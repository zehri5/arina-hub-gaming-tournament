// FIX 9 (2026-11-23) — Watch Live player: Error 153 fix + remove
// ALL YouTube-exit routes.
//
// Live bug (Sameer's phone, tournament "pppppppp"): the player
// showed YouTube's own error screen — "Video player configuration
// error / Error 153" + a "Watch video on YouTube" button — for a
// video whose oEmbed says embedding is allowed. The fix: a Chrome
// mobile user agent (the default Android WebView UA contains "wv",
// which YouTube's player rejects with 153), autoplay without a
// user gesture on Android, and an IFrame API wrapper page whose
// onError posts to the 'PlayerError' JavaScriptChannel so the app
// shows its own fallback + Retry instead of YouTube's error
// screen. The AppBar arrow ("YouTube me kholein") and the
// fallback's YouTube button are both gone (user order 2026-11-23
// 00:12); Retry reloads the player in-app.
//
// No network, no real WebView: the fake platform records the HTML
// / URL / user agent the screen loads and captures the error
// channel handler, so the error path is driven through the real
// handler. Real playback can only be proven on Sameer's phone.
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

// ---------- fake WebView platform ----------
// Records everything the screen asks the webview to do: the HTML
// string (IFrame wrapper), the direct-load URL (channel live),
// the user agent, and the PlayerError channel handler — so tests
// can drive the error path through the real handler.

class _FakeWebViewPlatform extends WebViewPlatform {
  static String? lastLoadedUrl;
  static String? lastLoadedHtml;
  static String? lastBaseUrl;
  static int loadHtmlStringCount = 0;
  static String? lastUserAgent;
  static String? errorChannelName;
  static void Function(JavaScriptMessage)? errorChannelHandler;
  static WebResourceErrorCallback? resourceErrorHandler;

  static void reset() {
    lastLoadedUrl = null;
    lastLoadedHtml = null;
    lastBaseUrl = null;
    loadHtmlStringCount = 0;
    lastUserAgent = null;
    errorChannelName = null;
    errorChannelHandler = null;
    resourceErrorHandler = null;
  }

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
    _FakeWebViewPlatform.lastBaseUrl = baseUrl;
    _FakeWebViewPlatform.loadHtmlStringCount++;
  }

  @override
  Future<void> setUserAgent(String? userAgent) async {
    _FakeWebViewPlatform.lastUserAgent = userAgent;
  }

  @override
  Future<void> addJavaScriptChannel(
      JavaScriptChannelParams params) async {
    _FakeWebViewPlatform.errorChannelName = params.name;
    _FakeWebViewPlatform.errorChannelHandler = params.onMessageReceived;
  }

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
  ) async {
    _FakeWebViewPlatform.resourceErrorHandler = onWebResourceError;
  }
}

class _FakeWebViewWidget extends PlatformWebViewWidget {
  _FakeWebViewWidget.implementation(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) =>
      const ColoredBox(color: Colors.black);
}

