// AssetIQ -- join-organization Edge Function
//
// Turns a freshly signed-up auth user into a Staff or Viewer member of an
// EXISTING organisation, using a single-use invite code that organisation's
// own Org Manager generated (Access Checks screen > Invite a teammate).
//
// Same reasoning as create-organization for why this runs server-side with
// the service role key rather than as a client insert under RLS: the role
// and organization_id a caller ends up with must come from something an
// existing admin already created (the invite row), never from a value the
// caller supplies directly. This function reads the invite, checks it is
// unused and unexpired, and only then creates the profile -- the caller
// never gets to pick their own role or organisation_id.

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

    const callerClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: userData, error: userErr } = await callerClient.auth.getUser();
    if (userErr || !userData?.user) return jsonResponse({ error: "Not authenticated." }, 401);
    const user = userData.user;

    const adminClient = createClient(supabaseUrl, serviceRoleKey);

    const { data: existingProfile } = await adminClient
      .from("profiles")
      .select("id")
      .eq("id", user.id)
      .maybeSingle();
    if (existingProfile) {
      return jsonResponse({ error: "This account already belongs to an organisation." }, 409);
    }

    const { inviteCode, name } = await req.json();
    const code = String(inviteCode || "").trim();
    if (!code) return jsonResponse({ error: "Invite code is required." }, 400);

    const { data: invite, error: inviteErr } = await adminClient
      .from("invites")
      .select("*")
      .eq("code", code)
      .maybeSingle();

    if (inviteErr || !invite) {
      return jsonResponse({ error: "That invite code was not found." }, 404);
    }
    if (invite.used_by) {
      return jsonResponse({ error: "That invite code has already been used." }, 410);
    }
    if (new Date(invite.expires_at).getTime() < Date.now()) {
      return jsonResponse({ error: "That invite code has expired. Ask your Org Manager for a new one." }, 410);
    }

    const { data: org } = await adminClient
      .from("organizations")
      .select("id, name, status")
      .eq("id", invite.organization_id)
      .single();
    if (!org) return jsonResponse({ error: "The organisation for this invite no longer exists." }, 404);

    const { error: profileErr } = await adminClient.from("profiles").insert([{
      id: user.id,
      organization_id: invite.organization_id,
      email: user.email,
      role: invite.role,
      name: String(name || "").trim() || (user.email ?? ""),
      title: invite.role === "viewer" ? "Viewer" : "Staff",
      dept: "",
    }]);
    if (profileErr) {
      console.error("join-organization: profiles insert failed:", profileErr);
      return jsonResponse({ error: "Could not create your profile." }, 500);
    }

    await adminClient
      .from("invites")
      .update({ used_by: user.id, used_at: new Date().toISOString() })
      .eq("code", code);

    return jsonResponse({ organization: { id: org.id, name: org.name }, role: invite.role });
  } catch (err) {
    return jsonResponse({ error: String(err) }, 500);
  }
});
