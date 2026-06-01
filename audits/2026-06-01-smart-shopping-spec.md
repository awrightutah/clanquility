# Smart Shopping — Phase 2 Spec

**Date:** 2026-06-01
**Status:** Locked, ready for implementation
**Builds on:** 2026-05-31-shopping-rework-spec.md (Phase 1 shopping rework, shipped on Day 9 in TestFlight build 1.0.0+3)

---

## Product Vision

The headline outcome: **"Wow, the app remembered."**

A user opens the Add Item form and the store is already pre-selected based on where they bought this item last time. Two weeks later, they get a notification: "You have Tacos planned tonight — you haven't bought ground beef in 12 days." The app feels like it's paying attention.

Smart Shopping is not one feature. It's the visible outcome of a foundation that combines:
- Shopping pattern memory (what was bought, where, when)
- Recipe ingredient identity (the same "broccoli" across recipes)
- Meal consumption signal (planned meals → actually eaten → ingredients depleted)
- Predictive logic running once daily (cron-based, server-side, deterministic)

This differentiates Clanquility from AnyList, Cozi, OurGroceries, and similar shopping apps. None combine recipe-aware meal planning with per-store shopping and consumption-driven predictions. The combination is the moat.

The discipline this spec captures: **foundation right before features ship.** Predictive notifications that misfire train users to ignore notifications permanently. The cost of getting it wrong is higher than the cost of waiting until it's right.

---

## Current State (investigation findings from 2026-06-01)

**Recipe ingredients are mostly structured.** Sample data shows the `{name, quantity, unit, category}` shape — not free-text "2 cups flour" strings. Existing recipe library UX captures structured fields. URL-imported recipes also produce structured ingredients (when Bug 2 ships).

**shopping_items already records the historical fact infrastructure:**
- `purchased_at timestamptz`
- `purchased_by_member_id uuid`
- `source_recipe_id uuid` (references household_recipes)
- `source_meal_plan_id uuid` (references meal_plans)
- `store_id uuid` (from Phase 1 shopping rework, references stores)

When a row has `purchased = true` and `purchased_at IS NOT NULL`, it's a purchase observation that can be aggregated for patterns.

**meal_plans exists with date + recipe linkage** but has no consumption signal. Today there's no way to know if a planned meal actually happened.

**Four fanout paths from recipe to shopping, inconsistent attribution:**
1. Meal scheduling auto-add (adult): full attribution
2. Meal scheduling auto-add (kid): full attribution
3. _AddFromRecipeSheet in shopping screen (Phase 1 path): partial attribution (source_recipe_id only, no source_meal_plan_id)
4. Recipe detail "add to cart" + Recipe library "add to shopping": no attribution

**Zero purchases marked in production yet.** Cold-start reality: even with infrastructure ready, no historical data exists until users start marking items purchased. The "Done Shopping" archive flow from Phase 1 is critical for habit-forming.

**Ingredient identity is fuzzy.** "flour" vs "all-purpose flour" vs "AP flour" have no shared identity. Aggregation across recipes requires normalization.

---

## Target State

After Phase 2 ships:

- Item purchase history table per household, normalized by ingredient identity
- Master ingredients table with canonical names + synonyms, used by recipe forms (autocomplete) and shopping items (back-reference)
- meal_plans has `consumed_at` column, populated by default when planned date passes, with opt-out UX
- All four fanout paths route through `add_item_to_store` RPC (full attribution everywhere)
- Server-side cron job runs daily per household, evaluates upcoming meals against recent purchases, sends notifications
- Push notifications + in-app notification center, with hand-written templated copy
- User-configurable low-stock thresholds with sensible defaults
- Privacy: shopping/meal data treated as personal data; privacy policy doc written separately

---

## Phased Roadmap

Six steps. Each ships something visible. Don't ship the next step until the current step is right.

### Step 1 — Store-routing memory (1-2 sessions)

**What ships visibly:** When user adds an item, the store is pre-selected based on where this item was last purchased. "The app remembered."

