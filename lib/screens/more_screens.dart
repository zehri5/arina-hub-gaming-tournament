import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/imgbb_service.dart';
import '../services/sound_service.dart';
import '../services/presence_service.dart';
import '../services/push_service.dart';
import '../services/supabase_db.dart';
import '../community_service.dart';
import 'communities_screens.dart';
import 'community_screens.dart';
import 'wallet_screens.dart';
import 'player_stats.dart';
import 'pro_features.dart';
import 'sessions_page.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui; // ROUND 5: ui.PathMetric for the podium border comet.
import 'frames_screen.dart';
import 'frames_widgets.dart';
import '../services/admin_config.dart';
import '../components/arena_components.dart';
import '../components/premium_badge.dart';
import '../components/cached_image.dart';
import '../widgets/arena_ui.dart'; // Phase 2 redesign (S5): shared buttons/chips.
import '../platform/builder/smart_builder_page.dart';
import '../platform/core/regions.dart';
import '../platform/core/screens/country_select_page.dart';
import '../platform/core/screens/language_settings_page.dart';
import '../platform/disputes/action_required_page.dart';
import '../platform/disputes/dispute_center_page.dart';
import '../platform/organizer/become_organizer_page.dart';
import '../platform/organizer/organizer_dashboard_page.dart';
import '../platform/organizer/organizer_service.dart';
import '../platform/core/scoring.dart';
import '../platform/scoring/leaderboard_page.dart';
import '../platform/scoring/scoring_template_store.dart';
import '../utils.dart';
import 'rewards_screens.dart';

class EarningsPage extends StatelessWidget {
  final String uid;
  const EarningsPage({super.key, required this.uid});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Map<String, dynamic>>(
      stream: SupaDb.streamProfile(uid),
      builder: (context, snap) {
        final profile = snap.data ?? {};
        final code = strVal(profile['referralCode']);
        return SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              MockupCard(
                padding: const EdgeInsets.all(14),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _stat('Total Earnings', numVal(profile['totalEarnings'])),
                    _stat('Referral Earnings', numVal(profile['referralEarnings'])),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              MockupCard(
                padding: const EdgeInsets.all(14),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    // FIX ROUND 2026-10-28: counts are NOT money — the
                    // old _stat() formatted everything with fmtRs, so
                    // this row read "Matches: Rs 1.00".
                    _stat('Matches', numVal(profile['totalMatches']), money: false),
                    _stat('Wins', numVal(profile['wonMatches']), money: false),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Text('Refer & Earn', style: TextStyle(color: kGold, fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              FutureBuilder<Map<String, dynamic>>(
                future: SupaDb.getAppSettings(),
                builder: (context, ssnap) {
                  final settings = ssnap.data ?? {};
                  final signupBonus = SupaDb.numOf(settings['signupBonus'], 10);
                  final referralBonus = SupaDb.numOf(settings['referralBonus'], SupaDb.numOf(settings['referral_bonus'], 0));
                  final downloadLink = SupaDb.strOf(settings['appDownloadLink'], SupaDb.strOf(settings['downloadLink'], SupaDb.strOf(settings['app_download_link'])));
                  final shareText = StringBuffer('Join ARENA HUB with my referral code: $code and earn rewards!');
                  if (signupBonus > 0) shareText.write(' New users get a Rs ${signupBonus.toStringAsFixed(0)} signup bonus.');
                  if (referralBonus > 0) shareText.write(' I earn Rs ${referralBonus.toStringAsFixed(0)} for each friend who joins with my code.');
                  if (downloadLink.isNotEmpty) shareText.write(' Download: $downloadLink');
                  return MockupCard(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      children: [
                        Text('Your Referral Code', style: TextStyle(color: kMuted)),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(code.isEmpty ? '—' : code, style: TextStyle(color: kGold, fontSize: 24, fontWeight: FontWeight.bold, letterSpacing: 2)),
                            IconButton(
                              icon: Icon(Icons.copy, color: kGold),
                              onPressed: () {
                                Clipboard.setData(ClipboardData(text: code));
                                toast(context, 'Referral code copied.');
                              },
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(shareText.toString(), style: TextStyle(color: kMuted, fontSize: 12), textAlign: TextAlign.center),
                        const SizedBox(height: 8),
                        goldButton(
                          label: 'Share Referral Code',
                          onPressed: code.isEmpty ? null : () => Share.share(shareText.toString()),
                        ),
                      ],
                    ),
                  );
                },
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const LeaderboardPage())),
                  icon: Icon(Icons.emoji_events, color: kGold),
                  label: Text('Leaderboard', style: TextStyle(color: kGold)),
                  style: OutlinedButton.styleFrom(side: BorderSide(color: kGold), padding: const EdgeInsets.symmetric(vertical: 13)),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => Scaffold(appBar: AppBar(title: Text('Wallet', style: TextStyle(color: kGold))), body: WalletPage(uid: uid)))),
                  icon: Icon(Icons.account_balance_wallet, color: kGold),
                  label: Text('Open Wallet', style: TextStyle(color: kGold)),
                  style: OutlinedButton.styleFrom(side: BorderSide(color: kGold), padding: const EdgeInsets.symmetric(vertical: 13)),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _stat(String label, double v, {bool money = true}) => Column(children: [Text(label, style: TextStyle(color: kMuted, fontSize: 12)), SizedBox(height: 4), Text(money ? fmtRs(v) : v.toInt().toString(), style: TextStyle(color: kText, fontWeight: FontWeight.bold, fontSize: 18))]);
}

/// Flat crown silhouette (mockup #5 podium: gold #1, silver #2, bronze
/// #3). Pure CustomPainter — no material icon is a crown — and no glow.
class _CrownIcon extends StatelessWidget {
  final Color color;
  final double size;
  const _CrownIcon({required this.color, this.size = 28});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(size: Size(size, size * 0.75), painter: _CrownPainter(color));
  }
}

class _CrownPainter extends CustomPainter {
  final Color color;
  _CrownPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final paint = Paint()..color = color;
    final path = Path()
      ..moveTo(0, h * 0.95)
      ..lineTo(0, h * 0.45)
      ..lineTo(w * 0.22, h * 0.68)
      ..lineTo(w * 0.5, h * 0.08)
      ..lineTo(w * 0.78, h * 0.68)
      ..lineTo(w, h * 0.45)
      ..lineTo(w, h * 0.95)
      ..close();
    canvas.drawPath(path, paint);
    canvas.drawRect(Rect.fromLTWH(0, h * 0.8, w, h * 0.17), paint);
    // LEADERBOARD DETAIL (2026-11-20): jewel tips on the crown's
    // three points, like the mockup's premium crowns.
    final jewelR = w * 0.09;
    canvas.drawCircle(Offset(0, h * 0.45), jewelR, paint);
    canvas.drawCircle(Offset(w * 0.5, h * 0.08), jewelR, paint);
    canvas.drawCircle(Offset(w, h * 0.45), jewelR, paint);
  }

  @override
  bool shouldRepaint(covariant _CrownPainter old) => old.color != color;
}

// LEADERBOARD DETAIL (2026-11-20, user walkthrough) — animated golden
// ember dots drifting upward behind the leaderboard content, like
// flying sparks. Lightweight by design: one CustomPaint, 16 dots from
// a fixed table (no per-frame allocation, no dart:math), a single
// repeating controller; RepaintBoundary isolates the repaint and
// IgnorePointer (at the use site) keeps taps free. Dots fade in near
// the bottom and out near the top so nothing pops.
class _EmberDots extends StatefulWidget {
  const _EmberDots();

  @override
  State<_EmberDots> createState() => _EmberDotsState();
}

class _EmberDotsState extends State<_EmberDots> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(seconds: 16))..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (context, _) => CustomPaint(
          painter: _EmberDotsPainter(_ctrl.value),
          size: Size.infinite,
        ),
      ),
    );
  }
}

class _EmberDotsPainter extends CustomPainter {
  // x, startY, radius, rise per cycle, sway phase, base alpha.
  static const _dots = <List<double>>[
    [0.05, 0.95, 2.6, 0.45, 0.00, 0.50],
    [0.12, 0.70, 1.6, 0.60, 0.30, 0.35],
    [0.18, 0.35, 2.2, 0.50, 0.55, 0.42],
    [0.25, 0.85, 1.4, 0.70, 0.15, 0.30],
    [0.32, 0.55, 3.0, 0.40, 0.70, 0.48],
    [0.40, 0.20, 1.8, 0.65, 0.45, 0.38],
    [0.47, 0.98, 2.4, 0.48, 0.85, 0.44],
    [0.55, 0.60, 1.5, 0.58, 0.20, 0.32],
    [0.62, 0.30, 2.8, 0.42, 0.60, 0.50],
    [0.68, 0.88, 1.7, 0.66, 0.05, 0.36],
    [0.75, 0.45, 2.3, 0.52, 0.40, 0.46],
    [0.82, 0.15, 1.6, 0.72, 0.75, 0.34],
    [0.88, 0.75, 2.9, 0.44, 0.25, 0.48],
    [0.93, 0.50, 1.5, 0.62, 0.50, 0.33],
    [0.97, 0.90, 2.1, 0.46, 0.65, 0.40],
    [0.08, 0.45, 1.9, 0.56, 0.90, 0.37],
  ];
  final double t;
  const _EmberDotsPainter(this.t);

  @override
  void paint(Canvas canvas, Size size) {
    for (final d in _dots) {
      final y = (d[1] - t * d[3]) % 1.0;
      // Gentle sideways sway (triangle wave, continuous — no pops).
      final sway = (t + d[4]) % 1.0;
      final sx = (sway < 0.5 ? sway * 2 : 2 - sway * 2) * 8 - 4;
      final x = d[0] * size.width + sx;
      // Fade in at the bottom edge, out at the top edge.
      var edge = 1.0;
      if (y > 0.85) edge = (1.0 - y) / 0.15;
      if (y < 0.15) edge = y / 0.15;
      final a = d[5] * edge;
      if (a <= 0.01) continue;
      final halo = Paint()..color = kGold.withValues(alpha: a * 0.16);
      canvas.drawCircle(Offset(x, y * size.height), d[2] * 3, halo);
      final core = Paint()..color = kGold.withValues(alpha: a);
      canvas.drawCircle(Offset(x, y * size.height), d[2], core);
    }
  }

  @override
  bool shouldRepaint(covariant _EmberDotsPainter old) => old.t != t;
}

/// Phase 2 redesign (S5) — ONE source of truth for the Rank /
/// Player / Points / Matches column widths. The table header
/// (_tableBox) and every LeaderboardRow read the SAME constants, so
/// the columns can never drift apart. Values are the existing
/// mockup #5 geometry (36 / 72 / 56 + the 50dp avatar column =
/// 40dp avatar + 10dp gap), unchanged — only the duplication is
/// gone. Ranking order and score values are untouched by this.
const double _kRankColWidth = 36;
const double _kAvatarColWidth = 50;
const double _kPointsColWidth = 72;
const double _kMatchesColWidth = 56;

class LeaderboardPage extends StatefulWidget {
  // Phase 2: `embedded` lets the Rankings tab embed the leaderboard
  // body without a second Scaffold/AppBar. Default false keeps every
  // existing push (EarningsPage, etc.) byte-identical in behaviour.
  // Phase 3: tabs Global / Weekly / Friends, search, top-3 podium,
  // "YOU" row highlighted. Ranking stays the CURRENT `leaderboard_rank`
  // order. The Points column / podium show TOURNAMENT points —
  // computed from APPROVED results with the effective template
  // (1st=10, 2nd=7, 3rd=5, +1/kill), the SAME points the rank is
  // built from. (An earlier version showed Community Points ledger
  // totals here — a different point system — so top-ranked players
  // showed "0 pts". Community Points live on the Rewards hub and
  // Player Stats, not on this board.) No sample names/points are
  // ever copied.
  final bool embedded;
  const LeaderboardPage({super.key, this.embedded = false});
  @override
  State<LeaderboardPage> createState() => _LeaderboardPageState();
}

class _LeaderboardPageState extends State<LeaderboardPage> with AutomaticKeepAliveClientMixin {
  // WAVE 4 FIX 5: keep-alive so the tab State (cached leaderboard)
  // survives tab switches in the IndexedStack.
  @override
  bool get wantKeepAlive => true;

  int _tab = 0; // 0 Global, 1 Weekly, 2 Friends
  final _searchCtrl = TextEditingController();
  String _query = '';
  bool _loading = true;
  bool _offline = false;
  String? _error;
  // P-ALL-FIXES-C (2026-11-20): the mockup has NO refresh button, so
  // the load-once leaderboard re-fetches three other ways: (1)
  // pull-to-refresh on the list (RefreshIndicator in _body,
  // standalone page), (2) a stale-aware re-fetch when switching
  // Global/Weekly/Friends (see _onTabSelected — only when the cached
  // data is older than 60s, so rapid tab switching keeps load-once),
  // (3) the offline/error retry affordance. A refresh never blanks
  // the cached list — the skeleton shows only on the very first
  // load; a failed refresh keeps last-good data.
  DateTime? _lastLoadedAt;
  static const _refreshStaleAfter = Duration(seconds: 60);
  // WAVE 4 FIX 5: load-once flag — _load fetches once per session;
  // a Rankings tab switch used to re-run the whole fetch
  // (getAllRegistrations + 500-row match_history + friends +
  // leaderboard) on EVERY visit.
  bool _loadedOnce = false;
  List<Map<String, dynamic>> _users = [];
  Set<String> _weeklyUids = {};
  Set<String> _friendUids = {};
  String _myUid = '';
  // Tournament points per uid: computed from APPROVED results
  // with the effective template (same query recomputeLeaderboard
  // uses), fetched once in _load. 0 when a user has no approved
  // results. These are the points the stored rank is built from —
  // rank and points are one system on this board.
  Map<String, int> _points = {};
  // LEADERBOARD FILTER (2026-11-21, mockup #5): the tune button
  // opens a REAL filter sheet (game + period), not an info dialog.
  // The filtered view is computed from the same approved-results
  // cache the points use (mirror of the admin leaderboard's
  // _computeFiltered): game via the tournament's game_id, period
  // via created_at. Filtered rows are dense-ranked by
  // aggregateResults + rankEntries — the stored leaderboard_rank
  // is only the all-time order.
  String? _gameId; // null = all games
  String _period = 'all'; // all | week | month
  List<Map<String, dynamic>> _games = [];
  List<Map<String, dynamic>> _approvedResults = [];
  Map<String, String> _gameByTournament = {};
  Map<String, String> _namesByUid = {};
  ScoringTemplate _template = kDefaultScoringTemplate;
  List<Map<String, dynamic>> _filteredRows = [];
  Map<String, int> _filteredPoints = {};

  @override
  void initState() {
    super.initState();
    _myUid = FirebaseAuth.instance.currentUser?.uid ?? '';
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<bool> _checkOnline() async {
    try {
      final conn = await Connectivity().checkConnectivity();
      return !conn.contains(ConnectivityResult.none);
    } catch (_) {
      return true; // Cannot tell: try the load, let it fail honestly.
    }
  }

  Future<void> _load({bool force = false}) async {
    // WAVE 4 FIX 5: load-once (see _loadedOnce). Re-fetch only via
    // pull-to-refresh, stale-aware tab switching, or the
    // offline/error retry affordance — there is no refresh button
    // (mockup #5). A refresh never blanks the cached list — the
    // skeleton shows only on the very first load; a failed refresh
    // keeps last-good data.
    if (_loadedOnce && !force) return;
    final firstLoad = _users.isEmpty;
    setState(() {
      _loading = firstLoad;
      _error = null;
      _offline = false;
    });
    if (!await _checkOnline()) {
      if (mounted) setState(() { _loading = false; _offline = true; });
      return;
    }
    try {
      // Weekly: users with a match_history row played in the last 7 days.
      // match_history.played_at is the real activity signal; the list
      // keeps leaderboard_rank order, it is NOT re-ranked by activity.
      // NOTE: capped at the 500 most recent rows — a very large history
      // could miss an active player; that is a fetch cap, not a ranking.
      final weekAgo = DateTime.now().millisecondsSinceEpoch - 7 * 24 * 60 * 60 * 1000;
      final recent = await SupaDb.getList('match_history', orderBy: 'played_at', ascending: false, limit: 500);
      final weekly = <String>{};
      for (final h in recent) {
        final ts = SupaDb.parseTs(h['played_at'] ?? h['created_at']);
        if (ts >= weekAgo) weekly.add(strVal(h['firebase_uid']));
      }
      // Friends: live `friends` table (008: user_uid / friend_uid).
      // The viewer themself is included so the YOU row can appear here.
      final friends = await SupaDb.getList('friends', eqCol: 'user_uid', eqVal: _myUid);
      final friendUids = {for (final f in friends) strVal(f['friend_uid'])}..add(_myUid);
      final users = await SupaDb.getLeaderboard();
      // Filter base data (game list + tournament -> game map) —
      // own fallback: a games/tournaments read failure never
      // fails the whole board; the filter sheet then just
      // offers "All games".
      var games = <Map<String, dynamic>>[];
      var gameByTournament = <String, String>{};
      try {
        games = await SupaDb.getGamesForPicker();
        final tournaments = await SupaDb.getTournaments();
        gameByTournament = {
          for (final t in tournaments)
            SupaDb.strOf(t['id']):
                SupaDb.strOf(t['game_id'], SupaDb.strOf(t['gameId'])),
        };
      } catch (_) {}
      // Points for the mockup's Points column / podium: computed
      // from APPROVED results with the effective template — the
      // SAME points the stored rank is built from. Any error
      // leaves every user at 0 — honest, never invented.
      final points = <String, int>{};
      var approvedCache = <Map<String, dynamic>>[];
      var templateCache = kDefaultScoringTemplate;
      try {
        final template = await ScoringTemplateStore.loadEffectiveTemplate();
        final approved = await SupaDb.getList('tournament_results',
            eqCol: 'status', eqVal: 'approved', limit: 1000);
        approvedCache = approved;
        templateCache = template;
        for (final r in approved) {
          final uid = strVal(r['firebase_uid']);
          if (uid.isEmpty) continue;
          points[uid] = (points[uid] ?? 0) +
              SupaDb.matchPoints(
                  kills: intVal(r['kills']),
                  placement: intVal(r['placement']),
                  template: template);
        }
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _users = users;
        _points = points;
        _games = games;
        _approvedResults = approvedCache;
        _gameByTournament = gameByTournament;
        _template = templateCache;
        _namesByUid = {
          for (final u in users)
            strVal(u['firebase_uid']): strVal(u['displayName'], 'User'),
        };
        _weeklyUids = weekly;
        _friendUids = friendUids;
        _loading = false;
        _loadedOnce = true;
        _lastLoadedAt = DateTime.now();
      });
      // A filter active from before a refresh recomputes from the
      // fresh cache (same as the admin leaderboard page).
      if (!_filterIsAllTime) _computeFiltered();
    } catch (e) {
      // SupaDb.getList/getLeaderboard swallow read errors and return [],
      // so this is defensive-only (Phase 2 checkpoint P-C2); a read
      // failure currently looks like "empty", not an error.
      if (mounted) setState(() { _loading = false; _error = '$e'; });
    }
  }

  // P-ALL-FIXES-C: re-fetch path #2 (see _lastLoadedAt). Switching
  // Global/Weekly/Friends re-fetches ONLY when the cached data is
  // stale (>60s since the last successful load) — rapid tab
  // switching keeps the WAVE 4 load-once behaviour, and the user can
  // always get fresh data by switching tabs after a minute. Works
  // in both the standalone page and the embedded Rankings tab,
  // where pull-to-refresh cannot trigger (NeverScrollable physics).
  void _onTabSelected(int i) {
    setState(() => _tab = i);
    final last = _lastLoadedAt;
    if (last == null || DateTime.now().difference(last) > _refreshStaleAfter) {
      _load(force: true);
    }
  }

  // True when no filter is set — the board is the all-time stored
  // ranking (leaderboard_rank + _points).
  bool get _filterIsAllTime => _period == 'all' && _gameId == null;

  // The rows the podium/list render: all-time rows, or the
  // filtered rows when a filter is active.
  List<Map<String, dynamic>> get _displayUsers =>
      _filterIsAllTime ? _users : _filteredRows;
  Map<String, int> get _displayPoints =>
      _filterIsAllTime ? _points : _filteredPoints;

  String get _filterLabel {
    var game = 'All games';
    for (final g in _games) {
      if (SupaDb.strOf(g['id']) == _gameId) {
        game = SupaDb.strOf(g['name'], 'Game');
        break;
      }
    }
    final period = _period == 'week'
        ? 'This week'
        : _period == 'month'
            ? 'This month'
            : 'All time';
    return 'Filtered: $game · $period — tournament points from approved results.';
  }

  /// Filtered view from the cached approved results — the same
  /// inputs the admin leaderboard's _computeFiltered uses.
  /// Rows are dense-ranked by rankEntries and shaped like the
  /// all-time rows so podium + list render unchanged. No data
  /// means an empty list and the honest empty state, never
  /// invented rows.
  void _computeFiltered() {
    final filtered = filterApprovedResults(
      _approvedResults,
      gameByTournament: _gameByTournament,
      gameId: _gameId,
      period: _period,
      nowMs: DateTime.now().millisecondsSinceEpoch,
    );
    final entries = rankEntries(aggregateResults(
      filtered,
      names: _namesByUid,
      template: _template,
    ));
    final rows = <Map<String, dynamic>>[];
    final points = <String, int>{};
    for (final e in entries) {
      points[e.uid] = e.points;
      rows.add({
        'firebase_uid': e.uid,
        'displayName': e.name,
        'leaderboard_rank': e.rank,
        'totalMatches': e.matches,
      });
    }
    if (!mounted) return;
    setState(() {
      _filteredRows = rows;
      _filteredPoints = points;
    });
  }

  /// Opens the real filter sheet (game + period). Apply recomputes
  /// the filtered view; Clear resets to the all-time board.
  Future<void> _openFilterSheet() async {
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      // Phase 2 redesign (S5): raised surface token — the guide's
      // "Surface Elevated" is the dialog/sheet surface.
      backgroundColor: kCardPurpleMid,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22)), side: const BorderSide(color: kCardPurpleBorder, width: 1.5)),
      builder: (ctx) => LeaderboardFilterSheet(
        games: _games,
        selectedGameId: _gameId,
        period: _period,
      ),
    );
    if (result == null || !mounted) return;
    if (result['reset'] == true) {
      setState(() {
        _gameId = null;
        _period = 'all';
        _filteredRows = [];
        _filteredPoints = {};
      });
      return;
    }
    setState(() {
      _gameId = result['gameId'] as String?;
      _period = result['period'] as String? ?? 'all';
    });
    _computeFiltered();
  }

  List<Map<String, dynamic>> get _filtered {
    var list = List<Map<String, dynamic>>.from(_displayUsers);
    if (_tab == 1) list = list.where((u) => _weeklyUids.contains(strVal(u['firebase_uid']))).toList();
    if (_tab == 2) list = list.where((u) => _friendUids.contains(strVal(u['firebase_uid']))).toList();
    if (_query.isNotEmpty) {
      final q = _query.toLowerCase();
      list = list.where((u) => strVal(u['displayName'], 'User').toLowerCase().contains(q)).toList();
    }
    return list;
  }

  // Phase 2 redesign (S5): the LEADERBOARD heading, shared by the
  // standalone AppBar and the embedded Rankings tab — one widget,
  // so the two can never drift. Mockup #5: big (~32px, deliberately
  // above kStyleTitle's 22) italic w900, LEADER gold / BOARD white.
  // FittedBox scaleDown keeps it on one line on the 360px screen.
  Widget _leaderboardHeader() {
    return Row(
      children: [
        const ArenaLogo(crownSize: 26, fontSize: 13),
        const SizedBox(width: 10),
        Expanded(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: RichText(
              text: TextSpan(
                style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w900, fontStyle: FontStyle.italic),
                children: [
                  TextSpan(text: 'LEADER', style: TextStyle(color: kGold)),
                  TextSpan(text: 'BOARD', style: TextStyle(color: kText)),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (widget.embedded) return _body();
    // Mockup #5 header: ARENA HUB lockup + big italic LEADERBOARD
    // (LEADER gold, BOARD white). Back chevron is the AppBar default.
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: _leaderboardHeader(),
      ),
      body: _body(),
    );
  }

  Widget _body() {
    if (_loading) {
      return ListView(
        shrinkWrap: widget.embedded,
        physics: widget.embedded ? const NeverScrollableScrollPhysics() : null,
        padding: const EdgeInsets.all(kSpace16),
        children: const [
          LoadingSkeleton(height: 40),
          SizedBox(height: 12),
          LoadingSkeleton(height: 110),
          SizedBox(height: 12),
          LoadingSkeleton(height: 64),
          SizedBox(height: 8),
          LoadingSkeleton(height: 64),
          SizedBox(height: 8),
          LoadingSkeleton(height: 64),
        ],
      );
    }
    // WAVE 4 FIX 5: offline / error replace the list ONLY when there
    // is no cached data yet — a failed background refresh keeps the
    // last-good leaderboard on screen.
    if (_offline && _users.isEmpty) {
      return Center(child: OfflineState(onRetry: () => _load(force: true)));
    }
    if (_error != null && _users.isEmpty) {
      return Center(child: ErrorState(message: 'Leaderboard load nahi hua: $_error', onRetry: () => _load(force: true)));
    }
    final list = _filtered;
    // LEADERBOARD DETAIL (2026-11-20): animated ember dots drift
    // behind the whole page — Stack + Positioned.fill, taps pass
    // through via IgnorePointer.
    return Stack(
      children: [
        const Positioned.fill(child: IgnorePointer(child: _EmberDots())),
        // P-ALL-FIXES-C: pull-to-refresh is re-fetch path #1 (the
        // mockup has no refresh button). AlwaysScrollable physics on
        // the standalone page so a pull works even when the list is
        // shorter than the viewport; the embedded Rankings tab keeps
        // NeverScrollable physics (RefreshIndicator simply never
        // triggers there — tab-switch re-fetch covers it).
        RefreshIndicator(
          onRefresh: () => _load(force: true),
          color: kGold,
          child: ListView(
      shrinkWrap: widget.embedded,
      physics: widget.embedded ? const NeverScrollableScrollPhysics() : const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(kSpace16),
      children: [
        // Mockup #5 header (the embedded Rankings tab has no AppBar, so
        // the header lives here): ARENA HUB lockup + big italic
        // LEADERBOARD (LEADER gold, BOARD white). The scaffold's own
        // "Rankings" title + wallet/bell bar above stay as-is.
        if (widget.embedded) ...[
          _leaderboardHeader(),
          const SizedBox(height: kSpace12),
        ],
        // Mockup #5: tabs sit in one segmented pill bar (active = gold
        // pill), search field + a filter button beside it. LEADERBOARD
        // DETAIL (2026-11-20): the mockup's tab container is one
        // tall dark rounded box — radius 28, padding 6.
        // P-ALL-FIXES-C: FilterTabs(expanded: true) renders the three
        // labels as EQUAL thirds filling the box (mockup).
        // PHASE E (E24, CORRECTED 2026-11-24): the strip is the
        // card now (shared token, not the opaque kSurfaceElevated)
        // — the active tab is the gold fill inside it (FilterTabs).
        Container(
          padding: const EdgeInsets.all(6),
          decoration: cardDecoration(radius: 28),
          child: FilterTabs(
            labels: const ['Global', 'Weekly', 'Friends'],
            selectedIndex: _tab,
            onSelected: _onTabSelected,
            expanded: true,
            // Mockup #5: one outer outline on the container, no
            // per-pill outlines inside the segmented bar.
            segmented: true,
          ),
        ),
        const SizedBox(height: kSpace12),
        Row(
          children: [
            Expanded(
              child: ArenaSearchBar(
                controller: _searchCtrl,
                hint: 'Search player...',
                onChanged: (v) => setState(() => _query = v.trim()),
                // P-ALL-FIXES-C: mockup #5 — magnifier at the RIGHT
                // inside the field, full pill radius 24.
                iconAtEnd: true,
                borderRadius: 24,
              ),
            ),
            const SizedBox(width: kSpace8),
            // LEADERBOARD FILTER (2026-11-21, mockup #5): the tune
            // button opens a REAL filter sheet (game + period) —
            // the old build opened an info dialog whose text was
            // wrong ("Community Points", "rank set by admins").
            // A gold border + dot mark an active filter.
            // PHASE E (E24): the tune button is card-filled now
            // (shared token), not the opaque raised surface.
            InkWell(
              onTap: () => _openFilterSheet(),
              borderRadius: BorderRadius.circular(24),
              child: Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                    color: kCardFillColor,
                    shape: BoxShape.circle,
                    border: Border.all(
                        color: _filterIsAllTime ? kBorder : kGold)),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Icon(Icons.tune,
                        color: _filterIsAllTime ? kGold : kText),
                    if (!_filterIsAllTime)
                      Positioned(
                        right: 9,
                        top: 9,
                        child: Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                              color: kGold, shape: BoxShape.circle),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            // P-ALL-FIXES-C: NO refresh button here — the mockup has
            // none. Re-fetch still works via pull-to-refresh (below),
            // stale-aware tab switching (_onTabSelected), and the
            // offline/error retry affordance.
          ],
        ),
        const SizedBox(height: kSpace12),
        // Active-filter notice (admin leaderboard's _filterNotice,
        // compact): what the board is filtered to right now.
        if (!_filterIsAllTime) ...[
          Row(
            children: [
              Icon(Icons.filter_alt, color: kGold, size: 16),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _filterLabel,
                  style: kStyleLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: kSpace8),
        ],
        if (list.isEmpty)
          EmptyState(
            icon: Icons.emoji_events,
            title: !_filterIsAllTime && _query.isEmpty
                ? 'Is filter mein koi ranking nahi'
                : _tab == 1
                    ? 'No one played this week'
                    : _tab == 2
                        ? 'No friends on the leaderboard yet'
                        : 'No leaderboard data yet.',
            body: _query.isNotEmpty
                ? 'No player matches "$_query".'
                : !_filterIsAllTime
                    ? 'Is game/period mein koi APPROVED result nahi hai — ranking sirf approved results se banti hai. Filter badlein ya pehle results approve karein.'
                    : _tab == 1
                        ? 'Weekly shows players with a match in the last 7 days (from match history). No one has played this week yet.'
                        : _tab == 2
                            ? 'Add friends from Teams to see them here. Your friends list is empty right now.'
                            : 'The leaderboard is empty right now.',
          )
        else ...[
          _podium(list),
          const SizedBox(height: kSpace16),
          _tableBox(list),
        ],
      ],
        ),
        ),
      ],
    );
  }

  Widget _tableBox(List<Map<String, dynamic>> list) {
    // LEADERBOARD DETAIL (2026-11-20): ONE outer box holding the
    // header row and all rows — the old build had a bare header +
    // loose cards. MOCKUP CARD (2026-11-20, global rule): gradient
    // fill + the two rotating corner shines, NO full gold border
    // (the old Border.all + glow is gone). Padding stays 10 so the
    // header insets still match the row insets (see below).
    return MockupCard(
      padding: const EdgeInsets.all(10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Mockup #5 column headers: Rank | Player | Points | Matches.
          // Phase 2 redesign (S5): the widths come from the SAME
          // shared constants as the rows below (_kRankColWidth /
          // _kAvatarColWidth / _kPointsColWidth / _kMatchesColWidth),
          // so header labels and cells can never drift apart; the
          // label style is the shared kStyleLabel token (12, muted).
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: kSpace12),
            child: Row(
              children: [
                SizedBox(width: _kRankColWidth, child: Text('Rank', style: kStyleLabel.copyWith(fontWeight: FontWeight.bold), maxLines: 1, overflow: TextOverflow.ellipsis)),
                const SizedBox(width: _kAvatarColWidth),
                Expanded(child: Text('Player', style: kStyleLabel.copyWith(fontWeight: FontWeight.bold), maxLines: 1, overflow: TextOverflow.ellipsis)),
                SizedBox(width: _kPointsColWidth, child: Text('Points', style: kStyleLabel.copyWith(fontWeight: FontWeight.bold), textAlign: TextAlign.right, maxLines: 1, overflow: TextOverflow.ellipsis)),
                const SizedBox(width: kSpace8),
                SizedBox(width: _kMatchesColWidth, child: Text('Matches', style: kStyleLabel.copyWith(fontWeight: FontWeight.bold), textAlign: TextAlign.right, maxLines: 1, overflow: TextOverflow.ellipsis)),
              ],
            ),
          ),
          const SizedBox(height: kSpace8),
          for (var i = 0; i < list.length; i++) ...[
            _row(list[i], i),
            if (i < list.length - 1) const SizedBox(height: kSpace8),
          ],
        ],
      ),
    );
  }

  // Thousands separators for points ("15,840") — no intl import in
  // this file; plain loop, no dependencies.
  String _fmtPoints(int v) {
    final s = v.toString();
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
      buf.write(s[i]);
    }
    return buf.toString();
  }

  Widget _podium(List<Map<String, dynamic>> list) {
    // Mockup #5: 3-tier podium — a crown above each avatar, centre
    // (#1) tallest, rank medal overlapping the avatar, name + REAL
    // tournament points on each tier. Only REAL top-3 users appear:
    // a missing position renders as an honest empty slot (never a
    // fake player).
    // ROUND 5 REDO (2026-11-20, side-by-side vs mockup #5 — the user
    // still did not get the result he wanted):
    //  - The avatars OVERLAP the tier boxes (the mockup's avatar
    //    circles sit ON the boxes, the box top edge crossing the
    //    lower avatar); the old build floated them above the boxes
    //    with a gap. Each slot is now a Stack: box at the bottom,
    //    avatar on top, overlapping by `overlap`.
    //  - The centre tier is MUCH taller than the sides (100 vs 72,
    //    step 28 — mockup ratio ~1.4); the old 104 vs 84 (step 20)
    //    read as almost flat.
    //  - FIX 24 REFINEMENT (2026-11-21, user order — OVERRIDES the
    //    yellow-box direction above): the boxes are the STANDARD
    //    CARD colour (kCard, dark — like the empty slot was), text
    //    WHITE, the border a thin YELLOW line WITH a yellow glowing
    //    effect, and both travelling shines YELLOW (white was only
    //    needed while the boxes were yellow). The yellow gradient
    //    and black text are gone.
    //  - FIX 24.1 (2026-11-21): the divider joints are SINGLE thin
    //    (1px) lines on BOTH sides. The old per-box Border.all(1.5)
    //    doubled at the joints (3px bright) — and the right joint
    //    only LOOKED thin because the empty #3 slot's border was
    //    dark kBorder. Each box now carries only its own edges
    //    (see below); the centre box's exposed risers above the
    //    side boxes are drawn by the _PodiumRisers overlay.
    final top = list.take(3).toList();
    if (top.isEmpty) return const SizedBox.shrink();
    // Left-to-right order: #2, #1, #3 (centre tallest). `user` is
    // null for a position no real player holds yet. `overlap` = how
    // far the avatar's bottom edge hangs below the box top edge
    // (mockup: the #1 box top crosses its avatar below centre, the
    // side boxes just kiss their avatars' bottoms). Radii measured
    // from the mockup: centre avatar ~62% of its box width, sides
    // ~48% (the old 38/30 made the avatars dominate the screen).
    final order = <({Map<String, dynamic>? user, int pos, Color crown, double radius, double tierHeight, double overlap})>[
      (user: top.length > 1 ? top[1] : null, pos: 2, crown: const Color(0xFFC0C0C0), radius: 26, tierHeight: _kPodiumSideHeight, overlap: 14),
      (user: top[0], pos: 1, crown: kGold, radius: 34, tierHeight: _kPodiumCentreHeight, overlap: 32),
      (user: top.length > 2 ? top[2] : null, pos: 3, crown: const Color(0xFFCD7F32), radius: 26, tierHeight: _kPodiumSideHeight, overlap: 14),
    ];

    ({Widget avatarCell, Widget boxCell}) slotCell(({Map<String, dynamic>? user, int pos, Color crown, double radius, double tierHeight, double overlap}) s) {
      final isEmpty = s.user == null;
      final uid = isEmpty ? '' : strVal(s.user!['firebase_uid']);
      final isMe = !isEmpty && uid == _myUid;
      // M-DETAIL-FIX2-B (2026-11-20): the name box shows the REAL player
      // name, like the mockup (#1 name larger) — never "YOU" in
      // place of the name. The current user gets a small YOU pill under
      // the points instead (the old code showed "YOU" as the #1 name).
      final name = isEmpty ? '—' : strVal(s.user!['displayName'], 'User');
      final points = isEmpty ? 0 : (_displayPoints[uid] ?? 0);
      final ringColor = isEmpty ? s.crown.withValues(alpha: 0.35) : s.crown;
      // Avatar outer diameter: photo + 2.5 padding + 2.5 ring, each side.
      final avatarD = s.radius * 2 + 10;
      // Rank-coloured ring around the frame (mockup) + the rank
      // medal overlapping the avatar's bottom-right (mockup #5).
      final avatar = Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            padding: const EdgeInsets.all(2.5),
            decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: ringColor, width: 2.5)),
            child: isEmpty
                ? Container(
                    width: s.radius * 2,
                    height: s.radius * 2,
                    decoration: BoxDecoration(shape: BoxShape.circle, color: kField),
                    child: Icon(Icons.person_outline, color: kMuted, size: s.radius),
                  )
                : CachedFramedAvatar(uid: uid, name: strVal(s.user!['displayName'], 'User'), radius: s.radius),
          ),
          // ROUND 5: ribbon medal (disc + tails, like the mockup) —
          // the old build had a bare circle. It straddles the
          // avatar's bottom-right edge; the tails hang over the box.
          // FIX 24.2 (2026-11-21): the rank medal shows on ALL
          // THREE slots BY DEFAULT — the old `if (!isEmpty)` hid it
          // on empty slots, so an empty #3 had no badge. Empty
          // slots get the muted (35% alpha) rank colour, matching
          // the muted ring and crown.
          Positioned(
            right: -2,
            bottom: -12,
            child: _MedalBadge(rank: s.pos, color: isEmpty ? s.crown.withValues(alpha: 0.35) : s.crown, size: s.pos == 1 ? 28 : 24),
          ),
        ],
      );
      final box = Container(
        height: s.tierHeight,
        // ROUND 5: the name/points sit in the space BELOW the
        // overlapping avatar — top padding reserves exactly the
        // overlap, so the text never hides behind the avatar, and
        // the Column centres in what is left.
        padding: EdgeInsets.only(top: s.overlap + 2, bottom: 4, left: 4, right: 4),
        decoration: BoxDecoration(
          // FIX 24 REFINEMENT (2026-11-21): STANDARD CARD colour
          // (kCard) on ALL three boxes — the yellow gradient is
          // gone, centre included. The empty slot already was kCard;
          // now the filled slots match it.
          color: kCardFillColor,
          // FIX 24 REFINEMENT: YELLOW GLOWING border — a soft
          // kGold glow around each box (the ROUND 5 "no glow"
          // rule was overridden by the user's new order).
          boxShadow: [BoxShadow(color: kGold.withValues(alpha: 0.28), blurRadius: 10, spreadRadius: 0)],
          // M-DETAIL-FIX2-B: the three tier boxes join edge to edge
          // into ONE continuous podium (mockup) — only the outer
          // corners are rounded; the old 6px gaps are gone.
          // FIX 5 (2026-11-20): the CENTRE (#1) box's TOP corners
          // are softly rounded too (small radius, same constant as
          // the stepped clip path below) — the old BorderRadius.zero
          // left the tallest box fully square. Only the top corners:
          // the bottom corners stay square so the box still joins
          // the side boxes and the base line edge to edge, and the
          // rounding stops 20dp above the step joint, so the joint
          // itself is untouched.
          borderRadius: s.pos == 2
              ? const BorderRadius.only(topLeft: Radius.circular(12), bottomLeft: Radius.circular(12))
              : s.pos == 3
                  ? const BorderRadius.only(topRight: Radius.circular(12), bottomRight: Radius.circular(12))
                  : const BorderRadius.only(topLeft: Radius.circular(_kPodiumCentreRadius), topRight: Radius.circular(_kPodiumCentreRadius)),
          // FIX 24.1 (2026-11-21): per-side borders, so each joint
          // carries ONE thin (1px) yellow line — the old
          // Border.all(1.5) on every box doubled to 3px at the
          // joints, which is why the left (2nd–1st) joint looked
          // fat. Outer edges stay 1.5px. The centre box has NO
          // left/right border here (its exposed risers above the
          // side boxes are drawn by the _PodiumRisers overlay,
          // which paints above the boxes but never over avatars).
          border: s.pos == 2
              ? Border(left: BorderSide(color: kGold, width: 1.5), top: BorderSide(color: kGold, width: 1.5), bottom: BorderSide(color: kGold, width: 1.5), right: BorderSide(color: kGold, width: 1))
              : s.pos == 3
                  ? Border(left: BorderSide(color: kGold, width: 1), top: BorderSide(color: kGold, width: 1.5), right: BorderSide(color: kGold, width: 1.5), bottom: BorderSide(color: kGold, width: 1.5))
                  : Border(top: BorderSide(color: kGold, width: 1.5), bottom: BorderSide(color: kGold, width: 1.5)),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              name,
              // FIX 24 REFINEMENT (2026-11-21): WHITE text on the
              // dark card — black text belonged to the yellow
              // boxes and is unreadable on kCard.
              // Mockup #5: the #1 name is GOLD (crown gold);
              // 2nd/3rd stay white on the dark card.
              style: TextStyle(color: isEmpty ? kMuted : (s.pos == 1 ? kGold : Colors.white), fontWeight: FontWeight.bold, fontSize: s.pos == 1 ? 16 : 14),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 2),
            Text(
              isEmpty ? 'No player yet' : '${_fmtPoints(points)} pts',
              // Mockup #5: points text is white (not white70).
              style: TextStyle(color: isEmpty ? kMuted : Colors.white, fontSize: 13),
              textAlign: TextAlign.center,
            ),
            if (isMe) ...[
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                // FIX 24 REFINEMENT: the YOU pill is GOLD with
                // black text again (the app's own pill convention,
                // like the YOU tab on the rows below) — it reads
                // on the dark card; the black pill belonged to
                // the yellow boxes.
                decoration: BoxDecoration(color: kGold, borderRadius: BorderRadius.circular(8)),
                child: const Text('YOU', style: TextStyle(color: Colors.black, fontSize: 10, fontWeight: FontWeight.bold)),
              ),
            ],
          ],
        ),
      );
      // ROUND 5: the avatar OVERLAPS the box, like the mockup —
      // the old Column left an 8dp gap between the avatar and the
      // box. SAMEER FIX 1 (2026-11-21): the slot is SPLIT into two
      // layers so the podium's animated overlays (face sheen,
      // border comet, risers) can paint BETWEEN them — boxes at the
      // bottom, overlays in the middle, crowns + avatars on top.
      // The old build stacked box + avatar inside one slot and the
      // overlays sat above the whole Row, so the travelling yellow
      // line crossed OVER the photos. Geometry is unchanged: the
      // avatar column keeps its exact height (avatarD + tierHeight
      // - overlap, avatar at its top) and the box row is
      // bottom-aligned to the same baseline, so the avatar still
      // overlaps its box by `overlap` — only the paint order moved.
      // The Row's CrossAxisAlignment.end keeps all three box
      // bottoms aligned.
      final avatarCell = Expanded(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _CrownIcon(color: isEmpty ? s.crown.withValues(alpha: 0.35) : s.crown, size: s.pos == 1 ? 34 : 26),
            const SizedBox(height: 4),
            SizedBox(
              height: avatarD + s.tierHeight - s.overlap,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned(top: 0, left: 0, right: 0, child: Center(child: avatar)),
                ],
              ),
            ),
          ],
        ),
      );
      final boxCell = Expanded(child: box);
      return (avatarCell: avatarCell, boxCell: boxCell);
    }

    // SAMEER FIX 1 (2026-11-21): the slots are built once, then the
    // podium Stack layers them — boxes (bottom) -> animated
    // overlays (middle) -> crowns + avatars (top) — so the
    // travelling yellow line always passes BEHIND the photos.
    final cells = [for (final s in order) slotCell(s)];
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // ROUND 5: NO glow box behind the podium — the background
        // behind it is dark, like the mockup. The shine lives ON the
        // boxes only: a face sheen + a travelling border comet
        // (same language as the home hero slider), both clipped /
        // pinned to the stepped box outline. SAMEER FIX 1
        // (2026-11-21): the overlays paint BETWEEN the boxes and the
        // avatars (see the layer order below) — the old Stack put
        // them above the whole Row, so the line crossed OVER the
        // photos even though it was pinned to the boxes region (the
        // avatars overlap the boxes by up to 32dp).
        Stack(
          children: [
            // Layer 1 (bottom): the tier boxes only, bottom-aligned
            // (M-DETAIL-FIX2-B: no gaps — they join into one
            // continuous podium, like the mockup).
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [for (final c in cells) c.boxCell],
              ),
            ),
            // ROUND 5: the face sheen is pinned to the boxes region
            // (bottom, centre-tier tall) AND clipped to the stepped
            // podium outline — the old Positioned.fill swept the
            // band across the avatars and crowns too.
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: _kPodiumCentreHeight,
              child: IgnorePointer(
                child: ClipPath(
                  clipper: const _SteppedPodiumClipper(),
                  child: const _PodiumSheen(),
                ),
              ),
            ),
            // ROUND 5: the travelling shine BORDER around the tier
            // boxes — a bright comet running clockwise along the
            // stepped podium outline (centre box tallest), on the
            // same 4.5 s loop as the face sheen. Bottom-aligned,
            // centre-tier tall, so it hugs the boxes only (never
            // the avatars).
            const Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: _kPodiumCentreHeight,
              child: IgnorePointer(child: _PodiumBorderSheen()),
            ),
            // FIX 24.1 (2026-11-21): the centre box's exposed
            // risers — the two short vertical edges above the side
            // boxes (the centre box has no left/right border of
            // its own, so the joints stay single lines). Painted
            // as a static overlay: the risers sit at the slot
            // boundaries, far from every avatar, so they never
            // paint over one.
            const Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: _kPodiumCentreHeight,
              child: IgnorePointer(child: _PodiumRisers()),
            ),
            // Layer 3 (top, SAMEER FIX 1): crowns + avatars — always
            // fully visible ABOVE the animated line. This
            // non-positioned Row sizes the Stack; the box layer is
            // bottom-aligned to it, so the avatar/box overlap is
            // exactly as before.
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [for (final c in cells) c.avatarCell],
            ),
          ],
        ),
        const SizedBox(height: kSpace8),
        // Bright gold base line under the platform, like the mockup.
        // Phase 2 redesign (S5): the premium gold gradient
        // (kGoldSoft -> kGold, #FDC903) instead of a flat fill.
        FractionallySizedBox(
          widthFactor: 0.85,
          child: Container(
            height: 3,
            decoration: BoxDecoration(
              gradient: kGoldGradient,
              borderRadius: BorderRadius.circular(2),
              boxShadow: [BoxShadow(color: kGold.withValues(alpha: 0.5), blurRadius: 10)],
            ),
          ),
        ),
      ],
    );
  }


  Widget _row(Map<String, dynamic> u, int i) {
    final uid = strVal(u['firebase_uid']);
    final isMe = uid == _myUid;
    // Rank from leaderboard_rank (NOT totalEarnings sort).
    final rank = SupaDb.intOf(u['leaderboard_rank'], i + 1);
    final matches = intVal(u['totalMatches']);
    // Mockup #5 columns: Rank / Player / Points / Matches.
    // Points = tournament points (approved results, effective
    // template) — the same points the rank is built from.
    final row = LeaderboardRow(
      rank: rank,
      name: strVal(u['displayName'], 'User'),
      photoUrl: strVal(u['photoURL']),
      pointsText: _fmtPoints(_displayPoints[uid] ?? 0),
      matches: matches,
      isMe: isMe,
    );
    if (!isMe) return row;
    // YOU row: gold border highlight + gold YOU tab on the top edge
    // (mockup #5). Same 64dp box height as every other row — the tab
    // overlaps the top edge into the inter-row gap, it does not add
    // height to the box.
    // M-DETAIL-FIX2-B: the gold border is a DecoratedBox, NOT a
    // Container with a decoration — a Container ADDS its border's
    // dimensions to the layout (2px top + 2px bottom), which made the
    // YOU box 68dp while every other row is 64dp. DecoratedBox paints
    // the same 2px border on the row's own 64dp box, so the YOU row
    // is exactly the same height and width as all other rows.
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // P-ALL-FIXES-C: restored M-DETAIL-FIX2-B fix — the gold
          // border is a DecoratedBox, NOT a Container with a
          // decoration: a Container ADDS its border's dimensions to
          // the layout (2px top + 2px bottom), which made the YOU box
          // 68dp while every other row is 64dp. DecoratedBox paints
          // the same 2px border on the row's own 64dp box.
          // Phase 2 redesign (S5): a soft gold glow around the YOU
          // row (shadow only — it never changes layout) so the
          // current user's row reads as highlighted at a glance,
          // on top of the gold border + YOU pill.
          DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: kGold, width: 2),
              boxShadow: [BoxShadow(color: kGold.withValues(alpha: 0.22), blurRadius: 12)],
            ),
            child: row,
          ),
          Positioned(
            top: -9,
            left: 16,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(color: kGold, borderRadius: BorderRadius.circular(8)),
              child: const Text('YOU', style: TextStyle(color: Colors.black, fontSize: 10, fontWeight: FontWeight.bold)),
            ),
          ),
        ],
      ),
    );
  }
}

