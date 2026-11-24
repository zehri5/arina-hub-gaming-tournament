// REDESIGN PHASE 2 — GROUP S10: ACHIEVEMENTS (guide §6 Screen 10).
// Pumps the REAL ProfilePage (Achievements lives in its Overview /
// Achievements tab + the options-tile list) with fixture data via the
// SupaDb.testFixtures seam and the fake-Firebase pattern from
// profile_page_mockup18_test.dart (platform-interface fakes, no
// network). No pumpAndSettle — ArenaEmberDots / FireSparks repeat
// forever.
//
// Pins the S10 restyle (styling ONLY — no logic/flow/navigation/data
// changes):
//   1. F1 contract tokens exist with the contract values (gold rule:
//      #FDC903 only — the guide's two suggested gold shades are banned
//      and appear nowhere).
//   2. Consistent Achievements header (title + View All action).
//   3. Summary cards: icons + labels aligned, equal heights.
//   4. Achievements tab rows: token type scale, locked/unlocked +
//      progress per the REAL fixture counts.
//   5. S10 list tiles (Frames, Match History, Player Stats, Community
//      Rewards, Activity History, Your Invites, Friends & Requests,
//      Messages, Following): icon + label + chevron consistent in
//      every row; navigation preserved.
//   6. F2 stub components compile and behave (buttons press,
//      pressable taps).
import 'package:firebase_core/firebase_core.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_auth_platform_interface/firebase_auth_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/components/premium_badge.dart';
import 'package:protournament_user/screens/frames_screen.dart';
import 'package:protournament_user/screens/more_screens.dart';
import 'package:protournament_user/screens/player_stats.dart';
import 'package:protournament_user/services/supabase_db.dart';
import 'package:protournament_user/theme.dart';
import 'package:protournament_user/widgets/arena_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _uid = 's10-test-uid';

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

// 0 matches / 0 wins / Rs 0 — every achievement Locked.
Map<String, List<Map<String, dynamic>>> _lockedFixtures() => {
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

// 12 matches / 6 wins / Rs 1,500 — First Blood, Survivalist, Squad
// Leader, Top Earner Unlocked; Veteran (50 matches) still Locked.
Map<String, List<Map<String, dynamic>>> _unlockedFixtures() => {
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
          'total_matches': 12,
          'won_matches': 6,
          'total_earnings': 1500,
        },
      ],
      'match_history': [],
      'admin_config': [],
    };

