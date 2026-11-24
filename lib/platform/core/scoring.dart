import 'package:protournament_user/utils.dart';

/// Scoring templates, points math, leaderboard scopes and seasons
/// (ChatGPT blueprint §5-5/§6; backend guide §3-F `scoring_templates`,
/// §5-5 `calculate_match_score`, §6 `leaderboard_snapshots` /
/// `seasons`).
///
/// ⚠️ SCORING — READ THIS (10-vs-15 conflict, unresolved at the
/// server): the DECIDED model (Sameer 2026-11-21 02:20) is
/// placement 1st = 10, 2nd = 7, 3rd = 5, 4th and below = 0, plus
/// 1 point per kill — and that is the DEFAULT template here
/// ([kDefaultScoringTemplate]). BUT the LIVE server migration 022
/// (`record_match_result`, verified by reading the file) credits
/// 1st = 15 — its CASE is
/// {1:15, 2:12, 3:10, 4:8, 5:6, 6:4, 7:2, 8:2} + 1/kill, so
/// 1st + 12 kills = 27 on the server today vs 22 under the decided
/// model. The old table is kept as [kLegacy022ScoringTemplate] so
/// already-credited points can still be reproduced. THE BACKEND
/// MUST UPDATE 022 to the decided 10/7/5 model for app/server
/// agreement — that is a backend-handoff item, NOT fixed here.
/// Do not "fix" the server from the app side.
///
/// Scoring is ultimately SERVER-side (guide §5-5, developer
/// requirement #5: never trust client-calculated points).
/// [calculateMatchPoints] is the app's mirror of the server formula
/// for previews and offline display only.

int _int(dynamic v, [int fallback = 0]) {
  if (v is num) return v.toInt();
  return int.tryParse(v?.toString() ?? '') ?? fallback;
}

double _double(dynamic v, [double fallback = 1.0]) {
  if (v is num) return v.toDouble();
  return double.tryParse(v?.toString() ?? '') ?? fallback;
}

List<String> _strList(dynamic v) {
  if (v is List) return v.map((e) => e.toString()).toList();
  return const [];
}

Map<int, int> _placementMap(dynamic v) {
  final out = <int, int>{};
  if (v is Map) {
    for (final entry in v.entries) {
      final place = int.tryParse(entry.key.toString());
      if (place != null) out[place] = _int(entry.value);
    }
  }
  return out;
}

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

String _norm(String? raw) =>
    (raw ?? '').toLowerCase().replaceAll(RegExp(r'[_\-\s]'), '');

/// A points configuration (guide §3-F `scoring_templates` table).
class ScoringTemplate {
  final String id;

  /// Owning organization; null = platform template (guide §3-F).
  final String? organizationId;
  final String name;

  /// Placement -> points, e.g. {1: 10, 2: 7, 3: 5}. Placements not
  /// listed score 0.
  final Map<int, int> placementPoints;

  /// Points per kill (default 1 everywhere).
  final int killPoints;
  final List<String> bonusRules;
  final List<String> penalties;
  final List<String> tieBreakers;
  final List<String> disqualifyOn;

  /// True when the table follows the official-style placement
  /// shape (guide §3-F `is_official_style`).
  final bool isOfficialStyle;

  const ScoringTemplate({
    required this.id,
    this.organizationId,
    required this.name,
    this.placementPoints = const {},
    this.killPoints = 1,
    this.bonusRules = const [],
    this.penalties = const [],
    this.tieBreakers = const [],
    this.disqualifyOn = const [],
    this.isOfficialStyle = false,
  });

  factory ScoringTemplate.fromMap(Map<String, dynamic> map) =>
      ScoringTemplate(
        id: (map['id'] ?? '').toString(),
        organizationId: map['organization_id']?.toString(),
        name: (map['name'] ?? '').toString(),
        placementPoints:
            _placementMap(map['placement_points'] ?? map['placementPoints']),
        killPoints: _int(map['kill_points'] ?? map['killPoints'], 1),
        bonusRules: _strList(map['bonus_rules'] ?? map['bonusRules']),
        penalties: _strList(map['penalties']),
        tieBreakers: _strList(map['tiebreakers'] ?? map['tieBreakers']),
        disqualifyOn:
            _strList(map['disqualify_on'] ?? map['disqualifyOn']),
        isOfficialStyle: map['is_official_style'] == true ||
            map['isOfficialStyle'] == true,
      );

  /// Keys are the guide's `scoring_templates` column names.
  /// Placement keys are strings (JSON-safe).
  Map<String, dynamic> toMap() => {
        'id': id,
        'organization_id': organizationId,
        'name': name,
        'placement_points':
            placementPoints.map((k, v) => MapEntry(k.toString(), v)),
        'kill_points': killPoints,
        'bonus_rules': bonusRules,
        'penalties': penalties,
        'tiebreakers': tieBreakers,
        'disqualify_on': disqualifyOn,
        'is_official_style': isOfficialStyle,
      };
}

