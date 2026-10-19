# Hosting AssetIQ on Vercel

This gives the prototype a real public web address (something like
`https://assetiq-demo.vercel.app`) instead of only opening as a local
file. No credit card, no command line.

**Do this *after* completing `SETUP.md`.** Hosting just makes the same
file reachable at a URL; it doesn't replace the Supabase project setup.
Your `index.html` should already have your real `SUPABASE_URL` and
`SUPABASE_ANON_KEY` filled in (not the `PASTE_YOUR_...` placeholders)
before you upload it here.

**One thing to decide first: will you need to update this later?** Vercel's
drag-and-drop tool (Vercel Drop) is extremely simple, but it creates a
brand-new project -- with a brand-new web address -- every time you drop a
folder. There's no "update this same site" button inside Drop itself.
- If this is a one-time submission and you don't expect to touch it again,
  **Part 1** alone is all you need.
- If you expect to fix something or swap in a new Supabase project later
  and want the address to stay the same, do **Part 2** as well, right after
  Part 1 -- it connects the project to a free GitHub repository so future
  changes publish automatically without creating a new link each time, and
  without needing git or a terminal.

## About the Hobby plan's terms

Vercel's free Hobby plan is for personal, non-commercial use; a
revenue-generating product belongs on a paid plan. For a graded class
prototype that isn't taking payments or generating revenue, Hobby is the
appropriate tier -- just worth knowing as this moves beyond coursework.

## Part 1: Get it live

### 1. Put `index.html` in its own folder

Vercel Drop expects a folder, a single file, or a zip. Create a new folder
anywhere on your computer -- call it `assetiq-site`, for example -- and put
only your finished `index.html` inside it.

### 2. Go to Vercel Drop

Open [vercel.com/drop](https://vercel.com/drop) in your browser.

### 3. Drag the folder in

Drag the `assetiq-site` folder onto the page. You'll be asked to sign up
or log in first if you haven't already (a free account, no card) --
Vercel is one of the few drag-and-drop hosts that requires this before
your very first deploy, unlike some alternatives.

### 4. Name it and deploy

Choose a team (your personal account is fine) and a project name -- this
becomes part of the address, e.g. a project named `assetiq-demo` becomes
`assetiq-demo.vercel.app`. Click **Deploy**.

Vercel publishes it within seconds and shows you the live address. Click
through and confirm the login screen appears.

## Part 2 (optional): connect GitHub so you can update it without creating a new link

Skip this if Part 1 is all you need.

### 1. Create a GitHub account if you don't have one

Free, at [github.com](https://github.com/).

### 2. Create a new repository

Click the **+** in GitHub's top-right corner, choose **New repository**,
give it a name (e.g. `assetiq-site`), set it to **Public**, and click
**Create repository**. Don't add a README or any other starter file.

### 3. Upload `index.html` through the browser

On the new repository's page, click **Add file > Upload files**, drag your
`index.html` in, and click **Commit changes**. No git, no terminal --
this is GitHub's own web uploader.

### 4. Connect this repository to your Vercel project

In the Vercel dashboard, open the project you created in Part 1, go to its
**Settings > Git**, and connect it to the GitHub repository you just
created. Vercel will ask for permission to access your GitHub account the
first time -- this is normal and limited to the repository you choose.

From this point on, updating the site means: edit `index.html` in GitHub's
web editor (or repeat Step 3 to re-upload it), commit the change, and
Vercel automatically redeploys the same project at the same address within
moments -- no new link, no dropping a folder again.

## Is it safe to publish the Supabase URL and key in a public page?

Yes, by design. The `SUPABASE_ANON_KEY` is meant to be visible in
client-side code -- Supabase's own documentation calls it the "anon
public" key for exactly that reason. It grants no access by itself; every
request made with it still has to pass the Row Level Security rules in
`supabase.sql`. Anyone who views your page's source will see your Supabase
URL and anon key, and that's expected and fine. What must stay private is
your project's separate **service role key** (used only for
administrative scripts), which never appears anywhere in `index.html`.

## If something doesn't work

- **Blank page or a loading spinner that never finishes** -- open the
  browser's developer console (F12 > Console tab) on the live URL. A
  genuine configuration problem (wrong Supabase URL, wrong key) shows up
  here as a clear error, the same as it would running the file locally.
- **The page loads but sign-in fails in a way it didn't locally** -- this
  is almost never specific to Vercel; re-check `SETUP.md`'s
  troubleshooting section, since the same project configuration applies
  whether the file is opened locally or hosted.
- **"This plan does not support commercial use"-type messages** -- shouldn't
  come up for a coursework prototype; if it does, it means Vercel's
  automated review flagged something about the project as commercial. This
  is a conversation with Vercel support, not a bug in this file.

## Onboarding a new customer (multi-tenant version)

This is the one section that changed when the app became multi-tenant
(see README, "Multi-tenancy, in full"): a new customer does **not** need
their own Supabase project, their own Vercel deployment, or any setup from
you at all. They go to this one hosted URL and use **Sign up > New
organisation** -- `create-organization` (an Edge Function, see `SETUP.md`)
provisions their organisation and Org Manager account automatically. One
deployment, one Supabase project, every customer.

A client running this as part of a real business, rather than a demo,
would still need Vercel's paid Pro plan under its own commercial terms
(the Hobby-plan caveat above still applies to the one shared deployment) --
worth raising directly rather than assuming Hobby covers it.
