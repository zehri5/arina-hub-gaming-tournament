import 'package:flutter/material.dart';
import 'package:protournament_user/platform/core/scoring.dart';
import 'package:protournament_user/platform/disputes/dispute_service.dart';
import 'package:protournament_user/platform/scoring/scoring_display.dart';
import 'package:protournament_user/platform/scoring/scoring_template_store.dart';
import 'package:protournament_user/services/admin_db_people.dart';
import 'package:protournament_user/services/supabase_db.dart';
import 'package:protournament_user/utils.dart';

/// 5-scope leaderboards (ChatGPT blueprint §6; backend guide §6
/// `leaderboard_snapshots` / `seasons` / `rebuild_leaderboard`).
///
/// Tabs: Match / Tournament / Season / Country / Global
/// ([LeaderboardScope]). Every ranking shows rank, name, points,
/// kills, matches and previous-rank movement, plus a transparency
/// footer on EVERY ranking: last updated, verified/provisional,
/// calculation method, dispute-open indicator.
///
/// DATA — READ THIS: the backend `leaderboard_snapshots` table
/// does NOT exist yet (guide §6, backend work), so every ranking
/// here is computed LOCALLY from APPROVED + VERIFIED results
/// (`tournament_results` status `approved` or `verified` — the
/// same query [SupaDb.recomputeLeaderboard] uses, extended for
/// verified rows so 054-scored results do not vanish) via
/// [calculateMatchPoints] — except 'verified' rows, whose stored
/// `team_points` (written by 054) is used as-is — and marked
/// Provisional. Only verified results count (guide §5-5). When
/// snapshots land, this page reads them instead and the badge
/// flips to Verified — the footer already says which source a
/// ranking came from.
///
/// SCOPE HONESTY:
/// * Match / Tournament: in the live data model one result row
///   exists per (tournament, player), so a "match" ranking and a
///   "tournament" ranking coincide until multi-match tournaments
///   exist (backend `match_teams`, guide §5-3). The Match tab
///   shows one tournament (constructor `tournamentId`, else the
///   latest with approved results); the Tournament tab adds a
///   tournament picker.
/// * Season: the `seasons` table does not exist yet, so results
///   cannot be filtered by season — the tab aggregates all
///   approved results and the footer says season snapshots are
///   pending.
/// * Country: `profiles.country_code` does not exist yet (guide
///   §2), so results cannot be filtered by country — the tab
///   aggregates all approved results and the footer says so.
/// * Scores are NEVER mixed across game modes in one ranking:
///   each tab is its own scope, computed from its own filtered
///   result set.
///
/// Previous rank: the Global tab uses the stored
/// `profiles.leaderboard_rank` (written by recomputeLeaderboard
/// at the last approval) as the previous rank, so movement
/// (up/down/same) is real there. Other scopes have no previous
/// snapshot yet, so movement shows '–'.
class ScopedLeaderboardPage extends StatefulWidget {
  final String? tournamentId;
  final String? seasonId;

  /// Reserved for future country filtering (backend
  /// profiles.country_code) — the Country tab cannot filter yet,
  /// so this is accepted but not used for filtering today.
  final String? countryCode;

  /// #16: which tab opens first. [TournamentLeaderboardPage]
  /// passes `tournament` so a tournament link lands directly on
  /// its ranking instead of the Match tab.
  final LeaderboardScope initialScope;

  const ScopedLeaderboardPage(
      {super.key,
      this.tournamentId,
      this.seasonId,
      this.countryCode,
      this.initialScope = LeaderboardScope.match});

  @override
  State<ScopedLeaderboardPage> createState() => _ScopedLeaderboardPageState();
}

