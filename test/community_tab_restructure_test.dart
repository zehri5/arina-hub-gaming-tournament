// COMMUNITY TAB RESTRUCTURE (2026-11-22, user order) — regression
// tests. The nav Community tab is the teams list now
// (TeamsPage, embedded); Friends / Requests / Followers /
// Messages / Following moved to Profile (refined 05:07: Profile
// → "Friends & Requests" with 3 tabs + a separate "Messages");
// the old single hub (CommunityHubPage) is deleted; "Create Team"
// never clips again; the two CTAs match + animate; team
// cards follow the global card rule; the bottom nav highlights
// the tab the page actually came from.
//
// FIX 12 G11 (2026-11-23) SUPERSEDES the toggle half: the two-pill
// Clan/Community toggle + the Create/Join pair are replaced by ONE
// row of three buttons [Community] [Squad] [Create], with Join by
// Code full-width on the Squad side. The affected assertions below
// were updated to the new layout.
//
// Source-invariant tests read the R-copy sources (no backend).
// Widget tests pump the new pages (the readiness probes swallow
// backend errors and read as not-ready with no backend — same
// pattern as the old hub clip test in sameer_fixes_test.dart).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/components/arena_components.dart';
import 'package:protournament_user/screens/community_screens.dart';
import 'package:protournament_user/screens/pro_features.dart';
import 'package:protournament_user/services/supabase_db.dart';
import 'package:protournament_user/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

String _read(String path) => File(path).readAsStringSync();

