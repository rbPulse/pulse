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
  key            text         NOT NULL UNIQUE,       -- slug: "sleep", "repair"
  name           text         NOT NULL,              -- display name: "Sleep", "Repair"
  product_type   text,                               -- "Pod" or "Stack"
  category       text,                               -- grouping: "Performance", "Longevity", etc.
  compounds      jsonb        DEFAULT '[]',          -- array of component strings
  price          numeric(10,2),                      -- product price in USD
  note           text,                               -- clinical note / admin notes
  is_archived    boolean      NOT NULL DEFAULT false,
  created_by     uuid,
  created_at     timestamptz  NOT NULL DEFAULT now(),
  updated_at     timestamptz  NOT NULL DEFAULT now()
);

-- If running against an existing table that doesn't have new columns yet
ALTER TABLE protocol_templates ADD COLUMN IF NOT EXISTS product_type text;
ALTER TABLE protocol_templates ADD COLUMN IF NOT EXISTS price numeric(10,2);

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
-- Seed: upsert so re-running the migration updates existing rows that
-- were seeded with the old schema (e.g. "Sleep Protocol" → "Sleep").
-- Clean product names, Pod/Stack type, Performance/Longevity/Recovery/
-- Body Comp categories, $100 baseline price.
-- ─────────────────────────────────────────────────────────────────────────
INSERT INTO protocol_templates (key, name, product_type, category, compounds, price, note)
VALUES
  ('sleep',      'Sleep',      'Pod',   'Longevity',   '["Epithalon 10mg","DSIP 500mcg"]'::jsonb,                             100.00, 'Take 30 min before bed.'),
  ('repair',     'Repair',     'Pod',   'Recovery',    '["BPC-157 250mcg","TB-500 2.5mg"]'::jsonb,                            100.00, 'Rotate injection sites.'),
  ('growth',     'Growth',     'Pod',   'Performance', '["CJC-1295 2mg","Ipamorelin 300mcg"]'::jsonb,                         100.00, 'Fasted, before bed.'),
  ('endurance',  'Endurance',  'Pod',   'Performance', '["AOD-9604 300mcg","TB-500 2.5mg"]'::jsonb,                           100.00, 'Pre-workout.'),
  ('shred',      'Shred',      'Pod',   'Body Comp',   '["AOD-9604 300mcg","Semaglutide 0.5mg"]'::jsonb,                      100.00, 'Morning dose.'),
  ('vitality',   'Vitality',   'Pod',   'Longevity',   '["Epithalon 10mg","Thymosin Alpha-1 1.5mg"]'::jsonb,                  100.00, '10-day on cycles.'),
  ('longevity',  'Longevity',  'Pod',   'Longevity',   '["Epithalon 10mg","Thymosin Alpha-1 1.5mg","Selank 300mcg"]'::jsonb,  100.00, 'Cycled dosing.'),
  ('recovery',   'Recovery',   'Stack', 'Recovery',    '["BPC-157 250mcg","TB-500 2.5mg"]'::jsonb,                            100.00, 'Combined repair stack.'),
  ('performance','Performance','Stack', 'Performance', '["CJC-1295 2mg","Ipamorelin 300mcg","AOD-9604 300mcg"]'::jsonb,       100.00, 'Fasted.'),
  ('optimize',   'Optimize',   'Stack', 'Performance', '["CJC-1295 2mg","Ipamorelin 300mcg","Epithalon 10mg"]'::jsonb,        100.00, 'Growth + longevity.')
ON CONFLICT (key) DO UPDATE SET
  name         = EXCLUDED.name,
  product_type = EXCLUDED.product_type,
  category     = EXCLUDED.category,
  compounds    = EXCLUDED.compounds,
  price        = EXCLUDED.price,
  note         = EXCLUDED.note,
  updated_at   = now();

INSERT INTO protocol_categories (name, display_order)
VALUES
  ('Performance',  1),
  ('Longevity',    2),
  ('Recovery',     3),
  ('Body Comp',    4)
ON CONFLICT (name) DO UPDATE SET
  display_order = EXCLUDED.display_order;

-- Archive the OLD category names left over from the initial seed
-- (Sleep, Repair, Growth, etc. were stored as categories before we
-- restructured — they are now product names, not categories).
UPDATE protocol_categories
  SET is_archived = true
  WHERE name IN ('Sleep','Repair','Growth','Endurance','Shred','Vitality','Longevity','Recovery','Performance','Optimize')
    AND name NOT IN ('Performance','Longevity','Recovery','Body Comp');


-- ─────────────────────────────────────────────────────────────────────────
-- Verify
-- ─────────────────────────────────────────────────────────────────────────
SELECT 'protocol_templates rows',  COUNT(*) FROM protocol_templates;
SELECT 'protocol_categories rows', COUNT(*) FROM protocol_categories;
