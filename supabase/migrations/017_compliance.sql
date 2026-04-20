-- ═══════════════════════════════════════════════════════════════════════════
-- Pulse — Phase 8 migration: compliance + multi-location + regional
-- ═══════════════════════════════════════════════════════════════════════════
--
-- WHAT THIS DOES
--   Creates four tables that together cover Phase 8's compliance
--   surface. Kept in one migration because the tables reference each
--   other conceptually (regions gate assignment; licenses scope
--   clinicians to states the tenant operates in) and deploying them
--   independently would leave half-wired state.
--
--     1. tenant_locations         physical clinic locations per tenant
--                                 (address, phone, hours, primary flag).
--     2. tenant_regions           which states/regions a tenant
--                                 operates in. One row per (tenant,
--                                 state). is_allowed=false rows track
--                                 deliberate NOT-operating state for
--                                 audit / future-consideration.
--     3. tenant_consents          versioned consent templates (HIPAA
--                                 authorisation, telehealth consent,
--                                 payment authorisation). Members
--                                 sign a specific version; later
--                                 versions don't invalidate prior
--                                 signatures.
--     4. clinician_state_licenses per-clinician licensure records
--                                 keyed by user_id (not tenant), so
--                                 a clinician working at multiple
--                                 tenants has one license row
--                                 visible at each.
--
-- RLS POSTURE
--   Standard staff/platform template for tenant_locations and
--   tenant_regions (tenant staff read; tenant_owner/tenant_admin
--   and platform write). Consents: any authenticated user can read
--   active templates (members need to read consents to sign them);
--   platform + tenant admins write. Licenses: the clinician themselves
--   + tenant admins where they hold a membership + platform users.
--
-- USAGE
--   Paste into Supabase SQL editor and run. Idempotent.
--
-- ROLLBACK
--   See block at the bottom.
--
-- ═══════════════════════════════════════════════════════════════════════════

-- ── 1. tenant_locations ─────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS tenant_locations (
  id             uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id      uuid         NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  name           text         NOT NULL,
  address_line1  text,
  address_line2  text,
  city           text,
  state          text,
  postal_code    text,
  country        text         NOT NULL DEFAULT 'US',
  phone          text,
  hours          jsonb        NOT NULL DEFAULT '{}'::jsonb,
  timezone       text,
  is_primary     boolean      NOT NULL DEFAULT false,
  is_archived    boolean      NOT NULL DEFAULT false,
  display_order  int          NOT NULL DEFAULT 0,
  created_at     timestamptz  NOT NULL DEFAULT now(),
  updated_at     timestamptz  NOT NULL DEFAULT now()
);

-- Exactly one primary location per tenant (enforced at write time by
-- the UI; a partial unique index makes duplicate primaries rejected).
CREATE UNIQUE INDEX IF NOT EXISTS tenant_locations_primary_uq
  ON tenant_locations(tenant_id)
  WHERE is_primary AND NOT is_archived;

CREATE INDEX IF NOT EXISTS tenant_locations_tenant_idx ON tenant_locations(tenant_id);

DROP TRIGGER IF EXISTS tenant_locations_set_updated_at ON tenant_locations;
CREATE TRIGGER tenant_locations_set_updated_at
  BEFORE UPDATE ON tenant_locations
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

ALTER TABLE tenant_locations ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "locations_staff_read" ON tenant_locations;
CREATE POLICY "locations_staff_read" ON tenant_locations
  FOR SELECT TO authenticated
  USING (
    tenant_id IN (SELECT public.current_tenant_ids())
    OR public.is_platform_user()
  );

DROP POLICY IF EXISTS "locations_staff_write" ON tenant_locations;
CREATE POLICY "locations_staff_write" ON tenant_locations
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

-- ── 2. tenant_regions ───────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS tenant_regions (
  id          uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   uuid         NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  state       text         NOT NULL,
  is_allowed  boolean      NOT NULL DEFAULT true,
  notes       text,
  created_at  timestamptz  NOT NULL DEFAULT now(),
  updated_at  timestamptz  NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, state),
  CONSTRAINT tenant_regions_state_format CHECK (state ~ '^[A-Z]{2}$')
);

CREATE INDEX IF NOT EXISTS tenant_regions_tenant_idx ON tenant_regions(tenant_id);
CREATE INDEX IF NOT EXISTS tenant_regions_allowed_idx ON tenant_regions(tenant_id, is_allowed);

