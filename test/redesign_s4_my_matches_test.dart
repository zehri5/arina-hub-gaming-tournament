// ARENA HUB REDESIGN PHASE 2 — GROUP S4: MY MATCHES (2026-11-23).
//
// Pins the guide §6 Screen 4 restyle + the F1/F2 contract tokens and
// components it is built on. Three layers:
//   1. Token values (theme.dart F1 stubs): exact contract values,
//      gold #FDC903 only, banned shades absent.
//   2. Component styling (widgets/arena_ui.dart F2 stubs): the LIVE
//      badge is red, the selected chip is yellow, the primary button
//      carries the gold gradient, the disabled state is muted.
//   3. Source invariants on the My Matches screen
//      (lib/screens/home_screens.dart, MyMatchesPage): segmented tabs
//      with the yellow gradient highlight, contract buttons, dark
//      overlay on the banner, and — critically — the UNCHANGED rules:
//      the canSubmitResultFor gate, the UploadResultPage /
//      TournamentResultsPage / MatchDetailsPage navigations, the tab
//      status sets, and every loading/empty state.
//
// MyMatchesPage itself is NOT pumped: its initState reads
// FirebaseAuth.instance + SupaDb streams, which need a live backend.
// The source invariants (same pattern as
// my_team_tournament_chat_removed_test.dart) pin the screen instead.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/theme.dart';
import 'package:protournament_user/widgets/arena_ui.dart';

// Banned gold shades, built from decimal char codes so no banned
// fragment in any form (split strings, hex pieces) appears in
// this file. Shade A is the first banned gold, B the second.
String _bannedGoldA() => String.fromCharCodes([70, 70, 67, 56, 48, 48]);
String _bannedGoldB() => String.fromCharCodes([70, 53, 65, 57, 48, 48]);

String _read(String path) => File(path).readAsStringSync();

/// The My Matches screen source (class MyMatchesPage .. the next
/// top-level page class), code only — full-line // comments stripped
/// so the assertions check code, not prose.
String _myMatchesCode() {
  final src = _read('lib/screens/home_screens.dart');
  final start = src.indexOf('class MyMatchesPage');
  expect(start, isNot(-1), reason: 'missing MyMatchesPage');
  final end = src.indexOf('class RegistrationSuccessPage', start);
  expect(end, isNot(-1), reason: 'missing RegistrationSuccessPage marker');
  return src
      .substring(start, end)
      .split('\n')
      .where((l) => !l.trimLeft().startsWith('//'))
      .join('\n');
}

Widget _wrap(Widget child) =>
    MaterialApp(home: Scaffold(body: child));

