/*
 * Migration: Tighten stores RLS to admin-only mutations
 *
 * Replaces the single permissive household_scoped_stores policy with
 * four scoped policies:
 *   - stores_member_select: any household member can SELECT
 *   - stores_admin_insert / update / delete: admins only
 *
 * Same pattern as migration 0023 (calendar_tags_rls_admin_only_mutations.sql).
 * Without this, any household member (including kids) could CRUD stores.
 * With this, only admins can mutate; kids can still SELECT for pickers.
 *
 * Applied to production Supabase 2026-05-31 via SQL Editor (Phase 1
 * Sub-branch 2a of Bug 1 shopping rework). This file backfills the
 * change into the repo migration history.
 */

DROP POLICY IF EXISTS household_scoped_stores ON public.stores;

CREATE POLICY stores_member_select
  ON public.stores
  FOR SELECT
  TO authenticated
  USING (is_household_member(household_id));

CREATE POLICY stores_admin_insert
  ON public.stores
  FOR INSERT
  TO authenticated
  WITH CHECK (is_household_admin(household_id));

CREATE POLICY stores_admin_update
  ON public.stores
  FOR UPDATE
  TO authenticated
  USING (is_household_admin(household_id))
  WITH CHECK (is_household_admin(household_id));

CREATE POLICY stores_admin_delete
  ON public.stores
  FOR DELETE
  TO authenticated
  USING (is_household_admin(household_id));
