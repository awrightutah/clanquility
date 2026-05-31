import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import '../utils/membership.dart';

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
                            onPressed: _isSaving
                                ? null
                                : () => Navigator.of(context).pop(false),
                            child: const Text('Cancel'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: FilledButton(
                            onPressed: _isSaving ? null : _save,
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
