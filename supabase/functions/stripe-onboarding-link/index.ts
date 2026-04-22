// ═══════════════════════════════════════════════════════════════════════════
// stripe-onboarding-link — Unite edge function
// ═══════════════════════════════════════════════════════════════════════════
//
// WHAT THIS DOES
//   Generates a Stripe-hosted onboarding URL for a tenant's connected
//   account via Stripe's Account Links API. The tenant admin clicks
//   "Complete onboarding" in Pulse admin, this function mints a fresh
//   short-lived URL, the admin is redirected to Stripe, fills in the
//   required business / tax / bank info, and Stripe redirects back
//   to the tenant admin when done.
//
//   This is the proper long-term onboarding mechanism — real tenants
//   never log into the Unite Platform's Stripe dashboard. Every new
//   tenant runs the exact same flow Pulse runs today.
//
// STRIPE DOCS
//   POST https://api.stripe.com/v1/account_links
//     account=acct_...                   (the connected account to onboard)
//     type=account_onboarding            (onboarding flow)
//     refresh_url=<url>                  (Stripe bounces here if link expires)
//     return_url=<url>                   (Stripe bounces here when done)
//
// CALLER CONTRACT
//   POST /functions/v1/stripe-onboarding-link
//     Body: { tenant_id, return_url, userToken }
//
// RESPONSE
//   { url, expires_at }
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

    const { tenant_id, return_url } = body || {};
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
      .select("credentials")
      .eq("tenant_id", tenant_id)
      .eq("provider", "stripe")
      .maybeSingle();
    if (!intRow) return json({ error: "Stripe integration row not found" }, 404);

    const stripeUserId = intRow.credentials?.stripe_user_id;
    if (!stripeUserId) return json({ error: "Stripe account not connected yet — finish OAuth first" }, 409);

    // Account Links API — form-encoded.
    const form = new URLSearchParams();
    form.set("account", stripeUserId);
    form.set("type", "account_onboarding");
    form.set("refresh_url", return_url || "https://rbpulse.github.io/pulse/t/pulse/admin/");
    form.set("return_url", return_url || "https://rbpulse.github.io/pulse/t/pulse/admin/");

    const resp = await fetch("https://api.stripe.com/v1/account_links", {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${STRIPE_SECRET_KEY}`,
        "Content-Type": "application/x-www-form-urlencoded",
      },
      body: form.toString(),
    });
    const data = await resp.json();
    if (!resp.ok) {
      return json({
        error: data?.error?.message || `Stripe returned ${resp.status}`,
        detail: data,
      }, resp.status);
    }

    return json({
      url: data.url,
      expires_at: data.expires_at,
    });
  } catch (err) {
    return json({ error: (err as Error).message || "Internal error" }, 500);
  }
});
