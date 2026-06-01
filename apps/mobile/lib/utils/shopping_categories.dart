// Shared shopping category constants used by all shopping forms.
// Extracted from shopping_list_screen.dart's _AddShoppingItemSheet
// on 2026-06-01 (Smart Shopping Phase 2 Step 1b) to prevent data
// fragmentation between Quick Add (ShoppingStoresScreen) and the
// regular Add Item form (ShoppingListScreen).
//
// The category names here must match the category names used in
// necessity_categories rows for kid wishlist routing to work
// correctly via the add_item_to_store RPC.

const List<String> shoppingCategories = [
  'Produce',
  'Dairy',
  'Meat & Seafood',
  'Pantry',
  'Frozen',
  'Bakery',
  'Beverages',
  'Snacks',
  'Household',
  'Personal Care',
  'Pet Supplies',
  'Other',
];

const Map<String, String> shoppingCategoryEmojis = {
  'Produce': '🥬',
  'Dairy': '🥛',
  'Meat & Seafood': '🥩',
  'Pantry': '🫘',
  'Frozen': '🧊',
  'Bakery': '🍞',
  'Beverages': '☕',
  'Snacks': '🍪',
  'Household': '🧹',
  'Personal Care': '🧴',
  'Pet Supplies': '🐾',
  'Other': '📦',
};
