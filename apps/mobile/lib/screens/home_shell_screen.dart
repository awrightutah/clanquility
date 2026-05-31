import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import '../services/realtime_service.dart';
import '../services/active_member_service.dart';
import '../utils/membership.dart';
import '../utils/permissions.dart';
import 'chore_dashboard_screen.dart';
import 'meal_planner_screen.dart';
import 'shopping_stores_screen.dart';
import 'calendar_screen.dart';
import 'recipe_library_screen.dart';
import 'members_screen.dart';
import 'rewards_screen.dart';
import 'achievements_screen.dart';
import 'point_history_screen.dart';
import 'settings_screen.dart';
import 'profile_screen.dart';
import 'subscription_screen.dart';
import 'feedback_screen.dart';
import 'activity_feed_screen.dart';
import 'search_screen.dart';
import 'household_stats_screen.dart';
import 'chore_templates_screen.dart';
import 'invite_management_screen.dart';
import 'announcements_screen.dart';
import 'member_profile_screen.dart';
import 'data_export_screen.dart';
import 'approvals_screen.dart';
import '../services/feature_tour_service.dart';
import '../widgets/offline_banner.dart';

class HomeShellScreen extends StatefulWidget {
  const HomeShellScreen({super.key});

  @override
  State<HomeShellScreen> createState() => _HomeShellScreenState();
}

class _HomeShellScreenState extends State<HomeShellScreen> {
  int _currentIndex = 0;
  Map<String, dynamic>? _household;
  Map<String, dynamic>? _myMembership;
  bool _isLoading = true;
  Map<String, dynamic>? _pinnedAnnouncement;
  List<Map<String, dynamic>> _householdMembers = [];
  bool _showTour = false;
  // Batch 5b-i — AppBar inbox badge count: sum of pending_verification
  // chores + is_wishlist=true shopping_items in the household. Updated on
  // load + on chores/shopping realtime ticks + after Approvals screen pops.
  int _pendingTotal = 0;

  // Per-tab Navigator for the Shopping tab so pushes (e.g., into a
  // store-detail view) stay scoped to the tab's route stack across
  // tab switches. The system back button on Android pops this
  // Navigator before falling through to default exit behavior; see
  // PopScope wrapper in build().
  final GlobalKey<NavigatorState> _shoppingNavKey = GlobalKey<NavigatorState>();

  List<Widget> get _screens => [
    const ChoreDashboardScreen(),
    const MealPlannerScreen(),
    Navigator(
      key: _shoppingNavKey,
      onGenerateRoute: (settings) => MaterialPageRoute<void>(
        builder: (_) => const ShoppingStoresScreen(),
        settings: settings,
      ),
    ),
    const CalendarScreen(),
    const RecipeLibraryScreen(),
  ];

  @override
  void initState() {
    super.initState();
    _loadHouseholdInfo();
    // Listen for points changes to refresh the badge
    RealtimeService.instance.pointsVersion.addListener(_onPointsChanged);
    // Listen for announcement changes to refresh the banner
    RealtimeService.instance.announcementsVersion.addListener(_onAnnouncementChanged);
    // Batch 5b-i — chores/shopping ticks refresh the Approvals badge count.
    // Batch 6b — meal_requests ticks join the same fan-in so a kid submitting
    // on another device live-updates the admin's badge.
    RealtimeService.instance.choresVersion.addListener(_onApprovalsSourceChanged);
    RealtimeService.instance.shoppingVersion.addListener(_onApprovalsSourceChanged);
    RealtimeService.instance.mealRequestsVersion.addListener(_onApprovalsSourceChanged);
    ActiveMemberService.instance.activeMemberId.addListener(_onActiveMemberChanged);
  }

  @override
  void dispose() {
    RealtimeService.instance.pointsVersion.removeListener(_onPointsChanged);
    RealtimeService.instance.announcementsVersion.removeListener(_onAnnouncementChanged);
    RealtimeService.instance.choresVersion.removeListener(_onApprovalsSourceChanged);
    RealtimeService.instance.shoppingVersion.removeListener(_onApprovalsSourceChanged);
    RealtimeService.instance.mealRequestsVersion.removeListener(_onApprovalsSourceChanged);
    ActiveMemberService.instance.activeMemberId.removeListener(_onActiveMemberChanged);
    super.dispose();
  }