DROP TRIGGER IF EXISTS tenant_regions_set_updated_at ON tenant_regions;
CREATE TRIGGER tenant_regions_set_updated_at
  BEFORE UPDATE ON tenant_regions
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

ALTER TABLE tenant_regions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "regions_staff_read" ON tenant_regions;
CREATE POLICY "regions_staff_read" ON tenant_regions
  FOR SELECT TO authenticated
  USING (
    tenant_id IN (SELECT public.current_tenant_ids())
    OR public.is_platform_user()
  );

DROP POLICY IF EXISTS "regions_staff_write" ON tenant_regions;
CREATE POLICY "regions_staff_write" ON tenant_regions
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

-- ── 3. tenant_consents ──────────────────────────────────────────────────────
-- Versioned so signing a v1 consent doesn't evaporate when v2 lands.
-- Member signatures (who signed what version when) live in a separate
-- member_consent_signatures table that's NOT part of this migration —
-- the signature table lands when the member intake flow gets
-- consent-gated (Phase 9 / 10). Today, signatures are implicit from
-- having completed intake.

CREATE TABLE IF NOT EXISTS tenant_consents (
  id                    uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id             uuid         NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  key                   text         NOT NULL,
  version               int          NOT NULL DEFAULT 1,
  title                 text         NOT NULL,
  body                  text         NOT NULL,
  requires_signature    boolean      NOT NULL DEFAULT true,
  effective_date        date,
  is_archived           boolean      NOT NULL DEFAULT false,
  created_by            uuid         REFERENCES auth.users(id),
  created_at            timestamptz  NOT NULL DEFAULT now(),
  updated_at            timestamptz  NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, key, version)
);

CREATE INDEX IF NOT EXISTS tenant_consents_tenant_idx ON tenant_consents(tenant_id);
CREATE INDEX IF NOT EXISTS tenant_consents_active_idx
  ON tenant_consents(tenant_id, key)
  WHERE NOT is_archived;

DROP TRIGGER IF EXISTS tenant_consents_set_updated_at ON tenant_consents;
CREATE TRIGGER tenant_consents_set_updated_at
  BEFORE UPDATE ON tenant_consents
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

ALTER TABLE tenant_consents ENABLE ROW LEVEL SECURITY;

-- Anyone authenticated at the tenant (staff or member) reads active
-- consent templates — members need to read them to sign. Archived or
-- superseded versions stay readable so old signatures can resolve
-- back to the exact template text the member agreed to.
DROP POLICY IF EXISTS "consents_tenant_read" ON tenant_consents;
CREATE POLICY "consents_tenant_read" ON tenant_consents
  FOR SELECT TO authenticated
  USING (
    tenant_id IN (SELECT public.current_tenant_ids())
    OR public.is_platform_user()
  );

DROP POLICY IF EXISTS "consents_staff_write" ON tenant_consents;
CREATE POLICY "consents_staff_write" ON tenant_consents
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

-- ── 4. clinician_state_licenses ─────────────────────────────────────────────
-- Per-clinician, NOT per-tenant. A clinician holding a California medical
-- license carries that license regardless of which tenant they work at.
-- Tenants read this table when deciding which clinicians can be assigned
-- to members in specific states. Read access is gated to "any tenant
-- this clinician belongs to" — so the Pulse admin can see a moonlighter's
-- licenses but Tenant B can't see the licenses of a Tenant A clinician
-- unless the clinician also works at Tenant B.

CREATE TABLE IF NOT EXISTS clinician_state_licenses (
  id             uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id        uuid         NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  state          text         NOT NULL,
  license_number text         NOT NULL,
  issuing_board  text,
  issued_date    date,
  expires_date   date,
  document_url   text,
  notes          text,
  is_active      boolean      NOT NULL DEFAULT true,
  created_at     timestamptz  NOT NULL DEFAULT now(),
  updated_at     timestamptz  NOT NULL DEFAULT now(),
  UNIQUE (user_id, state, license_number),
  CONSTRAINT clinician_state_licenses_state_format CHECK (state ~ '^[A-Z]{2}$')
);

CREATE INDEX IF NOT EXISTS clinician_licenses_user_idx ON clinician_state_licenses(user_id);
CREATE INDEX IF NOT EXISTS clinician_licenses_state_idx ON clinician_state_licenses(state);
CREATE INDEX IF NOT EXISTS clinician_licenses_expiry_idx
  ON clinician_state_licenses(expires_date)
  WHERE is_active AND expires_date IS NOT NULL;