Future<void> _pumpProfile(WidgetTester tester, {bool unlocked = false}) async {
  SupaDb.testFixtures = unlocked ? _unlockedFixtures() : _lockedFixtures();
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

Future<void> _pumpFrames(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// The ListTile for the S10 options-tile with this label.
ListTile _tileOf(WidgetTester tester, String label) {
  final finder = find.ancestor(of: find.text(label), matching: find.byType(ListTile));
  expect(finder, findsOneWidget, reason: 'one ListTile for "$label"');
  return tester.widget<ListTile>(finder);
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
    SupaDb.testFixtures = _lockedFixtures();
  });

  tearDown(() {
    SupaDb.testFixtures = null;
  });

  group('F1 contract tokens (stub values per CONTRACT.md)', () {
    test('gold rule: kGold is #FDC903 only; gradient uses the substituted shades', () {
      expect(kGold, const Color(0xFFFDC903));
      expect(kGoldDeep, const Color(0xFFFDC903));
      expect(kGoldBright, const Color(0xFFFDC903));
      // kGoldGradient substitutes #FFE16A -> #FDC903 (the guide's two
      // suggested gold shades are BANNED by the gold rule, so the
      // gradient must be EXACTLY these two colours — nothing else).
      expect(kGoldGradient.colors, const [Color(0xFFFFE16A), Color(0xFFFDC903)]);
      expect(kGoldGradient.colors, hasLength(2));
      expect(kGoldSoft, const Color(0xFFFFE16A));
    });

    test('surface / muted / semantic token values', () {
      expect(kSurfaceElevated, const Color(0xFF202331));
      expect(kTextMuted, const Color(0xFF737789));
      expect(kWarning, const Color(0xFFF4A62A));
      expect(kError, const Color(0xFFF04452));
      expect(kCardSurfaceGradient.colors, const [Color(0xFF202331), Color(0xFF12141C)]);
      expect(kBackgroundGradient.colors, const [Color(0xFF10121A), Color(0xFF08090D)]);
    });

    test('spacing + radii scales', () {
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

    test('text-style scale sizes/weights', () {
      expect(kStyleTitle.fontSize, 22);
      expect(kStyleTitle.fontWeight, FontWeight.bold);
      expect(kStyleSection.fontSize, 18);
      expect(kStyleSection.fontWeight, FontWeight.bold);
      expect(kStyleCardTitle.fontSize, 17);
      expect(kStyleCardTitle.fontWeight, FontWeight.w600);
      expect(kStyleBody.fontSize, 15);
      expect(kStyleBody.fontWeight, FontWeight.normal);
      expect(kStyleMeta.fontSize, 13);
      expect(kStyleLabel.fontSize, 12);
      expect(kStyleLabel.fontWeight, FontWeight.w500);
    });
  });

  group('F2 stub components behave', () {
    testWidgets('primary button + pressable fire their callbacks; chip + badge render', (tester) async {
      var pressed = 0;
      var tapped = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              ArenaPrimaryButton(onPressed: () => pressed++, child: const Text('Go')),
              ArenaPressable(onTap: () => tapped++, child: const Text('Press me')),
              const ArenaFilterChip(label: 'All', selected: true, onTap: _noop),
              const ArenaLiveBadge(),
              const ArenaLoadingIndicator(),
            ],
          ),
        ),
      ));
      await tester.tap(find.text('Go'));
      await tester.tap(find.text('Press me'));
      expect(pressed, 1);
      expect(tapped, 1);
      expect(find.text('All'), findsOneWidget);
      expect(find.text('LIVE'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('achievements preview header (consistent header)', () {
    testWidgets('title uses the shared section style; View All is gold + wired via ArenaPressable', (tester) async {
      await _pumpProfile(tester);
      // Two 'Achievements' texts: the Tab label (no explicit style)
      // and the section header (kStyleSection).
      final headers = tester.widgetList<Text>(find.text('Achievements')).where((t) => t.style == kStyleSection).toList();
      expect(headers, hasLength(1));
      expect(headers.single.style?.fontSize, 18);
      expect(headers.single.style?.fontWeight, FontWeight.bold);
      // View All: gold 14 bold + gold arrow, pressed through the
      // shared pressable (same behaviour as before).
      final viewAll = tester.widget<Text>(find.text('View All'));
      expect(viewAll.style?.color, kGold);
      expect(viewAll.style?.fontSize, 14);
      expect(viewAll.style?.fontWeight, FontWeight.bold);
      final arrow = tester.widget<Icon>(find.byIcon(Icons.arrow_forward));
      expect(arrow.color, kGold);
      expect(arrow.size, 16);
      final pressable = find.ancestor(of: find.text('View All'), matching: find.byType(ArenaPressable));
      expect(pressable, findsOneWidget);
      expect(tester.widget<ArenaPressable>(pressable).onTap, isNotNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets('View All still switches to the Achievements tab', (tester) async {
      await _pumpProfile(tester);
      await tester.tap(find.text('View All'));
      await _pumpFrames(tester);
      expect(find.text('Win your first match'), findsOneWidget);
      expect(find.text('Achievements  (0 / 5 unlocked)'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('achievement summary cards (aligned icons + labels)', () {
    testWidgets('three mockup badge cards render with aligned labels + equal heights', (tester) async {
      await _pumpProfile(tester);
      expect(find.text('FIRST BLOOD'), findsOneWidget);
      expect(find.text('SURVIVALIST'), findsOneWidget);
      expect(find.text('SQUAD LEADER'), findsOneWidget);
      // Labels aligned: same top edge across the row.
      final tops = ['FIRST BLOOD', 'SURVIVALIST', 'SQUAD LEADER'].map((l) => tester.getTopLeft(find.text(l)).dy).toList();
      expect((tops[0] - tops[1]).abs(), lessThan(1.0));
      expect((tops[1] - tops[2]).abs(), lessThan(1.0));
      // Cards equal height (stretched row) + same top edge, so the
      // 44px icons inside sit at the same height too.
      Size cardSize(String label) {
        final containers = tester.widgetList<Container>(find.ancestor(of: find.text(label), matching: find.byType(Container)));
        final card = containers.firstWhere((c) => c.decoration is BoxDecoration && (c.decoration as BoxDecoration).gradient != null);
        return tester.getSize(find.byWidget(card));
      }

      final sizes = ['FIRST BLOOD', 'SURVIVALIST', 'SQUAD LEADER'].map(cardSize).toList();
      expect(sizes[0].height, sizes[1].height);
      expect(sizes[1].height, sizes[2].height);
      // The two emblem icons align at the same top edge.
      final emblems = find.byType(PremiumEmblemIcon);
      expect(emblems, findsNWidgets(2));
      final eTops = [tester.getTopLeft(emblems.at(0)).dy, tester.getTopLeft(emblems.at(1)).dy];
      expect((eTops[0] - eTops[1]).abs(), lessThan(1.0));
      expect(tester.takeException(), isNull);
    });

    testWidgets('locked fixture: all three preview badges show the lock mark', (tester) async {
      await _pumpProfile(tester);
      // One lock icon per locked preview badge (0 wins / 0 matches).
      expect(find.byIcon(Icons.lock), findsNWidgets(3));
      expect(tester.takeException(), isNull);
    });

    testWidgets('unlocked fixture: the three preview badges show no lock mark', (tester) async {
      await _pumpProfile(tester, unlocked: true);
      expect(find.byIcon(Icons.lock), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('achievements tab (full list, real states)', () {
    testWidgets('locked fixture: header count + all five rows Locked with real progress', (tester) async {
      await _pumpProfile(tester);
      await tester.tap(find.text('View All'));
      await _pumpFrames(tester);
      // Header: shared section size/weight, gold.
      final header = tester.widget<Text>(find.text('Achievements  (0 / 5 unlocked)'));
      expect(header.style?.fontSize, 18);
      expect(header.style?.fontWeight, FontWeight.bold);
      expect(header.style?.color, kGold);
      // Rows: token type scale.
      expect(tester.widget<Text>(find.text('First Blood')).style, kStyleCardTitle);
      expect(tester.widget<Text>(find.text('Survivalist')).style, kStyleCardTitle);
      expect(tester.widget<Text>(find.text('Squad Leader')).style, kStyleCardTitle);
      expect(tester.widget<Text>(find.text('Win your first match')).style, kStyleMeta);
      expect(tester.widget<Text>(find.text('Play 10 matches')).style, kStyleMeta);
      // All five Locked, in the muted token colour; real progress.
      expect(find.text('Locked'), findsNWidgets(5));
      expect(find.text('Unlocked'), findsNothing);
      for (final t in tester.widgetList<Text>(find.text('Locked'))) {
        expect(t.style?.color, kTextMuted);
        expect(t.style?.fontSize, 12);
        expect(t.style?.fontWeight, FontWeight.bold);
      }
      expect(find.text('0 / 1 win'), findsOneWidget);
      expect(find.text('0 / 10 matches'), findsOneWidget);
      expect(find.text('0 / 5 wins'), findsOneWidget);
      expect(find.text('0 / 50 matches'), findsOneWidget);
      expect(find.text('Rs 0.00 / Rs 1,000'), findsOneWidget);
      expect(tester.widget<Text>(find.text('0 / 1 win')).style, kStyleMeta);
      expect(tester.takeException(), isNull);
    });

    testWidgets('unlocked fixture: 4/5 unlocked, Veteran still locked, progress real', (tester) async {
      await _pumpProfile(tester, unlocked: true);
      await tester.tap(find.text('View All'));
      await _pumpFrames(tester);
      expect(find.text('Achievements  (4 / 5 unlocked)'), findsOneWidget);
      expect(find.text('Unlocked'), findsNWidgets(4));
      expect(find.text('Locked'), findsOneWidget); // Veteran only
      for (final t in tester.widgetList<Text>(find.text('Unlocked'))) {
        expect(t.style?.color, kGold);
        expect(t.style?.fontSize, 12);
        expect(t.style?.fontWeight, FontWeight.bold);
      }
      expect(find.text('6 / 1 win'), findsOneWidget);
      expect(find.text('12 / 10 matches'), findsOneWidget);
      expect(find.text('6 / 5 wins'), findsOneWidget);
      expect(find.text('12 / 50 matches'), findsOneWidget);
      expect(find.text('Rs 1500.00 / Rs 1,000'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('S10 list tiles (icon + label + chevron consistent)', () {
    const s10Tiles = {
      'Frames': Icons.emoji_events,
      'Match History': Icons.history,
      'Player Stats': Icons.bar_chart,
      'Community Rewards': Icons.card_giftcard,
      'Activity History': Icons.history_toggle_off,
      'Your Invites': Icons.person_add_alt,
      'Friends & Requests': Icons.people,
      'Messages': Icons.message,
      'Following': Icons.visibility,
    };

    testWidgets('all nine S10 tiles exist with the same row treatment', (tester) async {
      await _pumpProfile(tester);
      for (final entry in s10Tiles.entries) {
        final tile = _tileOf(tester, entry.key);
        final leading = tile.leading as Icon;
        expect(leading.icon, entry.value, reason: '${entry.key} keeps its icon');
        expect(leading.color, kGold, reason: '${entry.key} leading is gold');
        expect(leading.size, 22, reason: '${entry.key} leading size 22');
        final title = tile.title as Text;
        expect(title.data, entry.key);
        expect(title.style, kStyleBody, reason: '${entry.key} label uses kStyleBody');
        final trailing = tile.trailing as Icon;
        expect(trailing.icon, Icons.chevron_right, reason: '${entry.key} chevron');
        expect(trailing.color, kTextMuted, reason: '${entry.key} chevron muted');
        expect(trailing.size, 20, reason: '${entry.key} chevron size 20');
        expect(tile.onTap, isNotNull, reason: '${entry.key} keeps its tap');
        expect(tile.minTileHeight, 48, reason: '${entry.key} touch height 48');
        expect(tile.horizontalTitleGap, kSpace12, reason: '${entry.key} icon/label gap');
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('Frames tile still opens the Frames shop', (tester) async {
      await _pumpProfile(tester);
      await tester.ensureVisible(find.text('Frames'));
      await tester.tap(find.text('Frames'));
      await _pumpFrames(tester);
      expect(find.byType(FramesShopPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Player Stats tile still opens Player Stats', (tester) async {
      await _pumpProfile(tester);
      await tester.ensureVisible(find.text('Player Stats'));
      await tester.tap(find.text('Player Stats'));
      await _pumpFrames(tester);
      expect(find.byType(PlayerStatsPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}

void _noop() {}
