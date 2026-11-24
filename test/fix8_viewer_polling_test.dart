// FIX 8 (2026-11-22) — viewer count via polling.
//
// Realtime does NOT exist on A1 (404), so the Watch Live in-app
// viewer count cannot come from Realtime presence. It comes from a
// heartbeat table instead: `watch_live_viewers` (tournament_id +
// viewer_key + last_seen). The screen upserts one row on open (one
// random viewer key per screen open, logged-in or guest), re-upserts
// every 30 s, and deletes its row on dispose (best-effort). The
// count is the rows for the tournament with last_seen inside the
// last 90 s. Any failure reads "—", never 0 and never a stale
// number. The Realtime presence subscription is still opened but
// the displayed count comes from the poll, never from presenceState.
//
// Covers: the 30 s / 90 s constants, the freshness rule (incl. the
// 90 s boundary), heartbeat upsert semantics (one row per key,
// stable key across beats), tournament filtering, dispose delete,
// count failure -> "—", and the 30 s tick refreshing the count.
// Widget tests pump the real WatchLiveScreen with the same fake
// Firebase / fake WebView pattern as watch_live_test.dart; the
// SupaDb methods are exercised against the fixture seam — no
// network, no live server.
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

String _read(String rel) => File('test/../$rel').readAsStringSync();

String _isoMinutesAgo(double minutes) => DateTime.now()
    .toUtc()
    .subtract(Duration(milliseconds: (minutes * 60000).round()))
    .toIso8601String();

String _isoSecondsAgo(int seconds) =>
    DateTime.now().toUtc().subtract(Duration(seconds: seconds)).toIso8601String();

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

// ---------- fake WebView platform (copied pattern from watch_live_test.dart) ----------

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
  Widget build(BuildContext context) =>
      const ColoredBox(color: Colors.black);
}

