import 'package:protournament_user/utils.dart';

/// Exception management / Action Required Center (ChatGPT blueprint
/// §5-7; backend guide §5-7 `disputes` + `exception_reports` tables).
///
/// `disputes.kind` has exactly 8 values (guide §5-7) and
/// `disputes.status` exactly 4 — there is NO `escalated` status;
/// the existing `Flagged` dispute state maps to `open`.

String _norm(String? raw) =>
    (raw ?? '').toLowerCase().replaceAll(RegExp(r'[_\-\s]'), '');

DateTime? _date(dynamic v) {
  if (v == null) return null;
  if (v is DateTime) return v;
  if (v is num) {
    final ms = v.toDouble().abs() < 100000000000
        ? (v.toDouble() * 1000).round()
        : v.toDouble().round();
    return DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
  }
  return DateTime.tryParse(v.toString());
}

String? _iso(DateTime? d) => d?.toUtc().toIso8601String();

/// How urgently an exception needs a human.
enum ExceptionSeverity {
  high,
  medium,
  low;

  String get label => switch (this) {
        ExceptionSeverity.high => tr('High', 'High'),
        ExceptionSeverity.medium => tr('Medium', 'Medium'),
        ExceptionSeverity.low => tr('Low', 'Low'),
      };
}

/// The 8 dispute/exception kinds (guide §5-7 `disputes.kind`).
enum ExceptionType {
  cheating,
  fakeEvidence,
  wrongScore,
  serverIssue,
  misconduct,
  cancellation,
  disqualification,
  other;

  String get label => switch (this) {
        ExceptionType.cheating => tr('Cheating', 'Cheating'),
        ExceptionType.fakeEvidence => tr('Fake evidence', 'Jhoota saboot'),
        ExceptionType.wrongScore => tr('Wrong score', 'Ghalat score'),
        ExceptionType.serverIssue => tr('Server issue', 'Server masla'),
        ExceptionType.misconduct => tr('Misconduct', 'Bad-tameezi'),
        ExceptionType.cancellation => tr('Cancellation', 'Cancellation'),
        ExceptionType.disqualification =>
          tr('Disqualification', 'Disqualification'),
        ExceptionType.other => tr('Other', 'Doosra'),
      };

  /// Server wire value (guide §5-7, snake_case).
  String get wireValue => name.replaceAllMapped(
      RegExp('[A-Z]'), (m) => '_${m.group(0)!.toLowerCase()}');

  /// Triage severity. Cheating / fake evidence / misconduct /
  /// disqualification need a human first; server issues and wrong
  /// scores are usually data fixes; cancellations and `other` are
  /// lowest priority.
  ExceptionSeverity get severity => switch (this) {
        ExceptionType.cheating => ExceptionSeverity.high,
        ExceptionType.fakeEvidence => ExceptionSeverity.high,
        ExceptionType.misconduct => ExceptionSeverity.high,
        ExceptionType.disqualification => ExceptionSeverity.high,
        ExceptionType.wrongScore => ExceptionSeverity.medium,
        ExceptionType.serverIssue => ExceptionSeverity.medium,
        ExceptionType.cancellation => ExceptionSeverity.low,
        ExceptionType.other => ExceptionSeverity.low,
      };

  static ExceptionType fromString(String? raw,
          [ExceptionType fallback = ExceptionType.other]) {
    final n = _norm(raw);
    for (final t in ExceptionType.values) {
      if (_norm(t.name) == n) return t;
    }
    return fallback;
  }
}

/// Dispute lifecycle (guide §5-7 `disputes.status`): exactly these
/// four values. No `escalated` — an unresolved dispute stays `open`
/// or `under_review`.
enum DisputeStatus {
  open,
  underReview,
  resolved,
  rejected;

  String get label => switch (this) {
        DisputeStatus.open => tr('Open', 'Khula hua'),
        DisputeStatus.underReview => tr('Under review', 'Review mein hai'),
        DisputeStatus.resolved => tr('Resolved', 'Hal ho gaya'),
        DisputeStatus.rejected => tr('Rejected', 'Reject ho gaya'),
      };

  /// Server wire value (guide §5-7).
  String get wireValue => this == DisputeStatus.underReview
      ? 'under_review'
      : name;

  static DisputeStatus fromString(String? raw,
          [DisputeStatus fallback = DisputeStatus.open]) {
    final n = _norm(raw);
    for (final s in DisputeStatus.values) {
      if (_norm(s.name) == n) return s;
    }
    return fallback;
  }
}

/// One item in the Action Required Center — a dispute or an
/// auto-generated exception (check-in close, scoring anomaly,
/// no-show). Maps loosely onto the guide's `disputes` table
/// (`kind`/`status`) and `exception_reports` table; the backend
/// tables carry extra columns (`match_id`, `evidence_urls`,
/// `resolution`, `reported_by`) that later workstreams can add here
/// when the dispute screens need them.
class ActionItem {
  final String id;
  final ExceptionType type;
  final String title;
  final String detail;
  final String tournamentId;

  /// Firebase UID of the reported player/team captain (nullable in
  /// practice — system-generated exceptions may have no target).
  final String targetUid;
  final DisputeStatus status;
  final DateTime? createdAt;
  final DateTime? resolvedAt;

  const ActionItem({
    required this.id,
    required this.type,
    this.title = '',
    this.detail = '',
    this.tournamentId = '',
    this.targetUid = '',
    this.status = DisputeStatus.open,
    this.createdAt,
    this.resolvedAt,
  });

  factory ActionItem.fromMap(Map<String, dynamic> map) => ActionItem(
        id: (map['id'] ?? '').toString(),
        type: ExceptionType.fromString(
            (map['kind'] ?? map['type'] ?? '').toString()),
        title: (map['title'] ?? '').toString(),
        detail: (map['detail'] ?? '').toString(),
        tournamentId:
            (map['tournament_id'] ?? map['tournamentId'] ?? '').toString(),
        targetUid: (map['target_uid'] ?? map['targetUid'] ?? '').toString(),
        status: DisputeStatus.fromString((map['status'] ?? '').toString()),
        createdAt: _date(map['created_at'] ?? map['createdAt']),
        resolvedAt: _date(map['resolved_at'] ?? map['resolvedAt']),
      );

  /// Keys follow the guide's `disputes` naming (`kind`,
  /// `tournament_id`, `created_at`, `resolved_at`).
  Map<String, dynamic> toMap() => {
        'id': id,
        'kind': type.wireValue,
        'title': title,
        'detail': detail,
        'tournament_id': tournamentId,
        'target_uid': targetUid,
        'status': status.wireValue,
        'created_at': _iso(createdAt),
        'resolved_at': _iso(resolvedAt),
      };
}