  void _onPointsChanged() {
    if (mounted) {
      // Reload membership to get updated points balance
      _loadHouseholdInfo();
    }
  }

  void _onAnnouncementChanged() {
    if (mounted) _loadHouseholdInfo();
  }

  void _onActiveMemberChanged() {
    if (mounted) _loadHouseholdInfo();
  }

  /// Realtime tick from chores OR shopping_items → refresh the Approvals
  /// badge count. Lightweight: only the count query, no full reload.
  void _onApprovalsSourceChanged() {
    if (mounted) _loadPendingTotal();
  }

  /// Recomputes _pendingTotal from two count queries. No-op for non-admins.
  Future<void> _loadPendingTotal() async {
    if (_household == null) return;
    if (!Permissions.isAdmin(_myMembership)) {
      if (mounted && _pendingTotal != 0) {
        setState(() => _pendingTotal = 0);
      }
      return;
    }
    try {
      final householdId = _household!['id'];
      // Three parallel id-only queries (chores + shopping wishlist + meal
      // requests). At current scale (~few items) this is cheap; switch to
      // `.count()` syntax later if volume grows.
      final results = await Future.wait([
        Supabase.instance.client
            .from('chores')
            .select('id')
            .eq('household_id', householdId)
            .eq('status', 'pending_verification'),
        Supabase.instance.client
            .from('shopping_items')
            .select('id')
            .eq('household_id', householdId)
            .eq('is_wishlist', true),
        Supabase.instance.client
            .from('meal_requests')
            .select('id')
            .eq('household_id', householdId)
            .eq('status', 'pending'),
      ]);
      final total = (results[0] as List).length +
          (results[1] as List).length +
          (results[2] as List).length;
      if (mounted) setState(() => _pendingTotal = total);
    } catch (e) {
      debugPrint('load pending total failed: $e');
      // Keep last-known count; don't disturb the badge on transient errors.
    }
  }

