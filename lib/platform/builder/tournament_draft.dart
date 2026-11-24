import 'package:protournament_user/platform/core/scoring.dart';
import 'package:protournament_user/platform/core/tournament_enums.dart';

import 'schedule_kind.dart';

/// The Smart Tournament Builder draft — ALL 7 sections of the
/// ChatGPT blueprint §3 in one object (backend guide §3).
///
/// [toMap] / [fromMap] use the guide's snake_case column names, so
/// the map can be sent straight to Supabase once the backend batch
/// lands the columns. Until then the draft is the local record:
/// the publish path (see smart_builder_page.dart) writes ONLY the
/// columns verified to exist today and keeps the rest here.
///
/// Two keys are LOCAL-ONLY (not guide columns) and are marked as
/// such in [toMap]: `id` (the local draft id) and `server_id` (the
/// `tournaments` row id once published — null until then).
///
/// MAPPING NOTE — `elimination` (guide §3-B): the server has ONE
/// `elimination` column holding single / double / round_robin /
/// swiss / cumulative, but the app splits it into TWO fields —
/// [EliminationType] (knockout brackets: single / double) and
/// [MatchFormat] (round robin / swiss / cumulative points). MERGE
/// RULE: when [format] is knockout, [elimination] is authoritative
/// and its wire value is written; otherwise [matchFormat] is
/// authoritative. The non-authoritative side is NOT persisted (the
/// column holds exactly one value) and falls back to its default
/// ([EliminationType.single] / [MatchFormat.cumulativePoints]) on
/// [fromMap]. SPLIT RULE: a stored `single` / `double` restores
/// [elimination]; a stored `round_robin` / `swiss` / `cumulative`
/// restores [matchFormat].
///
/// MAPPING NOTE — registration (guide §3-C): the server splits
/// registration into TWO columns — `registration_type`
/// (individual / team) and `registrant` (captain / each_player) —
/// but the app has ONE [RegistrationMode]. MAPPING:
/// [RegistrationMode.individual] -> type `individual`,
/// registrant `each_player` (every player registers themselves);
/// [RegistrationMode.teamCaptain] -> type `team`, registrant
/// `captain`. [fromMap] reads `registration_type` first (`team`
/// -> teamCaptain, anything else -> individual) and falls back to
/// `registrant` (`captain` -> teamCaptain) when the type column is
/// absent. The server combination type `team` + registrant
/// `each_player` has no app-side mode and reads back as
/// `teamCaptain` (type wins); the builder never writes it.

String _str(dynamic v, [String fallback = '']) {
  if (v == null) return fallback;
  final s = v.toString();
  return s.isEmpty ? fallback : s;
}

bool _bool(dynamic v, [bool fallback = false]) {
  if (v is bool) return v;
  if (v is num) return v != 0;
  if (v is String) return v.toLowerCase() == 'true' || v == '1';
  return fallback;
}

int _int(dynamic v, [int fallback = 0]) {
  if (v is num) return v.toInt();
  return int.tryParse(v?.toString() ?? '') ?? fallback;
}

double _double(dynamic v, [double fallback = 0]) {
  if (v is num) return v.toDouble();
  return double.tryParse(v?.toString() ?? '') ?? fallback;
}

