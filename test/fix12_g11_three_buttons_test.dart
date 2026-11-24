// FIX 12 G11 (2026-11-23, user order 01:35) — THREE-BUTTON TOP ROW.
// On the Communities screen (the teams-list screen opened from the
// bottom nav Communities tab), the top has ONE row of THREE buttons,
// in order: [Community] [Squad] [Create]. Community selected shows
// the communities list; Squad selected shows the squads list (all
// teams); Create opens the create form for the selected side. This
// REPLACES Fix 11's two-pill Clan/Community toggle + the separate
// Create Clan / Create Community buttons below it. Button 2's label
// is "Squad" (user said "Squad ya Team") and lives in the named
// constant kSquadTabLabel so it flips in one line. Join by Code
// stays on the Squad side. The unified create form is built by
// group G13 (MERGED 2026-11-23) — the Create button calls the
// unified form (_openCreateCommunity) through the single
// _openCreate call site; the old _createTeam dialog is DELETED.
// Source-invariant tests read the sources (no backend); widget
// tests pump TeamsPage with SupaDb.testFixtures.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/screens/communities_screens.dart';
import 'package:protournament_user/screens/pro_features.dart';
import 'package:protournament_user/services/supabase_db.dart';
import 'package:protournament_user/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

String _read(String path) => File(path).readAsStringSync();

String _region(String src, String from, String to) {
  final start = src.indexOf(from);
  final end = src.indexOf(to, start);
  return src.substring(start, end);
}

