// ARENA HUB #10 AUDIO — shared test harness (Group 10).
//
// This file holds the audio contract as the tests see it, plus the fake
// channel and source-presence helpers the audio_*_test.dart files share.
// It contains NO tests, so `flutter test` never runs it directly.
//
// Shared contracts (~/workspace/arena-hub-audio/COORDINATION.md):
//   * Platform channel `arena_audio/effects`, methods setReverb /
//     setEcho / setDelay / setBass / setEq.
//   * G3 lib/services/audio_effects_reverb.dart — ReverbEffect
//     .setAmount(double) / .dispose().
//   * G4 lib/services/audio_effects_echo.dart — EchoDelayEffect
//     .setEcho(double) / .setDelayMs(double) / .dispose().
//   * G5 lib/services/audio_effects_bass.dart — BassEqEffect
//     .setBass(double) / .setEqBand(int, double) / .dispose().
//   * Mic processors: initialize() / buildProcessor() -> TrackProcessor?
//     / dispose(). G1 lib/services/krisp_noise_filter.dart
//     (KrispMicProcessor); G2 lib/services/rnnoise_processor.dart
//     (RnnoiseMicProcessor).
//   * G7 lib/services/mic_audio_pipeline.dart (MicAudioPipeline).
//   * G8 lib/services/playback_effects.dart (PlaybackEffects:
//     attachToPlayer / applyPreset Off-Room-Hall / setEnabled / dispose).
//   * G9 lib/screens/audio_effects_panel.dart (callbacks onReverb /
//     onEcho / onDelayMs / onBass / onPreset / onNoiseCancellation).
//
// CANONICAL ARGUMENT ENCODING — the LANDED encoding, as the real
// services emit it (reconciled by the coordinator 2026-11-22 — the
// phase-1 bare-double encoding never landed; see FINDING G1 in
// test/audio_impl_contract_test.dart):
//   setReverb / setEcho / setBass : {'amount': double 0.0-1.0}.
//   setDelay                      : {'ms': double, delay in ms, 0-2000}.
//   setEq                         : {'band': int >= 0, 'gainDb': double dB -15..+15}.
//     (No upper band bound — setEqBand forwards band 9 raw; only
//     negative bands throw ArgumentError. EQ clamp is ±15 dB, not ±12.)
// The native sides in G3/G4/G5/G6 must decode exactly this.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The platform-channel contract for audio effects.
abstract final class AudioEffectsContract {
  static const String channelName = 'arena_audio/effects';

  static const String setReverb = 'setReverb';
  static const String setEcho = 'setEcho';
  static const String setDelay = 'setDelay';
  static const String setBass = 'setBass';
  static const String setEq = 'setEq';

  /// The closed set of methods any audio code may send on the channel.
  static const Set<String> allMethods = <String>{
    setReverb,
    setEcho,
    setDelay,
    setBass,
    setEq,
  };

  /// Level range for setReverb / setEcho / setBass (0 = off, 1 = full).
  static const double minLevel = 0.0;
  static const double maxLevel = 1.0;

  /// Delay range for setDelay, in milliseconds.
  static const double minDelayMs = 0.0;
  static const double maxDelayMs = 2000.0;

  /// EQ band floor for setEq (no upper bound — the landed impl
  /// forwards any non-negative band raw; only negative bands throw).
  static const int minEqBand = 0;

  /// EQ gain range for setEq, in dB (landed clamp is ±15 dB).
  static const double minEqGainDb = -15.0;
  static const double maxEqGainDb = 15.0;

  static const MethodChannel channel = MethodChannel(channelName);
}

