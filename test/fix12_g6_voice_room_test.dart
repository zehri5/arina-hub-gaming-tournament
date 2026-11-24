// FIX 12 G6 — FULL VOICE ROOM IN COMMUNITY (user order 2026-11-23,
// MD §6): the community detail mounts the SAME embedded
// UnifiedRoomPage the old clan room had — host panel + 6 mic seats
// + mic-request flow + music player/library + RJ Studio + all
// voice settings + live hosting controls + listeners — with room
// id community_<id>. The old single-voice LiveKit connect
// (_lkVoice + bottom sheet) is gone; the room page owns the whole
// voice session. Fix-14 gating stays intact: lock banner +
// request -> approval on communities.voice_enabled.
//
// FIX 12 G6b (2026-11-23 01:56, LIVE ISSUE): the "Connecting…"
// pill hung for nearly an hour after the LiveKit project switch
// (server probed UP — the hang is app-side). Fix: hard timeouts
// on every join step, fresh active-project re-read at join time,
// surfaced token failures, an error banner + Retry, a four-state
// pill, and a connection-aware host presence line.
//
// Source pins (what the code says) + widget tests (what the user
// sees) + service unit tests with a fake SDK room (mocked connect
// success / failure / timeout). Widget tests reuse the
// fake-Firebase pattern from device_ban_gate_test.dart /
// v2017_voice_toggle_test.dart and the SupaDb.testFixtures pattern.
//
// HONEST LIMIT: a widget test cannot prove the mic is really
// connected (no mic, no network in tests) — the auto-join path is
// pinned by source, and the panel-mount test proves the panel
// appears with the right room id, 6 seats and the music/RJ/
// settings entry points (the join path stops at the permission
// step, handled gracefully, no crash). A real on-device
// connection can only be proven on Sameer's phone with the new
// build — but the code now makes silent hangs impossible: every
// failure path lands on the honest error state + Retry.
import 'dart:async';
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
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:protournament_user/screens/communities_screens.dart';
import 'package:protournament_user/screens/room_screen.dart';
import 'package:protournament_user/services/livekit_voice_service.dart';
import 'package:protournament_user/services/supabase_db.dart';
import 'package:protournament_user/widgets/voice_settings_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

String _read(String rel) => File('test/../$rel').readAsStringSync();

