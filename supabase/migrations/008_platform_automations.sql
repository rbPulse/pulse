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

-- Seed all known automations with defaults
INSERT INTO platform_automations (key, label, portal, category, description, enabled, config)
VALUES
  -- Member Portal > Onboarding
  ('welcome_message',       'Welcome Message',           'member',    'Onboarding',     'Auto-sends personalized clinician message on first portal load after prescription',  true, '{"template":"Welcome to Pulse, {firstName}. I''m glad to have you on board."}'),
  ('auto_schedule_checkins','Auto-Schedule Check-ins',    'member',    'Onboarding',     'Creates monthly check-in appointments based on protocol duration',                   true, '{"duration_minutes":20,"frequency":"monthly"}'),

  -- Member Portal > Engagement
  ('wellness_prompts',      'Wellness Check-in Prompts',  'member',    'Engagement',     'Weekly rotating prompt on Overview tab, one per week per member',                    true, '{"cadence":"weekly","prompt_count":10}'),
  ('checkin_routing',        'Check-in Response Routing', 'member',    'Engagement',     'Auto-sends member check-in responses to clinician as a message',                     true, '{}'),
  ('low_supply_alert',       'Low Supply Alert',          'member',    'Engagement',     'Flags protocol as low-supply and shows refill button',                               true, '{"threshold_days":14}'),

  -- Member Portal > Requests
  ('protocol_request_routing','Protocol Request Routing', 'member',    'Requests',       'Member protocol request creates consultation + message + notification to clinician', true, '{"auto_notify":true,"auto_message":true}'),
  ('refill_request_routing',  'Refill Request Routing',   'member',    'Requests',       'Member refill request creates consultation + message + notification to clinician',   true, '{"auto_notify":true,"auto_message":true}'),

  -- Clinician Portal > Intake Pipeline
  ('auto_assign_clinician',  'Auto-Assign Clinician',     'clinician', 'Intake Pipeline','Assigns new intakes to clinician with lowest pending review count',                  true, '{"mode":"lowest_load","state_filter":true}'),
  ('risk_evaluation',        'Risk Scoring',              'clinician', 'Intake Pipeline','Scores medical history into low/moderate/high risk tiers',                            true, '{"high_threshold":4,"moderate_threshold":2}'),
  ('overdue_flag',           'Overdue Review Flag',        'clinician', 'Intake Pipeline','Flags consultations as overdue and pins to top of attention queue',                  true, '{"threshold_hours":24}'),

  -- Clinician Portal > Communication
  ('new_message_notify',     'New Message → Member',       'clinician', 'Communication', 'Notifies member when clinician sends a message',                                     true, '{}'),
  ('rx_change_notify',       'Rx Change → Member',         'clinician', 'Communication', 'Notifies member when clinician prescribes, adjusts, or discontinues',                true, '{}'),

  -- Clinician Portal > Scheduling
  ('appointment_alerts',     'Appointment Alerts',         'clinician', 'Scheduling',    'Notifies both parties on appointment confirmation or cancellation',                  true, '{}'),
  ('session_auto_close',     'Session Auto-Close',         'clinician', 'Scheduling',    'Updates review status automatically when live consult session ends',                  true, '{}')
ON CONFLICT (key) DO NOTHING;

-- Verify
SELECT key, label, portal, category, enabled FROM platform_automations ORDER BY portal, category, label;
