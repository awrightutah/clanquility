/*
 * Migration: add_item_to_store RPC
 *
 * Phase 1 Sub-branch 2b-1 of the shopping rework. Store-first item add
 * path: takes a store_id (instead of household_id + shopping_list_id)
 * and resolves the household + active list internally. Single round-trip
 * write that preserves the wishlist routing semantics from
 * add_shopping_item (migration 0017).
 *
 * Why a new RPC rather than reusing add_shopping_item: the store-first
 * UX collapses the per-tab data model around store as the primary axis.
 * The mobile client passes store_id (which it has from the navigation
 * context); the RPC derives household_id and the active list_id. This
 * lets the client stay store-centric without having to fetch the
 * active list separately before each add.
 *
 * Wishlist routing: mirrors add_shopping_item logic via
 * the necessity_categories TABLE (not a column on households).
 * Kids' items default to is_wishlist=true UNLESS the category is a
 * case-insensitive match in necessity_categories. Adult items always
 * is_wishlist=false.
 *
 * Auth: validates is_household_member of the store's household.
 * Errors:
 *   P0001 — Store not found
 *   P0002 — Not authorized (not a household member)
 *   P0003 — Store has no active list (shouldn't happen given the
 *           partial unique index from migration 0029, but defensive)
 *
 * Returns the new shopping_items.id.
 *
 * Applied to production Supabase 2026-05-31 via SQL Editor.
 */

CREATE OR REPLACE FUNCTION public.add_item_to_store(
  p_member_id uuid,
  p_store_id uuid,
  p_name text,
  p_quantity numeric DEFAULT NULL,
  p_unit text DEFAULT NULL,
  p_category text DEFAULT NULL,
  p_display_quantity text DEFAULT NULL,
  p_source_recipe_id uuid DEFAULT NULL,
  p_source_meal_plan_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_household_id uuid;
  v_active_list_id uuid;
  v_is_wishlist boolean;
  v_is_kid boolean;
  v_is_necessity boolean;
  v_new_item_id uuid;
BEGIN
  -- Look up household from store
  SELECT household_id INTO v_household_id
  FROM public.stores
  WHERE id = p_store_id;

  IF v_household_id IS NULL THEN
    RAISE EXCEPTION 'Store not found' USING ERRCODE = 'P0001';
  END IF;

  -- Validate caller is a household member
  IF NOT public.is_household_member(v_household_id) THEN
    RAISE EXCEPTION 'Not authorized' USING ERRCODE = 'P0002';
  END IF;

  -- Look up active list for this store
  SELECT id INTO v_active_list_id
  FROM public.shopping_lists
  WHERE store_id = p_store_id
    AND is_active = true
  LIMIT 1;

  IF v_active_list_id IS NULL THEN
    RAISE EXCEPTION 'Store has no active list' USING ERRCODE = 'P0003';
  END IF;

  -- Determine wishlist routing (mirrors add_shopping_item in migration 0017)
  SELECT (kind = 'sub_profile') INTO v_is_kid
  FROM public.household_members
  WHERE id = p_member_id;

  v_is_wishlist := false;
  IF v_is_kid THEN
    -- Case-insensitive necessity match against necessity_categories TABLE
    SELECT EXISTS (
      SELECT 1
        FROM public.necessity_categories nc
       WHERE nc.household_id = v_household_id
         AND lower(nc.category) = lower(COALESCE(p_category, ''))
    ) INTO v_is_necessity;

    v_is_wishlist := NOT v_is_necessity;
  END IF;

  -- Insert the item
  INSERT INTO public.shopping_items (
    household_id, shopping_list_id, store_id,
    name, quantity, unit, category, display_quantity,
    purchased, is_wishlist,
    added_by_member_id,
    source_recipe_id, source_meal_plan_id
  )
  VALUES (
    v_household_id, v_active_list_id, p_store_id,
    p_name, p_quantity, p_unit, p_category, p_display_quantity,
    false, v_is_wishlist,
    p_member_id,
    p_source_recipe_id, p_source_meal_plan_id
  )
  RETURNING id INTO v_new_item_id;

  RETURN v_new_item_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.add_item_to_store(uuid, uuid, text, numeric, text, text, text, uuid, uuid) TO authenticated;
