// DSP FOLD — AUDIO #10: tests for the composite mic processor
// (lib/services/composite_mic_processor.dart).
//
// The composite stacks the DSP-engine mic chain (Gate -> Compressor ->
// EQ -> Echo -> Reverb) and RNNoise on ONE mic track: its built
// TrackProcessor init() calls BOTH channels' init(trackId) — DSP-mic
// FIRST, then RNNoise — because the native hooks run in add order on
// the same in-place buffer. These tests prove, against mocked
// MethodChannels:
//
//   * init order: DSP-mic 'init' precedes RNNoise 'init', same trackId;
//   * fail-open: one absent/failing channel never blocks the other;
//   * dispose cleans both channels;
//   * the RJ live setters delegate to the DSP child;
//   * the MicNoiseProcessor contract against the real MicAudioPipeline.
//
// What these tests CANNOT prove: that live mic audio actually flows
// through both engines on a phone. That needs a device (mic + WebRTC
// APM + both native .so files) — see AUDIO_TEST_PLAN.md. Never claim
// live-mic success from these tests alone.
//
// HOST NOTE on RnnoiseTrackProcessor.nativeActive: on the Linux test
// host RnnoiseMicProcessor.initialize() skips the isAvailable ping
// (isSupported() is Android-only), so its nativeAvailable is false and
// the RNNoise child's nativeActive stays false even when the mocked
// channel answers init. That is G2's designed host behaviour, not a
// composite defect — the init CALL still goes out (which the order
// tests assert), and on a real Android device nativeAvailable is true.
// The DSP child has no such gate: its nativeActive is true in tests
// when the mocked channel answers.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:protournament_user/services/composite_mic_processor.dart';
import 'package:protournament_user/services/dsp_mic_processor.dart';
import 'package:protournament_user/services/mic_audio_pipeline.dart';
import 'package:protournament_user/services/rnnoise_processor.dart';

const MethodChannel _dspChannel = MethodChannel('arena_hub_dsp_mic');
const MethodChannel _rnnoiseChannel = MethodChannel('arena_hub_rnnoise');

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

/// One recorded call, tagged with the channel it arrived on, so the
/// tests can assert ORDER across both channels.
class _Call {
  _Call(this.channel, this.call);

  final String channel;
  final MethodCall call;
}

/// Records every call on both channels and serves configurable replies.
class _FakeChannels {
  final List<_Call> calls = <_Call>[];

  bool dspAvailable = true;
  bool dspInitThrows = false;

  Future<dynamic> dspHandler(MethodCall call) async {
    calls.add(_Call('dsp', call));
    switch (call.method) {
      case 'isAvailable':
        return dspAvailable;
      case 'init':
        if (dspInitThrows) {
          throw PlatformException(code: 'NATIVE_ERROR');
        }
        return null;
      default:
        return null;
    }
  }

  Future<dynamic> rnnoiseHandler(MethodCall call) async {
    calls.add(_Call('rnnoise', call));
    return null;
  }

  List<_Call> callsNamed(String channel, String method) => calls
      .where((c) => c.channel == channel && c.call.method == method)
      .toList();

