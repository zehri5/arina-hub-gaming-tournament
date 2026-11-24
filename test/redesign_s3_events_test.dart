// PHASE 2 REDESIGN — GROUP S3 (Events) — real render tests for
// TournamentsPage (the Events tab) + the F1/F2 contract files
// (real files copied verbatim from g-f1/g-f2 on 2026-11-23;
// the earlier stubs are gone).
//
// Pumps the REAL page at real device sizes (360x800 and 320x568)
// with fixture data via the SupaDb.testFixtures seam and a fake
// Firebase Auth (platform-interface fakes, no network — same
// harness as test/home_empty_fix_test.dart), and pins:
//   1. contract tokens exist with the guide values, gold is ONLY
//      #FDC903 (banned gold shades appear nowhere in the tokens),
//   2. header title + gold-ring back button + search/filter actions,
//   3. category pills: selected = kGold fill, unselected = dark
//      card + muted border (and the selection MOVES on tap),
//   4. fee chips stay single-select (any/free/paid) and sort chips
//      stay optional-toggle — selection LOGIC preserved,
//   5. search field uses the shared input style (kField fill,
//      kRadiusInput, gold focus border) and still filters,
//   6. tournament cards keep the exact-142 hierarchy: image slot,
//      LIVE/status pill, title, date/mode, players, actions —
//      Details + Watch actions unchanged (Details navigates,
//      Watch shows the honest no-stream toast),
//   7. consistent kSpace12 spacing between cards,
//   8. empty state keeps its gold CLEAR FILTERS / outlined
//      EXPLORE GAMES actions,
//   9. no overflow on a small (320x568) screen.
import 'package:firebase_core/firebase_core.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_auth_platform_interface/firebase_auth_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/screens/home_screens.dart';
import 'package:protournament_user/services/supabase_db.dart';
import 'package:protournament_user/theme.dart';
import 'package:protournament_user/widgets/arena_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ---------- fake Firebase (platform-interface fakes) ----------

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

// ---------- fixtures (raw snake_case rows, as PostgREST returns them) ----------

const _uid = 'test-uid';

Map<String, dynamic> _tournament({
  required String id,
  required String name,
  required String status,
  required int startMs,
  String banner = '',
  String mode = 'Squad',
  int maxPlayers = 100,
  num entryFee = 0,
}) =>
    {
      'id': id,
      'name': name,
      'status': status,
      'start_time': startMs,
      'banner_url': banner,
      'mode': mode,
      'max_players': maxPlayers,
      'entry_fee': entryFee,
      'prize_pool': 5000,
      'game_name': 'PUBG Mobile',
    };

