// FIX 31b DEFECT A — HOST-PAGE MOUNT VERIFICATION (2026-11-24).
// The verifier found the re-skinned panel grows the host page by
// ~30px (the header strip), overflowing TeamChatPage's Column by
// 30px on the bottom at heights <=720. The fix absorbs it in
// _buildCappedSidebar (reserves +36: 280->316 team, 200->236
// community). These tests mount the panel inside its REAL host
// pages — not standalone — at the sizes that failed:
//
//   * TeamChatPage at 800x600 (default viewport): no exception.
//   * TeamChatPage at 360x667 (iPhone SE height): no BOTTOM
//     overflow. The pre-existing 7px RIGHT overflow in
//     ArenaChatHeader (arena_chat.dart:340, in the item-31
//     baseline at all 360-wide sizes) is NOT this defect, so
//     this test captures FlutterErrors and asserts on the
//     DIRECTION, not on takeException().
//   * CommunityDetailPage at 800x600: the panel is sticky for
//     members; the page Column is panel + Expanded chat, so it
//     is safe by structure — this is its first mount test.
//
// Widget tests reuse the fake-Firebase pattern from
// fix16_voice_header_test.dart + SupaDb.testFixtures, and the
// DSP MethodChannel mock (the room auto-tries DSP on mount;
// without the mock the 2s timeout Timer trips postTest).
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_auth_platform_interface/firebase_auth_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/components/arena_chat.dart';
import 'package:protournament_user/screens/communities_screens.dart';
import 'package:protournament_user/screens/pro_features.dart';
import 'package:protournament_user/screens/room_screen.dart';
import 'package:protournament_user/services/supabase_db.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('FIX 31b Defect A — host-page mounts, no bottom overflow', () {
    setUpAll(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
      FirebasePlatform.instance = _FakeCorePlatform();
      FirebaseAuthPlatform.instance = _FakeAuthPlatform();
      await Firebase.initializeApp();
      // ignore: unnecessary_statements
      FirebaseAuth.instance;
      // DSP mock: isAvailable -> false (no pending 2s timer).
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('arena_hub_dsp_mic'),
              (MethodCall call) async {
                if (call.method == 'isAvailable') return false;
                return null;
              });
    });

    tearDownAll(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('arena_hub_dsp_mic'), null);
    });

    setUp(() async {
      await FirebaseAuth.instance
          .signInWithEmailAndPassword(email: 't@t.com', password: 'password');
    });

    tearDown(() async {
      SupaDb.testFixtures = null;
      await FirebaseAuth.instance.signOut();
    });

    testWidgets('TeamChatPage 800x600, panel open: no overflow at all',
        (tester) async {
      SupaDb.testFixtures = _teamFixtures(team: _team());
      await tester.pumpWidget(
          MaterialApp(home: TeamChatPage(team: _team(), uid: 'test-uid')));
      await _settle(tester);
      await tester.tap(_headerButton(tester, 'Voice'));
      await _settle(tester);
      expect(find.byType(UnifiedRoomPage), findsOneWidget);
      expect(find.text('6'), findsOneWidget,
          reason: 'mic seats are part of the mounted panel');
      // 800px wide: no pre-existing right overflow here, so a
      // plain null check is exact — Defect A was a 30px BOTTOM
      // overflow at this size before the fix.
      expect(tester.takeException(), isNull);
    });

    testWidgets('TeamChatPage 360x667, panel open: no BOTTOM overflow',
        (tester) async {
      tester.view.physicalSize = const Size(360, 667);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      // Capture every FlutterError and assert on DIRECTION: the
      // pre-existing 7px RIGHT overflow in ArenaChatHeader
      // (baseline, all 360-wide sizes) may still appear; a
      // BOTTOM overflow must not.
      final errors = <String>[];
      final prevHandler = FlutterError.onError;
      FlutterError.onError = (details) {
        errors.add(details.exceptionAsString());
      };
      addTearDown(() {
        FlutterError.onError = prevHandler;
      });
      SupaDb.testFixtures = _teamFixtures(team: _team());
      await tester.pumpWidget(
          MaterialApp(home: TeamChatPage(team: _team(), uid: 'test-uid')));
      await _settle(tester);
      await tester.tap(_headerButton(tester, 'Voice'));
      await _settle(tester);
      expect(find.byType(UnifiedRoomPage), findsOneWidget);
      expect(find.text('6'), findsOneWidget,
          reason: 'mic seats are part of the mounted panel');
      final bottom = errors
          .where((e) => e.contains('overflowed') && e.contains('on the bottom'))
          .toList();
      expect(bottom, isEmpty,
          reason: 'bottom overflow(s) at 360x667: $bottom');
    });

    testWidgets('CommunityDetailPage 800x600, panel mounted: no overflow',
        (tester) async {
      SupaDb.testFixtures =
          _communityFixtures(community: _unlockedCommunity());
      await tester.pumpWidget(MaterialApp(
        home: CommunityDetailPage(
          uid: 'test-uid',
          communityId: 'comm-1',
          community: _unlockedCommunity(),
        ),
      ));
      await _settle(tester);
      // FIX 23 item 16a: the panel is sticky for members — it
      // mounts the moment the page opens, no toggle needed.
      expect(find.byType(UnifiedRoomPage), findsOneWidget);
      expect(find.text('6'), findsOneWidget,
          reason: 'mic seats are part of the mounted panel');
      expect(tester.takeException(), isNull);
    });
  });
}

