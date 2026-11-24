// FIX 16 — VOICE-ROOM HEADER CONTROLS (user order 2026-11-23,
// voice call): (1) the top-bar Voice button toggles the WHOLE
// voice panel (host card + mic seats + all voice UI); (2) the
// Connecting pill moved UP into the host card, NEXT TO the green
// Unmute mic button (same row: Live column, pill, mic); (3) the
// top-bar More button becomes Settings while the panel is open
// and opens the voice settings sheet with ALL voice functions
// (Music, Room Settings, RJ Studio for broadcast admins, Close
// voice); (4) the bottom Music/Settings/Close row is gone (it
// was already gone since Fix 1 — this pins it STAYS gone, with
// Music/Settings/RJ relocated to the sheet, not deleted);
// (5) the host card is more compact (tighter padding/spacing).
//
// SUPERSESSION NOTE: Fix 16 deliberately supersedes Fix 1's
// placement pins (fix1_voice_panel_compact_test.dart) — Fix 1 put
// Music/Settings/RJ icons in a controls row ABOVE the mic, Fix 16
// moves them to the header Settings sheet and the pill beside the
// mic. The Fix 1 tests that pin the old row WILL fail after this
// change; that is the user order, not a regression. The mic size
// (56px), the toggle behaviour and the full-page host card are
// unchanged and still pinned here.
//
// A-7 BOUNDARY: the "Host" pill / "Room Owner" subtitle / bio /
// "Admin" text are owned by parallel item A-7 — Fix 16 does NOT
// remove them (pinned present below) and does not depend on them.
//
// Widget tests reuse the fake-Firebase pattern from
// v2017_voice_toggle_test.dart + SupaDb.testFixtures. HONEST
// LIMIT: a widget test cannot prove the mic is really connected
// (no mic, no network in tests) — the pill-position assertions
// below prove layout (same row as the mic, above the seats), and
// the controller tests prove the sheet's rows fire the panel's
// real callbacks.
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_auth_platform_interface/firebase_auth_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/components/arena_chat.dart';
import 'package:protournament_user/screens/pro_features.dart';
import 'package:protournament_user/screens/room_screen.dart';
import 'package:protournament_user/services/supabase_db.dart';
import 'package:protournament_user/widgets/voice_settings_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

String _read(String rel) => File('test/../$rel').readAsStringSync();

/// Source with full-line comments stripped, so a mention inside a
/// comment (e.g. "the old Fix 1 controls row") never counts as code.
String _codeOnly(String src) => src.split('\n').where((l) => !l.trimLeft().startsWith('//')).join('\n');

/// The slice of [src] between two markers (exclusive of the end
/// marker), for scoped assertions.
String _region(String src, String start, String end) {
  final s = src.indexOf(start);
  expect(s, isNot(-1), reason: 'region start not found: $start');
  final e = src.indexOf(end, s + start.length);
  expect(e, isNot(-1), reason: 'region end not found: $end');
  return src.substring(s, e);
}

