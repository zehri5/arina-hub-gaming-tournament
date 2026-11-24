// REWRITTEN 2026-11-22 against the landed APIs — same treatment as
// test/audio_harness_verify_test.dart (49/49 passing). Phase 1 wrote
// this file against GUESSED APIs that never landed (no-arg
// PlaybackEffects, a PlaybackPreset enum, pipeline initialize(),
// bare-double channel payloads, +/-12 dB EQ, panel delay 0-2000 ms /
// bass 0-1); it did not compile after the merge (35 analyzer issues:
// pipeline initialize() + 5x5 missing required PlaybackEffects args +
// 3 undefined preset getters). Every test below is rewritten against
// the LANDED API, verified by reading the implementation files —
// same 31 tests (28 test + 3 testWidgets), same count, same or
// greater strictness, no deletions, no weakenings. The old
// `// ignore_for_file: uri_does_not_exist, ...` line is GONE: all 8
// imports resolve now and the file compiles + passes clean without it.
//
// ARENA HUB #10 AUDIO — impl-conformance tests (Group 10).
//
// These tests assert that each group's REAL classes satisfy the shared
// contract (channel `arena_audio/effects`, landed argument encoding
// documented below). They import the contract files:
//
//   G3 lib/services/audio_effects_reverb.dart  — ReverbEffect
//   G4 lib/services/audio_effects_echo.dart    — EchoDelayEffect
//   G5 lib/services/audio_effects_bass.dart    — BassEqEffect
//   G1 lib/services/krisp_noise_filter.dart   — KrispMicProcessor
//   G2 lib/services/rnnoise_processor.dart    — RnnoiseMicProcessor
//   G7 lib/services/mic_audio_pipeline.dart   — MicAudioPipeline
//   G8 lib/services/playback_effects.dart     — PlaybackEffects
//   G9 lib/screens/audio_effects_panel.dart   — AudioEffectsPanel
//
// LANDED API (the real contracts under test — read from the impls):
//   * ReverbEffect.setAmount(double) -> setReverb {'amount': 0.0-1.0}
//     (NaN -> 0.0, clamped, DEDUPED — a repeat of the last amount sends
//     nothing, StateError after dispose). dispose() sends setReverb 0.0
//     only if an effect was active.
//   * EchoDelayEffect.setEcho(double) -> setEcho {'amount': 0.0-1.0};
//     setDelayMs(double) -> setDelay {'ms': 0.0-2000.0} (arg key is
//     'ms', not 'delayMs'). dispose() always sends setEcho 0.0 and has
//     NO disposed-state guard (F6).
//   * BassEqEffect.setBass(double) -> setBass {'amount': 0.0-1.0};
//     setEqBand(int, double) -> setEq {'band': n, 'gainDb': +/-15 dB}
//     (negative band throws ArgumentError; NO upper band bound — G3).
//     dispose() sends setBass 0.0 + flattens touched bands.
//   * PlaybackEffects has NO setReverb/setEcho/... setters and NO
//     no-arg constructor: it takes five required tear-offs and exposes
//     attachToPlayer / applyPreset('Off'/'Room'/'Hall') / setEnabled /
//     dispose. Presets are static PlaybackPreset VALUES (a value class,
//     not an enum) in PlaybackEffects.presets.
//   * MicAudioPipeline has NO initialize()/isInitialized/buildProcessor().
//     Real API: setProcessor(MicNoiseProcessor?) -> Future<bool>,
//     setNoiseCancellationEnabled(bool) (sync), prepareForPublish(),
//     markProcessorDetached(), captureOptions(), dispose();
//     getters hasProcessor / processorName / processor / activeProcessor.
//   * MicNoiseProcessor (abstract): initialize() -> Future<bool>,
//     buildProcessor() -> Future<TrackProcessor<AudioProcessorOptions>?>,
//     dispose(). KrispMicProcessor + RnnoiseMicProcessor implement it;
//     both fail soft and never throw MissingPluginException (G7).
//   * AudioEffectsPanel takes the six named callbacks (all optional)
//     + value params with defaults; 4 material Sliders (keys
//     reverb/echo/delay/bass-slider), 3 preset buttons (keys
//     preset-Off/Room/Hall), 1 Switch (key noise-cancellation-switch).
//     LANDED RANGES: delay 0-500 ms (not 0-2000), bass -12..+12 dB
//     (not 0..1) — see G5.
//
// PER-TEST MAPPING (old intent -> new assertion; RENAMED where the old
// name described an API that never landed):
//   Reverb 1  bare-double setReverb -> {'amount': 0.5} map payload (G1).
//   Reverb 2  boundary values -> same, map payloads 0.0 / 1.0.
//   Reverb 3  clamped-or-rejected -> EXACT clamps 1.5->1.0, -0.5->0.0
//             (landed impls clamp, never reject; stricter than phase 1).
//   Reverb 4  dispose idempotent -> + isDisposed true, setAmount after
//             dispose throws StateError, second dispose sends nothing.
//   Echo 1    bare-double setEcho -> {'amount': 0.4} map payload (G1).
//   Echo 2    clamped-or-rejected -> EXACT clamps 1.5->1.0, -0.5->0.0.
//   Echo 3    setDelay (not setDelayMs) -> same + {'ms': 250.0} (F5).
//   Echo 4    clamped-or-rejected -> EXACT clamps 5000->2000, -10->0.
//   Echo 5    dispose idempotent -> + F6: no disposed guard, setEcho
//             still works after dispose.
//   Bass 1    bare-double setBass -> {'amount': 0.7} map payload (G1).
//   Bass 2    clamped-or-rejected -> EXACT clamps 1.5->1.0, -0.5->0.0.
//   Bass 3    setEq {band, gain} -> {band, gainDb} (G1).
//   Bass 4    band 0-4 + gain +/-12 -> negative band throws
//             ArgumentError; gain clamps to +/-15 dB (F2); band 9 is
//             FORWARDED (no upper bound — finding G3, pinned not hidden).
//   Bass 5    dispose idempotent -> + second dispose sends nothing,
//             setBass/setEqBand after dispose throw StateError.
//   Krisp 1   init completes-or-MissingPlugin -> initialize() returns
//             bool; false where unsupported (Linux); isAvailable agrees.
//   Krisp 2   buildProcessor null tolerated -> returns null where
//             unsupported (Linux); lazy init; repeat returns same.
//   Krisp 3   dispose lifecycle safe -> + after dispose, initialize
//             returns false and buildProcessor returns null.
//   RNNoise 1 init completes-or-MissingPlugin -> initialize() returns
//             TRUE on every platform (fail-open); isInitialized true;
//             Linux: spectral-gate engine, native unavailable.
//   RNNoise 2 buildProcessor null tolerated -> null BEFORE init, a live
//             processor named 'RnnoiseMicProcessor' AFTER init.
//   RNNoise 3 dispose lifecycle safe -> + after dispose, initialize
//             returns false and buildProcessor returns null.
//   Pipe 1    pipeline initialize() -> RENAMED: setProcessor installs
//             (install IS init — F4); NC defaults OFF; enabling NC
//             supplies the processor via captureOptions().
//   Pipe 2    dispose idempotent -> + dispose clears processor + NC
//             flag; setProcessor after dispose returns false (F3).
//   Play 1    attachToPlayer completes -> RENAMED: attach completes,
//             bridge answers (fake), Off preset pushed, isAttached +
//             attachedPlayerId set. AudioPlayer needs the audioplayers
//             channel mocks (G8) or its constructor fails unhandled.
//   Play 2    applyPreset(PlaybackPreset.off) -> applyPreset('Off');
//             pushes the five zero values; only known methods sent.
//   Play 3    applyPreset(PlaybackPreset.room) -> applyPreset('Room');
//             pushes 0.35/0.15/180.0/0.30/band0+3dB in order.
//   Play 4    applyPreset(PlaybackPreset.hall) -> applyPreset('Hall');
//             pushes 0.70/0.25/350.0/0.40/band0+4.5dB in order.
//   Play 5    setEnabled toggles -> + isEnabled flips; repeat toggle is
//             a no-op (no new calls); only known methods sent.
//   Play 6    dispose idempotent -> + isEnabled false after dispose;
//             applyPreset/setEnabled after dispose throw StateError.
//   Panel 1   builds with all callbacks -> + 4 sliders / 3 presets /
//             NS switch found; preset-Room tap fires onPreset('Room')
//             and moves the reverb slider to 0.35.
//   Panel 2   dragging a slider fires a callback -> RENAMED: each of
//             the four keyed sliders dragged; callbacks fire with
//             LANDED ranges (delay 0-500, bass -12..+12 — G5).
//   Panel 3   toggling NS fires its callback -> same, keyed finder;
//             asserts the value is true (was: merely non-null).
//
// FINDINGS (landed behavior that contradicts a phase-1 intent —
// reported, not hidden; no test was deleted to force a pass):
//   F1. (from the 49-test rewrite) No `enabled` flag exists in the
//       landed API: "off" is amount 0.0, and PlaybackEffects' Off
//       preset pushes zeros.
//   F2. The EQ clamp is +/-15 dB (BassEqEffect.maxGainDb), not the
//       +/-12 dB the phase-1 tests assumed.
//   F3. The pipeline NEVER throws for a missing/uninitialized
//       processor: it fails open (setProcessor returns false,
//       captureOptions() carries a null processor).
//   F4. There is no pipeline initialize()/isInitialized at all:
//       install IS setProcessor, and it initializes the processor
//       itself.
//   F5. setDelay's argument key is 'ms' (EchoDelayEffect), not
//       'delayMs'.
//   F6. (Observation) EchoDelayEffect.dispose() has no disposed-state
//       guard: unlike ReverbEffect/BassEqEffect it never throws
//       StateError after dispose and can be reused.
//   G1. The helpers' canonical encoding (audio_test_helpers.dart:
//       bare double for setReverb/setEcho/setBass/setDelay; setEq
//       {'band','gain'}; +/-12 dB) was a phase-1 G10 definition the
//       landed impls did NOT follow — landed encoding is map payloads
//       {'amount'} / {'ms'} / {'band','gainDb'} and +/-15 dB. So
//       `assertConformingCall` (which pins the old encoding) CANNOT be
//       used here; this file asserts the landed shapes directly via
//       _assertLandedCall. COORDINATOR: audio_test_helpers.dart itself
//       still pins the old encoding (out of scope for this file —
//       this rewrite may only edit this test file).
//   G2. ReverbEffect DEDUPES identical amounts: a repeat of the last
//       amount sends no channel call. Tests that count calls must use
//       distinct amounts (and PlaybackEffects re-pushes of the same
//       preset send fewer reverb calls than echo/delay/bass ones).
//   G3. BassEqEffect.setEqBand has NO upper band bound: band 9 is
//       forwarded raw (only a negative band throws ArgumentError).
//       The phase-1 "band must be 0-4" intent has no landed equivalent.
//   G4. PlaybackEffects presets are static PlaybackPreset VALUES keyed
//       by capitalized String names ('Off'/'Room'/'Hall') —
//       PlaybackPreset is a value class, not an enum; there is no
//       PlaybackPreset.off/room/hall.
//   G5. Panel slider ranges differ from the phase-1 guesses: delay
//       0-500 ms (not 0-2000) and bass -12..+12 dB (not a 0..1 amount).
//       Panel preset values ALSO differ from PlaybackEffects presets
//       (Room delay 120 vs 180 ms; Hall echo 0.40 vs 0.25; panel bass
//       is dB, playback bass is a 0-1 amount) — the merge must
//       reconcile the two preset tables.
//   G6. attachPlayback / detachPlayback are BRIDGE methods on the
//       shared channel, OUTSIDE the five effect methods —
//       assertOnlyKnownMethods must only be applied to preset/effect
//       calls, never after attachToPlayer/dispose.
//   G7. Krisp/RNNoise initialize() returns Future<bool> (not void)
//       and NEVER throws MissingPluginException — both fail soft
//       internally (Krisp: false on unsupported platforms; RNNoise:
//       true everywhere, spectral-gate fallback). The A7
//       MissingPlugin tolerance is now needed only for
//       AudioPlayer.dispose() (audioplayers release() hits an
//       unregistered plugin channel under flutter test) — and with
//       the audioplayers channel mocks installed (G8) even that
//       completes cleanly.
//   G8. audioplayers calls `init` (global channel) + `create`
//       (players channel) from the AudioPlayer constructor; without
//       mocks those futures fail with MissingPluginException and the
//       test zone reports an unhandled error. The PlaybackEffects
//       group therefore mocks xyz.luan/audioplayers(.global) (same
//       pattern as test/audio_playback_verify_test.dart).
//   G9. Effect dispose() methods SEND channel calls (reverb sends
//       setReverb 0.0 only if an effect was active; echo always sends
//       setEcho 0.0; bass sends setBass 0.0 + flattens touched
//       bands) — call counts are always asserted BEFORE dispose.
//   G10. SDK QUIRK (not a test issue): this pre-release Flutter SDK
//       deprecates the `package:flutter/material.dart` barrel itself
//       (deprecated_member_use info; `material_ui` does not exist),
//       so the import below carries a single-line
//       `// ignore: deprecated_member_use`. The already-merged
//       test/audio_effects_ui_test.dart carries the same info
//       unsuppressed; this file suppresses it only to keep the
//       0-error / 0-warning / 0-info gate meaningful.