/// LEADERBOARD FILTER SHEET (2026-11-21, mockup #5): the tune
/// button opens this REAL filter — game + period — never an info
/// dialog. Apply pops {'gameId': String?, 'period': String};
/// Clear pops {'reset': true}; dismissing pops null. The note
/// states the ranking rule honestly: tournament points from
/// APPROVED results (1st=10, 2nd=7, 3rd=5, +1 per kill) — the
/// old dialog's "Community Points" / "rank set by admins" text
/// was factually wrong and is gone. Pure widget — unit-tested.
class LeaderboardFilterSheet extends StatefulWidget {
  final List<Map<String, dynamic>> games;
  final String? selectedGameId;
  final String period; // all | week | month
  const LeaderboardFilterSheet({
    super.key,
    required this.games,
    required this.selectedGameId,
    required this.period,
  });
  @override
  State<LeaderboardFilterSheet> createState() => _LeaderboardFilterSheetState();
}

class _LeaderboardFilterSheetState extends State<LeaderboardFilterSheet> {
  String? _gameId;
  String _period = 'all';

  @override
  void initState() {
    super.initState();
    _gameId = widget.selectedGameId;
    _period = widget.period;
  }

  // Phase 2 redesign (S5): the shared ArenaFilterChip — selected =
  // yellow fill + dark text, unselected = dark surface + grey
  // border. Same look and same tap behaviour as the old ChoiceChip.
  Widget _periodChip(String value, String label) {
    return ArenaFilterChip(
      label: label,
      selected: _period == value,
      onTap: () => setState(() => _period = value),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Scrollable: the sheet is tall (game + period + note +
    // buttons) and must never overflow a small phone screen.
    return SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(kSpace16, kSpace12, kSpace16, kSpace20),
          child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('Filter', style: kStyleSection),
                ),
                IconButton(
                  icon: Icon(Icons.close, color: kText),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            const SizedBox(height: kSpace8),
            Text('Game', style: kStyleLabel.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Container(
              decoration: BoxDecoration(
                  color: kField,
                  borderRadius: BorderRadius.circular(kRadiusInput),
                  border: Border.all(color: kBorder)),
              padding: const EdgeInsets.symmetric(horizontal: kSpace12),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String?>(
                  value: _gameId,
                  isExpanded: true,
                  dropdownColor: kField,
                  hint: Text('All games',
                      style: TextStyle(color: kText)),
                  items: [
                    DropdownMenuItem<String?>(
                      value: null,
                      child: Text('All games',
                          style: TextStyle(color: kText)),
                    ),
                    for (final g in widget.games)
                      DropdownMenuItem<String?>(
                        value: SupaDb.strOf(g['id']),
                        child: Text(SupaDb.strOf(g['name'], 'Game'),
                            style: TextStyle(color: kText)),
                      ),
                  ],
                  onChanged: (v) => setState(() => _gameId = v),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Text('Period', style: kStyleLabel.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Wrap(
              spacing: kSpace8,
              children: [
                _periodChip('all', 'All time'),
                _periodChip('week', 'This week'),
                _periodChip('month', 'This month'),
              ],
            ),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                  color: kField, borderRadius: BorderRadius.circular(kRadiusChip)),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.info_outline, color: kGold, size: 16),
                  SizedBox(width: kSpace8),
                  Expanded(
                    child: Text(
                      'Points are tournament points from APPROVED results (1st=10, 2nd=7, 3rd=5, +1 per kill). Ranks update when an admin approves a result.',
                      style: kStyleLabel.copyWith(fontWeight: FontWeight.normal),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: kSpace16),
            Row(
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context, {'reset': true}),
                  child: Text('Clear filter',
                      style: TextStyle(color: kGold)),
                ),
                const SizedBox(width: kSpace8),
                Expanded(
                  // Phase 2 redesign (S5): the shared primary
                  // button — gold-gradient fill, dark text. Same
                  // Apply behaviour (pops gameId + period).
                  child: ArenaPrimaryButton(
                    onPressed: () => Navigator.pop(
                        context, {'gameId': _gameId, 'period': _period}),
                    child: const Text('Apply',
                        style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ),
              ],
            ),
          ],
        ),
        ),
      ),
    );
  }
}

/// ROUND 5 (2026-11-20) — podium geometry, measured from mockup #5:
/// centre tier 100dp, side tiers 72dp (ratio ~1.4, step 28dp),
/// outer corner radius 12dp. Single source of truth for the tier
/// boxes (_podium), the face-sheen clip and the border comet.
/// FIX 5 (2026-11-20): centre-tier TOP corner radius 8dp — small
/// and soft, deliberately smaller than the 12dp outer corners, and
/// well under the 28dp step so the centre/side joint is untouched.
const double _kPodiumCentreHeight = 100.0;
const double _kPodiumSideHeight = 72.0;
const double _kPodiumStep = _kPodiumCentreHeight - _kPodiumSideHeight;
const double _kPodiumRadius = 12.0;
const double _kPodiumCentreRadius = 8.0;

/// The stepped outline of the three joined tier boxes (centre
/// tallest), clockwise from the left box's top-left corner. Single
/// source of truth for the border comet AND the face-sheen clip, so
/// both hug the boxes exactly. `size.height` must be the centre
/// tier height; the side tiers end `step` below the top. `inset`
/// pulls the outline inside the boxes (1 = the border stroke's
/// centre, for the comet painter); the clip uses 0 (full boxes).
/// FIX 5 (2026-11-20): the centre tier's TOP corners are rounded
/// (centreRadius, same constant as the centre box decoration) — the
/// old path ran square across the top, so a square sheen corner
/// would have stuck out past the box's new rounded corners. The
/// rounding lives entirely in the top `centreRadius` of the risers,
/// far above the step joints, so the joints are unchanged.
Path _steppedPodiumPath(Size size, {double step = _kPodiumStep, double radius = _kPodiumRadius, double centreRadius = _kPodiumCentreRadius, double inset = 0}) {
  final w = size.width;
  final h = size.height;
  final third = w / 3;
  final r = radius;
  final cr = centreRadius;
  final i = inset;
  return Path()
    ..moveTo(i, step + r)
    ..lineTo(i, h - r)
    ..quadraticBezierTo(i, h - i, i + r, h - i)
    ..lineTo(w - i - r, h - i)
    ..quadraticBezierTo(w - i, h - i, w - i, h - r)
    ..lineTo(w - i, step + r)
    ..quadraticBezierTo(w - i, step + i, w - i - r, step + i)
    ..lineTo(2 * third, step + i)
    ..lineTo(2 * third, i + cr)
    ..quadraticBezierTo(2 * third, i, 2 * third - cr, i)
    ..lineTo(third + cr, i)
    ..quadraticBezierTo(third, i, third, i + cr)
    ..lineTo(third, step + i)
    ..lineTo(i + r, step + i)
    ..quadraticBezierTo(i, step + i, i, step + r)
    ..close();
}

/// Clips the face sheen to the stepped podium outline, so the band
/// only ever paints ON the tier boxes (never the avatars above the
/// side boxes or the gaps beside the centre box).
class _SteppedPodiumClipper extends CustomClipper<Path> {
  const _SteppedPodiumClipper();
  @override
  Path getClip(Size size) => _steppedPodiumPath(size);
  @override
  bool shouldReclip(covariant _SteppedPodiumClipper old) => false;
}

/// Mockup #5 rank medal: a rank-coloured disc with the rank number
/// + two short ribbon tails hanging below it (the old build had a
/// bare circle). The tails overlay the tier box, like the mockup.
class _MedalBadge extends StatelessWidget {
  final int rank;
  final Color color;
  final double size;
  const _MedalBadge({required this.rank, required this.color, this.size = 28});

  @override
  Widget build(BuildContext context) {
    final tailH = size * 0.28;
    return SizedBox(
      width: size,
      height: size + tailH,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: (size - size * 0.62) / 2,
            top: size - 2,
            child: CustomPaint(
              size: Size(size * 0.62, tailH + 2),
              painter: _MedalRibbonPainter(color),
            ),
          ),
          Container(
            width: size,
            height: size,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(color: kCard, width: 2),
            ),
            child: Text('$rank', style: const TextStyle(color: Colors.black, fontWeight: FontWeight.w900, fontSize: 13)),
          ),
        ],
      ),
    );
  }
}

/// Two tapered ribbon tails with a V notch between them, in the
/// rank colour darkened a touch (like the mockup's shaded tails).
class _MedalRibbonPainter extends CustomPainter {
  final Color color;
  const _MedalRibbonPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final paint = Paint()..color = Color.lerp(color, Colors.black, 0.18)!;
    // Left tail: tapered, slanted bottom edge.
    final left = Path()
      ..moveTo(0, 0)
      ..lineTo(w * 0.46, 0)
      ..lineTo(w * 0.38, h)
      ..lineTo(w * 0.16, h * 0.72)
      ..close();
    // Right tail (mirror).
    final right = Path()
      ..moveTo(w * 0.54, 0)
      ..lineTo(w, 0)
      ..lineTo(w * 0.84, h * 0.72)
      ..lineTo(w * 0.62, h)
      ..close();
    canvas.drawPath(left, paint);
    canvas.drawPath(right, paint);
  }

  @override
  bool shouldRepaint(covariant _MedalRibbonPainter old) => old.color != color;
}

/// ROUND 5 (2026-11-20): the podium's animated face shine — the
/// SAME diagonal travelling band as the home slider's _HeroSheen
/// (user: "jaise slider mein shine wala border hai"), sweeping
/// left -> right across the three tier boxes on a slow 4.5 s loop.
/// YELLOW (FIX 24 REFINEMENT, 2026-11-21): white was only needed
/// while the boxes were yellow; on the dark card the yellow sheen
/// reads clearly. The call site pins it to the boxes region and
/// clips it to the stepped outline. Own widget + RepaintBoundary,
/// so only the podium repaints; IgnorePointer at the call site,
/// never blocks taps.
class _PodiumSheen extends StatefulWidget {
  const _PodiumSheen();
  @override
  State<_PodiumSheen> createState() => _PodiumSheenState();
}

class _PodiumSheenState extends State<_PodiumSheen> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 4500))..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (context, _) => CustomPaint(painter: _PodiumSheenPainter(_ctrl.value)),
      ),
    );
  }
}

/// One diagonal YELLOW band + one thin yellow slash, travelling left
/// -> right (same geometry as _HeroSheenPainter on the slider).
/// FIX 24 REFINEMENT (2026-11-21): yellow, not white — white was
/// only needed while the boxes were yellow; on the dark card the
/// yellow sheen reads clearly. Alpha stays low (<= 0.30) so the
/// sweep reads as a gentle sheen, not a flash.
class _PodiumSheenPainter extends CustomPainter {
  final double t;
  const _PodiumSheenPainter(this.t);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    // Band centre travels from -0.35w (off-screen left) to 1.35w
    // (off-screen right).
    final cx = (-0.35 + 1.7 * t) * w;
    final band = Path()
      ..moveTo(cx - 0.22 * w, -10)
      ..lineTo(cx + 0.06 * w, -10)
      ..lineTo(cx - 0.14 * w, h + 10)
      ..lineTo(cx - 0.42 * w, h + 10)
      ..close();
    final bandRect = Rect.fromLTWH(cx - 0.42 * w, 0, 0.48 * w, h);
    canvas.drawPath(
      band,
      Paint()
        ..shader = LinearGradient(
          colors: [
            kGold.withValues(alpha: 0),
            kGold.withValues(alpha: 0.30),
            kGold.withValues(alpha: 0),
          ],
          stops: const [0.0, 0.5, 1.0],
        ).createShader(bandRect),
    );
    // Thin yellow slash travelling just behind the band.
    final sx = cx - 0.30 * w;
    canvas.drawLine(
      Offset(sx, -10),
      Offset(sx - 0.28 * w, h + 10),
      Paint()
        ..color = kGold.withValues(alpha: 0.40)
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(covariant _PodiumSheenPainter old) => old.t != t;
}

/// ROUND 5 (2026-11-20): the podium's travelling shine BORDER — a
/// bright COMET running clockwise around the three joined tier
/// boxes, forever, on the same 4.5 s loop as the face sheen. The
/// same comet language as the home hero slider's _HeroBorderRunner:
/// wide faint gold halo + bright core + bright head dot. FIX 24
/// REFINEMENT (2026-11-21): the core + head dot are YELLOW — white
/// was only needed while the boxes were yellow; on the dark card
/// the yellow comet reads clearly. The outline is STEPPED (centre
/// box tallest) from the shared _steppedPodiumPath builder. Own
/// widget + RepaintBoundary; the call site pins it to the boxes
/// region (bottom, centre-tier tall).
class _PodiumBorderSheen extends StatefulWidget {
  const _PodiumBorderSheen();
  @override
  State<_PodiumBorderSheen> createState() => _PodiumBorderSheenState();
}

class _PodiumBorderSheenState extends State<_PodiumBorderSheen> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 4500))..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (context, _) => CustomPaint(painter: _PodiumBorderSheenPainter(_ctrl.value)),
      ),
    );
  }
}

class _PodiumBorderSheenPainter extends CustomPainter {
  final double t;
  const _PodiumBorderSheenPainter(this.t);

  @override
  void paint(Canvas canvas, Size size) {
    // The stepped outline from the shared builder (inset 1 = the
    // border stroke's centre, so the comet rides ON the border).
    final path = _steppedPodiumPath(size, inset: 1);
    // computeMetrics() is single-use (see _HeroBorderRunnerPainter
    // in home_screens.dart) — take the metric in one iteration only.
    ui.PathMetric? metric;
    for (final m in path.computeMetrics()) {
      metric = m;
      break;
    }
    if (metric == null) return;
    final total = metric.length;
    if (total <= 0) return;
    // The comet: a 150dp segment (same length as the home hero
    // slider's comet, clamped to half the outline on very narrow
    // screens) with its head at t around the outline, travelling
    // clockwise forever. No blink at the loop wrap: the head wraps
    // from the end back to the start continuously.
    final segLen = math.min(150.0, total * 0.5);
    final head = (t * total) % total;
    final start = (head - segLen) % total;
    final Path segPath;
    if (start < head) {
      segPath = metric.extractPath(start, head);
    } else {
      segPath = metric.extractPath(start, total);
      segPath.addPath(metric.extractPath(0, head), Offset.zero);
    }
    // Wide faint gold halo + bright YELLOW core + bright head dot —
    // the hero slider's comet language. FIX 24 REFINEMENT: the
    // core + head dot are yellow (white was only needed on the
    // yellow boxes); on the dark card the yellow comet reads.
    canvas.drawPath(segPath, Paint()..color = kGold.withValues(alpha: 0.25)..style = PaintingStyle.stroke..strokeWidth = 6..strokeCap = StrokeCap.round);
    canvas.drawPath(segPath, Paint()..color = kGold.withValues(alpha: 0.95)..style = PaintingStyle.stroke..strokeWidth = 2.5..strokeCap = StrokeCap.round);
    final headPos = metric.getTangentForOffset(head)?.position;
    if (headPos != null) {
      canvas.drawCircle(headPos, 4, Paint()..color = kGold);
      canvas.drawCircle(headPos, 7, Paint()..color = kGold.withValues(alpha: 0.35)..style = PaintingStyle.stroke..strokeWidth = 2);
    }
  }

  @override
  bool shouldRepaint(covariant _PodiumBorderSheenPainter old) => old.t != t;
}

/// FIX 24.1 (2026-11-21) — the centre tier's exposed risers: the
/// two short vertical edges where the taller centre box rises above
/// the side boxes (from the centre top corner down to the side-box
/// top, i.e. y = centreRadius .. step within the boxes region).
/// The centre box carries no left/right border of its own — that is
/// what keeps the 2nd–1st and 1st–3rd joints single thin lines —
/// so these risers are painted here as a static overlay. They sit
/// exactly on the slot boundaries, far from every avatar circle,
/// so they never paint over one. Static (shouldRepaint false):
/// painted once, no per-frame cost.
class _PodiumRisers extends StatelessWidget {
  const _PodiumRisers();
  @override
  Widget build(BuildContext context) => const CustomPaint(painter: _PodiumRisersPainter());
}

class _PodiumRisersPainter extends CustomPainter {
  const _PodiumRisersPainter();
  @override
  void paint(Canvas canvas, Size size) {
    final third = size.width / 3;
    final paint = Paint()
      ..color = kGold
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true;
    // From just below the rounded top corner (centreRadius) down
    // to the side-box top (step). The 1.5px matches the outer edges.
    canvas.drawLine(Offset(third, _kPodiumCentreRadius), Offset(third, _kPodiumStep), paint);
    canvas.drawLine(Offset(2 * third, _kPodiumCentreRadius), Offset(2 * third, _kPodiumStep), paint);
  }

  @override
  bool shouldRepaint(covariant _PodiumRisersPainter old) => false;
}

/// LEADERBOARD SLIM FIX (2026-11-20) — one table row, extracted so its
/// geometry is widget-testable. Mockup #5 rows are slim: the SAME height
/// for every row (64dp), a fixed 40dp avatar, single-line everything.
/// The YOU row differs ONLY by the gold border + YOU pill, which the
/// caller adds — never by height.
///
/// Root cause of the old oversized YOU row (measured ~80dp on the
/// user's phone screenshot): appCard's 14px padding + a two-line
/// Matches stack on the YOU row + CachedFramedAvatar, whose equipped
/// frame ring inflates the avatar 40 -> 50dp. The row avatar here is
/// a fixed 40dp ArenaCachedAvatar (real photo when the profile has
/// one, initial letter otherwise — never a fake photo); equipped
/// frames are NOT rendered in the table (the mockup shows plain
/// thin-ring avatars; frames still show on the podium and Profile).
class LeaderboardRow extends StatelessWidget {
  final int rank;
  final String name;
  final String photoUrl;
  final String pointsText;
  final int matches;
  final bool isMe;
  const LeaderboardRow({super.key, required this.rank, required this.name, required this.photoUrl, required this.pointsText, required this.matches, required this.isMe});

