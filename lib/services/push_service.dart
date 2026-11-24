import 'package:firebase_auth/firebase_auth.dart';
import 'package:onesignal_flutter/onesignal_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../config.dart';
import 'message_sounds.dart';
import 'supabase_db.dart';

/// OneSignal push.
///
/// The App ID is NEVER hardcoded: it comes from app_settings `onesignal`
/// (map {appId, restApiKey} or flat onesignal_app_id) — read at runtime.
/// The REST key is read from app_settings.onesignal at SEND time by the
/// admin app; this user app never sends pushes and never embeds the key.
/// While no App ID is set, initialisation is skipped gracefully and
/// in-app Supabase notifications keep working. Do NOT claim push works
/// until a real App ID is configured.
class PushService {
  static bool _initialised = false;
  static String? _appId;

  static Future<void> init() async {
    if (_initialised) return;
    // Master notifications toggle (Profile / Settings): when the user
    // turned notifications off, push stays uninitialised (audit fix
    // 2026-11-21 — the toggle previously had no effect at all).
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool('notificationsEnabled') == false) return;
    } catch (_) {}
    String appId = AppConfig.oneSignalAppId;
    try {
      final settings = await SupaDb.getAppSettings();
      final one = SupaDb.asMap(settings['onesignal']);
      final fromSettings = SupaDb.strOf(one['appId'], SupaDb.strOf(one['app_id'], SupaDb.strOf(settings['onesignal_app_id'])));
      if (fromSettings.isNotEmpty) appId = fromSettings;
    } catch (_) {}
    if (appId.isEmpty) return;
    _appId = appId;
    OneSignal.initialize(appId);
    OneSignal.Notifications.requestPermission(true);
    // MESSAGE SOUNDS (Sameer's picks, 2026-11-22): a push that
    // arrives while the app is in the foreground plays one of his
    // sounds — the MESSAGE pop (msg_01) when the payload marks it
    // as a chat/DM/message push, the NOTIFICATION bell (notif_02)
    // otherwise. No chat push exists yet (today only team-invite /
    // support pushes are sent, with no `data` field), so chat
    // pushes must carry `data: {type: 'chat_message'}` to get the
    // message sound. The notification itself is NOT suppressed —
    // display proceeds as before. Playback honours the
    // `sound_enabled` mute toggle inside SoundService, and this
    // whole listener never registers when the master
    // `notificationsEnabled` toggle is off (early return above).
    OneSignal.Notifications.addForegroundWillDisplayListener((event) {
      final sound =
          MessageSounds.soundForPush(event.notification.additionalData);
      MessageSounds.play(sound);
    });
    _initialised = true;
    await syncPlayerId();
  }

  /// Stores the OneSignal player ID on the profile (`onesignal_id`).
  static Future<void> syncPlayerId() async {
    // FIX (2026-10-27): previously returned early when _initialised was
    // false (e.g. first init skipped because the App ID was not yet
    // configured), so a later login never synced the player ID.
    // Now: ensure init first, then sync, with one best-effort delayed
    // retry when the pushSubscription id is initially null.
    if (!_initialised) await init();
    if (!_initialised) return;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    try {
      OneSignal.login(user.uid);
      var id = OneSignal.User.pushSubscription.id;
      if (id == null || id.isEmpty) {
        // Player ID can be null on first launch; one delayed retry.
        await Future.delayed(const Duration(seconds: 3));
        id = OneSignal.User.pushSubscription.id;
      }
      if (id != null && id.isNotEmpty) {
        await SupaDb.updateProfile(user.uid, {'onesignal_id': id});
      }
    } catch (_) {}
  }

  static Future<void> logout() async {
    if (!_initialised) return;
    try {
      await OneSignal.logout();
    } catch (_) {}
    _initialised = false;
  }

  static String? get appId => _appId;
  static bool get isInitialised => _initialised;
}
