// FIX 5 (2026-11-22) — Watch Live moderator.
//
// Sameer's decision: moderator banne ke liye KOI REQUEST NAHI —
// admin khud apni marzi se kisi ko bhi moderator bana sakta hai
// (separate admin APK → Roles), aur wo moderator live chat ka
// saara moderation sambhal sakta hai (delete / block / kick / ban).
//
// Covers: moderator gets the long-press mod menu, ordinary user
// does not, designated admin still does, role-read failure =
// no menu (fail closed), moderator is never kicked, and no
// request/apply flow exists anywhere.
//
// Widget tests pump the real WatchLiveScreen with the same fake
// Firebase / fake WebView pattern as
// watch_live_moderation_test.dart; no network, no real stream.
// NOTE: SharedPreferences.setMockInitialValues only seeds the
// FIRST read, so admin_mode is true for the whole file and the
// non-admin cases are built by making the designated-admin UID
// mismatch instead (marker set + wrong UID = not admin).
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_auth_platform_interface/firebase_auth_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/screens/watch_live_screen.dart';
import 'package:protournament_user/services/supabase_db.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

String _read(String rel) => File('test/../$rel').readAsStringSync();

// ---------- fake Firebase (copied pattern from watch_live_test.dart) ----------

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

class _FakeAuthPlatform extends FirebaseAuthPlatform {
  _FakeAuthPlatform({super.appInstance});

  UserPlatform? _user;

  @override
  FirebaseAuthPlatform delegateFor({required FirebaseApp app}) =>
      _FakeAuthPlatform(appInstance: app);

  @override
  FirebaseAuthPlatform setInitialValues(
      {PigeonUserDetails? currentUser, String? languageCode}) {
    final uid = currentUser?.userInfo.uid ?? 'test-uid';
    _user = _FakeUser(
      this,
      _FakeMultiFactor(this),
      PigeonUserDetails(
          userInfo: PigeonUserInfo(
              uid: uid, isAnonymous: false, isEmailVerified: true),
          providerData: []),
    );
    return this;
  }

  @override
  UserPlatform? get currentUser => _user;

  @override
  set currentUser(UserPlatform? user) => _user = user;
}

// ---------- fake WebView platform (copied from watch_live_test.dart) ----------

class _FakeWebViewPlatform extends WebViewPlatform {
  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) =>
      _FakeWebViewController.implementation(params);

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
    PlatformNavigationDelegateCreationParams params,
  ) =>
      _FakeNavigationDelegate.implementation(params);

  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
    PlatformWebViewWidgetCreationParams params,
  ) =>
      _FakeWebViewWidget.implementation(params);
}

class _FakeWebViewController extends PlatformWebViewController {
  _FakeWebViewController.implementation(super.params)
      : super.implementation();

  @override
  Future<void> loadRequest(LoadRequestParams params) async {}

  // FIX 9: the screen now also sets a Chrome UA, registers the
  // PlayerError channel and loads the IFrame wrapper via
  // loadHtmlString — the platform defaults throw, so the fake
  // must swallow them.
  @override
  Future<void> setUserAgent(String? userAgent) async {}

  @override
  Future<void> addJavaScriptChannel(
      JavaScriptChannelParams params) async {}

  @override
  Future<void> loadHtmlString(String html, {String? baseUrl}) async {}

  @override
  Future<void> setJavaScriptMode(JavaScriptMode javaScriptMode) async {}

  @override
  Future<void> setBackgroundColor(Color color) async {}

  @override
  Future<void> setPlatformNavigationDelegate(
    PlatformNavigationDelegate handler,
  ) async {}
}

class _FakeNavigationDelegate extends PlatformNavigationDelegate {
  _FakeNavigationDelegate.implementation(super.params)
      : super.implementation();

  @override
  Future<void> setOnNavigationRequest(
    NavigationRequestCallback onNavigationRequest,
  ) async {}

  @override
  Future<void> setOnPageFinished(PageEventCallback onPageFinished) async {}

  @override
  Future<void> setOnWebResourceError(
    WebResourceErrorCallback onWebResourceError,
  ) async {}
}

class _FakeWebViewWidget extends PlatformWebViewWidget {
  _FakeWebViewWidget.implementation(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) => const ColoredBox(color: Colors.black);
}

