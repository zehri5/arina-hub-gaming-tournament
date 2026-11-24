/// Tests for the RNNoise mic processor (Group 2, #10 audio).
///
/// Covers: the pure-Dart spectral gate's DSP behaviour (noise reduction,
/// tone preservation, determinism, framing), the TrackProcessor seam
/// contract over a mocked MethodChannel, and the RnnoiseMicProcessor
/// lifecycle. The native RNNoise C engine is verified separately on the
/// host (see android/app/src/main/cpp/rnnoise/README.md) — no device
/// or APK build is involved here.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show MediaStreamTrack;
import 'package:livekit_client/livekit_client.dart';
import 'package:protournament_user/services/rnnoise_processor.dart';

/// Minimal fake mic track: only `id` is read by the processor.
class _FakeMicTrack extends MediaStreamTrack {
  _FakeMicTrack(this._id);

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
  set enabled(bool value) {}

  @override
  bool? get muted => false;

  @override
  Future<void> stop() async {}

  @override
  // ignore: deprecated_member_use_from_same_package
  Future<void> dispose() async {}
}

double _rms(Float32List frame) {
  var acc = 0.0;
  for (final v in frame) {
    acc += v * v;
  }
  return math.sqrt(acc / frame.length);
}

Float32List _noiseFrame(math.Random rng, double amplitude) {
  final frame = Float32List(SpectralGateNoiseSuppressor.frameSize);
  for (var i = 0; i < frame.length; i++) {
    frame[i] = amplitude * (rng.nextDouble() * 2 - 1);
  }
  return frame;
}

