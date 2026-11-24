/// Squad definition (documented assumption).
///
/// The HTML join form has NO explicit squad/grouping record - it only has
/// `teamName` (+ slot) fields per tournament. So a squad is defined here as:
/// players sharing the SAME `teamName` in the SAME tournament.
///   squadId is tournamentId + "_" + normalised teamName.
/// (lowercased, non-alphanumerics -> underscore). Solo players (empty
/// teamName) have no squad: their squadId is empty and squad chat/voice
/// is not offered to them. The join screen stores this `squadId` on the
/// player's `registeredPlayers` entry so both apps can compute it the
/// same way.
String squadIdFor(String tournamentId, String teamName) {
  final norm = teamName.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_').replaceAll(RegExp(r'^_+|_+$'), '');
  if (norm.isEmpty) return '';
  return '${tournamentId}_$norm';
}

String squadRoomId(String squadId) => 'squad_$squadId';
String tournamentRoomId(String tournamentId) => 'tournament_$tournamentId';
// COMMUNITY VOICE (2026-11-22 user order): one LiveKit room per
// community, same naming scheme as squad/tournament rooms.
String communityRoomId(String communityId) => 'community_$communityId';

// v2016 FIX 11 (user order 2026-11-22): total mic seats in a team
// voice room. FIX 11 (2026-11-23) removed the SQUAD team type;
// FIX 12 GROUP G5 (user order 2026-11-23 01:09) removed the CLAN
// type too — every team is just a TEAM now, no is_clan distinction
// anywhere in UI or logic, so every team room has 6 mic seats.
// The parameter is gone with the distinction: callers pass nothing.
// NOTE: the room id stays `squad_<teamId>` (server-side rooms
// already exist under that name) — only the UI/type distinction
// went away.
int teamMicCount() => 6;
