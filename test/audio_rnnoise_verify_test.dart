// ARENA HUB #10 AUDIO — Group 2 VERIFIER (independent tests).
//
// Written PHASE 1 from the coordinator's spec ONLY — the verifier has not
// seen the implementer's code. These tests FAIL until the implementation
// lands (the import below does not resolve yet); that is expected.
// Do NOT weaken them to make them pass.
//
// Contract under test (coordinator spec):
//   * class RnnoiseMicProcessor in lib/services/rnnoise_processor.dart
//   * methods: initialize() / buildProcessor() / dispose()
//   * custom noise-suppression prototype on the mic capture path via the
//     livekit_client 2.13.2 TrackProcessor seam
//   * NO new pub dependencies
//
// Contract-shape assumptions (the only readings consistent with the seam):
//   * RnnoiseMicProcessor() — default constructor, no required args.
//   * Future<void> initialize() — async init (mirrors TrackProcessor.init).
//   * buildProcessor() returns TrackProcessor<AudioProcessorOptions>
//     (sync or Future — the tests await, which compiles for both).
//   * Future<void> dispose() — async teardown (mirrors TrackProcessor.destroy).
//
// Seam facts (livekit_client 2.13.2, verified from the published package):
//   * AudioCaptureOptions.processor is TrackProcessor<AudioProcessorOptions>?
//     (src/track/options.dart) — this is the mic-capture seam.
//   * LocalAudioTrack.create calls track.setProcessor(options.processor)
//     (src/track/local/audio.dart), and LocalTrack.setProcessor calls
//     processor.init(AudioProcessorOptions(track: mediaStreamTrack))
//     and swaps in processedTrack when non-null (src/track/local/local.dart).
//   * The app's mic path is LocalParticipant.setMicrophoneEnabled(bool,
//     {AudioCaptureOptions?}) — see lib/services/livekit_voice_service.dart.
//
// What these tests deliberately do NOT assert (not in the spec):
//   * buildProcessor() before initialize() throwing (guard behaviour
//     unspecified — the happy path initialize -> buildProcessor is tested).
//   * processedTrack null vs non-null (both are legitimate designs:
//     null = in-place processing, non-null = replacement track).
//   * Any frame-level audio behaviour — there is no audio-frame callback
//     in the Dart TrackProcessor API, so a pure-Dart prototype cannot
//     transform frames through this seam; what the suppression stage
//     REALLY is (full RNNoise vs simplified prototype) is judged in
//     Phase 2 by reading the implementation source, not by these tests.
//   * Re-initialise-after-dispose (single-use vs reusable unspecified).
//
// NOTE on platform channels: if RnnoiseMicProcessor.initialize() talks to
// native code over a MethodChannel, these tests need that channel mocked
// (TestWidgetsFlutterBinding is initialised in main for that reason).
// A MissingPluginException in Phase 2 means the impl needs a native side
// the test env cannot see — report it as evidence, do not delete tests.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:protournament_user/services/rnnoise_processor.dart';

// Direct dependencies in pubspec.yaml at Phase-1 baseline (2026-11-22).
// The spec forbids new pub dependencies, so this set must not change —
// except for deps merged by OTHER groups: 'livekit_noise_filter' was added
// by Group 1 (Krisp, merged 2026-11-22 13:47 UTC), not by Group 2. This
// test still fails on any further dep, so G2's no-new-dep rule is intact.
const _baselineDependencies = <String>{
  'flutter',
  'firebase_core',
  'firebase_auth',
  'supabase_flutter',
  'google_sign_in',
  'onesignal_flutter',
  'image_picker',
  'http',
  'share_plus',
  'url_launcher',
  'shared_preferences',
  'cached_network_image',
  'flutter_webrtc',
  'livekit_client',
  'livekit_noise_filter',
  'permission_handler',
  'connectivity_plus',
  'audioplayers',
  'file_picker',
  'image',
  'app_links',
  'pdf',
  'webview_flutter',
};

