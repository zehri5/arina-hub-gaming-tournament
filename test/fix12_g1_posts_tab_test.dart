// FIX 12 — GROUP G1 (2026-11-23, user order §1): REMOVE the Posts
// tab from the community detail screen. Only CHAT + MEMBERS remain.
//   * TabBar: the Tab(icon: Icons.article, text: 'POSTS') entry is gone.
//   * TabBarView: the _PostsTab(...) child is gone.
//   * _PostsTab / _PostCard classes are gone (the post composer with them).
//   * NOT removed: the server tables (community_posts /
//     community_comments stay — backend untouched), the
//     CommunitiesListPage FAB, the TEAM N sender pill.
//
// FIX 22 (2026-11-23, user order: "ye hata do, direct chat nazar
// aye") SUPERSEDES the tab layout this file pinned: the CHAT/MEMBERS
// TabBar is gone too — CommunityDetailPage shows the chat directly
// and the members list opens as a pushed page (_CommunityMembersPage
// via the header Members button). The pins below were rewritten to
// the new structure: no TabController / TabBar / TabBarView /
// CommunityDetailTab anywhere; the POSTS-removal pins stay (posts
// must never come back either).
// Source-invariant tests read the sources (no backend); widget tests
// pump CommunityDetailPage with SupaDb.testFixtures.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/screens/communities_screens.dart';
import 'package:protournament_user/services/supabase_db.dart';
import 'package:shared_preferences/shared_preferences.dart';

String _read(String path) => File(path).readAsStringSync();

