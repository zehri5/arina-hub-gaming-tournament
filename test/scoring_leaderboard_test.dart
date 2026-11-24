// WORKSTREAM D — SCORING / LEADERBOARDS / DISPUTES (ChatGPT
// blueprint §5-5/§5-7/§6; backend guide §1.4 OD-02 DECIDED).
//
// Pins the decided model: placement table 1st=10 + 1/kill via the
// NEW SupaDb.matchPoints (the old kills x 10 + 50 formula is
// superseded), leaderboard ranking order + tie handling, the
// dispute lifecycle, transparency-footer data, and the 8
// exception kinds.
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/platform/core/exceptions.dart';
import 'package:protournament_user/platform/core/scoring.dart';
import 'package:protournament_user/platform/disputes/dispute_service.dart';
import 'package:protournament_user/platform/scoring/leaderboard_page.dart';
import 'package:protournament_user/services/supabase_db.dart';
import 'package:protournament_user/utils.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    langUrduNotifier.value = false;
  });

  group('SupaDb.matchPoints (decided model, OD-02)', () {
    test('1st + 12 kills = 22', () {
      expect(SupaDb.matchPoints(kills: 12, placement: 1), 22);
    });
    test('9th + 5 kills = 5 (no placement points, kills only)', () {
      expect(SupaDb.matchPoints(kills: 5, placement: 9), 5);
    });
    test('placement 0 = 0 (no result)', () {
      expect(SupaDb.matchPoints(kills: 12, placement: 0), 0);
    });
    test('2nd + 0 kills = 7', () {
      expect(SupaDb.matchPoints(kills: 0, placement: 2), 7);
    });
    test('matches calculateMatchPoints with the default template', () {
      for (final p in [1, 2, 3, 4, 5, 6, 7, 8, 9, 16]) {
        expect(
          SupaDb.matchPoints(kills: 7, placement: p),
          calculateMatchPoints(placement: p, kills: 7),
        );
      }
    });
  });

  group('leaderboard ranking', () {
    List<Map<String, dynamic>> rows() => [
          {
            'firebase_uid': 'u1',
            'tournament_id': 't1',
            'placement': 1,
            'kills': 12,
          },
          {
            'firebase_uid': 'u2',
            'tournament_id': 't1',
            'placement': 2,
            'kills': 6,
          },
          {
            'firebase_uid': 'u3',
            'tournament_id': 't1',
            'placement': 9,
            'kills': 12,
          },
          {
            'firebase_uid': 'u4',
            'tournament_id': 't1',
            'placement': 2,
            'kills': 6,
          },
        ];

    test('aggregateResults sums points per player (22 / 13 / 12 / 13)', () {
      final entries = aggregateResults(rows(),
          names: {'u1': 'A', 'u2': 'B', 'u3': 'C', 'u4': 'D'});
      final byUid = {for (final e in entries) e.uid: e};
      expect(byUid['u1']!.points, 22); // 10 + 12
      expect(byUid['u2']!.points, 13); // 7 + 6
      expect(byUid['u3']!.points, 12); // 0 + 12
      expect(byUid['u4']!.points, 13); // 7 + 6
      expect(byUid['u1']!.kills, 12);
      expect(byUid['u1']!.matches, 1);
      expect(byUid['u1']!.name, 'A');
    });

    test('aggregateResults sums across multiple results for one player', () {
      final entries = aggregateResults([
        {'firebase_uid': 'u1', 'tournament_id': 't1', 'placement': 1, 'kills': 5},
        {'firebase_uid': 'u1', 'tournament_id': 't2', 'placement': 3, 'kills': 2},
      ]);
      expect(entries, hasLength(1));
      expect(entries.first.points, 15 + 7); // (10+5) + (5+2)
      expect(entries.first.kills, 7);
      expect(entries.first.matches, 2);
    });

    test('ranking order is points desc; equal points share a rank', () {
      final ranked = rankEntries(aggregateResults(rows()));
      // u1 first (22 pts). u2 / u4 tie at 13 pts (6 kills each,
      // uid order) and share rank 2; u3 (12 pts) is rank 4
      // (rank skips after the tie).
      expect(ranked.map((e) => e.uid).toList(), ['u1', 'u2', 'u4', 'u3']);
      expect(ranked[0].rank, 1); // 22 pts
      expect(ranked[1].rank, 2); // 13 pts
      expect(ranked[2].rank, 2); // 13 pts
      expect(ranked[3].rank, 4); // 12 pts
    });

    test('rank after a tie skips (1, 1, 3)', () {
      final ranked = rankEntries([
        const LeaderboardEntry(
            uid: 'a', name: 'A', points: 20, kills: 5, matches: 1),
        const LeaderboardEntry(
            uid: 'b', name: 'B', points: 20, kills: 3, matches: 1),
        const LeaderboardEntry(
            uid: 'c', name: 'C', points: 10, kills: 9, matches: 1),
      ]);
      expect(ranked.map((e) => e.rank).toList(), [1, 1, 3]);
    });

    test('aggregateResults sums damage per player', () {
      final entries = aggregateResults([
        {'firebase_uid': 'u1', 'tournament_id': 't1', 'placement': 1, 'kills': 5, 'damage': 1200},
        {'firebase_uid': 'u1', 'tournament_id': 't2', 'placement': 3, 'kills': 2, 'damage': 800},
        {'firebase_uid': 'u2', 'tournament_id': 't1', 'placement': 2, 'kills': 6},
      ]);
      final byUid = {for (final e in entries) e.uid: e};
      expect(byUid['u1']!.damage, 2000);
      expect(byUid['u2']!.damage, 0); // no damage column -> 0
    });

    test('damage breaks ties after kills (template tiebreaker)', () {
      final ranked = rankEntries([
        const LeaderboardEntry(
            uid: 'a', name: 'A', points: 13, kills: 6, matches: 1, damage: 900),
        const LeaderboardEntry(
            uid: 'b', name: 'B', points: 13, kills: 6, matches: 1, damage: 1500),
        const LeaderboardEntry(
            uid: 'c', name: 'C', points: 13, kills: 6, matches: 1, damage: 1500),
      ]);
      // Same points + same kills: higher damage first; equal
      // damage falls back to name. All three share rank 1.
      expect(ranked.map((e) => e.uid).toList(), ['b', 'c', 'a']);
      expect(ranked.map((e) => e.rank).toList(), [1, 1, 1]);
    });

    test('movement: up / down / same / none', () {
      const up = LeaderboardEntry(
          uid: 'a',
          name: 'A',
          points: 20,
          kills: 1,
          matches: 1,
          rank: 1,
          previousRank: 5);
      const down = LeaderboardEntry(
          uid: 'b',
          name: 'B',
          points: 10,
          kills: 1,
          matches: 1,
          rank: 5,
          previousRank: 1);
      const same = LeaderboardEntry(
          uid: 'c',
          name: 'C',
          points: 10,
          kills: 1,
          matches: 1,
          rank: 3,
          previousRank: 3);
      const none = LeaderboardEntry(
          uid: 'd', name: 'D', points: 10, kills: 1, matches: 1, rank: 2);
      expect(up.movement, 1);
      expect(down.movement, -1);
      expect(same.movement, 0);
      expect(none.movement, 0);
    });
  });

  group('transparency footer data', () {
    test('a ranking carries lastUpdated + verified flag + method string', () {
      final now = DateTime.now();
      final ranking = LeaderboardRanking(
        scope: LeaderboardScope.global,
        scopeLabel: 'Global',
        entries: const [],
        lastUpdated: now,
        verified: false,
        method: leaderboardMethodString(),
      );
      expect(ranking.lastUpdated, now);
      expect(ranking.verified, isFalse);
      expect(ranking.method, contains('Official Style'));
      expect(ranking.method, contains('1/kill'));
      expect(ranking.scope, LeaderboardScope.global);
    });

    test('method string names the template', () {
      expect(leaderboardMethodString(kLegacy022ScoringTemplate),
          contains('Legacy Server (022)'));
    });

    test('all five scopes exist', () {
      expect(LeaderboardScope.values.length, 5);
      expect(
          LeaderboardScope.values.map((s) => s.name).toSet(),
          {'match', 'tournament', 'season', 'country', 'global'});
    });
  });

  group('dispute lifecycle', () {
    test('file → open → underReview → resolved with resolution text', () async {
      final service = DisputeService();
      final item = await service.fileDispute(
        tournamentId: 't1',
        matchId: 'm1',
        kind: ExceptionType.wrongScore,
        detail: 'My kills were counted wrong.',
        evidenceUrls: ['https://example.com/shot.png'],
        reportedBy: 'u1',
      );
      expect(item.status, DisputeStatus.open);
      expect(item.tournamentId, 't1');
      expect(item.type, ExceptionType.wrongScore);

      var mine = await service.listMyDisputes('u1');
      expect(mine, hasLength(1));
      expect(mine.first.matchId, 'm1');
      expect(mine.first.evidenceUrls, ['https://example.com/shot.png']);

      expect(await service.markUnderReview(item.id), isTrue);
      mine = await service.listMyDisputes('u1');
      expect(mine.first.status, DisputeStatus.underReview);

      expect(
          await service.resolveDispute(
              item.id, 'Score corrected to 12 kills.', 'admin1'),
          isTrue);
      mine = await service.listMyDisputes('u1');
      expect(mine.first.status, DisputeStatus.resolved);
      expect(mine.first.resolution, 'Score corrected to 12 kills.');
      expect(mine.first.resolvedBy, 'admin1');
      expect(mine.first.resolvedAt, isNotNull);

      // Resolved disputes leave the open queue.
      final open = await service.listOpenExceptions();
      expect(open, isEmpty);
    });

    test('reject path stores the reason as resolution text', () async {
      final service = DisputeService();
      final item = await service.fileDispute(
        tournamentId: 't1',
        kind: ExceptionType.cheating,
        detail: 'He cheated.',
        reportedBy: 'u1',
      );
      expect(
          await service.rejectDispute(
              item.id, 'No evidence — screenshot was unclear.', 'admin1'),
          isTrue);
      final mine = await service.listMyDisputes('u1');
      expect(mine.first.status, DisputeStatus.rejected);
      expect(mine.first.resolution, 'No evidence — screenshot was unclear.');
      expect(await service.listOpenExceptions(), isEmpty);
    });

    test('listMyDisputes only returns the filer’s disputes', () async {
      final service = DisputeService();
      await service.fileDispute(
          tournamentId: 't1',
          kind: ExceptionType.other,
          detail: 'Mine',
          reportedBy: 'u1');
      await service.fileDispute(
          tournamentId: 't1',
          kind: ExceptionType.other,
          detail: 'Not mine',
          reportedBy: 'u2');
      expect(await service.listMyDisputes('u1'), hasLength(1));
      expect(await service.listMyDisputes('u2'), hasLength(1));
      expect(await service.listOpenExceptions(), hasLength(2));
    });

    test('unknown ids return false / null', () async {
      final service = DisputeService();
      expect(await service.markUnderReview('nope'), isFalse);
      expect(await service.resolveDispute('nope', 'x', 'a'), isFalse);
      expect(await service.rejectDispute('nope', 'x', 'a'), isFalse);
      expect(await service.getDispute('nope'), isNull);
    });
  });

  group('exception kinds', () {
    test('exactly 8 kinds, including other', () {
      expect(ExceptionType.values.length, 8);
      expect(ExceptionType.values, contains(ExceptionType.other));
      expect(
          ExceptionType.values.map((e) => e.wireValue).toSet(),
          {
            'cheating',
            'fake_evidence',
            'wrong_score',
            'server_issue',
            'misconduct',
            'cancellation',
            'disqualification',
            'other',
          });
    });

    test('exactly 4 dispute statuses', () {
      expect(DisputeStatus.values.length, 4);
      expect(
          DisputeStatus.values.map((s) => s.wireValue).toSet(),
          {'open', 'under_review', 'resolved', 'rejected'});
    });
  });
}
