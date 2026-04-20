-- ═══════════════════════════════════════════════════════════════════════════
-- Pulse — Phase 4 migration: catalog pricing schema
-- ═══════════════════════════════════════════════════════════════════════════
--
-- WHAT THIS DOES
--   Extends the existing catalog tables so each tenant can price its
--   products independently and bundle them into packages:
--
--     1. Per-tenant key uniqueness on protocol_templates. The original
--        UNIQUE constraint on `key` was global (migration 005), but in
--        multi-tenant world two tenants might both want a "sleep"
--        protocol. Drop the global constraint and replace with a
--        composite UNIQUE (tenant_id, key).
--     2. refill_price + subscription_cadence columns on protocol_templates.
--        Tenants that sell subscriptions charge a different price on
--        refills; cadence governs how often the refill billing event
--        fires.
--     3. New protocol_packages table — named bundles of protocols at a
--        package-level price. tenant-scoped with RLS matching the
--        Phase 0 staff/platform pattern.
--
--   NO data changes. Every existing protocol_templates row keeps its
--   current price. refill_price and subscription_cadence default NULL
--   (interpreted by downstream portals as "same as price; one-time").
--
-- USAGE
--   Paste into Supabase SQL editor and run. Idempotent.
--
-- ROLLBACK
--   See ROLLBACK block at the bottom. Safe to re-run from either
--   direction as long as no packages data exists.
--
-- ═══════════════════════════════════════════════════════════════════════════

-- ── 1. Per-tenant key uniqueness on protocol_templates ─────────────────────
-- The old global UNIQUE lives as an implicit constraint on the key column.
-- Finding its name reliably means querying pg_constraint — simpler to
-- DROP by the pattern Postgres auto-names and use IF EXISTS so a re-run
-- doesn't blow up.

DO $$ BEGIN
  ALTER TABLE protocol_templates DROP CONSTRAINT IF EXISTS protocol_templates_key_key;
EXCEPTION WHEN undefined_object THEN NULL; END $$;

-- Safety net: if the constraint had a different auto-generated name,
-- walk pg_constraint and drop anything unique-tagged on just `key`.
DO $$
DECLARE c text;
BEGIN
  FOR c IN
    SELECT conname FROM pg_constraint
      WHERE conrelid = 'public.protocol_templates'::regclass
        AND contype = 'u'
        AND array_length(conkey, 1) = 1
        AND conkey = ARRAY[(SELECT attnum FROM pg_attribute
                             WHERE attrelid = 'public.protocol_templates'::regclass
                               AND attname = 'key')]::smallint[]
  LOOP
    EXECUTE 'ALTER TABLE protocol_templates DROP CONSTRAINT ' || quote_ident(c);
  END LOOP;
END $$;

-- Composite uniqueness so each tenant gets its own "sleep", "repair", etc.
DO $$ BEGIN
  ALTER TABLE protocol_templates
    ADD CONSTRAINT protocol_templates_tenant_key_uq UNIQUE (tenant_id, key);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- ── 2. Pricing columns on protocol_templates ───────────────────────────────

ALTER TABLE protocol_templates
  ADD COLUMN IF NOT EXISTS refill_price          numeric(10,2),
  ADD COLUMN IF NOT EXISTS subscription_cadence  text;

-- Cadence values are free text so tenants can introduce new billing
-- frequencies without a migration, but we do gate the known set so a
-- typo doesn't land silently. NULL = no subscription, charged per order.
DO $$ BEGIN
  ALTER TABLE protocol_templates
    ADD CONSTRAINT protocol_templates_cadence_check
    CHECK (subscription_cadence IS NULL
           OR subscription_cadence IN ('one_time','weekly','monthly','quarterly','annual'));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- ── 3. protocol_packages ───────────────────────────────────────────────────
-- Bundles of protocols at a package-level price. items is an array of
-- {protocol_id: uuid, quantity: int} — kept in JSONB rather than a
-- separate protocol_package_items table because (a) a package rarely
-- contains more than ~5 items, (b) the admin UI edits the whole bundle
-- atomically so there's no per-row update pattern, (c) read path always
-- pulls the full package. Promote to a normalised table if a tenant
-- eventually has packages with dozens of items, or if analytics needs
-- to join across packages + items.