/// A mock handler for the audio-effects channel. Records every call in
/// order, and lets a test script a reply or an error (e.g. a
/// [PlatformException] from the native side).
///
/// Constructing one installs the mock; call [dispose] in tearDown to
/// remove it.
class FakeAudioEffectsChannel {
  FakeAudioEffectsChannel() {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      AudioEffectsContract.channel,
      _handle,
    );
  }

  /// Every call received, in order.
  final List<MethodCall> calls = <MethodCall>[];

  /// Value the mock returns for every call (null by default).
  Object? reply;

  /// When non-null, the mock throws this instead of replying.
  Exception? error;

  Future<Object?> _handle(MethodCall call) async {
    calls.add(call);
    final Exception? failure = error;
    if (failure != null) {
      throw failure;
    }
    return reply;
  }

  void dispose() {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AudioEffectsContract.channel, null);
  }

  /// Calls received for [method], in order.
  List<MethodCall> callsNamed(String method) =>
      calls.where((MethodCall c) => c.method == method).toList();
}

/// Sends exactly what the contract requires on the channel: the golden
/// reference for what conforming impl code must emit. The contract tests
/// assert the mock receives these calls; the impl-conformance tests
/// assert the real effect classes emit the same shapes.
class GoldenAudioEffectsSender {
  GoldenAudioEffectsSender([MethodChannel? channel])
      : _channel = channel ?? AudioEffectsContract.channel;

  final MethodChannel _channel;

  Future<void> sendReverb(double level) =>
      _channel.invokeMethod<void>(AudioEffectsContract.setReverb,
          <String, Object>{'amount': level});

  Future<void> sendEcho(double level) =>
      _channel.invokeMethod<void>(AudioEffectsContract.setEcho,
          <String, Object>{'amount': level});

  Future<void> sendDelay(double delayMs) =>
      _channel.invokeMethod<void>(AudioEffectsContract.setDelay,
          <String, Object>{'ms': delayMs});

  Future<void> sendBass(double level) =>
      _channel.invokeMethod<void>(AudioEffectsContract.setBass,
          <String, Object>{'amount': level});

  Future<void> sendEq(int band, double gain) =>
      _channel.invokeMethod<void>(
        AudioEffectsContract.setEq,
        <String, Object>{'band': band, 'gainDb': gain},
      );
}

/// Fails unless [call] is a conforming invocation of [method]: exact
/// method name, canonical argument shape, and in-range values.
void assertConformingCall(MethodCall call, String method) {
  expect(
    call.method,
    method,
    reason: 'expected channel method $method, got ${call.method}',
  );
  final Object? args = call.arguments;
  switch (method) {
    case AudioEffectsContract.setReverb:
    case AudioEffectsContract.setEcho:
    case AudioEffectsContract.setBass:
      expect(
        args,
        isA<Map<dynamic, dynamic>>(),
        reason: '$method must carry an {amount} map, got $args',
      );
      final Map<dynamic, dynamic> levelMap = args as Map<dynamic, dynamic>;
      expect(
        levelMap.containsKey('amount'),
        isTrue,
        reason: '$method map must carry the amount key, got ${levelMap.keys}',
      );
      final Object? levelArg = levelMap['amount'];
      expect(
        levelArg,
        isA<double>(),
        reason: '$method amount must be a double, got $levelArg',
      );
      final double level = levelArg as double;
      expect(
        level,
        inInclusiveRange(
          AudioEffectsContract.minLevel,
          AudioEffectsContract.maxLevel,
        ),
        reason: '$method level $level outside 0.0-1.0',
      );
    case AudioEffectsContract.setDelay:
      expect(
        args,
        isA<Map<dynamic, dynamic>>(),
        reason: "setDelay must carry an {ms} map, got $args",
      );
      final Map<dynamic, dynamic> delayMap = args as Map<dynamic, dynamic>;
      expect(
        delayMap.containsKey('ms'),
        isTrue,
        reason: "setDelay map must carry the ms key, got ${delayMap.keys}",
      );
      final Object? delayArg = delayMap['ms'];
      expect(
        delayArg,
        isA<double>(),
        reason: 'setDelay ms must be a double, got $delayArg',
      );
      final double delayMs = delayArg as double;
      expect(
        delayMs,
        inInclusiveRange(
          AudioEffectsContract.minDelayMs,
          AudioEffectsContract.maxDelayMs,
        ),
        reason: 'setDelay $delayMs ms outside 0-2000',
      );
    case AudioEffectsContract.setEq:
      expect(
        args,
        isA<Map<dynamic, dynamic>>(),
        reason: 'setEq must carry a {band, gainDb} map, got $args',
      );
      final Map<dynamic, dynamic> map = args as Map<dynamic, dynamic>;
      expect(
        map.length,
        2,
        reason: 'setEq map must have exactly 2 keys, got ${map.keys}',
      );
      expect(
        map.containsKey('band') && map.containsKey('gainDb'),
        isTrue,
        reason: 'setEq map keys must be band + gainDb, got ${map.keys}',
      );
      final Object? band = map['band'];
      final Object? gain = map['gainDb'];
      expect(
        band,
        isA<int>(),
        reason: 'setEq band must be an int, got $band',
      );
      expect(
        band as int,
        greaterThanOrEqualTo(AudioEffectsContract.minEqBand),
        reason: 'setEq band $band is negative (no upper bound — the '
            'landed impl forwards any non-negative band raw)',
      );
      expect(
        gain,
        isA<double>(),
        reason: 'setEq gainDb must be a double (dB), got $gain',
      );
      expect(
        gain as double,
        inInclusiveRange(
          AudioEffectsContract.minEqGainDb,
          AudioEffectsContract.maxEqGainDb,
        ),
        reason: 'setEq gainDb $gain dB outside -15..+15',
      );
    default:
      fail('unknown channel method: $method');
  }
}

