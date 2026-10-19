# AssetIQ (Supabase-backed, multi-tenant) -- setup

No terminal, no Python, no installation beyond a free account. About fifteen
to twenty minutes -- a little longer than the single-tenant version, because
there are three Edge Functions to deploy instead of one, and one extra,
one-time step to make your own account the platform owner.

**This is the multi-tenant version.** One deployment of this app and one
Supabase project now serve every customer ("tenant"), each with its own
isolated organisation, rather than one Supabase project per customer. If you
are looking for the simpler single-tenant setup (one installation per
client), that is a different, earlier version of this project -- this file
is for the version where customers sign themselves up.

## 1. Create a Supabase project

Go to [supabase.com](https://supabase.com/), sign in (GitHub or email), and
click **New project**. Give it any name, set a database password (you won't
need to remember this -- it's for direct database connections, which this
prototype doesn't use), and pick a region. No credit card is required for
the free plan.

Creating a new project takes Supabase a minute or two to provision -- wait
for the progress screen to finish before continuing.

## 2. Enable public sign-up

This is the **opposite** of the single-tenant version's Step 2, and it is
deliberate, not a regression -- see README, "Sign-up, revisited for
multi-tenancy" for the full reasoning. A subscription product needs
customers to be able to sign themselves up; the security property the
single-tenant version protected by turning sign-up off is protected here a
different way instead (by what a signed-up account is allowed to *become*,
never by stopping sign-up itself).

Go to **Authentication > Sign In / Providers** (or **Authentication >
Settings**), find **Email**, and make sure **"Allow new users to sign up"**
is **ON** (it is Supabase's default for a new project, so you may not need
to change anything here -- just confirm it's on). Also confirm **"Confirm
email"** is **OFF** for this demo, since these are fictional addresses that
can't receive a real confirmation email; the sign-up flow in `index.html`
assumes a session exists immediately after `signUp()`.

## 3. Run the database setup script

Go to the **SQL Editor**, click **New query**, open `supabase.sql`
(included alongside this file), copy its entire contents, paste them in,
and click **Run**.

This creates every table (including `organizations`, `platform_admins` and
`invites`, which did not exist in the single-tenant version), turns on Row
Level Security scoped to each organisation, and sets up the subscription
enforcement (`org_active()`) and the platform-owner functions behind the
master dashboard. It's commented throughout -- worth reading, since this is
the real enforcement layer, not `index.html`'s JavaScript.

**If you are upgrading from the single-tenant version:** this is a breaking
schema change (new composite primary keys on `assets` and `tickets`), not a
safe `ALTER` against an existing project. Use a fresh Supabase project.

**If you already have this multi-tenant version live with real
organisations signed up:** `supabase.sql` now also includes the billing,
payments and plan-tier addition at the end -- running the WHOLE file again
is still safe (every statement in it is idempotent), so you don't need to
treat this as a second breaking change.

### 3a. Billing, payments and plan tiers (already included above for a fresh project)

This adds a real credit balance, a dummy "pay now" top-up flow, and actual
enforced per-plan asset limits -- see README, "Billing, payments and plan
tiers" for what's real and what's a deliberate placeholder. It's already
part of the `supabase.sql` you just ran in Step 3, so a fresh project needs
nothing further here.

If you installed this app's multi-tenant version **before** this feature
existed and don't want to re-run the entire `supabase.sql` file, run just
`supabase/billing-upgrade.sql` instead (same SQL Editor steps as Step 3) --
it is written to be safe against an already-live project: it only adds a
column and a new table, and never drops or re-keys anything existing
tenants' data depends on.

## 4. Connect the app to your project

Go to **Project Settings > API**. You'll see a **Project URL** and an
**anon public key** (starts with `eyJ...`). These are safe to put in a
public file -- they only grant whatever Row Level Security allows.

Open `index.html`, find this block near the top of the `<script>` section:

```javascript
const SUPABASE_URL = "PASTE_YOUR_SUPABASE_PROJECT_URL";
const SUPABASE_ANON_KEY = "PASTE_YOUR_SUPABASE_ANON_PUBLIC_KEY";
```

Replace both with the real values from your project. Save the file.

## 5. Deploy the three Edge Functions

There are three this time, each handling something that must not run in
the browser:

| Function | Folder | What it does |
|---|---|---|
| `scan-nameplate` | `supabase/functions/scan-nameplate/` | Reads a nameplate photo via Claude Fable 5.1 (unchanged from the single-tenant version) |
| `create-organization` | `supabase/functions/create-organization/` | Turns a freshly signed-up account into a new organisation's Org Manager |
| `join-organization` | `supabase/functions/join-organization/` | Turns a freshly signed-up account into a Staff/Viewer member via an invite code |

For each one: go to **Edge Functions** in the left sidebar, click **Create a
new function**, name it **exactly** as in the table above (the app calls
these names directly), delete the placeholder code, paste in that folder's
`index.ts`, and click **Deploy**.

`create-organization` and `join-organization` both need the **service role
key** (see why in the long comment at the top of each file -- in short,
creating an organisation and its first profile row has to be one atomic,
trusted operation, not something Row Level Security could safely allow a
client to do directly). Supabase provides `SUPABASE_URL`,
`SUPABASE_ANON_KEY` and `SUPABASE_SERVICE_ROLE_KEY` to every Edge Function
automatically -- you do not set any of these three yourself.

### 5a. Get an Anthropic API key (for `scan-nameplate` only)

Go to [console.anthropic.com](https://console.anthropic.com/) and sign up.
Unlike Gemini, **Anthropic's API has no card-free tier** -- add a payment
method under **Settings > Billing**. Then **Settings > API Keys > Create
Key** and copy it.

### 5b. Add the Anthropic key as a secret

In **Edge Functions > Manage secrets**, add a secret named exactly
`ANTHROPIC_API_KEY` with the key from 5a. `create-organization` and
`join-organization` do not need this secret -- it is only read by
`scan-nameplate`.

## 6. Make yourself the platform owner

This is the one step with no equivalent in the single-tenant version. The
**platform owner** is AssetIQ's own operator (you) -- a separate kind of
account from any tenant's Org Manager, with access only to the master
dashboard (organisation names, plans, status, member/asset counts), never to
any tenant's actual data (see README, "Privacy boundary").

1. Sign up for a normal account first: open `index.html`, go to **Sign up >
   New organisation**, and create any throwaway organisation with your own
   email and a password you'll remember. (You need an `auth.users` row to
   exist before the next step -- this organisation itself is not used for
   anything; you can ignore or delete it later.)
2. Go to the **SQL Editor** and run:
   ```sql
   insert into public.platform_admins (id, email)
   values ('PASTE-YOUR-USER-UID-HERE', 'your-email@example.com');
   ```
   Get your UID from **Authentication > Users**.
3. Log out and log back in with that same email/password. You should land
   on **AssetIQ Platform Admin** (the master dashboard) instead of a tenant
   dashboard -- a profile row and a platform_admins row both existing for
   the same account is not expected to happen in normal use, but if it
   does, the profile takes priority (see the auth-state-change handler in
   `index.html`), so step 1's throwaway organisation is harmless either way.

`supabase/seed-accounts-template.sql` still exists for reference but is no
longer the primary way to provision accounts -- Section 6 above and the
in-app invite flow (next section) replace it. See the comment at the top of
that file.

## 7. Try it

Double-click `index.html`. **Sign up > New organisation** creates a new
tenant and makes you its Org Manager on a 14-day trial. From **Profile >
Access Checks > Invite a teammate**, generate an invite code and use it
(from a private/incognito window, so you don't sign yourself out) with
**Sign up > Join with invite code** to add a Staff or Viewer account to that
same organisation.

## If something doesn't work

- **Sign-up fails with "email confirmation is required"** -- Step 2's
  "Confirm email" setting is still on. Turn it off, or (for a real
  deployment) implement the email-confirmation screen this demo skips.
- **"This account already belongs to an organisation"** -- the same
  `auth.users` account already has a `profiles` row. One account = one
  organisation membership in this MVP; sign up with a different email to
  create a second one.
- **Signed in, but it says no organisation is set up** -- usually means the
  `create-organization` or `join-organization` Edge Function failed or
  isn't deployed under the exact name in the table in Step 5. Check **Edge
  Functions > [function name] > Logs**.
- **Any error mentioning "row-level security policy"** -- Step 3
  (`supabase.sql`) was skipped, didn't fully run, or an earlier line failed.
  Re-run the whole script -- it's safe to run more than once.
- **"relation ... does not exist"** -- same as above; check the SQL
  Editor's output for the specific line that failed.
- **An invite code says "not found" or "expired"** -- codes are single-use
  and expire after 7 days (`invites.expires_at` in `supabase.sql`); generate
  a new one from Access Checks.
- **"Scan Nameplate" always comes back "unresolved"** -- Step 5b for that
  function, or 5a/5b's `ANTHROPIC_API_KEY` secret, was missed or billing
  wasn't completed. Safe failure, not a crash -- falls back to manual entry.
- **"Failed to send a request to the Edge Function"** -- the function name
  doesn't exactly match the table in Step 5, or its deploy didn't finish.

## A note on the free plan

Supabase pauses a free project after about a week with no activity. If a
demo seems slow or unresponsive the first time, open the project dashboard
on supabase.com and click **Resume**.

## What's genuinely still a demo here

This MVP's subscription model has no real payment provider wired up -- the
Billing screen's "Pay now" collects a fake card number and always succeeds;
no real card processor, no Stripe, no money moves. What IS real: the
credit balance it produces, the per-plan asset limit, and the
checked-and-atomic upgrade that spends that balance -- all enforced in
`supabase.sql`, not just shown by the page. The platform owner can also
still set plan/status by hand from the master dashboard, for support cases
outside the normal flow. See README, "Subscription model: what's real and
what's a placeholder" and "Billing, payments and plan tiers" for the full,
honest version of this, including what a production build would still
need to add (an actual Stripe integration, replacing just the top-up
form -- see that section for exactly where it would slot in).
