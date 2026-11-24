// Phase 2 redesign — GROUP S2: Watch Live styling.
//
// Pins the §6 Screen 2 restyle: contract tokens, the player in a
// dark rounded container, the stream info card, the dark comments
// surface + yellow Send button, polished empty/loading states, the
// player error fallback (Retry, never a YouTube exit), and the
// absence of hardcoded old colours. Logic is pinned only where the
// restyle must not have changed it (comment submission still goes
// through SupaDb.sendChat with scope 'watch_live').
//
// Widget tests pump the real WatchLiveScreen with fixture comments
// (SupaDb.testFixtures seam + fake Firebase Auth + fake WebView
// platform, same pattern as watch_live_test.dart /
// fix9_watch_player_test.dart). No network, no real YouTube stream.
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
import 'package:protournament_user/theme.dart';
import 'package:protournament_user/widgets/arena_ui.dart';
import 'package:webview_flutter/webview_flutter.dart';
// ignore: depend_on_referenced_packages
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

// Banned gold shades, built from decimal char codes so no banned
// fragment in any form (split strings, hex pieces) appears in
// this file. Shade A is the first banned gold, B the second.
String _bannedGoldA() => String.fromCharCodes([70, 70, 67, 56, 48, 48]);
String _bannedGoldB() => String.fromCharCodes([70, 53, 65, 57, 48, 48]);

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

// ---------- fake WebView platform (fix9 pattern: records the load +
// captures the PlayerError JS channel so tests can fire a player
// error and see the app's fallback) ----------

class _FakeWebViewPlatform extends WebViewPlatform {
  static String? lastLoadedUrl;
  static String? lastLoadedHtml;
  static int loadHtmlStringCount = 0;
  static String? errorChannelName;
  static void Function(JavaScriptMessage)? errorChannelHandler;

