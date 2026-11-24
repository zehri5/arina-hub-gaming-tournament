// FIX 21 — RJ Studio mic-processor switch failure (v2020 phone test,
// 2026-11-23 12:05, TEAM voice room): Sameer switched the mic
// processor and got "Mic processor available nahi hai — pehle wala
// chal raha hai." The mic was fine — the new processor's
// initialize() failed and the old one kept running.
//
// ITEM 1: the toast names WHICH processor failed.
// ITEM 2: the init failure cause is found + fixed. Proven by
//   elimination (see the report): DSP is the ONLY kind whose
//   initialize() can return false on Android — Krisp's
//   `LiveKitNoiseFilter.isSupported()` is a pure platform check
//   (true on Android), RNNoise's initialize() always returns true
//   (Dart spectral-gate fallback), and the composite returns true
//   when EITHER child works. So the toast could only have come
//   from a DSP switch. The DSP ping fails iff the native .so did
//   not load, the channel is unregistered, the ping times out, or
//   the ping throws — and the old code collapsed all four into a
//   bare `false`, so the reason was lost. Fixed: the reason is kept
//   (DspMicInitFailure), the ping is retried ONCE on timeout only,
//   and a cached probe shares the one check with initialize().
// ITEM 3: the RJ console picker greys DSP out (with a short reason)
//   when the probe says it cannot run — never tappable-then-toast.
//   The currently-active processor is never disabled.
//
// What these tests CANNOT prove: that libaudio_dsp.so actually
// loads on Sameer's TECNO CAMON 18P (API 30). That needs the phone
// (logcat `DspMic registered (nativeLoaded=...)` line). Never claim
// on-device DSP success from these tests alone.
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/screens/room_screen.dart';
import 'package:protournament_user/services/composite_mic_processor.dart';
import 'package:protournament_user/services/dsp_mic_processor.dart';
import 'package:protournament_user/services/krisp_noise_filter.dart';
import 'package:protournament_user/services/rnnoise_processor.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('FIX 21 item 1 — toast names the processor', () {
    test('rjProcessorDisplayName maps every kind', () {
      expect(rjProcessorDisplayName(MicProcessorKind.dsp), 'DSP');
      expect(rjProcessorDisplayName(MicProcessorKind.krisp), 'Krisp');
      expect(rjProcessorDisplayName(MicProcessorKind.rnnoise), 'RNNoise');
      expect(
        rjProcessorDisplayName(MicProcessorKind.composite),
        'DSP + RNNoise',
      );
    });

    test('switch-failure toast uses the failing kind name', () {
      final room = _read('lib/screens/room_screen.dart');
      final start = room.indexOf('Future<void> _rjSwitchMicProcessor');
      expect(start, isNot(-1), reason: 'missing _rjSwitchMicProcessor');
      final end = room.indexOf('Future<void> _playSoundboardPad', start);
      expect(end, isNot(-1), reason: 'missing switch-function end');
      final fn = room.substring(start, end);
      // The toast interpolates the failing kind's display name.
      expect(fn, contains('rjProcessorDisplayName(kind)'));
      expect(
        fn,
        contains(
          '\$failedName available nahi hai — pehle wala chal raha hai.',
        ),
      );
      // The old bare toast is gone (the generic text survives only
      // as the defensive null-kind fallback, never as the message).
      expect(
        fn,
        isNot(contains("'Mic processor available nahi hai")),
      );
    });
  });

  group('FIX 21 item 2 — DSP init failure reasons + retry + probe', () {
    const channel = MethodChannel('arena_hub_dsp_mic');
    late List<MethodCall> calls;
    FutureOr<bool> Function()? isAvailableAnswer;
    int isAvailableCalls = 0;

    Future<dynamic> handler(MethodCall call) async {
      calls.add(call);
      switch (call.method) {
        case 'isAvailable':
          isAvailableCalls++;
          final answer = isAvailableAnswer;
          if (answer == null) return true;
          return answer();
        case 'setEq':
        case 'setBypass':
        case 'init':
        case 'restart':
          return true;
        case 'framesProcessed':
          return 42;
        case 'lastError':
          return 0;
        default:
          return null;
      }
    }

    setUp(() {
      calls = <MethodCall>[];
      isAvailableCalls = 0;
      isAvailableAnswer = null;
      DspMicProcessor.resetProbeCacheForTest();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, handler);
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      DspMicProcessor.resetProbeCacheForTest();
    });

    test('success: ping true -> init true, reason none', () async {
      final dsp = DspMicProcessor();
      expect(await dsp.initialize(), isTrue);
      expect(dsp.lastInitFailure, DspMicInitFailure.none);
      expect(dsp.isNativeAvailable, isTrue);
      await dsp.dispose();
    });

    test('ping false -> init false, reason nativeAbsent, NO retry',
        () async {
      isAvailableAnswer = () => false;
      final dsp = DspMicProcessor();
      expect(await dsp.initialize(), isFalse);
      expect(dsp.lastInitFailure, DspMicInitFailure.nativeAbsent);
      expect(isAvailableCalls, 1,
          reason: 'native-absent is definitive, never retried');
      await dsp.dispose();
    });

    test('no channel handler -> init false, reason channelMissing',
        () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      final dsp = DspMicProcessor();
      expect(await dsp.initialize(), isFalse);
      expect(dsp.lastInitFailure, DspMicInitFailure.channelMissing);
      await dsp.dispose();
    });

    test('ping throws PlatformException -> init false, reason platformError',
        () async {
      isAvailableAnswer = () => throw PlatformException(code: 'boom');
      final dsp = DspMicProcessor();
      expect(await dsp.initialize(), isFalse);
      expect(dsp.lastInitFailure, DspMicInitFailure.platformError);
      expect(isAvailableCalls, 1,
          reason: 'platform error is definitive, never retried');
      await dsp.dispose();
    });

    test('ping never answers -> init false, reason timeout (2 attempts)',
        () async {
      // Each attempt waits out the 2s timeout; the retry makes this
      // test take ~4s. That is the documented cost of the retry.
      isAvailableAnswer = () => Completer<bool>().future;
      final dsp = DspMicProcessor();
      expect(await dsp.initialize(), isFalse);
      expect(dsp.lastInitFailure, DspMicInitFailure.timeout);
      expect(isAvailableCalls, 2, reason: 'one retry on timeout only');
      await dsp.dispose();
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('retry: first ping hangs, second answers -> init true', () async {
      var n = 0;
      isAvailableAnswer = () {
        n++;
        if (n == 1) return Completer<bool>().future;
        return true;
      };
      final dsp = DspMicProcessor();
      expect(await dsp.initialize(), isTrue);
      expect(dsp.lastInitFailure, DspMicInitFailure.none);
      expect(isAvailableCalls, 2);
      await dsp.dispose();
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('probeAvailable caches: second probe does not re-ping', () async {
      expect(await DspMicProcessor.probeAvailable(), isTrue);
      expect(await DspMicProcessor.probeAvailable(), isTrue);
      expect(isAvailableCalls, 1, reason: 'cached after the first probe');
    });

    test('probeAvailable false when the ping answers false', () async {
      isAvailableAnswer = () => false;
      expect(await DspMicProcessor.probeAvailable(), isFalse);
      expect(isAvailableCalls, 1);
    });

    test('probe and initialize consult the SAME ping', () async {
      isAvailableAnswer = () => false;
      expect(await DspMicProcessor.probeAvailable(), isFalse);
      // initialize() pings again (it never trusts the cache) and
      // reaches the same verdict through the same check.
      final dsp = DspMicProcessor();
      expect(await dsp.initialize(), isFalse);
      expect(dsp.lastInitFailure, DspMicInitFailure.nativeAbsent);
      expect(isAvailableCalls, 2, reason: 'probe ping + init ping');
      await dsp.dispose();
    });

    test('resetProbeCacheForTest clears the cache', () async {
      expect(await DspMicProcessor.probeAvailable(), isTrue);
      expect(isAvailableCalls, 1);
      DspMicProcessor.resetProbeCacheForTest();
      isAvailableAnswer = () => false;
      expect(await DspMicProcessor.probeAvailable(), isFalse);
      expect(isAvailableCalls, 2);
    });
  });

  group('FIX 21 item 2 — elimination: only DSP can fail init', () {
    test('RNNoise init is true with NO native side (spectral gate)',
        () async {
      // No mock handler on arena_hub_rnnoise at all: the ping
      // throws MissingPluginException and init still returns true.
      final rnnoise = RnnoiseMicProcessor();
      expect(await rnnoise.initialize(), isTrue);
      expect(rnnoise.engine, RnnoiseEngine.spectralGate);
      await rnnoise.dispose();
    });

    test('composite init is true with NO native side on either channel',
        () async {
      // No mocks on either channel: the DSP child fails, the
      // RNNoise child falls back — the composite still inits.
      final composite = CompositeMicProcessor();
      expect(await composite.initialize(), isTrue);
      expect(composite.isDspUsable, isFalse);
      expect(composite.isRnnoiseUsable, isTrue);
      await composite.dispose();
    });

    test('Krisp init consults the platform gate only (false on Linux)',
        () async {
      // LiveKitNoiseFilter.isSupported() is a pure platform-list
      // check ([macOS, iOS, android]) — on this Linux test host it
      // is false, so init returns false WITHOUT any native call.
      // On Android the same check is true and the constructor
      // cannot throw, so Krisp init cannot fail there.
      final krisp = KrispMicProcessor();
      expect(await krisp.initialize(), isFalse);
      await krisp.dispose();
    });
  });

  group('FIX 21 item 3 — picker greys out unavailable DSP', () {
    String consoleRegion() {
      final room = _read('lib/screens/room_screen.dart');
      // FIX 22 items 20+21: the console signature carries
      // initialSection now, and the old end marker (the
      // _showMusicSettings comment) is gone with the dialog.
      final start = room.indexOf('Future<void> _showRjVoiceConsole(');
      expect(start, isNot(-1), reason: 'missing _showRjVoiceConsole');
      final end = room.indexOf(
          '// FIX 22 item 22: _showMusicSettings is DELETED', start);
      expect(end, isNot(-1), reason: 'missing console end marker');
      return room.substring(start, end);
    }

    test('console probes DSP availability (one source of truth)', () {
      final sheet = consoleRegion();
      // Same check the switch uses: DspMicProcessor.probeAvailable
      // consults the `isAvailable` ping, exactly like initialize().
      expect(sheet, contains('DspMicProcessor.probeAvailable()'));
      expect(sheet, contains('if (!dspProbeStarted)'));
      // A late probe answer must not touch a closed sheet.
      expect(sheet, contains('if (!sheetCtx.mounted) return;'));
    });

    test('DSP button is disabled when the probe says unavailable', () {
      final sheet = consoleRegion();
      // FIX 22 item 20: the dropdown item is a BUTTON now, and
      // FIX 22 item 8: the label is the SPECIFIC failure reason
      // (never the bare "available nahi"). The DSP call spans
      // lines, so its parts are pinned separately.
      expect(sheet, contains('enabled: dspAvailable != false ||'));
      expect(sheet, contains('dspFailureLabel('));
      expect(sheet, contains('DspMicProcessor.lastProbeFailure)'));
      expect(sheet, isNot(contains('DSP — is device par available nahi')));
    });

    test('the active processor is never disabled', () {
      final sheet = consoleRegion();
      // The enabled expression ORs in the active-kind guard.
      expect(sheet, contains('currentKind == MicProcessorKind.dsp'));
    });

    test('other kinds are never probe-gated', () {
      final sheet = consoleRegion();
      // FIX 22 item 20: RNNoise / composite / Krisp / Off are
      // plain processorBtn calls with NO enabled: argument
      // (default true) — their init cannot fail, so the probe
      // never touches them. Only the DSP call passes enabled:.
      expect(sheet, contains('processorBtn(MicProcessorKind.rnnoise'));
      expect(sheet, contains('processorBtn(MicProcessorKind.composite'));
      expect(sheet, contains('processorBtn(MicProcessorKind.krisp'));
      expect(sheet, contains("processorBtn(null, 'Off'"));
      // Only the DSP button passes enabled: — scoped to the
      // button block (the wider console has one other enabled:
      // a switch inside the panel).
      final blockStart = sheet.indexOf('processorBtn(MicProcessorKind.rnnoise');
      final blockEnd = sheet.indexOf("processorBtn(null, 'Off'");
      final block = sheet.substring(blockStart, blockEnd);
      expect('enabled:'.allMatches(block).length, 1);
    });
  });
}
