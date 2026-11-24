import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:protournament_user/components/arena_components.dart';
import 'package:protournament_user/screens/communities_screens.dart';
import 'package:protournament_user/services/supabase_db.dart';
import 'package:protournament_user/theme.dart';
import 'package:protournament_user/widgets/arena_ui.dart';

/// REDESIGN B-S8 — Communities list (Screen 8) styling.
///
/// Pins the contract styling on [CommunitiesListPage] + the shared
/// [StanCommunityRow] + [CommunitySectionHeader]:
///   * F1 tokens in theme.dart — exact values (gold #FDC903 only,
///     spacing scale, radii, text styles).
///   * F2 shared components — [ArenaBackground] (golden glow),
///     [ArenaTextField] search, [ArenaLoadingIndicator] spinners.
///   * STAN row structure UNCHANGED (photo radius 28, bold name +
///     CREATOR badge, member-count chip, gold arrow circle radius
///     20) — only the styling is tokenised.
///   * NO banner grid, NO follow buttons on rows (user orders).
///   * 360px wide phone: no overflow, long names ellipsise.
///
/// Widget tests pump the real page against SupaDb.testFixtures
/// (the FIX 6 seam) — no Supabase connection needed. The list
/// page reads SharedPreferences (cached-first list), so mock
/// values + a cleared live instance per test, like
/// communities_test.dart.
///
/// NON-VACUITY: the style asserts pin exact values that only the
/// redesigned styling satisfies (name 17/w800, section header
/// 18/bold, count 12/kMuted, FAB label 14/w900, row radius 14,
/// list padding 16/8/16/96) and component types that do not exist
/// in the pre-redesign page (ArenaBackground / ArenaTextField /
/// ArenaLoadingIndicator). Reverting communities_screens.dart to
/// the pre-redesign file fails these tests (verified by running
/// this suite against the backed-up original).

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    // Contract tokens are read in dark mode.
    themeLightNotifier.value = false;
  });

  tearDown(() {
    SupaDb.testFixtures = null;
  });

  // A tall test surface so all rows + both section headers are
  // built at once (ListView.builder only builds visible items).
  void tallSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(800, 2200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  // Manual settle (FIX 23 item 24): pumpAndSettle NEVER settles
  // once the smoke layer (continuous Lottie) is mounted — pump
  // fixed frames instead.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  // A narrow phone surface (360px logical width).
  void narrowSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  double dy(WidgetTester tester, String text) =>
      tester.getTopLeft(find.text(text)).dy;

  /// 7 communities whose NEWEST-first order is deliberately the
  /// REVERSE of their member-count order (same fixture as
  /// fix12_g15_stan_list_test.dart).
  Map<String, List<Map<String, dynamic>>> sevenFixtures() {
    final defs = <(String, String, String, int)>[
      ('c1', 'Alpha', '2026-11-21T10:00:00.000Z', 3),
      ('c2', 'Bravo', '2026-11-20T10:00:00.000Z', 50),
      ('c3', 'Charlie', '2026-11-19T10:00:00.000Z', 12),
      ('c4', 'Delta', '2026-11-18T10:00:00.000Z', 0),
      ('c5', 'Echo', '2026-11-17T10:00:00.000Z', 8),
      ('c6', 'Foxtrot', '2026-11-16T10:00:00.000Z', 25),
      ('c7', 'Golf', '2026-11-15T10:00:00.000Z', 1),
    ];
    final communities = defs
        .map((d) => <String, dynamic>{
              'id': d.$1,
              'name': d.$2,
              'description': d.$2 == 'Alpha' ? 'Best players only' : '',
              'photo_url': '',
              'created_by_uid': 'u9',
              'created_at': d.$3,
            })
        .toList();
    final members = <Map<String, dynamic>>[];
    for (final d in defs) {
      for (var i = 0; i < d.$4; i++) {
        members.add(<String, dynamic>{
          'community_id': d.$1,
          'firebase_uid': 'm-${d.$1}-$i',
          'role': 'member',
        });
      }
    }
    return {'communities': communities, 'community_members': members};
  }

  group('F1 contract tokens — exact values', () {
    test('gold is #FDC903 only, in every gold token', () {
      const gold = Color(0xFFFDC903);
      expect(kGold, gold);
      expect(kGoldDeep, gold);
      expect(kGoldBright, gold);
      expect(kSectionLabel, gold);
    });

    test('dark surfaces match the contract', () {
      expect(kBg, const Color(0xFF070A10));
      expect(kSurface, const Color(0xFF10131A));
      expect(kCard, const Color(0xFF181B24));
      expect(kSurfaceElevated, const Color(0xFF202331));
      expect(kText, Colors.white);
      expect(kMuted, const Color(0xFFAAB0D0));
      expect(kTextMuted, const Color(0xFF737789));
    });

    test('spacing scale', () {
      expect(kSpace4, 4);
      expect(kSpace8, 8);
      expect(kSpace12, 12);
      expect(kSpace16, 16);
      expect(kSpace20, 20);
      expect(kSpace24, 24);
      expect(kSpace32, 32);
    });

    test('corner radii', () {
      expect(kRadiusChip, 12);
      expect(kRadiusInput, 14);
      expect(kRadiusCard, 18);
      expect(kRadiusHero, 22);
    });

    test('text styles', () {
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
  });

  group('GOLD RULE — banned guide golds absent from the list file',
      () {
    // The two banned shades are built ONLY via decimal char codes
    // (never as literals — the verifier fails on any literal form
    // in lib/ or test/).
    String bannedA() =>
        String.fromCharCodes([70, 70, 67, 56, 48, 48]);
    String bannedB() =>
        String.fromCharCodes([70, 53, 65, 57, 48, 48]);
    String bannedHexA() =>
        String.fromCharCodes([48, 120, 67, 56, 48, 48]);
    String bannedHexB() =>
        String.fromCharCodes([48, 120, 65, 57, 48, 48]);

    test('communities_screens.dart has no banned gold in any form',
        () {
      final code = File('lib/screens/communities_screens.dart')
          .readAsStringSync();
      // Sanity: the scan ran on the real file.
      expect(code, contains('StanCommunityRow'));
      expect(code, contains('FDC903'));
      expect(code, isNot(contains(bannedA())));
      expect(code, isNot(contains(bannedB())));
      expect(code, isNot(contains(bannedHexA())));
      expect(code, isNot(contains(bannedHexB())));
    });

    test('this test file has no banned gold literal either', () {
      final code = File('test/redesign_s8_communities_test.dart')
          .readAsStringSync();
      expect(code, contains('String.fromCharCodes'));
      expect(code, isNot(contains(bannedA())));
      expect(code, isNot(contains(bannedB())));
      expect(code, isNot(contains(bannedHexA())));
      expect(code, isNot(contains(bannedHexB())));
    });
  });

  group('CommunitiesListPage at 360px — no overflow', () {
    testWidgets('rows render, sections + search + FAB, no overflow',
        (tester) async {
      narrowSurface(tester);
      final fixtures = sevenFixtures();
      // One 60-char name (2 members) to prove ellipsis at 360px.
      final longName = 'L' * 60;
      fixtures['communities']!.add(<String, dynamic>{
        'id': 'c8',
        'name': longName,
        'description': '',
        'photo_url': '',
        'created_by_uid': 'u9',
        'created_at': '2026-11-14T10:00:00.000Z',
      });
      for (var i = 0; i < 2; i++) {
        fixtures['community_members']!.add(<String, dynamic>{
          'community_id': 'c8',
          'firebase_uid': 'm-c8-$i',
          'role': 'member',
        });
      }
      SupaDb.testFixtures = fixtures;

      await tester.pumpWidget(
        const MaterialApp(home: CommunitiesListPage(uid: 'u1')),
      );
      await settle(tester);

      // Shared components are in the tree.
      expect(find.byType(ArenaBackground), findsOneWidget);
      expect(find.byType(ArenaTextField), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
      expect(find.byType(RefreshIndicator), findsOneWidget);

      // Top section + at least the first STAN rows are visible.
      expect(find.text('Top Communities'), findsOneWidget);
      expect(find.byType(StanCommunityRow), findsWidgets);
      expect(find.text('Bravo'), findsOneWidget);

      // Scroll the whole list (builds every row, incl. the long
      // name) — no overflow anywhere. Manual drags: scrollUntilVisible
      // cannot disambiguate the ListView's Scrollable from the
      // search field's internal one.
      Future<void> dragDownTo(Finder target) async {
        for (var i = 0; i < 10; i++) {
          if (target.evaluate().isNotEmpty) return;
          await tester.drag(
              find.byType(ListView).first, const Offset(0, -500));
          await settle(tester);
        }
      }

      await dragDownTo(find.text(longName));
      expect(find.text(longName), findsOneWidget);
      final longText = tester.widget<Text>(find.text(longName));
      expect(longText.maxLines, 1);
      expect(longText.overflow, TextOverflow.ellipsis);
      await dragDownTo(find.text('Delta'));
      expect(find.text('All Communities'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('CommunitiesListPage styling (tall surface)', () {
    testWidgets('header, search, FAB + list use contract tokens',
        (tester) async {
      tallSurface(tester);
      SupaDb.testFixtures = sevenFixtures();
      await tester.pumpWidget(
        const MaterialApp(home: CommunitiesListPage(uid: 'u1')),
      );
      await settle(tester);

      // Background: gradient + golden glow behind the content.
      // FIX 23 items 21+24: the background is the app image
      // layer + smoke now (ArenaBackground still mounts with the
      // golden glow on); the Scaffold itself has no background
      // color any more — ArenaBackground provides it.
      final bg = tester.widget<ArenaBackground>(
          find.byType(ArenaBackground));
      expect(bg.showGoldenGlow, isTrue);
      expect(
          find.descendant(
              of: find.byType(ArenaBackground),
              matching: find.byType(AppBackgroundLayer)),
          findsOneWidget);
      expect(
          find.descendant(
              of: find.byType(ArenaBackground),
              matching: find.byType(SmokeLayer)),
          findsOneWidget);

      // Header: gold italic 22/w900 title on the surface colour.
      final title = tester.widget<Text>(find.text('COMMUNITIES'));
      expect(title.style!.color, kGold);
      expect(title.style!.fontSize, 22);
      expect(title.style!.fontWeight, FontWeight.w900);
      expect(title.style!.fontStyle, FontStyle.italic);
      final appBar = tester.widget<AppBar>(find.byType(AppBar));
      expect(appBar.backgroundColor, kSurface);
      final scaffold =
          tester.widget<Scaffold>(find.byType(Scaffold));
      // FIX 23 item 21: no Scaffold background color — the
      // ArenaBackground layer provides the background.
      expect(scaffold.backgroundColor, isNull);

      // Search: the shared ArenaTextField, same hint + gold icon.
      // FIX 23 item 29B: the field is borderless inside
      // CardFieldShell now (card gradient + purple border).
      expect(find.byType(ArenaTextField), findsOneWidget);
      final field =
          tester.widget<TextField>(find.byType(TextField));
      expect(field.decoration!.hintText, 'Community dhoonden...');
      expect(field.decoration!.fillColor, isNull);
      expect(
          (field.decoration!.border as OutlineInputBorder)
              .borderSide
              .style,
          BorderStyle.none);
      expect(
          find.ancestor(
              of: find.byType(TextField),
              matching: find.byType(CardFieldShell)),
          findsOneWidget);
      expect(find.byIcon(Icons.search), findsOneWidget);

      // FAB: extended + gold, label 14/w900 black — and the list
      // keeps 96dp bottom padding so it never covers content.
      final fab = tester.widget<FloatingActionButton>(
          find.byType(FloatingActionButton));
      expect(fab.backgroundColor, kGold);
      final fabLabel = tester.widget<Text>(find.text('CREATE'));
      expect(fabLabel.style!.color, Colors.black);
      expect(fabLabel.style!.fontSize, 14);
      expect(fabLabel.style!.fontWeight, FontWeight.w900);
      final list = tester.widget<ListView>(find.byType(ListView));
      expect(list.padding,
          const EdgeInsets.fromLTRB(16, 8, 16, 96));

      expect(tester.takeException(), isNull);
    });

    testWidgets('STAN rows: token styles, structure unchanged',
        (tester) async {
      tallSurface(tester);
      SupaDb.testFixtures = sevenFixtures();
      await tester.pumpWidget(
        const MaterialApp(home: CommunitiesListPage(uid: 'u1')),
      );
      await settle(tester);

      // Sections + order (top 5 above All, count-desc).
      expect(find.text('Top Communities'), findsOneWidget);
      expect(find.text('All Communities'), findsOneWidget);
      expect(dy(tester, 'Bravo') < dy(tester, 'Foxtrot'), isTrue);
      expect(dy(tester, 'Foxtrot') < dy(tester, 'Charlie'), isTrue);
      expect(dy(tester, 'Charlie') < dy(tester, 'Echo'), isTrue);
      expect(dy(tester, 'Echo') < dy(tester, 'Alpha'), isTrue);
      expect(dy(tester, 'Alpha') < dy(tester, 'All Communities'),
          isTrue);
      expect(dy(tester, 'All Communities') < dy(tester, 'Golf'),
          isTrue);
      expect(dy(tester, 'Golf') < dy(tester, 'Delta'), isTrue);

      // Row structure: 7 rows, 7 gold arrows, 14 avatars.
      expect(find.byType(StanCommunityRow), findsNWidgets(7));
      expect(find.byIcon(Icons.arrow_forward), findsNWidgets(7));
      expect(find.byType(CircleAvatar), findsNWidgets(14));

      // Section header typography = kStyleSection (18/bold).
      final header =
          tester.widget<Text>(find.text('Top Communities'));
      expect(header.style!.fontSize, 18);
      expect(header.style!.fontWeight, FontWeight.bold);
      expect(header.style!.color, kText);

      // Row name typography = kStyleCardTitle + w800 (17/w800).
      final name = tester.widget<Text>(find.text('Bravo'));
      expect(name.style!.fontSize, 17);
      expect(name.style!.fontWeight, FontWeight.w800);
      expect(name.style!.color, kText);
      expect(name.maxLines, 1);
      expect(name.overflow, TextOverflow.ellipsis);

      // Member-count chip text = kStyleLabel + kMuted/w700.
      final count = tester.widget<Text>(find.text('50 members'));
      expect(count.style!.fontSize, 12);
      expect(count.style!.color, kMuted);
      expect(count.style!.fontWeight, FontWeight.w700);

      // Row card: MockupCard radius = kRadiusInput (14), padding 12.
      final cards = tester.widgetList<MockupCard>(
          find.byType(MockupCard));
      expect(cards.length, 7);
      expect(cards.every((c) => c.radius == kRadiusInput), isTrue);
      expect(cards.every((c) => c.padding == const EdgeInsets.all(12)),
          isTrue);
      expect(cards.every((c) => c.animate == false), isTrue);

      // Photo avatars radius 28, arrow circles radius 20 + gold.
      final avatars = tester.widgetList<CircleAvatar>(
          find.byType(CircleAvatar));
      expect(avatars.where((a) => a.radius == 28).length, 7);
      final arrows = avatars.where((a) => a.radius == 20);
      expect(arrows.length, 7);
      expect(arrows.every((a) => a.backgroundColor == kGold), isTrue);

      // NO banner grid, NO description. FIX 23 item 19
      // SUPERSEDES the "no follow buttons" rule: every row now
      // has a Follow button (direct join) — all 7 fixtures are
      // u9's, u1 is not a member, so all 7 show it.
      expect(find.byType(GridView), findsNothing);
      expect(find.textContaining('Discover'), findsNothing);
      expect(find.text('Follow'), findsNWidgets(7));
      expect(find.text('FOLLOW'), findsNothing);
      expect(find.text('JOINED'), findsNothing);
      expect(find.text('Best players only'), findsNothing);
      expect(find.text('50 members'), findsOneWidget);
      expect(find.text('1 member'), findsOneWidget);
      expect(find.text('0 members'), findsOneWidget);

      expect(tester.takeException(), isNull);
    });

    testWidgets('search still filters through the new field',
        (tester) async {
      tallSurface(tester);
      SupaDb.testFixtures = sevenFixtures();
      await tester.pumpWidget(
        const MaterialApp(home: CommunitiesListPage(uid: 'u1')),
      );
      await settle(tester);
      expect(find.text('Top Communities'), findsOneWidget);

      await tester.enterText(find.byType(TextField).first, 'bravo');
      await tester.pump(const Duration(milliseconds: 350));
      await settle(tester);
      expect(find.text('Bravo'), findsOneWidget);
      expect(find.text('Alpha'), findsNothing);
      expect(find.text('Top Communities'), findsNothing);
      expect(find.text('All Communities'), findsNothing);

      await tester.enterText(find.byType(TextField).first, '');
      await tester.pump(const Duration(milliseconds: 350));
      await settle(tester);
      expect(find.text('Top Communities'), findsOneWidget);
      expect(find.text('Golf'), findsOneWidget);
    });

    testWidgets('loading state shows the gold contract indicator',
        (tester) async {
      SupaDb.testFixtures = sevenFixtures();
      await tester.pumpWidget(
        const MaterialApp(home: CommunitiesListPage(uid: 'u1')),
      );
      // First frame: the cached-first load has not finished yet,
      // so the loading state is visible — as the gold indicator.
      expect(find.byType(ArenaLoadingIndicator), findsOneWidget);
      expect(find.byType(StanCommunityRow), findsNothing);
      await settle(tester);
      expect(find.text('Bravo'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('empty list shows the designed empty state',
        (tester) async {
      SupaDb.testFixtures = {
        'communities': [],
        'community_members': [],
      };
      await tester.pumpWidget(
        const MaterialApp(home: CommunitiesListPage(uid: 'u1')),
      );
      await settle(tester);

      expect(find.byType(EmptyState), findsOneWidget);
      expect(find.text('Abhi koi community nahi'), findsOneWidget);
      expect(find.text('CREATE COMMUNITY'), findsOneWidget);
      // Search + background + FAB stay on the empty screen.
      expect(find.byType(ArenaTextField), findsOneWidget);
      expect(find.byType(ArenaBackground), findsOneWidget);
      expect(find.text('CREATE'), findsOneWidget);
      expect(find.byType(StanCommunityRow), findsNothing);
      expect(find.byType(GridView), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('StanCommunityRow standalone', () {
    testWidgets('creator badge + compact count + gold arrow',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: StanCommunityRow(
            community: {
              'name': 'Creator Club',
              'photo_url': '',
              'myRole': 'creator',
              'memberCount': 1500,
            },
            onOpen: () {},
          ),
        ),
      ));
      await settle(tester);

      expect(find.text('Creator Club'), findsOneWidget);
      expect(find.text('CREATOR'), findsOneWidget);
      expect(find.text('1.5K members'), findsOneWidget);
      expect(find.byIcon(Icons.arrow_forward), findsOneWidget);
      final name = tester.widget<Text>(find.text('Creator Club'));
      expect(name.style!.fontSize, 17);
      expect(name.style!.fontWeight, FontWeight.w800);
      expect(tester.takeException(), isNull);
    });
  });
}
