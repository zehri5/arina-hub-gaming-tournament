// FIX 12 G10 (2026-11-23) — COMMUNITY CHAT POLISH + LIVE MEMBERS.
//   1. Live members (presence) in/above community chat — REMOVED
//      by FIX 20 (fix 6, 2026-11-23 user order): the
//      LiveMembersStrip + onlineCommunityMembers + the chat tab's
//      30s presence refresh are deleted. The detail header's own
//      online count (_loadOnlineCount) is untouched.
//   2. Polished bubbles: ArenaChatMessage/ArenaChatBubble gain an
//      opt-in `polished` flag (default false — no other chat
//      changes); community chat passes polished: true.
//   3. Sender pill stays "TEAM N"; the chat refresh logic
//      (streamCommunityChat, G2's pollInterval) is untouched.
// Source-invariant tests read the sources (no backend); widget
// tests pump the strip and the bubble directly.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/components/arena_chat.dart';
import 'package:shared_preferences/shared_preferences.dart';

String _read(String path) => File(path).readAsStringSync();

String _region(String src, String from, String to) {
  final start = src.indexOf(from);
  final end = src.indexOf(to, start);
  return src.substring(start, end);
}

/// The chat bubble container: the Container whose decoration is a
/// BoxDecoration with the given corner radius.
Finder _bubbleWithRadius(double r) => find.byWidgetPredicate((w) =>
    w is Container &&
    w.decoration is BoxDecoration &&
    (w.decoration as BoxDecoration).borderRadius ==
        BorderRadius.circular(r));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late String communityScreens;
  late String arenaChat;

  setUpAll(() {
    communityScreens = _read('lib/screens/communities_screens.dart');
    arenaChat = _read('lib/components/arena_chat.dart');
  });

  group('Fix 20 (fix 6) — live-members strip REMOVED', () {
    test('strip class + helper + call site are all deleted', () {
      expect(communityScreens,
          isNot(contains('class LiveMembersStrip extends StatelessWidget')));
      expect(communityScreens,
          isNot(contains('class CommunityLiveMember {')));
      expect(
          communityScreens,
          isNot(contains(
              'List<CommunityLiveMember> onlineCommunityMembers({')));
      expect(communityScreens,
          isNot(contains('LiveMembersStrip(members: _liveMembers)')));
    });

    test('detail header online count is GONE — presence lives in the Followers list (FIX 23 items 1+12)', () {
      // FIX 23 items 1+12b SUPERSEDE the header line: the top bar
      // is gone; online presence moved to the Followers list
      // (per-follower online dot, same presence data).
      final detail = _region(communityScreens,
          'class _CommunityDetailPageState', 'class _FollowToInteractBanner');
      expect(detail, isNot(contains('Future<void> _loadOnlineCount()')));
      expect(detail, isNot(contains('int _onlineCount')));
      expect(detail, isNot(contains('bool _showOnline')));
      expect(detail, contains('Future<void> _loadMemberCount()'));
      expect(detail, contains('_memberCountFresh'));
      expect(communityScreens, contains('_memberAvatarWithDot'));
      expect(communityScreens, contains('presenceIsOnline'));
    });
  });

  group('Fix 12 G10 — polished bubbles', () {
    testWidgets('polished bubble is rounder (radius 18), default stays 16',
        (t) async {
      await t.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: ArenaChatMessage(
            isMine: false,
            text: 'hello',
            senderName: 'Ali',
            polished: true,
          ),
        ),
      ));
      expect(_bubbleWithRadius(18), findsOneWidget);
      expect(_bubbleWithRadius(16), findsNothing);

      await t.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: ArenaChatMessage(
            isMine: false,
            text: 'hello',
            senderName: 'Ali',
          ),
        ),
      ));
      await t.pump();
      expect(_bubbleWithRadius(16), findsOneWidget);
      expect(_bubbleWithRadius(18), findsNothing);
    });

    test('polished flag is opt-in in the shared component (default false)',
        () {
      expect(arenaChat, contains('final bool polished;'));
      expect(arenaChat, contains('this.polished = false,'));
      expect(arenaChat, contains('polished: polished,'));
    });
  });

  group('Fix 12 G10 — chat tab wiring (source invariants)', () {
    test('chat tab has NO live strip and NO presence refresh (FIX 20 fix 6)',
        () {
      final chatTab = _region(communityScreens,
          'class _CommunityChatTabState', '// ------------------------------------------------------------------\n// MEMBERS TAB');
      expect(chatTab, isNot(contains('LiveMembersStrip(members: _liveMembers)')));
      expect(chatTab, isNot(contains('_refreshLiveMembers')));
      expect(chatTab, isNot(contains('_loadLiveMembers')));
      expect(chatTab, isNot(contains('_presenceTimer')));
      expect(chatTab, isNot(contains('onlineCommunityMembers(')));
      expect(chatTab, isNot(contains('CommunityGroups.memberUids(')));
      expect(chatTab, isNot(contains('SupaDb.getPresenceMap(')));
      expect(chatTab, isNot(contains('widget.memberCount > 1000')));
    });

    test('chat tab passes polished: true to the message rows', () {
      final chatTab = _region(communityScreens,
          'class _CommunityChatTabState', '// ------------------------------------------------------------------\n// MEMBERS TAB');
      expect(chatTab, contains('polished: true,'));
    });

    test('TEAM N sender pill is untouched', () {
      expect(communityScreens,
          contains("'TEAM \${_teamOf[senderUid]}'"));
    });

    test('chat refresh logic untouched (G2 owns pollInterval)', () {
      final chatTab = _region(communityScreens,
          'class _CommunityChatTabState', '// ------------------------------------------------------------------\n// MEMBERS TAB');
      expect(
          chatTab,
          contains(
              '_streamSub = CommunityGroups.streamCommunityChat(widget.communityId)'));
      expect(chatTab, isNot(contains('pollInterval')));
    });
  });
}