/// Parses the top-level keys of the `dependencies:` block in pubspec.yaml.
Set<String> _directDependencies(String pubspec) {
  final deps = <String>{};
  var inDeps = false;
  final keyPattern = RegExp(r'^  ([a-z0-9_]+):');
  for (final line in pubspec.split('\n')) {
    if (!inDeps) {
      if (line == 'dependencies:') inDeps = true;
      continue;
    }
    // A non-indented, non-empty line ends the block (next top-level key).
    if (line.isNotEmpty && !line.startsWith(' ')) break;
    final match = keyPattern.firstMatch(line);
    if (match != null) deps.add(match.group(1)!);
  }
  return deps;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('RnnoiseMicProcessor contract (Group 2 verifier)', () {
    test('initialize() completes without error', () async {
      final mic = RnnoiseMicProcessor();
      try {
        await mic.initialize();
      } finally {
        await mic.dispose();
      }
    });

    test('buildProcessor() returns a TrackProcessor<AudioProcessorOptions>',
        () async {
      final mic = RnnoiseMicProcessor();
      try {
        await mic.initialize();
        final processor = await mic.buildProcessor();
        expect(processor, isA<TrackProcessor<AudioProcessorOptions>>());
      } finally {
        await mic.dispose();
      }
    });

    test('built processor has a non-empty name', () async {
      final mic = RnnoiseMicProcessor();
      try {
        await mic.initialize();
        final processor = await mic.buildProcessor();
        expect(processor, isNotNull);
        expect(processor!.name, isNotEmpty);
      } finally {
        await mic.dispose();
      }
    });

    test('built processor plugs into AudioCaptureOptions.processor '
        '(the mic-capture seam)', () async {
      final mic = RnnoiseMicProcessor();
      try {
        await mic.initialize();
        final processor = await mic.buildProcessor();
        // Compile-time proof of the seam: AudioCaptureOptions.processor is
        // typed TrackProcessor<AudioProcessorOptions>?, so this constructor
        // call only compiles if buildProcessor() returns exactly that.
        final options = AudioCaptureOptions(processor: processor);
        expect(options.processor, same(processor));
      } finally {
        await mic.dispose();
      }
    });

    test('built processor processedTrack getter is readable', () async {
      final mic = RnnoiseMicProcessor();
      try {
        await mic.initialize();
        final processor = await mic.buildProcessor();
        expect(processor, isNotNull);
        // Reading must not throw. Value is intentionally NOT asserted:
        // null means in-place processing, non-null means the processor
        // supplies a replacement track — both are valid TrackProcessor
        // designs (see LocalTrack.setProcessor in livekit_client).
        expect(() => processor!.processedTrack, returnsNormally);
      } finally {
        await mic.dispose();
      }
    });

    test('full lifecycle initialize -> buildProcessor -> dispose completes',
        () async {
      final mic = RnnoiseMicProcessor();
      await mic.initialize();
      final processor = await mic.buildProcessor();
      expect(processor, isNotNull);
      await mic.dispose();
    });

    test('dispose() completes without error after initialize() alone',
        () async {
      final mic = RnnoiseMicProcessor();
      await mic.initialize();
      await mic.dispose();
    });
  });

  group('pubspec: no new dependencies (Group 2 verifier)', () {
    late String pubspec;

    setUpAll(() {
      pubspec = File('pubspec.yaml').readAsStringSync();
    });

    test('direct dependency set is unchanged from the Phase-1 baseline', () {
      final deps = _directDependencies(pubspec);
      expect(deps, equals(_baselineDependencies),
          reason: 'No new pub dependencies allowed. Added: '
              '${deps.difference(_baselineDependencies)}; '
              'removed: ${_baselineDependencies.difference(deps)}.');
    });

    test('livekit_client stays at ^2.13.2 and flutter_webrtc at 1.6.3', () {
      expect(pubspec, contains('livekit_client: ^2.13.2'));
      expect(pubspec, contains('flutter_webrtc: 1.6.3'));
    });
  });
}
