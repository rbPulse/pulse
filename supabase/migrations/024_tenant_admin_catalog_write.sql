-- ═══════════════════════════════════════════════════════════════════════════
-- Unite — R6 carry-over: tenant-admin write access to catalog tables
-- ═══════════════════════════════════════════════════════════════════════════
--
-- WHAT THIS DOES
--   Widens the RLS on protocol_templates, protocol_categories, and
--   protocol_product_types so tenant_owner + tenant_admin can INSERT /
--   UPDATE / DELETE rows scoped to their own tenant. Same pattern as
--   migration 014 used for protocol_packages.
--
--   Prior state (migration 005): the "admin write" policy gated writes
--   on legacy profiles.role = 'admin' — the pre-multi-tenant admin
--   concept. Under Unite that maps to platform users only, so
--   tenant admins couldn't write catalog rows even though the catalog
--   has been tenant-scoped since migration 011.
--
--   After this migration: catalog writes are allowed for platform
--   users (unchanged) AND for tenant owners/admins on their own
--   tenant_id (new). Cross-tenant writes are still blocked by the
--   tenant_id filter inside the policy.
--
-- USAGE
--   Paste into Supabase SQL editor and run. Idempotent.
--
-- ═══════════════════════════════════════════════════════════════════════════

-- ── protocol_templates ────────────────────────────────────────────

DROP POLICY IF EXISTS "catalog_tenant_templates_read"  ON protocol_templates;
CREATE POLICY "catalog_tenant_templates_read" ON protocol_templates
  FOR SELECT TO authenticated
  USING (
    tenant_id IN (SELECT public.current_tenant_ids())
    OR public.is_platform_user()
  );

DROP POLICY IF EXISTS "catalog_tenant_templates_write" ON protocol_templates;
CREATE POLICY "catalog_tenant_templates_write" ON protocol_templates
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

-- ── protocol_categories ───────────────────────────────────────────

DROP POLICY IF EXISTS "catalog_tenant_categories_read" ON protocol_categories;
CREATE POLICY "catalog_tenant_categories_read" ON protocol_categories
  FOR SELECT TO authenticated
  USING (
    tenant_id IN (SELECT public.current_tenant_ids())
    OR public.is_platform_user()
  );

DROP POLICY IF EXISTS "catalog_tenant_categories_write" ON protocol_categories;
CREATE POLICY "catalog_tenant_categories_write" ON protocol_categories
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

-- ── protocol_product_types ────────────────────────────────────────

DROP POLICY IF EXISTS "catalog_tenant_product_types_read"  ON protocol_product_types;
CREATE POLICY "catalog_tenant_product_types_read" ON protocol_product_types
  FOR SELECT TO authenticated
  USING (
    tenant_id IN (SELECT public.current_tenant_ids())
    OR public.is_platform_user()
  );

DROP POLICY IF EXISTS "catalog_tenant_product_types_write" ON protocol_product_types;
CREATE POLICY "catalog_tenant_product_types_write" ON protocol_product_types
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

-- ── Retire the legacy profiles.role='admin' write policies ────────
-- They're superseded by the tenant_write policies above. Platform
-- users still have full access via public.is_platform_user().

DROP POLICY IF EXISTS "admin write protocol templates"  ON protocol_templates;
DROP POLICY IF EXISTS "admin write protocol categories" ON protocol_categories;
DROP POLICY IF EXISTS "read protocol templates"         ON protocol_templates;
DROP POLICY IF EXISTS "read protocol categories"        ON protocol_categories;

-- ── Verify ────────────────────────────────────────────────────────
SELECT
  (SELECT count(*) FROM pg_policies WHERE schemaname='public' AND tablename='protocol_templates'     AND policyname='catalog_tenant_templates_write')     AS templates_write,
  (SELECT count(*) FROM pg_policies WHERE schemaname='public' AND tablename='protocol_categories'    AND policyname='catalog_tenant_categories_write')    AS categories_write,
  (SELECT count(*) FROM pg_policies WHERE schemaname='public' AND tablename='protocol_product_types' AND policyname='catalog_tenant_product_types_write') AS product_types_write;

-- ═══════════════════════════════════════════════════════════════════════════
-- ROLLBACK
-- ═══════════════════════════════════════════════════════════════════════════
--
-- DROP POLICY IF EXISTS "catalog_tenant_templates_read"      ON protocol_templates;
-- DROP POLICY IF EXISTS "catalog_tenant_templates_write"     ON protocol_templates;
-- DROP POLICY IF EXISTS "catalog_tenant_categories_read"     ON protocol_categories;
-- DROP POLICY IF EXISTS "catalog_tenant_categories_write"    ON protocol_categories;
-- DROP POLICY IF EXISTS "catalog_tenant_product_types_read"  ON protocol_product_types;
-- DROP POLICY IF EXISTS "catalog_tenant_product_types_write" ON protocol_product_types;
--
-- -- Restore legacy policies from migration 005 if needed:
-- CREATE POLICY "read protocol templates" ON protocol_templates FOR SELECT TO authenticated USING (true);
-- CREATE POLICY "admin write protocol templates" ON protocol_templates FOR ALL TO authenticated
--   USING (EXISTS (SELECT 1 FROM profiles WHERE user_id = auth.uid() AND role = 'admin'))
--   WITH CHECK (EXISTS (SELECT 1 FROM profiles WHERE user_id = auth.uid() AND role = 'admin'));
-- CREATE POLICY "read protocol categories" ON protocol_categories FOR SELECT TO authenticated USING (true);
-- CREATE POLICY "admin write protocol categories" ON protocol_categories FOR ALL TO authenticated
--   USING (EXISTS (SELECT 1 FROM profiles WHERE user_id = auth.uid() AND role = 'admin'))
--   WITH CHECK (EXISTS (SELECT 1 FROM profiles WHERE user_id = auth.uid() AND role = 'admin'));
