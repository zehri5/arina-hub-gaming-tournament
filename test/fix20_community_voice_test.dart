// FIX 20 (2026-11-23, user order from v2019 phone screenshots) —
// COMMUNITY VOICE CHAT screen + RJ Studio console + Watch Live, 20 fixes:
//   1. The description + JOINED/FOLLOW strip is GONE from the chat
//      screen (description still in the More-menu About sheet;
//      Follow/Unfollow moved into the More menu, same
//      _toggleFollow logic; creator still sees a disabled JOINED
//      entry there, no CREATOR label anywhere).
//      FIX 23 SUPERSEDES the More-menu home (items 1+9): the top
//      bar + More menu are gone; Follow lives in the sidebar's
//      Followers spot, visible to every user.
//   2. The "N members + Invite" row below the 6 mic seats is GONE.
//   3. Invite moved INTO the More (⋮) menu — the existing
//      _inviteFromChat (moved to the detail page state, same body,
//      no duplication), reached via _onHeaderMore 'invite'.
//      FIX 23 SUPERSEDES the More-menu home (item 4): Invite
//      lives in the merged community Settings sheet now.
//   4. The member count shows UNDER the voice-room Connecting
//      pill ("N members", small muted text) — plumbed through a
//      new UnifiedRoomPage.memberCount param (community scope
//      only; null shows nothing, never a fake number). The
//      pill's 4-state logic is UNTOUCHED.
//      FIX 23 SUPERSEDES this (item 12b): the members line is
//      GONE ("Members" must not appear in the room); the count
//      moved to the sidebar Followers entry (real community
//      count, same source as the list).
//   5. Chat clear leaves NOTHING behind — the marker message
//      insert is deleted from clearCommunityChat (the toast still
//      confirms the clear). Single-message delete already removes
//      the row (deleted_at rows are filtered, no placeholder).
//   6. The "LIVE • N Online" presence strip is GONE (call site +
//      LiveMembersStrip class + dead presence helpers removed;
//      the detail header's "N Members • M Online" line stays).
//      FIX 23 SUPERSEDES the header line (items 1+12b): the top
//      bar is gone and online presence moved to the Followers
//      list (per-follower online dot).
//   7a. The community voice room had NO way to reach Music / RJ
//      Studio / Settings (the sheet was wired only in TeamChatPage).
//      CommunityDetailPage now owns a VoicePanelController bound
//      to the embedded room, and the More menu gains a Voice
//      Settings entry (visible only while the voice panel is open).
//      FIX 23 SUPERSEDES the More-menu entry (item 4): the voice
//      rows live in the merged community Settings sheet now;
//      the controller bindings stay.
//   7b. RJ Studio was ADMIN-ONLY, so the room host (team captain /
//      community organizer) never saw the RJ row. All four RJ gates
//      now use the room-host check (admin / team captain /
//      community organizer — same parity as music broadcast).
//      Listeners still see no RJ row.
//   8. Mic mute/unmute sometimes dead / hangs: tapping your own
//      seat while not joined returned SILENTLY, and the setMuted
//      awaits had no timeout. Now: an honest toast when not
//      joined, a 2s timeout + generation guard on both setMuted
//      calls, admin-mute guard unchanged, host-button guard
//      unchanged.
//      FIX 23 SUPERSEDES the host-card toast (item 16b): the host
//      mic button is INERT (visibly disabled, no toast) until
//      voice is joined; the seat-tap toast stays.
//   9. GO LIVE / ON AIR works (session-local live state in the
//      room; gated on actually being on voice; END LIVE returns
//      to OFF AIR; timer runs from the start time).
//  10. The RJ panel gear button opens Room Settings (new
//      onSettingsPressed callback; console closes first).
//  11. MIC-fader-linked music ducking: mic ON + fader up -> music
//      down to ~5%; fader down -> music louder; muted -> no
//      ducking; multiplies with the voice-activity ducking.
//  12. RJ panel lag: DSP pushes throttled to 1 per 50ms per
//      control (trailing push carries the exact final value);
//      panel rebuilds throttled the same way; the fader
//      accumulates drags locally like the knob.
//  13. Console bottom cut off: DraggableScrollableSheet owns the
//      scroll gesture now; 28dp + viewInsets bottom padding;
//      tight labels (pads, preset pills, knob labels) scale down.
//  14. Broadcast ON = music didn't play: local playback starts
//      IMMEDIATELY on tap now; upload+announce runs in the
//      background (30s upload timeout, fromToggle semantics).
//  15. "RJ Panel" button in the Music header (hosts only; closes
//      Music first, then opens the RJ Studio console).
//  16. Duplicate song in the library: dedupe by key OR title+size
//      (same file under different path spellings merges into one
//      entry; URL merges in; size persisted).
//  17. Watch Live "stream load nahi ho saka" on a fine video:
//      onWebResourceError now fails the player ONLY for main-frame
//      errors; subresource errors are logged + ignored.
//  18. Watch Live comments kept reloading: the comments stream is
//      created ONCE in initState now (Watch Live + room chat);
//      the community chat already subscribed once.
//  19. Watch Live must start fast on slow data: the IFrame onReady
//      sets 240p ('small') + caps auto quality at 360p ('medium')
//      before playVideo (pinned in fix9_watch_player_test.dart).
//  20. Total views counter on Watch Live: +1 per open via the
//      increment_watch_views RPC (once, guarded, best-effort);
//      the cumulative total shows in the info card ("1.2K total
//      views"), refreshed with the 30s poll; "—" until the
//      backend migration lands (never 0, never fake).
// Gold: #FDC903 (kGold) only — no banned gold in any form.
import 'dart:async';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_auth_platform_interface/firebase_auth_platform_interface.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/community_service.dart';
import 'package:protournament_user/screens/communities_screens.dart';
import 'package:protournament_user/screens/room_screen.dart';
import 'package:protournament_user/services/supabase_db.dart';
import 'package:protournament_user/widgets/voice_settings_sheet.dart';
import 'package:protournament_user/widgets/rj_studio_panel.dart';
import 'package:protournament_user/widgets/music_library_panel.dart';
import 'package:shared_preferences/shared_preferences.dart';

String _read(String path) => File(path).readAsStringSync();

String _region(String src, String from, String to) {
  final start = src.indexOf(from);
  final end = src.indexOf(to, start);
  return src.substring(start, end);
}

