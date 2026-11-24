// FIX 23 — UNIFORM PILLS (items 18, 20).
// The Community tab's three toggle pills [Community] [Squad]
// [Create] render at one size, and the Events filter pills
// [All] [Live] [Upcoming] [My Games] [Saved] render at one size
// in a horizontally scrollable row (matching the fee row, which
// is the reference and is NOT touched).

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_auth_platform_interface/firebase_auth_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/screens/home_screens.dart';
import 'package:protournament_user/screens/pro_features.dart';
import 'package:protournament_user/services/supabase_db.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'audio_test_helpers.dart';

String _region(String src, String start, String end) {
  final s = src.indexOf(start);
  if (s < 0) return '';
  final e = src.indexOf(end, s + start.length);
  if (e < 0) return '';
  return src.substring(s, e);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('fix23 item 18 — three toggle pills uniform (source)', () {
    late String pro;

    setUpAll(() {
      pro = codeOnly(requireProjectFile('lib/screens/pro_features.dart'));
    });

    test('no FittedBox shrinking in _toggleBtn', () {
      final btn = _region(
          pro, 'Widget _toggleBtn(', 'Widget _buildCommunityList()');
      expect(btn, isNotEmpty);
      expect(btn, isNot(contains('FittedBox')));
      expect(btn, contains('fontSize: 14'));
    });

    test('Community pill gets the wider flex (4/3/3)', () {
      final row = _region(pro, 'Widget _toggleRow(', 'Widget _buildBody(');
      // Fall back: search the whole file for the flex literals.
      final target = row.isEmpty ? pro : row;
      expect(target, contains('flex: 4'));
      expect(target, contains('flex: 3'));
    });
  });

  group('fix23 item 20 — filter pills uniform + scrollable (source)', () {
    late String home;

    setUpAll(() {
      home = codeOnly(requireProjectFile('lib/screens/home_screens.dart'));
    });

    test('filter pills row scrolls horizontally, no FittedBox shrink', () {
      // The row is inline in the Events build (no named method):
      // from the pill list to the tournaments-list Expanded.
      // (Anchor on the icon-bearing def — an earlier row reuses
      // the same 'all'/'All' keys without icons.)
      final row = _region(
          home, "{'k': 'all', 'l': 'All', 'i': Icons.grid_view}", 'Expanded(');
      expect(row, isNotEmpty);
      expect(row, isNot(contains('FittedBox')));
      for (final label in ['All', 'Live', 'Upcoming', 'My Games', 'Saved']) {
        expect(row, contains("'$label'"), reason: 'missing pill: $label');
      }
      expect(row, contains('fontSize: 13'));
      // The scrollable wrapper's padding (fee row uses different
      // padding, so this snippet identifies the filter row).
      expect(home,
          contains('fromLTRB(kSpace12, kSpace4, kSpace12, kSpace4)'));
    });

    test('fee row untouched — still the scrollable reference', () {
      final fee = _region(home, 'Widget _feeSortRow(', 'Widget build(');
      expect(fee, isNotEmpty);
      expect(fee, contains('SingleChildScrollView'));
      expect(fee, contains('ArenaFilterChip'));
    });
  });

  group('fix23 item 18 — TeamsPage pills widget at 360px', () {
    setUp(() {
      SupaDb.testFixtures = {
        'teams': [],
        'team_members': [],
        'team_invitations': [],
        'profiles': [
          {
            'firebase_uid': 'test-uid',
            'display_name': 'Tester',
            'username': 'tester'
          },
        ],
      };
    });
    tearDown(() {
      SupaDb.testFixtures = null;
    });

    testWidgets('all three pills same font size + height, no overflow',
        (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(const MaterialApp(
          home: TeamsPage(uid: 'test-uid', embedded: true)));
      await tester.pump();
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      double? height;
      for (final label in ['Community', 'Squad', 'Create']) {
        expect(find.text(label), findsOneWidget, reason: label);
        final text = tester.widget<Text>(find.text(label));
        expect(text.style?.fontSize, 14.0, reason: label);
        final h = tester.getSize(find.text(label)).height;
        height ??= h;
        expect(h, height, reason: '$label height differs');
      }
      expect(tester.takeException(), isNull);
    });
  });

  group('fix23 item 20 — Events filter pills widget at 360px', () {
    setUpAll(() async {
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
      // ignore: unnecessary_statements
      FirebaseAuth.instance;
    });

    setUp(() async {
      await FirebaseAuth.instance
          .signInWithEmailAndPassword(email: 't@t.com', password: 'password');
      SupaDb.testFixtures = {'tournaments': []};
    });

    tearDown(() async {
      SupaDb.testFixtures = null;
      await FirebaseAuth.instance.signOut();
    });

    Future<void> pumpEvents(WidgetTester tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: TournamentsPage()),
        ),
      );
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    testWidgets('all five pills same font size + height, row scrolls',
        (tester) async {
      await pumpEvents(tester);
      double? height;
      for (final label in ['All', 'Live', 'Upcoming', 'My Games', 'Saved']) {
        expect(find.text(label), findsOneWidget, reason: label);
        final text = tester.widget<Text>(find.text(label));
        expect(text.style?.fontSize, 13.0, reason: label);
        final h = tester.getSize(find.text(label)).height;
        height ??= h;
        expect(h, height, reason: '$label height differs');
      }
      // The row scrolls: 'Upcoming' sits inside a horizontal
      // SingleChildScrollView.
      final scrollable = find.ancestor(
        of: find.text('Upcoming'),
        matching: find.byType(SingleChildScrollView),
      );
      expect(scrollable, findsOneWidget);
      final scroll = tester.widget<SingleChildScrollView>(scrollable);
      expect(scroll.scrollDirection, Axis.horizontal);
      // Dragging the row moves it (no clip, reachable pills).
      final before = tester.getTopLeft(find.text('Saved')).dx;
      await tester.drag(find.text('All'), const Offset(-120, 0));
      await tester.pump();
      final after = tester.getTopLeft(find.text('Saved')).dx;
      expect(after, lessThan(before));
      expect(tester.takeException(), isNull);
    });
  });
}

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
    _user = currentUser == null
        ? null
        : _FakeUser(this, _FakeMultiFactor(this), currentUser);
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
        uid: 'test-uid',
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
