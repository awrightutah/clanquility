/*
 * Migration: delete_store_and_reassign RPC
 *
 * Atomic store-deletion operation. Moves all items off the
 * to-be-deleted store onto the household's default store (updates
 * both store_id and shopping_list_id to the default's active list),
 * then deletes the store. The store deletion cascades to its
 * shopping_lists rows (FK in migration 0028 sets ON DELETE CASCADE),
 * which are now empty because items were already moved off.
 *
 * SECURITY DEFINER for transaction integrity. Authorization via
 * is_household_admin (delete is admin-only).
 *
 * Blocks deletion of the default store with P0003. Mobile UI surfaces
 * this as 'Set another store as default first.'
 *
 * Error codes:
 *   P0001 — Store not found
 *   P0002 — Not authorized (caller is not a household admin)
 *   P0003 — Cannot delete the default store
 *   P0004 — No default store found for household (defensive; shouldn't
 *           happen post-backfill from migration 0025)
 *   P0005 — Default store has no active list (defensive; shouldn't
 *           happen post-constraint from migration 0029 + the
 *           ensure-default-list code path)
 *
 * Used by the upcoming Delete button in AddEditStoreScreen edit mode
 * (Sub-branch 2b-2 Task 5b of the shopping rework).
 *
 * Applied to production Supabase 2026-05-31 via SQL Editor (Phase 1
 * Sub-branch 2b-2 Task 5a of the shopping rework). This file
 * backfills the change into the repo migration history.
 */

CREATE OR REPLACE FUNCTION public.delete_store_and_reassign(p_store_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_household_id uuid;
  v_is_default boolean;
  v_default_store_id uuid;
  v_default_active_list_id uuid;
BEGIN
  SELECT household_id, is_default
    INTO v_household_id, v_is_default
  FROM public.stores
  WHERE id = p_store_id;

  IF v_household_id IS NULL THEN
    RAISE EXCEPTION 'Store not found' USING ERRCODE = 'P0001';
  END IF;

  IF NOT public.is_household_admin(v_household_id) THEN
    RAISE EXCEPTION 'Not authorized' USING ERRCODE = 'P0002';
  END IF;

  IF v_is_default THEN
    RAISE EXCEPTION 'Cannot delete the default store. Set another store as default first.' USING ERRCODE = 'P0003';
  END IF;

  SELECT id INTO v_default_store_id
  FROM public.stores
  WHERE household_id = v_household_id
    AND is_default = true
  LIMIT 1;

  IF v_default_store_id IS NULL THEN
    RAISE EXCEPTION 'No default store found for household' USING ERRCODE = 'P0004';
  END IF;

  SELECT id INTO v_default_active_list_id
  FROM public.shopping_lists
  WHERE store_id = v_default_store_id
    AND is_active = true
  LIMIT 1;

  IF v_default_active_list_id IS NULL THEN
    RAISE EXCEPTION 'Default store has no active list' USING ERRCODE = 'P0005';
  END IF;

  UPDATE public.shopping_items
  SET store_id = v_default_store_id,
      shopping_list_id = v_default_active_list_id
  WHERE store_id = p_store_id;

  DELETE FROM public.stores
  WHERE id = p_store_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.delete_store_and_reassign(uuid) TO authenticated;
