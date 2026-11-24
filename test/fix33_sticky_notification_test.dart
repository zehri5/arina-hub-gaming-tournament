// FIX 33 — STICKY VOICE-CHAT NOTIFICATION (2026-11-24 user report,
// v2022): after leaving the voice room, the "Pro Tournament voice
// chat" notification STAYED in the shade and could not be swiped
// away (setOngoing(true)). The notification is posted by the native
// VoiceForegroundService and can only be removed by stopping that
// service — Dart does that via MethodChannel
// 'pro_tournament/voice_foreground' invokeMethod('stop').
//
// These tests mock that channel and assert 'stop' is invoked on
// EVERY session-ending path:
//   * LiveKit connect failure / timeout (start already ran — the
//     failed join must undo it; joined stays false, so no leave
//     path is ever offered to clear it otherwise).
//   * LiveKit disconnect() (the normal leave).
//   * LiveKit dispose() without disconnect.
//   * LiveKit RoomDisconnectedEvent (server-side / network drop).
//   * Mesh VoiceRoom.leave() (including never-joined: the stop is
//     unconditional — that is what clears a LiveKit-started
//     notification on the Leave Room path).
//   * Mesh VoiceRoom.dispose() without leave.
// Plus source pins (established repo pattern — see
// speaker_toggle_test.dart) for the two fixes that cannot be driven
// from a unit test: _exitRoom() disconnecting the LiveKit engine,
// and the native service's START_NOT_STICKY + onTaskRemoved
// (no Kotlin compile exists on this VM).
import 'dart:async';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_auth_platform_interface/firebase_auth_platform_interface.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:protournament_user/services/livekit_voice_service.dart';
import 'package:protournament_user/services/voice_service.dart';

const _voiceChannel = MethodChannel('pro_tournament/voice_foreground');

// ---------- fake Firebase (VoiceRoom reads currentUser at construction) ----------
// Copied from test/speaker_toggle_test.dart.

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

// ---------- fake LiveKit room (copied from test/fix12_g6_voice_room_test.dart) ----------

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

// ---------- source-pin helpers (copied from test/speaker_toggle_test.dart) ----------

String _read(String path) => File(path).readAsStringSync();

/// True when [needle] appears in [src] OUTSIDE a `//` comment
/// (checked per line: only the part before the first `//` counts).
bool _codeContains(String src, String needle) {
  for (final line in src.split('\n')) {
    final code = line.split('//').first;
    if (code.contains(needle)) return true;
  }
  return false;
}

