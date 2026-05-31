/// Permission helpers for household member-level authorization.
///
/// Every action helper takes a `Map<String, dynamic>?` membership row
/// (matching the codebase's universal pattern — there's no Membership
/// type) and returns a bool. Null or missing-field membership returns
/// false (deny by default).
///
/// Action helpers internally combine:
///   - kind != 'sub_profile' (defense in depth — kids never pass even
///     if their row had an unexpected role)
///   - role in ('owner', 'admin')
///
/// All action helpers are equivalent today (they all return isAdmin).
/// The named helpers exist to document intent at call sites and to
/// future-proof against per-action permission changes — e.g., if
/// "edit household" later requires owner-only, we change one line here
/// instead of grepping the app.
///
/// Counterpart RLS / RPC enforcement lives in migrations 0017 and 0018.
class Permissions {
  Permissions._();

  // --- Identity checks ---

  /// True if the member exists and is a sub_profile (kid).
  static bool isKid(Map<String, dynamic>? m) {
    if (m == null) return false;
    return m['kind'] == 'sub_profile';
  }

  /// True if the member exists, is NOT a kid, and has role 'owner' or
  /// 'admin'. The single underlying check that every can* helper
  /// delegates to.
  static bool isAdmin(Map<String, dynamic>? m) {
    if (m == null) return false;
    if (m['kind'] == 'sub_profile') return false;
    final role = m['role'];
    return role == 'owner' || role == 'admin';
  }

  /// True if the member is NOT a kid and has role 'owner' specifically.
  /// For display purposes (badge, "the household creator"), not gates —
  /// authorization gates should use isAdmin or one of the can* helpers,
  /// because owner and admin are treated equivalently for permissions.
  static bool isOwner(Map<String, dynamic>? m) {
    if (m == null) return false;
    if (m['kind'] == 'sub_profile') return false;
    return m['role'] == 'owner';
  }

  // --- Action helpers ---
  //
  // All equivalent to isAdmin(m) today. Keep them named so call sites
  // document what they're gating, and so we can tighten one without
  // touching the others.

  /// Can edit household-level settings (name, theme, emoji, subscription).
  /// Disallowed Action #1 from the kid-permissions spec.
  static bool canEditHousehold(Map<String, dynamic>? m) => isAdmin(m);

  /// Can approve/reject chores in pending_verification state.
  /// Disallowed Action #2.
  static bool canVerifyChores(Map<String, dynamic>? m) => isAdmin(m);

  /// Can edit any chore in the household (not just chores assigned to self).
  /// Today this is the admin-only chore-edit gate at chore_detail_screen.
  /// Call sites typically OR this with `isAssignedToMe` for the broader
  /// "admin or own chore" path.
  static bool canEditAnyChore(Map<String, dynamic>? m) => isAdmin(m);

  /// Can add or remove household members, edit other members' profiles,
  /// set or change a kid's PIN. Disallowed Action #3.
  static bool canManageMembers(Map<String, dynamic>? m) => isAdmin(m);

  /// Can generate / revoke household invites. Disallowed Action #9.
  static bool canInviteMembers(Map<String, dynamic>? m) => isAdmin(m);

  /// Can create, edit, or delete reward definitions; also approve or
  /// deny pending redemptions. Disallowed Action #4.
  static bool canManageRewards(Map<String, dynamic>? m) => isAdmin(m);

  /// Can decide pending meal requests and (later) pending wishlist
  /// items. Disallowed Action #5 (the "can decide requests" subset;
  /// the RPC additionally enforces "not the requester").
  static bool canDecideRequests(Map<String, dynamic>? m) => isAdmin(m);

  /// Can edit the household's necessity_categories list (the bypass
  /// list for kid wishlist routing). Disallowed Action #6 (the
  /// category-management part; the per-item wishlist routing is
  /// handled by the add_shopping_item RPC).
  static bool canManageNecessityCategories(Map<String, dynamic>? m) => isAdmin(m);

  /// Can view billing / subscription / authorize.net details.
  /// Disallowed Action #7.
  static bool canManageBilling(Map<String, dynamic>? m) => isAdmin(m);

  /// Can create / edit / delete announcements. Pre-existing gate
  /// (announcements_screen) — not in the spec's Disallowed list but
  /// follows the same admin-only pattern.
  static bool canManageAnnouncements(Map<String, dynamic>? m) => isAdmin(m);

  /// Can create, edit, or delete calendar_tags (the color/emoji labels
  /// applied to events, meals, and chores). Phase 2 of Bug 1 calendar
  /// feature. Backed by the admin-only RLS policies on calendar_tags
  /// (migration 0023).
  static bool canManageTags(Map<String, dynamic>? m) => isAdmin(m);

  /// Can create, edit, or delete stores (the per-household store list
  /// that organizes shopping). Phase 1 Sub-branch 2b-2 of the shopping
  /// rework. Backed by the admin-only RLS policies on stores from
  /// migration 0026.
  static bool canManageStores(Map<String, dynamic>? m) => isAdmin(m);
}
