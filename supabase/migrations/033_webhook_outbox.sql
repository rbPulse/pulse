-- ═══════════════════════════════════════════════════════════════════════════
-- Unite — Phase 8a migration: outbound event webhooks
-- ═══════════════════════════════════════════════════════════════════════════
--
-- WHAT THIS DOES
--   Generic, BYO event-webhook pipe. Tenant admins point any HTTPS
--   endpoint (Zapier, n8n, Make, Slack incoming webhook, custom
--   backend) at one or more event types, and the dispatch worker
--   POSTs a signed JSON envelope every time a matching event fires.
--
-- TABLES
--   webhook_subscriptions  — one row per tenant×endpoint registration
--   events_outbox          — every event ever emitted (write-only from
--                             app code via emit_event())
--   webhook_deliveries     — one row per (outbox × subscription)
--                             attempt; carries status_code + retry
--                             metadata for the worker
--
-- ENVELOPE SHAPE (POST body)
--   {
--     "id":             "<uuid>",            // outbox id, idempotent on retries
--     "tenant_id":      "<uuid>",
--     "type":           "refill.paid",
--     "schema_version": 1,
--     "created_at":     "<iso8601>",
--     "data":           { /* event-specific payload */ }
--   }
--
-- SIGNING
--   X-Pulse-Signature: t=<unix>,v1=<hex_hmac_sha256>
--   Receiver computes HMAC_SHA256(secret, "<t>." + raw_body) and
--   compares against the v1 hex. Stripe-style. Worker also sets
--   X-Pulse-Event, X-Pulse-Delivery-Id, X-Pulse-Attempt headers.
--
-- DELIVERY POLICY
--   Worker pulls events in created_at order. For each outbox row:
--     1. Look up enabled subscriptions on the tenant whose
--        event_types[] contains the row's type.
--     2. POST envelope to each. Record a webhook_deliveries row.
--     3. Retry on non-2xx with backoff: 1m, 5m, 30m, 2h, 12h, dead.
--     4. After all subscriptions are delivered or dead-lettered,
--        flip outbox.status to 'delivered' (best effort) or 'failed'.
--   No subscriptions on a tenant for a given event type → outbox
--   row marked 'skipped' immediately so the queue stays clean.
--
-- USAGE
--   Paste into Supabase SQL editor and run. Idempotent.
--
-- ═══════════════════════════════════════════════════════════════════════════

-- ── webhook_subscriptions ──────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS webhook_subscriptions (
  id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id    uuid        NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,

  label        text,                                -- human label e.g. "Slack #refills"
  target_url   text        NOT NULL,
  secret       text        NOT NULL,                -- HMAC signing key (random 32 bytes hex)

  event_types  text[]      NOT NULL DEFAULT '{}',   -- ['refill.paid','refill.approved',...]
  enabled      boolean     NOT NULL DEFAULT true,

  created_by   uuid        REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT webhook_subscriptions_url_https CHECK (target_url ~* '^https?://'),
  CONSTRAINT webhook_subscriptions_event_types_nonempty CHECK (cardinality(event_types) > 0)
);

CREATE INDEX IF NOT EXISTS webhook_subscriptions_tenant_idx
  ON webhook_subscriptions(tenant_id, enabled);

DROP TRIGGER IF EXISTS webhook_subscriptions_set_updated_at ON webhook_subscriptions;
CREATE TRIGGER webhook_subscriptions_set_updated_at
  BEFORE UPDATE ON webhook_subscriptions
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ── events_outbox ──────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS events_outbox (
  id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id    uuid        NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  type         text        NOT NULL,                -- 'refill.paid' etc.
  schema_version integer   NOT NULL DEFAULT 1,
  data         jsonb       NOT NULL DEFAULT '{}'::jsonb,

  status       text        NOT NULL DEFAULT 'pending'
                           CHECK (status IN ('pending','delivering','delivered','failed','skipped')),
  next_attempt_at timestamptz NOT NULL DEFAULT now(),

  created_at   timestamptz NOT NULL DEFAULT now(),
  finalized_at timestamptz
);

-- Worker pulls by (status, next_attempt_at) — small index covers the
-- pending queue scan.
CREATE INDEX IF NOT EXISTS events_outbox_pending_idx
  ON events_outbox(next_attempt_at)
  WHERE status IN ('pending','delivering');

CREATE INDEX IF NOT EXISTS events_outbox_tenant_type_idx
  ON events_outbox(tenant_id, type, created_at DESC);

-- ── webhook_deliveries ─────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS webhook_deliveries (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  outbox_id       uuid        NOT NULL REFERENCES events_outbox(id) ON DELETE CASCADE,
  subscription_id uuid        NOT NULL REFERENCES webhook_subscriptions(id) ON DELETE CASCADE,

  attempt         integer     NOT NULL DEFAULT 1,
  status          text        NOT NULL DEFAULT 'pending'
                              CHECK (status IN ('pending','success','failure','dead_letter')),
  status_code     integer,
  response_body   text,                              -- truncated to 2KB at write time
  error_message   text,
  latency_ms      integer,

  attempted_at    timestamptz NOT NULL DEFAULT now(),
  next_retry_at   timestamptz
);

CREATE INDEX IF NOT EXISTS webhook_deliveries_outbox_idx
  ON webhook_deliveries(outbox_id, attempt DESC);

CREATE INDEX IF NOT EXISTS webhook_deliveries_sub_recent_idx
  ON webhook_deliveries(subscription_id, attempted_at DESC);

CREATE INDEX IF NOT EXISTS webhook_deliveries_retry_queue_idx
  ON webhook_deliveries(next_retry_at)
  WHERE status = 'failure' AND next_retry_at IS NOT NULL;

