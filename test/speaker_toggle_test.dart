// SPEAKER TOGGLE — REMOVED (FIX 22 item 7, Sameer 2026-11-23 18:49:
// "hata do, big speaker pe voice & sound music ana chahiye").
//
// The old spec (this file's previous version) pinned a working
// Speaker ON/OFF toggle. That spec is CANCELLED: the toggle is
// GONE from the UI entirely (RoomSpeakerRow deleted), voice +
// music are ALWAYS on the loudspeaker, and no code path may flip
// the speaker off. The real ask behind the toggle was Bluetooth
// headphones: BLUETOOTH_CONNECT is declared + requested at
// runtime, and the mesh route prefers Bluetooth when connected
// (setSpeakerphoneOnButPreferBluetooth) — never forced to the
// loudspeaker over BT.
//
// What this file pins now:
//   (a) no Speaker row/toggle anywhere in the UI;
//   (b) the speaker preference is permanently ON in BOTH voice
//       engines (LiveKit + mesh), with no setSpeaker method left;
//   (c) AndroidManifest declares BLUETOOTH_CONNECT (and NOT
//       BLUETOOTH_SCAN — the app has no BT device-picker UI),
//       and the runtime permission request exists.
//
// The widget tests reuse the fake-Firebase pattern from
// home_empty_fix_test.dart (VoiceRoom reads
// FirebaseAuth.instance.currentUser at construction).
import 'dart:async';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_auth_platform_interface/firebase_auth_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/services/livekit_voice_service.dart';
import 'package:protournament_user/services/voice_service.dart';

// ---------- fake Firebase (pattern from home_empty_fix_test.dart) ----------

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

class _FakeAuthPlatform extends FirebaseAuthPlatform {
  _FakeAuthPlatform({super.appInstance});

  UserPlatform? _user;

  @override
  FirebaseAuthPlatform delegateFor({required FirebaseApp app}) =>
      _FakeAuthPlatform(appInstance: app);

  @override
  FirebaseAuthPlatform setInitialValues({PigeonUserDetails? currentUser, String? languageCode}) {
    final uid = currentUser?.userInfo.uid ?? 'test-uid';
    _user = _FakeUser(
      this,
      _FakeMultiFactor(this),
      PigeonUserDetails(userInfo: PigeonUserInfo(uid: uid, isAnonymous: false, isEmailVerified: true), providerData: []),
    );
    return this;
  }

  @override
  UserPlatform? get currentUser => _user;

  @override
  set currentUser(UserPlatform? user) => _user = user;
}

// ---------- source-pin helpers ----------

String _read(String path) => File(path).readAsStringSync();

/// True when [needle] appears in [src] OUTSIDE a `//` comment
/// (checked per line: only the part before the first `//` counts).
/// The removal notes mention the deleted names in comments
/// ("setSpeaker is deleted", "(setSpeakerphoneOn(false) =
/// earpiece) is deleted", "RoomSpeakerRow, deleted") — those
/// must not trip the absence pins.
bool _codeContains(String src, String needle) {
  for (final line in src.split('\n')) {
    final code = line.split('//').first;
    if (code.contains(needle)) return true;
  }
  return false;
}

