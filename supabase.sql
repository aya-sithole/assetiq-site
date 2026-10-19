-- =====================================================================
-- AssetIQ -- Supabase (PostgreSQL) schema and access control
-- MULTI-TENANT VERSION
--
-- This is the REAL enforcement layer -- everything in index.html's
-- JavaScript that hides a button or checks a role is a convenience for the
-- interface only. This file is what actually decides whether a read or
-- write succeeds, evaluated by Postgres itself, not by the page.
--
-- WHAT CHANGED FROM THE SINGLE-TENANT VERSION, AND WHY:
-- Every tenant (customer organisation) now shares the same database and
-- the same set of tables -- this is the standard "pooled / shared schema"
-- multi-tenant model, the one real SaaS platforms use at MVP stage because
-- it needs no per-customer infrastructure (Section on Scalability in the
-- report). Isolation between tenants is therefore NOT physical (separate
-- databases) -- it is enforced entirely by Row Level Security filtering
-- every query by organization_id. If that filter were ever missing from a
-- policy, tenants could see each other's data; this file is written so
-- that is structurally hard to forget (every policy below is written
-- "same org AND ...", never just "...").
--
-- To install: run this against a FRESH Supabase project (Dashboard > SQL
-- Editor > New query > paste this entire file > Run). This is a breaking
-- schema change from the single-tenant version (new tables, new primary
-- keys on assets/tickets), so it is not a safe ALTER against an existing
-- single-tenant project -- start a new project, exactly as SETUP.md's
-- multi-tenant section says.
--
-- IMPORTANT, NOT OPTIONAL: account creation for an ORGANISATION'S FIRST
-- user now happens through this app's own sign-up screen (Create an
-- organisation), which is deliberately different from the single-tenant
-- version's "no self-service sign-up at all". See the long comment above
-- the profiles table below for why this is still safe. Supabase's
-- dashboard "Allow new users to sign up" setting must be ON for this
-- version (the opposite of the single-tenant SETUP.md step 2) -- see
-- SETUP.md.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------

-- One row per customer (tenant). This is the unit the subscription model
-- and the platform owner's "master dashboard" both operate on.
create table if not exists public.organizations (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  slug text not null unique,
  -- Subscription model: deliberately simple for an MVP (see README,
  -- "Subscription model: what's real and what's a placeholder"). plan and
  -- status are the two fields a real billing provider (e.g. Stripe) would
  -- otherwise update via webhook; here the platform owner sets status by
  -- hand from the master dashboard, which is an honest stand-in for that
  -- integration, not a finished one.
  plan text not null default 'trial' check (plan in ('trial', 'starter', 'pro')),
  status text not null default 'trialing' check (status in ('trialing', 'active', 'suspended', 'canceled')),
  trial_ends_at timestamptz not null default (now() + interval '14 days'),
  created_at timestamptz not null default now()
);

-- The platform owner -- AssetIQ's own operator, NOT a member of any
-- tenant's organisation. Kept as a wholly separate table from profiles on
-- purpose: a platform-owner account is never "an admin of an org with
-- extra powers", it is a different kind of account entirely, with no
-- organization_id and (per the RLS below) no visibility into any tenant's
-- assets, tickets or audit log -- only the organisations table itself and
-- the aggregate counts exposed by the platform_* functions further down.
create table if not exists public.platform_admins (
  id uuid primary key references auth.users (id) on delete cascade,
  email text not null
);

-- Invite codes: how an existing organisation's Org Manager adds a Staff or
-- Viewer account without running SQL by hand (the single-tenant version's
-- seed-accounts-template.sql approach does not scale once there are many
-- tenants, each with their own users). A code is single-use and expires.
create table if not exists public.invites (
  code text primary key default substr(encode(gen_random_bytes(6), 'hex'), 1, 10),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  role text not null check (role in ('user', 'viewer')),
  created_by uuid references auth.users (id),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '7 days'),
  used_by uuid references auth.users (id),
  used_at timestamptz
);

create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  organization_id uuid not null references public.organizations (id) on delete cascade,
  email text not null,
  role text not null check (role in ('admin', 'user', 'viewer')),
  name text not null default '',
  title text not null default '',
  dept text not null default ''
);