void main() {
  group('SupaDb.parseAdminRoleResult — RPC payload parsing', () {
    test('bare String role passes through', () {
      expect(SupaDb.parseAdminRoleResult('moderator'), 'moderator');
    });
    test('Map with role key', () {
      expect(
        SupaDb.parseAdminRoleResult({'role': 'moderator'}),
        'moderator',
      );
    });
    test('Map with admin_role key', () {
      expect(
        SupaDb.parseAdminRoleResult({'admin_role': 'tournament_manager'}),
        'tournament_manager',
      );
    });
    test('null payload -> null (fail closed)', () {
      expect(SupaDb.parseAdminRoleResult(null), isNull);
    });
    test('empty String -> null', () {
      expect(SupaDb.parseAdminRoleResult(''), isNull);
    });
    test('empty Map -> null', () {
      expect(SupaDb.parseAdminRoleResult(<String, dynamic>{}), isNull);
    });
  });

  group('shouldKickFromWatchLive — moderator never kicked', () {
    test('moderator restricted + logged in is NOT kicked', () {
      expect(
        shouldKickFromWatchLive(
          loggedIn: true,
          isAdmin: false,
          isRestricted: true,
          isModerator: true,
        ),
        isFalse,
      );
    });
    test('moderator + admin flags both true is NOT kicked', () {
      expect(
        shouldKickFromWatchLive(
          loggedIn: true,
          isAdmin: true,
          isRestricted: true,
          isModerator: true,
        ),
        isFalse,
      );
    });
    test('default (no isModerator arg) keeps the old rule', () {
      expect(
        shouldKickFromWatchLive(
            loggedIn: true, isAdmin: false, isRestricted: true),
        isTrue,
      );
      expect(
        shouldKickFromWatchLive(
            loggedIn: true, isAdmin: true, isRestricted: true),
        isFalse,
      );
    });
  });

  group('FIX 5 source pins — appointment path + gates', () {
    // FIX 32 (2026-11-24): the Roles page is gone with the panel —
    // the appointment path now lives in the separate admin APK.
    // This test keeps pinning the user-app side: no request/apply
    // flow for moderator anywhere in Watch Live.
    test('NO request/apply flow for moderator anywhere', () {
      final watch = _read('lib/screens/watch_live_screen.dart');
      for (final banned in [
        'Request Moderator',
        'request_moderator',
        'requestModerator',
        'Apply for Moderator',
        'apply_for_moderator',
        'Moderator Request',
      ]) {
        expect(watch, isNot(contains(banned)), reason: banned);
      }
    });
    test('long-press menu is gated on _canModerate (admin OR moderator)',
        () {
      final src = _read('lib/screens/watch_live_screen.dart');
      expect(
        src,
        contains('bool get _canModerate => _isAdmin || _isModerator;'),
      );
      expect(src, contains('onLongPress: _canModerate'));
      expect(src, contains('bool _isModerator = false;'));
    });
    test('_loadAdminStatus reads the role and checks moderator', () {
      final src = _read('lib/screens/watch_live_screen.dart');
      expect(src, contains('SupaDb.myAdminRole()'));
      expect(src, contains("isModerator = role == 'moderator'"));
    });
    test('kick check skips moderators and passes the flag through', () {
      final src = _read('lib/screens/watch_live_screen.dart');
      expect(src, contains('if (_kickedOut || _isAdmin || _isModerator)'));
      expect(src, contains('isModerator: _isModerator,'));
      expect(src, contains('bool isModerator = false,'));
    });
    test('SupaDb.myAdminRole exists and is fail-closed', () {
      final src = _read('lib/services/supabase_db.dart');
      expect(src, contains('static Future<String?> myAdminRole()'));
      expect(src, contains("client.rpc('admin_role')"));
      expect(src, contains("getRow('admin_users', 'firebase_uid', uid)"));
    });
  });

  group('WatchLiveScreen moderator widget', () {
    setUpAll(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      // FIX 17: load the real Roboto so the 360px fit test
      // measures what a real phone measures — the fallback
      // test font is ~2x wider and fakes an overflow
      // (same approach as fix22_watch_engagement_test.dart).
      await _loadRoboto();
      WebViewPlatform.instance = _FakeWebViewPlatform();
      FirebasePlatform.instance = _FakeCorePlatform();
      FirebaseAuthPlatform.instance = _FakeAuthPlatform();
      SharedPreferences.setMockInitialValues({'admin_mode': true});
      await Firebase.initializeApp(
        options: const FirebaseOptions(
            apiKey: 'test',
            appId: '1:1:android:1',
            messagingSenderId: '1',
            projectId: 'test'),
      );
    });

    tearDown(() {
      SupaDb.testFixtures = null;
    });

    List<Map<String, dynamic>> chatFixture() => [
          {
            'id': 'c1',
            'scope': 'watch_live',
            'tournament_id': 't1',
            'firebase_uid': 'u1',
            'display_name': 'Areeba',
            'message': 'GG! Final dekh rahe ho?',
            'created_at': '2026-11-21T10:00:00Z',
          },
          {
            'id': 'c2',
            'scope': 'watch_live',
            'tournament_id': 't1',
            'firebase_uid': 'u2',
            'display_name': 'Bilal',
            'message': 'Last circle — jeet pakki!',
            'created_at': '2026-11-21T10:01:00Z',
          },
        ];

    /// Fixtures for a viewer who is NOT the designated admin
    /// (admin_config points at someone else). Extra tables (e.g.
    /// admin_users, chat_restrictions) merge in via [extra].
    Map<String, List<Map<String, dynamic>>> notAdminFixtures({
      Map<String, List<Map<String, dynamic>>> extra = const {},
    }) =>
        {
          'chat_messages': chatFixture(),
          'admin_config': [
            {'id': 1, 'admin_firebase_uid': 'someone-else'},
          ],
          ...extra,
        };

    Future<void> pumpScreen(WidgetTester tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        const MaterialApp(
          home: WatchLiveScreen(
            tournamentId: 't1',
            tournamentName: 'Grand Final',
            watchUrl: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
          ),
        ),
      );
      // Fixture chat stream + async admin-status load (designated
      // UID check, then the role read).
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
    }

    Future<void> longPressFirstMessage(WidgetTester tester) async {
      expect(find.text('GG! Final dekh rahe ho?'), findsOneWidget);
      await tester.longPress(find.text('GG! Final dekh rahe ho?'));
      await tester.pump(const Duration(milliseconds: 500));
    }

    void expectModMenuVisible() {
      expect(find.text('Delete message'), findsOneWidget);
      expect(find.text('Block user (comments band)'), findsOneWidget);
      expect(find.text('Kick user (live se nikaalein)'), findsOneWidget);
      expect(find.text('Ban user (login band)'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
    }

    void expectModMenuHidden() {
      expect(find.text('Delete message'), findsNothing);
      expect(find.text('Block user (comments band)'), findsNothing);
      expect(find.text('Kick user (live se nikaalein)'), findsNothing);
      expect(find.text('Ban user (login band)'), findsNothing);
    }

    test('myAdminRole reads the moderator row from fixtures', () async {
      SupaDb.testFixtures = {
        'admin_users': [
          {'firebase_uid': 'test-uid', 'role': 'moderator'},
        ],
      };
      // Supabase is uninitialized in tests, so the RPC attempt
      // throws and the fallback row read is what answers.
      expect(await SupaDb.myAdminRole(), 'moderator');
    });

    test('myAdminRole returns null with no row (fail closed)', () async {
      SupaDb.testFixtures = {'admin_users': <Map<String, dynamic>>[]};
      expect(await SupaDb.myAdminRole(), isNull);
    });

    test('myAdminRole returns the stored role for other roles', () async {
      SupaDb.testFixtures = {
        'admin_users': [
          {'firebase_uid': 'test-uid', 'role': 'finance_admin'},
        ],
      };
      expect(await SupaDb.myAdminRole(), 'finance_admin');
    });

    test('myAdminRole ignores rows for other UIDs', () async {
      SupaDb.testFixtures = {
        'admin_users': [
          {'firebase_uid': 'someone-else', 'role': 'moderator'},
        ],
      };
      expect(await SupaDb.myAdminRole(), isNull);
    });

    testWidgets('moderator long-press opens the mod menu (all 4 actions)',
        (tester) async {
      SupaDb.testFixtures = notAdminFixtures(extra: {
        'admin_users': [
          {'firebase_uid': 'test-uid', 'role': 'moderator'},
        ],
      });
      await pumpScreen(tester);
      await longPressFirstMessage(tester);
      expectModMenuVisible();
    });

    testWidgets('ordinary user long-press shows no mod menu',
        (tester) async {
      SupaDb.testFixtures = notAdminFixtures();
      await pumpScreen(tester);
      await longPressFirstMessage(tester);
      expectModMenuHidden();
    });

    testWidgets('designated admin still gets the mod menu',
        (tester) async {
      SupaDb.testFixtures = {
        'chat_messages': chatFixture(),
        'admin_config': [
          {'id': 1, 'admin_firebase_uid': 'test-uid'},
        ],
      };
      await pumpScreen(tester);
      await longPressFirstMessage(tester);
      expectModMenuVisible();
    });

    testWidgets('other admin roles do NOT get the mod menu',
        (tester) async {
      SupaDb.testFixtures = notAdminFixtures(extra: {
        'admin_users': [
          {'firebase_uid': 'test-uid', 'role': 'finance_admin'},
        ],
      });
      await pumpScreen(tester);
      await longPressFirstMessage(tester);
      expectModMenuHidden();
    });

    testWidgets('moderator row for another UID does NOT open the menu',
        (tester) async {
      SupaDb.testFixtures = notAdminFixtures(extra: {
        'admin_users': [
          {'firebase_uid': 'someone-else', 'role': 'moderator'},
        ],
      });
      await pumpScreen(tester);
      await longPressFirstMessage(tester);
      expectModMenuHidden();
    });

    testWidgets('moderator is NOT kicked even when restricted',
        (tester) async {
      SupaDb.testFixtures = notAdminFixtures(extra: {
        'admin_users': [
          {'firebase_uid': 'test-uid', 'role': 'moderator'},
        ],
        'chat_restrictions': [
          {'firebase_uid': 'test-uid', 'reason': 'spam'},
        ],
      });
      await pumpScreen(tester);
      expect(find.text('WATCH LIVE'), findsOneWidget);

      await tester.pump(const Duration(seconds: 31));
      await tester.pump();
      await tester.pump();

      expect(find.text('Live chat se hata diya gaya'), findsNothing);
      expect(find.text('WATCH LIVE'), findsOneWidget);
    });
  });
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
