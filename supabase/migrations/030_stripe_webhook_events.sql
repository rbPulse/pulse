-- ═══════════════════════════════════════════════════════════════════════════
-- Unite — Phase 4c migration: stripe_webhook_events
-- ═══════════════════════════════════════════════════════════════════════════
--
-- WHAT THIS DOES
--   Creates a table that records every Stripe webhook event Unite
--   receives. Serves two purposes:
--
--     1. Dedup — Stripe retries delivery on non-2xx responses and
--        occasionally double-delivers even on success. The edge
--        function looks up the incoming event.id here before acting;
--        a row that's already processed skips the side effects.
--
--     2. Audit — platform operators can see exactly which Stripe
--        events were received, for which tenant, and whether they
--        were processed successfully. Failed processing leaves an
--        error message + created_at, so reprocessing is a manual
--        SQL action against this table.
--
--   Credentials / card numbers DO NOT end up here. Stripe's webhook
--   payloads carry metadata + IDs, not PAN data. Still, the table
--   is platform-read-only — tenant staff have no direct access.
--
-- USAGE
--   Paste into Supabase SQL editor and run. Idempotent.
--
-- ═══════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS stripe_webhook_events (
  id                 text         PRIMARY KEY,        -- Stripe's event.id (evt_...)
  tenant_id          uuid         REFERENCES tenants(id) ON DELETE SET NULL,
  stripe_account_id  text,                             -- Connected account that triggered the event
  event_type         text         NOT NULL,            -- e.g. 'payment_intent.succeeded'
  livemode           boolean      NOT NULL DEFAULT false,
  payload            jsonb        NOT NULL,            -- full event body for replay / debug
  processed_at       timestamptz,                      -- NULL until handler finishes cleanly
  error              text,                             -- populated if handler throws
  received_at        timestamptz  NOT NULL DEFAULT now(),
  created_at         timestamptz  NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS stripe_webhook_events_tenant_idx
  ON stripe_webhook_events(tenant_id, received_at DESC);
CREATE INDEX IF NOT EXISTS stripe_webhook_events_type_idx
  ON stripe_webhook_events(event_type, received_at DESC);
CREATE INDEX IF NOT EXISTS stripe_webhook_events_unprocessed_idx
  ON stripe_webhook_events(received_at)
  WHERE processed_at IS NULL;

ALTER TABLE stripe_webhook_events ENABLE ROW LEVEL SECURITY;

-- Platform users can read the whole table; tenant staff have no
-- direct access. Writes come from the webhook edge function via
-- the service role — no RLS policy needed for that path.
DROP POLICY IF EXISTS "stripe_webhook_events_platform_read" ON stripe_webhook_events;
CREATE POLICY "stripe_webhook_events_platform_read" ON stripe_webhook_events
  FOR SELECT TO authenticated
  USING (public.is_platform_user());

SELECT
  (SELECT count(*) FROM pg_tables
     WHERE schemaname='public' AND tablename='stripe_webhook_events')  AS table_exists,
  (SELECT count(*) FROM pg_indexes
     WHERE schemaname='public' AND tablename='stripe_webhook_events')  AS index_count,
  (SELECT count(*) FROM pg_policies
     WHERE schemaname='public' AND tablename='stripe_webhook_events')  AS policy_count;
