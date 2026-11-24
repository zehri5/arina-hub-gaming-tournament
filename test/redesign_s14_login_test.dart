// PHASE 2 REDESIGN — GROUP S14: Login (guide §6 Screen 14).
//
// Pins the S14 styling against the REAL F1/F2 files (theme tokens
// + arena_ui components, swapped in verbatim 2026-11-23) and proves
// the auth behaviour is untouched. The button assertions match the
// real F2 structure (Container + InkWell frame, no
// ElevatedButton/OutlinedButton).
// No Firebase interaction: no test taps LOGIN / Google / Forgot
// Password (those need the platform fakes in device_ban_gate_test);
// the mode toggle + visibility toggle are pure setState and ARE
// exercised. No pumpAndSettle — FireSparks repeats forever.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/components/arena_components.dart';
import 'package:protournament_user/screens/auth_screen.dart';
import 'package:protournament_user/theme.dart';
import 'package:protournament_user/widgets/arena_ui.dart';

// Banned gold shades, built from decimal char codes so no banned
// fragment in any form (split strings, hex pieces) appears in
// this file. Shade A is the first banned gold, B the second.
String _bannedGoldA() => String.fromCharCodes([70, 70, 67, 56, 48, 48]);
String _bannedGoldB() => String.fromCharCodes([70, 53, 65, 57, 48, 48]);

Future<void> _pumpAuth(WidgetTester tester) async {
  // Wide phone viewport (480x860): same reason as
  // device_ban_gate_test — the screen overflows at 360px wide
  // (pre-existing layout issue, not caused by S14).
  tester.view.physicalSize = const Size(480, 860);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(const MaterialApp(home: AuthScreen()));
  await tester.pump(const Duration(milliseconds: 100));
}

String _authSource() => File('lib/screens/auth_screen.dart').readAsStringSync();