DROP TRIGGER IF EXISTS clinician_licenses_set_updated_at ON clinician_state_licenses;
CREATE TRIGGER clinician_licenses_set_updated_at
  BEFORE UPDATE ON clinician_state_licenses
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

ALTER TABLE clinician_state_licenses ENABLE ROW LEVEL SECURITY;

-- Read: the clinician themselves, any tenant admin at a tenant where
-- the clinician has a membership, and platform users.
DROP POLICY IF EXISTS "licenses_read" ON clinician_state_licenses;
CREATE POLICY "licenses_read" ON clinician_state_licenses
  FOR SELECT TO authenticated
  USING (
    user_id = auth.uid()
    OR public.is_platform_user()
    OR EXISTS (
      SELECT 1 FROM tenant_memberships me
      JOIN tenant_memberships target ON me.tenant_id = target.tenant_id
      WHERE me.user_id = auth.uid()
        AND me.role IN ('tenant_owner','tenant_admin')
        AND target.user_id = clinician_state_licenses.user_id
    )
  );

-- Write: same set. A clinician can maintain their own licenses; their
-- tenants' admins can update on their behalf (e.g. when re-credentialing
-- an entire roster).
DROP POLICY IF EXISTS "licenses_write" ON clinician_state_licenses;
CREATE POLICY "licenses_write" ON clinician_state_licenses
  FOR ALL TO authenticated
  USING (
    user_id = auth.uid()
    OR public.is_platform_user()
    OR EXISTS (
      SELECT 1 FROM tenant_memberships me
      JOIN tenant_memberships target ON me.tenant_id = target.tenant_id
      WHERE me.user_id = auth.uid()
        AND me.role IN ('tenant_owner','tenant_admin')
        AND target.user_id = clinician_state_licenses.user_id
    )
  )
  WITH CHECK (
    user_id = auth.uid()
    OR public.is_platform_user()
    OR EXISTS (
      SELECT 1 FROM tenant_memberships me
      JOIN tenant_memberships target ON me.tenant_id = target.tenant_id
      WHERE me.user_id = auth.uid()
        AND me.role IN ('tenant_owner','tenant_admin')
        AND target.user_id = clinician_state_licenses.user_id
    )
  );

-- ── Verify ─────────────────────────────────────────────────────────────
SELECT
  (SELECT count(*) FROM pg_tables WHERE schemaname = 'public' AND tablename = 'tenant_locations')          AS locations_table,
  (SELECT count(*) FROM pg_tables WHERE schemaname = 'public' AND tablename = 'tenant_regions')            AS regions_table,
  (SELECT count(*) FROM pg_tables WHERE schemaname = 'public' AND tablename = 'tenant_consents')           AS consents_table,
  (SELECT count(*) FROM pg_tables WHERE schemaname = 'public' AND tablename = 'clinician_state_licenses')  AS licenses_table,
  (SELECT count(*) FROM pg_policies
     WHERE schemaname = 'public'
       AND tablename IN ('tenant_locations','tenant_regions','tenant_consents','clinician_state_licenses'))  AS total_policies;

-- ═══════════════════════════════════════════════════════════════════════════
-- ROLLBACK
-- ═══════════════════════════════════════════════════════════════════════════
--
-- DROP POLICY IF EXISTS "licenses_write" ON clinician_state_licenses;
-- DROP POLICY IF EXISTS "licenses_read"  ON clinician_state_licenses;
-- DROP TABLE IF EXISTS clinician_state_licenses;
-- DROP POLICY IF EXISTS "consents_staff_write" ON tenant_consents;
-- DROP POLICY IF EXISTS "consents_tenant_read" ON tenant_consents;
-- DROP TABLE IF EXISTS tenant_consents;
-- DROP POLICY IF EXISTS "regions_staff_write" ON tenant_regions;
-- DROP POLICY IF EXISTS "regions_staff_read"  ON tenant_regions;
-- DROP TABLE IF EXISTS tenant_regions;
-- DROP POLICY IF EXISTS "locations_staff_write" ON tenant_locations;
-- DROP POLICY IF EXISTS "locations_staff_read"  ON tenant_locations;
-- DROP TABLE IF EXISTS tenant_locations;