// Full-line // comments are stripped: the G1 removal notes mention
// Posts by name, and the FIX 22 note names the deleted tab pieces,
// so the assertions must check code, not prose.
String _code(String src) =>
    src.split('\n').where((l) => !l.trimLeft().startsWith('//')).join('\n');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late String communityScreens;
  late String communityService;

  setUpAll(() {
    communityScreens = _read('lib/screens/communities_screens.dart');
    communityService = _read('lib/community_service.dart');
  });

  group('Fix 12 G1 — Posts tab removed (source invariants)', () {
    test('no tab machinery at all (FIX 22 supersedes the 2-tab layout)',
        () {
      final code = _code(communityScreens);
      expect(code, isNot(contains('TabController')));
      expect(code, isNot(contains('TabBar')));
      expect(code, isNot(contains('TabBarView')));
      expect(code, isNot(contains('CommunityDetailTab')));
      expect(code, isNot(contains('communityDetailTabs')));
      expect(code, isNot(contains('communityDetailTabIndex')));
      expect(code, isNot(contains('_detailTabWidget')));
      expect(code, isNot(contains('_detailTabPage')));
      expect(code, isNot(contains('_tabs.')));
      expect(code, isNot(contains('initialTab')));
      expect(code, isNot(contains('TabController(length: 3')));
      expect(code, isNot(contains('TabController(length: 2')));
      // The chat + members widgets still exist — chat renders
      // directly, members live in their own pushed page.
      expect(code, contains('_CommunityChatTab('));
      expect(code, contains('_MembersTab('));
      expect(code, contains('_CommunityMembersPage('));
    });

    test('no TabBar entries; header gold CHAT title stays, no POSTS', () {
      final code = _code(communityScreens);
      expect(code, isNot(contains('Tab(icon:')));
      expect(code, isNot(contains("text: 'MEMBERS'")));
      expect(code, isNot(contains("text: 'POSTS'")));
      expect(code, isNot(contains('Icons.article')));
      // The header title keeps the gold "CHAT" word (RichText span)
      // — it is the screen title, not a tab.
      expect(code, contains("text: 'CHAT'"));
    });

    test('Posts classes are gone; chat renders directly', () {
      final code = _code(communityScreens);
      expect(code, isNot(contains('class _PostsTab')));
      expect(code, isNot(contains('class _PostsTabState')));
      expect(code, isNot(contains('class _PostCard')));
      expect(code, isNot(contains('class _PostCardState')));
      expect(code, isNot(contains('_PostsTab(')));
      expect(code, isNot(contains('_PostCard(')));
      // The chat widget renders directly in the detail body.
      expect(code, contains('_CommunityChatTab('));
      expect(code, contains('_MembersTab('));
    });

    test('Members header button pushes the members page (no animateTo)',
        () {
      final code = _code(communityScreens);
      expect(code, contains('onTap: _openMembers'));
      expect(code, contains('void _openMembers()'));
      expect(code, contains('_CommunityMembersPage('));
      // (The chat's own _scroll.animateTo stays — it scrolls the
      // message list, it has nothing to do with tabs.)
      expect(code, isNot(contains('_tabs.animateTo')));
    });

    test('Kick dialog no longer promises posts to a kicked member', () {
      final code = _code(communityScreens);
      expect(code,
          isNot(contains('posts aur members dekh sakte hain')));
      expect(code, contains('Aap members dekh sakte hain'));
    });

    test('Server tables untouched — posts API still in the service', () {
      expect(communityService, contains('community_posts'));
      expect(communityService, contains('community_comments'));
    });

    test('Out of scope, untouched: list FAB + TEAM N pill', () {
      final code = _code(communityScreens);
      expect(code, contains('FloatingActionButton.extended'));
      expect(code, contains("label: const Text('CREATE'"));
      expect(code, contains(r"'TEAM ${_teamOf[senderUid]}'"));
    });
  });

  group('Fix 12 G1 — CommunityDetailPage shows chat directly (widget)',
      () {
    setUp(() {
      SupaDb.testFixtures = {
        'communities': [
          {
            'id': 'comm-1',
            'name': 'Meri Kahani',
            'description': 'testing',
            'photo_url': '',
            'is_public': true,
            'created_by_uid': 'test-uid',
            'created_at': '2026-11-22T19:39:32Z',
          },
        ],
        'community_members': [
          {
            'community_id': 'comm-1',
            'firebase_uid': 'test-uid',
            'role': 'creator'
          },
          {
            'community_id': 'comm-1',
            'firebase_uid': 'other-uid',
            'role': 'member'
          },
        ],
        'profiles': [
          {
            'firebase_uid': 'test-uid',
            'display_name': 'Tester',
            'username': 'tester'
          },
          {
            'firebase_uid': 'other-uid',
            'display_name': 'Other',
            'username': 'other'
          },
        ],
        'chat_messages': [],
      };
    });
    tearDown(() {
      SupaDb.testFixtures = null;
    });

    Future<void> pumpDetail(WidgetTester tester) async {
      await tester.pumpWidget(MaterialApp(
          home: CommunityDetailPage(
              uid: 'test-uid',
              communityId: 'comm-1',
              community: {
                'id': 'comm-1',
                'name': 'Meri Kahani',
                'description': 'testing',
                'photo_url': '',
                'is_public': true,
                'created_by_uid': 'test-uid',
                'created_at': '2026-11-22T19:39:32Z',
              })));
      await tester.pump();
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
    }

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
    }

    testWidgets('no tabs render at all; chat shows directly',
        (tester) async {
      await pumpDetail(tester);
      expect(find.byType(CommunityDetailPage), findsOneWidget);
      expect(find.byType(TabBar), findsNothing);
      expect(find.byType(Tab), findsNothing);
      // Chat empty state is visible — the chat renders directly.
      expect(find.text('Abhi koi chat nahi'), findsOneWidget);
      // Header chrome stayed: Members button + gold CHAT title
      // (the title is a RichText span, not a Text widget — and
      // every Text builds an inner RichText, so match by content).
      expect(find.text('Members'), findsOneWidget);
      final header = tester
          .widgetList<RichText>(find.descendant(
              of: find.byType(AppBar), matching: find.byType(RichText)))
          .firstWhere((r) => r.text.toPlainText().contains('CHAT'));
      expect(header.text.toPlainText(), contains('MERI KAHANI'));
      expect(find.text('POSTS'), findsNothing);
      expect(find.byIcon(Icons.article), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('chat renders directly on open; members list not built',
        (tester) async {
      await pumpDetail(tester);
      expect(find.text('Abhi koi chat nahi'), findsOneWidget);
      // Members search field is NOT built until the members page
      // is opened.
      expect(find.text('Member dhoondhen...'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('header Members button pushes the members page',
        (tester) async {
      await pumpDetail(tester);
      await tester.tap(find.text('Members'));
      await tester.pump();
      await settle(tester);
      // Members page content is now showing, on a pushed route —
      // its own AppBar title 'Members' is visible (the detail
      // page's header button is offstage under the pushed route,
      // so finders see only the pushed title).
      expect(find.text('Member dhoondhen...'), findsOneWidget);
      expect(find.text('Members'), findsOneWidget);
      expect(find.text('POSTS'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('back from the members page returns to the chat',
        (tester) async {
      await pumpDetail(tester);
      await tester.tap(find.text('Members'));
      await tester.pump();
      await settle(tester);
      expect(find.text('Member dhoondhen...'), findsOneWidget);
      await tester.pageBack();
      await tester.pump();
      await settle(tester);
      expect(find.text('Abhi koi chat nahi'), findsOneWidget);
      expect(find.text('Member dhoondhen...'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
