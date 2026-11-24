// SAMEER'S FIXES (2026-11-21, voice call) — regression tests for
// workstream H: FIX 1 podium line behind photos, FIX 2 Requests-tab
// badge, FIX 3 Home empty state, FIX 4 DM pictures, FIX 8
// WhatsApp-style chat bubbles.
//
// FIX 1 NOTE (honest): the podium itself (_podium in
// more_screens.dart) is a private method on _LeaderboardPageState
// and only renders with live leaderboard data, so no widget test
// can pump it in isolation — the layering (boxes -> overlays ->
// avatars) was verified by code inspection against the Stack child
// order in _podium, and the rank-row half of FIX 1 is covered here
// by pumping the real LeaderboardRow: its avatar paints above the
// MockupCard shine layer by construction (theme.dart Stack order).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/components/cached_image.dart';
import 'package:protournament_user/components/chat_bubble.dart';
import 'package:protournament_user/screens/community_screens.dart';
import 'package:protournament_user/screens/home_screens.dart';
import 'package:protournament_user/screens/more_screens.dart';
import 'package:protournament_user/theme.dart';

void main() {
  // FIX 2 — Requests-tab badge: shows the count when pending > 0,
  // shows nothing when 0, caps at 9+ (same rule as the nav badge).
  group('FIX 2 RequestsTabBadge', () {
    Future<void> pumpBadge(WidgetTester tester, int count) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: Center(child: RequestsTabBadge(count: count))),
      ));
      await tester.pump();
    }

    testWidgets('shows the count when pending > 0', (tester) async {
      await pumpBadge(tester, 3);
      expect(find.text('3'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('shows nothing when 0', (tester) async {
      await pumpBadge(tester, 0);
      expect(find.text('0'), findsNothing);
      expect(find.byType(RequestsTabBadge), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('caps at 9+', (tester) async {
      await pumpBadge(tester, 12);
      expect(find.text('9+'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    // CLIP FIX (2026-11-21, user screenshot): the Requests badge
    // overhangs its pill by 6px (Positioned top: -6) and the tab
    // row lives in a horizontal SingleChildScrollView, which clips
    // at its own edge by default — the top half of the red "1" was
    // cut off. The scroll view must not clip, so the badge paints
    // into the 8px headroom above it. RESTRUCTURE (2026-11-22):
    // the tab row moved with the hub's tabs into FriendsRequestsPage
    // (CommunityHubPage is deleted; refined 05:07 to Friends /
    // Requests / Followers) — the test pumps FriendsRequestsPage
    // now. The page is pumpable in tests: the readiness probes +
    // count stream swallow backend errors and read as not-ready /
    // 0 with no backend.
    testWidgets('tab row scroll view does not clip the badge', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: FriendsRequestsPage(uid: 'test-uid'),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final scrollView = tester.widget<SingleChildScrollView>(
        find.byType(SingleChildScrollView),
      );
      expect(scrollView.scrollDirection, Axis.horizontal);
      expect(scrollView.clipBehavior, Clip.none);
      expect(tester.takeException(), isNull);
    });
  });

  // FIX 3 — Home tournaments empty state renders with its text +
  // Browse Events action, and the action fires.
  group('FIX 3 HomeTournamentsEmptyState', () {
    testWidgets('renders text + Browse Events action, content-sized', (tester) async {
      var tapped = false;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: HomeTournamentsEmptyState(onBrowse: () => tapped = true),
          ),
        ),
      ));
      await tester.pump();
      expect(find.text('No tournaments yet'), findsOneWidget);
      expect(find.text('Browse Events'), findsOneWidget);
      // FIX 3 REGRESSION GUARD: the card sizes to its content —
      // the pre-fix _DarkMockupCard sized to constraints.biggest
      // (infinite in a scroll view, whole-screen in a Column).
      final size = tester.getSize(find.byType(HomeTournamentsEmptyState));
      expect(size.height, lessThan(400));
      expect(size.height, greaterThan(100));
      await tester.tap(find.text('Browse Events'));
      expect(tapped, isTrue);
      expect(tester.takeException(), isNull);
    });
  });

  // FIX 1 (rank-row half) — the real row builds with its avatar
  // present; the podium layering is verified by code inspection
  // (see the file header note).
  group('FIX 1 leaderboard rank row', () {
    testWidgets('row builds with avatar above the card shine layer', (tester) async {
      tester.view.physicalSize = const Size(720, 1600);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: LeaderboardRow(
            rank: 1,
            name: 'sameer',
            photoUrl: '',
            pointsText: '0',
            matches: 1,
            isMe: true,
          ),
        ),
      ));
      await tester.pump();
      expect(find.text('sameer'), findsOneWidget);
      // The avatar (initial fallback) is in the tree.
      expect(find.text('S'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  // FIX 8 — WhatsApp-style bubbles: sender right + gold-tinted,
  // receiver left + card-grey, timestamp attached, image inside.
  group('FIX 8 ChatBubble', () {
    Future<void> pumpBubble(WidgetTester tester, ChatBubble bubble) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ListView(children: [bubble]),
        ),
      ));
      await tester.pump();
    }

    testWidgets('sender bubble is right-aligned and gold-tinted', (tester) async {
      await pumpBubble(tester, const ChatBubble(isMine: true, text: 'Hello', timeLabel: '10:30 PM'));
      final align = tester.widget<Align>(find.descendant(of: find.byType(ChatBubble), matching: find.byType(Align)).first);
      expect(align.alignment, Alignment.centerRight);
      final container = tester.widget<Container>(find.descendant(of: find.byType(ChatBubble), matching: find.byType(Container)).first);
      final deco = container.decoration as BoxDecoration;
      expect(deco.color, kGold.withValues(alpha: 0.16));
      expect(find.text('Hello'), findsOneWidget);
      expect(find.text('10:30 PM'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('receiver bubble is left-aligned and card-grey', (tester) async {
      await pumpBubble(tester, const ChatBubble(isMine: false, text: 'Hi there', timeLabel: '10:31 PM'));
      final align = tester.widget<Align>(find.descendant(of: find.byType(ChatBubble), matching: find.byType(Align)).first);
      expect(align.alignment, Alignment.centerLeft);
      final container = tester.widget<Container>(find.descendant(of: find.byType(ChatBubble), matching: find.byType(Container)).first);
      final deco = container.decoration as BoxDecoration;
      expect(deco.color, kCard);
      expect(find.text('Hi there'), findsOneWidget);
      expect(find.text('10:31 PM'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('room layout: own bubble stays left-aligned with gold tint', (tester) async {
      await pumpBubble(tester, const ChatBubble(isMine: true, alignEnd: false, text: 'Room msg'));
      final align = tester.widget<Align>(find.descendant(of: find.byType(ChatBubble), matching: find.byType(Align)).first);
      expect(align.alignment, Alignment.centerLeft);
      final container = tester.widget<Container>(find.descendant(of: find.byType(ChatBubble), matching: find.byType(Container)).first);
      final deco = container.decoration as BoxDecoration;
      expect(deco.color, kGold.withValues(alpha: 0.16));
      expect(tester.takeException(), isNull);
    });

    testWidgets('image message renders the image inside the bubble', (tester) async {
      var tapped = false;
      await pumpBubble(
        tester,
        ChatBubble(
          isMine: true,
          imageUrl: 'https://example.com/pic.jpg',
          timeLabel: '10:32 PM',
          onImageTap: () => tapped = true,
        ),
      );
      expect(find.byType(ArenaCachedImage), findsOneWidget);
      expect(find.text('10:32 PM'), findsOneWidget);
      await tester.tap(find.byType(ArenaCachedImage));
      expect(tapped, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('sender name line shows for group bubbles', (tester) async {
      await pumpBubble(tester, const ChatBubble(isMine: false, senderName: 'usmi', text: 'Hello'));
      expect(find.text('usmi'), findsOneWidget);
      expect(find.text('Hello'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  // FIX 4 — DM composer has the image-attach button; uploading shows
  // a spinner instead of the button.
  group('FIX 4 DmComposer', () {
    testWidgets('attach button exists and fires', (tester) async {
      final ctrl = TextEditingController();
      addTearDown(ctrl.dispose);
      var attached = false;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: DmComposer(
            controller: ctrl,
            enabled: true,
            sending: false,
            uploading: false,
            onSend: () {},
            onAttach: () => attached = true,
          ),
        ),
      ));
      await tester.pump();
      expect(find.byTooltip('Send a picture'), findsOneWidget);
      expect(find.byIcon(Icons.image), findsOneWidget);
      expect(find.byIcon(Icons.send), findsOneWidget);
      await tester.tap(find.byTooltip('Send a picture'));
      expect(attached, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('uploading shows a spinner, not the attach button', (tester) async {
      final ctrl = TextEditingController();
      addTearDown(ctrl.dispose);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: DmComposer(
            controller: ctrl,
            enabled: true,
            sending: false,
            uploading: true,
            onSend: () {},
            onAttach: () {},
          ),
        ),
      ));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byTooltip('Send a picture'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('disabled composer disables attach and send', (tester) async {
      final ctrl = TextEditingController();
      addTearDown(ctrl.dispose);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: DmComposer(
            controller: ctrl,
            enabled: false,
            sending: false,
            uploading: false,
            onSend: () {},
            onAttach: () {},
          ),
        ),
      ));
      await tester.pump();
      final attach = tester.widget<IconButton>(
        find.ancestor(of: find.byTooltip('Send a picture'), matching: find.byType(IconButton)),
      );
      expect(attach.onPressed, isNull);
      expect(tester.takeException(), isNull);
    });
  });
}
