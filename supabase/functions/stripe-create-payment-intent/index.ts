// ═══════════════════════════════════════════════════════════════════════════
// stripe-create-payment-intent — Unite edge function
// ═══════════════════════════════════════════════════════════════════════════
//
// WHAT THIS DOES
//   Creates a Stripe PaymentIntent scoped to a tenant's connected
//   account so the patient-facing Pulse consultation page can render
//   Stripe's Payment Element inline — no redirect to a Stripe-hosted
//   checkout page. Patient stays on /t/{slug}/consultation/ through
//   the entire payment.
//
//   Direct-charge model: charges land on the tenant's connected
//   account balance (not Unite's). The Stripe-Account header tells
//   Stripe "act as this account" — money routes there, Stripe fees
//   are deducted, payout goes to the tenant's bank.
//
// CALLER CONTRACT
//   POST /functions/v1/stripe-create-payment-intent
//     Body: {
//       tenant_id,
//       consultation_id,           // stashed in metadata
//       line_items: [{ name, description?, amount_cents, quantity }],
//       customer_email?,
//       userToken
//     }
//
// RESPONSE
//   {
//     client_secret,               // used by Stripe.js + Payment Element
//     connected_account_id,        // browser needs this to init Stripe.js
//                                  // with { stripeAccount: '...' }
//     payment_intent_id,
//     amount,
//     currency
//   }
//
// AUTHZ
//   Authenticated caller with ANY membership on the tenant. Patients
//   authenticate via their Supabase session; the tenant_memberships
//   row for their user_id + tenant_id is the gate.
//
// ═══════════════════════════════════════════════════════════════════════════

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const STRIPE_SECRET_KEY = Deno.env.get("STRIPE_SECRET_KEY")!;
// Publishable key is safe to ship to the browser — Stripe designs it
// for client-side use. We pass it through a secret + function rather
// than hardcoding in the admin page so rotation is a single Supabase
// Secrets edit, not a repo commit.
const STRIPE_PUBLISHABLE_KEY = Deno.env.get("STRIPE_PUBLISHABLE_KEY") || "";
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

    const { tenant_id, consultation_id, line_items, customer_email } = body || {};
    if (!tenant_id) return json({ error: "tenant_id is required" }, 400);
    if (!Array.isArray(line_items) || line_items.length === 0) return json({ error: "line_items is required" }, 400);

    const { data: membership } = await supabase
      .from("tenant_memberships")
      .select("role")
      .eq("tenant_id", tenant_id)
      .eq("user_id", user.id)
      .maybeSingle();
    if (!membership) return json({ error: "Not a member of this tenant" }, 403);

    const { data: intRow } = await supabase
      .from("tenant_integrations")
      .select("credentials, config")
      .eq("tenant_id", tenant_id)
      .eq("provider", "stripe")
      .maybeSingle();
    if (!intRow) return json({ error: "Stripe is not entitled to this tenant's plan" }, 409);

    const stripeAccountId = intRow.credentials?.stripe_user_id;
    if (!stripeAccountId) return json({ error: "Stripe not connected for this tenant" }, 409);
    if (!intRow.config?.charges_enabled) {
      return json({ error: "Stripe charges are not enabled yet — finish onboarding first" }, 409);
    }

    // Sum line items into a single PI amount. Stripe's PaymentIntent
    // API doesn't take itemized lines — it's one charge for one
    // amount. Keep item breakdown in metadata for bookkeeping + future
    // receipt generation; the summary shows in the patient's inline
    // order-summary panel, not on the Stripe side.
    let totalCents = 0;
    line_items.forEach((li: any) => {
      const q = Number(li.quantity || 1);
      totalCents += Math.round(Number(li.amount_cents) * q);
    });
    if (totalCents <= 0) return json({ error: "Total amount must be > 0" }, 400);

    // Automatic payment methods = let Stripe decide which payment
    // methods to offer the patient based on the tenant's Stripe
    // dashboard config. Covers cards by default; tenants can enable
    // ACH / Cash App / Apple Pay / Klarna in their own Stripe.
    const form = new URLSearchParams();
    form.set("amount", String(totalCents));
    form.set("currency", "usd");
    form.set("automatic_payment_methods[enabled]", "true");
    if (customer_email) form.set("receipt_email", customer_email);

    const metadata: Record<string, string> = {
      unite_tenant_id: tenant_id,
      unite_user_id: user.id,
    };
    if (consultation_id) metadata.pulse_consultation_id = consultation_id;
    metadata.line_item_count = String(line_items.length);
    metadata.line_item_names = line_items.map((li: any) => li.name).join(", ").slice(0, 500);
    Object.entries(metadata).forEach(([k, v]) => form.set(`metadata[${k}]`, v));

    const resp = await fetch("https://api.stripe.com/v1/payment_intents", {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${STRIPE_SECRET_KEY}`,
        "Content-Type": "application/x-www-form-urlencoded",
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
      client_secret: data.client_secret,
      connected_account_id: stripeAccountId,
      publishable_key: STRIPE_PUBLISHABLE_KEY,
      payment_intent_id: data.id,
      amount: data.amount,
      currency: data.currency,
    });
  } catch (err) {
    return json({ error: (err as Error).message || "Internal error" }, 500);
  }
});
