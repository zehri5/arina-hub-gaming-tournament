// GROUP 7 — AUDIO #10: unit tests for MicAudioPipeline
// (lib/services/mic_audio_pipeline.dart) + source pins for the
// LiveKit wiring in livekit_voice_service.dart / room_screen.dart.
//
// Live voice CANNOT be tested in a widget test: it needs a real
// mic, a LiveKit server and native audio. So the live-track half
// (re-publish on toggle, fresh processor after mute/disconnect) is
// pinned by SOURCE tests below — they fail if the wiring strings
// ever disappear — and the pipeline half is tested directly with
// fake processors. The real mic path is proven on Sameer's phone.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:protournament_user/services/mic_audio_pipeline.dart';

String _read(String path) => File(path).readAsStringSync();

/// A TrackProcessor the pipeline can hold. The SDK (never the
/// pipeline) drives init/destroy — the counters pin that ownership.
class _FakeTrackProcessor
    extends lk.TrackProcessor<lk.AudioProcessorOptions> {
  _FakeTrackProcessor(this._name);

  final String _name;
  int initCalls = 0;
  int destroyCalls = 0;

  @override
  String get name => _name;

  @override
  Future<void> init(lk.AudioProcessorOptions options) async {
    initCalls++;
  }

  @override
  Future<void> restart(lk.AudioProcessorOptions options) async {}

  @override
  Future<void> destroy() async {
    destroyCalls++;
  }

  @override
  Future<void> onPublish(lk.Room room) async {}

  @override
  Future<void> onUnpublish() async {}

  @override
  rtc.MediaStreamTrack? get processedTrack => null;
}

class _FakeNoiseProcessor implements MicNoiseProcessor {
  _FakeNoiseProcessor({
    this.initializeResult = true,
    this.buildResult,
    this.buildNull = false,
    this.throwOnInitialize = false,
    this.throwOnBuild = false,
  });

  final bool initializeResult;
  final _FakeTrackProcessor? buildResult;
  final bool buildNull;
  final bool throwOnInitialize;
  final bool throwOnBuild;
  int initializeCalls = 0;
  int buildCalls = 0;
  int disposeCalls = 0;

  @override
  Future<bool> initialize() async {
    initializeCalls++;
    if (throwOnInitialize) throw StateError('init boom');
    return initializeResult;
  }

  @override
  Future<lk.TrackProcessor<lk.AudioProcessorOptions>?>
  buildProcessor() async {
    buildCalls++;
    if (throwOnBuild) throw StateError('build boom');
    if (buildNull) return null;
    return buildResult ?? _FakeTrackProcessor('fake');
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
  }
}

/// A processor whose initialize() only completes when the test
/// completes [initGate] — for the overlapping-install race test.
class _SlowNoiseProcessor implements MicNoiseProcessor {
  final Completer<bool> initGate = Completer<bool>();
  int disposeCalls = 0;

  @override
  Future<bool> initialize() => initGate.future;

  @override
  Future<lk.TrackProcessor<lk.AudioProcessorOptions>?>
  buildProcessor() async => _FakeTrackProcessor('slow');

  @override
  Future<void> dispose() async {
    disposeCalls++;
  }
}

