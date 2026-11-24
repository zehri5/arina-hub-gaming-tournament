// LEADERBOARD SLIM FIX (2026-11-20) — regression test for the
// oversized YOU row.
//
// ROOT CAUSE (measured from the user's phone screenshot): the old row
// used appCard (14px padding) + a two-line Matches stack on the YOU
// row + CachedFramedAvatar, whose equipped frame ring inflates the
// avatar 40 -> 50dp — the YOU row measured ~80dp tall while other
// rows were ~68dp. The fix: LeaderboardRow is a fixed 64dp box (40dp
// avatar + 12px vertical padding each side), single-line everything,
// YOU differing only by the caller's gold border + pill. This test
// pumps the real shipped widget and asserts those heights on a
// 360px-wide screen, with no overflow.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/screens/more_screens.dart';

void main() {
  testWidgets('leaderboard rows are slim and equal height', (tester) async {
    tester.view.physicalSize = const Size(720, 1600);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    Widget row({required bool isMe}) => LeaderboardRow(
          rank: isMe ? 1 : 4,
          name: isMe ? 'sameer' : 'Ghost_Rider',
          photoUrl: '',
          pointsText: '0',
          matches: 1,
          isMe: isMe,
        );

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: Column(
            children: [
              row(isMe: false),
              const SizedBox(height: 8),
              // YOU row exactly as _row builds it: gold wrapper + pill.
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Container(
                      decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xFFFFC928), width: 2)),
                      child: row(isMe: true),
                    ),
                    Positioned(
                      top: -9,
                      left: 16,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                            color: const Color(0xFFFFC928), borderRadius: BorderRadius.circular(8)),
                        child: const Text('YOU',
                            style: TextStyle(color: Colors.black, fontSize: 10, fontWeight: FontWeight.bold)),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ));
    // FIX 2 (2026-11-21): cards animate FOREVER by design (the
    // MockupCard shine controller repeats), so pumpAndSettle can
    // never complete — it times out. This test measures LAYOUT
    // (row heights), not animation, so a bounded pump is correct.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(tester.takeException(), isNull);

    final plain = tester.getSize(find.byWidgetPredicate((w) => w is LeaderboardRow && !w.isMe));
    final you = tester.getSize(find.byWidgetPredicate((w) => w is LeaderboardRow && w.isMe));
    // Same slim 64dp box for every row, YOU included.
    expect(plain.height, 64);
    expect(you.height, 64);
    expect(plain.height, you.height);
    // Avatar photo circle is 37dp (40dp outer with the 1.5dp ring).
    final avatars = find.byType(CircleAvatar);
    expect(avatars, findsNWidgets(2));
    expect(tester.getSize(avatars.first).width, 37);
    expect(tester.getSize(avatars.first).height, 37);
    // Single-line matches: no 'Matches' label text anywhere.
    expect(find.text('Matches'), findsNothing);
    // The YOU pill is present.
    expect(find.text('YOU'), findsOneWidget);
  });
}