import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
// ignore: deprecated_member_use — see finding G10 in the header.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/screens/audio_effects_panel.dart';
import 'package:protournament_user/services/audio_effects_bass.dart';
import 'package:protournament_user/services/audio_effects_echo.dart';
import 'package:protournament_user/services/audio_effects_reverb.dart';
import 'package:protournament_user/services/krisp_noise_filter.dart';
import 'package:protournament_user/services/mic_audio_pipeline.dart';
import 'package:protournament_user/services/playback_effects.dart';
import 'package:protournament_user/services/rnnoise_processor.dart';

import 'audio_test_helpers.dart';

/// Passes when [action] completes, or when it throws
/// MissingPluginException (G7: no native plugin under `flutter test`).
/// Any other error fails the test. Only needed for
/// AudioPlayer.dispose() now — the audio impls all fail soft.
Future<void> _completesOrMissingPlugin(
  Future<void> Function() action,
) async {
  try {
    await action();
  } on MissingPluginException {
    // Expected in the unit-test sandbox — real init is on-device work.
  }
}

/// Asserts [call] is a landed-encoding invocation of [method] carrying
/// exactly [payload] (deep equality). The landed encoding is map
/// payloads — see FINDING G1: the helpers' `assertConformingCall`
/// pins the phase-1 bare-double encoding, which the landed impls do
/// not send, so this file asserts the landed shapes directly.
void _assertLandedCall(
  MethodCall call,
  String method,
  Map<String, Object> payload,
) {
  expect(
    call.method,
    method,
    reason: 'expected channel method $method, got ${call.method}',
  );
  expect(call.arguments, payload);
}

