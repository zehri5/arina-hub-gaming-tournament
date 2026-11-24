// FIX 23 items 25–27 — NEW LOGO + SPLASH REBUILD + AUTH ANIMATION.
// Source pins + widget tests. The logo is Sameer's file
// (1000050465_11_61ab.png, bundled as assets/images/arena_hub_logo.png);
// it has white/light corners, so it is always shown as a circle
// crop (ClipOval) with a gold ring — never raw on dark. The splash
// keeps its state machine byte-identical (visuals only); auth loses
// its static ember image and gains smoke + sparks instead.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/arena_hub_splash_screen.dart';
import 'package:protournament_user/components/arena_components.dart';
import 'package:protournament_user/theme.dart';
import 'package:protournament_user/widgets/arena_ui.dart';

import 'audio_test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('fix23 item 25 — new logo (source + widget)', () {
    test('logo asset is bundled + declared in pubspec', () {
      final file =
          File('${findProjectRoot().path}/assets/images/arena_hub_logo.png');
      expect(file.existsSync(), isTrue);
      expect(file.lengthSync(), greaterThan(0));
      final pubspec = requireProjectFile('pubspec.yaml');
      expect(pubspec, contains('- assets/images/arena_hub_logo.png'));
    });

    test('logo widget: circle crop + gold ring + gold glow', () {
      expect(ArenaHubLogoImage.asset, 'assets/images/arena_hub_logo.png');
      final src = codeOnly(requireProjectFile(
          'lib/components/arena_components.dart'));
      final region = src.substring(src.indexOf('class ArenaHubLogoImage'));
      // White corners are cut by the circle crop, never pasted raw.
      expect(region, contains('ClipOval('));
      expect(region, contains('Image.asset('));
      expect(region, contains('Border.all(color: kGold'));
      expect(region, contains('BoxShape.circle'));
      // Error fallback: dark purple + gold crown, never a white box.
      expect(region, contains('errorBuilder'));
      expect(region, contains('Icons.emoji_events'));
    });

    testWidgets('logo renders as a gold-ringed circle', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(child: ArenaHubLogoImage(size: 120, ringWidth: 3)),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(ClipOval), findsOneWidget);
      final image = tester.widget<Image>(find.byType(Image));
      expect((image.image as AssetImage).assetName,
          ArenaHubLogoImage.asset);
      final container = tester.widget<Container>(
          find.byType(Container).first);
      final deco = container.decoration as BoxDecoration;
      expect(deco.shape, BoxShape.circle);
      expect((deco.border as Border).top.color, kGold);
      expect(tester.takeException(), isNull);
    });

    test('launcher icon untouched (ic_launcher is NOT the new logo)', () {
      final manifest = requireProjectFile(
          'android/app/src/main/AndroidManifest.xml');
      expect(manifest, contains('@mipmap/ic_launcher'));
    });
  });

  // NOTE (2026-11-24 00:33): the interim splash pinned here is
  // SUPERSEDED in the gate by the AI Studio cinematic splash
  // (fix23_splash_cinematic_test.dart) — these pins only guard that
  // the old file still compiles/renders for its own tests.
  group('fix23 item 26 — splash rebuild (source + widget)', () {
    test('splash visuals: logo + smoke + sparks + loading text', () {
      final src = codeOnly(
          requireProjectFile('lib/arena_hub_splash_screen.dart'));
      final art = src.substring(src.indexOf('class ArenaHubSplashArtwork'));
      expect(art, contains('ArenaHubLogoImage('));
      expect(art, contains('size: 200,'));
      expect(art, contains('const SmokeLayer()'));
      expect(art, contains('FireSparks(count: 28)'));
      expect(art, contains("'Loading Arena Hub...'"));
      // The poster stays as the (blurred) backdrop until Sameer
      // sends the new splash background — never self-picked.
      expect(art, contains('assets/arena_hub_splash.png'));
      expect(art, contains('ImageFilter.blur'));
    });

    test('splash logic untouched: state machine + navigation intact', () {
      final src = codeOnly(
          requireProjectFile('lib/arena_hub_splash_screen.dart'));
      expect(src, contains('minimumDuration = const Duration(milliseconds: 3200)'));
      expect(src, contains('Navigator.of(context).pushReplacement'));
      final main = codeOnly(requireProjectFile('lib/main.dart'));
      // SplashGate states all still present.
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

    testWidgets('splash artwork renders logo + smoke + sparks',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: ArenaHubSplashArtwork()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      expect(find.byType(ArenaHubLogoImage), findsOneWidget);
      expect(find.byType(SmokeLayer), findsOneWidget);
      expect(find.byType(FireSparks), findsOneWidget);
      expect(find.text('Loading Arena Hub...'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('fix23 items 25+27 — logo wiring (source)', () {
    test('Home header uses the new logo, not the text wordmark', () {
      final home =
          codeOnly(requireProjectFile('lib/screens/home_screens.dart'));
      expect(home, contains('ArenaHubLogoImage(size: 44)'));
      expect(home, isNot(contains('ArenaLogo(crownSize: 44')));
    });

    test('auth: static ember image GONE, logo + animation in', () {
      final auth =
          codeOnly(requireProjectFile('lib/screens/auth_screen.dart'));
      expect(auth, isNot(contains('ember_bg.png')));
      expect(auth, contains('ArenaHubLogoImage(size: 120'));
      // No LOCAL sparks widget — smoke + sparks come from the
      // app-wide background layer behind the auth screen.
      expect(auth, isNot(contains('FireSparks(')));
      // Auth logic untouched.
      expect(auth, contains('signInWithEmailAndPassword'));
      expect(auth, contains('createUserWithEmailAndPassword'));
    });
  });
}
