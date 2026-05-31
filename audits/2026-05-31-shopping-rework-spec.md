# Shopping Rework Spec — 2026-05-31

Working narrative for the multi-session shopping experience rework. This doc plays the same role for shopping that audits/2026-05-30-day7-tester-bugs.md played for the Bug 1 calendar work across Days 7-8: it accumulates decisions, captures open questions, tracks phasing, and survives across sessions.

The spec is living. Sub-branches that land may revise sections of the spec. New decisions update the spec inline. Open questions get answered and moved to "Locked decisions." When the rework is complete, the spec gets a closing section and the work moves to commit-message-as-documentation.

---

## Product vision

### What we're building

Clanquility's shopping experience, designed to be substantially better than what Apple Reminders, Google Keep, or other generic list apps offer. The goal isn't a checklist-with-extras; it's a household-aware, store-organized, recipe-integrated, history-tracking shopping system that family users will choose over the alternatives.

### What "better" means concretely

The user opens the Shopping tab and sees their *stores*, not a single flat list. Tap a store, see what's needed there. Add items either manually, from a recipe (one tap to import all ingredients), or via quick-add chips for things you buy often. Kids contribute via a wishlist that admins review and assign to a store on approval. The list tracks history so predictive suggestions ("you usually buy milk weekly — did you forget?") become possible over time. Budget mode lets users set a spending cap and see a running total based on prices they've entered or scanned from receipts.

### What this is NOT

- **Not** a live-pricing API integration. Grocery APIs are gated (Kroger, Walmart) or scraping-fragile (Apify-style approaches). Users enter their own prices, or future receipt OCR captures them.
- **Not** store-layout-aware aisle ordering. No data source exists at usable scale; would require user-crowdsourced data that's its own product.
- **Not** a multi-store-per-item model. Items belong to one store. If a user genuinely wants the same item at two stores, they add it twice. Acceptably rare for v1+.

### Differentiators (the "why switch" pitch)

1. **Household-native** — your list is the family's list, no setup, no shared-iCloud-album dance.
2. **Recipe → shopping list** — one tap from a recipe imports all ingredients to the right store.
3. **Store-organized natively** — the app organizes by store, the way you actually shop, not by item type.
4. **Kid wishlist with approval workflow** — kids can ask, parents decide what makes it onto the list and at which store.
5. **History + predictions** — over time the app learns your patterns and surfaces forgotten staples.
6. **Budget awareness** — running totals based on your own historical pricing, optional budget cap with prioritization help.

---

## Current state (as of 2026-05-31)

Documented via three investigation passes on shopping_list_screen.dart (1177 lines) plus accompanying schema files and audit history. Detailed findings:

### What's built

- **shopping_lists** table per household with archive support. `is_active` boolean + `archived_at`. Default name "Current Shopping List."
- **shopping_items** table with: name, quantity, unit, display_quantity (denormalized), category (text), store_id (FK to stores), purchased (bool) + purchased_at + purchased_by_member_id, sort_order, lineage via source_recipe_id + source_meal_plan_id, added_by_member_id, is_wishlist (added in migration 0016).
- **stores** table per household. Read by the manual-add form; no creation UI exists in shopping_list_screen.dart.
- **RLS:** household-scoped on shopping_lists and shopping_items (any member). Trigger gates is_wishlist mutations to admins (migration 0021).
- **RPCs:** `add_shopping_item` (SECURITY DEFINER, kid-safe insert with wishlist routing). `approve_wishlist_item` (admin-only, flips is_wishlist to false).
- **Manual add form** (_AddShoppingItemSheet) with: name, quantity, unit, category (horizontal ChoiceChip row of 12 fixed categories), store (optional Dropdown). Kid path routes through add_shopping_item RPC. Adult path direct INSERT.
- **From-recipe form** (_AddFromRecipeSheet) with: recipe picker, ingredient checkboxes, select-all toggle, bulk insert. Adult-only (kid path explicitly removed in Batch 6a followup).
- **List rendering:** two sections — "To buy" (active items) and "Purchased" (struck-through, persistent until bulk-cleared). Optional toggle: category-grouped vs. flat for the To-buy section. Purchased always flat. Empty state when no items at all.
- **Item card:** Dismissible swipe-left-to-delete (no confirmation), tap to edit, checkbox to toggle purchased. Subtitle shows quantity, store (inline 🏪 icon + name), category (inline 🏷️ + name).
- **Realtime sync** via RealtimeService.instance.shoppingVersion listener — household members see changes from other members in near-realtime.
- **Kid awareness:** ActiveMemberService.instance.activeMemberId determines current member; Permissions.isKid gates the From-recipe button visibility and the add_item routing.
- **Categories:** 12 hardcoded strings (Produce, Dairy, Meat & Seafood, Pantry, Frozen, Bakery, Beverages, Snacks, Household, Personal Care, Pet Supplies, Other) with matching emojis, icons, and Color constants. Per-household customization is via a separate ShoppingCategoryScreen accessed from the popup menu. Categories are independent of the calendar_tags system.

