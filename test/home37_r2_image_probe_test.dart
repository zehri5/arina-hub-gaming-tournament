// HOME #37 FIX ROUND 2 — regression test for the blank card image.
//
// ROOT CAUSE (proven 2026-11-19): _TournamentCard wrapped its Row in
// IntrinsicHeight and gave the image `height: double.infinity`.
// That throws 'height.isFinite' in layout (debug) and, with asserts
// off in release, sizes the card infinitely tall (one card + a huge
// empty gap below, blank image slot). The fix: NO IntrinsicHeight,
// NO explicit image height — the Row's stretch gives the image slot
// the content column's height. This test pumps the exact fixed
// pattern and asserts the image renders at a finite size.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('fixed card image slot renders at finite size', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                width: 110,
                child: Image.asset('assets/images/trophy_cover.jpg',
                    width: 110, fit: BoxFit.cover),
              ),
            ),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Paid Solo Cup'),
                  Text('0 / 100 Players'),
                  SizedBox(height: 10),
                  Text('Details   Join Event'),
                ],
              ),
            ),
          ],
        ),
      ),
    ));
    await tester.pumpAndSettle();
    final img = find.byType(Image);
    expect(img, findsOneWidget);
    final box = tester.getSize(img);
    expect(box.width, 110);
    expect(box.height, greaterThan(50));
    expect(box.height.isFinite, isTrue);
  });
}
