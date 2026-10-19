const { JSDOM } = require('jsdom');
const fs = require('fs');

let failures = 0, total = 0;
function check(name, cond) { total++; if (!cond) { failures++; console.log('FAIL  ' + name); } else console.log('ok    ' + name); }

// ---------------------------------------------------------------------
// MULTI-TENANT TEST DOUBLE. This does not and cannot stand in for Row
// Level Security -- Postgres is the only thing that can actually prove
// isolation and permission refusals (that is what the Access Checks
// screen and SETUP.md's manual test script are for, against a real
// Supabase project). What this harness DOES verify, honestly: that the
// page loads without a JavaScript error, that the sign-up and sign-in
// flows drive the right screens for each kind of account (tenant user,
// and the platform owner), and that the screens touched by recent edits
// are actually reachable. See README, "What the automated tests do and
// do not prove" for the same point made at more length.
// ---------------------------------------------------------------------
function makeFakeSupabase() {
  let orgs = [
    { id: 'org-acme', name: 'Acme Co', slug: 'acme-co', plan: 'trial', status: 'active', trial_ends_at: new Date(Date.now() + 9e8).toISOString(), created_at: new Date().toISOString(), credits_balance: 150 },
  ];
  const users = [
    { id: 'uid-admin', email: 'admin@acme.test', password: 'Demo2026pass!', role: 'admin', name: 'Alex Manager', title: 'Fleet & Asset Director', dept: 'Operations Management', organization_id: 'org-acme' },
    { id: 'uid-staff', email: 'demo@acme.test', password: 'Demo2026pass!', role: 'user', name: 'Sam Technician', title: 'Field Technician', dept: 'Operations', organization_id: 'org-acme' },
    { id: 'uid-viewer', email: 'viewer@acme.test', password: 'Demo2026pass!', role: 'viewer', name: 'Riley Auditor', title: 'Compliance Auditor', dept: 'Risk & Compliance', organization_id: 'org-acme' },
  ];
  let profiles = users.map(u => ({ id: u.id, organization_id: u.organization_id, email: u.email, role: u.role, name: u.name, title: u.title, dept: u.dept }));
  let platformAdmins = [];
  let invites = [];
  let assets = [
    { id: 'LPT-4922', organization_id: 'org-acme', name: 'MacBook Pro 16"', icon: '💻', make: 'Apple', model: 'M3 Max', sn: 'SN1', replace: '', location: 'HQ', assigned: 'Sam', condition: 'Good', notes: '', photo: '', active: true, value: 65000 },
  ];
  let tickets = [];
  let auditLog = [];
  let payments = [];
  let authCallback = null;
  let session = null;
  let pendingSignups = {}; // email -> { id, password } for the fake signUp()/signIn() pair
  let nextId = 1000;
  const errors = [];

  const TABLES = { profiles: () => profiles, assets: () => assets, tickets: () => tickets, audit_log: () => auditLog, organizations: () => orgs, invites: () => invites, platform_admins: () => platformAdmins, payments: () => payments };

  function q(table) {
    const state = { table, filters: [], order: null, limitN: null, single: false, maybeSingle: false, countMode: null };
    const data = () => (TABLES[table] ? TABLES[table]() : []);
    const api = {
      select(_cols, opts) { if (opts && opts.count) state.countMode = opts.count; return api; },
      eq(col, val) { state.filters.push([col, val, 'eq']); return api; },
      neq(col, val) { state.filters.push([col, val, 'neq']); return api; },
      order(col, opts) { state.order = { col, asc: !opts || opts.ascending !== false }; return api; },
      limit(n) { state.limitN = n; return api; },
      single() { state.single = true; return api; },
      maybeSingle() { state.maybeSingle = true; return api; },
      in(col, vals) { state.filters.push([col, vals, 'in']); return api; },
      then(resolve) {
        let rows = data().filter(r => state.filters.every(([c, v, op]) => op === 'in' ? v.includes(r[c]) : (op === 'neq' ? r[c] !== v : r[c] === v)));
        if (state.order) rows = rows.slice().sort((a, b) => (a[state.order.col] > b[state.order.col] ? 1 : -1) * (state.order.asc ? 1 : -1));
        if (state.limitN) rows = rows.slice(0, state.limitN);
        if (state.countMode) return resolve({ data: null, count: rows.length, error: null });
        if (state.single) return resolve({ data: rows[0] || null, error: rows[0] ? null : { message: 'No rows' } });
        if (state.maybeSingle) return resolve({ data: rows[0] || null, error: null });
        resolve({ data: rows, error: null });
      },
      insert(rows) {
        const arr = (Array.isArray(rows) ? rows : [rows]).map(r => {
          if (table === 'invites' && !r.code) r = { ...r, code: 'code-' + (nextId++), expires_at: new Date(Date.now() + 6e8).toISOString(), used_by: null, used_at: null };
          if (table === 'organizations' && !r.id) r = { ...r, id: 'org-' + (nextId++), plan: 'trial', status: 'trialing', trial_ends_at: new Date(Date.now() + 1.2e9).toISOString(), created_at: new Date().toISOString(), credits_balance: 0 };
          if (table === 'payments') r = { ...r, id: 'pay-' + (nextId++), status: r.status || 'succeeded', method: r.method || 'card', created_at: new Date().toISOString() };
          return r;
        });
        arr.forEach(r => data().push(r));
        // Mirrors apply_payment_to_balance_trigger in supabase.sql: a
        // succeeded payment is a real balance increase, not just a logged row.
        if (table === 'payments') {
          arr.forEach(r => { if (r.status === 'succeeded') { const o = orgs.find(x => x.id === r.organization_id); if (o) o.credits_balance = (o.credits_balance || 0) + Number(r.amount); } });
        }
        // A real Promise, not a bare object with a `then` method -- so a
        // caller chaining .then(...).catch(...) off this (as runGuarded()
        // does for every insert in index.html) gets proper native Promise
        // chaining, the same as the real supabase-js client's thenable
        // query builder. .select() is attached as an extra property on the
        // same promise so both `insert(...)` and `insert(...).select()`
        // resolve consistently.
        const resultPromise = Promise.resolve({ data: arr, error: null });
        resultPromise.select = () => ({ single: () => Promise.resolve({ data: arr[0], error: null }), then: resultPromise.then.bind(resultPromise), catch: resultPromise.catch.bind(resultPromise) });
        return resultPromise;
      },
      upsert(rows) {
        const arr = Array.isArray(rows) ? rows : [rows];
        arr.forEach(r => { const d = data(); const i = d.findIndex(x => x.id === r.id && x.organization_id === r.organization_id); if (i >= 0) d[i] = r; else d.push(r); });
        return Promise.resolve({ data: arr, error: null });
      },
      update(patch) {
        const target = data().filter(r => state.filters.every(([c, v]) => r[c] === v));
        target.forEach(r => Object.assign(r, patch));
        return { eq: () => api, select: () => Promise.resolve({ data: target, error: null }), then: (res) => res({ data: target, error: null }) };
      },
      delete() {
        return { eq: (c, v) => { const d = data(); const idx = d.findIndex(r => r[c] === v); if (idx >= 0) d.splice(idx, 1); return Promise.resolve({ data: [], error: null }); },
                 in: (c, vals) => { const d = data(); for (let i = d.length - 1; i >= 0; i--) if (vals.includes(d[i][c])) d.splice(i, 1); return Promise.resolve({ data: [], error: null }); } };
      },
    };
    return api;
  }

  async function rpc(name, args) {
    if (name === 'is_platform_owner') return { data: !!(session && platformAdmins.find(p => p.id === session.id)), error: null };
    if (name === 'platform_list_organizations') {
      return { data: orgs.map(o => ({ ...o, member_count: profiles.filter(p => p.organization_id === o.id).length, asset_count: assets.filter(a => a.organization_id === o.id).length, credits_balance: o.credits_balance || 0 })), error: null };
    }
    if (name === 'platform_set_org_status') {
      const o = orgs.find(x => x.id === args.org_id);
      if (o) o.status = args.new_status;
      return { data: null, error: null };
    }
    if (name === 'platform_set_org_plan') {
      const o = orgs.find(x => x.id === args.org_id);
      if (o) o.plan = args.new_plan;
      return { data: null, error: null };
    }
    if (name === 'platform_revenue_summary') {
      const succeeded = payments.filter(p => p.status === 'succeeded');
      return { data: [{ total_revenue: succeeded.reduce((s, p) => s + Number(p.amount), 0), revenue_last_30d: succeeded.reduce((s, p) => s + Number(p.amount), 0), payments_count: succeeded.length, organizations_count: orgs.length }], error: null };
    }
    if (name === 'platform_list_payments') {
      const succeeded = payments.filter(p => p.status === 'succeeded').slice().sort((a, b) => new Date(b.created_at) - new Date(a.created_at));
      return { data: succeeded.slice(0, (args && args.limit_n) || 20).map(p => ({ id: p.id, organization_name: (orgs.find(o => o.id === p.organization_id) || {}).name || '', amount: p.amount, method: p.method, created_at: p.created_at })), error: null };
    }
    // Mirrors upgrade_plan() in supabase.sql: checked and spent atomically
    // against the caller's own organisation, admin only.
    if (name === 'upgrade_plan') {
      const me = session && profiles.find(p => p.id === session.id);
      if (!me || me.role !== 'admin') return { data: null, error: { message: 'Only an Org Manager can change the subscription plan.' } };
      const cost = args.new_plan === 'starter' ? 29 : (args.new_plan === 'pro' ? 99 : null);
      if (cost == null) return { data: null, error: { message: 'Unknown plan: ' + args.new_plan } };
      const o = orgs.find(x => x.id === me.organization_id);
      if (!o || (o.credits_balance || 0) < cost) return { data: null, error: { message: 'Insufficient credit balance: ' + args.new_plan + ' costs ' + cost + ', your balance is ' + (o ? o.credits_balance : 0) + '. Top up first.' } };
      o.credits_balance -= cost; o.plan = args.new_plan; o.status = 'active';
      return { data: [{ plan: o.plan, credits_balance: o.credits_balance }], error: null };
    }
    return { data: null, error: { message: 'Unknown RPC in test double: ' + name } };
  }

  async function invokeFunction(name, { body }) {
    if (name === 'scan-nameplate') return { data: { error: 'Not exercised in this test' }, error: null };
    if (!session) return { data: { error: 'Not authenticated.' }, error: null };
    if (name === 'create-organization') {
      if (profiles.find(p => p.id === session.id)) return { data: { error: 'This account already belongs to an organisation.' }, error: null };
      const org = { id: 'org-' + (nextId++), name: body.orgName, slug: 'slug-' + nextId, plan: 'trial', status: 'trialing', trial_ends_at: new Date(Date.now() + 1.2e9).toISOString(), created_at: new Date().toISOString() };
      orgs.push(org);
      profiles.push({ id: session.id, organization_id: org.id, email: session.user.email, role: 'admin', name: body.name || session.user.email, title: 'Org Manager', dept: '' });
      return { data: { organization: org }, error: null };
    }
    if (name === 'join-organization') {
      if (profiles.find(p => p.id === session.id)) return { data: { error: 'This account already belongs to an organisation.' }, error: null };
      const invite = invites.find(i => i.code === body.inviteCode);
      if (!invite) return { data: { error: 'That invite code was not found.' }, error: null };
      if (invite.used_by) return { data: { error: 'That invite code has already been used.' }, error: null };
      profiles.push({ id: session.id, organization_id: invite.organization_id, email: session.user.email, role: invite.role, name: body.name || session.user.email, title: invite.role === 'viewer' ? 'Viewer' : 'Staff', dept: '' });
      invite.used_by = session.id; invite.used_at = new Date().toISOString();
      return { data: { organization: orgs.find(o => o.id === invite.organization_id), role: invite.role }, error: null };
    }
    return { data: { error: 'Unknown function in test double: ' + name }, error: null };
  }

  return {
    client: {
      auth: {
        onAuthStateChange: (cb) => { authCallback = cb; },
        getSession: async () => ({ data: { session } }),
        refreshSession: async () => { if (authCallback) await authCallback('TOKEN_REFRESHED', session); return { data: { session }, error: null }; },
        getUser: async () => ({ data: { user: session ? { id: session.id } : null }, error: null }),
        signInWithPassword: async ({ email, password }) => {
          const u = users.find(x => x.email === email && x.password === password);
          if (!u) return { data: null, error: { message: 'Invalid login credentials' } };
          session = { id: u.id, user: { id: u.id, email: u.email } };
          if (authCallback) await authCallback('SIGNED_IN', session);
          return { data: { user: session.user, session }, error: null };
        },
        signUp: async ({ email, password }) => {
          const id = 'uid-new-' + (nextId++);
          users.push({ id, email, password, organization_id: null });
          session = { id, user: { id, email } };
          if (authCallback) await authCallback('SIGNED_IN', session); // fires BEFORE a profile exists, on purpose
          return { data: { user: session.user, session }, error: null };
        },
        signOut: async () => { session = null; if (authCallback) await authCallback('SIGNED_OUT', null); return { error: null }; },
      },
      from: q,
      rpc,
      functions: { invoke: async (name, opts) => invokeFunction(name, opts || {}) },
    },
    seedPlatformOwner(email, password) {
      const id = 'uid-owner';
      users.push({ id, email, password, organization_id: null });
      platformAdmins.push({ id, email });
    },
    errors,
  };
}

