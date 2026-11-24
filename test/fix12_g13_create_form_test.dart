// FIX 12 G13 (2026-11-23, user order 01:12) — ONE CREATE FORM.
// One unified form (name, description, photo) with TWO option boxes
// [Community] [Squad] at the end that ARE the submit action for
// their type. Tapping Community creates a community; tapping Squad
// creates a teams row (is_clan ignored — no Squad/Clan choice
// anywhere). This replaces the separate per-type create
// buttons/forms from Fix 11. The entry point is UNCHANGED:
// `CreateCommunityPage(uid: ...)` — same class, same constructor —
// so group G11's Create button calls it as before.
// Source-invariant tests read the sources (no backend); service +
// widget tests run against SupaDb.testFixtures (fixture seams in
// CommunityGroups.createCommunity / createSquad mirror the live
// writes in-memory — the production path is untouched).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/community_service.dart';
import 'package:protournament_user/screens/communities_screens.dart';
import 'package:protournament_user/screens/pro_features.dart';
import 'package:protournament_user/services/supabase_db.dart';
import 'package:shared_preferences/shared_preferences.dart';

String _read(String path) => File(path).readAsStringSync();

// Full-line // comments are stripped: the G13 notes mention
// Squad/Clan by name, so the assertions must check code, not prose.
String _code(String src) =>
    src.split('\n').where((l) => !l.trimLeft().startsWith('//')).join('\n');

String _region(String src, String from, String to) {
  final start = src.indexOf(from);
  final end = src.indexOf(to, start);
  return src.substring(start, end);
}