CREATE TABLE IF NOT EXISTS protocol_packages (
  id             uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id      uuid         NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  key            text         NOT NULL,
  name           text         NOT NULL,
  description    text,
  price          numeric(10,2),
  refill_price   numeric(10,2),
  cadence        text,
  items          jsonb        NOT NULL DEFAULT '[]'::jsonb,
  display_order  int          NOT NULL DEFAULT 0,
  is_archived    boolean      NOT NULL DEFAULT false,
  created_by     uuid         REFERENCES auth.users(id),
  created_at     timestamptz  NOT NULL DEFAULT now(),
  updated_at     timestamptz  NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, key),
  CONSTRAINT protocol_packages_cadence_check
    CHECK (cadence IS NULL
           OR cadence IN ('one_time','weekly','monthly','quarterly','annual'))
);

CREATE INDEX IF NOT EXISTS protocol_packages_tenant_idx ON protocol_packages(tenant_id);
CREATE INDEX IF NOT EXISTS protocol_packages_active_idx
  ON protocol_packages(tenant_id, is_archived);

-- Updated-at trigger reuses set_updated_at() from migration 010.
DROP TRIGGER IF EXISTS protocol_packages_set_updated_at ON protocol_packages;
CREATE TRIGGER protocol_packages_set_updated_at
  BEFORE UPDATE ON protocol_packages
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- RLS follows the Phase 0 staff/platform template.
ALTER TABLE protocol_packages ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "packages_staff_read" ON protocol_packages;
CREATE POLICY "packages_staff_read" ON protocol_packages
  FOR SELECT TO authenticated
  USING (
    tenant_id IN (SELECT public.current_tenant_ids())
    OR public.is_platform_user()
  );

DROP POLICY IF EXISTS "packages_staff_write" ON protocol_packages;
CREATE POLICY "packages_staff_write" ON protocol_packages
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

-- ── Verify ─────────────────────────────────────────────────────────────────
-- Expect: composite UNIQUE on (tenant_id, key), 2 new columns on
-- protocol_templates, 1 new table with RLS enabled.

SELECT
  (SELECT count(*) FROM pg_constraint
     WHERE conname = 'protocol_templates_tenant_key_uq')                     AS templates_tenant_key_uq,
  (SELECT count(*) FROM information_schema.columns
     WHERE table_name = 'protocol_templates' AND column_name = 'refill_price')        AS refill_price_col,
  (SELECT count(*) FROM information_schema.columns
     WHERE table_name = 'protocol_templates' AND column_name = 'subscription_cadence') AS cadence_col,
  (SELECT count(*) FROM pg_tables
     WHERE schemaname = 'public' AND tablename = 'protocol_packages')                 AS packages_table,
  (SELECT count(*) FROM pg_policies
     WHERE schemaname = 'public' AND tablename = 'protocol_packages')                 AS packages_policies;

-- ═══════════════════════════════════════════════════════════════════════════
-- ROLLBACK  (run only if you need to fully undo this migration)
-- ═══════════════════════════════════════════════════════════════════════════
--
-- DROP POLICY IF EXISTS "packages_staff_write" ON protocol_packages;
-- DROP POLICY IF EXISTS "packages_staff_read"  ON protocol_packages;
-- DROP TABLE IF EXISTS protocol_packages;
-- ALTER TABLE protocol_templates DROP CONSTRAINT IF EXISTS protocol_templates_cadence_check;
-- ALTER TABLE protocol_templates DROP COLUMN IF EXISTS subscription_cadence;
-- ALTER TABLE protocol_templates DROP COLUMN IF EXISTS refill_price;
-- ALTER TABLE protocol_templates DROP CONSTRAINT IF EXISTS protocol_templates_tenant_key_uq;
-- -- restoring the old global UNIQUE key is manual — it requires confirming
-- -- no tenant has introduced a duplicate key across tenants:
-- --   SELECT key, count(*) FROM protocol_templates GROUP BY key HAVING count(*) > 1;
-- -- if empty, run:
-- --   ALTER TABLE protocol_templates ADD CONSTRAINT protocol_templates_key_key UNIQUE (key);
