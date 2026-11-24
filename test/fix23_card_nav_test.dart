// FIX 23 — CARD + NAV BAR RESTYLE (item 23, ChatGPT design).
// Cards are the frosted purple gradient (ChatGPT's exact values,
// 85% fill so the background image shows faintly through); the
// nav bar is the floating purple shell with kGold selected +
// lavender unselected. The MockupCard 2-shine-lines look is
// SUPERSEDED for the card fill (no more per-card shine painter).

import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/theme.dart';

import 'audio_test_helpers.dart';

String _region(String src, String start, String end) {
  final s = src.indexOf(start);
  if (s < 0) return '';
  final e = src.indexOf(end, s + start.length);
  if (e < 0) return '';
  return src.substring(s, e);
}

void main() {
  group('fix23 item 23 — tokens (unit)', () {
    test('purple card tokens are ChatGPT exact values', () {
      expect(kCardPurpleTop, const Color(0xFF211052));
      expect(kCardPurpleMid, const Color(0xFF100829));
      expect(kCardPurpleBottom, const Color(0xFF080817));
      expect(kCardPurpleBorder, const Color(0xFF922BFF));
      expect(kCardPurpleGlow, const Color(0xFF8A20FF));
      expect(kNavUnselected, const Color(0xFFB9A9D8));
    });

    test('fill opacity + blur sigma', () {
      // 0.48 (2026-11-23 23:52): 0.85 too dark, 0.60 STILL not
      // transparent enough ("abhi bhi transparent nahi hai").
      expect(kCardFillOpacity, 0.48);
      // Blur raised 10 → 12 with the lighter fill (readability).
      expect(kCardBlurSigma, 12.0);
    });

    test('old gradient tokens KEPT (other tests pin them)', () {
      expect(kCardGradientTop, const Color(0xFF1D2029));
      expect(kCardGradientBottom, const Color(0xFF15181F));
    });

    test('selected nav color is kGold, never the ChatGPT gold', () {
      expect(kGold, const Color(0xFFFDC903));
      // The banned gold is built from char codes so the literal
      // itself never appears in this file (STRICT gold scans test
      // files too).
      final banned = String.fromCharCodes([70, 70, 67, 52, 48, 48]);
      final theme = codeOnly(requireProjectFile('lib/theme.dart'));
      expect(theme, isNot(contains(banned)));
      expect(theme, isNot(contains(banned.toLowerCase())));
    });
  });

  group('fix23 item 23 — decorations (unit)', () {
    test('cardDecoration: gradient + border + glow + radius 22', () {
      final d = cardDecoration();
      expect(d.borderRadius, BorderRadius.circular(22));
      final g = d.gradient as LinearGradient;
      expect(g.begin, Alignment.topLeft);
      expect(g.end, Alignment.bottomRight);
      expect(g.colors, [
        kCardPurpleTop.withValues(alpha: 0.48),
        kCardPurpleMid.withValues(alpha: 0.48),
        kCardPurpleBottom.withValues(alpha: 0.48),
      ]);
      final border = d.border as Border;
      expect(border.top.color, kCardPurpleBorder);
      expect(border.top.width, 1.5);
      expect(d.boxShadow, hasLength(1));
      final shadow = d.boxShadow!.first;
      expect(shadow.color, kCardPurpleGlow.withValues(alpha: 0.25));
      expect(shadow.blurRadius, 15);
      expect(shadow.spreadRadius, 1);
    });

    test('cardFillDecoration: gradient only, no border/shadow', () {
      final d = cardFillDecoration(radius: 12);
      expect(d.borderRadius, BorderRadius.circular(12));
      expect(d.gradient, isA<LinearGradient>());
      expect(d.border, isNull);
      expect(d.boxShadow, isNull);
    });

    test('cardFrameDecoration: border + glow only, no fill', () {
      final d = cardFrameDecoration();
      expect(d.gradient, isNull);
      expect((d.border as Border).top.color, kCardPurpleBorder);
      expect(d.boxShadow, hasLength(1));
    });
  });

  group('fix23 item 23 — MockupCard widget', () {
    testWidgets('frosted purple card: blur + purple frame, no shines',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: MockupCard(child: Text('card-content')),
        ),
      ));
      await tester.pump();
      expect(find.text('card-content'), findsOneWidget);
      // Frosted glass: a BackdropFilter with the 12px blur.
      final filter =
          tester.widget<BackdropFilter>(find.byType(BackdropFilter));
      expect(filter.filter.toString(), contains('12.0'));
      // No shine painter anywhere in the card (scoped to the card
      // itself — the debug banner is a CustomPaint too).
      expect(
          find.descendant(
              of: find.byType(MockupCard),
              matching: find.byType(CustomPaint)),
          findsNothing);
      // The frame container carries the purple border.
      final frames = tester.widgetList<Container>(find.byType(Container));
      final hasPurpleBorder = frames.any((c) {
        final d = c.decoration;
        if (d is! BoxDecoration) return false;
        final b = d.border;
        return b is Border && b.top.color == kCardPurpleBorder;
      });
      expect(hasPurpleBorder, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('animate/sparks params still accepted (deprecated no-ops)',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: MockupCard(
              animate: true, sparks: true, child: Text('legacy')),
        ),
      ));
      await tester.pump();
      expect(find.text('legacy'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('fix23 item 23 — nav bar (source + math)', () {
    test('all three nav bars use the shell + kGold + kNavUnselected', () {
      final main = codeOnly(requireProjectFile('lib/main.dart'));
      expect(main, contains('navBarShell('));
      expect(main, contains('selectedItemColor: kGold'));
      expect(main, contains('unselectedItemColor: kNavUnselected'));
      final pro =
          codeOnly(requireProjectFile('lib/screens/pro_features.dart'));
      expect(pro, contains('navBarShell('));
      expect(pro, contains('unselectedItemColor: kNavUnselected'));
      final more =
          codeOnly(requireProjectFile('lib/screens/more_screens.dart'));
      expect(more, contains('navBarShell('));
      expect(more, contains('unselectedItemColor: kNavUnselected'));
    });

    test('theme bottomNavigationBarTheme matches', () {
      final main = codeOnly(requireProjectFile('lib/main.dart'));
      final theme = _region(
          main, 'bottomNavigationBarTheme:', 'pageTransitionsTheme:');
      expect(theme, isNotEmpty);
      expect(theme, contains('kCardPurpleMid'));
      expect(theme, contains('selectedItemColor: kGold'));
      expect(theme, contains('unselectedItemColor: kNavUnselected'));
    });

    testWidgets('navBarTabCenter math at 360px', (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final centers = <double>[];
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) {
            for (var i = 0; i < 6; i++) {
              centers.add(navBarTabCenter(context, i));
            }
            return const SizedBox();
          },
        ),
      ));
      await tester.pump();
      // (360-24)/6 = 56 per tab; centres at 28, 84, 140, 196, 252, 308.
      expect(centers, [28.0, 84.0, 140.0, 196.0, 252.0, 308.0]);
      expect(tester.takeException(), isNull);
    });

    test('filter pills sit in the purple container (source)', () {
      final home =
          codeOnly(requireProjectFile('lib/screens/home_screens.dart'));
      expect(home, contains('decoration: cardDecoration(radius: 20)'));
    });

    test('MockupCard source: no shine painter, blur layering present', () {
      final theme = codeOnly(requireProjectFile('lib/theme.dart'));
      final card = _region(theme, 'class MockupCard',
          'class _FireSparksPainter');
      expect(card, isNotEmpty);
      expect(card, contains('BackdropFilter('));
      expect(card, contains('cardFrameDecoration('));
      expect(card, contains('cardFillDecoration('));
      expect(card, isNot(contains('CustomPaint')));
      expect(card, isNot(contains('_MockupCardBorderPainter')));
      expect(theme, isNot(contains('_MockupCardBorderPainter')));
    });
  });
}
