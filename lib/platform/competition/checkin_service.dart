import 'package:protournament_user/platform/competition/waitlist_service.dart';
import 'package:protournament_user/platform/core/exceptions.dart';
import 'package:protournament_user/platform/core/lifecycle.dart';
import 'package:protournament_user/platform/core/local_store.dart';
import 'package:protournament_user/utils.dart';

/// Smart check-in (ChatGPT blueprint §5-2; backend guide §5-2
/// `check_ins` table + `open_check_in` / `close_check_in` RPCs).
///
/// INTERIM — LOCAL STORE ONLY: until the backend `check_ins` table
/// and the `open_check_in` / `close_check_in` RPCs land, window and
/// entry state live in [PlatformLocalStore] under area `checkin`
/// (`platform.checkin.window.<tournamentId>` and
/// `platform.checkin.entries.<tournamentId>`). The exception report
/// produced by [closeCheckIn] is also stored locally
/// (`platform.checkin.exceptions.<tournamentId>`) — the backend
/// `exception_reports` table is its eventual home.
///
/// NO-SHOW RULE (Sameer, DECISIONS-2026-11-20.md §2): 10-minute
/// grace, then the entry fee is FORFEIT — no refund. A no-show is
/// an absence, NOT cheating: exception items use kind `other`, never
/// `cheating` / `misconduct`.

/// Grace period in minutes (DECISIONS §2: the 5–10 minute range's
/// upper end). Named with the `CheckIn` prefix so it can never
/// collide with the runbook's `kNoShowGraceMinutes`.
const int kCheckInNoShowGraceMinutes = 10;

/// The no-show rule, stated plainly for players and admins.
/// Shown on the check-in page and attached to every no-show
/// exception item.
String get kNoShowRuleText => tr(
      'No-show rule: if your captain does not check in within 10 minutes of the match time, the match is delayed up to 10 minutes. After that your team is marked absent and the entry fee is forfeited — no refund.',
      'No-show rule: agar aap ka captain match time ke 10 minute ke andar check-in nahi karta, to match 10 minute tak delay hoga. Us ke baad team absent ho jayegi aur entry fee wapas NAHI hogi — koi refund nahi.',
    );

/// One per-team check-in record (guide §5-2 `check_ins` row).
class CheckInEntry {
  final String teamId;
  final String captainUid;
  final CheckInStatus status;
  final DateTime? checkedInAt;

  const CheckInEntry({
    required this.teamId,
    this.captainUid = '',
    required this.status,
    this.checkedInAt,
  });

  factory CheckInEntry.fromMap(Map<String, dynamic> map) => CheckInEntry(
        teamId: (map['team_id'] ?? map['teamId'] ?? '').toString(),
        captainUid:
            (map['captain_uid'] ?? map['captainUid'] ?? '').toString(),
        status: CheckInStatus.fromString((map['status'] ?? '').toString()),
        checkedInAt: map['checked_in_at'] == null
            ? null
            : DateTime.tryParse(map['checked_in_at'].toString()),
      );

  Map<String, dynamic> toMap() => {
        'team_id': teamId,
        'captain_uid': captainUid,
        'status': status.wireValue,
        'checked_in_at': checkedInAt?.toUtc().toIso8601String(),
      };
}

/// Result of [CheckInService.closeCheckIn]: which teams were
/// absent, which waitlist entries were promoted into the freed
/// slots, and the exception report (one [ActionItem] per no-show).
class CheckInCloseResult {
  final List<String> absentTeamIds;
  final List<WaitlistEntry> promoted;
  final List<ActionItem> exceptions;
  final CheckInWindow window;

  const CheckInCloseResult({
    required this.absentTeamIds,
    required this.promoted,
    required this.exceptions,
    this.window = CheckInWindow.closed,
  });
}

class CheckInService {
  static const String _area = 'checkin';

  final WaitlistService _waitlist;

  CheckInService({WaitlistService? waitlist})
      : _waitlist = waitlist ?? const WaitlistService();

  String _windowId(String tournamentId) => 'window:$tournamentId';
  String _entriesId(String tournamentId) => 'entries:$tournamentId';
  String _exceptionsId(String tournamentId) => 'exceptions:$tournamentId';

