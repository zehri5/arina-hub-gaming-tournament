// REDESIGN PHASE 2 — GROUP S9: PROFILE (guide §6 Screen 9).
//
// Pins the restyle, NOT the old look:
//   1. F1 contract tokens exist with the guide values (gold #FDC903
//      ONLY — the banned shades appear nowhere, in code or comments);
//   2. F2 contract components behave per contract (outlined button =
//      gold border, primary = gold gradient, loading = gold spinner);
//   3. avatar keeps the mockup's clean golden ring (2px kGold) + a
//      SUBTLE gold glow (low alpha, never a neon halo);
//   4. username / status dot / member-since readable on the shared
//      text tokens; Edit Profile is the shared ArenaOutlinedButton
//      and still navigates to CreateProfilePage;
//   5. XP bar fill is the shared kGoldGradient on the visible track,
//      with the REAL xp / (level x 100) curve untouched;
//   6. the four stat cells stay aligned in their 2x2 grid;
//   7. tabs use the shared tab style (gold indicator/label, muted
//      unselected) and still switch content;
//   8. achievement preview cards share one radius + border treatment,
//      locked vs unlocked from REAL counts;
//   9. statistics / rank logic untouched — fixture values render,
//      mockup sample values NEVER appear.
//
// Pumps the REAL ProfilePage with fixture data via the
// SupaDb.testFixtures seam and the fake-Firebase pattern from
// profile_page_mockup18_test.dart (platform-interface fakes, no
// network). No pumpAndSettle — ArenaEmberDots / FireSparks repeat
// forever.
import 'package:firebase_core/firebase_core.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_auth_platform_interface/firebase_auth_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/screens/frames_widgets.dart';
import 'package:protournament_user/screens/more_screens.dart';
import 'package:protournament_user/screens/pro_features.dart';
import 'package:protournament_user/services/presence_service.dart';
import 'package:protournament_user/services/supabase_db.dart';
import 'package:protournament_user/theme.dart';
import 'package:protournament_user/widgets/arena_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _uid = 's9-profile-test-uid';

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

