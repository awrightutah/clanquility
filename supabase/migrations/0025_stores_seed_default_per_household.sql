/*
 * Migration: Backfill default 'Grocery Store' per household + assign items
 *
 * For every existing household, INSERT a single 'Grocery Store' with
 * is_default=true if no default store exists yet. Then UPDATE all
 * shopping_items rows with store_id=null to point to their household's
 * default store.
 *
 * This is a one-time backfill. New households get the seeded store via
 * the application code (household_setup_screen.dart seed loop, added in
 * the same branch as this migration).
 *
 * Applied to production Supabase 2026-05-31 via SQL Editor (Phase 1 Sub-branch 1
 * of Bug 1 shopping rework). This file backfills the change into the repo
 * migration history.
 *
 * Idempotency: the WHERE NOT EXISTS clause inside the FOR loop skips
 * households that already have a default store, so re-running this
 * migration is safe and won't create duplicates.
 */

DO $$
DECLARE
  household_record RECORD;
  new_store_id uuid;
BEGIN
  FOR household_record IN
    SELECT id FROM public.households
    WHERE NOT EXISTS (
      SELECT 1 FROM public.stores
      WHERE household_id = households.id AND is_default = true
    )
  LOOP
    INSERT INTO public.stores (household_id, name, is_default)
    VALUES (household_record.id, 'Grocery Store', true)
    RETURNING id INTO new_store_id;

    UPDATE public.shopping_items
    SET store_id = new_store_id
    WHERE household_id = household_record.id
      AND store_id IS NULL;
  END LOOP;
END $$;
