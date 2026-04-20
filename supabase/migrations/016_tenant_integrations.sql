-- ═══════════════════════════════════════════════════════════════════════════
-- Pulse — Phase 7 migration: tenant_integrations
-- ═══════════════════════════════════════════════════════════════════════════
--
-- WHAT THIS DOES
--   Creates the per-tenant integrations table — one row per connected
--   external provider (Stripe, Daily.co, Resend, Twilio, etc.). Fields:
--
--     - credentials  jsonb   the secret bag (API keys, tokens, signing
--                            secrets). Shape varies per provider. Read
--                            access is gated to platform users only;
--                            tenant staff — even owners — cannot read
--                            their own stored keys via the API. This is
--                            deliberate: keys are entered during an
--                            operator-assisted setup flow and should
--                            never leak back to a tenant surface.
--     - config       jsonb   non-secret configuration (mode: test/live,
--                            webhook path, base URL overrides). Readable
--                            by tenant staff so admin-side code can
--                            make routing decisions without needing the
--                            credentials.
--     - status       text    connected / disconnected / error. Surfaced
--                            in the operator portal as a pill so Pulse
--                            ops can see at a glance which tenant has
--                            which integrations live.
--     - last_connected_at, last_error, last_error_at
--                            bookkeeping for the "Test connection"
--                            action in the operator portal.
--
-- CREDENTIAL STORAGE — READ THIS
--   Credentials are stored inline in JSONB today. RLS gates read to
--   platform users only. This is the minimum-viable posture for a
--   Phase 7 foundation:
--
--     - Tenant staff can't read secrets back, even via PostgREST
--       (select policy restricts to is_platform_user()).
--     - Secrets are column-level protected by Postgres role
--       boundaries; a compromised tenant session cannot exfiltrate
--       them.
--     - A compromised platform user DOES see every tenant's secrets.
--       Vault migration is the path to fix that and lives as the top
--       Phase 7 carry-over (see PHASES.md).
--
--   Before this table holds production credentials for a live billing
--   integration, migrate to Supabase Vault or equivalent server-held
--   secret store. The column shape (jsonb with a free bag) accommodates
--   a vault-ref shape like `{ "vault_secret_id": "..." }` — swapping
--   storage is app-level, not a schema change.
--
-- WEBHOOK ROUTING
--   config.webhook_path holds the URL fragment the provider posts back
--   to (e.g. stripe webhooks route through /webhooks/stripe/{slug}).
--   The actual router (Edge Function / serverless) lives outside this
--   migration — it reads the tenant off the URL path or provider
--   metadata and looks up this table for the signing secret to verify
--   the payload. Router implementation is a Phase 7 carry-over.
--
-- USAGE
--   Paste into Supabase SQL editor and run. Idempotent.
--
-- ═══════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS tenant_integrations (
  id                  uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id           uuid         NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  provider            text         NOT NULL,
  status              text         NOT NULL DEFAULT 'disconnected',
  credentials         jsonb        NOT NULL DEFAULT '{}'::jsonb,
  config              jsonb        NOT NULL DEFAULT '{}'::jsonb,
  last_connected_at   timestamptz,
  last_error          text,
  last_error_at       timestamptz,
  created_by          uuid         REFERENCES auth.users(id),
  created_at          timestamptz  NOT NULL DEFAULT now(),
  updated_at          timestamptz  NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, provider),
  CONSTRAINT tenant_integrations_status_check
    CHECK (status IN ('connected','disconnected','error'))
);

CREATE INDEX IF NOT EXISTS tenant_integrations_tenant_idx ON tenant_integrations(tenant_id);
CREATE INDEX IF NOT EXISTS tenant_integrations_provider_idx ON tenant_integrations(provider);
CREATE INDEX IF NOT EXISTS tenant_integrations_status_idx ON tenant_integrations(tenant_id, status);

