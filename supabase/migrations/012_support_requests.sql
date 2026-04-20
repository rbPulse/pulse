-- ═══════════════════════════════════════════════════════════════════════════
-- Pulse — Phase 0 migration: support_requests table
-- ═══════════════════════════════════════════════════════════════════════════
--
-- WHAT THIS DOES
--   Creates the support_requests table that portal.html has been
--   inserting into since before our audit. The table never existed,
--   so every submit has been silently failing (the caller's
--   .catch() swallows the error). Standing it up tenant-scoped from
--   day one so we don't have to come back.
--
--   Columns loosely modelled on the existing insert payload plus the
--   usual timestamps + status tracking so clinicians can triage.
--
-- USAGE
--   Paste into Supabase SQL editor and run. Idempotent.
--
-- ROLLBACK
--   DROP TABLE IF EXISTS support_requests;
--
-- ═══════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS support_requests (
  id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id    uuid        NOT NULL DEFAULT '00000000-0000-0000-0000-000000000001'
                           REFERENCES tenants(id),
  user_id      uuid        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  type         text        NOT NULL,
  message      text        NOT NULL,
  status       text        NOT NULL DEFAULT 'open'
                           CHECK (status IN ('open', 'in_review', 'resolved', 'closed')),
  resolved_at  timestamptz,
  resolved_by  uuid        REFERENCES auth.users(id),
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS support_requests_tenant_idx  ON support_requests(tenant_id);
CREATE INDEX IF NOT EXISTS support_requests_user_idx    ON support_requests(user_id);
CREATE INDEX IF NOT EXISTS support_requests_status_idx  ON support_requests(tenant_id, status);
CREATE INDEX IF NOT EXISTS support_requests_created_idx ON support_requests(tenant_id, created_at DESC);

DROP TRIGGER IF EXISTS support_requests_set_updated_at ON support_requests;
CREATE TRIGGER support_requests_set_updated_at
  BEFORE UPDATE ON support_requests
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ── RLS ────────────────────────────────────────────────────────────────────
-- Patients: insert + read their own rows in their tenant.
-- Staff: read + update all rows in their tenant.
-- Platform users: read all (write limited to specific ops later).

ALTER TABLE support_requests ENABLE ROW LEVEL SECURITY;

-- Patient can read their own requests at tenants they're enrolled in.
DROP POLICY IF EXISTS "support_patient_read_own" ON support_requests;
CREATE POLICY "support_patient_read_own" ON support_requests
  FOR SELECT TO authenticated
  USING (
    user_id = auth.uid()
    AND tenant_id IN (SELECT public.current_tenant_ids())
  );

-- Patient can insert their own requests at tenants they're enrolled in.
DROP POLICY IF EXISTS "support_patient_insert_own" ON support_requests;
CREATE POLICY "support_patient_insert_own" ON support_requests
  FOR INSERT TO authenticated
  WITH CHECK (
    user_id = auth.uid()
    AND tenant_id IN (SELECT public.current_tenant_ids())
  );

-- Staff (any tenant_memberships role at this tenant) can read all.
DROP POLICY IF EXISTS "support_staff_read" ON support_requests;
CREATE POLICY "support_staff_read" ON support_requests
  FOR SELECT TO authenticated
  USING (
    tenant_id IN (
      SELECT tenant_id FROM tenant_memberships WHERE user_id = auth.uid()
    )
  );

-- Staff can triage: update status, assign resolver, add internal notes.
-- (Tightening which roles can do what happens in the Phase 6 permissions
-- pass; for now any staff member of the tenant can update.)
DROP POLICY IF EXISTS "support_staff_update" ON support_requests;
CREATE POLICY "support_staff_update" ON support_requests
  FOR UPDATE TO authenticated
  USING (
    tenant_id IN (
      SELECT tenant_id FROM tenant_memberships WHERE user_id = auth.uid()
    )
  );

-- Platform users can read across tenants.
DROP POLICY IF EXISTS "support_platform_read" ON support_requests;
CREATE POLICY "support_platform_read" ON support_requests
  FOR SELECT TO authenticated
  USING (public.is_platform_user());

-- ── Verify ─────────────────────────────────────────────────────────────────

SELECT
  (SELECT count(*) FROM information_schema.tables
     WHERE table_schema = 'public' AND table_name = 'support_requests') AS table_exists,
  (SELECT count(*) FROM information_schema.columns
     WHERE table_schema = 'public' AND table_name = 'support_requests'
       AND column_name = 'tenant_id')                                    AS tenant_id_col,
  (SELECT count(*) FROM pg_policies
     WHERE schemaname = 'public' AND tablename = 'support_requests')     AS policy_count;
