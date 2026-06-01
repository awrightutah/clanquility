/*
 * Migration: item_purchase_history table + record_item_purchase trigger
 *
 * Step 1a of Smart Shopping Phase 2 (audits/2026-06-01-smart-shopping-spec.md).
 *
 * Records purchase observations per (household, item_name_normalized, store)
 * triple via an AFTER UPDATE trigger on shopping_items. Fires only on the
 * false→true transition of the purchased column. Upserts on conflict to
 * keep one dense row per triple with last_purchased_at + purchase_count.
 *
 * Used by Step 1b's Quick Add UI to suggest the store when adding an item
 * based on prior purchase history.
 *
 * Defensive design:
 *   - COALESCE(NEW.purchased_at, now()) — falls back to trigger-fire time if
 *     a future code path forgets to set purchased_at. Prevents the trigger
 *     from blocking a user's 'mark purchased' tap due to a downstream
 *     bookkeeping bug.
 *   - Skip insert if essential fields are NULL or name is whitespace-only.
 *   - WHEN (OLD.purchased IS DISTINCT FROM NEW.purchased AND NEW.purchased = true)
 *     handles NULL → true cleanly via IS DISTINCT FROM.
 *
 * RLS:
 *   - SELECT/INSERT/UPDATE: any household member
 *   - DELETE: admins only (cleanup actions)
 *
 * Trigger function is plpgsql without SECURITY DEFINER, matching codebase
 * convention. Trigger runs as the original caller (the user who just
 * updated shopping_items), so the INSERT into item_purchase_history
 * passes the member_insert RLS policy by construction.
 *
 * Realtime: not subscribed for v1. Add Item form reads on open, not via
 * subscription. May add later if cross-device sync surfaces as a gap.
 *
 * Applied to production Supabase 2026-06-01 via SQL Editor (Step 1a of
 * Smart Shopping Phase 2). This file backfills the change into the repo
 * migration history. Trigger function includes the COALESCE amendment
 * that was applied after the initial print.
 */

CREATE TABLE IF NOT EXISTS public.item_purchase_history (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  household_id uuid NOT NULL REFERENCES public.households(id) ON DELETE CASCADE,
  item_name_normalized text NOT NULL,
  store_id uuid NOT NULL REFERENCES public.stores(id) ON DELETE CASCADE,
  last_purchased_at timestamptz NOT NULL DEFAULT now(),
  purchase_count integer NOT NULL DEFAULT 1,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_item_purchase_history_unique
  ON public.item_purchase_history (household_id, item_name_normalized, store_id);

CREATE INDEX IF NOT EXISTS idx_item_purchase_history_lookup
  ON public.item_purchase_history (household_id, item_name_normalized);

ALTER TABLE public.item_purchase_history ENABLE ROW LEVEL SECURITY;

CREATE POLICY item_purchase_history_member_select
  ON public.item_purchase_history
  FOR SELECT
  TO authenticated
  USING (is_household_member(household_id));

CREATE POLICY item_purchase_history_member_insert
  ON public.item_purchase_history
  FOR INSERT
  TO authenticated
  WITH CHECK (is_household_member(household_id));

CREATE POLICY item_purchase_history_member_update
  ON public.item_purchase_history
  FOR UPDATE
  TO authenticated
  USING (is_household_member(household_id))
  WITH CHECK (is_household_member(household_id));

CREATE POLICY item_purchase_history_admin_delete
  ON public.item_purchase_history
  FOR DELETE
  TO authenticated
  USING (is_household_admin(household_id));

CREATE OR REPLACE FUNCTION public.record_item_purchase()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_name_normalized text;
BEGIN
  IF NEW.store_id IS NULL OR NEW.household_id IS NULL OR NEW.name IS NULL THEN
    RETURN NEW;
  END IF;

  v_name_normalized := lower(trim(NEW.name));

  IF v_name_normalized = '' THEN
    RETURN NEW;
  END IF;

  INSERT INTO public.item_purchase_history (
    household_id, item_name_normalized, store_id, last_purchased_at, purchase_count
  )
  VALUES (
    NEW.household_id, v_name_normalized, NEW.store_id, COALESCE(NEW.purchased_at, now()), 1
  )
  ON CONFLICT (household_id, item_name_normalized, store_id)
  DO UPDATE SET
    last_purchased_at = EXCLUDED.last_purchased_at,
    purchase_count = item_purchase_history.purchase_count + 1,
    updated_at = now();

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS record_item_purchase_on_purchased ON public.shopping_items;

CREATE TRIGGER record_item_purchase_on_purchased
  AFTER UPDATE ON public.shopping_items
  FOR EACH ROW
  WHEN (OLD.purchased IS DISTINCT FROM NEW.purchased AND NEW.purchased = true)
  EXECUTE FUNCTION public.record_item_purchase();
