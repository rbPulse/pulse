-- ═══════════════════════════════════════════════════════════════════════════
-- Pulse — Phase 0 migration: multi-tenant foundation
-- ═══════════════════════════════════════════════════════════════════════════
--
-- WHAT THIS DOES
--   Stands up the core multi-tenant primitives without touching any
--   existing table. After this runs, Pulse continues to work exactly
--   as before — nothing references these new tables yet. Migration 011
--   is what actually wires existing data to the new structure.
--
--   Objects created:
--     - enum  tenant_lifecycle_state     (sandbox | live | suspended | archived)
--     - enum  tenant_role                (staff roles within a tenant)
--     - enum  platform_role              (Pulse-internal operator roles)
--     - enum  patient_enrollment_status  (active | inactive | discharged)
--     - table tenants                    (registry of clinic clients)
--     - table tenant_memberships         (staff ↔ tenant + role)
--     - table patient_enrollments        (patient ↔ tenant + status)
--     - column profiles.platform_role    (nullable; only set for Pulse internal)
--     - function public.current_tenant_ids()  (helper used by later RLS policies)
--     - seed row: Pulse tenant with a well-known UUID
--
-- USAGE
--   Paste into Supabase SQL editor and run. Idempotent — safe to re-run.
--
-- ROLLBACK
--   See `ROLLBACK` block at the bottom. Run the statements there to undo.
--   No existing data is modified by this migration, so rollback is clean.
--
-- ═══════════════════════════════════════════════════════════════════════════

-- ── Enums ──────────────────────────────────────────────────────────────────

DO $$ BEGIN
  CREATE TYPE tenant_lifecycle_state AS ENUM (
    'sandbox', 'live', 'suspended', 'archived'
  );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE tenant_role AS ENUM (
    'tenant_owner',
    'tenant_admin',
    'tenant_clinician',
    'tenant_nurse',
    'tenant_billing',
    'tenant_analyst'
  );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE platform_role AS ENUM (
    'platform_super_admin',
    'platform_admin',
    'platform_ops',
    'platform_support',
    'platform_billing',
    'platform_readonly'
  );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE patient_enrollment_status AS ENUM (
    'active', 'inactive', 'discharged'
  );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- ── tenants ────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS tenants (
  id               uuid                   PRIMARY KEY DEFAULT gen_random_uuid(),
  slug             text                   NOT NULL UNIQUE,
  name             text                   NOT NULL,
  legal_name       text,
  lifecycle_state  tenant_lifecycle_state NOT NULL DEFAULT 'sandbox',
  -- JSONB config layers. Empty until their phase lands.
  brand            jsonb                  NOT NULL DEFAULT '{}'::jsonb,
  terminology      jsonb                  NOT NULL DEFAULT '{}'::jsonb,
  workflow         jsonb                  NOT NULL DEFAULT '{}'::jsonb,
  catalog_config   jsonb                  NOT NULL DEFAULT '{}'::jsonb,
  comms_config     jsonb                  NOT NULL DEFAULT '{}'::jsonb,
  integrations     jsonb                  NOT NULL DEFAULT '{}'::jsonb,
  compliance       jsonb                  NOT NULL DEFAULT '{}'::jsonb,
  features         jsonb                  NOT NULL DEFAULT '{}'::jsonb,
  -- Bookkeeping.
  created_at       timestamptz            NOT NULL DEFAULT now(),
  updated_at       timestamptz            NOT NULL DEFAULT now(),
  created_by       uuid                   REFERENCES auth.users(id),
  -- Slug is the URL segment used in /t/{slug}/. Lowercase letters, digits,
  -- hyphens; no leading/trailing hyphen. Enforced via check constraint.
  CONSTRAINT tenants_slug_format CHECK (slug ~ '^[a-z0-9]([a-z0-9-]*[a-z0-9])?$'),
  CONSTRAINT tenants_slug_reserved CHECK (slug NOT IN (
    'admin', 'portal', 'platform', 'api', 't', 'tenants', 'assets', 'static'
  ))
);

CREATE INDEX IF NOT EXISTS tenants_lifecycle_idx ON tenants(lifecycle_state);

-- ── tenant_memberships (staff) ─────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS tenant_memberships (
  id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       uuid        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  tenant_id     uuid        NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  role          tenant_role NOT NULL,
  -- Future per-role overrides (max caseload, allowed states, etc.).
  capabilities  jsonb       NOT NULL DEFAULT '{}'::jsonb,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  -- A user has at most one role per tenant. If they need multiple roles,
  -- that's a capabilities-map concern, not a row-count concern.
  UNIQUE (user_id, tenant_id)
);

