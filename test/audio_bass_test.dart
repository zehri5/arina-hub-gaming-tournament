// Group 5 (ARENA HUB #10 AUDIO) — BassEqEffect tests.
//
// Dart-side only: the `arena_audio/effects` MethodChannel is mocked, so
// no Android device or native AudioEffect engine is needed. The native
// Kotlin (BassEqEffect.kt) cannot be unit-tested on this VM — no Android
// device/emulator and no APK build here.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/services/audio_effects_bass.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel('arena_audio/effects');
  final List<MethodCall> calls = <MethodCall>[];
  PlatformException? errorToThrow;

  setUp(() {
    calls.clear();
    errorToThrow = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      calls.add(call);
      final PlatformException? error = errorToThrow;
      if (error != null) {
        throw error;
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('setBass sends amount on arena_audio/effects', () async {
    final BassEqEffect effect = BassEqEffect();
    await effect.setBass(0.5);
    expect(calls, hasLength(1));
    expect(calls.single.method, 'setBass');
    expect(calls.single.arguments, <String, Object>{'amount': 0.5});
    await effect.dispose();
  });

  test('setBass clamps out-of-range amounts', () async {
    final BassEqEffect effect = BassEqEffect();
    await effect.setBass(1.8);
    await effect.setBass(-0.4);
    expect(
      calls.map((MethodCall c) => (c.arguments as Map)['amount']),
      <double>[1.0, 0.0],
    );
    await effect.dispose();
  });

  test('setEqBand sends band and gainDb', () async {
    final BassEqEffect effect = BassEqEffect();
    await effect.setEqBand(2, 6.0);
    expect(calls, hasLength(1));
    expect(calls.single.method, 'setEq');
    expect(calls.single.arguments, <String, Object>{'band': 2, 'gainDb': 6.0});
    await effect.dispose();
  });

  test('setEqBand clamps gain to +/-15 dB', () async {
    final BassEqEffect effect = BassEqEffect();
    await effect.setEqBand(0, 40.0);
    await effect.setEqBand(1, -40.0);
    expect(
      calls.map((MethodCall c) => (c.arguments as Map)['gainDb']),
      <double>[15.0, -15.0],
    );
    await effect.dispose();
  });

  test('setEqBand rejects a negative band without calling native', () async {
    final BassEqEffect effect = BassEqEffect();
    await expectLater(effect.setEqBand(-1, 3.0), throwsArgumentError);
    expect(calls, isEmpty);
    await effect.dispose();
  });

  test('dispose resets bass and touched bands to neutral', () async {
    final BassEqEffect effect = BassEqEffect();
    await effect.setBass(0.7);
    await effect.setEqBand(1, 4.0);
    await effect.setEqBand(3, -2.0);
    calls.clear();
    await effect.dispose();
    expect(
      calls.map((MethodCall c) => c.method),
      <String>['setBass', 'setEq', 'setEq'],
    );
    expect((calls[0].arguments as Map)['amount'], 0.0);
    expect((calls[1].arguments as Map)['gainDb'], 0.0);
    expect((calls[2].arguments as Map)['gainDb'], 0.0);
    expect(
      <int>{
        (calls[1].arguments as Map)['band'] as int,
        (calls[2].arguments as Map)['band'] as int,
      },
      <int>{1, 3},
    );
  });

  test('dispose is idempotent', () async {
    final BassEqEffect effect = BassEqEffect();
    await effect.setBass(0.5);
    await effect.dispose();
    calls.clear();
    await effect.dispose();
    expect(calls, isEmpty);
  });

  test('calls after dispose throw StateError', () async {
    final BassEqEffect effect = BassEqEffect();
    await effect.dispose();
    await expectLater(effect.setBass(0.5), throwsStateError);
    await expectLater(effect.setEqBand(0, 1.0), throwsStateError);
  });

  test('native PlatformException propagates from setBass', () async {
    errorToThrow = PlatformException(code: 'effect_unavailable');
    final BassEqEffect effect = BassEqEffect();
    await expectLater(effect.setBass(0.5), throwsA(isA<PlatformException>()));
    // dispose's best-effort reset must swallow the same error.
    await effect.dispose();
  });
}
