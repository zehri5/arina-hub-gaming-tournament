// FIX 6 — FREE SPECTATING (Sameer 2026-11-22 23:06, voice call):
// anyone spectates — no tournament join needed. Watch opens the
// in-app Watch Live page straight away (video + live comments +
// likes + views); the Detail-page detour is gone. A logged-out
// spectator can watch + read; comment/like need login (honest
// toast, never a crash, never a fake success).
//
// Groups: (a) the detail-note rule with no joined requirement,
// (b) source pins on the two Watch entry points + the logged-out
// guards, (c) widget tests pumping the real WatchLiveScreen as a
// logged-in spectator and as a logged-out spectator (fake Firebase
// + fake WebView + SupaDb.testFixtures, same pattern as
// watch_live_test.dart / watch_live_moderation_test.dart).
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

  /// FIX 6: flip to simulate a LOGGED-OUT spectator.
  /// `FirebaseAuth.instance.currentUser` reads the delegate live,
  /// so toggling this changes every read (initState + build).
  static bool signedOut = false;

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
  UserPlatform? get currentUser => signedOut ? null : _user;

  @override
  set currentUser(UserPlatform? user) => _user = user;
}

// ---------- fake WebView platform (copied pattern) ----------

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

// ---------- source-pin helpers ----------

String _read(String path) => File(path).readAsStringSync();

String _region(String src, String startMarker, String endMarker) {
  final start = src.indexOf(startMarker);
  expect(start, isNot(-1), reason: 'start marker missing: $startMarker');
  final end = src.indexOf(endMarker, start + startMarker.length);
  expect(end, isNot(-1), reason: 'end marker missing: $endMarker');
  return src.substring(start, end);
}

