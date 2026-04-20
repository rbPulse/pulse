-- ═══════════════════════════════════════════════════════════════════════════
-- Pulse — Phase 9 migration: plans, subscriptions, module entitlements
-- ═══════════════════════════════════════════════════════════════════════════
--
-- WHAT THIS DOES
--   Creates the three tables backing Phase 9's commercial surface:
--
--     1. plans                   platform-wide plan catalog (Starter,
--                                Pro, Enterprise, etc.). Not tenant-
--                                scoped — the plans themselves are
--                                Pulse-owned; each tenant picks ONE.
--     2. tenant_subscriptions    per-tenant subscription state. Holds
--                                the plan reference, Stripe IDs, billing
--                                cycle, period window. One "active"
--                                row per tenant; canceled rows stay as
--                                history.
--     3. module_entitlements     per-tenant, per-module enablement.
--                                Modules come from the plan (source=
--                                'plan') or are added/removed manually
--                                (source='override' or 'addon').
--                                module_key is a stable slug referenced
--                                by downstream feature gates.
--
--   plans is the one table here that's NOT tenant-scoped — it's the
--   Pulse-side catalog. Everything else is tenant_id-scoped with the
--   standard staff/platform RLS template.
--
-- STRIPE IDs
--   stripe_customer_id + stripe_subscription_id are text columns. We
--   don't enforce a foreign-key to Stripe, obviously, and we don't
--   require them — a tenant on a trial plan with no card on file has
--   NULLs here. Populated by Phase 7's Stripe integration when it
--   lands (see carry-over). Until then, subscriptions are tracked
--   manually by platform operators.
--
-- USAGE
--   Paste into Supabase SQL editor and run. Idempotent.
--
-- ═══════════════════════════════════════════════════════════════════════════

-- ── plans ────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS plans (
  id                     uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
  key                    text         NOT NULL UNIQUE,
  name                   text         NOT NULL,
  description            text,
  monthly_price          numeric(10,2),
  annual_price           numeric(10,2),
  included_modules       text[]       NOT NULL DEFAULT '{}',
  stripe_price_id_monthly text,
  stripe_price_id_annual  text,
  is_archived            boolean      NOT NULL DEFAULT false,
  display_order          int          NOT NULL DEFAULT 0,
  created_at             timestamptz  NOT NULL DEFAULT now(),
  updated_at             timestamptz  NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS plans_active_idx ON plans(display_order) WHERE NOT is_archived;

DROP TRIGGER IF EXISTS plans_set_updated_at ON plans;
CREATE TRIGGER plans_set_updated_at
  BEFORE UPDATE ON plans
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

ALTER TABLE plans ENABLE ROW LEVEL SECURITY;

-- Plans are a public catalog — any authenticated user can read so the
-- signup / billing surface can render pricing without special role.
DROP POLICY IF EXISTS "plans_read" ON plans;
CREATE POLICY "plans_read" ON plans
  FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS "plans_platform_write" ON plans;
CREATE POLICY "plans_platform_write" ON plans
  FOR ALL TO authenticated
  USING (public.is_platform_user())
  WITH CHECK (public.is_platform_user());

-- ── tenant_subscriptions ───────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS tenant_subscriptions (
  id                        uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id                 uuid         NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  plan_id                   uuid         NOT NULL REFERENCES plans(id),
  billing_cycle             text         NOT NULL DEFAULT 'monthly',
  status                    text         NOT NULL DEFAULT 'trialing',
  stripe_customer_id        text,
  stripe_subscription_id    text,
  current_period_start      timestamptz,
  current_period_end        timestamptz,
  trial_end                 timestamptz,
  cancel_at_period_end      boolean      NOT NULL DEFAULT false,
  canceled_at               timestamptz,
  notes                     text,
  created_by                uuid         REFERENCES auth.users(id),
  created_at                timestamptz  NOT NULL DEFAULT now(),
  updated_at                timestamptz  NOT NULL DEFAULT now(),
  CONSTRAINT tenant_subscriptions_billing_cycle_check
    CHECK (billing_cycle IN ('monthly','annual')),
  CONSTRAINT tenant_subscriptions_status_check
    CHECK (status IN ('trialing','active','past_due','canceled','paused','incomplete'))
);

CREATE INDEX IF NOT EXISTS tenant_subs_tenant_idx ON tenant_subscriptions(tenant_id);
CREATE INDEX IF NOT EXISTS tenant_subs_plan_idx ON tenant_subscriptions(plan_id);
CREATE INDEX IF NOT EXISTS tenant_subs_status_idx ON tenant_subscriptions(status);
CREATE UNIQUE INDEX IF NOT EXISTS tenant_subs_one_active_uq
  ON tenant_subscriptions(tenant_id)
  WHERE status IN ('trialing','active','past_due','paused','incomplete');

DROP TRIGGER IF EXISTS tenant_subs_set_updated_at ON tenant_subscriptions;
CREATE TRIGGER tenant_subs_set_updated_at
  BEFORE UPDATE ON tenant_subscriptions
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

ALTER TABLE tenant_subscriptions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "subs_staff_read" ON tenant_subscriptions;
CREATE POLICY "subs_staff_read" ON tenant_subscriptions
  FOR SELECT TO authenticated
  USING (
    tenant_id IN (SELECT public.current_tenant_ids())
    OR public.is_platform_user()
  );

DROP POLICY IF EXISTS "subs_platform_write" ON tenant_subscriptions;
CREATE POLICY "subs_platform_write" ON tenant_subscriptions
  FOR ALL TO authenticated
  USING (public.is_platform_user())
  WITH CHECK (public.is_platform_user());

-- ── module_entitlements ───────────────────────────────────────────────
-- Per-tenant, per-module. Usually derived from the subscription plan
-- but with manual override capacity for ad-hoc grants (sales gives a
-- prospect live-video for 30 days; ops grants a friend-and-family
-- tenant an Enterprise feature).

CREATE TABLE IF NOT EXISTS module_entitlements (
  id          uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   uuid         NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  module_key  text         NOT NULL,
  enabled     boolean      NOT NULL DEFAULT true,
  source      text         NOT NULL DEFAULT 'plan',
  expires_at  timestamptz,
  notes       text,
  granted_by  uuid         REFERENCES auth.users(id),
  created_at  timestamptz  NOT NULL DEFAULT now(),
  updated_at  timestamptz  NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, module_key),
  CONSTRAINT module_entitlements_source_check
    CHECK (source IN ('plan','override','addon','trial'))
);

