// FIX 23 item 29 — auth background + smoke (Part A), card-style
// text fields (Part B), all cardviews identical (Part C).
//
// Part A: login + signup render the app-wide background image +
// smoke + sparks (already wired via ArenaBackground in items 21/24
// — this file VERIFIES it, it does not rebuild it).
// Part B: every place text is typed wears the item-23 card look
// (CardFieldShell: gradient + purple border + glow; focus -> gold
// border, error -> red border). Chat composer: style only.
// Part C: the auth Google button is the card button; LOGIN stays
// the gold primary; every dialog + bottom sheet + admin card wears
// the card look. No pumpAndSettle — FireSparks/SmokeLayer repeat
// forever.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/components/arena_chat.dart';
import 'package:protournament_user/components/arena_components.dart';
import 'package:protournament_user/screens/auth_screen.dart';
import 'package:protournament_user/theme.dart';
import 'package:protournament_user/widgets/arena_ui.dart';

Future<void> _pumpAuth(WidgetTester tester) async {
  // Wide phone viewport (480x860): same reason as S14 — the
  // screen overflows at 360px wide (pre-existing layout issue).
  tester.view.physicalSize = const Size(480, 860);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(const MaterialApp(home: AuthScreen()));
  await tester.pump(const Duration(milliseconds: 100));
}

/// The Container decoration of a CardFieldShell (its own Container
/// is the first Container descendant — Focus is not a Container).
BoxDecoration _shellDecoration(WidgetTester tester, Finder shell) {
  final container = tester.widget<Container>(
    find.descendant(of: shell, matching: find.byType(Container)).first,
  );
  return container.decoration as BoxDecoration;
}

/// True when some rendered Image uses the given asset.
bool _imageWithAsset(WidgetTester tester, String asset) {
  for (final e in find.byType(Image).evaluate()) {
    final img = (e.widget as Image).image;
    if (img is AssetImage && img.assetName == asset) return true;
  }
  return false;
}

/// The item-23 card gradient colours at the current fill opacity.
List<Color> _cardGradientColors() => [
      kCardPurpleTop.withValues(alpha: kCardFillOpacity),
      kCardPurpleMid.withValues(alpha: kCardFillOpacity),
      kCardPurpleBottom.withValues(alpha: kCardFillOpacity),
    ];

void _expectCardLook(BoxDecoration deco, double radius) {
  final gradient = deco.gradient as LinearGradient;
  expect(gradient.colors, _cardGradientColors());
  expect(gradient.begin, Alignment.topLeft);
  expect(gradient.end, Alignment.bottomRight);
  expect(deco.borderRadius, BorderRadius.circular(radius));
  expect((deco.border as Border).top.width, 1.5);
  expect(deco.boxShadow, hasLength(1));
  expect(deco.boxShadow!.first.blurRadius, 15);
  expect(deco.boxShadow!.first.spreadRadius, 1);
}

/// Index of the paren matching the '(' at [openIdx].
int _parenEnd(String src, int openIdx) {
  var depth = 0;
  var j = openIdx;
  while (j < src.length) {
    final c = src[j];
    if (c == '(') depth++;
    if (c == ')') {
      depth--;
      if (depth == 0) return j;
    }
    j++;
  }
  return src.length - 1;
}

