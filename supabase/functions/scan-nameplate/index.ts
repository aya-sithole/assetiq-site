// AssetIQ -- scan-nameplate Edge Function
//
// This is the AI integration: it reads manufacturer, model and serial
// number off a photo of an equipment nameplate, using Claude Fable 5.1.
//
// WHY THIS MODEL: chosen on independent third-party evidence, not a
// teammate's test. Roboflow's public Vision Evals OCR benchmark (23 vision
// models, scored against real images, last updated 28 July 2026) ranks
// Claude Fable 5.1 highest overall at 94.0% accuracy, ahead of Claude Opus
// (93.8%) and clear of the mid-tier models. That is a broader, more
// current, independently-run comparison than any single team's manual
// test of a handful of photos.
//
// Two honest limits on that evidence: (1) the benchmark measures general
// OCR and document-extraction ability, not equipment nameplates
// specifically -- grimy, embossed, or steeply-angled metal plates are a
// different domain from the scanned documents such benchmarks typically
// use, so this is the best available signal, not a guarantee for this
// exact use case. (2) Fable sits at the top of Anthropic's current
// pricing tiers, meaningfully above Sonnet per token -- still a small
// absolute cost per single-image scan at MVP volumes, but worth knowing
// before scaling up. If real nameplate photos become available, testing
// this model against them directly (the way Jacques tested his three)
// would turn this from an evidence-based choice into a proven one.
//
// WHY THIS HAS TO BE AN EDGE FUNCTION, NOT CLIENT-SIDE JAVASCRIPT:
// index.html is a static file anyone can view the source of. The
// SUPABASE_ANON_KEY is safe to put there, because every request it makes
// is still checked by Row Level Security (supabase.sql). An Anthropic API
// key has no equivalent protection -- Anthropic bills whoever's key is
// used, with no per-request authorisation check of its own. Putting it in
// index.html would mean anyone who viewed the page source could make
// unlimited Claude calls billed to this project. Running it here instead
// means the key lives only in this function's environment (as a secret,
// never in code), on Supabase's server, where the browser never sees it.
//
// This function re-checks the caller's role itself using the SAME Row
// Level Security rules as everywhere else (it signs its internal query
// with the caller's own access token, not an admin key), so it is not a
// second, separate permission system to keep in sync -- it relies on the
// one in supabase.sql.
//
// SUPABASE_URL and SUPABASE_ANON_KEY are provided automatically in every
// Edge Function's environment -- you do not set those yourself. The one
// secret you DO need to add is ANTHROPIC_API_KEY (see SETUP.md). Unlike
// Gemini, Anthropic's API has no card-free tier -- SETUP.md says so
// plainly where this key is set up.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const CLAUDE_MODEL = "claude-fable-5-1";
const ANTHROPIC_ENDPOINT = "https://api.anthropic.com/v1/messages";
const ANTHROPIC_VERSION = "2023-06-01";

const PROMPT = `You are reading a photograph of an equipment nameplate. Report only
text that is visibly printed on the plate. Preserve printed labels and
characters exactly. If a field cannot be read, or the plate does not show
it, mark it unresolved rather than guessing. Report any other identifiers
you see (job number, machine number) separately from the serial number.

Respond with JSON only -- no markdown code fences, no explanation before or
after it -- in exactly this shape:
{"manufacturer": {"value": "", "status": "read|unresolved", "note": ""},
 "model": {"value": "", "status": "read|unresolved", "note": ""},
 "serial_number": {"value": "", "status": "read|unresolved", "note": ""},
 "other_identifiers": ""}`;

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

function emptyResult(note: string) {
  const unresolved = { value: "", status: "unresolved", note };
  return {
    manufacturer: { ...unresolved },
    model: { ...unresolved },
    serial_number: { ...unresolved },
    other_identifiers: "",
  };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return jsonResponse({ error: "Not authenticated." }, 401);
    }

    // A client scoped to the CALLER's own access token -- not a service
    // role key. The query below is therefore subject to the exact same
    // "read own profile" Row Level Security rule as any other call in
    // this app (see supabase.sql), not a special bypass.
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
    const callerClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authHeader } },
    });

    const { data: userData, error: userErr } = await callerClient.auth.getUser();
    if (userErr || !userData?.user) {
      return jsonResponse({ error: "Not authenticated." }, 401);
    }

    const { data: profile, error: profileErr } = await callerClient
      .from("profiles")
      .select("role")
      .eq("id", userData.user.id)
      .single();

    if (profileErr || !profile) {
      return jsonResponse({ error: "No profile record found for this account." }, 403);
    }

    // Matches the report's scan_create_asset permission: Org Manager and
    // Staff may scan a nameplate to register a new asset; Viewer may not.
    if (profile.role !== "admin" && profile.role !== "user") {
      return jsonResponse(
        { error: "Not authorised for this action (403, enforced by this function)." },
        403,
      );
    }

    const { image, mimeType } = await req.json();
    if (!image) {
      return jsonResponse({ error: "No image supplied." }, 400);
    }

    const anthropicKey = Deno.env.get("ANTHROPIC_API_KEY");
    if (!anthropicKey) {
      // No key configured yet -- fail safely to "unresolved" rather than
      // erroring, so the review screen still works for manual entry.
      return jsonResponse(
        emptyResult("No ANTHROPIC_API_KEY secret is configured for this project yet. Enter details manually."),
      );
    }

    const payload = {
      model: CLAUDE_MODEL,
      max_tokens: 1024,
      messages: [
        {
          role: "user",
          content: [
            { type: "image", source: { type: "base64", media_type: mimeType || "image/jpeg", data: image } },
            { type: "text", text: PROMPT },
          ],
        },
      ],
    };

    const claudeResponse = await fetch(ANTHROPIC_ENDPOINT, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-api-key": anthropicKey,
        "anthropic-version": ANTHROPIC_VERSION,
      },
      body: JSON.stringify(payload),
    });

    if (!claudeResponse.ok) {
      const errBody = await claudeResponse.text();
      // Logged here, not returned to the browser -- it may contain more
      // detail than should be shown to an end user. Visible in Supabase
      // Dashboard > Edge Functions > scan-nameplate > Logs if diagnosing.
      console.error("Anthropic API error:", claudeResponse.status, errBody);
      return jsonResponse(
        emptyResult(`The AI service returned an error (HTTP ${claudeResponse.status}). Enter details manually.`),
      );
    }

    const claudeData = await claudeResponse.json();
    let parsed: Record<string, unknown>;
    try {
      const text = claudeData.content[0].text;
      // Claude sometimes wraps JSON in a markdown fence even when told not
      // to; strip ```json / ``` if present before parsing.
      const cleaned = text.replace(/^```(?:json)?\s*/i, "").replace(/\s*```\s*$/i, "");
      parsed = JSON.parse(cleaned);
    } catch (_err) {
      return jsonResponse(
        emptyResult("The AI service returned something unusable. Enter details manually."),
      );
    }

    for (const field of ["manufacturer", "model", "serial_number"]) {
      if (!parsed[field]) {
        parsed[field] = { value: "", status: "unresolved", note: "Missing from AI response." };
      }
    }
    if (!("other_identifiers" in parsed)) parsed.other_identifiers = "";

    return jsonResponse(parsed);
  } catch (err) {
    return jsonResponse({ error: String(err) }, 500);
  }
});
