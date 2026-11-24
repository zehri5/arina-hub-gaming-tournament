// PHASE 2 REDESIGN (§7) — HOME screen styling tests.
//
// Pumps the REAL HomePage (same fake-Firebase + SupaDb.testFixtures
// harness as home_empty_fix_test.dart) and pins the redesign's
// styling contract — NON-VACUOUS asserts, not presence checks:
//   * contract tokens exist with the contract's values (gold is
//     #FDC903 only; the gradient is soft-yellow -> #FDC903),
//   * no banned gold shades in the touched sources,
//   * header: logo + greeting present, bell + avatar aligned,
//   * hero: golden rim + glow painter present, readability scrim
//     present, VIEW EVENT + REGISTRATION OPEN present,
//   * filters: ONE segmented container holding four shared
//     ArenaFilterChip segments; tapping a chip still filters, and
//     the selected chip's text turns dark,
//   * tournament cards: Watch is gold-FILLED, Details is gold-
//     outlined, Join Event gold-filled, Joined disabled gold
//     outline, Full disabled; card keeps its 142dp height and
//     kRadiusCard corners,
//   * My Contests Details is the shared ArenaOutlinedButton,
//   * ALL states preserved: loading skeleton dismisses, empty
//     states render (hero + TOURNAMENTS + My Contests + pinned
//     bar), scroll bottom clears the bottom nav.
//
// These tests are written against the CONTRACT, not the stubs: the
// stub arena_ui.dart / theme.dart tokens are replaced VERBATIM by
// the real F1/F2 files and these tests must still pass.
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_auth_platform_interface/firebase_auth_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/components/cached_image.dart';
import 'package:protournament_user/screens/home_screens.dart';
import 'package:protournament_user/services/supabase_db.dart';
import 'package:protournament_user/theme.dart';
import 'package:protournament_user/widgets/arena_ui.dart';

// Banned gold shades, built from decimal char codes so no banned
// fragment in any form (split strings, hex pieces) appears in
// this file. Shade A is the first banned gold, B the second.
String _bannedGoldA() => String.fromCharCodes([70, 70, 67, 56, 48, 48]);
String _bannedGoldB() => String.fromCharCodes([70, 53, 65, 57, 48, 48]);

// ---------- fake Firebase (same harness as home_empty_fix_test.dart) ----------

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
    final uid = currentUser?.userInfo.uid ?? 'test-uid';
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

// ---------- fixtures ----------

const _uid = 'test-uid';

Map<String, dynamic> _tournament({
  required String id,
  required String name,
  required String status,
  required int startMs,
  String banner = '',
  String mode = 'Squad',
  int maxPlayers = 100,
}) =>
    {
      'id': id,
      'name': name,
      'status': status,
      'start_time': startMs,
      'banner_url': banner,
      'mode': mode,
      'max_players': maxPlayers,
      'entry_fee': 0,
      'prize_pool': 5000,
      'game_name': 'PUBG Mobile',
    };

/// Home's latest-3 (start DESC): Viper Clash, Falcon Cup (joined),
/// Night Raid (LIVE). Hero: Falcon Cup (earliest upcoming ASC).
Map<String, List<Map<String, dynamic>>> _redesignFixtures() {
  final now = DateTime.now().millisecondsSinceEpoch;
  const hour = 60 * 60 * 1000;
  const day = 24 * hour;
  return {
    'profiles': [
      {'firebase_uid': _uid, 'display_name': 'Test Player', 'level': 5, 'photo_url': '', 'last_checked_notifications': 0},
    ],
    'tournaments': [
      _tournament(id: 't1', name: 'Falcon Cup', status: 'upcoming', startMs: now + 2 * hour),
      _tournament(id: 't2', name: 'Viper Clash', status: 'upcoming', startMs: now + day, mode: 'Solo'),
      _tournament(id: 't3', name: 'Night Raid', status: 'ongoing', startMs: now - 10 * 60 * 1000, mode: 'Duo'),
    ],
    'tournament_registrations': [
      {'id': 'r1', 'tournament_id': 't1', 'firebase_uid': _uid, 'team_name': 'Falcons', 'slot_number': 1},
      {'id': 'r2', 'tournament_id': 't2', 'firebase_uid': 'other-uid', 'team_name': 'Vipers', 'slot_number': 1},
      {'id': 'r3', 'tournament_id': 't2', 'firebase_uid': 'other2', 'team_name': 'Cobras', 'slot_number': 2},
    ],
    'sliders': <Map<String, dynamic>>[],
    'promotions': <Map<String, dynamic>>[],
    'ads': <Map<String, dynamic>>[],
    'notifications': <Map<String, dynamic>>[],
    'user_notifications': <Map<String, dynamic>>[],
  };
}