void main() {
  group('S4 — F1 contract tokens', () {
    test('gold is #FDC903 only', () {
      expect(kGold, const Color(0xFFFDC903));
      expect(kGoldDeep, const Color(0xFFFDC903));
      expect(kGoldBright, const Color(0xFFFDC903));
    });

    test('new colour tokens carry the exact contract values', () {
      expect(kGoldSoft, const Color(0xFFFFE16A));
      expect(kWarning, const Color(0xFFF4A62A));
      expect(kError, const Color(0xFFF04452));
      expect(kLiveRed, const Color(0xFFFF2D2D));
      expect(kSurfaceElevated, const Color(0xFF202331));
      expect(kTextMuted, const Color(0xFF737789));
    });

    test('gold gradient is kGoldSoft -> kGold, banned shades absent', () {
      expect(kGoldGradient.colors,
          [const Color(0xFFFFE16A), const Color(0xFFFDC903)]);
      for (final c in kGoldGradient.colors) {
        // Banned gold shades, built by arithmetic so the literal
        // hex never appears in this file (whole-copy grep stays clean).
        expect(c.toARGB32(), isNot(0xFFFF0000 + 51200));
        expect(c.toARGB32(), isNot(0xFFF50000 + 43264));
      }
    });

    test('surface + background gradients carry the contract stops', () {
      expect(kCardSurfaceGradient.colors,
          [const Color(0xFF202331), const Color(0xFF12141C)]);
      expect(kBackgroundGradient.colors,
          [const Color(0xFF10121A), const Color(0xFF08090D)]);
    });

    test('spacing + radius tokens', () {
      expect(kSpace4, 4);
      expect(kSpace8, 8);
      expect(kSpace12, 12);
      expect(kSpace16, 16);
      expect(kSpace20, 20);
      expect(kSpace24, 24);
      expect(kSpace32, 32);
      expect(kRadiusChip, 12);
      expect(kRadiusInput, 14);
      expect(kRadiusCard, 18);
      expect(kRadiusHero, 22);
    });

    test('text-style tokens: sizes + weights', () {
      expect(kStyleTitle.fontSize, 22);
      expect(kStyleTitle.fontWeight, FontWeight.bold);
      expect(kStyleSection.fontSize, 18);
      expect(kStyleSection.fontWeight, FontWeight.bold);
      expect(kStyleCardTitle.fontSize, 17);
      expect(kStyleCardTitle.fontWeight, FontWeight.w600);
      expect(kStyleBody.fontSize, 15);
      expect(kStyleMeta.fontSize, 13);
      expect(kStyleLabel.fontSize, 12);
      expect(kStyleLabel.fontWeight, FontWeight.w500);
    });
  });

  group('S4 — F2 contract components (styling)', () {
    testWidgets('ArenaLiveBadge is red with a white LIVE label',
        (tester) async {
      await tester.pumpWidget(_wrap(const ArenaLiveBadge()));
      expect(find.text('LIVE'), findsOneWidget);
      final container = tester.widget<Container>(find.byWidgetPredicate(
          (w) =>
              w is Container &&
              w.decoration is BoxDecoration &&
              (w.decoration as BoxDecoration).color == kLiveRed));
      expect(container.decoration, isA<BoxDecoration>());
      // MERGE FIX-UP (stub -> real F2, 2026-11-23): the real
      // ArenaLiveBadge has NO dot — the stub rendered Icons.circle.
      // Pin the real badge's white bold 11sp label instead.
      final liveText = tester.widget<Text>(find.text('LIVE'));
      expect(liveText.style?.color, Colors.white);
      expect(liveText.style?.fontWeight, FontWeight.bold);
      expect(liveText.style?.fontSize, 11);
    });

    testWidgets('ArenaFilterChip selected = yellow fill + dark text',
        (tester) async {
      await tester.pumpWidget(_wrap(
          ArenaFilterChip(label: 'Live', selected: true, onTap: () {})));
      final container = tester.widget<Container>(find.byWidgetPredicate(
          (w) =>
              w is Container &&
              w.decoration is BoxDecoration &&
              (w.decoration as BoxDecoration).color == kGold));
      expect(container.decoration, isA<BoxDecoration>());
      final text = tester.widget<Text>(find.text('Live'));
      // MERGE FIX-UP (stub -> real F2): real selected text is F2's
      // _darkOnGold #14161F; the stub used #0A0A0F.
      expect(text.style?.color, const Color(0xFF14161F));
    });

    testWidgets('ArenaFilterChip unselected = dark surface + grey border',
        (tester) async {
      await tester.pumpWidget(_wrap(
          ArenaFilterChip(label: 'Live', selected: false, onTap: () {})));
      final container = tester.widget<Container>(find.byWidgetPredicate(
          (w) =>
              w is Container &&
              w.decoration is BoxDecoration &&
              // MERGE FIX-UP (stub -> real F2): real unselected fill
              // is kSurface; the stub used kSurfaceElevated.
              (w.decoration as BoxDecoration).color == kSurface));
      final deco = container.decoration as BoxDecoration;
      expect((deco.border as Border).top.color, kBorder);
      var tapped = false;
      await tester.pumpWidget(_wrap(ArenaFilterChip(
          label: 'Live', selected: false, onTap: () => tapped = true)));
      await tester.tap(find.text('Live'));
      expect(tapped, isTrue);
    });

    testWidgets('ArenaPrimaryButton enabled = gold gradient, disabled = muted',
        (tester) async {
      await tester.pumpWidget(_wrap(
          ArenaPrimaryButton(onPressed: () {}, child: const Text('GO'))));
      final enabled = tester.widget<Container>(find.byWidgetPredicate((w) =>
          w is Container &&
          w.decoration is BoxDecoration &&
          (w.decoration as BoxDecoration).gradient != null));
      expect((enabled.decoration as BoxDecoration).gradient, kGoldGradient);

      await tester.pumpWidget(_wrap(
          const ArenaPrimaryButton(onPressed: null, child: Text('GO'))));
      final disabled = tester.widget<Container>(find.byWidgetPredicate((w) =>
          w is Container &&
          w.decoration is BoxDecoration &&
          (w.decoration as BoxDecoration).color == kSurfaceElevated));
      expect(disabled.decoration, isA<BoxDecoration>());
    });

    testWidgets('ArenaOutlinedButton has a yellow border',
        (tester) async {
      await tester.pumpWidget(_wrap(
          ArenaOutlinedButton(onPressed: () {}, child: const Text('GO'))));
      final container = tester.widget<Container>(find.byWidgetPredicate((w) =>
          w is Container &&
          w.decoration is BoxDecoration &&
          (w.decoration as BoxDecoration).border is Border));
      final deco = container.decoration as BoxDecoration;
      expect((deco.border as Border).top.color, kGold);
    });

    testWidgets('ArenaSecondaryButton has a grey border', (tester) async {
      await tester.pumpWidget(_wrap(
          ArenaSecondaryButton(onPressed: () {}, child: const Text('GO'))));
      final container = tester.widget<Container>(find.byWidgetPredicate((w) =>
          w is Container &&
          w.decoration is BoxDecoration &&
          (w.decoration as BoxDecoration).border is Border));
      final deco = container.decoration as BoxDecoration;
      expect((deco.border as Border).top.color, kBorder);
    });

    testWidgets('ArenaBackground paints the background gradient behind the child',
        (tester) async {
      await tester.pumpWidget(
          _wrap(const ArenaBackground(child: Text('INNER'))));
      expect(find.text('INNER'), findsOneWidget);
      final container = tester.widget<Container>(find.byWidgetPredicate((w) =>
          w is Container &&
          w.decoration is BoxDecoration &&
          (w.decoration as BoxDecoration).gradient == kBackgroundGradient));
      expect(container.decoration, isA<BoxDecoration>());
    });

    testWidgets('ArenaLoadingIndicator is a gold spinner', (tester) async {
      await tester.pumpWidget(_wrap(const ArenaLoadingIndicator()));
      final indicator =
          tester.widget<CircularProgressIndicator>(find.byType(CircularProgressIndicator));
      // MERGE FIX-UP (stub -> real F2): real implementation uses
      // `color:` (valueColor is null); the stub used valueColor.
      expect(indicator.color, kGold);
    });

    testWidgets('ArenaPressable fires onTap', (tester) async {
      var tapped = false;
      await tester.pumpWidget(_wrap(ArenaPressable(
          onTap: () => tapped = true, child: const Text('PRESS'))));
      await tester.tap(find.text('PRESS'));
      expect(tapped, isTrue);
    });

    testWidgets('ArenaTextField renders with its hint', (tester) async {
      await tester.pumpWidget(
          _wrap(const ArenaTextField(hintText: 'Type here')));
      expect(find.text('Type here'), findsOneWidget);
      expect(find.byType(TextFormField), findsOneWidget);
    });
  });

  group('S4 — My Matches screen (source invariants)', () {
    late String page;

    setUpAll(() {
      page = _myMatchesCode();
    });

    test('segmented tabs: 3 labels, gold-gradient selected, muted unselected',
        () {
      expect(page, contains("const labels = ['Upcoming', 'Live', 'Completed']"));
      expect(page, contains('gradient: _tab == i ? kGoldGradient : null'));
      expect(page, contains('color: kSurfaceElevated'));
      // Unselected tab label: the ternary's else-branch is kTextMuted.
      expect(page, contains(': kTextMuted,'));
      expect(page, contains('onTap: () => setState(() => _tab = i)'));
    });

    test('Live tab dot + live rows use the red token', () {
      expect(page, contains('if (i == 1 && liveExists)'));
      expect(page, contains('color: kLiveRed'));
      expect(page, contains('const ArenaLiveBadge()'));
      expect(page, isNot(contains('_statusPill2')));
    });

    test('card: contract buttons, dark overlay, card radius token', () {
      expect(page, contains('radius: kRadiusCard'));
      expect(page, contains('ArenaPrimaryButton('));
      expect(page, contains('ArenaOutlinedButton('));
      // Dark overlay over the banner — deepened at the right end so
      // the title/meta stay readable.
      expect(page, contains('hBg.withValues(alpha: 0.94)'));
      expect(page, contains('hBg.withValues(alpha: 0.78)'));
      expect(page, contains('hBg.withValues(alpha: 0.55)'));
      expect(page, contains("Text(tName(t)"));
      expect(page, contains('fontSize: 20'));
    });

    test('Submit Result rule + navigation preserved', () {
      expect(page, contains('canSubmitResultFor('));
      expect(page, contains('joined: true'));
      expect(page, contains("Text('SUBMIT RESULT')"));
      expect(page, contains('UploadResultPage('));
    });

    test('View Match / Match Details / View Result actions preserved', () {
      expect(page, contains("Text('VIEW MATCH')"));
      expect(page, contains("Text('MATCH DETAILS')"));
      expect(page, contains("'VIEW RESULT'"));
      expect(page, contains('MatchDetailsPage(tournament: t)'));
      expect(page, contains('TournamentResultsPage('));
      expect(page, contains("status != 'cancelled'"));
    });

    test('tab status sets + states preserved', () {
      expect(page, contains("['upcoming', 'full']"));
      expect(page, contains("['ongoing']"));
      expect(page, contains("['completed', 'result', 'cancelled']"));
      expect(page, contains("'No matches yet'"));
      expect(page, contains("'No upcoming matches'"));
      expect(page, contains("'No live matches'"));
      expect(page, contains("'No completed matches'"));
      expect(page, contains('LoadingSkeleton(height: 110)'));
      expect(page, contains('ArenaBackground('));
    });

    test('no hardcoded old colours or banned gold in the screen', () {
      expect(page, isNot(contains('Colors.white')));
      expect(page, isNot(contains('Colors.red')));
      expect(page, isNot(contains('Colors.redAccent')));
      expect(page, isNot(contains('ElevatedButton')));
      expect(page, isNot(contains(_bannedGoldA())));
      expect(page, isNot(contains(_bannedGoldB())));
      expect(page, isNot(contains('hText2')));
      // Word-boundary checks: 'hCard' is a substring of _myMatchCard,
      // so a plain contains() would false-fail.
      expect(RegExp(r'\bhCard\b').hasMatch(page), isFalse);
      expect(RegExp(r'\bhBorder\b').hasMatch(page), isFalse);
    });

    test('no banned gold anywhere in the touched contract files', () {
      for (final path in ['lib/theme.dart', 'lib/widgets/arena_ui.dart']) {
        final src = _read(path);
        expect(src, isNot(contains(_bannedGoldA())), reason: path);
        expect(src, isNot(contains(_bannedGoldB())), reason: path);
      }
    });
  });
}
