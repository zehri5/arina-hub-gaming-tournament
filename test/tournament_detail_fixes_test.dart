// TOURNAMENT DETAILS FIXES (2026-11-21, user FINAL 8-item list +
// standing rule: NOTHING on this screen may be hidden, cut or
// broken) — unit tests for the display sanitisers + widget tests
// pumping the REAL TournamentDetailPage at 360x800 with fixture
// data via the SupaDb.testFixtures seam and a fake Firebase Auth
// (platform-interface fakes, same pattern as
// home_empty_fix_test.dart). No network, no live DB.
//
// Covered:
//   1. tags chips below Tournament Rules are GONE (no Chip),
//   2. MATCH INFO shows Map "Erangel" (from the "Erangle" tag),
//      Perspective "TPP" (NULL default), Team Size "4 Players",
//   3. display mapping Erangle -> Erangel (case-insensitive),
//   4. no truncated/broken words ("4 Players" maxLines 2,
//      "Match Starts" label inside a FittedBox),
//   5. JOIN button label "JOIN TOURNAMENT",
//   6. SCHEDULE labels separate ("Lobby Opens" / "Match Starts"),
//   7. dummy description "test description" -> "No description
//      added yet",
//   8. bottom stats card + scroll bottom padding (32px) so the
//      Prize / Entry Fee / Spots / Per Kill card scrolls fully
//      above the bottom bar.
import 'package:firebase_core/firebase_core.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_auth_platform_interface/firebase_auth_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/screens/home_screens.dart';
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

// ---------- fixtures: the live Pro Tour shape ----------

const _uid = 'test-uid';

/// Pro Tour as it stands live: tags ["Squad", "Erangle"],
/// map/perspective columns NULL, description "test description".
Map<String, dynamic> _proTourFixture() {
  final now = DateTime.now().millisecondsSinceEpoch;
  const hour = 60 * 60 * 1000;
  return {
    'id': 'pro-tour',
    'name': 'Pro Tour',
    'status': 'upcoming',
    'start_time': now + 2 * hour,
    'banner_url': '',
    'mode': 'Squad',
    'max_players': 64,
    'entry_fee': 100,
    'prize_pool': 10000,
    'per_kill_prize': 50,
    'game_name': 'PUBG Mobile',
    'description': 'test description',
    'tags': ['Squad', 'Erangle'],
    'rules': 'No cheating.\nBe on time.',
  };
}

Map<String, List<Map<String, dynamic>>> _detailFixtures() => {
      'profiles': [
        {
          'firebase_uid': _uid,
          'display_name': 'Test Player',
          'level': 5,
          'photo_url': '',
          'last_checked_notifications': 0
        },
      ],
      'tournaments': [_proTourFixture()],
      'tournament_registrations': <Map<String, dynamic>>[],
      'sliders': <Map<String, dynamic>>[],
      'promotions': <Map<String, dynamic>>[],
      'ads': <Map<String, dynamic>>[],
      'notifications': <Map<String, dynamic>>[],
      'user_notifications': <Map<String, dynamic>>[],
    };

