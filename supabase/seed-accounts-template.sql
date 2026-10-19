-- AssetIQ -- manual profile-seeding template (MULTI-TENANT VERSION)
--
-- SUPERSEDED FOR NORMAL USE by the in-app flows: an organisation's first
-- account now provisions itself via Sign up > "New organisation" (handled
-- by the create-organization Edge Function), and every later teammate via
-- Sign up > "Join with invite code" (handled by join-organization and the
-- invites table) -- both described in SETUP.md. Neither needs anyone to
-- open the SQL Editor.
--
-- This file still has two real uses:
--
-- 1. Bootstrapping the PLATFORM OWNER (SETUP.md step 6) -- a
--    platform_admins row, not a profiles row, and genuinely has no other
--    way to be created, by design (there is no "become the platform owner"
--    button anywhere in the app, the same reasoning the single-tenant
--    version applied to admin accounts generally):
--
--    insert into public.platform_admins (id, email) values
--      ('PASTE-YOUR-USER-UID-HERE', 'your-email@example.com');
--
-- 2. Recovering a demo organisation's accounts by hand (e.g. for this
--    project's own marking/demo environment, where it's convenient to have
--    fixed, memorable logins rather than going through sign-up each time).
--    Replace the organization_id and UID placeholders below with real
--    values -- an organisation's id from the organizations table (create
--    one first, or use one already created via sign-up), and each
--    account's UID from Authentication > Users after creating it there.

insert into public.profiles (id, organization_id, email, role, name, title, dept) values
  ('PASTE-ADMIN-UID-HERE', 'PASTE-ORGANIZATION-ID-HERE', 'admin@example.test', 'admin', 'Alex Manager', 'Fleet & Asset Director', 'Operations Management'),
  ('PASTE-STAFF-UID-HERE', 'PASTE-ORGANIZATION-ID-HERE', 'staff@example.test', 'user', 'Sam Technician', 'Field Technician', 'Operations'),
  ('PASTE-VIEWER-UID-HERE', 'PASTE-ORGANIZATION-ID-HERE', 'viewer@example.test', 'viewer', 'Riley Auditor', 'Compliance Auditor', 'Risk & Compliance')
on conflict (id) do update set
  role = excluded.role, name = excluded.name, title = excluded.title, dept = excluded.dept;
-- organization_id is deliberately NOT included in the update list -- the
-- protect_own_role trigger in supabase.sql refuses to move a profile
-- between organisations even when run from here, so re-running this with a
-- different organization_id for an existing UID will fail loudly rather
-- than silently reassigning someone's tenant.

-- This query runs with full database privileges (the SQL Editor is not
-- subject to the app's own Row Level Security), which is exactly why it is
-- still administrator-only, not something a client call could do.
