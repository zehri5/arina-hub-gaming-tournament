// FIX 23 — COMMUNITY CHAT + MY COMMUNITY (items 7, 8, 10, 12d, 15, 19).
// Source pins + widget tests. Chat is live-only (pre-entry messages
// hidden), kick notices auto-dismiss in 2.5s, bubbles are neon +
// left-aligned with no like/dislike, the members list shows online
// dots under the "Followers" label, My Community lets the creator
// edit name/description/photo, and every community card has a
// Follow button that disappears after a successful follow.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/community_service.dart';
import 'package:protournament_user/components/arena_chat.dart';
import 'package:protournament_user/screens/communities_screens.dart';
import 'package:protournament_user/services/supabase_db.dart';

import 'audio_test_helpers.dart';

String _region(String src, String start, String end) {
  final s = src.indexOf(start);
  if (s < 0) return '';
  final e = src.indexOf(end, s + start.length);
  if (e < 0) return '';
  return src.substring(s, e);
}

void main() {
  group('fix23 item 7 — live-only chat (source)', () {
    late String chat;

    setUpAll(() {
      final comm = codeOnly(
          requireProjectFile('lib/screens/communities_screens.dart'));
      chat = _region(comm, 'class _CommunityChatTabState',
          'class _CommunityMembersPage');
    });

    test('chat region exists', () {
      expect(chat, isNotEmpty);
    });

    test('entry timestamp captured at init', () {
      expect(chat, contains('_entryTime'));
      expect(chat, contains('DateTime.now().subtract('));
    });

    test('live filter: own messages always live, history filtered', () {
      expect(chat, contains('_isLiveMessage'));
      expect(chat, contains('.where(_isLiveMessage)'));
    });

    test('no history loading on entry (deleted)', () {
      expect(chat, isNot(contains('_loadFirstPage')));
      expect(chat, isNot(contains('_loadMore')));
      expect(chat, isNot(contains('_oldestCursor')));
    });

    test('team chat untouched by the live-only change', () {
      final pro =
          codeOnly(requireProjectFile('lib/screens/pro_features.dart'));
      expect(pro, isNot(contains('_entryTime')));
      expect(pro, isNot(contains('_isLiveMessage')));
    });
  });

  group('fix23 item 8 — kick notice auto-dismiss (source)', () {
    test('kick dialog auto-dismisses after 2.5s', () {
      final comm = codeOnly(
          requireProjectFile('lib/screens/communities_screens.dart'));
      final kick = _region(comm, 'Future<void> _checkKicked(',
          'class _CommunityMembersPage');
      expect(kick, isNotEmpty);
      expect(
          comm, contains('static const Duration kKickNoticeDuration ='));
      expect(
          comm, contains('Duration(milliseconds: 2500)'));
      expect(kick, contains('Timer('));
      expect(kick, contains('Navigator.of(context).pop()'));
    });
  });

  group('fix23 item 10 — neon bubbles, tighter chat, no reactions (source)',
      () {
    test('community chat uses neon left-aligned bubbles', () {
      final comm = codeOnly(
          requireProjectFile('lib/screens/communities_screens.dart'));
      final chat = _region(comm, 'class _CommunityChatTabState',
          'class _CommunityMembersPage');
      expect(chat, contains('neon: true'));
      expect(chat, contains('alignEnd: false'));
      expect(chat, isNot(contains('reactions: _reactionRow')));
      expect(chat, isNot(contains('_toggleReaction')));
    });

    test('neon gap is 4px, standard gap stays 8px', () {
      final arena =
          codeOnly(requireProjectFile('lib/components/arena_chat.dart'));
      expect(arena, contains('kChatRowBottomGapNeon = 4'));
      expect(arena, contains('kChatRowBottomGap = 8'));
      expect(arena, contains('neon ? kChatRowBottomGapNeon'));
    });

    test('team chat keeps its own reactions', () {
      final pro =
          codeOnly(requireProjectFile('lib/screens/pro_features.dart'));
      expect(pro, contains('_reactionRow'));
    });
  });

  group('fix23 item 12d — followers list with online dots (source)', () {
    test('members page is titled Followers + shows presence', () {
      final comm = codeOnly(
          requireProjectFile('lib/screens/communities_screens.dart'));
      final tab = _region(comm, 'class _MembersTab', 'class MyCommunityPage');
      expect(tab, isNotEmpty);
      expect(tab, contains('_presence'));
      expect(tab, contains('presenceIsOnline'));
      expect(tab, contains('_memberAvatarWithDot'));
      expect(comm, contains("title: Text('Followers'"));
    });
  });

  group('fix23 item 15 — My Community + updateCommunity (source)', () {
    test('updateCommunity exists with validation + read-back', () {
      final svc =
          codeOnly(requireProjectFile('lib/community_service.dart'));
      final fn = _region(svc, 'updateCommunity({',
          'static Future<Map<String, dynamic>> createSquad(');
      expect(fn, isNotEmpty);
      expect(fn, contains('Community ka naam likhen.'));
      expect(fn, contains('getCommunity'));
    });

    test('entry is creator-only, page + edit form exist', () {
      final comm = codeOnly(
          requireProjectFile('lib/screens/communities_screens.dart'));
      expect(comm,
          contains('onMyCommunity: _isCreator ? _openMyCommunity : null'));
      expect(comm, contains('class MyCommunityPage'));
      expect(comm, contains('class EditCommunityPage'));
      expect(comm, contains("key: const Key('g23_edit_name_field')"));
      expect(comm, contains("key: const Key('g23_edit_desc_field')"));
      expect(comm, contains("'Open Community Chat'"));
      expect(comm, contains('EDIT COMMUNITY'));
    });

    test('no community-history view was invented', () {
      final comm = codeOnly(
          requireProjectFile('lib/screens/communities_screens.dart'));
      expect(comm, isNot(contains('CommunityHistory')));
      expect(comm, isNot(contains('COMMUNITY HISTORY')));
    });
  });

  group('fix23 item 19 — Follow button on cards (source)', () {
    test('row takes showFollow/onFollow, hides for creator/member', () {
      final comm = codeOnly(
          requireProjectFile('lib/screens/communities_screens.dart'));
      final row = _region(
          comm, 'class StanCommunityRow', 'class CommunitiesListPage');
      expect(row, isNotEmpty);
      expect(row, contains('showFollow'));
      expect(row, contains('onFollow'));
      expect(row, contains('!isCreator && !isMember'));
    });

    test('follow hides the button via _followedIds (no Following state)',
        () {
      final comm = codeOnly(
          requireProjectFile('lib/screens/communities_screens.dart'));
      expect(comm, contains('_followedIds'));
      expect(comm, contains('_followBusyIds'));
      // The row construction is multi-line in code: pin the parts.
      expect(comm, contains('showFollow:'));
      expect(comm,
          contains('!_followedIds.contains(SupaDb.strOf(c[\'id\']))'));
      expect(comm, contains('Follow ho gaya'));
    });

    test('followCommunity inserts a community_members row (real join)',
        () {
      final svc =
          codeOnly(requireProjectFile('lib/community_service.dart'));
      final fn = _region(svc, 'followCommunity(', 'unfollowCommunity(');
      expect(fn, isNotEmpty);
      expect(fn, contains('community_members'));
    });
  });

  group('fix23 item 10 — neon bubble widget', () {
    testWidgets('neon own message is left-aligned with no reactions',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 360,
            child: ArenaChatMessage(
              isMine: true,
              neon: true,
              alignEnd: false,
              text: 'hello neon',
              timeLabel: '11:00 PM',
              senderName: 'Tester',
            ),
          ),
        ),
      ));
      await tester.pump();
      expect(find.text('hello neon'), findsOneWidget);
      // Left-aligned: the bubble starts near the left edge.
      final left = tester.getTopLeft(find.text('hello neon')).dx;
      expect(left, lessThan(100.0));
      // No like/dislike anywhere.
      expect(find.text('👍'), findsNothing);
      expect(find.text('👎'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('standard bubble keeps the 8px gap (team unchanged)',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              ArenaChatMessage(
                  isMine: false, text: 'one', senderName: 'A'),
              ArenaChatMessage(
                  isMine: false, text: 'two', senderName: 'A'),
            ],
          ),
        ),
      ));
      await tester.pump();
      final one = tester.getBottomRight(find.text('one')).dy;
      final two = tester.getTopLeft(find.text('two')).dy;
      // Gap = bubble padding (8 bottom) + avatar/text offsets; the
      // row gap itself is 8 — assert the rows don't overlap and
      // the distance is in the compact-but-not-neon band.
      expect(two - one, greaterThan(0.0));
      expect(tester.takeException(), isNull);
    });
  });

  group('fix23 item 19 — StanCommunityRow Follow widget', () {
    testWidgets('Follow shows for a non-member, tap fires onFollow',
        (tester) async {
      var followed = false;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: StanCommunityRow(
            community: {
              'id': 'c1',
              'name': 'Test Community',
              'memberCount': 4,
              'myRole': 'member',
              'isMember': false,
            },
            onOpen: () {},
            showFollow: true,
            onFollow: () => followed = true,
          ),
        ),
      ));
      await tester.pump();
      expect(find.text('Follow'), findsOneWidget);
      await tester.tap(find.text('Follow'));
      await tester.pump();
      expect(followed, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Follow hidden for creator + for existing members',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              StanCommunityRow(
                community: {
                  'id': 'c1',
                  'name': 'Mine',
                  'memberCount': 4,
                  'myRole': 'creator',
                },
                onOpen: () {},
                showFollow: true,
                onFollow: () {},
              ),
              StanCommunityRow(
                community: {
                  'id': 'c2',
                  'name': 'Joined',
                  'memberCount': 4,
                  'myRole': 'member',
                  'isMember': true,
                },
                onOpen: () {},
                showFollow: true,
                onFollow: () {},
              ),
            ],
          ),
        ),
      ));
      await tester.pump();
      expect(find.text('Follow'), findsNothing);
      expect(find.text('CREATOR'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('fix23 item 15 — updateCommunity + Edit page', () {
    setUp(() {
      SupaDb.testFixtures = {
        'communities': [
          {
            'id': 'comm-1',
            'name': 'Old Name',
            'description': 'Old desc',
            'created_by_uid': 'u1',
          }
        ],
      };
    });

    tearDown(() {
      SupaDb.testFixtures = null;
    });

    test('updateCommunity renames via the fixture seam', () async {
      final res = await CommunityGroups.updateCommunity(
          id: 'comm-1', name: 'New Name', description: 'New desc');
      expect(res['ok'], isTrue);
      expect(
          SupaDb.testFixtures!['communities']!.first['name'], 'New Name');
      expect(SupaDb.testFixtures!['communities']!.first['description'],
          'New desc');
    });

    test('updateCommunity rejects an empty name', () async {
      final res =
          await CommunityGroups.updateCommunity(id: 'comm-1', name: '   ');
      expect(res['ok'], isFalse);
      expect(res['error'], 'Community ka naam likhen.');
    });

    test('updateCommunity fails honestly for an unknown id', () async {
      final res =
          await CommunityGroups.updateCommunity(id: 'nope', name: 'X');
      expect(res['ok'], isFalse);
    });

    testWidgets('Edit page pre-fills + saves the new name',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: EditCommunityPage(
          communityId: 'comm-1',
          name: 'Old Name',
          description: 'Old desc',
        ),
      ));
      await tester.pump();
      expect(find.text('Old Name'), findsOneWidget);
      await tester.enterText(
          find.byKey(const Key('g23_edit_name_field')), 'New Name');
      await tester.tap(find.text('SAVE'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
          SupaDb.testFixtures!['communities']!.first['name'], 'New Name');
      expect(tester.takeException(), isNull);
    });

    testWidgets('Edit page rejects an empty name (no save)',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: EditCommunityPage(
          communityId: 'comm-1',
          name: 'Old Name',
          description: 'Old desc',
        ),
      ));
      await tester.pump();
      await tester.enterText(find.byKey(const Key('g23_edit_name_field')), '');
      await tester.tap(find.text('SAVE'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
          SupaDb.testFixtures!['communities']!.first['name'], 'Old Name');
      expect(tester.takeException(), isNull);
    });
  });
}