void main() {
  group('FIX 8 constants', () {
    test('heartbeat is 30 s, staleness window is 90 s (3x heartbeat)', () {
      expect(SupaDb.watchLiveViewerHeartbeatSeconds, 30);
      expect(SupaDb.watchLiveViewerStaleSeconds, 90);
      expect(SupaDb.watchLiveViewerStaleSeconds,
          3 * SupaDb.watchLiveViewerHeartbeatSeconds);
    });
  });

  group('watchLiveViewerRowIsFresh — staleness rule', () {
    test('fresh within 90 s, stale beyond it', () {
      final now = DateTime.utc(2026, 11, 22, 23, 20, 0);
      expect(
          SupaDb.watchLiveViewerRowIsFresh(
              DateTime.utc(2026, 11, 22, 23, 19, 30).toIso8601String(),
              now: now),
          isTrue);
      expect(
          SupaDb.watchLiveViewerRowIsFresh(
              DateTime.utc(2026, 11, 22, 23, 18, 29).toIso8601String(),
              now: now),
          isFalse);
    });
    test('exactly 90 s old still counts (boundary is inclusive)', () {
      final now = DateTime.utc(2026, 11, 22, 23, 20, 0);
      expect(
          SupaDb.watchLiveViewerRowIsFresh(
              DateTime.utc(2026, 11, 22, 23, 18, 30).toIso8601String(),
              now: now),
          isTrue);
      expect(
          SupaDb.watchLiveViewerRowIsFresh(
              DateTime.utc(2026, 11, 22, 23, 18, 29, 999).toIso8601String(),
              now: now),
          isFalse);
    });
    test('DateTime input works too', () {
      final now = DateTime.utc(2026, 11, 22, 23, 20, 0);
      expect(
          SupaDb.watchLiveViewerRowIsFresh(
              DateTime.utc(2026, 11, 22, 23, 19, 0),
              now: now),
          isTrue);
    });
    test('unparseable / null last_seen is stale, never counted', () {
      expect(SupaDb.watchLiveViewerRowIsFresh(null), isFalse);
      expect(SupaDb.watchLiveViewerRowIsFresh('not-a-date'), isFalse);
      expect(SupaDb.watchLiveViewerRowIsFresh(12345), isFalse);
    });
  });

  group('heartbeat / count / leave — fixture seam', () {
    setUp(() {
      SupaDb.testFixtures = <String, List<Map<String, dynamic>>>{};
    });

    tearDown(() {
      SupaDb.testFixtures = null;
    });

    test('heartbeat inserts one row, second beat upserts (still one row)',
        () async {
      expect(
          await SupaDb.heartbeatWatchLiveViewer(
              tournamentId: 't1', viewerKey: 'k1'),
          isTrue);
      expect(
          await SupaDb.heartbeatWatchLiveViewer(
              tournamentId: 't1', viewerKey: 'k1'),
          isTrue);
      final rows = SupaDb.testFixtures!['watch_live_viewers']!;
      expect(rows.length, 1);
      expect(rows.first['tournament_id'], 't1');
      expect(rows.first['viewer_key'], 'k1');
      expect(rows.first['last_seen'], isNotEmpty);
    });

    test('different keys are different viewers (one row each)', () async {
      await SupaDb.heartbeatWatchLiveViewer(
          tournamentId: 't1', viewerKey: 'k1');
      await SupaDb.heartbeatWatchLiveViewer(
          tournamentId: 't1', viewerKey: 'k2');
      expect(SupaDb.testFixtures!['watch_live_viewers']!.length, 2);
      expect(await SupaDb.getWatchLiveViewerCount('t1'), 2);
    });

    test('empty tournament / key heartbeats fail (false, no row)', () async {
      expect(
          await SupaDb.heartbeatWatchLiveViewer(
              tournamentId: '', viewerKey: 'k1'),
          isFalse);
      expect(
          await SupaDb.heartbeatWatchLiveViewer(
              tournamentId: 't1', viewerKey: ''),
          isFalse);
      expect(SupaDb.testFixtures!['watch_live_viewers'], isNull);
    });

    test('count filters by tournament_id', () async {
      SupaDb.testFixtures!['watch_live_viewers'] = [
        {
          'tournament_id': 't1',
          'viewer_key': 'a',
          'last_seen': _isoSecondsAgo(5)
        },
        {
          'tournament_id': 't1',
          'viewer_key': 'b',
          'last_seen': _isoSecondsAgo(10)
        },
        {
          'tournament_id': 't2',
          'viewer_key': 'c',
          'last_seen': _isoSecondsAgo(5)
        },
      ];
      expect(await SupaDb.getWatchLiveViewerCount('t1'), 2);
      expect(await SupaDb.getWatchLiveViewerCount('t2'), 1);
      expect(await SupaDb.getWatchLiveViewerCount('t3'), 0);
    });

    test('stale rows (older than 90 s) are excluded from the count',
        () async {
      SupaDb.testFixtures!['watch_live_viewers'] = [
        {
          'tournament_id': 't1',
          'viewer_key': 'fresh1',
          'last_seen': _isoSecondsAgo(10)
        },
        {
          'tournament_id': 't1',
          'viewer_key': 'fresh2',
          'last_seen': _isoSecondsAgo(89)
        },
        {
          'tournament_id': 't1',
          'viewer_key': 'stale',
          'last_seen': _isoMinutesAgo(2)
        },
      ];
      expect(await SupaDb.getWatchLiveViewerCount('t1'), 2);
    });

    test('leave deletes only its own row', () async {
      SupaDb.testFixtures!['watch_live_viewers'] = [
        {
          'tournament_id': 't1',
          'viewer_key': 'mine',
          'last_seen': _isoSecondsAgo(5)
        },
        {
          'tournament_id': 't1',
          'viewer_key': 'other',
          'last_seen': _isoSecondsAgo(5)
        },
        {
          'tournament_id': 't2',
          'viewer_key': 'mine',
          'last_seen': _isoSecondsAgo(5)
        },
      ];
      await SupaDb.leaveWatchLiveViewer(
          tournamentId: 't1', viewerKey: 'mine');
      final rows = SupaDb.testFixtures!['watch_live_viewers']!;
      expect(rows.length, 2);
      expect(
          rows.any((r) =>
              r['tournament_id'] == 't1' && r['viewer_key'] == 'mine'),
          isFalse);
      expect(
          rows.any((r) =>
              r['tournament_id'] == 't1' && r['viewer_key'] == 'other'),
          isTrue);
      expect(
          rows.any((r) =>
              r['tournament_id'] == 't2' && r['viewer_key'] == 'mine'),
          isTrue);
    });

    test('leave with empty key / tournament is a no-op', () async {
      SupaDb.testFixtures!['watch_live_viewers'] = [
        {
          'tournament_id': 't1',
          'viewer_key': 'k1',
          'last_seen': _isoSecondsAgo(5)
        },
      ];
      await SupaDb.leaveWatchLiveViewer(tournamentId: '', viewerKey: 'k1');
      await SupaDb.leaveWatchLiveViewer(tournamentId: 't1', viewerKey: '');
      expect(SupaDb.testFixtures!['watch_live_viewers']!.length, 1);
    });
  });

  group('FIX 8 source pins — poll is the count source, always', () {
    test('presence sync never writes the displayed count', () {
      final src = _read('lib/screens/watch_live_screen.dart');
      expect(
          src.contains(
              '_inAppViewers = _presenceChannel?.presenceState().length'),
          isFalse);
    });
    test('screen starts polling in _setupWatchLiveExtras', () {
      final src = _read('lib/screens/watch_live_screen.dart');
      expect(src.contains('_startViewerPolling()'), isTrue);
      expect(src.contains('Timer.periodic'), isTrue);
      expect(
          src.contains('SupaDb.watchLiveViewerHeartbeatSeconds'), isTrue);
    });
    test('dispose cancels the viewer timer and deletes the own row', () {
      final src = _read('lib/screens/watch_live_screen.dart');
      expect(src.contains('_viewerTimer?.cancel()'), isTrue);
      expect(src.contains('leaveWatchLiveViewer('), isTrue);
    });
  });

  group('WatchLiveScreen viewer polling widget', () {
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
      SupaDb.testFixtures = {
        // FIX 20 (fix 20): the tournaments row the total-views
        // read needs (else the total line shows "—" in these
        // tests too, which is correct behaviour, not a failure).
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
            'message': 'GG!',
            'created_at': '2026-11-21T10:00:00Z',
          },
        ],
        'watch_live_viewers': [
          {
            'tournament_id': 't1',
            'viewer_key': 'other1',
            'last_seen': _isoSecondsAgo(10)
          },
          {
            'tournament_id': 't1',
            'viewer_key': 'other2',
            'last_seen': _isoSecondsAgo(20)
          },
          {
            'tournament_id': 't1',
            'viewer_key': 'gone',
            'last_seen': _isoMinutesAgo(2)
          },
          {
            'tournament_id': 't2',
            'viewer_key': 'elsewhere',
            'last_seen': _isoSecondsAgo(10)
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
      // Let the fixture futures settle: the YouTube-key read,
      // the heartbeat upsert, the count query and the likes load
      // are a chain of several async hops before the first count
      // lands (4 pumps is ample; pumpAndSettle would hang on the
      // screen's periodic timers).
      await tester.pump();
      await tester.pump();
      await tester.pump();
      await tester.pump();
    }

    List<Map<String, dynamic>> viewerRows(String tournamentId) =>
        (SupaDb.testFixtures!['watch_live_viewers'] ?? [])
            .where((r) => r['tournament_id'] == tournamentId)
            .toList();

    testWidgets(
        'IN APP display removed (FIX 22 item 3) — heartbeat still writes this screen\'s row',
        (tester) async {
      await pumpScreen(tester);
      // FIX 22 item 3 (user order 2026-11-23): the IN APP
      // count is GONE from the display — and with it the count
      // query. The heartbeat upsert still runs (the server-side
      // presence other viewers rely on depends on it).
      // Nothing on screen may show the stat anymore.
      expect(find.text('IN APP'), findsNothing);
      // The heartbeat still wrote this screen's row: 3 fixture
      // rows for t1 (incl. the stale 'gone' row — the list is
      // raw) + 1 own row.
      expect(viewerRows('t1').length, 4);
      // The total-views line still shows the fixture total.
      expect(find.text('1.2K'), findsOneWidget);
    });

    testWidgets(
        'viewer key is stable across heartbeats (one row per screen)',
        (tester) async {
      await pumpScreen(tester);
      final first = viewerRows('t1');
      // 3 fixture rows (incl. the stale one — the list is raw,
      // freshness is a count-time filter) + 1 own row.
      expect(first.length, 4);
      final ownKey = first
          .firstWhere((r) =>
              r['viewer_key'] != 'other1' && r['viewer_key'] != 'other2' && r['viewer_key'] != 'gone')['viewer_key'];
      // Two more 30 s ticks: still exactly one own row, same key.
      await tester.pump(const Duration(seconds: 31));
      await tester.pump();
      await tester.pump(const Duration(seconds: 31));
      await tester.pump();
      final after = viewerRows('t1');
      expect(
          after.where((r) => r['viewer_key'] == ownKey).length, 1);
      expect(after.length, 4);
    });

    testWidgets('30 s tick re-heartbeats, 15 s does not (FIX 22 item 3)',
        (tester) async {
      await pumpScreen(tester);
      // FIX 22 item 3 removed the IN APP count display (and its
      // query) — the 30 s tick's observable work now is the
      // heartbeat re-upsert (last_seen refresh) + the total
      // refresh. Pin the timing on the own row's last_seen.
      String ownLastSeen() {
        final rows = viewerRows('t1');
        final own = rows.firstWhere((r) =>
            r['viewer_key'] != 'other1' &&
            r['viewer_key'] != 'other2' &&
            r['viewer_key'] != 'gone');
        return own['last_seen'] as String;
      }

      final atStart = ownLastSeen();
      // Change the fixture total: only the 30 s tick reloads
      // it, so the display must not move before the tick.
      SupaDb.testFixtures!['tournaments'] = [
        {'id': 't1', 'watch_views': 2500},
      ];
      // 15 s: no tick yet — last_seen is untouched and the
      // total still shows the old value.
      await tester.pump(const Duration(seconds: 15));
      await tester.pump();
      expect(ownLastSeen(), atStart);
      expect(find.text('1.2K'), findsOneWidget);
      // Past 30 s: the tick fires — the heartbeat re-upserts
      // (last_seen refreshed; DateTime.now() is real wall time
      // under flutter_test, so the strings differ only in
      // milliseconds — but they DO differ) and the total
      // reloads to the new fixture value.
      await tester.pump(const Duration(seconds: 16));
      await tester.pump();
      expect(ownLastSeen(), isNot(atStart));
      expect(find.text('2.5K'), findsOneWidget);
      expect(find.text('1.2K'), findsNothing);
    });

    testWidgets(
        'total-views failure reads "—", never 0 and never stale (FIX 22 item 3)',
        (tester) async {
      await pumpScreen(tester);
      // The total loads from the fixture first.
      expect(find.text('1.2K'), findsOneWidget);
      expect(find.text('IN APP'), findsNothing);
      // Simulate the table / connection going away: no fixtures
      // means the live path, which has no Supabase client under
      // test — the total read throws.
      SupaDb.testFixtures = null;
      await tester.pump(const Duration(seconds: 31));
      await tester.pump();
      // FIX 22 item 3: the IN APP stat is gone, so the total
      // line is the one that must read "—" on failure — never
      // 0, never the stale 1.2K.
      final totalRow = find.byWidgetPredicate((w) =>
          w is Row &&
          w.children.any((c) => c is Text && c.data == 'total views'));
      expect(find.descendant(of: totalRow, matching: find.text('—')),
          findsOneWidget);
      expect(find.text('1.2K'), findsNothing);
    });

    testWidgets('dispose deletes this screen\'s own row', (tester) async {
      await pumpScreen(tester);
      final before = viewerRows('t1');
      expect(before.length, 4);
      final ownKey = before
          .firstWhere((r) =>
              r['viewer_key'] != 'other1' && r['viewer_key'] != 'other2' && r['viewer_key'] != 'gone')['viewer_key'];
      // Dispose the screen by pumping a different widget.
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pump();
      final after = viewerRows('t1');
      expect(
          after.any((r) => r['viewer_key'] == ownKey), isFalse);
      // The other viewers' rows are untouched.
      expect(after.length, 3);
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
