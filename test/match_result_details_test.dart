// MATCH RESULT DETAILS (2026-11-21, mockup #16 printer-copy) —
// widget tests pumping the REAL MatchResultDetailsPage at 360x800
// with fixture data via the SupaDb.testFixtures seam and a fake
// Firebase Auth (same pattern as tournament_detail_fixes_test.dart).
// No network, no live DB.
//
// Covered (mockup structure, REAL fixture data — never the mockup's
// sample values as data; the fixture numbers differ from the mockup
// on purpose: 16 pts / 6+4+3+2 kills / 4 assists / 28:45):
//   1. victory card: '#1 VICTORY' + '1st PLACE', team name,
//      TOTAL POINTS = place points (1st=10) + kills, squad grid 2x2
//      with real names + kills,
//   2. PERFORMANCE SUMMARY: Kills = TEAM total, Assists + Duration
//      from the player's tournament_results row, Damage formatted,
//   3. RESULT VERIFIED pill + banner show ONLY when the tournament
//      status is 'result' (gated on/off),
//   4. MATCH TIMELINE built ONLY from real data: match start
//      (played_at + map, Erangle -> Erangel display) + match finish
//      (duration_seconds); no invented wipe events, no mock text,
//   5. Solo grid: one cell spans the full width (crossAxisCount 1),
//      honest '—' for missing assists/duration,
//   6. canonical page: MatchSummaryPage redirects to
//      MatchResultDetailsPage when the viewer has a result, and
//      says so honestly when they do not (no duplicate screen).
import 'package:firebase_core/firebase_core.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_auth_platform_interface/firebase_auth_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/screens/more_screens.dart';
import 'package:protournament_user/screens/pro_features.dart';
import 'package:protournament_user/services/supabase_db.dart';

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

// ---------- fixtures (raw snake_case rows, as PostgREST returns them) ----------

const _uid = 'test-uid';
final _playedMs = DateTime(2026, 11, 22, 20, 0).millisecondsSinceEpoch;

Map<String, dynamic> _tournament({String status = 'result', String mode = 'Squad'}) => {
      'id': 't1',
      'name': 'Weekend Community Cup',
      'status': status,
      'start_time': _playedMs,
      'banner_url': '',
      'mode': mode,
      'map': 'Erangle',
      'max_players': 100,
      'entry_fee': 100,
      'prize_pool': 5000,
      'game_name': 'PUBG Mobile',
    };

Map<String, dynamic> _history({int rank = 1, int kills = 6, int damage = 3450}) => {
      'tournament_id': 't1',
      'tournamentName': 'Weekend Community Cup',
      'name': 'Weekend Community Cup',
      'rank': rank,
      'kills': kills,
      'damage': damage,
      'winnings': 120,
      'timestamp': _playedMs,
    };

List<Map<String, dynamic>> _squadRegs() => [
      {'tournament_id': 't1', 'firebase_uid': _uid, 'username': 'Player', 'team_name': 'Team Alpha', 'kills': 6, 'rank': 1},
      {'tournament_id': 't1', 'firebase_uid': 'uid-2', 'username': 'Venom', 'team_name': 'Team Alpha', 'kills': 4, 'rank': 1},
      {'tournament_id': 't1', 'firebase_uid': 'uid-3', 'username': 'Blaze', 'team_name': 'Team Alpha', 'kills': 3, 'rank': 1},
      {'tournament_id': 't1', 'firebase_uid': 'uid-4', 'username': 'Shadow', 'team_name': 'Team Alpha', 'kills': 2, 'rank': 1},
    ];

