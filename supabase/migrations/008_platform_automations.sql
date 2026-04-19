-- ═══════════════════════════════════════════════════════════════════════════
-- Pulse — Phase 8 migration: platform_automations
-- ═══════════════════════════════════════════════════════════════════════════
--
-- WHAT THIS DOES
--   Creates a key-value table for toggling and configuring every
--   automated behavior in the platform. Each row is one automation
--   with an enabled flag and a JSONB config blob for its settings.
--   The admin portal reads/writes this table from the Automations tab.
--
-- USAGE
--   Paste into Supabase SQL editor and run. Idempotent.
--
-- ROLLBACK
--   DROP TABLE platform_automations;
--
-- ═══════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS platform_automations (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  key         text        NOT NULL UNIQUE,
  label       text        NOT NULL,
  portal      text        NOT NULL,
  category    text        NOT NULL,
  description text,
  enabled     boolean     NOT NULL DEFAULT true,
  config      jsonb       DEFAULT '{}',
  updated_at  timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE platform_automations ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "read automations" ON platform_automations;
CREATE POLICY "read automations"
  ON platform_automations FOR SELECT
  TO authenticated
  USING (true);

DROP POLICY IF EXISTS "admin write automations" ON platform_automations;
CREATE POLICY "admin write automations"
  ON platform_automations FOR ALL
  TO authenticated
  USING      (EXISTS (SELECT 1 FROM profiles WHERE user_id = auth.uid() AND role = 'admin'))
  WITH CHECK (EXISTS (SELECT 1 FROM profiles WHERE user_id = auth.uid() AND role = 'admin'));

-- Seed all known automations with defaults. Uses ON CONFLICT so
-- re-running updates labels/descriptions without touching config
-- or enabled state.
INSERT INTO platform_automations (key, label, portal, category, description, enabled, config)
VALUES
  -- Member Portal > Onboarding
  ('welcome_message',        'Welcome Message',           'member',    'Onboarding',     'Sends a personalized message from the assigned clinician when a member first opens the portal after being prescribed', true, '{"template":"Welcome to Pulse, {firstName}. I''m glad to have you on board."}'),
  ('auto_schedule_checkins', 'Auto-Schedule Check-ins',    'member',    'Onboarding',     'Creates recurring check-in appointments based on protocol duration', true, '{"duration_minutes":20,"frequency":"monthly"}'),
  ('purchase_confirmation',  'Purchase Confirmation',      'member',    'Onboarding',     'Sends a confirmation message to the member after completing checkout', true, '{"template":"Your order is confirmed. Your clinician will follow up shortly."}'),
  -- Member Portal > Engagement
  ('wellness_prompts',       'Wellness Check-in Prompts',  'member',    'Engagement',     'Shows a rotating prompt on the Overview tab to gather member wellness data', true, '{"cadence":"weekly","prompt_count":10}'),
  ('checkin_routing',        'Check-in → Clinician',       'member',    'Engagement',     'Routes member check-in responses to the assigned clinician as a message', true, '{}'),
  ('low_supply_alert',       'Low Supply Alert',           'member',    'Engagement',     'Shows a refill prompt when product supply drops below threshold', true, '{"threshold_days":14}'),
  ('inactivity_nudge',       'Inactivity Nudge',           'member',    'Engagement',     'Sends a message if a member hasn''t logged activity in a set number of days', true, '{"days_inactive":7}'),
  ('protocol_completion',    'Protocol Completion',        'member',    'Engagement',     'Prompts member for next steps when their protocol duration ends', true, '{}'),
  -- Member Portal > Requests
  ('protocol_request_routing','Protocol Requests',         'member',    'Requests',       'Routes new protocol requests to the clinician with a message and notification', true, '{"auto_notify":true,"auto_message":true}'),
  ('refill_request_routing', 'Refill Requests',            'member',    'Requests',       'Routes refill requests to the clinician with supply details and any medical updates', true, '{"auto_notify":true,"auto_message":true}'),
  -- Clinician Portal > Intake Pipeline
  ('auto_assign_clinician',  'Auto-Assign Clinician',      'clinician', 'Intake Pipeline','Assigns new intakes to the clinician with the lowest open review count', true, '{"mode":"lowest_load","state_filter":true}'),
  ('risk_evaluation',        'Risk Scoring',               'clinician', 'Intake Pipeline','Evaluates medical history and assigns a risk tier (low, moderate, high)', true, '{"high_threshold":4,"moderate_threshold":2}'),
  ('overdue_flag',           'Overdue Review Flag',         'clinician', 'Intake Pipeline','Flags pending intakes as overdue after a set time with no clinician action', true, '{"threshold_hours":24}'),
  ('high_risk_admin_alert',  'High-Risk → Admin Alert',    'clinician', 'Intake Pipeline','Escalates high-risk intakes to the admin team in addition to the assigned clinician', true, '{}'),
  -- Clinician Portal > Notifications
  ('rx_approved_notify',     'Approved → Member',          'clinician', 'Notifications',  'Notifies the member when the clinician approves and prescribes a product', true, '{"template":"{clinicianName} has approved your {protocolName} plan."}'),
  ('rx_adjusted_notify',     'Adjusted → Member',          'clinician', 'Notifications',  'Notifies the member when the clinician adjusts dose, frequency, or timing', true, '{"template":"Your {protocolName} plan has been updated by {clinicianName}."}'),
  ('rx_discontinued_notify', 'Discontinued → Member',      'clinician', 'Notifications',  'Notifies the member when the clinician discontinues a product', true, '{"template":"Your {protocolName} plan has been discontinued. Reach out with questions."}'),
  -- Clinician Portal > Scheduling
  ('appointment_reminder',   'Appointment Reminder',       'clinician', 'Scheduling',     'Sends a reminder to the member before a scheduled appointment', true, '{"hours_before":24}')
ON CONFLICT (key) DO UPDATE SET
  label       = EXCLUDED.label,
  portal      = EXCLUDED.portal,
  category    = EXCLUDED.category,
  description = EXCLUDED.description;

-- Clean up old automation keys that were removed
DELETE FROM platform_automations WHERE key IN ('new_message_notify','rx_change_notify','appointment_alerts','session_auto_close');

-- Verify
SELECT key, label, portal, category, enabled FROM platform_automations ORDER BY portal, category, label;