void main() {
  group('FIX 16 — source pins', () {
    late String room;
    late String code;
    late String features;
    late String chat;
    late String sheet;

    setUpAll(() {
      room = _read('lib/screens/room_screen.dart');
      code = _codeOnly(room);
      features = _read('lib/screens/pro_features.dart');
      chat = _read('lib/components/arena_chat.dart');
      sheet = _read('lib/widgets/voice_settings_sheet.dart');
    });

    test('(a) Voice toggle shows/hides the WHOLE panel', () {
      final featCode = _codeOnly(features);
      expect(featCode.contains('void _toggleVoice()'), isTrue);
      expect(featCode.contains('onVoice: _isTournament ? null : _toggleVoice'), isTrue);
      expect(featCode.contains('voiceActive: _voicePanelOpen'), isTrue);
      // The toggle mounts/unmounts the panel — the whole embedded
      // room page (host card + seats + banners), not a section.
      expect(featCode.contains('if (_voicePanelOpen && !_isTournament) _buildVoicePanel()'), isTrue);
      final panel = _region(featCode, 'Widget _buildVoicePanel() {', 'void _onLockedVoiceTap() {');
      expect(panel.contains('UnifiedRoomPage('), isTrue);
      expect(panel.contains('embedded: true,'), isTrue);
      expect(panel.contains('onCloseVoice:'), isTrue);
      // The panel reaches the header Settings sheet via the bridge.
      expect(panel.contains('voiceController: _voiceController,'), isTrue);
      // Embedded mode renders the voice sections only.
      expect(code.contains('if (widget.embedded) return _buildEmbeddedVoice(uid, peers, kbOpen);'), isTrue);
      final embedded = _region(code, 'Widget _buildEmbeddedVoice(', '@override\n  Widget build(BuildContext context)');
      expect(embedded.contains('_buildHostStrip(uid, peers, compactControls: true)'), isTrue);
      expect(embedded.contains('_buildSeatGrid(uid, peers, kbOpen)'), isTrue);
    });

    test('(b) Connecting pill is in the host card, in the status strip', () {
      final strip = _region(code, 'Widget _buildHostStrip(', 'Widget _buildHostLiveColumn(');
      // The pill builder exists and the status strip mounts it.
      expect(code.contains('Widget _buildConnectingPill()'), isTrue);
      expect(code.contains('Widget _buildHostStatusStrip('), isTrue);
      final status = _region(code, 'Widget _buildHostStatusStrip(',
          'Widget _buildHostLiveColumn(');
      expect(status.contains('_buildConnectingPill()'), isTrue);
      // FIX 23 item 2 SUPERSEDES the one-row layout: the compact
      // card is TWO rows — Row 1 (avatar + name + mic), Row 2
      // (the status strip with the pill). The strip mounts the
      // status strip in the compact branch, AFTER the mic row.
      expect(strip.contains('_buildHostStatusStrip('), isTrue);
      final compactAt = strip.indexOf('if (compactControls)');
      expect(compactAt, isNot(-1));
      final micAt = strip.indexOf('_buildHostMicButton(', compactAt);
      final statusAt = strip.indexOf('_buildHostStatusStrip(', compactAt);
      expect(micAt, lessThan(statusAt),
          reason: 'mic row comes before the status strip row');
      // The pill itself is unchanged (small 9px text, same copy).
      // FIX 31b: the 9px text wears the AI Studio body token now
      // (Inter 9, w800) — same size, same copy.
      final pill = _region(code, 'Widget _buildConnectingPill()', 'List<Widget> _buildRequestBanners()');
      expect(pill.contains("'Voice On'"), isTrue);
      expect(pill.contains("'Connecting…'"), isTrue);
      expect(pill.contains('ArenaTypography.body(9'), isTrue);
      // NOT below the mics: the embedded panel body never mentions
      // the pill (it lives in the host strip, above the seats).
      final embedded = _region(code, 'Widget _buildEmbeddedVoice(', '@override\n  Widget build(BuildContext context)');
      expect(embedded.contains('Connecting'), isFalse);
      expect(embedded.contains('_buildConnectingPill'), isFalse);
      // Fix 1's above-mic controls row + icon helper are deleted
      // (superseded — see the file header note).
      expect(code.contains('_buildHostCardControls'), isFalse);
      expect(code.contains('_hostCardIconBtn'), isFalse);
    });

    test('(c) Settings sheet replaces More, holds all voice functions', () {
      // The header gains a Settings button that replaces More.
      expect(chat.contains('final VoidCallback? onSettings;'), isTrue);
      expect(chat.contains("label: 'Settings'"), isTrue);
      expect(chat.contains('Icons.settings'), isTrue);
      // TeamChatPage wires it while the panel is open (team mode).
      expect(features.contains('onSettings: (_voicePanelOpen && !_isTournament) ? () => showVoiceSettingsSheet(context, _voiceController) : null,'), isTrue);
      // The sheet holds every voice function.
      expect(sheet.contains("title: 'Music'"), isTrue);
      expect(sheet.contains("title: 'Room Settings'"), isTrue);
      expect(sheet.contains("title: 'RJ Studio'"), isTrue);
      expect(sheet.contains("title: 'Close voice'"), isTrue);
      expect(sheet.contains('showRj'), isTrue);
      expect(sheet.contains('Future<void> showVoiceSettingsSheet('), isTrue);
      // The room binds its REAL actions into the bridge (nothing
      // is a stub, nothing is dropped).
      expect(code.contains('final VoicePanelController? voiceController;'), isTrue);
      final bind = _region(code, 'void _bindVoiceController() {', 'void didUpdateWidget(');
      // FIX 22 item 21: Music opens the RJ console focused on
      // the PLAYER section (no standalone player sheet).
      expect(bind.contains('onMusic: () => unawaited('), isTrue);
      expect(bind.contains("_showRjVoiceConsole(initialSection: 'player')"),
          isTrue);
      expect(bind.contains('onRoomSettings: _showRoomSettings,'), isTrue);
      expect(bind.contains('onRjConsole: _showRjVoiceConsole,'), isTrue);
      expect(bind.contains('onCloseVoice: widget.onCloseVoice,'), isTrue);
      // FIX 20 (fix 7b): RJ is for the ROOM HOST (admin / team
      // captain / community organizer) — not admin-only.
      expect(
          bind.contains(
              'rjVisible: () =>\n          _isAdminForBroadcast ||\n          _isTeamCaptainForBroadcast ||\n          _isCommunityOrganizerForBroadcast,'),
          isTrue);
      expect(code.contains('widget.voiceController?.unbind();'), isTrue);
    });

    test('(d) bottom Music/Settings/Close row is gone', () {
      expect(code.contains('_buildEmbeddedControls'), isFalse);
      expect(code.contains('_embeddedControlBtn'), isFalse);
      final embedded = _region(code, 'Widget _buildEmbeddedVoice(', '@override\n  Widget build(BuildContext context)');
      expect(embedded.contains('Icons.music_note'), isFalse);
      expect(embedded.contains('Icons.settings'), isFalse);
      expect(embedded.contains('Icons.close'), isFalse);
      expect(embedded.contains("'Close'"), isFalse);
      // No music/settings icon buttons left in the host strip.
      final strip = _region(code, 'Widget _buildHostStrip(', 'Widget _buildHostLiveColumn(');
      expect(strip.contains('Icons.music_note'), isFalse);
      expect(strip.contains('_showMusicPanel'), isFalse);
      expect(strip.contains('_showRoomSettings'), isFalse);
    });

    test('(e) host card is SHORTER (tighter padding + gaps)', () {
      final strip = _region(code, 'Widget _buildHostStrip(', 'Widget _buildHostLiveColumn(');
      // Card padding: vertical 10 -> 8 in compact mode (Fix 1 had
      // 10, the full page keeps 14).
      expect(strip.contains('vertical: compactControls ? 8 : 14'), isTrue);
      // FIX 12 A-7 (merged AFTER Fix 16): the text-column gaps are
      // GONE entirely — A-7 removed the pill + both gaps +
      // subtitle + tagline from the top box, so the card is
      // tighter still. The old '? 2 : 4' pin is superseded.
      expect(strip.contains('compactControls ? 2 : 4'), isFalse);
      expect(strip.contains('compactControls ? 3 : 4'), isFalse);
      // The full room page keeps the current (roomier) host card.
      expect(code.contains('          _buildHostStrip(uid, peers),'), isTrue);
      // Guard: the green mic stays BIG (56px, icon 24).
      final mic = _region(code, 'Widget _buildHostMicButton(', 'Widget _buildConnectingPill()');
      expect(mic.contains('width: 56,'), isTrue);
      expect(mic.contains('height: 56,'), isTrue);
      expect(mic.contains('size: 24'), isTrue);
    });

    test('A-7 boundary: Host pill is BACK (FIX 22 item 14); Room Owner still gone', () {
      // Parallel item A-7 owns removing these — Fix 16 must neither
      // remove them nor depend on them. A-7 MERGED (Host pill
      // gone), but FIX 22 item 14 SUPERSEDES it: the user's latest
      // direct order keeps the gold Host pill above the name.
      // 'Room Owner' and the sample tagline stay gone.
      expect(code.contains("'Room Owner'"), isFalse);
      // FIX 31b: the pill is the AI Studio host-card pill now —
      // a Row with a Lucide crown + token-styled 'Host' text on
      // a royal-gold fill (same pill as the full-page screen).
      expect(code.contains("Text('Host', style: ArenaTypography.body(10, color: ArenaColors.primaryBg, weight: FontWeight.w800))"), isTrue,
          reason: 'FIX 22 item 14 brings the Host pill back');
      expect(code.contains("'Good Vibes • Real Talks • Heart Connects'"), isFalse);
    });

    test('gold is #FDC903 only; no clan references in the new sheet', () {
      expect(sheet.toLowerCase().contains('clan'), isFalse);
      expect(sheet.contains('Color(0xFF'), isFalse, reason: 'the sheet must use the kGold token, no new hex');
      expect(sheet.contains('kGold'), isTrue);
    });

    test('pubspec version untouched (1.0.1+2023)', () {
      expect(_read('pubspec.yaml').contains('version: 1.0.1+2023'), isTrue);
    });
  });

  group('FIX 16 — VoicePanelController (unit)', () {
    test('bind -> actions fire; unbind -> safe no-ops', () {
      final c = VoicePanelController();
      expect(c.isBound, isFalse);
      expect(c.showRj, isFalse);
      // Unbound calls never throw.
      c.openMusic();
      c.openRoomSettings();
      c.openRjConsole();
      c.closeVoice();

      var music = 0, settings = 0, rj = 0, close = 0;
      c.bind(
        onMusic: () => music++,
        onRoomSettings: () => settings++,
        onRjConsole: () => rj++,
        onCloseVoice: () => close++,
        rjVisible: () => true,
      );
      expect(c.isBound, isTrue);
      expect(c.showRj, isTrue);
      c.openMusic();
      c.openRoomSettings();
      c.openRjConsole();
      c.closeVoice();
      expect([music, settings, rj, close], [1, 1, 1, 1]);

      c.unbind();
      expect(c.isBound, isFalse);
      expect(c.showRj, isFalse);
      c.openMusic();
      c.openRoomSettings();
      c.openRjConsole();
      c.closeVoice();
      expect([music, settings, rj, close], [1, 1, 1, 1]);
      c.dispose();
    });

    test('showRj re-evaluates the getter (late admin load)', () {
      var admin = false;
      final c = VoicePanelController()..bind(rjVisible: () => admin);
      expect(c.showRj, isFalse);
      admin = true;
      expect(c.showRj, isTrue);
      c.dispose();
    });
  });

  group('FIX 16 — widget: header Settings replaces More', () {
    testWidgets('onSettings set -> Settings button, no More popup', (tester) async {
      var tapped = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ArenaChatHeader(
            onBack: () {},
            titleName: 'TEST CH',
            subtitle: '1 member',
            onVoice: () {},
            voiceActive: true,
            onSettings: () => tapped++,
            moreItems: const [ArenaChatMenuItem('invite', 'Invite player')],
          ),
        ),
      ));
      await tester.pump();
      expect(find.text('Settings'), findsOneWidget);
      expect(find.text('More'), findsNothing);
      expect(find.text('Voice'), findsOneWidget);
      await tester.tap(find.text('Settings'));
      await tester.pump();
      expect(tapped, 1);
    });

    testWidgets('onSettings null -> More popup as before', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ArenaChatHeader(
            onBack: () {},
            titleName: 'TEST CH',
            subtitle: '1 member',
            onVoice: () {},
            moreItems: const [ArenaChatMenuItem('invite', 'Invite player')],
          ),
        ),
      ));
      await tester.pump();
      expect(find.text('More'), findsOneWidget);
      expect(find.text('Settings'), findsNothing);
    });
  });

  group('FIX 16 — widget: settings sheet rows + gating', () {
    late VoicePanelController controller;
    var music = 0;
    var settings = 0;
    var rj = 0;
    var close = 0;

    Widget openSheet({required bool admin}) {
      controller = VoicePanelController()
        ..bind(
          onMusic: () => music++,
          onRoomSettings: () => settings++,
          onRjConsole: () => rj++,
          onCloseVoice: () => close++,
          rjVisible: () => admin,
        );
      return MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showVoiceSettingsSheet(context, controller),
              child: const Text('OPEN'),
            ),
          ),
        ),
      );
    }

    setUp(() {
      music = 0;
      settings = 0;
      rj = 0;
      close = 0;
    });

    tearDown(() => controller.dispose());

    testWidgets('admin sees all four rows; Music fires + pops', (tester) async {
      await tester.pumpWidget(openSheet(admin: true));
      await tester.tap(find.text('OPEN'));
      await tester.pumpAndSettle();
      expect(find.text('Voice Settings'), findsOneWidget);
      expect(find.text('Music'), findsOneWidget);
      expect(find.text('Room Settings'), findsOneWidget);
      expect(find.text('RJ Studio'), findsOneWidget);
      expect(find.text('Close voice'), findsOneWidget);

      await tester.tap(find.text('Music'));
      await tester.pumpAndSettle();
      expect(music, 1);
      expect(find.text('Voice Settings'), findsNothing, reason: 'the sheet pops before the action runs');
    });

    testWidgets('non-admin sees no RJ row; Close voice fires + pops', (tester) async {
      await tester.pumpWidget(openSheet(admin: false));
      await tester.tap(find.text('OPEN'));
      await tester.pumpAndSettle();
      expect(find.text('Music'), findsOneWidget);
      expect(find.text('Room Settings'), findsOneWidget);
      expect(find.text('RJ Studio'), findsNothing);
      expect(find.text('Close voice'), findsOneWidget);

      await tester.tap(find.text('Close voice'));
      await tester.pumpAndSettle();
      expect(close, 1);
      expect(find.text('Voice Settings'), findsNothing);
    });

    testWidgets('Room Settings + RJ Studio rows fire', (tester) async {
      await tester.pumpWidget(openSheet(admin: true));
      await tester.tap(find.text('OPEN'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Room Settings'));
      await tester.pumpAndSettle();
      expect(settings, 1);

      await tester.tap(find.text('OPEN'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('RJ Studio'));
      await tester.pumpAndSettle();
      expect(rj, 1);
    });
  });

  // ------------------------------------------------------------------
  // Widget tests: fake Firebase (pattern from
  // v2017_voice_toggle_test.dart) + SupaDb.testFixtures.
  // ------------------------------------------------------------------
  group('FIX 16 — widget: full header flow on TeamChatPage', () {
    setUpAll(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
      FirebasePlatform.instance = _FakeCorePlatform();
      FirebaseAuthPlatform.instance = _FakeAuthPlatform();
      await Firebase.initializeApp();
      // ignore: unnecessary_statements
      FirebaseAuth.instance;
    });

    setUp(() async {
      await FirebaseAuth.instance.signInWithEmailAndPassword(email: 't@t.com', password: 'password');
      SupaDb.testFixtures = _fixtures(team: _team());
    });

    tearDown(() async {
      SupaDb.testFixtures = null;
      await FirebaseAuth.instance.signOut();
    });

    testWidgets('panel closed -> More; panel open -> Settings replaces More', (tester) async {
      await tester.pumpWidget(MaterialApp(home: TeamChatPage(team: _team(), uid: 'test-uid')));
      await _settle(tester);
      expect(find.byType(UnifiedRoomPage), findsNothing);
      expect(find.text('More'), findsOneWidget);
      expect(find.text('Settings'), findsNothing);

      // ON: whole panel mounts (host card + seats), More -> Settings.
      await tester.tap(_headerButton(tester, 'Voice'));
      await _settle(tester);
      expect(find.byType(UnifiedRoomPage), findsOneWidget);
      expect(find.text('6'), findsOneWidget, reason: 'mic seats are part of the toggled panel');
      expect(_headerButton(tester, 'Settings'), findsOneWidget);
      // FIX 22 item 15: the sidebar ALSO has a Settings entry —
      // header Settings + sidebar Settings = 2 'Settings' texts.
      expect(find.text('Settings'), findsNWidgets(2));
      expect(find.text('More'), findsNothing);
      // FIX 22 item 15: the sidebar Music entry is the only
      // 'Music' text while the sheet is closed.
      expect(find.text('Music'), findsOneWidget);

      // OFF: whole panel unmounts, More returns.
      await tester.tap(_headerButton(tester, 'Voice'));
      await _settle(tester);
      expect(find.byType(UnifiedRoomPage), findsNothing);
      expect(find.text('6'), findsNothing);
      expect(find.text('More'), findsOneWidget);
      expect(find.text('Settings'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Connecting pill sits in the status strip, above the seats', (tester) async {
      await tester.pumpWidget(MaterialApp(home: TeamChatPage(team: _team(), uid: 'test-uid')));
      await _settle(tester);
      await tester.tap(_headerButton(tester, 'Voice'));
      await _settle(tester);

      final panel = find.byType(UnifiedRoomPage);
      expect(panel, findsOneWidget);
      // Pill text — FIX 12 G6b (merged): FOUR honest states now
      // (Voice On / Voice Failed / Connecting… / Not connected).
      // In this test no join is attempted, so the idle pill reads
      // 'Not connected'; accept any of the four — the position
      // assertions below are what this test pins.
      Finder? pill;
      for (final label in ['Connecting…', 'Voice On', 'Voice Failed', 'Not connected']) {
        final f = find.text(label);
        if (f.evaluate().isNotEmpty) { pill = f; break; }
      }
      expect(pill, isNotNull, reason: 'no pill label found in the panel');
      expect(pill!, findsOneWidget);
      // The green mic button + the state label, same card.
      // FIX 22 item 14a: the label under the mic is the STATE
      // (ON/OFF), not the old Mute/Unmute action — the mic is
      // located by its 24px mic icon (the Live pill's mic icon
      // is 12px, so this matches exactly one widget).
      final micIcon = find.descendant(
        of: panel,
        matching: find.byWidgetPredicate((w) =>
            w is Icon &&
            (w.icon == Icons.mic || w.icon == Icons.mic_off) &&
            w.size == 24),
      );
      expect(micIcon, findsOneWidget);
      // FIX 22 item 14a: the mic shows its STATE (ON/OFF), not
      // the backwards Mute/Unmute action labels. Here the host
      // is not on voice, so the state is OFF.
      expect(find.descendant(of: panel, matching: find.text('OFF')),
          findsOneWidget);
      expect(find.descendant(of: panel, matching: find.text('Unmute')),
          findsNothing);
      expect(find.descendant(of: panel, matching: find.text('Mute')),
          findsNothing);
      // FIX 22 item 14b: LIVE shows ONLY when the room is
      // actually live — no join is attempted in this test, so
      // there is no Live badge at all (never a LIVE on a dead
      // room). The Connected box carries the state instead.
      final live = find.descendant(of: panel, matching: find.text('Live'));
      expect(live, findsNothing);
      expect(
          find.descendant(of: panel, matching: find.text('Disconnected')),
          findsOneWidget);

      final pillC = tester.getCenter(pill);
      final micC = tester.getCenter(micIcon);
      // FIX 23 item 2: the compact card is TWO rows — the pill
      // sits in Row 2 (the status strip), BELOW the mic button
      // in Row 1 (was same-row before fix23). The gap is one
      // row + spacing (~40-80px), never a whole card away.
      expect(pillC.dy, greaterThan(micC.dy));
      expect(pillC.dy - micC.dy, lessThan(80));
      // Row 2 starts at the left: the pill sits horizontally
      // before the mic button.
      expect(pillC.dx, lessThan(micC.dx));
      // In the host card, NOT below the mics: the pill is above the
      // seat numbers.
      final seat1 = find.descendant(of: panel, matching: find.text('1'));
      expect(seat1, findsOneWidget);
      expect(pillC.dy, lessThan(tester.getCenter(seat1).dy));
      expect(tester.takeException(), isNull);
    });

    testWidgets('Settings opens the sheet; Close voice hides the panel', (tester) async {
      await tester.pumpWidget(MaterialApp(home: TeamChatPage(team: _team(), uid: 'test-uid')));
      await _settle(tester);
      await tester.tap(_headerButton(tester, 'Voice'));
      await _settle(tester);
      expect(find.byType(UnifiedRoomPage), findsOneWidget);

      await tester.tap(_headerButton(tester, 'Settings'));
      await _settle(tester);
      expect(find.text('Voice Settings'), findsOneWidget);
      // FIX 22 item 15: the sidebar also has a Music entry, so
      // the sheet's Music row is scoped to the bottom sheet.
      expect(
          find.descendant(
              of: find.byType(BottomSheet), matching: find.text('Music')),
          findsOneWidget);
      expect(find.text('Room Settings'), findsOneWidget);
      expect(find.text('Close voice'), findsOneWidget);

      await tester.tap(find.text('Close voice'));
      await _settle(tester);
      expect(find.text('Voice Settings'), findsNothing);
      expect(find.byType(UnifiedRoomPage), findsNothing, reason: 'Close voice hides the whole panel');
      expect(find.text('More'), findsOneWidget, reason: 'More returns once the panel is closed');
      expect(tester.takeException(), isNull);
    });
  });
}

/// A header circle button's label, scoped to the header so the
/// panel's own texts can never be mistaken for it.
Finder _headerButton(WidgetTester tester, String label) =>
    find.descendant(of: find.byType(ArenaChatHeader), matching: find.text(label));

/// Pump past the fixture futures (getList/getRow/streamChat) and
/// the embedded panel's post-frame auto-join — plus the join's
/// delayed re-asserts (LiveKit 700ms speaker re-assert, mesh 1s),
/// so no service timer is still pending at test end (FIX 22
/// item 7 fires the speaker preference at join now).
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 500));
  }
}

