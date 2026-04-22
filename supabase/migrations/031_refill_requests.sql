-- ═══════════════════════════════════════════════════════════════════════════
-- Unite — Phase 9 migration: refill_requests
-- ═══════════════════════════════════════════════════════════════════════════
--
-- WHAT THIS DOES
--   Creates the table backing the refill workflow:
--
--     patient initiates ──▶ status='requested'
--                                │
--                        clinician reviews
--                         │           │
--                    'approved'   'denied'
--                         │
--                    patient pays ──▶ 'paid'
--                         │
--                    new prescription + shipment ──▶ 'fulfilled'
--
--   Every refill gets a clinician review — no auto-approval path.
--   'Trusted patient' auto-approve after N successful refills is a
--   future feature; for now every refill flows through the queue.
--
-- PRICING
--   Refill price comes from protocol_templates.refill_price (falls
--   back to .price when null). That column already exists from
--   migration 014.
--
-- RLS
--   - Patients can INSERT + SELECT their own refills.
--   - Clinicians + tenant admins on the same tenant can SELECT all
--     refills for that tenant, and UPDATE to approve/deny/etc.
--   - Platform users see everything.
--
-- USAGE
--   Paste into Supabase SQL editor and run. Idempotent.
--
-- ═══════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS refill_requests (
  id                       uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id                uuid         NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  patient_user_id          uuid         NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  consultation_id          uuid         NOT NULL REFERENCES consultations(id) ON DELETE CASCADE,
  prescription_id          uuid         REFERENCES prescriptions(id) ON DELETE SET NULL,
  protocol_key             text         NOT NULL,

  status                   text         NOT NULL DEFAULT 'requested'
                           CHECK (status IN ('requested','approved','denied','paid','fulfilled','canceled')),

  requested_at             timestamptz  NOT NULL DEFAULT now(),
  patient_note             text,

  clinician_id             uuid         REFERENCES auth.users(id) ON DELETE SET NULL,
  reviewed_at              timestamptz,
  clinician_note           text,
  denial_reason            text,

  stripe_payment_intent_id text,
  paid_at                  timestamptz,
  amount_cents             integer,

  new_prescription_id      uuid         REFERENCES prescriptions(id) ON DELETE SET NULL,
  fulfilled_at             timestamptz,

  created_at               timestamptz  NOT NULL DEFAULT now(),
  updated_at               timestamptz  NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS refill_requests_tenant_status_idx ON refill_requests(tenant_id, status, requested_at DESC);
CREATE INDEX IF NOT EXISTS refill_requests_patient_idx       ON refill_requests(patient_user_id, requested_at DESC);
CREATE INDEX IF NOT EXISTS refill_requests_consultation_idx  ON refill_requests(consultation_id);

-- Reuse set_updated_at from migration 010.
DROP TRIGGER IF EXISTS refill_requests_set_updated_at ON refill_requests;
CREATE TRIGGER refill_requests_set_updated_at
  BEFORE UPDATE ON refill_requests
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ── RLS ────────────────────────────────────────────────────────────────

ALTER TABLE refill_requests ENABLE ROW LEVEL SECURITY;

-- Patients: INSERT + SELECT their own refills.
DROP POLICY IF EXISTS "refill_requests_patient_insert" ON refill_requests;
CREATE POLICY "refill_requests_patient_insert" ON refill_requests
  FOR INSERT TO authenticated
  WITH CHECK (patient_user_id = auth.uid());

DROP POLICY IF EXISTS "refill_requests_patient_read" ON refill_requests;
CREATE POLICY "refill_requests_patient_read" ON refill_requests
  FOR SELECT TO authenticated
  USING (patient_user_id = auth.uid());

-- Clinicians + tenant admins: SELECT + UPDATE all refills on their tenant.
DROP POLICY IF EXISTS "refill_requests_staff_read" ON refill_requests;
CREATE POLICY "refill_requests_staff_read" ON refill_requests
  FOR SELECT TO authenticated
  USING (
    tenant_id IN (
      SELECT tenant_id FROM tenant_memberships
      WHERE user_id = auth.uid()
        AND role IN ('tenant_clinician', 'tenant_nurse', 'tenant_admin', 'tenant_owner')
    )
  );

DROP POLICY IF EXISTS "refill_requests_staff_update" ON refill_requests;
CREATE POLICY "refill_requests_staff_update" ON refill_requests
  FOR UPDATE TO authenticated
  USING (
    tenant_id IN (
      SELECT tenant_id FROM tenant_memberships
      WHERE user_id = auth.uid()
        AND role IN ('tenant_clinician', 'tenant_nurse', 'tenant_admin', 'tenant_owner')
    )
  )
  WITH CHECK (
    tenant_id IN (
      SELECT tenant_id FROM tenant_memberships
      WHERE user_id = auth.uid()
        AND role IN ('tenant_clinician', 'tenant_nurse', 'tenant_admin', 'tenant_owner')
    )
  );

-- Platform users see everything (consistent with the rest of the schema).
DROP POLICY IF EXISTS "refill_requests_platform_all" ON refill_requests;
CREATE POLICY "refill_requests_platform_all" ON refill_requests
  FOR ALL TO authenticated
  USING (public.is_platform_user())
  WITH CHECK (public.is_platform_user());

-- ── Verify ─────────────────────────────────────────────────────────────

SELECT
  (SELECT count(*) FROM pg_tables WHERE schemaname='public' AND tablename='refill_requests')      AS table_exists,
  (SELECT count(*) FROM pg_indexes WHERE schemaname='public' AND tablename='refill_requests')     AS index_count,
  (SELECT count(*) FROM pg_policies WHERE schemaname='public' AND tablename='refill_requests')    AS policy_count;
