// REDESIGN S16 — Offline Screen (guide §6 Screen 16).
// Pins the redesign styling: contract tokens used, logo + illustration
// centre-aligned, "YOU'RE OFFLINE" prominent WHITE, status badge
// outlined, Retry = yellow primary / Go Back = dark secondary, and
// the retry/back ACTIONS unchanged. Styling-only: no logic, flow or
// navigation change is asserted here beyond the pre-existing behaviour.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/components/arena_components.dart';
import 'package:protournament_user/screens/offline_screen.dart';
import 'package:protournament_user/theme.dart';
import 'package:protournament_user/widgets/arena_ui.dart';

/// All BoxDecorations rendered inside [ancestor] (Ink or Container),
/// so the button-fill assertions survive F2's real implementation as
/// long as it keeps the contract look (kGoldGradient fill on primary,
/// dark surface + border on secondary).
List<BoxDecoration> _decorationsIn(WidgetTester tester, Finder ancestor) {
  final out = <BoxDecoration>[];
  for (final ink in tester.widgetList<Ink>(find.descendant(of: ancestor, matching: find.byType(Ink)))) {
    final d = ink.decoration;
    if (d is BoxDecoration) out.add(d);
  }
  for (final c in tester.widgetList<Container>(find.descendant(of: ancestor, matching: find.byType(Container)))) {
    final d = c.decoration;
    if (d is BoxDecoration) out.add(d);
  }
  return out;
}