Map<String, dynamic> _team() => {
      'id': 'team-1',
      'name': 'TEST CH',
      'is_clan': true,
      'captain_uid': 'test-uid',
      'invite_code': 'ABC123',
      // No voice flag at all: voice by default (no approval).
    };

Map<String, List<Map<String, dynamic>>> _fixtures({required Map<String, dynamic> team}) => {
      'teams': [team],
      'team_members': [
        {'team_id': team['id'], 'firebase_uid': 'test-uid', 'game_id': 'Tester'}
      ],
      'team_invitations': [],
      'profiles': [
        {'firebase_uid': 'test-uid', 'display_name': 'Tester', 'level': 1}
      ],
      // The test user IS the designated admin, so the room page
      // treats them as room admin (mic-request gate skipped).
      'admin_config': [
        {'id': 1, 'admin_firebase_uid': 'test-uid'}
      ],
      'communities': [
        {'id': team['id'], 'name': team['name'], 'created_by_uid': 'test-uid', 'voice_enabled': team['voice_enabled'] ?? true}
      ],
      'community_voice_requests': [],
      'chat_messages': [],
    };

// ---- Fake Firebase (exact pattern from v2017_voice_toggle_test) ----

class _FakeAppPlatform extends FirebaseAppPlatform {
  _FakeAppPlatform(super.name, super.options);
}

class _FakeCorePlatform extends FirebasePlatform {
  FirebaseAppPlatform? _app;

  @override
  Future<FirebaseAppPlatform> initializeApp({String? name, FirebaseOptions? options}) async {
    _app = _FakeAppPlatform(
      name ?? defaultFirebaseAppName,
      options ?? const FirebaseOptions(apiKey: 'test', appId: '1:1:android:1', messagingSenderId: '1', projectId: 'test'),
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
  FirebaseAuthPlatform delegateFor({required FirebaseApp app}) => _FakeAuthPlatform(appInstance: app);

  @override
  FirebaseAuthPlatform setInitialValues({PigeonUserDetails? currentUser, String? languageCode}) {
    _user = currentUser == null ? null : _FakeUser(this, _FakeMultiFactor(this), currentUser);
    return this;
  }

  @override
  UserPlatform? get currentUser => _user;

  @override
  set currentUser(UserPlatform? user) => _user = user;

  @override
  Future<UserCredentialPlatform> signInWithEmailAndPassword(String email, String password) async {
    final details = PigeonUserDetails(
      userInfo: PigeonUserInfo(uid: 'test-uid', email: email, isAnonymous: false, isEmailVerified: true),
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
