// FIX 12 G12 — TAP → CHAT DIRECTLY (2026-11-23, user order 01:12).
//
//   * Tapping a squad/clan card opens its CHAT directly
//     (TeamChatPage) — already true in the base (FIX 11), pinned
//     here so no later change can quietly route it back through
//     the detail page.
//   * Tapping a community opens its CHAT — CommunityDetailPage
//     IS the chat (FIX 22 removed the CHAT/MEMBERS tab bar, so
//     there is no tab to land on anymore; Follow button + About
//     menu stay on the detail header, Members opens as a page).
//
// FIX 22 (2026-11-23, user order: "ye hata do, direct chat nazar
// aye") SUPERSEDES the tab-index machinery this file pinned:
// CommunityDetailTab / communityDetailTabs / communityDetailTabIndex
// are DELETED. The pins below were rewritten to the new structure:
// no tabs at all, chat renders directly, Members opens as a page.
//
// FIX 23 (items 1+4+9+12+16a) SUPERSEDES the detail header: the
// top bar is gone (no More menu, no Members button); Follow lives
// in the sidebar Followers spot, About in the Settings sheet, the
// members page opens from the sidebar Followers entry, and the
// voice panel mounts ALWAYS for members — so this file needs the
// fake Firebase auth (VoiceRoom reads currentUser!.uid at mount).
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
import 'package:protournament_user/services/supabase_db.dart';
import 'package:shared_preferences/shared_preferences.dart';

String _read(String path) => File(path).readAsStringSync();

String _stripComments(String src) => src
    .split('\n')
    .where((l) => !l.trimLeft().startsWith('//'))
    .join('\n');

Future<void> _settle(WidgetTester tester) async {
  // 4s flushes the fixture futures + the DSP ping/retry (2s +
  // 2s, fix21 item 2); the final 5s flushes the mount toast's
  // snackbar timer (fix20 detail-group pattern). The old 1.6s
  // settle left the DSP timer pending once the room mounted at
  // pump time (FIX 23 item 16a).
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 500));
  }
  await tester.pump(const Duration(seconds: 5));
}

const _community = {
  'id': 'c1',
  'name': 'PUBG Pros',
  'description': 'Best players only',
  'photo_url': '',
  'created_by_uid': 'u9',
  'voice_enabled': true,
  'isMember': true,
  'myRole': 'member',
  'memberCount': 1,
};

