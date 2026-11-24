// GROUP 7 DSP — AUDIO #10: tests for the DSP-engine mic processor
// (lib/services/dsp_mic_processor.dart) + source pins for the native
// mic glue (Kotlin + JNI + C++ bridge) that no Dart test can execute.
//
// RJ STUDIO EVOLUTION (2026-11-22): the host mic chain is the v3
// engine's full chain (Gate -> Compressor -> EQ -> Echo -> Reverb),
// full-band when numBands == 1 and per-band full-chain (EQ on band 0
// only) when split — see dsp_mic_bridge.h. The live setters
// (setEq/setEcho/setReverb/setNoiseGate/setCompressor) forward over
// the mocked arena_hub_dsp_mic channel and are pinned here,
// including the no-op-when-native-absent behaviour and the live
// contract (param changes never touch the track).
//
// What these tests CAN prove: the Dart control plane (isAvailable
// ping / EQ preset / bypass / attach / detach / diagnostics over the
// mocked arena_hub_dsp_mic channel), the MicNoiseProcessor contract
// against the real MicAudioPipeline, and that the native glue files
// contain the hook they must contain.
//
// What they CANNOT prove: that live mic audio actually flows through
// the C++ engine. That needs a phone (mic + WebRTC APM + native .so)
// and is verified by the first device run, which logs the observed
// buffer layout from DspMicAudioProcessor. Never claim live-mic
// success from these tests alone.
//
// The C++ bridge itself is verified on the host separately
// (/tmp/dsp_mic_rj_bridge_check.cpp) — the float/int16 routing, the
// float sanity check, the full-band + per-band full-chain processing,
// the pending preset, and the live gate/compressor params.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:protournament_user/services/dsp_mic_processor.dart';
import 'package:protournament_user/services/mic_audio_pipeline.dart';

String _read(String path) => File(path).readAsStringSync();

class _FakeTrack extends rtc.MediaStreamTrack {
  _FakeTrack(this._id);

  final String _id;

  @override
  String? get id => _id;

  @override
  String? get label => 'fake mic';

  @override
  String? get kind => 'audio';

  @override
  bool get enabled => true;

  @override
  set enabled(bool b) {}

  @override
  bool? get muted => false;

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}
}

class _FakeNoiseProcessor implements MicNoiseProcessor {
  _FakeNoiseProcessor(this._name);

  final String _name;

  @override
  Future<bool> initialize() async => true;

  @override
  Future<lk.TrackProcessor<lk.AudioProcessorOptions>?>
  buildProcessor() async => null;

  @override
  Future<void> dispose() async {}

  @override
  String toString() => _name;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('arena_hub_dsp_mic');
  late List<MethodCall> calls;
  var nativeAvailable = true;

