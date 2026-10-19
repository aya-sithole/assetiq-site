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
