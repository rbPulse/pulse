-- ═══════════════════════════════════════════════════════════════════════════
-- Pulse — Setup Wizard: per-message cadence/threshold persistence
-- ═══════════════════════════════════════════════════════════════════════════
--
-- WHAT THIS DOES
--   Fixes two latent issues with migration 026 and extends the
--   apply_wizard_answers RPC to actually persist per-message settings
--   (tone template body, cadence, threshold) into platform_automations
--   — the table the runtime reads from when firing auto-messages.
--
-- ISSUE 1 — platform_automations had UNIQUE(key) from migration 008
--   even after migration 011 added a tenant_id column. That prevented
--   multiple tenants from owning their own automation configs. We
--   replace the constraint with UNIQUE(tenant_id, key) so each tenant
--   can customize independently.
--
-- ISSUE 2 — migration 026's RPC inserted into communication_templates
--   with channel='portal', which fails the channel CHECK constraint
--   (only 'email','sms','push' allowed). More importantly the runtime
--   (t/pulse/portal/index.html _checkInactivityNudge et al) reads
--   bodies + config from platform_automations.config — NOT from
--   communication_templates. Wizard writes now land in the correct
--   table via upsert.
--
-- ISSUE 3 — wizard automation keys didn't always match the canonical
--   platform_automations keys the runtime looks up. We map them
--   explicitly (welcome → welcome_message, order_confirmation →
--   purchase_confirmation, refill_reminder → low_supply_alert). Two
--   wizard concepts without existing platform automations
--   (check_in_reminder, follow_up) get seeded as new keys.
--
-- ISSUE 4 — per-message cadence + threshold set in the wizard editor
--   had nowhere to land. They now merge into config.cadence /
--   config.days_inactive so the runtime picks them up.
--
-- USAGE
--   Paste into Supabase SQL editor and run. Idempotent.
--
-- ═══════════════════════════════════════════════════════════════════════════

-- ── 1. Schema: allow per-tenant automation configs ──────────────────
-- Drop the original UNIQUE(key) (may be named platform_automations_key_key)
-- and establish UNIQUE(tenant_id, key) in its place. Only works once
-- migration 011 has added tenant_id.

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
     WHERE table_schema = 'public' AND table_name = 'platform_automations' AND column_name = 'tenant_id'
  ) THEN
    -- Drop any single-column unique constraint on key.
    IF EXISTS (
      SELECT 1 FROM information_schema.table_constraints
       WHERE table_schema = 'public' AND table_name = 'platform_automations'
         AND constraint_name = 'platform_automations_key_key'
    ) THEN
      ALTER TABLE public.platform_automations DROP CONSTRAINT platform_automations_key_key;
    END IF;

    -- Add the composite unique if missing.
    IF NOT EXISTS (
      SELECT 1 FROM pg_indexes
       WHERE schemaname = 'public' AND tablename = 'platform_automations'
         AND indexname = 'platform_automations_tenant_key_uq'
    ) THEN
      ALTER TABLE public.platform_automations
        ADD CONSTRAINT platform_automations_tenant_key_uq UNIQUE (tenant_id, key);
    END IF;
  END IF;
END $$;

-- ── 2. Seed new automation rows for wizard concepts ─────────────────
-- check_in_reminder and follow_up don't exist in migration 008's
-- original seed. Add them as global/Pulse-defaulted rows so the
-- wizard has a canonical key to upsert into.

INSERT INTO public.platform_automations (tenant_id, key, label, portal, category, description, enabled, config)
SELECT id, 'check_in_reminder', 'Check-in Reminder', 'member', 'Engagement',
       'Prompts members to complete scheduled clinical check-ins (weight, symptoms, mood).',
       true,
       '{"cadence":"monthly","template":"Time for your check-in. Takes 2 minutes — helps your care team keep everything dialed in."}'::jsonb
  FROM public.tenants
 WHERE NOT EXISTS (
   SELECT 1 FROM public.platform_automations pa
    WHERE pa.tenant_id = tenants.id AND pa.key = 'check_in_reminder'
 );

INSERT INTO public.platform_automations (tenant_id, key, label, portal, category, description, enabled, config)
SELECT id, 'follow_up', 'Follow-up Outreach', 'member', 'Engagement',
       'Post-protocol outreach on your follow-up cadence.',
       true,
       '{"cadence":"monthly","template":"Your care team would love an update on how your protocol is landing."}'::jsonb
  FROM public.tenants
 WHERE NOT EXISTS (
   SELECT 1 FROM public.platform_automations pa
    WHERE pa.tenant_id = tenants.id AND pa.key = 'follow_up'
 );

