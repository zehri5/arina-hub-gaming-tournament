import 'package:protournament_user/platform/core/tournament_enums.dart';
import 'package:protournament_user/utils.dart';

import 'schedule_kind.dart';
import 'tournament_draft.dart';

/// Pre-publish validation for the Smart Tournament Builder —
/// the 9-point checklist from the backend guide §3-G (the server
/// RPC `validate_tournament_for_publish` is the server-side mirror
/// of this list; the app checks first so a bad draft never reaches
/// the server).
///
/// Pure functions: no I/O, no Supabase, no state.

class ValidationIssue {
  /// Draft field the issue belongs to (e.g. 'dates', 'mapPool',
  /// 'entryModel'). Used by the UI to jump to the right step.
  final String field;
  final String message;

  /// Blocking issues stop publish; non-blocking issues are
  /// warnings the organizer may accept.
  final bool blocking;

  const ValidationIssue({
    required this.field,
    required this.message,
    this.blocking = true,
  });
}

/// One row of the publish checklist shown on the wizard's last step.
class ChecklistItem {
  /// Stable key ('dates', 'maps', 'scoring', 'capacity', 'rules',
  /// 'schedule', 'region', 'prize', 'policies', 'paidApproval').
  final String key;
  final String label;
  final bool passed;

  const ChecklistItem({
    required this.key,
    required this.label,
    required this.passed,
  });
}

