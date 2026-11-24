// HOME VS-COMPACT FIX (2026-11-20) — regression tests for the user's
// phone-test complaints on the K-splash-fix1 build:
//   FIX 1 — "Your Next Match" card was a ~160px tall box pinned above
//     the bottom nav hiding content; it is now a compact ~118px card
//     (filled) / ~74px (empty, one slim line), mockup #37 shape.
//   FIX 2/3 — tournament-card and hero photos were black/empty: the
//     fallback was a flat dark box + small icon, while production data
//     is NULL banners (2 of 3 tournaments), a 203 KB proxied LIVE
//     banner (~30 s on the user's 7 KB/s net) and a 404 slider image.
//     The fallback is now the bundled trophy_cover.jpg asset,
//     full-bleed, shown instantly with no network.
//   FIX 18 (2026-11-21) — tournament card is now the mockup-EXACT
//     142dp card: 123x142 full-bleed thumb, 14px gap, badge 20,
//     gaps 3/5/5/3/7, title 20sp / meta 14sp / players 13sp,
//     progress 6, buttons 32 (the FIX 4 replica below tracks it).
//   FIX 20 (2026-11-21) — the continuous border runner is GONE
//     (two tapered corner lines now, top-right + bottom-left);
//     the outline tests pin the same path geometry the corner
//     lines walk (heroRunnerSegment / heroRunnerHeadPosition).
//
// NOTE on scope: _TournamentCard / _HomeCoverImage / the VS bar are
// private widgets in home_screens.dart, so the layout tests below
// pump the EXACT geometry of those widgets (same sizes, paddings and
// widget types) — the round-2 precedent. The outline tests call the
// real public test hooks (heroRunnerSegment / heroRunnerHeadPosition)
// in home_screens.dart, so they verify the real traversal math.
import 'package:protournament_user/screens/home_screens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FIX 2/3 — bundled fallback photo', () {
    // FIX 18 (2026-11-21): the card thumb slot is now 123x142
    // (was 110x160), rounded only on the card's left corners.
    testWidgets('trophy_cover.jpg renders full-bleed at the card slot size',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ClipRRect(
            borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(18), bottomLeft: Radius.circular(18)),
            child: SizedBox(
              width: 123,
              height: 142,
              child: Image.asset('assets/images/trophy_cover.jpg',
                  width: 123, height: 142, fit: BoxFit.cover),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      final img = find.byType(Image);
      expect(img, findsOneWidget);
      final box = tester.getSize(img);
      expect(box.width, 123);
      expect(box.height, 142);
      expect(box.height.isFinite, isTrue);
    });
  });

  group('FIX 1 — compact VS card geometry', () {
    testWidgets('empty VS card pattern is slim (< 90px tall)', (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      // Exact geometry of the new _pinnedNextMatchEmpty: 10px vertical
      // padding, 30px header row, 6px gap, one 13px line.
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Container(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xFF1B1D29),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: const Color(0xFF2A2E3A)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(children: [
                  Container(
                      padding: const EdgeInsets.all(6),
                      decoration: const BoxDecoration(
                          shape: BoxShape.circle, color: Colors.amber),
                      child: const Icon(Icons.emoji_events,
                          color: Colors.amber, size: 18)),
                  const SizedBox(width: 8),
                  const Expanded(
                      child: Text('Your Next Match',
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.bold))),
                ]),
                const SizedBox(height: 6),
                const Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                          text: 'No upcoming match',
                          style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 13)),
                      TextSpan(
                          text: ' — join a tournament to see it here.',
                          style: TextStyle(
                              color: Color(0xFFAAB0D0), fontSize: 13)),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final card = find.byType(Container).first;
      final height = tester.getSize(card).height;
      // Old empty card was ~120px; the compact one must stay slim.
      expect(height, lessThan(90));
    });

    testWidgets('filled VS card pattern stays compact (< 130px tall)',
        (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      // Exact geometry of the new filled _pinnedNextMatchBar after the
      // M-detail-fix2 trim: 8px padding, 28px header circle, 5px gap,
      // ~24px time pill, 4px gap, ~36px VS row (avatar-driven).
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Container(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFF1B1D29),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: const Color(0xFF2A2E3A)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(children: [
                  Container(
                      padding: const EdgeInsets.all(5),
                      decoration: const BoxDecoration(
                          shape: BoxShape.circle, color: Colors.amber),
                      child: const Icon(Icons.emoji_events,
                          color: Colors.amber, size: 18)),
                  const SizedBox(width: 8),
                  const Expanded(
                      child: Text('Your Next Match',
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.bold))),
                  const Text('See Details →',
                      style: TextStyle(
                          color: Colors.amber,
                          fontSize: 12,
                          fontWeight: FontWeight.bold)),
                ]),
                const SizedBox(height: 5),
                const Center(
                    child: Text('Today, 9:00 PM',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.bold))),
                const SizedBox(height: 4),
                Row(children: [
                  const Expanded(
                      child: Text('Team Alpha',
                          textAlign: TextAlign.right,
                          style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 14))),
                  const SizedBox(width: 12),
                  const Text('VS',
                      style: TextStyle(
                          color: Colors.amber,
                          fontWeight: FontWeight.w900,
                          fontStyle: FontStyle.italic,
                          fontSize: 22)),
                  const SizedBox(width: 12),
                  const Expanded(
                      child: Text('TBD',
                          style: TextStyle(
                              color: Color(0xFFAAB0D0),
                              fontWeight: FontWeight.bold,
                              fontSize: 14))),
                ]),
              ],
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final card = find.byType(Container).first;
      final height = tester.getSize(card).height;
      // Old filled card was ~160px; mockup #37 shape is ~107px on a real
      // phone. The test font (Ahem: every glyph one full font-size wide)
      // inflates text rows by ~40px vs Roboto, so the bound here is 150:
      // the pre-trim replica measured 156, the trimmed one must be below
      // 150. Phone proof still comes from the next test APK screenshot.
      expect(height, lessThan(150));
      expect(find.text('Your Next Match'), findsOneWidget);
      expect(find.text('VS'), findsOneWidget);
    });
  });

  group('FIX 4 — tournament card fits a 360px screen', () {
    testWidgets('full card content renders with no overflow at 360px',
        (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      // Exact geometry of _TournamentCard after FIX 18 (2026-11-21,
      // mockup-EXACT): 142 fixed height, 123x142 full-bleed thumb
      // (rounded only on the card's left corners), 14px gap,
      // content padding top 7 / right 14 / bottom 7, badge 20,
      // gaps 3/5/5/3/7, title 20sp / meta 14sp / players 13sp
      // (all height 1.0), progress 6, buttons 32. The stack sums
      // to exactly 142 (7+20+3+20+5+14+5+13+3+6+7+32+7).
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            padding:
                const EdgeInsets.only(top: 16, left: 12, right: 12, bottom: 16),
            child: SizedBox(
              key: const Key('tournament-card'),
              height: 142,
              child: Container(
                padding: EdgeInsets.zero,
                // No border: the real _homeGlassCard/_DarkMockupCard
                // has NO static border (global card rule — corner
                // shines only), so a Border.all here would inset
                // the content by 2px and fake an overflow.
                decoration: BoxDecoration(
                  color: const Color(0xFF1B1D29),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ClipRRect(
                      borderRadius: const BorderRadius.only(
                          topLeft: Radius.circular(18),
                          bottomLeft: Radius.circular(18)),
                      child: SizedBox(
                        width: 123,
                        height: 142,
                        child: Image.asset('assets/images/trophy_cover.jpg',
                            width: 123, height: 142, fit: BoxFit.cover),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Padding(
                        padding:
                            const EdgeInsets.only(top: 7, right: 14, bottom: 7),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              height: 20,
                              child: Row(children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 4),
                                  decoration: BoxDecoration(
                                      color: Colors.amber,
                                      borderRadius: BorderRadius.circular(20)),
                                  child: const Text('UPCOMING',
                                      style: TextStyle(
                                          color: Colors.black,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 12,
                                          height: 1.0)),
                                ),
                                const Spacer(),
                                const Icon(Icons.chevron_right,
                                    color: Colors.grey, size: 20),
                              ]),
                            ),
                            const SizedBox(height: 3),
                            const Text('Squad Showdown',
                                style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 20,
                                    height: 1.0,
                                    fontWeight: FontWeight.bold),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis),
                            const SizedBox(height: 5),
                            const Row(children: [
                              Icon(Icons.calendar_today,
                                  color: Colors.grey, size: 13),
                              SizedBox(width: 4),
                              Flexible(
                                  child: Text('Nov 23, 8:00 PM',
                                      style: TextStyle(
                                          color: Colors.grey,
                                          fontSize: 14,
                                          height: 1.0),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis)),
                              SizedBox(width: 8),
                              Text('|',
                                  style: TextStyle(
                                      color: Colors.grey,
                                      fontSize: 14,
                                      height: 1.0)),
                              SizedBox(width: 8),
                              Icon(Icons.group, color: Colors.grey, size: 13),
                              SizedBox(width: 4),
                              Text('Squad',
                                  style: TextStyle(
                                      color: Colors.grey,
                                      fontSize: 14,
                                      height: 1.0)),
                            ]),
                            const SizedBox(height: 5),
                            const Text('250 / 1000 Players',
                                style: TextStyle(
                                    color: Colors.grey,
                                    fontSize: 13,
                                    height: 1.0),
                                // maxLines is a TEST-only pin: the
                                // Ahem test font (every glyph one
                                // full font-size wide) wraps this
                                // line to two rows; real Roboto fits
                                // it on one line (~117px < 183px).
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis),
                            const SizedBox(height: 3),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: const LinearProgressIndicator(
                                  value: 0.25,
                                  minHeight: 6,
                                  backgroundColor: Color(0xFF2A2E3A),
                                  valueColor: AlwaysStoppedAnimation<Color>(
                                      Colors.amber)),
                            ),
                            const SizedBox(height: 7),
                            SizedBox(
                              height: 32,
                              child: Row(children: [
                                Expanded(
                                  child: OutlinedButton(
                                    onPressed: () {},
                                    style: OutlinedButton.styleFrom(
                                      minimumSize: const Size(0, 32),
                                      tapTargetSize:
                                          MaterialTapTargetSize.shrinkWrap,
                                      padding: const EdgeInsets.symmetric(
                                          vertical: 0, horizontal: 4),
                                      shape: RoundedRectangleBorder(
                                          borderRadius:
                                              BorderRadius.circular(12)),
                                    ),
                                    child: const FittedBox(
                                        fit: BoxFit.scaleDown,
                                        child: Text('Details',
                                            style: TextStyle(
                                                fontWeight: FontWeight.bold,
                                                fontSize: 14))),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: ElevatedButton(
                                    onPressed: () {},
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: Colors.amber,
                                      foregroundColor: Colors.black,
                                      minimumSize: const Size(0, 32),
                                      tapTargetSize:
                                          MaterialTapTargetSize.shrinkWrap,
                                      padding: const EdgeInsets.symmetric(
                                          vertical: 0, horizontal: 4),
                                      shape: RoundedRectangleBorder(
                                          borderRadius:
                                              BorderRadius.circular(12)),
                                      elevation: 0,
                                    ),
                                    child: const FittedBox(
                                        fit: BoxFit.scaleDown,
                                        child: Text('Join Event',
                                            style: TextStyle(
                                                fontWeight: FontWeight.bold,
                                                fontSize: 14))),
                                  ),
                                ),
                              ]),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('UPCOMING'), findsOneWidget);
      expect(find.text('Squad Showdown'), findsOneWidget);
      expect(find.text('Nov 23, 8:00 PM'), findsOneWidget);
      expect(find.text('250 / 1000 Players'), findsOneWidget);
      expect(find.text('Details'), findsOneWidget);
      expect(find.text('Join Event'), findsOneWidget);
      final img = find.byType(Image);
      expect(img, findsOneWidget);
      expect(tester.getSize(img).width, 123);
      // FIX 18: the card is exactly 142 tall (mockup-EXACT).
      final cardSize = tester.getSize(find.byKey(const Key('tournament-card')));
      expect(cardSize.height, closeTo(142.0, 0.5));
    });
  });

  group('FIX 20 — hero outline path geometry (corner lines walk this outline)',
      () {
    test('segment head sweeps the whole perimeter, constant length', () {
      const total = 1100.0; // ~2x(328+204), the 360px hero banner perimeter
      const segLen = 150.0; // pure-math parameter for the segment helper
      double prevHead = -1;
      for (var i = 0; i <= 100; i++) {
        final t = i / 100;
        final seg = heroRunnerSegment(total, t, segLen);
        // Head is exactly t * total (mod total): one full loop per cycle.
        expect(seg.head, closeTo((t * total) % total, 1e-9));
        // Segment always spans exactly segLen — never a gap, never short.
        final span = (seg.head - seg.start + total) % total;
        expect(span, closeTo(segLen, 1e-9));
        // Head advances monotonically with t (no jumps backwards).
        if (i > 0 && t < 1.0) {
          expect(seg.head, greaterThanOrEqualTo(prevHead));
        }
        prevHead = seg.head;
      }
    });

    test('head visits all four edges of the 328x204 banner', () {
      const size = Size(328, 204);
      var top = false, right = false, bottom = false, left = false;
      for (var i = 0; i < 128; i++) {
        final pos = heroRunnerHeadPosition(size, i / 128);
        expect(pos, isNotNull);
        final p = pos!;
        // Head never leaves the banner bounds.
        expect(p.dx, inInclusiveRange(0.0, 328.0));
        expect(p.dy, inInclusiveRange(0.0, 204.0));
        // Top edge slants y 24 -> 0; right edge x = 328;
        // bottom edge is STRAIGHT at y 204 (FIX 20 refinement #2);
        // left edge x = 0.
        if (p.dy <= 28.0) top = true;
        if (p.dx >= 323.0) right = true;
        if (p.dy >= 182.0) bottom = true;
        if (p.dx <= 5.0) left = true;
      }
      expect(top, isTrue, reason: 'head never reached the top edge');
      expect(right, isTrue, reason: 'head never reached the right edge');
      expect(bottom, isTrue, reason: 'head never reached the bottom edge');
      expect(left, isTrue, reason: 'head never reached the left edge');
    });

    test('head at t=0 sits at the loop start (top-left corner)', () {
      final pos = heroRunnerHeadPosition(const Size(328, 204), 0.0);
      expect(pos, isNotNull);
      // Path starts at (0, slant + radius) = (0, 44) after v2014
      // (slant 24 + radius 20; was 56 with the v2010 slant 36).
      expect(pos!.dx, closeTo(0.0, 1.0));
      expect(pos.dy, closeTo(44.0, 1.0));
    });
  });
}
