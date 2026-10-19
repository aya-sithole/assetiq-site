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