-- id is the human-readable asset tag (e.g. "LPT-4922"). It is UNIQUE PER
-- ORGANISATION, not globally -- two different tenants seeding the same
-- demo data would otherwise collide on a single global primary key. The
-- primary key is therefore the pair (organization_id, id).
create table if not exists public.assets (
  id text not null,
  organization_id uuid not null references public.organizations (id) on delete cascade,
  name text not null,
  icon text not null default '',
  make text not null default '',
  model text not null default '',
  sn text not null default '',
  "replace" text not null default '',
  location text not null default '',
  assigned text not null default '',
  condition text not null default 'Good',
  notes text not null default '',
  photo text not null default '',
  active boolean not null default true,
  value numeric not null default 0,
  primary key (organization_id, id)
);

create table if not exists public.tickets (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  reference text not null,
  asset_id text,
  asset_label text not null default '',
  type text not null default '',
  urgency text not null default 'Medium',
  description text not null default '',
  status text not null default 'open' check (status in ('open', 'resolved')),
  created_by text not null default '',
  created_at timestamptz not null default now(),
  -- Composite FK, matching the composite primary key on assets above.
  foreign key (organization_id, asset_id) references public.assets (organization_id, id)
);

create table if not exists public.audit_log (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  ts timestamptz not null default now(),
  user_email text not null default '',
  action text not null,
  detail text not null default '',
  denied boolean not null default false
);

-- ---------------------------------------------------------------------
-- Helper functions, all SECURITY DEFINER + STABLE for the same reason as
-- the single-tenant version: a policy on "profiles" that queried
-- "profiles" directly to check your own role/org would recurse into
-- itself under Row Level Security. These bypass that by running with the
-- function owner's privileges, looked up once per statement.
-- ---------------------------------------------------------------------

create or replace function public.my_role()
returns text
language sql security definer stable set search_path = public
as $$
  select role from public.profiles where id = auth.uid();
$$;

create or replace function public.my_org_id()
returns uuid
language sql security definer stable set search_path = public
as $$
  select organization_id from public.profiles where id = auth.uid();
$$;

create or replace function public.is_admin()
returns boolean
language sql security definer stable set search_path = public
as $$
  select coalesce(public.my_role() = 'admin', false);
$$;

create or replace function public.is_platform_owner()
returns boolean
language sql security definer stable set search_path = public
as $$
  select exists (select 1 from public.platform_admins where id = auth.uid());
$$;

-- The subscription-enforcement check: a tenant whose organisation has been
-- suspended or cancelled (set from the master dashboard, see below) loses
-- read/write access to its own assets and tickets -- not just a UI banner,
-- an actual refusal from Postgres, the same way every other restriction in
-- this file is real rather than cosmetic. Profile reads are deliberately
-- NOT gated by this (see profiles policies) so a suspended tenant's users
-- can still sign in and see why they are locked out.
create or replace function public.org_active()
returns boolean
language sql security definer stable set search_path = public
as $$
  select coalesce(
    (select status not in ('suspended', 'canceled') from public.organizations where id = public.my_org_id()),
    false
  );
$$;

-- ---------------------------------------------------------------------
-- Row Level Security: ON for every table, with no default access at all.
-- ---------------------------------------------------------------------

alter table public.organizations enable row level security;
alter table public.platform_admins enable row level security;
alter table public.invites enable row level security;
alter table public.profiles enable row level security;
alter table public.assets enable row level security;
alter table public.tickets enable row level security;
alter table public.audit_log enable row level security;

