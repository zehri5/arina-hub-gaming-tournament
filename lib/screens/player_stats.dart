import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../components/arena_components.dart';
import '../components/cached_image.dart';
import '../services/supabase_db.dart';
import '../theme.dart';
import 'more_screens.dart'; // SettingsPage for the header gear — circular
// import with more_screens.dart (which imports this file) is legal in
// Dart; same precedent as rewards_screens.dart <-> more_screens.dart.
import '../main.dart'; // ArenaBottomNav + homeTabRequest (bottom-nav
    // round 2026-11-22, #25). Circular with main.dart (which imports
    // more_screens.dart, which imports this file) — legal in Dart, no
    // import-time initialisers involved.

/// Player Stats screen (§6.1 #25) — Phase 2 data, Wave 4b design-match,
/// fix round 1 (2026-11-20): rebuilt same-to-same against mockup
/// `ai-studio-batches/batch6/26_player_stats.jpg`.
/// MISC card pass (2026-11-20): all cards switched from appCard
/// (flat full border) to MockupCard (global 2-shine style, user
/// order "har jagah"); layout, data and paddings unchanged.
/// PLAYER STATS REDO (2026-11-20, user: "bahut wahiyaat banaya hua
/// hai"): rebuilt pixel-measured against mockup #25
/// (633354963_1795037712725428.jpg, 768×1376 — text/cards measured
/// from the image at ~0.5 dp/px): centred overview tiles, 168dp
/// overview block (was 236, and the GridView left a ~25dp gap under
/// the tiles on 360dp screens), vertical dashed chart gridlines,
/// inset game-stat dividers, compact match cards with the placement
/// pill on the date row (right) and a short "Nov 23, 8:00 PM" date,
/// header sizes re-measured (avatar 76, name 24, tier 21), and the
/// achievements back to the mockup's round winged medallions
/// (badge_*.png, cropped from this mockup). Data wiring untouched —
/// presentation only.
///
/// Layout follows the mockup (player header with Lv pill + rank tier +
/// team, OVERVIEW STATISTICS 2×2 + 7-day PERFORMANCE chart,
/// GAME-SPECIFIC STATS row, RECENT MATCHES cards + View All,
/// ACHIEVEMENTS icon row) using ONLY live data:
/// match_history rows (via SupaDb.getMatchHistory — played_at, kills,
/// rank, earnings) + live profiles columns (via SupaDb.getProfile —
/// display_name, photo_url, level) + Community Points ledger
/// (via SupaDb.getPointsTotal — SUM(delta), the real TOTAL POINTS) +
/// team_name from the player's latest registration.
///
/// Real-data derivations (documented, never invented values):
/// - TOTAL POINTS = SUM(community_points_ledger.delta) — the same
///   total the Rewards hub shows. 0 until the first ledger rows land.
/// - Per-match "+N Pts" = the server's own 022 record_match_result
///   formula: placement points (#1:15 #2:12 #3:10 #4:8 #5:6 #6:4
///   #7:2 #8:2 else 0) + kills. Same numbers the server credits.
/// - K/D ratio: match_history has NO deaths column. Battle-royale
///   derivation — you die once per match you don't win, so deaths =
///   matches played − matches won (rank #1 = survived). K/D =
///   kills / deaths (0.00 with no matches; kills when undefeated).
/// - Rank tier (CONQUEROR / DIAMOND / PLATINUM / GOLD / SILVER /
///   BRONZE) is a presentation label derived from the REAL
///   profiles.level (migration 017, same source Profile/Home use):
///   Lv 50+ CONQUEROR, 40+ DIAMOND, 30+ PLATINUM, 20+ GOLD,
///   10+ SILVER, else BRONZE. There is no tier column in the DB;
///   the tier name is only a label for the real level.
/// - Team name = team_name of the player's latest registration.
///   No registration yet → the team line is omitted (never invented).
/// - AVG. DAMAGE / HEADSHOTS read the real match_history.damage /
///   headshot columns (077, applied 2026-11-21 — verified live:
///   both columns exist, 0 on rows the 022 RPC never wrote). The
///   read degrades honestly: a row without the columns sums as 0
///   (SupaDb.intOf default). The WRITE side is still blocked on
///   the 022 record_match_result RPC + JWT bridge — until that
///   lands every row stays 0, which is real (no damage was ever
///   recorded), not a display bug.
/// - NO game-art thumbnails on match cards (never copy PUBG/BGMI art)
///   — gold trophy tile instead, unless the tournament has a real
///   banner_url (then the banner photo, disk-cached). NO avatar photo
///   from the mockup — the real profile photo_url, or a gold-ring
///   person icon.
/// - The 7-day chart plots ONLY real played_at/kills buckets; with
///   no matches in the last 7 days it shows the honest empty state.
/// - Achievements use the SAME real-counts rule as ProfilePage
///   (more_screens.dart): First Win (wins ≥ 1), 10 Matches
///   (matches ≥ 10), Champion (wins ≥ 5), Veteran (matches ≥ 50),
///   Top Earner (profile total_earnings ≥ Rs 1000). The BADGE ART is
///   the mockup's own round winged gold medallions —
///   assets/images/badge_*.png, cropped from mockup #25 itself
///   (the user's own designs, authorized 2026-11-20) — closest-art
///   mapping only (First Win / Top Earner → MVP trophy, 10 Matches
///   → Slayer swords, Champion → Survivor, Veteran → Deadshot);
///   labels stay the REAL earned achievements, never the mockup's
///   sample names. (The shield-crest PremiumAchievementBadge from
///   the P-all-fixes round was the wrong shape vs the mockup's round
///   medallions — swapped back in the 2026-11-20 redo.)
/// - Match dates render short like the mockup ("Nov 23, 8:00 PM",
///   no year, month first) via the local _shortDate — fmtDate in
///   utils.dart includes the year and is shared, so this screen
///   formats its own short date here.
/// - Team name: team_name of the player's latest registration.
///   A stored team name shorter than 4 chars is treated as a stray
///   fragment and hidden (production evidence 2026-11-20: the user's
///   only registration carries team_name 'jii'). No registration
///   yet → the team line is omitted (never invented).
///   tournament_registrations.created_at is live (068, applied
///   2026-11-21) and the "latest" pick below orders by newest
///   created_at (backfilled from joined_at at apply time).
/// - Header has a working share action (shares the real stats as
///   text via share_plus) and a settings gear → SettingsPage — both
///   live in the AppBar (mockup top-right), so the Lv pill + tier
///   name row has room and the tier name never truncates.
class PlayerStatsPage extends StatelessWidget {
  final String uid;
  const PlayerStatsPage({super.key, required this.uid});