Float32List _toneFrame(int frameIndex, double amplitude, double freqHz) {
  final frame = Float32List(SpectralGateNoiseSuppressor.frameSize);
  for (var i = 0; i < frame.length; i++) {
    final t =
        (frameIndex * SpectralGateNoiseSuppressor.frameSize + i) / 48000.0;
    frame[i] = amplitude * math.sin(2 * math.pi * freqHz * t);
  }
  return frame;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SpectralGateNoiseSuppressor', () {
    test('silence in -> silence out, no NaN', () {
      final gate = SpectralGateNoiseSuppressor();
      final silence = Float32List(SpectralGateNoiseSuppressor.frameSize);
      for (var i = 0; i < 20; i++) {
        final out = gate.processFrame(silence);
        expect(out.length, SpectralGateNoiseSuppressor.frameSize);
        for (final v in out) {
          expect(v.isNaN, isFalse);
          expect(v.isInfinite, isFalse);
          expect(v.abs(), lessThan(1e-6));
        }
      }
      expect(gate.framesProcessed, 20);
    });

    test('noise-only frames are gated down (>= 6 dB) after adaptation', () {
      final gate = SpectralGateNoiseSuppressor();
      final rng = math.Random(42);
      // Warm up: let the noise floor learn the noise (30 frames).
      for (var i = 0; i < 30; i++) {
        gate.processFrame(_noiseFrame(rng, 0.25));
      }
      // Measure over the next 40 frames.
      var inRms = 0.0;
      var outRms = 0.0;
      for (var i = 0; i < 40; i++) {
        final frame = _noiseFrame(rng, 0.25);
        inRms += _rms(frame);
        outRms += _rms(gate.processFrame(frame));
      }
      inRms /= 40;
      outRms /= 40;
      expect(outRms, lessThan(inRms * 0.5),
          reason: 'in=$inRms out=$outRms (expected >= 6 dB reduction)');
    });

    test('steady tone is preserved (>= 70% RMS)', () {
      final gate = SpectralGateNoiseSuppressor();
      // Warm up on the tone itself so the floor learns it is signal.
      for (var i = 0; i < 30; i++) {
        gate.processFrame(_toneFrame(i, 0.5, 1000));
      }
      var inRms = 0.0;
      var outRms = 0.0;
      for (var i = 30; i < 70; i++) {
        final frame = _toneFrame(i, 0.5, 1000);
        inRms += _rms(frame);
        outRms += _rms(gate.processFrame(frame));
      }
      inRms /= 40;
      outRms /= 40;
      expect(outRms, greaterThan(inRms * 0.7),
          reason: 'in=$inRms out=$outRms (tone must survive the gate)');
    });

    test('tone + noise: tone survives, output stays finite', () {
      final gate = SpectralGateNoiseSuppressor();
      final rng = math.Random(7);
      for (var i = 0; i < 60; i++) {
        final frame = _toneFrame(i, 0.5, 800);
        for (var j = 0; j < frame.length; j++) {
          frame[j] += 0.15 * (rng.nextDouble() * 2 - 1);
        }
        final out = gate.processFrame(frame);
        for (final v in out) {
          expect(v.isNaN, isFalse);
          expect(v.isInfinite, isFalse);
          expect(v.abs(), lessThanOrEqualTo(1.0));
        }
      }
      // Last frame's output should still carry most of the tone energy.
      final probe = _toneFrame(60, 0.5, 800);
      final outRms = _rms(gate.processFrame(probe));
      expect(outRms, greaterThan(_rms(probe) * 0.6));
    });

    test('deterministic: same input -> identical output', () {
      final a = SpectralGateNoiseSuppressor();
      final b = SpectralGateNoiseSuppressor();
      final rng = math.Random(99);
      for (var i = 0; i < 25; i++) {
        final frame = _noiseFrame(rng, 0.3);
        final outA = a.processFrame(frame);
        final outB = b.processFrame(frame);
        expect(outA, orderedEquals(outB));
      }
    });

    test('reset restores fresh-instance behaviour', () {
      final gate = SpectralGateNoiseSuppressor();
      final fresh = SpectralGateNoiseSuppressor();
      final rng = math.Random(5);
      for (var i = 0; i < 40; i++) {
        gate.processFrame(_noiseFrame(rng, 0.25));
      }
      expect(gate.framesProcessed, 40);
      gate.reset();
      expect(gate.framesProcessed, 0);
      final frame = _noiseFrame(rng, 0.25);
      expect(gate.processFrame(frame),
          orderedEquals(fresh.processFrame(frame)));
    });

    test('wrong frame length throws ArgumentError', () {
      final gate = SpectralGateNoiseSuppressor();
      expect(() => gate.processFrame(Float32List(100)),
          throwsA(isA<ArgumentError>()));
      expect(() => gate.processFrame(Float32List(0)),
          throwsA(isA<ArgumentError>()));
      expect(() => gate.processFrame(Float32List(960)),
          throwsA(isA<ArgumentError>()));
    });

    test('frameSize/sampleRate match RNNoise framing', () {
      expect(SpectralGateNoiseSuppressor.frameSize, 480);
      expect(SpectralGateNoiseSuppressor.sampleRate, 48000);
    });
  });

  group('RnnoiseTrackProcessor (mocked channel)', () {
    const channel = MethodChannel(RnnoiseMicProcessor.channelName);
    final calls = <MethodCall>[];

    setUp(() {
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
        calls.add(call);
        switch (call.method) {
          case 'isAvailable':
            return true;
          case 'lastError':
            return 0;
          case 'framesProcessed':
            return 1234;
          case 'init':
          case 'restart':
          case 'setBypass':
            return true;
          default:
            return null;
        }
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    Future<TrackProcessor> buildActiveProcessor() async {
      final mic = RnnoiseMicProcessor();
      // On the Linux test host isSupported() is false, so initialize
      // skips the channel ping; buildProcessor still works (fail-open).
      await mic.initialize();
      final processor = await mic.buildProcessor();
      expect(processor, isNotNull);
      return processor!;
    }

    test('name is RnnoiseMicProcessor, processedTrack is null (in-place)',
        () async {
      final processor = await buildActiveProcessor();
      expect(processor.name, 'RnnoiseMicProcessor');
      expect(processor.processedTrack, isNull);
      await processor.destroy();
    });

    test('init sends trackId, restart re-sends it, destroy calls destroy',
        () async {
      final processor =
          await buildActiveProcessor() as RnnoiseTrackProcessor;
      final options =
          AudioProcessorOptions(track: _FakeMicTrack('mic-track-1'));
      await processor.init(options);
      expect(processor.nativeActive, isFalse,
          reason: 'native unavailable on test host (no Android ping)');
      expect(calls.map((c) => c.method), contains('init'));
      final initCall = calls.firstWhere((c) => c.method == 'init');
      expect((initCall.arguments as Map)['trackId'], 'mic-track-1');

      await processor.restart(options);
      expect(calls.where((c) => c.method == 'restart').length, 1);
      expect(
          ((calls.firstWhere((c) => c.method == 'restart').arguments
                  as Map)['trackId']),
          'mic-track-1');

      await processor.destroy();
      expect(calls.map((c) => c.method), contains('destroy'));
      // destroy is idempotent: second call sends nothing more.
      final destroys =
          calls.where((c) => c.method == 'destroy').length;
      await processor.destroy();
      expect(calls.where((c) => c.method == 'destroy').length, destroys);
    });

    test('onPublish / onUnpublish / setBypass forward over the channel',
        () async {
      final processor =
          await buildActiveProcessor() as RnnoiseTrackProcessor;
      // onPublish needs a Room; the processor ignores it, but the
      // signature requires one — use a detached Room instance.
      final room = Room();
      await processor.onPublish(room);
      await processor.onUnpublish();
      expect(await processor.setBypass(true), isTrue);
      expect(await processor.setBypass(false), isTrue);
      expect(await processor.lastError(), 0);
      expect(await processor.framesProcessed(), 1234);
      expect(calls.map((c) => c.method),
          containsAll(['onPublish', 'onUnpublish', 'setBypass']));
      final bypassCall =
          calls.firstWhere((c) => c.method == 'setBypass');
      expect((bypassCall.arguments as Map)['bypass'], isTrue);
      await processor.destroy();
      await room.dispose();
    });

    test('missing native handler fails open (no throw)', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      final processor =
          await buildActiveProcessor() as RnnoiseTrackProcessor;
      final options =
          AudioProcessorOptions(track: _FakeMicTrack('mic-track-2'));
      await processor.init(options); // must not throw
      await processor.restart(options);
      await processor.onPublish(Room());
      await processor.onUnpublish();
      expect(await processor.setBypass(true), isFalse);
      expect(await processor.lastError(), -1);
      expect(await processor.framesProcessed(), -1);
      expect(processor.nativeActive, isFalse);
      await processor.destroy();
    });

    test('platform exception from native fails open (no throw)', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
        throw PlatformException(code: 'BOOM');
      });
      final processor =
          await buildActiveProcessor() as RnnoiseTrackProcessor;
      final options =
          AudioProcessorOptions(track: _FakeMicTrack('mic-track-3'));
      await processor.init(options);
      expect(processor.nativeActive, isFalse);
      expect(await processor.setBypass(false), isFalse);
      expect(await processor.framesProcessed(), -1);
      await processor.destroy();
    });
  });

  group('RnnoiseMicProcessor lifecycle', () {
    test('isSupported is false on the Linux test host', () {
      expect(RnnoiseMicProcessor.isSupported(), isFalse);
    });

    test('buildProcessor before initialize returns null', () async {
      final mic = RnnoiseMicProcessor();
      expect(await mic.buildProcessor(), isNull);
      expect(mic.isInitialized, isFalse);
      await mic.dispose();
    });

    test('initialize -> buildProcessor -> dispose', () async {
      final mic = RnnoiseMicProcessor();
      expect(await mic.initialize(), isTrue);
      expect(mic.isInitialized, isTrue);
      // No native side on the test host.
      expect(mic.isNativeAvailable, isFalse);
      expect(mic.engine, RnnoiseEngine.spectralGate);
      final processor = await mic.buildProcessor();
      expect(processor, isNotNull);
      expect(processor!.name, 'RnnoiseMicProcessor');
      expect(mic.hasActiveProcessor, isTrue);
      await mic.dispose();
      expect(mic.isInitialized, isFalse);
      expect(mic.hasActiveProcessor, isFalse);
      // initialize after dispose refuses (new instance required).
      expect(await mic.initialize(), isFalse);
      expect(await mic.buildProcessor(), isNull);
      // dispose is idempotent.
      await mic.dispose();
    });

    test('building twice destroys the previous processor', () async {
      const channel = MethodChannel(RnnoiseMicProcessor.channelName);
      var destroys = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
        if (call.method == 'destroy') destroys++;
        return null;
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });
      final mic = RnnoiseMicProcessor();
      await mic.initialize();
      final first = await mic.buildProcessor();
      final second = await mic.buildProcessor();
      expect(identical(first, second), isFalse);
      expect(destroys, 1,
          reason: 'previous processor must be destroyed on rebuild');
      await mic.dispose();
    });

    test('initialize is idempotent', () async {
      final mic = RnnoiseMicProcessor();
      expect(await mic.initialize(), isTrue);
      expect(await mic.initialize(), isTrue);
      await mic.dispose();
    });
  });
}
