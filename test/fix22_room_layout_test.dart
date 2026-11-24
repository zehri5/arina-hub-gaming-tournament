// FIX 22 items 12 + 17 + 21 — room layout pins.
// 6 mic seats both scopes; smaller seats; NO tab strip, NO
// back arrow, NO tournament banner, NO bottom Join/VIP/Hot;
// Music/RJ open the unified console; the standalone player
// (_showMusicPlayer) is retired from lib entirely.

import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/services/squad.dart';

import 'audio_test_helpers.dart';

void main() {
  group('fix22 item 12 — seats', () {
    test('micCount == 6 in both scopes', () {
      final community =
          codeOnly(requireProjectFile('lib/screens/communities_screens.dart'));
      expect(community, contains('micCount: 6,'));
      expect(teamMicCount(), 6);
    });

    test('seats slightly smaller (58 extent / 20 radius)', () {
      final room =
          codeOnly(requireProjectFile('lib/screens/room_screen.dart'));
      expect(room, contains('final seatR = 20.0;'));
      expect(room, contains('final seatExtent = 58.0;'));
    });
  });

  group('fix22 items 12b + 17 — nothing above/below the room', () {
    late String room;

    setUpAll(() {
      room = codeOnly(requireProjectFile('lib/screens/room_screen.dart'));
    });

    test('no tab strip in the room', () {
      expect(room, isNot(contains('TabBar(')));
      expect(room, isNot(contains("'Live Chat'")));
      expect(room, isNot(contains("'Voice Chat'")));
    });

    test('no back arrow / AppBar in the room', () {
      expect(room, isNot(contains('AppBar(')));
      expect(room, isNot(contains('BackButton')));
      expect(room, isNot(contains('Icons.arrow_back')));
    });

    test('no tournament banner, no bottom Join/VIP/Hot', () {
      expect(room, isNot(contains('Join Voice Chat')));
      expect(room, isNot(contains("'VIP Room'")));
      expect(room, isNot(contains("'Hot Room'")));
    });
  });

  group('fix22 item 21 — console entries, standalone player retired',
      () {
    test('no _showMusicPlayer references anywhere in lib', () {
      expect(projectTreeContains('lib', '_showMusicPlayer'), isFalse);
    });

    test('Music + RJ entries open the console', () {
      final room =
          codeOnly(requireProjectFile('lib/screens/room_screen.dart'));
      expect(room,
          contains("_showRjVoiceConsole(initialSection: 'player')"));
      expect(room, contains('onRjConsole: _showRjVoiceConsole,'));
    });

    test('player section lives inside the console, with Library', () {
      final room =
          codeOnly(requireProjectFile('lib/screens/room_screen.dart'));
      expect(room, contains('Widget _buildConsoleMusicSection('));
      expect(room, contains('_showMusicPanel()'));
    });
  });
}
