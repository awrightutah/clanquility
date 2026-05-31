/*
 * Migration: One active list per store (partial unique index)
 *
 * Phase 1 Sub-branch 2b-1 of the shopping rework. Adds a partial
 * unique index ensuring at most one is_active=true list per store.
 * Multiple archived lists remain valid.
 *
 * This constraint prevents the data fragmentation bug discovered
 * during 0028 backfill: two duplicate is_active=true lists existed
 * for the same store, with items split between them. Going forward,
 * any code path attempting to create a second active list for a
 * store will fail with a unique violation — visible, debuggable,
 * not silently fragmenting data.
 *
 * Applied to production Supabase 2026-05-31 via SQL Editor.
 */

CREATE UNIQUE INDEX IF NOT EXISTS idx_shopping_lists_one_active_per_store
ON public.shopping_lists (store_id)
WHERE is_active = true;
