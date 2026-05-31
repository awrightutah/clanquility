import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import 'home_shell_screen.dart';

class HouseholdSetupScreen extends StatefulWidget {
  const HouseholdSetupScreen({super.key});

  @override
  State<HouseholdSetupScreen> createState() => _HouseholdSetupScreenState();
}

class _HouseholdSetupScreenState extends State<HouseholdSetupScreen> {
  int _step = 0; // 0 = choose create/join, 1 = create form, 2 = join form
  bool _isLoading = false;
  String? _errorMessage;

  // Create household fields
  final _householdNameController = TextEditingController();
  Color _selectedColor = AppColors.honeyGold;

  // Join household fields
  final _inviteCodeController = TextEditingController();

  final _colors = [
    AppColors.honeyGold,
    AppColors.skyBlue,
    AppColors.grassGreen,
    AppColors.coral,
    const Color(0xFF9B59B6),
    const Color(0xFFE67E22),
    const Color(0xFF1ABC9C),
    const Color(0xFFE91E63),
  ];

  @override
  void dispose() {
    _householdNameController.dispose();
    _inviteCodeController.dispose();
    super.dispose();
  }

  /// Ensure the user has a profile record in the profiles table.
  Future<void> _ensureProfile() async {
    final user = Supabase.instance.client.auth.currentUser!;
    try {
      await Supabase.instance.client.from('profiles').upsert({
        'id': user.id,
        'email': user.email,
        'display_name': user.userMetadata?['display_name'] ?? user.email?.split('@').first ?? 'User',
      }, onConflict: 'id');
    } catch (_) {
      // Profile may already exist, that's fine
    }
  }

