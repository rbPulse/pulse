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
// Used by the post-payment confirmation email. Not required — if
// missing, the webhook still processes the payment; we just skip
// the email send with a log line.
const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY") || "";
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
  const consultId       = (pi.metadata as any)?.pulse_consultation_id;
  const tenantId        = (pi.metadata as any)?.unite_tenant_id;
  const refillRequestId = (pi.metadata as any)?.pulse_refill_request_id;

  // Refill path: different DB shape than initial consultations. A
  // refill_request row gets flipped to 'paid', a new prescription
  // row is created for tracking, and we fire the same confirmation
  // email (which works because the refill is still linked to a
  // consultation).
  if (refillRequestId) {
    await handleRefillPaid(supabase, pi, refillRequestId, tenantId);
    return;
  }

  if (!consultId) {
    console.log(`[stripe-webhook] payment_intent.succeeded ${pi.id} has no pulse_consultation_id`);
    return;
  }

  const { data: consultRow } = await supabase
    .from("consultations")
    .select("data, purchase_status, tenant_id")
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

  // Fire a confirmation email. Non-blocking on errors — if the send
  // fails (Resend down, sender not configured, etc.) we still want
  // the payment to be recorded as successful. The patient already
  // got Stripe's auto-receipt separately; this is Pulse-branded nice-to-have.
  try {
    await sendPurchaseConfirmationEmail(supabase, {
      tenantId: tenantId || consultRow.tenant_id,
      recipientEmail: pi.receipt_email || null,
      amountCents: pi.amount_received || pi.amount,
      lineItemNames: (pi.metadata as any)?.line_item_names || "your protocol",
      paymentIntentId: pi.id,
    });
  } catch (emailErr) {
    console.warn(`[stripe-webhook] confirmation email send failed for ${pi.id}:`, (emailErr as Error).message);
  }
}

// Fires a Pulse-branded "payment confirmed, protocol active" email
// via Resend. Uses the tenant's configured sender domain when
// verified; falls back to onboarding@resend.dev for tenants still
// in test mode. Called from the payment_intent.succeeded handler —
// the browser-side modal also shows a success state, but this is the
// durable record that lands in the patient's inbox.
async function sendPurchaseConfirmationEmail(
  supabase: any,
  opts: {
    tenantId: string | null;
    recipientEmail: string | null;
    amountCents: number;
    lineItemNames: string;
    paymentIntentId: string;
  },
) {
  if (!RESEND_API_KEY) {
    console.log(`[stripe-webhook] RESEND_API_KEY not set — skipping confirmation email`);
    return;
  }
  if (!opts.recipientEmail) {
    console.log(`[stripe-webhook] no recipient email on PI ${opts.paymentIntentId} — skipping confirmation email`);
    return;
  }
  if (!opts.tenantId) {
    console.log(`[stripe-webhook] no tenant_id resolved for PI ${opts.paymentIntentId} — skipping confirmation email`);
    return;
  }

  // Look up the tenant's Resend configuration. Skip if integration
  // isn't connected (tenant hasn't set up email yet — no point
  // trying to send on their behalf).
  const { data: resendRow } = await supabase
    .from("tenant_integrations")
    .select("status, mode, config")
    .eq("tenant_id", opts.tenantId)
    .eq("provider", "resend")
    .maybeSingle();
  if (!resendRow || resendRow.status !== "connected") {
    console.log(`[stripe-webhook] Resend not enabled for tenant ${opts.tenantId} — skipping confirmation email`);
    return;
  }

  // Tenant + brand for From-address and body personalization.
  const { data: tenantRow } = await supabase
    .from("tenants")
    .select("name, brand")
    .eq("id", opts.tenantId)
    .maybeSingle();
  const brandName = tenantRow?.brand?.wordmark || tenantRow?.name || "Your clinic";
  const supportEmail = tenantRow?.brand?.support_email || "";

  // Derive from-address. Verified domain → noreply@{domain};
  // test-mode fallback → onboarding@resend.dev.
  const senderDomain = resendRow.config?.sender_domain;
  const useTestFallback = !senderDomain || resendRow.config?.sender_mode === "test_fallback";
  const fromAddress = useTestFallback
    ? `${brandName} <onboarding@resend.dev>`
    : `${brandName} <noreply@${senderDomain}>`;

  const amount = (opts.amountCents / 100).toFixed(2);

  // Simple single-tenant-safe template. Tenants wanting to customize
  // can add a communication_templates row with key
  // 'consultation_purchased' in a follow-up phase.
  const subject = `Your ${brandName} protocol is active`;
  const html = `
<!doctype html>
<html><body style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Inter,sans-serif;max-width:560px;margin:40px auto;padding:0 24px;color:#1a1a1a;line-height:1.55;">
  <h1 style="font-size:22px;font-weight:600;letter-spacing:-0.01em;margin:0 0 18px;">Payment confirmed</h1>
  <p>Thanks for activating your ${escapeHtml(brandName)} protocol — your payment of <strong>$${amount}</strong> cleared successfully.</p>
  <div style="background:#f7f5f0;border:1px solid rgba(20,25,35,0.06);border-radius:10px;padding:16px 20px;margin:22px 0;">
    <div style="font-size:10px;letter-spacing:0.16em;text-transform:uppercase;color:#3a7a5c;font-weight:600;margin-bottom:8px;">Order</div>
    <div style="font-size:14px;">${escapeHtml(opts.lineItemNames)}</div>
    <div style="display:flex;justify-content:space-between;padding-top:10px;margin-top:10px;border-top:1px solid rgba(20,25,35,0.08);font-weight:600;">
      <span>Total</span><span>$${amount}</span>
    </div>
  </div>
  <p>Your clinician will be in touch shortly with next steps. You can also log into your patient portal at any time to view your protocol, book a follow-up, or message the care team.</p>
  ${supportEmail ? `<p style="font-size:12px;color:#666;">Questions? Reply to this email or write to <a href="mailto:${escapeAttr(supportEmail)}" style="color:#3a7a5c;">${escapeHtml(supportEmail)}</a>.</p>` : ""}
  <p style="font-size:11px;color:#999;margin-top:28px;">Reference: ${escapeHtml(opts.paymentIntentId)}</p>
</body></html>`.trim();

  const text = `Payment confirmed — thanks for activating your ${brandName} protocol.

Your payment of $${amount} cleared successfully.

Order: ${opts.lineItemNames}
Total: $${amount}

Your clinician will be in touch shortly with next steps. Log into your patient portal any time to view your protocol, book a follow-up, or message the care team.

${supportEmail ? `Questions? Write to ${supportEmail}.\n\n` : ""}Reference: ${opts.paymentIntentId}`;

  const resp = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${RESEND_API_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      from: fromAddress,
      to: [opts.recipientEmail],
      subject,
      html,
      text,
      tags: [
        { name: "source", value: "stripe-webhook" },
        { name: "event_type", value: "payment_intent.succeeded" },
      ],
    }),
  });
  if (!resp.ok) {
    const detail = await resp.text();
    throw new Error(`Resend returned ${resp.status}: ${detail.slice(0, 200)}`);
  }
  const result = await resp.json();
  console.log(`[stripe-webhook] confirmation email sent for PI ${opts.paymentIntentId}: ${result.id}`);
}

