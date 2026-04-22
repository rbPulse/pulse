-- ═══════════════════════════════════════════════════════════════════════════
-- Unite — Phase 9 follow-up: custom_rx_overrides on refill_requests
-- ═══════════════════════════════════════════════════════════════════════════
--
-- WHAT THIS DOES
--   Adds a single jsonb column to refill_requests so a clinician can
--   stamp edited prescription details onto the refill at approval time.
--
--   When the patient pays, stripe-webhook.handleRefillPaid reads this
--   column and uses the overrides when it creates the new prescription
--   row (via prescription_versions v=1). If the column is null, the
--   new prescription inherits the previous Rx's latest version values
--   unchanged — same as today.
--
-- SHAPE
--   custom_rx_overrides jsonb =
--     {
--       "dose_amount":        <numeric>,
--       "dose_unit":          <text>,
--       "frequency_amount":   <integer>,
--       "frequency_cadence":  <text>,
--       "timing":             <text>,
--       "duration_value":     <integer>,
--       "duration_unit":      <text>,
--       "other_notes":        <text>
--     }
--   Any subset of keys is valid — missing keys inherit from the prior Rx.
--
-- USAGE
--   Paste into Supabase SQL editor and run. Idempotent.
--
-- ═══════════════════════════════════════════════════════════════════════════

ALTER TABLE refill_requests
  ADD COLUMN IF NOT EXISTS custom_rx_overrides jsonb;

-- ── Verify ─────────────────────────────────────────────────────────────

SELECT
  (SELECT count(*) FROM information_schema.columns
    WHERE table_schema='public' AND table_name='refill_requests' AND column_name='custom_rx_overrides') AS column_exists;