/// Zero-progress user: 0 matches / Lv.1 / BRONZE / 0 XP.
Map<String, List<Map<String, dynamic>>> _fixturesZero() => {
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

/// Progressed user: 12 matches / 5 wins / Lv.3 / 250 XP / Gold tier —
/// pins the REAL curve (next level = 3 x 100 = 300 XP) and the REAL
/// unlock thresholds (First Blood 1 win, Survivalist 10 matches,
/// Squad Leader 5 wins — all unlocked here).
Map<String, List<Map<String, dynamic>>> _fixturesProgressed() => {
      'profiles': [
        {
          'firebase_uid': _uid,
          'display_name': 'Test Player',
          'username': 'testplayer',
          'photo_url': '',
          'created_at': '2026-10-15T12:00:00Z',
          'level': 3,
          'xp': 250,
          'rank_tier': 'Gold',
          'total_matches': 12,
          'won_matches': 5,
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

Future<void> _pumpWidget(WidgetTester tester, Widget widget) async {
  tester.view.physicalSize = const Size(360, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: widget)));
  await tester.pump();
}

/// The gold ring container: circular, 2px kGold border.
Finder _ringContainer() => find.byWidgetPredicate(
      (w) =>
          w is Container &&
          w.decoration is BoxDecoration &&
          (w.decoration as BoxDecoration).shape == BoxShape.circle &&
          (w.decoration as BoxDecoration).border is Border &&
          ((w.decoration as BoxDecoration).border as Border).top.color == kGold &&
          ((w.decoration as BoxDecoration).border as Border).top.width == 2,
    );

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
    // Dark mode (the default) so the dark token values apply.
    themeLightNotifier.value = false;
    SupaDb.testFixtures = _fixturesZero();
  });

  tearDown(() {
    SupaDb.testFixtures = null;
  });

  group('F1 contract tokens (guide values, gold rule)', () {
    test('gold is #FDC903 only', () {
      // The banned-shade negative check lives in the exact-gradient
      // pins below ('gradients match the guide'): a gradient that
      // equals exactly [FFE16A, FDC903] cannot carry a banned shade.
      // (No banned-gold value is written in this file at all.)
      expect(kGold, const Color(0xFFFDC903));
      expect(kGoldDeep, const Color(0xFFFDC903));
      expect(kGoldBright, const Color(0xFFFDC903));
    });

    test('new colour tokens match the guide', () {
      expect(kGoldSoft, const Color(0xFFFFE16A));
      expect(kWarning, const Color(0xFFF4A62A));
      expect(kError, const Color(0xFFF04452));
      expect(kSurfaceElevated, const Color(0xFF202331));
      expect(kTextMuted, const Color(0xFF737789));
    });

    test('gradients match the guide (gold rule substitution applied)', () {
      expect(kGoldGradient.colors, [const Color(0xFFFFE16A), const Color(0xFFFDC903)]);
      expect(kCardSurfaceGradient.colors, [const Color(0xFF202331), const Color(0xFF12141C)]);
      expect(kBackgroundGradient.colors, [const Color(0xFF10121A), const Color(0xFF08090D)]);
    });

    test('spacing + radii consts match the contract', () {
      expect(kSpace4, 4);
      expect(kSpace8, 8);
      expect(kSpace12, 12);
      expect(kSpace16, 16);
      expect(kSpace20, 20);
      expect(kSpace24, 24);
      expect(kSpace32, 32);
      expect(kRadiusChip, 12);
      expect(kRadiusInput, 14);
      expect(kRadiusCard, 18);
      expect(kRadiusHero, 22);
    });

    test('text styles match the contract hierarchy', () {
      expect(kStyleTitle.fontSize, 22);
      expect(kStyleTitle.fontWeight, FontWeight.bold);
      expect(kStyleTitle.color, kText);
      expect(kStyleSection.fontSize, 18);
      expect(kStyleSection.fontWeight, FontWeight.bold);
      expect(kStyleCardTitle.fontSize, 17);
      expect(kStyleCardTitle.fontWeight, FontWeight.w600);
      expect(kStyleBody.fontSize, 15);
      expect(kStyleBody.fontWeight, FontWeight.normal);
      expect(kStyleMeta.fontSize, 13);
      expect(kStyleMeta.color, kMuted);
      expect(kStyleLabel.fontSize, 12);
      expect(kStyleLabel.fontWeight, FontWeight.w500);
      // REAL F1 value (differs from the S9 stub, which used kMuted):
      // the label token is the guide's Text Muted, not secondary text.
      expect(kStyleLabel.color, kTextMuted);
    });
  });

  group('F2 contract components (real F2 behaviour)', () {
    testWidgets('ArenaOutlinedButton: gold border when enabled, muted when disabled', (tester) async {
      var tapped = false;
      await _pumpWidget(tester, ArenaOutlinedButton(onPressed: () => tapped = true, child: const Text('Go')));
      // Real F2 is a framed Container + InkWell, NOT an OutlinedButton.
      final frame = find.descendant(of: find.byType(ArenaOutlinedButton), matching: find.byType(Container)).first;
      final decoration = tester.widget<Container>(frame).decoration as BoxDecoration;
      expect((decoration.border as Border?)?.top.color, kGold);
      expect((decoration.border as Border?)?.top.width, 1.5);
      expect(decoration.borderRadius, BorderRadius.circular(kRadiusInput));
      await tester.tap(find.text('Go'));
      expect(tapped, isTrue);

      await _pumpWidget(tester, const ArenaOutlinedButton(onPressed: null, child: Text('Off')));
      final disabledFrame = find.descendant(of: find.byType(ArenaOutlinedButton), matching: find.byType(Container)).first;
      final disabledDecoration = tester.widget<Container>(disabledFrame).decoration as BoxDecoration;
      expect((disabledDecoration.border as Border?)?.top.color, kTextMuted);
      expect(tester.takeException(), isNull);
    });

    testWidgets('ArenaPrimaryButton: gold gradient when enabled, muted surface when disabled', (tester) async {
      await _pumpWidget(tester, ArenaPrimaryButton(onPressed: () {}, child: const Text('Go')));
      final enabled = tester.widget<Container>(
        find.byWidgetPredicate((w) => w is Container && (w.decoration as BoxDecoration?)?.gradient == kGoldGradient),
      );
      expect(enabled.decoration, isA<BoxDecoration>());

      // Real F2 disabled surface is kSurfaceElevated (stub used kField).
      await _pumpWidget(tester, const ArenaPrimaryButton(onPressed: null, child: Text('Off')));
      expect(
        find.byWidgetPredicate((w) => w is Container && (w.decoration as BoxDecoration?)?.color == kSurfaceElevated),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('ArenaFilterChip: selected = yellow fill + dark text', (tester) async {
      await _pumpWidget(
        tester,
        Column(children: [ArenaFilterChip(label: 'On', selected: true, onTap: () {}), ArenaFilterChip(label: 'Off', selected: false, onTap: () {})]),
      );
      final onLabel = tester.widget<Text>(find.text('On'));
      // Real F2 dark-on-gold is #14161F (stub used pure black).
      expect(onLabel.style?.color, const Color(0xFF14161F));
      final offLabel = tester.widget<Text>(find.text('Off'));
      expect(offLabel.style?.color, kText);
      expect(
        find.byWidgetPredicate((w) => w is Container && (w.decoration as BoxDecoration?)?.color == kGold),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('ArenaLiveBadge / ArenaLoadingIndicator / ArenaBackground / ArenaPressable', (tester) async {
      await _pumpWidget(
        tester,
        ArenaBackground(
          child: Column(children: [const ArenaLiveBadge(), const ArenaLoadingIndicator(), ArenaPressable(onTap: () {}, child: const Text('Press me'))]),
        ),
      );
      expect(find.text('LIVE'), findsOneWidget);
      expect(
        find.byWidgetPredicate((w) => w is Container && (w.decoration as BoxDecoration?)?.color == kLiveRed),
        findsOneWidget,
      );
      expect(tester.widget<CircularProgressIndicator>(find.byType(CircularProgressIndicator)).color, kGold);
      expect(
        find.byWidgetPredicate((w) => w is Container && (w.decoration as BoxDecoration?)?.gradient == kBackgroundGradient),
        findsOneWidget,
      );
      var pressed = false;
      await _pumpWidget(tester, ArenaPressable(onTap: () => pressed = true, child: const Text('Press me')));
      await tester.tap(find.text('Press me'));
      expect(pressed, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('ArenaTextField: dark fill, subtle border, gold focus border', (tester) async {
      await _pumpWidget(tester, ArenaTextField(hintText: 'Type here', onChanged: (_) {}));
      // TextFormField has no decoration getter — read it off the inner TextField.
      final field = tester.widget<TextField>(find.byType(TextField));
      final decoration = field.decoration!;
      expect(decoration.fillColor, kField);
      expect((decoration.enabledBorder as OutlineInputBorder?)?.borderSide.color, kBorder);
      expect((decoration.focusedBorder as OutlineInputBorder?)?.borderSide.color, kGold);
      expect((decoration.errorBorder as OutlineInputBorder?)?.borderSide.color, kError);
      expect(tester.takeException(), isNull);
    });
  });

  group('avatar: golden ring + subtle glow (guide §6 Screen 9)', () {
    testWidgets('2px kGold ring, plain avatar, subtle (low-alpha) gold glow', (tester) async {
      await _pumpProfile(tester);
      // Plain FramedAvatar, no equipped-frame sparkle.
      expect(find.byType(CachedFramedAvatar), findsNothing);
      final avatar = find.byType(FramedAvatar);
      expect(avatar, findsOneWidget);
      expect(tester.widget<FramedAvatar>(avatar).frame, isNull);
      // The ring: exactly one circular 2px gold-bordered container.
      expect(_ringContainer(), findsOneWidget);
      final ring = tester.widget<Container>(_ringContainer());
      final decoration = ring.decoration as BoxDecoration;
      final shadows = decoration.boxShadow!;
      expect(shadows, isNotEmpty);
      // Subtle glow: every halo is gold (same RGB as kGold) at low alpha.
      // NOTE: Color.red/green/blue/alpha are INT getters (0-255) — the
      // float getters are r/g/b/a. An alpha of 0.35 reads as 89 via
      // .alpha, so the low-alpha check must use .a (0.0-1.0).
      for (final s in shadows) {
        expect(s.color.r, kGold.r);
        expect(s.color.g, kGold.g);
        expect(s.color.b, kGold.b);
        expect(s.color.a, lessThan(0.6));
        expect(s.color.a, greaterThan(0));
      }
      // Lv pill unchanged: black fill, gold border, gold text.
      expect(find.text('Lv.1'), findsOneWidget);
      expect(tester.widget<Text>(find.text('Lv.1')).style?.color, kGold);
      expect(tester.takeException(), isNull);
    });
  });

  group('identity lines readable on shared tokens', () {
    testWidgets('name / handle / member-since / presence dot', (tester) async {
      await _pumpProfile(tester);
      final name = tester.widget<Text>(find.text('Test Player'));
      expect(name.style?.fontSize, 26);
      expect(name.style?.color, kText);
      expect(name.style?.fontWeight, FontWeight.bold);
      final handle = tester.widget<Text>(find.text('@testplayer'));
      expect(handle.style?.color, kMuted);
      expect(handle.style?.fontSize, 14);
      final since = tester.widget<Text>(find.text('Member since Oct 2026'));
      expect(since.style?.color, kMuted);
      expect(since.style?.fontSize, 13);
      expect(find.byType(PresenceDot), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('Edit Profile is the shared outlined button', () {
    testWidgets('ArenaOutlinedButton, white label, gold icon, still navigates', (tester) async {
      await _pumpProfile(tester);
      final button = find.byType(ArenaOutlinedButton);
      expect(button, findsOneWidget);
      expect(tester.widget<ArenaOutlinedButton>(button).onPressed, isNotNull);
      final label = tester.widget<Text>(find.text('Edit Profile'));
      expect(label.style?.color, kText);
      expect(find.byIcon(Icons.edit), findsOneWidget);
      expect(tester.widget<Icon>(find.byIcon(Icons.edit)).color, kGold);
      // Navigation preserved: tap opens the Edit Profile flow.
      await tester.tap(find.text('Edit Profile'));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(CreateProfilePage), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('XP bar: golden gradient fill, real curve', () {
    testWidgets('fill uses kGoldGradient; track visible at 0 XP; real 0 / 100 XP', (tester) async {
      await _pumpProfile(tester);
      // The fill is the one kGoldGradient container on the screen.
      expect(
        find.byWidgetPredicate((w) => w is Container && (w.decoration as BoxDecoration?)?.gradient == kGoldGradient),
        findsOneWidget,
      );
      // The track stays a visible medium grey even at 0 XP.
      expect(
        find.byWidgetPredicate((w) => w is Container && (w.decoration as BoxDecoration?)?.color == const Color(0xFF2E323F)),
        findsOneWidget,
      );
      expect(find.text('LEVEL 1'), findsOneWidget);
      expect(find.text('LEVEL 2'), findsOneWidget);
      expect(tester.widget<Text>(find.text('LEVEL 1')).style?.fontSize, 12);
      // Real F1 kStyleLabel colour is kTextMuted (guide Text Muted),
      // not kMuted as the S9 stub had it.
      expect(tester.widget<Text>(find.text('LEVEL 1')).style?.color, kTextMuted);
      // XP line is two Text widgets ('0' + ' / 100 XP').
      final xpValue = tester.widget<Text>(find.text('0').first);
      expect(xpValue.style?.color, kGold);
      expect(xpValue.style?.fontSize, 15);
      expect(find.text(' / 100 XP'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('progressed user: LEVEL 3 -> 4, 250 / 300 XP (level x 100 curve)', (tester) async {
      SupaDb.testFixtures = _fixturesProgressed();
      await _pumpProfile(tester);
      expect(find.text('LEVEL 3'), findsOneWidget);
      expect(find.text('LEVEL 4'), findsOneWidget);
      expect(find.text('250'), findsOneWidget);
      expect(find.text(' / 300 XP'), findsOneWidget);
      expect(find.text('GOLD'), findsOneWidget);
      expect(find.text('Lv.3'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('stat cards: aligned 2x2 grid', () {
    testWidgets('four cells, row 1 shares a baseline, columns aligned, values gold', (tester) async {
      await _pumpProfile(tester);
      expect(find.text('Matches Played'), findsOneWidget);
      expect(find.text('Matches Won'), findsOneWidget);
      expect(find.text('Current Rank'), findsOneWidget);
      expect(find.text('Community Points'), findsOneWidget);
      // Row 1 labels share a vertical centre (both values are 32px).
      final playedY = tester.getCenter(find.text('Matches Played')).dy;
      final wonY = tester.getCenter(find.text('Matches Won')).dy;
      expect((playedY - wonY).abs(), lessThan(1.0));
      // Columns stay aligned: the two left-column labels share a
      // horizontal centre, and so do the two right-column labels
      // (the grid's equal Expanded halves).
      final playedX = tester.getCenter(find.text('Matches Played')).dx;
      final rankX = tester.getCenter(find.text('Current Rank')).dx;
      expect((playedX - rankX).abs(), lessThan(1.0));
      final wonX = tester.getCenter(find.text('Matches Won')).dx;
      final pointsX = tester.getCenter(find.text('Community Points')).dx;
      expect((wonX - pointsX).abs(), lessThan(1.0));
      // Row 1 sits above row 2.
      final rankY = tester.getCenter(find.text('Current Rank')).dy;
      expect(playedY, lessThan(rankY));
      // NOTE: row-2 labels do NOT share a baseline by design — the
      // tier value is 24px and the points value is 32px (pre-existing
      // mockup sizing, untouched by the restyle), so their labels sit
      // ~12px apart. That is the mockup's look, not a defect.
      // Every '0' value on the screen is the gold 32px stat value
      // (matches, wins, points — and the XP count).
      final zeroes = find.text('0');
      expect(zeroes, findsWidgets);
      for (final e in tester.widgetList<Text>(zeroes)) {
        expect(e.style?.color, kGold);
      }
      // Rank tier is white 24px (mockup), not gold.
      final bronze = tester.widget<Text>(find.text('BRONZE'));
      expect(bronze.style?.color, kText);
      expect(bronze.style?.fontSize, 24);
      expect(tester.takeException(), isNull);
    });
  });

  group('tabs: shared tab style, switching preserved', () {
    testWidgets('gold indicator + label, muted unselected, 14px bold labels', (tester) async {
      await _pumpProfile(tester);
      final tabBar = tester.widget<TabBar>(find.byType(TabBar));
      expect(tabBar.indicatorColor, kGold);
      expect(tabBar.indicatorWeight, 3);
      expect(tabBar.labelColor, kGold);
      expect(tabBar.unselectedLabelColor, kMuted);
      expect(tabBar.labelStyle?.fontSize, 14);
      expect(tabBar.labelStyle?.fontWeight, FontWeight.bold);
      expect(tabBar.unselectedLabelStyle?.fontSize, 14);
      expect(find.text('Overview'), findsOneWidget);
      expect(find.text('Match History'), findsWidgets);
      expect(find.text('Achievements'), findsNWidgets(2)); // tab + section header
      expect(tester.takeException(), isNull);
    });

    testWidgets('tapping tabs still switches content', (tester) async {
      await _pumpProfile(tester);
      await tester.tap(find.text('Achievements').first);
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('Win your first match'), findsOneWidget);
      expect(find.text('Locked'), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  });

  group('achievements preview: consistent cards, real lock states', () {
    // REDESIGN S10 (merged): the three badge cards use the shared
    // CARD radius (kRadiusCard, 18) per S10 §6 Screen 10 — S9 had
    // pinned kRadiusInput (14). The shared-radius intent is
    // unchanged: all three cards still share ONE radius.
    testWidgets('three badge cards share radius + locked border at 0 wins', (tester) async {
      await _pumpProfile(tester);
      final header = tester.widget<Text>(find.text('Achievements').last);
      expect(header.style?.fontSize, 18);
      expect(header.style?.fontWeight, FontWeight.bold);
      expect(find.text('View All'), findsOneWidget);
      for (final name in ['FIRST BLOOD', 'SURVIVALIST', 'SQUAD LEADER']) {
        expect(find.text(name), findsOneWidget);
        final card = find.ancestor(of: find.text(name), matching: find.byType(Container)).first;
        final decoration = tester.widget<Container>(card).decoration as BoxDecoration;
        expect(decoration.borderRadius, BorderRadius.circular(kRadiusCard));
        // Locked at 0 wins / 0 matches: muted border, 1px.
        expect((decoration.border as Border?)?.top.color, kBorder);
        expect((decoration.border as Border?)?.top.width, 1);
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('progressed user: all three preview badges unlocked (gold border)', (tester) async {
      SupaDb.testFixtures = _fixturesProgressed();
      await _pumpProfile(tester);
      for (final name in ['FIRST BLOOD', 'SURVIVALIST', 'SQUAD LEADER']) {
        final card = find.ancestor(of: find.text(name), matching: find.byType(Container)).first;
        final decoration = tester.widget<Container>(card).decoration as BoxDecoration;
        expect(decoration.borderRadius, BorderRadius.circular(kRadiusCard));
        expect((decoration.border as Border?)?.top.color, kGold);
        expect((decoration.border as Border?)?.top.width, 1.5);
      }
      expect(tester.takeException(), isNull);
    });
  });

  group('statistics / rank logic untouched', () {
    testWidgets('fixture values render; mockup sample values never appear', (tester) async {
      await _pumpProfile(tester);
      expect(find.text('Test Player'), findsOneWidget);
      expect(find.text('@testplayer'), findsOneWidget);
      expect(find.text('Member since Oct 2026'), findsOneWidget);
      expect(find.text('BRONZE'), findsOneWidget);
      expect(find.text(' / 100 XP'), findsOneWidget);
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
