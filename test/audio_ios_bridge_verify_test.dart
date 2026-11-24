// ARENA HUB #10 AUDIO — Group 6 VERIFIER (iOS native audio path).
//
// INDEPENDENT tests written from the SPEC ONLY, before seeing the
// implementer's code. The spec: the iOS side of the DSP bridge is
// built in Swift (AVAudioEngine nodes) under ios/Runner/, exposing
// the SAME platform channel `arena_audio/effects` with the SAME
// methods as Android: setReverb / setEcho / setDelay / setBass /
// setEq.
//
// HONEST LIMIT — READ FIRST: this Linux VM has NO Xcode, so iOS
// code CANNOT be compiled, run, or tested here. NOTHING in this
// file proves the iOS bridge works on a real device — only a Mac
// build + run can. What this file proves:
//   Part A — the Dart-side channel contract is well-formed: the
//            channel name and the five method names are exactly
//            the spec strings, and arguments pass through the
//            MethodChannel verbatim (mocked native side).
//   Part B — the Swift sources (once landed) register that same
//            channel, handle all five methods, and use
//            AVAudioEngine nodes. These tests FAIL until the
//            implementer's diff lands — that is expected.
//   Part C — Android parity: IF an Android bridge exists in this
//            copy, its method names must match the spec too. This
//            copy currently has NO Android bridge (another group's
//            scope), so that check is explicitly vacuous until one
//            lands; parity is then checked against the spec names.
//
// ARGUMENT SHAPES: the spec pins method names only, NOT argument
// keys. The canonical payloads below are the verifier's INDEPENDENT
// assumption (documented here so Phase 2 can reconcile them
// against the implementer's Swift argument parsing and the Android
// bridge). The pass-through tests assert verbatim delivery of
// whatever map is sent — they do not hard-pin keys the spec never
// gave. If the landed Swift handler parses different keys, that is
// a Phase-2 finding, not a test failure to hide.
//
// Phase 2 note: if the implementer's diff lands a Dart service
// (e.g. lib/services/audio_effects_service.dart), drive THAT class
// through the mock instead of the test-local client below.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

// ------------------------------------------------------------------
// The contract, pinned once and shared by every part of this file.
// ------------------------------------------------------------------

/// Platform channel name — must match Android exactly.
const String kAudioEffectsChannel = 'arena_audio/effects';

/// The five DSP methods, in spec order. Must match Android exactly.
const List<String> kAudioEffectMethods = <String>[
  'setReverb',
  'setEcho',
  'setDelay',
  'setBass',
  'setEq',
];

/// Canonical example payloads — the verifier's independent
/// assumption (see header). Used as example arguments in the
/// pass-through tests; the Swift handler's real parsing is
/// reconciled in Phase 2.
const Map<String, Map<String, Object>> kCanonicalPayloads =
    <String, Map<String, Object>>{
  'setReverb': <String, Object>{'enabled': true, 'level': 0.5},
  'setEcho': <String, Object>{
    'enabled': true,
    'delayMs': 250.0,
    'feedback': 0.4,
  },
  'setDelay': <String, Object>{
    'enabled': true,
    'delayMs': 300.0,
    'feedback': 0.3,
  },
  'setBass': <String, Object>{'enabled': true, 'level': 0.6},
  'setEq': <String, Object>{
    'enabled': true,
    'bands': <double>[0.0, 0.0, 0.0, 0.0, 0.0],
  },
};

/// Test-local thin client over the spec channel. Deliberately
/// minimal: one method per DSP effect, arguments passed through
/// verbatim as a map. Phase 2 replaces this with the landed Dart
/// service class if one exists.
class AudioEffectsChannel {
  const AudioEffectsChannel();

  static const MethodChannel _channel =
      MethodChannel(kAudioEffectsChannel);

  Future<void> setReverb(Map<String, dynamic> args) =>
      _channel.invokeMethod<void>('setReverb', args);

  Future<void> setEcho(Map<String, dynamic> args) =>
      _channel.invokeMethod<void>('setEcho', args);

  Future<void> setDelay(Map<String, dynamic> args) =>
      _channel.invokeMethod<void>('setDelay', args);

