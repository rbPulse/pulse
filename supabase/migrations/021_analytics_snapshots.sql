-- ═══════════════════════════════════════════════════════════════════════════
-- Pulse — Phase 14 migration: analytics_snapshots
-- ═══════════════════════════════════════════════════════════════════════════
--
-- WHAT THIS DOES
--   Creates analytics_snapshots — one row per (tenant_id, snapshot_date,
--   metric_group) tuple — to hold pre-aggregated daily metrics that
--   today's dashboards compute at read-time.
--
--   Phase 14 foundations (this migration plus the platform.html
--   Analytics tabs) render EVERYTHING via read-time aggregation
--   against the live tables. That's fine at Pulse's scale (<50
--   tenants) and simpler to reason about — no staleness, no backfill,
--   no scheduler dependency. This table exists so the daily snapshot
--   job (carry-over; lives as an Edge Function / pg_cron entry) has a
--   place to write to when it lands.
--
--   Shape choice: one row per (tenant, date, metric_group) instead of
--   a wide per-metric column set, so the schema doesn't need a
--   migration every time a new metric gets tracked. `metric_group`
--   partitions the snapshot by subject (e.g. 'funnel', 'sla', 'comms')
--   so a query for "funnel drop-off over time" hits a narrow slice
--   instead of scanning the whole snapshot history.
--
--   `values` JSONB holds the actual metric bag. Stable keys per
--   metric_group by convention (documented by the producer).
--
-- TENANT-NULLABLE
--   tenant_id is nullable so fleet-wide snapshots (sum over all
--   tenants) fit the same shape. NULL means "platform total".
--
-- USAGE
--   Paste into Supabase SQL editor and run. Idempotent.
--
-- ═══════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS analytics_snapshots (
  id             uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id      uuid         REFERENCES tenants(id) ON DELETE CASCADE,
  snapshot_date  date         NOT NULL,
  metric_group   text         NOT NULL,
  values         jsonb        NOT NULL DEFAULT '{}'::jsonb,
  created_at     timestamptz  NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, snapshot_date, metric_group)
);

-- NULL tenant_id means fleet-wide; unique index accounts for the null.
CREATE UNIQUE INDEX IF NOT EXISTS analytics_snapshots_fleet_uq
  ON analytics_snapshots(snapshot_date, metric_group)
  WHERE tenant_id IS NULL;

CREATE INDEX IF NOT EXISTS analytics_snapshots_tenant_group_idx
  ON analytics_snapshots(tenant_id, metric_group, snapshot_date DESC);
CREATE INDEX IF NOT EXISTS analytics_snapshots_group_date_idx
  ON analytics_snapshots(metric_group, snapshot_date DESC);

-- ── RLS ───────────────────────────────────────────────────────────────
-- Tenant staff can read their own rows; platform users read everything.
-- Writes are platform-only (the snapshot job runs as a service role
-- when it lands; until then no one writes).

ALTER TABLE analytics_snapshots ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "analytics_staff_read" ON analytics_snapshots;
CREATE POLICY "analytics_staff_read" ON analytics_snapshots
  FOR SELECT TO authenticated
  USING (
    tenant_id IS NULL
    OR tenant_id IN (SELECT public.current_tenant_ids())
    OR public.is_platform_user()
  );

DROP POLICY IF EXISTS "analytics_platform_write" ON analytics_snapshots;
CREATE POLICY "analytics_platform_write" ON analytics_snapshots
  FOR ALL TO authenticated
  USING (public.is_platform_user())
  WITH CHECK (public.is_platform_user());

-- ── Verify ────────────────────────────────────────────────────────────
SELECT
  (SELECT count(*) FROM pg_tables
     WHERE schemaname = 'public' AND tablename = 'analytics_snapshots')            AS table_exists,
  (SELECT count(*) FROM pg_policies
     WHERE schemaname = 'public' AND tablename = 'analytics_snapshots')            AS policy_count,
  (SELECT count(*) FROM pg_indexes
     WHERE schemaname = 'public' AND tablename = 'analytics_snapshots')            AS index_count;

-- ═══════════════════════════════════════════════════════════════════════════
-- ROLLBACK
-- ═══════════════════════════════════════════════════════════════════════════
--
-- DROP POLICY IF EXISTS "analytics_platform_write" ON analytics_snapshots;
-- DROP POLICY IF EXISTS "analytics_staff_read"     ON analytics_snapshots;
-- DROP TABLE IF EXISTS analytics_snapshots;