bool _codeMatches(String src, RegExp pattern) {
  for (final line in src.split('\n')) {
    final code = line.split('//').first;
    if (pattern.hasMatch(code)) return true;
  }
  return false;
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    FirebasePlatform.instance = _FakeCorePlatform();
    FirebaseAuthPlatform.instance = _FakeAuthPlatform();
    await Firebase.initializeApp(
      options: const FirebaseOptions(apiKey: 'test', appId: '1:1:android:1', messagingSenderId: '1', projectId: 'test'),
    );
    // VoiceRoom reads the signed-in user at construction.
    expect(FirebaseAuth.instance.currentUser, isNotNull);
  });

  group('speaker preference is permanently ON (services)', () {
    test('LiveKit speakerOn is always true', () {
      final lkRoom = LiveKitVoiceService(roomId: 't1', roomLabel: 'Test');
      expect(lkRoom.speakerOn, isTrue);
    });

    test('mesh speakerOn is always true', () {
      final room = VoiceRoom(roomId: 't1', roomLabel: 'Test');
      expect(room.speakerOn, isTrue);
    });
  });

  group('no speaker toggle anywhere in the UI (source pins)', () {
    late String roomScreen;
    late String sheet;
    late String lkService;
    late String meshService;

    setUpAll(() {
      roomScreen = _read('lib/screens/room_screen.dart');
      sheet = _read('lib/widgets/voice_settings_sheet.dart');
      lkService = _read('lib/services/livekit_voice_service.dart');
      meshService = _read('lib/services/voice_service.dart');
    });

    test('RoomSpeakerRow widget file is deleted', () {
      expect(File('lib/widgets/room_speaker_row.dart').existsSync(), isFalse);
    });

    test('no RoomSpeakerRow construction or import in lib', () {
      // The room screen mentions it only in a removal comment.
      expect(_codeContains(roomScreen, 'RoomSpeakerRow'), isFalse);
      expect(_codeContains(sheet, 'RoomSpeakerRow'), isFalse);
      expect(_codeContains(roomScreen, 'room_speaker_row.dart'), isFalse);
      expect(_codeContains(sheet, 'room_speaker_row.dart'), isFalse);
    });

    test("no 'LiveKit Speaker' label anywhere in code", () {
      expect(_codeContains(roomScreen, 'LiveKit Speaker'), isFalse);
      expect(_codeContains(sheet, 'LiveKit Speaker'), isFalse);
    });

    test('voice settings sheet has no speaker switch', () {
      // No speakerOn reference at all in the sheet — nothing
      // left for a toggle to drive.
      expect(_codeContains(sheet, 'speakerOn'), isFalse);
      expect(_codeContains(sheet, 'setSpeaker'), isFalse);
    });

    test('speaker preference is a hardcoded true in both services', () {
      expect(lkService, contains('bool get speakerOn => true;'));
      expect(meshService, contains('bool get speakerOn => true;'));
    });

    test('no setSpeaker method left in either service', () {
      // \bsetSpeaker\s*\( matches the deleted method's calls
      // and definition, but NOT setSpeakerOutputPreferred /
      // setSpeakerphoneOn* (identifier continues past the name).
      final setSpeakerCall = RegExp(r'\bsetSpeaker\s*\(');
      expect(_codeMatches(lkService, setSpeakerCall), isFalse);
      expect(_codeMatches(meshService, setSpeakerCall), isFalse);
    });

    test('LiveKit asserts speaker output preferred (true) at join', () {
      expect(lkService, contains('setSpeakerOutputPreferred(true)'));
    });

    test('mesh asserts speaker output preferred (true) too', () {
      expect(meshService, contains('setSpeakerOutputPreferred(true)'));
    });

    test('mesh never forces the earpiece; BT is preferred', () {
      // The earpiece path (setSpeakerphoneOn(false)) is deleted
      // — it survives only in a removal comment. The live call
      // prefers Bluetooth when headphones are connected.
      expect(_codeContains(meshService, 'setSpeakerphoneOn(false)'), isFalse);
      expect(
        meshService,
        contains('setSpeakerphoneOnButPreferBluetooth()'),
      );
    });
  });

  group('Bluetooth permission (manifest + runtime)', () {
    late String manifest;
    late String roomScreen;

    setUpAll(() {
      manifest = _read('android/app/src/main/AndroidManifest.xml');
      roomScreen = _read('lib/screens/room_screen.dart');
    });

    test('manifest declares BLUETOOTH_CONNECT', () {
      expect(
        manifest,
        contains('android.permission.BLUETOOTH_CONNECT'),
      );
    });

    test('manifest does NOT declare BLUETOOTH_SCAN (no picker UI)', () {
      expect(manifest, isNot(contains('BLUETOOTH_SCAN')));
    });

    test('runtime BLUETOOTH_CONNECT request exists in the room', () {
      expect(
        roomScreen,
        contains('Permission.bluetoothConnect.request()'),
      );
    });
  });
}