  Future<void> _createHousehold() async {
    final name = _householdNameController.text.trim();
    if (name.isEmpty) {
      setState(() => _errorMessage = 'Please give your household a name.');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final user = Supabase.instance.client.auth.currentUser!;

      // Ensure profile exists
      await _ensureProfile();

      final colorHex = '#${_selectedColor.value.toRadixString(16).substring(2).toUpperCase()}';

      // Create household
      final household = await Supabase.instance.client
          .from('households')
          .insert({
            'name': name,
            'theme_color': colorHex,
            'owner_user_id': user.id,
            'tier': 'free',
            'subscription_status': 'active',
          })
          .select()
          .single();

      final householdId = household['id'];

      // Add current user as owner of the new household (adult_auth_user kind)
      await Supabase.instance.client.from('household_members').insert({
        'household_id': householdId,
        'auth_user_id': user.id,
        'role': 'owner',
        'kind': 'adult_auth_user',
        'display_name': user.userMetadata?['display_name'] ?? user.email?.split('@').first ?? 'Admin',
        'points_balance': 0,
        'is_active': true,
        'created_by': user.id,
      });

      // Create default calendar tags for the household
      final defaultTags = [
        {'name': 'Shopping', 'color': '#4A90D9', 'emoji': '🛒'},
        {'name': 'Family', 'color': '#FF6B6B', 'emoji': '❤️'},
        {'name': 'School', 'color': '#9B59B6', 'emoji': '📚'},
        {'name': 'Other', 'color': '#95A5A6', 'emoji': '📌'},
      ];

      for (final tag in defaultTags) {
        await Supabase.instance.client.from('calendar_tags').insert({
          'household_id': householdId,
          ...tag,
        });
      }

      // Create a default store for the household. Failures propagate to
      // the outer catch (same pattern as calendar_tags above), so a seed
      // failure surfaces as 'Could not create household' to the user
      // rather than leaving them with broken shopping state.
      await Supabase.instance.client.from('stores').insert({
        'household_id': householdId,
        'name': 'Grocery Store',
        'is_default': true,
      });

      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const HomeShellScreen()),
        );
      }
    } catch (e) {
      setState(() => _errorMessage = 'Could not create household. ${e.toString()}');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _joinHousehold() async {
    final code = _inviteCodeController.text.trim().toUpperCase();
    if (code.isEmpty) {
      setState(() => _errorMessage = 'Please enter an invite code.');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      await _ensureProfile();

      await Supabase.instance.client.rpc<void>(
        'redeem_invite_code',
        params: {'p_code': code},
      );

      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const HomeShellScreen()),
        );
      }
    } on PostgrestException catch (e) {
      final message = switch (e.code) {
        'P0001' => 'Please sign in to join a household.',
        'P0002' => 'Invalid invite code. Please check and try again.',
        'P0003' => 'This invite code has been revoked.',
        'P0004' => 'This invite code has expired.',
        'P0005' => 'This invite code has reached its usage limit.',
        _ => 'Could not join household. Please try again.',
      };
      setState(() => _errorMessage = message);
    } catch (e) {
      setState(() => _errorMessage = 'Could not join household. ${e.toString()}');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: _step > 0 ? IconButton(icon: const Icon(Icons.arrow_back_rounded), onPressed: () => setState(() { _step = 0; _errorMessage = null; })) : null,
        title: const Text('Household Setup'),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 250),
            child: _buildStep(),
          ),
        ),
      ),
    );
  }

  Widget _buildStep() {
    switch (_step) {
      case 1: return _buildCreateForm();
      case 2: return _buildJoinForm();
      default: return _buildChooseStep();
    }
  }

  Widget _buildChooseStep() {
    return Column(
      key: const ValueKey('choose'),
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Spacer(),
        Container(
          width: 100,
          height: 100,
          decoration: BoxDecoration(
            color: AppColors.honeyGold.withValues(alpha:.18),
            shape: BoxShape.circle,
          ),
          child: const Center(child: Text('🏠', style: TextStyle(fontSize: 52))),
        ),
        const SizedBox(height: 24),
        Text(
          'Set up your household',
          style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w900),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(
          'Create a new household or join an existing one with an invite code.',
          style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 40),
        FilledButton.icon(
          onPressed: () => setState(() => _step = 1),
          icon: const Icon(Icons.add_home_rounded),
          label: const Text('Create a household'),
        ),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: () => setState(() => _step = 2),
          icon: const Icon(Icons.mail_outline_rounded),
          label: const Text('Join with invite code'),
        ),
        const Spacer(),
      ],
    );
  }

  Widget _buildCreateForm() {
    return SingleChildScrollView(
      key: const ValueKey('create'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Name your household', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900)),
          const SizedBox(height: 4),
          Text('Pick something fun that everyone will recognize.', style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
          const SizedBox(height: 24),

          // Household name
          TextFormField(
            controller: _householdNameController,
            textCapitalization: TextCapitalization.words,
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(
              labelText: 'Household name',
              prefixIcon: Icon(Icons.home_rounded),
              border: OutlineInputBorder(),
              hintText: 'e.g., The Smith Family',
            ),
          ),
          const SizedBox(height: 24),

          // Color picker
          Text('Pick a theme color', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: _colors.map((color) => GestureDetector(
              onTap: () => setState(() => _selectedColor = color),
              child: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  border: _selectedColor == color ? Border.all(color: Colors.black, width: 3) : null,
                ),
                child: _selectedColor == color ? const Icon(Icons.check_rounded, color: Colors.white, size: 20) : null,
              ),
            )).toList(),
          ),
          const SizedBox(height: 12),

          // Preview
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: _selectedColor.withValues(alpha:.2),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Center(child: Text('🏠', style: const TextStyle(fontSize: 28))),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _householdNameController.text.isEmpty ? 'Your Household' : _householdNameController.text,
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        Text('Preview', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 32),

          if (_errorMessage != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(Icons.error_outline_rounded, color: Theme.of(context).colorScheme.error, size: 20),
                  const SizedBox(width: 8),
                  Expanded(child: Text(_errorMessage!, style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer, fontSize: 13))),
                ],
              ),
            ),

          FilledButton(
            onPressed: _isLoading ? null : _createHousehold,
            child: _isLoading
                ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Text('Create household'),
          ),
        ],
      ),
    );
  }

  Widget _buildJoinForm() {
    return Column(
      key: const ValueKey('join'),
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Spacer(),
        Container(
          width: 80,
          height: 80,
          decoration: BoxDecoration(
            color: AppColors.skyBlue.withValues(alpha:.18),
            shape: BoxShape.circle,
          ),
          child: const Center(child: Text('✉️', style: TextStyle(fontSize: 40))),
        ),
        const SizedBox(height: 24),
        Text('Join a household', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900)),
        const SizedBox(height: 8),
        Text('Enter the invite code shared by a household admin.', style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant), textAlign: TextAlign.center),
        const SizedBox(height: 32),
        TextFormField(
          controller: _inviteCodeController,
          textCapitalization: TextCapitalization.characters,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, letterSpacing: 4),
          maxLength: 8,
          decoration: const InputDecoration(
            labelText: 'Invite code',
            prefixIcon: Icon(Icons.vpn_key_rounded),
            border: OutlineInputBorder(),
            counterText: '',
          ),
        ),
        const SizedBox(height: 24),

        if (_errorMessage != null)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Icon(Icons.error_outline_rounded, color: Theme.of(context).colorScheme.error, size: 20),
                const SizedBox(width: 8),
                Expanded(child: Text(_errorMessage!, style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer, fontSize: 13))),
              ],
            ),
          ),

        FilledButton(
          onPressed: _isLoading ? null : _joinHousehold,
          child: _isLoading
              ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Text('Join household'),
        ),
        const Spacer(),
      ],
    );
  }
}