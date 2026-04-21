-- ═══════════════════════════════════════════════════════════════════════════
-- CommandOS — R10 migration: tenant-admin write access to integrations config
-- ═══════════════════════════════════════════════════════════════════════════
--
-- WHAT THIS DOES
--   Lets tenant_owner + tenant_admin update the NON-SECRET config
--   column on their own tenant's tenant_integrations rows. Preserves
--   the Phase 7 security posture: credentials remain platform-only,
--   tenant admins can only change config / status (in limited ways).
--
--   Protected columns (non-platform users cannot change):
--     credentials, tenant_id, provider, id, created_at,
--     last_connected_at, last_error, last_error_at
--
--   Permitted for tenant admins:
--     config (JSONB — mode, webhook paths, feature toggles)
--     status (limited to 'connected' / 'disconnected' — cannot
--             set to 'error' since that's a system-reported state)
--
-- USAGE
--   Paste into Supabase SQL editor and run. Idempotent.
--
-- ═══════════════════════════════════════════════════════════════════════════

DROP POLICY IF EXISTS "integrations_tenant_config_update" ON tenant_integrations;
CREATE POLICY "integrations_tenant_config_update" ON tenant_integrations
  FOR UPDATE TO authenticated
  USING (
    tenant_id IN (
      SELECT tenant_id FROM tenant_memberships
      WHERE user_id = auth.uid()
        AND role IN ('tenant_owner', 'tenant_admin')
    )
  )
  WITH CHECK (
    tenant_id IN (
      SELECT tenant_id FROM tenant_memberships
      WHERE user_id = auth.uid()
        AND role IN ('tenant_owner', 'tenant_admin')
    )
  );

CREATE OR REPLACE FUNCTION public.guard_integrations_protected_columns()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  -- Platform users can change anything (they provision credentials).
  IF public.is_platform_user() THEN
    RETURN NEW;
  END IF;

  IF NEW.credentials       IS DISTINCT FROM OLD.credentials       THEN RAISE EXCEPTION 'credentials are platform-owned'; END IF;
  IF NEW.tenant_id         IS DISTINCT FROM OLD.tenant_id         THEN RAISE EXCEPTION 'tenant_id is immutable'; END IF;
  IF NEW.provider          IS DISTINCT FROM OLD.provider          THEN RAISE EXCEPTION 'provider is immutable'; END IF;
  IF NEW.id                IS DISTINCT FROM OLD.id                THEN RAISE EXCEPTION 'id is immutable'; END IF;
  IF NEW.created_at        IS DISTINCT FROM OLD.created_at        THEN RAISE EXCEPTION 'created_at is immutable'; END IF;
  IF NEW.last_connected_at IS DISTINCT FROM OLD.last_connected_at THEN RAISE EXCEPTION 'last_connected_at is system-managed'; END IF;
  IF NEW.last_error        IS DISTINCT FROM OLD.last_error        THEN RAISE EXCEPTION 'last_error is system-managed'; END IF;
  IF NEW.last_error_at     IS DISTINCT FROM OLD.last_error_at     THEN RAISE EXCEPTION 'last_error_at is system-managed'; END IF;

  -- Status: tenant admins can toggle between 'connected' and
  -- 'disconnected' only. 'error' is system-reported.
  IF NEW.status IS DISTINCT FROM OLD.status THEN
    IF NEW.status NOT IN ('connected', 'disconnected') THEN
      RAISE EXCEPTION 'status can only be set to connected or disconnected by tenant admins';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS integrations_guard_protected ON tenant_integrations;
CREATE TRIGGER integrations_guard_protected
  BEFORE UPDATE ON tenant_integrations
  FOR EACH ROW EXECUTE FUNCTION public.guard_integrations_protected_columns();

SELECT
  (SELECT count(*) FROM pg_policies WHERE schemaname='public' AND tablename='tenant_integrations' AND policyname='integrations_tenant_config_update') AS config_policy,
  (SELECT count(*) FROM pg_trigger  WHERE tgrelid='public.tenant_integrations'::regclass AND tgname='integrations_guard_protected') AS guard_trigger;

-- ROLLBACK
-- DROP TRIGGER  IF EXISTS integrations_guard_protected ON tenant_integrations;
-- DROP FUNCTION IF EXISTS public.guard_integrations_protected_columns();
-- DROP POLICY   IF EXISTS "integrations_tenant_config_update" ON tenant_integrations;
