import 'package:protournament_user/utils.dart';

/// Automation lifecycle: notification events, check-in and waitlist
/// (ChatGPT blueprint §5; backend guide §5-1/§5-2/§5-6).
///
/// Notification events (guide §5-6 `notification_log.kind`): exactly
/// the 10 events from the blueprint. [notificationContent] builds
/// the (title, body) for each from a `vars` map — pass
/// `{'tournament': name}` and, where relevant, `{'date': ...}`,
/// `{'time': ...}`, `{'position': ...}`.

/// The 10 auto-notification events (blueprint §5-6; guide §5-6).
enum NotificationEvent {
  registrationConfirmed,
  registrationClosing,
  checkInOpened,
  checkInMissed,
  matchReminder,
  roomPublished,
  resultSubmitted,
  disputeResolved,
  leaderboardPublished,
  tournamentCompleted;

  /// Server wire value (snake_case) for `notification_log.kind`.
  String get wireValue => name.replaceAllMapped(
      RegExp('[A-Z]'), (m) => '_${m.group(0)!.toLowerCase()}');

  static NotificationEvent? tryFromString(String? raw) {
    if (raw == null) return null;
    final norm = raw.toLowerCase().replaceAll(RegExp(r'[_\-\s]'), '');
    for (final e in NotificationEvent.values) {
      if (e.name.toLowerCase() == norm) return e;
    }
    return null;
  }
}

/// Title/body templates for a notification event, in EN/Roman Urdu.
/// `vars` supplies the tournament name (`vars['tournament']`) and,
/// where relevant, `date`, `time` or `rank`.
({String title, String body}) notificationContent(
    NotificationEvent event, Map<String, String> vars) {
  final t = vars['tournament'] ?? tr('the tournament', 'tournament');
  final date = vars['date'] ?? '';
  final time = vars['time'] ?? '';
  final rank = vars['rank'] ?? '';
  return switch (event) {
    NotificationEvent.registrationConfirmed => (
        title: tr('Registration confirmed', 'Registration confirm ho gayi'),
        body: tr('You are registered for $t.',
            'Aap $t ke liye register ho gaye hain.'),
      ),
    NotificationEvent.registrationClosing => (
        title: tr('Registration closing soon', 'Registration band ho rahi hai'),
        body: tr('Registration for $t closes soon. Register now before it ends.',
            '$t ki registration jald band ho rahi hai. Khatam hone se pehle register karen.'),
      ),
    NotificationEvent.checkInOpened => (
        title: tr('Check-in is open', 'Check-in khul gaya hai'),
        body: tr('Check-in for $t is open. Captains, please check in now.',
            '$t ka check-in khul gaya hai. Captains, abhi check-in karen.'),
      ),
    NotificationEvent.checkInMissed => (
        title: tr('Check-in missed', 'Check-in miss ho gaya'),
        body: tr('Your team missed check-in for $t. Your slot may go to the waitlist.',
            'Aap ki team ka $t ka check-in miss ho gaya. Aap ki slot waitlist ko mil sakti hai.'),
      ),
    NotificationEvent.matchReminder => (
        title: tr('Match reminder', 'Match ki yaad dehani'),
        body: tr('Your match in $t starts at $time $date. Be ready.',
            '$t mein aap ka match $time $date shuru ho raha hai. Tayyar rahen.'),
      ),
    NotificationEvent.roomPublished => (
        title: tr('Room details published', 'Room details aa gayi hain'),
        body: tr('Room ID and password for $t are now available in the app.',
            '$t ka room ID aur password ab app mein maujood hai.'),
      ),
    NotificationEvent.resultSubmitted => (
        title: tr('Result submitted', 'Result jama ho gaya'),
        body: tr('A result for $t was submitted and is waiting for verification.',
            '$t ka result jama ho gaya hai aur verification ka intezar hai.'),
      ),
    NotificationEvent.disputeResolved => (
        title: tr('Dispute resolved', 'Dispute hal ho gaya'),
        body: tr('Your dispute in $t has been resolved. Check the details in the app.',
            '$t mein aap ka dispute hal ho gaya hai. Tafseel app mein dekhen.'),
      ),
    NotificationEvent.leaderboardPublished => (
        title: tr('Leaderboard published', 'Leaderboard publish ho gaya'),
        body: tr('The leaderboard for $t is live. Your rank: $rank.',
            '$t ka leaderboard live hai. Aap ki rank: $rank.'),
      ),
    NotificationEvent.tournamentCompleted => (
        title: tr('Tournament completed', 'Tournament mukammal ho gaya'),
        body: tr('$t is complete. Thank you for playing!',
            '$t mukammal ho gaya hai. Khelne ka shukriya!'),
      ),
  };
}

