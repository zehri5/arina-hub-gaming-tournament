// FIX 22 items 15 + 20 + 21 — sidebar pins.
// The sidebar is the FINAL 5 round-icon entries (item 15,
// supersedes items 5 + 12e): Followers, Music, RJ Panel,
// Settings, Leave Room. No rectangular cards, no Room Home /
// Participants / Tournament Info / Gift / Mic entries.

import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/screens/room_screen.dart';

import 'audio_test_helpers.dart';

String _region(String src, String start, String end) {
  final s = src.indexOf(start);
  if (s < 0) return '';
  final e = src.indexOf(end, s + start.length);
  if (e < 0) return '';
  return src.substring(s, e);
}

void main() {
  group('fix22 item 15 + fix23 item 11 — sidebar: 6 round-icon entries', () {
    late String room;
    late String sidebar;

    setUpAll(() {
      room = codeOnly(requireProjectFile('lib/screens/room_screen.dart'));
      sidebar = _region(
        room,
        'Widget _buildEmbeddedSidebar() {',
        'Widget _buildEmbeddedVoice(',
      );
    });

    test('sidebar region exists', () {
      expect(sidebar, isNotEmpty);
    });

    test('exactly 6 round-icon buttons, in order', () {
      // 7 matches = 1 definition + 6 call sites (FIX 23 item 11
      // adds the Power entry before Leave Room — Leave stays
      // last).
      final count = '_sidebarRoundBtn('.allMatches(sidebar).length;
      expect(count, 7);
      final followers = sidebar.indexOf('Icons.people');
      final music = sidebar.indexOf('Icons.music_note');
      final rj = sidebar.indexOf('Icons.graphic_eq');
      final settings = sidebar.indexOf('Icons.settings');
      final power = sidebar.indexOf('Icons.power_settings_new_rounded');
      final leave = sidebar.indexOf('Icons.exit_to_app');
      expect(followers, isNot(-1));
      expect(music, greaterThan(followers));
      expect(rj, greaterThan(music));
      expect(settings, greaterThan(rj));
      expect(power, greaterThan(settings));
      expect(leave, greaterThan(power));
      expect(sidebar, contains("'Power'"));
    });

    test('no rectangular rail buttons in the sidebar', () {
      expect(sidebar, isNot(contains('_railBtn(')));
      expect(sidebar, isNot(contains('_railFab(')));
    });

    test('no removed entries in the sidebar', () {
      expect(sidebar, isNot(contains("'Room Home'")));
      expect(sidebar, isNot(contains("'Participants'")));
      expect(sidebar, isNot(contains("'Tournament Info'")));
      expect(sidebar, isNot(contains("'Gift'")));
      expect(sidebar, isNot(contains("'Mic'")));
    });

    test('FIX 23 item 6: neon colors on the sidebar buttons', () {
      // The no-pink/purple rule is SUPERSEDED by the user's neon
      // order (2026-11-23): each button gets its own neon color.
      expect(sidebar, contains('neon: _neonPink'));
      expect(sidebar, contains('neon: _neonCyan'));
      expect(sidebar, contains('neon: _neonPurple'));
      expect(sidebar, contains('neon: _neonLime'));
      expect(sidebar, contains('neon: _neonOrange'));
    });

    test('Music opens the console focused on the player', () {
      expect(room,
          contains("_showRjVoiceConsole(initialSection: 'player')"));
    });

    test('RJ Panel opens the console (default effects focus)', () {
      expect(room, contains('onRjConsole: _showRjVoiceConsole,'));
    });
  });

  group('fix22 item 15 — formatCompactCount', () {
    test('small counts stay plain', () {
      expect(formatCompactCount(0), '0');
      expect(formatCompactCount(1), '1');
      expect(formatCompactCount(999), '999');
    });

    test('K tier, whole and one-decimal', () {
      expect(formatCompactCount(1000), '1K');
      expect(formatCompactCount(1500), '1.5K');
    });

    test('M / B / T tiers', () {
      expect(formatCompactCount(1000000), '1M');
      expect(formatCompactCount(2500000), '2.5M');
      expect(formatCompactCount(1000000000), '1B');
      expect(formatCompactCount(1000000000000), '1T');
    });

    test('negatives clamp to 0', () {
      expect(formatCompactCount(-5), '0');
    });
  });
}
