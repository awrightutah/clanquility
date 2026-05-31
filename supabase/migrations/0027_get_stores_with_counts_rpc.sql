/*
 * Migration: get_stores_with_counts RPC
 *
 * SECURITY DEFINER function returning a household's stores with
 * active item counts in a single round-trip. Replaces the two-query
 * + client-side aggregation that the mobile code would otherwise do.
 *
 * Active count semantics: purchased = false AND is_wishlist = false.
 * Wishlist items are admin-pending and shouldn't inflate the
 * 'stuff to buy' counter on the stores-list view.
 *
 * Ordering: default store first (is_default DESC), then alphabetical.
 *
 * Auth: SECURITY DEFINER bypasses RLS for efficient count aggregation,
 * but the WHERE clause includes is_household_member(p_household_id) as
 * an in-function auth gate. Non-members receive zero rows (silent
 * denial — appropriate for read-only).
 *
 * Used by the new ShoppingStoresScreen at the Shopping tab root
 * (Sub-branch 2b) to populate the store-with-counts list.
 *
 * Applied to production Supabase 2026-05-31 via SQL Editor (Phase 1
 * Sub-branch 2a of Bug 1 shopping rework). This file backfills the
 * change into the repo migration history.
 */

CREATE OR REPLACE FUNCTION public.get_stores_with_counts(p_household_id uuid)
RETURNS TABLE(
  id uuid,
  name text,
  is_default boolean,
  active_count bigint,
  created_at timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    s.id,
    s.name,
    s.is_default,
    COALESCE(
      (SELECT count(*)
       FROM public.shopping_items si
       WHERE si.store_id = s.id
         AND si.purchased = false
         AND si.is_wishlist = false),
      0
    ) AS active_count,
    s.created_at
  FROM public.stores s
  WHERE s.household_id = p_household_id
    AND public.is_household_member(p_household_id)
  ORDER BY s.is_default DESC, s.name ASC;
$$;

GRANT EXECUTE ON FUNCTION public.get_stores_with_counts(uuid) TO authenticated;
