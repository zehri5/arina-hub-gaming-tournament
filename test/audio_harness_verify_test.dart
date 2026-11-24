// REWRITTEN 2026-11-22 against the landed APIs (see COORDINATION.md G10 note)
// — phase-1 assumed value-object effect classes + PlaybackEffects setters +
// pipeline initialize()/buildProcessor(), none of which landed.
//
// GROUP 10 VERIFIER — INDEPENDENT contract-conformance suite, rewritten
// against the LANDED #10 audio APIs (verified by reading the implementation
// files, not from the phase-1 guesses). Group D is unchanged from phase 1.
//
// LANDED API (the real contracts under test):
//   * lib/services/audio_effects.dart — barrel: ReverbEffect,
//     EchoDelayEffect, BassEqEffect, PlaybackEffects.
//   * ReverbEffect.setAmount(double) -> setReverb {'amount': 0.0-1.0}
//     (NaN -> 0.0, clamped, deduped, StateError after dispose).
//   * EchoDelayEffect.setEcho(double) -> setEcho {'amount': 0.0-1.0};
//     setDelayMs(double) -> setDelay {'ms': 0.0-2000.0} (NOTE: the arg
//     key is 'ms', not 'delayMs').
//   * BassEqEffect.setBass(double) -> setBass {'amount': 0.0-1.0};
//     setEqBand(int, double) -> setEq {'band': n, 'gainDb': +/-15 dB}.
//   * PlaybackEffects has NO setReverb/setEcho/... setters and NO no-arg
//     constructor: it takes five required tear-offs and exposes
//     attachToPlayer / applyPreset('Off'/'Room'/'Hall') / setEnabled.
//   * MicAudioPipeline has NO initialize()/isInitialized/buildProcessor().
//     Real API: setProcessor(MicNoiseProcessor?) -> Future<bool>,
//     setNoiseCancellationEnabled(bool) (sync), prepareForPublish(),
//     markProcessorDetached(), captureOptions(), dispose();
//     getters hasProcessor / processorName / processor / activeProcessor.
//   * MicNoiseProcessor (abstract): initialize() -> Future<bool>,
//     buildProcessor() -> Future<TrackProcessor<AudioProcessorOptions>?>,
//     dispose(). KrispMicProcessor + RnnoiseMicProcessor implement it.
//
// GROUP A (channel contract, 10) — same intent as phase 1, real API:
//   A1-A5 call the landed service methods and assert method + payload.
//   A6 now wires PlaybackEffects to the REAL effect instances and asserts
//     the Room preset's five values reach the channel (old: custom
//     ReverbEffect(roomSize/damping) values — those params never landed).
//   A7 RENAMED: no `enabled` flag exists anywhere in the landed API —
//     "off" is amount 0.0, so the test asserts the zero payloads.
//   A8 unchanged in intent (sequential calls arrive in order).
//   A9 RENAMED: no `enabled:true` default payload exists — instead the
//     test pins PlaybackEffects' real defaults (preset Off, enabled,
//     unattached) and that construction sends nothing.
//   A10 STRENGTHENED: the landed reverb doc says a PlatformException
//     propagates, so the test now requires the typed throw (phase 1
//     allowed propagate-or-swallow).
//
// GROUP B (effect shapes, 15) — the assumed value-object classes
// (EchoEffect/DelayEffect/BassEffect/EqEffect with enabled/toMap/defaults)
// DO NOT EXIST. Every test is replaced by its closest landed equivalent —
// clamping / defaults / round-trip via the service methods + mocked
// channel assertions (old intent -> new assertion):
//   B1  ReverbEffect defaults in range + enabled
//       -> fresh ReverbEffect: lastAmount null, not disposed, sends nothing.
//   B2  out-of-range roomSize clamped/rejected
//       -> setAmount(2.5) emits 1.0; setAmount(NaN) emits 0.0.
//   B3  ReverbEffect toMap round-trip
//       -> setAmount(0.7) round-trips via channel payload + lastAmount.
//   B4  EchoEffect defaults in range + enabled
//       -> fresh EchoDelayEffect: amount 0.0, delayMs == defaultDelayMs 250.
//   B5  out-of-range feedback clamped/rejected
//       -> setEcho(-1.0) emits 0.0; setEcho(NaN) emits 0.0.
//   B6  EchoEffect toMap round-trip
//       -> setEcho(0.5) + setDelayMs(450) round-trip via channel + getters.
//   B7  DelayEffect defaults in range + enabled
//       -> setDelayMs(2000) forwards the max delay (maxDelayMs == 2000).
//   B8  out-of-range mix clamped/rejected
//       -> setDelayMs(3000) emits 2000.0; setDelayMs(-5) emits 0.0.
//   B9  DelayEffect toMap round-trip
//       -> setDelayMs(200) round-trips via channel {'ms': 200.0} + getter.
//   B10 BassEffect defaults flat (0 dB) + enabled
//       -> setBass(0.0) sends the flat/off amount.
//   B11 out-of-range gainDb clamped/rejected (+/-12 assumed)
//       -> setBass(2.0) emits 1.0; setBass(-0.5) emits 0.0. (FINDING:
//       the landed EQ clamp is +/-15 dB, not the assumed +/-12 — see B14.)
//   B12 BassEffect toMap round-trip
//       -> setBass(0.6) round-trips via the channel payload.
//   B13 EqEffect defaults flat (all bands 0 dB) + enabled
//       -> setEqBand(0, 0.0) sends a flat band.
//   B14 out-of-range band gain clamped/rejected (+/-12 assumed)
//       -> setEqBand(1, 50.0) emits 15.0; (1, -50.0) emits -15.0.
//       (FINDING: landed bound is +/-15 dB, not +/-12.)
//   B15 EqEffect toMap round-trips its bands
//       -> setEqBand round-trips three band/gain pairs on the channel.
//
// GROUP C (pipeline lifecycle, 12) — rewritten against the real
// MicAudioPipeline + MicNoiseProcessor API, with a small fake processor
// (same pattern as test/audio_mic_pipeline_verify_test.dart):
//   C1  RENAMED: setProcessor installs (hasProcessor, processorName);
//       NC defaults OFF so nothing is supplied until enabled.
//   C2  RENAMED: setProcessor(null) removes + disposes (was: double init).
//   C3  RENAMED: replacing a processor disposes the old one (was:
//       buildProcessor-before-init throws — see FINDING F3 below).
//   C4  RENAMED: NC on/off via captureOptions().processor; the SAME
//       instance returns on re-enable, without re-init or dispose.
//   C5  RENAMED: setNoiseCancellationEnabled(true) reflected by the
//       noiseCancellationEnabled getter (was: setNoiseSuppression).
//   C6  RENAMED: NC toggle round-trips true-false-true.
//   C7  RENAMED: prepareForPublish rebuilds a FRESH processor after
//       markProcessorDetached (was: processor reports NS enabled).
//   C8  RENAMED: prepareForPublish is a no-op while NC is off.
//   C9  RENAMED: fail-open — a processor whose initialize() returns
//       false (or whose buildProcessor() returns null) installs
//       nothing; the mic stays plain (was: dispose marks uninitialized).
//   C10 RENAMED: the REAL processors — Krisp fails open where
//       unsupported (Linux), RNNoise installs via its spectral-gate
//       fallback (was: double dispose — now C12).
//   C11 RENAMED: dispose clears the processor + the NC flag.
//   C12 RENAMED: double dispose is safe; setProcessor after dispose
//       fails open (returns false) instead of throwing.
//
// FINDINGS (landed behavior that contradicts a phase-1 test intent —
// reported, not hidden; no test was deleted to force a pass):
//   F1. No `enabled` flag exists in the landed API (no enabled field,
//       no toMap, no per-effect value objects): "off" is amount 0.0,
//       and PlaybackEffects' Off preset pushes zeros. Old A7/A9/B1/B4/
//       B7/B10/B13 intents about `enabled` have no landed equivalent.
//   F2. The EQ clamp is +/-15 dB (BassEqEffect.maxGainDb), not the
//       +/-12 dB the phase-1 tests assumed (old B11/B14).
//   F3. The pipeline NEVER throws for a missing/uninitialized processor:
//       it fails open (setProcessor returns false, captureOptions()
//       carries a null processor). Old C3/C11 expected StateError.
//   F4. There is no pipeline initialize()/isInitialized at all: install
//       IS setProcessor, and it initializes the processor itself.
//   F5. setDelay's argument key is 'ms' (EchoDelayEffect), not 'delayMs'.
//   F6. (Observation, not a contradiction) EchoDelayEffect.dispose() has
//       no disposed-state guard: unlike ReverbEffect/BassEqEffect it
//       never throws StateError after dispose and can be reused.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:protournament_user/services/audio_effects.dart';
import 'package:protournament_user/services/krisp_noise_filter.dart';
import 'package:protournament_user/services/mic_audio_pipeline.dart';
import 'package:protournament_user/services/rnnoise_processor.dart';

