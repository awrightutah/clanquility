import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import '../utils/membership.dart';
import '../utils/permissions.dart';

/// Create or edit a single store. Pushed from ShoppingStoresScreen via
/// the AppBar 'Add Store' action (create) or by tapping an edit affordance
/// on a store card (edit). Returns true via Navigator.pop on save success
/// so the caller can refresh its list.
///
/// Admin-only at the UI level via the gated entry points; the stores RLS
/// policies from migration 0026 are the server-side enforcement, and
/// set_store_as_default (migration 0032) likewise checks
/// is_household_admin server-side.
class AddEditStoreScreen extends StatefulWidget {
  const AddEditStoreScreen({super.key, this.existingStore});

  /// Null for create, populated for edit. Expected keys: id, name,
  /// is_default, household_id.
  final Map<String, dynamic>? existingStore;

  @override
  State<AddEditStoreScreen> createState() => _AddEditStoreScreenState();
}

class _AddEditStoreScreenState extends State<AddEditStoreScreen> {
  late final TextEditingController _nameController;
  bool _setAsDefault = false;
  bool _isSaving = false;
  bool _isDeleting = false;
  bool _isLoading = true;
  String? _errorMessage;

  Map<String, dynamic>? _household;
  Map<String, dynamic>? _myMembership;
  List<Map<String, dynamic>> _existingStores = [];

  bool get _isEditing => widget.existingStore != null;

  /// In edit mode, true when the store being edited is the household's
  /// current default. In that case, the user can't un-default via this
  /// screen — they swap by setting another store as default.
  bool get _isCurrentDefault =>
      _isEditing && widget.existingStore?['is_default'] == true;

