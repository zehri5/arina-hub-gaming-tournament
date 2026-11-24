// ARENA HUB #10 AUDIO — SOUNDBOARD END-TO-END ASSET TEST (2026-11-22).
//
// Runs Soundboard.init() against the REAL asset bundle (the 4 approved
// .wavs baked into assets/sounds/, pubspec directory entry
// `- assets/sounds/`) and asserts all 4 pads load, decode to the exact
// frame counts, and play/stop. This is the asset-load path the review
// agent could NOT test (its copy had no .wav files — see
// SOUNDBOARD_INTEGRATION.md §6.7 / §7.6).
//
// The audioplayers calls inside init()/play() are all try/catch'd in
// Soundboard, so no channel mock is needed — an unmocked channel just
// logs and the test continues. The D9 finish timer is cancelled by
// stop()/dispose(), so no test waits out a clip duration.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/audio/soundboard.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The Soundboard constructor creates an AudioPlayer, whose own
  // constructor calls the audioplayers.global channel — without a
  // mock it throws MissingPluginException before any test body runs
  // (same mock as soundboard_test.dart).
  const MethodChannel audioplayersChannel =
      MethodChannel('xyz.luan/audioplayers');
  const MethodChannel audioplayersGlobalChannel =
      MethodChannel('xyz.luan/audioplayers.global');

  late Soundboard board;

  setUp(() {
    final TestDefaultBinaryMessengerBinding binding =
        TestDefaultBinaryMessengerBinding.instance;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      audioplayersChannel,
      (MethodCall call) async => null,
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      audioplayersGlobalChannel,
      (MethodCall call) async => null,
    );
    board = Soundboard();
  });

  tearDown(() async {
    board.dispose();
    // The Soundboard disposes its AudioPlayer fire-and-forget; let
    // that future finish while the channel mocks are still
    // registered — clearing them first throws MissingPluginException
    // as an unhandled async error (same pattern as soundboard_test).
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    final TestDefaultBinaryMessengerBinding binding =
        TestDefaultBinaryMessengerBinding.instance;
    binding.defaultBinaryMessenger
        .setMockMethodCallHandler(audioplayersChannel, null);
    binding.defaultBinaryMessenger
        .setMockMethodCallHandler(audioplayersGlobalChannel, null);
  });

  test('init() loads all 4 approved sounds from the real bundle',
      () async {
    await board.init();

    for (final pad in SoundPad.values) {
      expect(
        board.isPadAvailable(pad),
        isTrue,
        reason: '$pad should be available after init()',
      );
    }
  });

  test('decoded clips have the exact approved frame counts', () async {
    await board.init();

    // Measured by the review agent against the real files
    // (SOUNDBOARD_INTEGRATION.md §6.1): 48 kHz mono, 16-bit PCM.
    expect(board.decodedClip(SoundPad.applause)?.length, 120000);
    expect(board.decodedClip(SoundPad.airHorn)?.length, 79200);
    expect(board.decodedClip(SoundPad.laugh)?.length, 120000);
    expect(board.decodedClip(SoundPad.drumRoll)?.length, 132000);
  });

  test('clip durations match the approved sounds', () async {
    await board.init();

    expect(
      board.clipDuration(SoundPad.applause),
      const Duration(milliseconds: 2500),
    );
    expect(
      board.clipDuration(SoundPad.airHorn),
      const Duration(milliseconds: 1650),
    );
    expect(
      board.clipDuration(SoundPad.laugh),
      const Duration(milliseconds: 2500),
    );
    expect(
      board.clipDuration(SoundPad.drumRoll),
      const Duration(milliseconds: 2750),
    );
  });

  test('play/stop cycle works on a real decoded clip', () async {
    await board.init();

    board.play(SoundPad.applause);
    expect(board.isPlaying, isTrue);
    expect(board.activePad, SoundPad.applause);

    board.stop();
    expect(board.isPlaying, isFalse);
    expect(board.activePad, isNull);
  });

  test('gainFor defaults to pad 0.8 x master 1.0', () async {
    await board.init();

    expect(board.gainFor(SoundPad.applause), 0.8);
    board.setPadVolume(SoundPad.applause, 0.5);
    expect(board.gainFor(SoundPad.applause), 0.5);
    board.setMasterVolume(0.5);
    expect(board.gainFor(SoundPad.applause), 0.25);
  });
}
