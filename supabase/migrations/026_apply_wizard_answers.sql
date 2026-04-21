-- ═══════════════════════════════════════════════════════════════════════════
-- Pulse — Setup Wizard: apply_wizard_answers RPC + tone template seeds
-- ═══════════════════════════════════════════════════════════════════════════
--
-- WHAT THIS DOES
--   Replaces the template-picker path (migration 025's
--   apply_tenant_template) with a direct answer-bundle applier. The
--   Setup wizard produces a JSON answer bundle; this RPC translates
--   those answers into tenants.* JSONB merges and seed-row inserts.
--
--   The answer bundle shape is documented inline in the function body.
--   Schema drift in the wizard UI extends the bundle; this function
--   ignores unknown keys so older bundles keep applying cleanly.
--
--   Tone templates (warm / professional / clinical / direct) for each
--   automation key are seeded into a new `comms_tone_templates` lookup
--   table. When the wizard enables an automation with a specific tone,
--   the RPC upserts the corresponding tone row into the tenant's
--   platform_automations so per-member auto-messages use the matching
--   copy.
--
--   Deprecates: the peptide_therapy / weight_loss / hormone_therapy
--   rows seeded by migration 025 are archived (is_archived = true) so
--   the wizard is the only path forward. Blank + Wellness stay so the
--   tenant_templates infrastructure isn't wasted — admins or platform
--   operators can still seed a tenant from a raw config_snapshot via
--   the old path when they want to.
--
-- USAGE
--   Paste into Supabase SQL editor and run. Idempotent.
--
-- ═══════════════════════════════════════════════════════════════════════════

-- ── comms_tone_templates lookup ──────────────────────────────────────
-- Rows are (automation_key, tone, template) triples — one template
-- string per (automation, tone) combination. Every wizard-enabled
-- automation resolves to one of these at apply time.

CREATE TABLE IF NOT EXISTS public.comms_tone_templates (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  automation_key  text        NOT NULL,
  tone            text        NOT NULL,
  template        text        NOT NULL,
  created_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (automation_key, tone)
);

-- Read-only for every authenticated user; only platform users can
-- write tones (templates are platform-curated).
ALTER TABLE public.comms_tone_templates ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "tone_templates_read" ON public.comms_tone_templates;
CREATE POLICY "tone_templates_read" ON public.comms_tone_templates
  FOR SELECT TO authenticated USING (true);
DROP POLICY IF EXISTS "tone_templates_platform_write" ON public.comms_tone_templates;
CREATE POLICY "tone_templates_platform_write" ON public.comms_tone_templates
  FOR ALL TO authenticated
  USING (public.is_platform_user())
  WITH CHECK (public.is_platform_user());

-- Seed: 6 automations × 4 tones = 24 templates.
INSERT INTO public.comms_tone_templates (automation_key, tone, template) VALUES
  -- Welcome
  ('welcome','warm',         'Hi {firstName} — glad you''re here. I''ve scheduled check-ins ({checkInDates}) so we can track how you''re doing together.'),
  ('welcome','professional', 'Welcome to {clinicName}, {firstName}. Your care team is ready. Scheduled check-ins: {checkInDates}.'),
  ('welcome','clinical',     '{firstName}: your intake is complete. Clinician review within 24h. Follow-up check-ins scheduled: {checkInDates}.'),
  ('welcome','direct',       '{firstName}, you''re in. Check-ins: {checkInDates}. Message us anytime.'),
  -- Order confirmation
  ('order_confirmation','warm',         'Your order is confirmed — your clinician will follow up shortly to walk through next steps.'),
  ('order_confirmation','professional', 'Order confirmed. Your clinician will follow up with next steps within 24 hours.'),
  ('order_confirmation','clinical',     'Order received. Clinical review in progress. Expect clinician outreach within 24h.'),
  ('order_confirmation','direct',       'Order in. Clinician reply incoming.'),
  -- Refill reminder
  ('refill_reminder','warm',         'Heads up, {firstName} — your current supply is running low. Tap here to request a refill whenever you''re ready.'),
  ('refill_reminder','professional', '{firstName}, your protocol is approaching run-out. Request a refill at your convenience.'),
  ('refill_reminder','clinical',     '{firstName}: refill eligibility active. Request refill to continue current protocol.'),
  ('refill_reminder','direct',       'Refill time, {firstName}. Tap to reorder.'),
  -- Inactivity nudge
  ('inactivity_nudge','warm',         'Hey {firstName} — just checking in. Your care team is here if anything''s come up. No pressure, just a quick hello.'),
  ('inactivity_nudge','professional', '{firstName}, we haven''t seen recent activity. Your care team is available if you have questions or need support.'),
  ('inactivity_nudge','clinical',     '{firstName}: no recent dose logs detected. Reach out if protocol adjustment is needed.'),
  ('inactivity_nudge','direct',       '{firstName} — you okay? Reply if you need us.'),
  -- Check-in reminder
  ('check_in_reminder','warm',         'Time for your check-in, {firstName}. Takes 2 minutes — helps your care team keep everything dialed in.'),
  ('check_in_reminder','professional', '{firstName}, your scheduled check-in is due. Please complete it in the portal when convenient.'),
  ('check_in_reminder','clinical',     '{firstName}: check-in due. Complete to support clinical monitoring.'),
  ('check_in_reminder','direct',       'Check-in time, {firstName}. 2 min.'),
  -- Follow-up
  ('follow_up','warm',         'How''s it going, {firstName}? Your care team would love an update on how your protocol is landing.'),
  ('follow_up','professional', '{firstName}, we''d like to check in on your progress. Please share any updates when you can.'),
  ('follow_up','clinical',     '{firstName}: scheduled follow-up. Response supports protocol evaluation.'),
  ('follow_up','direct',       'Progress update, {firstName}? Quick reply works.')
