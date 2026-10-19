// AssetIQ -- ai-copilot Edge Function
//
// WHAT THIS DOES: a real, Claude-backed conversation, in two modes
// selected by the request body's `scope`:
//
// - scope: "platform" -- a Customer Discovery co-pilot for the
//   PLATFORM OWNER, applying Steve Blank's Customer Development
//   methodology (specifically its first phase, Customer Discovery) to
//   AssetIQ itself: hypotheses about customer/problem/solution,
//   "get out of the building" interview logging, a running Business
//   Model Canvas, and pivot-or-persevere decisions. This mode can also
//   call tools that write to discovery_hypotheses / discovery_interviews
//   / discovery_canvas / discovery_decisions (see supabase/copilot-
//   upgrade.sql) -- a genuinely agentic co-pilot, not just a chat
//   window bolted onto static forms.
//
// - scope: "tenant" -- a lighter-touch upgrade of the old, purely
//   scripted "AI Assist" chat: grounded Q&A about THIS organisation's
//   own assets and tickets. No framework overlay, no tools -- just a
//   real model instead of keyword matching.
//
// WHY THIS HAS TO BE AN EDGE FUNCTION: same reason as scan-nameplate --
// the ANTHROPIC_API_KEY secret must never reach the browser. See that
// function's header comment for the full argument.
//
// WHY THIS DOES NOT USE THE SERVICE ROLE KEY, UNLIKE create-organization
// /join-organization: everything this function reads and writes --
// the platform owner's own discovery_* rows and copilot_messages, or a
// tenant's own assets/tickets/copilot_messages -- goes through a
// Supabase client scoped to the CALLER's own access token. Row Level
// Security (supabase.sql / supabase/copilot-upgrade.sql) is what
// actually decides what this function can see and change, exactly as
// it would for a direct client call -- this function is a relay to the
// Claude API and a place to keep ANTHROPIC_API_KEY secret, not a
// second, elevated-privilege access path. If a policy ever changed to
// deny the caller something, this function would be denied it too.
//
// A NOTE ON THE TOOL-USE LOOP: Claude can ask to call a tool (e.g.
// save_hypothesis) instead of replying with text immediately. This
// function executes that tool against the database AS THE CALLER, feeds
// the result back, and lets Claude continue -- up to MAX_TOOL_ROUNDS
// times, so a confused model can't loop forever. Only the original user
// message and the FINAL text reply are saved to copilot_messages; the
// tool-call plumbing in between is not persisted as chat history, but
// which tools fired is returned to the client so the UI can show e.g.
// "✓ saved hypothesis" under the reply.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// Sonnet, not Fable: this is an iterative back-and-forth chat (and, for
// the platform-owner mode, a short tool-use loop per turn), not a
// single-shot vision task. Sonnet is Anthropic's "smart, efficient
// model for everyday use" -- the right cost/latency trade-off for a
// conversational co-pilot that may be called many times per session,
// where scan-nameplate's one-shot-per-asset OCR justified reaching for
// the more expensive Fable instead (see that function's header comment).
const CLAUDE_MODEL = "claude-sonnet-5";
const ANTHROPIC_ENDPOINT = "https://api.anthropic.com/v1/messages";
const ANTHROPIC_VERSION = "2023-06-01";
const MAX_TOOL_ROUNDS = 4;
const MAX_HISTORY = 20;

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

