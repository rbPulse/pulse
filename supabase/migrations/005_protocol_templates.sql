-- ═══════════════════════════════════════════════════════════════════════════
-- Pulse — Phase 5 migration: protocol templates & categories
-- ═══════════════════════════════════════════════════════════════════════════
--
-- WHAT THIS DOES
--   Creates two admin-managed tables that replace hardcoded protocol
--   and category lists in the application:
--
--     protocol_templates  — the library of named protocols clinicians
--                           prescribe and members select from
--     protocol_categories — the dropdown list on the member protocol
--                           request form
--
--   The admin portal reads/writes these directly via the Configure tab.
--   The member and clinician portals still read hardcoded lists today;
--   a later phase will migrate them to these tables.
--
-- USAGE
--   Paste into the Supabase SQL editor and run. Idempotent.
--
-- ROLLBACK
--   DROP TABLE protocol_templates;
--   DROP TABLE protocol_categories;
--
-- ═══════════════════════════════════════════════════════════════════════════

-- ─────────────────────────────────────────────────────────────────────────
-- protocol_templates
-- ─────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS protocol_templates (
  id             uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
  key            text         NOT NULL UNIQUE,       -- e.g. "sleep"
  name           text         NOT NULL,              -- e.g. "Sleep Protocol"
  category       text,                               -- e.g. "Longevity"
  compounds      jsonb        DEFAULT '[]',          -- array of strings
  note           text,                               -- clinical note / default timing
  cycle          text,                               -- e.g. "12 weeks"
  is_archived    boolean      NOT NULL DEFAULT false,
  created_by     uuid,
  created_at     timestamptz  NOT NULL DEFAULT now(),
  updated_at     timestamptz  NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS protocol_templates_active
  ON protocol_templates (key)
  WHERE is_archived = false;

ALTER TABLE protocol_templates ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "read protocol templates" ON protocol_templates;
CREATE POLICY "read protocol templates"
  ON protocol_templates FOR SELECT
  TO authenticated
  USING (true);

DROP POLICY IF EXISTS "admin write protocol templates" ON protocol_templates;
CREATE POLICY "admin write protocol templates"
  ON protocol_templates FOR ALL
  TO authenticated
  USING      (EXISTS (SELECT 1 FROM profiles WHERE user_id = auth.uid() AND role = 'admin'))
  WITH CHECK (EXISTS (SELECT 1 FROM profiles WHERE user_id = auth.uid() AND role = 'admin'));


-- ─────────────────────────────────────────────────────────────────────────
-- protocol_categories
-- ─────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS protocol_categories (
  id             uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
  name           text         NOT NULL UNIQUE,
  display_order  int          NOT NULL DEFAULT 0,
  is_archived    boolean      NOT NULL DEFAULT false,
  created_at     timestamptz  NOT NULL DEFAULT now()
);

ALTER TABLE protocol_categories ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "read protocol categories" ON protocol_categories;
CREATE POLICY "read protocol categories"
  ON protocol_categories FOR SELECT
  TO authenticated
  USING (true);

DROP POLICY IF EXISTS "admin write protocol categories" ON protocol_categories;
CREATE POLICY "admin write protocol categories"
  ON protocol_categories FOR ALL
  TO authenticated
  USING      (EXISTS (SELECT 1 FROM profiles WHERE user_id = auth.uid() AND role = 'admin'))
  WITH CHECK (EXISTS (SELECT 1 FROM profiles WHERE user_id = auth.uid() AND role = 'admin'));


-- ─────────────────────────────────────────────────────────────────────────
-- Seed: insert the current hardcoded protocols and categories so the
-- admin portal isn't empty on first load. Only seeds if the table is
-- empty (safe to re-run).
-- ─────────────────────────────────────────────────────────────────────────
INSERT INTO protocol_templates (key, name, category, compounds, note, cycle)
SELECT * FROM (VALUES
  ('sleep',      'Sleep Protocol',      'Longevity',   '["Epithalon 10mg","DSIP 500mcg"]'::jsonb,                             'Take 30 min before bed.', '12 weeks'),
  ('repair',     'Repair Protocol',     'Recovery',    '["BPC-157 250mcg","TB-500 2.5mg"]'::jsonb,                            'Rotate injection sites.', '8 weeks'),
  ('growth',     'Growth Protocol',     'Performance', '["CJC-1295 2mg","Ipamorelin 300mcg"]'::jsonb,                         'Fasted, before bed.',     '12 weeks'),
  ('endurance',  'Endurance Protocol',  'Performance', '["AOD-9604 300mcg","TB-500 2.5mg"]'::jsonb,                           'Pre-workout.',            '12 weeks'),
  ('shred',      'Shred Protocol',      'Body Comp',   '["AOD-9604 300mcg","Semaglutide 0.5mg"]'::jsonb,                      'Morning dose.',           '12 weeks'),
  ('vitality',   'Vitality Protocol',   'Longevity',   '["Epithalon 10mg","Thymosin Alpha-1 1.5mg"]'::jsonb,                  '10-day on cycles.',       '60 days'),
  ('longevity',  'Longevity Protocol',  'Longevity',   '["Epithalon 10mg","Thymosin Alpha-1 1.5mg","Selank 300mcg"]'::jsonb,  'Cycled dosing.',          '60 days'),
  ('recovery',   'Recovery Stack',      'Recovery',    '["BPC-157 250mcg","TB-500 2.5mg"]'::jsonb,                            'Combined repair stack.',  '8 weeks'),
  ('performance','Performance Stack',   'Performance', '["CJC-1295 2mg","Ipamorelin 300mcg","AOD-9604 300mcg"]'::jsonb,       'Fasted.',                 '12 weeks'),
  ('optimize',   'Optimize Stack',      'Performance', '["CJC-1295 2mg","Ipamorelin 300mcg","Epithalon 10mg"]'::jsonb,        'Growth + longevity.',     '12 weeks')
) AS v(key, name, category, compounds, note, cycle)
WHERE NOT EXISTS (SELECT 1 FROM protocol_templates);

INSERT INTO protocol_categories (name, display_order)
SELECT * FROM (VALUES
  ('Sleep',        1),
  ('Repair',       2),
  ('Growth',       3),
  ('Endurance',    4),
  ('Shred',        5),
  ('Vitality',     6),
  ('Longevity',    7),
  ('Recovery',     8),
  ('Performance',  9),
  ('Optimize',    10)
) AS v(name, display_order)
WHERE NOT EXISTS (SELECT 1 FROM protocol_categories);


-- ─────────────────────────────────────────────────────────────────────────
-- Verify
-- ─────────────────────────────────────────────────────────────────────────
SELECT 'protocol_templates rows',  COUNT(*) FROM protocol_templates;
SELECT 'protocol_categories rows', COUNT(*) FROM protocol_categories;
