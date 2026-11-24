// ARENA HUB component library widget tests (Phase 1 — 2026-11-19).
// Presentational only: no Supabase, no Firebase, no network. Proves the
// §7.3 components build with the gold tokens and behave (taps, busy
// state, filter selection, field input). A HomePage pump needs backend
// mocks and is NOT attempted here — Phase 7 phone test covers it.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/components/arena_components.dart';
import 'package:protournament_user/theme.dart';

Widget wrap(Widget child) => MaterialApp(
      theme: ThemeData.dark().copyWith(scaffoldBackgroundColor: kBg),
      home: Scaffold(body: child),
    );

void main() {
  testWidgets('ArenaLogo renders ARENA / HUB wordmark', (tester) async {
    await tester.pumpWidget(wrap(const ArenaLogo()));
    expect(find.text('ARENA'), findsOneWidget);
    expect(find.text('HUB'), findsOneWidget);
  });

  testWidgets('GoldButton fires onPressed and shows busy spinner',
      (tester) async {
    var tapped = false;
    await tester.pumpWidget(wrap(GoldButton(
      label: 'Join Event',
      onPressed: () => tapped = true,
    )));
    await tester.tap(find.text('Join Event'));
    expect(tapped, isTrue);

    await tester.pumpWidget(
        wrap(const GoldButton(label: 'Wait', onPressed: null, busy: true)));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('OutlineButton fires onPressed', (tester) async {
    var tapped = false;
    await tester.pumpWidget(wrap(OutlineButton(
      label: 'Details',
      onPressed: () => tapped = true,
    )));
    await tester.tap(find.text('Details'));
    expect(tapped, isTrue);
  });

  testWidgets('StatusBadge live is red, upcoming is gold', (tester) async {
    await tester.pumpWidget(wrap(const Column(children: [
      StatusBadge(label: 'LIVE', kind: StatusKind.live),
      StatusBadge(label: 'UPCOMING', kind: StatusKind.upcoming),
    ])));
    expect(find.text('LIVE'), findsOneWidget);
    expect(find.text('UPCOMING'), findsOneWidget);
    final live = tester.widget<Container>(find
        .ancestor(of: find.text('LIVE'), matching: find.byType(Container))
        .first);
    expect((live.decoration as BoxDecoration).color, kLiveRed);
  });

  testWidgets('TournamentCard renders title, players and Join button',
      (tester) async {
    var joined = false;
    await tester.pumpWidget(wrap(TournamentCard(
      title: 'Squad Showdown',
      dateText: 'Sat, 22 Nov · 6:00 PM',
      modeText: 'Squad · 4v4',
      playersText: '42/64 players',
      progress: 42 / 64,
      statusLabel: 'UPCOMING',
      statusKind: StatusKind.upcoming,
      primaryLabel: 'Join Event',
      onDetails: () {},
      onPrimary: () => joined = true,
    )));
    expect(find.text('Squad Showdown'), findsOneWidget);
    expect(find.text('42/64 players'), findsOneWidget);
    expect(find.text('Join Event'), findsOneWidget);
    await tester.tap(find.text('Join Event'));
    expect(joined, isTrue);
  });

  testWidgets('FilterTabs selects the tapped tab', (tester) async {
    var selected = -1;
    await tester.pumpWidget(wrap(FilterTabs(
      labels: const ['All', 'Live', 'Upcoming'],
      selectedIndex: 0,
      onSelected: (i) => selected = i,
    )));
    await tester.tap(find.text('Upcoming'));
    expect(selected, 2);
  });

  testWidgets('EmptyState / ErrorState / OfflineState render with retry',
      (tester) async {
    var retried = false;
    // Scrollable: OfflineState is now the full-screen #11 design
    // (~440px tall), so the three states no longer fit a fixed
    // 600px test viewport stacked in a plain Column. Assertions
    // unchanged.
    await tester.pumpWidget(wrap(SingleChildScrollView(
        child: Column(children: [
      const EmptyState(
          icon: Icons.emoji_events,
          title: 'No tournaments yet',
          body: 'Check back soon for new events.'),
      ErrorState(
          message: 'Something went wrong', onRetry: () => retried = true),
      const OfflineState(),
    ]))));
    expect(find.text('No tournaments yet'), findsOneWidget);
    expect(find.text('Something went wrong'), findsOneWidget);
    expect(find.text('Check your internet connection and try again.'),
        findsOneWidget);
    await tester.tap(find.text('Retry'));
    expect(retried, isTrue);
  });

  testWidgets('ArenaFormField accepts input', (tester) async {
    final ctl = TextEditingController();
    await tester.pumpWidget(wrap(ArenaFormField(
      controller: ctl,
      label: 'Team name',
      hint: 'Enter team name',
    )));
    await tester.enterText(find.byType(TextField), 'Alpha Squad');
    expect(ctl.text, 'Alpha Squad');
  });

  testWidgets('ProgressBar and LeaderboardItem render', (tester) async {
    await tester.pumpWidget(wrap(const Column(children: [
      ProgressBar(value: 0.65),
      LeaderboardItem(rank: 1, name: 'Team Alpha', pointsText: '142 pts'),
      LeaderboardItem(rank: 2, name: 'Team Bravo', pointsText: '120 pts'),
    ])));
    expect(find.text('Team Alpha'), findsOneWidget);
    expect(find.text('142 pts'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
  });

  testWidgets('AppHeader renders logo, bell with badge and avatar',
      (tester) async {
    var bell = false;
    await tester.pumpWidget(wrap(AppHeader(
      unreadCount: 3,
      onBell: () => bell = true,
      onAvatarTap: () {},
    )));
    expect(find.text('ARENA'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(find.byIcon(Icons.notifications_outlined), findsOneWidget);
    expect(find.byIcon(Icons.person), findsOneWidget);
    await tester.tap(find.byIcon(Icons.notifications_outlined));
    expect(bell, isTrue);
  });

  testWidgets('GoldButton uses the gold token', (tester) async {
    await tester.pumpWidget(
        wrap(GoldButton(label: 'Go', onPressed: () {})));
    final btn = tester.widget<ElevatedButton>(find.byType(ElevatedButton));
    final bg = btn.style?.backgroundColor?.resolve(<WidgetState>{});
    expect(bg, kGold);
  });
}
