// FIX 6 UPGRADE (2026-11-21) — REAL render tests for HomePage.
//
// v2005 PROOF: the 01:51 screenshot (1000049121_48_c19q.jpg) showed
// Home with ONLY the "Your Next Match" bar at the top and a black
// void below — no hero, no tournaments, no sliders — while the
// Events tab in the same build showed all tournaments and the live
// DB audit proved the data is there (6 upcoming tournaments,
// sliders, promotions, ads, permissive RLS). These tests pump the
// REAL HomePage (not a geometry replica) at a real device size
// (360x800) with fixture data via the SupaDb.testFixtures seam and
// a fake Firebase Auth (platform-interface fakes, no network, no
// firebase_auth_mocks dependency), and prove:
//   1. hero + sliders + latest-3 tournament cards render,
//   2. the Next Match VS bar sits at the BOTTOM above the bottom
//      nav (not the top — the v2005 signature),
//   3. the scroll view has real height (the v2005 bug gave it 0px),
//   4. the genuinely-empty case shows the branded empty state,
//      never a void,
//   5. pull-to-refresh actually reloads (fixture swap -> new data),
//   6. dead/empty banner URLs render the bundled trophy fallback,
//      never a black slot.
//
// NOTE on CachedNetworkImage in tests: flutter_cache_manager's
// sqflite/path_provider backend never resolves in a widget test,
// so a dead URL stays on its placeholder forever (verified by
// probe). That is FINE here: _HomeCoverImage uses the SAME
// _fallback() widget (bundled trophy_cover.jpg) for its placeholder
// AND its errorWidget, so placeholder coverage == error coverage
// for the widget under test. Fixture banners are therefore a mix
// of empty (immediate fallback, no network attempt) and dead URLs
// (placeholder fallback).
import 'package:firebase_core/firebase_core.dart';
// Platform-interface fakes (transitive deps of firebase_auth /
// firebase_core; the direct packages do NOT re-export the platform
// types, so these imports are intentional).
// ignore: depend_on_referenced_packages
import 'package:firebase_auth_platform_interface/firebase_auth_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/screens/home_screens.dart';
import 'package:protournament_user/services/supabase_db.dart';

// ---------- fake Firebase (platform-interface fakes) ----------

class _FakeAppPlatform extends FirebaseAppPlatform {
  _FakeAppPlatform(super.name, super.options);
}

class _FakeCorePlatform extends FirebasePlatform {
  FirebaseAppPlatform? _app;

