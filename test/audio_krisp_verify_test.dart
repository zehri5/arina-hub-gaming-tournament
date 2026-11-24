// GROUP 1 VERIFIER — INDEPENDENT Krisp tests (Phase 1).
//
// Written 2026-11-22 from the Group 1 spec ONLY, BEFORE seeing the
// implementer's code. They pin the contracted shape:
//
//   lib/services/krisp_noise_filter.dart
//   class KrispMicProcessor with initialize() / buildProcessor() / dispose()
//   backed by the real `livekit_noise_filter` plugin (pub.dev 0.2.1),
//   whose LiveKitNoiseFilter is the processor handed to LiveKit as
//   AudioCaptureOptions.processor.
//
// These tests FAIL until the implementer's diff lands (missing file +
// missing pubspec dependency) — that failure is EXPECTED in Phase 1.
// Do NOT weaken them to make them pass without the implementation.
//
// Contract notes (deliberate choices, not guesses):
// - initialize()/dispose() are awaited: lifecycle methods that touch the
//   plugin's async method channel can only sensibly be Future-returning
//   (the plugin's own destroy()/init() are Future<void>).
// - buildProcessor() is consumed tolerantly (sync OR async): the spec
//   does not say, and either shape is a valid factory. What IS pinned
//   is the yielded value: a real LiveKitNoiseFilter, never a stub.
// - initialize() must complete without throwing on the test VM (no
//   native platform, no method-channel handler): the wrapper must
//   degrade gracefully on unsupported platforms, never crash the caller.
// - Nothing here pins unspecified behaviour (e.g. buildProcessor()
//   before initialize(), repeated-build identity, bypass API).
import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:livekit_noise_filter/livekit_noise_filter.dart';
import 'package:protournament_user/services/krisp_noise_filter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// buildProcessor() returns Future<TrackProcessor?> per the Group 1
  /// contract — await it, then cast the RESULT (not the Future) to
  /// LiveKitNoiseFilter. Returns null when the platform cannot build
  /// one (fail-soft: LiveKitNoiseFilter.isSupported() is false on
  /// Linux by plugin design, so buildProcessor() returns null there);
  /// callers skip in that case.
  /// MERGE FIX (coordinator, 2026-11-22): the phase-1 helper cast the
  /// Future itself to LiveKitNoiseFilter, which throws; and it assumed
  /// a non-null processor, which Linux can never produce.
  Future<LiveKitNoiseFilter?> build(KrispMicProcessor proc) async {
    final TrackProcessor? built = await proc.buildProcessor();
    if (built == null) return null;
    return built as LiveKitNoiseFilter;
  }

  group('KrispMicProcessor lifecycle', () {
    test('constructs with the default constructor', () {
      expect(KrispMicProcessor(), isA<KrispMicProcessor>());
    });

    test('initialize() completes without throwing on the test VM', () async {
      final proc = KrispMicProcessor();
      await proc.initialize();
      await proc.dispose();
    });

    test('initialize() is idempotent', () async {
      final proc = KrispMicProcessor();
      await proc.initialize();
      await proc.initialize();
      await proc.dispose();
    });

    test('dispose() completes after initialize()', () async {
      final proc = KrispMicProcessor();
      await proc.initialize();
      await proc.dispose();
    });

    test('dispose() is idempotent (double dispose is safe)', () async {
      final proc = KrispMicProcessor();
      await proc.initialize();
      await proc.dispose();
      await proc.dispose();
    });

    test('dispose() before initialize() is safe', () async {
      final proc = KrispMicProcessor();
      await proc.dispose();
    });
  });

  group('KrispMicProcessor processor wiring', () {
    test('buildProcessor() returns a real LiveKitNoiseFilter', () async {
      final proc = KrispMicProcessor();
      await proc.initialize();
      final processor = await build(proc);
      if (processor == null) {
        // Krisp unsupported here (Linux: isSupported() is false by
        // plugin design, so buildProcessor() correctly returns null).
        // Skip; this test runs for real on Android/iOS/macOS.
        markTestSkipped('Krisp unsupported on this platform (Linux).');
        return;
      }
      expect(processor, isA<LiveKitNoiseFilter>());
      expect(processor, isA<TrackProcessor<AudioProcessorOptions>>());
      await proc.dispose();
    });

    test('built processor reports the Krisp plugin name', () async {
      final proc = KrispMicProcessor();
      await proc.initialize();
      final processor = await build(proc);
      if (processor == null) {
        // Krisp unsupported here (Linux: isSupported() is false by
        // plugin design, so buildProcessor() correctly returns null).
        // Skip; this test runs for real on Android/iOS/macOS.
        markTestSkipped('Krisp unsupported on this platform (Linux).');
        return;
      }
      expect(processor.name, 'KrispNoiseFilter');
      await proc.dispose();
    });

    test('built processor plugs into AudioCaptureOptions + RoomOptions',
        () async {
      final proc = KrispMicProcessor();
      await proc.initialize();
      final processor = await build(proc);
      if (processor == null) {
        // Krisp unsupported here (Linux: isSupported() is false by
        // plugin design, so buildProcessor() correctly returns null).
        // Skip; this test runs for real on Android/iOS/macOS.
        markTestSkipped('Krisp unsupported on this platform (Linux).');
        return;
      }
      final captureOptions = AudioCaptureOptions(processor: processor);
      expect(captureOptions.processor, same(processor));
      final roomOptions =
          RoomOptions(defaultAudioCaptureOptions: captureOptions);
      expect(roomOptions.defaultAudioCaptureOptions.processor, same(processor));
      await proc.dispose();
    });
  });
}
