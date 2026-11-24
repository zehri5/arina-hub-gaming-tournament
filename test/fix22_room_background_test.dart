// FIX 22 item 18 — room background pins.
// The whole voice room is dark + gold: the old blue/magenta
// glows and the pink/purple painter accents are gold now, the
// heart icon is gone, and the embedded panel sits on a
// kSurface -> kBg gradient.

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
  group('fix22 item 18 — gold background, no pink/purple/blue', () {
    late String room;
    late String painter;

    setUpAll(() {
      room = codeOnly(requireProjectFile('lib/screens/room_screen.dart'));
      painter = _region(
        room,
        'class _OrnateRoomPainter extends CustomPainter {',
        'class _UnifiedRoomPageState extends State<UnifiedRoomPage> {',
      );
    });

    test('painter region exists', () {
      expect(painter, isNotEmpty);
    });

    test('painter accents are gold, not pink/purple', () {
      expect(painter, contains('nGold'));
      expect(painter, isNot(contains('nPink')));
      expect(painter, isNot(contains('nPurple')));
    });

    test('background glows are gold', () {
      expect(room, contains('nGold.withValues(alpha: 0.10)'));
      expect(room, contains('nGold.withValues(alpha: 0.08)'));
    });

    test('no heart icon in the room background', () {
      // The old decorative heart (top-right of the room Stack)
      // is removed; hearts only survive in earlier widgets
      // (e.g. the seat like-hearts), never as background decor.
      // build() is the last method of the state class, so the
      // background region runs from the painter to EOF.
      final start = room.indexOf(
          'Positioned.fill(child: CustomPaint(painter: _OrnateRoomPainter())),');
      expect(start, isNot(-1));
      final bg = room.substring(start);
      expect(bg, isNotEmpty);
      expect(bg, isNot(contains('Icons.favorite')));
      expect(bg, isNot(contains('Icons.heart_broken')));
    });

    test('embedded panel wrapped in the app background layer (FIX 23 items 14+21)', () {
      final embedded = _region(
        room,
        'Widget _buildEmbeddedVoice(',
        'Widget build(BuildContext context) {',
      );
      expect(embedded, isNotEmpty);
      // FIX 23 items 14+21 SUPERSEDE the fix22 gold gradient
      // ([kSurface, kBg]): the embedded panel now shows the
      // app-wide background layer (item-21 image + smoke), with
      // the stored-background gradient (_bgColors) as the
      // override path.
      expect(embedded, isNot(contains('colors: [kSurface, kBg]')));
      expect('AppBackgroundLayer'.allMatches(embedded).length, 1);
      expect(embedded, contains('_bgColors'));
      expect(embedded, contains('LinearGradient('));
    });
  });
}
