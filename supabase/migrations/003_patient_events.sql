-- ═══════════════════════════════════════════════════════════════════════════
-- Pulse — Phase 3 migration: patient_events unified timeline
-- ═══════════════════════════════════════════════════════════════════════════
--
-- WHAT THIS DOES
--   Creates a `patient_events` table that stores every significant event
--   in a patient's journey as a typed, timestamped row with a flexible
--   JSONB payload. Event types include check-ins, prescription changes,
--   clinician notes, completed appointments, etc. Both the member and
--   clinician portals query this table to render patient timelines.
--
--   Product-agnostic by design — event_type is a text string and
--   event_data is JSONB, so new event types or product verticals don't
--   require schema changes.
--
-- USAGE
--   Paste into the Supabase SQL editor and run. Idempotent.
--
-- ROLLBACK
--   DROP TABLE patient_events;
--
-- ═══════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS patient_events (
  id               uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id          uuid         NOT NULL,
  event_type       text         NOT NULL,
  event_data       jsonb        DEFAULT '{}',
  created_by       uuid,
  created_by_name  text,
  created_at       timestamptz  NOT NULL DEFAULT now()
);

-- Primary lookup: "give me the full timeline for this patient"
CREATE INDEX IF NOT EXISTS patient_events_user_timeline
  ON patient_events (user_id, created_at DESC);

-- Secondary: filter by event type across all patients (analytics,
-- clinician dashboard queries like "all check-ins this week")
CREATE INDEX IF NOT EXISTS patient_events_type_created
  ON patient_events (event_type, created_at DESC);

-- RLS: authenticated users can read/write. Tighten per-role later.
ALTER TABLE patient_events ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "manage patient events" ON patient_events;
CREATE POLICY "manage patient events"
  ON patient_events FOR ALL
  TO authenticated
  USING      (auth.uid() IS NOT NULL)
  WITH CHECK (auth.uid() IS NOT NULL);

-- Verify
SELECT 'patient_events rows', COUNT(*) FROM patient_events;

SELECT column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_name = 'patient_events'
ORDER BY ordinal_position;
