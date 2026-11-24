// Watch Live (2026-11-21) — unit tests for the embed-URL builder, the
// video-id parser and the entry-button visibility rule, plus a widget
// test that pumps the real WatchLiveScreen with fixture comments
// (SupaDb.testFixtures seam + fake Firebase Auth, same pattern as
// home_empty_fix_test.dart). No network, no real YouTube stream.
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
// ignore: depend_on_referenced_packages
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

// ---------- fake Firebase (copied pattern from home_empty_fix_test.dart) ----------

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

// ---------- fake WebView platform ----------
// `flutter test` ships no WebView implementation
// (WebViewPlatform.instance is null), so pumping WatchLiveScreen
// throws without one. This fake records the URL the screen asks to
// load — the test asserts it is the low-quality embed URL — and
// renders a plain black box instead of a real web view.
class _FakeWebViewPlatform extends WebViewPlatform {
  static String? lastLoadedUrl;
  static String? lastLoadedHtml;

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
  Future<void> loadRequest(LoadRequestParams params) async {
    _FakeWebViewPlatform.lastLoadedUrl = params.uri.toString();
  }

  @override
  Future<void> loadHtmlString(String html, {String? baseUrl}) async {
    _FakeWebViewPlatform.lastLoadedHtml = html;
  }

  @override
  Future<void> setUserAgent(String? userAgent) async {}

  @override
  Future<void> addJavaScriptChannel(
      JavaScriptChannelParams params) async {}

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
  Widget build(BuildContext context) =>
      const ColoredBox(color: Colors.black);
}

