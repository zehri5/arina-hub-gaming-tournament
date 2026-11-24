// B-11 ROOM-CREDENTIALS REWIRE (2026-11-21) + F16 + P2 one-liners —
// source-invariant regression tests. No network, no Supabase init,
// no Firebase init: they read the R-copy sources and assert the
// shapes that close the live leak. If any of these fail, the leak
// (or the F16/P2 fix) has regressed — do NOT ship.
//
// Covered:
//   1. getRoomCredentials calls the LIVE 2-arg RPC
//      (p_caller_uid + p_tournament_id), never the 1-arg call.
//   2. No direct tournament-row credential read remains in
//      home_screens.dart (t['roomId'] / t['roomPassword'] /
//      tournament['roomId'] / tournament['roomPassword']).
//   3. getRoomCredentials is the read path at all three display
//      sites (dialog, _roomDetailsCompact, _MatchRoomDetailsCard).
//   4. (REMOVED FIX 32, 2026-11-24) the admin form's credential
//      writes — the admin panel is gone from the user app.
//   5. (REMOVED FIX 32) F16 create-form columns — same reason.
//   6. P2 markers: TournamentsPage in-page header, mate gold
//      rings + READY-under-mates-only, Match Room gold chevron,
//      BACK TO HOME radius 28, _twoToneTitle goldFirst flag with
//      the registration banner inverted (#6) and #1 untouched.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

String _region(String src, String startMarker, String endMarker) {
  final start = src.indexOf(startMarker);
  expect(start, isNot(-1), reason: 'missing marker: $startMarker');
  final end = src.indexOf(endMarker, start);
  expect(end, isNot(-1), reason: 'missing marker: $endMarker');
  return src.substring(start, end);
}

void main() {
  late String db;
  late String home;

  setUpAll(() {
    db = _read('lib/services/supabase_db.dart');
    home = _read('lib/screens/home_screens.dart');
  });

  group('B-11 (a) getRoomCredentials — live 2-arg RPC', () {
    test('calls get_room_credentials with p_caller_uid + p_tournament_id',
        () {
      final fn = _region(db, 'getRoomCredentials(String tournamentId)',
          '// ---------- avatar frames');
      expect(fn, contains("'p_caller_uid'"));
      expect(fn, contains("'p_tournament_id'"));
      expect(fn, contains("FirebaseAuth.instance.currentUser?.uid"));
    });

    test('never calls the RPC with the tournament id alone', () {
      expect(
          db,
          isNot(contains(
              "rpc('get_room_credentials', params: {'p_tournament_id': tournamentId})")));
    });

    test('fails closed without a signed-in caller', () {
      final fn = _region(db, 'getRoomCredentials(String tournamentId)',
          '// ---------- avatar frames');
      expect(fn, contains('Not signed in'));
      expect(fn, contains("'ok': false"));
    });
  });

  group('B-11 (b) no direct row read in home_screens.dart', () {
    test('no t[...] / tournament[...] credential reads remain', () {
      for (final bad in [
        "t['roomId']",
        "t['roomPassword']",
        "tournament['roomId']",
        "tournament['roomPassword']",
      ]) {
        expect(home, isNot(contains(bad)), reason: 'leak read left: $bad');
      }
    });

    test('all three display sites read via getRoomCredentials', () {
      final calls = 'getRoomCredentials('.allMatches(home).length;
      expect(calls, greaterThanOrEqualTo(3),
          reason: 'dialog + _roomDetailsCompact + _MatchRoomDetailsCard');
    });

    test('credentials are read from the RPC result map, not the row',
        () {
      expect(home, contains("SupaDb.strOf(creds['roomId'])"));
      expect(home, contains("SupaDb.strOf(creds['roomPassword'])"));
    });
  });

  group('P2 one-liners', () {
    test('(a) TournamentsPage has the in-page TOURNAMENTS header', () {
      final page = _region(home, 'class _TournamentsPageState',
          'class _PresenceContextUpdater');
      expect(page, contains('_tournamentsAppBarTitle()'));
      expect(page, contains('_showSearch = !_showSearch'));
    });

    test('(b) mate gold rings + READY pill under mates only', () {
      final card = _region(
          home, 'Widget _yourTeamCard(', 'class MatchDetailsPage');
      expect(card, contains("if (strVal(p['firebase_uid']) != myUid)"));
      expect(card, isNot(contains('? hGold')));
      expect(card, contains('READY ✓'));
    });

    test('(c) Match Room back chevron is gold', () {
      final page = _region(home, 'class MatchRoomPage',
          'class _MatchRoomCountdown');
      final leading = _region(page, 'Icons.chevron_left', 'MATCH ROOM');
      expect(leading, contains('color: hGold'));
    });

    test('(d) BACK TO HOME is a full pill (radius 28)', () {
      final idx = home.indexOf("'BACK TO HOME'");
      expect(idx, isNot(-1));
      final before = home.substring(idx - 700, idx);
      expect(before, contains('BorderRadius.circular(28)'));
    });

    test('(e) two-tone flag: banner inverted for #6, #1 default kept',
        () {
      expect(home, contains('bool goldFirst = true'));
      expect(home, contains('goldFirst: false'));
      // #1 (MatchCountdownPage) still uses the default: no flag.
      final countdown = _region(
          home, 'class MatchCountdownPage', 'class _ReadyPlayersList');
      expect(countdown, isNot(contains('goldFirst: false')));
    });
  });
}
