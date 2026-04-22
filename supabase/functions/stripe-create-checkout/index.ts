// ═══════════════════════════════════════════════════════════════════════════
// stripe-create-checkout — Unite edge function
// ═══════════════════════════════════════════════════════════════════════════
//
// WHAT THIS DOES
//   Creates a Stripe Checkout Session scoped to a tenant's connected
//   Stripe account. The Platform (Unite) uses the `Stripe-Account`
//   header to tell Stripe "act as this connected account" so charges
//   appear in the tenant's dashboard and payouts go to the tenant's
//   bank, not Unite's.
//
//   Supports one-time payments + recurring subscriptions via Stripe's
//   native Checkout modes. Patient is redirected to Stripe's hosted
//   checkout UI (complies with PCI DSS without any SAQ-D work on our
//   side — Stripe hosts the card entry).
//
// CALLER CONTRACT
//   POST /functions/v1/stripe-create-checkout
//     Body: {
//       tenant_id,
//       mode: 'payment' | 'subscription',
//       line_items: [{ name, description?, amount_cents, quantity,
//                      recurring?: { interval: 'day'|'week'|'month'|'year' } }],
//       success_url,            // Stripe replaces {CHECKOUT_SESSION_ID}
//       cancel_url,
//       customer_email?,        // prefills the checkout form
//       metadata?,              // round-trips through Stripe so webhooks
//                               // can match back to Pulse entities
//       consultation_id?,       // convenience — stashed in metadata
//       userToken
//     }
//
// RESPONSE
//   { url, session_id, livemode }
//
// PATIENT UX
//   The caller redirects window.location to `url`. Patient sees
//   Stripe's branded checkout (optionally rebrandable per tenant via
//   their Stripe dashboard). Stripe redirects back to success_url or
//   cancel_url when done.
//
// AUTHZ
//   Authenticated caller with ANY membership on the tenant, OR a
//   public patient flow (consultation-id-based) that we trust from
//   the member portal. For now we require tenant membership — patient-
//   facing calls will land via a separate auth path later.
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

    const {
      tenant_id,
      mode = "payment",
      line_items,
      success_url,
      cancel_url,
      customer_email,
      metadata,
      consultation_id,
    } = body || {};

    if (!tenant_id) return json({ error: "tenant_id is required" }, 400);
    if (!Array.isArray(line_items) || line_items.length === 0) return json({ error: "line_items is required" }, 400);
    if (!success_url || !cancel_url) return json({ error: "success_url and cancel_url are required" }, 400);
    if (!["payment", "subscription"].includes(mode)) return json({ error: "mode must be payment or subscription" }, 400);

    // Any membership on the tenant — patients + staff both covered.
    // Tighter checks (e.g. match user_id to consultation.user_id) can
    // layer on top; for now membership is the coarse gate.
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
      .eq("provider", "stripe")
      .maybeSingle();
    if (!intRow) return json({ error: "Stripe is not entitled to this tenant's plan" }, 409);

    const stripeAccountId = intRow.credentials?.stripe_user_id;
    if (!stripeAccountId) return json({ error: "Stripe not connected for this tenant" }, 409);
    if (!intRow.config?.charges_enabled) {
      return json({ error: "Stripe charges are not enabled yet — finish onboarding first" }, 409);
    }

    // Build Stripe Checkout form body.
    // Stripe's /v1/checkout/sessions API is form-encoded with nested
    // keys like line_items[0][price_data][product_data][name].
    const form = new URLSearchParams();
    form.set("mode", mode);
    form.set("success_url", success_url);
    form.set("cancel_url", cancel_url);
    if (customer_email) form.set("customer_email", customer_email);

    line_items.forEach((li: any, i: number) => {
      form.set(`line_items[${i}][quantity]`, String(li.quantity || 1));
      form.set(`line_items[${i}][price_data][currency]`, "usd");
      form.set(`line_items[${i}][price_data][unit_amount]`, String(li.amount_cents));
      form.set(`line_items[${i}][price_data][product_data][name]`, li.name);
      if (li.description) form.set(`line_items[${i}][price_data][product_data][description]`, li.description);
      if (mode === "subscription" && li.recurring?.interval) {
        form.set(`line_items[${i}][price_data][recurring][interval]`, li.recurring.interval);
      }
    });

    const fullMetadata = { ...(metadata || {}) };
    if (consultation_id) fullMetadata.pulse_consultation_id = consultation_id;
    fullMetadata.unite_tenant_id = tenant_id;
    Object.entries(fullMetadata).forEach(([k, v]) => {
      form.set(`metadata[${k}]`, String(v));
    });

    const resp = await fetch("https://api.stripe.com/v1/checkout/sessions", {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${STRIPE_SECRET_KEY}`,
        "Content-Type": "application/x-www-form-urlencoded",
        // THIS is what makes the charge land on the tenant's account
        // instead of Unite's. Stripe calls this "direct charges" —
        // cleanest per-tenant accounting model.
        "Stripe-Account": stripeAccountId,
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
      session_id: data.id,
      livemode: !!data.livemode,
    });
  } catch (err) {
    return json({ error: (err as Error).message || "Internal error" }, 500);
  }
});
