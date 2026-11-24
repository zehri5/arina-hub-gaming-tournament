// CHILD A (batch 3B) — ISO-week free-join quota window + cache-first
// tournament list.
//
// Pins the two pure/testable behaviours this batch changed:
//   * SupaDb.periodKeyFor(..., 'weekly') groups Mon-Sun into one
//     ISO week — the window countFreeTournamentJoinsThisWeek (and
//     the creation quota) now count in. A Monday and the Sunday of
//     the same week share a key; the next Monday does not.
//   * SupaDb.writeTournamentsCache / readCachedTournaments round
//     trip raw rows through SharedPreferences JSON and return
//     normed tournaments; corrupt or absent cache reads as [].
// The network parts (join guard itself, recordTransaction bool,
// checkInToMatch dedupe, RPC wrappers) are not unit-testable
// without a Supabase mock and are covered by flutter analyze +
// code review, not by fakes here.
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/services/supabase_db.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('periodKeyFor weekly (ISO week the free-join quota counts in)', () {
    test('Mon 2026-11-16 and Sun 2026-11-22 share one week key', () {
      expect(
        SupaDb.periodKeyFor(DateTime(2026, 11, 16), 'weekly'),
        SupaDb.periodKeyFor(DateTime(2026, 11, 22), 'weekly'),
      );
      expect(
        SupaDb.periodKeyFor(DateTime(2026, 11, 16), 'weekly'),
        '2026-W47',
      );
    });

    test('next Monday 2026-11-23 is a different week key', () {
      expect(
        SupaDb.periodKeyFor(DateTime(2026, 11, 23), 'weekly'),
        '2026-W48',
      );
      expect(
        SupaDb.periodKeyFor(DateTime(2026, 11, 23), 'weekly'),
        isNot(SupaDb.periodKeyFor(DateTime(2026, 11, 22), 'weekly')),
      );
    });
  });

  group('tournament list cache (cache-first home load)', () {
    test('write then read returns the normed rows', () async {
      await SupaDb.writeTournamentsCache([
        {
          'id': 't1',
          'name': 'Pro Tour',
          'status': 'upcoming',
          'mode': 'Squad',
          'entry_fee': 0,
          'start_time': '2026-11-22T15:00:00.000Z',
        },
        {
          'id': 't2',
          'name': 'Solo Cup',
          'status': 'ongoing',
          'mode': 'Solo',
          'entry_fee': 100,
          'start_time': '2026-11-21T15:00:00.000Z',
        },
      ]);
      final cached = await SupaDb.readCachedTournaments();
      expect(cached.length, 2);
      expect(cached[0]['id'], 't1');
      expect(cached[0]['name'], 'Pro Tour');
      expect(cached[0]['entryFee'], 0);
      expect(cached[1]['entryFee'], 100);
      expect(cached[1]['status'], 'ongoing');
    });

    test('empty cache reads as []', () async {
      expect(await SupaDb.readCachedTournaments(), isEmpty);
    });

    test('corrupt cache reads as [] instead of throwing', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('cached_tournaments_v1', 'not-json{{{');
      expect(await SupaDb.readCachedTournaments(), isEmpty);
    });

    test('rows without an id are dropped on read', () async {
      await SupaDb.writeTournamentsCache([
        {'name': 'No id row', 'status': 'upcoming'},
        {'id': 't9', 'name': 'Good row', 'status': 'upcoming'},
      ]);
      final cached = await SupaDb.readCachedTournaments();
      expect(cached.length, 1);
      expect(cached[0]['id'], 't9');
    });
  });
}