async function boot(fake, htmlTransform) {
  let html = fs.readFileSync('../index.html', 'utf8');
  if (htmlTransform) html = htmlTransform(html);
  const errors = [];
  const dom = new JSDOM(html, {
    runScripts: 'dangerously', url: 'https://assetiq.test/', pretendToBeVisual: true,
    beforeParse(w) {
      w.supabase = { createClient: () => fake.client };
      w.alert = () => {};
      w.addEventListener('error', e => errors.push(e.message));
    },
  });
  await new Promise(res => { if (dom.window.document.readyState === 'complete') res(); else dom.window.addEventListener('load', res); });
  return { dom, w: dom.window, d: dom.window.document, errors };
}

const active = d => { const a = d.querySelector('.screen.active'); return a ? a.id : null; };

(async () => {
  const fake = makeFakeSupabase();
  fake.seedPlatformOwner('owner@assetiq.app', 'Owner2026pass!');
  const { d, errors } = await boot(fake);
  check('Page loads with no script errors', errors.length === 0);
  if (errors.length) console.log('      error was:', errors[0]);
  check('Starts on the landing screen', active(d) === 'screen-landing');
  check('The old public "Create demo accounts" button is gone', !d.getElementById('btn-run-setup'));
  check('Sign-up screen offers both a Create-org and a Join-with-code mode', !!d.getElementById('signup-mode-create') && !!d.getElementById('signup-mode-join'));
  check('No quick-demo-access chips render with the shipped (blank) DEMO_ACCOUNTS', d.querySelectorAll('.demo-chip').length === 0);

  // Pricing tiles on the landing screen are themselves sign-up buttons.
  const starterTile = d.querySelector('.price-tier[data-plan="starter"]');
  check('Landing page has three clickable plan tiles', d.querySelectorAll('.price-tier').length === 3);
  if (starterTile) {
    starterTile.click();
    check('Clicking the Starter tile reaches the sign-up screen', active(d) === 'screen-signup');
    check('Clicking a paid tier updates the sign-up hint to mention that plan\'s cost', /\$29/.test(d.getElementById('signup-mode-hint').textContent));
    d.querySelector('[data-target="screen-landing"]').click();
  }

  d.querySelector('[data-target="screen-login"]').click();
  for (const [email, label] of [['demo@acme.test', 'Staff'], ['admin@acme.test', 'Org Manager'], ['viewer@acme.test', 'Viewer']]) {
    d.getElementById('username-input').value = email;
    d.getElementById('password-input').value = 'Demo2026pass!';
    d.getElementById('btn-login').click();
    await new Promise(r => setTimeout(r, 50));
    check(`Sign-in as ${label} reaches the dashboard`, active(d) === 'screen-dashboard');
    check(`Sign-in as ${label} shows the right role badge`, d.getElementById('dash-role-badge').textContent === label);
    check(`Sign-in as ${label} shows their organisation's name`, d.getElementById('dash-org-name').textContent === 'Acme Co');
    d.getElementById('btn-logout').click();
    await new Promise(r => setTimeout(r, 20));
    d.querySelector('[data-target="screen-login"]').click();
  }

  // Platform owner: a wholly separate account type, with no profile row
  // at all -- should land on the master dashboard, not the tenant one.
  d.getElementById('username-input').value = 'owner@assetiq.app';
  d.getElementById('password-input').value = 'Owner2026pass!';
  d.getElementById('btn-login').click();
  await new Promise(r => setTimeout(r, 50));
  check('Platform owner reaches the master dashboard, not a tenant dashboard', active(d) === 'screen-master');
  check('Master dashboard lists the seeded organisation', d.getElementById('master-org-list').textContent.includes('Acme Co'));
  d.getElementById('btn-master-logout').click();
  await new Promise(r => setTimeout(r, 20));

  // Sign-up: create a brand new organisation end to end through the real
  // UI handler and the fake create-organization function.
  d.querySelector('[data-target="screen-landing"]') ? null : null;
  const landingSignup = d.querySelector('[data-target="screen-signup"]');
  if (landingSignup) landingSignup.click();
  d.getElementById('signup-name').value = 'Jordan Founder';
  d.getElementById('signup-email').value = 'jordan@newco.test';
  d.getElementById('signup-password').value = 'NewcoPass123!';
  d.getElementById('signup-orgname').value = 'NewCo Logistics';
  d.getElementById('btn-signup').click();
  await new Promise(r => setTimeout(r, 80));
  check('Creating a new organisation via sign-up reaches that org\'s dashboard', active(d) === 'screen-dashboard');
  check('The new organisation\'s name is shown', d.getElementById('dash-org-name').textContent === 'NewCo Logistics');
  check('The sign-up creator becomes Org Manager of the new org', d.getElementById('dash-role-badge').textContent === 'Org Manager');
  d.getElementById('btn-logout').click();
  await new Promise(r => setTimeout(r, 20));
  d.querySelector('[data-target="screen-login"]').click();

  // Sign in as admin and exercise the screens touched by recent edits.
  d.getElementById('username-input').value = 'admin@acme.test';
  d.getElementById('password-input').value = 'Demo2026pass!';
  d.getElementById('btn-login').click();
  await new Promise(r => setTimeout(r, 50));

  d.querySelector('.nav-tab[data-tab="screen-scan-upload"]').click();
  check('Org Manager can open Scan Nameplate', active(d) === 'screen-scan-upload');

  d.getElementById('btn-profile').click();
  d.getElementById('btn-open-security').click();
  await new Promise(r => setTimeout(r, 20));
  check('Org Manager can open Access Checks', active(d) === 'screen-security');
  check('Invite a teammate panel is visible to the Org Manager', d.getElementById('invite-panel').style.display !== 'none');
  d.getElementById('btn-run-checks').click();
  await new Promise(r => setTimeout(r, 100));
  check('Access Checks produced results', d.querySelectorAll('#check-results .test-row').length > 0);

  const createInviteBtn = d.getElementById('btn-create-invite');
  createInviteBtn.click();
  await new Promise(r => setTimeout(r, 50));
  check('Generating an invite code shows a result', /code/i.test(d.getElementById('invite-result').textContent));

  d.querySelector('[data-target="screen-profile"]').click();
  d.getElementById('btn-open-audit').click();
  await new Promise(r => setTimeout(r, 50));
  check('Org Manager can open the Audit Log', active(d) === 'screen-audit');

  // Billing: a dummy top-up should raise the real credit balance shown on
  // screen, and a plan upgrade should spend it -- same balance, same number,
  // not two separate client-side counters that happen to agree.
  d.getElementById('btn-profile').click();
  d.getElementById('btn-open-billing').click();
  await new Promise(r => setTimeout(r, 30));
  check('Org Manager can open Billing & Plan', active(d) === 'screen-billing');
  check('Billing shows the organisation\'s credit balance', /\$150/.test(d.getElementById('billing-balance-box').textContent));

  d.getElementById('billing-card-number').value = '4242 4242 4242 4242';
  d.getElementById('billing-card-expiry').value = '12/30';
  d.getElementById('billing-card-cvc').value = '123';
  d.getElementById('billing-topup-amount').value = '50';
  d.getElementById('btn-billing-pay').click();
  await new Promise(r => setTimeout(r, 50));
  check('A dummy top-up raises the balance by the paid amount', /\$200/.test(d.getElementById('billing-balance-box').textContent));

  d.getElementById('btn-billing-upgrade-starter').click();
  await new Promise(r => setTimeout(r, 50));
  check('Upgrading to Starter spends the cost from the balance', /\$171/.test(d.getElementById('billing-balance-box').textContent));
  check('Upgrading to Starter shows success in the result line', /Upgraded to starter/i.test(d.getElementById('billing-upgrade-result').textContent));

  d.getElementById('btn-profile').click();
  const orgTab = [...d.querySelectorAll('.nav-tab')].find(t => t.textContent.includes('Tickets'));
  if (orgTab) orgTab.click();
  await new Promise(r => setTimeout(r, 30));
  check('Org Manager can open Tickets', active(d) === 'screen-issues-list');
  const openFilterBtn = d.getElementById('filter-open');
  check('An Open filter button exists on the Tickets screen', !!openFilterBtn);
  if (openFilterBtn) {
    openFilterBtn.click();
    check('Clicking "Open" marks it active (the filter listener fired)', openFilterBtn.classList.contains('active'));
  }

  const orgTab2 = [...d.querySelectorAll('.nav-tab')].find(t => t.textContent.includes('Organisation'));
  if (orgTab2) { orgTab2.click(); await new Promise(r => setTimeout(r, 30)); }
  const assetCard = d.querySelector('.asset-card');
  if (assetCard) { assetCard.click(); await new Promise(r => setTimeout(r, 30)); }
  const editBtn = d.getElementById('btn-goto-edit');
  if (editBtn && editBtn.style.display !== 'none') { editBtn.click(); await new Promise(r => setTimeout(r, 30)); }

  check('No JavaScript errors occurred anywhere in this entire run', errors.length === 0);
  if (errors.length) errors.forEach(e => console.log('      error:', e));

  // Quick demo access: a separate boot with a fake "operator-configured"
  // DEMO_ACCOUNTS (the shipped file ships this blank -- see the check
  // above), proving the one-click chip actually drives attemptLogin() and
  // reaches the real dashboard, not a shortcut that bypasses sign-in.
  const fake2 = makeFakeSupabase();
  const injectDemoAccount = html => html.replace(
    /const DEMO_ACCOUNTS = \[[\s\S]*?\];/,
    "const DEMO_ACCOUNTS = [{ label: 'Org Manager', email: 'admin@acme.test', password: 'Demo2026pass!' }];"
  );
  const { d: d2, errors: errors2 } = await boot(fake2, injectDemoAccount);
  const demoChip = d2.querySelector('.demo-chip');
  check('A demo chip renders once DEMO_ACCOUNTS is configured', !!demoChip);
  if (demoChip) {
    demoChip.click();
    await new Promise(r => setTimeout(r, 50));
    check('Clicking a demo chip signs in via the real login path and reaches the dashboard', active(d2) === 'screen-dashboard');
    check('The demo chip signed in as the expected role', d2.getElementById('dash-role-badge').textContent === 'Org Manager');
  }
  check('No JavaScript errors in the quick-demo-access run', errors2.length === 0);

  console.log(`\n${total - failures}/${total} passed`);
  process.exit(failures ? 1 : 0);
})();