/// The 9-point pre-publish checklist (guide §3-G) plus the
/// approved-paid gate and the title check:
///
/// 1. dates sane — registration end after start, first match after
///    registration closes.
/// 2. maps set — at least one map in the pool.
/// 3. scoring template set — a template id and a non-empty
///    placement table.
/// 4. capacity set — maxTeams >= 2.
/// 5. rules present.
/// 6. schedule complete — all required kinds present (registration,
///    check-in, match, results); verification deadline +
///    leaderboard publish are non-blocking warnings when missing.
/// 7. region / server match — a server region is set when the
///    visibility is country-scoped, and selected-countries
///    visibility names at least one country.
/// 8. prize info present — prize pool > 0.
/// 9. policies — refund / cancellation / postponement policies are
///    non-empty when the entry model is approvedPaid.
/// + approved-paid gate — approvedPaid publish is BLOCKED unless
///   paidApprovedAt / paidApprovedBy are set ("Paid entry needs
///   Super Admin approval — contact support"); a paid entry model
///   also needs an entry fee > 0.
/// + title — a tournament cannot publish without a title.
List<ValidationIssue> validateForPublish(TournamentDraft d) {
  final issues = <ValidationIssue>[];

  // Title (not in the guide's 9 — a publish without a title is
  // still impossible).
  if (d.title.trim().isEmpty) {
    issues.add(ValidationIssue(
      field: 'title',
      message: tr('Title is missing.', 'Title nahi likha.'),
    ));
  }

  // 1. Dates sane.
  if (d.registrationStart == null || d.registrationEnd == null) {
    issues.add(ValidationIssue(
      field: 'dates',
      message: tr(
        'Registration window is not set.',
        'Registration ka waqt set nahi hai.',
      ),
    ));
  } else {
    if (!d.registrationEnd!.isAfter(d.registrationStart!)) {
      issues.add(ValidationIssue(
        field: 'dates',
        message: tr(
          'Registration must end after it starts.',
          'Registration khatam hone ka waqt shuru hone se baad hona chahiye.',
        ),
      ));
    }
    final match = d.scheduleItem(ScheduleKind.match);
    final matchStart = match?.startsAt;
    if (matchStart != null &&
        !matchStart.isAfter(d.registrationEnd!)) {
      issues.add(ValidationIssue(
        field: 'dates',
        message: tr(
          'The first match must start after registration closes.',
          'Pehla match registration band hone ke baad shuru hona chahiye.',
        ),
      ));
    }
  }

  // 2. Maps set.
  if (d.mapPool.isEmpty) {
    issues.add(ValidationIssue(
      field: 'mapPool',
      message: tr('No map selected.', 'Koi map select nahi hai.'),
    ));
  }

  // 3. Scoring template set.
  if (d.scoringTemplateId.trim().isEmpty ||
      d.scoringTemplate.placementPoints.isEmpty) {
    issues.add(ValidationIssue(
      field: 'scoring',
      message: tr(
        'Scoring template is not set.',
        'Scoring template set nahi hai.',
      ),
    ));
  }

  // 4. Capacity set.
  if (d.maxTeams < 2) {
    issues.add(ValidationIssue(
      field: 'maxTeams',
      message: tr(
        'Capacity is not set (at least 2 teams).',
        'Capacity set nahi hai (kam se kam 2 teams).',
      ),
    ));
  }

  // 5. Rules present.
  if (d.rules.trim().isEmpty) {
    issues.add(ValidationIssue(
      field: 'rules',
      message: tr('Rules are missing.', 'Rules nahi likhe.'),
    ));
  }

  // 6. Schedule complete.
  final presentKinds =
      d.scheduleItems.map((s) => s.kind).toSet();
  final missing = kRequiredScheduleKinds
      .where((k) => !presentKinds.contains(k))
      .toList();
  if (missing.isNotEmpty) {
    issues.add(ValidationIssue(
      field: 'schedule',
      message: tr(
        'Schedule is incomplete — missing: ${missing.map((k) => k.label).join(', ')}.',
        'Schedule adhura hai — missing: ${missing.map((k) => k.label).join(', ')}.',
      ),
    ));
  }
  for (final optional in [
    ScheduleKind.verificationDeadline,
    ScheduleKind.leaderboardPublish,
  ]) {
    if (!presentKinds.contains(optional)) {
      issues.add(ValidationIssue(
        field: 'schedule',
        message: tr(
          'Schedule has no ${optional.label.toLowerCase()} item (recommended).',
          'Schedule mein ${optional.label.toLowerCase()} nahi hai (behtar hai ke ho).',
        ),
        blocking: false,
      ));
    }
  }

  // 7. Region / server match.
  final countryScoped = d.visibility == TournamentVisibility.countryOnly ||
      d.visibility == TournamentVisibility.selectedCountries;
  if (countryScoped && d.serverRegion.trim().isEmpty) {
    issues.add(ValidationIssue(
      field: 'serverRegion',
      message: tr(
        'Server region is required for country-scoped tournaments.',
        'Country wale tournaments ke liye server region zaroori hai.',
      ),
    ));
  }
  if (d.visibility == TournamentVisibility.selectedCountries &&
      d.allowedCountryCodes.isEmpty) {
    issues.add(ValidationIssue(
      field: 'allowedCountryCodes',
      message: tr(
        'Selected-countries visibility needs at least one country.',
        'Selected countries ke liye kam se kam ek mulk chahiye.',
      ),
    ));
  }

  // 8. Prize info present.
  if (d.prizePool <= 0) {
    issues.add(ValidationIssue(
      field: 'prizePool',
      message: tr('Prize pool is not set.', 'Prize pool set nahi hai.'),
    ));
  }

  // 9. Policies + the approved-paid gate (guide §3-D / §4).
  if (d.entryModel == EntryModel.approvedPaid) {
    if (d.paidApprovedAt == null ||
        (d.paidApprovedBy ?? '').trim().isEmpty) {
      issues.add(ValidationIssue(
        field: 'entryModel',
        message: tr(
          'Paid entry needs Super Admin approval — contact support.',
          'Paid entry ke liye Super Admin ki approval chahiye — support se rabta karein.',
        ),
      ));
    }
    if ((d.entryFee ?? 0) <= 0) {
      issues.add(ValidationIssue(
        field: 'entryFee',
        message: tr(
          'Paid entry needs an entry fee above 0.',
          'Paid entry ke liye entry fee 0 se zyada honi chahiye.',
        ),
      ));
    }
    if (d.refundPolicy.trim().isEmpty) {
      issues.add(ValidationIssue(
        field: 'refundPolicy',
        message: tr(
          'Refund policy is required for paid entry.',
          'Paid entry ke liye refund policy zaroori hai.',
        ),
      ));
    }
    if (d.cancellationPolicy.trim().isEmpty) {
      issues.add(ValidationIssue(
        field: 'cancellationPolicy',
        message: tr(
          'Cancellation policy is required for paid entry.',
          'Paid entry ke liye cancellation policy zaroori hai.',
        ),
      ));
    }
    if (d.postponementPolicy.trim().isEmpty) {
      issues.add(ValidationIssue(
        field: 'postponementPolicy',
        message: tr(
          'Postponement policy is required for paid entry.',
          'Paid entry ke liye postponement policy zaroori hai.',
        ),
      ));
    }
  }

  return issues;
}

