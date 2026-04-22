// ═══════════════════════════════════════════════════════════════════════════
// webhook-dispatch — Phase 8a: outbound event webhook delivery worker
// ═══════════════════════════════════════════════════════════════════════════
//
// WHAT THIS DOES
//   Polls events_outbox for pending rows + failed rows whose
//   next_retry_at has elapsed, fans them out to every matching
//   webhook_subscriptions row, POSTs a signed JSON envelope, records
//   each delivery attempt in webhook_deliveries, retries failures
//   with exponential backoff, and dead-letters after the cap.
//
// SCHEDULING
//   Designed to be invoked on a cron (Supabase pg_cron or external).
//   Each invocation processes up to BATCH_SIZE outbox rows. Calling
//   it more often than ~30s is fine — rows are claimed via
//   status='delivering' so concurrent invocations don't double-fire.
//
// SIGNING
//   Stripe-style: X-Pulse-Signature: t=<unix>,v1=<hex_hmac_sha256>
//   Receiver computes HMAC_SHA256(secret, t + "." + raw_body) and
//   compares against v1.
//
// CALLER
//   POST /functions/v1/webhook-dispatch
//     Body: optional { batch_size?: number }
//     Headers: Authorization: Bearer <service_role>  (or platform JWT)
//
// ═══════════════════════════════════════════════════════════════════════════

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const FN_VERSION = "8a-dispatch-v1";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const BATCH_SIZE_DEFAULT = 25;
const PER_DELIVERY_TIMEOUT_MS = 10_000;
const RESPONSE_BODY_CAP = 2000;

// Backoff schedule. attempt N (1-indexed) → minutes until next retry.
// After RETRY_DELAYS_MIN.length attempts, the delivery is dead-lettered.
const RETRY_DELAYS_MIN = [1, 5, 30, 120, 720];

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });
}

interface OutboxRow {
  id: string;
  tenant_id: string;
  type: string;
  schema_version: number;
  data: Record<string, unknown>;
  created_at: string;
}
interface SubscriptionRow {
  id: string;
  tenant_id: string;
  target_url: string;
  secret: string;
  event_types: string[];
  enabled: boolean;
}

