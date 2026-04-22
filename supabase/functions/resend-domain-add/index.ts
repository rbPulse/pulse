// ═══════════════════════════════════════════════════════════════════════════
// resend-domain-add — Unite edge function
// ═══════════════════════════════════════════════════════════════════════════
//
// WHAT THIS DOES
//   Adds a per-tenant sender domain to the Unite-owned Resend account,
//   then persists the returned domain_id + DNS records on
//   tenant_integrations.config so the tenant admin UI can display
//   the DNS records the tenant operator needs to add.
//
// WHY THIS IS AN EDGE FUNCTION
//   RESEND_API_KEY is a platform secret. Shipping it to the browser
//   would expose every tenant's email-sending capability. This
//   function is the only code path with access to the key.
//
// CALLER CONTRACT
//   POST /functions/v1/resend-domain-add
//     Authorization: Bearer <tenant-admin session token>
//     Body: { tenant_id, domain }
//
// AUTHZ
//   Caller must be a tenant_owner or tenant_admin on tenant_id. We
//   enforce via a direct tenant_memberships lookup — not via RLS
//   because this function uses the service role to write to
//   tenant_integrations (which tenant admins can't update the
//   credentials column on).
//
// RESPONSE
//   { domain_id, records: [{ type, name, value, ttl, status }] }
//   records is what the tenant admin UI renders for "copy into DNS."
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
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });

  try {
    const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY);

    const body = await req.json();

    // Pattern: anon key rides in Authorization to satisfy the gateway's
    // verify_jwt check. The real user JWT is inside the body (userToken)
    // and we use it here to identify the caller. Falls back to the
    // Authorization header if someone invokes without the body shim.
    const bodyToken = (body && body.userToken) as string | undefined;
    const headerToken = (req.headers.get("Authorization") || "").replace("Bearer ", "");
    const token = bodyToken || headerToken;
    if (!token) return json({ error: "Missing authentication" }, 401);

    const { data: { user }, error: authError } = await supabase.auth.getUser(token);
    if (authError || !user) return json({ error: "Unauthorized" }, 401);

    const { tenant_id, domain } = body || {};
    if (!tenant_id || !domain) return json({ error: "tenant_id and domain are required" }, 400);

    // Domain sanity check — Resend will re-validate but we block obvious junk early.
    if (!/^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$/i.test(domain)) {
      return json({ error: "Domain looks malformed" }, 400);
    }

    // Authz: caller must be owner or admin of this tenant.
    const { data: membership } = await supabase
      .from("tenant_memberships")
      .select("role")
      .eq("tenant_id", tenant_id)
      .eq("user_id", user.id)
      .in("role", ["tenant_owner", "tenant_admin"])
      .maybeSingle();
    if (!membership) return json({ error: "Not authorised on this tenant" }, 403);

    // Ensure the tenant_integrations row exists (it should, from migration 028a).
    const { data: intRow } = await supabase
      .from("tenant_integrations")
      .select("id, config")
      .eq("tenant_id", tenant_id)
      .eq("provider", "resend")
      .maybeSingle();
    if (!intRow) return json({ error: "Resend is not entitled to this tenant's plan" }, 409);

    // Call Resend API — Domains.create.
    const resendResp = await fetch("https://api.resend.com/domains", {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${RESEND_API_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ name: domain }),
    });
    const resendJson = await resendResp.json();
    if (!resendResp.ok) {
      return json({ error: resendJson?.message || "Resend domain creation failed", detail: resendJson }, resendResp.status);
    }

    // Persist domain_id + records + sender address shape into config.
    // We store the full records array so the UI can re-display them
    // without a second round-trip to Resend.
    const nextConfig = {
      ...(intRow.config || {}),
      sender_domain: domain,
      resend_domain_id: resendJson.id,
      dns_records: resendJson.records || [],
    };

    await supabase
      .from("tenant_integrations")
      .update({ config: nextConfig, status: "disconnected" })  // status flips to connected after verify
      .eq("id", intRow.id);

    return json({
      domain_id: resendJson.id,
      records: resendJson.records || [],
      domain,
    });
  } catch (err) {
    return json({ error: (err as Error).message || "Internal error" }, 500);
  }
});