-- ── 3. apply_wizard_answers v2 ──────────────────────────────────────
-- Replaces migration 026's version. Now maps wizard automation keys
-- to canonical platform_automations keys and upserts config into
-- platform_automations (tenant_id, key). The runtime (_checkInactivityNudge
-- et al in the portal) already reads from platform_automations via
-- _getAutomationConfig, so changes take effect on the next portal
-- load without additional wiring.

CREATE OR REPLACE FUNCTION public.apply_wizard_answers(
  p_tenant_id uuid,
  p_answers   jsonb
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
  v_tenant_before   jsonb;
  v_tenant_after    jsonb;
  v_brand           jsonb := '{}'::jsonb;
  v_terminology     jsonb := '{}'::jsonb;
  v_workflow        jsonb := '{}'::jsonb;
  v_features        jsonb := '{}'::jsonb;
  v_ct              text;
  v_tone            text;
  v_state           text;
  v_auto_key        text;
  v_is_on           boolean;
  v_body            text;
  v_custom          text;
  v_cadence         text;
  v_threshold       int;
  v_canonical       text;
  v_existing_config jsonb;
  v_new_config      jsonb;
  v_n_regions       int := 0;
  v_n_automations   int := 0;
  v_rows            int := 0;

  -- Wizard key → canonical platform_automations key. Anything not in
  -- this map falls through to its own name (check_in_reminder, follow_up
  -- are seeded in section 2 above).
  v_key_map constant jsonb := jsonb_build_object(
    'welcome',            'welcome_message',
    'order_confirmation', 'purchase_confirmation',
    'refill_reminder',    'low_supply_alert',
    'inactivity_nudge',   'inactivity_nudge',
    'check_in_reminder',  'check_in_reminder',
    'follow_up',          'follow_up'
  );
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
    RAISE EXCEPTION 'not authorized to apply wizard answers for this tenant';
  END IF;

  SELECT jsonb_build_object(
    'brand',       brand,
    'terminology', terminology,
    'workflow',    workflow,
    'features',    features
  ) INTO v_tenant_before
  FROM tenants WHERE id = p_tenant_id;

  -- ── Terminology layer ──────────────────────────────────────────────
  IF p_answers ? 'language' THEN
    IF (p_answers->'language'->>'memberTerm') IS NOT NULL AND length(p_answers->'language'->>'memberTerm') > 0 THEN
      v_terminology := v_terminology || jsonb_build_object(
        'member',  p_answers->'language'->>'memberTerm',
        'members', p_answers->'language'->>'memberTerm' || 's'
      );
    END IF;
    IF (p_answers->'language'->>'clinicianTerm') IS NOT NULL AND length(p_answers->'language'->>'clinicianTerm') > 0 THEN
      v_terminology := v_terminology || jsonb_build_object(
        'clinician',  p_answers->'language'->>'clinicianTerm',
        'clinicians', p_answers->'language'->>'clinicianTerm' || 's'
      );
    END IF;
    IF (p_answers->'language'->>'protocolTerm') IS NOT NULL AND length(p_answers->'language'->>'protocolTerm') > 0 THEN
      v_terminology := v_terminology || jsonb_build_object(
        'protocol',  p_answers->'language'->>'protocolTerm',
        'protocols', p_answers->'language'->>'protocolTerm' || 's'
      );
    END IF;
  END IF;

  -- ── Workflow layer ─────────────────────────────────────────────────
  IF p_answers ? 'workflow' THEN
    IF (p_answers->'workflow'->>'consultPolicy') IS NOT NULL THEN
      v_workflow := v_workflow || jsonb_build_object(
        'consult', jsonb_build_object(
          'policy', CASE p_answers->'workflow'->>'consultPolicy'
            WHEN 'sync'   THEN 'synchronous_for_first_rx'
            WHEN 'either' THEN 'either'
            ELSE 'required_for_first_rx'
          END,
          'allow_async_review', (p_answers->'workflow'->>'consultPolicy') <> 'sync'
        )
      );
    END IF;
    IF (p_answers->'workflow'->>'refillDays') IS NOT NULL THEN
      v_workflow := v_workflow || jsonb_build_object(
        'refill', jsonb_build_object(
          'eligibility_days_before_runout', (p_answers->'workflow'->>'refillDays')::int,
          'clinician_review_required', true
        )
      );
    END IF;
    IF (p_answers->'workflow'->>'intakeRequired') IS NOT NULL THEN
      v_workflow := v_workflow || jsonb_build_object(
        'intake', jsonb_build_object('required', (p_answers->'workflow'->>'intakeRequired')::boolean)
      );
    END IF;
    IF (p_answers->'workflow'->>'followUpDays') IS NOT NULL THEN
      v_workflow := v_workflow || jsonb_build_object(
        'follow_up', jsonb_build_object('cadence_days', (p_answers->'workflow'->>'followUpDays')::int)
      );
    END IF;
  END IF;

  -- ── Brand layer ────────────────────────────────────────────────────
  IF p_answers ? 'brand' THEN
    IF (p_answers->'brand'->>'wordmark')           IS NOT NULL THEN v_brand := v_brand || jsonb_build_object('wordmark',           p_answers->'brand'->>'wordmark');           END IF;
    IF (p_answers->'brand'->>'wordmarkImageUrl')   IS NOT NULL THEN v_brand := v_brand || jsonb_build_object('wordmark_image_url', p_answers->'brand'->>'wordmarkImageUrl'); END IF;
    IF (p_answers->'brand'->>'logoUrl')            IS NOT NULL THEN v_brand := v_brand || jsonb_build_object('logo_url',           p_answers->'brand'->>'logoUrl');            END IF;
    IF (p_answers->'brand'->>'accentColor')        IS NOT NULL THEN v_brand := v_brand || jsonb_build_object('accent_color',       upper(p_answers->'brand'->>'accentColor')); END IF;
    IF (p_answers->'brand'->>'supportEmail')       IS NOT NULL THEN v_brand := v_brand || jsonb_build_object('support_email',      p_answers->'brand'->>'supportEmail');       END IF;
    IF (p_answers->'brand'->>'supportPhone')       IS NOT NULL THEN v_brand := v_brand || jsonb_build_object('support_phone',      p_answers->'brand'->>'supportPhone');       END IF;
  END IF;

  -- ── Features layer ─────────────────────────────────────────────────
  v_ct := p_answers->>'clinicType';
  IF v_ct IS NOT NULL THEN
    v_features := v_features ||
      CASE v_ct
        WHEN 'peptide_therapy' THEN jsonb_build_object('telehealth_sessions', true, 'dose_logging', true,  'check_in_schedule', true)
        WHEN 'weight_loss'     THEN jsonb_build_object('weight_tracking',     true, 'side_effect_logging', true, 'dose_escalation', true)
        WHEN 'hormone_therapy' THEN jsonb_build_object('lab_tracking',        true, 'synchronous_visits', true, 'check_in_schedule', true)
        WHEN 'wellness'        THEN jsonb_build_object('dose_logging',        true, 'check_in_schedule', true)
        ELSE '{}'::jsonb
      END;
  END IF;

  UPDATE tenants SET
    brand       = COALESCE(brand,       '{}'::jsonb) || v_brand,
    terminology = COALESCE(terminology, '{}'::jsonb) || v_terminology,
    workflow    = COALESCE(workflow,    '{}'::jsonb) || v_workflow,
    features    = COALESCE(features,    '{}'::jsonb) || v_features
  WHERE id = p_tenant_id;

  -- ── Territory ──────────────────────────────────────────────────────
  IF p_answers ? 'territory' AND jsonb_typeof(p_answers->'territory'->'states') = 'array' THEN
    FOR v_state IN SELECT jsonb_array_elements_text(p_answers->'territory'->'states') LOOP
      IF NOT EXISTS (SELECT 1 FROM tenant_regions WHERE tenant_id = p_tenant_id AND state = v_state) THEN
        INSERT INTO tenant_regions (tenant_id, state, is_allowed) VALUES (p_tenant_id, v_state, true);
        v_n_regions := v_n_regions + 1;
      ELSE
        UPDATE tenant_regions SET is_allowed = true
         WHERE tenant_id = p_tenant_id AND state = v_state AND is_allowed IS DISTINCT FROM true;
      END IF;
    END LOOP;
    UPDATE tenant_regions SET is_allowed = false
     WHERE tenant_id = p_tenant_id
       AND state NOT IN (SELECT jsonb_array_elements_text(p_answers->'territory'->'states'))
       AND is_allowed = true;
  END IF;

  -- ── Automations: upsert platform_automations rows ──────────────────
  v_tone := COALESCE(p_answers->'comms'->>'tone', 'professional');
  IF p_answers ? 'comms' AND jsonb_typeof(p_answers->'comms'->'enabled') = 'object' THEN
    FOR v_auto_key IN SELECT jsonb_object_keys(p_answers->'comms'->'enabled') LOOP
      v_is_on := COALESCE((p_answers->'comms'->'enabled'->>v_auto_key)::boolean, true);

      -- Resolve template body: custom override wins over tone default.
      v_custom := p_answers->'comms'->'customTemplates'->>v_auto_key;
      IF v_custom IS NOT NULL AND length(v_custom) > 0 THEN
        v_body := v_custom;
      ELSE
        SELECT template INTO v_body
          FROM comms_tone_templates
         WHERE automation_key = v_auto_key AND tone = v_tone
         LIMIT 1;
      END IF;

      -- Per-message overrides (cadence, threshold days).
      v_cadence   := p_answers->'comms'->'perMessage'->v_auto_key->>'cadence';
      v_threshold := NULLIF(p_answers->'comms'->'perMessage'->v_auto_key->>'thresholdDays', '')::int;

      -- Canonical key: map wizard key to the platform_automations key
      -- the runtime actually reads. Falls back to wizard key unchanged.
      v_canonical := COALESCE(v_key_map->>v_auto_key, v_auto_key);

      -- Fetch existing config so we merge rather than overwrite.
      SELECT config INTO v_existing_config
        FROM platform_automations
       WHERE tenant_id = p_tenant_id AND key = v_canonical
       LIMIT 1;
      v_existing_config := COALESCE(v_existing_config, '{}'::jsonb);

      -- Build the new config from the wizard answers. Only keys that
      -- changed get overwritten; everything else in the existing
      -- config stays.
      v_new_config := v_existing_config;
      IF v_body IS NOT NULL THEN
        v_new_config := v_new_config || jsonb_build_object('template', v_body);
      END IF;
      IF v_cadence IS NOT NULL THEN
        v_new_config := v_new_config || jsonb_build_object('cadence', v_cadence);
      END IF;
      IF v_threshold IS NOT NULL THEN
        -- Canonical key for runtime lookup is days_inactive (inactivity_nudge).
        v_new_config := v_new_config || jsonb_build_object('days_inactive', v_threshold);
      END IF;

      IF EXISTS (
        SELECT 1 FROM platform_automations
         WHERE tenant_id = p_tenant_id AND key = v_canonical
      ) THEN
        UPDATE platform_automations
           SET enabled = v_is_on,
               config  = v_new_config,
               updated_at = now()
         WHERE tenant_id = p_tenant_id AND key = v_canonical;
        GET DIAGNOSTICS v_rows = ROW_COUNT;
        v_n_automations := v_n_automations + v_rows;
      ELSE
        INSERT INTO platform_automations (tenant_id, key, label, portal, category, description, enabled, config)
        VALUES (p_tenant_id, v_canonical,
                INITCAP(REPLACE(v_canonical, '_', ' ')),
                'member', 'Engagement',
                'Auto-generated from the Setup wizard.',
                v_is_on, v_new_config);
        v_n_automations := v_n_automations + 1;
      END IF;
    END LOOP;
  END IF;

  SELECT jsonb_build_object(
    'brand',       brand,
    'terminology', terminology,
    'workflow',    workflow,
    'features',    features
  ) INTO v_tenant_after
  FROM tenants WHERE id = p_tenant_id;

  BEGIN
    INSERT INTO audit_logs (action, change_type, actor_id, target_id, tenant_id,
      before_snapshot, after_snapshot, details)
    VALUES ('tenant.wizard_applied', 'wizard_apply', v_caller, p_tenant_id, p_tenant_id,
      v_tenant_before, v_tenant_after,
      jsonb_build_object('answers', p_answers, 'counts',
        jsonb_build_object('regions_inserted', v_n_regions, 'automations_upserted', v_n_automations))::text);
  EXCEPTION WHEN OTHERS THEN NULL;
  END;

  RETURN jsonb_build_object(
    'ok',     true,
    'before', v_tenant_before,
    'after',  v_tenant_after,
    'counts', jsonb_build_object(
      'regions_inserted',     v_n_regions,
      'automations_upserted', v_n_automations
    )
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.apply_wizard_answers(uuid, jsonb) TO authenticated;

-- ── Verify ────────────────────────────────────────────────────────────
SELECT
  (SELECT count(*) FROM pg_constraint
    WHERE conname = 'platform_automations_tenant_key_uq')            AS composite_unique_in_place,
  (SELECT count(*) FROM public.platform_automations
    WHERE key IN ('check_in_reminder','follow_up'))                   AS new_keys_seeded,
  (SELECT count(*) FROM pg_proc
    WHERE proname = 'apply_wizard_answers')                           AS rpc_installed;

-- ═══════════════════════════════════════════════════════════════════════════
-- ROLLBACK
-- ═══════════════════════════════════════════════════════════════════════════
-- -- Restore the rpc shape from migration 026 if needed, then:
-- ALTER TABLE public.platform_automations DROP CONSTRAINT IF EXISTS platform_automations_tenant_key_uq;
-- -- Re-add the original UNIQUE(key) if rolling back past migration 011 as well:
-- -- ALTER TABLE public.platform_automations ADD CONSTRAINT platform_automations_key_key UNIQUE (key);
-- DELETE FROM public.platform_automations WHERE key IN ('check_in_reminder','follow_up');