void main() {
  group('watchLiveUrlNoteVisibleFor — FIX 6, no joined requirement', () {
    test('non-joined + ongoing + no URL shows the note', () {
      expect(
        watchLiveUrlNoteVisibleFor(
            {'status': 'ongoing', 'watchLiveUrl': ''}),
        isTrue,
      );
      expect(watchLiveUrlNoteVisibleFor({'status': 'ongoing'}), isTrue);
    });
    test('joined + ongoing + no URL still shows the note', () {
      expect(
        watchLiveUrlNoteVisibleFor(
            {'status': 'ongoing', 'watchLiveUrl': ''}),
        isTrue,
      );
    });
    test('upcoming tournament shows no note (not live yet)', () {
      expect(
        watchLiveUrlNoteVisibleFor(
            {'status': 'upcoming', 'watchLiveUrl': ''}),
        isFalse,
      );
    });
  });

  group('FIX 6 source pins — Watch entry points', () {
    late String home;
    late String watchLive;

    setUpAll(() {
      home = _read('lib/screens/home_screens.dart');
      watchLive = _read('lib/screens/watch_live_screen.dart');
    });

    test('home card _watch opens WatchLiveScreen on visibility alone',
        () {
      final watch = _region(
        home,
        'Future<void> _watch(BuildContext context) async {',
        '\n  @override\n  Widget build',
      );
      expect(watch, contains('if (watchLiveVisibleFor(tournament)) {'));
      expect(watch, contains('WatchLiveScreen('));
      expect(watch, contains('watchUrl: watchLiveUrlOf(tournament)'));
    });

    test('no joined gate left on any Watch Live entry point', () {
      expect(home.contains('joined && watchLiveVisibleFor'), isFalse);
    });

    test('_watch never falls back to the Detail page', () {
      final watch = _region(
        home,
        'Future<void> _watch(BuildContext context) async {',
        '\n  @override\n  Widget build',
      );
      expect(watch.contains('_openDetail('), isFalse);
    });

    test('_watch shows an honest note when there is no stream', () {
      final watch = _region(
        home,
        'Future<void> _watch(BuildContext context) async {',
        '\n  @override\n  Widget build',
      );
      expect(watch, contains("toast(context, 'Live stream URL set nahi hai.')"));
    });

    test('detail page Watch Live button needs no join', () {
      expect(home, contains('if (watchLiveVisibleFor(t)) ...['));
    });

    test('detail note call carries no joined argument', () {
      expect(home, contains('if (watchLiveUrlNoteVisibleFor(t)) ...['));
      expect(home.contains('watchLiveUrlNoteVisibleFor(t,\n'), isFalse);
    });

    test('watchLiveUrlNoteVisibleFor has no joined parameter', () {
      final fn = _region(
        watchLive,
        'bool watchLiveUrlNoteVisibleFor(',
        '\n}\n',
      );
      expect(fn.contains('joined'), isFalse);
    });

    test('card tap + Details button still open Detail (unchanged)', () {
      expect(home, contains('onTap: () => _openDetail(context)'));
      expect(home, contains('onPressed: () => _openDetail(context)'));
    });
  });

  group('FIX 6 source pins — logged-out spectator guards', () {
    late String watchLive;

    setUpAll(() {
      watchLive = _read('lib/screens/watch_live_screen.dart');
    });

    test('comment without login toasts honestly', () {
      expect(watchLive,
          contains("toast(context, 'Comment karne ke liye login zaroori hai.')"));
    });

    test('like without login toasts honestly', () {
      expect(watchLive,
          contains("toast(context, 'Like karne ke liye login zaroori hai.')"));
    });

    test('composer shows the login hint to logged-out spectators', () {
      expect(watchLive, contains("'Comment ke liye login karein…'"));
    });

    test('subtitle no longer claims comments are players-only', () {
      expect(watchLive.contains('sirf ARENA HUB players'), isFalse);
      expect(watchLive, contains('Live comments — sab dekh sakte hain'));
    });
  });

  group('WatchLiveScreen spectator widget', () {
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
      SharedPreferences.setMockInitialValues({'admin_mode': false});
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
      _FakeAuthPlatform.signedOut = false;
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
        'watch_live_likes': [
          {'id': 'like-1', 'tournament_id': 't1', 'firebase_uid': 'u1'},
          {'id': 'like-2', 'tournament_id': 't1', 'firebase_uid': 'u2'},
        ],
      };
    });

    tearDown(() {
      SupaDb.testFixtures = null;
      _FakeAuthPlatform.signedOut = false;
    });

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
      // Fixture chat stream + async likes load.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
    }

    // FIX 22 item 4: the like count lives in the engagement
    // row's Like button — the Comment action shows its own
    // count beside it (2 fixture messages), so a bare
    // find.text('2') matches twice. Scope like-count
    // assertions to the Like button.
    Finder likeCount(String count) => find.descendant(
          of: find.byKey(const ValueKey('watchLiveLikeButton')),
          matching: find.text(count),
        );

    testWidgets('logged-in spectator sees comments + like count',
        (tester) async {
      await pumpScreen(tester);
      // FIX 9: the spectator's screen loads the IFrame wrapper
      // HTML (Chrome UA + onError reporting), not the plain embed.
      expect(_FakeWebViewPlatform.lastLoadedUrl, isNull);
      expect(_FakeWebViewPlatform.lastLoadedHtml, contains('dQw4w9WgXcQ'));
      expect(_FakeWebViewPlatform.lastLoadedHtml, contains('iframe_api'));
      expect(find.text('WATCH LIVE'), findsOneWidget);
      expect(find.text('Grand Final'), findsOneWidget);
      expect(find.text('Areeba'), findsOneWidget);
      expect(find.text('GG! Final dekh rahe ho?'), findsOneWidget);
      expect(find.text('Bilal'), findsOneWidget);
      expect(find.text('Last circle — jeet pakki!'), findsOneWidget);
      expect(find.text('Live comments — sab dekh sakte hain'),
          findsOneWidget);
      // 2 fixture likes, neither from the spectator.
      expect(likeCount('2'), findsOneWidget);
      expect(find.byIcon(Icons.favorite_border), findsOneWidget);
      expect(find.text('Live comment likhein…'), findsOneWidget);
    });

    testWidgets('logged-in spectator can like (count 2 -> 3)',
        (tester) async {
      await pumpScreen(tester);
      expect(likeCount('2'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.favorite_border));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();

      expect(likeCount('3'), findsOneWidget);
      expect(find.byIcon(Icons.favorite), findsOneWidget);
    });

    testWidgets('logged-out spectator sees comments + likes read-only',
        (tester) async {
      _FakeAuthPlatform.signedOut = true;
      await pumpScreen(tester);
      expect(find.text('WATCH LIVE'), findsOneWidget);
      expect(find.text('Areeba'), findsOneWidget);
      expect(find.text('GG! Final dekh rahe ho?'), findsOneWidget);
      expect(likeCount('2'), findsOneWidget);
      expect(find.byIcon(Icons.favorite_border), findsOneWidget);
    });

    testWidgets('logged-out spectator sees the login composer hint',
        (tester) async {
      _FakeAuthPlatform.signedOut = true;
      await pumpScreen(tester);
      expect(find.text('Comment ke liye login karein…'), findsOneWidget);
      expect(find.text('Live comment likhein…'), findsNothing);
    });

    testWidgets('logged-out send shows the login toast, no crash',
        (tester) async {
      _FakeAuthPlatform.signedOut = true;
      await pumpScreen(tester);

      await tester.enterText(find.byType(TextField), 'hello final!');
      await tester.tap(find.byIcon(Icons.send));
      await tester.pump();

      expect(find.text('Comment karne ke liye login zaroori hai.'),
          findsOneWidget);
      expect(find.text('WATCH LIVE'), findsOneWidget);
    });

    testWidgets('logged-out like tap shows the login toast, no crash',
        (tester) async {
      _FakeAuthPlatform.signedOut = true;
      await pumpScreen(tester);

      await tester.tap(find.byIcon(Icons.favorite_border));
      await tester.pump();

      expect(find.text('Like karne ke liye login zaroori hai.'),
          findsOneWidget);
      expect(likeCount('2'), findsOneWidget);
      expect(find.byIcon(Icons.favorite_border), findsOneWidget);
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