/// Source of one method body (from its signature line to the next
/// 2-space-indented member boundary inside the same class, or EOF).
String _method(String src, String signature) {
  final start = src.indexOf(signature);
  expect(start, isNot(-1), reason: 'method not found: $signature');
  final rest = src.substring(start + signature.length);
  final end = rest.indexOf(RegExp(r'\n  (Future<|Widget |void |@override)'));
  return end == -1
      ? src.substring(start)
      : src.substring(start, start + signature.length + end);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late String proFeatures;
  late String communityScreens;

  setUpAll(() {
    proFeatures = _read('lib/screens/pro_features.dart');
    communityScreens = _read('lib/screens/communities_screens.dart');
  });

  group('Fix 12 G11 — three-button top row (source invariants)', () {
    test('top-row labels are named constants; Squad is "Squad"', () {
      expect(proFeatures,
          contains("const String kCommunityTabLabel = 'Community';"));
      expect(proFeatures, contains("const String kSquadTabLabel = 'Squad';"));
      expect(proFeatures, contains("const String kCreateTabLabel = 'Create';"));
      // The constant itself, not just the source text.
      expect(kCommunityTabLabel, 'Community');
      expect(kSquadTabLabel, 'Squad');
      expect(kCreateTabLabel, 'Create');
    });

    test('three buttons in ONE row, in order Community / Squad / Create',
        () {
      final teamsPage =
          _region(proFeatures, 'class _TeamsPageState', 'class TeamDetailPage');
      final community = teamsPage.indexOf('label: kCommunityTabLabel');
      final squad = teamsPage.indexOf('label: kSquadTabLabel');
      final create = teamsPage.indexOf('label: kCreateTabLabel');
      expect(community, isNot(-1));
      expect(squad, isNot(-1));
      expect(create, isNot(-1));
      // All three in the same Row: the Row opens before the first
      // button and closes after the third, with no other Row
      // boundary between them.
      final rowStart = teamsPage.lastIndexOf('Row(children: [', community);
      final rowEnd = teamsPage.indexOf(']),', create);
      expect(rowStart, isNot(-1));
      expect(rowEnd, greaterThan(create));
      // No second Row boundary between the opener and the closer.
      expect(teamsPage.substring(rowStart + 'Row(children: ['.length, rowEnd),
          isNot(contains('Row(children: [')));
      expect(community, lessThan(squad));
      expect(squad, lessThan(create));
    });

    test('old two-pill Clan/Community toggle is gone', () {
      final teamsPage =
          _region(proFeatures, 'class _TeamsPageState', 'class TeamDetailPage');
      expect(teamsPage, isNot(contains("_toggleBtn(label: 'Clan'")));
      expect(teamsPage, isNot(contains("label: 'Clan'")));
      // The separate Create buttons below the toggle are gone too —
      // Create lives in the top row now. (The create DIALOG itself
      // is DELETED by FIX 12 G13 — the unified form replaces it.)
      expect(teamsPage, isNot(contains("goldButton(label: 'Create Clan'")));
      expect(
          teamsPage, isNot(contains("goldButton(label: 'Create Community'")));
    });

    test('Create is one call site opening the unified form', () {
      final teamsPage =
          _region(proFeatures, 'class _TeamsPageState', 'class TeamDetailPage');
      expect(teamsPage, contains('onTap: _openCreate'));
      final openCreate = _method(teamsPage, 'void _openCreate() {');
      // FIX 12 G13 (merged): the coordinator rewired this ONE
      // method to the unified form — both sides open
      // _openCreateCommunity; the old _createTeam dialog is
      // DELETED, so there is no _showCommunities branch any more.
      expect(openCreate, contains('_openCreateCommunity()'));
      expect(openCreate, isNot(contains('_createTeam()')));
      expect(openCreate, isNot(contains('_showCommunities')));
    });

    test('Join by Code stays on the Squad side', () {
      final teamsPage =
          _region(proFeatures, 'class _TeamsPageState', 'class TeamDetailPage');
      // The Join button's onPressed sits after the Squad-side
      // guard and before the Community-side block.
      final guard = teamsPage.indexOf('if (!_showCommunities)');
      final join = teamsPage.indexOf("Text('Join by Code'");
      final communityBlock = teamsPage.indexOf('if (_showCommunities) ...[');
      expect(guard, isNot(-1));
      expect(join, isNot(-1));
      expect(communityBlock, isNot(-1));
      expect(join, greaterThan(guard));
      expect(join, lessThan(communityBlock));
    });

    test('CommunitiesListPage keeps its own FAB (untouched)', () {
      expect(communityScreens,
          contains('floatingActionButton: FloatingActionButton.extended('));
    });
  });

  group('Fix 12 G11 — three-button top row (widget)', () {
    setUp(() {
      SupaDb.testFixtures = {
        'teams': [
          {
            'id': 'team-1',
            'name': 'Falcons',
            'tag': 'FLC',
            'game': 'PUBG Mobile',
            'is_clan': false,
            'captain_uid': 'test-uid',
            'captain_name': 'Tester',
            'invite_code': 'ABC123'
          },
          {
            'id': 'team-2',
            'name': 'Wolves',
            'tag': 'WLF',
            'game': 'PUBG Mobile',
            'is_clan': true,
            'captain_uid': 'test-uid',
            'captain_name': 'Tester',
            'invite_code': 'XYZ789'
          },
        ],
        'team_members': [
          {
            'team_id': 'team-1',
            'firebase_uid': 'test-uid',
            'user_name': 'Tester',
            'role': 'captain'
          },
          {
            'team_id': 'team-2',
            'firebase_uid': 'test-uid',
            'user_name': 'Tester',
            'role': 'captain'
          },
        ],
        'team_invitations': [],
        'communities': [
          {
            'id': 'comm-1',
            'name': 'Meri Kahani',
            'description': 'testing',
            'photo_url': '',
            'is_public': true,
            'created_by_uid': 'test-uid',
            'created_at': '2026-11-22T19:39:32Z',
          },
          {
            'id': 'comm-2',
            'name': 'Pro Gamers',
            'description': '',
            'photo_url': '',
            'is_public': true,
            'created_by_uid': 'other-uid',
            'created_at': '2026-11-22T18:00:00Z',
          },
        ],
        'community_members': [
          {
            'community_id': 'comm-1',
            'firebase_uid': 'test-uid',
            'role': 'creator'
          },
          {
            'community_id': 'comm-1',
            'firebase_uid': 'other-uid',
            'role': 'member'
          },
        ],
        'profiles': [
          {
            'firebase_uid': 'test-uid',
            'display_name': 'Tester',
            'username': 'tester'
          },
        ],
      };
    });
    tearDown(() {
      SupaDb.testFixtures = null;
    });

    Future<void> pumpTeams(WidgetTester tester) async {
      await tester.pumpWidget(const MaterialApp(
          home: TeamsPage(uid: 'test-uid', embedded: true)));
      await tester.pump();
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
    }

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
    }

    Color? labelColor(WidgetTester tester, String label) =>
        tester.widget<Text>(find.text(label)).style?.color;

    testWidgets('three buttons render in order, on one row',
        (tester) async {
      await pumpTeams(tester);
      expect(find.text('Community'), findsOneWidget);
      expect(find.text('Squad'), findsOneWidget);
      expect(find.text('Create'), findsOneWidget);
      // Left-to-right order: Community, then Squad, then Create.
      final communityX = tester.getCenter(find.text('Community')).dx;
      final squadX = tester.getCenter(find.text('Squad')).dx;
      final createX = tester.getCenter(find.text('Create')).dx;
      expect(communityX, lessThan(squadX));
      expect(squadX, lessThan(createX));
      // Same row: same vertical centre (within 1px).
      final communityY = tester.getCenter(find.text('Community')).dy;
      final squadY = tester.getCenter(find.text('Squad')).dy;
      final createY = tester.getCenter(find.text('Create')).dy;
      expect((communityY - squadY).abs(), lessThan(1.0));
      expect((squadY - createY).abs(), lessThan(1.0));
      expect(tester.takeException(), isNull);
    });

    testWidgets('default side is Squad: teams list + Join by Code',
        (tester) async {
      await pumpTeams(tester);
      expect(find.text('Falcons'), findsOneWidget);
      expect(find.text('Wolves'), findsOneWidget);
      expect(find.text('Join by Code'), findsOneWidget);
      expect(find.text('Meri Kahani'), findsNothing);
      // Squad is the selected tab (black text on gold); Community
      // is unselected (gold text on dark).
      expect(labelColor(tester, 'Squad'), const Color(0xFF0A0A0F));
      expect(labelColor(tester, 'Community'), kGold);
      expect(tester.takeException(), isNull);
    });

    testWidgets('tapping Community shows the communities list',
        (tester) async {
      await pumpTeams(tester);
      await tester.tap(find.text('Community'));
      await tester.pump();
      await settle(tester);
      expect(find.text('Meri Kahani'), findsOneWidget);
      expect(find.text('Pro Gamers'), findsOneWidget);
      expect(find.text('Falcons'), findsNothing);
      expect(find.text('Wolves'), findsNothing);
      // Community-side controls: search field in, Join by Code out.
      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('Join by Code'), findsNothing);
      // Selection flipped with the tap.
      expect(labelColor(tester, 'Community'), const Color(0xFF0A0A0F));
      expect(labelColor(tester, 'Squad'), kGold);
      expect(tester.takeException(), isNull);
    });

    testWidgets('tapping Squad shows the squads list again',
        (tester) async {
      await pumpTeams(tester);
      await tester.tap(find.text('Community'));
      await tester.pump();
      await settle(tester);
      expect(find.text('Meri Kahani'), findsOneWidget);
      await tester.tap(find.text('Squad'));
      await tester.pump();
      await settle(tester);
      expect(find.text('Falcons'), findsOneWidget);
      expect(find.text('Wolves'), findsOneWidget);
      expect(find.text('Meri Kahani'), findsNothing);
      expect(find.text('Join by Code'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('old two-pill toggle is gone', (tester) async {
      await pumpTeams(tester);
      expect(find.text('Clan'), findsNothing);
      expect(find.text('Create Clan'), findsNothing);
      expect(find.text('Create Community'), findsNothing);
      await tester.tap(find.text('Community'));
      await tester.pump();
      await settle(tester);
      expect(find.text('Clan'), findsNothing);
      expect(find.text('Create Clan'), findsNothing);
      expect(find.text('Create Community'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Squad label comes from the named constant',
        (tester) async {
      expect(kSquadTabLabel, 'Squad');
      await pumpTeams(tester);
      // The rendered button reads the constant, not a literal.
      expect(find.text(kSquadTabLabel), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Create on the Squad side opens the unified form',
        (tester) async {
      await pumpTeams(tester);
      await tester.tap(find.text('Create'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      // FIX 12 G13 (merged): the old squad create dialog is
      // DELETED — Create opens the SAME unified form on both
      // sides (name, description, photo + [Community]/[Squad]).
      expect(find.byType(CreateCommunityPage), findsOneWidget);
      expect(find.text('Create Team'), findsNothing);
      expect(find.text('Team name'), findsNothing);
      expect(find.text('Create Clan'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Create on the Community side opens the create page',
        (tester) async {
      await pumpTeams(tester);
      await tester.tap(find.text('Community'));
      await tester.pump();
      await settle(tester);
      await tester.tap(find.text('Create'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      // The EXISTING community create page (not a new form).
      expect(find.byType(CreateCommunityPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
