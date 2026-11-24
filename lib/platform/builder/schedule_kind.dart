import 'package:protournament_user/utils.dart';

/// Schedule item kinds (ChatGPT blueprint §3-E; backend guide §3-E
/// `tournament_schedule_items.kind`).
///
/// Wire values are the guide's exact strings:
/// `registration` / `check_in` / `match` / `results` /
/// `verification_deadline` / `leaderboard_publish`. Times are stored
/// UTC; the app converts to local (see
/// [RegionService.formatInTimezone] in the core regions contract).
enum ScheduleKind {
  registration,
  checkIn,
  match,
  results,
  verificationDeadline,
  leaderboardPublish;

  String get label => switch (this) {
        ScheduleKind.registration =>
          tr('Registration', 'Registration'),
        ScheduleKind.checkIn => tr('Check-in', 'Check-in'),
        ScheduleKind.match => tr('Match', 'Match'),
        ScheduleKind.results => tr('Results', 'Results'),
        ScheduleKind.verificationDeadline =>
          tr('Verification deadline', 'Verification deadline'),
        ScheduleKind.leaderboardPublish =>
          tr('Leaderboard publish', 'Leaderboard publish'),
      };

  String get wireValue => switch (this) {
        ScheduleKind.registration => 'registration',
        ScheduleKind.checkIn => 'check_in',
        ScheduleKind.match => 'match',
        ScheduleKind.results => 'results',
        ScheduleKind.verificationDeadline => 'verification_deadline',
        ScheduleKind.leaderboardPublish => 'leaderboard_publish',
      };

  static ScheduleKind fromString(String? raw,
      [ScheduleKind fallback = ScheduleKind.match]) {
    final n =
        (raw ?? '').toLowerCase().replaceAll(RegExp(r'[_\-\s]'), '');
    for (final k in ScheduleKind.values) {
      if (k.wireValue.replaceAll('_', '') == n) return k;
      if (k.name.toLowerCase() == n) return k;
    }
    return fallback;
  }
}

/// The schedule kinds the pre-publish checklist requires
/// (guide §3-G "schedule complete"): registration, check-in, match
/// and results. `verification_deadline` and `leaderboard_publish`
/// are recommended but not blocking.
const List<ScheduleKind> kRequiredScheduleKinds = [
  ScheduleKind.registration,
  ScheduleKind.checkIn,
  ScheduleKind.match,
  ScheduleKind.results,
];