  Future<Map<String, dynamic>?> _loadWindow(String tournamentId) =>
      PlatformLocalStore.loadDraft(_area, _windowId(tournamentId));

  Future<List<CheckInEntry>> _loadEntries(String tournamentId) async {
    final rows =
        await PlatformLocalStore.loadList(_area, _entriesId(tournamentId));
    return rows.map(CheckInEntry.fromMap).toList();
  }

  Future<void> _saveEntries(
      String tournamentId, List<CheckInEntry> entries) async {
    await PlatformLocalStore.saveList(
        _area, _entriesId(tournamentId), entries.map((e) => e.toMap()).toList());
  }

  Future<void> _saveWindow(String tournamentId, CheckInWindow window,
      {DateTime? deadline}) async {
    await PlatformLocalStore.saveDraft(_area, _windowId(tournamentId), {
      'state': window.name,
      if (deadline != null) 'deadline': deadline.toUtc().toIso8601String(),
    });
  }

  /// Opens the check-in window with a deadline. Mirrors the backend
  /// `open_check_in` RPC (sets `check_in_open_at` /
  /// `check_in_deadline` on the tournament).
  Future<bool> openWindow(String tournamentId, DateTime deadline) async {
    return PlatformLocalStore.saveDraft(_area, _windowId(tournamentId), {
      'state': CheckInWindow.open.name,
      'deadline': deadline.toUtc().toIso8601String(),
      'opened_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  /// Closes the check-in window (no more check-ins). Does NOT mark
  /// absences — that is [closeCheckIn]'s job.
  Future<bool> closeWindow(String tournamentId) async {
    final current = await _loadWindow(tournamentId);
    final deadline = current?['deadline'];
    return PlatformLocalStore.saveDraft(_area, _windowId(tournamentId), {
      'state': CheckInWindow.closed.name,
      if (deadline != null) 'deadline': deadline,
      'closed_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  /// Stored window state (notOpened / open / closed).
  Future<CheckInWindow> getWindow(String tournamentId) async {
    final data = await _loadWindow(tournamentId);
    return CheckInWindow.fromString(data?['state']?.toString());
  }

  /// The check-in deadline, or null when the window was never opened.
  Future<DateTime?> getDeadline(String tournamentId) async {
    final data = await _loadWindow(tournamentId);
    final raw = data?['deadline'];
    if (raw == null) return null;
    return DateTime.tryParse(raw.toString());
  }

  /// True only while the window is stored open AND the deadline has
  /// not passed. A window left open past its deadline counts as
  /// closed for check-in purposes.
  Future<bool> isWindowOpen(String tournamentId, {DateTime? now}) async {
    final data = await _loadWindow(tournamentId);
    if (data == null) return false;
    if (CheckInWindow.fromString(data['state']?.toString()) !=
        CheckInWindow.open) {
      return false;
    }
    final deadline = await getDeadline(tournamentId);
    if (deadline != null && (now ?? DateTime.now()).isAfter(deadline)) {
      return false;
    }
    return true;
  }

  /// Captain check-in. Records `checkedIn` — ONLY while the window
  /// is open. Returns null on success, or an error string when the
  /// window is not open (never opened / closed / deadline passed).
  /// Re-checking an already checked-in team is a no-op success.
  Future<String?> captainCheckIn(
      String tournamentId, String teamId, String captainUid,
      {DateTime? now}) async {
    if (!await isWindowOpen(tournamentId, now: now)) {
      final window = await getWindow(tournamentId);
      if (window == CheckInWindow.notOpened) {
        return tr('Check-in has not opened yet.',
            'Check-in abhi khula nahi hai.');
      }
      return tr('Check-in is closed. The deadline has passed.',
          'Check-in band ho gaya hai. Deadline guzar gayi hai.');
    }
    final entries = await _loadEntries(tournamentId);
    for (final e in entries) {
      if (e.teamId == teamId && e.status == CheckInStatus.checkedIn) {
        return null; // Already checked in — idempotent success.
      }
    }
    entries.removeWhere((e) => e.teamId == teamId);
    entries.add(CheckInEntry(
      teamId: teamId,
      captainUid: captainUid,
      status: CheckInStatus.checkedIn,
      checkedInAt: (now ?? DateTime.now()).toUtc(),
    ));
    await _saveEntries(tournamentId, entries);
    return null;
  }

  /// Marks a team `late` (captain arrived after the deadline but
  /// the admin still admits them). Allowed regardless of window
  /// state — it is an admin action, not a player check-in.
  Future<void> markLate(
      String tournamentId, String teamId, String captainUid) async {
    final entries = await _loadEntries(tournamentId);
    entries.removeWhere((e) => e.teamId == teamId);
    entries.add(CheckInEntry(
      teamId: teamId,
      captainUid: captainUid,
      status: CheckInStatus.late,
      checkedInAt: DateTime.now().toUtc(),
    ));
    await _saveEntries(tournamentId, entries);
  }

  /// All check-in entries for the tournament.
  Future<List<CheckInEntry>> getEntries(String tournamentId) =>
      _loadEntries(tournamentId);

  /// This team's entry, or null when the team has no record yet.
  Future<CheckInEntry?> getEntryFor(
      String tournamentId, String teamId) async {
    final entries = await _loadEntries(tournamentId);
    for (final e in entries) {
      if (e.teamId == teamId) return e;
    }
    return null;
  }

  /// The exception report from the last [closeCheckIn] (stored
  /// locally; the backend `exception_reports` table is its
  /// eventual home).
  Future<List<ActionItem>> getExceptions(String tournamentId) async {
    final rows = await PlatformLocalStore.loadList(
        _area, _exceptionsId(tournamentId));
    return rows.map(ActionItem.fromMap).toList();
  }

  /// Closes check-in (mirrors the backend `close_check_in` RPC):
  /// every expected team whose captain did not check in (and was
  /// not marked late) is marked `absent`; waitlist entries are
  /// promoted in order to fill the freed slots (one per absent
  /// team); the window locks to `closed`; and an exception report
  /// is produced — one [ActionItem] per no-show team, kind `other`
  /// (a no-show is an absence, NOT cheating), with the forfeit rule
  /// in the detail.
  Future<CheckInCloseResult> closeCheckIn(
      String tournamentId, List<String> expectedTeamIds) async {
    final entries = await _loadEntries(tournamentId);
    final present = <String>{};
    for (final e in entries) {
      if (e.status == CheckInStatus.checkedIn ||
          e.status == CheckInStatus.late) {
        present.add(e.teamId);
      }
    }
    final absent =
        expectedTeamIds.where((t) => !present.contains(t)).toList();

    // Mark the missing captains absent.
    for (final teamId in absent) {
      entries.removeWhere((e) => e.teamId == teamId);
      entries.add(CheckInEntry(
        teamId: teamId,
        status: CheckInStatus.absent,
      ));
    }
    await _saveEntries(tournamentId, entries);

    // Promote waitlist entries in order, one per freed slot.
    final promoted = <WaitlistEntry>[];
    for (var i = 0; i < absent.length; i++) {
      final next = await _waitlist.promoteNext(tournamentId);
      if (next == null) break;
      promoted.add(next);
    }

    // Exception report — one item per no-show team.
    final now = DateTime.now().toUtc();
    final exceptions = absent
        .map((teamId) => ActionItem(
              id: 'noshow:$tournamentId:$teamId:${now.millisecondsSinceEpoch}',
              type: ExceptionType.other,
              title: tr('No-show: team did not check in',
                  'No-show: team ne check-in nahi kiya'),
              detail:
                  'No-show: captain did not check in. $kNoShowRuleText',
              tournamentId: tournamentId,
              targetUid: teamId,
              status: DisputeStatus.open,
              createdAt: now,
            ))
        .toList();
    final previous = await getExceptions(tournamentId);
    await PlatformLocalStore.saveList(_area, _exceptionsId(tournamentId),
        [...previous, ...exceptions].map((e) => e.toMap()).toList());

    // Lock the window.
    await _saveWindow(tournamentId, CheckInWindow.closed,
        deadline: await getDeadline(tournamentId));

    return CheckInCloseResult(
      absentTeamIds: absent,
      promoted: promoted,
      exceptions: exceptions,
    );
  }
}
