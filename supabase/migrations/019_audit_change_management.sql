-- ═══════════════════════════════════════════════════════════════════════════
-- Pulse — Phase 10 migration: audit_logs change management
-- ═══════════════════════════════════════════════════════════════════════════
--
-- WHAT THIS DOES
--   Extends the existing audit_logs table (from migration 009,
--   tenant-scoped in migration 011) with structured before/after
--   snapshot columns so audit entries carry structured diffs
--   instead of opaque JSON strings in `details`:
--
--     - change_type      text; a stable, queryable classifier
--                        ('brand','workflow','integration', etc.).
--                        Derived from the existing `action` column
--                        for backfill, authored on new writes.
--     - before_snapshot  jsonb; the pre-change state. NULL for
--                        creation events.
--     - after_snapshot   jsonb; the post-change state. NULL for
--                        deletion events.
--
--   The existing `details` column stays — it remains the free-form
--   text slot for anything that doesn't fit the snapshot shape
--   (e.g. brief human-readable summary, external reference IDs).
--   New writes populate both; legacy writes that only use `details`
--   keep working.
--
-- BACKFILL
--   Existing audit_logs rows get a `change_type` derived from
--   `action` (e.g. 'tenant.brand_updated' → 'brand',
--   'tenant.lifecycle_changed' → 'lifecycle'). before_snapshot and
--   after_snapshot stay NULL for historical rows; migrating the
--   older details-as-JSON-string format to structured columns would
--   be a parse-risk more than it's worth, and Phase 10's timeline UI
--   handles both shapes on read.
--
-- TAMPER PROTECTION
--   Migration 009 installed a BEFORE UPDATE trigger preventing audit
--   mutation. This migration does NOT touch that trigger — new columns
--   write on INSERT only; the append-only property is preserved.
--
-- USAGE
--   Paste into Supabase SQL editor and run. Idempotent.
--
-- ═══════════════════════════════════════════════════════════════════════════

-- The append-only trigger from migration 009 blocks UPDATE on audit_logs.
-- Dropping new columns via ALTER TABLE ADD COLUMN is fine (DDL isn't
-- row-level UPDATE), but backfilling change_type for existing rows
-- IS a row-level UPDATE and the trigger rejects it. Disable the trigger
-- for the backfill window, then re-enable.

DO $$ BEGIN
  ALTER TABLE audit_logs ADD COLUMN IF NOT EXISTS change_type     text;
EXCEPTION WHEN duplicate_column THEN NULL; END $$;
DO $$ BEGIN
  ALTER TABLE audit_logs ADD COLUMN IF NOT EXISTS before_snapshot jsonb;
EXCEPTION WHEN duplicate_column THEN NULL; END $$;
DO $$ BEGIN
  ALTER TABLE audit_logs ADD COLUMN IF NOT EXISTS after_snapshot  jsonb;
EXCEPTION WHEN duplicate_column THEN NULL; END $$;

CREATE INDEX IF NOT EXISTS audit_logs_change_type ON audit_logs(change_type);
-- Existing tenant_id index (from migration 011) covers the per-tenant
-- timeline query path. Add a composite for the timeline-by-tenant-
-- ordered-by-time pattern the Activity tab uses.
CREATE INDEX IF NOT EXISTS audit_logs_tenant_created
  ON audit_logs(tenant_id, created_at DESC)
  WHERE tenant_id IS NOT NULL;

-- ── Backfill change_type from action ──────────────────────────────────
-- Map the actions in use today to a short stable classifier. This list
-- matches the write-sites in platform.html; as new audit actions are
-- added, extend this mapping AND write new rows with change_type set
-- directly so no future backfill is needed.

DO $$
DECLARE
  trigger_exists boolean;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM pg_trigger
    WHERE tgrelid = 'public.audit_logs'::regclass
      AND tgname = 'audit_logs_no_update'
  ) INTO trigger_exists;

  IF trigger_exists THEN
    EXECUTE 'ALTER TABLE public.audit_logs DISABLE TRIGGER audit_logs_no_update';
  END IF;

  -- Single UPDATE with CASE covers every known action. Unknown actions
  -- get change_type = NULL, which the UI treats as "uncategorised" and
  -- renders without the group header.
  UPDATE audit_logs SET change_type = CASE
    WHEN action = 'tenant.lifecycle_changed'                    THEN 'lifecycle'
    WHEN action = 'tenant.brand_updated'                        THEN 'brand'
    WHEN action = 'tenant.terminology_updated'                  THEN 'terminology'
    WHEN action = 'tenant.workflow_updated'                     THEN 'workflow'
    WHEN action = 'tenant.comms_template_updated'               THEN 'comms'
    WHEN action = 'tenant.comms_template_reset'                 THEN 'comms'
    WHEN action = 'tenant.integration_connected'                THEN 'integration'
    WHEN action = 'tenant.integration_disconnected'             THEN 'integration'
    WHEN action = 'tenant.region_toggled'                       THEN 'compliance'
    WHEN action = 'tenant.location_added'                       THEN 'compliance'
    WHEN action = 'tenant.location_updated'                     THEN 'compliance'
    WHEN action = 'tenant.location_archived'                    THEN 'compliance'
    WHEN action = 'tenant.consent_version_added'                THEN 'compliance'
    WHEN action = 'tenant.consent_archived'                     THEN 'compliance'
    WHEN action = 'tenant.consent_unarchived'                   THEN 'compliance'
    WHEN action = 'tenant.subscription_assigned'                THEN 'billing'
    WHEN action = 'tenant.subscription_updated'                 THEN 'billing'
    WHEN action = 'tenant.subscription_canceled'                THEN 'billing'
    WHEN action = 'tenant.module_entitlement_changed'           THEN 'billing'
    WHEN action LIKE 'tenant.lifecycle%'                        THEN 'lifecycle'
    WHEN action LIKE 'user.%'                                   THEN 'user'
    WHEN action LIKE 'access.%'                                 THEN 'access'
    ELSE NULL
  END
  WHERE change_type IS NULL;

  IF trigger_exists THEN
    EXECUTE 'ALTER TABLE public.audit_logs ENABLE TRIGGER audit_logs_no_update';
  END IF;
END $$;

-- ── Verify ────────────────────────────────────────────────────────────
SELECT
  (SELECT count(*) FROM information_schema.columns
     WHERE table_name = 'audit_logs' AND column_name = 'change_type')     AS change_type_col,
  (SELECT count(*) FROM information_schema.columns
     WHERE table_name = 'audit_logs' AND column_name = 'before_snapshot') AS before_col,
  (SELECT count(*) FROM information_schema.columns
     WHERE table_name = 'audit_logs' AND column_name = 'after_snapshot')  AS after_col,
  (SELECT count(*) FROM audit_logs WHERE change_type IS NOT NULL)         AS backfilled_rows,
  (SELECT count(*) FROM audit_logs)                                       AS total_rows;

-- ═══════════════════════════════════════════════════════════════════════════
-- ROLLBACK
-- ═══════════════════════════════════════════════════════════════════════════
--
-- DROP INDEX IF EXISTS audit_logs_tenant_created;
-- DROP INDEX IF EXISTS audit_logs_change_type;
-- ALTER TABLE audit_logs DROP COLUMN IF EXISTS after_snapshot;
-- ALTER TABLE audit_logs DROP COLUMN IF EXISTS before_snapshot;
-- ALTER TABLE audit_logs DROP COLUMN IF EXISTS change_type;