void main() {
  // The real failing case from Sameer's phone.
  const failingUrl = 'https://youtu.be/1O_GCgCu-j4?si=yaqDCuIbXoJu6Ilh';
  const failingId = '1O_GCgCu-j4';

  group('kWatchLiveUserAgent', () {
    test('is a Chrome mobile UA with no WebView "wv" marker', () {
      expect(kWatchLiveUserAgent, contains('Chrome/'));
      expect(kWatchLiveUserAgent, contains('Mobile'));
      expect(kWatchLiveUserAgent, isNot(contains('; wv')));
      expect(kWatchLiveUserAgent, isNot(contains(' wv;')));
    });
  });

  group('buildYouTubePlayerHtml', () {
    test('embeds the video id + IFrame API + onError + autoplay', () {
      final html = buildYouTubePlayerHtml(failingId);
      expect(html, contains(failingId));
      expect(html, contains('https://www.youtube.com/iframe_api'));
      expect(html, contains('onYouTubeIframeAPIReady'));
      expect(html, contains('new YT.Player'));
      expect(html, contains('onError'));
      expect(html, contains('PlayerError.postMessage'));
      expect(html, contains('autoplay: 1'));
      expect(html, contains('modestbranding: 1'));
      expect(html, contains('playsinline: 1'));
      expect(html, contains('rel: 0'));
    });

    test('sanitises a hostile video id (no JS break-out)', () {
      final html = buildYouTubePlayerHtml("x';alert(1);//<script>");
      expect(html, isNot(contains("alert(1)")));
      expect(html, isNot(contains("';")));
      expect(html, contains("videoId: 'xalert1script'"));
    });

    // FIX 20 (fix 19): fast start on slow data — onReady sets
    // 240p first ('small') and caps auto quality at 360p
    // ('medium'), BEFORE playVideo, so the stream begins in
    // seconds instead of trying HD first.
    test('onReady starts low (240p) + caps auto quality at 360p', () {
      final html = buildYouTubePlayerHtml(failingId);
      expect(html, contains("setPlaybackQuality('small')"));
      expect(html, contains("setPlaybackQualityRange('small', 'medium')"));
      expect(html, contains('playVideo()'));
      expect(html.indexOf("setPlaybackQuality('small')"),
          lessThan(html.indexOf('playVideo()')));
      // The PlayerError onError post is untouched.
      expect(html, contains('PlayerError.postMessage'));
    });
  });

  group('channel-live behaviour unchanged', () {
    test('channel live URL still has no video id and loads raw', () {
      const channelLive = 'https://www.youtube.com/@ArenaHub/live';
      expect(extractYouTubeVideoId(channelLive), isNull);
      expect(watchLiveLoadUrl(channelLive), channelLive);
    });
    test('video URL still parses to its id', () {
      expect(extractYouTubeVideoId(failingUrl), failingId);
    });
  });

  group('WatchLiveScreen widget (FIX 9)', () {
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
      _FakeWebViewPlatform.reset();
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
        ],
      };
    });

    tearDown(() {
      SupaDb.testFixtures = null;
    });

    Future<void> pumpScreen(WidgetTester tester, String watchUrl) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: WatchLiveScreen(
            tournamentId: 't1',
            tournamentName: 'Grand Final',
            watchUrl: watchUrl,
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
    }

    testWidgets('no YouTube-exit button anywhere on the screen',
        (tester) async {
      await pumpScreen(tester, failingUrl);
      expect(find.byIcon(Icons.open_in_new), findsNothing);
      expect(find.text('YouTube me kholein'), findsNothing);
      expect(find.text('WATCH LIVE'), findsOneWidget);
    });

    testWidgets('back arrow still shows when pushed on a route stack',
        (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const WatchLiveScreen(
                    tournamentId: 't1',
                    tournamentName: 'Grand Final',
                    watchUrl: failingUrl,
                  ),
                ),
              ),
              child: const Text('go'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await tester.pump();
      await tester.pump();
      expect(find.text('WATCH LIVE'), findsOneWidget);
      expect(find.byIcon(Icons.arrow_back), findsOneWidget);
      expect(find.byIcon(Icons.open_in_new), findsNothing);
    });

    testWidgets(
        'video URL loads through the IFrame wrapper with the Chrome UA',
        (tester) async {
      await pumpScreen(tester, failingUrl);
      final html = _FakeWebViewPlatform.lastLoadedHtml;
      expect(html, isNotNull);
      expect(html, contains(failingId));
      expect(html, contains('iframe_api'));
      expect(html, contains('onError'));
      // No direct embed-URL load for a video id any more.
      expect(_FakeWebViewPlatform.lastLoadedUrl, isNull);
      expect(_FakeWebViewPlatform.lastUserAgent, kWatchLiveUserAgent);
      // The error channel is registered under its documented name.
      expect(_FakeWebViewPlatform.errorChannelName, 'PlayerError');
      expect(_FakeWebViewPlatform.errorChannelHandler, isNotNull);
    });

    testWidgets(
        'player error shows the app fallback with Retry, never YouTube',
        (tester) async {
      await pumpScreen(tester, failingUrl);
      final handler = _FakeWebViewPlatform.errorChannelHandler;
      expect(handler, isNotNull);
      // Simulate the IFrame player's onError (e.g. code 150).
      handler!(const JavaScriptMessage(message: '150'));
      await tester.pump();
      // FIX 21 (item 5): a PLAYER error gets the neutral message —
      // the internet is not blamed for a player failure.
      expect(find.text('Stream app mein nahi chal saki — dobara koshish karein.'),
          findsOneWidget);
      expect(find.textContaining('internet check karein'), findsNothing);
      expect(find.text('Dobara koshish karein'), findsOneWidget);
      expect(find.byIcon(Icons.refresh), findsOneWidget);
      expect(find.text('YouTube me kholein'), findsNothing);
      expect(find.byIcon(Icons.open_in_new), findsNothing);
      // The player loading spinner is gone while the fallback shows
      // (keyed — the comments area has its own spinner).
      expect(find.byKey(const ValueKey('watchLivePlayerLoading')),
          findsNothing);
    });

    testWidgets('Retry reloads the player and clears the failure',
        (tester) async {
      await pumpScreen(tester, failingUrl);
      expect(_FakeWebViewPlatform.loadHtmlStringCount, 1);
      _FakeWebViewPlatform.errorChannelHandler!(
          const JavaScriptMessage(message: '100'));
      await tester.pump();
      expect(find.text('Dobara koshish karein'), findsOneWidget);
      await tester.tap(find.text('Dobara koshish karein'));
      await tester.pump();
      // Loading again, fallback gone, wrapper re-loaded.
      expect(find.byKey(const ValueKey('watchLivePlayerLoading')),
          findsOneWidget);
      expect(find.text('Dobara koshish karein'), findsNothing);
      expect(_FakeWebViewPlatform.loadHtmlStringCount, 2);
      expect(_FakeWebViewPlatform.lastLoadedHtml, contains(failingId));
    });

    // FIX 21 (item 4): the wrapper loads with the APPFIXGURU base
    // URL — fix 22's youtube.com baseUrl itself caused Error 152
    // on v2020 (a page claiming to BE youtube.com hosting a
    // youtube.com iframe is rejected as an invalid embed context).
    testWidgets('wrapper loads with the appfixguru baseUrl (fix 21)',
        (tester) async {
      await pumpScreen(tester, failingUrl);
      expect(_FakeWebViewPlatform.lastBaseUrl,
          'https://appfixguru.com');
    });

    // FIX 21 (item 4): the IFrame `origin` playerVar matches the
    // base URL (same constant — they can never drift apart).
    testWidgets('IFrame origin playerVar matches the baseUrl',
        (tester) async {
      await pumpScreen(tester, failingUrl);
      final html = _FakeWebViewPlatform.lastLoadedHtml ?? '';
      expect(html, contains("origin: 'https://appfixguru.com'"));
      expect(_FakeWebViewPlatform.lastBaseUrl,
          'https://appfixguru.com');
    });

    // FIX 20 (fix 21): the PlayerError code is captured RAW and
    // shown as a small muted diagnostic line under the message.
    // FIX 21 (item 5): the message above it is the neutral one.
    testWidgets('PlayerError code 5 shows as "Error code: 5"',
        (tester) async {
      await pumpScreen(tester, failingUrl);
      _FakeWebViewPlatform.errorChannelHandler!(
          const JavaScriptMessage(message: '5'));
      await tester.pump();
      expect(find.text('Stream app mein nahi chal saki — dobara koshish karein.'),
          findsOneWidget);
      expect(find.text('Error code: 5'), findsOneWidget);
      expect(find.text('Dobara koshish karein'), findsOneWidget);
    });

    // Sameer's exact code: 115 is NOT a documented IFrame onError
    // code (2/5/100/101/150) — the handler must store it RAW,
    // never map or drop unrecognised codes.
    testWidgets('PlayerError code 115 is shown raw, never mapped',
        (tester) async {
      await pumpScreen(tester, failingUrl);
      _FakeWebViewPlatform.errorChannelHandler!(
          const JavaScriptMessage(message: '115'));
      await tester.pump();
      expect(find.text('Error code: 115'), findsOneWidget);
    });

    // The IFrame wrapper posts 'unknown' when the player gives no
    // code — that is an absence, not a diagnosis: no line at all.
    // FIX 21 (item 5): still a player error, so the neutral message.
    testWidgets("'unknown' code shows no diagnostic line",
        (tester) async {
      await pumpScreen(tester, failingUrl);
      _FakeWebViewPlatform.errorChannelHandler!(
          const JavaScriptMessage(message: 'unknown'));
      await tester.pump();
      expect(find.text('Stream app mein nahi chal saki — dobara koshish karein.'),
          findsOneWidget);
      expect(find.textContaining('Error code'), findsNothing);
      expect(find.textContaining('unknown'), findsNothing);
    });

    // FIX 20 (fix 21): a main-frame resource error shows its raw
    // code + description. FIX 21 (item 5): a NETWORK error keeps
    // the internet hint — only player errors get the neutral text.
    testWidgets('main-frame resource error shows its code',
        (tester) async {
      await pumpScreen(tester, failingUrl);
      final handler = _FakeWebViewPlatform.resourceErrorHandler;
      expect(handler, isNotNull);
      handler!(const WebResourceError(
        errorCode: -2,
        description: 'net::ERR_INTERNET_DISCONNECTED',
        isForMainFrame: true,
        url: 'https://www.youtube.com/embed/1O_GCgCu-j4',
      ));
      await tester.pump();
      expect(find.textContaining('Stream load nahi ho saka'),
          findsOneWidget);
      expect(find.textContaining('internet check karein'), findsOneWidget);
      expect(
          find.text('Network error -2: net::ERR_INTERNET_DISCONNECTED'),
          findsOneWidget);
      expect(find.text('Dobara koshish karein'), findsOneWidget);
    });

    // FIX 20 (fix 17, widget-level): a subresource error never
    // fails the player — no fallback, no diagnostic line.
    testWidgets('subresource error leaves the player up',
        (tester) async {
      await pumpScreen(tester, failingUrl);
      final handler = _FakeWebViewPlatform.resourceErrorHandler;
      expect(handler, isNotNull);
      handler!(const WebResourceError(
        errorCode: -6,
        description: 'net::ERR_FILE_NOT_FOUND',
        isForMainFrame: false,
        url: 'https://i.ytimg.com/vi/1O_GCgCu-j4/hqdefault.jpg',
      ));
      await tester.pump();
      expect(find.textContaining('Stream load nahi ho saka'),
          findsNothing);
      expect(find.textContaining('Stream app mein nahi chal saki'),
          findsNothing);
      expect(find.text('Dobara koshish karein'), findsNothing);
      expect(find.textContaining('Error code'), findsNothing);
      expect(find.textContaining('Network error'), findsNothing);
    });

    // FIX 20 (fix 21a): at 360dp the whole fallback — message +
    // diagnostic code + button — fits INSIDE the ~189dp player
    // box with zero overflow, the code line ABOVE the button
    // (never behind or below it where it can be covered).
    // pumpScreen already sets a 360x800 surface.
    testWidgets(
        'fallback at 360dp: code + button both fully visible, no overflow',
        (tester) async {
      await pumpScreen(tester, failingUrl);
      _FakeWebViewPlatform.errorChannelHandler!(
          const JavaScriptMessage(message: '115'));
      await tester.pump();
      final boxRect = tester.getRect(
          find.byKey(const ValueKey('watchLivePlayerContainer')));
      final codeRect = tester.getRect(find.text('Error code: 115'));
      final buttonRect =
          tester.getRect(find.text('Dobara koshish karein'));
      // Both fully inside the player box (a pump with a
      // RenderFlex overflow would already have failed the test).
      expect(boxRect.contains(codeRect.topLeft), isTrue);
      expect(boxRect.contains(codeRect.bottomRight), isTrue);
      expect(boxRect.contains(buttonRect.topLeft), isTrue);
      expect(boxRect.contains(buttonRect.bottomRight), isTrue);
      // Code line sits ABOVE the button, with clear spacing.
      expect(codeRect.bottom, lessThan(buttonRect.top));
    });

    testWidgets('channel-live URL still loads directly, no wrapper',
        (tester) async {
      const channelLive = 'https://www.youtube.com/@ArenaHub/live';
      await pumpScreen(tester, channelLive);
      expect(_FakeWebViewPlatform.lastLoadedUrl, channelLive);
      expect(_FakeWebViewPlatform.lastLoadedHtml, isNull);
      expect(_FakeWebViewPlatform.loadHtmlStringCount, 0);
      expect(find.byIcon(Icons.open_in_new), findsNothing);
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
