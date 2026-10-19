# AssetIQ -- Supabase-backed prototype (multi-tenant)

Real authentication, a real PostgreSQL database, and real server-side
access control via Row Level Security (RLS) -- now rebuilt again, from the
single-tenant version described through most of this file, into a genuine
**multi-tenant SaaS**: one deployment and one Supabase project serve every
customer ("tenant"/organisation), each sees only its own data, and a
separate **platform owner** account manages tenants from a master
dashboard. See `SETUP.md` for the fifteen-to-twenty-minute, no-terminal
setup, and "Multi-tenancy" below for what changed and why.

Everything below this point, up to "Multi-tenancy, in full", describes the
**single-tenant** version this was built from -- kept rather than deleted,
because the reasoning in it (why Supabase, the Firestore-vs-Postgres RLS
differences, the AI model choice, the account-creation vulnerability and
its fix, the three bugs found and fixed) still applies unchanged to the
multi-tenant version; none of it was undone, only extended. Read the
multi-tenancy sections at the end for what's actually new.

## Why Supabase, specifically now

Two reasons, not one. First, the same Accessibility/Reliability reasoning
that moved the earlier Django build toward Firebase still applies here --
this is a vendor-hosted backend a non-technical client can set up
themselves. Second, and more specific to this project: your teammate's
Backend & Data section already uses Supabase. Building this layer on
Supabase too means the whole group's actual submission can run on one
backend, rather than the Firebase-versus-Supabase inconsistency flagged
earlier in this project. That inconsistency is now resolved by removing
Firebase from the picture entirely, not by papering over it.

The honest trade-off, already flagged when Firebase was first chosen over
Supabase and still true now: Supabase's free tier pauses a project after
about a week of inactivity. `SETUP.md` explains how to wake it back up
before a demonstration. This wasn't a reason to avoid Supabase -- matching
the rest of the group's stack outweighs it -- but it's worth the group
knowing about, and mentioning in the report if relevant.

## A real architectural difference worth knowing, not just a vendor swap

