import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_auth_platform_interface/firebase_auth_platform_interface.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:protournament_user/community_service.dart';
import 'package:protournament_user/screens/communities_screens.dart';
import 'package:protournament_user/services/supabase_db.dart';

/// FIX 12 G4 — Community detail Settings sheet → About option.
///
/// Pins: the About option is present in the Settings sheet; the
/// About sheet shows the community name + description + CREATED BY
/// (creator display name) + created date + member count. The
/// creator name resolves via the spec route (community_members
/// role 'creator' → profiles), with created_by_uid as fallback.
/// Runs against SupaDb.testFixtures — no network.
///
/// FIX 23 (items 1+4+16a): the top bar + More menu are gone —
/// About lives in the sidebar Settings sheet now, and the detail
/// page mounts the voice panel ALWAYS for members, so this file
/// needs the fake Firebase auth (VoiceRoom reads
/// FirebaseAuth.instance.currentUser!.uid at mount) and manual
/// pumps (pumpAndSettle never settles with the room mounted).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Fake Firebase FIRST (top-level setUpAll, device_ban_gate_test
  // pattern — the detail page mounts UnifiedRoomPage, whose
  // services touch FirebaseAuth.instance; without the fakes the
  // real delegate caches and Firebase.initializeApp() hits the
  // native channel).
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
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    // The room mounts at pump time — a signed-in user must exist
    // before pumpDetail runs (VoiceRoom constructor reads
    // currentUser!.uid). The fake signs in as u1, the page's uid.
    await FirebaseAuth.instance.signOut();
    await FirebaseAuth.instance
        .signInWithEmailAndPassword(email: 'u1@test.com', password: 'x');
  });

  tearDown(() {
    SupaDb.testFixtures = null;
  });

  // Creator u9 'Ayesha Khan' + member u1: 2 members total. The
  // community row's created_at is 21 Nov 2026, 10:00 UTC.
  Map<String, List<Map<String, dynamic>>> fixtures({
    bool withCreatorRole = true,
  }) {
    return {
      'communities': [
        {
          'id': 'c1',
          'name': 'PUBG Pros',
          'description': 'Best players only',
          'photo_url': '',
          'created_by_uid': 'u9',
          'voice_enabled': true,
          'created_at': '2026-11-21T10:00:00.000Z',
        },
      ],
      'community_members': [
        if (withCreatorRole)
          {
            'community_id': 'c1',
            'firebase_uid': 'u9',
            'role': 'creator',
            'joined_at': '2026-11-21T10:00:00.000Z',
          },
        {
          'community_id': 'c1',
          'firebase_uid': 'u1',
          'role': 'member',
          'joined_at': '2026-11-21T11:00:00.000Z',
        },
      ],
      'profiles': [
        {'firebase_uid': 'u9', 'display_name': 'Ayesha Khan'},
        {'firebase_uid': 'u1', 'display_name': 'Test Player'},
      ],
      'community_posts': [],
    };
  }

  Future<void> pumpDetail(WidgetTester tester) async {
    // Tall viewport: the always-mounted voice panel + chat
    // overflow the default 600px height (G6 pattern).
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: CommunityDetailPage(
          uid: 'u1',
          communityId: 'c1',
          community: const {
            'id': 'c1',
            'name': 'PUBG Pros',
            'description': 'Best players only',
            'photo_url': '',
            'created_by_uid': 'u9',
            'voice_enabled': true,
            'isMember': true,
            'myRole': 'member',
            // STALE on purpose: the sheet must show the fresh
            // COUNT (2), not this cached 1.
            'memberCount': 1,
          },
        ),
      ),
    );
    // Manual pumps, NOT pumpAndSettle: the mounted room + smoke
    // layer never settle. 4s flushes the fixture futures + the
    // DSP ping/retry (2s + 2s); the final 5s flushes the mount
    // toast's snackbar timer (fix20 detail-group pattern).
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    await tester.pump(const Duration(seconds: 5));
  }

  Future<void> openSettings(WidgetTester tester) async {
    await tester.tap(find.text('Settings'));
    await tester.pump();
    // Let the sheet entrance finish before asserting on it
    // (G4 pattern — a t=0 sheet swallows the first pump).
    await tester.pump(const Duration(milliseconds: 300));
  }

  group('CommunityGroups.creatorDisplayName', () {
    test('resolves the creator name via the role creator row',
        () async {
      SupaDb.testFixtures = fixtures();
      expect(
          await CommunityGroups.creatorDisplayName('c1',
              createdByUid: 'u9'),
          'Ayesha Khan');
    });

    test('falls back to created_by_uid when the role row is missing',
        () async {
      SupaDb.testFixtures = fixtures(withCreatorRole: false);
      expect(
          await CommunityGroups.creatorDisplayName('c1',
              createdByUid: 'u9'),
          'Ayesha Khan');
    });

    test('returns empty when nothing resolves', () async {
      SupaDb.testFixtures = fixtures(withCreatorRole: false);
      expect(await CommunityGroups.creatorDisplayName('c1'), '');
      expect(await CommunityGroups.creatorDisplayName(''), '');
    });
  });

  group('Settings sheet -> About (FIX 23 item 4)', () {
    testWidgets('About option is present in the Settings sheet',
        (tester) async {
      SupaDb.testFixtures = fixtures();
      await pumpDetail(tester);

      // FIX 23 item 4: the More menu is gone — About lives in the
      // sidebar Settings sheet now.
      expect(find.text('More'), findsNothing);
      await openSettings(tester);

      expect(find.text('About'), findsOneWidget);
      // The old options survived — About was added, not swapped in.
      expect(find.text('Copy community name'), findsOneWidget);
    });

    testWidgets(
        'About sheet shows name + description + creator + date + count',
        (tester) async {
      SupaDb.testFixtures = fixtures();
      await pumpDetail(tester);

      await openSettings(tester);
      await tester.tap(find.text('About'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // Scoped to the sheet: the name/description also appear in
      // the page header/body, so an unscoped find would pass
      // even if the sheet were empty.
      final sheet = find.byType(CommunityAboutSheet);
      expect(sheet, findsOneWidget);
      expect(find.descendant(of: sheet, matching: find.text('PUBG Pros')),
          findsOneWidget);
      expect(
          find.descendant(
              of: sheet, matching: find.text('Best players only')),
          findsOneWidget);
      expect(find.descendant(of: sheet, matching: find.text('CREATED BY')),
          findsOneWidget);
      expect(
          find.descendant(
              of: sheet, matching: find.text('Ayesha Khan')),
          findsOneWidget);
      expect(
          find.descendant(
              of: sheet, matching: find.text('21 Nov 2026')),
          findsOneWidget);
      // Fresh COUNT (2 fixture members), NOT the stale cached 1.
      expect(find.descendant(of: sheet, matching: find.text('2 members')),
          findsOneWidget);
      expect(find.descendant(of: sheet, matching: find.text('1 member')),
          findsNothing);
    });
  });

  group('CommunityAboutSheet (direct)', () {
    testWidgets('renders all five fields with distinct values',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CommunityAboutSheet(
              name: 'Solo Clan',
              description: 'Just us, no noise.',
              creatorName: 'Zara Ali',
              createdAtMs:
                  DateTime.utc(2026, 1, 5, 12).millisecondsSinceEpoch,
              memberCount: 42,
            ),
          ),
        ),
      );

      expect(find.text('Solo Clan'), findsOneWidget);
      expect(find.text('Just us, no noise.'), findsOneWidget);
      expect(find.text('CREATED BY'), findsOneWidget);
      expect(find.text('Zara Ali'), findsOneWidget);
      expect(find.text('5 Jan 2026'), findsOneWidget);
      expect(find.text('42 members'), findsOneWidget);
    });

    testWidgets('unknown creator/date read Unknown, never a fake value',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: CommunityAboutSheet(
              name: 'Mystery Club',
              description: '',
              creatorName: '',
              createdAtMs: 0,
              memberCount: 1,
            ),
          ),
        ),
      );

      expect(find.text('Mystery Club'), findsOneWidget);
      expect(find.text('No description yet.'), findsOneWidget);
      // One 'Unknown' for CREATED BY, one for CREATED ON.
      expect(find.text('Unknown'), findsNWidgets(2));
      expect(find.text('1 member'), findsOneWidget);
    });
  });
}

// ---- Fake Firebase (exact pattern from device_ban_gate_test,
// copied from fix20_community_voice_test.dart; the fake signs in
// as u1, this file's page uid) ----

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
        uid: 'u1',
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
