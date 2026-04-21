-- ═══════════════════════════════════════════════════════════════════════════
-- CommandOS — Phase 0 migration: plan-level integration entitlement
-- ═══════════════════════════════════════════════════════════════════════════
--
-- WHAT THIS DOES
--   Sets up the three-layer integration architecture across existing
--   tables (no new catalog/entitlement tables — the JS catalog in
--   integrations.js stays source of truth):
--
--     LAYER 1 · Catalog      → integrations.js (shipping code, rare change)
--     LAYER 2 · Entitlement  → plans.included_integrations text[]  (NEW)
--     LAYER 3 · Per-tenant   → tenant_integrations + mode column   (NEW col)
--
--   Changes in this migration:
--
--     1. plans.included_integrations text[]
--          Mirrors the existing plans.included_modules pattern. Lists
--          provider slugs (e.g. {'stripe','twilio','dailyco','resend'})
--          that tenants on this plan can configure. Non-included
--          providers are invisible in the tenant admin Integrations tab.
--
--     2. tenant_integrations.mode text
--          Explicit test|live column (was previously buried inside the
--          config JSONB). Enables a one-click "go live" UX and reliable
--          fleet-wide queries like "how many tenants are in live mode
--          on Stripe". Default 'test' so new rows start sandboxed.
--
--     3. auto_provision_tenant_integrations() trigger
--          Fires on tenant_subscriptions insert/update. Ensures each
--          provider in the new plan's included_integrations has a row
--          in tenant_integrations for this tenant. Pre-existing rows
--          are left untouched — we never clobber operator-entered
--          credentials. Rows for providers the new plan DOESN'T
--          include are also left in place (status stays as-is but the
--          admin UI will hide them; downgrade path is a carry-over).
--
--     4. Backfill
--          Every existing plan gets included_integrations = the four
--          active providers. Every existing tenant with a subscription
--          gets tenant_integrations rows provisioned for the providers
--          its plan includes. Daily rows for Pulse are preserved.
--
-- USAGE
--   Paste into Supabase SQL editor and run. Idempotent.
--
-- ═══════════════════════════════════════════════════════════════════════════

-- ── 1. plans.included_integrations ────────────────────────────────────

ALTER TABLE plans
  ADD COLUMN IF NOT EXISTS included_integrations text[] NOT NULL DEFAULT '{}';

-- ── 2. tenant_integrations.mode ───────────────────────────────────────

ALTER TABLE tenant_integrations
  ADD COLUMN IF NOT EXISTS mode text NOT NULL DEFAULT 'test';

-- Drop any prior version of the check so we can re-add cleanly.
ALTER TABLE tenant_integrations
  DROP CONSTRAINT IF EXISTS tenant_integrations_mode_check;
ALTER TABLE tenant_integrations
  ADD CONSTRAINT tenant_integrations_mode_check
  CHECK (mode IN ('test','live'));

-- Extend the staff-readable view so tenant admins can see the mode
-- (they need it to render the test/live toggle). The view already
-- excludes credentials; mode is non-secret config.
--
-- IMPORTANT: new columns must be appended at the END of the SELECT
-- list. Postgres CREATE OR REPLACE VIEW only allows additions after
-- the existing columns — inserting a column in the middle raises
-- "cannot change name of view column". The column position in this
-- SELECT is a public contract for SELECT * consumers (like the
-- tenant_integrations_for_my_tenants function below).
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
    updated_at,
    mode
  FROM tenant_integrations;

ALTER VIEW tenant_integrations_public SET (security_barrier = true);

-- Extend the guard so tenant admins can toggle mode but NOT change
-- credentials or system-managed columns. Existing guard from
-- migration 023 is replaced.
CREATE OR REPLACE FUNCTION public.guard_integrations_protected_columns()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  -- Platform users can change anything.
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

  IF NEW.status IS DISTINCT FROM OLD.status THEN
    IF NEW.status NOT IN ('connected', 'disconnected') THEN
      RAISE EXCEPTION 'status can only be set to connected or disconnected by tenant admins';
    END IF;
  END IF;

  IF NEW.mode IS DISTINCT FROM OLD.mode THEN
    IF NEW.mode NOT IN ('test','live') THEN
      RAISE EXCEPTION 'mode must be test or live';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