// ---------------------------------------------------------------------
// Tools available to the PLATFORM-OWNER mode only. Each one maps
// directly onto one of the discovery_* tables in supabase/copilot-
// upgrade.sql -- Claude decides WHEN to call these based on the system
// prompt's instructions; the function below just carries them out,
// scoped by the caller's own RLS the same as everything else.
// ---------------------------------------------------------------------
const DISCOVERY_TOOLS = [
  {
    name: "save_hypothesis",
    description:
      "Create a new customer-discovery hypothesis, or update an existing one by id. Use this whenever the founder states or refines a testable belief about WHO the customer is, WHAT problem they have, and WHAT solution is proposed -- not for vague statements that haven't been made specific yet.",
    input_schema: {
      type: "object",
      properties: {
        id: { type: "string", description: "Existing hypothesis id to update. Omit to create a new one." },
        customer_segment: { type: "string" },
        problem_statement: { type: "string" },
        solution_statement: { type: "string" },
        status: { type: "string", enum: ["untested", "testing", "validated", "invalidated"] },
      },
    },
  },
  {
    name: "log_interview",
    description:
      "Log one real 'get out of the building' customer interview the founder reports having actually had -- who it was with, what was discussed, and what was genuinely learned (confirmed, disconfirmed, or surprising). Do not call this for a hypothetical or planned interview that hasn't happened yet.",
    input_schema: {
      type: "object",
      properties: {
        hypothesis_id: { type: "string", description: "Which hypothesis this interview was testing, if known." },
        interviewee: { type: "string", description: "Who was interviewed (role/company is fine, a full name is not required)." },
        notes: { type: "string" },
        learning: { type: "string", description: "What was actually learned, in the founder's own words." },
      },
      required: ["interviewee", "notes"],
    },
  },
  {
    name: "update_canvas_block",
    description: "Update one block of AssetIQ's own Business Model Canvas as the founder's thinking on it firms up.",
    input_schema: {
      type: "object",
      properties: {
        block_key: {
          type: "string",
          enum: [
            "customer_segments", "value_proposition", "channels", "customer_relationships",
            "revenue_streams", "key_resources", "key_activities", "key_partners", "cost_structure",
          ],
        },
        content: { type: "string" },
      },
      required: ["block_key", "content"],
    },
  },
  {
    name: "record_decision",
    description:
      "Record a pivot-or-persevere decision. Only call this once the founder has explicitly made the call, with a rationale grounded in real evidence (interviews, the real revenue/signup data provided) -- never on your own initiative, and never for a decision still being discussed.",
    input_schema: {
      type: "object",
      properties: {
        decision: { type: "string", enum: ["persevere", "pivot"] },
        rationale: { type: "string" },
      },
      required: ["decision", "rationale"],
    },
  },
];

const CANVAS_BLOCKS = [
  "customer_segments", "value_proposition", "channels", "customer_relationships",
  "revenue_streams", "key_resources", "key_activities", "key_partners", "cost_structure",
];

async function executeTool(
  client: ReturnType<typeof createClient>,
  userId: string,
  name: string,
  input: Record<string, unknown>,
): Promise<{ summary: string; resultText: string; isError: boolean }> {
  try {
    if (name === "save_hypothesis") {
      const patch: Record<string, unknown> = { updated_at: new Date().toISOString() };
      for (const k of ["customer_segment", "problem_statement", "solution_statement", "status"]) {
        if (input[k] !== undefined) patch[k] = input[k];
      }
      if (input.id) {
        const { data, error } = await client.from("discovery_hypotheses").update(patch).eq("id", input.id).select().single();
        if (error) throw error;
        return { summary: "Updated hypothesis", resultText: JSON.stringify(data), isError: false };
      }
      const { data, error } = await client.from("discovery_hypotheses").insert([{ ...patch, created_by: userId }]).select().single();
      if (error) throw error;
      return { summary: "Saved a new hypothesis", resultText: JSON.stringify(data), isError: false };
    }
    if (name === "log_interview") {
      const { data, error } = await client.from("discovery_interviews").insert([{
        hypothesis_id: input.hypothesis_id || null,
        interviewee: String(input.interviewee || ""),
        notes: String(input.notes || ""),
        learning: String(input.learning || ""),
        created_by: userId,
      }]).select().single();
      if (error) throw error;
      return { summary: "Logged an interview with " + (input.interviewee || "someone"), resultText: JSON.stringify(data), isError: false };
    }
    if (name === "update_canvas_block") {
      if (!CANVAS_BLOCKS.includes(String(input.block_key))) {
        return { summary: "Rejected an unknown canvas block", resultText: "Unknown block_key: " + input.block_key, isError: true };
      }
      const { data, error } = await client.from("discovery_canvas")
        .upsert([{ block_key: input.block_key, content: String(input.content || ""), updated_by: userId, updated_at: new Date().toISOString() }], { onConflict: "block_key" })
        .select().single();
      if (error) throw error;
      return { summary: "Updated the " + input.block_key + " canvas block", resultText: JSON.stringify(data), isError: false };
    }
    if (name === "record_decision") {
      const { data, error } = await client.from("discovery_decisions").insert([{
        decision: input.decision, rationale: String(input.rationale || ""), created_by: userId,
      }]).select().single();
      if (error) throw error;
      return { summary: "Recorded a decision to " + input.decision, resultText: JSON.stringify(data), isError: false };
    }
    return { summary: "Unknown tool", resultText: "Unknown tool: " + name, isError: true };
  } catch (err) {
    // A real refusal from Postgres (e.g. RLS) comes through here exactly
    // like any other failed call in this app -- reported back to Claude
    // as a tool error, not swallowed, and never retried with elevated
    // privilege.
    return { summary: "Could not complete: " + name, resultText: "Database refused this: " + String((err as Error).message || err), isError: true };
  }
}