-- ── emit_event() helper ────────────────────────────────────────────────
-- App code calls this from anywhere — edge functions, RPC handlers,
-- triggers — to broadcast an event to every matching subscription.
-- If the tenant has no enabled subscriptions for this type the row
-- is created with status='skipped' so we still have a full audit
-- trail of every event the platform emitted.

CREATE OR REPLACE FUNCTION emit_event(
  p_tenant_id uuid,
  p_type      text,
  p_data      jsonb DEFAULT '{}'::jsonb,
  p_schema_version integer DEFAULT 1
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id          uuid;
  v_match_count integer;
BEGIN
  IF p_tenant_id IS NULL OR p_type IS NULL THEN
    RAISE EXCEPTION 'emit_event requires tenant_id and type';
  END IF;

  -- Count matching enabled subscriptions on this tenant. If zero, we
  -- mark the outbox row 'skipped' immediately so the worker doesn't
  -- pull it.
  SELECT count(*) INTO v_match_count
  FROM webhook_subscriptions
  WHERE tenant_id = p_tenant_id
    AND enabled = true
    AND p_type = ANY (event_types);

  INSERT INTO events_outbox (tenant_id, type, schema_version, data, status, finalized_at)
  VALUES (
    p_tenant_id,
    p_type,
    COALESCE(p_schema_version, 1),
    COALESCE(p_data, '{}'::jsonb),
    CASE WHEN v_match_count = 0 THEN 'skipped' ELSE 'pending' END,
    CASE WHEN v_match_count = 0 THEN now() ELSE NULL END
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

COMMENT ON FUNCTION emit_event IS
  'Phase 8 — write a row to events_outbox so the webhook-dispatch worker fans it out to matching subscriptions. Returns the outbox id.';

GRANT EXECUTE ON FUNCTION emit_event(uuid, text, jsonb, integer) TO authenticated, service_role;

-- ── RLS ────────────────────────────────────────────────────────────────

ALTER TABLE webhook_subscriptions ENABLE ROW LEVEL SECURITY;
ALTER TABLE events_outbox        ENABLE ROW LEVEL SECURITY;
ALTER TABLE webhook_deliveries   ENABLE ROW LEVEL SECURITY;

-- webhook_subscriptions: tenant admins/owners on the same tenant can
-- SELECT + INSERT + UPDATE + DELETE. Platform users see all.
DROP POLICY IF EXISTS "webhook_subscriptions_tenant_admin_all" ON webhook_subscriptions;
CREATE POLICY "webhook_subscriptions_tenant_admin_all" ON webhook_subscriptions
  FOR ALL TO authenticated
  USING (
    tenant_id IN (
      SELECT tenant_id FROM tenant_memberships
      WHERE user_id = auth.uid()
        AND role IN ('tenant_admin', 'tenant_owner')
    )
  )
  WITH CHECK (
    tenant_id IN (
      SELECT tenant_id FROM tenant_memberships
      WHERE user_id = auth.uid()
        AND role IN ('tenant_admin', 'tenant_owner')
    )
  );

DROP POLICY IF EXISTS "webhook_subscriptions_platform_all" ON webhook_subscriptions;
CREATE POLICY "webhook_subscriptions_platform_all" ON webhook_subscriptions
  FOR ALL TO authenticated
  USING (public.is_platform_user())
  WITH CHECK (public.is_platform_user());

-- events_outbox: tenant admins can SELECT (audit/visibility). Writes
-- happen via emit_event() (security definer) or service_role only.
DROP POLICY IF EXISTS "events_outbox_tenant_admin_read" ON events_outbox;
CREATE POLICY "events_outbox_tenant_admin_read" ON events_outbox
  FOR SELECT TO authenticated
  USING (
    tenant_id IN (
      SELECT tenant_id FROM tenant_memberships
      WHERE user_id = auth.uid()
        AND role IN ('tenant_admin', 'tenant_owner')
    )
  );

DROP POLICY IF EXISTS "events_outbox_platform_all" ON events_outbox;
CREATE POLICY "events_outbox_platform_all" ON events_outbox
  FOR ALL TO authenticated
  USING (public.is_platform_user())
  WITH CHECK (public.is_platform_user());

-- webhook_deliveries: tenant admins can SELECT for the delivery log
-- UI. Writes are service_role only (worker).
DROP POLICY IF EXISTS "webhook_deliveries_tenant_admin_read" ON webhook_deliveries;
CREATE POLICY "webhook_deliveries_tenant_admin_read" ON webhook_deliveries
  FOR SELECT TO authenticated
  USING (
    subscription_id IN (
      SELECT id FROM webhook_subscriptions
      WHERE tenant_id IN (
        SELECT tenant_id FROM tenant_memberships
        WHERE user_id = auth.uid()
          AND role IN ('tenant_admin', 'tenant_owner')
      )
    )
  );

DROP POLICY IF EXISTS "webhook_deliveries_platform_all" ON webhook_deliveries;
CREATE POLICY "webhook_deliveries_platform_all" ON webhook_deliveries
  FOR ALL TO authenticated
  USING (public.is_platform_user())
  WITH CHECK (public.is_platform_user());

-- ── Verify ─────────────────────────────────────────────────────────────

SELECT
  (SELECT count(*) FROM pg_tables WHERE schemaname='public' AND tablename='webhook_subscriptions') AS subscriptions_exists,
  (SELECT count(*) FROM pg_tables WHERE schemaname='public' AND tablename='events_outbox')        AS outbox_exists,
  (SELECT count(*) FROM pg_tables WHERE schemaname='public' AND tablename='webhook_deliveries')   AS deliveries_exists,
  (SELECT count(*) FROM pg_proc  WHERE proname='emit_event')                                      AS emit_event_exists;
