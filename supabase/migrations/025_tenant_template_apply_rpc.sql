-- ═══════════════════════════════════════════════════════════════════════════
-- Pulse — Setup Wizard: apply_tenant_template RPC + curated templates
-- ═══════════════════════════════════════════════════════════════════════════
--
-- WHAT THIS DOES
--   1. Adds three curated tenant_templates (Peptide Therapy, Weight
--      Loss, Hormone Therapy) alongside the existing Blank + Wellness
--      seeds from migration 020. Each carries a full config_snapshot:
--      terminology overrides, workflow defaults, protocol categories,
--      product types, consent documents, region allow-lists.
--
--   2. Creates apply_tenant_template(p_template_id, p_tenant_id) as a
--      SECURITY DEFINER RPC so a tenant admin clicking "Apply template"
--      in the Getting Started wizard can run the merge without needing
--      a cross-product Unite roundtrip.
--
--      The RPC:
--        - Verifies the caller is a tenant_owner or tenant_admin of
--          the target tenant (or a platform user).
--        - Shallow-merges layers (brand / terminology / workflow /
--          compliance / features) onto the tenant's existing columns.
--        - Inserts seeds (categories, product_types, protocols,
--          comms_templates, regions, consents) with the target
--          tenant_id. Uses ON CONFLICT DO NOTHING so re-apply is
--          safe — existing rows stay untouched.
--        - Writes a structured audit_logs row with the before /
--          after snapshot, same shape Phase 10 established.
--
-- USAGE
--   Paste into Supabase SQL editor and run. Idempotent.
--
-- ═══════════════════════════════════════════════════════════════════════════

-- ── Curated templates ────────────────────────────────────────────────