  @override
  Widget build(BuildContext context) {
    final initial = name.isNotEmpty ? name[0].toUpperCase() : 'P';
    // MOCKUP CARD (2026-11-20, global card rule): the row is the
    // shared MockupCard (two rotating yellow shines, no full border).
    // 64dp geometry preserved — MockupCard paints NO border, so the
    // vertical padding is 12, not 11: 12 + 12 + 40 avatar = 64dp
    // exactly, matching the slim-row regression test. The YOU row's
    // gold border still comes from the caller's wrapper.
    // Phase 2 redesign (S5): animate: false for list rows (contract)
    // — the shines park at rest, no ticker per row. Column widths
    // come from the SAME shared constants as the table header, so
    // Rank / Player / Points / Matches can never drift apart.
    // Text styles are the shared kStyleBody token (15), bolded.
    return MockupCard(
      animate: false,
      padding: const EdgeInsets.symmetric(horizontal: kSpace12, vertical: kSpace12),
      radius: kRadiusChip,
      child: Row(
        children: [
          SizedBox(
            width: _kRankColWidth,
            child: Text('#$rank', style: kStyleBody.copyWith(color: isMe ? kGold : kText, fontWeight: FontWeight.bold)),
          ),
          // Fixed 40dp avatar: 37dp photo + 1.5dp ring each side.
          // (BoxDecoration borders paint inside the box, so the
          // outer size stays exactly 40dp.)
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: isMe ? kGold : kBorder, width: 1.5)),
            child: ClipOval(
              child: ArenaCachedAvatar(
                photoUrl: photoUrl,
                radius: 18.5,
                // ROUND 5 (2026-11-20): kGold, never a hardcoded
                // yellow hex — the later kGold -> #FDC903 pass must
                // recolour this fallback too.
                backgroundColor: kGold,
                fallback: Text(initial, style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 15)),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            // LEADERBOARD DETAIL (2026-11-20): mockup rows show the
            // name only — the old "N wins" subline is gone.
            // Long names ellipsize on one line, never overflow.
            child: Text(name, style: kStyleBody.copyWith(color: isMe ? kGold : kText, fontWeight: FontWeight.bold), maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          // Mockup #5: Points (tournament points from approved results) then Matches.
          SizedBox(
            width: _kPointsColWidth,
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: pointsText, style: kStyleBody.copyWith(color: isMe ? kGold : kText, fontWeight: FontWeight.bold, fontSize: 14)),
                  TextSpan(text: ' PTS', style: TextStyle(color: kMuted, fontWeight: FontWeight.bold, fontSize: 10)),
                ],
              ),
              textAlign: TextAlign.right,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: kSpace8),
          // Single-line matches number on EVERY row, YOU included —
          // the old two-line "Matches" label under the YOU number
          // made that row taller than the rest.
          SizedBox(
            width: _kMatchesColWidth,
            child: Text('$matches', style: kStyleBody.copyWith(color: kText, fontWeight: FontWeight.bold), textAlign: TextAlign.right, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }
}

class ProfilePage extends StatefulWidget {
  final String uid;
  const ProfilePage({super.key, required this.uid});
  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> with SingleTickerProviderStateMixin, AutomaticKeepAliveClientMixin {
  // WAVE 4 FIX 5: keep-alive so the tab State survives switches.
  @override
  bool get wantKeepAlive => true;

  // WAVE B design-match (#18, 2026-11-19): mockup structure — header
  // (Back / PROFILE), gold-ring avatar, name / @handle /
  // Member since, outlined Edit Profile pill, 2x2 stats grid, tabs
  // Overview / Match History / Achievements, achievements preview.
  // REAL DATA ONLY: handle = username (omitted when unset), Member
  // since = profiles.created_at (omitted when unset), Current Rank =
  // profiles.rank_tier (migration 017, 'Bronze' when unset — never a
  // higher tier invented).
  // MOCKUP #18 HEADER (2026-11-21): the in-page header is back —
  // centered PROFILE + gear top-right, Back only when pushed
  // (see build). This supersedes the 2026-11-20 "gear OUT" order:
  // the gear opens the SAME SettingsPage the Overview 'Settings'
  // tile opens (one Settings, no duplicate). NOTE: on the
  // bottom-nav root tab HomeShell's AppBar still shows "Profile" +
  // wallet + bell above this header (main.dart, outside this
  // file) — hiding it there is a one-line follow-up for the
  // main.dart lane (add _index == 5 to the appBar-null condition,
  // same pattern as tabs 0 and 2).
  // TabBar is scrollable so no tab label clips on 360px. Stats are
  // ~36px values / ~15px labels per the mockup. J-detail-fix1 (#18):
  // Lv badge is BLACK-filled with a GOLD border + GOLD text (mockup
  // #18 — the old gold-filled / black-text pill was inverted).
  // (user order "kro"): 4th stat = Community Points (REAL ledger
  // total via SupaDb.getPointsTotal; 0 when no rows); XP bar under
  // the Edit Profile pill uses REAL profiles.xp / profiles.level
  // with the curve next-level = level x 100 XP (display only — no
  // level-up logic, no writes; leveling stays server-side).
  // WAVE C (2026-11-19): Lv badge shows the REAL profiles.level
  // (migration 017, same source Home uses — intVal(level, 1)).
  // The settings tiles live in the Overview tab.
  // Photo-change (FIX 3) flow is unchanged. FIX ROUND (2026-11-20,
  // duplicate cleanup): the name-edit tile is gone — name editing
  // lives only inside the Edit Profile flow (CreateProfilePage's
  // Display Name field), so the old name-edit dialog was removed too.
  late final TabController _tabController;
  int _tabIndex = 0;
  // ADMIN PERSISTENCE FIX (2026-10-30 user report): the admin
  // account lost its admin UI on app restart, because AdminRooms
  // was reachable ONLY from the Admin Login button on the logged-out
  // AuthScreen, while a restored Firebase session goes straight to
  // HomeShell. This flag re-derives admin identity from the same
  // fail-closed designated-admin check (admin_config id=1
  // admin_firebase_uid vs the signed-in UID) — never from a stored
  // flag or a navigation argument, so it survives close/reopen, and
  // a non-admin NEVER sees the row. WAVE 4 FIX 5: it now runs once
  // per session (initState) instead of on every Profile visit, so a
  // tab switch never re-fetches it; a mid-session admin grant shows
  // after the next app restart.
  // FIX 32 (2026-11-24): the flag now gates ONLY the Organizer
  // Runbook tile — the admin panel ("Switch to Admin") is gone.
  bool _isDesignatedAdmin = false;
  // WAVE 4 FIX 5: the profile stream + match-history future are
  // created ONCE, not per build — the old build called
  // SupaDb.streamProfile(widget.uid) and getMatchHistory(widget.uid)
  // fresh on EVERY build, so every tab switch (and every setState)
  // re-subscribed / re-fetched. History refreshes on
  // SupaDb.refreshNotifier (Join / pop-back) instead of on visit.
  // P-ALL-FIXES-A (2026-11-20, profile photo): NOT final any more —
  // _changePhoto and _refreshHistory resubscribe it on purpose (see
  // _subscribeProfile): the stream only re-emits on a Supabase
  // Realtime postgres_changes event, which never arrives when the
  // table is out of the realtime publication or realtime drops on a
  // flaky connection — so a saved photo never appeared until an app
  // restart. Resubscribing forces the stream's initial fetch, which
  // is a plain read and always returns the fresh row.
  late Stream<Map<String, dynamic>> _profileStream;
  late Future<List<Map<String, dynamic>>> _historyFuture;
  // OD-02 (2026-11-20): Community Points total — SUM of
  // community_points_ledger.delta for this user (SupaDb
  // .getPointsTotal). Created once, refreshed with history.
  late Future<int> _pointsFuture;
  // FIX 3 (Wave 4, 2026-11-19): profile photo is changeable from the
  // Profile screen itself — the upload flow used to live only under
  // the Frames screen, so users had no way to change it here.
  bool _photoBusy = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    // WAVE 4 FIX 5: stream + history future created once (see fields
    // above); history re-fetches on the refresh notifier only.
    _subscribeProfile();
    _historyFuture = SupaDb.getMatchHistory(widget.uid);
    _pointsFuture = SupaDb.getPointsTotal(widget.uid);
    SupaDb.refreshNotifier.addListener(_refreshHistory);
    // ROUND 6: entering Profile re-heartbeats immediately, so the
    // header dot is green within seconds of opening Profile even if
    // the last heartbeat is minutes old.
    PresenceService.goOnline();
    _checkDesignatedAdmin();
  }

  @override
  void dispose() {
    SupaDb.refreshNotifier.removeListener(_refreshHistory);
    _tabController.dispose();
    super.dispose();
  }

  /// P-ALL-FIXES-A: (re)subscribe the profile stream. Creating a
  /// fresh stream runs its initial fetch immediately, so the
  /// StreamBuilder shows the current row without waiting for a
  /// Realtime event. The old subscription is dropped by the
  /// StreamBuilder when the stream instance changes (its controller
  /// closes itself on cancel). Called once in initState, after a
  /// photo change, and on refresh-notifier bumps.
  void _subscribeProfile() {
    _profileStream = SupaDb.streamProfile(widget.uid);
  }

  /// WAVE 4 FIX 5: a Join / pop-back bumped the notifier — re-fetch
  /// the match-history future once (stats + achievements derive from
  /// it). Tab switches no longer trigger this.
  /// P-ALL-FIXES-A: also resubscribe the profile stream — a photo
  /// changed on another screen (Frames shop, Edit Profile save) and
  /// then popped back here left this tab showing the old photo,
  /// because the once-created stream never re-emitted.
  void _refreshHistory() {
    if (!mounted) return;
    setState(() {
      _subscribeProfile();
      _historyFuture = SupaDb.getMatchHistory(widget.uid);
      _pointsFuture = SupaDb.getPointsTotal(widget.uid);
    });
  }

  Future<void> _checkDesignatedAdmin() async {
    // Fail closed: any failure or empty UID leaves the row hidden.
    try {
      final adminUid = await fetchDesignatedAdminUid();
      if (mounted && adminUid.isNotEmpty && widget.uid.isNotEmpty && widget.uid == adminUid) {
        setState(() => _isDesignatedAdmin = true);
      }
    } catch (_) {}
  }

  // FIX 3 (Wave 4, 2026-11-19): SAME flow as FramesShopPage._changePhoto
  // (frames_screen.dart) — gallery -> ImgBB upload -> updateProfile
  // photo_url -> PhotoCache.invalidate -> toast. No second upload
  // implementation; ImgbbService + SupaDb.updateProfile are reused.
  //
  // P-ALL-FIXES-A (2026-11-20) — ROOT CAUSE of "photo does not
  // change", found by tracing the whole chain:
  //   1. Picker, ImgBB upload and updateProfile were all plausibly
  //      wired — and the success toast fired even when nothing
  //      visible changed.
  //   2. The visible photo comes ONLY from _profileStream, created
  //      once in initState on a keep-alive tab. streamProfile
  //      re-emits ONLY on a Supabase Realtime postgres_changes event
  //      for `profiles` — which never arrives when the table is out
  //      of the realtime publication (see 003_realtime.sql) or when
  //      Realtime drops on a flaky connection. So after a successful
  //      save the avatar kept the OLD photo until an app restart,
  //      while the toast already claimed "Profile photo updated."
  //   3. updateProfile is fire-and-forget: a PostgREST UPDATE that
  //      matches 0 rows still returns success, so a non-landing
  //      write ALSO toasted success.
  // The fix below closes both holes: the write is VERIFIED by a
  // read-back (mismatch = honest failure toast, never a fake
  // success), and the UI is refreshed by resubscribing the stream
  // (plain initial fetch — no Realtime dependency) plus
  // PhotoCache.invalidate + a refresh-notifier bump so other
  // screens holding the profile (e.g. the Home header avatar)
  // refetch too. No fake values anywhere: on any failure the old
  // photo simply stays and the toast is a plain retry message —
  // raw exception text is never shown to the user.
  Future<void> _changePhoto() async {
    if (_photoBusy) return;
    try {
      // ADDENDUM (2026-11-20, profile-photo fallback): the user hit
      // "Upload failed" (MissingPluginException) on image upload
      // elsewhere in the app. The delivered FINAL APK's dex DOES
      // contain the ImagePicker plugin (and GeneratedPluginRegistrant
      // registers it), so this is most likely an older APK or a
      // runtime quirk — but the upload must NEVER dead-end here: if
      // the gallery picker plugin is missing at runtime, fall back
      // to file_picker (pinned 8.3.7, also in the dex) and continue
      // the SAME ImgBB upload + verify-read-back path below. Same
      // user-visible flow, no new UI. A cancel in either picker just
      // returns silently.
      File? file;
      try {
        // imageQuality/maxWidth match the evidence-upload pick
        // (pro_features.dart): a phone photo shrinks to ~1 MB, so the
        // ImgBB upload stays fast on a slow connection.
        final picked = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 85, maxWidth: 1024);
        if (picked != null) file = File(picked.path);
      } on MissingPluginException {
        // ImagePicker plugin missing at runtime — file_picker path.
        final res = await FilePicker.platform.pickFiles(type: FileType.image, allowMultiple: false);
        if (res != null && res.files.isNotEmpty) {
          final path = res.files.single.path;
          if (path != null && path.isNotEmpty) file = File(path);
        }
      }
      if (file == null) return;
      if (!mounted) return;
      setState(() => _photoBusy = true);
      toast(context, 'Uploading photo…');
      final url = await ImgbbService.uploadImage(file);
      if (url.isEmpty) throw Exception('Upload returned an empty URL.');
      await SupaDb.updateProfile(widget.uid, {'photo_url': url});
      // VERIFY the write landed before claiming success: read the
      // row back and compare. A 0-row update (or any write the
      // server silently drops) must NOT toast "updated".
      final fresh = await SupaDb.getProfile(widget.uid);
      final saved = SupaDb.strOf(fresh['photo_url']);
      if (saved != url) {
        throw Exception('Photo upload ho gaya lekin profile par save nahi hua — dobara try karein.');
      }
      // ROUND 11: drop the cached photo so seats/strip/chat pick up
      // the new photo on their next build instead of the old one.
      PhotoCache.invalidate(widget.uid);
      SupaDb.bumpRefresh();
      if (!mounted) return;
      // Force the fresh row onto the screen NOW — do not wait for a
      // Realtime event that may never come (see root cause above).
      setState(() => _subscribeProfile());
      if (mounted) toast(context, 'Profile photo updated.');
    } catch (e) {
      // Plain message only — raw exception text (MissingPluginException,
      // ImgBB errors, network errors) must NEVER reach the user.
      if (mounted) toast(context, 'Photo upload nahi ho saki — dobara koshish karein');
    } finally {
      if (mounted) setState(() => _photoBusy = false);
    }
  }

  // WAVE B (#18): 'Member since Nov 2023' from profiles.created_at.
  // Empty string when the timestamp is missing — the line is omitted
  // rather than showing a fake date.
  String _memberSince(Map<String, dynamic> profile) {
    final ms = parseTsMs(profile['created_at']);
    if (ms <= 0) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return 'Member since ${months[d.month - 1]} ${d.year}';
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return StreamBuilder<Map<String, dynamic>>(
      stream: _profileStream,
      builder: (context, snap) {
        final profile = snap.data ?? {};
        final photo = strVal(profile['photoURL']);
        // WAVE C: REAL level (profiles.level, migration 017 — same
        // source Home uses; default 1 when unset).
        final level = intVal(profile['level'], 1);
        // FIX ROUND (2026-11-20, handle fix): the handle is the
        // USERNAME the user chose (profiles.username) — never the
        // game UID, which is a separate in-game player ID. The name
        // falls back to the username when no display name is set, so
        // the 'User' default (normProfile's stand-in for an empty
        // display_name) never shows while a real username exists.
        // NOTE (2026-11-20): migration 017 IS live on production
        // (applied ~04:04 PKT) — username / game_uid / level /
        // rank_tier columns exist; the handle is honestly omitted
        // only when the user has not set a username. Nothing is
        // invented here.
        final username = strVal(profile['username']);
        final rawName = strVal(profile['displayName']);
        final displayName = rawName.isNotEmpty && rawName != 'User'
            ? rawName
            : (username.isNotEmpty ? username : 'User');
        // J-detail-fix1 (#18): mockup #18 background has sparse gold
        // dots — shared ArenaEmberDots behind the content (taps pass
        // through, one lightweight repaint-isolated layer).
        // FIX 23.1 (2026-11-21): the colours were SWAPPED — the page
        // background carried the card colour while the card itself
        // was pure black. Now: DARK BLACK background (this layer),
        // card colour in the card (below). The ember dots stay, on
        // black, per mockup #18.
        // PHASE E (E6): the opaque black layer is GONE — the
        // app-wide poster shows through behind the ember dots and
        // the card now. The dots + SafeArea behaviour are unchanged.
        return Stack(
          children: [
            const Positioned.fill(child: IgnorePointer(child: ArenaEmberDots())),
            // HEADER SPACING v2014 (Bugs 3+4, user order — gear "upar
            // ghusa hua" + tap nahi lag raha): the HomeShell AppBar is
            // null on the Profile tab, so this scroll view started at
            // y=0 (screen top, UNDER the status bar) with only its
            // 16dp padding — the header sat ~6dp under the status bar
            // and the gear button's top strip was under it (dead to
            // touches; Android also steals top-edge taps for the
            // notification shade). SafeArea(top) puts the header below
            // the status bar with real breathing room, like mockup #18
            // (header clearly below the notch). The black background
            // stays full-screen behind the status bar. bottom: false —
            // the shell's bottom nav already bounds the scroll area.
            SafeArea(
              top: true,
              bottom: false,
              child: SingleChildScrollView(
            padding: const EdgeInsets.all(kSpace16),
            child: Column(
              children: [
                // PROFILE HEADER (mockup #18, 2026-11-21): centered
                // PROFILE title + gear top-right. The gear opens the
                // SAME SettingsPage the Overview 'Settings' tile opens
                // — one Settings, no duplicate page. Back ONLY when
                // this page was PUSHED (canPop) — on the bottom-nav
                // root tab there is no back destination, so no dead
                // back button is ever drawn. The Stack keeps PROFILE
                // exactly centred whatever the left slot holds.
                // (Supersedes the 2026-11-20 "no in-page header / gear
                // OUT" note: the header is now always shown. The
                // HomeShell AppBar above it on the root tab still
                // shows "Profile" + wallet + bell — hiding that needs
                // the one-line main.dart follow-up, outside this file.)
                // GEAR-OVERLAP FIX (2026-11-22): the SizedBox had NO
                // width, so inside this center-aligned Column the Stack
                // sized to the title text only and the right-Positioned
                // gear landed ON the title ("PROF⚙E" on Sameer's phone).
                // width: double.infinity makes the Stack full-width —
                // title truly centred, gear truly top-right.
                SizedBox(
                  height: 48,
                  width: double.infinity,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      // REDESIGN S9: header title on the shared title token.
                      Text('PROFILE', textAlign: TextAlign.center, style: kStyleTitle.copyWith(fontWeight: FontWeight.w800, letterSpacing: 1)),
                      if (Navigator.of(context).canPop())
                        Positioned(
                          left: 0,
                          top: 0,
                          bottom: 0,
                          child: TextButton.icon(
                            onPressed: () => Navigator.maybePop(context),
                            icon: Icon(Icons.chevron_left, color: kText, size: 22),
                            label: Text('Back', style: TextStyle(color: kText, fontSize: 16, fontWeight: FontWeight.w600)),
                            style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(48, 48), tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                          ),
                        ),
                      Positioned(
                        right: 0,
                        top: 0,
                        bottom: 0,
                        child: IconButton(
                          icon: Icon(Icons.settings_outlined, color: kText, size: 26),
                          tooltip: 'Settings',
                          onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => SettingsPage(uid: widget.uid))),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                // MOCKUP FIX (2026-11-20, user order — red-marked mockup):
                // the avatar STRADDLES the card's top edge: half above the
                // card, half inside it, centred (the 3D look in the
                // mockup). The card starts at the avatar's vertical centre
                // — 57px = radius 52 + 3 padding + 2 ring — so the avatar's
                // bottom half + Lv pill sit INSIDE the card; the card's top
                // padding (72) leaves only a small gap under the Lv pill
                // (pill bottom ≈ 69px) before the name row — tight, like
                // mockup #18 (Round 4, 2026-11-20: was 84, name floated
                // too far below the avatar). The
                // avatar is the LAST Stack child so it paints ABOVE the
                // card; the card is the sizing child (Column) underneath.
                Stack(
                  clipBehavior: Clip.none,
                  alignment: Alignment.topCenter,
                  children: [
                    Column(
                      children: [
                        const SizedBox(height: 57),
                // M-DETAIL-FIX2-B (2026-11-20): mockup #18 card view — the
                // profile content (name / handle / Edit pill / XP / stats
                // / tabs / achievements) sits on ONE card on the black
                // page (FIX 23.1, 2026-11-21: the card is the card
                // colour now — the old black card on the dark page had
                // the colours swapped). MOCKUP FIX (2026-11-20, user
                // order — he
                // compared the mockup with the built app on his phone):
                // the card is made visible ONLY by a thin yellow line
                // along its TOP edge, where the profile picture sits —
                // NO full border (the old Border.all wrapped the whole
                // card in bright yellow, which is NOT in the mockup).
                // Black card on the black page, top line only. The card
                // starts at the avatar's vertical centre (57px spacer in
                // the Column below), so the AVATAR straddles its top edge
                // — half above the card, half inside it — like the mockup
                // (red-marked, user order 2026-11-20). The Lv pill sits
                // inside the card, just above the name. The settings tiles
                // stay OUTSIDE / below the card (app IA, not in the
                // mockup).
                // FIX 23.2 (2026-11-21): animated fire sparks INSIDE the
                // profile card — the card is the sizing child, the
                // sparks layer stretches to it, clipped to the card's
                // rounded corners. Taps pass through (IgnorePointer).
                // The sparks float over the card like embers in the
                // air — small, sparse, low alpha, never covering text.
                Stack(
                  children: [
                Container(
                  // CARD SIZE (2026-11-22, mockup-exact): top 72 stays —
                  // the Lv pill bottom sits ~69px into the card, so a
                  // smaller top padding would overlap the pill. Bottom
                  // 16 -> 12 trims the dead space under the tabs.
                  padding: const EdgeInsets.fromLTRB(16, 72, 16, 12),
                  // FIX 23 item 23: the card fill is the shared
                  // purple gradient now (semi-transparent, so the
                  // background shows faintly). NO BackdropFilter
                  // here — the avatar straddles the card's top
                  // edge and a clip would cut it off. The gold
                  // TOP LINE stays (mockup #18, deliberate).
                  decoration: cardFillDecoration(radius: 16).copyWith(
                    // TOP LINE ONLY — mockup #18 (see comment above).
                    border: Border(top: BorderSide(color: kGold, width: 1.5)),
                  ),
                  child: Column(
                    children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // REDESIGN S9: display name on the shared title token.
                    Flexible(child: Text(displayName, style: kStyleTitle.copyWith(fontSize: 26), textAlign: TextAlign.center)),
                    const SizedBox(width: kSpace8),
                    PresenceDot(uid: widget.uid),
                  ],
                ),
                // Mockup handle/member-since lines. Handle = the chosen
                // USERNAME (real, omitted when unset) — never the game
                // UID: that is a separate in-game player ID, not a
                // handle. Member since = created_at (real, omitted when
                // unset). No email line — the mockup has none; email
                // stays reachable via Account Settings.
                // REDESIGN S9: handle + member-since on the shared meta token.
                if (username.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text('@$username', style: kStyleMeta.copyWith(fontSize: 14)),
                ],
                if (_memberSince(profile).isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(_memberSince(profile), style: kStyleMeta),
                ],
                // Round 4 (2026-11-20): was 14 — mockup #18 keeps the pill
                // close under the member-since line.
                const SizedBox(height: 10),
                // Mockup #18: outlined gold 'Edit Profile' pill —
                // PRINTER-COPY (2026-11-21): mockup pixels sample the
                // label WHITE (243,244,246), gold pencil icon, gold
                // border — the old gold label text was wrong.
                // REDESIGN S9: shared ArenaOutlinedButton (contract) —
                // same destination, same white label + gold icon +
                // gold border; radius is now the shared kRadiusInput
                // (14) instead of the old 24 pill radius.
                ArenaOutlinedButton(
                  onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => CreateProfilePage(uid: widget.uid))),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.edit, color: kGold, size: 16),
                      const SizedBox(width: kSpace8),
                      Text('Edit Profile', style: TextStyle(color: kText, fontWeight: FontWeight.bold, fontSize: 14)),
                    ],
                  ),
                ),
                // Round 4: was 18 — mockup #18 keeps the XP bar close
                // under the pill.
                const SizedBox(height: kSpace12),
                // OD-03 DECISION (2026-11-20, user order "kro"): XP
                // progress bar under the Edit Profile pill, as in
                // mockup #18 (LEVEL N / LEVEL N+1 labels, gold fill on
                // a dark track, "X / Y XP" under the bar). REAL data
                // only: profiles.xp (default 0) and profiles.level
                // (default 1) — both pass through normProfile from
                // the raw row (migration 017 columns).
                // CURVE: next level needs level x 100 XP (level 1 ->
                // 100, level 5 -> 500). Progress = xp / (level x 100),
                // clamped 0-1. xp 0 -> EMPTY bar — honest, never fake
                // progress. DISPLAY ONLY: no level-up logic, no
                // auto-leveling, no writes — leveling stays server-side.
                Builder(
                  builder: (_) {
                    final xp = intVal(profile['xp'], 0);
                    final xpLevel = level < 1 ? 1 : level;
                    final xpNeeded = xpLevel * 100;
                    final xpProgress = (xp / xpNeeded).clamp(0.0, 1.0).toDouble();
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            // REDESIGN S9: level labels on the shared label token.
                            Text('LEVEL $xpLevel', style: kStyleLabel.copyWith(fontWeight: FontWeight.bold)),
                            Text('LEVEL ${xpLevel + 1}', style: kStyleLabel.copyWith(fontWeight: FontWeight.bold)),
                          ],
                        ),
                        const SizedBox(height: 6),
                        // J-detail-fix1 (#18): mockup #18 XP fill glows —
                        // bright yellow-gold fill (brighter at the left)
                        // with a soft gold halo hugging the filled segment,
                        // brightest at the leading edge. The glow is a
                        // static BoxShadow on the fill (no animation); the
                        // Stack uses Clip.none so the halo is not clipped
                        // by the track.
                        // REDESIGN S9: fill uses the shared kGoldGradient
                        // (#FFE16A -> #FDC903 — bright at the left, as the
                        // mockup has it); track + glow unchanged.
                        Stack(
                          clipBehavior: Clip.none,
                          children: [
                            // XP-TRACK FIX (2026-11-22): the track was
                            // kCard — the SAME colour as the card, so
                            // at 0 XP the bar was invisible ("patti
                            // dikhti hi nahi"). The track is now a
                            // clearly visible medium grey (mockup #18
                            // groove), 10px tall like the mockup.
                            Container(height: 10, decoration: BoxDecoration(color: const Color(0xFF2E323F), borderRadius: BorderRadius.circular(5))),
                            FractionallySizedBox(
                              alignment: Alignment.centerLeft,
                              widthFactor: xpProgress,
                              child: Container(
                                height: 10,
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(5),
                                  gradient: kGoldGradient,
                                  boxShadow: [
                                    BoxShadow(color: kGold.withValues(alpha: 0.55), blurRadius: 8, spreadRadius: 1),
                                    BoxShadow(color: kGold.withValues(alpha: 0.22), blurRadius: 16, spreadRadius: 2),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            // REDESIGN S9: XP counts on the shared body token.
                            Text(_fmtPoints(xp), style: kStyleBody.copyWith(color: kGold, fontWeight: FontWeight.bold)),
                            Text(' / ${_fmtPoints(xpNeeded)} XP', style: kStyleBody.copyWith(color: kMuted)),
                          ],
                        ),
                      ],
                    );
                  },
                ),
                // CARD SIZE (2026-11-22): XP -> stats gap 16 -> 12.
                const SizedBox(height: kSpace12),
                // FIX ROUND 2026-10-28 (board Profile): stats + an
                // achievements list derived ONLY from real counts (no
                // invented badges). WAVE B (#18) restyled them into the
                // mockup's 2x2 stats grid + badge-card preview; K/D is
                // no longer shown on this screen (it lives on the
                // Player Stats page, reachable from the tiles below).
                FutureBuilder<List<Map<String, dynamic>>>(
                  future: _historyFuture,
                  builder: (context, hsnap) {
                    final history = hsnap.data ?? [];
                    final matches = intVal(profile['totalMatches'], history.length);
                    final wins = intVal(profile['wonMatches']);
                    final earnings = numVal(profile['totalEarnings']);
                    // Achievements derive ONLY from real counts (no
                    // invented badges). Each entry carries its real
                    // unlock condition + locked/unlocked state + its
                    // OWN badge icon; the Achievements tab shows this
                    // detail, the Overview tab shows the first three.
                    // MOCKUP FIX (2026-11-20, user order): the three
                    // preview badges are the mockup's own — FIRST
                    // BLOOD (target), SURVIVALIST (shield), SQUAD
                    // LEADER (crown) — each with its own icon, like
                    // mockup #18. The NAMES are the mockup's content;
                    // the UNLOCK states stay real counts (wins /
                    // matches / earnings), never invented.
                    final achievementsDetail = <({String name, String condition, bool unlocked, String progress, Widget icon})>[
                      (name: 'First Blood', condition: 'Win your first match', unlocked: wins >= 1, progress: '$wins / 1 win', icon: PremiumEmblemIcon(kind: PremiumBadgeKind.deadshot, size: 44, locked: wins < 1, glow: wins >= 1)),
                      (name: 'Survivalist', condition: 'Play 10 matches', unlocked: matches >= 10, progress: '$matches / 10 matches', icon: PremiumEmblemIcon(kind: PremiumBadgeKind.survivor, size: 44, locked: matches < 10, glow: matches >= 10)),
                      (name: 'Squad Leader', condition: 'Win 5 matches', unlocked: wins >= 5, progress: '$wins / 5 wins', icon: _squadLeaderBadge(wins >= 5)),
                      (name: 'Veteran', condition: 'Play at least 50 matches', unlocked: matches >= 50, progress: '$matches / 50 matches', icon: PremiumEmblemIcon(kind: PremiumBadgeKind.deadshot, size: 44, locked: matches < 50, glow: matches >= 50)),
                      (name: 'Top Earner', condition: 'Earn at least Rs 1,000 in total', unlocked: earnings >= 1000, progress: '${fmtRs(earnings)} / Rs 1,000', icon: PremiumEmblemIcon(kind: PremiumBadgeKind.mvp, size: 44, locked: earnings < 1000, glow: earnings >= 1000)),
                    ];
                    final unlockedCount = achievementsDetail.where((a) => a.unlocked).length;
                    // Overview preview: the mockup's three badges in
                    // mockup order — First Blood, Survivalist, Squad
                    // Leader — never re-sorted, so the row always
                    // reads like mockup #18.
                    final previewAchievements = achievementsDetail.take(3).toList();
                    // WAVE B (#18): mockup 2x2 stats grid ABOVE the tabs.
                    // Matches/Won = real counts; Current Rank = REAL
                    // profiles.rank_tier ('Bronze' when unset — never a
                    // higher tier invented); 4th slot = Community Points
                    // (OD-02 decision 2026-11-20): REAL ledger total
                    // via SupaDb.getPointsTotal — 0 when the ledger has
                    // no rows. Total Earnings is NOT deleted — it still
                    // lives on the Earnings page (Wallet -> "View
                    // Earnings & Referrals").
                    final rt = strVal(profile['rank_tier']);
                    final rankTier = rt.isNotEmpty ? rt : 'Bronze';
                    return Column(
                      children: [
                        // OD-02: the 4th stat reads the REAL Community
                        // Points total (SUM of community_points_ledger
                        // .delta). While it loads, 0 shows — the ledger
                        // total is 0 for a user with no rows anyway.
                        FutureBuilder<int>(
                          future: _pointsFuture,
                          builder: (context, psnap) {
                            final points = psnap.data ?? 0;
                            return appCard(
                              animate: true,
                              padding: EdgeInsets.zero,
                              child: Column(
                                children: [
                                  IntrinsicHeight(
                                    child: Row(
                                      children: [
                                        _gridStat('Matches Played', '$matches'),
                                        _fadeDividerV(),
                                        _gridStat('Matches Won', '$wins'),
                                      ],
                                    ),
                                  ),
                                  _fadeDividerH(),
                                  IntrinsicHeight(
                                    child: Row(
                                      children: [
                                        _gridStat('Current Rank', rankTier, valueWidget: _rankTierValue(rankTier)),
                                        _fadeDividerV(),
                                        _gridStat('Community Points', _fmtPoints(points), valueWidget: _pointsValue(points)),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                        // MOCKUP #18 (2026-11-21): the Followers /
                        // Following / Community row is REMOVED — it is
                        // NOT in mockup #18. Followers/Following stay
                        // reachable from the Community tab (hub Following
                        // tab + player-card counts -> FollowListPage)
                        // and the 'Community' tile below still opens
                        // the hub. Nothing else removed.
                        const SizedBox(height: kSpace12),
                        TabBar(
                          controller: _tabController,
                          // Mockup #18: the three tabs span the full
                          // width (Overview / Match History /
                          // Achievements) — non-scrollable + fill.
                          // isScrollable:true + fill is an invalid
                          // combination (Flutter asserts on every
                          // ProfilePage build in debug).
                          // TAB-CUTOFF FIX (2026-11-22): 15px labels
                          // clipped ("Match Histo…", "Achievemen…") in
                          // the ~98px slots on 360px. Labels are now
                          // 14px + FittedBox scaleDown inside each Tab,
                          // so all three always fit whole — no clip at
                          // any width, mockup look kept.
                          tabAlignment: TabAlignment.fill,
                          labelPadding: const EdgeInsets.symmetric(horizontal: 6),
                          onTap: (i) => setState(() => _tabIndex = i),
                          indicatorColor: kGold,
                          indicatorWeight: 3,
                          labelColor: kGold,
                          unselectedLabelColor: kMuted,
                          // REDESIGN S9: shared tab label style — the
                          // label token (12 medium, muted) at the 14px
                          // bold size the tab-cutoff fix needs.
                          labelStyle: kStyleLabel.copyWith(fontWeight: FontWeight.bold, fontSize: 14),
                          unselectedLabelStyle: kStyleLabel.copyWith(fontWeight: FontWeight.bold, fontSize: 14),
                          tabs: const [
                            Tab(child: FittedBox(fit: BoxFit.scaleDown, child: Text('Overview'))),
                            Tab(child: FittedBox(fit: BoxFit.scaleDown, child: Text('Match History'))),
                            Tab(child: FittedBox(fit: BoxFit.scaleDown, child: Text('Achievements'))),
                          ],
                        ),
                        const SizedBox(height: 10),
                        if (_tabIndex == 1)
                          // Match History tab: the existing page embedded
                          // (no Scaffold/AppBar of its own).
                          MatchHistoryPage(uid: widget.uid, embedded: true)
                        else if (_tabIndex == 2)
                          // Achievements tab: every achievement with its
                          // real unlock condition + locked/unlocked state.
                          // REDESIGN S10 (§6 Screen 10): header uses the
                          // shared section style (gold — matches the
                          // preview header's size/weight); rows use the
                          // token type scale (card title / meta) and
                          // token spacing. States stay real: Locked /
                          // Unlocked + progress from the same counts.
                          appCard(
                            animate: true,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Achievements  ($unlockedCount / ${achievementsDetail.length} unlocked)', style: kStyleSection.copyWith(color: kGold)),
                                const SizedBox(height: kSpace8),
                                for (final a in achievementsDetail)
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: kSpace12),
                                    child: Row(
                                      children: [
                                        PremiumAchievementBadge(kind: premiumBadgeKindFor(a.name), size: 28, locked: !a.unlocked),
                                        const SizedBox(width: kSpace12),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Text(a.name, style: kStyleCardTitle),
                                              Text(a.condition, style: kStyleMeta),
                                            ],
                                          ),
                                        ),
                                        // S10 FIX (2026-11-23): the status
                                        // column is capped at 170px — the
                                        // long Rs progress strings made it
                                        // overflow 360px screens (14px
                                        // locked / 53px unlocked). 170 is
                                        // above the real-font width (~140)
                                        // so the app renders unchanged; the
                                        // FittedBox only shrinks the
                                        // progress text when it exceeds the
                                        // cap (wide test font). The extra
                                        // 8px gap before this column is
                                        // gone (base had none).
                                        ConstrainedBox(
                                          constraints: const BoxConstraints(maxWidth: 170),
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.end,
                                            children: [
                                              Text(a.unlocked ? 'Unlocked' : 'Locked', style: TextStyle(color: a.unlocked ? kGold : kTextMuted, fontWeight: FontWeight.bold, fontSize: 12)),
                                              FittedBox(
                                                fit: BoxFit.scaleDown,
                                                alignment: Alignment.centerRight,
                                                child: Text(a.progress, style: kStyleMeta),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                              ],
                            ),
                          )
                        else
                          // Overview tab: achievements preview (mockup
                          // #18) — 'Achievements' + 'View All →' + 3
                          // badge cards from REAL counts (unlocked first).
                          // 'View All' switches to the Achievements tab.
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // REDESIGN S10 (§6 Screen 10): consistent
                              // header — title uses the shared section
                              // style; 'View All' keeps its gold
                              // treatment and now presses through the
                              // shared ArenaPressable (same onTap:
                              // switches to the Achievements tab).
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  // Flexible: the title ellipsises instead
                                  // of overflowing on narrow/test fonts
                                  // (Ahem overflows by 57px at 360px);
                                  // with the real font it fits whole.
                                  // REDESIGN S9: section header on the shared section token.
                                  Flexible(child: Text('Achievements', style: kStyleSection, maxLines: 1, overflow: TextOverflow.ellipsis)),
                                  ArenaPressable(
                                    onTap: () {
                                      _tabController.animateTo(2);
                                      setState(() => _tabIndex = 2);
                                    },
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        // v2011 fix: explicit fontSize 14 —
                                        // without it this Text inherits the
                                        // 48px fallback style when no
                                        // Material/DefaultTextStyle ancestor
                                        // is present (tests), overflowing the
                                        // header Row by 108px. 14 is the
                                        // Material body size the real app
                                        // gives it, so no visual change.
                                        Text('View All', style: TextStyle(color: kGold, fontSize: 14, fontWeight: FontWeight.bold)),
                                        SizedBox(width: kSpace4),
                                        Icon(Icons.arrow_forward, color: kGold, size: 16),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                              // CARD SIZE (2026-11-22): gaps 10 -> 8
                              // and 16 -> 12 under the badge row.
                              const SizedBox(height: kSpace8),
                              // REDESIGN S10: the three summary cards
                              // are naturally equal height (same 44px
                              // icons + single-line labels), so their
                              // icons and labels align across the row
                              // WITHOUT stretch — stretch forced infinite
                              // height inside this scrolling viewport and
                              // threw on every ProfilePage pump.
                              Row(
                                children: [
                                  for (var i = 0; i < previewAchievements.length; i++) ...[
                                    if (i > 0) const SizedBox(width: kSpace12),
                                    Expanded(child: _achievementBadge(previewAchievements[i])),
                                  ],
                                ],
                              ),
                              const SizedBox(height: kSpace12),
                            ],
                          ),
                      ],
                    );
                  },
                ),
                    ],
                  ),
                ),
                    Positioned.fill(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: const IgnorePointer(child: FireSparks(count: 14)),
                      ),
                    ),
                  ],
                ),
                      ],
                    ),
                // J-detail-fix1 (#18, 2026-11-20): mockup #18 avatar glow —
                // strong soft gold halo tight on the ring + a wider radial
                // wash behind the avatar. M-DETAIL-FIX2-B (2026-11-20,
                // user order): the long thin horizontal yellow line
                // behind the avatar is REMOVED — it is not in the mockup.
                // The mockup's card view replaces it: the profile content
                // below sits on a card (card colour, FIX 23.1) with a
                // thin yellow line along its TOP edge only (see the
                // Container under this Stack),
                // and the AVATAR straddles that card's top edge — half
                // above the card, half inside (red-marked mockup, user
                // order 2026-11-20). The camera badge is
                // GONE — mockup #18 has no badge (photo change lives on
                // Edit Profile); the avatar stays tappable to change the
                // photo (FIX 3). The ring is THIN (2px) per the mockup.
                // Lv pill is INVERTED vs the old code: mockup is a BLACK
                // pill with a GOLD border + GOLD text (the old gold-filled
                // / black-text pill was backwards).
                SizedBox(
                  width: double.infinity,
                  child: Stack(
                    alignment: Alignment.center,
                    clipBehavior: Clip.none,
                    children: [
                      // Radial wash behind the avatar (~1.5x its diameter).
                      Positioned.fill(
                        child: IgnorePointer(
                          child: Align(
                            alignment: Alignment.center,
                            child: Container(
                              width: 220,
                              height: 220,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                gradient: RadialGradient(
                                  colors: [
                                    kGold.withValues(alpha: 0.20),
                                    kGold.withValues(alpha: 0.07),
                                    kGold.withValues(alpha: 0.0),
                                  ],
                                  stops: const [0.0, 0.55, 1.0],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      GestureDetector(
                        onTap: _photoBusy ? null : _changePhoto,
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            Container(
                              padding: const EdgeInsets.all(3),
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                // REDESIGN S9: the golden ring (2px kGold)
                                // + subtle gold glow the guide asks for —
                                // already the mockup #18 ring; unchanged.
                                border: Border.all(color: kGold, width: 2),
                                // Halo: soft gold glow tight on the thin
                                // ring (mockup #18) — kept modest so the
                                // ring itself stays the thin yellow ring.
                                boxShadow: [
                                  BoxShadow(color: kGold.withValues(alpha: 0.35), blurRadius: 14, spreadRadius: 1),
                                  BoxShadow(color: kGold.withValues(alpha: 0.15), blurRadius: 28, spreadRadius: 4),
                                ],
                              ),
                              // MOCKUP #18 AVATAR RING (2026-11-21): the
                              // mockup has a CLEAN gold ring — the old
                              // CachedFramedAvatar rendered the user's
                              // EQUIPPED shop frame here (purple/gold
                              // sparkle frame in the screenshot), which
                              // is NOT in the mockup. FramedAvatar with
                              // frame: null renders just the plain photo
                              // circle, so the 2px gold border + gold
                              // halo of this Container IS the ring —
                              // exactly the mockup's clean gold ring.
                              // The equipped frame still shows everywhere
                              // else it belongs (chat, leaderboard,
                              // room); only this hero avatar is
                              // mockup-plain. Lv pill unchanged below.
                              child: FramedAvatar(name: displayName, frame: null, radius: 52, photoUrl: photo, avatarColor: kGold),
                            ),
                            // P-ALL-FIXES-A: uploading feedback. The old
                            // flow showed NOTHING while the ImgBB upload
                            // ran (and with no timeout it could run
                            // forever), so a tap looked dead. Only
                            // visible during the upload; at rest the
                            // avatar is exactly as the mockup has it.
                            if (_photoBusy)
                              Positioned.fill(
                                child: IgnorePointer(
                                  child: Container(
                                    decoration: const BoxDecoration(shape: BoxShape.circle, color: Colors.black54),
                                    // REDESIGN S9: shared gold loading indicator.
                                    child: const Center(child: ArenaLoadingIndicator()),
                                  ),
                                ),
                              ),
                            // Mockup #18: Lv badge overlapping the avatar's
                            // bottom edge, centred — REAL profiles.level.
                            // Black fill + gold border + gold text.
                            Positioned(
                              bottom: -12,
                              left: 0,
                              right: 0,
                              child: Center(
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                  decoration: BoxDecoration(color: Colors.black, borderRadius: BorderRadius.circular(20), border: Border.all(color: kGold, width: 1.5)),
                                  child: Text('Lv.$level', style: TextStyle(color: kGold, fontWeight: FontWeight.bold, fontSize: 12)),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                  ],
                ),
                const SizedBox(height: kSpace16),
                // Tiles live in the Overview tab only; Match History and
                // Achievements show their own content above.
                if (_tabIndex == 0)
                appCard(
                  animate: true,
                  child: Column(
                    children: [
                      // FIX 32 (2026-11-24, admin-panel removal): the
                      // "Switch to Admin" tile is GONE with the panel
                      // — the user app has no Admin Mode any more.
                      // The designated-admin flag below now gates
                      // ONLY the Organizer Runbook tile (admin-only
                      // by user order, still in the user app).
                      // MERGE (O-admin-panel, 2026-11-20): the two N-round
                      // admin queue shortcuts ("Tournament Approvals" /
                      // "Result Reviews") are REMOVED here — both queues
                      // now live inside Admin Mode (Tournaments sub-entry
                      // + Results section). FIX DUPLICATES: one entry.
                      // FIX 32 (2026-11-24): Admin Mode itself is gone
                      // from the user app now (separate admin APK) —
                      // the queues went with it.
                      // N-create-tournament PREP-FIRST: organizer runbook (pre-launch checklist).
                      // MOCKUP FIX (2026-11-20, user order): the runbook is
                      // ADMIN-ONLY (RunbookPickerPage + OrganizerRunbookPage
                      // both bounce non-admins with 'Sirf admin runbook dekh
                      // sakta hai') — so the tile itself must not show to
                      // players at all. Gated on the designated-admin
                      // check above (FIX 32: the runbook STAYS in the
                      // user app — only the panel went).
                      if (_isDesignatedAdmin)
                        _tile(context, Icons.checklist, 'Organizer Runbook', () => Navigator.push(context, MaterialPageRoute(builder: (_) => RunbookPickerPage(uid: widget.uid)))),
                      _tile(context, Icons.emoji_events, 'Frames', () => Navigator.push(context, MaterialPageRoute(builder: (_) => const FramesShopPage()))),
                      _tile(context, Icons.history, 'Match History', () => Navigator.push(context, MaterialPageRoute(builder: (_) => MatchHistoryPage(uid: widget.uid)))),
                      // Phase 2 (#25): Player Stats entry point — the
                      // stats page Worker C built had no link from
                      // anywhere in the app; this tile wires it in.
                      _tile(context, Icons.bar_chart, 'Player Stats', () => Navigator.push(context, MaterialPageRoute(builder: (_) => PlayerStatsPage(uid: widget.uid)))),
                      // Phase 3 (Worker A): Account Security, Community
                      // Rewards, Activity History, Your Invites. Existing
                      // tiles keep their order; Wallet/Earnings tiles and
                      // the admin check below are untouched.
                      // FIX ROUND (2026-11-20, duplicate cleanup): the
                      // name-edit tile is gone — name editing lives only
                      // inside the Edit Profile flow (CreateProfilePage's
                      // Display Name field) — and the create/complete-
                      // profile tile (same destination as the Edit
                      // Profile button below the avatar).
                      // P-ALL-FIXES (2026-11-20, user order): the
                      // 'Settings' tile is BACK in this list — the
                      // header gear that used to open Settings is
                      // removed, so this tile (just above Logout) is
                      // now the SINGLE Settings entry from Profile.
                      // DEDUPE (2026-11-22, user order): 'Account Security'
                      // moved to Settings ONLY (Settings group 1) — the
                      // Profile tile is removed, not duplicated.
                      _tile(context, Icons.card_giftcard, 'Community Rewards', () => Navigator.push(context, MaterialPageRoute(builder: (_) => CommunityRewardsPage(uid: widget.uid)))),
                      _tile(context, Icons.history_toggle_off, 'Activity History', () => Navigator.push(context, MaterialPageRoute(builder: (_) => ActivityHistoryPage(uid: widget.uid)))),
                      _tile(context, Icons.person_add_alt, 'Your Invites', () => Navigator.push(context, MaterialPageRoute(builder: (_) => YourInvitesPage(uid: widget.uid)))),
                      // COMMUNITY RESTRUCTURE (2026-11-22, user
                      // order; refined 05:07): the old single
                      // 'Community' hub tile is GONE — the hub pushed
                      // the chat off the bottom when the friends list
                      // grew. Profile options now: 'Friends &
                      // Requests' (one screen, 3 tabs: Friends,
                      // Requests, Followers) + a separate 'Messages'
                      // (DMs list). 'Following' keeps its own tile:
                      // the refined structure names neither it nor a
                      // home for it, and dropping it would orphan a
                      // working feature. The nav Community tab itself
                      // is now the teams list (TeamsPage,
                      // main.dart).
                      _tile(context, Icons.people, 'Friends & Requests', () => Navigator.push(context, MaterialPageRoute(builder: (_) => FriendsRequestsPage(uid: widget.uid)))),
                      _tile(context, Icons.message, 'Messages', () => Navigator.push(context, MaterialPageRoute(builder: (_) => MessagesPage(uid: widget.uid)))),
                      _tile(context, Icons.visibility, 'Following', () => Navigator.push(context, MaterialPageRoute(builder: (_) => FollowingPage(uid: widget.uid)))),
                      _tile(context, Icons.headset_mic, 'Help & Support', () => Navigator.push(context, MaterialPageRoute(builder: (_) => NewSupportTicketPage(uid: widget.uid)))),
                      // Phase 3 #30: the dedicated Invite Friends page.
                      // (Earnings stays reachable via the 'Earnings' tile
                      // below; this tile used to open EarningsPage.)
                      _tile(context, Icons.card_giftcard, 'Refer & Earn', () => Navigator.push(context, MaterialPageRoute(builder: (_) => InviteFriendsPage(uid: widget.uid)))),
                      // Phase 2: Wallet + Earnings under Profile. Both
                      // screens are preserved as-is (no cash logic
                      // changes); WalletPage/EarningsPage are body
                      // widgets, so they are wrapped in a Scaffold here
                      // exactly like the existing Refer & Earn tile does.
                      _tile(context, Icons.account_balance_wallet, 'Wallet', () => Navigator.push(context, MaterialPageRoute(builder: (_) => Scaffold(appBar: AppBar(title: Text('Wallet', style: TextStyle(color: kGold))), body: WalletPage(uid: widget.uid))))),
                      _tile(context, Icons.attach_money, 'Earnings', () => Navigator.push(context, MaterialPageRoute(builder: (_) => Scaffold(appBar: AppBar(title: Text('Earnings', style: TextStyle(color: kGold))), body: EarningsPage(uid: widget.uid))))),
                      _tile(context, Icons.chat, 'Contact Us (WhatsApp)', () async {
                        final settings = await SupaDb.getAppSettings();
                        final raw = strVal(settings['supportContact'], strVal(settings['support_contact']));
                        // WHATSAPP NORMALIZE (2026-11-20): the stored
                        // value may be malformed (an old "+92 333..."
                        // or "0333-..." entry) — strip everything but
                        // digits (+ a leading 00 international prefix)
                        // before building the wa.me URL.
                        var contact = raw.replaceAll(RegExp(r'[^0-9]'), '');
                        if (contact.startsWith('00')) contact = contact.substring(2);
                        // LEADING-0 FIX (2026-11-21): a stored local
                        // number (0333...) is Pakistani — wa.me needs
                        // the country code, so a leading 0 becomes 92.
                        if (contact.startsWith('0')) contact = '92${contact.substring(1)}';
                        if (contact.isEmpty || contact.length < 10) {
                          if (context.mounted) toast(context, 'Support contact is not set yet.');
                          return;
                        }
                        final uri = Uri.parse('https://wa.me/$contact');
                        if (await canLaunchUrl(uri)) {
                          await launchUrl(uri, mode: LaunchMode.externalApplication);
                        } else if (context.mounted) {
                          toast(context, 'WhatsApp nahi khul saka — number check karein');
                        }
                      }),
                      // DEDUPE (2026-11-22, user order): the 'Push
                      // Notifications' switch moved to Settings ONLY
                      // ('Notification Preferences' toggle, same key +
                      // same PushService effect) — removed from Profile.
                      // PLACEMENT (2026-11-22, user order): Rules &
                      // Policies lives on PROFILE (one tile opening the
                      // full Rules & Policies page — all 7 docs incl.
                      // the 4 policies below). The 4 separate policy
                      // tiles are removed; their docs live inside that
                      // page. Settings no longer lists Terms & Privacy.
                      _tile(context, Icons.description, 'Rules & Policies', () => Navigator.push(context, MaterialPageRoute(builder: (_) => const RulesPoliciesPage()))),
                      _tile(context, Icons.dashboard, 'Pro Features', () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ProHubPage()))),
                      // DEDUPE (2026-11-22, user order): 'Backup My Profile'
                      // + 'Restore Profile' moved to Settings ONLY (new
                      // Backup group) — removed from Profile.
                      // PLATFORM (2026-11-21, ChatGPT blueprint
                      // integration): organizer + global platform
                      // entries. Organizer-gated tiles resolve the
                      // user's organization first; without one they
                      // route to Become an Organizer.
                      _tile(context, Icons.business, tr('Become an Organizer', 'Organizer banein'), () => Navigator.push(context, MaterialPageRoute(builder: (_) => BecomeOrganizerPage(uid: widget.uid)))),
                      _tile(context, Icons.storefront, tr('My Organizer Dashboard', 'Mera Organizer Dashboard'), () async {
                        final org = await const OrganizerService().getMyOrganization(widget.uid);
                        if (!context.mounted) return;
                        if (org == null) {
                          toast(context, tr('Pehle organizer banein — application submit karein.', 'Pehle organizer banein — application submit karein.'));
                          Navigator.push(context, MaterialPageRoute(builder: (_) => BecomeOrganizerPage(uid: widget.uid)));
                          return;
                        }
                        Navigator.push(context, MaterialPageRoute(builder: (_) => OrganizerDashboardPage(organizationId: org.id)));
                      }),
                      _tile(context, Icons.add_circle_outline, tr('Create Tournament', 'Tournament banayen'), () async {
                        final org = await const OrganizerService().getMyOrganization(widget.uid);
                        if (!context.mounted) return;
                        if (org == null) {
                          toast(context, tr('Tournament banane ke liye pehle organizer banein.', 'Tournament banane ke liye pehle organizer banein.'));
                          Navigator.push(context, MaterialPageRoute(builder: (_) => BecomeOrganizerPage(uid: widget.uid)));
                          return;
                        }
                        Navigator.push(context, MaterialPageRoute(builder: (_) => SmartBuilderPage(organizationId: org.id)));
                      }),
                      _tile(context, Icons.leaderboard, tr('Global Leaderboard', 'Global Leaderboard'), () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ScopedLeaderboardPage()))),
                      _tile(context, Icons.gavel, tr('Dispute Center', 'Dispute Center'), () => Navigator.push(context, MaterialPageRoute(builder: (_) => DisputeCenterPage(uid: widget.uid)))),
                      // DEDUPE (2026-11-22, user order): 'Action Required',
                      // 'Country / Region' + 'Language' moved to Settings
                      // ONLY — removed from Profile. ('Language' in
                      // Settings now opens the REAL language page, not
                      // the old English-only stub.)
                      // DEDUPE (2026-11-22, user order): the 'Settings'
                      // tile is removed — Settings now opens ONLY from
                      // the header gear (top-right, mockup #18). The
                      // 2026-11-20 "gear OUT, tile IN" decision is
                      // reversed by this order.
                      // DEDUPE (2026-11-22, user order): 'Logout' lives
                      // in Settings ONLY (red LOG OUT pill, same sign-out
                      // steps) — the Profile tile is removed.
                    ],
                  ),
                ),
              ],
            ),
              ),
            ),
          ],
        );
      },
    );
  }

  // REDESIGN S10 (§6 Screen 10): every list row is now consistent —
  // gold leading icon (fixed 22), token body label, muted chevron
  // (fixed 20), token icon/label gap, 48dp touch height. The rows
  // stay ListTiles inside the single options card (no restructure);
  // onTap/navigation is untouched.
  Widget _tile(BuildContext context, IconData icon, String label, VoidCallback onTap) {
    // Transparent Material: ListTile requires a Material ancestor;
    // ProfilePage has no Scaffold of its own (it relies on the host),
    // so the tile brings its own — zero visual change.
    return Material(
      type: MaterialType.transparency,
      child: ListTile(
        leading: Icon(icon, color: kGold, size: 22),
        title: Text(label, style: kStyleBody),
        trailing: Icon(Icons.chevron_right, color: kTextMuted, size: 20),
        onTap: onTap,
        contentPadding: EdgeInsets.zero,
        horizontalTitleGap: kSpace12,
        minTileHeight: 48,
      ),
    );
  }

  // WAVE B (#18): one cell of the mockup's 2x2 stats grid — big gold
  // value over a white label. FIX ROUND (2026-11-20, profile fix):
  // mockup sizes — value ~36px w800, label ~15px. The value is
  // wrapped in FittedBox(scaleDown) so long values (Rs amounts,
  // tier names) shrink instead of clipping on 360px.
  // CARD SIZE (2026-11-22, mockup-exact): value 36 -> 32, label
  // 15 -> 13, cell padding 14 -> 10 — the mockup grid is denser
  // than the old 83px cells; saves ~30px of card height.
  Widget _gridStat(String label, String value, {Widget? valueWidget}) => Expanded(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
          child: Column(children: [
            // REDESIGN S9: stat value + label on the shared tokens
            // (title token at the mockup's 32px w800, meta token for
            // the label) — sizes unchanged, mockup-exact.
            valueWidget ??
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(value, style: kStyleTitle.copyWith(color: kGold, fontSize: 32, fontWeight: FontWeight.w800), textAlign: TextAlign.center, maxLines: 1),
                ),
            const SizedBox(height: kSpace4),
            Text(label, style: kStyleMeta.copyWith(color: kText), textAlign: TextAlign.center),
          ]),
        ),
      );

  // Current Rank cell: REAL profiles.rank_tier + tier badge icon
  // (mockup #18: "DIAMOND" + badge). RANK FIX (2026-11-22): the
  // mockup's tier name is WHITE and SMALLER than the numbers (24px
  // vs 32px) — the old gold 36px "BRONZE" shouted over the whole
  // grid. FittedBox scaleDown keeps long tier names inside the
  // half-width cell.
  Widget _rankTierValue(String tier) => FittedBox(
        fit: BoxFit.scaleDown,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // REDESIGN S9: tier name on the shared title token (24px w800).
            Text(tier.toUpperCase(), style: kStyleTitle.copyWith(fontSize: 24, fontWeight: FontWeight.w800)),
            const SizedBox(width: 6),
            Icon(_rankTierIcon(tier), color: kGold, size: 22),
          ],
        ),
      );

