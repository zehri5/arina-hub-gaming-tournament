// FIX 72 — CommunityDetailPage overflow (constrain fix) + mic-seats hide
// toggle — TEST VERIFICATION (2026-11-24, v2024 re-gate).
//
// The defect (gate report): CommunityDetailPage overflowed by 72px on the
// bottom at 800x600 / 71px at 360x800 — the embedded UnifiedRoomPage took
// nearly the whole screen, leaving the chat tab ~1-2px while the composer
// alone needs ~73px. The fix (FIX72-REPORT.md, code already in the tree):
//   * UnifiedRoomPage gains optional `sidebarReserve`; _buildCappedSidebar
//     uses it (override floor 160, default floor 220 — team 316 / community
//     236 defaults survive exactly when no override is passed).
//   * CommunityDetailPage._buildVoicePanel passes sidebarReserve: 480.0.
//   * The empty state is wrapped in SingleChildScrollView (the 93px
//     partial-height empty-state overflow at 360x800 unlocked).
//   * A chevron toggle (key 'fix72_seats_toggle') in the header strip
//     hides/shows the seats + sidebar Row; the host card NEVER hides
//     (fix23 item 16). Default shown, session-local.
//
// This file PROVES the fix — it does not re-pin the fix's own source:
//   (a) CommunityDetailPage mounts locked + unlocked at 800x600, 360x800,
//       360x667: no overflow, composer visible, chat height measured
//       against the FIX72-REPORT predictions (locked 205/167px,
//       unlocked 281/321px — PREDICTED, measured here for real).
//   (b) TeamChatPage mounts at 800x600 + 360x667: no regression.
//   (c) Hide toggle: default shown on entry; tap -> seats + sidebar Row
//       unmounts, chat expands, composer visible, host card present;
//       tap again -> seats + sidebar return; host card present in BOTH
//       states.
//
// Mount pattern + fake Firebase + DSP mock copied from
// fix31b_fix_verify_test.dart; _loadRoboto (real-phone metrics) from
// fix11_community_tabs_test.dart (fix17 pattern).
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_auth_platform_interface/firebase_auth_platform_interface.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/components/arena_chat.dart';
import 'package:protournament_user/screens/communities_screens.dart';
import 'package:protournament_user/screens/pro_features.dart';
import 'package:protournament_user/screens/room_screen.dart';
import 'package:protournament_user/services/supabase_db.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('FIX 72 — CommunityDetailPage overflow + mic-seats hide toggle', () {
    setUpAll(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
      // FIX 17: real Roboto — real-phone metrics, not the ~2x
      // wider/taller fallback test font.
      await _loadRoboto();
      FirebasePlatform.instance = _FakeCorePlatform();
      FirebaseAuthPlatform.instance = _FakeAuthPlatform();
      await Firebase.initializeApp();
      // ignore: unnecessary_statements
      FirebaseAuth.instance;
      // DSP mock: isAvailable -> false (no pending 2s timer).
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
      await FirebaseAuth.instance
          .signInWithEmailAndPassword(email: 't@t.com', password: 'password');
    });

    tearDown(() async {
      SupaDb.testFixtures = null;
      await FirebaseAuth.instance.signOut();
    });

    // ---- (a) CommunityDetailPage mounts ----

    testWidgets('CommunityDetailPage LOCKED 800x600: no overflow, chat ~205px',
        (tester) async {
      final errors = _captureErrors();
      SupaDb.testFixtures =
          _communityFixtures(community: _lockedCommunity());
      await tester.pumpWidget(MaterialApp(
        home: CommunityDetailPage(
          uid: 'test-uid',
          communityId: 'comm-1',
          community: _lockedCommunity(),
        ),
      ));
      await _settle(tester);
      _restoreErrors(errors);
      expect(find.byType(UnifiedRoomPage), findsOneWidget);
      expect(find.byType(ArenaChatInputBar), findsOneWidget,
          reason: 'composer must be visible (the defect cut it off)');
      _expectNoBottomOverflow(errors);
      expect(tester.takeException(), isNull);
      final chat = _chatTabHeight(tester);
      // ignore: avoid_print
      print('FIX72 MEASURED locked 800x600 chat height: ${chat.toStringAsFixed(1)}px (predicted 205)');
      expect(chat, greaterThanOrEqualTo(143),
          reason: 'chat tab must fit its ~143px minimum content');
      _expectComposerOnScreen(tester);
    });

    testWidgets('CommunityDetailPage LOCKED 360x800: no overflow, chat ~167px',
        (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final errors = _captureErrors();
      SupaDb.testFixtures =
          _communityFixtures(community: _lockedCommunity());
      await tester.pumpWidget(MaterialApp(
        home: CommunityDetailPage(
          uid: 'test-uid',
          communityId: 'comm-1',
          community: _lockedCommunity(),
        ),
      ));
      await _settle(tester);
      _restoreErrors(errors);
      expect(find.byType(UnifiedRoomPage), findsOneWidget);
      expect(find.byType(ArenaChatInputBar), findsOneWidget,
          reason: 'composer must be visible (the defect cut it off)');
      _expectNoBottomOverflow(errors);
      expect(tester.takeException(), isNull);
      final chat = _chatTabHeight(tester);
      // ignore: avoid_print
      print('FIX72 MEASURED locked 360x800 chat height: ${chat.toStringAsFixed(1)}px (predicted 167)');
      expect(chat, greaterThanOrEqualTo(143),
          reason: 'chat tab must fit its ~143px minimum content');
      _expectComposerOnScreen(tester);
    });

    testWidgets('CommunityDetailPage UNLOCKED 360x667: no overflow',
        (tester) async {
      tester.view.physicalSize = const Size(360, 667);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final errors = _captureErrors();
      SupaDb.testFixtures =
          _communityFixtures(community: _unlockedCommunity());
      await tester.pumpWidget(MaterialApp(
        home: CommunityDetailPage(
          uid: 'test-uid',
          communityId: 'comm-1',
          community: _unlockedCommunity(),
        ),
      ));
      await _settle(tester);
      _restoreErrors(errors);
      expect(find.byType(UnifiedRoomPage), findsOneWidget);
      expect(find.text('6'), findsOneWidget,
          reason: 'mic seats are part of the mounted panel');
      expect(find.byType(ArenaChatInputBar), findsOneWidget,
          reason: 'composer must be visible');
      _expectNoBottomOverflow(errors);
      expect(tester.takeException(), isNull);
      final chat = _chatTabHeight(tester);
      // ignore: avoid_print
      print('FIX72 MEASURED unlocked 360x667 chat height: ${chat.toStringAsFixed(1)}px');
      expect(chat, greaterThanOrEqualTo(143),
          reason: 'chat tab must fit its ~143px minimum content');
      _expectComposerOnScreen(tester);
    });

    testWidgets(
        'CommunityDetailPage UNLOCKED 800x600: no overflow, chat ~281px',
        (tester) async {
      final errors = _captureErrors();
      SupaDb.testFixtures =
          _communityFixtures(community: _unlockedCommunity());
      await tester.pumpWidget(MaterialApp(
        home: CommunityDetailPage(
          uid: 'test-uid',
          communityId: 'comm-1',
          community: _unlockedCommunity(),
        ),
      ));
      await _settle(tester);
      _restoreErrors(errors);
      expect(find.byType(UnifiedRoomPage), findsOneWidget);
      expect(find.text('6'), findsOneWidget,
          reason: 'mic seats are part of the mounted panel');
      expect(find.byType(ArenaChatInputBar), findsOneWidget,
          reason: 'composer must be visible');
      _expectNoBottomOverflow(errors);
      expect(tester.takeException(), isNull);
      final chat = _chatTabHeight(tester);
      // ignore: avoid_print
      print('FIX72 MEASURED unlocked 800x600 chat height: ${chat.toStringAsFixed(1)}px (predicted 281)');
      expect(chat, greaterThanOrEqualTo(143),
          reason: 'chat tab must fit its ~143px minimum content');
      _expectComposerOnScreen(tester);
    });

    // ---- (b) TeamChatPage mounts — no regression ----

    testWidgets('TeamChatPage 800x600, panel open: no regression',
        (tester) async {
      final errors = _captureErrors();
      SupaDb.testFixtures = _teamFixtures(team: _team());
      await tester.pumpWidget(
          MaterialApp(home: TeamChatPage(team: _team(), uid: 'test-uid')));
      await _settle(tester);
      await tester.tap(_headerButton(tester, 'Voice'));
      await _settle(tester);
      _restoreErrors(errors);
      expect(find.byType(UnifiedRoomPage), findsOneWidget);
      expect(find.text('6'), findsOneWidget,
          reason: 'mic seats are part of the mounted panel');
      expect(find.byType(ArenaChatInputBar), findsOneWidget,
          reason: 'composer must be visible');
      _expectNoBottomOverflow(errors);
      expect(tester.takeException(), isNull);
    });

    testWidgets('TeamChatPage 360x667, panel open: no BOTTOM overflow',
        (tester) async {
      tester.view.physicalSize = const Size(360, 667);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final errors = _captureErrors();
      SupaDb.testFixtures = _teamFixtures(team: _team());
      await tester.pumpWidget(
          MaterialApp(home: TeamChatPage(team: _team(), uid: 'test-uid')));
      await _settle(tester);
      await tester.tap(_headerButton(tester, 'Voice'));
      await _settle(tester);
      _restoreErrors(errors);
      expect(find.byType(UnifiedRoomPage), findsOneWidget);
      expect(find.text('6'), findsOneWidget,
          reason: 'mic seats are part of the mounted panel');
      // Direction assertion (fix31b pattern): the pre-existing 7px
      // RIGHT overflow in ArenaChatHeader (baseline, all 360-wide
      // sizes) may still appear; a BOTTOM overflow must not.
      _expectNoBottomOverflow(errors);
    });

    // ---- (c) Hide toggle ----

    testWidgets(
        'Hide toggle: default shown -> hide (chat expands, host card stays) -> show',
        (tester) async {
      final errors = <String>[];
      SupaDb.testFixtures =
          _communityFixtures(community: _unlockedCommunity());
      await tester.pumpWidget(MaterialApp(
        home: CommunityDetailPage(
          uid: 'test-uid',
          communityId: 'comm-1',
          community: _unlockedCommunity(),
        ),
      ));
      // Phase 0 — entry: capture, settle, restore, THEN expects.
      errors.addAll(await _settleCaptured(tester));

      // Default state on entry: seats + sidebar SHOWN.
      final toggle = find.byKey(const ValueKey('fix72_seats_toggle'));
      expect(toggle, findsOneWidget, reason: 'chevron toggle must exist');
      expect(find.text('6'), findsOneWidget,
          reason: 'default state: mic seats shown on entry');
      expect(find.text('Followers'), findsOneWidget,
          reason: 'default state: sidebar shown on entry');
      expect(find.text('Host'), findsOneWidget,
          reason: 'fix23 item 16: host card present');
      expect(find.byType(ArenaChatInputBar), findsOneWidget);
      final chatBefore = _chatTabHeight(tester);

      // Phase 1 — tap -> seats + sidebar Row unmounts, chat expands.
      errors.addAll(await _tapCaptured(tester, toggle));
      expect(find.text('6'), findsNothing,
          reason: 'seats must unmount when hidden');
      expect(find.text('Followers'), findsNothing,
          reason: 'sidebar must unmount when hidden');
      expect(find.text('Host'), findsOneWidget,
          reason: 'fix23 item 16: host card NEVER hides');
      expect(find.byType(ArenaChatInputBar), findsOneWidget,
          reason: 'composer visible while seats hidden');
      expect(toggle, findsOneWidget,
          reason: 'toggle stays (it lives in the header strip)');
      final chatHidden = _chatTabHeight(tester);
      // ignore: avoid_print
      print('FIX72 MEASURED toggle 800x600 chat: shown=${chatBefore.toStringAsFixed(1)}px hidden=${chatHidden.toStringAsFixed(1)}px');
      expect(chatHidden, greaterThan(chatBefore + 100),
          reason: 'chat must expand into the freed space');
      _expectComposerOnScreen(tester);

      // Phase 2 — tap again -> seats + sidebar return.
      errors.addAll(await _tapCaptured(tester, toggle));
      expect(find.text('6'), findsOneWidget,
          reason: 'seats return on second tap');
      expect(find.text('Followers'), findsOneWidget,
          reason: 'sidebar returns on second tap');
      expect(find.text('Host'), findsOneWidget,
          reason: 'fix23 item 16: host card present after re-show');
      expect(find.byType(ArenaChatInputBar), findsOneWidget);
      final chatBack = _chatTabHeight(tester);
      expect(chatBack, closeTo(chatBefore, 1.0),
          reason: 'chat height must return to its shown-state value');
      _expectComposerOnScreen(tester);

      _expectNoBottomOverflow(errors);
      expect(tester.takeException(), isNull);
    });
  });
}