void main() {
  group('extractYouTubeVideoId', () {
    test('watch URL', () {
      expect(
          extractYouTubeVideoId(
              'https://www.youtube.com/watch?v=dQw4w9WgXcQ'),
          'dQw4w9WgXcQ');
    });
    test('watch URL with extra params keeps only the id', () {
      expect(
          extractYouTubeVideoId(
              'https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42s&list=PLx'),
          'dQw4w9WgXcQ');
    });
    test('youtu.be short link', () {
      expect(extractYouTubeVideoId('https://youtu.be/dQw4w9WgXcQ'),
          'dQw4w9WgXcQ');
    });
    test('embed / shorts / live URLs with an id', () {
      expect(
          extractYouTubeVideoId(
              'https://www.youtube.com/embed/dQw4w9WgXcQ'),
          'dQw4w9WgXcQ');
      expect(
          extractYouTubeVideoId(
              'https://www.youtube.com/shorts/dQw4w9WgXcQ'),
          'dQw4w9WgXcQ');
      expect(
          extractYouTubeVideoId(
              'https://www.youtube.com/live/dQw4w9WgXcQ'),
          'dQw4w9WgXcQ');
    });
    test('channel live URL carries no video id', () {
      expect(
          extractYouTubeVideoId(
              'https://www.youtube.com/@ArenaHub/live'),
          isNull);
      expect(
          extractYouTubeVideoId(
              'https://www.youtube.com/channel/UC1234567890/live'),
          isNull);
      expect(
          extractYouTubeVideoId('https://www.youtube.com/c/ArenaHub/live'),
          isNull);
    });
    test('non-YouTube URL is not a video id', () {
      expect(extractYouTubeVideoId('https://example.com/live/abc'),
          isNull);
      expect(extractYouTubeVideoId(''), isNull);
    });
  });

  group('buildYouTubeEmbedUrl / watchLiveLoadUrl', () {
    test('embed URL starts low quality for slow 4G and autoplays', () {
      final url = buildYouTubeEmbedUrl('dQw4w9WgXcQ');
      expect(url,
          'https://www.youtube.com/embed/dQw4w9WgXcQ?autoplay=1&vq=small&rel=0&modestbranding=1&playsinline=1&iv_load_policy=3');
      expect(url, contains('vq=small'));
      expect(url, contains('autoplay=1'));
    });
    test('video URL loads through the embed', () {
      expect(watchLiveLoadUrl('https://youtu.be/dQw4w9WgXcQ'),
          contains('/embed/dQw4w9WgXcQ?'));
    });
    test('channel live URL loads directly, not through the embed', () {
      const channelLive = 'https://www.youtube.com/@ArenaHub/live';
      expect(watchLiveLoadUrl(channelLive), channelLive);
    });
  });

  group('watchLiveVisibleFor — entry-button rule', () {
    test('no URL means hidden, even with the toggle on', () {
      expect(
          watchLiveVisibleFor(
              {'showWatchLive': true, 'watchLiveUrl': ''}),
          isFalse);
      expect(watchLiveVisibleFor({'watchLiveUrl': ''}), isFalse);
    });
    test('toggle false hides the button even with a URL', () {
      expect(
          watchLiveVisibleFor({
            'showWatchLive': false,
            'watchLiveUrl': 'https://youtu.be/dQw4w9WgXcQ'
          }),
          isFalse);
      expect(
          watchLiveVisibleFor({
            'show_watch_live': false,
            'watch_live_url': 'https://youtu.be/dQw4w9WgXcQ'
          }),
          isFalse);
    });
    test('toggle true + URL shows the button', () {
      expect(
          watchLiveVisibleFor({
            'showWatchLive': true,
            'watchLiveUrl': 'https://youtu.be/dQw4w9WgXcQ'
          }),
          isTrue);
    });
    test('no toggle column yet: URL present falls back to visible', () {
      expect(
          watchLiveVisibleFor(
              {'watchLiveUrl': 'https://youtu.be/dQw4w9WgXcQ'}),
          isTrue);
    });
    test('watchLiveUrlOf accepts all spellings', () {
      expect(
          watchLiveUrlOf({'watch_live_url': 'https://youtu.be/abc'}),
          'https://youtu.be/abc');
      expect(watchLiveUrlOf({'live_url': 'https://youtu.be/abc'}),
          'https://youtu.be/abc');
      expect(watchLiveUrlOf({}), '');
    });
  });

  group('WatchLiveScreen widget', () {
    setUpAll(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      // FIX 17 (gate): real Roboto — the fallback test font fakes a
      // 91px overflow on WatchLiveScreen (see _loadRoboto below).
      await _loadRoboto();
      WebViewPlatform.instance = _FakeWebViewPlatform();
      FirebasePlatform.instance = _FakeCorePlatform();
      FirebaseAuthPlatform.instance = _FakeAuthPlatform();
      await Firebase.initializeApp(
        options: const FirebaseOptions(
            apiKey: 'test',
            appId: '1:1:android:1',
            messagingSenderId: '1',
            projectId: 'test'),
      );
    });

    setUp(() {
      _FakeWebViewPlatform.lastLoadedUrl = null;
      _FakeWebViewPlatform.lastLoadedHtml = null;
      SupaDb.testFixtures = {
        'chat_messages': [
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
        ],
      };
    });

    tearDown(() {
      SupaDb.testFixtures = null;
    });

    testWidgets('renders title, stream area and fixture comments',
        (tester) async {
      // Real phone size (like home_empty_fix_test.dart): the
      // default 800x600 test window makes a 16:9 player 450dp tall
      // and crowds the comments out.
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
      await tester.pump();
      // Let the fixture chat stream emit (Stream.value delivers on
      // the next microtask, after the first build).
      await tester.pump();
      // FIX 9: a watch URL loads through the IFrame wrapper HTML
      // (Chrome UA + onError reporting), not the plain embed URL.
      expect(_FakeWebViewPlatform.lastLoadedUrl, isNull);
      expect(_FakeWebViewPlatform.lastLoadedHtml, contains('dQw4w9WgXcQ'));
      expect(_FakeWebViewPlatform.lastLoadedHtml, contains('iframe_api'));
      expect(find.text('WATCH LIVE'), findsOneWidget);
      expect(find.text('Grand Final'), findsOneWidget);
      expect(find.text('Areeba'), findsOneWidget);
      expect(find.text('GG! Final dekh rahe ho?'), findsOneWidget);
      expect(find.text('Bilal'), findsOneWidget);
      expect(find.text('Last circle — jeet pakki!'), findsOneWidget);
      expect(find.text('Live comment likhein…'), findsOneWidget);
    });
  });
}

// FIX 17 (gate): load the real Roboto so 360px fit tests measure what a
// real phone measures — the fallback test font is ~2x wider and fakes a
// 91px overflow on WatchLiveScreen (same approach as
// fix22_watch_engagement_test.dart / fix5_watchlive_moderator_test.dart).
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