  Future<void> _loadHouseholdInfo() async {
    try {
      // Batch 7a-iii (CLEANUP) — replaced the verbose manual overlay with
      // MembershipHelper. The helper does the same JWT-holder-then-active-id
      // resolution internally; we still load the full members list separately
      // for the profile switcher menu.
      final membership = await MembershipHelper.loadActiveMembership(
        includeHouseholdJoin: true,
      );

      if (membership != null) {
        _household = membership['households'];
        _myMembership = membership;

        final members = await Supabase.instance.client
            .from('household_members')
            .select()
            .eq('household_id', _household!['id'])
            .eq('is_active', true)
            .order('created_at');
        _householdMembers = List<Map<String, dynamic>>.from(members);

        // If the persisted active-member id doesn't match what the helper
        // resolved to (either it was never set, or the kid sub_profile it
        // pointed to has been deactivated), sync ActiveMemberService to the
        // resolved id so subsequent listeners see the corrected value.
        final requestedActiveId =
            ActiveMemberService.instance.activeMemberId.value;
        if (requestedActiveId != _myMembership!['id']) {
          await ActiveMemberService.instance.switchTo(_myMembership!['id']);
        }

        // Subscribe to realtime updates for this household
        RealtimeService.instance.subscribe(_household!['id']);

        // Batch 5b-i — refresh the AppBar inbox badge count.
        await _loadPendingTotal();

        // Load pinned announcement
        try {
          final pinned = await Supabase.instance.client
              .from('announcements')
              .select('title, message')
              .eq('household_id', _household!['id'])
              .eq('is_pinned', true)
              .order('created_at', ascending: false)
              .limit(1);
          _pinnedAnnouncement = pinned.isNotEmpty ? pinned[0] : null;
        } catch (_) {
          _pinnedAnnouncement = null;
        }
      }
    } catch (_) {
      // Silently handle - screens will show their own errors
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
        // Show feature tour for first-time users
        if (!FeatureTourService.instance.tourCompleted) {
          Future.delayed(const Duration(milliseconds: 800), () {
            if (mounted) setState(() => _showTour = true);
          });
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scaffold = PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        // On the Shopping tab, pop the per-tab Navigator if it has
        // routes above its root. Lets system back unwind in-tab pushes
        // (e.g., AddEditStoreScreen) before exiting/backgrounding the app.
        if (_currentIndex == 2) {
          final shoppingNav = _shoppingNavKey.currentState;
          if (shoppingNav != null && shoppingNav.canPop()) {
            shoppingNav.pop();
            return;
          }
        }
        // No tab-level pop available — fall through to system default
        // (backgrounds the app on Android; ignored on iOS).
      },
      child: Scaffold(
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                const OfflineBanner(),
                if (_pinnedAnnouncement != null)
                  Semantics(
                    label: 'Pinned announcement: ${_pinnedAnnouncement!['title']}. Tap to view.',
                    button: true,
                    child: Material(
                    color: AppColors.honeyGold.withValues(alpha:.15),
                    child: InkWell(
                      onTap: () {
                        Navigator.push(context, MaterialPageRoute(builder: (_) => const AnnouncementsScreen()));
                      },
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        child: Row(
                          children: [
                            const Icon(Icons.push_pin_rounded, size: 16, color: AppColors.honeyGold),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _pinnedAnnouncement!['title'] ?? '',
                                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: AppColors.honeyGold),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const Icon(Icons.chevron_right_rounded, size: 16, color: AppColors.honeyGold),
                          ],
                        ),
                      ),
                    ),
                  ),
                  ),
                Expanded(
                  child: IndexedStack(
                    index: _currentIndex,
                    children: _screens,
                  ),
                ),
              ],
            ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (value) => setState(() => _currentIndex = value),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.task_alt_rounded), label: 'Chores'),
          NavigationDestination(icon: Icon(Icons.restaurant_menu_rounded), label: 'Meals'),
          NavigationDestination(icon: Icon(Icons.shopping_cart_rounded), label: 'Shop'),
          NavigationDestination(icon: Icon(Icons.calendar_month_rounded), label: 'Calendar'),
          NavigationDestination(icon: Icon(Icons.menu_book_rounded), label: 'Recipes'),
        ],
      ),
      appBar: _isLoading
          ? null
          : AppBar(
              title: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_household?['emoji'] != null && (_household!['emoji'] as String).isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Text(
                        _household!['emoji'],
                        style: const TextStyle(fontSize: 22),
                      ),
                    ),
                  Flexible(
                    child: Text(
                      _household?['name'] ?? 'Clanquility',
                      style: const TextStyle(fontWeight: FontWeight.w800),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              actions: [
                // Points badge
                if (_myMembership != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Semantics(
                      label: 'Points balance: ${_myMembership!['points_balance'] ?? 0}. Tap to view history.',
                      button: true,
                      child: TextButton.icon(
                      onPressed: () => _navigateToPointHistory(),
                      icon: const Icon(Icons.star_rounded, size: 18, color: AppColors.honeyGold),
                      label: Text(
                        '${_myMembership!['points_balance'] ?? 0}',
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          color: AppColors.honeyGold,
                          fontSize: 14,
                        ),
                      ),
                      style: TextButton.styleFrom(
                        backgroundColor: AppColors.honeyGold.withValues(alpha:.1),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(100)),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                  ),
                  ),
                // Batch 7b-iii — Active-member identity indicator. Replaces
                // the prior baby/switch-account IconButton. Shows the active
                // member's avatar + first name so a parent helping their kid
                // can tell at a glance which profile is operating. Same tap
                // handler (_showProfileSwitcher) as the old icon.
                _buildActiveMemberIndicator(),
                IconButton(
                  icon: const Icon(Icons.search_rounded),
                  onPressed: () => _navigateToSearch(),
                  tooltip: 'Search',
                ),
                // Batch 5b-i — Approvals inbox icon with badge. Admin-only;
                // Members IconButton was removed from here to free the slot
                // (Members remains reachable from the popup menu and from
                // Settings → Household).
                if (Permissions.isAdmin(_myMembership))
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Badge.count(
                      count: _pendingTotal,
                      isLabelVisible: _pendingTotal > 0,
                      child: IconButton(
                        icon: const Icon(Icons.inbox_rounded),
                        tooltip: 'Approvals',
                        onPressed: () async {
                          await Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const ApprovalsScreen(),
                            ),
                          );
                          // Refresh badge on return — approve/deny actions
                          // would have changed counts.
                          if (mounted) await _loadPendingTotal();
                        },
                      ),
                    ),
                  ),
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_horiz_rounded),
                  onSelected: _handleMenuAction,
                  itemBuilder: (context) => [
                    const PopupMenuItem(value: 'profile', child: Row(children: [Icon(Icons.person_rounded, size: 20), SizedBox(width: 12), Text('My Profile')])),
                    const PopupMenuItem(value: 'switch_profile', child: Row(children: [Icon(Icons.switch_account_rounded, size: 20), SizedBox(width: 12), Text('Switch Profile')])),
                    const PopupMenuItem(value: 'members', child: Row(children: [Icon(Icons.people_rounded, size: 20), SizedBox(width: 12), Text('Household Members')])),
                    const PopupMenuItem(value: 'activity', child: Row(children: [Icon(Icons.timeline_rounded, size: 20), SizedBox(width: 12), Text('Activity Feed')])),
                    const PopupMenuItem(value: 'stats', child: Row(children: [Icon(Icons.bar_chart_rounded, size: 20), SizedBox(width: 12), Text('Household Stats')])),
                    // Batch 7b-i — admin-only menu entry. Chore templates are
                    // an admin authoring tool; the screen itself rejects kid
                    // writes, but the menu shouldn't expose the entry point.
                    if (Permissions.isAdmin(_myMembership))
                      const PopupMenuItem(value: 'templates', child: Row(children: [Icon(Icons.assignment_rounded, size: 20), SizedBox(width: 12), Text('Chore Templates')])),
                    const PopupMenuItem(value: 'invites', child: Row(children: [Icon(Icons.mail_rounded, size: 20), SizedBox(width: 12), Text('Invite Codes')])),
                    const PopupMenuItem(value: 'announcements', child: Row(children: [Icon(Icons.campaign_rounded, size: 20), SizedBox(width: 12), Text('Announcements')])),
                    const PopupMenuItem(value: 'export', child: Row(children: [Icon(Icons.download_rounded, size: 20), SizedBox(width: 12), Text('Export Data')])),
                    const PopupMenuItem(value: 'leaderboard', child: Row(children: [Icon(Icons.emoji_events_rounded, size: 20), SizedBox(width: 12), Text('Leaderboard')])),
                    const PopupMenuItem(value: 'rewards', child: Row(children: [Icon(Icons.card_giftcard_rounded, size: 20), SizedBox(width: 12), Text('Rewards')])),
                    const PopupMenuItem(value: 'achievements', child: Row(children: [Icon(Icons.military_tech_rounded, size: 20), SizedBox(width: 12), Text('Achievements')])),
                    const PopupMenuItem(value: 'point_history', child: Row(children: [Icon(Icons.history_rounded, size: 20), SizedBox(width: 12), Text('Point History')])),
                    const PopupMenuDivider(),
                    const PopupMenuItem(value: 'subscription', child: Row(children: [Icon(Icons.workspace_premium_rounded, size: 20), SizedBox(width: 12), Text('Subscription')])),
                    const PopupMenuItem(value: 'feedback', child: Row(children: [Icon(Icons.feedback_rounded, size: 20), SizedBox(width: 12), Text('Send Feedback')])),
                    const PopupMenuItem(value: 'settings', child: Row(children: [Icon(Icons.settings_rounded, size: 20), SizedBox(width: 12), Text('Settings')])),
                    const PopupMenuItem(value: 'signout', child: Row(children: [Icon(Icons.logout_rounded, size: 20), SizedBox(width: 12), Text('Sign Out')])),
                  ],
                ),
              ],
            ),
      ),
    );

    if (_showTour) {
      return Stack(
        children: [
          scaffold,
          FeatureTourOverlay(
            onCompleted: () {
              if (mounted) setState(() => _showTour = false);
            },
          ),
        ],
      );
    }

    return scaffold;
  }

  void _navigateToMembers() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const MembersScreen()),
    );
  }

  void _navigateToSearch() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const SearchScreen()),
    );
  }

  void _navigateToStats() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const HouseholdStatsScreen()),
    );
  }

  void _navigateToProfile() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const ProfileScreen()),
    );
  }

  void _navigateToRewards() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const RewardsScreen()),
    );
  }

  void _navigateToAchievements() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const AchievementsScreen()),
    );
  }

  void _navigateToPointHistory() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const PointHistoryScreen()),
    );
  }

  // ─── Batch 7b-iii: active member identity indicator ────────────────────

  /// First name parsed from `display_name`. Splits on whitespace and takes the
  /// first token; returns the trimmed name unchanged if it has no spaces, or
  /// '?' if the field is empty/null.
  String _firstName(Map<String, dynamic>? membership) {
    final displayName = (membership?['display_name'] as String?)?.trim() ?? '';
    if (displayName.isEmpty) return '?';
    final parts = displayName.split(RegExp(r'\s+'));
    return parts.first;
  }

  /// First letter of `display_name`, uppercased, for the initials fallback
  /// avatar. Returns '?' if the field is empty/null.
  String _firstLetter(Map<String, dynamic>? membership) {
    final displayName = (membership?['display_name'] as String?)?.trim() ?? '';
    if (displayName.isEmpty) return '?';
    return displayName.substring(0, 1).toUpperCase();
  }

  /// AppBar widget that always shows whose profile is active. Avatar (image
  /// or initials) + first name in a horizontal Row, tappable to open the
  /// profile switcher (same handler as the prior baby IconButton).
  Widget _buildActiveMemberIndicator() {
    final firstName = _firstName(_myMembership);
    final firstLetter = _firstLetter(_myMembership);
    final avatarUrl = _myMembership?['avatar_url'] as String?;
    final hasAvatar = avatarUrl != null && avatarUrl.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: InkWell(
        onTap: _showProfileSwitcher,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircleAvatar(
                radius: 16,
                backgroundColor: AppColors.honeyGold,
                // backgroundImage falls through to the child slot if null;
                // when the URL is set but fails to load there is no error
                // fallback today (the circle renders honey-gold with no
                // initials). Flag as a future polish if it becomes annoying
                // in practice — most users will have working URLs or none.
                backgroundImage: hasAvatar ? NetworkImage(avatarUrl) : null,
                child: hasAvatar
                    ? null
                    : Text(
                        firstLetter,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                          fontSize: 14,
                        ),
                      ),
              ),
              const SizedBox(width: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 80),
                child: Text(
                  firstName,
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _navigateToSettings() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const SettingsScreen()),
    );
  }

  void _navigateToSubscription() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const SubscriptionScreen()),
    );
  }

  void _navigateToFeedback() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const FeedbackScreen()),
    );
  }

  void _handleMenuAction(String action) {
    switch (action) {
      case 'profile':
        _navigateToProfile();
        break;
      case 'switch_profile':
        _showProfileSwitcher();
        break;
      case 'members':
        _navigateToMembers();
        break;
      case 'leaderboard':
        _showLeaderboard();
        break;
      case 'rewards':
        _navigateToRewards();
        break;
      case 'achievements':
        _navigateToAchievements();
        break;
      case 'point_history':
        _navigateToPointHistory();
        break;
      case 'subscription':
        _navigateToSubscription();
        break;
      case 'activity':
        Navigator.push(context, MaterialPageRoute(builder: (_) => const ActivityFeedScreen()));
        break;
      case 'stats':
        _navigateToStats();
        break;
      case 'templates':
        Navigator.push(context, MaterialPageRoute(builder: (_) => const ChoreTemplatesScreen()));
        break;
      case 'invites':
        Navigator.push(context, MaterialPageRoute(builder: (_) => const InviteManagementScreen()));
        break;
      case 'announcements':
        Navigator.push(context, MaterialPageRoute(builder: (_) => const AnnouncementsScreen()));
        break;
      case 'export':
        Navigator.push(context, MaterialPageRoute(builder: (_) => const DataExportScreen()));
        break;
      case 'feedback':
        _navigateToFeedback();
        break;
      case 'settings':
        _navigateToSettings();
        break;
      case 'signout':
        _signOut();
        break;
    }
  }


  Future<void> _showProfileSwitcher() async {
    if (_householdMembers.isEmpty || _myMembership == null) return;

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Switch Profile', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900)),
              const SizedBox(height: 8),
              Text(
                'Kids use their PIN to switch into their profile under this adult account.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
              ..._householdMembers.where((member) {
                final currentUserId = Supabase.instance.client.auth.currentUser?.id;
                return member['kind'] == 'sub_profile' || member['auth_user_id'] == currentUserId;
              }).map((member) {
                final isKid = member['kind'] == 'sub_profile';
                final isActive = member['id'] == _myMembership?['id'];
                return Card(
                  child: ListTile(
                    leading: CircleAvatar(child: Text(isKid ? '👶' : '👤')),
                    title: Text(member['display_name'] ?? 'Unknown', style: const TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: Text(isKid ? 'Kid profile' : 'Adult profile'),
                    trailing: isActive
                        ? const Icon(Icons.check_circle_rounded, color: AppColors.grassGreen)
                        : Icon(isKid ? Icons.lock_outline_rounded : Icons.login_rounded),
                    onTap: isActive
                        ? null
                        : () async {
                            Navigator.pop(context);
                            if (isKid) {
                              await _verifyAndSwitchToKid(member);
                            } else {
                              await ActiveMemberService.instance.switchTo(member['id']);
                              if (mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text('Switched to ${member['display_name']}')),
                                );
                              }
                            }
                          },
                  ),
                );
              }),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _verifyAndSwitchToKid(Map<String, dynamic> member) async {
    // Migration 0013 drops the old pin_hash column, so any kid created
    // before today's migration starts with no PIN until an admin sets one.
    // Gate the verify dialog on has_member_pin; if the PIN isn't set yet,
    // route admins to a Set-PIN dialog and tell non-admins to ask one.
    final hasPin = await Supabase.instance.client.rpc('has_member_pin', params: {
      'p_member_id': member['id'],
    }) as bool;
    if (!mounted) return;

    if (!hasPin) {
      await _promptToSetMissingPin(member);
      return;
    }

    final pinController = TextEditingController();
    final verified = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Enter PIN for ${member['display_name']}'),
        content: TextField(
          controller: pinController,
          autofocus: true,
          obscureText: true,
          keyboardType: TextInputType.number,
          maxLength: 6,
          decoration: const InputDecoration(
            labelText: 'PIN',
            prefixIcon: Icon(Icons.lock_outline_rounded),
            counterText: '',
          ),
          onSubmitted: (_) => Navigator.pop(context, true),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Switch')),
        ],
      ),
    );

    if (verified != true) return;
    final pin = pinController.text.trim();
    // CQ2 resolved 2026-05-22: PIN verification runs server-side via the
    // verify_member_pin RPC (pgcrypto bcrypt, per-row salt). The hash
    // is never read by the client. See supabase/migrations/0013_pin_hashing_bcrypt.sql.
    final ok = await Supabase.instance.client.rpc('verify_member_pin', params: {
      'p_member_id': member['id'],
      'p_pin': pin,
    }) as bool;
    if (!ok) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Incorrect PIN. Please try again.')),
        );
      }
      return;
    }

    await ActiveMemberService.instance.switchTo(member['id']);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Switched to ${member['display_name']}')),
      );
    }
  }

  Future<void> _promptToSetMissingPin(Map<String, dynamic> member) async {
    final isAdmin = Permissions.canManageMembers(_myMembership);

    if (!isAdmin) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${member['display_name']} needs a PIN. Ask an admin to set one.'),
          ),
        );
      }
      return;
    }

    final pinController = TextEditingController();
    final confirmController = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Set PIN for ${member['display_name']}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: pinController,
              autofocus: true,
              obscureText: true,
              keyboardType: TextInputType.number,
              maxLength: 6,
              decoration: const InputDecoration(
                labelText: 'New PIN (4-6 digits)',
                prefixIcon: Icon(Icons.lock_outline_rounded),
                counterText: '',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: confirmController,
              obscureText: true,
              keyboardType: TextInputType.number,
              maxLength: 6,
              decoration: const InputDecoration(
                labelText: 'Confirm PIN',
                prefixIcon: Icon(Icons.lock_outline_rounded),
                counterText: '',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Set PIN')),
        ],
      ),
    );

    if (confirmed != true) return;

    final newPin = pinController.text.trim();
    final confirmPin = confirmController.text.trim();
    if (newPin.length < 4 || newPin.length > 6 || !RegExp(r'^[0-9]+$').hasMatch(newPin)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('PIN must be 4 to 6 digits.')),
        );
      }
      return;
    }
    if (newPin != confirmPin) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('PINs do not match.')),
        );
      }
      return;
    }

    try {
      await Supabase.instance.client.rpc('set_member_pin', params: {
        'p_member_id': member['id'],
        'p_pin': newPin,
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('PIN set for ${member['display_name']}. They can switch in now.')),
        );
      }
    } catch (e) {
      debugPrint('set_member_pin failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not set PIN: $e')),
        );
      }
    }
  }

  Future<void> _showLeaderboard() async {
    if (_household == null) return;

    try {
      final results = await Supabase.instance.client
          .rpc('get_leaderboard', params: {'p_household_id': _household!['id']});

      if (!mounted) return;

      showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        builder: (context) => DraggableScrollableSheet(
          initialChildSize: 0.6,
          minChildSize: 0.3,
          maxChildSize: 0.8,
          expand: false,
          builder: (context, scrollController) => Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(20),
                child: Row(
                  children: [
                    const Icon(Icons.emoji_events_rounded, color: AppColors.honeyGold, size: 28),
                    const SizedBox(width: 12),
                    Text('Leaderboard', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900)),
                    const Spacer(),
                    TextButton.icon(
                      onPressed: () {
                        Navigator.pop(context);
                        _navigateToPointHistory();
                      },
                      icon: const Icon(Icons.history_rounded, size: 18),
                      label: const Text('My History'),
                      style: TextButton.styleFrom(
                        foregroundColor: AppColors.honeyGold,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: (results as List).isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.emoji_events_outlined, size: 64, color: Colors.grey.shade300),
                            const SizedBox(height: 16),
                            Text('No points yet!', style: TextStyle(fontSize: 16, color: Colors.grey.shade500, fontWeight: FontWeight.w600)),
                            const SizedBox(height: 8),
                            Text('Complete chores to earn points and climb the leaderboard.', style: TextStyle(fontSize: 13, color: Colors.grey.shade400), textAlign: TextAlign.center),
                          ],
                        ),
                      )
                    : ListView.builder(
                        controller: scrollController,
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        itemCount: results.length,
                        itemBuilder: (context, i) {
                          final entry = results[i] as Map<String, dynamic>;
                          final rank = entry['rank'] ?? i + 1;
                          final name = entry['display_name'] ?? 'Unknown';
                          final points = entry['points_balance'] ?? 0;
                          final kind = entry['kind'] ?? 'adult_auth_user';
                          final streak = entry['current_streak'] ?? 0;

                          final rankEmoji = switch (rank) {
                            1 => '🥇',
                            2 => '🥈',
                            3 => '🥉',
                            _ => '',
                          };

                          return ListTile(
                            leading: CircleAvatar(
                              backgroundColor: rank <= 3 ? AppColors.honeyGold.withValues(alpha:.2) : Colors.grey.withValues(alpha:.1),
                              child: Text(
                                rankEmoji.isNotEmpty ? rankEmoji : '$rank',
                                style: TextStyle(fontSize: rankEmoji.isNotEmpty ? 22 : 14, fontWeight: FontWeight.w800),
                              ),
                            ),
                            title: Text(name, style: const TextStyle(fontWeight: FontWeight.w700)),
                            subtitle: Row(
                              children: [
                                Text(kind == 'sub_profile' ? 'Kid' : 'Adult'),
                                if (streak > 0) ...[
                                  const SizedBox(width: 8),
                                  const Icon(Icons.local_fire_department_rounded, size: 14, color: AppColors.coral),
                                  Text('$streak streak', style: const TextStyle(fontSize: 12, color: AppColors.coral, fontWeight: FontWeight.w600)),
                                ],
                              ],
                            ),
                            trailing: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                              decoration: BoxDecoration(
                                color: AppColors.honeyGold.withValues(alpha:.15),
                                borderRadius: BorderRadius.circular(100),
                              ),
                              child: Text('$points pts', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: AppColors.honeyGold)),
                            ),
                            onTap: () {
                              final memberId = entry['id'] ?? entry['member_id'];
                              if (memberId != null) {
                                Navigator.pop(context);
                                Navigator.push(context, MaterialPageRoute(builder: (_) => MemberProfileScreen(memberId: memberId)));
                              }
                            },
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not load leaderboard.')),
        );
      }
    }
  }

  Future<void> _signOut() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sign out?'),
        content: const Text('You\'ll need to sign in again to access your household.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Sign out')),
        ],
      ),
    );

    if (confirmed == true) {
      RealtimeService.instance.reset();
      await ActiveMemberService.instance.clear();
      await Supabase.instance.client.auth.signOut();
    }
  }
}
