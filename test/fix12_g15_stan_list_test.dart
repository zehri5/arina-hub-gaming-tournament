import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:protournament_user/screens/communities_screens.dart';
import 'package:protournament_user/screens/pro_features.dart';
import 'package:protournament_user/services/supabase_db.dart';
import 'package:protournament_user/theme.dart';

/// FIX 12 G15 — STAN-style community list (2026-11-23 user orders
/// 01:33 + 01:34 + 01:35).
///
/// Pins: ALL communities listed as STAN rows (round photo, name,
/// member count, arrow) ordered by COUNT-based member count
/// DESCENDING; the top 5 in a "Top Communities" section (5 is the
/// named constant [kTopCommunitiesCount]); NO banner grid (the
/// user cancelled it — its absence is a PASS condition); search +
/// pull-to-refresh + paging still work; gold #FDC903 + black ONLY
/// (STAN's purple is never copied — layout only).
///
/// Widget tests pump the real pages against SupaDb.testFixtures
/// (the FIX 6 seam) — no Supabase connection needed. The list
/// page reads SharedPreferences (cached-first list), so mock
/// values + a cleared live instance per test, like
/// communities_test.dart.

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
  });

  tearDown(() {
    SupaDb.testFixtures = null;
  });

  // A tall test surface so all 7 rows + both section headers are
  // built at once (ListView.builder only builds visible items).
  void tallSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(800, 2200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  double dy(WidgetTester tester, String text) =>
      tester.getTopLeft(find.text(text)).dy;

  // FIX 23 (gate): CommunitiesListPage sits on ArenaBackground, whose
  // AppBackgroundLayer runs the FireSparks animation forever — so
  // pumpAndSettle() can NEVER return on this page. Bounded pumps
  // (same pattern as fix11's settle()) let the fixture loads land
  // without waiting for an animation that never ends.
  Future<void> _settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }
  }

  /// 7 communities whose NEWEST-first order is deliberately the
  /// REVERSE of their member-count order, so a test that passes
  /// only when the list is count-sorted: Alpha is newest (3
  /// members) and Delta is oldest (0 members).
  Map<String, List<Map<String, dynamic>>> sevenFixtures() {
    final defs = <(String, String, String, int)>[
      ('c1', 'Alpha', '2026-11-21T10:00:00.000Z', 3),
      ('c2', 'Bravo', '2026-11-20T10:00:00.000Z', 50),
      ('c3', 'Charlie', '2026-11-19T10:00:00.000Z', 12),
      ('c4', 'Delta', '2026-11-18T10:00:00.000Z', 0),
      ('c5', 'Echo', '2026-11-17T10:00:00.000Z', 8),
      ('c6', 'Foxtrot', '2026-11-16T10:00:00.000Z', 25),
      ('c7', 'Golf', '2026-11-15T10:00:00.000Z', 1),
    ];
    final communities = defs
        .map((d) => {
              'id': d.$1,
              'name': d.$2,
              'description': d.$2 == 'Alpha' ? 'Best players only' : '',
              'photo_url': '',
              'created_by_uid': 'u9',
              'created_at': d.$3,
            })
        .toList();
    final members = <Map<String, dynamic>>[];
    for (final d in defs) {
      for (var i = 0; i < d.$4; i++) {
        members.add({
          'community_id': d.$1,
          'firebase_uid': 'm-${d.$1}-$i',
          'role': 'member',
        });
      }
    }
    return {'communities': communities, 'community_members': members};
  }

  group('kTopCommunitiesCount', () {
    test('is 5 — the Top Communities section size is a named constant',
        () {
      expect(kTopCommunitiesCount, 5);
    });
  });

  group('sortCommunitiesByMembers', () {
    test('orders by member count descending', () {
      final sorted = sortCommunitiesByMembers([
        {'name': 'Small', 'memberCount': 3},
        {'name': 'Big', 'memberCount': 50},
        {'name': 'Mid', 'memberCount': 12},
      ]);
      expect(sorted.map((c) => c['name']).toList(),
          ['Big', 'Mid', 'Small']);
    });

    test('ties break by name ascending; missing count reads 0', () {
      final sorted = sortCommunitiesByMembers([
        {'name': 'Zulu'},
        {'name': 'Alpha', 'memberCount': 0},
        {'name': 'Mike', 'memberCount': 0},
      ]);
      expect(sorted.map((c) => c['name']).toList(),
          ['Alpha', 'Mike', 'Zulu']);
    });

    test('returns a new list; the input order is untouched', () {
      final input = [
        {'name': 'Small', 'memberCount': 1},
        {'name': 'Big', 'memberCount': 9},
      ];
      final sorted = sortCommunitiesByMembers(input);
      expect(sorted.first['name'], 'Big');
      expect(input.first['name'], 'Small');
      expect(identical(sorted, input), isFalse);
    });
  });

  group('formatMemberCount', () {
    test('STAN-style compact counts', () {
      expect(formatMemberCount(0), '0');
      expect(formatMemberCount(1), '1');
      expect(formatMemberCount(999), '999');
      expect(formatMemberCount(1000), '1K');
      expect(formatMemberCount(1500), '1.5K');
      expect(formatMemberCount(15700), '15.7K');
      expect(formatMemberCount(4900000), '4.9M');
      expect(formatMemberCount(32800000), '32.8M');
      expect(formatMemberCount(1000000), '1M');
      expect(formatMemberCount(-5), '0');
    });
  });

  group('communityListSlots', () {
    test('empty list has no slots', () {
      expect(communityListSlots([], searching: false), isEmpty);
    });

    test('3 items: Top header + 3 rows, no All header', () {
      final slots = communityListSlots(
          List.generate(3, (i) => {'name': 'C$i'}),
          searching: false);
      expect(slots.length, 4);
      expect(slots[0].isHeader, isTrue);
      expect(slots[0].header, 'Top Communities');
      expect(slots.skip(1).every((s) => !s.isHeader), isTrue);
      expect(slots.where((s) => s.header == 'All Communities'),
          isEmpty);
    });

    test('7 items: Top header + 5 rows + All header + 2 rows', () {
      final items = List.generate(7, (i) => {'name': 'C$i'});
      final slots = communityListSlots(items, searching: false);
      expect(slots.length, 9);
      expect(slots[0].header, 'Top Communities');
      expect(
          slots.sublist(1, 6).map((s) => s.community!['name']).toList(),
          ['C0', 'C1', 'C2', 'C3', 'C4']);
      expect(slots[6].header, 'All Communities');
      expect(
          slots.sublist(7).map((s) => s.community!['name']).toList(),
          ['C5', 'C6']);
    });

    test('searching: plain rows, no section headers', () {
      final slots = communityListSlots(
          List.generate(7, (i) => {'name': 'C$i'}),
          searching: true);
      expect(slots.length, 7);
      expect(slots.every((s) => !s.isHeader), isTrue);
    });
  });

  group('CommunitiesListPage STAN list (fixture-backed)', () {
    testWidgets(
        'all 7 listed as STAN rows, count-desc, top 5 sectioned',
        (tester) async {
      tallSurface(tester);
      SupaDb.testFixtures = sevenFixtures();

      await tester.pumpWidget(
        const MaterialApp(home: CommunitiesListPage(uid: 'u1')),
      );
      await _settle(tester);

      // ALL communities are listed.
      for (final name in [
        'Alpha',
        'Bravo',
        'Charlie',
        'Delta',
        'Echo',
        'Foxtrot',
        'Golf'
      ]) {
        expect(find.text(name), findsOneWidget);
      }

      // Sections exist — and the 5 largest sit ABOVE the All
      // header, in count-descending order (50, 25, 12, 8, 3),
      // with the 2 smallest (1, 0) below it. Newest-first would
      // put Alpha (newest, 3 members) on top — it must NOT be.
      expect(find.text('Top Communities'), findsOneWidget);
      expect(find.text('All Communities'), findsOneWidget);
      expect(dy(tester, 'Top Communities') < dy(tester, 'Bravo'),
          isTrue);
      expect(dy(tester, 'Bravo') < dy(tester, 'Foxtrot'), isTrue);
      expect(dy(tester, 'Foxtrot') < dy(tester, 'Charlie'), isTrue);
      expect(dy(tester, 'Charlie') < dy(tester, 'Echo'), isTrue);
      expect(dy(tester, 'Echo') < dy(tester, 'Alpha'), isTrue);
      expect(dy(tester, 'Alpha') < dy(tester, 'All Communities'),
          isTrue);
      expect(dy(tester, 'All Communities') < dy(tester, 'Golf'),
          isTrue);
      expect(dy(tester, 'Golf') < dy(tester, 'Delta'), isTrue);

      // STAN row shape: 7 shared rows, each with a gold arrow.
      expect(find.byType(StanCommunityRow), findsNWidgets(7));
      expect(find.byIcon(Icons.arrow_forward), findsNWidgets(7));
      // Round photos (7) + gold arrow circles (7) = 14 avatars.
      expect(find.byType(CircleAvatar), findsNWidgets(14));

      // COUNT-based member counts, compact + labelled.
      expect(find.text('50 members'), findsOneWidget);
      expect(find.text('25 members'), findsOneWidget);
      expect(find.text('12 members'), findsOneWidget);
      expect(find.text('8 members'), findsOneWidget);
      expect(find.text('3 members'), findsOneWidget);
      expect(find.text('1 member'), findsOneWidget);
      expect(find.text('0 members'), findsOneWidget);

      // STAN rows carry no description and no follow button —
      // follow lives on the detail page.
      expect(find.text('Best players only'), findsNothing);
      expect(find.text('FOLLOW'), findsNothing);
      expect(find.text('JOINED'), findsNothing);

      // NO BANNER GRID (user cancelled it 01:34): no grid, no
      // Discover section, no banner cards anywhere in the list.
      expect(find.byType(GridView), findsNothing);
      expect(find.textContaining('Discover'), findsNothing);
      expect(find.textContaining('Banner'), findsNothing);

      // Search + pull-to-refresh + the list page's own FAB stay.
      expect(find.byType(TextField), findsOneWidget);
      expect(find.byType(RefreshIndicator), findsOneWidget);
      expect(find.text('CREATE'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('no purple anywhere in the list (gold + black only)',
        (tester) async {
      tallSurface(tester);
      SupaDb.testFixtures = sevenFixtures();
      await tester.pumpWidget(
        const MaterialApp(home: CommunitiesListPage(uid: 'u1')),
      );
      await _settle(tester);

      // NOT const: Color overrides ==, so a const set rejects it.
      final purple = <Color>{
        Colors.purple,
        Colors.deepPurple,
        Colors.purpleAccent,
        Color(0xFF7C5CFF), // STAN-ish purple
        Color(0xFF8B5CF6),
        Color(0xFF6D28D9),
      };
      var checked = 0;
      for (final w in tester.allWidgets) {
        if (w is Icon && w.color != null) {
          expect(purple.contains(w.color), isFalse,
              reason: 'purple icon: ${w.icon}');
          checked++;
        }
        if (w is Text && w.style?.color != null) {
          expect(purple.contains(w.style!.color), isFalse,
              reason: 'purple text: ${w.data}');
          checked++;
        }
        if (w is CircleAvatar && w.backgroundColor != null) {
          // Photo avatars are gold-tinted, arrow circles are gold.
          expect(
              w.backgroundColor == kGold ||
                  w.backgroundColor == kGold.withValues(alpha: 0.18),
              isTrue,
              reason:
                  'avatar is neither gold nor gold-tinted: ${w.backgroundColor}');
          checked++;
        }
      }
      // Non-vacuous: the walk must actually have seen widgets.
      expect(checked, greaterThan(20));
      // The arrow circles are gold, not STAN purple.
      final arrows = tester
          .widgetList<CircleAvatar>(find.byType(CircleAvatar))
          .where((a) => a.radius == 20);
      expect(arrows.length, 7);
      expect(arrows.every((a) => a.backgroundColor == kGold), isTrue);
    });

    testWidgets('search filters the list and drops the Top section',
        (tester) async {
      tallSurface(tester);
      SupaDb.testFixtures = sevenFixtures();
      await tester.pumpWidget(
        const MaterialApp(home: CommunitiesListPage(uid: 'u1')),
      );
      await _settle(tester);
      expect(find.text('Top Communities'), findsOneWidget);

      await tester.enterText(find.byType(TextField).first, 'bravo');
      // Pump past the 300ms search debounce explicitly — the
      // timer must fire before the settle, every cycle.
      await tester.pump(const Duration(milliseconds: 350));
      await _settle(tester);

      expect(find.text('Bravo'), findsOneWidget);
      expect(find.text('Alpha'), findsNothing);
      expect(find.text('Top Communities'), findsNothing);
      expect(find.text('All Communities'), findsNothing);

      // Clearing the search restores the sectioned list.
      await tester.enterText(find.byType(TextField).first, '');
      await tester.pump(const Duration(milliseconds: 350));
      await _settle(tester);
      expect(find.text('Top Communities'), findsOneWidget);
      expect(find.text('Bravo'), findsOneWidget);
      expect(find.text('Golf'), findsOneWidget);
    });

    testWidgets('paging: scrolling loads the 51st community',
        (tester) async {
      tallSurface(tester);
      final communities = List.generate(51, (i) {
        // Unique, strictly descending timestamps: Paged 00 is
        // newest, Paged 50 oldest — so page 1 is 00..49 and the
        // 51st item (Paged 50) only arrives with page 2.
        final created =
            DateTime.utc(2026, 11, 21, 23, 59).subtract(
          Duration(minutes: i),
        );
        return {
          'id': 'p$i',
          'name': 'Paged ${i.toString().padLeft(2, '0')}',
          'description': '',
          'photo_url': '',
          'created_by_uid': 'u9',
          'created_at': created.toIso8601String(),
        };
      });
      SupaDb.testFixtures = {
        'communities': communities,
        'community_members': [],
      };
      await tester.pumpWidget(
        const MaterialApp(home: CommunitiesListPage(uid: 'u1')),
      );
      await _settle(tester);

      // Page 1 (50) loaded; the 51st is not there yet.
      expect(find.text('Paged 00'), findsOneWidget);
      expect(find.text('Paged 50'), findsNothing);

      // Scroll to the bottom -> the next page loads.
      await tester.drag(
          find.byType(ListView).first, const Offset(0, -20000));
      await _settle(tester);

      // The 51st row is below the fold after the new page lands
      // (the scroll offset stays at the old max extent) — scroll
      // until it is built and visible.
      await tester.scrollUntilVisible(find.text('Paged 50'), 500.0);
      await _settle(tester);

      expect(find.text('Paged 50'), findsOneWidget);
      // Scroll back to the top — the first page is still there.
      await tester.drag(
          find.byType(ListView).first, const Offset(0, 20000));
      await _settle(tester);
      expect(find.text('Paged 00'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('Community tab embedded list (fixture-backed)', () {
    testWidgets('tab list is STAN-styled, count-desc, top 5 sectioned',
        (tester) async {
      tallSurface(tester);
      final seven = sevenFixtures();
      SupaDb.testFixtures = {
        'teams': [
          {
            'id': 'team-1',
            'name': 'Falcons',
            'tag': 'FLC',
            'game': 'PUBG Mobile',
            'is_clan': true,
            'captain_uid': 'test-uid',
            'captain_name': 'Tester',
            'invite_code': 'ABC123'
          },
        ],
        'team_members': [
          {
            'team_id': 'team-1',
            'firebase_uid': 'test-uid',
            'user_name': 'Tester',
            'role': 'captain'
          },
        ],
        'team_invitations': [],
        'communities': seven['communities']!,
        'community_members': seven['community_members']!,
        'profiles': [
          {
            'firebase_uid': 'test-uid',
            'display_name': 'Tester',
            'username': 'tester'
          },
        ],
      };

      await tester.pumpWidget(const MaterialApp(
          home: TeamsPage(uid: 'test-uid', embedded: true)));
      await tester.pump();
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }

      // Switch to the Community tab (the Clan/Community toggle
      // row above the list is G11's — this test only taps it).
      await tester.tap(find.text('Community'));
      await tester.pump();
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }

      for (final name in [
        'Alpha',
        'Bravo',
        'Charlie',
        'Delta',
        'Echo',
        'Foxtrot',
        'Golf'
      ]) {
        expect(find.text(name), findsOneWidget);
      }
      expect(find.text('Top Communities'), findsOneWidget);
      expect(find.text('All Communities'), findsOneWidget);
      expect(dy(tester, 'Bravo') < dy(tester, 'Foxtrot'), isTrue);
      expect(dy(tester, 'Foxtrot') < dy(tester, 'Charlie'), isTrue);
      expect(dy(tester, 'Charlie') < dy(tester, 'Echo'), isTrue);
      expect(dy(tester, 'Echo') < dy(tester, 'Alpha'), isTrue);
      expect(
          dy(tester, 'Alpha') < dy(tester, 'All Communities'), isTrue);
      expect(dy(tester, 'All Communities') < dy(tester, 'Golf'),
          isTrue);
      expect(dy(tester, 'Golf') < dy(tester, 'Delta'), isTrue);

      expect(find.byType(StanCommunityRow), findsNWidgets(7));
      expect(find.byIcon(Icons.arrow_forward), findsNWidgets(7));
      expect(find.text('50 members'), findsOneWidget);
      expect(find.text('FOLLOW'), findsNothing);
      expect(find.text('JOINED'), findsNothing);
      expect(find.byType(GridView), findsNothing);
      expect(find.byType(RefreshIndicator), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
