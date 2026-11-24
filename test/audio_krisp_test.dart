import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_noise_filter/livekit_noise_filter.dart';
import 'package:protournament_user/services/krisp_noise_filter.dart';

/// AUDIO #10 Group 1 — Krisp mic noise cancellation.
///
/// What these tests CAN prove on this Linux VM (no mic, no Android device):
/// Dart-level processor construction + the KrispMicProcessor lifecycle on
/// an unsupported platform (Linux: `LiveKitNoiseFilter.isSupported()` is
/// false here, so initialize/buildProcessor must fail soft, never throw).
///
/// What they CANNOT prove here (stated honestly, not faked): the
/// supported-platform path (Android/iOS), the native method-channel calls,
/// or the self-hosted auth gate — those need a real phone + our server.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('KrispMicProcessor lifecycle (unsupported platform)', () {
    test('initialize returns false on Linux and never throws', () async {
      final krisp = KrispMicProcessor();
      expect(await krisp.initialize(), isFalse);
      expect(krisp.isAvailable, isFalse);
      await krisp.dispose();
    });

    test('initialize is idempotent', () async {
      final krisp = KrispMicProcessor();
      expect(await krisp.initialize(), isFalse);
      expect(await krisp.initialize(), isFalse);
      expect(krisp.isAvailable, isFalse);
      await krisp.dispose();
    });

    test('buildProcessor returns null when unavailable', () async {
      final krisp = KrispMicProcessor();
      await krisp.initialize();
      expect(await krisp.buildProcessor(), isNull);
      await krisp.dispose();
    });

    test('buildProcessor lazily initializes and stays null here', () async {
      final krisp = KrispMicProcessor();
      // No initialize() call: buildProcessor must init on its own.
      expect(await krisp.buildProcessor(), isNull);
      expect(krisp.isAvailable, isFalse);
      await krisp.dispose();
    });

    test('dispose is safe before initialize and twice in a row', () async {
      final krisp = KrispMicProcessor();
      await krisp.dispose();
      await krisp.dispose();
      expect(krisp.isAvailable, isFalse);
    });

    test('initialize and buildProcessor return false/null after dispose',
        () async {
      final krisp = KrispMicProcessor();
      await krisp.initialize();
      await krisp.dispose();
      expect(await krisp.initialize(), isFalse);
      expect(await krisp.buildProcessor(), isNull);
      expect(krisp.isAvailable, isFalse);
    });
  });

  group('LiveKitNoiseFilter (plugin) — local construction', () {
    test('isSupported is false on this Linux VM', () async {
      expect(await LiveKitNoiseFilter.isSupported(), isFalse);
    });

    test('processor constructs locally with the Krisp name', () {
      // Pure Dart construction: no native call, no mic needed. Proves the
      // TrackProcessor object itself can be created; the native filter
      // only engages when the track lifecycle calls init()/onPublish().
      final filter = LiveKitNoiseFilter();
      expect(filter.name, 'KrispNoiseFilter');
      expect(filter.processedTrack, isNull);
    });
  });
}
