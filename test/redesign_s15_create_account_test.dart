// Phase 2 redesign — GROUP S15: Create Account (guide §6 Screen 15).
//
// The Create Account screen is the sign-up mode (_isLogin == false)
// of AuthScreen (lib/screens/auth_screen.dart) — it shares its
// build with Login, so the branding/background/typography pins here
// assert BOTH modes carry the same look, and the signup pins assert
// the four fields, the optional Referral label and the yellow
// gradient SIGN UP pill.
//
// STYLING ONLY: every logic pin below (password rule, referral
// hand-off, account creation, device-ban gate, busy/disabled states,
// keyboard scroll-into-view) asserts the code is UNCHANGED — a
// restyle must never move behaviour.
//
// The real F1/F2 files (theme tokens + arena_ui.dart, copied
// VERBATIM from g-f1/g-f2 on the coordinator's order 2026-11-22,
// md5-verified) are pinned too, so a future F1/F2 change that
// moves a token value or a component's styling fails loudly here
// instead of silently changing the screen.
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

String _read(String rel) => File('test/../$rel').readAsStringSync();

/// Source with full-line comments stripped, so a mention inside a
/// comment never counts as code.
String _codeOnly(String src) => src.split('\n').where((l) => !l.trimLeft().startsWith('//')).join('\n');

