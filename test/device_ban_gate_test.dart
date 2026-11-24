// Device-ban login gate (P2, 2026-11-22) — tests.
//
// Proves, with NO network and NO real Firebase/Supabase:
//   1. a uid with a `device_bans` row is stopped at login,
//   2. a device_id with a `device_bans` row is stopped at login,
//   3. a clean login still goes through (currentUser stays signed in,
//      no ban toast),
//   4. a failed ban read FAILS OPEN — login proceeds (unit level:
//      [DeviceBanGate.isBanned] returns false when the reader throws).
//   The widget tests pump the REAL AuthScreen against the
//   SupaDb.testFixtures seam + a fake Firebase Auth (platform-
//   interface fakes, same pattern as home_empty_fix_test.dart).
//   The read-error path cannot be forced through fixtures (fixtures
//   never throw), so it is proven at unit level with a throwing
//   reader — the same code path the widget calls.
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_auth_platform_interface/firebase_auth_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/screens/auth_screen.dart';
import 'package:protournament_user/widgets/arena_ui.dart';
import 'package:protournament_user/services/device_ban_gate.dart';
import 'package:protournament_user/services/supabase_db.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ---------- fake Firebase (pattern from home_empty_fix_test.dart) ----------

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
            projectId: 'test',
          ),
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

class _FakeUserCredential extends UserCredentialPlatform {
  _FakeUserCredential({required super.auth, super.user});
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
    // Signed OUT at start (unlike home_empty_fix_test, which defaults
    // to a signed-in test user): the login flow under test must do
    // the signing in.
    _user = currentUser == null
        ? null
        : _FakeUser(
            this,
            _FakeMultiFactor(this),
            currentUser,
          );
    return this;
  }

  @override
  UserPlatform? get currentUser => _user;

  @override
  set currentUser(UserPlatform? user) => _user = user;

  @override
  Future<UserCredentialPlatform> signInWithEmailAndPassword(
    String email,
    String password,
  ) async {
    final details = PigeonUserDetails(
      userInfo: PigeonUserInfo(
        uid: _uid,
        email: email,
        isAnonymous: false,
        isEmailVerified: true,
      ),
      providerData: [],
    );
    _user = _FakeUser(this, _FakeMultiFactor(this), details);
    return _FakeUserCredential(auth: this, user: _user);
  }

  @override
  Future<void> signOut() async {
    _user = null;
  }
}

// ---------- fixtures ----------

const _uid = 'test-uid';
const _bannedDeviceId = 'banned-device-1';
const _cleanDeviceId = 'clean-device-1';

Map<String, List<Map<String, dynamic>>> _fixtures({
  List<Map<String, dynamic>> deviceBans = const [],
}) =>
    {
      'profiles': [
        {
          'firebase_uid': _uid,
          'display_name': 'Test Player',
          'email': 'test@example.com',
          'photo_url': '',
          'last_checked_notifications': 0,
        },
      ],
      'device_bans': deviceBans,
    };

Future<void> _setDeviceId(String deviceId) async {
  // SharedPreferences caches its instance after the first
  // getInstance(), so seeding must write through the live instance
  // (setMockInitialValues in setUpAll only seeds the FIRST read).
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString('device_id', deviceId);
}

Future<void> _pumpAuth(WidgetTester tester) async {
  // Wide phone viewport (480x860): at the 360px width the existing
  // tests use (home_empty_fix_test.dart), AuthScreen's Google pill
  // and footer rows overflow by ~90px (pre-existing layout issue,
  // NOT caused by the ban gate — the same overflow shows in debug
  // on a 360dp phone). The overflow errors would fail the test run
  // even when the gate behaves correctly, so the gate tests pump at
  // a width where the screen lays out cleanly. The tap targets the
  // ArenaPrimaryButton itself (S14 rebuilt the Login CTA on the F2
  // contract button — no ElevatedButton remains on AuthScreen):
  // tapping the LOGIN Text warns that the Text's RenderParagraph
  // is not a hit-test target.
  tester.view.physicalSize = const Size(480, 860);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    const MaterialApp(home: AuthScreen()),
  );
  await tester.pump(const Duration(milliseconds: 100));
}