/// Fails unless every call in [calls] uses one of the five contracted
/// method names.
void assertOnlyKnownMethods(Iterable<MethodCall> calls) {
  for (final MethodCall call in calls) {
    expect(
      AudioEffectsContract.allMethods,
      contains(call.method),
      reason: 'unknown channel method sent: ${call.method}',
    );
  }
}

/// The project root: the directory containing pubspec.yaml, found by
/// walking up from the current working directory. `flutter test` runs
/// with the project root as the working directory.
Directory findProjectRoot() {
  var dir = Directory.current;
  while (!File('${dir.path}/pubspec.yaml').existsSync()) {
    final Directory parent = dir.parent;
    if (parent.path == dir.path) {
      throw StateError(
        'project root (pubspec.yaml) not found above '
        '${Directory.current.path}',
      );
    }
    dir = parent;
  }
  return dir;
}

/// Reads [relativePath] (relative to the project root) as text, failing
/// the test with a clear message when the file is absent. Use this for
/// presence gates: a missing contract file must fail loudly, not crash
/// on a FileSystemException.
String requireProjectFile(String relativePath) {
  final String path = '${findProjectRoot().path}/$relativePath';
  expect(
    File(path).existsSync(),
    isTrue,
    reason: 'contract file missing: $relativePath',
  );
  return File(path).readAsStringSync();
}

/// Source with full-line comments stripped, so a mention inside a
/// comment never counts as code. (Same pattern as
/// v2017_voice_toggle_test.dart.)
String codeOnly(String src) => src
    .split('\n')
    .where((String l) => !l.trimLeft().startsWith('//'))
    .join('\n');

/// True when any file under [relativeDir] (relative to the project
/// root) contains [needle] in code. Binary files are skipped via
/// lenient UTF-8 decoding.
bool projectTreeContains(String relativeDir, String needle) {
  final Directory dir =
      Directory('${findProjectRoot().path}/$relativeDir');
  if (!dir.existsSync()) {
    return false;
  }
  for (final FileSystemEntity entity
      in dir.listSync(recursive: true, followLinks: false)) {
    if (entity is File) {
      final String text =
          utf8.decode(entity.readAsBytesSync(), allowMalformed: true);
      if (codeOnly(text).contains(needle)) {
        return true;
      }
    }
  }
  return false;
}
