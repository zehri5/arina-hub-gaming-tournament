// FIX 11 (2026-11-23, user order) — COMMUNITY TAB REDESIGN +
// REMOVE THE SQUAD SYSTEM. FIX 12 GROUP G5 (2026-11-23 01:09)
// removed the CLAN type too — the toggle's teams tab is labelled
// 'Teams' now (was 'Clan'), the CLAN pill is gone from both the
// list card and the detail header, and teamMicCount takes no
// parameter. The create form still writes is_clan=true — that
// write is group G13's scope, not this file's.
//   1. My Team screen: modern Teams / Community toggle at the top
//      (same twin-pill style as Create/Join); the selected tab's
//      list shows below. Teams tab = my teams (whole card tappable
//      → chat) + Create Team + Join by Code + invites. Community
//      tab = public communities, paged 50, scrollable, searchable,
//      pull-to-refresh; tap opens the detail page; Create
//      Community lives here. The old "Browse Communities" button
//      is gone.
//      FIX 12 G11 (2026-11-23) SUPERSEDES the toggle half of (1):
//      the two-pill Clan/Community toggle + the separate Create
//      Clan / Create Community buttons are replaced by ONE row of
//      three buttons [Community] [Squad] [Create]; Join by Code
//      stays on the Squad side; Create dispatches to the existing
//      entry points through _openCreate. The rest of Fix 11
//      (squad removal, TEAM N pill, 6 mic seats) stands.
//   2. Squad is GONE from the team flow: the create form always
//      writes is_clan=true (no toggle), no SQUAD pill/label
//      anywhere in team UI, every team room has 6 mic seats.
//      Voice-room ids (squad_<teamId>) are UNCHANGED — existing
//      rooms keep working. The community-chat sender pill is
//      renamed SQUAD N → TEAM N (same numbering).
//   3. Tournament modes (Solo/Duo/Squad registration) are NOT part
//      of this removal — they describe tournament formats, not
//      team types, and are untouched.
// Source-invariant tests read the sources (no backend); widget
// tests pump TeamsPage with SupaDb.testFixtures.
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_auth_platform_interface/firebase_auth_platform_interface.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/screens/communities_screens.dart';
import 'package:protournament_user/screens/pro_features.dart';
import 'package:protournament_user/services/squad.dart';
import 'package:protournament_user/services/supabase_db.dart';
import 'package:shared_preferences/shared_preferences.dart';

String _read(String path) => File(path).readAsStringSync();

// Full-line // comments are stripped: the FIX 11 removal notes
// mention Squad by name, so the assertions must check code, not
// prose.
String _code(String src) =>
    src.split('\n').where((l) => !l.trimLeft().startsWith('//')).join('\n');

