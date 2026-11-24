// ARENA HUB #10 AUDIO — platform-channel contract tests (Group 10).
//
// These tests pin the shared channel contract WITHOUT importing any impl
// code, so they run (and pass) right now, before any group lands:
//   * channel name is exactly `arena_audio/effects`;
//   * the five method names are exactly setReverb / setEcho / setDelay /
//     setBass / setEq;
//   * every method carries the canonical argument encoding defined in
//     audio_test_helpers.dart (bare doubles; setEq as {band, gain}).
//
// The golden sender in the helpers file is the reference for what
// conforming impl code must emit. If a group's code sends a different
// method name or argument shape, the impl-conformance tests in
// audio_impl_contract_test.dart fail against the same assertions here.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audio_test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeAudioEffectsChannel fake;

  setUp(() {
    fake = FakeAudioEffectsChannel();
  });

  tearDown(() {
    fake.dispose();
  });

  group('channel identity', () {
    test('channel name is exactly arena_audio/effects', () {
      expect(AudioEffectsContract.channelName, 'arena_audio/effects');
      expect(AudioEffectsContract.channel.name, 'arena_audio/effects');
    });

    test('the five method names are exactly as contracted', () {
      expect(
        AudioEffectsContract.allMethods,
        const <String>{
          'setReverb',
          'setEcho',
          'setDelay',
          'setBass',
          'setEq',
        },
      );
    });
  });

  group('canonical argument encoding (golden sender)', () {
    test('setReverb sends an {amount} map 0..1', () async {
      await GoldenAudioEffectsSender().sendReverb(0.5);
      expect(fake.calls, hasLength(1));
      assertConformingCall(fake.calls.single, 'setReverb');
      expect(
        fake.calls.single.arguments,
        const <String, Object>{'amount': 0.5},
      );
    });

    test('setEcho sends an {amount} map 0..1', () async {
      await GoldenAudioEffectsSender().sendEcho(0.3);
      expect(fake.calls, hasLength(1));
      assertConformingCall(fake.calls.single, 'setEcho');
      expect(
        fake.calls.single.arguments,
        const <String, Object>{'amount': 0.3},
      );
    });

    test('setDelay sends an {ms} map (ms)', () async {
      await GoldenAudioEffectsSender().sendDelay(250.0);
      expect(fake.calls, hasLength(1));
      assertConformingCall(fake.calls.single, 'setDelay');
      expect(
        fake.calls.single.arguments,
        const <String, Object>{'ms': 250.0},
      );
    });

    test('setBass sends an {amount} map 0..1', () async {
      await GoldenAudioEffectsSender().sendBass(0.7);
      expect(fake.calls, hasLength(1));
      assertConformingCall(fake.calls.single, 'setBass');
      expect(
        fake.calls.single.arguments,
        const <String, Object>{'amount': 0.7},
      );
    });

    test('setEq sends exactly {band, gainDb}', () async {
      await GoldenAudioEffectsSender().sendEq(2, 3.0);
      expect(fake.calls, hasLength(1));
      assertConformingCall(fake.calls.single, 'setEq');
      expect(
        fake.calls.single.arguments,
        const <String, Object>{'band': 2, 'gainDb': 3.0},
      );
    });

    test('boundary values are encodable', () async {
      final GoldenAudioEffectsSender sender = GoldenAudioEffectsSender();
      await sender.sendReverb(0.0);
      await sender.sendReverb(1.0);
      await sender.sendDelay(0.0);
      await sender.sendDelay(2000.0);
      await sender.sendEq(0, -15.0);
      await sender.sendEq(4, 15.0);
      expect(fake.calls, hasLength(6));
      for (final MethodCall call in fake.calls) {
        assertConformingCall(call, call.method);
      }
    });

    test('closed method set: the golden sender emits only the five',
        () async {
      final GoldenAudioEffectsSender sender = GoldenAudioEffectsSender();
      await sender.sendReverb(0.5);
      await sender.sendEcho(0.5);
      await sender.sendDelay(100.0);
      await sender.sendBass(0.5);
      await sender.sendEq(1, 0.0);
      expect(fake.calls, hasLength(5));
      assertOnlyKnownMethods(fake.calls);
    });

    test('calls arrive in send order', () async {
      final GoldenAudioEffectsSender sender = GoldenAudioEffectsSender();
      await sender.sendBass(0.1);
      await sender.sendReverb(0.2);
      await sender.sendEq(3, -6.0);
      expect(
        fake.calls.map((MethodCall c) => c.method).toList(),
        <String>['setBass', 'setReverb', 'setEq'],
      );
    });
  });

  group('error propagation', () {
    test('a PlatformException from native surfaces to the caller',
        () async {
      fake.error = PlatformException(
        code: 'EFFECT_UNAVAILABLE',
        message: 'native effect missing',
      );
      await expectLater(
        GoldenAudioEffectsSender().sendReverb(0.5),
        throwsA(isA<PlatformException>()),
      );
    });

    test('the call is still recorded when native throws', () async {
      fake.error = PlatformException(code: 'EFFECT_FAILED');
      try {
        await GoldenAudioEffectsSender().sendBass(0.5);
      } on PlatformException {
        // Expected — the point is the call was still recorded.
      }
      expect(fake.callsNamed('setBass'), hasLength(1));
    });
  });
}
