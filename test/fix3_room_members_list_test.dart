// FIX 3 — MEMBERS BUTTON = IN-ROOM ONLINE LIST (user order
// 2026-11-22): in the team/clan chat header, tapping Members used
// to push the My Team detail screen. Now it toggles an inline
// dropdown under the header listing the ONLINE users in THIS room
// (team members with a fresh presence heartbeat — the single
// 2-minute rule). First tap opens, second tap closes; the list
// scrolls when there are many users. My Team stays reachable via
// More -> Team settings. Tournament mode is untouched (its
// Members still shows the players dialog).
//
// Source pins (what the code says) + unit tests for the pure
// filter + widget tests (what the user sees). The widget tests
// reuse the fake-Firebase pattern from device_ban_gate_test.dart
// and the SupaDb.testFixtures pattern from
// community_tab_restructure_test.dart / v2017_voice_toggle_test.dart.
//
// HONEST LIMIT: a widget test cannot prove the presence rows are
// really fresh on the server (no network in tests) — the freshness
// rule itself is pinned by SupaDb.presenceIsOnline (unit) and the
// list renders exactly what that rule admits.
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_auth_platform_interface/firebase_auth_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/components/arena_chat.dart';
import 'package:protournament_user/screens/pro_features.dart';
import 'package:protournament_user/services/supabase_db.dart';
import 'package:protournament_user/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

String _read(String rel) => File('test/../$rel').readAsStringSync();

/// Source with full-line comments stripped, so a mention inside a
/// comment never counts as code.
String _codeOnly(String src) => src
    .split('\n')
    .where((l) => !l.trimLeft().startsWith('//'))
    .join('\n');

/// The body of a method (from its signature to the next '  }' line
/// after it) for scoped assertions.
String _method(String src, String signature) {
  final start = src.indexOf(signature);
  expect(start, isNot(-1), reason: 'method not found: $signature');
  final end = src.indexOf('\n  }\n', start);
  expect(end, isNot(-1), reason: 'method end not found: $signature');
  return src.substring(start, end);
}

