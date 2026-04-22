-- ═══════════════════════════════════════════════════════════════════════════
-- CommandOS — Phase 0 repair: backfill tenant_integrations directly
-- ═══════════════════════════════════════════════════════════════════════════
--
-- WHAT THIS DOES
--   Migration 028's backfill bumped tenant_subscriptions.updated_at
--   hoping the auto-provision trigger would fire. It did not: the
--   trigger was declared AFTER INSERT OR UPDATE OF plan_id, status,
--   which per Postgres semantics only fires when those specific
--   columns are the update target. Bumping updated_at is a different
--   column set, so the trigger stayed silent and no tenant_integrations
--   rows were provisioned.
--
--   This migration backfills directly (no trigger reliance):
--
--     1. CASE A: every active subscription → insert a
--        tenant_integrations row per provider listed in that
--        subscription's plan.included_integrations.
--
--     2. CASE B: Pulse tenant (slug='pulse') with no active
--        subscription → still provision the 4 curated providers
--        so the admin UI has something to render for dev /
--        demo purposes. Scoped to Pulse only; other tenants
--        must go through the normal plan-assignment path.
--
--   ON CONFLICT DO NOTHING on both, so re-running is safe and
--   nothing with real credentials gets clobbered.
--
-- USAGE
--   Paste into Supabase SQL editor and run. Idempotent.
--
-- ═══════════════════════════════════════════════════════════════════════════

-- ── CASE A: tenants with active subscriptions ──────────────────────────
INSERT INTO tenant_integrations (tenant_id, provider, status, mode, credentials, config)
SELECT
  s.tenant_id,
  provider,
  'disconnected',
  'test',
  '{}'::jsonb,
  '{}'::jsonb
FROM tenant_subscriptions s
JOIN plans p ON p.id = s.plan_id
CROSS JOIN LATERAL unnest(coalesce(p.included_integrations, '{}'::text[])) AS provider
WHERE s.status IN ('trialing','active','past_due','paused','incomplete')
ON CONFLICT (tenant_id, provider) DO NOTHING;

-- ── CASE B: Pulse tenant dev fallback (no subscription required) ──────
INSERT INTO tenant_integrations (tenant_id, provider, status, mode, credentials, config)
SELECT
  t.id,
  provider,
  'disconnected',
  'test',
  '{}'::jsonb,
  '{}'::jsonb
FROM tenants t
CROSS JOIN LATERAL unnest(ARRAY['stripe','twilio','dailyco','resend']::text[]) AS provider
WHERE t.slug = 'pulse'
ON CONFLICT (tenant_id, provider) DO NOTHING;

-- ── Verify ────────────────────────────────────────────────────────────

SELECT
  (SELECT count(*) FROM tenant_integrations)                                             AS total_rows,
  (SELECT count(*) FROM tenant_integrations
     WHERE tenant_id = (SELECT id FROM tenants WHERE slug='pulse'))                      AS pulse_rows,
  (SELECT string_agg(provider, ',' ORDER BY provider) FROM tenant_integrations
     WHERE tenant_id = (SELECT id FROM tenants WHERE slug='pulse'))                      AS pulse_providers;
