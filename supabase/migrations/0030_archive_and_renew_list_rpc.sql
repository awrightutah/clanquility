/*
 * Migration: archive_and_renew_list RPC
 *
 * Phase 1 Sub-branch 2b-1 of the shopping rework. SECURITY DEFINER
 * function that atomically archives the given shopping_list and
 * creates a fresh active replacement scoped to the same store, in
 * a single transaction.
 *
 * Use case: 'Done shopping at <store>' flow. The current list rolls
 * to history (archived_at + is_active=false), a new is_active=true
 * list takes its place. The partial unique index from migration 0029
 * makes this atomic: if some concurrent code path tries to create
 * its own new active list at the same time, one of the two
 * INSERTs will fail with unique_violation rather than silently
 * fragmenting.
 *
 * Auth: validates is_household_member of the list's household.
 * Non-members get P0002 'Not authorized'. Missing list gets P0001
 * 'List not found'.
 *
 * Returns the new list's id (so the caller can immediately
 * navigate to or refresh against it).
 *
 * Applied to production Supabase 2026-05-31 via SQL Editor.
 */

CREATE OR REPLACE FUNCTION public.archive_and_renew_list(p_list_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_household_id uuid;
  v_store_id uuid;
  v_new_list_id uuid;
BEGIN
  -- Validate the list exists and capture its household + store
  SELECT household_id, store_id INTO v_household_id, v_store_id
  FROM public.shopping_lists
  WHERE id = p_list_id;

  IF v_household_id IS NULL THEN
    RAISE EXCEPTION 'List not found' USING ERRCODE = 'P0001';
  END IF;

  -- Validate caller is a household member
  IF NOT public.is_household_member(v_household_id) THEN
    RAISE EXCEPTION 'Not authorized' USING ERRCODE = 'P0002';
  END IF;

  -- Archive the current list and create the renewed active list in one transaction
  UPDATE public.shopping_lists
  SET archived_at = now(),
      is_active = false
  WHERE id = p_list_id;

  INSERT INTO public.shopping_lists (household_id, store_id, name, is_active)
  VALUES (v_household_id, v_store_id, 'Current Shopping List', true)
  RETURNING id INTO v_new_list_id;

  RETURN v_new_list_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.archive_and_renew_list(uuid) TO authenticated;
