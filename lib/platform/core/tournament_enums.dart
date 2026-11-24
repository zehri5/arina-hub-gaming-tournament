import 'package:protournament_user/utils.dart';

/// Tournament enums for the Smart Tournament Builder (ChatGPT blueprint
/// §3; backend guide §3/§4 column values).
///
/// Every enum has:
/// * [label] — user-facing, via tr().
/// * `wireValue` — the exact string the backend guide stores
///   (snake_case; see the per-enum notes for the values that differ
///   from a plain snake_case of the Dart name).
/// * `fromString` — parses a stored value, accepting snake_case,
///   camelCase and the guide's aliases; unknown values fall back to
///   the documented default instead of throwing.
///
/// NOTE — `elimination` column (guide §3-B): the server stores
/// `single` / `double` / `round_robin` / `swiss` / `cumulative` in
/// ONE column. The app splits it into [EliminationType] (single/
/// double) and [MatchFormat] (round robin / swiss / cumulative
/// points); the builder workstream maps the two enums back onto the
/// one column. NOTE — registration (guide §3-C): the server splits
/// registration into TWO columns (`registration_type`:
/// individual/team, `registrant`: captain/each_player); the app's
/// single [RegistrationMode] covers the common cases and the builder
/// maps it onto both columns.

String _norm(String? raw) =>
    (raw ?? '').toLowerCase().replaceAll(RegExp(r'[_\-\s]'), '');

String _snake(String camel) => camel.replaceAllMapped(
    RegExp('[A-Z]'), (m) => '_${m.group(0)!.toLowerCase()}');

T _parse<T extends Enum>(List<T> values, String? raw, T fallback,
    [Map<String, T> aliases = const {}]) {
  final n = _norm(raw);
  if (n.isEmpty) return fallback;
  final aliased = aliases[n];
  if (aliased != null) return aliased;
  for (final v in values) {
    if (_norm(v.name) == n) return v;
  }
  return fallback;
}

/// Who can see / join the tournament (guide §2 `visibility`).
enum TournamentVisibility {
  worldwide,
  countryOnly,
  selectedCountries,
  privateInvite;

  String get label => switch (this) {
        TournamentVisibility.worldwide => tr('Worldwide', 'Duniya bhar'),
        TournamentVisibility.countryOnly =>
          tr('My country only', 'Sirf mera mulk'),
        TournamentVisibility.selectedCountries =>
          tr('Selected countries', 'Chune hue mumalik'),
        TournamentVisibility.privateInvite =>
          tr('Private (invite only)', 'Private (sirf invite)'),
      };

  String get wireValue => _snake(name);

  static TournamentVisibility fromString(String? raw,
          [TournamentVisibility fallback = TournamentVisibility.worldwide]) =>
      _parse(values, raw, fallback);
}

/// How entry is paid for (guide §3-D `entry_model`).
/// `approvedPaid` may only be set when a legal/payment approval flag
/// is on (guide §3-D) — the builder must refuse paid publish
/// without it. Commercial finance stays OFF until legal approval.
enum EntryModel {
  free,
  sponsored,
  organizerFunded,
  approvedPaid;

  String get label => switch (this) {
        EntryModel.free => tr('Free', 'Free'),
        EntryModel.sponsored => tr('Sponsored', 'Sponsored'),
        EntryModel.organizerFunded =>
          tr('Organizer funded', 'Organizer funded'),
        EntryModel.approvedPaid =>
          tr('Paid (approved)', 'Paid (approved)'),
      };

  String get wireValue => _snake(name);

  static EntryModel fromString(String? raw,
          [EntryModel fallback = EntryModel.free]) =>
      _parse(values, raw, fallback);
}

/// Payment state (guide §4 `payment_events.status`). IRON RULE from
/// the guide: `confirmed` ONLY from an authorized provider record —
/// never from a user-uploaded screenshot.
enum PaymentStatus {
  notRequired,
  pending,
  confirmed,
  failed,
  refunded,
  underReview;

  String get label => switch (this) {
        PaymentStatus.notRequired => tr('Not required', 'Zaroori nahi'),
        PaymentStatus.pending => tr('Pending', 'Pending'),
        PaymentStatus.confirmed => tr('Confirmed', 'Confirmed'),
        PaymentStatus.failed => tr('Failed', 'Fail ho gaya'),
        PaymentStatus.refunded => tr('Refunded', 'Refund ho gaya'),
        PaymentStatus.underReview => tr('Under review', 'Review mein hai'),
      };

  String get wireValue => _snake(name);

  static PaymentStatus fromString(String? raw,
          [PaymentStatus fallback = PaymentStatus.notRequired]) =>
      _parse(values, raw, fallback);
}

/// PUBG Mobile game mode (guide §3-B `game_mode`).
enum GameMode {
  classic,
  tdm;

  String get label => switch (this) {
        GameMode.classic => tr('Classic', 'Classic'),
        GameMode.tdm => tr('TDM', 'TDM'),
      };

  String get wireValue => name;

  static GameMode fromString(String? raw,
          [GameMode fallback = GameMode.classic]) =>
      _parse(values, raw, fallback);
}

/// Camera perspective (guide §3-B `perspective`).
enum Perspective {
  tpp,
  fpp;

  String get label => switch (this) {
        Perspective.tpp => tr('TPP', 'TPP'),
        Perspective.fpp => tr('FPP', 'FPP'),
      };

  String get wireValue => name;