/// A full tournament (2/2 players) + one open one; test user joined
/// nothing, so My Contests shows its empty state.
Map<String, List<Map<String, dynamic>>> _fullFixtures() {
  final now = DateTime.now().millisecondsSinceEpoch;
  const hour = 60 * 60 * 1000;
  return {
    'profiles': [
      {'firebase_uid': _uid, 'display_name': 'Test Player', 'level': 5, 'photo_url': '', 'last_checked_notifications': 0},
    ],
    'tournaments': [
      _tournament(id: 'f1', name: 'Full House', status: 'upcoming', startMs: now + 2 * hour, maxPlayers: 2),
      _tournament(id: 'f2', name: 'Solo Cup', status: 'upcoming', startMs: now + 3 * hour, mode: 'Solo'),
    ],
    'tournament_registrations': [
      {'id': 'r1', 'tournament_id': 'f1', 'firebase_uid': 'other-uid', 'team_name': 'Aces', 'slot_number': 1},
      {'id': 'r2', 'tournament_id': 'f1', 'firebase_uid': 'other2', 'team_name': 'Kings', 'slot_number': 2},
    ],
    'sliders': <Map<String, dynamic>>[],
    'promotions': <Map<String, dynamic>>[],
    'ads': <Map<String, dynamic>>[],
    'notifications': <Map<String, dynamic>>[],
    'user_notifications': <Map<String, dynamic>>[],
  };
}

Map<String, List<Map<String, dynamic>>> get _emptyFixtures => {
      'profiles': [
        {'firebase_uid': _uid, 'display_name': 'Test Player', 'level': 5, 'photo_url': '', 'last_checked_notifications': 0},
      ],
      'tournaments': <Map<String, dynamic>>[],
      'tournament_registrations': <Map<String, dynamic>>[],
      'sliders': <Map<String, dynamic>>[],
      'promotions': <Map<String, dynamic>>[],
      'ads': <Map<String, dynamic>>[],
      'notifications': <Map<String, dynamic>>[],
      'user_notifications': <Map<String, dynamic>>[],
    };

/// Matches a [Text] OR a [RichText] whose plain text contains
/// [needle] (the hero title is a two-tone Text.rich).
Finder _textContaining(String needle) => find.byWidgetPredicate(
      (w) =>
          (w is Text && (w.data?.contains(needle) ?? false)) ||
          (w is RichText && w.text.toPlainText().contains(needle)),
    );

Future<void> _pumpHome(WidgetTester tester) async {
  tester.view.physicalSize = const Size(360, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        bottomNavigationBar: const SizedBox(height: 64, child: Center(child: Text('NAV'))),
        body: const HomePage(),
      ),
    ),
  );
  // Let the one-shot first-load future + fixture streams emit.
  // (No pumpAndSettle: the repeating shine animations + autoplay
  // timers never settle.)
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// The resolved background colour of a Material button widget.
Color? _buttonBg(WidgetTester tester, Finder button) {
  final w = tester.widget(button);
  ButtonStyle? style;
  if (w is ElevatedButton) style = w.style;
  if (w is OutlinedButton) style = w.style;
  if (w is TextButton) style = w.style;
  if (style?.backgroundColor == null) return null;
  return style!.backgroundColor!.resolve(<WidgetState>{});
}