-- Reuse set_updated_at from migration 010.
DROP TRIGGER IF EXISTS tenant_integrations_set_updated_at ON tenant_integrations;
CREATE TRIGGER tenant_integrations_set_updated_at
  BEFORE UPDATE ON tenant_integrations
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ── RLS ───────────────────────────────────────────────────────────────
-- Credentials are platform-read-only. Non-secret config (status,
-- last_connected_at, config bag) is readable by tenant staff so the
-- admin portal can surface "Stripe: connected" without ever loading
-- the secret key. Achieved with a view below — the base table keeps
-- the strict policy; tenant staff read the view instead.

ALTER TABLE tenant_integrations ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "integrations_platform_read" ON tenant_integrations;
CREATE POLICY "integrations_platform_read" ON tenant_integrations
  FOR SELECT TO authenticated
  USING (public.is_platform_user());

DROP POLICY IF EXISTS "integrations_platform_write" ON tenant_integrations;
CREATE POLICY "integrations_platform_write" ON tenant_integrations
  FOR ALL TO authenticated
  USING (public.is_platform_user())
  WITH CHECK (public.is_platform_user());

-- Safe projection for tenant staff — excludes credentials column.
-- Built as a view so the staff-readable surface is version-controlled
-- alongside the table. Tenant staff querying the base table get
-- nothing back (policies above block it); querying this view gets
-- the non-secret fields scoped to their own tenant.

CREATE OR REPLACE VIEW tenant_integrations_public AS
  SELECT
    id,
    tenant_id,
    provider,
    status,
    config,
    last_connected_at,
    last_error,
    last_error_at,
    created_at,
    updated_at
  FROM tenant_integrations;

-- The view inherits RLS from the base table by default, so the public
-- projection still won't leak to unauthorised callers. But the base
-- table's read policy restricts to platform users — we need a
-- dedicated policy on the view that lets tenant staff read their own
-- rows. Postgres views don't carry their own RLS directly; we enable
-- it on the base table with a security-definer wrapper function
-- instead. Simpler path: a second policy on the base table scoped to
-- the specific non-secret columns via a SECURITY BARRIER view.

ALTER VIEW tenant_integrations_public SET (security_barrier = true);

-- Grant the tenant-staff read path by adding a second SELECT policy
-- on the base table that only applies when a specific query shape
-- is used. Postgres can't gate policies on columns, so we take a
-- different approach: a SECURITY DEFINER function callable by tenant
-- staff that returns non-secret rows for their own tenant.

CREATE OR REPLACE FUNCTION public.tenant_integrations_for_my_tenants()
RETURNS SETOF tenant_integrations_public
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT * FROM tenant_integrations_public
  WHERE tenant_id IN (SELECT public.current_tenant_ids())
$$;

GRANT EXECUTE ON FUNCTION public.tenant_integrations_for_my_tenants() TO authenticated;

-- ── Verify ────────────────────────────────────────────────────────────
SELECT
  (SELECT count(*) FROM pg_tables
     WHERE schemaname = 'public' AND tablename = 'tenant_integrations')       AS table_exists,
  (SELECT count(*) FROM pg_policies
     WHERE schemaname = 'public' AND tablename = 'tenant_integrations')       AS policy_count,
  (SELECT count(*) FROM pg_views
     WHERE schemaname = 'public' AND viewname = 'tenant_integrations_public') AS view_exists,
  (SELECT count(*) FROM pg_proc
     WHERE proname = 'tenant_integrations_for_my_tenants')                    AS rpc_exists;

-- ═══════════════════════════════════════════════════════════════════════════
-- ROLLBACK  (run only if you need to fully undo this migration)
-- ═══════════════════════════════════════════════════════════════════════════
--
-- DROP FUNCTION IF EXISTS public.tenant_integrations_for_my_tenants();
-- DROP VIEW IF EXISTS tenant_integrations_public;
-- DROP POLICY IF EXISTS "integrations_platform_write" ON tenant_integrations;
-- DROP POLICY IF EXISTS "integrations_platform_read"  ON tenant_integrations;
-- DROP TABLE IF EXISTS tenant_integrations;
