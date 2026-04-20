-- ═══════════════════════════════════════════════════════════════════════════
-- Pulse — Phase 0 migration: tenant scoping of existing data
-- ═══════════════════════════════════════════════════════════════════════════
--
-- WHAT THIS DOES
--   Adds tenant_id to every tenant-scoped existing table, backfills all
--   existing rows to the Pulse tenant, and splits today's
--   profiles.role values into the new staff/patient tables introduced
--   by migration 010.
--
--   RLS policies on existing tables are deliberately NOT changed here.
--   Pulse continues to operate under its current policies so nothing
--   breaks. The RLS swap to tenant-scoped policies happens in a later
--   migration after tenant.js and the auth wrapper are in place.
--
--   Operations per tenant-scoped table:
--     1. Add tenant_id column (nullable first)
--     2. Set DEFAULT = Pulse UUID so new inserts don't fail while
--        application code is still catching up
--     3. Backfill any NULL rows
--     4. NOT NULL constraint
--     5. FK to tenants(id)
--     6. Index on tenant_id
--
--   Special-case: audit_logs has a BEFORE UPDATE tamper-protection
--   trigger (migration 009) that blocks backfill UPDATEs. We disable
--   the trigger, run the backfill, re-enable. The trigger is only
--   disabled for the duration of the DO block.
--
-- USAGE
--   Paste into Supabase SQL editor. Idempotent — safe to re-run.
--   Recommended: take a database backup first. This is the only
--   Phase 0 migration that touches existing data.
--
-- ROLLBACK
--   See `ROLLBACK` block at the bottom. This migration is forward-
--   only safe (no data destruction) but the tenant_id columns can
--   be dropped if needed.
--
-- ═══════════════════════════════════════════════════════════════════════════

-- ── Tenant-scope the 16 existing tenant-owned tables ─────────────────────

DO $$
DECLARE
  tbl              text;
  pulse_uuid       uuid := '00000000-0000-0000-0000-000000000001';
  audit_trigger_on boolean;
BEGIN
  FOREACH tbl IN ARRAY ARRAY[
    -- Clinical + patient data
    'consultations', 'prescriptions', 'prescription_versions',
    'patient_notes', 'patient_events', 'dose_logs',
    -- Communication + scheduling
    'messages', 'appointments', 'notifications',
    'availability', 'support_requests',
    -- Catalog / config
    'protocol_templates', 'protocol_categories', 'protocol_product_types',
    'platform_automations',
    -- Governance
    'audit_logs'
  ] LOOP
    -- Skip if table doesn't exist (defensive against partial installs)
    IF NOT EXISTS (
      SELECT 1 FROM information_schema.tables
      WHERE table_schema = 'public' AND table_name = tbl
    ) THEN
      RAISE NOTICE '  skipping %: table does not exist', tbl;
      CONTINUE;
    END IF;

    -- 1. Add column if missing
    EXECUTE format(
      'ALTER TABLE public.%I ADD COLUMN IF NOT EXISTS tenant_id uuid',
      tbl
    );

    -- 2. Set default → Pulse UUID (idempotent; safe if default already set)
    EXECUTE format(
      'ALTER TABLE public.%I ALTER COLUMN tenant_id SET DEFAULT %L',
      tbl, pulse_uuid
    );

    -- 3. Backfill any NULL rows. Always run the UPDATE — it's a no-op
    --    when nothing is null. audit_logs has a BEFORE UPDATE trigger
    --    (migration 009) that blocks every UPDATE; disable it around
    --    the backfill only if it actually exists.
    IF tbl = 'audit_logs' THEN
      SELECT EXISTS (
        SELECT 1 FROM pg_trigger
        WHERE tgrelid = 'public.audit_logs'::regclass
          AND tgname = 'audit_logs_no_update'
      ) INTO audit_trigger_on;

      IF audit_trigger_on THEN
        EXECUTE 'ALTER TABLE public.audit_logs DISABLE TRIGGER audit_logs_no_update';
      END IF;

      EXECUTE format(
        'UPDATE public.%I SET tenant_id = %L WHERE tenant_id IS NULL',
        tbl, pulse_uuid
      );

      IF audit_trigger_on THEN
        EXECUTE 'ALTER TABLE public.audit_logs ENABLE TRIGGER audit_logs_no_update';
      END IF;
    ELSE
      EXECUTE format(
        'UPDATE public.%I SET tenant_id = %L WHERE tenant_id IS NULL',
        tbl, pulse_uuid
      );
    END IF;

    -- 4. NOT NULL (safe now that all rows have a value)
    EXECUTE format('ALTER TABLE public.%I ALTER COLUMN tenant_id SET NOT NULL', tbl);

    -- 5. FK to tenants(id). Drop-then-add for idempotency (Postgres has
    --    no ADD CONSTRAINT IF NOT EXISTS).
    EXECUTE format(
      'ALTER TABLE public.%I DROP CONSTRAINT IF EXISTS %I',
      tbl, tbl || '_tenant_id_fkey'
    );
    EXECUTE format(
      'ALTER TABLE public.%I ADD CONSTRAINT %I FOREIGN KEY (tenant_id) REFERENCES public.tenants(id)',
      tbl, tbl || '_tenant_id_fkey'
    );

    -- 6. Index for tenant-scoped queries
    EXECUTE format(
      'CREATE INDEX IF NOT EXISTS %I ON public.%I(tenant_id)',
      tbl || '_tenant_id_idx', tbl
    );

    RAISE NOTICE '  scoped % with tenant_id', tbl;
  END LOOP;