/// A header circle button's label, scoped to the header so the
/// panel's own texts can never be mistaken for it.
Finder _headerButton(WidgetTester tester, String label) =>
    find.descendant(of: find.byType(ArenaChatHeader), matching: find.text(label));

/// Pump past the fixture futures (getList/getRow/streamChat) and
/// the embedded panel's post-frame auto-join — plus the join's
/// delayed re-asserts, so no service timer is still pending at
/// test end (fix16 pattern).
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 500));
  }
}

Map<String, dynamic> _team() => {
      'id': 'team-1',
      'name': 'TEST CH',
      'is_clan': true,
      'captain_uid': 'test-uid',
      'invite_code': 'ABC123',
      // No voice flag at all: voice by default (no approval).
    };

Map<String, List<Map<String, dynamic>>> _teamFixtures(
        {required Map<String, dynamic> team}) =>
    {
      'teams': [team],
      'team_members': [
        {'team_id': team['id'], 'firebase_uid': 'test-uid', 'game_id': 'Tester'}
      ],
      'team_invitations': [],
      'profiles': [
        {'firebase_uid': 'test-uid', 'display_name': 'Tester', 'level': 1}
      ],
      // The test user IS the designated admin, so the room page
      // treats them as room admin (mic-request gate skipped).
      'admin_config': [
        {'id': 1, 'admin_firebase_uid': 'test-uid'}
      ],
      'communities': [
        {
          'id': team['id'],
          'name': team['name'],
          'created_by_uid': 'test-uid',
          'voice_enabled': team['voice_enabled'] ?? true
        }
      ],
      'community_voice_requests': [],
      'chat_messages': [],
    };

Map<String, dynamic> _unlockedCommunity() => {
      'id': 'comm-1',
      'name': 'TEST COMMUNITY',
      'description': 'Test community',
      'created_by_uid': 'test-uid',
      'voice_enabled': true,
      'isMember': true,
      'myRole': 'creator',
      'memberCount': 1,
    };

Map<String, List<Map<String, dynamic>>> _communityFixtures(
        {required Map<String, dynamic> community}) =>
    {
      'communities': [community],
      'community_members': [
        {
          'community_id': community['id'],
          'firebase_uid': 'test-uid',
          'role': 'creator',
        }
      ],
      'community_voice_requests': [],
      'profiles': [
        {
          'firebase_uid': 'test-uid',
          'display_name': 'Tester',
          'level': 1,
        }
      ],
      'admin_config': [
        {'id': 1, 'admin_firebase_uid': 'test-uid'}
      ],
      'chat_messages': [],
      'presence': [],
    };

// ---- Fake Firebase (exact pattern from fix16_voice_header_test) ----

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
              projectId: 'test'),
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
        : _FakeUser(this, _FakeMultiFactor(this), currentUser);
    return this;
  }

  @override
  UserPlatform? get currentUser => _user;

  @override
  set currentUser(UserPlatform? user) => _user = user;

  @override
  Future<UserCredentialPlatform> signInWithEmailAndPassword(
      String email, String password) async {
    final details = PigeonUserDetails(
      userInfo: PigeonUserInfo(
          uid: 'test-uid',
          email: email,
          isAnonymous: false,
          isEmailVerified: true),
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