void main() {
  group('fix3 — source invariants', () {
    test('Members toggles the inline list — no push, no new screen', () {
      final pro = _read('lib/screens/pro_features.dart');
      final toggle = _method(pro, 'void _toggleRoomMembers() {');
      expect(toggle, contains('final opening = !_roomMembersOpen;'));
      expect(toggle, contains('_roomMembersOpen = opening'));
      expect(toggle, contains('_loadRoomMembers()'));
      expect(toggle, isNot(contains('Navigator.push')));
      expect(toggle, isNot(contains('TeamDetailPage')));
      // Wiring: team mode toggles, tournament mode keeps players.
      expect(pro, contains('onMembers: _isTournament ? _showPlayers : _toggleRoomMembers,'));
      expect(pro, contains('membersActive: _roomMembersOpen,'));
      // Panel sits under the header, above the messages.
      expect(pro, contains('if (_roomMembersOpen && !_isTournament) _roomMembersPanel(),'));
      // The panel is a capped, scrollable list — never a push.
      final panel = _method(pro, 'Widget _roomMembersPanel() {');
      expect(panel, contains('onlineRoomMembers('));
      expect(panel, contains('BoxConstraints(maxHeight: 320)'));
      expect(panel, contains('ListView.builder('));
      expect(panel, isNot(contains('Navigator.push')));
    });

    test('My Team stays reachable via More -> Team settings', () {
      final pro = _read('lib/screens/pro_features.dart');
      expect(pro, contains("ArenaChatMenuItem('team', 'Team settings')"));
      final open = _method(pro, 'void _openMembers() {');
      expect(open, contains('TeamDetailPage(team: widget.team'));
    });

    test('header Members button shows its active state', () {
      final chat = _read('lib/components/arena_chat.dart');
      expect(chat, contains('final bool membersActive;'));
      expect(chat, contains('selected: membersActive'));
    });

    test('presence/profile reads honor testFixtures (seam for tests)', () {
      final db = _codeOnly(_read('lib/services/supabase_db.dart'));
      expect(db, contains('static Future<Map<String, Map<String, dynamic>>> getPresenceMap'));
      expect(db, contains("for (final r in _fixtureRows('presence'))"));
      expect(db, contains("for (final r in _fixtureRows('profiles'))"));
    });
  });

  group('fix3 — onlineRoomMembers (pure filter)', () {
    Map<String, dynamic> member(String uid, [String name = '']) =>
        {'firebase_uid': uid, if (name.isNotEmpty) 'user_name': name};
    Map<String, dynamic> fresh() => {'last_seen': DateTime.now().toIso8601String()};
    Map<String, dynamic> stale() =>
        {'last_seen': DateTime.now().subtract(const Duration(minutes: 5)).toIso8601String()};

    test('online members only — offline, ghost and stranger excluded', () {
      final out = onlineRoomMembers(
        members: [member('a', 'Ana'), member('b', 'Bob'), member('c', 'Ghost')],
        presence: {'a': fresh(), 'b': stale(), 'stranger': fresh()},
        profiles: {},
      );
      expect(out.map((e) => e.uid), ['a']);
      expect(out.first.name, 'Ana');
    });

    test('name fallback: user_name > display_name > username > Player', () {
      final out = onlineRoomMembers(
        members: [member('a'), member('b'), member('c'), member('d', 'Dee')],
        presence: {'a': fresh(), 'b': fresh(), 'c': fresh(), 'd': fresh()},
        profiles: {
          'a': {'display_name': 'A-Prof', 'username': 'a_user'},
          'b': {'username': 'b_user'},
          'c': {},
        },
      );
      expect(out.map((e) => e.name), ['A-Prof', 'b_user', 'Player', 'Dee']);
    });

    test('photoUrl passes through; empty uid skipped', () {
      final out = onlineRoomMembers(
        members: [
          {'firebase_uid': '', 'user_name': 'NoUid'},
          member('a', 'Ana'),
        ],
        presence: {'a': fresh()},
        profiles: {
          'a': {'photo_url': 'https://x/y.png'}
        },
      );
      expect(out.length, 1);
      expect(out.first.photoUrl, 'https://x/y.png');
    });

    test('getPresenceMap/getProfilesMap read fixtures', () async {
      SupaDb.testFixtures = {
        'presence': [
          {'firebase_uid': 'u1', 'last_seen': DateTime.now().toIso8601String()},
          {'firebase_uid': 'u9', 'last_seen': DateTime.now().toIso8601String()},
        ],
        'profiles': [
          {'firebase_uid': 'u1', 'display_name': 'One'},
          {'firebase_uid': 'u9', 'display_name': 'Nine'},
        ],
      };
      try {
        final presence = await SupaDb.getPresenceMap(['u1', 'u2']);
        expect(presence.keys, ['u1']);
        final profiles = await SupaDb.getProfilesMap(['u1']);
        expect(profiles['u1']?['display_name'], 'One');
      } finally {
        SupaDb.testFixtures = null;
      }
    });
  });

  // ------------------------------------------------------------------
  // Widget tests: fake Firebase + SupaDb.testFixtures.
  // ------------------------------------------------------------------
  group('fix3 — widget: Members dropdown', () {
    setUpAll(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
      FirebasePlatform.instance = _FakeCorePlatform();
      FirebaseAuthPlatform.instance = _FakeAuthPlatform();
      await Firebase.initializeApp();
      // ignore: unnecessary_statements
      FirebaseAuth.instance;
    });

    setUp(() async {
      await FirebaseAuth.instance.signInWithEmailAndPassword(
          email: 't@t.com', password: 'password');
      SupaDb.testFixtures = _fixtures();
    });

    tearDown(() async {
      SupaDb.testFixtures = null;
      await FirebaseAuth.instance.signOut();
    });

    Finder membersButton() => find.descendant(
          of: find.byType(ArenaChatHeader),
          matching: find.text('Members'),
        );

    Finder panel() => find.byKey(const Key('room_members_panel'));

    Future<void> pumpChat(WidgetTester tester) async {
      await tester.pumpWidget(MaterialApp(
        home: TeamChatPage(team: _clanTeam(), uid: 'test-uid'),
      ));
      await _settle(tester);
    }

    testWidgets('tap Members -> online list opens; offline/ghost absent; no My Team screen',
        (tester) async {
      await pumpChat(tester);
      expect(panel(), findsNothing);
      expect(find.byType(TeamDetailPage), findsNothing);

      await tester.tap(membersButton());
      await _settle(tester);

      // The inline panel is on the SAME screen (composer still
      // there, no TeamDetailPage pushed).
      expect(panel(), findsOneWidget);
      expect(find.text('Type a message...'), findsOneWidget);
      expect(find.byType(TeamDetailPage), findsNothing);
      expect(find.text('EDIT TEAM'), findsNothing);
      // Title + count: 2 online (Tester + Ana).
      expect(find.text('ONLINE IN ROOM'), findsOneWidget);
      expect(find.text('(2)'), findsOneWidget);
      // Online members shown; offline Bob + ghost (no presence
      // row) + the non-member stranger never appear.
      expect(find.text('Tester'), findsOneWidget);
      expect(find.text('Ana'), findsOneWidget);
      expect(find.text('Bob'), findsNothing);
      expect(find.text('Ghost'), findsNothing);
      expect(find.text('Stranger'), findsNothing);
      // Each shown row carries a green Online label.
      expect(
        find.descendant(of: panel(), matching: find.text('Online')),
        findsNWidgets(2),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('second Members tap closes the list', (tester) async {
      await pumpChat(tester);
      await tester.tap(membersButton());
      await _settle(tester);
      expect(panel(), findsOneWidget);
      expect(find.text('Ana'), findsOneWidget);

      await tester.tap(membersButton());
      await _settle(tester);
      expect(panel(), findsNothing);
      expect(find.text('Ana'), findsNothing);
      expect(find.byType(TeamDetailPage), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('header Members label is gold while the list is open', (tester) async {
      await pumpChat(tester);
      await tester.tap(membersButton());
      await _settle(tester);
      final active = tester.widget<Text>(membersButton());
      expect(active.style?.color, kGold);
      expect(active.style?.fontWeight, FontWeight.w800);

      await tester.tap(membersButton());
      await _settle(tester);
      final inactive = tester.widget<Text>(membersButton());
      expect(inactive.style?.color, kText);
      expect(inactive.style?.fontWeight, isNot(FontWeight.w800));
    });

    testWidgets('nobody online -> honest empty state, no crash', (tester) async {
      SupaDb.testFixtures = _fixtures(allOffline: true);
      await pumpChat(tester);
      await tester.tap(membersButton());
      await _settle(tester);
      expect(panel(), findsOneWidget);
      expect(find.text('Abhi koi member online nahi hai.'), findsOneWidget);
      expect(find.text('(0)'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('many users -> list scrolls up/down inside the capped panel',
        (tester) async {
      SupaDb.testFixtures = _fixtures(many: true);
      await pumpChat(tester);
      await tester.tap(membersButton());
      await _settle(tester);
      expect(panel(), findsOneWidget);
      expect(find.text('(12)'), findsOneWidget);
      // The panel's list is a real ListView (scrollable), and the
      // last member is NOT built until scrolled to (capped height).
      expect(
        find.descendant(of: panel(), matching: find.byType(ListView)),
        findsOneWidget,
      );
      expect(find.text('Member 12'), findsNothing);
      final panelScrollable =
          find.descendant(of: panel(), matching: find.byType(Scrollable));
      await tester.scrollUntilVisible(find.text('Member 12'), 100,
          scrollable: panelScrollable);
      expect(find.text('Member 12'), findsOneWidget);
      // And back up again.
      await tester.scrollUntilVisible(find.text('Tester'), -100,
          scrollable: panelScrollable);
      expect(find.text('Tester'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}

Map<String, dynamic> _clanTeam() => {
      'id': 'team-1',
      'name': 'TEST CH',
      'is_clan': true,
      'captain_uid': 'test-uid',
      'invite_code': 'ABC123',
    };

Map<String, List<Map<String, dynamic>>> _fixtures(
    {bool allOffline = false, bool many = false}) {
  final now = DateTime.now();
  final freshTs = now.toIso8601String();
  final staleTs = now.subtract(const Duration(minutes: 5)).toIso8601String();
  final members = <Map<String, dynamic>>[];
  final presence = <Map<String, dynamic>>[];
  final profiles = <Map<String, dynamic>>[];

  void addMember(String uid, String name, {required bool online, String? profileName}) {
    members.add({'team_id': 'team-1', 'firebase_uid': uid, 'user_name': name});
    if (online) {
      presence.add({'firebase_uid': uid, 'last_seen': allOffline ? staleTs : freshTs});
    } else {
      presence.add({'firebase_uid': uid, 'last_seen': staleTs});
    }
    profiles.add({
      'firebase_uid': uid,
      'display_name': profileName ?? name,
      'photo_url': '',
      'level': 1,
    });
  }

  if (many) {
    addMember('test-uid', 'Tester', online: true);
    for (var i = 2; i <= 12; i++) {
      addMember('uid-m$i', 'Member $i', online: true);
    }
  } else {
    addMember('test-uid', 'Tester', online: true);
    // Profile name differs on purpose: the list must show the
    // team_members user_name ('Ana'), not the profile name.
    addMember('uid-ana', 'Ana', online: true, profileName: 'Ana P');
    addMember('uid-bob', 'Bob', online: false);
    // Ghost: a member with NO presence row at all.
    members.add({'team_id': 'team-1', 'firebase_uid': 'uid-ghost', 'user_name': 'Ghost'});
    profiles.add({'firebase_uid': 'uid-ghost', 'display_name': 'Ghost', 'photo_url': ''});
    // Stranger: online presence, but NOT a team member.
    presence.add({'firebase_uid': 'uid-stranger', 'last_seen': freshTs});
    profiles.add({'firebase_uid': 'uid-stranger', 'display_name': 'Stranger', 'photo_url': ''});
  }

  return {
    'teams': [_clanTeam()],
    'team_members': members,
    'team_invitations': [],
    'profiles': profiles,
    'presence': presence,
    'admin_config': [
      {'id': 1, 'admin_firebase_uid': 'test-uid'}
    ],
    'communities': [
      {
        'id': 'team-1',
        'name': 'TEST CH',
        'created_by_uid': 'test-uid',
        'voice_enabled': true,
      }
    ],
    'community_voice_requests': [],
    'chat_messages': [],
  };
}

/// Pump past the fixture futures (getList/getRow/streamChat +
/// the dropdown's presence/profile reads).
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}

// ---- Fake Firebase (exact pattern from device_ban_gate_test) ----

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
