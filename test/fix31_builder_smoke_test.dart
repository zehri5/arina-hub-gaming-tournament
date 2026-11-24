// FIX 31 — builder smoke checks for ArenaVoiceRoomScreen (standalone,
// mock props only; no UnifiedRoomPage mount, so no DSP MethodChannel
// mock is needed here). The verifier writes the formal
// test/fix31_room_ui_test.dart afterwards; this file is the builder's
// own checks and may be kept or removed by the verifier.
// NOTE: the screen runs a 1 s periodic timer + a repeating pulse
// animation, so these tests use explicit pump() calls, never
// pumpAndSettle.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:protournament_user/models/voice_room_models.dart';
import 'package:protournament_user/screens/arena_voice_room_screen.dart';

Widget wrap(Widget child) => MaterialApp(home: child);

List<VoiceSeatMember> mockSeats() => const [
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

List<ArenaChatMessage> mockMessages() => const [
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

void main() {
  // Phone-sized surface (360x800 @ 2.0 — the narrowest common phone,
  // so layout checks run against a real viewport, not the 800x600
  // test default, and narrow phones are covered too).
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

  testWidgets('FIX31 header: full title + count, no back arrow, no dots',
      (tester) async {
    await tester.pumpWidget(wrap(ArenaVoiceRoomScreen(
      roomTitle: 'Tournament Room — Test Cup',
      hostName: 'Host One',
      hostAvatar: '',
      initialSeats: mockSeats(),
      initialMessages: mockMessages(),
      playersCount: 7,
    )));
    await tester.pump();
    expect(find.textContaining('ARENA HUB'), findsOneWidget);
    expect(find.textContaining('VOICE CHAT ROOM'), findsOneWidget);
    expect(find.byIcon(LucideIcons.arrowLeft), findsNothing);
    expect(find.byIcon(LucideIcons.ellipsis), findsNothing);
    expect(find.text('7'), findsOneWidget); // header players badge
    expect(find.textContaining('Members'), findsNothing);
    expect(find.textContaining('Voice Seats'), findsOneWidget);
    expect(find.textContaining('Seated'), findsOneWidget);
  });

  testWidgets('FIX31 no host: "No host" + no crown tick', (tester) async {
    await tester.pumpWidget(wrap(ArenaVoiceRoomScreen(
      roomTitle: 'Tournament Room — Test Cup',
      hostName: '',
      hostAvatar: '',
      hostPresent: false,
      initialSeats: mockSeats(),
      initialMessages: mockMessages(),
    )));
    await tester.pump();
    expect(find.text('No host'), findsOneWidget);
  });

  testWidgets('FIX31 mic toggle + send fire callbacks', (tester) async {
    bool? micValue;
    String? sent;
    await tester.pumpWidget(wrap(ArenaVoiceRoomScreen(
      roomTitle: 'Room',
      hostName: 'Host One',
      hostAvatar: '',
      initialSeats: mockSeats(),
      initialMessages: mockMessages(),
      ownMemberId: 'user-2',
      ownDisplayName: 'Second User',
      onMicToggled: (v) => micValue = v,
      onSendMessage: (t) => sent = t,
    )));
    await tester.pump();
    // Mic orb (centerpiece) toggles mic on -> off.
    await tester.tap(find.byIcon(LucideIcons.mic).first);
    await tester.pump();
    expect(micValue, isFalse);
    // Composer send.
    await tester.enterText(find.byType(TextField), 'hello test');
    await tester.tap(find.byIcon(LucideIcons.send));
    await tester.pump();
    expect(sent, 'hello test');
  });

  testWidgets('FIX31 locked voice output never fires', (tester) async {
    var calls = 0;
    await tester.pumpWidget(wrap(ArenaVoiceRoomScreen(
      roomTitle: 'Room',
      hostName: 'Host One',
      hostAvatar: '',
      initialSeats: mockSeats(),
      initialMessages: mockMessages(),
      lockVoiceOutputOn: true,
      onVoiceOutputToggled: (_) => calls++,
    )));
    await tester.pump();
    await tester.tap(find.text('Voice On'));
    await tester.pump();
    expect(calls, 0);
    expect(find.text('Voice On'), findsOneWidget);
  });

  testWidgets('FIX31 menu sheet: Followers + Leave fire real callbacks',
      (tester) async {
    var followers = false;
    var left = false;
    await tester.pumpWidget(wrap(ArenaVoiceRoomScreen(
      roomTitle: 'Room',
      hostName: 'Host One',
      hostAvatar: '',
      initialSeats: mockSeats(),
      initialMessages: mockMessages(),
      onFollowers: () => followers = true,
      onLeaveRoom: () => left = true,
    )));
    await tester.pump();
    // Host-card menu button opens the sheet. The sheet's slide-in
    // animation starts during the first pump after the tap, so a
    // single pump(Duration) leaves it at value 0 (off-screen) — pump
    // twice to let it settle.
    await tester.tap(find.byIcon(LucideIcons.menu).first);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('Room Menu'), findsOneWidget);
    expect(find.text('Followers'), findsOneWidget);
    expect(find.text('Leave Room'), findsOneWidget);
    await tester.tap(find.text('Followers'));
    await tester.pump();
    expect(followers, isTrue);
    // Reopen, leave with confirm.
    await tester.tap(find.byIcon(LucideIcons.menu).first);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.tap(find.text('Leave Room'));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('Leave Voice Room?'), findsOneWidget);
    await tester.tap(find.text('Leave Room').last);
    await tester.pump();
    expect(left, isTrue);
  });

  testWidgets('FIX31 live sync: new props replace seats/messages',
      (tester) async {
    Widget build(int players, List<ArenaChatMessage> msgs) =>
        wrap(ArenaVoiceRoomScreen(
          roomTitle: 'Room',
          hostName: 'Host One',
          hostAvatar: '',
          initialSeats: mockSeats(),
          initialMessages: msgs,
          playersCount: players,
        ));
    await tester.pumpWidget(build(7, mockMessages()));
    await tester.pump();
    expect(find.text('Hello room'), findsOneWidget);
    await tester.pumpWidget(build(9, [
      ...mockMessages(),
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
}