const String _channelName = 'arena_audio/effects';

/// Payload values on the channel must be plain numbers/bools (eq bands
/// may additionally be a list of numbers). No nulls, no nested maps.
void _expectNumericPayload(Map<dynamic, dynamic> args,
    {bool allowNumList = false}) {
  for (final entry in args.entries) {
    final value = entry.value;
    final ok = value is num ||
        value is bool ||
        (allowNumList &&
            value is List &&
            value.every((e) => e is num));
    expect(ok, isTrue,
        reason: 'payload key ${entry.key} has non-numeric value: $value');
  }
}

/// Installs a recording mock on the shared effects channel and returns
/// the list the calls land in. All three effect services + the
/// PlaybackEffects bridge use this one channel name.
List<MethodCall> _mockEffectsChannel() {
  final calls = <MethodCall>[];
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel(_channelName),
    (MethodCall call) async {
      calls.add(call);
      return null;
    },
  );
  return calls;
}

void _unmockEffectsChannel() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel(_channelName), null);
}

/// Minimal TrackProcessor stand-in: proves the pipeline's output fits
/// the livekit_client 2.13.2 `AudioCaptureOptions.processor` seam
/// (type `TrackProcessor<AudioProcessorOptions>?`). Never actually
/// processes audio in these tests. Same shape as the fake in
/// test/audio_mic_pipeline_verify_test.dart.
class _FakeTrackProcessor extends TrackProcessor<AudioProcessorOptions> {
  @override
  String get name => 'fake-noise-processor';