Firestore (the Firebase version's database) has a built-in way to check
*which specific fields* a write is trying to change, which is what let the
Firebase version enforce "Staff may change condition and notes, but not
serial number" directly in its rules file with one line
(`diff().affectedKeys().hasOnly([...])`).

PostgreSQL's Row Level Security -- what Supabase uses -- works at the level
of whole *rows*, not individual *columns*. There's no built-in way to write
an RLS policy that says "allow this update, but only if these particular
columns weren't touched." The standard, documented way to get that
behaviour in Postgres is a **trigger**: a small function that runs before
every update, compares the old and new values of the protected columns, and
raises an error if a column outside someone's allowed set has changed.
That's what `protect_asset_privileged_fields()` in `supabase.sql` does.

This is a genuinely different mechanism, not just different syntax for the
same idea -- and it's worth a sentence or two in the report if the group is
discussing Integration or technical trade-offs between the backends it
considered, since it's a concrete, specific difference between a
document-oriented database (Firestore) and a relational one (PostgreSQL)
that goes beyond "NoSQL vs SQL" as an abstraction.

## A second real difference, found while building the Access Checks screen

Firestore, if a query *could* return a document that fails its security
rule, refuses the entire query outright with a "permission denied" error.
PostgreSQL's Row Level Security instead **silently filters out** rows that
don't satisfy the policy, returning a smaller, successful result rather
than an error. For example: a Staff account running "get all user
profiles" doesn't get refused in Supabase -- it just quietly gets back one
profile (their own), with no error raised at all.

This genuinely changes what "the access check passed" looks like between
the two versions, and the Access Checks screen in this version tests for
the correct thing for each database: an error for the Firebase version, a
row count for this one. Both are legitimate ways for a database to enforce
"you may not see that", but they behave differently enough that code
written assuming one will misbehave silently (not crash, just quietly do
the wrong thing) if pointed at the other. Worth knowing if anyone on the
team works with both.

## AI integration: now implemented, and why it was missing before

Earlier versions of this rebuild (Firebase, then the first Supabase pass)
kept the original teammate prototype's "AI Assistant" chat screen
unchanged -- which was always a scripted keyword-matcher, never a real AI
call. The Django build built earlier in this project *did* implement a
genuine AI integration for nameplate scanning, but that work wasn't
carried forward when the project moved to this architecture, and that gap
went unflagged for several iterations. It's fixed now: **Scan Nameplate**
is a real feature, available from the bottom navigation to Org Manager and
Staff, that sends a photo to an AI model and lets the user review and
confirm the result before anything is saved.

### Why Claude Fable 5.1, specifically

This project went through three positions on the AI model before landing
here, and it's worth being transparent about why, since the reasoning
changed each time:

1. **Gemini 3.1 Flash-Lite**, on your teammate Jacques's own head-to-head
   test against GPT-4.1 mini and Claude Haiku 4.5 -- a real, scored
   comparison, and a reasonable basis for a decision.
2. **Claude Sonnet 5**, when asked to use Claude instead -- but the
   honest reasoning at the time was "Haiku lost, Sonnet is a different,
   untested tier," which is a fair observation, not actual evidence that
   Sonnet is good at this task. No one had tested it.
3. **Claude Fable 5.1** (current), after being asked directly to stop
   anchoring decisions on any one person's test and find the best-supported
   choice instead.

That third step meant going and finding independent evidence rather than
reasoning from what either Jacques or this project's own earlier guesses
had covered. Roboflow's public Vision Evals OCR benchmark scores 23 vision
models against real images and is updated regularly -- as of 28 July 2026,
it ranks **Claude Fable 5.1 highest overall at 94.0% accuracy**, ahead of
Claude Opus (93.8%) and clear of the mid-tier models including Sonnet. That
is a broader, more current, third-party comparison than a single team's
manual test of a handful of photos, and it's the actual basis for this
choice -- not a reaction to what anyone on the team tried first.

**Two honest limits on that evidence, stated plainly:**
- The benchmark measures general OCR and document-extraction ability, not
  equipment nameplates specifically. A grimy, embossed, or steeply-angled
  metal plate is a different domain from the scanned documents such
  benchmarks typically use. This is the best available signal, not a
  guarantee for this exact use case -- the same honest gap that applied to
  every model choice made in this project, including Jacques's own test,
  which was real evidence but only on nine photos.
- Fable sits at the top of Anthropic's current pricing tiers --
  meaningfully more expensive per token than Sonnet, and likely more than
  Gemini. At MVP volumes (occasional single-image scans) the absolute cost
  per scan stays small, but this is worth re-examining if usage scales up
  and a cheaper model's accuracy turns out to be adequate in practice.

If real nameplate photos become available, running them through Fable,
Sonnet, and Gemini the way Jacques tested his three would turn this from
an evidence-based choice into a proven one -- that test doesn't exist yet
for any model used in this project, including this one.

It had to be built as a **Supabase Edge Function**
(`supabase/functions/scan-nameplate/index.ts`), not as more JavaScript in
`index.html`, for a concrete reason: `index.html` is a static file anyone
can view the source of, and the `SUPABASE_ANON_KEY` is safe to put there
only because every request it makes is still checked by Row Level
Security. An Anthropic API key has no equivalent protection -- Anthropic
bills whoever's key is used, with no per-request permission check of its
own. Putting it in `index.html` would let anyone who viewed the page
source run up unlimited charges on your account. This is exactly why your
teammate's AI section specified routing the AI call through a Supabase
Edge Function in the first place -- it isn't an architectural preference,
it's the only way to keep a key off the browser using this stack.
`SETUP.md` section 5 covers deploying it, entirely through Supabase's
dashboard -- no CLI needed, since Supabase added dashboard-based Edge
Function deployment.

The Edge Function re-checks the caller's role itself before calling
Claude, using the SAME Row Level Security rule as everywhere else in this
project (it queries `profiles` using the caller's own access token, not an
elevated key), so this isn't a second permission system to keep in sync --
Viewer is refused by the identical rule that already governs everything
else.

## Account creation: a real vulnerability, found and fixed

Earlier versions of this prototype had a "Create demo accounts & data"
button on the login screen, using Supabase's public sign-up API. That
button existing at all was a mistake: Supabase projects allow public
self-registration by default, and the database rule governing who can
create a `profiles` row only checked "is this your own account ID" -- it
never checked what *role* the row claimed. Together, that meant anyone who
reached the live site could open the browser console, sign themselves up,
and insert their own profile with `role: 'admin'`, becoming a fully
privileged Org Manager with no one's permission.

This surfaced when asked directly why accounts weren't administrator-only,
given that's exactly what Section 1 of the report calls for. It's fixed
two ways, not one, deliberately:

1. **Public sign-up is now disabled at the project level** (`SETUP.md` step
   2) -- the Supabase API itself refuses to create new accounts for anyone
   but the project owner, through the dashboard.
2. **The database policy itself no longer allows self-granted privilege**,
   even as a backup: a self-created profile row can only ever claim the
   Viewer role (`supabase.sql`, the `profiles` insert policy). Belt and
   suspenders -- either protection alone would have closed this, and both
   are in place.

Account creation is now a deliberate, administrator-only process: create
the auth account via the Supabase dashboard, then assign its role by
running `supabase/seed-accounts-template.sql` in the SQL Editor. Slower
than a button, but it's what "the administrator creates accounts" has to
mean for the claim to be true rather than aspirational.

## Two further bugs found while verifying this fix

Checking the account-creation fix meant actually running the file
end-to-end for the first time in several edits, rather than only
syntax-checking it. That surfaced two further problems, both now fixed and
covered by an automated test (`test/run.js`) that loads the real file in a
simulated browser and clicks through it -- 18 checks, all passing:

- **The Supabase connection itself was missing.** A prior edit extracted
  this file's script using a boundary that excluded the
  `SUPABASE_URL`/`SUPABASE_ANON_KEY` constants and the client
  initialization. The two most recent versions handed over before this
  fix would have failed immediately on load, with no working connection to
  Supabase at all. `node --check` (a syntax check) could not catch this,
  because the file was syntactically valid JavaScript -- it just referenced
  a variable that was never declared, which is a runtime error, not a
  syntax error. Caught by actually running the file, not by re-reading it.
- **The Profile button did nothing.** This one is older than the issue
  above -- it was dropped when this project's HTML/JS line was first
  rebuilt from your teammate's original prototype into a Firebase-backed
  version, then carried forward, unnoticed, through every rebuild since
  (Firebase, then this Supabase version, then every AI-model change). Since
  the Audit Log and Access Checks screens are only reachable through
  Profile, both were completely unreachable by clicking through the app in
  every version delivered up to this point, despite passing test suites at
  several of those stages -- the tests run at those stages exercised
  permissions and data, not this specific click path.

Both are now fixed, and the test suite added for this round specifically
exercises the click path that missed them, not just the data and
permission logic underneath.

## A third bug: the whole app had no container

Reported as "the home page feels stretched out," this turned out to be a
real CSS defect, not a design opinion to weigh. The app's outer container
was tagged `class="phone-frame"` in the HTML, but the CSS that actually
constrains it to a neat, phone-shaped box (375×812px, rounded corners, the
dark device border) is written for a class called `.device-simulator` --
a naming mismatch from an earlier rebuild. Since nothing matched, every
screen had no size constraint at all and stretched to fill the entire
browser window, so a few short items (a title, a line of text, two
buttons) ended up spread across whatever height the viewer's screen
happened to be, rather than sitting in the compact layout they were
designed for. Fixed by correcting the class name; confirmed by actually
rendering the page as an image before and after, not just reading the CSS.

Worth flagging separately from the bug fix: this restores the app to a
**fixed-size, phone-shaped mockup centred on the page** -- which is how
your teammate's original prototype was designed, and reasonable for
demonstrating a mobile app concept, but it means the app does not stretch
to fill a desktop browser window the way an ordinary responsive website
would. If the long-term intent is a real desktop-usable web app rather
than a phone-app mockup, that's a separate, larger redesign -- worth
raising directly if that's the direction this should go.

## What this prototype does

| Layer | What's implemented |
|---|---|
| Authentication | Supabase Auth, email + password. Supabase handles password hashing and storage -- this project never sees or stores a password itself |
| Access control | Three roles (Org Manager, Staff, Viewer), enforced by PostgreSQL Row Level Security -- not by this page's JavaScript, which only hides buttons as a convenience |
| Field-level rule | Staff may change condition, notes and photo on any asset; only Org Manager may change serial number, assignment, location, replacement cycle or name. Enforced by a Postgres trigger (see above) -- a tampered request that includes an extra field is rejected by the database, not merely ignored by the form |
| Audit log | A real `audit_log` table with no update or delete policy at all, for any role -- genuinely append-only, including for the Org Manager account. Every sign-in, sign-out, refusal and change is recorded |
| Reporting | A real CSV download, generated from live Supabase data, scoped by role (Staff/Viewer get no value column) |
| One-time setup | "Reset demo data" (Access Checks) seeds sample assets/tickets for the signed-in account's own organisation -- accounts themselves are now created by sign-up/invite, not by this button (see "Multi-tenancy" below) |

## What is NOT the same as the Django version, and why

The same two limitations as the Firebase version, for the same reasons --
neither is specific to which vendor was picked:

- **Session idle timeout is client-side only.** Supabase Auth doesn't give
  a static page a way to enforce "sign out after N minutes idle" on its
  own; that would need a server-side function. The on-screen countdown and
  automatic sign-out are real, but a valid Supabase session token could be
  used past that point via a direct API call.
- **Login lockout (three attempts, 30 seconds) is client-side**, tracked in
  memory, reset by a page reload. Supabase has its own project-level rate
  limiting on auth endpoints as an undocumented backstop, but the visible
  30-second lockout here is a UI feature, not a database-enforced guarantee.
- **The "Access Checks" screen cannot fully reproduce T4** in one sitting,
  since it can only test as whichever single account is currently signed
  in. Follow the manual test script on the same screen -- sign in as each
  role in turn -- to properly exercise cross-role denial.
- **The AI *Assistant chat screen* is still the original scripted
  keyword-matcher**, not a real AI call -- this is a different feature
  from Scan Nameplate, which now does make a real Claude call. The
  valuation figure the chat assistant reports is computed live from real
  Supabase data, which is the one genuine improvement to it.
- **Scan Nameplate's field-level write behaviour is new and worth
  understanding:** Staff may set manufacturer, model and serial number
  freely when *registering a brand-new asset* through this flow, since
  providing those details is the entire point of the feature. The
  trigger-based restriction in `supabase.sql` still applies to *editing*
  an asset afterwards -- including one Staff just created themselves --
  so this isn't a hole in the field-level rule, but it's a distinction
  worth being able to explain if asked.

## What HAS been tested, and what has not

This sandbox has no network access to Supabase's domains and no Supabase
account of its own, so **the app has never been run against a live
Supabase project, and the two bugs described above show why that matters**
-- both would have been caught instantly by anyone clicking through a real
deployment, but neither was visible from reading the code or from a syntax
check alone.

What *is* now actually tested, as of this round, using a simulated
Supabase client standing in for the real one: `test/run.js` loads the
genuine `index.html` into a real DOM (via jsdom) and clicks through it --
signing in as all three roles, reaching every screen including Scan
Nameplate, Access Checks, Audit Log and Tickets, and confirming zero
JavaScript errors across the whole run. This is real evidence the
front-end code runs correctly, in a way "the syntax is valid" never was.

What this testing does NOT cover: the fake Supabase client mimics the real
one's request/response shapes, but it does not enforce Row Level Security
the way a real Postgres database does -- so this confirms the JavaScript
runs correctly, not that `supabase.sql`'s rules behave exactly as reasoned
through. That part is still evidenced the way it's described below, not
run.

- The HTML's tags are correctly balanced and all fifteen screens are
  present.
- The SQL was written and reasoned through against PostgreSQL's and
  Supabase's documented behaviour -- including the two RLS-versus-Firestore
  differences described above, which only became apparent while working
  through exactly how each check should behave on this database rather
  than copying the Firebase version's logic across unchanged.
- The Edge Function's TypeScript was checked for balanced syntax only (no
  Deno runtime is available in this sandbox to actually execute it). Its
  logic follows Supabase's documented Edge Function patterns (the
  auto-provided `SUPABASE_URL`/`SUPABASE_ANON_KEY` environment variables,
  the `esm.sh` import style, `Deno.serve`), and the Anthropic Messages API
  call inside it follows Anthropic's documented request shape (the
  `x-api-key` header, the `anthropic-version` header, image content
  blocks) -- but the live round trip to Claude, through this specific
  function, has not been run, and no Anthropic account was available here
  to test it against.

