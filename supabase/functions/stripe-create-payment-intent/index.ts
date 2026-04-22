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

// VERSION_MARKER — bump this string every time we redeploy so the
// browser response tells us which code is actually running on the
// server. If this value doesn't appear in the Network response, the
// old code is still live and the redeploy didn't take.
const FN_VERSION = "4b-authz-consult-v3";

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

  console.log(`[stripe-create-payment-intent] ${FN_VERSION} request received`);

  try {
    const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY);
    const body = await req.json();
    const token = body?.userToken || (req.headers.get("Authorization") || "").replace("Bearer ", "");
    if (!token) return json({ error: "Missing authentication", version: FN_VERSION }, 401);
    const { data: { user }, error: authError } = await supabase.auth.getUser(token);
    if (authError || !user) return json({ error: "Unauthorized" }, 401);

    const { tenant_id, consultation_id, line_items, selected_keys, customer_email, refill_request_id } = body || {};
    if (!tenant_id) return json({ error: "tenant_id is required" }, 400);

    // Authz: accept ANY of three proofs that this user has a
    // relationship with this tenant:
    //   1. Staff membership (tenant_memberships)
    //   2. Active patient enrollment (patient_enrollments)
    //   3. They OWN a consultation on this tenant — if a consultation
    //      was created for them with matching tenant_id + user_id,
    //      they have an established relationship even if the
    //      patient_enrollments row wasn't created (common upstream
    //      gap during the consultation flow).
    //
    // When #3 is the proof, we also UPSERT a patient_enrollments row
    // so downstream systems (member portal, messaging, RLS) see the
    // relationship cleanly. Self-healing data.
    const [memRes, enrRes, consultRes] = await Promise.all([
      supabase
        .from("tenant_memberships")
        .select("role")
        .eq("tenant_id", tenant_id)
        .eq("user_id", user.id)
        .maybeSingle(),
      supabase
        .from("patient_enrollments")
        .select("status")
        .eq("tenant_id", tenant_id)
        .eq("user_id", user.id)
        .eq("status", "active")
        .maybeSingle(),
      consultation_id
        ? supabase
            .from("consultations")
            .select("id")
            .eq("id", consultation_id)
            .eq("user_id", user.id)
            .eq("tenant_id", tenant_id)
            .maybeSingle()
        : supabase
            .from("consultations")
            .select("id")
            .eq("user_id", user.id)
            .eq("tenant_id", tenant_id)
            .limit(1)
            .maybeSingle(),
    ]);

    const authorized = !!memRes.data || !!enrRes.data || !!consultRes.data;
    if (!authorized) {
      return json({
        error: "Not authorised on this tenant",
        version: FN_VERSION,
        diag: {
          user_id: user.id,
          tenant_id: tenant_id,
          consultation_id: consultation_id || null,
          membership_row: memRes.data || null,
          enrollment_row: enrRes.data || null,
          consultation_match: consultRes.data || null,
          membership_err: memRes.error?.message || null,
          enrollment_err: enrRes.error?.message || null,
          consultation_err: consultRes.error?.message || null,
        },
      }, 403);
    }

    // Self-heal: if we authed via consultation and there's no
    // patient_enrollments row, create one so the rest of the system
    // treats them as a real patient going forward. upsert handles
    // race conditions cleanly.
    if (!enrRes.data && consultRes.data && !memRes.data) {
      await supabase
        .from("patient_enrollments")
        .upsert(
          { user_id: user.id, tenant_id, status: "active" },
          { onConflict: "user_id,tenant_id" }
        );
    }

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

    // Three ways to specify what's being bought:
    //   1. refill_request_id — server looks up the refill row, uses
    //      protocol_templates.refill_price (falls back to .price)
    //      for the single line item. Charged against the same
    //      consultation as the refill's original prescription.
    //   2. selected_keys: ["repair", "growth"] — server looks up
    //      catalog name + price from protocol_templates.
    //   3. line_items: [{name, amount_cents, quantity}] — caller
    //      has prepared line items; server trusts them.
    // Exactly one path is required.
    let resolvedLineItems: Array<{ name: string; description?: string; amount_cents: number; quantity: number }> = [];
    let resolvedConsultationId: string | undefined = consultation_id;

    if (refill_request_id) {
      const { data: refill } = await supabase
        .from("refill_requests")
        .select("id, tenant_id, consultation_id, protocol_key, status, patient_user_id")
        .eq("id", refill_request_id)
        .maybeSingle();
      if (!refill) return json({ error: "Refill request not found" }, 404);
      if (refill.tenant_id !== tenant_id) return json({ error: "Refill tenant_id mismatch" }, 400);
      if (refill.patient_user_id !== user.id) return json({ error: "Refill belongs to a different patient" }, 403);
      if (refill.status !== "approved") {
        return json({ error: `Refill is not approved yet (status: ${refill.status})` }, 409);
      }
      resolvedConsultationId = refill.consultation_id;

      const { data: t } = await supabase
        .from("protocol_templates")
        .select("key, name, price, refill_price")
        .eq("tenant_id", tenant_id)
        .eq("key", refill.protocol_key)
        .maybeSingle();
      const displayName = t?.name || refill.protocol_key;
      const cents = t?.refill_price != null
        ? Math.round(Number(t.refill_price) * 100)
        : (t?.price != null ? Math.round(Number(t.price) * 100) : 9900);
      resolvedLineItems.push({
        name: displayName,
        description: "Pulse protocol refill",
        amount_cents: cents,
        quantity: 1,
      });
    } else if (Array.isArray(selected_keys) && selected_keys.length > 0) {
      const { data: templates } = await supabase
        .from("protocol_templates")
        .select("key, name, price")
        .eq("tenant_id", tenant_id);
      const byKeyOrName: Record<string, { key: string; name: string; price: number | null }> = {};
      (templates || []).forEach((t: any) => {
        if (t.key)  byKeyOrName[String(t.key).toLowerCase()]  = t;
        if (t.name) byKeyOrName[String(t.name).toLowerCase()] = t;
      });
      selected_keys.forEach((rawKey: string) => {
        const lookup = byKeyOrName[String(rawKey).toLowerCase()];
        const name = lookup?.name || String(rawKey);
        const cents = lookup?.price != null ? Math.round(Number(lookup.price) * 100) : 9900;
        resolvedLineItems.push({
          name,
          description: body?.description_suffix ? `Pulse protocol — ${body.description_suffix}` : undefined,
          amount_cents: cents,
          quantity: 1,
        });
      });
    } else if (Array.isArray(line_items) && line_items.length > 0) {
      resolvedLineItems = line_items.map((li: any) => ({
        name: li.name,
        description: li.description,
        amount_cents: Math.round(Number(li.amount_cents)),
        quantity: Number(li.quantity || 1),
      }));
    } else {
      return json({ error: "selected_keys or line_items is required" }, 400);
    }

    let totalCents = 0;
    resolvedLineItems.forEach((li) => {
      totalCents += li.amount_cents * li.quantity;
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
    if (resolvedConsultationId) metadata.pulse_consultation_id = resolvedConsultationId;
    if (refill_request_id) metadata.pulse_refill_request_id = refill_request_id;
    metadata.line_item_count = String(resolvedLineItems.length);
    metadata.line_item_names = resolvedLineItems.map((li) => li.name).join(", ").slice(0, 500);
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
      line_items: resolvedLineItems,
    });
  } catch (err) {
    return json({ error: (err as Error).message || "Internal error" }, 500);
  }
});