String _region(String src, String from, String to) {
  final start = src.indexOf(from);
  final end = src.indexOf(to, start);
  return src.substring(start, end);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late String proFeatures;
  late String communityScreens;
  late String squadService;

  setUpAll(() {
    proFeatures = _read('lib/screens/pro_features.dart');
    communityScreens = _read('lib/screens/communities_screens.dart');
    squadService = _read('lib/services/squad.dart');
  });

  // Fake Firebase (device_ban_gate_test pattern, copied from
  // fix12_g4_about_menu_test.dart): FIX 23 item 16a mounts the
  // voice panel ALWAYS, so pushing the detail page runs the
  // VoiceRoom constructor, which reads currentUser!.uid — a
  // signed-in user must exist before any push.
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    // FIX 17 (gate): real Roboto — the fallback test font fakes an
    // overflow on the detail page (see _loadRoboto below).
    await _loadRoboto();
    FirebasePlatform.instance = _FakeCorePlatform();
    FirebaseAuthPlatform.instance = _FakeAuthPlatform();
    await Firebase.initializeApp(
      options: const FirebaseOptions(
apiKey: 'test',
        appId: '1:1:android:1',
        messagingSenderId: '1',
        projectId: 'test',
      ),
    );
    // ignore: unnecessary_statements
    FirebaseAuth.instance;
  });

  setUp(() async {
    await FirebaseAuth.instance.signOut();
    await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: 'test@test.com', password: 'x');
  });

  group('Fix 11 — toggle + tabs (source invariants)', () {
    test('three-button top row exists (G11), Browse Communities is gone',
        () {
      final teamsPage = _region(proFeatures, 'class _TeamsPageState',
          'class TeamDetailPage');
      // FIX 12 G11 replaced Fix 11's two-pill Clan/Community toggle
      // with ONE row of three buttons: Community / Squad / Create.
      expect(teamsPage, contains("_toggleBtn(label: kCommunityTabLabel"));
      expect(teamsPage, contains("_toggleBtn(label: kSquadTabLabel"));
      expect(teamsPage, contains("_toggleBtn(label: kCreateTabLabel"));
      expect(teamsPage, isNot(contains("_toggleBtn(label: 'Clan'")));
      expect(teamsPage, contains('_selectTab('));
      expect(teamsPage, contains('bool _showCommunities = false'));
      expect(teamsPage, isNot(contains("label: 'Browse Communities'")));
    });

    test('Community tab loads paged communities + refresh + search',
        () {
      final teamsPage = _region(proFeatures, 'class _TeamsPageState',
          'class TeamDetailPage');
      expect(teamsPage, contains('CommunityGroups.listCommunities'));
      expect(teamsPage, contains('CommunityGroups.pageSize'));
      expect(teamsPage, contains('RefreshIndicator('));
      expect(teamsPage, contains("hintText: 'Community dhoonden...'"));
      expect(teamsPage, contains('_buildCommunityList()'));
    });

    test('Create + open routes: team, community, detail', () {
      final teamsPage = _region(proFeatures, 'class _TeamsPageState',
          'class TeamDetailPage');
      // FIX 12 G11: no separate Create Clan / Create Community
      // buttons — the top row's Create dispatches to both existing
      // entries through the single _openCreate call site.
      expect(teamsPage, isNot(contains("goldButton(label: 'Create Clan'")));
      // Merge lane: G5 renamed the button 'Create Team' before G11
      // removed it — pin that absence too.
      expect(teamsPage, isNot(contains("goldButton(label: 'Create Team'")));
      expect(
          teamsPage, isNot(contains("goldButton(label: 'Create Community'")));
      expect(teamsPage, contains('onTap: _openCreate'));
      expect(teamsPage, contains('CreateCommunityPage(uid: widget.uid)'));
      expect(teamsPage, contains('CommunityDetailPage('));
      // Whole team card opens the chat (not just the button).
      expect(
          teamsPage,
          contains(
              'child: InkWell(\n                                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => TeamChatPage(team: t, uid: widget.uid, navIndex: widget.embedded ? 4 : 2))),'));
    });

    test('No SQUAD/CLAN label in team lists/cards/detail (code, not prose)',
        () {
      final teamsPage = _code(_region(proFeatures, 'class _TeamsPageState',
          'class TeamDetailPage'));
      final detailPage = _code(_region(proFeatures, 'class TeamDetailPage',
          'class TeamHistoryPage'));
      expect(teamsPage, isNot(contains("'SQUAD'")));
      expect(detailPage, isNot(contains("'SQUAD'")));
      // FIX 12 G5: no CLAN pill either — every team is just a team.
      expect(teamsPage, isNot(contains("Text('CLAN'")));
      expect(detailPage, isNot(contains("Text('CLAN'")));
    });

    test('Create form is the unified page — no _createTeam dialog, Squad writes no is_clan', () {
      // FIX 12 G13 (merged): the _createTeam dialog is DELETED —
      // the ONE create entry is the unified CreateCommunityPage
      // (name, description, photo + [Community]/[Squad] boxes),
      // opened from the three-button row via _openCreate.
      expect(proFeatures, isNot(contains('Future<void> _createTeam()')));
      expect(proFeatures, contains('_openCreateCommunity'));
      expect(proFeatures, contains('CreateCommunityPage(uid: widget.uid)'));
      // No is_clan:true write anywhere in the teams page any more
      // (the Squad path writes no is_clan at all — the only
      // constant is_clan write left in lib is ensureTeamForJoin's
      // false, pinned by the G5 suite).
      expect(proFeatures, isNot(contains("'is_clan': true")));
    });

    test('Mic counts: every team room has 6 seats', () {
      // FIX 12 G5: teamMicCount takes no parameter — the
      // is_clan distinction is gone, every team gets 6 seats.
      expect(teamMicCount(), 6);
    });

    test('Roster size: no squad default — uncapped without a size',
        () {
      expect(teamRosterSize({}), isNull);
      expect(teamRosterSize({'is_clan': false}), isNull);
      expect(teamRosterSize({'is_clan': true}), isNull);
      expect(teamRosterSize({'max_members': 6}), 6);
    });

    test('Voice-room ids unchanged (existing rooms keep working)', () {
      expect(squadService, contains("String squadRoomId(String squadId) => 'squad_\$squadId';"));
      expect(proFeatures, contains("squad_<teamId>"));
    });

    test('Community-chat sender pill renamed SQUAD N -> TEAM N', () {
      final code = _code(communityScreens);
      expect(code, contains("'TEAM \${_teamOf[senderUid]}'"));
      expect(code, isNot(contains("'SQUAD ")));
      expect(code, isNot(contains('_squadOf')));
    });
  });

  group('Fix 11 — TeamsPage tabs (widget)', () {
    setUp(() {
      SupaDb.testFixtures = {
        'teams': [
          {
            'id': 'team-1',
            'name': 'Falcons',
            'tag': 'FLC',
            'game': 'PUBG Mobile',
            // Pre-Fix-11 squad row: still shows — every team is just
            // a team now, no team is ever hidden by the old flag.
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

    testWidgets('default squad tab: both teams, no CLAN/SQUAD pills',
        (tester) async {
      await pumpTeams(tester);
      // FIX 12 G11: three-button top row (Community / Squad /
      // Create); the old Clan toggle + Create Clan button are gone.
      expect(find.text('Community'), findsOneWidget);
      expect(find.text('Squad'), findsOneWidget);
      expect(find.text('Create'), findsOneWidget);
      expect(find.text('Clan'), findsNothing);
      expect(find.text('Create Clan'), findsNothing);
      expect(find.text('Join by Code'), findsOneWidget);
      expect(find.text('Falcons'), findsOneWidget);
      expect(find.text('Wolves'), findsOneWidget);
      // FIX 12 G5: no type pill on any card (incl. the old clan row).
      expect(find.text('CLAN'), findsNothing);
      expect(find.text('SQUAD'), findsNothing);
      expect(find.text('Browse Communities'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Community tab lists communities; tap opens detail',
        (tester) async {
      await pumpTeams(tester);
      await tester.tap(find.text('Community'));
      await tester.pump();
      await settle(tester);
      expect(find.text('Meri Kahani'), findsOneWidget);
      expect(find.text('Pro Gamers'), findsOneWidget);
      expect(find.text('2 members'), findsOneWidget);
      // FIX 12 G11: Create lives in the top row now — no separate
      // Create Community button on this side.
      expect(find.text('Create'), findsOneWidget);
      expect(find.text('Create Community'), findsNothing);
      expect(find.text('Create Clan'), findsNothing);
      expect(find.text('Falcons'), findsNothing);
      // Tap a community row → detail page opens.
      await tester.tap(find.text('Meri Kahani'));
      await tester.pump();
      // FIX 23 item 16a: the detail page mounts the voice panel
      // immediately, so the DSP mic-processor ping timer (2s +
      // 2s retry = 4s) is pending — flush past it before the
      // test ends, or the pending timer fails the test.
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      await tester.pump(const Duration(seconds: 5));
      expect(find.byType(CommunityDetailPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('whole team card tap opens the chat', (tester) async {
      await pumpTeams(tester);
      // Tap the team NAME (not the 'Members & Chat' button).
      await tester.tap(find.text('Falcons'));
      await tester.pump();
      await settle(tester);
      expect(find.byType(TeamChatPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('toggle back to Squad restores the squad list',
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
      expect(tester.takeException(), isNull);
    });
  });
}

// ---- Fake Firebase (exact pattern from device_ban_gate_test,
// copied from fix20_community_voice_test.dart; the fake signs in
// as test-uid, this file's page uid) ----

class _FakeAppPlatform extends FirebaseAppPlatform {
  _FakeAppPlatform(super.name, super.options);
}

class _FakeCorePlatform extends FirebasePlatform {
  FirebaseAppPlatform? _app;

  @override
  Future<FirebaseAppPlatform> initializeApp(
      {String? name, FirebaseOptions? options}) async {
    _app = _FakeAppPlatform(
      name ?? defaultFirebaseAppName,
      options ??
          const FirebaseOptions(
            apiKey: 'test',
            appId: '1:1:android:1',
            messagingSenderId: '1',
            projectId: 'test',
          ),
    );
    return _app!;
  }

  @override
  FirebaseAppPlatform app([String name = defaultFirebaseAppName]) {
    final a = _app;
    if (a == null) throw StateError('Firebase.initializeApp() was not called');
    return a;
  }
}

class _FakeMultiFactor extends MultiFactorPlatform {
  _FakeMultiFactor(super.auth);
}

class _FakeUser extends UserPlatform {
  _FakeUser(super.auth, super.multiFactor, super.user);
}

class _FakeUserCredential extends UserCredentialPlatform {
  _FakeUserCredential({required super.auth, super.user});
}

class _FakeAuthPlatform extends FirebaseAuthPlatform {
  _FakeAuthPlatform({super.appInstance});

  UserPlatform? _user;

  @override
  FirebaseAuthPlatform delegateFor({required FirebaseApp app}) =>
      _FakeAuthPlatform(appInstance: app);

  @override
  FirebaseAuthPlatform setInitialValues(
      {PigeonUserDetails? currentUser, String? languageCode}) {
    _user = currentUser == null
        ? null
        : _FakeUser(
            this,
            _FakeMultiFactor(this),
            currentUser,
          );
    return this;
  }

  @override
  UserPlatform? get currentUser => _user;

  @override
  set currentUser(UserPlatform? user) => _user = user;

  @override
  Future<UserCredentialPlatform> signInWithEmailAndPassword(
    String email,
    String password,
  ) async {
    final details = PigeonUserDetails(
      userInfo: PigeonUserInfo(
        uid: 'test-uid',
        email: email,
        isAnonymous: false,
        isEmailVerified: true,
      ),
      providerData: [],
    );
    _user = _FakeUser(this, _FakeMultiFactor(this), details);
    return _FakeUserCredential(auth: this, user: _user);
  }

  @override
  Future<void> signOut() async {
    _user = null;
  }
}

// FIX 17 (gate): load the real Roboto so 360px fit tests measure what a
// real phone measures — the fallback test font is ~2x wider/taller and
// fakes an overflow (same approach as fix22_watch_engagement_test.dart).
Future<void> _loadRoboto() async {
  final home = Platform.environment['HOME'] ?? '';
  final dir = '$home/flutter/bin/cache/artifacts/material_fonts';
  final loader = FontLoader('Roboto');
  for (final file in [
    'Roboto-Regular.ttf',
    'Roboto-Medium.ttf',
    'Roboto-Bold.ttf',
    'Roboto-Black.ttf',
  ]) {
    final bytes = await File('$dir/$file').readAsBytes();
    loader.addFont(Future.value(bytes.buffer.asByteData()));
  }
  await loader.load();
}
