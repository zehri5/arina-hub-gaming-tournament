// v2016 FIX 6 (2026-11-22) — mic seat numbers 1-9 redesigned.
// The free-seat disc (52px gradient disc + mic glyph + number) was
// already redesigned in the tree; the gap was that OCCUPIED seats
// showed no number at all (the photo replaced it) and LOCKED seats
// showed only a lock. Both now carry the small gold
// MicSeatNumberBadge (top-left corner, dimmed on locked seats).
//
// The badge widget itself has no Firebase/Supabase/LiveKit
// dependency, so it IS pumpable in a real widget test — unlike the
// full Room screen (see v2016_room_voice_test.dart header).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/screens/room_screen.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  group('MicSeatNumberBadge widget', () {
    testWidgets('renders the seat number in white (FIX 23 item 6 neon)', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: Center(child: MicSeatNumberBadge(seatNo: 3))),
      ));
      expect(find.text('3'), findsOneWidget);
      final text = tester.widget<Text>(find.text('3'));
      // FIX 23 item 6: the number is white now; the neon lives
      // in the ring + glow (gold number superseded).
      expect(text.style?.color, Colors.white);
      expect(text.style?.fontWeight, FontWeight.w900);
    });

    testWidgets('dimmed variant: white number, muted neon ring (FIX 23 item 6)', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: Center(child: MicSeatNumberBadge(seatNo: 7, dimmed: true))),
      ));
      expect(find.text('7'), findsOneWidget);
      final text = tester.widget<Text>(find.text('7'));
      // FIX 23 item 6: dimming lives in the ring (neon at 0.55),
      // not the number — the number stays white.
      expect(text.style?.color, Colors.white);
      expect(text.style?.fontWeight, FontWeight.w900);
    });

    testWidgets('badge is an 18px circle', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: Center(child: MicSeatNumberBadge(seatNo: 1))),
      ));
      final size = tester.getSize(find.byType(MicSeatNumberBadge));
      expect(size, const Size(18, 18));
    });
  });

  group('Fix 6 wiring (source pins)', () {
    test('occupied cell shows the seat number badge', () {
      final src = _read('lib/screens/room_screen.dart');
      expect(src, contains('MicSeatNumberBadge(seatNo: i + 1)'));
    });

    test('locked cell shows the dimmed number badge', () {
      final src = _read('lib/screens/room_screen.dart');
      expect(src, contains('MicSeatNumberBadge(seatNo: seatNo, dimmed: true)'));
    });

    test('free-seat disc keeps the redesigned number (white, FIX 23 item 6)', () {
      final src = _read('lib/screens/room_screen.dart');
      // FIX 23 item 6: the free-disc number is white now (neon
      // ring + glow carry the color); 17px w900 unchanged.
      expect(src, contains("Text('\$seatNo', style: const TextStyle(color: Colors.white, fontSize: 17"));
    });
  });
}