  int indexOf(String channel, String method) => calls.indexWhere(
        (c) => c.channel == channel && c.call.method == method,
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeChannels fake;

  setUp(() {
    fake = _FakeChannels();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_dspChannel, fake.dspHandler);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_rnnoiseChannel, fake.rnnoiseHandler);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_dspChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_rnnoiseChannel, null);
  });

  group('initialize', () {
    test('returns true when both children initialize', () async {
      final composite = CompositeMicProcessor();
      addTearDown(composite.dispose);
      expect(await composite.initialize(), isTrue);
      expect(composite.isDspUsable, isTrue);
      expect(composite.isRnnoiseUsable, isTrue);
      expect(fake.callsNamed('dsp', 'isAvailable'), hasLength(1));
    });

    test('returns true when the DSP native side is absent', () async {
      fake.dspAvailable = false;
      final composite = CompositeMicProcessor();
      addTearDown(composite.dispose);
      expect(await composite.initialize(), isTrue);
      expect(composite.isDspUsable, isFalse);
      expect(composite.isRnnoiseUsable, isTrue);
    });

    test('returns false when NEITHER child initializes', () async {
      fake.dspAvailable = false;
      final deadRnnoise = RnnoiseMicProcessor();
      await deadRnnoise.dispose(); // disposed -> initialize() false
      final composite = CompositeMicProcessor(rnnoise: deadRnnoise);
      addTearDown(composite.dispose);
      expect(await composite.initialize(), isFalse);
      expect(await composite.buildProcessor(), isNull);
    });

    test('returns false after dispose', () async {
      final composite = CompositeMicProcessor();
      await composite.dispose();
      expect(await composite.initialize(), isFalse);
    });
  });

  group('buildProcessor + init order', () {
    test('init calls DSP-mic FIRST, then RNNoise, same trackId', () async {
      final composite = CompositeMicProcessor();
      addTearDown(composite.dispose);
      expect(await composite.initialize(), isTrue);
      final built = await composite.buildProcessor();
      expect(built, isNotNull);
      expect(built, isA<CompositeMicTrackProcessor>());
      expect(built!.name, 'CompositeMicProcessor');
      expect(built.processedTrack, isNull);

      fake.calls.clear();
      await built.init(
        lk.AudioProcessorOptions(track: _FakeTrack('mic-track-1')),
      );

      final dspInit = fake.indexOf('dsp', 'init');
      final rnnoiseInit = fake.indexOf('rnnoise', 'init');
      expect(dspInit, isNot(-1), reason: 'DSP init must be called');
      expect(rnnoiseInit, isNot(-1), reason: 'RNNoise init must be called');
      expect(dspInit, lessThan(rnnoiseInit),
          reason: 'DSP-mic init must precede RNNoise init');
      expect(
        fake.callsNamed('dsp', 'init').single.call.arguments,
        <String, dynamic>{'trackId': 'mic-track-1'},
      );
      expect(
        fake.callsNamed('rnnoise', 'init').single.call.arguments,
        <String, dynamic>{'trackId': 'mic-track-1'},
      );

      final typed = built as CompositeMicTrackProcessor;
      expect(typed.dspActive, isTrue);
      // RNNoise nativeActive is false on the Linux host by G2 design
      // (see the file header) — the init CALL above is the proof.
      expect(typed.nativeActive, isTrue);
    });

    test('fail-open: DSP init throws, RNNoise init still runs', () async {
      fake.dspInitThrows = true;
      final composite = CompositeMicProcessor();
      addTearDown(composite.dispose);
      expect(await composite.initialize(), isTrue);
      final built = await composite.buildProcessor();
      expect(built, isNotNull);

      fake.calls.clear();
      // Must not throw even though the DSP channel throws.
      await built!.init(
        lk.AudioProcessorOptions(track: _FakeTrack('mic-track-1')),
      );

      expect(fake.callsNamed('dsp', 'init'), hasLength(1));
      expect(fake.callsNamed('rnnoise', 'init'), hasLength(1));
      final typed = built as CompositeMicTrackProcessor;
      expect(typed.dspActive, isFalse);
    });

    test('fail-open: DSP absent, only RNNoise init runs', () async {
      fake.dspAvailable = false;
      final composite = CompositeMicProcessor();
      addTearDown(composite.dispose);
      expect(await composite.initialize(), isTrue);
      final built = await composite.buildProcessor();
      expect(built, isNotNull);

      fake.calls.clear();
      await built!.init(
        lk.AudioProcessorOptions(track: _FakeTrack('mic-track-1')),
      );

      expect(fake.callsNamed('dsp', 'init'), isEmpty);
      expect(fake.callsNamed('rnnoise', 'init'), hasLength(1));
    });

    test('returns null when not initialized', () async {
      final composite = CompositeMicProcessor();
      addTearDown(composite.dispose);
      expect(await composite.buildProcessor(), isNull);
    });

    test('building twice destroys the previous processor first', () async {
      final composite = CompositeMicProcessor();
      addTearDown(composite.dispose);
      expect(await composite.initialize(), isTrue);
      final first = await composite.buildProcessor();
      expect(first, isNotNull);
      await first!.init(
        lk.AudioProcessorOptions(track: _FakeTrack('mic-track-1')),
      );
      fake.calls.clear();
      final second = await composite.buildProcessor();
      expect(second, isNotNull);
      expect(second, isNot(same(first)));
      expect(fake.callsNamed('dsp', 'destroy'), hasLength(1));
      expect(fake.callsNamed('rnnoise', 'destroy'), hasLength(1));
    });
  });

  group('restart / publish / destroy forwarding', () {
    test('restart calls DSP first, then RNNoise', () async {
      final composite = CompositeMicProcessor();
      addTearDown(composite.dispose);
      expect(await composite.initialize(), isTrue);
      final built = await composite.buildProcessor();
      await built!.init(
        lk.AudioProcessorOptions(track: _FakeTrack('mic-track-1')),
      );
      fake.calls.clear();
      await built.restart(
        lk.AudioProcessorOptions(track: _FakeTrack('mic-track-2')),
      );
      expect(
        fake.indexOf('dsp', 'restart'),
        lessThan(fake.indexOf('rnnoise', 'restart')),
      );
      expect(
        fake.callsNamed('dsp', 'restart').single.call.arguments,
        <String, dynamic>{'trackId': 'mic-track-2'},
      );
    });

    test('destroy cleans both channels and is idempotent', () async {
      final composite = CompositeMicProcessor();
      addTearDown(composite.dispose);
      expect(await composite.initialize(), isTrue);
      final built = await composite.buildProcessor();
      await built!.init(
        lk.AudioProcessorOptions(track: _FakeTrack('mic-track-1')),
      );
      fake.calls.clear();
      await built.destroy();
      await built.destroy();
      expect(fake.callsNamed('dsp', 'destroy'), hasLength(1));
      expect(fake.callsNamed('rnnoise', 'destroy'), hasLength(1));
      final typed = built as CompositeMicTrackProcessor;
      expect(typed.nativeActive, isFalse);
    });
  });

  group('dispose', () {
    test('dispose cleans both children', () async {
      final composite = CompositeMicProcessor();
      expect(await composite.initialize(), isTrue);
      final built = await composite.buildProcessor();
      await built!.init(
        lk.AudioProcessorOptions(track: _FakeTrack('mic-track-1')),
      );
      fake.calls.clear();
      await composite.dispose();
      expect(fake.callsNamed('dsp', 'destroy'), hasLength(1));
      expect(fake.callsNamed('rnnoise', 'destroy'), hasLength(1));
      expect(composite.isInitialized, isFalse);
      expect(await composite.buildProcessor(), isNull);
    });

    test('dispose is idempotent and safe without initialize', () async {
      final composite = CompositeMicProcessor();
      await composite.dispose();
      await composite.dispose();
      expect(fake.callsNamed('dsp', 'destroy'), isEmpty);
      expect(fake.callsNamed('rnnoise', 'destroy'), isEmpty);
    });
  });

  group('RJ live setters delegate to the DSP child', () {
    test('setEcho / setReverb / setNoiseGate / setCompressor go to DSP',
        () async {
      final composite = CompositeMicProcessor();
      addTearDown(composite.dispose);
      expect(await composite.initialize(), isTrue);
      fake.calls.clear();

      expect(await composite.setEcho(delayMs: 300, feedback: 0.5, mix: 0.4),
          isTrue);
      expect(await composite.setReverb(wetDryMix: 0.6), isTrue);
      expect(await composite.setNoiseGate(thresholdDb: -30), isTrue);
      expect(await composite.setCompressor(ratio: 3), isTrue);

      expect(fake.callsNamed('dsp', 'setEcho'), hasLength(1));
      expect(fake.callsNamed('dsp', 'setReverb'), hasLength(1));
      expect(fake.callsNamed('dsp', 'setNoiseGate'), hasLength(1));
      expect(fake.callsNamed('dsp', 'setCompressor'), hasLength(1));
      expect(fake.callsNamed('rnnoise', 'setEcho'), isEmpty);
      final echoArgs = Map<String, dynamic>.from(
        fake.callsNamed('dsp', 'setEcho').single.call.arguments as Map,
      );
      expect(echoArgs['delayMs'], 300.0);
      expect(echoArgs['feedback'], 0.5);
      expect(echoArgs['mix'], 0.4);
    });

    test('setEqPreset sends the voice preset over the DSP channel',
        () async {
      final composite = CompositeMicProcessor();
      addTearDown(composite.dispose);
      expect(await composite.initialize(), isTrue);
      fake.calls.clear();
      expect(
        await composite.setEqPreset(const DspMicEqPreset(
          bassBoostDb: 1,
          lowGainDb: 2,
          midGainDb: 3,
          highGainDb: 4,
        )),
        isTrue,
      );
      final setEq = fake.callsNamed('dsp', 'setEq');
      expect(setEq, hasLength(1));
      final args = Map<String, dynamic>.from(
        setEq.single.call.arguments as Map,
      );
      expect(args['bassDb'], 1.0);
      expect(args['highDb'], 4.0);
    });

    test('setters return false, never throw, when DSP is absent', () async {
      fake.dspAvailable = false;
      final composite = CompositeMicProcessor();
      addTearDown(composite.dispose);
      expect(await composite.initialize(), isTrue);
      // No mocked 'setEcho' reply is needed: the DSP child is absent,
      // but the channel mock still answers — so force a true absence
      // by removing the DSP handler entirely.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_dspChannel, null);
      expect(await composite.setEcho(), isFalse);
      expect(await composite.setReverb(), isFalse);
    });
  });

  group('MicAudioPipeline contract', () {
    test('installs in the pipeline and supplies the active processor',
        () async {
      final pipeline = MicAudioPipeline();
      addTearDown(pipeline.dispose);
      final composite = CompositeMicProcessor();
      expect(await pipeline.setProcessor(composite), isTrue);
      expect(pipeline.hasProcessor, isTrue);
      expect(pipeline.source, same(composite));
      expect(pipeline.processorName, 'CompositeMicProcessor');
      // NC off: no active processor.
      expect(pipeline.activeProcessor, isNull);
      pipeline.setNoiseCancellationEnabled(true);
      expect(pipeline.activeProcessor, isNotNull);
      expect(pipeline.activeProcessor!.name, 'CompositeMicProcessor');
    });

    test('pipeline install still succeeds when DSP is absent', () async {
      fake.dspAvailable = false;
      final pipeline = MicAudioPipeline();
      addTearDown(pipeline.dispose);
      final composite = CompositeMicProcessor();
      expect(await pipeline.setProcessor(composite), isTrue);
      expect(pipeline.hasProcessor, isTrue);
    });
  });
}