/// The 9 checklist rows for the wizard's Publish step, derived from
/// [validateForPublish]. A row passes when no BLOCKING issue names
/// its field(s). When the entry model is approvedPaid a 10th row
/// ('paidApproval') is appended for the Super Admin gate.
List<ChecklistItem> publishChecklist(TournamentDraft d) {
  final blocking =
      validateForPublish(d).where((i) => i.blocking).toList();
  bool fails(String field) => blocking.any((i) => i.field == field);
  bool failsAny(List<String> fields) =>
      fields.any((f) => blocking.any((i) => i.field == f));

  final items = <ChecklistItem>[
    ChecklistItem(
      key: 'dates',
      label: tr('Dates are sane', 'Dates theek hain'),
      passed: !fails('dates'),
    ),
    ChecklistItem(
      key: 'maps',
      label: tr('Maps set', 'Maps set hain'),
      passed: !fails('mapPool'),
    ),
    ChecklistItem(
      key: 'scoring',
      label: tr('Scoring template set', 'Scoring template set hai'),
      passed: !fails('scoring'),
    ),
    ChecklistItem(
      key: 'capacity',
      label: tr('Capacity set', 'Capacity set hai'),
      passed: !fails('maxTeams'),
    ),
    ChecklistItem(
      key: 'rules',
      label: tr('Rules present', 'Rules maujood hain'),
      passed: !fails('rules'),
    ),
    ChecklistItem(
      key: 'schedule',
      label: tr('Schedule complete', 'Schedule mukammal hai'),
      passed: !fails('schedule'),
    ),
    ChecklistItem(
      key: 'region',
      label: tr('Region / server match', 'Region / server match hai'),
      passed: !failsAny(['serverRegion', 'allowedCountryCodes']),
    ),
    ChecklistItem(
      key: 'prize',
      label: tr('Prize info present', 'Prize info maujood hai'),
      passed: !fails('prizePool'),
    ),
    ChecklistItem(
      key: 'policies',
      label: tr(
        'Refund / cancellation / postponement policies',
        'Refund / cancellation / postponement policies',
      ),
      passed: !failsAny(
          ['refundPolicy', 'cancellationPolicy', 'postponementPolicy']),
    ),
  ];
  if (d.entryModel == EntryModel.approvedPaid) {
    items.add(ChecklistItem(
      key: 'paidApproval',
      label: tr(
        'Paid entry approved by Super Admin',
        'Paid entry Super Admin se approved hai',
      ),
      passed: !fails('entryModel'),
    ));
  }
  return items;
}

/// True when [validateForPublish] reports no blocking issue.
/// (Extension, not a method on the model, so the model file stays
/// free of a validation import cycle.)
extension TournamentDraftPublishable on TournamentDraft {
  bool get isPublishable =>
      validateForPublish(this).where((i) => i.blocking).isEmpty;
}
