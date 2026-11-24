// INDEPENDENT VERIFIER TESTS — Arena Hub #10 Audio, Group 3 (DSP reverb).
//
// Written from the SPEC ONLY, without looking at the implementer's code:
//   * Dart class `ReverbEffect` in lib/services/audio_effects_reverb.dart
//   * `setAmount(double 0.0-1.0)` / `dispose()`
//   * platform channel `arena_audio/effects`, method `setReverb`
//   * native file android/.../ReverbEffect.kt implementing setReverb
//     (platform AudioEffect APIs preferred, custom DSP acceptable)
// These tests are EXPECTED to fail to compile until the implementation
// lands. Do NOT weaken them to make them pass without the implementation.
//
// The contract does not pin down the return types of setAmount/dispose
// (Future<void> vs void) or the exact argument encoding of setReverb, so:
//   * static shape is checked with void tear-offs, which accept either
//     return type;
//   * behaviour calls go through `dynamic` so awaiting works either way;
//   * the setReverb argument is accepted if it carries the amount as a
//     double, a map value, or a list element.

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/services/audio_effects_reverb.dart';

const String _channelName = 'arena_audio/effects';
const String _methodName = 'setReverb';

/// Returns true when [arguments] carries [amount] in any reasonable encoding.
bool _carriesAmount(Object? arguments, double amount) {
  if (arguments is double) return arguments == amount;
  if (arguments is num) return arguments.toDouble() == amount;
  if (arguments is Map) {
    return arguments.values.any((v) => v is num && v.toDouble() == amount);
  }
  if (arguments is List) {
    return arguments.any((v) => v is num && v.toDouble() == amount);
  }
  return false;
}

/// Calls setAmount(amount) and waits until the platform call lands
/// (or [timeout] elapses), returning the recorded method calls.
Future<List<MethodCall>> _setAmountAndCollect(
  ReverbEffect effect,
  double amount, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final List<MethodCall> calls = <MethodCall>[];
  final MethodChannel channel = const MethodChannel(_channelName);
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (MethodCall call) async {
    calls.add(call);
    return null;
  });
  addTearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  // Dynamic invocation: works whether setAmount returns Future<void> or void.
  await (effect as dynamic).setAmount(amount);

  // Flush any unawaited async work the implementation may do internally.
  final DateTime deadline = DateTime.now().add(timeout);
  while (calls.isEmpty && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  return calls;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ReverbEffect contract', () {
    testWidgets('class exists with contracted static shape',
        (WidgetTester tester) async {
      final ReverbEffect effect = ReverbEffect();
      // Void tear-offs accept either a void or a Future<void> return type,
      // but fail to compile if the parameter shape differs.
      final void Function(double) setAmount = effect.setAmount;
      final void Function() disposeFn = effect.dispose;
      expect(setAmount, isNotNull);
      expect(disposeFn, isNotNull);
      await (effect as dynamic).dispose();
    });

    testWidgets('setAmount(0.5) invokes setReverb on arena_audio/effects',
        (WidgetTester tester) async {
      final ReverbEffect effect = ReverbEffect();
      final List<MethodCall> calls =
          await _setAmountAndCollect(effect, 0.5);
      expect(calls, hasLength(1),
          reason: 'one setAmount must produce exactly one platform call');
      expect(calls.first.method, _methodName,
          reason: 'method name must be exactly "setReverb"');
      expect(_carriesAmount(calls.first.arguments, 0.5), isTrue,
          reason:
              'setReverb arguments must carry the amount 0.5; got ${calls.first.arguments}');
      await (effect as dynamic).dispose();
    });

    testWidgets('setAmount(0.0) forwards the lower boundary',
        (WidgetTester tester) async {
      final ReverbEffect effect = ReverbEffect();
      final List<MethodCall> calls =
          await _setAmountAndCollect(effect, 0.0);
      expect(calls, hasLength(1));
      expect(calls.first.method, _methodName);
      expect(_carriesAmount(calls.first.arguments, 0.0), isTrue,
          reason:
              'setReverb arguments must carry the amount 0.0; got ${calls.first.arguments}');
      await (effect as dynamic).dispose();
    });

    testWidgets('setAmount(1.0) forwards the upper boundary',
        (WidgetTester tester) async {
      final ReverbEffect effect = ReverbEffect();
      final List<MethodCall> calls =
          await _setAmountAndCollect(effect, 1.0);
      expect(calls, hasLength(1));
      expect(calls.first.method, _methodName);
      expect(_carriesAmount(calls.first.arguments, 1.0), isTrue,
          reason:
              'setReverb arguments must carry the amount 1.0; got ${calls.first.arguments}');
      await (effect as dynamic).dispose();
    });

    testWidgets('each setAmount produces exactly one platform call',
        (WidgetTester tester) async {
      final ReverbEffect effect = ReverbEffect();
      final List<MethodCall> calls = <MethodCall>[];
      final MethodChannel channel = const MethodChannel(_channelName);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
        calls.add(call);
        return null;
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });
      await (effect as dynamic).setAmount(0.25);
      await (effect as dynamic).setAmount(0.75);
      // Harness fix (coordinator 2026-11-22): the bare Future.delayed hung
      // under testWidgets' fake async (timer never fires without a pump);
      // tester.pump advances fake async the same 100 ms. Assertions unchanged.
      await tester.pump(const Duration(milliseconds: 100));
      expect(calls, hasLength(2),
          reason: 'two setAmount calls must produce exactly two platform calls');
      expect(calls.map((c) => c.method).toSet(), {_methodName});
      expect(_carriesAmount(calls[0].arguments, 0.25), isTrue);
      expect(_carriesAmount(calls[1].arguments, 0.75), isTrue);
      await (effect as dynamic).dispose();
    });

    testWidgets('dispose completes without throwing',
        (WidgetTester tester) async {
      final ReverbEffect effect = ReverbEffect();
      await (effect as dynamic).dispose();
    });
  });

  group('native ReverbEffect.kt', () {
    test('native file exists under android/ and implements setReverb', () {
      final List<File> matches = Directory('android')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('ReverbEffect.kt'))
          .toList();
      expect(matches, isNotEmpty,
          reason: 'android/.../ReverbEffect.kt must exist');
      expect(matches, hasLength(1),
          reason: 'exactly one ReverbEffect.kt expected; found '
              '${matches.map((f) => f.path).join(', ')}');
      final String source = matches.first.readAsStringSync();
      expect(source.contains('setReverb'), isTrue,
          reason: 'ReverbEffect.kt must implement setReverb');

      // Approach detection (reported, not pass/fail: platform APIs are
      // preferred, custom DSP is acceptable per the spec).
      final bool usesPlatformAudioFx =
          source.contains('android.media.audiofx') ||
              source.contains('PresetReverb') ||
              source.contains('EnvironmentalReverb') ||
              source.contains('AudioEffect');
      final bool looksCustomDsp = source.contains('comb') ||
          source.contains('allpass') ||
          source.contains('Allpass') ||
          source.contains('feedback') ||
          source.contains('delayLine') ||
          source.contains('Schroeder');
      final String approach = usesPlatformAudioFx
          ? 'platform AudioEffect APIs'
          : (looksCustomDsp ? 'custom DSP' : 'unknown');
      // ignore: avoid_print
      print('NATIVE-APPROACH: $approach (${matches.first.path})');
    });
  });
}
