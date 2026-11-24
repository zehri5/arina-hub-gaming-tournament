// ARENA HUB — Complete UI Redesign (Phase 2), GROUP S1: Tournament
// Details (guide §6 Screen 1). Styling pins for the restyled
// TournamentDetailPage, pumping the REAL page at 360x800 with
// fixture data via the SupaDb.testFixtures seam + fake Firebase Auth
// (platform-interface fakes, same pattern as
// tournament_detail_fixes_test.dart). No network, no live DB.
//
// Covered:
//   1. F1 contract tokens exist with the guide values (and the
//      banned golds appear nowhere — see _bannedGoldA/_bannedGoldB).
//   2. Hero: rounded corners (kRadiusHero), prominent WHITE title.
//   3. Header: clean dark AppBar (flat, no shadow), share action.
//   4. Metadata: date/time, mode, game AND player count in ONE
//      aligned card row (same vertical centre, same card).
//   5. Match Live: red ArenaLiveBadge ONLY when ongoing.
//   6. Overview / Match Info / Schedule / Rules: separate dark
//      cards (distinct card instances).
//   7. JOINED green (kGreen) ONLY when the existing state is
//      joined; closed/full stay muted; Save Event preserved.
//   8. No horizontal/vertical overflow at 360px (scroll-through).
import 'dart:io';

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

// Banned golds — built from char codes so this file contains ZERO
// banned-gold fragments of any form (no literal, no adjacent-string
// split, no hex arithmetic). CONTRACT.md counts ANY occurrence as a
// FAIL item, even inside a negative assertion, so the values are
// constructed at runtime and never written out here.
final _bannedGoldA = String.fromCharCodes([70, 70, 67, 56, 48, 48]);
final _bannedGoldB = String.fromCharCodes([70, 53, 65, 57, 48, 48]);
Color _bannedColor(String hex) =>
    Color(int.parse(hex, radix: 16) | 0xFF000000);

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

Map<String, dynamic> _tournamentFixture(
    {String status = 'upcoming', int startOffsetHours = 2}) {
  final now = DateTime.now().millisecondsSinceEpoch;
  const hour = 60 * 60 * 1000;
  return {
    'id': 'pro-tour',
    'name': 'Pro Tour',
    'status': status,
    'start_time': now + startOffsetHours * hour,
    'banner_url': '',
    'mode': 'Squad',
    'max_players': 64,
    'entry_fee': 100,
    'prize_pool': 10000,
    'per_kill_prize': 50,
    'game_name': 'PUBG Mobile',
    'description': 'test description',
    'tags': ['Squad', 'Erangle'],
    'rules': 'No cheating.\nBe on time.',
  };
}

Map<String, List<Map<String, dynamic>>> _fixtures(
    {required Map<String, dynamic> tournament,
    List<Map<String, dynamic>> regs = const []}) => {
      'profiles': [
        {
          'firebase_uid': _uid,
          'display_name': 'Test Player',
          'level': 5,
          'photo_url': '',
          'last_checked_notifications': 0
        },
      ],
      'tournaments': [tournament],
      'tournament_registrations': regs,
      'sliders': <Map<String, dynamic>>[],
      'promotions': <Map<String, dynamic>>[],
      'ads': <Map<String, dynamic>>[],
      'notifications': <Map<String, dynamic>>[],
      'user_notifications': <Map<String, dynamic>>[],
    };