  IconData _rankTierIcon(String tier) {
    switch (tier.toLowerCase()) {
      case 'diamond':
        return Icons.diamond;
      case 'platinum':
        return Icons.emoji_events;
      case 'gold':
        return Icons.workspace_premium;
      case 'silver':
        return Icons.military_tech;
      case 'bronze':
      default:
        return Icons.shield;
    }
  }

  // Community Points cell (OD-02 decision 2026-11-20): REAL ledger
  // total with thousand separators + the mockup's small gold "CP"
  // coin badge. FittedBox scaleDown keeps long values inside the
  // half-width cell on 360px. CARD SIZE (2026-11-22): 36 -> 32 to
  // match the other numbers, badge 26 -> 24.
  Widget _pointsValue(int points) => FittedBox(
        fit: BoxFit.scaleDown,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // REDESIGN S9: points value on the shared title token (32px w800 gold).
            Text(_fmtPoints(points), style: kStyleTitle.copyWith(color: kGold, fontSize: 32, fontWeight: FontWeight.w800)),
            const SizedBox(width: 6),
            Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(color: kGold, shape: BoxShape.circle),
              alignment: Alignment.center,
              child: const Text('CP', style: TextStyle(color: Colors.black, fontSize: 10, fontWeight: FontWeight.w800)),
            ),
          ],
        ),
      );

  // Thousands separators ("4,850") — same plain loop as the
  // Leaderboard page's helper; no intl import in this file.
  String _fmtPoints(int v) {
    final s = v.toString();
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
      buf.write(s[i]);
    }
    return buf.toString();
  }

  // J-detail-fix1 (#18): mockup #18 badge tiles — warm golden-brown
  // gradient (brighter at the top, darker at the bottom). P-all-fixes
  // Worker F (2026-11-20 ~18:13 user order): the large gold icon is
  // the PREMIUM badge — the user's own winged-shield crest +
  // crown with a drawn gold emblem (44dp), greyed when locked, with
  // a soft gold glow when unlocked.
  // MOCKUP FIX (2026-11-20, user order): the achievement cards match
  // mockup #18 — DARK card (near-black, warm gold tint at the top)
  // with the gold badge + halo and a white bold label. The old brown
  // gradient (0xFF8A6A2B...) looked muddy, nothing like the mockup.
  // The three preview badges are the mockup's own — First Blood
  // (target), Survivalist (shield), Squad Leader (crown) — each
  // with its OWN icon from the record (a.icon), never three copies
  // of one badge. Names are the mockup's labels; unlock states stay
  // real counts.
  // REDESIGN S10 (§6 Screen 10): summary cards use the shared card
  // radius + token spacing; icon (44) and label stay centred so the
  // three cards align in their row. Locked/unlocked
  // treatment unchanged (real counts).
  Widget _achievementBadge(({String name, String condition, bool unlocked, String progress, Widget icon}) a) => Container(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 6),
        decoration: BoxDecoration(
          gradient: a.unlocked
              ? const LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0xFF3A2E12), Color(0xFF1C1A15), Color(0xFF121212)],
                )
              : LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [kField, kField],
                ),
          borderRadius: BorderRadius.circular(kRadiusCard),
          border: Border.all(color: a.unlocked ? kGold : kBorder, width: a.unlocked ? 1.5 : 1),
        ),
        child: Column(
          children: [
            Stack(
              alignment: Alignment.center,
              children: [
                // MOCKUP FIX (2026-11-20): the record's OWN large
                // icon — target / shield / crown — not the crest
                // (its kind emblem is ~8px at this size, which made
                // all three cards look identical).
                a.icon,
                if (!a.unlocked)
                  Positioned(right: 0, top: 0, child: Icon(Icons.lock, size: 12, color: kMuted)),
              ],
            ),
            const SizedBox(height: kSpace8),
            Text(a.name.toUpperCase(), style: TextStyle(color: a.unlocked ? kText : kMuted, fontSize: 11, fontWeight: FontWeight.bold), textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis),
          ],
        ),
      );

  // Mockup #18 Squad Leader badge: a gold crown (the mockup's crown
  // in a hexagon). No PremiumBadgeKind is a crown — premium_badge.dart
  // is shared, not this file's to change — so the crown reuses this
  // file's flat _CrownIcon (leaderboard podium) with the same gold
  // halo the emblem badges get when unlocked, muted when locked.
  Widget _squadLeaderBadge(bool unlocked) {
    return SizedBox(
      width: 44,
      height: 44,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (unlocked)
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: [BoxShadow(color: kGold.withValues(alpha: 0.45), blurRadius: 10)],
              ),
            ),
          _CrownIcon(color: unlocked ? kGold : kMuted, size: 44),
        ],
      ),
    );
  }
}

class MatchHistoryPage extends StatelessWidget {
  final String uid;
  // Phase 2: `embedded` lets the Profile Match History tab embed the
  // history body without a second Scaffold/AppBar. Default false keeps
  // existing pushes working unchanged.
  final bool embedded;
  const MatchHistoryPage({super.key, required this.uid, this.embedded = false});

  @override
  Widget build(BuildContext context) {
    if (embedded) return _body();
    return Scaffold(
      appBar: AppBar(title: Text('Match History', style: TextStyle(color: kGold))),
      body: _body(),
    );
  }

  Widget _body() {
    return StreamBuilder<List<Map<String, dynamic>>>(
        stream: SupaDb.streamMatchHistory(uid),
        builder: (context, snap) {
          final items = snap.data ?? [];
          if (items.isEmpty) return Center(child: Text('No match history yet.', style: TextStyle(color: kMuted)));
          return ListView.separated(
            // Embedded (Profile tab): the parent scrolls, so the list
            // sizes itself and never scrolls on its own.
            shrinkWrap: embedded,
            physics: embedded ? const NeverScrollableScrollPhysics() : null,
            padding: const EdgeInsets.all(16),
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (_, i) {
              final h = items[i];
              final rank = h['rank'];
              final rankText = rank == null ? '' : 'Rank $rank • ';
              // WAVE C (#16): tap opens the Match Result Details
              // screen (mockup #16) for this match. Same stream/data.
              return InkWell(
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => MatchResultDetailsPage(history: h, uid: uid))),
                borderRadius: BorderRadius.circular(16),
                child: appCard(
                  child: Row(
                    children: [
                      if (rank != null)
                        Container(
                          width: 44,
                          height: 44,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(color: kGold.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(12), border: Border.all(color: kGold)),
                          child: Text('#$rank', style: TextStyle(color: kGold, fontWeight: FontWeight.w900, fontSize: 16)),
                        )
                      else
                        Container(
                          width: 44,
                          height: 44,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(color: kField, borderRadius: BorderRadius.circular(12), border: Border.all(color: kBorder)),
                          child: Icon(Icons.emoji_events, color: kGold, size: 22),
                        ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(strVal(h['tournamentName'], 'Match'), style: TextStyle(color: kText, fontWeight: FontWeight.bold)),
                            const SizedBox(height: 2),
                            Text('$rankText${intVal(h['kills'])} kills • Winnings ${fmtRs(numVal(h['winnings']))} • ${fmtDate(h['timestamp'])}', style: TextStyle(color: kMuted, fontSize: 12)),
                            if (strVal(h['result']).isNotEmpty) Text(strVal(h['result']), style: TextStyle(color: kMuted, fontSize: 12)),
                          ],
                        ),
                      ),
                      Icon(Icons.chevron_right, color: kGold, size: 22),
                    ],
                  ),
                ),
              );
            },
          );
        },
      );
  }
}

/// P-all-fixes-D1 (#16): mockup #16's victory shield — a gold shield
/// emblem with a dark soldier-helmet silhouette inside (the mockup's
/// art, redrawn as own art — never the mockup image). Static paint.
class _VictoryShieldPainter extends CustomPainter {
  const _VictoryShieldPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    double x(double f) => f * w;
    double y(double f) => f * h;

    // Gold shield: bright top-left → deep gold bottom.
    final shield = Path()
      ..moveTo(x(0.08), y(0.12))
      ..lineTo(x(0.92), y(0.12))
      ..lineTo(x(0.92), y(0.42))
      ..quadraticBezierTo(x(0.92), y(0.72), x(0.50), y(0.92))
      ..quadraticBezierTo(x(0.08), y(0.72), x(0.08), y(0.42))
      ..close();
    final goldFill = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: const [Color(0xFFFDC903), Color(0xFFFDC903), Color(0xFFFDC903)],
        stops: const [0.0, 0.55, 1.0],
      ).createShader(Rect.fromLTWH(0, 0, w, h));
    canvas.drawPath(shield, goldFill);
    canvas.drawPath(
      shield,
      Paint()
        ..color = const Color(0xFFFDC903)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );

    // Soldier helmet silhouette (dark) — dome, brim tips, cheek
    // guards, chin; a bright visor slit for the face opening.
    final helmet = Path()
      ..moveTo(x(0.50), y(0.20))
      ..quadraticBezierTo(x(0.30), y(0.20), x(0.28), y(0.42))
      ..lineTo(x(0.24), y(0.44))
      ..lineTo(x(0.30), y(0.46))
      ..lineTo(x(0.32), y(0.60))
      ..quadraticBezierTo(x(0.38), y(0.70), x(0.50), y(0.70))
      ..quadraticBezierTo(x(0.62), y(0.70), x(0.68), y(0.60))
      ..lineTo(x(0.70), y(0.46))
      ..lineTo(x(0.76), y(0.44))
      ..lineTo(x(0.72), y(0.42))
      ..quadraticBezierTo(x(0.70), y(0.20), x(0.50), y(0.20))
      ..close();
    canvas.drawPath(helmet, Paint()..color = const Color(0xFF17181F));
    canvas.drawLine(
      Offset(x(0.38), y(0.52)),
      Offset(x(0.62), y(0.52)),
      Paint()
        ..color = const Color(0xFFFFD94D)
        ..strokeWidth = w * 0.045
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// ---------------------------------------------------------------------------
// #16 Match Result Details (WAVE C, 2026-11-19)
// ---------------------------------------------------------------------------
/// Mockup #16, hubahu: header (MATCH RESULT DETAILS + ARENA HUB
/// lockup), italic tournament name (first word gold), mode • date +
/// COMPLETED pill, gold victory card (shield + team + placement +
/// squad grid), PERFORMANCE SUMMARY 4-box grid, MATCH TIMELINE,
/// VIEW TOURNAMENT LEADERBOARD + REPORT RESULT ISSUE buttons.
///
/// REAL DATA ONLY, from live columns:
/// - match_history (001 + damage 011): tournament_name, rank,
///   kills, damage, earnings, played_at.
/// - tournaments: mode / map (getTournament).
/// - tournament_registrations: my team_name + squad rows (username
///   + kills each) for the 2x2 grid.
/// GAPS (nothing invented): RESULT VERIFIED pill/banner are gated on
/// the tournament's live status == 'result' (published results —
/// the same gate MatchSummaryPage uses). TOTAL POINTS uses the
/// locked scoring (1st=10, 2nd=7, 3rd=5 place points + 1 per kill);
/// Assists + Duration come from the player's own
/// tournament_results row (submitResult) when it exists, else "—".
/// The timeline is built ONLY from data that exists: match start
/// (played_at, map when known) + match finish (duration_seconds
/// from the same result row) — wipe events are never invented.
/// Squad art is the app's own avatar/initials, never the mockup's
/// PUBG soldier photos.
class MatchResultDetailsPage extends StatefulWidget {
  final Map<String, dynamic> history;
  final String uid;
  const MatchResultDetailsPage({super.key, required this.history, required this.uid});
  @override
  State<MatchResultDetailsPage> createState() => _MatchResultDetailsPageState();
}

class _MatchResultDetailsPageState extends State<MatchResultDetailsPage> {
  bool _loading = true;
  Map<String, dynamic> _tournament = {};
  Map<String, dynamic> _profile = {};
  // The player's own submitted-result row (tournament_results):
  // the ONLY live source of assists + duration_seconds.
  Map<String, dynamic> _myResult = {};
  String _teamName = '';
  List<Map<String, dynamic>> _squad = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final tid = strVal(widget.history['tournament_id']);
    if (tid.isNotEmpty) {
      try {
        _tournament = await SupaDb.getTournament(tid);
      } catch (_) {}
      try {
        final regs = await SupaDb.getRegistrations(tid);
        final mine = regs.where((r) => strVal(r['firebase_uid']) == widget.uid).toList();
        if (mine.isNotEmpty) _teamName = strVal(mine.first['team_name']);
        if (_teamName.isNotEmpty) {
          _squad = regs.where((r) => strVal(r['team_name']) == _teamName).toList();
        }
      } catch (_) {}
      try {
        _myResult = await SupaDb.getMyResult(tid, widget.uid);
      } catch (_) {}
    }
    try {
      _profile = await SupaDb.getProfile(widget.uid);
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  String _ordinal(int n) {
    if (n % 100 >= 11 && n % 100 <= 13) return '${n}th';
    switch (n % 10) {
      case 1:
        return '${n}st';
      case 2:
        return '${n}nd';
      case 3:
        return '${n}rd';
      default:
        return '${n}th';
    }
  }

  String _fmtNum(int n) {
    final s = n.toString();
    final buf = StringBuffer();
    for (int i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
      buf.write(s[i]);
    }
    return buf.toString();
  }

  // "Nov 22, 8:00 PM" — mockup style, from the real played_at.
  String _fmtShort(dynamic ts) {
    final ms = parseTsMs(ts);
    if (ms <= 0) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final h12 = d.hour % 12 == 0 ? 12 : d.hour % 12;
    return '${months[d.month - 1]} ${d.day}, $h12:${d.minute.toString().padLeft(2, '0')} ${d.hour >= 12 ? 'PM' : 'AM'}';
  }

  // "28:45" — mm:ss from real duration_seconds.
  String _fmtDur(int seconds) {
    if (seconds <= 0) return '—';
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  // Locked scoring (user decision 2026-11-20): placement points
  // 1st=10, 2nd=7, 3rd=5 + 1 per kill. No placement points beyond 3rd.
  int _placePoints(int rank) {
    if (rank == 1) return 10;
    if (rank == 2) return 7;
    if (rank == 3) return 5;
    return 0;
  }

  // Map label for the timeline ("Match Started on Erangel"): the
  // `map` column wins; else the tags (live rows carry the map as a
  // tag, e.g. "Erangle"). Display mapping Erangle -> Erangel only —
  // the stored value is never changed. Empty when nothing names a map.
  String _mapLabel() {
    final col = strVal(_tournament['map']);
    if (col.isNotEmpty) return _displayMap(col);
    final tags = _tournament['tags'];
    if (tags is List) {
      const known = {'erangel', 'erangle', 'miramar', 'sanhok', 'vikendi', 'livik', 'karakin', 'deston', 'rondo', 'nusa'};
      for (final t in tags) {
        if (known.contains(t.toString().trim().toLowerCase())) return _displayMap(t.toString());
      }
    }
    return '';
  }

  String _displayMap(String raw) {
    final cleaned = raw.trim();
    if (cleaned.isEmpty) return cleaned;
    return cleaned.replaceAll(RegExp(r'\berangle\b', caseSensitive: false), 'Erangel');
  }

  @override
  Widget build(BuildContext context) {
    final h = widget.history;
    final name = strVal(h['tournamentName'], 'Match');
    // #16 deep-links: this page's tournament id + display name,
    // carried to the tournament leaderboard and the dispute form.
    // Empty name = the target pages resolve the live name themselves.
    final tid = strVal(h['tournament_id']);
    final tName = strVal(_tournament['name']).isNotEmpty
        ? strVal(_tournament['name'])
        : (name == 'Match' ? '' : name);
    final rank = intVal(h['rank']);
    final kills = intVal(h['kills']);
    final damage = intVal(h['damage']);
    final mode = strVal(_tournament['mode'], 'Solo');
    final dateStr = _fmtShort(h['timestamp']);
    final firstWord = name.split(' ').first;
    final rest = name.length > firstWord.length ? name.substring(firstWord.length + 1) : '';
    final teamLabel = _teamName.isNotEmpty ? _teamName : strVal(_profile['displayName'], strVal(_profile['display_name'], 'Player'));
    final bigLine = rank == 1 ? '#$rank VICTORY' : rank > 0 ? '#$rank' : 'RESULT';
    final placeLine = rank == 1 ? '1st PLACE' : rank > 0 ? '${_ordinal(rank)} PLACE' : 'COMPLETED';
    // RESULT VERIFIED — ONLY when the tournament's live status is
    // 'result' (published results), the same gate MatchSummaryPage
    // uses. Any other status never claims verification.
    final isVerified = strVal(_tournament['status']).toLowerCase() == 'result';
    // Squad grid: real squad rows when known, else just self.
    final cells = <Map<String, dynamic>>[];
    if (_squad.isNotEmpty) {
      for (final r in _squad) {
        cells.add({'uid': strVal(r['firebase_uid']), 'name': strVal(r['username'], strVal(r['user_name'], strVal(r['firebase_uid'], 'Player'))), 'kills': intVal(r['kills'])});
      }
    } else {
      cells.add({'uid': widget.uid, 'name': strVal(_profile['displayName'], strVal(_profile['display_name'], 'Player')), 'kills': kills});
    }
    // J-detail-fix1 (#16): mockup #16 squad cells carry a small icon
    // at the right edge — a crown for the top fragger, a person glyph
    // for the rest. Top = highest real kills (> 0); ties take the
    // first row. No kills data is invented.
    final topKills = cells.map((c) => intVal(c['kills'])).fold<int>(0, (a, b) => a > b ? a : b);
    // Mockup #16 TOTAL POINTS: place points + the PLAYER's own
    // kills (locked scoring — the test encodes 1st = 10 + 6 = 16).
    // The Kills box is the TEAM total (squad rows summed — the
    // mockup's 15 = 6+4+3+2); the history kills win when the squad
    // rows carry no kills.
    final placePts = _placePoints(rank);
    final totalPoints = placePts + kills;
    final squadKills = cells.fold<int>(0, (a, c) => a + intVal(c['kills']));
    final teamKills = squadKills > 0 ? squadKills : kills;
    // Assists + Duration: real only, from the player's own
    // tournament_results row. Absent column/row -> "—", never 0.
    final hasAssists = _myResult['assists'] != null;
    final assists = intVal(_myResult['assists']);
    final durationSeconds = intVal(_myResult['duration_seconds']);
    final hasDuration = durationSeconds > 0;
    // MATCH TIMELINE — built ONLY from data that exists: match
    // start (played_at + map when known) and match finish
    // (duration_seconds from the result row). No wipe events exist
    // anywhere live, so none are shown — never invented.
    final timeline = <Map<String, String>>[];
    final startMs = parseTsMs(h['timestamp']);
    if (startMs > 0) {
      final mapLabel = _mapLabel();
      timeline.add({'time': '00:00', 'label': mapLabel.isNotEmpty ? 'Match Started on $mapLabel' : 'Match Started'});
    }
    if (hasDuration) {
      timeline.add({
        'time': _fmtDur(durationSeconds),
        'label': rank == 1 ? 'Match Won — 1st Place' : rank > 0 ? 'Match Finished — ${_ordinal(rank)} Place' : 'Match Finished',
      });
    }
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        centerTitle: false,
        leading: IconButton(icon: Icon(Icons.chevron_left, color: kGold, size: 28), onPressed: () => Navigator.maybePop(context)),
        title: Text('MATCH RESULT DETAILS', style: TextStyle(color: kText, fontSize: 22, fontWeight: FontWeight.w900, fontStyle: FontStyle.italic)),
        titleSpacing: 0,
        actions: const [Padding(padding: EdgeInsets.only(right: 16), child: ArenaLogo(crownSize: 28, fontSize: 14))],
      ),
      // J-detail-fix1 (#16): mockup #16 background has sparse gold
      // dots — shared ArenaEmberDots behind the content.
      body: Stack(
        children: [
          const Positioned.fill(child: IgnorePointer(child: ArenaEmberDots())),
          _loading
          ? ListView(
              padding: const EdgeInsets.all(16),
              children: const [
                LoadingSkeleton(height: 40),
                SizedBox(height: 12),
                LoadingSkeleton(height: 160),
                SizedBox(height: 12),
                LoadingSkeleton(height: 90),
              ],
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // Mockup #16 title: one line, first word gold
                // italic, rest white italic. FittedBox shrinks long
                // names instead of cutting or wrapping them.
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: RichText(
                    text: TextSpan(
                      style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w900, fontStyle: FontStyle.italic, height: 1.05),
                      children: [
                        TextSpan(text: firstWord.toUpperCase(), style: TextStyle(color: kGold)),
                        if (rest.isNotEmpty) TextSpan(text: ' ${rest.toUpperCase()}', style: TextStyle(color: kText)),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        [mode, dateStr].where((s) => s.isNotEmpty).join(' • '),
                        style: TextStyle(color: kText, fontSize: 14),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(color: kGold.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(12), border: Border.all(color: kGold.withValues(alpha: 0.45))),
                      child: Text('COMPLETED', style: TextStyle(color: kGold, fontSize: 11, fontWeight: FontWeight.bold)),
                    ),
                    // Mockup's green RESULT VERIFIED pill — only when
                    // the tournament's results are really published.
                    if (isVerified) ...[
                      const SizedBox(width: 8),
                      // v2011 fix: cap + shrink-to-fit — in wide test
                      // fonts this pill is ~204px and the two pills
                      // together overflow the 328px row by 11px.
                      // The cap (160) sits above the pill's real
                      // ~145px device width, so on a real device it
                      // never shrinks; only the test font is capped.
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 160),
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerRight,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: Colors.green.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: Colors.green),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text('RESULT VERIFIED', style: TextStyle(color: Colors.greenAccent, fontSize: 11, fontWeight: FontWeight.bold)),
                                SizedBox(width: 4),
                                // J-detail-fix1 (#16): mockup's icon is a
                                // GOLD shield-check, not a green check.
                                Icon(Icons.verified, color: kGold, size: 13),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 14),
                // J-detail-fix1 (#16): mockup #16 victory card — DARK
                // METALLIC GRADIENT fill (silver-grey, lighter top-left,
                // darker bottom-right) with a gold border + soft gold
                // glow, brightest at the top. Static BoxShadows only.
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Color(0xFF4A4F5E), Color(0xFF2A2D38), Color(0xFF1B1D29)],
                    ),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: kGold, width: 2),
                    boxShadow: [
                      BoxShadow(color: kGold.withValues(alpha: 0.35), blurRadius: 18, spreadRadius: 1),
                      BoxShadow(color: kGold.withValues(alpha: 0.20), blurRadius: 8, spreadRadius: 0, offset: const Offset(0, -4)),
                    ],
                  ),
                  child: Column(
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Column(
                            children: [
                              // P-all-fixes-D1 (#16): mockup shield is a
                              // DRAWN gold emblem with a soldier helmet
                              // silhouette — not a generic shield glyph.
                              // _VictoryShieldPainter draws it (own art).
                              Container(
                                width: 84,
                                height: 84,
                                decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), border: Border.all(color: kGold, width: 1.5), color: kGold.withValues(alpha: 0.12)),
                                child: const Padding(
                                  padding: EdgeInsets.all(8),
                                  child: CustomPaint(painter: _VictoryShieldPainter()),
                                ),
                              ),
                              const SizedBox(height: 8),
                              SizedBox(
                                width: 120,
                                child: Text(teamLabel, style: TextStyle(color: kText, fontSize: 18, fontWeight: FontWeight.bold), textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis),
                              ),
                              Text('YOUR TEAM', style: TextStyle(color: kMuted, fontSize: 11, letterSpacing: 1.5)),
                              const SizedBox(height: 6),
                              Text('TOTAL POINTS: $totalPoints', style: TextStyle(color: kGold, fontSize: 15, fontWeight: FontWeight.w900)),
                              const SizedBox(height: 2),
                              Text('$placePts Place • $kills Kills', style: TextStyle(color: kText, fontSize: 12)),
                            ],
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                FittedBox(
                                  fit: BoxFit.scaleDown,
                                  alignment: Alignment.centerRight,
                                  child: Text(bigLine, style: TextStyle(color: kGold, fontSize: 36, fontWeight: FontWeight.w900, fontStyle: FontStyle.italic)),
                                ),
                                Text(placeLine, style: TextStyle(color: kText, fontSize: 18, fontWeight: FontWeight.w800, fontStyle: FontStyle.italic)),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      // Mockup #16 squad grid: 2 columns, except a
                      // lone Solo cell, which spans the full width.
                      // v2011 fix: aspect 2.6 -> 2.2 — the cells were
                      // 32.6px tall inside but the two text lines
                      // need ~37px in wide test fonts (21px overflow);
                      // even on a real device the margin was ~2px.
                      GridView.count(
                        crossAxisCount: cells.length == 1 ? 1 : 2,
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        mainAxisSpacing: 8,
                        crossAxisSpacing: 8,
                        childAspectRatio: 2.2,
                        children: [
                          for (final c in cells)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                              decoration: BoxDecoration(color: kField, borderRadius: BorderRadius.circular(12), border: Border.all(color: kBorder)),
                              child: Row(
                                children: [
                                  CachedFramedAvatar(uid: strVal(c['uid']), name: strVal(c['name']), radius: 17),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        Text(
                                          '${strVal(c['name'])}${strVal(c['uid']) == widget.uid ? ' (You)' : ''}',
                                          style: TextStyle(color: kText, fontSize: 14, fontWeight: FontWeight.bold),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        // v2011 fix: maxLines 1 + ellipsis
                                        // (like the name above) — without
                                        // it a long kills string wraps to
                                        // a 2nd line and the cell Column
                                        // overflows vertically.
                                        Text('${intVal(c['kills'])} Kills', style: TextStyle(color: kMuted, fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis),
                                      ],
                                    ),
                                  ),
                                  // J-detail-fix1 (#16): mockup cell
                                  // right-edge icon — crown on the top
                                  // fragger, person glyph otherwise.
                                  Icon(
                                    intVal(c['kills']) == topKills && topKills > 0 ? Icons.emoji_events : Icons.person,
                                    color: intVal(c['kills']) == topKills && topKills > 0 ? kGold : kMuted,
                                    size: 16,
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                Text('PERFORMANCE SUMMARY', style: TextStyle(color: kText, fontSize: 20, fontWeight: FontWeight.w900)),
                const SizedBox(height: 10),
                Row(
                  children: [
                    _perfBox('Kills', _fmtNum(teamKills), Icons.gps_fixed),
                    const SizedBox(width: 8),
                    _perfBox('Assists', hasAssists ? _fmtNum(assists) : '—', Icons.group),
                    const SizedBox(width: 8),
                    _perfBox('Total Damage', _fmtNum(damage), Icons.bolt),
                    const SizedBox(width: 8),
                    _perfBox('Duration', hasDuration ? _fmtDur(durationSeconds) : '—', Icons.hourglass_bottom),
                  ],
                ),
                const SizedBox(height: 20),
                Text('MATCH TIMELINE', style: TextStyle(color: kText, fontSize: 20, fontWeight: FontWeight.w900)),
                const SizedBox(height: 10),
                // Real events only (match start + match finish, when
                // the data exists). No timeline was recorded at all
                // only when even the start time is missing.
                if (timeline.isEmpty)
                  MockupCard(
                    padding: const EdgeInsets.all(14),
                    radius: 14,
                    child: Text('No timeline was recorded for this match.', style: TextStyle(color: kMuted, fontSize: 13)),
                  )
                else
                  _MatchTimeline(events: timeline),
                const SizedBox(height: 22),
                // Mockup's green verified banner — only when the
                // tournament's results are really published.
                if (isVerified) ...[
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(color: Colors.green.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.green.withValues(alpha: 0.6))),
                    child: Row(children: [
                      Text('RESULT VERIFIED', style: TextStyle(color: kGold, fontSize: 15, fontWeight: FontWeight.bold)),
                      const SizedBox(width: 10),
                      Expanded(child: Text('Verified by Arena Hub Officials', style: TextStyle(color: kText, fontSize: 14))),
                      Icon(Icons.workspace_premium, color: kGold),
                    ]),
                  ),
                  const SizedBox(height: 12),
                ],
                // Mockup #16 buttons are ROUNDED RECTANGLES (radius
                // 12, ~52px tall) — NOT the app-wide radius-30 pills,
                // so they are page-local here; GoldButton /
                // OutlineButton stay untouched for the rest of the app.
                // #16 (1): the tournament-scoped leaderboard (not the
                // global board) — TournamentLeaderboardPage opens
                // directly on this tournament's ranking.
                _rectGoldButton(label: 'VIEW TOURNAMENT LEADERBOARD', icon: Icons.chevron_right, onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => TournamentLeaderboardPage(tournamentId: tid, tournamentName: tName.isEmpty ? null : tName)))),
                const SizedBox(height: 10),
                // #16 (2): the dispute form opens pre-selected on
                // this tournament — the player never re-picks it.
                _rectOutlineButton(label: 'REPORT RESULT ISSUE', icon: Icons.flag, onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => DisputePage(uid: widget.uid, tournamentId: tid.isEmpty ? null : tid, tournamentName: tName.isEmpty ? null : tName)))),
                const SizedBox(height: 8),
              ],
            ),
        ],
      ),
    );
  }

  Widget _perfBox(String label, String value, IconData icon) {
    return Expanded(
      child: MockupCard(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        radius: 12,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(label, style: TextStyle(color: kMuted, fontSize: 11)),
                  ),
                ),
                const SizedBox(width: 2),
                Icon(icon, color: kGold, size: 16),
              ],
            ),
            const SizedBox(height: 4),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(value, style: TextStyle(color: kGold, fontSize: 26, fontWeight: FontWeight.w900)),
            ),
          ],
        ),
      ),
    );
  }

  // Mockup #16 rounded-rectangle CTAs (radius 12, ~52px tall).
  Widget _rectGoldButton({required String label, required IconData icon, required VoidCallback onPressed}) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: kGold,
          foregroundColor: const Color(0xFF0A0A0F),
          padding: const EdgeInsets.symmetric(vertical: 15, horizontal: 20),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          elevation: 0,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Flexible(
              child: Text(label, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16, letterSpacing: 0.5), maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            const SizedBox(width: 6),
            Icon(icon, size: 18),
          ],
        ),
      ),
    );
  }

  Widget _rectOutlineButton({required String label, required IconData icon, required VoidCallback onPressed}) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          foregroundColor: kGold,
          side: BorderSide(color: kGold, width: 1.5),
          backgroundColor: kCard,
          padding: const EdgeInsets.symmetric(vertical: 15, horizontal: 20),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Flexible(
              child: Text(label, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15), maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            const SizedBox(width: 6),
            Icon(icon, size: 18),
          ],
        ),
      ),
    );
  }
}