**What's built:**
- New table `item_purchase_history(household_id, item_name_normalized, store_id, last_purchased_at, purchase_count)`
- Triggered on `add_item_to_store` insert path (and on `purchased = true` updates)
- Read on Add Item form: pre-populate store from most recent history match
- Falls back silently to current behavior (default store) when no history match

**Foundation contribution:** Starts accumulating per-item per-store purchase patterns. Same data the bigger prediction needs.

### Step 2 — Ingredient normalization (2-3 sessions)

**What ships visibly:** Recipe ingredient name field becomes autocomplete from master list. Adding the same ingredient name across multiple recipes produces consistent identity.

**What's built:**
- New table `ingredients_master(id, canonical_name, synonyms text[])`
- Recipe edit form: ingredient name → autocomplete with "add new" inline
- New RPC `normalize_ingredient_name(text) → uuid` (matches against canonical_name + synonyms, case-insensitive)
- Backfill existing recipe ingredients to reference ingredients_master (one-time migration)
  - Deterministic for exact matches
  - AI-assisted for ambiguous cases ("AP flour" → "all-purpose flour") — *this is where AI earns its one-time cost*
- Add `ingredient_id uuid` column to shopping_items (deterministic side-channel; populated by add_item_to_store RPC)

**Foundation contribution:** Ingredient identity is now stable across recipes. Cross-recipe aggregation becomes possible.

### Step 3 — Meal consumption signal (1-2 sessions)

**What ships visibly:** Meal planner becomes a meal log. "This week's meals" view shows what was actually eaten. Users see meal history with consumption status.

**What's built:**
- New column `meal_plans.consumed_at timestamptz` (nullable)
- Default-consumed logic: when `planned_for < today` AND `consumed_at IS NULL`, treat as consumed for prediction purposes
- New UX: swipe action or button on past meals to mark "didn't eat" (sets `consumed_at = NULL` with a separate `opted_out_at` flag to distinguish from "not yet marked")
- Meal log view (perhaps in the calendar or meal planner) showing past N days with consumption status

**Foundation contribution:** Meals become historical observations, not just plans. Required for consumption-driven prediction.

### Step 4 — Attribution backfill (1 session)

**What ships visibly:** Nothing direct.

**What's built:**
- Route the two unattributed fanout paths (recipe_detail + recipe_library) through `add_item_to_store` RPC
- Consolidates to one fanout path
- All future purchases attributed to source_recipe_id and source_meal_plan_id when applicable

**Foundation contribution:** Completes the data pipeline. All historical inputs accounted for.

### Step 5 — Smaller prediction: "Recipe-tonight ingredient check" (2-3 sessions)

**What ships visibly:** First predictive notification. Headline magic moment 1.

**Notification format (templated):**
> "You have {recipe_name} planned for tonight. You haven't bought {item_name} in {days_since} days — might want to check."

**What's built:**
- Server-side cron job (Supabase pg_cron) running once daily, late morning
- For each household: identify recipes planned in next 24-48 hours, aggregate required ingredients, check shopping_items + item_purchase_history for recent purchases
- Notification dispatch via existing push infrastructure (assumes APN/FCM is already wired)
- In-app notification center (small inbox icon in header? settings page?)
- User-configurable thresholds: "remind me if I haven't bought {ingredient} in N days" — default N=7
- Hand-written templated copy with smart variables

**Foundation contribution:** Validates the prediction pipeline end-to-end with a tractable scope. Surfaces UX edge cases before the bigger feature.

### Step 6 — Bigger prediction: "Running out based on consumption rate" (2-3 sessions)

**What ships visibly:** The full magic moment. Headline magic moment 2.

**Notification format (templated):**
> "Based on your meals this week, you'll likely need {item_name} by {day_of_week}. Last bought {days_since} days ago."

**What's built:**
- Cron job aggregates consumed meals → required ingredient quantities → compares to recent purchases
- Estimated depletion date calculation per ingredient per household
- Threshold logic: "alert when projected depletion is within {N} days" — default N=3
- More sophisticated than Step 5 because it considers consumption *rate*, not just "have you bought it recently"

**Foundation contribution:** The destination. Smart Shopping in its full form.

---

