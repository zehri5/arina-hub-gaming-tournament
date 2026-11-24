// ARENA HUB Phase 2 — group F2 shared-component tests.
// Pins the CONTRACT.md styling for every component in
// lib/widgets/arena_ui.dart: button fills/borders, chip
// selected/unselected, red LIVE badge, text-field focus/error
// borders, background glow on/off, pressable feedback, gold
// loading indicator. Presentational only: no Supabase, no
// Firebase, no network.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/theme.dart';
import 'package:protournament_user/widgets/arena_ui.dart';

Widget wrap(Widget child) => MaterialApp(
      theme: ThemeData.dark().copyWith(scaffoldBackgroundColor: kBg),
      home: Scaffold(body: child),
    );

/// The outermost Container (frame) of a component under [scope].
BoxDecoration frameDecoration(WidgetTester tester, Finder scope) {
  final container = tester.widget<Container>(
    find.descendant(of: scope, matching: find.byType(Container)).first,
  );
  return container.decoration! as BoxDecoration;
}

/// Ambient text colour a plain Text child inherits (buttons set it
/// via DefaultTextStyle).
Color? ambientTextColor(WidgetTester tester, String text) =>
    DefaultTextStyle.of(tester.element(find.text(text))).style.color;

OutlineInputBorder borderOf(InputDecoration d, String which) {
  switch (which) {
    case 'enabled':
      return d.enabledBorder! as OutlineInputBorder;
    case 'focused':
      return d.focusedBorder! as OutlineInputBorder;
    case 'error':
      return d.errorBorder! as OutlineInputBorder;
    case 'focusedError':
      return d.focusedErrorBorder! as OutlineInputBorder;
    default:
      return d.border! as OutlineInputBorder;
  }
}