  @override
  Future<void> init(AudioProcessorOptions options) async {}

  @override
  Future<void> restart(AudioProcessorOptions options) async {}

  @override
  Future<void> destroy() async {}

  @override
  Future<void> onPublish(Room room) async {}

  @override
  Future<void> onUnpublish() async {}

  @override
  MediaStreamTrack? get processedTrack => null;
}

/// Fake processor implementing the landed MicNoiseProcessor shape, with
/// call counters so the tests can prove lifecycle ownership. Each
/// buildProcessor() call returns a FRESH TrackProcessor (the pipeline
/// contract: a built processor is one-shot per mic track), recorded in
/// [built] in build order.
class _FakeMicAudioProcessor implements MicNoiseProcessor {
  _FakeMicAudioProcessor({this.initResult = true, this.buildNull = false});

  final bool initResult;
  final bool buildNull;
  int initializeCalls = 0;
  int buildProcessorCalls = 0;
  int disposeCalls = 0;
  final List<_FakeTrackProcessor> built = <_FakeTrackProcessor>[];

  @override
  Future<bool> initialize() async {
    initializeCalls++;
    return initResult;
  }

  @override
  Future<TrackProcessor<AudioProcessorOptions>?> buildProcessor() async {
    buildProcessorCalls++;
    if (buildNull) return null;
    final processor = _FakeTrackProcessor();
    built.add(processor);
    return processor;
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
  }
}

