// N-create-tournament (2026-11-20) — pure-logic tests for the
// professional Create Tournament workflow. Covers the helpers only
// (the page itself loads live data):
//   1. platform commission math (10% default, paise rounding)
//   2. prize-split validation (must total exactly 100%)
//   3. max collectable (entry fee x max players)
//   4. the platform commission constant + default split
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/screens/pro_features.dart';

void main() {
  group('platformCommissionFor', () {
    test('10% of a Rs 100 entry fee is Rs 10', () {
      expect(platformCommissionFor(100, 10), 10);
    });
    test('10% of a Rs 50 entry fee is Rs 5', () {
      expect(platformCommissionFor(50, 10), 5);
    });
    test('free entry (fee 0) has zero commission', () {
      expect(platformCommissionFor(0, 10), 0);
    });
    test('rounds to paise (Rs 333 x 10% = Rs 33.30)', () {
      expect(platformCommissionFor(333, 10), 33.3);
    });
    test('full collectable: Rs 50 x 100 players = Rs 5000 -> Rs 500 commission', () {
      expect(platformCommissionFor(maxCollectable(50, 100), 10), 500);
    });
  });

  group('prizeSplitValid', () {
    test('default split 50/30/20 is valid', () {
      expect(prizeSplitValid(50, 30, 20), isTrue);
      expect(prizeSplitValid(kDefaultPrizeSplit[0], kDefaultPrizeSplit[1], kDefaultPrizeSplit[2]), isTrue);
    });
    test('splits that do not total 100 are invalid', () {
      expect(prizeSplitValid(60, 30, 20), isFalse);
      expect(prizeSplitValid(50, 30, 10), isFalse);
      expect(prizeSplitValid(0, 0, 0), isFalse);
    });
  });

  group('maxCollectable', () {
    test('fee x max players', () {
      expect(maxCollectable(50, 100), 5000);
      expect(maxCollectable(0, 100), 0);
    });
  });

  test('platform commission constant is 10%', () {
    expect(kPlatformCommissionPct, 10);
  });

  group('creationQuotaBlocked (user decisions, voice calls 2026-11-20)', () {
    test('free weekly quota constant is 1/week', () {
      expect(kMaxFreeTournamentsPerWeek, 1);
    });
    test('PAID is never blocked — no limit (18:04 PKT decision)', () {
      expect(creationQuotaBlocked(entryFee: 100, freeCreatedThisWeek: 0), isFalse);
      expect(creationQuotaBlocked(entryFee: 50, freeCreatedThisWeek: 1), isFalse);
      expect(creationQuotaBlocked(entryFee: 50, freeCreatedThisWeek: 10), isFalse);
      expect(creationQuotaBlocked(entryFee: 0.01, freeCreatedThisWeek: 100), isFalse);
    });
    test('FREE is allowed when 0 created this week', () {
      expect(creationQuotaBlocked(entryFee: 0, freeCreatedThisWeek: 0), isFalse);
    });
    test('FREE is blocked once 1 created this week (18:05 PKT decision)', () {
      expect(creationQuotaBlocked(entryFee: 0, freeCreatedThisWeek: 1), isTrue);
      expect(creationQuotaBlocked(entryFee: 0, freeCreatedThisWeek: 5), isTrue);
    });
    test('FREE quota OFF by admin — never blocked (18:45 PKT decision)', () {
      expect(creationQuotaBlocked(entryFee: 0, freeCreatedThisWeek: 1, quotaEnabled: false), isFalse);
      expect(creationQuotaBlocked(entryFee: 0, freeCreatedThisWeek: 5, quotaEnabled: false), isFalse);
    });
    test('FREE quota ON (explicit) — blocked once 1 created this week', () {
      expect(creationQuotaBlocked(entryFee: 0, freeCreatedThisWeek: 1, quotaEnabled: true), isTrue);
      expect(creationQuotaBlocked(entryFee: 0, freeCreatedThisWeek: 0, quotaEnabled: true), isFalse);
    });
    test('PAID is never blocked even when the quota is ON', () {
      expect(creationQuotaBlocked(entryFee: 100, freeCreatedThisWeek: 5, quotaEnabled: true), isFalse);
      expect(creationQuotaBlocked(entryFee: 100, freeCreatedThisWeek: 5, quotaEnabled: false), isFalse);
    });
  });

  group('no-show rule (user decision, voice call 2026-11-20 ~18:36 PKT)', () {
    test('grace period is 10 minutes (5–10 minute delay, then fee forfeit)', () {
      expect(kNoShowGraceMinutes, 10);
    });
  });
}
