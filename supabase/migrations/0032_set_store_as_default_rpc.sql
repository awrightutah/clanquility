/*
 * Migration: set_store_as_default RPC
 *
 * Atomic switch-default-store operation. Two writes (unset old
 * default, set new default) in one transaction so the household
 * never has zero defaults or two defaults visible mid-operation.
 *
 * SECURITY DEFINER for transaction integrity. Authorization via
 * is_household_admin (mutating default is admin-only). Raises
 * P0001 (store not found), P0002 (not authorized).
 *
 * Partial unique index from migration 0024 enforces at most one
 * default per household at commit time; this RPC ensures the
 * pre-commit state is valid by unsetting before setting in a
 * single transaction.
 *
 * Used by the upcoming AddEditStoreScreen (Sub-branch 2b-2 Task 2)
 * when the user toggles 'Set as default' for a store.
 *
 * Applied to production Supabase 2026-05-31 via SQL Editor (Phase 1
 * Sub-branch 2b-2 Task 2a of the shopping rework). This file
 * backfills the change into the repo migration history.
 */

CREATE OR REPLACE FUNCTION public.set_store_as_default(p_store_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_household_id uuid;
BEGIN
  SELECT household_id INTO v_household_id
  FROM public.stores
  WHERE id = p_store_id;

  IF v_household_id IS NULL THEN
    RAISE EXCEPTION 'Store not found' USING ERRCODE = 'P0001';
  END IF;

  IF NOT public.is_household_admin(v_household_id) THEN
    RAISE EXCEPTION 'Not authorized' USING ERRCODE = 'P0002';
  END IF;

  UPDATE public.stores
  SET is_default = false
  WHERE household_id = v_household_id
    AND is_default = true
    AND id <> p_store_id;

  UPDATE public.stores
  SET is_default = true
  WHERE id = p_store_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.set_store_as_default(uuid) TO authenticated;
