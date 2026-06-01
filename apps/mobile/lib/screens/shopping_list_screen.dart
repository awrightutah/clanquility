import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import '../services/realtime_service.dart';
import '../services/active_member_service.dart';
import '../utils/membership.dart';
import '../utils/permissions.dart';
import '../utils/shopping_categories.dart';
import 'shopping_category_screen.dart';

/// Full shopping list screen with multi-store support, manual entry,
/// recipe ingredient import, purchased tracking, and category grouping.
class ShoppingListScreen extends StatefulWidget {
  const ShoppingListScreen({super.key, required this.storeId});

  /// Required from Sub-branch 2b-2 Task 4 onward: scopes the screen to a
  /// single store. ShoppingStoresScreen pushes with the tapped store's id;
  /// the cross-store chip row at the top lets the user switch via
  /// Navigator.pushReplacement.
  final String storeId;

  @override
  State<ShoppingListScreen> createState() => _ShoppingListScreenState();
}

class _ShoppingListScreenState extends State<ShoppingListScreen>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  Map<String, dynamic>? _household;
  Map<String, dynamic>? _myMembership;
  List<Map<String, dynamic>> _shoppingLists = [];
  List<Map<String, dynamic>> _shoppingItems = [];
  List<Map<String, dynamic>> _stores = [];
  // Populated via get_stores_with_counts RPC; drives the cross-store chip
  // row at the top of the screen. Distinct from _stores (which lacks counts)
  // because we want live counts on chip labels without a second client-side
  // aggregation pass.
  List<Map<String, dynamic>> _storesWithCounts = [];
  List<Map<String, dynamic>> _householdRecipes = [];
  // Lowercased necessity-category names for this household — used by the
  // Batch 5a kid wishlist flow to decide which SnackBar copy to show after
  // an add (necessity → "Added to shopping list"; otherwise → "wishlist").
  List<String> _necessityCategoriesLower = [];
  bool _isLoading = true;
  bool _groupByCategory = true;

  String? _activeListId;

  static const _categoryOrder = [
    'Produce', 'Dairy', 'Meat & Seafood', 'Pantry', 'Frozen',
    'Bakery', 'Beverages', 'Snacks', 'Household', 'Personal Care',
    'Pet Supplies', 'Other',
  ];

  static const _categoryIcons = {
    'Produce': Icons.eco_rounded,
    'Dairy': Icons.water_drop_rounded,
    'Meat & Seafood': Icons.set_meal_rounded,
    'Pantry': Icons.inventory_2_rounded,
    'Frozen': Icons.ac_unit_rounded,
    'Bakery': Icons.bakery_dining_rounded,
    'Beverages': Icons.local_cafe_rounded,
    'Snacks': Icons.cookie_rounded,
    'Household': Icons.cleaning_services_rounded,
    'Personal Care': Icons.spa_rounded,
    'Pet Supplies': Icons.pets_rounded,
    'Other': Icons.more_horiz_rounded,
  };

  static const _categoryColors = {
    'Produce': Color(0xFF4CAF50),
    'Dairy': Color(0xFF42A5F5),
    'Meat & Seafood': Color(0xFFEF5350),
    'Pantry': Color(0xFFFF9800),
    'Frozen': Color(0xFF29B6F6),
    'Bakery': Color(0xFFD4A373),
    'Beverages': Color(0xFF7E57C2),
    'Snacks': Color(0xFFFFCA28),
    'Household': Color(0xFF78909C),
    'Personal Care': Color(0xFFEC407A),
    'Pet Supplies': Color(0xFF8D6E63),
    'Other': Color(0xFF9E9E9E),
  };

  @override
  void initState() {
    super.initState();
    _loadData();
    RealtimeService.instance.shoppingVersion.addListener(_onRealtimeUpdate);
    ActiveMemberService.instance.activeMemberId.addListener(_onActiveMemberChanged);
  }

  @override
  void dispose() {
    RealtimeService.instance.shoppingVersion.removeListener(_onRealtimeUpdate);
    ActiveMemberService.instance.activeMemberId.removeListener(_onActiveMemberChanged);
    super.dispose();
  }

  void _onRealtimeUpdate() {
    if (mounted) _loadData();
  }

  // Reload when the profile switcher changes the active member so the
  // is_wishlist-routing and add_shopping_item member-id reflect the new
  // member context immediately.
  void _onActiveMemberChanged() {
    if (mounted) _loadData();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);

    try {
      // Resolves to the active kid's row when one is selected via the
      // profile switcher, otherwise the JWT holder's adult row.
      final membership = await MembershipHelper.loadActiveMembership(
        includeHouseholdJoin: true,
      );

      if (membership == null) {
        setState(() => _isLoading = false);
        return;
      }

      _myMembership = membership;
      _household = membership['households'];
      final householdId = _household!['id'];

      final results = await Future.wait<dynamic>([
        // Active list for THIS store only (post-migration 0029 there's at
        // most one is_active=true list per store; this fetch + first
        // pattern preserves the existing call-shape without a maybeSingle
        // refactor).
        Supabase.instance.client
            .from('shopping_lists')
            .select()
            .eq('household_id', householdId)
            .eq('store_id', widget.storeId)
            .eq('is_active', true)
            .order('created_at', ascending: false),
        Supabase.instance.client
            .from('stores')
            .select()
            .eq('household_id', householdId)
            .order('is_default', ascending: false),
        Supabase.instance.client
            .from('household_recipes')
            .select('id, title, ingredients')
            .eq('household_id', householdId)
            .order('title'),
        Supabase.instance.client
            .from('necessity_categories')
            .select('category')
            .eq('household_id', householdId),
        Supabase.instance.client.rpc<List<dynamic>>(
          'get_stores_with_counts',
          params: {'p_household_id': householdId},
        ),
      ]);

      _shoppingLists = List<Map<String, dynamic>>.from(results[0] as List);
      _stores = List<Map<String, dynamic>>.from(results[1] as List);
      _householdRecipes = List<Map<String, dynamic>>.from(results[2] as List);
      _necessityCategoriesLower = (results[3] as List)
          .map((row) => (row['category'] as String).toLowerCase())
          .toList(growable: false);
      _storesWithCounts = List<Map<String, dynamic>>.from(results[4] as List);

      if (_shoppingLists.isNotEmpty) {
        _activeListId = _shoppingLists.first['id'];
      } else {
        await _ensureDefaultList();
      }

      await _loadShoppingItems();
    } catch (_) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // Dedupe concurrent _createDefaultList calls within this screen instance.
  // _loadData fires from 5 sites (initState, realtime tick, active-member
  // tick, refresh button, pull-to-refresh). Without this, two near-simultaneous
  // loads could both observe 'no active list' and both call _createDefaultList,
  // producing duplicate is_active=true rows for the same store. The partial
  // unique index from migration 0029 is the DB-level backstop; this is the
  // app-level defense that avoids hitting the constraint at all in normal use.
  Future<void>? _pendingDefaultListCreation;

  Future<void> _ensureDefaultList() async {
    if (_pendingDefaultListCreation != null) {
      await _pendingDefaultListCreation;
      return;
    }
    _pendingDefaultListCreation = _createDefaultList();
    try {
      await _pendingDefaultListCreation;
    } finally {
      _pendingDefaultListCreation = null;
    }
  }

  Future<void> _createDefaultList() async {
    if (_household == null) return;

    // store_id is widget.storeId — the screen is scoped to that store.
    // shopping_lists.store_id is NOT NULL after migration 0028.
    final storeId = widget.storeId;

    try {
      final newList = await Supabase.instance.client
          .from('shopping_lists')
          .insert({
            'household_id': _household!['id'],
            'store_id': storeId,
            'name': 'Current Shopping List',
            'is_active': true,
            'created_by_member_id': _myMembership!['id'],
          })
          .select()
          .single();

      setState(() {
        _shoppingLists = [newList];
        _activeListId = newList['id'];
      });
    } on PostgrestException catch (e) {
      if (e.code == '23505') {
        // Unique violation — another path (concurrent client, or this client
        // racing across instances) created an active list for this store
        // first. Reload to pick it up rather than failing the user.
        final existing = await Supabase.instance.client
            .from('shopping_lists')
            .select()
            .eq('household_id', _household!['id'])
            .eq('store_id', storeId)
            .eq('is_active', true)
            .maybeSingle();
        if (existing != null) {
          setState(() {
            _shoppingLists = [existing];
            _activeListId = existing['id'] as String?;
          });
        }
      }
      // Other PostgrestExceptions are swallowed silently here, matching
      // the catch (_) pattern used elsewhere in this method. Errors won't
      // reach the outer catch.
    } catch (_) {}
  }

  Future<void> _loadShoppingItems() async {
    if (_activeListId == null) return;

    try {
      final items = await Supabase.instance.client
          .from('shopping_items')
          .select('*, store:stores(name)')
          .eq('shopping_list_id', _activeListId!)
          .eq('is_wishlist', false)
          .order('purchased', ascending: true)
          .order('sort_order');

      setState(() {
        _shoppingItems = List<Map<String, dynamic>>.from(items);
        _isLoading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _showAddItemSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => _AddShoppingItemSheet(
        storeId: widget.storeId,
        myMemberId: _myMembership!['id'],
        isKid: Permissions.isKid(_myMembership),
        necessityCategoriesLower: _necessityCategoriesLower,
      ),
    ).then((_) => _loadShoppingItems());
  }

  void _showAddFromRecipeSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => _AddFromRecipeSheet(
        storeId: widget.storeId,
        myMemberId: _myMembership!['id'],
        recipes: _householdRecipes,
      ),
    ).then((_) => _loadShoppingItems());
  }

  Future<void> _togglePurchased(String itemId, bool purchased) async {
    try {
      await Supabase.instance.client
          .from('shopping_items')
          .update({
            'purchased': purchased,
            'purchased_by_member_id': purchased ? _myMembership!['id'] : null,
            'purchased_at': purchased ? DateTime.now().toIso8601String() : null,
          })
          .eq('id', itemId);
      _loadShoppingItems();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not update item.')),
        );
      }
    }
  }

  Future<void> _deleteItem(String itemId) async {
    try {
      await Supabase.instance.client
          .from('shopping_items')
          .delete()
          .eq('id', itemId);
      _loadShoppingItems();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not delete item.')),
        );
      }
    }
  }

  void _showEditItemSheet(Map<String, dynamic> item) {
    final nameController = TextEditingController(text: item['name'] ?? '');
    final quantityController = TextEditingController(text: item['quantity']?.toString() ?? '');
    final unitController = TextEditingController(text: item['unit'] ?? '');
    String? selectedCategory = item['category'];

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Edit Item', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900)),
              const SizedBox(height: 20),
              TextFormField(
                controller: nameController,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Item name',
                  prefixIcon: Icon(Icons.edit_note_rounded),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: TextFormField(
                      controller: quantityController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Quantity',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 3,
                    child: TextFormField(
                      controller: unitController,
                      decoration: const InputDecoration(
                        labelText: 'Unit (e.g., lbs, oz)',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                value: selectedCategory,
                decoration: const InputDecoration(
                  labelText: 'Category',
                  prefixIcon: Icon(Icons.category_rounded),
                  border: OutlineInputBorder(),
                ),
                items: [
                  const DropdownMenuItem<String>(value: null, child: Text('No category')),
                  ...shoppingCategories.map((c) => DropdownMenuItem<String>(value: c, child: Text(c))),
                ],
                onChanged: (v) => selectedCategory = v,
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: () async {
                  final name = nameController.text.trim();
                  if (name.isEmpty) return;

                  final quantity = quantityController.text.trim();
                  final unit = unitController.text.trim();
                  final displayQuantity = quantity.isEmpty ? null : (unit.isEmpty ? quantity : '$quantity $unit');

                  try {
                    await Supabase.instance.client
                        .from('shopping_items')
                        .update({
                          'name': name,
                          'quantity': double.tryParse(quantity),
                          'unit': unit.isEmpty ? null : unit,
                          'display_quantity': displayQuantity,
                          'category': selectedCategory,
                        })
                        .eq('id', item['id']);

                    if (mounted) {
                      Navigator.pop(context);
                      _loadShoppingItems();
                    }
                  } catch (e) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Error updating item: $e')),
                      );
                    }
                  }
                },
                child: const Text('Save Changes'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Looks up the current store's display name from _stores. Falls back to
  /// 'this store' during the brief window before _loadData completes.
  String _currentStoreName() {
    for (final s in _stores) {
      if (s['id'] == widget.storeId) {
        return s['name'] as String? ?? 'this store';
      }
    }
    return 'this store';
  }

  Future<void> _doneShopping() async {
    if (_activeListId == null) return;

    final storeName = _currentStoreName();
    final purchasedCount = _shoppingItems.where((i) => i['purchased'] == true).length;
    final activeCount = _shoppingItems.where((i) => i['purchased'] != true).length;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Done shopping at $storeName?'),
        content: Text(
          '$purchasedCount purchased ${purchasedCount == 1 ? 'item' : 'items'} and '
          '$activeCount unchecked ${activeCount == 1 ? 'item' : 'items'} will be '
          'archived. The store gets a fresh list.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Done shopping'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      // archive_and_renew_list (migration 0030) archives the current list
      // (sets archived_at=now() + is_active=false) and creates the next
      // active list scoped to the same store, atomically.
      await Supabase.instance.client.rpc<void>(
        'archive_and_renew_list',
        params: {'p_list_id': _activeListId},
      );
      if (mounted) await _loadData();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not finish shopping.')),
        );
      }
    }
  }

  /// Group items by category for display
  Map<String, List<Map<String, dynamic>>> _groupItemsByCategory(List<Map<String, dynamic>> items) {
    final groups = <String, List<Map<String, dynamic>>>{};
    for (final item in items) {
      final category = (item['category'] as String?) ?? 'Other';
      groups.putIfAbsent(category, () => []).add(item);
    }
    return groups;
  }

  /// Get sorted category names
  List<String> _sortedCategories(Map<String, List<Map<String, dynamic>>> groups) {
    final cats = groups.keys.toList();
    cats.sort((a, b) {
      final ai = _categoryOrder.indexOf(a);
      final bi = _categoryOrder.indexOf(b);
      // Default categories first, in defined order; custom categories last, alphabetically
      if (ai >= 0 && bi >= 0) return ai.compareTo(bi);
      if (ai >= 0) return -1;
      if (bi >= 0) return 1;
      return a.compareTo(b);
    });
    return cats;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final unpurchasedItems = _shoppingItems.where((i) => !(i['purchased'] ?? false)).toList();
    final purchasedItems = _shoppingItems.where((i) => i['purchased'] ?? false).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Shopping List 🛒'),
        actions: [
          IconButton(
            icon: Icon(_groupByCategory ? Icons.list_rounded : Icons.category_rounded),
            onPressed: () => setState(() => _groupByCategory = !_groupByCategory),
            tooltip: _groupByCategory ? 'Show as list' : 'Group by category',
          ),
          PopupMenuButton<String>(
            onSelected: (action) {
              switch (action) {
                case 'categories':
                  Navigator.push(context, MaterialPageRoute(builder: (_) => const ShoppingCategoryScreen()));
                  break;
                case 'done':
                  _doneShopping();
                  break;
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'categories',
                child: Row(children: [
                  Icon(Icons.category_rounded, size: 20),
                  SizedBox(width: 12),
                  Text('Manage Categories'),
                ]),
              ),
              if (_activeListId != null)
                PopupMenuItem(
                  value: 'done',
                  child: Row(children: [
                    const Icon(Icons.check_circle_rounded, size: 20),
                    const SizedBox(width: 12),
                    Text('Done shopping at ${_currentStoreName()}'),
                  ]),
                ),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _loadData,
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _loadData,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  // Cross-store chip row. Always renders even when only one
                  // store exists (visual consistency). Tapping an inactive
                  // chip pushReplacement's into that store's detail view —
                  // staying on the per-tab Navigator stack from home_shell.
                  if (_storesWithCounts.isNotEmpty) ...[
                    SizedBox(
                      height: 40,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: _storesWithCounts.length,
                        separatorBuilder: (_, __) => const SizedBox(width: 8),
                        itemBuilder: (context, i) {
                          final s = _storesWithCounts[i];
                          final sid = s['id'] as String;
                          final name = s['name'] as String? ?? 'Store';
                          final count = (s['active_count'] as int?) ?? 0;
                          final selected = sid == widget.storeId;
                          return ChoiceChip(
                            label: Text('$name ($count)',
                                style: const TextStyle(fontSize: 13)),
                            selected: selected,
                            onSelected: (_) {
                              if (selected) return;
                              Navigator.of(context).pushReplacement(
                                MaterialPageRoute<void>(
                                  builder: (_) =>
                                      ShoppingListScreen(storeId: sid),
                                ),
                              );
                            },
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],

                  // Quick actions. Batch 6a followup — "From recipe" hidden
                  // from kids; recipe-ingredient bulk-add only flows via the
                  // meal-request → admin approve → meal_plans path. Kids
                  // can still use the single-item "Add item" wishlist flow.
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _showAddItemSheet,
                          icon: const Icon(Icons.add_rounded, size: 18),
                          label: const Text('Add item'),
                        ),
                      ),
                      if (!Permissions.isKid(_myMembership)) ...[
                        const SizedBox(width: 12),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _showAddFromRecipeSheet,
                            icon: const Icon(Icons.restaurant_menu_rounded, size: 18),
                            label: const Text('From recipe'),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 24),

                  // Unpurchased items
                  if (unpurchasedItems.isNotEmpty) ...[
                    Row(
                      children: [
                        Text(
                          'To buy',
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: AppColors.honeyGold.withValues(alpha:.2),
                            borderRadius: BorderRadius.circular(100),
                          ),
                          child: Text('${unpurchasedItems.length}', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    if (_groupByCategory)
                      ..._buildCategorizedItems(unpurchasedItems)
                    else
                      ...unpurchasedItems.map((item) => _ShoppingItemCard(
                            item: item,
                            onToggle: (v) => _togglePurchased(item['id'], v),
                            onDelete: () => _deleteItem(item['id']),
                            onEdit: () => _showEditItemSheet(item),
                          )),
                    const SizedBox(height: 24),
                  ],

                  // Purchased items
                  if (purchasedItems.isNotEmpty) ...[
                    Row(
                      children: [
                        Text(
                          'Purchased',
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: AppColors.grassGreen.withValues(alpha:.2),
                            borderRadius: BorderRadius.circular(100),
                          ),
                          child: Text('${purchasedItems.length}', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    ...purchasedItems.map((item) => _ShoppingItemCard(
                          item: item,
                          onToggle: (v) => _togglePurchased(item['id'], v),
                          onDelete: () => _deleteItem(item['id']),
                          onEdit: () => _showEditItemSheet(item),
                        )),
                  ],

                  // Empty state
                  if (_shoppingItems.isEmpty)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Column(
                          children: [
                            const Text('🛒', style: TextStyle(fontSize: 48)),
                            const SizedBox(height: 12),
                            Text('Your list is empty', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
                            const SizedBox(height: 4),
                            Text('Add items manually or import from a recipe.', style: Theme.of(context).textTheme.bodyMedium),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
    );
  }

  /// Build category-grouped item sections
  List<Widget> _buildCategorizedItems(List<Map<String, dynamic>> items) {
    final groups = _groupItemsByCategory(items);
    final sortedCats = _sortedCategories(groups);
    final widgets = <Widget>[];

    for (final cat in sortedCats) {
      final catItems = groups[cat]!;
      final color = _categoryColors[cat] ?? Colors.grey;
      final icon = _categoryIcons[cat] ?? Icons.label_rounded;

      widgets.add(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Category header
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 8, top: 8),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha:.12),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(icon, size: 16, color: color),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    cat,
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                      color: color,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha:.1),
                      borderRadius: BorderRadius.circular(100),
                    ),
                    child: Text(
                      '${catItems.length}',
                      style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: color),
                    ),
                  ),
                ],
              ),
            ),
            // Items in category
            ...catItems.map((item) => _ShoppingItemCard(
                  item: item,
                  onToggle: (v) => _togglePurchased(item['id'], v),
                  onDelete: () => _deleteItem(item['id']),
                  onEdit: () => _showEditItemSheet(item),
                )),
            const SizedBox(height: 4),
          ],
        ),
      );
    }

    return widgets;
  }
}

class _ShoppingItemCard extends StatelessWidget {
  const _ShoppingItemCard({
    required this.item,
    required this.onToggle,
    required this.onDelete,
    required this.onEdit,
  });

  final Map<String, dynamic> item;
  final void Function(bool) onToggle;
  final VoidCallback onDelete;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final name = item['name'] ?? 'Unknown';
    final rawQuantity = item['display_quantity'] ?? item['quantity'];
    final quantity = rawQuantity is num
        ? (rawQuantity == rawQuantity.truncate()
            ? rawQuantity.toInt().toString()
            : rawQuantity.toString())
        : rawQuantity?.toString();
    final purchased = item['purchased'] ?? false;
    final store = item['store']?['name'];
    final category = item['category'];

    return Dismissible(
      key: ValueKey(item['id']),
      direction: DismissDirection.endToStart,
      onDismissed: (_) => onDelete(),
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 16),
        decoration: BoxDecoration(
          color: AppColors.coral.withValues(alpha:.1),
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Icon(Icons.delete_outline_rounded, color: AppColors.coral),
      ),
      child: Card(
        margin: const EdgeInsets.only(bottom: 6),
        child: InkWell(
          onTap: onEdit,
          borderRadius: BorderRadius.circular(12),
          child: CheckboxListTile(
          value: purchased,
          onChanged: (v) => onToggle(v ?? false),
          title: Text(
            name,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              decoration: purchased ? TextDecoration.lineThrough : null,
              color: purchased ? Colors.grey : null,
            ),
          ),
          subtitle: Row(
            children: [
              if (quantity != null) ...[
                Text(quantity, style: const TextStyle(fontSize: 13)),
                const SizedBox(width: 8),
              ],
              if (store != null) ...[
                Icon(Icons.storefront_rounded, size: 14, color: AppColors.skyBlue),
                const SizedBox(width: 2),
                Text(store, style: const TextStyle(fontSize: 13)),
                const SizedBox(width: 8),
              ],
              if (category != null) ...[
                Icon(Icons.label_outline_rounded, size: 14, color: Colors.grey.shade500),
                const SizedBox(width: 2),
                Text(category, style: const TextStyle(fontSize: 13)),
              ],
            ],
          ),
          controlAffinity: ListTileControlAffinity.leading,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        ),
        ),
      ),
    );
  }
}

