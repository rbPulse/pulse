-- ═══════════════════════════════════════════════════════════════════════════
-- Pulse — Phase 6 migration: protocol_product_types
-- ═══════════════════════════════════════════════════════════════════════════
--
-- WHAT THIS DOES
--   Creates a table to back the "Product Types" section of the admin
--   catalog manager (e.g. Pod, Stack). Mirrors protocol_categories so
--   admins can add/archive types independently of the products that
--   use them. Existing products keep their product_type string; the
--   table just governs what shows up in filters and the editor.
--
-- USAGE
--   Paste into the Supabase SQL editor and run. Idempotent.
--
-- ROLLBACK
--   DROP TABLE protocol_product_types;
--
-- ═══════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS protocol_product_types (
  id             uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
  name           text         NOT NULL UNIQUE,
  display_order  int          NOT NULL DEFAULT 0,
  is_archived    boolean      NOT NULL DEFAULT false,
  created_at     timestamptz  NOT NULL DEFAULT now()
);

ALTER TABLE protocol_product_types ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "read product types" ON protocol_product_types;
CREATE POLICY "read product types"
  ON protocol_product_types FOR SELECT
  TO authenticated
  USING (true);

DROP POLICY IF EXISTS "admin write product types" ON protocol_product_types;
CREATE POLICY "admin write product types"
  ON protocol_product_types FOR ALL
  TO authenticated
  USING      (EXISTS (SELECT 1 FROM profiles WHERE user_id = auth.uid() AND role = 'admin'))
  WITH CHECK (EXISTS (SELECT 1 FROM profiles WHERE user_id = auth.uid() AND role = 'admin'));

-- Seed the two known product types
INSERT INTO protocol_product_types (name, display_order)
VALUES
  ('Pod',   1),
  ('Stack', 2)
ON CONFLICT (name) DO UPDATE SET
  display_order = EXCLUDED.display_order,
  is_archived   = false;

-- Verify
SELECT 'protocol_product_types rows', COUNT(*) FROM protocol_product_types;
SELECT name, display_order, is_archived FROM protocol_product_types ORDER BY display_order;
