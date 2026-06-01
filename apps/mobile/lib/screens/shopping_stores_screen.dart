import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import '../services/realtime_service.dart';
import '../services/active_member_service.dart';
import '../utils/membership.dart';
import '../utils/permissions.dart';
import '../utils/shopping_categories.dart';
import 'add_edit_store_screen.dart';
import 'shopping_list_screen.dart';

/// Shopping tab root. Lists the household's stores with active item
/// counts and routes into ShoppingListScreen for the per-store detail
/// view. Admin users see an AppBar 'Add Store' action.
///
/// Currently not yet wired into the bottom navigation — Task 3 of
/// Sub-branch 2b-2 swaps the tab target from ShoppingListScreen to
/// this screen.
class ShoppingStoresScreen extends StatefulWidget {
  const ShoppingStoresScreen({super.key});

  @override
  State<ShoppingStoresScreen> createState() => _ShoppingStoresScreenState();
}

class _ShoppingStoresScreenState extends State<ShoppingStoresScreen>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  Map<String, dynamic>? _myMembership;
  List<Map<String, dynamic>> _stores = [];
  List<String> _necessityCategoriesLower = [];
  bool _isLoading = true;
  String? _errorMessage;

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

  void _onActiveMemberChanged() {
    if (mounted) _loadData();
  }

  Future<void> _loadData() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final membership = await MembershipHelper.loadActiveMembership(
        includeHouseholdJoin: true,
      );
      if (membership == null) {
        if (!mounted) return;
        setState(() => _isLoading = false);
        return;
      }

      final household = membership['households'] as Map<String, dynamic>?;
      if (household == null) {
        if (!mounted) return;
        setState(() => _isLoading = false);
        return;
      }

      final results = await Future.wait<dynamic>([
        Supabase.instance.client.rpc<List<dynamic>>(
          'get_stores_with_counts',
          params: {'p_household_id': household['id']},
        ),
        Supabase.instance.client
            .from('necessity_categories')
            .select('category')
            .eq('household_id', household['id']),
      ]);

      if (!mounted) return;
      setState(() {
        _myMembership = membership;
        _stores = List<Map<String, dynamic>>.from(results[0] as List);
        _necessityCategoriesLower = (results[1] as List)
            .map((row) => ((row as Map<String, dynamic>)['category'] as String).toLowerCase())
            .toList(growable: false);
        _isLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _errorMessage = "Couldn't load stores. Check your connection.";
        _isLoading = false;
      });
    }
  }

  Future<void> _addStore() async {
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => const AddEditStoreScreen(),
      ),
    );
    if (result == true && mounted) {
      await _loadData();
    }
  }

  Future<void> _editStore(Map<String, dynamic> store) async {
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => AddEditStoreScreen(existingStore: store),
      ),
    );
    if (result == true && mounted) {
      await _loadData();
    }
  }

  void _openStore(Map<String, dynamic> store) {
    final storeId = store['id'] as String;
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ShoppingListScreen(storeId: storeId),
      ),
    );
  }

  Future<void> _quickAddItem() async {
    if (_myMembership == null || _stores.isEmpty) return;
    final householdId =
        (_myMembership!['households'] as Map<String, dynamic>?)?['id'] as String?;
    if (householdId == null) return;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _QuickAddShoppingItemSheet(
        householdId: householdId,
        myMemberId: _myMembership!['id'] as String,
        isKid: Permissions.isKid(_myMembership),
        necessityCategoriesLower: _necessityCategoriesLower,
        stores: _stores,
      ),
    );
    if (mounted) await _loadData();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final canManage = Permissions.canManageStores(_myMembership);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Shopping 🛒'),
        actions: [
          if (canManage)
            IconButton(
              icon: const Icon(Icons.add_rounded),
              onPressed: _addStore,
              tooltip: 'Add Store',
            ),
        ],
      ),
      body: _buildBody(canManage),
    );
  }

  Widget _buildBody(bool canManage) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.grey),
              const SizedBox(height: 12),
              Text(
                _errorMessage!,
                style: Theme.of(context).textTheme.bodyLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton(onPressed: _loadData, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }
    if (_stores.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.storefront_outlined, size: 64, color: Colors.grey),
              const SizedBox(height: 12),
              Text(
                'No stores yet',
                style: Theme.of(context)
                    .textTheme
                    .titleLarge
                    ?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 4),
              Text(
                canManage
                    ? 'Tap + to create your first store.'
                    : 'Ask a household admin to add a store.',
                style: Theme.of(context).textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadData,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _QuickAddCard(onTap: _quickAddItem),
          for (final store in _stores)
            _StoreCard(
              store: store,
              onTap: () => _openStore(store),
              onLongPress: canManage ? () => _editStore(store) : null,
            ),
          if (_stores.length == 1 && canManage)
            const _HintCard(),
        ],
      ),
    );
  }
}