Map<String, List<Map<String, dynamic>>> _fixtures({
  String status = 'result',
  String mode = 'Squad',
  List<Map<String, dynamic>>? regs,
  List<Map<String, dynamic>>? results,
  List<Map<String, dynamic>>? history,
}) => {
      'profiles': [
        {'firebase_uid': _uid, 'display_name': 'Player', 'level': 5, 'photo_url': ''},
        {'firebase_uid': 'uid-2', 'display_name': 'Venom', 'level': 3, 'photo_url': ''},
        {'firebase_uid': 'uid-3', 'display_name': 'Blaze', 'level': 2, 'photo_url': ''},
        {'firebase_uid': 'uid-4', 'display_name': 'Shadow', 'level': 4, 'photo_url': ''},
      ],
      'tournaments': [_tournament(status: status, mode: mode)],
      'tournament_registrations': regs ?? _squadRegs(),
      'tournament_results': results ??
          [
            {'tournament_id': 't1', 'firebase_uid': _uid, 'assists': 4, 'duration_seconds': 1725},
          ],
      'match_history': history ??
          [
            {'id': 'h1', 'firebase_uid': _uid, 'tournament_id': 't1', 'tournament_name': 'Weekend Community Cup', 'rank': 1, 'kills': 6, 'damage': 3450, 'earnings': 120, 'played_at': _playedMs},
          ],
    };

