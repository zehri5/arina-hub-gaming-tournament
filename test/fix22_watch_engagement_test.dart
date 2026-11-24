// FIX 22 items 3+4 — Watch Live info area + engagement row.
//
// ITEM 3: the thick MockupCard frame is GONE (plain Padding, same
// padding + children) and the IN APP count is GONE from the display
// (the heartbeat logic still runs — display removal only).
// ITEM 4: Facebook-style engagement row (Arena dark + gold styling):
// Like (real count) + reacted row (real likers, tap -> full list),
// Comment (real count, tap -> latest + composer focus), Share
// (system sheet, NO count — none exists). Total views + YOUTUBE stay.
// FIX 23 item 28 (user order 2026-11-24): Bookmark REMOVED (button +
// device-local code deleted); the three remaining actions are gold
// pills with full labels at 360px (no ellipsis).
//
// Widget tests pump the real WatchLiveScreen with fixture likes /
// profiles / comments (SupaDb.testFixtures seam + fake Firebase
// Auth + fake WebView platform, same pattern as
// redesign_s2_watch_live_test.dart). No network, no real YouTube.
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
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';
// ignore: depend_on_referenced_packages
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

String _read(String path) => File(path).readAsStringSync();

// Full-line // comments are stripped: the FIX 22 notes name the
// removed pieces, so the assertions must check code, not prose.
String _code(String src) =>
    src.split('\n').where((l) => !l.trimLeft().startsWith('//')).join('\n');

// ---------- fake Firebase (copied pattern from S2) ----------

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

// ---------- fake WebView platform (copied pattern from S2) ----------

class _FakeWebViewPlatform extends WebViewPlatform {
  static String? lastLoadedHtml;
  static int loadHtmlStringCount = 0;