  Future<void> setBass(Map<String, dynamic> args) =>
      _channel.invokeMethod<void>('setBass', args);

  Future<void> setEq(Map<String, dynamic> args) =>
      _channel.invokeMethod<void>('setEq', args);
}

/// Strips full-line comments so a mention inside a comment never
/// counts as code (same pattern as v2017_voice_toggle_test.dart).
String _codeOnly(String src) => src
    .split('\n')
    .where((l) => !l.trimLeft().startsWith('//'))
    .join('\n');

/// All Swift sources under ios/Runner, filename -> code-only text.
Map<String, String> _swiftSources() {
  final dir = Directory('ios/Runner');
  final out = <String, String>{};
  if (!dir.existsSync()) {
    return out;
  }
  for (final e in dir.listSync(recursive: true)) {
    if (e is File && e.path.endsWith('.swift')) {
      final name = e.path.split('/').last;
      out[name] = _codeOnly(e.readAsStringSync());
    }
  }
  return out;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // --------------------------------------------------------------
  // Part A — Dart-side channel contract (mocked native side).
  // These tests need no implementation and must pass in Phase 1.
  // --------------------------------------------------------------
  group('audio iOS bridge — Part A: channel contract (mocked)', () {
    late List<MethodCall> calls;

    setUp(() {
      calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel(kAudioEffectsChannel),
        (MethodCall call) async {
          calls.add(call);
          return null;
        },
      );
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel(kAudioEffectsChannel),
        null,
      );
    });

    test('channel name is exactly arena_audio/effects', () {
      expect(kAudioEffectsChannel, 'arena_audio/effects');
      expect(kAudioEffectsChannel, isNot(contains(' ')));
    });

    test('the contract lists exactly the five spec methods', () {
      expect(
        kAudioEffectMethods,
        <String>['setReverb', 'setEcho', 'setDelay', 'setBass', 'setEq'],
      );
      expect(kAudioEffectMethods.toSet().length, 5,
          reason: 'no duplicate method names');
      for (final m in kAudioEffectMethods) {
        expect(m, equals(m.trim()), reason: 'no stray whitespace in $m');
      }
    });

    test('every spec method has a canonical payload example', () {
      for (final m in kAudioEffectMethods) {
        expect(kCanonicalPayloads, contains(m));
        expect(kCanonicalPayloads[m], isNotEmpty);
      }
    });

    test('setReverb reaches the native side with its arguments', () async {
      const client = AudioEffectsChannel();
      final args = Map<String, dynamic>.from(
          kCanonicalPayloads['setReverb']!);
      await client.setReverb(args);
      expect(calls, hasLength(1));
      expect(calls.single.method, 'setReverb');
      expect(calls.single.arguments, args);
    });

    test('setEcho reaches the native side with its arguments', () async {
      const client = AudioEffectsChannel();
      final args =
          Map<String, dynamic>.from(kCanonicalPayloads['setEcho']!);
      await client.setEcho(args);
      expect(calls, hasLength(1));
      expect(calls.single.method, 'setEcho');
      expect(calls.single.arguments, args);
    });

    test('setDelay reaches the native side with its arguments', () async {
      const client = AudioEffectsChannel();
      final args =
          Map<String, dynamic>.from(kCanonicalPayloads['setDelay']!);
      await client.setDelay(args);
      expect(calls, hasLength(1));
      expect(calls.single.method, 'setDelay');
      expect(calls.single.arguments, args);
    });

    test('setBass reaches the native side with its arguments', () async {
      const client = AudioEffectsChannel();
      final args =
          Map<String, dynamic>.from(kCanonicalPayloads['setBass']!);
      await client.setBass(args);
      expect(calls, hasLength(1));
      expect(calls.single.method, 'setBass');
      expect(calls.single.arguments, args);
    });

    test('setEq reaches the native side with its arguments', () async {
      const client = AudioEffectsChannel();
      final args = Map<String, dynamic>.from(kCanonicalPayloads['setEq']!);
      await client.setEq(args);
      expect(calls, hasLength(1));
      expect(calls.single.method, 'setEq');
      expect(calls.single.arguments, args);
    });

    test('all five methods go over the SAME channel, in order', () async {
      const client = AudioEffectsChannel();
      await client.setReverb(<String, dynamic>{'enabled': false});
      await client.setEcho(<String, dynamic>{'enabled': false});
      await client.setDelay(<String, dynamic>{'enabled': false});
      await client.setBass(<String, dynamic>{'enabled': false});
      await client.setEq(<String, dynamic>{'enabled': false});
      expect(
        calls.map((c) => c.method).toList(),
        kAudioEffectMethods,
      );
    });

    test('an empty argument map still passes through verbatim', () async {
      const client = AudioEffectsChannel();
      await client.setReverb(<String, dynamic>{});
      expect(calls, hasLength(1));
      expect(calls.single.arguments, <String, dynamic>{});
    });

    test('a native PlatformException surfaces to the Dart caller',
        () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel(kAudioEffectsChannel),
        (MethodCall call) async {
          throw PlatformException(
            code: 'UNAVAILABLE',
            message: 'AVAudioEngine not started',
          );
        },
      );
      const client = AudioEffectsChannel();
      await expectLater(
        client.setReverb(<String, dynamic>{'enabled': true}),
        throwsA(isA<PlatformException>().having(
          (e) => e.code,
          'code',
          'UNAVAILABLE',
        )),
      );
    });

    test('an unknown method is not silently swallowed by the client',
        () async {
      // The client exposes only the five spec methods — there is
      // no way to invoke anything else through it. This test pins
      // that by asserting the mock saw ONLY spec method names
      // after a full five-call round trip.
      const client = AudioEffectsChannel();
      await client.setReverb(<String, dynamic>{});
      await client.setEcho(<String, dynamic>{});
      await client.setDelay(<String, dynamic>{});
      await client.setBass(<String, dynamic>{});
      await client.setEq(<String, dynamic>{});
      for (final c in calls) {
        expect(kAudioEffectMethods, contains(c.method));
      }
    });
  });

  // --------------------------------------------------------------
  // Part B — Swift source pins. These FAIL until the implementer's
  // diff lands (no Swift audio files exist yet) — expected in
  // Phase 1. They are filename-agnostic: they scan every *.swift
  // file under ios/Runner, so the implementer's file naming is
  // never assumed.
  // --------------------------------------------------------------
  group('audio iOS bridge — Part B: Swift sources (needs the diff)',
      () {
    test('a Swift file registers the arena_audio/effects channel', () {
      final sources = _swiftSources();
      final hits = sources.entries
          .where((e) => e.value.contains(kAudioEffectsChannel))
          .map((e) => e.key)
          .toList();
      expect(
        hits,
        isNotEmpty,
        reason: 'no Swift file under ios/Runner mentions '
            '$kAudioEffectsChannel — iOS bridge not landed yet',
      );
    });

    test('Swift handles all five spec methods by exact name', () {
      final sources = _swiftSources();
      final all = sources.values.join('\n');
      for (final m in kAudioEffectMethods) {
        expect(
          all,
          contains('"$m"'),
          reason: 'Swift never handles "$m" (looked for the string '
              'literal "$m" in every *.swift under ios/Runner)',
        );
      }
    });

    test('Swift sets a method-call handler on the channel', () {
      final sources = _swiftSources();
      final all = sources.values.join('\n');
      expect(
        all,
        contains('setMethodCallHandler'),
        reason: 'no setMethodCallHandler in any Swift file under '
            'ios/Runner — the channel is never wired to a handler',
      );
    });

    test('Swift uses AVAudioEngine with reverb/delay/EQ nodes', () {
      final sources = _swiftSources();
      final all = sources.values.join('\n');
      expect(all, contains('AVAudioEngine'),
          reason: 'no AVAudioEngine in Swift — the spec requires '
              'AVAudioEngine nodes');
      expect(all, contains('AVAudioUnitReverb'),
          reason: 'no AVAudioUnitReverb — setReverb has no node');
      expect(all, contains('AVAudioUnitDelay'),
          reason: 'no AVAudioUnitDelay — setEcho/setDelay have no node');
      expect(all, contains('AVAudioUnitEQ'),
          reason: 'no AVAudioUnitEQ — setBass/setEq have no node');
    });

    test('new Swift files are audio-scoped (minimal touch)', () {
      // Baseline Swift files in ios/Runner before this work:
      // AppDelegate.swift + SceneDelegate.swift. Any ADDITIONAL
      // Swift file must be audio-related by name.
      const baseline = <String>{'AppDelegate.swift', 'SceneDelegate.swift'};
      final sources = _swiftSources();
      final extra =
          sources.keys.where((n) => !baseline.contains(n)).toList();
      expect(
        extra,
        isNotEmpty,
        reason: 'no new Swift file at all — the iOS bridge has not '
            'landed (expected in Phase 1)',
      );
      for (final name in extra) {
        final lower = name.toLowerCase();
        expect(
          lower.contains('audio') || lower.contains('effect'),
          isTrue,
          reason: 'unexpected new Swift file $name — only '
              'audio/effect Swift files may be added by this work',
        );
      }
    });

    test('AppDelegate wires the audio plugin (or it self-registers)',
        () {
      final sources = _swiftSources();
      final appDelegate = sources['AppDelegate.swift'] ?? '';
      final audioFiles = sources.entries
          .where((e) => e.key != 'AppDelegate.swift')
          .map((e) => e.value)
          .join('\n');
      final wiredInAppDelegate = appDelegate.contains('Audio') &&
          (appDelegate.contains(kAudioEffectsChannel) ||
              appDelegate.contains('register'));
      final selfRegisters = audioFiles.contains('register(') ||
          audioFiles.contains('FlutterPlugin') ||
          audioFiles.contains('registrar');
      expect(
        wiredInAppDelegate || selfRegisters,
        isTrue,
        reason: 'neither AppDelegate wires an audio plugin nor does '
            'any Swift file self-register — the bridge would never '
            'be reachable from Dart',
      );
    });
  });

  // --------------------------------------------------------------
  // Part C — Android parity. This copy currently has NO Android
  // DSP bridge (another group's scope), so the check is explicitly
  // vacuous until one lands here; the test name says so. If an
  // Android bridge IS present, its method names must match the
  // spec exactly.
  // --------------------------------------------------------------
  group('audio iOS bridge — Part C: Android parity', () {
    test(
        'SKIPPED if no Android bridge in this copy — else method names '
        'must match the spec', () {
      final androidDir = Directory('android/app/src/main');
      final hits = <String>[];
      // MERGE FIX (coordinator, 2026-11-22): the Android bridge is split
      // across one file per effect group (BassEqEffect.kt handles
      // setBass/setEq, EchoDelayEffect.kt handles setEcho/setDelay,
      // ReverbEffect.kt handles setReverb) plus a shared dispatcher in
      // MainActivity — no single file handles all five methods. So the
      // check is over the UNION of method names across all
      // channel-handling files; that is what iOS/Android parity means.
      // (The per-file form could never pass with this split.)
      final foundMethods = <String>{};
      if (androidDir.existsSync()) {
        for (final e in androidDir.listSync(recursive: true)) {
          if (e is File &&
              (e.path.endsWith('.kt') || e.path.endsWith('.java'))) {
            final src = _codeOnly(e.readAsStringSync());
            if (src.contains(kAudioEffectsChannel)) {
              hits.add(e.path);
              for (final m in kAudioEffectMethods) {
                if (src.contains('"$m"')) foundMethods.add(m);
              }
            }
          }
        }
      }
      // Only when an Android bridge exists: every spec method must be
      // handled by at least one Android file.
      if (hits.isNotEmpty) {
        for (final m in kAudioEffectMethods) {
          expect(
            foundMethods,
            contains(m),
            reason: 'No Android bridge file handles "$m" — iOS/Android '
                'method names would diverge',
          );
        }
      }
      // If hits is empty, no Android bridge exists in this copy:
      // the check is vacuous BY DESIGN (see header) and parity
      // rests on the spec names, which Part B pins against Swift.
      expect(hits, isA<List<String>>());
    });
  });
}
