// ═══════════════════════════════════════════════════════════════════════════
// resend-domain-verify — Unite edge function
// ═══════════════════════════════════════════════════════════════════════════
//
// WHAT THIS DOES
//   Asks Resend to verify the DNS records for a tenant's previously-
//   added sender domain. If Resend confirms the domain is verified,
//   flips tenant_integrations.status to 'connected'.
//
//   Can be called as often as the tenant admin hits "Verify" —
//   Resend handles the underlying DNS polling. We just proxy the
//   call + sync status.
//
// CALLER CONTRACT
//   POST /functions/v1/resend-domain-verify
//     Authorization: Bearer <tenant-admin session token>
//     Body: { tenant_id }
//
// RESPONSE
//   { verified, records, status }  — verified:boolean, records as
//   returned by Resend (with per-record status so the UI can show
//   which ones still aren't confirmed).
//
// ═══════════════════════════════════════════════════════════════════════════

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY")!;
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

    // See resend-domain-add for the auth pattern — anon key in header,
    // real user JWT in the body as userToken.
    const bodyToken = body.userToken as string | undefined;
    const headerToken = (req.headers.get("Authorization") || "").replace("Bearer ", "");
    const token = bodyToken || headerToken;
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
      .select("id, config, status")
      .eq("tenant_id", tenant_id)
      .eq("provider", "resend")
      .maybeSingle();
    if (!intRow) return json({ error: "Resend integration row not found" }, 404);

    const domainId = intRow.config?.resend_domain_id;
    if (!domainId) return json({ error: "No domain has been added yet" }, 409);

    // Poke Resend for the current verification state.
    // Resend's verify endpoint is POST /domains/{id}/verify; it returns
    // the domain record including records[].status.
    const verifyResp = await fetch(`https://api.resend.com/domains/${domainId}/verify`, {
      method: "POST",
      headers: { "Authorization": `Bearer ${RESEND_API_KEY}` },
    });

    // Whether the verify POST returns 200 or not, we still fetch the
    // domain to get the current record-level statuses.
    const getResp = await fetch(`https://api.resend.com/domains/${domainId}`, {
      headers: { "Authorization": `Bearer ${RESEND_API_KEY}` },
    });
    const domain = await getResp.json();
    if (!getResp.ok) return json({ error: domain?.message || "Resend fetch failed" }, getResp.status);

    const verified = domain.status === "verified";
    const nextStatus = verified ? "connected" : "disconnected";

    const nextConfig = {
      ...(intRow.config || {}),
      dns_records: domain.records || intRow.config?.dns_records || [],
      resend_domain_status: domain.status,
    };

    const { error: updateErr } = await supabase
      .from("tenant_integrations")
      .update({
        config: nextConfig,
        status: nextStatus,
        last_connected_at: verified ? new Date().toISOString() : null,
      })
      .eq("id", intRow.id);
    if (updateErr) return json({ error: `Verify-write failed: ${updateErr.message}` }, 500);

    return json({
      verified,
      status: nextStatus,
      resend_domain_status: domain.status,
      records: domain.records || [],
    });
  } catch (err) {
    return json({ error: (err as Error).message || "Internal error" }, 500);
  }
});