String _stripComments(String src) => src
    .split('\n')
    .where((l) => !l.trimLeft().startsWith('//'))
    .join('\n');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late String mainDart;
  late String moreScreens;
  late String communityScreens;
  late String proFeatures;
  late String arenaComponents;

  setUpAll(() {
    mainDart = _read('lib/main.dart');
    moreScreens = _read('lib/screens/more_screens.dart');
    communityScreens = _read('lib/screens/community_screens.dart');
    proFeatures = _read('lib/screens/pro_features.dart');
    arenaComponents = _read('lib/components/arena_components.dart');
  });

  group('Community tab restructure — source invariants', () {
    test('nav Community tab is TeamsPage, embedded; hub is gone', () {
      expect(mainDart, contains('TeamsPage(uid: uid, embedded: true)'));
      expect(mainDart, isNot(contains('CommunityHubPage')));
      expect(_stripComments(communityScreens),
          isNot(contains('class CommunityHubPage')));
      expect(_stripComments(communityScreens),
          isNot(contains('SQUAD & GROUP CHAT')));
    });

    test('pending-request badge moved from Community to Profile tab', () {
      final communityLabel = mainDart.indexOf("label: tr('Community'");
      final profileLabel = mainDart.indexOf("label: tr('Profile'");
      final badge = mainDart.indexOf('pendingRequestCountStream');
      expect(communityLabel, isNot(-1));
      expect(profileLabel, isNot(-1));
      expect(badge, isNot(-1));
      // The badge stream sits inside the Profile item now: after
      // the Community item's label, before the Profile label.
      expect(badge, greaterThan(communityLabel));
      expect(badge, lessThan(profileLabel));
    });

    test('Profile has Friends & Requests / Messages / Following', () {
      expect(moreScreens, contains("FriendsRequestsPage(uid: widget.uid)"));
      expect(moreScreens, contains("MessagesPage(uid: widget.uid)"));
      expect(moreScreens, contains("FollowingPage(uid: widget.uid)"));
      expect(moreScreens, contains("'Friends & Requests'"));
      expect(moreScreens, contains("'Messages'"));
      expect(moreScreens, isNot(contains('CommunityHubPage')));
    });

    test('Friends & Requests has 3 tabs: Friends, Requests, Followers', () {
      expect(communityScreens, contains('class FriendsRequestsPage'));
      expect(communityScreens,
          contains("labels: const ['Friends', 'Requests', 'Followers']"));
      expect(communityScreens, contains('class _FollowersTab'));
      expect(communityScreens, contains('class MessagesPage'));
      expect(communityScreens, contains('class FollowingPage'));
      expect(communityScreens, contains('_FollowingTab('));
    });

    test('TeamsPage: embedded hides its own bottom nav; list scrolls', () {
      expect(proFeatures, contains('final bool embedded;'));
      expect(
          proFeatures,
          contains(
              'bottomNavigationBar: widget.embedded ? null : const MyTeamBottomNav()'));
      // The teams list body is a ListView (vertical scroll) — the
      // user order: "zyada teams hon to upar-neeche scroll ho".
      final teamsStart = proFeatures.indexOf('class _TeamsPageState');
      final teamsEnd =
          proFeatures.indexOf('class TeamDetailPage', teamsStart);
      final teamsPage = proFeatures.substring(teamsStart, teamsEnd);
      expect(teamsPage, contains('ListView('));
    });

    test('TeamsPage links to Communities (feature not orphaned)', () {
      // FIX 11 (2026-11-23): the "Browse Communities" button is
      // GONE — the Community tab embeds the list instead. The
      // feature is not orphaned: the tab loads the same data
      // (listCommunities), opens the same detail page, and creates
      // through the same create page.
      expect(proFeatures, isNot(contains("label: 'Browse Communities'")));
      // FIX 12 G11: the two-pill toggle is gone — the top row is
      // [Community] [Squad] [Create] from named constants.
      expect(proFeatures, isNot(contains("_toggleBtn(label: 'Clan'")));
      expect(proFeatures, contains('label: kCommunityTabLabel'));
      expect(proFeatures, contains('label: kSquadTabLabel'));
      expect(proFeatures, contains('label: kCreateTabLabel'));
      expect(proFeatures, contains('CommunityGroups.listCommunities'));
      expect(proFeatures, contains('CommunityDetailPage('));
      expect(proFeatures, contains('CreateCommunityPage(uid: widget.uid)'));
    });

    test('GoldButton label cannot clip (FittedBox scaleDown)', () {
      final start = arenaComponents.indexOf('class GoldButton');
      final end = arenaComponents.indexOf('class OutlineButton', start);
      final gold = arenaComponents.substring(start, end);
      expect(gold, contains('FittedBox('));
      expect(gold, contains('BoxFit.scaleDown'));
    });

    test('nav highlight is context-aware (MyTeamBottomNav)', () {
      expect(proFeatures, contains('final int activeIndex;'));
      expect(proFeatures,
          contains('const MyTeamBottomNav({super.key, this.activeIndex = 2})'));
      expect(proFeatures, contains('final int navIndex;'));
      expect(proFeatures, contains('navIndex: widget.embedded ? 4 : 2'));
      expect(proFeatures,
          contains('MyTeamBottomNav(activeIndex: widget.navIndex)'));
    });

    test('Header buttons match + animate', () {
      final teamsStart = proFeatures.indexOf('class _TeamsPageState');
      final teamsEnd =
          proFeatures.indexOf('class TeamDetailPage', teamsStart);
      final teamsPage = proFeatures.substring(teamsStart, teamsEnd);
      // All header buttons wrapped in the animated CTA
      // (press-scale + breathing gold halo): the three-button
      // top row (3) + the Squad side's Join by Code (1) = 4.
      // (FIX 12 G11: was 5 — the two-pill toggle (2) + the clan
      // Create/Join pair (2) + the community Create button (1).)
      expect('_AnimatedCta('.allMatches(teamsPage).length, 4);
      // Join matches Create: pill radius 30, same padding, same
      // w900 16px label. FIX 23 item 18: the horizontal padding
      // tightened 20 -> 12 so all three uniform pills fit at
      // 360px.
      expect(teamsPage, contains('BorderRadius.circular(30)'));
      expect(teamsPage,
          contains('EdgeInsets.symmetric(vertical: 16, horizontal: 12)'));
      expect(proFeatures, contains('class _AnimatedCta'));
      expect(proFeatures, contains('AnimatedScale('));
    });

    test('team/clan cards follow the global card rule', () {
      final start = proFeatures.indexOf('class MyTeamCard');
      final end = proFeatures.indexOf('class TeamMemberCard', start);
      final card = proFeatures.substring(start, end);
      // Delegates to MockupCard (standard fill + two animated
      // shines, no full border) — the PRINTER-COPY full gold
      // border + glow are gone.
      expect(card, contains('MockupCard('));
      expect(card, contains('animate: gold'));
      expect(card, isNot(contains('Border.all(')));
      expect(card, isNot(contains('BoxShadow(')));
    });
  });

  group('Community tab restructure — widget tests', () {
    testWidgets(
        'Friends & Requests: 3 pills, no Messages/Following pill, no Squad card',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: FriendsRequestsPage(uid: 'test-uid'),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Friends'), findsOneWidget);
      expect(find.text('Requests'), findsOneWidget);
      expect(find.text('Followers'), findsOneWidget);
      expect(find.text('Messages'), findsNothing);
      expect(find.text('Following'), findsNothing);
      expect(find.text('SQUAD & GROUP CHAT'), findsNothing);
      expect(find.text('My Teams & Squad Chat'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('MessagesPage renders with MESSAGES title', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: MessagesPage(uid: 'test-uid'),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('MESSAGES'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('FollowingPage renders with FOLLOWING title',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: FollowingPage(uid: 'test-uid'),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('FOLLOWING'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('GoldButton "Create Team" fits a 159px half slot',
        (tester) async {
      // 360px phone: (360 - 32 page padding - 10 gap) / 2 = 159.
      // Pre-fix this overflowed (RenderFlex error); FittedBox
      // scaleDown shrinks the label instead. FIX 12 G5 renamed the
      // button to "Create Team" (the clan type is gone).
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 159,
            child: GoldButton(label: 'Create Team', onPressed: () {}),
          ),
        ),
      ));
      await tester.pump();
      expect(find.text('Create Team'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('MyTeamCard renders as a MockupCard (global card rule)',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: MyTeamCard(child: Text('card-content')),
        ),
      ));
      await tester.pump();
      expect(find.byType(MockupCard), findsOneWidget);
      expect(find.text('card-content'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('TeamsPage embedded (widget)', () {
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

    Future<void> pumpTeams(WidgetTester tester, {bool embedded = true}) async {
      await tester.pumpWidget(MaterialApp(
          home: TeamsPage(uid: 'test-uid', embedded: embedded)));
      await tester.pump();
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
    }

    testWidgets('embedded: no own bottom nav, three-button row + Join',
        (tester) async {
      await pumpTeams(tester, embedded: true);
      expect(find.byType(MyTeamBottomNav), findsNothing);
      // FIX 12 G11: the three-button top row (Community / Squad /
      // Create) + Join by Code on the Squad side. The old two-pill
      // toggle, "Create Clan" and "Browse Communities" are gone.
      expect(find.text('Community'), findsOneWidget);
      expect(find.text('Squad'), findsOneWidget);
      expect(find.text('Create'), findsOneWidget);
      expect(find.text('Clan'), findsNothing);
      expect(find.text('Create Clan'), findsNothing);
      expect(find.text('Join by Code'), findsOneWidget);
      expect(find.text('Browse Communities'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('pushed (not embedded): own bottom nav stays',
        (tester) async {
      await pumpTeams(tester, embedded: false);
      expect(find.byType(MyTeamBottomNav), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Community toggle shows the embedded communities tab',
        (tester) async {
      // FIX 11: the Community toggle (not a separate page) shows
      // the communities list inline — search field + top-row
      // Create + the empty state (no fixture communities).
      // FIX 12 G11: no separate Create Community button — Create
      // lives in the top row now.
      await pumpTeams(tester, embedded: true);
      await tester.tap(find.text('Community'));
      await tester.pump();
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(find.text('Create'), findsOneWidget);
      expect(find.text('Create Community'), findsNothing);
      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('Abhi koi community nahi'), findsOneWidget);
      expect(find.text('Create Clan'), findsNothing);
      expect(find.text('Join by Code'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('Nav highlight follows the entry point (widget)', () {
    setUp(() {
      SupaDb.testFixtures = {
        'teams': [
          {
            'id': 'team-1',
            'name': 'Falcons',
            'tag': 'FLC',
            'game': 'PUBG Mobile',
            'is_clan': false,
            'captain_uid': 'test-uid',
            'captain_name': 'Tester',
            'invite_code': 'ABC123'
          },
        ],
        'team_members': [
          {
            'team_id': 'team-1',
            'firebase_uid': 'test-uid',
            'user_name': 'Tester',
            'role': 'captain'
          },
        ],
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

    Future<int> openDetailNavIndex(WidgetTester tester,
        {required bool embedded}) async {
      await tester.pumpWidget(MaterialApp(
          home: TeamsPage(uid: 'test-uid', embedded: embedded)));
      await tester.pump();
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(find.text('Members & Chat'), findsOneWidget);
      await tester.tap(find.text('Members & Chat'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      // v2016 FIX 13: 'Members & Chat' opens the CHAT directly now —
      // the detail page lives inside the chat's More menu as
      // 'Team settings'. Reach the detail page through the menu.
      expect(find.byType(TeamChatPage), findsOneWidget);
      expect(find.byType(TeamDetailPage), findsNothing);
      await tester.tap(find.byIcon(Icons.more_horiz));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.text('Team settings'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      // The detail page's OWN nav (a pushed list keeps its nav in
      // the route below, so scope the lookup to TeamDetailPage).
      final bar = tester.widget<BottomNavigationBar>(
        find.descendant(
          of: find.byType(TeamDetailPage),
          matching: find.byType(BottomNavigationBar),
        ),
      );
      return bar.currentIndex;
    }

    testWidgets('from the Community tab: detail highlights Community (4)',
        (tester) async {
      final index = await openDetailNavIndex(tester, embedded: true);
      expect(index, 4);
      expect(tester.takeException(), isNull);
    });

    testWidgets('from a pushed list: detail highlights My Matches (2)',
        (tester) async {
      final index = await openDetailNavIndex(tester, embedded: false);
      expect(index, 2);
      expect(tester.takeException(), isNull);
    });
  });
}
