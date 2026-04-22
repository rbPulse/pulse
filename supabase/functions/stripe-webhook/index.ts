// ═══════════════════════════════════════════════════════════════════════════
// stripe-webhook — Unite edge function
// ═══════════════════════════════════════════════════════════════════════════
//
// WHAT THIS DOES
//   Receives Stripe webhook deliveries for the Unite Platform's
//   Connect events, verifies the signature, dedupes by event.id,
//   and routes recognised event types into handlers that update
//   Pulse's DB state.
//
// WHY THIS EXISTS (vs. the optimistic browser-side write in 4b)
//   The consultation modal already sets purchase_status = 'completed'
//   after confirmPayment succeeds. That's the fast-feedback path for
//   the patient. But:
//
//     - Async payment methods (ACH, Klarna, bank debits) don't
//       complete inline — the PaymentIntent stays 'processing' and
//       flips to 'succeeded' minutes/days later. The browser never
//       sees that flip.
//     - Refunds, disputes, failed subscription renewals all happen
//       without a browser session to observe them.
//     - A patient who closes the tab mid-payment would leave the DB
//       in 'pending_payment' forever if Stripe couldn't reach us.
//
//   Webhooks are the authoritative reconciliation path. They're
//   idempotent: safe to retry, safe to double-deliver. The dedup
//   table (stripe_webhook_events) tracks what's been processed.
//
// EVENTS HANDLED
//   - payment_intent.succeeded   → consultations.purchase_status='completed'
//   - payment_intent.payment_failed  → record failure on consultation
//   - charge.refunded            → record refund on consultation
//
//   Unhandled events still get logged to stripe_webhook_events for
//   future processing (event_type + payload preserved).
//
// VERIFY_JWT: false
//   Stripe doesn't carry a Supabase JWT. The webhook endpoint must
//   be deployed with verify_jwt: false (in the dashboard settings
//   or via supabase/config.toml).
//
// ═══════════════════════════════════════════════════════════════════════════

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import Stripe from "https://esm.sh/stripe@14?target=deno";

const FN_VERSION = "4c-webhook-v1";

const STRIPE_SECRET_KEY = Deno.env.get("STRIPE_SECRET_KEY")!;
const STRIPE_WEBHOOK_SECRET = Deno.env.get("STRIPE_WEBHOOK_SECRET")!;
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const stripe = new Stripe(STRIPE_SECRET_KEY, {
  httpClient: Stripe.createFetchHttpClient(),
});

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "content-type, stripe-signature",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });

  const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY);

  // Stripe requires raw body for signature verification — DO NOT
  // parse JSON before calling constructEventAsync.
  const body = await req.text();
  const signature = req.headers.get("stripe-signature") || "";

  let event: Stripe.Event;
  try {
    event = await stripe.webhooks.constructEventAsync(
      body,
      signature,
      STRIPE_WEBHOOK_SECRET,
      undefined,
      Stripe.createSubtleCryptoProvider(),
    );
  } catch (err) {
    console.error(`[stripe-webhook] ${FN_VERSION} signature verification failed:`, (err as Error).message);
    return new Response(JSON.stringify({ error: "Invalid signature" }), {
      status: 400,
      headers: { ...cors, "Content-Type": "application/json" },
    });
  }

  const stripeAccountId = (event as any).account || null;
  console.log(`[stripe-webhook] ${FN_VERSION} ${event.type} ${event.id} account=${stripeAccountId}`);

  // Resolve tenant from the connected account id (direct charges
  // come through with event.account set).
  let tenantId: string | null = null;
  if (stripeAccountId) {
    const { data: intRow } = await supabase
      .from("tenant_integrations")
      .select("tenant_id")
      .eq("provider", "stripe")
      .filter("credentials->>stripe_user_id", "eq", stripeAccountId)
      .maybeSingle();
    tenantId = intRow?.tenant_id ?? null;
  }

  // Dedup: try to insert the event; if it already exists (by PK),
  // skip processing but still return 200 so Stripe stops retrying.
  const { error: insertErr } = await supabase
    .from("stripe_webhook_events")
    .insert({
      id: event.id,
      tenant_id: tenantId,
      stripe_account_id: stripeAccountId,
      event_type: event.type,
      livemode: event.livemode,
      payload: event as any,
    });

  if (insertErr) {
    // Duplicate primary-key = 23505. Anything else is unexpected.
    if ((insertErr as any).code === "23505") {
      console.log(`[stripe-webhook] ${event.id} already seen — skipping`);
      return new Response(JSON.stringify({ received: true, duplicate: true }), {
        status: 200,
        headers: { ...cors, "Content-Type": "application/json" },
      });
    }
    console.error(`[stripe-webhook] dedup-insert failed:`, insertErr.message);
    return new Response(JSON.stringify({ error: insertErr.message }), {
      status: 500,
      headers: { ...cors, "Content-Type": "application/json" },
    });
  }

  // Route the event to a handler.
  try {
    switch (event.type) {
      case "payment_intent.succeeded":
        await handlePaymentIntentSucceeded(supabase, event.data.object as Stripe.PaymentIntent);
        break;
      case "payment_intent.payment_failed":
        await handlePaymentIntentFailed(supabase, event.data.object as Stripe.PaymentIntent);
        break;
      case "charge.refunded":
        await handleChargeRefunded(supabase, event.data.object as Stripe.Charge);
        break;
      default:
        // Logged in stripe_webhook_events; no-op for now.
        console.log(`[stripe-webhook] unhandled event type: ${event.type}`);
    }

    // Mark processed.
    await supabase
      .from("stripe_webhook_events")
      .update({ processed_at: new Date().toISOString(), error: null })
      .eq("id", event.id);
  } catch (err) {
    const msg = (err as Error).message || String(err);
    console.error(`[stripe-webhook] handler threw for ${event.type}:`, msg);
    await supabase
      .from("stripe_webhook_events")
      .update({ error: msg.slice(0, 500) })
      .eq("id", event.id);
    // Respond 500 so Stripe retries. If the error is permanent,
    // we'll see it in stripe_webhook_events.error and fix manually.
    return new Response(JSON.stringify({ error: msg }), {
      status: 500,
      headers: { ...cors, "Content-Type": "application/json" },
    });
  }

  return new Response(JSON.stringify({ received: true, event_id: event.id }), {
    status: 200,
    headers: { ...cors, "Content-Type": "application/json" },
  });
});