## Locked Product Decisions

1. **Deterministic-first.** All prediction logic is rule-based SQL/cron, not ML. AI is reserved for one-time ingredient normalization migration only (Step 2).

2. **Cron-based, not real-time.** Predictions run once daily per household via Supabase pg_cron. No per-action AI calls. No real-time inference cost.

3. **Hand-written templated notification copy.** No AI generation at runtime. Templates with smart variables (item names, store names, days since, recipe names). Defer AI-generated variety; revisit after user feedback.

4. **Push + in-app notifications.** Both channels for the same predictions. In-app notification center handles missed pushes and provides history.

5. **User-configurable thresholds with sensible defaults.** "Low" is per-household, not global. Defaults shipped, users adjust as needed.

6. **Default-consumed for meal completion.** When planned date passes, meal is treated as consumed unless user opts out. Captures 90%+ accuracy with minimal user burden.

7. **Inventory model is implicit from purchases for v1.** No separate pantry table. "What you have" is inferred from "what you've bought minus what meals have used." May upgrade to explicit pantry tracking in Phase 3 based on user feedback.

8. **Shopping and meal data treated as personal data.** Includes dietary patterns, household composition signals, location data via stores, time-of-day patterns. Privacy policy document to be written separately. No sharing with third parties. No advertising use. Full deletion on household removal.

9. **Server-side prediction for v1.** Predictions run on Supabase. On-device prediction (stronger privacy story) deferred to future phase. Cost of rewriting prediction logic in Dart is not justified for v1 scale.

10. **Step sequence is fixed.** Don't skip foundation to chase headline features. Don't ship until each step is right.

---

## Open Questions

These need resolving during the relevant step's design conversation, not now:

- **Threshold defaults.** What's "low" by default for first-time users with no inventory? (Step 5/6)
- **Notification frequency caps.** Max one per item per N days? Daily digest vs. real-time? (Step 5/6)
- **Cold-start UX.** What does the app communicate during the 2-4 weeks while data accumulates? Banner? In-app hint? (Step 5)
- **AI vs. user-curated synonyms.** For Step 2's one-time migration, do we use AI for ambiguous ingredient matching, or surface ambiguity to the user as part of the migration UX? (Step 2)
- **In-app notification center placement.** Where does it live? New tab? Header icon? Settings sub-page? (Step 5)
- **APN/FCM wiring status.** Confirmation that push notification infrastructure is already in place from earlier work. (Step 5)

---

## Explicitly Out of Scope for Phase 2

- **Personalized ML models** — household-specific learning. Defer to Phase 3+ after collecting real usage data.
- **Recipe URL import** (Bug 2) — separate work, parallel track.
- **Receipt OCR** (Phase 8 in original product roadmap) — way off.
- **AI-generated notification copy at runtime** — cost not justified for marginal benefit. Templates suffice.
- **On-device prediction** — server-side is fine for v1; revisit privacy story in Phase 3.
- **Cross-household sharing of normalized ingredients** — interesting future feature ("Costco's bulk pack of paper towels is in this household's ingredient master, surface to other Costco shoppers") but well out of scope.
- **Predictive store routing for non-purchased items** — Step 1 covers "default store based on last purchase," not "if you're at Costco, suggest items from your Smith's list."

---

## Sequencing Discipline

The discipline this spec captures, in one sentence: **ship something every session, but don't ship until the thing is right.**

Day 9 demonstrated this works when followed. Phase 1 of the shopping rework took 12 commits across one Sunday, each one a coherent shippable unit, ending with a feature-complete merge that smoke-tested clean.

Phase 2 estimate: 8-12 sessions of 4-6 hours each. Roughly 4-6 weeks of evening work at the user's stated pace, with one off-day per week. Real time, not aspirational time.

The biggest risk to this discipline is "good enough, just ship it" creep during sessions when energy is low. The user has named this explicitly as a pattern from prior work (CreditStamina). Mitigation: name it when it shows up, and stop work that day rather than ship with that voice driving.

---

End of spec. Phase 2 implementation begins with Step 1 (store-routing memory) tomorrow or next session.