CREATE INDEX IF NOT EXISTS tenant_memberships_user_idx   ON tenant_memberships(user_id);
CREATE INDEX IF NOT EXISTS tenant_memberships_tenant_idx ON tenant_memberships(tenant_id);

-- ── patient_enrollments (end users) ────────────────────────────────────────

CREATE TABLE IF NOT EXISTS patient_enrollments (
  id            uuid                      PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       uuid                      NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  tenant_id     uuid                      NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  status        patient_enrollment_status NOT NULL DEFAULT 'active',
  enrolled_at   timestamptz               NOT NULL DEFAULT now(),
  discharged_at timestamptz,
  created_at    timestamptz               NOT NULL DEFAULT now(),
  updated_at    timestamptz               NOT NULL DEFAULT now(),
  -- A person can be enrolled at multiple tenants, but at most once per tenant.
  UNIQUE (user_id, tenant_id)
);

CREATE INDEX IF NOT EXISTS patient_enrollments_user_idx   ON patient_enrollments(user_id);
CREATE INDEX IF NOT EXISTS patient_enrollments_tenant_idx ON patient_enrollments(tenant_id);
CREATE INDEX IF NOT EXISTS patient_enrollments_status_idx ON patient_enrollments(tenant_id, status);

-- ── profiles.platform_role ─────────────────────────────────────────────────
-- Nullable by design: only Pulse internal team has a value here. Every other
-- user has NULL and is purely a tenant participant.

ALTER TABLE profiles
  ADD COLUMN IF NOT EXISTS platform_role platform_role;

-- ── updated_at triggers ────────────────────────────────────────────────────
-- Reusing the same pattern the rest of the schema uses (if this helper
-- doesn't exist yet we create it here so later tables can also depend on it).

CREATE OR REPLACE FUNCTION set_updated_at() RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS tenants_set_updated_at ON tenants;
CREATE TRIGGER tenants_set_updated_at
  BEFORE UPDATE ON tenants
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

DROP TRIGGER IF EXISTS tenant_memberships_set_updated_at ON tenant_memberships;
CREATE TRIGGER tenant_memberships_set_updated_at
  BEFORE UPDATE ON tenant_memberships
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

DROP TRIGGER IF EXISTS patient_enrollments_set_updated_at ON patient_enrollments;
CREATE TRIGGER patient_enrollments_set_updated_at
  BEFORE UPDATE ON patient_enrollments
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ── Helpers: public.current_tenant_ids() / public.is_platform_user() ──────
-- Live in the public schema because Supabase's auth schema is reserved for
-- its own auth functions (writes to auth are permission-denied for the
-- dashboard role). They still call auth.uid(), which is a Supabase-provided
-- function we're allowed to read.
--
-- SECURITY DEFINER so the functions bypass RLS on tenant_memberships and
-- patient_enrollments — otherwise using them *inside* an RLS policy on
-- those tables would recurse.

CREATE OR REPLACE FUNCTION public.current_tenant_ids()
RETURNS SETOF uuid
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT tenant_id FROM tenant_memberships WHERE user_id = auth.uid()
  UNION
  SELECT tenant_id FROM patient_enrollments WHERE user_id = auth.uid();
$$;

CREATE OR REPLACE FUNCTION public.is_platform_user()
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1 FROM profiles
    WHERE user_id = auth.uid() AND platform_role IS NOT NULL
  );
$$;

-- ── RLS on the new tables ──────────────────────────────────────────────────

ALTER TABLE tenants              ENABLE ROW LEVEL SECURITY;
ALTER TABLE tenant_memberships   ENABLE ROW LEVEL SECURITY;
ALTER TABLE patient_enrollments  ENABLE ROW LEVEL SECURITY;

-- tenants: readable by anyone with a membership or enrollment; writable only
-- by platform users. (Tenant owners editing their own tenant config happens
-- via the operator portal path, which runs as a platform user — tenant-side
-- config editing is built in later phases with tighter policies.)
DROP POLICY IF EXISTS "tenants_read" ON tenants;
CREATE POLICY "tenants_read" ON tenants
  FOR SELECT TO authenticated
  USING (
    id IN (SELECT public.current_tenant_ids())
    OR public.is_platform_user()
  );

DROP POLICY IF EXISTS "tenants_platform_write" ON tenants;
CREATE POLICY "tenants_platform_write" ON tenants
  FOR ALL TO authenticated
  USING (public.is_platform_user())
  WITH CHECK (public.is_platform_user());