void main() {
  group('MicAudioPipeline', () {
    test('starts with NC off and no processor', () {
      final pipeline = MicAudioPipeline();
      expect(pipeline.noiseCancellationEnabled, isFalse);
      expect(pipeline.hasProcessor, isFalse);
      expect(pipeline.processorName, isNull);
      expect(pipeline.activeProcessor, isNull);
      expect(pipeline.captureOptions().processor, isNull);
    });

    test('setProcessor installs but stays off until enabled', () async {
      final pipeline = MicAudioPipeline();
      final source = _FakeNoiseProcessor(
        buildResult: _FakeTrackProcessor('fake-krisp'),
      );
      expect(await pipeline.setProcessor(source), isTrue);
      expect(source.initializeCalls, 1);
      expect(source.buildCalls, 1);
      expect(pipeline.hasProcessor, isTrue);
      expect(pipeline.processorName, 'fake-krisp');
      // Installed but NOT enabled: the mic still publishes plain.
      expect(pipeline.activeProcessor, isNull);
      expect(pipeline.captureOptions().processor, isNull);
    });

    test('enabling exposes the processor in capture options', () async {
      final pipeline = MicAudioPipeline();
      final built = _FakeTrackProcessor('fake-krisp');
      await pipeline.setProcessor(_FakeNoiseProcessor(buildResult: built));
      pipeline.setNoiseCancellationEnabled(true);
      expect(pipeline.noiseCancellationEnabled, isTrue);
      expect(pipeline.activeProcessor, same(built));
      expect(pipeline.captureOptions().processor, same(built));
    });

    test('disabling hides the processor again', () async {
      final pipeline = MicAudioPipeline();
      await pipeline.setProcessor(_FakeNoiseProcessor());
      pipeline.setNoiseCancellationEnabled(true);
      expect(pipeline.activeProcessor, isNotNull);
      pipeline.setNoiseCancellationEnabled(false);
      expect(pipeline.activeProcessor, isNull);
      expect(pipeline.captureOptions().processor, isNull);
      // The processor is still installed — only the switch moved.
      expect(pipeline.hasProcessor, isTrue);
    });

    test(
      'captureOptions preserves base fields and can clear a processor',
      () async {
        final pipeline = MicAudioPipeline();
        final built = _FakeTrackProcessor('fake-krisp');
        await pipeline.setProcessor(_FakeNoiseProcessor(buildResult: built));
        final base = lk.AudioCaptureOptions(
          deviceId: 'mic-1',
          noiseSuppression: false,
          stopAudioCaptureOnMute: false,
          processor: _FakeTrackProcessor('stale'),
        );
        // NC off: the base's stale processor must NOT leak through
        // (AudioCaptureOptions.copyWith would keep it — the
        // pipeline builds fresh, so null really means null).
        final off = pipeline.captureOptions(base: base);
        expect(off.processor, isNull);
        expect(off.deviceId, 'mic-1');
        expect(off.noiseSuppression, isFalse);
        expect(off.stopAudioCaptureOnMute, isFalse);
        // NC on: the pipeline's processor overrides the base's.
        pipeline.setNoiseCancellationEnabled(true);
        final on = pipeline.captureOptions(base: base);
        expect(on.processor, same(built));
        expect(on.deviceId, 'mic-1');
      },
    );

    test('initialize false => not installed, processor disposed', () async {
      final pipeline = MicAudioPipeline();
      final source = _FakeNoiseProcessor(initializeResult: false);
      expect(await pipeline.setProcessor(source), isFalse);
      expect(pipeline.hasProcessor, isFalse);
      expect(source.disposeCalls, 1);
      expect(source.buildCalls, 0);
      expect(pipeline.captureOptions().processor, isNull);
    });

    test('initialize throwing => not installed', () async {
      final pipeline = MicAudioPipeline();
      final source = _FakeNoiseProcessor(throwOnInitialize: true);
      expect(await pipeline.setProcessor(source), isFalse);
      expect(pipeline.hasProcessor, isFalse);
      expect(source.disposeCalls, 1);
    });

    test('buildProcessor null => not installed, processor disposed', () async {
      final pipeline = MicAudioPipeline();
      final source = _FakeNoiseProcessor(buildNull: true);
      expect(await pipeline.setProcessor(source), isFalse);
      expect(pipeline.hasProcessor, isFalse);
      expect(source.disposeCalls, 1);
    });

    test('buildProcessor throwing => not installed', () async {
      final pipeline = MicAudioPipeline();
      final source = _FakeNoiseProcessor(throwOnBuild: true);
      expect(await pipeline.setProcessor(source), isFalse);
      expect(pipeline.hasProcessor, isFalse);
      expect(source.disposeCalls, 1);
    });

    test('setProcessor(null) removes and disposes the old one', () async {
      final pipeline = MicAudioPipeline();
      final source = _FakeNoiseProcessor();
      await pipeline.setProcessor(source);
      pipeline.setNoiseCancellationEnabled(true);
      expect(await pipeline.setProcessor(null), isTrue);
      expect(pipeline.hasProcessor, isFalse);
      expect(pipeline.activeProcessor, isNull);
      expect(source.disposeCalls, 1);
    });

    test('swapping disposes the old processor', () async {
      final pipeline = MicAudioPipeline();
      final first = _FakeNoiseProcessor(
        buildResult: _FakeTrackProcessor('first'),
      );
      final second = _FakeNoiseProcessor(
        buildResult: _FakeTrackProcessor('second'),
      );
      await pipeline.setProcessor(first);
      expect(await pipeline.setProcessor(second), isTrue);
      expect(first.disposeCalls, 1);
      expect(second.disposeCalls, 0);
      expect(pipeline.processorName, 'second');
    });

    test(
      'detach drops the built copy; prepareForPublish rebuilds only when enabled',
      () async {
        final pipeline = MicAudioPipeline();
        final source = _FakeNoiseProcessor();
        await pipeline.setProcessor(source);
        pipeline.setNoiseCancellationEnabled(true);
        final firstBuilt = pipeline.activeProcessor;
        expect(firstBuilt, isNotNull);
        // Mute / unpublish / disconnect destroys the attached
        // processor inside the SDK.
        pipeline.markProcessorDetached();
        expect(pipeline.activeProcessor, isNull);
        expect(pipeline.processorName, isNull);
        // ...but the SOURCE survives, so the toggle stays available.
        expect(pipeline.hasProcessor, isTrue);
        // Rebuild for the next publish: a FRESH object, not the
        // destroyed one.
        await pipeline.prepareForPublish();
        expect(source.buildCalls, 2);
        expect(pipeline.activeProcessor, isNotNull);
        expect(pipeline.activeProcessor, isNot(same(firstBuilt)));
        // While NC is off, no rebuild happens (no wasted builds).
        pipeline.setNoiseCancellationEnabled(false);
        pipeline.markProcessorDetached();
        await pipeline.prepareForPublish();
        expect(source.buildCalls, 2);
      },
    );

    test('prepareForPublish is a no-op without a processor', () async {
      final pipeline = MicAudioPipeline();
      pipeline.setNoiseCancellationEnabled(true);
      await pipeline.prepareForPublish();
      expect(pipeline.activeProcessor, isNull);
    });

    test('pipeline never drives the built processor lifecycle', () async {
      final pipeline = MicAudioPipeline();
      final built = _FakeTrackProcessor('fake-krisp');
      final source = _FakeNoiseProcessor(buildResult: built);
      await pipeline.setProcessor(source);
      pipeline.setNoiseCancellationEnabled(true);
      pipeline.markProcessorDetached();
      await pipeline.prepareForPublish();
      await pipeline.dispose();
      // init/destroy belong to the SDK (LocalTrack.setProcessor /
      // stopProcessor) — the pipeline must never call them.
      expect(built.initCalls, 0);
      expect(built.destroyCalls, 0);
      expect(source.disposeCalls, 1);
    });

    test('overlapping setProcessor: stale slow install is discarded', () async {
      final pipeline = MicAudioPipeline();
      final slow = _SlowNoiseProcessor();
      final first = pipeline.setProcessor(slow);
      final fast = _FakeNoiseProcessor(
        buildResult: _FakeTrackProcessor('fast'),
      );
      expect(await pipeline.setProcessor(fast), isTrue);
      // The slow install finishes AFTER it was superseded: it must
      // not clobber the fast one, and it gets disposed.
      slow.initGate.complete(true);
      expect(await first, isFalse);
      expect(slow.disposeCalls, 1);
      expect(pipeline.processorName, 'fast');
      expect(fast.disposeCalls, 0);
    });

    test('dispose is idempotent and locks the pipeline', () async {
      final pipeline = MicAudioPipeline();
      final source = _FakeNoiseProcessor();
      await pipeline.setProcessor(source);
      await pipeline.dispose();
      await pipeline.dispose();
      expect(source.disposeCalls, 1);
      expect(pipeline.hasProcessor, isFalse);
      // After dispose: newcomers are disposed, not installed.
      final late = _FakeNoiseProcessor();
      expect(await pipeline.setProcessor(late), isFalse);
      expect(late.disposeCalls, 1);
      // ...and the switch no longer moves.
      pipeline.setNoiseCancellationEnabled(true);
      expect(pipeline.noiseCancellationEnabled, isFalse);
      expect(pipeline.captureOptions().processor, isNull);
    });

    test('dispose during a slow install disposes the late arrival', () async {
      final pipeline = MicAudioPipeline();
      final slow = _SlowNoiseProcessor();
      final pending = pipeline.setProcessor(slow);
      await pipeline.dispose();
      slow.initGate.complete(true);
      expect(await pending, isFalse);
      expect(slow.disposeCalls, 1);
      expect(pipeline.hasProcessor, isFalse);
    });
  });

  group('mic pipeline wiring (source pins)', () {
    test('service wires the pipeline into the mic path', () {
      final src = _read('lib/services/livekit_voice_service.dart');
      expect(src.contains('MicAudioPipeline micPipeline'), isTrue);
      expect(src.contains('micPipeline.captureOptions()'), isTrue);
      expect(src.contains('micPipeline.prepareForPublish()'), isTrue);
      expect(src.contains('micPipeline.markProcessorDetached()'), isTrue);
      expect(src.contains('setNoiseCancellationEnabled'), isTrue);
      expect(src.contains('setNoiseProcessor'), isTrue);
      expect(src.contains('noiseCancellationAvailable'), isTrue);
      // Live toggle goes through unpublish + re-publish (the only
      // public route in livekit_client 2.13.2).
      expect(src.contains('removePublishedTrack'), isTrue);
      expect(src.contains('_publishMicWithPipeline'), isTrue);
      expect(src.contains('_enableMic'), isTrue);
      // NO @internal SDK calls: stopProcessor is @internal, and a
      // direct setProcessor on a published track never reaches the
      // sender — so the ONLY setProcessor call in the service is
      // the pipeline's own install/swap.
      expect(src.contains('stopProcessor'), isFalse);
      expect('setProcessor('.allMatches(src).length, 1);
      expect(src.contains('micPipeline.setProcessor(processor)'), isTrue);
    });

    test('room screen has the noise-cancellation toggle', () {
      final src = _read('lib/screens/room_screen.dart');
      expect(src.contains('noiseCancellationAvailable'), isTrue);
      expect(src.contains('setNoiseCancellationEnabled'), isTrue);
      expect(src.contains('Noise Cancellation'), isTrue);
    });

    test('pipeline exposes the Groups 1/2 processor contract', () {
      final src = _read('lib/services/mic_audio_pipeline.dart');
      expect(src.contains('abstract class MicNoiseProcessor'), isTrue);
      expect(src.contains('Future<bool> initialize()'), isTrue);
      expect(
        src.contains(
          'Future<lk.TrackProcessor<lk.AudioProcessorOptions>?> buildProcessor()',
        ),
        isTrue,
      );
      expect(src.contains('Future<void> dispose()'), isTrue);
      expect(src.contains('AudioCaptureOptions.processor'), isTrue);
    });
  });
}
