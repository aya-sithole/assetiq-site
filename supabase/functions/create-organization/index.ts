// AssetIQ -- create-organization Edge Function
//
// WHAT THIS DOES: turns a freshly signed-up auth user (sb.auth.signUp()
// already succeeded on the client, so a valid session exists) into the
// very first member -- the Org Manager -- of a BRAND NEW organisation.
//
// WHY THIS HAS TO RUN SERVER-SIDE, WITH THE SERVICE ROLE KEY, RATHER THAN
// AS A CLIENT INSERT UNDER ROW LEVEL SECURITY:
// Creating an organisation and the caller's own 'admin' profile row has to
// happen as a single, atomic, trusted operation. If this were instead two
// ordinary client calls under RLS (insert into organizations, then insert
// into profiles with role='admin'), nothing would stop a signed-up user
// from skipping the first call and inserting a profiles row pointing at
// SOMEONE ELSE'S existing organization_id instead -- which is exactly the
// privilege-escalation shape the single-tenant version's security fix
// closed (see README). Routing it through one function using the service
// role key (which bypasses RLS entirely, the same trust level as an
// administrator running SQL by hand) means there is exactly one way to
// become an org's first admin, and it can only ever create a NEW
// organisation -- it has no code path that lets a caller choose an
// existing organization_id for themselves.
//
// This function does not accept a password or create the auth user itself
// -- the client calls supabase.auth.signUp() first (ordinary Supabase
// Auth, unrelated to this function), and only calls this function
// afterwards, with that session's access token, to provision the
// organisation and profile. If signUp() fails (e.g. weak password, email
// already registered), this function is never reached.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function slugify(name: string): string {
  const base = name.toLowerCase().trim().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "") || "org";
  return base.slice(0, 40) + "-" + Math.random().toString(36).slice(2, 7);
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) return jsonResponse({ error: "Not authenticated." }, 401);

    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

    // Identify the caller using their OWN token first -- never trust a
    // user id supplied in the request body.
    const callerClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: userData, error: userErr } = await callerClient.auth.getUser();
    if (userErr || !userData?.user) return jsonResponse({ error: "Not authenticated." }, 401);
    const user = userData.user;

    // A second, privileged client, used ONLY for the two inserts below.
    // This is the one and only place in this Edge Function the service
    // role key is used -- it never touches the request/response bodies.
    const adminClient = createClient(supabaseUrl, serviceRoleKey);

    // Guard: a caller who already has a profile cannot create (or join)
    // another organisation through this path. One auth account = one
    // organisation membership in this MVP.
    const { data: existingProfile } = await adminClient
      .from("profiles")
      .select("id")
      .eq("id", user.id)
      .maybeSingle();
    if (existingProfile) {
      return jsonResponse({ error: "This account already belongs to an organisation." }, 409);
    }

    const { orgName, name } = await req.json();
    if (!orgName || !String(orgName).trim()) {
      return jsonResponse({ error: "Organisation name is required." }, 400);
    }

    const { data: org, error: orgErr } = await adminClient
      .from("organizations")
      .insert([{ name: String(orgName).trim(), slug: slugify(String(orgName)) }])
      .select()
      .single();
    if (orgErr || !org) {
      console.error("create-organization: organizations insert failed:", orgErr);
      return jsonResponse({ error: "Could not create the organisation." }, 500);
    }

    const { error: profileErr } = await adminClient.from("profiles").insert([{
      id: user.id,
      organization_id: org.id,
      email: user.email,
      role: "admin",
      name: String(name || "").trim() || (user.email ?? ""),
      title: "Org Manager",
      dept: "",
    }]);
    if (profileErr) {
      // Roll back the orphaned organisation row rather than leave a
      // half-created tenant with no members.
      await adminClient.from("organizations").delete().eq("id", org.id);
      console.error("create-organization: profiles insert failed:", profileErr);
      return jsonResponse({ error: "Could not create your Org Manager profile." }, 500);
    }

    return jsonResponse({ organization: { id: org.id, name: org.name, slug: org.slug } });
  } catch (err) {
    return jsonResponse({ error: String(err) }, 500);
  }
});
