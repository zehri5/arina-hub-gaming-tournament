// FIX 4 LOG OUT CONFIRM + STUCK SCREEN (user order 2026-11-22,
// voice call + screenshot
// ~/workspace/user/files/1000049941_66_ubs2.jpg — Settings screen,
// red LOG OUT button): tapping LOG OUT left the screen STUCK —
// logout happened but nothing navigated, so Settings stayed on
// top until the user pressed back. Now LOG OUT asks first (same
// confirmation style as the exit dialog) and, on YES, signs out
// and shows the login screen AT ONCE.
//
// Root cause: the old _logOut() signed out but never navigated —
// the root StreamBuilder swaps home to AuthScreen on sign-out,
// but the pushed Settings route stayed on top of the Navigator
// stack. Fix: popUntil(isFirst) after the guarded sign-out.
// Do NOT push a new AuthScreen: AuthScreen never pops itself, so
// a pushed copy would trap the user on login after re-sign-in.
//
// Source pins (what the code says) for the _logOut flow — the
// Settings page cannot be widget-booted here (build/initState
// touch SharedPreferences + services) — plus REAL widget tests
// for showLogoutConfirmDialog itself (pure UI, no Firebase).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/utils.dart';

String _read(String rel) => File('test/../$rel').readAsStringSync();

/// Source with full-line comments stripped, so a mention inside a
/// comment never counts as code.
String _codeOnly(String src) => src
    .split('\n')
    .where((l) => !l.trimLeft().startsWith('//'))
    .join('\n');

/// The slice of [src] between two markers (exclusive of the end
/// marker), for scoped assertions.
String _region(String src, String start, String end) {
  final s = src.indexOf(start);
  expect(s, isNot(-1), reason: 'region start not found: $start');
  final e = src.indexOf(end, s + start.length);
  expect(e, isNot(-1), reason: 'region end not found: $end');
  return src.substring(s, e);
}

