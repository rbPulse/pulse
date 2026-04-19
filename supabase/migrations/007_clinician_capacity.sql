-- ═══════════════════════════════════════════════════════════════════════════
-- Pulse — Phase 7 migration: clinician capacity columns on profiles
-- ═══════════════════════════════════════════════════════════════════════════
--
-- WHAT THIS DOES
--   Adds max_concurrent_patients (integer) and working_hours (text)
--   columns to the profiles table so the admin portal's Clinician
--   Capacity tab can display and edit per-clinician settings.
--
-- USAGE
--   Paste into Supabase SQL editor and run. Idempotent.
--
-- ROLLBACK
--   ALTER TABLE profiles DROP COLUMN IF EXISTS max_concurrent_patients;
--   ALTER TABLE profiles DROP COLUMN IF EXISTS working_hours;
--
-- ═══════════════════════════════════════════════════════════════════════════

ALTER TABLE profiles
  ADD COLUMN IF NOT EXISTS max_concurrent_patients int;

ALTER TABLE profiles
  ADD COLUMN IF NOT EXISTS working_hours text;

-- Verify
SELECT column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_name = 'profiles'
  AND column_name IN ('max_concurrent_patients', 'working_hours')
ORDER BY column_name;