### What's strong and should be preserved

- The two-section To-buy + Purchased pattern. Maps cleanly to the "cross out, then bulk-delete on done" UX from the vision.
- The fast-capture UX: autofocus on name field, swipe-delete with no confirmation, single-button "Add item" submit. Optimizes for someone standing in the kitchen mid-cooking.
- The kid wishlist routing through `add_shopping_item` RPC. Schema and policy work is already done and proven.
- Realtime sync. Household members already see each other's changes.
- The recipe → list bulk-insert path. The plumbing exists; the lossiness around quantity/unit/category is fixable inside the existing flow.

### What's missing or wrong-shaped for the vision

| Feature | Status | Gap |
|---|---|---|
| Store as primary navigation axis | Schema supports it (`store_id`); UI doesn't | Build store-first navigation: stores-list view → store-detail view |
| Store management UI | None visible in this screen | Need create/edit/delete stores UI |
| Quick-add chips for common items | Doesn't exist | New per-household "favorites" concept + UI |
| In-stock subtraction ("I have this already") | Doesn't exist | New action distinct from delete |
| Predictive suggestions | Doesn't exist | Requires purchase history table + algorithm + surfacing UI |
| Budget mode + running total | Doesn't exist | Requires price column + budget setting + total calculation + over-budget UI |
| Manual price entry per item | Doesn't exist | New optional `price` column |
| Receipt OCR | Doesn't exist | Future Tier 2.5 — requires OCR library integration |
| Barcode scanning + Open Food Facts | Doesn't exist | Future Tier 2.5 — requires barcode scanner library |
| Recipe fanout lossiness (no quantity/category/store parsing) | Bulk-inserts raw ingredient strings | Fix during store-first rework |
| Kid wishlist + store-on-approval | Currently kid CAN pick a store; we want them not to | Remove kid store-picker; amend approve_wishlist_item RPC to take store_id |

---

## Target state

After the full rework, the user experience is:

### Shopping tab top level
- Vertical list of stores. Each store row: emoji or icon, store name, count of active items.
- "Add store" button or FAB for admins to create new stores.
- Tap a store → enter store-detail view.

### Store-detail view
- Same two-section pattern as today: "To buy" + "Purchased."
- Optional category-grouping toggle within the store.
- Items below show name, quantity, optional price (if user entered), inline category.
- Per-store "Done shopping" button (clears purchased items in this store only).
- Quick-add chips row at top: household-customizable list of common items ("milk, bread, eggs, butter").
- "Add item" button — manual form. Store pre-selected from context.
- "From recipe" button — recipe fanout. User picks recipe + ingredients. All go to this store.
- Per-store running total (if budget mode enabled).

### Add-item form (manual)
- Name, quantity, unit (as today).
- Category chips (as today).
- Optional price field.
- "Mark as in-stock" toggle — if checked, item is added directly to a "Stocked" log instead of the active list (foundation for predictive suggestions).
- Store: not visible to the user (pre-selected from store context).

### Wishlist (kid view)
- Kid sees a single "Wishlist" view, not store-organized.
- Kid adds items: name, quantity, optional category. No store picker.
- Items land in is_wishlist=true state via the existing RPC.

### Approval (admin view)
- Admin Approvals screen shows pending wishlist items.
- Tap a wishlist item → approval modal with store picker + optional category override.
- Approve → calls amended `approve_wishlist_item(p_item_id, p_store_id, p_category?)` RPC. Sets is_wishlist=false, sets store_id, optionally overrides category.
- Reject → marks rejected or deletes (current behavior).

### Predictive suggestions
- "Suggestions" section on store-detail views or on the tab top-level.
- Items the household has historically bought from this store but isn't currently on the list, with frequency info ("usually weekly, last bought 8 days ago").
- One-tap add.

### Budget mode (optional, per-list or per-trip)
- Settings or AppBar option: "Set budget for this trip."
- Running total displayed prominently in store-detail view.
- Items show their entered price inline.
- When total exceeds budget, items beyond budget visually demote or warning surfaces.
- "Suggest essentials only" mode: app proposes which items to keep within budget based on recipe-essential flag or user override.

---

## Phasing

Multi-session work. Each phase is independently shippable to TestFlight.

### Phase 1: Store-first navigation foundation