  @override
  Future<FirebaseAppPlatform> initializeApp({String? name, FirebaseOptions? options}) async {
    _app = _FakeAppPlatform(
      name ?? defaultFirebaseAppName,
      options ?? const FirebaseOptions(apiKey: 'test', appId: '1:1:android:1', messagingSenderId: '1', projectId: 'test'),
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
  FirebaseAuthPlatform delegateFor({required FirebaseApp app}) => _FakeAuthPlatform(appInstance: app);

  @override
  FirebaseAuthPlatform setInitialValues({PigeonUserDetails? currentUser, String? languageCode}) {
    final uid = currentUser?.userInfo.uid ?? 'test-uid';
    _user = _FakeUser(
      this,
      _FakeMultiFactor(this),
      PigeonUserDetails(userInfo: PigeonUserInfo(uid: uid, isAnonymous: false, isEmailVerified: true), providerData: []),
    );
    return this;
  }

  @override
  UserPlatform? get currentUser => _user;

  @override
  set currentUser(UserPlatform? user) => _user = user;
}

// ---------- fixtures (raw snake_case rows, as PostgREST returns them) ----------

const _uid = 'test-uid';

Map<String, dynamic> _tournament({
  required String id,
  required String name,
  required String status,
  required int startMs,
  String banner = '',
  String mode = 'Squad',
  int maxPlayers = 100,
}) =>
    {
      'id': id,
      'name': name,
      'status': status,
      'start_time': startMs,
      'banner_url': banner,
      'mode': mode,
      'max_players': maxPlayers,
      'entry_fee': 0,
      'prize_pool': 5000,
      'game_name': 'PUBG Mobile',
    };

Map<String, List<Map<String, dynamic>>> _populatedFixtures({bool withSlider = true}) {
  final now = DateTime.now().millisecondsSinceEpoch;
  const hour = 60 * 60 * 1000;
  const day = 24 * hour;
  return {
    'profiles': [
      {'firebase_uid': _uid, 'display_name': 'Test Player', 'level': 5, 'photo_url': '', 'last_checked_notifications': 0},
    ],
    // Home sorts startTime DESC + take(3): Storm, Viper, Falcon.
    // Night Raid (ongoing, earliest start) is the 4th and must NOT
    // appear in Home's latest-3 list (it stays in Events).
    'tournaments': [
      _tournament(id: 't1', name: 'Falcon Cup', status: 'upcoming', startMs: now + 2 * hour),
      _tournament(id: 't2', name: 'Viper Clash', status: 'upcoming', startMs: now + day, banner: 'https://example.invalid/dead.jpg', mode: 'Solo'),
      _tournament(id: 't3', name: 'Storm Arena', status: 'upcoming', startMs: now + 2 * day),
      _tournament(id: 't4', name: 'Night Raid', status: 'ongoing', startMs: now - hour, mode: 'Duo'),
    ],
    'tournament_registrations': [
      {'id': 'r1', 'tournament_id': 't1', 'firebase_uid': _uid, 'team_name': 'Falcons', 'slot_number': 1},
      {'id': 'r2', 'tournament_id': 't2', 'firebase_uid': 'other-uid', 'team_name': 'Vipers', 'slot_number': 1},
      {'id': 'r3', 'tournament_id': 't2', 'firebase_uid': 'other2', 'team_name': 'Cobras', 'slot_number': 2},
    ],
    'sliders': withSlider
        ? [
            {
              'id': 's1',
              'active': true,
              'sort_order': 1,
              'image_url': 'https://example.invalid/slider.jpg',
              'title': 'Slider Title',
              'subtitle': 'Slider subtitle here',
              // No target: with a resolved target tournament the
              // slide shows that tournament's meta row INSTEAD of
              // the subtitle (by design), so the subtitle path is
              // tested with no target; the pill + meta path is
              // covered by the tournament-hero test below.
              'target_type': 'tournament',
              'target_id': '',
            },
          ]
        : <Map<String, dynamic>>[],
    'promotions': [
      {'id': 'p1', 'title': 'Test Promo', 'image_url': 'https://example.invalid/promo.jpg', 'link': ''},
    ],
    'ads': [
      {'id': 'a1', 'active': true, 'title': 'Test Ad', 'image_url': ''},
    ],
    'notifications': <Map<String, dynamic>>[],
    'user_notifications': <Map<String, dynamic>>[],
  };
}

Map<String, List<Map<String, dynamic>>> get _emptyFixtures => {
      'profiles': [
        {'firebase_uid': _uid, 'display_name': 'Test Player', 'level': 5, 'photo_url': '', 'last_checked_notifications': 0},
      ],
      'tournaments': <Map<String, dynamic>>[],
      'tournament_registrations': <Map<String, dynamic>>[],
      'sliders': <Map<String, dynamic>>[],
      'promotions': <Map<String, dynamic>>[],
      'ads': <Map<String, dynamic>>[],
      'notifications': <Map<String, dynamic>>[],
      'user_notifications': <Map<String, dynamic>>[],
    };

/// Matches a [Text] OR a [RichText] (incl. Text.rich spans) whose
/// plain text contains [needle]. Plain find.text() does NOT match
/// Text.rich spans (their Text.data is null) — the pinned bar's
/// "No upcoming match" line is a Text.rich, so it needs this.
Finder _textContaining(String needle) => find.byWidgetPredicate(
      (w) =>
          (w is Text && (w.data?.contains(needle) ?? false)) ||
          (w is RichText && w.text.toPlainText().contains(needle)),
    );

/// The bundled trophy fallback image, wherever it renders.
Finder get _trophyFallback => find.byWidgetPredicate(
      (w) => w is Image && w.image is AssetImage && (w.image as AssetImage).assetName == 'assets/images/trophy_cover.jpg',
    );

Future<void> _pumpHome(WidgetTester tester) async {
  tester.view.physicalSize = const Size(360, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        // Stand-in for HomeShell's bottom nav: the pinned bar must
        // sit directly above this, not at the top of the screen.
        bottomNavigationBar: const SizedBox(height: 64, child: Center(child: Text('NAV'))),
        body: const HomePage(),
      ),
    ),
  );
  // Let the one-shot first-load future + fixture streams emit.
  // (No pumpAndSettle: the repeating shine animations + autoplay
  // timers never settle.)
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    FirebasePlatform.instance = _FakeCorePlatform();
    FirebaseAuthPlatform.instance = _FakeAuthPlatform();
    await Firebase.initializeApp(
      options: const FirebaseOptions(apiKey: 'test', appId: '1:1:android:1', messagingSenderId: '1', projectId: 'test'),
    );
  });

  setUp(() {
    SupaDb.testFixtures = null;
  });

  tearDown(() {
    SupaDb.testFixtures = null;
  });

  testWidgets('FIX 6 — Home renders hero + sliders + latest-3 cards, Next Match bar at the bottom', (tester) async {
    SupaDb.testFixtures = _populatedFixtures();
    await _pumpHome(tester);

    // The v2005 bug gave the scroll view 0px: it must have real height.
    final scroll = find.byType(SingleChildScrollView);
    expect(scroll, findsOneWidget);
    final scrollSize = tester.getSize(scroll);
    expect(scrollSize.height, greaterThan(400));

    // Header + greeting render.
    expect(find.text('Welcome back,'), findsOneWidget);
    expect(find.text('Test Player'), findsOneWidget);

    // HERO: the admin slider slide (dead URL -> trophy fallback
    // placeholder) with its subtitle + VIEW EVENT button. (No
    // REGISTRATION OPEN pill here — the fixture slider has no
    // target tournament; the pill is covered by the tournament-hero
    // test below.)
    expect(find.text('Slider subtitle here'), findsOneWidget);
    expect(find.text('VIEW EVENT'), findsOneWidget);

    // TOURNAMENTS section: latest 3, newest first; the 4th
    // (earliest) tournament stays in Events and must not show.
    expect(find.text('TOURNAMENTS'), findsOneWidget);
    expect(find.text('Storm Arena'), findsOneWidget);
    expect(find.text('Viper Clash'), findsOneWidget);
    expect(find.text('Falcon Cup'), findsWidgets);
    expect(find.text('Night Raid'), findsNothing);
    expect(find.text('No tournaments yet'), findsNothing);

    // Sponsored ad below (empty image -> campaign icon + title).
    expect(find.text('Sponsored'), findsOneWidget);
    expect(find.text('Test Ad'), findsOneWidget);

    // Hero/banner fallback: the bundled trophy asset renders
    // (empty banner + dead-URL banner both fall back to it).
    expect(_trophyFallback, findsWidgets);

    // NEXT MATCH VS BAR — FILLED state (joined Falcon Cup as
    // Falcons): VS + my team + the real tournament name.
    expect(find.text('Your Next Match'), findsOneWidget);
    expect(find.text('VS'), findsOneWidget);
    expect(find.text('Falcons'), findsOneWidget);
    expect(_textContaining('No upcoming match'), findsNothing);

    // (c) PLACEMENT: the bar sits at the BOTTOM, directly above the
    // bottom nav — not at the top (the v2005 signature).
    final barTop = tester.getTopLeft(find.text('Your Next Match')).dy;
    final barBottom = tester.getBottomRight(find.text('Your Next Match')).dy;
    final navTop = tester.getTopLeft(find.text('NAV')).dy;
    expect(barTop, greaterThan(500));
    expect(barBottom, lessThan(navTop));

    // The hero sits at the TOP of the scroll, above the bar.
    final heroTop = tester.getTopLeft(find.text('Slider subtitle here')).dy;
    expect(heroTop, lessThan(400));
    expect(heroTop, lessThan(barTop));

    // Autoplay ticks must NOT blank Home again (FIX 6 stream-churn
    // fix: streams are created once, so a rebuild cannot reset the
    // StreamBuilders to empty).
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Storm Arena'), findsOneWidget);
    expect(find.text('No tournaments yet'), findsNothing);
  });

  testWidgets('FIX 6 — no sliders: hero falls back to featured tournaments', (tester) async {
    SupaDb.testFixtures = _populatedFixtures(withSlider: false);
    await _pumpHome(tester);

    // Tournament hero: earliest upcoming first, REGISTRATION OPEN
    // pill + VIEW EVENT (the title is a two-tone RichText, so the
    // pill + button pin the hero, not the title string).
    expect(find.text('REGISTRATION OPEN'), findsOneWidget);
    expect(find.text('VIEW EVENT'), findsOneWidget);
    expect(find.text('TOURNAMENTS'), findsOneWidget);
    expect(find.text('Storm Arena'), findsOneWidget);
    expect(_trophyFallback, findsWidgets);
  });

  testWidgets('FIX 6 — genuinely empty data shows the branded empty state, never a void', (tester) async {
    SupaDb.testFixtures = _emptyFixtures;
    await _pumpHome(tester);

    final scroll = find.byType(SingleChildScrollView);
    expect(scroll, findsOneWidget);
    expect(tester.getSize(scroll).height, greaterThan(400));

    // Hero fallback card + branded TOURNAMENTS empty state.
    expect(find.text('No upcoming events yet'), findsOneWidget);
    expect(find.text('No tournaments yet'), findsOneWidget);
    expect(find.text('Browse Events'), findsOneWidget);
    expect(find.text('TOURNAMENTS'), findsOneWidget);

    // Pinned bar keeps its header + honest empty line, at the bottom.
    expect(find.text('Your Next Match'), findsOneWidget);
    expect(_textContaining('No upcoming match'), findsOneWidget);
    final barTop = tester.getTopLeft(find.text('Your Next Match')).dy;
    final navTop = tester.getTopLeft(find.text('NAV')).dy;
    expect(barTop, greaterThan(500));
    expect(barTop, lessThan(navTop));
  });

  testWidgets('FIX 6 — pull-to-refresh actually reloads tournaments', (tester) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    const hour = 60 * 60 * 1000;
    SupaDb.testFixtures = {
      'profiles': [
        {'firebase_uid': _uid, 'display_name': 'Test Player', 'level': 5, 'photo_url': '', 'last_checked_notifications': 0},
      ],
      'tournaments': [_tournament(id: 'ta', name: 'Alpha Cup', status: 'upcoming', startMs: now + 2 * hour)],
      'tournament_registrations': <Map<String, dynamic>>[],
      'sliders': <Map<String, dynamic>>[],
      'promotions': <Map<String, dynamic>>[],
      'ads': <Map<String, dynamic>>[],
      'notifications': <Map<String, dynamic>>[],
      'user_notifications': <Map<String, dynamic>>[],
    };
    await _pumpHome(tester);
    expect(find.text('Alpha Cup'), findsWidgets);

    // The backend changes under the app; a pull must pick it up.
    SupaDb.testFixtures = {
      'profiles': [
        {'firebase_uid': _uid, 'display_name': 'Test Player', 'level': 5, 'photo_url': '', 'last_checked_notifications': 0},
      ],
      'tournaments': [_tournament(id: 'tb', name: 'Beta Cup', status: 'upcoming', startMs: now + 3 * hour)],
      'tournament_registrations': <Map<String, dynamic>>[],
      'sliders': <Map<String, dynamic>>[],
      'promotions': <Map<String, dynamic>>[],
      'ads': <Map<String, dynamic>>[],
      'notifications': <Map<String, dynamic>>[],
      'user_notifications': <Map<String, dynamic>>[],
    };
    await tester.fling(find.byType(SingleChildScrollView), const Offset(0, 400), 1000);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(find.text('Beta Cup'), findsWidgets);
    expect(find.text('Alpha Cup'), findsNothing);
  });
}