CREATE INDEX IF NOT EXISTS module_ent_tenant_idx ON module_entitlements(tenant_id);
CREATE INDEX IF NOT EXISTS module_ent_enabled_idx
  ON module_entitlements(tenant_id, module_key)
  WHERE enabled;

DROP TRIGGER IF EXISTS module_ent_set_updated_at ON module_entitlements;
CREATE TRIGGER module_ent_set_updated_at
  BEFORE UPDATE ON module_entitlements
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

ALTER TABLE module_entitlements ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "entitlements_staff_read" ON module_entitlements;
CREATE POLICY "entitlements_staff_read" ON module_entitlements
  FOR SELECT TO authenticated
  USING (
    tenant_id IN (SELECT public.current_tenant_ids())
    OR public.is_platform_user()
  );

DROP POLICY IF EXISTS "entitlements_platform_write" ON module_entitlements;
CREATE POLICY "entitlements_platform_write" ON module_entitlements
  FOR ALL TO authenticated
  USING (public.is_platform_user())
  WITH CHECK (public.is_platform_user());

-- ── Seed baseline plans ───────────────────────────────────────────────
-- Three plans so the operator portal has something to pick from on
-- first boot. Real-world plan definitions will replace these once the
-- commercial team has priced things.

INSERT INTO plans (key, name, description, monthly_price, annual_price, included_modules, display_order)
VALUES
  ('starter',
   'Starter',
   'For new clinics launching their first telehealth offering. Core portals, up to 3 clinicians, async messaging, no advanced analytics.',
   299, 2990,
   ARRAY['async_messaging','portal_access','member_intake'],
   1),
  ('pro',
   'Pro',
   'Growing practices. Everything in Starter plus live video consults, e-prescribing, advanced analytics, multi-location.',
   899, 8990,
   ARRAY['async_messaging','portal_access','member_intake','live_video','e_prescribing','advanced_analytics','multi_location'],
   2),
  ('enterprise',
   'Enterprise',
   'Multi-clinic groups. Everything in Pro plus lab ordering, custom SSO, dedicated infra, white-label branding, SLA.',
   NULL, NULL,
   ARRAY['async_messaging','portal_access','member_intake','live_video','e_prescribing','advanced_analytics','multi_location','labs','custom_sso','white_label','api_access','dedicated_infra'],
   3)
ON CONFLICT (key) DO UPDATE SET
  name              = EXCLUDED.name,
  description       = EXCLUDED.description,
  monthly_price     = EXCLUDED.monthly_price,
  annual_price      = EXCLUDED.annual_price,
  included_modules  = EXCLUDED.included_modules,
  display_order     = EXCLUDED.display_order;

-- ── Verify ────────────────────────────────────────────────────────────

SELECT
  (SELECT count(*) FROM pg_tables WHERE schemaname = 'public' AND tablename = 'plans')                  AS plans_table,
  (SELECT count(*) FROM pg_tables WHERE schemaname = 'public' AND tablename = 'tenant_subscriptions')   AS subs_table,
  (SELECT count(*) FROM pg_tables WHERE schemaname = 'public' AND tablename = 'module_entitlements')    AS entitlements_table,
  (SELECT count(*) FROM plans)                                                                          AS plan_rows,
  (SELECT count(*) FROM pg_policies
     WHERE schemaname = 'public'
       AND tablename IN ('plans','tenant_subscriptions','module_entitlements'))                         AS total_policies;

-- ═══════════════════════════════════════════════════════════════════════════
-- ROLLBACK
-- ═══════════════════════════════════════════════════════════════════════════
--
-- DROP POLICY IF EXISTS "entitlements_platform_write" ON module_entitlements;
-- DROP POLICY IF EXISTS "entitlements_staff_read"     ON module_entitlements;
-- DROP TABLE IF EXISTS module_entitlements;
-- DROP POLICY IF EXISTS "subs_platform_write" ON tenant_subscriptions;
-- DROP POLICY IF EXISTS "subs_staff_read"     ON tenant_subscriptions;
-- DROP TABLE IF EXISTS tenant_subscriptions;
-- DROP POLICY IF EXISTS "plans_platform_write" ON plans;
-- DROP POLICY IF EXISTS "plans_read"           ON plans;
-- DROP TABLE IF EXISTS plans;