/// #16 — tournament-scoped leaderboard WITHOUT more_screens.dart.
/// A thin wrapper over [ScopedLeaderboardPage]: opens directly on
/// the Tournament tab for [tournamentId] (tournament-scoped
/// ranking from APPROVED + VERIFIED tournament_results, locked
/// template 1st=10 / 2nd=7 / 3rd=5 + 1/kill — see
/// [aggregateResults]). [tournamentName] is accepted for call
/// sites that already have it; the page resolves the live name
/// itself when it is null. Use this from tournament screens
/// instead of the global LeaderboardPage (more_screens.dart),
/// which has no tournamentId param.
class TournamentLeaderboardPage extends StatelessWidget {
  final String tournamentId;
  final String? tournamentName;
  const TournamentLeaderboardPage(
      {super.key, required this.tournamentId, this.tournamentName});

  @override
  Widget build(BuildContext context) => ScopedLeaderboardPage(
        tournamentId: tournamentId,
        initialScope: LeaderboardScope.tournament,
      );
}

/// One ranked row. Pure data — see [rankEntries] for how [rank]
/// is assigned (equal points share a rank).
class LeaderboardEntry {
  final String uid;
  final String name;
  final int points;
  final int kills;
  final int matches;
  final int rank;

  /// Total damage across the aggregated results — the second
  /// tiebreaker after kills (the decided template lists 'Most
  /// damage'; rankEntries applies it).
  final int damage;

  /// Rank in the previous snapshot, or null when no previous
  /// snapshot exists (movement then shows '–').
  final int? previousRank;

  /// True when an open dispute touches this player's result.
  final bool disputeOpen;

  const LeaderboardEntry({
    required this.uid,
    required this.name,
    required this.points,
    required this.kills,
    required this.matches,
    this.rank = 0,
    this.damage = 0,
    this.previousRank,
    this.disputeOpen = false,
  });

  /// Movement vs the previous rank: 1 = moved up, -1 = moved
  /// down, 0 = same rank or no previous rank.
  int get movement {
    if (previousRank == null || rank <= 0) return 0;
    if (previousRank! > rank) return 1;
    if (previousRank! < rank) return -1;
    return 0;
  }

  LeaderboardEntry copyWith({
    String? uid,
    String? name,
    int? points,
    int? kills,
    int? matches,
    int? rank,
    int? damage,
    int? previousRank,
    bool? disputeOpen,
  }) =>
      LeaderboardEntry(
        uid: uid ?? this.uid,
        name: name ?? this.name,
        points: points ?? this.points,
        kills: kills ?? this.kills,
        matches: matches ?? this.matches,
        rank: rank ?? this.rank,
        damage: damage ?? this.damage,
        previousRank: previousRank ?? this.previousRank,
        disputeOpen: disputeOpen ?? this.disputeOpen,
      );
}

/// A complete ranking for one scope, with the transparency data
/// the footer renders (guide §6: last updated, verified/
/// provisional, calculation method, dispute status).
class LeaderboardRanking {
  final LeaderboardScope scope;
  final String scopeLabel;
  final List<LeaderboardEntry> entries;
  final DateTime lastUpdated;
  final bool verified;
  final String method;
  final bool disputeOpen;

  /// Optional honest note (e.g. why a scope cannot be filtered
  /// yet). Rendered in the footer when non-empty.
  final String note;

  const LeaderboardRanking({
    required this.scope,
    required this.scopeLabel,
    required this.entries,
    required this.lastUpdated,
    required this.verified,
    required this.method,
    this.disputeOpen = false,
    this.note = '',
  });
}

/// The calculation-method string for the decided template
/// (blueprint §6 transparency: which template + formula version).
String leaderboardMethodString(
        [ScoringTemplate template = kDefaultScoringTemplate]) =>
    '${template.name} — ${tr('placement', 'placement')} + '
    '${template.killPoints}/${tr('kill', 'kill')}';