-- ── 3. Auto-provision trigger ─────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.auto_provision_tenant_integrations()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_providers text[];
  v_provider  text;
BEGIN
  -- Only act on active-ish statuses; don't auto-provision for a
  -- canceled subscription re-insert.
  IF NEW.status NOT IN ('trialing','active','past_due','paused','incomplete') THEN
    RETURN NEW;
  END IF;

  SELECT included_integrations INTO v_providers
  FROM plans WHERE id = NEW.plan_id;

  IF v_providers IS NULL OR array_length(v_providers, 1) IS NULL THEN
    RETURN NEW;
  END IF;

  FOREACH v_provider IN ARRAY v_providers LOOP
    -- UNIQUE(tenant_id, provider) guards against double-insert; use
    -- ON CONFLICT DO NOTHING so existing rows (with real credentials)
    -- are never clobbered.
    INSERT INTO tenant_integrations (tenant_id, provider, status, mode, credentials, config)
    VALUES (NEW.tenant_id, v_provider, 'disconnected', 'test', '{}'::jsonb, '{}'::jsonb)
    ON CONFLICT (tenant_id, provider) DO NOTHING;
  END LOOP;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS tenant_subscriptions_auto_provision_integrations ON tenant_subscriptions;
CREATE TRIGGER tenant_subscriptions_auto_provision_integrations
  AFTER INSERT OR UPDATE OF plan_id, status ON tenant_subscriptions
  FOR EACH ROW EXECUTE FUNCTION public.auto_provision_tenant_integrations();

-- ── 4. Backfill ───────────────────────────────────────────────────────
--
-- Every existing plan gets the four active providers. Operators can
-- trim per-plan later from CommandOS (Phase 4 wires the UI for this).
UPDATE plans
   SET included_integrations = ARRAY['stripe','twilio','dailyco','resend']
 WHERE (included_integrations IS NULL OR array_length(included_integrations, 1) IS NULL);

-- Every existing subscription gets its integrations provisioned.
-- Fires the trigger above for each active subscription by bumping
-- updated_at (no-op content change); the trigger then inserts
-- missing rows. Pre-existing rows (e.g. Pulse's Daily config) are
-- preserved by ON CONFLICT DO NOTHING.
DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT id FROM tenant_subscriptions
     WHERE status IN ('trialing','active','past_due','paused','incomplete')
  LOOP
    UPDATE tenant_subscriptions SET updated_at = now() WHERE id = r.id;
  END LOOP;
END $$;

-- ── Verify ────────────────────────────────────────────────────────────

SELECT
  (SELECT count(*) FROM information_schema.columns
     WHERE table_name = 'plans' AND column_name = 'included_integrations')              AS plans_col_added,
  (SELECT count(*) FROM information_schema.columns
     WHERE table_name = 'tenant_integrations' AND column_name = 'mode')                 AS ti_mode_col_added,
  (SELECT count(*) FROM pg_trigger
     WHERE tgname = 'tenant_subscriptions_auto_provision_integrations')                 AS provision_trigger,
  (SELECT count(*) FROM plans
     WHERE 'stripe' = ANY(included_integrations))                                       AS plans_with_stripe,
  (SELECT count(*) FROM tenant_integrations
     WHERE provider IN ('stripe','twilio','dailyco','resend'))                          AS tenant_int_rows_after_backfill;

-- ═══════════════════════════════════════════════════════════════════════════
-- ROLLBACK (run only if you need to fully undo this migration)
-- ═══════════════════════════════════════════════════════════════════════════
--
-- DROP TRIGGER IF EXISTS tenant_subscriptions_auto_provision_integrations ON tenant_subscriptions;
-- DROP FUNCTION IF EXISTS public.auto_provision_tenant_integrations();
-- ALTER TABLE tenant_integrations DROP CONSTRAINT IF EXISTS tenant_integrations_mode_check;
-- ALTER TABLE tenant_integrations DROP COLUMN IF EXISTS mode;
-- ALTER TABLE plans DROP COLUMN IF EXISTS included_integrations;
-- (The guard function revert to migration 023's version if needed.)