  @override
  Widget build(BuildContext context) {
    // Scaffold + AppBar live in _PlayerStatsBodyState so the AppBar
    // share action can use the loaded stats (mockup: share + gear
    // top-right next to the title).
    return _PlayerStatsBody(uid: uid);
  }
}

class _DayBucket {
  final DateTime day;
  final int matches;
  final int kills;
  const _DayBucket({required this.day, required this.matches, required this.kills});
}

/// Team-name fragment rule (see _StatsData header): a stored team
/// name shorter than 4 characters is a stray fragment, not a team
/// ("jii" on the user's own registration) — hidden, never shown.
/// Public so the regression test can cover it.
String cleanTeamName(String t) => t.length < 4 ? '' : t;

/// Thousands separator without pulling in package:intl
/// ("18,450" like the mockup). Handles a negative sign.
String _commas(int v) {
  final neg = v < 0;
  final s = v.abs().toString();
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
    buf.write(s[i]);
  }
  return neg ? '-${buf.toString()}' : buf.toString();
}

/// Short match date like the mockup ("Nov 23, 8:00 PM") — no year,
/// month first. fmtDate (utils.dart) includes the year and is
/// shared, so this screen formats its own short date here.
String _shortDate(int ms) {
  if (ms <= 0) return 'N/A';
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  final hour = d.hour % 12 == 0 ? 12 : d.hour % 12;
  return '${months[d.month - 1]} ${d.day}, $hour:${d.minute.toString().padLeft(2, '0')} ${d.hour >= 12 ? 'PM' : 'AM'}';
}

/// Per-match Community Points — the server's own 022
/// record_match_result formula (placement points + 1 per kill).
/// Same numbers the server credits; computed here only because
/// match_history stores rank + kills, not the credited points.
int _matchPoints(Map<String, dynamic> m) {
  const placement = {1: 15, 2: 12, 3: 10, 4: 8, 5: 6, 6: 4, 7: 2, 8: 2};
  return (placement[SupaDb.intOf(m['rank'])] ?? 0) + SupaDb.intOf(m['kills']);
}

class _StatsData {
  final String name;
  final String photoUrl;
  final int level;
  final int totalPoints;
  final String teamName;
  final Map<String, String> modes;
  final Map<String, String> banners;
  final int matches;
  final int wins;
  final int kills;
  final int totalDamage;
  final int totalHeadshots;
  final double totalEarnings;
  final List<Map<String, dynamic>> recent;
  final List<_DayBucket> week;
  final List<String> achievements;

  const _StatsData({
    required this.name,
    required this.photoUrl,
    required this.level,
    required this.totalPoints,
    required this.teamName,
    required this.modes,
    required this.banners,
    required this.matches,
    required this.wins,
    required this.kills,
    required this.totalDamage,
    required this.totalHeadshots,
    required this.totalEarnings,
    required this.recent,
    required this.week,
    required this.achievements,
  });

  factory _StatsData.empty() => _StatsData(
        name: 'Player',
        photoUrl: '',
        level: 1,
        totalPoints: 0,
        teamName: '',
        modes: const {},
        banners: const {},
        matches: 0,
        wins: 0,
        kills: 0,
        totalDamage: 0,
        totalHeadshots: 0,
        totalEarnings: 0,
        recent: const [],
        week: List<_DayBucket>.generate(7, (i) {
          final now = DateTime.now();
          final today = DateTime(now.year, now.month, now.day);
          return _DayBucket(day: today.subtract(Duration(days: 6 - i)), matches: 0, kills: 0);
        }),
        achievements: const [],
      );