**Please treat the first real run of this as a test, not a demo**, and
report back anything that doesn't work as described -- particularly error
messages from the browser console or the Supabase SQL Editor, which will
say exactly what was rejected and why.

## Files

```
index.html                                      The whole application -- open this in a browser
supabase.sql                                     The real access-control enforcement, now organisation-
                                                  scoped throughout -- paste into Supabase Dashboard >
                                                  SQL Editor and run once, against a FRESH project
supabase/functions/scan-nameplate/index.ts       The AI integration -- unchanged by multi-tenancy
supabase/functions/create-organization/index.ts  Turns a freshly signed-up account into a new
                                                  organisation's Org Manager (SETUP.md step 5)
supabase/functions/join-organization/index.ts    Turns a freshly signed-up account into a Staff/Viewer
                                                  member via an invite code (SETUP.md step 5)
supabase/seed-accounts-template.sql              Mostly superseded by sign-up/invite -- still used to
                                                  bootstrap the platform owner (SETUP.md step 6)
SETUP.md                                         Step-by-step project setup (no terminal), multi-tenant
HOSTING.md                                       Putting this on a public web address (Vercel)
test/run.js                                      Automated test suite -- loads the real index.html in a
                                                  simulated browser, signs in as each tenant role AND as
                                                  the platform owner, and runs a sign-up flow end to end;
                                                  run with `node run.js` from inside test/ (needs
                                                  `npm install jsdom` first). See "What the automated
                                                  tests do and do not prove" below.
README.md                                        This file
```

