// v2015 (2026-11-22) — Home slider left cut + Room screen 3 items.
//
// Bug 4: the hero slider card's LEFT edge read cut on the phone —
// the v2010 rotateY(-0.06) tilt pushed the card's left edge ~2dp
// past the PageView box with perspective, and the ClipRect cut the
// left gold border + glow (the right edge, pulled inward by the
// same tilt, kept its border). rotateY is removed; the slanted
// clip path already carries the mockup's 3D look. These tests pin
// the matrix (source) AND prove the geometry: the kept matrix
// (perspective + rotateX) never pushes any corner more than a
// sub-pixel past the box, while the old matrix pushed the left
// edge midpoint ~1.7dp out (the control that would have caught it).
// Bug 5 (Room): (a) the sidebar 'Mic On' FAB is removed — Follow
// stays the only rail FAB; (b) the host card's top mute/unmute
// button is a CIRCLE now (was a rounded rectangle), label below
// it like the rail FABs; (c) the host card's MockupCard shines
// are parked (animate: false) — the rotating bottom shine
// travelled along the bottom edge and read as a thin yellow
// divider line under the card; parked shines sit at the
// top-right + bottom-left corners and no line crosses the bottom.
// Room screen widget tests are impractical here (Firebase +
// Supabase + LiveKit), so (a)–(c) are source pins.
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

/// Projects a hero point (x, y) through the tilt matrix the way
/// Flutter does: rotateX first (then rotateY for the old matrix),
/// then the perspective divide (entry (3,2) = 0.0012). Returns the
/// projected x. The hero box is 328 wide (360 − 16×2 margins), so
/// the left edge sits at x = −164.
double _projectX(double x, double y, {required bool withRotateY}) {
  const persp = 0.0012;
  const rx = 0.02;
  const ry = -0.06;
  // rotateX(0.02): x unchanged; z' = y·sin(rx).
  double px = x;
  double pz = y * math.sin(rx);
  if (withRotateY) {
    // rotateY(-0.06): x' = x·cos + z·sin; z' = −x·sin + z·cos.
    final nx = px * math.cos(ry) + pz * math.sin(ry);
    final nz = -px * math.sin(ry) + pz * math.cos(ry);
    px = nx;
    pz = nz;
  }
  final w = 1 + persp * pz;
  return px / w;
}

void main() {
  group('Bug 4 — hero tilt keeps the card inside its box', () {
    test('tilt matrix has no rotateY (source pin)', () {
      final src = _read('lib/screens/home_screens.dart');
      final start = src.indexOf('Matrix4 _heroTiltMatrix()');
      expect(start, isNot(-1));
      final end = src.indexOf(';', start);
      final fn = src.substring(start, end);
      expect(fn, contains('setEntry(3, 2, 0.0012)'));
      expect(fn, contains('rotateX(0.02)'));
      expect(fn, isNot(contains('rotateY')));
    });

    test('kept matrix: no edge leaves the box by more than a pixel',
        () {
      // Card 328×216; left edge x = −164, right edge +164.
      const halfW = 164.0;
      const halfH = 108.0;
      // Left-edge midpoint: y = 0, so rotateX moves nothing — the
      // projected x must be exactly the box edge.
      expect(_projectX(-halfW, 0, withRotateY: false), halfW * -1);
      // All four corners: the rotateX perspective shift is
      // sub-pixel (< 1dp) on both sides.
      for (final corner in [
        (-halfW, -halfH),
        (halfW, -halfH),
        (-halfW, halfH),
        (halfW, halfH),
      ]) {
        final px = _projectX(corner.$1, corner.$2, withRotateY: false);
        expect(px.abs() - halfW, lessThan(1.0));
      }
    });

    test('old matrix (control): rotateY pushed the left edge out',
        () {
      // The regression this fix removes: with rotateY(-0.06) the
      // left-edge midpoint projected ~1.7dp past the box — past
      // the ClipRect, which cut the left border + glow.
      const halfW = 164.0;
      final px = _projectX(-halfW, 0, withRotateY: true);
      expect(-halfW - px, greaterThan(1.5));
    });
  });

  group('Bug 5 — Room screen', () {
    late String roomSrc;
    setUpAll(() {
      roomSrc = _read('lib/screens/room_screen.dart');
    });

    test('(a) sidebar has no Mic On FAB — Follow is the only rail FAB',
        () {
      final start = roomSrc.indexOf('_railBtn(Icons.music_note');
      final end = roomSrc.indexOf('_railBtn(Icons.exit_to_app', start);
      expect(start, isNot(-1));
      expect(end, greaterThan(start));
      final rail = roomSrc.substring(start, end);
      expect(rail, contains("'Follow'"));
      // Exactly one floating rail button left (Follow). The old
      // block also used Icons.mic — gone with it.
      expect('_railFab('.allMatches(rail).length, 1);
      expect(rail, isNot(contains('Icons.mic')));
    });

    test('(b) host mute/unmute button is a circle, ON/OFF label below', () {
      // FIX 22 item 18a: the button shows STATE now — 'ON' when
      // the mic is on, 'OFF' when muted (the old Mute/Unmute
      // action label is gone).
      final label = roomSrc.indexOf("micOn ? 'ON' : 'OFF'");
      expect(label, isNot(-1));
      // The button's Container sits just above its label text.
      final button = roomSrc.substring(label - 900, label);
      expect(button, contains('shape: BoxShape.circle'));
      expect(button, contains('width: 56'));
      expect(button, contains('height: 56'));
      expect(button,
          isNot(contains('borderRadius: BorderRadius.circular(16)')));
      expect(button,
          isNot(contains('EdgeInsets.symmetric(horizontal: 16, vertical: 12)')));
    });

    test('(c) host card shines are parked (no bottom-edge line)', () {
      final comment = roomSrc.indexOf('MASTER-PROMPT host panel');
      expect(comment, isNot(-1));
      final card = roomSrc.indexOf('MockupCard(', comment);
      expect(card, isNot(-1));
      final window = roomSrc.substring(card, card + 400);
      expect(window, contains('radius: 22'));
      expect(window, contains('animate: false'));
    });
  });
}
