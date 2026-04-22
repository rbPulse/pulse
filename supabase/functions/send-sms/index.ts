// ═══════════════════════════════════════════════════════════════════════════
// send-sms — Unite edge function
// ═══════════════════════════════════════════════════════════════════════════
//
// WHAT THIS DOES
//   Sends an SMS on behalf of a tenant using THAT tenant's own Twilio
//   credentials (BYOK). Every tenant's outbound SMS routes through
//   their own Twilio account + number, not a Unite-owned pool.
//
//   Uses the tenant's Messaging Service SID if configured (preferred
//   — gives Twilio room to rotate numbers, handle A2P registration,
//   schedule send windows, etc.). Falls back to a bare "From" number
//   if the tenant skipped the messaging service setup.
//
// CALLER CONTRACT
//   POST /functions/v1/send-sms
//     Body: {
//       tenant_id,
//       to,                  E.164 number, e.g. "+15555550123"
//       body,                the SMS text
//       from_override,       optional E.164 sender (bypasses messaging svc)
//       userToken            session access_token
//     }
//
// RESPONSE
//   { message_sid, status, to, from }  on success
//
// TEST-MODE CAVEAT
//   Twilio trial accounts can ONLY send to verified caller IDs.
//   Attempting to SMS an unverified number returns 400 with code
//   21608. We surface that error directly so the admin sees the
//   actionable message from Twilio.
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
    const body = await req.json();
    const token = body?.userToken || (req.headers.get("Authorization") || "").replace("Bearer ", "");
    if (!token) return json({ error: "Missing authentication" }, 401);
    const { data: { user }, error: authError } = await supabase.auth.getUser(token);
    if (authError || !user) return json({ error: "Unauthorized" }, 401);

    const { tenant_id, to, body: smsBody, from_override } = body || {};
    if (!tenant_id || !to || !smsBody) return json({ error: "tenant_id, to, and body are required" }, 400);

    const { data: membership } = await supabase
      .from("tenant_memberships")
      .select("role")
      .eq("tenant_id", tenant_id)
      .eq("user_id", user.id)
      .maybeSingle();
    if (!membership) return json({ error: "Not a member of this tenant" }, 403);

    const { data: intRow } = await supabase
      .from("tenant_integrations")
      .select("credentials, config, status")
      .eq("tenant_id", tenant_id)
      .eq("provider", "twilio")
      .maybeSingle();
    if (!intRow) return json({ error: "Twilio is not entitled to this tenant's plan" }, 409);

    const creds = intRow.credentials || {};
    const { account_sid, auth_token, messaging_service_sid } = creds;
    if (!account_sid || !auth_token) {
      return json({ error: "Twilio credentials not configured. Set them from the Integrations tab first." }, 409);
    }

    // Twilio's Messages.create uses application/x-www-form-urlencoded.
    const form = new URLSearchParams();
    form.set("To", to);
    form.set("Body", smsBody);
    if (from_override) {
      form.set("From", from_override);
    } else if (messaging_service_sid) {
      form.set("MessagingServiceSid", messaging_service_sid);
    } else {
      return json({ error: "No sender configured — pass from_override or save a messaging_service_sid" }, 400);
    }

    const basicAuth = btoa(`${account_sid}:${auth_token}`);
    const twResp = await fetch(`https://api.twilio.com/2010-04-01/Accounts/${account_sid}/Messages.json`, {
      method: "POST",
      headers: {
        "Authorization": `Basic ${basicAuth}`,
        "Content-Type": "application/x-www-form-urlencoded",
      },
      body: form.toString(),
    });
    const twData = await twResp.json();
    if (!twResp.ok) {
      return json({
        error: twData?.message || `Twilio returned ${twResp.status}`,
        code: twData?.code,
        detail: twData,
      }, twResp.status === 401 ? 401 : 400);
    }

    return json({
      message_sid: twData.sid,
      status: twData.status,
      to: twData.to,
      from: twData.from,
    });
  } catch (err) {
    return json({ error: (err as Error).message || "Internal error" }, 500);
  }
});