Future<void> _pumpDetail(WidgetTester tester) async {
  tester.view.physicalSize = const Size(360, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: TournamentDetailPage(tournament: _proTourFixture()),
    ),
  );
  // Let the fixture streams emit. (No pumpAndSettle: the rotating
  // MockupCard shines never settle.)
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

  // ---------- fix 7: description sanitiser (pure) ----------

  group('displayTournamentDescription', () {
    test('empty and whitespace-only -> placeholder', () {
      expect(displayTournamentDescription(''), 'No description added yet');
      expect(displayTournamentDescription('   '), 'No description added yet');
      expect(displayTournamentDescription('\n\t '), 'No description added yet');
    });

    test('live dummy "test description" (any case) -> placeholder', () {
      expect(displayTournamentDescription('test description'),
          'No description added yet');
      expect(displayTournamentDescription('Test Description'),
          'No description added yet');
      expect(displayTournamentDescription('TEST DESCRIPTION'),
          'No description added yet');
      expect(displayTournamentDescription('  test description  '),
          'No description added yet');
    });

    test('other dummy values -> placeholder', () {
      for (final d in [
        'test',
        'Test',
        'lorem ipsum',
        'Lorem ipsum dolor sit amet',
        'lorem',
        'dummy',
        'TBD',
        'coming soon',
        'n/a',
      ]) {
        expect(displayTournamentDescription(d), 'No description added yet',
            reason: 'dummy: $d');
      }
    });

    test('real description passes through untouched', () {
      expect(displayTournamentDescription('Weekly squad showdown.'),
          'Weekly squad showdown.');
      expect(displayTournamentDescription('  Real text with spaces.  '),
          'Real text with spaces.');
    });
  });

  // ---------- fix 3: Erangle -> Erangel mapping (pure) ----------

  group('displayMapName', () {
    test('Erangle (any case) -> Erangel', () {
      expect(displayMapName('Erangle'), 'Erangel');
      expect(displayMapName('ERANGLE'), 'Erangel');
      expect(displayMapName('erangle'), 'Erangel');
      expect(displayMapName('  Erangle  '), 'Erangel');
    });

    test('other map names pass through untouched', () {
      expect(displayMapName('Miramar'), 'Miramar');
      expect(displayMapName('Sanhok'), 'Sanhok');
      expect(displayMapName('Livik'), 'Livik');
      expect(displayMapName(''), '');
    });
  });

  // ---------- fix 2: MATCH INFO value derivation (pure) ----------

  group('matchInfo helpers', () {
    test('map comes from the tags when the column is NULL', () {
      expect(matchInfoMapName({'tags': ['Squad', 'Erangle']}), 'Erangel');
      expect(matchInfoMapName({'tags': ['Miramar']}), 'Miramar');
    });

    test('map column wins over tags', () {
      expect(matchInfoMapName({'map': 'Sanhok', 'tags': ['Erangle']}),
          'Sanhok');
    });

    test('no map anywhere -> PUBG default Erangel, never a dash', () {
      expect(matchInfoMapName({'tags': ['Squad']}), 'Erangel');
      expect(matchInfoMapName({}), 'Erangel');
    });

    test('perspective NULL -> TPP default; tag wins', () {
      expect(matchInfoPerspective({}), 'TPP');
      expect(matchInfoPerspective({'tags': ['Squad']}), 'TPP');
      expect(matchInfoPerspective({'tags': ['FPP']}), 'FPP');
      expect(matchInfoPerspective({'perspective': 'FPP'}), 'FPP');
    });

    test('team size label is the full "N Players"', () {
      expect(matchInfoTeamSizeLabel({'mode': 'Squad'}), '4 Players');
      expect(matchInfoTeamSizeLabel({'mode': 'Duo'}), '2 Players');
      expect(matchInfoTeamSizeLabel({'mode': 'Solo'}), '1 Players');
    });
  });

  // ---------- widget tests: the real detail page ----------

  group('TournamentDetailPage (Pro Tour fixture)', () {
    testWidgets('FIX 1 — no Squad/Erangle chips below Tournament Rules',
        (tester) async {
      SupaDb.testFixtures = _detailFixtures();
      await _pumpDetail(tester);
      expect(find.byType(Chip), findsNothing);
      expect(find.text('Erangle'), findsNothing);
      // (The hero info strip still shows the mode word "Squad" —
      // that is real tournament data, not a tag chip.)
    });

    testWidgets('FIX 2 — MATCH INFO shows Erangel / TPP / 4 Players',
        (tester) async {
      SupaDb.testFixtures = _detailFixtures();
      await _pumpDetail(tester);
      expect(find.text('Erangel'), findsOneWidget);
      expect(find.text('TPP'), findsOneWidget);
      expect(find.text('4 Players'), findsOneWidget);
      // No dash values left in MATCH INFO.
      expect(find.text('—'), findsNothing);
    });

    testWidgets('FIX 4 — "4 Players" is a 2-line value, never truncated',
        (tester) async {
      SupaDb.testFixtures = _detailFixtures();
      await _pumpDetail(tester);
      final teamSize = tester.widget<Text>(find.text('4 Players'));
      expect(teamSize.maxLines, 2,
          reason: 'maxLines 2 wraps at the word boundary; maxLines 1 + '
              'ellipsis rendered "4 Pla..."');
      expect(teamSize.overflow, TextOverflow.ellipsis);
    });

    testWidgets('FIX 5 — JOIN button reads JOIN TOURNAMENT', (tester) async {
      SupaDb.testFixtures = _detailFixtures();
      await _pumpDetail(tester);
      expect(find.text('JOIN TOURNAMENT  ›'), findsOneWidget);
      expect(find.text('JOIN COMMUNITY EVENT  ›'), findsNothing);
    });

    testWidgets('FIX 6 — SCHEDULE labels are separate, shrink-to-fit',
        (tester) async {
      SupaDb.testFixtures = _detailFixtures();
      await _pumpDetail(tester);
      expect(find.text('Lobby Opens'), findsOneWidget);
      expect(find.text('Match Starts'), findsOneWidget);
      // Both labels sit inside a FittedBox(scaleDown): they shrink
      // instead of breaking mid-word ("Perspec tive" class of bug).
      for (final label in ['Lobby Opens', 'Match Starts']) {
        expect(
            find.ancestor(
                of: find.text(label), matching: find.byType(FittedBox)),
            findsOneWidget,
            reason: '$label must be inside a FittedBox');
      }
    });

    testWidgets('FIX 7 — dummy description shows the placeholder',
        (tester) async {
      SupaDb.testFixtures = _detailFixtures();
      await _pumpDetail(tester);
      expect(find.text('No description added yet'), findsOneWidget);
      expect(find.text('test description'), findsNothing);
      expect(find.text('TOURNAMENT OVERVIEW'), findsOneWidget);
    });

    testWidgets('FIX 8 — bottom stats card + 32px scroll bottom padding',
        (tester) async {
      SupaDb.testFixtures = _detailFixtures();
      await _pumpDetail(tester);
      for (final label in ['Prize', 'Entry Fee', 'Spots', 'Per Kill']) {
        expect(find.text(label), findsOneWidget, reason: 'stat: $label');
      }
      // Full amounts, never truncated ("Rs 10000.00" is wider than
      // one stat cell at 13px).
      expect(find.text('Rs 10000.00'), findsOneWidget);
      expect(find.text('Rs 100.00'), findsOneWidget);
      final scroll = tester.widget<SingleChildScrollView>(
          find.byType(SingleChildScrollView));
      final padding = scroll.padding as EdgeInsets;
      expect(padding.bottom, greaterThanOrEqualTo(32),
          reason: 'content must scroll fully above the bottom bar');
      // Stat values wrap instead of truncating.
      final prize = tester.widget<Text>(find.text('Rs 10000.00'));
      expect(prize.maxLines, 2);
    });
  });
}
