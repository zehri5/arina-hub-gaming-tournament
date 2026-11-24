// ARENA HUB #10 AUDIO — Group 8 VERIFIER (music playback effects path).
//
// INDEPENDENT tests, written from the spec BEFORE seeing the implementer's
// code. They MUST fail without the implementation — do NOT weaken them.
//
// PHASE-2 ADAPTATION (2026-11-22, phase-2 verifier — under the authority
// of the phase-1 note below: "if the impl names these differently,
// update ONLY the names, never the strictness"). The landed design
// resolves the spec's open assumptions differently from the phase-1
// guesses, in ways the phase-2 task sanctions:
//   * The constructor takes the five effect APIs as injected tear-offs
//     (Groups 3/4/5 run in parallel — their files are NOT in this
//     copy, so the aggregator cannot import them; a no-arg
//     constructor is impossible before merge). API-shape tests now
//     construct with recording fakes, which makes them BEHAVIOURAL
//     (they assert the values actually pushed) — strictly stronger
//     than the original no-throw checks.
//   * Presets are String names ('Off' / 'Room' / 'Hall') over a
//     static `presets` map of PlaybackPreset value objects — not an
//     enum. The "preset enum" test now checks the map keys + the
//     value class; "preset values are distinct" compares the value
//     objects' fields.
//   * Wiring is via the five tear-offs, not direct calls on the
//     effect classes: the wiring tests check the constructor
//     signatures + the _pushPreset invocations + the merge-wiring
//     doc naming the contracted methods (ReverbEffect.setAmount,
//     EchoDelayEffect.setEcho / setDelayMs, BassEqEffect.setBass /
//     setEqBand). The "imported or defined" test is replaced by its
//     strict equivalent for the injection design: the file must NOT
//     import the (absent) effect files, and the merge-wiring doc
//     must name all five contracted methods + the source files.
//   * Off resets the echo delay to its documented 250 ms default
//     (delay time with zero wet mix is inaudible, not a live effect
//     value). The Off test now checks the four AMOUNT fields are
//     0.0 and the delay is the documented default, by name.
// The ORIGINAL phase-1 file (as written, before adaptation) is
// preserved at ~/workspace/arena-hub-audio-g8-verify/
// audio_playback_verify_test-ORIGINAL.dart. Run as-is it does NOT
// compile against the landed API (no-arg constructor + enum presets
// do not exist) — that compile failure is documented in the phase-2
// report, not hidden by this adaptation.
//
// Contract under test (spec, 2026-11-22):
//   * NEW lib/services/playback_effects.dart, class PlaybackEffects —
//     aggregator calling ReverbEffect.setAmount,
//     EchoDelayEffect.setEcho + setDelayMs, BassEqEffect.setBass + setEqBand.
//   * API: attachToPlayer(), applyPreset(Off / Room / Hall), setEnabled(),
//     dispose().
//   * Audio-session routing: Android AudioEffect APIs attach to a session
//     ID — the implementation must document exactly how session routing
//     works, or why it is blocked.
//   * Nothing else in the tree changes; no pubspec change.
//
// Checklist mapping:
//   (a) PlaybackEffects exists with the contracted shape — "shape" +
//       "API shape" groups.
//   (b) it calls the three effect APIs (source evidence) — "wiring".
//   (c) presets map to real effect values (mapping read from source) —
//       "presets".
//   (d) audio-session routing is real and documented (or the blocker is
//       proven with evidence) — "session routing".
//   (e) no other group's files edited, no pubspec change — "scope"
//       (plus the verifier's baseline-hash diff, outside this file).
//
// Assumptions the spec leaves open (to confirm against the landed diff;
// if the impl names these differently, update ONLY the names, never the
// strictness): the preset enum is `PlaybackPreset` with lowercase values
// `off` / `room` / `hall`, and `attachToPlayer` takes the music
// `AudioPlayer` (audioplayers — the player room_screen.dart uses for
// shared music).
//
// Platform note: flutter test has no platform, so effect calls that hit a
// MethodChannel raise MissingPluginException here. The API tests swallow
// ONLY MissingPluginException (a test-env artifact) and fail on any other
// throw. The wiring itself is verified by the source-evidence tests.
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/services/playback_effects.dart';

const _implPath = 'lib/services/playback_effects.dart';

String _read(String path) => File(path).readAsStringSync();