// ── Handlers ───────────────────────────────────────────────────────────

async function handlePaymentIntentSucceeded(supabase: any, pi: Stripe.PaymentIntent) {
  const consultId = (pi.metadata as any)?.pulse_consultation_id;
  if (!consultId) {
    console.log(`[stripe-webhook] payment_intent.succeeded ${pi.id} has no pulse_consultation_id`);
    return;
  }

  const { data: consultRow } = await supabase
    .from("consultations")
    .select("data, purchase_status")
    .eq("id", consultId)
    .maybeSingle();
  if (!consultRow) {
    console.warn(`[stripe-webhook] consultation ${consultId} not found for ${pi.id}`);
    return;
  }

  const existingData = consultRow.data || {};
  existingData.purchase_status = "completed";
  existingData.stripe_payment_intent_id = pi.id;
  existingData.stripe_amount_cents = pi.amount_received || pi.amount;
  existingData.stripe_paid_at = new Date(pi.created * 1000).toISOString();

  const { error } = await supabase
    .from("consultations")
    .update({
      data: existingData,
      purchase_status: "completed",
    })
    .eq("id", consultId);
  if (error) throw error;
}

async function handlePaymentIntentFailed(supabase: any, pi: Stripe.PaymentIntent) {
  const consultId = (pi.metadata as any)?.pulse_consultation_id;
  if (!consultId) return;

  const { data: consultRow } = await supabase
    .from("consultations")
    .select("data")
    .eq("id", consultId)
    .maybeSingle();
  if (!consultRow) return;

  const existingData = consultRow.data || {};
  existingData.purchase_status = "payment_failed";
  existingData.stripe_payment_intent_id = pi.id;
  existingData.stripe_failure_code = pi.last_payment_error?.code || null;
  existingData.stripe_failure_message = pi.last_payment_error?.message || null;
  existingData.stripe_failure_at = new Date().toISOString();

  const { error } = await supabase
    .from("consultations")
    .update({
      data: existingData,
      purchase_status: "payment_failed",
    })
    .eq("id", consultId);
  if (error) throw error;
}

async function handleChargeRefunded(supabase: any, charge: Stripe.Charge) {
  const piId = typeof charge.payment_intent === "string" ? charge.payment_intent : charge.payment_intent?.id;
  if (!piId) return;

  // Find the consultation via the PI id stashed on the data blob.
  // Falls back to metadata on the charge itself.
  const consultId = (charge.metadata as any)?.pulse_consultation_id;
  const { data: matches } = consultId
    ? await supabase.from("consultations").select("id, data").eq("id", consultId)
    : await supabase
        .from("consultations")
        .select("id, data")
        .filter("data->>stripe_payment_intent_id", "eq", piId)
        .limit(1);
  const row = matches?.[0];
  if (!row) return;

  const existingData = row.data || {};
  existingData.stripe_refunded_amount_cents = charge.amount_refunded;
  existingData.stripe_refunded_at = new Date().toISOString();
  existingData.purchase_status = charge.refunded ? "refunded" : existingData.purchase_status;

  const { error } = await supabase
    .from("consultations")
    .update({
      data: existingData,
      purchase_status: charge.refunded ? "refunded" : undefined,
    })
    .eq("id", row.id);
  if (error) throw error;
}