/// Banned gold hex fragments, built from char codes so this test
/// file itself contains NO banned literal in any form.
String _banned(List<int> codes) => String.fromCharCodes(codes);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Fake Firebase FIRST (top-level setUpAll, device_ban_gate_test
  // pattern — the fix-4 widget test pumps UnifiedRoomPage, whose
  // services touch FirebaseAuth.instance; without the fakes the
  // real delegate caches and Firebase.initializeApp() hits the
  // native channel).
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    FirebasePlatform.instance = _FakeCorePlatform();
    FirebaseAuthPlatform.instance = _FakeAuthPlatform();
    await Firebase.initializeApp(
      options: const FirebaseOptions(
        apiKey: 'test',
        appId: '1:1:android:1',
        messagingSenderId: '1',
        projectId: 'test',
      ),
    );
    // ignore: unnecessary_statements
    FirebaseAuth.instance;
  });

  late String communityScreens;
  late String roomScreen;
  late String communityService;
  late String rjPanel;
  late String musicPanel;
  late String watchLive;
  late String supaDb;
  late String voiceSheet;

  setUpAll(() {
    communityScreens = _read('lib/screens/communities_screens.dart');
    roomScreen = _read('lib/screens/room_screen.dart');
    communityService = _read('lib/community_service.dart');
    rjPanel = _read('lib/widgets/rj_studio_panel.dart');
    musicPanel = _read('lib/widgets/music_library_panel.dart');
    watchLive = _read('lib/screens/watch_live_screen.dart');
    supaDb = _read('lib/services/supabase_db.dart');
    voiceSheet = _read('lib/widgets/voice_settings_sheet.dart');
  });

  group('Fix 20 — fix 1: description + JOINED/FOLLOW strip gone', () {
    test('strip button + wiring are gone from the detail state', () {
      final detail = _region(communityScreens,
          'class _CommunityDetailPageState', 'class _FollowToInteractBanner');
      expect(detail, isNot(contains("label: _isMember ? 'JOINED' : 'FOLLOW'")));
      expect(detail,
          isNot(contains('onPressed: _isCreator ? null : _toggleFollow')));
      // No CREATOR label anywhere in the detail state (G3 invariant).
      expect(detail, isNot(contains("'CREATOR'")));
    });

    test('Follow/Unfollow lives in the sidebar Followers spot (FIX 23 item 9)',
        () {
      // FIX 23 items 1+9 SUPERSEDE the More-menu home: the top bar
      // + More menu are gone; Follow moved to the sidebar's FIRST
      // entry (Followers), visible to every user.
      expect(communityScreens, isNot(contains('_onHeaderMore')));
      expect(roomScreen, contains('_buildSidebarFollowPill'));
      expect(roomScreen, contains('onSidebarFollowToggle'));
      final pill = _region(roomScreen, 'Widget _buildSidebarFollowPill()',
          'Widget _buildEmbeddedSidebar()');
      // Creator (following == null) sees gold JOINED, no tap;
      // others see Follow / Following.
      expect(pill, contains("Text('JOINED',"));
      expect(pill,
          contains("child: Text(following ? 'Following' : 'Follow',"));
      // _toggleFollow logic itself unchanged.
      final detail = _region(communityScreens,
          'class _CommunityDetailPageState', 'class _FollowToInteractBanner');
      final toggle = _region(detail,
          'Future<void> _toggleFollow() async {', 'Future<void> _delete()');
      expect(toggle, contains('CommunityGroups.unfollowCommunity'));
      expect(toggle, contains('CommunityGroups.followCommunity'));
      expect(toggle, contains('await _init()'));
    });
  });

  group('Fix 20 — fix 2: members + Invite row gone', () {
    test('chat tab has no members/Invite row and no invite call', () {
      final chatTab = _region(communityScreens,
          'class _CommunityChatTabState',
          '// ------------------------------------------------------------------\n// MEMBERS TAB');
      expect(chatTab, isNot(contains("'Invite'")));
      expect(chatTab, isNot(contains('_inviteFromChat')));
      expect(
          chatTab,
          isNot(contains(
              r"'${widget.memberCount} member${widget.memberCount == 1 ? '' : 's'}'")));
      expect(chatTab, isNot(contains('OutlinedButton.icon')));
    });
  });

  group('Fix 20 — fix 3: Invite inside the More menu', () {
    test('Invite lives in the community Settings sheet (FIX 23 item 4)', () {
      // FIX 23 item 4 SUPERSEDES the More-menu home: the More menu
      // is gone; Invite moved into the merged community Settings
      // sheet, wired to the same _inviteFromChat.
      expect(communityScreens, isNot(contains('_onHeaderMore')));
      expect(voiceSheet, contains("title: 'Invite',"));
      expect(communityScreens,
          contains('onInvite: () => unawaited(_inviteFromChat())'));
    });

    test('_inviteFromChat exists exactly once, same body (no duplicate)',
        () {
      final defs = 'Future<void> _inviteFromChat() async {'
          .allMatches(communityScreens)
          .length;
      expect(defs, 1);
      final fn = _region(communityScreens,
          'Future<void> _inviteFromChat() async {', 'Future<void> _delete()');
      expect(fn, contains('SupaDb.getMyFirstTeam(widget.uid)'));
      expect(fn, contains('showChatTeamInviteDialog'));
      expect(fn, contains("toast(context, 'Invitation bhej di!')"));
    });
  });

  group('Fix 20 — fix 4: member count under the pill', () {
    test('memberCount param is GONE — sidebar shows the real community count (FIX 23 item 12)', () {
      // FIX 23 item 12b SUPERSEDES the pill count: the word
      // "Members" must not appear in the room; the count moved to
      // the sidebar Followers entry (real community count, same
      // source as the list).
      expect(roomScreen, isNot(contains('final int? memberCount;')));
      expect(roomScreen, isNot(contains('this.memberCount,')));
      expect(roomScreen, isNot(contains('hostCardTotalMembers')));
      expect(roomScreen, isNot(contains('hostCardOnlineMembers')));
      expect(roomScreen, contains('sidebarCommunityCount'));
    });

    test('pill has no members line; 4-state logic untouched', () {
      final pill = _region(roomScreen, 'Widget _buildConnectingPill()',
          'List<Widget> _buildRequestBanners()');
      // The fix20 members line is gone (only a comment explains
      // the removal now — no code renders it).
      expect(pill, isNot(contains('widget.memberCount')));
      expect(pill, isNot(contains('showMembers')));
      expect(
          pill,
          isNot(contains(
              r"'$count member${count == 1 ? '' : 's'}'")));
      // The four honest states are still all there.
      expect(pill, contains("'Voice On'"));
      expect(pill, contains("'Voice Failed'"));
      expect(pill, contains("'Connecting…'"));
      expect(pill, contains("'Not connected'"));
    });

    test('community mount passes the fresh community count to the sidebar', () {
      expect(communityScreens, contains('sidebarCommunityCount:'));
      expect(communityScreens, contains('_memberCountFresh'));
      expect(communityScreens,
          isNot(contains("memberCount: SupaDb.intOf(_community['memberCount'])")));
    });
  });

  group('Fix 20 — fix 5: clear leaves nothing behind', () {
    test('no marker string anywhere in community_service.dart', () {
      expect(communityService, isNot(contains('clear kar di gayi')));
    });

    test('clearCommunityChat deletes but never sends a message', () {
      final clear = _region(communityService,
          'static Future<Map<String, dynamic>> clearCommunityChat(',
          '/// Member UIDs only');
      expect(clear, contains('deleteChatMessagesByIds'));
      expect(clear, isNot(contains('sendCommunityChatMessage')));
    });

    test('clear leaves zero community rows (fixtures, no marker)', () async {
      SupaDb.testFixtures = {
        'communities': [
          {
            'id': 'comm-a',
            'name': 'Alpha',
            'created_by_uid': 'u-org-a',
            'voice_enabled': true,
          },
          {
            'id': 'comm-b',
            'name': 'Beta',
            'created_by_uid': 'u-org-b',
            'voice_enabled': true,
          },
        ],
        'community_members': [
          {
            'community_id': 'comm-a',
            'firebase_uid': 'u-org-a',
            'role': 'creator'
          },
          {
            'community_id': 'comm-a',
            'firebase_uid': 'u-mem',
            'role': 'member'
          },
          {
            'community_id': 'comm-b',
            'firebase_uid': 'u-org-b',
            'role': 'creator'
          },
        ],
        'chat_messages': [
          {
            'id': 'm1',
            'scope': 'community',
            'community_id': 'comm-a',
            'firebase_uid': 'u-mem',
            'message': 'hello A',
          },
          {
            'id': 'm2',
            'scope': 'community',
            'community_id': 'comm-a',
            'firebase_uid': 'u-org-a',
            'message': 'hi A',
          },
          {
            'id': 'm3',
            'scope': 'community',
            'community_id': 'comm-b',
            'firebase_uid': 'u-mem',
            'message': 'hello B',
          },
        ],
      };
      try {
        final res = await CommunityGroups.clearCommunityChat(
            communityId: 'comm-a',
            requesterUid: 'u-org-a',
            requesterName: 'Org A');
        expect(res['ok'], isTrue);
        expect(res['deleted'], 2);
        final msgs = SupaDb.testFixtures!['chat_messages']!;
        // Only comm-b's message survives — NO marker row was added
        // for comm-a (a marker would be a comm-a row).
        expect(msgs.length, 1);
        expect(msgs.first['id'], 'm3');
        expect(msgs.where((m) => m['community_id'] == 'comm-a'), isEmpty);
      } finally {
        SupaDb.testFixtures = null;
      }
    });
  });

  group('Fix 20 — fix 6: LIVE presence strip gone', () {
    test('strip class + helper + call site are all deleted', () {
      expect(communityScreens,
          isNot(contains('class LiveMembersStrip extends StatelessWidget')));
      expect(communityScreens,
          isNot(contains('class CommunityLiveMember {')));
      expect(communityScreens,
          isNot(contains('List<CommunityLiveMember> onlineCommunityMembers({')));
      expect(communityScreens,
          isNot(contains('LiveMembersStrip(members: _liveMembers)')));
      final chatTab = _region(communityScreens,
          'class _CommunityChatTabState',
          '// ------------------------------------------------------------------\n// MEMBERS TAB');
      expect(chatTab, isNot(contains('_refreshLiveMembers')));
      expect(chatTab, isNot(contains('_loadLiveMembers')));
      expect(chatTab, isNot(contains('_presenceTimer')));
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

  group('Fix 20 — gold: #FDC903 only in changed files', () {
    test('no banned gold fragment in lib or this test file', () {
      final banned = [
        _banned([70, 70, 67, 56, 48, 48]),
        _banned([70, 53, 65, 57, 48, 48]),
        _banned([70, 70, 67, 67, 48, 48]),
        _banned([70, 70, 69, 50, 48, 65]),
      ];
      final mine = _read('test/fix20_community_voice_test.dart');
      for (final b in banned) {
        expect(communityScreens, isNot(contains(b)));
        expect(roomScreen, isNot(contains(b)));
        expect(communityService, isNot(contains(b)));
        expect(rjPanel, isNot(contains(b)));
        expect(musicPanel, isNot(contains(b)));
        expect(watchLive, isNot(contains(b)));
        expect(supaDb, isNot(contains(b)));
        expect(mine, isNot(contains(b)));
      }
    });
  });

  group('Fix 20 — widget: detail page (fixes 1, 2, 3, 6)', () {
    setUp(() async {
      // FIX 23 item 16a: the detail page mounts the voice panel
      // ALWAYS for members, so VoiceRoom is constructed at pump
      // time — and its constructor reads
      // FirebaseAuth.instance.currentUser!.uid. Without a signed-in
      // user the pump throws a TypeError before any assert runs.
      await FirebaseAuth.instance.signOut();
      await FirebaseAuth.instance
          .signInWithEmailAndPassword(email: 'a@b.c', password: 'x');
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
          {
            'id': 'comm-2',
            'name': 'Pro Gamers',
            'description': '',
            'photo_url': '',
            'is_public': true,
            'created_by_uid': 'other-uid',
            'created_at': '2026-11-22T18:00:00Z',
          },
          {
            'id': 'comm-3',
            'name': 'Night Owls',
            'description': 'late night squad',
            'photo_url': '',
            'is_public': true,
            'created_by_uid': 'other-uid',
            'created_at': '2026-11-22T17:00:00Z',
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
          {
            'community_id': 'comm-3',
            'firebase_uid': 'test-uid',
            'role': 'member'
          },
          {
            'community_id': 'comm-3',
            'firebase_uid': 'other-uid',
            'role': 'creator'
          },
        ],
        'profiles': [
          {
            'firebase_uid': 'test-uid',
            'display_name': 'Tester',
            'username': 'tester'
          },
        ],
        'community_posts': [],
        'community_voice_requests': [],
      };
    });
    tearDown(() {
      SupaDb.testFixtures = null;
    });

    Map<String, dynamic> community(String id, String name, String desc,
        {required bool isMember, required String myRole}) {
      return {
        'id': id,
        'name': name,
        'description': desc,
        'photo_url': '',
        'is_public': true,
        'created_by_uid': id == 'comm-1' ? 'test-uid' : 'other-uid',
        'created_at': '2026-11-22T19:39:32Z',
        'isMember': isMember,
        'myRole': myRole,
      };
    }

    Future<void> pumpDetail(WidgetTester tester,
        Map<String, dynamic> comm) async {
      // Tall viewport: FIX 23 item 16a mounts the voice panel
      // ALWAYS for members, so the detail page + panel overflow
      // the default 600px height (G6 pattern — same as the fix-7a
      // group below).
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(
          home: CommunityDetailPage(
              uid: 'test-uid',
              communityId: comm['id'] as String,
              community: comm)));
      await tester.pump();
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      // Flush the DSP ping + its one retry (2s + 2s, fix21 item 2)
      // and the mount toast's 4s snackbar timer: the room's
      // initState installs the mic-noise processor, and a pending
      // ping timer fails the post-test invariant check if the test
      // ends first (members-group pattern).
      await tester.pump(const Duration(seconds: 5));
    }

    Future<void> openSettings(WidgetTester tester) async {
      await tester.tap(find.text('Settings'));
      await tester.pump();
      // Let the sheet entrance finish before asserting on it
      // (G4 pattern — a t=0 sheet swallows the first pump).
      await tester.pump(const Duration(milliseconds: 300));
    }

    testWidgets('strip + row + LIVE strip all gone from the chat screen',
        (tester) async {
      await pumpDetail(
          tester,
          community('comm-1', 'Meri Kahani', 'testing',
              isMember: true, myRole: 'creator'));
      // Fix 1: the description strip is gone — but the description
      // itself lives on as the host card's tagline (FIX 23 item 2:
      // the card keeps the real tagline). It renders exactly once,
      // italic, in the card — not as a strip on the chat screen.
      expect(find.text('testing'), findsOneWidget);
      // FIX 23 item 9: the creator sees JOINED in the sidebar
      // Follow pill immediately (no menu to open any more).
      expect(find.text('JOINED'), findsOneWidget);
      // Fix 2: no Invite button on the screen (row gone — Invite
      // lives in Settings now, FIX 23 item 4).
      expect(find.text('Invite'), findsNothing);
      // Fix 6: no LIVE presence strip.
      expect(find.text('LIVE'), findsNothing);
      expect(find.text('1 Online'), findsNothing);
      // FIX 23 item 1: the top bar is gone — no AppBar, no More.
      expect(find.byType(AppBar), findsNothing);
      expect(find.text('More'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('creator opens Settings: JOINED status + Invite there',
        (tester) async {
      await pumpDetail(
          tester,
          community('comm-1', 'Meri Kahani', 'testing',
              isMember: true, myRole: 'creator'));
      await openSettings(tester);
      // JOINED twice: the sidebar pill + the sheet's status line.
      expect(find.text('JOINED'), findsNWidgets(2));
      expect(find.text('Invite'), findsOneWidget);
      expect(find.text('CREATOR'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('member opens Settings: Following pill + Invite there',
        (tester) async {
      await pumpDetail(
          tester,
          community('comm-3', 'Night Owls', 'late night squad',
              isMember: true, myRole: 'member'));
      // FIX 23 item 9: the sidebar pill says Following (the old
      // More-menu 'Unfollow' text is gone).
      expect(find.text('Following'), findsOneWidget);
      expect(find.text('Unfollow'), findsNothing);
      await openSettings(tester);
      // JOINED once: the sheet's status line only (the sidebar
      // pill says Following for a member).
      expect(find.text('JOINED'), findsOneWidget);
      expect(find.text('Invite'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('non-member sees the Follow-to-join banner, no panel',
        (tester) async {
      await pumpDetail(
          tester,
          community('comm-2', 'Pro Gamers', '',
              isMember: false, myRole: ''));
      // FIX 23 item 16a: non-members get no voice panel (no
      // sidebar, no Settings) — the chat shows the Follow-to-join
      // banner. Follow itself lives on the community card
      // (FIX 23 item 19, pinned in fix23_community_chat_test).
      expect(find.text('Chat karne ke liye pehle Follow karen.'),
          findsOneWidget);
      expect(find.byType(UnifiedRoomPage), findsNothing);
      expect(find.text('Settings'), findsNothing);
      expect(find.text('More'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('Fix 20 — widget: members text under the pill (fix 4)', () {
    setUp(() async {
      await FirebaseAuth.instance.signInWithEmailAndPassword(
          email: 't@t.com', password: 'password');
      SupaDb.testFixtures = {
        'communities': [
          {
            'id': 'comm-1',
            'name': 'Meri Kahani',
            'description': 'testing',
            'photo_url': '',
            'is_public': true,
            'created_by_uid': 'test-uid',
            'voice_enabled': true,
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
            'firebase_uid': 'u2',
            'role': 'member'
          },
          {
            'community_id': 'comm-1',
            'firebase_uid': 'u3',
            'role': 'member'
          },
        ],
        'profiles': [],
        'chat_messages': [],
        'app_settings': [],
      };
    });
    tearDown(() async {
      SupaDb.testFixtures = null;
      await FirebaseAuth.instance.signOut();
    });

    Future<void> pumpRoom(WidgetTester tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: UnifiedRoomPage(
            scope: 'community',
            communityId: 'comm-1',
            communityName: 'Meri Kahani',
            organizerUid: 'test-uid',
            micCount: 6,
            embedded: true,
          ),
        ),
      ));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      // Flush the mount toast's 4s snackbar timer: the room shows
      // a toast while joining, and a pending snackbar timer fails
      // the post-test invariant check if the test ends first.
      await tester.pump(const Duration(seconds: 5));
    }

    testWidgets('community scope: NO members text anywhere (FIX 23 item 12b)',
        (tester) async {
      await pumpRoom(tester);
      // FIX 23 item 12b SUPERSEDES the fix20 members line: the
      // word "Members" must not appear in the room at all.
      expect(find.text('3 members'), findsNothing);
      expect(find.textContaining('members'), findsNothing);
      expect(find.textContaining('Members'), findsNothing);
      // The pill itself is still there (idle = Not connected).
      expect(find.text('Not connected'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('community scope, no count: no members text, no fake number',
        (tester) async {
      await pumpRoom(tester);
      expect(find.text('3 members'), findsNothing);
      expect(find.textContaining('members'), findsNothing);
      expect(find.text('Not connected'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('Fix 20 — fix 7a: settings sheet wired into the community page (source)',
      () {
    late String communityScreens;

    setUpAll(() {
      communityScreens = _read('lib/screens/communities_screens.dart');
    });

    test('detail page imports the sheet + owns a VoicePanelController', () {
      expect(communityScreens,
          contains("import '../widgets/voice_settings_sheet.dart';"));
      final detail = _region(communityScreens,
          'class _CommunityDetailPageState', 'class _FollowToInteractBanner');
      expect(detail,
          contains('final _voiceController = VoicePanelController();'));
      expect(detail, contains('_voiceController.dispose();'));
    });

    test('controller binds to the community mount; Settings sheet opens the voice rows (FIX 23 item 4)',
        () {
      final detail = _region(communityScreens,
          'class _CommunityDetailPageState', 'class _FollowToInteractBanner');
      expect(detail, contains('voiceController: _voiceController'));
      // FIX 23 item 4 SUPERSEDES the More-menu Voice Settings
      // entry: the panel is always mounted for members (no
      // _voicePanelOpen gate any more) and the sidebar Settings
      // opens the merged community Settings sheet.
      expect(detail, isNot(contains('_voicePanelOpen')));
      expect(detail, contains('onSidebarSettings: () => showCommunitySettingsSheet('));
      expect(detail, isNot(contains("value: 'voice_settings'")));
    });

    test('About lives in the Settings sheet untouched (FIX 23 item 4)', () {
      final detail = _region(communityScreens,
          'class _CommunityDetailPageState', 'class _FollowToInteractBanner');
      expect(detail, isNot(contains("value: 'about'")));
      expect(detail, contains('Future<void> _showAbout() async {'));
      expect(detail, contains('onAbout: () => unawaited(_showAbout())'));
      final sheet = _read('lib/widgets/voice_settings_sheet.dart');
      expect(sheet, contains("title: 'About',"));
    });
  });

  group('Fix 20 — fix 7b: RJ is for the room host (source)', () {
    late String room;
    late String sheet;

    setUpAll(() {
      room = _read('lib/screens/room_screen.dart');
      sheet = _read('lib/widgets/voice_settings_sheet.dart');
    });

    test('all four RJ gates use the extended host check', () {
      // (1) the voice-controller binding.
      expect(
          room,
          contains(
              'rjVisible: () =>\n          _isAdminForBroadcast ||\n          _isTeamCaptainForBroadcast ||\n          _isCommunityOrganizerForBroadcast,'));
      // (2) the console's gate — FIX 22 item 6: the silent
      // early return is GONE. The gate is the shared
      // _rjHostGatePasses getter; a blocked open waits for the
      // identity load (bounded 3 s) and then says WHY with an
      // honest toast, never silence.
      expect(
          room,
          contains(
              'bool get _rjHostGatePasses =>\n      _isAdminForBroadcast ||\n      _isTeamCaptainForBroadcast ||\n      _isCommunityOrganizerForBroadcast;'));
      expect(room, contains('if (!_rjHostGatePasses) {'));
      expect(
          room,
          contains(
              'await adminLoad.timeout(const Duration(seconds: 3));'));
      expect(
          room,
          contains(
              "'Pehchan load ho rahi hai — thora ruk kar dobara koshish karein.'"));
      expect(room, contains("'RJ panel sirf room host ke liye hai.'"));
      // (3) the nav-rail button.
      expect(
          room,
          contains(
              'if (_isAdminForBroadcast ||\n              _isTeamCaptainForBroadcast ||\n              _isCommunityOrganizerForBroadcast) ...['));
      // (4) the panel's isHost prop.
      expect(
          room,
          contains(
              'isHost: _isAdminForBroadcast ||\n                                _isTeamCaptainForBroadcast ||\n                                _isCommunityOrganizerForBroadcast,'));
      // No RJ gate is admin-only any more.
      expect(room, isNot(contains('rjVisible: () => _isAdminForBroadcast,')));
      expect(room, isNot(contains('if (!_isAdminForBroadcast) return;')));
    });

    test('stale "broadcast admin" comments are gone', () {
      expect(sheet, isNot(contains('broadcast admins only')));
      expect(sheet, isNot(contains('broadcast admin only')));
      expect(sheet, contains('room host only'));
    });

    test('music broadcast logic is untouched', () {
      expect(
          room,
          contains(
              'bool get _canBroadcastMusic => _isAdminForBroadcast || _isTeamCaptainForBroadcast || _isCommunityOrganizerForBroadcast || _musicApproved;'));
      expect(
          room,
          contains(
              'isHost: _isAdminForBroadcast || _isTeamCaptainForBroadcast || _isCommunityOrganizerForBroadcast,'));
    });
  });

  group('Fix 20 — fix 8: seat mute never dead, never hangs (source)', () {
    late String room;

    setUpAll(() {
      room = _read('lib/screens/room_screen.dart');
    });

    String toggle() => _region(room, 'Future<void> _toggleOwnSeat() async {',
        '/// FIX 16 (user order 2026-11-23): the Connecting / Voice On');

    test('not-joined tap shows an honest toast — no silent return', () {
      final fn = toggle();
      expect(
          fn,
          contains(
              "toast(context, 'Voice connected nahi hai — pehle connect karein')"));
      expect(fn, contains('if (!_room.joined) {'));
      // The old silent return is gone: the not-joined branch
      // contains the toast before its return.
      final branch = fn.substring(fn.indexOf('if (!_room.joined) {'));
      expect(branch.indexOf('toast(context'), lessThan(branch.indexOf('return;')));
    });

    test('both setMuted awaits have a 2s timeout + generation guard', () {
      final fn = toggle();
      expect('_seatToggleGen'.allMatches(fn).length, greaterThanOrEqualTo(4));
      expect(fn, contains('final gen = ++_seatToggleGen;'));
      expect('.timeout(const Duration(seconds: 2))'.allMatches(fn).length, 2);
      expect(fn, contains('on TimeoutException'));
      expect(
          fn,
          contains(
              "toast(context, 'Mic respond nahi kar raha, dobara try karein')"));
      expect(fn, contains('if (mounted && gen == _seatToggleGen)'));
    });

    test('admin-mute guard + host-button guard are unchanged', () {
      final fn = toggle();
      expect(
          fn,
          contains(
              "toast(context, 'Admin ne aapka mic band kiya hua hai — unmute sirf admin kar sakta hai.')"));
      // The guard appears in BOTH paths (LiveKit + mesh).
      expect('if (_adminMutedHeld || _adminMicOffHeld)'.allMatches(fn).length,
          2);
      // The host-button guard lives outside _toggleOwnSeat.
      expect(room, contains('if (!hostOnVoice) {'));
      expect(room,
          contains("toast(context, 'Host is not on voice right now.')"));
    });
  });

  group('Fix 20 — widget: community More menu gains Voice Settings (fix 7a)',
      () {
    setUpAll(() async {
      SharedPreferences.setMockInitialValues({});
    });

    setUp(() async {
      await FirebaseAuth.instance.signOut();
      await FirebaseAuth.instance
          .signInWithEmailAndPassword(email: 'a@b.c', password: 'x');
      SupaDb.testFixtures = {
        'teams': [],
        'team_members': [],
        'team_invitations': [],
        'communities': [
          {
            'id': 'comm-1',
            'name': 'Meri Kahani',
            'description': 'testing',
            'photo_url': '',
            'is_public': true,
            'created_by_uid': 'test-uid',
            'voice_enabled': true,
            'created_at': '2026-11-22T19:39:32Z',
          },
        ],
        'community_members': [
          {
            'community_id': 'comm-1',
            'firebase_uid': 'test-uid',
            'role': 'creator'
          },
        ],
        'community_posts': [],
        'community_voice_requests': [],
        'chat_messages': [],
        'admin_config': [],
        'app_settings': [],
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

    Map<String, dynamic> community() => {
          'id': 'comm-1',
          'name': 'Meri Kahani',
          'description': 'testing',
          'photoUrl': '',
          'isPublic': true,
          'created_by_uid': 'test-uid',
          'voice_enabled': true,
          'created_at': '2026-11-22T19:39:32Z',
          'isMember': true,
          'myRole': 'creator',
          'memberCount': 3,
        };

    Future<void> pumpDetail(WidgetTester tester) async {
      // Tall viewport: detail page + open voice panel overflow the
      // default 600px height (G6 pattern).
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: CommunityDetailPage(
              community: community(), uid: 'test-uid', communityId: 'comm-1'),
        ),
      ));
      for (var i = 0; i < 8; i++) {
        // 4s: flushes the join-time delayed re-asserts + the
        // mount toast's snackbar timer (see the members group).
        await tester.pump(const Duration(milliseconds: 500));
      }
    }

    Future<void> openSettings(WidgetTester tester) async {
      await tester.tap(find.text('Settings'));
      await tester.pump();
      // Let the sheet entrance finish before asserting on it
      // (G4 pattern — a t=0 sheet swallows the first pump).
      await tester.pump(const Duration(milliseconds: 300));
    }

    testWidgets('Settings sheet shows the voice rows + About (FIX 23 item 4)',
        (tester) async {
      await pumpDetail(tester);
      // FIX 23 items 1+4+16a SUPERSEDE the More-menu flow: there
      // is no More menu and no "panel closed" state — the panel
      // is always mounted for members and the sidebar Settings
      // opens the merged community Settings sheet.
      expect(find.text('More'), findsNothing);
      expect(find.text('Not connected'), findsOneWidget);
      await openSettings(tester);
      final sheet = find.byType(CommunitySettingsSheet);
      expect(sheet, findsOneWidget);
      expect(find.descendant(of: sheet, matching: find.text('About')),
          findsOneWidget);
      expect(find.descendant(of: sheet, matching: find.text('Backgrounds')),
          findsOneWidget);
      expect(
          find.descendant(
              of: sheet, matching: find.text('Voice test (LiveKit)')),
          findsOneWidget);
      expect(find.descendant(of: sheet, matching: find.text('Cheer (Free Points)')),
          findsOneWidget);
      // No Speaker toggle (fix22 item 7 — speaker permanently ON)
      // and no Follow (that lives in the sidebar, item 9).
      expect(find.descendant(of: sheet, matching: find.text('Speaker')),
          findsNothing);
      expect(find.descendant(of: sheet, matching: find.text('Follow')),
          findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Settings sheet has Music + RJ Studio, no Close voice (FIX 23 item 4)',
        (tester) async {
      await pumpDetail(tester);
      // The voice panel mounted (the pill shows).
      expect(find.text('Not connected'), findsOneWidget);
      await openSettings(tester);
      // The COMMUNITY sheet (not the fix16 team sheet): the voice
      // rows are flattened in, there is no Room Settings sub-row
      // and no Close voice (the host card is sticky, item 16a).
      final sheet = find.byType(CommunitySettingsSheet);
      expect(sheet, findsOneWidget);
      expect(find.byType(VoiceSettingsSheet), findsNothing);
      expect(find.descendant(of: sheet, matching: find.text('Music')),
          findsOneWidget);
      expect(find.descendant(of: sheet, matching: find.text('Room Settings')),
          findsNothing);
      expect(find.descendant(of: sheet, matching: find.text('Close voice')),
          findsNothing);
      // The creator IS the community organizer (room host) — the
      // RJ row shows for them (fix 7b).
      expect(find.descendant(of: sheet, matching: find.text('RJ Studio')),
          findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('Fix 20 — widget: RJ row host parity (fix 7b)', () {
    setUpAll(() async {
      SharedPreferences.setMockInitialValues({});
    });

    setUp(() async {
      await FirebaseAuth.instance.signOut();
      await FirebaseAuth.instance
          .signInWithEmailAndPassword(email: 'a@b.c', password: 'x');
    });
    tearDown(() {
      SupaDb.testFixtures = null;
    });

    Map<String, List<Map<String, dynamic>>> teamFixtures({
      required String captainUid,
      List<Map<String, dynamic>> adminConfig = const [],
    }) =>
        {
          'teams': [
            {
              'id': 'team-1',
              'name': 'Team Ninja',
              'created_by_uid': captainUid,
            },
          ],
          'team_members': <Map<String, dynamic>>[],
          'admin_config': adminConfig,
          'chat_messages': <Map<String, dynamic>>[],
          'app_settings': <Map<String, dynamic>>[],
          'profiles': [
            {
              'firebase_uid': 'test-uid',
              'display_name': 'Tester',
              'username': 'tester'
            },
          ],
        };

    Future<VoicePanelController> pumpRoom(
      WidgetTester tester, {
      required String scope,
      String teamId = '',
      String teamName = '',
      String captainUid = '',
      String communityId = '',
      String communityName = '',
      String organizerUid = '',
    }) async {
      final controller = VoicePanelController();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: UnifiedRoomPage(
            scope: scope,
            teamId: teamId,
            teamName: teamName,
            captainUid: captainUid,
            communityId: communityId,
            communityName: communityName,
            organizerUid: organizerUid,
            micCount: 6,
            embedded: true,
            voiceController: controller,
          ),
        ),
      ));
      for (var i = 0; i < 8; i++) {
        // 4 s total: the join's delayed re-asserts (LiveKit 700ms
        // speaker re-assert, mesh 1s — FIX 22 item 7 fires the
        // speaker preference at join now) must finish inside the
        // test, or a pending timer fails the post-test check.
        await tester.pump(const Duration(milliseconds: 500));
      }
      return controller;
    }

    Future<void> openSheet(
        WidgetTester tester, VoicePanelController controller) async {
      final ctx = tester.element(find.byType(UnifiedRoomPage));
      unawaited(showVoiceSettingsSheet(ctx, controller));
      await tester.pump();
      // 5s: flushes the mount toast's 4s snackbar timer, so no
      // timer is still pending when the test ends (the post-test
      // invariant check fails on a pending snackbar timer).
      await tester.pump(const Duration(seconds: 5));
    }

    testWidgets('plain listener: sheet has NO RJ Studio row',
        (tester) async {
      SupaDb.testFixtures = teamFixtures(captainUid: 'other-uid');
      final controller = await pumpRoom(tester,
          scope: 'team', teamId: 'team-1', teamName: 'Team Ninja', captainUid: 'other-uid');
      await openSheet(tester, controller);
      // FIX 22 item 15: the sidebar also has a Music entry — the
      // sheet's rows are scoped to the sheet.
      final sheet = find.byType(VoiceSettingsSheet);
      expect(sheet, findsOneWidget);
      expect(find.descendant(of: sheet, matching: find.text('Music')),
          findsOneWidget);
      expect(find.descendant(of: sheet, matching: find.text('Room Settings')),
          findsOneWidget);
      expect(find.descendant(of: sheet, matching: find.text('Close voice')),
          findsOneWidget);
      expect(find.text('RJ Studio'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('team captain: RJ row visible, tap opens the console',
        (tester) async {
      SupaDb.testFixtures = teamFixtures(captainUid: 'test-uid');
      final controller = await pumpRoom(tester,
          scope: 'team', teamId: 'team-1', teamName: 'Team Ninja', captainUid: 'test-uid');
      await openSheet(tester, controller);
      expect(find.text('RJ Studio'), findsOneWidget);
      await tester.tap(find.text('RJ Studio'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      // FIX 22 item 6: the panel builds even with dsp == null
      // (no native DSP in this test), so 'RJ STUDIO' appears
      // TWICE — the console sheet header (17px) + the panel's
      // own title (26px gold). Before item 6 the panel never
      // built here and only the header showed.
      expect(find.text('RJ STUDIO'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    });

    testWidgets('community organizer: RJ row visible', (tester) async {
      SupaDb.testFixtures = {
        'teams': [],
        'team_members': [],
        'admin_config': [],
        'communities': [
          {
            'id': 'comm-1',
            'name': 'Meri Kahani',
            'created_by_uid': 'test-uid',
            'voice_enabled': true,
          },
        ],
        'community_members': [],
        'chat_messages': [],
        'app_settings': [],
        'profiles': [
          {
            'firebase_uid': 'test-uid',
            'display_name': 'Tester',
            'username': 'tester'
          },
        ],
      };
      final controller = await pumpRoom(tester,
          scope: 'community',
          communityId: 'comm-1',
          communityName: 'Meri Kahani',
          organizerUid: 'test-uid');
      await openSheet(tester, controller);
      expect(find.text('RJ Studio'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('app admin: RJ row visible', (tester) async {
      SupaDb.testFixtures = teamFixtures(captainUid: 'other-uid',
          adminConfig: [
            {'id': 1, 'admin_firebase_uid': 'test-uid'},
          ]);
      final controller = await pumpRoom(tester,
          scope: 'team', teamId: 'team-1', teamName: 'Team Ninja', captainUid: 'other-uid');
      await openSheet(tester, controller);
      expect(find.text('RJ Studio'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('Fix 20 — widget: host mic guard intact (fix 8)', () {
    setUpAll(() async {
      SharedPreferences.setMockInitialValues({});
    });

    setUp(() async {
      await FirebaseAuth.instance.signOut();
      await FirebaseAuth.instance
          .signInWithEmailAndPassword(email: 'a@b.c', password: 'x');
      SupaDb.testFixtures = {
        'teams': [],
        'team_members': [],
        'admin_config': [],
        'communities': [
          {
            'id': 'comm-1',
            'name': 'Meri Kahani',
            'created_by_uid': 'test-uid',
            'voice_enabled': true,
          },
        ],
        'community_members': [],
        'chat_messages': [],
        'app_settings': [],
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

    testWidgets('host mic tap while not on voice does NOTHING — inert, no toast (FIX 23 item 16b)',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: UnifiedRoomPage(
            scope: 'community',
            communityId: 'comm-1',
            communityName: 'Meri Kahani',
            organizerUid: 'test-uid',
            micCount: 6,
            embedded: true,
          ),
        ),
      ));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(find.text('Not connected'), findsOneWidget);
      // The host mic button is the only 24px mic icon (seat mics
      // are 10px, the Live pill mic is 12px).
      final hostMic = find.byWidgetPredicate((w) =>
          w is Icon &&
          w.size == 24 &&
          (w.icon == Icons.mic || w.icon == Icons.mic_off));
      expect(hostMic, findsOneWidget);
      // Gated: the button is visibly dimmed (an Opacity 0.5
      // ancestor wraps it).
      final opacities = find
          .ancestor(of: hostMic, matching: find.byType(Opacity))
          .evaluate()
          .map((e) => (e.widget as Opacity).opacity);
      expect(opacities, contains(0.5));
      await tester.tap(hostMic);
      await tester.pump();
      // FIX 23 item 16b SUPERSEDES the fix20 toast for the
      // host-card button: inert, no toast. (The seat-tap toast
      // stays for seat taps.)
      expect(find.text('Host is not on voice right now.'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('Fix 20 — fix 9: GO LIVE / ON AIR works (source)', () {
    late String room;

    setUpAll(() {
      room = _read('lib/screens/room_screen.dart');
    });

    String console() => _region(room, 'Future<void> _showRjVoiceConsole(',
        '// FIX 22 item 22: _showMusicSettings is DELETED');

    test('live state lives in the room state (not the sheet)', () {
      expect(room, contains('bool _rjIsLive = false;'));
      expect(room, contains('DateTime? _rjLiveStartedAt;'));
    });

    test('console passes isLive + liveElapsed into the panel', () {
      final c = console();
      expect(c, contains('isLive: _rjIsLive,'));
      expect(c, contains('liveElapsed: liveElapsed,'));
      expect(c, contains('DateTime.now().difference(_rjLiveStartedAt!)'));
    });

    test('GO LIVE is gated on actually being on voice', () {
      final c = console();
      expect(c, contains('if (!_lkRoom.joined && !_room.joined) {'));
      expect(
          c,
          contains(
              "'Pehle voice par connect karein — live tabhi hoga jab aap voice par hon'"));
      expect(c, contains('_rjIsLive = true;'));
      expect(c, contains('_rjLiveStartedAt = DateTime.now();'));
      // The old documented no-op is gone.
      expect(c, isNot(contains('GO LIVE abhi available nahi hai')));
    });

    test('END LIVE clears the state + stops the ticker', () {
      final c = console();
      expect(c, contains('_rjIsLive = false;'));
      expect(c, contains('_rjLiveStartedAt = null;'));
      expect(c, contains('Timer.periodic(const Duration(seconds: 1)'));
      expect(c, contains('liveTicker?.cancel();'));
    });

    test('listener count stays real (LiveListeners)', () {
      final c = console();
      expect(c, contains('listenerCount: _liveListeners.listenerCount'));
      expect(c, contains('listeners: _liveListeners.listeners'));
    });
  });

  group('Fix 20 — fix 10: RJ gear opens Room Settings (source)', () {
    late String panel;
    late String room;

    setUpAll(() {
      panel = _read('lib/widgets/rj_studio_panel.dart');
      room = _read('lib/screens/room_screen.dart');
    });

    test('panel has an onSettingsPressed callback', () {
      expect(panel, contains('this.onSettingsPressed,'));
      expect(panel, contains('final VoidCallback? onSettingsPressed;'));
    });

    test('gear is a real button, not a bare Icon', () {
      final topBar = _region(panel, 'Widget _buildTopBar() {',
          'Widget _buildOnAirSign() {');
      expect(topBar, contains('onTap: widget.onSettingsPressed'));
      expect(topBar, contains('Icon(Icons.settings, color: _kGold, size: 28)'));
      expect(topBar, isNot(contains('const Icon(Icons.settings')));
    });

    test('console wires the gear to Room Settings (close-then-open)', () {
      final c = _region(room, 'Future<void> _showRjVoiceConsole(',
          '// FIX 22 item 22: _showMusicSettings is DELETED');
      expect(c, contains('onSettingsPressed: () {'));
      expect(c, contains('Navigator.of(context).pop();'));
      expect(c, contains('_showRoomSettings();'));
    });
  });

  group('Fix 20 — widget: RJ panel GO LIVE + gear (fixes 9, 10)', () {
    Future<void> pumpPanel(
      WidgetTester tester, {
      bool isLive = false,
      Duration liveElapsed = Duration.zero,
      VoidCallback? onGoLivePressed,
      VoidCallback? onSettingsPressed,
    }) async {
      // Tall viewport: the console is a tall sheet (rj_studio_panel
      // pattern).
      tester.view.physicalSize = const Size(400, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: RjStudioPanel(
              dsp: _FakeRjDsp(),
              isHost: true,
              hostName: 'RJ Sameer',
              isLive: isLive,
              liveElapsed: liveElapsed,
              onGoLivePressed: onGoLivePressed ?? () {},
              onMutePressed: () {},
              onSettingsPressed: onSettingsPressed,
            ),
          ),
        ),
      ));
      await tester.pump();
    }

    testWidgets('OFF AIR + GO LIVE button when not live; tap fires the callback',
        (tester) async {
      var tapped = false;
      await pumpPanel(tester, onGoLivePressed: () => tapped = true);
      expect(find.text('OFF AIR'), findsOneWidget);
      expect(find.text('ON AIR'), findsNothing);
      expect(find.text('GO LIVE'), findsOneWidget);
      expect(find.text('END LIVE'), findsNothing);
      await tester.tap(find.text('GO LIVE'));
      expect(tapped, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('ON AIR + END LIVE + running timer when live',
        (tester) async {
      await pumpPanel(tester,
          isLive: true, liveElapsed: const Duration(seconds: 65));
      expect(find.text('ON AIR'), findsOneWidget);
      expect(find.text('OFF AIR'), findsNothing);
      expect(find.text('END LIVE'), findsOneWidget);
      expect(find.text('GO LIVE'), findsNothing);
      expect(find.text('01:05'), findsOneWidget);
      expect(find.text('REC'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('gear tap fires onSettingsPressed', (tester) async {
      var tapped = false;
      await pumpPanel(tester, onSettingsPressed: () => tapped = true);
      expect(find.byIcon(Icons.settings), findsOneWidget);
      await tester.tap(find.byIcon(Icons.settings));
      expect(tapped, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('gear renders decorative when no callback is wired',
        (tester) async {
      await pumpPanel(tester);
      expect(find.byIcon(Icons.settings), findsOneWidget);
      await tester.tap(find.byIcon(Icons.settings));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });

  group('Fix 20 — fix 11: MIC-fader-linked music ducking', () {
    test('mic factor: full fader -> ~5%, zero fader -> 100%', () {
      expect(micFaderDuckFactor(micFader: 1.0, micOn: true), closeTo(0.05, 0.001));
      expect(micFaderDuckFactor(micFader: 0.0, micOn: true), closeTo(1.0, 0.001));
      expect(micFaderDuckFactor(micFader: 0.5, micOn: true), closeTo(0.525, 0.001));
    });

    test('mic muted -> no fader ducking, whatever the fader says', () {
      expect(micFaderDuckFactor(micFader: 1.0, micOn: false), closeTo(1.0, 0.001));
      expect(micFaderDuckFactor(micFader: 0.5, micOn: false), closeTo(1.0, 0.001));
    });

    test('fader clamps out-of-range values', () {
      expect(micFaderDuckFactor(micFader: 1.5, micOn: true), closeTo(0.05, 0.001));
      expect(micFaderDuckFactor(micFader: -0.5, micOn: true), closeTo(1.0, 0.001));
    });

    test('DEFECT FIX (behavioral): local/fallback ducking via musicTargetVolume', () {
      // Local playback (no shared session): mic fader at max
      // ducks the music to the 5% bed, exactly like shared.
      // (Before the fix the local target was the plain base
      // volume — turning the mic fader up did nothing locally.)
      expect(
          musicTargetVolume(
              base: 1.0,
              sharedSession: false,
              activityFactor: 1.0,
              faderFactor: 0.05),
          closeTo(0.05, 0.001));
      // Local + fader at 0: full volume.
      expect(
          musicTargetVolume(
              base: 0.8,
              sharedSession: false,
              activityFactor: 1.0,
              faderFactor: 1.0),
          closeTo(0.8, 0.001));
      // Local + fader halfway: half-ducked (0.525 factor).
      expect(
          musicTargetVolume(
              base: 1.0,
              sharedSession: false,
              activityFactor: 1.0,
              faderFactor: 0.525),
          closeTo(0.525, 0.001));
      // Shared + voice-activity ducked + fader max: both factors
      // multiply (0.05 x 0.05).
      expect(
          musicTargetVolume(
              base: 1.0,
              sharedSession: true,
              activityFactor: 0.05,
              faderFactor: 0.05),
          closeTo(0.0025, 0.0001));
      // Shared + not activity-ducked + fader max: fader only.
      expect(
          musicTargetVolume(
              base: 1.0,
              sharedSession: true,
              activityFactor: 1.0,
              faderFactor: 0.05),
          closeTo(0.05, 0.001));
      // The activity bed is shared-only: a ducked activity
      // factor on a local session must NOT duck (the rule
      // ignores activityFactor when sharedSession is false).
      expect(
          musicTargetVolume(
              base: 1.0,
              sharedSession: false,
              activityFactor: 0.05,
              faderFactor: 1.0),
          closeTo(1.0, 0.001));
    });

    test('DEFECT FIX (source): _applyMusicVolume uses the rule; fallback routes through it', () {
      // FIX 22 item 11: the fade loop is deleted — the region
      // now ends at the inverse-link handler below.
      final apply = _region(
          roomScreen,
          'Future<void> _applyMusicVolume()',
          'Future<void> _onUserMusicVolume(');
      expect(apply, isNotEmpty);
      expect(apply, contains('musicTargetVolume('));
      expect(apply, contains('sharedSession: _sharedSession != null,'));
      // The speaker fallback no longer sets the raw base volume
      // (which bypassed ducking entirely) — it clears the
      // session and routes through _applyMusicVolume.
      final fallback = _region(roomScreen, 'Future<void> _playSpeakerFallback(',
          'Future<void> _startListeningSession(');
      expect(fallback, isNotEmpty);
      expect(fallback, contains('_sharedSession = null;'));
      expect(fallback, contains('await _applyMusicVolume();'));
      expect(fallback, isNot(contains('setVolume(_musicBaseVolume)')));
    });

    test('room wires the MIC fader into _applyMusicVolume', () {
      expect(roomScreen, contains('onMicVolume: (v) async {'));
      // FIX 22 item 11: the fader routes through the inverse-link
      // gesture handler (mic up -> music down, one nudge per
      // gesture) instead of assigning the fader level directly.
      expect(roomScreen, contains('await _onUserMicLevel(v);'));
      expect(roomScreen, contains('_micFaderLevel = next.mic;'));
      // FIX 24 — SINGLE MECHANISM: _applyMusicVolume no longer
      // calls micFaderDuckFactor (it squared the link's response:
      // one mic drag changed the music through two multiplying
      // paths). The inverse link is the only mic/music mechanism
      // now — it moves _musicBaseVolume itself, and
      // _applyMusicVolume applies base x activity (faderFactor
      // 1.0). The pure micFaderDuckFactor function stays
      // (unit-tested above) — it is just not applied here.
      final apply = _region(
          roomScreen, 'Future<void> _applyMusicVolume()', 'Future<void> _onUserMusicVolume(');
      expect(apply, isNot(contains('micFaderDuckFactor(')));
      expect(apply, contains('const faderFactor = 1.0;'));
      // The MUSIC handle is never moved by ducking itself: the
      // onMicVolume handler calls only the gesture handler (the
      // inverse nudge lives inside _onUserMicLevel, not here).
      final handler = _region(roomScreen, 'onMicVolume: (v) async {',
          'onSoundboard: (pad) => _playSoundboardPad(');
      expect(handler, isNot(contains('_musicBaseVolume =')));
    });
  });

  group('Fix 20 — fix 12: RJ panel drag throttle (source)', () {
    test('all five DSP pushes go through the 50ms throttle', () {
      expect(rjPanel, contains('_throttledPush('));
      for (final key in ['reverb', 'echo', 'eq', 'compressor', 'noisegate']) {
        expect(rjPanel, contains("_throttledPush('$key'"));
      }
      expect(rjPanel, contains('_dragThrottle = Duration(milliseconds: 50)'));
    });

    test('drag handlers refresh the panel throttled, never per tick', () {
      // 6 knobs + 3 faders call the throttled refresh.
      expect('_throttledPanelRefresh();'.allMatches(rjPanel).length, 9);
      // The knob/fader onChanged handlers no longer setState
      // directly (single taps elsewhere still do — untouched).
      final knobs = _region(rjPanel, "key: const Key('knob-reverb')",
          'Widget _buildSoundboard()');
      expect(knobs, isNot(contains('setState(() {')));
      expect(knobs, isNot(contains('setState(() =>')));
    });

    test('pending throttle timers are cancelled in dispose', () {
      final dispose = _region(rjPanel, 'void dispose() {',
          'void _subscribeSpectrumStreams()');
      expect(dispose, contains('_dspPushPending'));
      expect(dispose, contains('_panelRefreshPending?.cancel()'));
    });

    test('the fader accumulates drags locally (throttled parent safe)', () {
      expect(rjPanel, contains('class _RjFaderState extends State<_RjFader>'));
      expect(rjPanel, contains('_dragAccum = widget.value.clamp(0.0, 1.0);'));
      expect(rjPanel, contains('_dragAccum = (_dragAccum - details.delta.dy'));
    });
  });

  group('Fix 20 — widget: MIC fader drag + drag throttle (fixes 11, 12)', () {
    Future<void> pumpPanel(
      WidgetTester tester, {
      _FakeRjDsp? dsp,
      ValueChanged<double>? onMicVolume,
    }) async {
      tester.view.physicalSize = const Size(400, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: RjStudioPanel(
              dsp: dsp ?? _FakeRjDsp(),
              isHost: true,
              hostName: 'RJ Sameer',
              onGoLivePressed: () {},
              onMutePressed: () {},
              onMicVolume: onMicVolume,
            ),
          ),
        ),
      ));
      await tester.pump();
    }

    testWidgets('dragging the MIC fader fires onMicVolume with a new value',
        (tester) async {
      final seen = <double>[];
      await pumpPanel(tester, onMicVolume: seen.add);
      await tester.drag(
          find.byKey(const Key('fader-mic')), const Offset(0, -55));
      await tester.pumpAndSettle();
      expect(seen, isNotEmpty);
      expect(seen.last, greaterThan(0.8));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a fast knob drag produces BOUNDED DSP pushes + exact final value',
        (tester) async {
      final fake = _FakeRjDsp();
      await pumpPanel(tester, dsp: fake);
      // One drag = many onChanged ticks at the same fake time:
      // the first pushes at once, the rest collapse into ONE
      // trailing push. Total must be exactly 2, and the last
      // push must carry the exact final drag value (0.5).
      await tester.drag(
          find.byKey(const Key('knob-reverb')), const Offset(0, -60));
      await tester.pump(const Duration(milliseconds: 100));
      expect(fake.reverbCalls, 2);
      expect(fake.lastWetDryMix, closeTo(0.5, 0.01));
      expect(tester.takeException(), isNull);
    });
  });

  group('Fix 20 — fix 13: console scrolls to the bottom (source)', () {
    test('console sheet owns the scroll gesture + bottom padding', () {
      final console = _region(roomScreen, '_showRjVoiceConsole',
          'void _showLiveKitPanel');
      expect(console, contains('DraggableScrollableSheet('));
      expect(console, contains('controller: scrollController,'));
      expect(console, contains('28 + MediaQuery.of(sheetCtx).viewInsets.bottom'));
    });

    test('tight panel labels scale down instead of clipping', () {
      expect(rjPanel, contains('FittedBox('));
      expect(rjPanel, contains("fit: BoxFit.scaleDown,"));
    });
  });

  group('Fix 20 — widget: panel scrolls fully at 360px (fix 13)', () {
    testWidgets('scroll to the bottom: GO LIVE + MUTE + listeners visible',
        (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: RjStudioPanel(
              dsp: _FakeRjDsp(),
              isHost: true,
              hostName: 'RJ Sameer',
              listenerCount: 3,
              onGoLivePressed: () {},
              onMutePressed: () {},
            ),
          ),
        ),
      ));
      await tester.pump();
      await tester.scrollUntilVisible(find.text('MUTE'), 300);
      await tester.pump();
      expect(find.text('GO LIVE'), findsOneWidget);
      expect(find.text('MUTE'), findsOneWidget);
      expect(find.text('3 listening'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('Fix 20 — fix 14: play local first, share in background (source)', () {
    test('library tap plays locally BEFORE the background share starts', () {
      final play = _region(roomScreen, 'Future<void> _playLibraryEntry',
          'Future<void> _pickAndShareFile()');
      final localAt = play.indexOf('_playLocalFile(path, name, key: key);');
      final shareAt =
          play.indexOf('_sharePlayingFileInBackground(path, name, key: key);');
      expect(localAt, greaterThanOrEqualTo(0));
      expect(shareAt, greaterThan(localAt));
      // The old gating call (awaited upload before any sound) is gone.
      expect(play, isNot(contains('await _uploadAndShareFile(path, name, key: key);')));
    });

    test('picked file plays locally BEFORE the background share starts', () {
      final pick = _region(roomScreen, 'Future<void> _pickAndShareFile()',
          'Future<void> _setBroadcast(bool on)');
      final localAt = pick.indexOf('_playLocalFile(picked.path, picked.name);');
      final shareAt =
          pick.indexOf('_sharePlayingFileInBackground(picked.path, picked.name);');
      expect(localAt, greaterThanOrEqualTo(0));
      expect(shareAt, greaterThan(localAt));
    });

    test('background share reuses fromToggle semantics + toasts on success', () {
      final helper = _region(roomScreen, '_sharePlayingFileInBackground',
          '// Upload + shared play.');
      expect(helper, contains('fromToggle: true'));
      expect(helper, contains('Shared to the room'));
    });

    test('the upload has a 30s timeout (never hangs forever)', () {
      final upload = _region(roomScreen,
          'Future<bool> _uploadAndShareFile', '// Re-broadcast a file');
      expect(upload, contains('.timeout(const Duration(seconds: 30))'));
    });

    test('the shared path never stops/restarts playback for sharing', () {
      final upload = _region(roomScreen,
          'Future<bool> _uploadAndShareFile', '// Re-broadcast a file');
      final toggleBranch = _region(upload, '} else {',
          "await _sendMusicAction('play', session: session);");
      expect(toggleBranch, isNot(contains('_stopMusic()')));
      expect(toggleBranch, isNot(contains('_playMusicSource(')));
    });
  });

  group('Fix 20 — fix 15: RJ Panel button in the Music header (source)', () {
    test('panel exposes the RJ button + host visibility flag', () {
      expect(musicPanel, contains('final VoidCallback? onRjPanel;'));
      expect(musicPanel, contains('final bool rjVisible;'));
      expect(musicPanel, contains("if (widget.rjVisible)"));
      expect(musicPanel, contains("'RJ Panel'"));
      expect(musicPanel, contains('Icons.graphic_eq'));
    });

    test('mount wires the host gate + close-then-open flow', () {
      // FIX 22 item 21: _showMusicPlayer is retired — the mount
      // region now ends at the next method, _editLibraryEntry.
      final mount = _region(roomScreen, 'void _showMusicPanel()',
          'Future<void> _editLibraryEntry(');
      expect(mount, contains('rjVisible: _isAdminForBroadcast ||'));
      expect(mount, contains('_isTeamCaptainForBroadcast ||'));
      expect(mount, contains('_isCommunityOrganizerForBroadcast,'));
      expect(mount, contains('onRjPanel: () async {'));
      final rj = _region(mount, 'onRjPanel: () async {', 'onClose: () => Navigator.pop(ctx),');
      expect(rj.indexOf('Navigator.pop(ctx);'),
          lessThan(rj.indexOf('_showRjVoiceConsole();')));
    });
  });

  group('Fix 20 — widget: Music header RJ Panel button (fix 15)', () {
    Future<void> pumpMusic(
      WidgetTester tester, {
      required bool rjVisible,
      VoidCallback? onRjPanel,
    }) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MusicLibraryPanel(
            songs: const [],
            nowPlaying: null,
            nowPlayingPaused: false,
            broadcastOn: false,
            selectedTab: 0,
            searchQuery: '',
            onTabChanged: (_) {},
            onSearchChanged: (_) {},
            onPlaySong: (_) {},
            onPauseResume: () {},
            onStop: () {},
            onOpenPlayer: () {},
            onToggleBookmark: (_) {},
            onEditSong: (_) {},
            onUpload: () {},
            onClose: () {},
            rjVisible: rjVisible,
            onRjPanel: onRjPanel,
          ),
        ),
      ));
      await tester.pump();
    }

    testWidgets('host sees the RJ Panel button; tap fires the callback',
        (tester) async {
      var tapped = false;
      await pumpMusic(tester, rjVisible: true, onRjPanel: () => tapped = true);
      expect(find.text('RJ Panel'), findsOneWidget);
      await tester.tap(find.text('RJ Panel'));
      expect(tapped, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('non-host sees no button at all (never a dead button)',
        (tester) async {
      await pumpMusic(tester, rjVisible: false);
      expect(find.text('RJ Panel'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('Fix 20 — fix 16: duplicate song dedupe', () {
    test('same key always matches', () {
      expect(
          libraryEntriesMatch(
              {'key': 'file:/a/song.mp3', 'title': 'Song', 'size': 100},
              {'key': 'file:/a/song.mp3', 'title': 'Other', 'size': 200}),
          isTrue);
    });

    test('same title + size matches even with a different path spelling', () {
      expect(
          libraryEntriesMatch(
              {
                'key': 'file:/storage/emulated/0/Music/x.mp3',
                'title': 'Kul marera nana',
                'size': 6234567
              },
              {
                'key': 'file:/storage/0/Music/x.mp3',
                'title': 'Kul marera nana',
                'size': 6234567
              }),
          isTrue);
    });

    test('title match is trimmed + case-insensitive', () {
      expect(
          libraryEntriesMatch(
              {'key': 'file:/a.mp3', 'title': '  My Song ', 'size': 5},
              {'key': 'file:/b.mp3', 'title': 'my song', 'size': 5}),
          isTrue);
    });

    test('same title but different size does NOT match', () {
      expect(
          libraryEntriesMatch(
              {'key': 'file:/a.mp3', 'title': 'Song', 'size': 100},
              {'key': 'file:/b.mp3', 'title': 'Song', 'size': 101}),
          isFalse);
    });

    test('different title does NOT match even with the same size', () {
      expect(
          libraryEntriesMatch(
              {'key': 'file:/a.mp3', 'title': 'Song A', 'size': 100},
              {'key': 'file:/b.mp3', 'title': 'Song B', 'size': 100}),
          isFalse);
    });

    test('unknown size (0 / missing) never matches by title', () {
      expect(
          libraryEntriesMatch(
              {'key': 'file:/a.mp3', 'title': 'Song', 'size': 0},
              {'key': 'file:/b.mp3', 'title': 'Song', 'size': 100}),
          isFalse);
      expect(
          libraryEntriesMatch(
              {'key': 'file:/a.mp3', 'title': 'Song'},
              {'key': 'file:/b.mp3', 'title': 'Song', 'size': 100}),
          isFalse);
    });

    test('tones (no size) match by key only', () {
      expect(
          libraryEntriesMatch(
              {'key': 'tone:Chime', 'title': 'Chime'},
              {'key': 'tone:Bell', 'title': 'Chime'}),
          isFalse);
      expect(
          libraryEntriesMatch(
              {'key': 'tone:Chime', 'title': 'Chime'},
              {'key': 'tone:Chime', 'title': 'Chime'}),
          isTrue);
    });

    test('upsert + load-merge + persist all use the dedupe', () {
      final upsert = _region(roomScreen,
          'Map<String, dynamic> _upsertLibraryFile(', '_libraryEntryByKey');
      expect(upsert, contains('libraryEntriesMatch(e, candidate)'));
      expect(upsert, contains("'size': size"));
      final load = _region(roomScreen,
          'Future<void> _loadPersistedMusic() async {',
          'Map<String, dynamic> _upsertLibraryFile(');
      expect(load, contains('libraryEntriesMatch(x, e)'));
      expect(load, contains("'size': size"));
      final persist = _region(roomScreen,
          'Future<void> _persistMusicLibrary() async {',
          'Future<void> _loadPersistedMusic() async {');
      expect(persist, contains("'size': e['size'] is int ? e['size'] : 0,"));
    });
  });

  group('Fix 20 — fix 17: subresource errors must not kill the player (source)', () {
    test('onWebResourceError fails the player ONLY for the main frame', () {
      final handler = _region(watchLive, 'onWebResourceError: (err) {',
          'onNavigationRequest: (req) {');
      expect(handler, contains('if (err.isForMainFrame != true) {'));
      expect(handler, contains('debugPrint('));
      expect(handler, contains('_playerFailed = true;'));
      // The guard returns BEFORE the failure setState.
      expect(handler.indexOf('return;'),
          lessThan(handler.indexOf('_playerFailed = true;')));
    });

    test('real player errors (JS channel) still fail the player + Retry stays', () {
      final channel = _region(watchLive, 'addJavaScriptChannel(',
          '..setNavigationDelegate(');
      expect(channel, contains('_playerFailed = true;'));
      expect(watchLive, contains('Dobara koshish karein'));
    });
  });

  group('Fix 20 — fix 18: chat streams created once, not per build (source)', () {
    test('Watch Live: one streamChat call (initState), field passed to the builder', () {
      expect('SupaDb.streamChat('.allMatches(watchLive).length, 1);
      expect(watchLive,
          contains("_commentStream = SupaDb.streamChat('watch_live', widget.tournamentId);"));
      expect(watchLive, contains('stream: _commentStream,'));
    });

    test('room chat: one streamChat call (initState), field shared by both paths', () {
      expect('SupaDb.streamChat('.allMatches(roomScreen).length, 1);
      expect(roomScreen,
          contains('_chatStream = SupaDb.streamChat(widget.scope, _chatScopeId);'));
      expect(roomScreen, contains('stream: _chatStream,'));
      expect(roomScreen, contains('_musicRowsSub = _chatStream.listen((rows) {'));
    });

    test('community chat already subscribes once in initState (no change needed)', () {
      final init = _region(communityScreens,
          'class _CommunityChatTabState', 'void dispose() {');
      expect(init,
          contains('_streamSub = CommunityGroups.streamCommunityChat(widget.communityId)'));
      expect(communityScreens, isNot(contains('stream: SupaDb.streamChat(')));
    });
  });
  group('Fix 20 — fix 20: total views counter (source)', () {
    test('increment fires once per open, guarded before the await', () {
      final count = _region(watchLive,
          'Future<void> _countWatchView() async {',
          'Future<void> _loadTotalViews() async {');
      expect(count, contains('if (_viewCounted) return;'));
      expect(count, contains('_viewCounted = true;'));
      expect(count.indexOf('_viewCounted = true;'),
          lessThan(count.indexOf('incrementWatchViews')));
      expect(count, contains('SupaDb.incrementWatchViews(widget.tournamentId);'));
    });

    test('total reads watch_views from the row; missing -> null ("—")', () {
      final load = _region(watchLive,
          'Future<void> _loadTotalViews() async {',
          'Future<void> _loadLikes() async {');
      expect(load, contains("SupaDb.getRow('tournaments', 'id', widget.tournamentId)"));
      expect(load, contains("row['watch_views']"));
      expect(load, contains('_totalViews = null'));
    });

    test('total refreshes with the 30s viewer poll + displays compact', () {
      final beat = _region(watchLive, '_heartbeatViewer()',
          '_countWatchView()');
      expect(beat, contains('unawaited(_loadTotalViews());'));
      expect(watchLive, contains("formatViewerCount(_totalViews!)"));
      expect(watchLive, contains("'total views'"));
    });

    test('SupaDb helper calls the RPC + records in fixture mode', () {
      final db = _read('lib/services/supabase_db.dart');
      expect(db, contains('static final List<Map<String, dynamic>> testRpcCalls'));
      expect(db, contains('static Future<bool> incrementWatchViews(String tournamentId)'));
      expect(db, contains("client.rpc('increment_watch_views'"));
      expect(db, contains("'p_tournament_id': tournamentId"));
      expect(db, contains("testRpcCalls.add("));
    });
  });
}

/// Minimal fake RjVoiceDsp for the panel widget tests (fixes 9,
/// 10): no-op setters — the tests only drive the GO LIVE button,
/// the ON AIR sign and the gear, never the DSP. Fix 12 records
/// the reverb pushes (count + last value) for the throttle pin.
class _FakeRjDsp implements RjVoiceDsp {
  @override
  bool isInitialized = true;

  int reverbCalls = 0;
  double lastWetDryMix = -1;

  @override
  Future<void> setEq({
    bool enabled = true,
    double bassBoostDb = 0.0,
    double lowGainDb = 0.0,
    double midGainDb = 0.0,
    double highGainDb = 0.0,
  }) async {}

  @override
  Future<void> setEcho({
    bool enabled = true,
    double delayMs = 250.0,
    double feedback = 0.35,
    double mix = 0.35,
  }) async {}

  @override
  Future<void> setReverb({
    bool enabled = true,
    double wetDryMix = 0.3,
    double roomSize = 0.5,
    double damping = 0.5,
  }) async {
    reverbCalls++;
    lastWetDryMix = wetDryMix;
  }

  @override
  Future<void> setNoiseGate({
    bool enabled = true,
    double thresholdDb = -40.0,
    double attackMs = 5.0,
    double releaseMs = 120.0,
  }) async {}

  @override
  Future<void> setCompressor({
    bool enabled = true,
    double thresholdDb = -18.0,
    double ratio = 4.0,
    double attackMs = 10.0,
    double releaseMs = 100.0,
    double makeupGainDb = 0.0,
  }) async {}
}

// ---- Fake Firebase (exact pattern from device_ban_gate_test,
// copied from fix12_g6_voice_room_test.dart) ----

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
            projectId: 'test',
          ),
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

class _FakeUserCredential extends UserCredentialPlatform {
  _FakeUserCredential({required super.auth, super.user});
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
    _user = currentUser == null
        ? null
        : _FakeUser(
            this,
            _FakeMultiFactor(this),
            currentUser,
          );
    return this;
  }

  @override
  UserPlatform? get currentUser => _user;

  @override
  set currentUser(UserPlatform? user) => _user = user;

  @override
  Future<UserCredentialPlatform> signInWithEmailAndPassword(
    String email,
    String password,
  ) async {
    final details = PigeonUserDetails(
      userInfo: PigeonUserInfo(
        uid: 'test-uid',
        email: email,
        isAnonymous: false,
        isEmailVerified: true,
      ),
      providerData: [],
    );
    _user = _FakeUser(this, _FakeMultiFactor(this), details);
    return _FakeUserCredential(auth: this, user: _user);
  }

  @override
  Future<void> signOut() async {
    _user = null;
  }
}
