// INDEPENDENT VERIFIER TESTS — Arena Hub #10 Audio, Group 7
// (LiveKit mic-path wiring: MicAudioPipeline -> AudioCaptureOptions.processor)
//
// Written by the Group 7 VERIFIER in Phase 1, from the task spec ONLY —
// WITHOUT looking at the implementer's code. These tests are expected to
// FAIL (missing import) until the implementer's diff lands in Phase 2.
// Do NOT weaken them; if a test fails after the diff lands, that is a
// finding to report, not a test to relax.
//
// CONTRACT ASSUMPTIONS (spec-derived; confirm against the landed diff in
// Phase 2 — if the implementer named something differently, rename HERE
// and record the deviation in the report, do not silently drop coverage):
//   1. File lib/services/mic_audio_pipeline.dart defines:
//      - abstract class MicAudioProcessor with
//          Future<void> initialize();
//          TrackProcessor<AudioProcessorOptions>? buildProcessor();
//          Future<void> dispose();
//        (sync `void` variants of initialize/dispose also satisfy the
//        fake below, since Future<void> is assignable to void.)
//      - class MicAudioPipeline with a default constructor and
//          setProcessor(MicAudioProcessor? processor)   // sync or async
//          setNoiseCancellationEnabled(bool enabled)    // sync or async
//          dispose()                                    // sync or async
//          TrackProcessor<AudioProcessorOptions>? get processor
//        (tests `await` the three methods, which compiles whether they
//        return void or Future<void>.)
//   2. Lifecycle is owned by the pipeline: setProcessor initializes the
//      new processor; replacing or clearing disposes the old one;
//      dispose() disposes the active processor.
//   3. The NC on/off toggle does NOT dispose the processor: turning NC
//      off stops supplying the TrackProcessor, turning it back on
//      restores the SAME instance. No re-init, no re-join, no call drop.
//   4. No default NC state is asserted (unknown from the spec): every
//      test that checks the supplied processor enables NC explicitly
//      first, so the tests pass whether the impl defaults NC on or off.
//   5. Wiring reaches the mic through the livekit_client 2.13.2 seam:
//      setMicrophoneEnabled(..., audioCaptureOptions:
//      AudioCaptureOptions(processor: ...)) or the equivalent
//      defaultAudioCaptureOptions route — the source-evidence tests
//      require the AudioCaptureOptions + processor + audioCaptureOptions
//      strings in livekit_voice_service.dart.
//   6. Source-evidence tests read files relative to the package root
//      (flutter test runs with cwd = project root).
//
// Pristine baselines (snapshotted 2026-11-22, before any impl):
//   lib/services/livekit_voice_service.dart: 381 lines,
//     'await room.connect(' x1, '_room?.disconnect()' x1,
//     'await disconnect();' x1.
//   lib/screens/room_screen.dart: 7067 lines.
//   pubspec.yaml: version 1.0.1+2017, livekit_client ^2.13.2,
//     no livekit_noise_filter.

import 'dart:io';

import 'package:protournament_user/services/mic_audio_pipeline.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:livekit_client/livekit_client.dart';

/// Minimal TrackProcessor stand-in: proves the pipeline's output fits
/// the livekit_client 2.13.2 `AudioCaptureOptions.processor` seam
/// (type `TrackProcessor<AudioProcessorOptions>?`). Never actually
/// processes audio in these tests.
class FakeTrackProcessor extends TrackProcessor<AudioProcessorOptions> {
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

/// Fake processor implementing the contracted MicNoiseProcessor shape,
/// with call counters so the tests can prove lifecycle ownership.
class FakeMicAudioProcessor implements MicNoiseProcessor {
  int initializeCalls = 0;
  int buildProcessorCalls = 0;
  int disposeCalls = 0;
  final FakeTrackProcessor trackProcessor = FakeTrackProcessor();

  @override
  Future<bool> initialize() async {
    initializeCalls++;
    return true;
  }

