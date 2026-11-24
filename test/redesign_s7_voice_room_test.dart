// REDESIGN S7 — TEAM VOICE / CHAT ROOM (group B-S7, 2026-11-23).
// Track B redesign of UnifiedRoomPage (lib/screens/room_screen.dart)
// + the header Settings sheet (lib/widgets/voice_settings_sheet.dart)
// per the guide's Screen 7 (§6) + Addendum §A–§J, on the POST-Fix-12
// layout: top box = organizer name ONLY (no Host pill, no 'Room
// Owner' subtitle, no bio lines), the Connecting pill lives IN the
// host card next to the mic, and the bottom Music/Settings/Close row
// is GONE (those controls live in the header Settings sheet via the
// voice controller). Styling only — no logic, flow or data change.
//
// Source pins (exact token values / exact strings) + widget tests
// (the real room pumped at 360px width: host card + 3x2 seat grid +
// composer, no overflow) + sheet + seat-badge widget tests.
//
// HONEST LIMITS (same as fix12 G6): a widget test cannot prove a
// live mic connection — the 'Voice On' and 'Connecting…' pill states
// need a real voice engine + server, so they are pinned by SOURCE
// (exact label + exact colour mapping in _buildConnectingPill) while
// the two states reachable in tests ('Not connected' idle,
// 'Voice Failed' after a failed join) are pinned by WIDGET. The
// Roman-Urdu empty-chat copy ('Abhi koi message nahi…') belongs to
// TeamChatPage (pro_features.dart), outside this group's file scope;
// this room's own empty state ('No messages yet. Say hi!') is
// pinned here, copy unchanged.
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
import 'package:protournament_user/theme/arena_theme.dart';
import 'package:protournament_user/widgets/arena_custom_graphics.dart';
import 'package:protournament_user/widgets/voice_settings_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

String _read(String rel) => File('test/../$rel').readAsStringSync();

/// Source with full-line comments stripped, so a mention inside a
/// comment (e.g. "the 'Room Owner' subtitle is REMOVED") never
/// counts as code.
String _codeOnly(String src) =>
    src.split('\n').where((l) => !l.trimLeft().startsWith('//')).join('\n');

/// The body of a method (from its signature to the next method's
/// closing), for scoped assertions.
String _method(String src, String signature) {
  final start = src.indexOf(signature);
  expect(start, isNot(-1), reason: 'method not found: $signature');
  final end = src.indexOf('\n  }\n', start);
  expect(end, isNot(-1), reason: 'method end not found: $signature');
  return src.substring(start, end);
}

/// The two banned gold hexes, built ONLY from decimal char codes —
/// the literals must never appear in lib/ or test/ in any form.
String get _bannedGoldA =>
    String.fromCharCodes([70, 70, 67, 56, 48, 48]);
String get _bannedGoldB =>
    String.fromCharCodes([70, 53, 65, 57, 48, 48]);
String get _bannedPieceA =>
    String.fromCharCodes([48, 120, 67, 56, 48, 48]);
