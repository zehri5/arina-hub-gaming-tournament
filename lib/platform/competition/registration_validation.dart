import 'package:protournament_user/platform/core/tournament_enums.dart';
import 'package:protournament_user/utils.dart';

/// Smart-registration validation (ChatGPT blueprint §5-1; backend
/// guide §5-1 `register_team` RPC).
///
/// Pure functions — no I/O, no state. Each returns an error string
/// (via tr()) when the check fails, or null when it passes. The
/// server-side `register_team` RPC re-checks all of these; these
/// client checks exist so the player sees the problem BEFORE
/// submitting.
///
/// Roster sizes MUST match `SupaDb.teamSizeOf`
/// (lib/services/supabase_db.dart): squad/team = 4, duo = 2,
/// anything else (solo) = 1.

/// Expected roster size for a team mode — mirrors
/// `SupaDb.teamSizeOf`: solo = 1, duo = 2, squad = 4.
int expectedRosterSize(TeamMode mode) => switch (mode) {
      TeamMode.solo => 1,
      TeamMode.duo => 2,
      TeamMode.squad => 4,
    };

/// Same game UID twice in one roster → error, else null.
/// Empty/blank UIDs are ignored here (roster-size / presence checks
/// catch them); only a repeated non-empty UID fails.
String? duplicateUidError(List<String> uids) {
  final seen = <String>{};
  for (final raw in uids) {
    final uid = raw.trim();
    if (uid.isEmpty) continue;
    if (!seen.add(uid)) {
      return tr(
        'The same player UID appears twice in this team. Each player can only register once per tournament.',
        'Ek hi player UID team mein do dafa hai. Har player ek tournament mein sirf ek dafa register ho sakta hai.',
      );
    }
  }
  return null;
}

/// Roster size must equal the mode size (solo = 1, duo = 2,
/// squad = 4). Returns an error string, or null when it matches.
String? rosterSizeError({required int size, required TeamMode mode}) {
  final expected = expectedRosterSize(mode);
  if (size == expected) return null;
  return tr(
    'A ${mode.label} team needs exactly $expected player${expected == 1 ? '' : 's'} (you have $size).',
    '${mode.label} team ke liye exactly $expected player chahiye (aap ke paas $size hain).',
  );
}

/// Eligibility: country restriction + level requirement.
/// `allowedCountries` is the tournament's allowed country codes
/// (guide §2 `allowed_country_codes`); an empty list means no
/// country restriction. `levelRequired` 0 means no level gate.
/// Returns null when the player is eligible, else the first
/// failing reason.
String? eligibilityError({
  required String playerCountry,
  required List<String> allowedCountries,
  required int playerLevel,
  required int levelRequired,
}) {
  if (allowedCountries.isNotEmpty) {
    final allowed =
        allowedCountries.map((c) => c.trim().toUpperCase()).toSet();
    if (!allowed.contains(playerCountry.trim().toUpperCase())) {
      return tr(
        'This tournament is not open to players from your country.',
        'Ye tournament aap ke mulk ke players ke liye nahi hai.',
      );
    }
  }
  if (levelRequired > 0 && playerLevel < levelRequired) {
    return tr(
      'This tournament needs level $levelRequired (your level: $playerLevel).',
      'Is tournament ke liye level $levelRequired chahiye (aap ka level: $playerLevel).',
    );
  }
  return null;
}
