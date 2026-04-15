-- ═══════════════════════════════════════════════════════════════════════════
-- Pulse — Phase 1 migration: relational prescriptions model
-- ═══════════════════════════════════════════════════════════════════════════
--
-- WHAT THIS DOES
--   1. Wipes all test-member data (you paste the UUIDs before running)
--   2. Drops prescription-related columns from `consultations` and `profiles`
--   3. Creates `prescriptions` table (one row per active/past Rx)
--   4. Creates `prescription_versions` table (audit trail per Rx)
--   5. Updates `dose_logs` to reference prescriptions by id
--   6. Adds indexes + RLS policies
--
-- BEFORE RUNNING
--   - Take a database snapshot in Supabase (Database → Backups) for safety.
--   - Open the Supabase SQL editor, paste this WHOLE file.
--   - Run Section 0 first to identify the three test members and copy
--     their UUIDs into Section 1.
--   - Run Section 1 to wipe those users' rows in the custom tables.
--   - Manually delete the three test users from the Supabase dashboard
--     (Authentication → Users). The SQL cannot touch `auth.users` directly.
--   - Run Sections 2–6 in order.
--   - Run Section 7 at the end to verify the migration succeeded.
--
-- ROLLBACK
--   None. This is destructive and one-way. The snapshot is your safety net.
--
-- ═══════════════════════════════════════════════════════════════════════════


-- ─────────────────────────────────────────────────────────────────────────
-- Section 0 — Identify test members (read-only, safe)
-- ─────────────────────────────────────────────────────────────────────────
-- Run this first. Copy the UUIDs of the three test members into Section 1.

SELECT p.user_id, p.email, p.first_name, p.last_name, p.role, p.created_at
  FROM profiles p
 WHERE p.role IN ('member', 'consumer')
    OR p.email ILIKE '%test%'
 ORDER BY p.created_at DESC;


-- ─────────────────────────────────────────────────────────────────────────
-- Section 1 — Wipe test member data (DESTRUCTIVE)
-- ─────────────────────────────────────────────────────────────────────────
-- Fill in the UUIDs from Section 0, then run this block. Leave the array
-- empty to get a safety exception instead of wiping nothing silently.

DO $$
DECLARE
  test_user_ids uuid[] := ARRAY[
    -- '00000000-0000-0000-0000-000000000000'::uuid,  -- testmember1
    -- '00000000-0000-0000-0000-000000000000'::uuid,  -- testmember2
    -- '00000000-0000-0000-0000-000000000000'::uuid   -- testmember3
  ]::uuid[];
  deleted_count integer;
