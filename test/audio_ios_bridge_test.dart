// audio_ios_bridge_test.dart
//
// ARENA HUB #10 AUDIO — Group 6 (iOS native audio path).
//
// Dart-side contract tests for the `arena_audio/effects` platform channel.
// They prove, via a mocked MethodChannel, that the Dart side invokes the
// SAME channel name and the SAME five methods with the SAME argument shapes
// that the iOS Swift bridge (ios/Runner/AudioEffectsPlugin.swift) — and the
// Android bridge (Groups 3/4/5) — implement:
//
//   Channel:  arena_audio/effects
//   setReverb  {"amount": double 0.0-1.0}
//   setEcho    {"amount": double 0.0-1.0}
//   setDelay   {"delayMs": double, milliseconds}
//   setBass    {"amount": double 0.0-1.0}
//   setEq      {"band": int 0-4, "gain": double dB}
//
// NOTE ON SCOPE: the real Dart callers (G3 ReverbEffect, G4 EchoDelayEffect,
// G5 BassEqEffect) live in other groups' copies and are NOT in this copy, so
// the wrapper below is a test-local mirror of their API surface
// (setAmount / setEcho / setDelayMs / setBass / setEqBand, per
// COORDINATION.md). These tests pin the iOS-side contract in executable
// form; the coordinator must confirm the G3/G4/G5 services send these exact
// shapes at merge time. The Swift side additionally accepts bare numbers
// (and [band, gain] lists for setEq) as a fallback, but the map form above
// is canonical.
//
// What these tests do NOT prove: anything about the Swift code itself. This
// Linux VM has no Xcode — iOS needs a Mac build to verify. Do not claim iOS
// audio works until then.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Test-local mirror of the Dart audio-effects callers (G3/G4/G5 API surface).
/// Sends the canonical `arena_audio/effects` contract to the native side.
class IosAudioEffectsBridge {
  static const MethodChannel channel =
      MethodChannel('arena_audio/effects');

  Future<void> setReverb(double amount) =>
      channel.invokeMethod('setReverb', <String, dynamic>{'amount': amount});

  Future<void> setEcho(double amount) =>
      channel.invokeMethod('setEcho', <String, dynamic>{'amount': amount});

  Future<void> setDelayMs(double delayMs) => channel
      .invokeMethod('setDelay', <String, dynamic>{'delayMs': delayMs});

  Future<void> setBass(double amount) =>
      channel.invokeMethod('setBass', <String, dynamic>{'amount': amount});

  Future<void> setEqBand(int band, double gain) =>
      channel.invokeMethod('setEq', <String, dynamic>{
        'band': band,
        'gain': gain,
      });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel('arena_audio/effects');
  final List<MethodCall> calls = <MethodCall>[];
  late IosAudioEffectsBridge bridge;

  setUp(() {
    calls.clear();
    bridge = IosAudioEffectsBridge();
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

  test('channel name is arena_audio/effects', () {
    expect(IosAudioEffectsBridge.channel.name, 'arena_audio/effects');
  });

  test('setReverb invokes setReverb with amount map', () async {
    await bridge.setReverb(0.6);
    expect(calls, hasLength(1));
    expect(calls.single.method, 'setReverb');
    expect(calls.single.arguments, <String, dynamic>{'amount': 0.6});
  });

  test('setEcho invokes setEcho with amount map', () async {
    await bridge.setEcho(0.4);
    expect(calls, hasLength(1));
    expect(calls.single.method, 'setEcho');
    expect(calls.single.arguments, <String, dynamic>{'amount': 0.4});
  });

  test('setDelayMs invokes setDelay with delayMs map', () async {
    await bridge.setDelayMs(250);
    expect(calls, hasLength(1));
    expect(calls.single.method, 'setDelay');
    expect(calls.single.arguments, <String, dynamic>{'delayMs': 250.0});
  });

  test('setBass invokes setBass with amount map', () async {
    await bridge.setBass(0.8);
    expect(calls, hasLength(1));
    expect(calls.single.method, 'setBass');
    expect(calls.single.arguments, <String, dynamic>{'amount': 0.8});
  });

  test('setEqBand invokes setEq with band and gain map', () async {
    await bridge.setEqBand(2, 6.0);
    expect(calls, hasLength(1));
    expect(calls.single.method, 'setEq');
    expect(
      calls.single.arguments,
      <String, dynamic>{'band': 2, 'gain': 6.0},
    );
  });

  test('all five methods fire in order with the contract shapes', () async {
    await bridge.setReverb(0.5);
    await bridge.setEcho(0.3);
    await bridge.setDelayMs(180);
    await bridge.setBass(0.7);
    await bridge.setEqBand(0, 9.0);

    expect(
      calls.map((MethodCall c) => c.method).toList(),
      <String>['setReverb', 'setEcho', 'setDelay', 'setBass', 'setEq'],
    );
    expect(calls[0].arguments, <String, dynamic>{'amount': 0.5});
    expect(calls[1].arguments, <String, dynamic>{'amount': 0.3});
    expect(calls[2].arguments, <String, dynamic>{'delayMs': 180.0});
    expect(calls[3].arguments, <String, dynamic>{'amount': 0.7});
    expect(calls[4].arguments, <String, dynamic>{'band': 0, 'gain': 9.0});
  });

  test('edge amounts 0.0 and 1.0 pass through unchanged', () async {
    await bridge.setReverb(0.0);
    await bridge.setReverb(1.0);
    await bridge.setDelayMs(0);
    expect(calls[0].arguments, <String, dynamic>{'amount': 0.0});
    expect(calls[1].arguments, <String, dynamic>{'amount': 1.0});
    expect(calls[2].arguments, <String, dynamic>{'delayMs': 0.0});
  });

  test('setEqBand accepts the full 0-4 band range', () async {
    await bridge.setEqBand(0, 12.0);
    await bridge.setEqBand(4, -6.0);
    expect(calls[0].arguments, <String, dynamic>{'band': 0, 'gain': 12.0});
    expect(calls[1].arguments, <String, dynamic>{'band': 4, 'gain': -6.0});
  });

  test('native error propagates as PlatformException', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      throw PlatformException(
        code: 'INVALID_ARGUMENT',
        message: 'setEq band out of range: 9 (valid 0-4)',
      );
    });
    expect(
      () => bridge.setEqBand(9, 6.0),
      throwsA(
        isA<PlatformException>().having(
          (PlatformException e) => e.code,
          'code',
          'INVALID_ARGUMENT',
        ),
      ),
    );
  });
}
