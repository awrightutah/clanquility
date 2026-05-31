/*
 * Migration: One default store per household
 *
 * Adds a partial unique index ensuring at most one store per household
 * can be marked is_default=true. Multiple non-default stores are fine.
 *
 * Applied to production Supabase 2026-05-31 via SQL Editor (Phase 1 Sub-branch 1
 * of Bug 1 shopping rework). This file backfills the change into the repo
 * migration history.
 */

CREATE UNIQUE INDEX IF NOT EXISTS idx_stores_one_default_per_household
ON public.stores (household_id)
WHERE is_default = true;