BEGIN
  IF test_user_ids IS NULL OR array_length(test_user_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'test_user_ids is empty — paste the UUIDs from Section 0 before running.';
  END IF;

  DELETE FROM notifications    WHERE user_id     = ANY(test_user_ids);
  GET DIAGNOSTICS deleted_count = ROW_COUNT;
  RAISE NOTICE 'notifications: deleted %', deleted_count;

  DELETE FROM messages         WHERE thread_id   = ANY(test_user_ids)
                                  OR sender_id   = ANY(test_user_ids);
  GET DIAGNOSTICS deleted_count = ROW_COUNT;
  RAISE NOTICE 'messages: deleted %', deleted_count;

  DELETE FROM dose_logs        WHERE user_id     = ANY(test_user_ids);
  GET DIAGNOSTICS deleted_count = ROW_COUNT;
  RAISE NOTICE 'dose_logs: deleted %', deleted_count;

  DELETE FROM appointments     WHERE consumer_id = ANY(test_user_ids);
  GET DIAGNOSTICS deleted_count = ROW_COUNT;
  RAISE NOTICE 'appointments: deleted %', deleted_count;

  DELETE FROM support_requests WHERE user_id     = ANY(test_user_ids);
  GET DIAGNOSTICS deleted_count = ROW_COUNT;
  RAISE NOTICE 'support_requests: deleted %', deleted_count;

  DELETE FROM consultations    WHERE user_id     = ANY(test_user_ids);
  GET DIAGNOSTICS deleted_count = ROW_COUNT;
  RAISE NOTICE 'consultations: deleted %', deleted_count;

  DELETE FROM profiles         WHERE user_id     = ANY(test_user_ids);
  GET DIAGNOSTICS deleted_count = ROW_COUNT;
  RAISE NOTICE 'profiles: deleted %', deleted_count;

  RAISE NOTICE 'Wiped data for % test users. Now delete the auth.users rows via the Supabase dashboard.', array_length(test_user_ids, 1);
END $$;


-- ─────────────────────────────────────────────────────────────────────────
-- Section 2 — Drop legacy prescription columns
-- ─────────────────────────────────────────────────────────────────────────
-- These are now owned by `prescriptions` and `prescription_versions`.
-- Safe to run after Section 1 since test data has been wiped.

ALTER TABLE consultations
  DROP COLUMN IF EXISTS protocol_assigned,
  DROP COLUMN IF EXISTS dose_amount,
  DROP COLUMN IF EXISTS dose_unit,
  DROP COLUMN IF EXISTS frequency,
  DROP COLUMN IF EXISTS frequency_amount,
  DROP COLUMN IF EXISTS frequency_cadence,
  DROP COLUMN IF EXISTS timing,
  DROP COLUMN IF EXISTS timing_instructions,
  DROP COLUMN IF EXISTS duration,
  DROP COLUMN IF EXISTS duration_value,
  DROP COLUMN IF EXISTS duration_unit,
  DROP COLUMN IF EXISTS other_notes,
  DROP COLUMN IF EXISTS prescription_history,
  DROP COLUMN IF EXISTS prescribed_protocols,
  DROP COLUMN IF EXISTS prescription_given,
  DROP COLUMN IF EXISTS protocol_version;

ALTER TABLE profiles
  DROP COLUMN IF EXISTS protocol_assigned,
  DROP COLUMN IF EXISTS dose_amount,
  DROP COLUMN IF EXISTS dose_unit,
  DROP COLUMN IF EXISTS frequency,
  DROP COLUMN IF EXISTS frequency_amount,
  DROP COLUMN IF EXISTS frequency_cadence,
  DROP COLUMN IF EXISTS timing,
  DROP COLUMN IF EXISTS duration,
  DROP COLUMN IF EXISTS duration_value,
  DROP COLUMN IF EXISTS duration_unit,
  DROP COLUMN IF EXISTS protocol_started_at;


-- ─────────────────────────────────────────────────────────────────────────
-- Section 3 — Create `prescriptions` table
-- ─────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS prescriptions (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  consultation_id     uuid NOT NULL REFERENCES consultations(id) ON DELETE CASCADE,
  user_id             uuid NOT NULL REFERENCES auth.users(id)    ON DELETE CASCADE,
  clinician_id        uuid REFERENCES auth.users(id) ON DELETE SET NULL,

  protocol_key        text NOT NULL,
  status              text NOT NULL DEFAULT 'active'
                      CHECK (status IN ('active', 'discontinued')),

  started_at          timestamptz NOT NULL DEFAULT now(),
  discontinued_at     timestamptz,
  discontinued_reason text,
  discontinued_by     uuid REFERENCES auth.users(id) ON DELETE SET NULL,

  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);

-- A consultation can only have ONE active prescription for a given protocol
-- at a time. Discontinued ones don't count, so re-prescribing is allowed.
CREATE UNIQUE INDEX IF NOT EXISTS prescriptions_active_unique
  ON prescriptions (consultation_id, protocol_key)
  WHERE status = 'active';

CREATE INDEX IF NOT EXISTS prescriptions_user_status
  ON prescriptions (user_id, status);

CREATE INDEX IF NOT EXISTS prescriptions_consultation
  ON prescriptions (consultation_id);

CREATE INDEX IF NOT EXISTS prescriptions_clinician
  ON prescriptions (clinician_id);


-- ─────────────────────────────────────────────────────────────────────────
-- Section 4 — Create `prescription_versions` table (audit trail)
-- ─────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS prescription_versions (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  prescription_id    uuid NOT NULL REFERENCES prescriptions(id) ON DELETE CASCADE,

  version            integer NOT NULL,
  effective_from     timestamptz NOT NULL,
  effective_to       timestamptz,  -- NULL = this is the current active version

  -- Snapshot of the Rx values as of this version
  dose_amount        numeric,
  dose_unit          text,
  frequency_amount   integer,
  frequency_cadence  text,
  timing             text,
  duration_value     integer,
  duration_unit      text,
  other_notes        text,

  -- What kind of change this was
  adjustment_types   text[] NOT NULL DEFAULT '{}',
  adjustment_reason  text,

  -- Who made the change (denormalized name so renames don't rewrite history)
  prescribed_by      uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  prescribed_by_name text,

  created_at         timestamptz NOT NULL DEFAULT now(),

  UNIQUE (prescription_id, version)
);

-- Fast "give me the current version of this Rx"
CREATE INDEX IF NOT EXISTS prescription_versions_current
  ON prescription_versions (prescription_id)
  WHERE effective_to IS NULL;

-- Timeline view of a single Rx, newest first
CREATE INDEX IF NOT EXISTS prescription_versions_timeline
  ON prescription_versions (prescription_id, effective_from DESC);


-- ─────────────────────────────────────────────────────────────────────────
-- Section 5 — Update `dose_logs` to reference prescriptions
-- ─────────────────────────────────────────────────────────────────────────

-- Add the FK column
ALTER TABLE dose_logs
  ADD COLUMN IF NOT EXISTS prescription_id uuid
    REFERENCES prescriptions(id) ON DELETE CASCADE;

-- Drop the legacy denormalized protocol label
ALTER TABLE dose_logs
  DROP COLUMN IF EXISTS protocol;

-- Drop the old (user_id, dose_date) unique constraint — members with
-- multiple protocols need to log a dose per prescription per day.
ALTER TABLE dose_logs
  DROP CONSTRAINT IF EXISTS dose_logs_user_id_dose_date_key;

-- New uniqueness: one log per (prescription, dose_date)
ALTER TABLE dose_logs
  DROP CONSTRAINT IF EXISTS dose_logs_prescription_date_key;

ALTER TABLE dose_logs
  ADD  CONSTRAINT       dose_logs_prescription_date_key
  UNIQUE (prescription_id, dose_date);

-- Tighten NOT NULL on prescription_id. Safe only when the table is empty
-- (test data was wiped in Section 1). If you have production dose logs, this
-- DO block leaves the column nullable so nothing breaks.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM dose_logs) THEN
    ALTER TABLE dose_logs ALTER COLUMN prescription_id SET NOT NULL;
    RAISE NOTICE 'dose_logs.prescription_id set to NOT NULL (table was empty)';
  ELSE
    RAISE NOTICE 'dose_logs is not empty — prescription_id left nullable for now';
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS dose_logs_prescription_date
  ON dose_logs (prescription_id, dose_date DESC);


-- ─────────────────────────────────────────────────────────────────────────
-- Section 6 — Row Level Security
-- ─────────────────────────────────────────────────────────────────────────
-- Matches the convention already used by dose_logs / availability:
-- role check via auth.jwt() → user_metadata → role.

-- prescriptions -----------------------------------------------------------
ALTER TABLE prescriptions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "members read own prescriptions" ON prescriptions;
CREATE POLICY "members read own prescriptions"
  ON prescriptions FOR SELECT
  USING (user_id = auth.uid());

DROP POLICY IF EXISTS "clinicians read all prescriptions" ON prescriptions;
CREATE POLICY "clinicians read all prescriptions"
  ON prescriptions FOR SELECT
  USING ((auth.jwt() -> 'user_metadata' ->> 'role') IN ('clinician','admin','super_admin'));

DROP POLICY IF EXISTS "clinicians write prescriptions" ON prescriptions;
CREATE POLICY "clinicians write prescriptions"
  ON prescriptions FOR ALL
  USING      ((auth.jwt() -> 'user_metadata' ->> 'role') IN ('clinician','admin','super_admin'))
  WITH CHECK ((auth.jwt() -> 'user_metadata' ->> 'role') IN ('clinician','admin','super_admin'));

-- prescription_versions ---------------------------------------------------
ALTER TABLE prescription_versions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "members read own prescription versions" ON prescription_versions;
CREATE POLICY "members read own prescription versions"
  ON prescription_versions FOR SELECT
  USING (
    prescription_id IN (SELECT id FROM prescriptions WHERE user_id = auth.uid())
  );

DROP POLICY IF EXISTS "clinicians read all prescription versions" ON prescription_versions;
CREATE POLICY "clinicians read all prescription versions"
  ON prescription_versions FOR SELECT
  USING ((auth.jwt() -> 'user_metadata' ->> 'role') IN ('clinician','admin','super_admin'));

DROP POLICY IF EXISTS "clinicians write prescription versions" ON prescription_versions;
CREATE POLICY "clinicians write prescription versions"
  ON prescription_versions FOR ALL
  USING      ((auth.jwt() -> 'user_metadata' ->> 'role') IN ('clinician','admin','super_admin'))
  WITH CHECK ((auth.jwt() -> 'user_metadata' ->> 'role') IN ('clinician','admin','super_admin'));


-- ─────────────────────────────────────────────────────────────────────────
-- Section 7 — Sanity checks (run at the end to verify)
-- ─────────────────────────────────────────────────────────────────────────

-- Row counts. After a clean wipe + migration: prescriptions/versions = 0,
-- consultations/profiles = however many clinician/admin rows survived.
SELECT 'prescriptions'         AS table_name, COUNT(*) FROM prescriptions
UNION ALL
SELECT 'prescription_versions',                COUNT(*) FROM prescription_versions
UNION ALL
SELECT 'consultations',                        COUNT(*) FROM consultations
UNION ALL
SELECT 'profiles',                             COUNT(*) FROM profiles
UNION ALL
SELECT 'dose_logs',                            COUNT(*) FROM dose_logs;

-- Verify legacy columns were dropped (should return 0 rows).
SELECT table_name, column_name
  FROM information_schema.columns
 WHERE table_name IN ('consultations','profiles')
   AND column_name IN (
     'protocol_assigned','dose_amount','dose_unit','frequency',
     'frequency_amount','frequency_cadence','timing','duration',
     'duration_value','duration_unit','other_notes','prescription_history',
     'prescribed_protocols','protocol_started_at','prescription_given'
   );

-- Verify new tables exist with the right shape (should return 2 rows).
SELECT table_name
  FROM information_schema.tables
 WHERE table_schema = 'public'
   AND table_name IN ('prescriptions','prescription_versions');

-- Verify the unique constraint on active prescriptions exists.
SELECT indexname FROM pg_indexes
 WHERE tablename = 'prescriptions'
   AND indexname = 'prescriptions_active_unique';
