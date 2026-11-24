// Watch Live moderation (v2013) — unit tests for the "URL set nahi
// hai" note rule and the kick rule, plus widget tests that pump the
// real WatchLiveScreen as admin (long-press mod menu) and as a
// restricted viewer (30s kick poll → exit dialog). Same fake
// Firebase / fake WebView pattern as watch_live_test.dart; no
// network, no real YouTube stream.
//
// NOTE: SharedPreferences.setMockInitialValues only seeds the FIRST
// read, so the admin_mode marker is true for the whole file and the
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
  group('watchLiveUrlNoteVisibleFor — detail note rule', () {
    test('joined + ongoing + no URL shows the note', () {
      expect(
        watchLiveUrlNoteVisibleFor(
          {'status': 'ongoing', 'watchLiveUrl': ''},
        ),
        isTrue,
      );
      expect(
        watchLiveUrlNoteVisibleFor({'status': 'ongoing'}),
        isTrue,
      );
    });
    // FIX 6 (2026-11-22, free spectating): spectating needs no
    // join, so a NON-joined viewer on a live tournament with no
    // URL sees the same honest note (was: no note at all).
    test('not joined ALSO shows the note (free spectating)', () {
      expect(
        watchLiveUrlNoteVisibleFor(
          {'status': 'ongoing', 'watchLiveUrl': ''},
        ),
        isTrue,
      );
    });
    test('upcoming tournament shows no note (not live yet)', () {
      expect(
        watchLiveUrlNoteVisibleFor(
          {'status': 'upcoming', 'watchLiveUrl': ''},
        ),
        isFalse,
      );
    });
    test('URL present shows no note (the button shows instead)', () {
      expect(
        watchLiveUrlNoteVisibleFor(
          {
            'status': 'ongoing',
            'watchLiveUrl': 'https://youtu.be/dQw4w9WgXcQ'
          },
        ),
        isFalse,
      );
    });
    test('completed tournament shows no note', () {
      expect(
        watchLiveUrlNoteVisibleFor(
          {'status': 'completed', 'watchLiveUrl': ''},
        ),
        isFalse,
      );
    });
  });

  group('shouldKickFromWatchLive — kick rule', () {
    test('restricted + logged in + not admin is kicked', () {
      expect(
        shouldKickFromWatchLive(
            loggedIn: true, isAdmin: false, isRestricted: true),
        isTrue,
      );
    });
    test('admin is never kicked', () {
      expect(
        shouldKickFromWatchLive(
            loggedIn: true, isAdmin: true, isRestricted: true),
        isFalse,
      );
    });
    test('logged-out viewer is never kicked', () {
      expect(
        shouldKickFromWatchLive(
            loggedIn: false, isAdmin: false, isRestricted: true),
        isFalse,
      );
    });
    test('not restricted is never kicked', () {
      expect(
        shouldKickFromWatchLive(
            loggedIn: true, isAdmin: false, isRestricted: false),
        isFalse,
      );
    });
  });

  group('WatchLiveScreen moderation widget', () {
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
      // Fixture chat stream + async admin-status load.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
    }

    testWidgets('admin long-press opens the mod menu with all 4 actions',
        (tester) async {
      SupaDb.testFixtures = {
        'chat_messages': chatFixture(),
        'admin_config': [
          {'id': 1, 'admin_firebase_uid': 'test-uid'},
        ],
      };
      await pumpScreen(tester);
      expect(find.text('GG! Final dekh rahe ho?'), findsOneWidget);

      await tester.longPress(find.text('GG! Final dekh rahe ho?'));
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.text('Delete message'), findsOneWidget);
      expect(find.text('Block user (comments band)'), findsOneWidget);
      expect(find.text('Kick user (live se nikaalein)'), findsOneWidget);
      expect(find.text('Ban user (login band)'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
    });

    testWidgets(
        'non-admin long-press shows no mod menu (designated UID mismatch)',
        (tester) async {
      SupaDb.testFixtures = {
        'chat_messages': chatFixture(),
        'admin_config': [
          {'id': 1, 'admin_firebase_uid': 'someone-else'},
        ],
      };
      await pumpScreen(tester);
      expect(find.text('GG! Final dekh rahe ho?'), findsOneWidget);

      await tester.longPress(find.text('GG! Final dekh rahe ho?'));
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.text('Delete message'), findsNothing);
      expect(find.text('Block user (comments band)'), findsNothing);
      expect(find.text('Kick user (live se nikaalein)'), findsNothing);
      expect(find.text('Ban user (login band)'), findsNothing);
    });

    testWidgets('restricted viewer is kicked out on the 30s poll',
        (tester) async {
      SupaDb.testFixtures = {
        'chat_messages': chatFixture(),
        'admin_config': [
          {'id': 1, 'admin_firebase_uid': 'someone-else'},
        ],
        'chat_restrictions': [
          {'firebase_uid': 'test-uid', 'reason': 'spam'},
        ],
      };
      await pumpScreen(tester);
      expect(find.text('WATCH LIVE'), findsOneWidget);

      // Advance past the 30s kick poll, then let the async
      // restriction check + dialog build.
      await tester.pump(const Duration(seconds: 31));
      await tester.pump();
      await tester.pump();

      expect(find.text('Live chat se hata diya gaya'), findsOneWidget);

      // OK pops the dialog, then the screen itself pops (each
      // transition needs its own pump time).
      await tester.tap(find.text('OK'));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      expect(find.text('WATCH LIVE'), findsNothing);
    });

    testWidgets('admin is NOT kicked even when restricted',
        (tester) async {
      SupaDb.testFixtures = {
        'chat_messages': chatFixture(),
        'admin_config': [
          {'id': 1, 'admin_firebase_uid': 'test-uid'},
        ],
        'chat_restrictions': [
          {'firebase_uid': 'test-uid', 'reason': 'spam'},
        ],
      };
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
