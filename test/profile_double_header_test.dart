// PROFILE DOUBLE HEADER — AUDIT P2-12 (2026-11-21).
//
// main.dart:1137 already carries the fix — the HomeShell AppBar is
// null on tabs 0, 2 AND 5 — because ProfilePage renders its own
// centered PROFILE + gear header (more_screens.dart:2253). These
// tests pump the REAL HomeShell and prove, per tab, that the global
// AppBar appears exactly where it should and NEVER above the
// Profile tab's own header.
//
// Harness: the fake-Firebase pattern from
// profile_page_mockup18_test.dart + the SupaDb.testFixtures seam
// (no network) + the connectivity mock from
// team_invite_notification_test.dart (HomeShell subscribes to
// Connectivity().onConnectivityChanged in initState).
import 'package:firebase_core/firebase_core.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_auth_platform_interface/firebase_auth_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/main.dart';
import 'package:protournament_user/services/supabase_db.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _uid = 'profile-test-uid';

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
    final uid = currentUser?.userInfo.uid ?? _uid;
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

Map<String, List<Map<String, dynamic>>> _fixtures() => {
      'profiles': [
        {
          'firebase_uid': _uid,
          'display_name': 'Test Player',
          'username': 'testplayer',
          'photo_url': '',
          'created_at': '2026-10-15T12:00:00Z',
          'level': 1,
          'xp': 0,
          'rank_tier': 'Bronze',
          'total_matches': 0,
          'won_matches': 0,
          'total_earnings': 0,
        },
      ],
      'tournaments': [],
      'sliders': [],
      'promotions': [],
      'ads': [],
      'match_history': [],
      'tournament_registrations': [],
      'community_points_ledger': [],
      'admin_config': [],
    };

Future<void> _pumpShell(WidgetTester tester) async {
  tester.view.physicalSize = const Size(360, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  // Install the error recorder HERE (in the test body, not setUp):
  // the framework re-installs its own FlutterError.onError after
  // setUp runs, so a setUp install never sees the pump's errors.
  _prevOnError = FlutterError.onError;
  final prev = _prevOnError;
  FlutterError.onError = (details) {
    _recordedErrors.add(details.exception);
    prev?.call(details);
  };
  await tester.pumpWidget(const MaterialApp(home: HomeShell()));
  // Let the fixture streams + one-shot futures emit. (No
  // pumpAndSettle: ArenaEmberDots / FireSparks repeat forever.)
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// KNOWN TEST-FONT-ONLY ERRORS (2026-11-22 update). The two
/// more_screens.dart defects this harness used to tolerate are
/// FIXED and removed from the list:
///   (1) more_screens.dart:2572 — ProfilePage's TabBar was
///       `isScrollable: true` + `tabAlignment: TabAlignment.fill`
///       (invalid combination). Fixed: non-scrollable + fill, the
///       tabs span the full width per mockup #18.
///   (2) more_screens.dart:2642 — the Achievements-preview header
///       Row overflowed by 57px at 360px in tests only (Ahem font).
///       Fixed: the title is wrapped in Flexible + ellipsis; with
///       the real font it fits whole (~210px in a 296px card).
/// One known error REMAINS, from another file (not this lane's to
/// fix): home_screens.dart:5391 — the TournamentsPage in-page
/// header Row overflows by 71px on the right AT 360px IN TESTS
/// ONLY: the Ahem test font measures 'TOURNAMENTS' at ~24px/char
/// while the real font measures ~15px/char, so the row fits on a
/// real device. Test-font artifact, not a device bug — the exact
/// '71 pixels' string is allow-listed so any OTHER overflow still
/// fails loudly. Zero recorded errors is also fine (the 71px fires
/// only when the Events tab is visited).
/// These tests record every framework error via a forwarding
/// FlutterError.onError (installed in _pumpShell — the framework
/// re-installs its own handler after setUp) and assert EVERY one
/// is a known message, and nothing else. Do NOT "fix" it by
/// ignoring all errors. (takeException() alone cannot do this:
/// with >1 error it returns one aggregated "Multiple
/// exceptions (N)…" summary instead of the individual messages.)
final _recordedErrors = <Object>[];
void Function(FlutterErrorDetails)? _prevOnError;

const _knownErrorMessages = [
  // Test-font-only overflow (TournamentsPage in-page header,
  // home_screens.dart:5391) — see the note above.
  'A RenderFlex overflowed by 71 pixels on the right.',
];

void _expectOnlyKnownPreexistingErrors(WidgetTester tester) {
  // Zero recorded errors is the ideal (both more_screens.dart
  // defects are fixed); any error that DOES fire must be a known
  // test-font artifact above — anything else fails loudly.
  for (final e in _recordedErrors) {
    final msg = e.toString();
    expect(
      _knownErrorMessages.any((known) => msg.contains(known)),
      isTrue,
      reason: 'unexpected exception in HomeShell pump: $e',
    );
  }
  // Drain the framework's (possibly aggregated) record so the test
  // ends with a clean slate, and restore the framework's handler.
  while (tester.takeException() != null) {}
  FlutterError.onError = _prevOnError;
  _prevOnError = null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  setUpAll(() async {
    FirebasePlatform.instance = _FakeCorePlatform();
    FirebaseAuthPlatform.instance = _FakeAuthPlatform();
    await Firebase.initializeApp(
      options: const FirebaseOptions(apiKey: 'test', appId: '1:1:android:1', messagingSenderId: '1', projectId: 'test'),
    );
  });

  setUp(() {
    // Fresh error record per test (the recorder itself is installed
    // in _pumpShell — see the note there).
    _recordedErrors.clear();
    // HomeShell._listenDeepLinks / connectivity subscribe in
    // initState; with no platform handler those calls never resolve.
    // Mock connectivity online (same pattern as
    // team_invite_notification_test.dart).
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity'),
      (call) async {
        if (call.method == 'check') return ['wifi'];
        return null;
      },
    );
    SupaDb.testFixtures = _fixtures();
  });

  tearDown(() {
    SupaDb.testFixtures = null;
  });

  group('P2-12 Profile double header', () {
    testWidgets('Profile tab: NO global AppBar, exactly one PROFILE header',
        (tester) async {
      await _pumpShell(tester);
      await tester.tap(find.text('Profile'));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      // The in-page header (ProfilePage's own centered PROFILE +
      // gear) is the ONLY header on this tab.
      expect(find.text('PROFILE'), findsOneWidget);
      // No 'Profile' title inside any AppBar — the HomeShell
      // AppBar is null on index 5 (main.dart:1137).
      expect(
        find.ancestor(
            of: find.text('Profile'), matching: find.byType(AppBar)),
        findsNothing,
      );
      _expectOnlyKnownPreexistingErrors(tester);
    });

    testWidgets('control: Events tab DOES show the global AppBar',
        (tester) async {
      await _pumpShell(tester);
      await tester.tap(find.text('Events'));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      // Same detector as the Profile test: it must FIND the AppBar
      // when the tab is one that keeps it — otherwise the Profile
      // assertion above would prove nothing.
      expect(
        find.ancestor(
            of: find.text('Events'), matching: find.byType(AppBar)),
        findsOneWidget,
      );
      _expectOnlyKnownPreexistingErrors(tester);
    });

    testWidgets('Home tab: NO global AppBar either (index 0 in the null set)',
        (tester) async {
      await _pumpShell(tester);
      expect(
        find.ancestor(
            of: find.text('ARENA HUB'), matching: find.byType(AppBar)),
        findsNothing,
      );
      _expectOnlyKnownPreexistingErrors(tester);
    });
  });
}
