import 'sound_service.dart';

/// Which of Sameer's 3 chosen sounds to play for an event.
enum MessageSound {
  /// In-chat arrival (inside the chat screen): chat_08 "Typewriter
  /// soft click" — the WhatsApp-style short pop.
  chat,

  /// Message arrival while NOT in the chat: msg_01 "Message pop
  /// alert".
  message,

  /// General app notification (non-message): notif_02 "Service bell".
  notification,
}

/// MESSAGE SOUNDS routing (Sameer's picks, 2026-11-22).
///
/// The three sounds and their events:
/// * [MessageSound.chat] — a new message from SOMEONE ELSE arrives
///   while the user is INSIDE that chat screen (team / community /
///   DM / room / watch-live chat).
/// * [MessageSound.message] — a new chat message arrives while the
///   user is NOT in that chat. Today the only funnel is a OneSignal
///   push received while the app is in the foreground (see
///   PushService); no chat push exists yet, so this fires the
///   moment the backend/admin starts sending chat pushes with a
///   type marker (see [soundForPush]). Backgrounded-app sound is
///   the OS default until a custom notification sound ships with
///   the push payload (native + backend work, not this round).
/// * [MessageSound.notification] — the unread-notification count
///   (bell badge) INCREASES — a new general notification row
///   (team invite, slot confirmed, support reply, ...).
///
/// Every decision here is pure (unit-tested in
/// test/message_sounds_test.dart) so the call sites stay one-liners.
/// Playback is best-effort via [SoundService]: it honours the
/// `sound_enabled` mute toggle and never throws into the caller —
/// a missing/unplayable file fails silently, never a crash/toast,
/// and never blocks message delivery.
class MessageSounds {
  /// In-chat arrival: play the short pop ONLY when the stream is
  /// already primed (not the first load — opening a chat must not
  /// beep for its history), the list GREW, and the newest message
  /// is NOT mine (my own sends never beep).
  static bool shouldPlayChatSound({
    required bool primed,
    required bool grew,
    required bool lastIsMine,
  }) =>
      primed && grew && !lastIsMine;

  /// Notification arrival: play ONLY when the unread count ROSE
  /// from a known previous value. `previousUnread == null` is the
  /// first emission (app start / stream subscribe) — never a beep.
  /// A drop (mark-read / delete-all) is never a beep either.
  static bool shouldPlayNotificationSound({
    required int? previousUnread,
    required int currentUnread,
  }) =>
      previousUnread != null && currentUnread > previousUnread;

  /// Push routing (OneSignal foreground listener): a push whose
  /// additional data marks it as a chat/DM/message push gets the
  /// MESSAGE sound; anything else (incl. no data at all — today's
  /// team-invite/support pushes carry no `data` field) gets the
  /// NOTIFICATION sound. Case-insensitive; checks both `type` and
  /// `kind` keys so either backend spelling works.
  static MessageSound soundForPush(Map<String, dynamic>? data) {
    if (data != null) {
      for (final key in const ['type', 'kind']) {
        final v = data[key]?.toString().toLowerCase() ?? '';
        if (v == 'chat' ||
            v == 'chat_message' ||
            v == 'dm' ||
            v == 'direct_message' ||
            v == 'message') {
          return MessageSound.message;
        }
      }
    }
    return MessageSound.notification;
  }

  /// Fire-and-forget play. Never throws; respects the mute toggle
  /// inside [SoundService].
  static Future<void> play(MessageSound sound) {
    switch (sound) {
      case MessageSound.chat:
        return SoundService.chatMessage();
      case MessageSound.message:
        return SoundService.messageReceived();
      case MessageSound.notification:
        return SoundService.notification();
    }
  }
}
