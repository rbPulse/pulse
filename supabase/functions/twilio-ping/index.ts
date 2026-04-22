// ═══════════════════════════════════════════════════════════════════════════
// twilio-ping — Unite edge function
// ═══════════════════════════════════════════════════════════════════════════
//
// WHAT THIS DOES
//   Re-tests an existing tenant's stored Twilio credentials against
//   Twilio's /Accounts/{SID}.json endpoint. Does NOT accept fresh
//   credentials — that's twilio-save-creds's job. Used by the
//   tenant admin's "Test connection" button when no keys have
//   changed.
//
//   Updates tenant_integrations.last_connected_at on success or
//   last_error + last_error_at on failure.
//
// CALLER CONTRACT
//   POST /functions/v1/twilio-ping
//     Body: { tenant_id, userToken }
//
// RESPONSE
//   { ok: true, friendly_name } on success
//   { error } on failure (with the tenant_integrations row annotated)
//
// ═══════════════════════════════════════════════════════════════════════════

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });

  try {
    const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY);
    const body = (await req.json()) || {};
    const token = body.userToken || (req.headers.get("Authorization") || "").replace("Bearer ", "");
    if (!token) return json({ error: "Missing authentication" }, 401);
    const { data: { user }, error: authError } = await supabase.auth.getUser(token);
    if (authError || !user) return json({ error: "Unauthorized" }, 401);

    const { tenant_id } = body;
    if (!tenant_id) return json({ error: "tenant_id is required" }, 400);

    const { data: membership } = await supabase
      .from("tenant_memberships")
      .select("role")
      .eq("tenant_id", tenant_id)
      .eq("user_id", user.id)
      .in("role", ["tenant_owner", "tenant_admin"])
      .maybeSingle();
    if (!membership) return json({ error: "Not authorised on this tenant" }, 403);

    const { data: intRow } = await supabase
      .from("tenant_integrations")
      .select("id, credentials")
      .eq("tenant_id", tenant_id)
      .eq("provider", "twilio")
      .maybeSingle();
    if (!intRow) return json({ error: "Twilio integration row not found" }, 404);

    const creds = intRow.credentials || {};
    const account_sid = creds.account_sid;
    const auth_token = creds.auth_token;
    if (!account_sid || !auth_token) {
      return json({ error: "No credentials stored yet. Save them first from the Integrations tab." }, 409);
    }

    const basicAuth = btoa(`${account_sid}:${auth_token}`);
    const twResp = await fetch(`https://api.twilio.com/2010-04-01/Accounts/${account_sid}.json`, {
      headers: { "Authorization": `Basic ${basicAuth}` },
    });

    if (!twResp.ok) {
      const errText = await twResp.text();
      const { error: e } = await supabase
        .from("tenant_integrations")
        .update({
          status: "error",
          last_error: `Twilio ping ${twResp.status}: ${errText.slice(0, 240)}`,
          last_error_at: new Date().toISOString(),
        })
        .eq("id", intRow.id);
      if (e) return json({ error: `Annotate-failure failed: ${e.message}` }, 500);
      return json({ error: `Twilio returned ${twResp.status}`, detail: errText }, 400);
    }
    const twAccount = await twResp.json();

    const { error: updateErr } = await supabase
      .from("tenant_integrations")
      .update({
        status: "connected",
        last_connected_at: new Date().toISOString(),
        last_error: null,
        last_error_at: null,
      })
      .eq("id", intRow.id);
    if (updateErr) return json({ error: `Ping-succeed write failed: ${updateErr.message}` }, 500);

    return json({ ok: true, friendly_name: twAccount.friendly_name || null });
  } catch (err) {
    return json({ error: (err as Error).message || "Internal error" }, 500);
  }
});