  setUp(() {
    calls = <MethodCall>[];
    nativeAvailable = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          calls.add(call);
          switch (call.method) {
            case 'isAvailable':
              return nativeAvailable;
            case 'init':
            case 'restart':
            case 'setBypass':
              return true;
            case 'framesProcessed':
              return 42;
            case 'lastError':
              return 0;
            default:
              return null;
          }
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  List<MethodCall> callsTo(String method) =>
      calls.where((c) => c.method == method).toList();

  group('DspMicProcessor control plane', () {
    test('isSupported is false on the Linux test host', () {
      expect(DspMicProcessor.isSupported(), isFalse);
    });

    test('initialize pings isAvailable and sends the voice preset', () async {
      final processor = DspMicProcessor();
      expect(await processor.initialize(), isTrue);
      expect(processor.isInitialized, isTrue);
      expect(processor.isNativeAvailable, isTrue);

      expect(callsTo('isAvailable'), hasLength(1));
      // The voice preset is sent at initialize so the native bridge
      // stores it before the engine is created on the first frame.
      final set = callsTo('setEq');
      expect(set, hasLength(1));
      final args = set.single.arguments as Map<dynamic, dynamic>;
      expect(args['enabled'], isTrue);
      expect(args['bassDb'], DspMicEqPreset.voice.bassBoostDb);
      expect(args['lowDb'], DspMicEqPreset.voice.lowGainDb);
      expect(args['midDb'], DspMicEqPreset.voice.midGainDb);
      expect(args['highDb'], DspMicEqPreset.voice.highGainDb);
    });

    test('initialize is idempotent — second call pings nothing', () async {
      final processor = DspMicProcessor();
      expect(await processor.initialize(), isTrue);
      expect(await processor.initialize(), isTrue);
      expect(callsTo('isAvailable'), hasLength(1));
      expect(callsTo('setEq'), hasLength(1));
    });

    test('initialize false when native side answers unavailable', () async {
      nativeAvailable = false;
      final processor = DspMicProcessor();
      expect(await processor.initialize(), isFalse);
      expect(processor.isInitialized, isFalse);
      expect(processor.isNativeAvailable, isFalse);
      expect(await processor.buildProcessor(), isNull);
      // No preset sent to a native side that is not there.
      expect(callsTo('setEq'), isEmpty);
    });

    test('initialize false when the native plugin is missing', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      final processor = DspMicProcessor();
      expect(await processor.initialize(), isFalse);
      expect(await processor.buildProcessor(), isNull);
    });

    test('buildProcessor returns the DSP track processor', () async {
      final processor = DspMicProcessor();
      await processor.initialize();
      final built = await processor.buildProcessor();
      expect(built, isNotNull);
      expect(built, isA<lk.TrackProcessor<lk.AudioProcessorOptions>>());
      expect(built, isA<DspMicTrackProcessor>());
      expect(built!.name, 'DspMicProcessor');
      // In-place processor: no replacement track.
      expect(built.processedTrack, isNull);
      expect(processor.hasActiveProcessor, isTrue);
    });

    test('buildProcessor is null before initialize', () async {
      final processor = DspMicProcessor();
      expect(await processor.buildProcessor(), isNull);
    });

    test('building twice destroys the previous processor first', () async {
      final processor = DspMicProcessor();
      await processor.initialize();
      final first = await processor.buildProcessor();
      expect(first, isNotNull);
      final second = await processor.buildProcessor();
      expect(second, isNotNull);
      expect(second, isNot(same(first)));
      // The first processor was destroyed (its destroy() call went out).
      expect(callsTo('destroy'), hasLength(1));
    });

    test('track processor init sends trackId and reports nativeActive',
        () async {
      final processor = DspMicProcessor();
      await processor.initialize();
      final built =
          (await processor.buildProcessor())! as DspMicTrackProcessor;
      await built.init(
        lk.AudioProcessorOptions(track: _FakeTrack('mic-track-1')),
      );
      expect(built.nativeActive, isTrue);
      final initCalls = callsTo('init');
      expect(initCalls, hasLength(1));
      final args = initCalls.single.arguments as Map<dynamic, dynamic>;
      expect(args['trackId'], 'mic-track-1');
    });

    test('track processor init fails open when the plugin is missing',
        () async {
      final processor = DspMicProcessor();
      await processor.initialize();
      final built =
          (await processor.buildProcessor())! as DspMicTrackProcessor;
      // The native side vanished between build and init (e.g. the
      // channel was never registered): no throw, nativeActive false.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      await built.init(
        lk.AudioProcessorOptions(track: _FakeTrack('mic-track-1')),
      );
      expect(built.nativeActive, isFalse);
    });

    test('track processor restart re-sends the trackId', () async {
      final processor = DspMicProcessor();
      await processor.initialize();
      final built =
          (await processor.buildProcessor())! as DspMicTrackProcessor;
      await built.init(
        lk.AudioProcessorOptions(track: _FakeTrack('mic-track-1')),
      );
      await built.restart(
        lk.AudioProcessorOptions(track: _FakeTrack('mic-track-2')),
      );
      expect(built.nativeActive, isTrue);
      final restarts = callsTo('restart');
      expect(restarts, hasLength(1));
      expect(
        (restarts.single.arguments as Map)['trackId'],
        'mic-track-2',
      );
    });

    test('track processor destroy is idempotent — one channel call',
        () async {
      final processor = DspMicProcessor();
      await processor.initialize();
      final built =
          (await processor.buildProcessor())! as DspMicTrackProcessor;
      await built.init(
        lk.AudioProcessorOptions(track: _FakeTrack('mic-track-1')),
      );
      await built.destroy();
      await built.destroy();
      expect(callsTo('destroy'), hasLength(1));
      expect(built.nativeActive, isFalse);
    });

    test('onPublish / onUnpublish are forwarded (native no-ops them)',
        () async {
      final processor = DspMicProcessor();
      await processor.initialize();
      final built = (await processor.buildProcessor())!;
      calls.clear();
      await built.onPublish(lk.Room());
      await built.onUnpublish();
      expect(calls.map((c) => c.method).toList(), [
        'onPublish',
        'onUnpublish',
      ]);
    });

    test('setEqPreset sends the gains with the Kotlin arg keys', () async {
      const preset = DspMicEqPreset(
        bassBoostDb: 1.0,
        lowGainDb: -2.0,
        midGainDb: 3.0,
        highGainDb: 4.0,
      );
      final processor = DspMicProcessor();
      await processor.initialize();
      calls.clear();
      expect(await processor.setEqPreset(preset), isTrue);
      final set = callsTo('setEq');
      expect(set, hasLength(1));
      final args = set.single.arguments as Map<dynamic, dynamic>;
      expect(args['enabled'], isTrue);
      // Keys must match DspMicProcessor.kt: bassDb/lowDb/midDb/highDb.
      expect(args['bassDb'], 1.0);
      expect(args['lowDb'], -2.0);
      expect(args['midDb'], 3.0);
      expect(args['highDb'], 4.0);
    });

    test('setEqPreset clamps gains to the engine ranges', () async {
      const preset = DspMicEqPreset(
        bassBoostDb: -5.0, // clamps to 0
        lowGainDb: 99.0, // clamps to 12
        midGainDb: -99.0, // clamps to -12
        highGainDb: 3.0,
      );
      final processor = DspMicProcessor();
      await processor.initialize();
      calls.clear();
      await processor.setEqPreset(preset);
      final args =
          callsTo('setEq').single.arguments as Map<dynamic, dynamic>;
      expect(args['bassDb'], 0.0);
      expect(args['lowDb'], 12.0);
      expect(args['midDb'], -12.0);
      expect(args['highDb'], 3.0);
    });

    test('setBypass routes to the native engine; false when missing',
        () async {
      final processor = DspMicProcessor();
      await processor.initialize();
      expect(await processor.setBypass(true), isTrue);
      expect(await processor.setBypass(false), isTrue);
      expect(callsTo('setBypass'), hasLength(2));
      expect(
        (callsTo('setBypass')[0].arguments as Map)['bypass'],
        isTrue,
      );
      expect(
        (callsTo('setBypass')[1].arguments as Map)['bypass'],
        isFalse,
      );

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      expect(await processor.setBypass(true), isFalse);
    });

    test('framesProcessed / lastError diagnostics; -1 when missing',
        () async {
      final processor = DspMicProcessor();
      await processor.initialize();
      expect(await processor.framesProcessed(), 42);
      expect(await processor.lastError(), 0);

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      expect(await processor.framesProcessed(), -1);
      expect(await processor.lastError(), -1);
    });

    test('dispose destroys the active processor once; safe before init',
        () async {
      final uninitialized = DspMicProcessor();
      await uninitialized.dispose(); // no processor — no channel call
      expect(callsTo('destroy'), isEmpty);

      final processor = DspMicProcessor();
      await processor.initialize();
      await processor.buildProcessor();
      await processor.dispose();
      await processor.dispose();
      expect(callsTo('destroy'), hasLength(1));
      expect(processor.isInitialized, isFalse);
      expect(processor.hasActiveProcessor, isFalse);
      // After dispose the processor is dead: no re-init, no build.
      expect(await processor.initialize(), isFalse);
      expect(await processor.buildProcessor(), isNull);
    });
  });