class _StoreCard extends StatelessWidget {
  const _StoreCard({
    required this.store,
    required this.onTap,
    this.onLongPress,
  });

  final Map<String, dynamic> store;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final name = store['name'] as String? ?? 'Store';
    final isDefault = store['is_default'] == true;
    final activeCount = (store['active_count'] as int?) ?? 0;
    final countLabel = '$activeCount ${activeCount == 1 ? 'item' : 'items'}';

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              SizedBox(
                width: 36,
                height: 36,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    const Icon(
                      Icons.storefront_rounded,
                      size: 28,
                      color: AppColors.skyBlue,
                    ),
                    if (isDefault)
                      const Positioned(
                        top: -2,
                        right: -2,
                        child: Icon(
                          Icons.star_rounded,
                          size: 14,
                          color: AppColors.honeyGold,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      name,
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      countLabel,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Colors.grey.shade600,
                          ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: Colors.grey.shade400),
            ],
          ),
        ),
      ),
    );
  }
}

class _HintCard extends StatelessWidget {
  const _HintCard();

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(top: 8, bottom: 12),
      color: AppColors.skyBlue.withValues(alpha: .08),
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            const Icon(
              Icons.lightbulb_outline_rounded,
              size: 24,
              color: Colors.amber,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                "Add more stores to organize your shopping by where you'll buy each item.",
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _QuickAddCard extends StatelessWidget {
  const _QuickAddCard({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      color: Colors.white,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.grey.shade300, width: 1),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: AppColors.skyBlue.withValues(alpha: .1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(
                  Icons.add_shopping_cart_rounded,
                  size: 22,
                  color: AppColors.skyBlue,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'Quick add item',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      "We'll pick the store based on where you usually buy it",
                      style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: Colors.grey.shade400),
            ],
          ),
        ),
      ),
    );
  }
}

class _QuickAddShoppingItemSheet extends StatefulWidget {
  const _QuickAddShoppingItemSheet({
    required this.householdId,
    required this.myMemberId,
    required this.isKid,
    required this.necessityCategoriesLower,
    required this.stores,
  });

  final String householdId;
  final String myMemberId;
  final bool isKid;
  final List<String> necessityCategoriesLower;
  final List<Map<String, dynamic>> stores;

  @override
  State<_QuickAddShoppingItemSheet> createState() => _QuickAddShoppingItemSheetState();
}

class _QuickAddShoppingItemSheetState extends State<_QuickAddShoppingItemSheet> {
  late final TextEditingController _nameController;
  final TextEditingController _quantityController = TextEditingController();
  final TextEditingController _unitController = TextEditingController();
  String? _selectedCategory;
  String? _selectedStoreId;
  String? _suggestedStoreName;
  String? _suggestedFromName;
  bool _isSubmitting = false;
  String? _errorMessage;
  Timer? _debounceTimer;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController();
    _nameController.addListener(_onNameChanged);

