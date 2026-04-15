-- ═══════════════════════════════════════════════════════════════════════════
-- Pulse — Phase 2 migration: patient_notes audit table
-- ═══════════════════════════════════════════════════════════════════════════
--
-- WHAT THIS DOES
--   Creates a new `patient_notes` table that stores every version of a
--   patient's clinician-authored notes as an append-only audit log.
--   Each row is a single saved note with the clinician who wrote it and
--   the time it was saved. The "current" note is simply the most recent
--   row for a given user_id.
--
--   Replaces the legacy single-string `consultations.session_notes`
--   field as the canonical source of patient notes. The old column is
--   LEFT IN PLACE for backwards compatibility with existing reads; the
--   portal JS continues to mirror the latest note into that column on
--   save so nothing downstream breaks.
--
-- USAGE
--   Paste this whole file into the Supabase SQL editor and run it.
--   Idempotent — safe to re-run.
--
-- ROLLBACK
--   DROP TABLE patient_notes;
--   (The consultations.session_notes column is untouched so legacy
--   reads keep working.)
--
-- ═══════════════════════════════════════════════════════════════════════════


-- ─────────────────────────────────────────────────────────────────────────
-- Section 1 — Create the table
-- ─────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS patient_notes (
  id               uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id          uuid         NOT NULL,
  consultation_id  uuid,
  clinician_id     uuid,
  clinician_name   text,
  note_text        text         NOT NULL,
  created_at       timestamptz  NOT NULL DEFAULT now()
);

-- Primary lookup pattern: "give me the most recent notes for this
-- patient". Index covers both the equality on user_id and the DESC
-- order-by on created_at.
CREATE INDEX IF NOT EXISTS patient_notes_user_id_created_at
  ON patient_notes (user_id, created_at DESC);

-- Secondary index for consultation-scoped queries (e.g. showing all
-- notes attached to a specific intake / follow-up consultation).
CREATE INDEX IF NOT EXISTS patient_notes_consultation_id
  ON patient_notes (consultation_id)
  WHERE consultation_id IS NOT NULL;


-- ─────────────────────────────────────────────────────────────────────────
-- Section 2 — Row-level security
-- ─────────────────────────────────────────────────────────────────────────
-- Clinicians can read/write any patient_notes row while authenticated.
-- Members are never granted access (the portal's clinician-mode UI is
-- the only surface that touches this table). Tighten later if you add
-- per-clinician patient assignment enforcement.

ALTER TABLE patient_notes ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "clinicians manage patient notes" ON patient_notes;
CREATE POLICY "clinicians manage patient notes"
  ON patient_notes FOR ALL
  TO authenticated
  USING       (auth.uid() IS NOT NULL)
  WITH CHECK  (auth.uid() IS NOT NULL);


-- ─────────────────────────────────────────────────────────────────────────
-- Section 3 — Verify
-- ─────────────────────────────────────────────────────────────────────────
-- Run these after the creation statements above to confirm.

SELECT 'patient_notes rows', COUNT(*) FROM patient_notes;

SELECT
  column_name,
  data_type,
  is_nullable
FROM information_schema.columns
WHERE table_name = 'patient_notes'
ORDER BY ordinal_position;
