// ═══════════════════════════════════════════════════════════════════════════
// stripe-ping — Unite edge function
// ═══════════════════════════════════════════════════════════════════════════
//
// WHAT THIS DOES
//   Fetches the current state of the tenant's connected Stripe account
//   from Stripe's /v1/accounts/{id} endpoint using the Unite Platform
//   secret key. Used by the tenant admin to confirm the connection is
//   still valid and to refresh the displayed business name / charges-
//   enabled status after the tenant completes Stripe onboarding.
//
// CALLER CONTRACT
//   POST /functions/v1/stripe-ping
//     Body: { tenant_id, userToken }
//
// RESPONSE
//   { ok, business_name, charges_enabled, payouts_enabled, livemode }
//
// ═══════════════════════════════════════════════════════════════════════════

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const STRIPE_SECRET_KEY = Deno.env.get("STRIPE_SECRET_KEY")!;
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
      .select("id, credentials, config")
      .eq("tenant_id", tenant_id)
      .eq("provider", "stripe")
      .maybeSingle();
    if (!intRow) return json({ error: "Stripe integration row not found" }, 404);

    const stripeUserId = intRow.credentials?.stripe_user_id;
    if (!stripeUserId) return json({ error: "No Stripe account connected yet" }, 409);

    const resp = await fetch(`https://api.stripe.com/v1/accounts/${stripeUserId}`, {
      headers: { "Authorization": `Bearer ${STRIPE_SECRET_KEY}` },
    });
    if (!resp.ok) {
      const errText = await resp.text();
      await supabase
        .from("tenant_integrations")
        .update({
          status: "error",
          last_error: `Stripe ping ${resp.status}: ${errText.slice(0, 240)}`,
          last_error_at: new Date().toISOString(),
        })
        .eq("id", intRow.id);
      return json({ error: `Stripe returned ${resp.status}`, detail: errText }, 400);
    }
    const acct = await resp.json();
    const businessName = acct.business_profile?.name || acct.email || acct.id;

    const nextConfig = {
      ...(intRow.config || {}),
      business_name: businessName,
      charges_enabled: !!acct.charges_enabled,
      payouts_enabled: !!acct.payouts_enabled,
      details_submitted: !!acct.details_submitted,
    };

    const { error: updateErr } = await supabase
      .from("tenant_integrations")
      .update({
        config: nextConfig,
        status: "connected",
        last_connected_at: new Date().toISOString(),
        last_error: null,
        last_error_at: null,
      })
      .eq("id", intRow.id);
    if (updateErr) return json({ error: `Ping-succeed write failed: ${updateErr.message}` }, 500);

    return json({
      ok: true,
      business_name: businessName,
      charges_enabled: !!acct.charges_enabled,
      payouts_enabled: !!acct.payouts_enabled,
      details_submitted: !!acct.details_submitted,
      livemode: !!acct.livemode,
    });
  } catch (err) {
    return json({ error: (err as Error).message || "Internal error" }, 500);
  }
});