  group('live param forwarding (RJ Studio)', () {
    test('setEq sends the 4 dB values with the Kotlin arg keys', () async {
      final processor = DspMicProcessor();
      await processor.initialize();
      calls.clear();
      expect(
        await processor.setEq(
          bassBoostDb: 2.0,
          lowGainDb: -1.0,
          midGainDb: 3.0,
          highGainDb: 4.5,
        ),
        isTrue,
      );
      final set = callsTo('setEq');
      expect(set, hasLength(1));
      final args = set.single.arguments as Map<dynamic, dynamic>;
      expect(args['enabled'], isTrue);
      // Keys must match DspMicProcessor.kt: bassDb/lowDb/midDb/highDb
      // (same keys as setEqPreset — one channel method, two Dart
      // forms: the preset form and the per-knob form the RJ panel
      // drives via RjVoiceDsp).
      expect(args['bassDb'], 2.0);
      expect(args['lowDb'], -1.0);
      expect(args['midDb'], 3.0);
      expect(args['highDb'], 4.5);
    });

    test('setEq with enabled false bypasses the EQ stage', () async {
      final processor = DspMicProcessor();
      await processor.initialize();
      calls.clear();
      expect(await processor.setEq(enabled: false), isTrue);
      final args =
          callsTo('setEq').single.arguments as Map<dynamic, dynamic>;
      expect(args['enabled'], isFalse);
      expect(args['bassDb'], 0.0);
      expect(args['lowDb'], 0.0);
      expect(args['midDb'], 0.0);
      expect(args['highDb'], 0.0);
    });

    test('setEq clamps gains to the engine ranges; false when absent',
        () async {
      final processor = DspMicProcessor();
      await processor.initialize();
      calls.clear();
      await processor.setEq(
        bassBoostDb: -5.0, // clamps to 0
        lowGainDb: 99.0, // clamps to 12
        midGainDb: -99.0, // clamps to -12
        highGainDb: 3.0,
      );
      final args =
          callsTo('setEq').single.arguments as Map<dynamic, dynamic>;
      expect(args['bassDb'], 0.0);
      expect(args['lowDb'], 12.0);
      expect(args['midDb'], -12.0);
      expect(args['highDb'], 3.0);

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      expect(await processor.setEq(), isFalse);
    });

    test('setEcho sends the method + payload with Kotlin arg keys',
        () async {
      final processor = DspMicProcessor();
      await processor.initialize();
      calls.clear();
      expect(
        await processor.setEcho(
          delayMs: 400.0,
          feedback: 0.5,
          mix: 0.6,
        ),
        isTrue,
      );
      final set = callsTo('setEcho');
      expect(set, hasLength(1));
      final args = set.single.arguments as Map<dynamic, dynamic>;
      expect(args['enabled'], isTrue);
      expect(args['delayMs'], 400.0);
      expect(args['feedback'], 0.5);
      expect(args['mix'], 0.6);
    });

    test('setEcho clamps to the engine ranges', () async {
      final processor = DspMicProcessor();
      await processor.initialize();
      calls.clear();
      await processor.setEcho(
        delayMs: 5000.0, // clamps to 2000
        feedback: 2.0, // clamps to 0.95
        mix: -1.0, // clamps to 0
      );
      final args =
          callsTo('setEcho').single.arguments as Map<dynamic, dynamic>;
      expect(args['delayMs'], 2000.0);
      expect(args['feedback'], 0.95);
      expect(args['mix'], 0.0);
    });

    test('setReverb sends the method + payload and clamps', () async {
      final processor = DspMicProcessor();
      await processor.initialize();
      calls.clear();
      expect(
        await processor.setReverb(
          wetDryMix: 0.7,
          roomSize: 0.8,
          damping: 0.2,
        ),
        isTrue,
      );
      var args =
          callsTo('setReverb').single.arguments as Map<dynamic, dynamic>;
      expect(args['enabled'], isTrue);
      expect(args['wetDryMix'], 0.7);
      expect(args['roomSize'], 0.8);
      expect(args['damping'], 0.2);

      calls.clear();
      await processor.setReverb(wetDryMix: 5.0, roomSize: -1.0);
      args = callsTo('setReverb').single.arguments as Map<dynamic, dynamic>;
      expect(args['wetDryMix'], 1.0);
      expect(args['roomSize'], 0.0);
    });

    test('setNoiseGate sends the method + payload and clamps', () async {
      final processor = DspMicProcessor();
      await processor.initialize();
      calls.clear();
      expect(
        await processor.setNoiseGate(
          thresholdDb: -30.0,
          attackMs: 10.0,
          releaseMs: 200.0,
        ),
        isTrue,
      );
      var args =
          callsTo('setNoiseGate').single.arguments as Map<dynamic, dynamic>;
      expect(args['enabled'], isTrue);
      expect(args['thresholdDb'], -30.0);
      expect(args['attackMs'], 10.0);
      expect(args['releaseMs'], 200.0);

      calls.clear();
      await processor.setNoiseGate(
        thresholdDb: 5.0, // clamps to 0
        attackMs: 0.0, // clamps to 0.1
        releaseMs: 9999.0, // clamps to 2000
      );
      args =
          callsTo('setNoiseGate').single.arguments as Map<dynamic, dynamic>;
      expect(args['thresholdDb'], 0.0);
      expect(args['attackMs'], 0.1);
      expect(args['releaseMs'], 2000.0);
    });

    test('setCompressor sends the method + payload and clamps (v3)',
        () async {
      final processor = DspMicProcessor();
      await processor.initialize();
      calls.clear();
      expect(
        await processor.setCompressor(
          thresholdDb: -20.0,
          ratio: 3.0,
          attackMs: 5.0,
          releaseMs: 200.0,
          makeupGainDb: 6.0,
        ),
        isTrue,
      );
      var args =
          callsTo('setCompressor').single.arguments as Map<dynamic, dynamic>;
      expect(args['enabled'], isTrue);
      expect(args['thresholdDb'], -20.0);
      expect(args['ratio'], 3.0);
      expect(args['attackMs'], 5.0);
      expect(args['releaseMs'], 200.0);
      expect(args['makeupGainDb'], 6.0);

      calls.clear();
      await processor.setCompressor(
        thresholdDb: -99.0, // clamps to -60
        ratio: 99.0, // clamps to 20
        attackMs: 0.0, // clamps to 0.1
        releaseMs: 9999.0, // clamps to 2000
        makeupGainDb: -5.0, // clamps to 0
      );
      args =
          callsTo('setCompressor').single.arguments as Map<dynamic, dynamic>;
      expect(args['thresholdDb'], -60.0);
      expect(args['ratio'], 20.0);
      expect(args['attackMs'], 0.1);
      expect(args['releaseMs'], 2000.0);
      expect(args['makeupGainDb'], 0.0);
    });

    test('live setters use the engine defaults when called bare', () async {
      final processor = DspMicProcessor();
      await processor.initialize();
      calls.clear();
      await processor.setEcho();
      await processor.setReverb();
      await processor.setNoiseGate();
      await processor.setCompressor();
      expect(
        (callsTo('setEcho').single.arguments as Map)['delayMs'],
        250.0,
      );
      expect(
        (callsTo('setReverb').single.arguments as Map)['wetDryMix'],
        0.3,
      );
      expect(
        (callsTo('setNoiseGate').single.arguments as Map)['thresholdDb'],
        -40.0,
      );
      expect(
        (callsTo('setCompressor').single.arguments as Map)['thresholdDb'],
        -18.0,
      );
      expect(
        (callsTo('setCompressor').single.arguments as Map)['ratio'],
        4.0,
      );
    });

    test('live setters are no-ops (false, no throw) when native is absent',
        () async {
      final processor = DspMicProcessor();
      await processor.initialize();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      expect(await processor.setEcho(), isFalse);
      expect(await processor.setReverb(), isFalse);
      expect(await processor.setNoiseGate(), isFalse);
      expect(await processor.setCompressor(), isFalse);
      expect(
        await processor.setEqPreset(DspMicEqPreset.flat),
        isFalse,
      );
    });

    test('live setters work after initialize without re-init', () async {
      final processor = DspMicProcessor();
      await processor.initialize();
      calls.clear();
      expect(await processor.setEcho(), isTrue);
      expect(await processor.setReverb(), isTrue);
      expect(await processor.setNoiseGate(), isTrue);
      expect(await processor.setCompressor(), isTrue);
      // No re-init: the isAvailable ping ran once, at initialize.
      expect(callsTo('isAvailable'), isEmpty);
      expect(callsTo('setEq'), isEmpty);
    });

    test('live setters work before initialize (bridge stores pending)',
        () async {
      // The bridge stores params pending until the engine is created
      // on the first frame, so sending before initialize is safe —
      // the preset is applied when the engine exists.
      final processor = DspMicProcessor();
      expect(await processor.setEcho(delayMs: 300.0), isTrue);
      expect(await processor.setCompressor(), isTrue);
      expect(callsTo('setEcho'), hasLength(1));
      expect(callsTo('setCompressor'), hasLength(1));
      expect(callsTo('isAvailable'), isEmpty);
    });

    test('live setters never touch the track (no re-publish path)',
        () async {
      final processor = DspMicProcessor();
      await processor.initialize();
      final built =
          (await processor.buildProcessor())! as DspMicTrackProcessor;
      await built.init(
        lk.AudioProcessorOptions(track: _FakeTrack('mic-track-1')),
      );
      calls.clear();
      await processor.setEcho();
      await processor.setReverb();
      await processor.setNoiseGate();
      await processor.setCompressor();
      await processor.setEqPreset(DspMicEqPreset.flat);
      await processor.setBypass(true);
      // ONLY param calls went out — no init/restart/destroy, so the
      // track is untouched and no re-publish can be triggered.
      expect(
        calls.map((c) => c.method).toList(),
        ['setEcho', 'setReverb', 'setNoiseGate', 'setCompressor', 'setEq',
         'setBypass'],
      );
    });
  });