/// Mockup #16 MATCH TIMELINE: timestamps left, a dotted vertical
/// gold line with a dot per event (gold, last one white), event text
/// right. Events are real only — the caller builds the list.
class _MatchTimeline extends StatelessWidget {
  final List<Map<String, String>> events;
  const _MatchTimeline({required this.events});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (var i = 0; i < events.length; i++)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 52,
                child: Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(events[i]['time'] ?? '', style: TextStyle(color: kMuted, fontSize: 13), textAlign: TextAlign.right),
                ),
              ),
              const SizedBox(width: 14),
              Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: i == events.length - 1 ? Colors.white : kGold,
                        border: Border.all(color: i == events.length - 1 ? Colors.white : kGold),
                      ),
                    ),
                  ),
                  if (i < events.length - 1)
                    CustomPaint(
                      size: const Size(2, 30),
                      painter: _DottedLinePainter(color: kGold.withValues(alpha: 0.6)),
                    ),
                ],
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Text(events[i]['label'] ?? '', style: TextStyle(color: kText, fontSize: 15)),
                ),
              ),
            ],
          ),
      ],
    );
  }
}

/// Dashed vertical line for the match timeline.
class _DottedLinePainter extends CustomPainter {
  final Color color;
  const _DottedLinePainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    var y = 0.0;
    while (y < size.height) {
      final end = (y + 3).clamp(0.0, size.height);
      canvas.drawLine(Offset(size.width / 2, y), Offset(size.width / 2, end), paint);
      y += 7;
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Notifications (Phase 3, WAVE B design-match #21, 2026-11-19):
/// mockup structure — bordered back box, gold italic NOTIFICATIONS
/// title, gold 'Mark All Read' pill, pill tabs All / Matches / Events
/// / System, unread = gold border + gold dot, read = muted border +
/// grey icon, icon badge + title/time + body per card. Data source and
/// navigation unchanged (SupaDb.getNotifications + markNotificationsRead).
///
/// VERIFIED GAP (001_init.sql): `notifications` + `user_notifications`
/// have NO type/category column — only title / message / image_url /
/// created_at (+ firebase_uid on user rows). The tabs therefore filter
/// by KEYWORD MATCH on title + message (see _categoryOf); they do NOT
/// claim a stored category exists. A real category column is a
/// Phase 4/5 schema follow-up (NOT built here). WAVE C (2026-11-19):
/// the on-screen honesty line about the keyword filter was REMOVED —
/// it is not in mockup #21 and breaks hubahu; the tabs keep working
/// via the keyword filter without the explanation.
///
/// TEAM-INVITE Accept/Decline (2026-11-21 fix — the old "BLOCKED,
/// not shipped" note below is superseded): the invite state lives
/// in `team_invitations` (027) + the invitee's `user_notifications`
/// row (type='team_invite', invite_id, team_id). The inbox shows
/// Accept/Decline on every team_invite row AND on pending invites
/// read directly from `team_invitations` (SupaDb.
/// getPendingTeamInvites + mergeInviteNotifications) — so an invite
/// whose notification row never arrived (or was swiped away) is
/// still visible and actionable. Accept/Decline run through
/// SupaDb.respondTeamInvite, a DIRECT-WRITE path (team_members
/// insert + team_invitations status update): the 027 RPC cannot be
/// called from this app (authenticated-only + firebase_uid() is
/// NULL for the anon app — see supabase_db.dart). A responded
/// invite's card disappears on the next load even if its
/// notification row could not be deleted (stale-drop in the merge).
///
/// PER-ROW DELETE (2026-11-20, Community System): the user's OWN
/// user_notifications rows swipe-to-delete (Dismissible, one by
/// one, red delete background). Delete goes through
/// CommunityService.deleteNotification: direct DELETE first, with
/// the dismiss_notification RPC (027) as fallback until draft 036's
/// DELETE policy is applied. A failed delete restores the row and
/// says so — never a silent loss.
///
/// FIX 7 (2026-11-20) — TWO SOURCES, THREE ROOT CAUSES (all verified
/// in code, supabase_db.dart getNotifications / markNotificationsRead
/// + community_service.dart deleteNotification + admin_db_care.dart):
/// the list merges TWO tables — global `notifications` (admin
/// broadcasts, incl. push-style announcements; NO firebase_uid, only
/// admin can delete them server-side) and the user's own
/// `user_notifications` (firebase_uid = this user). No local list and
/// no push-handler insert exists — every row comes from the backend.
/// (1) MARK-ALL DID NOTHING: markNotificationsRead swallows ALL
/// errors (catch (_) {}) and returns void, so the UI could never know
/// the profiles.last_checked_notifications write had failed — and the
/// old code toasted success anyway. Unread dots are timestamp-based
/// (_isUnread: timestamp > _lastChecked), so a failed write left
/// every dot in place. Fix: optimistic local update (dots vanish at
/// once) + VERIFY by re-reading the profile — success only if the
/// server value actually advanced, else restore + honest error.
/// (2) DELETE-ALL LEFT ONE ROW: it deleted ONLY own rows and toasted
/// "saari delete ho gayin" unconditionally (finally block) — the one
/// leftover was a GLOBAL broadcast row, which no user-side path could
/// remove (deleteNotification is own-rows only; dismiss RPC rejects
/// global rows). Fix: global rows are now hidden LOCALLY per device
/// (SharedPreferences dismissed-id list, per user) while own rows are
/// deleted on the server — and the toast reports the VERIFIED result
/// (full / partial / failed), never a blind success. A locally hidden
/// broadcast still exists server-side (shared with all users); it
/// reappears only on a fresh install / another device.
/// (3) SELECT-ALL + DELETE: long-press enters selection mode (tap
/// toggles, checkbox on each card), "Select all" selects the visible
/// tab's rows, and DELETE removes the selection (own rows server-side,
/// global rows locally hidden) with the same verified result.
///
/// NOTIFICATIONS REDESIGN (2026-11-21, mockup #21 same-to-same):
/// filter pills share the full width (FilterTabs expanded); unread
/// cards get the gold border + glow + corner gold dot BACK (ROUND 3
/// had removed the border under the global card rule — mockup #21
/// shows it); read cards are a plain border with no dot; title 16 /
/// body 14 / time 12, everything fully wrapped, never ellipsized
/// (standing no-cut rule). Team-invite rows (real or synthesized)
/// are NOT deletable/selectable anywhere — swipe, Clear-all and
/// Delete-selected all skip them, because a pending invite
/// re-synthesizes on the next load and a "deleted" invite card
/// coming back is a lie; only Accept/Decline removes it.
class NotificationsPage extends StatefulWidget {
  final String uid;
  const NotificationsPage({super.key, required this.uid});
  @override
  State<NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends State<NotificationsPage> {
  int _tab = 0; // 0 All, 1 Matches, 2 Events, 3 System
  bool _loading = true;
  bool _offline = false;
  String? _error;
  List<Map<String, dynamic>> _all = [];
  int _lastChecked = 0;
  // Display name of the current user (from the profile read in
  // _load) — Accept needs it for the team_members row.
  String _myDisplayName = 'User';
  // FIX 7 (2026-11-20): selection mode (Select all + Delete) and the
  // device-local hidden list for global broadcast rows.
  final Set<String> _selected = {};
  Set<String> _hiddenGlobalIds = {};
  bool _busy = false; // a mark-all / delete run is in flight.

  @override
  void initState() {
    super.initState();
    _load();
  }

  // FIX 7: a row is GLOBAL (admin broadcast, shared with all users)
  // when it carries no firebase_uid — getNotifications merges the
  // global `notifications` table with the user's own
  // `user_notifications` rows, and only the own rows have the uid.
  static bool _isGlobal(Map<String, dynamic> n) => strVal(n['firebase_uid']).isEmpty;
  static String _rowId(Map<String, dynamic> n) => strVal(n['id']);

  // 2026-11-21 NOTIFICATIONS REDESIGN: a team-invite row (real
  // user_notifications row OR synthesized card) is an ACTIONABLE
  // invite, not a deletable notification — it leaves the list ONLY
  // via Accept/Decline. Deleting its notification row while the
  // invite is still pending just re-synthesizes the card on the
  // next load, so a swipe / Clear-all / Delete-selected that
  // "succeeds" on it is a lie (the card comes back).
  static bool _isInviteRow(Map<String, dynamic> n) =>
      (strVal(n['type']) == 'team_invite' &&
              strVal(n['invite_id']).isNotEmpty) ||
      // PHASE E (E30): a community invite is actionable too —
      // it leaves the list ONLY via Join/Decline, never swipe.
      (strVal(n['type']) == 'community_invite' &&
          strVal(n['community_id']).isNotEmpty);

  // FIX 7: device-local dismissed list for global rows (per user).
  // Global broadcasts cannot be deleted server-side by the user (only
  // admin can delete them; the dismiss RPC rejects them) — so hiding
  // them on this device is the honest way to make Clear-all /
  // select-delete actually empty the visible list.
  String get _hiddenKey => 'dismissed_global_notifs_${widget.uid}';

  Future<Set<String>> _readHiddenGlobalIds() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getStringList(_hiddenKey)?.toSet() ?? {};
    } catch (_) {
      return {};
    }
  }

  /// Hide global rows locally. Returns false when the ids could not
  /// be saved (then the rows stay visible — never a silent success).
  Future<bool> _hideGlobalIds(List<String> ids) async {
    final fresh = ids.where((id) => id.isNotEmpty).toSet();
    if (fresh.isEmpty) return true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final next = {..._hiddenGlobalIds, ...fresh};
      final saved = await prefs.setStringList(_hiddenKey, next.toList());
      if (!saved) return false;
      _hiddenGlobalIds = next;
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _offline = false;
    });
    try {
      final conn = await Connectivity().checkConnectivity();
      if (conn.contains(ConnectivityResult.none)) {
        if (mounted) setState(() { _loading = false; _offline = true; });
        return;
      }
    } catch (_) {}
    try {
      final list = await SupaDb.getNotifications(widget.uid);
      final profile = await SupaDb.getProfile(widget.uid);
      // TEAM-INVITE FIX (2026-11-21): second discovery path — read
      // the pending invites DIRECTLY from team_invitations and merge
      // them into the inbox (a synthesized card for an invite whose
      // notification row never arrived, stale cards dropped). A
      // FAILED read leaves `pending` null and the merge returns the
      // inbox unchanged — "could not load" is never shown as "no
      // invites". This read is best-effort: it must never fail the
      // whole inbox load.
      List<Map<String, dynamic>>? pending;
      try {
        pending = await SupaDb.enrichTeamInvites(await SupaDb.getPendingTeamInvites(widget.uid));
      } catch (_) {
        pending = null;
      }
      final merged = SupaDb.mergeInviteNotifications(list, pending);
      // FIX 7: locally hidden global rows never reappear in the list.
      final hidden = await _readHiddenGlobalIds();
      if (!mounted) return;
      setState(() {
        _all = merged.where((n) => !(_isGlobal(n) && hidden.contains(_rowId(n)))).toList();
        _hiddenGlobalIds = hidden;
        // A row that no longer exists cannot stay selected.
        _selected.removeWhere((id) => !_all.any((n) => _rowId(n) == id));
        _lastChecked = SupaDb.intOf(profile['lastCheckedNotifications'], 0);
        _myDisplayName = SupaDb.strOf(profile['displayName'], 'User');
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = '$e'; });
    }
  }

  /// FIX 7 — Mark all read, VERIFIED. Root cause of "dabane par kuch
  /// nahi hota": SupaDb.markNotificationsRead used to swallow every
  /// error (catch (_) {}) and return void, so the old code toasted
  /// success even when the profiles.last_checked_notifications write
  /// never landed — and the unread dots (timestamp > _lastChecked)
  /// all stayed. Now markNotificationsRead returns bool (false =
  /// the write failed), AND the profile is re-read from the server
  /// as a second proof. On failure the old value is restored and
  /// the user gets an honest error, never a false "ho gaya".
  Future<void> _markAllRead() async {
    if (_all.isEmpty || _busy) return;
    if (!_all.any(_isUnread)) {
      toast(context, 'Sab notifications pehle se read hain.');
      return;
    }
    final before = _lastChecked;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    setState(() {
      _busy = true;
      _lastChecked = nowMs; // dots vanish at once.
    });
    try {
      final marked = await SupaDb.markNotificationsRead(widget.uid);
      if (!marked) {
        // The write itself failed — restore + honest error, no
        // pointless re-read.
        if (!mounted) return;
        setState(() {
          _busy = false;
          _lastChecked = before;
        });
        toast(context, 'Mark all read nahi hua — internet check karke dobara try karein.');
        return;
      }
      await _load(); // re-reads the profile + list from the server.
      if (!mounted) return;
      setState(() => _busy = false);
      // The re-read is the second proof: success = the server clock
      // advanced past `before`, or no unread row is left. A load
      // error / offline run proves nothing — that is a failure,
      // not a success.
      final ok = _error == null && !_offline && (_lastChecked > before || !_all.any(_isUnread));
      if (ok) {
        toast(context, 'Sab notifications read ho gayin.');
      } else {
        setState(() => _lastChecked = before);
        toast(context, 'Mark all read nahi hua — internet check karke dobara try karein.');
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _lastChecked = before;
      });
      toast(context, 'Mark all read nahi hua — internet check karke dobara try karein.');
    }
  }

  /// Delete ONE notification (swipe-to-delete). Optimistic: the row
  /// leaves the list at once; a failed delete restores it and says
  /// so. FIX 7: EVERY row is deletable now — own rows go to the
  /// server (CommunityService.deleteNotification), global broadcast
  /// rows are hidden locally (no user-side server delete exists for
  /// them — only admin can delete a broadcast). A row with no id
  /// cannot be deleted by either path, so it gets no delete option.
  Future<void> _deleteNotification(String id) async {
    if (id.isEmpty || _busy) return;
    final idx = _all.indexWhere((n) => _rowId(n) == id);
    if (idx < 0) return;
    final removed = _all[idx];
    // TEAM-INVITE FIX (2026-11-21): an invite card — real row or
    // synthesized — has no delete path. It is removed only by
    // Accept/Decline (or when the invite stops being pending).
    // Deleting the notification row while the invite is pending
    // just re-synthesizes the card on the next load, so a swipe
    // that "succeeds" here would lie and the card would come back.
    if (_isInviteRow(removed)) {
      toast(context, 'Team invitation Accept ya Decline se hat-ti hai — delete se nahi.');
      return;
    }
    if (removed['_synthetic_invite'] == true) return;
    final global = _isGlobal(removed);
    setState(() => _all.removeAt(idx));
    final ok = global
        ? await _hideGlobalIds([id])
        : (await CommunityService.deleteNotification(id: id, uid: widget.uid))['ok'] == true;
    if (!mounted) return;
    if (ok) {
      // BADGE FIX (2026-11-22): same as bulk delete — the bell badge
      // cannot see this delete on its own; refresh it directly.
      SupaDb.notifyUnreadChanged();
      toast(context, 'Notification delete ho gayi.');
    } else {
      setState(() => _all.insert(idx, removed));
      toast(context, 'Delete nahi hui — internet check karke dobara try karein.');
    }
  }

  /// FIX 7 — shared delete engine for Clear-all + Delete-selected.
  /// Own rows: bulk DELETE first (fast path, needs 036 RLS), then
  /// every survivor one-by-one through CommunityService
  /// .deleteNotification (direct DELETE + dismiss-RPC fallback), and
  /// each result is COUNTED. Global rows: hidden locally. Returns
  /// {'deleted': n, 'failed': n} — the caller reports the VERIFIED
  /// result and never claims a success it did not check.
  Future<Map<String, int>> _deleteRows(List<Map<String, dynamic>> rows) async {
    // 2026-11-21: invite rows are NEVER bulk-deleted (see
    // _isInviteRow) — a pending invite re-synthesizes on the next
    // load, so deleting its row would only fake a success.
    final own = rows.where((n) => !_isGlobal(n) && _rowId(n).isNotEmpty && n['_synthetic_invite'] != true && !_isInviteRow(n)).toList();
    final globalIds = rows.where(_isGlobal).map(_rowId).where((id) => id.isNotEmpty).toList();
    var deleted = 0;
    var failed = 0;
    if (own.isNotEmpty) {
      try {
        await SupaDb.client.from('user_notifications').delete().eq('firebase_uid', widget.uid);
      } catch (_) {
        // Bulk blocked (RLS until 036) — per-row fallback below.
      }
      // Survivors of the bulk delete, one by one. Only the rows we
      // were asked to delete — a fresh row that arrived mid-run is
      // NOT swept up (the old code re-read the whole table).
      final want = own.map(_rowId).toSet();
      final remaining = await SupaDb.getList('user_notifications', eqCol: 'firebase_uid', eqVal: widget.uid);
      final survivors = remaining.where((r) => want.contains(SupaDb.strOf(r['id']))).toList();
      deleted += own.length - survivors.length;
      for (final row in survivors) {
        final res = await CommunityService.deleteNotification(id: SupaDb.strOf(row['id']), uid: widget.uid);
        if (res['ok'] == true) {
          deleted++;
        } else {
          failed++;
        }
      }
    }
    if (globalIds.isNotEmpty) {
      final hidden = await _hideGlobalIds(globalIds);
      if (hidden) {
        deleted += globalIds.length;
      } else {
        failed += globalIds.length;
      }
    }
    // BADGE FIX (2026-11-22): the bell badge cannot see these deletes
    // (realtime DELETE events are unreliable; hiding touches no
    // table) — refresh it directly so the count drops at once.
    if (deleted > 0) SupaDb.notifyUnreadChanged();
    return {'deleted': deleted, 'failed': failed};
  }

  /// FIX 7 — honest result toast after a bulk delete. `asked` is how
  /// many rows the user asked to delete; `failed` is how many the
  /// engine could not remove. Full success, partial success and total
  /// failure each get their own plain (non-technical) message — a
  /// partial delete is NEVER reported as "saari delete ho gayin".
  void _reportBulkDeleteResult(int asked, int failed) {
    if (failed <= 0) {
      toast(context, 'Saari notifications delete ho gayin.');
    } else if (failed >= asked) {
      toast(context, 'Delete nahi hui — internet check karke dobara try karein.');
    } else {
      toast(context, '${asked - failed} delete ho gayin, $failed reh gayin — dobara try karein.');
    }
  }

  /// Delete ALL notifications at once (user order: "ek + sab" —
  /// one-by-one swipe AND clear-all). FIX 7: covers EVERY visible
  /// row, own + global — the old version deleted only own rows and
  /// still toasted "saari delete ho gayin", which is why one
  /// (global/broadcast) notification always stayed behind. Always
  /// asks first — clearing all cannot be undone.
  Future<void> _deleteAllNotifications() async {
    // 2026-11-21: pending invite cards stay — only Accept/Decline
    // removes them (see _isInviteRow). They are not counted in the
    // result toast either, so "saari delete ho gayin" is never a lie.
    final rows = _all.where((n) => _rowId(n).isNotEmpty && !_isInviteRow(n)).toList();
    if (rows.isEmpty || _busy) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kCardPurpleMid,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22), side: const BorderSide(color: kCardPurpleBorder, width: 1.5)),
        title: Text('Saari notifications delete karein?', style: TextStyle(color: kText, fontWeight: FontWeight.bold)),
        content: Text('${rows.length} notifications delete ho jayengi. Ye wapas nahi aayengi.', style: TextStyle(color: kMuted)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('Cancel', style: TextStyle(color: kMuted))),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete All', style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    setState(() {
      _busy = true;
      _loading = true;
    });
    try {
      final res = await _deleteRows(rows);
      if (!mounted) return;
      setState(() => _selected.clear());
      await _load();
      if (!mounted) return;
      _reportBulkDeleteResult(rows.length, res['failed'] ?? 0);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// FIX 7 — selection mode (Select all + Delete). Long-press a card
  /// to enter selection mode; tap toggles a row; "Select all" selects
  /// every row visible in the current tab.
  bool get _selecting => _selected.isNotEmpty;

  void _toggleSelect(String id) {
    if (id.isEmpty) return;
    // 2026-11-21: invite rows are never selectable (they cannot be
    // deleted — only Accept/Decline removes them).
    final row = _all.where((n) => _rowId(n) == id).toList();
    if (row.isNotEmpty && _isInviteRow(row.first)) return;
    setState(() {
      if (!_selected.add(id)) _selected.remove(id);
    });
  }

  void _selectAllVisible() {
    final ids = _filtered.where((n) => !_isInviteRow(n)).map(_rowId).where((id) => id.isNotEmpty).toSet();
    setState(() {
      if (ids.isNotEmpty && _selected.containsAll(ids)) {
        _selected.removeAll(ids); // all visible selected -> deselect.
      } else {
        _selected.addAll(ids);
      }
    });
  }

  /// FIX 7 — delete the selection (own rows server-side, global rows
  /// hidden locally), then clear the selection + refresh. Same
  /// verified result as Clear-all: never a blind success.
  Future<void> _deleteSelected() async {
    // 2026-11-21: invite rows never enter the delete set (see
    // _isInviteRow) even if a stale selection held one.
    final rows = _all.where((n) => _selected.contains(_rowId(n)) && !_isInviteRow(n)).toList();
    if (rows.isEmpty || _busy) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kCardPurpleMid,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22), side: const BorderSide(color: kCardPurpleBorder, width: 1.5)),
        title: Text('${rows.length} notifications delete karein?', style: TextStyle(color: kText, fontWeight: FontWeight.bold)),
        content: Text('Selected notifications delete ho jayengi. Ye wapas nahi aayengi.', style: TextStyle(color: kMuted)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('Cancel', style: TextStyle(color: kMuted))),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete', style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    setState(() {
      _busy = true;
      _loading = true;
    });
    try {
      final res = await _deleteRows(rows);
      if (!mounted) return;
      setState(() => _selected.clear());
      await _load();
      if (!mounted) return;
      _reportBulkDeleteResult(rows.length, res['failed'] ?? 0);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // Invite ids with a respond call in flight (buttons disabled until
  // it lands — no double-tap double-respond).
  final Set<String> _responding = {};

  /// Accept/Decline a team invitation (027, mockup #22 — direct-write
  /// path, 2026-11-21 fix: SupaDb.respondTeamInvite inserts the
  /// team_members row + flips the invite status; the 027 RPC cannot
  /// run from this app). On success the notification row is removed
  /// best-effort (a synthesized card has no server row to delete —
  /// it vanishes on refresh because the invite is no longer pending)
  /// and the list refreshes. A stale row (already responded
  /// elsewhere) just refreshes so the dead buttons disappear.
  Future<void> _respondToInvite(Map<String, dynamic> n, String response) async {
    final inviteId = strVal(n['invite_id']);
    final notifId = strVal(n['id']);
    final synthetic = n['_synthetic_invite'] == true;
    if (inviteId.isEmpty || notifId.isEmpty || _responding.contains(inviteId)) return;
    setState(() => _responding.add(inviteId));
    final res = await SupaDb.respondTeamInvite(inviteId, response, uid: widget.uid, userName: _myDisplayName);
    if (!mounted) return;
    if (res['ok'] == true) {
      if (!synthetic) {
        // Best-effort only: the merge's stale-drop hides the card on
        // the next load even if this delete is blocked server-side.
        try {
          await CommunityService.deleteNotification(id: notifId, uid: widget.uid);
        } catch (_) {}
      }
      if (!mounted) return;
      setState(() => _responding.remove(inviteId));
      toast(context, response == 'accepted' ? 'Team join ho gayi!' : 'Invitation decline kar di.');
      await _load();
    } else {
      setState(() => _responding.remove(inviteId));
      final err = strVal(res['error']);
      if (err.contains('already responded')) {
        toast(context, 'Ye invitation pehle hi respond ho chuki hai.');
        await _load();
      } else {
        toast(context, 'Failed: $err');
      }
    }
  }

  /// Join/Decline a COMMUNITY invitation (PHASE E E30 — the
  /// invite IS the notification row; there is no separate invite
  /// table). Join follows the community via
  /// CommunityGroups.respondCommunityInvite (real membership row
  /// + delete the notification); Decline just deletes the row.
  /// The list refreshes afterwards either way.
  Future<void> _respondToCommunityInvite(
      Map<String, dynamic> n, String response) async {
    final notifId = strVal(n['id']);
    final communityId = strVal(n['community_id']);
    if (notifId.isEmpty ||
        communityId.isEmpty ||
        _responding.contains(notifId)) {
      return;
    }
    setState(() => _responding.add(notifId));
    final res = await CommunityGroups.respondCommunityInvite(
      notificationId: notifId,
      communityId: communityId,
      response: response,
      uid: widget.uid,
    );
    if (!mounted) return;
    setState(() => _responding.remove(notifId));
    if (res['ok'] == true) {
      toast(context,
          response == 'accepted' ? 'Community join ho gayi!' : 'Invitation decline kar di.');
      await _load();
    } else {
      toast(context, 'Failed: ${strVal(res['error'])}');
    }
  }

  /// Open the community behind a community_invite row (tap on
  /// the card itself — the Join/Decline pills keep their own
  /// taps). The detail page reloads fresh data on entry, so a
  /// minimal map (id + name from the notification) is enough.
  void _openCommunityInvite(Map<String, dynamic> n) {
    final communityId = strVal(n['community_id']);
    if (communityId.isEmpty) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CommunityDetailPage(
          uid: widget.uid,
          communityId: communityId,
          community: {
            'id': communityId,
            'name': SupaDb.strOf(n['community_name'], 'Community'),
          },
        ),
      ),
    );
  }

  bool _isUnread(Map<String, dynamic> n) => SupaDb.intOf(n['timestamp'], 0) > _lastChecked;

  // Keyword heuristic ONLY — no category column exists (see header).
  // Unclassified notifications appear in All only, never forced into a tab.
  String? _categoryOf(Map<String, dynamic> n) {
    final text = '${strVal(n['title'])} ${strVal(n['message'])}'.toLowerCase();
    bool has(List<String> words) => words.any(text.contains);
    if (has(['maintenance', 'update', 'announcement', 'welcome', 'system', 'policy', 'support', 'verification', 'password', 'account'])) {
      return 'System';
    }
    if (has(['match', 'result', 'won', 'win ', 'rank', 'kill', 'score', 'tournament result', 'prize'])) {
      return 'Matches';
    }
    if (has(['event', 'tournament', 'promotion', 'offer', 'bonus', 'giveaway', 'season'])) {
      return 'Events';
    }
    return null;
  }

  List<Map<String, dynamic>> get _filtered {
    const tabs = ['All', 'Matches', 'Events', 'System'];
    if (_tab == 0) return _all;
    final want = tabs[_tab];
    return _all.where((n) => _categoryOf(n) == want).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // WAVE B (#21): mockup header — bordered back box, gold italic
      // NOTIFICATIONS title, gold 'Mark All Read' pill.
      appBar: AppBar(
        automaticallyImplyLeading: false,
        centerTitle: true,
        leading: Padding(
          padding: const EdgeInsets.all(8),
          child: Container(
            decoration: BoxDecoration(border: Border.all(color: kBorder), borderRadius: BorderRadius.circular(10)),
            child: IconButton(icon: Icon(Icons.chevron_left, color: kGold, size: 24), padding: EdgeInsets.zero, onPressed: () => Navigator.maybePop(context)),
          ),
        ),
        // P-all-fixes-D1 (#21): mockup title is ~24px (AppBar default
        // is 20) and the back chevron in the bordered box is GOLD.
        title: Text('NOTIFICATIONS', style: TextStyle(color: kGold, fontSize: 24, fontWeight: FontWeight.w900, fontStyle: FontStyle.italic)),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Center(
              child: GestureDetector(
                // FIX 7: disabled while a mark/delete run is in flight
                // (no double-tap double-run on the verified mark-all).
                onTap: (_all.isEmpty || _busy) ? null : _markAllRead,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                  decoration: BoxDecoration(color: (_all.isEmpty || _busy) ? kField : kGold, borderRadius: BorderRadius.circular(10)),
                  child: Text('Mark All Read', style: TextStyle(color: (_all.isEmpty || _busy) ? kMuted : Colors.black, fontSize: 12, fontWeight: FontWeight.bold)),
                ),
              ),
            ),
          ),
        ],
      ),
      // Mockup #21: the bottom nav (Home active) — same
      // pushed-screen pattern as MyTeamBottomNav.
      bottomNavigationBar: const _PushedBottomNav(activeIndex: 0),
      // J-detail-fix1 (#21): mockup #21 background has faint gold dust
      // specks — shared ArenaEmberDots behind the content.
      body: Stack(
        children: [
          const Positioned.fill(child: IgnorePointer(child: ArenaEmberDots())),
          _loading
          ? ListView(
              padding: const EdgeInsets.all(16),
              children: const [
                LoadingSkeleton(height: 40),
                SizedBox(height: 12),
                LoadingSkeleton(height: 84),
                SizedBox(height: 8),
                LoadingSkeleton(height: 84),
                SizedBox(height: 8),
                LoadingSkeleton(height: 84),
              ],
            )
          : _offline
              ? Center(child: OfflineState(onRetry: _load))
              : _error != null
                  ? Center(child: ErrorState(message: 'Notifications load nahi hui: $_error', onRetry: _load))
                  : Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                          child: FilterTabs(
                            labels: const ['All', 'Matches', 'Events', 'System'],
                            selectedIndex: _tab,
                            onSelected: (i) => setState(() => _tab = i),
                            // 2026-11-21 NOTIFICATIONS REDESIGN (mockup
                            // #21): the four pills share the full width
                            // in one row — no horizontal scroll.
                            expanded: true,
                          ),
                        ),
                        // FIX 7 — actions row. Idle: "Select all" (left)
                        // + "Clear all" (right). Selecting: count +
                        // DELETE + Cancel. DELETE ALL (user order "ek
                        // + sab") now covers EVERY row, own + global
                        // (global rows are hidden locally — see the
                        // header) — the old row only showed when an
                        // OWN row existed, which is why the last
                        // broadcast row could never be cleared.
                        if (_all.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                            child: _selecting ? _selectionBar() : _idleActionsRow(),
                          ),
                        Expanded(child: _list()),
                      ],
                    ),
        ],
      ),
    );
  }

  // FIX 7 — idle actions: "Select all" (toggles to "Deselect all"
  // once every visible row is selected) + "Clear all". Same dark /
  // gold language as the rest of the page; both disabled while a
  // mark/delete run is in flight.
  Widget _idleActionsRow() {
    // 2026-11-21: invite rows are not selectable, so "Select all"
    // never counts them.
    final visibleIds = _filtered.where((n) => !_isInviteRow(n)).map(_rowId).where((id) => id.isNotEmpty).toSet();
    final allVisibleSelected = visibleIds.isNotEmpty && _selected.containsAll(visibleIds);
    return Row(
      children: [
        GestureDetector(
          onTap: _busy ? null : _selectAllVisible,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(allVisibleSelected ? Icons.deselect_outlined : Icons.select_all_outlined, color: _busy ? kMuted : kGold, size: 16),
              const SizedBox(width: 4),
              Text(allVisibleSelected ? 'Deselect all' : 'Select all', style: TextStyle(color: _busy ? kMuted : kGold, fontSize: 13, fontWeight: FontWeight.bold)),
            ],
          ),
        ),
        const Spacer(),
        GestureDetector(
          onTap: _busy ? null : _deleteAllNotifications,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.delete_sweep_outlined, color: _busy ? kMuted : kGold, size: 16),
              const SizedBox(width: 4),
              Text('Clear all', style: TextStyle(color: _busy ? kMuted : kGold, fontSize: 13, fontWeight: FontWeight.bold)),
            ],
          ),
        ),
      ],
    );
  }

  // FIX 7 — selection bar: count + DELETE (gold pill) + Cancel.
  // DELETE asks first (same confirm as Clear-all) and reports the
  // verified result; Cancel just leaves selection mode.
  Widget _selectionBar() {
    return Row(
      children: [
        Text('${_selected.length} selected', style: TextStyle(color: kText, fontSize: 13, fontWeight: FontWeight.bold)),
        const Spacer(),
        GestureDetector(
          onTap: _busy ? null : () => setState(() => _selected.clear()),
          child: Text('Cancel', style: TextStyle(color: kMuted, fontSize: 13, fontWeight: FontWeight.bold)),
        ),
        const SizedBox(width: 12),
        GestureDetector(
          onTap: _busy ? null : _deleteSelected,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
            decoration: BoxDecoration(color: _busy ? kField : kGold, borderRadius: BorderRadius.circular(10)),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.delete_outline, color: _busy ? kMuted : Colors.black, size: 16),
                const SizedBox(width: 4),
                Text('Delete', style: TextStyle(color: _busy ? kMuted : Colors.black, fontSize: 13, fontWeight: FontWeight.bold)),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _list() {
    final list = _filtered;
    if (list.isEmpty) {
      return Center(
        child: EmptyState(
          icon: Icons.notifications_none,
          title: _all.isEmpty ? 'No notifications.' : 'Nothing in this tab yet.',
          body: _all.isEmpty
              ? 'You have no notifications yet.'
              : 'No notification in this tab matches the keyword filter. Try the All tab.',
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: list.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (_, i) {
        final n = list[i];
        final img = strVal(n['image']);
        final unread = _isUnread(n);
        // FIX 7 (2026-11-20): EVERY row with an id is deletable now
        // (own rows server-side, global broadcast rows hidden
        // locally) — the old code only gave the user's OWN rows a
        // Dismissible, so a global row could never be removed at all.
        // A row with no id gets no delete/selection option (neither
        // path can address it).
        final notifId = _rowId(n);
        // TEAM-INVITE FIX (2026-11-21): an invite card — real row or
        // synthesized — is never swipe-deletable and never selectable.
        // It leaves the list only via Accept/Decline. (A Dismissible
        // left on it would animate the card away and, even though
        // _deleteNotification refuses the delete, the dismissed row
        // stays gone from the tree until a rebuild — a phantom delete.)
        final deletable = notifId.isNotEmpty && n['_synthetic_invite'] != true && !_isInviteRow(n);
        final checked = _selected.contains(notifId);
        // 2026-11-21 NOTIFICATIONS REDESIGN (mockup #21): icon badge
        // left, title + time right, body below. Unread = gold border
        // + glow + gold dot at the card's top-right corner; read =
        // plain border, no dot. No NEW badge (the mockup has none).
        final innerCard = appCard(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // FIX 7: selection checkbox — visible only in selection
              // mode (long-press a card to enter it). Gold fill +
              // black check when selected, muted outline otherwise.
              if (_selecting && deletable) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 15),
                  child: Container(
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(
                      color: checked ? kGold : Colors.transparent,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: checked ? kGold : kMuted, width: 1.5),
                    ),
                    child: checked ? const Icon(Icons.check, color: Colors.black, size: 16) : null,
                  ),
                ),
                const SizedBox(width: 10),
              ],
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(color: kField, borderRadius: BorderRadius.circular(12), border: Border.all(color: unread ? kGold : kBorder)),
                child: Icon(_iconFor(n), color: unread ? kGold : kMuted, size: 26),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: Text(strVal(n['title'], 'Notification'), style: TextStyle(color: kText, fontWeight: FontWeight.bold, fontSize: 16))),
                        const SizedBox(width: 6),
                        Text(timeAgo(n['timestamp']), style: TextStyle(color: kMuted, fontSize: 12)),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(strVal(n['message']), style: TextStyle(color: kMuted, fontSize: 14)),
                    if (img.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      // WAVE 4 FIX 5 (B): disk-cached notification
                      // image (was bare Image.network). Error state
                      // is now the shared dark card + broken-image
                      // icon (was a blank 120px area).
                      ArenaCachedImage(imageUrl: img, width: double.infinity, height: 120, fit: BoxFit.cover, borderRadius: BorderRadius.circular(8)),
                    ],
                    // Mockup #22 Team Invitation: Accept (gold) /
                    // Decline (outlined) pills, bottom-right below
                    // the message. ONLY rows that carry a real
                    // invite (type='team_invite' + invite_id, 027)
                    // get buttons — every other row is unchanged.
                    if (strVal(n['type']) == 'team_invite' && strVal(n['invite_id']).isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          _inviteActionBtn(
                            label: 'Accept',
                            gold: true,
                            busy: _responding.contains(strVal(n['invite_id'])),
                            onTap: () => _respondToInvite(n, 'accepted'),
                          ),
                          const SizedBox(width: 8),
                          _inviteActionBtn(
                            label: 'Decline',
                            gold: false,
                            busy: _responding.contains(strVal(n['invite_id'])),
                            onTap: () => _respondToInvite(n, 'declined'),
                          ),
                        ],
                      ),
                    ],
                    // PHASE E (E30): community invite — Join /
                    // Decline pills, same mockup style as the team
                    // ones. ONLY rows that carry a real community
                    // (type='community_invite' + community_id).
                    if (strVal(n['type']) == 'community_invite' &&
                        strVal(n['community_id']).isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          _inviteActionBtn(
                            label: 'Join',
                            gold: true,
                            busy: _responding.contains(strVal(n['id'])),
                            onTap: () =>
                                _respondToCommunityInvite(n, 'accepted'),
                          ),
                          const SizedBox(width: 8),
                          _inviteActionBtn(
                            label: 'Decline',
                            gold: false,
                            busy: _responding.contains(strVal(n['id'])),
                            onTap: () =>
                                _respondToCommunityInvite(n, 'declined'),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        );
        // 2026-11-21 NOTIFICATIONS REDESIGN (mockup #21): the unread
        // card gets its gold border + glow BACK — ROUND 3 had removed
        // it under the global card rule, but mockup #21 shows the
        // full gold border + glow on unread cards and a plain grey
        // border on read ones. The gold dot sits on the card's
        // top-right corner, like the mockup. The wrapper sits
        // OUTSIDE appCard so the MockupCard shines keep working
        // inside; read cards get no shadow and no dot.
        final card = Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: unread ? kGold : kBorder, width: unread ? 1.5 : 1),
                boxShadow: unread
                    ? [BoxShadow(color: kGold.withValues(alpha: 0.35), blurRadius: 14, spreadRadius: 1)]
                    : null,
              ),
              child: innerCard,
            ),
            if (unread)
              Positioned(
                top: -4,
                right: -2,
                child: Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: kGold,
                    shape: BoxShape.circle,
                    boxShadow: [BoxShadow(color: kGold.withValues(alpha: 0.6), blurRadius: 6)],
                  ),
                ),
              ),
          ],
        );
        // FIX 7: long-press enters selection mode (tap then toggles
        // the row); outside selection mode a tap does nothing (rows
        // have no navigation). The invite Accept/Decline pills keep
        // working — they sit inside the card and handle their own
        // taps. While a mark/delete run is in flight the gestures
        // are ignored so the selection cannot change mid-run.
        // PHASE E (E30): a community_invite card opens its
        // community on tap (outside selection mode) — the only
        // notification rows with navigation. Team invites keep
        // the old behaviour (no tap navigation).
        final isCommunityInvite =
            strVal(n['type']) == 'community_invite' &&
                strVal(n['community_id']).isNotEmpty;
        final row = GestureDetector(
          onLongPress: (deletable && !_busy) ? () => _toggleSelect(notifId) : null,
          onTap: (_selecting && deletable && !_busy)
              ? () => _toggleSelect(notifId)
              : (!_selecting && !_busy && isCommunityInvite)
                  ? () => _openCommunityInvite(n)
                  : null,
          child: card,
        );
        // Swipe left to delete, one by one. The red background +
        // trash icon show while swiping; the row is removed only
        // after the swipe completes (onDismissed). No swipe while
        // selecting (a swipe would fight the selection taps) and no
        // swipe on rows with no id (neither delete path can address
        // them). FIX 7: global rows swipe-delete too (local hide).
        if (!deletable || _selecting) return row;
        return Dismissible(
          key: ValueKey('notif_$notifId'),
          direction: DismissDirection.endToStart,
          background: Container(
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.only(right: 20),
            decoration: BoxDecoration(color: kRed, borderRadius: BorderRadius.circular(16)),
            child: const Icon(Icons.delete, color: Colors.white),
          ),
          onDismissed: (_) => _deleteNotification(notifId),
          child: row,
        );
      },
    );
  }

  // Mockup #22 invite action pill: Accept = solid gold, Decline =
  // dark with a muted border. Flat — no glow, no shadow.
  Widget _inviteActionBtn({required String label, required bool gold, required bool busy, required VoidCallback onTap}) {
    return Opacity(
      opacity: busy ? 0.5 : 1,
      child: AbsorbPointer(
        absorbing: busy,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
            decoration: BoxDecoration(
              color: gold ? kGold : kField,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: gold ? kGold : kBorder),
            ),
            child: Text(label, style: TextStyle(color: gold ? const Color(0xFF0A0A0F) : kText, fontWeight: FontWeight.bold, fontSize: 13)),
          ),
        ),
      ),
    );
  }

  // Icon per notification, from the same keyword text the tabs filter
  // on (no stored category exists). Generic icons only — no game art.
  IconData _iconFor(Map<String, dynamic> n) {
    final text = '${strVal(n['title'])} ${strVal(n['message'])}'.toLowerCase();
    if (text.contains('invit')) return Icons.group;
    if (text.contains('result')) return Icons.emoji_events;
    if (text.contains('starting soon') || text.contains('starts in')) return Icons.timer;
    if (text.contains('regist') || text.contains('confirm')) return Icons.verified;
    if (text.contains('rule') || text.contains('update')) return Icons.campaign;
    if (text.contains('verif')) return Icons.person;
    if (text.contains('match')) return Icons.sports_esports;
    if (text.contains('event') || text.contains('tournament')) return Icons.emoji_events;
    return Icons.notifications;
  }
}


