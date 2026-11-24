import 'package:protournament_user/platform/core/lifecycle.dart';
import 'package:protournament_user/platform/core/local_store.dart';
import 'package:protournament_user/services/supabase_db.dart';

/// Lifecycle auto-notifications (ChatGPT blueprint §5-6; backend
/// guide §5-6 `notification_log` + `notification_dismissals`).
///
/// Sends through the EXISTING [SupaDb.notifyUser] path (the app's
/// `user_notifications` table — the admin notifications UI already
/// reads it), then mirrors the send into PlatformLocalStore area
/// 'notification_log' with the guide's column names, until the
/// backend `notification_log` table lands (guide §3 Phase 8).
///
/// Dismissals mirror the guide's `notification_dismissals` table
/// (keyed by firebase_uid + notification_id) in local store area
/// 'notification_dismissals'. The existing device-local hide in
/// SharedPreferences is untouched — this is the server-mirror side.
///
/// NOTHING HERE EVER THROWS: a failed send is logged locally and
/// swallowed, so a notification failure can never crash a flow.
class LifecycleNotificationService {
  static const String _logArea = 'notification_log';
  static const String _logId = 'all';
  static const String _dismissArea = 'notification_dismissals';
  static const String _dismissId = 'all';

  /// Builds title/body via [notificationContent], sends via
  /// [SupaDb.notifyUser], and logs the send locally. `vars` supplies
  /// the tournament name (`vars['tournament']`) and, where relevant,
  /// `date`, `time` or `rank`.
  static Future<void> trigger(
    NotificationEvent event, {
    required String uid,
    String? tournamentId,
    String? matchId,
    Map<String, String> vars = const {},
  }) async {
    final content = notificationContent(event, vars);
    try {
      await SupaDb.notifyUser(uid, content.title, content.body);
    } catch (_) {
      // notifyUser is already best-effort; a failure here must never
      // throw — the local log below still records the attempt.
    }
    try {
      final rows =
          await PlatformLocalStore.loadList(_logArea, _logId);
      rows.add({
        'firebase_uid': uid,
        'kind': event.wireValue,
        'tournament_id': tournamentId,
        'match_id': matchId,
        'title': content.title,
        'body': content.body,
        'sent_at': DateTime.now().toIso8601String(),
        'channel': 'in_app',
      });
      await PlatformLocalStore.saveList(_logArea, _logId, rows);
    } catch (_) {
      // Local logging must never throw either.
    }
  }

  /// Records a permanent dismissal of a global broadcast
  /// notification (guide §5-6 `notification_dismissals`, keyed by
  /// firebase_uid + notification_id). Duplicate dismissals are
  /// ignored. The existing device-local hide stays as-is.
  static Future<void> dismissGlobal(String uid, String notificationId) async {
    try {
      final rows = await PlatformLocalStore.loadList(
          _dismissArea, _dismissId);
      final already = rows.any((r) =>
          r['firebase_uid'] == uid && r['notification_id'] == notificationId);
      if (already) return;
      rows.add({
        'firebase_uid': uid,
        'notification_id': notificationId,
        'dismissed_at': DateTime.now().toIso8601String(),
      });
      await PlatformLocalStore.saveList(_dismissArea, _dismissId, rows);
    } catch (_) {
      // Dismissal recording must never throw.
    }
  }

  /// True when this user already dismissed this notification.
  static Future<bool> isDismissed(String uid, String notificationId) async {
    try {
      final rows = await PlatformLocalStore.loadList(
          _dismissArea, _dismissId);
      return rows.any((r) =>
          r['firebase_uid'] == uid && r['notification_id'] == notificationId);
    } catch (_) {
      return false;
    }
  }

  /// Local mirror of the send log (guide `notification_log` rows),
  /// newest last. For admin/debug views until the backend table lands.
  static Future<List<Map<String, dynamic>>> listLog() =>
      PlatformLocalStore.loadList(_logArea, _logId);
}
