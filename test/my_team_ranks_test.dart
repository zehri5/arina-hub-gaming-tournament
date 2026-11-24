// P2 MY TEAM — RANKS / POSITIONS / CAP (2026-11-22, migration 081,
// FULL-AUDIT-2026-11-21.md #3):
//
//   * teams.team_rank (int, NULL = unranked) — the detail stats
//     strip shows the REAL rank ("Rank #8") or "Rank —", never a
//     fake rank. teams.max_members (default 4) drives the roster
//     header ("ROSTER (3/4)"), the stats strip ("3/4 Members")
//     and the honest empty slots.
//   * team_members.position (IGL / Assaulter / Support /
//     Entry Fragger, NULL = unset) — a member's roster role line
//     shows the stored position; the CAPTAIN gets a picker below
//     each member row to set it. Non-captains see no picker.
//   * Cap enforcement is client-side (invite / join-by-code /
//     accept): the pure gate is [teamIsFull]; the UI paths are
//     covered by the widget tests' roster state, not by tapping
//     through the network calls.
//
// What is NOT covered here (needs the live backend): the SQL
// itself (validated on staging — see 081's validation note),
// the actual position UPDATE round-trip (the picker writes via
// the live Supabase client, which has no fixture seam), and the
// recompute_team_ranks call site (NEXT STEP, not implemented
// in this round).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/screens/pro_features.dart';
import 'package:protournament_user/services/supabase_db.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _teamRow({int? rank, int? maxMembers}) => {
      'id': 'team-1',
      'name': 'Falcons',
      'tag': 'FLC',
      'game': 'PUBG Mobile',
      'is_clan': false,
      'captain_uid': 'captain-uid',
      'captain_name': 'ViperX',
      'invite_code': 'FLC123',
      if (rank != null) 'team_rank': rank,
      if (maxMembers != null) 'max_members': maxMembers,
    };

Map<String, List<Map<String, dynamic>>> _fixtures({int? rank, int? maxMembers, List<Map<String, dynamic>>? members}) => {
      'teams': [_teamRow(rank: rank, maxMembers: maxMembers)],
      'team_members': members ??
          [
            {'id': 'm1', 'team_id': 'team-1', 'firebase_uid': 'captain-uid', 'user_name': 'ViperX', 'role': 'captain', 'position': 'IGL'},
            {'id': 'm2', 'team_id': 'team-1', 'firebase_uid': 'member-1', 'user_name': 'SniperPro', 'role': 'member', 'position': 'Assaulter'},
            {'id': 'm3', 'team_id': 'team-1', 'firebase_uid': 'member-2', 'user_name': 'ApexPred', 'role': 'member'},
          ],
      'profiles': [],
    };

