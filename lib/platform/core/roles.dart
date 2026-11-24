import 'package:protournament_user/utils.dart';

/// App roles for the multi-organizer platform (ChatGPT blueprint §1/§8;
/// backend guide §4: roles enum `super_admin` / `regional_admin` /
/// `organizer` / `player`, stored in `organization_members.role` and
/// `profiles.role`).
///
/// Wire values are the guide's snake_case strings. [AppRole.fromString]
/// accepts both snake_case (`regional_admin`) and camelCase
/// (`regionalAdmin`).
enum AppRole {
  player,
  organizer,
  regionalAdmin,
  superAdmin;

  /// User-facing label (Roman Urdu via tr()).
  String get label => switch (this) {
        AppRole.player => tr('Player', 'Player'),
        AppRole.organizer => tr('Organizer', 'Organizer'),
        AppRole.regionalAdmin => tr('Regional Admin', 'Regional Admin'),
        AppRole.superAdmin => tr('Super Admin', 'Super Admin'),
      };

  /// Server wire value (backend guide §4).
  String get wireValue => switch (this) {
        AppRole.player => 'player',
        AppRole.organizer => 'organizer',
        AppRole.regionalAdmin => 'regional_admin',
        AppRole.superAdmin => 'super_admin',
      };

  /// Parses a stored role string (snake_case or camelCase). Returns null
  /// when the value is unknown — callers fall back to [AppRole.player].
  static AppRole? tryFromString(String? raw) {
    if (raw == null) return null;
    final norm = raw.toLowerCase().replaceAll(RegExp(r'[_\-\s]'), '');
    for (final role in AppRole.values) {
      if (role.name.toLowerCase() == norm) return role;
    }
    return null;
  }

  static AppRole fromString(String? raw,
          [AppRole fallback = AppRole.player]) =>
      tryFromString(raw) ?? fallback;
}

/// Resolves a profile row to an [AppRole] and answers permission
/// questions as pure static bools.
///
/// IMPORTANT — UI GATING ONLY: these helpers decide what the app
/// SHOWS. They do not enforce anything on the server. Real
/// enforcement (tenant isolation, admin-only RPCs) is a backend
/// handoff item — under the current anon-key auth model the server
/// cannot trust a client-sent role at all (backend guide §2).
class RoleService {
  /// Resolves the role from a profile map.
  ///
  /// Reads `role` (or legacy `app_role`) as a string, then the
  /// `is_organizer` / `is_regional_admin` bool flags. Anything
  /// unknown resolves to [AppRole.player].
  ///
  /// `superAdmin` is returned ONLY when the caller passes
  /// [isSuperAdmin] = true. A profile row that merely CLAIMS
  /// `super_admin` without that flag falls back to player — the
  /// existing admin check lives in `admin_config` id=1 and is NOT
  /// re-implemented here; the caller passes the flag after doing
  /// that check.
  static AppRole roleOf(Map<String, dynamic> profile,
      {bool isSuperAdmin = false}) {
    if (isSuperAdmin) return AppRole.superAdmin;
    final raw = profile['role'] ?? profile['app_role'];
    final parsed = AppRole.tryFromString(raw?.toString());
    // A profile string alone can never grant super admin.
    if (parsed == AppRole.superAdmin) return AppRole.player;
    if (parsed != null) return parsed;
    if (profile['is_organizer'] == true || profile['isOrganizer'] == true) {
      return AppRole.organizer;
    }
    if (profile['is_regional_admin'] == true ||
        profile['isRegionalAdmin'] == true) {
      return AppRole.regionalAdmin;
    }
    return AppRole.player;
  }

  /// Create tournaments. Players cannot — they must first apply to
  /// become an organizer (backend guide §7).
  static bool canCreateTournament(AppRole role) =>
      role == AppRole.organizer ||
      role == AppRole.regionalAdmin ||
      role == AppRole.superAdmin;

  /// Verify submitted match results (Approve / Request Correction /
  /// Reject). Organizers verify their own tournaments; regional and
  /// super admins verify across their scope.
  static bool canVerifyResults(AppRole role) =>
      role == AppRole.organizer ||
      role == AppRole.regionalAdmin ||
      role == AppRole.superAdmin;

  /// Approve / suspend organizer accounts and organizations.
  static bool canManageOrganizers(AppRole role) =>
      role == AppRole.regionalAdmin || role == AppRole.superAdmin;

  /// Manage a country: enable/disable it, assign its regional admin,
  /// see its growth stats.
  static bool canManageCountry(AppRole role) =>
      role == AppRole.regionalAdmin || role == AppRole.superAdmin;

  /// See financial records (organizers see only their own org's;
  /// regional/super admins see their scope).
  static bool canViewFinancials(AppRole role) =>
      role == AppRole.organizer ||
      role == AppRole.regionalAdmin ||
      role == AppRole.superAdmin;

  /// Moderate: act on disputes, exceptions and flagged content.
  static bool canModerate(AppRole role) =>
      role == AppRole.regionalAdmin || role == AppRole.superAdmin;
}