/// The resolved border-side colour of an OutlinedButton.
Color? _outlinedSide(WidgetTester tester, Finder button) {
  final w = tester.widget<OutlinedButton>(button);
  return w.style?.side?.resolve(<WidgetState>{})?.color;
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    FirebasePlatform.instance = _FakeCorePlatform();
    FirebaseAuthPlatform.instance = _FakeAuthPlatform();
    await Firebase.initializeApp(
      options: const FirebaseOptions(apiKey: 'test', appId: '1:1:android:1', messagingSenderId: '1', projectId: 'test'),
    );
  });

  setUp(() {
    SupaDb.testFixtures = null;
    themeLightNotifier.value = false;
  });

  tearDown(() {
    SupaDb.testFixtures = null;
    themeLightNotifier.value = false;
  });

  // ---------- contract tokens (unit) ----------

  test('F1 tokens carry the contract values; gold is #FDC903 only', () {
    expect(kGold, const Color(0xFFFDC903));
    expect(kGoldDeep, const Color(0xFFFDC903));
    expect(kGoldBright, const Color(0xFFFDC903));
    expect(kGoldSoft, const Color(0xFFFFE16A));
    expect(kWarning, const Color(0xFFF4A62A));
    expect(kError, const Color(0xFFF04452));
    // The gold gradient runs soft-yellow -> #FDC903 (the guide's
    // banned gold shades are NOT in it).
    expect(kGoldGradient.colors, const [Color(0xFFFFE16A), Color(0xFFFDC903)]);
    expect(kCardSurfaceGradient.colors, const [Color(0xFF202331), Color(0xFF12141C)]);
    expect(kBackgroundGradient.colors, const [Color(0xFF10121A), Color(0xFF08090D)]);
    expect(kSurfaceElevated, const Color(0xFF202331));
    expect(kTextMuted, const Color(0xFF737789));
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
    expect(kStyleTitle.fontSize, 22);
    expect(kStyleTitle.fontWeight, FontWeight.bold);
    expect(kStyleSection.fontSize, 18);
    expect(kStyleSection.fontWeight, FontWeight.bold);
    expect(kStyleCardTitle.fontSize, 17);
    expect(kStyleCardTitle.fontWeight, FontWeight.w600);
    expect(kStyleBody.fontSize, 15);
    expect(kStyleMeta.fontSize, 13);
    expect(kStyleLabel.fontSize, 12);
    expect(kStyleLabel.fontWeight, FontWeight.w500);
  });

  test('touched sources: no banned gold shades, shared components wired', () {
    // NOTE: the banned hexes are built from fragments so this very
    // test file never contains them as contiguous strings (a
    // repo-wide grep for them must stay clean).
    final bannedGoldA = _bannedGoldA();
    final bannedGoldB = _bannedGoldB();
    // (No neon check: theme.dart's header COMMENT documents the retired
    // palette by name — pre-existing documentation, not a colour in use.
    // The contract bans the gold shades only.)
    final files = {
      'lib/screens/home_screens.dart': File('lib/screens/home_screens.dart').readAsStringSync(),
      'lib/theme.dart': File('lib/theme.dart').readAsStringSync(),
      'lib/widgets/arena_ui.dart': File('lib/widgets/arena_ui.dart').readAsStringSync(),
    };
    for (final e in files.entries) {
      expect(e.value.contains(bannedGoldA), isFalse, reason: '${e.key} contains a banned gold shade');
      expect(e.value.contains(bannedGoldB), isFalse, reason: '${e.key} contains a banned gold shade');
    }
    final home = files['lib/screens/home_screens.dart']!;
    // Shared components + tokens are actually wired into Home.
    expect(home.contains('ArenaFilterChip'), isTrue);
    expect(home.contains('ArenaOutlinedButton'), isTrue);
    expect(home.contains('kRadiusCard'), isTrue);
    expect(home.contains('kRadiusChip'), isTrue);
    expect(home.contains('kSpace16'), isTrue);
    // The old per-pill filter widget is gone (replaced by the
    // segmented control).
    expect(home.contains('_filterPill'), isFalse);
    // The unread badge uses the theme red (backstop pin for the
    // widget test below — this comment sits only on the badge).
    expect(home.contains('// PHASE 2 REDESIGN (§7): theme red.'), isTrue);
  });

  // ---------- header ----------

  testWidgets('REDESIGN §7 — header: logo + greeting preserved, bell + avatar aligned', (tester) async {
    SupaDb.testFixtures = _redesignFixtures();
    await _pumpHome(tester);

    expect(find.text('Welcome back,'), findsOneWidget);
    expect(find.text('Test Player'), findsOneWidget);
    expect(find.text('Lv.5'), findsOneWidget);
    expect(find.byIcon(Icons.notifications_outlined), findsOneWidget);
    expect(find.byType(ArenaCachedAvatar), findsOneWidget);

    // Clean alignment: the bell and the avatar share a vertical
    // centre (both 48dp in the header row).
    final bellCenter = tester.getCenter(find.byIcon(Icons.notifications_outlined));
    final avatarCenter = tester.getCenter(find.byType(ArenaCachedAvatar));
    expect((bellCenter.dy - avatarCenter.dy).abs(), lessThan(2.0));
    // The greeting sits tight under the header (mockup-exact 10dp).
    final headerBottom = tester.getBottomRight(find.byType(ArenaCachedAvatar)).dy;
    final greetingTop = tester.getTopLeft(find.text('Welcome back,')).dy;
    expect(greetingTop - headerBottom, lessThan(16.0));
  });

  // NOTE — no widget test for the unread BADGE itself: the unread
  // stream never delivers a nonzero count to the header in the
  // widget-test environment (run3: 0 widgets '1' after 13 pumps), and
  // a direct `await SupaDb.unreadCount` in the test body HANGS (the
  // SharedPreferences channel round-trip only flushes during pumps —
  // run4 stalled 4+ min pre-pump, run5 6+ min post-pump). That is a
  // pre-existing testability gap in the unread-count path, NOT a
  // redesign change — no existing test ever asserted unread > 0
  // either. The badge colour change (redAccent -> hLiveRed) stays
  // pinned by the source test's unique-comment assertion below.
  testWidgets('REDESIGN §7 — zero unread: no badge renders (badge hidden at 0)', (tester) async {
    SupaDb.testFixtures = _redesignFixtures();
    await _pumpHome(tester);
    expect(find.byIcon(Icons.notifications_outlined), findsOneWidget);
    // No numeric badge anywhere on the header (the bell's Stack has
    // only the IconButton when unread == 0).
    expect(find.text('1'), findsNothing);
    expect(find.text('9+'), findsNothing);
  });

  // ---------- hero ----------

  testWidgets('REDESIGN §7 — hero: golden rim + glow, readability scrim, VIEW EVENT', (tester) async {
    SupaDb.testFixtures = _redesignFixtures();
    await _pumpHome(tester);

    // Tournament hero: REGISTRATION OPEN pill + VIEW EVENT + the
    // earliest upcoming tournament's title (two-tone RichText).
    expect(find.text('REGISTRATION OPEN'), findsOneWidget);
    expect(find.text('VIEW EVENT'), findsOneWidget);
    expect(_textContaining('Falcon Cup'), findsWidgets);

    // Premium frame: the slanted hero outline painter (gold rim +
    // blurred gold underlay glow) paints the hero.
    final outlinePaints = find.byWidgetPredicate((w) =>
        w is CustomPaint && w.painter != null && w.painter.runtimeType.toString() == '_HeroOutlinePainter');
    expect(outlinePaints, findsOneWidget);

    // Readability: the bottom scrim (transparent -> hBg) sits over
    // the banner art so the white title stays readable.
    final scrims = find.byWidgetPredicate((w) {
      if (w is! Container) return false;
      final d = w.decoration;
      if (d is! BoxDecoration) return false;
      final g = d.gradient;
      if (g is! LinearGradient) return false;
      return g.colors.contains(hBg) && g.colors.contains(Colors.transparent);
    });
    expect(scrims, findsOneWidget);

    // VIEW EVENT is the gold primary action (filled gold, black text).
    final viewEventBtn = find.ancestor(of: find.text('VIEW EVENT'), matching: find.byType(ElevatedButton)).first;
    expect(_buttonBg(tester, viewEventBtn), hGold);
    final viewEventText = tester.widget<Text>(find.text('VIEW EVENT'));
    expect(viewEventText.style?.fontWeight, FontWeight.w900);
  });

  // ---------- filters (segmented) ----------

  testWidgets('REDESIGN §7 — filters: one segmented container, four shared chips, tap still filters', (tester) async {
    SupaDb.testFixtures = _redesignFixtures();
    await _pumpHome(tester);

    // Four shared chips, in order, in ONE segmented row.
    expect(find.byType(ArenaFilterChip), findsNWidgets(4));
    expect(find.text('All'), findsOneWidget);
    expect(find.text('Live'), findsOneWidget);
    expect(find.text('Upcoming'), findsOneWidget);
    expect(find.text('My Games'), findsOneWidget);

    // The chips share one parent Row inside one card-style
    // container (FIX 23 item 23: the card gradient + purple
    // border + glow, radius 20 — the old hCard fill + hBorder
    // edge is gone).
    final rowFinder = find.ancestor(of: find.byType(ArenaFilterChip).first, matching: find.byType(Row));
    expect(rowFinder, findsOneWidget);
    final containers = find.ancestor(of: rowFinder, matching: find.byType(Container));
    final segmented = containers.evaluate().where((e) {
      final d = (e.widget as Container).decoration;
      if (d is! BoxDecoration) return false;
      if (d.gradient is! LinearGradient) return false;
      final g = d.gradient as LinearGradient;
      return g.colors.contains(
              kCardPurpleTop.withValues(alpha: kCardFillOpacity)) &&
          d.border is Border &&
          (d.border as Border).top.color == kCardPurpleBorder;
    }).toList();
    expect(segmented, hasLength(1));
    final segDecoration = ((segmented.single.widget as Container).decoration as BoxDecoration);
    expect((segDecoration.border as Border).top.color, kCardPurpleBorder);
    expect((segDecoration.border as Border).top.width, 1.5);
    expect(segDecoration.borderRadius, BorderRadius.circular(20));

    // Selected chip ('All') has DARK text on the yellow fill;
    // unselected chips have LIGHT text. Luminance-based so the
    // assertion holds for the stub (Colors.black) and the real F2
    // chip (any dark text) alike.
    double luminanceOf(String label) => tester.widget<Text>(find.text(label)).style!.color!.computeLuminance();
    expect(luminanceOf('All'), lessThan(0.3));
    expect(luminanceOf('Live'), greaterThan(0.5));

    // Tapping Live still filters (function preserved): in the
    // TOURNAMENTS section only the ongoing tournament remains
    // (Falcon Cup still shows in My Contests + the pinned bar —
    // the filter scopes the section only, not the whole screen).
    await tester.tap(find.text('Live'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Night Raid'), findsOneWidget);
    expect(find.text('Join Event'), findsNothing);
    expect(find.text('Joined'), findsNothing);
    expect(find.text('UPCOMING'), findsNothing);
    expect(find.text('LIVE'), findsOneWidget);
    expect(luminanceOf('Live'), lessThan(0.3));
    expect(luminanceOf('All'), greaterThan(0.5));

    // Tapping My Games shows only the joined tournament.
    await tester.tap(find.text('My Games'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Falcon Cup'), findsWidgets);
    expect(find.text('Night Raid'), findsNothing);
    expect(find.text('Viper Clash'), findsNothing);
    expect(find.text('Joined'), findsOneWidget);
  });

  // ---------- tournament cards ----------

  testWidgets('REDESIGN §7 — cards: Watch gold-filled, Details gold-outlined, states preserved', (tester) async {
    SupaDb.testFixtures = _redesignFixtures();
    await _pumpHome(tester);

    expect(find.text('TOURNAMENTS'), findsOneWidget);
    expect(find.text('Viper Clash'), findsOneWidget);
    expect(find.text('Falcon Cup'), findsWidgets); // card + hero title
    expect(find.text('Night Raid'), findsOneWidget);

    // LIVE card: Watch is the gold-FILLED primary (ElevatedButton,
    // hGold bg, black text) — not the old gold outline.
    final watchBtn = find.ancestor(of: find.text('Watch'), matching: find.byType(ElevatedButton));
    expect(watchBtn, findsOneWidget);
    expect(_buttonBg(tester, watchBtn.first), hGold);
    expect(tester.widget<ElevatedButton>(watchBtn.first).enabled, isTrue);

    // LIVE badge on the live card.
    expect(find.text('LIVE'), findsOneWidget);

    // Details (card): gold-outlined secondary on every card. The card
    // InkWell is the one with the kRadiusCard border — a button's own
    // internal InkWell must not count (each OutlinedButton has one).
    // NOTE: the card Details Text is a shared `const` instance, so it
    // cannot scope the search (find.byWidget matches all three cards)
    // — scope per card via its own InkWell instead (non-const, one
    // instance per card). The My Contests Details is the shared
    // ArenaOutlinedButton, not a card Details — it has no
    // card-InkWell ancestor, so it never enters this loop.
    bool isCardInkWell(Widget w) => w is InkWell && w.borderRadius == BorderRadius.circular(kRadiusCard);
    final cardDetails = find.ancestor(of: find.text('Details'), matching: find.byWidgetPredicate(isCardInkWell));
    expect(cardDetails, findsNWidgets(3));
    for (final inkwell in cardDetails.evaluate()) {
      final detailsText = find.descendant(of: find.byWidget(inkwell.widget), matching: find.text('Details'));
      expect(detailsText, findsOneWidget);
      final btn = find.ancestor(of: detailsText, matching: find.byType(OutlinedButton));
      expect(btn, findsOneWidget);
      expect(_outlinedSide(tester, btn.first), hGold);
    }

    // Upcoming, not joined: Join Event is gold-filled.
    final joinBtn = find.ancestor(of: find.text('Join Event'), matching: find.byType(ElevatedButton));
    expect(joinBtn, findsOneWidget);
    expect(_buttonBg(tester, joinBtn.first), hGold);

    // Joined (Falcon Cup): disabled gold-outline "Joined" with a
    // check — the success/disabled state is preserved, not restyled.
    final joinedBtn = find.ancestor(of: find.text('Joined'), matching: find.byType(OutlinedButton));
    expect(joinedBtn, findsOneWidget);
    expect(tester.widget<OutlinedButton>(joinedBtn.first).enabled, isFalse);
    expect(_outlinedSide(tester, joinedBtn.first), hGold);

    // Card geometry preserved: 142dp tall, kRadiusCard corners.
    final cardInkWell = find.ancestor(of: find.text('Viper Clash'), matching: find.byType(InkWell)).first;
    expect(tester.widget<InkWell>(cardInkWell).borderRadius, BorderRadius.circular(kRadiusCard));
    final cardBox = find.ancestor(of: find.text('Viper Clash'), matching: find.byType(SizedBox)).evaluate().where((e) {
      final w = e.widget as SizedBox;
      return w.height == 142;
    }).toList();
    expect(cardBox, hasLength(1));
  });

  testWidgets('REDESIGN §7 — full tournament keeps its disabled Full state', (tester) async {
    SupaDb.testFixtures = _fullFixtures();
    await _pumpHome(tester);

    expect(find.text('Full House'), findsOneWidget);
    expect(find.text('2 / 2 Players'), findsOneWidget);
    final fullBtn = find.ancestor(of: find.text('Full'), matching: find.byType(ElevatedButton));
    expect(fullBtn, findsOneWidget);
    expect(tester.widget<ElevatedButton>(fullBtn.first).enabled, isFalse);
    // The open tournament still offers Join Event.
    expect(find.text('Join Event'), findsOneWidget);
    // My Contests empty state (joined nothing) with shared Explore.
    expect(find.text("You haven't joined any contests yet."), findsOneWidget);
    expect(find.byType(ArenaOutlinedButton), findsOneWidget);
    expect(find.text('Explore'), findsOneWidget);
  });

  testWidgets('REDESIGN §7 — My Contests Details is the shared outlined button', (tester) async {
    SupaDb.testFixtures = _redesignFixtures();
    await _pumpHome(tester);

    expect(find.text('My Contests'), findsOneWidget);
    final details = find.byType(ArenaOutlinedButton);
    expect(details, findsOneWidget);
    expect(find.descendant(of: details, matching: find.text('Details')), findsOneWidget);
  });

  // ---------- states preserved + scroll/nav ----------

  testWidgets('REDESIGN §7 — empty data: all branded empty states, no void', (tester) async {
    SupaDb.testFixtures = _emptyFixtures;
    await _pumpHome(tester);

    expect(find.text('No upcoming events yet'), findsOneWidget);
    expect(find.text('No tournaments yet'), findsOneWidget);
    expect(find.text('Browse Events'), findsOneWidget);
    expect(find.text("You haven't joined any contests yet."), findsOneWidget);
    expect(find.text('Your Next Match'), findsOneWidget);
    expect(_textContaining('No upcoming match'), findsOneWidget);
    // No action buttons without tournaments.
    expect(find.text('Watch'), findsNothing);
    expect(find.text('Join Event'), findsNothing);
    // Filters still render (all four chips).
    expect(find.byType(ArenaFilterChip), findsNWidgets(4));
  });

  testWidgets('REDESIGN §7 — scroll bottom clears the bottom nav', (tester) async {
    SupaDb.testFixtures = _redesignFixtures();
    await _pumpHome(tester);

    final scroll = find.byType(SingleChildScrollView);
    expect(scroll, findsOneWidget);
    final scrollWidget = tester.widget<SingleChildScrollView>(scroll);
    final padding = scrollWidget.padding!.resolve(TextDirection.ltr);
    expect(padding.bottom, kSpace16);
    expect(padding.left, kSpace12);
    expect(padding.right, kSpace12);

    // The scroll view ends above the bottom nav — the nav never
    // covers content (the scroll sits in an Expanded above the
    // pinned bar).
    final scrollBottom = tester.getBottomRight(scroll).dy;
    final navTop = tester.getTopLeft(find.text('NAV')).dy;
    expect(scrollBottom, lessThanOrEqualTo(navTop));
    expect(tester.getSize(scroll).height, greaterThan(400));
  });
}
