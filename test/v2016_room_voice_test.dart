// v2016 (2026-11-22) — 5 Room fixes Sameer found in v2015.
//
// Fix 1: the thin vertical yellow divider between the Host pill
// column and the Live pill on the host card is GONE.
// Fix 2: the 'Good Vibes • Real Talks • Heart Connects' tagline
// under Room Owner read cut ('Good Vibes • Re…') — it now wraps
// UNCAPPED (no maxLines): maxLines 2 still cut "Connects" on a
// 360dp phone, where the text column is only ~94px wide and the
// tagline needs 3 lines. The string is fixed-length and the card
// grows vertically, so the full text always shows.
// SUPERSEDED by FIX 12 G7 (2026-11-23 §7): the tagline is now
// REMOVED outright — the top box shows the organizer's name only.
// Fix 3: the speaker toggle did nothing and audio stayed on the
// earpiece. TWO root causes, both proven from code:
//   (a) LiveKitVoiceService._notify() called ITSELF
//       (`if (!_disposed) _notify();`) — infinite recursion, so
//       every notify threw StackOverflowError and NO LiveKit state
//       change ever reached the UI (the Switch never moved).
//   (b) the MESH engine's toggle was dead too: LiveKit's plugin
//       disables flutter_webrtc's native audio management at
//       attach (setAudioSessionManagementEnabled(false)), so the
//       mesh Helper calls are no-ops — and on a mesh visit no
//       LiveKit room ever connects, so LiveKit's native session is
//       never started either. The mesh now starts that session
//       itself (once, via LiveKit's own MethodChannel) and routes
//       through LiveKit's AudioManager — the only live control.
//   Plus a delayed re-apply in the LiveKit service as insurance
//   for the native start/snapshot race.
// Fix 4: Bluetooth never connected. The manifest permissions were
// verified present (both manifests + the shipped v2015 APK), so
// the gap was the runtime flow: the join-time request result was
// swallowed silently — a denial (or a permanent one) left the
// user with no idea why BT never worked. The result is now
// checked: denied = honest toast, permanently denied = a dialog
// with a direct Open Settings shortcut. Voice never blocks.
// Fix 5: chat bar — the raise-hand button is GONE; the photo
// upload moved INSIDE the text field (left corner) as a small
// WhatsApp-style attach icon (no round image button outside).
//
// Room screen widget tests are impractical here (Firebase +
// Supabase + LiveKit), so fixes 1, 2, 4, 5 and the mesh half of
// fix 3 are source pins (the v2015 pattern). The LiveKit service
// IS constructible in a test (no Firebase at construction), so
// its toggle behaviour is a real unit test — including the
// listener notification, which is the test that would have caught
// the _notify recursion before it shipped.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/services/livekit_voice_service.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  group('Fix 1 — host card divider gone', () {
    test('no vertical divider container in the room screen', () {
      final src = _read('lib/screens/room_screen.dart');
      expect(src, isNot(contains('width: 1, height: 56')));
    });
  });

  group('Fix 2 — Good Vibes tagline REMOVED (FIX 12 G7 supersedes)', () {
    test('tagline is gone from the top box', () {
      // FIX 12 G7 (user order 2026-11-23 §7): the 'Good Vibes •
      // Real Talks • Heart Connects' tagline is REMOVED from the
      // top box — the organizer's name is the only label there.
      // This group used to pin the tagline's uncapped wrap; it
      // now pins the removal (see
      // fix12_g7_organizer_name_test.dart).
      final src = _read('lib/screens/room_screen.dart');
      expect(src.indexOf('Good Vibes • Real Talks • Heart Connects'),
          -1);
    });
  });

  group('Fix 3 — speakerphone toggle', () {
    test('LiveKit _notify notifies (no self-recursion)', () {
      final src = _read('lib/services/livekit_voice_service.dart');
      final idx = src.indexOf('void _notify()');
      expect(idx, isNot(-1));
      final lineEnd = src.indexOf('\n', idx);
      final line = src.substring(idx, lineEnd);
      expect(line, contains('notifyListeners()'));
      // The body after '{' must not call _notify() again.
      final body = line.substring(line.indexOf('{'));
      expect(body, isNot(contains('_notify()')));
    });

    test('LiveKit service has the delayed re-apply guard', () {
      final src = _read('lib/services/livekit_voice_service.dart');
      expect(src, contains('_speakerRouteGen'));
      expect(src, contains('Future.delayed(const Duration(milliseconds: 700)'));
    });

    test('mesh routes through LiveKit AudioManager + starts its session',
        () {
      final src = _read('lib/services/voice_service.dart');
      final start = src.indexOf('Future<void> _applySpeakerRoute()');
      expect(start, isNot(-1));
      final window = src.substring(start, start + 3000);
      expect(window, contains("MethodChannel('livekit_client')"));
      expect(window, contains('configureAndroidAudioSession'));
      expect(window, contains('setSpeakerOutputPreferred'));
    });

    test('mesh leave stops the session it started', () {
      final src = _read('lib/services/voice_service.dart');
      final start = src.indexOf('Future<void> leave()');
      expect(start, isNot(-1));
      // leave() grew past 1200 chars above the stop call (timers,
      // foreground-service stop, peer cleanup) — the call now sits
      // ~1300 chars in. 2000 covers the whole body; the stop call
      // occurs only once in this file (inside leave()), so the
      // wider window cannot pass from any other method.
      final window = src.substring(start, start + 2000);
      expect(window, contains('_lkSessionStartedByMesh'));
      expect(window, contains('stopAndroidAudioSession'));
    });

    test('speakerOn is always true; reapplySpeakerRoute completes', () async {
      // FIX 22 item 7: setSpeaker is DELETED — the speaker
      // preference is permanently ON (no toggle, no earpiece).
      // The route is re-asserted via reapplySpeakerRoute, which
      // must complete without throwing (the old setSpeaker
      // threw StackOverflowError before the v2016 fix when its
      // _notify recursed — the re-apply path must not regress).
      final svc = LiveKitVoiceService(roomId: 't1', roomLabel: 'Test');
      expect(svc.speakerOn, isTrue);
      await svc.reapplySpeakerRoute();
      expect(svc.speakerOn, isTrue);
      // Let the delayed re-assert fire inside the test so a
      // failure in it cannot leak into the next test as an
      // unhandled error.
      await Future.delayed(const Duration(milliseconds: 900));
      expect(svc.speakerOn, isTrue);
      svc.dispose();
    });

    test('repeated reapplySpeakerRoute calls complete without throwing',
        () async {
      final svc = LiveKitVoiceService(roomId: 't1', roomLabel: 'Test');
      await svc.reapplySpeakerRoute();
      await svc.reapplySpeakerRoute();
      await svc.reapplySpeakerRoute();
      expect(svc.speakerOn, isTrue);
      await Future.delayed(const Duration(milliseconds: 900));
      svc.dispose();
    });

    test('setMuted flips muted AND notifies listeners', () async {
      final svc = LiveKitVoiceService(roomId: 't1', roomLabel: 'Test');
      var notified = 0;
      svc.addListener(() => notified++);
      await svc.setMuted(false);
      expect(svc.muted, isFalse);
      expect(notified, 1);
      svc.dispose();
    });
  });

  group('Fix 4 — Bluetooth permission flow', () {
    test('both manifests declare BLUETOOTH_CONNECT', () {
      for (final path in [
        'android/app/src/main/AndroidManifest.xml',
        'build/manual-apk/AndroidManifest.xml',
      ]) {
        final manifest = _read(path);
        expect(manifest, contains('android.permission.BLUETOOTH_CONNECT'),
            reason: path);
      }
    });

    test('join flow checks the Bluetooth request result', () {
      final src = _read('lib/screens/room_screen.dart');
      final idx = src.indexOf('Permission.bluetoothConnect.request()');
      expect(idx, isNot(-1));
      // The result must be captured and acted on, not swallowed.
      final window = src.substring(idx - 200, idx + 2200);
      expect(window, contains('final bt = await'));
      expect(window, contains('isPermanentlyDenied'));
      expect(window, contains('openAppSettings()'));
      expect(window, contains('Bluetooth permission'));
    });
  });

  group('Fix 5 — chat bar', () {
    late String roomSrc;
    setUpAll(() {
      roomSrc = _read('lib/screens/room_screen.dart');
    });

    test('raise-hand button is gone', () {
      expect(roomSrc, isNot(contains('Icons.pan_tool')));
      expect(roomSrc, isNot(contains("'Raise hand'")));
    });

    test('attach icon lives inside the field, small, WhatsApp-style',
        () {
      final start = roomSrc.indexOf('MASTER-PROMPT composer');
      final end = roomSrc.indexOf('BOTTOM BAR REMOVED', start);
      expect(start, isNot(-1));
      expect(end, greaterThan(start));
      final composer = roomSrc.substring(start, end);
      expect(composer, contains('prefixIcon:'));
      expect(composer, contains('Icons.attach_file'));
      // Small: 20px icon in a tight 36px box, not the old 24px
      // icon on a 44px round disc.
      expect(composer, contains('iconSize: 20'));
      expect(composer, contains('minWidth: 36, minHeight: 36'));
      // No round image button left in the composer.
      expect(composer, isNot(contains('Icons.image')));
    });
  });
}
