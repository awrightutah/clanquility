/*
 * Migration: Add store_id to shopping_lists (per-store lists model)
 *
 * Phase 1 Sub-branch 2b-1 of the shopping rework. Adds store_id FK
 * column to shopping_lists, indexes it, backfills existing rows by
 * assigning to each household's default store, then locks the column
 * NOT NULL going forward.
 *
 * Backfill discovery: production had 2 duplicate is_active=true lists
 * for the test household (created 13ms apart on 2026-05-21 from a
 * suspected race condition in _createDefaultList). Recovery work
 * merged items from both lists onto one (39 total) and deleted the
 * duplicate. The partial unique constraint added in
 * 0029_shopping_lists_one_active_per_store.sql prevents recurrence.
 *
 * Applied to production Supabase 2026-05-31 via SQL Editor.
 */

ALTER TABLE public.shopping_lists
ADD COLUMN IF NOT EXISTS store_id uuid REFERENCES public.stores(id) ON DELETE CASCADE;

CREATE INDEX IF NOT EXISTS idx_shopping_lists_store_id
  ON public.shopping_lists(store_id);

-- Backfill: assign existing lists to their household's default store
DO $$
DECLARE
  list_record RECORD;
  v_default_store_id uuid;
BEGIN
  FOR list_record IN
    SELECT id, household_id FROM public.shopping_lists
    WHERE store_id IS NULL
  LOOP
    SELECT id INTO v_default_store_id
    FROM public.stores
    WHERE household_id = list_record.household_id
      AND is_default = true
    LIMIT 1;

    IF v_default_store_id IS NOT NULL THEN
      UPDATE public.shopping_lists
      SET store_id = v_default_store_id
      WHERE id = list_record.id;
    END IF;
  END LOOP;
END $$;

-- Lock NOT NULL going forward (after backfill is complete)
ALTER TABLE public.shopping_lists
ALTER COLUMN store_id SET NOT NULL;