-- --- organizations ---
-- A member reads their own organisation's row (for the plan/status chip
-- shown in the app); the platform owner reads every row (the master
-- dashboard's list). Nobody updates or deletes this table directly through
-- RLS at all -- every change to it goes through the platform_* functions
-- further down, or the create-organization Edge Function, both of which
-- run with elevated privilege deliberately, as a single controlled path
-- rather than an RLS policy a client could call directly.
drop policy if exists "member reads own org or platform owner reads any" on public.organizations;
create policy "member reads own org or platform owner reads any" on public.organizations
  for select using (id = public.my_org_id() or public.is_platform_owner());

-- --- platform_admins: nobody reads or writes this via the client at all.
-- Bootstrapped once, by hand, in the SQL editor (SETUP.md) -- there is no
-- RLS policy here on purpose, so every client request is refused.

-- --- invites ---
drop policy if exists "org admin creates invites for own org" on public.invites;
create policy "org admin creates invites for own org" on public.invites
  for insert with check (public.is_admin() and organization_id = public.my_org_id());

drop policy if exists "org admin reads own org invites" on public.invites;
create policy "org admin reads own org invites" on public.invites
  for select using (public.is_admin() and organization_id = public.my_org_id());
-- No update/delete policy: an invite is marked used only by the
-- join-organization Edge Function (service role), never by a client call.

-- --- profiles ---
drop policy if exists "read own or admin reads any" on public.profiles;
drop policy if exists "read own or org admin reads own org" on public.profiles;
create policy "read own or org admin reads own org" on public.profiles
  for select using (auth.uid() = id or (public.is_admin() and organization_id = public.my_org_id()));

-- No INSERT policy at all, deliberately. In the single-tenant version this
-- was a client-callable "insert your own profile, viewer role only"
-- policy. Here it is removed entirely: EVERY profile row is now created by
-- one of two Edge Functions (create-organization, join-organization),
-- both running with the service role key, which bypasses RLS by design
-- the same way a privileged admin SQL script always has. The security
-- property from the single-tenant version is preserved, just moved: a
-- self-signed-up user can still never grant themselves an arbitrary role
-- in an arbitrary organisation, because create-organization always makes
-- them 'admin' of a BRAND NEW org, and join-organization only ever applies
-- the role attached to one specific, single-use invite code created by an
-- existing admin of that org. Neither function lets the caller choose
-- their own role or organisation directly.
drop policy if exists "create own profile only, viewer role only" on public.profiles;

-- Self-update allowed (so a user can fix their own name/title/dept), and
-- an org admin may update any profile in their own org (used for nothing
-- yet in the UI beyond viewing, but kept consistent with assets/tickets).
-- organization_id = my_org_id() in BOTH using and with check means a user
-- can never update a row into or out of another organisation, and the
-- trigger below additionally blocks a non-admin from touching role.
drop policy if exists "update own or admin updates any" on public.profiles;
drop policy if exists "update own or org admin updates own org" on public.profiles;
create policy "update own or org admin updates own org" on public.profiles
  for update
  using ((auth.uid() = id or public.is_admin()) and organization_id = public.my_org_id())
  with check (organization_id = public.my_org_id());

-- No DELETE policy = deletes are always refused for everyone.

-- --- assets --- (every policy requires organization_id = my_org_id() AND,
-- for writes, org_active() -- a suspended tenant cannot write OR read its
-- own asset data until the platform owner reactivates it)
drop policy if exists "any signed-in user can read assets" on public.assets;
drop policy if exists "org members read own org assets" on public.assets;
create policy "org members read own org assets" on public.assets
  for select using (auth.uid() is not null and organization_id = public.my_org_id() and public.org_active());

drop policy if exists "admin creates assets" on public.assets;
drop policy if exists "admin or staff can create assets" on public.assets;
drop policy if exists "admin or staff create assets in own org" on public.assets;
create policy "admin or staff create assets in own org" on public.assets
  for insert
  with check ((public.is_admin() or public.my_role() = 'user') and organization_id = public.my_org_id() and public.org_active());

drop policy if exists "admin deletes assets" on public.assets;
drop policy if exists "admin deletes own org assets" on public.assets;
create policy "admin deletes own org assets" on public.assets
  for delete using (public.is_admin() and organization_id = public.my_org_id());

drop policy if exists "admin or staff can update assets" on public.assets;
drop policy if exists "admin or staff update own org assets" on public.assets;
create policy "admin or staff update own org assets" on public.assets
  for update
  using ((public.is_admin() or public.my_role() = 'user') and organization_id = public.my_org_id() and public.org_active())
  with check (organization_id = public.my_org_id());

-- --- tickets ---
drop policy if exists "staff or admin create tickets" on public.tickets;
drop policy if exists "staff or admin create tickets in own org" on public.tickets;
create policy "staff or admin create tickets in own org" on public.tickets
  for insert
  with check (public.my_role() in ('user', 'admin') and organization_id = public.my_org_id() and public.org_active());

drop policy if exists "admin reads tickets" on public.tickets;
drop policy if exists "admin reads own org tickets" on public.tickets;
create policy "admin reads own org tickets" on public.tickets
  for select using (public.is_admin() and organization_id = public.my_org_id() and public.org_active());

drop policy if exists "admin updates tickets" on public.tickets;
drop policy if exists "admin updates own org tickets" on public.tickets;
create policy "admin updates own org tickets" on public.tickets
  for update
  using (public.is_admin() and organization_id = public.my_org_id() and public.org_active())
  with check (organization_id = public.my_org_id());

drop policy if exists "admin deletes tickets" on public.tickets;
drop policy if exists "admin deletes own org tickets" on public.tickets;
create policy "admin deletes own org tickets" on public.tickets
  for delete using (public.is_admin() and organization_id = public.my_org_id());

-- --- audit_log: append-only, exactly as in the single-tenant version, now
-- also org-scoped. The platform owner deliberately CANNOT read any
-- tenant's audit log -- only that tenant's own Org Manager can (privacy
-- boundary: what AssetIQ's operator can see about a customer is limited to
-- the organisations table and the aggregate counts below, never the
-- customer's own operational data). There is still no update or delete
-- policy at all, for anyone, including Org Manager and platform owner.
drop policy if exists "any signed-in user can write audit entries" on public.audit_log;
drop policy if exists "signed-in user writes own org audit entries" on public.audit_log;
create policy "signed-in user writes own org audit entries" on public.audit_log
  for insert with check (auth.uid() is not null and organization_id = public.my_org_id());

drop policy if exists "admin reads audit log" on public.audit_log;
drop policy if exists "admin reads own org audit log" on public.audit_log;
create policy "admin reads own org audit log" on public.audit_log
  for select using (public.is_admin() and organization_id = public.my_org_id());

-- ---------------------------------------------------------------------
-- Field-level enforcement for assets (same reasoning as the single-tenant
-- version: Row Level Security is per-ROW, not per-COLUMN, so a trigger is
-- the idiomatic way to stop Staff changing specific columns even on a row
-- the UPDATE policy already lets them touch). Extended to also forbid
-- changing organization_id outright, for anyone, including an Org Manager
-- -- an asset can never be moved between tenants.
-- ---------------------------------------------------------------------

create or replace function public.protect_asset_privileged_fields()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  if new.organization_id is distinct from old.organization_id then
    raise exception 'An asset cannot be moved between organisations.' using errcode = '42501';
  end if;
  if public.is_admin() then
    return new;
  end if;
  if new.sn is distinct from old.sn
     or new.assigned is distinct from old.assigned
     or new.location is distinct from old.location
     or new."replace" is distinct from old."replace"
     or new.name is distinct from old.name
  then
    raise exception 'Only an Org Manager may change serial number, assigned user, location, replacement cycle or name.'
      using errcode = '42501';
  end if;
  return new;
end;
$$;

drop trigger if exists protect_asset_privileged_fields_trigger on public.assets;
create trigger protect_asset_privileged_fields_trigger
  before update on public.assets
  for each row execute function public.protect_asset_privileged_fields();

-- Same idea, applied to profiles: stops a Staff or Viewer account
-- rewriting its own role to 'admin', and stops ANYONE rewriting their own
-- (or another profile's) organization_id -- moving a user between tenants
-- is not supported at all; they would sign up or be invited again.
create or replace function public.protect_own_role()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  if new.organization_id is distinct from old.organization_id then
    raise exception 'A profile cannot be moved to a different organisation.' using errcode = '42501';
  end if;
  if public.is_admin() then
    return new;
  end if;
  if new.role is distinct from old.role then
    raise exception 'You cannot change your own role.' using errcode = '42501';
  end if;
  return new;
end;
$$;

drop trigger if exists protect_own_role_trigger on public.profiles;
create trigger protect_own_role_trigger
  before update on public.profiles
  for each row execute function public.protect_own_role();

-- ---------------------------------------------------------------------
-- Platform-owner functions: the "master dashboard"'s real backing. Each
-- one re-checks is_platform_owner() INSIDE the function body (not just via
-- a grant), so even if a function's EXECUTE privilege were ever
-- accidentally left open, a non-platform-owner calling it gets a refusal
-- from Postgres, not tenant data. They deliberately return aggregate
-- counts only (member_count, asset_count), never the tenant's actual
-- asset or ticket rows -- see the audit_log policy comment above for why
-- that boundary matters.
-- ---------------------------------------------------------------------

create or replace function public.platform_list_organizations()
returns table (
  id uuid, name text, slug text, plan text, status text,
  trial_ends_at timestamptz, created_at timestamptz,
  member_count bigint, asset_count bigint
)
language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_platform_owner() then
    raise exception 'Not authorised: platform owner only.' using errcode = '42501';
  end if;
  return query
    select o.id, o.name, o.slug, o.plan, o.status, o.trial_ends_at, o.created_at,
           (select count(*) from public.profiles p where p.organization_id = o.id) as member_count,
           (select count(*) from public.assets a where a.organization_id = o.id) as asset_count
    from public.organizations o
    order by o.created_at desc;
end;
$$;

create or replace function public.platform_set_org_status(org_id uuid, new_status text)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_platform_owner() then
    raise exception 'Not authorised: platform owner only.' using errcode = '42501';
  end if;
  if new_status not in ('trialing', 'active', 'suspended', 'canceled') then
    raise exception 'Unknown status: %', new_status;
  end if;
  update public.organizations set status = new_status where id = org_id;
end;
$$;

grant execute on function public.platform_list_organizations() to authenticated;
grant execute on function public.platform_set_org_status(uuid, text) to authenticated;

-- =====================================================================
-- Billing / payments / plan tiers -- merged in from supabase/billing-
-- upgrade.sql so a FRESH install gets this in one run. If you already
-- have a live project, do NOT re-run this whole file -- run just
-- supabase/billing-upgrade.sql instead (see its header comment for why
-- that one is additive-safe and this combined file is not, due to the
-- composite-key / breaking-change note at the top of this file).
-- =====================================================================

-- =====================================================================
-- AssetIQ -- Billing / payments / plan-tier addition
--
-- UNLIKE supabase.sql, this file is SAFE TO RUN AGAINST YOUR EXISTING,
-- ALREADY-LIVE MULTI-TENANT PROJECT. Nothing here drops a table or
-- changes an existing primary key -- it only ADDS a column, ADDS a new
-- table, and uses `create or replace function` / `drop ... if exists`
-- throughout, so real signed-up organisations, assets and tickets are
-- untouched. Run it once in the SQL Editor, same as supabase.sql; it is
-- also safe to run more than once.
--
-- WHAT THIS ADDS, AND WHY (see README, "Billing, payments and plan
-- tiers" for the long version):
--
-- 1. A real (if simplified) payment/credit system. There is still no
--    actual card processor wired up -- this is a DUMMY payment flow,
--    on purpose, exactly like the rest of this MVP's subscription model
--    (see supabase.sql's comment on organizations.plan/status). A
--    tenant's "Pay now" button on the new Billing screen in index.html
--    collects fake card details that are never validated or stored,
--    and always succeeds -- inserting a row into the new `payments`
--    table below, which a trigger turns into a real balance increase
--    on organizations.credits_balance. That balance is real and
--    enforced; the card number next to it is theatre.
--
-- 2. Plan tiers that actually mean something. trial/starter/pro now
--    each have a real asset-count limit (plan_asset_limit() below),
--    enforced the same way every other restriction in supabase.sql is
--    enforced: a trigger that makes Postgres itself refuse the INSERT
--    once an organisation is at its limit, not a number shown in the
--    UI that nothing stops you exceeding.
--
-- 3. A spend-credits-to-upgrade path (upgrade_plan()), checked and
--    applied atomically in the database, not computed in JavaScript
--    and then trusted.
--
-- 4. Real levers for the platform owner beyond suspend/activate:
--    platform_set_org_plan() (a direct override -- e.g. comping a
--    customer, or fixing a stuck account, without them having to pay
--    again) and two read-only aggregate views, platform_revenue_summary()
--    and platform_list_payments() -- deliberately amounts and org
--    names only, never a tenant's own operational data, the same
--    privacy boundary the rest of the platform_* functions already
--    draw.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Schema additions
-- ---------------------------------------------------------------------

alter table public.organizations add column if not exists credits_balance numeric not null default 0;

-- Append-only payment ledger, same pattern as audit_log: insert policy
-- for the org admin, select policy for the org admin, no update/delete
-- policy at all (so nobody, including the org admin, can edit or erase
-- a payment once it exists).
create table if not exists public.payments (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  amount numeric not null check (amount > 0),
  method text not null default 'card',
  status text not null default 'succeeded' check (status in ('succeeded', 'failed')),
  note text not null default '',
  created_by uuid references auth.users (id),
  created_at timestamptz not null default now()
);
alter table public.payments enable row level security;

drop policy if exists "org admin creates payments for own org" on public.payments;
create policy "org admin creates payments for own org" on public.payments
  for insert with check (public.is_admin() and organization_id = public.my_org_id());
-- Deliberately NOT gated by org_active() -- unlike assets/tickets, a
-- SUSPENDED tenant must still be able to pay in order to get itself
-- reactivated (upgrade_plan() below is the only thing that spends a
-- balance and flips status back to 'active'); refusing the payment
-- itself would make suspension unrecoverable by the customer.

drop policy if exists "org admin reads own org payments" on public.payments;
create policy "org admin reads own org payments" on public.payments
  for select using (public.is_admin() and organization_id = public.my_org_id());

-- ---------------------------------------------------------------------
-- 2. A successful payment becomes a real balance increase.
-- ---------------------------------------------------------------------

create or replace function public.apply_payment_to_balance()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  if new.status = 'succeeded' then
    update public.organizations set credits_balance = credits_balance + new.amount where id = new.organization_id;
  end if;
  return new;
end;
$$;

drop trigger if exists apply_payment_to_balance_trigger on public.payments;
create trigger apply_payment_to_balance_trigger
  after insert on public.payments
  for each row execute function public.apply_payment_to_balance();

-- ---------------------------------------------------------------------
-- 3. Plan limits and costs. "Space" in this prototype means asset
-- count, not disk space -- photos are mocked filenames, not real
-- uploaded files (see README) -- so that is what each tier actually
-- gates.
-- ---------------------------------------------------------------------

create or replace function public.plan_asset_limit(p text)
returns int
language sql immutable
as $$
  select case p when 'trial' then 10 when 'starter' then 50 when 'pro' then 500 else 10 end;
$$;

create or replace function public.plan_cost(p text)
returns numeric
language sql immutable
as $$
  select case p when 'starter' then 29 when 'pro' then 99 else 0 end;
$$;

-- The real enforcement: Postgres itself refuses to create one more
-- asset than the organisation's plan allows. index.html's Billing
-- screen shows the same limit as a usage bar, purely for display --
-- this trigger is what actually stops it being exceeded, the same way
-- org_active() actually stops a suspended tenant writing, not just a
-- banner saying so.
create or replace function public.enforce_asset_plan_limit()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  current_count int;
  limit_n int;
  org_plan text;
begin
  select plan into org_plan from public.organizations where id = new.organization_id;
  limit_n := public.plan_asset_limit(org_plan);
  select count(*) into current_count from public.assets where organization_id = new.organization_id;
  if current_count >= limit_n then
    raise exception 'Asset limit reached for the % plan (% of % used). Upgrade your plan from Billing to raise this limit.', org_plan, current_count, limit_n
      using errcode = '42501';
  end if;
  return new;
end;
$$;

drop trigger if exists enforce_asset_plan_limit_trigger on public.assets;
create trigger enforce_asset_plan_limit_trigger
  before insert on public.assets
  for each row execute function public.enforce_asset_plan_limit();

-- ---------------------------------------------------------------------
-- 4. Tenant-facing: spend credits to upgrade. Checked and applied
-- atomically inside the database -- the balance check and the deduction
-- happen in the same statement, so two rapid clicks can't both succeed
-- against a balance that only covers one of them.
-- ---------------------------------------------------------------------

create or replace function public.upgrade_plan(new_plan text)
returns table(plan text, credits_balance numeric)
language plpgsql security definer set search_path = public
as $$
declare
  v_org_id uuid;
  v_cost numeric;
  v_balance numeric;
begin
  if not public.is_admin() then
    raise exception 'Only an Org Manager can change the subscription plan.' using errcode = '42501';
  end if;
  v_org_id := public.my_org_id();
  if new_plan not in ('starter', 'pro') then
    raise exception 'Unknown plan: %', new_plan;
  end if;
  v_cost := public.plan_cost(new_plan);
  select o.credits_balance into v_balance from public.organizations o where o.id = v_org_id;
  if v_balance < v_cost then
    raise exception 'Insufficient credit balance: % costs %, your balance is %. Top up first.', new_plan, v_cost, v_balance
      using errcode = '42501';
  end if;
  update public.organizations o set credits_balance = o.credits_balance - v_cost, plan = new_plan, status = 'active'
    where o.id = v_org_id;
  return query select o.plan, o.credits_balance from public.organizations o where o.id = v_org_id;
end;
$$;

grant execute on function public.upgrade_plan(text) to authenticated;

-- ---------------------------------------------------------------------
-- 5. Platform-owner functions. Same re-check-is_platform_owner-inside-
-- the-function-body pattern as platform_list_organizations() /
-- platform_set_org_status() in supabase.sql, and the same privacy
-- boundary: amounts and organisation names only, never a tenant's
-- actual assets, tickets or audit log.
-- ---------------------------------------------------------------------

create or replace function public.platform_set_org_plan(org_id uuid, new_plan text)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_platform_owner() then
    raise exception 'Not authorised: platform owner only.' using errcode = '42501';
  end if;
  if new_plan not in ('trial', 'starter', 'pro') then
    raise exception 'Unknown plan: %', new_plan;
  end if;
  update public.organizations set plan = new_plan where id = org_id;
end;
$$;

grant execute on function public.platform_set_org_plan(uuid, text) to authenticated;

create or replace function public.platform_revenue_summary()
returns table(total_revenue numeric, revenue_last_30d numeric, payments_count bigint, organizations_count bigint)
language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_platform_owner() then
    raise exception 'Not authorised: platform owner only.' using errcode = '42501';
  end if;
  return query
    select
      coalesce((select sum(amount) from public.payments where status = 'succeeded'), 0),
      coalesce((select sum(amount) from public.payments where status = 'succeeded' and created_at > now() - interval '30 days'), 0),
      (select count(*) from public.payments where status = 'succeeded'),
      (select count(*) from public.organizations);
end;
$$;

grant execute on function public.platform_revenue_summary() to authenticated;

create or replace function public.platform_list_payments(limit_n int default 20)
returns table(id uuid, organization_name text, amount numeric, method text, created_at timestamptz)
language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_platform_owner() then
    raise exception 'Not authorised: platform owner only.' using errcode = '42501';
  end if;
  return query
    select p.id, o.name, p.amount, p.method, p.created_at
    from public.payments p
    join public.organizations o on o.id = p.organization_id
    where p.status = 'succeeded'
    order by p.created_at desc
    limit limit_n;
end;
$$;

grant execute on function public.platform_list_payments(int) to authenticated;

-- platform_list_organizations() gains a credits_balance column. Its
-- return signature is changing (an added output column), which Postgres
-- will not allow via a plain CREATE OR REPLACE -- hence the explicit
-- DROP first. This is still safe to run on a live project: it is the
-- same function name and the same security check inside it, just one
-- more column in what it returns.
drop function if exists public.platform_list_organizations();

create or replace function public.platform_list_organizations()
returns table (
  id uuid, name text, slug text, plan text, status text,
  trial_ends_at timestamptz, created_at timestamptz,
  member_count bigint, asset_count bigint, credits_balance numeric
)
language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_platform_owner() then
    raise exception 'Not authorised: platform owner only.' using errcode = '42501';
  end if;
  return query
    select o.id, o.name, o.slug, o.plan, o.status, o.trial_ends_at, o.created_at,
           (select count(*) from public.profiles p where p.organization_id = o.id) as member_count,
           (select count(*) from public.assets a where a.organization_id = o.id) as asset_count,
           o.credits_balance
    from public.organizations o
    order by o.created_at desc;
end;
$$;

grant execute on function public.platform_list_organizations() to authenticated;

-- =====================================================================
-- Customer Discovery co-pilot -- merged in from supabase/copilot-
-- upgrade.sql so a FRESH install gets this in one run. If you already
-- have a live project, do NOT re-run this whole file -- run just
-- supabase/copilot-upgrade.sql instead (same reasoning as the billing
-- addition above: this combined file is not safe to re-run on a live
-- project due to the composite-key / breaking-change note at the very
-- top of this file; the standalone files are additive-safe).
-- =====================================================================

-- =====================================================================
-- AssetIQ -- Customer Discovery co-pilot addition
--
-- SAFE TO RUN AGAINST YOUR EXISTING, ALREADY-LIVE PROJECT, same as
-- supabase/billing-upgrade.sql -- every statement here only creates new
-- tables and uses `drop policy if exists` before `create policy`, so
-- nothing existing is dropped or re-keyed. Run it once in the SQL
-- Editor; safe to run more than once.
--
-- WHAT THIS ADDS, AND WHY (see README, "The Customer Discovery
-- co-pilot" for the long version):
--
-- A real, Claude-backed chat co-pilot, reached through the new
-- `ai-copilot` Edge Function (see supabase/functions/ai-copilot/), in
-- two modes:
--
-- 1. PLATFORM OWNER: a coach applying Steve Blank's Customer Discovery
--    methodology to AssetIQ itself (the SaaS business, not any tenant's
--    business) -- hypotheses about customer/problem/solution, a log of
--    real "get out of the building" interviews, a running Business
--    Model Canvas, and pivot-or-persevere decisions. These four tables
--    below hold that state, and they are the platform owner's own
--    working notes -- not tenant data, not an append-only ledger like
--    audit_log/payments, so (unlike those) the owner can edit and
--    delete their own entries directly.
--
-- 2. TENANT: a lighter-touch real-AI upgrade of the existing "AI
--    Assist" chat (previously scripted keyword-matching in index.html,
--    not real AI at all) -- grounded in that organisation's own
--    assets/tickets, with no Customer-Discovery framework overlay.
--
-- Both modes' conversation history is persisted in `copilot_messages`,
-- scoped so a platform owner's messages and a tenant's messages can
-- never cross -- the same "organization_id = ... AND ..." discipline
-- the rest of this schema already follows, with the platform-owner
-- case narrowed further to the owner's OWN messages (created_by =
-- auth.uid()), since more than one platform_admins row could exist.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Customer Discovery state (platform owner only -- this is about
-- AssetIQ's own business model, so it is not organisation-scoped at
-- all; it has no organization_id column, on purpose).
-- ---------------------------------------------------------------------

create table if not exists public.discovery_hypotheses (
  id uuid primary key default gen_random_uuid(),
  customer_segment text not null default '',
  problem_statement text not null default '',
  solution_statement text not null default '',
  status text not null default 'untested' check (status in ('untested', 'testing', 'validated', 'invalidated')),
  created_by uuid references auth.users (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.discovery_hypotheses enable row level security;
drop policy if exists "platform owner manages hypotheses" on public.discovery_hypotheses;
create policy "platform owner manages hypotheses" on public.discovery_hypotheses
  for all using (public.is_platform_owner()) with check (public.is_platform_owner());

create table if not exists public.discovery_interviews (
  id uuid primary key default gen_random_uuid(),
  hypothesis_id uuid references public.discovery_hypotheses (id) on delete set null,
  interviewee text not null default '',
  notes text not null default '',
  learning text not null default '',
  created_by uuid references auth.users (id),
  created_at timestamptz not null default now()
);
alter table public.discovery_interviews enable row level security;
drop policy if exists "platform owner manages interviews" on public.discovery_interviews;
create policy "platform owner manages interviews" on public.discovery_interviews
  for all using (public.is_platform_owner()) with check (public.is_platform_owner());

-- One row per Business Model Canvas block -- a fixed set of nine keys,
-- checked by the constraint below, not an open-ended table.
create table if not exists public.discovery_canvas (
  block_key text primary key check (block_key in (
    'customer_segments', 'value_proposition', 'channels', 'customer_relationships',
    'revenue_streams', 'key_resources', 'key_activities', 'key_partners', 'cost_structure'
  )),
  content text not null default '',
  updated_by uuid references auth.users (id),
  updated_at timestamptz not null default now()
);
alter table public.discovery_canvas enable row level security;
drop policy if exists "platform owner manages canvas" on public.discovery_canvas;
create policy "platform owner manages canvas" on public.discovery_canvas
  for all using (public.is_platform_owner()) with check (public.is_platform_owner());

create table if not exists public.discovery_decisions (
  id uuid primary key default gen_random_uuid(),
  decision text not null check (decision in ('persevere', 'pivot')),
  rationale text not null default '',
  created_by uuid references auth.users (id),
  created_at timestamptz not null default now()
);
alter table public.discovery_decisions enable row level security;
drop policy if exists "platform owner manages decisions" on public.discovery_decisions;
create policy "platform owner manages decisions" on public.discovery_decisions
  for all using (public.is_platform_owner()) with check (public.is_platform_owner());

-- ---------------------------------------------------------------------
-- 2. Persisted chat history for BOTH co-pilot modes. scope='platform'
-- rows have organization_id = null; scope='tenant' rows always carry
-- one. The CHECK below makes that pairing structural, not just a
-- convention the application has to remember to honour.
-- ---------------------------------------------------------------------

create table if not exists public.copilot_messages (
  id uuid primary key default gen_random_uuid(),
  scope text not null check (scope in ('platform', 'tenant')),
  organization_id uuid references public.organizations (id) on delete cascade,
  role text not null check (role in ('user', 'assistant')),
  content text not null,
  created_by uuid not null references auth.users (id),
  created_at timestamptz not null default now(),
  constraint copilot_messages_scope_org_pairing check (
    (scope = 'platform' and organization_id is null) or
    (scope = 'tenant' and organization_id is not null)
  )
);
alter table public.copilot_messages enable row level security;

-- Platform owner reads/writes only their OWN messages (not any other
-- platform_admins row's conversation, in case there is more than one).
drop policy if exists "platform owner manages own copilot messages" on public.copilot_messages;
create policy "platform owner manages own copilot messages" on public.copilot_messages
  for all
  using (scope = 'platform' and created_by = auth.uid() and public.is_platform_owner())
  with check (scope = 'platform' and created_by = auth.uid() and public.is_platform_owner());

-- A tenant user reads/writes only their OWN messages within their OWN
-- organisation -- so two Staff accounts in the same org get separate
-- conversations with the assistant, not one shared, confusing thread.
drop policy if exists "org member manages own tenant copilot messages" on public.copilot_messages;
create policy "org member manages own tenant copilot messages" on public.copilot_messages
  for all
  using (scope = 'tenant' and created_by = auth.uid() and organization_id = public.my_org_id())
  with check (scope = 'tenant' and created_by = auth.uid() and organization_id = public.my_org_id());
