// FIX 23 item 26 REPLACED (Sameer 2026-11-24 00:33, "same lagao" +
// "ab bnao"): the interim splash (blurred poster + logo + smoke /
// sparks, pinned in fix23_brand_test) is SUPERSEDED by the Google AI
// Studio cinematic splash — 5 dart files copied verbatim into
// lib/widgets/, artwork = the existing poster copied to
// assets/images/arena_hub_splash_art.png, wired into SplashGate's
// loading branch. The gate's state-machine DECISIONS are unchanged:
// same states, same screens, same routing — the gate advances only
// when BOTH the boot outcome is known AND the 4.5s cinematic has
// completed (advancing on the cinematic alone would skip the
// maintenance / force-update gates on a slow boot).
//
// The cinematic files are NOT reformatted and NOT recolored (Sameer's
// order): the metallic gold gradient (FDE047 / F59E0B / FBBF24 /
// D97706 / B45309) is part of the approved design and contains NONE
// of the banned hexes.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/widgets/arena_hub_splash_screen.dart';
import 'package:protournament_user/widgets/golden_loading_bar.dart';

import 'audio_test_helpers.dart';

// Banned golds, built ONLY from decimal char codes — the
// literals must never appear in lib/ or test/ in any form
// (not even in a comment listing them).
List<String> _bannedGolds() => [
      String.fromCharCodes([70, 70, 67, 56, 48, 48]),
      String.fromCharCodes([70, 53, 65, 57, 48, 48]),
      String.fromCharCodes([70, 70, 67, 67, 48, 48]),
      String.fromCharCodes([70, 70, 69, 50, 48, 65]),
      String.fromCharCodes([70, 70, 67, 52, 48, 48]),
    ];

const _cinematicFiles = [
  'lib/widgets/arena_hub_splash_screen.dart',
  'lib/widgets/arena_artwork_layers.dart',
  'lib/widgets/smoke_canvas_painter.dart',
  'lib/widgets/logo_reveal_layer.dart',
  'lib/widgets/golden_loading_bar.dart',
];

void main() {
  group('fix23 item 26 (replaced) — cinematic splash assets', () {
    test('art asset is the poster, byte-identical', () {
      final art =
          File('assets/images/arena_hub_splash_art.png').readAsBytesSync();
      final poster = File('assets/arena_hub_splash.png').readAsBytesSync();
      expect(art.length, greaterThan(0));
      expect(listEquals(art, poster), isTrue);
    });

    test('art asset declared in pubspec', () {
      final pubspec = requireProjectFile('pubspec.yaml');
      expect(pubspec, contains('- assets/images/'));
      expect(
          pubspec, contains('- assets/images/arena_hub_splash_art.png'));
      // Version untouched by the splash integration.
      expect(pubspec, contains('version: 1.0.1+2023'));
    });

    test('cinematic defaults: 4.5s minimum + art asset path', () {
      final src = codeOnly(requireProjectFile(
          'lib/widgets/arena_hub_splash_screen.dart'));
      expect(src,
          contains('minimumCinematicDuration = const Duration(milliseconds: 4500)'));
      expect(src,
          contains("splashArtworkAsset = 'assets/images/arena_hub_splash_art.png'"));
      expect(src, contains('required this.onCompleted'));
      // onInitialize is optional (nullable) — the gate passes null.
      expect(src,
          contains('Future<void> Function(ArenaProgressReporter reportProgress)? onInitialize'));
    });

    test('approved metallic golds present; no banned gold anywhere', () {
      for (final path in _cinematicFiles) {
        final src = codeOnly(requireProjectFile(path));
        for (final banned in _bannedGolds()) {
          expect(src.contains(banned), isFalse,
              reason: 'banned gold in $path');
        }
        expect(
            src.contains(String.fromCharCodes(
                [50, 53, 53, 44, 32, 49, 57, 48, 44, 32, 48])),
            isFalse);
      }
      // The approved metallic-gold design is intact (positive check).
      final bar =
          codeOnly(requireProjectFile('lib/widgets/golden_loading_bar.dart'));
      expect(bar, contains('FDE047'));
      expect(bar, contains('F59E0B'));
      expect(bar, contains('FBBF24'));
    });
  });

  group('fix23 item 26 (replaced) — SplashGate wiring', () {
    test('loading branch shows the cinematic; gate needs both halves',
        () {
      final main = codeOnly(requireProjectFile('lib/main.dart'));
      expect(main, contains('cinematic_splash.ArenaHubSplashScreen('));
      expect(main, contains('onCompleted'));
      // Boot records its outcome; the gate advances only when the
      // cinematic has also completed.
      expect(main, contains('String? _bootOutcome;'));
      expect(main, contains('bool _cinematicDone = false;'));
      expect(main, contains('void _finishBoot(String outcome)'));
      expect(main, contains('void _maybeAdvance()'));
      expect(main, contains("_finishBoot('done')"));
      expect(main, contains("_finishBoot('maintenance')"));
      expect(main, contains("_finishBoot('forceUpdate')"));
      expect(main, contains("_finishBoot('nointernet')"));
      // The interim art is gone from the gate (the old file still
      // exists for its own tests, but main no longer shows it).
      expect(main.contains('ArenaHubSplashArtwork()'), isFalse);
      // All six gate states still exist.
      for (final state in [
        'loading',
        'maintenance',
        'forceUpdate',
        'nointernet',
        'settingsError',
        'done',
      ]) {
        expect(main, contains(state), reason: 'missing gate state: $state');
      }
    });

    test('the old splash file is not imported by main (name clash avoided)',
        () {
      final main = requireProjectFile('lib/main.dart');
      expect(main.contains("import 'arena_hub_splash_screen.dart';"), isFalse);
      expect(
          main,
          contains(
              "import 'widgets/arena_hub_splash_screen.dart' as cinematic_splash;"));
    });
  });

  group('fix23 item 26 (replaced) — cinematic widget', () {
    testWidgets('mounts, runs the cinematic and calls onCompleted',
        (tester) async {
      // The splash calls SystemChrome in initState; in widget tests
      // there is no engine to answer that channel, so mock it
      // (reply null, like the engine would).
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (MethodCall call) async => null,
      );
      var completed = false;
      await tester.pumpWidget(
        MaterialApp(
          home: ArenaHubSplashScreen(
            // Short cinematic in test only — production keeps the
            // approved 4.5s minimum (pinned above).
            minimumCinematicDuration: const Duration(milliseconds: 100),
            onCompleted: (_) => completed = true,
          ),
        ),
      );
      // The golden loading dock renders from the first frame.
      expect(find.byType(GoldenLoadingBarDock), findsOneWidget);
      // Bootstrap does REAL engine work (image-codec decode of the
      // poster + a ~870k-pixel layer split + smoke textures) that
      // only progresses on the real event loop — fake-async pumps
      // alone never complete it (verified: 60 pumps without runAsync
      // left onCompleted unfired). Interleave real-async waits
      // (bootstrap) with fake-time pumps (the 100ms cinematic +
      // progress settle). The ambient / shimmer controllers repeat
      // forever — never pumpAndSettle; pump in bounded steps.
      for (var i = 0; i < 40 && !completed; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 500)));
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(completed, isTrue);
    });
  });
}
