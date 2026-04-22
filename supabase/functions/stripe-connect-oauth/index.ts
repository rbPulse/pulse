// ═══════════════════════════════════════════════════════════════════════════
// stripe-connect-oauth — Unite edge function
// ═══════════════════════════════════════════════════════════════════════════
//
// WHAT THIS DOES
//   Completes the Stripe Connect OAuth flow. The tenant admin clicks
//   "Connect Stripe" in /t/{slug}/admin/, is redirected to Stripe
//   connect.stripe.com/oauth/authorize, logs into THEIR own Stripe
//   account, and authorizes Unite as a Platform. Stripe redirects
//   back to stripe-return.html with an authorization code; that page
//   hands the code to this function.
//
//   We exchange the code for the tenant's connected account ID via
//   Stripe's POST /oauth/token, then persist the account ID in
//   tenant_integrations.credentials so future server-side Stripe calls
//   (stripe-create-checkout, webhooks) can act on behalf of the tenant.
//
// CALLER CONTRACT
//   POST /functions/v1/stripe-connect-oauth
//     Body: { tenant_id, code, userToken }
//
// RESPONSE
//   { connected_account_id, livemode, business_name }
//
// SECURITY NOTES
//   STRIPE_SECRET_KEY must be the Unite Platform's own secret key —
//   NOT the tenant's. Stripe's /oauth/token requires the Platform's
//   secret to authorize the code exchange.
//
//   stripe_user_id IS a credential in the sense that it identifies
//   which Stripe account our Platform can act on. Stored in the
//   platform-read-only credentials column per migration 016.
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
    const body = await req.json();
    const token = body?.userToken || (req.headers.get("Authorization") || "").replace("Bearer ", "");
    if (!token) return json({ error: "Missing authentication" }, 401);
    const { data: { user }, error: authError } = await supabase.auth.getUser(token);
    if (authError || !user) return json({ error: "Unauthorized" }, 401);

    const { tenant_id, code } = body || {};
    if (!tenant_id || !code) return json({ error: "tenant_id and code are required" }, 400);

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
      .eq("provider", "stripe")
      .maybeSingle();
    if (!intRow) return json({ error: "Stripe is not entitled to this tenant's plan" }, 409);

    // Exchange the authorization code for a connected account ID.
    // Stripe wants application/x-www-form-urlencoded here.
    const form = new URLSearchParams();
    form.set("grant_type", "authorization_code");
    form.set("code", code);

    const stripeResp = await fetch("https://connect.stripe.com/oauth/token", {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${STRIPE_SECRET_KEY}`,
        "Content-Type": "application/x-www-form-urlencoded",
      },
      body: form.toString(),
    });
    const stripeData = await stripeResp.json();
    if (!stripeResp.ok) {
      return json({
        error: stripeData.error_description || stripeData.error || `Stripe returned ${stripeResp.status}`,
        detail: stripeData,
      }, stripeResp.status);
    }

    const connectedAccountId: string = stripeData.stripe_user_id;
    const livemode: boolean = !!stripeData.livemode;
    const scope: string = stripeData.scope || "";

    // Pull a little business info for display in the admin UI.
    let businessName = "";
    try {
      const acctResp = await fetch(`https://api.stripe.com/v1/accounts/${connectedAccountId}`, {
        headers: { "Authorization": `Bearer ${STRIPE_SECRET_KEY}` },
      });
      if (acctResp.ok) {
        const acct = await acctResp.json();
        businessName = acct.business_profile?.name || acct.email || acct.id || "";
      }
    } catch (_) { /* non-fatal */ }

    const nextCredentials = {
      stripe_user_id: connectedAccountId,
      scope,
      livemode,
    };
    const nextConfig = {
      ...(intRow.config || {}),
      business_name: businessName,
      connected_account_hint: connectedAccountId.slice(0, 8) + "…" + connectedAccountId.slice(-4),
      livemode,
    };

    const { error: updateErr } = await supabase
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
    if (updateErr) return json({ error: `Save failed: ${updateErr.message}` }, 500);

    return json({
      connected_account_id: connectedAccountId,
      livemode,
      business_name: businessName,
      connected_account_hint: nextConfig.connected_account_hint,
    });
  } catch (err) {
    return json({ error: (err as Error).message || "Internal error" }, 500);
  }
});
