// ═══════════════════════════════════════════════════════════════════════════
// twilio-save-creds — Unite edge function
// ═══════════════════════════════════════════════════════════════════════════
//
// WHAT THIS DOES
//   Accepts a tenant admin's pasted Twilio credentials
//   (Account SID, Auth Token, Messaging Service SID), validates them
//   by pinging Twilio's /Accounts/{SID}.json endpoint, and on success
//   writes them to tenant_integrations.credentials via the service
//   role (bypassing the platform-only-write RLS + column guard).
//
// WHY AN EDGE FUNCTION OWNS THIS WRITE
//   tenant_integrations.credentials is locked down by migration 023 —
//   tenant admins can't UPDATE that column directly. The security
//   posture is "credentials pass through an authenticated server
//   surface, never loose in the SDK." This function IS that surface.
//
// CALLER CONTRACT
//   POST /functions/v1/twilio-save-creds
//     Authorization: Bearer <SUPABASE_ANON_KEY>
//     Body: {
//       tenant_id,
//       account_sid,            AC... (34 chars)
//       auth_token,             the shared secret
//       messaging_service_sid,  MG... (34 chars, optional but recommended)
//       userToken               Supabase session access_token
//     }
//
// RESPONSE
//   { ok: true, account_friendly_name }
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
    const bodyToken = body?.userToken;
    const headerToken = (req.headers.get("Authorization") || "").replace("Bearer ", "");
    const token = bodyToken || headerToken;
    if (!token) return json({ error: "Missing authentication" }, 401);

    const { data: { user }, error: authError } = await supabase.auth.getUser(token);
    if (authError || !user) return json({ error: "Unauthorized" }, 401);

    const { tenant_id, account_sid, auth_token, messaging_service_sid } = body || {};
    if (!tenant_id || !account_sid || !auth_token) {
      return json({ error: "tenant_id, account_sid, and auth_token are required" }, 400);
    }

    // Shape checks — catch obvious typos before calling Twilio.
    if (!/^AC[a-f0-9]{32}$/i.test(account_sid)) {
      return json({ error: "account_sid should start with AC and be 34 characters" }, 400);
    }
    if (messaging_service_sid && !/^MG[a-f0-9]{32}$/i.test(messaging_service_sid)) {
      return json({ error: "messaging_service_sid should start with MG and be 34 characters" }, 400);
    }

    // Authz — only tenant owners / admins can paste creds.
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
      .select("id, config")
      .eq("tenant_id", tenant_id)
      .eq("provider", "twilio")
      .maybeSingle();
    if (!intRow) return json({ error: "Twilio is not entitled to this tenant's plan" }, 409);

    // Ping Twilio with the supplied creds. Twilio uses HTTP Basic auth:
    // username=Account SID, password=Auth Token. 200 = creds valid.
    const basicAuth = btoa(`${account_sid}:${auth_token}`);
    const twResp = await fetch(`https://api.twilio.com/2010-04-01/Accounts/${account_sid}.json`, {
      headers: { "Authorization": `Basic ${basicAuth}` },
    });
    if (!twResp.ok) {
      const detail = await twResp.text();
      return json({
        error: twResp.status === 401
          ? "Twilio rejected the credentials — check Account SID and Auth Token"
          : `Twilio returned ${twResp.status}`,
        detail,
      }, 400);
    }
    const twAccount = await twResp.json();

    // Write credentials + flip status. config.friendly_name is non-
    // secret and surfaces in the admin UI so the operator can see
    // which Twilio account is attached without re-exposing the token.
    const nextCredentials = {
      account_sid,
      auth_token,
      ...(messaging_service_sid ? { messaging_service_sid } : {}),
    };
    const nextConfig = {
      ...(intRow.config || {}),
      friendly_name: twAccount.friendly_name || null,
      account_sid_hint: account_sid.slice(0, 6) + "…" + account_sid.slice(-4),
    };

    await supabase
      .from("tenant_integrations")
      .update({
        credentials: nextCredentials,
        config: nextConfig,
        status: "connected",
        last_connected_at: new Date().toISOString(),
        last_error: null,
        last_error_at: null,
      })
      .eq("id", intRow.id);

    return json({
      ok: true,
      account_friendly_name: twAccount.friendly_name || null,
      account_sid_hint: nextConfig.account_sid_hint,
    });
  } catch (err) {
    return json({ error: (err as Error).message || "Internal error" }, 500);
  }
});
