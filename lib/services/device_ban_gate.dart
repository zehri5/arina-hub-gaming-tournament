import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import 'supabase_db.dart';

/// Device-ban login gate (P2, 2026-11-22).
///
/// Ground facts, verified against STAGING (project
/// yiofwceischeqicwdhmy, 2026-11-22) — not taken from the audit on
/// trust:
/// * `device_bans` EXISTS, 0 rows. Columns: `id` uuid PK
///   (gen_random_uuid()), `device_id` text NOT NULL, `firebase_uid`
///   text NULL, `reason` text NULL, `banned_by` text NULL,
///   `created_at` timestamptz NOT NULL default now().
/// * RLS is ON with one policy, `anon_all_device_bans` (role anon,
///   ALL commands, qual `true`) — the anon Supabase client used at
///   login CAN read it. (The same policy also lets anon write; that
///   is pre-existing staging state, NOT something this gate creates —
///   server-side write restriction waits for the JWT auth bridge,
///   same as every other admin write in this app.)
/// * NO `check_login_allowed` RPC exists, so the gate reads the table
///   directly (two indexed equality lookups, limit 1 each).
/// * Device identity is the scheme `_deviceCheck` has used since
///   migration 008: a per-install id in SharedPreferences under
///   `device_id`, mirrored on `profiles.device_id`. No new device-id
///   scheme is invented here. (`profiles.install_id` from the 030
///   draft does NOT exist on staging, so it is NOT used.)
///
/// FAIL-OPEN, deliberately: any read error returns "not banned".
/// Login is the app's front door — a transient Supabase / network /
/// RLS failure must never lock every user out. A missed ban is
/// recoverable (the check runs again on the next login, and the admin
/// can re-ban); a broken login is a total outage. This matches the
/// best-effort style of the rest of the login flow (`_deviceCheck`,
/// `_recordLoginSession` both swallow failures).
typedef DeviceBanReader = Future<List<Map<String, dynamic>>> Function(
  String table, {
  String? eqCol,
  dynamic eqVal,
  int? limit,
});

class DeviceBanGate {
  /// The stable per-install device id, creating it on first use.
  /// Same 16-random-bytes-as-hex scheme as the old inline code in
  /// `AuthScreen._deviceCheck` (moved here so the gate and the
  /// duplicate-account check share one source of truth).
  static Future<String> localDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    var deviceId = prefs.getString('device_id');
    if (deviceId == null || deviceId.isEmpty) {
      final rnd = Random.secure();
      deviceId = List.generate(
        16,
        (_) => rnd.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
      await prefs.setString('device_id', deviceId);
    }
    return deviceId;
  }

  /// True when [uid] OR [deviceId] has a row in `device_bans`.
  /// [readBans] is a test seam only (production always reads via
  /// [SupaDb.getListOrThrow], which throws on a failed read so the
  /// fail-open branch below can tell "read failed" apart from "no
  /// ban" — `getList` would silently return [] for both).
  static Future<bool> isBanned({
    required String uid,
    required String deviceId,
    DeviceBanReader? readBans,
  }) async {
    final read = readBans ?? _readBans;
    try {
      final byUid = await read(
        'device_bans',
        eqCol: 'firebase_uid',
        eqVal: uid,
        limit: 1,
      );
      if (byUid.isNotEmpty) return true;
      if (deviceId.isEmpty) return false;
      final byDevice = await read(
        'device_bans',
        eqCol: 'device_id',
        eqVal: deviceId,
        limit: 1,
      );
      return byDevice.isNotEmpty;
    } catch (_) {
      // FAIL-OPEN: a failed ban read never blocks login (see above).
      return false;
    }
  }

  static Future<List<Map<String, dynamic>>> _readBans(
    String table, {
    String? eqCol,
    dynamic eqVal,
    int? limit,
  }) =>
      SupaDb.getListOrThrow(table, eqCol: eqCol, eqVal: eqVal, limit: limit);
}