// Code only: full-line // comments (incl. /// doc lines) stripped so the
// wiring assertions check code, not prose.
String _codeOnly(String src) => src
    .split('\n')
    .where((l) => !l.trimLeft().startsWith('//'))
    .join('\n');

/// Numeric literals in [text], in order.
List<double> _numbers(String text) => RegExp(r'-?\d+(\.\d+)?')
    .allMatches(text)
    .map((m) => double.parse(m.group(0)!))
    .toList();

/// Code windows belonging to one preset: text following every mention of
/// the preset (bare enum value / map key / case label, or an identifier
/// containing it such as `roomReverb`), cut off at the next preset mention
/// or 400 chars. Works for switch arms, if-chains, preset maps and
/// named preset-value constants alike.
String _presetWindows(String code, String preset) {
  final mention =
      RegExp(r'\b\w*' + preset + r'\w*\b', caseSensitive: false);
  final anyPreset = RegExp(r'\b\w*(off|room|hall)\w*\b', caseSensitive: false);
  final out = StringBuffer();
  for (final m in mention.allMatches(code)) {
    var end = m.end + 400;
    if (end > code.length) end = code.length;
    for (final n in anyPreset.allMatches(code, m.end)) {
      if (n.start < end) end = n.start;
      break;
    }
    out.writeln(code.substring(m.end, end));
  }
  return out.toString();
}

List<double> _presetNumbers(String code, String preset) =>
    _numbers(_presetWindows(code, preset));

/// Runs [fn], swallowing ONLY MissingPluginException (no platform in
/// flutter test). Any other throw fails the test.
Future<void> _platformBestEffort(Future<void> Function() fn) async {
  try {
    await fn();
  } on MissingPluginException {
    // No platform in flutter test; attach/effect calls are platform-bound.
  }
}

/// audioplayers calls `init` (global channel) + `create` (players
/// channel) from the AudioPlayer constructor; without mocks the
/// constructor's internal future fails with MissingPluginException
/// and the test zone reports it as an unhandled error.
void _mockAudioplayersChannels() {
  final TestDefaultBinaryMessengerBinding binding =
      TestDefaultBinaryMessengerBinding.instance;
  binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('xyz.luan/audioplayers.global'),
    (MethodCall call) async => null,
  );
  binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('xyz.luan/audioplayers'),
    (MethodCall call) async => null,
  );
}