  factory _StatsData.from(
    Map<String, dynamic> profile,
    List<Map<String, dynamic>> history, {
    required int totalPoints,
    required String teamName,
    required Map<String, String> modes,
    required Map<String, String> banners,
  }) {
    final matches = history.length;
    final wins = history.where((h) => SupaDb.intOf(h['rank']) == 1).length;
    final kills = history.fold<int>(0, (s, h) => s + SupaDb.intOf(h['kills']));
    final totalDamage = history.fold<int>(0, (s, h) => s + SupaDb.intOf(h['damage']));
    final totalHeadshots = history.fold<int>(0, (s, h) => s + SupaDb.intOf(h['headshot']));
    final totalEarnings = history.fold<double>(0, (s, h) => s + SupaDb.numOf(h['earnings']));
    // 7-day buckets from match_history played_at (normalised to
    // 'timestamp' ms by normMatchHistory). Real rows only.
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final week = List<_DayBucket>.generate(7, (i) {
      final day = today.subtract(Duration(days: 6 - i));
      final dayRows = history.where((h) {
        final ts = SupaDb.intOf(h['timestamp']);
        if (ts <= 0) return false;
        final d = DateTime.fromMillisecondsSinceEpoch(ts);
        return d.year == day.year && d.month == day.month && d.day == day.day;
      }).toList();
      return _DayBucket(
        day: day,
        matches: dayRows.length,
        kills: dayRows.fold<int>(0, (s, h) => s + SupaDb.intOf(h['kills'])),
      );
    });
    // Same thresholds as ProfilePage — real counts only.
    final achievements = <String>[];
    if (wins >= 1) achievements.add('First Win');
    if (matches >= 10) achievements.add('10 Matches');
    if (wins >= 5) achievements.add('Champion');
    if (matches >= 50) achievements.add('Veteran');
    if (SupaDb.numOf(profile['totalEarnings']) >= 1000) achievements.add('Top Earner');
    return _StatsData(
      name: SupaDb.strOf(profile['displayName'], 'Player'),
      photoUrl: SupaDb.strOf(profile['photoURL']),
      // REAL profiles.level (migration 017 — same source Home/Profile use).
      level: SupaDb.intOf(profile['level'], 1),
      totalPoints: totalPoints,
      teamName: teamName,
      modes: modes,
      banners: banners,
      matches: matches,
      wins: wins,
      kills: kills,
      totalDamage: totalDamage,
      totalHeadshots: totalHeadshots,
      totalEarnings: totalEarnings,
      // getMatchHistory already orders newest first (played_at desc).
      recent: history,
      week: week,
      achievements: achievements,
    );
  }

  double get winRate => matches > 0 ? wins / matches * 100 : 0;

  /// K/D ratio. match_history has NO deaths column — battle-royale
  /// derivation: you die once per match you don't win, so
  /// deaths = matches − wins (rank #1 = survived). 0.00 with no
  /// matches; kills when undefeated (no deaths to divide by).
  double get kdRatio {
    if (matches == 0) return 0;
    final deaths = matches - wins;
    if (deaths <= 0) return kills.toDouble();
    return kills / deaths;
  }

  /// Rank-tier label derived from the REAL profiles.level (see file
  /// header). Lv 50+ CONQUEROR, 40+ DIAMOND, 30+ PLATINUM,
  /// 20+ GOLD, 10+ SILVER, else BRONZE.
  String get rankTier {
    if (level >= 50) return 'CONQUEROR';
    if (level >= 40) return 'DIAMOND';
    if (level >= 30) return 'PLATINUM';
    if (level >= 20) return 'GOLD';
    if (level >= 10) return 'SILVER';
    return 'BRONZE';
  }

  IconData get rankTierIcon {
    if (level >= 50) return Icons.emoji_events;
    if (level >= 40) return Icons.diamond;
    if (level >= 30) return Icons.workspace_premium;
    if (level >= 20) return Icons.military_tech;
    return Icons.shield;
  }

  double get avgDamage => matches > 0 ? totalDamage / matches : 0;
  double get hsPct => kills > 0 ? totalHeadshots / kills * 100 : 0;
  // Real top-10 finishes only (rank 1–10).
  int get topPlacements => recent.where((h) {
        final r = SupaDb.intOf(h['rank']);
        return r >= 1 && r <= 10;
      }).length;
}

/// Gold line chart of real kills-per-day (last 7 days), with a
/// gradient fill under the line — the mockup's PERFORMANCE chart.
/// Draws nothing when every value is 0 (caller shows the empty state).
class _KillsLinePainter extends CustomPainter {
  final List<int> kills;
  final Color lineColor;
  const _KillsLinePainter({required this.kills, required this.lineColor});

