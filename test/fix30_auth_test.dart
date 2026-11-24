// FIX 30 verifier test — written by the VERIFIER (2026-11-24), NOT the
// builder. Independently checks the AI Studio login/signup apply:
// mounts, background asset, OUR centred logo, 'Player' header, ZERO
// ArenaHubLogo references, banned-gold absence, callback wiring
// (login / Google / signup incl. referral / forgot incl. inline error),
// and login <-> signup navigation.
//
// The screens use GoogleFonts; runtime fetching is disabled here so the
// tests never touch the network (font fallback is fine for assertions).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:protournament_user/components/arena_components.dart';
import 'package:protournament_user/screens/login_screen.dart';
import 'package:protournament_user/screens/signup_screen.dart';
import 'package:protournament_user/theme/arena_theme.dart';
import 'package:protournament_user/widgets/arena_gaming_widgets.dart';

void main() {
  setUpAll(() {
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  // The files item 30 added or changed (plus the untouched auth screen,
  // which must NOT contain the AI Studio logo either).
  const checkedFiles = [
    'lib/theme/arena_theme.dart',
    'lib/widgets/arena_gaming_widgets.dart',
    'lib/screens/forgot_password_sheet.dart',
    'lib/screens/login_screen.dart',
    'lib/screens/signup_screen.dart',
    'lib/services/auth_service.dart',
    'lib/screens/auth_screen.dart',
    'lib/main.dart',
  ];

  Widget wrap(Widget child) => MaterialApp(home: child);

  Future<void> pumpLogin(WidgetTester tester,
      {Future<void> Function(String e, String p)? onLogin,
      Future<void> Function()? onGoogle,
      Future<void> Function(String n, String e, String p, String r)? onSignup,
      Future<void> Function(String e)? onForgot}) async {
    await tester.pumpWidget(wrap(LoginScreen(
      onLoginSubmit: onLogin,
      onGoogleLogin: onGoogle,
      onSignupSubmit: onSignup,
      onForgotPassword: onForgot,
    )));
    await tester.pumpAndSettle();
  }

  group('fix30 login screen', () {
    testWidgets('mounts with Welcome Back / Player header', (tester) async {
      await pumpLogin(tester);
      expect(find.text('Welcome Back,'), findsOneWidget);
      expect(find.text('Player'), findsOneWidget);
      expect(find.text('Your next victory starts here.'), findsOneWidget);
    });

    testWidgets('OUR logo centred, size 120, gold ring', (tester) async {
      await pumpLogin(tester);
      final logoFinder = find.byType(ArenaHubLogoImage);
      expect(logoFinder, findsOneWidget);
      final logo = tester.widget<ArenaHubLogoImage>(logoFinder);
      expect(logo.size, 120);
      expect(logo.ringWidth, 3);
      // CENTRED: the logo's ancestor chain must include a Center.
      expect(
        find.ancestor(of: logoFinder, matching: find.byType(Center)),
        findsWidgets,
      );
    });

    testWidgets('uses the auth background asset', (tester) async {
      expect(ArenaTheme.backgroundAsset,
          'assets/images/arena_auth_background.png');
      expect(File('assets/images/arena_auth_background.png').existsSync(),
          isTrue);
      await pumpLogin(tester);
      final imageFinder = find.byWidgetPredicate((w) =>
          w is Image &&
          w.image is AssetImage &&
          (w.image as AssetImage).assetName ==
              'assets/images/arena_auth_background.png');
      expect(imageFinder, findsOneWidget);
    });

    testWidgets('login submit fires onLoginSubmit with the typed values',
        (tester) async {
      String? gotEmail;
      String? gotPass;
      await pumpLogin(tester, onLogin: (e, p) async {
        gotEmail = e;
        gotPass = p;
      });
      await tester.enterText(find.byType(TextField).at(0), 'a@b.com');
      await tester.enterText(find.byType(TextField).at(1), 'secret1');
      await tester.ensureVisible(find.text('LOGIN'));
      await tester.tap(find.text('LOGIN'));
      await tester.pumpAndSettle();
      expect(gotEmail, 'a@b.com');
      expect(gotPass, 'secret1');
    });

    testWidgets('Google button fires onGoogleLogin', (tester) async {
      var fired = false;
      await pumpLogin(tester, onGoogle: () async => fired = true);
      await tester.ensureVisible(find.byType(ArenaGoogleButton));
      await tester.tap(find.byType(ArenaGoogleButton));
      await tester.pumpAndSettle();
      expect(fired, isTrue);
    });

    testWidgets('Create Account navigates to Signup; back link returns',
        (tester) async {
      await pumpLogin(tester);
      // The bottom link is a RichText ('New player? Create Account')
      // inside a GestureDetector — assert its text, tap via its icon.
      final createLink = find.byWidgetPredicate((w) =>
          w is RichText &&
          w.text.toPlainText().contains('New player? Create Account'));
      expect(createLink, findsOneWidget);
      await tester.ensureVisible(find.byIcon(Icons.person_add_alt_1_outlined));
      await tester.tap(find.byIcon(Icons.person_add_alt_1_outlined));
      await tester.pumpAndSettle();
      expect(find.byType(SignupScreen), findsOneWidget);
      expect(find.text('Create Your'), findsOneWidget);
      // The bottom back link is a RichText ('Already have an account?
      // Login') inside a GestureDetector — find it by its icon and by
      // its RichText content (find.text does not match RichText spans).
      final backLinkText = find.byWidgetPredicate((w) =>
          w is RichText &&
          w.text.toPlainText().contains('Already have an account?'));
      expect(backLinkText, findsOneWidget);
      await tester.ensureVisible(find.byIcon(Icons.login_rounded));
      await tester.tap(find.byIcon(Icons.login_rounded));
      await tester.pumpAndSettle();
      expect(find.byType(LoginScreen), findsOneWidget);
      expect(find.text('Player'), findsOneWidget);
    });
  });

  group('fix30 signup screen', () {
    Future<void> pumpSignup(WidgetTester tester,
        {Future<void> Function(String n, String e, String p, String r)?
            onSignup}) async {
      await tester.pumpWidget(wrap(SignupScreen(
        onSignupSubmit: onSignup,
        onGoogleSignup: () async {},
      )));
      await tester.pumpAndSettle();
    }

    testWidgets('mounts with OUR logo centred, size 96, gold ring',
        (tester) async {
      await pumpSignup(tester);
      expect(find.text('Create Your'), findsOneWidget);
      final logoFinder = find.byType(ArenaHubLogoImage);
      expect(logoFinder, findsOneWidget);
      final logo = tester.widget<ArenaHubLogoImage>(logoFinder);
      expect(logo.size, 96);
      expect(logo.ringWidth, 3);
      expect(
        find.ancestor(of: logoFinder, matching: find.byType(Center)),
        findsWidgets,
      );
    });

    testWidgets('uses the auth background asset', (tester) async {
      await pumpSignup(tester);
      final imageFinder = find.byWidgetPredicate((w) =>
          w is Image &&
          w.image is AssetImage &&
          (w.image as AssetImage).assetName ==
              'assets/images/arena_auth_background.png');
      expect(imageFinder, findsOneWidget);
    });

    testWidgets('has the referral field and passes it to the callback',
        (tester) async {
      String? gotName;
      String? gotEmail;
      String? gotPass;
      String? gotReferral;
      await pumpSignup(tester, onSignup: (n, e, p, r) async {
        gotName = n;
        gotEmail = e;
        gotPass = p;
        gotReferral = r;
      });
      // 5 text fields in order: name, email, password, confirm, referral.
      expect(find.byType(TextField), findsNWidgets(5));
      await tester.enterText(find.byType(TextField).at(0), 'Test User');
      await tester.enterText(find.byType(TextField).at(1), 'a@b.com');
      await tester.enterText(find.byType(TextField).at(2), 'secret1');
      await tester.enterText(find.byType(TextField).at(3), 'secret1');
      await tester.enterText(find.byType(TextField).at(4), 'REF123');
      await tester.ensureVisible(find.text('CREATE ACCOUNT'));
      await tester.tap(find.text('CREATE ACCOUNT'));
      await tester.pumpAndSettle();
      expect(gotName, 'Test User');
      expect(gotEmail, 'a@b.com');
      expect(gotPass, 'secret1');
      expect(gotReferral, 'REF123');
    });
  });

  group('fix30 forgot-password sheet', () {
    testWidgets('submit fires onForgotPassword and shows the sent panel',
        (tester) async {
      String? gotEmail;
      await pumpLogin(tester, onForgot: (e) async => gotEmail = e);
      await tester.ensureVisible(find.text('Forgot Password?'));
      await tester.tap(find.text('Forgot Password?'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsWidgets);
      await tester.enterText(find.byType(TextField).last, 'a@b.com');
      await tester.tap(find.text('SEND RESET LINK'));
      await tester.pumpAndSettle();
      expect(gotEmail, 'a@b.com');
      expect(find.textContaining('Reset link sent to a@b.com.'),
          findsOneWidget);
      expect(find.text('RETURN TO LOGIN'), findsOneWidget);
    });

    testWidgets('a failed reset shows the error inline (no fake sent state)',
        (tester) async {
      await pumpLogin(tester,
          onForgot: (_) async => throw Exception('no network'));
      await tester.ensureVisible(find.text('Forgot Password?'));
      await tester.tap(find.text('Forgot Password?'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'a@b.com');
      await tester.tap(find.text('SEND RESET LINK'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Could not send reset email'),
          findsOneWidget);
      expect(find.text('RETURN TO LOGIN'), findsNothing);
    });
  });

  group('fix30 source checks', () {
    test('ZERO ArenaHubLogo references (word boundary) in checked files',
        () {
      final pattern = RegExp(r'\bArenaHubLogo\b');
      for (final path in checkedFiles) {
        final src = File(path).readAsStringSync();
        expect(pattern.hasMatch(src), isFalse, reason: path);
      }
    });

    test('no banned gold literals in the new/changed files', () {
      const banned = ['FFC800', 'F5A900', 'FFCC00', 'FFE20A', 'FFC400'];
      for (final path in checkedFiles) {
        final src = File(path).readAsStringSync().toUpperCase();
        for (final hex in banned) {
          expect(src.contains(hex), isFalse, reason: '$path contains $hex');
        }
      }
    });

    test('Google G painter still exists in the widgets file', () {
      final src =
          File('lib/widgets/arena_gaming_widgets.dart').readAsStringSync();
      expect(src.contains('class _GoogleLogoPainter'), isTrue);
    });

    test('auth background asset is declared in pubspec', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      expect(pubspec.contains('assets/images/arena_auth_background.png'),
          isTrue);
      expect(pubspec.contains('google_fonts:'), isTrue);
    });

    test('forgot sheet file is imported by the login screen (wired)', () {
      final src = File('lib/screens/login_screen.dart').readAsStringSync();
      expect(src.contains('forgot_password_sheet.dart'), isTrue);
      expect(src.contains('showArenaForgotPasswordSheet'), isTrue);
    });
  });
}