END $$;

-- ── Split profiles.role into tenant_memberships + patient_enrollments ────

-- Clinicians → tenant_memberships as tenant_clinician at Pulse
INSERT INTO tenant_memberships (user_id, tenant_id, role)
SELECT
  user_id,
  '00000000-0000-0000-0000-000000000001',
  'tenant_clinician'::tenant_role
FROM profiles
WHERE role = 'clinician'
  AND user_id IS NOT NULL
ON CONFLICT (user_id, tenant_id) DO NOTHING;

-- Admins → tenant_memberships as tenant_admin at Pulse
INSERT INTO tenant_memberships (user_id, tenant_id, role)
SELECT
  user_id,
  '00000000-0000-0000-0000-000000000001',
  'tenant_admin'::tenant_role
FROM profiles
WHERE role = 'admin'
  AND user_id IS NOT NULL
ON CONFLICT (user_id, tenant_id) DO NOTHING;

-- Members (and legacy NULL role) → patient_enrollments as active at Pulse
INSERT INTO patient_enrollments (user_id, tenant_id, status)
SELECT
  user_id,
  '00000000-0000-0000-0000-000000000001',
  'active'::patient_enrollment_status
FROM profiles
WHERE (role = 'member' OR role IS NULL)
  AND user_id IS NOT NULL
ON CONFLICT (user_id, tenant_id) DO NOTHING;

-- ── Backfill platform_role on profiles for Pulse internal operators ──────

-- super_admins → platform_super_admin
UPDATE profiles
SET platform_role = 'platform_super_admin'::platform_role
WHERE admin_role = 'super_admin'
  AND platform_role IS NULL;

-- Non-super platform admins → platform_admin
UPDATE profiles
SET platform_role = 'platform_admin'::platform_role
WHERE admin_role = 'admin'
  AND platform_role IS NULL;

-- ── Verify ───────────────────────────────────────────────────────────────

SELECT
  -- Count of tables that now have a tenant_id column
  (SELECT count(*) FROM information_schema.columns
     WHERE table_schema = 'public'
       AND column_name = 'tenant_id'
       AND table_name IN (
         'consultations', 'prescriptions', 'prescription_versions',
         'patient_notes', 'patient_events', 'dose_logs',
         'messages', 'appointments', 'notifications',
         'availability', 'support_requests',
         'protocol_templates', 'protocol_categories',
         'protocol_product_types', 'platform_automations', 'audit_logs'
       )
  ) AS tables_with_tenant_id,
  (SELECT count(*) FROM tenant_memberships
     WHERE tenant_id = '00000000-0000-0000-0000-000000000001')
     AS pulse_staff_count,
  (SELECT count(*) FROM patient_enrollments
     WHERE tenant_id = '00000000-0000-0000-0000-000000000001')
     AS pulse_patient_count,
  (SELECT count(*) FROM profiles
     WHERE platform_role IS NOT NULL)
     AS platform_operators_count;

-- ═══════════════════════════════════════════════════════════════════════════
-- ROLLBACK  (run only if you need to undo this migration)
-- ═══════════════════════════════════════════════════════════════════════════
--
-- -- Drop tenant_id columns from every scoped table
-- DO $$
-- DECLARE tbl text;
-- BEGIN
--   FOREACH tbl IN ARRAY ARRAY[
--     'consultations', 'prescriptions', 'prescription_versions',
--     'patient_notes', 'patient_events', 'dose_logs',
--     'messages', 'appointments', 'notifications',
--     'availability', 'support_requests',
--     'protocol_templates', 'protocol_categories', 'protocol_product_types',
--     'platform_automations', 'audit_logs'
--   ] LOOP
--     EXECUTE format('ALTER TABLE public.%I DROP COLUMN IF EXISTS tenant_id CASCADE', tbl);
--   END LOOP;
-- END $$;
--
-- -- Wipe the backfilled rows in the new tables
-- DELETE FROM patient_enrollments
--   WHERE tenant_id = '00000000-0000-0000-0000-000000000001';
-- DELETE FROM tenant_memberships
--   WHERE tenant_id = '00000000-0000-0000-0000-000000000001';
--
-- -- Clear platform_role
-- UPDATE profiles SET platform_role = NULL;