## Multi-tenancy, in full

The sections above describe a **single-tenant** installation: one Supabase
project, one customer, one set of three demo accounts. That is `SETUP.md`'s
closing section's "Model 1" -- a separate installation per client. This
version is **Model 2**: one shared deployment, many customers
("organisations"), each tenant sees only its own data, and the whole thing
runs under a subscription model with a platform owner who can see and
manage tenants without ever seeing their data.

### What changed in the data model

Every table that used to hold one organisation's data now holds everyone's,
scoped by a new `organization_id` column: `profiles`, `assets`, `tickets`
and `audit_log` all gained it, and three new tables appeared --
`organizations` (one row per tenant, including its subscription `plan` and
`status`), `platform_admins` (who operates the platform, entirely separate
from any tenant), and `invites` (single-use codes an Org Manager generates
to add a teammate without touching SQL). `assets`' primary key changed from
a globally-unique `id` to the pair `(organization_id, id)`, since two
different tenants seeding the same demo data would otherwise collide on a
single global key -- `tickets.asset_id` became a composite foreign key to
match. This is a breaking schema change, not an `ALTER`; see `SETUP.md`.

**Isolation is enforced by Row Level Security, not by the application.**
Every policy in `supabase.sql` for these four tables is written
`organization_id = my_org_id() AND ...`, never just `...` -- structurally,
it is hard to accidentally write a policy that leaks across tenants,
because the org check is always the first clause, not an afterthought. The
Access Checks screen includes a real round-trip test of this ("Tenant
isolation: cannot see any other organisation's row"), not just a read of
the policy text.

### Sign-up, revisited for multi-tenancy

The single-tenant version's whole security fix (see "Account creation: a
real vulnerability, found and fixed" above) rested on turning public
sign-up **off** entirely, because the only thing stopping a self-signed-up
account from granting itself `admin` was "don't let anyone sign up in the
first place." A subscription SaaS product has to let people sign
themselves up -- that constraint can't survive unchanged.

What actually carries the security property forward is **not** "no
self-service", it's **"a self-signed-up account can never choose its own
role or organisation."** Sign-up is back on (`SETUP.md` step 2, the
opposite of the single-tenant version), but no `profiles` row can be
created directly by a client anymore -- the RLS INSERT policy for
`profiles` was removed outright. Every profile is now created by one of two
Edge Functions, each running with the service role key (full database
privileges, bypassing RLS by design, the same trust level the single-tenant
version gave only to an administrator typing SQL by hand):