  group('pipeline selection', () {
    test('pipeline installs the DSP processor; active only when enabled',
        () async {
      final pipeline = MicAudioPipeline();
      final dsp = DspMicProcessor();
      expect(await pipeline.setProcessor(dsp), isTrue);
      expect(pipeline.hasProcessor, isTrue);
      expect(pipeline.processorName, 'DspMicProcessor');
      // Installed but NOT enabled: the mic still publishes plain.
      expect(pipeline.activeProcessor, isNull);
      expect(pipeline.captureOptions().processor, isNull);

      pipeline.setNoiseCancellationEnabled(true);
      final active = pipeline.activeProcessor;
      expect(active, isNotNull);
      expect(active, isA<DspMicTrackProcessor>());
      expect(pipeline.captureOptions().processor, same(active));
      await pipeline.dispose();
      expect(callsTo('destroy'), hasLength(1));
    });

    test('detach + prepareForPublish rebuilds a FRESH DSP processor',
        () async {
      final pipeline = MicAudioPipeline();
      await pipeline.setProcessor(DspMicProcessor());
      pipeline.setNoiseCancellationEnabled(true);
      final first = pipeline.activeProcessor;
      expect(first, isNotNull);
      // Mute / unpublish / disconnect: the SDK destroyed the built
      // copy; the source survives.
      pipeline.markProcessorDetached();
      expect(pipeline.activeProcessor, isNull);
      expect(pipeline.hasProcessor, isTrue);
      await pipeline.prepareForPublish();
      final second = pipeline.activeProcessor;
      expect(second, isNotNull);
      expect(second, isNot(same(first)));
      // initialize() ran ONCE — rebuilds re-attach to the same
      // native engine; the preset was sent once, at initialize.
      expect(callsTo('isAvailable'), hasLength(1));
      expect(callsTo('setEq'), hasLength(1));
      await pipeline.dispose();
    });

    test('pipeline refuses the DSP processor when native is absent',
        () async {
      nativeAvailable = false;
      final pipeline = MicAudioPipeline();
      expect(await pipeline.setProcessor(DspMicProcessor()), isFalse);
      expect(pipeline.hasProcessor, isFalse);
      expect(pipeline.captureOptions().processor, isNull);
      await pipeline.dispose();
    });

    test('pipeline exposes the source so the RJ panel can reach the live setters',
        () async {
      final pipeline = MicAudioPipeline();
      expect(pipeline.source, isNull);
      final dsp = DspMicProcessor();
      expect(await pipeline.setProcessor(dsp), isTrue);
      expect(pipeline.source, same(dsp));
      // The panel's path: source -> live setters, no re-publish.
      final live = pipeline.source as DspMicProcessor?;
      expect(live, isNotNull);
      calls.clear();
      expect(await live!.setEcho(), isTrue);
      expect(callsTo('setEcho'), hasLength(1));
      expect(callsTo('init'), isEmpty);
      expect(callsTo('destroy'), isEmpty);
      // The source survives a track stop (only the built copy drops).
      pipeline.markProcessorDetached();
      expect(pipeline.source, same(dsp));
      await pipeline.dispose();
      expect(pipeline.source, isNull);
    });

    test('buildMicProcessor selects DSP vs Krisp vs RNNoise', () {
      final krisp = _FakeNoiseProcessor('krisp');
      final rnnoise = _FakeNoiseProcessor('rnnoise');

      final dsp = buildMicProcessor(MicProcessorKind.dsp);
      expect(dsp, isA<DspMicProcessor>());

      expect(
        buildMicProcessor(MicProcessorKind.krisp, krisp: krisp),
        same(krisp),
      );
      expect(
        buildMicProcessor(MicProcessorKind.rnnoise, rnnoise: rnnoise),
        same(rnnoise),
      );
      // A kind with no processor yet: null = mic publishes plain.
      expect(buildMicProcessor(MicProcessorKind.krisp), isNull);
      expect(buildMicProcessor(MicProcessorKind.rnnoise), isNull);
    });
  });