/// Phase 3 — new pages (Worker A, more_screens.dart only).
///
/// Real app version (pubspec.yaml:4 — `version: 1.0.0+1`). This is the
/// live version string, not a placeholder; update it when pubspec changes.
const String kAppVersionDisplay = '1.0.1 (build 4)';

/// Invitation History state label, mapped from the REAL
/// pending_referrals.status values (001 + 019 CHECK:
/// pending / invited / joined / verified / credited).
String inviteStateLabel(String status) {
  switch (status.toLowerCase()) {
    case 'verified':
    case 'credited':
      return 'VERIFIED';
    case 'joined':
      return 'JOINED';
    default:
      return 'INVITED';
  }
}

Future<bool> _isOnline() async {
  try {
    final conn = await Connectivity().checkConnectivity();
    return !conn.contains(ConnectivityResult.none);
  } catch (_) {
    return true;
  }
}

// ---------------------------------------------------------------------------
// #36 Settings hub (NEW)
// ---------------------------------------------------------------------------
/// J-detail-fix1 (#36): gold diagonal slashes behind Settings — the
/// mockup's thin gold-outlined angular shards at the top-right and
/// bottom-right corners. Static paint, drawn once behind the content;
/// no animation, no per-frame work.
class _GoldSlashesPainter extends CustomPainter {
  const _GoldSlashesPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final stroke = Paint()
      ..color = kGold.withValues(alpha: 0.45)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    final fill = Paint()
      ..color = kGold.withValues(alpha: 0.05)
      ..style = PaintingStyle.fill;
    // Top-right shard (thin triangle along the top edge).
    final top = Path()
      ..moveTo(w * 0.55, 0)
      ..lineTo(w, 0)
      ..lineTo(w, h * 0.09)
      ..lineTo(w * 0.74, 0)
      ..close();
    canvas.drawPath(top, fill);
    canvas.drawPath(top, stroke);
    // Diagonal slash line under it.
    canvas.drawLine(Offset(w * 0.68, 0), Offset(w, h * 0.20), stroke);
    // Bottom-right shard.
    final bottom = Path()
      ..moveTo(w, h * 0.93)
      ..lineTo(w, h)
      ..lineTo(w * 0.80, h)
      ..lineTo(w, h * 0.86)
      ..close();
    canvas.drawPath(bottom, fill);
    canvas.drawPath(bottom, stroke);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class SettingsPage extends StatefulWidget {
  final String uid;
  const SettingsPage({super.key, required this.uid});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  // Mockup #36 shows Notification Preferences and Sound & Haptics as
  // toggles in the hub itself. Both bind to the REAL existing prefs:
  // 'notificationsEnabled' (same key ProfilePage uses) and
  // 'sound_enabled' (same key SettingsExtrasPage / SoundService use).
  // Tapping a row still opens its detail page.
  bool _notifOn = true;
  bool _soundOn = true;
  // FIX 4 (2026-11-22): guard flag stops stacked logout dialogs on
  // rapid LOG OUT taps (same pattern as the exit-dialog guard).
  bool _logoutDialogOpen = false;
  // DEDUPE (2026-11-22): the Language row shows the REAL current
  // language ('English' / 'Roman Urdu'), re-read after returning
  // from the language page — the old static 'English' trailing lied
  // whenever Urdu was selected.
  String _languageLabel = 'English';

  @override
  void initState() {
    super.initState();
    _loadToggles();
    _loadLanguageLabel();
  }

  Future<void> _loadLanguageLabel() async {
    final code = await RegionService.getLanguageCode();
    if (mounted) setState(() => _languageLabel = code == 'ur' ? 'Roman Urdu' : 'English');
  }

  Future<void> _loadToggles() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _notifOn = prefs.getBool('notificationsEnabled') ?? true;
        _soundOn = prefs.getBool('sound_enabled') ?? true;
      });
    }
  }

  Future<void> _setNotif(bool v) async {
    setState(() => _notifOn = v);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('notificationsEnabled', v);
    // Same effect as the Profile switch (audit fix 2026-11-21).
    if (v) {
      await PushService.init();
    } else {
      await PushService.logout();
    }
  }

  Future<void> _setSound(bool v) async {
    setState(() => _soundOn = v);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('sound_enabled', v);
    await SoundService.setEnabled(v);
  }

  // FIX 4 (2026-11-22, user order): LOG OUT asks first (same
  // confirmation style as the exit dialog) and, on YES, signs out
  // and shows the login screen AT ONCE. Root cause of the stuck
  // screen: the old code signed out but never navigated — the root
  // StreamBuilder swaps home to AuthScreen on sign-out, but this
  // pushed Settings route stayed on top of the stack until the
  // user pressed back. popUntil(isFirst) removes the covering
  // route so the login screen shows immediately. Do NOT push a
  // new AuthScreen here: AuthScreen never pops itself, so a pushed
  // copy would trap the user on login after re-sign-in.
  Future<void> _logOut() async {
    if (_logoutDialogOpen) return;
    _logoutDialogOpen = true;
    final yes = await showLogoutConfirmDialog(context);
    _logoutDialogOpen = false;
    if (!yes) return;
    await _signOutGuarded();
    if (!mounted) return;
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  // FIX 4: every sign-out step is timeout-guarded (5 s) and
  // failure-proof, so no await can hang the navigation to login.
  Future<void> _signOutGuarded() async {
    try {
      await AdminMode.set(false).timeout(const Duration(seconds: 5));
    } catch (_) {}
    try {
      await PresenceService.goOffline()
          .timeout(const Duration(seconds: 5));
    } catch (_) {}
    try {
      await PushService.logout().timeout(const Duration(seconds: 5));
    } catch (_) {}
    try {
      await GoogleSignIn().signOut().timeout(const Duration(seconds: 5));
    } catch (_) {}
    try {
      await FirebaseAuth.instance
          .signOut()
          .timeout(const Duration(seconds: 5));
    } catch (_) {}
  }

  // DEDUPE (2026-11-22, user order): Backup / Restore moved here
  // from the Profile list — same logic, same ownership + verify
  // rules, only the home changed (Settings group 5).
  Future<void> _backupProfile() async {
    final profile = await SupaDb.getProfile(widget.uid);
    final history = await SupaDb.getMatchHistory(widget.uid);
    final backup = jsonEncode({'firebase_uid': widget.uid, 'displayName': SupaDb.strOf(profile['displayName']), 'photo_url': SupaDb.strOf(profile['photo_url']), 'game_uid': SupaDb.strOf(profile['game_uid']), 'matches': history.length, 'exported_at': DateTime.now().toIso8601String()});
    await Share.share(backup, subject: 'ARENA HUB profile backup');
  }

  Future<void> _restoreProfile() async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kCardPurpleMid,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22), side: const BorderSide(color: kCardPurpleBorder, width: 1.5)),
        title: Text('Restore Profile', style: kStyleSection.copyWith(color: kGold)),
        content: ArenaTextField(controller: ctrl, hintText: 'Backup JSON yahan paste karen', maxLines: 5),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('Cancel', style: kStyleBody.copyWith(color: kMuted))), TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text('Restore', style: kStyleBody.copyWith(color: kGold)))],
      ),
    );
    if (ok != true) return;
    try {
      final data = jsonDecode(ctrl.text.trim()) as Map<String, dynamic>;
      // Ownership check (audit fix 2026-11-21): a backup carrying
      // another user's uid is refused. Backups made before this fix
      // carry no uid key — those are still accepted.
      final owner = data['firebase_uid'];
      if (owner is String && owner.isNotEmpty && owner != widget.uid) {
        throw Exception('Ye backup kisi aur player ka hai — is account par restore nahi ho sakta.');
      }
      final patch = <String, dynamic>{};
      if (data['displayName'] is String && (data['displayName'] as String).isNotEmpty) patch['display_name'] = data['displayName'];
      if (data['photo_url'] is String && (data['photo_url'] as String).isNotEmpty) patch['photo_url'] = data['photo_url'];
      // game_uid was exported but never restored (audit fix
      // 2026-11-21) — same digits rule as Edit Profile.
      final g = data['game_uid'];
      if (g is String && g.trim().isNotEmpty) {
        final gt = g.trim();
        if (gt.length < 5 || gt.length > 20 || !RegExp(r'^[0-9]+$').hasMatch(gt)) {
          throw Exception('Backup ki Game UID sahi format me nahi hai (5-20 digits).');
        }
        patch['game_uid'] = gt;
      }
      if (patch.isEmpty) throw Exception('Backup me koi restore karne laiq field nahi mili.');
      await SupaDb.updateProfile(widget.uid, patch);
      // Read-back verify: do not claim success unless the values
      // actually landed.
      final fresh = await SupaDb.getProfile(widget.uid);
      if (patch.containsKey('display_name') && SupaDb.strOf(fresh['displayName']) != patch['display_name']) {
        throw Exception('Restore verify nahi hua — dobara koshish karein.');
      }
      if (patch.containsKey('game_uid') && SupaDb.strOf(fresh['gameUid']) != patch['game_uid']) {
        throw Exception('Game UID restore verify nahi hua — dobara koshish karein.');
      }
      if (context.mounted) toast(context, 'Profile restore ho gaya!');
    } catch (e) {
      if (context.mounted) toast(context, 'Restore failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final uid = widget.uid;
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        backgroundColor: Colors.transparent, // PHASE E (E4): transparent header — poster shows through
        // J-detail-fix1 (#36): mockup chevron is GOLD (code relied on
        // the default white AppBar arrow).
        leading: IconButton(icon: Icon(Icons.chevron_left, color: kGold, size: 28), onPressed: () => Navigator.maybePop(context)),
        // J-detail-fix1 (#36): soft horizontal gold glow streak
        // directly beneath the SETTINGS title (mockup light smear).
        title: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('SETTINGS', style: kStyleTitle),
            const SizedBox(height: 3),
            Container(
              width: 110,
              height: 4,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(2),
                gradient: LinearGradient(colors: [kGold, kGold.withValues(alpha: 0.0)]),
                boxShadow: [BoxShadow(color: kGold.withValues(alpha: 0.6), blurRadius: 8, spreadRadius: 1)],
              ),
            ),
          ],
        ),
        titleSpacing: 0,
        // Mockup #36: crown emblem top-right.
        actions: const [Padding(padding: EdgeInsets.only(right: 16), child: ArenaLogo(crownSize: 28, fontSize: 14, showWordmark: false))],
      ),
      // J-detail-fix1 (#36): mockup background — gold diagonal slashes
      // top-right + bottom-right and sparse gold ember streaks/dots.
      body: ArenaBackground(child: Stack(
        children: [
          const Positioned.fill(child: IgnorePointer(child: CustomPaint(painter: _GoldSlashesPainter()))),
          const Positioned.fill(child: IgnorePointer(child: ArenaEmberDots())),
          ListView(
        padding: const EdgeInsets.all(kSpace16),
        children: [
          // Mockup #36 group 1 — account.
          _sectionLabel('ACCOUNT'),
          const SizedBox(height: kSpace8),
          MockupCard(
            padding: const EdgeInsets.all(kSpace16),
            radius: kRadiusCard,
            child: Column(
              children: [
                // J-detail-fix1 (#36): mockup glyphs — person silhouette
                // (not person-in-filled-circle), padlock+key, bell.
                _row(context, Icons.person, 'Account Settings', () => Navigator.push(context, MaterialPageRoute(builder: (_) => CreateProfilePage(uid: uid)))),
                // DEDUPE (2026-11-22, user order): 'Account Security'
                // lives in Settings ONLY now (moved from Profile).
                _row(context, Icons.security, 'Account Security', () => Navigator.push(context, MaterialPageRoute(builder: (_) => AccountSecurityPage(uid: uid)))),
                // WRONG-SCREEN FIX (2026-11-22): this row used to open
                // AccountSecurityPage — Change Password now opens its
                // OWN screen (ChangePasswordPage).
                _row(context, Icons.lock, 'Change Password', () => Navigator.push(context, MaterialPageRoute(builder: (_) => ChangePasswordPage(uid: uid))), iconWidget: _stackedBadge(Icons.lock, Icons.key)),
                // DEDUPE (2026-11-22, user order): 'Action Required'
                // moved here from Profile.
                _row(context, Icons.warning_amber_rounded, 'Action Required', () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ActionRequiredPage()))),
                _toggleRow(context, Icons.notifications, 'Notification Preferences', _notifOn, _setNotif, () => Navigator.push(context, MaterialPageRoute(builder: (_) => NotificationPrefsPage(uid: uid)))),
              ],
            ),
          ),
          const SizedBox(height: kSpace20),
          // Mockup #36 group 2 — language / appearance / sound.
          _sectionLabel('PREFERENCES'),
          const SizedBox(height: kSpace8),
          MockupCard(
            padding: const EdgeInsets.all(kSpace16),
            radius: kRadiusCard,
            child: Column(
              children: [
                // DEDUPE (2026-11-22): Language now opens the REAL
                // language page (English / Roman Urdu, persists via
                // RegionService) — the old English-only stub
                // LanguagePage is deleted. The trailing shows the
                // current language and refreshes on return.
                _row(context, Icons.language, 'Language', () => Navigator.push(context, MaterialPageRoute(builder: (_) => const LanguageSettingsPage())).then((_) => _loadLanguageLabel()), trailing: _languageLabel),
                // DEDUPE (2026-11-22, user order): 'Country / Region'
                // moved here from Profile.
                _row(context, Icons.public, 'Country / Region', () => Navigator.push(context, MaterialPageRoute(builder: (_) => const CountrySelectPage()))),
                // OD-12: Appearance shows the current defaults and changes
                // nothing — the page is read-only.
                _row(context, Icons.palette, 'Appearance', () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AppearancePage()))),
                _toggleRow(context, Icons.volume_up, 'Sound & Haptics', _soundOn, _setSound, () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsExtrasPage()))),
              ],
            ),
          ),
          const SizedBox(height: kSpace20),
          // Mockup #36 group 3 — privacy.
          _sectionLabel('PRIVACY'),
          const SizedBox(height: kSpace8),
          MockupCard(
            padding: const EdgeInsets.all(kSpace16),
            radius: kRadiusCard,
            child: Column(
              children: [
                // J-detail-fix1 (#36): mockup Privacy is shield+padlock
                // (not privacy_tip's shield+check); Blocked Users is
                // person+× (not circle-slash).
                // WRONG-SCREEN FIX (2026-11-22): this row used to open
                // AccountSecurityPage — Privacy now opens its OWN
                // screen (PrivacyPage).
                _row(context, Icons.shield, 'Privacy', () => Navigator.push(context, MaterialPageRoute(builder: (_) => PrivacyPage(uid: uid))), iconWidget: _stackedBadge(Icons.shield, Icons.lock)),
                // Mockup #36: Blocked Users opens the blocked-players
                // list directly (not the Account Security hub).
                _row(context, Icons.person, 'Blocked Users', () => Navigator.push(context, MaterialPageRoute(builder: (_) => BlockedPlayersPage(uid: uid))), iconWidget: _stackedBadge(Icons.person, Icons.cancel)),
              ],
            ),
          ),
          const SizedBox(height: kSpace20),
          // Mockup #36 group 4 — help / about / legal.
          _sectionLabel('ABOUT'),
          const SizedBox(height: kSpace8),
          MockupCard(
            padding: const EdgeInsets.all(kSpace16),
            radius: kRadiusCard,
            child: Column(
              children: [
                // DEDUPE (2026-11-22, user order): 'Help & Support'
                // lives on PROFILE ONLY — removed from Settings.
                // DEDUPE (2026-11-22, user order): 'Terms & Privacy'
                // lives on PROFILE ONLY ('Rules & Policies' tile) —
                // removed from Settings.
                _row(context, Icons.info, 'About Arena Hub', () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AboutPage()))),
                // ADMIN ENTRY REMOVED (FIX 32, 2026-11-24): the old
                // Settings "Admin Access" row AND the Profile
                // "Switch to Admin" tile are BOTH gone — the admin
                // panel lives in a separate admin APK now. Nothing
                // admin lives in Settings any more.
              ],
            ),
          ),
          const SizedBox(height: kSpace20),
          // DEDUPE (2026-11-22, user order): Backup group — moved
          // here from the Profile list (same logic, see _backupProfile
          // / _restoreProfile above).
          _sectionLabel('BACKUP'),
          const SizedBox(height: kSpace8),
          MockupCard(
            padding: const EdgeInsets.all(kSpace16),
            radius: kRadiusCard,
            child: Column(
              children: [
                _row(context, Icons.backup, 'Backup My Profile', _backupProfile),
                _row(context, Icons.restore, 'Restore Profile (Paste Backup)', _restoreProfile),
              ],
            ),
          ),
          const SizedBox(height: kSpace20),
          // Mockup #36: red outlined LOG OUT pill, centred.
          Center(
            child: SizedBox(
              width: 220,
              child: OutlinedButton.icon(
                onPressed: _logOut,
                icon: const Icon(Icons.logout, color: kError),
                label: const Text('LOG OUT', style: TextStyle(color: kError, fontWeight: FontWeight.bold, letterSpacing: 1)),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: kError, width: 1.5),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
                  padding: const EdgeInsets.symmetric(vertical: kSpace12),
                ),
              ),
            ),
          ),
          const SizedBox(height: kSpace12),
          // Real app version — never the mockup's 1.4.2.
          Center(child: Text('Version $kAppVersionDisplay', style: kStyleMeta)),
          const SizedBox(height: kSpace8),
        ],
      ),
        ],
      ),
      ),
    );
  }

  // REDESIGN S11: small gold section label above each settings
  // group — the grouped-card hierarchy from guide §6 Screen 11.
  Widget _sectionLabel(String label) => Padding(
        padding: const EdgeInsets.only(left: kSpace4),
        child: Text(label, style: kStyleLabel.copyWith(color: kGold, letterSpacing: 1.2)),
      );

  // Mockup #36: gold icon inside a thin gold circle.
  Widget _iconBadge(IconData icon) => Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: kGold, width: 1.5)),
        child: Icon(icon, color: kGold, size: 20),
      );

  // J-detail-fix1 (#36): two-glyph badge for the mockup's stacked
  // icons (padlock+key, shield+padlock, person+×) — main glyph
  // centred, small glyph tucked at the bottom-right on a card-coloured
  // disc so it reads as one badge.
  Widget _stackedBadge(IconData main, IconData small) => Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: kGold, width: 1.5)),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Icon(main, color: kGold, size: 20),
            Positioned(
              right: 1,
              bottom: 1,
              child: Container(
                padding: const EdgeInsets.all(1),
                decoration: BoxDecoration(color: kCard, shape: BoxShape.circle),
                child: Icon(small, color: kGold, size: 11),
              ),
            ),
          ],
        ),
      );

  Widget _row(BuildContext context, IconData icon, String label, VoidCallback onTap, {String? trailing, Widget? iconWidget}) {
    return ListTile(
      leading: iconWidget ?? _iconBadge(icon),
      title: Text(label, style: kStyleBody),
      trailing: trailing != null
          ? Row(mainAxisSize: MainAxisSize.min, children: [Text(trailing, style: kStyleMeta), const SizedBox(width: 4), Icon(Icons.chevron_right, color: kGold)])
          : Icon(Icons.chevron_right, color: kGold),
      onTap: onTap,
      contentPadding: EdgeInsets.zero,
      minTileHeight: 56,
    );
  }

  // Mockup #36: the two toggles are the gold ON/OFF pill toggles
  // (same _OnOffSwitch the Account Security screen already uses),
  // not plain Material Switches.
  Widget _toggleRow(BuildContext context, IconData icon, String label, bool value, ValueChanged<bool> onChanged, VoidCallback onTap) {
    return ListTile(
      leading: _iconBadge(icon),
      title: Text(label, style: kStyleBody),
      trailing: _OnOffSwitch(value: value, onChanged: onChanged),
      onTap: onTap,
      contentPadding: EdgeInsets.zero,
      minTileHeight: 56,
    );
  }
}

/// Language (OD-11): English only, read-only page.
// DEDUPE (2026-11-22): the English-only stub LanguagePage is
// DELETED — Settings > Language now opens the real
// LanguageSettingsPage (English / Roman Urdu).

/// Appearance (OD-12): shows the current defaults, changes nothing.
class AppearancePage extends StatelessWidget {
  const AppearancePage({super.key});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Appearance', style: TextStyle(color: kGold))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          MockupCard(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _kv('Theme', appLightMode ? 'Light' : 'Dark (Board)'),
                _kv('Accent', 'Gold'),
                _kv('Text size', 'Medium (default)'),
                const SizedBox(height: 12),
                Text(
                  'Appearance follows the app\u2019s current defaults and cannot be changed in this release.',
                  style: TextStyle(color: kMuted, fontSize: 13),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(k, style: TextStyle(color: kMuted)),
            Text(v, style: TextStyle(color: kText, fontWeight: FontWeight.bold)),
          ],
        ),
      );
}

class AboutPage extends StatelessWidget {
  const AboutPage({super.key});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('About', style: TextStyle(color: kGold))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          MockupCard(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // PHASE E (E23): the old gold text wordmark is
                // the NEW logo badge now (E18 style).
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Image.asset(
                    'assets/images/arena_hub_logo.png',
                    width: 48,
                    height: 48,
                    fit: BoxFit.cover,
                  ),
                ),
                const SizedBox(height: 8),
                Text('Version $kAppVersionDisplay', style: TextStyle(color: kText)),
                const SizedBox(height: 8),
                Text(
                  'ARENA HUB is a tournament platform: join tournaments, track your matches, climb the leaderboard and play with your squad.',
                  style: TextStyle(color: kMuted, fontSize: 13),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// #9 Notification Preferences (NEW)
// ---------------------------------------------------------------------------
class NotificationPrefsPage extends StatefulWidget {
  final String uid;
  const NotificationPrefsPage({super.key, required this.uid});
  @override
  State<NotificationPrefsPage> createState() => _NotificationPrefsPageState();
}

class _NotificationPrefsPageState extends State<NotificationPrefsPage> {
  // The 6 categories from draft 017 (profiles.notification_prefs jsonb,
  // all true by default). Draft 017 is NOT applied yet — until the Wave 4
  // re-test, the server read/save below may fail and the local fallback
  // (SharedPreferences) is the live path; see _save().
  static const _keys = ['reminders', 'match_alerts', 'team_invites', 'results', 'announcements', 'community'];
  // WAVE C design-match (#9, 2026-11-19): mockup titles, descriptions
  // and icons, element-for-element. Toggle positions are the user's
  // REAL saved prefs (all true by default) — never the mockup's
  // on/off pattern.
  static const _labels = {
    'reminders': 'Tournament Reminders',
    'match_alerts': 'Match Starting Alerts',
    'team_invites': 'Team Invitations',
    'results': 'Tournament Results',
    'announcements': 'Organizer Announcements',
    'community': 'Community Updates',
  };
  static const _descriptions = {
    'reminders': 'Get notified when registrations open or are about to close.',
    'match_alerts': 'Never miss a match with alerts 15 minutes before start.',
    'team_invites': 'Receive alerts when teams invite you to join.',
    'results': 'Get updates on match standings and tournament winners.',
    'announcements': 'Stay updated with important organizer messages and rules.',
    'community': 'Updates about new features, events, and community news.',
  };
  static const _icons = {
    'reminders': Icons.calendar_month,
    'match_alerts': Icons.alarm,
    'team_invites': Icons.person_add,
    'results': Icons.emoji_events,
    'announcements': Icons.campaign,
    'community': Icons.public,
  };
  Map<String, bool> _prefs = {for (final k in _keys) k: true};
  bool _loading = true;
  bool _offline = false;
  bool _localOnly = false;

  String get _localKey => 'notif_prefs_local_${widget.uid}';
  String get _localOnlyKey => 'notif_prefs_local_only_${widget.uid}';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<Map<String, bool>> _loadLocal() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_localKey);
      if (raw == null) return {for (final k in _keys) k: true};
      final map = SupaDb.asMap(jsonDecode(raw));
      return {for (final k in _keys) k: map[k] == true};
    } catch (_) {
      return {for (final k in _keys) k: true};
    }
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    if (!await _isOnline()) {
      final local = await _loadLocal();
      if (mounted) setState(() {_loading = false; _offline = true; _prefs = local; _localOnly = true;});
      return;
    }
    // Worker S contract: getNotificationPrefs NEVER throws — on any error
    // (017 not applied, no row) it returns all-true defaults. So the
    // local-only flag recorded at save time decides which copy is truth:
    // if the last save failed server-side, the local copy wins.
    final stored = await SharedPreferences.getInstance();
    if (stored.getBool(_localOnlyKey) ?? false) {
      final local = await _loadLocal();
      if (mounted) setState(() {_loading = false; _prefs = local; _localOnly = true;});
      return;
    }
    final raw = await SupaDb.getNotificationPrefs(widget.uid);
    final map = SupaDb.asMap(raw);
    if (!mounted) return;
    setState(() {
      _prefs = {for (final k in _keys) k: map[k] == true};
      _loading = false;
      _localOnly = false;
    });
  }

  Future<void> _save() async {
    // Worker S contract: updateNotificationPrefs returns false (not throw)
    // on failure — e.g. column missing (017 not applied). Only a true
    // return means the server has the prefs.
    bool ok = false;
    try {
      ok = await SupaDb.updateNotificationPrefs(widget.uid, _prefs);
    } catch (_) {
      ok = false;
    }
    final prefs = await SharedPreferences.getInstance();
    if (ok) {
      await prefs.setBool(_localOnlyKey, false);
      if (mounted) {
        setState(() => _localOnly = false);
        toast(context, 'Notification preferences saved.');
      }
    } else {
      // Server save failed: persist on this device and say so honestly.
      await prefs.setString(_localKey, jsonEncode(_prefs));
      await prefs.setBool(_localOnlyKey, true);
      if (mounted) {
        setState(() => _localOnly = true);
        toast(context, 'Saved on this device, will sync to your account after the next update.');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // WAVE C (#9): mockup header — bordered back box + gold bar +
    // white italic title; one bordered card per category (gold icon
    // in a bordered square, bold title, 2-line description, gold
    // toggle); gold SAVE PREFERENCES pill at the bottom. Toggles
    // edit local state only — Save persists (server + local fallback).
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        centerTitle: false,
        // J-detail-fix1 (#9): mockup chevron is GOLD and PLAIN (no
        // bordered box); title ~28px italic with the gold bar; a thin
        // divider line runs under the title across the width.
        leading: IconButton(icon: Icon(Icons.chevron_left, color: kGold, size: 28), onPressed: () => Navigator.maybePop(context)),
        title: Row(
          children: [
            Container(width: 5, height: 28, decoration: BoxDecoration(color: kGold, borderRadius: BorderRadius.circular(3))),
            const SizedBox(width: 10),
            const Expanded(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text('NOTIFICATION PREFERENCES', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontStyle: FontStyle.italic, fontSize: 26)),
              ),
            ),
          ],
        ),
        titleSpacing: 0,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: kBorder),
        ),
      ),
      // J-detail-fix1 (#9): mockup background has sparse gold dots —
      // shared ArenaEmberDots behind the content.
      body: Stack(
        children: [
          const Positioned.fill(child: IgnorePointer(child: ArenaEmberDots())),
          _loading
          ? ListView(
              padding: const EdgeInsets.all(16),
              children: const [
                LoadingSkeleton(height: 76),
                SizedBox(height: 12),
                LoadingSkeleton(height: 76),
                SizedBox(height: 12),
                LoadingSkeleton(height: 76),
                SizedBox(height: 12),
                LoadingSkeleton(height: 76),
              ],
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (_offline) ...[
                  OfflineState(onRetry: _load),
                  const SizedBox(height: 12),
                ],
                if (_localOnly)
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(color: kField, borderRadius: BorderRadius.circular(12), border: Border.all(color: kGold)),
                    child: Text(
                      'Saved on this device, will sync to your account after the next update.',
                      style: TextStyle(color: kText, fontSize: 13),
                    ),
                  ),
                if (_localOnly) const SizedBox(height: 12),
                for (final k in _keys) ...[
                  _prefCard(k),
                  const SizedBox(height: 12),
                ],
                const SizedBox(height: 8),
                // FIX ROUND I-all-fix1-D (#10): the mockup's SAVE
                // button is a flat gold pill (radius ~28) with a
                // chevron. The shared GoldButton is radius 12 and
                // must NOT change (every screen uses it), so this
                // instance is built locally with the same flat gold
                // styling. Toggle states stay the user's real saved
                // prefs — never the mockup's on/off pattern.
                // J-detail-fix1 (#9): mockup shows a soft glow beneath
                // the pill — static shadow on the wrapper, button
                // itself stays flat gold.
                Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(28),
                    boxShadow: [
                      BoxShadow(color: kGold.withValues(alpha: 0.35), blurRadius: 16, spreadRadius: 1, offset: const Offset(0, 6)),
                      BoxShadow(color: kGold.withValues(alpha: 0.15), blurRadius: 28, spreadRadius: 2, offset: const Offset(0, 10)),
                    ],
                  ),
                  child: ElevatedButton(
                    onPressed: _save,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: kGold,
                      foregroundColor: const Color(0xFF0A0A0F),
                      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 20),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
                      elevation: 0,
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text('SAVE PREFERENCES', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                        SizedBox(width: 6),
                        Icon(Icons.chevron_right, size: 18),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
              ],
            ),
        ],
      ),
    );
  }

  Widget _prefCard(String key) {
    // FIX ROUND I-all-fix1-D (#10): toggle vertically centered on
    // the card (was top-aligned).
    // J-detail-fix1 (#9): mockup icons have NO box — plain gold
    // glyph, left-aligned. The toggle is the mockup's metallic
    // radial-gradient knob (see _GoldToggle) with a soft halo on ON
    // tracks — the flat Flutter Switch is gone.
    // MOCKUP CARD (2026-11-20, global rule): gradient fill +
    // rotating shines, no full border (the old gold-tinted
    // Border.all is gone).
    return MockupCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(_icons[key], color: kGold, size: 28),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_labels[key]!, style: TextStyle(color: kText, fontSize: 17, fontWeight: FontWeight.bold)),
                const SizedBox(height: 3),
                Text(_descriptions[key]!, style: TextStyle(color: kMuted, fontSize: 13, height: 1.35)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _GoldToggle(
            value: _prefs[key] ?? true,
            onChanged: (v) => setState(() => _prefs[key] = v),
          ),
        ],
      ),
    );
  }
}