/// The check-in WINDOW for a tournament/match (guide §5-2:
/// `open_check_in` / `close_check_in` RPCs set the window on the
/// tournament). This is the window state — per-team state is
/// [CheckInStatus].
enum CheckInWindow {
  notOpened,
  open,
  closed;

  String get label => switch (this) {
        CheckInWindow.notOpened => tr('Check-in not open yet', 'Check-in abhi khula nahi'),
        CheckInWindow.open => tr('Check-in open', 'Check-in khula hai'),
        CheckInWindow.closed => tr('Check-in closed', 'Check-in band hai'),
      };

  static CheckInWindow fromString(String? raw,
          [CheckInWindow fallback = CheckInWindow.notOpened]) {
    final n = (raw ?? '').toLowerCase().replaceAll(RegExp(r'[_\-\s]'), '');
    for (final w in CheckInWindow.values) {
      if (w.name.toLowerCase() == n) return w;
    }
    return fallback;
  }
}

/// Per-team check-in outcome (guide §5-2 `check_ins.status`:
/// `checked_in` / `absent` / `late`).
///
/// NOTE: there is no `missed` / `no_show` value here — a team that
/// never checks in is `absent`, and no-show handling (waitlist
/// promotion + exception report) lives in the exceptions flow
/// (guide §5-2 `close_check_in` writes an exception report row).
enum CheckInStatus {
  checkedIn,
  absent,
  late;

  String get label => switch (this) {
        CheckInStatus.checkedIn => tr('Checked in', 'Check-in ho gaya'),
        CheckInStatus.absent => tr('Absent', 'Absent'),
        CheckInStatus.late => tr('Late', 'Late'),
      };

  /// Server wire value (guide §5-2).
  String get wireValue => switch (this) {
        CheckInStatus.checkedIn => 'checked_in',
        CheckInStatus.absent => 'absent',
        CheckInStatus.late => 'late',
      };

  static CheckInStatus fromString(String? raw,
          [CheckInStatus fallback = CheckInStatus.absent]) {
    final n = (raw ?? '').toLowerCase().replaceAll(RegExp(r'[_\-\s]'), '');
    for (final s in CheckInStatus.values) {
      if (s.name.toLowerCase() == n) return s;
    }
    return fallback;
  }
}

/// Waitlist entry state (guide §5-1 `waitlist_entries.status`).
enum WaitlistStatus {
  waiting,
  promoted,
  expired;

  String get label => switch (this) {
        WaitlistStatus.waiting => tr('Waiting', 'Wait kar rahe hain'),
        WaitlistStatus.promoted => tr('Promoted', 'Slot mil gaya'),
        WaitlistStatus.expired => tr('Expired', 'Khatam ho gaya'),
      };

  String get wireValue => name;

  static WaitlistStatus fromString(String? raw,
          [WaitlistStatus fallback = WaitlistStatus.waiting]) {
    final n = (raw ?? '').toLowerCase().replaceAll(RegExp(r'[_\-\s]'), '');
    for (final s in WaitlistStatus.values) {
      if (s.name.toLowerCase() == n) return s;
    }
    return fallback;
  }
}
