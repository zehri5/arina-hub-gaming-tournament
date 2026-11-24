// LEADERBOARD FILTER (2026-11-21, mockup #5) — pins the real
// filter the tune button now opens (game + period), the
// competition-rank rule the filtered view shares with the stored
// rank, and the filter sheet's Apply/Clear contract + honest
// note. No mock players, no mock values — the fixtures are
// synthetic rows for the pure helpers only.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/platform/core/scoring.dart';
import 'package:protournament_user/platform/scoring/leaderboard_page.dart';
import 'package:protournament_user/screens/more_screens.dart';
import 'package:protournament_user/widgets/arena_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  const now = 1795000000000; // fixed "now" (ms) for period cutoffs
  const dayMs = 24 * 3600 * 1000;

  Map<String, dynamic> row(String uid, String tid, int createdAtMs) => {
        'firebase_uid': uid,
        'tournament_id': tid,
        'placement': 1,
        'kills': 0,
        'created_at': createdAtMs,
      };

  const gameByTournament = {'t-pubg': 'g-pubg', 't-cod': 'g-cod'};

  group('filterApprovedResults', () {
    test('no filter keeps every row (incl. unknown tournament)', () {
      final rows = [
        row('u1', 't-pubg', now - dayMs),
        row('u2', 't-unknown', now - dayMs),
      ];
      final out = filterApprovedResults(rows,
          gameByTournament: gameByTournament, nowMs: now);
      expect(out, hasLength(2));
    });

    test('game filter keeps only that game; unknown tournament dropped',
        () {
      final rows = [
        row('u1', 't-pubg', now - dayMs),
        row('u2', 't-cod', now - dayMs),
        row('u3', 't-unknown', now - dayMs),
      ];
      final out = filterApprovedResults(rows,
          gameByTournament: gameByTournament,
          gameId: 'g-pubg',
          nowMs: now);
      expect(out, hasLength(1));
      expect(out.first['firebase_uid'], 'u1');
    });

    test('week keeps only the last 7 days', () {
      final rows = [
        row('u1', 't-pubg', now - 6 * dayMs),
        row('u2', 't-pubg', now - 8 * dayMs),
      ];
      final out = filterApprovedResults(rows,
          gameByTournament: gameByTournament, period: 'week', nowMs: now);
      expect(out, hasLength(1));
      expect(out.first['firebase_uid'], 'u1');
    });

    test('month keeps the last 30 days, drops older', () {
      final rows = [
        row('u1', 't-pubg', now - 29 * dayMs),
        row('u2', 't-pubg', now - 31 * dayMs),
      ];
      final out = filterApprovedResults(rows,
          gameByTournament: gameByTournament, period: 'month', nowMs: now);
      expect(out, hasLength(1));
      expect(out.first['firebase_uid'], 'u1');
    });

    test('all keeps everything; unknown period behaves as all', () {
      final rows = [
        row('u1', 't-pubg', now - 400 * dayMs),
        row('u2', 't-cod', now - 400 * dayMs),
      ];
      expect(
          filterApprovedResults(rows,
              gameByTournament: gameByTournament,
              period: 'bogus',
              nowMs: now),
          hasLength(2));
    });

    test('game + period combine', () {
      final rows = [
        row('u1', 't-pubg', now - dayMs),
        row('u2', 't-pubg', now - 8 * dayMs),
        row('u3', 't-cod', now - dayMs),
      ];
      final out = filterApprovedResults(rows,
          gameByTournament: gameByTournament,
          gameId: 'g-pubg',
          period: 'week',
          nowMs: now);
      expect(out, hasLength(1));
      expect(out.first['firebase_uid'], 'u1');
    });

    test('empty input stays empty', () {
      expect(
          filterApprovedResults([],
              gameByTournament: gameByTournament, nowMs: now),
          isEmpty);
    });
  });

  group('rankEntries (filtered view rule)', () {
    test('ties share a rank, next rank skips (1, 1, 3)', () {
      final entries = rankEntries(aggregateResults(
        [
          row('u1', 't-pubg', now),
          row('u2', 't-pubg', now),
          {
            'firebase_uid': 'u3',
            'tournament_id': 't-pubg',
            'placement': 2,
            'kills': 0,
            'created_at': now,
          },
        ],
        names: const {'u1': 'A', 'u2': 'B', 'u3': 'C'},
        template: kDefaultScoringTemplate,
      ));
      expect(entries.map((e) => e.rank).toList(), [1, 1, 3]);
      expect(entries.map((e) => e.points).toList(), [10, 10, 7]);
    });
  });

  group('LeaderboardFilterSheet', () {
    testWidgets('renders the honest note, never the old wrong text',
        (tester) async {
      final host = _SheetHost();
      await host.open(tester);
      expect(find.text('Filter'), findsOneWidget);
      expect(find.text('Game'), findsOneWidget);
      expect(find.text('Period'), findsOneWidget);
      expect(
          find.text(
              'Points are tournament points from APPROVED results (1st=10, 2nd=7, 3rd=5, +1 per kill). Ranks update when an admin approves a result.'),
          findsOneWidget);
      expect(find.textContaining('Community Points'), findsNothing);
      expect(find.textContaining('set by admins'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Apply returns the picked game + period', (tester) async {
      final host = _SheetHost();
      await host.open(tester);
      // Pick PUBG Mobile from the dropdown.
      await tester.tap(find.byType(DropdownButton<String?>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('PUBG Mobile').last);
      await tester.pumpAndSettle();
      // Pick This week.
      await tester.tap(find.text('This week'));
      await tester.pumpAndSettle();
      // The sheet scrolls on short screens — scroll Apply into view.
      await tester.ensureVisible(find.text('Apply'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();
      expect(host.result, {'gameId': 'g-pubg', 'period': 'week'});
      expect(tester.takeException(), isNull);
    });

    testWidgets('Clear filter returns reset', (tester) async {
      final host = _SheetHost();
      await host.open(tester);
      await tester.ensureVisible(find.text('Clear filter'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Clear filter'));
      await tester.pumpAndSettle();
      expect(host.result, {'reset': true});
      expect(tester.takeException(), isNull);
    });

    testWidgets('initial selection is honoured', (tester) async {
      final host = _SheetHost();
      await host.open(tester, selectedGameId: 'g-cod', period: 'month');
      // The closed dropdown shows the selected game.
      expect(find.text('COD Mobile'), findsOneWidget);
      // Phase 2 redesign (S5): period chips are the shared
      // ArenaFilterChip now, not ChoiceChip — same selection rule.
      final monthChip =
          tester.widget<ArenaFilterChip>(find.ancestor(
              of: find.text('This month'), matching: find.byType(ArenaFilterChip)));
      expect(monthChip.selected, isTrue);
      final allChip =
          tester.widget<ArenaFilterChip>(find.ancestor(
              of: find.text('All time'), matching: find.byType(ArenaFilterChip)));
      expect(allChip.selected, isFalse);
      expect(tester.takeException(), isNull);
    });
  });
}

/// Test host that opens [LeaderboardFilterSheet] as a real bottom
/// sheet and captures the value it pops with.
class _SheetHost {
  static const games = [
    {'id': 'g-pubg', 'name': 'PUBG Mobile'},
    {'id': 'g-cod', 'name': 'COD Mobile'},
  ];

  Map<String, dynamic>? result;

  Future<void> open(
    WidgetTester tester, {
    String? selectedGameId,
    String period = 'all',
  }) async {
    // Phone-sized viewport (same as leaderboard_tabs_search_test):
    // the sheet is tall and must render inside a real screen.
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
              builder: (_) => LeaderboardFilterSheet(
                games: games,
                selectedGameId: selectedGameId,
                period: period,
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
