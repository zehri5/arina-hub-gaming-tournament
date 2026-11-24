// N-create-tournament AUTOMATION + ANTI-FRAUD (2026-11-20) — pure-logic
// tests. Covers the helpers only (the flows themselves need live data):
//   1. matchPoints (DECIDED model, OD-02 2026-11-21: placement
//      table 1st=10 + 1/kill — the old kills x 10 + win 50 is
//      superseded)
//   2. matchWinnings (kills x per-kill prize + placement win bonus)
//   3. prizeFundable (paid prize must fit fee x players - commission)
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/screens/pro_features.dart';
import 'package:protournament_user/services/supabase_db.dart';

void main() {
  group('matchPoints', () {
    test('5 kills + 1st place = 10 + 5 = 15 (decided model)', () {
      expect(SupaDb.matchPoints(kills: 5, placement: 1), 15);
    });
    test('3 kills + 4th place = 0 + 3 = 3 (decided model: 4th+ = 0)', () {
      expect(SupaDb.matchPoints(kills: 3, placement: 4), 3);
    });
    test('0 kills + 1st place = 10 (placement points only)', () {
      expect(SupaDb.matchPoints(kills: 0, placement: 1), 10);
    });
    test('0 kills + 4th place = 0 (decided model: 4th+ = 0)', () {
      expect(SupaDb.matchPoints(kills: 0, placement: 4), 0);
    });
  });

  group('matchWinnings', () {
    test('5 kills x Rs 10 + 1st of Rs 10000 (50%) = 50 + 5000', () {
      final w = SupaDb.matchWinnings(
        kills: 5,
        perKillPrize: 10,
        placement: 1,
        prizePool: 10000,
        splitFirst: 50,
        splitSecond: 30,
        splitThird: 20,
      );
      expect(w['killAmount'], 50);
      expect(w['winBonus'], 5000);
      expect(w['total'], 5050);
    });
    test('2nd place takes the 2nd share', () {
      final w = SupaDb.matchWinnings(
        kills: 2,
        perKillPrize: 10,
        placement: 2,
        prizePool: 10000,
        splitFirst: 50,
        splitSecond: 30,
        splitThird: 20,
      );
      expect(w['killAmount'], 20);
      expect(w['winBonus'], 3000);
      expect(w['total'], 3020);
    });
    test('4th place gets no win bonus, only kill money', () {
      final w = SupaDb.matchWinnings(
        kills: 4,
        perKillPrize: 10,
        placement: 4,
        prizePool: 10000,
        splitFirst: 50,
        splitSecond: 30,
        splitThird: 20,
      );
      expect(w['killAmount'], 40);
      expect(w['winBonus'], 0);
      expect(w['total'], 40);
    });
    test('free tournament (prize 0, per-kill 0) pays 0', () {
      final w = SupaDb.matchWinnings(
        kills: 8,
        perKillPrize: 0,
        placement: 1,
        prizePool: 0,
        splitFirst: 50,
        splitSecond: 30,
        splitThird: 20,
      );
      expect(w['total'], 0);
    });
  });

  group('prizeFundable', () {
    test('Rs 50 fee x 100 players - 10% = Rs 4500 max prize', () {
      expect(prizeFundable(prizePool: 4500, entryFee: 50, maxPlayers: 100, commissionPct: 10), isTrue);
      expect(prizeFundable(prizePool: 4501, entryFee: 50, maxPlayers: 100, commissionPct: 10), isFalse);
      expect(prizeFundable(prizePool: 5000, entryFee: 50, maxPlayers: 100, commissionPct: 10), isFalse);
    });
    test('free tournaments are always fundable (sponsor-funded prize)', () {
      expect(prizeFundable(prizePool: 100000, entryFee: 0, maxPlayers: 100, commissionPct: 10), isTrue);
    });
  });

group('splitAmounts (runbook payout preview, PREP-FIRST)', () {
  test('10000 prize, 50/30/20 -> 5000/3000/2000', () {
    expect(splitAmounts(10000, 50, 30, 20), [5000, 3000, 2000]);
  });
  test('amounts always sum to the prize pool', () {
    final a = splitAmounts(9999, 50, 30, 20);
    expect((a[0] + a[1] + a[2]).toStringAsFixed(2), '9999.00');
  });
});

// FIX 32 (2026-11-24): legacyCreditBlockedReason group removed with
// the admin panel (AdminDbSystem.creditPrizes guard lives in the
// separate admin APK now).
group('periodKeyFor weekly (window the free-creation quota counts in)', () {
  // The free quota (1/week, user decision 2026-11-20 ~18:05 PKT) counts
  // FREE creations whose created_at falls in the current ISO calendar
  // week (Mon-Sun), via SupaDb.countFreeTournamentsCreatedThisWeek.
  // These tests pin that window: Mon 2026-11-16 .. Sun 2026-11-22 is
  // one week; Sun 2026-11-15 belongs to the previous week.
  test('Monday and Sunday of the same ISO week share one key', () {
    final monday = SupaDb.periodKeyFor(DateTime(2026, 11, 16), 'weekly');
    final sunday = SupaDb.periodKeyFor(DateTime(2026, 11, 22), 'weekly');
    expect(monday, sunday);
    expect(monday, '2026-W47');
  });
  test('the previous Sunday is a different week', () {
    expect(
      SupaDb.periodKeyFor(DateTime(2026, 11, 15), 'weekly'),
      isNot(SupaDb.periodKeyFor(DateTime(2026, 11, 16), 'weekly')),
    );
    expect(SupaDb.periodKeyFor(DateTime(2026, 11, 15), 'weekly'), '2026-W46');
  });
  test('daily key still differs per day (weekly is the only shared key)', () {
    expect(
      SupaDb.periodKeyFor(DateTime(2026, 11, 16), 'daily'),
      isNot(SupaDb.periodKeyFor(DateTime(2026, 11, 17), 'daily')),
    );
  });
});
}