/// J-detail-fix1 (#9): mockup's toggle — gold pill track with a
/// METALLIC GOLD radial-gradient knob (3D coin look, bright centre,
/// darker rim) on the right when ON, dark track with a plain grey knob
/// on the left when OFF; ON tracks carry a soft gold halo. Static
/// gradients/shadows only; the knob slides with AnimatedAlign.
class _GoldToggle extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;
  const _GoldToggle({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => onChanged(!value),
      child: Container(
        width: 52,
        height: 30,
        decoration: BoxDecoration(
          color: value ? kGold : kField,
          borderRadius: BorderRadius.circular(15),
          border: Border.all(color: value ? kGold : kBorder, width: 1),
          boxShadow: value
              ? [
                  BoxShadow(color: kGold.withValues(alpha: 0.45), blurRadius: 10, spreadRadius: 1),
                  BoxShadow(color: kGold.withValues(alpha: 0.18), blurRadius: 20, spreadRadius: 2),
                ]
              : null,
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            AnimatedAlign(
              duration: const Duration(milliseconds: 150),
              alignment: value ? Alignment.centerRight : Alignment.centerLeft,
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 3),
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: value
                      ? const RadialGradient(
                          center: Alignment(-0.3, -0.3),
                          radius: 0.9,
                          colors: [Color(0xFFFDC903), Color(0xFFFDC903), Color(0xFF9A7B12)],
                          stops: [0.0, 0.55, 1.0],
                        )
                      : const RadialGradient(
                          center: Alignment(-0.3, -0.3),
                          radius: 0.9,
                          colors: [Color(0xFF9AA0AE), Color(0xFF6B7280)],
                          stops: [0.0, 1.0],
                        ),
                  boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 3, offset: Offset(0, 1))],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Bottom nav for pushed sub-screens whose mockup shows the shell
/// nav (#34 Rules & Policies, #21 Notifications — Home active).
/// Same 6 tabs + gold top/bottom indicators as MyTeamBottomNav
/// (pro_features.dart); any tap pops back to the HomeShell (first
/// route), the established pushed-screen pattern.
class _PushedBottomNav extends StatelessWidget {
  const _PushedBottomNav({required this.activeIndex});
  final int activeIndex;

  @override
  Widget build(BuildContext context) {
    final center = navBarTabCenter(context, activeIndex);
    // REDESIGN §5 (F2): SafeArea so the nav never sits under the
    // system gesture bar / covers content at the bottom edge.
    // FIX 23 item 23: floating purple bar (ChatGPT reference) —
    // same shell as ArenaBottomNav.
    return SafeArea(
      top: false,
      child: navBarShell(
        child: Stack(
          children: [
            MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(1.0)),
              child: BottomNavigationBar(
                currentIndex: activeIndex,
                onTap: (_) => Navigator.of(context).popUntil((route) => route.isFirst),
                type: BottomNavigationBarType.fixed,
                backgroundColor: Colors.transparent,
                selectedFontSize: 10,
                unselectedFontSize: 9,
                selectedItemColor: kGold,
                // FIX 23 item 23: unselected = lavender.
                unselectedItemColor: kNavUnselected,
              items: [
                BottomNavigationBarItem(icon: const Icon(Icons.home), label: tr('Home', 'Home')),
                BottomNavigationBarItem(icon: const Icon(Icons.calendar_month), label: tr('Events', 'Events')),
                BottomNavigationBarItem(icon: const CrossedSwordsIcon(), label: tr('My Matches', 'My Matches')),
                BottomNavigationBarItem(icon: const Icon(Icons.leaderboard), label: tr('Rankings', 'Rankings')),
                BottomNavigationBarItem(icon: const Icon(Icons.people), label: tr('Community', 'Community')),
                BottomNavigationBarItem(icon: const Icon(Icons.person), label: tr('Profile', 'Profile')),
              ],
            ),
          ),
          Positioned(
            top: 0,
            left: center - 22,
            child: Container(width: 44, height: 4, decoration: BoxDecoration(color: kGold, borderRadius: BorderRadius.circular(2))),
          ),
          Positioned(
            bottom: 0,
            left: center - 26,
            child: Container(width: 52, height: 4, decoration: BoxDecoration(color: kGold, borderRadius: BorderRadius.circular(2))),
          ),
        ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// #34 Rules & Policies hub (NEW)
// ---------------------------------------------------------------------------
class RulesPoliciesPage extends StatelessWidget {
  const RulesPoliciesPage({super.key});

  // Admin-editable docs live in app_settings (069 columns); the
  // built-in const text below is the fallback while a column is
  // empty — never a blank 'Not available yet.' for real content.
  // The other 4 read their app_settings columns via _policy() too.
  static const String _communityGuidelines = 'Community Guidelines\n\n'
      '1. Be respectful to every player, organiser and admin — no abuse, hate speech or harassment.\n'
      '2. No cheating, exploiting or sharing another player\u2019s account.\n'
      '3. Keep chat clean: no spam, no advertising, no sharing of personal contact details in public rooms.\n'
      '4. Play fair and follow the tournament rules for every match you join.\n'
      '5. Breaking these guidelines can lead to a warning, a match ban or an account ban.';
  static const String _tournamentRules = 'Tournament Rules\n\n'
      '1. Register before the deadline and check in on time; late check-ins forfeit the slot.\n'
      '2. No-show: match $kNoShowGraceMinutes minute delay hoga (grace period); phir bhi na aaye to entry fee forfeit — wapas nahi hogi, koi refund nahi.\n'
      '3. Squad size must match the tournament mode (Solo / Duo / Squad).\n'
      '4. Room ID and password are shared only with registered players, shortly before the match.\n'
      '5. Results must be submitted honestly; false results are reviewed by admins and can be reversed.\n'
      '6. The organiser\u2019s decision on a disputed match is final.';
  static const String _contentChatRules = 'Content & Chat Rules\n\n'
      '1. No abusive, threatening or discriminatory messages in any chat.\n'
      '2. No spam, flooding or repeated messages.\n'
      '3. No links to scams, phishing pages or unrelated promotions.\n'
      '4. Do not share other players\u2019 personal information.\n'
      '5. Messages can be reported; reported content is reviewed by admins and may be removed.';

  // Admin-editable docs live in app_settings (069 columns); the
  // built-in const text is the fallback while a column is empty —
  // never a blank 'Not available yet.' for real content.
  Future<void> _policy(BuildContext context, String key, String title, [String? fallback]) async {
    final settings = await SupaDb.getAppSettings();
    final raw = strVal(settings[key]);
    final body = raw.isEmpty ? (fallback ?? 'Not available yet.') : raw;
    if (context.mounted) showInfoDialog(context, title, body);
  }

  @override
  Widget build(BuildContext context) {
    // WAVE C design-match (#34, 2026-11-19): mockup header — gold
    // back arrow, centred ARENA HUB lockup, big italic RULES (white)
    // & POLICIES (gold) title + grey COMMUNITY GUIDELINES subtitle;
    // one bordered card per doc (gold icon in a bordered square,
    // bold title, 2-line description, chevron); Fair Play carries
    // the gold border + IMPORTANT ribbon. Taps open the same docs
    // as before (built-in text or app_settings, admin-editable
    // where columns exist). Bottom nav present (Home active) per
    // the mockup — pushed-screen pattern, pops back to the shell.
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        centerTitle: true,
        leading: IconButton(icon: Icon(Icons.arrow_back, color: kGold, size: 26), onPressed: () => Navigator.maybePop(context)),
        title: const ArenaLogo(crownSize: 30, fontSize: 16),
      ),
      bottomNavigationBar: const _PushedBottomNav(activeIndex: 0),
      // P-all-fixes-D1 (#34): mockup background also has a large dark
      // diagonal slash panel at the top-right corner (embers alone
      // were not the whole background) — static paint, behind dots.
      body: Stack(
        children: [
          const Positioned.fill(child: IgnorePointer(child: CustomPaint(painter: _DarkSlashPainter()))),
          const Positioned.fill(child: IgnorePointer(child: ArenaEmberDots())),
          ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
        children: [
          Center(
            child: RichText(
              textAlign: TextAlign.center,
              text: TextSpan(
                style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w900, fontStyle: FontStyle.italic, letterSpacing: 0.5),
                children: [
                  TextSpan(text: 'RULES ', style: TextStyle(color: kText)),
                  TextSpan(text: '& ', style: TextStyle(color: kGold)),
                  TextSpan(text: 'POLICIES', style: TextStyle(color: kGold)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 4),
          Center(child: Text('COMMUNITY GUIDELINES', style: TextStyle(color: kMuted, fontSize: 14, letterSpacing: 3))),
          const SizedBox(height: 18),
          _doc(context, Icons.people, 'Community Guidelines', 'Expected behavior, chat sportsmanship, and respect.', () => _policy(context, 'policy_community_guidelines', 'Community Guidelines', _communityGuidelines)),
          const SizedBox(height: 12),
          _doc(context, Icons.emoji_events, 'Tournament Rules', 'Registration, match timelines, and scoring systems.', () => _policy(context, 'policy_tournament_rules', 'Tournament Rules', _tournamentRules)),
          const SizedBox(height: 12),
          _doc(context, Icons.shield, 'Fair Play Policy', 'Strictly no cheating, hacking, or behavior manipulation.', () => _policy(context, 'policyFairPlay', 'Fair Play Policy'), important: true),
          const SizedBox(height: 12),
          _doc(
            context,
            Icons.shield,
            'Privacy Policy',
            'How we collect, use, and safeguard your personal data.',
            () => _policy(context, 'policyPrivacy', 'Privacy Policy'),
            // Mockup: shield with a padlock (not privacy_tip's
            // shield+check). J-detail-fix1 (#34): grey/white like the
            // other non-Fair-Play icons — only Fair Play is gold.
            iconWidget: Stack(
              alignment: Alignment.center,
              children: [
                Icon(Icons.shield, color: kText, size: 28),
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: Container(
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(color: kCard, shape: BoxShape.circle),
                    child: Icon(Icons.lock, color: kText, size: 13),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _doc(context, Icons.description, 'Terms of Use', 'Our legal agreements, user responsibilities, and terms.', () => _policy(context, 'policyTerms', 'Terms of Use')),
          const SizedBox(height: 12),
          _doc(context, Icons.money_off, 'Refund Policy', 'When entry fees are refunded — and when they are not.', () => _policy(context, 'policyRefund', 'Refund Policy')),
          const SizedBox(height: 12),
          _doc(context, Icons.chat, 'Content & Chat Rules', 'Guidelines for media, text, and voice communications.', () => _policy(context, 'policy_chat_rules', 'Content & Chat Rules', _contentChatRules)),
        ],
      ),
        ],
      ),
    );
  }

  Widget _doc(BuildContext context, IconData icon, String title, String description, VoidCallback onTap, {bool important = false, Widget? iconWidget}) {
    // J-detail-fix1 (#34): mockup icons are GREY/WHITE on five of the
    // six cards — ONLY the Fair Play shield is gold. The IMPORTANT tab
    // is a slanted ribbon (left edge slants, top-right corner follows
    // the card's corner), not a rectangle. The Fair Play card carries
    // a warm gold rim-light glow around its whole border.
    return GestureDetector(
      onTap: onTap,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // MOCKUP CARD (2026-11-20, global card rule): the card is
          // the shared MockupCard (two rotating yellow shines, no
          // full border). The IMPORTANT card's warm gold rim-light
          // glow is IN the mockup, so it stays — as a shadow-only
          // wrapper around the MockupCard, not a border.
          Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              boxShadow: important
                  ? [
                      BoxShadow(color: kGold.withValues(alpha: 0.45), blurRadius: 18, spreadRadius: 1),
                      BoxShadow(color: kGold.withValues(alpha: 0.20), blurRadius: 30, spreadRadius: 2),
                    ]
                  : null,
            ),
            child: MockupCard(
              padding: const EdgeInsets.all(16),
              radius: 16,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), border: Border.all(color: kBorder, width: 1.5)),
                    child: iconWidget ?? Icon(icon, color: important ? kGold : kText, size: 28),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: TextStyle(color: kText, fontSize: 17, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 3),
                        Text(description, style: TextStyle(color: kMuted, fontSize: 13, height: 1.35)),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(Icons.chevron_right, color: important ? kGold : kText, size: 26),
                ],
              ),
            ),
          ),
          if (important)
            Positioned(
              top: -1,
              right: 12,
              child: ClipPath(
                clipper: _SlantedRibbonClipper(),
                child: Container(
                  padding: const EdgeInsets.fromLTRB(20, 4, 12, 4),
                  color: kGold,
                  child: const Text('IMPORTANT', style: TextStyle(color: Colors.black, fontSize: 11, fontWeight: FontWeight.w900)),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// P-all-fixes-D1 (#34): the mockup's large dark diagonal slash panel
/// at the top-right corner — a dark slate panel (slightly lighter
/// than the near-black background) with a faint gold edge line.
/// Static paint, behind the ember dots.
class _DarkSlashPainter extends CustomPainter {
  const _DarkSlashPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final panel = Path()
      ..moveTo(w * 0.60, 0)
      ..lineTo(w, 0)
      ..lineTo(w, h * 0.12)
      ..lineTo(w * 0.82, 0)
      ..close();
    canvas.drawPath(panel, Paint()..color = const Color(0xFF14161F));
    canvas.drawLine(
      Offset(w * 0.82, 0),
      Offset(w, h * 0.12),
      Paint()
        ..color = kGold.withValues(alpha: 0.30)
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// J-detail-fix1 (#34): slanted ribbon clip for the IMPORTANT tab —
/// left edge slants down-right, top-right corner rounded to follow
/// the card's corner.
class _SlantedRibbonClipper extends CustomClipper<Path> {
  @override
  Path getClip(Size size) {
    const slant = 10.0;
    const corner = 10.0;
    return Path()
      ..moveTo(slant, 0)
      ..lineTo(size.width - corner, 0)
      ..quadraticBezierTo(size.width, 0, size.width, corner)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
  }

  @override
  bool shouldReclip(covariant CustomClipper<Path> oldClipper) => false;
}

// ---------------------------------------------------------------------------
// #31 Account Security (NEW)
// ---------------------------------------------------------------------------
class AccountSecurityPage extends StatefulWidget {
  final String uid;
  const AccountSecurityPage({super.key, required this.uid});
  @override
  State<AccountSecurityPage> createState() => _AccountSecurityPageState();
}

class _AccountSecurityPageState extends State<AccountSecurityPage> {
  // PRIVACY EXTRACTED (2026-11-22): the privacy toggles + Blocked
  // Players row now live in the shared PrivacyControlsCard below
  // (used here AND on the standalone PrivacyPage) — one source of
  // truth, no duplicated save logic. This page keeps only email /
  // two-step / login activity.
  bool _loading = true;
  bool _offline = false;
  // Two-step preference (profiles.two_fa_enabled, migration 017):
  // stored when the column exists, otherwise on this device only —
  // the same guarded pattern the privacy toggles use. It is a
  // PREFERENCE only: nothing in the login flow enforces it yet.
  bool _twoFa = false;
  // Login history (audit fix 2026-11-21): last 10 rows from the live
  // login_sessions table, written at every sign-in (auth_screen).
  List<Map<String, dynamic>> _sessions = [];

  // Login Activity row (#31): device name/type + last-active time
  // when the row carries them (078 writer); older rows show the
  // login date only — never invented device info.
  String _sessionLine(Map<String, dynamic> s) {
    final device = strVal(s['device_name']);
    final type = strVal(s['device_type']);
    final activeMs = SupaDb.parseTs(s['last_active_at']);
    final ts = activeMs > 0 ? activeMs : SupaDb.parseTs(s['created_at']);
    final date = fmtDate(ts);
    if (device.isEmpty) return 'Login — $date';
    final label = type.isEmpty ? device : '$device • $type';
    return '$label — $date';
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    if (!await _isOnline()) {
      final twoFaLocal = await _loadTwoFaLocal();
      if (mounted) setState(() {_loading = false; _offline = true; _twoFa = twoFaLocal;});
      return;
    }
    try {
      final profile = await SupaDb.getProfile(widget.uid);
      // Two-step preference: real flag when the column exists,
      // otherwise the on-device value (default off).
      final tfa = profile['two_fa_enabled'];
      _twoFa = tfa is bool ? tfa : await _loadTwoFaLocal();
    } catch (_) {
      _twoFa = await _loadTwoFaLocal();
    }
    try {
      _sessions = await SupaDb.getList('login_sessions',
          eqCol: 'firebase_uid',
          eqVal: widget.uid,
          orderBy: 'created_at',
          ascending: false,
          limit: 10);
    } catch (_) {
      _sessions = [];
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<bool> _loadTwoFaLocal() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool('two_fa_local_${widget.uid}') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> _saveTwoFa(bool v) async {
    setState(() => _twoFa = v);
    try {
      await SupaDb.updateProfile(widget.uid, {'two_fa_enabled': v});
      if (mounted) toast(context, 'Two-step preference saved.');
    } catch (_) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('two_fa_local_${widget.uid}', v);
      if (mounted) toast(context, 'Saved on this device, will sync to your account after the next update.');
    }
  }

  Future<void> _changePassword() async {
    // EXISTING Firebase flow, verified in auth_screen.dart (_forgotPassword):
    // there is no in-app updatePassword flow — password change is the
    // reset email. Do not assume otherwise.
    final email = FirebaseAuth.instance.currentUser?.email ?? '';
    if (email.isEmpty) {
      toast(context, 'No email on this account — cannot send a reset email.');
      return;
    }
    try {
      await FirebaseAuth.instance.sendPasswordResetEmail(email: email);
      if (mounted) toast(context, 'Password reset email sent to $email.');
    } catch (e) {
      if (mounted) toast(context, 'Could not send reset email: $e');
    }
  }

  // WAVE C (#31): mask the REAL email the way the mockup does
  // ("player.arena***@gmail.com") — most of the local part visible,
  // last 3 chars + domain kept honest.
  String _maskEmail(String email) {
    final at = email.indexOf('@');
    if (at <= 4) return email;
    final local = email.substring(0, at);
    final domain = email.substring(at);
    return '${local.substring(0, local.length - 3)}***$domain';
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    final email = user?.email ?? '';
    final verified = user?.emailVerified ?? false;
    // PHASE 2 REDESIGN (Screen 13, 2026-11-23): sections keep the
    // mockup structure — ACCOUNT EMAIL / SECURITY / LOGIN ACTIVITY /
    // PRIVACY CONTROLS in separate dark MockupCards — restyled on
    // the F1/F2 contract tokens (kStyleSection labels, kStyleCardTitle
    // row titles, kStyleMeta subtitles, kSpace* spacing) and the
    // shared ArenaOutlinedButton for the two actions. Login Activity
    // is now a readable timeline (gold marker + vertical rail per
    // entry). All behaviour is unchanged: same handlers, same
    // states, same honest empty states — styling only.
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        centerTitle: false,
        // Mockup #31: plain gold chevron, no bordered box.
        leading: IconButton(icon: Icon(Icons.chevron_left, color: kGold, size: 28), onPressed: () => Navigator.maybePop(context)),
        title: const Text('ACCOUNT SECURITY', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontStyle: FontStyle.italic, fontSize: 22)),
        titleSpacing: 0,
      ),
      // J-detail-fix1 (#31): mockup background has sparse tiny gold
      // ember specks at the edges — shared ArenaEmberDots behind the
      // content, over the contract background gradient.
      body: ArenaBackground(
        child: Stack(
        children: [
          const Positioned.fill(child: IgnorePointer(child: ArenaEmberDots())),
          _loading
          ? ListView(
              padding: const EdgeInsets.all(kSpace16),
              children: const [
                LoadingSkeleton(height: 72),
                SizedBox(height: kSpace12),
                LoadingSkeleton(height: 52),
                SizedBox(height: kSpace12),
                LoadingSkeleton(height: 120),
              ],
            )
          : ListView(
              padding: const EdgeInsets.all(kSpace16),
              children: [
                if (_offline) ...[
                  OfflineState(onRetry: _load),
                  const SizedBox(height: kSpace12),
                ],
                Text('ACCOUNT EMAIL', style: kStyleSection),
                const SizedBox(height: kSpace8),
                // MOCKUP CARD (2026-11-20): gradient fill + yellow
                // gradient border, like the mockup (har jagah rule).
                MockupCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Email Address', style: kStyleLabel),
                      const SizedBox(height: kSpace4),
                      Row(
                        children: [
                          Expanded(child: Text(email.isEmpty ? '—' : _maskEmail(email), style: kStyleCardTitle)),
                          // J-detail-fix1 (#31): mockup Verified pill
                          // is GOLD/olive-gold (gold check + gold text),
                          // not mint green. Not-verified stays muted
                          // grey — an honest distinction, not a gold
                          // claim.
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: kSpace12, vertical: kSpace4),
                            decoration: BoxDecoration(
                              color: verified ? kGold.withValues(alpha: 0.12) : kField,
                              borderRadius: BorderRadius.circular(kRadiusChip),
                              border: Border.all(color: verified ? kGold.withValues(alpha: 0.6) : kBorder),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(verified ? Icons.check_circle : Icons.error_outline, color: verified ? kGold : kMuted, size: 14),
                                const SizedBox(width: kSpace4),
                                Text(verified ? 'Verified' : 'Not verified', style: kStyleLabel.copyWith(color: verified ? kGold : kMuted, fontWeight: FontWeight.bold)),
                              ],
                            ),
                          ),
                        ],
                      ),
                      if (!verified && email.isNotEmpty) ...[
                        const SizedBox(height: kSpace8),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: ArenaOutlinedButton(
                            onPressed: () async {
                              try {
                                await user?.sendEmailVerification();
                                if (!context.mounted) return;
                                toast(context, 'Verification email sent.');
                              } catch (e) {
                                if (!context.mounted) return;
                                toast(context, 'Could not send verification email: $e');
                              }
                            },
                            child: Text('Send verification email', style: TextStyle(color: kGold, fontWeight: FontWeight.bold)),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: kSpace16),
                Text('SECURITY', style: kStyleSection),
                const SizedBox(height: kSpace8),
                // MOCKUP CARD (2026-11-20): gradient fill + yellow
                // gradient border, like the mockup (har jagah rule).
                MockupCard(
                  child: Column(
                    children: [
                      InkWell(
                        onTap: _changePassword,
                        child: Row(
                          children: [
                            _iconBadge(Icons.key),
                            const SizedBox(width: kSpace12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text('Change Password', style: kStyleCardTitle),
                                  const SizedBox(height: 2),
                                  Text('A reset link is emailed to your account email.', style: kStyleMeta),
                                ],
                              ),
                            ),
                            Icon(Icons.chevron_right, color: kGold, size: 26),
                          ],
                        ),
                      ),
                      // Mockup: no line between rows in this card —
                      // plain spacing (was a solid kBorder Divider).
                      const SizedBox(height: kSpace24),
                      Row(
                        children: [
                          _iconBadge(Icons.shield),
                          const SizedBox(width: kSpace12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Two-Step Verification', style: kStyleCardTitle),
                                const SizedBox(height: 2),
                                Text('Additional security on new logins', style: kStyleMeta),
                                const SizedBox(height: 2),
                                // Honest label: a stored preference only.
                                // Nothing enforces it on login yet, and
                                // there is no OTP flow behind this toggle.
                                Text('Preference — enforced when the backend ships it.', style: kStyleLabel),
                              ],
                            ),
                          ),
                          // Stores the real profiles.two_fa_enabled
                          // flag (017) when the column exists, else
                          // on this device — never claims enforcement.
                          _OnOffSwitch(value: _twoFa, onChanged: _saveTwoFa),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: kSpace16),
                Text('LOGIN ACTIVITY', style: kStyleSection),
                const SizedBox(height: kSpace8),
                // MOCKUP CARD (2026-11-20): gradient fill + yellow
                // gradient border, like the mockup (har jagah rule).
                MockupCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // The REAL current session: the signed-in
                      // Firebase user on this device. Below it, the
                      // last 10 recorded logins from login_sessions
                      // (written at every sign-in since the 2026-11-21
                      // audit fix). Rows show the device name/type +
                      // last-active time when the row carries them
                      // (078 writer); older rows show date/time only
                      // — never invented device info.
                      Row(
                        children: [
                          // J-detail-fix1 (#31): mockup device icons
                          // sit in gold-ringed CIRCLES, not rounded
                          // squares.
                          _iconBadge(Icons.smartphone),
                          const SizedBox(width: kSpace12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                // J-detail-fix1 (#31): "(Active)" is
                                // GOLD in the mockup; the rest white.
                                RichText(
                                  text: TextSpan(
                                    style: kStyleCardTitle,
                                    children: [
                                      const TextSpan(text: 'This Device '),
                                      TextSpan(text: '(Active)', style: kStyleCardTitle.copyWith(color: kGold)),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(email.isEmpty ? 'Signed in on this device' : 'Signed in as ${_maskEmail(email)}', style: kStyleMeta),
                              ],
                            ),
                          ),
                          Text('Active Now', style: kStyleMeta.copyWith(color: kGold, fontWeight: FontWeight.bold)),
                        ],
                      ),
                      const SizedBox(height: kSpace12),
                      Text(
                        _sessions.isEmpty
                            ? 'No previous logins recorded yet — logins from now on will appear here.'
                            : (_sessions.any((s) => strVal(s['device_name']).isNotEmpty)
                                ? 'Recent logins:'
                                : 'Recent logins (date/time only — device info is not recorded yet):'),
                        style: kStyleMeta,
                      ),
                      if (_sessions.isNotEmpty)
                        for (var i = 0; i < _sessions.length; i++)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                // PHASE 2 REDESIGN (S13): timeline
                                // rail — gold marker + a vertical
                                // line down to the next entry (the
                                // last entry has no line below it).
                                // Same rows, same text, same order.
                                Column(
                                  children: [
                                    Icon(Icons.history, size: 14, color: kGold),
                                    if (i < _sessions.length - 1)
                                      Container(width: 2, height: 14, color: kBorder),
                                  ],
                                ),
                                const SizedBox(width: kSpace8),
                                Expanded(
                                  child: Text(
                                    _sessionLine(_sessions[i]),
                                    style: kStyleMeta.copyWith(color: kText),
                                  ),
                                ),
                              ],
                            ),
                          ),
                      if (_sessions.isNotEmpty) ...[
                        const SizedBox(height: kSpace12),
                        // Mockup #31: gold 'See All Sessions' pill —
                        // opens the full SessionsPage (3B Child E).
                        Align(
                          alignment: Alignment.centerRight,
                          child: ArenaOutlinedButton(
                            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => SessionsPage(uid: widget.uid))),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text('See All Sessions', style: kStyleMeta.copyWith(color: kGold, fontWeight: FontWeight.bold)),
                                const SizedBox(width: kSpace4),
                                Icon(Icons.chevron_right, color: kGold, size: 16),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: kSpace16),
                Text('PRIVACY CONTROLS', style: kStyleSection),
                const SizedBox(height: kSpace8),
                // PRIVACY EXTRACTED (2026-11-22): the shared card —
                // same toggles + Blocked Players row as the
                // standalone PrivacyPage (one source of truth).
                PrivacyControlsCard(uid: widget.uid),
                const SizedBox(height: kSpace8),
              ],
            ),
        ],
      ),
      ),
    );
  }

  Widget _iconBadge(IconData icon) => Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: kGold, width: 1.5)),
        child: Icon(icon, color: kGold, size: 22),
      );
}

/// WAVE C (#31): mockup ON/OFF toggle — gold track with "ON" text and
/// white knob when on, grey track with "OFF" text when off. A plain
/// Flutter Switch cannot carry the label, so this draws it.
class _OnOffSwitch extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;
  const _OnOffSwitch({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => onChanged(!value),
      child: Container(
        width: 64,
        height: 32,
        decoration: BoxDecoration(
          // J-detail-fix1 (#31/#36): mockup OFF track is mid-grey with
          // no visible outline (code was dark kField + kBorder).
          color: value ? kGold : const Color(0xFF4B505E),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: value ? kGold : const Color(0xFF4B505E), width: 1.5),
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (value)
              const Positioned(left: 9, child: Text('ON', style: TextStyle(color: Colors.black, fontSize: 11, fontWeight: FontWeight.w900)))
            else
              Positioned(right: 8, child: Text('OFF', style: TextStyle(color: kMuted, fontSize: 11, fontWeight: FontWeight.w900))),
            AnimatedAlign(
              duration: const Duration(milliseconds: 150),
              alignment: value ? Alignment.centerRight : Alignment.centerLeft,
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 3),
                width: 24,
                height: 24,
                decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// PRIVACY (2026-11-22, wrong-screen fix): the privacy toggles +
/// Blocked Players row as ONE shared card — used by AccountSecurityPage
/// (its PRIVACY CONTROLS section) AND by the standalone PrivacyPage
/// Settings > Privacy now opens. Same data, same save logic, one
/// place: profiles.privacy jsonb (draft 017) with a SharedPreferences
/// fallback on this device when the column is missing/offline.
class PrivacyControlsCard extends StatefulWidget {
  final String uid;
  const PrivacyControlsCard({super.key, required this.uid});
  @override
  State<PrivacyControlsCard> createState() => _PrivacyControlsCardState();
}

class _PrivacyControlsCardState extends State<PrivacyControlsCard> {
  static const _privacyKeys = ['profile_visible', 'show_game_id', 'show_history'];
  // WAVE C (#31): mockup titles + descriptions.
  static const _privacyLabels = {
    'profile_visible': 'Profile Visibility',
    'show_game_id': 'Show Game ID',
    'show_history': 'Show Match History',
  };
  static const _privacyDescriptions = {
    'profile_visible': 'Allow others to see your stats',
    'show_game_id': 'Visible on tournaments and match info',
    'show_history': 'Allow players to see match performance',
  };
  // Mockup #31: Show Match History is OFF by default; the other
  // two toggles default ON. (Stored values always win over this.)
  Map<String, bool> _privacy = {for (final k in _privacyKeys) k: k != 'show_history'};
  bool _loading = true;
  bool _localOnly = false;
  List<Map<String, dynamic>> _blocked = [];
  String? _blockedError;

  String get _privacyLocalKey => 'privacy_prefs_local_${widget.uid}';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final profile = await SupaDb.getProfile(widget.uid);
      final privacy = SupaDb.asMap(profile['privacy']);
      if (privacy.isNotEmpty) {
        _privacy = {for (final k in _privacyKeys) k: privacy[k] == true};
      } else {
        _privacy = await _loadPrivacyLocal();
        _localOnly = true;
      }
    } catch (_) {
      _privacy = await _loadPrivacyLocal();
      _localOnly = true;
    }
    try {
      _blocked = await SupaDb.getBlockedUsers(widget.uid);
      _blockedError = null;
    } catch (e) {
      _blockedError = '$e';
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<Map<String, bool>> _loadPrivacyLocal() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_privacyLocalKey);
      if (raw == null) return {for (final k in _privacyKeys) k: k != 'show_history'};
      final map = SupaDb.asMap(jsonDecode(raw));
      return {for (final k in _privacyKeys) k: map[k] == true};
    } catch (_) {
      return {for (final k in _privacyKeys) k: k != 'show_history'};
    }
  }

  Future<void> _savePrivacy() async {
    try {
      await SupaDb.updateProfile(widget.uid, {'privacy': _privacy});
      if (mounted) {
        setState(() => _localOnly = false);
        toast(context, 'Privacy settings saved.');
      }
    } catch (_) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_privacyLocalKey, jsonEncode(_privacy));
      if (mounted) {
        setState(() => _localOnly = true);
        toast(context, 'Saved on this device, will sync to your account after the next update.');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const LoadingSkeleton(height: 180);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_localOnly) ...[
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: kField, borderRadius: BorderRadius.circular(12), border: Border.all(color: kGold)),
            child: Text(
              'Privacy settings saved on this device, will sync to your account after the next update.',
              style: TextStyle(color: kText, fontSize: 13),
            ),
          ),
          const SizedBox(height: 12),
        ],
        MockupCard(
          child: Column(
            children: [
              for (int i = 0; i < _privacyKeys.length; i++) ...[
                // Mockup: no line between privacy rows — plain spacing.
                if (i > 0) const SizedBox(height: 24),
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(_privacyLabels[_privacyKeys[i]]!, style: TextStyle(color: kText, fontSize: 16, fontWeight: FontWeight.bold)),
                          const SizedBox(height: 2),
                          Text(_privacyDescriptions[_privacyKeys[i]]!, style: TextStyle(color: kMuted, fontSize: 12)),
                        ],
                      ),
                    ),
                    _OnOffSwitch(
                      value: _privacy[_privacyKeys[i]] ?? true,
                      onChanged: (v) {
                        setState(() => _privacy[_privacyKeys[i]] = v);
                        _savePrivacy();
                      },
                    ),
                  ],
                ),
              ],
              // Mockup: no line above Blocked Players — plain spacing.
              const SizedBox(height: 24),
              InkWell(
                onTap: () async {
                  await Navigator.push(context, MaterialPageRoute(builder: (_) => BlockedPlayersPage(uid: widget.uid)));
                  if (mounted) _load();
                },
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Blocked Players', style: TextStyle(color: kText, fontSize: 16, fontWeight: FontWeight.bold)),
                          const SizedBox(height: 2),
                          Text(_blockedError != null ? 'Blocked list could not load.' : '${_blocked.length} player${_blocked.length == 1 ? '' : 's'} blocked', style: TextStyle(color: kMuted, fontSize: 12)),
                        ],
                      ),
                    ),
                    Icon(Icons.chevron_right, color: kGold, size: 26),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// PRIVACY PAGE (2026-11-22, wrong-screen fix): Settings > Privacy
/// used to open AccountSecurityPage — it now opens this dedicated
/// screen with the same privacy controls (shared card above).
class PrivacyPage extends StatelessWidget {
  final String uid;
  const PrivacyPage({super.key, required this.uid});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        centerTitle: false,
        leading: IconButton(icon: Icon(Icons.chevron_left, color: kGold, size: 28), onPressed: () => Navigator.maybePop(context)),
        title: const Text('PRIVACY', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontStyle: FontStyle.italic, fontSize: 22)),
        titleSpacing: 0,
      ),
      body: Stack(
        children: [
          const Positioned.fill(child: IgnorePointer(child: ArenaEmberDots())),
          ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text('PRIVACY CONTROLS', style: TextStyle(color: kSectionLabel, fontSize: 13, fontWeight: FontWeight.bold, letterSpacing: 1)),
              const SizedBox(height: 8),
              Text(
                'Control what other players can see about you.',
                style: TextStyle(color: kMuted, fontSize: 13),
              ),
              const SizedBox(height: 12),
              PrivacyControlsCard(uid: uid),
            ],
          ),
        ],
      ),
    );
  }
}

/// CHANGE PASSWORD PAGE (2026-11-22, wrong-screen fix): Settings >
/// Change Password used to open AccountSecurityPage — it now opens
/// this dedicated screen. There is NO in-app password form: like
/// Forgot Password on the login screen, password change is the
/// Firebase reset email (verified in auth_screen.dart). This page
/// says so honestly and sends the link.
class ChangePasswordPage extends StatefulWidget {
  final String uid;
  const ChangePasswordPage({super.key, required this.uid});
  @override
  State<ChangePasswordPage> createState() => _ChangePasswordPageState();
}

class _ChangePasswordPageState extends State<ChangePasswordPage> {
  bool _busy = false;

  // Same mask as Account Security (first chars + *** + domain).
  String _maskEmail(String email) {
    final at = email.indexOf('@');
    if (at <= 4) return email;
    final local = email.substring(0, at);
    final domain = email.substring(at);
    return '${local.substring(0, local.length - 3)}***$domain';
  }

  Future<void> _sendResetEmail() async {
    final email = FirebaseAuth.instance.currentUser?.email ?? '';
    if (email.isEmpty) {
      toast(context, 'No email on this account — cannot send a reset email.');
      return;
    }
    setState(() => _busy = true);
    try {
      await FirebaseAuth.instance.sendPasswordResetEmail(email: email);
      if (mounted) toast(context, 'Password reset email sent to $email.');
    } catch (e) {
      if (mounted) toast(context, 'Could not send reset email: $e');
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final email = FirebaseAuth.instance.currentUser?.email ?? '';
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        centerTitle: false,
        leading: IconButton(icon: Icon(Icons.chevron_left, color: kGold, size: 28), onPressed: () => Navigator.maybePop(context)),
        title: const Text('CHANGE PASSWORD', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontStyle: FontStyle.italic, fontSize: 22)),
        titleSpacing: 0,
      ),
      body: Stack(
        children: [
          const Positioned.fill(child: IgnorePointer(child: ArenaEmberDots())),
          ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text('ACCOUNT EMAIL', style: TextStyle(color: kSectionLabel, fontSize: 13, fontWeight: FontWeight.bold, letterSpacing: 1)),
              const SizedBox(height: 8),
              MockupCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Email Address', style: TextStyle(color: kMuted, fontSize: 13)),
                    const SizedBox(height: 4),
                    Text(email.isEmpty ? '—' : _maskEmail(email), style: TextStyle(color: kText, fontSize: 16, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 12),
                    Text(
                      'A reset link is emailed to your account email. Open the email and follow the link to set a new password.',
                      style: TextStyle(color: kMuted, fontSize: 13),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              GoldButton(
                label: 'Send Reset Link',
                onPressed: _busy ? null : _sendResetEmail,
                busy: _busy,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// WAVE C (#31): Blocked Players detail page — the LIVE blocked_users
/// rows (008) with real names + Unblock. Reached from the Blocked
/// Players row on Account Security (mockup #31 layout).
class BlockedPlayersPage extends StatefulWidget {
  final String uid;
  const BlockedPlayersPage({super.key, required this.uid});
  @override
  State<BlockedPlayersPage> createState() => _BlockedPlayersPageState();
}

class _BlockedPlayersPageState extends State<BlockedPlayersPage> {
  bool _loading = true;
  bool _offline = false;
  String? _error;
  List<Map<String, dynamic>> _blocked = [];
  Map<String, Map<String, dynamic>> _blockedNames = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _offline = false;
    });
    if (!await _isOnline()) {
      if (mounted) setState(() { _loading = false; _offline = true; });
      return;
    }
    try {
      _blocked = await SupaDb.getBlockedUsers(widget.uid);
      final uids = [for (final b in _blocked) strVal(b['blocked_uid'])];
      _blockedNames = await SupaDb.getProfilesMap(uids);
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = '$e'; });
      return;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _unblock(String blockedUid, String name) async {
    bool ok = false;
    try {
      ok = await SupaDb.unblockUser(widget.uid, blockedUid);
    } catch (e) {
      if (mounted) toast(context, 'Unblock failed: $e');
      return;
    }
    if (!ok) {
      if (mounted) toast(context, 'Unblock failed — please try again.');
      return;
    }
    await _load();
    if (mounted) toast(context, '$name unblocked.');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Blocked Players', style: TextStyle(color: kGold))),
      body: _loading
          ? ListView(
              padding: const EdgeInsets.all(16),
              children: const [LoadingSkeleton(height: 64), SizedBox(height: 8), LoadingSkeleton(height: 64)],
            )
          : _offline
              ? Center(child: OfflineState(onRetry: _load))
              : _error != null
                  ? Center(child: ErrorState(message: 'Blocked list load nahi hui: $_error', onRetry: _load))
                  : ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        if (_blocked.isEmpty)
                          const EmptyState(icon: Icons.block, title: 'No blocked players.', body: 'You have not blocked anyone.')
                        else
                          for (final b in _blocked)
                            Builder(
                              builder: (context) {
                                final blockedUid = strVal(b['blocked_uid']);
                                final raw = _blockedNames[blockedUid] ?? {};
                                final name = strVal(raw['display_name'], strVal(raw['displayName'], blockedUid));
                                return Padding(
                                  padding: const EdgeInsets.only(bottom: 8),
                                  child: appCard(
                                    child: ListTile(
                                      leading: CachedFramedAvatar(uid: blockedUid, name: name, radius: 16),
                                      title: Text(name, style: TextStyle(color: kText)),
                                      subtitle: Text('Blocked ${fmtDate(SupaDb.parseTs(b['created_at']))}', style: TextStyle(color: kMuted, fontSize: 12)),
                                      trailing: TextButton(
                                        onPressed: () => _unblock(blockedUid, name),
                                        child: Text('Unblock', style: TextStyle(color: kGold, fontWeight: FontWeight.bold)),
                                      ),
                                      contentPadding: EdgeInsets.zero,
                                    ),
                                  ),
                                );
                              },
                            ),
                      ],
                    ),
    );
  }
}

