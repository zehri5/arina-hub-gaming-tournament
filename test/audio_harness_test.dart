// ARENA HUB #10 AUDIO — harness self-tests + presence gates (Group 10).
//
// Two parts:
//  1. HARNESS SELF-TESTS — prove the shared harness in
//     audio_test_helpers.dart works, including NEGATIVE tests that prove
//     the conformance assertions actually catch violations (a check that
//     cannot fail is worthless). These pass right now.
//  2. PRESENCE GATES — source pins that FAIL until each group's contract
//     file lands in this tree. They are the machine-readable "is the
//     code here yet?" signal for the coordinator. A failing presence
//     gate means BLOCKED ON MISSING CODE, not a broken test.
//     (Source-pinning pattern copied from v2017_voice_toggle_test.dart:
//     read the file, strip full-line comments, assert the API surface.)

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audio_test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('harness self-tests (FakeAudioEffectsChannel)', () {
    late FakeAudioEffectsChannel fake;

    setUp(() {
      fake = FakeAudioEffectsChannel();
    });

    tearDown(() {
      fake.dispose();
    });

    test('records calls in order with method + arguments', () async {
      final GoldenAudioEffectsSender sender = GoldenAudioEffectsSender();
      await sender.sendReverb(0.5);
      await sender.sendEcho(0.25);
      await sender.sendBass(0.75);
      expect(
        fake.calls.map((MethodCall c) => c.method).toList(),
        <String>['setReverb', 'setEcho', 'setBass'],
      );
      expect(
        fake.calls[1].arguments,
        const <String, Object>{'amount': 0.25},
      );
    });

    test('a scripted reply is returned to the caller', () async {
      fake.reply = true;
      final bool? result = await AudioEffectsContract.channel
          .invokeMethod<bool>('setReverb', 0.5);
      expect(result, isTrue);
    });

    test('an injected error is thrown to the caller', () async {
      fake.error = PlatformException(code: 'NATIVE_DOWN');
      await expectLater(
        AudioEffectsContract.channel.invokeMethod<void>('setEcho', 0.5),
        throwsA(isA<PlatformException>()),
      );
    });

    test('callsNamed filters by method', () async {
      final GoldenAudioEffectsSender sender = GoldenAudioEffectsSender();
      await sender.sendReverb(0.1);
      await sender.sendReverb(0.2);
      await sender.sendBass(0.3);
      expect(fake.callsNamed('setReverb'), hasLength(2));
      expect(fake.callsNamed('setBass'), hasLength(1));
      expect(fake.callsNamed('setDelay'), isEmpty);
    });

    test('dispose removes the handler (later calls miss the plugin)',
        () async {
      fake.dispose();
      await expectLater(
        AudioEffectsContract.channel
            .invokeMethod<void>('setReverb', 0.5),
        throwsA(isA<MissingPluginException>()),
      );
      // tearDown's dispose is still safe: setting a null handler twice
      // is harmless.
    });
  });

  group('harness self-tests (conformance assertions have teeth)', () {
    test('assertConformingCall accepts a conforming call', () {
      assertConformingCall(
        const MethodCall(
          'setReverb',
          <String, Object>{'amount': 0.5},
        ),
        'setReverb',
      );
      assertConformingCall(
        const MethodCall(
          'setEq',
          <String, Object>{'band': 2, 'gainDb': 3.0},
        ),
        'setEq',
      );
    });

    test('assertConformingCall rejects a wrong method name', () {
      expect(
        () => assertConformingCall(
          const MethodCall('setReverbX', 0.5),
          'setReverb',
        ),
        throwsA(isA<TestFailure>()),
      );
    });

    test('assertConformingCall rejects an out-of-range level', () {
      expect(
        () => assertConformingCall(
          const MethodCall(
            'setReverb',
            <String, Object>{'amount': 1.5},
          ),
          'setReverb',
        ),
        throwsA(isA<TestFailure>()),
      );
    });

    test('assertConformingCall rejects a setEq map missing gainDb', () {
      expect(
        () => assertConformingCall(
          const MethodCall('setEq', <String, Object>{'band': 2}),
          'setEq',
        ),
        throwsA(isA<TestFailure>()),
      );
    });

    test(
        'assertConformingCall rejects a negative EQ band and accepts band 9',
        () {
      // Landed behavior (G3): setEqBand forwards any non-negative band
      // raw — band 9 is forwarded, not rejected. Only negative bands
      // throw (ArgumentError in the impl).
      expect(
        () => assertConformingCall(
          const MethodCall(
            'setEq',
            <String, Object>{'band': -1, 'gainDb': 0.0},
          ),
          'setEq',
        ),
        throwsA(isA<TestFailure>()),
      );
      assertConformingCall(
        const MethodCall(
          'setEq',
          <String, Object>{'band': 9, 'gainDb': 0.0},
        ),
        'setEq',
      );
    });

    test('assertConformingCall rejects a setReverb map missing amount', () {
      expect(
        () => assertConformingCall(
          const MethodCall(
            'setReverb',
            <String, Object>{'level': 0.5},
          ),
          'setReverb',
        ),
        throwsA(isA<TestFailure>()),
      );
    });

    test('assertConformingCall rejects a setEq gainDb that is an int', () {
      expect(
        () => assertConformingCall(
          const MethodCall(
            'setEq',
            <String, Object>{'band': 2, 'gainDb': 3},
          ),
          'setEq',
        ),
        throwsA(isA<TestFailure>()),
      );
    });

    test('assertConformingCall rejects a setDelay carrying a string', () {
      expect(
        () => assertConformingCall(
          const MethodCall('setDelay', '250'),
          'setDelay',
        ),
        throwsA(isA<TestFailure>()),
      );
    });

    test('assertConformingCall rejects a setEq map with an extra key',
        () {
      expect(
        () => assertConformingCall(
          const MethodCall(
            'setEq',
            <String, Object>{'band': 2, 'gain': 3.0, 'q': 1.0},
          ),
          'setEq',
        ),
        throwsA(isA<TestFailure>()),
      );
    });

    test('assertOnlyKnownMethods rejects an unknown method', () {
      expect(
        () => assertOnlyKnownMethods(
          const <MethodCall>[MethodCall('setFlanger', 0.5)],
        ),
        throwsA(isA<TestFailure>()),
      );
    });
  });

  group('harness self-tests (source helpers)', () {
    test('findProjectRoot locates this project', () {
      final String pubspec = requireProjectFile('pubspec.yaml');
      expect(pubspec, contains('name: protournament_user'));
    });

    test('codeOnly strips full-line comments', () {
      const String src = '// setReverb is mentioned here\n'
          'final x = 1; // trailing comment stays\n'
          '  // indented comment\n'
          'call(setReverb);';
      final String code = codeOnly(src);
      expect(code, contains('call(setReverb);'));
      expect(
        code.split('\n').where((String l) => l.contains('mentioned')),
        isEmpty,
      );
    });

    test('requireProjectFile fails loudly on a missing file', () {
      expect(
        () => requireProjectFile('lib/does_not_exist_g10_probe.dart'),
        throwsA(isA<TestFailure>()),
      );
    });

    test('projectTreeContains finds known text, misses nonsense', () {
      expect(projectTreeContains('lib', 'protournament_user'), isTrue);
      expect(projectTreeContains('lib', 'zz_no_such_string_zz'), isFalse);
      expect(projectTreeContains('no_such_dir_xyz', 'anything'), isFalse);
    });
  });

  // ------------------------------------------------------------------
  // PRESENCE GATES — every test in this group FAILS until the named
  // group's code lands. That is the expected state before the merge.
  // ------------------------------------------------------------------
  group('presence gates — FAIL until the group code lands', () {
    test('G3: reverb effect file + API surface', () {
      final String src = codeOnly(
        requireProjectFile('lib/services/audio_effects_reverb.dart'),
      );
      expect(src, contains('class ReverbEffect'));
      expect(src, contains('setAmount('));
      expect(src, contains('dispose('));
    });

    test('G4: echo/delay effect file + API surface', () {
      final String src = codeOnly(
        requireProjectFile('lib/services/audio_effects_echo.dart'),
      );
      expect(src, contains('class EchoDelayEffect'));
      expect(src, contains('setEcho('));
      expect(src, contains('setDelayMs('));
      expect(src, contains('dispose('));
    });

    test('G5: bass/EQ effect file + API surface', () {
      final String src = codeOnly(
        requireProjectFile('lib/services/audio_effects_bass.dart'),
      );
      expect(src, contains('class BassEqEffect'));
      expect(src, contains('setBass('));
      expect(src, contains('setEqBand('));
      expect(src, contains('dispose('));
    });

    test('G1: Krisp mic processor file + API surface', () {
      final String src = codeOnly(
        requireProjectFile('lib/services/krisp_noise_filter.dart'),
      );
      expect(src, contains('class KrispMicProcessor'));
      expect(src, contains('initialize('));
      expect(src, contains('buildProcessor('));
      expect(src, contains('dispose('));
      expect(src, contains('TrackProcessor'));
    });

    test('G2: RNNoise mic processor file + API surface', () {
      final String src = codeOnly(
        requireProjectFile('lib/services/rnnoise_processor.dart'),
      );
      expect(src, contains('class RnnoiseMicProcessor'));
      expect(src, contains('initialize('));
      expect(src, contains('buildProcessor('));
      expect(src, contains('dispose('));
      expect(src, contains('TrackProcessor'));
    });

    test('G7: mic audio pipeline file + class', () {
      final String src = codeOnly(
        requireProjectFile('lib/services/mic_audio_pipeline.dart'),
      );
      expect(src, contains('class MicAudioPipeline'));
    });

    test('G7: pipeline wired into the voice service or room screen', () {
      final String voice = codeOnly(
        requireProjectFile('lib/services/livekit_voice_service.dart'),
      );
      final String room = codeOnly(
        requireProjectFile('lib/screens/room_screen.dart'),
      );
      expect(
        voice.contains('MicAudioPipeline') ||
            voice.contains('mic_audio_pipeline') ||
            room.contains('MicAudioPipeline') ||
            room.contains('mic_audio_pipeline'),
        isTrue,
        reason: 'neither livekit_voice_service.dart nor room_screen.dart '
            'references the MicAudioPipeline yet (G7 wiring not landed)',
      );
    });

    test('G8: playback effects file + API surface', () {
      final String src = codeOnly(
        requireProjectFile('lib/services/playback_effects.dart'),
      );
      expect(src, contains('class PlaybackEffects'));
      expect(src, contains('attachToPlayer('));
      expect(src, contains('applyPreset('));
      expect(src, contains('setEnabled('));
      expect(src, contains('dispose('));
      // Presets Off-Room-Hall: enum values are lowerCamelCase, string
      // literals are Capitalized — match either.
      expect(src.toLowerCase(), contains('room'));
      expect(src.toLowerCase(), contains('hall'));
    });

    test('G9: effects panel file + callbacks', () {
      final String src = codeOnly(
        requireProjectFile('lib/screens/audio_effects_panel.dart'),
      );
      expect(src, contains('class AudioEffectsPanel'));
      expect(src, contains('onReverb'));
      expect(src, contains('onEcho'));
      expect(src, contains('onDelayMs'));
      expect(src, contains('onBass'));
      expect(src, contains('onPreset'));
      expect(src, contains('onNoiseCancellation'));
    });

    test('Dart side references the arena_audio/effects channel', () {
      expect(
        projectTreeContains('lib', 'arena_audio/effects'),
        isTrue,
        reason: 'no Dart file under lib/ references the channel yet',
      );
    });

    test('Android native side references the channel', () {
      expect(
        projectTreeContains('android', 'arena_audio/effects'),
        isTrue,
        reason: 'no file under android/ references the channel yet',
      );
    });

    test('iOS native side references the channel', () {
      expect(
        projectTreeContains('ios', 'arena_audio/effects'),
        isTrue,
        reason: 'no file under ios/ references the channel yet',
      );
    });

    test('pubspec declares livekit_noise_filter (G1 dep)', () {
      final String pubspec = requireProjectFile('pubspec.yaml');
      expect(
        pubspec,
        contains('livekit_noise_filter'),
        reason: 'G1 has not added livekit_noise_filter to pubspec yet',
      );
    });
  });
}