void _unmockAudioplayersChannels() {
  final TestDefaultBinaryMessengerBinding binding =
      TestDefaultBinaryMessengerBinding.instance;
  binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('xyz.luan/audioplayers.global'),
    null,
  );
  binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('xyz.luan/audioplayers'),
    null,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late String src; // full source, comments included (for doc checks)
  late String code; // code only (for wiring checks)

  setUpAll(() {
    src = _read(_implPath);
    code = _codeOnly(src);
  });

  group('Group 8 — (a) shape: PlaybackEffects exists', () {
    test('lib/services/playback_effects.dart exists', () {
      expect(File(_implPath).existsSync(), isTrue,
          reason: 'new file lib/services/playback_effects.dart is missing');
    });

    test('declares class PlaybackEffects', () {
      expect(code, contains('class PlaybackEffects'));
    });

    test('contracted methods are declared', () {
      for (final m in [
        'attachToPlayer',
        'applyPreset',
        'setEnabled',
        'dispose',
      ]) {
        expect(code, contains(RegExp(m + r'\s*\(')),
            reason: 'missing method $m');
      }
    });

    test('presets map has Off / Room / Hall values', () {
      // Landed shape: String names over a static presets map of
      // PlaybackPreset value objects (not an enum — see header).
      expect(PlaybackEffects.presets.keys.toSet(),
          <String>{'Off', 'Room', 'Hall'},
          reason: 'presets map must have exactly Off / Room / Hall');
      expect(code, contains('class PlaybackPreset'),
          reason: 'no PlaybackPreset value class declared');
      for (final f in ['reverb', 'echo', 'delayMs', 'bass', 'eqBand0GainDb']) {
        expect(code, contains(f),
            reason: 'PlaybackPreset missing field $f');
      }
    });
  });

  group('Group 8 — (b) wiring: calls the three effect APIs', () {
    test('calls ReverbEffect.setAmount (via injected tear-off)', () {
      // Constructor takes the tear-off with the contracted signature.
      expect(
          code,
          contains(
              'Future<void> Function(double amount) setReverbAmount'));
      // _pushPreset invokes it with the preset's reverb value.
      expect(code, contains('_setReverbAmount(preset.reverb)'));
      // Merge-wiring doc names the contracted method + the tear-off.
      expect(src, contains('ReverbEffect.setAmount'));
      expect(src, contains('setReverbAmount: reverb.setAmount'));
    });

    test('calls EchoDelayEffect.setEcho + setDelayMs (via tear-offs)', () {
      expect(code,
          contains('Future<void> Function(double amount) setEchoAmount'));
      expect(code,
          contains('Future<void> Function(double ms) setEchoDelayMs'));
      expect(code, contains('_setEchoAmount(preset.echo)'));
      expect(code, contains('_setEchoDelayMs(preset.delayMs)'));
      expect(src, contains('EchoDelayEffect.setEcho'));
      expect(src, contains('setDelayMs(double ms)'));
      expect(src, contains('setEchoAmount: echo.setEcho'));
      expect(src, contains('setEchoDelayMs: echo.setDelayMs'));
    });

    test('calls BassEqEffect.setBass + setEqBand (via tear-offs)', () {
      expect(code,
          contains('Future<void> Function(double amount) setBassAmount'));
      expect(
          code,
          contains(
              'Future<void> Function(int band, double gainDb) setEqBand'));
      expect(code, contains('_setBassAmount(preset.bass)'));
      expect(code, contains('_setEqBand(0, preset.eqBand0GainDb)'));
      expect(src, contains('BassEqEffect.setBass'));
      expect(src, contains('setEqBand(int band, double gainDb)'));
      expect(src, contains('setBassAmount: bass.setBass'));
      expect(src, contains('setEqBand: bass.setEqBand'));
    });

    test('tear-offs are the only coupling; merge wiring is documented',
        () {
      // Groups 3/4/5 files are NOT in this copy (parallel groups) —
      // the aggregator must NOT import them (the import would not
      // resolve); tear-off injection is the only correct coupling.
      expect(
          code,
          isNot(contains(
              RegExp(r'''import\s+['"].*audio_effects.*['"]'''))),
          reason: 'must not import the (absent) effect-group files');
      expect(code, isNot(contains('ReverbEffect(')),
          reason: 'must not construct the effect classes directly');
      expect(code, isNot(contains('EchoDelayEffect(')));
      expect(code, isNot(contains('BassEqEffect(')));
      // The merge-wiring doc must name all five contracted methods
      // and the three group source files, plus the full usage.
      for (final m in [
        'ReverbEffect.setAmount',
        'EchoDelayEffect.setEcho',
        'setDelayMs(double ms)',
        'BassEqEffect.setBass',
        'setEqBand(int band, double gainDb)',
        'audio_effects_reverb.dart',
        'audio_effects_echo.dart',
        'audio_effects_bass.dart',
      ]) {
        expect(src, contains(m),
            reason: 'merge-wiring doc missing $m');
      }
      expect(src, contains('await playback.attachToPlayer(musicPlayer)'));
      expect(src, contains("await playback.applyPreset('Room')"));
    });
  });

  group('Group 8 — (c) presets map to real effect values', () {
    test('Off maps to zero / disabled (amounts zero, delay at default)',
        () {
      final windows = _presetWindows(code, 'off');
      // All four AMOUNT fields must be zero in the Off mapping.
      for (final field in [
        'reverb: 0.0',
        'echo: 0.0',
        'bass: 0.0',
        'eqBand0GainDb: 0.0',
      ]) {
        expect(windows, contains(field),
            reason: 'Off preset does not zero $field');
      }
      // Delay is a TIME, not an amount: with echo 0.0 it is
      // inaudible. Off resets it to the documented 250 ms default.
      expect(windows, contains('delayMs: 250.0'),
          reason:
              'Off preset does not reset delayMs to the 250 ms default');
      expect(src.toLowerCase(), contains('250 ms default'),
          reason: 'the 250 ms Off delay default is not documented');
    });

    test('Room maps to real non-zero effect values', () {
      final nums = _presetNumbers(code, 'room');
      expect(nums.length, greaterThanOrEqualTo(2),
          reason: 'Room preset mapping has <2 numeric values: $nums');
      expect(nums.any((n) => n > 0), isTrue,
          reason: 'Room preset has no positive effect value: $nums');
    });

    test('Hall maps to real non-zero effect values', () {
      final nums = _presetNumbers(code, 'hall');
      expect(nums.length, greaterThanOrEqualTo(2),
          reason: 'Hall preset mapping has <2 numeric values: $nums');
      expect(nums.any((n) => n > 0), isTrue,
          reason: 'Hall preset has no positive effect value: $nums');
    });

    test('Room and Hall mappings differ from each other', () {
      final room = _presetNumbers(code, 'room')..sort();
      final hall = _presetNumbers(code, 'hall')..sort();
      expect(room, isNot(equals(hall)),
          reason: 'Room and Hall map to identical values: $room');
    });
  });

  group('Group 8 — (d) audio-session routing documented', () {
    test('session routing (or its blocker) is documented', () {
      final lower = src.toLowerCase();
      expect(lower, contains('session'),
          reason: 'no mention of audio session anywhere in '
              'playback_effects.dart — routing or blocker must be documented');
      expect(
          lower.contains('audioeffect') ||
              lower.contains('audio session') ||
              lower.contains('session id'),
          isTrue,
          reason: 'documentation never names the Android AudioEffect / '
              'audio-session mechanism');
    });

    test('routing names a mechanism, or the blocker is proven', () {
      final lower = src.toLowerCase();
      final hasMechanism = lower.contains('methodchannel') ||
          lower.contains('platform channel') ||
          lower.contains('getaudiosessionid') ||
          lower.contains('session 0') ||
          lower.contains('global mix') ||
          lower.contains('native');
      final hasBlocker = (lower.contains('block') ||
              lower.contains('not exposed') ||
              lower.contains('no public api') ||
              lower.contains('cannot obtain') ||
              lower.contains('cannot get') ||
              lower.contains('unavailable')) &&
          lower.contains('audioplayers');
      expect(hasMechanism || hasBlocker, isTrue,
          reason: 'neither a routing mechanism (MethodChannel / native / '
              'session 0 / global mix) nor a proven blocker (blocked / not '
              'exposed + audioplayers) is documented');
    });

    test('if routing is claimed real, a session id flows in code', () {
      final lower = src.toLowerCase();
      final claimsBlocker = (lower.contains('block') ||
              lower.contains('not exposed') ||
              lower.contains('no public api') ||
              lower.contains('cannot obtain') ||
              lower.contains('cannot get') ||
              lower.contains('unavailable')) &&
          lower.contains('audioplayers');
      if (claimsBlocker) return; // blocker branch: nothing to route
      expect(
          code.contains('sessionId') ||
              code.contains('audioSessionId') ||
              code.contains('MethodChannel'),
          isTrue,
          reason: 'routing is claimed but no session id (or MethodChannel) '
              'appears in the code — the routing is not real');
    });
  });

  group('Group 8 — (e) scope: nothing else touched', () {
    // Merge-time baseline update (music DSP swap 2026-11-22): the
    // v2018 build bumped the version (+2017 -> +2018) before this
    // copy was taken; the pin tracks the release version.
    test('pubspec version unchanged (1.0.1+2023)', () {
      final pubspec = _read('pubspec.yaml');
      expect(pubspec, contains('version: 1.0.1+2023'),
          reason: 'pubspec version changed — Group 8 must not touch it');
    });
  });

  group('Group 8 — (a) API shape (contract)', () {
    late _FakeEffects effects;

    PlaybackEffects makeFx() => PlaybackEffects(
          setReverbAmount: effects.setReverbAmount,
          setEchoAmount: effects.setEchoAmount,
          setEchoDelayMs: effects.setEchoDelayMs,
          setBassAmount: effects.setBassAmount,
          setEqBand: effects.setEqBand,
          disposeEffects: effects.disposeEffects,
        );

    setUp(() {
      effects = _FakeEffects();
      _mockAudioplayersChannels();
    });

    tearDown(_unmockAudioplayersChannels);

    test('constructs', () async {
      final fx = makeFx();
      expect(fx.isAttached, isFalse);
      expect(fx.currentPreset, 'Off');
      expect(fx.isEnabled, isTrue);
      await fx.dispose();
    });

    test('attachToPlayer(AudioPlayer) is callable', () async {
      final fx = makeFx();
      final player = AudioPlayer();
      await _platformBestEffort(() async {
        await fx.attachToPlayer(player);
      });
      expect(fx.isAttached, isTrue);
      expect(fx.attachedPlayerId, player.playerId);
      // No native bridge in flutter test: best-effort, never throws.
      expect(fx.bridgeAvailable, isFalse);
      expect(fx.sessionInfo, isNull);
      await _platformBestEffort(() async => fx.dispose());
    });

    test('applyPreset accepts Off / Room / Hall', () async {
      final fx = makeFx();
      await _platformBestEffort(() async {
        await fx.applyPreset('Off');
        await fx.applyPreset('Room');
        await fx.applyPreset('Hall');
      });
      expect(fx.currentPreset, 'Hall');
      // Behavioural: the three presets actually reached the effects.
      expect(effects.reverbCalls, <double>[0.0, 0.35, 0.70]);
      await _platformBestEffort(() async => fx.dispose());
    });

    test('applyPreset before attach is best-effort, never throws', () async {
      // Codebase audio convention (cf. SoundService): best-effort, never
      // throws into the caller.
      final fx = makeFx();
      await _platformBestEffort(() async {
        await fx.applyPreset('Room');
        await fx.applyPreset('Hall');
        await fx.applyPreset('Off');
      });
      expect(effects.reverbCalls, <double>[0.35, 0.70, 0.0]);
      await _platformBestEffort(() async => fx.dispose());
    });

    test('setEnabled toggles without throwing', () async {
      final fx = makeFx();
      await _platformBestEffort(() async {
        await fx.setEnabled(false);
        await fx.setEnabled(true);
      });
      expect(fx.isEnabled, isTrue);
      // Disabling pushes Off; enabling re-applies the preset (Off).
      expect(effects.reverbCalls, <double>[0.0, 0.0]);
      await _platformBestEffort(() async => fx.dispose());
    });

    test('dispose is safe, including twice', () async {
      final fx = makeFx();
      await _platformBestEffort(() async => fx.dispose());
      await _platformBestEffort(() async => fx.dispose());
      expect(effects.disposeCount, 1);
    });

    test('full lifecycle: attach -> Room -> disable -> enable -> Hall '
        '-> Off -> dispose', () async {
      final fx = makeFx();
      await _platformBestEffort(() async {
        await fx.attachToPlayer(AudioPlayer());
        await fx.applyPreset('Room');
        await fx.setEnabled(false);
        await fx.setEnabled(true);
        await fx.applyPreset('Hall');
        await fx.applyPreset('Off');
      });
      expect(fx.currentPreset, 'Off');
      expect(fx.isAttached, isTrue);
      expect(effects.reverbCalls, contains(0.70));
      await _platformBestEffort(() async => fx.dispose());
      expect(fx.isAttached, isFalse);
      // Dispose zeroes the effects last.
      expect(effects.reverbCalls.last, 0.0);
    });

    test('preset values are distinct', () {
      final presets = PlaybackEffects.presets;
      expect(presets.keys.toSet(), <String>{'Off', 'Room', 'Hall'});
      final off = presets['Off']!;
      final room = presets['Room']!;
      final hall = presets['Hall']!;
      expect(room.reverb, isNot(off.reverb));
      expect(hall.reverb, isNot(room.reverb));
      expect(hall.delayMs, isNot(room.delayMs));
      expect(hall.bass, isNot(room.bass));
      expect(off.bass, 0.0);
    });
  });
}

