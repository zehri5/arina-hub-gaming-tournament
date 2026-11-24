// REGISTRATION UNIFY (2026-11-21, user FINAL spec — one design +
// one system for Solo/Duo/Squad; mockups' per-mode differences
// OVERRIDDEN) — widget tests pumping the REAL JoinTournamentPage
// at 360x800 with fixture data via the SupaDb.testFixtures seam
// and a fake Firebase Auth (platform-interface fakes, same pattern
// as home_empty_fix_test.dart). No network, no live DB.
//
// Side-by-side check (all three modes, same assertions):
//   * header: identical style — upright bold 20 title, gold back
//     chevron, ARENA HUB wordmark top-right (Solo AND Duo too),
//   * banner: same layout — cover, two-tone name, date + mode pill,
//     fee pill (Squad included),
//   * form: the SAME player-card component (Solo 1 card, Duo
//     leader + 1 mate, Squad leader + 3 mates),
//   * slot picker: the SAME component in all three (Duo included —
//     auto-pick ended; Solo's stays optional),
//   * fee pill + confirm button: identical style (labels CONFIRM
//     SOLO / DUO / SQUAD),
//   * only the formula differs: teamSize 1/2/4, mate slots 0/1/3,
//     fee = entryFee x teamSize, slots = maxPlayers / teamSize.
// Solo keeps Preferred Region + the IGN confirm checkbox.
import 'package:firebase_core/firebase_core.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_auth_platform_interface/firebase_auth_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/components/arena_components.dart';
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

// ---------- fixtures ----------

const _uid = 'test-uid';

Map<String, dynamic> _tournamentFixture(String mode) {
  final now = DateTime.now().millisecondsSinceEpoch;
  const hour = 60 * 60 * 1000;
  // v2011: keys in BOTH spellings, exactly as a SupaDb-normalized
  // tournament map carries them in the real app (supabase_db.dart
  // sets both entryFee + entry_fee, startTime + start_time, etc.).
  // The Join page reads the camelCase keys; the old snake_case-only
  // fixture made it read fee 0 and show FREE ENTRY for a Rs 100
  // tournament, so the price pills never rendered.
  return {
    'id': 't-$mode',
    'name': 'Pro Tour',
    'status': 'upcoming',
    'startTime': now + 2 * hour,
    'start_time': now + 2 * hour,
    'bannerUrl': '',
    'banner_url': '',
    'mode': mode,
    'maxPlayers': 64,
    'max_players': 64,
    'entryFee': 100,
    'entry_fee': 100,
    'prizePool': 10000,
    'prize_pool': 10000,
    'gameName': 'PUBG Mobile',
    'game_name': 'PUBG Mobile',
    'description': 'Weekly showdown.',
    'tags': <String>[],
    'rules': 'No cheating.',
  };
}

Map<String, List<Map<String, dynamic>>> _joinFixtures(String mode) => {
      'profiles': [
        {
          'firebase_uid': _uid,
          'display_name': 'Test Player',
          'username': 'TestPlayer',
          'level': 5,
          'photo_url': '',
          'country': 'Pakistan',
          'last_checked_notifications': 0
        },
      ],
      'tournaments': [_tournamentFixture(mode)],
      'tournament_registrations': <Map<String, dynamic>>[],
      'sliders': <Map<String, dynamic>>[],
      'promotions': <Map<String, dynamic>>[],
      'ads': <Map<String, dynamic>>[],
      'notifications': <Map<String, dynamic>>[],
      'user_notifications': <Map<String, dynamic>>[],
    };

Future<void> _pumpJoin(WidgetTester tester, String mode) async {
  tester.view.physicalSize = const Size(360, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: JoinTournamentPage(tournament: _tournamentFixture(mode)),
    ),
  );
  // Let _load() (profile + registrations fixtures) settle.
  // (No pumpAndSettle: the rotating MockupCard shines never settle.)
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// The shared header contract: same title style, gold chevron,
/// wordmark — in EVERY mode.
void _expectUnifiedHeader(WidgetTester tester, String title) {
  final titleText = tester.widget<Text>(find.text(title));
  expect(titleText.style?.fontSize, 20);
  expect(titleText.style?.fontWeight, FontWeight.w900);
  expect(titleText.style?.fontStyle, FontStyle.normal);
  final chevron = tester.widget<Icon>(find.byIcon(Icons.chevron_left));
  expect(chevron.color, hGold);
  expect(chevron.size, 28);
  expect(find.byType(ArenaWordmark), findsOneWidget);
}