Map<String, List<Map<String, dynamic>>> _detailFixtures() => {
      'communities': [
        {
          'id': 'c1',
          'name': 'PUBG Pros',
          'description': 'Best players only',
          'photo_url': '',
          'created_by_uid': 'u9',
          'voice_enabled': true,
          'created_at': '2026-11-21T10:00:00.000Z',
        },
      ],
      'community_members': [
        {
          'community_id': 'c1',
          'firebase_uid': 'u1',
          'role': 'member',
          'joined_at': '2026-11-21T10:00:00.000Z',
        },
      ],
      'community_posts': [],
      'chat_messages': [],
      'profiles': [
        {
          'firebase_uid': 'u1',
          'display_name': 'Tester',
          'username': 'tester',
        },
      ],
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  // Fake Firebase FIRST (top-level setUpAll, device_ban_gate_test
  // pattern — the detail page mounts UnifiedRoomPage, whose
  // services touch FirebaseAuth.instance; without the fakes the
  // real delegate caches and Firebase.initializeApp() hits the
  // native channel).
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

  // A signed-in user must exist before any detail-page pump
  // (VoiceRoom's constructor reads currentUser!.uid). The fake
  // signs in as u1, the detail tests' page uid; the TeamsPage
  // test passes its own uid explicitly and never touches the room.
  setUp(() async {
    await FirebaseAuth.instance.signOut();
    await FirebaseAuth.instance
        .signInWithEmailAndPassword(email: 'u1@test.com', password: 'x');
  });

  group('G12 — source invariants (no tabs at all, FIX 22)', () {
    late String communitiesScreens;
    late String proFeatures;

    setUpAll(() {
      communitiesScreens = _read('lib/screens/communities_screens.dart');
      proFeatures = _read('lib/screens/pro_features.dart');
    });

    test('CommunityDetailPage has no tab machinery at all', () {
      final src = _stripComments(communitiesScreens);
      expect(src, isNot(contains('TabController')));
      expect(src, isNot(contains('TabBar')));
      expect(src, isNot(contains('TabBarView')));
      expect(src, isNot(contains('CommunityDetailTab')));
      expect(src, isNot(contains('communityDetailTabs')));
      expect(src, isNot(contains('communityDetailTabIndex')));
      expect(src, isNot(contains('_detailTabWidget')));
      expect(src, isNot(contains('_detailTabPage')));
      expect(src, isNot(contains('_tabs.')));
      expect(src, isNot(contains('initialTab')));
      expect(src, isNot(contains('TabController(length: 3')));
      expect(src, isNot(contains('TabController(length: 2')));
      // (The chat's own _scroll.animateTo stays — it scrolls the
      // message list, it has nothing to do with tabs.)
      expect(src, isNot(contains('_tabs.animateTo')));
      // The chat renders directly; members open as a page.
      expect(src, contains('_CommunityChatTab('));
      expect(src, contains('void _openMembers()'));
      expect(src, contains('_CommunityMembersPage('));
    });

    test('both user-facing community taps open the detail page (the chat)',
        () {
      // CommunitiesListPage row tap.
      expect(communitiesScreens, contains('CommunityDetailPage('));
      expect(communitiesScreens, isNot(contains('initialTab:')));
      // TeamsPage Community tab (_openCommunity).
      expect(proFeatures, contains('CommunityDetailPage('));
      expect(proFeatures, isNot(contains('initialTab:')));
    });

    test('squad/clan card tap pushes TeamChatPage directly', () {
      // The whole-card InkWell (not just the button) opens the
      // chat — FIX 11 behaviour, pinned.
      final teamsStart = proFeatures.indexOf('class _TeamsPageState');
      final teamsEnd = proFeatures.indexOf('class TeamDetailPage', teamsStart);
      final teamsPage = proFeatures.substring(teamsStart, teamsEnd);
      expect(
          teamsPage,
          contains(
              'onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => TeamChatPage(team: t, uid: widget.uid, navIndex: widget.embedded ? 4 : 2)))'));
    });
  });

  group('G12 — squad tap opens the chat directly (widget)', () {
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

    testWidgets('tapping the clan card name opens TeamChatPage, not detail',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
          home: TeamsPage(uid: 'test-uid', embedded: true)));
      await tester.pump();
      await _settle(tester);
      expect(find.text('Falcons'), findsOneWidget);
      // Tap the team NAME (not the 'Members & Chat' button).
      await tester.tap(find.text('Falcons'));
      await tester.pump();
      await _settle(tester);
      expect(find.byType(TeamChatPage), findsOneWidget);
      expect(find.byType(TeamDetailPage), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('G12 — community tap opens the chat directly (widget)', () {
    setUp(() {
      SupaDb.testFixtures = {
        'teams': [],
        'team_members': [],
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
        'community_posts': [],
        'chat_messages': [],
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

    testWidgets('TeamsPage Community tab: tap opens the detail chat directly',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
          home: TeamsPage(uid: 'test-uid', embedded: true)));
      await tester.pump();
      await _settle(tester);
      await tester.tap(find.text('Community'));
      await tester.pump();
      await _settle(tester);
      expect(find.text('Meri Kahani'), findsOneWidget);
      await tester.tap(find.text('Meri Kahani'));
      await tester.pump();
      await _settle(tester);
      expect(find.byType(CommunityDetailPage), findsOneWidget);
      // FIX 22: no tabs — the chat renders directly.
      expect(find.byType(TabBar), findsNothing);
      expect(find.byType(Tab), findsNothing);
      expect(find.text('Abhi koi chat nahi'), findsOneWidget);
      // FIX 23 items 1+9+12b: no top bar, no More menu — the
      // creator sees JOINED in the sidebar Follow pill
      // immediately, and the word "Members" is gone from the room.
      expect(find.text('More'), findsNothing);
      expect(find.text('JOINED'), findsOneWidget);
      expect(find.text('Members'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('G12 — CommunityDetailPage shows the chat directly (widget)', () {
    setUp(() {
      SupaDb.testFixtures = _detailFixtures();
    });
    tearDown(() {
      SupaDb.testFixtures = null;
    });

    Future<void> pumpDetail(WidgetTester tester) async {
      // Tall viewport: the always-mounted voice panel + chat
      // overflow the default 600px height (G6 pattern).
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(const MaterialApp(
        home: CommunityDetailPage(
          uid: 'u1',
          communityId: 'c1',
          community: _community,
        ),
      ));
      await tester.pump();
      await _settle(tester);
    }

    testWidgets('detail opens on the chat directly, no tabs', (tester) async {
      await pumpDetail(tester);
      expect(find.byType(CommunityDetailPage), findsOneWidget);
      expect(find.byType(TabBar), findsNothing);
      expect(find.byType(Tab), findsNothing);
      expect(find.text('Abhi koi chat nahi'), findsOneWidget);
      // FIX 23 items 1+9+12b: no top bar, no More menu — the
      // member's follow state shows as the Following pill in the
      // sidebar (no tap needed); "Unfollow" and "Members" are
      // gone from the room.
      expect(find.text('More'), findsNothing);
      expect(find.text('Following'), findsOneWidget);
      expect(find.text('Unfollow'), findsNothing);
      expect(find.text('Members'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Followers sidebar entry pushes the members page',
        (tester) async {
      await pumpDetail(tester);
      // FIX 23 item 9: the Members header button is gone — the
      // members page opens from the sidebar Followers entry.
      await tester.tap(find.text('Followers'));
      await tester.pump();
      await _settle(tester);
      // The pushed page is _CommunityMembersPage, titled
      // 'Followers' in its AppBar (no search field — the old
      // FollowListPage hint pin was wrong even for v2022).
      expect(
          find.descendant(
              of: find.byType(AppBar), matching: find.text('Followers')),
          findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}

// ---- Fake Firebase (exact pattern from device_ban_gate_test,
// copied from fix20_community_voice_test.dart; the fake signs in
// as u1, this file's page uid) ----

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
        uid: 'u1',
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
