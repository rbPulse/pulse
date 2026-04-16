-- ═══════════════════════════════════════════════════════════════════════════
-- Pulse — Phase 4 migration: consultation_type column
-- ═══════════════════════════════════════════════════════════════════════════
--
-- WHAT THIS DOES
--   Adds a `consultation_type` text column to the `consultations` table
--   to distinguish regular intakes from protocol-request consultations.
--   Existing rows get NULL (treated as 'intake' by the application).
--   New protocol requests set this to 'protocol_request'.
--
-- USAGE
--   Paste into Supabase SQL editor and run. Idempotent.
--
-- ROLLBACK
--   ALTER TABLE consultations DROP COLUMN IF EXISTS consultation_type;
--
-- ═══════════════════════════════════════════════════════════════════════════

ALTER TABLE consultations
  ADD COLUMN IF NOT EXISTS consultation_type text;

-- Index for filtering by type in attention-queue queries
CREATE INDEX IF NOT EXISTS consultations_type
  ON consultations (consultation_type)
  WHERE consultation_type IS NOT NULL;

-- Verify
SELECT column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_name = 'consultations' AND column_name = 'consultation_type';
