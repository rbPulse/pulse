// ═══════════════════════════════════════════════════════════════════════════
// send-email — Unite edge function
// ═══════════════════════════════════════════════════════════════════════════
//
// WHAT THIS DOES
//   Sends a transactional email on behalf of a tenant via the Unite-
//   owned Resend account. The tenant's verified sender domain
//   (stored in tenant_integrations.config.sender_domain) becomes the
//   "from" domain; the Unite Resend account does the actual delivery.
//
//   This is the single send path for every tenant. No tenant-branded
//   mailer code. Everything flows through here.
//
// CALLER CONTRACT
//   POST /functions/v1/send-email
//     Authorization: Bearer <session token of a user with access to tenant_id>
//     Body:
//       {
//         tenant_id,              required
//         to,                     required ("name@host" or array of same)
//         subject,                required
//         html,                   one of html or text required
//         text,                   "
//         from_local_part,        optional, defaults to "noreply"
//                                 (will become "noreply@{sender_domain}")
//         from_name,              optional friendly name
//         reply_to,               optional
//         tags,                   optional [{name,value}], forwarded to Resend
//       }
//
// AUTHZ
//   Authenticated caller with ANY role on the tenant (owner, admin,
//   clinician, nurse) may send. Patient portal sends go through
//   backend workflows that use the service role and spoof a tenant
//   membership check — not this direct path. We'll tighten if needed.
//
// TEST vs LIVE MODE
//   If tenant_integrations.mode = 'test' and the sender domain isn't
//   verified yet, fall back to sending from "onboarding@resend.dev"
//   so the demo flow works before DNS is set up.
//
// RESPONSE
//   { message_id, from, to, sender_mode }  on success.
//
// ═══════════════════════════════════════════════════════════════════════════

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY")!;
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

    const token = (req.headers.get("Authorization") || "").replace("Bearer ", "");
    if (!token) return json({ error: "Missing authentication" }, 401);
    const { data: { user }, error: authError } = await supabase.auth.getUser(token);
    if (authError || !user) return json({ error: "Unauthorized" }, 401);

    const body = await req.json();
    const { tenant_id, to, subject, html, text, from_local_part, from_name, reply_to, tags } = body || {};
    if (!tenant_id || !to || !subject) return json({ error: "tenant_id, to, and subject are required" }, 400);
    if (!html && !text) return json({ error: "html or text is required" }, 400);

    const { data: membership } = await supabase
      .from("tenant_memberships")
      .select("role")
      .eq("tenant_id", tenant_id)
      .eq("user_id", user.id)
      .maybeSingle();
    if (!membership) return json({ error: "Not a member of this tenant" }, 403);

    const { data: intRow } = await supabase
      .from("tenant_integrations")
      .select("status, mode, config")
      .eq("tenant_id", tenant_id)
      .eq("provider", "resend")
      .maybeSingle();
    if (!intRow) return json({ error: "Resend is not entitled to this tenant's plan" }, 409);

    const senderDomain = intRow.config?.sender_domain as string | undefined;
    const verified = intRow.status === "connected";

    // Derive the from-address. In test mode with no verified domain,
    // use Resend's shared onboarding sender so demos work before DNS.
    let fromAddress: string;
    let senderMode: "own_domain" | "resend_test" = "own_domain";
    if (verified && senderDomain) {
      const local = (from_local_part || "noreply").replace(/[^a-z0-9._-]/gi, "");
      fromAddress = from_name
        ? `${from_name} <${local}@${senderDomain}>`
        : `${local}@${senderDomain}`;
    } else if (intRow.mode === "test") {
      fromAddress = "Unite (test) <onboarding@resend.dev>";
      senderMode = "resend_test";
    } else {
      return json({ error: "Sender domain is not verified. Verify it from the Integrations tab or switch to test mode." }, 409);
    }

    // Resend API — Emails.send
    const payload: Record<string, unknown> = {
      from: fromAddress,
      to: Array.isArray(to) ? to : [to],
      subject,
    };
    if (html) payload.html = html;
    if (text) payload.text = text;
    if (reply_to) payload.reply_to = reply_to;
    if (tags) payload.tags = tags;

    const resp = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${RESEND_API_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(payload),
    });
    const r = await resp.json();
    if (!resp.ok) return json({ error: r?.message || "Resend send failed", detail: r }, resp.status);

    return json({
      message_id: r.id,
      from: fromAddress,
      to: payload.to,
      sender_mode: senderMode,
    });
  } catch (err) {
    return json({ error: (err as Error).message || "Internal error" }, 500);
  }
});
