// v2017 INLINE VOICE TOGGLE (user order 2026-11-22): the Voice
// button in the clan/squad chat no longer pushes a new screen —
// it toggles an inline voice panel on the same chat screen.
// Tap ON -> panel appears (mic seats + voice connect + mic/music
// controls) and voice connects; tap OFF -> panel hides and voice
// disconnects. The button shows its state (gold while ON).
//
// Source pins (what the code says) + widget tests (what the user
// sees). The widget tests reuse the fake-Firebase pattern from
// device_ban_gate_test.dart and the SupaDb.testFixtures pattern
// from community_tab_restructure_test.dart.
//
// HONEST LIMIT: a widget test cannot prove the mic is really
// connected (no mic, no network in tests) — the auto-join path is
// pinned by source, and the panel-mount test proves the panel
// appears with the right seats and the join path runs (it stops
// at the permission step, handled gracefully, no crash).
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
import 'package:protournament_user/components/arena_chat.dart';
import 'package:protournament_user/screens/pro_features.dart';
import 'package:protournament_user/screens/room_screen.dart';
import 'package:protournament_user/services/squad.dart';
import 'package:protournament_user/services/supabase_db.dart';
import 'package:protournament_user/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

String _read(String rel) =>
    File('test/../$rel').readAsStringSync();

/// Source with full-line comments stripped, so a mention inside a
/// comment (e.g. "was _openVoiceRoom's push") never counts as code.
String _codeOnly(String src) => src
    .split('\n')
    .where((l) => !l.trimLeft().startsWith('//'))
    .join('\n');

/// The body of a top-level-ish method (from its signature to the
/// next method's closing), for scoped assertions.
String _method(String src, String signature) {
  final start = src.indexOf(signature);
  expect(start, isNot(-1), reason: 'method not found: $signature');
  // The method ends at the next line that is exactly '  }' after
  // the signature — both _toggleVoice and _buildVoicePanel are
  // two-space-indented members of a class.
  final end = src.indexOf('\n  }\n', start);
  expect(end, isNot(-1), reason: 'method end not found: $signature');
  return src.substring(start, end);
}