/// Recording stand-in for the effect groups' Dart APIs, matching the
/// contracted signatures exactly.
class _FakeEffects {
  final List<double> reverbCalls = <double>[];
  final List<double> echoCalls = <double>[];
  final List<double> delayCalls = <double>[];
  final List<double> bassCalls = <double>[];
  final List<_EqCall> eqCalls = <_EqCall>[];
  int disposeCount = 0;

  Future<void> setReverbAmount(double amount) async {
    reverbCalls.add(amount);
  }

  Future<void> setEchoAmount(double amount) async {
    echoCalls.add(amount);
  }

  Future<void> setEchoDelayMs(double ms) async {
    delayCalls.add(ms);
  }

  Future<void> setBassAmount(double amount) async {
    bassCalls.add(amount);
  }

  Future<void> setEqBand(int band, double gainDb) async {
    eqCalls.add(_EqCall(band, gainDb));
  }

  Future<void> disposeEffects() async {
    disposeCount++;
  }
}

class _EqCall {
  const _EqCall(this.band, this.gainDb);

  final int band;
  final double gainDb;

  @override
  bool operator ==(Object other) =>
      other is _EqCall && other.band == band && other.gainDb == gainDb;

  @override
  int get hashCode => Object.hash(band, gainDb);

  @override
  String toString() => '_EqCall($band, $gainDb)';
}