function escapeHtml(s: string): string {
  return String(s == null ? "" : s)
    .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;").replace(/'/g, "&#39;");
}
function escapeAttr(s: string): string {
  return escapeHtml(s);
}

// Handle the payment_intent.succeeded event for a refill. Flips the
// refill_requests row to 'paid', creates a new active prescription
// row so the clinical record reflects the refill, and fires the
// same confirmation email used for initial purchases.
async function handleRefillPaid(
  supabase: any,
  pi: Stripe.PaymentIntent,
  refillRequestId: string,
  tenantId: string | undefined,
) {
  const { data: refill } = await supabase
    .from("refill_requests")
    .select("id, tenant_id, consultation_id, patient_user_id, protocol_key, clinician_id, status")
    .eq("id", refillRequestId)
    .maybeSingle();
  if (!refill) {
    console.warn(`[stripe-webhook] refill_request ${refillRequestId} not found for ${pi.id}`);
    return;
  }
  if (refill.status === "paid" || refill.status === "fulfilled") {
    console.log(`[stripe-webhook] refill ${refillRequestId} already ${refill.status} — webhook replay`);
    return;
  }

  // Create the new prescription row for this refill. The existing
  // active prescription for the same (consultation_id, protocol_key)
  // is fine to leave in place — prescriptions can co-exist per that
  // unique index's WHERE clause (status='active' dedup). If the old
  // one is also 'active', keep it; this simply adds another active
  // row. Real-world: clinical teams may want to discontinue the
  // prior row before issuing a new one; that's a workflow choice
  // they can make via the admin UI.
  const { data: newRx, error: rxErr } = await supabase
    .from("prescriptions")
    .insert({
      consultation_id: refill.consultation_id,
      user_id:         refill.patient_user_id,
      clinician_id:    refill.clinician_id,
      protocol_key:    refill.protocol_key,
      status:          "active",
    })
    .select("id")
    .single();
  if (rxErr) {
    // Unique-violation on (consultation_id, protocol_key, status='active')
    // is OK — means an active rx already covers this. Any other error
    // bubbles up.
    if ((rxErr as any).code !== "23505") {
      throw rxErr;
    }
    console.log(`[stripe-webhook] active prescription already exists for consult ${refill.consultation_id} + ${refill.protocol_key} — skipping insert`);
  }

  const { error: updateErr } = await supabase
    .from("refill_requests")
    .update({
      status: "paid",
      stripe_payment_intent_id: pi.id,
      paid_at: new Date().toISOString(),
      amount_cents: pi.amount_received || pi.amount,
      new_prescription_id: newRx?.id || null,
    })
    .eq("id", refillRequestId);
  if (updateErr) throw updateErr;

  // Confirmation email for the refill. Reuses the same helper; the
  // tenant's Resend config + shared-fallback logic all apply.
  try {
    await sendPurchaseConfirmationEmail(supabase, {
      tenantId: tenantId || refill.tenant_id,
      recipientEmail: pi.receipt_email || null,
      amountCents: pi.amount_received || pi.amount,
      lineItemNames: (pi.metadata as any)?.line_item_names || "your refill",
      paymentIntentId: pi.id,
    });
  } catch (emailErr) {
    console.warn(`[stripe-webhook] refill confirmation email failed for ${pi.id}:`, (emailErr as Error).message);
  }
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