INSERT INTO tenant_templates (key, name, description, vertical, display_order, config_snapshot)
VALUES
  -- Peptide Therapy (the Pulse flagship vertical)
  (
    'peptide_therapy',
    'Peptide Therapy Clinic',
    'Peptide protocols (GLP-1, growth factors, recovery). Async clinician review, monthly check-ins, 14-day refill window. Seeds Recovery / Performance / Longevity categories + telehealth consent.',
    'peptide_therapy',
    3,
    jsonb_build_object(
      'layers', jsonb_build_object(
        'terminology', jsonb_build_object(
          'member',        'Member',
          'members',       'Members',
          'clinician',     'Clinician',
          'clinicians',    'Clinicians',
          'protocol',      'Protocol',
          'protocols',     'Protocols',
          'prescription',  'Protocol',
          'prescriptions', 'Protocols',
          'refill',        'Refill',
          'refills',       'Refills',
          'consultation',  'Intake',
          'consultations', 'Intakes'
        ),
        'workflow', jsonb_build_object(
          'intake',    jsonb_build_object('required', true),
          'consult',   jsonb_build_object('policy', 'required_for_first_rx', 'allow_async_review', true),
          'refill',    jsonb_build_object('eligibility_days_before_runout', 14, 'clinician_review_required', true),
          'sla_hours', jsonb_build_object('intake_review', 24, 'refill_approval', 24),
          'follow_up', jsonb_build_object('cadence_days', 30)
        ),
        'features', jsonb_build_object(
          'telehealth_sessions', true,
          'dose_logging',        true,
          'check_in_schedule',   true
        )
      ),
      'seeds', jsonb_build_object(
        'categories', jsonb_build_array(
          jsonb_build_object('name', 'Recovery',    'display_order', 1),
          jsonb_build_object('name', 'Performance', 'display_order', 2),
          jsonb_build_object('name', 'Longevity',   'display_order', 3),
          jsonb_build_object('name', 'Body Comp',   'display_order', 4)
        ),
        'product_types', jsonb_build_array(
          jsonb_build_object('name', 'Pod',   'display_order', 1),
          jsonb_build_object('name', 'Stack', 'display_order', 2)
        ),
        'regions', jsonb_build_array('CA','NY','TX','FL','AZ','CO','WA'),
        'consents', jsonb_build_array(
          jsonb_build_object(
            'key', 'telehealth_consent', 'version', 1,
            'title', 'Telehealth Consent',
            'body',  'I consent to receive care via telehealth. I understand peptides are prescribed compounded medications, not FDA-approved drugs, and require clinician review of intake responses.',
            'requires_signature', true
          ),
          jsonb_build_object(
            'key', 'controlled_substances_acknowledgment', 'version', 1,
            'title', 'Clinician Review Acknowledgment',
            'body',  'I understand a licensed clinician must review my intake responses before any protocol is prescribed. Responses must be truthful and complete.',
            'requires_signature', true
          )
        )
      )
    )
  ),

  -- Weight Loss Clinic
  (
    'weight_loss',
    'Weight Loss Clinic',
    'GLP-1-driven weight management. Monthly check-ins with weight + side-effect tracking. Intake includes BMI + contraindication screening. Refills require check-in completion.',
    'weight_loss',
    4,
    jsonb_build_object(
      'layers', jsonb_build_object(
        'terminology', jsonb_build_object(
          'member',        'Patient',
          'members',       'Patients',
          'clinician',     'Clinician',
          'clinicians',    'Clinicians',
          'protocol',      'Protocol',
          'protocols',     'Protocols',
          'prescription',  'Prescription',
          'prescriptions', 'Prescriptions',
          'refill',        'Refill',
          'refills',       'Refills',
          'consultation',  'Consultation',
          'consultations', 'Consultations'
        ),
        'workflow', jsonb_build_object(
          'intake',    jsonb_build_object('required', true, 'require_bmi', true),
          'consult',   jsonb_build_object('policy', 'required_for_first_rx', 'allow_async_review', true),
          'refill',    jsonb_build_object('eligibility_days_before_runout', 7, 'clinician_review_required', true, 'require_check_in_completion', true),
          'sla_hours', jsonb_build_object('intake_review', 24, 'refill_approval', 24),
          'follow_up', jsonb_build_object('cadence_days', 30)
        ),
        'features', jsonb_build_object(
          'weight_tracking',     true,
          'side_effect_logging', true,
          'dose_escalation',     true
        )
      ),
      'seeds', jsonb_build_object(
        'categories', jsonb_build_array(
          jsonb_build_object('name', 'GLP-1 Agonists', 'display_order', 1),
          jsonb_build_object('name', 'Combination',    'display_order', 2)
        ),
        'product_types', jsonb_build_array(
          jsonb_build_object('name', 'Weekly', 'display_order', 1),
          jsonb_build_object('name', 'Daily',  'display_order', 2)
        ),
        'regions', jsonb_build_array('CA','NY','TX','FL','AZ','CO','WA','IL','GA','NC','VA','PA'),
        'consents', jsonb_build_array(
          jsonb_build_object(
            'key', 'weight_loss_consent', 'version', 1,
            'title', 'GLP-1 Weight Loss Treatment Consent',
            'body',  'I consent to GLP-1-based weight management. I acknowledge potential side effects including nausea, GI symptoms, and rare serious events. I will report side effects promptly.',
            'requires_signature', true
          ),
          jsonb_build_object(
            'key', 'telehealth_consent', 'version', 1,
            'title', 'Telehealth Consent',
            'body',  'I consent to receive care via telehealth. I understand remote evaluation limits and accept them for this treatment.',
            'requires_signature', true
          )
        )
      )
    )
  ),

  -- Hormone Therapy Clinic
  (
    'hormone_therapy',
    'Hormone Therapy Clinic',
    'TRT / HRT / peri-menopause. Lab-review required before first prescription, quarterly re-labs. Workflow defaults to synchronous consult for first Rx, async for refills.',
    'hormone_therapy',
    5,
    jsonb_build_object(
      'layers', jsonb_build_object(
        'terminology', jsonb_build_object(
          'member',        'Patient',
          'members',       'Patients',
          'clinician',     'Provider',
          'clinicians',    'Providers',
          'protocol',      'Therapy',
          'protocols',     'Therapies',
          'prescription',  'Prescription',
          'prescriptions', 'Prescriptions',
          'refill',        'Refill',
          'refills',       'Refills',
          'consultation',  'Consultation',
          'consultations', 'Consultations'
        ),
        'workflow', jsonb_build_object(
          'intake',    jsonb_build_object('required', true, 'require_labs', true),
          'consult',   jsonb_build_object('policy', 'synchronous_for_first_rx', 'allow_async_review', false, 'allow_async_refill', true),
          'refill',    jsonb_build_object('eligibility_days_before_runout', 30, 'clinician_review_required', true, 'require_recent_labs_months', 3),
          'sla_hours', jsonb_build_object('intake_review', 48, 'refill_approval', 48),
          'follow_up', jsonb_build_object('cadence_days', 90)
        ),
        'features', jsonb_build_object(
          'lab_tracking',      true,
          'synchronous_visits',true,
          'check_in_schedule', true
        )
      ),
      'seeds', jsonb_build_object(
        'categories', jsonb_build_array(
          jsonb_build_object('name', 'Testosterone',   'display_order', 1),
          jsonb_build_object('name', 'Estrogen',       'display_order', 2),
          jsonb_build_object('name', 'Thyroid',        'display_order', 3),
          jsonb_build_object('name', 'Peptide Adjunct','display_order', 4)
        ),
        'product_types', jsonb_build_array(
          jsonb_build_object('name', 'Injection',   'display_order', 1),
          jsonb_build_object('name', 'Topical',     'display_order', 2),
          jsonb_build_object('name', 'Oral',        'display_order', 3),
          jsonb_build_object('name', 'Pellet',      'display_order', 4)
        ),
        'regions', jsonb_build_array('CA','NY','TX','FL','AZ','CO','WA','NV','IL'),
        'consents', jsonb_build_array(
          jsonb_build_object(
            'key', 'hormone_therapy_consent', 'version', 1,
            'title', 'Hormone Therapy Consent',
            'body',  'I consent to hormone therapy evaluation and prescribing. I acknowledge cardiovascular, metabolic, and endocrine risks and commit to the lab-monitoring cadence my provider sets.',
            'requires_signature', true
          ),
          jsonb_build_object(
            'key', 'telehealth_consent', 'version', 1,
            'title', 'Telehealth Consent',
            'body',  'I consent to receive care via telehealth. I understand the limits of remote evaluation.',
            'requires_signature', true
          )
        )
      )
    )
  )