/// The shared banner contract: status + mode pills and the fee
/// pill (banner + heading row = 2 copies of the fee text).
void _expectUnifiedBanner(WidgetTester tester, String modePill) {
  expect(find.text('REGISTRATION OPEN'), findsOneWidget);
  expect(find.text(modePill), findsWidgets);
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

  group('Registration unify — Solo', () {
    testWidgets('unified header + banner + one PLAYER (YOU) card',
        (tester) async {
      SupaDb.testFixtures = _joinFixtures('Solo');
      await _pumpJoin(tester, 'Solo');
      _expectUnifiedHeader(tester, 'SOLO REGISTRATION');
      expect(find.text('REGISTER FOR EVENT'), findsNothing);
      _expectUnifiedBanner(tester, 'SOLO');
      // Fee = entryFee x 1 = Rs 100.00 (banner pill + heading pill).
      expect(find.text('Rs 100.00'), findsNWidgets(2));
      expect(find.text('YOUR PLAYER (0/1)'), findsOneWidget);
      expect(find.text('PLAYER (YOU)'), findsOneWidget);
      expect(find.text('TEAM LEADER (YOU)'), findsNothing);
      // No mate cards, no team name in Solo.
      expect(find.text('TEAMMATE'), findsNothing);
      expect(find.textContaining('SQUAD MATE'), findsNothing);
      expect(find.text('Team Name'), findsNothing);
    });

    testWidgets('Solo keeps region + slot preference + confirm checkbox',
        (tester) async {
      SupaDb.testFixtures = _joinFixtures('Solo');
      await _pumpJoin(tester, 'Solo');
      expect(find.text('Preferred Region'), findsOneWidget);
      expect(find.text('Preferred Slot (optional)'), findsOneWidget);
      expect(find.text('Select Slot'), findsNothing);
      expect(find.text('I confirm that my in-game details are correct.'),
          findsOneWidget);
      expect(find.text('CONFIRM SOLO'), findsOneWidget);
      expect(find.text('CONFIRM REGISTRATION'), findsNothing);
    });
  });

  group('Registration unify — Duo', () {
    testWidgets('unified header + banner + leader + 1 mate + picker',
        (tester) async {
      SupaDb.testFixtures = _joinFixtures('Duo');
      await _pumpJoin(tester, 'Duo');
      _expectUnifiedHeader(tester, 'DUO REGISTRATION');
      expect(find.text('REGISTER DUO TEAM'), findsNothing);
      _expectUnifiedBanner(tester, 'DUO');
      // Fee = entryFee x 2 = Rs 200.00 (banner pill + heading pill).
      expect(find.text('Rs 200.00'), findsNWidgets(2));
      expect(find.text('BUILD YOUR DUO (0/2)'), findsOneWidget);
      expect(find.text('TEAM LEADER (YOU)'), findsOneWidget);
      expect(find.text('TEAMMATE'), findsOneWidget);
      expect(find.textContaining('SQUAD MATE'), findsNothing);
      // Team name IS present for teams; slot picker is visible now
      // (auto-pick ended).
      expect(find.text('Team Name'), findsOneWidget);
      expect(find.text('Select Slot'), findsOneWidget);
      expect(find.text('Preferred Slot (optional)'), findsNothing);
      expect(find.text('CONFIRM DUO'), findsOneWidget);
      expect(find.text('CONFIRM TEAM REGISTRATION'), findsNothing);
      // Solo-only extras stay out of Duo.
      expect(find.text('Preferred Region'), findsNothing);
      expect(find.text('I confirm that my in-game details are correct.'),
          findsNothing);
    });
  });

  group('Registration unify — Squad', () {
    testWidgets('unified header + banner + leader + 3 mates + picker',
        (tester) async {
      SupaDb.testFixtures = _joinFixtures('Squad');
      await _pumpJoin(tester, 'Squad');
      _expectUnifiedHeader(tester, 'SQUAD REGISTRATION');
      _expectUnifiedBanner(tester, 'SQUAD');
      // Fee = entryFee x 4 = Rs 400.00 (banner pill + heading pill).
      expect(find.text('Rs 400.00'), findsNWidgets(2));
      expect(find.text('BUILD YOUR SQUAD (0/4)'), findsOneWidget);
      expect(find.text('TEAM LEADER (YOU)'), findsOneWidget);
      expect(find.text('SQUAD MATE #2'), findsOneWidget);
      expect(find.text('SQUAD MATE #3'), findsOneWidget);
      expect(find.text('SQUAD MATE #4'), findsOneWidget);
      expect(find.text('TEAMMATE'), findsNothing);
      expect(find.text('Team Name'), findsOneWidget);
      expect(find.text('Select Slot'), findsOneWidget);
      expect(find.text('CONFIRM SQUAD'), findsOneWidget);
      // Solo-only extras stay out of Squad.
      expect(find.text('Preferred Region'), findsNothing);
      expect(find.text('I confirm that my in-game details are correct.'),
          findsNothing);
    });
  });

  group('Registration unify — side-by-side', () {
    testWidgets('all three headers share one style (title + chevron)',
        (tester) async {
      // The per-mode title style differences are gone: the same
      // FittedBox-wrapped upright-bold-20 title, gold chevron and
      // wordmark render in Solo, Duo and Squad alike.
      for (final mode in ['Solo', 'Duo', 'Squad']) {
        SupaDb.testFixtures = _joinFixtures(mode);
        await _pumpJoin(tester, mode);
        _expectUnifiedHeader(
            tester, '${mode.toUpperCase()} REGISTRATION');
        expect(tester.takeException(), isNull);
      }
    });
  });
}