String get _bannedPieceB =>
    String.fromCharCodes([48, 120, 65, 57, 48, 48]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Fake Firebase FIRST (top-level setUpAll, before ANY test —
  // fix12_g6 pattern): the fakes must be in place before any
  // Firebase touch, or the delegate caches as real.
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
    // REAL PHONE METRICS: flutter_test's default font (Ahem)
    // renders every glyph 1em wide — ~40% wider than Roboto — so
    // the host card and chat header overflow at 360px in tests
    // while fitting fine on a real phone (63px + 2.6px of pure
    // font-metric artefact, verified 2026-11-23). Load the SDK's
    // Roboto so the 360px overflow checks measure what Sameer's
    // phone actually shows. Fails LOUDLY if the SDK fonts are
    // missing — a silent fallback would make the overflow checks
    // vacuous.
    await _loadRoboto();
    // FIX 22 item 6: the room auto-tries DSP on mount
    // (_installMicNoiseProcessor from initState). In widget tests
    // the native channel never answers, so initialize()'s 2s
    // timeout Timer stays pending past _settle's 1.6s and trips
    // the postTest invariant. Answer isAvailable -> false
    // immediately (the fix21 pattern): DSP fails fast as
    // native-absent (no retry), the room falls back to RNNoise,
    // no timer lingers.
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

  group('redesign S7 — F1 tokens: exact values', () {
    test('gold is exactly #FDC903, radii + spacing are the contract values',
        () {
      expect(kGold, const Color(0xFFFDC903));
      expect(kGoldDeep, const Color(0xFFFDC903));
      expect(kSpace4, 4);
      expect(kSpace8, 8);
      expect(kSpace12, 12);
      expect(kSpace16, 16);
      expect(kSpace20, 20);
      expect(kSpace24, 24);
      expect(kSpace32, 32);
      expect(kRadiusChip, 12);
      expect(kRadiusInput, 14);
      expect(kRadiusCard, 18);
      expect(kRadiusHero, 22);
      expect(kLiveRed, const Color(0xFFFF2D2D));
    });

    test('text styles carry the contract sizes', () {
      expect(kStyleTitle.fontSize, 22);
      expect(kStyleSection.fontSize, 18);
      expect(kStyleCardTitle.fontSize, 17);
      expect(kStyleCardTitle.fontWeight, FontWeight.w600);
      expect(kStyleBody.fontSize, 15);
      expect(kStyleMeta.fontSize, 13);
      expect(kStyleLabel.fontSize, 12);
      expect(kStyleLabel.fontWeight, FontWeight.w500);
    });
  });

  group('redesign S7 — GOLD RULE: banned golds absent', () {
    test('no banned gold hex in either changed lib file or this test', () {
      for (final rel in [
        'lib/screens/room_screen.dart',
        'lib/widgets/voice_settings_sheet.dart',
        'test/redesign_s7_voice_room_test.dart',
      ]) {
        final src = _read(rel);
        for (final banned in [
          _bannedGoldA,
          _bannedGoldB,
          _bannedGoldA.toLowerCase(),
          _bannedGoldB.toLowerCase(),
          _bannedPieceA,
          _bannedPieceB,
          _bannedPieceA.toLowerCase(),
          _bannedPieceB.toLowerCase(),
        ]) {
          expect(src.contains(banned), isFalse,
              reason: '$rel contains a banned gold form');
        }
      }
    });
  });

  group('redesign S7 — source: host strip is organizer-name-only', () {
    test('host strip pins the FIX 22 item 14 card (Host pill back, Room Owner still gone)',
        () {
      final room = _codeOnly(_read('lib/screens/room_screen.dart'));
      final strip = _method(room, 'Widget _buildHostStrip(');
      // FIX 22 item 14 (user order 2026-11-23) SUPERSEDES FIX 12
      // G7's "name only, no Host pill" rule: the gold Host pill
      // is BACK above the name. 'Room Owner' and the sample
      // tagline text stay GONE — never restored.
      expect(strip.contains('Text(\'Host\''), isTrue);
      expect(strip.contains("'Room Owner'"), isFalse);
      expect(strip.contains('Good Vibes'), isFalse);
      // The whole room file carries no 'Room Owner' / 'Good Vibes'
      // string outside comments either (only the G7 removal notes).
      expect(room.contains("'Room Owner'"), isFalse);
      expect(room.contains('Good Vibes'), isFalse);
    });

    test('host strip keeps the pinned literals (G7 name, v2015 radius)',
        () {
      final room = _read('lib/screens/room_screen.dart');
      final strip = _method(room, 'Widget _buildHostStrip(');
      // G7 pins the name's exact literal — the redesign keeps it.
      // FIX 31b: the name wears the AI Studio heading token now
      // (Rajdhani 17, w700) — same size, same Flexible + ellipsis.
      expect(
          strip,
          contains(
              'Flexible(child: Text(hostName, style: ArenaTypography.heading(17)'));
      // v2015 pins the card radius.
      expect(strip, contains('radius: 22'));
      // Fix 1/16/G9 pin the vertical padding literal.
      expect(strip, contains('vertical: compactControls ? 8 : 14'));
      // FIX 23 item 2 SUPERSEDES G9's two 8px compact-row gaps:
      // the compact card is two rows now (row 1: avatar + name
      // + mic; row 2: the status strip, a Wrap with spacing 8 /
      // runSpacing 6) — the G9 tightened gaps (4 -> 2 compact)
      // live in _buildHostLiveColumn, not the strip.
      expect(strip, isNot(contains('const SizedBox(width: 8),')));
      final col = _method(room, 'Widget _buildHostLiveColumn(');
      expect(col, contains('compact ? 2 : 4'));
      final statusStrip = _method(room, 'Widget _buildHostStatusStrip(');
      expect(statusStrip, contains('spacing: 8'));
      expect(statusStrip, contains('runSpacing: 6'));
      // The avatar ring is the AI Studio gold→blue gradient +
      // glow (§C). FIX 31b: royal gold + electric blue, same
      // 0.35 glow alpha as the old kGold ring.
      expect(strip, contains('[ArenaColors.royalGold, ArenaColors.electricBlue]'));
      expect(strip, contains('ArenaColors.royalGold.withValues(alpha: 0.35)'));
      // The §I compact fit: narrower card sides + tighter main gaps.
      expect(
          strip,
          contains(
              'horizontal: compactControls ? 12 : 14'));
      expect(strip, contains('SizedBox(width: compactControls ? 8 : 10)'));
    });

    test('Live pill + status line on the shared tokens', () {
      final room = _read('lib/screens/room_screen.dart');
      // FIX 23 item 2: the Live pill is extracted into
      // _buildLivePill (the compact card's status strip reuses
      // the identical widget) — pin it there, not in the column.
      final pill = _method(room, 'Widget _buildLivePill()');
      expect(pill, contains('BorderRadius.circular(kRadiusChip)'));
      expect(pill, contains("Text('Live'"));
      final col = _method(room, 'Widget _buildHostLiveColumn(');
      expect(col, contains('_buildLivePill()'));
      expect(col, contains('color: kMuted'));
    });
  });

  group('redesign S7 — source: Connecting pill, all four states', () {
    test('four labels + exact colour mapping preserved', () {
      final room = _read('lib/screens/room_screen.dart');
      final pill = _method(room, 'Widget _buildConnectingPill()');
      expect(pill, contains("? 'Voice On'"));
      expect(pill, contains("? 'Voice Failed'"));
      expect(pill, contains("? 'Connecting…'"));
      expect(pill, contains(": 'Not connected'"));
      // FIX 31b: the four-state colour mapping wears the AI
      // Studio tokens now — same four states, same order:
      // connected green / failed live-red / connecting royal
      // gold / idle secondary text.
      expect(pill, contains('? ArenaColors.connectedGreen'));
      expect(pill, contains('? ArenaColors.liveRed'));
      expect(pill, contains('? ArenaColors.royalGold'));
      expect(pill, contains(': ArenaColors.secondaryText'));
      // The §E pill treatment: chip radius from the tokens.
      expect(pill, contains('BorderRadius.circular(kRadiusChip)'));
    });
  });

  group('redesign S7 — source: seats, chat, composer', () {
    test('seat cells read PODIUM (electric-blue frame + disc) + purple locked (FIX 31b)',
        () {
      final room = _read('lib/screens/room_screen.dart');
      // FIX 31b SUPERSEDES the FIX 23 item 6 neon seats
      // (Sameer's explicit orders 2026-11-24 01:48 "same lagao"
      // for the AI Studio code + 03:07 embedded adaptation):
      // the cells wear the AI Studio podium look now —
      // electric-blue frame + podium disc under every live
      // seat, purple frame on locked cells (no disc — not a
      // live seat), royal gold on the '+N' overflow cell. The
      // seat-NUMBER badge keeps its neon ring (pinned by the
      // widget tests below) — only the cell look changed.
      final badge = _method(room, 'final neon = dimmed ? _neonSeat');
      expect(badge, contains('_neonSeat.withValues(alpha: 0.55)'));
      expect(badge, contains('_neonSeat.withValues(alpha: 0.4)'));
      final free = _method(room, 'Widget _stageCellFree(');
      expect(free,
          contains('PodiumDiscPainter(outerColor: ArenaColors.electricBlue)'));
      expect(free,
          contains('Border.all(color: ArenaColors.electricBlue, width: 2.2)'));
      expect(free, contains('LucideIcons.plus'));
      final locked = _method(room, 'Widget _stageCellLocked(');
      expect(locked, contains('ArenaColors.purple.withValues(alpha: 0.5)'));
      expect(locked, isNot(contains('PodiumDiscPainter')));
      final listener = _method(room, 'Widget _stageCellListener(');
      expect(listener,
          contains('ArenaColors.electricBlue.withValues(alpha: 0.7)'));
      expect(listener,
          contains('PodiumDiscPainter(outerColor: ArenaColors.electricBlue)'));
      final grid = _method(room, 'Widget _buildSeatGrid(');
      expect(grid, contains('ArenaColors.cardBg.withValues(alpha: 0.78)'));
      expect(grid, contains('BorderRadius.circular(20)'));
      expect(grid, contains('_fix31bPodiumHeader(occupiedCount)'));
    });

    test('empty-chat copy is unchanged, exactly once', () {
      final room = _read('lib/screens/room_screen.dart');
      expect('No messages yet. Say hi!'.allMatches(room).length, 1);
    });

    test('composer: card-shell field, gold send button, dark icon (FIX 23 item 29)', () {
      final room = _read('lib/screens/room_screen.dart');
      // FIX 23 item 29B SUPERSEDES the token field fill: the
      // composer field wears the card look now (CardFieldShell
      // gradient + purple border + glow) and the field itself is
      // borderless. Hint, send button + icon unchanged.
      expect(room, isNot(contains('fillColor: kField')));
      expect(room, contains('CardFieldShell('));
      expect(room, contains('border: const OutlineInputBorder(borderSide: BorderSide.none)'));
      expect(room, contains('hintStyle: TextStyle(color: kMuted)'));
      expect(room, contains('Icon(Icons.send, color: Colors.black)'));
      expect(room, contains('IconButton.styleFrom(backgroundColor: kGold)'));
    });

    test('voice-error Retry keeps the pinned G6b button shape', () {
      final room = _read('lib/screens/room_screen.dart');
      final banner = _method(room, 'Widget _buildVoiceConnectErrorBanner()');
      // FIX 12 G6b pins this exact ElevatedButton.icon shape —
      // the redesign keeps it (no shared-button swap here).
      expect(banner, contains('ElevatedButton.icon('));
      expect(banner, contains("onPressed: _lkConnecting ? null : _joinVoiceOpen"));
      expect(banner, contains("label: Text(_lkConnecting ? 'Connect ho raha hai…' : 'Retry'"));
      expect(banner, contains('backgroundColor: const Color(0xFFFDC903)'));
      expect(banner, contains('foregroundColor: Colors.black'));
    });
  });

  group('redesign S7 — source: settings sheet on the tokens', () {
    test('sheet title, rows and shape read the F1 tokens + card style (FIX 23 item 29)', () {
      final sheet = _read('lib/widgets/voice_settings_sheet.dart');
      expect(sheet, contains('kStyleCardTitle.copyWith(fontWeight: FontWeight.w900)'));
      expect(sheet, contains('kStyleBody.copyWith(fontWeight: FontWeight.w800)'));
      expect(sheet, contains('Text(subtitle, style: kStyleLabel)'));
      expect(sheet, contains('BorderRadius.circular(kRadiusChip)'));
      // FIX 23 item 29C SUPERSEDES the token sheet radius: sheets
      // wear the card style now (radius 22 + purple border).
      expect(sheet, isNot(contains('Radius.circular(kRadiusCard)')));
      expect(sheet, contains('Radius.circular(22)'));
      expect(sheet, contains('kCardPurpleBorder'));
      expect(sheet, contains('Divider(color: kBorder, height: kSpace24)'));
    });

    test('sheet bindings unchanged: pop-then-run + controller calls', () {
      final sheet = _read('lib/widgets/voice_settings_sheet.dart');
      expect(sheet, contains('controller.openMusic()'));
      expect(sheet, contains('controller.openRoomSettings()'));
      expect(sheet, contains('controller.openRjConsole()'));
      expect(sheet, contains('controller.closeVoice()'));
      expect(sheet, contains('if (controller.showRj)'));
    });
  });

  // Widget tests: fake Firebase + SupaDb.testFixtures (fix12_g6
  // pattern). Manual pumps only — never pumpAndSettle (the room's
  // animation controllers trip fake-time scheduler assertions).
  // ------------------------------------------------------------------
  group('redesign S7 — widget: embedded room at 360px', () {
    setUp(() async {
      await FirebaseAuth.instance.signInWithEmailAndPassword(
          email: 't@t.com', password: 'password');
      SupaDb.testFixtures = _fixtures(community: _unlockedCommunity());
    });

    tearDown(() async {
      SupaDb.testFixtures = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('flutter.baseflow.com/permissions/methods'),
              null);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('FlutterWebRTC.Method'), null);
      await FirebaseAuth.instance.signOut();
    });

    testWidgets('host card + 6 seats + idle pill, no overflow at 360px',
        (tester) async {
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
          ),
        ),
      ));
      await _settle(tester);
      expect(find.byType(UnifiedRoomPage), findsOneWidget);

      // Host card: FIX 23 item 17 (STRICT host rule) — with
      // nobody on voice the card shows 'No host' + an empty
      // picture slot, NEVER the admin's/organizer's name from
      // fixtures. The old 'Tester' pin was the exact bug item 17
      // fixed (a non-present user's name in the host slot).
      final name = tester.widget<Text>(find.text('No host'));
      expect(name.style?.fontSize, 17);
      // FIX 31b: the name wears the AI Studio heading token now
      // (Rajdhani 17, w700) — same size, same colour.
      expect(name.style?.fontWeight, FontWeight.w700);
      expect(name.style?.color, kText);
      expect(name.maxLines, 1);
      expect(name.overflow, TextOverflow.ellipsis);
      // FIX 22 item 14b: LIVE shows ONLY when the host is
      // actually on voice — this idle fixture's host is off
      // voice ('Not connected' + 'Offline' below), so NO Live
      // badge may show on the dead room.
      expect(find.text('Live'), findsNothing);
      // FIX 22 item 14: the gold Host pill is BACK above the
      // name (supersedes G7's "name only" rule). The OLD
      // top-box labels stay ABSENT — never restored.
      final panel = find.byType(UnifiedRoomPage);
      expect(find.descendant(of: panel, matching: find.text('Host')),
          findsOneWidget);
      expect(find.descendant(of: panel, matching: find.text('Room Owner')),
          findsNothing);
      expect(
          find.descendant(
              of: panel, matching: find.textContaining('Good Vibes')),
          findsNothing);
      expect(find.descendant(of: panel, matching: find.text('Admin')),
          findsNothing);

      // Idle pill: 'Not connected', muted, 9px heavy.
      // FIX 31b: the idle colour is the AI Studio secondary text
      // token now — same 9px heavy treatment.
      expect(find.text('Not connected'), findsOneWidget);
      final pill = tester.widget<Text>(find.text('Not connected'));
      expect(pill.style?.color, ArenaColors.secondaryText);
      expect(pill.style?.fontSize, 9);
      expect(pill.style?.fontWeight, FontWeight.w800);
      // FIX 23 item 2: the compact card's row-2 status strip
      // shows 'Disconnected' (same _voiceConnected truth) — the
      // full-page 'Offline' presence line is not rendered here.
      expect(find.text('Disconnected'), findsOneWidget);
      expect(find.text('Offline'), findsNothing);

      // 3x2 seats: 1..6 present, no 7th; seat numbers in WHITE
      // (FIX 23 item 6 neon — the gold number is gone).
      for (var n = 1; n <= 6; n++) {
        expect(find.text('$n'), findsOneWidget);
      }
      expect(find.text('7'), findsNothing);
      final seat1 = tester.widget<Text>(find.text('1'));
      expect(seat1.style?.color, Colors.white);
      expect(seat1.style?.fontSize, 17);
      expect(seat1.style?.fontWeight, FontWeight.w900);
      // The six free seats carry the AI Studio PODIUM disc
      // (FIX 31b supersedes the FIX 23 item 6 neon gradient
      // ring): a PodiumDiscPainter under each seat, electric
      // blue for a free seat.
      final discs = tester.widgetList<CustomPaint>(find.byType(CustomPaint)).where(
          (p) => p.painter is PodiumDiscPainter).length;
      expect(discs, 6);

      // No overflow at 360px width (overflow surfaces as a test
      // exception in the widget framework).
      expect(tester.takeException(), isNull);

      // Close the mounted panel before the test ends (a room left
      // mounted pollutes the next widget test).
      await tester.pumpWidget(
          const MaterialApp(home: Scaffold(body: Text('closed'))));
      await tester.pump();
    });

    testWidgets('failed join -> Voice Failed pill + F2 Retry button',
        (tester) async {
      _mockPermissionsGranted();
      _mockWebRtcThrows();
      tester.view.physicalSize = const Size(360, 900);
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
          ),
        ),
      ));
      await _settle(tester);
      expect(find.byType(UnifiedRoomPage), findsOneWidget);

      // Join via a seat tap (admin -> slot dialog). The mesh join
      // fails in tests (no mic plugin) — the failure must be
      // VISIBLE with a way back, never a stuck pill.
      final seat1 = find.descendant(
          of: find.byType(UnifiedRoomPage), matching: find.text('1'));
      await tester.ensureVisible(seat1);
      await tester.tap(seat1);
      await _settle(tester);
      await tester.tap(find.text('Mic 1 (suggested)'));
      await _settle(tester);
      expect(find.text('Voice connect nahi ho saka'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      // The Retry action is the pinned gold button (G6b shape:
      // gold fill, dark text) — its label is the tap target.
      final retry = tester.widget<ElevatedButton>(
          find.widgetWithText(ElevatedButton, 'Retry'));
      expect(retry.style?.backgroundColor?.resolve({}),
          const Color(0xFFFDC903));
      // Pill: failed, red — never stuck on 'Connecting…'.
      // FIX 31b: the failed red is the AI Studio liveRed token.
      expect(find.text('Voice Failed'), findsOneWidget);
      final failed = tester.widget<Text>(find.text('Voice Failed'));
      expect(failed.style?.color, ArenaColors.liveRed);
      expect(failed.style?.fontSize, 9);
      expect(failed.style?.fontWeight, FontWeight.w800);
      expect(find.text('Connecting…'), findsNothing);
      // Host line: this phone is not on voice, so presence is
      // unknown — the compact card's row-2 status strip shows
      // 'Disconnected' (FIX 23 item 2; the full-page 'Not
      // connected' presence line lives only in
      // _buildHostLiveColumn now), never a false 'Offline'.
      expect(find.text('Disconnected'), findsOneWidget);
      expect(tester.takeException(), isNull);

      // Retry re-runs the join and lands on the SAME honest
      // error state — still never stuck on 'Connecting…'.
      await tester.tap(find.text('Retry'));
      await _settle(tester);
      expect(find.text('Voice connect nahi ho saka'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('Voice Failed'), findsOneWidget);
      expect(find.text('Connecting…'), findsNothing);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(
          const MaterialApp(home: Scaffold(body: Text('closed'))));
      await tester.pump();
    });
  });

  group('redesign S7 — widget: full room page at 360px', () {
    setUp(() async {
      await FirebaseAuth.instance.signInWithEmailAndPassword(
          email: 't@t.com', password: 'password');
      SupaDb.testFixtures = _fixtures(community: _unlockedCommunity());
    });

    tearDown(() async {
      SupaDb.testFixtures = null;
      await FirebaseAuth.instance.signOut();
    });

    testWidgets('chat panel + empty state + composer, no overflow',
        (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(
        home: UnifiedRoomPage(
          scope: 'community',
          communityId: 'comm-1',
          communityName: 'TEST COMMUNITY',
          organizerUid: 'test-uid',
          micCount: 6,
        ),
      ));
      await _settle(tester);
      expect(find.byType(UnifiedRoomPage), findsOneWidget);

      // Host card + seats render in full-page mode too.
      // FIX 23 item 17: nobody on voice -> 'No host' (never a
      // fixture name in the host slot).
      expect(find.text('No host'), findsOneWidget);
      expect(find.text('Tester'), findsNothing);
      // FIX 22 item 14b: no LIVE badge while the host is off
      // voice (same idle fixture as the embedded test).
      expect(find.text('Live'), findsNothing);
      for (var n = 1; n <= 6; n++) {
        expect(find.text('$n'), findsOneWidget);
      }
      // Rail present (Room Home first).
      expect(find.text('Room Home'), findsOneWidget);

      // Chat panel: header + the UNCHANGED empty-state copy.
      expect(find.text('LIVE CHAT'), findsOneWidget);
      expect(find.text('No messages yet. Say hi!'), findsOneWidget);
      final empty = tester.widget<Text>(find.text('No messages yet. Say hi!'));
      expect(empty.style?.color, kMuted);
      expect(empty.style?.fontSize, 14);
      // The §F flanking divider lines: two gold-fade gradients.
      final lines = tester.widgetList<Container>(find.byType(Container)).where(
          (c) {
        final d = c.decoration;
        if (d is! BoxDecoration) return false;
        final g = d.gradient;
        if (g is! LinearGradient) return false;
        return g.colors.contains(kGold.withValues(alpha: 0.6)) &&
            g.colors.contains(kGold.withValues(alpha: 0));
      }).length;
      expect(lines, 2);

      // Composer: card-shell field (FIX 23 item 29B — the token
      // fill is gone; the field is borderless inside
      // CardFieldShell) + gold circular send button with a dark
      // icon.
      final field = tester.widget<TextField>(find.byType(TextField).first);
      final deco = field.decoration!;
      expect(deco.fillColor, isNull);
      expect((deco.border as OutlineInputBorder).borderSide.style,
          BorderStyle.none);
      expect(
          find.ancestor(
              of: find.byType(TextField).first,
              matching: find.byType(CardFieldShell)),
          findsOneWidget);
      expect(deco.hintStyle?.color, kMuted);
      final sendBtn =
          tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.send));
      expect(sendBtn.style?.backgroundColor?.resolve({}), kGold);
      final sendIcon = tester.widget<Icon>(find.byIcon(Icons.send));
      expect(sendIcon.color, Colors.black);

      expect(tester.takeException(), isNull);

      await tester.pumpWidget(
          const MaterialApp(home: Scaffold(body: Text('closed'))));
      await tester.pump();
    });
  });

  group('redesign S7 — widget: seat number badge', () {
    testWidgets('badge shows the number in white, neon ring with glow (FIX 23 item 6)', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: Center(child: MicSeatNumberBadge(seatNo: 3)),
        ),
      ));
      await tester.pump();
      final num = tester.widget<Text>(find.text('3'));
      expect(num.style?.color, Colors.white);
      expect(num.style?.fontSize, 10);
      expect(num.style?.fontWeight, FontWeight.w900);
      // The outer ring container: NEON gradient ring + soft neon
      // glow (the inner disc is the dark gradient — filter by ring).
      final rings = tester.widgetList<Container>(find.ancestor(
          of: find.text('3'), matching: find.byType(Container))).where((c) {
        final d = c.decoration;
        if (d is! BoxDecoration) return false;
        final g = d.gradient;
        return g is LinearGradient && g.colors.isNotEmpty && g.colors[0] == const Color(0xFFC026D3);
      }).toList();
      expect(rings, hasLength(1));
      final deco = rings.first.decoration! as BoxDecoration;
      expect(deco.shape, BoxShape.circle);
      final gradient = deco.gradient! as LinearGradient;
      expect(gradient.colors[0], const Color(0xFFC026D3));
      expect(gradient.colors[1], const Color(0xFF7E22CE));
      expect(deco.boxShadow, isNotNull);
      expect(deco.boxShadow!.first.color,
          const Color(0xFFC026D3).withValues(alpha: 0.4));
      expect(tester.takeException(), isNull);
    });

    testWidgets('dimmed badge: muted neon, no glow (FIX 23 item 6)', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: Center(child: MicSeatNumberBadge(seatNo: 5, dimmed: true)),
        ),
      ));
      await tester.pump();
      final num = tester.widget<Text>(find.text('5'));
      expect(num.style?.color, Colors.white);
      final rings = tester.widgetList<Container>(find.ancestor(
          of: find.text('5'), matching: find.byType(Container))).where((c) {
        final d = c.decoration;
        if (d is! BoxDecoration) return false;
        final g = d.gradient;
        return g is LinearGradient &&
            g.colors.isNotEmpty &&
            g.colors[0] == const Color(0xFFC026D3).withValues(alpha: 0.55);
      }).toList();
      expect(rings, hasLength(1));
      final deco = rings.first.decoration! as BoxDecoration;
      expect(deco.boxShadow, isNull);
      expect(tester.takeException(), isNull);
    });
  });

  group('redesign S7 — widget: voice settings sheet', () {
    testWidgets('rows, token styles, pop-then-run bindings', (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = VoicePanelController();
      var music = false;
      var settings = false;
      var rj = false;
      var closed = false;
      controller.bind(
        onMusic: () => music = true,
        onRoomSettings: () => settings = true,
        onRjConsole: () => rj = true,
        onCloseVoice: () => closed = true,
        rjVisible: () => true,
      );
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () =>
                    showVoiceSettingsSheet(context, controller),
                child: const Text('open sheet'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open sheet'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // Title on the card-title token, heavy.
      final title = tester.widget<Text>(find.text('Voice Settings'));
      expect(title.style?.fontSize, 17);
      expect(title.style?.fontWeight, FontWeight.w900);
      // All four rows (RJ visible: broadcast admin).
      expect(find.text('Music'), findsOneWidget);
      expect(find.text('Room Settings'), findsOneWidget);
      expect(find.text('RJ Studio'), findsOneWidget);
      expect(find.text('Close voice'), findsOneWidget);
      // Row title + subtitle on the body/label tokens.
      final rowTitle = tester.widget<Text>(find.text('Music'));
      expect(rowTitle.style?.fontSize, 15);
      expect(rowTitle.style?.fontWeight, FontWeight.w800);
      expect(rowTitle.style?.color, kText);
      final sub =
          tester.widget<Text>(find.text('Play music in this room'));
      expect(sub.style?.fontSize, 12);
      expect(sub.style?.color, kTextMuted);
      // Music icon circle: gold-tinted fill + gold border.
      final circles = tester.widgetList<Container>(find.ancestor(
          of: find.byIcon(Icons.music_note),
          matching: find.byType(Container))).where((c) {
        final d = c.decoration;
        if (d is! BoxDecoration) return false;
        return d.shape == BoxShape.circle &&
            d.color == kGold.withValues(alpha: 0.12);
      }).toList();
      expect(circles, hasLength(1));
      final deco = circles.first.decoration! as BoxDecoration;
      expect(deco.shape, BoxShape.circle);
      expect(deco.color, kGold.withValues(alpha: 0.12));
      expect((deco.border! as Border).top.color,
          kGold.withValues(alpha: 0.4));
      // Close voice is the destructive row (live-red icon).
      final closeIcon = tester.widget<Icon>(find.byIcon(Icons.close).first);
      expect(closeIcon.color, kLiveRed);

      // Tap Music: the sheet pops, then the action runs.
      await tester.tap(find.text('Music'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Voice Settings'), findsNothing);
      expect(music, isTrue);
      expect(settings, isFalse);
      expect(rj, isFalse);
      expect(closed, isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('RJ row hidden when the controller hides it', (tester) async {
      final controller = VoicePanelController();
      controller.bind(onMusic: () {});
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () =>
                    showVoiceSettingsSheet(context, controller),
                child: const Text('open sheet'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open sheet'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('RJ Studio'), findsNothing);
      expect(find.text('Music'), findsOneWidget);
      expect(find.text('Close voice'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}

/// Load the Flutter SDK's Roboto (Regular/Medium/Bold/Black) so
/// widget-test layout uses real-phone glyph metrics instead of the
/// 1em-wide Ahem test font. Throws if the SDK fonts are absent.
Future<void> _loadRoboto() async {
  final home = Platform.environment['HOME'] ?? '';
  final dir =
      '$home/flutter/bin/cache/artifacts/material_fonts';
  final loader = FontLoader('Roboto');
  for (final file in [
    'Roboto-Regular.ttf',
    'Roboto-Medium.ttf',
    'Roboto-Bold.ttf',
    'Roboto-Black.ttf',
  ]) {
    final path = '$dir/$file';
    final bytes = await File(path).readAsBytes().catchError((e) {
      throw StateError(
          'redesign S7 needs the SDK Roboto for real-phone metrics; missing: $path ($e)');
    });
    loader.addFont(Future.value(bytes.buffer.asByteData()));
  }
  await loader.load();
}

/// Pump past the fixture futures (getProfile/getCommunity/
/// member counts) and the embedded panel's post-frame auto-join.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}

Map<String, dynamic> _unlockedCommunity() => {
      'id': 'comm-1',
      'name': 'TEST COMMUNITY',
      'description': 'Test community',
      'created_by_uid': 'test-uid',
      'voice_enabled': true,
      'isMember': true,
      'myRole': 'creator',
      'memberCount': 1,
    };

Map<String, List<Map<String, dynamic>>> _fixtures(
        {required Map<String, dynamic> community, bool member = true}) =>
    {
      'communities': [community],
      'community_members': member
          ? [
              {
                'community_id': community['id'],
                'firebase_uid': 'test-uid',
                'role': 'creator',
              }
            ]
          : [],
      'community_voice_requests': [],
      'profiles': [
        {
          'firebase_uid': 'test-uid',
          'display_name': 'Tester',
          'level': 1,
        }
      ],
      'admin_config': [
        {'id': 1, 'admin_firebase_uid': 'test-uid'}
      ],
      'chat_messages': [],
      'presence': [],
    };

/// Mock flutter_webrtc: every channel call throws (no mic plugin in
/// tests). Cleared by the widget group's tearDown.
void _mockWebRtcThrows() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('FlutterWebRTC.Method'),
    (call) async =>
        throw PlatformException(code: 'NO_MIC', message: 'No mic in tests'),
  );
}

/// Mock permission_handler: every requested permission is granted.
/// Cleared by the widget group's tearDown.
void _mockPermissionsGranted() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('flutter.baseflow.com/permissions/methods'),
    (call) async {
      if (call.method == 'requestPermissions') {
        final args = (call.arguments as List).cast<int>();
        return {for (final v in args) v: 1};
      }
      if (call.method == 'checkPermissionStatus') return 1;
      return null;
    },
  );
}

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