  static void reset() {
    lastLoadedHtml = null;
    loadHtmlStringCount = 0;
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
  Future<void> loadRequest(LoadRequestParams params) async {}

  @override
  Future<void> loadHtmlString(String html, {String? baseUrl}) async {
    _FakeWebViewPlatform.lastLoadedHtml = html;
    _FakeWebViewPlatform.loadHtmlStringCount++;
  }

  @override
  Future<void> setUserAgent(String? userAgent) async {}

  @override
  Future<void> addJavaScriptChannel(JavaScriptChannelParams params) async {}

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
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Fix 22 item 3+4 — info area + engagement (source)', () {
    late String screen;
    late String db;

    setUpAll(() {
      screen = _read('lib/screens/watch_live_screen.dart');
      db = _read('lib/services/supabase_db.dart');
    });

    test('no MockupCard frame, no IN APP display', () {
      final code = _code(screen);
      expect(code, isNot(contains('MockupCard')));
      expect(code, isNot(contains("'IN APP'")));
      expect(code, isNot(contains('Icons.visibility')));
      // The info area is a plain Padding with the same key.
      expect(code, contains("ValueKey('watchLiveInfoCard')"));
      expect(code, contains('padding: const EdgeInsets.all(kSpace12)'));
    });

    test('heartbeat logic untouched (display removal only)', () {
      expect(screen, contains('_startViewerPolling()'));
      expect(screen, contains('_heartbeatViewer()'));
      expect(screen, contains('heartbeatWatchLiveViewer('));
      expect(screen, contains('_viewerTimer = Timer.periodic'));
      // FIX 22 item 3 (warning fix): the IN APP count query died
      // with its display — the screen no longer fetches a count
      // nobody shows (the SupaDb method itself stays, tested by
      // fix8). The heartbeat upsert above is the logic kept.
      expect(screen, isNot(contains('getWatchLiveViewerCount(')));
      expect(screen, isNot(contains('_inAppViewers')));
    });

    test('total views + YOUTUBE stay in the stats row', () {
      expect(screen, contains("formatViewerCount(_totalViews!)"));
      expect(screen, contains("'total views'"));
      expect(screen, contains("formatViewerCount(_ytViewers!)"));
      expect(screen, contains("'YOUTUBE'"));
    });

    test('likers load from watch_live_likes + profiles', () {
      expect(db, contains('static Future<List<Map<String, dynamic>>> getWatchLiveLikers('));
      expect(db, contains("getListOrThrow('watch_live_likes'"));
      expect(screen, contains('getWatchLiveLikers(widget.tournamentId)'));
      expect(screen, contains('getProfilesMap(uids)'));
      expect(screen, contains('_loadLikers()'));
    });

    test('share opens the system sheet with the stream link, no count',
        () {
      expect(screen, contains('Share.share(text)'));
      expect(screen, contains('widget.watchUrl'));
      // The share action has no count argument (the Like and
      // Comment actions do — pin the difference by region).
      final row = screen.substring(screen.indexOf('Widget _engagementRow()'));
      final share = row.substring(row.indexOf("label: 'Share'"));
      expect(share.substring(0, share.indexOf('),')),
          isNot(contains('count:')));
    });

    test('FIX 23 item 28: bookmark is GONE (button + dead code)', () {
      expect(screen, isNot(contains('_toggleBookmark')));
      expect(screen, isNot(contains('_loadBookmark')));
      expect(screen, isNot(contains('_bookmarked')));
      expect(screen, isNot(contains('_bookmarkKey')));
      expect(screen, isNot(contains('watch_live_bookmark_')));
      expect(screen, isNot(contains('watchLiveBookmarkButton')));
      expect(screen, isNot(contains("label: 'Bookmark'")));
    });

    test('FIX 23 item 28: engagement pills — rounded, no ellipsis', () {
      // Scope to _engagementRow only (build() below has its own
      // Expanded/Flexible/ellipsis, legitimately).
      final rowStart = screen.indexOf('Widget _engagementRow()');
      final rowEnd = screen.indexOf('@override', rowStart);
      final row = screen.substring(rowStart, rowEnd);
      // Pill containers (radius 20) + gold active treatment.
      expect(row, contains('BorderRadius.circular(20)'));
      expect(row, contains('kGold.withValues(alpha: 0.12)'));
      // Natural widths spread evenly — no Expanded thirds, no
      // Flexible, no ellipsis (the "Com..."/"Bookm..." bug).
      expect(row, contains('MainAxisAlignment.spaceEvenly'));
      expect(row, isNot(contains('Expanded(')));
      expect(row, isNot(contains('Flexible(')));
      expect(row, isNot(contains('TextOverflow.ellipsis')));
    });

    test('comment tap jumps to latest + focuses the composer', () {
      expect(screen, contains('_jumpToLatest();'));
      expect(screen, contains('_composerFocus.requestFocus();'));
      expect(screen, contains('focusNode: _composerFocus'));
    });
  });

  group('Fix 22 item 4 — reacted text (pure)', () {
    test('0 likers -> nothing', () {
      expect(watchLiveReactedText('Areeba', 0), '');
      expect(watchLiveReactedText('', 0), '');
    });

    test('1 liker -> "Name reacted" (first name only)', () {
      expect(watchLiveReactedText('Areeba Khan', 1), 'Areeba reacted');
      expect(watchLiveReactedText('Bilal', 1), 'Bilal reacted');
    });

    test('N likers -> "Name and N-1 others reacted"', () {
      expect(watchLiveReactedText('Areeba Khan', 2),
          'Areeba and 1 others reacted');
      expect(
          watchLiveReactedText('Bilal', 5), 'Bilal and 4 others reacted');
    });

    test('empty/blank name -> nothing (never a fake name)', () {
      expect(watchLiveReactedText('', 3), '');
      expect(watchLiveReactedText('   ', 3), '');
    });
  });

  group('Fix 22 item 4 — engagement row (widget)', () {
    setUpAll(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      themeLightNotifier.value = false;
      // FIX 23 item 28: load the real Roboto so the 360px fit
      // test measures what a real phone measures — the fallback
      // test font is ~2x wider and would fake an overflow.
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
      SharedPreferences.setMockInitialValues({});
      _FakeWebViewPlatform.reset();
      SupaDb.testRpcCalls.clear();
      SupaDb.testFixtures = {
        'tournaments': [
          {'id': 't1', 'watch_views': 6},
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
        // u1 liked LAST (newest first) so Areeba leads the row.
        'watch_live_likes': [
          {
            'id': 'l1',
            'tournament_id': 't1',
            'firebase_uid': 'u2',
            'created_at': '2026-11-23T10:00:00Z',
          },
          {
            'id': 'l2',
            'tournament_id': 't1',
            'firebase_uid': 'u1',
            'created_at': '2026-11-23T10:01:00Z',
          },
        ],
        'profiles': [
          {
            'firebase_uid': 'u1',
            'display_name': 'Areeba Khan',
            'photo_url': '',
          },
          {
            'firebase_uid': 'u2',
            'display_name': 'Bilal',
            'photo_url': '',
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
      await tester.pump();
      // Let the async chains settle (likes + likers + total).
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      await tester.pump();
    }

    testWidgets('engagement row: Like 2, Comment 2, Share (no Bookmark)',
        (tester) async {
      await pumpScreen(tester);
      expect(find.text('Like'), findsOneWidget);
      expect(find.text('Comment'), findsOneWidget);
      expect(find.text('Share'), findsOneWidget);
      expect(find.text('Bookmark'), findsNothing);
      // Like count 2 (fixture rows), comment count 2 (messages).
      final likeBtn = find.byKey(const ValueKey('watchLiveLikeButton'));
      expect(
          find.descendant(of: likeBtn, matching: find.text('2')),
          findsOneWidget);
      final commentBtn =
          find.byKey(const ValueKey('watchLiveCommentButton'));
      expect(
          find.descendant(of: commentBtn, matching: find.text('2')),
          findsOneWidget);
      // Share carries NO count (exactly one Text).
      final shareBtn = find.byKey(const ValueKey('watchLiveShareButton'));
      expect(
          find.descendant(of: shareBtn, matching: find.byType(Text)),
          findsOneWidget);
      // Total views still shows (6 from the row).
      expect(find.text('total views'), findsOneWidget);
      expect(find.text('IN APP'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'FIX 23 item 28: full labels + counts at 360px, zero ellipsis',
        (tester) async {
      await pumpScreen(tester);
      // Full labels render (no "Com..." truncation) with their
      // counts beside them.
      for (final label in ['Like', 'Comment', 'Share']) {
        final text = tester.widget<Text>(find.text(label));
        expect(text.overflow, isNull, reason: '$label must not ellipsize');
        expect(text.data, label);
      }
      expect(find.text('2'), findsNWidgets(2)); // like 2 + comment 2
      // Pills: rounded containers with a border.
      final likeBtn = find.byKey(const ValueKey('watchLiveLikeButton'));
      final container = tester.widget<Container>(find.descendant(
          of: likeBtn, matching: find.byType(Container)));
      final deco = container.decoration as BoxDecoration;
      expect(deco.borderRadius, BorderRadius.circular(20));
      expect(deco.border, isNotNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets('reacted row shows real likers, newest first',
        (tester) async {
      await pumpScreen(tester);
      expect(find.text('Areeba and 1 others reacted'), findsOneWidget);
      // Two overlapping avatars (initials A + B, no photos) —
      // scoped to the reacted row (the comment bubbles below
      // show the same initials).
      final row = find.ancestor(
        of: find.text('Areeba and 1 others reacted'),
        matching: find.byType(Row),
      );
      expect(find.descendant(of: row, matching: find.text('A')),
          findsOneWidget);
      expect(find.descendant(of: row, matching: find.text('B')),
          findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('tapping the reacted row opens the full likers sheet',
        (tester) async {
      await pumpScreen(tester);
      await tester.tap(find.text('Areeba and 1 others reacted'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Liked by 2'), findsOneWidget);
      // Scoped to the sheet (Bilal is also a comment author
      // behind it).
      final sheet = find.ancestor(
        of: find.text('Liked by 2'),
        matching: find.byType(Column),
      );
      expect(find.descendant(of: sheet, matching: find.text('Areeba Khan')),
          findsOneWidget);
      expect(find.descendant(of: sheet, matching: find.text('Bilal')),
          findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('no likers -> no reacted row, like count 0', (tester) async {
      SupaDb.testFixtures = {
        'tournaments': [
          {'id': 't1', 'watch_views': 6},
        ],
        'chat_messages': const [],
        'watch_live_likes': const [],
        'profiles': const [],
      };
      await pumpScreen(tester);
      expect(find.textContaining('reacted'), findsNothing);
      final likeBtn = find.byKey(const ValueKey('watchLiveLikeButton'));
      expect(
          find.descendant(of: likeBtn, matching: find.text('0')),
          findsOneWidget);
      expect(tester.takeException(), isNull);
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