void main() {
  group('contract tokens (theme.dart stubs)', () {
    test('gold gradient is soft-gold -> #FDC903', () {
      expect(kGoldGradient.colors,
          [const Color(0xFFFFE16A), const Color(0xFFFDC903)]);
      expect(kGold, const Color(0xFFFDC903));
    });

    test('spacing + radii constants', () {
      expect(kSpace4, 4);
      expect(kSpace8, 8);
      expect(kSpace12, 12);
      expect(kSpace16, 16);
      expect(kSpace20, 20);
      expect(kSpace24, 24);
      expect(kSpace32, 32);
      expect(kRadiusChip, 12);
      expect(kRadiusInput, 14);
      expect(kRadiusCard, 18);
      expect(kRadiusHero, 22);
    });

    test('text styles follow the §4 hierarchy', () {
      expect(kStyleTitle.fontSize, 22);
      expect(kStyleTitle.fontWeight, FontWeight.bold);
      expect(kStyleSection.fontSize, 18);
      expect(kStyleSection.fontWeight, FontWeight.bold);
      expect(kStyleCardTitle.fontSize, 17);
      expect(kStyleCardTitle.fontWeight, FontWeight.w600);
      expect(kStyleBody.fontSize, 15);
      expect(kStyleMeta.fontSize, 13);
      expect(kStyleMeta.color, kMuted);
      expect(kStyleLabel.fontSize, 12);
      expect(kStyleLabel.fontWeight, FontWeight.w500);
      expect(kStyleLabel.color, kTextMuted);
    });
  });

  group('ArenaPrimaryButton', () {
    testWidgets('enabled: gold gradient, warm shadow, dark text, tap fires',
        (tester) async {
      var tapped = false;
      await tester.pumpWidget(wrap(ArenaPrimaryButton(
        onPressed: () => tapped = true,
        child: const Text('Go'),
      )));
      final dec = frameDecoration(tester, find.byType(ArenaPrimaryButton));
      expect(dec.gradient, kGoldGradient);
      expect(dec.color, isNull);
      expect(dec.borderRadius, BorderRadius.circular(kRadiusInput));
      expect(dec.boxShadow, hasLength(1));
      expect(dec.boxShadow!.first.color, kGold.withValues(alpha: 0.35));
      expect(dec.boxShadow!.first.blurRadius, 12);
      expect(ambientTextColor(tester, 'Go'), const Color(0xFF14161F));

      await tester.tap(find.text('Go'));
      expect(tapped, isTrue);
    });

    testWidgets('disabled: muted surface + muted text, no shadow, no tap',
        (tester) async {
      var tapped = false;
      await tester.pumpWidget(wrap(ArenaPrimaryButton(
        onPressed: null,
        child: const Text('Off'),
      )));
      final dec = frameDecoration(tester, find.byType(ArenaPrimaryButton));
      expect(dec.gradient, isNull);
      expect(dec.color, kSurfaceElevated);
      expect(dec.boxShadow, isNull);
      expect(ambientTextColor(tester, 'Off'), kTextMuted);

      await tester.tap(find.text('Off'));
      expect(tapped, isFalse);
    });
  });

  group('ArenaSecondaryButton', () {
    testWidgets('dark surface, thin grey border, white text, tap fires',
        (tester) async {
      var tapped = false;
      await tester.pumpWidget(wrap(ArenaSecondaryButton(
        onPressed: () => tapped = true,
        child: const Text('Later'),
      )));
      final dec = frameDecoration(tester, find.byType(ArenaSecondaryButton));
      expect(dec.gradient, isNull);
      expect(dec.color, kSurface);
      expect(dec.border, isA<Border>());
      final border = dec.border! as Border;
      expect(border.top.color, kBorder);
      expect(border.top.width, 1);
      expect(dec.borderRadius, BorderRadius.circular(kRadiusInput));
      expect(ambientTextColor(tester, 'Later'), kText);

      await tester.tap(find.text('Later'));
      expect(tapped, isTrue);
    });

    testWidgets('disabled: muted surface + muted text, no border',
        (tester) async {
      await tester.pumpWidget(wrap(const ArenaSecondaryButton(
        onPressed: null,
        child: Text('Off'),
      )));
      final dec = frameDecoration(tester, find.byType(ArenaSecondaryButton));
      expect(dec.color, kSurfaceElevated);
      expect(dec.border, isNull);
      expect(ambientTextColor(tester, 'Off'), kTextMuted);
    });
  });

  group('ArenaOutlinedButton', () {
    testWidgets('transparent fill, yellow border, yellow text, tap fires',
        (tester) async {
      var tapped = false;
      await tester.pumpWidget(wrap(ArenaOutlinedButton(
        onPressed: () => tapped = true,
        child: const Text('More'),
      )));
      final dec = frameDecoration(tester, find.byType(ArenaOutlinedButton));
      expect(dec.color, Colors.transparent);
      expect(dec.gradient, isNull);
      final border = dec.border! as Border;
      expect(border.top.color, kGold);
      expect(border.top.width, 1.5);
      expect(dec.borderRadius, BorderRadius.circular(kRadiusInput));
      expect(ambientTextColor(tester, 'More'), kGold);

      await tester.tap(find.text('More'));
      expect(tapped, isTrue);
    });

    testWidgets('disabled: muted border + muted text', (tester) async {
      await tester.pumpWidget(wrap(const ArenaOutlinedButton(
        onPressed: null,
        child: Text('Off'),
      )));
      final dec = frameDecoration(tester, find.byType(ArenaOutlinedButton));
      final border = dec.border! as Border;
      expect(border.top.color, kTextMuted);
      expect(ambientTextColor(tester, 'Off'), kTextMuted);
    });
  });

  group('ArenaFilterChip', () {
    testWidgets('selected: yellow fill + dark text, no border, tap fires',
        (tester) async {
      var tapped = false;
      await tester.pumpWidget(wrap(ArenaFilterChip(
        label: 'All',
        selected: true,
        onTap: () => tapped = true,
      )));
      final dec = frameDecoration(tester, find.byType(ArenaFilterChip));
      expect(dec.color, kGold);
      expect(dec.border, isNull);
      expect(dec.borderRadius, BorderRadius.circular(kRadiusChip));
      final text = tester.widget<Text>(find.text('All'));
      expect(text.style!.color, const Color(0xFF14161F));
      expect(text.style!.fontWeight, FontWeight.w600);

      await tester.tap(find.text('All'));
      expect(tapped, isTrue);
    });

    testWidgets('unselected: dark surface + grey border', (tester) async {
      await tester.pumpWidget(wrap(ArenaFilterChip(
        label: 'Live',
        selected: false,
        onTap: () {},
      )));
      final dec = frameDecoration(tester, find.byType(ArenaFilterChip));
      expect(dec.color, kSurface);
      final border = dec.border! as Border;
      expect(border.top.color, kBorder);
      final text = tester.widget<Text>(find.text('Live'));
      expect(text.style!.color, kText);
    });
  });

  testWidgets('ArenaLiveBadge is a red badge with white LIVE text',
      (tester) async {
    await tester.pumpWidget(wrap(const ArenaLiveBadge()));
    final dec = frameDecoration(tester, find.byType(ArenaLiveBadge));
    expect(dec.color, kLiveRed);
    expect(dec.color, const Color(0xFFFF2D2D));
    final text = tester.widget<Text>(find.text('LIVE'));
    expect(text.style!.color, Colors.white);
    expect(text.style!.fontWeight, FontWeight.bold);
  });

  group('ArenaTextField', () {
    testWidgets('card-shell field: borderless input, purple shell, red error style (FIX 23 item 29B)',
        (tester) async {
      await tester.pumpWidget(wrap(const ArenaTextField(
        labelText: 'Name',
        hintText: 'Your name',
      )));
      expect(find.text('Name'), findsOneWidget);
      expect(find.text('Your name'), findsOneWidget);
      // FIX 23 item 29B SUPERSEDES the dark fill + token borders:
      // the card look comes from CardFieldShell (gradient +
      // purple border + glow); the field itself is borderless
      // and unfilled. Focus turns the shell's border gold, an
      // error turns it red — see the shell's own tests.
      expect(
          find.ancestor(
              of: find.byType(TextField),
              matching: find.byType(CardFieldShell)),
          findsOneWidget);
      final field = tester.widget<TextField>(find.byType(TextField));
      final d = field.decoration!;
      expect(d.filled, isFalse);
      expect(d.fillColor, isNull);
      for (final which in ['enabled', 'focused', 'error', 'focusedError']) {
        expect(borderOf(d, which).borderSide.style, BorderStyle.none);
      }
      expect(d.errorStyle?.color, kError);
      expect(field.style!.color, kText);
    });

    testWidgets('typing updates the controller and fires onChanged',
        (tester) async {
      final controller = TextEditingController();
      var changed = '';
      await tester.pumpWidget(wrap(ArenaTextField(
        controller: controller,
        onChanged: (v) => changed = v,
      )));
      await tester.enterText(find.byType(TextFormField), 'hello');
      expect(controller.text, 'hello');
      expect(changed, 'hello');
    });

    testWidgets('errorText renders and validator shows its message',
        (tester) async {
      await tester.pumpWidget(wrap(const ArenaTextField(
        errorText: 'Bad input',
      )));
      expect(find.text('Bad input'), findsOneWidget);

      final formKey = GlobalKey<FormState>();
      await tester.pumpWidget(wrap(Form(
        key: formKey,
        child: ArenaTextField(
          validator: (v) => (v == null || v.isEmpty) ? 'Required' : null,
        ),
      )));
      expect(formKey.currentState!.validate(), isFalse);
      await tester.pump();
      expect(find.text('Required'), findsOneWidget);
    });

    testWidgets('obscureText + maxLines does not crash (guard to 1)',
        (tester) async {
      await tester.pumpWidget(wrap(const ArenaTextField(
        obscureText: true,
        maxLines: 3,
      )));
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.obscureText, isTrue);
      expect(field.maxLines, 1);
    });
  });

  group('ArenaBackground', () {
    testWidgets('glow on: app image layer + radial golden light behind the child (FIX 23 items 21+24)',
        (tester) async {
      await tester.pumpWidget(wrap(const ArenaBackground(
        showGoldenGlow: true,
        child: Text('Hello'),
      )));
      expect(find.text('Hello'), findsOneWidget);
      // FIX 23 items 21+24 SUPERSEDE the flat dark gradient: the
      // background is the app image layer now; the radial golden
      // glow on top of it is unchanged.
      expect(find.byType(AppBackgroundLayer), findsOneWidget);
      final containers = tester.widgetList<Container>(find.descendant(
          of: find.byType(ArenaBackground), matching: find.byType(Container)));
      final gradients = containers
          .map((c) => (c.decoration as BoxDecoration?)?.gradient)
          .whereType<Gradient>()
          .toList();
      expect(gradients.whereType<LinearGradient>(), hasLength(0));
      final radial = gradients.whereType<RadialGradient>().single;
      expect(radial.center, Alignment.topCenter);
      expect(radial.colors.first, kGold.withValues(alpha: 0.12));
      expect(radial.colors.last, kGold.withValues(alpha: 0));
    });

    testWidgets('glow off: app image layer only, no radial layer (FIX 23 item 21)',
        (tester) async {
      await tester.pumpWidget(wrap(const ArenaBackground(
        child: Text('Hello'),
      )));
      // FIX 23 item 21 SUPERSEDES the base gradient: the
      // background is the app image layer; with the glow off
      // there is no gradient layer at all.
      expect(find.byType(AppBackgroundLayer), findsOneWidget);
      final containers = tester.widgetList<Container>(find.descendant(
          of: find.byType(ArenaBackground), matching: find.byType(Container)));
      final gradients = containers
          .map((c) => (c.decoration as BoxDecoration?)?.gradient)
          .whereType<Gradient>()
          .toList();
      expect(gradients, hasLength(0));
    });
  });

  group('ArenaPressable', () {
    testWidgets('press down scales + fades, release restores, tap fires',
        (tester) async {
      var tapped = false;
      await tester.pumpWidget(wrap(ArenaPressable(
        onTap: () => tapped = true,
        child: const Text('Press me'),
      )));
      expect(
          tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale, 1.0);
      expect(
          tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
          1.0);

      final gesture =
          await tester.startGesture(tester.getCenter(find.text('Press me')));
      await tester.pump();
      expect(
          tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale, 0.97);
      expect(
          tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
          0.85);

      await gesture.up();
      await tester.pump();
      expect(
          tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale, 1.0);
      expect(
          tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
          1.0);
      expect(tapped, isTrue);
    });

    testWidgets('reduced motion: no scale/opacity change on press',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: ArenaPressable(
              onTap: () {},
              child: const Text('Press me'),
            ),
          ),
        ),
      ));
      final gesture =
          await tester.startGesture(tester.getCenter(find.text('Press me')));
      await tester.pump();
      expect(
          tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale, 1.0);
      expect(
          tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
          1.0);
      await gesture.up();
    });
  });

  testWidgets('ArenaLoadingIndicator is a gold spinner', (tester) async {
    await tester.pumpWidget(wrap(const ArenaLoadingIndicator()));
    final spinner = tester.widget<CircularProgressIndicator>(
        find.byType(CircularProgressIndicator));
    expect(spinner.color, kGold);
  });
}
