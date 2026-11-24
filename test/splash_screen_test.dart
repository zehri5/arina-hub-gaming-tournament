import 'dart:io';

import 'package:protournament_user/arena_hub_splash_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

// Banned gold shade A, built from decimal char codes so no banned
// fragment in any form (split strings, hex pieces) appears in
// this file.
String _bannedGoldA() => String.fromCharCodes([70, 70, 67, 56, 48, 48]);

void main() {
  group('ArenaHubSplashArtwork', () {
    testWidgets('renders the supplied splash artwork image', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: ArenaHubSplashArtwork()),
        ),
      );
      // The repeating glow animation never settles — pump once, never
      // pumpAndSettle.
      await tester.pump(const Duration(milliseconds: 100));
      final imageFinder = find.byWidgetPredicate(
        (w) =>
            w is Image &&
            w.image is AssetImage &&
            (w.image as AssetImage).assetName ==
                'assets/arena_hub_splash.png',
      );
      expect(imageFinder, findsOneWidget);
    });

    testWidgets('artwork fills the screen (cover fit)', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: ArenaHubSplashArtwork()),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      final image = tester.widget<Image>(
        find.byWidgetPredicate(
          (w) =>
              w is Image &&
              w.image is AssetImage &&
              (w.image as AssetImage).assetName ==
                  'assets/arena_hub_splash.png',
        ),
      );
      expect(image.fit, BoxFit.cover);
    });
  });

  group('ArenaHubSplashScreen (full widget)', () {
    // The splash awaits a platform-channel call (SystemChrome) before
    // navigating; in widget tests there is no engine to answer that
    // channel, so the await would hang forever without a mock
    // handler. Mock it (reply null, like the engine would).
    void mockPlatformChannel(WidgetTester tester) {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (MethodCall call) async => null,
      );
    }

    // Pump until HOME appears (bounded), instead of assuming an exact
    // pump count — the SystemChrome round-trip needs extra cycles
    // under fake async.
    Future<void> pumpUntilHome(WidgetTester tester) async {
      for (var i = 0;
          i < 40 && find.text('HOME').evaluate().isEmpty;
          i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    testWidgets('navigates to home after the minimum duration',
        (tester) async {
      mockPlatformChannel(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: ArenaHubSplashScreen(
            minimumDuration: const Duration(milliseconds: 100),
            homeBuilder: (context) => const Text('HOME'),
          ),
        ),
      );
      expect(find.text('HOME'), findsNothing);
      await pumpUntilHome(tester);
      expect(find.text('HOME'), findsOneWidget);
    });

    testWidgets('waits for initializeApp before navigating', (tester) async {
      var initialized = false;
      mockPlatformChannel(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: ArenaHubSplashScreen(
            minimumDuration: const Duration(milliseconds: 50),
            initializeApp: () async {
              await Future<void>.delayed(const Duration(milliseconds: 300));
              initialized = true;
            },
            homeBuilder: (context) => const Text('HOME'),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('HOME'), findsNothing);
      await pumpUntilHome(tester);
      expect(initialized, isTrue);
      expect(find.text('HOME'), findsOneWidget);
    });
  });

  group('Splash gold + gate wiring (source pins)', () {
    test('widget uses #FDC903 gold only — no banned gold anywhere', () {
      final src =
          File('lib/arena_hub_splash_screen.dart').readAsStringSync();
      expect(src.contains(_bannedGoldA()), isFalse);
      // The banned RGB triple, built from char codes (never as a
      // literal — the verifier fails on any literal form).
      expect(
          src.contains(
              String.fromCharCodes([50, 53, 53, 44, 32, 49, 57, 48, 44, 32, 48])),
          isFalse);
      expect(src.contains('FDC903'), isTrue);
      expect(src.contains('253, 201, 3'), isTrue);
    });

    test('SplashGate still owns routing; loading shows the AI Studio cinematic splash', () {
      final src = File('lib/main.dart').readAsStringSync();
      // State machine intact.
      for (final gate in [
        "'maintenance'",
        "'forceUpdate'",
        "'nointernet'",
        "'settingsError'",
        "'done'",
        '_boot()',
        'class SplashGate',
      ]) {
        expect(src.contains(gate), isTrue, reason: 'missing $gate');
      }
      // Loading branch shows the AI Studio cinematic splash (FIX 23
      // item 26 REPLACED 2026-11-24 — the interim blurred-poster art
      // is superseded; the old crest / spinner / LOADING visual is
      // gone from the loading branch). The gate advances only when
      // BOTH the boot outcome is known AND the cinematic completed.
      expect(src.contains('cinematic_splash.ArenaHubSplashScreen('), isTrue);
      expect(src.contains('onCompleted'), isTrue);
      expect(src.contains('_finishBoot('), isTrue);
      expect(src.contains('_maybeAdvance()'), isTrue);
      expect(src.contains('ArenaHubSplashArtwork()'), isFalse);
      expect(src.contains("home: const SplashGate()"), isTrue);
    });

    test('splash PNG is registered in pubspec assets', () {
      final src = File('pubspec.yaml').readAsStringSync();
      expect(src.contains('- assets/arena_hub_splash.png'), isTrue);
      expect(File('assets/arena_hub_splash.png').existsSync(), isTrue);
    });
  });
}