/// The test binding's own FlutterError handler (saved at capture
/// time, restored after — restoring to presentError would break
/// tester.takeException()).
void Function(FlutterErrorDetails)? _prevErrorHandler;

/// Capture every FlutterError for direction assertions. MUST be
/// restored (via [_restoreErrors]) BEFORE any expect() runs — an
/// expect failure with a custom handler installed wedges the
/// runner (fix72 probe lesson).
List<String> _captureErrors() {
  final errors = <String>[];
  _prevErrorHandler = FlutterError.onError;
  FlutterError.onError = (details) {
    errors.add(details.exceptionAsString());
  };
  return errors;
}

void _restoreErrors(List<String> errors) {
  FlutterError.onError = _prevErrorHandler ?? FlutterError.presentError;
}

/// Settle while capturing FlutterErrors; handler restored before
/// this returns, so expects after it are safe.
Future<List<String>> _settleCaptured(WidgetTester tester) async {
  final errors = _captureErrors();
  await _settle(tester);
  _restoreErrors(errors);
  return errors;
}

/// Tap + settle while capturing FlutterErrors; handler restored
/// before this returns, so expects after it are safe.
Future<List<String>> _tapCaptured(WidgetTester tester, Finder target) async {
  final errors = _captureErrors();
  await tester.tap(target);
  await _settle(tester);
  _restoreErrors(errors);
  return errors;
}