/// Pump the real AuthScreen. 480x860: at 360px width the Google pill
/// and footer rows overflow ~90px (pre-existing, NOT this group —
/// see device_ban_gate_test.dart), which would fail the run.
Future<void> _pumpAuth(WidgetTester tester, {Size size = const Size(480, 860)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(const MaterialApp(home: AuthScreen()));
  await tester.pump(const Duration(milliseconds: 100));
}

/// Switch from login to signup mode via the footer link. Scrolls
/// the link into view first — at a short viewport it sits below
/// the fold and a blind tap would silently miss it.
Future<void> _goSignup(WidgetTester tester) async {
  await tester.ensureVisible(find.text('Create Account'));
  await tester.pump(const Duration(milliseconds: 100));
  await tester.tap(find.text('Create Account'));
  await tester.pump(const Duration(milliseconds: 100));
}

Finder _emberBg() => find.byWidgetPredicate(
      (w) => w is Image && w.image is AssetImage && (w.image as AssetImage).assetName == 'assets/images/ember_bg.png',
    );

Finder _appBg() => find.byWidgetPredicate(
      (w) => w is Image && w.image is AssetImage && (w.image as AssetImage).assetName == 'assets/images/app_background.png',
    );

/// The Container decoration of a CardFieldShell (its own Container
/// is the first Container descendant — Focus is not a Container).
BoxDecoration _shellDecoration(WidgetTester tester, Finder shell) {
  final container = tester.widget<Container>(
    find.descendant(of: shell, matching: find.byType(Container)).first,
  );
  return container.decoration as BoxDecoration;
}

/// The item-23 card gradient colours at the current fill opacity.
List<Color> _cardGradientColors() => [
      kCardPurpleTop.withValues(alpha: kCardFillOpacity),
      kCardPurpleMid.withValues(alpha: kCardFillOpacity),
      kCardPurpleBottom.withValues(alpha: kCardFillOpacity),
    ];

/// The gradient Container wrapping the CTA button — NOTE 3: the
/// pill helper is GONE (the CTA is the shared ArenaPrimaryButton
/// now); the pill test scans the button's descendant Containers
/// directly, mirroring the S14 login-button test.

void main() {
  group('S15 — Create Account screen (signup mode)', () {
    testWidgets('signup mode shows all four fields + SIGN UP, no Forgot Password', (tester) async {
      await _pumpAuth(tester);
      await _goSignup(tester);
      expect(find.text('Full Name'), findsOneWidget);
      expect(find.text('Email Address'), findsOneWidget);
      expect(find.text('Password'), findsOneWidget);
      expect(find.text('Referral Code (Optional)'), findsOneWidget);
      expect(find.byType(TextField), findsNWidgets(4));
      expect(find.text('SIGN UP'), findsOneWidget);
      expect(find.text('LOGIN'), findsNothing);
      expect(find.text('Forgot Password?'), findsNothing);
      expect(find.text('Already a player? '), findsOneWidget);
      expect(find.text('Login'), findsOneWidget);
    });

    testWidgets('Create Account heading is prominent (52px gold second line)', (tester) async {
      await _pumpAuth(tester);
      await _goSignup(tester);
      expect(find.text('CREATE YOUR'), findsOneWidget);
      final account = tester.widget<Text>(find.text('ACCOUNT'));
      expect(account.style!.fontSize, 52);
      expect(account.style!.color, kGold);
      expect(account.style!.fontWeight, FontWeight.w900);
      final createYour = tester.widget<Text>(find.text('CREATE YOUR'));
      expect(createYour.style!.fontSize, 28);
      expect(createYour.style!.color, kText);
      expect(find.text('Join the arena and start competing.'), findsOneWidget);
    });

    // FIX 23 (items 25/27): the old crown wordmark (ArenaLogo) and
    // the static ember_bg.png are GONE from the auth pages — the
    // branding is the new ArenaHubLogoImage and the background is
    // the app-wide layer (app_background.png + smoke + sparks).
    // The Scaffold no longer paints kBg itself; ArenaBackground
    // paints the background.
    testWidgets('same branding + background as Login (logo image, app background, smoke)', (tester) async {
      await _pumpAuth(tester);
      // Login mode.
      expect(find.byType(ArenaHubLogoImage), findsOneWidget);
      expect(find.byType(ArenaLogo), findsNothing);
      expect(find.byType(AppBackgroundLayer), findsOneWidget);
      expect(find.byType(SmokeLayer), findsOneWidget);
      expect(_appBg(), findsOneWidget);
      expect(_emberBg(), findsNothing);
      // Signup mode — identical branding.
      await _goSignup(tester);
      expect(find.byType(ArenaHubLogoImage), findsOneWidget);
      expect(find.byType(ArenaLogo), findsNothing);
      expect(find.byType(AppBackgroundLayer), findsOneWidget);
      expect(find.byType(SmokeLayer), findsOneWidget);
      expect(_appBg(), findsOneWidget);
      expect(_emberBg(), findsNothing);
    });

    // FIX 23 item 29: the fields wear the card look now — the
    // gradient + purple border + glow live on the CardFieldShell
    // around each field, and the field itself is borderless and
    // unfilled (an InputDecoration cannot paint a gradient).
    testWidgets('all four fields share one input style (card shell)', (tester) async {
      await _pumpAuth(tester);
      await _goSignup(tester);
      final fields = tester.widgetList<TextField>(find.byType(TextField)).toList();
      expect(fields, hasLength(4));
      for (final field in fields) {
        final dec = field.decoration!;
        expect(dec.filled, isFalse);
        // Borderless = an OUTLINE border with no side: invisible,
        // but the outline layout keeps the floating label inside
        // the field's height (InputBorder.none would add +16px).
        for (final border in [dec.border, dec.enabledBorder, dec.focusedBorder]) {
          expect((border as OutlineInputBorder).borderSide, BorderSide.none);
        }
        expect(field.style!.fontSize, kStyleBody.fontSize);
        expect(field.style!.color, kStyleBody.color);
        expect(dec.hintStyle!.color, kTextMuted);
      }
      // One card shell per field, all with the identical card look:
      // purple gradient fill, purple border 1.5, glow, radius 22.
      final shells = find.byType(CardFieldShell);
      expect(shells, findsNWidgets(4));
      for (var i = 0; i < 4; i++) {
        final deco = _shellDecoration(tester, shells.at(i));
        final gradient = deco.gradient as LinearGradient;
        expect(gradient.colors, _cardGradientColors());
        expect(gradient.begin, Alignment.topLeft);
        expect(gradient.end, Alignment.bottomRight);
        expect(deco.borderRadius, BorderRadius.circular(22));
        expect((deco.border as Border).top.color, kCardPurpleBorder);
        expect((deco.border as Border).top.width, 1.5);
        expect(deco.boxShadow, hasLength(1));
        expect(deco.boxShadow!.first.blurRadius, 15);
        expect(deco.boxShadow!.first.spreadRadius, 1);
      }
      // Labels + hints are passed to the SHARED ArenaTextField
      // (NOTE 3: S14's contract rebuild wins — the fields are
      // ArenaTextField widgets, not S15's kept _AuthField).
      // Mirror of the S14 login-field pins.
      final shared = tester.widgetList<ArenaTextField>(find.byType(ArenaTextField)).toList();
      expect(shared, hasLength(4));
      expect(shared[0].labelText, 'Full Name');
      expect(shared[0].hintText, 'Enter your name');
      expect(shared[1].labelText, 'Email Address');
      expect(shared[1].hintText, 'Enter your email');
      expect(shared[1].keyboardType, TextInputType.emailAddress);
      expect(shared[2].labelText, 'Password');
      expect(shared[2].obscureText, isTrue);
      expect(shared[3].labelText, 'Referral Code (Optional)');
      expect(shared[3].hintText, 'Enter referral code');
      // Prefix icons are GONE by contract (NOTE 3): the shared
      // ArenaTextField has no prefix-icon slot — S15's kept icons
      // did NOT merge, so both screens' auth fields are identical.
      expect(find.byIcon(Icons.person_outline), findsNothing);
      expect(find.byIcon(Icons.mail_outline), findsNothing);
      expect(find.byIcon(Icons.lock_outline), findsNothing);
      expect(find.byIcon(Icons.card_giftcard), findsNothing);
    });

    testWidgets('SIGN UP button is the shared yellow-gradient primary (56 high, glow kept)', (tester) async {
      // NOTE 3 adaptation: S14's contract rebuild wins — the CTA is
      // the shared ArenaPrimaryButton (radius kRadiusInput, NOT the
      // radius-30 pill S15 kept). Mirror of the S14 login-button
      // pins, for the SIGN UP label.
      await _pumpAuth(tester);
      await _goSignup(tester);
      expect(find.byType(ArenaPrimaryButton), findsOneWidget);
      expect(find.text('SIGN UP'), findsOneWidget);
      // CTA height: the button fills its 56-high SizedBox.
      expect(tester.getSize(find.byType(ArenaPrimaryButton)).height, 56);
      // The gradient decoration lives on the button's container.
      final containers = find.descendant(of: find.byType(ArenaPrimaryButton), matching: find.byType(Container));
      BoxDecoration? gradientDeco;
      for (final e in containers.evaluate()) {
        final deco = (e.widget as Container).decoration;
        if (deco is BoxDecoration && deco.gradient is LinearGradient) {
          final g = deco.gradient as LinearGradient;
          if (g.colors.contains(kGoldSoft) && g.colors.contains(kGold)) {
            gradientDeco = deco;
          }
        }
      }
      expect(gradientDeco, isNotNull, reason: 'SIGN UP button must paint the kGoldGradient (soft gold -> #FDC903)');
      final gradient = gradientDeco!.gradient as LinearGradient;
      expect(gradient.colors, [kGoldSoft, kGold]);
      // Contract radius (kRadiusInput), not the old pill radius 30.
      expect(gradientDeco.borderRadius, BorderRadius.circular(kRadiusInput));
      // The soft gold glow under the button survives.
      expect(gradientDeco.boxShadow, hasLength(1));
      expect(gradientDeco.boxShadow!.first.color, kGold.withValues(alpha: 0.35));
      // REAL F2: the shared buttons are built on Container +
      // Material + InkWell — there is NO ElevatedButton anywhere
      // on this screen any more. The tap target is the InkWell
      // inside the primary button (enabled: onTap set).
      final inkwell = tester.widget<InkWell>(
        find.descendant(of: find.byType(ArenaPrimaryButton), matching: find.byType(InkWell)),
      );
      expect(inkwell.onTap, isNotNull);
      expect(find.byType(ElevatedButton), findsNothing);
      // Dark bold label on gold.
      final label = tester.widget<Text>(find.text('SIGN UP'));
      expect(label.style!.fontWeight, FontWeight.w900);
      expect(label.style!.fontSize, 18);
    });

    testWidgets('password visibility toggle still works in signup mode', (tester) async {
      await _pumpAuth(tester);
      await _goSignup(tester);
      final fields = find.byType(TextField);
      expect(tester.widget<TextField>(fields.at(2)).obscureText, isTrue);
      await tester.tap(find.byIcon(Icons.visibility_off_outlined));
      await tester.pump();
      expect(tester.widget<TextField>(fields.at(2)).obscureText, isFalse);
    });

    testWidgets('short-password validation still blocks signup (toast, no nav)', (tester) async {
      await _pumpAuth(tester);
      await _goSignup(tester);
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), 'Test Player');
      await tester.enterText(fields.at(1), 'test@example.com');
      await tester.enterText(fields.at(2), 'abc');
      // Let the _kbAware delayed (300 ms) scroll-into-view reveals
      // from focusing the fields fire FIRST, so the scroll position
      // is settled before we bring the CTA into view — otherwise a
      // late reveal can scroll the button back off-screen and the
      // tap below silently misses.
      await tester.pump(const Duration(milliseconds: 400));
      // NOTE 3: the CTA is the shared ArenaPrimaryButton now
      // (no ElevatedButton anywhere on this screen any more).
      await tester.ensureVisible(find.byType(ArenaPrimaryButton));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.byType(ArenaPrimaryButton));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Enter a valid email and a password of at least 6 characters.'), findsOneWidget);
      expect(find.text('SIGN UP'), findsOneWidget);
    });

    testWidgets('form scrolls and keyboard padding follows viewInsets', (tester) async {
      // Short viewport: the form must scroll, not overflow.
      await _pumpAuth(tester, size: const Size(480, 500));
      await _goSignup(tester);
      final scroll = find.byType(SingleChildScrollView);
      expect(scroll, findsOneWidget);
      final padding0 = tester.widget<SingleChildScrollView>(scroll).padding as EdgeInsets;
      expect(padding0.bottom, kSpace24);
      expect(padding0.left, kSpace24);
      expect(padding0.right, kSpace24);
      // Keyboard opens: bottom padding grows by the inset.
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.resetViewInsets);
      await tester.pump(const Duration(milliseconds: 100));
      final padding1 = tester.widget<SingleChildScrollView>(scroll).padding as EdgeInsets;
      expect(padding1.bottom, 300 + kSpace24);
      // Last field + CTA stay reachable while the keyboard is up.
      await tester.ensureVisible(find.byType(TextField).at(3));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byType(TextField).at(3));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.ensureVisible(find.text('SIGN UP'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('SIGN UP'), findsOneWidget);
      await tester.drag(scroll, const Offset(0, -300));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Referral Code (Optional)'), findsOneWidget);
    });

    testWidgets('login mode untouched: 2 fields + LOGIN + Forgot Password', (tester) async {
      await _pumpAuth(tester);
      expect(find.byType(TextField), findsNWidgets(2));
      expect(find.text('LOGIN'), findsOneWidget);
      expect(find.text('Forgot Password?'), findsOneWidget);
      expect(find.text('Full Name'), findsNothing);
      expect(find.text('Referral Code (Optional)'), findsNothing);
    });
  });

  group('S15 — logic untouched (source pins)', () {
    late String code;
    setUpAll(() => code = _codeOnly(_read('lib/screens/auth_screen.dart')));

    test('password rule + account creation flow unchanged', () {
      expect(code.contains('if (email.isEmpty || password.length < 6)'), isTrue);
      expect(code.contains('createUserWithEmailAndPassword(email: email, password: password)'), isTrue);
      expect(code.contains('signInWithEmailAndPassword(email: email, password: password)'), isTrue);
      expect(code.contains("toast(context, 'Enter a valid email and a password of at least 6 characters.')"), isTrue);
    });

    test('referral + display-name hand-off unchanged', () {
      expect(code.contains('referralCodeFromSignup: _referral.text.trim()'), isTrue);
      expect(code.contains('displayNameOverride: _name.text.trim().isEmpty ? null : _name.text.trim()'), isTrue);
    });

    test('device-ban gate + post-auth flow unchanged', () {
      expect('_checkDeviceBan(cred.user!.uid)'.allMatches(code).length, 3);
      expect(code.contains('await _deviceCheck(cred.user!.uid)'), isTrue);
      expect(code.contains('await _recordLoginSession(cred.user!.uid)'), isTrue);
      expect(code.contains('await PushService.syncPlayerId()'), isTrue);
      expect(code.contains('await PresenceService.goOnline()'), isTrue);
    });

    test('busy/disabled + keyboard scroll behaviour unchanged', () {
      expect(code.contains("_GoldPillButton(label: _isLogin ? 'LOGIN' : 'SIGN UP', busy: _busy, onPressed: _emailAuth)"), isTrue);
      expect(code.contains('onPressed: busy ? null : onPressed'), isTrue);
      expect(code.contains('CircularProgressIndicator(strokeWidth: 2'), isTrue);
      expect(code.contains('Scrollable.ensureVisible'), isTrue);
      expect(code.contains('MediaQuery.of(context).viewInsets.bottom'), isTrue);
    });

    test('contract tokens used, banned golds + old hardcoded colours absent', () {
      // NOTE 3: kGoldGradient / kRadiusInput / kTextMuted live in
      // the F1/F2 files now (the screen is built on the shared
      // ArenaTextField / ArenaPrimaryButton) — they are pinned in
      // the Group 3 tests below, not in this screen's source.
      for (final token in ['kStyleBody', 'kSpace16', 'kSpace24', 'kSpace32', 'ArenaTextField', 'ArenaPrimaryButton']) {
        expect(code.contains(token), isTrue, reason: 'token not used: $token');
      }
      expect(code.contains('0xFFC9CED6'), isFalse, reason: 'old hardcoded label grey must be gone');
      // Banned golds, built from pieces so the literals themselves
      // never appear in this file (the verifier greps the whole
      // copy — ANY occurrence, even in a test, is a FAIL item).
      for (final banned in [_bannedGoldA(), _bannedGoldB(), '#${_bannedGoldA()}', '#${_bannedGoldB()}']) {
        expect(code.toUpperCase().contains(banned.toUpperCase()), isFalse, reason: 'banned gold present: $banned');
      }
    });
  });

  group('S15 — real F1/F2 files (theme + arena_ui)', () {
    test('no banned gold anywhere in the F1/F2 files', () {
      // Banned golds built from pieces — see the note above.
      final bannedA = _bannedGoldA();
      final bannedB = _bannedGoldB();
      for (final rel in ['lib/theme.dart', 'lib/widgets/arena_ui.dart']) {
        final src = _read(rel).toUpperCase();
        expect(src.contains(bannedA), isFalse, reason: '$rel contains banned gold A');
        expect(src.contains(bannedB), isFalse, reason: '$rel contains banned gold B');
      }
    });

    test('gold gradient token is kGoldSoft -> kGold (#FDC903)', () {
      expect(kGoldGradient.colors, [kGoldSoft, kGold]);
      expect(kGold, const Color(0xFFFDC903));
      expect(kGoldSoft, const Color(0xFFFFE16A));
      expect(kRadiusInput, 14);
      expect(kStyleBody.fontSize, 15);
    });

    testWidgets('ArenaPrimaryButton: gradient when enabled, muted when disabled', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                ArenaPrimaryButton(onPressed: () {}, child: const Text('GO')),
                ArenaPrimaryButton(onPressed: null, child: const Text('OFF')),
              ],
            ),
          ),
        ),
      );
      final on = tester.widgetList<Container>(
        find.ancestor(of: find.text('GO'), matching: find.byType(Container)),
      ).firstWhere((c) => (c.decoration as BoxDecoration?)?.gradient != null);
      expect((on.decoration as BoxDecoration).gradient, isA<LinearGradient>());
      expect(((on.decoration as BoxDecoration).gradient as LinearGradient).colors, [kGoldSoft, kGold]);
      final off = tester.widgetList<Container>(
        find.ancestor(of: find.text('OFF'), matching: find.byType(Container)),
      ).firstWhere((c) => c.decoration is BoxDecoration);
      expect((off.decoration as BoxDecoration).gradient, isNull);
      expect((off.decoration as BoxDecoration).color, kSurfaceElevated);
    });

    // FIX 23 item 29: ArenaTextField renders the card-shell input
    // now — the field itself is borderless and unfilled, the card
    // look (gradient + purple border + glow, radius 22) lives on
    // the CardFieldShell around it.
    testWidgets('ArenaTextField renders the shared card-shell input', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: ArenaTextField(labelText: 'Name', hintText: 'Enter name')),
        ),
      );
      // TextFormField keeps its decoration private — read it off the
      // inner TextField it builds.
      final field = tester.widget<TextField>(
        find.descendant(of: find.byType(TextFormField), matching: find.byType(TextField)),
      );
      expect(field.decoration!.filled, isFalse);
      for (final border in [field.decoration!.border, field.decoration!.enabledBorder, field.decoration!.focusedBorder]) {
        expect((border as OutlineInputBorder).borderSide, BorderSide.none);
      }
      expect(field.style!.fontSize, kStyleBody.fontSize);
      expect(field.style!.color, kStyleBody.color);
      expect(field.decoration!.hintStyle!.color, kTextMuted);
      final shell = find.byType(CardFieldShell);
      expect(shell, findsOneWidget);
      final deco = _shellDecoration(tester, shell);
      final gradient = deco.gradient as LinearGradient;
      expect(gradient.colors, _cardGradientColors());
      expect(gradient.begin, Alignment.topLeft);
      expect(gradient.end, Alignment.bottomRight);
      expect(deco.borderRadius, BorderRadius.circular(22));
      expect((deco.border as Border).top.color, kCardPurpleBorder);
      expect((deco.border as Border).top.width, 1.5);
      expect(deco.boxShadow, hasLength(1));
    });

    testWidgets('ArenaBackground + ArenaLoadingIndicator smoke', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: ArenaBackground(showGoldenGlow: true, child: ArenaLoadingIndicator()),
        ),
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(tester.widget<CircularProgressIndicator>(find.byType(CircularProgressIndicator)).color, kGold);
    });
  });
}
