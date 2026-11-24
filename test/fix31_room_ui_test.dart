// FIX 31 — VERIFIER formal tests for ArenaVoiceRoomScreen + adapter pins.
// Independent of the builder's smoke tests: every claim in
// BUILDER-DONE.md is re-checked here from the code + widget behaviour.
// Screen-level only (mock props) — no UnifiedRoomPage mount, so no DSP
// MethodChannel mock is needed in this file. The adapter mapping
// (_fix31MapSeats/_fix31MapMessages/live-only filter) is verified by
// code review + source pins, not by mounting the full room.
// NOTE: the screen runs a 1 s periodic timer + a repeating pulse
// animation, so these tests use explicit pump() calls, never
// pumpAndSettle.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:protournament_user/models/voice_room_models.dart';
import 'package:protournament_user/screens/arena_voice_room_screen.dart';
import 'package:protournament_user/screens/room_screen.dart'
    show hostVerifiedTick;
import 'package:protournament_user/theme/arena_theme.dart';
import 'package:protournament_user/widgets/arena_custom_graphics.dart';

import 'audio_test_helpers.dart';

Widget _wrap(Widget child) => MaterialApp(home: child);

List<VoiceSeatMember> _mockSeats() => const [
      VoiceSeatMember(
          seatNumber: 1,
          memberId: 'host-1',
          name: 'Host One',
          isHost: true,
          isVerified: true,
          isMuted: false,
          isSpeaking: true),
      VoiceSeatMember(
          seatNumber: 2,
          memberId: 'user-2',
          name: 'Second User',
          isMuted: true),
      VoiceSeatMember(seatNumber: 3),
      VoiceSeatMember(seatNumber: 4),
      VoiceSeatMember(seatNumber: 5),
      VoiceSeatMember(seatNumber: 6),
    ];

/// Seats with NO host occupant (no-host room).
List<VoiceSeatMember> _noHostSeats() => const [
      VoiceSeatMember(seatNumber: 1),
      VoiceSeatMember(
          seatNumber: 2,
          memberId: 'user-2',
          name: 'Second User',
          isMuted: true),
      VoiceSeatMember(seatNumber: 3),
      VoiceSeatMember(seatNumber: 4),
      VoiceSeatMember(seatNumber: 5),
      VoiceSeatMember(seatNumber: 6),
    ];

List<ArenaChatMessage> _mockMessages() => const [
      ArenaChatMessage(
          id: 'm1',
          senderName: 'Host One',
          initials: 'HO',
          timestamp: '10:00',
          text: 'Hello room',
          isHost: true),
      ArenaChatMessage(
          id: 'm2',
          senderName: 'Second User',
          initials: 'SU',
          timestamp: '10:01',
          text: 'Hi there'),
    ];

Widget _screen({
  List<VoiceSeatMember>? seats,
  List<ArenaChatMessage>? messages,
  int playersCount = 7,
  bool hostPresent = true,
  bool hostVerified = true,
  String hostName = 'Host One',
  int initialDurationSeconds = 0,
  VoiceConnectionStatus connectionStatus =
      VoiceConnectionStatus.connected,
  bool isMicOn = true,
  bool lockVoiceOutputOn = false,
  bool micToggleEnabled = true,
  String? ownMemberId,
  String ownDisplayName = 'You',
  ValueChanged<bool>? onMicToggled,
  ValueChanged<bool>? onVoiceOutputToggled,
  ValueChanged<String>? onSendMessage,
  VoidCallback? onLeaveRoom,
  VoidCallback? onFollowers,
  VoidCallback? onMusic,
  VoidCallback? onRjPanel,
  VoidCallback? onSettings,
  String? followersCountLabel,
  bool? followState,
  bool followBusy = false,
  VoidCallback? onFollowToggle,
  bool showRjPanel = true,
  List<ArenaMenuEntry> menuExtras = const [],
  VoidCallback? onUsersTap,
  VoidCallback? onViewAll,
  ValueChanged<VoiceSeatMember>? onSeatTap,
  VoidCallback? onImageTap,
}) =>
    _wrap(ArenaVoiceRoomScreen(
      roomTitle: 'Tournament Room — Test Cup',
      hostName: hostName,
      hostAvatar: '',
      hostVerified: hostVerified,
      hostPresent: hostPresent,
      initialSeats: seats ?? _mockSeats(),
      initialMessages: messages ?? _mockMessages(),
      playersCount: playersCount,
      initialDurationSeconds: initialDurationSeconds,
      connectionStatus: connectionStatus,
      isMicOn: isMicOn,
      lockVoiceOutputOn: lockVoiceOutputOn,
      micToggleEnabled: micToggleEnabled,
      ownMemberId: ownMemberId,
      ownDisplayName: ownDisplayName,
      onMicToggled: onMicToggled,
      onVoiceOutputToggled: onVoiceOutputToggled,
      onSendMessage: onSendMessage,
      onLeaveRoom: onLeaveRoom,
      onFollowers: onFollowers,
      onMusic: onMusic,
      onRjPanel: onRjPanel,
      onSettings: onSettings,
      followersCountLabel: followersCountLabel,
      followState: followState,
      followBusy: followBusy,
      onFollowToggle: onFollowToggle,
      showRjPanel: showRjPanel,
      menuExtras: menuExtras,
      onUsersTap: onUsersTap,
      onViewAll: onViewAll,
      onSeatTap: onSeatTap,
      onImageTap: onImageTap,
    ));