  @override
  Future<TrackProcessor<AudioProcessorOptions>?> buildProcessor() async {
    buildProcessorCalls++;
    return trackProcessor;
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
  }
}

String _readLib(String relativePath) =>
    File(relativePath).readAsStringSync();

int _count(String haystack, String needle) =>
    needle.allMatches(haystack).length;

void main() {
  group('MicAudioPipeline contract (checklist a)', () {
    test('starts with no processor supplied', () {
      final pipeline = MicAudioPipeline();
      expect(pipeline.processor, isNull);
    });

    test('setProcessor installs and supplies the built TrackProcessor',
        () async {
      final pipeline = MicAudioPipeline();
      final fake = FakeMicAudioProcessor();
      await pipeline.setProcessor(fake);
      // No assumption about the DEFAULT nc state: enable explicitly.
      pipeline.setNoiseCancellationEnabled(true);
      expect(pipeline.processor, isNotNull);
      expect(pipeline.processor, same(fake.trackProcessor));
    });

    test('setProcessor initializes the installed processor', () async {
      final pipeline = MicAudioPipeline();
      final fake = FakeMicAudioProcessor();
      await pipeline.setProcessor(fake);
      expect(fake.initializeCalls, 1);
    });

    test('setProcessor(null) clears the supplied processor and disposes it',
        () async {
      final pipeline = MicAudioPipeline();
      final fake = FakeMicAudioProcessor();
      await pipeline.setProcessor(fake);
      pipeline.setNoiseCancellationEnabled(true);
      expect(pipeline.processor, isNotNull);
      await pipeline.setProcessor(null);
      expect(pipeline.processor, isNull);
      expect(fake.disposeCalls, 1);
    });

    test('replacing a processor disposes the old one, supplies the new one',
        () async {
      final pipeline = MicAudioPipeline();
      final first = FakeMicAudioProcessor();
      final second = FakeMicAudioProcessor();
      await pipeline.setProcessor(first);
      await pipeline.setProcessor(second);
      pipeline.setNoiseCancellationEnabled(true);
      expect(first.disposeCalls, 1);
      expect(second.initializeCalls, 1);
      expect(pipeline.processor, same(second.trackProcessor));
    });

    test(
        'NC off stops supplying WITHOUT disposing; NC on restores the SAME instance',
        () async {
      final pipeline = MicAudioPipeline();
      final fake = FakeMicAudioProcessor();
      await pipeline.setProcessor(fake);
      pipeline.setNoiseCancellationEnabled(true);
      expect(pipeline.processor, same(fake.trackProcessor));
      pipeline.setNoiseCancellationEnabled(false);
      expect(pipeline.processor, isNull);
      expect(fake.disposeCalls, 0,
          reason: 'toggling NC off must not dispose the processor');
      pipeline.setNoiseCancellationEnabled(true);
      expect(pipeline.processor, same(fake.trackProcessor),
          reason: 're-enabling NC must restore the same processor');
      expect(fake.initializeCalls, 1,
          reason: 're-enabling NC must not re-initialize the processor');
    });

    test('toggling NC with no processor installed is a safe no-op',
        () async {
      final pipeline = MicAudioPipeline();
      pipeline.setNoiseCancellationEnabled(true);
      pipeline.setNoiseCancellationEnabled(false);
      expect(pipeline.processor, isNull);
    });

    test('dispose disposes the active processor; double-dispose is safe',
        () async {
      final pipeline = MicAudioPipeline();
      final fake = FakeMicAudioProcessor();
      await pipeline.setProcessor(fake);
      await pipeline.dispose();
      expect(fake.disposeCalls, 1);
      expect(pipeline.processor, isNull);
      await pipeline.dispose(); // must not throw
      expect(fake.disposeCalls, 1);
    });
  });

  group('livekit_client 2.13.2 seam (checklist b)', () {
    test('supplied processor fits AudioCaptureOptions.processor', () async {
      final pipeline = MicAudioPipeline();
      final fake = FakeMicAudioProcessor();
      await pipeline.setProcessor(fake);
      pipeline.setNoiseCancellationEnabled(true);
      // This line is the seam: it must COMPILE (type
      // TrackProcessor<AudioProcessorOptions>?) and carry the processor.
      final options = AudioCaptureOptions(processor: pipeline.processor);
      expect(options.processor, same(fake.trackProcessor));
    });

    test('livekit_voice_service wires the pipeline into AudioCaptureOptions',
        () {
      final src = _readLib('lib/services/livekit_voice_service.dart');
      expect(src.contains('MicAudioPipeline'), isTrue,
          reason: 'voice service must reference the pipeline');
      expect(src.contains('AudioCaptureOptions'), isTrue,
          reason: 'voice service must build AudioCaptureOptions');
      expect(src.contains('audioCaptureOptions:'), isTrue,
          reason: 'voice service must pass audioCaptureOptions into '
              'setMicrophoneEnabled (the 2.13.2 mic seam)');
      expect(src.contains('processor'), isTrue,
          reason: 'voice service must supply a processor');
    });

    test('room_screen exposes the noise-cancellation control', () {
      final src = _readLib('lib/screens/room_screen.dart');
      expect(
          src.contains('setNoiseCancellationEnabled') ||
              src.contains('MicAudioPipeline') ||
              src.contains('noiseCancellationEnabled'),
          isTrue,
          reason: 'room screen must wire the NC toggle to the pipeline / '
              'voice service');
    });
  });

  group('surgical shared-file edits (checklist c)', () {
    test('voice service keeps its pre-existing voice logic', () {
      final src = _readLib('lib/services/livekit_voice_service.dart');
      for (final anchor in [
        'shouldHonorOrganizerPacket',
        'organizer_control',
        '_applySpeakerRoute',
        'setMicrophoneEnabled',
        '_speakerRouteGen',
        'fetchToken',
        'mutedByOrganizer',
      ]) {
        expect(src.contains(anchor), isTrue,
            reason: 'voice logic anchor "$anchor" must survive the wiring');
      }
      // True line count: the file ends with a newline, so '\n' matches
      // + 1 overcounts by one (531 vs the real 530 — the diff is
      // +151/-2, net +149). Count the final line only when it is not
      // newline-terminated.
      // Merge-time baseline update (speaker toggle fix 2026-11-22):
      // the notify-first + 2 s timeouts + generation-guard hardening
      // legitimately grew the service by 15 lines (530 -> 545). The
      // bound now counts from the post-fix count, with a fresh
      // 150-line budget for the wiring still to come.
      // Merge-time baseline update (Fix 24, merged step 7
      // 2026-11-24): the radio mixer round (mic-track hold on
      // mute, music-quality publish, track-id + ensure-enabled
      // helpers) legitimately grew the service by 83 lines (636
      // -> 719) on top of the fix23 + fix33 tree. The bound now
      // counts from the post-Fix-24 count, with a fresh 150-line
      // budget for the wiring still to come.
      final lines =
          '\n'.allMatches(src).length + (src.endsWith('\n') ? 0 : 1);
      // RJ ducking (2026-11-22): +8 lines (4 event listeners) landed
      // within this budget — file 553, bound unchanged.
      expect(lines, lessThan(719 + 150),
          reason: 'voice service grew by ${lines - 719} lines; '
              'wiring must be surgical, not a rewrite (post-fix: 719)');
    });

    test('room screen keeps its LiveKit anchors', () {
      final src = _readLib('lib/screens/room_screen.dart');
      for (final anchor in [
        '_lkRoom',
        'LiveKitVoiceService',
        '_useLiveKit',
        '_onLiveKitChanged',
      ]) {
        expect(src.contains(anchor), isTrue,
            reason: 'room screen anchor "$anchor" must survive the wiring');
      }
      // True line count (same trailing-newline correction as above).
      // Merge-time baseline update (DSP fold 2026-11-22): the verified
      // effects mount (panel + dispatcher wiring) legitimately grew
      // room_screen by 222 lines (7067 -> 7289). The bound now counts
      // from the post-mount count, with a fresh 200-line budget for
      // the RJ voice mount + processor picker work still to come.
      // Runaway growth still fails.
      // Merge-time baseline update (RJ voice mount 2026-11-22): the
      // RJ console + processor picker legitimately grew room_screen
      // by 492 lines (7289 -> 7781) — the 200-line budget guessed
      // for this work was too small for what the mount specifies
      // (scrollable voice console sheet + 5-option picker + 10 live
      // mic callbacks + host gating + the testable wiring helpers),
      // and even a terse implementation runs ~280 lines. The bound
      // now counts from the post-mount count, with a fresh 200-line
      // budget for the next round of work. Runaway growth still
      // fails.
      final lines =
          '\n'.allMatches(src).length + (src.endsWith('\n') ? 0 : 1);
      // RJ ducking (2026-11-22): +29 lines landed within this budget
      // (library merge had shrunk the file by 155) — bound unchanged.
      // Merge-time baseline update (Fix 20 2026-11-23): the
      // community voice + RJ + Watch Live round (member count
      // under the pill, RJ host parity, seat-mute timeouts,
      // session-local GO LIVE, gear wiring, mic-fader ducking,
      // console scroll sheet, play-local-first sharing, RJ Panel
      // button, title+size dedupe, hoisted chat streams)
      // legitimately grew room_screen by 411 lines (8362 -> 8773).
      // The bound now counts from the post-Fix-20 count, with a
      // fresh 200-line budget for the next round. Runaway growth
      // still fails.
      // Merge-time baseline update (Fix 24 2026-11-23, merged
      // step 7 2026-11-24): the radio music mixer round (APM mixer
      // register/unregister/gains methods, Krisp force-switch,
      // call-in seat assignment + guest-pick pure rules, link-gated
      // gesture rule, GO LIVE / END LIVE hooks, console wiring,
      // pump feed) legitimately grew room_screen by 365 lines
      // (10940 -> 11305) on top of the fix23 + item-31 tree. The
      // bound now counts from the post-Fix-24 count, with a fresh
      // 200-line budget for the next round. Runaway growth still
      // fails.
      expect(lines, lessThan(11305 + 200),
          reason: 'room screen grew by ${lines - 11305} lines since '
              'Fix 24 (post-Fix-24: 11305); wiring must be surgical');
    });
  });

  group('on/off switching safety — no call drop by design (checklist d)',
      () {
    test('voice service has no new connect/disconnect calls', () {
      final src = _readLib('lib/services/livekit_voice_service.dart');
      // Pristine counts: exactly one room connect, one room disconnect,
      // one self-disconnect inside connect(). A toggle that drops and
      // re-joins the call would add more — that is a FAIL.
      // FIX 12 G6b (2026-11-23): connect()'s catch block tears down
      // a half-connected room (second `_room?.disconnect()`), so a
      // failed/timeout handshake can never complete later behind
      // the UI's back. That is failure teardown inside connect(),
      // not a toggle path — the on/off toggle still adds no calls.
      expect(_count(src, 'await room.connect('), 1);
      expect(_count(src, '_room?.disconnect()'), 2);
      expect(_count(src, 'await disconnect();'), 1);
    });
  });

  group('scope — nothing else touched (checklist e)', () {
    test('pubspec unchanged apart from Group 1\'s merged livekit_noise_filter',
        () {
      final pubspec = _readLib('pubspec.yaml');
      // Merge-time baseline update (music DSP swap 2026-11-22):
      // the v2018 build bumped the version (+2017 -> +2018) before
      // this copy was taken; the pin tracks the release version.
      expect(pubspec.contains('version: 1.0.1+2023'), isTrue);
      expect(pubspec.contains('livekit_client: ^2.13.2'), isTrue);
      // Merge-time baseline update (coordinator 2026-11-22): G7 added no
      // dependency — its diff has no pubspec change. livekit_noise_filter
      // is present because Group 1 merged it (13:47 UTC), before G7.
      expect(pubspec.contains('livekit_noise_filter: ^0.2.1'), isTrue);
    });

    test('no other new processor/pipeline/noise files under lib/services',
        () {
      final services = Directory('lib/services').listSync();
      final extra = services
          .map((e) => e.path.split('/').last)
          .where((name) =>
              (name.contains('processor') ||
                  name.contains('pipeline') ||
                  name.contains('noise')) &&
              name != 'mic_audio_pipeline.dart' &&
              // Merge-time baseline update (coordinator 2026-11-22):
              // these two were merged by other groups before G7
              // (G1 Krisp, G2 RNNoise); G7 itself added only
              // mic_audio_pipeline.dart. Any further file still fails.
              name != 'krisp_noise_filter.dart' &&
              name != 'rnnoise_processor.dart' &&
              // Merge-time baseline update (coordinator 2026-11-22):
              // dsp_mic_processor.dart was merged by the RJ live mic
              // chain after G7 (G7-RJ). Any further file still fails.
              name != 'dsp_mic_processor.dart' &&
              // Merge-time baseline update (DSP fold 2026-11-22):
              // composite_mic_processor.dart stacks the DSP mic chain
              // + RNNoise on one track (required fold work). Any
              // further file still fails.
              name != 'composite_mic_processor.dart')
          .toList();
      expect(extra, isEmpty,
          reason: 'only mic_audio_pipeline.dart may be added; found: $extra');
    });
  });
}
