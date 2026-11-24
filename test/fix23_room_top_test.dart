// FIX 23 — ROOM TOP REDESIGN (items 1-6, 9, 11-14, 16, 17).
// Source pins + widget tests at 360px. The top bar is gone, the
// host card is the top full-width element with the community name
// inside, the sidebar sits below it with neon buttons + Follow
// pill + Power, mic seats are tighter + speaking-gated, the
// default room background is the app-wide image, the host slot
// shows ONLY the organizer (or 'No host'), and the word
// "Members" appears nowhere in the room.

import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_auth_platform_interface/firebase_auth_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/screens/room_screen.dart';
import 'package:protournament_user/services/supabase_db.dart';
import 'package:protournament_user/theme.dart';
import 'package:protournament_user/widgets/arena_ui.dart';
import 'package:protournament_user/widgets/voice_settings_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'audio_test_helpers.dart';

String _region(String src, String start, String end) {
  final s = src.indexOf(start);
  if (s < 0) return '';
  final e = src.indexOf(end, s + start.length);
  if (e < 0) return '';
  return src.substring(s, e);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('fix23 items 1+4 — top bar gone, Settings merge (source)', () {
    late String comm;
    late String detail;

    setUpAll(() {
      comm = codeOnly(
          requireProjectFile('lib/screens/communities_screens.dart'));
      detail = _region(comm, 'class _CommunityDetailPageState',
          'class _FollowToInteractBanner');
    });

    test('detail region exists', () {
      expect(detail, isNotEmpty);
    });

    test('item 1: NO AppBar in the detail page', () {
      expect(detail, isNot(contains('appBar:')));
      expect(detail, isNot(contains('_onHeaderMore')));
      expect(detail, isNot(contains('_headerCircleButton')));
      expect(detail, isNot(contains('_toggleVoicePanel')));
      // The whole file keeps exactly 5 AppBars (list, create,
      // members, My Community, Edit) — none of them the room.
      final count = 'appBar: AppBar('.allMatches(comm).length;
      expect(count, 5);
    });

    test('item 1: voice panel is ALWAYS mounted for members', () {
      expect(detail, contains('if (_isMember) _buildVoicePanel()'));
      expect(detail, isNot(contains('_voicePanelOpen')));
    });

    test('item 4: sidebar Settings opens the merged sheet', () {
      expect(detail, contains('showCommunitySettingsSheet('));
      expect(detail, contains('onAbout:'));
      expect(detail, contains('onInvite:'));
      expect(detail, contains('onCopyName:'));
      expect(detail, contains('onMyCommunity:'));
      expect(detail, contains('onClearChat:'));
      expect(detail, contains('onDeleteCommunity:'));
    });

    test('item 4: merged sheet has every entry, no Speaker/Follow', () {
      final sheet = codeOnly(
          requireProjectFile('lib/widgets/voice_settings_sheet.dart'));
      final region = _region(sheet, 'class CommunitySettingsSheet',
          'Future<void> showCommunitySettingsSheet(');
      expect(region, isNotEmpty);
      for (final entry in [
        'About',
        'Invite',
        'Copy community name',
        'My Community',
        'Clear chat history',
        'Delete community',
        'JOINED',
        'Backgrounds',
        'Frames',
        'Participants',
        'Voice diagnostics',
        'Voice test',
        'Cheer',
        'RJ Studio',
      ]) {
        expect(region, contains(entry), reason: 'missing entry: $entry');
      }
      expect(region, isNot(contains('Speaker')));
      expect(region, isNot(contains("'Follow'")));
      expect(region, isNot(contains('Close voice')));
    });
  });

  group('fix23 items 2+3+12+16+17 — host card (source)', () {
    late String room;
    late String strip;

    setUpAll(() {
      room = codeOnly(requireProjectFile('lib/screens/room_screen.dart'));
      strip = _region(
        room,
        'Widget _buildHostStrip(',
        'Widget _buildHostLiveColumn(',
      );
    });

    test('host strip region exists', () {
      expect(strip, isNotEmpty);
    });

    test('item 2: compact card is two rows (no LayoutBuilder)', () {
      // FIX 23 SUPERSEDES the v2022 Gate-1 LayoutBuilder mechanism:
      // the zero-overflow-at-360px PROPERTY holds via the full-width
      // two-row + Wrap design instead (pinned by widget tests).
      expect(strip, isNot(contains('LayoutBuilder')));
      expect(strip, contains('_buildHostStatusStrip('));
    });

    test('item 2: card keeps Host pill + avatar + mic + Live', () {
      expect(strip, contains("'Host'"));
      expect(strip, contains('_buildHostMicButton('));
      expect(strip, contains('_buildHostStatusStrip('));
      expect(strip, contains('MockupCard('));
      expect(strip, contains('animate: false'));
    });

    test('item 3: community name next to Host + image thumb', () {
      expect(strip, contains('scopeName'));
      expect(strip, contains('ArenaCachedImage('));
      expect(strip, contains('Icons.emoji_events'));
    });

    test('item 12b: NO members button / "members" text in the card', () {
      expect(strip, isNot(contains('hostCardTotalMembers')));
      expect(strip, isNot(contains('hostCardOnlineMembers')));
      expect(strip, isNot(contains('onHostCardMembersPressed')));
      expect(strip, isNot(contains(' members')));
      expect(strip, isNot(contains('Members')));
    });

    test('item 12c: live cluster = Live pill + listeners row', () {
      expect(room, contains('Widget _buildLivePill()'));
      expect(room, contains('Widget _buildListenersRow()'));
      expect(room, contains('_liveListeners.listenerCount'));
      expect(room, contains('Icons.headset'));
    });

    test('item 16b: host mic gated on _voiceConnected, no toast', () {
      final mic = _region(room, 'Widget _buildHostMicButton(',
          'Widget _buildConnectingPill()');
      expect(mic, isNotEmpty);
      expect(mic, contains('final gated = !_voiceConnected;'));
      // The ternary is split across lines in code: pin the parts.
      expect(mic, contains('onTap: gated'));
      expect(mic, contains('? null'));
      expect(mic, contains('Opacity(opacity: 0.5'));
      // The gate itself adds NO toast (the toasts still in this
      // region are the pre-existing host-not-on-voice / other-mic
      // info toasts, not the fix20 gate toast).
      expect(mic, isNot(contains('Voice connected nahi hai')));
      // The fix20 toast still exists for SEAT taps only.
      expect(room, contains('Voice connected nahi hai'));
    });

    test('item 17: host slot is organizer-only, "No host" fallback', () {
      // Scope to _hostEntry itself (next method is _stageCellFree)
      // — _adminUid legitimately appears later in _loadRoomAdmin.
      final entry =
          _region(room, '_hostEntry', 'Widget _stageCellFree(');
      expect(entry, isNotEmpty);
      // Organizer-only: empty organizer -> null; a peer is used
      // only when its key IS the organizer.
      expect(entry, contains('if (organizer.isEmpty) return null;'));
      expect(entry, contains('if (e.key == organizer) return'));
      expect(entry, isNot(contains('occupied.first')));
      expect(entry, isNot(contains('_adminUid')));
      // 'No host' is rendered by the strip when _hostEntry is null.
      expect(strip, contains("'No host'"));
    });

    test('item 16a: voiceLocked blocks join + shows locked line', () {
      expect(room, contains('if (widget.voiceLocked) return;'));
      expect(room, contains('_buildVoiceLockedLine()'));
      expect(room, contains('Voice locked'));
    });
  });

  group('fix23 items 5+6+9+11+13 — sidebar, neon, seats (source)', () {
    late String room;

    setUpAll(() {
      room = codeOnly(requireProjectFile('lib/screens/room_screen.dart'));
    });

    test('item 6: neon palette consts exist', () {
      for (final hex in [
        '0xFFFF2E88',
        '0xFF00E5FF',
        '0xFFB537F2',
        '0xFF39FF88',
        '0xFFFF5C39',
        '0xFFC026D3',
      ]) {
        expect(room, contains(hex), reason: 'missing neon: $hex');
      }
    });

    test('item 5+9+11: sidebar has 6 entries incl. Follow pill + Power', () {
      final side = _region(
          room, 'Widget _buildEmbeddedSidebar(', 'Widget _sidebarRoundBtn(');
      expect(side, isNotEmpty);
      for (final label in [
        "'Followers'",
        "'Music'",
        "'RJ Panel'",
        "'Settings'",
        "'Leave Room'",
        "'Power'",
      ]) {
        expect(side, contains(label), reason: 'missing sidebar entry: $label');
      }
      expect(room, contains('Widget _buildSidebarFollowPill()'));
      expect(room, contains("sidebarCommunityCount"));
    });

    test('item 13a: tighter seat spacing', () {
      expect(room, contains('mainAxisSpacing: 4'));
      expect(room, contains('crossAxisSpacing: 6'));
    });

    test('item 13b: pulse is speaking-gated, not mic-on-gated', () {
      expect(room, contains("final speaking = e.value['speaking'] == true;"));
      // _PulseGlow call is multi-line in code: pin the parts.
      expect(room, contains('_PulseGlow('));
      expect(room, contains('active: speaking,'));
      expect(room, isNot(contains('active: unmuted')));
    });

    test('item 14+21: default room background is the app image', () {
      expect(room, contains('bool _bgUserPicked = false;'));
      expect(room, contains('AppBackgroundLayer(respectLightMode: false)'));
      expect(room, contains("if (!_bgUserPicked)"));
    });
  });

  group('fix23 room — widget tests at 360px', () {
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
      await _loadRoboto();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('arena_hub_dsp_mic'),
              (MethodCall call) async {
                if (call.method == 'isAvailable') return false;
                return null;
              });
    });

    setUp(() async {
      await FirebaseAuth.instance
          .signInWithEmailAndPassword(email: 't@t.com', password: 'password');
      SupaDb.testFixtures = _fixtures();
      SupaDb.appBackgroundUrl.value = '';
    });

    tearDown(() async {
      SupaDb.testFixtures = null;
      SupaDb.appBackgroundUrl.value = '';
      await FirebaseAuth.instance.signOut();
    });

    Future<void> pumpRoom(WidgetTester tester,
        {bool? sidebarFollowing, VoidCallback? onFollowToggle}) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = VoicePanelController();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: UnifiedRoomPage(
            scope: 'community',
            communityId: 'comm-1',
            communityName: 'TEST COMMUNITY',
            organizerUid: 'test-uid',
            micCount: 6,
            embedded: true,
            voiceController: controller,
            sidebarCommunityCount: 4,
            sidebarFollowing: sidebarFollowing,
            onSidebarFollowToggle: onFollowToggle,
          ),
        ),
      ));
      await tester.pump();
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
    }

    testWidgets('item 2: host card is top + full width + shorter than 151px',
        (tester) async {
      await pumpRoom(tester, sidebarFollowing: null);
      final cards = tester.widgetList<MockupCard>(find.byType(MockupCard));
      expect(cards, isNotEmpty);
      final cardFinder = find.byType(MockupCard).first;
      final top = tester.getTopLeft(cardFinder).dy;
      final size = tester.getSize(cardFinder);
      expect(top, lessThanOrEqualTo(8.0));
      // Full width minus the 12px side margins.
      expect(size.width, greaterThanOrEqualTo(330.0));
      // Shorter than the measured v2022 card (151px).
      expect(size.height, lessThan(135.0));
      expect(tester.takeException(), isNull);
    });

    testWidgets('item 3: community name inside the host card',
        (tester) async {
      await pumpRoom(tester, sidebarFollowing: null);
      expect(find.text('TEST COMMUNITY'), findsOneWidget);
      expect(find.text('Host'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('item 5: sidebar starts BELOW the host card',
        (tester) async {
      await pumpRoom(tester, sidebarFollowing: null);
      final cardBottom =
          tester.getBottomRight(find.byType(MockupCard).first).dy;
      final followersTop = tester.getTopLeft(find.text('Followers')).dy;
      expect(followersTop, greaterThan(cardBottom));
      expect(tester.takeException(), isNull);
    });

    testWidgets('item 9: creator sees JOINED, member sees Follow pill',
        (tester) async {
      // The pill only renders when the follow callback is wired
      // (community scope always wires it; team scope passes null).
      await pumpRoom(tester,
          sidebarFollowing: null, onFollowToggle: () {});
      expect(find.text('JOINED'), findsOneWidget);
      expect(find.text('Follow'), findsNothing);

      var tapped = false;
      await pumpRoom(tester,
          sidebarFollowing: false, onFollowToggle: () => tapped = true);
      expect(find.text('Follow'), findsOneWidget);
      await tester.tap(find.text('Follow'));
      await tester.pump();
      expect(tapped, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('item 11: Power entry shows Off when music is stopped',
        (tester) async {
      await pumpRoom(tester, sidebarFollowing: null);
      expect(find.text('Power'), findsOneWidget);
      expect(find.text('Off'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('item 12b: no "Members" text anywhere in the room',
        (tester) async {
      await pumpRoom(tester, sidebarFollowing: null);
      final hits = find.byWidgetPredicate((w) =>
          w is Text &&
          (w.data?.toLowerCase().contains('member') ?? false));
      expect(hits, findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('item 14+21: default background image layer renders',
        (tester) async {
      await pumpRoom(tester, sidebarFollowing: null);
      expect(find.byType(AppBackgroundLayer), findsOneWidget);
      expect(find.byKey(const ValueKey('app_bg_scrim')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('item 17: host offline shows "No host" + no member photo',
        (tester) async {
      await pumpRoom(tester, sidebarFollowing: null);
      expect(find.text('No host'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('zero overflow at 360px with the sidebar present',
        (tester) async {
      await pumpRoom(tester, sidebarFollowing: false);
      expect(tester.takeException(), isNull);
      // Every sidebar label fits on screen.
      for (final label in [
        'Followers',
        'Music',
        'RJ Panel',
        'Settings',
        'Leave Room',
        'Power',
      ]) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
    });
  });

  group('fix23 item 4 — CommunitySettingsSheet widget', () {
    testWidgets('merged sheet shows all entries, no Speaker/Follow',
        (tester) async {
      var aboutTapped = false;
      // RJ Studio only shows when the host binding says so.
      final controller = VoicePanelController()
        ..bind(rjVisible: () => true);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showCommunitySettingsSheet(
                context,
                controller,
                isMember: true,
                isCreator: true,
                onAbout: () => aboutTapped = true,
                onInvite: () {},
                onCopyName: () {},
                onMyCommunity: () {},
                onClearChat: () {},
                onDeleteCommunity: () {},
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      for (final entry in [
        'About',
        'Invite',
        'Copy community name',
        'My Community',
        'Clear chat history',
        'Delete community',
        'JOINED',
        'Music',
        'Backgrounds',
        'Frames',
        'Participants / Status',
        'Voice diagnostics',
        'Voice test (LiveKit)',
        'Cheer (Free Points)',
        'RJ Studio',
      ]) {
        expect(find.text(entry), findsWidgets, reason: 'missing: $entry');
      }
      expect(find.text('Speaker'), findsNothing);
      expect(find.text('Follow'), findsNothing);
      expect(find.text('Close voice'), findsNothing);
      await tester.tap(find.text('About'));
      await tester.pump();
      expect(aboutTapped, isTrue);
      expect(tester.takeException(), isNull);
    });
  });
}

Future<void> _loadRoboto() async {
  final home = Platform.environment['HOME'] ?? '';
  final dir = '$home/flutter/bin/cache/artifacts/material_fonts';
  final loader = FontLoader('Roboto');
  for (final file in [
    'Roboto-Regular.ttf',
    'Roboto-Medium.ttf',
    'Roboto-Bold.ttf',
    'Roboto-Black.ttf',
  ]) {
    final bytes = await File('$dir/$file').readAsBytes();
    loader.addFont(Future.value(bytes.buffer.asByteData()));
  }
  await loader.load();
}

Map<String, List<Map<String, dynamic>>> _fixtures() => {
      'communities': [
        {
          'id': 'comm-1',
          'name': 'TEST COMMUNITY',
          'description': 'Test community',
          'created_by_uid': 'test-uid',
          'voice_enabled': true,
          'isMember': true,
          'myRole': 'creator',
          'memberCount': 4,
        }
      ],
      'community_members': [
        {'community_id': 'comm-1', 'firebase_uid': 'test-uid', 'role': 'creator'}
      ],
      'community_voice_requests': [],
      'profiles': [
        {'firebase_uid': 'test-uid', 'display_name': 'Tester', 'level': 1}
      ],
      'admin_config': [
        {'id': 1, 'admin_firebase_uid': 'test-uid'}
      ],
      'chat_messages': [],
      'presence': [],
    };

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
        : _FakeUser(this, _FakeMultiFactor(this), currentUser);
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
