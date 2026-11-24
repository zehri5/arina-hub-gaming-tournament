import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/services/audio_effects_reverb.dart';

/// GROUP 3 — Dart-side tests for the reverb effect.
///
/// The MethodChannel is mocked: these tests prove the Dart contract
/// (channel name, method name, argument shape, clamping, dedupe,
/// dispose semantics). The native Kotlin side (ReverbEffect.kt) cannot
/// be unit-tested on this VM — it needs an Android device/emulator.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('arena_audio/effects');
  final calls = <MethodCall>[];
  var throwNext = false;

  setUp(() {
    calls.clear();
    throwNext = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      calls.add(call);
      if (throwNext) {
        throw PlatformException(
          code: 'reverb_unavailable',
          message: 'EnvironmentalReverb could not be created',
        );
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  double recordedAmount(int index) =>
      (calls[index].arguments as Map)['amount'] as double;

  group('setAmount', () {
    test('sends setReverb with the amount on arena_audio/effects',
        () async {
      final effect = ReverbEffect();
      await effect.setAmount(0.5);
      expect(calls, hasLength(1));
      expect(calls.single.method, 'setReverb');
      expect(recordedAmount(0), 0.5);
      expect(effect.lastAmount, 0.5);
    });

    test('clamps values outside 0.0-1.0', () async {
      final effect = ReverbEffect();
      await effect.setAmount(-3.0);
      await effect.setAmount(2.5);
      expect(calls, hasLength(2));
      expect(recordedAmount(0), 0.0);
      expect(recordedAmount(1), 1.0);
    });

    test('treats NaN as 0.0 (dry)', () async {
      final effect = ReverbEffect();
      await effect.setAmount(double.nan);
      expect(calls, hasLength(1));
      expect(recordedAmount(0), 0.0);
      expect(effect.lastAmount, 0.0);
    });

    test('skips the channel call when the amount is unchanged', () async {
      final effect = ReverbEffect();
      await effect.setAmount(0.7);
      await effect.setAmount(0.7);
      await effect.setAmount(0.7000001);
      expect(calls, hasLength(2));
      expect(recordedAmount(1), 0.7000001);
    });

    test('sends 0.0 to disable after a non-zero amount', () async {
      final effect = ReverbEffect();
      await effect.setAmount(0.8);
      await effect.setAmount(0.0);
      expect(calls, hasLength(2));
      expect(recordedAmount(1), 0.0);
      expect(effect.lastAmount, 0.0);
    });

    test('propagates a native PlatformException and allows a retry',
        () async {
      final effect = ReverbEffect();
      throwNext = true;
      await expectLater(
        effect.setAmount(0.5),
        throwsA(isA<PlatformException>()),
      );
      // Failed call did not stick: the retry goes through.
      expect(effect.lastAmount, isNull);
      throwNext = false;
      await effect.setAmount(0.5);
      expect(calls, hasLength(2));
      expect(effect.lastAmount, 0.5);
    });
  });

  group('dispose', () {
    test('sends setReverb 0.0 when an effect is active', () async {
      final effect = ReverbEffect();
      await effect.setAmount(0.6);
      await effect.dispose();
      expect(calls, hasLength(2));
      expect(recordedAmount(1), 0.0);
      expect(effect.isDisposed, isTrue);
      expect(effect.lastAmount, isNull);
    });

    test('sends nothing when no effect is active', () async {
      final effect = ReverbEffect();
      await effect.dispose();
      expect(calls, isEmpty);

      final dry = ReverbEffect();
      await dry.setAmount(0.0);
      await dry.dispose();
      expect(calls, hasLength(1));
      expect(recordedAmount(0), 0.0);
    });

    test('is idempotent', () async {
      final effect = ReverbEffect();
      await effect.setAmount(0.4);
      await effect.dispose();
      await effect.dispose();
      expect(calls, hasLength(2));
    });

    test('swallows native errors', () async {
      final effect = ReverbEffect();
      await effect.setAmount(0.4);
      throwNext = true;
      await effect.dispose();
      expect(effect.isDisposed, isTrue);
    });

    test('setAmount after dispose throws StateError', () async {
      final effect = ReverbEffect();
      await effect.dispose();
      await expectLater(
        effect.setAmount(0.5),
        throwsA(isA<StateError>()),
      );
      expect(calls, isEmpty);
    });
  });
}