Future<void> _tapLogin(WidgetTester tester) async {
  final fields = find.byType(TextField);
  expect(fields, findsNWidgets(2));
  await tester.enterText(fields.at(0), 'test@example.com');
  await tester.enterText(fields.at(1), 'password123');
  await tester.ensureVisible(find.text('LOGIN'));
  await tester.pump(const Duration(milliseconds: 100));
  await tester.tap(find.byType(ArenaPrimaryButton).first);
  // Let the async login flow (sign-in -> ban gate -> profile sync)
  // finish. No pumpAndSettle: the screen has repeating animations.
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    FirebasePlatform.instance = _FakeCorePlatform();
    FirebaseAuthPlatform.instance = _FakeAuthPlatform();
    await Firebase.initializeApp(
      options: const FirebaseOptions(
        apiKey: 'test',
        appId: '1:1:android:1',
        messagingSenderId: '1',
        projectId: 'test',
      ),
    );
    // Force the FirebaseAuth singleton (and its delegate) to exist
    // now, so every test starts from the same signed-out fake.
    // ignore: unnecessary_statements
    FirebaseAuth.instance;
  });

  setUp(() {
    SupaDb.testFixtures = null;
  });

  tearDown(() async {
    SupaDb.testFixtures = null;
    // A signed-in fake user would leak into the next test.
    await FirebaseAuth.instance.signOut();
  });

  // ---------- unit: the gate decision itself ----------

  group('DeviceBanGate.isBanned', () {
    test('banned by firebase_uid -> true', () async {
      SupaDb.testFixtures = _fixtures(deviceBans: [
        {
          'id': 'b1',
          'device_id': 'some-other-device',
          'firebase_uid': _uid,
          'reason': 'cheating',
        },
      ]);
      expect(
        await DeviceBanGate.isBanned(uid: _uid, deviceId: _cleanDeviceId),
        isTrue,
      );
    });

    test('banned by device_id -> true', () async {
      SupaDb.testFixtures = _fixtures(deviceBans: [
        {
          'id': 'b2',
          'device_id': _bannedDeviceId,
          'firebase_uid': 'someone-else',
          'reason': 'multi-account',
        },
      ]);
      expect(
        await DeviceBanGate.isBanned(uid: _uid, deviceId: _bannedDeviceId),
        isTrue,
      );
    });

    test('no ban row -> false (clean login proceeds)', () async {
      SupaDb.testFixtures = _fixtures();
      expect(
        await DeviceBanGate.isBanned(uid: _uid, deviceId: _cleanDeviceId),
        isFalse,
      );
    });

    test('ban row for a DIFFERENT uid/device -> false', () async {
      SupaDb.testFixtures = _fixtures(deviceBans: [
        {
          'id': 'b3',
          'device_id': 'unrelated-device',
          'firebase_uid': 'unrelated-uid',
        },
      ]);
      expect(
        await DeviceBanGate.isBanned(uid: _uid, deviceId: _cleanDeviceId),
        isFalse,
      );
    });

    test('read error FAILS OPEN -> false (login must never break)',
        () async {
      expect(
        await DeviceBanGate.isBanned(
          uid: _uid,
          deviceId: _cleanDeviceId,
          readBans: (_, {eqCol, eqVal, limit}) =>
              throw Exception('simulated Supabase outage'),
        ),
        isFalse,
      );
    });

    test('localDeviceId is stable across calls and stored', () async {
      final first = await DeviceBanGate.localDeviceId();
      final second = await DeviceBanGate.localDeviceId();
      expect(first, isNotEmpty);
      expect(second, first);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('device_id'), first);
    });
  });

  // ---------- widget: the gate wired into the real login flow ----------

  testWidgets('banned uid: login is stopped, user is signed out',
      (tester) async {
    SupaDb.testFixtures = _fixtures(deviceBans: [
      {
        'id': 'b1',
        'device_id': 'some-other-device',
        'firebase_uid': _uid,
        'reason': 'cheating',
      },
    ]);
    await _setDeviceId(_cleanDeviceId);
    await _pumpAuth(tester);
    expect(FirebaseAuth.instance.currentUser, isNull);

    await _tapLogin(tester);

    // The gate signed the just-signed-in session straight back out.
    expect(FirebaseAuth.instance.currentUser, isNull);
    // ... and told the user why, instead of failing silently.
    expect(find.textContaining('banned'), findsOneWidget);
  });

  testWidgets('banned device: login is stopped even for a clean uid',
      (tester) async {
    SupaDb.testFixtures = _fixtures(deviceBans: [
      {
        'id': 'b2',
        'device_id': _bannedDeviceId,
        'firebase_uid': 'someone-else',
        'reason': 'multi-account',
      },
    ]);
    await _setDeviceId(_bannedDeviceId);
    await _pumpAuth(tester);

    await _tapLogin(tester);

    expect(FirebaseAuth.instance.currentUser, isNull);
    expect(find.textContaining('banned'), findsOneWidget);
  });

  testWidgets('clean login: user stays signed in, no ban message',
      (tester) async {
    SupaDb.testFixtures = _fixtures();
    await _setDeviceId(_cleanDeviceId);
    await _pumpAuth(tester);

    await _tapLogin(tester);

    // THE regression this gate must never cause: a clean login
    // blocked by the new check.
    expect(FirebaseAuth.instance.currentUser, isNotNull);
    expect(FirebaseAuth.instance.currentUser!.uid, _uid);
    expect(find.textContaining('banned'), findsNothing);
  });
}
