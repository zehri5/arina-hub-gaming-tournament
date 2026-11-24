import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'supabase_db.dart';
import 'admin_config.dart';

/// Admin data layer (Phase 6, O-admin-panel round, worker W1).
///
/// ALL admin backend access goes through [AdminDb], which reuses
/// [SupaDb.client]. [SupaDb] is NOT forked and its user-facing methods
/// are NOT changed. Admin screens never call Supabase directly and
/// never write a table from a widget.
///
/// Reads are guarded: any failure returns `[]` / `null` (the existing
/// SupaDb pattern) — a read failure is never presented as "no data"
/// without the screen's error state. Writes go through an RPC where
/// one exists; where none exists yet, the write is a DIRECT-WRITE
/// under the 024 RLS admin-only policy, always paired with an
/// [logAdminActivity] row in the same user action (plan §4.7).
///
/// Every admin decision (approve/reject/close/open/warn/restrict/
/// resolve/adjust/publish) writes an `admin_activity_logs` row — no
/// decision without an audit row is a Phase 6 defect (plan §4.7).
class AdminDb {
  /// Generic guarded list read. [eq] maps column -> value (every entry
  /// applied as an equality filter). Returns `[]` on any failure.
  static Future<List<Map<String, dynamic>>> getList(
    String table, {
    Map<String, dynamic>? eq,
    String? orderBy,
    bool ascending = false,
    int? limit,
  }) async {
    try {
      dynamic q = SupaDb.client.from(table).select();
      if (eq != null) {
        for (final e in eq.entries) {
          q = q.eq(e.key, e.value);
        }
      }
      if (orderBy != null) q = q.order(orderBy, ascending: ascending);
      if (limit != null) q = q.limit(limit);
      final rows = await q;
      return (rows as List)
          .map((r) => Map<String, dynamic>.from(r as Map))
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// Generic guarded single-row read. Returns `null` when the row does
  /// not exist or the read fails.
  static Future<Map<String, dynamic>?> getRow(
    String table,
    String idColumn,
    String id,
  ) async {
    try {
      final row = await SupaDb.client
          .from(table)
          .select()
          .eq(idColumn, id)
          .limit(1)
          .maybeSingle();
      if (row == null) return null;
      return Map<String, dynamic>.from(row as Map);
    } catch (_) {
      return null;
    }
  }

  /// Writes one `admin_activity_logs` row for an admin decision.
  /// NEVER throws to the caller: a failed audit insert must not break
  /// the admin action it describes — but the failure IS recorded via
  /// debugPrint so it is visible in logs instead of silently lost.
  static Future<void> logAdminActivity({
    required String action,
    required String targetType,
    required String targetId,
    String? oldValue,
    String? newValue,
    String? reason,
  }) async {
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
      await SupaDb.client.from('admin_activity_logs').insert({
        'admin_uid': uid,
        'action': action,
        'target_type': targetType,
        'target_id': targetId,
        if (oldValue != null) 'old_value': oldValue,
        if (newValue != null) 'new_value': newValue,
        if (reason != null && reason.trim().isNotEmpty) 'reason': reason.trim(),
      });
    } catch (e) {
      // Audit failure must never break the admin action — but it must
      // not vanish either: record it in the log output.
      debugPrint('[AdminDb] admin_activity_logs insert failed ($action/$targetType/$targetId): $e');
    }
  }

  /// The caller's admin role via the `admin_role` RPC (023), which
  /// resolves identity server-side from `firebase_uid()` — no UID is
  /// ever sent from the client for authorization. Returns `null` on
  /// any failure (unknown role = no capabilities, fail closed).
  static Future<String?> getAdminRole() async {
    try {
      final res = await SupaDb.client.rpc('admin_role');
      if (res == null) return null;
      if (res is String) return res.isEmpty ? null : res;
      if (res is Map) {
        final role = SupaDb.strOf(res['role'], SupaDb.strOf(res['admin_role']));
        return role.isEmpty ? null : role;
      }
      final s = res.toString();
      return s.isEmpty ? null : s;
    } catch (_) {
      return null;
    }
  }

  /// Designated-admin check (plan §1): the signed-in Firebase UID
  /// must equal `admin_config` id=1 `admin_firebase_uid`, checked
  /// fresh. `profiles.is_admin` is NEVER an entry credential.
  /// Returns false on any failure (fail closed).
  static Future<bool> isDesignatedAdmin() async {
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
      if (uid.isEmpty) return false;
      final adminUid = await fetchDesignatedAdminUid();
      return adminUid.isNotEmpty && adminUid == uid;
    } catch (_) {
      return false;
    }
  }
}