  static Perspective fromString(String? raw,
          [Perspective fallback = Perspective.tpp]) =>
      _parse(values, raw, fallback);
}

/// Team size (guide §3-B `team_mode`).
enum TeamMode {
  solo,
  duo,
  squad;

  String get label => switch (this) {
        TeamMode.solo => tr('Solo', 'Solo'),
        TeamMode.duo => tr('Duo', 'Duo'),
        TeamMode.squad => tr('Squad', 'Squad'),
      };

  String get wireValue => name;

  static TeamMode fromString(String? raw,
          [TeamMode fallback = TeamMode.squad]) =>
      _parse(values, raw, fallback);
}

/// Tournament structure (guide §3-B `format`).
enum TournamentFormat {
  league,
  groups,
  knockout,
  custom;

  String get label => switch (this) {
        TournamentFormat.league => tr('League', 'League'),
        TournamentFormat.groups => tr('Groups', 'Groups'),
        TournamentFormat.knockout => tr('Knockout', 'Knockout'),
        TournamentFormat.custom => tr('Custom', 'Custom'),
      };

  String get wireValue => name;

  static TournamentFormat fromString(String? raw,
          [TournamentFormat fallback = TournamentFormat.league]) =>
      _parse(values, raw, fallback);
}

/// Knockout elimination (guide §3-B `elimination`: single/double).
/// Round robin / Swiss / cumulative live in [MatchFormat].
enum EliminationType {
  single,
  double;

  String get label => switch (this) {
        EliminationType.single => tr('Single elimination', 'Single elimination'),
        EliminationType.double => tr('Double elimination', 'Double elimination'),
      };

  String get wireValue => name;

  static EliminationType fromString(String? raw,
          [EliminationType fallback = EliminationType.single]) =>
      _parse(values, raw, fallback);
}

/// Tournament stage (guide §3-B `stages` jsonb).
enum StageType {
  qualifier,
  semifinal,
  finalStage;

  String get label => switch (this) {
        StageType.qualifier => tr('Qualifier', 'Qualifier'),
        StageType.semifinal => tr('Semi-final', 'Semi-final'),
        StageType.finalStage => tr('Final', 'Final'),
      };

  /// `final` is a Dart keyword, so the Dart value is `finalStage`
  /// but the wire value is the guide's `final`.
  String get wireValue =>
      this == StageType.finalStage ? 'final' : name;

  static StageType fromString(String? raw,
          [StageType fallback = StageType.qualifier]) =>
      _parse(values, raw, fallback, {'final': StageType.finalStage});
}

/// How matches are played / points accumulate (guide §3-B
/// `elimination` column values `round_robin` / `swiss` /
/// `cumulative` — see the file header note).
enum MatchFormat {
  roundRobin,
  swiss,
  cumulativePoints;

  String get label => switch (this) {
        MatchFormat.roundRobin => tr('Round robin', 'Round robin'),
        MatchFormat.swiss => tr('Swiss', 'Swiss'),
        MatchFormat.cumulativePoints =>
          tr('Cumulative points', 'Cumulative points'),
      };

  /// Guide wire value is `cumulative`, not `cumulative_points`.
  String get wireValue => this == MatchFormat.cumulativePoints
      ? 'cumulative'
      : _snake(name);

  static MatchFormat fromString(String? raw,
          [MatchFormat fallback = MatchFormat.cumulativePoints]) =>
      _parse(values, raw, fallback,
          {'cumulative': MatchFormat.cumulativePoints});
}

/// Who registers (guide §3-C: `registration_type` individual/team +
/// `registrant` captain/each_player — see the file header note).
enum RegistrationMode {
  individual,
  teamCaptain;

  String get label => switch (this) {
        RegistrationMode.individual =>
          tr('Individual', 'Individual'),
        RegistrationMode.teamCaptain =>
          tr('Team (captain registers)', 'Team (captain register kare)'),
      };

  String get wireValue => _snake(name);

  static RegistrationMode fromString(String? raw,
          [RegistrationMode fallback = RegistrationMode.individual]) =>
      _parse(values, raw, fallback, {
        'team': RegistrationMode.teamCaptain,
        'captain': RegistrationMode.teamCaptain,
        'eachplayer': RegistrationMode.individual,
      });
}

/// How teams are placed into matches (guide §5-3
/// `match_teams.allocation_method`: random / seeded / country /
/// performance / manual).
enum TeamAllocationMode {
  random,
  seeded,
  countryBased,
  performanceBased,
  manual;

  String get label => switch (this) {
        TeamAllocationMode.random => tr('Random', 'Random'),
        TeamAllocationMode.seeded => tr('Seeded', 'Seeded'),
        TeamAllocationMode.countryBased => tr('Country based', 'Mulk ke hisaab se'),
        TeamAllocationMode.performanceBased =>
          tr('Performance based', 'Performance ke hisaab se'),
        TeamAllocationMode.manual => tr('Manual', 'Manual'),
      };

  /// Guide wire values are `country` / `performance` (not
  /// `country_based` / `performance_based`).
  String get wireValue => switch (this) {
        TeamAllocationMode.countryBased => 'country',
        TeamAllocationMode.performanceBased => 'performance',
        _ => name,
      };

  static TeamAllocationMode fromString(String? raw,
          [TeamAllocationMode fallback = TeamAllocationMode.random]) =>
      _parse(values, raw, fallback, {
        'country': TeamAllocationMode.countryBased,
        'performance': TeamAllocationMode.performanceBased,
      });
}