/// Aggregates APPROVED result rows into one unranked entry per
/// player (points via [calculateMatchPoints], kills, damage and
/// match counts summed). Pure — unit-tested.
///
/// [names] maps firebase_uid -> display name; [flaggedKeys] holds
/// 'tournamentId|firebaseUid' keys with an open dispute (from
/// [AdminDbPeople.getFlaggedResultKeys]).
///
/// P1-10 / #16: a row with status 'verified' was scored by the
/// server (054 calculate_match_score) — its stored `team_points`
/// is authoritative and is used as-is, even when it differs from
/// the client-computed value (template edits, overrides). An
/// 'approved' row uses the computed value: P1-10 writes the same
/// decided-table points at approve time, and rows approved before
/// that change still carry the stored 0, so computing is the
/// honest value for them.
List<LeaderboardEntry> aggregateResults(
  List<Map<String, dynamic>> approvedResults, {
  Map<String, String> names = const {},
  Set<String> flaggedKeys = const {},
  ScoringTemplate template = kDefaultScoringTemplate,
}) {
  final points = <String, int>{};
  final kills = <String, int>{};
  final damage = <String, int>{};
  final matches = <String, int>{};
  final flagged = <String>{};
  for (final r in approvedResults) {
    final uid = SupaDb.strOf(r['firebase_uid']);
    if (uid.isEmpty) continue;
    final k = SupaDb.intOf(r['kills'], 0);
    final isVerified =
        SupaDb.strOf(r['status']).toLowerCase() == 'verified';
    points[uid] = (points[uid] ?? 0) +
        (isVerified
            ? SupaDb.intOf(r['team_points'], 0)
            : calculateMatchPoints(
                placement: SupaDb.intOf(r['placement'], 0),
                kills: k,
                template: template));
    kills[uid] = (kills[uid] ?? 0) + k;
    damage[uid] =
        (damage[uid] ?? 0) + SupaDb.intOf(r['damage'], 0);
    matches[uid] = (matches[uid] ?? 0) + 1;
    final key =
        '${SupaDb.strOf(r['tournament_id'])}|${SupaDb.strOf(r['firebase_uid'])}';
    if (flaggedKeys.contains(key)) flagged.add(uid);
  }
  return points.entries
      .map((e) => LeaderboardEntry(
            uid: e.key,
            name: names[e.key] ?? e.key,
            points: e.value,
            kills: kills[e.key] ?? 0,
            matches: matches[e.key] ?? 0,
            damage: damage[e.key] ?? 0,
            disputeOpen: flagged.contains(e.key),
          ))
      .toList();
}

/// Filters APPROVED result rows by game + period — the shared
/// filter step for the user leaderboard's filter sheet and the
/// admin leaderboard's filtered view. Pure — unit-tested.
///
/// [gameByTournament] maps tournament_id -> game_id (from
/// [SupaDb.getTournaments]); rows whose tournament is unknown
/// are dropped when a game is picked (never silently kept).
/// [period]: 'all' | 'week' (last 7 days) | 'month' (last 30
/// days), cut on the result's created_at. Unknown period values
/// behave as 'all'.
List<Map<String, dynamic>> filterApprovedResults(
  List<Map<String, dynamic>> approvedResults, {
  required Map<String, String> gameByTournament,
  String? gameId,
  String period = 'all',
  required int nowMs,
}) {
  final cutoff = period == 'week'
      ? nowMs - 7 * 24 * 3600 * 1000
      : period == 'month'
          ? nowMs - 30 * 24 * 3600 * 1000
          : 0;
  return approvedResults.where((r) {
    if (gameId != null &&
        gameByTournament[SupaDb.strOf(r['tournament_id'])] != gameId) {
      return false;
    }
    if (cutoff > 0 && SupaDb.parseTs(r['created_at']) < cutoff) {
      return false;
    }
    return true;
  }).toList();
}