void main() {
  final calls = <String>[];

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    FirebasePlatform.instance = _FakeCorePlatform();
    FirebaseAuthPlatform.instance = _FakeAuthPlatform();
    await Firebase.initializeApp(
      options: const FirebaseOptions(apiKey: 'test', appId: '1:1:android:1', messagingSenderId: '1', projectId: 'test'),
    );
    expect(FirebaseAuth.instance.currentUser, isNotNull);
  });

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_voiceChannel, (call) async {
      calls.add(call.method);
      return null;
    });
  });

  tearDown(() {
    // The timeout test shortens the static — always restore.
    LiveKitVoiceService.connectTimeout = const Duration(seconds: 30);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_voiceChannel, null);
  });

  /// True when a 'stop' was recorded AFTER the last 'start' — i.e.
  /// the service the session started was actually stopped again.
  bool stoppedAfterStart() {
    final start = calls.lastIndexOf('start');
    final stop = calls.lastIndexOf('stop');
    return start >= 0 && stop > start;
  }

  group('fix33 — LiveKit: stop on every session end', () {
    test('failed connect: start is undone by stop', () async {
      final svc = LiveKitVoiceService(roomId: 'community_comm-1', roomLabel: 'Test');
      svc.roomFactory = () => _FakeLkRoom(
          connectBehavior: () async => throw Exception('boom'));
      await svc.connect('wss://fake.invalid', 'fake-token');
      expect(svc.joined, isFalse);
      expect(svc.error, isNotNull);
      expect(calls, contains('start'));
      expect(stoppedAfterStart(), isTrue,
          reason: 'failed connect left the service running: $calls');
      svc.dispose();
    });

    test('connect timeout: start is undone by stop', () async {
      LiveKitVoiceService.connectTimeout =
          const Duration(milliseconds: 200);
      final svc = LiveKitVoiceService(roomId: 'community_comm-1', roomLabel: 'Test');
      svc.roomFactory = () => _FakeLkRoom(
          connectBehavior: () => Completer<void>().future);
      await svc.connect('wss://blackhole.invalid', 'fake-token');
      expect(svc.joined, isFalse);
      expect(svc.error, contains('timeout'));
      expect(calls, contains('start'));
      expect(stoppedAfterStart(), isTrue,
          reason: 'timed-out connect left the service running: $calls');
      svc.dispose();
    });

    test('disconnect() stops the service', () async {
      final svc = LiveKitVoiceService(roomId: 'community_comm-1', roomLabel: 'Test');
      svc.roomFactory = () => _FakeLkRoom();
      await svc.connect('wss://fake.invalid', 'fake-token');
      expect(svc.joined, isTrue);
      expect(calls, contains('start'));
      await svc.disconnect();
      expect(stoppedAfterStart(), isTrue,
          reason: 'disconnect did not stop the service: $calls');
      svc.dispose();
    });

    test('dispose() without disconnect stops the service', () async {
      final svc = LiveKitVoiceService(roomId: 'community_comm-1', roomLabel: 'Test');
      svc.roomFactory = () => _FakeLkRoom();
      await svc.connect('wss://fake.invalid', 'fake-token');
      expect(svc.joined, isTrue);
      svc.dispose(); // no disconnect() first
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(stoppedAfterStart(), isTrue,
          reason: 'dispose without disconnect leaked the service: $calls');
    });

    test('server-side drop (RoomDisconnectedEvent) stops the service',
        () async {
      final svc = LiveKitVoiceService(roomId: 'community_comm-1', roomLabel: 'Test');
      final fake = _FakeLkRoom();
      svc.roomFactory = () => fake;
      await svc.connect('wss://fake.invalid', 'fake-token');
      expect(svc.joined, isTrue);
      // The SDK emits this when the room drops on its own
      // (server kick / network loss) — no leave button is pressed.
      // emit() is @internal in livekit_client, so this is the one
      // place a test may drive the SDK event directly.
      // ignore: invalid_use_of_internal_member
      fake.events.emit(lk.RoomDisconnectedEvent());
      // The listener runs on an async broadcast stream.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(svc.joined, isFalse);
      expect(stoppedAfterStart(), isTrue,
          reason: 'server-side drop left the service running: $calls');
      svc.dispose();
    });
  });

  group('fix33 — mesh: stop on every session end', () {
    test('leave() stops the service even when never joined', () async {
      // The stop is UNCONDITIONAL: Leave Room relies on the mesh
      // leave to clear a LiveKit-started notification too.
      final room = VoiceRoom(roomId: 't1', roomLabel: 'Test');
      expect(room.joined, isFalse);
      await room.leave();
      expect(calls, contains('stop'));
      room.dispose();
    });

    test('dispose() without leave stops the service', () async {
      final room = VoiceRoom(roomId: 't1', roomLabel: 'Test');
      room.dispose(); // no leave() first
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(calls, contains('stop'));
    });
  });

  group('fix33 — source pins (paths a unit test cannot drive)', () {
    test('_exitRoom disconnects the LiveKit engine too', () {
      final src = _read('lib/screens/room_screen.dart');
      final start = src.indexOf('Future<void> _exitRoom() async {');
      final end = src.indexOf(
          'Future<void> _leaveEmbeddedVoice() async {', start);
      expect(start, isNot(-1), reason: '_exitRoom not found');
      expect(end, greaterThan(start),
          reason: '_leaveEmbeddedVoice must follow _exitRoom');
      final body = src.substring(start, end);
      expect(body, contains('await _room.leave();'),
          reason: '_exitRoom must still leave the mesh');
      expect(body, contains('await _lkRoom.disconnect();'),
          reason: 'Leave Room never disconnected LiveKit — the '
              'user stayed a ghost participant until dispose ran');
    });

    test('native service never restarts itself (START_NOT_STICKY + onTaskRemoved)', () {
      // No Kotlin compile exists on this VM — pin the source so a
      // regression is caught here. START_STICKY restarted the
      // service after a process kill with no Dart alive to stop
      // it: the permanent stuck notification.
      final src = _read(
          'android/app/src/main/kotlin/com/protournament/app/VoiceForegroundService.kt');
      expect(_codeContains(src, 'return START_NOT_STICKY'), isTrue);
      expect(_codeContains(src, 'return START_STICKY'), isFalse,
          reason: 'START_STICKY restarts a mic service no Dart '
              'code can ever stop again');
      expect(_codeContains(src, 'override fun onTaskRemoved'), isTrue,
          reason: 'swiping the app from recents must stop the service');
      expect(_codeContains(src, 'stopForeground(true)'), isTrue,
          reason: 'onDestroy must still remove the notification');
    });
  });
}