  @override
  void paint(Canvas canvas, Size size) {
    final maxV = kills.fold<int>(0, (m, v) => v > m ? v : m);
    if (maxV <= 0 || kills.length < 2) return;
    const padX = 8.0;
    const padTop = 12.0;
    const padBottom = 8.0;
    final w = size.width - padX * 2;
    final h = size.height - padTop - padBottom;
    Offset pt(int i) => Offset(
          padX + w * (i / (kills.length - 1)),
          padTop + h * (1 - kills[i] / maxV),
        );
    // REDO (2026-11-20): the mockup's chart has faint VERTICAL
    // dashed gridlines — one under each day's dot — NOT the
    // horizontal lines the old painter drew.
    final grid = Paint()..color = lineColor.withValues(alpha: 0.14)..strokeWidth = 1;
    const dashH = 4.0;
    const gapH = 4.0;
    for (var i = 0; i < kills.length; i++) {
      final x = pt(i).dx;
      var y = padTop;
      while (y < size.height - padBottom) {
        final y2 = math.min(y + dashH, size.height - padBottom);
        canvas.drawLine(Offset(x, y), Offset(x, y2), grid);
        y += dashH + gapH;
      }
    }
    // Smooth line through the points (midpoint quadratic segments).
    final line = Path()..moveTo(pt(0).dx, pt(0).dy);
    for (var i = 1; i < kills.length; i++) {
      final mid = Offset((pt(i - 1).dx + pt(i).dx) / 2, (pt(i - 1).dy + pt(i).dy) / 2);
      line.quadraticBezierTo(pt(i - 1).dx, pt(i - 1).dy, mid.dx, mid.dy);
    }
    line.lineTo(pt(kills.length - 1).dx, pt(kills.length - 1).dy);
    // Gradient fill under the line.
    final fill = Path.from(line)
      ..lineTo(pt(kills.length - 1).dx, size.height - padBottom)
      ..lineTo(pt(0).dx, size.height - padBottom)
      ..close();
    canvas.drawPath(
      fill,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [lineColor.withValues(alpha: 0.45), lineColor.withValues(alpha: 0.02)],
        ).createShader(Rect.fromLTWH(0, 0, size.width, size.height)),
    );
    // Mockup #25: the gold line glows softly, and each dot is a
    // brighter glowing point — a wide faint stroke under the line
    // plus a halo under every dot.
    canvas.drawPath(
      line,
      Paint()
        ..color = lineColor.withValues(alpha: 0.28)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 8
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawPath(
      line,
      Paint()
        ..color = lineColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round,
    );
    // Dots on each day (halo + core + bright centre).
    for (var i = 0; i < kills.length; i++) {
      canvas.drawCircle(pt(i), 7, Paint()..color = lineColor.withValues(alpha: 0.25));
      canvas.drawCircle(pt(i), 3.5, Paint()..color = lineColor);
      canvas.drawCircle(pt(i), 1.5, Paint()..color = kGoldBright);
    }
  }

  @override
  bool shouldRepaint(covariant _KillsLinePainter old) => old.kills != kills || old.lineColor != lineColor;
}

/// Faint diagonal sheen top-right (mockup #25 §26(a) — "a faint
/// diagonal streak top-right, no dots"). Three soft diagonal bands
/// painted BEHIND the scrolling content, barely visible (white
/// alpha 0.035–0.05) so they read as a sheen, not a graphic.
class _BgStreakPainter extends CustomPainter {
  const _BgStreakPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final band = Paint()
      ..color = Colors.white.withValues(alpha: 0.035)
      ..strokeWidth = 26
      ..strokeCap = StrokeCap.round;
    // Bands run top-right → bottom-left, like the mockup sheen.
    canvas.drawLine(Offset(size.width * 0.95, -10), Offset(size.width * 0.30, size.height * 0.85), band);
    canvas.drawLine(Offset(size.width * 1.05, size.height * 0.10), Offset(size.width * 0.55, size.height * 0.95), band);
    final thin = Paint()
      ..color = Colors.white.withValues(alpha: 0.05)
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(size.width * 0.88, -10), Offset(size.width * 0.18, size.height * 0.90), thin);
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}

class _PlayerStatsBody extends StatefulWidget {
  final String uid;
  const _PlayerStatsBody({required this.uid});
  @override
  State<_PlayerStatsBody> createState() => _PlayerStatsBodyState();
}

class _PlayerStatsBodyState extends State<_PlayerStatsBody> {
  late Future<_StatsData> _future;
  // Latest loaded stats, for the AppBar share action (the action
  // lives in the AppBar, the data in the FutureBuilder — this field
  // bridges them; set via .then so the AppBar rebuilds with it).
  _StatsData? _lastData;

  @override
  void initState() {
    super.initState();
    _future = _load();
    _future.then((d) {
      if (mounted) setState(() => _lastData = d);
    });
  }

  Future<_StatsData> _load() async {
    final profile = await SupaDb.getProfile(widget.uid);
    final history = await SupaDb.getMatchHistory(widget.uid);
    // REAL total Community Points (018 ledger SUM(delta)).
    final points = await SupaDb.getPointsTotal(widget.uid);
    // REAL team name: team_name of the player's latest registration.
    // getMyRegistrations has no order — pick the row with the newest
    // created_at; no registration yet → no team line (never invented).
    var teamName = '';
    var teamTs = 0;
    for (final r in await SupaDb.getMyRegistrations(widget.uid)) {
      final t = SupaDb.strOf(r['team_name'], SupaDb.strOf(r['teamName']));
      if (t.isEmpty) continue;
      final ts = SupaDb.parseTs(r['created_at']);
      if (ts >= teamTs) {
        teamTs = ts;
        teamName = t;
      }
    }
    // Mode + banner per tournament ("Nov 23, 8:00 PM | Squad" row,
    // and the match-card photo) — one fetch per distinct tournament,
    // best-effort ('Solo' fallback comes from normTournament itself;
    // a missing banner keeps the gold trophy tile).
    final modes = <String, String>{};
    final banners = <String, String>{};
    final ids = <String>{};
    for (final m in history) {
      final id = SupaDb.strOf(m['tournament_id'], SupaDb.strOf(m['tournamentId']));
      if (id.isNotEmpty) ids.add(id);
    }
    await Future.wait(ids.map((id) async {
      try {
        final t = await SupaDb.getTournament(id);
        modes[id] = SupaDb.strOf(t['mode'], 'Solo');
        banners[id] = SupaDb.strOf(t['banner_url'], SupaDb.strOf(t['bannerUrl']));
      } catch (_) {
        modes[id] = 'Solo';
        banners[id] = '';
      }
    }));
    // A stored team name shorter than 4 chars is a stray fragment,
    // not a team — hide the line (production evidence: the user's
    // only registration carries team_name 'jii').
    teamName = cleanTeamName(teamName);
    return _StatsData.from(
      profile,
      history,
      totalPoints: points,
      teamName: teamName,
      modes: modes,
      banners: banners,
    );
  }

