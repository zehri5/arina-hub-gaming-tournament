// MOCKUP CARD ANIMATION (2026-11-20) — REWRITTEN for FIX 23
// item 23 (2026-11-23): the corner shines are GONE — item 23
// superseded the two rotating gold shine lines with the purple
// border + glow card (ChatGPT design). The animation itself
// (4500ms controller + _MockupCardBorderPainter) was deleted
// with them; `animate` is now a deprecated no-op kept only so
// old call sites still compile.
//
// What these tests pin now: no shine painter exists anywhere
// in a MockupCard (animate true or false), and the card still
// renders with the item-23 frame (purple border + frosted
// fill). The old "t advances with the clock" behaviour is
// superseded, not broken.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/theme.dart';

/// No shine painter anywhere in the card (scoped to the card
/// itself — the debug banner is a CustomPaint too).
void _expectNoShinePainter(WidgetTester tester) {
  expect(
      find.descendant(
          of: find.byType(MockupCard),
          matching: find.byType(CustomPaint)),
      findsNothing);
}

/// The frame container carries the item-23 purple border.
void _expectPurpleFrame(WidgetTester tester) {
  final frames = tester.widgetList<Container>(find.byType(Container));
  expect(
      frames.any((c) {
        final d = c.decoration;
        if (d is! BoxDecoration) return false;
        final b = d.border;
        return b is Border && b.top.color == kCardPurpleBorder;
      }),
      isTrue);
}

void main() {
  testWidgets('MockupCard has no shine painter (animate: true is a no-op)',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: MockupCard(child: Text('stats')),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('stats'), findsOneWidget);
    _expectNoShinePainter(tester);
    _expectPurpleFrame(tester);
    // The clock advancing changes nothing — there is no
    // animation left to advance.
    await tester.pump(const Duration(milliseconds: 4500));
    _expectNoShinePainter(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('MockupCard has no shine painter (animate: false)',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: MockupCard(animate: false, child: Text('row')),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('row'), findsOneWidget);
    _expectNoShinePainter(tester);
    _expectPurpleFrame(tester);
    await tester.pump(const Duration(milliseconds: 4500));
    _expectNoShinePainter(tester);
    expect(tester.takeException(), isNull);
  });
}
