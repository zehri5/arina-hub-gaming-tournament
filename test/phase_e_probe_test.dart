// TEMPORARY PROBE (Phase E E15/E16/E17 diagnosis) — DELETE after use.
// Mounts CommunityDetailPage unlocked at 360x800 (fix72 pattern) and
// PRINTS geometry: host-card top, seat rects, sidebar bottom vs chat
// top, composer position; taps Music + RJ Panel and prints what opens.
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_auth_platform_interface/firebase_auth_platform_interface.dart';
import 'package:firebase_core/firebase_core.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/components/arena_chat.dart';
import 'package:protournament_user/screens/communities_screens.dart';
import 'package:protournament_user/screens/room_screen.dart';
import 'package:protournament_user/services/supabase_db.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 500));
  }
}

void main() {
  group('PROBE', () {
    setUpAll(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
      await _loadRoboto();
      FirebasePlatform.instance = _FakeCorePlatform();
      FirebaseAuthPlatform.instance = _FakeAuthPlatform();
      await Firebase.initializeApp();
      // ignore: unnecessary_statements
      FirebaseAuth.instance;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('arena_hub_dsp_mic'),
              (MethodCall call) async {
                if (call.method == 'isAvailable') return false;
                return null;
              });
    });

    setUp(() async {
      await FirebaseAuth.instance
          .signInWithEmailAndPassword(email: 't@t.com', password: 'password');
    });

    tearDown(() async {
      SupaDb.testFixtures = null;
      await FirebaseAuth.instance.signOut();
    });

    Future<void> mount(WidgetTester tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
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
    }

    testWidgets('geometry 360x800', (tester) async {
      await mount(tester);
      // ignore: avoid_print
      print('PROBE host Host-text top: ${tester.getTopLeft(find.text('Host')).dy}');
      // ignore: avoid_print
      print('PROBE panel bottom: ${tester.getBottomLeft(find.byType(UnifiedRoomPage)).dy}');
      final grid = find.byType(GridView);
      // ignore: avoid_print
      print('PROBE grid: count=${grid.evaluate().length} ${grid.evaluate().isEmpty ? '' : 'top=${tester.getTopLeft(grid).dy} bottom=${tester.getBottomLeft(grid).dy} height=${tester.getSize(grid).height}'}');
      for (final s in ['1', '2', '3', '4', '5', '6']) {
        final f = find.descendant(of: grid, matching: find.text(s));
        // ignore: avoid_print
        print('PROBE seat $s: count=${f.evaluate().length} ${f.evaluate().isEmpty ? '' : 'top=${tester.getTopLeft(f).dy} bottom=${tester.getBottomLeft(f).dy}'}');
      }
      // Podium card = the ClipRRect ancestor of the grid.
      final card = find.ancestor(of: grid, matching: find.byType(ClipRRect)).first;
      // ignore: avoid_print
      print('PROBE podium card: top=${tester.getTopLeft(card).dy} bottom=${tester.getBottomLeft(card).dy}');
      for (final label in ['Followers', 'Music', 'RJ Panel', 'Settings', 'Power', 'Leave Room']) {
        final f = find.text(label);
        // ignore: avoid_print
        print('PROBE sidebar $label: count=${f.evaluate().length} ${f.evaluate().isEmpty ? '' : 'top=${tester.getTopLeft(f).dy} bottom=${tester.getBottomLeft(f).dy}'}');
      }
      // ignore: avoid_print
      print('PROBE composer bottom: ${tester.getBottomRight(find.byType(ArenaChatInputBar)).dy}');
      // ignore: avoid_print
      print('PROBE exception: ${tester.takeException()}');
    });

    testWidgets('tap Music', (tester) async {
      await mount(tester);
      await tester.tap(find.text('Music'));
      await _settle(tester);
      // ignore: avoid_print
      print('PROBE after Music tap: exception=${tester.takeException()}');
      // ignore: avoid_print
      print('PROBE BottomSheet present: ${find.byType(BottomSheet).evaluate().length}');
      // ignore: avoid_print
      print('PROBE texts: ${find.text('MUSIC').evaluate().length} ${find.text('Music Player').evaluate().length} ${find.text('RJ STUDIO').evaluate().length}');
    });

    testWidgets('tap RJ Panel', (tester) async {
      await mount(tester);
      await tester.tap(find.text('RJ Panel'));
      await _settle(tester);
      // ignore: avoid_print
      print('PROBE after RJ tap: exception=${tester.takeException()}');
      // ignore: avoid_print
      print('PROBE BottomSheet present: ${find.byType(BottomSheet).evaluate().length}');
    });
  });
}
