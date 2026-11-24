// FIX 22 (2026-11-23, user orders from v2021 phone screenshots):
//
// ITEM 1 — REMOVE the CHAT/MEMBERS tab bar from CommunityDetailPage
// ("ye hata do, direct chat nazar aye"): no TabBar / TabBarView /
// TabController / CommunityDetailTab anywhere; the chat renders
// directly in the detail body; the members list opens as a pushed
// page (_CommunityMembersPage) from the header Members button.
// The header gold "CHAT" title stays (screen title, not a tab).
//
// ITEM 2 — REDUCE the spacing between the composer icons
// ("in icon ke beach mai space kam kro"): the shared
// [ArenaChatInputBar] gaps tightened — emoji ↔ attach 8 → 4,
// attach ↔ pill edge 10 → 6, pill ↔ send 10 → 6. Icons
// themselves (22px) and the send button (48×48) are unchanged.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/components/arena_chat.dart';

String _read(String path) => File(path).readAsStringSync();

// Full-line // comments are stripped: the FIX 22 note names the
// deleted tab pieces, so the assertions must check code, not prose.
String _code(String src) =>
    src.split('\n').where((l) => !l.trimLeft().startsWith('//')).join('\n');

String _region(String src, String start, String end) {
  final s = src.indexOf(start);
  final e = src.indexOf(end, s);
  return src.substring(s, e);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late String communityScreens;
  late String proFeatures;
  late String arenaChat;

  setUpAll(() {
    communityScreens = _read('lib/screens/communities_screens.dart');
    proFeatures = _read('lib/screens/pro_features.dart');
    arenaChat = _read('lib/components/arena_chat.dart');
  });

  group('Fix 22 item 1 — no tabs, chat renders directly (source)', () {
    test('no tab machinery anywhere in communities_screens.dart', () {
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
      expect(code, isNot(contains('Tab(icon:')));
      expect(code, isNot(contains("text: 'MEMBERS'")));
    });

    test('detail body renders _CommunityChatTab directly, same args', () {
      final code = _code(communityScreens);
      final detail = _region(code, 'class _CommunityDetailPageState',
          'class _FollowToInteractBanner');
      expect(detail, contains('child: _CommunityChatTab('));
      expect(detail, contains('uid: widget.uid'));
      expect(detail, contains('communityId: _id'));
      expect(detail, contains('isMember: _isMember'));
      expect(detail, contains('memberCount: count'));
      expect(detail, contains('myName: _myName'));
      // FIX 23 item 16a SUPERSEDES the conditional panel mount:
      // the voice panel is STICKY now — always mounted, never
      // closed (no _voicePanelOpen gate). The lock banner stays.
      expect(detail, contains('if (!_voiceEnabled) _voiceLockBanner()'));
      expect(detail, isNot(contains('if (_voicePanelOpen) _buildVoicePanel()')));
      expect(detail, contains('onSidebarFollowers: _openMembers'));
    });

    test('Followers sidebar entry opens _MembersTab as a pushed page (FIX 23 items 1+9)', () {
      final code = _code(communityScreens);
      final detail = _region(code, 'class _CommunityDetailPageState',
          'class _FollowToInteractBanner');
      // FIX 23 item 1: the Members HEADER button is gone with
      // the top bar; the members page opens from the sidebar
      // Followers entry (item 9) via onSidebarFollowers.
      expect(detail, isNot(contains("label: 'Members'")));
      expect(detail, isNot(contains('onTap: _openMembers')));
      expect(detail, contains('onSidebarFollowers: _openMembers'));
      final open = _region(
          detail, 'void _openMembers()', 'Widget build(BuildContext context)');
      expect(open, contains('Navigator.push('));
      expect(open, contains('MaterialPageRoute('));
      expect(open, contains('_CommunityMembersPage('));
      expect(open, contains('communityId: _id'));
      expect(open, contains('uid: widget.uid'));
      expect(open, contains('isCreator: _isCreator'));
      expect(open, contains('voiceApproved: _voiceApproved'));
      // The pushed page builds the SAME members widget, same args.
      // (End marker is the next class — the MEMBERS TAB section
      // header is a comment line, stripped from `code`.)
      final page = _region(code, 'class _CommunityMembersPage',
          'class _MembersTab extends StatefulWidget');
      expect(page, contains('body: _MembersTab('));
      expect(page, contains('communityId: communityId'));
      expect(page, contains('uid: uid'));
      expect(page, contains('isCreator: isCreator'));
      expect(page, contains('voiceApproved: voiceApproved'));
    });

    test('header gold CHAT title GONE with the top bar (FIX 23 item 1); call sites pass no tab param', () {
      final code = _code(communityScreens);
      // FIX 23 item 1: the whole top bar (incl. the gold CHAT
      // title) is removed — the room opens on the chat directly.
      expect(code, isNot(contains("text: 'CHAT'")));
      expect(communityScreens, contains('CommunityDetailPage('));
      expect(communityScreens, isNot(contains('initialTab:')));
      expect(proFeatures, contains('CommunityDetailPage('));
      expect(proFeatures, isNot(contains('initialTab:')));
    });
  });

  group('Fix 22 item 2 — composer icon gaps tightened', () {
    test('gap constants are the tightened values (was 8 / 10 / 10)', () {
      expect(kComposerIconGap, 4);
      expect(kComposerIconEdgeGap, 6);
      expect(kComposerSendGap, 6);
      // Each is strictly tighter than the old value.
      expect(kComposerIconGap, lessThan(8));
      expect(kComposerIconEdgeGap, lessThan(10));
      expect(kComposerSendGap, lessThan(10));
    });

    test('the constants are actually used in ArenaChatInputBar', () {
      // Scoped to the composer class — other widgets in the same
      // file legitimately use 8/10 gaps.
      final bar = arenaChat.substring(
          arenaChat.indexOf('class ArenaChatInputBar'));
      expect(bar, contains('SizedBox(width: kComposerIconGap)'));
      expect(bar, contains('SizedBox(width: kComposerIconEdgeGap)'));
      expect(bar, contains('SizedBox(width: kComposerSendGap)'));
      // No leftover hardcoded composer gaps.
      expect(bar, isNot(contains('SizedBox(width: 8)')));
      expect(bar, isNot(contains('SizedBox(width: 10)')));
    });

    test('icons + send button unchanged (only the gaps shrank)', () {
      final bar = arenaChat.substring(
          arenaChat.indexOf('class ArenaChatInputBar'));
      expect(bar, contains('Icons.emoji_emotions_outlined'));
      expect(bar, contains('size: 22'));
      expect(bar, contains('width: 48,'));
      expect(bar, contains('height: 48,'));
      expect(bar, contains('Icons.send'));
    });

    testWidgets('composer renders the tightened gaps, icons intact',
        (tester) async {
      final ctrl = TextEditingController();
      addTearDown(ctrl.dispose);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ArenaChatInputBar(
            controller: ctrl,
            onSend: () {},
            onEmoji: () {},
            onAttach: () {},
          ),
        ),
      ));
      await tester.pump();
      // The 4px emoji ↔ attach gap, exactly once.
      expect(
          find.byWidgetPredicate(
              (w) => w is SizedBox && w.width == kComposerIconGap),
          findsOneWidget);
      // Two 6px gaps: attach ↔ pill edge + pill ↔ send button.
      expect(
          find.byWidgetPredicate(
              (w) => w is SizedBox && w.width == kComposerSendGap),
          findsNWidgets(2));
      // Icons + send button all present, unchanged.
      expect(find.byIcon(Icons.emoji_emotions_outlined), findsOneWidget);
      expect(find.byIcon(Icons.add_circle_outline), findsOneWidget);
      expect(find.byIcon(Icons.send), findsOneWidget);
      expect(
          find.byWidgetPredicate((w) =>
              w is Container &&
              w.constraints?.maxWidth == 48 &&
              w.constraints?.maxHeight == 48),
          findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
