// ARENA HUB — MESSAGE SOUNDS ROUTING + ASSET TESTS (2026-11-22).
//
// Sameer's picks (by number, 2026-11-22 20:40-20:41; Mixkit, free):
// * MESSAGE (not in the chat): msg_01 "Message pop alert" 0.30 s
//   -> assets/sounds/message_received.wav
// * IN-CHAT (inside the chat): chat_08 "Typewriter soft click"
//   0.30 s -> assets/sounds/chat_message.wav
// * NOTIFICATION (general): notif_02 "Service bell" 0.78 s
//   -> assets/sounds/notification.wav
//
// Tests the pure routing decisions in MessageSounds, the real
// bundled assets (decode to the exact approved frame counts), and
// that playback never throws (muted or enabled).

import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/audio/wav_decoder.dart';
import 'package:protournament_user/services/message_sounds.dart';
import 'package:protournament_user/services/sound_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // AudioPlayer construction + play/stop call these channels; the
  // soundboard tests use the same mocks (an unmocked channel throws
  // MissingPluginException before any test body runs).
  const MethodChannel audioplayersChannel =
      MethodChannel('xyz.luan/audioplayers');
  const MethodChannel audioplayersGlobalChannel =
      MethodChannel('xyz.luan/audioplayers.global');

  setUp(() {
    final TestDefaultBinaryMessengerBinding binding =
        TestDefaultBinaryMessengerBinding.instance;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      audioplayersChannel,
      (MethodCall call) async => null,
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      audioplayersGlobalChannel,
      (MethodCall call) async => null,
    );
  });

  tearDown(() async {
    // SoundService._enabled is static: restore ON so no test leaks
    // a muted state into the next one (the prefs write inside
    // setEnabled fails silently in tests — the flag itself is set).
    await SoundService.setEnabled(true);
    await Future<void>.delayed(Duration.zero);
    final TestDefaultBinaryMessengerBinding binding =
        TestDefaultBinaryMessengerBinding.instance;
    binding.defaultBinaryMessenger
        .setMockMethodCallHandler(audioplayersChannel, null);
    binding.defaultBinaryMessenger
        .setMockMethodCallHandler(audioplayersGlobalChannel, null);
  });

  group('in-chat arrival routing (chat sound)', () {
    test('primed + grew + not mine -> play', () {
      expect(
        MessageSounds.shouldPlayChatSound(
            primed: true, grew: true, lastIsMine: false),
        isTrue,
      );
    });

    test('first load (unprimed) -> never beeps for history', () {
      expect(
        MessageSounds.shouldPlayChatSound(
            primed: false, grew: true, lastIsMine: false),
        isFalse,
      );
    });

    test('no growth -> no beep', () {
      expect(
        MessageSounds.shouldPlayChatSound(
            primed: true, grew: false, lastIsMine: false),
        isFalse,
      );
    });

    test('own message -> no beep', () {
      expect(
        MessageSounds.shouldPlayChatSound(
            primed: true, grew: true, lastIsMine: true),
        isFalse,
      );
    });
  });

  group('notification arrival routing (notification sound)', () {
    test('unread count rises -> play', () {
      expect(
        MessageSounds.shouldPlayNotificationSound(
            previousUnread: 2, currentUnread: 3),
        isTrue,
      );
    });

    test('first emission (no previous) -> no beep', () {
      expect(
        MessageSounds.shouldPlayNotificationSound(
            previousUnread: null, currentUnread: 3),
        isFalse,
      );
    });

    test('same count -> no beep', () {
      expect(
        MessageSounds.shouldPlayNotificationSound(
            previousUnread: 3, currentUnread: 3),
        isFalse,
      );
    });

    test('count drops (mark-read / delete-all) -> no beep', () {
      expect(
        MessageSounds.shouldPlayNotificationSound(
            previousUnread: 3, currentUnread: 0),
        isFalse,
      );
    });
  });

  group('push routing (foreground OneSignal)', () {
    test('chat-marked pushes get the message sound', () {
      for (final type in [
        'chat',
        'chat_message',
        'dm',
        'direct_message',
        'message',
      ]) {
        expect(
          MessageSounds.soundForPush({'type': type}),
          MessageSound.message,
          reason: "type '$type' should route to the message sound",
        );
        expect(
          MessageSounds.soundForPush({'kind': type}),
          MessageSound.message,
          reason: "kind '$type' should route to the message sound",
        );
      }
    });

    test('type matching is case-insensitive', () {
      expect(
        MessageSounds.soundForPush({'type': 'CHAT_MESSAGE'}),
        MessageSound.message,
      );
      expect(
        MessageSounds.soundForPush({'type': 'Dm'}),
        MessageSound.message,
      );
    });

    test('no data at all -> notification sound (today\'s pushes)', () {
      expect(MessageSounds.soundForPush(null), MessageSound.notification);
      expect(MessageSounds.soundForPush({}), MessageSound.notification);
    });

    test('other types -> notification sound', () {
      expect(
        MessageSounds.soundForPush({'type': 'team_invite'}),
        MessageSound.notification,
      );
      expect(
        MessageSounds.soundForPush({'type': 'support_reply'}),
        MessageSound.notification,
      );
    });
  });

  group('bundled assets are the approved sounds', () {
    Future<Float32List> decode(String asset) async {
      final data = await rootBundle.load('assets/sounds/$asset');
      final bytes = data.buffer.asUint8List();
      expect(bytes.lengthInBytes, greaterThan(0), reason: '$asset empty');
      return WavDecoder.decodeToMono48k(bytes);
    }

    test('message_received.wav is msg_01: 0.30 s = 14400 frames', () async {
      expect((await decode('message_received.wav')).length, 14400);
    });

    test('chat_message.wav is chat_08: 0.30 s = 14400 frames', () async {
      expect((await decode('chat_message.wav')).length, 14400);
    });

    test('notification.wav is notif_02: 0.78 s = 37418 frames', () async {
      expect((await decode('notification.wav')).length, 37418);
    });
  });

  group('playback never throws', () {
    test('muted: all three sounds return silently', () async {
      await SoundService.setEnabled(false);
      expect(SoundService.enabled, isFalse);
      await MessageSounds.play(MessageSound.chat);
      await MessageSounds.play(MessageSound.message);
      await MessageSounds.play(MessageSound.notification);
    });

    test('enabled: all three sounds play without throwing', () async {
      await SoundService.setEnabled(true);
      await MessageSounds.play(MessageSound.chat);
      await MessageSounds.play(MessageSound.message);
      await MessageSounds.play(MessageSound.notification);
    });
  });
}
