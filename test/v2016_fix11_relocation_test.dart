// v2016 FIX 11 — VOICE ROOM RELOCATION (2026-11-22 user order) —
// voice/chat rooms move OUT of tournament details and INTO the team
// chat. Covered:
//   1. Mic counts: every team room has 6 seats (teamMicCount,
//      single source). FIX 11 (2026-11-23) removed the Squad
//      team type, so the old SQUAD 4 branch is gone.
//   2. Room-id routing: team rooms squad_<teamId>, public community
//      rooms community_<id>, squad rooms squad_<squadId>, tournament
//      rooms tournament_<id>. The room page AND the status sheet
//      must agree on the team room id.
//   3. No tournament room entry in tournament details — the
//      MatchDetailsPage / MatchRoomPage chat buttons are gone.
//   4. Team chat opens the team room (Voice button wired, team
//      scope, micCount from teamMicCount).
//   5. Public community voice still uses community_ (unchanged).
// Source-invariant tests read the sources (same pattern as
// my_team_tournament_chat_removed_test.dart): no network, no
// Supabase/Firebase init.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/services/squad.dart';

String _read(String path) => File(path).readAsStringSync();

// Code only: full-line // comments are stripped because the removal
// notes mention the old entries by name — the assertions must check
// code, not prose.
String _code(String src) {
  return src
      .split('\n')
      .where((l) => !l.trimLeft().startsWith('//'))
      .join('\n');
}

void main() {
  group('Fix 11 — mic counts (all teams 6)', () {
    // FIX 12 G5 (2026-11-23): the Clan type is gone too — the
    // is_clan distinction no longer exists, so teamMicCount takes
    // no parameter and every team room has 6 seats.
    test('teamMicCount: 6, no type parameter', () {
      expect(teamMicCount(), 6);
    });

    test('teamMicCount signature takes no isClan flag', () {
      final squad = _read('lib/services/squad.dart');
      expect(squad, contains('int teamMicCount() => 6;'));
      expect(squad, isNot(contains('teamMicCount(bool')));
    });

    test('room falls back to 6 mics when the caller passes 0', () {
      final room = _read('lib/screens/room_screen.dart');
      expect(
        room,
        contains('widget.micCount > 0 ? widget.micCount : 6'),
        reason: 'team mic default must be the clan count (6)',
      );
    });
  });

  group('Fix 11 — room-id routing', () {
    test('room-id helpers produce the right prefixes', () {
      expect(squadRoomId('abc'), 'squad_abc');
      expect(communityRoomId('abc'), 'community_abc');
      expect(tournamentRoomId('abc'), 'tournament_abc');
      // A team room id is squad_ + teamId — never community_.
      expect(squadRoomId('team42'), startsWith('squad_'));
      expect(squadRoomId('team42'), isNot(startsWith('community_')));
    });

    test('room page routes team scope via squadRoomId', () {
      final room = _code(_read('lib/screens/room_screen.dart'));
      expect(room, contains('_isTeam ? squadRoomId(widget.teamId)'));
      expect(room, isNot(contains('communityRoomId(widget.teamId)')),
          reason: 'team rooms must not use the community_ prefix');
    });

    test('status sheet agrees with the room page on the team id', () {
      final sheet = _code(_read('lib/screens/status_sheet.dart'));
      expect(sheet,
          contains('widget.teamId.isNotEmpty ? squadRoomId(widget.teamId)'));
      expect(sheet, isNot(contains('communityRoomId(widget.teamId)')));
    });

    test('team chat rows stay keyed team_<id>', () {
      final room = _read('lib/screens/room_screen.dart');
      expect(room, contains("'team_\${widget.teamId}'"));
    });
  });

  group('Fix 11 — tournament room entries removed', () {
    test('no OPEN MATCH CHAT button in tournament pages', () {
      final home = _code(_read('lib/screens/home_screens.dart'));
      expect(home, isNot(contains('OPEN MATCH CHAT')));
    });

    test('no room-page entry left in home_screens', () {
      final home = _code(_read('lib/screens/home_screens.dart'));
      expect(home, isNot(contains('UnifiedRoomPage(')),
          reason:
              'all three home_screens room entries were the removed buttons');
      expect(home, isNot(contains("import 'room_screen.dart';")));
    });
  });

  group('Fix 11 — team chat opens the team room', () {
    test('embedded voice panel uses team scope + teamMicCount', () {
      final pro = _read('lib/screens/pro_features.dart');
      expect(pro, contains("scope: 'team',"));
      // FIX 12 G5: no is_clan read at the call site — the voice
      // panel passes no flag at all.
      expect(pro, contains('micCount: teamMicCount(),'));
      expect(pro, isNot(contains("widget.team['is_clan']")));
      expect(pro, contains("teamId: SupaDb.strOf(widget.team['id']),"));
      // v2017: the room page is embedded inline now (no push) —
      // the same constructor args, mounted as a panel.
      expect(pro, contains('embedded: true,'));
    });

    test('Voice button is wired in team mode only', () {
      final pro = _read('lib/screens/pro_features.dart');
      // v2017: the button toggles the inline panel now (was
      // _openVoiceRoom's push).
      expect(pro, contains('onVoice: _isTournament ? null : _toggleVoice,'));
      expect(pro, contains('voiceActive: _voicePanelOpen,'));
    });
  });

  group('Fix 11 — public community voice unchanged', () {
    test('community voice still uses communityRoomId', () {
      // FIX 12 G6: the detail page no longer builds the room id
      // inline — it mounts the shared UnifiedRoomPage with scope
      // 'community' + communityId, and the ROOM derives the
      // community_<id> id via communityRoomId(widget.communityId).
      // Same room-id scheme, new wiring — pin both sides.
      final comm = _read('lib/screens/communities_screens.dart');
      expect(comm, contains("scope: 'community',"));
      expect(comm, contains('communityId: _id,'));
      final room = _code(_read('lib/screens/room_screen.dart'));
      expect(room,
          contains('_isCommunity ? communityRoomId(widget.communityId)'));
    });
  });
}
