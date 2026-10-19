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