String _planText() =>
    File('AUDIO_TEST_PLAN.md').readAsStringSync().toLowerCase();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ------------------------------------------------------------------
  // A. Playback effects — method-channel contract (mocked channel).
  // Rewritten: the landed service methods are called directly, and A6
  // wires PlaybackEffects to the REAL effect instances (the aggregator
  // itself has no setReverb/setEcho/... setters — it pushes presets
  // through the five injected tear-offs).
  // ------------------------------------------------------------------
  group('A. Playback effects channel contract', () {
    late List<MethodCall> calls;

    setUp(() {
      calls = _mockEffectsChannel();
    });

    tearDown(_unmockEffectsChannel);

    test('A1 setAmount invokes setReverb on arena_audio/effects', () async {
      final reverb = ReverbEffect();
      await reverb.setAmount(0.5);
      expect(calls, hasLength(1));
      expect(calls.single.method, 'setReverb');
      expect(calls.single.arguments, isA<Map>());
      final args = calls.single.arguments as Map;
      _expectNumericPayload(args);
      expect(args['amount'], 0.5);
    });

    test('A2 setEcho invokes setEcho on arena_audio/effects', () async {
      final echo = EchoDelayEffect();
      await echo.setEcho(0.4);
      expect(calls, hasLength(1));
      expect(calls.single.method, 'setEcho');
      expect(calls.single.arguments, isA<Map>());
      final args = calls.single.arguments as Map;
      _expectNumericPayload(args);
      expect(args['amount'], 0.4);
    });

    test('A3 setDelayMs invokes setDelay on arena_audio/effects', () async {
      final echo = EchoDelayEffect();
      await echo.setDelayMs(300.0);
      expect(calls, hasLength(1));
      expect(calls.single.method, 'setDelay');
      expect(calls.single.arguments, isA<Map>());
      final args = calls.single.arguments as Map;
      _expectNumericPayload(args);
      // Landed arg key is 'ms', not 'delayMs' (see header finding F5).
      expect(args['ms'], 300.0);
    });

    test('A4 setBass invokes setBass on arena_audio/effects', () async {
      final bass = BassEqEffect();
      await bass.setBass(0.6);
      expect(calls, hasLength(1));
      expect(calls.single.method, 'setBass');
      expect(calls.single.arguments, isA<Map>());
      final args = calls.single.arguments as Map;
      _expectNumericPayload(args);
      expect(args['amount'], 0.6);
    });

    test('A5 setEqBand invokes setEq on arena_audio/effects', () async {
      final bass = BassEqEffect();
      await bass.setEqBand(2, 6.0);
      expect(calls, hasLength(1));
      expect(calls.single.method, 'setEq');
      expect(calls.single.arguments, isA<Map>());
      final args = calls.single.arguments as Map;
      _expectNumericPayload(args);
      expect(args['band'], 2);
      expect(args['gainDb'], 6.0);
    });

    test('A6 Room preset values pass through to the channel', () async {
      final reverb = ReverbEffect();
      final echo = EchoDelayEffect();
      final bass = BassEqEffect();
      final fx = PlaybackEffects(
        setReverbAmount: reverb.setAmount,
        setEchoAmount: echo.setEcho,
        setEchoDelayMs: echo.setDelayMs,
        setBassAmount: bass.setBass,
        setEqBand: bass.setEqBand,
      );
      await fx.applyPreset('Room');
      expect(calls.map((c) => c.method).toList(),
          ['setReverb', 'setEcho', 'setDelay', 'setBass', 'setEq']);
      expect((calls[0].arguments as Map)['amount'], 0.35);
      expect((calls[1].arguments as Map)['amount'], 0.15);
      expect((calls[2].arguments as Map)['ms'], 180.0);
      expect((calls[3].arguments as Map)['amount'], 0.30);
      final eqArgs = calls[4].arguments as Map;
      expect(eqArgs['band'], 0);
      expect(eqArgs['gainDb'], 3.0);
      expect(fx.currentPreset, 'Room');
    });

    test('A7 zero amount is the off state (no enabled flag in the landed API)',
        () async {
      final reverb = ReverbEffect();
      final echo = EchoDelayEffect();
      final bass = BassEqEffect();
      await reverb.setAmount(0.0);
      await echo.setEcho(0.0);
      await bass.setBass(0.0);
      expect(calls, hasLength(3));
      for (final call in calls) {
        expect((call.arguments as Map)['amount'], 0.0);
      }
    });

    test('A8 sequential calls arrive on the channel in order', () async {
      await ReverbEffect().setAmount(0.3);
      await BassEqEffect().setBass(0.4);
      await BassEqEffect().setEqBand(0, 2.0);
      expect(calls.map((c) => c.method).toList(),
          ['setReverb', 'setBass', 'setEq']);
    });

    test(
        'A9 fresh PlaybackEffects defaults to Off/enabled/unattached; construction sends nothing',
        () async {
      final fx = PlaybackEffects(
        setReverbAmount: (_) async {},
        setEchoAmount: (_) async {},
        setEchoDelayMs: (_) async {},
        setBassAmount: (_) async {},
        setEqBand: (_, __) async {},
      );
      expect(fx.currentPreset, 'Off');
      expect(fx.isEnabled, isTrue);
      expect(fx.isAttached, isFalse);
      expect(fx.attachedPlayerId, isNull);
      expect(fx.bridgeAvailable, isFalse);
      expect(fx.sessionInfo, isNull);
      // Constructing the effect services also sends nothing.
      final reverb = ReverbEffect();
      final echo = EchoDelayEffect();
      final bass = BassEqEffect();
      expect(reverb.isDisposed, isFalse);
      expect(echo.amount, 0.0);
      expect(bass, isA<BassEqEffect>());
      expect(calls, isEmpty);
      await fx.dispose();
    });

    test('A10 platform error propagates typed and never hangs', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel(_channelName),
        (MethodCall call) async {
          throw PlatformException(code: 'UNAVAILABLE');
        },
      );
      final reverb = ReverbEffect();
      // Landed contract: a PlatformException from the native side
      // propagates to the caller (it must never hang or crash untyped).
      await expectLater(
        reverb.setAmount(0.5),
        throwsA(isA<PlatformException>()),
      );
    });
  });

  // ------------------------------------------------------------------
  // B. Effect shapes: defaults, clamping, round-trips.
  // Rewritten: the assumed value-object classes (EchoEffect/DelayEffect/
  // BassEffect/EqEffect with enabled/toMap/defaults) DO NOT EXIST, so
  // each test asserts the closest landed equivalent — clamping /
  // defaults / round-trip via the service methods + mocked channel.
  // Out-of-range input must be CLAMPED into range — never silently
  // passed through. See the header comment for the per-test mapping.
  // ------------------------------------------------------------------
  group('B. Effect shapes', () {
    late List<MethodCall> calls;

    setUp(() {
      calls = _mockEffectsChannel();
    });

    tearDown(_unmockEffectsChannel);

    test(
        'B1 ReverbEffect starts with no applied amount (lastAmount null, nothing sent)',
        () {
      final reverb = ReverbEffect();
      expect(reverb.lastAmount, isNull);
      expect(reverb.isDisposed, isFalse);
      expect(calls, isEmpty);
    });

    test('B2 ReverbEffect setAmount clamps out-of-range input (2.5 -> 1.0, NaN -> 0.0)',
        () async {
      final reverb = ReverbEffect();
      await reverb.setAmount(2.5);
      await reverb.setAmount(double.nan);
      expect(calls, hasLength(2));
      expect((calls[0].arguments as Map)['amount'], 1.0);
      expect((calls[1].arguments as Map)['amount'], 0.0);
      expect(reverb.lastAmount, 0.0);
    });

    test('B3 ReverbEffect setAmount round-trips via the channel payload + lastAmount',
        () async {
      final reverb = ReverbEffect();
      await reverb.setAmount(0.7);
      expect((calls.single.arguments as Map)['amount'], 0.7);
      expect(reverb.lastAmount, 0.7);
    });

    test('B4 EchoDelayEffect defaults: amount 0.0, delayMs 250.0', () {
      final echo = EchoDelayEffect();
      expect(echo.amount, 0.0);
      expect(echo.delayMs, 250.0);
      expect(EchoDelayEffect.defaultDelayMs, 250.0);
      expect(calls, isEmpty);
    });

    test('B5 EchoDelayEffect setEcho clamps out-of-range input (-1.0 -> 0.0, NaN -> 0.0)',
        () async {
      final echo = EchoDelayEffect();
      await echo.setEcho(-1.0);
      await echo.setEcho(double.nan);
      expect(calls, hasLength(2));
      expect((calls[0].arguments as Map)['amount'], 0.0);
      expect((calls[1].arguments as Map)['amount'], 0.0);
      expect(echo.amount, 0.0);
    });

    test('B6 EchoDelayEffect values round-trip via channel + getters',
        () async {
      final echo = EchoDelayEffect();
      await echo.setEcho(0.5);
      await echo.setDelayMs(450.0);
      expect(calls, hasLength(2));
      expect(calls[0].method, 'setEcho');
      expect((calls[0].arguments as Map)['amount'], 0.5);
      expect(calls[1].method, 'setDelay');
      expect((calls[1].arguments as Map)['ms'], 450.0);
      expect(echo.amount, 0.5);
      expect(echo.delayMs, 450.0);
    });

    test('B7 EchoDelayEffect setDelayMs forwards the max delay (2000 ms)',
        () async {
      final echo = EchoDelayEffect();
      expect(EchoDelayEffect.maxDelayMs, 2000.0);
      await echo.setDelayMs(2000.0);
      expect((calls.single.arguments as Map)['ms'], 2000.0);
      expect(echo.delayMs, 2000.0);
    });

    test('B8 EchoDelayEffect setDelayMs clamps to 0-2000 (3000 -> 2000, -5 -> 0)',
        () async {
      final echo = EchoDelayEffect();
      await echo.setDelayMs(3000.0);
      await echo.setDelayMs(-5.0);
      expect(calls, hasLength(2));
      expect((calls[0].arguments as Map)['ms'], 2000.0);
      expect((calls[1].arguments as Map)['ms'], 0.0);
      expect(echo.delayMs, 0.0);
    });

    test('B9 EchoDelayEffect setDelayMs round-trips via channel + getter',
        () async {
      final echo = EchoDelayEffect();
      await echo.setDelayMs(200.0);
      expect(calls.single.method, 'setDelay');
      expect((calls.single.arguments as Map)['ms'], 200.0);
      expect(echo.delayMs, 200.0);
    });

    test('B10 BassEqEffect setBass(0.0) sends the flat/off amount', () async {
      final bass = BassEqEffect();
      await bass.setBass(0.0);
      expect(calls.single.method, 'setBass');
      expect((calls.single.arguments as Map)['amount'], 0.0);
    });

    test('B11 BassEqEffect setBass clamps out-of-range input (2.0 -> 1.0, -0.5 -> 0.0)',
        () async {
      final bass = BassEqEffect();
      await bass.setBass(2.0);
      await bass.setBass(-0.5);
      expect(calls, hasLength(2));
      expect((calls[0].arguments as Map)['amount'], 1.0);
      expect((calls[1].arguments as Map)['amount'], 0.0);
    });

    test('B12 BassEqEffect setBass round-trips via the channel payload',
        () async {
      final bass = BassEqEffect();
      await bass.setBass(0.6);
      expect((calls.single.arguments as Map)['amount'], 0.6);
    });

    test('B13 BassEqEffect setEqBand(0, 0.0) sends a flat band', () async {
      final bass = BassEqEffect();
      await bass.setEqBand(0, 0.0);
      expect(calls.single.method, 'setEq');
      final args = calls.single.arguments as Map;
      expect(args['band'], 0);
      expect(args['gainDb'], 0.0);
    });

    test('B14 BassEqEffect setEqBand clamps gain to +/-15 dB (50 -> 15, -50 -> -15)',
        () async {
      final bass = BassEqEffect();
      expect(BassEqEffect.maxGainDb, 15.0);
      expect(BassEqEffect.minGainDb, -15.0);
      await bass.setEqBand(1, 50.0);
      await bass.setEqBand(1, -50.0);
      expect(calls, hasLength(2));
      expect((calls[0].arguments as Map)['gainDb'], 15.0);
      expect((calls[1].arguments as Map)['gainDb'], -15.0);
    });

    test('B15 BassEqEffect setEqBand round-trips each band + gain', () async {
      final bass = BassEqEffect();
      await bass.setEqBand(0, 3.0);
      await bass.setEqBand(1, -2.0);
      await bass.setEqBand(2, 0.0);
      expect(calls, hasLength(3));
      expect(calls.map((c) => c.method).toList(), ['setEq', 'setEq', 'setEq']);
      expect((calls[0].arguments as Map)['band'], 0);
      expect((calls[0].arguments as Map)['gainDb'], 3.0);
      expect((calls[1].arguments as Map)['band'], 1);
      expect((calls[1].arguments as Map)['gainDb'], -2.0);
      expect((calls[2].arguments as Map)['band'], 2);
      expect((calls[2].arguments as Map)['gainDb'], 0.0);
    });
  });

  // ------------------------------------------------------------------
  // C. MicAudioPipeline lifecycle + noise cancellation.
  // Rewritten against the real API: setProcessor(MicNoiseProcessor?) /
  // setNoiseCancellationEnabled / prepareForPublish / markProcessorDetached
  // / captureOptions / dispose. No initialize()/isInitialized/
  // buildProcessor() on the pipeline — install IS setProcessor, and the
  // pipeline initializes the processor itself. Uses a small fake
  // MicNoiseProcessor (same pattern as
  // test/audio_mic_pipeline_verify_test.dart); C10 also exercises the
  // two REAL processors (Krisp fails open on Linux, RNNoise installs
  // via its spectral-gate fallback).
  // ------------------------------------------------------------------
  group('C. MicAudioPipeline lifecycle', () {
    test('C1 setProcessor installs the processor; NC defaults OFF', () async {
      final pipeline = MicAudioPipeline();
      final fake = _FakeMicAudioProcessor();
      final ok = await pipeline.setProcessor(fake);
      expect(ok, isTrue);
      expect(fake.initializeCalls, 1);
      expect(fake.buildProcessorCalls, 1);
      expect(pipeline.hasProcessor, isTrue);
      expect(pipeline.processorName, 'fake-noise-processor');
      // Default is OFF (explicit opt-in): installed but not supplied.
      expect(pipeline.noiseCancellationEnabled, isFalse);
      expect(pipeline.processor, isNull);
      pipeline.setNoiseCancellationEnabled(true);
      expect(pipeline.processor, same(fake.built.single));
      expect(pipeline.activeProcessor, same(fake.built.single));
      await pipeline.dispose();
    });

    test('C2 setProcessor(null) removes the processor and disposes it',
        () async {
      final pipeline = MicAudioPipeline();
      final fake = _FakeMicAudioProcessor();
      await pipeline.setProcessor(fake);
      pipeline.setNoiseCancellationEnabled(true);
      expect(pipeline.processor, isNotNull);
      final removed = await pipeline.setProcessor(null);
      expect(removed, isTrue);
      expect(pipeline.hasProcessor, isFalse);
      expect(pipeline.processor, isNull);
      expect(pipeline.processorName, isNull);
      expect(fake.disposeCalls, 1);
      await pipeline.dispose();
    });

    test('C3 replacing a processor disposes the old one, supplies the new one',
        () async {
      final pipeline = MicAudioPipeline();
      final first = _FakeMicAudioProcessor();
      final second = _FakeMicAudioProcessor();
      await pipeline.setProcessor(first);
      await pipeline.setProcessor(second);
      pipeline.setNoiseCancellationEnabled(true);
      expect(first.disposeCalls, 1);
      expect(second.initializeCalls, 1);
      expect(pipeline.processor, same(second.built.single));
      await pipeline.dispose();
    });

    test(
        'C4 NC off stops supplying via captureOptions WITHOUT disposing; NC on restores the SAME instance',
        () async {
      final pipeline = MicAudioPipeline();
      final fake = _FakeMicAudioProcessor();
      await pipeline.setProcessor(fake);
      pipeline.setNoiseCancellationEnabled(true);
      expect(pipeline.captureOptions().processor, same(fake.built.single));
      pipeline.setNoiseCancellationEnabled(false);
      expect(pipeline.captureOptions().processor, isNull);
      expect(pipeline.hasProcessor, isTrue,
          reason: 'the source survives an NC-off toggle');
      expect(fake.disposeCalls, 0);
      pipeline.setNoiseCancellationEnabled(true);
      expect(pipeline.captureOptions().processor, same(fake.built.single));
      expect(fake.initializeCalls, 1,
          reason: 're-enabling NC must not re-initialize the processor');
      await pipeline.dispose();
    });

    test('C5 setNoiseCancellationEnabled(true) is reflected by the pipeline',
        () async {
      final pipeline = MicAudioPipeline();
      await pipeline.setProcessor(_FakeMicAudioProcessor());
      pipeline.setNoiseCancellationEnabled(true);
      expect(pipeline.noiseCancellationEnabled, isTrue);
      expect(pipeline.captureOptions().processor, isNotNull);
      await pipeline.dispose();
    });

    test('C6 NC toggle round-trips true-false-true', () async {
      final pipeline = MicAudioPipeline();
      await pipeline.setProcessor(_FakeMicAudioProcessor());
      pipeline.setNoiseCancellationEnabled(true);
      expect(pipeline.noiseCancellationEnabled, isTrue);
      expect(pipeline.captureOptions().processor, isNotNull);
      pipeline.setNoiseCancellationEnabled(false);
      expect(pipeline.noiseCancellationEnabled, isFalse);
      expect(pipeline.captureOptions().processor, isNull);
      pipeline.setNoiseCancellationEnabled(true);
      expect(pipeline.noiseCancellationEnabled, isTrue);
      expect(pipeline.captureOptions().processor, isNotNull);
      await pipeline.dispose();
    });

    test(
        'C7 prepareForPublish rebuilds a FRESH processor after markProcessorDetached',
        () async {
      final pipeline = MicAudioPipeline();
      final fake = _FakeMicAudioProcessor();
      await pipeline.setProcessor(fake);
      pipeline.setNoiseCancellationEnabled(true);
      final first = pipeline.processor;
      expect(first, same(fake.built.single));
      pipeline.markProcessorDetached();
      expect(pipeline.processor, isNull);
      expect(pipeline.hasProcessor, isTrue);
      await pipeline.prepareForPublish();
      expect(fake.buildProcessorCalls, 2);
      expect(fake.built, hasLength(2));
      expect(pipeline.processor, same(fake.built[1]));
      expect(pipeline.processor, isNot(same(first)));
      await pipeline.dispose();
    });

    test('C8 prepareForPublish is a no-op while NC is off; rebuilds once NC is on',
        () async {
      final pipeline = MicAudioPipeline();
      final fake = _FakeMicAudioProcessor();
      await pipeline.setProcessor(fake);
      pipeline.setNoiseCancellationEnabled(true);
      pipeline.markProcessorDetached();
      pipeline.setNoiseCancellationEnabled(false);
      await pipeline.prepareForPublish();
      expect(fake.buildProcessorCalls, 1,
          reason: 'no wasted builds while NC is off');
      expect(pipeline.processor, isNull);
      pipeline.setNoiseCancellationEnabled(true);
      await pipeline.prepareForPublish();
      expect(fake.buildProcessorCalls, 2);
      expect(pipeline.processor, same(fake.built[1]));
      await pipeline.dispose();
    });

    test('C9 fail-open: a processor that cannot initialize installs nothing',
        () async {
      final pipeline = MicAudioPipeline();
      final badInit = _FakeMicAudioProcessor(initResult: false);
      final okInit = await pipeline.setProcessor(badInit);
      expect(okInit, isFalse);
      expect(pipeline.hasProcessor, isFalse);
      expect(pipeline.processor, isNull);
      expect(pipeline.captureOptions().processor, isNull);
      expect(badInit.buildProcessorCalls, 0);
      expect(badInit.disposeCalls, 1);
      // Same fail-open outcome when buildProcessor() returns null.
      final nullBuild = _FakeMicAudioProcessor(buildNull: true);
      final okBuild = await pipeline.setProcessor(nullBuild);
      expect(okBuild, isFalse);
      expect(pipeline.hasProcessor, isFalse);
      expect(nullBuild.disposeCalls, 1);
      await pipeline.dispose();
    });

    test(
        'C10 real processors: Krisp fails open where unsupported; RNNoise installs via its fallback',
        () async {
      final pipeline = MicAudioPipeline();
      // Krisp: unsupported on Linux (LiveKitNoiseFilter.isSupported()
      // is false by plugin design), so install fails soft here — and
      // wherever it fails, the pipeline must report exactly that (no
      // phantom install).
      final krisp = KrispMicProcessor();
      final krispOk = await pipeline.setProcessor(krisp);
      expect(pipeline.hasProcessor, krispOk,
          reason: 'hasProcessor must agree with the setProcessor result');
      if (Platform.isLinux) {
        expect(krispOk, isFalse, reason: 'Krisp is unsupported on Linux');
        expect(pipeline.processor, isNull);
      }
      // RNNoise: initialize() succeeds on every platform by design (a
      // missing native side just selects the spectral-gate fallback),
      // so install succeeds and the mic gets a real processor.
      final rnnoise = RnnoiseMicProcessor();
      final rnnoiseOk = await pipeline.setProcessor(rnnoise);
      expect(rnnoiseOk, isTrue);
      expect(pipeline.hasProcessor, isTrue);
      expect(pipeline.processorName, 'RnnoiseMicProcessor');
      pipeline.setNoiseCancellationEnabled(true);
      expect(pipeline.captureOptions().processor, isNotNull);
      await pipeline.dispose();
    });

    test('C11 dispose clears the processor and the NC flag', () async {
      final pipeline = MicAudioPipeline();
      final fake = _FakeMicAudioProcessor();
      await pipeline.setProcessor(fake);
      pipeline.setNoiseCancellationEnabled(true);
      expect(pipeline.processor, isNotNull);
      await pipeline.dispose();
      expect(pipeline.hasProcessor, isFalse);
      expect(pipeline.processor, isNull);
      expect(pipeline.processorName, isNull);
      expect(pipeline.noiseCancellationEnabled, isFalse);
      expect(pipeline.captureOptions().processor, isNull);
      expect(fake.disposeCalls, 1);
    });

    test(
        'C12 double dispose is safe; setProcessor after dispose fails open (returns false)',
        () async {
      final pipeline = MicAudioPipeline();
      final fake = _FakeMicAudioProcessor();
      await pipeline.setProcessor(fake);
      await pipeline.dispose();
      await pipeline.dispose();
      expect(fake.disposeCalls, 1);
      final late = _FakeMicAudioProcessor();
      final ok = await pipeline.setProcessor(late);
      expect(ok, isFalse);
      expect(pipeline.hasProcessor, isFalse);
      // The late arrival is disposed instead of installed, never initialized.
      expect(late.initializeCalls, 0);
      expect(late.disposeCalls, 1);
      // The NC switch is a no-op after dispose.
      pipeline.setNoiseCancellationEnabled(true);
      expect(pipeline.noiseCancellationEnabled, isFalse);
    });
  });

  // ------------------------------------------------------------------
  // D. AUDIO_TEST_PLAN.md checklist (on-device plan, project root).
  // Mechanical floor only — phase 2 also READS the plan and judges
  // whether each section is genuinely usable, not just mentioned.
  // KEPT AS-IS from phase 1 (2026-11-22 rewrite: untouched).
  // ------------------------------------------------------------------
  group('D. AUDIO_TEST_PLAN.md checklist', () {
    test('D1 plan file exists and is non-trivial', () {
      final text = _planText();
      expect(text.length, greaterThan(200));
    });

    test('D2 plan covers reverb', () {
      expect(_planText(), contains('reverb'));
    });

    test('D3 plan covers echo', () {
      expect(_planText(), contains('echo'));
    });

    test('D4 plan covers delay', () {
      expect(_planText(), contains('delay'));
    });

    test('D5 plan covers bass', () {
      expect(_planText(), contains('bass'));
    });

    test('D6 plan covers eq', () {
      expect(_planText(), contains('eq'));
    });

    test('D7 plan says what to tap and what to listen for', () {
      final text = _planText();
      expect(text, contains('tap'));
      expect(text, contains('listen'));
    });

    test('D8 plan covers noise suppression on AND off', () {
      final text = _planText();
      expect(text.contains('noise suppression') || text.contains('ns'),
          isTrue);
      expect(text, contains('on'));
      expect(text, contains('off'));
    });

    test('D9 plan tells how to measure latency', () {
      final text = _planText();
      expect(text, contains('latency'));
      expect(text.contains('ms') || text.contains('millisecond'), isTrue);
    });

    test('D10 plan tells how to measure CPU', () {
      expect(_planText(), contains('cpu'));
    });

    test('D11 plan states pass/fail criteria', () {
      final text = _planText();
      expect(text, contains('pass'));
      expect(text, contains('fail'));
    });

    test('D12 plan covers the mic path (not only playback)', () {
      expect(_planText(), contains('mic'));
    });
  });
}
