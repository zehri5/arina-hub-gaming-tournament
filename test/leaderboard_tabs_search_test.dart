// P-ALL-FIXES-C (2026-11-20) — regression tests for mockup #5
// leaderboard tabs + search row:
// (1) Global / Weekly / Friends are three EQUAL thirds in one box,
//     active = gold pill filling its whole third;
// (2) ArenaSearchBar(iconAtEnd: true) puts the magnifier at the
//     RIGHT inside the field with a full pill radius (24);
// (3) defaults are unchanged (left icon, radius 12, content-width
//     scroll-row tabs) so every other caller is unaffected.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/components/arena_components.dart';
import 'package:protournament_user/theme.dart';

void main() {
  testWidgets('FilterTabs expanded renders three equal thirds, active gold', (tester) async {
    tester.view.physicalSize = const Size(720, 1280);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // 316 = leaderboard inner width on the 360px screen
    // (360 - 16*2 page padding - 6*2 container padding).
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 316,
            child: FilterTabs(
              labels: const ['Global', 'Weekly', 'Friends'],
              selectedIndex: 0,
              onSelected: (_) {},
              expanded: true,
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    final detectors = tester.widgetList<GestureDetector>(find.byType(GestureDetector)).toList();
    expect(detectors, hasLength(3));
    final widths = [for (final d in detectors) tester.getSize(find.byWidget(d)).width];
    // Three equal thirds of 316, within rounding.
    for (final w in widths) {
      expect(w, closeTo(316 / 3, 1.0));
    }
    expect(widths[0], widths[1]);
    expect(widths[1], widths[2]);

    // Active pill is gold; inactive segments are transparent.
    final pills = tester
        .widgetList<Container>(find.byType(Container))
        .where((c) => c.decoration is BoxDecoration)
        .map((c) => c.decoration! as BoxDecoration)
        .toList();
    expect(pills, hasLength(3));
    expect(pills[0].color, kGold);
    expect(pills[1].color, Colors.transparent);
    expect(pills[2].color, Colors.transparent);
  });

  testWidgets('ArenaSearchBar iconAtEnd puts the icon right with pill radius', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ArenaSearchBar(
          controller: controller,
          hint: 'Search player...',
          iconAtEnd: true,
          borderRadius: 24,
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    final field = tester.widget<TextField>(find.byType(TextField));
    final decoration = field.decoration!;
    expect(decoration.prefixIcon, isNull);
    expect((decoration.suffixIcon as Icon).icon, Icons.search);
    expect((decoration.border as OutlineInputBorder).borderRadius, BorderRadius.circular(24));
  });

  testWidgets('ArenaSearchBar defaults unchanged: left icon, radius 12', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ArenaSearchBar(controller: controller),
      ),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    final field = tester.widget<TextField>(find.byType(TextField));
    final decoration = field.decoration!;
    expect((decoration.prefixIcon as Icon).icon, Icons.search);
    expect(decoration.suffixIcon, isNull);
    expect((decoration.border as OutlineInputBorder).borderRadius, BorderRadius.circular(12));
  });
}