Future<void> _pumpPage(WidgetTester tester, Widget page) async {
  tester.view.physicalSize = const Size(360, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(home: page));
  // Let the fixture reads land. (No pumpAndSettle: the rotating
  // MockupCard shines never settle.)
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
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
    SupaDb.testFixtures = null;
  });

  tearDown(() {
    SupaDb.testFixtures = null;
  });

  group('MatchResultDetailsPage (mockup #16)', () {
    testWidgets('victory card: points, place, team, 2x2 squad grid',
        (tester) async {
      SupaDb.testFixtures = _fixtures();
      await _pumpPage(tester, MatchResultDetailsPage(history: _history(), uid: _uid));

      expect(find.text('MATCH RESULT DETAILS'), findsOneWidget);
      // v2011: the title is a two-tone RichText (first word gold,
      // rest white, mockup #16) — the finder must look into rich
      // text, not just Text widgets.
      expect(find.textContaining('WEEKEND', findRichText: true), findsOneWidget);
      // Locked scoring: 1st place = 10 pts + 6 kills = 16.
      expect(find.text('TOTAL POINTS: 16'), findsOneWidget);
      expect(find.text('10 Place • 6 Kills'), findsOneWidget);
      expect(find.text('#1 VICTORY'), findsOneWidget);
      expect(find.text('1st PLACE'), findsOneWidget);
      expect(find.text('Team Alpha'), findsOneWidget);
      expect(find.text('YOUR TEAM'), findsOneWidget);
      // Squad grid: real names + real kills each.
      expect(find.text('Player (You)'), findsOneWidget);
      expect(find.text('Venom'), findsOneWidget);
      expect(find.text('Blaze'), findsOneWidget);
      expect(find.text('Shadow'), findsOneWidget);
      expect(find.text('6 Kills'), findsOneWidget);
      expect(find.text('4 Kills'), findsOneWidget);
      expect(find.text('3 Kills'), findsOneWidget);
      expect(find.text('2 Kills'), findsOneWidget);
      // Buttons (mockup #16 labels).
      // v2011: the buttons sit below the fold and the ListView
      // builds lazily — scroll them into view first (the squad GridView
      // is a second Scrollable on this page, so the outer one
      // (.first) must be named or scrollUntilVisible throws).
      await tester.scrollUntilVisible(
        find.text('VIEW TOURNAMENT LEADERBOARD'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pump();
      expect(find.text('VIEW TOURNAMENT LEADERBOARD'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('REPORT RESULT ISSUE'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pump();
      expect(find.text('REPORT RESULT ISSUE'), findsOneWidget);
    });

    testWidgets('performance summary: team kills, real assists/duration',
        (tester) async {
      SupaDb.testFixtures = _fixtures();
      await _pumpPage(tester, MatchResultDetailsPage(history: _history(), uid: _uid));

      expect(find.text('PERFORMANCE SUMMARY'), findsOneWidget);
      // Kills box is the TEAM total: 6+4+3+2 = 15.
      expect(find.text('15'), findsOneWidget);
      // Assists + Duration from the player's tournament_results row.
      expect(find.text('4'), findsOneWidget);
      expect(find.text('3,450'), findsOneWidget);
      expect(find.text('28:45'), findsWidgets);
    });

    testWidgets('RESULT VERIFIED shows only when status is result',
        (tester) async {
      SupaDb.testFixtures = _fixtures(status: 'result');
      await _pumpPage(tester, MatchResultDetailsPage(history: _history(), uid: _uid));
      // Pill + banner.
      expect(find.text('RESULT VERIFIED'), findsWidgets);
      // v2011: the banner sits below the fold and the ListView
      // builds lazily — scroll it into view first (outer Scrollable
      // (.first) named: the squad GridView is a second Scrollable).
      await tester.scrollUntilVisible(
        find.text('Verified by Arena Hub Officials'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pump();
      expect(find.text('Verified by Arena Hub Officials'), findsOneWidget);

      SupaDb.testFixtures = _fixtures(status: 'upcoming');
      // v2011: a plain re-pump REUSES the old State (same type, same
      // tree position) — initState/_load never re-run, so the page
      // would keep the first pump's 'result' data and the banner.
      // A UniqueKey forces a fresh State that loads the new
      // 'upcoming' fixtures.
      await _pumpPage(tester, MatchResultDetailsPage(key: UniqueKey(), history: _history(), uid: _uid));
      expect(find.text('RESULT VERIFIED'), findsNothing);
      expect(find.text('Verified by Arena Hub Officials'), findsNothing);
      expect(find.text('COMPLETED'), findsOneWidget);
    });

    testWidgets('timeline: real start + finish only, never invented',
        (tester) async {
      SupaDb.testFixtures = _fixtures();
      await _pumpPage(tester, MatchResultDetailsPage(history: _history(), uid: _uid));

      expect(find.text('MATCH TIMELINE'), findsOneWidget);
      expect(find.text('00:00'), findsOneWidget);
      // Map column 'Erangle' displays as 'Erangel'.
      expect(find.text('Match Started on Erangel'), findsOneWidget);
      expect(find.text('Match Won — 1st Place'), findsOneWidget);
      // Mockup sample events are layout-only: never rendered as data.
      expect(find.text('Team Bravo Wiped'), findsNothing);
      expect(find.textContaining('Chicken Dinner'), findsNothing);
      expect(find.text('No timeline was recorded for this match.'), findsNothing);
    });

    testWidgets('solo: one full-width cell, honest dashes, start-only timeline',
        (tester) async {
      SupaDb.testFixtures = _fixtures(
        mode: 'Solo',
        regs: [
          {'tournament_id': 't1', 'firebase_uid': _uid, 'username': 'Player', 'team_name': 'Player', 'kills': 5, 'rank': 2},
        ],
        results: <Map<String, dynamic>>[],
      );
      await _pumpPage(tester, MatchResultDetailsPage(history: _history(rank: 2, kills: 5), uid: _uid));

      // 2nd place = 7 pts + 5 kills = 12.
      expect(find.text('TOTAL POINTS: 12'), findsOneWidget);
      expect(find.text('7 Place • 5 Kills'), findsOneWidget);
      expect(find.text('#2'), findsOneWidget);
      // One cell spans the full width (crossAxisCount 1, not 2).
      final grid = tester.widget<GridView>(find.byType(GridView));
      final delegate = grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
      expect(delegate.crossAxisCount, 1);
      // No result row -> assists + duration are honest dashes.
      expect(find.text('—'), findsWidgets);
      // Timeline has only the start event (no duration to finish with).
      expect(find.text('00:00'), findsOneWidget);
      expect(find.text('Match Started on Erangel'), findsOneWidget);
      expect(find.textContaining('Match Won'), findsNothing);
      expect(find.textContaining('Match Finished'), findsNothing);
    });
  });

  group('MatchSummaryPage canonical redirect', () {
    testWidgets('redirects to MatchResultDetailsPage when a result exists',
        (tester) async {
      SupaDb.testFixtures = _fixtures();
      await _pumpPage(tester, MatchSummaryPage(tournament: _tournament()));
      expect(find.text('#1 VICTORY'), findsOneWidget);
      expect(find.text('TOTAL POINTS: 16'), findsOneWidget);
    });

    testWidgets('honest empty state when the viewer has no result',
        (tester) async {
      SupaDb.testFixtures = _fixtures(history: <Map<String, dynamic>>[]);
      await _pumpPage(tester, MatchSummaryPage(tournament: _tournament()));
      expect(find.text('No match result yet'), findsOneWidget);
      expect(find.text('#1 VICTORY'), findsNothing);
    });
  });
}
