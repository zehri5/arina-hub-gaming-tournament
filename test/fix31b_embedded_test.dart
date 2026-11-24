// FIX 31b — EMBEDDED VOICE-PANEL ADAPTATION.
// The AI Studio design language applied to the INLINE voice panel
// (community detail + team chat): compact header strip (room title
// + LIVE + listeners), podium seat grid, re-skinned host card and
// sidebar — with NO Scaffold, NO chat, NO new screen, NO routing
// change. Every fix23 function must survive; the host pages are
// untouched in structure.

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
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:protournament_user/screens/arena_voice_room_screen.dart';
import 'package:protournament_user/screens/room_screen.dart';
import 'package:protournament_user/screens/status_sheet.dart';
import 'package:protournament_user/services/supabase_db.dart';
import 'package:protournament_user/widgets/arena_custom_graphics.dart';
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
  group('fix31b — header strip + podium header (source)', () {
    late String room;
    late String embedded;
    late String fix31b;

    setUpAll(() {
      room = codeOnly(requireProjectFile('lib/screens/room_screen.dart'));
      // Regions are cut from the RAW file (the section markers are
      // comment lines, which codeOnly strips), then codeOnly'd for
      // the content checks below.
      final raw = requireProjectFile('lib/screens/room_screen.dart');
      embedded = codeOnly(_region(
        raw,
        'Widget _buildEmbeddedVoice(',
        '// ─── FIX 31b:',
      ));
      fix31b = codeOnly(_region(
        raw,
        '// ─── FIX 31b:',
        '// ─── FIX 31:',
      ));
    });

    test('regions exist', () {
      expect(embedded, isNotEmpty);
      expect(fix31b, isNotEmpty);
    });

    test('header strip: cyber-notch + room title + LIVE + listeners', () {
      expect(fix31b, contains('Widget _fix31bHeaderStrip('));
      expect(fix31b, contains('LeftCyberNotchClipper()'));
      expect(fix31b, contains('_roomTitle'));
      expect(fix31b, contains('_buildLivePill()'));
      expect(fix31b, contains('_buildListenersRow()'));
      // LIVE is gated on the host being on voice (same rule as
      // the old status strip — never a LIVE badge on a dead room).
      expect(fix31b, contains('if (hostOnVoice)'));
      // The strip is wired into the panel between the host card
      // and the seats.
      expect(embedded, contains('_fix31bHeaderStrip(peers)'));
    });

    test('full-page title NEVER appears in the embedded panel', () {
      expect(embedded, isNot(contains('Arena Hub Voice Chat Room')));
      expect(embedded, isNot(contains('ARENA HUB VOICE CHAT ROOM')));
      expect(fix31b, isNot(contains('Arena Hub Voice Chat Room')));
      expect(fix31b, isNot(contains('ARENA HUB VOICE CHAT ROOM')));
    });

    test('podium header: Voice Seats + View All + cyber-notch', () {
      expect(fix31b, contains('Widget _fix31bPodiumHeader('));
      expect(fix31b, contains('LeftCyberNotchClipper()'));
      expect(fix31b, contains('RightCyberNotchClipper()'));
      expect(fix31b, contains("'Voice Seats (\$occupiedCount)'"));
      expect(fix31b, contains("'View All'"));
      expect(fix31b, contains('onTap: _openStatus'));
      // The grid calls it with the real seated count.
      expect(room, contains('_fix31bPodiumHeader(occupiedCount)'));
    });

    test('embedded panel: NO Scaffold, NO chat, NO new screen', () {
      expect(embedded, isNot(contains('Scaffold(')));
      expect(fix31b, isNot(contains('Scaffold(')));
      expect(fix31b, isNot(contains('ArenaVoiceRoomScreen(')));
      // No speaker/output routing reintroduced (fix22 item 7).
      expect(embedded, isNot(contains('peaker')));
      expect(fix31b, isNot(contains('peaker')));
    });

    test('no "Members" wording in the new panel code', () {
      expect(embedded, isNot(contains('Members')));
      expect(fix31b, isNot(contains('Members')));
    });

    test('routing unchanged: build() branch line is byte-identical', () {
      expect(room,
          contains('if (widget.embedded) return _buildEmbeddedVoice(uid, peers, kbOpen);'));
      expect(room, contains('return _buildArenaVoiceRoom(uid, peers);'));
    });

    test('fix31 adapter untouched', () {
      expect(room, contains('Widget _buildArenaVoiceRoom('));
      expect(room, contains('_fix31MapSeats('));
      expect(room, contains('_fix31SetMic('));
      expect(room, contains('_fix31MenuExtras('));
    });
  });

  group('fix31b — seats / mic / host survive (source)', () {
    late String room;

    setUpAll(() {
      room = codeOnly(requireProjectFile('lib/screens/room_screen.dart'));
    });

    test('seat assignment unchanged (seat_no 1..6, join-order fill)', () {
      final grid = _region(room, 'Widget _buildSeatGrid(',
          'Widget _buildConnectionFailedBanner()');
      expect(grid, isNotEmpty);
      expect(grid, contains("SupaDb.intOf(e.value['seat_no'])"));
      expect(grid, contains('peerForMicCell('));
      expect(grid, contains('final seatR = 20.0;'));
      expect(grid, contains('final seatExtent = 58.0;'));
      expect(grid, contains('mainAxisSpacing: 4'));
      expect(grid, contains('crossAxisSpacing: 6'));
      // 6 mic seats in both embedded scopes.
      expect(grid, contains('_teamMicCount'));
      expect(grid, contains('_communityMicCount'));
    });

    test('podium styling: disc painter + AI Studio frame colours', () {
      expect(room, contains('PodiumDiscPainter('));
      final grid = _region(room, 'Widget _buildSeatGrid(',
          'Widget _buildConnectionFailedBanner()');
      // Host gold / speaking pink / default electric blue.
      expect(grid, contains('ArenaColors.royalGold'));
      expect(grid, contains('ArenaColors.neonPink'));
      expect(grid, contains('ArenaColors.electricBlue'));
      expect(grid, contains('active: speaking && unmuted'));
      // Pulse is still speaking-gated (fix23 item 13b).
      expect(grid, contains("final speaking = e.value['speaking'] == true;"));
      expect(grid, contains('_PulseGlow('));
      expect(grid, contains('active: speaking,'));
      // Seat numbers still visible (v2016 FIX 6).
      expect(grid, contains('MicSeatNumberBadge(seatNo: i + 1)'));
    });

    test('free cell keeps its number (17px) + real tap path', () {
      final free = _region(room, 'Widget _stageCellFree(',
          'Widget _stageCellLocked(');
      expect(free, isNotEmpty);
      expect(free, contains("Text('\$seatNo'"));
      expect(free, contains('fontSize: 17'));
      expect(free, contains('_adminTakeMic(seatNo)'));
      expect(free, contains('_joinVoiceOpen()'));
      // AI Studio empty-seat look: plus glyph + podium disc.
      expect(free, contains('LucideIcons.plus'));
      expect(free, contains('PodiumDiscPainter('));
    });

    test('mic on/off: 16b gate + real toggle path survive', () {
      final mic = _region(room, 'Widget _buildHostMicButton(',
          'Widget _buildConnectingPill()');
      expect(mic, isNotEmpty);
      expect(mic, contains('final gated = !_voiceConnected;'));
      expect(mic, contains('onTap: gated'));
      expect(mic, contains('? null'));
      expect(mic, contains('Opacity(opacity: 0.5'));
      expect(mic, contains('_toggleOwnSeat()'));
      // Own-seat tap flips the real mic too.
      final grid = _region(room, 'Widget _buildSeatGrid(',
          'Widget _buildConnectionFailedBanner()');
      expect(grid, contains('await _toggleOwnSeat();'));
    });

    test('host slot: organizer-only + No host + item-19 tick', () {
      final strip = _region(room, 'Widget _buildHostStrip(',
          'Widget _buildHostLiveColumn(');
      expect(strip, contains("'No host'"));
      expect(strip, contains('_hostEntry('));
      expect(strip, contains('hostVerifiedTick('));
      expect(strip, contains('Icon(Icons.verified'));
      // AI Studio host-card look: Lucide crown + royal-gold pill.
      expect(strip, contains('LucideIcons.crown'));
      expect(strip, contains('ArenaColors.royalGold'));
      expect(strip, contains('ArenaTypography.heading(17)'));
    });

    test('listeners count is the real LiveListeners count', () {
      expect(room, contains('_liveListeners.listenerCount'));
      final listeners = _region(room, 'Widget _buildListenersRow()',
          'Widget _buildConnectedBox()');
      expect(listeners, contains('Icons.headset'));
    });

    test('sidebar keeps all 6 entries + Follow pill (the menu)', () {
      final side = _region(room, 'Widget _buildEmbeddedSidebar(',
          'Widget _sidebarRoundBtn(');
      expect(side, isNotEmpty);
      for (final label in [
        "'Followers'",
        "'Music'",
        "'RJ Panel'",
        "'Settings'",
        "'Leave Room'",
        "'Power'",
      ]) {
        expect(side, contains(label), reason: 'missing entry: $label');
      }
      expect(room, contains('Widget _buildSidebarFollowPill()'));
      expect(side, contains('widget.onSidebarFollowers'));
      expect(side, contains('widget.onSidebarMusic'));
      expect(side, contains('widget.onSidebarRjPanel'));
      expect(side, contains('widget.onSidebarSettings'));
      expect(side, contains('widget.onSidebarLeaveRoom'));
    });

    test('voice-locked line + banners survive', () {
      expect(room, contains('_buildVoiceLockedLine()'));
      expect(room, contains('Voice locked'));
      expect(room, contains('_buildRoomDisabledBanner()'));
      expect(room, contains('_buildVoiceConnectErrorBanner()'));
      expect(room, contains('_buildRequestBanners()'));
      expect(room, contains('_buildConnectionFailedBanner()'));
      expect(room, contains('_liveKitDroppedBanner()'));
    });
  });

  group('fix31b — STRICT gold (room_screen.dart)', () {
    test('no banned gold hex in any form', () {
      final room = codeOnly(requireProjectFile('lib/screens/room_screen.dart'));
      for (final hex in [
        'FFC800',
        'F5A900',
        'FFCC00',
        'FFE20A',
        'FFC400',
      ]) {
        expect(room.toUpperCase(), isNot(contains(hex)),
            reason: 'banned hex: $hex');
      }
      // No RGB (255,190,0) either.
      expect(room, isNot(contains('255, 190, 0')));
      expect(room, isNot(contains('255,190,0')));
    });

    test('FFD700 appears only via ArenaColors.royalGold', () {
      final room = requireProjectFile('lib/screens/room_screen.dart');
      // The design gold is a TOKEN here — no raw FFD700 literal
      // in the room file (the literal lives in arena_theme.dart).
      expect(room.toUpperCase(), isNot(contains('FFD700')));
      expect(room, contains('ArenaColors.royalGold'));
    });
  });

  group('fix31b — host pages unchanged in structure (source)', () {
    test('community detail mounts embedded, same wiring', () {
      final comm = codeOnly(
          requireProjectFile('lib/screens/communities_screens.dart'));
      final panel = _region(comm, 'Widget _buildVoicePanel()',
          'Widget build(BuildContext context) {');
      expect(panel, isNotEmpty);
      expect(panel, contains('UnifiedRoomPage('));
      expect(panel, contains("scope: 'community'"));
      expect(panel, contains('embedded: true'));
      expect(panel, contains('micCount: 6,'));
      expect(panel, contains('onSidebarFollowers:'));
      expect(panel, contains('onSidebarLeaveRoom:'));
      expect(comm, isNot(contains('_fix31b')));
      expect(comm, isNot(contains('ArenaVoiceRoomScreen')));
    });

    test('team chat mounts embedded, same wiring', () {
      final pro = codeOnly(
          requireProjectFile('lib/screens/pro_features.dart'));
      final panel = _region(pro, 'Widget _buildVoicePanel()',
          'void _onLockedVoiceTap()');
      expect(panel, isNotEmpty);
      expect(panel, contains('UnifiedRoomPage('));
      expect(panel, contains("scope: 'team'"));
      expect(panel, contains('embedded: true'));
      expect(panel, contains('onSidebarFollowers:'));
      expect(panel, contains('onSidebarLeaveRoom:'));
      expect(pro, isNot(contains('_fix31b')));
      expect(pro, isNot(contains('ArenaVoiceRoomScreen')));
    });
  });

  group('fix31b — embedded panel widget tests at 360px', () {
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
        {bool? sidebarFollowing,
        VoidCallback? onFollowToggle,
        VoidCallback? onFollowers,
        VoidCallback? onMusic,
        VoidCallback? onRjPanel,
        VoidCallback? onSettings,
        VoidCallback? onLeaveRoom,
        bool voiceLocked = false,
        String scope = 'community'}) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = VoicePanelController();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: scope == 'team'
              ? UnifiedRoomPage(
                  scope: 'team',
                  teamId: 'team-1',
                  teamName: 'TEST TEAM',
                  captainUid: 'test-uid',
                  micCount: 6,
                  embedded: true,
                  voiceController: controller,
                  voiceLocked: voiceLocked,
                  sidebarFollowersCount: 4,
                  sidebarFollowing: sidebarFollowing,
                  onSidebarFollowToggle: onFollowToggle,
                  onSidebarFollowers: onFollowers,
                  onSidebarMusic: onMusic,
                  onSidebarRjPanel: onRjPanel,
                  onSidebarSettings: onSettings,
                  onSidebarLeaveRoom: onLeaveRoom,
                )
              : UnifiedRoomPage(
                  scope: 'community',
                  communityId: 'comm-1',
                  communityName: 'TEST COMMUNITY',
                  organizerUid: 'test-uid',
                  micCount: 6,
                  embedded: true,
                  voiceController: controller,
                  voiceLocked: voiceLocked,
                  sidebarCommunityCount: 4,
                  sidebarFollowing: sidebarFollowing,
                  onSidebarFollowToggle: onFollowToggle,
                  onSidebarFollowers: onFollowers,
                  onSidebarMusic: onMusic,
                  onSidebarRjPanel: onRjPanel,
                  onSidebarSettings: onSettings,
                  onSidebarLeaveRoom: onLeaveRoom,
                ),
        ),
      ));
      await tester.pump();
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
    }

    Finder seatNumberFinder(String n) => find.byWidgetPredicate((w) =>
        w is Text && w.data == n && w.style?.fontSize == 17);

    testWidgets('panel mounts at 360px, no overflow, no exception',
        (tester) async {
      await pumpRoom(tester, sidebarFollowing: null);
      expect(find.byType(UnifiedRoomPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('header strip: room title + listeners, no LIVE offline',
        (tester) async {
      await pumpRoom(tester, sidebarFollowing: null);
      // The room's own title — never the full-page screen title.
      expect(find.text('Community Room — TEST COMMUNITY'), findsOneWidget);
      expect(find.text('Arena Hub Voice Chat Room'), findsNothing);
      // Real listeners count (0 — nobody on voice yet).
      expect(find.text('0'), findsOneWidget);
      expect(find.byIcon(Icons.headset), findsOneWidget);
      // Host offline -> no LIVE chip anywhere in the panel.
      expect(find.text('Live'), findsNothing);
      // The cyber-notch clipper shapes the strip.
      expect(find.byType(ClipPath), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('host card: No host + name + Host pill + crowns',
        (tester) async {
      await pumpRoom(tester, sidebarFollowing: null);
      expect(find.text('No host'), findsOneWidget);
      expect(find.text('TEST COMMUNITY'), findsOneWidget);
      expect(find.text('Host'), findsOneWidget);
      // Lucide crowns: Host pill + header-strip chip (the avatar
      // crown only renders with a host present).
      expect(find.byIcon(LucideIcons.crown), findsNWidgets(2));
      // Connection state still visible in the card.
      expect(find.text('Not connected'), findsOneWidget);
      expect(find.text('Disconnected'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('podium: header + 6 free seats + podium discs',
        (tester) async {
      await pumpRoom(tester, sidebarFollowing: null);
      expect(find.text('Voice Seats (0)'), findsOneWidget);
      expect(find.text('View All'), findsOneWidget);
      for (final n in ['1', '2', '3', '4', '5', '6']) {
        expect(seatNumberFinder(n), findsOneWidget, reason: 'seat $n');
      }
      // One podium disc under each free seat.
      final discs = find.byWidgetPredicate((w) =>
          w is CustomPaint && w.painter is PodiumDiscPainter);
      expect(discs, findsNWidgets(6));
      expect(tester.takeException(), isNull);
    });

    testWidgets('mic button: OFF + gated while disconnected (16b)',
        (tester) async {
      await pumpRoom(tester, sidebarFollowing: null);
      expect(find.text('OFF'), findsOneWidget);
      // The gate: onTap is null while not on voice.
      final inkwell = find.ancestor(
          of: find.text('OFF'), matching: find.byType(InkWell));
      expect(inkwell, findsOneWidget);
      expect(tester.widget<InkWell>(inkwell).onTap, isNull);
      // Tapping the gated button does nothing at all.
      await tester.tap(find.text('OFF'));
      await tester.pump();
      expect(find.byType(SnackBar), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('free seat tap fires the real join path (slot dialog)',
        (tester) async {
      await pumpRoom(tester, sidebarFollowing: null);
      await tester.tap(seatNumberFinder('1'));
      await tester.pump();
      // Admin slot picker — the seat tap reached _adminTakeMic.
      expect(find.text('Mic slot chuno — Aap (Admin)'), findsOneWidget);
      expect(find.text('Mic 1 (suggested)'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pump();
      expect(find.text('Mic 1 (suggested)'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('sidebar: all 6 entries + Follow pill reachable',
        (tester) async {
      var followed = false;
      await pumpRoom(tester,
          sidebarFollowing: false, onFollowToggle: () => followed = true);
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
      expect(find.text('Follow'), findsOneWidget);
      await tester.tap(find.text('Follow'));
      await tester.pump();
      expect(followed, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('sidebar callbacks fire the real functions', (tester) async {
      var followers = false;
      var music = false;
      var rj = false;
      var settings = false;
      var leave = false;
      await pumpRoom(tester,
          sidebarFollowing: null,
          onFollowers: () => followers = true,
          onMusic: () => music = true,
          onRjPanel: () => rj = true,
          onSettings: () => settings = true,
          onLeaveRoom: () => leave = true);
      await tester.tap(find.text('Followers'));
      await tester.pump();
      expect(followers, isTrue);
      await tester.tap(find.text('Music'));
      await tester.pump();
      expect(music, isTrue);
      await tester.tap(find.text('RJ Panel'));
      await tester.pump();
      expect(rj, isTrue);
      await tester.tap(find.text('Settings'));
      await tester.pump();
      expect(settings, isTrue);
      await tester.tap(find.text('Leave Room'));
      await tester.pump();
      expect(leave, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('View All opens Participants/Status (real function)',
        (tester) async {
      await pumpRoom(tester, sidebarFollowing: null);
      await tester.tap(find.text('View All'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(OnlineStatusSheet), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('NO Scaffold inside the panel, NO full-page screen',
        (tester) async {
      await pumpRoom(tester, sidebarFollowing: null);
      expect(
          find.descendant(
              of: find.byType(UnifiedRoomPage),
              matching: find.byType(Scaffold)),
          findsNothing);
      expect(find.byType(ArenaVoiceRoomScreen), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('no "Members" text anywhere in the panel',
        (tester) async {
      await pumpRoom(tester, sidebarFollowing: null);
      final hits = find.byWidgetPredicate((w) =>
          w is Text &&
          (w.data?.toLowerCase().contains('member') ?? false));
      expect(hits, findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('voice locked: locked line replaces the seats',
        (tester) async {
      await pumpRoom(tester, sidebarFollowing: null, voiceLocked: true);
      expect(find.text('Voice locked'), findsOneWidget);
      expect(find.text('Voice Seats (0)'), findsNothing);
      expect(seatNumberFinder('1'), findsNothing);
      // Header strip + host card still render.
      expect(find.text('Community Room — TEST COMMUNITY'), findsOneWidget);
      expect(find.text('No host'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('team scope: same panel, team title, 6 seats',
        (tester) async {
      await pumpRoom(tester, sidebarFollowing: null, scope: 'team');
      expect(find.text('Team Room — TEST TEAM'), findsOneWidget);
      expect(find.text('TEST TEAM'), findsOneWidget);
      expect(find.text('No host'), findsOneWidget);
      expect(find.text('Voice Seats (0)'), findsOneWidget);
      for (final n in ['1', '2', '3', '4', '5', '6']) {
        expect(seatNumberFinder(n), findsOneWidget, reason: 'seat $n');
      }
      // Team scope passes no follow toggle -> no Follow pill.
      expect(find.text('Follow'), findsNothing);
      expect(find.text('JOINED'), findsNothing);
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
      'teams': [
        {
          'id': 'team-1',
          'name': 'TEST TEAM',
          'captain_uid': 'test-uid',
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