async function hmacSha256Hex(secret: string, message: string): Promise<string> {
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    enc.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sigBuf = await crypto.subtle.sign("HMAC", key, enc.encode(message));
  return Array.from(new Uint8Array(sigBuf))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

function buildEnvelope(row: OutboxRow): string {
  return JSON.stringify({
    id:             row.id,
    tenant_id:      row.tenant_id,
    type:           row.type,
    schema_version: row.schema_version,
    created_at:     row.created_at,
    data:           row.data,
  });
}

async function postWithTimeout(
  url: string,
  body: string,
  headers: Record<string, string>,
  timeoutMs: number,
): Promise<{ status: number; bodyText: string; latencyMs: number; errorMessage?: string }> {
  const ac = new AbortController();
  const tid = setTimeout(() => ac.abort(), timeoutMs);
  const t0 = Date.now();
  try {
    const resp = await fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json", ...headers },
      body,
      signal: ac.signal,
    });
    const text = (await resp.text()).slice(0, RESPONSE_BODY_CAP);
    return { status: resp.status, bodyText: text, latencyMs: Date.now() - t0 };
  } catch (err) {
    return {
      status: 0,
      bodyText: "",
      latencyMs: Date.now() - t0,
      errorMessage: (err as Error).message || String(err),
    };
  } finally {
    clearTimeout(tid);
  }
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });

  console.log(`[webhook-dispatch] ${FN_VERSION} invoked`);
  const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY);

  let batchSize = BATCH_SIZE_DEFAULT;
  try {
    const body = await req.json().catch(() => ({}));
    if (body && typeof body.batch_size === "number" && body.batch_size > 0) {
      batchSize = Math.min(100, Math.floor(body.batch_size));
    }
  } catch (_) { /* no body, use defaults */ }

  // 1. Pull pending outbox rows whose next_attempt_at has elapsed.
  //    Order by created_at ASC so we drain in FIFO. Status flips to
  //    'delivering' as we claim each row to prevent double-fire from
  //    overlapping invocations.
  const { data: pending, error: pendErr } = await supabase
    .from("events_outbox")
    .select("id, tenant_id, type, schema_version, data, created_at")
    .eq("status", "pending")
    .lte("next_attempt_at", new Date().toISOString())
    .order("created_at", { ascending: true })
    .limit(batchSize);

  if (pendErr) {
    console.error("[webhook-dispatch] outbox query failed:", pendErr.message);
    return json({ error: pendErr.message, version: FN_VERSION }, 500);
  }

  const rows = (pending || []) as OutboxRow[];
  if (rows.length === 0) {
    return json({ version: FN_VERSION, processed: 0, deliveries: 0 });
  }

  let totalDeliveries = 0;
  let totalSuccess = 0;
  let totalFailure = 0;
  let totalDeadLetter = 0;

  for (const row of rows) {
    // Claim this row so concurrent invocations skip it.
    const { error: claimErr } = await supabase
      .from("events_outbox")
      .update({ status: "delivering" })
      .eq("id", row.id)
      .eq("status", "pending");
    if (claimErr) {
      console.warn(`[webhook-dispatch] claim failed for ${row.id}:`, claimErr.message);
      continue;
    }

    // Fetch matching subscriptions on this tenant. We requery every
    // claim so the worker picks up new subscriptions registered
    // between events without restart.
    const { data: subs, error: subsErr } = await supabase
      .from("webhook_subscriptions")
      .select("id, tenant_id, target_url, secret, event_types, enabled")
      .eq("tenant_id", row.tenant_id)
      .eq("enabled", true)
      .contains("event_types", [row.type]);

    if (subsErr) {
      console.error(`[webhook-dispatch] subs query failed for ${row.id}:`, subsErr.message);
      // Put it back so a later invocation tries again.
      await supabase
        .from("events_outbox")
        .update({ status: "pending" })
        .eq("id", row.id);
      continue;
    }

    const matches = (subs || []) as SubscriptionRow[];
    if (matches.length === 0) {
      // No subscribers — mark skipped (shouldn't happen if emit_event
      // counted correctly, but defends against subscription churn
      // between emit and dispatch).
      await supabase
        .from("events_outbox")
        .update({ status: "skipped", finalized_at: new Date().toISOString() })
        .eq("id", row.id);
      continue;
    }

    const envelope = buildEnvelope(row);
    let allDelivered = true;

    for (const sub of matches) {
      // Find the latest attempt count for this (outbox, subscription)
      // pair so retries get an incrementing attempt number.
      const { data: prior } = await supabase
        .from("webhook_deliveries")
        .select("attempt")
        .eq("outbox_id", row.id)
        .eq("subscription_id", sub.id)
        .order("attempt", { ascending: false })
        .limit(1);
      const lastAttempt = (prior && prior[0]?.attempt) || 0;
      const attempt = lastAttempt + 1;

      const t = Math.floor(Date.now() / 1000).toString();
      const sigPayload = `${t}.${envelope}`;
      const sig = await hmacSha256Hex(sub.secret, sigPayload);
      const headers: Record<string, string> = {
        "X-Pulse-Signature":   `t=${t},v1=${sig}`,
        "X-Pulse-Event":       row.type,
        "X-Pulse-Delivery-Id": row.id,
        "X-Pulse-Attempt":     String(attempt),
        "User-Agent":          "Pulse-Webhook/1.0",
      };

      const result = await postWithTimeout(
        sub.target_url,
        envelope,
        headers,
        PER_DELIVERY_TIMEOUT_MS,
      );

      const success = result.status >= 200 && result.status < 300;
      let nextRetryAt: string | null = null;
      let deliveryStatus: "success" | "failure" | "dead_letter" = success
        ? "success"
        : (attempt >= RETRY_DELAYS_MIN.length ? "dead_letter" : "failure");

      if (deliveryStatus === "failure") {
        const minutes = RETRY_DELAYS_MIN[attempt - 1] ?? RETRY_DELAYS_MIN[RETRY_DELAYS_MIN.length - 1];
        nextRetryAt = new Date(Date.now() + minutes * 60_000).toISOString();
      }

      const { error: insertErr } = await supabase
        .from("webhook_deliveries")
        .insert({
          outbox_id:       row.id,
          subscription_id: sub.id,
          attempt,
          status:          deliveryStatus,
          status_code:     result.status || null,
          response_body:   result.bodyText || null,
          error_message:   result.errorMessage || null,
          latency_ms:      result.latencyMs,
          next_retry_at:   nextRetryAt,
        });
      if (insertErr) {
        console.warn(`[webhook-dispatch] delivery insert failed:`, insertErr.message);
      }

      totalDeliveries++;
      if (success) totalSuccess++;
      else if (deliveryStatus === "dead_letter") { totalFailure++; totalDeadLetter++; }
      else totalFailure++;

      if (!success) allDelivered = false;
    }

    // If any delivery for this row needs another attempt, schedule
    // the outbox row to be re-pulled at the earliest retry time. If
    // every delivery succeeded or hit dead-letter, finalize.
    if (allDelivered) {
      await supabase
        .from("events_outbox")
        .update({ status: "delivered", finalized_at: new Date().toISOString() })
        .eq("id", row.id);
    } else {
      // Pull the soonest pending retry for this outbox to schedule
      // the next dispatch pass.
      const { data: nextRetryRows } = await supabase
        .from("webhook_deliveries")
        .select("next_retry_at, status")
        .eq("outbox_id", row.id)
        .eq("status", "failure")
        .not("next_retry_at", "is", null)
        .order("next_retry_at", { ascending: true })
        .limit(1);
      const nextAt = nextRetryRows?.[0]?.next_retry_at;

      // Are there any deliveries still retriable? If every match is
      // dead_letter or success but we landed here because some hit
      // dead_letter, finalize as 'failed'.
      if (nextAt) {
        await supabase
          .from("events_outbox")
          .update({ status: "pending", next_attempt_at: nextAt })
          .eq("id", row.id);
      } else {
        await supabase
          .from("events_outbox")
          .update({ status: "failed", finalized_at: new Date().toISOString() })
          .eq("id", row.id);
      }
    }
  }

  return json({
    version: FN_VERSION,
    processed: rows.length,
    deliveries: totalDeliveries,
    success: totalSuccess,
    failure: totalFailure,
    dead_letter: totalDeadLetter,
  });
});