double? _doubleOrNull(dynamic v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  return double.tryParse(v.toString());
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

List<String> _strList(dynamic v) {
  if (v is List) {
    return v.map((e) => e.toString()).where((s) => s.isNotEmpty).toList();
  }
  return const [];
}

/// One schedule row (guide §3-E `tournament_schedule_items`).
/// Times are stored UTC; display converts to local / organizer
/// timezone at the UI layer.
class ScheduleItem {
  ScheduleKind kind;
  DateTime? startsAt;
  DateTime? endsAt;

  /// IANA timezone the organizer entered the time in (e.g.
  /// 'Asia/Karachi'); '' = the tournament's [TournamentDraft.timezone].
  String timezone;

  ScheduleItem({
    required this.kind,
    this.startsAt,
    this.endsAt,
    this.timezone = '',
  });

  factory ScheduleItem.fromMap(Map<String, dynamic> map) => ScheduleItem(
        kind: ScheduleKind.fromString(_str(map['kind'])),
        startsAt: _date(map['starts_at'] ?? map['startsAt']),
        endsAt: _date(map['ends_at'] ?? map['endsAt']),
        timezone: _str(map['timezone']),
      );

  /// Keys are the guide's `tournament_schedule_items` column names.
  Map<String, dynamic> toMap() => {
        'kind': kind.wireValue,
        'starts_at': _iso(startsAt),
        'ends_at': _iso(endsAt),
        'timezone': timezone,
      };

  ScheduleItem copy() => ScheduleItem(
        kind: kind,
        startsAt: startsAt,
        endsAt: endsAt,
        timezone: timezone,
      );
}

class TournamentDraft {
  /// Local draft id (LOCAL-ONLY key in [toMap], not a guide column).
  /// '' = a brand-new draft; the builder assigns
  /// `draft-<milliseconds>` when it first auto-saves.
  String id;

  /// `tournaments` row id once published (LOCAL-ONLY key
  /// `server_id` in [toMap]). Null until the first publish.
  String? serverId;

  /// 'draft' or 'published' (guide §3-G publish sets
  /// status='published'). The LIVE server write maps a new
  /// 'published' draft to 'pending' (admin approval queue) — see
  /// smart_builder_page.dart.
  String status;

  /// Owning organization (guide §4 `organization_id`). '' until
  /// the organizer's org is known.
  String organizationId;

  // ---- (A) Basic info ----
  String title;
  String logoUrl;
  String bannerUrl;
  String game;
  String description;
  String organizerName;
  String category;
  bool isPublic;
  TournamentVisibility visibility;
  String countryCode;
  List<String> allowedCountryCodes;
  String language;
  String timezone;
  String rules;
  String contactInfo;
  String supportInfo;

  /// Prize pool (Rs) — existing `tournaments.prize_pool` column;
  /// the publish checklist requires it to be present.
  double prizePool;

  /// Per-kill prize (Rs) — existing `tournaments.per_kill_prize`.
  double perKillPrize;

  // ---- (B) Competition config ----
  GameMode gameMode;
  Perspective perspective;
  TeamMode teamMode;
  List<String> mapPool;
  String serverRegion;
  int maxTeams;
  int substituteLimit;
  int matchCount;
  List<StageType> stages;
  TournamentFormat format;
  EliminationType elimination;
  MatchFormat matchFormat;

  // ---- (C) Registration config ----
  RegistrationMode registrationMode;
  DateTime? registrationStart;
  DateTime? registrationEnd;
  int minTeams;
  bool waitlistEnabled;
  bool verificationRequired;
  DateTime? rosterLockAt;
  String substitutePolicy;

  // ---- (D) Entry model ----
  EntryModel entryModel;
  double? entryFee;
  DateTime? paidApprovedAt;
  String? paidApprovedBy;

  // ---- (E) Schedule ----
  List<ScheduleItem> scheduleItems;

  // ---- (F) Rules & scoring ----
  String scoringTemplateId;
  ScoringTemplate scoringTemplate;
  String refundPolicy;
  String cancellationPolicy;
  String postponementPolicy;

  TournamentDraft({
    this.id = '',
    this.serverId,
    this.status = 'draft',
    this.organizationId = '',
    this.title = '',
    this.logoUrl = '',
    this.bannerUrl = '',
    this.game = 'PUBG Mobile',
    this.description = '',
    this.organizerName = '',
    this.category = '',
    this.isPublic = true,
    this.visibility = TournamentVisibility.worldwide,
    this.countryCode = 'PK',
    List<String>? allowedCountryCodes,
    this.language = 'en',
    this.timezone = 'Asia/Karachi',
    this.rules = '',
    this.contactInfo = '',
    this.supportInfo = '',
    this.prizePool = 0,
    this.perKillPrize = 0,
    this.gameMode = GameMode.classic,
    this.perspective = Perspective.tpp,
    this.teamMode = TeamMode.squad,
    List<String>? mapPool,
    this.serverRegion = '',
    this.maxTeams = 0,
    this.substituteLimit = 0,
    this.matchCount = 1,
    List<StageType>? stages,
    this.format = TournamentFormat.league,
    this.elimination = EliminationType.single,
    this.matchFormat = MatchFormat.cumulativePoints,
    this.registrationMode = RegistrationMode.individual,
    this.registrationStart,
    this.registrationEnd,
    this.minTeams = 0,
    this.waitlistEnabled = false,
    this.verificationRequired = false,
    this.rosterLockAt,
    this.substitutePolicy = '',
    this.entryModel = EntryModel.free,
    this.entryFee,
    this.paidApprovedAt,
    this.paidApprovedBy,
    List<ScheduleItem>? scheduleItems,
    this.scoringTemplateId = 'default',
    ScoringTemplate? scoringTemplate,
    this.refundPolicy = '',
    this.cancellationPolicy = '',
    this.postponementPolicy = '',
  })  : allowedCountryCodes = allowedCountryCodes ?? [],
        mapPool = mapPool ?? [],
        stages = stages ?? [],
        scheduleItems = scheduleItems ?? [],
        scoringTemplate = scoringTemplate ?? kDefaultScoringTemplate;

  // Publishability (no blocking validation issue) is exposed as
  // the `isPublishable` extension getter in builder_validation.dart,
  // so this model file stays free of a validation import cycle.

  /// First schedule item of [kind], or null when the draft has none.
  ScheduleItem? scheduleItem(ScheduleKind kind) {
    for (final item in scheduleItems) {
      if (item.kind == kind) return item;
    }
    return null;
  }

  /// Players per team for [teamMode] (solo 1 / duo 2 / squad 4).
  int get teamSize => switch (teamMode) {
        TeamMode.solo => 1,
        TeamMode.duo => 2,
        TeamMode.squad => 4,
      };

  /// Max players across all teams — the value written to the
  /// existing `tournaments.max_players` column at publish time.
  int get maxPlayers => maxTeams * teamSize;

  /// The single `elimination` wire value for this draft (see the
  /// class-level mapping note): knockout format -> the elimination
  /// type, anything else -> the match format.
  String get eliminationWireValue => format == TournamentFormat.knockout
      ? elimination.wireValue
      : matchFormat.wireValue;

  factory TournamentDraft.fromMap(Map<String, dynamic> map) {
    // Registration mapping (see the class-level note): type wins,
    // registrant is the fallback.
    final regType = _str(map['registration_type']);
    final registrant = _str(map['registrant']);
    final RegistrationMode regMode;
    if (regType.isNotEmpty) {
      regMode = regType.toLowerCase() == 'team'
          ? RegistrationMode.teamCaptain
          : RegistrationMode.individual;
    } else if (registrant.toLowerCase() == 'captain') {
      regMode = RegistrationMode.teamCaptain;
    } else {
      regMode = RegistrationMode.fromString(
          _str(map['registration_mode'] ?? map['registrationMode']));
    }

    // Elimination split (see the class-level note).
    final elimRaw = _str(map['elimination']).toLowerCase();
    final EliminationType elim;
    final MatchFormat matchFmt;
    if (elimRaw == 'single' || elimRaw == 'double') {
      elim = EliminationType.fromString(elimRaw);
      matchFmt = MatchFormat.cumulativePoints;
    } else if (elimRaw == 'round_robin' ||
        elimRaw == 'swiss' ||
        elimRaw == 'cumulative') {
      elim = EliminationType.single;
      matchFmt = MatchFormat.fromString(elimRaw);
    } else {
      elim = EliminationType.fromString(_str(map['elimination_type']));
      matchFmt = MatchFormat.fromString(_str(map['match_format']));
    }

    final stagesRaw = map['stages'];
    final stages = <StageType>[];
    if (stagesRaw is List) {
      for (final s in stagesRaw) {
        stages.add(StageType.fromString(s.toString()));
      }
    }

    final scheduleRaw = map['schedule_items'] ?? map['scheduleItems'];
    final scheduleItems = <ScheduleItem>[];
    if (scheduleRaw is List) {
      for (final item in scheduleRaw) {
        if (item is Map) {
          scheduleItems
              .add(ScheduleItem.fromMap(Map<String, dynamic>.from(item)));
        }
      }
    }

    final templateRaw = map['scoring_template'] ?? map['scoringTemplate'];
    final ScoringTemplate template;
    if (templateRaw is Map) {
      template =
          ScoringTemplate.fromMap(Map<String, dynamic>.from(templateRaw));
    } else {
      template = kDefaultScoringTemplate;
    }

    return TournamentDraft(
      id: _str(map['id']),
      serverId: _str(map['server_id']).isEmpty
          ? null
          : _str(map['server_id']),
      status: _str(map['status'], 'draft'),
      organizationId: _str(map['organization_id'] ?? map['organizationId']),
      title: _str(map['title'] ?? map['name']),
      logoUrl: _str(map['logo_url'] ?? map['logoUrl']),
      bannerUrl: _str(map['banner_url'] ?? map['bannerUrl']),
      game: _str(map['game'], 'PUBG Mobile'),
      description: _str(map['description']),
      organizerName:
          _str(map['organizer_name'] ?? map['organizerName']),
      category: _str(map['category']),
      isPublic: _bool(map['is_public'] ?? map['isPublic'], true),
      visibility: TournamentVisibility.fromString(
          _str(map['visibility'])),
      countryCode:
          _str(map['country_code'] ?? map['countryCode'], 'PK'),
      allowedCountryCodes: _strList(
          map['allowed_country_codes'] ?? map['allowedCountryCodes']),
      language: _str(map['language'], 'en'),
      timezone: _str(map['timezone'], 'Asia/Karachi'),
      rules: _str(map['rules']),
      contactInfo: _str(map['contact_info'] ?? map['contactInfo']),
      supportInfo: _str(map['support_info'] ?? map['supportInfo']),
      prizePool: _double(map['prize_pool'] ?? map['prizePool']),
      perKillPrize:
          _double(map['per_kill_prize'] ?? map['perKillPrize']),
      gameMode: GameMode.fromString(_str(map['game_mode'])),
      perspective: Perspective.fromString(_str(map['perspective'])),
      teamMode: TeamMode.fromString(_str(map['team_mode'])),
      mapPool: _strList(map['map_pool'] ?? map['mapPool']),
      serverRegion: _str(map['server_region'] ?? map['serverRegion']),
      maxTeams: _int(map['max_teams'] ?? map['maxTeams']),
      substituteLimit:
          _int(map['substitute_limit'] ?? map['substituteLimit']),
      matchCount: _int(map['match_count'] ?? map['matchCount'], 1),
      stages: stages,
      format: TournamentFormat.fromString(_str(map['format'])),
      elimination: elim,
      matchFormat: matchFmt,
      registrationMode: regMode,
      registrationStart:
          _date(map['registration_start'] ?? map['registrationStart']),
      registrationEnd:
          _date(map['registration_end'] ?? map['registrationEnd']),
      minTeams: _int(map['min_teams'] ?? map['minTeams']),
      waitlistEnabled:
          _bool(map['waitlist_enabled'] ?? map['waitlistEnabled']),
      verificationRequired: _bool(
          map['verification_required'] ?? map['verificationRequired']),
      rosterLockAt:
          _date(map['roster_lock_at'] ?? map['rosterLockAt']),
      substitutePolicy:
          _str(map['substitute_policy'] ?? map['substitutePolicy']),
      entryModel: EntryModel.fromString(_str(map['entry_model'])),
      entryFee: _doubleOrNull(map['entry_fee'] ?? map['entryFee']),
      paidApprovedAt:
          _date(map['paid_approved_at'] ?? map['paidApprovedAt']),
      paidApprovedBy: _str(map['paid_approved_by'] ??
              map['paidApprovedBy'])
          .isEmpty
          ? null
          : _str(map['paid_approved_by'] ?? map['paidApprovedBy']),
      scheduleItems: scheduleItems,
      scoringTemplateId: _str(
          map['scoring_template_id'] ?? map['scoringTemplateId'],
          'default'),
      scoringTemplate: template,
      refundPolicy: _str(map['refund_policy'] ?? map['refundPolicy']),
      cancellationPolicy: _str(
          map['cancellation_policy'] ?? map['cancellationPolicy']),
      postponementPolicy: _str(
          map['postponement_policy'] ?? map['postponementPolicy']),
    );
  }

  /// Keys are the guide's snake_case column names (§3-A…F), so this
  /// map can go straight to Supabase once the backend batch lands
  /// the columns. EXCEPTIONS (local-only, not guide columns):
  /// `id` (local draft id) and `server_id` (published row id).
  Map<String, dynamic> toMap() => {
        // Local-only keys (NOT guide columns).
        'id': id,
        'server_id': serverId,
        // Guide columns.
        'status': status,
        'organization_id': organizationId,
        'title': title,
        'logo_url': logoUrl,
        'banner_url': bannerUrl,
        'game': game,
        'description': description,
        'organizer_name': organizerName,
        'category': category,
        'is_public': isPublic,
        'visibility': visibility.wireValue,
        'country_code': countryCode,
        'allowed_country_codes': allowedCountryCodes,
        'language': language,
        'timezone': timezone,
        'rules': rules,
        'contact_info': contactInfo,
        'support_info': supportInfo,
        'prize_pool': prizePool,
        'per_kill_prize': perKillPrize,
        'game_mode': gameMode.wireValue,
        'perspective': perspective.wireValue,
        'team_mode': teamMode.wireValue,
        'map_pool': mapPool,
        'server_region': serverRegion,
        'max_teams': maxTeams,
        'substitute_limit': substituteLimit,
        'match_count': matchCount,
        'stages': stages.map((s) => s.wireValue).toList(),
        'format': format.wireValue,
        // One column, merged (see the class-level mapping note).
        'elimination': eliminationWireValue,
        // One app mode, split into two columns (see the note).
        'registration_type': registrationMode == RegistrationMode.teamCaptain
            ? 'team'
            : 'individual',
        'registrant': registrationMode == RegistrationMode.teamCaptain
            ? 'captain'
            : 'each_player',
        'registration_start': _iso(registrationStart),
        'registration_end': _iso(registrationEnd),
        'min_teams': minTeams,
        'waitlist_enabled': waitlistEnabled,
        'verification_required': verificationRequired,
        'roster_lock_at': _iso(rosterLockAt),
        'substitute_policy': substitutePolicy,
        'entry_model': entryModel.wireValue,
        'entry_fee': entryFee,
        'paid_approved_at': _iso(paidApprovedAt),
        'paid_approved_by': paidApprovedBy,
        'schedule_items': scheduleItems.map((s) => s.toMap()).toList(),
        'scoring_template_id': scoringTemplateId,
        'scoring_template': scoringTemplate.toMap(),
        'refund_policy': refundPolicy,
        'cancellation_policy': cancellationPolicy,
        'postponement_policy': postponementPolicy,
      };

  TournamentDraft copy() => TournamentDraft.fromMap(toMap());
}
