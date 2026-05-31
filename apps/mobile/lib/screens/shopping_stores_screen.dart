import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import '../services/realtime_service.dart';
import '../services/active_member_service.dart';
import '../utils/membership.dart';
import '../utils/permissions.dart';
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

      final result = await Supabase.instance.client.rpc<List<dynamic>>(
        'get_stores_with_counts',
        params: {'p_household_id': household['id']},
      );

      if (!mounted) return;
      setState(() {
        _myMembership = membership;
        _stores = List<Map<String, dynamic>>.from(result);
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
    // Task 4 will refactor ShoppingListScreen to accept storeId. For now,
    // push the existing screen — it loads the household's active list,
    // which is what the user has today.
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => const ShoppingListScreen(),
      ),
    );
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