ON CONFLICT (key) DO UPDATE SET
  name            = EXCLUDED.name,
  description     = EXCLUDED.description,
  vertical        = EXCLUDED.vertical,
  display_order   = EXCLUDED.display_order,
  config_snapshot = EXCLUDED.config_snapshot;


-- ── apply_tenant_template RPC ────────────────────────────────────────
-- SECURITY DEFINER so the tenant admin's RLS role doesn't need direct
-- write on every seed table. The function internally enforces caller
-- authority: platform user OR tenant_owner/tenant_admin of p_tenant_id.

CREATE OR REPLACE FUNCTION public.apply_tenant_template(
  p_template_id uuid,
  p_tenant_id   uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_caller          uuid := auth.uid();
  v_is_platform     boolean;
  v_is_tenant_admin boolean;
  v_template        tenant_templates%ROWTYPE;
  v_snapshot        jsonb;
  v_layers          jsonb;
  v_seeds           jsonb;
  v_tenant_before   jsonb;
  v_tenant_after    jsonb;
  v_counts          jsonb := '{}'::jsonb;
  v_applied         jsonb;
  v_cat             jsonb;
  v_pt              jsonb;
  v_proto           jsonb;
  v_consent         jsonb;
  v_region          text;
  v_comms_tmpl      jsonb;
  v_n_cat           int := 0;
  v_n_pt            int := 0;
  v_n_proto         int := 0;
  v_n_consent       int := 0;
  v_n_region        int := 0;
  v_n_comms         int := 0;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'authentication required';
  END IF;

  v_is_platform := public.is_platform_user();
  v_is_tenant_admin := EXISTS (
    SELECT 1 FROM tenant_memberships
    WHERE user_id = v_caller AND tenant_id = p_tenant_id
      AND role IN ('tenant_owner','tenant_admin')
  );
  IF NOT (v_is_platform OR v_is_tenant_admin) THEN
    RAISE EXCEPTION 'not authorized to apply templates to this tenant';
  END IF;

  SELECT * INTO v_template FROM tenant_templates WHERE id = p_template_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'template % not found', p_template_id;
  END IF;

  v_snapshot := COALESCE(v_template.config_snapshot, '{}'::jsonb);
  v_layers   := COALESCE(v_snapshot->'layers', '{}'::jsonb);
  v_seeds    := COALESCE(v_snapshot->'seeds',  '{}'::jsonb);

  -- Capture before-snapshot for audit trail.
  SELECT jsonb_build_object(
    'brand',        brand,
    'terminology',  terminology,
    'workflow',     workflow,
    'compliance',   compliance,
    'features',     features
  ) INTO v_tenant_before
  FROM tenants WHERE id = p_tenant_id;

  -- Layer merge. Each layer shallow-merges overlay over existing so
  -- keys not in the template stay put. An absent layer in the template
  -- is a no-op; an empty {} overlay is also a no-op (jsonb || works
  -- with null gracefully when coalesced).
  UPDATE tenants SET
    brand       = COALESCE(brand,       '{}'::jsonb) || COALESCE(v_layers->'brand',       '{}'::jsonb),
    terminology = COALESCE(terminology, '{}'::jsonb) || COALESCE(v_layers->'terminology', '{}'::jsonb),
    workflow    = COALESCE(workflow,    '{}'::jsonb) || COALESCE(v_layers->'workflow',    '{}'::jsonb),
    compliance  = COALESCE(compliance,  '{}'::jsonb) || COALESCE(v_layers->'compliance',  '{}'::jsonb),
    features    = COALESCE(features,    '{}'::jsonb) || COALESCE(v_layers->'features',    '{}'::jsonb)
  WHERE id = p_tenant_id;

  -- Seed categories: INSERT … ON CONFLICT (tenant_id, name) DO NOTHING
  -- keeps re-apply safe. Unique constraint on (tenant_id, name) may not
  -- exist historically, so we guard with EXISTS instead of ON CONFLICT
  -- to stay portable across schema states.
  FOR v_cat IN SELECT * FROM jsonb_array_elements(COALESCE(v_seeds->'categories', '[]'::jsonb)) LOOP
    IF NOT EXISTS (
      SELECT 1 FROM protocol_categories
      WHERE tenant_id = p_tenant_id AND name = v_cat->>'name'
    ) THEN
      INSERT INTO protocol_categories (tenant_id, name, display_order)
      VALUES (p_tenant_id, v_cat->>'name', COALESCE((v_cat->>'display_order')::int, 0));
      v_n_cat := v_n_cat + 1;
    END IF;
  END LOOP;

  FOR v_pt IN SELECT * FROM jsonb_array_elements(COALESCE(v_seeds->'product_types', '[]'::jsonb)) LOOP
    IF NOT EXISTS (
      SELECT 1 FROM protocol_product_types
      WHERE tenant_id = p_tenant_id AND name = v_pt->>'name'
    ) THEN
      INSERT INTO protocol_product_types (tenant_id, name, display_order)
      VALUES (p_tenant_id, v_pt->>'name', COALESCE((v_pt->>'display_order')::int, 0));
      v_n_pt := v_n_pt + 1;
    END IF;
  END LOOP;

  -- Protocols: tenant_id + key is the composite unique (migration 014).
  FOR v_proto IN SELECT * FROM jsonb_array_elements(COALESCE(v_seeds->'protocols', '[]'::jsonb)) LOOP
    IF NOT EXISTS (
      SELECT 1 FROM protocol_templates
      WHERE tenant_id = p_tenant_id AND key = v_proto->>'key'
    ) THEN
      INSERT INTO protocol_templates (
        tenant_id, key, name, product_type, category,
        price, refill_price, subscription_cadence, compounds
      ) VALUES (
        p_tenant_id,
        v_proto->>'key',
        v_proto->>'name',
        v_proto->>'product_type',
        v_proto->>'category',
        NULLIF(v_proto->>'price', '')::numeric,
        NULLIF(v_proto->>'refill_price', '')::numeric,
        v_proto->>'subscription_cadence',
        COALESCE(v_proto->'compounds', '[]'::jsonb)
      );
      v_n_proto := v_n_proto + 1;
    END IF;
  END LOOP;

  -- Regions: tenant_regions.state is unique per tenant_id.
  FOR v_region IN SELECT jsonb_array_elements_text(COALESCE(v_seeds->'regions', '[]'::jsonb)) LOOP
    IF NOT EXISTS (
      SELECT 1 FROM tenant_regions
      WHERE tenant_id = p_tenant_id AND state = v_region
    ) THEN
      INSERT INTO tenant_regions (tenant_id, state, is_allowed)
      VALUES (p_tenant_id, v_region, true);
      v_n_region := v_n_region + 1;
    END IF;
  END LOOP;

  -- Consents: key + version unique per tenant_id.
  FOR v_consent IN SELECT * FROM jsonb_array_elements(COALESCE(v_seeds->'consents', '[]'::jsonb)) LOOP
    IF NOT EXISTS (
      SELECT 1 FROM tenant_consents
      WHERE tenant_id = p_tenant_id AND key = v_consent->>'key' AND version = COALESCE((v_consent->>'version')::int, 1)
    ) THEN
      INSERT INTO tenant_consents (
        tenant_id, key, version, title, body, requires_signature
      ) VALUES (
        p_tenant_id,
        v_consent->>'key',
        COALESCE((v_consent->>'version')::int, 1),
        v_consent->>'title',
        v_consent->>'body',
        COALESCE((v_consent->>'requires_signature')::boolean, false)
      );
      v_n_consent := v_n_consent + 1;
    END IF;
  END LOOP;

  -- Comms templates: tenant_id + key + channel composite unique.
  FOR v_comms_tmpl IN SELECT * FROM jsonb_array_elements(COALESCE(v_seeds->'comms_templates', '[]'::jsonb)) LOOP
    IF NOT EXISTS (
      SELECT 1 FROM communication_templates
      WHERE tenant_id = p_tenant_id
        AND key       = v_comms_tmpl->>'key'
        AND channel   = v_comms_tmpl->>'channel'
    ) THEN
      INSERT INTO communication_templates (
        tenant_id, key, channel, subject, body, variables, cadence, is_enabled
      ) VALUES (
        p_tenant_id,
        v_comms_tmpl->>'key',
        v_comms_tmpl->>'channel',
        v_comms_tmpl->>'subject',
        v_comms_tmpl->>'body',
        COALESCE(v_comms_tmpl->'variables', '[]'::jsonb),
        v_comms_tmpl->>'cadence',
        true
      );
      v_n_comms := v_n_comms + 1;
    END IF;
  END LOOP;

  -- After-snapshot for audit.
  SELECT jsonb_build_object(
    'brand',        brand,
    'terminology',  terminology,
    'workflow',     workflow,
    'compliance',   compliance,
    'features',     features
  ) INTO v_tenant_after
  FROM tenants WHERE id = p_tenant_id;

  v_counts := jsonb_build_object(
    'categories',     v_n_cat,
    'product_types',  v_n_pt,
    'protocols',      v_n_proto,
    'regions',        v_n_region,
    'consents',       v_n_consent,
    'comms_templates',v_n_comms
  );

  v_applied := jsonb_build_object(
    'template_id',  v_template.id,
    'template_key', v_template.key,
    'template_name',v_template.name,
    'layers_applied', jsonb_object_keys(v_layers),
    'seed_counts',    v_counts
  );

  -- Audit trail (Phase 10 structured columns).
  BEGIN
    INSERT INTO audit_logs (
      action, change_type, actor_id, target_id, tenant_id,
      before_snapshot, after_snapshot, details
    ) VALUES (
      'tenant.template_applied',
      'template_apply',
      v_caller,
      p_tenant_id,
      p_tenant_id,
      v_tenant_before,
      v_tenant_after,
      jsonb_build_object('template', v_applied)::text
    );
  EXCEPTION WHEN OTHERS THEN
    -- Audit failures don't block the apply — it's already written.
    NULL;
  END;

  RETURN jsonb_build_object(
    'ok',         true,
    'template',   v_applied,
    'before',     v_tenant_before,
    'after',      v_tenant_after,
    'seed_counts',v_counts
  );
END;
$$;

-- Grant execute to authenticated; the function self-gates by caller.
GRANT EXECUTE ON FUNCTION public.apply_tenant_template(uuid, uuid) TO authenticated;

-- ── Verify ────────────────────────────────────────────────────────────
SELECT
  (SELECT count(*) FROM tenant_templates WHERE NOT is_archived)     AS total_templates,
  (SELECT count(*) FROM pg_proc WHERE proname = 'apply_tenant_template') AS rpc_installed;

-- ═══════════════════════════════════════════════════════════════════════════
-- ROLLBACK
-- ═══════════════════════════════════════════════════════════════════════════
--
-- DROP FUNCTION IF EXISTS public.apply_tenant_template(uuid, uuid);
-- DELETE FROM tenant_templates WHERE key IN ('peptide_therapy','weight_loss','hormone_therapy');
