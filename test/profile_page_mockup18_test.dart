// PROFILE — MOCKUP #18 MATCH (2026-11-21, user order — mockup
// 370943701_1795037708708021.jpg vs current app 1000049425_44_47aa.jpg):
//   1. header: centered PROFILE + gear top-right (the gear is the
//      ONLY Settings entry now — the Overview 'Settings' tile was
//      removed 2026-11-22, user order); Back ONLY
//      when pushed — on the bottom-nav root tab there is no back
//      destination, so NO dead back button is ever drawn;
//   2. the Followers / Following / Community row below the stats card
//      is GONE (not in the mockup);
//   3. tabs Overview / Match History / Achievements + the
//      'Achievements / View All' preview with the mockup's three badge
//      cards (FIRST BLOOD / SURVIVALIST / SQUAD LEADER) render below
//      the fold and survive scrolling;
//   4. bottom nav is out of scope here (6 items vs mockup 5 — the
//      Community tab is an ordered feature, intentionally kept);
//   5. avatar ring is the mockup's CLEAN gold ring: FramedAvatar with
//      frame: null (the old CachedFramedAvatar rendered the user's
//      equipped shop frame — purple/gold sparkle — which is not in
//      the mockup). Lv pill unchanged.
// Data stays REAL: fixture profile is 0 matches / Lv.1 / BRONZE /
// 0 XP / Member since Oct 2026 — the mockup's 248 / 64 / DIAMOND /
// 4,850 / 1,850 XP are samples and must NEVER appear.
//
// Pumps the REAL ProfilePage with fixture data via the
// SupaDb.testFixtures seam and the fake-Firebase pattern from
// home_empty_fix_test.dart (platform-interface fakes, no network).
// No pumpAndSettle — ArenaEmberDots / FireSparks repeat forever.
import 'package:firebase_core/firebase_core.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_auth_platform_interface/firebase_auth_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/screens/frames_widgets.dart';
import 'package:protournament_user/screens/more_screens.dart';
import 'package:protournament_user/services/supabase_db.dart';
import 'package:protournament_user/theme.dart';
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
      'match_history': [],
      'admin_config': [],
    };

