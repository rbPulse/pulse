-- ═══════════════════════════════════════════════════════════════════════════
-- Pulse — Phase 6 migration: communication_templates
-- ═══════════════════════════════════════════════════════════════════════════
--
-- WHAT THIS DOES
--   Creates the per-tenant messaging template table. Each row is one
--   configurable message: "member welcome email", "refill approved
--   email", "consult reminder SMS", etc. Tenants override subject
--   and body per template; unset templates fall through to the
--   bundled defaults defined in messaging.js at runtime.
--
--   Key shape: the (tenant_id, key, channel) triple is unique. A
--   single logical message can have one row per channel — a tenant
--   sending the refill-approved notification both as email AND SMS
--   gets two rows with the same `key` and different `channel`s.
--
-- WHY JSONB `variables` ISN'T AN ARRAY COLUMN
--   PostgREST can filter and select JSONB arrays cleanly, and future
--   phases will want to attach per-variable metadata (e.g. "this
--   variable is required; template fails validation if missing").
--   Array column can't carry that; JSONB of { name, required, type }
--   objects can.
--
-- USAGE
--   Paste into Supabase SQL editor and run. Idempotent.
--
-- ROLLBACK
--   See block at the bottom.
--
-- ═══════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS communication_templates (
  id           uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id    uuid         NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  key          text         NOT NULL,
  channel      text         NOT NULL,
  subject      text,
  body         text         NOT NULL,
  variables    jsonb        NOT NULL DEFAULT '[]'::jsonb,
  cadence      jsonb,
  is_enabled   boolean      NOT NULL DEFAULT true,
  created_by   uuid         REFERENCES auth.users(id),
  created_at   timestamptz  NOT NULL DEFAULT now(),
  updated_at   timestamptz  NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, key, channel),
  CONSTRAINT communication_templates_channel_check
    CHECK (channel IN ('email','sms','push'))
);

CREATE INDEX IF NOT EXISTS communication_templates_tenant_idx
  ON communication_templates(tenant_id);
CREATE INDEX IF NOT EXISTS communication_templates_lookup_idx
  ON communication_templates(tenant_id, key, channel)
  WHERE is_enabled;

-- Reuse set_updated_at() from migration 010.
DROP TRIGGER IF EXISTS communication_templates_set_updated_at ON communication_templates;
CREATE TRIGGER communication_templates_set_updated_at
  BEFORE UPDATE ON communication_templates
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ── RLS ─────────────────────────────────────────────────────────────────
-- Staff at the tenant can read. Tenant owners/admins can write. Platform
-- users can read + write across all tenants — same template as
-- protocol_packages (migration 014).

ALTER TABLE communication_templates ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "comm_tmpl_staff_read" ON communication_templates;
CREATE POLICY "comm_tmpl_staff_read" ON communication_templates
  FOR SELECT TO authenticated
  USING (
    tenant_id IN (SELECT public.current_tenant_ids())
    OR public.is_platform_user()
  );

DROP POLICY IF EXISTS "comm_tmpl_staff_write" ON communication_templates;
CREATE POLICY "comm_tmpl_staff_write" ON communication_templates
  FOR ALL TO authenticated
  USING (
    public.is_platform_user()
    OR tenant_id IN (
      SELECT tenant_id FROM tenant_memberships
      WHERE user_id = auth.uid()
        AND role IN ('tenant_owner','tenant_admin')
    )
  )
  WITH CHECK (
    public.is_platform_user()
    OR tenant_id IN (
      SELECT tenant_id FROM tenant_memberships
      WHERE user_id = auth.uid()
        AND role IN ('tenant_owner','tenant_admin')
    )
  );

-- ── Verify ─────────────────────────────────────────────────────────────
SELECT
  (SELECT count(*) FROM pg_tables
     WHERE schemaname = 'public' AND tablename = 'communication_templates')       AS table_exists,
  (SELECT count(*) FROM pg_policies
     WHERE schemaname = 'public' AND tablename = 'communication_templates')       AS policy_count,
  (SELECT count(*) FROM pg_indexes
     WHERE schemaname = 'public' AND tablename = 'communication_templates')       AS index_count;

-- ═══════════════════════════════════════════════════════════════════════════
-- ROLLBACK  (run only if you need to fully undo this migration)
-- ═══════════════════════════════════════════════════════════════════════════
--
-- DROP POLICY IF EXISTS "comm_tmpl_staff_write" ON communication_templates;
-- DROP POLICY IF EXISTS "comm_tmpl_staff_read"  ON communication_templates;
-- DROP TABLE IF EXISTS communication_templates;