class _AddShoppingItemSheet extends StatefulWidget {
  const _AddShoppingItemSheet({
    required this.storeId,
    required this.myMemberId,
    required this.isKid,
    required this.necessityCategoriesLower,
  });

  final String storeId;
  final String myMemberId;
  // Routes adds through the add_item_to_store RPC. When isKid=true the
  // server may set is_wishlist=true if the category isn't a necessity;
  // the kid SnackBar copy varies accordingly.
  final bool isKid;
  // Lowercased necessity-category names for the household; used purely to
  // pick the right SnackBar copy after a successful kid add. Server is the
  // source of truth for the actual is_wishlist decision.
  final List<String> necessityCategoriesLower;

  @override
  State<_AddShoppingItemSheet> createState() => _AddShoppingItemSheetState();
}

class _AddShoppingItemSheetState extends State<_AddShoppingItemSheet> {
  final _nameController = TextEditingController();
  final _quantityController = TextEditingController();
  final _unitController = TextEditingController();
  String? _selectedCategory;
  bool _isLoading = false;

  @override
  void dispose() {
    _nameController.dispose();
    _quantityController.dispose();
    _unitController.dispose();
    super.dispose();
  }

  Future<void> _addItem() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter an item name.')),
      );
      return;
    }

    setState(() => _isLoading = true);

    try {
      final quantity = _quantityController.text.trim();
      final unit = _unitController.text.trim();
      final displayQuantity = quantity.isEmpty ? null : (unit.isEmpty ? quantity : '$quantity $unit');
      final parsedQuantity = double.tryParse(quantity);

      // Unified path via add_item_to_store RPC (migration 0031). The RPC
      // resolves household_id + active list_id from store_id, applies the
      // kid+necessity wishlist routing internally, and inserts the row.
      await Supabase.instance.client.rpc<void>('add_item_to_store', params: {
        'p_member_id': widget.myMemberId,
        'p_store_id': widget.storeId,
        'p_name': name,
        'p_quantity': parsedQuantity,
        'p_unit': unit.isEmpty ? null : unit,
        'p_category': _selectedCategory,
        'p_display_quantity': displayQuantity,
        // p_source_recipe_id / p_source_meal_plan_id: null (manual add).
      });

      if (mounted) {
        if (widget.isKid) {
          // Server is source-of-truth for is_wishlist; this mirror logic
          // picks the matching SnackBar copy (necessity → on the list;
          // otherwise → pending wishlist approval).
          final isNecessity = _selectedCategory != null &&
              widget.necessityCategoriesLower
                  .contains(_selectedCategory!.toLowerCase());
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(isNecessity
                  ? 'Added to shopping list'
                  : 'Added to wishlist — waiting for approval'),
            ),
          );
        }
        Navigator.pop(context);
      }
    } catch (e) {
      debugPrint('add shopping item failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not add item: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Add Shopping Item', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900)),
            const SizedBox(height: 20),

            // Item name
            TextFormField(
              controller: _nameController,
              textCapitalization: TextCapitalization.words,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Item name',
                prefixIcon: Icon(Icons.shopping_basket_rounded),
                border: OutlineInputBorder(),
                hintText: 'e.g., Milk, Eggs, Bread',
              ),
            ),
            const SizedBox(height: 16),

            // Quantity and unit
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _quantityController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Quantity',
                      prefixIcon: Icon(Icons.format_list_numbered_rounded),
                      border: OutlineInputBorder(),
                      hintText: 'e.g., 2, 1.5',
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextFormField(
                    controller: _unitController,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(
                      labelText: 'Unit',
                      border: OutlineInputBorder(),
                      hintText: 'e.g., gal, lbs, dozen',
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Category selector with emoji chips
            Text('Category', style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            SizedBox(
              height: 42,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: shoppingCategories.length,
                separatorBuilder: (_, __) => const SizedBox(width: 6),
                itemBuilder: (context, i) {
                  final cat = shoppingCategories[i];
                  final selected = _selectedCategory == cat;
                  return ChoiceChip(
                    label: Text('${shoppingCategoryEmojis[cat]} ${cat}'),
                    selected: selected,
                    onSelected: (_) => setState(() => _selectedCategory = selected ? null : cat),
                  );
                },
              ),
            ),
            const SizedBox(height: 24),

            // Store picker removed — the parent ShoppingListScreen is
            // scoped to widget.storeId, which the RPC consumes directly.
            FilledButton(
              onPressed: _isLoading ? null : _addItem,
              child: _isLoading
                  ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Text('Add item'),
            ),
          ],
        ),
      ),
    );
  }
}