Goal: rework the Shopping tab so stores are the primary axis. Get this in front of testers ASAP.

Includes:
- Stores-list view at the tab root
- Store-detail view (replicates existing To-buy + Purchased pattern)
- Store management UI (create/edit/delete stores)
- Store pre-selection on add-item form when entered from store context
- Recipe-fanout entry from within store context (store inferred)
- Migration: handle existing items with null store_id (assign to "Unassigned" pseudo-store OR backfill to a default)

Schema work:
- Decision: "Unassigned" pseudo-store or required store-on-create? See Open Questions below.
- Likely no new columns. Possibly a default_store_id on households.

Resolved (2026-05-31): backfill is trivial. No real store assignments exist anywhere. Plan: seed a single 'Grocery Store' marked is_default=true at household setup; one UPDATE shopping_items SET store_id = <household's default store id> WHERE store_id IS NULL AND household_id = <h>, applied per-household during the migration. New households get the seed via the household_setup_screen seed loop (matching the calendar_tags pattern at household_setup_screen.dart:104-119).

### Phase 2: Kid wishlist + admin store-on-approval

Goal: rework the wishlist flow per the locked decision (kid storeless, admin assigns).

Includes:
- Remove store picker from kid path in _AddShoppingItemSheet (UI gating only; RPC stays compatible)
- Force p_store_id: null in the kid RPC call
- Amend approve_wishlist_item RPC to take p_store_id (and optionally p_category)
- Update admin Approvals screen to show store picker on approval

Schema work:
- New RPC version of approve_wishlist_item
- No table changes

### Phase 3: Quick-add chips

Goal: per-household customizable list of common items appears as quick-add chips at the top of each store-detail view.

Schema work:
- New `quick_add_items` table or `is_quick_add` flag on a new household-level config table
- Admin management UI for adding/removing quick-add items

UI work:
- Chips row at top of store-detail view
- Tap a chip → instant-add (no modal) to current store
- Settings UI for managing quick-add items per household

### Phase 4: In-stock subtraction + purchase history foundation

Goal: introduce the "I have this in stock" concept as a distinct action from delete, and start logging purchase history.

Schema work:
- New `shopping_purchase_history` table (or repurpose how purchased items archive)
- When user marks purchased: write history row at "Clear Purchased" time
- "Mark as in-stock" path: archive item without going through purchased state

History captures: item name, household, store, member who marked it, when, optional price.

This unlocks predictive suggestions (Phase 5) and budget mode (Phase 6).

### Phase 5: Predictive suggestions

Goal: surface items the household historically buys that aren't currently on the list.

Algorithm:
- For each store in the household, look at purchase history over last N weeks
- Items bought ≥M times not currently on the store's list
- Sort by recency or frequency
- Display as a "Suggestions" section above the To-buy section

UI work:
- New section in store-detail view
- Tap suggestion to add (with category + store auto-filled from history)

Defer: smart algorithms (e.g., gap analysis, day-of-week patterns). Start with a simple frequency-based algorithm.

### Phase 6: Manual prices + budget mode

Goal: optional price field on items + per-trip budget with running total.

Schema work:
- Add `price` column to shopping_items (decimal, nullable)
- Add `budget_amount` to shopping_lists or new shopping_trips table
- Add `essential` boolean on shopping_items (for "suggest essentials only" mode)

UI work:
- Optional price field on add/edit forms
- Running total displayed in store-detail view
- Budget setting screen
- Over-budget warning UX
- "Essentials only" toggle

### Phase 7 (Tier 2.5): Barcode scan + Open Food Facts integration

Goal: scan a barcode while at the store, get product name/image/category auto-filled.

Schema work:
- Possibly add `barcode` and `image_url` columns to shopping_items or a new products lookup table

UI work:
- Barcode scanner camera view
- Auto-fill from Open Food Facts response
- Fallback to manual entry if barcode unknown

Tools:
- mobile_scanner Flutter package
- Open Food Facts public API (free)

### Phase 8 (Tier 2.5): Receipt OCR

Goal: post-shopping receipt photo → extract items + prices → update purchase history with real prices.

Schema work:
- Likely uses existing purchase_history with prices populated
- New `receipts` table for raw scan storage and review

UI work:
- Camera screen for receipt photo
- OCR processing (server-side or on-device)
- Review/edit screen for OCR output
- Confirm → bulk-update history with prices

Tools:
- Tesseract, Google Vision, or AWS Textract (cost trade-offs)

---

## Locked decisions

