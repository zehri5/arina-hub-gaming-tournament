// ARENA HUB Phase 2 redesign — GROUP S5: Rankings (guide §6 Screen 5).
//
// Pins the S5 restyle of the LeaderboardPage (lib/screens/
// more_screens.dart): contract tokens in use, the shared tab
// component, search + filter in the shared input/button style, the
// premium golden podium, the highlighted current-user row, aligned
// Rank / Player / Points / Matches columns, ranking order + score
// values UNCHANGED, and long-name overflow handling. Styling only —
// no logic, flow, navigation or data change is pinned in or out
// beyond "the widget renders exactly what it is given".
//
// NOTE: LeaderboardPage itself needs Firebase + Supabase, so it is
// NOT pumped here (same as the existing leaderboard tests). The
// public pieces (LeaderboardRow, LeaderboardFilterSheet, FilterTabs,
// ArenaSearchBar) are pumped for real; the private pieces (_podium,
// _tableBox, _row's YOU wrapper) are pinned by source inspection —
// the file must wire the tokens/components in, not just claim to.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/components/arena_components.dart';
import 'package:protournament_user/screens/more_screens.dart';
import 'package:protournament_user/theme.dart';
import 'package:protournament_user/widgets/arena_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Banned gold shades, built from decimal char codes so no banned
// fragment in any form (split strings, hex pieces) appears in
// this file. Shade A is the first banned gold, B the second.
String _bannedGoldA() => String.fromCharCodes([70, 70, 67, 56, 48, 48]);
String _bannedGoldB() => String.fromCharCodes([70, 53, 65, 57, 48, 48]);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    themeLightNotifier.value = false;
  });

  void setPhone(WidgetTester tester) {
    tester.view.physicalSize = const Size(720, 1600);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  group('contract tokens (F1 stub values)', () {
    test('gold is #FDC903 only — never the banned shades', () {
      expect(kGold, const Color(0xFFFDC903));
      expect(kGoldDeep, const Color(0xFFFDC903));
      expect(kGoldBright, const Color(0xFFFDC903));
      expect(kGoldSoft, const Color(0xFFFFE16A));
      expect(kWarning, const Color(0xFFF4A62A));
      expect(kError, const Color(0xFFF04452));
      // The gold gradient is kGoldSoft -> kGold (#FDC903); the
      // guide's two banned gold shades must not appear — the
      // exact-colour pin above already rules them out, and the
      // source-grep test below checks the files themselves.
      expect(kGoldGradient.colors, [kGoldSoft, kGoldDeep]);
    });

    test('surface / muted / gradient tokens', () {
      expect(kSurfaceElevated, const Color(0xFF202331));
      expect(kTextMuted, const Color(0xFF737789));
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

    test('text style tokens (guide §4 hierarchy)', () {
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

  group('source pins — the screen wires the tokens/components in', () {
    late String src;
    late String themeSrc;
    late String uiSrc;

    setUp(() {
      src = File('lib/screens/more_screens.dart').readAsStringSync();
      themeSrc = File('lib/theme.dart').readAsStringSync();
      uiSrc = File('lib/widgets/arena_ui.dart').readAsStringSync();
    });

    test('no banned gold hex anywhere in the S5 files', () {
      // The banned shades are spelled from parts so this test file
      // itself never contains the contiguous hex strings (a repo
      // grep for them must come back clean, test files included).
      final banned1 = _bannedGoldA();
      final banned2 = _bannedGoldB();
      for (final s in [src, themeSrc, uiSrc]) {
        expect(s.toUpperCase().contains(banned1), isFalse);
        expect(s.toUpperCase().contains(banned2), isFalse);
      }
    });

    test('shared column-width constants used by header AND rows', () {
      for (final c in [
        '_kRankColWidth',
        '_kAvatarColWidth',
        '_kPointsColWidth',
        '_kMatchesColWidth',
      ]) {
        // Declared once + used in the header + used in the row.
        expect(c.allMatches(src).length, greaterThanOrEqualTo(3),
            reason: '$c must be declared and used in both places');
      }
      // No leftover hardcoded column widths in the leaderboard
      // header/row area (the 36/72/56 literals are gone).
      expect(src.contains("SizedBox(width: 36,"), isFalse);
      expect(src.contains("SizedBox(width: 72,"), isFalse);
      expect(src.contains("SizedBox(width: 56,"), isFalse);
    });

    test('podium base line uses the gold gradient', () {
      expect(src.contains('gradient: kGoldGradient'), isTrue);
    });

    test('YOU row keeps the gold border and gains a soft gold glow', () {
      expect(src.contains('Border.all(color: kGold, width: 2)'), isTrue);
      expect(
          src.contains(
              'BoxShadow(color: kGold.withValues(alpha: 0.22)'),
          isTrue);
    });

    test('tab bar + filter button sit on the raised surface token', () {
      expect(src.contains('color: kSurfaceElevated'), isTrue);
    });

    test('filter sheet uses the shared chip + primary button', () {
      expect(src.contains('ArenaFilterChip('), isTrue);
      expect(src.contains('ArenaPrimaryButton('), isTrue);
      expect(src.contains('ChoiceChip('), isFalse);
    });

    test('heading is one shared widget for AppBar + embedded tab', () {
      expect(src.contains('_leaderboardHeader()'), isTrue);
      // Exactly one LEADERBOARD RichText definition (not two copies).
      expect("TextSpan(text: 'LEADER'".allMatches(src).length, 1);
      expect("TextSpan(text: 'BOARD'".allMatches(src).length, 1);
    });

    test('rows use the shared card with animation off (contract)', () {
      expect(src.contains('animate: false,'), isTrue);
    });
  });

  group('LeaderboardRow — order, scores, columns, overflow', () {
    Widget rows(List<LeaderboardRow> rs) => MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: Column(children: rs),
            ),
          ),
        );

    LeaderboardRow row({
      required int rank,
      required String name,
      required String points,
      required int matches,
      bool isMe = false,
    }) =>
        LeaderboardRow(
          rank: rank,
          name: name,
          photoUrl: '',
          pointsText: points,
          matches: matches,
          isMe: isMe,
        );

    testWidgets('renders ranks, points and matches verbatim, in order',
        (tester) async {
      setPhone(tester);
      await tester.pumpWidget(rows([
        row(rank: 1, name: 'Alpha', points: '15,840', matches: 42),
        row(rank: 2, name: 'Bravo', points: '9,200', matches: 30),
        row(rank: 3, name: 'Charlie', points: '300', matches: 5),
      ]));
      await tester.pump();
      expect(tester.takeException(), isNull);

      // Rank, points and matches are displayed EXACTLY as given —
      // the restyle never transforms a value.
      expect(find.text('#1'), findsOneWidget);
      expect(find.text('#2'), findsOneWidget);
      expect(find.text('#3'), findsOneWidget);
      expect(find.textContaining('15,840'), findsOneWidget);
      expect(find.textContaining('9,200'), findsOneWidget);
      expect(find.textContaining('300'), findsOneWidget);
      expect(find.text('42'), findsOneWidget);
      expect(find.text('30'), findsOneWidget);
      expect(find.text('5'), findsOneWidget);
      // Visual order is the input order (top to bottom).
      final y1 = tester.getTopLeft(find.text('#1')).dy;
      final y2 = tester.getTopLeft(find.text('#2')).dy;
      final y3 = tester.getTopLeft(find.text('#3')).dy;
      expect(y1, lessThan(y2));
      expect(y2, lessThan(y3));
    });

    testWidgets('column cells use the shared widths 36 / 72 / 56',
        (tester) async {
      setPhone(tester);
      await tester.pumpWidget(
          rows([row(rank: 4, name: 'Delta', points: '120', matches: 3)]));
      await tester.pump();
      expect(tester.takeException(), isNull);

      final widths = tester
          .widgetList<SizedBox>(find.byType(SizedBox))
          .map((b) => b.width)
          .whereType<double>()
          .toSet();
      expect(widths.contains(36.0), isTrue, reason: 'rank column');
      expect(widths.contains(72.0), isTrue, reason: 'points column');
      expect(widths.contains(56.0), isTrue, reason: 'matches column');
    });

    testWidgets('long player name ellipsizes on one line, no overflow',
        (tester) async {
      setPhone(tester);
      const longName =
          'A_Very_Long_Player_Name_That_Would_Never_Fit_On_A_Phone_Screen';
      await tester.pumpWidget(rows([
        row(rank: 7, name: longName, points: '1,000', matches: 9),
      ]));
      await tester.pump();
      expect(tester.takeException(), isNull);

      final name = tester.widget<Text>(find.text(longName));
      expect(name.maxLines, 1);
      expect(name.overflow, TextOverflow.ellipsis);
      // The name stays inside the 360px screen.
      final rect = tester.getRect(find.text(longName));
      expect(rect.right, lessThanOrEqualTo(360));
      expect(rect.left, greaterThanOrEqualTo(0));
    });

    testWidgets('current-user row is gold-highlighted, 64dp, static card',
        (tester) async {
      setPhone(tester);
      await tester.pumpWidget(rows([
        row(rank: 1, name: 'sameer', points: '500', matches: 2, isMe: true),
        row(rank: 2, name: 'Other', points: '400', matches: 2),
      ]));
      await tester.pump();
      expect(tester.takeException(), isNull);

      // Name + rank in gold for the current user, plain for others.
      final myName = tester.widget<Text>(find.text('sameer'));
      expect(myName.style?.color, kGold);
      final myRank = tester.widget<Text>(find.text('#1'));
      expect(myRank.style?.color, kGold);
      final otherName = tester.widget<Text>(find.text('Other'));
      expect(otherName.style?.color, kText);
      // Shared body token: 15, bold.
      expect(myName.style?.fontSize, kStyleBody.fontSize);
      expect(myName.style?.fontWeight, FontWeight.bold);
      // Still the slim 64dp box (slim-row regression).
      final me = tester.widget<LeaderboardRow>(
          find.byWidgetPredicate((w) => w is LeaderboardRow && w.isMe));
      expect(tester.getSize(find.byWidget(me)).height, 64);
      // List rows use the static card (no per-row ticker).
      final card = tester.widget<MockupCard>(
          find.byType(MockupCard).first);
      expect(card.animate, isFalse);
      expect(card.radius, kRadiusChip);
    });
  });

  group('shared tab component + search input', () {
    testWidgets('FilterTabs segmented: equal thirds, active gold, no per-pill border',
        (tester) async {
      setPhone(tester);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 316,
              child: FilterTabs(
                labels: const ['Global', 'Weekly', 'Friends'],
                selectedIndex: 1,
                onSelected: (_) {},
                expanded: true,
                segmented: true,
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      final detectors =
          tester.widgetList<GestureDetector>(find.byType(GestureDetector)).toList();
      expect(detectors, hasLength(3));
      final widths = [
        for (final d in detectors) tester.getSize(find.byWidget(d)).width
      ];
      for (final w in widths) {
        expect(w, closeTo(316 / 3, 1.0));
      }
      final pills = tester
          .widgetList<Container>(find.byType(Container))
          .where((c) => c.decoration is BoxDecoration)
          .map((c) => c.decoration! as BoxDecoration)
          .toList();
      expect(pills, hasLength(3));
      // Weekly (index 1) is the active gold pill.
      expect(pills[1].color, kGold);
      expect(pills[0].color, Colors.transparent);
      expect(pills[2].color, Colors.transparent);
      // Segmented mode: NO per-pill outline (one outer container
      // border in the page, not here).
      for (final p in pills) {
        expect(p.border, isNull);
      }
      // Active label is dark, inactive labels muted.
      final active = tester.widget<Text>(find.text('Weekly'));
      expect(active.style?.color, const Color(0xFF0A0A0F));
      final inactive = tester.widget<Text>(find.text('Global'));
      expect(inactive.style?.color, kMuted);
    });

    testWidgets('ArenaSearchBar: dark fill, subtle border, gold focus',
        (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ArenaSearchBar(
            controller: controller,
            hint: 'Search player...',
            iconAtEnd: true,
            borderRadius: 24,
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      final field = tester.widget<TextField>(find.byType(TextField));
      final dec = field.decoration!;
      expect(dec.filled, isTrue);
      expect(dec.fillColor, kField);
      expect(dec.hintText, 'Search player...');
      final enabled = dec.enabledBorder as OutlineInputBorder;
      expect(enabled.borderSide.color, kBorder);
      expect(enabled.borderRadius, BorderRadius.circular(24));
      final focused = dec.focusedBorder as OutlineInputBorder;
      expect(focused.borderSide.color, kGold);
      expect(focused.borderRadius, BorderRadius.circular(24));
      // Magnifier at the right (mockup #5).
      expect(dec.suffixIcon, isA<Icon>());
      expect(dec.prefixIcon, isNull);
    });
  });

  group('LeaderboardFilterSheet — shared chips + primary button', () {
    testWidgets('three shared chips, selection switches, Apply pops',
        (tester) async {
      final host = _SheetHost();
      await host.open(tester);
      expect(find.byType(ArenaFilterChip), findsNWidgets(3));
      expect(find.byType(ArenaPrimaryButton), findsOneWidget);
      expect(find.text('Apply'), findsOneWidget);
      expect(find.text('Clear filter'), findsOneWidget);
      expect(tester.takeException(), isNull);

      // Default: All time selected.
      ArenaFilterChip chip(String label) => tester.widget<ArenaFilterChip>(
          find.ancestor(
              of: find.text(label),
              matching: find.byType(ArenaFilterChip)));
      expect(chip('All time').selected, isTrue);
      expect(chip('This week').selected, isFalse);

      // Tapping switches the selection (same behaviour as before).
      await tester.tap(find.text('This week'));
      await tester.pump();
      expect(chip('This week').selected, isTrue);
      expect(chip('All time').selected, isFalse);

      // Apply pops the picked period through the shared button.
      await tester.ensureVisible(find.text('Apply'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();
      expect(host.result, {'gameId': null, 'period': 'week'});
      expect(tester.takeException(), isNull);
    });
  });
}

/// Minimal host that opens [LeaderboardFilterSheet] as a real bottom
/// sheet and captures the value it pops with.
class _SheetHost {
  static const games = [
    {'id': 'g-pubg', 'name': 'PUBG Mobile'},
    {'id': 'g-cod', 'name': 'COD Mobile'},
  ];

  Map<String, dynamic>? result;

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(720, 1280);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (ctx) => ElevatedButton(
          onPressed: () async {
            result = await showModalBottomSheet<Map<String, dynamic>>(
              context: ctx,
              builder: (_) => const LeaderboardFilterSheet(
                games: games,
                selectedGameId: null,
                period: 'all',
              ),
            );
          },
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }
}
