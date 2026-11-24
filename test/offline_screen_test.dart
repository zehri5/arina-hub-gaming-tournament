// P2 #11 (2026-11-21) — OfflineScreen is WIRED now: SplashGate's
// no-internet branch renders this screen. These tests pump the
// screen directly and prove the mockup #11 content + both buttons
// fire their callbacks (onRetry = re-run boot/connectivity check,
// onGoBack = exit at the boot gate).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/screens/offline_screen.dart';

void main() {
  testWidgets('mockup #11 content renders with the boot-gate message',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: OfflineScreen(
          message: 'Check your internet connection and try again.',
          onRetry: () {},
          onGoBack: () {},
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Check your internet connection and try again.'),
        findsOneWidget);
    expect(find.text('RETRY CONNECTION'), findsOneWidget);
    expect(find.text('GO BACK'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('RETRY CONNECTION fires onRetry, GO BACK fires onGoBack',
      (tester) async {
    var retried = false;
    var wentBack = false;
    await tester.pumpWidget(
      MaterialApp(
        home: OfflineScreen(
          onRetry: () => retried = true,
          onGoBack: () => wentBack = true,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('RETRY CONNECTION'));
    await tester.pump();
    expect(retried, isTrue);
    await tester.tap(find.text('GO BACK'));
    await tester.pump();
    expect(wentBack, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('no callbacks: RETRY hidden, GO BACK always renders, title still does',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: OfflineScreen()),
    );
    await tester.pump(const Duration(milliseconds: 100));
    // OfflineState renders RETRY only when onRetry is non-null,
    // but GO BACK ALWAYS renders (mockup #11 — arena_components
    // OfflineState default: pop this route when possible, else
    // exit the app). The old expectation (no GO BACK without a
    // callback) is stale since that default landed; the test now
    // asserts the current intentional behaviour.
    expect(find.text('GO BACK'), findsOneWidget);
    expect(find.text('RETRY CONNECTION'), findsNothing);
    expect(find.text('Check your internet connection and try again.'),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
