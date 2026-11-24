// FIX 23 item 24 — BLUE + PURPLE SMOKE (Lottie).
// Source pins + widget tests. The smoke is a tinted free Lottie
// ("Fog / Smoke" by Ladon Sklyarov, LottieFiles, Lottie Simple
// License — commercial use allowed, attribution not required),
// rendered by ONE widget (SmokeLayer) inside AppBackgroundLayer,
// above the background image + scrim and below all content, at
// 20% opacity, 30 fps, paused when the app is backgrounded.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lottie/lottie.dart';
import 'package:protournament_user/services/supabase_db.dart';
import 'package:protournament_user/theme.dart';
import 'package:protournament_user/widgets/arena_ui.dart';

import 'audio_test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('fix23 item 24 — smoke asset + license trail (source)', () {
    test('tinted smoke JSON is bundled + declared in pubspec', () {
      final file =
          File('${findProjectRoot().path}/assets/lottie/smoke_blue_purple.json');
      expect(file.existsSync(), isTrue);
      expect(file.lengthSync(), greaterThan(0));
      final pubspec = requireProjectFile('pubspec.yaml');
      expect(pubspec, contains('- assets/lottie/smoke_blue_purple.json'));
    });

    test('smoke JSON: 3 color layers tinted blue + purple + violet', () {
      final json = jsonDecode(requireProjectFile(
          'assets/lottie/smoke_blue_purple.json')) as Map<String, dynamic>;
      final layers = json['layers'] as List;
      expect(layers, hasLength(6));
      // layer name -> fill [r, g, b, a]
      final fills = <String, List>{};
      for (final layer in layers.cast<Map<String, dynamic>>()) {
        final name = layer['nm'] as String;
        if (!name.startsWith('Color')) continue;
        for (final shape in (layer['shapes'] as List)
            .cast<Map<String, dynamic>>()) {
          for (final item
              in (shape['it'] as List).cast<Map<String, dynamic>>()) {
            if (item['ty'] == 'fl') {
              fills[name] = (item['c']['k'] as List).cast<num>().toList();
            }
          }
        }
      }
      // #3B82F6 blue, #922BFF purple (= kCardPurpleBorder),
      // #7C3AED violet. No gold in the smoke (purple+gold idea
      // was superseded by blue+purple, user order 2026-11-23).
      expect(fills['Color 1'], [0.231, 0.51, 0.965, 1]);
      expect(fills['Color 2'], [0.573, 0.169, 1.0, 1]);
      expect(fills['Color 3'], [0.486, 0.227, 0.929, 1]);
    });

    test('lottie package resolves without touching pinned packages', () {
      final pubspec = requireProjectFile('pubspec.yaml');
      expect(pubspec, contains('lottie: ^3.8.2'));
      final lock = requireProjectFile('pubspec.lock');
      final lottieBlock = lock.substring(
          lock.indexOf('  lottie:'), lock.indexOf('  matcher:'));
      expect(lottieBlock, contains('version: "3.8.2"'));
      // Pins unchanged.
      expect(pubspec, contains('shared_preferences: 2.3.0'));
      expect(pubspec, contains('file_picker: 8.3.7'));
    });
  });

  group('fix23 item 24 — SmokeLayer (unit + source)', () {
    test('constants: enabled, 20% opacity (in the 15–25% band)', () {
      expect(SmokeLayer.enabled, isTrue);
      expect(SmokeLayer.smokeOpacity, 0.20);
      expect(SmokeLayer.smokeOpacity, greaterThanOrEqualTo(0.15));
      expect(SmokeLayer.smokeOpacity, lessThanOrEqualTo(0.25));
      expect(SmokeLayer.asset, 'assets/lottie/smoke_blue_purple.json');
    });

    test('source: 30fps cap + lifecycle pause + drift', () {
      final src = codeOnly(requireProjectFile('lib/widgets/arena_ui.dart'));
      final layer = src.substring(src.indexOf('class SmokeLayer'));
      expect(layer, contains('frameRate: FrameRate(30)'));
      expect(layer, contains('didChangeAppLifecycleState'));
      expect(layer, contains('_lottieController.stop()'));
      expect(layer, contains('_driftController.stop()'));
      expect(layer, contains('_lottieController.repeat()'));
      expect(layer, contains('_driftController.repeat(reverse: true)'));
      // Slow upward drift (24px over the drift cycle).
      expect(layer, contains('-24.0 * _driftController.value'));
      // One-line kill switch: disabled -> empty widget.
      expect(layer, contains('if (!SmokeLayer.enabled)'));
    });

    test('source: smoke + sparks live in the background layer', () {
      final src = codeOnly(requireProjectFile('lib/widgets/arena_ui.dart'));
      final bg = src.substring(
          src.indexOf('class AppBackgroundLayer'),
          src.indexOf('class SmokeLayer'));
      expect(bg, contains('const SmokeLayer()'));
      expect(bg, contains('FireSparks(count: AppBackgroundLayer.sparkCount)'));
      expect(bg, contains('static const bool sparksEnabled = true;'));
      expect(bg, contains('static const int sparkCount = 12;'));
    });
  });

  group('fix23 item 24 — smoke widget tests', () {
    setUp(() {
      SupaDb.appBackgroundUrl.value = '';
      themeLightNotifier.value = false;
    });

    tearDown(() {
      SupaDb.appBackgroundUrl.value = '';
      themeLightNotifier.value = false;
    });

    testWidgets('smoke renders + stays below content in the Stack',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                AppBackgroundLayer(),
                Center(child: Text('CONTENT')),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      expect(find.byType(SmokeLayer), findsOneWidget);
      expect(find.byType(LottieBuilder), findsOneWidget);
      // Opacity 0.20 wraps the lottie.
      final opacity = tester.widget<Opacity>(find.ancestor(
          of: find.byType(LottieBuilder), matching: find.byType(Opacity)));
      expect(opacity.opacity, 0.20);
      // Layer order: background layer is the FIRST Stack child,
      // content comes after it.
      final stack = tester.widget<Stack>(find.byType(Stack).first);
      expect(stack.children.first, isA<AppBackgroundLayer>());
      expect(stack.children.last, isA<Center>());
      expect(find.text('CONTENT'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('tinted JSON parses in the Flutter lottie renderer',
        (tester) async {
      // Pumping the layer + advancing time validates the JSON
      // (incl. its track mattes) loads and animates without error.
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Stack(children: [SmokeLayer()]),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      await tester.pump(const Duration(seconds: 2));
      expect(find.byType(LottieBuilder), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('lifecycle pause/resume does not crash', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Stack(children: [SmokeLayer()]),
          ),
        ),
      );
      await tester.pump();
      tester.binding
          .handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      tester.binding
          .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });
}