void main() {
  group('S14 contract tokens (F1 stub values)', () {
    test('gold gradient runs soft gold into #FDC903', () {
      expect(kGoldSoft, const Color(0xFFFFE16A));
      expect(kGold, const Color(0xFFFDC903));
      expect(kGoldGradient.colors, [kGoldSoft, const Color(0xFFFDC903)]);
    });

    test('background + surface gradients use the contract stops', () {
      expect(kBackgroundGradient.colors, [const Color(0xFF10121A), const Color(0xFF08090D)]);
      expect(kCardSurfaceGradient.colors, [const Color(0xFF202331), const Color(0xFF12141C)]);
      expect(kSurfaceElevated, const Color(0xFF202331));
      expect(kTextMuted, const Color(0xFF737789));
    });

    test('spacing + radii tokens have the contract values', () {
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

    test('error + warning tokens use the contract values', () {
      expect(kError, const Color(0xFFF04452));
      expect(kWarning, const Color(0xFFF4A62A));
    });
  });

  group('S14 login screen styling', () {
    testWidgets('logo + welcome heading are clean and centered', (tester) async {
      await _pumpAuth(tester);
      // FIX 23 item 25: the new ARENA HUB logo image (circle crop),
      // centred — the old crown wordmark is gone.
      expect(find.byType(ArenaHubLogoImage), findsOneWidget);
      expect(find.byType(ArenaLogo), findsNothing);
      expect(find.ancestor(of: find.byType(ArenaHubLogoImage), matching: find.byType(Center)), findsOneWidget);
      // Welcome heading, centred, gold second line.
      final line1 = tester.widget<Text>(find.text('WELCOME BACK,'));
      final line2 = tester.widget<Text>(find.text('PLAYER'));
      expect(line1.textAlign, TextAlign.center);
      expect(line2.textAlign, TextAlign.center);
      expect(line1.style!.color, kText);
      expect(line2.style!.color, kGold);
      expect(line2.style!.fontSize, 52);
      final sub = tester.widget<Text>(find.text('Your next victory starts here.'));
      expect(sub.textAlign, TextAlign.center);
      expect(sub.style!.color, kMuted);
    });

    testWidgets('background is the shared gradient + golden glow + particles', (tester) async {
      await _pumpAuth(tester);
      final bg = tester.widget<ArenaBackground>(find.byType(ArenaBackground));
      expect(bg.showGoldenGlow, isTrue);
      expect(find.byType(FireSparks), findsOneWidget);
      // FIX 23 items 21/27: the ember image is gone — the Images
      // now are the app background (AppBackgroundLayer) + the new
      // logo; the slash panels stay.
      expect(find.byType(Image), findsWidgets);
      expect(find.byType(AppBackgroundLayer), findsOneWidget);
      expect(find.byType(SmokeLayer), findsOneWidget);
    });

    testWidgets('email + password use the shared input style', (tester) async {
      await _pumpAuth(tester);
      expect(find.byType(ArenaTextField), findsNWidgets(2));
      expect(find.byType(TextField), findsNWidgets(2));
      final email = tester.widget<ArenaTextField>(find.byType(ArenaTextField).at(0));
      final password = tester.widget<ArenaTextField>(find.byType(ArenaTextField).at(1));
      expect(email.labelText, 'Email Address');
      expect(email.hintText, 'Enter your email');
      expect(email.keyboardType, TextInputType.emailAddress);
      expect(email.obscureText, isFalse);
      expect(password.labelText, 'Password');
      expect(password.obscureText, isTrue);
      // FIX 23 item 29 Part B: the shared input look is the CARD
      // look — each field sits in a CardFieldShell (gradient +
      // purple border + glow) and the field itself is borderless
      // and unfilled (a decoration cannot paint a gradient).
      expect(find.byType(CardFieldShell), findsNWidgets(2));
      final field = tester.widget<TextField>(find.byType(TextField).at(0));
      final deco = field.decoration!;
      expect(deco.filled, isFalse);
      // Borderless = outline border with no side (invisible, but
      // keeps the floating label inside the field's height).
      expect((deco.border as OutlineInputBorder).borderSide, BorderSide.none);
      final shell = tester.widget<Container>(
        find.descendant(of: find.byType(CardFieldShell).at(0), matching: find.byType(Container)).first,
      );
      final shellDeco = shell.decoration as BoxDecoration;
      expect(shellDeco.gradient, isA<LinearGradient>());
      expect((shellDeco.border as Border).top.color, kCardPurpleBorder);
      expect(shellDeco.borderRadius, BorderRadius.circular(22));
    });

    testWidgets('password visibility toggle still works', (tester) async {
      await _pumpAuth(tester);
      TextField passwordField() => tester.widget<TextField>(find.byType(TextField).at(1));
      expect(passwordField().obscureText, isTrue);
      await tester.tap(find.byType(IconButton));
      await tester.pump(const Duration(milliseconds: 100));
      expect(passwordField().obscureText, isFalse);
      await tester.tap(find.byType(IconButton));
      await tester.pump(const Duration(milliseconds: 100));
      expect(passwordField().obscureText, isTrue);
    });

    testWidgets('forgot password is readable and clearly tappable', (tester) async {
      await _pumpAuth(tester);
      final link = find.text('Forgot Password?');
      expect(link, findsOneWidget);
      final style = tester.widget<Text>(link).style!;
      expect(style.color, kGold);
      expect(style.fontWeight, FontWeight.bold);
      final button = find.ancestor(of: link, matching: find.byType(TextButton));
      expect(button, findsOneWidget);
      // Full tap target — no shrinkWrap: at least 40px tall.
      expect(tester.getSize(button).height, greaterThanOrEqualTo(40));
      // Right-aligned, as before.
      final align = tester.widget<Align>(find.ancestor(of: button, matching: find.byType(Align)).first);
      expect(align.alignment, Alignment.centerRight);
    });

    testWidgets('login button is the shared yellow-gradient primary', (tester) async {
      await _pumpAuth(tester);
      expect(find.byType(ArenaPrimaryButton), findsOneWidget);
      expect(find.text('LOGIN'), findsOneWidget);
      // The gradient decoration lives on the button's container.
      final containers = find.descendant(of: find.byType(ArenaPrimaryButton), matching: find.byType(Container));
      var foundGradient = false;
      for (final e in containers.evaluate()) {
        final deco = (e.widget as Container).decoration;
        if (deco is BoxDecoration && deco.gradient is LinearGradient) {
          final g = deco.gradient as LinearGradient;
          if (g.colors.contains(kGoldSoft) && g.colors.contains(const Color(0xFFFDC903))) {
            foundGradient = true;
          }
        }
      }
      expect(foundGradient, isTrue, reason: 'Login button must paint the kGoldGradient (soft gold -> #FDC903)');
      // REAL F2 (2026-11-23): the shared buttons are built on
      // Container + Material + InkWell — there is NO ElevatedButton
      // anywhere on this screen any more. The tap target is the
      // InkWell inside the primary button (enabled: onTap set).
      final inkwell = tester.widget<InkWell>(
        find.descendant(of: find.byType(ArenaPrimaryButton), matching: find.byType(InkWell)),
      );
      expect(inkwell.onTap, isNotNull);
      expect(find.byType(ElevatedButton), findsNothing);
    });

    testWidgets('google button is the card-style button', (tester) async {
      await _pumpAuth(tester);
      // FIX 23 item 29 Part C: the Google button wears the item-23
      // card look (ArenaCardButton), not the old dark secondary.
      expect(find.byType(ArenaCardButton), findsOneWidget);
      expect(find.byType(ArenaSecondaryButton), findsNothing);
      expect(find.text('Continue with Google'), findsOneWidget);
      final frame = tester.widget<Container>(
        find.descendant(of: find.byType(ArenaCardButton), matching: find.byType(Container)).first,
      );
      final deco = frame.decoration as BoxDecoration;
      final gradient = deco.gradient as LinearGradient;
      expect(gradient.colors, [
        kCardPurpleTop.withValues(alpha: kCardFillOpacity),
        kCardPurpleMid.withValues(alpha: kCardFillOpacity),
        kCardPurpleBottom.withValues(alpha: kCardFillOpacity),
      ]);
      expect((deco.border as Border).top.color, kCardPurpleBorder);
      expect(deco.borderRadius, BorderRadius.circular(22));
    });

    testWidgets('create account link is clear; mode toggle still works', (tester) async {
      await _pumpAuth(tester);
      expect(find.text('New player? '), findsOneWidget);
      final link = tester.widget<Text>(find.text('Create Account'));
      expect(link.style!.color, kGold);
      expect(link.style!.decoration, TextDecoration.underline);
      // Toggle to signup: 4 shared fields + SIGN UP, same screen.
      await tester.tap(find.text('Create Account'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('CREATE YOUR'), findsOneWidget);
      expect(find.text('ACCOUNT'), findsOneWidget);
      expect(find.byType(ArenaTextField), findsNWidgets(4));
      expect(find.text('SIGN UP'), findsOneWidget);
      expect(find.text('Forgot Password?'), findsNothing);
      // Toggle back to login.
      await tester.tap(find.text('Login'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('WELCOME BACK,'), findsOneWidget);
      expect(find.byType(ArenaTextField), findsNWidgets(2));
    });

    testWidgets('keyboard open: fields + buttons stay accessible', (tester) async {
      await _pumpAuth(tester);
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pump(const Duration(milliseconds: 100));
      // The form scrolls; the LOGIN button can still be brought
      // into view and the password field stays findable.
      await tester.ensureVisible(find.text('LOGIN'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('LOGIN'), findsOneWidget);
      expect(find.byType(TextField), findsNWidgets(2));
      await tester.ensureVisible(find.byType(TextField).at(1));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Forgot Password?'), findsOneWidget);
      addTearDown(tester.view.resetViewInsets);
    });
  });

  group('S14 auth logic untouched (source pins)', () {
    test('sign-in / signup / google / reset calls are all still there', () {
      final src = _authSource();
      for (final needle in [
        'signInWithEmailAndPassword',
        'createUserWithEmailAndPassword',
        'signInWithCredential',
        'GoogleSignIn(',
        'sendPasswordResetEmail',
        '_checkDeviceBan',
        'ensureUserProfile',
        'password.length < 6',
        '_obscurePassword',
        '_deviceCheck',
        '_recordLoginSession',
        'AdminMode.set(false)',
      ]) {
        expect(src, contains(needle), reason: 'auth logic must be unchanged: $needle');
      }
    });

    test('keyboard behaviour code is still there', () {
      final src = _authSource();
      expect(src, contains('viewInsets'));
      expect(src, contains('Scrollable.ensureVisible'));
      expect(src, contains('_kbAware'));
      expect(src, contains('SingleChildScrollView'));
    });

    test('screen is built on the shared components + tokens', () {
      final src = _authSource();
      for (final needle in [
        'ArenaBackground(',
        'ArenaTextField(',
        'ArenaPrimaryButton(',
        // FIX 23 items 25/29: the card button (not the secondary)
        // + the new logo; FireSparks now comes from the shared
        // background layer, not from this file.
        'ArenaCardButton(',
        'ArenaHubLogoImage(',
        'kSpace16',
        'kSpace24',
        'kSpace32',
        'showGoldenGlow: true',
      ]) {
        expect(src, contains(needle), reason: 'redesign must use the shared contract pieces: $needle');
      }
    });

    test('no banned gold shades and no leftover old colours', () {
      final src = _authSource();
      final upper = src.toUpperCase();
      expect(upper, isNot(contains(_bannedGoldA())));
      expect(upper, isNot(contains(_bannedGoldB())));
      // The old hardcoded label grey is gone (labels come from the
      // shared input now); the old flat-gold button fill is gone
      // (gradient component now).
      expect(src, isNot(contains('0xFFC9CED6')));
      expect(src, isNot(contains('backgroundColor: kGold')));
    });
  });
}