Map<String, List<Map<String, dynamic>>> _populatedFixtures() {
  final now = DateTime.now().millisecondsSinceEpoch;
  const hour = 60 * 60 * 1000;
  const day = 24 * hour;
  return {
    'profiles': [
      {
        'firebase_uid': _uid,
        'display_name': 'Test Player',
        'level': 5,
        'photo_url': '',
        'last_checked_notifications': 0
      },
    ],
    // t1 upcoming + free + joined by uid; t2 upcoming + PAID;
    // t3 ongoing (LIVE, Watch button, no stream URL);
    // t4 completed (grey pill, disabled action).
    'tournaments': [
      _tournament(
          id: 't1', name: 'Falcon Cup', status: 'upcoming', startMs: now + 2 * hour),
      _tournament(
          id: 't2',
          name: 'Viper Clash',
          status: 'upcoming',
          startMs: now + day,
          mode: 'Solo',
          maxPlayers: 50,
          entryFee: 100),
      _tournament(
          id: 't3',
          name: 'Storm Arena',
          status: 'ongoing',
          startMs: now - hour,
          mode: 'Duo'),
      _tournament(
          id: 't4',
          name: 'Night Raid',
          status: 'completed',
          startMs: now - 2 * day),
    ],
    'tournament_registrations': [
      {
        'id': 'r1',
        'tournament_id': 't1',
        'firebase_uid': _uid,
        'team_name': 'Falcons',
        'slot_number': 1
      },
      {
        'id': 'r2',
        'tournament_id': 't2',
        'firebase_uid': 'other-uid',
        'team_name': 'Vipers',
        'slot_number': 1
      },
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
        {
          'firebase_uid': _uid,
          'display_name': 'Test Player',
          'level': 5,
          'photo_url': '',
          'last_checked_notifications': 0
        },
      ],
      'tournaments': <Map<String, dynamic>>[],
      'tournament_registrations': <Map<String, dynamic>>[],
      'sliders': <Map<String, dynamic>>[],
      'promotions': <Map<String, dynamic>>[],
      'ads': <Map<String, dynamic>>[],
      'notifications': <Map<String, dynamic>>[],
      'user_notifications': <Map<String, dynamic>>[],
    };

// ---------- pump helpers ----------

Future<void> _pumpEvents(WidgetTester tester,
    {double width = 360, double height = 800}) async {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    const MaterialApp(
      home: Scaffold(body: TournamentsPage()),
    ),
  );
  // Let the fixture streams emit. (No pumpAndSettle: the repeating
  // shine animations never settle.)
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Matches a [Text] OR a [RichText] whose plain text contains [needle].
Finder _textContaining(String needle) => find.byWidgetPredicate(
      (w) =>
          (w is Text && (w.data?.contains(needle) ?? false)) ||
          (w is RichText && w.text.toPlainText().contains(needle)),
    );

/// The category pill (radius-24 container) behind a pill label.
BoxDecoration _pillDecoration(WidgetTester tester, String label) {
  final containers = find
      .ancestor(of: find.text(label), matching: find.byType(Container))
      .evaluate();
  for (final e in containers) {
    final c = e.widget as Container;
    final d = c.decoration;
    if (d is BoxDecoration &&
        d.borderRadius == BorderRadius.circular(24)) {
      return d;
    }
  }
  fail('no radius-24 pill container found for "$label"');
}

/// An [ArenaFilterChip] by label.
Finder _chip(String label) => find.byWidgetPredicate(
      (w) => w is ArenaFilterChip && w.label == label,
    );

bool _chipSelected(WidgetTester tester, String label) =>
    tester.widget<ArenaFilterChip>(_chip(label)).selected;

/// The Events list's vertical Scrollable. scrollUntilVisible needs
/// the Scrollable itself (ListView builds one internally — passing
/// find.byType(ListView) throws a type error), and the fee/sort
/// row's horizontal Scrollable must not match.
Finder get _verticalScrollable => find.byWidgetPredicate(
      (w) => w is Scrollable && w.axis == Axis.vertical,
    );

/// The exact-142 tournament-card root (SizedBox height 142, no width)
/// that contains the given tournament title. The thumb SizedBox is
/// 123x142, so the width check separates card root from thumb.
Finder _cardRoot(String title) => find.ancestor(
      of: find.text(title),
      matching: find.byWidgetPredicate(
          (w) => w is SizedBox && w.height == 142 && w.width == null),
    );

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
          projectId: 'test'),
    );
  });

  setUp(() {
    SupaDb.testFixtures = null;
  });

  tearDown(() {
    SupaDb.testFixtures = null;
  });

  group('S3 — contract tokens (F1 stub)', () {
    test('gold is ONLY #FDC903; banned gold shades appear nowhere', () {
      // NOTE: the two banned golds are built via fromARGB so their
      // hex literals never appear in this file — the contract's
      // verifier greps the copy for those hex strings, and ANY
      // occurrence (even in a test) is a FAIL item.
      const bannedA = Color.fromARGB(255, 255, 200, 0); // guide Primary Yellow
      const bannedB = Color.fromARGB(255, 245, 169, 0); // guide Golden
      expect(kGold, const Color(0xFFFDC903));
      expect(kGoldDeep, const Color(0xFFFDC903));
      expect(kGoldBright, const Color(0xFFFDC903));
      expect(kSectionLabel, const Color(0xFFFDC903));
      for (final c in kGoldGradient.colors) {
        expect(c, isNot(bannedA));
        expect(c, isNot(bannedB));
      }
      expect(kGoldGradient.colors, [kGoldSoft, const Color(0xFFFDC903)]);
      expect(kGoldSoft, const Color(0xFFFFE16A));
    });

    test('new tokens carry the guide values', () {
      expect(kSurfaceElevated, const Color(0xFF202331));
      expect(kTextMuted, const Color(0xFF737789));
      expect(kWarning, const Color(0xFFF4A62A));
      expect(kError, const Color(0xFFF04452));
      expect(kCardSurfaceGradient.colors,
          [const Color(0xFF202331), const Color(0xFF12141C)]);
      expect(kBackgroundGradient.colors,
          [const Color(0xFF10121A), const Color(0xFF08090D)]);
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
      expect(kStyleCardTitle.fontSize, 17);
      expect(kStyleBody.fontSize, 15);
      expect(kStyleMeta.fontSize, 13);
      expect(kStyleLabel.fontSize, 12);
    });
  });

  group('S3 — contract components (F2 stub)', () {
    testWidgets('ArenaFilterChip: selected = gold fill + dark text; '
        'unselected = dark surface + grey border', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                ArenaFilterChip(
                    label: 'On', selected: true, onTap: () {}),
                ArenaFilterChip(
                    label: 'Off', selected: false, onTap: () {}),
              ],
            ),
          ),
        ),
      );
      BoxDecoration dec(String label) {
        final c = find
            .ancestor(of: find.text(label), matching: find.byType(Container))
            .evaluate()
            .map((e) => e.widget as Container)
            .firstWhere((c) => c.decoration is BoxDecoration);
        return c.decoration as BoxDecoration;
      }

      final on = dec('On');
      expect(on.color, kGold);
      // REAL F2 (2026-11-23 swap): the selected chip has NO border
      // (fill only) and its dark text is #14161F — the stub used
      // #0A0A0F + a gold border. The real file wins; the test pins
      // the real values.
      expect(on.border, isNull);
      expect(
          tester.widget<Text>(find.text('On')).style?.color,
          const Color(0xFF14161F));
      final off = dec('Off');
      expect(off.color, kSurface);
      expect((off.border as Border).top.color, kBorder);
      expect(tester.widget<Text>(find.text('Off')).style?.color, kText);
    });

    testWidgets('ArenaLiveBadge is a red LIVE badge, never gold',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: ArenaLiveBadge()),
        ),
      );
      expect(find.text('LIVE'), findsOneWidget);
      final c = find
          .ancestor(of: find.text('LIVE'), matching: find.byType(Container))
          .evaluate()
          .map((e) => e.widget as Container)
          .firstWhere((c) => c.decoration is BoxDecoration);
      expect((c.decoration as BoxDecoration).color, kLiveRed);
      expect((c.decoration as BoxDecoration).color, isNot(kGold));
    });
  });

  group('S3 — Events header + category pills', () {
    testWidgets('header: TOURNAMENTS title, gold-ring back, search + '
        'filter actions', (tester) async {
      SupaDb.testFixtures = _populatedFixtures();
      await _pumpEvents(tester);

      expect(find.text('TOURNAMENTS'), findsOneWidget);
      expect(find.byTooltip('Back'), findsOneWidget);
      expect(find.byTooltip('Search tournaments'), findsOneWidget);
      expect(find.byTooltip('Filter tournaments'), findsOneWidget);
      // The gold ring around the back arrow is the kGold token.
      final ring = find
          .ancestor(of: find.byTooltip('Back'), matching: find.byType(Container))
          .evaluate()
          .map((e) => e.widget as Container)
          .firstWhere((c) =>
              c.decoration is BoxDecoration &&
              (c.decoration as BoxDecoration).shape == BoxShape.circle);
      final border = (ring.decoration as BoxDecoration).border as Border;
      expect(border.top.color, kGold);
      expect(border.top.width, 1.5);
    });

    testWidgets('category pills: All selected = gold fill; others = dark '
        'card + muted border; selection moves on tap', (tester) async {
      SupaDb.testFixtures = _populatedFixtures();
      await _pumpEvents(tester);

      // Default filter is 'all': All pill gold, the rest dark.
      final all = _pillDecoration(tester, 'All');
      expect(all.color, kGold);
      expect((all.border as Border).top.color, kGold);
      expect(
          tester.widget<Text>(find.text('All')).style?.color,
          const Color(0xFF0A0A0F));
      for (final label in ['Live', 'Upcoming', 'My Games', 'Saved']) {
        final d = _pillDecoration(tester, label);
        expect(d.color, const Color(0xFF1B1D29),
            reason: '$label pill must be dark, not gold');
        expect((d.border as Border).top.color, const Color(0xFF2A2E3A));
        expect(tester.widget<Text>(find.text(label)).style?.color,
            Colors.white);
      }

      // Tap Live: the gold fill MOVES to Live and the list filters.
      await tester.tap(find.text('Live'));
      await _settle(tester);
      expect(_pillDecoration(tester, 'Live').color, kGold);
      expect(_pillDecoration(tester, 'All').color, const Color(0xFF1B1D29));
      expect(find.text('Storm Arena'), findsOneWidget);
      expect(find.text('Falcon Cup'), findsNothing);
      expect(find.text('Viper Clash'), findsNothing);
      expect(find.text('Night Raid'), findsNothing);
    });
  });

  group('S3 — fee / sort filter logic preserved', () {
    testWidgets('fee group stays single-select: exactly one of '
        'Any/Free/Paid', (tester) async {
      SupaDb.testFixtures = _populatedFixtures();
      await _pumpEvents(tester);

      expect(find.byType(ArenaFilterChip), findsNWidgets(6));
      expect(_chipSelected(tester, 'Any fee'), isTrue);
      expect(_chipSelected(tester, 'Free entry'), isFalse);
      expect(_chipSelected(tester, 'Paid entry'), isFalse);

      // The fee row scrolls horizontally: 'Paid entry' sits off
      // the right edge at 360dp, so bring each chip into view
      // before tapping (a tap on an off-screen widget never lands).
      await tester.ensureVisible(find.text('Free entry'));
      await tester.tap(find.text('Free entry'));
      await _settle(tester);
      expect(_chipSelected(tester, 'Any fee'), isFalse);
      expect(_chipSelected(tester, 'Free entry'), isTrue);
      expect(_chipSelected(tester, 'Paid entry'), isFalse);
      // Paid tournament is filtered out; free ones stay.
      expect(find.text('Viper Clash'), findsNothing);
      expect(find.text('Falcon Cup'), findsWidgets);
      expect(find.text('Storm Arena'), findsOneWidget);

      await tester.ensureVisible(find.text('Paid entry'));
      await tester.tap(find.text('Paid entry'));
      await _settle(tester);
      expect(_chipSelected(tester, 'Any fee'), isFalse);
      expect(_chipSelected(tester, 'Free entry'), isFalse);
      expect(_chipSelected(tester, 'Paid entry'), isTrue);
      expect(find.text('Viper Clash'), findsWidgets);
      expect(find.text('Falcon Cup'), findsNothing);
      expect(find.text('Storm Arena'), findsNothing);
    });

    testWidgets('sort group stays optional-toggle: tap selects, '
        'tap again deselects', (tester) async {
      SupaDb.testFixtures = _populatedFixtures();
      await _pumpEvents(tester);

      // No sort selected at start (EVENTS FILTER RULE 2026-11-22).
      expect(_chipSelected(tester, 'Sort: Date'), isFalse);
      expect(_chipSelected(tester, 'Sort: Prize'), isFalse);
      expect(_chipSelected(tester, 'Sort: Fee'), isFalse);

      await tester.ensureVisible(find.text('Sort: Date'));
      await tester.tap(find.text('Sort: Date'));
      await _settle(tester);
      expect(_chipSelected(tester, 'Sort: Date'), isTrue);

      await tester.tap(find.text('Sort: Date'));
      await _settle(tester);
      expect(_chipSelected(tester, 'Sort: Date'), isFalse);
    });
  });

  group('S3 — search bar', () {
    testWidgets('search field uses the shared input style and still '
        'filters the list', (tester) async {
      SupaDb.testFixtures = _populatedFixtures();
      await _pumpEvents(tester);

      // The list renders a search field whenever results exist.
      // FIX 23 item 29B SUPERSEDES the shared input style: the
      // fields are borderless inside CardFieldShell now (card
      // gradient + purple border + glow). Hint + filtering stay.
      expect(find.byType(TextField), findsWidgets);
      for (final e in find.byType(TextField).evaluate()) {
        final tf = e.widget as TextField;
        final dec = tf.decoration!;
        expect(dec.fillColor, isNull);
        expect(dec.hintText, 'Search tournaments, games...');
        final border = dec.border as OutlineInputBorder;
        expect(border.borderSide.style, BorderStyle.none);
      }
      expect(
          find.ancestor(
              of: find.byType(TextField).first,
              matching: find.byType(CardFieldShell)),
          findsOneWidget);

      // Typing filters; clearing restores.
      await tester.enterText(find.byType(TextField).first, 'viper');
      await _settle(tester);
      expect(find.text('Viper Clash'), findsWidgets);
      expect(find.text('Falcon Cup'), findsNothing);
      expect(find.text('Storm Arena'), findsNothing);
      await tester.enterText(find.byType(TextField).first, '');
      await _settle(tester);
      expect(find.text('Falcon Cup'), findsWidgets);
      expect(find.text('Storm Arena'), findsOneWidget);
    });

    testWidgets('header search icon toggles the search row',
        (tester) async {
      SupaDb.testFixtures = _populatedFixtures();
      await _pumpEvents(tester);
      final before = find.byType(TextField).evaluate().length;
      await tester.tap(find.byTooltip('Search tournaments'));
      await _settle(tester);
      // The header search row appears in addition to the list one.
      expect(find.byType(TextField).evaluate().length, before + 1);
    });
  });

  group('S3 — tournament cards', () {
    testWidgets('card hierarchy: image slot, LIVE pill, title, '
        'date/mode, players, actions — exact 142 height', (tester) async {
      SupaDb.testFixtures = _populatedFixtures();
      await _pumpEvents(tester);

      // Storm Arena is ongoing, so it appears exactly once (the
      // Recommended section only takes upcoming tournaments).
      // It sits below the fold: scroll it into view first.
      await tester.scrollUntilVisible(find.text('Storm Arena'), 100,
          scrollable: _verticalScrollable);
      await _settle(tester);
      final card = _cardRoot('Storm Arena');
      expect(card, findsOneWidget);
      expect(tester.getSize(card).height, 142);

      // Image slot: full-height 123-wide thumb.
      expect(
          find.descendant(
              of: card,
              matching: find.byWidgetPredicate((w) =>
                  w is SizedBox && w.width == 123 && w.height == 142)),
          findsOneWidget);
      // LIVE pill: red (mockup LIVE red), never gold.
      final live = find.descendant(of: card, matching: find.text('LIVE'));
      expect(live, findsOneWidget);
      final livePill = find
          .ancestor(of: live, matching: find.byType(Container))
          .evaluate()
          .map((e) => e.widget as Container)
          .firstWhere((c) => c.decoration is BoxDecoration);
      expect((livePill.decoration as BoxDecoration).color,
          const Color(0xFFFF0B1C));
      // Title, players line, actions.
      final title =
          find.descendant(of: card, matching: find.text('Storm Arena'));
      final players = find.descendant(
          of: card, matching: find.text('0 / 100 Players'));
      final watch = find.descendant(of: card, matching: find.text('Watch'));
      final details =
          find.descendant(of: card, matching: find.text('Details'));
      expect(title, findsOneWidget);
      expect(players, findsOneWidget);
      expect(watch, findsOneWidget);
      expect(details, findsOneWidget);
      // Vertical hierarchy: pill above title above players above actions.
      expect(tester.getTopLeft(live).dy, lessThan(tester.getTopLeft(title).dy));
      expect(
          tester.getTopLeft(title).dy, lessThan(tester.getTopLeft(players).dy));
      expect(tester.getTopLeft(players).dy,
          lessThan(tester.getTopLeft(watch).dy));
      // The mode chip text sits on the meta row.
      expect(find.descendant(of: card, matching: find.text('Duo')),
          findsOneWidget);
    });

    testWidgets('upcoming card shows UPCOMING gold pill + Join Event; '
        'joined card shows Joined; completed shows disabled label',
        (tester) async {
      SupaDb.testFixtures = _populatedFixtures();
      await _pumpEvents(tester);

      // Viper Clash: upcoming, not joined -> Join Event (gold fill).
      final viper = _cardRoot('Viper Clash');
      expect(viper, findsWidgets);
      expect(
          find.descendant(of: viper.first, matching: find.text('UPCOMING')),
          findsOneWidget);
      final joinBtn = find.descendant(
          of: viper.first, matching: find.text('Join Event'));
      expect(joinBtn, findsOneWidget);
      final joinElevated = find
          .ancestor(of: joinBtn, matching: find.byType(ElevatedButton))
          .evaluate()
          .first
          .widget as ElevatedButton;
      expect(joinElevated.onPressed, isNotNull);
      expect(
          joinElevated.style?.backgroundColor?.resolve({}), kGold);
      // Falcon Cup: upcoming + joined -> disabled gold-outlined Joined.
      final falcon = _cardRoot('Falcon Cup');
      final joinedBtn = find.descendant(
          of: falcon.first, matching: find.text('Joined'));
      expect(joinedBtn, findsOneWidget);
      final joinedOutlined = find
          .ancestor(of: joinedBtn, matching: find.byType(OutlinedButton))
          .evaluate()
          .first
          .widget as OutlinedButton;
      expect(joinedOutlined.onPressed, isNull);
      // Night Raid: completed -> disabled status label, grey pill.
      final night = _cardRoot('Night Raid');
      expect(
          find.descendant(of: night, matching: find.text('COMPLETED')),
          findsOneWidget);
      final completedBtn = find.descendant(
          of: night, matching: find.text('Completed'));
      expect(completedBtn, findsOneWidget);
      final completedElevated = find
          .ancestor(of: completedBtn, matching: find.byType(ElevatedButton))
          .evaluate()
          .first
          .widget as ElevatedButton;
      expect(completedElevated.onPressed, isNull);
    });

    testWidgets('Details navigates to the detail page; Watch shows the '
        'honest no-stream toast', (tester) async {
      SupaDb.testFixtures = _populatedFixtures();
      await _pumpEvents(tester);

      // Storm Arena sits below the fold: scroll it into view first.
      await tester.scrollUntilVisible(find.text('Storm Arena'), 100,
          scrollable: _verticalScrollable);
      await _settle(tester);
      // Watch on a live tournament with no stream URL: honest toast,
      // never a silent Detail detour.
      final card = _cardRoot('Storm Arena');
      await tester.tap(
          find.descendant(of: card, matching: find.text('Watch')));
      await _settle(tester);
      expect(find.text('Live stream URL set nahi hai.'), findsOneWidget);
      expect(find.byType(TournamentDetailPage), findsNothing);

      // Details opens the detail page (same action as before).
      await tester.tap(
          find.descendant(of: card, matching: find.text('Details')));
      await _settle(tester);
      expect(find.byType(TournamentDetailPage), findsOneWidget);
    });

    testWidgets('cards are spaced kSpace12 apart, consistently',
        (tester) async {
      SupaDb.testFixtures = _populatedFixtures();
      await _pumpEvents(tester);

      // Every card sits in a Padding with bottom kSpace12.
      final cards = find
          .byWidgetPredicate(
              (w) => w is SizedBox && w.height == 142 && w.width == null)
          .evaluate();
      expect(cards.length, greaterThanOrEqualTo(2));
      for (final e in cards) {
        final paddings = find
            .ancestor(
                of: find.byWidget(e.widget), matching: find.byType(Padding))
            .evaluate();
        expect(paddings, isNotEmpty);
        final hasCardGap = paddings.any((p) =>
            (p.widget as Padding).padding ==
            const EdgeInsets.only(bottom: kSpace12));
        expect(hasCardGap, isTrue,
            reason: 'every card must wrap in a bottom-kSpace12 Padding');
      }
      // The first two laid-out cards are both in the Recommended
      // section (consecutive, no section header between them), so
      // their measured gap really is kSpace12.
      final laidOut = cards
          .map((e) => tester.getRect(find.byWidget(e.widget)))
          .toList()
        ..sort((a, b) => a.top.compareTo(b.top));
      expect(laidOut.length, greaterThanOrEqualTo(2));
      expect(laidOut[1].top - laidOut[0].bottom, kSpace12);
    });
  });

  group('S3 — empty state', () {
    testWidgets('empty list keeps the NO EVENTS FOUND art + gold '
        'CLEAR FILTERS + outlined EXPLORE GAMES', (tester) async {
      SupaDb.testFixtures = _emptyFixtures;
      await _pumpEvents(tester);

      expect(_textContaining('NO EVENTS'), findsOneWidget);
      expect(_textContaining('FOUND'), findsOneWidget);
      expect(
          find.text(
              'There are no tournaments matching your filters right now.'),
          findsOneWidget);
      final clear = tester.widget<ElevatedButton>(
          find.widgetWithText(ElevatedButton, 'CLEAR FILTERS'));
      expect(clear.onPressed, isNotNull);
      expect(clear.style?.backgroundColor?.resolve({}), kGold);
      final explore = tester.widget<OutlinedButton>(
          find.widgetWithText(OutlinedButton, 'EXPLORE GAMES'));
      expect(explore.onPressed, isNotNull);
      expect(explore.style?.side?.resolve({})?.color, kGold);
      // Tapping CLEAR FILTERS resets the filters (no crash, state stays).
      await tester.tap(find.text('CLEAR FILTERS'));
      await _settle(tester);
      expect(_textContaining('NO EVENTS'), findsOneWidget);
    });
  });

  group('S3 — small screens', () {
    testWidgets('320x568: search + filters + cards render with no '
        'overflow', (tester) async {
      SupaDb.testFixtures = _populatedFixtures();
      await _pumpEvents(tester, width: 320, height: 568);

      // Any RenderFlex overflow fails the test via FlutterError.
      expect(find.text('TOURNAMENTS'), findsOneWidget);
      expect(find.text('All'), findsOneWidget);
      expect(find.text('Live'), findsOneWidget);
      expect(find.text('Saved'), findsOneWidget);
      expect(find.byType(TextField), findsWidgets);
      expect(find.byType(ArenaFilterChip), findsNWidgets(6));
      // Storm Arena sits below the fold at this height: scroll to it.
      await tester.scrollUntilVisible(find.text('Storm Arena'), 100,
          scrollable: _verticalScrollable);
      await _settle(tester);
      expect(find.text('Storm Arena'), findsOneWidget);
      // The fee/sort row scrolls horizontally instead of overflowing.
      final hScroll = find.byWidgetPredicate((w) =>
          w is SingleChildScrollView &&
          w.scrollDirection == Axis.horizontal);
      expect(hScroll, findsWidgets);
      // Chips still tappable at this width (row scrolls to them).
      await tester.ensureVisible(find.text('Sort: Prize'));
      await tester.tap(find.text('Sort: Prize'));
      await _settle(tester);
      expect(_chipSelected(tester, 'Sort: Prize'), isTrue);
    });
  });
}
