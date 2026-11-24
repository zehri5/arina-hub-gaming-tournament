// FIX 22 item 21 — GO LIVE broadcast semantics.
// Before GO LIVE, music is local-only (_broadcastMusic defaults
// false). GO LIVE starts the broadcast; END LIVE stops sharing
// and music returns to local-only. The play path shares only
// when broadcast is on.

import 'package:flutter_test/flutter_test.dart';

import 'audio_test_helpers.dart';

String _region(String src, String start, String end) {
  final s = src.indexOf(start);
  if (s < 0) return '';
  final e = src.indexOf(end, s + start.length);
  if (e < 0) return '';
  return src.substring(s, e);
}

void main() {
  group('fix22 item 21 — GO LIVE broadcast', () {
    late String room;
    late String console;

    setUpAll(() {
      room = codeOnly(requireProjectFile('lib/screens/room_screen.dart'));
      console = _region(
        room,
        'Future<void> _showRjVoiceConsole(',
        'void _showLiveKitPanel() {',
      );
    });

    test('broadcast defaults to OFF (local-only until GO LIVE)', () {
      expect(room, contains('bool _broadcastMusic = false;'));
    });

    test('GO LIVE starts the broadcast, END LIVE stops it', () {
      expect(console, isNotEmpty);
      // FIX 24 defect 1: GO LIVE arms ONE path via
      // _goLiveBroadcast (mixer first, upload fallback only when
      // registration fails) — the upload arm is NOT in the
      // handler anymore (arming both played the song twice).
      expect(console, contains('unawaited(_goLiveBroadcast());'));
      expect(console, isNot(contains('unawaited(_setBroadcast(true));')));
      expect(console, contains('unawaited(_setBroadcast(false));'));
    });

    test('play path shares only when broadcast is on', () {
      expect(room, contains('if (_broadcastMusic) {'));
    });

    test('END LIVE keeps playing locally (stop, not stopMusic)', () {
      final setBroadcast = _region(
        room,
        'Future<void> _setBroadcast(bool on) async {',
        'Future<void> _startListeningSession(',
      );
      expect(setBroadcast, isNotEmpty);
      expect(setBroadcast, contains("await _sendMusicAction('stop'"));
      expect(setBroadcast, contains('_broadcastMusic = false;'));
    });
  });
}