void _expectNoBottomOverflow(List<String> errors) {
  final bottom = errors
      .where((e) => e.contains('overflowed') && e.contains('on the bottom'))
      .toList();
  expect(bottom, isEmpty, reason: 'bottom overflow(s): $bottom');
}

/// The chat tab's height: screen height minus the bottom of the
/// embedded panel (the page Column is [banner?, panel, Expanded
/// chat], so the tab starts where the panel ends).
double _chatTabHeight(WidgetTester tester) {
  final h =
      tester.view.physicalSize.height / tester.view.devicePixelRatio;
  final panelBottom =
      tester.getBottomLeft(find.byType(UnifiedRoomPage)).dy;
  return h - panelBottom;
}

/// The composer must be fully on screen (not pushed below the fold
/// by an overflow — the defect's user-visible symptom).
void _expectComposerOnScreen(WidgetTester tester) {
  final h =
      tester.view.physicalSize.height / tester.view.devicePixelRatio;
  final composerBottom =
      tester.getBottomRight(find.byType(ArenaChatInputBar)).dy;
  expect(composerBottom, lessThanOrEqualTo(h + 0.5),
      reason: 'composer bottom $composerBottom must be within screen $h');
}

/// A header circle button's label, scoped to the header so the
/// panel's own texts can never be mistaken for it.
Finder _headerButton(WidgetTester tester, String label) =>
    find.descendant(of: find.byType(ArenaChatHeader), matching: find.text(label));