/// Sorts entries (points desc; ties by kills desc, then damage
/// desc — the decided template's tiebreakers — then name) and
/// assigns competition ranks: equal points SHARE a rank and the
/// next distinct rank skips (1, 1, 3) — the same rule
/// [SupaDb.recomputeLeaderboard] uses. Pure — unit-tested.
List<LeaderboardEntry> rankEntries(List<LeaderboardEntry> entries) {
  final sorted = List<LeaderboardEntry>.from(entries)
    ..sort((a, b) {
      final byPoints = b.points.compareTo(a.points);
      if (byPoints != 0) return byPoints;
      final byKills = b.kills.compareTo(a.kills);
      if (byKills != 0) return byKills;
      final byDamage = b.damage.compareTo(a.damage);
      if (byDamage != 0) return byDamage;
      return a.name.compareTo(b.name);
    });
  final out = <LeaderboardEntry>[];
  var rank = 0;
  var lastPoints = -1;
  for (var i = 0; i < sorted.length; i++) {
    final e = sorted[i];
    if (e.points != lastPoints) {
      rank = i + 1;
      lastPoints = e.points;
    }
    out.add(e.copyWith(rank: rank));
  }
  return out;
}

class _ScopedLeaderboardPageState extends State<ScopedLeaderboardPage> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _approved = [];
  List<Map<String, dynamic>> _tournaments = [];
  Map<String, String> _names = {};
  Set<String> _flaggedKeys = {};
  Map<String, int> _storedRanks = {};
  Set<String> _openDisputeTournaments = {};
  String? _tournamentPick;
  // Effective scoring template (admin override when saved, else the
  // decided 10/7/5) — loaded in _load, passed to aggregateResults.
  ScoringTemplate _template = kDefaultScoringTemplate;

  @override
  void initState() {
    super.initState();
    _tournamentPick = widget.tournamentId;
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // #16: approved AND verified rows. 054 flips a scored result
      // to 'verified' — reading only 'approved' would drop every
      // scored result off the board. Both statuses carry real
      // points (approved: P1-10 writes them at approve time;
      // verified: 054 wrote them); aggregateResults picks the
      // right source per row.
      final approved = await SupaDb.getList('tournament_results',
          eqCol: 'status', eqVal: 'approved', limit: 1000);
      final verified = await SupaDb.getList('tournament_results',
          eqCol: 'status', eqVal: 'verified', limit: 1000);
      final allResults = [...approved, ...verified];
      final tournaments = await SupaDb.getTournaments();
      final names = await AdminDbPeople.getProfileNames();
      final flagged = await AdminDbPeople.getFlaggedResultKeys();
      final stored = await SupaDb.getLeaderboard();
      final openDisputes = await DisputeService().listOpenExceptions();
      final template = await ScoringTemplateStore.loadEffectiveTemplate();
      if (!mounted) return;
      setState(() {
        _approved = allResults;
        _tournaments = tournaments;
        _names = names;
        _flaggedKeys = flagged;
        _storedRanks = {
          for (final p in stored)
            SupaDb.strOf(p['firebase_uid']):
                SupaDb.intOf(p['leaderboard_rank'], 0)
        }..removeWhere((uid, rank) => uid.isEmpty || rank <= 0);
        _openDisputeTournaments = openDisputes
            .map((d) => d.tournamentId)
            .where((t) => t.isNotEmpty)
            .toSet();
        _template = template;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error =
            tr('Could not load leaderboards: $e', 'Leaderboard load nahi hua: $e');
        _loading = false;
      });
    }
  }

  String _tournamentName(String id) {
    for (final t in _tournaments) {
      if (SupaDb.strOf(t['id']) == id) return SupaDb.strOf(t['name'], 'Tournament');
    }
    return tr('Tournament', 'Tournament');
  }

  /// Tournament ids that have at least one approved result.
  List<String> get _tournamentIdsWithResults {
    final ids = <String>{};
    for (final r in _approved) {
      final id = SupaDb.strOf(r['tournament_id']);
      if (id.isNotEmpty) ids.add(id);
    }
    return ids.toList();
  }

  /// The most recently active tournament (by latest approved
  /// result) — the default when no tournamentId was passed in.
  String? get _latestTournamentId {
    String? best;
    var bestTs = -1;
    for (final r in _approved) {
      final ts = SupaDb.parseTs(r['created_at']);
      if (ts > bestTs) {
        bestTs = ts;
        best = SupaDb.strOf(r['tournament_id']);
      }
    }
    return best;
  }

  bool _scopeHasOpenDispute(Iterable<String> tournamentIds) {
    for (final id in tournamentIds) {
      if (_openDisputeTournaments.contains(id)) return true;
    }
    return false;
  }

  LeaderboardRanking _rankingFor(LeaderboardScope scope) {
    final now = DateTime.now();
    final method = leaderboardMethodString(_template);
    switch (scope) {
      case LeaderboardScope.match:
        final tid = widget.tournamentId ?? _latestTournamentId;
        final rows = tid == null
            ? <Map<String, dynamic>>[]
            : _approved
                .where((r) => SupaDb.strOf(r['tournament_id']) == tid)
                .toList();
        return LeaderboardRanking(
          scope: scope,
          scopeLabel: tid == null
              ? tr('Match', 'Match')
              : _tournamentName(tid),
          entries: rankEntries(aggregateResults(rows,
              names: _names, flaggedKeys: _flaggedKeys, template: _template)),
          lastUpdated: now,
          verified: false,
          method: method,
          disputeOpen:
              tid != null && _scopeHasOpenDispute([tid]),
          note: tr(
              'Match ranking is computed locally from approved + verified results. Server snapshots are not live yet.',
              'Match ranking approved + verified results se locally banayi gayi hai. Server snapshots abhi live nahi hain.'),
        );
      case LeaderboardScope.tournament:
        final tid = _tournamentPick ?? _latestTournamentId;
        final rows = tid == null
            ? <Map<String, dynamic>>[]
            : _approved
                .where((r) => SupaDb.strOf(r['tournament_id']) == tid)
                .toList();
        return LeaderboardRanking(
          scope: scope,
          scopeLabel: tid == null
              ? tr('Tournament', 'Tournament')
              : _tournamentName(tid),
          entries: rankEntries(aggregateResults(rows,
              names: _names, flaggedKeys: _flaggedKeys, template: _template)),
          lastUpdated: now,
          verified: false,
          method: method,
          disputeOpen:
              tid != null && _scopeHasOpenDispute([tid]),
          note: tr(
              'Tournament ranking is computed locally from approved + verified results. Server snapshots are not live yet.',
              'Tournament ranking approved + verified results se locally banayi gayi hai. Server snapshots abhi live nahi hain.'),
        );
      case LeaderboardScope.season:
        return LeaderboardRanking(
          scope: scope,
          scopeLabel: widget.seasonId ?? tr('All seasons', 'Sab seasons'),
          entries: rankEntries(aggregateResults(_approved,
              names: _names, flaggedKeys: _flaggedKeys, template: _template)),
          lastUpdated: now,
          verified: false,
          method: method,
          disputeOpen: _scopeHasOpenDispute(_tournamentIdsWithResults),
          note: tr(
              'Season filtering needs the seasons + leaderboard_snapshots tables (backend §6) — showing all approved results for now.',
              'Season filter ke liye seasons + leaderboard_snapshots tables chahiye (backend §6) — filhal sab approved results dikhaye ja rahe hain.'),
        );
      case LeaderboardScope.country:
        return LeaderboardRanking(
          scope: scope,
          // Honest header (not just the footer note): without
          // profiles.country_code this tab cannot filter, so it
          // shows every player — never imply a country ranking.
          scopeLabel: tr('All players (country filter pending)',
              'Saare players (country filter pending)'),
          entries: rankEntries(aggregateResults(_approved,
              names: _names, flaggedKeys: _flaggedKeys, template: _template)),
          lastUpdated: now,
          verified: false,
          method: method,
          disputeOpen: _scopeHasOpenDispute(_tournamentIdsWithResults),
          note: tr(
              'Country filtering needs profiles.country_code (backend §2) — showing all approved results for now.',
              'Country filter ke liye profiles.country_code chahiye (backend §2) — filhal sab approved results dikhaye ja rahe hain.'),
        );
      case LeaderboardScope.global:
        final entries = rankEntries(aggregateResults(_approved,
                names: _names, flaggedKeys: _flaggedKeys, template: _template))
            .map((e) => e.copyWith(
                previousRank: _storedRanks[e.uid]))
            .toList();
        return LeaderboardRanking(
          scope: scope,
          scopeLabel: tr('Global', 'Global'),
          entries: entries,
          lastUpdated: now,
          verified: false,
          method: method,
          disputeOpen: _scopeHasOpenDispute(_tournamentIdsWithResults),
          note: tr(
              'Global ranking is computed locally from approved results. Previous rank comes from the stored leaderboard rank.',
              'Global ranking approved results se locally banayi gayi hai. Pichhli rank stored leaderboard rank se li gayi hai.'),
        );
    }
  }

  String _fmtDateTime(DateTime d) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    final hour = d.hour % 12 == 0 ? 12 : d.hour % 12;
    final ampm = d.hour >= 12 ? 'PM' : 'AM';
    return '${months[d.month - 1]} ${d.day}, ${d.year} '
        '$hour:${d.minute.toString().padLeft(2, '0')} $ampm';
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: LeaderboardScope.values.length,
      initialIndex: LeaderboardScope.values.indexOf(widget.initialScope),
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: Colors.transparent, // PHASE E (E4): transparent header — poster shows through
          title: Text(tr('Leaderboards', 'Leaderboards'),
              style: TextStyle(color: kText, fontWeight: FontWeight.bold)),
          iconTheme: IconThemeData(color: kGold),
          actions: [
            IconButton(
                icon: const Icon(Icons.refresh),
                onPressed: _loading ? null : _load),
          ],
          bottom: TabBar(
            isScrollable: true,
            indicatorColor: kGold,
            labelColor: kGold,
            unselectedLabelColor: kMuted,
            tabs: LeaderboardScope.values
                .map((s) => Tab(text: s.label))
                .toList(),
          ),
        ),
        body: _loading
            ? Center(child: CircularProgressIndicator(color: kGold))
            : _error != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(_error!,
                              textAlign: TextAlign.center,
                              style: TextStyle(color: kText)),
                          const SizedBox(height: 16),
                          ElevatedButton(
                            onPressed: _load,
                            style: ElevatedButton.styleFrom(
                                backgroundColor: kGold,
                                foregroundColor: Colors.black),
                            child: Text(tr('Retry', 'Dobara koshish karen')),
                          ),
                        ],
                      ),
                    ),
                  )
                : TabBarView(
                    children: LeaderboardScope.values
                        .map((s) => _scopeTab(s))
                        .toList(),
                  ),
      ),
    );
  }

  Widget _scopeTab(LeaderboardScope scope) {
    final ranking = _rankingFor(scope);
    return RefreshIndicator(
      color: kGold,
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (scope == LeaderboardScope.tournament) _tournamentPicker(),
          if (scope == LeaderboardScope.tournament)
            const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Text(
                  ranking.scopeLabel,
                  style: TextStyle(
                      color: kText, fontWeight: FontWeight.bold, fontSize: 17),
                ),
              ),
              ProvisionalBadge(verified: ranking.verified),
            ],
          ),
          const SizedBox(height: 12),
          if (ranking.entries.isEmpty)
            MockupCard(
              animate: false,
              child: Text(
                tr('No verified results yet for this ranking.',
                    'Is ranking ke liye abhi koi verified result nahi hai.'),
                style: TextStyle(color: kMuted),
              ),
            )
          else
            ...ranking.entries.map(_entryRow),
          const SizedBox(height: 16),
          _transparencyFooter(ranking),
        ],
      ),
    );
  }

  Widget _tournamentPicker() {
    final ids = _tournamentIdsWithResults;
    final current = _tournamentPick ?? _latestTournamentId;
    return DropdownButtonFormField<String>(
      value: current != null && ids.contains(current) ? current : null,
      decoration: InputDecoration(
        labelText: tr('Tournament', 'Tournament'),
        labelStyle: TextStyle(color: kMuted),
        filled: true,
        fillColor: kField,
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: kBorder)),
      ),
      dropdownColor: kSurface,
      style: TextStyle(color: kText),
      items: ids
          .map((id) => DropdownMenuItem<String>(
              value: id, child: Text(_tournamentName(id))))
          .toList(),
      onChanged: (v) => setState(() => _tournamentPick = v),
    );
  }

  Widget _entryRow(LeaderboardEntry e) {
    final movement = e.movement;
    final arrow = movement > 0
        ? '↑'
        : movement < 0
            ? '↓'
            : '–';
    final arrowColor =
        movement > 0 ? kGreen : movement < 0 ? kRed : kMuted;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: MockupCard(
        animate: false,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            SizedBox(
              width: 30,
              child: Text(
                '#${e.rank}',
                style: TextStyle(
                    color: e.rank <= 3 ? kGold : kText,
                    fontWeight: FontWeight.bold,
                    fontSize: 15),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          e.name,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: kText,
                              fontWeight: FontWeight.bold,
                              fontSize: 14),
                        ),
                      ),
                      if (e.disputeOpen)
                        Padding(
                          padding: const EdgeInsets.only(left: 6),
                          child: Icon(Icons.flag,
                              color: Colors.orange, size: 14),
                        ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    tr('${e.kills} kills · ${e.matches} matches',
                        '${e.kills} kills · ${e.matches} matches'),
                    style: TextStyle(color: kMuted, fontSize: 12),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(
              tr('${e.points} pts', '${e.points} points'),
              style: TextStyle(
                  color: kGold, fontWeight: FontWeight.bold, fontSize: 14),
            ),
            const SizedBox(width: 10),
            SizedBox(
              width: 18,
              child: Text(
                arrow,
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: arrowColor,
                    fontWeight: FontWeight.bold,
                    fontSize: 16),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Transparency footer, rendered on EVERY ranking (blueprint
  /// §6): last updated, verified/provisional, calculation method,
  /// dispute-open indicator, plus the scope note.
  Widget _transparencyFooter(LeaderboardRanking r) {
    return MockupCard(
      animate: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            tr('How this ranking is calculated',
                'Ye ranking kaise banti hai'),
            style:
                TextStyle(color: kText, fontWeight: FontWeight.bold, fontSize: 14),
          ),
          const SizedBox(height: 10),
          _footerRow(tr('Last updated', 'Aakhri update'),
              _fmtDateTime(r.lastUpdated)),
          _footerRow(tr('Status', 'Status'),
              r.verified ? tr('Verified', 'Verified') : tr('Provisional', 'Aarzi')),
          _footerRow(tr('Method', 'Tareeqa'), r.method),
          _footerRow(
              tr('Disputes open', 'Khuli disputes'),
              r.disputeOpen
                  ? tr('Yes — a dispute is open in this scope',
                      'Haan — is scope mein dispute khula hua hai')
                  : tr('No', 'Nahi')),
          if (r.note.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(r.note, style: TextStyle(color: kMuted, fontSize: 12)),
          ],
        ],
      ),
    );
  }

  Widget _footerRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(label,
                style: TextStyle(color: kMuted, fontSize: 13)),
          ),
          Expanded(
            child: Text(value,
                style: TextStyle(color: kText, fontSize: 13)),
          ),
        ],
      ),
    );
  }
}