/// THE DECIDED MODEL (Sameer 2026-11-21 02:20): 1st = 10, 2nd = 7,
/// 3rd = 5, 4th and below = 0, + 1 per kill. Default for
/// [calculateMatchPoints]. 1st + 12 kills = 22. (Supersedes the
/// earlier 1st=10/2nd=6/3rd=5/4th=4 table.) The admin can override
/// these values from the admin panel without a new build — see
/// [ScoringTemplateStore.loadEffectiveTemplate] (platform/scoring).
const ScoringTemplate kDefaultScoringTemplate = ScoringTemplate(
  id: 'default',
  name: 'Official Style',
  placementPoints: {1: 10, 2: 7, 3: 5},
  killPoints: 1,
  tieBreakers: ['Most kills', 'Most damage'],
  isOfficialStyle: true,
);

/// The LIVE server table from migration 022 `record_match_result`
/// (verified by reading the file): {1:15, 2:12, 3:10, 4:8, 5:6, 6:4,
/// 7:2, 8:2} + 1/kill. 1st + 12 kills = 27. Kept ONLY so the app can
/// still reproduce points the server already credited. Do NOT use it
/// for new tournaments — the backend must update 022 to the decided
/// 1st=10 model (see the file header).
const ScoringTemplate kLegacy022ScoringTemplate = ScoringTemplate(
  id: 'legacy-022',
  name: 'Legacy Server (022)',
  placementPoints: {1: 15, 2: 12, 3: 10, 4: 8, 5: 6, 6: 4, 7: 2, 8: 2},
  killPoints: 1,
  isOfficialStyle: false,
);

/// Empty starting point for a custom template.
const ScoringTemplate kCustomScoringTemplate = ScoringTemplate(
  id: 'custom',
  name: 'Custom',
  placementPoints: {},
  killPoints: 1,
);

/// Pure points math: placement points from [template] + 1 point per
/// kill (times [template.killPoints]).
///
/// * placement <= 0 -> 0 (no result).
/// * kills < 0 -> treated as 0 (placement points only).
/// * placement not in the table (9th+) -> 0 placement points.
int calculateMatchPoints({
  required int placement,
  required int kills,
  ScoringTemplate template = kDefaultScoringTemplate,
}) {
  if (placement <= 0) return 0;
  final safeKills = kills < 0 ? 0 : kills;
  final placementPoints = template.placementPoints[placement] ?? 0;
  return placementPoints + safeKills * template.killPoints;
}

/// The five ranking systems (blueprint §6; guide §6
/// `leaderboard_snapshots.scope`).
enum LeaderboardScope {
  match,
  tournament,
  season,
  country,
  global;

  String get label => switch (this) {
        LeaderboardScope.match => tr('Match', 'Match'),
        LeaderboardScope.tournament => tr('Tournament', 'Tournament'),
        LeaderboardScope.season => tr('Season', 'Season'),
        LeaderboardScope.country => tr('Country', 'Mulk'),
        LeaderboardScope.global => tr('Global', 'Global'),
      };

  String get wireValue => name;

  static LeaderboardScope fromString(String? raw,
          [LeaderboardScope fallback = LeaderboardScope.tournament]) {
    final n = _norm(raw);
    for (final s in LeaderboardScope.values) {
      if (_norm(s.name) == n) return s;
    }
    return fallback;
  }
}

/// Season lifecycle (guide §6 `seasons.status`).
enum SeasonStatus {
  upcoming,
  active,
  completed;

  String get label => switch (this) {
        SeasonStatus.upcoming => tr('Upcoming', 'Aane wala'),
        SeasonStatus.active => tr('Active', 'Active'),
        SeasonStatus.completed => tr('Completed', 'Mukammal'),
      };

  static SeasonStatus fromString(String? raw,
          [SeasonStatus fallback = SeasonStatus.upcoming]) {
    final n = _norm(raw);
    for (final s in SeasonStatus.values) {
      if (_norm(s.name) == n) return s;
    }
    return fallback;
  }
}

/// A ranked season (guide §6 `seasons` table).
///
/// NOTE on [weighting]: the guide stores it as a jsonb CONFIG
/// (default 1.0) because no weighting formula exists in the
/// blueprint (guide §7 gap #7 — a Sameer decision). The app model
/// keeps the simple number form (default 1.0); [fromMap] reads a
/// plain number and ignores a richer config object.
class Season {
  final String id;

  /// Owning organization; null = platform season (guide §6).
  final String? organizationId;
  final String name;
  final DateTime? startsAt;
  final DateTime? endsAt;
  final SeasonStatus status;
  final double weighting;

  const Season({
    required this.id,
    this.organizationId,
    required this.name,
    this.startsAt,
    this.endsAt,
    this.status = SeasonStatus.upcoming,
    this.weighting = 1.0,
  });

  factory Season.fromMap(Map<String, dynamic> map) => Season(
        id: (map['id'] ?? '').toString(),
        organizationId: map['organization_id']?.toString(),
        name: (map['name'] ?? '').toString(),
        startsAt: _date(map['starts_at'] ?? map['startsAt']),
        endsAt: _date(map['ends_at'] ?? map['endsAt']),
        status: SeasonStatus.fromString((map['status'] ?? '').toString()),
        weighting: _double(map['weighting'], 1.0),
      );

  /// Keys are the guide's `seasons` column names.
  Map<String, dynamic> toMap() => {
        'id': id,
        'organization_id': organizationId,
        'name': name,
        'starts_at': _iso(startsAt),
        'ends_at': _iso(endsAt),
        'status': status.name,
        'weighting': weighting,
      };
}