Future<void> _pumpProfile(WidgetTester tester) async {
  tester.view.physicalSize = const Size(360, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(home: ProfilePage(uid: _uid)));
  // Let the fixture stream + one-shot futures emit. (No
  // pumpAndSettle: the ember/spark animations repeat forever.)
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

// v2014 (Bugs 3+4): same as _pumpProfile, but with a 24dp status bar
// (the phone's), so SafeArea(top) actually insets — the default test
// view has no status bar, which hid the header-under-status-bar bug.
Future<void> _pumpProfileWithStatusBar(WidgetTester tester) async {
  tester.view.physicalSize = const Size(360, 800);
  tester.view.devicePixelRatio = 1.0;
  tester.view.padding = const FakeViewPadding(top: 24);
  tester.view.viewPadding = const FakeViewPadding(top: 24);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPadding);
  addTearDown(tester.view.resetViewPadding);
  await tester.pumpWidget(MaterialApp(home: ProfilePage(uid: _uid)));
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
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
    SupaDb.testFixtures = _fixtures();
  });

  tearDown(() {
    SupaDb.testFixtures = null;
  });

  group('mockup #18 header', () {
    testWidgets('centered PROFILE title + gear, NO dead Back on the root tab', (tester) async {
      await _pumpProfile(tester);
      expect(find.text('PROFILE'), findsOneWidget);
      // Gear top-right, wired (not decorative).
      final gear = find.byIcon(Icons.settings_outlined);
      expect(gear, findsOneWidget);
      expect(tester.widget<IconButton>(find.ancestor(of: gear, matching: find.byType(IconButton))).onPressed, isNotNull);
      // Root tab: no back destination, so no Back button at all.
      expect(find.text('Back'), findsNothing);
      expect(find.byIcon(Icons.chevron_left), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('gear opens SettingsPage (the only Settings entry now)', (tester) async {
      await _pumpProfile(tester);
      await tester.tap(find.byIcon(Icons.settings_outlined));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(SettingsPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    // v2014 (Bugs 3+4): with a real 24dp status bar, the header must
    // clear it — before the SafeArea fix the header started at y=16
    // (icon top 27, ~6dp under the bar) and the gear's top strip was
    // dead to touches.
    testWidgets('v2014: header clears the status bar; gear aligned with title', (tester) async {
      await _pumpProfileWithStatusBar(tester);
      final gearTop = tester.getTopLeft(find.byIcon(Icons.settings_outlined)).dy;
      expect(gearTop, greaterThanOrEqualTo(40.0));
      final gearCenter = tester.getCenter(find.byIcon(Icons.settings_outlined)).dy;
      final titleCenter = tester.getCenter(find.text('PROFILE')).dy;
      expect((gearCenter - titleCenter).abs(), lessThan(2.0));
      expect(tester.takeException(), isNull);
    });

    testWidgets('v2014: gear opens SettingsPage with a status bar present', (tester) async {
      await _pumpProfileWithStatusBar(tester);
      await tester.tap(find.byIcon(Icons.settings_outlined));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(SettingsPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  // RESTRUCTURE UPDATE (2026-11-22, user order): the old Followers /
  // Following / Community ROW below the stats card is still gone —
  // but 'Following' now legitimately appears as a Profile TILE (the
  // 05:07 Community-tab restructure moved Friends/Requests/Followers
  // + Messages + Following into Profile as tiles), and the old
  // 'Community' tile is gone (replaced by those three). This test
  // now asserts the NEW tile structure instead of the old row text.
  group('community tiles (2026-11-22 restructure)', () {
    testWidgets('Friends & Requests / Messages / Following tiles exist, Community tile gone', (tester) async {
      await _pumpProfile(tester);
      expect(find.text('Friends & Requests'), findsOneWidget);
      expect(find.text('Messages'), findsOneWidget);
      expect(find.text('Following'), findsOneWidget);
      expect(find.text('Community'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('tabs + achievements preview (mockup #18)', () {
    testWidgets('three tabs render with the mockup labels', (tester) async {
      await _pumpProfile(tester);
      expect(find.text('Overview'), findsOneWidget);
      expect(find.text('Match History'), findsWidgets);
      expect(find.text('Achievements'), findsNWidgets(2)); // tab + section header
      expect(tester.takeException(), isNull);
    });

    testWidgets('Achievements / View All + the three mockup badge cards render', (tester) async {
      await _pumpProfile(tester);
      expect(find.text('View All'), findsOneWidget);
      expect(find.text('FIRST BLOOD'), findsOneWidget);
      expect(find.text('SURVIVALIST'), findsOneWidget);
      expect(find.text('SQUAD LEADER'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('badge cards survive scrolling to the bottom of the page', (tester) async {
      await _pumpProfile(tester);
      await tester.drag(find.byType(SingleChildScrollView), const Offset(0, -1200));
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('FIRST BLOOD'), findsOneWidget);
      expect(find.text('SURVIVALIST'), findsOneWidget);
      expect(find.text('SQUAD LEADER'), findsOneWidget);
      // No overflow anywhere on the page (standing rule: no word
      // cut or hidden).
      expect(tester.takeException(), isNull);
    });

    testWidgets('View All switches to the Achievements tab with real conditions', (tester) async {
      await _pumpProfile(tester);
      await tester.tap(find.text('View All'));
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      // Full list: real unlock conditions + locked states for 0 wins.
      expect(find.text('Win your first match'), findsOneWidget);
      expect(find.text('Play 10 matches'), findsOneWidget);
      expect(find.text('Win 5 matches'), findsOneWidget);
      expect(find.text('Locked'), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  });

  group('Edit Profile pill (printer-copy: white label, gold icon/border)', () {
    testWidgets('label text is white like the mockup, icon stays gold', (tester) async {
      await _pumpProfile(tester);
      final label = tester.widget<Text>(find.text('Edit Profile'));
      expect(label.style?.color, kText);
      expect(find.byIcon(Icons.edit), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('avatar ring (mockup #18 clean gold)', () {
    testWidgets('plain FramedAvatar, no equipped-frame sparkle; Lv pill as-is', (tester) async {
      await _pumpProfile(tester);
      expect(find.byType(CachedFramedAvatar), findsNothing);
      final avatar = find.byType(FramedAvatar);
      expect(avatar, findsOneWidget);
      expect(tester.widget<FramedAvatar>(avatar).frame, isNull);
      expect(find.text('Lv.1'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('data stays real (never the mockup samples)', () {
    testWidgets('0 matches / BRONZE / 0 XP / Member since Oct 2026', (tester) async {
      await _pumpProfile(tester);
      expect(find.text('Test Player'), findsOneWidget);
      expect(find.text('@testplayer'), findsOneWidget);
      expect(find.text('Member since Oct 2026'), findsOneWidget);
      expect(find.text('BRONZE'), findsOneWidget);
      // XP line is two Text widgets ('0' + ' / 100 XP').
      expect(find.text(' / 100 XP'), findsOneWidget);
      expect(find.text('Matches Played'), findsOneWidget);
      expect(find.text('Matches Won'), findsOneWidget);
      expect(find.text('Current Rank'), findsOneWidget);
      expect(find.text('Community Points'), findsOneWidget);
      // Mockup sample values must NEVER appear.
      expect(find.text('248'), findsNothing);
      expect(find.text('64'), findsNothing);
      expect(find.text('DIAMOND'), findsNothing);
      expect(find.text('4,850'), findsNothing);
      expect(find.text('1,850 / 2,500 XP'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