- **`create-organization`** always creates a **brand-new** organisation and
  makes the caller its `admin` -- it has no code path that accepts an
  existing `organization_id` from the caller, so it cannot be used to join
  or escalate within someone else's tenant.
- **`join-organization`** only ever applies the role attached to one
  specific, unused, unexpired invite code that an *existing* admin already
  created for their own organisation -- the caller supplies a code, never a
  role or an organisation directly.

Neither function lets a request body say "make me an admin of organisation
X" and have that be honoured. That is the same invariant the single-tenant
fix protected, just moved from "stop sign-up" to "constrain what sign-up
can produce" -- arguably a more realistic security boundary for a real SaaS
product than relying on sign-up being off at all.

### Subscription model: what's real and what's a placeholder

`organizations.plan` (trial/starter/pro) and `organizations.status`
(trialing/active/suspended/canceled) are real columns, really enforced:
`org_active()` in `supabase.sql` is checked by every `assets`/`tickets`
read and write policy, so a suspended organisation genuinely loses access
to its own data -- a real refusal from Postgres (and a banner on the
dashboard explaining why), not a cosmetic UI lock. New organisations start
`trialing` with a 14-day `trial_ends_at`.

What is **honestly not built**, and should be said plainly rather than
implied: there is no payment gateway. Nothing charges a card, nothing
automatically moves an organisation from `trialing` to `active` or
`suspended` when a trial ends or a payment fails -- the platform owner sets
`status` by hand from the master dashboard. In a real product this field
would be updated by a webhook from a billing provider (Stripe is the
obvious choice, and would slot in cleanly: a webhook handler would be
another small Edge Function calling the same `platform_set_org_status()`
path, or writing to `organizations` directly with the service role key).
Building that integration was out of scope for an MVP assignment with no
real payment processor account to test against -- flagged here rather than
left for someone to discover the gap later.

