-- ═══════════════════════════════════════════════════════════════════════════
-- Pulse — Phase 2 migration: brand-assets storage bucket
-- ═══════════════════════════════════════════════════════════════════════════
--
-- WHAT THIS DOES
--   Creates a public Supabase Storage bucket for per-tenant brand assets
--   (logos, favicons, any other image used by the downstream portals to
--   brand themselves). Public so the downstream portals can render the
--   image with a plain <img src> — no signed URL, no auth round-trip on
--   every portal load.
--
--   Path convention:  {tenant_id}/logo.{ext}
--                     {tenant_id}/favicon.{ext}
--                     {tenant_id}/{any-other-asset}.{ext}
--
--   Writes are gated to platform users only. Tenant admins don't edit
--   their own brand today — all brand config lives on the operator portal.
--   If that changes, relax the WITH CHECK clause to also allow tenant
--   owners/admins writing to their own tenant's path prefix.
--
-- USAGE
--   Paste into Supabase SQL editor and run. Idempotent — safe to re-run.
--
-- ROLLBACK
--   See ROLLBACK block at the bottom. Empty the bucket first if it
--   holds real data — dropping a non-empty bucket fails.
--
-- ═══════════════════════════════════════════════════════════════════════════

-- ── Bucket ─────────────────────────────────────────────────────────────────
-- public = true means unauthenticated GETs work; RLS still governs writes.

INSERT INTO storage.buckets (id, name, public)
VALUES ('brand-assets', 'brand-assets', true)
ON CONFLICT (id) DO UPDATE SET public = EXCLUDED.public;

-- ── Policies on storage.objects ───────────────────────────────────────────
-- Public bucket gives free SELECT to everyone, so we only need to write
-- the three mutating policies. Each checks public.is_platform_user()
-- (helper defined in migration 010) so only Pulse internal operators can
-- push or replace brand assets. Scoped to this bucket so these policies
-- don't shadow policies on other buckets that haven't been created yet.

DROP POLICY IF EXISTS "brand_assets_platform_insert" ON storage.objects;
CREATE POLICY "brand_assets_platform_insert" ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (
    bucket_id = 'brand-assets'
    AND public.is_platform_user()
  );

DROP POLICY IF EXISTS "brand_assets_platform_update" ON storage.objects;
CREATE POLICY "brand_assets_platform_update" ON storage.objects
  FOR UPDATE TO authenticated
  USING (
    bucket_id = 'brand-assets'
    AND public.is_platform_user()
  )
  WITH CHECK (
    bucket_id = 'brand-assets'
    AND public.is_platform_user()
  );

DROP POLICY IF EXISTS "brand_assets_platform_delete" ON storage.objects;
CREATE POLICY "brand_assets_platform_delete" ON storage.objects
  FOR DELETE TO authenticated
  USING (
    bucket_id = 'brand-assets'
    AND public.is_platform_user()
  );

-- ── Verify ─────────────────────────────────────────────────────────────────
-- Expect: 1 bucket row with public=true, 3 policies on storage.objects
-- scoped to this bucket.

SELECT
  (SELECT count(*) FROM storage.buckets WHERE id = 'brand-assets' AND public = true) AS bucket_exists,
  (SELECT count(*) FROM pg_policies
     WHERE schemaname = 'storage' AND tablename = 'objects'
       AND policyname LIKE 'brand_assets_%')                                          AS policy_count;

-- ═══════════════════════════════════════════════════════════════════════════
-- ROLLBACK  (run only if you need to fully undo this migration)
-- ═══════════════════════════════════════════════════════════════════════════
--
-- -- Empty the bucket first or this fails:
-- -- DELETE FROM storage.objects WHERE bucket_id = 'brand-assets';
-- DROP POLICY IF EXISTS "brand_assets_platform_delete" ON storage.objects;
-- DROP POLICY IF EXISTS "brand_assets_platform_update" ON storage.objects;
-- DROP POLICY IF EXISTS "brand_assets_platform_insert" ON storage.objects;
-- DELETE FROM storage.buckets WHERE id = 'brand-assets';