  void _retry() => setState(() {
        _lastData = null;
        _future = _load();
        _future.then((d) {
          if (mounted) setState(() => _lastData = d);
        });
      });

  // Bottom-nav-at-bottom round (2026-11-22, #25): a nav tap pops
  // back to HomeShell first, then posts the wanted tab — the shell
  // (mounted below this pushed page) switches to it with its
  // normal _onTap. Pop first so a maintenance dialog from the
  // switch (if any) never opens over this page.
  void _onNavTap(int i) {
    Navigator.pop(context);
    homeTabRequest.value = i;
  }

  void _share(_StatsData d) {
    Share.share(
      'My ARENA HUB stats — ${d.name}: Lv.${d.level} ${d.rankTier}, '
      '${d.matches} matches, ${d.wins} wins, K/D ${d.kdRatio.toStringAsFixed(2)}, '
      '${_commas(d.totalPoints)} points, ${d.topPlacements} top-10 finishes.',
    );
  }

  @override
  Widget build(BuildContext context) {
    // Mockup #25 header: back chevron + PLAYER STATS + share and
    // settings icons top-right in the AppBar (white, 24). The icons
    // used to sit in the player-header row next to the name, which
    // squeezed the Lv pill + tier name until the tier clipped
    // ("BRON..."). Moving them here frees the whole row for the name.
    return Scaffold(
      appBar: AppBar(
        // Mockup #25 title ~26dp (was 22). FittedBox scaleDown is
        // the overflow safety: at 360dp beside the two AppBar
        // actions the title shrinks instead of truncating or
        // overflowing.
        title: const FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            'PLAYER STATS',
            style: TextStyle(fontStyle: FontStyle.italic, fontWeight: FontWeight.w900, fontSize: 26, letterSpacing: 0.5),
          ),
        ),
        actions: [
          IconButton(
            icon: Icon(Icons.share_outlined, color: kText, size: 24),
            tooltip: 'Share my stats',
            onPressed: _lastData == null ? null : () => _share(_lastData!),
          ),
          IconButton(
            icon: Icon(Icons.settings_outlined, color: kText, size: 24),
            tooltip: 'Settings',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => SettingsPage(uid: widget.uid)),
            ),
          ),
        ],
      ),
      // Bottom-nav-at-bottom round (2026-11-22, #25): this page is
      // a pushed Profile sub-screen (Profile → Player Stats tile),
      // so it shows the SHARED HomeShell nav — the same
      // ArenaBottomNav widget, not a copy — with the Profile tab
      // highlighted, as in mockup #25 (Profile active, gold). A
      // tap pops back to the shell and switches to that tab.
      bottomNavigationBar:
          ArenaBottomNav(currentIndex: 5, onTap: _onNavTap),
      // Mockup #25 §26(a): faint diagonal sheen top-right, painted
      // behind the scrolling content (the streaks stay fixed while
      // the list scrolls over them).
      body: Stack(
        children: [
          const Positioned(
            top: -10,
            right: -20,
            child: CustomPaint(size: Size(280, 220), painter: _BgStreakPainter()),
          ),
          FutureBuilder<_StatsData>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return ListView(
            padding: const EdgeInsets.all(16),
            children: const [
              LoadingSkeleton(height: 84),
              SizedBox(height: 12),
              LoadingSkeleton(height: 168),
              SizedBox(height: 12),
              LoadingSkeleton(height: 76),
              SizedBox(height: 12),
              LoadingSkeleton(height: 72),
            ],
          );
        }
        if (snap.hasError) {
          // Defensive: getProfile/getMatchHistory swallow read errors,
          // so this fires only for an unexpected throw.
          return Center(child: ErrorState(message: 'Stats load nahi ho sake: ${snap.error}', onRetry: _retry));
        }
        final d = snap.data ?? _StatsData.empty();
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _playerHeader(d),
            const SizedBox(height: 20),
            _sectionTitle('OVERVIEW STATISTICS'),
            const SizedBox(height: 10),
            _overview(d),
            const SizedBox(height: 20),
            _sectionTitle('GAME-SPECIFIC STATS'),
            const SizedBox(height: 10),
            _gameStats(d),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(child: _sectionTitle('RECENT MATCHES')),
                if (d.recent.isNotEmpty)
                  GestureDetector(
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => _AllMatchesPage(matches: d.recent, modes: d.modes, banners: d.banners),
                      ),
                    ),
                    child: Row(
                      children: [
                        Text('View All', style: TextStyle(color: kGold, fontWeight: FontWeight.bold, fontSize: 13)),
                        const SizedBox(width: 2),
                        Icon(Icons.arrow_forward, color: kGold, size: 14),
                      ],
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            if (d.recent.isEmpty)
              const EmptyState(
                icon: Icons.history,
                title: 'No matches yet',
                body: 'Abhi koi match record nahi — admin jab result credit karega, tab yahan matches dikhenge.',
              )
            else
              // Inline: first 2 only — the mockup shows 2 + View
              // All; the full history lives behind "View All".
              for (final m in d.recent.take(2)) _matchCard(m, d.modes, d.banners),
            const SizedBox(height: 20),
            _sectionTitle('ACHIEVEMENTS'),
            const SizedBox(height: 10),
            _achievements(d),
            const SizedBox(height: 8),
          ],
        );
      },
      ),
        ],
      ),
    );
  }

  // MISC (2026-11-20): section titles stay WHITE — mockup §25
  // shows white display headings ("OVERVIEW STATISTICS"), and the
  // kSectionLabel style is for SMALL caps labels (MORE worker's
  // ACCOUNT EMAIL pattern), not 17px display headings. HOME's
  // section headers are white too — same precedent.
  Widget _sectionTitle(String text) {
    return Text(
      text,
      style: TextStyle(color: kText, fontWeight: FontWeight.w900, fontSize: 17, letterSpacing: 0.3),
    );
  }

  Widget _playerHeader(_StatsData d) {
    // REDO (2026-11-20): sizes re-measured from the mockup —
    // avatar ~150px (~76dp, was 84), name ~24dp (was 22), tier
    // ~25dp measured (2026-11-22: raised 21 -> 25 to match; the
    // FittedBox scaleDown below shrinks it instead of truncating,
    // so CONQUEROR + pill + emblem still fit on a 360dp screen),
    // Lv pill 13, team 14.
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 76,
          height: 76,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: kGold, width: 3),
            color: kField,
            // Mockup #25: soft gold glow around the avatar ring.
            boxShadow: goldGlow(alpha: 0.45, blur: 16, spread: 1, offset: Offset.zero),
          ),
          child: ClipOval(
            // Disk-cached avatar (was bare Image.network).
            child: d.photoUrl.isEmpty
                ? Icon(Icons.person, color: kGold, size: 40)
                : ArenaCachedAvatar(
                    photoUrl: d.photoUrl,
                    radius: 38,
                    backgroundColor: kField,
                    fallback: Icon(Icons.person, color: kGold, size: 40),
                  ),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                d.name.toUpperCase(),
                style: TextStyle(color: kText, fontSize: 24, fontWeight: FontWeight.w900, letterSpacing: 0.3),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 6),
              // Mockup row: gold "Lv. N" pill + gold rank-tier title +
              // tier badge (tier is a label derived from the real
              // profiles.level — see file header).
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: kGold),
                      color: kGold.withValues(alpha: 0.12),
                    ),
                    // Mockup #25: the Lv pill is plain gold text in a
                    // dark pill with a gold border — NO star icon
                    // (the old star was an extra the mockup lacks).
                    child: Text('Lv.${d.level}', style: TextStyle(color: kGold, fontWeight: FontWeight.bold, fontSize: 13)),
                  ),
                  const SizedBox(width: 8),
                  // FIX (2026-11-20): the tier name clipped to
                  // "BRON..." — the share/settings icons used to
                  // sit in this row and squeeze it. They now live
                  // in the AppBar; the tier text also scales down
                  // instead of truncating, so the FULL tier name
                  // (CONQUEROR is the longest) always shows.
                  Flexible(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        d.rankTier,
                        // Mockup #25: tier name ~25dp (was 21); the
                        // FittedBox above scales it down instead of
                        // truncating, so CONQUEROR never clips.
                        style: TextStyle(color: kGold, fontWeight: FontWeight.w900, fontSize: 25),
                        maxLines: 1,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  // Mockup #25 rank badge: a gold winged crest next
                  // to CONQUEROR. The full winged crest is an asset
                  // gap — CONQUEROR gets the closest honest drawn
                  // badge (winged shield + crown); lower tiers keep
                  // their honest tier glyphs. The header badge is
                  // small with no halo so "CONQUEROR" still fits at
                  // 360 dp (the glow lives on the larger badges).
                  if (d.level >= 50)
                    const ArenaWingedBadge(size: 26, kind: ArenaBadgeKind.crown)
                  else
                    Icon(d.rankTierIcon, color: kGold, size: 20),
                ],
              ),
              // Real team name (latest registration) — omitted when
              // the player has no team yet, and short fragments are
              // filtered in _load (a stored 'jii' is not a team).
              if (d.teamName.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  d.teamName,
                  style: TextStyle(color: kMuted, fontSize: 14),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _overviewTile(String label, String value, [String? sub]) {
    // MISC (2026-11-20, user order "har jagah"): MockupCard — the
    // global 2-shine card style — instead of appCard's flat full
    // border. REDO (2026-11-20): the mockup's tiles are CENTRED
    // (label + value + sub all centred — the old code left-aligned
    // them), the value is ~24dp measured (was 28), radius 12 (the
    // mockup's corners are tighter than the 16 default).
    return MockupCard(
      radius: 12,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // FIX (2026-11-20): labels rendered "MATCHE..." — the tiles
          // are ~74px wide and the label was hard-ellipsised at 10.5.
          // FittedBox shrinks the label to fit instead of cutting it,
          // so MATCHES PLAYED / MATCHES WON / TOP PLACEMENTS /
          // TOTAL POINTS always render in full, single line, like the
          // mockup.
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(label, style: TextStyle(color: kMuted, fontSize: 10, fontWeight: FontWeight.bold), maxLines: 1),
          ),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            // Mockup value size ~24 measured from the image (was 28).
            child: Text(value, style: TextStyle(color: kGold, fontSize: 24, fontWeight: FontWeight.w900)),
          ),
          if (sub != null) ...[
            const SizedBox(height: 2),
            // S10 FIX (2026-11-23): the sub was the only bare Text in
            // the tile — under a wide font ('Top 10' = 60px in a
            // 58.5px tile) it wrapped to 2 lines and the tile Column
            // overflowed by 11px on the bottom. FittedBox scaleDown
            // (the same pattern the label + value above already use)
            // keeps it on one line; the real font is narrower than
            // the tile, so the app renders unchanged.
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(sub, style: TextStyle(color: kMuted, fontSize: 10), maxLines: 1),
            ),
          ],
        ],
      ),
    );
  }

  Widget _overview(_StatsData d) {
    // Mockup layout: 2×2 stat tiles on the left, PERFORMANCE chart
    // card on the right, same height. REDO (2026-11-20): the old
    // GridView sized tiles from childAspectRatio, so on a 360dp
    // screen the grid came out ~25dp SHORTER than the 236dp chart
    // card (a visible gap under the tiles) — and the whole block
    // was far taller than the mockup (~150dp measured). Column +
    // Expanded rows now force both sides to exactly the same
    // height, and the block is 168dp (tiles 79dp each: label +
    // 24dp value + "Top 10" sub fit with room to spare).
    return SizedBox(
      height: 168,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Column(
              children: [
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(child: _overviewTile('MATCHES PLAYED', '${d.matches}')),
                      const SizedBox(width: 10),
                      Expanded(child: _overviewTile('MATCHES WON', '${d.wins}')),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(child: _overviewTile('TOP PLACEMENTS', '${d.topPlacements}', 'Top 10')),
                      const SizedBox(width: 10),
                      // Mockup 4th tile: TOTAL POINTS — real ledger total
                      // (was Total Earnings, Rs 0.00).
                      Expanded(child: _overviewTile('TOTAL POINTS', _commas(d.totalPoints))),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(child: _weekChart(d)),
        ],
      ),
    );
  }

  Widget _weekChart(_StatsData d) {
    const days = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
    final weekMatches = d.week.fold<int>(0, (s, b) => s + b.matches);
    // MISC (2026-11-20): MockupCard — global 2-shine card style.
    // REDO: radius 12 (mockup's corners are tighter than 16).
    return MockupCard(
      radius: 12,
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('PERFORMANCE', style: TextStyle(color: kText, fontWeight: FontWeight.w900, fontSize: 15)),
          Text('Last 7 Days', style: TextStyle(color: kMuted, fontSize: 12)),
          const SizedBox(height: 8),
          if (weekMatches == 0)
            Expanded(
              child: Center(
                child: Text(
                  'No matches in the last 7 days.',
                  style: TextStyle(color: kMuted, fontSize: 12),
                  textAlign: TextAlign.center,
                ),
              ),
            )
          else
            Expanded(
              child: Column(
                children: [
                  Expanded(
                    child: CustomPaint(
                      painter: _KillsLinePainter(
                        kills: d.week.map((b) => b.kills).toList(),
                        lineColor: kGold,
                      ),
                      size: Size.infinite,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      for (final day in days)
                        Expanded(
                          child: Text(day, textAlign: TextAlign.center, style: TextStyle(color: kMuted, fontSize: 11)),
                        ),
                    ],
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _gameStats(_StatsData d) {
    Widget cell(String label, String value) {
      return Expanded(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Column(
            children: [
              // FIX (2026-11-20): "HEADSHOTS" wrapped as "HEADSHOT
              // S" and "AVG. DAMAGE" wrapped — the labels are 10.5
              // at ~62px per cell on a 360px screen. FittedBox
              // shrinks each label to one line instead of wrapping,
              // like the mockup (all four labels on one line each).
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(label, style: TextStyle(color: kMuted, fontSize: 10, fontWeight: FontWeight.bold), maxLines: 1),
              ),
              const SizedBox(height: 6),
              FittedBox(
                fit: BoxFit.scaleDown,
                // REDO (2026-11-20): game values measure ~26px cap
                // in the mockup vs ~34px for the tile values — about
                // 3/4 the size (was 24, same as the tiles).
                child: Text(value, style: TextStyle(color: kGold, fontSize: 20, fontWeight: FontWeight.w900)),
              ),
            ],
          ),
        ),
      );
    }

    // REDO (2026-11-20): the mockup's dividers are short vertical
    // lines spanning the CONTENT height (~44dp), inset from the
    // card's top/bottom edges — not full-height borders.
    Widget divider() => Container(width: 1, height: 44, color: kBorder);

    // MISC (2026-11-20): MockupCard — global 2-shine card style
    // (padding 14 preserves the old appCard default). REDO: radius
    // 12 (mockup's corners are tighter than 16).
    return MockupCard(
      radius: 12,
      padding: const EdgeInsets.all(14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Mockup first column: K/D RATIO (was "KILLS / MATCH").
          // Real K/D — kills ÷ (matches − wins), see kdRatio.
          cell('K/D RATIO', d.kdRatio.toStringAsFixed(2)),
          divider(),
          cell('AVG. DAMAGE', d.avgDamage.toStringAsFixed(0)),
          divider(),
          cell('HEADSHOTS', '${d.hsPct.toStringAsFixed(1)}%'),
          divider(),
          cell('WIN RATE', '${d.winRate.toStringAsFixed(1)}%'),
        ],
      ),
    );
  }

  // REDO (2026-11-20): the mockup's achievements are ROUND winged
  // gold medallions — assets/images/badge_*.png, cropped from
  // mockup #25 itself (the user's own designs, authorized
  // 2026-11-20). The shield-crest PremiumAchievementBadge from the
  // P-all-fixes round was the wrong shape (a tall shield, not the
  // mockup's round medallion) and too big (64dp vs ~44dp measured).
  // Closest-art mapping ONLY — labels stay the REAL earned
  // achievements, never the mockup's sample names.
  String _achievementBadgeAsset(String name) {
    switch (name) {
      case '10 Matches':
        return 'assets/images/badge_slayer.png';
      case 'Champion':
        return 'assets/images/badge_survivor.png';
      case 'Veteran':
        return 'assets/images/badge_deadshot.png';
      case 'First Win':
      case 'Top Earner':
      default:
        return 'assets/images/badge_mvp.png';
    }
  }

  Widget _achievements(_StatsData d) {
    if (d.achievements.isEmpty) {
      // MISC (2026-11-20): MockupCard — global 2-shine card style.
      return MockupCard(
        radius: 12,
        padding: const EdgeInsets.all(14),
        child: Text(
          'No achievements yet — pehli win par First Win milega!',
          style: TextStyle(color: kMuted, fontSize: 13),
        ),
      );
    }
    // Mockup: one row of round medallions (~44dp measured, 48dp
    // here), evenly spread, gold glow behind each, label beneath.
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final a in d.achievements)
          Expanded(
            child: Column(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    boxShadow: goldGlow(alpha: 0.35, blur: 12, spread: 0, offset: Offset.zero),
                  ),
                  child: Image.asset(
                    _achievementBadgeAsset(a),
                    width: 48,
                    height: 48,
                    fit: BoxFit.contain,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  a,
                  style: TextStyle(color: kText, fontSize: 11, fontWeight: FontWeight.w500),
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
      ],
    );
  }

}

/// Recent-match card, mockup layout: thumbnail + title with gold
/// "+N Pts" on the right, "date | Mode" line with the gold
/// "Placement: #N" pill at its right end (only when a real
/// placement exists). Points per match use the server's 022 formula
/// (see _matchPoints). The thumbnail is the tournament's real
/// banner photo when one exists, else the gold trophy tile (game
/// art is never copied). Top-level so both the inline list and the
/// View All page share it.
/// REDO (2026-11-20): the old card put the pill BELOW the date on
/// the left (a third row — the card was ~110dp tall); the mockup's
/// card is two lines (~60dp measured) with the pill on the date
/// row at the right. Thumbnail 48 (was 56), padding 12 (was 14),
/// and the date is the short mockup form "Nov 23, 8:00 PM" (the old
/// fmtDate included the year: "23 Nov 2026, 8:00 PM").
Widget _matchCard(Map<String, dynamic> m, Map<String, String> modes, Map<String, String> banners) {
  final rank = SupaDb.intOf(m['rank']);
  final pts = _matchPoints(m);
  final tid = SupaDb.strOf(m['tournament_id'], SupaDb.strOf(m['tournamentId']));
  final mode = modes[tid] ?? 'Solo';
  final banner = banners[tid] ?? '';
  return Padding(
    padding: const EdgeInsets.only(bottom: 10),
    // MISC (2026-11-20): MockupCard — global 2-shine card style.
    // REDO: radius 12 (mockup's corners are tighter than 16).
    child: MockupCard(
      radius: 12,
      padding: const EdgeInsets.all(12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Real banner photo when the tournament has one; the
          // gold trophy tile is the fallback (never game art).
          if (banner.isEmpty)
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(color: kGold.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(10)),
              child: Icon(Icons.emoji_events, color: kGold, size: 26),
            )
          else
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: ArenaCachedImage(
                imageUrl: banner,
                width: 48,
                height: 48,
                fit: BoxFit.cover,
              ),
            ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        SupaDb.strOf(m['tournamentName']),
                        style: TextStyle(color: kText, fontWeight: FontWeight.bold, fontSize: 15),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '+$pts Pts',
                      style: TextStyle(color: kGold, fontWeight: FontWeight.bold, fontSize: 13),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Row(
                  children: [
                    Icon(Icons.calendar_today, color: kMuted, size: 12),
                    const SizedBox(width: 4),
                    Flexible(
                      // FittedBox shrinks the date instead of
                      // cutting the mode on narrow screens, so the
                      // pill still fits at the row's right end.
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          '${_shortDate(SupaDb.intOf(m['timestamp']))}  |  $mode',
                          style: TextStyle(color: kMuted, fontSize: 12),
                          maxLines: 1,
                        ),
                      ),
                    ),
                    // Mockup: the placement pill sits at the RIGHT
                    // end of the date row, under the "+N Pts".
                    if (rank > 0) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: kGold),
                          color: kGold.withValues(alpha: 0.12),
                        ),
                        child: Text('Placement: #$rank', style: TextStyle(color: kGold, fontSize: 11, fontWeight: FontWeight.bold)),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

/// Full match history behind the "View All →" link (the inline list
/// shows the first 2 only, like the mockup).
class _AllMatchesPage extends StatelessWidget {
  final List<Map<String, dynamic>> matches;
  final Map<String, String> modes;
  final Map<String, String> banners;
  const _AllMatchesPage({required this.matches, required this.modes, required this.banners});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'RECENT MATCHES',
          style: TextStyle(fontStyle: FontStyle.italic, fontWeight: FontWeight.w900, fontSize: 22, letterSpacing: 0.5),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [for (final m in matches) _matchCard(m, modes, banners)],
      ),
    );
  }
}
