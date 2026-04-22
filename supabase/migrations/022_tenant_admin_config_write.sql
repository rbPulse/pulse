-- ═══════════════════════════════════════════════════════════════════════════
-- Unite — R4 migration: tenant-admin write access to config columns
-- ═══════════════════════════════════════════════════════════════════════════
--
-- WHAT THIS DOES
--   Widens tenants-row write access so tenant_owner + tenant_admin can
--   update the CONFIG columns on their own tenant row:
--
--     brand, terminology, workflow, compliance, features, legal_name
--
--   Platform-only columns remain platform-only:
--     slug, name, lifecycle_state, created_by
--
--   This unlocks the R4+ migration sequence: each tenant-owned
--   configuration surface (Brand, Terminology, Catalog, Workflow,
--   Comms, Compliance, etc.) moves from Unite into the tenant
--   admin portal, and the tenant admin needs RLS permission to save.
--
-- HOW THE POLICY WORKS
--   Postgres RLS evaluates policies as OR — if any SELECT/UPDATE
--   policy passes, the row is accessible. So we add a new
--   tenants_admin_config_update policy alongside the existing
--   tenants_platform_write. Tenant admins satisfy the new policy;
--   platform users satisfy the existing one; both paths land the
--   same UPDATE statement at the DB.
--
--   Postgres RLS does NOT natively support column-level WITH CHECK
--   restriction — the whole row is either writeable or not. To
--   enforce "tenant admins can update config columns but NOT slug /
--   name / lifecycle_state / created_by," we use a BEFORE UPDATE
--   trigger that rolls back protected-column changes when the
--   current user isn't a platform user. The trigger + policy split
--   gives us the semantic "RLS gates access, trigger gates scope."
--
-- USAGE
--   Paste into Supabase SQL editor and run. Idempotent.
--
-- ═══════════════════════════════════════════════════════════════════════════

-- ── Policy: tenant admins can update their own tenant row ──────────────

DROP POLICY IF EXISTS "tenants_admin_config_update" ON tenants;
CREATE POLICY "tenants_admin_config_update" ON tenants
  FOR UPDATE TO authenticated
  USING (
    id IN (
      SELECT tenant_id FROM tenant_memberships
      WHERE user_id = auth.uid()
        AND role IN ('tenant_owner', 'tenant_admin')
    )
  )
  WITH CHECK (
    id IN (
      SELECT tenant_id FROM tenant_memberships
      WHERE user_id = auth.uid()
        AND role IN ('tenant_owner', 'tenant_admin')
    )
  );

-- ── Trigger: prevent tenant admins from changing protected columns ────
-- Platform users bypass this guard because they need to provision
-- tenants (which includes setting slug / name / lifecycle_state).
-- Tenant admins only get pass-through for the config columns.

CREATE OR REPLACE FUNCTION public.guard_tenants_protected_columns()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  -- Platform users can change anything.
  IF public.is_platform_user() THEN
    RETURN NEW;
  END IF;

  -- Non-platform users (tenant admins) can't touch these columns.
  IF NEW.slug IS DISTINCT FROM OLD.slug THEN
    RAISE EXCEPTION 'slug is platform-owned; only platform admins can change it';
  END IF;
  IF NEW.name IS DISTINCT FROM OLD.name THEN
    RAISE EXCEPTION 'name is platform-owned; only platform admins can change it';
  END IF;
  IF NEW.lifecycle_state IS DISTINCT FROM OLD.lifecycle_state THEN
    RAISE EXCEPTION 'lifecycle_state is platform-owned; only platform admins can change it';
  END IF;
  IF NEW.created_by IS DISTINCT FROM OLD.created_by THEN
    RAISE EXCEPTION 'created_by is platform-owned';
  END IF;
  IF NEW.id IS DISTINCT FROM OLD.id THEN
    RAISE EXCEPTION 'id is immutable';
  END IF;
  IF NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'created_at is immutable';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS tenants_guard_protected_columns ON tenants;
CREATE TRIGGER tenants_guard_protected_columns
  BEFORE UPDATE ON tenants
  FOR EACH ROW EXECUTE FUNCTION public.guard_tenants_protected_columns();

-- ── Verify ─────────────────────────────────────────────────────────────
SELECT
  (SELECT count(*) FROM pg_policies
     WHERE schemaname = 'public' AND tablename = 'tenants'
       AND policyname = 'tenants_admin_config_update')                     AS admin_update_policy,
  (SELECT count(*) FROM pg_trigger
     WHERE tgrelid = 'public.tenants'::regclass
       AND tgname  = 'tenants_guard_protected_columns')                    AS guard_trigger;

-- ═══════════════════════════════════════════════════════════════════════════
-- ROLLBACK
-- ═══════════════════════════════════════════════════════════════════════════
--
-- DROP TRIGGER  IF EXISTS tenants_guard_protected_columns ON tenants;
-- DROP FUNCTION IF EXISTS public.guard_tenants_protected_columns();
-- DROP POLICY   IF EXISTS "tenants_admin_config_update"   ON tenants;
