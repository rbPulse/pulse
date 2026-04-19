-- ═══════════════════════════════════════════════════════════════════════════
-- Pulse — Phase 9 migration: HIPAA audit log hardening
-- ═══════════════════════════════════════════════════════════════════════════
--
-- WHAT THIS DOES
--   Makes the audit_logs table tamper-proof for HIPAA compliance:
--   - Prevents UPDATE and DELETE via a trigger (append-only)
--   - Adds index on target_id for per-patient access lookups
--   - Documents the 6-year retention requirement
--
-- USAGE
--   Paste into Supabase SQL editor and run. Idempotent.
--
-- ═══════════════════════════════════════════════════════════════════════════

-- Ensure the table exists (in case 008 wasn't run first)
CREATE TABLE IF NOT EXISTS audit_logs (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  action      text        NOT NULL,
  actor_id    uuid,
  actor_email text,
  target_id   uuid,
  details     text,
  created_at  timestamptz NOT NULL DEFAULT now()
);

-- Indexes for compliance queries
CREATE INDEX IF NOT EXISTS audit_logs_created ON audit_logs (created_at DESC);
CREATE INDEX IF NOT EXISTS audit_logs_action ON audit_logs (action);
CREATE INDEX IF NOT EXISTS audit_logs_target ON audit_logs (target_id) WHERE target_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS audit_logs_actor ON audit_logs (actor_id) WHERE actor_id IS NOT NULL;

-- RLS: admins can read; any authenticated user can insert (for PHI logging)
ALTER TABLE audit_logs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "admin read audit logs" ON audit_logs;
CREATE POLICY "admin read audit logs" ON audit_logs
  FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM profiles WHERE user_id = auth.uid() AND role = 'admin'));

DROP POLICY IF EXISTS "authenticated write audit logs" ON audit_logs;
CREATE POLICY "authenticated write audit logs" ON audit_logs
  FOR INSERT TO authenticated
  WITH CHECK (true);

-- Tamper protection: prevent any UPDATE or DELETE on audit_logs.
-- This makes the table truly append-only for HIPAA compliance.
CREATE OR REPLACE FUNCTION prevent_audit_log_modification()
RETURNS TRIGGER AS $$
BEGIN
  RAISE EXCEPTION 'Audit logs are append-only and cannot be modified or deleted (HIPAA compliance)';
  RETURN NULL;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS audit_logs_no_update ON audit_logs;
CREATE TRIGGER audit_logs_no_update
  BEFORE UPDATE ON audit_logs
  FOR EACH ROW EXECUTE FUNCTION prevent_audit_log_modification();

DROP TRIGGER IF EXISTS audit_logs_no_delete ON audit_logs;
CREATE TRIGGER audit_logs_no_delete
  BEFORE DELETE ON audit_logs
  FOR EACH ROW EXECUTE FUNCTION prevent_audit_log_modification();

-- NOTE: HIPAA requires 6 years of audit log retention.
-- Do NOT add any automated purge/cleanup to this table.
-- If storage becomes a concern, partition by year instead of deleting.

-- Verify
SELECT 'audit_logs rows', COUNT(*) FROM audit_logs;
SELECT 'triggers', tgname FROM pg_trigger WHERE tgrelid = 'audit_logs'::regclass;
