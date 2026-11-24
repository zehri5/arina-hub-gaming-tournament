import 'package:protournament_user/utils.dart';

/// Rules-change impact warning (backend guide §3-F): when a
/// scoring template or the schedule changes AFTER a tournament has
/// registrations / verified results, the organizer must see what
/// happens to the existing data BEFORE saving.
///
/// Pure function: no I/O, no state.
///
/// Returns '' when nothing is affected — i.e. when there are no
/// registrations and no verified results, or when neither scoring
/// nor the schedule changed. Otherwise returns a short paragraph
/// plus a bullet list of what changes and what stays untouched.
///
/// Server rule this text mirrors (guide §3-F): the backend must
/// NOT silently rewrite already-verified results — scoring changes
/// apply to future matches only.
String rulesChangeImpact({
  required int registrationCount,
  required int verifiedResultsCount,
  required bool scoringChanged,
  required bool scheduleChanged,
}) {
  if (registrationCount <= 0 && verifiedResultsCount <= 0) return '';
  if (!scoringChanged && !scheduleChanged) return '';

  final lines = <String>[];
  lines.add(tr(
    'This tournament already has $registrationCount registration(s)'
    '${verifiedResultsCount > 0 ? ' and $verifiedResultsCount verified result(s)' : ''}. '
    'Changing the rules now affects them:',
    'Is tournament mein pehle se $registrationCount registration(s) hain'
    '${verifiedResultsCount > 0 ? ' aur $verifiedResultsCount verified result(s) hain' : ''}. '
    'Ab rules badalne se in par asar parega:',
  ));
  if (scoringChanged) {
    lines.add(tr(
      'Scoring changes apply to future matches only.',
      'Scoring ki tabdeeli sirf aane wale matches par lagegi.',
    ));
    if (verifiedResultsCount > 0) {
      lines.add(tr(
        '$verifiedResultsCount verified result(s) will NOT be rescored — they keep the points they were given.',
        '$verifiedResultsCount verified result(s) dobara score NAHI honge — un ke points wahi rahenge.',
      ));
    }
    lines.add(tr(
      'Registered teams will see the new scoring table.',
      'Registered teams ko nayi scoring table nazar aayegi.',
    ));
  }
  if (scheduleChanged) {
    lines.add(tr(
      'Schedule changes apply to matches that have not started yet.',
      'Schedule ki tabdeeli sirf un matches par lagegi jo abhi shuru nahi hue.',
    ));
    if (registrationCount > 0) {
      lines.add(tr(
        'Tell the $registrationCount registered team(s) about the new times.',
        '$registrationCount registered team(s) ko naye waqt ke baare mein bata dein.',
      ));
    }
  }

  final buffer = StringBuffer(lines.first);
  for (final line in lines.skip(1)) {
    buffer.write('\n• $line');
  }
  return buffer.toString();
}