async function callClaude(anthropicKey: string, system: string, messages: unknown[], tools: unknown[]) {
  const payload: Record<string, unknown> = { model: CLAUDE_MODEL, max_tokens: 1200, system, messages };
  if (tools.length) payload.tools = tools;
  const resp = await fetch(ANTHROPIC_ENDPOINT, {
    method: "POST",
    headers: { "content-type": "application/json", "x-api-key": anthropicKey, "anthropic-version": ANTHROPIC_VERSION },
    body: JSON.stringify(payload),
  });
  if (!resp.ok) {
    const body = await resp.text();
    console.error("Anthropic API error:", resp.status, body);
    throw new Error("The AI service returned an error (HTTP " + resp.status + ").");
  }
  return await resp.json();
}

function buildPlatformSystemPrompt(data: Record<string, unknown>): string {
  return `You are a Customer Discovery co-pilot for the founder of AssetIQ (this very SaaS product), applying Steve Blank's Customer Development methodology -- specifically its first phase, Customer Discovery.

Your job is to coach the methodology, not to discuss code or software features. Hold the founder to its discipline:
1. Turn vague beliefs into falsifiable hypotheses: WHO the customer segment is, WHAT problem they have, WHAT solution is proposed. Push for specificity ("facilities managers at mid-size manufacturers" beats "businesses"). Call save_hypothesis whenever one is stated or refined -- don't just describe it back, actually save it.
2. Insist on "getting out of the building": real conversations with real prospective customers, not surveys or guesses, and not only talking to people who already like the idea. When the founder reports back from a real conversation, call log_interview and specifically ask what was DISCONFIRMED, not just confirmed.
3. Keep the Business Model Canvas current with update_canvas_block as hypotheses firm up -- don't let it go stale while the conversation moves on to something else.
4. Only once there is real evidence (not a guess) push the founder toward an explicit pivot-or-persevere call, and use record_decision only once they have actually made it, with a rationale tied to evidence -- not to call it for them.
5. Ground your coaching in the REAL data about this business below -- e.g. a trial that never converts is a signal to question the hypothesis, not a sales problem. Treat vanity metrics (raw signups) with more suspicion than hard ones (paid conversion, revenue).

Tone: direct and Socratic, a little impatient with hand-waving -- a demanding but good mentor running discovery, not a cheerleader. Ask one sharp question at a time. Use the tools whenever the founder states something tool-worthy; don't narrate what you would log, actually log it.

Current real data about AssetIQ:
${JSON.stringify(data, null, 2)}`;
}