  group('native mic glue (source pins)', () {
    test('bridge routes by capacity: float32 primary, int16 fallback',
        () {
      final src = _read('android/app/src/main/cpp/dsp_mic_bridge.cpp');
      expect(src.contains('floatBytes'), isTrue);
      expect(src.contains('pcm16Bytes'), isTrue);
      expect(src.contains('processFloat'), isTrue);
      expect(src.contains('processPcm16'), isTrue);
      // A buffer too small for either layout fails open.
      expect(src.contains('kDspMicBadBuffer'), isTrue);
      // The float sanity check guards against misrouting.
      expect(src.contains('checkFloatSanity'), isTrue);
      expect(src.contains('kDspMicBadFormat'), isTrue);
      // Only band 0 is processed (bands 1+ untouched).
      expect(src.contains('Band 0 is the first'), isTrue);
    });

    test('bridge mic preset: EQ on, echo/reverb/gate/comp off, pending until init',
        () {
      final src = _read('android/app/src/main/cpp/dsp_mic_bridge.h');
      expect(src.contains('bool eqEnabled_ = true'), isTrue);
      expect(src.contains('bool echoEnabled_ = false'), isTrue);
      expect(src.contains('bool reverbEnabled_ = false'), isTrue);
      expect(src.contains('bool gateEnabled_ = false'), isTrue);
      expect(src.contains('bool compEnabled_ = false'), isTrue);
      expect(src.contains('paramsDirty_'), isTrue);
      // Split-band rate for band 0 is 16 kHz.
      final cpp = _read('android/app/src/main/cpp/dsp_mic_bridge.cpp');
      expect(cpp.contains('(numBands > 1) ? 16000'), isTrue);
    });

    test('bridge runs the full chain per band: one engine per band, EQ on band 0 only',
        () {
      final header = _read('android/app/src/main/cpp/dsp_mic_bridge.h');
      // One engine per band (state must never be shared across bands).
      expect(
        header.contains('DspEngine* engines_[kMaxBands]'),
        isTrue,
      );
      expect(header.contains('void setNoiseGate('), isTrue);
      expect(header.contains('void setCompressor('), isTrue);
      final cpp = _read('android/app/src/main/cpp/dsp_mic_bridge.cpp');
      // Every band runs through its own engine...
      expect(cpp.contains('engines_[b]->processPcm16'), isTrue);
      // ...with gate/compressor/echo/reverb on every engine...
      expect(cpp.contains('engines_[b]->setNoiseGate'), isTrue);
      expect(cpp.contains('engines_[b]->setCompressor'), isTrue);
      expect(cpp.contains('engines_[b]->setEcho'), isTrue);
      expect(cpp.contains('engines_[b]->setReverb'), isTrue);
      // ...but EQ only on engine 0 (bands 1-2 get EQ disabled).
      expect(cpp.contains('engines_[b]->setEq(false'), isTrue);
      // A band whose every stage is disabled is skipped outright
      // (bit-identical on the float path — no int16 round-trip).
      expect(cpp.contains('bandBypass_[b]'), isTrue);
      // Per-band rate helper for host tests.
      expect(header.contains('engineSampleRateForBand'), isTrue);
    });

    test('mic JNI exposes the bridge with no array round-trip', () {
      final src = _read('android/app/src/main/cpp/dsp_mic_jni.cpp');
      expect(
        src.contains('Java_com_protournament_app_DspMicProcessor_nativeInit'),
        isTrue,
      );
      expect(
        src.contains(
          'Java_com_protournament_app_DspMicProcessor_nativeProcess',
        ),
        isTrue,
      );
      expect(
        src.contains(
          'Java_com_protournament_app_DspMicProcessor_nativeSetEq',
        ),
        isTrue,
      );
      expect(
        src.contains(
          'Java_com_protournament_app_DspMicProcessor_nativeSetEcho',
        ),
        isTrue,
      );
      expect(
        src.contains(
          'Java_com_protournament_app_DspMicProcessor_nativeSetReverb',
        ),
        isTrue,
      );
      expect(
        src.contains(
          'Java_com_protournament_app_DspMicProcessor_nativeSetNoiseGate',
        ),
        isTrue,
      );
      expect(
        src.contains(
          'Java_com_protournament_app_DspMicProcessor_nativeSetCompressor',
        ),
        isTrue,
      );
      expect(
        src.contains(
          'Java_com_protournament_app_DspMicProcessor_nativeGetFramesProcessed',
        ),
        isTrue,
      );
      expect(src.contains('GetDirectBufferAddress'), isTrue);
      expect(src.contains('GetDirectBufferCapacity'), isTrue);
      // No array round-trip on the audio path: no JNI function here
      // takes or returns a jbyteArray (the word only appears in the
      // header comment explaining why).
      expect(src.contains('jbyteArray JNICALL'), isFalse);
      expect(src.contains('NewByteArray'), isFalse);
      expect(src.contains('GetByteArrayRegion'), isFalse);
    });

    test('Kotlin processor is G2-shaped: hook, lazy init, fail-open',
        () {
      final src = _read(
        'android/app/src/main/kotlin/com/protournament/app/DspMicProcessor.kt',
      );
      // The hook (same as G2/Krisp).
      expect(src.contains('FlutterWebRTCPlugin.sharedSingleton'), isTrue);
      expect(src.contains('getLocalTrack(trackId)'), isTrue);
      expect(src.contains('LocalAudioTrack'), isTrue);
      expect(src.contains('capturePostProcessing'), isTrue);
      expect(src.contains('addProcessor(audioProcessor)'), isTrue);
      expect(src.contains('removeProcessor(audioProcessor)'), isTrue);
      // G2 patterns: loadLibrary try/catch + nativeLoaded flag.
      expect(src.contains('System.loadLibrary("audio_dsp")'), isTrue);
      expect(src.contains('nativeLoaded'), isTrue);
      // Lazy init in process() (initialize() may never fire).
      expect(src.contains('if (!nativeInitDone)'), isTrue);
      // Correct ExternalAudioFrameProcessing signature order.
      expect(
        src.contains(
          'override fun process(numBands: Int, numFrames: Int, buffer: ByteBuffer?)',
        ),
        isTrue,
      );
      expect(src.contains('override fun reset(newRate: Int)'), isTrue);
      // Single shared processor + registered flag (no double-attach).
      expect(src.contains('private val audioProcessor'), isTrue);
      expect(src.contains('if (registered)'), isTrue);
      // First-frame layout log (settles float32 vs int16 on-device).
      expect(src.contains('first frame: bands='), isTrue);
      expect(src.contains('capacity=\${buffer.capacity()}'), isTrue);
      // Channel name matches the Dart side.
      expect(src.contains('arena_hub_dsp_mic'), isTrue);
    });

    test('Kotlin forwards the live setters: echo/reverb/gate/compressor',
        () {
      final src = _read(
        'android/app/src/main/kotlin/com/protournament/app/DspMicProcessor.kt',
      );
      // Channel cases (the RJ panel's sliders land here).
      expect(src.contains('"setEcho"'), isTrue);
      expect(src.contains('"setReverb"'), isTrue);
      expect(src.contains('"setNoiseGate"'), isTrue);
      expect(src.contains('"setCompressor"'), isTrue);
      // JNI declarations (names must match dsp_mic_jni.cpp).
      expect(src.contains('nativeSetEcho'), isTrue);
      expect(src.contains('nativeSetReverb'), isTrue);
      expect(src.contains('nativeSetNoiseGate'), isTrue);
      expect(src.contains('nativeSetCompressor'), isTrue);
      // Arg keys mirror the AudioDsp plugin (minus `handle`).
      expect(src.contains('"delayMs"'), isTrue);
      expect(src.contains('"wetDryMix"'), isTrue);
      expect(src.contains('"thresholdDb"'), isTrue);
      expect(src.contains('"makeupGainDb"'), isTrue);
    });

    test('v3 engine chain order: Gate -> Compressor -> EQ -> Echo -> Reverb',
        () {
      final src = _read('android/app/src/main/cpp/dsp_engine.cpp');
      final gate = src.indexOf('noiseGate_.process(');
      final comp = src.indexOf('compressor_.process(');
      final eq = src.indexOf('eq_.process(');
      final echo = src.indexOf('echo_.process(');
      final reverb = src.indexOf('reverb_.process(');
      expect(gate, isNot(-1));
      expect(comp, isNot(-1));
      expect(eq, isNot(-1));
      expect(echo, isNot(-1));
      expect(reverb, isNot(-1));
      expect(gate < comp, isTrue);
      expect(comp < eq, isTrue);
      expect(eq < echo, isTrue);
      expect(echo < reverb, isTrue);
      // The compressor setter exists and is mutex-guarded (live-safe).
      final header = _read('android/app/src/main/cpp/dsp_engine.h');
      expect(header.contains('void setCompressor('), isTrue);
      expect(header.contains('CompressorProcessor compressor_'), isTrue);
    });

    test('MainActivity registers the DSP channel; Gradle builds the .so',
        () {
      final main = _read(
        'android/app/src/main/kotlin/com/protournament/app/MainActivity.kt',
      );
      expect(
        main.contains(
          'DspMicProcessor.register(flutterEngine.dartExecutor.binaryMessenger)',
        ),
        isTrue,
      );
      final gradle = _read('android/app/build.gradle.kts');
      expect(gradle.contains('externalNativeBuild'), isTrue);
      expect(
        gradle.contains('path = file("src/main/cpp/CMakeLists.txt")'),
        isTrue,
      );
    });

    test('engine bypass is TRUE bypass (disabled stages never touch audio)',
        () {
      final src = _read('android/app/src/main/cpp/dsp_engine.cpp');
      // Reverb disabled (or zero mix): returns before touching the buffer.
      expect(
        src.contains('if (!enabled_ || wetDryMix_ <= 0.0001f)'),
        isTrue,
      );
      // Echo disabled (or zero mix): same.
      expect(
        src.contains('if (!enabled_ || mix_ <= 0.0001f'),
        isTrue,
      );
      // EQ / gate / compressor disabled: same.
      expect(src.contains('if (!enabled_)'), isTrue);
      // All stages disabled (v3: gate + compressor + EQ + echo +
      // reverb): whole engine is a memcpy passthrough.
      expect(src.contains('!noiseGate_.isEnabled()'), isTrue);
      expect(src.contains('!compressor_.isEnabled()'), isTrue);
      expect(src.contains('!eq_.isEnabled()'), isTrue);
      expect(src.contains('!echo_.isEnabled()'), isTrue);
      expect(src.contains('!reverb_.isEnabled()'), isTrue);
    });

    test('external plugin untouched: JNI names, package, channel intact',
        () {
      final plugin = _read(
        'android/app/src/main/kotlin/com/arenahub/app/dsp/AudioDspPlugin.kt',
      );
      expect(plugin.contains('package com.arenahub.app.dsp'), isTrue);
      expect(
        plugin.contains('com.arenahub.app/audio_dsp'),
        isTrue,
      );
      final jni = _read('android/app/src/main/cpp/audio_dsp_jni.cpp');
      expect(
        jni.contains('Java_com_arenahub_app_dsp_AudioDspPlugin_nativeProcess'),
        isTrue,
      );
      expect(
        jni.contains('Java_com_arenahub_app_dsp_AudioDspPlugin_nativeSetEq'),
        isTrue,
      );
    });

    test('CMakeLists builds the mic bridge + JNI into libaudio_dsp', () {
      final src = _read('android/app/src/main/cpp/CMakeLists.txt');
      expect(src.contains('dsp_mic_bridge.cpp'), isTrue);
      expect(src.contains('dsp_mic_jni.cpp'), isTrue);
      expect(src.contains('dsp_engine.cpp'), isTrue);
      expect(src.contains('audio_dsp_jni.cpp'), isTrue);
    });
  });
}