void main() {
  setUp(() {
    // Dark mode is the app default; pin it so kText == white etc.
    themeLightNotifier.value = false;
  });

  group('S16 contract tokens', () {
    test('gold gradient is the GOLD-RULE form (#FFE16A -> #FDC903)', () {
      expect(kGoldSoft, const Color(0xFFFFE16A));
      expect(kGold, const Color(0xFFFDC903));
      // Exact list equality also pins that NO other yellow (in
      // particular the guide's banned two-tone golds) is in it.
      expect(kGoldGradient.colors, [const Color(0xFFFFE16A), const Color(0xFFFDC903)]);
      expect(kGoldGradient.colors, hasLength(2));
    });

    test('warning + spacing + radius + text tokens have contract values', () {
      expect(kWarning, const Color(0xFFF4A62A));
      expect(kError, const Color(0xFFF04452));
      expect(kSurfaceElevated, const Color(0xFF202331));
      expect(kTextMuted, const Color(0xFF737789));
      expect(kSpace8, 8);
      expect(kSpace12, 12);
      expect(kSpace16, 16);
      expect(kSpace24, 24);
      expect(kRadiusInput, 14);
      expect(kStyleBody.fontSize, 15);
      expect(kStyleMeta.fontSize, 13);
      expect(kCardSurfaceGradient.colors, [const Color(0xFF202331), const Color(0xFF12141C)]);
      expect(kBackgroundGradient.colors, [const Color(0xFF10121A), const Color(0xFF08090D)]);
    });
  });

  group('S16 offline screen styling', () {
    Future<void> pumpScreen(WidgetTester tester, {VoidCallback? onRetry, VoidCallback? onGoBack}) async {
      await tester.pumpWidget(
        MaterialApp(
          home: OfflineScreen(
            message: 'Check your internet connection and try again.',
            onRetry: onRetry,
            onGoBack: onGoBack,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }

    testWidgets('logo + illustration are centre-aligned', (tester) async {
      await pumpScreen(tester, onRetry: () {}, onGoBack: () {});
      final screenW = tester.getSize(find.byType(Scaffold)).width;
      final logoCenter = tester.getCenter(find.byType(ArenaLogo));
      expect(logoCenter.dx, moreOrLessEquals(screenW / 2, epsilon: 1.0));
      final illoCenter = tester.getCenter(find.byKey(const ValueKey('offline-illustration')));
      expect(illoCenter.dx, moreOrLessEquals(screenW / 2, epsilon: 1.0));
      // The illustration is the 172x172 drawn artwork, not a photo.
      expect(tester.getSize(find.byKey(const ValueKey('offline-illustration'))), const Size(172, 172));
      expect(tester.takeException(), isNull);
    });

    testWidgets('"YOU\'RE OFFLINE" is prominent WHITE (36px, w900)', (tester) async {
      await pumpScreen(tester, onRetry: () {}, onGoBack: () {});
      // Every Text builds a RichText, so match the heading by content.
      final rich = tester.widget<RichText>(find.byWidgetPredicate((w) => w is RichText && (w.text as TextSpan).toPlainText() == "YOU'RE OFFLINE"));
      final root = rich.text as TextSpan;
      expect(root.style!.fontSize, 36);
      expect(root.style!.fontWeight, FontWeight.w900);
      expect(root.style!.color, Colors.white);
      // Both spans white — the old gold "OFFLINE" is gone.
      expect(root.children, hasLength(2));
      for (final span in root.children!.cast<TextSpan>()) {
        expect(span.style!.color, Colors.white);
      }
      expect(root.toPlainText(), "YOU'RE OFFLINE");
      expect(tester.takeException(), isNull);
    });

    testWidgets('message uses the body token in muted grey', (tester) async {
      await pumpScreen(tester, onRetry: () {}, onGoBack: () {});
      final text = tester.widget<Text>(find.text('Check your internet connection and try again.'));
      expect(text.style!.fontSize, kStyleBody.fontSize);
      expect(text.style!.color, kMuted);
      expect(text.textAlign, TextAlign.center);
    });

    testWidgets('status badge is small + outlined with a kWarning dot', (tester) async {
      await pumpScreen(tester, onRetry: () {}, onGoBack: () {});
      final badge = tester.widget<Container>(find.byKey(const ValueKey('offline-status-badge')));
      final deco = badge.decoration! as BoxDecoration;
      // Outlined: transparent fill, gold border — not a filled card.
      expect(deco.color, Colors.transparent);
      expect(deco.border, isA<Border>());
      final border = deco.border! as Border;
      expect(border.top.color, kGold.withValues(alpha: 0.6));
      expect(find.text('Connection Unavailable'), findsOneWidget);
      // The dot is the contract warning token, not a hardcoded orange.
      final dots = tester.widgetList<Container>(find.byWidgetPredicate((w) =>
          w is Container && w.decoration is BoxDecoration && (w.decoration! as BoxDecoration).shape == BoxShape.circle && (w.decoration! as BoxDecoration).color == kWarning));
      expect(dots, hasLength(1));
    });

    testWidgets('RETRY is the yellow primary, GO BACK the dark secondary', (tester) async {
      await pumpScreen(tester, onRetry: () {}, onGoBack: () {});
      final primary = find.byType(ArenaPrimaryButton);
      final secondary = find.byType(ArenaSecondaryButton);
      expect(primary, findsOneWidget);
      expect(secondary, findsOneWidget);
      expect(find.descendant(of: primary, matching: find.text('RETRY CONNECTION')), findsOneWidget);
      expect(find.descendant(of: secondary, matching: find.text('GO BACK')), findsOneWidget);
      // Primary fill = the gold gradient (contract look).
      final primaryDecos = _decorationsIn(tester, primary);
      expect(primaryDecos.any((d) => d.gradient is LinearGradient && (d.gradient! as LinearGradient).colors.contains(kGoldSoft) && (d.gradient! as LinearGradient).colors.contains(kGold)), isTrue);
      // Primary label is dark text on the gold fill.
      final retryLabel = tester.widget<Text>(find.text('RETRY CONNECTION'));
      expect(retryLabel.style!.color, const Color(0xFF0A0A0F));
      // Secondary = dark surface + grey border + white text.
      // Merge lane (stub swap): the REAL F2 secondary fills with
      // kSurface — the stub filled with kCard. Same dark-surface
      // intent; only the token differs.
      final secondaryDecos = _decorationsIn(tester, secondary);
      expect(secondaryDecos.any((d) => d.color == kSurface && d.border is Border), isTrue);
      final backLabel = tester.widget<Text>(find.text('GO BACK'));
      expect(backLabel.style!.color, kText);
    });

    testWidgets('retry + back actions are unchanged', (tester) async {
      var retried = false;
      var wentBack = false;
      await pumpScreen(tester, onRetry: () => retried = true, onGoBack: () => wentBack = true);
      await tester.tap(find.text('RETRY CONNECTION'));
      await tester.pump();
      expect(retried, isTrue);
      await tester.tap(find.text('GO BACK'));
      await tester.pump();
      expect(wentBack, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('no callbacks: RETRY hidden, GO BACK always renders', (tester) async {
      await pumpScreen(tester);
      expect(find.text('RETRY CONNECTION'), findsNothing);
      expect(find.byType(ArenaPrimaryButton), findsNothing);
      expect(find.text('GO BACK'), findsOneWidget);
      expect(find.byType(ArenaSecondaryButton), findsOneWidget);
      expect(find.text('Check your internet connection and try again.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('both buttons are tappable without scrolling (600px fit)', (tester) async {
      await pumpScreen(tester, onRetry: () {}, onGoBack: () {});
      // Default test viewport is 800x600: GO BACK must sit on-screen.
      final backTop = tester.getTopLeft(find.text('GO BACK')).dy;
      expect(backTop, lessThan(600));
      expect(tester.takeException(), isNull);
    });
  });
}
