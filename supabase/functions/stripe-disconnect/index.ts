// ═══════════════════════════════════════════════════════════════════════════
// stripe-disconnect — Unite edge function
// ═══════════════════════════════════════════════════════════════════════════
//
// WHAT THIS DOES
//   Revokes the tenant's Stripe Connect authorization via Stripe's
//   /oauth/deauthorize endpoint, then clears the stored
//   stripe_user_id from tenant_integrations. After this, the tenant
//   must re-run the Connect OAuth flow to reconnect.
//
//   Idempotent: if Stripe reports the account is already deauthorized
//   (or the stripe_user_id isn't recognised) we still clear the local
//   state and return success.
//
// CALLER CONTRACT
//   POST /functions/v1/stripe-disconnect
//     Body: { tenant_id, userToken }
//
// ═══════════════════════════════════════════════════════════════════════════

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const STRIPE_SECRET_KEY = Deno.env.get("STRIPE_SECRET_KEY")!;
const STRIPE_CONNECT_CLIENT_ID = Deno.env.get("STRIPE_CONNECT_CLIENT_ID")!;
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

    // Best-effort deauthorize. If it fails because the connection is
    // already broken, we still clear the local state.
    if (stripeUserId) {
      const form = new URLSearchParams();
      form.set("client_id", STRIPE_CONNECT_CLIENT_ID);
      form.set("stripe_user_id", stripeUserId);
      try {
        await fetch("https://connect.stripe.com/oauth/deauthorize", {
          method: "POST",
          headers: {
            "Authorization": `Bearer ${STRIPE_SECRET_KEY}`,
            "Content-Type": "application/x-www-form-urlencoded",
          },
          body: form.toString(),
        });
        // Ignore non-2xx — may already be deauthorized.
      } catch (_) { /* non-fatal */ }
    }

    const cleanConfig: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(intRow.config || {})) {
      if (!["business_name", "connected_account_hint", "livemode", "charges_enabled", "payouts_enabled", "details_submitted"].includes(k)) {
        cleanConfig[k] = v;
      }
    }

    const { error: updateErr } = await supabase
      .from("tenant_integrations")
      .update({
        credentials: {},
        config: cleanConfig,
        status: "disconnected",
        last_connected_at: null,
        last_error: null,
        last_error_at: null,
      })
      .eq("id", intRow.id);
    if (updateErr) return json({ error: `Disconnect write failed: ${updateErr.message}` }, 500);

    return json({ ok: true });
  } catch (err) {
    return json({ error: (err as Error).message || "Internal error" }, 500);
  }
});