class _AddFromRecipeSheet extends StatefulWidget {
  const _AddFromRecipeSheet({
    required this.storeId,
    required this.myMemberId,
    required this.recipes,
  });

  final String storeId;
  final String myMemberId;
  // isKid removed as a Batch 6a followup — this sheet is now adult-only;
  // the entry-point button on shopping_list_screen is gated by
  // Permissions.isKid before reaching this sheet.
  final List<Map<String, dynamic>> recipes;

  @override
  State<_AddFromRecipeSheet> createState() => _AddFromRecipeSheetState();
}

class _AddFromRecipeSheetState extends State<_AddFromRecipeSheet> {
  String? _selectedRecipeId;
  bool _isLoading = false;
  List<String> _selectedIngredients = [];

  @override
  Widget build(BuildContext context) {
    final selectedRecipe = widget.recipes.where((r) => r['id'] == _selectedRecipeId).firstOrNull;
    final ingredients = selectedRecipe?['ingredients'] as List<dynamic>? ?? [];

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Add from Recipe', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900)),
            const SizedBox(height: 20),

            // Recipe selection
            DropdownButtonFormField<String>(
              value: _selectedRecipeId,
              decoration: const InputDecoration(
                labelText: 'Choose a recipe',
                prefixIcon: Icon(Icons.menu_book_rounded),
                border: OutlineInputBorder(),
              ),
              items: widget.recipes.map((r) => DropdownMenuItem<String>(
                value: r['id'],
                child: Text(r['title'] ?? 'Untitled', overflow: TextOverflow.ellipsis),
              )).toList(),
              onChanged: (v) {
                setState(() {
                  _selectedRecipeId = v;
                  _selectedIngredients = [];
                });
              },
            ),
            const SizedBox(height: 16),

            // Ingredients list
            if (ingredients.isNotEmpty) ...[
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Select ingredients:', style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                  TextButton(
                    onPressed: () {
                      setState(() {
                        if (_selectedIngredients.length == ingredients.length) {
                          _selectedIngredients = [];
                        } else {
                          _selectedIngredients = ingredients.map((ing) {
                            return ing is String ? ing : (ing['raw']?.toString() ?? ing.toString());
                          }).toList().cast<String>();
                        }
                      });
                    },
                    child: Text(_selectedIngredients.length == ingredients.length ? 'Deselect all' : 'Select all'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Container(
                constraints: const BoxConstraints(maxHeight: 200),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: ingredients.length,
                  itemBuilder: (context, i) {
                    final ing = ingredients[i];
                    final text = ing is String ? ing : (ing['raw']?.toString() ?? ing.toString());
                    final isSelected = _selectedIngredients.contains(text);

                    return CheckboxListTile(
                      value: isSelected,
                      onChanged: (v) {
                        setState(() {
                          if (v == true) {
                            _selectedIngredients.add(text);
                          } else {
                            _selectedIngredients.remove(text);
                          }
                        });
                      },
                      title: Text(text, style: const TextStyle(fontSize: 14)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
                      dense: true,
                    );
                  },
                ),
              ),
              const SizedBox(height: 16),
            ],

            FilledButton(
              onPressed: _isLoading || _selectedIngredients.isEmpty ? null : _addIngredients,
              child: _isLoading
                  ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : Text('Add ${_selectedIngredients.length} ingredient${_selectedIngredients.length == 1 ? '' : 's'}'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _addIngredients() async {
    setState(() => _isLoading = true);

    try {
      // Adult-only path (entry-point gated by Permissions.isKid on the
      // parent screen). N RPC calls via add_item_to_store — one per
      // ingredient. Known v1 limitation: ingredient strings aren't
      // parsed, so quantity/unit/category land null. Improving that is
      // a future task (likely Phase 4+ once we add a parser).
      for (final ing in _selectedIngredients) {
        await Supabase.instance.client.rpc<void>('add_item_to_store', params: {
          'p_member_id': widget.myMemberId,
          'p_store_id': widget.storeId,
          'p_name': ing,
          'p_source_recipe_id': _selectedRecipeId,
          // p_quantity / p_unit / p_category / p_display_quantity /
          // p_source_meal_plan_id all default to null.
        });
      }

      if (mounted) Navigator.pop(context);
    } catch (e) {
      debugPrint('add ingredients failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not add ingredients: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }
}