### The master dashboard, and its privacy boundary

A platform owner is a `platform_admins` row, not a `profiles` row --
deliberately a different *kind* of account, not an admin-with-extra-powers.
Logging in as one skips the tenant dashboard entirely and lands on
**AssetIQ Platform Admin**, which lists every organisation's name, plan,
status, trial date and two aggregate counts (members, assets), and lets the
owner set an organisation's status (the subscription-enforcement hook
above).

**What it deliberately does not show: any tenant's actual data.** No
asset, no ticket, no audit log entry, not even for troubleshooting. Two
things enforce this, not one: `platform_list_organizations()` only ever
`select`s aggregate counts, never row contents, from inside a
`security definer` function the client cannot bypass to query those tables
directly; and even if it did, the underlying RLS policies on `assets`,
`tickets` and `audit_log` never grant `is_platform_owner()` access at all
-- only `organizations` does. This was a deliberate design choice, not the
only option: a real support team often does need some way to see into a
customer's data to help them, and this version doesn't provide one. If that
were ever needed, the honest way to add it would be a scoped, logged,
time-limited "support access" grant a customer explicitly turns on --
not a blanket platform-owner read policy on tenant tables.

### What the automated tests do and do not prove

`test/run.js` was extended for this round: beyond the three tenant roles,
it now signs in as a seeded platform owner and checks it lands on the
master dashboard (not a tenant one) and that the dashboard lists the
seeded organisation; it also runs a full sign-up ("New organisation") end
to end against a fake `create-organization` function and checks the new
organisation's name and Org Manager role actually appear. All 28 checks
pass as of this version.

The same limitation as before still applies, stated plainly rather than
left implicit: the fake Supabase client this test drives mimics
request/response shapes, including fake versions of the three Edge
Functions -- it does **not** run real Row Level Security. It is evidence
the JavaScript runs correctly end to end (sign-up, org creation, invite
flow, master dashboard, every screen click path), not evidence that
`supabase.sql`'s policies behave exactly as reasoned through against a real
Postgres database. That second kind of evidence is what the Access Checks
screen's real round-trips, and SETUP.md's manual test script, are for --
against an actual Supabase project, which this sandbox cannot reach.