void main() {
  group('item 29 Part A — auth background + smoke', () {
    testWidgets('login renders the app background image + smoke + sparks',
        (tester) async {
      await _pumpAuth(tester);
      expect(find.byType(AppBackgroundLayer), findsOneWidget);
      expect(find.byType(SmokeLayer), findsOneWidget);
      expect(find.byType(FireSparks), findsOneWidget);
      expect(_imageWithAsset(tester, 'assets/images/app_background.png'),
          isTrue,
          reason: 'login must show the item-21 background image');
      expect(_imageWithAsset(tester, 'assets/images/ember_bg.png'), isFalse,
          reason: 'the old ember background is gone (item 27)');
      expect(find.byType(ArenaHubLogoImage), findsOneWidget);
      expect(find.byType(ArenaLogo), findsNothing,
          reason: 'the old crown wordmark is gone (item 25)');
    });

    testWidgets('signup renders the same background + smoke + logo',
        (tester) async {
      await _pumpAuth(tester);
      await tester.tap(find.text('Create Account'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('SIGN UP'), findsOneWidget);
      expect(find.byType(AppBackgroundLayer), findsOneWidget);
      expect(find.byType(SmokeLayer), findsOneWidget);
      expect(_imageWithAsset(tester, 'assets/images/app_background.png'),
          isTrue);
      expect(find.byType(ArenaHubLogoImage), findsOneWidget);
    });
  });

  group('item 29 Part B — text fields wear the card look', () {
    testWidgets('ArenaTextField renders in a card shell, field borderless',
        (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ArenaTextField(labelText: 'Email', controller: controller),
        ),
      ));
      await tester.pump();
      final shell = find.byType(CardFieldShell);
      expect(shell, findsOneWidget);
      expect(find.byType(TextFormField), findsOneWidget);
      // TextFormField builds one inner TextField — that is where
      // the decoration lives (TextFormField has no .decoration).
      // Borderless = an OUTLINE border with no side: invisible,
      // but the outline layout keeps the floating label inside
      // the field's height (InputBorder.none would add +16px).
      final field = tester.widget<TextField>(find.byType(TextField));
      final border = field.decoration!.border as OutlineInputBorder;
      expect(border.borderSide, BorderSide.none);
      expect(field.decoration!.filled, isFalse);
      final deco = _shellDecoration(tester, shell);
      _expectCardLook(deco, 22);
      expect((deco.border as Border).top.color, kCardPurpleBorder);
    });

    testWidgets('focus turns the field border gold, blur restores purple',
        (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ArenaTextField(labelText: 'Email', controller: controller),
        ),
      ));
      await tester.pump();
      final shell = find.byType(CardFieldShell);
      expect((_shellDecoration(tester, shell).border as Border).top.color,
          kCardPurpleBorder);
      await tester.tap(find.byType(TextFormField));
      await tester.pump();
      expect((_shellDecoration(tester, shell).border as Border).top.color,
          kGold,
          reason: 'focused field border is gold');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      expect((_shellDecoration(tester, shell).border as Border).top.color,
          kCardPurpleBorder);
    });

    testWidgets('error turns the field border red and shows the message',
        (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ArenaTextField(
            labelText: 'Email',
            controller: controller,
            errorText: 'Required',
          ),
        ),
      ));
      await tester.pump();
      final shell = find.byType(CardFieldShell);
      expect((_shellDecoration(tester, shell).border as Border).top.color,
          kError);
      expect(find.text('Required'), findsOneWidget);
    });

    testWidgets('ArenaFormField renders in a card shell, field borderless',
        (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ArenaFormField(controller: controller, label: 'Name'),
        ),
      ));
      await tester.pump();
      expect(find.byType(CardFieldShell), findsOneWidget);
      final field = tester.widget<TextField>(find.byType(TextField));
      final border = field.decoration!.border as OutlineInputBorder;
      expect(border.borderSide, BorderSide.none);
      _expectCardLook(
          _shellDecoration(tester, find.byType(CardFieldShell)), 22);
    });

    testWidgets('chat composer wears the card shell (style only)',
        (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ArenaChatInputBar(controller: controller, onSend: () {}),
        ),
      ));
      await tester.pump();
      final shell = find.byType(CardFieldShell);
      expect(shell, findsOneWidget);
      expect(tester.widget<CardFieldShell>(shell).radius, 24);
      _expectCardLook(_shellDecoration(tester, shell), 24);
      // Layout + behaviour untouched: hint, send button present.
      expect(find.text('Type a message...'), findsOneWidget);
      expect(find.byIcon(Icons.send), findsOneWidget);
    });

    test('theme backstop gives bare fields the card look', () {
      final main = File('lib/main.dart').readAsStringSync();
      final start = main.indexOf('inputDecorationTheme: InputDecorationTheme(');
      expect(start, isNot(-1));
      // The theme block runs to the pageTransitionsTheme that
      // follows it; pin the card values inside that span (not just
      // anywhere in main.dart).
      final end = main.indexOf('pageTransitionsTheme', start);
      expect(end, greaterThan(start));
      final block = main.substring(start, end);
      expect(block, contains('fillColor: kCardPurpleMid'));
      expect(block, contains('BorderRadius.circular(22)'));
      // The purple borderSide is split across lines; pin its parts.
      expect(block, contains('color: kCardPurpleBorder, width: 1.5'));
      expect(block, contains('BorderSide(color: kGold, width: 1.5)'));
      expect(block, contains('BorderSide(color: kError, width: 1.5)'));
    });

    // FIX 32 (2026-11-24): the admin-form half of this test is gone
    // with the panel; the CardFieldShell half (user-app theme) stays.
    test('CardFieldShell carries the card look', () {
      final theme = File('lib/theme.dart').readAsStringSync();
      expect(theme, contains('class CardFieldShell'));
      expect(theme, contains('goldBorder'));
      expect(theme, contains('widget.error'));
    });
  });

  group('item 29 Part C — all cardviews identical', () {
    testWidgets('ArenaCardButton renders the card decoration',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ArenaCardButton(
              onPressed: () {}, child: const Text('Continue')),
        ),
      ));
      await tester.pump();
      final frame = tester.widget<Container>(
        find.descendant(
            of: find.byType(ArenaCardButton), matching: find.byType(Container)).first,
      );
      final deco = frame.decoration as BoxDecoration;
      _expectCardLook(deco, 22);
      expect((deco.border as Border).top.color, kCardPurpleBorder);
    });

    testWidgets('ArenaCardButton disabled = muted surface, no border',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: ArenaCardButton(onPressed: null, child: Text('Continue')),
        ),
      ));
      await tester.pump();
      final frame = tester.widget<Container>(
        find.descendant(
            of: find.byType(ArenaCardButton), matching: find.byType(Container)).first,
      );
      final deco = frame.decoration as BoxDecoration;
      expect(deco.color, kSurfaceElevated);
      expect(deco.gradient, isNull);
    });

    testWidgets('auth Google button is the card button; LOGIN stays gold',
        (tester) async {
      await _pumpAuth(tester);
      expect(find.byType(ArenaCardButton), findsOneWidget);
      expect(find.text('Continue with Google'), findsOneWidget);
      expect(find.byType(ArenaSecondaryButton), findsNothing);
      expect(find.byType(ArenaPrimaryButton), findsOneWidget);
      expect(find.text('LOGIN'), findsOneWidget);
    });

    test('auth source uses the card button, not the secondary button', () {
      final auth = File('lib/screens/auth_screen.dart').readAsStringSync();
      expect(auth, contains('ArenaCardButton('));
      expect(auth, isNot(contains('ArenaSecondaryButton')));
    });

    test('every AlertDialog wears the card look', () {
      var checked = 0;
      for (final file in Directory('lib').listSync(recursive: true)) {
        if (file is! File || !file.path.endsWith('.dart')) continue;
        final src = file.readAsStringSync();
        var from = 0;
        while (true) {
          final idx = src.indexOf('AlertDialog(', from);
          if (idx == -1) break;
          final open = src.indexOf('(', idx);
          final close = _parenEnd(src, open);
          final block = src.substring(idx, close + 1);
          expect(block, contains('backgroundColor: kCardPurpleMid,'),
              reason: '${file.path} dialog must use the card fill');
          expect(
              block,
              contains(
                  'side: const BorderSide(color: kCardPurpleBorder, width: 1.5)'),
              reason: '${file.path} dialog must have the purple border');
          checked++;
          from = close + 1;
        }
      }
      // FIX 32 (2026-11-24): threshold was >100 — the deleted admin
      // screens carried ~50 of the dialogs. 51 remain, all checked
      // above; the guard still catches a scan covering too few.
      expect(checked, greaterThan(40),
          reason: 'the scan must cover all dialogs ($checked found)');
    });

    test('every bottom sheet wears the card look', () {
      var checked = 0;
      for (final file in Directory('lib').listSync(recursive: true)) {
        if (file is! File || !file.path.endsWith('.dart')) continue;
        final src = file.readAsStringSync();
        var from = 0;
        while (true) {
          final idx = src.indexOf('showModalBottomSheet', from);
          if (idx == -1) break;
          final open = src.indexOf('(', idx);
          final close = _parenEnd(src, open);
          final call = src.substring(idx, close + 1);
          final builderIdx = call.indexOf('builder:');
          final head = builderIdx == -1 ? call : call.substring(0, builderIdx);
          if (head.contains('backgroundColor:') &&
              !head.contains('Colors.transparent')) {
            expect(head, contains('backgroundColor: kCardPurpleMid,'),
                reason: '${file.path} sheet must use the card fill');
            checked++;
          }
          if (head.contains('shape:')) {
            expect(head, contains('kCardPurpleBorder'),
                reason: '${file.path} sheet shape must have the purple border');
          }
          from = close + 1;
        }
      }
      // FIX 32 (2026-11-24): threshold was >25 — the deleted admin
      // screens carried some of the sheets. 23 remain, all checked
      // above; the guard still catches a scan covering too few.
      expect(checked, greaterThan(15),
          reason: 'the scan must cover the solid sheets ($checked found)');
    });

  });
}