/// Pump past the fixture futures (getList/getRow/streamChat) and
/// the embedded panel's post-frame auto-join — plus the join's
/// delayed re-asserts, so no service timer is still pending at
/// test end (fix16 pattern).
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

Map<String, List<Map<String, dynamic>>> _teamFixtures(
        {required Map<String, dynamic> team}) =>
    {
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
        {
          'id': team['id'],
          'name': team['name'],
          'created_by_uid': 'test-uid',
          'voice_enabled': team['voice_enabled'] ?? true
        }
      ],
      'community_voice_requests': [],
      'chat_messages': [],
    };

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

/// Locked: voice_enabled false -> CommunityGroups.isVoiceEnabled
/// false -> the page shows the voice-lock banner and passes
/// voiceLocked: true to the embedded room (seats become the
/// "Voice locked" line).
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

Map<String, List<Map<String, dynamic>>> _communityFixtures(
        {required Map<String, dynamic> community}) =>
    {
      'communities': [community],
      'community_members': [
        {
          'community_id': community['id'],
          'firebase_uid': 'test-uid',
          'role': 'creator',
        }
      ],
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

// ---- Fake Firebase (exact pattern from fix16_voice_header_test) ----

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
              projectId: 'test'),
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
      String email, String password) async {
    final details = PigeonUserDetails(
      userInfo: PigeonUserInfo(
          uid: 'test-uid',
          email: email,
          isAnonymous: false,
          isEmailVerified: true),
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

// FIX 17 (gate): load the real Roboto so fit tests measure what a
// real phone measures — the fallback test font is ~2x wider/taller
// and fakes an overflow (same approach as fix11_community_tabs_test).
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
