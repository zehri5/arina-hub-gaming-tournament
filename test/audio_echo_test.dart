// ARENA HUB #10 AUDIO — Group 4 tests: echo/delay Dart side.
//
// Covers the EchoDelayEffect contract against a mocked
// MethodChannel (channel arena_audio/effects, methods setEcho /
// setDelay): argument forwarding, clamping, getters, dispose, and
// error behaviour.
//
// NOTE: the native Kotlin delay line (EchoDelayEffect.kt) cannot be
// unit-tested on this VM (no Android emulator / Robolectric run
// here) — these tests pin the Dart half of the contract only, and
// the Kotlin is kept small and reviewable by design.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/services/audio_effects_echo.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel('arena_audio/effects');
  final List<MethodCall> calls = <MethodCall>[];
  late EchoDelayEffect effect;

  Future<void> setHandler(
    Future<dynamic> Function(MethodCall call)? handler,
  ) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, handler);
  }

  setUp(() async {
    calls.clear();
    effect = EchoDelayEffect();
    await setHandler((MethodCall call) async {
      calls.add(call);
      return null;
    });
  });

  tearDown(() async {
    await setHandler(null);
  });

  test('setEcho forwards amount on arena_audio/effects', () async {
    await effect.setEcho(0.5);

    expect(calls, hasLength(1));
    expect(calls.single.method, 'setEcho');
    expect(calls.single.arguments, <String, double>{'amount': 0.5});
    expect(effect.amount, 0.5);
  });

  test('setEcho clamps above 1.0 and below 0.0', () async {
    await effect.setEcho(2.5);
    await effect.setEcho(-0.25);

    expect(calls, hasLength(2));
    expect(calls[0].arguments, <String, double>{'amount': 1.0});
    expect(calls[1].arguments, <String, double>{'amount': 0.0});
    expect(effect.amount, 0.0);
  });

  test('setEcho turns NaN into 0.0', () async {
    await effect.setEcho(double.nan);

    expect(calls.single.arguments, <String, double>{'amount': 0.0});
    expect(effect.amount, 0.0);
  });

  test('setDelayMs forwards ms on arena_audio/effects', () async {
    await effect.setDelayMs(400);

    expect(calls, hasLength(1));
    expect(calls.single.method, 'setDelay');
    expect(calls.single.arguments, <String, double>{'ms': 400.0});
    expect(effect.delayMs, 400.0);
  });

  test('setDelayMs clamps to 0..maxDelayMs', () async {
    await effect.setDelayMs(5000);
    await effect.setDelayMs(-100);

    expect(calls, hasLength(2));
    expect(
      calls[0].arguments,
      <String, double>{'ms': EchoDelayEffect.maxDelayMs},
    );
    expect(calls[1].arguments, <String, double>{'ms': 0.0});
    expect(effect.delayMs, 0.0);
  });

  test('setDelayMs turns NaN into 0.0', () async {
    await effect.setDelayMs(double.nan);

    expect(calls.single.arguments, <String, double>{'ms': 0.0});
    expect(effect.delayMs, 0.0);
  });

  test('defaults are dry with the native default delay', () {
    expect(effect.amount, 0.0);
    expect(effect.delayMs, EchoDelayEffect.defaultDelayMs);
  });

  test('dispose resets echo to 0.0 and never throws', () async {
    await effect.setEcho(0.8);
    calls.clear();

    await setHandler((MethodCall call) async {
      calls.add(call);
      throw PlatformException(code: 'UNAVAILABLE');
    });

    // Must complete normally despite the platform error.
    await effect.dispose();

    expect(effect.amount, 0.0);
    expect(calls, hasLength(1));
    expect(calls.single.method, 'setEcho');
    expect(calls.single.arguments, <String, double>{'amount': 0.0});
  });

  test('setEcho propagates platform errors to the caller', () async {
    await setHandler((MethodCall call) async {
      throw PlatformException(code: 'UNAVAILABLE');
    });

    await expectLater(
      effect.setEcho(0.5),
      throwsA(isA<PlatformException>()),
    );
  });

  test('setDelayMs propagates platform errors to the caller', () async {
    await setHandler((MethodCall call) async {
      throw PlatformException(code: 'UNAVAILABLE');
    });

    await expectLater(
      effect.setDelayMs(300),
      throwsA(isA<PlatformException>()),
    );
  });
}
