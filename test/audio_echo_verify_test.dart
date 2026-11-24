// INDEPENDENT VERIFIER TESTS — Group 4: echo/delay DSP for the music player.
// Written from the contract spec ONLY, without seeing the implementer's code:
//   * Dart: class `EchoDelayEffect` in lib/services/audio_effects_echo.dart
//     with setEcho(double), setDelayMs(double), dispose().
//   * Platform channel `arena_audio/effects`, methods `setEcho` and `setDelay`.
//   * Native: android/.../EchoDelayEffect.kt with a custom delay-line DSP
//     (Android has no built-in echo effect for playback).
// These tests FAIL until the implementation lands — that is expected.
// They must NOT be weakened to pass without the implementation.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/services/audio_effects_echo.dart';

/// The channel argument may be a bare number, a map, or a list — the contract
/// pins the method name and the value, not the envelope. Accept any envelope
/// that actually carries the value.
bool _carriesValue(Object? args, num value) {
  if (args is num) return args == value;
  if (args is Map) return args.values.any((v) => v is num && v == value);
  if (args is Iterable) return args.any((v) => v is num && v == value);
  return false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('arena_audio/effects');
  late List<MethodCall> calls;

  setUp(() {
    calls = <MethodCall>[];
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

  group('EchoDelayEffect contract (Dart side)', () {
    test('1. class exists and can be constructed', () {
      final effect = EchoDelayEffect();
      expect(effect, isNotNull);
      effect.dispose();
    });

    test('2. setEcho(0.5) invokes setEcho on arena_audio/effects carrying 0.5',
        () async {
      final effect = EchoDelayEffect();
      await effect.setEcho(0.5);
      expect(calls, hasLength(1),
          reason: 'setEcho must make exactly one platform call');
      expect(calls.single.method, 'setEcho');
      expect(_carriesValue(calls.single.arguments, 0.5), isTrue,
          reason:
              'setEcho argument must carry the level 0.5 (got ${calls.single.arguments})');
      effect.dispose();
    });

    test(
        '3. setDelayMs(250) invokes setDelay on arena_audio/effects carrying 250',
        () async {
      final effect = EchoDelayEffect();
      await effect.setDelayMs(250);
      expect(calls, hasLength(1),
          reason: 'setDelayMs must make exactly one platform call');
      expect(calls.single.method, 'setDelay');
      expect(_carriesValue(calls.single.arguments, 250), isTrue,
          reason:
              'setDelay argument must carry the delay 250 ms (got ${calls.single.arguments})');
      effect.dispose();
    });

    test('4. boundary levels 0.0 and 1.0 pass through unchanged', () async {
      final effect = EchoDelayEffect();
      await effect.setEcho(0.0);
      await effect.setEcho(1.0);
      expect(calls, hasLength(2));
      expect(calls[0].method, 'setEcho');
      expect(_carriesValue(calls[0].arguments, 0.0), isTrue);
      expect(calls[1].method, 'setEcho');
      expect(_carriesValue(calls[1].arguments, 1.0), isTrue);
      effect.dispose();
    });

    test('5. sequential setEcho then setDelayMs arrive in order', () async {
      final effect = EchoDelayEffect();
      await effect.setEcho(0.3);
      await effect.setDelayMs(120);
      expect(
          calls.map((c) => c.method).toList(), ['setEcho', 'setDelay']);
      effect.dispose();
    });

    test('6. dispose() is callable without error', () {
      final effect = EchoDelayEffect();
      // Closure form: works whether dispose() returns void or Future<void>.
      expect(() => effect.dispose(), returnsNormally);
    });

    test('7. Dart source declares the contracted channel and method names',
        () {
      final source =
          File('lib/services/audio_effects_echo.dart').readAsStringSync();
      expect(source, contains('class EchoDelayEffect'));
      expect(source, contains('arena_audio/effects'),
          reason: 'channel name must be exactly arena_audio/effects');
      expect(source, contains("'setEcho'"),
          reason: 'Dart side must invoke method setEcho');
      expect(source, contains("'setDelay'"),
          reason: 'Dart side must invoke method setDelay');
      expect(source, contains('setEcho('));
      expect(source, contains('setDelayMs('));
    });
  });

  group('EchoDelayEffect native side (Android delay-line DSP)', () {
    File? findNativeFile() {
      final expected = File(
          'android/app/src/main/kotlin/com/protournament/app/EchoDelayEffect.kt');
      if (expected.existsSync()) return expected;
      // Fall back to a recursive search anywhere under android/.
      final found = Directory('android')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('EchoDelayEffect.kt'))
          .toList();
      return found.isEmpty ? null : found.first;
    }

    test('8. native EchoDelayEffect.kt exists under android/', () {
      expect(findNativeFile(), isNotNull,
          reason: 'android/.../EchoDelayEffect.kt is missing');
    });

    test('9. native file implements a real delay line, not a stub', () {
      final file = findNativeFile();
      expect(file, isNotNull,
          reason: 'cannot inspect DSP: EchoDelayEffect.kt missing');
      final src = file!.readAsStringSync();
      // (a) A delay buffer: an array holding past samples.
      expect(
          RegExp(r'(FloatArray|ShortArray|DoubleArray|IntArray|ByteArray)')
              .hasMatch(src),
          isTrue,
          reason:
              'no sample buffer array (FloatArray/ShortArray/...) — no delay line');
      expect(src.toLowerCase(), contains('delay'),
          reason: 'native file never mentions delay');
      // (b) Delay length derived from the sample rate (ms -> samples).
      expect(src, contains('sampleRate'),
          reason:
              'no sampleRate use — delay time cannot be converted to samples');
      // (c) Echo character: feedback and/or wet/dry mix.
      expect(
          RegExp(r'feedback|decay|wet|mix', caseSensitive: false).hasMatch(src),
          isTrue,
          reason: 'no feedback/decay/wet-mix — nothing makes it an echo');
      // (d) Circular read/write position into the delay line.
      expect(
          RegExp(r'writeIndex|readIndex|writePos|readPos|writePtr|readPtr')
              .hasMatch(src),
          isTrue,
          reason: 'no circular read/write index into the delay line');
      // (e) The native side registers the contracted channel and methods.
      expect(src, contains('arena_audio/effects'),
          reason: 'native side never registers channel arena_audio/effects');
      expect(src, contains('"setEcho"'),
          reason: 'native side never handles method setEcho');
      expect(src, contains('"setDelay"'),
          reason: 'native side never handles method setDelay');
    });
  });
}