-- tenant_memberships: a user can see their own memberships; staff at a
-- tenant can see all of that tenant's memberships; platform users see all.
DROP POLICY IF EXISTS "memberships_self_read" ON tenant_memberships;
CREATE POLICY "memberships_self_read" ON tenant_memberships
  FOR SELECT TO authenticated
  USING (
    user_id = auth.uid()
    OR tenant_id IN (SELECT public.current_tenant_ids())
    OR public.is_platform_user()
  );

DROP POLICY IF EXISTS "memberships_platform_write" ON tenant_memberships;
CREATE POLICY "memberships_platform_write" ON tenant_memberships
  FOR ALL TO authenticated
  USING (public.is_platform_user())
  WITH CHECK (public.is_platform_user());

-- patient_enrollments: a patient sees their own; tenant staff see all of
-- their tenant's patients; platform users see all.
DROP POLICY IF EXISTS "enrollments_self_read" ON patient_enrollments;
CREATE POLICY "enrollments_self_read" ON patient_enrollments
  FOR SELECT TO authenticated
  USING (
    user_id = auth.uid()
    OR tenant_id IN (SELECT public.current_tenant_ids())
    OR public.is_platform_user()
  );

DROP POLICY IF EXISTS "enrollments_platform_write" ON patient_enrollments;
CREATE POLICY "enrollments_platform_write" ON patient_enrollments
  FOR ALL TO authenticated
  USING (public.is_platform_user())
  WITH CHECK (public.is_platform_user());

-- ── Seed: Pulse tenant ─────────────────────────────────────────────────────
-- Fixed UUID so migration 011 can reference it during backfill without
-- a separate lookup. If you regenerate this UUID you MUST update 011 to match.

INSERT INTO tenants (id, slug, name, legal_name, lifecycle_state)
VALUES (
  '00000000-0000-0000-0000-000000000001',
  'pulse',
  'Pulse',
  'Pulse',
  'live'
)
ON CONFLICT (slug) DO NOTHING;

-- ── Verify ─────────────────────────────────────────────────────────────────
-- Expect: 3 new tables, 4 new enums, 1 new profiles column, 1 seed row.

SELECT
  (SELECT count(*) FROM tenants WHERE slug = 'pulse')                     AS pulse_tenant_exists,
  (SELECT count(*) FROM pg_type WHERE typname = 'tenant_lifecycle_state') AS lifecycle_enum,
  (SELECT count(*) FROM pg_type WHERE typname = 'tenant_role')            AS tenant_role_enum,
  (SELECT count(*) FROM pg_type WHERE typname = 'platform_role')          AS platform_role_enum,
  (SELECT count(*) FROM pg_type WHERE typname = 'patient_enrollment_status') AS enrollment_status_enum,
  (SELECT count(*) FROM information_schema.columns
     WHERE table_name = 'profiles' AND column_name = 'platform_role')     AS profiles_platform_role_col;

-- ═══════════════════════════════════════════════════════════════════════════
-- ROLLBACK  (run only if you need to fully undo this migration)
-- ═══════════════════════════════════════════════════════════════════════════
--
-- DROP POLICY IF EXISTS "enrollments_platform_write"   ON patient_enrollments;
-- DROP POLICY IF EXISTS "enrollments_self_read"        ON patient_enrollments;
-- DROP POLICY IF EXISTS "memberships_platform_write"   ON tenant_memberships;
-- DROP POLICY IF EXISTS "memberships_self_read"        ON tenant_memberships;
-- DROP POLICY IF EXISTS "tenants_platform_write"       ON tenants;
-- DROP POLICY IF EXISTS "tenants_read"                 ON tenants;
-- DROP FUNCTION IF EXISTS public.is_platform_user();
-- DROP FUNCTION IF EXISTS public.current_tenant_ids();
-- DROP TABLE IF EXISTS patient_enrollments;
-- DROP TABLE IF EXISTS tenant_memberships;
-- DROP TABLE IF EXISTS tenants;
-- ALTER TABLE profiles DROP COLUMN IF EXISTS platform_role;
-- DROP TYPE IF EXISTS patient_enrollment_status;
-- DROP TYPE IF EXISTS platform_role;
-- DROP TYPE IF EXISTS tenant_role;
-- DROP TYPE IF EXISTS tenant_lifecycle_state;
-- (set_updated_at function is reused elsewhere; leave it.)
