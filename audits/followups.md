# Followups & Known Issues

Living registry of items that need addressing but aren't blocking current work. Each item gets a status; resolved items move to the archive section so future investigations don't re-discover them.

**Maintenance:** Add new items as they're discovered (during investigation, smoke testing, design conversations). Move items to "Resolved" with a date + resolution note when shipped. Don't delete items from this doc — the archive is the historical record.

---

## Phase 1 leftovers (shopping rework)

### Paths 1, 2, 4, 5 in shopping fanout don't set `store_id`

Items added via meal-scheduling auto-add (adult + kid), recipe-detail "add to cart", or recipe-library "add to shopping" land with `store_id = NULL`. Because Phase 1's ShoppingListScreen filters by `store_id`, these items become invisible in the store-scoped UI.

- **Status:** Dormant in production today (0 affected items as of 2026-06-01). Bug will fire as soon as those paths get exercised.
- **Resolution path:** Smart Shopping Phase 2 Step 3 (fanout path consolidation) will route all 5 paths through `add_item_to_store` RPC, naturally fixing this bug.
- **Investigation reference:** Day 11 Step 2 investigation surfaced this.

### Path 2 still calls pre-Phase-1 `add_shopping_item` RPC

Meal scheduling auto-add for kids still uses the old `add_shopping_item` RPC instead of `add_item_to_store`. Migration debt from Phase 1.

- **Status:** Functional but inconsistent.
- **Resolution path:** Smart Shopping Phase 2 Step 3 (fanout consolidation) will migrate Path 2 along with the others.

### Deprecated DropdownButtonFormField `value:` parameters

Two pickers in `apps/mobile/lib/screens/meal_planner_screen.dart` still use the deprecated `value:` parameter instead of `initialValue:`. Triggers linter warnings.

- **Status:** Warnings only, no functional impact.
- **Resolution path:** Quick fix when the file is next opened for other work.

### Helper duplication across files

`_parseTagColor` and `_isRlsError` helper functions are duplicated in 3+ files (`shopping_list_screen.dart`, `shopping_stores_screen.dart`, and at least one other).

- **Status:** Working but DRY violation.
- **Resolution path:** Extract to shared util (similar to how `shopping_categories.dart` was extracted in Step 1b of Smart Shopping).

---

## Smart Shopping Phase 2 design decisions

(All decisions through Step 2 ordering locked as of 2026-06-01. New items added as later steps surface design questions.)

---

## General product bugs

### Duplicate household_recipes on rapid "Add to my library" taps

Tapping "Add to my library" on a master recipe twice (or otherwise re-triggering the action) creates duplicate `household_recipes` entries pointing at the same `master_recipe_id`.

- **Observed:** 2 copies of "Taco Tuesday Tacos" in test household, created ~3 minutes apart, same `master_recipe_id`, same creator. 2026-05-21.
- **Status:** Confirmed bug, low severity (limited tester base + workaround exists).
- **Likely cause:** Add button is tappable while the previous request is in flight, OR the success state doesn't communicate clearly enough to prevent re-adds.
- **Resolution path:** Either debounce the button after first tap until response, or check for existing copy in household before allowing insert. Probably a future minor sprint.

---

## Resolved (archive)

### 2026-06-01 — Smart Shopping Phase 2 Step 1 shipped
Store-routing memory complete. `item_purchase_history` table + trigger + RLS in production (migration 0034). Quick Add UI on ShoppingStoresScreen with debounced history lookup. Magic-moment "You usually buy 'X' at Y" helper text validated end-to-end. Merged to main at a560862.

### 2026-06-01 — Smart Shopping Phase 2 spec banked
Six-step roadmap for predictive shopping foundation documented in audits/2026-06-01-smart-shopping-spec.md. Locked product decisions: deterministic-first, cron-based, templated notifications, hybrid ingredients_master architecture. Commit 25f1c89.

### 2026-05-31 — Phase 1 shopping rework shipped
Store-first shopping architecture. ShoppingStoresScreen, ShoppingListScreen scoped to store_id, archive_and_renew_list RPC, add_item_to_store RPC. TestFlight 1.0.0+3 uploaded Day 9 evening.

---

End of followups registry.
