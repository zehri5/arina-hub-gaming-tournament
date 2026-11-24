// CHILD B (batch 2) — P1-10 + #16(a).
//
// Pins the approve-time points persist + merge behaviour:
//  * SupaDb.splitMatchPoints splits the decided-model total into
//    placement/kill/team parts that always sum to matchPoints.
//  * SupaDb.mergeResultPoints copies stored result points onto
//    registration rows by firebase_uid (0 when no result row).
//  * aggregateResults uses the STORED team_points for 'verified'
//    rows (054-scored, authoritative) and computes from
//    placement/kills for 'approved' rows (pre-P1-10 rows still
//    carry stored 0, so computing is the honest value).
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/platform/scoring/leaderboard_page.dart';
import 'package:protournament_user/services/supabase_db.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('SupaDb.splitMatchPoints (P1-10, decided model OD-02)', () {
    test('1st + 12 kills = {10, 12, 22}', () {
      expect(
        SupaDb.splitMatchPoints(kills: 12, placement: 1),
        {'placement_points': 10, 'kill_points': 12, 'team_points': 22},
      );
    });
    test('2nd + 5 kills = {7, 5, 12}', () {
      expect(
        SupaDb.splitMatchPoints(kills: 5, placement: 2),
        {'placement_points': 7, 'kill_points': 5, 'team_points': 12},
      );
    });
    test('3rd + 0 kills = {5, 0, 5}', () {
      expect(
        SupaDb.splitMatchPoints(kills: 0, placement: 3),
        {'placement_points': 5, 'kill_points': 0, 'team_points': 5},
      );
    });
    test('4th + 3 kills = {0, 3, 3} (kills only)', () {
      expect(
        SupaDb.splitMatchPoints(kills: 3, placement: 4),
        {'placement_points': 0, 'kill_points': 3, 'team_points': 3},
      );
    });
    test('placement 0 = all 0 (no result)', () {
      expect(
        SupaDb.splitMatchPoints(kills: 12, placement: 0),
        {'placement_points': 0, 'kill_points': 0, 'team_points': 0},
      );
    });
    test('split always sums to matchPoints', () {
      for (final p in [1, 2, 3, 4, 5, 9]) {
        for (final k in [0, 1, 7, 12]) {
          final split = SupaDb.splitMatchPoints(kills: k, placement: p);
          expect(
            split['placement_points']! + split['kill_points']!,
            SupaDb.matchPoints(kills: k, placement: p),
          );
          expect(split['team_points'],
              SupaDb.matchPoints(kills: k, placement: p));
        }
      }
    });
  });

  group('SupaDb.mergeResultPoints (P1-10)', () {
    test('merges stored points onto matching registration rows', () {
      final regs = [
        {'firebase_uid': 'u1', 'rank': 1, 'kills': 12},
        {'firebase_uid': 'u2', 'rank': 2, 'kills': 5},
        {'firebase_uid': 'u3', 'rank': 4, 'kills': 3},
      ];
      final results = [
        {
          'firebase_uid': 'u1',
          'status': 'approved',
          'placement_points': 10,
          'kill_points': 12,
          'team_points': 22,
        },
        {
          'firebase_uid': 'u2',
          'status': 'approved',
          'placement_points': 7,
          'kill_points': 5,
          'team_points': 12,
        },
      ];
      final merged = SupaDb.mergeResultPoints(regs, results);
      expect(merged[0]['team_points'], 22);
      expect(merged[0]['placement_points'], 10);
      expect(merged[0]['kill_points'], 12);
      expect(merged[0]['result_status'], 'approved');
      expect(merged[1]['team_points'], 12);
      // u3 has no result row yet: honest 0, rank/kills untouched.
      expect(merged[2]['team_points'], 0);
      expect(merged[2]['placement_points'], 0);
      expect(merged[2]['kill_points'], 0);
      expect(merged[2]['rank'], 4);
      expect(merged[2]['kills'], 3);
    });

    test('empty results list leaves every row at 0', () {
      final regs = [
        {'firebase_uid': 'u1', 'rank': 1},
      ];
      final merged = SupaDb.mergeResultPoints(regs, []);
      expect(merged[0]['team_points'], 0);
      expect(merged[0]['result_status'], '');
    });
  });

  group('aggregateResults stored-points preference (#16a)', () {
    test('verified row uses stored team_points, not computed', () {
      // Placement 1 + 12 kills computes to 22, but the server
      // scored this row to 30 (template) — stored wins.
      final rows = [
        {
          'firebase_uid': 'u1',
          'tournament_id': 't1',
          'status': 'verified',
          'placement': 1,
          'kills': 12,
          'team_points': 30,
        },
      ];
      final entries = aggregateResults(rows);
      expect(entries.single.points, 30);
    });

    test('approved row with stored 0 still computes (pre-P1-10 row)', () {
      final rows = [
        {
          'firebase_uid': 'u1',
          'tournament_id': 't1',
          'status': 'approved',
          'placement': 1,
          'kills': 12,
          'team_points': 0,
        },
      ];
      final entries = aggregateResults(rows);
      expect(entries.single.points, 22);
    });

    test('verified 0 is honest (4th place, 0 kills scored 0)', () {
      final rows = [
        {
          'firebase_uid': 'u1',
          'tournament_id': 't1',
          'status': 'verified',
          'placement': 4,
          'kills': 0,
          'team_points': 0,
        },
      ];
      final entries = aggregateResults(rows);
      expect(entries.single.points, 0);
    });

    test('mixed approved + verified rows rank on their real points', () {
      final rows = [
        {
          'firebase_uid': 'u1',
          'tournament_id': 't1',
          'status': 'approved',
          'placement': 2,
          'kills': 5,
          'team_points': 12,
        },
        {
          'firebase_uid': 'u2',
          'tournament_id': 't1',
          'status': 'verified',
          'placement': 1,
          'kills': 3,
          'team_points': 13,
        },
      ];
      final ranked = rankEntries(aggregateResults(rows));
      expect(ranked[0].uid, 'u2');
      expect(ranked[0].points, 13);
      expect(ranked[0].rank, 1);
      expect(ranked[1].uid, 'u1');
      expect(ranked[1].points, 12);
      expect(ranked[1].rank, 2);
    });
  });
}
