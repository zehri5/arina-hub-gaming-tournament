import 'package:audioplayers/audioplayers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// REMAINING-ITEMS round: real bundled sound pack (synthesised tones in
/// assets/sounds/, no downloaded audio, no paid assets). Sounds: tap,
/// send, message, mic_join, gift, win. Mute is a real toggle in
/// App Settings (SharedPreferences `sound_enabled`, default ON).
/// Every play is best-effort and never throws into the caller.
class SoundService {
  static final AudioPlayer _player = AudioPlayer();
  static bool _enabled = true;
  static bool _loaded = false;

  static Future<void> init() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      _enabled = prefs.getBool('sound_enabled') ?? true;
    } catch (_) {}
  }

  static bool get enabled => _enabled;

  static Future<void> setEnabled(bool value) async {
    _enabled = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('sound_enabled', value);
    } catch (_) {}
  }

  static Future<void> play(String name) async {
    if (!_enabled) return;
    try {
      await _player.stop();
      await _player.play(AssetSource('sounds/$name.wav'));
    } catch (_) {}
  }

  static Future<void> tap() => play('tap');
  static Future<void> send() => play('send');
  static Future<void> message() => play('message');
  static Future<void> micJoin() => play('mic_join');
  static Future<void> gift() => play('gift');
  static Future<void> win() => play('win');

  // MESSAGE SOUNDS (Sameer's picks, 2026-11-22 — Mixkit, free):
  // message_received = msg_01 "Message pop alert" (message arrives
  // while NOT in the chat); chat_message = chat_08 "Typewriter soft
  // click" (message arrives while INSIDE the chat); notification =
  // notif_02 "Service bell" (general app notification). The old
  // synthesised `message.wav` stays untouched — it is the mic/music
  // request alert, a different sound for a different event.
  static Future<void> messageReceived() => play('message_received');
  static Future<void> chatMessage() => play('chat_message');
  static Future<void> notification() => play('notification');
}