function buildTenantSystemPrompt(org: Record<string, unknown>, role: string, data: Record<string, unknown>): string {
  return `You are the AssetIQ Assistant for "${org.name}", a customer on the ${org.plan} plan. Help this user run their asset-management operation in practical terms: questions about their own assets, tickets, maintenance and replacement timing, and operational suggestions.

You can only ever see this ONE organisation's own data, given below -- never another tenant's. The person you're talking to is signed in as ${role === "admin" ? "an Org Manager" : role === "user" ? "Staff" : "a Viewer"}; ${role === "admin" ? "they may see organisation-wide totals and valuation." : "organisation-wide valuation has deliberately NOT been included in the data below for this role -- if asked for it, explain that it's limited to Org Managers, don't estimate or guess at a figure."}

If asked about billing, credits or changing plan, point them to Profile > Billing & Plan rather than inventing numbers -- you have not been given billing data.

Current data for this organisation:
${JSON.stringify(data, null, 2)}`;
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
    // The ONLY client used anywhere in this function -- scoped to the
    // caller's own access token. See the header comment above: there is
    // deliberately no service-role client here at all.
    const callerClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authHeader } },
    });

    const { data: userData, error: userErr } = await callerClient.auth.getUser();
    if (userErr || !userData?.user) return jsonResponse({ error: "Not authenticated." }, 401);
    const userId = userData.user.id;

    const { scope, message } = await req.json();
    if (!message || !String(message).trim()) return jsonResponse({ error: "No message supplied." }, 400);
    if (scope !== "platform" && scope !== "tenant") return jsonResponse({ error: "Unknown scope." }, 400);

    const anthropicKey = Deno.env.get("ANTHROPIC_API_KEY");
    if (!anthropicKey) {
      return jsonResponse({ error: "No ANTHROPIC_API_KEY secret is configured for this project yet. See SETUP.md." }, 200);
    }

    let systemPrompt: string;
    let tools: unknown[] = [];
    let historyFilter: Record<string, unknown> = { scope, created_by: userId };
    let orgIdForInsert: string | null = null;

    if (scope === "platform") {
      const { data: isOwner } = await callerClient.rpc("is_platform_owner");
      if (!isOwner) return jsonResponse({ error: "Not authorised: platform owner only." }, 403);

      const [{ data: revSummary }, { data: orgList }, { data: hypotheses }, { data: interviews }, { data: canvas }, { data: decisions }] =
        await Promise.all([
          callerClient.rpc("platform_revenue_summary"),
          callerClient.rpc("platform_list_organizations"),
          callerClient.from("discovery_hypotheses").select("*").order("updated_at", { ascending: false }).limit(20),
          callerClient.from("discovery_interviews").select("*").order("created_at", { ascending: false }).limit(15),
          callerClient.from("discovery_canvas").select("*"),
          callerClient.from("discovery_decisions").select("*").order("created_at", { ascending: false }).limit(10),
        ]);

      const orgs = orgList || [];
      const byStatus: Record<string, number> = {};
      const byPlan: Record<string, number> = {};
      for (const o of orgs) {
        byStatus[o.status] = (byStatus[o.status] || 0) + 1;
        byPlan[o.plan] = (byPlan[o.plan] || 0) + 1;
      }
      const totalOrgs = orgs.length;
      const paidOrgs = (byPlan.starter || 0) + (byPlan.pro || 0);
      const groundingData = {
        organisations_total: totalOrgs,
        organisations_by_status: byStatus,
        organisations_by_plan: byPlan,
        rough_trial_to_paid_conversion_pct: totalOrgs ? Math.round((paidOrgs / totalOrgs) * 1000) / 10 : 0,
        conversion_caveat: "A simple snapshot ratio across all organisations ever signed up, not a proper cohort analysis -- treat it as a rough signal only.",
        revenue: (revSummary && revSummary[0]) || null,
        open_hypotheses: hypotheses || [],
        recent_interviews: interviews || [],
        business_model_canvas: canvas || [],
        past_decisions: decisions || [],
      };
      systemPrompt = buildPlatformSystemPrompt(groundingData);
      tools = DISCOVERY_TOOLS;
    } else {
      const { data: profile, error: profileErr } = await callerClient.from("profiles").select("*").eq("id", userId).maybeSingle();
      if (profileErr || !profile) return jsonResponse({ error: "No organisation is set up for this account." }, 403);

      const { data: org } = await callerClient.from("organizations").select("*").eq("id", profile.organization_id).maybeSingle();
      const { data: assets } = await callerClient.from("assets").select("condition, active, value");
      // Tickets' own RLS already restricts SELECT to Org Manager (see
      // supabase.sql) -- a Staff/Viewer caller simply gets nothing back
      // here, the same real refusal as everywhere else in this app, not
      // a role check this function has to reimplement.
      const { data: tickets } = await callerClient.from("tickets").select("status, urgency");

      const assetRows = assets || [];
      const byCondition: Record<string, number> = {};
      for (const a of assetRows) byCondition[a.condition] = (byCondition[a.condition] || 0) + 1;

      // Organisation-wide valuation is withheld from the data payload
      // itself for a role that cannot see it -- the same decide(role,
      // 'view_org') === admin-only gate index.html's old scripted
      // assistant applied, just enforced in the data this function
      // builds rather than trusted to a prompt instruction alone.
      const groundingData: Record<string, unknown> = {
        organisation_name: org?.name,
        plan: org?.plan,
        status: org?.status,
        asset_count: assetRows.length,
        active_asset_count: assetRows.filter((a) => a.active).length,
        assets_by_condition: byCondition,
        open_tickets: (tickets || []).filter((t) => t.status === "open").length,
      };
      if (profile.role === "admin") {
        groundingData.total_portfolio_value = assetRows.reduce((s, a) => s + (Number(a.value) || 0), 0);
        groundingData.tickets_by_urgency = (tickets || []).reduce((acc: Record<string, number>, t) => {
          acc[t.urgency] = (acc[t.urgency] || 0) + 1;
          return acc;
        }, {});
      }

      systemPrompt = buildTenantSystemPrompt(org || {}, profile.role, groundingData);
      tools = [];
      historyFilter = { scope: "tenant", organization_id: profile.organization_id, created_by: userId };
      orgIdForInsert = profile.organization_id;
    }

    // Recent history for THIS caller's own conversation only (RLS would
    // enforce that regardless, these filters just avoid fetching rows
    // that would be filtered out anyway).
    let historyQuery = callerClient.from("copilot_messages").select("role, content").eq("scope", historyFilter.scope as string).eq("created_by", userId);
    if (scope === "tenant") historyQuery = historyQuery.eq("organization_id", orgIdForInsert as string);
    const { data: historyRows } = await historyQuery.order("created_at", { ascending: true }).limit(MAX_HISTORY);

    const conversation: { role: string; content: unknown }[] = (historyRows || []).map((m) => ({ role: m.role, content: m.content }));
    conversation.push({ role: "user", content: String(message) });

    let finalText = "";
    const actions: string[] = [];
    for (let round = 0; round < MAX_TOOL_ROUNDS; round++) {
      const claudeData = await callClaude(anthropicKey, systemPrompt, conversation, tools);
      const blocks = claudeData.content || [];
      const textBlocks = blocks.filter((b: { type: string }) => b.type === "text").map((b: { text: string }) => b.text).join("\n");
      if (textBlocks) finalText = textBlocks;

      const toolUses = blocks.filter((b: { type: string }) => b.type === "tool_use");
      if (claudeData.stop_reason !== "tool_use" || toolUses.length === 0 || tools.length === 0) {
        break;
      }

      conversation.push({ role: "assistant", content: blocks });
      const toolResults = [];
      for (const tu of toolUses) {
        const result = await executeTool(callerClient, userId, tu.name, tu.input || {});
        actions.push(result.summary);
        toolResults.push({ type: "tool_result", tool_use_id: tu.id, content: result.resultText, is_error: result.isError });
      }
      conversation.push({ role: "user", content: toolResults });
    }

    if (!finalText) {
      finalText = actions.length
        ? "Noted -- I've updated your discovery records accordingly."
        : "I wasn't able to form a reply. Try rephrasing.";
    }

    // Persist exactly the human-readable exchange (not the tool-call
    // plumbing above) -- using the SAME caller-scoped client, so this
    // insert is subject to the exact copilot_messages RLS policy any
    // direct client insert would be.
    await callerClient.from("copilot_messages").insert([
      { scope, organization_id: orgIdForInsert, role: "user", content: String(message), created_by: userId },
      { scope, organization_id: orgIdForInsert, role: "assistant", content: finalText, created_by: userId },
    ]);

    return jsonResponse({ reply: finalText, actions });
  } catch (err) {
    return jsonResponse({ error: String((err as Error).message || err) }, 500);
  }
});