- **Store is the primary organizing principle.** Stores-list at tab root; store-detail views below.
- **Stores are per-household.** Already in schema. Each household manages its own.
- **One item belongs to one store** (no multi-store-per-item). Acceptably rare to add the same item twice.
- **Kid wishlist items are storeless.** Kids don't pick stores. Admin assigns store at approval time.
- **Kid picks category at add time, admin picks store at approval time.** Categories are item-attribute; store is purchase-decision.
- **Per-store "Done shopping"** rather than global. Each store's purchased items clear independently.
- **Recipe fanout happens within store context.** User enters a store's view first, then "From recipe" — ingredients all go to that store.
- **No live grocery pricing API.** Manual price entry + future receipt OCR are the path. Tier 3 scraping/API approaches are blocked by external reality (gated APIs, fragile scrapers).
- **No store-layout aisle ordering for v1.** Data source doesn't exist; deferred indefinitely.
- **Categories stay app-level fixed (the 12), but per-household customization exists via ShoppingCategoryScreen.** Not the same as calendar_tags. Different mental model: categories are about *what something is*, calendar tags are about *how the user wants to organize their schedule*.
- **No "Unassigned" pseudo-store.** The original concept was a fallback for items without a store. Replaced by: every household gets a single seeded store at creation (marked is_default=true), so there's always somewhere for items to go. Cleaner mental model, no special-case bucket.
- **is_default column repurposed.** The pre-existing is_default boolean on the stores table is used as 'this household's default store for new items.' New items default to is_default=true store. Admin can change which store is the household default. Default store cannot be deleted while it has items (forces admin to reassign or designate a new default first).
- **Single seeded store at household creation.** New households get exactly one seeded store named 'Grocery Store' with is_default=true. User renames or replaces immediately as they discover their actual stores. Pattern diverges from calendar_tags seed (which seeded 4 example tags) because stores are too household-specific to anticipate — brand names like 'Costco' or 'Trader Joe's' might not be relevant to all households.

---

## Open questions

These need decisions before relevant phases start.

### Quick-add items: shared household list or per-member?
- Shared: one list of "milk/bread/eggs" for the whole household.
- Per-member: kids have different staples than parents.

Lean: shared. Simpler. Per-member can be added later if real demand surfaces.

### Predictive suggestion algorithm specifics
- Window: last N weeks (4? 6? 12?)
- Threshold: bought ≥M times (1? 3?)
- Display limit: how many suggestions to show

Defer to Phase 5 design.

### Budget mode scope
- Per-list, per-trip, or per-store?
- Includes all stores or one store at a time?

Defer to Phase 6 design.

### "Mark as in-stock" — separate action or repurposed purchased?
- Option A: distinct action "I have this." Item archives to history without going through purchased state.
- Option B: "I have this" = marking purchased + immediate bulk-clear. Same code path.

Lean: A. Cleaner semantics. Foundation for "Stocked items" view if we ever build it.

### Recipe fanout in storeless context (Shopping tab top-level)
- Option A: Disable "From recipe" at the tab top-level. Force user to enter a store first.
- Option B: Show a store picker as part of recipe fanout flow.

Lean: B if the user just dropped into the tab and wants to import a recipe before navigating to a store. More flexible.

---

## Where stores currently get created

**Resolved 2026-05-31 via codebase-wide grep: nowhere.**

The schema (0001_initial_schema.sql), RLS policy, read path, store:stores(name) join on item-load, and DropdownButtonFormField render in _AddShoppingItemSheet are all pre-staged. But no code anywhere INSERTs into the stores table. Across apps/mobile/lib, services/api, and supabase/migrations, every reference to stores is read-only.

Reality on the ground today:
- Every household has zero stores.
- The store-picker dropdown shows only the 'No specific store' sentinel option.
- Every shopping_items row has store_id = null.
- The store:stores(name) join returns null for every item.
- The 🏪 icon + store name in _ShoppingItemCard.subtitle never renders for any user — it's dead UI.

Implication for Phase 1: it's effectively greenfield for stores. No legacy data to migrate, no risk of stomping on existing assignments. The store-picker dropdown, the icon-and-name subtitle render path, and the store_id column are all wired and waiting — Phase 1 closes the loop by adding the write path + seed + management UI.

The is_default column on the stores table is also pre-staged and unused. Phase 1 puts it to work (see Locked Decisions).

---

## Spec status

- Created: 2026-05-31
- Last updated: 2026-05-31 (after store-creation grep + Q1-Q4 decisions)
- Status: Phase 0 (planning) → about to enter Phase 1 design.
- Today's session resolved: where stores currently get created (nowhere), seed shape (single 'Grocery Store' with is_default=true), is_default semantics (user's default for new items), no Unassigned pseudo-store needed.
- Document owner: Andrew + Claude across sessions; spec is the working narrative; updates happen inline as decisions land.