/// Source with full-line comments stripped, so a mention inside a
/// comment (e.g. "the old _lkVoice is DELETED") never counts as code.
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Fake Firebase FIRST (top-level setUpAll, before ANY test —
  // device_ban_gate_test pattern): Firebase._delegate is cached
  // lazily on first access, and the service tests touch
  // FirebaseAuth.instance (LiveKitVoiceService._uid) — if the
  // fakes were installed only in the widget group's setUpAll,
  // the REAL MethodChannel delegate would already be cached by
  // then and Firebase.initializeApp() would hit the native
  // pigeon channel (setUpAll failure, 2026-11-23 re-run).
  // Installing here makes the first delegate access resolve to
  // the fakes. No user is signed in here — the widget group's
  // setUp signs in per test, so the service tests still run
  // signed-out (currentUser null, _uid '') as before.
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
  });

  group('fix12 G6 — source: community scope on the room page', () {
    test('UnifiedRoomPage declares the community scope + params', () {
      final room = _read('lib/screens/room_screen.dart');
      expect(room, contains("final String scope; // 'tournament' | 'squad' | 'team' | 'community'"));
      expect(room, contains("final String communityId; // '' unless scope == 'community'"));
      expect(room, contains("final String communityName; // '' unless scope == 'community'"));
      expect(room, contains("final String organizerUid; // community creator, '' unless scope == 'community'"));
      expect(room, contains('this.communityId = \'\','));
      expect(room, contains('this.organizerUid = \'\','));
      expect(room, contains('bool get _isCommunity => widget.scope == \'community\';'));
    });

    test('room id is community_<id>; title is the community room', () {
      final room = _read('lib/screens/room_screen.dart');
      expect(room,
          contains('communityRoomId(widget.communityId)'));
      expect(room,
          contains("String get _voiceRoomId => _isTeam ? squadRoomId(widget.teamId) : _isCommunity ? communityRoomId(widget.communityId)"));
      expect(room,
          contains("'Community Room — \${widget.communityName}'"));
      // Chat rows live on the community filter, never tournament_id.
      expect(room,
          contains("_isCommunity ? widget.communityId : _isSquad ? widget.squadId : widget.tournamentId"));
      expect(room, contains("_isCommunity ? 'community_id' : 'tournament_id'"));
    });

    test('community rooms get 6 mic seats, like the team room', () {
      final room = _read('lib/screens/room_screen.dart');
      expect(room,
          contains('int get _communityMicCount => widget.micCount > 0 ? widget.micCount : 6;'));
      expect(room,
          contains('_isCommunity ? _communityMicCount : _isSquad ? _squadCapacity'));
      expect(room,
          contains('final total = _isTeam ? _teamMicCount : _isCommunity ? _communityMicCount : 9;'));
    });

    test('community rooms skip tournament-only gates (join, room control, shared bg)', () {
      final room = _read('lib/screens/room_screen.dart');
      expect(room, contains('if (_isSquad || _isTeam || _isCommunity) {'));
      expect(room, contains('if (_isTeam || _isCommunity) return;'));
      expect(room,
          contains("bool get _broadcastJoinBlocked => !_isTeam && !_isCommunity && !_joined && !_isAdminForBroadcast;"));
      expect(room,
          contains("_tournamentFuture = _isTeam ? SupaDb.getRow('teams', 'id', widget.teamId) : _isCommunity ? SupaDb.getRow('communities', 'id', widget.communityId)"));
      expect(room,
          contains("SupaDb.strOf(t['created_by_uid'], widget.organizerUid)"));
      // Host falls back to the organizer (creator), mirroring the
      // team captain fallback. FIX 23 item 17 reformatted this
      // into a multi-line ternary (the host-slot rule lives in
      // the same expression now) — pin the fragment, not the
      // single-line spelling.
      expect(room,
          contains('(_creatorUid.isNotEmpty ? _creatorUid : widget.organizerUid)'));
      // Members come from community_members for presence welcomes.
      expect(room,
          contains("SupaDb.getList('community_members', eqCol: 'community_id', eqVal: widget.communityId"));
    });

    test('organizer UID reaches the LiveKit service (FIX 15 carry-over)', () {
      final room = _read('lib/screens/room_screen.dart');
      // The old detail-page voice service set organizerUid from
      // created_by_uid so organizer-mute packets were honored;
      // the room page owns the service now, so it must wire the
      // same UID — at creation and refreshed from the row.
      expect(room,
          contains("if (_isCommunity) _lkRoom.organizerUid = widget.organizerUid;"));
      expect(room,
          contains("if (_isCommunity && c.isNotEmpty) _lkRoom.organizerUid = c;"));
    });

    test('community rooms never write tournament-keyed rows (mutes/pins/reports)', () {
      final room = _read('lib/screens/room_screen.dart');
      // room_mutes is tournament-keyed: a '' tournament_id row
      // would block every team/community join (their mute check
      // queries tournament_id=''), so community rooms skip the
      // persistent record exactly like team rooms.
      expect(room, contains('if (!_isTeam && !_isCommunity) {'));
      expect(room,
          contains('tournamentId: _isTeam || _isCommunity ? null : widget.tournamentId,'));
      expect(room,
          contains("if (mounted) toast(context, 'Pin \${_isCommunity ? 'community' : 'team'} rooms mein abhi available nahi hai.');"));
    });

    test('embedded panel still carries music / RJ / settings + requests', () {
      final room = _read('lib/screens/room_screen.dart');
      // Embedded renders the host strip (compact controls) +
      // request banners + seat grid — the SAME panel the clan had.
      expect(room,
          contains('if (widget.embedded) return _buildEmbeddedVoice(uid, peers, kbOpen);'));
      expect(room, contains('_buildHostStrip(uid, peers, compactControls: true)'));
      expect(room, contains('..._buildRequestBanners(),'));
      expect(room, contains('_buildSeatGrid(uid, peers, kbOpen)'));
      // FIX 16 (merged): the compact host-card icon buttons are
      // GONE — Music / RJ / Settings moved to the header Settings
      // sheet, bound through the voice controller. Same panels,
      // same handlers, new entry point (the full-room nav rail
      // carries the same three buttons too).
      // FIX 22 item 21: Music no longer opens a standalone player
      // (_showMusicPlayer is retired) — it opens the unified RJ
      // console focused on the player section, in BOTH the
      // controller binding and the full-room rail.
      expect(room, contains('void _bindVoiceController() {'));
      expect(room, contains('onMusic: () => unawaited('));
      expect(room,
          contains("_showRjVoiceConsole(initialSection: 'player')"));
      expect(room, contains('onRjConsole: _showRjVoiceConsole,'));
      expect(room, contains('onRoomSettings: _showRoomSettings,'));
      expect(room, contains("_railBtn(Icons.music_note, 'Music',"));
      expect(room, contains(
          "() => unawaited(_showRjVoiceConsole(initialSection: 'player'))"));
      expect(room, contains("_railBtn(Icons.graphic_eq, 'RJ Studio', _showRjVoiceConsole)"));
      expect(room, contains("_railBtn(Icons.settings, 'Settings', _showRoomSettings)"));
    });
  });

  group('fix12 G6 — source: chat branches for the community room', () {
    test('streamChat / getChat / sendChat have a community branch', () {
      final db = _read('lib/services/supabase_db.dart');
      expect(db, contains("if (scope == 'community') {"));
      expect(db,
          contains("eqCol: 'scope', eqVal: 'community', eqCol2: 'community_id', eqVal2: scopeId"));
      expect(db,
          contains("'tournament_id': scope == 'team' ? '' : scope == 'community' ? null : _chatTournamentId(scope, scopeId),"));
      expect(db, contains("if (scope == 'community') 'community_id': scopeId,"));
    });
  });

  group('fix12 G6 — source: verifier-4 parity fixes (F1/F2)', () {
    test('community organizer can broadcast music (F1)', () {
      final room = _read('lib/screens/room_screen.dart');
      // The gate includes the community-organizer branch.
      expect(
          room,
          contains(
              'bool get _canBroadcastMusic => _isAdminForBroadcast || _isTeamCaptainForBroadcast || _isCommunityOrganizerForBroadcast || _musicApproved;'));
      // The getter exists: community-only, organizer identity via
      // loaded _creatorUid first, widget.organizerUid fallback.
      final gate = _method(room, 'bool get _isCommunityOrganizerForBroadcast {');
      expect(gate, contains('if (!_isCommunity) return false;'));
      expect(gate, contains('final organizer = _creatorUid.isNotEmpty ? _creatorUid : widget.organizerUid;'));
      expect(gate, contains('return organizer.isNotEmpty && myUid == organizer;'));
      // The music panel treats the community organizer as host
      // (effects knobs), like the team captain.
      expect(room, contains('isHost: _isAdminForBroadcast || _isTeamCaptainForBroadcast || _isCommunityOrganizerForBroadcast,'));
    });

    test('status sheet lists community members (F2)', () {
      final sheet = _read('lib/screens/status_sheet.dart');
      // The sheet takes a community id and streams its members.
      expect(sheet, contains('final String communityId;'));
      expect(sheet, contains("String communityId = '',"));
      expect(sheet, contains("SupaDb.streamList('community_members', eqCol: 'community_id', eqVal: widget.communityId)"));
      // Voice peers come from the community room id (mic icons).
      expect(sheet, contains('communityRoomId(widget.communityId)'));
      // community_members rows carry no username — names fall back
      // to the profile, never a fake 'Player' for every row.
      expect(sheet, contains("strVal(prof?['display_name'], strVal(prof?['username'], 'Player'))"));
      // The empty state is honest and scope-aware.
      expect(sheet, contains("widget.communityId.isNotEmpty ? 'No members yet.' : 'No players joined yet.'"));
      // The room passes its community id when opening the sheet.
      final room = _read('lib/screens/room_screen.dart');
      expect(room, contains("communityId: _isCommunity ? widget.communityId : '',"));
    });
  });

  group('fix12 G6 — source: detail page mounts the room', () {
    test('panel embeds the community room page (same scope, 6 seats)', () {
      final comm = _read('lib/screens/communities_screens.dart');
      final panel = _method(comm, 'Widget _buildVoicePanel() {');
      expect(panel, contains('UnifiedRoomPage('));
      expect(panel, contains("scope: 'community',"));
      expect(panel, contains('communityId: _id,'));
      expect(panel,
          contains("communityName: SupaDb.strOf(_community['name'], 'Community'),"));
      expect(panel,
          contains("organizerUid: SupaDb.strOf(_community['created_by_uid']),"));
      expect(panel, contains('micCount: 6,'));
      expect(panel, contains('embedded: true,'));
      // FIX 23 item 16a SUPERSEDES onCloseVoice: the host card is
      // sticky — no close affordance, no hide path. (The comment
      // in the mount mentions the name, so pin on code only.)
      expect(_codeOnly(panel), isNot(contains('onCloseVoice')));
      // Panel mounts for members ALWAYS (no _voicePanelOpen gate
      // any more) — under the lock banner.
      expect(comm, contains('if (_isMember) _buildVoicePanel(),'));
      expect(comm, isNot(contains('if (_voicePanelOpen) _buildVoicePanel(),')));
    });

    test('old single-voice connect is gone; the panel toggle is gone too (FIX 23 item 16a)', () {
      final comm = _read('lib/screens/communities_screens.dart');
      final code = _codeOnly(comm);
      expect(code, isNot(contains('_lkVoice')));
      expect(code, isNot(contains('_toggleCommunityVoice')));
      expect(code, isNot(contains('_showVoiceSheet')));
      expect(code, isNot(contains('LiveKitVoiceService')));
      expect(code, isNot(contains('LiveKitConfig')));
      // FIX 23 items 1+16a SUPERSEDE the Voice toggle: no top bar,
      // no Voice button, no panel toggle — the panel is always
      // mounted for members.
      expect(code, isNot(contains('_toggleVoicePanel')));
      expect(code, isNot(contains('_voicePanelOpen')));
      // The lock path is intact: tapping the lock banner still
      // opens the request sheet (fix-14 flow, pinned in detail
      // by the test below).
      expect(code, contains('void _onLockedVoiceTap() {'));
      expect(code, contains('void _showVoiceRequestSheet() {'));
      expect(code, contains('Future<bool> _requestVoiceAccess() async {'));
    });

    test('fix-14 gating stays intact on the detail page', () {
      final comm = _read('lib/screens/communities_screens.dart');
      expect(comm, contains('if (!_voiceEnabled) _voiceLockBanner(),'));
      expect(comm, contains('Widget _voiceLockBanner() {'));
      expect(comm, contains('void _onLockedVoiceTap() {'));
      expect(comm, contains('void _showVoiceRequestSheet() {'));
      expect(comm, contains('Future<bool> _requestVoiceAccess() async {'));
      expect(comm, contains("'Voice Locked hai'"));
      expect(comm, contains("'REQUEST VOICE ACCESS'"));
      expect(comm, contains("'SEND VOICE REQUEST'"));
      // The lock banner is shown while locked; the panel is a
      // separate mount (never both from the same flag).
      expect(comm, contains("bool get _voiceEnabled => CommunityGroups.isVoiceEnabled(_community);"));
    });
  });

  // ------------------------------------------------------------------
  // FIX 12 G6b (2026-11-23, 01:56 live issue): the "Connecting…"
  // pill hung for nearly an hour after the LiveKit project switch.
  // Root causes: the SDK's room.connect() has NO timeout, and the
  // room only TOASTED join failures — so a failed join looked
  // exactly like a join in flight, with no reason and no retry.
  // Fix: hard timeouts on every join step, fresh config at join
  // time, surfaced token failures, an error banner + Retry, a
  // four-state pill, and a connection-aware host presence line.
  // ------------------------------------------------------------------
  group('fix12 G6b — source: connect timeout + fresh project', () {
    test('service connect has a hard timeout + connecting state', () {
      final svc = _read('lib/services/livekit_voice_service.dart');
      expect(svc, contains('bool connecting = false;'));
      expect(svc,
          contains('static Duration connectTimeout = const Duration(seconds: 30);'));
      expect(svc, contains('.timeout(connectTimeout, onTimeout: () {'));
      expect(svc, contains('TimeoutException('));
      // Timeout message names the fix (Retry), not just the error.
      expect(svc, contains('phir Retry dabayen.'));
      // A second connect while one is in flight is a no-op.
      expect(svc, contains('if (connecting) return;'));
      // Test seam for mocked connect outcomes.
      expect(svc, contains('lk.Room Function()? roomFactory;'));
    });

    test('join re-reads the active project fresh + bounds every step', () {
      final room = _read('lib/screens/room_screen.dart');
      final join = _method(room, 'Future<void> _joinVoiceLiveKit() async {');
      // (a) Fresh config at join time — never a cached _lkConfig.
      expect(join, contains('cfg = await LiveKitConfig.load()'));
      expect(join, isNot(contains('_lkConfig.activeProject')));
      // (b) Config load bounded (Supabase REST has no timeout).
      expect(join, contains('.timeout(const Duration(seconds: 15))'));
      // (c) Token failures surfaced, not swallowed.
      expect(join, contains("'Voice token nahi mila: \$e'"));
      // (d) Every failure lands on _lkConnectError + the banner.
      expect(join, contains('_lkConnectError ='));
      expect(join, contains('_lkConnecting = true;'));
      expect(join, contains('_lkConnecting = false'));
      // Reconnect has the same config-load bound.
      final reconnect =
          _method(room, 'Future<void> _reconnectLiveKit() async {');
      expect(reconnect, contains('.timeout(const Duration(seconds: 15))'));
    });

    test('join awaits the admin load before the mic gate (no race)',
        () {
      final room = _read('lib/screens/room_screen.dart');
      // The load future is stored at initState, not fire-and-forgot.
      expect(room, contains('Future<void>? _adminLoadFuture;'));
      expect(room, contains('_adminLoadFuture = _loadRoomAdmin();'));
      // The join awaits it (bounded) BEFORE the gates that read
      // admin state — otherwise the post-frame auto-join could read
      // not-yet-loaded state, send a mic request and return without
      // ever joining, for a user who IS the admin (found by the
      // mesh-failure widget test: no join, no error, no banner).
      final join = _method(room, 'Future<void> _joinVoiceOpen() async {');
      expect(join, contains('final adminLoad = _adminLoadFuture;'));
      expect(join,
          contains('await adminLoad.timeout(const Duration(seconds: 5))'));
      expect(join.indexOf('adminLoad.timeout'),
          lessThan(join.indexOf('if (_adminMicRejected)')));
      expect(join.indexOf('adminLoad.timeout'),
          lessThan(join.indexOf('final isAdminNow')));
    });

    test('error banner + Retry exist and render in both room modes', () {
      final room = _read('lib/screens/room_screen.dart');
      expect(room, contains('Widget _buildVoiceConnectErrorBanner() {'));
      expect(room, contains("'Voice connect nahi ho saka'"));
      expect(room, contains("label: Text(_lkConnecting ? 'Connect ho raha hai…' : 'Retry'"));
      expect(room, contains('onPressed: _lkConnecting ? null : _joinVoiceOpen,'));
      // Rendered in the embedded panel AND the full room page
      // (exactly two call sites, plus the definition above).
      expect('_buildVoiceConnectErrorBanner(),'.allMatches(room).length, 2);
      expect(room, contains('String? get _voiceConnectError {'));
      // Mesh failures surface through the SAME banner: the getter
      // reads the mesh engine's error too, not just LiveKit's.
      expect(room,
          contains("if (_room.error != null && _room.error!.isNotEmpty) return _room.error;"));
    });

    test('pill has four honest states; host presence is connection-aware', () {
      final room = _read('lib/screens/room_screen.dart');
      // FIX 16 (merged): _buildHostCardControls is DELETED — the
      // pill lives in _buildConnectingPill now (the G6b 4-state
      // logic was TRANSPLANTED there at merge, not resurrected).
      final controls = _method(room, 'Widget _buildConnectingPill() {');
      expect(controls, contains("'Voice On'"));
      expect(controls, contains("'Voice Failed'"));
      expect(controls, contains("'Connecting…'"));
      expect(controls, contains("'Not connected'"));
      // 'Connecting…' only while a join is actually in flight.
      expect(controls, contains('_lkConnecting || _lkRoom.connecting || _lkReconnecting'));
      // Host presence line (requirement d).
      expect(room, contains('String _hostPresenceLabel() {'));
      final host = _method(room, 'Widget _buildHostLiveColumn(');
      expect(host, contains('_hostPresenceLabel()'));
    });
  });

  // ------------------------------------------------------------------
  // Widget tests: fake Firebase + SupaDb.testFixtures.
  // ------------------------------------------------------------------
  group('fix12 G6 — widget: community voice room', () {
    // Fake Firebase is installed by the TOP-LEVEL setUpAll (see
    // main() above) — never here: the fakes must be in place
    // before ANY Firebase touch, or the delegate caches as real.
    setUp(() async {
      await FirebaseAuth.instance.signInWithEmailAndPassword(
          email: 't@t.com', password: 'password');
      SupaDb.testFixtures = _fixtures(community: _unlockedCommunity());
    });

    tearDown(() async {
      SupaDb.testFixtures = null;
      // G6b permission + WebRTC mocks (only the failure-path tests
      // set them).
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('flutter.baseflow.com/permissions/methods'),
              null);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('FlutterWebRTC.Method'), null);
      await FirebaseAuth.instance.signOut();
    });

    testWidgets('locked community (creator): banner + request, panel STILL mounted (FIX 23 item 16a)',
        (tester) async {
      // Tall viewport: the always-mounted panel + banner + chat
      // overflow the default 600px height (G6 pattern).
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SupaDb.testFixtures = _fixtures(community: _lockedCommunity());
      await tester.pumpWidget(MaterialApp(
        home: CommunityDetailPage(
          uid: 'test-uid',
          communityId: 'comm-1',
          community: _lockedCommunity(),
        ),
      ));
      await _settle(tester);

      // Lock banner under the header; creator sees the button.
      expect(find.text('Voice locked hai — admin approval ke baad milegi.'),
          findsOneWidget);
      expect(find.text('REQUEST VOICE ACCESS'), findsOneWidget);
      // FIX 23 item 16a: the host card is STICKY — the panel is
      // mounted even while voice is locked (no top bar, no
      // 'Locked' header label any more).
      expect(find.byType(UnifiedRoomPage), findsOneWidget);
      expect(find.text('Locked'), findsNothing);

      // Tap the banner (not the button) -> the request sheet,
      // panel stays mounted.
      await tester.tap(
          find.text('Voice locked hai — admin approval ke baad milegi.'));
      await _settle(tester);
      expect(find.text('Voice Locked hai'), findsOneWidget);
      expect(find.byType(UnifiedRoomPage), findsOneWidget);

      // Send the request -> sheet pops, banner shows PENDING.
      await tester.tap(find.text('SEND VOICE REQUEST'));
      await _settle(tester);
      expect(find.text('Voice Locked hai'), findsNothing);
      expect(find.text('PENDING'), findsOneWidget);
      expect(
          find.text(
              'Voice request pending hai — admin approval ka intezar karen.'),
          findsOneWidget);
      expect(find.byType(UnifiedRoomPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('unlocked community: panel mounted immediately, 6 seats, music/RJ/settings (FIX 23 items 1+16a)',
        (tester) async {
      // FIX 20 (fix 4): the members line under the pill makes the
      // host strip ~13px taller, so the chat empty state overflows
      // the default 600px height by 6px — same tall viewport as
      // the other panel-open tests in this file.
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(
        home: CommunityDetailPage(
          uid: 'test-uid',
          communityId: 'comm-1',
          community: _unlockedCommunity(),
        ),
      ));
      await _settle(tester);
      // FIX 23 items 1+16a: no top bar, no Voice button to tap —
      // the panel is mounted the moment the page opens.
      expect(find.byType(UnifiedRoomPage), findsOneWidget);
      expect(find.text('Voice'), findsNothing);
      expect(find.text('Voice locked hai — admin approval ke baad milegi.'),
          findsNothing);

      // The mounted room IS the community room: scope + id pin
      // the room id community_comm-1 (see _voiceRoomId source pin).
      final room =
          tester.widget<UnifiedRoomPage>(find.byType(UnifiedRoomPage));
      expect(room.scope, 'community');
      expect(room.communityId, 'comm-1');
      expect(room.communityName, 'TEST COMMUNITY');
      expect(room.organizerUid, 'test-uid');
      expect(room.micCount, 6);
      expect(room.embedded, isTrue);

      // 6 mic seats, no 7th — the same full system as the clan room.
      expect(find.text('6'), findsOneWidget);
      expect(find.text('7'), findsNothing);

      // FIX 16 (merged): the host-card Music / RJ / Settings icon
      // buttons are GONE from the embedded panel — the features
      // live in the full-room nav rail + the voice-controller
      // header sheet (pinned by the source tests above).
      // FIX 22 item 15: the embedded panel now carries the round
      // sidebar (Followers / Music / RJ Panel / Settings / Leave
      // Room) INSIDE the room, so the three icons ARE present —
      // as sidebar round buttons, not host-card buttons.
      final panelFinder = find.byType(UnifiedRoomPage);
      expect(
          find.descendant(
              of: panelFinder, matching: find.byIcon(Icons.music_note)),
          findsOneWidget);
      expect(
          find.descendant(
              of: panelFinder, matching: find.byIcon(Icons.graphic_eq)),
          findsOneWidget);
      expect(
          find.descendant(
              of: panelFinder, matching: find.byIcon(Icons.settings)),
          findsOneWidget);
      // FIX 22 item 18b: LIVE shows ONLY when the host is actually
      // on voice. In this test the host never connects, so the
      // Live pill is honestly ABSENT — and the item-18c connection
      // box shows 'Disconnected' instead (same _voiceConnected
      // truth as the Connecting pill).
      expect(
          find.descendant(of: panelFinder, matching: find.text('Live')),
          findsNothing);
      expect(
          find.descendant(
              of: panelFinder, matching: find.text('Disconnected')),
          findsOneWidget);

      // FIX 23 item 16a: the host card is STICKY — there is no
      // header label to flip and no way to close the panel. The
      // panel stays mounted and no close affordance exists.
      expect(find.text('Close voice'), findsNothing);
      expect(find.text('Voice On'), findsNothing);

      // The room is EMBEDDED — no new screen was pushed: the
      // chat is still on screen below the panel (FIX 22: no tabs
      // anymore — the chat renders directly).
      expect(find.byType(CommunityDetailPage), findsOneWidget);
      expect(find.text('Abhi koi chat nahi'), findsOneWidget);
      expect(tester.takeException(), isNull);

      // STICKY: after more pumps the panel is STILL mounted —
      // there is no OFF state any more.
      await _settle(tester);
      expect(find.byType(UnifiedRoomPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('non-member: no panel, Follow-to-join banner (FIX 23 items 1+16a)',
        (tester) async {
      SupaDb.testFixtures =
          _fixtures(community: _unlockedCommunity(), member: false);
      await tester.pumpWidget(MaterialApp(
        home: CommunityDetailPage(
          uid: 'test-uid',
          communityId: 'comm-1',
          community: _unlockedCommunity(),
        ),
      ));
      await _settle(tester);
      // FIX 23 items 1+16a: no top bar, no Voice button to tap —
      // non-members get no voice panel at all, and the chat shows
      // the Follow-to-join banner (Follow itself lives on the
      // community card, item 19).
      expect(find.text('Voice'), findsNothing);
      expect(find.byType(UnifiedRoomPage), findsNothing);
      expect(find.text('Chat karne ke liye pehle Follow karen.'),
          findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    // FIX 12 G6b — failure paths land on the honest error state +
    // Retry, never stuck on "Connecting…". Permissions are mocked
    // granted here (tearDown clears the mock) so the join runs
    // past the permission step into the real engine paths.
    testWidgets('mesh join failure -> error banner + Retry + Voice Failed',
        (tester) async {
      _mockPermissionsGranted();
      _mockWebRtcThrows();
      // Tall viewport: panel + error banner + seat grid overflow
      // the default 600px height (59px, seen 2026-11-23).
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(
        home: CommunityDetailPage(
          uid: 'test-uid',
          communityId: 'comm-1',
          community: _unlockedCommunity(),
        ),
      ));
      await _settle(tester);
      // FIX 23 item 16a: the panel is already mounted (no Voice
      // button to tap) — join via an explicit seat tap (admin
      // -> slot dialog -> _joinVoiceOpen). The mesh join fails
      // in tests (no mic plugin) — the failure must be VISIBLE
      // with a way back, not a stuck pill.
      expect(find.byType(UnifiedRoomPage), findsOneWidget);
      // Seat 1 by its 17px w900 number: FIX 23 item 12a puts the
      // real member count ('1' here — one fixture member) in the
      // sidebar Followers sub-line, so a bare find.text('1')
      // matches twice inside the room now.
      final seat1 = find.descendant(
          of: find.byType(UnifiedRoomPage),
          matching: find.byWidgetPredicate((w) =>
              w is Text && w.data == '1' && w.style?.fontSize == 17));
      await tester.ensureVisible(seat1);
      await tester.tap(seat1);
      await _settle(tester);
      await tester.tap(find.text('Mic 1 (suggested)'));
      await _settle(tester);
      expect(find.text('Voice connect nahi ho saka'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      // Pill: failed, not connecting. Host line: this phone is
      // not on voice, so presence is unknown — the compact
      // card's row-2 status strip shows 'Disconnected' (FIX 23
      // item 2; the full-page 'Not connected' presence line
      // lives only in _buildHostLiveColumn now), never a
      // "Connecting…" hang and never a false "Offline".
      expect(find.text('Voice Failed'), findsOneWidget);
      expect(find.text('Disconnected'), findsOneWidget);
      expect(find.text('Connecting…'), findsNothing);
      expect(tester.takeException(), isNull);

      // Retry re-runs the join and lands on the SAME honest
      // error state — still never stuck on "Connecting…".
      await tester.tap(find.text('Retry'));
      await _settle(tester);
      expect(find.text('Voice connect nahi ho saka'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('Voice Failed'), findsOneWidget);
      expect(find.text('Connecting…'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('LiveKit not-configured -> surfaced error + Retry',
        (tester) async {
      _mockPermissionsGranted();
      // Tall viewport: panel + error banner + seat grid overflow
      // the default 600px height (59px, seen 2026-11-23).
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      // FIX 16 (merged): the embedded panel has NO Settings button
      // any more (host-card controls deleted), and the FULL room
      // has NO Connecting pill (compact-only) — so this test pumps
      // the room EMBEDDED with a voice controller and drives the
      // room settings through it (the same path the header sheet
      // uses on the team side). The engine-switch + join +
      // surfaced-failure flow below is unchanged.
      final controller = VoicePanelController();
      await tester.pumpWidget(MaterialApp(
        // Scaffold: the embedded panel's InkWells need a Material
        // ancestor (the detail page provides it in the real app;
        // this direct pump must provide it itself).
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

      // Switch the engine to LiveKit via the controller-bound
      // room settings: Settings -> Voice test (LiveKit) ->
      // LiveKit test engine.
      controller.openRoomSettings();
      await _settle(tester);
      await tester.ensureVisible(find.text('Voice test (LiveKit)'));
      await tester.tap(find.text('Voice test (LiveKit)'));
      await _settle(tester);
      await tester.tap(find.text('Voice engine: LiveKit test'));
      await _settle(tester);

      // Join via a seat tap (admin -> slot dialog): the join now
      // runs the LiveKit path — no app_settings in tests, so the
      // config reads as not-configured and the failure must be
      // SURFACED (not a toast, not a hang). Seat 1 by its 17px
      // w900 number (same disambiguation as the mesh test above).
      final seat1 = find.descendant(
          of: find.byType(UnifiedRoomPage),
          matching: find.byWidgetPredicate((w) =>
              w is Text && w.data == '1' && w.style?.fontSize == 17));
      await tester.ensureVisible(seat1);
      await tester.tap(seat1);
      await _settle(tester);
      await tester.tap(find.text('Mic 1 (suggested)'));
      await _settle(tester);
      expect(find.textContaining('LiveKit server abhi set nahi hai'),
          findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('Voice Failed'), findsOneWidget);
      expect(find.text('Connecting…'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  // Service tests run after the widget group (order no longer
  // load-bearing: the TOP-LEVEL setUpAll owns the fake Firebase
  // platforms now, so the token test exercises the real
  // HTTP-failure path wherever it runs).
  group('fix12 G6b — service: mocked connect success / failure / timeout', () {
    tearDown(() {
      // The timeout test shortens the static — always restore.
      LiveKitVoiceService.connectTimeout = const Duration(seconds: 30);
    });

    test('connect timeout defaults to 30s', () {
      expect(LiveKitVoiceService.connectTimeout,
          const Duration(seconds: 30));
    });

    test('mocked success: fake room connects -> joined, no error', () async {
      final svc = LiveKitVoiceService(roomId: 'community_comm-1', roomLabel: 'Test');
      final fake = _FakeLkRoom();
      svc.roomFactory = () => fake;
      await svc.connect('wss://fake.invalid', 'fake-token');
      expect(fake.connectCalled, isTrue);
      expect(svc.joined, isTrue);
      expect(svc.error, isNull);
      expect(svc.connecting, isFalse);
      expect(svc.connectionState, lk.ConnectionState.connected);
      svc.dispose();
    });

    test('mocked failure: fake room throws -> honest error, not joined', () async {
      final svc = LiveKitVoiceService(roomId: 'community_comm-1', roomLabel: 'Test');
      final fake = _FakeLkRoom(
          connectBehavior: () async => throw Exception('boom'));
      svc.roomFactory = () => fake;
      await svc.connect('wss://fake.invalid', 'fake-token');
      expect(svc.joined, isFalse);
      expect(svc.connecting, isFalse);
      expect(svc.error, isNotNull);
      expect(svc.error, contains('LiveKit connect failed'));
      expect(svc.connectionState, lk.ConnectionState.disconnected);
      // The half-connected room is torn down (no zombie handshake).
      expect(fake.disconnectCalled, isTrue);
      svc.dispose();
    });

    test('mocked timeout: fake room never answers -> timeout error, not stuck', () async {
      LiveKitVoiceService.connectTimeout =
          const Duration(milliseconds: 200);
      final svc = LiveKitVoiceService(roomId: 'community_comm-1', roomLabel: 'Test');
      svc.roomFactory = () => _FakeLkRoom(
          connectBehavior: () => Completer<void>().future);
      final sw = Stopwatch()..start();
      await svc.connect('wss://blackhole.invalid', 'fake-token');
      sw.stop();
      expect(sw.elapsedMilliseconds, lessThan(5000));
      expect(svc.joined, isFalse);
      expect(svc.connecting, isFalse);
      expect(svc.error, isNotNull);
      expect(svc.error, contains('timeout'));
      expect(svc.connectionState, lk.ConnectionState.disconnected);
      svc.dispose();
    });

    test('token fetch failure throws (surfaced, never swallowed)', () async {
      // Connection refused: no server on 127.0.0.1:9 — fails fast.
      await expectLater(
        LiveKitVoiceService.fetchToken(
            'http://127.0.0.1:9/token', 'community_comm-1', 'test-uid'),
        throwsA(isA<Exception>()),
      );
    });
  });
}

/// Mock flutter_webrtc: every channel call throws (no mic plugin in
/// tests). The mesh join MUST fail deterministically through
/// getUserMedia — without this mock the unmocked WebRTC channel
/// call never resolves in the test sandbox (observed 2026-11-23:
/// the join runs past every gate yet no error ever surfaces, so
/// the banner never appears). Cleared by the widget group's
/// tearDown.
void _mockWebRtcThrows() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('FlutterWebRTC.Method'),
    (call) async =>
        throw PlatformException(code: 'NO_MIC', message: 'No mic in tests'),
  );
}

/// Mock permission_handler: every requested permission is granted
/// (status 1 = PermissionStatus.granted; 0 is DENIED — the first
/// version of this mock returned 0 and the join silently stopped
/// at the permission gate, so no failure banner ever appeared).
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

/// Fake LiveKit SDK room for the mocked connect tests: the
/// service's roomFactory seam injects it instead of a real
/// lk.Room, so connect success / failure / timeout can be driven
/// without a server.
class _FakeLkRoom extends lk.Room {
  _FakeLkRoom({this.connectBehavior});

  final Future<void> Function()? connectBehavior;
  bool connectCalled = false;
  bool disconnectCalled = false;

  @override
  lk.ConnectionState get connectionState => lk.ConnectionState.connected;

  @override
  Future<void> connect(String url, String token,
      {lk.ConnectOptions? connectOptions,
      lk.RoomOptions? roomOptions,
      lk.FastConnectOptions? fastConnectOptions}) async {
    connectCalled = true;
    if (connectBehavior != null) await connectBehavior!();
  }

  @override
  Future<void> disconnect() async {
    disconnectCalled = true;
  }
}

/// Pump past the fixture futures (getProfile/getCommunity/
 /// member counts) and the embedded panel's post-frame auto-join.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  for (var i = 0; i < 8; i++) {
    // 4s total: the room shows a mount toast whose 4s snackbar
    // timer must fire inside the test, or the post-test
    // invariant check fails on a pending timer (the snackbar
    // lives on the parent page's ScaffoldMessenger, so it
    // survives the voice panel unmounting).
    await tester.pump(const Duration(milliseconds: 500));
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

Map<String, dynamic> _lockedCommunity() => {
      'id': 'comm-1',
      'name': 'TEST COMMUNITY',
      'description': 'Test community',
      'created_by_uid': 'test-uid',
      'voice_enabled': false,
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
      // The test user IS the designated admin, so the room page
      // treats them as room admin (mic-request gate skipped, RJ
      // button visible).
      'admin_config': [
        {'id': 1, 'admin_firebase_uid': 'test-uid'}
      ],
      'chat_messages': [],
      'presence': [],
    };

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
