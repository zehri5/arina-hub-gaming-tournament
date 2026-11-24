// Premium achievement badge tests (P-all-fixes, Worker F, 2026-11-20).
// Pumps the badge at 64dp and at small sizes and asserts it renders
// without overflow/exception; the name->kind mapping keeps the REAL
// earned achievements (no invented badges).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/components/premium_badge.dart';

void main() {
  Future<void> pumpBadge(
    WidgetTester tester, {
    required PremiumBadgeKind kind,
    required double size,
    bool locked = false,
    bool glow = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: PremiumAchievementBadge(
              kind: kind,
              size: size,
              locked: locked,
              glow: glow,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(PremiumAchievementBadge), findsOneWidget);
    expect(
      tester.getSize(find.byType(PremiumAchievementBadge)),
      Size(size, size * 783 / 732),
    );
  }

  testWidgets('premium badge renders at 64dp, all four kinds + glow',
      (tester) async {
    for (final kind in PremiumBadgeKind.values) {
      await pumpBadge(tester, kind: kind, size: 64, glow: true);
    }
  });

  testWidgets('premium badge renders at small sizes (44dp tile, 28dp row) + locked',
      (tester) async {
    for (final kind in PremiumBadgeKind.values) {
      await pumpBadge(tester, kind: kind, size: 44, glow: true);
      await pumpBadge(tester, kind: kind, size: 28);
      await pumpBadge(tester, kind: kind, size: 28, locked: true);
      await pumpBadge(tester, kind: kind, size: 44, locked: true);
    }
  });

  testWidgets('five premium badges share a 360px row without overflow (Player Stats)',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 360,
            child: Row(
              children: [
                for (final kind in PremiumBadgeKind.values)
                  Expanded(
                    child: Center(
                      child: PremiumAchievementBadge(
                          kind: kind, size: 56, glow: true),
                    ),
                  ),
                const Expanded(
                  child: Center(
                    child: PremiumAchievementBadge(
                        kind: PremiumBadgeKind.mvp, size: 56, glow: true),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  test('name mapping keeps the real earned achievements', () {
    expect(premiumBadgeKindFor('First Win'), PremiumBadgeKind.mvp);
    expect(premiumBadgeKindFor('10 Matches'), PremiumBadgeKind.slayer);
    expect(premiumBadgeKindFor('Champion'), PremiumBadgeKind.survivor);
    expect(premiumBadgeKindFor('Veteran'), PremiumBadgeKind.deadshot);
    expect(premiumBadgeKindFor('Top Earner'), PremiumBadgeKind.mvp);
    // Unknown names never produce a missing badge.
    expect(premiumBadgeKindFor('Something New'), PremiumBadgeKind.mvp);
  });
}