int _count(String src, String pattern) =>
    pattern.allMatches(src).length;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late String proFeatures;
  late String communityScreens;
  late String communityService;

  setUpAll(() {
    proFeatures = _read('lib/screens/pro_features.dart');
    communityScreens = _read('lib/screens/communities_screens.dart');
    communityService = _read('lib/community_service.dart');
  });

  tearDown(() {
    SupaDb.testFixtures = null;
  });

  group('G13 — entry point preserved (source invariants)', () {
    test('CreateCommunityPage class + constructor unchanged from Fix 11',
        () {
      expect(communityScreens,
          contains('class CreateCommunityPage extends StatefulWidget'));
      expect(
          communityScreens,
          contains(
              'const CreateCommunityPage({super.key, required this.uid});'));
      // Both call sites still push it with the same signature.
      expect(proFeatures, contains('CreateCommunityPage(uid: widget.uid)'));
      expect(communityScreens,
          contains('CreateCommunityPage(uid: widget.uid)'));
    });
  });

  group('G13 — unified form (source invariants)', () {
    late String form;
    late String formCode;

    setUpAll(() {
      form = _region(communityScreens, 'class CreateCommunityPage',
          'class CommunityAboutSheet');
      formCode = _code(form);
    });

    test('form has name + description + photo fields', () {
      expect(form, contains("label: 'Naam'"));
      expect(form, contains("label: 'Description'"));
      expect(form, contains('_pickPhoto'));
      expect(form, contains('Icons.add_a_photo'));
      expect(form, contains("Text('Photo (optional)'"));
      // The old per-type labels are gone.
      expect(form, isNot(contains("label: 'Community ka naam'")));
      expect(form, isNot(contains("'NAYI COMMUNITY'")));
      expect(form, isNot(contains("label: 'CREATE COMMUNITY'")));
    });

    test('two submit boxes: Community + Squad, wired to _create', () {
      expect(form, contains("label: 'Community'"));
      expect(form, contains("label: 'Squad'"));
      expect(form, contains('enum _CreateKind { community, squad }'));
      expect(form, contains('class _CreateTypeBox'));
      expect(form, contains('_create(_CreateKind.community)'));
      expect(form, contains('_create(_CreateKind.squad)'));
      // The old single submit button is gone — the boxes ARE the submit.
      expect(formCode, isNot(contains('GoldButton(')));
      // The submit routes to the right service call per type.
      expect(form, contains('CommunityGroups.createCommunity('));
      expect(form, contains('CommunityGroups.createSquad('));
    });

    test('no Squad/Clan toggle anywhere in the form', () {
      expect(formCode, isNot(contains('Switch(')));
      expect(formCode, isNot(contains('Radio(')));
      expect(formCode, isNot(contains('DropdownButton')));
      expect(formCode, isNot(contains("'is_clan'")));
      expect(formCode, isNot(contains('isClan')));
      expect(formCode, isNot(contains("'Clan'")));
    });
  });

  group('G13 — createSquad service (source invariants)', () {
    late String squad;

    setUpAll(() {
      squad = _region(communityService,
          'static Future<Map<String, dynamic>> createSquad(',
          '/// Delete a community.');
    });

    test('teams row + captain member row, invite code, never is_clan',
        () {
      expect(squad, contains(".from('teams').insert({"));
      expect(squad, contains(".from('team_members').insert({"));
      expect(squad, contains("'role': 'captain'"));
      expect(squad, contains('generateReferralCode(6)'));
      expect(squad, contains("'inviteCode': code"));
      expect(squad, contains('hasTestFixtures'));
      expect(_code(squad), isNot(contains("'is_clan'")));
    });

    test('createCommunity has the fixture seam (tests only)', () {
      final create = _region(
          communityService,
          'static Future<Map<String, dynamic>> createCommunity(',
          'static Future<Map<String, dynamic>> createSquad(');
      expect(create, contains('hasTestFixtures'));
      expect(create,
          contains("'communities', () => <Map<String, dynamic>>[]"));
      expect(create,
          contains("'community_members', () => <Map<String, dynamic>>[]"));
    });
  });

  group('G13 — TeamsPage single Create (source invariants)', () {
    test('one Create button per tab, no per-type buttons, no _createTeam',
        () {
      final teamsPage = _region(proFeatures, 'class _TeamsPageState',
          'class TeamDetailPage');
      // FIX 12 G11 + G13 (merge-lane adaptation): the per-tab
      // goldButtons are GONE — G11 replaced them with the
      // three-button top row, whose ONE Create entry (a
      // _toggleBtn labelled kCreateTabLabel) opens the unified
      // form via _openCreate -> _openCreateCommunity. So the
      // per-tab goldButton count is 0, not 2 — the "one Create
      // entry point" intent is pinned by the row below.
      expect(_count(teamsPage, "goldButton(label: 'Create',"), 0);
      expect(teamsPage, isNot(contains("goldButton(label: 'Create Clan'")));
      expect(teamsPage,
          isNot(contains("goldButton(label: 'Create Community'")));
      expect(teamsPage, isNot(contains('_createTeam')));
      expect(teamsPage, contains('_openCreateCommunity'));
      expect(teamsPage, contains('CreateCommunityPage(uid: widget.uid)'));
      expect(teamsPage, contains('kCreateTabLabel'));
      expect(teamsPage, contains('onTap: _openCreate'));
      expect(teamsPage,
          contains("actionLabel: _commQuery.isEmpty ? 'CREATE' : null"));
    });

    test('CommunitiesListPage FAB stays', () {
      expect(communityScreens, contains('FloatingActionButton.extended'));
      expect(communityScreens, contains("label: const Text('CREATE'"));
      expect(communityScreens, contains('onPressed: _openCreate'));
    });

    test('constraints: TEAM N sender pill intact, no tournament touch',
        () {
      expect(_code(communityScreens),
          contains("'TEAM \${_teamOf[senderUid]}'"));
      final form = _region(communityScreens, 'class CreateCommunityPage',
          'class CommunityAboutSheet');
      expect(form, isNot(contains('Tournament')));
    });
  });

  group('G13 — createSquad / createCommunity service (fixtures)', () {
    test('createSquad rejects empty name + missing login, no DB call',
        () async {
      var res =
          await CommunityGroups.createSquad(creatorUid: 'u1', name: '   ');
      expect(res['ok'], false);
      expect(res['error'], contains('naam'));
      res = await CommunityGroups.createSquad(creatorUid: '', name: 'Falcons');
      expect(res['ok'], false);
    });

    test('createSquad writes a teams row + captain row, no is_clan',
        () async {
      SupaDb.testFixtures = {
        'teams': [],
        'team_members': [],
        'profiles': [
          {
            'firebase_uid': 'test-uid',
            'display_name': 'Tester',
            'username': 'tester'
          },
        ],
      };
      final res = await CommunityGroups.createSquad(
          creatorUid: 'test-uid', name: 'Falcons');
      expect(res['ok'], true);
      expect(res['id'], isNotEmpty);
      expect((res['inviteCode'] as String).length, 6);
      final teams = SupaDb.testFixtures!['teams']!;
      expect(teams.length, 1);
      expect(teams.first['name'], 'Falcons');
      expect(teams.first['captain_uid'], 'test-uid');
      expect(teams.first['captain_name'], 'Tester');
      expect((teams.first['invite_code'] as String).length, 6);
      expect(teams.first.containsKey('is_clan'), isFalse);
      final members = SupaDb.testFixtures!['team_members']!;
      expect(members.length, 1);
      expect(members.first['team_id'], res['id']);
      expect(members.first['firebase_uid'], 'test-uid');
      expect(members.first['role'], 'captain');
    });

    test('createCommunity writes community + creator row (fixture seam)',
        () async {
      SupaDb.testFixtures = {
        'communities': [],
        'community_members': [],
      };
      final res = await CommunityGroups.createCommunity(
        creatorUid: 'test-uid',
        name: 'Meri Kahani',
        description: 'testing',
        photoUrl: 'https://imgbb.test/pic.jpg',
      );
      expect(res['ok'], true);
      final communities = SupaDb.testFixtures!['communities']!;
      expect(communities.length, 1);
      expect(communities.first['name'], 'Meri Kahani');
      expect(communities.first['description'], 'testing');
      expect(communities.first['photo_url'], 'https://imgbb.test/pic.jpg');
      expect(communities.first['is_public'], true);
      final members = SupaDb.testFixtures!['community_members']!;
      expect(members.length, 1);
      expect(members.first['community_id'], res['id']);
      expect(members.first['role'], 'creator');
    });
  });

  group('G13 — unified form (widget)', () {
    Map<String, List<Map<String, dynamic>>> baseFixtures() => {
          'teams': [],
          'team_members': [],
          'communities': [],
          'community_members': [],
          'profiles': [
            {
              'firebase_uid': 'test-uid',
              'display_name': 'Tester',
              'username': 'tester'
            },
          ],
        };

    Widget harness() => MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) => ElevatedButton(
                onPressed: () => Navigator.push(
                  ctx,
                  MaterialPageRoute(
                      builder: (_) =>
                          const CreateCommunityPage(uid: 'test-uid')),
                ),
                child: const Text('OPEN'),
              ),
            ),
          ),
        );

    Future<void> openForm(WidgetTester tester) async {
      await tester.pumpWidget(harness());
      await tester.tap(find.text('OPEN'));
      await tester.pumpAndSettle();
      expect(find.byType(CreateCommunityPage), findsOneWidget);
    }

    Future<void> enterName(WidgetTester tester, String name) async {
      final field = find.descendant(
        of: find.byKey(const Key('g13_create_name_field')),
        matching: find.byType(TextField),
      );
      await tester.enterText(field, name);
      await tester.pump();
    }

    testWidgets('renders name/description/photo + both boxes, no old submit',
        (tester) async {
      SupaDb.testFixtures = baseFixtures();
      await openForm(tester);
      expect(find.text('CREATE'), findsOneWidget);
      expect(find.text('Naam'), findsOneWidget);
      expect(find.text('Description'), findsOneWidget);
      expect(find.byIcon(Icons.add_a_photo), findsOneWidget);
      expect(find.text('Photo (optional)'), findsOneWidget);
      expect(find.byKey(const Key('g13_create_community_box')),
          findsOneWidget);
      expect(find.byKey(const Key('g13_create_squad_box')), findsOneWidget);
      expect(find.text('Community'), findsOneWidget);
      expect(find.text('Squad'), findsOneWidget);
      expect(find.text('CREATE COMMUNITY'), findsNothing);
      expect(find.text('NAYI COMMUNITY'), findsNothing);
      expect(find.text('Clan'), findsNothing);
      expect(find.byType(Switch), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Community box creates a community + pops', (tester) async {
      SupaDb.testFixtures = baseFixtures();
      await openForm(tester);
      await enterName(tester, 'Meri Kahani');
      final descField = find.descendant(
        of: find.byKey(const Key('g13_create_desc_field')),
        matching: find.byType(TextField),
      );
      await tester.enterText(descField, 'testing');
      await tester.pump();
      await tester.tap(find.byKey(const Key('g13_create_community_box')));
      await tester.pumpAndSettle();
      // Back at the harness — the form popped with success.
      expect(find.byType(CreateCommunityPage), findsNothing);
      expect(find.text('OPEN'), findsOneWidget);
      // The community row really landed (not just a toast).
      final communities = SupaDb.testFixtures!['communities']!;
      expect(communities.length, 1);
      expect(communities.first['name'], 'Meri Kahani');
      expect(communities.first['description'], 'testing');
      expect(communities.first['created_by_uid'], 'test-uid');
      final members = SupaDb.testFixtures!['community_members']!;
      expect(members.length, 1);
      expect(members.first['role'], 'creator');
      // And no squad was created by the Community box.
      expect(SupaDb.testFixtures!['teams']!, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Squad box creates a teams row + pops', (tester) async {
      SupaDb.testFixtures = baseFixtures();
      await openForm(tester);
      await enterName(tester, 'Falcons');
      await tester.tap(find.byKey(const Key('g13_create_squad_box')));
      await tester.pumpAndSettle();
      expect(find.byType(CreateCommunityPage), findsNothing);
      expect(find.text('OPEN'), findsOneWidget);
      final teams = SupaDb.testFixtures!['teams']!;
      expect(teams.length, 1);
      expect(teams.first['name'], 'Falcons');
      expect(teams.first['captain_uid'], 'test-uid');
      expect((teams.first['invite_code'] as String).length, 6);
      expect(teams.first.containsKey('is_clan'), isFalse);
      final members = SupaDb.testFixtures!['team_members']!;
      expect(members.length, 1);
      expect(members.first['role'], 'captain');
      // And no community was created by the Squad box.
      expect(SupaDb.testFixtures!['communities']!, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('empty name: tap does nothing, stays on form',
        (tester) async {
      SupaDb.testFixtures = baseFixtures();
      await openForm(tester);
      await tester.tap(find.byKey(const Key('g13_create_squad_box')));
      // Short pumps only — pumpAndSettle would fast-forward the
      // 4s SnackBar dismiss timer and hide the validation toast.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(CreateCommunityPage), findsOneWidget);
      expect(find.text('Naam likhen.'), findsOneWidget);
      expect(SupaDb.testFixtures!['teams']!, isEmpty);
      expect(tester.takeException(), isNull);
    });
  });

  group('G13 — TeamsPage single Create (widget)', () {
    setUp(() {
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
        ],
        'community_members': [
          {
            'community_id': 'comm-1',
            'firebase_uid': 'test-uid',
            'role': 'creator'
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

    testWidgets('one Create button on each tab, no per-type buttons',
        (tester) async {
      await pumpTeams(tester);
      expect(find.text('Create'), findsOneWidget);
      expect(find.text('Create Clan'), findsNothing);
      expect(find.text('Create Community'), findsNothing);
      expect(find.text('Join by Code'), findsOneWidget);
      expect(find.text('Falcons'), findsOneWidget);
      await tester.tap(find.text('Community'));
      await tester.pump();
      await settle(tester);
      expect(find.text('Create'), findsOneWidget);
      expect(find.text('Create Clan'), findsNothing);
      expect(find.text('Create Community'), findsNothing);
      expect(find.text('Meri Kahani'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Create opens the unified form', (tester) async {
      await pumpTeams(tester);
      await tester.tap(find.text('Create'));
      // Manual pumps, not pumpAndSettle: the TeamsPage CTA halo
      // animates continuously (same reason the Fix 11 tests use
      // pump loops here).
      await tester.pump();
      await settle(tester);
      expect(find.byType(CreateCommunityPage), findsOneWidget);
      expect(find.byKey(const Key('g13_create_community_box')),
          findsOneWidget);
      expect(
          find.byKey(const Key('g13_create_squad_box')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