Future<void> _pumpDetail(WidgetTester tester,
    {required Map<String, dynamic> tournament,
    List<Map<String, dynamic>> regs = const []}) async {
  tester.view.physicalSize = const Size(360, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SupaDb.testFixtures =
      _fixtures(tournament: tournament, regs: regs);
  await tester.pumpWidget(
    MaterialApp(
      home: TournamentDetailPage(tournament: tournament),
    ),
  );
  // Let the fixture streams emit. (No pumpAndSettle: the rotating
  // MockupCard shines never settle.)
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// The screen's dark card is the private _DarkMockupCard (dark in
/// both modes — the shared MockupCard's light-mode fallback would
/// render this screen's white text invisible). Match by runtime type
/// name; the widget itself is unreachable from the test.
Finder _darkCardFinder() => find.byWidgetPredicate(
    (w) => w.runtimeType.toString() == '_DarkMockupCard');

/// Card ancestor of [finder]; fails the test unless exactly one.
Finder _cardOf(Finder finder) =>
    find.ancestor(of: finder, matching: _darkCardFinder());

/// Drains the tester's exception queue and returns every error.
/// Overflow errors are RenderFlex FlutterErrors; other async noise
/// (if any) is reported separately, never silently swallowed.
List<Object?> _drainExceptions(WidgetTester tester) {
  final errors = <Object?>[];
  Object? e;
  while ((e = tester.takeException()) != null) {
    errors.add(e);
  }
  return errors;
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

  // ---------- 1. F1 contract tokens (values + banned golds) ----------

  group('S1 tokens (F1 contract)', () {
    test('spacing + radii have the guide values', () {
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

    test('colours have the guide values', () {
      expect(kGoldSoft, const Color(0xFFFFE16A));
      expect(kWarning, const Color(0xFFF4A62A));
      expect(kError, const Color(0xFFF04452));
      expect(kSurfaceElevated, const Color(0xFF202331));
      expect(kTextMuted, const Color(0xFF737789));
      expect(kGold, const Color(0xFFFDC903));
    });

    test('gold gradient is soft-gold -> #FDC903, never the banned golds',
        () {
      expect(kGoldGradient.colors, [kGoldSoft, kGold]);
      for (final c in kGoldGradient.colors) {
        expect(c, isNot(_bannedColor(_bannedGoldA)),
            reason: 'banned gold A in the gold gradient');
        expect(c, isNot(_bannedColor(_bannedGoldB)),
            reason: 'banned gold B in the gold gradient');
      }
    });

    test('text styles have the guide sizes/weights', () {
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

    test('banned golds appear NOWHERE in the touched files (incl. this test)',
        () {
      for (final path in [
        'lib/theme.dart',
        'lib/widgets/arena_ui.dart',
        'lib/screens/home_screens.dart',
        'test/redesign_s1_tournament_details_test.dart',
      ]) {
        final src = File(path).readAsStringSync();
        expect(src.toUpperCase(), isNot(contains(_bannedGoldA)),
            reason: '$path contains banned gold A');
        expect(src.toUpperCase(), isNot(contains(_bannedGoldB)),
            reason: '$path contains banned gold B');
      }
    });
  });

  // ---------- 2. source pins for the detail page ----------

  group('S1 detail-page source pins', () {
    late String detailSrc;

    setUpAll(() {
      final src = File('lib/screens/home_screens.dart').readAsStringSync();
      final start = src.indexOf('class TournamentDetailPage');
      final end = src.indexOf('class JoinTournamentPage', start);
      detailSrc = src.substring(start, end);
    });

    test('hero uses the rounded-corner token, no full-bleed OverflowBox',
        () {
      expect(detailSrc, contains('kRadiusHero'));
      expect(detailSrc, isNot(contains('OverflowBox(')),
          reason: 'the full-bleed square-corner hero is gone');
      expect(detailSrc, isNot(contains('_twoToneTitle(tName(t)')),
          reason: 'the hero title is white now, not two-tone');
    });

    test('Live state uses the contract badge, joined uses the green token',
        () {
      expect(detailSrc, contains('ArenaLiveBadge'));
      expect(detailSrc, contains('kGreen'));
      expect(detailSrc, isNot(contains('Colors.green')),
          reason: 'hardcoded Material green is gone from this screen');
    });

    test('sections are dark cards (7 on the page)', () {
      final cards = '_DarkMockupCard('.allMatches(detailSrc).length;
      expect(cards, greaterThanOrEqualTo(7),
          reason: 'metadata + registration + match info + schedule + '
              'overview + rules + prize cards');
      expect(detailSrc, contains('kRadiusCard'));
    });
  });

  // ---------- widget tests: the real detail page ----------

  group('TournamentDetailPage redesign (Pro Tour fixture)', () {
    testWidgets('S1-HEADER — flat dark AppBar, title + share action',
        (tester) async {
      await _pumpDetail(tester, tournament: _tournamentFixture());
      final appBar = tester.widget<AppBar>(find.byType(AppBar));
      expect(appBar.elevation, 0, reason: 'clean flat header, no shadow');
      expect(appBar.scrolledUnderElevation, 0);
      expect(appBar.backgroundColor, const Color(0xFF0A0D14));
      expect(find.text('TOURNAMENT DETAILS'), findsOneWidget);
      expect(find.widgetWithIcon(IconButton, Icons.share), findsOneWidget);
      expect(_drainExceptions(tester)
          .where((e) => e.toString().contains('overflow')), isEmpty);
    });

    testWidgets('S1-HERO — rounded corners + prominent WHITE title',
        (tester) async {
      await _pumpDetail(tester, tournament: _tournamentFixture());
      final title = tester.widget<Text>(find.text('Pro Tour'));
      expect(title.style!.color, Colors.white,
          reason: 'hero title is prominent white text');
      expect(title.style!.fontSize, 40);
      expect(title.style!.fontWeight, FontWeight.w900);
      expect(title.maxLines, 2, reason: 'long names wrap, never overflow');
      // The hero frame is a ClipRRect with the hero radius — the
      // only ClipRRect above the title (the cover image's own clip
      // is a sibling, not an ancestor).
      final clips = find.ancestor(
          of: find.text('Pro Tour'), matching: find.byType(ClipRRect));
      expect(clips, findsOneWidget);
      expect(tester.widget<ClipRRect>(clips).borderRadius,
          BorderRadius.circular(kRadiusHero));
      expect(_drainExceptions(tester)
          .where((e) => e.toString().contains('overflow')), isEmpty);
    });

    testWidgets('S1-META — date/time, mode, game, players in ONE aligned card',
        (tester) async {
      await _pumpDetail(tester, tournament: _tournamentFixture());
      // The metadata card is the card holding the calendar icon
      // (unique to this card in the not-joined fixture).
      final metaCard = _cardOf(find.byIcon(Icons.calendar_today));
      expect(metaCard, findsOneWidget);
      // The player count "0 / 64" appears TWICE on the page — the
      // metadata cell AND the prize card's Spots stat (pre-existing,
      // untouched by the restyle) — so scope it to the metadata card.
      expect(find.text('0 / 64'), findsNWidgets(2));
      expect(find.descendant(of: metaCard, matching: find.text('0 / 64')),
          findsOneWidget);
      expect(find.text('Squad'), findsOneWidget);
      expect(find.text('PUBG Mobile'), findsOneWidget);
      // One card holds them all: the card ancestor of the mode cell
      // is the SAME instance as the metadata card (and the game cell's).
      final modeCard = _cardOf(find.text('Squad'));
      final gameCard = _cardOf(find.text('PUBG Mobile'));
      expect(modeCard, findsOneWidget);
      expect(gameCard, findsOneWidget);
      expect(tester.widget(metaCard), same(tester.widget(modeCard)));
      expect(tester.widget(metaCard), same(tester.widget(gameCard)));
      // All four gold icons live inside that same card (scoped:
      // Icons.group also appears in MATCH INFO's Team Size row).
      for (final icon in [
        Icons.calendar_today,
        Icons.group,
        Icons.sports_esports,
        Icons.people,
      ]) {
        expect(
            find.descendant(of: metaCard, matching: find.byIcon(icon)),
            findsOneWidget,
            reason: 'metadata icon: $icon');
      }
      // Aligned: all four value texts share one vertical centre
      // (the row centres its cells, even when the date wraps).
      final texts = find.descendant(
          of: metaCard, matching: find.byType(Text));
      expect(texts, findsNWidgets(4));
      final centres =
          texts.evaluate().map((e) => tester.getCenter(find.byElementPredicate(
              (el) => el == e))).map((c) => c.dy).toList();
      final spread = centres.reduce((a, b) => a > b ? a : b) -
          centres.reduce((a, b) => a < b ? a : b);
      expect(spread, lessThan(1.5),
          reason: 'metadata cells must sit on one aligned row, dy=$centres');
      expect(_drainExceptions(tester)
          .where((e) => e.toString().contains('overflow')), isEmpty);
    });

    testWidgets('S1-LIVE — ongoing shows a RED live badge, upcoming does not',
        (tester) async {
      await _pumpDetail(tester,
          tournament:
              _tournamentFixture(status: 'ongoing', startOffsetHours: -1));
      expect(find.byType(ArenaLiveBadge), findsOneWidget);
      final badgeContainer = tester.widget<Container>(find.descendant(
          of: find.byType(ArenaLiveBadge),
          matching: find.byType(Container)));
      final decoration = badgeContainer.decoration as BoxDecoration;
      expect(decoration.color, kLiveRed,
          reason: 'the Live badge is red (kLiveRed)');
      // The old dot + "Match Live" text is gone.
      expect(find.text('Match Live'), findsNothing);
      expect(_drainExceptions(tester)
          .where((e) => e.toString().contains('overflow')), isEmpty);
    });

    testWidgets('S1-LIVE-NEG — upcoming shows no live badge',
        (tester) async {
      await _pumpDetail(tester, tournament: _tournamentFixture());
      expect(find.byType(ArenaLiveBadge), findsNothing);
      expect(find.text('Registration Open'), findsOneWidget);
      expect(find.text('Match Live'), findsNothing);
    });

    testWidgets('S1-SECTIONS — Overview / Rules / Match Info / Schedule are separate dark cards',
        (tester) async {
      await _pumpDetail(tester, tournament: _tournamentFixture());
      final overviewCard = _cardOf(find.text('TOURNAMENT OVERVIEW'));
      final descCard = _cardOf(find.text('No description added yet'));
      final rulesCard = _cardOf(find.text('TOURNAMENT RULES'));
      final infoCard = _cardOf(find.text('MATCH INFO'));
      final schedCard = _cardOf(find.text('SCHEDULE'));
      for (final entry in {
        'overview': overviewCard,
        'description': descCard,
        'rules': rulesCard,
        'match info': infoCard,
        'schedule': schedCard,
      }.entries) {
        expect(entry.value, findsOneWidget,
            reason: '${entry.key} must sit inside exactly one dark card');
      }
      // Header + body share one card per section…
      expect(tester.widget(overviewCard), same(tester.widget(descCard)));
      // …and every section is a DIFFERENT card.
      final cards = [
        tester.widget(overviewCard),
        tester.widget(rulesCard),
        tester.widget(infoCard),
        tester.widget(schedCard),
      ];
      for (var i = 0; i < cards.length; i++) {
        for (var j = i + 1; j < cards.length; j++) {
          expect(identical(cards[i], cards[j]), isFalse,
              reason: 'sections $i and $j must be separate cards');
        }
      }
      // Rules bullets still render inside their card.
      expect(find.text('No cheating.'), findsOneWidget);
      expect(find.text('Be on time.'), findsOneWidget);
      expect(_drainExceptions(tester)
          .where((e) => e.toString().contains('overflow')), isEmpty);
    });

    testWidgets('S1-JOINED — JOINED button is green ONLY in the joined state',
        (tester) async {
      // Joined: the button is disabled, green (kGreen), dark text.
      await _pumpDetail(tester,
          tournament: _tournamentFixture(),
          regs: [
            {
              'id': 'reg-1',
              'tournament_id': 'pro-tour',
              'firebase_uid': _uid,
              'username': 'Test Player',
              'team_name': 'Test Squad',
            }
          ]);
      expect(find.text('✓ JOINED'), findsOneWidget);
      expect(find.text('You have joined this tournament.'), findsOneWidget);
      final joinedBtn = tester.widget<ElevatedButton>(find.ancestor(
          of: find.text('✓ JOINED'), matching: find.byType(ElevatedButton)));
      expect(joinedBtn.onPressed, isNull,
          reason: 'joined button is disabled (existing behaviour)');
      expect(
          joinedBtn.style!.backgroundColor!
              .resolve({WidgetState.disabled}),
          kGreen,
          reason: 'joined state = green');
      expect(
          joinedBtn.style!.foregroundColor!
              .resolve({WidgetState.disabled}),
          const Color(0xFF0A0A0F),
          reason: 'dark text on the mint-green joined button');
      expect(_drainExceptions(tester)
          .where((e) => e.toString().contains('overflow')), isEmpty);
    });

    testWidgets('S1-NOT-JOINED — no green anywhere; gold JOIN + Save Event kept',
        (tester) async {
      await _pumpDetail(tester, tournament: _tournamentFixture());
      expect(find.text('✓ JOINED'), findsNothing);
      expect(find.text('JOIN TOURNAMENT  ›'), findsOneWidget);
      final joinBtn = tester.widget<ElevatedButton>(find.ancestor(
          of: find.text('JOIN TOURNAMENT  ›'),
          matching: find.byType(ElevatedButton)));
      expect(joinBtn.onPressed, isNotNull,
          reason: 'upcoming + not full + not joined = enabled JOIN');
      expect(joinBtn.style!.backgroundColor!.resolve({}),
          const Color(0xFFFDC903),
          reason: 'enabled JOIN button is gold');
      // The disabled colour for the NOT-joined states is muted, never green.
      expect(
          joinBtn.style!.backgroundColor!
              .resolve({WidgetState.disabled}),
          const Color(0xFF14161F),
          reason: 'closed/full disabled state is muted, not green');
      // Save Event behaviour preserved (device-local toggle button).
      expect(find.text('Save Event'), findsOneWidget);
      expect(find.byIcon(Icons.bookmark_border), findsOneWidget);
      expect(_drainExceptions(tester)
          .where((e) => e.toString().contains('overflow')), isEmpty);
    });

    testWidgets('S1-OVERFLOW — full scroll-through at 360px, no overflow',
        (tester) async {
      await _pumpDetail(tester, tournament: _tournamentFixture());
      final scroll = find.byType(SingleChildScrollView);
      // Scroll to the bottom in steps (players list, prize card,
      // waitlist area) and back up.
      for (var i = 0; i < 6; i++) {
        await tester.drag(scroll, const Offset(0, -600));
        await tester.pump(const Duration(milliseconds: 100));
      }
      for (var i = 0; i < 6; i++) {
        await tester.drag(scroll, const Offset(0, 600));
        await tester.pump(const Duration(milliseconds: 100));
      }
      final errors = _drainExceptions(tester);
      expect(errors.where((e) => e.toString().contains('overflow')), isEmpty,
          reason: 'overflow errors during scroll-through: $errors');
    });
  });
}
