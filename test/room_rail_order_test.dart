// ROOM RAIL REORDER (2026-11-22 user order) + DATE-PILL REMOVAL —
// source-invariant regression tests. No network, no Supabase init,
// no Firebase init: they read the R-copy sources and assert the
// shapes the user ordered. If any of these fail, the rail order or
// the pill removal has regressed — do NOT ship.
//
// Covered:
//   1. Right rail order (top -> bottom): Room Home, Settings,
//      Voice Connect, Music, Follow, Leave Room LAST. (v2015: the
//      Mic On FAB was REMOVED by user order 2026-11-22 — mic
//      toggle lives on the seat + the host card's circular
//      button now. Invite is squad-only and sits after Room
//      Home; Refresh is LiveKit-test-only and Voice On indicators
//      are connected-only — both stay beside Voice, not in the
//      fixed order.)
//   2. No Participants button on the rail (the Participants/Status
//      sheet itself is untouched — only the rail entry is gone).
//   3. No scheduled-start date pill above the mic grid: the
//      _roomStartLabel helper is gone and _voiceStrip takes no
//      tournament row anymore.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  late String room;

  setUpAll(() {
    room = _read('lib/screens/room_screen.dart');
  });

  String navRail() {
    final start = room.indexOf('Widget _navRail()');
    expect(start, isNot(-1), reason: 'missing _navRail');
    final end = room.indexOf('// Circular floating rail button', start);
    expect(end, isNot(-1), reason: 'missing _navRail end marker');
    return room.substring(start, end);
  }

  group('Room rail order (2026-11-22)', () {
    test('fixed buttons run Room Home, Settings, Voice, Music, Follow, Leave Room',
        () {
      final rail = navRail();
      // Call markers (not bare labels — comments also mention the
      // labels, so the call sites pin the real order).
      final markers = <String, String>{
        'Room Home': "_railBtn(Icons.home, 'Room Home'",
        'Settings': "_railBtn(Icons.settings, 'Settings'",
        // Voice button ternary (connected ? 'Voice On' : 'Voice').
        'Voice': "connected ? 'Voice On' : 'Voice'",
        'Music': "_railBtn(Icons.music_note, 'Music'",
        // Follow FAB: gold heart icon (unique in the rail).
        'Follow': 'Icons.favorite,',
        'Leave Room': "_railBtn(Icons.exit_to_app, 'Leave Room'",
      };
      var prev = -1;
      for (final entry in markers.entries) {
        final at = rail.indexOf(entry.value);
        expect(at, isNot(-1), reason: 'missing rail button: ${entry.key}');
        expect(at, greaterThan(prev),
            reason: '${entry.key} is out of order in the rail');
        prev = at;
      }
    });

    test('Mic On FAB is gone (v2015 user order)', () {
      final rail = navRail();
      // The removed FAB called _railFab(Icons.mic, 'Mic On', ...)
      // — Icons.mic with a trailing comma was unique to it (the
      // Voice button ternary has no comma after Icons.mic).
      expect(rail, isNot(contains('Icons.mic,')));
      // Follow stays the only floating rail button.
      expect('_railFab('.allMatches(rail).length, 1);
    });

    test('Leave Room is the last rail button', () {
      final rail = navRail();
      final leaveAt = rail.indexOf("_railBtn(Icons.exit_to_app, 'Leave Room'");
      expect(leaveAt, isNot(-1));
      // Nothing but whitespace/closers follows the Leave Room
      // button line itself.
      final afterButton =
          rail.substring(rail.indexOf('\n', leaveAt) + 1);
      expect(afterButton, isNot(contains('_railBtn(')));
      expect(afterButton, isNot(contains('_railFab(')));
    });

    test('no Participants button on the rail', () {
      final rail = navRail();
      expect(rail, isNot(contains("_railBtn(Icons.people, 'Participants'")));
      expect(rail, isNot(contains("'Participants'")));
    });

    test('Participants sheet itself still exists (menu + seat tap)', () {
      // The removal is rail-only: _openStatus still serves the room
      // menu and the occupied-seat tap.
      expect(room, contains('void _openStatus()'));
      expect(room, contains("row(Icons.people, 'Participants / Status'"));
    });
  });

  group('Date pill above the mic grid (2026-11-22)', () {
    test('_roomStartLabel helper is gone', () {
      expect(room, isNot(contains('String? _roomStartLabel')));
      expect(room, isNot(contains("Starts \${d.day}")));
    });

    test('v2016 fix 7: _voiceStrip is gone entirely', () {
      expect(room, isNot(contains('Widget _voiceStrip(')));
      expect(room, isNot(contains('_voiceStrip(')));
      expect(room, isNot(contains("Text('LIVE VOICE CHAT'")));
    });
  });
}