void main() {
  late String more;
  late String code;
  late String utils;

  setUpAll(() {
    more = _read('lib/screens/more_screens.dart');
    code = _codeOnly(more);
    utils = _codeOnly(_read('lib/utils.dart'));
  });

  group('FIX 4 — LOG OUT asks first, then logs out + shows login', () {
    test('LOG OUT button still calls _logOut', () {
      expect(code.contains('onPressed: _logOut'), isTrue);
      expect(code.contains("label: const Text('LOG OUT'"), isTrue);
    });

    test('_logOut shows the confirmation dialog FIRST', () {
      final logout = _region(
        code,
        'Future<void> _logOut() async {',
        'Future<void> _signOutGuarded() async {',
      );
      expect(logout.contains('showLogoutConfirmDialog(context)'), isTrue);
      // The dialog comes before any sign-out work.
      expect(
        logout.indexOf('showLogoutConfirmDialog(context)') <
            logout.indexOf('_signOutGuarded()'),
        isTrue,
      );
    });

    test('NO on the dialog signs out nothing', () {
      final logout = _region(
        code,
        'Future<void> _logOut() async {',
        'Future<void> _signOutGuarded() async {',
      );
      // The early return on NO sits before the sign-out call.
      expect(logout.contains('if (!yes) return;'), isTrue);
      expect(
        logout.indexOf('if (!yes) return;') <
            logout.indexOf('_signOutGuarded()'),
        isTrue,
      );
    });

    test('YES signs out AND navigates to login at once', () {
      final logout = _region(
        code,
        'Future<void> _logOut() async {',
        'Future<void> _signOutGuarded() async {',
      );
      // Sign-out happens, then the stack is popped back to the
      // root route — whose content is the login screen after the
      // authStateChanges emission. This is the stuck-screen fix.
      expect(logout.contains('await _signOutGuarded();'), isTrue);
      expect(
        logout.contains(
            'Navigator.of(context).popUntil((route) => route.isFirst)'),
        isTrue,
      );
      expect(
        logout.indexOf('await _signOutGuarded();') <
            logout.indexOf('popUntil((route) => route.isFirst)'),
        isTrue,
      );
    });

    test('logout path never pushes a new AuthScreen', () {
      final logout = _region(
        code,
        'Future<void> _logOut() async {',
        'Future<void> _signOutGuarded() async {',
      );
      // AuthScreen never pops itself — a pushed copy would trap
      // the user on login after re-sign-in.
      expect(logout.contains('AuthScreen'), isFalse);
      expect(logout.contains('pushAndRemoveUntil'), isFalse);
      expect(logout.contains('pushReplacement'), isFalse);
    });

    test('no unbounded await before navigation (all steps time out)', () {
      final guarded = _region(
        code,
        'Future<void> _signOutGuarded() async {',
        'Future<void> _backupProfile() async {',
      );
      // All five sign-out steps, each timeout-guarded at 5 s.
      expect(guarded.contains('AdminMode.set(false)'), isTrue);
      expect(guarded.contains('PresenceService.goOffline()'), isTrue);
      expect(guarded.contains('PushService.logout()'), isTrue);
      expect(guarded.contains('GoogleSignIn().signOut()'), isTrue);
      expect(guarded.contains('FirebaseAuth.instance'), isTrue);
      expect(guarded.contains('.signOut()'), isTrue);
      final timeouts =
          '.timeout(const Duration(seconds: 5))'.allMatches(guarded).length;
      expect(timeouts, 5,
          reason: 'every sign-out step must carry the 5 s timeout');
    });

    test('rapid LOG OUT taps cannot stack dialogs', () {
      expect(code.contains('bool _logoutDialogOpen = false'), isTrue);
      final logout = _region(
        code,
        'Future<void> _logOut() async {',
        'Future<void> _signOutGuarded() async {',
      );
      expect(logout.contains('if (_logoutDialogOpen) return;'), isTrue);
      expect(logout.contains('_logoutDialogOpen = true;'), isTrue);
      expect(logout.contains('_logoutDialogOpen = false;'), isTrue);
    });
  });

  group('FIX 4 — the confirmation dialog itself (utils.dart)', () {
    test('dialog matches the exit-dialog style (MockupCard + gold)', () {
      final dialog = _region(
        utils,
        'Future<bool> showLogoutConfirmDialog(BuildContext context) async {',
        'Future<void> showInfoDialog(',
      );
      expect(dialog.contains('MockupCard('), isTrue);
      expect(dialog.contains('Icons.logout'), isTrue);
      expect(dialog.contains("'Do you want to log out?'"), isTrue);
      expect(dialog.contains("child: const Text('NO'"), isTrue);
      expect(dialog.contains("child: const Text('YES'"), isTrue);
      expect(dialog.contains('backgroundColor: kGold'), isTrue);
      expect(dialog.contains('return result == true;'), isTrue);
    });
  });

  group('FIX 4 — confirmation dialog behaviour (widget tests)', () {
    // NOTE: no pumpAndSettle() here — the dialog's MockupCard runs
    // an infinite 4.5 s shine animation (_ctrl.repeat()), so the
    // tester would never settle. Fixed-duration pumps instead.
    Future<void> openDialog(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  _dialogResult = await showLogoutConfirmDialog(ctx);
                },
                child: const Text('LOG OUT'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('LOG OUT'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    testWidgets('dialog shows with the question + YES + NO',
        (tester) async {
      await openDialog(tester);
      expect(find.text('Do you want to log out?'), findsOneWidget);
      expect(find.text('YES'), findsOneWidget);
      expect(find.text('NO'), findsOneWidget);
      expect(find.byIcon(Icons.logout), findsOneWidget);
    });

    testWidgets('YES returns true', (tester) async {
      _dialogResult = null;
      await openDialog(tester);
      await tester.tap(find.text('YES'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(_dialogResult, isTrue);
    });

    testWidgets('NO returns false', (tester) async {
      _dialogResult = null;
      await openDialog(tester);
      await tester.tap(find.text('NO'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(_dialogResult, isFalse);
    });

    testWidgets('dismissing the dialog returns false', (tester) async {
      _dialogResult = null;
      await openDialog(tester);
      // Tap the barrier (top-left corner, outside the dialog).
      await tester.tapAt(const Offset(5, 5));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(_dialogResult, isFalse);
    });
  });
}

// Shared slot for the dialog widget tests above (the dialog future
// completes into this from the tapped button's callback).
bool? _dialogResult;