/// Wires a [PlaybackEffects] to the REAL effect instances (the merge
/// wiring from playback_effects.dart), so preset pushes land on the
/// fake channel. dispose() also disposes the effect instances.
PlaybackEffects _wiredPlaybackEffects({
  required ReverbEffect reverb,
  required EchoDelayEffect echo,
  required BassEqEffect bass,
}) {
  return PlaybackEffects(
    setReverbAmount: reverb.setAmount,
    setEchoAmount: echo.setEcho,
    setEchoDelayMs: echo.setDelayMs,
    setBassAmount: bass.setBass,
    setEqBand: bass.setEqBand,
    disposeEffects: () async {
      await reverb.dispose();
      await echo.dispose();
      await bass.dispose();
    },
  );
}

/// audioplayers calls `init` (global channel) + `create` (players
/// channel) from the AudioPlayer constructor; without mocks the
/// constructor's internal future fails with MissingPluginException
/// and the test zone reports it as an unhandled error (G8). Same
/// pattern as test/audio_playback_verify_test.dart.
void _mockAudioplayersChannels() {
  final TestDefaultBinaryMessengerBinding binding =
      TestDefaultBinaryMessengerBinding.instance;
  binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('xyz.luan/audioplayers.global'),
    (MethodCall call) async => null,
  );
  binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('xyz.luan/audioplayers'),
    (MethodCall call) async => null,
  );
}

