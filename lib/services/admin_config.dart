import 'package:shared_preferences/shared_preferences.dart';

import 'supabase_db.dart';

/// ADMIN IDENTITY (moved here 2026-11-24, FIX 32 admin-panel removal):
/// the designated-admin UID read + the device-local admin-mode marker
/// used to live in the admin login screen, which was deleted with the
/// admin panel. The USER app still needs both:
///
/// * [fetchDesignatedAdminUid] — the fail-closed admin_config id=1
///   read behind the boot-gate bypass (main.dart), the runbook gate
///   (more_screens.dart), AdminDb.isDesignatedAdmin, and the room /
///   Watch Live admin checks.
/// * [AdminMode] — the device-local marker. The user app never SETS
///   it any more (Admin Login + "Switch to Admin" are gone with the
///   panel); it is only CLEARED on logout (auth_screen.dart,
///   more_screens.dart) so a stale marker from an older install can
///   never linger. [AdminMode.isSet] is kept for the separate admin
///   APK's shared code and for tests; nothing in the user app reads
///   it to grant access any more.
///
/// Neither grants anything by itself: every caller re-verifies the
/// signed-in UID against admin_config on a fresh read.
class AdminMode {
  static const String key = 'admin_mode';

  static Future<bool> isSet() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(key) ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> set(bool value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(key, value);
    } catch (_) {}
  }
}

/// Shared admin-identity check. Returns the admin UID ('' if the row
/// cannot be read — fail closed, caller must treat '' as not-admin).
Future<String> fetchDesignatedAdminUid() async {
  try {
    final rows = await SupaDb.getList('admin_config', eqCol: 'id', eqVal: 1);
    if (rows.isNotEmpty) return SupaDb.strOf(rows.first['admin_firebase_uid']);
  } catch (_) {}
  return '';
}