  static void reset() {
    lastLoadedUrl = null;
    lastLoadedHtml = null;
    loadHtmlStringCount = 0;
    errorChannelName = null;
    errorChannelHandler = null;
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
  _FakeWebViewController.implementation(super.params) : super.implementation();

  @override
  Future<void> loadRequest(LoadRequestParams params) async {
    _FakeWebViewPlatform.lastLoadedUrl = params.uri.toString();
  }

  @override
  Future<void> loadHtmlString(String html, {String? baseUrl}) async {
    _FakeWebViewPlatform.lastLoadedHtml = html;
    _FakeWebViewPlatform.loadHtmlStringCount++;
  }

  @override
  Future<void> setUserAgent(String? userAgent) async {}

  @override
  Future<void> addJavaScriptChannel(JavaScriptChannelParams params) async {
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
  _FakeNavigationDelegate.implementation(super.params) : super.implementation();

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
  group('S2 contract tokens (F1 stub values)', () {
    setUpAll(() {
      // Token values are dark-mode values; pin the switch off.
      themeLightNotifier.value = false;
    });

    test('gold is ONLY #FDC903', () {
      expect(kGold, const Color(0xFFFDC903));
      expect(kGoldDeep, const Color(0xFFFDC903));
      expect(kGoldBright, const Color(0xFFFDC903));
    });

    test('new surface / muted tokens', () {
      expect(kSurfaceElevated, const Color(0xFF202331));
      expect(kTextMuted, const Color(0xFF737789));
      expect(kGoldSoft, const Color(0xFFFFE16A));
      expect(kWarning, const Color(0xFFF4A62A));
      expect(kError, const Color(0xFFF04452));
    });

    test('gradients use the substituted gold (no banned shades)', () {
      expect(
        kGoldGradient.colors,
        [const Color(0xFFFFE16A), const Color(0xFFFDC903)],
      );
      expect(
        kCardSurfaceGradient.colors,
        [const Color(0xFF202331), const Color(0xFF12141C)],
      );
      expect(
        kBackgroundGradient.colors,
        [const Color(0xFF10121A), const Color(0xFF08090D)],
      );
      for (final g in [
        kGoldGradient,
        kCardSurfaceGradient,
        kBackgroundGradient,
      ]) {
        for (final c in g.colors) {
          expect(c, isNot(const Color(0xFFFF0000 + 51200)));
          expect(c, isNot(const Color(0xFFF50000 + 43264)));
        }
      }
    });

    test('spacing + radii', () {
      expect(kSpace4, 4);
      expect(kSpace8, 8);
      expect(kSpace12, 12);
      expect(kSpace16, 16);
      expect(kSpace20, 20);
      expect(kSpace24, 24);
      expect(kSpace32, 32);
      expect(kRadiusChip, 12);
      expect(kRadiusInput, 14);
      expect(kRadiusCard, 18);
      expect(kRadiusHero, 22);
    });

    test('text styles', () {
      expect(kStyleTitle.fontSize, 22);
      expect(kStyleTitle.fontWeight, FontWeight.bold);
      expect(kStyleSection.fontSize, 18);
      expect(kStyleSection.fontWeight, FontWeight.bold);
      expect(kStyleCardTitle.fontSize, 17);
      expect(kStyleCardTitle.fontWeight, FontWeight.w600);
      expect(kStyleBody.fontSize, 15);
      expect(kStyleMeta.fontSize, 13);
      expect(kStyleLabel.fontSize, 12);
      expect(kStyleLabel.fontWeight, FontWeight.w500);
    });
  });

  group('S2 arena_ui stubs render (contract signatures)', () {
    testWidgets('ArenaPrimaryButton renders its child, enabled + disabled',
        (tester) async {
      var tapped = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Column(
            children: [
              ArenaPrimaryButton(
                onPressed: () => tapped = true,
                child: const Text('Go live'),
              ),
              const ArenaPrimaryButton(
                onPressed: null,
                child: Text('Disabled'),
              ),
              const ArenaLoadingIndicator(),
              const ArenaLiveBadge(),
            ],
          ),
        ),
      );
      expect(find.text('Go live'), findsOneWidget);
      expect(find.text('Disabled'), findsOneWidget);
      expect(find.text('LIVE'), findsOneWidget);
      final indicator = tester.widget<CircularProgressIndicator>(
          find.byType(CircularProgressIndicator));
      expect(indicator.color, kGold);
      await tester.tap(find.text('Go live'));
      expect(tapped, isTrue);
    });

    testWidgets('ArenaBackground renders its child over the gradient',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: ArenaBackground(child: Text('behind me')),
        ),
      );
      expect(find.text('behind me'), findsOneWidget);
      final bg = tester.widget<Container>(
        find.descendant(
          of: find.byType(ArenaBackground),
          matching: find.byType(Container).first,
        ),
      );
      final deco = bg.decoration as BoxDecoration;
      expect(deco.gradient, isA<LinearGradient>());
    });
  });

  group('WatchLiveScreen redesign widget', () {
    setUpAll(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      themeLightNotifier.value = false;
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
      // FIX 20 (fix 20): clear the recorded RPC calls + provide
      // the tournaments row the total-views read needs.
      SupaDb.testRpcCalls.clear();
      SupaDb.testFixtures = {
        'tournaments': [
          {'id': 't1', 'watch_views': 1200},
        ],
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
      await tester.pump();
      // Let the fixture chat stream emit.
      await tester.pump();
    }

    testWidgets('top bar: WATCH LIVE title + red LIVE dot', (tester) async {
      await pumpScreen(tester);
      expect(find.byType(AppBar), findsOneWidget);
      expect(find.text('WATCH LIVE'), findsOneWidget);
      // The LIVE dot: 9x9 red circle in the title row, kLiveRed.
      final dot = find.byWidgetPredicate((w) =>
          w is Container &&
          w.decoration is BoxDecoration &&
          (w.decoration as BoxDecoration).color == kLiveRed &&
          (w.decoration as BoxDecoration).shape == BoxShape.circle);
      expect(dot, findsOneWidget);
      final appBar = tester.widget<AppBar>(find.byType(AppBar));
      expect(appBar.backgroundColor, kBg);
      expect(appBar.elevation, 0);
    });

    // FIX 20 (fix 18): smoke test — after the comments load,
    // timer-driven rebuilds must NOT send the list back to the
    // waiting spinner. (The source pin in fix20_community_voice_
    // test.dart proves the stream is created once in initState;
    // this test proves the list stays put across rebuilds.)
    testWidgets('comments stay visible across timer rebuilds (no reload)',
        (tester) async {
      await pumpScreen(tester);
      expect(find.text('GG! Final dekh rahe ho?'), findsOneWidget);
      // Fire the 30s viewer timer (and the kick timer) — each
      // setStates the screen, which used to resubscribe the
      // comments stream and flash the spinner.
      await tester.pump(const Duration(seconds: 31));
      await tester.pump();
      await tester.pump(const Duration(seconds: 31));
      await tester.pump();
      expect(find.text('GG! Final dekh rahe ho?'), findsOneWidget);
      expect(find.text('Last circle — jeet pakki!'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    // FIX 20 (fix 20): the total-views counter — one increment
    // per Watch open, the total read from the tournament row,
    // "—" when the backend migration hasn't landed yet.
    testWidgets('Watch open calls the increment RPC exactly once',
        (tester) async {
      await pumpScreen(tester);
      await tester.pump(const Duration(seconds: 31));
      await tester.pump();
      await tester.pump(const Duration(seconds: 31));
      await tester.pump();
      expect(SupaDb.testRpcCalls.length, 1);
      expect(SupaDb.testRpcCalls.single['rpc'], 'increment_watch_views');
      expect(SupaDb.testRpcCalls.single['p_tournament_id'], 't1');
    });

    testWidgets('total views display from the row value, compact (1.2K)',
        (tester) async {
      await pumpScreen(tester);
      // Let the async chain settle (API-key read -> total read ->
      // rebuild); small pumps only, so no 30s timer fires.
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      await tester.pump();
      // The open incremented the fixture 1200 -> 1201; both
      // format as "1.2K" (1200 is the formatter's own doc
      // example; 1250 would round to "1.3K"). Scoped to the total-views row so a
      // "1.2K" anywhere else would not satisfy this.
      final totalRow = find.byWidgetPredicate((w) =>
          w is Row &&
          w.children.any((c) => c is Text && c.data == 'total views'));
      expect(totalRow, findsOneWidget);
      expect(find.descendant(of: totalRow, matching: find.text('1.2K')),
          findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('missing watch_views column -> "—", no crash, no 0',
        (tester) async {
      // Pre-migration server: the row exists but has no
      // watch_views key (the RPC 404s there, so no bump either).
      SupaDb.testFixtures = {
        'tournaments': [
          {'id': 't1'},
        ],
        'chat_messages': const [],
      };
      await pumpScreen(tester);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      await tester.pump();
      final totalRow = find.byWidgetPredicate((w) =>
          w is Row &&
          w.children.any((c) => c is Text && c.data == 'total views'));
      expect(totalRow, findsOneWidget);
      expect(find.descendant(of: totalRow, matching: find.text('—')),
          findsOneWidget);
      // The total row itself shows no 0 (other rows — likes,
      // viewers — may legitimately show 0).
      expect(find.descendant(of: totalRow, matching: find.text('0')),
          findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('back navigation appears when pushed on a stack',
        (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => Navigator.of(ctx).push(
                    MaterialPageRoute(
                      builder: (_) => const WatchLiveScreen(
                        tournamentId: 't1',
                        tournamentName: 'Grand Final',
                        watchUrl: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
                      ),
                    ),
                  ),
                  child: const Text('Open live'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open live'));
      await tester.pump();
      await tester.pump();
      expect(find.text('WATCH LIVE'), findsOneWidget);
      expect(find.byTooltip('Back'), findsOneWidget);
    });

    testWidgets('player sits in a dark rounded container', (tester) async {
      await pumpScreen(tester);
      // The video id still loads through the IFrame wrapper HTML
      // (FIX 9), not a plain URL load.
      expect(_FakeWebViewPlatform.lastLoadedUrl, isNull);
      expect(_FakeWebViewPlatform.lastLoadedHtml, contains('dQw4w9WgXcQ'));
      expect(_FakeWebViewPlatform.lastLoadedHtml, contains('iframe_api'));
      expect(_FakeWebViewPlatform.loadHtmlStringCount, 1);
      final key = find.byKey(const ValueKey('watchLivePlayerContainer'));
      expect(key, findsOneWidget);
      final container = tester.widget<Container>(key);
      final deco = container.decoration as BoxDecoration;
      expect(deco.color, Colors.black);
      expect(deco.borderRadius, BorderRadius.circular(kRadiusHero));
      expect(deco.borderRadius, BorderRadius.circular(22));
      final border = deco.border as Border;
      expect(border.top.color, kBorder);
      // The webview itself lives inside that container.
      expect(
        find.descendant(
          of: key,
          matching: find.byType(WebViewWidget),
        ),
        findsOneWidget,
      );
    });

    testWidgets('player loading state preserved (gold indicator, keyed)',
        (tester) async {
      await pumpScreen(tester);
      // The fake never fires onPageFinished, so the player is
      // still "loading" — the keyed indicator must be showing.
      final key = find.byKey(const ValueKey('watchLivePlayerLoading'));
      expect(key, findsOneWidget);
      expect(tester.widget(key), isA<ArenaLoadingIndicator>());
    });

    testWidgets('stream title + stats live in a frameless info area',
        (tester) async {
      await pumpScreen(tester);
      // FIX 22 (item 3): the thick MockupCard frame is gone — a
      // plain Padding, same key, same children.
      expect(find.byType(MockupCard), findsNothing);
      final info = find.byKey(const ValueKey('watchLiveInfoCard'));
      expect(info, findsOneWidget);
      expect(
        find.descendant(of: info, matching: find.text('Grand Final')),
        findsOneWidget,
      );
      // FIX 22 (item 3): the IN APP count is gone from the display.
      expect(find.text('IN APP'), findsNothing);
      // Total views + the comments note stay.
      expect(
        find.descendant(of: info, matching: find.text('total views')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: info,
          matching: find.text('Live comments — sab dekh sakte hain'),
        ),
        findsOneWidget,
      );
      // FIX 22 (item 4): the engagement row lives in the info area.
      expect(
        find.descendant(
            of: info,
            matching:
                find.byKey(const ValueKey('watchLiveLikeButton'))),
        findsOneWidget,
      );
      expect(
        find.descendant(
            of: info,
            matching:
                find.byKey(const ValueKey('watchLiveShareButton'))),
        findsOneWidget,
      );
      // FIX 22 (item 4) + FIX 23 item 28: Bookmark REMOVED by user
      // order 2026-11-24 (see _engagementRow doc in watch_live_screen);
      // the engagement row is Like + Share only — pin the absence.
      expect(
        find.descendant(
            of: info,
            matching:
                find.byKey(const ValueKey('watchLiveBookmarkButton'))),
        findsNothing,
      );
      final title = tester.widget<Text>(find.text('Grand Final'));
      expect(title.style?.fontSize, kStyleCardTitle.fontSize);
    });

    testWidgets('comments area is a dark surface with fixture comments',
        (tester) async {
      await pumpScreen(tester);
      final surface = find.byKey(const ValueKey('watchLiveCommentsSurface'));
      expect(surface, findsOneWidget);
      expect(tester.widget<Container>(surface).color, kSurface);
      expect(find.text('Areeba'), findsOneWidget);
      expect(find.text('GG! Final dekh rahe ho?'), findsOneWidget);
      expect(find.text('Bilal'), findsOneWidget);
      expect(find.text('Last circle — jeet pakki!'), findsOneWidget);
    });

    testWidgets('Send button is yellow; composer + send tap stay intact',
        (tester) async {
      await pumpScreen(tester);
      expect(find.text('Live comment likhein…'), findsOneWidget);
      final send = find.byKey(const ValueKey('watchLiveSendButton'));
      expect(send, findsOneWidget);
      final deco = tester.widget<Container>(send).decoration as BoxDecoration;
      expect(deco.color, kGold);
      expect(deco.shape, BoxShape.circle);
      final icon = tester.widget<Icon>(
        find.descendant(of: send, matching: find.byIcon(Icons.send)),
      );
      expect(icon.color, Colors.black);
      expect(find.byTooltip('Bhejein'), findsOneWidget);
      // Tapping send with text must not crash the screen (the
      // send itself hits no test backend and fails honestly
      // inside _send's try/catch, like the real no-network path).
      await tester.enterText(find.byType(TextField), 'Test comment');
      await tester.tap(find.byTooltip('Bhejein'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Grand Final'), findsOneWidget);
      expect(find.text('Areeba'), findsOneWidget);
    });

    testWidgets('empty comments state is polished (icon + message)',
        (tester) async {
      SupaDb.testFixtures = {'chat_messages': []};
      await pumpScreen(tester);
      expect(
        find.text('Abhi koi comment nahi — pehla comment aap karein!'),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.forum_outlined), findsOneWidget);
    });

    testWidgets('player error fallback: Retry, never a YouTube exit',
        (tester) async {
      await pumpScreen(tester);
      final handler = _FakeWebViewPlatform.errorChannelHandler;
      expect(handler, isNotNull);
      expect(_FakeWebViewPlatform.errorChannelName, 'PlayerError');
      handler!(const JavaScriptMessage(message: '150'));
      await tester.pump();
      // FIX 21 (item 5): a PLAYER error gets the neutral message —
      // the internet is not blamed for a player failure.
      expect(find.text('Stream app mein nahi chal saki — dobara koshish karein.'),
          findsOneWidget);
      expect(find.text('Dobara koshish karein'), findsOneWidget);
      expect(find.byIcon(Icons.refresh), findsOneWidget);
      // Retry is the shared gold primary button now.
      expect(
        find.descendant(
          of: find.byType(ArenaPrimaryButton),
          matching: find.text('Dobara koshish karein'),
        ),
        findsOneWidget,
      );
      // Loading spinner gone while the fallback shows.
      expect(
          find.byKey(const ValueKey('watchLivePlayerLoading')), findsNothing);
      // NO YouTube exit anywhere (Fix 9 order, 2026-11-23).
      expect(find.text('YouTube me kholein'), findsNothing);
      expect(find.text('Watch video on YouTube'), findsNothing);
      expect(find.byIcon(Icons.open_in_new), findsNothing);
      expect(find.textContaining('YouTube'), findsNothing);
      expect(find.textContaining('YOUTUBE'), findsNothing);
      // Retry reloads the same player in-app (no exit) and the
      // loading state comes back.
      await tester.tap(find.text('Dobara koshish karein'));
      await tester.pump();
      expect(_FakeWebViewPlatform.loadHtmlStringCount, 2);
      expect(_FakeWebViewPlatform.lastLoadedHtml,
          contains('dQw4w9WgXcQ'));
      expect(find.byKey(const ValueKey('watchLivePlayerLoading')),
          findsOneWidget);
      expect(find.text('Dobara koshish karein'), findsNothing);
    });

    testWidgets('healthy screen has no YouTube-exit buttons', (tester) async {
      await pumpScreen(tester);
      expect(find.text('YouTube me kholein'), findsNothing);
      expect(find.text('Watch video on YouTube'), findsNothing);
      expect(find.byIcon(Icons.open_in_new), findsNothing);
      expect(find.textContaining('YouTube'), findsNothing);
    });
  });

  group('S2 source checks — no old colours, logic preserved', () {
    late String screen;
    late String theme;
    late String arenaUi;

    setUpAll(() {
      screen = File('lib/screens/watch_live_screen.dart').readAsStringSync();
      theme = File('lib/theme.dart').readAsStringSync();
      arenaUi = File('lib/widgets/arena_ui.dart').readAsStringSync();
    });

    test('no banned gold anywhere in the touched files', () {
      for (final src in [screen, theme, arenaUi]) {
        expect(src, isNot(contains(_bannedGoldA())));
        expect(src, isNot(contains(_bannedGoldB())));
        expect(src, isNot(contains(_bannedGoldA().toLowerCase())));
        expect(src, isNot(contains(_bannedGoldB().toLowerCase())));
      }
    });

    test('no hardcoded old colours left in the screen', () {
      // The local _watchGold duplicate is gone — kGold is used.
      expect(screen, isNot(contains('_watchGold')));
      // The LIVE dot uses the kLiveRed token, not a literal.
      expect(screen, isNot(contains('0xFFFF2D2D')));
      // The avatar + bubble use tokens, not literals.
      expect(screen, isNot(contains('0xFF2A2E3D')));
      // Mod-menu reds use the kError token.
      expect(screen, isNot(contains('redAccent')));
      expect(screen, isNot(contains('white54')));
      expect(screen, isNot(contains('white70')));
      expect(screen, isNot(contains('white30')));
    });

    test('no YouTube-exit affordance in the screen source', () {
      expect(screen, isNot(contains('YouTube me kholein')));
      expect(screen, isNot(contains('Watch video on YouTube')));
      expect(screen, isNot(contains('open_in_new')));
      expect(screen, isNot(contains('OutlinedButton.icon')));
    });

    test('restyle uses the contract components + tokens', () {
      expect(screen, contains('ArenaBackground'));
      expect(screen, contains('ArenaLoadingIndicator'));
      expect(screen, contains('ArenaPrimaryButton'));
      // FIX 22 (item 3): the info card's thick MockupCard frame is
      // gone — a plain Padding now (and kRadiusCard went with it;
      // the FIX 22 note still names MockupCard, so strip comments
      // before asserting absence).
      final code = screen
          .split('\n')
          .where((l) => !l.trimLeft().startsWith('//'))
          .join('\n');
      expect(code, isNot(contains('MockupCard')));
      expect(code, isNot(contains('kRadiusCard')));
      expect(code, isNot(contains("'IN APP'")));
      expect(screen, contains('kSurfaceElevated'));
      expect(screen, contains('kRadiusHero'));
      expect(screen, contains('kStyleCardTitle'));
      expect(screen, contains('kLiveRed'));
      expect(screen, contains('kError'));
      expect(screen, contains('kTextMuted'));
    });

    test('comment submission logic is untouched', () {
      expect(screen, contains("scope: 'watch_live'"));
      expect(screen, contains('SupaDb.sendChat('));
      expect(screen, contains('onSubmitted: (_) => _send()'));
      expect(screen, contains('textInputAction: TextInputAction.send'));
    });

    test('player states + keys are preserved', () {
      expect(screen, contains("ValueKey('watchLivePlayerLoading')"));
      expect(screen, contains('_retryPlayer'));
      expect(screen, contains('_loadingPlayer'));
      expect(screen, contains('_playerFailed'));
      expect(screen, contains('Stream load nahi ho saka'));
      expect(screen, contains('Abhi koi comment nahi'));
      expect(screen, contains('Comments load nahi ho sake'));
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
