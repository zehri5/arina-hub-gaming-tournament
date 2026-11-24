// ARENA HUB #10 AUDIO — SoundboardPads widget tests (review group,
// 2026-11-22).
//
// Covers lib/widgets/soundboard_pads.dart: 4 pads render, unavailable
// pads are greyed + untappable, tapping an available pad plays it
// (gold underline + gold label), gold is #FDC903 only (no forbidden
// #FFE20A / #FFCC00 anywhere).
//
// Clips are generated test tones injected via debugInjectClip, plus
// one real-file test (applause.wav from the external dir, read with
// dart:io — NOT as an asset). No placeholder .wav is ever added to
// the tree or to pubspec assets.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/audio/soundboard.dart';
import 'package:protournament_user/audio/wav_decoder.dart';
import 'package:protournament_user/widgets/soundboard_pads.dart';

const Color _gold = Color(0xFFFDC903);
const Color _forbiddenGoldA = Color(0xFFFFE20A);
const Color _forbiddenGoldB = Color(0xFFFFCC00);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel audioplayersChannel =
      MethodChannel('xyz.luan/audioplayers');
  const MethodChannel audioplayersGlobalChannel =
      MethodChannel('xyz.luan/audioplayers.global');

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
  });

  tearDown(() {
    final TestDefaultBinaryMessengerBinding binding =
        TestDefaultBinaryMessengerBinding.instance;
    binding.defaultBinaryMessenger
        .setMockMethodCallHandler(audioplayersChannel, null);
    binding.defaultBinaryMessenger
        .setMockMethodCallHandler(audioplayersGlobalChannel, null);
  });

  group('SoundboardPads', () {
    late Soundboard soundboard;

    setUp(() {
      soundboard = Soundboard(playLocally: false);
    });

    tearDown(() async {
      soundboard.dispose();
      // Flush the fire-and-forget AudioPlayer.dispose() while the
      // channel mocks are still registered (see soundboard_test.dart).
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
    });

    Future<void> pumpPads(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SoundboardPads(soundboard: soundboard),
          ),
        ),
      );
    }

    List<double> padOpacities(WidgetTester tester) {
      return tester
          .widgetList<Opacity>(find.byType(Opacity))
          .map((Opacity o) => o.opacity)
          .toList();
    }

    Finder goldUnderlineFinder() {
      return find.byWidgetPredicate(
        (Widget w) =>
            w is Container &&
            w.decoration is BoxDecoration &&
            (w.decoration! as BoxDecoration).color == _gold,
      );
    }

    testWidgets('4 pads render, all disabled when no clips loaded',
        (WidgetTester tester) async {
      await pumpPads(tester);
      expect(find.text('APPLAUSE'), findsOneWidget);
      expect(find.text('AIR HORN'), findsOneWidget);
      expect(find.text('LAUGH'), findsOneWidget);
      expect(find.text('DRUM'), findsOneWidget);
      // All greyed at 45% opacity (pad order: applause, air horn,
      // laugh, drum).
      expect(padOpacities(tester), <double>[0.45, 0.45, 0.45, 0.45]);
      // Tapping a disabled pad does nothing.
      await tester.tap(find.text('APPLAUSE'));
      await tester.pump();
      expect(soundboard.isPlaying, isFalse);
      expect(soundboard.activePad, isNull);
      expect(goldUnderlineFinder(), findsNothing);
    });

    testWidgets('injecting a clip enables only its pad',
        (WidgetTester tester) async {
      await pumpPads(tester);
      expect(padOpacities(tester), <double>[0.45, 0.45, 0.45, 0.45]);
      soundboard.debugInjectClip(
        SoundPad.applause,
        Float32List.fromList(List<double>.filled(48000, 0.5)),
      );
      await tester.pump();
      expect(padOpacities(tester), <double>[1.0, 0.45, 0.45, 0.45]);
      soundboard.debugInjectClip(
        SoundPad.drumRoll,
        Float32List.fromList(List<double>.filled(48000, 0.5)),
      );
      await tester.pump();
      expect(padOpacities(tester), <double>[1.0, 0.45, 0.45, 1.0]);
    });

    testWidgets('tapping an available pad plays it + gold underline',
        (WidgetTester tester) async {
      soundboard.debugInjectClip(
        SoundPad.applause,
        Float32List.fromList(List<double>.filled(48000, 0.5)),
      );
      await pumpPads(tester);
      await tester.tap(find.text('APPLAUSE'));
      await tester.pump();
      expect(soundboard.isPlaying, isTrue);
      expect(soundboard.activePad, SoundPad.applause);
      // Active underline: the gold bar under the playing pad.
      expect(goldUnderlineFinder(), findsOneWidget);
      // Active label turns gold.
      final Text label = tester.widget<Text>(find.text('APPLAUSE'));
      expect(label.style?.color, _gold);
      // Tapping a DISABLED pad while applause plays changes nothing.
      await tester.tap(find.text('LAUGH'));
      await tester.pump();
      expect(soundboard.isPlaying, isTrue);
      expect(soundboard.activePad, SoundPad.applause);
      expect(goldUnderlineFinder(), findsOneWidget);
      // Let the 1 s finish timer fire before the test ends (the
      // framework fails a test that leaves a Timer pending).
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('underline clears when the clip finishes (timer)',
        (WidgetTester tester) async {
      // 480-sample clip = 10 ms: tap, underline appears, then pump
      // past the duration and the underline is gone (route-A finish
      // timer — mixInto is never called in this test).
      soundboard.debugInjectClip(
        SoundPad.applause,
        Float32List.fromList(List<double>.filled(480, 0.5)),
      );
      await pumpPads(tester);
      await tester.tap(find.text('APPLAUSE'));
      await tester.pump();
      expect(goldUnderlineFinder(), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 100));
      expect(goldUnderlineFinder(), findsNothing);
      expect(soundboard.isPlaying, isFalse);
    });

    testWidgets('gold is #FDC903 only, no forbidden hex anywhere',
        (WidgetTester tester) async {
      soundboard.debugInjectClip(
        SoundPad.applause,
        Float32List.fromList(List<double>.filled(48000, 0.5)),
      );
      soundboard.debugInjectClip(
        SoundPad.laugh,
        Float32List.fromList(List<double>.filled(48000, 0.5)),
      );
      await pumpPads(tester);
      await tester.tap(find.text('APPLAUSE'));
      await tester.pump();
      // Every Icon in the tree: gold pads use exactly #FDC903, and
      // the forbidden golds (#FFE20A / #FFCC00) appear nowhere.
      final List<Icon> icons =
          tester.widgetList<Icon>(find.byType(Icon)).toList();
      expect(icons.length, 4);
      int goldIcons = 0;
      for (final Icon icon in icons) {
        expect(icon.color, isNot(_forbiddenGoldA));
        expect(icon.color, isNot(_forbiddenGoldB));
        if (icon.color == _gold) goldIcons++;
      }
      // Exactly the 2 available pads have gold icons.
      expect(goldIcons, 2);
      // The underline is exactly #FDC903 (checked via its container).
      expect(goldUnderlineFinder(), findsOneWidget);
      // Let the 1 s finish timer fire before the test ends.
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('REAL applause.wav: pad enables and plays',
        (WidgetTester tester) async {
      final String home = Platform.environment['HOME'] ?? '';
      final File file = File(
        '$home/workspace/arena-hub-audio-dsp-external/assets/sounds/applause.wav',
      );
      expect(
        file.existsSync(),
        isTrue,
        reason: 'real applause.wav missing (pre-approval location)',
      );
      final Float32List decoded =
          WavDecoder.decodeToMono48k(file.readAsBytesSync());
      expect(decoded.length, 120000);
      soundboard.debugInjectClip(SoundPad.applause, decoded);
      await pumpPads(tester);
      expect(padOpacities(tester)[0], 1.0);
      await tester.tap(find.text('APPLAUSE'));
      await tester.pump();
      expect(soundboard.isPlaying, isTrue);
      expect(soundboard.activePad, SoundPad.applause);
      expect(goldUnderlineFinder(), findsOneWidget);
      // Let the 2.5 s finish timer fire before the test ends.
      await tester.pump(const Duration(seconds: 3));
    });
  });
}
