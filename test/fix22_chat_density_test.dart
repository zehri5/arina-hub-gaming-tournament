// FIX 22 item 13 — chat density pins.
// Tight message rows: name + time on ONE line above the bubble,
// small vertical gaps. Colors stay dark + gold (the reference
// screenshot's pink/blue was layout reference only).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/components/arena_chat.dart';

void main() {
  group('fix22 item 13 — density constants', () {
    test('row gaps are the tight values', () {
      expect(kChatRowBottomGap, 8);
      expect(kChatNameBubbleGap, 3);
      expect(kChatAvatarGap, 6);
      expect(kChatBubblePaddingV, 7);
      expect(kChatBubblePaddingVPolished, 8);
    });
  });

  group('fix22 item 13 — message row layout', () {
    testWidgets('name + time on one line above the bubble',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ArenaChatMessage(
              isMine: false,
              senderName: 'Test Sender',
              timeLabel: '10:30',
              text: 'Hello world',
            ),
          ),
        ),
      );
      expect(find.text('Test Sender'), findsOneWidget);
      expect(find.text('10:30'), findsOneWidget);
      expect(find.text('Hello world'), findsOneWidget);
      // Name and time share one Row: same vertical centre.
      final nameTop =
          tester.getTopLeft(find.text('Test Sender')).dy;
      final timeTop = tester.getTopLeft(find.text('10:30')).dy;
      // Same Row: tops within a couple of px (different font sizes).
      expect((nameTop - timeTop).abs(), lessThan(3.0));
      // The bubble sits BELOW the name line.
      final bubbleTop =
          tester.getTopLeft(find.text('Hello world')).dy;
      expect(bubbleTop, greaterThan(nameTop));
      expect(tester.takeException(), isNull);
    });

    testWidgets('no overflow at 360px with a long message',
        (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ArenaChatMessage(
              isMine: false,
              senderName: 'A Very Long Sender Name Here',
              timeLabel: '10:30',
              text: 'This is a very long message that should wrap '
                  'across several lines inside the bubble without '
                  'overflowing the 360px-wide screen at all.',
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
    });
  });
}