void main() {
  group('v2017 — teamMicCount (all teams 6)', () {
    // FIX 12 G5 (2026-11-23): the Clan type is gone too — every
    // team room has 6 mic seats, and teamMicCount takes no flag.
    test('every team gets 6 seats', () {
      expect(teamMicCount(), 6);
    });
  });

  group('v2017 — source invariants', () {
    test('Voice button toggles the panel — no push, no new screen', () {
      final pro = _read('lib/screens/pro_features.dart');
      final toggle = _method(pro, 'void _toggleVoice() {');
      expect(toggle, contains('_voicePanelOpen = !_voicePanelOpen'));
      expect(toggle, contains('_onLockedVoiceTap()'));
      expect(toggle, isNot(contains('Navigator.push')));
      expect(toggle, isNot(contains('UnifiedRoomPage(')));
      // The old opener is gone from the code (a comment mention
      // does not count).
      expect(_codeOnly(pro), isNot(contains('_openVoiceRoom')));
      // Wiring: toggle + active state on the header.
      expect(pro, contains('onVoice: _isTournament ? null : _toggleVoice,'));
      expect(pro, contains('voiceActive: _voicePanelOpen,'));
    });

    test('panel embeds the team room page (same scope, same seats)', () {
      final pro = _read('lib/screens/pro_features.dart');
      final panel = _method(pro, 'Widget _buildVoicePanel() {');
      expect(panel, contains('UnifiedRoomPage('));
      expect(panel, contains("scope: 'team',"));
      expect(panel, contains("teamId: SupaDb.strOf(widget.team['id']),"));
      // FIX 12 G5: no is_clan read in the panel — the voice panel
      // passes no flag at all.
      expect(panel, contains('micCount: teamMicCount(),'));
      expect(panel, isNot(contains('is_clan')));
      expect(panel, contains('embedded: true,'));
      expect(panel, contains('onCloseVoice:'));
      // Panel sits above the messages, under the header.
      expect(pro, contains('if (_voicePanelOpen && !_isTournament) _buildVoicePanel(),'));
    });

    test('embedded mode auto-joins and disconnects on close', () {
      final room = _read('lib/screens/room_screen.dart');
      // Embedded mode exists on the room page.
      expect(room, contains('final bool embedded;'));
      expect(room, contains('final VoidCallback? onCloseVoice;'));
      // Embedded renders the voice sections only (no full page).
      expect(room, contains('if (widget.embedded) return _buildEmbeddedVoice(uid, peers, kbOpen);'));
      // Mounting connects voice (same gates as the full page —
      // _joinVoiceOpen, not a second implementation).
      expect(room, contains('if (widget.embedded) {'));
      expect(room, contains('if (mounted) _joinVoiceOpen();'));
      // Unmounting leaves the room AND disconnects LiveKit — the
      // same dispose as the full page; only the presence
      // goOffline is skipped (the chat screen owns presence).
      expect(room, contains('if (!widget.embedded) PresenceService.goOffline();'));
      expect(room, contains('_room.leave();'));
      expect(room, contains('_lkRoom.disconnect();'));
      // Music rows keep flowing in embedded mode (no chat
      // StreamBuilder there to drive them).
      expect(room, contains('_musicRowsSub'));
    });

    test('locked community routes to the lock flow, never the panel', () {
      final pro = _read('lib/screens/pro_features.dart');
      // Lock = EXPLICIT false only — a flag-less clan team
      // keeps voice by default (isVoiceEnabled is fail-closed and
      // would lock every flag-less team — the wrong default here).
      expect(pro, contains("widget.team['voice_enabled'] == false"));
      expect(pro, contains("widget.team['voiceEnabled'] == false"));
      // Toggle checks the lock FIRST.
      final toggle = _method(pro, 'void _toggleVoice() {');
      expect(toggle.indexOf('_voiceLocked'), lessThan(toggle.indexOf('_voicePanelOpen')));
      // Lock flow pieces all exist (same copy as the public
      // community chat).
      expect(pro, contains('void _onLockedVoiceTap() {'));
      expect(pro, contains('void _showVoiceRequestSheet() {'));
      expect(pro, contains('Future<bool> _requestVoiceAccess() async {'));
      expect(pro, contains('Widget _voiceLockBanner() {'));
      expect(pro, contains("'Voice Locked hai'"));
      expect(pro, contains("'REQUEST VOICE ACCESS'"));
      // Banner under the header while locked.
      expect(pro, contains('if (_voiceLocked) _voiceLockBanner(),'));
    });

    test('header Voice button shows its active state', () {
      final chat = _read('lib/components/arena_chat.dart');
      expect(chat, contains('final bool voiceActive;'));
      expect(chat, contains('selected: voiceActive'));
      // Selected = gold filled circle + black icon + gold label.
      expect(chat, contains('selected ? kGold : kCard'));
    });
  });

  // ------------------------------------------------------------------
  // Widget tests: fake Firebase (pattern from
  // device_ban_gate_test.dart) + SupaDb.testFixtures (pattern from
  // community_tab_restructure_test.dart).
  // ------------------------------------------------------------------
  group('v2017 — widget: inline voice toggle', () {
    setUpAll(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
      FirebasePlatform.instance = _FakeCorePlatform();
      FirebaseAuthPlatform.instance = _FakeAuthPlatform();
      await Firebase.initializeApp();
      // Force the FirebaseAuth singleton (and its delegate) to exist
      // now, so every test starts from the same signed-out fake.
      // ignore: unnecessary_statements
      FirebaseAuth.instance;
      // FIX 22 item 6: the voice panel embeds the real room, whose
      // initState auto-tries DSP (_installMicNoiseProcessor). In
      // widget tests the native channel never answers, so
      // initialize()'s 2s timeout Timer stays pending and trips
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

    setUp(() async {
      await FirebaseAuth.instance.signInWithEmailAndPassword(
          email: 't@t.com', password: 'password');
      SupaDb.testFixtures = _fixtures(team: _clanTeam());
    });

    tearDown(() async {
      SupaDb.testFixtures = null;
      await FirebaseAuth.instance.signOut();
    });

    testWidgets('header Voice button: gold label while ON, plain while OFF',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ArenaChatHeader(
            onBack: () {},
            titleName: 'TEST CH',
            subtitle: '1 member',
            onVoice: () {},
            voiceActive: true,
          ),
        ),
      ));
      await tester.pump();
      final active = tester.widget<Text>(
          find.descendant(of: find.byType(ArenaChatHeader), matching: find.text('Voice')));
      expect(active.style?.color, kGold);
      expect(active.style?.fontWeight, FontWeight.w800);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ArenaChatHeader(
            onBack: () {},
            titleName: 'TEST CH',
            subtitle: '1 member',
            onVoice: () {},
            voiceActive: false,
          ),
        ),
      ));
      await tester.pump();
      final inactive = tester.widget<Text>(
          find.descendant(of: find.byType(ArenaChatHeader), matching: find.text('Voice')));
      expect(inactive.style?.color, kText);
      expect(inactive.style?.fontWeight, isNot(FontWeight.w800));
    });

    testWidgets('no Voice button when onVoice is null (DMs, tournaments)',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ArenaChatHeader(
            onBack: () {},
            titleName: 'TEST CH',
            subtitle: '1 member',
          ),
        ),
      ));
      await tester.pump();
      expect(find.text('Voice'), findsNothing);
    });

    testWidgets('locked team: banner + sheet, no panel, request -> PENDING',
        (tester) async {
      SupaDb.testFixtures = _fixtures(team: _lockedTeam());
      await tester.pumpWidget(MaterialApp(
        home: TeamChatPage(
          team: _lockedTeam(),
          uid: 'test-uid',
        ),
      ));
      await _settle(tester);

      // Lock banner under the header; creator sees the button.
      expect(find.text('Voice locked hai — admin approval ke baad milegi.'),
          findsOneWidget);
      expect(find.text('REQUEST VOICE ACCESS'), findsOneWidget);
      expect(find.byType(UnifiedRoomPage), findsNothing);

      // Tap Voice -> the request sheet, NOT the panel.
      await tester.tap(_voiceButton(tester));
      await _settle(tester);
      expect(find.text('Voice Locked hai'), findsOneWidget);
      expect(find.byType(UnifiedRoomPage), findsNothing);

      // Send the request -> sheet pops, banner shows PENDING.
      await tester.tap(find.text('SEND VOICE REQUEST'));
      await _settle(tester);
      expect(find.text('Voice Locked hai'), findsNothing);
      expect(find.text('PENDING'), findsOneWidget);
      expect(find.text('Voice request pending hai — admin approval ka intezar karen.'),
          findsOneWidget);
      expect(find.byType(UnifiedRoomPage), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('unlocked clan: tap Voice -> panel + 6 seats; tap again -> gone',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: TeamChatPage(
          team: _clanTeam(),
          uid: 'test-uid',
        ),
      ));
      await _settle(tester);
      expect(find.byType(UnifiedRoomPage), findsNothing);

      // ON: panel mounts, 6 mic seats, header label gold.
      await tester.tap(_voiceButton(tester));
      await _settle(tester);
      expect(find.byType(UnifiedRoomPage), findsOneWidget);
      expect(find.text('6'), findsOneWidget);
      expect(find.text('7'), findsNothing);
      final active = tester.widget<Text>(
          find.descendant(of: find.byType(ArenaChatHeader), matching: find.text('Voice')));
      expect(active.style?.color, kGold);
      // The room page is EMBEDDED — no second AppBar/Scaffold
      // push happened: the chat composer is still on screen.
      expect(find.text('Type a message...'), findsOneWidget);
      expect(tester.takeException(), isNull);

      // OFF: panel unmounts (dispose leaves + disconnects),
      // header label back to plain.
      await tester.tap(_voiceButton(tester));
      await _settle(tester);
      expect(find.byType(UnifiedRoomPage), findsNothing);
      final inactive = tester.widget<Text>(
          find.descendant(of: find.byType(ArenaChatHeader), matching: find.text('Voice')));
      expect(inactive.style?.color, kText);
      expect(tester.takeException(), isNull);
    });

    // FIX 11 (2026-11-23): the Squad team type is gone — a
    // non-clan team gets 6 mic seats too (no more 4-seat branch).
    testWidgets('unlocked non-clan team: tap Voice -> panel + 6 seats (no 7th)',
        (tester) async {
      SupaDb.testFixtures = _fixtures(team: _nonClanTeam());
      await tester.pumpWidget(MaterialApp(
        home: TeamChatPage(
          team: _nonClanTeam(),
          uid: 'test-uid',
        ),
      ));
      await _settle(tester);

      await tester.tap(_voiceButton(tester));
      await _settle(tester);
      expect(find.byType(UnifiedRoomPage), findsOneWidget);
      expect(find.text('6'), findsOneWidget);
      expect(find.text('7'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}

/// The Voice button in the chat header (scoped to the header so the
/// panel's own 'Voice On' indicator can never be mistaken for it).
Finder _voiceButton(WidgetTester tester) => find.descendant(
      of: find.byType(ArenaChatHeader),
      matching: find.text('Voice'),
    );

/// Pump past the fixture futures (getList/getRow/streamChat) and
/// the embedded panel's post-frame auto-join.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}

Map<String, dynamic> _clanTeam() => {
      'id': 'team-1',
      'name': 'TEST CH',
      'is_clan': true,
      'captain_uid': 'test-uid',
      'invite_code': 'ABC123',
      // No voice flag at all: voice by default (no approval).
    };

Map<String, dynamic> _nonClanTeam() => {
      'id': 'team-2',
      'name': 'Test Team',
      // Pre-Fix-11 squad row (is_clan false): still a full team
      // with 6 mic seats now — the flag no longer means Squad.
      'is_clan': false,
      'captain_uid': 'test-uid',
      'invite_code': 'XYZ789',
    };

Map<String, dynamic> _lockedTeam() => {
      'id': 'team-1',
      'name': 'TEST CH',
      'is_clan': true,
      'captain_uid': 'test-uid',
      'created_by_uid': 'test-uid',
      'invite_code': 'ABC123',
      'voice_enabled': false, // EXPLICIT false: locked.
    };

Map<String, List<Map<String, dynamic>>> _fixtures(
    {required Map<String, dynamic> team}) => {
      'teams': [team],
      'team_members': [
        {
          'team_id': team['id'],
          'firebase_uid': 'test-uid',
          'game_id': 'Tester',
        }
      ],
      'team_invitations': [],
      'profiles': [
        {
          'firebase_uid': 'test-uid',
          'display_name': 'Tester',
          'level': 1,
        }
      ],
      // The test user IS the designated admin, so the room page
      // treats them as room admin (mic-request gate skipped).
      'admin_config': [
        {'id': 1, 'admin_firebase_uid': 'test-uid'}
      ],
      // The lock flow's request needs the communities row.
      'communities': [
        {
          'id': team['id'],
          'name': team['name'],
          'created_by_uid': 'test-uid',
          'voice_enabled': team['voice_enabled'] ?? true,
        }
      ],
      'community_voice_requests': [],
      'chat_messages': [],
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