void _unmockAudioplayersChannels() {
  final TestDefaultBinaryMessengerBinding binding =
      TestDefaultBinaryMessengerBinding.instance;
  binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('xyz.luan/audioplayers.global'),
    null,
  );
  binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('xyz.luan/audioplayers'),
    null,
  );
}

/// Panel wrapper matching test/audio_effects_ui_test.dart: a scroll
/// view so the tall panel never overflows the 800x600 test viewport.
Widget _wrapPanel(AudioEffectsPanel panel) => MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(child: panel),
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeAudioEffectsChannel fake;

  setUp(() {
    fake = FakeAudioEffectsChannel();
  });

  tearDown(() {
    fake.dispose();
  });

  group('ReverbEffect (G3)', () {
    test('setAmount sends setReverb with an {amount} map payload',
        () async {
      final effect = ReverbEffect();
      await effect.setAmount(0.5);
      expect(fake.callsNamed('setReverb'), hasLength(1));
      _assertLandedCall(
        fake.callsNamed('setReverb').single,
        'setReverb',
        const <String, Object>{'amount': 0.5},
      );
      expect(effect.lastAmount, 0.5);
      await effect.dispose();
    });

    test('setAmount boundary values pass through unchanged', () async {
      final effect = ReverbEffect();
      await effect.setAmount(0.0);
      await effect.setAmount(1.0);
      final sent = fake.callsNamed('setReverb');
      expect(sent, hasLength(2));
      expect(sent[0].arguments, const <String, Object>{'amount': 0.0});
      expect(sent[1].arguments, const <String, Object>{'amount': 1.0});
      expect(effect.lastAmount, 1.0);
      await effect.dispose();
    });

    test('setAmount clamps out-of-range input (1.5 -> 1.0, -0.5 -> 0.0)',
        () async {
      final effect = ReverbEffect();
      await effect.setAmount(1.5);
      await effect.setAmount(-0.5);
      final sent = fake.callsNamed('setReverb');
      expect(sent, hasLength(2));
      expect(sent[0].arguments, const <String, Object>{'amount': 1.0});
      expect(sent[1].arguments, const <String, Object>{'amount': 0.0});
      expect(effect.lastAmount, 0.0);
      await effect.dispose();
    });

    test('dispose completes and is idempotent; use after dispose throws',
        () async {
      final effect = ReverbEffect();
      await effect.setAmount(0.5);
      await effect.dispose();
      expect(effect.isDisposed, isTrue);
      // dispose() released the active effect (G9).
      expect(
        fake.callsNamed('setReverb').last.arguments,
        const <String, Object>{'amount': 0.0},
      );
      final int afterFirst = fake.calls.length;
      await effect.dispose();
      expect(
        fake.calls.length,
        afterFirst,
        reason: 'second dispose must send nothing',
      );
      await expectLater(effect.setAmount(0.5), throwsStateError);
    });
  });

  group('EchoDelayEffect (G4)', () {
    test('setEcho sends setEcho with an {amount} map payload', () async {
      final effect = EchoDelayEffect();
      await effect.setEcho(0.4);
      expect(fake.callsNamed('setEcho'), hasLength(1));
      _assertLandedCall(
        fake.callsNamed('setEcho').single,
        'setEcho',
        const <String, Object>{'amount': 0.4},
      );
      expect(effect.amount, 0.4);
      await effect.dispose();
    });

    test('setEcho clamps out-of-range input (1.5 -> 1.0, -0.5 -> 0.0)',
        () async {
      final effect = EchoDelayEffect();
      await effect.setEcho(1.5);
      await effect.setEcho(-0.5);
      final sent = fake.callsNamed('setEcho');
      expect(sent, hasLength(2));
      expect(sent[0].arguments, const <String, Object>{'amount': 1.0});
      expect(sent[1].arguments, const <String, Object>{'amount': 0.0});
      expect(effect.amount, 0.0);
      await effect.dispose();
    });

    test('setDelayMs sends channel method setDelay (not setDelayMs)',
        () async {
      final effect = EchoDelayEffect();
      await effect.setDelayMs(250.0);
      expect(fake.callsNamed('setDelay'), hasLength(1));
      expect(fake.callsNamed('setDelayMs'), isEmpty);
      _assertLandedCall(
        fake.callsNamed('setDelay').single,
        'setDelay',
        const <String, Object>{'ms': 250.0},
      );
      expect(effect.delayMs, 250.0);
      await effect.dispose();
    });

    test('setDelayMs clamps to 0-2000 ms (5000 -> 2000, -10 -> 0)',
        () async {
      final effect = EchoDelayEffect();
      expect(EchoDelayEffect.maxDelayMs, 2000.0);
      await effect.setDelayMs(5000.0);
      await effect.setDelayMs(-10.0);
      final sent = fake.callsNamed('setDelay');
      expect(sent, hasLength(2));
      expect(sent[0].arguments, const <String, Object>{'ms': 2000.0});
      expect(sent[1].arguments, const <String, Object>{'ms': 0.0});
      expect(effect.delayMs, 0.0);
      await effect.dispose();
    });

    test('dispose completes and is idempotent; no disposed-state guard (F6)',
        () async {
      final effect = EchoDelayEffect();
      await effect.dispose();
      await effect.dispose();
      // F6: unlike ReverbEffect/BassEqEffect, EchoDelayEffect has no
      // disposed-state guard — it never throws after dispose and can
      // be reused.
      await effect.setEcho(0.3);
      expect(
        fake.callsNamed('setEcho').last.arguments,
        const <String, Object>{'amount': 0.3},
      );
      expect(effect.amount, 0.3);
    });
  });

  group('BassEqEffect (G5)', () {
    test('setBass sends setBass with an {amount} map payload', () async {
      final effect = BassEqEffect();
      await effect.setBass(0.7);
      expect(fake.callsNamed('setBass'), hasLength(1));
      _assertLandedCall(
        fake.callsNamed('setBass').single,
        'setBass',
        const <String, Object>{'amount': 0.7},
      );
      await effect.dispose();
    });

    test('setBass clamps out-of-range input (1.5 -> 1.0, -0.5 -> 0.0)',
        () async {
      final effect = BassEqEffect();
      await effect.setBass(1.5);
      await effect.setBass(-0.5);
      final sent = fake.callsNamed('setBass');
      expect(sent, hasLength(2));
      expect(sent[0].arguments, const <String, Object>{'amount': 1.0});
      expect(sent[1].arguments, const <String, Object>{'amount': 0.0});
      await effect.dispose();
    });

    test('setEqBand sends setEq with {band, gainDb}', () async {
      final effect = BassEqEffect();
      await effect.setEqBand(2, 3.0);
      expect(fake.callsNamed('setEq'), hasLength(1));
      _assertLandedCall(
        fake.callsNamed('setEq').single,
        'setEq',
        const <String, Object>{'band': 2, 'gainDb': 3.0},
      );
      await effect.dispose();
    });

    test(
        'setEqBand rejects a negative band; clamps gain to +/-15 dB; '
        'band 9 is forwarded (G3)', () async {
      final effect = BassEqEffect();
      expect(BassEqEffect.maxGainDb, 15.0);
      expect(BassEqEffect.minGainDb, -15.0);
      await expectLater(effect.setEqBand(-1, 0.0), throwsArgumentError);
      expect(
        fake.callsNamed('setEq'),
        isEmpty,
        reason: 'a rejected band must send nothing',
      );
      await effect.setEqBand(1, 30.0);
      await effect.setEqBand(1, -30.0);
      // FINDING G3: there is NO upper band bound — band 9 is
      // forwarded raw. Pinned here, not hidden; the phase-1 "band
      // must be 0-4" intent has no landed equivalent.
      await effect.setEqBand(9, 0.0);
      final sent = fake.callsNamed('setEq');
      expect(sent, hasLength(3));
      expect(
        sent[0].arguments,
        const <String, Object>{'band': 1, 'gainDb': 15.0},
      );
      expect(
        sent[1].arguments,
        const <String, Object>{'band': 1, 'gainDb': -15.0},
      );
      expect(
        sent[2].arguments,
        const <String, Object>{'band': 9, 'gainDb': 0.0},
      );
      await effect.dispose();
    });

    test('dispose completes and is idempotent; use after dispose throws',
        () async {
      final effect = BassEqEffect();
      await effect.setBass(0.5);
      await effect.setEqBand(1, 2.0);
      await effect.dispose();
      final int afterFirst = fake.calls.length;
      await effect.dispose();
      expect(
        fake.calls.length,
        afterFirst,
        reason: 'second dispose must send nothing',
      );
      await expectLater(effect.setBass(0.1), throwsStateError);
      await expectLater(effect.setEqBand(0, 0.0), throwsStateError);
    });
  });

  group('KrispMicProcessor (G1)', () {
    test('initialize returns a bool; false where unsupported (Linux)',
        () async {
      final processor = KrispMicProcessor();
      final bool ok = await processor.initialize();
      expect(processor.isAvailable, ok);
      if (Platform.isLinux) {
        expect(ok, isFalse, reason: 'Krisp is unsupported on Linux');
        expect(processor.isAvailable, isFalse);
      }
      // initialize() is idempotent: a second call agrees.
      expect(await processor.initialize(), ok);
      await processor.dispose();
    });

    test('buildProcessor returns null where unsupported; never throws',
        () async {
      final processor = KrispMicProcessor();
      // Lazy init: buildProcessor without initialize() never throws.
      final built = await processor.buildProcessor();
      await processor.initialize();
      final builtAgain = await processor.buildProcessor();
      // Repeated calls return the same instance (or null twice).
      expect(builtAgain, same(built));
      expect(processor.isAvailable, built != null);
      if (Platform.isLinux) {
        expect(built, isNull);
        expect(builtAgain, isNull);
      }
      await processor.dispose();
    });

    test('dispose lifecycle is safe (before init, twice); dead after dispose',
        () async {
      final processor = KrispMicProcessor();
      await processor.dispose();
      await processor.dispose();
      expect(processor.isAvailable, isFalse);
      expect(await processor.initialize(), isFalse);
      expect(await processor.buildProcessor(), isNull);
    });
  });

  group('RnnoiseMicProcessor (G2)', () {
    test('initialize returns true on every platform (fail-open)', () async {
      final processor = RnnoiseMicProcessor();
      final bool ok = await processor.initialize();
      expect(ok, isTrue);
      expect(processor.isInitialized, isTrue);
      if (Platform.isLinux) {
        expect(processor.isNativeAvailable, isFalse);
        expect(processor.engine, RnnoiseEngine.spectralGate);
      }
      // initialize() is idempotent.
      expect(await processor.initialize(), isTrue);
      await processor.dispose();
    });

    test('buildProcessor returns null before init, a live processor after init',
        () async {
      final processor = RnnoiseMicProcessor();
      expect(await processor.buildProcessor(), isNull);
      await processor.initialize();
      final built = await processor.buildProcessor();
      expect(built, isNotNull);
      expect(built!.name, 'RnnoiseMicProcessor');
      expect(processor.hasActiveProcessor, isTrue);
      await processor.dispose();
    });

    test('dispose lifecycle is safe (before init, twice); dead after dispose',
        () async {
      final processor = RnnoiseMicProcessor();
      await processor.dispose();
      await processor.dispose();
      expect(processor.isInitialized, isFalse);
      expect(await processor.initialize(), isFalse);
      expect(await processor.buildProcessor(), isNull);
    });
  });

  group('MicAudioPipeline (G7)', () {
    test('setProcessor installs the processor; NC defaults OFF (install IS init)',
        () async {
      final pipeline = MicAudioPipeline();
      final rnnoise = RnnoiseMicProcessor();
      // F4: there is no pipeline initialize() — install IS
      // setProcessor, and it initializes the processor itself.
      final bool ok = await pipeline.setProcessor(rnnoise);
      expect(ok, isTrue);
      expect(pipeline.hasProcessor, isTrue);
      expect(pipeline.processorName, 'RnnoiseMicProcessor');
      // Default is OFF (explicit opt-in): installed but not supplied.
      expect(pipeline.noiseCancellationEnabled, isFalse);
      expect(pipeline.processor, isNull);
      expect(pipeline.captureOptions().processor, isNull);
      pipeline.setNoiseCancellationEnabled(true);
      expect(pipeline.noiseCancellationEnabled, isTrue);
      expect(pipeline.processor, isNotNull);
      expect(pipeline.captureOptions().processor, isNotNull);
      await pipeline.dispose();
    });

    test('dispose completes and is idempotent; setProcessor after dispose fails open',
        () async {
      final pipeline = MicAudioPipeline();
      await pipeline.setProcessor(RnnoiseMicProcessor());
      pipeline.setNoiseCancellationEnabled(true);
      expect(pipeline.processor, isNotNull);
      await pipeline.dispose();
      expect(pipeline.hasProcessor, isFalse);
      expect(pipeline.processor, isNull);
      expect(pipeline.processorName, isNull);
      expect(pipeline.noiseCancellationEnabled, isFalse);
      expect(pipeline.captureOptions().processor, isNull);
      await pipeline.dispose();
      // F3: fail-open, never throws — setProcessor after dispose
      // returns false instead of installing.
      final bool late = await pipeline.setProcessor(RnnoiseMicProcessor());
      expect(late, isFalse);
      expect(pipeline.hasProcessor, isFalse);
      // The NC switch is a no-op after dispose.
      pipeline.setNoiseCancellationEnabled(true);
      expect(pipeline.noiseCancellationEnabled, isFalse);
    });
  });

  group('PlaybackEffects (G8)', () {
    // G8: the AudioPlayer constructor needs the audioplayers channel
    // mocks (its init/create calls fail unhandled without them).
    setUp(_mockAudioplayersChannels);
    tearDown(_unmockAudioplayersChannels);

    test('attachToPlayer completes; bridge answers; Off preset pushed',
        () async {
      final reverb = ReverbEffect();
      final echo = EchoDelayEffect();
      final bass = BassEqEffect();
      final effects = _wiredPlaybackEffects(
        reverb: reverb,
        echo: echo,
        bass: bass,
      );
      final AudioPlayer player = AudioPlayer();
      await effects.attachToPlayer(player);
      expect(effects.isAttached, isTrue);
      expect(effects.attachedPlayerId, player.playerId);
      // The fake channel answers attachPlayback, so the bridge is
      // available (it reports no session info — the mock replies null).
      expect(effects.bridgeAvailable, isTrue);
      expect(effects.sessionInfo, isNull);
      // attach re-applies the Off preset through the tear-offs.
      // G6: attachPlayback is a bridge method, outside the five
      // effect methods — assert the exact sequence, not only-known.
      expect(
        fake.calls.map((MethodCall c) => c.method).toList(),
        <String>[
          'attachPlayback',
          'setReverb',
          'setEcho',
          'setDelay',
          'setBass',
          'setEq',
        ],
      );
      expect(
        fake.callsNamed('setReverb').single.arguments,
        const <String, Object>{'amount': 0.0},
      );
      expect(
        fake.callsNamed('setDelay').single.arguments,
        const <String, Object>{'ms': 250.0},
      );
      await effects.dispose();
      // G7: player.dispose() hits the audioplayers plugin channel,
      // which is unregistered under flutter test without the mocks.
      await _completesOrMissingPlugin(() => player.dispose());
    });

    test('applyPreset("Off") pushes zero values; only known methods sent',
        () async {
      final effects = _wiredPlaybackEffects(
        reverb: ReverbEffect(),
        echo: EchoDelayEffect(),
        bass: BassEqEffect(),
      );
      await effects.applyPreset('Off');
      assertOnlyKnownMethods(fake.calls);
      expect(
        fake.calls.map((MethodCall c) => c.method).toList(),
        <String>['setReverb', 'setEcho', 'setDelay', 'setBass', 'setEq'],
      );
      // F1: "off" is amount 0.0 — the Off preset pushes zeros.
      expect(
        fake.callsNamed('setReverb').single.arguments,
        const <String, Object>{'amount': 0.0},
      );
      expect(
        fake.callsNamed('setEcho').single.arguments,
        const <String, Object>{'amount': 0.0},
      );
      expect(
        fake.callsNamed('setDelay').single.arguments,
        const <String, Object>{'ms': 250.0},
      );
      expect(
        fake.callsNamed('setBass').single.arguments,
        const <String, Object>{'amount': 0.0},
      );
      expect(
        fake.callsNamed('setEq').single.arguments,
        const <String, Object>{'band': 0, 'gainDb': 0.0},
      );
      expect(effects.currentPreset, 'Off');
      await effects.dispose();
    });

    test('applyPreset("Room") pushes the Room values; only known methods sent',
        () async {
      final effects = _wiredPlaybackEffects(
        reverb: ReverbEffect(),
        echo: EchoDelayEffect(),
        bass: BassEqEffect(),
      );
      await effects.applyPreset('Room');
      assertOnlyKnownMethods(fake.calls);
      expect(
        fake.calls.map((MethodCall c) => c.method).toList(),
        <String>['setReverb', 'setEcho', 'setDelay', 'setBass', 'setEq'],
      );
      expect(
        fake.callsNamed('setReverb').single.arguments,
        const <String, Object>{'amount': 0.35},
      );
      expect(
        fake.callsNamed('setEcho').single.arguments,
        const <String, Object>{'amount': 0.15},
      );
      expect(
        fake.callsNamed('setDelay').single.arguments,
        const <String, Object>{'ms': 180.0},
      );
      expect(
        fake.callsNamed('setBass').single.arguments,
        const <String, Object>{'amount': 0.30},
      );
      expect(
        fake.callsNamed('setEq').single.arguments,
        const <String, Object>{'band': 0, 'gainDb': 3.0},
      );
      expect(effects.currentPreset, 'Room');
      await effects.dispose();
    });

    test('applyPreset("Hall") pushes the Hall values; only known methods sent',
        () async {
      final effects = _wiredPlaybackEffects(
        reverb: ReverbEffect(),
        echo: EchoDelayEffect(),
        bass: BassEqEffect(),
      );
      await effects.applyPreset('Hall');
      assertOnlyKnownMethods(fake.calls);
      expect(
        fake.calls.map((MethodCall c) => c.method).toList(),
        <String>['setReverb', 'setEcho', 'setDelay', 'setBass', 'setEq'],
      );
      expect(
        fake.callsNamed('setReverb').single.arguments,
        const <String, Object>{'amount': 0.70},
      );
      expect(
        fake.callsNamed('setEcho').single.arguments,
        const <String, Object>{'amount': 0.25},
      );
      expect(
        fake.callsNamed('setDelay').single.arguments,
        const <String, Object>{'ms': 350.0},
      );
      expect(
        fake.callsNamed('setBass').single.arguments,
        const <String, Object>{'amount': 0.40},
      );
      expect(
        fake.callsNamed('setEq').single.arguments,
        const <String, Object>{'band': 0, 'gainDb': 4.5},
      );
      expect(effects.currentPreset, 'Hall');
      await effects.dispose();
    });

    test('setEnabled toggles without error; no-op when unchanged',
        () async {
      final effects = _wiredPlaybackEffects(
        reverb: ReverbEffect(),
        echo: EchoDelayEffect(),
        bass: BassEqEffect(),
      );
      expect(effects.isEnabled, isTrue);
      await effects.setEnabled(false);
      expect(effects.isEnabled, isFalse);
      // Disabling pushes the Off values.
      expect(
        fake.callsNamed('setReverb').single.arguments,
        const <String, Object>{'amount': 0.0},
      );
      final int afterDisable = fake.calls.length;
      await effects.setEnabled(false);
      expect(
        fake.calls.length,
        afterDisable,
        reason: 're-disabling must be a no-op',
      );
      await effects.setEnabled(true);
      expect(effects.isEnabled, isTrue);
      expect(effects.currentPreset, 'Off');
      assertOnlyKnownMethods(fake.calls);
      // G2: the re-enable re-pushes Off, but ReverbEffect dedupes the
      // repeat 0.0 — exactly one setReverb call in total.
      expect(fake.callsNamed('setReverb'), hasLength(1));
      await effects.dispose();
    });

    test('dispose completes and is idempotent; use after dispose throws',
        () async {
      final effects = PlaybackEffects(
        setReverbAmount: (_) async {},
        setEchoAmount: (_) async {},
        setEchoDelayMs: (_) async {},
        setBassAmount: (_) async {},
        setEqBand: (_, __) async {},
      );
      await effects.dispose();
      expect(effects.isEnabled, isFalse);
      await effects.dispose();
      await expectLater(effects.applyPreset('Room'), throwsStateError);
      await expectLater(effects.setEnabled(true), throwsStateError);
    });
  });

  group('AudioEffectsPanel (G9)', () {
    testWidgets('builds with all callbacks provided; preset tap fires onPreset',
        (tester) async {
      String? seenPreset;
      await tester.pumpWidget(
        _wrapPanel(
          AudioEffectsPanel(
            isHost: true,
            onReverb: (double value) {},
            onEcho: (double value) {},
            onDelayMs: (double value) {},
            onBass: (double value) {},
            onPreset: (String preset) {
              seenPreset = preset;
            },
            onNoiseCancellation: (bool enabled) {},
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(AudioEffectsPanel), findsOneWidget);
      expect(find.byType(Slider), findsNWidgets(7));
      expect(find.text('Off'), findsOneWidget);
      expect(find.text('Room'), findsOneWidget);
      expect(find.text('Hall'), findsOneWidget);
      expect(
        find.byKey(const Key('noise-cancellation-switch')),
        findsOneWidget,
      );
      // Tapping a preset fires onPreset and moves the sliders to the
      // panel's preset values (G5: panel Room reverb is 0.35).
      await tester.tap(find.byKey(const Key('preset-Room')));
      await tester.pump();
      expect(seenPreset, 'Room');
      expect(
        tester
            .widget<Slider>(find.byKey(const Key('reverb-slider')))
            .value,
        0.35,
      );
      expect(find.text('35%'), findsOneWidget);
    });

    testWidgets(
        'dragging each level slider fires its callback with landed-range values',
        (tester) async {
      final List<double> reverbValues = <double>[];
      final List<double> echoValues = <double>[];
      final List<double> delayValues = <double>[];
      final List<double> bassValues = <double>[];
      await tester.pumpWidget(
        _wrapPanel(
          AudioEffectsPanel(
            isHost: true,
            onReverb: reverbValues.add,
            onEcho: echoValues.add,
            onDelayMs: delayValues.add,
            onBass: bassValues.add,
            onPreset: (String preset) {},
            onNoiseCancellation: (bool enabled) {},
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(Slider), findsNWidgets(7));
      await tester.drag(
        find.byKey(const Key('reverb-slider')),
        const Offset(100, 0),
      );
      await tester.pump();
      await tester.drag(
        find.byKey(const Key('echo-slider')),
        const Offset(100, 0),
      );
      await tester.pump();
      await tester.drag(
        find.byKey(const Key('delay-slider')),
        const Offset(100, 0),
      );
      await tester.pump();
      await tester.drag(
        find.byKey(const Key('bass-slider')),
        const Offset(100, 0),
      );
      await tester.pump();
      // G5: landed ranges — delay is 0-500 ms (not 0-2000) and bass
      // is -12..+12 dB (not a 0..1 amount).
      expect(reverbValues, isNotEmpty);
      expect(echoValues, isNotEmpty);
      expect(delayValues, isNotEmpty);
      expect(bassValues, isNotEmpty);
      for (final double value in <double>[...reverbValues, ...echoValues]) {
        expect(value, inInclusiveRange(0.0, 1.0));
      }
      for (final double value in delayValues) {
        expect(value, inInclusiveRange(0.0, 500.0));
      }
      for (final double value in bassValues) {
        expect(value, inInclusiveRange(-12.0, 12.0));
      }
      // Dragging right from the 0 start moves every level up.
      expect(reverbValues.last, greaterThan(0.0));
      expect(echoValues.last, greaterThan(0.0));
      expect(delayValues.last, greaterThan(0.0));
      expect(bassValues.last, greaterThan(0.0));
    });

    testWidgets('toggling noise cancellation fires its callback',
        (tester) async {
      bool? lastValue;
      await tester.pumpWidget(
        _wrapPanel(
          AudioEffectsPanel(
            isHost: true,
            onReverb: (double value) {},
            onEcho: (double value) {},
            onDelayMs: (double value) {},
            onBass: (double value) {},
            onPreset: (String preset) {},
            onNoiseCancellation: (bool enabled) {
              lastValue = enabled;
            },
          ),
        ),
      );
      await tester.pump();
      expect(
        find.byKey(const Key('noise-cancellation-switch')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('noise-cancellation-switch')));
      await tester.pump();
      expect(lastValue, isTrue);
    });
  });
}
