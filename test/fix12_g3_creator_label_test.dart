// FIX12-G3 (§3, 2026-11-23 user order) — REMOVE the big CREATOR
// label from the community detail header. One clean Follow/Unfollow
// button stays in the same spot (GoldButton, gold #FDC903 pill);
// the creator sees it in the JOINED state, like any member.
// _toggleFollow logic is UNCHANGED — only the label changed.
// FIX 20 (2026-11-23): the header strip is GONE — Follow/Unfollow
// moved into the More menu (same _toggleFollow logic; creator
// still sees a disabled JOINED entry there, never CREATOR).
// Out of scope (other groups / other screens): the CommunitiesList
// card badge, the Members-tab role pill, the More-menu About option.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/screens/communities_screens.dart';
import 'package:protournament_user/services/supabase_db.dart';
import 'package:shared_preferences/shared_preferences.dart';

String _read(String path) => File(path).readAsStringSync();

String _region(String src, String from, String to) {
  final start = src.indexOf(from);
  final end = src.indexOf(to, start);
  return src.substring(start, end);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late String communityScreens;

  setUpAll(() {
    communityScreens = _read('lib/screens/communities_screens.dart');
  });

  group('Fix12-G3 — detail header label (source invariants)', () {
    test('follow action lives in the More menu — no CREATOR ternary',
        () {
      // FIX 20: the header strip is gone — Follow/Unfollow moved
      // into the More menu. The creator still sees JOINED
      // (disabled), never CREATOR.
      final detail = _region(communityScreens,
          'class _CommunityDetailPageState', 'class _FollowToInteractBanner');
      expect(detail, isNot(contains("label: _isMember ? 'JOINED' : 'FOLLOW'")));
      expect(detail, contains("value: 'follow',"));
      expect(detail, contains("child: Text('JOINED',"));
      expect(
          detail, contains("child: Text(_isMember ? 'Unfollow' : 'Follow'"));
      expect(detail, isNot(contains("'CREATOR'")));
      expect(detail, isNot(contains('_isCreator ? \'CREATOR\'')));
    });

    test('_toggleFollow logic unchanged (follow/unfollow + refresh)',
        () {
      // Scope to the DETAIL state first: the list card has its own
      // _toggleFollow earlier in the file.
      final detail = _region(communityScreens,
          'class _CommunityDetailPageState', 'class _FollowToInteractBanner');
      final toggle = _region(detail,
          'Future<void> _toggleFollow() async {', 'Future<void> _delete()');
      expect(toggle, contains('CommunityGroups.unfollowCommunity'));
      expect(toggle, contains('CommunityGroups.followCommunity'));
      expect(toggle, contains('await _init()'));
      expect(toggle, contains('_followBusy'));
    });

    test('creator menu entry stays non-tappable (cannot unfollow own community)',
        () {
      // FIX 20: the strip's disabled button became a disabled menu
      // entry — the JOINED item is the only `enabled: false` in
      // the detail state.
      final detail = _region(communityScreens,
          'class _CommunityDetailPageState', 'class _FollowToInteractBanner');
      expect('enabled: false,'.allMatches(detail).length, 1);
      expect(detail, contains("child: Text('JOINED',"));
    });

    test('header strip is gone — no GoldButton JOINED/FOLLOW on the page',
        () {
      // FIX 20: the description + Follow strip was deleted from
      // the detail body (the voice-lock banner keeps its own
      // GoldButton — REQUEST VOICE ACCESS, a different label).
      final detail = _region(communityScreens,
          'class _CommunityDetailPageState', 'class _FollowToInteractBanner');
      expect(detail, isNot(contains("label: _isMember ? 'JOINED' : 'FOLLOW'")));
      expect(detail,
          isNot(contains('onPressed: _isCreator ? null : _toggleFollow')));
    });
  });

  group('Fix12-G3 — detail header button (widget)', () {
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
      await tester.pumpWidget(MaterialApp(
          home: CommunityDetailPage(
              uid: 'test-uid',
              communityId: comm['id'] as String,
              community: comm)));
      await tester.pump();
      // _init() refreshes from fixtures; settle through it so the
      // asserted label is the refreshed one, not the first frame.
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
    }

    // The AppBar title is a standalone RichText: name UPPERCASED +
    // ' CHAT' (communities_screens.dart ~1367). find.text IGNORES
    // standalone RichText unless findRichText: true.
    String headerTitle(String name) => '${name.toUpperCase()} CHAT';
    Finder headerName(String name) =>
        find.text(headerTitle(name), findRichText: true);

    // FIX 20: the Follow/Unfollow action lives in the More menu
    // now — open it before asserting the follow state.
    Future<void> openMore(WidgetTester tester) async {
      await tester.tap(find.text('More'));
      await tester.pump();
    }

    testWidgets('creator sees JOINED in More — never CREATOR',
        (tester) async {
      await pumpDetail(
          tester,
          community('comm-1', 'Meri Kahani', 'testing',
              isMember: true, myRole: 'creator'));
      expect(headerName('Meri Kahani'), findsOneWidget);
      // The strip is gone: JOINED is not on the page itself.
      expect(find.text('JOINED'), findsNothing);
      await openMore(tester);
      expect(find.text('JOINED'), findsOneWidget);
      expect(find.text('Follow'), findsNothing);
      expect(find.text('CREATOR'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('plain member sees Unfollow in More — never CREATOR',
        (tester) async {
      await pumpDetail(
          tester,
          community('comm-3', 'Night Owls', 'late night squad',
              isMember: true, myRole: 'member'));
      expect(headerName('Night Owls'), findsOneWidget);
      expect(find.text('JOINED'), findsNothing);
      await openMore(tester);
      expect(find.text('Unfollow'), findsOneWidget);
      expect(find.text('JOINED'), findsNothing);
      expect(find.text('CREATOR'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('non-member sees Follow in More — never CREATOR',
        (tester) async {
      await pumpDetail(
          tester,
          community('comm-2', 'Pro Gamers', '',
              isMember: false, myRole: ''));
      expect(headerName('Pro Gamers'), findsOneWidget);
      expect(find.text('Follow'), findsNothing);
      await openMore(tester);
      expect(find.text('Follow'), findsOneWidget);
      expect(find.text('JOINED'), findsNothing);
      expect(find.text('CREATOR'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