/// Opens the host-card menu sheet (slide-in needs two pumps).
Future<void> _openMenu(WidgetTester tester) async {
  await tester.tap(find.byIcon(LucideIcons.menu).first);
  await tester.pump(const Duration(milliseconds: 600));
  await tester.pump(const Duration(milliseconds: 600));
}

/// Podium disc glow state, seat order (true = speaking + unmuted).
List<bool> _discActives(WidgetTester tester) {
  final discs = tester
      .widgetList<CustomPaint>(find.byType(CustomPaint))
      .where((w) => w.painter is PodiumDiscPainter)
      .map((w) => (w.painter as PodiumDiscPainter).active)
      .toList();
  return discs;
}

void main() {
  // Phone-sized surface (360x800 @ 2.0 — the narrowest common phone).
  setUpAll(() {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    binding.window.physicalSizeTestValue = const Size(360 * 2, 800 * 2);
    binding.window.devicePixelRatioTestValue = 2.0;
  });
  tearDownAll(() {
    TestWidgetsFlutterBinding.ensureInitialized()
        .window
        .clearAllTestValues();
  });

  group('FIX31 mount + layout (360x800)', () {
    testWidgets('mounts with mock props, no overflow, no exception',
        (tester) async {
      await tester.pumpWidget(_screen());
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.byType(ArenaVoiceRoomScreen), findsOneWidget);
      expect(find.textContaining('ARENA HUB'), findsOneWidget);
      expect(find.textContaining('VOICE CHAT ROOM'), findsOneWidget);
      expect(find.text('Voice Seats (2)'), findsOneWidget);
      expect(find.text('2 Seated'), findsOneWidget);
    });

    testWidgets('mounts at 360x844 with no overflow', (tester) async {
      final binding = TestWidgetsFlutterBinding.ensureInitialized();
      binding.window.physicalSizeTestValue = const Size(360 * 2, 844 * 2);
      addTearDown(() {
        binding.window.physicalSizeTestValue = const Size(360 * 2, 800 * 2);
      });
      await tester.pumpWidget(_screen());
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.textContaining('VOICE CHAT ROOM'), findsOneWidget);
    });

    testWidgets('empty chat shows the empty state, not a blank panel',
        (tester) async {
      await tester.pumpWidget(_screen(messages: const []));
      await tester.pump();
      expect(find.text('No messages yet. Say hi!'), findsOneWidget);
    });
  });

  group('FIX31 01:50 header overrides', () {
    testWidgets('no back arrow, no three-dots anywhere in the screen',
        (tester) async {
      await tester.pumpWidget(_screen());
      await tester.pump();
      expect(find.byIcon(LucideIcons.arrowLeft), findsNothing);
      expect(find.byIcon(LucideIcons.ellipsis), findsNothing);
      expect(find.byIcon(Icons.arrow_back), findsNothing);
      expect(find.byIcon(Icons.more_horiz), findsNothing);
      expect(find.byIcon(Icons.more_vert), findsNothing);
      expect(find.byType(BackButton), findsNothing);
    });

    testWidgets('players count badge up top is the real prop',
        (tester) async {
      await tester.pumpWidget(_screen(playersCount: 7));
      await tester.pump();
      expect(find.text('7'), findsOneWidget); // header badge
      expect(find.text('7 Online'), findsNWidgets(2)); // host card + chat
      await tester.pumpWidget(_screen(playersCount: 1500));
      await tester.pump();
      expect(find.text('1.5K'), findsOneWidget);
      expect(find.text('1.5K Online'), findsNWidgets(2));
    });

    testWidgets('ONE menu button on mount, in the host card',
        (tester) async {
      await tester.pumpWidget(_screen());
      await tester.pump();
      expect(find.byIcon(LucideIcons.menu), findsOneWidget);
    });

    testWidgets('no "Members" text rendered anywhere', (tester) async {
      await tester.pumpWidget(_screen());
      await tester.pump();
      expect(find.textContaining('Members'), findsNothing);
      expect(find.textContaining(RegExp('members', caseSensitive: false)),
          findsNothing);
      await _openMenu(tester);
      expect(find.textContaining('Members'), findsNothing);
      expect(find.textContaining(RegExp('members', caseSensitive: false)),
          findsNothing);
    });
  });

  group('FIX31 menu sheet', () {
    List<ArenaMenuEntry> extras(Map<String, bool> fired) => [
          ArenaMenuEntry(
              icon: LucideIcons.power,
              label: 'Power',
              color: ArenaColors.connectedGreen,
              onTap: () => fired['power'] = true),
          ArenaMenuEntry(
              icon: LucideIcons.mic,
              label: 'Voice',
              color: ArenaColors.connectedGreen,
              onTap: () => fired['voice'] = true),
          ArenaMenuEntry(
              icon: LucideIcons.userPlus,
              label: 'Invite',
              color: ArenaColors.royalGold,
              onTap: () => fired['invite'] = true),
          ArenaMenuEntry(
              icon: LucideIcons.heart,
              label: 'Follow Host',
              color: ArenaColors.neonPink,
              onTap: () => fired['followHost'] = true),
          ArenaMenuEntry(
              icon: LucideIcons.phoneOff,
              label: 'Leave Voice',
              color: ArenaColors.liveRed,
              onTap: () => fired['leaveVoice'] = true),
          ArenaMenuEntry(
              icon: LucideIcons.refreshCw,
              label: 'Refresh',
              color: ArenaColors.electricBlue,
              onTap: () => fired['refresh'] = true),
        ];

    testWidgets('menu contains every entry, Leave Room last',
        (tester) async {
      final fired = <String, bool>{};
      await tester.pumpWidget(_screen(menuExtras: extras(fired)));
      await tester.pump();
      await _openMenu(tester);
      expect(find.text('Room Menu'), findsOneWidget);
      for (final label in [
        'Followers',
        'Music',
        'RJ Panel',
        'Settings',
        'Power',
        'Voice',
        'Invite',
        'Follow Host',
        'Leave Voice',
        'Refresh',
        'Leave Room',
      ]) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      final texts = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data)
          .whereType<String>()
          .toList();
      final order = [
        'Followers',
        'Music',
        'RJ Panel',
        'Settings',
        'Power',
        'Voice',
        'Invite',
        'Follow Host',
        'Leave Voice',
        'Refresh',
        'Leave Room',
      ];
      for (var i = 0; i < order.length - 1; i++) {
        expect(texts.indexOf(order[i]), lessThan(texts.indexOf(order[i + 1])),
            reason: '${order[i]} must precede ${order[i + 1]}');
      }
    });

    testWidgets('canonical entries each fire their real target',
        (tester) async {
      final fired = <String, bool>{};
      await tester.pumpWidget(_screen(
        onFollowers: () => fired['followers'] = true,
        onMusic: () => fired['music'] = true,
        onRjPanel: () => fired['rj'] = true,
        onSettings: () => fired['settings'] = true,
      ));
      await tester.pump();
      for (final entry in {
        'Followers': 'followers',
        'Music': 'music',
        'RJ Panel': 'rj',
        'Settings': 'settings',
      }.entries) {
        await _openMenu(tester);
        await tester.tap(find.text(entry.key));
        await tester.pump();
        expect(fired[entry.value], isTrue, reason: entry.key);
      }
    });

    testWidgets('extras each fire their real target', (tester) async {
      final fired = <String, bool>{};
      await tester.pumpWidget(_screen(menuExtras: extras(fired)));
      await tester.pump();
      for (final label in [
        'Power',
        'Voice',
        'Invite',
        'Follow Host',
        'Leave Voice',
        'Refresh',
      ]) {
        await _openMenu(tester);
        await tester.tap(find.text(label));
        await tester.pump();
      }
      expect(
          fired,
          equals({
            'power': true,
            'voice': true,
            'invite': true,
            'followHost': true,
            'leaveVoice': true,
            'refresh': true,
          }));
    });

    testWidgets('RJ Panel row hidden when host-gated off', (tester) async {
      await tester.pumpWidget(_screen(showRjPanel: false));
      await tester.pump();
      await _openMenu(tester);
      expect(find.text('RJ Panel'), findsNothing);
      expect(find.text('Followers'), findsOneWidget);
    });

    testWidgets('Followers row: real count label + Follow pill fires',
        (tester) async {
      var toggled = false;
      await tester.pumpWidget(_screen(
        followersCountLabel: '1.2K',
        followState: false,
        onFollowToggle: () => toggled = true,
      ));
      await tester.pump();
      await _openMenu(tester);
      expect(find.text('1.2K'), findsOneWidget);
      expect(find.text('Follow'), findsOneWidget);
      await tester.tap(find.text('Follow'));
      await tester.pump();
      expect(toggled, isTrue);
    });

    testWidgets('Follow pill states: Following / absent without state',
        (tester) async {
      await tester.pumpWidget(_screen(
        followersCountLabel: '1.2K',
        followState: true,
        onFollowToggle: () {},
      ));
      await tester.pump();
      await _openMenu(tester);
      expect(find.text('Following'), findsOneWidget);
      expect(find.text('Follow'), findsNothing);

      await tester.pumpWidget(_screen(
        followersCountLabel: '1.2K',
        followState: null,
        onFollowToggle: null,
      ));
      await tester.pump();
      await _openMenu(tester);
      expect(find.text('Follow'), findsNothing);
      expect(find.text('Following'), findsNothing);
      expect(find.text('JOINED'), findsNothing);
    });
  });

  group('FIX31 callbacks wired', () {
    testWidgets('mic toggle fires + flips the OWN seat', (tester) async {
      bool? micValue;
      await tester.pumpWidget(_screen(
        ownMemberId: 'host-1',
        onMicToggled: (v) => micValue = v,
      ));
      await tester.pump();
      // Host seat speaks -> its podium disc glows (active).
      expect(_discActives(tester),
          equals([true, false, false, false, false, false]));
      await tester.tap(find.byIcon(LucideIcons.mic).first);
      await tester.pump();
      expect(micValue, isFalse);
      expect(find.text('Mic Off'), findsOneWidget);
      // Own (host) seat flipped to muted -> disc glow off.
      expect(_discActives(tester),
          equals([false, false, false, false, false, false]));
    });

    testWidgets('mic gated when disconnected (16b): tap stays silent',
        (tester) async {
      var calls = 0;
      await tester.pumpWidget(_screen(
        micToggleEnabled: false,
        onMicToggled: (_) => calls++,
      ));
      await tester.pump();
      await tester.tap(find.byIcon(LucideIcons.mic).first);
      await tester.pump();
      expect(calls, 0);
      expect(find.text('Mic On'), findsOneWidget);
    });

    testWidgets('send fires + optimistic row is the CURRENT user',
        (tester) async {
      String? sent;
      await tester.pumpWidget(_screen(
        ownMemberId: 'user-2',
        ownDisplayName: 'Second User',
        onSendMessage: (t) => sent = t,
      ));
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'hello test');
      await tester.tap(find.byIcon(LucideIcons.send));
      await tester.pump();
      expect(sent, 'hello test');
      expect(find.text('hello test'), findsOneWidget);
      // Sender line is the current user (mock m2 is also from
      // Second User, so the optimistic row reads 'Second User  Now').
      expect(find.text('Second User  Now'), findsOneWidget);
    });

    testWidgets('locked voice output never fires', (tester) async {
      var calls = 0;
      await tester.pumpWidget(_screen(
        lockVoiceOutputOn: true,
        onVoiceOutputToggled: (_) => calls++,
      ));
      await tester.pump();
      await tester.tap(find.text('Voice On'));
      await tester.pump();
      expect(calls, 0);
      expect(find.text('Voice On'), findsOneWidget);
    });

    testWidgets('leave: Stay cancels, Leave Room confirms then exits',
        (tester) async {
      var left = false;
      await tester.pumpWidget(_screen(onLeaveRoom: () => left = true));
      await tester.pump();
      await _openMenu(tester);
      await tester.tap(find.text('Leave Room'));
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('Leave Voice Room?'), findsOneWidget);
      await tester.tap(find.text('Stay'));
      await tester.pump();
      expect(left, isFalse);
      await _openMenu(tester);
      await tester.tap(find.text('Leave Room'));
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 600));
      await tester.tap(find.text('Leave Room').last);
      await tester.pump();
      expect(left, isTrue);
    });

    testWidgets('header users / View All / seat / image taps fire',
        (tester) async {
      var users = false;
      var viewAll = false;
      VoiceSeatMember? tappedSeat;
      var image = false;
      await tester.pumpWidget(_screen(
        onUsersTap: () => users = true,
        onViewAll: () => viewAll = true,
        onSeatTap: (s) => tappedSeat = s,
        onImageTap: () => image = true,
      ));
      await tester.pump();
      await tester.tap(find.byIcon(LucideIcons.usersRound).first);
      await tester.pump();
      expect(users, isTrue);
      await tester.tap(find.text('View All'));
      await tester.pump();
      expect(viewAll, isTrue);
      await tester.tap(find.text('Second User'));
      await tester.pump();
      expect(tappedSeat?.seatNumber, 2);
      expect(tappedSeat?.memberId, 'user-2');
      await tester.tap(find.byIcon(LucideIcons.image));
      await tester.pump();
      expect(image, isTrue);
    });

    testWidgets('emoji strip inserts at the cursor', (tester) async {
      await tester.pumpWidget(_screen());
      await tester.pump();
      await tester.tap(find.byIcon(LucideIcons.smile));
      await tester.pump();
      expect(find.text('😀'), findsOneWidget);
      await tester.tap(find.text('😀'));
      await tester.pump();
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller?.text, contains('😀'));
    });
  });

  group('FIX31 host card (items 17 + 19)', () {
    testWidgets('verified tick shown only when hostVerified (flag rule)',
        (tester) async {
      // Disconnected: the stage chip shows wifiOff, so the only
      // badgeCheck in the tree is the host tick.
      await tester.pumpWidget(_screen(
        connectionStatus: VoiceConnectionStatus.disconnected,
        hostVerified: true,
      ));
      await tester.pump();
      expect(find.byIcon(LucideIcons.badgeCheck), findsOneWidget);
      await tester.pumpWidget(_screen(
        connectionStatus: VoiceConnectionStatus.disconnected,
        hostVerified: false,
      ));
      await tester.pump();
      expect(find.byIcon(LucideIcons.badgeCheck), findsNothing);
    });

    test('hostVerifiedTick uses the fix22 formula (flag OR >=1000)',
        () {
      expect(hostVerifiedTick(flag: false, followersCount: null), isFalse);
      expect(hostVerifiedTick(flag: false, followersCount: 999), isFalse);
      expect(hostVerifiedTick(flag: false, followersCount: 1000), isTrue);
      expect(hostVerifiedTick(flag: false, followersCount: 5000), isTrue);
      expect(hostVerifiedTick(flag: true, followersCount: 0), isTrue);
      expect(hostVerifiedTick(flag: true, followersCount: null), isTrue);
    });

    testWidgets('offline host: "No host" + empty circle, no other photo',
        (tester) async {
      await tester.pumpWidget(_screen(
        hostPresent: false,
        hostName: '',
        seats: _noHostSeats(),
      ));
      await tester.pump();
      expect(find.text('No host'), findsOneWidget);
      // No avatar fallback icon anywhere (empty circle, not a face).
      expect(find.byIcon(LucideIcons.user), findsNothing);
      // Crowns: header + "Host" badge only (no avatar crown).
      expect(find.byIcon(LucideIcons.crown), findsNWidgets(2));
    });

    testWidgets('host present with no avatar URL: icon fallback renders',
        (tester) async {
      await tester.pumpWidget(_screen(hostPresent: true));
      await tester.pump();
      expect(find.text('Host One'), findsWidgets);
      expect(find.byIcon(LucideIcons.user), findsOneWidget);
    });
  });

  group('FIX31 seats + live state', () {
    testWidgets('speaking-gated pulse: only the speaking seat glows',
        (tester) async {
      await tester.pumpWidget(_screen());
      await tester.pump();
      // Seat 1 speaks unmuted -> active; seat 2 muted -> inactive;
      // empty seats -> inactive.
      expect(_discActives(tester),
          equals([true, false, false, false, false, false]));
    });

    testWidgets('duration shows the real elapsed prop, never 12:45',
        (tester) async {
      await tester.pumpWidget(_screen(initialDurationSeconds: 3661));
      await tester.pump();
      expect(find.text('01:01:01'), findsOneWidget);
      expect(find.text('12:45'), findsNothing);
    });

    testWidgets('connection chip: Connected vs Offline', (tester) async {
      await tester.pumpWidget(
          _screen(connectionStatus: VoiceConnectionStatus.connected));
      await tester.pump();
      expect(find.text('Connected'), findsOneWidget);
      await tester.pumpWidget(
          _screen(connectionStatus: VoiceConnectionStatus.disconnected));
      await tester.pump();
      expect(find.text('Offline'), findsOneWidget);
    });

    testWidgets(
        'VERIFIER NOTE: reconnecting currently renders as Offline '
        '(adapter distinguishes it; screen has no Reconnecting label)',
        (tester) async {
      await tester.pumpWidget(
          _screen(connectionStatus: VoiceConnectionStatus.reconnecting));
      await tester.pump();
      expect(find.text('Offline'), findsOneWidget);
      expect(find.textContaining('econnect'), findsNothing);
    });

    testWidgets('live sync: new props replace seats/messages',
        (tester) async {
      Widget build(int players, List<ArenaChatMessage> msgs) => _screen(
            playersCount: players,
            messages: msgs,
          );
      await tester.pumpWidget(build(7, _mockMessages()));
      await tester.pump();
      expect(find.text('Hello room'), findsOneWidget);
      await tester.pumpWidget(build(9, [
        ..._mockMessages(),
        const ArenaChatMessage(
            id: 'm3',
            senderName: 'Third',
            initials: 'TH',
            timestamp: '10:02',
            text: 'Third message'),
      ]));
      await tester.pump();
      expect(find.text('Third message'), findsOneWidget);
      expect(find.text('9'), findsOneWidget);
    });

    testWidgets('no fake sample counts or names rendered', (tester) async {
      await tester.pumpWidget(_screen());
      await tester.pump();
      expect(find.text('124'), findsNothing);
      expect(find.text('124 Online'), findsNothing);
      expect(find.text('24 Online'), findsNothing);
      expect(find.text('SZ'), findsNothing);
      expect(find.text('John Doe'), findsNothing);
    });
  });

  group('FIX31 assets + theme (source + bundle)', () {
    test('voice background asset loads + is byte-identical to item-21 bg',
        () async {
      final voice =
          await rootBundle.load('assets/images/arena_voice_background.png');
      final appBg =
          await rootBundle.load('assets/images/app_background.png');
      final a = voice.buffer.asUint8List();
      final b = appBg.buffer.asUint8List();
      expect(a.length, greaterThan(0));
      expect(listEquals(a, b), isTrue,
          reason: 'arena_voice_background.png must equal app_background.png');
    });

    test('theme merge: ArenaTheme + ArenaColors + ArenaTypography present',
        () {
      final theme = requireProjectFile('lib/theme/arena_theme.dart');
      expect(theme, contains('class ArenaTheme'));
      expect(theme, contains('class ArenaColors'));
      expect(theme, contains('class ArenaTypography'));
      // Design gold only via the token.
      expect(ArenaColors.royalGold, const Color(0xFFFFD700));
      expect(ArenaTypography.heading(16), isA<TextStyle>());
      expect(ArenaTypography.orbitron(13), isA<TextStyle>());
      expect(ArenaTypography.body(12), isA<TextStyle>());
    });

    test('item-30 ArenaTheme class untouched (fix31 file only ADDS below it)',
        () {
      final fix30 =
          File('/home/hatch/workspace/arena-hub-fix30-auth/lib/theme/arena_theme.dart');
      if (!fix30.existsSync()) {
        markTestSkipped('fix30 reference tree not present on this VM');
      }
      final oldContent = fix30.readAsStringSync();
      final newContent = requireProjectFile('lib/theme/arena_theme.dart');
      expect(newContent.startsWith(oldContent), isTrue,
          reason: 'fix31 theme must start with the verbatim item-30 file');
      expect(newContent.length, greaterThan(oldContent.length));
    });

    test('STRICT gold: zero banned literals in ANY form (new/changed code)',
        () {
      // Banned literals built from char codes so this test file
      // itself never contains them as literals.
      final banned = [
        String.fromCharCodes([70, 70, 67, 56, 48, 48]), // FFC800
        String.fromCharCodes([70, 53, 65, 57, 48, 48]), // F5A900
        String.fromCharCodes([70, 70, 67, 67, 48, 48]), // FFCC00
        String.fromCharCodes([70, 70, 69, 50, 48, 65]), // FFE20A
        String.fromCharCodes([70, 70, 67, 52, 48, 48]), // FFC400
      ];
      // Split-string fragments (either half of a split literal).
      final fragments = [
        String.fromCharCodes([70, 70, 67, 56]), // FFC8
        String.fromCharCodes([70, 53, 65, 57]), // F5A9
        String.fromCharCodes([70, 70, 67, 67]), // FFCC
        String.fromCharCodes([70, 70, 69, 50]), // FFE2
        String.fromCharCodes([70, 70, 67, 52]), // FFC4
        String.fromCharCodes([67, 56, 48, 48]), // C800
        String.fromCharCodes([65, 57, 48, 48]), // A900
        String.fromCharCodes([67, 67, 48, 48]), // CC00
        String.fromCharCodes([69, 50, 48, 65]), // E20A
        String.fromCharCodes([67, 52, 48, 48]), // C400
      ];
      final files = [
        'lib/screens/arena_voice_room_screen.dart',
        'lib/models/voice_room_models.dart',
        'lib/widgets/arena_custom_graphics.dart',
        'lib/theme/arena_theme.dart',
        'lib/screens/room_screen.dart',
        'pubspec.yaml',
      ];
      for (final f in files) {
        final src = requireProjectFile(f).toUpperCase();
        for (final b in banned) {
          expect(src.contains(b), isFalse, reason: '$f contains $b');
        }
        for (final frag in fragments) {
          expect(src.contains(frag), isFalse, reason: '$f contains $frag');
        }
      }
    });

    test('design gold FFD700 appears ONLY in the theme definition', () {
      final theme =
          requireProjectFile('lib/theme/arena_theme.dart').toUpperCase();
      // Once in the definition + once in the FIX 31 comment.
      expect('FFD700'.allMatches(theme).length, 2);
      for (final f in [
        'lib/screens/arena_voice_room_screen.dart',
        'lib/models/voice_room_models.dart',
        'lib/widgets/arena_custom_graphics.dart',
        'lib/screens/room_screen.dart',
      ]) {
        final src = requireProjectFile(f).toUpperCase();
        expect(src.contains('FFD700'), isFalse, reason: f);
      }
    });

    test('"Members" word: only inside FIX 31 comments, never in code', () {
      final raw =
          requireProjectFile('lib/screens/arena_voice_room_screen.dart');
      final hits = raw
          .split('\n')
          .where((l) => l.contains('Members'))
          .toList();
      expect(hits, isNotEmpty,
          reason: 'expected the 2 documenting comments');
      for (final line in hits) {
        expect(line.trimLeft().startsWith('//'), isTrue,
            reason: 'non-comment "Members" line: $line');
      }
      expect(codeOnly(raw).toLowerCase().contains('members'), isFalse);
      for (final f in [
        'lib/models/voice_room_models.dart',
        'lib/widgets/arena_custom_graphics.dart',
        'lib/theme/arena_theme.dart',
      ]) {
        expect(codeOnly(requireProjectFile(f)).toLowerCase().contains('members'),
            isFalse,
            reason: f);
      }
    });
  });

  group('FIX31 V0 routing pins (which surfaces show the new UI)', () {
    late String room;
    setUpAll(() {
      room = requireProjectFile('lib/screens/room_screen.dart');
    });

    String after(String src, String needle, [int len = 700]) {
      final i = src.indexOf(needle);
      if (i < 0) return '';
      final end = (i + len < src.length) ? i + len : src.length;
      return src.substring(i, end);
    }

    test('build(): embedded -> legacy panel, full-page -> new screen', () {
      expect(
          room,
          contains(
              'if (widget.embedded) return _buildEmbeddedVoice(uid, peers, kbOpen);'));
      expect(room, contains('return _buildArenaVoiceRoom(uid, peers);'));
      expect(room, contains('Widget _buildLegacyFullRoom('));
    });

    test('community detail mounts embedded (legacy UI unchanged)', () {
      final comm =
          requireProjectFile('lib/screens/communities_screens.dart');
      // Long arg list (comments + sidebar props) — wide window.
      expect(after(comm, 'UnifiedRoomPage(', 2000), contains('embedded: true'));
    });

    test('team chat mounts embedded (legacy UI unchanged)', () {
      final pro = requireProjectFile('lib/screens/pro_features.dart');
      final first = pro.indexOf('UnifiedRoomPage(');
      expect(first, greaterThan(0));
      final region = pro.substring(
          first, (first + 700 < pro.length) ? first + 700 : pro.length);
      expect(region, contains('embedded: true'));
      expect(region, contains("scope: 'team'"));
    });

    test('spectator/shoutcaster mount full-page (new UI, no embedded flag)',
        () {
      final pro = requireProjectFile('lib/screens/pro_features.dart');
      final hits = 'UnifiedRoomPage('.allMatches(pro).toList();
      expect(hits.length, 3); // team panel + spectate + shoutcaster
      for (final m in hits.sublist(1)) {
        final region = pro.substring(m.start,
            (m.start + 500 < pro.length) ? m.start + 500 : pro.length);
        expect(region, contains('spectator: true'));
        expect(region, isNot(contains('embedded')));
      }
    });

    // ITEM 32 (merge step 4) removed the admin panel from the user app
    // (admin_login_screen.dart deleted; admin APK is a separate future
    // build), so the old "admin direct entry mounts full-page" pin is
    // vacuous — this test pins the new contract instead: the admin
    // direct entry is ABSENT from the user app.
    test('admin direct entry is absent (item 32 removed the admin panel)',
        () {
      final adminPath =
          '${findProjectRoot().path}/lib/screens/admin_login_screen.dart';
      expect(File(adminPath).existsSync(), isFalse,
          reason:
              'admin_login_screen.dart must stay deleted (item 32: admin panel out of the user app)');
    });
  });

  group('FIX31 adapter wiring pins (room_screen.dart)', () {
    late String room;
    setUpAll(() {
      room = requireProjectFile('lib/screens/room_screen.dart');
    });

    test('leave goes to the real exit path after the screen dialog', () {
      expect(room, contains('onLeaveRoom: _exitRoom'));
    });

    test('mic gate + locked voice output + real counts', () {
      expect(room, contains('micToggleEnabled: connected'));
      expect(room, contains('lockVoiceOutputOn: true'));
      expect(
          room, contains('peers.length + _liveListeners.listenerCount'));
    });

    test('menu targets are the real functions', () {
      expect(room, contains('onFollowers: widget.onSidebarFollowers'));
      expect(room, contains('onMusic: widget.onSidebarMusic'));
      expect(room, contains('onRjPanel: widget.onSidebarRjPanel'));
      expect(room, contains('onSettings: widget.onSidebarSettings'));
      expect(room, contains('menuExtras: _fix31MenuExtras()'));
      expect(room, contains('onUsersTap: _openStatus'));
      expect(room, contains('onViewAll: _openStatus'));
      expect(room, contains('onSeatTap: _fix31SeatTap'));
    });

    test('live-only chat filter preserved in _fix31MapMessages', () {
      expect(room, contains('ms == 0 || ms >= _roomEnteredAtMs'));
    });

    test('host tick uses the full item-19 formula', () {
      expect(room, contains('(hostUid == _adminUid) ||'));
      expect(room, contains('hostVerifiedTick('));
    });

    test('seats always map to exactly 6 podium cells', () {
      expect(room, contains('const total = 6;'));
      expect(room, contains('for (var seatNo = 1; seatNo <= total; seatNo++)'));
    });

    test('ArenaChatMessage collision handled with hide', () {
      expect(
          room, contains("import '../components/arena_chat.dart' hide ArenaChatMessage;"));
      final screen =
          requireProjectFile('lib/screens/arena_voice_room_screen.dart');
      expect(
          screen, contains("import '../components/arena_chat.dart' hide ArenaChatMessage;"));
    });
  });
}
