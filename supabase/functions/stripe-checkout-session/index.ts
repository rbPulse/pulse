// ═══════════════════════════════════════════════════════════════════════════
// stripe-checkout-session — Unite edge function
// ═══════════════════════════════════════════════════════════════════════════
//
// WHAT THIS DOES
//   Fetches a Stripe Checkout session from the tenant's connected
//   account so the post-checkout success page can confirm the
//   session's payment status without needing webhooks.
//
//   Webhooks (Phase 4c) are the authoritative path for marking an
//   order paid; this function is a convenience for the success-page
//   UX — "thanks, your payment cleared" without round-tripping
//   through the webhook delay.
//
// CALLER CONTRACT
//   POST /functions/v1/stripe-checkout-session
//     Body: { tenant_id, session_id, userToken }
//
// RESPONSE
//   { payment_status, amount_total, customer_email, metadata }
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

    const { tenant_id, session_id } = body || {};
    if (!tenant_id || !session_id) return json({ error: "tenant_id and session_id are required" }, 400);

    const { data: membership } = await supabase
      .from("tenant_memberships")
      .select("role")
      .eq("tenant_id", tenant_id)
      .eq("user_id", user.id)
      .maybeSingle();
    if (!membership) return json({ error: "Not a member of this tenant" }, 403);

    const { data: intRow } = await supabase
      .from("tenant_integrations")
      .select("credentials")
      .eq("tenant_id", tenant_id)
      .eq("provider", "stripe")
      .maybeSingle();
    const stripeAccountId = intRow?.credentials?.stripe_user_id;
    if (!stripeAccountId) return json({ error: "Stripe not connected for this tenant" }, 409);

    const resp = await fetch(`https://api.stripe.com/v1/checkout/sessions/${encodeURIComponent(session_id)}`, {
      headers: {
        "Authorization": `Bearer ${STRIPE_SECRET_KEY}`,
        "Stripe-Account": stripeAccountId,
      },
    });
    const data = await resp.json();
    if (!resp.ok) {
      return json({ error: data?.error?.message || `Stripe returned ${resp.status}`, detail: data }, resp.status);
    }

    return json({
      payment_status: data.payment_status,
      amount_total: data.amount_total,
      currency: data.currency,
      customer_email: data.customer_details?.email || data.customer_email,
      metadata: data.metadata || {},
      mode: data.mode,
      livemode: !!data.livemode,
    });
  } catch (err) {
    return json({ error: (err as Error).message || "Internal error" }, 500);
  }
});
