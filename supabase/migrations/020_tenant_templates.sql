-- ═══════════════════════════════════════════════════════════════════════════
-- Pulse — Phase 12 migration: tenant_templates
-- ═══════════════════════════════════════════════════════════════════════════
--
-- WHAT THIS DOES
--   Creates tenant_templates — a library of starter packs. Each row is
--   a snapshot of tenant config (brand, terminology, workflow,
--   compliance, features JSONB layers) plus seed-item arrays that the
--   "apply template" flow deserializes into rows on the target tenant
--   (catalog protocols, categories, product types, comms templates,
--   operating regions, consents).
--
--   Templates are Pulse-owned, not tenant-scoped. Operators pick from
--   the library when creating a new tenant or apply a template to an
--   existing tenant to bulk-seed config.
--
-- SNAPSHOT SHAPE
--   config_snapshot is a JSONB bag with well-known top-level keys:
--
--     {
--       "layers": {
--         "brand":       {...},  // merged into tenants.brand
--         "terminology": {...},  // merged into tenants.terminology
--         "workflow":    {...},  // merged into tenants.workflow
--         "compliance":  {...},  // merged into tenants.compliance
--         "features":    {...}   // merged into tenants.features
--       },
--       "seeds": {
--         "protocols":       [...],  // each → protocol_templates insert
--         "categories":      [...],  // each → protocol_categories insert
--         "product_types":   [...],  // each → protocol_product_types insert
--         "comms_templates": [...],  // each → communication_templates insert
--         "regions":         [...],  // state codes → tenant_regions insert
--         "consents":        [...]   // each → tenant_consents insert
--       }
--     }
--
--   Application is a straightforward merge + insert; the shape is
--   stable-but-extensible. Unknown keys in `layers` or `seeds` are
--   ignored, so older templates stay apply-able as the shape grows.
--
-- USAGE
--   Paste into Supabase SQL editor and run. Idempotent.
--
-- ═══════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS tenant_templates (
  id                  uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
  key                 text         NOT NULL UNIQUE,
  name                text         NOT NULL,
  description         text,
  vertical            text,
  config_snapshot     jsonb        NOT NULL DEFAULT '{}'::jsonb,
  source_tenant_id    uuid         REFERENCES tenants(id) ON DELETE SET NULL,
  is_archived         boolean      NOT NULL DEFAULT false,
  display_order       int          NOT NULL DEFAULT 0,
  created_by          uuid         REFERENCES auth.users(id),
  created_at          timestamptz  NOT NULL DEFAULT now(),
  updated_at          timestamptz  NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS tenant_templates_vertical_idx ON tenant_templates(vertical);
CREATE INDEX IF NOT EXISTS tenant_templates_active_idx
  ON tenant_templates(display_order) WHERE NOT is_archived;

DROP TRIGGER IF EXISTS tenant_templates_set_updated_at ON tenant_templates;
CREATE TRIGGER tenant_templates_set_updated_at
  BEFORE UPDATE ON tenant_templates
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ── RLS ───────────────────────────────────────────────────────────────
-- Readable by any authenticated user so the create-tenant form can
-- render the picker regardless of role. Write-gated to platform users.
ALTER TABLE tenant_templates ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "templates_read" ON tenant_templates;
CREATE POLICY "templates_read" ON tenant_templates
  FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS "templates_platform_write" ON tenant_templates;
CREATE POLICY "templates_platform_write" ON tenant_templates
  FOR ALL TO authenticated
  USING (public.is_platform_user())
  WITH CHECK (public.is_platform_user());

-- ── Seed templates ───────────────────────────────────────────────────
-- Two starter packs: a minimal Pulse baseline (empty defaults — use
-- as a "blank slate" when no vertical applies) and a Wellness Clinic
-- example that's opinionated enough to be useful out of the box.
-- Real templates will replace these as commercial patterns emerge.

INSERT INTO tenant_templates (key, name, description, vertical, display_order, config_snapshot)
VALUES
  (
    'blank',
    'Blank (Pulse defaults)',
    'Minimal seed. Brand, terminology, workflow stay at Pulse defaults. Use when onboarding a tenant that doesn\u2019t fit a specific vertical.',
    NULL,
    1,
    '{"layers":{},"seeds":{}}'::jsonb
  ),
  (
    'wellness',
    'Wellness Clinic Starter',
    'Cash-pay wellness vertical. Members and protocols (not patients and prescriptions). Async-review workflow, 14-day refill window, quarterly follow-ups. Seeds sample categories + an intro consent template.',
    'wellness',
    2,
    jsonb_build_object(
      'layers', jsonb_build_object(
        'terminology', jsonb_build_object(
          'member',       'Member',
          'members',      'Members',
          'clinician',    'Provider',
          'clinicians',   'Providers',
          'protocol',     'Protocol',
          'protocols',    'Protocols',
          'prescription', 'Order',
          'prescriptions','Orders',
          'refill',       'Renewal',
          'refills',      'Renewals',
          'consultation', 'Visit',
          'consultations','Visits'
        ),
        'workflow', jsonb_build_object(
          'intake',     jsonb_build_object('required', true),
          'consult',    jsonb_build_object('policy', 'required_for_first_rx', 'allow_async_review', true),
          'refill',     jsonb_build_object('eligibility_days_before_runout', 14, 'clinician_review_required', true),
          'sla_hours',  jsonb_build_object('intake_review', 48, 'refill_approval', 48),
          'follow_up',  jsonb_build_object('cadence_days', 90)
        )
      ),
      'seeds', jsonb_build_object(
        'categories', jsonb_build_array(
          jsonb_build_object('name', 'Longevity',   'display_order', 1),
          jsonb_build_object('name', 'Performance', 'display_order', 2),
          jsonb_build_object('name', 'Recovery',    'display_order', 3)
        ),
        'product_types', jsonb_build_array(
          jsonb_build_object('name', 'Daily',    'display_order', 1),
          jsonb_build_object('name', 'Monthly',  'display_order', 2)
        ),
        'consents', jsonb_build_array(
          jsonb_build_object(
            'key', 'telehealth_consent',
            'version', 1,
            'title', 'Telehealth Consent',
            'body', 'I consent to receive clinical care via telehealth. I understand the limits of remote evaluation and agree to the terms of service.',
            'requires_signature', true
          )
        ),
        'regions', jsonb_build_array('CA','NY','TX','FL')
      )
    )
  )
ON CONFLICT (key) DO UPDATE SET
  name              = EXCLUDED.name,
  description       = EXCLUDED.description,
  vertical          = EXCLUDED.vertical,
  display_order     = EXCLUDED.display_order,
  config_snapshot   = EXCLUDED.config_snapshot;

-- ── Verify ────────────────────────────────────────────────────────────
SELECT
  (SELECT count(*) FROM pg_tables WHERE schemaname = 'public' AND tablename = 'tenant_templates') AS table_exists,
  (SELECT count(*) FROM tenant_templates)                                                         AS template_count,
  (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND tablename = 'tenant_templates') AS policy_count;

-- ═══════════════════════════════════════════════════════════════════════════
-- ROLLBACK
-- ═══════════════════════════════════════════════════════════════════════════
--
-- DROP POLICY IF EXISTS "templates_platform_write" ON tenant_templates;
-- DROP POLICY IF EXISTS "templates_read"           ON tenant_templates;
-- DROP TABLE IF EXISTS tenant_templates;