/// Pumps [TeamDetailPage] and lets its defensive _load finish.
/// _load awaits LIVE presence/profile lookups (real HTTPS, not
/// fixtures) before its setState, so the wait is in REAL time
/// (bounded poll, exits early once the roster header appears).
/// Then scrolls the roster into view: the ListView builds
/// below-fold rows lazily, so the member rows + empty slots are
/// not in the tree until scrolled to — plain finders would miss
/// them even with skipOffstage:false. No pumpAndSettle —
/// MockupCard's shine controllers repeat forever.
Future<void> _pumpTeamDetail(WidgetTester tester, {required String uid, Map<String, List<Map<String, dynamic>>>? fixtures, int? teamRank = 8}) async {
  SupaDb.testFixtures = fixtures ?? _fixtures(rank: 8, maxMembers: 4);
  await tester.pumpWidget(
    MaterialApp(home: TeamDetailPage(team: _teamRow(rank: teamRank, maxMembers: 4), uid: uid)),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 100));
  for (var i = 0; i < 10; i++) {
    await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 500)));
    await tester.pump();
    if (find.textContaining('ROSTER (', skipOffstage: false).evaluate().isNotEmpty) break;
  }
  await tester.drag(find.byType(ListView).first, const Offset(0, -500));
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  tearDown(() {
    SupaDb.testFixtures = null;
  });

  group('teamRankLabel (081)', () {
    test('real rank shows "Rank #N"', () {
      expect(teamRankLabel(8), 'Rank #8');
      expect(teamRankLabel(1), 'Rank #1');
      expect(teamRankLabel('3'), 'Rank #3');
    });

    test('unranked shows "Rank —", never a fake rank', () {
      expect(teamRankLabel(null), 'Rank —');
      expect(teamRankLabel(0), 'Rank —');
      expect(teamRankLabel(-1), 'Rank —');
      expect(teamRankLabel(''), 'Rank —');
    });
  });

  group('teamPositions (081)', () {
    test('exactly the four mockup #3 roles', () {
      expect(teamPositions, ['IGL', 'Assaulter', 'Support', 'Entry Fragger']);
    });

    test('isValidTeamPosition is case-sensitive and rejects junk', () {
      expect(isValidTeamPosition('IGL'), isTrue);
      expect(isValidTeamPosition('Entry Fragger'), isTrue);
      expect(isValidTeamPosition('Sniper'), isFalse);
      expect(isValidTeamPosition('igl'), isFalse);
      expect(isValidTeamPosition(null), isFalse);
      expect(isValidTeamPosition(''), isFalse);
    });

    test('teamPositionLabel passes valid positions through, else empty', () {
      expect(teamPositionLabel('Support'), 'Support');
      expect(teamPositionLabel(null), '');
      expect(teamPositionLabel('Sniper'), '');
    });
  });

  group('teamIsFull cap gate (081)', () {
    test('full at the cap and over it, open below it', () {
      expect(teamIsFull(4, 4), isTrue);
      expect(teamIsFull(5, 4), isTrue);
      expect(teamIsFull(3, 4), isFalse);
      expect(teamIsFull(0, 4), isFalse);
    });

    test('a null cap (clan) is never full', () {
      expect(teamIsFull(99, null), isFalse);
    });
  });

  group('roster size / labels with max_members (081)', () {
    test('explicit max_members wins over the default', () {
      expect(teamRosterSize({'max_members': 6}), 6);
      expect(teamRosterSize({'max_members': 6, 'is_clan': true}), 6);
      expect(teamRosterSize({'max_members': 4}), 4);
    });

    test('clan without a cap stays uncapped', () {
      expect(teamRosterSize({'is_clan': true}), isNull);
    });

    test('roster header shows N/max, bare count for a clan', () {
      expect(rosterHeaderLabel(3, 4), 'ROSTER (3/4)');
      expect(rosterHeaderLabel(4, 4), 'ROSTER (4/4)');
      expect(rosterHeaderLabel(3, null), 'ROSTER (3)');
    });

    test('members stat shows N/max, bare count for a clan', () {
      expect(membersStatLabel(3, 4), '3/4 Members');
      expect(membersStatLabel(3, null), '3 Members');
    });

    test('empty slots are honest: cap minus count, never negative', () {
      expect(emptySlotCount(3, 4), 1);
      expect(emptySlotCount(4, 4), 0);
      expect(emptySlotCount(5, 4), 0);
      expect(emptySlotCount(3, null), 0);
    });
  });

  group('TeamDetailPage — rank + roster header + empty slots (081)', () {
    testWidgets('real rank renders "Rank #8" (never the mockup sample)', (tester) async {
      await _pumpTeamDetail(tester, uid: 'captain-uid');
      expect(find.text('Rank #8', skipOffstage: false), findsOneWidget);
      expect(find.text('Rank —', skipOffstage: false), findsNothing);
    });

    testWidgets('unranked team renders "Rank —"', (tester) async {
      await _pumpTeamDetail(
        tester,
        uid: 'captain-uid',
        fixtures: _fixtures(rank: null, maxMembers: 4),
        teamRank: null,
      );
      expect(find.text('Rank —', skipOffstage: false), findsOneWidget);
    });

    testWidgets('roster header is "ROSTER (3/4)" with one honest empty slot', (tester) async {
      await _pumpTeamDetail(tester, uid: 'captain-uid');
      expect(find.text('ROSTER (3/4)', skipOffstage: false), findsOneWidget);
      expect(find.byType(EmptyRosterSlot, skipOffstage: false), findsOneWidget);
      // The stats strip shows the same N/max as the mockup.
      expect(find.text('3/4', skipOffstage: false), findsOneWidget);
    });

    testWidgets('full roster shows no empty slots', (tester) async {
      final members = [
        {'id': 'm1', 'team_id': 'team-1', 'firebase_uid': 'captain-uid', 'user_name': 'ViperX', 'role': 'captain', 'position': 'IGL'},
        {'id': 'm2', 'team_id': 'team-1', 'firebase_uid': 'member-1', 'user_name': 'SniperPro', 'role': 'member', 'position': 'Assaulter'},
        {'id': 'm3', 'team_id': 'team-1', 'firebase_uid': 'member-2', 'user_name': 'ApexPred', 'role': 'member', 'position': 'Support'},
        {'id': 'm4', 'team_id': 'team-1', 'firebase_uid': 'member-3', 'user_name': 'Fury_07', 'role': 'member', 'position': 'Entry Fragger'},
      ];
      await _pumpTeamDetail(tester, uid: 'captain-uid', fixtures: _fixtures(rank: 2, maxMembers: 4, members: members));
      expect(find.text('ROSTER (4/4)', skipOffstage: false), findsOneWidget);
      expect(find.byType(EmptyRosterSlot, skipOffstage: false), findsNothing);
    });
  });

  group('TeamDetailPage — position display + captain-only picker (081)', () {
    testWidgets('member role line shows the stored position', (tester) async {
      await _pumpTeamDetail(tester, uid: 'captain-uid');
      // Widget predicates, not raw text counts: the DropdownButton
      // keeps offstage copies of its items, so 'Assaulter' text
      // appears 3× — the role line is pinned by its widget prop.
      expect(
        find.byWidgetPredicate((w) => w is TeamMemberCard && w.roleText == 'Assaulter'),
        findsOneWidget,
      );
      expect(
        find.byWidgetPredicate((w) => w is TeamMemberCard && w.roleText == 'IGL / Leader'),
        findsOneWidget,
      );
    });

    testWidgets('captain sees a position picker per member row', (tester) async {
      await _pumpTeamDetail(tester, uid: 'captain-uid');
      // Two member rows (captain row has no picker): one picker
      // holds the stored value, the other is unset (null value).
      expect(find.byType(DropdownButton<String?>, skipOffstage: false), findsNWidgets(2));
      expect(
        find.byWidgetPredicate((w) => w is DropdownButton<String?> && w.value == 'Assaulter'),
        findsOneWidget,
      );
      expect(
        find.byWidgetPredicate((w) => w is DropdownButton<String?> && w.value == null),
        findsOneWidget,
      );
    });

    testWidgets('non-captain sees no position picker', (tester) async {
      await _pumpTeamDetail(tester, uid: 'member-1');
      expect(find.byType(DropdownButton<String?>, skipOffstage: false), findsNothing);
      // The stored position still shows on the role line.
      expect(
        find.byWidgetPredicate((w) => w is TeamMemberCard && w.roleText == 'Assaulter'),
        findsOneWidget,
      );
    });
  });
}
