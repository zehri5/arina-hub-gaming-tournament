// FIX 22 items 6 + 8 + 20 — RJ console + DSP pins.
// Item 6: the panel builds even when dsp == null (DSP is NOT
// the gate anymore); the force-stop re-open bug was a Kotlin
// one-shot register singleton — both .kt files re-bind the
// channel when the engine messenger changes.
// Item 8: the REAL DSP failure reason surfaces (Urdu).
// Item 20: 5 processor BUTTONS first in the console, no dropdown.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/services/dsp_mic_processor.dart';

import 'audio_test_helpers.dart';

String _region(String src, String start, String end) {
  final s = src.indexOf(start);
  if (s < 0) return '';
  final e = src.indexOf(end, s + start.length);
  if (e < 0) return '';
  return src.substring(s, e);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('fix22 item 8 — dspFailureLabel mappings', () {
    test('all five reasons map to the right Urdu label', () {
      expect(dspFailureLabel(DspMicInitFailure.nativeAbsent),
          'DSP — native library load nahi ho saki');
      expect(dspFailureLabel(DspMicInitFailure.channelMissing),
          'DSP — app channel nahi mila');
      expect(dspFailureLabel(DspMicInitFailure.timeout),
          'DSP — jawab time out ho gaya');
      expect(dspFailureLabel(DspMicInitFailure.platformError),
          'DSP — platform error');
      expect(dspFailureLabel(DspMicInitFailure.none),
          'DSP — RJ live effects');
    });
  });

  group('fix22 item 6 — probe records the failure reason', () {
    const channel = MethodChannel('arena_hub_dsp_mic');
    FutureOr<bool> Function()? isAvailableAnswer;

    Future<dynamic> handler(MethodCall call) async {
      switch (call.method) {
        case 'isAvailable':
          final answer = isAvailableAnswer;
          if (answer == null) return true;
          return answer();
        case 'init':
        case 'setEq':
        case 'setBypass':
        case 'restart':
          return true;
        case 'framesProcessed':
          return 42;
        case 'lastError':
          return 0;
        case 'nativeLoadError':
          return null;
        default:
          return null;
      }
    }

    setUp(() {
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

    test('probe true twice in one isolate (re-open pin)', () async {
      expect(await DspMicProcessor.probeAvailable(), isTrue);
      expect(await DspMicProcessor.probeAvailable(), isTrue);
      expect(DspMicProcessor.lastProbeFailure, DspMicInitFailure.none);
    });

    test('probe false records nativeAbsent', () async {
      isAvailableAnswer = () => false;
      expect(await DspMicProcessor.probeAvailable(), isFalse);
      expect(DspMicProcessor.lastProbeFailure,
          DspMicInitFailure.nativeAbsent);
    });

    test('fresh processor initializes after a previous init + dispose',
        () async {
      final first = DspMicProcessor();
      expect(await first.initialize(), isTrue);
      await first.dispose();
      // Second consecutive open in the same session: a fresh
      // instance must initialize again (no one-shot state).
      final second = DspMicProcessor();
      expect(await second.initialize(), isTrue);
      expect(second.lastInitFailure, DspMicInitFailure.none);
      await second.dispose();
    });

    test('nativeLoadError returns null when the native side is clean',
        () async {
      expect(await DspMicProcessor.nativeLoadError(), isNull);
    });
  });

  group('fix22 item 6 — Kotlin re-bind (source pins)', () {
    test('both processors re-bind when the messenger changes', () {
      for (final f in [
        'android/app/src/main/kotlin/com/protournament/app/DspMicProcessor.kt',
        'android/app/src/main/kotlin/com/protournament/app/RnnoiseProcessor.kt',
      ]) {
        final kt = requireProjectFile(f);
        expect(kt, contains('boundMessenger'));
        expect(kt, contains('boundMessenger !== messenger'));
        expect(kt, contains('onEngineRebound()'));
      }
    });
  });

  group('fix22 items 6 + 20 — console structure', () {
    late String room;
    late String console;

    setUpAll(() {
      room = codeOnly(requireProjectFile('lib/screens/room_screen.dart'));
      console = _region(
        room,
        'Future<void> _showRjVoiceConsole(',
        'void _showLiveKitPanel() {',
      );
    });

    test('console region exists', () {
      expect(console, isNotEmpty);
    });

    test('gate never fails silently: honest toasts', () {
      expect(console, contains('Pehchan load ho rahi hai'));
      expect(console, contains('RJ panel sirf room host ke liye hai.'));
    });

    test('panel builds with dsp == null (DSP-independent)', () {
      final panel =
          codeOnly(requireProjectFile('lib/widgets/rj_studio_panel.dart'));
      expect(panel, contains('final RjVoiceDsp? dsp;'));
      expect(console, contains('RjStudioPanel('));
      expect(console, isNot(contains('if (voiceDsp != null)')));
    });

    test('Urdu DSP message, English note gone', () {
      expect(room, contains('Live effects ke liye DSP chahiye'));
      expect(room, isNot(contains('Live effects need the DSP mic chain')));
    });

    test('5 processor buttons first, NO DropdownButton', () {
      expect(console, isNot(contains('DropdownButton')));
      expect('processorBtn('.allMatches(console).length, 6,
          reason: '1 definition + 5 buttons');
      expect(console, contains("processorBtn(MicProcessorKind.rnnoise, 'RNNoise'"));
      expect(console, contains('MicProcessorKind.composite'));
      expect(console, contains("processorBtn(MicProcessorKind.krisp, 'Krisp'"));
      expect(console, contains("processorBtn(null, 'Off'"));
    });

    test('DSP button disabled with its reason when unavailable', () {
      expect(console, contains('dspFailureLabel('));
      expect(console, contains('dspAvailable'));
    });

    test('upload errors are honest: file gone + timeout', () {
      expect(room, contains('Ye file ab phone mein nahi hai'));
      expect(room, contains('Upload slow network par time out ho gaya'));
      expect(room, contains('File(path).existsSync()'));
    });
  });
}
