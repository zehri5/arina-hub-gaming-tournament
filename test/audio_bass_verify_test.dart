// INDEPENDENT VERIFIER TESTS — Group 5 (DSP bass/EQ), Arena Hub #10 Audio.
// Written from the spec ONLY, without seeing the implementer's code.
// Contract under test:
//   - Dart: class BassEqEffect in lib/services/audio_effects_bass.dart
//     with setBass(double), setEqBand(int, double), dispose().
//   - Platform channel 'arena_audio/effects', methods 'setBass' and 'setEq'.
//   - Native: android/.../BassEqEffect.kt implementing setBass/setEq.
// These tests FAIL until the implementation lands — that is expected.
// Do NOT weaken them to pass without the implementation.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/services/audio_effects_bass.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channelName = 'arena_audio/effects';
  const channel = MethodChannel(channelName);

  final List<MethodCall> calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      calls.add(call);
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  /// The channel call is issued synchronously when the Dart method body runs
  /// up to its first await, so one microtask turn is enough for the mock
  /// handler to have recorded it — whether the method returns void or
  /// Future<void>.
  Future<void> settle() async {
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
  }

  bool argCarries(Object? arg, Object value) {
    if (arg == value) return true;
    if (arg is Map) {
      return arg.values.any((v) => v == value);
    }
    if (arg is List) return arg.contains(value);
    return false;
  }

  group('BassEqEffect contract (Group 5 verifier)', () {
    test('class exists and can be constructed', () {
      final fx = BassEqEffect();
      expect(fx, isNotNull);
      fx.dispose();
    });

    test('setBass invokes method setBass on channel arena_audio/effects',
        () async {
      final fx = BassEqEffect();
      fx.setBass(0.75);
      await settle();
      expect(calls, isNotEmpty,
          reason: 'no call arrived on arena_audio/effects');
      expect(calls.first.method, 'setBass');
      fx.dispose();
    });

    test('setBass passes the bass value through', () async {
      final fx = BassEqEffect();
      fx.setBass(0.75);
      await settle();
      expect(calls, isNotEmpty);
      expect(argCarries(calls.first.arguments, 0.75), isTrue,
          reason: 'setBass argument did not carry 0.75: '
              '${calls.first.arguments}');
      fx.dispose();
    });

    test('setEqBand invokes method setEq on channel arena_audio/effects',
        () async {
      final fx = BassEqEffect();
      fx.setEqBand(2, -4.5);
      await settle();
      expect(calls, isNotEmpty,
          reason: 'no call arrived on arena_audio/effects');
      expect(calls.first.method, 'setEq');
      fx.dispose();
    });

    test('setEqBand passes band index and gain through', () async {
      final fx = BassEqEffect();
      fx.setEqBand(2, -4.5);
      await settle();
      expect(calls, isNotEmpty);
      final arg = calls.first.arguments;
      expect(argCarries(arg, 2), isTrue,
          reason: 'setEq argument did not carry band 2: $arg');
      expect(argCarries(arg, -4.5), isTrue,
          reason: 'setEq argument did not carry gain -4.5: $arg');
      fx.dispose();
    });

    test('repeated setBass calls each reach the platform', () async {
      final fx = BassEqEffect();
      fx.setBass(0.1);
      fx.setBass(0.9);
      await settle();
      expect(calls.where((c) => c.method == 'setBass').length, 2);
      fx.dispose();
    });

    test('dispose completes without throwing', () {
      final fx = BassEqEffect();
      expect(() => fx.dispose(), returnsNormally);
    });

    test('Dart source declares the contracted channel and method names', () {
      final src = File('lib/services/audio_effects_bass.dart')
          .readAsStringSync();
      expect(src, contains('arena_audio/effects'));
      expect(src, contains('setBass'));
      expect(src, contains('setEq'));
      expect(src, contains('class BassEqEffect'));
    });

    test('native BassEqEffect.kt exists and implements setBass/setEq', () {
      const ktPath =
          'android/app/src/main/kotlin/com/protournament/app/BassEqEffect.kt';
      final file = File(ktPath);
      expect(file.existsSync(), isTrue,
          reason: 'native file missing: $ktPath');
      final src = file.readAsStringSync();
      expect(src, contains('setBass'));
      expect(src, contains('setEq'));
    });

    test('native side listens on channel arena_audio/effects', () {
      const ktPath =
          'android/app/src/main/kotlin/com/protournament/app/BassEqEffect.kt';
      const mainPath =
          'android/app/src/main/kotlin/com/protournament/app/MainActivity.kt';
      final ktSrc = File(ktPath).readAsStringSync();
      final mainSrc = File(mainPath).readAsStringSync();
      expect(
        ktSrc.contains('arena_audio/effects') ||
            mainSrc.contains('arena_audio/effects'),
        isTrue,
        reason: 'neither BassEqEffect.kt nor MainActivity.kt references '
            'channel arena_audio/effects',
      );
    });
  });
}