  @override
  void initState() {
    super.initState();
    _nameController =
        TextEditingController(text: widget.existingStore?['name'] as String? ?? '');
    _setAsDefault = widget.existingStore?['is_default'] == true;
    _loadData();
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
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

      final stores = await Supabase.instance.client
          .from('stores')
          .select()
          .eq('household_id', household['id']);

      if (!mounted) return;
      setState(() {
        _myMembership = membership;
        _household = household;
        _existingStores = List<Map<String, dynamic>>.from(stores);
        _isLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _errorMessage = "Couldn't load store data. Try again.";
        _isLoading = false;
      });
    }
  }

  Future<void> _save() async {
    final trimmed = _nameController.text.trim();

    if (trimmed.isEmpty) {
      setState(() => _errorMessage = 'Store name is required.');
      return;
    }
    if (trimmed.length > 50) {
      setState(() => _errorMessage = 'Store name must be 50 characters or fewer.');
      return;
    }

    final normalized = trimmed.toLowerCase();
    final editingId = widget.existingStore?['id'];
    final conflict = _existingStores.any((s) =>
        (s['name'] as String? ?? '').toLowerCase() == normalized &&
        (editingId == null || s['id'] != editingId));
    if (conflict) {
      setState(() => _errorMessage = 'A store named "$trimmed" already exists.');
      return;
    }

    if (_household == null || _myMembership == null) {
      setState(() => _errorMessage = 'Household not loaded. Try again.');
      return;
    }

    setState(() {
      _isSaving = true;
      _errorMessage = null;
    });

    try {
      final supabase = Supabase.instance.client;

      if (_isEditing) {
        await supabase
            .from('stores')
            .update({'name': trimmed})
            .eq('id', editingId as Object);

        // If the user turned the default-toggle on for a previously
        // non-default store, swap defaults atomically via the RPC.
        // (We don't support un-defaulting via this screen — the toggle
        // is disabled when editing the current default.)
        if (_setAsDefault && !_isCurrentDefault) {
          await supabase.rpc<void>(
            'set_store_as_default',
            params: {'p_store_id': editingId},
          );
        }
      } else {
        final inserted = await supabase
            .from('stores')
            .insert({
              'household_id': _household!['id'],
              'name': trimmed,
              'created_by_member_id': _myMembership!['id'],
            })
            .select()
            .single();

        if (_setAsDefault) {
          await supabase.rpc<void>(
            'set_store_as_default',
            params: {'p_store_id': inserted['id']},
          );
        }
      }

      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on PostgrestException catch (e) {
      if (!mounted) return;
      setState(() {
        _isSaving = false;
        _errorMessage = _isRlsError(e)
            ? 'Only household admins can manage stores.'
            : 'Could not save store: ${e.message}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isSaving = false;
        _errorMessage = 'Could not save store: $e';
      });
    }
  }

  Future<void> _deleteStore() async {
    if (widget.existingStore == null) return;
    final storeId = widget.existingStore!['id'] as String;
    final storeName = widget.existingStore!['name'] as String? ?? 'this store';

    // UI also hides the button for default stores, but defensive guard
    // here matches the server-side P0003 raise from migration 0033.
    if (_isCurrentDefault) {
      setState(() => _errorMessage =
          "Default store can't be deleted. Set another store as default first.");
      return;
    }

    // On-demand item count for the confirmation message. Non-fatal —
    // if the count query fails we still show the dialog without it.
    int itemCount = 0;
    try {
      final response = await Supabase.instance.client
          .from('shopping_items')
          .select('id')
          .eq('store_id', storeId)
          .count(CountOption.exact);
      itemCount = response.count;
    } catch (_) {
      // Fall through with itemCount = 0.
    }

    final defaultStore = _existingStores.firstWhere(
      (s) => s['is_default'] == true,
      orElse: () => <String, dynamic>{'name': 'the default store'},
    );
    final defaultName = defaultStore['name'] as String? ?? 'the default store';

    final body = itemCount == 0
        ? 'Delete $storeName?'
        : 'Delete $storeName? Its $itemCount ${itemCount == 1 ? 'item' : 'items'} '
            'will move to $defaultName.';

    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete $storeName?'),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.coral),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    if (!mounted) return;

    setState(() {
      _isDeleting = true;
      _errorMessage = null;
    });

    try {
      // delete_store_and_reassign (migration 0033): moves items off the
      // store to the household default's active list, then deletes the
      // store, all in one transaction.
      await Supabase.instance.client.rpc<void>(
        'delete_store_and_reassign',
        params: {'p_store_id': storeId},
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on PostgrestException catch (e) {
      if (!mounted) return;
      setState(() {
        _isDeleting = false;
        if (e.code == 'P0003') {
          _errorMessage =
              "Default store can't be deleted. Set another store as default first.";
        } else if (_isRlsError(e) || e.code == 'P0002') {
          _errorMessage = 'Only household admins can delete stores.';
        } else {
          _errorMessage = 'Could not delete store: ${e.message}';
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isDeleting = false;
        _errorMessage = 'Could not delete store: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditing ? 'Edit Store' : 'Add Store'),
        actions: [
          if (_isSaving)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Center(
                child: SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          else
            TextButton(
              onPressed: _isLoading ? null : _save,
              child: const Text('Save'),
            ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Store details',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            color: Colors.grey.shade600,
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _nameController,
                      autofocus: true,
                      maxLength: 50,
                      textCapitalization: TextCapitalization.words,
                      decoration: const InputDecoration(
                        labelText: 'Store name',
                        hintText: "e.g., Costco, Smith's",
                        prefixIcon: Icon(Icons.storefront_rounded),
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (_) {
                        if (_errorMessage != null) {
                          setState(() => _errorMessage = null);
                        }
                      },
                    ),
                    const SizedBox(height: 16),
                    Card(
                      margin: EdgeInsets.zero,
                      child: SwitchListTile(
                        title: const Text(
                          'Set as default store',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                        subtitle: Text(
                          _isCurrentDefault
                              ? 'This is your default store. Set another store as default to change.'
                              : 'New items default to this store when adding.',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        value: _setAsDefault,
                        onChanged: _isCurrentDefault
                            ? null
                            : (v) => setState(() => _setAsDefault = v),
                      ),
                    ),
                    if (_errorMessage != null) ...[
                      const SizedBox(height: 16),
                      Card(
                        margin: EdgeInsets.zero,
                        color: AppColors.coral.withValues(alpha: .12),
                        elevation: 0,
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.error_outline_rounded,
                                color: AppColors.coral,
                                size: 20,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  _errorMessage!,
                                  style: const TextStyle(
                                    color: AppColors.coral,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 24),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: (_isSaving || _isDeleting)
                                ? null
                                : () => Navigator.of(context).pop(false),
                            child: const Text('Cancel'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: FilledButton(
                            onPressed: (_isSaving || _isDeleting) ? null : _save,
                            child: _isSaving
                                ? const SizedBox(
                                    height: 18,
                                    width: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : Text(_isEditing ? 'Save' : 'Create'),
                          ),
                        ),
                      ],
                    ),
                    if (_isEditing &&
                        Permissions.canManageStores(_myMembership)) ...[
                      const SizedBox(height: 32),
                      const Divider(),
                      const SizedBox(height: 16),
                      Text(
                        'Danger zone',
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                              color: Colors.grey.shade700,
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                      const SizedBox(height: 12),
                      if (_isCurrentDefault)
                        Card(
                          margin: EdgeInsets.zero,
                          color: Colors.grey.shade100,
                          elevation: 0,
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.info_outline_rounded,
                                  color: Colors.grey.shade600,
                                  size: 20,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    "The default store can't be deleted. "
                                    'Set another store as default to remove this one.',
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodySmall
                                        ?.copyWith(color: Colors.grey.shade700),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        )
                      else
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            onPressed: (_isSaving || _isDeleting)
                                ? null
                                : _deleteStore,
                            icon: _isDeleting
                                ? const SizedBox(
                                    height: 16,
                                    width: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: AppColors.coral,
                                    ),
                                  )
                                : const Icon(
                                    Icons.delete_outline_rounded,
                                    color: AppColors.coral,
                                  ),
                            label: Text(
                              _isDeleting ? 'Deleting...' : 'Delete store',
                              style: const TextStyle(
                                color: AppColors.coral,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            style: OutlinedButton.styleFrom(
                              side:
                                  const BorderSide(color: AppColors.coral),
                              padding: const EdgeInsets.symmetric(vertical: 12),
                            ),
                          ),
                        ),
                    ],
                  ],
                ),
              ),
            ),
    );
  }
}

bool _isRlsError(PostgrestException e) {
  if (e.code == '42501') return true;
  final lower = e.message.toLowerCase();
  return lower.contains('permission') ||
      lower.contains('row-level') ||
      lower.contains('policy');
}
