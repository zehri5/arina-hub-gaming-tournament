import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:firebase_auth_platform_interface/firebase_auth_platform_interface.dart';
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:protournament_user/community_service.dart';
import 'package:protournament_user/screens/communities_screens.dart';
import 'package:protournament_user/screens/room_screen.dart';
import 'package:protournament_user/services/squad.dart';
import 'package:protournament_user/services/supabase_db.dart';

/// Communities feature (2026-11-21, draft migration 073).
///
/// Pure normaliser + validation tests run with NO network. The widget
/// test pumps the real list page against SupaDb.testFixtures (the
/// FIX 6 seam) — no Supabase connection is needed: reads go through
/// the fixtures, and the readiness probe fails closed to "coming
/// online" (which the page shows alongside the list, never instead
/// of it).

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Fake Firebase FIRST (top-level setUpAll, before ANY test —
  // device_ban_gate_test / G6 pattern): FIX 12 G6 mounts the real
  // UnifiedRoomPage on a Voice tap, and its initState constructs
  // a VoiceRoom whose _uid reads FirebaseAuth.instance.currentUser!
  // — without a fake app + a signed-in user the mount throws
  // [core/no-app]. The fakes must be in place before ANY Firebase
  // touch, or the real MethodChannel delegate caches. Only the
  // voice test signs in (below); the other tests never touch
  // Firebase, so the signed-out fake is invisible to them.
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
    // Force the FirebaseAuth singleton (and its delegate) to exist
    // now, so every test starts from the same signed-out fake.
    // ignore: unnecessary_statements
    FirebaseAuth.instance;
    // FIX 22 item 6: the room auto-tries DSP on mount
    // (_installMicNoiseProcessor from initState). In widget tests
    // the native channel never answers, so initialize()'s 2s
    // timeout Timer stays pending and trips the postTest
    // invariant. Answer isAvailable -> false immediately (the
    // fix21 pattern): DSP fails fast as native-absent (no
    // retry), the room falls back to RNNoise, no timer lingers.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('arena_hub_dsp_mic'),
            (MethodCall call) async {
              if (call.method == 'isAvailable') return false;
              return null;
            });
  });

  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('arena_hub_dsp_mic'), null);
  });

  // The list page reads SharedPreferences (cached-first list, guide
  // §4.1). Without mock values the prefs method-channel call never
  // completes under fake async and pumpAndSettle times out. The
  // instance is cached process-wide after the first getInstance(),
  // so each test also clears the LIVE instance — otherwise a list
  // cached by an earlier test would leak into the next one.
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
  });

  tearDown(() {
    SupaDb.testFixtures = null;
  });

  // FIX 23: manual pumps replace pumpAndSettle everywhere in this
  // file — the smoke layer (item 24, continuous Lottie) never
  // settles, so pumpAndSettle times out on every page now. 4s
  // flushes the fixture futures; the final 5s flushes the mount
  // toast's snackbar timer (the DSP ping is already mocked to
  // answer immediately in setUpAll above).
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    await tester.pump(const Duration(seconds: 5));
  }

  // FIX 23 item 16a: the detail page mounts the voice panel
  // ALWAYS for members, so VoiceRoom is constructed at pump time
  // — a signed-in user must exist first (currentUser!.uid).
  Future<void> signIn() async {
    await FirebaseAuth.instance.signOut();
    await FirebaseAuth.instance
        .signInWithEmailAndPassword(email: 't@t.com', password: 'password');
  }

  group('CommunityGroups.normCommunity', () {
    test('maps snake_case row to both key styles + defaults', () {
      final m = CommunityGroups.normCommunity({
        'id': 'c1',
        'name': 'PUBG Pros',
        'description': 'Best players',
        'photo_url': 'https://example.com/p.png',
        'created_by_uid': 'u1',
        'created_at': '2026-11-21T10:00:00.000Z',
      });
      expect(m['id'], 'c1');
      expect(m['name'], 'PUBG Pros');
      expect(m['photoUrl'], 'https://example.com/p.png');
      expect(m['createdByUid'], 'u1');
      expect(m['memberCount'], 0);
      expect(m['isMember'], false);
      expect(m['createdAt'], greaterThan(0));
    });

    test('empty row stays empty', () {
      expect(CommunityGroups.normCommunity({}), isEmpty);
    });
  });

  group('CommunityGroups.normPost / normComment', () {
    test('post keeps body + image + ms timestamp', () {
      final p = CommunityGroups.normPost({
        'id': 'p1',
        'community_id': 'c1',
        'author_uid': 'u2',
        'body': 'Hello community',
        'image_url': '',
        'created_at': '2026-11-21T10:00:00.000Z',
      });
      expect(p['body'], 'Hello community');
      expect(p['imageUrl'], '');
      expect(p['createdAt'], greaterThan(0));
      expect(p['commentCount'], 0);
    });

    test('comment keeps body + post link', () {
      final c = CommunityGroups.normComment({
        'id': 'cm1',
        'post_id': 'p1',
        'author_uid': 'u3',
        'body': 'Nice!',
        'created_at': '2026-11-21T10:05:00.000Z',
      });
      expect(c['post_id'], 'p1');
      expect(c['body'], 'Nice!');
    });
  });

  group('CommunityGroups validation (no network touched)', () {
    test('createCommunity rejects empty name before any DB call', () async {
      final res = await CommunityGroups.createCommunity(
          creatorUid: 'u1', name: '   ');
      expect(res['ok'], false);
      expect(res['error'], contains('naam'));
    });

    test('createCommunity rejects missing login', () async {
      final res = await CommunityGroups.createCommunity(
          creatorUid: '', name: 'Test');
      expect(res['ok'], false);
    });

    test('createCommunity rejects >80 char name', () async {
      final res = await CommunityGroups.createCommunity(
          creatorUid: 'u1', name: 'x' * 81);
      expect(res['ok'], false);
    });

    test('createPost rejects empty body before any DB call', () async {
      final res = await CommunityGroups.createPost(
          communityId: 'c1', authorUid: 'u1', body: '   ');
      expect(res['ok'], false);
    });

    test('addComment rejects empty body before any DB call', () async {
      final res = await CommunityGroups.addComment(
          postId: 'p1', communityId: 'c1', authorUid: 'u1', body: '');
      expect(res['ok'], false);
    });

    test('sendCommunityChatMessage rejects empty message', () async {
      final res = await CommunityGroups.sendCommunityChatMessage(
          communityId: 'c1',
          fromUid: 'u1',
          displayName: 'Player',
          message: '  ');
      expect(res['ok'], false);
    });

    test('followCommunity rejects missing login', () async {
      final res = await CommunityGroups.followCommunity('', 'c1');
      expect(res['ok'], false);
    });
  });

  group('CommunitiesListPage widget (fixture-backed)', () {
    testWidgets('shows fixture communities as STAN rows',
        (tester) async {
      SupaDb.testFixtures = {
        'communities': [
          {
            'id': 'c1',
            'name': 'PUBG Pros',
            'description': 'Best players only',
            'photo_url': '',
            'created_by_uid': 'u9',
            'created_at': '2026-11-21T10:00:00.000Z',
          },
          {
            'id': 'c2',
            'name': 'Free Fire Squad',
            'description': '',
            'photo_url': '',
            'created_by_uid': 'u8',
            'created_at': '2026-11-20T10:00:00.000Z',
          },
        ],
        'community_members': [],
      };

      await tester.pumpWidget(
        const MaterialApp(
          home: CommunitiesListPage(uid: 'u1'),
        ),
      );
      await settle(tester);

      expect(find.text('PUBG Pros'), findsOneWidget);
      expect(find.text('Free Fire Squad'), findsOneWidget);
      // FIX 12 G15 (STAN rows): no description in the row — round
      // photo + name + count chip + gold arrow. Both communities
      // land in Top Communities.
      // FIX 23 item 19 SUPERSEDES the no-Follow-button rule: every
      // non-creator, non-member row has a Follow button now
      // (direct join from outside). Neither fixture row is the
      // user's own, so both show it. JOINED still never shows on
      // a card (unfollow lives in the room, item 9).
      expect(find.text('Best players only'), findsNothing);
      expect(find.text('Follow'), findsNWidgets(2));
      expect(find.text('JOINED'), findsNothing);
      expect(find.text('Top Communities'), findsOneWidget);
      expect(find.text('All Communities'), findsNothing);
      expect(find.byIcon(Icons.arrow_forward), findsNWidgets(2));
      // No members in fixtures -> 0 members shown on both rows.
      expect(find.text('0 members'), findsNWidgets(2));
      expect(find.text('CREATE'), findsOneWidget);
    });

    testWidgets('search filters the list', (tester) async {
      SupaDb.testFixtures = {
        'communities': [
          {
            'id': 'c1',
            'name': 'PUBG Pros',
            'description': '',
            'photo_url': '',
            'created_by_uid': 'u9',
            'created_at': '2026-11-21T10:00:00.000Z',
          },
          {
            'id': 'c2',
            'name': 'Free Fire Squad',
            'description': '',
            'photo_url': '',
            'created_by_uid': 'u8',
            'created_at': '2026-11-20T10:00:00.000Z',
          },
        ],
        'community_members': [],
      };

      await tester.pumpWidget(
        const MaterialApp(home: CommunitiesListPage(uid: 'u1')),
      );
      await settle(tester);

      await tester.enterText(
          find.byType(TextField).first, 'free fire');
      await settle(tester);

      expect(find.text('Free Fire Squad'), findsOneWidget);
      expect(find.text('PUBG Pros'), findsNothing);
    });

    testWidgets('empty list shows the create empty state',
        (tester) async {
      SupaDb.testFixtures = {
        'communities': [],
        'community_members': [],
      };

      await tester.pumpWidget(
        const MaterialApp(home: CommunitiesListPage(uid: 'u1')),
      );
      await settle(tester);

      expect(find.text('Abhi koi community nahi'), findsOneWidget);
      expect(find.text('CREATE COMMUNITY'), findsOneWidget);
    });
  });

  group('CommunityGroups validation — length limits (no network)', () {
    test('createPost rejects >2000 char body before any DB call',
        () async {
      final res = await CommunityGroups.createPost(
          communityId: 'c1', authorUid: 'u1', body: 'x' * 2001);
      expect(res['ok'], false);
      expect(res['error'], contains('2000'));
    });

    test('addComment rejects >1000 char body before any DB call',
        () async {
      final res = await CommunityGroups.addComment(
          postId: 'p1',
          communityId: 'c1',
          authorUid: 'u1',
          body: 'x' * 1001);
      expect(res['ok'], false);
      expect(res['error'], contains('1000'));
    });

    test('promoteMember rejects empty ids before any DB call', () async {
      final res = await CommunityGroups.promoteMember(
          communityId: '',
          requesterUid: 'u1',
          targetUid: 'u2',
          toRole: 'admin');
      expect(res['ok'], false);
      final res2 = await CommunityGroups.promoteMember(
          communityId: 'c1',
          requesterUid: 'u1',
          targetUid: '',
          toRole: 'admin');
      expect(res2['ok'], false);
    });

    test('promoteMember rejects bad role + self-promote', () async {
      final badRole = await CommunityGroups.promoteMember(
          communityId: 'c1',
          requesterUid: 'u1',
          targetUid: 'u2',
          toRole: 'creator');
      expect(badRole['ok'], false);
      final self = await CommunityGroups.promoteMember(
          communityId: 'c1',
          requesterUid: 'u1',
          targetUid: 'u1',
          toRole: 'admin');
      expect(self['ok'], false);
    });
  });

  group('SupaDb.getList pagination + search (fixtures)', () {
    List<Map<String, dynamic>> fiveCommunities() => [
          {
            'id': 'c1',
            'name': 'PUBG Pros',
            'created_at': '2026-11-21T10:00:00.000Z',
          },
          {
            'id': 'c2',
            'name': 'Free Fire Squad',
            'created_at': '2026-11-20T10:00:00.000Z',
          },
          {
            'id': 'c3',
            'name': 'pubg fans club',
            'created_at': '2026-11-19T10:00:00.000Z',
          },
          {
            'id': 'c4',
            'name': 'Chess Masters',
            'created_at': '2026-11-18T10:00:00.000Z',
          },
          {
            'id': 'c5',
            'name': 'Apex Legends PK',
            'created_at': '2026-11-17T10:00:00.000Z',
          },
        ];

    test('offset + limit page through rows in order', () async {
      SupaDb.testFixtures = {'communities': fiveCommunities()};
      final p1 = await SupaDb.getList('communities',
          orderBy: 'created_at', ascending: false, limit: 2, offset: 0);
      expect(p1.map((r) => r['id']).toList(), ['c1', 'c2']);
      final p2 = await SupaDb.getList('communities',
          orderBy: 'created_at', ascending: false, limit: 2, offset: 2);
      expect(p2.map((r) => r['id']).toList(), ['c3', 'c4']);
      final p3 = await SupaDb.getList('communities',
          orderBy: 'created_at', ascending: false, limit: 2, offset: 4);
      expect(p3.map((r) => r['id']).toList(), ['c5']);
      final p4 = await SupaDb.getList('communities',
          orderBy: 'created_at', ascending: false, limit: 2, offset: 5);
      expect(p4, isEmpty);
    });

    test('ilike is a case-insensitive substring match', () async {
      SupaDb.testFixtures = {'communities': fiveCommunities()};
      final hits = await SupaDb.getList('communities',
          ilikeCol: 'name', ilikeVal: 'PUBG');
      expect(hits.map((r) => r['id']).toList(), ['c1', 'c3']);
      final none = await SupaDb.getList('communities',
          ilikeCol: 'name', ilikeVal: 'zzz');
      expect(none, isEmpty);
    });

    test('lt is a strict less-than (chat cursor)', () async {
      SupaDb.testFixtures = {'communities': fiveCommunities()};
      final older = await SupaDb.getList('communities',
          ltCol: 'created_at', ltVal: '2026-11-19T10:00:00.000Z');
      expect(
          older.map((r) => r['id']).toList(), ['c4', 'c5']);
    });
  });

  group('SupaDb.countRows (fixtures)', () {
    test('counts filtered rows; 0 for missing table', () async {
      SupaDb.testFixtures = {
        'community_members': [
          {'community_id': 'c1', 'firebase_uid': 'u1'},
          {'community_id': 'c1', 'firebase_uid': 'u2'},
          {'community_id': 'c1', 'firebase_uid': 'u3'},
          {'community_id': 'c2', 'firebase_uid': 'u1'},
        ],
      };
      expect(
          await SupaDb.countRows('community_members',
              eqCol: 'community_id', eqVal: 'c1'),
          3);
      expect(
          await SupaDb.countRows('community_members',
              eqCol: 'community_id', eqVal: 'c2'),
          1);
      expect(
          await SupaDb.countRows('community_members',
              eqCol: 'community_id', eqVal: 'c9'),
          0);
      expect(await SupaDb.countRows('no_such_table'), 0);
    });
  });

  group('CommunityGroups.listCommunities pagination (fixtures)', () {
    test('pages newest-first + server-side name search', () async {
      SupaDb.testFixtures = {
        'communities': [
          {
            'id': 'c1',
            'name': 'PUBG Pros',
            'created_at': '2026-11-21T10:00:00.000Z',
          },
          {
            'id': 'c2',
            'name': 'Free Fire Squad',
            'created_at': '2026-11-20T10:00:00.000Z',
          },
          {
            'id': 'c3',
            'name': 'pubg fans club',
            'created_at': '2026-11-19T10:00:00.000Z',
          },
        ],
        'community_members': [
          {'community_id': 'c1', 'firebase_uid': 'u1'},
          {'community_id': 'c1', 'firebase_uid': 'u2'},
        ],
      };
      final p1 =
          await CommunityGroups.listCommunities(limit: 2, offset: 0);
      expect(p1.map((r) => r['id']).toList(), ['c1', 'c2']);
      // COUNT-based member count attached (no rows loaded).
      expect(p1[0]['memberCount'], 2);
      expect(p1[1]['memberCount'], 0);
      final p2 =
          await CommunityGroups.listCommunities(limit: 2, offset: 2);
      expect(p2.map((r) => r['id']).toList(), ['c3']);
      final found =
          await CommunityGroups.listCommunities(search: 'fire');
      expect(found.map((r) => r['id']).toList(), ['c2']);
    });
  });

  group('CommunityGroups.members pagination (fixtures)', () {
    test('pages joined-first + creator always first', () async {
      SupaDb.testFixtures = {
        // Creator joined LAST — the defensive sort must still put
        // the creator first (a repaired membership row could reorder).
        'community_members': [
          {
            'community_id': 'c1',
            'firebase_uid': 'u2',
            'role': 'member',
            'joined_at': '2026-11-20T10:00:00.000Z',
          },
          {
            'community_id': 'c1',
            'firebase_uid': 'u3',
            'role': 'member',
            'joined_at': '2026-11-20T11:00:00.000Z',
          },
          {
            'community_id': 'c1',
            'firebase_uid': 'u1',
            'role': 'creator',
            'joined_at': '2026-11-21T10:00:00.000Z',
          },
          {
            'community_id': 'c2',
            'firebase_uid': 'u9',
            'role': 'creator',
            'joined_at': '2026-11-20T10:00:00.000Z',
          },
        ],
      };
      final all = await CommunityGroups.members('c1');
      expect(all.length, 3);
      expect(all[0]['firebase_uid'], 'u1');
      expect(all[0]['role'], 'creator');
      final page1 = await CommunityGroups.members('c1', limit: 2);
      expect(page1.length, 2);
      final page2 =
          await CommunityGroups.members('c1', offset: 2, limit: 2);
      expect(page2.length, 1);
      expect(page2[0]['firebase_uid'], 'u1');
      expect(await CommunityGroups.members(''), isEmpty);
    });
  });

  group('Community voice (2026-11-22 user order)', () {
    test('communityRoomId follows the room-id scheme', () {
      expect(communityRoomId('abc'), 'community_abc');
      expect(communityRoomId(''), 'community_');
    });

    testWidgets('detail page mounts the panel immediately (member, FIX 23 items 1+16a)',
        (tester) async {
      // Tall viewport: the always-mounted panel + chat overflow
      // the default 600px height (G6 pattern).
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await signIn();
      SupaDb.testFixtures = {
        'communities': [
          {
            'id': 'c1',
            'name': 'PUBG Pros',
            'description': 'Best players only',
            'photo_url': '',
            'created_by_uid': 'u9',
            'voice_enabled': true,
            'created_at': '2026-11-21T10:00:00.000Z',
          },
        ],
        'community_members': [
          {
            'community_id': 'c1',
            'firebase_uid': 'u1',
            'role': 'member',
            'joined_at': '2026-11-21T10:00:00.000Z',
          },
        ],
        'community_posts': [],
      };

      await tester.pumpWidget(
        MaterialApp(
          home: CommunityDetailPage(
            uid: 'u1',
            communityId: 'c1',
            community: const {
              'id': 'c1',
              'name': 'PUBG Pros',
              'description': 'Best players only',
              'photo_url': '',
              'created_by_uid': 'u9',
              'voice_enabled': true,
              'isMember': true,
              'myRole': 'member',
              'memberCount': 1,
            },
          ),
        ),
      );
      await settle(tester);

      // FIX 23 items 1+16a: no top bar, no Voice toggle to tap —
      // the panel is mounted the moment the page opens.
      expect(find.text('Voice'), findsNothing);
      expect(find.text('More'), findsNothing);
      expect(find.byType(UnifiedRoomPage), findsOneWidget);
      // Member state survived the fixture refresh (Following in
      // the sidebar pill — FIX 23 item 9 moved Follow there from
      // the deleted More menu).
      expect(find.text('Following'), findsOneWidget);
      expect(find.text('Unfollow'), findsNothing);
    });

    testWidgets('non-member sees the Follow-to-join banner, no panel (FIX 23 items 1+16a)',
        (tester) async {
      SupaDb.testFixtures = {
        'communities': [
          {
            'id': 'c1',
            'name': 'PUBG Pros',
            'description': '',
            'photo_url': '',
            'created_by_uid': 'u9',
            'voice_enabled': true,
            'created_at': '2026-11-21T10:00:00.000Z',
          },
        ],
        'community_members': [],
        'community_posts': [],
      };

      await tester.pumpWidget(
        MaterialApp(
          home: CommunityDetailPage(
            uid: 'u1',
            communityId: 'c1',
            community: const {
              'id': 'c1',
              'name': 'PUBG Pros',
              'description': '',
              'photo_url': '',
              'created_by_uid': 'u9',
              'voice_enabled': true,
              'isMember': false,
              'myRole': '',
              'memberCount': 0,
            },
          ),
        ),
      );
      await settle(tester);

      // FIX 23 items 1+16a: no Voice button to tap (no top bar)
      // and no gate toast — non-members get no voice panel at all
      // and the chat shows the Follow-to-join banner (Follow
      // itself lives on the community card, item 19).
      expect(find.text('Voice'), findsNothing);
      expect(find.byType(UnifiedRoomPage), findsNothing);
      expect(find.text('Chat karne ke liye pehle Follow karen.'),
          findsOneWidget);
      expect(
          find.text(
              'Pehle community join karen — voice sirf members ke liye hai.'),
          findsNothing);
      expect(find.text('Voice On'), findsNothing);
    });

    testWidgets('member without LiveKit config shows honest idle state (FIX 23 item 16a)',
        (tester) async {
      // Tall viewport: the mounted panel + seat grid overflow the
      // default 600px height (same reason as the G6 mesh test).
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      // The mounted room's VoiceRoom reads
      // FirebaseAuth.instance.currentUser! — sign in (fake uid
      // 'test-uid') so the mount does not throw [core/no-app].
      await signIn();
      SupaDb.testFixtures = {
        'communities': [
          {
            'id': 'c1',
            'name': 'PUBG Pros',
            'description': '',
            'photo_url': '',
            'created_by_uid': 'u9',
            'voice_enabled': true,
            'created_at': '2026-11-21T10:00:00.000Z',
          },
        ],
        'community_members': [
          {
            'community_id': 'c1',
            'firebase_uid': 'u1',
            'role': 'member',
            'joined_at': '2026-11-21T10:00:00.000Z',
          },
        ],
        'community_posts': [],
        // No app_settings fixture -> LiveKitConfig.load() fails
        // closed (isConfigured == false).
      };

      await tester.pumpWidget(
        MaterialApp(
          home: CommunityDetailPage(
            uid: 'u1',
            communityId: 'c1',
            community: const {
              'id': 'c1',
              'name': 'PUBG Pros',
              'description': '',
              'photo_url': '',
              'created_by_uid': 'u9',
              'voice_enabled': true,
              'isMember': true,
              'myRole': 'member',
              'memberCount': 1,
            },
          ),
        ),
      );
      // Manual pumps only (no pumpAndSettle): the mounted room's
      // animation controllers + the smoke layer trip fake-time
      // scheduler assertions when mixed with pumpAndSettle (seen
      // 2026-11-23; smoke added FIX 23 item 24).
      await settle(tester);

      // FIX 23 item 16a: no Voice button to tap — the panel is
      // already mounted. The room sits idle (honest 'Not
      // connected' pill) until the user joins a seat; the
      // join-failure path (error banner + Retry + 'Voice Failed')
      // is pinned by the G6 mesh/LiveKit tests. This test pins
      // the entry point: panel mounted, no fake 'Voice On', no
      // 'Connecting…' hang, no stale toast.
      expect(find.byType(UnifiedRoomPage), findsOneWidget);
      // Pill pins are scoped to the panel.
      final panel = find.byType(UnifiedRoomPage);
      expect(
          find.descendant(of: panel, matching: find.text('Not connected')),
          findsOneWidget);
      expect(
          find.descendant(of: panel, matching: find.text('Voice On')),
          findsNothing);
      expect(
          find.descendant(of: panel, matching: find.text('Connecting…')),
          findsNothing);
      expect(
          find.text(
              'Voice server abhi set nahi hai — admin se server set karwayen.'),
          findsNothing);
      // FIX 23 item 16a: the panel is STICKY — there is no close
      // path any more, so no unmount step (the old Voice On tap
      // is gone with the top bar).
      expect(find.text('Close voice'), findsNothing);
    });
  });

  group('Community voice approval — FIX 14 (backend handoff §1)', () {
    test('normCommunity maps voice_enabled, missing reads locked', () {
      final on = CommunityGroups.normCommunity(
          {'id': 'c1', 'name': 'X', 'voice_enabled': true});
      expect(on['voice_enabled'], true);
      expect(on['voiceEnabled'], true);
      final off = CommunityGroups.normCommunity(
          {'id': 'c1', 'name': 'X', 'voice_enabled': false});
      expect(off['voice_enabled'], false);
      // Old rows / old caches have no key — fail-closed (locked).
      final missing =
          CommunityGroups.normCommunity({'id': 'c1', 'name': 'X'});
      expect(missing['voice_enabled'], false);
      expect(missing['voiceEnabled'], false);
      // camelCase input also maps.
      final camel = CommunityGroups.normCommunity(
          {'id': 'c1', 'name': 'X', 'voiceEnabled': true});
      expect(camel['voice_enabled'], true);
    });

    test('isVoiceEnabled reads both key styles', () {
      expect(CommunityGroups.isVoiceEnabled({'voice_enabled': true}), true);
      expect(CommunityGroups.isVoiceEnabled({'voiceEnabled': true}), true);
      expect(
          CommunityGroups.isVoiceEnabled({'voice_enabled': false}), false);
      expect(CommunityGroups.isVoiceEnabled({}), false);
    });

    test('isOpenVoiceRequestStatus: pending/approved open, rejected not',
        () {
      expect(CommunityGroups.isOpenVoiceRequestStatus('pending'), true);
      expect(CommunityGroups.isOpenVoiceRequestStatus('approved'), true);
      expect(CommunityGroups.isOpenVoiceRequestStatus('rejected'), false);
      expect(CommunityGroups.isOpenVoiceRequestStatus(''), false);
    });

    test('canRequestVoiceAccess: creator + locked + no open request', () {
      expect(
          CommunityGroups.canRequestVoiceAccess(
              isCreator: true, voiceEnabled: false, requestStatus: ''),
          true);
      expect(
          CommunityGroups.canRequestVoiceAccess(
              isCreator: true,
              voiceEnabled: false,
              requestStatus: 'rejected'),
          true);
      expect(
          CommunityGroups.canRequestVoiceAccess(
              isCreator: true,
              voiceEnabled: false,
              requestStatus: 'pending'),
          false);
      expect(
          CommunityGroups.canRequestVoiceAccess(
              isCreator: true,
              voiceEnabled: false,
              requestStatus: 'approved'),
          false);
      expect(
          CommunityGroups.canRequestVoiceAccess(
              isCreator: true, voiceEnabled: true, requestStatus: ''),
          false);
      expect(
          CommunityGroups.canRequestVoiceAccess(
              isCreator: false, voiceEnabled: false, requestStatus: ''),
          false);
    });

    test('normVoiceRequest maps both key styles + ms timestamps', () {
      final m = CommunityGroups.normVoiceRequest({
        'id': 'vr-1',
        'community_id': 'c1',
        'requested_by': 'u1',
        'status': 'pending',
        'created_at': '2026-11-22T09:00:00.000Z',
      });
      expect(m['community_id'], 'c1');
      expect(m['requestedBy'], 'u1');
      expect(m['status'], 'pending');
      expect(m['createdAt'], greaterThan(0));
      expect(m['decidedBy'], '');
      expect(CommunityGroups.normVoiceRequest({}), isEmpty);
    });

    test('requestVoiceAccess: creator files, second call is idempotent',
        () async {
      SupaDb.testFixtures = {
        'communities': [
          {
            'id': 'c1',
            'name': 'PUBG Pros',
            'created_by_uid': 'u1',
            'voice_enabled': false,
            'created_at': '2026-11-21T10:00:00.000Z',
          },
        ],
        'community_voice_requests': [],
      };
      final first = await CommunityGroups.requestVoiceAccess(
          communityId: 'c1', requesterUid: 'u1');
      expect(first['ok'], true);
      expect(first['status'], 'pending');
      expect(SupaDb.testFixtures!['community_voice_requests']!.length, 1);
      // Second request while pending: returns the existing state,
      // no second row (the unique-index conflict, handled).
      final second = await CommunityGroups.requestVoiceAccess(
          communityId: 'c1', requesterUid: 'u1');
      expect(second['ok'], true);
      expect(second['already'], true);
      expect(second['status'], 'pending');
      expect(SupaDb.testFixtures!['community_voice_requests']!.length, 1);
      expect(await CommunityGroups.voiceRequestStatus('c1'), 'pending');
    });

    test('requestVoiceAccess: non-creator is refused', () async {
      SupaDb.testFixtures = {
        'communities': [
          {
            'id': 'c1',
            'name': 'PUBG Pros',
            'created_by_uid': 'u9',
            'voice_enabled': false,
            'created_at': '2026-11-21T10:00:00.000Z',
          },
        ],
        'community_voice_requests': [],
      };
      final res = await CommunityGroups.requestVoiceAccess(
          communityId: 'c1', requesterUid: 'u1');
      expect(res['ok'], false);
      expect(SupaDb.testFixtures!['community_voice_requests']!, isEmpty);
    });

    test('requestVoiceAccess: unlocked community reports already-approved',
        () async {
      SupaDb.testFixtures = {
        'communities': [
          {
            'id': 'c1',
            'name': 'PUBG Pros',
            'created_by_uid': 'u1',
            'voice_enabled': true,
            'created_at': '2026-11-21T10:00:00.000Z',
          },
        ],
        'community_voice_requests': [],
      };
      final res = await CommunityGroups.requestVoiceAccess(
          communityId: 'c1', requesterUid: 'u1');
      expect(res['ok'], true);
      expect(res['already'], true);
      expect(res['status'], 'approved');
      expect(SupaDb.testFixtures!['community_voice_requests']!, isEmpty);
    });

    test('voiceRequestStatus: none / pending / rejected', () async {
      SupaDb.testFixtures = {
        'community_voice_requests': [
          {
            'id': 'vr-1',
            'community_id': 'c2',
            'requested_by': 'u1',
            'status': 'rejected',
            'created_at': '2026-11-22T08:00:00.000Z',
          },
          {
            'id': 'vr-2',
            'community_id': 'c3',
            'requested_by': 'u1',
            'status': 'pending',
            'created_at': '2026-11-22T09:00:00.000Z',
          },
        ],
      };
      expect(await CommunityGroups.voiceRequestStatus('c1'), '');
      expect(await CommunityGroups.voiceRequestStatus('c2'), 'rejected');
      expect(await CommunityGroups.voiceRequestStatus('c3'), 'pending');
      expect(await CommunityGroups.voiceRequestStatus(''), '');
    });

    test('listPendingVoiceRequests: pending only, oldest first, with names',
        () async {
      SupaDb.testFixtures = {
        'communities': [
          {
            'id': 'c1',
            'name': 'PUBG Pros',
            'created_by_uid': 'u1',
            'created_at': '2026-11-21T10:00:00.000Z',
          },
          {
            'id': 'c2',
            'name': 'FF Squad',
            'created_by_uid': 'u2',
            'created_at': '2026-11-21T10:00:00.000Z',
          },
        ],
        'community_voice_requests': [
          {
            'id': 'vr-2',
            'community_id': 'c2',
            'requested_by': 'u2',
            'status': 'pending',
            'created_at': '2026-11-22T09:30:00.000Z',
          },
          {
            'id': 'vr-1',
            'community_id': 'c1',
            'requested_by': 'u1',
            'status': 'pending',
            'created_at': '2026-11-22T09:00:00.000Z',
          },
          {
            'id': 'vr-3',
            'community_id': 'c1',
            'requested_by': 'u1',
            'status': 'rejected',
            'created_at': '2026-11-22T08:00:00.000Z',
          },
        ],
      };
      final pending = await CommunityGroups.listPendingVoiceRequests();
      expect(pending.length, 2);
      expect(pending[0]['id'], 'vr-1'); // oldest first
      expect(pending[0]['community_name'], 'PUBG Pros');
      expect(pending[1]['communityName'], 'FF Squad');
    });

    test('approveVoiceRequest: approves AND unlocks voice; idempotent',
        () async {
      SupaDb.testFixtures = {
        'communities': [
          {
            'id': 'c1',
            'name': 'PUBG Pros',
            'created_by_uid': 'u1',
            'voice_enabled': false,
            'created_at': '2026-11-21T10:00:00.000Z',
          },
        ],
        'community_voice_requests': [
          {
            'id': 'vr-1',
            'community_id': 'c1',
            'requested_by': 'u1',
            'status': 'pending',
            'created_at': '2026-11-22T09:00:00.000Z',
          },
        ],
      };
      final res = await CommunityGroups.approveVoiceRequest(
          requestId: 'vr-1', adminUid: 'admin1');
      expect(res['ok'], true);
      expect(res['community_id'], 'c1');
      final req = SupaDb.testFixtures!['community_voice_requests']!.first;
      expect(req['status'], 'approved');
      expect(req['decided_by'], 'admin1');
      expect(req['decided_at'], isNotEmpty);
      // Second write: the community flag flipped.
      expect(SupaDb.testFixtures!['communities']!.first['voice_enabled'],
          true);
      expect(await CommunityGroups.voiceRequestStatus('c1'), 'approved');
      // Approving again stays ok (idempotent repair path).
      final again = await CommunityGroups.approveVoiceRequest(
          requestId: 'vr-1', adminUid: 'admin1');
      expect(again['ok'], true);
      // An approved request can no longer be rejected.
      final rej = await CommunityGroups.rejectVoiceRequest(
          requestId: 'vr-1', adminUid: 'admin1');
      expect(rej['ok'], false);
    });

    test('approveVoiceRequest: rejected request cannot be approved',
        () async {
      SupaDb.testFixtures = {
        'communities': [
          {
            'id': 'c1',
            'name': 'PUBG Pros',
            'created_by_uid': 'u1',
            'voice_enabled': false,
            'created_at': '2026-11-21T10:00:00.000Z',
          },
        ],
        'community_voice_requests': [
          {
            'id': 'vr-1',
            'community_id': 'c1',
            'requested_by': 'u1',
            'status': 'rejected',
            'created_at': '2026-11-22T09:00:00.000Z',
          },
        ],
      };
      final res = await CommunityGroups.approveVoiceRequest(
          requestId: 'vr-1', adminUid: 'admin1');
      expect(res['ok'], false);
      expect(SupaDb.testFixtures!['communities']!.first['voice_enabled'],
          false);
    });

    test(
        'rejectVoiceRequest: rejects, voice stays locked, re-request possible',
        () async {
      SupaDb.testFixtures = {
        'communities': [
          {
            'id': 'c1',
            'name': 'PUBG Pros',
            'created_by_uid': 'u1',
            'voice_enabled': false,
            'created_at': '2026-11-21T10:00:00.000Z',
          },
        ],
        'community_voice_requests': [
          {
            'id': 'vr-1',
            'community_id': 'c1',
            'requested_by': 'u1',
            'status': 'pending',
            'created_at': '2026-11-22T09:00:00.000Z',
          },
        ],
      };
      final res = await CommunityGroups.rejectVoiceRequest(
          requestId: 'vr-1', adminUid: 'admin1');
      expect(res['ok'], true);
      expect(res['status'], 'rejected');
      final req = SupaDb.testFixtures!['community_voice_requests']!.first;
      expect(req['status'], 'rejected');
      expect(req['decided_by'], 'admin1');
      expect(SupaDb.testFixtures!['communities']!.first['voice_enabled'],
          false);
      expect(await CommunityGroups.voiceRequestStatus('c1'), 'rejected');
      // Rejecting again stays ok (already).
      final again = await CommunityGroups.rejectVoiceRequest(
          requestId: 'vr-1', adminUid: 'admin1');
      expect(again['ok'], true);
      expect(again['already'], true);
      // Re-request after reject: allowed — a NEW pending row appears.
      final re = await CommunityGroups.requestVoiceAccess(
          communityId: 'c1', requesterUid: 'u1');
      expect(re['ok'], true);
      expect(re['already'], isNot(true));
      expect(SupaDb.testFixtures!['community_voice_requests']!.length, 2);
      expect(await CommunityGroups.voiceRequestStatus('c1'), 'pending');
    });

    test('approve/reject: unknown request + empty ids fail closed', () async {
      SupaDb.testFixtures = {
        'communities': [],
        'community_voice_requests': [],
      };
      expect(
          (await CommunityGroups.approveVoiceRequest(
              requestId: 'nope', adminUid: 'admin1'))['ok'],
          false);
      expect(
          (await CommunityGroups.rejectVoiceRequest(
              requestId: 'nope', adminUid: 'admin1'))['ok'],
          false);
      expect(
          (await CommunityGroups.approveVoiceRequest(
              requestId: '', adminUid: 'admin1'))['ok'],
          false);
      expect(
          (await CommunityGroups.requestVoiceAccess(
              communityId: '', requesterUid: 'u1'))['ok'],
          false);
    });

    testWidgets('locked community: creator sees request button, files request',
        (tester) async {
      // Tall viewport: the always-mounted panel + banner + chat
      // overflow the default 600px height (G6 pattern).
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await signIn();
      SupaDb.testFixtures = {
        'communities': [
          {
            'id': 'c1',
            'name': 'PUBG Pros',
            'description': '',
            'photo_url': '',
            'created_by_uid': 'u1',
            'voice_enabled': false,
            'created_at': '2026-11-21T10:00:00.000Z',
          },
        ],
        'community_members': [
          {
            'community_id': 'c1',
            'firebase_uid': 'u1',
            'role': 'creator',
            'joined_at': '2026-11-21T10:00:00.000Z',
          },
        ],
        'community_posts': [],
        'community_voice_requests': [],
      };

      await tester.pumpWidget(
        MaterialApp(
          home: CommunityDetailPage(
            uid: 'u1',
            communityId: 'c1',
            community: const {
              'id': 'c1',
              'name': 'PUBG Pros',
              'description': '',
              'photo_url': '',
              'created_by_uid': 'u1',
              'voice_enabled': false,
              'isMember': true,
              'myRole': 'creator',
              'memberCount': 1,
            },
          ),
        ),
      );
      await settle(tester);

      // Locked: banner + creator-only request button. FIX 23
      // items 1+16a: no top bar, so no 'Locked' header button —
      // and the panel is mounted even while locked (sticky).
      expect(find.text('Locked'), findsNothing);
      expect(find.text('Voice'), findsNothing);
      expect(find.text('Voice locked hai — admin approval ke baad milegi.'),
          findsOneWidget);
      expect(find.text('REQUEST VOICE ACCESS'), findsOneWidget);
      expect(find.byType(UnifiedRoomPage), findsOneWidget);

      await tester.tap(find.text('REQUEST VOICE ACCESS'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      expect(
          find.text(
              'Voice request bhej di gayi — admin approval ka intezar karen.'),
          findsOneWidget);
      expect(SupaDb.testFixtures!['community_voice_requests']!.length, 1);

      // After settle the banner flips to the pending state.
      await settle(tester);
      expect(
          find.text(
              'Voice request pending hai — admin approval ka intezar karen.'),
          findsOneWidget);
      expect(find.text('PENDING'), findsOneWidget);
      expect(find.text('REQUEST VOICE ACCESS'), findsNothing);
    });

    testWidgets('locked community: non-creator sees lock, no request button',
        (tester) async {
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await signIn();
      SupaDb.testFixtures = {
        'communities': [
          {
            'id': 'c1',
            'name': 'PUBG Pros',
            'description': '',
            'photo_url': '',
            'created_by_uid': 'u9',
            'voice_enabled': false,
            'created_at': '2026-11-21T10:00:00.000Z',
          },
        ],
        'community_members': [
          {
            'community_id': 'c1',
            'firebase_uid': 'u1',
            'role': 'member',
            'joined_at': '2026-11-21T10:00:00.000Z',
          },
        ],
        'community_posts': [],
        'community_voice_requests': [],
      };

      await tester.pumpWidget(
        MaterialApp(
          home: CommunityDetailPage(
            uid: 'u1',
            communityId: 'c1',
            community: const {
              'id': 'c1',
              'name': 'PUBG Pros',
              'description': '',
              'photo_url': '',
              'created_by_uid': 'u9',
              'voice_enabled': false,
              'isMember': true,
              'myRole': 'member',
              'memberCount': 1,
            },
          ),
        ),
      );
      await settle(tester);

      // FIX 23 item 1: no 'Locked' header button any more — the
      // lock shows as the banner only.
      expect(find.text('Locked'), findsNothing);
      expect(find.text('Voice locked hai — admin approval ke baad milegi.'),
          findsOneWidget);
      expect(find.text('REQUEST VOICE ACCESS'), findsNothing);
      // Tapping the banner shows the lock message, never a sheet.
      await tester.tap(
          find.text('Voice locked hai — admin approval ke baad milegi.'));
      await tester.pump();
      expect(find.text('Voice abhi lock hai — admin approval ke baad milegi.'),
          findsOneWidget);
      expect(find.text('SEND VOICE REQUEST'), findsNothing);
    });

    testWidgets('locked community: creator taps banner, request sheet opens',
        (tester) async {
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await signIn();
      SupaDb.testFixtures = {
        'communities': [
          {
            'id': 'c1',
            'name': 'PUBG Pros',
            'description': '',
            'photo_url': '',
            'created_by_uid': 'u1',
            'voice_enabled': false,
            'created_at': '2026-11-21T10:00:00.000Z',
          },
        ],
        'community_members': [
          {
            'community_id': 'c1',
            'firebase_uid': 'u1',
            'role': 'creator',
            'joined_at': '2026-11-21T10:00:00.000Z',
          },
        ],
        'community_posts': [],
        'community_voice_requests': [],
      };

      await tester.pumpWidget(
        MaterialApp(
          home: CommunityDetailPage(
            uid: 'u1',
            communityId: 'c1',
            community: const {
              'id': 'c1',
              'name': 'PUBG Pros',
              'description': '',
              'photo_url': '',
              'created_by_uid': 'u1',
              'voice_enabled': false,
              'isMember': true,
              'myRole': 'creator',
              'memberCount': 1,
            },
          ),
        ),
      );
      await settle(tester);

      // FIX 23 item 1: no 'Locked' header button — the request
      // sheet opens from tapping the lock banner itself.
      await tester.tap(
          find.text('Voice locked hai — admin approval ke baad milegi.'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Voice Locked hai'), findsOneWidget);
      expect(find.text('SEND VOICE REQUEST'), findsOneWidget);

      await tester.tap(find.text('SEND VOICE REQUEST'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      expect(
          find.text(
              'Voice request bhej di gayi — admin approval ka intezar karen.'),
          findsOneWidget);
      expect(SupaDb.testFixtures!['community_voice_requests']!.length, 1);
    });
  });
}

// --- Fake Firebase platforms (copied from fix12_g6_voice_room_test.dart) ---

// ---- Fake Firebase (exact pattern from device_ban_gate_test) ----

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