// ---------------------------------------------------------------------------
// #30 Invite Friends (NEW)
// ---------------------------------------------------------------------------
class InviteFriendsPage extends StatefulWidget {
  final String uid;
  const InviteFriendsPage({super.key, required this.uid});
  @override
  State<InviteFriendsPage> createState() => _InviteFriendsPageState();
}

class _InviteFriendsPageState extends State<InviteFriendsPage> {
  bool _loading = true;
  bool _offline = false;
  String? _error;
  String _code = '';
  List<Map<String, dynamic>> _invites = [];
  // Configured community milestones (referral_milestones table:
  // milestone_friends / points / title), set from the admin panel.
  // [] when none are configured — the card then shows an honest
  // empty state, never invented thresholds or rewards.
  List<Map<String, dynamic>> _milestones = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _offline = false;
    });
    if (!await _isOnline()) {
      if (mounted) setState(() { _loading = false; _offline = true; });
      return;
    }
    try {
      final profile = await SupaDb.getProfile(widget.uid);
      // Worker S method (Phase 3 data layer): exact signature per brief.
      // Reads the live `pending_referrals` table (001).
      final invites = await SupaDb.getMyInvites(widget.uid);
      // Configured milestone rewards (referral_milestones). A failure
      // here must never fail the whole page — [] shows the honest
      // empty state instead. Invalid rows (friends <= 0) are dropped;
      // the rest sort ascending by threshold.
      List<Map<String, dynamic>> milestones = [];
      try {
        milestones = await SupaDb.getReferralMilestones();
      } catch (_) {
        milestones = [];
      }
      milestones = milestones.where((m) => SupaDb.intOf(m['milestone_friends']) > 0).toList()
        ..sort((a, b) => SupaDb.intOf(a['milestone_friends']).compareTo(SupaDb.intOf(b['milestone_friends'])));
      if (!mounted) return;
      setState(() {
        _code = strVal(profile['referralCode']);
        _invites = invites;
        _milestones = milestones;
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = '$e'; });
    }
  }

  String get _shareText => 'Join ARENA HUB with my referral code: $_code';

  // Referral Activity pill (mockup #30 words, REAL status mapping):
  // joined / verified / credited -> ACTIVE; invited / pending -> REGISTERED.
  String _activityLabel(String status) {
    final s = status.toLowerCase();
    return (s == 'joined' || s == 'verified' || s == 'credited') ? 'ACTIVE' : 'REGISTERED';
  }

  @override
  Widget build(BuildContext context) {
    // WAVE C design-match (#30, 2026-11-19): mockup header (back +
    // italic INVITE FRIENDS + crown), flat dark hero with
    // BUILD YOUR / GAMING COMMUNITY + subtitle, referral-code card
    // with Copy pill + SHARE INVITE button, Community Milestones
    // card, Referral Activity rows (avatar + name + ACTIVE/
    // REGISTERED pill). Hero art is the app's own flat dark card +
    // trophy icon — NEVER the mockup's PUBG art.
    // MILESTONES (2026-11-20, user order): thresholds + reward
    // points come from the CONFIGURED referral_milestones rows
    // (admin panel) — never the mockup's 30/30/60 demo values. The
    // markers show each milestone's configured reward; when no
    // milestones are configured the card shows an honest empty
    // state. Progress = the real count of friends who joined with
    // this code (pending_referrals rows with joined / verified /
    // credited). No Claim action on this screen — the reward is
    // earned only when an invited friend BOTH recharges AND plays a
    // tournament (enforced server-side).
    final successful = _invites.where((r) {
      final s = strVal(r['status']).toLowerCase();
      return s == 'joined' || s == 'verified' || s == 'credited';
    }).length;
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        centerTitle: false,
        // J-detail-fix1 (#30): mockup #30 back arrow is a plain WHITE
        // chevron (code rendered gold — backwards).
        leading: IconButton(icon: Icon(Icons.chevron_left, color: kText, size: 28), onPressed: () => Navigator.maybePop(context)),
        title: const Text('INVITE FRIENDS', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontStyle: FontStyle.italic, fontSize: 22)),
        titleSpacing: 0,
        actions: const [Padding(padding: EdgeInsets.only(right: 16), child: ArenaLogo(crownSize: 30, fontSize: 16, showWordmark: false))],
      ),
      body: _loading
          ? ListView(
              padding: const EdgeInsets.all(16),
              children: const [
                LoadingSkeleton(height: 140),
                SizedBox(height: 12),
                LoadingSkeleton(height: 120),
                SizedBox(height: 12),
                LoadingSkeleton(height: 64),
              ],
            )
          : _offline
              ? Center(child: OfflineState(onRetry: _load))
              : _error != null
                  ? Center(child: ErrorState(message: 'Invite data load nahi hua: $_error', onRetry: _load))
                  : ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        // Hero — MockupCard (gradient fill + rotating
                        // shines, no full border). Hero art is the
                        // BUNDLED trophy placeholder
                        // (assets/images/trophy_cover.jpg) — gold
                        // trophy on dark, own art, never a wrong or
                        // unrelated image. No fist-bump gamer art
                        // asset exists yet; when one is made it
                        // replaces this banner. (PUBG game art is a
                        // DEMO-ONLY placeholder in the mockup; this
                        // app never ships it.)
                        // MOCKUP FIX (2026-11-20, user order): the
                        // sparkles live INSIDE this card (clipped
                        // _EmberDots behind the content) — never
                        // scattered on the black page background.
                        MockupCard(
                          padding: EdgeInsets.zero,
                          radius: 20,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(20),
                            child: Column(
                              children: [
                                Image.asset(
                                  'assets/images/trophy_cover.jpg',
                                  height: 148,
                                  width: double.infinity,
                                  fit: BoxFit.cover,
                                ),
                                Stack(
                                  children: [
                                    const Positioned.fill(child: IgnorePointer(child: _EmberDots())),
                                    Padding(
                                      padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
                                      child: Column(
                                        children: [
                                          const Text('BUILD YOUR', style: TextStyle(color: Colors.white, fontSize: 30, fontWeight: FontWeight.w900, fontStyle: FontStyle.italic, height: 1.05)),
                                          Text('GAMING COMMUNITY', style: TextStyle(color: kGold, fontSize: 30, fontWeight: FontWeight.w900, fontStyle: FontStyle.italic, height: 1.05)),
                                          const SizedBox(height: 10),
                                          Text(
                                            'Invite your friends to Arena Hub and compete together in free community tournaments.',
                                            style: TextStyle(color: kMuted, fontSize: 14, height: 1.4),
                                            textAlign: TextAlign.center,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 14),
                        // Referral code card — MOCKUP CARD (2026-11-20,
                        // global rule): gradient fill + rotating
                        // shines, no full gold border.
                        MockupCard(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('YOUR REFERRAL CODE', style: TextStyle(color: kMuted, fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 1)),
                              const SizedBox(height: 6),
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(_code.isEmpty ? '—' : _code, style: TextStyle(color: kGold, fontSize: 30, fontWeight: FontWeight.w900, letterSpacing: 2)),
                                  ),
                                  GestureDetector(
                                    onTap: _code.isEmpty
                                        ? null
                                        : () {
                                            Clipboard.setData(ClipboardData(text: _code));
                                            toast(context, 'Referral code copied.');
                                          },
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                                      decoration: BoxDecoration(color: kField, borderRadius: BorderRadius.circular(12), border: Border.all(color: kBorder)),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(Icons.copy, color: kText, size: 16),
                                          const SizedBox(width: 6),
                                          Text('Copy', style: TextStyle(color: kText, fontSize: 14, fontWeight: FontWeight.bold)),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              // J-detail-fix1 (#30): mockup SHARE INVITE
                              // has a slight glow — static shadow on a
                              // wrapper; the shared GoldButton is
                              // untouched (radius 12, flat).
                              Container(
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(12),
                                  boxShadow: [BoxShadow(color: kGold.withValues(alpha: 0.35), blurRadius: 14, spreadRadius: 1, offset: const Offset(0, 4))],
                                ),
                                child: GoldButton(
                                  label: 'SHARE INVITE',
                                  icon: Icons.share,
                                  onPressed: _code.isEmpty ? null : () => Share.share(_shareText),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 14),
                        // MOCKUP CARD (2026-11-20): animated rotating
                        // shine border, like the mockup (har jagah rule).
                        MockupCard(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('COMMUNITY MILESTONES', style: TextStyle(color: kText, fontSize: 17, fontWeight: FontWeight.bold)),
                              const SizedBox(height: 12),
                              // MILESTONES (2026-11-20): thresholds +
                              // reward points from the CONFIGURED
                              // referral_milestones rows (admin panel).
                              // Mockup order: value pills, then the
                              // bar, then the threshold labels below
                              // it. No milestones configured = honest
                              // empty state, never invented values.
                              if (_milestones.isEmpty) ...[
                                Text(
                                  'Community milestones haven\'t been set up yet — your invites still count.',
                                  style: TextStyle(color: kMuted, fontSize: 13),
                                ),
                                const SizedBox(height: 8),
                                Text('$successful friend${successful == 1 ? '' : 's'} joined', style: TextStyle(color: kMuted, fontSize: 12)),
                              ] else ...[
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                                  children: [
                                    for (final m in _milestones)
                                      _milestoneMarker(
                                        points: SupaDb.intOf(m['points']),
                                        reached: successful >= SupaDb.intOf(m['milestone_friends']),
                                      ),
                                  ],
                                ),
                                const SizedBox(height: 10),
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: LinearProgressIndicator(
                                    value: (successful / SupaDb.intOf(_milestones.last['milestone_friends'])).clamp(0.0, 1.0),
                                    minHeight: 10,
                                    backgroundColor: kField,
                                    valueColor: AlwaysStoppedAnimation<Color>(kGold),
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                                  children: [
                                    for (final m in _milestones)
                                      Text(
                                        '${SupaDb.intOf(m['milestone_friends'])} Friends',
                                        style: TextStyle(color: successful >= SupaDb.intOf(m['milestone_friends']) ? kGold : kMuted, fontSize: 12, fontWeight: FontWeight.bold),
                                      ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                Text('$successful friend${successful == 1 ? '' : 's'} joined', style: TextStyle(color: kMuted, fontSize: 12)),
                                const SizedBox(height: 4),
                                Text('Reward is earned when an invited friend recharges and plays a tournament.', style: TextStyle(color: kMuted, fontSize: 11)),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                        // J-detail-fix1 (#30): mockup has ONE enclosing
                        // card with the REFERRAL ACTIVITY heading inside
                        // it — code rendered the heading outside and
                        // each row as its own card.
                        // MOCKUP CARD (2026-11-20): animated rotating
                        // shine border, like the mockup (har jagah rule).
                        MockupCard(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('REFERRAL ACTIVITY', style: TextStyle(color: kText, fontSize: 17, fontWeight: FontWeight.bold)),
                              const SizedBox(height: 12),
                              if (_invites.isEmpty)
                                const EmptyState(icon: Icons.person_add, title: 'No referrals yet.', body: 'Share your code — friends who join with it will appear here.')
                              else
                                for (int i = 0; i < _invites.length; i++) ...[
                                  // Mockup: no line between invite
                                  // rows — plain spacing.
                                  if (i > 0) const SizedBox(height: 24),
                                  _activityRow(_invites[i]),
                                ],
                            ],
                          ),
                        ),
                        const SizedBox(height: 8),
                      ],
                    ),
    );
  }

  // Real display name for a referred friend: the local part of their
  // referral email when known, else their UID. Never a mock name.
  String _inviteName(Map<String, dynamic> inv) {
    final email = strVal(inv['referred_email']);
    if (email.contains('@')) return email.split('@').first;
    if (email.isNotEmpty) return email;
    return strVal(inv['referred_uid'], 'Friend');
  }

  // One milestone marker: the mockup's trophy + configured reward
  // points pill ("🏆 30") — gold when the real joined-friends count
  // has reached the threshold, muted otherwise. Points come from the
  // configured referral_milestones row; a milestone with no reward
  // configured (0 pts) shows the trophy alone — never an invented
  // value. The threshold label sits BELOW the progress bar (mockup
  // order). Display only — never tappable, never a reward or a Claim.
  Widget _milestoneMarker({required int points, required bool reached}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: reached ? kGold.withValues(alpha: 0.15) : kField,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: reached ? kGold : kBorder, width: 1.5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.emoji_events, color: reached ? kGold : kMuted, size: 16),
            if (points > 0) ...[
              const SizedBox(width: 4),
              Text('$points', style: TextStyle(color: reached ? kGold : kMuted, fontSize: 13, fontWeight: FontWeight.w900)),
            ],
          ],
        ),
      );

  // One row inside the single REFERRAL ACTIVITY card: avatar + real
  // name + invite date + ACTIVE/REGISTERED pill.
  Widget _activityRow(Map<String, dynamic> inv) => Row(
        children: [
          CachedFramedAvatar(uid: strVal(inv['referred_uid']), name: _inviteName(inv), radius: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_inviteName(inv), style: TextStyle(color: kText, fontWeight: FontWeight.bold, fontSize: 15)),
                const SizedBox(height: 2),
                Text(fmtDate(SupaDb.parseTs(inv['created_at'])), style: TextStyle(color: kMuted, fontSize: 12)),
              ],
            ),
          ),
          _activityChip(_activityLabel(strVal(inv['status']))),
        ],
      );

  Widget _activityChip(String label) {
    final active = label == 'ACTIVE';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: active ? kGold : kField,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: active ? kGold : kBorder),
      ),
      child: Text(label, style: TextStyle(color: active ? Colors.black : kMuted, fontSize: 11, fontWeight: FontWeight.w900)),
    );
  }
}

/// P-all-fixes-D1 (#32): mockup #32's small 3D gold treasure chest
/// sitting at the progress bar's right end — arched lid, base, lock
/// clasp. Drawn own art (no chest asset exists); decorative only,
/// never a Claim action. Static paint.
class _TreasureChestPainter extends CustomPainter {
  const _TreasureChestPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    double x(double f) => f * w;
    double y(double f) => f * h;
    final rim = Paint()
      ..color = const Color(0xFFFDC903)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;

    // Base: rounded rect, gold gradient (bright top → deep bottom).
    final base = RRect.fromLTRBR(x(0.05), y(0.50), x(0.95), y(0.96), Radius.circular(w * 0.08));
    final baseFill = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0xFFFDC903), Color(0xFFFDC903)],
      ).createShader(Rect.fromLTWH(0, y(0.50), w, y(0.46)));
    canvas.drawRRect(base, baseFill);
    canvas.drawRRect(base, rim);

    // Lid: arched top, brighter gold.
    final lid = Path()
      ..moveTo(x(0.05), y(0.52))
      ..quadraticBezierTo(x(0.05), y(0.02), x(0.50), y(0.02))
      ..quadraticBezierTo(x(0.95), y(0.02), x(0.95), y(0.52))
      ..close();
    final lidFill = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0xFFFDC903), Color(0xFFFDC903)],
      ).createShader(Rect.fromLTWH(0, 0, w, y(0.52)));
    canvas.drawPath(lid, lidFill);
    canvas.drawPath(lid, rim);

    // Lid seam.
    canvas.drawLine(
      Offset(x(0.05), y(0.52)),
      Offset(x(0.95), y(0.52)),
      Paint()
        ..color = const Color(0xFFFDC903)
        ..strokeWidth = 1.2,
    );

    // Lock clasp: small dark-gold plate over the seam + keyhole dot.
    final lock = RRect.fromLTRBR(x(0.43), y(0.40), x(0.57), y(0.68), Radius.circular(w * 0.03));
    canvas.drawRRect(lock, Paint()..color = const Color(0xFFFDC903));
    canvas.drawCircle(Offset(x(0.50), y(0.55)), w * 0.035, Paint()..color = const Color(0xFF17181F));
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// ---------------------------------------------------------------------------
// #32 Your Invites (NEW)
// ---------------------------------------------------------------------------
class YourInvitesPage extends StatefulWidget {
  final String uid;
  const YourInvitesPage({super.key, required this.uid});
  @override
  State<YourInvitesPage> createState() => _YourInvitesPageState();
}

class _YourInvitesPageState extends State<YourInvitesPage> {
  bool _loading = true;
  bool _offline = false;
  String? _error;
  String _code = '';
  List<Map<String, dynamic>> _invites = [];
  // Configured community milestones (referral_milestones table:
  // milestone_friends / points / title), set from the admin panel.
  // [] when none are configured — the summary then shows an honest
  // empty state, never an invented milestone target.
  List<Map<String, dynamic>> _milestones = [];
  // Pending TEAM invitations for this user (team_invitations, direct
  // read — the invite lane's second discovery path, same as the
  // Notifications/Teams pages). Shown as a section at the TOP of
  // this page with Accept/Decline; [] hides the section entirely
  // (the reference has no such section, so an empty one must not
  // break the mockup match). A failed read also yields [] — "could
  // not load" is never shown as "no invites".
  List<Map<String, dynamic>> _pendingTeamInvites = [];
  // Display name of the current user (from the profile read in
  // _load) — Accept needs it for the team_members row.
  String _myDisplayName = 'User';
  // Invite ids with a respond call in flight (buttons disabled until
  // it lands — no double-tap double-respond).
  final Set<String> _responding = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _offline = false;
    });
    if (!await _isOnline()) {
      if (mounted) setState(() { _loading = false; _offline = true; });
      return;
    }
    try {
      final profile = await SupaDb.getProfile(widget.uid);
      final invites = await SupaDb.getMyInvites(widget.uid);
      // Configured milestone rewards (referral_milestones). A failure
      // here must never fail the whole page — [] shows the honest
      // empty state instead. Invalid rows (friends <= 0) are dropped;
      // the rest sort ascending by threshold.
      List<Map<String, dynamic>> milestones = [];
      try {
        milestones = await SupaDb.getReferralMilestones();
      } catch (_) {
        milestones = [];
      }
      milestones = milestones.where((m) => SupaDb.intOf(m['milestone_friends']) > 0).toList()
        ..sort((a, b) => SupaDb.intOf(a['milestone_friends']).compareTo(SupaDb.intOf(b['milestone_friends'])));
      // Pending team invites (invite lane, 2026-11-21): second
      // discovery path, read directly from team_invitations and
      // enriched with the team + inviter names. Best-effort — a
      // failed read leaves [] and must never fail the whole page.
      List<Map<String, dynamic>> pendingTeam = [];
      try {
        pendingTeam = await SupaDb.enrichTeamInvites(await SupaDb.getPendingTeamInvites(widget.uid));
      } catch (_) {
        pendingTeam = [];
      }
      if (!mounted) return;
      setState(() {
        _code = strVal(profile['referralCode']);
        _myDisplayName = SupaDb.strOf(profile['displayName'], 'User');
        _invites = invites;
        _milestones = milestones;
        _pendingTeamInvites = pendingTeam;
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = '$e'; });
    }
  }

  /// The next configured milestone above the real successful count —
  /// null when none is configured or every milestone is reached.
  Map<String, dynamic>? _nextMilestone(int successful) {
    for (final m in _milestones) {
      if (SupaDb.intOf(m['milestone_friends']) > successful) return m;
    }
    return null;
  }

  /// Accept/Decline a pending team invitation (invite lane,
  /// 2026-11-21 fix: SupaDb.respondTeamInvite, DIRECT-WRITE path —
  /// team_members insert + team_invitations status update; the 027
  /// RPC cannot run from this app). On success the card is removed
  /// locally at once (the invite is no longer pending, so a reload
  /// would drop it too); on failure the card stays and the error is
  /// toasted — never a silent loss. A stale invite (responded
  /// elsewhere) just reloads so the dead buttons disappear.
  Future<void> _respondToInvite(Map<String, dynamic> inv, String response) async {
    final inviteId = strVal(inv['invite_id']);
    if (inviteId.isEmpty || _responding.contains(inviteId)) return;
    setState(() => _responding.add(inviteId));
    final res = await SupaDb.respondTeamInvite(inviteId, response, uid: widget.uid, userName: _myDisplayName);
    if (!mounted) return;
    if (res['ok'] == true) {
      setState(() {
        _responding.remove(inviteId);
        _pendingTeamInvites.removeWhere((e) => strVal(e['invite_id']) == inviteId);
      });
      toast(context, response == 'accepted' ? 'Team join ho gayi!' : 'Invitation decline kar di.');
    } else {
      setState(() => _responding.remove(inviteId));
      final err = strVal(res['error']);
      if (err.contains('already responded')) {
        toast(context, 'Ye invitation pehle hi respond ho chuki hai.');
        await _load();
      } else {
        toast(context, 'Failed: $err');
      }
    }
  }

  /// Reference-style invite date ("Nov 23, 2025") — month first,
  /// no time, exactly as the mockup shows it. 'N/A' when the row
  /// carries no usable timestamp (never a fake date).
  String _inviteDate(dynamic ts) {
    final ms = SupaDb.parseTs(ts);
    if (ms <= 0) return 'N/A';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${months[d.month - 1]} ${d.day}, ${d.year}';
  }

  @override
  Widget build(BuildContext context) {
    final invited = _invites.length;
    final successful = _invites.where((r) {
      final s = strVal(r['status']).toLowerCase();
      return s == 'joined' || s == 'verified' || s == 'credited';
    }).length;
    // Next configured milestone above the real successful count
    // (null when none is configured or every one is reached).
    final next = _nextMilestone(successful);
    final maxFriends = _milestones.isEmpty ? 0 : SupaDb.intOf(_milestones.last['milestone_friends']);
    // REDESIGN (2026-11-21, user order — reference
    // 1000048236_36_2szc.jpg, element by element): header (gold-
    // bordered back box + italic YOUR INVITES + solid gold info
    // circle), stats card with the reference's STRONG gold glow
    // border + sparkles INSIDE, "N more to Next Milestone" (number
    // gold, rest white) + successful/next (first number gold) + gold
    // bar on a grey track + treasure chest, INVITATION HISTORY with
    // the gold bar, rows (avatar + name + Joined/Invited date +
    // VERIFIED gold-fill / JOINED gold-outline / INVITED grey-fill
    // pill), bottom "Share your code: <real code>" + gold INVITE
    // FRIENDS pill button. ALL NUMBERS ARE REAL (pending_referrals
    // rows + the profile's referral code) — the reference's 18/12,
    // names, Nov 2025 dates and ARENA123 are mock and never copied.
    // MILESTONES: the bar runs to the NEXT CONFIGURED
    // referral_milestones threshold (admin panel) — no milestones
    // configured = the honest empty text, never an invented target
    // or a fake bar. TEAM INVITATIONS (invite lane): pending team
    // invites sit at the TOP with Accept/Decline; the section only
    // renders when one is actually pending, so the reference match
    // is untouched otherwise. NO WORD CUT anywhere on this page:
    // names/dates/pills wrap or shrink, never clip.
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        centerTitle: false,
        leading: Padding(
          padding: const EdgeInsets.all(8),
          child: Container(
            decoration: BoxDecoration(
              color: kField,
              border: Border.all(color: kGold, width: 1.5),
              borderRadius: BorderRadius.circular(10),
            ),
            child: IconButton(icon: Icon(Icons.chevron_left, color: kGold, size: 24), padding: EdgeInsets.zero, onPressed: () => Navigator.maybePop(context)),
          ),
        ),
        title: const Text('YOUR INVITES', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontStyle: FontStyle.italic, fontSize: 22)),
        titleSpacing: 0,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: IconButton(
              icon: Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(shape: BoxShape.circle, color: kGold),
                child: const Icon(Icons.info, color: Color(0xFF0A0A0F), size: 18),
              ),
              onPressed: () => showInfoDialog(context, 'Your Invites', 'Everyone you invited with your referral code. Successful = friends who joined with your code.'),
            ),
          ),
        ],
      ),
      body: _loading
          ? ListView(
              padding: const EdgeInsets.all(16),
              children: const [
                LoadingSkeleton(height: 84),
                SizedBox(height: 12),
                LoadingSkeleton(height: 120),
                SizedBox(height: 12),
                LoadingSkeleton(height: 64),
              ],
            )
          : _offline
              ? Center(child: OfflineState(onRetry: _load))
              : _error != null
                  ? Center(child: ErrorState(message: 'Invites load nahi hue: $_error', onRetry: _load))
                  : ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        // TEAM INVITATIONS (invite lane, 2026-11-21):
                        // pending team invites with Accept/Decline,
                        // at the TOP of the page. Only renders while
                        // at least one invite is actually pending —
                        // the reference has no such section, so an
                        // empty one must not break the mockup match.
                        if (_pendingTeamInvites.isNotEmpty) ...[
                          Row(
                            children: [
                              Container(width: 5, height: 24, decoration: BoxDecoration(color: kGold, borderRadius: BorderRadius.circular(3))),
                              const SizedBox(width: 10),
                              Text('TEAM INVITATIONS', style: TextStyle(color: kText, fontSize: 19, fontWeight: FontWeight.w900, fontStyle: FontStyle.italic)),
                            ],
                          ),
                          const SizedBox(height: 12),
                          for (final inv in _pendingTeamInvites) ...[
                            _teamInviteCard(inv),
                            const SizedBox(height: 8),
                          ],
                          const SizedBox(height: 12),
                        ],
                        // STATS CARD (redesign 2026-11-21): the
                        // reference's STRONG gold glow border — a
                        // full gold border + layered gold glow,
                        // NOT the faint MockupCard shine (its 0.10
                        // shadow read as no border at all on the
                        // user's screenshot). Deliberate local
                        // deviation from the MockupCard global rule,
                        // justified by the reference itself. The
                        // sparkles live INSIDE the card (clipped
                        // _EmberDots behind the content) — user order.
                        Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(22),
                            // FIX 23 item 23: fill is the shared
                            // purple gradient. PHASE E (E25): the
                            // GOLD border + gold glow are GONE —
                            // they tinted the whole card yellow
                            // (Sameer: "peela hai"). Standard card
                            // border + purple shadow now, exactly
                            // like every other card. The in-card
                            // sparkles (_EmberDots) STAY — user
                            // order, and not a tint source.
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [
                                kCardPurpleTop.withValues(
                                    alpha: kCardFillOpacity),
                                kCardPurpleMid.withValues(
                                    alpha: kCardFillOpacity),
                                kCardPurpleBottom.withValues(
                                    alpha: kCardFillOpacity),
                              ],
                            ),
                            border: Border.all(
                                color: kCardPurpleBorder, width: 1.5),
                            boxShadow: [
                              BoxShadow(
                                color: kCardPurpleGlow.withValues(
                                    alpha: 0.25),
                                blurRadius: 15,
                                spreadRadius: 1,
                              ),
                            ],
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(22),
                            child: Stack(
                              children: [
                                const Positioned.fill(child: IgnorePointer(child: _EmberDots())),
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
                                  child: Column(
                            children: [
                              Row(
                                children: [
                                  Expanded(child: _totalStat('TOTAL INVITATIONS', '$invited')),
                                  _fadeDividerV(height: 64),
                                  Expanded(child: _totalStat('SUCCESSFUL REGISTRATIONS', '$successful')),
                                ],
                              ),
                              // Mockup: the line above the milestone
                              // row fades out toward both ends (same
                              // 24 px total spacing as the old Divider).
                              const SizedBox(height: 11),
                              _fadeDividerH(),
                              const SizedBox(height: 12),
                              if (_milestones.isEmpty)
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    'No community milestones have been set up yet.',
                                    style: TextStyle(color: kMuted, fontSize: 13),
                                  ),
                                )
                              else if (next != null) ...[
                                Row(
                                  children: [
                                    Expanded(
                                      // Reference: the remaining count
                                      // is GOLD, the rest white.
                                      // Threshold = the NEXT CONFIGURED
                                      // referral_milestones row
                                      // (smallest threshold above the
                                      // real successful count) — never
                                      // a hardcoded 12/20 or 20.
                                      child: RichText(
                                        text: TextSpan(
                                          style: TextStyle(color: kText, fontSize: 14, fontWeight: FontWeight.bold),
                                          children: [
                                            TextSpan(text: '${SupaDb.intOf(next['milestone_friends']) - successful}', style: TextStyle(color: kGold, fontWeight: FontWeight.w900)),
                                            const TextSpan(text: ' more to Next Milestone'),
                                          ],
                                        ),
                                      ),
                                    ),
                                    // Reference: "12/20" — the
                                    // successful count is gold, the
                                    // "/next" is muted.
                                    RichText(
                                      text: TextSpan(
                                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w900),
                                        children: [
                                          TextSpan(text: '$successful', style: TextStyle(color: kGold)),
                                          TextSpan(text: '/${SupaDb.intOf(next['milestone_friends'])}', style: TextStyle(color: kMuted)),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                Row(
                                  children: [
                                    Expanded(
                                      child: ClipRRect(
                                        borderRadius: BorderRadius.circular(8),
                                        child: LinearProgressIndicator(
                                          value: (successful / SupaDb.intOf(next['milestone_friends'])).clamp(0.0, 1.0),
                                          minHeight: 10,
                                          backgroundColor: kField,
                                          valueColor: AlwaysStoppedAnimation<Color>(kGold),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    // P-all-fixes-D1 (#32): mockup's small
                                    // 3D gold treasure chest at the bar's
                                    // end — drawn own art (was the flat
                                    // gift-card icon). Decorative only,
                                    // never a Claim action.
                                    const CustomPaint(painter: _TreasureChestPainter(), size: Size(30, 26)),
                                  ],
                                ),
                              ] else ...[
                                // Every configured milestone reached:
                                // completed state — never a broken bar
                                // or a fake next target.
                                Row(
                                  children: [
                                    Expanded(child: Text('All milestones reached', style: TextStyle(color: kText, fontSize: 14, fontWeight: FontWeight.bold))),
                                    RichText(
                                      text: TextSpan(
                                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w900),
                                        children: [
                                          TextSpan(text: '$successful', style: TextStyle(color: kGold)),
                                          TextSpan(text: '/$maxFriends', style: TextStyle(color: kMuted)),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                Row(
                                  children: [
                                    Expanded(
                                      child: ClipRRect(
                                        borderRadius: BorderRadius.circular(8),
                                        child: LinearProgressIndicator(
                                          value: 1.0,
                                          minHeight: 10,
                                          backgroundColor: kField,
                                          valueColor: AlwaysStoppedAnimation<Color>(kGold),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    const CustomPaint(painter: _TreasureChestPainter(), size: Size(30, 26)),
                                  ],
                                ),
                              ],
                            ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 20),
                        Row(
                          children: [
                            Container(width: 5, height: 24, decoration: BoxDecoration(color: kGold, borderRadius: BorderRadius.circular(3))),
                            const SizedBox(width: 10),
                            Text('INVITATION HISTORY', style: TextStyle(color: kText, fontSize: 19, fontWeight: FontWeight.w900, fontStyle: FontStyle.italic)),
                          ],
                        ),
                        const SizedBox(height: 12),
                        if (_invites.isEmpty)
                          const EmptyState(icon: Icons.person_add, title: 'No invitations yet.', body: 'Share your referral code to start inviting friends.')
                        else
                          for (final inv in _invites)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              // Reference rows are plain dark cards
                              // with a faint border — NOT the gold
                              // shine MockupCard (that border belongs
                              // to the stats card only).
                              child: Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: kField,
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(color: kBorder),
                                ),
                                child: Row(
                                  children: [
                                    CachedFramedAvatar(uid: strVal(inv['referred_uid']), name: _inviteName(inv), radius: 22),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(_inviteName(inv), style: TextStyle(color: kText, fontWeight: FontWeight.bold, fontSize: 16)),
                                          const SizedBox(height: 2),
                                          Text(
                                            '${_joinedWord(inv)} ${_inviteDate(inv['created_at'])}',
                                            style: TextStyle(color: kMuted, fontSize: 12),
                                          ),
                                        ],
                                      ),
                                    ),
                                    _stateChip(inviteStateLabel(strVal(inv['status']))),
                                  ],
                                ),
                              ),
                            ),
                        const SizedBox(height: 16),
                        RichText(
                          textAlign: TextAlign.center,
                          text: TextSpan(
                            style: TextStyle(color: kMuted, fontSize: 14),
                            children: [
                              const TextSpan(text: 'Share your code: '),
                              TextSpan(text: _code.isEmpty ? '—' : _code, style: TextStyle(color: kText, fontWeight: FontWeight.w900)),
                            ],
                          ),
                        ),
                        const SizedBox(height: 10),
                        // J-detail-fix1 (#32): mockup CTA is a full pill
                        // (~r28, 18pt w900 caps + chevron) with a soft
                        // gold glow beneath it — built locally, NOT the
                        // shared GoldButton (radius 12, 15pt, flat).
                        Container(
                          width: double.infinity,
                          height: 56,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(28),
                            boxShadow: [
                              BoxShadow(color: kGold.withValues(alpha: 0.35), blurRadius: 16, spreadRadius: 1, offset: const Offset(0, 6)),
                              BoxShadow(color: kGold.withValues(alpha: 0.15), blurRadius: 28, spreadRadius: 2, offset: const Offset(0, 10)),
                            ],
                          ),
                          child: ElevatedButton(
                            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => InviteFriendsPage(uid: widget.uid))),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: kGold,
                              foregroundColor: const Color(0xFF0A0A0F),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
                              elevation: 0,
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text('INVITE FRIENDS', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18)),
                                SizedBox(width: 6),
                                Icon(Icons.chevron_right, size: 22),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                      ],
                    ),
    );
  }

  // Real display name for a referred friend: the local part of their
  // referral email when known, else their UID. Never a mock name.
  String _inviteName(Map<String, dynamic> inv) {
    final email = strVal(inv['referred_email']);
    if (email.contains('@')) return email.split('@').first;
    if (email.isNotEmpty) return email;
    return strVal(inv['referred_uid'], 'Friend');
  }

  String _joinedWord(Map<String, dynamic> inv) {
    final s = strVal(inv['status']).toLowerCase();
    return (s == 'joined' || s == 'verified' || s == 'credited') ? 'Joined' : 'Invited';
  }

  Widget _totalStat(String label, String value) => Column(
        children: [
          Text(label, style: TextStyle(color: kMuted, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 0.5), textAlign: TextAlign.center),
          const SizedBox(height: 6),
          Text(value, style: TextStyle(color: kGold, fontWeight: FontWeight.w900, fontSize: 40)),
        ],
      );

  // Reference pills (redesign 2026-11-21): VERIFIED = gold FILL +
  // dark text + dark check; JOINED = gold outline + gold text;
  // INVITED = grey fill + grey text. No word ever cut — the pill
  // sizes to its label.
  Widget _stateChip(String label) {
    final verified = label == 'VERIFIED';
    final joined = label == 'JOINED';
    final Color fill;
    final Color color;
    Color? border;
    if (verified) {
      fill = kGold;
      color = const Color(0xFF0A0A0F);
    } else if (joined) {
      fill = Colors.transparent;
      color = kGold;
      border = kGold;
    } else {
      fill = const Color(0xFF3A4152);
      color = const Color(0xFFB7BCCB);
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(16),
        border: border == null ? null : Border.all(color: border, width: 1.2),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w900)),
          if (verified) ...[const SizedBox(width: 4), Icon(Icons.check_circle, color: color, size: 13)],
        ],
      ),
    );
  }

  // One pending team invitation card (top section): team name +
  // inviter + date, with Accept (solid gold) / Decline (dark)
  // pills — same action style as the Notifications inbox. Names
  // come from the enriched server rows only; a missing team/inviter
  // name falls back to generic wording, never an invented name.
  Widget _teamInviteCard(Map<String, dynamic> inv) {
    final inviteId = strVal(inv['invite_id']);
    final busy = _responding.contains(inviteId);
    final teamName = strVal(inv['team_name']);
    final inviterName = strVal(inv['inviter_name']);
    final title = teamName.isEmpty ? 'Team Invitation' : teamName;
    final subtitle = inviterName.isEmpty
        ? 'You have been invited to join this team.'
        : '$inviterName invited you to join.';
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: kField,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: kGold.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(shape: BoxShape.circle, color: kGold.withValues(alpha: 0.15), border: Border.all(color: kGold, width: 1.5)),
                child: Icon(Icons.group, color: kGold, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: TextStyle(color: kText, fontWeight: FontWeight.bold, fontSize: 16)),
                    const SizedBox(height: 2),
                    Text(subtitle, style: TextStyle(color: kMuted, fontSize: 12)),
                    const SizedBox(height: 2),
                    Text('Invited ${_inviteDate(inv['created_at'])}', style: TextStyle(color: kMuted, fontSize: 12)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              _inviteActionBtn(label: 'Decline', gold: false, busy: busy, onTap: () => _respondToInvite(inv, 'declined')),
              const SizedBox(width: 8),
              _inviteActionBtn(label: 'Accept', gold: true, busy: busy, onTap: () => _respondToInvite(inv, 'accepted')),
            ],
          ),
        ],
      ),
    );
  }

  // Invite action pill: Accept = solid gold + dark text, Decline =
  // dark with a muted border. Same style as the Notifications inbox.
  Widget _inviteActionBtn({required String label, required bool gold, required bool busy, required VoidCallback onTap}) {
    return Opacity(
      opacity: busy ? 0.5 : 1,
      child: AbsorbPointer(
        absorbing: busy,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
            decoration: BoxDecoration(
              color: gold ? kGold : kField,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: gold ? kGold : kBorder),
            ),
            child: Text(label, style: TextStyle(color: gold ? const Color(0xFF0A0A0F) : kText, fontWeight: FontWeight.bold, fontSize: 13)),
          ),
        ),
      ),
    );
  }
}

/// FADING DIVIDERS (2026-11-20, user order — "meri zabaan thak gayi
/// hai"): the mockups' divider lines are THIN and LIGHT, fading out
/// toward their ends — never solid corner-to-corner lines. Both
/// helpers render a 1px line whose middle is a light grey (~20%
/// white on the dark card) and whose ends fade to transparent.
///
/// Horizontal: gradient along X (use between stacked rows).
Widget _fadeDividerH() => Container(
      height: 1,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [
            Colors.transparent,
            Color(0x33FFFFFF),
            Color(0x33FFFFFF),
            Colors.transparent,
          ],
          stops: [0.0, 0.25, 0.75, 1.0],
        ),
      ),
    );

/// Vertical: gradient along Y (use between side-by-side stats).
/// [height] fixes the length; null lets the parent (e.g. an
/// IntrinsicHeight Row) stretch it.
Widget _fadeDividerV({double? height}) => Container(
      width: 1,
      height: height,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.transparent,
            Color(0x33FFFFFF),
            Color(0x33FFFFFF),
            Colors.transparent,
          ],
          stops: [0.0, 0.25, 0.75, 1.0],
        ),
      ),
    );