ON CONFLICT (automation_key, tone) DO UPDATE SET template = EXCLUDED.template;


-- ── apply_wizard_answers RPC ─────────────────────────────────────────
-- Input: jsonb answer bundle matching the shape the wizard persists.
-- Output: jsonb { ok, before, after, applied } — consumed by the
-- wizard success screen.

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
  v_layers          jsonb := '{}'::jsonb;
  v_brand           jsonb := '{}'::jsonb;
  v_terminology     jsonb := '{}'::jsonb;
  v_workflow        jsonb := '{}'::jsonb;
  v_features        jsonb := '{}'::jsonb;
  v_ct              text;
  v_tone            text;
  v_state           text;
  v_auto            record;
  v_n_regions       int := 0;
  v_n_comms         int := 0;
  v_rows            int := 0;
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

  -- Snapshot before for audit.
  SELECT jsonb_build_object(
    'brand',        brand,
    'terminology',  terminology,
    'workflow',     workflow,
    'features',     features
  ) INTO v_tenant_before
  FROM tenants WHERE id = p_tenant_id;

  -- ── Terminology layer ──────────────────────────────────────────────
  IF p_answers ? 'language' THEN
    -- Each of the three nouns: write singular + plural. Plural is
    -- derived as singular+'s' unless the caller provided one.
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
    IF (p_answers->'brand'->>'wordmark')      IS NOT NULL THEN v_brand := v_brand || jsonb_build_object('wordmark',      p_answers->'brand'->>'wordmark');      END IF;
    IF (p_answers->'brand'->>'accentColor')   IS NOT NULL THEN v_brand := v_brand || jsonb_build_object('accent_color',  upper(p_answers->'brand'->>'accentColor')); END IF;
    IF (p_answers->'brand'->>'supportEmail')  IS NOT NULL THEN v_brand := v_brand || jsonb_build_object('support_email', p_answers->'brand'->>'supportEmail'); END IF;
    IF (p_answers->'brand'->>'supportPhone')  IS NOT NULL THEN v_brand := v_brand || jsonb_build_object('support_phone', p_answers->'brand'->>'supportPhone'); END IF;
  END IF;

  -- ── Features layer (clinic type → feature flags) ───────────────────
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

  -- ── Apply layer merges onto tenant row ─────────────────────────────
  UPDATE tenants SET
    brand       = COALESCE(brand,       '{}'::jsonb) || v_brand,
    terminology = COALESCE(terminology, '{}'::jsonb) || v_terminology,
    workflow    = COALESCE(workflow,    '{}'::jsonb) || v_workflow,
    features    = COALESCE(features,    '{}'::jsonb) || v_features
  WHERE id = p_tenant_id;

  -- ── Seed territories ───────────────────────────────────────────────
  IF p_answers ? 'territory' AND jsonb_typeof(p_answers->'territory'->'states') = 'array' THEN
    -- Insert any missing, flip existing to is_allowed=true
    FOR v_state IN SELECT jsonb_array_elements_text(p_answers->'territory'->'states') LOOP
      IF NOT EXISTS (SELECT 1 FROM tenant_regions WHERE tenant_id = p_tenant_id AND state = v_state) THEN
        INSERT INTO tenant_regions (tenant_id, state, is_allowed) VALUES (p_tenant_id, v_state, true);
        v_n_regions := v_n_regions + 1;
      ELSE
        UPDATE tenant_regions SET is_allowed = true
         WHERE tenant_id = p_tenant_id AND state = v_state AND is_allowed IS DISTINCT FROM true;
      END IF;
    END LOOP;
    -- States removed from the wizard's selection: mark is_allowed=false
    -- (keep the row for historical audit, just disable).
    UPDATE tenant_regions SET is_allowed = false
     WHERE tenant_id = p_tenant_id
       AND state NOT IN (
         SELECT jsonb_array_elements_text(p_answers->'territory'->'states')
       )
       AND is_allowed = true;
  END IF;

  -- ── Seed communication_templates from tone preset ──────────────────
  v_tone := COALESCE(p_answers->'comms'->>'tone', 'professional');
  IF p_answers ? 'comms' AND jsonb_typeof(p_answers->'comms'->'enabled') = 'object' THEN
    FOR v_auto IN
      SELECT k.key AS auto_key, (p_answers->'comms'->'enabled'->>k.key)::boolean AS is_on
        FROM jsonb_object_keys(p_answers->'comms'->'enabled') k(key)
    LOOP
      IF v_auto.is_on IS DISTINCT FROM true THEN CONTINUE; END IF;
      -- Upsert into communication_templates, body from tone lookup.
      IF NOT EXISTS (
        SELECT 1 FROM communication_templates
         WHERE tenant_id = p_tenant_id AND key = v_auto.auto_key AND channel = 'portal'
      ) THEN
        INSERT INTO communication_templates (tenant_id, key, channel, subject, body, is_enabled)
        SELECT p_tenant_id, v_auto.auto_key, 'portal', NULL, template, true
          FROM comms_tone_templates
         WHERE automation_key = v_auto.auto_key AND tone = v_tone
         LIMIT 1;
        GET DIAGNOSTICS v_rows = ROW_COUNT;
        v_n_comms := v_n_comms + v_rows;
      ELSE
        UPDATE communication_templates SET
          body = (SELECT template FROM comms_tone_templates WHERE automation_key = v_auto.auto_key AND tone = v_tone LIMIT 1),
          is_enabled = true
         WHERE tenant_id = p_tenant_id AND key = v_auto.auto_key AND channel = 'portal';
      END IF;
    END LOOP;
  END IF;

  -- ── After snapshot + audit ─────────────────────────────────────────
  SELECT jsonb_build_object(
    'brand',        brand,
    'terminology',  terminology,
    'workflow',     workflow,
    'features',     features
  ) INTO v_tenant_after
  FROM tenants WHERE id = p_tenant_id;

  BEGIN
    INSERT INTO audit_logs (action, change_type, actor_id, target_id, tenant_id,
      before_snapshot, after_snapshot, details)
    VALUES ('tenant.wizard_applied', 'wizard_apply', v_caller, p_tenant_id, p_tenant_id,
      v_tenant_before, v_tenant_after,
      jsonb_build_object('answers', p_answers, 'counts',
        jsonb_build_object('regions_inserted', v_n_regions, 'comms_templates_inserted', v_n_comms))::text);
  EXCEPTION WHEN OTHERS THEN NULL;
  END;

  RETURN jsonb_build_object(
    'ok',    true,
    'before', v_tenant_before,
    'after',  v_tenant_after,
    'counts', jsonb_build_object(
      'regions_inserted',         v_n_regions,
      'comms_templates_inserted', v_n_comms
    )
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.apply_wizard_answers(uuid, jsonb) TO authenticated;

-- ── Archive the verticalized template rows from migration 025 ────────
-- Wizard is the path forward; keep Blank + Wellness as optional bulk-
-- apply escape hatch for platform operators.
UPDATE tenant_templates
   SET is_archived = true
 WHERE key IN ('peptide_therapy','weight_loss','hormone_therapy');

-- ── Verify ────────────────────────────────────────────────────────────
SELECT
  (SELECT count(*) FROM pg_proc WHERE proname = 'apply_wizard_answers')            AS rpc_installed,
  (SELECT count(*) FROM comms_tone_templates)                                      AS tone_templates,
  (SELECT count(*) FROM tenant_templates WHERE NOT is_archived)                    AS active_templates;

-- ═══════════════════════════════════════════════════════════════════════════
-- ROLLBACK
-- ═══════════════════════════════════════════════════════════════════════════
-- DROP FUNCTION IF EXISTS public.apply_wizard_answers(uuid, jsonb);
-- UPDATE tenant_templates SET is_archived = false WHERE key IN ('peptide_therapy','weight_loss','hormone_therapy');
-- DROP TABLE IF EXISTS public.comms_tone_templates;