    final defaultStore = widget.stores.firstWhere(
      (s) => s['is_default'] == true,
      orElse: () => widget.stores.isNotEmpty ? widget.stores.first : <String, dynamic>{},
    );
    _selectedStoreId = defaultStore['id'] as String?;
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _nameController.removeListener(_onNameChanged);
    _nameController.dispose();
    _quantityController.dispose();
    _unitController.dispose();
    super.dispose();
  }

  void _onNameChanged() {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 400), () {
      if (!mounted) return;
      _lookupHistory();
    });
  }

  Future<void> _lookupHistory() async {
    final name = _nameController.text.trim().toLowerCase();

    if (name.isEmpty) {
      if (_suggestedStoreName != null && mounted) {
        setState(() {
          _suggestedStoreName = null;
          _suggestedFromName = null;
        });
      }
      return;
    }

    try {
      final response = await Supabase.instance.client
          .from('item_purchase_history')
          .select('store_id, purchase_count, last_purchased_at, stores(name)')
          .eq('household_id', widget.householdId)
          .eq('item_name_normalized', name)
          .order('purchase_count', ascending: false)
          .order('last_purchased_at', ascending: false)
          .limit(1);

      if (!mounted) return;

      if (response.isEmpty) {
        if (_suggestedStoreName != null) {
          setState(() {
            _suggestedStoreName = null;
            _suggestedFromName = null;
          });
        }
        return;
      }

      final match = response.first;
      final matchedStoreId = match['store_id'] as String?;
      final storeData = match['stores'] as Map<String, dynamic>?;
      final matchedStoreName = storeData?['name'] as String?;

      if (matchedStoreId == null || matchedStoreName == null) return;

      setState(() {
        _selectedStoreId = matchedStoreId;
        _suggestedStoreName = matchedStoreName;
        _suggestedFromName = _nameController.text.trim();
      });
    } catch (_) {
      if (mounted && _suggestedStoreName != null) {
        setState(() {
          _suggestedStoreName = null;
          _suggestedFromName = null;
        });
      }
    }
  }

  bool get _suggestionStillRelevant {
    if (_suggestedStoreName == null || _suggestedFromName == null) return false;
    return _nameController.text.trim().toLowerCase() == _suggestedFromName!.toLowerCase();
  }

  Future<void> _submit() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() => _errorMessage = 'Item name is required');
      return;
    }
    if (_selectedStoreId == null) {
      setState(() => _errorMessage = 'Please select a store');
      return;
    }

    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
    });

    try {
      final quantity = double.tryParse(_quantityController.text.trim());
      final unit = _unitController.text.trim();

      await Supabase.instance.client.rpc<void>('add_item_to_store', params: {
        'p_member_id': widget.myMemberId,
        'p_store_id': _selectedStoreId,
        'p_name': name,
        'p_quantity': quantity,
        'p_unit': unit.isEmpty ? null : unit,
        'p_category': _selectedCategory,
      });

      if (!mounted) return;

      if (widget.isKid) {
        final isNecessity = _selectedCategory != null &&
            widget.necessityCategoriesLower.contains(_selectedCategory!.toLowerCase());
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(isNecessity
                ? 'Added to shopping list'
                : 'Added to wishlist — waiting for approval'),
          ),
        );
      }

      Navigator.of(context).pop();
    } on PostgrestException catch (e) {
      if (!mounted) return;
      setState(() {
        _isSubmitting = false;
        _errorMessage = 'Could not add item: ${e.message}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isSubmitting = false;
        _errorMessage = 'Could not add item: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const Text(
              'Quick add item',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 16),

            TextField(
              controller: _nameController,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Item name',
                hintText: 'e.g., Milk, Bread, Eggs',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),

            DropdownButtonFormField<String>(
              initialValue: _selectedStoreId,
              decoration: const InputDecoration(
                labelText: 'Store',
                border: OutlineInputBorder(),
              ),
              items: widget.stores.map((s) {
                return DropdownMenuItem<String>(
                  value: s['id'] as String,
                  child: Text(s['name'] as String? ?? 'Store'),
                );
              }).toList(),
              onChanged: (val) {
                setState(() {
                  _selectedStoreId = val;
                  _suggestedStoreName = null;
                  _suggestedFromName = null;
                });
              },
            ),

            SizedBox(
              height: 24,
              child: _suggestionStillRelevant
                  ? Padding(
                      padding: const EdgeInsets.only(top: 4, left: 4),
                      child: Text(
                        "You usually buy '${_suggestedFromName!}' at $_suggestedStoreName",
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.skyBlue,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    )
                  : null,
            ),

            const SizedBox(height: 8),

            Row(
              children: [
                Expanded(
                  flex: 2,
                  child: TextField(
                    controller: _quantityController,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'Quantity',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 3,
                  child: TextField(
                    controller: _unitController,
                    decoration: const InputDecoration(
                      labelText: 'Unit (lb, cups, etc.)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            const Text(
              'Category',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
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
                    label: Text('${shoppingCategoryEmojis[cat]} $cat'),
                    selected: selected,
                    onSelected: (_) =>
                        setState(() => _selectedCategory = selected ? null : cat),
                  );
                },
              ),
            ),
            const SizedBox(height: 16),

            if (_errorMessage != null) ...[
              Card(
                margin: EdgeInsets.zero,
                color: AppColors.coral.withValues(alpha: .12),
                elevation: 0,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      const Icon(Icons.error_outline_rounded,
                          color: AppColors.coral, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(_errorMessage!,
                            style: const TextStyle(color: AppColors.coral)),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],

            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed:
                        _isSubmitting ? null : () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: _isSubmitting ? null : _submit,
                    child: _isSubmitting
                        ? const SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white),
                          )
                        : const Text('Add'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
