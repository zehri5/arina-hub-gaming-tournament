import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../components/arena_components.dart';
import '../components/cached_image.dart';
import '../platform/competition/checkin_page.dart';
import '../platform/competition/waitlist_page.dart';
import '../platform/core/scoring.dart';
import '../platform/disputes/dispute_center_page.dart';
import '../platform/scoring/leaderboard_page.dart';
import '../platform/scoring/scoring_display.dart';
import '../platform/scoring/scoring_template_store.dart';
import '../services/imgbb_service.dart';
import '../services/presence_service.dart';
import '../services/squad.dart';
import '../services/supabase_db.dart';
import 'frames_widgets.dart';
import 'more_screens.dart';
import 'pro_features.dart'
    hide
        CheckInPage; // Platform CheckInPage (tournament check-in) is imported below; the Pro-hub CheckInPage (match_checkins) is not used in this file.
import 'status_sheet.dart';
import 'watch_live_screen.dart';
import '../utils.dart';
import '../widgets/arena_ui.dart';

/// Current app version (pubspec 1.0.1). Forced-update compares
/// app_settings.update_config.version against this constant — there is
/// no package_info_plus dependency, so a version-code bump must update
/// this constant too (noted in the port report).
const String kAppVersion = '1.0.1';

String tName(Map<String, dynamic> t) => strVal(
    t['name'],
    strVal(t['tournamentName'],
        strVal(t['title'], strVal(t['gameName'], 'Tournament'))));
String tImage(Map<String, dynamic> t) => strVal(t['banner'],
    strVal(t['bannerUrl'], strVal(t['imageUrl'], strVal(t['image'], ''))));
String tGame(Map<String, dynamic> t) =>
    strVal(t['gameName'], strVal(t['game'], ''));
String tStatus(Map<String, dynamic> t) =>
    strVal(t['status'], 'upcoming').toLowerCase();
int teamSizeOf(Map<String, dynamic> t) => SupaDb.teamSizeOf(t);

/// Tournament Details fixes (2026-11-21, user FINAL list +
/// standing rule: NOTHING on this screen may be hidden, cut or
/// broken) — display-side sanitisers. All pure functions, unit
/// tested in test/tournament_detail_fixes_test.dart.
///
/// [displayTournamentDescription]: empty / whitespace-only / known
/// dummy placeholder text ("test description" is live on the Pro
/// Tour row) renders "No description added yet" — dummy text is
/// never shown to players.
String displayTournamentDescription(String raw) {
  final cleaned = raw.trim();
  if (cleaned.isEmpty) return 'No description added yet';
  // Strip trailing periods so "Test." still matches the dummy set.
  final lower =
      cleaned.toLowerCase().replaceAll(RegExp(r'[.\s]+$'), '').trim();
  const dummies = {
    'test',
    'test description',
    'testing',
    'dummy',
    'dummy text',
    'description',
    'lorem ipsum',
    'lorem',
    'tbd',
    'todo',
    'coming soon',
    'no description',
    'n/a',
    'na',
    '-',
    '--',
    '...',
    'xxx',
    'asdf',
  };
  if (dummies.contains(lower) || lower.contains('lorem ipsum')) {
    return 'No description added yet';
  }
  return cleaned;
}

/// Display mapping for map names (2026-11-21): the live data has
/// the typo "Erangle"; the correct name is "Erangel". Display-only
/// — the stored tag/column is NOT changed here (the admin fixes the
/// tag in the database). Case-insensitive; any other map name
/// passes through untouched.
String displayMapName(String raw) {
  final cleaned = raw.trim();
  if (cleaned.isEmpty) return cleaned;
  return cleaned.replaceAll(
      RegExp(r'\berangle\b', caseSensitive: false), 'Erangel');
}

/// MATCH INFO map (2026-11-21): the live Pro Tour row has
/// map/perspective columns NULL and tags ["Squad", "Erangle"] —
/// that is why the box showed "—". The map name is therefore read
/// from the tags (first tag that is a known PUBG map, typo
/// included), with the `map` column winning when set. When neither
/// source names a map, the PUBG default "Erangel" shows — the same
/// defaulting pattern as the user-ordered TPP default below, never
/// a dash (standing rule).
String matchInfoMapName(Map<String, dynamic> t) {
  final col = strVal(t['map']);
  if (col.isNotEmpty) return displayMapName(col);
  const knownMaps = {
    'erangel',
    'erangle',
    'miramar',
    'sanhok',
    'vikendi',
    'livik',
    'karakin',
    'deston',
    'rondo',
    'nusa',
  };
  for (final tag in SupaDb.asList(t['tags'])) {
    final v = tag.toString().trim().toLowerCase();
    if (knownMaps.contains(v)) return displayMapName(tag.toString());
  }
  return 'Erangel';
}

/// MATCH INFO perspective (2026-11-21): NULL/empty → "TPP"
/// (PUBG default, user order); a TPP/FPP tag wins over the default.
String matchInfoPerspective(Map<String, dynamic> t) {
  final col = strVal(t['perspective']);
  if (col.isNotEmpty) return col;
  for (final tag in SupaDb.asList(t['tags'])) {
    final v = tag.toString().trim().toLowerCase();
    if (v == 'tpp') return 'TPP';
    if (v == 'fpp') return 'FPP';
  }
  return 'TPP';
}

/// MATCH INFO team size (2026-11-21): always the full "N Players"
/// — Squad = 4, Duo = 2, Solo = 1. Never truncated.
String matchInfoTeamSizeLabel(Map<String, dynamic> t) =>
    '${teamSizeOf(t)} Players';

/// Phase 2 — room-credential gating, ONE definition shared by the
/// Detail page, MatchDetailsPage (#14) and MatchRoomPage (#19):
/// show only if show_id_pass AND (ongoing OR upcoming + within
/// 10 min before start — mockup #1: the room opens 08:50 PM for a
/// 09:00 PM start). B-11 (2026-11-21): the direct
/// room_id/room_password read is GONE — all three display sites
/// read credentials only via SupaDb.getRoomCredentials (026 RPC);
/// the gating rule stays the same.
bool roomVisibleFor(Map<String, dynamic> t) {
  final showFlag = t['showIdPass'] == true || t['show_id_pass'] == true;
  final status = tStatus(t);
  final startMs = intVal(t['startTime']);
  final now = DateTime.now().millisecondsSinceEpoch;
  // The admin-set lobby time wins when present (audit fix 2026-11-21
  // — the Matches picker wrote lobby_opens_at but nothing read it);
  // otherwise the room opens 10 min before start, as before.
  final lobbyMs = SupaDb.parseTs(t['lobbyOpensAt'] ?? t['lobby_opens_at']);
  final openMs = lobbyMs > 0 ? lobbyMs : startMs - 10 * 60 * 1000;
  final withinWindow =
      startMs > 0 && now >= openMs && (startMs - now) >= -24 * 60 * 60 * 1000;
  return showFlag &&
      (status == 'ongoing' || (status == 'upcoming' && withinWindow));
}

/// Phase 2 — Save Event, device-local interim (SharedPreferences).
/// Server-side saved_events lands with draft 019 in Phase 4; until
/// then the save persists on this device only and is NOT synced.
/// No fake "saved" state: the toggle reads the real stored list.
Future<Set<String>> loadSavedTournamentIds() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getStringList('saved_tournaments')?.toSet() ?? <String>{};
}

Future<bool> toggleSavedTournament(String id) async {
  final prefs = await SharedPreferences.getInstance();
  final saved = prefs.getStringList('saved_tournaments')?.toSet() ?? <String>{};
  final nowSaved = !saved.contains(id);
  if (nowSaved) {
    saved.add(id);
  } else {
    saved.remove(id);
  }
  await prefs.setStringList('saved_tournaments', saved.toList());
  return nowSaved;
}

Future<void> openAdTarget(BuildContext context, Map<String, dynamic> ad) async {
  final type = strVal(ad['targetType']);
  final targetId = strVal(ad['targetId']);
  final targetName = strVal(ad['targetName']);
  if (type == 'tournament') {
    final t = await SupaDb.getTournament(targetId);
    if (t.isEmpty) {
      if (context.mounted) toast(context, 'This offer is no longer available');
      return;
    }
    if (context.mounted)
      Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => TournamentDetailPage(tournament: t)));
  } else if (type == 'game') {
    if (context.mounted) {
      Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => TournamentsPage(
                  gameFilter: targetId.isNotEmpty ? targetId : targetName,
                  gameName: targetName.isNotEmpty ? targetName : null)));
    }
  } else {
    // Promotion target: the promotion's ONLY target is its link
    // (promotions carry no target_type/target_id — see the admin
    // promotions form). FIX 19 (2026-11-21): NO intermediate
    // "Promotion" dialog — the tap goes STRAIGHT to the link. A
    // promotion with no link set has nowhere to go: silent no-op
    // (no dialog, no toast — the admin simply hasn't set a target).
    // The 'no longer available' toast below stays: it fires only
    // when the promotion itself is GONE (dead target), never as an
    // intermediate step in front of a live target.
    final promos = await SupaDb.getPromotions();
    final match = promos.where((p) => p['id'] == targetId).toList();
    if (match.isEmpty) {
      if (context.mounted) toast(context, 'This offer is no longer available');
      return;
    }
    final link = strVal(match.first['link']);
    if (link.isEmpty) return;
    final uri = Uri.parse(link);
    if (await canLaunchUrl(uri))
      await launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}

/// List card. ROOT-CAUSE FIX: `joined` comes from the caller's
/// registrations query (tournament_registrations for the current uid),
/// NEVER from the detail page alone. Joined -> disabled green "Joined"
/// button; the card itself still taps through to Detail. Non-upcoming
/// tournaments show their status label; a full upcoming tournament
/// shows "Full".
/// 2026-11-20 USER CORRECTION (global card rule): the shared
/// MockupCard (gradient fill + two orbiting yellow shines, NO full
/// border) replaces appCard here — this card's content is
/// theme-aware (k* tokens), so the shared widget is correct.
/// Small stat chip: wraps to a second line instead of truncating.
/// (Overflow fix: the old single Row of three Flexible Texts squeezed
/// "Prize: Rs ..." / "Fee: ..." / "4/100" into ~1/3 width each at the
/// user's large text scale, rendering as "Pr... Fe... 4/..." — chips
/// wrap, so every value stays fully readable.)
Widget _infoChip(String label, Color color, {bool bold = false}) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration:
        BoxDecoration(color: kField, borderRadius: BorderRadius.circular(16)),
    child: Text(label,
        style: TextStyle(
            color: color,
            fontWeight: bold ? FontWeight.bold : FontWeight.normal,
            fontSize: 13)),
  );
}

Widget tournamentCard(BuildContext context, Map<String, dynamic> t,
    {bool showJoin = true,
    bool joined = false,
    int? joinedCount,
    String? mySquadId,
    String? myTeamName}) {
  final maxP = intVal(t['maxPlayers'], 0);
  final count = joinedCount ?? 0;
  final fee = numVal(t['entryFee']);
  final prize = numVal(t['prizePool']);
  final status = tStatus(t);
  final isFull = maxP > 0 && count >= maxP;
  final feeLabel = fee == 0 ? 'Free' : fmtRs(fee);
  final spotsLabel = maxP > 0 ? '$count/$maxP' : '$count joined';
  // v2016 FIX 11(a): the openUnifiedRoom() helper is GONE (it was
  // already uncalled) — tournament rooms moved to team chat.
  return MockupCard(
    padding: const EdgeInsets.all(14),
    child: InkWell(
      onTap: () async {
        await Navigator.push(
            context,
            MaterialPageRoute(
                builder: (_) => TournamentDetailPage(tournament: t)));
        // Detail may have joined / changed state: force a fresh fetch
        // so the card flips without re-entering the screen (see B).
        SupaDb.bumpRefresh();
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // FIX ROUND 2026-10-28 (board card cover): a FIXED 16:9 slot
          // with BoxFit.cover, centred — the old fixed-height-130 image
          // cropped admin banners unpredictably and showed a giant
          // cut-off "PUBG" text. A banner whose text is baked into the
          // image itself cannot be re-typeset by the app, but the
          // fixed-aspect slot stops the giant-crop effect; empty/failed
          // banners get a generic icon placeholder, never game art.
          // HOME FIX 3 — cover via _HomeCoverImage (user's 00:12
          // screenshot): a dead/slow banner NEVER renders the
          // shared broken-image error box — loading, error and
          // no-banner all show the same flat dark + gold trophy
          // fallback, disk-cached so slow net never re-downloads.
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: _HomeCoverImage(
                  imageUrl: tImage(t),
                  width: double.infinity,
                  height: double.infinity,
                  fit: BoxFit.cover),
            ),
          ),
          const SizedBox(height: 8),
          Text(tName(t),
              style: TextStyle(
                  color: kText, fontWeight: FontWeight.bold, fontSize: 16),
              maxLines: 2,
              overflow: TextOverflow.ellipsis),
          // HOME #37 FIX — the date segment is HIDDEN when there is
          // no start time (never "N/A", never invented).
          Text(
              '${tGame(t)}  •  ${strVal(t['mode'], 'Solo')}${intVal(t['startTime']) > 0 ? '  •  ${_shortDate(intVal(t['startTime']))}' : ''}',
              style: TextStyle(color: kMuted, fontSize: 12),
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              _infoChip('Prize: ${fmtRs(prize)}', kGold, bold: true),
              _infoChip('Fee: $feeLabel', kText),
              _infoChip(spotsLabel, kMuted),
            ],
          ),
          if (maxP > 0) ...[
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                  value: (count / maxP).clamp(0.0, 1.0),
                  minHeight: 8,
                  backgroundColor: kField,
                  valueColor: AlwaysStoppedAnimation<Color>(kGold)),
            ),
          ],
          if (showJoin) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                // HOME #37 FIX — Joined: gold OUTLINE button with a
                // check (mockup #37 has no green buttons). The old
                // disabled green button is gone.
                Expanded(
                  child: joined
                      ? OutlinedButton(
                          onPressed: null,
                          style: OutlinedButton.styleFrom(
                            side: BorderSide(color: kGold, width: 1.5),
                            backgroundColor: kCard,
                            foregroundColor: kGold,
                            disabledForegroundColor: kGold,
                          ),
                          child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.check, size: 16),
                                SizedBox(width: 4),
                                Text('Joined',
                                    style:
                                        TextStyle(fontWeight: FontWeight.bold))
                              ]),
                        )
                      : ElevatedButton(
                          onPressed: (status != 'upcoming' || isFull)
                              ? null
                              : () async {
                                  await Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                          builder: (_) => JoinTournamentPage(
                                              tournament: t)));
                                  // Join page pops here: force a fresh fetch
                                  // so Joined shows immediately (see B).
                                  SupaDb.bumpRefresh();
                                },
                          // FIX ROUND 2026-10-28: board PRIMARY button is
                          // orange with white text in BOTH modes (the old
                          // gold button went dark-gold in light mode).
                          style: ElevatedButton.styleFrom(
                            backgroundColor: kGold,
                            disabledBackgroundColor: kField,
                            disabledForegroundColor: Colors.white,
                            foregroundColor: Colors.white,
                            elevation: 0,
                          ),
                          child: Text(
                              (status != 'upcoming'
                                  ? status[0].toUpperCase() +
                                      status.substring(1)
                                  : (isFull ? 'Full' : 'Join Now')),
                              style:
                                  const TextStyle(fontWeight: FontWeight.bold)),
                        ),
                ),
                const SizedBox(width: 8),
                // v2016 FIX 11(a): the second button is Details in
                // both states — the "Enter Room" branch is GONE
                // (voice rooms moved to team chat).
                OutlinedButton(
                  onPressed: () async {
                    await Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) =>
                                TournamentDetailPage(tournament: t)));
                    SupaDb.bumpRefresh();
                  },
                  style:
                      OutlinedButton.styleFrom(side: BorderSide(color: kGold)),
                  child: Text('Details',
                      style:
                          TextStyle(color: kGold, fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          ],
        ],
      ),
    ),
  );
}

/// Wave 4 design-match (#37) — match-time label from a REAL start
/// timestamp: "Today, 8:00 PM" / "Tomorrow, 8:00 PM", else the full
/// date. "Time TBA" when the tournament has no start time — never a
/// guessed time.
String _matchTimeLabel(int startMs) {
  if (startMs <= 0) return 'Time TBA';
  final d = DateTime.fromMillisecondsSinceEpoch(startMs);
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(d.year, d.month, d.day);
  final diff = day.difference(today).inDays;
  final hh = d.hour % 12 == 0 ? 12 : d.hour % 12;
  final mm = d.minute.toString().padLeft(2, '0');
  final ampm = d.hour >= 12 ? 'PM' : 'AM';
  final time = '$hh:$mm $ampm';
  if (diff == 0) return 'Today, $time';
  if (diff == 1) return 'Tomorrow, $time';
  return fmtDate(startMs);
}

/// Wave 4 design-match (#37) — ONE hero slide: the tournament's REAL
/// banner_url cover (never a mock photo; a dark placeholder with a
/// gold trophy icon when the tournament has no banner), the
/// "REGISTRATION OPEN" pill only when the tournament is actually
/// upcoming, the REAL name in big italic, the REAL date + mode, and a
/// gold VIEW EVENT button into TournamentDetailPage.
class _HeroSlide extends StatelessWidget {
  final Map<String, dynamic> tournament;
  final int dotCount;
  final int activeDot;
  final bool isActive;
  const _HeroSlide(
      {required this.tournament,
      this.dotCount = 0,
      this.activeDot = 0,
      this.isActive = true});

  @override
  Widget build(BuildContext context) {
    final t = tournament;
    final img = tImage(t);
    final upcoming = tStatus(t) == 'upcoming';
    final startMs = intVal(t['startTime']);
    // HOME #37 FIX — slanted hero with diagonal gold trim + in-hero
    // dots (see _SlantedHeroClipper / _HeroOutlinePainter). The
    // rectangular Container + ClipRRect + gold glow shadow are gone:
    // the mockup hero has no rectangular glow.
    // FIX 20 (2026-11-21): the slide box is 216 tall; the banner
    // is 204, bottom-aligned; the top 12dp is the character
    // pop-out zone (empty on tournament heroes — they have no
    // character cutout; the admin slider hero below fills it).
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: _kHeroBannerHeight,
          child: ClipPath(
            clipper: const _SlantedHeroClipper(),
            child: Stack(
              fit: StackFit.expand,
              children: [
                // HOME FIX 3 — hero cover via _HomeCoverImage: a
                // dead/slow banner renders the same flat dark +
                // gold trophy as the no-banner state — never the
                // shared broken-image error box, never blank.
                _HomeCoverImage(
                    imageUrl: img,
                    width: double.infinity,
                    height: double.infinity,
                    fit: BoxFit.cover,
                    iconSize: 56),
                // Bottom gradient so the white title stays readable over
                // any cover art.
                Container(
                  // PHASE 2 REDESIGN (guide §7): readability scrim over
                  // the banner art — hBg token now, same 0.8 -> solid ramp.
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.transparent,
                          hBg.withValues(alpha: 0.8),
                          hBg
                        ]),
                  ),
                ),
                // HOME FIX 2 — animated light-yellow sheen sweep
                // (detail image 01b): gentle moving gold light
                // across the hero, clipped to the slanted shape.
                Positioned.fill(
                    child:
                        IgnorePointer(child: _HeroSheen(isActive: isActive))),
                // FIX 6 (2026-11-21): the hero title is DESIGNED for
                // up to 2 lines (_heroTitle maxLines: 2 — the
                // mockup's own title is 2 lines), but the old
                // padding (36/14) + gaps (6/10) only budgeted ONE:
                // a 2-line title overflowed the 222 banner by 9px.
                // Top 36->32 (pill still 12px clear of the 20px
                // slant) + bottom 14->10 + gaps 6->4 / 10->8 buys
                // 12px; the Spacer absorbs the slack on 1-line
                // titles, so their layout is unchanged.
                // v2010: banner 204 + slant 36 — top padding 32->36
                // (just clears the steeper slant: clip edge at the
                // pill's left is ~y35) + bottom 10->8 + title 28
                // + button padding 8 + gaps 2/6: the 2-line + pill
                // stack fits the 204 banner (test-verified).
                // v2014: slant is 24 now (was 36) — the 36 top
                // padding clears it with room to spare.
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 36, 16, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (upcoming) _regOpenPill(),
                      const Spacer(),
                      _heroTitle(tName(t), fontSize: 28),
                      const SizedBox(height: 2),
                      _heroMetaRow(
                          startMs: startMs, mode: strVal(t['mode'], 'Solo')),
                      const SizedBox(height: 6),
                      ElevatedButton(
                        onPressed: () async {
                          await Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) =>
                                      TournamentDetailPage(tournament: t)));
                          SupaDb.bumpRefresh();
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: hGold,
                          foregroundColor: Colors.black,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 20, vertical: 8),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(24)),
                          elevation: 0,
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text('VIEW EVENT',
                                style: TextStyle(
                                    fontWeight: FontWeight.w900, fontSize: 15)),
                            SizedBox(width: 4),
                            Icon(Icons.chevron_right, size: 20),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                // HOME #37 FIX ROUND 2 — dots show even for a single
                // slide (staging has exactly 1 slider row, so the old
                // `dotCount > 1` guard hid them entirely).
                if (dotCount >= 1)
                  Positioned(
                    right: 14,
                    bottom: 32,
                    child: Row(
                        children: List.generate(
                            dotCount, (i) => _heroDot(i == activeDot))),
                  ),
              ],
            ),
          ),
        ),
        const Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: _kHeroBannerHeight,
            child: CustomPaint(painter: _HeroOutlinePainter())),
        // FIX 20 REFINEMENT #3: TWO tapered corner lines (top-right
        // + bottom-left), NOT the old continuous travelling ring.
        // Active slide only.
        Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: _kHeroBannerHeight,
            child: IgnorePointer(child: _HeroCornerLines(isActive: isActive))),
      ],
    );
  }
}

/// Wave C (A) — ADMIN SLIDER HERO (user order 2026-11-19 ~09:08
/// PKT): one slide from a `public.sliders` row (STAGING; admin
/// manages slides, app changes automatically, no rebuild). Layout is
/// the mockup hero's: image + REGISTRATION OPEN pill + big title +
/// subtitle row + gold VIEW EVENT button. The pill shows ONLY when
/// the slide's target tournament is really upcoming (resolved via
/// SupaDb.getTournament); the subtitle row shows only when the row
/// has a subtitle — the sliders table has NO date/mode columns, so
/// no date/mode row is invented. Tap opens the target tournament
/// (target_type='tournament' + target_id); a missing target toasts
/// honestly; target_url opens externally when there is no
/// tournament target. NEVER a hardcoded mock slide.
class _SliderHeroSlide extends StatefulWidget {
  final Map<String, dynamic> slide;
  final int dotCount;
  final int activeDot;
  final bool isActive;
  const _SliderHeroSlide(
      {required this.slide,
      this.dotCount = 0,
      this.activeDot = 0,
      this.isActive = true});
  @override
  State<_SliderHeroSlide> createState() => _SliderHeroSlideState();
}

class _SliderHeroSlideState extends State<_SliderHeroSlide> {
  Map<String, dynamic>? _target;

  @override
  void initState() {
    super.initState();
    final type = strVal(widget.slide['target_type'], 'tournament');
    final id = strVal(widget.slide['target_id']);
    if (type == 'tournament' && id.isNotEmpty) {
      SupaDb.getTournament(id).then((t) {
        if (mounted && t.isNotEmpty) setState(() => _target = t);
      });
    }
  }

  Future<void> _openTarget() async {
    Map<String, dynamic>? target = _target;
    final type = strVal(widget.slide['target_type'], 'tournament');
    // F1 (2026-11-21 audit): target_type 'none' means "sirf tasveer" —
    // tapping it must do nothing, never the misleading "no longer
    // available" toast.
    if (type == 'none') return;
    final id = strVal(widget.slide['target_id']);
    if (type == 'tournament' && id.isNotEmpty) {
      final Map<String, dynamic> resolved =
          target ?? await SupaDb.getTournament(id);
      if (!mounted) return;
      if (resolved.isNotEmpty) {
        await Navigator.push(
            context,
            MaterialPageRoute(
                builder: (_) => TournamentDetailPage(tournament: resolved)));
        SupaDb.bumpRefresh();
        return;
      }
      toast(context, 'This event is no longer available');
      return;
    }
    final url = strVal(widget.slide['target_url']);
    if (url.isNotEmpty) {
      final uri = Uri.parse(url);
      if (await canLaunchUrl(uri))
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      return;
    }
    toast(context, 'This event is no longer available');
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.slide;
    final img = strVal(s['image_url']);
    final title = strVal(s['title'], 'Arena Hub');
    final subtitle = strVal(s['subtitle']);
    final upcoming = _target != null && tStatus(_target!) == 'upcoming';
    // HOME #37 FIX — when the slide's target tournament resolved,
    // the meta row comes from THAT tournament's real data (date /
    // mode); otherwise the slide's own subtitle row stays (never an
    // invented date/mode).
    final target = _target;
    // FIX 20 (2026-11-21): 2-image hero — the background banner +
    // an optional CHARACTER cutout (transparent PNG, admin-set via
    // sliders.character_image_url, migration 038). The cutout
    // renders ~1.05x, right-aligned, its head ~12dp above the
    // banner's top edge (the 3D pop-out). No character set: the
    // banner renders normally, exactly like before.
    final character = strVal(s['character_image_url']);
    // HOME #37 FIX — slanted hero with diagonal gold trim + in-hero
    // dots (see _SlantedHeroClipper / _HeroOutlinePainter).
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: _kHeroBannerHeight,
          child: ClipPath(
            clipper: const _SlantedHeroClipper(),
            child: Stack(
              fit: StackFit.expand,
              children: [
                // HOME FIX 3 — slider cover via _HomeCoverImage:
                // a dead/slow banner renders the same flat dark +
                // gold trophy as the no-banner state — never the
                // shared broken-image error box, never blank.
                _HomeCoverImage(
                    imageUrl: img,
                    width: double.infinity,
                    height: double.infinity,
                    fit: BoxFit.cover,
                    iconSize: 56),
                Container(
                  // PHASE 2 REDESIGN (guide §7): readability scrim over
                  // the banner art — hBg token now, same 0.8 -> solid ramp.
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.transparent,
                          hBg.withValues(alpha: 0.8),
                          hBg
                        ]),
                  ),
                ),
                // HOME FIX 2 — animated light-yellow sheen sweep
                // (detail image 01b): gentle moving gold light
                // across the hero, clipped to the slanted shape.
                Positioned.fill(
                    child: IgnorePointer(
                        child: _HeroSheen(isActive: widget.isActive))),
                // FIX 6 (2026-11-21): same 2-line-title headroom as
                // _HeroSlide above (padding 36/14 -> 32/10, gaps
                // 6->4 / 10->8 = 12px; the Spacer absorbs the slack
                // on 1-line titles).
                // v2010: top padding 32->36 (clears the v2014 24
                // slant with room to spare) + bottom 10->8 +
                // title 28 + button
                // padding 8 + gaps 2/6, so the 2-line + pill stack
                // fits the 204 banner (test-verified). Right
                // padding 140 when a character cutout is set — the
                // cutout paints IN FRONT of the banner, and v2009's
                // "TEST HEADLINE" title ran under it and read cut
                // mid-letter. 140dp keeps the text out of the
                // cutout zone (~135 wide at the 216 box + 6 right
                // offset); the title wraps to 2 lines instead of
                // hiding under the soldier.
                Padding(
                  padding: EdgeInsets.fromLTRB(
                      16, 36, character.isNotEmpty ? 140 : 16, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (upcoming) _regOpenPill(),
                      const Spacer(),
                      _heroTitle(title, fontSize: 28),
                      if (target != null) ...[
                        const SizedBox(height: 2),
                        _heroMetaRow(
                            startMs: intVal(target['startTime']),
                            mode: strVal(target['mode'], 'Solo')),
                      ] else if (subtitle.isNotEmpty &&
                          !_isJunkText(subtitle)) ...[
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            const Icon(Icons.local_offer,
                                color: Colors.white, size: 14),
                            const SizedBox(width: 5),
                            Expanded(
                                child: Text(subtitle,
                                    style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 13,
                                        fontWeight: FontWeight.bold),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis)),
                          ],
                        ),
                      ],
                      const SizedBox(height: 6),
                      // F1 (2026-11-21 audit): no VIEW EVENT button on
                      // a 'none'-target slide — there is nowhere to go.
                      if (strVal(widget.slide['target_type'], 'tournament') !=
                          'none')
                        ElevatedButton(
                          onPressed: _openTarget,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: hGold,
                            foregroundColor: Colors.black,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 20, vertical: 8),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(24)),
                            elevation: 0,
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text('VIEW EVENT',
                                  style: TextStyle(
                                      fontWeight: FontWeight.w900,
                                      fontSize: 15)),
                              SizedBox(width: 4),
                              Icon(Icons.chevron_right, size: 20),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
                // HOME #37 FIX ROUND 2 — dots show even for a single
                // slide (staging has exactly 1 slider row, so the old
                // `dotCount > 1` guard hid them entirely).
                if (widget.dotCount >= 1)
                  Positioned(
                    right: 14,
                    bottom: 32,
                    child: Row(
                        children: List.generate(widget.dotCount,
                            (i) => _heroDot(i == widget.activeDot))),
                  ),
              ],
            ),
          ),
        ),
        const Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: _kHeroBannerHeight,
            child: CustomPaint(painter: _HeroOutlinePainter())),
        // FIX 20 REFINEMENT #3: TWO tapered corner lines (top-right
        // + bottom-left), NOT the old continuous travelling ring.
        Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: _kHeroBannerHeight,
            child: IgnorePointer(
                child: _HeroCornerLines(isActive: widget.isActive))),
        // FIX 20: the character cutout paints LAST (in front of the
        // banner and its border — it is a 3D pop-out, so it must
        // sit in front; the corner shine passes behind it). Taps
        // pass through to the slide's own tap handler.
        if (character.isNotEmpty)
          Positioned(
            right: 6,
            bottom: 0,
            height: _kHeroBoxHeight,
            child:
                IgnorePointer(child: _HeroCharacterCutout(imageUrl: character)),
          ),
      ],
    );
  }
}

/// FIX 20 (2026-11-21) — the 3D pop-out character cutout: a
/// transparent PNG rendered ~1.05x the banner (216 tall),
/// right-aligned, bottom-clipped at the banner's bottom edge, its
/// head ~12dp above the banner's top edge. The drop shadow follows
/// the cutout's own shape: a blurred black copy of the image,
/// offset down-right (a BoxShadow would shadow the bounding
/// RECTANGLE, not the character). A failed/slow load renders
/// nothing, never a placeholder — a trophy "character" would be
/// absurd, and the banner underneath still shows.
class _HeroCharacterCutout extends StatelessWidget {
  final String imageUrl;
  const _HeroCharacterCutout({required this.imageUrl});

  @override
  Widget build(BuildContext context) {
    // HOME FIX (2026-11-21, v2007 — user phone test): the cutout
    // used to render UNCLIPPED (Stack Clip.none) at full height
    // with BoxFit.contain — a wide opaque image set as the
    // character (the live slider row carries the same website
    // screenshot as banner AND character) bled past the hero's
    // rounded outline and covered the title/button beneath. The
    // cutout is now clipped to the hero's own corner radius
    // (_kHeroRadius, the same radius the gold border paints) and
    // capped at ~55% of the slide width (screen minus the 24dp
    // side margins): a real character PNG (typically <=160dp
    // wide) is never capped, while a wide rectangle can't span
    // the hero. The 12dp top pop-out is untouched — the clip is
    // the cutout's own box, not the banner's. Bottom alignment
    // keeps a capped image standing on the banner floor instead
    // of floating mid-box.
    return ClipRRect(
      borderRadius: BorderRadius.circular(_kHeroRadius),
      child: ConstrainedBox(
        constraints:
            BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.52),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            // Drop shadow: black silhouette of the cutout, blurred.
            Transform.translate(
              offset: const Offset(5, 7),
              child: ImageFiltered(
                imageFilter: ui.ImageFilter.blur(sigmaX: 6, sigmaY: 6),
                child: ColorFiltered(
                  colorFilter:
                      const ColorFilter.mode(Colors.black54, BlendMode.srcIn),
                  child: CachedNetworkImage(
                      imageUrl: imageUrl,
                      height: _kHeroBoxHeight,
                      fit: BoxFit.contain,
                      alignment: Alignment.bottomCenter,
                      errorWidget: (_, __, ___) => const SizedBox.shrink()),
                ),
              ),
            ),
            CachedNetworkImage(
                imageUrl: imageUrl,
                height: _kHeroBoxHeight,
                fit: BoxFit.contain,
                alignment: Alignment.bottomCenter,
                errorWidget: (_, __, ___) => const SizedBox.shrink()),
          ],
        ),
      ),
    );
  }
}

/// Wave 4 design-match (#37) — THE shared horizontal tournament card
/// (home_screens.dart, this file): cover LEFT (~110px, rounded),
/// content right — status pill (UPCOMING gold / LIVE red with dot),
/// title, date + mode row, REAL "N / MAX Players" + gold progress
/// bar, and Details (dark outline) + Join Event (gold filled) side
/// by side; LIVE cards show Watch (gold outline) instead of Join.
/// Covers come ONLY from tournaments.banner_url (ImgBB) or the
/// app's own neutral gold trophy cover (assets/images/
/// trophy_cover.jpg) full-bleed — never a black square, never a
/// mock photo. All numbers are real: joinedCount is players
/// (registrations x team size, counted by the caller), maxPlayers is
/// the tournament's real cap. Joined -> gold OUTLINE "Joined" with a
/// check (HOME #37 FIX: the old disabled GREEN button is gone —
/// mockup #37 has no green buttons). The date segment is HIDDEN
/// when the tournament has no start time (never "N/A").
/// TournamentsPage reuses THIS widget for its list (2026-11-20
/// migration — the populated list has no own mockup, so it follows
/// the Home card design per the inventory). Do not build a second
/// card. (The older vertical tournamentCard() above stays for Home
/// My Contests only.)
class _TournamentCard extends StatelessWidget {
  final Map<String, dynamic> tournament;
  final bool joined;
  final int joinedCount;
  const _TournamentCard(
      {required this.tournament, this.joined = false, this.joinedCount = 0});

  Future<void> _openDetail(BuildContext context) async {
    await Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => TournamentDetailPage(tournament: tournament)));
    SupaDb.bumpRefresh();
  }

  Future<void> _openJoin(BuildContext context) async {
    await Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => JoinTournamentPage(tournament: tournament)));
    SupaDb.bumpRefresh();
  }

  Future<void> _watch(BuildContext context) async {
    // FIX 6 (2026-11-22, free spectating — Sameer's rule): ANYONE
    // watches INSIDE the app when the stream is switched on —
    // joined players, non-joined players, admin. NO joined
    // requirement: spectating is free. Only when the in-app page
    // cannot open do we try the external YouTube URL, and when
    // there is no stream at all we say so honestly — NEVER a
    // silent Detail detour (the user tapped Watch, not Details;
    // Details stays reachable via its own button / card tap).
    if (watchLiveVisibleFor(tournament)) {
      await Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => WatchLiveScreen(
                    tournamentId: strVal(tournament['id']),
                    tournamentName: tName(tournament),
                    watchUrl: watchLiveUrlOf(tournament),
                  )));
      return;
    }
    final url = strVal(tournament['watchLiveUrl']);
    var launched = false;
    if (url.isNotEmpty) {
      final uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
        launched = true;
      }
    }
    // No stream URL set (or it failed to launch): honest note,
    // not a Detail page — the Detail page shows the same state
    // anyway (its Watch Live button is hidden without a URL).
    if (!launched && context.mounted) {
      toast(context, 'Live stream URL set nahi hai.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = tournament;
    final status = tStatus(t);
    final isLive = status == 'ongoing';
    final isUpcoming = status == 'upcoming';
    final maxP = intVal(t['maxPlayers'], 0);
    final isFull = maxP > 0 && joinedCount >= maxP;
    final img = tImage(t);
    final playersText =
        maxP > 0 ? '$joinedCount / $maxP Players' : '$joinedCount Players';
    // HOME #37 FIX — the date segment is HIDDEN when the tournament
    // has no start time (never "N/A", never invented); _shortDate
    // is the mockup's "Nov 23, 8:00 PM" format.
    final startMs = intVal(t['startTime']);
    // FIX 18 + REFINEMENT (2026-11-21, user order "mockup hubahu"):
    // the card is measured EXACT from mockup 1000048218_36_3m8b.png
    // (852x1846 px @2x = 426x923 dp) — the old card was ~180dp tall
    // (160 thumb + 10 padding) with loose gaps, which is why the
    // name floated far above the middle content. Geometry (dp):
    // height 142 (FIXED — the stack below sums to exactly 142);
    // thumb 123 wide, FULL card height (full-bleed left, rounded
    // only on the card's left corners); content padding top 7 /
    // left 14 (from the thumb) / right 14 / bottom 7; badge 20;
    // badge->title 3; title 20sp; title->meta 5; meta 14sp;
    // meta->players 5; players 13sp; players->progress 3;
    // progress 6; progress->buttons 7; buttons 32.
    // Texts use height: 1.0 so each line is exactly its font size
    // tall (7+20+3+20+5+14+5+13+3+6+7+32+7 = 142). The thumb
    // covers the card's left edge, so the bottom-left corner shine
    // hides behind it — the top-right shine + top/bottom edges
    // still animate (the thumb is full-bleed in the mockup).
    // S3 REDESIGN (Phase 2, guide §6 Screen 3): card hierarchy
    // (thumb, status pill, title, date/mode, players, progress,
    // actions) is unchanged — only radii/colours now read the
    // contract tokens (kRadiusCard/kRadiusChip/kGold, same values
    // as before). The exact-142 geometry above is NOT touched.
    return SizedBox(
      height: 142,
      child: _homeGlassCard(
        padding: EdgeInsets.zero,
        child: InkWell(
          onTap: () => _openDetail(context),
          borderRadius: BorderRadius.circular(kRadiusCard),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(kRadiusCard),
                    bottomLeft: Radius.circular(kRadiusCard)),
                child: SizedBox(
                  width: 123,
                  height: 142,
                  // HOME FIX 3 — cover via _HomeCoverImage: a real
                  // banner_url renders disk-cached; loading, error
                  // and no-banner all render the same flat dark +
                  // gold trophy fallback — never blank, never the
                  // shared broken-image error box.
                  child: _HomeCoverImage(
                      imageUrl: img,
                      width: 123,
                      height: 142,
                      fit: BoxFit.cover,
                      iconSize: 40),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 7, right: 14, bottom: 7),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // S3 OVERFLOW FIX (Phase 2, found by the S3
                      // render tests): the bare status pill
                      // overflowed by 3px at 320dp (the content
                      // column is only 137 wide there, and long
                      // statuses like COMPLETED are wider still).
                      // The pill now scales down inside a Flexible
                      // + FittedBox when it must, and renders at
                      // full size otherwise; spaceBetween keeps the
                      // chevron pinned right (the old Spacer's job).
                      // The 20dp badge row and the exact-142 card
                      // geometry are unchanged.
                      SizedBox(
                        height: 20,
                        child: Row(
                          mainAxisAlignment:
                              MainAxisAlignment.spaceBetween,
                          children: [
                            Flexible(
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: Alignment.centerLeft,
                                child: _statusPill(status,
                                    isLive: isLive,
                                    isUpcoming: isUpcoming),
                              ),
                            ),
                            const Icon(Icons.chevron_right,
                                color: hText2, size: 20),
                          ],
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(tName(t),
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 20,
                              height: 1.0,
                              fontWeight: FontWeight.bold),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 5),
                      Row(
                        children: [
                          if (startMs > 0) ...[
                            const Icon(Icons.calendar_today,
                                color: hText2, size: 13),
                            const SizedBox(width: 4),
                            Flexible(
                                child: Text(_shortDate(startMs),
                                    style: const TextStyle(
                                        color: hText2,
                                        fontSize: 14,
                                        height: 1.0),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis)),
                            const SizedBox(width: kSpace8),
                            // J-detail-fix1 (#37): mockup has a visible
                            // pipe between the date and the mode.
                            const Text('|',
                                style: TextStyle(
                                    color: hText2, fontSize: 14, height: 1.0)),
                            const SizedBox(width: kSpace8),
                          ],
                          const Icon(Icons.group, color: hText2, size: 13),
                          const SizedBox(width: 4),
                          // FIX 23 item 23: the card's purple border
                          // (1.5px/side) shrank the inner width — the
                          // bare mode Text overflowed by 1.5px at
                          // wide fonts. Flexible + ellipsis, same
                          // treatment as the date above it.
                          Flexible(
                              child: Text(strVal(t['mode'], 'Solo'),
                                  style: const TextStyle(
                                      color: hText2,
                                      fontSize: 14,
                                      height: 1.0),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis)),
                        ],
                      ),
                      const SizedBox(height: 5),
                      // FIX 6 (2026-11-21): maxLines 1 + ellipsis —
                      // the bare Text WRAPPED to 2 lines at a wide
                      // font / large text scale ('0 / 100 Players'
                      // measured 26px, not 13), overflowing the
                      // exact-142 card by 13px. One line, like the
                      // title and meta above it.
                      Text(playersText,
                          style: const TextStyle(
                              color: hText2, fontSize: 13, height: 1.0),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                      if (maxP > 0) ...[
                        const SizedBox(height: 3),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                              value: (joinedCount / maxP).clamp(0.0, 1.0),
                              minHeight: 6,
                              backgroundColor: hBorder,
                              valueColor:
                                  AlwaysStoppedAnimation<Color>(kGold)),
                        ),
                      ],
                      // FIX 23 item 23: the card's purple border
                      // (1.5px top + 1.5px bottom) eats 3px of the
                      // fixed 142px height — the column budget was
                      // exact at 128px, so this gap shrinks 7 -> 4
                      // to keep the card overflow-free at 142.
                      const SizedBox(height: 4),
                      SizedBox(
                        height: 32,
                        child: Row(
                          children: [
                            Expanded(
                              // PHASE 2 REDESIGN (§7): Details is the
                              // secondary OUTLINED action (gold border).
                              child: OutlinedButton(
                                onPressed: () => _openDetail(context),
                                style: OutlinedButton.styleFrom(
                                  side: BorderSide(color: kGold),
                                  backgroundColor: hCard,
                                  foregroundColor: kGold,
                                  minimumSize: const Size(0, 32),
                                  tapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                  padding: const EdgeInsets.symmetric(
                                      vertical: 0, horizontal: 4),
                                  shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(kRadiusChip)),
                                ),
                                child: const FittedBox(
                                    fit: BoxFit.scaleDown,
                                    child: Text('Details',
                                        style: TextStyle(
                                            fontWeight: FontWeight.bold,
                                            fontSize: 14))),
                              ),
                            ),
                            const SizedBox(width: kSpace8),
                            Expanded(
                                child: _primaryButton(context,
                                    isLive: isLive,
                                    isUpcoming: isUpcoming,
                                    isFull: isFull)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Status pill: LIVE red with dot, UPCOMING gold, anything else a
  /// grey pill with the real status text. FIX 18 (2026-11-21):
  /// exactly 20dp tall (mockup) — vertical padding 4 + 12sp text
  /// at height 1.0 = 4+12+4.
  Widget _statusPill(String status,
      {required bool isLive, required bool isUpcoming}) {
    if (isLive) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
            color: hLiveRed, borderRadius: BorderRadius.circular(20)),
        child: const Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.circle, color: Colors.white, size: 7),
          SizedBox(width: 5),
          Text('LIVE',
              style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                  height: 1.0,
                  letterSpacing: 0.5))
        ]),
      );
    }
    if (isUpcoming) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
            color: kGold, borderRadius: BorderRadius.circular(20)),
        child: const Text('UPCOMING',
            style: TextStyle(
                color: Color(0xFF0A0A0F),
                fontWeight: FontWeight.bold,
                fontSize: 12,
                height: 1.0,
                letterSpacing: 0.5)),
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
          color: hBorder, borderRadius: BorderRadius.circular(20)),
      child: Text(status.toUpperCase(),
          style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 12,
              height: 1.0,
              letterSpacing: 0.5)),
    );
  }

  /// Primary action per state (mockup #37 + Phase 2 §7): LIVE ->
  /// Watch (gold FILLED — the primary Watch action is yellow);
  /// joined -> GOLD OUTLINE "Joined" with a check (the old
  /// disabled GREEN button is gone — mockup #37 has no green
  /// buttons); upcoming + free slot -> Join Event (gold filled);
  /// full -> disabled "Full"; anything else -> disabled status label.
  Widget _primaryButton(BuildContext context,
      {required bool isLive, required bool isUpcoming, required bool isFull}) {
    if (isLive) {
      // PHASE 2 REDESIGN (§7): primary Watch action is YELLOW
      // (filled gold, black text) — the old gold-outline style is
      // gone. Tap behaviour unchanged (_watch).
      return ElevatedButton(
        onPressed: () => _watch(context),
        style: ElevatedButton.styleFrom(
          backgroundColor: kGold,
          foregroundColor: Colors.black,
          minimumSize: const Size(0, 32),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          padding: const EdgeInsets.symmetric(vertical: 0, horizontal: 4),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(kRadiusChip)),
          elevation: 0,
        ),
        child: const FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.play_arrow, size: 16),
            SizedBox(width: 4),
            Text('Watch',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14))
          ]),
        ),
      );
    }
    if (joined) {
      return OutlinedButton(
        onPressed: null,
        style: OutlinedButton.styleFrom(
          side: BorderSide(color: kGold, width: 1.5),
          backgroundColor: hCard,
          foregroundColor: kGold,
          disabledForegroundColor: kGold,
          minimumSize: const Size(0, 32),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          padding: const EdgeInsets.symmetric(vertical: 0, horizontal: 4),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(kRadiusChip)),
        ),
        child: const FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.check, size: 16),
            SizedBox(width: 4),
            Text('Joined',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14))
          ]),
        ),
      );
    }
    if (isUpcoming && !isFull) {
      return ElevatedButton(
        onPressed: () => _openJoin(context),
        style: ElevatedButton.styleFrom(
          backgroundColor: kGold,
          foregroundColor: Colors.black,
          minimumSize: const Size(0, 32),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          padding: const EdgeInsets.symmetric(vertical: 0, horizontal: 4),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(kRadiusChip)),
          elevation: 0,
        ),
        child: const FittedBox(
            fit: BoxFit.scaleDown,
            child: Text('Join Event',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14))),
      );
    }
    final label = isFull
        ? 'Full'
        : tStatus(tournament)[0].toUpperCase() +
            tStatus(tournament).substring(1);
    return ElevatedButton(
      onPressed: null,
      style: ElevatedButton.styleFrom(
        disabledBackgroundColor: hSecondary,
        disabledForegroundColor: hText2,
        minimumSize: const Size(0, 32),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: const EdgeInsets.symmetric(vertical: 0, horizontal: 4),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(kRadiusChip)),
        elevation: 0,
      ),
      child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(label,
              style:
                  const TextStyle(fontWeight: FontWeight.bold, fontSize: 14))),
    );
  }
}

/// HOME GOLD THEME (Phase 1 — ARENA HUB) — local copies of the gold
/// palette, so Home renders gold dark in BOTH light and dark modes
/// (same precedent as the room stage, which stays dark in both
/// modes). Home-only ON PURPOSE: the global k* constants in
/// theme.dart are the single source of truth for other screens;
/// these h* copies exist so Home's polish widgets keep their exact
/// shape contracts while the colours follow gold.
/// HOME #37 FIX (2026-11-19) — colours re-sampled from mockup
/// #37 with PIL (old values were close but the bg/card were too
/// neutral-black): bg #0A0D14, card #1B1D29, deeper #14161F,
/// border #2A2E3A. Gold #FDC903 already matched (mockup #FEC901).
/// REGISTRATION OPEN green is the mockup's medium green
/// (~#4AB557) and LIVE red is its bright pure red (#F6070D–
/// #FF0B1C) — both as separate constants below.
const Color hBg = Color(0xFF0A0D14);
const Color hSecondary = Color(0xFF14161F);
const Color hCard = Color(0xFF1B1D29);
const Color hBorder = Color(0xFF2A2E3A);
const Color hGoldDeep = Color(0xFFFDC903);
const Color hGoldBright = Color(0xFFFDC903);
const Color hGold = Color(0xFFFDC903);
const Color hGreen = Color(0xFF00F5A0);
const Color hText2 = Color(0xFFAAB0D0);
const Color hGreenPill = Color(0xFF4CAF50);
const Color hLiveRed = Color(0xFFFF0B1C);

/// Home-local glass card: a _DarkMockupCard (FIX 23 item 23
/// frosted-purple card — diagonal purple gradient + purple border
/// + purple glow). [borderColor] is kept for the call sites'
/// signatures but no longer paints a border.
Widget _homeGlassCard(
    {required Widget child,
    EdgeInsetsGeometry padding = const EdgeInsets.all(14),
    Color? borderColor}) {
  return _DarkMockupCard(padding: padding, radius: kRadiusCard, child: child);
}

/// DARK MOCKUP CARD (FIX 23 item 23) — the shared MockupCard's
/// look (diagonal purple gradient fill, semi-transparent frosted
/// glass over the background image + purple border + purple glow)
/// for the screens in this file that render dark in BOTH modes by
/// design — Home, Detail, Countdown, MatchDetails, MatchRoom,
/// MyMatches, Success — whose content uses fixed h*/white colours.
/// The shared MockupCard's light-mode fallback is a WHITE card,
/// which would render those screens' white text invisible if the
/// stored theme pref ever reads 'light' (main.dart honours the
/// pref at startup). Same frosted-purple look as theme.dart's
/// MockupCard — only the light fallback is dropped. The old
/// rotating gold shines + their painter are GONE (FIX 23 item 23
/// superseded them); no animation, no ticker.
class _DarkMockupCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  const _DarkMockupCard(
      {required this.child,
      this.padding = const EdgeInsets.all(16),
      this.radius = 22});

  @override
  Widget build(BuildContext context) {
    // Same layering as MockupCard: border + glow on the OUTER
    // container (unclipped), frosted fill inside the clip.
    return RepaintBoundary(
      child: Container(
        decoration: cardFrameDecoration(radius: radius),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(
                sigmaX: kCardBlurSigma, sigmaY: kCardBlurSigma),
            child: Container(
              padding: padding,
              decoration: cardFillDecoration(radius: radius),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}


/// Gold carousel dot: active = wide flat gold pill, inactive =
/// small muted dot.
Widget _homeDot(bool active) {
  return Container(
    margin: const EdgeInsets.symmetric(horizontal: 3),
    width: active ? 28 : 8,
    height: 8,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(4),
      color: active ? hGold : hText2.withValues(alpha: 0.5),
    ),
  );
}

/// FIX 20 REFINEMENT #2 (2026-11-21, user order — OVERRIDES the
/// parallelogram): the hero is NOT a parallelogram any more. The
/// BOTTOM edge is STRAIGHT/level (both sides the same level) and
/// the TOP edge is DIAGONAL (left low -> right high) — v2010
/// (user order 2026-11-21, voice call + screenshot: "left chhota,
/// right bada, tirchha 3D look"): slant rise 24dp, banner height
/// 180dp at the left, 204dp at the right — the left edge reads
/// clearly shorter than the right. v2014: 36 -> 24, measured from
/// the current Home mockup (1000048218_19_xjfa.png: the hero's top
/// edge drops ~21dp left-to-right); the 36 came from an older
/// mockup and left a 54dp black band above the slider. The
/// earlier "left width kam / taper" idea is superseded by this
/// geometry. Plus a slight 3D perspective lean (see
/// _heroTiltMatrix). The clipper, the outline painter AND the
/// corner-line painter share _heroSlantPath, so border, trim and
/// shines always follow the same outline. Content padding (top
/// 36) and the dots (bottom 32) are set so nothing is clipped by
/// the slanted top edge (36 clears the 24 slant with room).
const double _kHeroSlant = 24;
const double _kHeroRadius = 20;

/// FIX 20 (2026-11-21) — hero heights, measured from the mockup.
/// v2010 (user order: slider height thodi kam): the banner is
/// 204dp tall (right edge) and sits bottom-aligned in a 216dp
/// slide box; the top 12dp is the character pop-out zone (the
/// cutout rises ~12dp above the banner's top edge).
/// The character cutout is ~1.05x the banner (216 tall).
const double _kHeroBannerHeight = 204;
const double _kHeroBoxHeight = 216;

/// Shared slanted-hero outline: straight level bottom edge,
/// diagonal top edge (left low -> right high by _kHeroSlant),
/// vertical sides, rounded corners. Starts at the top-left corner
/// and winds clockwise. Used by the clipper, the outline painter
/// AND the corner-line painter.
Path _heroSlantPath(Size size) {
  final w = size.width;
  final h = size.height;
  final r = _kHeroRadius;
  final s = _kHeroSlant;
  return Path()
    ..moveTo(0, s + r)
    ..quadraticBezierTo(0, s, r, s * (1 - r / w))
    ..lineTo(w - r, s * r / w)
    ..quadraticBezierTo(w, 0, w, r)
    ..lineTo(w, h - r)
    ..quadraticBezierTo(w, h, w - r, h)
    ..lineTo(r, h)
    ..quadraticBezierTo(0, h, 0, h - r)
    ..close();
}

/// HOME FIX 4 — 3D perspective lean for the hero card (mockup
/// 01b: the card leans like a tilted 3D panel — right edge
/// slightly toward the viewer, top edge slightly away). Small
/// angles only, so the text stays readable and nothing distorts;
/// the ClipRect at the PageView (HOME FIX 3) bounds the tilted
/// card to the 216 box.
/// v2015 (user phone test 2026-11-22): the v2010 rotateY -0.06
/// is REMOVED — with perspective it pushed the card's LEFT edge
/// ~2dp past the box, and the ClipRect cut the left gold border
/// + glow (the right edge, pulled inward by the same tilt, kept
/// its border — so the left side read "kata hua"). The slanted
/// clip path (_heroSlantPath) already carries the mockup's 3D
/// look. rotateX stays: it moves nothing sideways except a
/// ~0.4dp perspective shift at the extreme corners (sub-pixel;
/// the 1dp border stroke is centred on the path, so nothing
/// visible is ever cut).
Matrix4 _heroTiltMatrix() => Matrix4.identity()
  ..setEntry(3, 2, 0.0012)
  ..rotateX(0.02);

class _SlantedHeroClipper extends CustomClipper<Path> {
  const _SlantedHeroClipper();
  @override
  Path getClip(Size size) => _heroSlantPath(size);

  @override
  bool shouldReclip(_SlantedHeroClipper old) => false;
}

/// Strokes the slanted hero outline + the diagonal gold trim line
/// along the slanted bottom edge (inset ~5px).
/// J-detail-fix1 (#37, mockup 01b): the border is a thin GOLD rim
/// with a slight glow (left + bottom edges read gold-tinted in the
/// mockup) — the old flat grey hBorder stroke is gone. A blurred
/// gold underlay gives the soft rim glow; the crisp gold stroke
/// sits on top.
class _HeroOutlinePainter extends CustomPainter {
  const _HeroOutlinePainter();
  @override
  void paint(Canvas canvas, Size size) {
    final path = _heroSlantPath(size);
    canvas.drawPath(
      path,
      Paint()
        ..color = hGold.withValues(alpha: 0.30)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
    );
    canvas.drawPath(
        path,
        Paint()
          ..color = hGold.withValues(alpha: 0.55)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1);
    // FIX 20 REFINEMENT #2: the trim follows the STRAIGHT bottom
    // edge now (inset ~5px above it) — the old diagonal trim
    // belonged to the parallelogram's slanted bottom.
    final trim = Path()
      ..moveTo(5, size.height - 5)
      ..lineTo(size.width - 5, size.height - 5);
    canvas.drawPath(
        trim,
        Paint()
          ..color = hGold
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..strokeCap = StrokeCap.round);
    // M-detail-fix2-A (2026-11-20): the top-right slash (HOME FIX 2)
    // and the two bottom-right slashes (HOME FIX 4) are REMOVED.
    // Mockup-crop check against 1000048218-dashboard.png: the
    // mockup's top-right corner is CLEAN (only the rounded gold
    // border) and its bottom-right has NO parallel slashes — the
    // diagonals there are baked into the cover ART (yellow slashes
    // on the photo's right edge) and the dark triangle the dots sit
    // on. The code slashes were invented strokes, and on the user's
    // phone — especially with the black no-banner fallback hero —
    // they read as stray gold lines floating in empty space (see
    // the 1000048937 screenshot: a long diagonal across the black
    // top-right corner, two more across the black bottom-right).
    // What stays: the gold rim + the bottom trim line, both of
    // which the mockup really shows.
  }

  @override
  bool shouldRepaint(covariant _HeroOutlinePainter old) => false;
}

/// HOME FIX 2 — animated light-yellow sheen sweeping through the
/// hero (user detail image 01b: light yellow accent colors sweep
/// diagonally across the slider, gentle and moving — "ghoomte hue").
/// One slow repeating sweep (4.5 s), very light gold (alpha <= 0.14),
/// clipped to the slanted hero shape by the parent ClipPath. The
/// animation lives in its own widget + RepaintBoundary so only the
/// hero repaints, and it never blocks input (IgnorePointer at the
/// call site). Only the ACTIVE slide animates (isActive) — off-screen
/// slides paint nothing, so the PageView costs almost nothing on
/// low-end phones.
class _HeroSheen extends StatefulWidget {
  final bool isActive;
  const _HeroSheen({this.isActive = true});
  @override
  State<_HeroSheen> createState() => _HeroSheenState();
}

class _HeroSheenState extends State<_HeroSheen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 4500));
    if (widget.isActive) _ctrl.repeat();
  }

  @override
  void didUpdateWidget(covariant _HeroSheen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive && !_ctrl.isAnimating) {
      _ctrl.repeat();
    } else if (!widget.isActive && _ctrl.isAnimating) {
      _ctrl.stop();
    }
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
            painter: _HeroSheenPainter(widget.isActive ? _ctrl.value : 0.0)),
      ),
    );
  }
}

/// Paints one diagonal light-yellow band + one thin gold slash,
/// travelling left -> right across the hero. Alpha stays low
/// (<= 0.14) so the sweep reads as a gentle sheen, not a flash.
class _HeroSheenPainter extends CustomPainter {
  final double t;
  const _HeroSheenPainter(this.t);

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
        ..shader = const LinearGradient(
          colors: [
            Color(0x00FDC903),
            Color(0x24FDC903),
            Color(0x00FDC903),
          ],
          stops: [0.0, 0.5, 1.0],
        ).createShader(bandRect),
    );
    // Thin gold slash travelling just behind the band.
    final sx = cx - 0.30 * w;
    canvas.drawLine(
      Offset(sx, -10),
      Offset(sx - 0.28 * w, h + 10),
      Paint()
        ..color = hGold.withValues(alpha: 0.20)
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(covariant _HeroSheenPainter old) => old.t != t;
}

/// HOME #37 FIX — in-hero slider dots (mockup #37): small 7dp
/// round dots, bottom-right INSIDE the hero; active = gold,
/// inactive = muted grey. (The wide-pill _homeDot stays for the
/// promos/ads carousels below the fold.)
Widget _heroDot(bool active) {
  return Container(
    margin: const EdgeInsets.only(left: 6),
    width: 7,
    height: 7,
    decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: active ? hGold : const Color(0xFF6B7280)),
  );
}

/// HOME #37 FIX — "REGISTRATION OPEN" as a GREEN OUTLINE pill
/// (mockup #37 / detail image 01b): dark-green tinted fill, 1.5px
/// green border, green text, green dot. Green is the mockup's
/// medium green (sampled ~#4AB557), NOT the mint hGreen.
Widget _regOpenPill() {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
        color: hGreenPill.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: hGreenPill, width: 1.5)),
    child: const Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.circle, color: hGreenPill, size: 7),
        SizedBox(width: 6),
        Text('REGISTRATION OPEN',
            style: TextStyle(
                color: hGreenPill,
                fontWeight: FontWeight.bold,
                fontSize: 11,
                letterSpacing: 0.5)),
      ],
    ),
  );
}

/// HOME #37 FIX — two-tone hero title (mockup #37): heavy italic
/// extra-bold, first words white, LAST word(s) gold. Mockups #37 /
/// #7 gold the last TWO words of a 3+ word name ("WEEKEND |
/// COMMUNITY CUP", "WEEKEND | DUO SHOWDOWN"); a 2-word name golds
/// only the last word. The name is the REAL tournament/slide title,
/// upper-cased; only the gold part takes the gold.
/// v2010: [fontSize] is 32 on the registration/detail headers
/// that share this helper; the two hero slides pass 28 so the
/// 2-line + pill stack fits the shorter 204 banner.
Widget _heroTitle(String name, {double fontSize = 32}) {
  final upper = name.toUpperCase();
  final words = upper.split(' ');
  final goldCount = words.length >= 3 ? 2 : 1;
  final goldWords = words.sublist(words.length - goldCount).join(' ');
  final rest = words.length > goldCount
      ? words.sublist(0, words.length - goldCount).join(' ')
      : '';
  return RichText(
    maxLines: 2,
    overflow: TextOverflow.ellipsis,
    text: TextSpan(
      style: TextStyle(
          color: Colors.white,
          fontSize: fontSize,
          fontWeight: FontWeight.w900,
          fontStyle: FontStyle.italic,
          height: 1.05),
      children: [
        if (rest.isNotEmpty) TextSpan(text: '$rest '),
        TextSpan(text: goldWords, style: const TextStyle(color: hGold)),
      ],
    ),
  );
}

/// HOME #37 FIX — hero meta date in the mockup's format:
/// "Sat, Nov 22 • 8:00 PM". Empty when there is no start time —
/// the caller omits the date segment instead of showing "N/A".
String _heroMetaDate(int ms) {
  if (ms <= 0) return '';
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  const wd = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const mo = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec'
  ];
  final hh = d.hour % 12 == 0 ? 12 : d.hour % 12;
  final mm = d.minute.toString().padLeft(2, '0');
  return '${wd[d.weekday - 1]}, ${mo[d.month - 1]} ${d.day} • $hh:$mm ${d.hour >= 12 ? 'PM' : 'AM'}';
}

/// HOME #37 FIX — hero meta row in the mockup's format:
/// "📅 Sat, Nov 22 • 8:00 PM | 👥 SQUAD". The date segment is
/// OMITTED when there is no start time (never "N/A", never
/// invented). The mockup hero shows NO fee — the fee lives on the
/// Detail page — so no fee segment is rendered here.
/// v2010: a subtitle with no letters or digits is junk test data
/// (staging's "????)") — showing it reads as a broken app, so the
/// subtitle row hides it. Latin + Urdu/Arabic letters count as real.
bool _isJunkText(String s) =>
    s.isNotEmpty && !RegExp(r'[A-Za-z0-9\u0600-\u06FF]').hasMatch(s);

Widget _heroMetaRow({required int startMs, required String mode}) {
  final date = _heroMetaDate(startMs);
  return Row(
    children: [
      if (date.isNotEmpty) ...[
        const Icon(Icons.calendar_today, color: Colors.white, size: 15),
        const SizedBox(width: 5),
        Flexible(
            child: Text(date,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.bold),
                maxLines: 1,
                overflow: TextOverflow.ellipsis)),
        const SizedBox(width: 10),
        const Text('|',
            style: TextStyle(
                color: Colors.white54,
                fontSize: 14,
                fontWeight: FontWeight.bold)),
        const SizedBox(width: 10),
      ],
      const Icon(Icons.group, color: Colors.white, size: 16),
      const SizedBox(width: 5),
      Text(mode.toUpperCase(),
          style: const TextStyle(
              color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold)),
    ],
  );
}

/// HOME #37 FIX ROUND 2 — _homeGlowBackground DELETED: the three
/// soft gold radial-glow blobs sat behind the whole Home scroll
/// content (behind the buttons) and the mockup has no such glows —
/// flat dark background. This was the "old gradient behind the
/// buttons" the user reported.

/// Dashboard polish (2026-11-01): consistent section header —
// Wave 4 design-match (#37): mockup style — gold vertical bar +
// italic bold title (the old gold text + underline bar is gone).
// 2026-11-20 USER CORRECTION (overrides the mockup's white):
// headings are LIGHT GOLDEN, not pure white — kSectionLabel
// (theme.dart, sampled from the Account Security mockup). Used by
// the Home TOURNAMENTS / Sponsored / My Contests headers; "Your
// Next Match" has its own header inside its card.
Widget _homeSectionHeader(String title, {Widget? action}) {
  return Row(
    mainAxisAlignment: MainAxisAlignment.spaceBetween,
    crossAxisAlignment: CrossAxisAlignment.center,
    children: [
      Expanded(
        child: Row(
          children: [
            Container(
                width: 4,
                height: 22,
                decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(2), color: hGold)),
            const SizedBox(width: kSpace8),
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(title,
                    style: const TextStyle(
                        color: kSectionLabel,
                        fontSize: 20,
                        fontWeight: FontWeight.w900,
                        fontStyle: FontStyle.italic)),
              ),
            ),
          ],
        ),
      ),
      if (action != null) action,
    ],
  );
}

/// HOME #37 FIX ROUND 2 — flat gold border for the "Your Next
/// Match" card. The old gradient ring (LinearGradient gold border +
/// glow shadow) is GONE: the mockup's card is flat with a thin gold
/// edge. Renamed from _homeGradientBorder (it has no gradient any
/// more).
/// 2026-11-20 USER CORRECTION (global card rule, "har jagah"): the
/// flat gold border is gone too — the card is a _DarkMockupCard now
/// (gradient fill + two orbiting yellow shines, no static border).
/// No padding here: the callers pad their own content.
Widget _homeGoldBorder({required Widget child, double radius = 18}) {
  return _DarkMockupCard(
      padding: EdgeInsets.zero, radius: radius, child: child);
}

/// J-detail-fix1 (2026-11-20) — shared detail helpers for this
/// file's screens. GLOW RULE (GLOW-DIRECTIVE + DETAIL-SPEC rule 1):
/// glow is added ONLY where the mockup visibly shows it; every glow
/// below cites its mockup evidence at the call site. Everything else
/// stays flat. Gold stays plan-locked #FDC903 (hGold).
List<BoxShadow> _goldGlow(
        {double blur = 18,
        double alpha = 0.35,
        double spread = 0,
        Offset offset = const Offset(0, 6)}) =>
    [
      BoxShadow(
          color: hGold.withValues(alpha: alpha),
          blurRadius: blur,
          spreadRadius: spread,
          offset: offset)
    ];

/// J-detail-fix1 — local gold PILL button (radius 28, black w900
/// 16). The shared GoldButton stays radius 12 — NEVER change it;
/// mockups that show a full pill build their own button here.
/// [glow] adds the soft gold shadow ONLY where the mockup shows
/// glow under the button (#08 SUBMIT FOR REVIEW, #23 CONFIRM
/// SQUAD, #29 CONFIRM REGISTRATION). [busy] shows a spinner and
/// disables; null [onPressed] = disabled (gold 0.45, like
/// GoldButton).
Widget _goldPillButton(
    {required String label,
    required VoidCallback? onPressed,
    bool glow = false,
    bool busy = false}) {
  final enabled = onPressed != null && !busy;
  return Container(
    width: double.infinity,
    decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        boxShadow: glow && enabled ? _goldGlow() : null),
    child: ElevatedButton(
      onPressed: busy ? null : onPressed,
      style: ElevatedButton.styleFrom(
        backgroundColor: hGold,
        foregroundColor: const Color(0xFF0A0A0F),
        disabledBackgroundColor: hGold.withValues(alpha: 0.45),
        disabledForegroundColor: const Color(0xFF0A0A0F),
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        elevation: 0,
      ),
      child: busy
          ? const SizedBox(
              height: 18,
              width: 18,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Color(0xFF0A0A0F)))
          : Text(label,
              style:
                  const TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
    ),
  );
}

/// J-detail-fix1 — wraps a radius-12 GoldButton with the soft gold
/// glow the mockup shows under it (#22 VIEW MATCH SUMMARY, #24
/// VIEW MY MATCHES). Shape unchanged — only the shadow is added.
Widget _glowGoldButton({required Widget child}) => Container(
      decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          boxShadow: _goldGlow(blur: 16, alpha: 0.32)),
      child: child,
    );

/// J-detail-fix1 — tiny gold crown vector (own art; Material has
/// no crown icon). Used where the mockup shows a crown: the Squad
/// leader avatar badge (#23) and above the 1st-place avatar (#22).
/// The app logo asset is NOT a crown — do not use it in this slot.
class _MiniCrown extends StatelessWidget {
  const _MiniCrown({this.size = 20, this.color = hGold});
  final double size;
  final Color color;
  @override
  Widget build(BuildContext context) => CustomPaint(
      size: Size(size, size * 0.82), painter: _MiniCrownPainter(color));
}

class _MiniCrownPainter extends CustomPainter {
  final Color color;
  const _MiniCrownPainter(this.color);
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final path = Path()
      ..moveTo(0, h * 0.18)
      ..lineTo(w * 0.22, h * 0.48)
      ..lineTo(w * 0.5, h * 0.06)
      ..lineTo(w * 0.78, h * 0.48)
      ..lineTo(w, h * 0.18)
      ..lineTo(w * 0.88, h)
      ..lineTo(w * 0.12, h)
      ..close();
    canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.fill);
    // Base band (darker, so the crown reads at 12px too).
    canvas.drawRect(Rect.fromLTWH(w * 0.12, h * 0.80, w * 0.76, h * 0.12),
        Paint()..color = Colors.black.withValues(alpha: 0.30));
  }

  @override
  bool shouldRepaint(covariant _MiniCrownPainter old) => old.color != color;
}

/// J-detail-fix1 (#37) — faint diagonal dark speed-line streaks
/// top-right behind the header (mockup 01_home_dashboard.png).
/// Very subtle light-grey slashes on black; static, no animation,
/// behind content, never blocking taps (IgnorePointer at the call
/// site).
class _DiagonalStreaks extends StatelessWidget {
  const _DiagonalStreaks();
  @override
  Widget build(BuildContext context) => const SizedBox(
      width: 220,
      height: 130,
      child: CustomPaint(painter: _DiagonalStreaksPainter()));
}

class _DiagonalStreaksPainter extends CustomPainter {
  const _DiagonalStreaksPainter();
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.06)
      ..strokeWidth = 10
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(size.width * 0.55, -10),
        Offset(size.width * 0.95, size.height * 0.75), paint);
    canvas.drawLine(Offset(size.width * 0.78, -10),
        Offset(size.width + 10, size.height * 0.45), paint);
    canvas.drawLine(
      Offset(size.width * 0.32, 0),
      Offset(size.width * 0.68, size.height * 0.60),
      Paint()
        ..color = Colors.white.withValues(alpha: 0.04)
        ..strokeWidth = 6
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(covariant _DiagonalStreaksPainter old) => false;
}

/// FIX 5 (2026-11-20): comet length and loop time. The old 90px
/// comet covered only ~8% of the ~1076px hero perimeter, so on the
/// phone it read as a small spark that vanished around corners
/// even though the head already swept the full border. 150px
/// (~14%) + a brighter head makes the full round clearly
/// followable; 5 s keeps the speed readable (~215 px/s).
// FIX 20 REFINEMENT #3 (2026-11-21): the continuous runner is
// gone — the old _kRunnerSegLen (150px comet) / _kRunnerLoop (5 s)
// constants died with it. The corner lines use a 160dp ribbon on
// a 3.5 s loop (see _HeroCornerLinesPainter).

/// Test hook (FIX 5): the runner segment [start, head] arc offsets
/// for animation value [t] on a path of [total] length with a comet
/// of [segLen]. The head advances monotonically with t (one full
/// perimeter per loop) and the segment always spans exactly
/// segLen — no invisible gaps, no partial-edge-only run. (FIX 20:
/// the continuous runner widget is gone, but this pure segment
/// math is kept — the tests pin it, and the corner-line painter
/// walks the same outline.)
@visibleForTesting
({double start, double head}) heroRunnerSegment(
    double total, double t, double segLen) {
  final head = (t * total) % total;
  final start = (head - segLen + total) % total;
  return (start: start, head: head);
}

/// Test hook (FIX 5, kept for FIX 20): the position on the
/// slanted hero border for animation value [t] in [0, 1) and hero
/// [size] — the point a light travelling the outline clockwise
/// would sit at. Null when the path has no metrics. The
/// continuous runner is gone (Fix 20 refinement #3), but the
/// corner-line painter walks this same path, so the hook still
/// pins the outline geometry.
/// M-detail-fix2-A: Path.computeMetrics() is SINGLE-USE — the first
/// isEmpty/first call consumes the only metric, so the old
/// `if (metrics.isEmpty) return null; metrics.first` threw
/// "Bad state: No element" on EVERY call (proven in a scratch probe:
/// isEmpty false, then true, then first throws). Take the first
/// metric in ONE iteration and never touch the iterable again.
@visibleForTesting
Offset? heroRunnerHeadPosition(Size size, double t) {
  ui.PathMetric? metric;
  for (final m in _heroSlantPath(size).computeMetrics()) {
    metric = m;
    break;
  }
  if (metric == null) return null;
  final total = metric.length;
  if (total <= 0) return null;
  final head = (t * total) % total;
  return metric.getTangentForOffset(head)?.position;
}

/// FIX 20 REFINEMENT #3 (2026-11-21, user order): the hero's
/// border light is NO LONGER one line travelling continuously
/// around the whole border (the old _HeroBorderRunner comet is
/// gone). Like every other card in the app, the hero now carries
/// TWO corner lines — top-RIGHT + bottom-LEFT — yellow, fading
/// in/out, rotating like clock hands on a 3.5 s loop. The banner
/// difference: each line starts THICK at its corner and tapers
/// THIN as it fades out (the 3D look). Each shine is ONE filled
/// tapered ribbon (a single path, one draw call, gradient shader
/// for the alpha fade) — never segmented strokes (dotted risk)
/// and never circles. Active slide only. Per-frame cost is two
/// ribbons (32 samples each) + two halos, inside a
/// RepaintBoundary, never blocking taps (IgnorePointer at the
/// call site). Sits OUTSIDE the ClipPath, next to
/// _HeroOutlinePainter, so it draws on the border itself — not
/// the hero face (that is _HeroSheen).
class _HeroCornerLines extends StatefulWidget {
  final bool isActive;
  const _HeroCornerLines({this.isActive = true});
  @override
  State<_HeroCornerLines> createState() => _HeroCornerLinesState();
}

class _HeroCornerLinesState extends State<_HeroCornerLines>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 3500));
    if (widget.isActive) _ctrl.repeat();
  }

  @override
  void didUpdateWidget(covariant _HeroCornerLines oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive && !_ctrl.isAnimating) {
      _ctrl.repeat();
    } else if (!widget.isActive && _ctrl.isAnimating) {
      _ctrl.stop();
    }
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
            painter:
                _HeroCornerLinesPainter(widget.isActive ? _ctrl.value : null)),
      ),
    );
  }
}

class _HeroCornerLinesPainter extends CustomPainter {
  final double? t;
  const _HeroCornerLinesPainter(this.t);

  @override
  void paint(Canvas canvas, Size size) {
    // Inactive slides pass null and paint nothing. A real t of 0.0
    // paints the shines at their rest corners (top-right +
    // bottom-left) — the old runner's `t == 0.0` early return
    // blanked one frame at every loop wrap, so the light blinked
    // out once per round; no such early return here.
    final tt = t;
    if (tt == null) return;
    // computeMetrics() is single-use (see heroRunnerHeadPosition)
    // — take the metric in one iteration only.
    ui.PathMetric? metric;
    for (final m in _heroSlantPath(size).computeMetrics()) {
      metric = m;
      break;
    }
    if (metric == null) return;
    final total = metric.length;
    if (total <= 0) return;
    // Corner centres along the path (analytic, from the segment
    // lengths — the path starts at the top-left corner and winds
    // clockwise: corner, diagonal top edge, corner, right edge,
    // corner, bottom edge, corner, left edge). A corner curve is
    // ~a quarter circle of radius r.
    final w = size.width;
    final h = size.height;
    final r = _kHeroRadius;
    final slant = _kHeroSlant;
    final corner = math.pi * r / 2;
    final topEdge = math
        .sqrt(math.pow(w - 2 * r, 2) + math.pow(slant * (1 - 2 * r / w), 2));
    final rightEdge = h - 2 * r;
    final bottomEdge = w - 2 * r;
    final trCenter = corner + topEdge + corner / 2;
    final blCenter =
        trCenter + corner / 2 + rightEdge + corner + bottomEdge + corner / 2;
    // Each shine is ~160dp long (clamped to a quarter of the
    // outline on narrow screens), rotating clockwise with t.
    final segLen = math.min(160.0, total * 0.25);
    for (final base in [trCenter + tt * total, blCenter + tt * total]) {
      _paintTaperedShine(canvas, metric, total, base % total, segLen);
    }
  }

  /// One tapered shine: a FILLED ribbon (single path, one draw
  /// call) centred on [center], THICK at the centre (the corner)
  /// and tapering to a point at both tails, with a gradient alpha
  /// fade along its length. A soft wider halo ribbon underneath
  /// gives the glow. No strokes, no dashes, no dots, no circles.
  void _paintTaperedShine(Canvas canvas, ui.PathMetric metric, double total,
      double center, double segLen) {
    const samples = 32;
    const maxWidth = 5.0;
    // Sample the segment: centre points + normals + the width
    // profile (0 at both tails, max at the centre).
    final centers = <Offset>[];
    final normals = <Offset>[];
    final halfWidths = <double>[];
    Offset? startPos;
    Offset? endPos;
    for (var k = 0; k <= samples; k++) {
      final u = k / samples;
      final off = (center - segLen / 2 + u * segLen) % total;
      final tangent = metric.getTangentForOffset(off);
      if (tangent == null) return;
      if (k == 0) startPos = tangent.position;
      if (k == samples) endPos = tangent.position;
      final shape = math.pow(math.sin(math.pi * u), 0.7).toDouble();
      centers.add(tangent.position);
      normals.add(Offset(-tangent.vector.dy, tangent.vector.dx));
      halfWidths.add(maxWidth * shape / 2);
    }
    if (centers.length < 2 || startPos == null || endPos == null) return;
    Path buildRibbon(double scale) {
      final path = Path();
      for (var k = 0; k < centers.length; k++) {
        final p = centers[k] + normals[k] * (halfWidths[k] * scale);
        if (k == 0) {
          path.moveTo(p.dx, p.dy);
        } else {
          path.lineTo(p.dx, p.dy);
        }
      }
      for (var k = centers.length - 1; k >= 0; k--) {
        final p = centers[k] - normals[k] * (halfWidths[k] * scale);
        path.lineTo(p.dx, p.dy);
      }
      path.close();
      return path;
    }

    // Soft halo (wider, faint, no hard edge — it tapers to points
    // like the core).
    canvas.drawPath(
      buildRibbon(2.0),
      Paint()
        ..color = hGold.withValues(alpha: 0.18)
        ..isAntiAlias = true,
    );
    // Core ribbon with a gradient alpha fade along its own chord
    // (start -> end point), so the fade follows the line even
    // around corners — the same smooth-shader technique as the
    // MockupCard shines (Fix 2 refinement: no steps, no dashes).
    final ribbonPath = buildRibbon(1.0);
    final bounds = ribbonPath.getBounds().inflate(2);
    Alignment align(Offset p) {
      final x = bounds.width < 0.5
          ? 0.0
          : ((p.dx - bounds.left) / bounds.width) * 2 - 1;
      final y = bounds.height < 0.5
          ? 0.0
          : ((p.dy - bounds.top) / bounds.height) * 2 - 1;
      return Alignment(x.clamp(-1.0, 1.0), y.clamp(-1.0, 1.0));
    }

    canvas.drawPath(
      ribbonPath,
      Paint()
        ..isAntiAlias = true
        ..shader = LinearGradient(
          begin: align(startPos),
          end: align(endPos),
          colors: [
            hGold.withValues(alpha: 0),
            hGold,
            hGold,
            hGold.withValues(alpha: 0),
          ],
          stops: const [0.0, 0.18, 0.82, 1.0],
        ).createShader(bounds),
    );
  }

  @override
  bool shouldRepaint(covariant _HeroCornerLinesPainter old) => old.t != t;
}

/// 5-point star path for the line-art painters below.
Path _starPath(double cx, double cy, double rOuter, double rInner) {
  final path = Path();
  for (var i = 0; i < 10; i++) {
    final r = i.isEven ? rOuter : rInner;
    final a = -math.pi / 2 + i * math.pi / 5;
    final x = cx + r * math.cos(a);
    final y = cy + r * math.sin(a);
    if (i == 0) {
      path.moveTo(x, y);
    } else {
      path.lineTo(x, y);
    }
  }
  path.close();
  return path;
}

/// J-detail-fix1 (#7) — gold TROPHY + GAMEPAD in thin gold OUTLINE
/// line-art (mockup 08_tournaments_empty.jpg): cup with two
/// handles, a 5-point star on the cup, a stepped pedestal base,
/// and a tilted gamepad overlapping the bottom-right. Drawn twice
/// — a blurred gold underlay (the art itself glows in the mockup)
/// plus the crisp 2.5px outline. Own vector art, no asset.
class _EmptyTrophyPainter extends CustomPainter {
  const _EmptyTrophyPainter();
  @override
  void paint(Canvas canvas, Size size) {
    final glowPaint = Paint()
      ..color = hGold.withValues(alpha: 0.45)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5);
    final paint = Paint()
      ..color = hGold
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    void drawPaths(List<Path> paths) {
      for (final p in paths) {
        canvas.drawPath(p, glowPaint);
      }
      for (final p in paths) {
        canvas.drawPath(p, paint);
      }
    }

    // Trophy: rim, body, handles, star, stem, stepped pedestal.
    final trophy = <Path>[
      // Rim (rounded rect).
      Path()
        ..addRRect(RRect.fromRectAndRadius(
            const Rect.fromLTWH(95, 28, 90, 16), const Radius.circular(6))),
      // Cup body.
      Path()
        ..moveTo(98, 44)
        ..cubicTo(100, 95, 110, 122, 128, 128)
        ..lineTo(152, 128)
        ..cubicTo(170, 122, 180, 95, 182, 44),
      // Left + right handles.
      Path()
        ..moveTo(98, 56)
        ..cubicTo(70, 60, 68, 92, 102, 102),
      Path()
        ..moveTo(182, 56)
        ..cubicTo(210, 60, 212, 92, 178, 102),
      // Star on the cup.
      _starPath(140, 84, 16, 7),
      // Stem.
      Path()
        ..moveTo(132, 128)
        ..lineTo(132, 152)
        ..lineTo(148, 152)
        ..lineTo(148, 128),
      // Pedestal steps.
      Path()
        ..addRRect(RRect.fromRectAndRadius(
            const Rect.fromLTWH(118, 152, 44, 14), const Radius.circular(3))),
      Path()
        ..addRRect(RRect.fromRectAndRadius(
            const Rect.fromLTWH(108, 166, 64, 16), const Radius.circular(3))),
    ];
    drawPaths(trophy);

    // Gamepad: tilted rounded body + D-pad + 4 buttons + sticks.
    canvas.save();
    canvas.translate(192, 196);
    canvas.rotate(-0.32);
    final pad = <Path>[
      Path()
        ..addRRect(RRect.fromRectAndRadius(
            const Rect.fromLTWH(-52, -28, 104, 56), const Radius.circular(18))),
      // D-pad (plus).
      Path()
        ..addRRect(RRect.fromRectAndRadius(
            const Rect.fromLTWH(-36, -8, 16, 5), const Radius.circular(2))),
      Path()
        ..addRRect(RRect.fromRectAndRadius(
            const Rect.fromLTWH(-30, -14, 5, 17), const Radius.circular(2))),
      // 4 buttons.
      Path()..addOval(const Rect.fromLTWH(22, -14, 9, 9)),
      Path()..addOval(const Rect.fromLTWH(33, -3, 9, 9)),
      Path()..addOval(const Rect.fromLTWH(22, 8, 9, 9)),
      Path()..addOval(const Rect.fromLTWH(11, -3, 9, 9)),
      // Sticks.
      Path()..addOval(const Rect.fromLTWH(-12, 8, 11, 11)),
      Path()..addOval(const Rect.fromLTWH(4, 12, 11, 11)),
    ];
    drawPaths(pad);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _EmptyTrophyPainter old) => false;
}

/// J-detail-fix1 (#24) — gold shield OUTLINE with a bold gold check
/// (mockup 25_registration_success.jpg). The old solid filled
/// shield icon is gone; the mockup's shield is an outline (~8px
/// stroke). P-D2: the laurel wreath is drawn by _LaurelWreath
/// (below) — the two flat gold rings stay behind it as well.
class _SuccessShield extends StatelessWidget {
  const _SuccessShield({this.size = 150});
  final double size;
  @override
  Widget build(BuildContext context) => CustomPaint(
      size: Size(size, size), painter: const _SuccessShieldPainter());
}

class _SuccessShieldPainter extends CustomPainter {
  const _SuccessShieldPainter();
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final shield = Path()
      ..moveTo(w * 0.10, h * 0.24)
      ..quadraticBezierTo(w * 0.5, h * 0.10, w * 0.90, h * 0.24)
      ..lineTo(w * 0.90, h * 0.52)
      ..quadraticBezierTo(w * 0.90, h * 0.78, w * 0.5, h * 0.94)
      ..quadraticBezierTo(w * 0.10, h * 0.78, w * 0.10, h * 0.52)
      ..close();
    canvas.drawPath(
      shield,
      Paint()
        ..color = hGold
        ..style = PaintingStyle.stroke
        ..strokeWidth = 8
        ..strokeJoin = StrokeJoin.round,
    );
    final check = Path()
      ..moveTo(w * 0.30, h * 0.52)
      ..lineTo(w * 0.45, h * 0.67)
      ..lineTo(w * 0.72, h * 0.36);
    canvas.drawPath(
      check,
      Paint()
        ..color = hGold
        ..style = PaintingStyle.stroke
        ..strokeWidth = 10
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(covariant _SuccessShieldPainter old) => false;
}

/// P-D2 (#24) — gold laurel wreath wrapping the shield's lower
/// sides (mockup 25_registration_success.jpg: two curved leaf
/// branches meeting at the bottom centre). Drawn with a painter —
/// no laurel asset exists. Static, painted once; sits in the
/// shield Stack below the shield, above the flat rings.
class _LaurelWreath extends StatelessWidget {
  const _LaurelWreath();
  @override
  Widget build(BuildContext context) =>
      const CustomPaint(size: Size(200, 120), painter: _LaurelWreathPainter());
}

class _LaurelWreathPainter extends CustomPainter {
  const _LaurelWreathPainter();
  @override
  void paint(Canvas canvas, Size size) {
    final leafPaint = Paint()
      ..color = hGold
      ..style = PaintingStyle.fill;
    final stemPaint = Paint()
      ..color = hGold.withValues(alpha: 0.75)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    Offset q(Offset p0, Offset c, Offset p1, double t) {
      final u = 1 - t;
      return Offset(u * u * p0.dx + 2 * u * t * c.dx + t * t * p1.dx,
          u * u * p0.dy + 2 * u * t * c.dy + t * t * p1.dy);
    }

    Offset qTan(Offset p0, Offset c, Offset p1, double t) {
      return Offset(2 * (1 - t) * (c.dx - p0.dx) + 2 * t * (p1.dx - c.dx),
          2 * (1 - t) * (c.dy - p0.dy) + 2 * t * (p1.dy - c.dy));
    }

    void branch(Offset p0, Offset c, Offset p1) {
      final stem = Path()
        ..moveTo(p0.dx, p0.dy)
        ..quadraticBezierTo(c.dx, c.dy, p1.dx, p1.dy);
      canvas.drawPath(stem, stemPaint);
      // 8 leaves per branch, alternating sides of the stem, angled
      // outward along it — the classic laurel look.
      for (var i = 0; i < 8; i++) {
        final t = 0.06 + i * 0.125;
        final pt = q(p0, c, p1, t);
        final tan = qTan(p0, c, p1, t);
        final len = math.sqrt(tan.dx * tan.dx + tan.dy * tan.dy);
        if (len == 0) continue;
        final normal = Offset(-tan.dy / len, tan.dx / len);
        final side = i.isEven ? 1.0 : -1.0;
        final center = pt + normal * (5 * side);
        final angle = math.atan2(tan.dy, tan.dx) + side * 0.55;
        canvas.save();
        canvas.translate(center.dx, center.dy);
        canvas.rotate(angle);
        canvas.drawOval(
            Rect.fromCenter(center: Offset.zero, width: 13, height: 5),
            leafPaint);
        canvas.restore();
      }
    }

    // Left branch sweeps from the shield's mid-left down to the
    // bottom centre; right branch mirrors it.
    branch(const Offset(54, 4), const Offset(6, 58), const Offset(100, 112));
    branch(const Offset(146, 4), const Offset(194, 58), const Offset(100, 112));
    // Tie where the branches meet.
    canvas.drawCircle(const Offset(100, 112), 4, leafPaint);
  }

  @override
  bool shouldRepaint(covariant _LaurelWreathPainter old) => false;
}

/// J-detail-fix1 (#24) — static full-screen confetti (mockup
/// 25_registration_success.jpg: gold/white rectangles, dots and
/// 4-point stars scattered across the WHOLE screen, not confined
/// to the shield box). Fixed fractional positions, drawn once —
/// no animation, no per-frame cost, behind content (IgnorePointer
/// at the call site).
class _FullScreenConfetti extends StatelessWidget {
  const _FullScreenConfetti();
  @override
  Widget build(BuildContext context) => const CustomPaint(
      size: Size.infinite, painter: _FullScreenConfettiPainter());
}

class _FullScreenConfettiPainter extends CustomPainter {
  const _FullScreenConfettiPainter();
  // xFrac, yFrac, size, angle, kind (0 = rect, 1 = dot, 2 = star), gold?
  static const _pieces = <List<double>>[
    [0.06, 0.08, 9, 0.5, 0, 1],
    [0.16, 0.22, 6, 0.0, 1, 1],
    [0.88, 0.10, 8, -0.7, 0, 0],
    [0.94, 0.30, 5, 0.0, 1, 1],
    [0.04, 0.42, 7, 1.1, 0, 1],
    [0.92, 0.48, 10, 0.3, 2, 1],
    [0.10, 0.62, 5, 0.0, 1, 0],
    [0.86, 0.66, 7, -0.4, 0, 1],
    [0.20, 0.78, 9, 0.9, 0, 0],
    [0.78, 0.82, 6, 0.0, 1, 1],
    [0.50, 0.05, 6, 0.6, 0, 1],
    [0.34, 0.14, 10, 0.0, 2, 1],
    [0.66, 0.18, 5, 0.0, 1, 0],
    [0.28, 0.34, 6, -0.9, 0, 1],
    [0.72, 0.38, 8, 0.4, 2, 0],
    [0.44, 0.90, 7, 0.2, 0, 1],
    [0.60, 0.94, 5, 0.0, 1, 0],
    [0.08, 0.88, 10, 0.0, 2, 1],
    [0.95, 0.86, 6, -0.6, 0, 0],
    [0.58, 0.72, 6, 0.0, 1, 1],
  ];
  @override
  void paint(Canvas canvas, Size size) {
    for (final p in _pieces) {
      final x = p[0] * size.width;
      final y = p[1] * size.height;
      final s = p[2];
      final color = p[5] == 1 ? hGold : Colors.white;
      final kind = p[4].toInt();
      if (kind == 1) {
        canvas.drawCircle(Offset(x, y), s / 2,
            Paint()..color = color.withValues(alpha: 0.85));
      } else if (kind == 2) {
        canvas.drawPath(_starPath(x, y, s, s * 0.45),
            Paint()..color = color.withValues(alpha: 0.85));
      } else {
        canvas.save();
        canvas.translate(x, y);
        canvas.rotate(p[3]);
        canvas.drawRect(
            Rect.fromCenter(center: Offset.zero, width: s * 0.7, height: s),
            Paint()..color = color.withValues(alpha: 0.85));
        canvas.restore();
      }
    }
  }

  @override
  bool shouldRepaint(covariant _FullScreenConfettiPainter old) => false;
}

/// J-detail-fix1 (#24) — two thin diagonal gold slashes across the
/// summary thumb (mockup 25: the thumb carries a gold diagonal
/// lightning/slash overlay). Static, painted once.
class _ThumbSlashPainter extends CustomPainter {
  const _ThumbSlashPainter();
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = hGold.withValues(alpha: 0.85)
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(size.width * 0.08, size.height * 0.92),
        Offset(size.width * 0.72, size.height * 0.08), paint);
    canvas.drawLine(Offset(size.width * 0.28, size.height),
        Offset(size.width * 0.92, size.height * 0.16), paint);
  }

  @override
  bool shouldRepaint(covariant _ThumbSlashPainter old) => false;
}

/// Wave B design-match — shared mockup helpers (screens #7, #26, #28,
/// #6, #23, #29, #14, #1, #24). All values come from the real
/// tournament / registration rows; nothing here invents data.

/// Mockup-style short date: "Nov 23, 8:00 PM". "Time TBA" when the
/// tournament has no start time — never a guessed time.
String _shortDate(int ms) {
  if (ms <= 0) return 'Time TBA';
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec'
  ];
  final hh = d.hour % 12 == 0 ? 12 : d.hour % 12;
  final mm = d.minute.toString().padLeft(2, '0');
  return '${months[d.month - 1]} ${d.day}, $hh:$mm ${d.hour >= 12 ? 'PM' : 'AM'}';
}

/// Time-only twin of [_shortDate]: "8:00 PM".
String _timeOnly(int ms) {
  if (ms <= 0) return 'TBA';
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  final hh = d.hour % 12 == 0 ? 12 : d.hour % 12;
  final mm = d.minute.toString().padLeft(2, '0');
  return '$hh:$mm ${d.hour >= 12 ? 'PM' : 'AM'}';
}

/// Lobby opens 10 min before start — the SAME rule `roomVisibleFor`
/// gates room credentials on, so the schedule time and the lock
/// always agree (mockup #1: room opens 08:50 PM for a 09:00 PM
/// start). 0 when there is no start time.
int _lobbyOpensMs(int startMs) => startMs <= 0 ? 0 : startMs - 10 * 60 * 1000;

/// F21 (Batch 3B, 2026-11-22): the DISPLAY twin of `roomVisibleFor`'s
/// computed open time — the admin-set `lobby_opens_at` wins when
/// present, otherwise start−10min (same fallback, same rule, one
/// definition). Every lobby-time display must use this, never the
/// bare [_lobbyOpensMs] — the three sites that hard-coded start−10min
/// showed a different time than the lock the moment an admin set a
/// lobby time. 0 when there is no start time and no lobby time.
int lobbyOpensMsFor(Map<String, dynamic> t) {
  final lobbyMs = SupaDb.parseTs(t['lobbyOpensAt'] ?? t['lobby_opens_at']);
  if (lobbyMs > 0) return lobbyMs;
  return _lobbyOpensMs(intVal(t['startTime']));
}

/// Mockup date WITH weekday (banners #6/#23): "Sat, Nov 22 • 8:00 PM".
/// [_shortDate] stays the plain form used everywhere else.
String _shortDateWeekday(int ms) {
  if (ms <= 0) return 'Time TBA';
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  return '${weekdays[d.weekday - 1]}, ${_shortDate(ms).replaceFirst(', ', ' • ')}';
}

/// Mockup hero title: first word gold, the rest white, big italic.
/// The words are the REAL tournament name, only typeset.
/// P2 (2026-11-21): the mockups disagree per screen — #1 wants
/// SQUAD gold + SHOWDOWN white (goldFirst: true, the default),
/// #6/#23 want WEEKEND white + DUO/SQUAD SHOWDOWN gold
/// (goldFirst: false). One helper cannot match both without the
/// per-call flag, so each call site picks its own mockup's side.
Widget _twoToneTitle(String name,
    {double fontSize = 34, TextAlign align = TextAlign.left, bool goldFirst = true}) {
  final words = name.trim().split(RegExp(r'\s+'));
  final first = words.isEmpty ? '' : words.first;
  final rest = words.length > 1 ? ' ${words.sublist(1).join(' ')}' : '';
  return RichText(
    textAlign: align,
    text: TextSpan(
      style: TextStyle(
          color: Colors.white,
          fontSize: fontSize,
          fontWeight: FontWeight.w900,
          fontStyle: FontStyle.italic,
          height: 1.05),
      children: [
        TextSpan(
            text: first,
            style: TextStyle(color: goldFirst ? hGold : Colors.white)),
        TextSpan(
            text: rest,
            style: TextStyle(color: goldFirst ? Colors.white : hGold)),
      ],
    ),
  );
}

/// HOME FIX 3 — graceful cover image (user's 00:12 screenshot:
/// a dead/slow banner rendered the shared broken-image error box
/// over the header, and the Pro Tour card's cover rendered as a
/// blank dark slot). This widget NEVER shows a broken-image icon
/// or error text: loading shows the same flat dark + gold trophy
/// as the load-failure state, a dead URL / timeout shows it too,
/// and an empty URL shows it immediately with no network attempt
/// — the slot is always a flat dark cover with the gold trophy
/// motif, never blank, never an error box. Disk-cached via
/// CachedNetworkImage (same flutter_cache_manager cache as the
/// old shared widget), so slow net never re-downloads. Width and
/// height are ALWAYS explicit and finite at the call sites, so
/// the slot can never collapse to zero or overflow its parent.
/// No glow: flat colour only, no BoxShadow, no gradients.
class _HomeCoverImage extends StatelessWidget {
  const _HomeCoverImage({
    required this.imageUrl,
    required this.width,
    required this.height,
    this.fit = BoxFit.cover,
    this.iconSize = 48,
    this.borderRadius,
  });

  final String imageUrl;
  final double width;
  final double height;
  final BoxFit fit;
  final double iconSize;
  final BorderRadius? borderRadius;

  /// HOME FIX (2026-11-20, user phone test): the fallback is the
  /// BUNDLED trophy_cover.jpg asset rendered FULL-BLEED — never a
  /// flat dark box with a small icon. The old fallback (flat hBg
  /// + centred trophy icon) read as a BLACK/EMPTY slot on the
  /// user's phone whenever the network image was slow (user's net
  /// ~7 KB/s: the LIVE card's 203 KB proxied banner takes ~30 s),
  /// dead (production slider image 404s on ImgBB) or absent
  /// (banner_url NULL on 2 of 3 production tournaments). A bundled
  /// asset shows instantly with no network; CachedNetworkImage
  /// swaps in the real banner the moment it arrives.
  Widget _fallback() => Image.asset(
        'assets/images/trophy_cover.jpg',
        width: width,
        height: height,
        fit: BoxFit.cover,
      );

  @override
  Widget build(BuildContext context) {
    final Widget body;
    if (imageUrl.isEmpty) {
      body = _fallback();
    } else {
      body = CachedNetworkImage(
        imageUrl: imageUrl,
        width: width,
        height: height,
        fit: fit,
        placeholder: (_, __) => _fallback(),
        errorWidget: (_, __, ___) => _fallback(),
      );
    }
    return ClipRRect(
      borderRadius: borderRadius ?? BorderRadius.zero,
      child: body,
    );
  }
}

/// Real banner cover (tournaments.banner_url, ImgBB) or an honest
/// dark placeholder with a gold trophy — never mock game art.
/// Fills its parent; callers size it with AspectRatio / SizedBox.
/// Disk-cached via _HomeCoverImage (HOME FIX 3): loading, error
/// and empty URL all render the same flat dark + gold trophy
/// fallback — never the shared broken-image error box, never blank.
Widget _coverImage(String url, {double iconSize = 48}) {
  return _HomeCoverImage(
    imageUrl: url,
    width: double.infinity,
    height: double.infinity,
    fit: BoxFit.cover,
    iconSize: iconSize,
  );
}

/// Generic pill: gold fill by default; pass bg/fg/border for the
/// green VALIDATED / red LIVE / outlined variants.
Widget _goldPill(String label,
    {Color? bg, Color? fg, Color? border, IconData? icon}) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
      color: bg ?? hGold,
      borderRadius: BorderRadius.circular(20),
      border: border == null ? null : Border.all(color: border, width: 1.5),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Icon(icon, color: fg ?? const Color(0xFF0A0A0F), size: 12),
          const SizedBox(width: 4)
        ],
        Text(label,
            style: TextStyle(
                color: fg ?? const Color(0xFF0A0A0F),
                fontWeight: FontWeight.bold,
                fontSize: 11,
                letterSpacing: 0.5)),
      ],
    ),
  );
}

/// Status pill shared by the design-match cards: LIVE red with dot,
/// UPCOMING gold, anything else a muted pill with the real status.
Widget _statusPill2(String status) {
  final s = status.toLowerCase();
  if (s == 'ongoing') {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
          color: Colors.red, borderRadius: BorderRadius.circular(20)),
      child: const Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.circle, color: Colors.white, size: 7),
        SizedBox(width: 5),
        Text('LIVE',
            style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 11,
                letterSpacing: 0.5))
      ]),
    );
  }
  if (s == 'upcoming') return _goldPill('UPCOMING');
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration:
        BoxDecoration(color: hBorder, borderRadius: BorderRadius.circular(20)),
    child: Text(status.toUpperCase(),
        style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 11,
            letterSpacing: 0.5)),
  );
}

/// "NO EVENTS FOUND" illustration (#7): gold trophy + gamepad in
/// thin gold OUTLINE line-art (mockup 08_tournaments_empty.jpg:
/// cup with two handles, a 5-point star on the cup, a stepped
/// pedestal base, a tilted gamepad overlapping the bottom-right),
/// on a soft radial gold halo + scattered gold sparkles.
/// J-detail-fix1: the old SOLID trophy icon + flat ring + gamepad
/// in a circle badge are gone — the mockup's art is outline
/// line-art with a glowing halo (glow IS in the mockup, restored
/// per the glow directive). Drawn with a CustomPainter — no image
/// asset, no copied art. Sized close to the mockup's ~300px-tall art.
Widget _noEventsArt() {
  return SizedBox(
    width: 280,
    height: 260,
    child: Stack(
      alignment: Alignment.center,
      children: [
        // Radial gold halo behind the art (mockup: brightest
        // directly behind the cup, fading ~80px out).
        Container(
          width: 260,
          height: 260,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              colors: [
                hGold.withValues(alpha: 0.28),
                hGold.withValues(alpha: 0.10),
                Colors.transparent
              ],
              stops: const [0.0, 0.55, 1.0],
            ),
          ),
        ),
        const CustomPaint(size: Size(280, 260), painter: _EmptyTrophyPainter()),
        const Positioned(
            top: 20, left: 34, child: Icon(Icons.star, color: hGold, size: 16)),
        const Positioned(
            top: 52,
            right: 30,
            child: Icon(Icons.star, color: hGold, size: 11)),
        const Positioned(
            bottom: 62,
            left: 16,
            child: Icon(Icons.star, color: hGold, size: 11)),
        const Positioned(
            top: 96, left: 8, child: Icon(Icons.star, color: hGold, size: 9)),
        const Positioned(
            bottom: 24,
            right: 64,
            child: Icon(Icons.star, color: hGold, size: 9)),
        const Positioned(
            top: 12, right: 84, child: Icon(Icons.star, color: hGold, size: 8)),
      ],
    ),
  );
}

/// "Starts in: 02h 45m" (#28): live from the real start timestamp,
/// ticks every 30 s. Honest fallbacks, never a guessed countdown.
class _StartsInText extends StatefulWidget {
  final int startMs;
  const _StartsInText({required this.startMs});
  @override
  State<_StartsInText> createState() => _StartsInTextState();
}

class _StartsInTextState extends State<_StartsInText> {
  late final Timer _timer;
  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.startMs <= 0) {
      return const Text('Starts in: Time TBA',
          style: TextStyle(color: hText2, fontSize: 14));
    }
    final diff = widget.startMs - DateTime.now().millisecondsSinceEpoch;
    if (diff <= 0) {
      return const Text('Starting soon',
          style: TextStyle(
              color: hGold, fontSize: 14, fontWeight: FontWeight.bold));
    }
    final hours = diff ~/ 3600000;
    final mins = (diff % 3600000) ~/ 60000;
    final label = hours > 0
        ? '${hours.toString().padLeft(2, '0')}h ${mins.toString().padLeft(2, '0')}m'
        : '${mins}m';
    return RichText(
      text: TextSpan(
        style: const TextStyle(color: Colors.white, fontSize: 14),
        children: [
          const TextSpan(text: 'Starts in: '),
          TextSpan(
              text: label,
              style:
                  const TextStyle(color: hGold, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
}

/// Big gold digital countdown (#1 hero, #14 lobby card): HH:MM:SS
/// with HOURS / MINUTES / SECONDS labels, ticking every second.
/// Total hours (days fold in) like the mockup's 00:42:18.
/// J-detail-fix1: [glow] adds the soft gold LED glow the #1
/// mockup shows on the digits (02_match_countdown.jpg) — used ONLY
/// by MatchCountdownPage; the #14 lobby card keeps flat gold
/// digits. [showLabels] hides the HOURS/MINUTES/SECONDS labels —
/// the #14 mockup's lobby countdown has none.
class _DigitalCountdown extends StatefulWidget {
  final int targetMs;
  final String status;
  final double fontSize;
  final bool glow;
  final bool showLabels;
  // P2 (mockup #1): the mockup's SECONDS pair renders dimmer than
  // HOURS/MINUTES. Opt-in per call site — only MatchCountdownPage
  // passes true; every other countdown keeps full-bright digits.
  final bool dimSeconds;
  const _DigitalCountdown(
      {required this.targetMs,
      required this.status,
      this.fontSize = 56,
      this.glow = false,
      this.showLabels = true,
      this.dimSeconds = false});
  @override
  State<_DigitalCountdown> createState() => _DigitalCountdownState();
}

class _DigitalCountdownState extends State<_DigitalCountdown> {
  late final Timer _timer;
  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.status == 'ongoing') {
      return Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
              color: Colors.redAccent, borderRadius: BorderRadius.circular(12)),
          child: const Text('● LIVE',
              style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 16)));
    }
    if (widget.targetMs <= 0)
      return Text('Start time not announced yet.',
          style: TextStyle(color: hText2, fontSize: 13));
    final diff = widget.targetMs - DateTime.now().millisecondsSinceEpoch;
    if (diff <= 0)
      return Text('Starting soon',
          style: TextStyle(
              color: hGold,
              fontWeight: FontWeight.bold,
              fontSize: widget.fontSize * 0.45));
    final hours = diff ~/ 3600000;
    final mins = (diff % 3600000) ~/ 60000;
    final secs = (diff % 60000) ~/ 1000;
    // J-detail-fix1 (#1): soft gold LED glow on the digits (the
    // mockup's seconds pair renders dimmer — likely a render
    // artefact, so all three units glow equally here).
    final digitShadows = widget.glow
        ? <Shadow>[
            Shadow(color: hGold.withValues(alpha: 0.55), blurRadius: 14),
            Shadow(color: hGold.withValues(alpha: 0.9), blurRadius: 4),
          ]
        : null;
    Widget unit(String v, String label) {
      // P2 (mockup #1): the SECONDS pair is dimmer — same gold,
      // ~45% alpha, no glow shadow.
      final dim = widget.dimSeconds && label == 'SECONDS';
      return Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(v,
                  style: TextStyle(
                      color:
                          dim ? hGold.withValues(alpha: 0.45) : hGold,
                      fontWeight: FontWeight.w900,
                      fontSize: widget.fontSize,
                      height: 1.0,
                      fontFeatures: const [FontFeature.tabularFigures()],
                      shadows: dim ? null : digitShadows)),
              if (widget.showLabels) ...[
                const SizedBox(height: 4),
                Text(label,
                    style: TextStyle(
                        color: hText2,
                        fontSize: (widget.fontSize * 0.22).clamp(10.0, 16.0),
                        letterSpacing: 1)),
              ],
            ],
          ),
        );
    }
    Widget sep() => Padding(
          padding: EdgeInsets.only(
              bottom: widget.showLabels ? widget.fontSize * 0.28 : 0),
          child: Text(':',
              style: TextStyle(
                  color: hGold,
                  fontWeight: FontWeight.w900,
                  fontSize: widget.fontSize,
                  shadows: digitShadows)),
        );
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        unit(hours.toString().padLeft(2, '0'), 'HOURS'),
        sep(),
        unit(mins.toString().padLeft(2, '0'), 'MINUTES'),
        sep(),
        unit(secs.toString().padLeft(2, '0'), 'SECONDS'),
      ],
    );
  }
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

/// Save Event as a full outlined gold bar button (#26 bottom bar).
/// Same device-local store as the old AppBar toggle — the toggle
/// reads the real stored list, never a fake "saved" state.
class _SaveEventBarButton extends StatefulWidget {
  final String tournamentId;
  const _SaveEventBarButton({required this.tournamentId});
  @override
  State<_SaveEventBarButton> createState() => _SaveEventBarButtonState();
}

class _SaveEventBarButtonState extends State<_SaveEventBarButton> {
  bool _saved = false;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    loadSavedTournamentIds().then((ids) {
      if (!mounted) return;
      setState(() {
        _saved = ids.contains(widget.tournamentId);
        _loaded = true;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: !_loaded
          ? null
          : () async {
              final nowSaved = await toggleSavedTournament(widget.tournamentId);
              if (!context.mounted) return;
              setState(() => _saved = nowSaved);
              toast(
                  context,
                  nowSaved
                      ? 'Event saved (on this device).'
                      : 'Event removed from saved.');
            },
      icon: Icon(_saved ? Icons.bookmark : Icons.bookmark_border,
          color: hGold, size: 20),
      label: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(_saved ? 'Saved' : 'Save Event',
              style: const TextStyle(
                  color: hGold, fontWeight: FontWeight.bold, fontSize: 14))),
      style: OutlinedButton.styleFrom(
        side: const BorderSide(color: hGold, width: 1.5),
        backgroundColor: hCard,
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      ),
    );
  }
}

/// ARENA / HUB wordmark in white + gold (mockup headers #28, #24).
/// The crown asset is the shared ArenaLogo; the wordmark is drawn
/// here so it stays white/gold on the dark gold screens.
Widget _arenaWordmark({double fontSize = 20, double crownSize = 36}) {
  return Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      ArenaLogo(crownSize: crownSize, fontSize: fontSize, showWordmark: false),
      const SizedBox(width: 6),
      // Dynamic wordmark (admin app_name) — was hardcoded ARENA/HUB.
      // White first line: these headers are dark in both modes.
      ArenaWordmark(
          fontSize: fontSize, letterSpacing: 0.5, firstColor: Colors.white),
    ],
  );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with AutomaticKeepAliveClientMixin {
  // WAVE 4 FIX 5: keep-alive so the tab State (streams, timers,
  // skeleton state) survives tab switches inside the IndexedStack.
  @override
  bool get wantKeepAlive => true;

  final _pageController = PageController();
  final _adPageController = PageController();
  final _heroController = PageController();
  int _promoIndex = 0;
  int _adIndex = 0;
  int _heroIndex = 0;
  Timer? _adTimer;
  Timer? _promoTimer;
  Timer? _heroTimer;
  int _promoCount = 0;
  int _heroCount = 0;
  bool _updateBannerChecked = false;
  // WAVE 4 FIX 5: session cache for getAppSettings — tab switches
  // never refetch (this State stays alive in the IndexedStack), and
  // a Home re-tap remount refreshes it (new nonce -> cache miss, so
  // the forced-update + popup check still re-runs on every Home load
  // with fresh settings). Keyed by the Home re-tap nonce so a fresh
  // HomeShell (nonce back to 0) reuses the first load's settings.
  static Map<String, dynamic>? _settingsCache;
  static int _settingsCacheNonce = -1;
  // SPECIAL-OFFER POPUP: at most ONCE per app session. HomePage
  // remounts on every Home re-tap (a new State each time), so the
  // per-State _updateBannerChecked flag cannot enforce this — only
  // a static survives remounts. Reset only by an app restart
  // (static state). Set only when the dialog actually shows (see
  // _checkUpdateAndBanner) — a no-image skip does not burn the
  // session's one showing.
  static bool _popupShownThisSession = false;
  // FIX 6 UPGRADE (2026-11-21) — Home's streams are created ONCE
  // here and re-created ONLY on explicit refresh (pull-to-refresh /
  // refresh-notifier bump), NEVER per build. The old code called
  // SupaDb.streamTournaments() / streamMyRegistrations() /
  // streamAllRegistrations() / streamPromotions() / streamAds() /
  // streamProfile() / streamUnreadCount() fresh inside build(), so
  // EVERY setState handed every StreamBuilder a NEW stream object —
  // and a StreamBuilder resets its snapshot to waiting/no-data on a
  // stream change. Home rebuilds every ~4s (hero/promo/ad autoplay
  // timers fire setState on every page change), so the TOURNAMENTS
  // section flashed its empty state, My Contests / promos / ads
  // flashed away, and every rebuild fired a fresh PostgREST fetch +
  // a new Realtime channel — on a slow connection Home looked empty
  // most of the time. Events uses the same call pattern but has no
  // timers, so it only resubscribed on user-driven rebuilds — this
  // was the second Home-vs-Events difference (the first is the
  // _DarkMockupCard 0px-scroll layout bug, FIX 3). The sliders
  // stream was already cached (late final); it joins the same set
  // so pull-to-refresh refetches it too.
  late final String _uid;
  late Stream<Map<String, dynamic>> _profileStream;
  late Stream<int> _unreadStream;
  late Stream<List<Map<String, dynamic>>> _tournamentsStream;
  late Stream<List<Map<String, dynamic>>> _slidersStream;
  late Stream<List<Map<String, dynamic>>> _myRegsStream;
  late Stream<List<Map<String, dynamic>>> _allRegsStream;
  late Stream<List<Map<String, dynamic>>> _promosStream;
  late Stream<List<Map<String, dynamic>>> _adsStream;

  void _createStreams() {
    _profileStream = SupaDb.streamProfile(_uid);
    _unreadStream = SupaDb.streamUnreadCount(_uid);
    _tournamentsStream = SupaDb.streamTournaments();
    // Wave C (A): admin-slider hero stream. Active slides ordered
    // by sort_order; empty/error -> getList returns [] -> the
    // featured-tournament fallback below.
    _slidersStream = SupaDb.streamList('sliders',
        eqCol: 'active', eqVal: true, orderBy: 'sort_order', ascending: true);
    _myRegsStream = SupaDb.streamMyRegistrations(_uid);
    _allRegsStream = SupaDb.streamAllRegistrations();
    _promosStream = SupaDb.streamPromotions();
    _adsStream = SupaDb.streamAds();
  }

  // FIX 6 UPGRADE — the pinned Next Match bar AND My Contests both
  // resolve my registrations to tournaments with
  // Future.wait(myIds -> getTournament). A FutureBuilder given a
  // NEW future on every build resets to waiting (same trap as the
  // streams above) and the bar flashed its empty state on every
  // autoplay tick. The future is memoised on the SORTED id set and
  // re-created only when my registrations actually change; both
  // call sites share the one future.
  String? _myTournamentsKey;
  Future<List<Map<String, dynamic>>>? _myTournamentsFuture;

  Future<List<Map<String, dynamic>>> _myTournamentsFor(Set<String> myIds) {
    final key = (myIds.toList()..sort()).join(',');
    if (_myTournamentsKey != key || _myTournamentsFuture == null) {
      _myTournamentsKey = key;
      _myTournamentsFuture =
          Future.wait(myIds.map((id) => SupaDb.getTournament(id)));
    }
    return _myTournamentsFuture!;
  }

  // Wave C (5): HomeLoadingSkeleton shows until the FIRST tournament
  // data arrives (stream emits [] on error too, so this can never
  // stick forever); never a full-screen spinner.
  bool _firstLoadDone = false;
  // CACHE-FIRST (Batch 3B, user order 2026-11-22 ~01:15 PKT): the
  // last tournament list rendered from the on-phone cache while
  // the live streams refresh in the background. Seeded in
  // initState from SupaDb.readCachedTournaments(); the hero and
  // TOURNAMENTS builders below fall back to this ONLY while their
  // stream has not delivered yet (snap.data == null) — once the
  // stream delivers, even [], live data wins, so a genuinely
  // empty list can never be masked by a stale cache.
  List<Map<String, dynamic>> _cachedTournaments = [];
  // HOME FIX (2026-11-21, v2007 — user phone test): one-shot
  // empty-load auto-retry. _tournamentsArrived flips true the
  // moment the tournaments stream delivers a non-empty list (set
  // in the TOURNAMENTS StreamBuilder below — a plain field write,
  // never a setState); _emptyRetryDone guards the retry to one
  // shot per mount.
  bool _tournamentsArrived = false;
  bool _emptyRetryDone = false;
  // One-shot retry timer (stored so dispose() can cancel it — an
  // unstored Future.delayed leaves a pending Timer that trips the
  // widget-test invariant "Timer still pending after dispose").
  Timer? _emptyRetryTimer;
  // Phase 2 (mockup #37): Home TOURNAMENTS filter —
  // all | live | upcoming | mygames.
  String _tourFilter = 'all';

  @override
  void initState() {
    super.initState();
    // FIX 6 UPGRADE: the uid + all streams are fixed at mount (see
    // the _createStreams comment). Same signed-in assumption as
    // build()'s old `currentUser!.uid` read — Home only renders
    // when a user is signed in.
    _uid = FirebaseAuth.instance.currentUser!.uid;
    _createStreams();
    _checkUpdateAndBanner();
    // PHOTO REFRESH (2026-11-20, Round 3 item 10): the header avatar
    // reads photo_url via streamProfile, which only refetches on
    // Realtime delivery — after a photo change it could lag until a
    // full Home rebuild. _changePhoto bumps SupaDb.refreshNotifier;
    // this listener rebuilds Home so the StreamBuilder resubscribes
    // with a fresh stream (immediate fetch, new photo at once).
    SupaDb.refreshNotifier.addListener(_onRefresh);
    // CACHE-FIRST (Batch 3B, user order 2026-11-22 ~01:15 PKT):
    // show the cached tournament list INSTANTLY on app open — the
    // skeleton dismisses as soon as the cache lands (a local
    // SharedPreferences read, no network), and the live streams
    // refresh in the background. Navigation is never blocked on
    // the network. When there is no cache this is a no-op and the
    // one-shot network read below still dismisses the skeleton.
    SupaDb.readCachedTournaments().then((rows) {
      if (mounted && rows.isNotEmpty) {
        setState(() {
          _cachedTournaments = rows;
          _firstLoadDone = true;
        });
      }
    });
    // Wave C (5): dismiss the HomeLoadingSkeleton on the first
    // tournament load. One-shot read (getList returns [] on error),
    // so the skeleton can never stick forever — and the live
    // StreamBuilders below keep updating after it.
    // FIX 6 UPGRADE: the 20s timeout closes the one hole in that
    // claim — a HUNG request (not an error) never returns, so
    // without a timeout a stalled network would stick the skeleton
    // forever. On timeout the skeleton still dismisses and the
    // live streams below keep updating when the network recovers.
    SupaDb.getTournaments()
        .timeout(const Duration(seconds: 20),
            onTimeout: () => <Map<String, dynamic>>[])
        .then((_) {
      if (mounted) setState(() => _firstLoadDone = true);
    });
    // HOME FIX (2026-11-21, v2007 — user phone test): one-shot
    // auto-retry when the first load comes back empty. Proven on
    // the user's phone: after an account switch the first fetch
    // can stick on empty (streams are created once at mount and
    // getList swallows every error into []), and a
    // pull-to-refresh — which only re-creates the streams via
    // _reloadHome — brings the data back. So 8s after mount, if
    // the tournaments stream has still delivered no rows, do
    // exactly that once. One shot per mount (guard bool), never
    // a loop or a repeating timer; the mounted check makes the
    // delayed callback safe if Home is gone by then, and the
    // stored Timer is cancelled in dispose() (an unstored
    // Future.delayed would leave a pending Timer behind). NOTE:
    // this deliberately does NOT wait for _firstLoadDone — in
    // the hung case the one-shot read behind the skeleton has a
    // 20s timeout, so requiring it would defeat the retry.
    _emptyRetryTimer = Timer(const Duration(seconds: 8), () {
      if (!mounted || _emptyRetryDone) return;
      _emptyRetryDone = true;
      if (!_tournamentsArrived) _reloadHome();
    });
  }

  void _onRefresh() {
    // FIX 6 UPGRADE: a bare setState no longer refetches anything
    // (streams are cached — see _createStreams), so a refresh bump
    // re-creates the streams AND the next-match future, then
    // rebuilds. This is the same fresh-fetch-on-pop behaviour
    // TournamentsPage gets from its nonce-keyed StreamBuilders.
    if (!mounted) return;
    _createStreams();
    _myTournamentsKey = null;
    _myTournamentsFuture = null;
    setState(() {});
  }

  /// FIX 6 UPGRADE — pull-to-refresh: re-creates every Home stream
  /// (tournaments + sliders + my/all registrations + promos + ads +
  /// profile/unread) and the next-match future, then waits for one
  /// fresh tournament read so the indicator spins until fresh data
  /// has actually landed. Never touches _firstLoadDone — a refresh
  /// must not flash the skeleton.
  Future<void> _reloadHome() async {
    _createStreams();
    _myTournamentsKey = null;
    _myTournamentsFuture = null;
    if (mounted) setState(() {});
    try {
      await SupaDb.getTournaments().timeout(const Duration(seconds: 20),
          onTimeout: () => <Map<String, dynamic>>[]);
    } catch (_) {}
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    SupaDb.refreshNotifier.removeListener(_onRefresh);
    _emptyRetryTimer?.cancel();
    _promoTimer?.cancel();
    _adTimer?.cancel();
    _heroTimer?.cancel();
    _pageController.dispose();
    _adPageController.dispose();
    _heroController.dispose();
    super.dispose();
  }

  /// Forced-update + popup banner, on login + every Home load (this
  /// page remounts when the Home tab is re-tapped — see HomeShell).
  Future<void> _checkUpdateAndBanner() async {
    if (_updateBannerChecked) return;
    _updateBannerChecked = true;
    try {
      // WAVE 4 FIX 5: cached getAppSettings (see _settingsCache).
      final nonce = (widget.key as ValueKey?)?.value as int? ?? 0;
      final cached = _settingsCacheNonce == nonce ? _settingsCache : null;
      final settings = cached ?? await SupaDb.getAppSettings();
      if (cached == null) {
        _settingsCache = settings;
        _settingsCacheNonce = nonce;
      }
      if (!mounted) return;
      final upd =
          SupaDb.asMap(settings['updateConfig'] ?? settings['update_config']);
      // FORCE UPDATE (2026-11-20): the forced path is enforced by the
      // SplashGate at boot (full-screen, cannot enter the app) — this
      // Home dialog is the SOFT path only (show == true, force ==
      // false). A forced update never reaches this dialog.
      if (upd['show'] == true && upd['force'] != true) {
        final version = SupaDb.strOf(upd['version']);
        final link = SupaDb.strOf(upd['link']);
        if (version.isNotEmpty && version != kAppVersion) {
          await showDialog<void>(
            context: context,
            barrierDismissible: true,
            builder: (_) => AlertDialog(
              backgroundColor: kCardPurpleMid,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22), side: const BorderSide(color: kCardPurpleBorder, width: 1.5)),
              title: Text('Update Available',
                  style: TextStyle(color: Colors.white)),
              content: Text(
                  'A new version ($version) is available. Please update to continue.',
                  style: TextStyle(color: hText2)),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text('Later', style: TextStyle(color: hText2))),
                TextButton(
                  onPressed: () async {
                    Navigator.pop(context);
                    // LINK ROBUSTNESS: an empty/invalid link used to
                    // silently do nothing — say so plainly instead.
                    if (link.isEmpty) {
                      if (mounted)
                        toast(context,
                            'Update link maujood nahi — admin se rabta karein.');
                      return;
                    }
                    final uri = Uri.parse(link);
                    if (await canLaunchUrl(uri)) {
                      await launchUrl(uri,
                          mode: LaunchMode.externalApplication);
                    } else if (mounted) {
                      toast(context,
                          'Update link maujood nahi — admin se rabta karein.');
                    }
                  },
                  child: Text('Update', style: TextStyle(color: hGold)),
                ),
              ],
            ),
          );
        }
      }
      final banner =
          SupaDb.asMap(settings['popupBanner'] ?? settings['popup_banner']);
      // SPECIAL-OFFER POPUP — shows ONLY when ALL of these hold:
      //   (1) admin toggle ON: app_settings.popup_banner.active ==
      //       true (Admin -> App Settings -> Branding -> Show
      //       Banner; admin_settings saves _showBanner into
      //       popup_banner.active, and getAppSettings aliases
      //       popup_banner <-> popupBanner, so active == false
      //       here ALWAYS means no popup);
      //   (2) an image URL is set — no image means skip silently;
      //       the bare 'Special offer!' text dialog never shows;
      //   (3) not shown yet this app session (static flag above).
      if (banner['active'] == true && !_popupShownThisSession && mounted) {
        final img = SupaDb.strOf(banner['imageUrl'],
            SupaDb.strOf(banner['image_url'], SupaDb.strOf(banner['image'])));
        final link = SupaDb.strOf(banner['link']);
        if (img.isNotEmpty) {
          _popupShownThisSession = true;
          await showDialog<void>(
            context: context,
            builder: (_) => AlertDialog(
              backgroundColor: kCardPurpleMid,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22), side: const BorderSide(color: kCardPurpleBorder, width: 1.5)),
              content: InkWell(
                onTap: link.isEmpty
                    ? null
                    : () async {
                        Navigator.pop(context);
                        final uri = Uri.parse(link);
                        if (await canLaunchUrl(uri))
                          await launchUrl(uri,
                              mode: LaunchMode.externalApplication);
                      },
                // HOME FIX 3 — disk-cached promo image; a dead
                // URL renders the flat dark + gold trophy
                // fallback, never the shared broken-image error
                // box. Dialog still closes normally either way.
                child: _HomeCoverImage(
                    imageUrl: img,
                    width: double.infinity,
                    height: 180,
                    fit: BoxFit.cover,
                    borderRadius: BorderRadius.circular(8)),
              ),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text('Close', style: TextStyle(color: hGold)))
              ],
            ),
          );
        }
      }
    } catch (_) {}
  }

  void _startPromoAutoplay(int count) {
    if (count == _promoCount) return;
    _promoCount = count;
    _promoTimer?.cancel();
    if (count <= 1) return;
    _promoTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (!_pageController.hasClients) return;
      final next = (_promoIndex + 1) % count;
      _pageController.animateToPage(next,
          duration: const Duration(milliseconds: 400), curve: Curves.easeInOut);
    });
  }

  /// Wave 4 design-match (#37): hero carousel autoplay (same 4s
  /// pattern as the promos carousel). No timer for a single slide.
  /// Wave C (A): the hero source can SWITCH (admin sliders appear /
  /// disappear), so a count change resets the page to 0 — otherwise
  /// the controller could sit past the end of the new list.
  void _startHeroAutoplay(int count) {
    if (count == _heroCount) return;
    _heroCount = count;
    _heroIndex = 0;
    if (_heroController.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_heroController.hasClients) _heroController.jumpToPage(0);
      });
    }
    _heroTimer?.cancel();
    if (count <= 1) return;
    _heroTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (!_heroController.hasClients) return;
      final next = (_heroIndex + 1) % count;
      _heroController.animateToPage(next,
          duration: const Duration(milliseconds: 400), curve: Curves.easeInOut);
    });
  }

  /// Shell for the pinned bar: side margins + gold divider line
  /// under it, as in the mockup. Only used by the VISIBLE bar
  /// states — the hidden state returns a bare shrink so the bar
  /// takes zero space and the tournament card above it is fully
  /// visible.
  Widget _pinnedBarShell(Widget child) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          child,
          const SizedBox(height: 10),
          Container(height: 2, color: hGold.withValues(alpha: 0.35)),
        ],
      ),
    );
  }

  /// HOME FIX 2 — pinned "Your Next Match" VS bar (user detail
  /// image 01c): the card sits directly above the bottom nav (the
  /// Home scroll is in an Expanded above it) — NOT a mid-scroll
  /// section any more. Header (gold trophy + "Your Next Match" +
  /// "See Details →"), centred time pill ("Today, 9:00 PM" from the
  /// REAL start time), VS row (my team left, big glowing VS centre,
  /// tournament name right). No opponent model exists, so the right
  /// side shows the REAL tournament name — never a fake Team
  /// Alpha/Bravo. Tap the card = the room; "See Details" = the
  /// tournament detail page.
  /// HOME FIX (2026-11-21, v2007 — user phone test): [hideEmpty]
  /// hides the bar's EMPTY state when Home HAS tournaments — the
  /// empty bar used to sit pinned above the nav and cover the
  /// bottom half of the first tournament card. On a genuinely
  /// empty Home (hideEmpty false) the empty card still shows so
  /// Home never feels dead; a joined match always shows the VS
  /// bar. The hidden state is a bare shrink (zero space), so the
  /// card above it is fully visible.
  Widget _pinnedNextMatchBar({bool hideEmpty = false}) {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _myRegsStream,
      builder: (context, snap) {
        final myRegs = snap.data ?? [];
        final myIds = myRegs.map((r) => strVal(r['tournament_id'])).toSet();
        if (myIds.isEmpty)
          return hideEmpty
              ? const SizedBox.shrink()
              : _pinnedBarShell(_pinnedNextMatchEmpty(context));
        final regByTid = <String, Map<String, dynamic>>{};
        for (final r in myRegs) {
          regByTid.putIfAbsent(strVal(r['tournament_id']), () => r);
        }
        return FutureBuilder<List<Map<String, dynamic>>>(
          future: _myTournamentsFor(myIds),
          builder: (context, fsnap) {
            var list = (fsnap.data ?? [])
                .where((t) =>
                    t.isNotEmpty &&
                    (tStatus(t) == 'upcoming' || tStatus(t) == 'full'))
                .toList();
            list.sort((a, b) =>
                intVal(a['startTime']).compareTo(intVal(b['startTime'])));
            if (list.isEmpty)
              return hideEmpty
                  ? const SizedBox.shrink()
                  : _pinnedBarShell(_pinnedNextMatchEmpty(context));
            final t = list.first;
            final reg = regByTid[strVal(t['id'])];
            final teamName = strVal(reg?['team_name']);
            final mode = strVal(t['mode'], 'Solo');
            final mySide = teamName.isNotEmpty
                ? teamName
                : (mode.toLowerCase() == 'solo' ? 'Solo entry' : 'Your squad');
            return _pinnedBarShell(GestureDetector(
              // v2016 FIX 11(a): the Next Match bar no longer
              // opens the tournament voice room (moved to team
              // chat) — it opens the tournament detail page.
              onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => TournamentDetailPage(
                          tournament: t))),
              child: _homeGoldBorder(
                child: Padding(
                  // HOME FIX (2026-11-20, user phone test): COMPACT
                  // card, mockup #37 shape — the old 14px padding +
                  // 22px header icon + 12px gaps made a ~160px tall
                  // box pinned above the bottom nav that hid the
                  // scroll content. Mockup height is ~110px: slim
                  // header, time pill centred above VS, slim VS row.
                  // M-detail-fix2-A: tightened further toward the
                  // mockup (was ~122px: padding 10, gaps 8+6, pill
                  // v-pad 3, 30px avatars) — padding 8, gaps 5+4,
                  // pill v-pad 2, 28px avatars, now ~107px. Font
                  // sizes stay per spec §37(f); only spacing shrank.
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(children: [
                        Container(
                            padding: const EdgeInsets.all(5),
                            decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: hGold.withValues(alpha: 0.15)),
                            child: const Icon(Icons.emoji_events,
                                color: hGold, size: 18)),
                        const SizedBox(width: 8),
                        const Expanded(
                            child: Text('Your Next Match',
                                style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 15,
                                    fontWeight: FontWeight.bold))),
                        GestureDetector(
                          onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) =>
                                      TournamentDetailPage(tournament: t))),
                          // FIX 16: padded tap target — the bare text
                          // was ~14px tall, too small to hit reliably.
                          child: const Padding(
                            padding: EdgeInsets.symmetric(
                                horizontal: 4, vertical: 6),
                            child: Text('See Details →',
                                style: TextStyle(
                                    color: hGold,
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold)),
                          ),
                        ),
                      ]),
                      const SizedBox(height: 5),
                      Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 2),
                          decoration: BoxDecoration(
                              color: hSecondary,
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(color: hBorder)),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.access_time,
                                  color: hGold, size: 13),
                              const SizedBox(width: 5),
                              Text(_matchTimeLabel(intVal(t['startTime'])),
                                  style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold)),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      // FIX 16 (mockup #37): the two sides sit at the
                      // OUTER edges (my team left, event right) with
                      // the big glowing VS in the centre. The old row
                      // crowded both sides toward the middle (left
                      // end-aligned, right start-aligned) and the VS
                      // was small and flat.
                      Row(
                        children: [
                          Expanded(
                            child: Row(
                              children: [
                                Container(
                                    padding: const EdgeInsets.all(2),
                                    decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        border:
                                            Border.all(color: hGold, width: 2)),
                                    child: const CircleAvatar(
                                        radius: 14,
                                        backgroundColor: hSecondary,
                                        child: Icon(Icons.shield,
                                            color: hGold, size: 15))),
                                const SizedBox(width: 8),
                                Flexible(
                                    child: Text(mySide,
                                        style: const TextStyle(
                                            color: Colors.white,
                                            fontWeight: FontWeight.bold,
                                            fontSize: 14),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis)),
                              ],
                            ),
                          ),
                          const SizedBox(width: 12),
                          // FIX 16: the mockup's VS is big (~28)
                          // italic with a yellow glow — the glow IS
                          // in the mockup, so it stays per the GLOW
                          // RULE.
                          Text('VS',
                              style: TextStyle(
                                  color: hGold,
                                  fontWeight: FontWeight.w900,
                                  fontStyle: FontStyle.italic,
                                  fontSize: 28,
                                  shadows: [
                                    Shadow(
                                        color: hGold.withValues(alpha: 0.65),
                                        blurRadius: 12)
                                  ])),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                // FIX 16: no opponent model exists —
                                // the right side shows the REAL
                                // tournament name (never a fake
                                // "Team Bravo"), with a trophy mark
                                // for the event.
                                Flexible(
                                    child: Text(tName(t),
                                        textAlign: TextAlign.right,
                                        style: const TextStyle(
                                            color: Colors.white,
                                            fontWeight: FontWeight.bold,
                                            fontSize: 14),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis)),
                                const SizedBox(width: 8),
                                Container(
                                    padding: const EdgeInsets.all(2),
                                    decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        border: Border.all(
                                            color: hBorder, width: 2)),
                                    child: const CircleAvatar(
                                        radius: 14,
                                        backgroundColor: hSecondary,
                                        child: Icon(Icons.emoji_events,
                                            color: hGold, size: 15))),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ));
          },
        );
      },
    );
  }

  /// Pinned-bar empty state: the card stays visible with its header
  /// instead of vanishing when the user has no next match.
  /// FIX 16 (2026-11-20): the one-line truncated message is gone —
  /// the full sentence wraps onto two lines (the old maxLines: 1 +
  /// ellipsis cut it mid-word on the user's phone: "...to see
  /// i..."), and the header carries a "Join a tournament →" action
  /// into the Tournaments page. Total empty card is now ~85px.
  Widget _pinnedNextMatchEmpty(BuildContext context) {
    return _homeGoldBorder(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(children: [
              Container(
                  padding: const EdgeInsets.all(5),
                  decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: hGold.withValues(alpha: 0.15)),
                  child:
                      const Icon(Icons.emoji_events, color: hGold, size: 18)),
              const SizedBox(width: 8),
              const Expanded(
                  child: Text('Your Next Match',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.bold),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis)),
              // FIX 16: the empty card gets the same right-side
              // action slot the joined card's "See Details →" uses —
              // "Join a tournament →" opens the Tournaments page
              // (same route as the "My Contests" Explore button).
              GestureDetector(
                onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => Scaffold(
                            appBar: AppBar(
                                centerTitle: true,
                                title: _tournamentsAppBarTitle()),
                            body: const TournamentsPage()))),
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                  child: Text('Join a tournament →',
                      style: TextStyle(
                          color: hGold,
                          fontSize: 12,
                          fontWeight: FontWeight.bold)),
                ),
              ),
            ]),
            const SizedBox(height: 5),
            // FIX 16: full sentence, wraps onto two lines — nothing
            // is truncated (the old maxLines: 1 + ellipsis cut it
            // mid-word).
            const Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                      text: 'No upcoming match',
                      style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 13)),
                  TextSpan(
                      text: ' — join a tournament to see it here.',
                      style: TextStyle(color: hText2, fontSize: 13)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// HOME FIX 4 — "My Contests" empty state is a real visible card
  /// (gold border + icon + Explore action), never a lone grey text
  /// line: with 1 tournament in the data the scroll content is
  /// short, and a bare line leaves the Home feeling empty/black
  /// below the tournament list. Explore opens the Tournaments page.
  Widget _myContestsEmpty(BuildContext context) {
    return _homeGoldBorder(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: hGold.withValues(alpha: 0.15)),
                child:
                    const Icon(Icons.sports_esports, color: hGold, size: 22)),
            const SizedBox(width: 10),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text("You haven't joined any contests yet.",
                      style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 15)),
                  SizedBox(height: 4),
                  Text('Join a tournament to see it here.',
                      style: TextStyle(color: hText2, fontSize: 13)),
                ],
              ),
            ),
            const SizedBox(width: 10),
            // PHASE 2 REDESIGN (§7): shared outlined action.
            ArenaOutlinedButton(
              onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => Scaffold(
                          appBar: AppBar(
                              centerTitle: true,
                              title: _tournamentsAppBarTitle()),
                          body: const TournamentsPage()))),
              child: const Text('Explore',
                  style: TextStyle(
                      color: hGold, fontWeight: FontWeight.bold, fontSize: 13)),
            ),
          ],
        ),
      ),
    );
  }

  // REMAINING-ITEMS: sponsored ads rotate at each ad's stored
  // rotation_interval_seconds (admin Ads edit dialog), falling back
  // to 4s when empty/invalid.
  void _scheduleAdRotation(List<Map<String, dynamic>> ads) {
    _adTimer?.cancel();
    if (ads.length <= 1) return;
    final raw = ads[_adIndex % ads.length]['rotationInterval'];
    final secs = raw is num ? raw.toInt() : int.tryParse(raw.toString());
    final interval = (secs != null && secs > 0) ? secs : 4;
    _adTimer = Timer(Duration(seconds: interval), () {
      if (!_adPageController.hasClients) return;
      final next = (_adIndex + 1) % ads.length;
      _adPageController.animateToPage(next,
          duration: const Duration(milliseconds: 400), curve: Curves.easeInOut);
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final uid = _uid;
    // v2010 — v2009 screenshot: the header sat HALF under the
    // status bar ("ARENA" invisible, crown/bell/avatar cut) even
    // though a SafeArea(top: true) wraps this Column — on this
    // build the reported top padding reads 0, so the SafeArea
    // insets nothing. Guarantee a 28dp floor: when the reported
    // padding is healthy (>= 28) nothing changes; when it reads
    // short/0 we top it up, so the header always clears the bar.
    final topPad = MediaQuery.paddingOf(context).top;
    final topShortfall = topPad < 28 ? 28 - topPad : 0.0;
    // Wave C (5): skeleton while the first data load has no cache —
    // never a full-screen spinner.
    if (!_firstLoadDone) {
      // PHASE E (E5): no opaque fill — the app-wide poster shows
      // through the skeleton too.
      return Container(
        child: Padding(
          padding: EdgeInsets.only(top: topPad + topShortfall),
          child: const HomeLoadingSkeleton(),
        ),
      );
    }
    // PHASE E (E5): the opaque hBg wrapper is gone — Home's whole
    // scroll content sits on the app-wide poster now.
    return Container(
      // HOME FIX 2 — pinned "Your Next Match" bar: the Home scroll
      // sits in an Expanded SingleChildScrollView and the VS card
      // is pinned directly above the bottom nav (detail image 01c)
      // — it is no longer a mid-scroll section. Flat bg + no glow
      // blobs: the mockup has neither.
      child: SafeArea(
        top: true,
        bottom: false,
        child: Column(
          children: [
            Expanded(
              // FIX 6 UPGRADE — pull-to-refresh (there was NO
              // RefreshIndicator on Home at all): a downward drag
              // re-creates every Home stream via _reloadHome
              // (tournaments + sliders + next match + promos + ads)
              // and the indicator spins until fresh data lands.
              // AlwaysScrollableScrollPhysics keeps the gesture
              // available even when the content is shorter than the
              // screen (e.g. the genuinely-empty state).
              child: RefreshIndicator(
                color: hGold,
                backgroundColor: hCard,
                onRefresh: _reloadHome,
                child: SingleChildScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  // FIX 18 REFINEMENT: side margins 12dp (mockup).
                  // v2010: + topShortfall (see above) — the header
                  // must clear the status bar even when the
                  // reported top padding reads 0.
                  // PHASE 2 REDESIGN (§7): bottom padding keeps the
                  // last content clear of the bottom nav (the scroll
                  // sits in an Expanded above the pinned bar, so the
                  // nav can never cover content).
                  padding: EdgeInsets.only(
                      top: kSpace16 + topShortfall,
                      left: kSpace12,
                      right: kSpace12,
                      bottom: kSpace16),
                  child: Stack(
                    children: [
                      // J-detail-fix1 (#37, mockup 01): faint diagonal
                      // streaks top-right behind the header/logo.
                      const Positioned(
                          top: 0,
                          right: 0,
                          child: IgnorePointer(child: _DiagonalStreaks())),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Wave 4 design-match (#37) header + greeting.
                          // Header: crown logo lockup + bell with REAL unread badge
                          // (hidden at 0) + round avatar with REAL photo_url and
                          // gold ring; avatar tap opens Profile. Greeting:
                          // "Welcome back," small, then the REAL display name BIG
                          // bold italic + the REAL level pill (profiles.level,
                          // migration 017, default 1).
                          StreamBuilder<Map<String, dynamic>>(
                            stream: _profileStream,
                            builder: (context, snap) {
                              final p = snap.data ?? {};
                              final name = strVal(p['displayName'], 'Player');
                              final level = intVal(p['level'], 1);
                              final photoUrl = strVal(p['photo_url']);
                              return Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      // PHASE E (E18): the FULL logo badge,
                                      // straight Image.asset — no ClipOval,
                                      // no added ring/glow (the emblem has
                                      // its own gold ring + crown). The
                                      // ClipOval version looked like a
                                      // second profile photo next to the
                                      // real one on the right.
                                      ClipRRect(
                                        borderRadius:
                                            BorderRadius.circular(10),
                                        child: Image.asset(
                                          'assets/images/arena_hub_logo.png',
                                          width: 48,
                                          height: 48,
                                          fit: BoxFit.cover,
                                        ),
                                      ),
                                      const Spacer(),
                                      StreamBuilder<int>(
                                        stream: _unreadStream,
                                        builder: (context, usnap) {
                                          final unread = usnap.data ?? 0;
                                          return Stack(
                                            children: [
                                              IconButton(
                                                icon: const Icon(
                                                    Icons
                                                        .notifications_outlined,
                                                    color: Colors.white,
                                                    size: 28),
                                                onPressed: () => Navigator.push(
                                                    context,
                                                    MaterialPageRoute(
                                                        builder: (_) =>
                                                            NotificationsPage(
                                                                uid: uid))),
                                              ),
                                              if (unread > 0)
                                                Positioned(
                                                  right: 6,
                                                  top: 6,
                                                  child: Container(
                                                    padding: const EdgeInsets
                                                        .symmetric(
                                                        horizontal: 5,
                                                        vertical: 1),
                                                    decoration: BoxDecoration(
                                                        // PHASE 2 REDESIGN (§7): theme red.
                                                        color: hLiveRed,
                                                        borderRadius:
                                                            BorderRadius
                                                                .circular(10)),
                                                    child: Text(
                                                        unread > 9
                                                            ? '9+'
                                                            : '$unread',
                                                        style: const TextStyle(
                                                            color: Colors.white,
                                                            fontSize: 10,
                                                            fontWeight:
                                                                FontWeight
                                                                    .bold)),
                                                  ),
                                                ),
                                            ],
                                          );
                                        },
                                      ),
                                      const SizedBox(width: 6),
                                      GestureDetector(
                                        onTap: () => Navigator.push(
                                            context,
                                            MaterialPageRoute(
                                                builder: (_) => Scaffold(
                                                    body: ProfilePage(
                                                        uid: uid)))),
                                        child: Container(
                                          padding: const EdgeInsets.all(2),
                                          decoration: BoxDecoration(
                                              shape: BoxShape.circle,
                                              border: Border.all(
                                                  color: hGold, width: 2)),
                                          // Wave C (B): disk-cached avatar (same gold
                                          // person-icon fallback as before).
                                          child: ArenaCachedAvatar(
                                            photoUrl: photoUrl,
                                            radius: 20,
                                            backgroundColor: hSecondary,
                                            fallback: const Icon(Icons.person,
                                                color: hGold, size: 22),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  // HOME SPACING (2026-11-22, user order —
                                  // mockup-exact): header -> "Welcome back,"
                                  // gap 14 -> 10; the mockup keeps the
                                  // greeting tight under the header.
                                  const SizedBox(height: 10),
                                  Text(tr('Welcome back,', 'Welcome back,'),
                                      style: const TextStyle(
                                          color: hText2, fontSize: 14)),
                                  Row(
                                    children: [
                                      // HOME #37 FIX — Lv pill INLINE right after the
                                      // name (mockup #37: "Player ★ Lv.5", small, dark
                                      // bg + gold border). Flexible(loose) lets the
                                      // name take only the width it needs instead of
                                      // pushing the pill to the right edge.
                                      Flexible(
                                        fit: FlexFit.loose,
                                        child: Text(name,
                                            style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 26,
                                                fontWeight: FontWeight.w900,
                                                fontStyle: FontStyle.italic),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis),
                                      ),
                                      const SizedBox(width: 8),
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 8, vertical: 3),
                                        decoration: BoxDecoration(
                                            color:
                                                hGold.withValues(alpha: 0.15),
                                            borderRadius:
                                                BorderRadius.circular(20),
                                            border: Border.all(color: hGold)),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            const Icon(Icons.star,
                                                color: hGold, size: 12),
                                            const SizedBox(width: 4),
                                            Text('Lv.$level',
                                                style: const TextStyle(
                                                    color: hGold,
                                                    fontWeight: FontWeight.bold,
                                                    fontSize: 12)),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              );
                            },
                          ),
                          // HOME SPACING v2014 (2026-11-22, user order —
                          // second report: "slider ke oper space abhi
                          // bhi hai"): the 16 -> 6 shrink was NOT
                          // enough — the old comment's "~50dp mockup"
                          // claim was wrong (the mockup's left gap is
                          // ~7-9dp; its slant is ~21dp, not 36).
                          // True v2013 geometry: 6 (this) + 12
                          // (pop-out zone) + 36 (slant) = 54dp black
                          // at the left, 18dp at the right. v2014:
                          // this gap 6 -> 2, slant 36 -> 24, box 204
                          // when no character is set (216 with one),
                          // and the hero translates up 18dp (see the
                          // branches below) — new visible gap ≈ 8dp
                          // left / -4dp centre / -16dp right (the
                          // hero's right edge rises beside the Lv
                          // pill, like the mockup). The 3D slant
                          // stays; the pop-out zone stays for
                          // character slides only.
                          const SizedBox(height: 2),
                          // Wave 4 design-match (#37) hero: swipeable
                          // featured-tournament carousel over REAL upcoming
                          // tournaments (name/date/mode/banner_url). The old
                          // "Esport Games / No games yet" section is REMOVED.
                          // Wave C (A) — ADMIN SLIDER HERO: when public.sliders has
                          // active rows, the hero shows THOSE (admin-managed, no
                          // rebuild); empty table / failed read -> the
                          // featured-tournament carousel below (never a hardcoded
                          // mock slide, never a crash). No admin screen here (Phase 6).
                          StreamBuilder<List<Map<String, dynamic>>>(
                            stream: _tournamentsStream,
                            builder: (context, snap) {
                              // CACHE-FIRST: cached list until the
                              // stream delivers (see _cachedTournaments).
                              final upcoming = (snap.data ?? _cachedTournaments)
                                  .where((t) => tStatus(t) == 'upcoming')
                                  .toList()
                                ..sort((a, b) => intVal(a['startTime'])
                                    .compareTo(intVal(b['startTime'])));
                              final heroes = upcoming.take(5).toList();
                              return StreamBuilder<List<Map<String, dynamic>>>(
                                stream: _slidersStream,
                                builder: (context, ssnap) {
                                  final sliders = (ssnap.data ?? [])
                                      .where((s) =>
                                          strVal(s['image_url']).isNotEmpty)
                                      .toList();
                                  if (sliders.isNotEmpty) {
                                    _startHeroAutoplay(sliders.length);
                                    // HOME #37 FIX — dots live INSIDE the hero now
                                    // (bottom-right, mockup #37); no dots row below.
                                    // HOME FIX 3 — ClipRect bounds the hero to its
                                    // box: no hero state (image, fallback, sheen)
                                    // can ever paint over the header above.
                                    // v2014 (Bug 1): the box is 204 when NO slider
                                    // carries a character cutout (the 12dp pop-out
                                    // zone is dead space then) and 216 when one
                                    // does (the head needs it). Transform.translate
                                    // lifts the hero 18dp toward the welcome row —
                                    // a negative-margin Container is ILLEGAL here
                                    // (Container asserts margin.isNonNegative, so
                                    // it crashes the build; proven 2026-11-22).
                                    // The 18dp lift + the 2dp gap below keeps the
                                    // hero→TOURNAMENTS visual gap at 20dp.
                                    return Transform.translate(
                                      offset: const Offset(0, -18),
                                      child: ClipRect(
                                        child: SizedBox(
                                          height: sliders.any((s) => strVal(s['character_image_url']).isNotEmpty)
                                              ? _kHeroBoxHeight
                                              : _kHeroBannerHeight,
                                          child: PageView.builder(
                                            controller: _heroController,
                                            itemCount: sliders.length,
                                            onPageChanged: (i) =>
                                                setState(() => _heroIndex = i),
                                            // HOME FIX 4 — 3D perspective lean on the
                                            // whole slide (see _heroTiltMatrix); the
                                            // ClipRect above bounds it to the box.
                                            itemBuilder: (_, i) => Transform(
                                                transform: _heroTiltMatrix(),
                                                alignment: Alignment.center,
                                                child: _SliderHeroSlide(
                                                    slide: sliders[i],
                                                    dotCount: sliders.length,
                                                    activeDot: _heroIndex,
                                                    isActive: i == _heroIndex)),
                                          ),
                                        ),
                                      ),
                                    );
                                  }
                                  if (heroes.isEmpty) {
                                    // v2014 (Bug 1): the empty card is SOLID (not
                                    // transparent like the hero's empty top zone),
                                    // so it does NOT get the 18dp translate lift —
                                    // it would cover the avatar + Lv pill. The
                                    // 18dp bottom padding keeps its gap to the
                                    // TOURNAMENTS header's layout box at the same
                                    // 20dp (18 + the 2dp SizedBox below); the
                                    // header translates up 8dp, so the VISUAL
                                    // gap is 12dp, like the hero branches.
                                    return Padding(
                                      padding: const EdgeInsets.only(bottom: 18),
                                      child: _homeGlassCard(
                                        child: Padding(
                                          padding: const EdgeInsets.symmetric(
                                              vertical: 12),
                                          child: Column(
                                            children: [
                                              Icon(Icons.emoji_events,
                                                  color: hGold, size: 40),
                                              const SizedBox(height: 10),
                                              const Text('No upcoming events yet',
                                                  style: TextStyle(
                                                      color: Colors.white,
                                                      fontWeight: FontWeight.bold,
                                                      fontSize: 16)),
                                              const SizedBox(height: 4),
                                              Text(
                                                  'New tournaments will appear here when registration opens.',
                                                  textAlign: TextAlign.center,
                                                  style: TextStyle(
                                                      color: hText2,
                                                      fontSize: 13)),
                                            ],
                                          ),
                                        ),
                                      ),
                                    );
                                  }
                                  _startHeroAutoplay(heroes.length);
                                  // HOME #37 FIX — dots live INSIDE the hero now
                                  // (bottom-right, mockup #37); no dots row below.
                                  // HOME FIX 3 — ClipRect bounds the hero to its
                                  // box: no hero state (image, fallback, sheen)
                                  // can ever paint over the header above.
                                  // v2014 (Bug 1): tournament heroes NEVER carry
                                  // a character cutout, so the box is the 204
                                  // banner height — the 12dp pop-out zone was
                                  // dead space here. Same 18dp translate lift
                                  // as the slider branch above.
                                  return Transform.translate(
                                    offset: const Offset(0, -18),
                                    child: ClipRect(
                                      child: SizedBox(
                                        height: _kHeroBannerHeight,
                                        child: PageView.builder(
                                          controller: _heroController,
                                          itemCount: heroes.length,
                                          onPageChanged: (i) =>
                                              setState(() => _heroIndex = i),
                                          // HOME FIX 4 — 3D perspective lean on the
                                          // whole slide (see _heroTiltMatrix); the
                                          // ClipRect above bounds it to the box.
                                          itemBuilder: (_, i) => Transform(
                                              transform: _heroTiltMatrix(),
                                              alignment: Alignment.center,
                                              child: _HeroSlide(
                                                  tournament: heroes[i],
                                                  dotCount: heroes.length,
                                                  activeDot: _heroIndex,
                                                  isActive: i == _heroIndex)),
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              );
                            },
                          ),
                          // FIX 18 REFINEMENT (2026-11-21): hero→TOURNAMENTS gap
                          // 20dp — measured from mockup 1000048218_36_3m8b.png
                          // (banner bottom → header). The old 14dp came from the
                          // #37 mockup's ~15dp; the new mockup is the authority.
                          // v2014: the SizedBox is 2 now, NOT 20 — the hero is
                          // translated up 18dp (see above), so the gap from the
                          // painted hero to the header's LAYOUT box is 18 + 2 =
                          // 20dp. (The empty card gets its 18dp from its own
                          // bottom padding instead.)
                          // 2026-11-23 USER ORDER: shrink the gaps around the
                          // TOURNAMENTS header WITHOUT moving the hero — the
                          // hero's -18 lift and the empty card's 18dp padding
                          // are UNTOUCHED (an earlier attempt changed the lift
                          // and grew the black band above the slider; the user
                          // rejected it). The header itself translates up 8dp
                          // into the dead space below the painted hero, so the
                          // VISUAL hero→header gap is 20 - 8 = 12dp and the
                          // header→chips visual gap is 8 (translate) + 2
                          // (SizedBox) = 10dp. Chips→card stays 10dp.
                          const SizedBox(height: 2),
                          // TOURNAMENTS section (mockup #37): fit-four filters +
                          // the shared horizontal _TournamentCard.
                          Transform.translate(
                            offset: const Offset(0, -8),
                            child: _homeSectionHeader(
                              'TOURNAMENTS',
                              action: GestureDetector(
                                onTap: () => Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                        builder: (_) => Scaffold(
                                            appBar: AppBar(
                                                centerTitle: true,
                                                title: _tournamentsAppBarTitle()),
                                            body: const TournamentsPage()))),
                                child: const Text('View All →',
                                    style: TextStyle(
                                        color: hGold,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 14)),
                              ),
                            ),
                          ),
                          // 2026-11-23: header→chips VISUAL gap 10dp — the
                          // 2dp SizedBox plus the header's 8dp upward
                          // translate above. (Was a 17dp SizedBox.)
                          const SizedBox(height: 2),
                          // PHASE 2 REDESIGN (§7): the four filters in the
                          // SHARED segmented style — one dark container
                          // holding four ArenaFilterChip segments. Same
                          // four filters, same order, same tap behaviour
                          // (_tourFilter); the per-pill icons are gone
                          // (the shared chip has no icon slot). Each chip
                          // sits in a FittedBox scaleDown: the real F2
                          // chip has no internal label scale-down and its
                          // 14dp side padding leaves ~54dp for text, so
                          // 'Upcoming' / 'My Games' would overflow their
                          // ~82dp segment at default text scale — the
                          // old pill scaled its label for exactly this
                          // reason. At scale 1.0 the wrapper is a no-op.
                          Container(
                            padding: const EdgeInsets.all(kSpace4),
                            // FIX 23 item 23: purple container
                            // (ChatGPT reference) — purple border +
                            // glow, selected chip gold fill (the
                            // chip itself already does gold).
                            decoration: cardDecoration(radius: 20),
                            child: Row(
                              children: [
                                Expanded(
                                    child: FittedBox(
                                        fit: BoxFit.scaleDown,
                                        child: ArenaFilterChip(
                                            label: 'All',
                                            selected: _tourFilter == 'all',
                                            onTap: () => setState(() =>
                                                _tourFilter = 'all')))),
                                Expanded(
                                    child: FittedBox(
                                        fit: BoxFit.scaleDown,
                                        child: ArenaFilterChip(
                                            label: 'Live',
                                            selected: _tourFilter == 'live',
                                            onTap: () => setState(() =>
                                                _tourFilter = 'live')))),
                                Expanded(
                                    child: FittedBox(
                                        fit: BoxFit.scaleDown,
                                        child: ArenaFilterChip(
                                            label: 'Upcoming',
                                            selected: _tourFilter == 'upcoming',
                                            onTap: () => setState(() =>
                                                _tourFilter = 'upcoming')))),
                                Expanded(
                                    child: FittedBox(
                                        fit: BoxFit.scaleDown,
                                        child: ArenaFilterChip(
                                            label: 'My Games',
                                            selected: _tourFilter == 'mygames',
                                            onTap: () => setState(() =>
                                                _tourFilter = 'mygames')))),
                              ],
                            ),
                          ),
                          // FIX 18 REFINEMENT: chips→card1 gap 10dp (mockup).
                          const SizedBox(height: 10),
                          StreamBuilder<List<Map<String, dynamic>>>(
                            stream: _tournamentsStream,
                            builder: (context, tsnap) {
                              // CACHE-FIRST: cached list until the
                              // stream delivers (see _cachedTournaments).
                              var list = tsnap.data ?? _cachedTournaments;
                              // HOME FIX (2026-11-21, v2007): arrival flag for the
                              // one-shot empty-load retry (see initState). Plain
                              // field write — never a setState, never a rebuild
                              // trigger.
                              if (tsnap.hasData && tsnap.data!.isNotEmpty)
                                _tournamentsArrived = true;
                              return StreamBuilder<List<Map<String, dynamic>>>(
                                stream: _myRegsStream,
                                builder: (context, msnap) {
                                  final myIds = (msnap.data ?? [])
                                      .map((r) => strVal(r['tournament_id']))
                                      .toSet();
                                  // PUBLIC VISIBILITY (audit fix 2026-11-21): a
                                  // pending/draft tournament awaiting approval — or
                                  // a cancelled one — is never a public card, in ANY
                                  // filter. (Join was already gated; the card itself
                                  // was not, so unapproved tournaments sat on Home.)
                                  list = list.where((t) {
                                    final s = tStatus(t);
                                    return s != 'pending' &&
                                        s != 'draft' &&
                                        s != 'cancelled';
                                  }).toList();
                                  if (_tourFilter == 'live') {
                                    list = list
                                        .where((t) => tStatus(t) == 'ongoing')
                                        .toList();
                                  } else if (_tourFilter == 'upcoming') {
                                    list = list
                                        .where((t) => tStatus(t) == 'upcoming')
                                        .toList();
                                  } else if (_tourFilter == 'mygames') {
                                    list = list
                                        .where((t) =>
                                            myIds.contains(strVal(t['id'])))
                                        .toList();
                                  }
                                  // HOME BUG FIX (2026-11-20, user-reported): the old
                                  // ASCENDING sort + take(3) showed only the 3
                                  // EARLIEST tournaments, so a newly created
                                  // tournament (later start time) NEVER appeared on
                                  // Home. The sort is DESCENDING now (latest start
                                  // time first) and take(3) STAYS — Home shows the
                                  // latest 3, newest first, per the user's rule
                                  // ("Home par sirf LATEST 3-4 tournaments, naye
                                  // pehle; baaki sab Events mein"). A newly created
                                  // tournament now appears at the top of Home, and
                                  // Home stays a compact latest-3 section. (The
                                  // take(3) in TournamentsPage is the "recommended
                                  // top 3" section — a different thing, untouched.)
                                  list.sort((a, b) => intVal(b['startTime'])
                                      .compareTo(intVal(a['startTime'])));
                                  list = list.take(3).toList();
                                  // SAMEER FIX 3 (2026-11-21): a lone grey line left
                                  // Home looking broken/empty when no tournament
                                  // matches the filter — a proper branded card with
                                  // a Browse Events action instead (never a fake
                                  // tournament). The hero above already has its own
                                  // "No upcoming events yet" card; this covers the
                                  // TOURNAMENTS section the same way.
                                  if (list.isEmpty) {
                                    return HomeTournamentsEmptyState(
                                      onBrowse: () => Navigator.push(
                                          context,
                                          MaterialPageRoute(
                                              builder: (_) => Scaffold(
                                                  appBar: AppBar(
                                                      centerTitle: true,
                                                      title:
                                                          _tournamentsAppBarTitle()),
                                                  body:
                                                      const TournamentsPage()))),
                                    );
                                  }
                                  return StreamBuilder<
                                      List<Map<String, dynamic>>>(
                                    stream: _allRegsStream,
                                    builder: (context, rsnap) {
                                      final allRegs = rsnap.data ?? [];
                                      return Column(
                                        children: [
                                          for (final t in list)
                                            Padding(
                                              // HOME #37 FIX — card→card gap 12→10dp
                                              // (measured mockup gap ~10dp).
                                              padding: const EdgeInsets.only(
                                                  bottom: 10),
                                              child: _TournamentCard(
                                                  tournament: t,
                                                  joined: myIds.contains(
                                                      strVal(t['id'])),
                                                  // P0-1: count PLAYERS, not rows x teamSize
                                                  // (RPC rows are one-per-member).
                                                  joinedCount: SupaDb
                                                      .registrationPlayerCount(allRegs
                                                          .where((r) =>
                                                              strVal(r[
                                                                      'tournament_id']) ==
                                                              strVal(t['id']))
                                                          .toList())),
                                            ),
                                        ],
                                      );
                                    },
                                  );
                                },
                              );
                            },
                          ),
                          const SizedBox(height: 14),
                          _homeSectionHeader('My Contests'),
                          const SizedBox(height: 10),
                          StreamBuilder<List<Map<String, dynamic>>>(
                            stream: _myRegsStream,
                            builder: (context, snap) {
                              final myRegs = snap.data ?? [];
                              final myIds = myRegs
                                  .map((r) => strVal(r['tournament_id']))
                                  .toSet();
                              if (myIds.isEmpty)
                                return _myContestsEmpty(context);
                              return FutureBuilder<List<Map<String, dynamic>>>(
                                future: _myTournamentsFor(myIds),
                                builder: (context, fsnap) {
                                  var list = (fsnap.data ?? [])
                                      .where((t) => t.isNotEmpty)
                                      .toList();
                                  // upcoming/ongoing/full only, start_time sort.
                                  // ('full' = slots locked; the tournament is still
                                  // the player's next match — audit fix 2026-11-21.)
                                  list = list
                                      .where((t) =>
                                          tStatus(t) == 'upcoming' ||
                                          tStatus(t) == 'ongoing' ||
                                          tStatus(t) == 'full')
                                      .toList();
                                  list.sort((a, b) => intVal(a['startTime'])
                                      .compareTo(intVal(b['startTime'])));
                                  if (list.isEmpty)
                                    return _myContestsEmpty(context);
                                  // ROUND 5 ROOT CAUSE: My Contests previously called
                                  // tournamentCard WITHOUT joinedCount, so it defaulted
                                  // to 0 and always showed 0/max + an empty bar, no
                                  // matter how many teams had joined. Count PLAYERS
                                  // live from all registration rows (1 row = 1 team,
                                  // x teamSize — the same definition as join validation
                                  // and the Detail page): 2 squads = 8 players, not 2.
                                  // The stream is live (Realtime), so the number and
                                  // the bar update without an app restart.
                                  return StreamBuilder<
                                      List<Map<String, dynamic>>>(
                                    stream: _allRegsStream,
                                    builder: (context, rsnap) {
                                      final allRegs = rsnap.data ?? [];
                                      return Column(children: [
                                        for (final t in list)
                                          Padding(
                                            padding: const EdgeInsets.only(
                                                bottom: 12),
                                            child: Column(children: [
                                              tournamentCard(context, t,
                                                  showJoin: false,
                                                  joined: true,
                                                  // P0-1: count PLAYERS, not rows x teamSize
                                                  // (RPC rows are one-per-member).
                                                  joinedCount: SupaDb
                                                      .registrationPlayerCount(allRegs
                                                          .where((r) =>
                                                              strVal(r[
                                                                      'tournament_id']) ==
                                                              strVal(t['id']))
                                                          .toList())),
                                              const SizedBox(height: 6),
                                              // v2016 FIX 11(a): the "Room" button is GONE
                                              // (voice rooms moved to team chat) — Details
                                              // is now the only, full-width button.
                                              SizedBox(
                                                width: double.infinity,
                                                // PHASE 2 REDESIGN (§7): shared
                                                // outlined Details action.
                                                child: ArenaOutlinedButton(
                                                    onPressed: () => Navigator.push(
                                                        context,
                                                        MaterialPageRoute(
                                                            builder: (_) =>
                                                                TournamentDetailPage(
                                                                    tournament:
                                                                        t))),
                                                    child: const Text('Details',
                                                        style: TextStyle(
                                                            color: hGold))),
                                              )
                                            ]),
                                          ),
                                      ]);
                                    },
                                  );
                                },
                              );
                            },
                          ),
                          const SizedBox(height: 20),
                          StreamBuilder<List<Map<String, dynamic>>>(
                            stream: _promosStream,
                            builder: (context, snap) {
                              final promos = snap.data ?? [];
                              if (promos.isEmpty)
                                return const SizedBox.shrink();
                              _startPromoAutoplay(promos.length);
                              return Column(
                                children: [
                                  SizedBox(
                                    height: 170,
                                    child: PageView.builder(
                                      controller: _pageController,
                                      itemCount: promos.length,
                                      onPageChanged: (i) =>
                                          setState(() => _promoIndex = i),
                                      itemBuilder: (_, i) {
                                        final p = promos[i];
                                        final img = strVal(p['imageUrl'], '');
                                        return InkWell(
                                          onTap: () async {
                                            // FIX 19 (2026-11-21): NO "Promotion"
                                            // dialog — the tap goes STRAIGHT to the
                                            // promotion's link. No link set: silent
                                            // no-op (no dialog, no toast).
                                            final link = strVal(p['link']);
                                            if (link.isEmpty) return;
                                            final uri = Uri.parse(link);
                                            if (await canLaunchUrl(uri))
                                              await launchUrl(uri,
                                                  mode: LaunchMode
                                                      .externalApplication);
                                          },
                                          child: Container(
                                            decoration: BoxDecoration(
                                                borderRadius:
                                                    BorderRadius.circular(20),
                                                border:
                                                    Border.all(color: hBorder)),
                                            child: ClipRRect(
                                              borderRadius:
                                                  BorderRadius.circular(20),
                                              child: img.isEmpty
                                                  ? Container(
                                                      color: hCard,
                                                      alignment:
                                                          Alignment.center,
                                                      child: Text(
                                                          strVal(p['title'],
                                                              'Promotion'),
                                                          style: TextStyle(
                                                              color: hGold,
                                                              fontWeight:
                                                                  FontWeight
                                                                      .bold)))
                                                  // HOME FIX 3 — disk-cached promo cover;
                                                  // a dead URL renders the flat dark +
                                                  // gold trophy fallback, never the
                                                  // shared broken-image error box.
                                                  : _HomeCoverImage(
                                                      imageUrl: img,
                                                      width: double.infinity,
                                                      height: double.infinity,
                                                      fit: BoxFit.cover),
                                            ),
                                          ),
                                        );
                                      },
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: List.generate(promos.length,
                                        (i) => _homeDot(i == _promoIndex)),
                                  ),
                                ],
                              );
                            },
                          ),
                          const SizedBox(height: 20),
                          // Phase 2 Ads slot (user order 2026-11-19 ~05:50 PKT):
                          // the Sponsored carousel reads the admin-managed `ads`
                          // table (remote, no rebuild to change the ad — that IS the
                          // user's "apni marzi ke Add" mechanism). The section is
                          // HIDDEN entirely when the table is empty — no grey
                          // "no offers" text spoiling the dashboard. NOTE: the brief
                          // said content driven by app_settings, but app_settings
                          // has NO ads_banner key live; adding a parallel
                          // app_settings mechanism would duplicate the working
                          // ads-table one. Logged as a deviation in the Phase 2
                          // checkpoint. NO AdMob SDK (launch crashes on TECNO).
                          StreamBuilder<List<Map<String, dynamic>>>(
                            stream: _adsStream,
                            builder: (context, snap) {
                              final ads = snap.data ?? [];
                              if (ads.isEmpty) return const SizedBox.shrink();
                              _scheduleAdRotation(ads);
                              return Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  _homeSectionHeader(
                                      tr('Sponsored', 'Sponsored')),
                                  const SizedBox(height: 10),
                                  SizedBox(
                                    height: 150,
                                    child: PageView.builder(
                                      controller: _adPageController,
                                      itemCount: ads.length,
                                      onPageChanged: (i) {
                                        setState(() => _adIndex = i);
                                        _scheduleAdRotation(ads);
                                      },
                                      itemBuilder: (_, i) {
                                        final ad = ads[i];
                                        final img = strVal(ad['imageUrl'], '');
                                        return InkWell(
                                          onTap: () =>
                                              openAdTarget(context, ad),
                                          child: _DarkMockupCard(
                                            padding: EdgeInsets.zero,
                                            radius: 20,
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Expanded(
                                                  child: ClipRRect(
                                                    borderRadius:
                                                        const BorderRadius
                                                            .vertical(
                                                            top:
                                                                Radius.circular(
                                                                    16)),
                                                    child: img.isEmpty
                                                        ? Container(
                                                            color: hSecondary,
                                                            alignment: Alignment
                                                                .center,
                                                            child: Icon(
                                                                Icons.campaign,
                                                                color: hGold,
                                                                size: 40))
                                                        // HOME FIX 3 — disk-cached ad cover;
                                                        // a dead URL renders the flat dark
                                                        // + gold trophy fallback, never the
                                                        // shared broken-image error box.
                                                        : _HomeCoverImage(
                                                            imageUrl: img,
                                                            width:
                                                                double.infinity,
                                                            height:
                                                                double.infinity,
                                                            fit: BoxFit.cover),
                                                  ),
                                                ),
                                                Padding(
                                                  padding:
                                                      const EdgeInsets.all(8),
                                                  child: Text(
                                                      strVal(ad['title'],
                                                          'Sponsored'),
                                                      style: TextStyle(
                                                          color: Colors.white,
                                                          fontWeight:
                                                              FontWeight.bold),
                                                      maxLines: 1,
                                                      overflow: TextOverflow
                                                          .ellipsis),
                                                ),
                                              ],
                                            ),
                                          ),
                                        );
                                      },
                                    ),
                                  ),
                                  if (ads.length > 1) ...[
                                    const SizedBox(height: 6),
                                    Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: List.generate(ads.length,
                                          (i) => _homeDot(i == _adIndex)),
                                    ),
                                  ],
                                ],
                              );
                            },
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
            // HOME FIX (2026-11-21, v2007 — user phone test): the
            // pinned bar hides its EMPTY state when Home HAS
            // tournaments — the empty bar used to sit pinned above
            // the nav and cover the bottom half of the first
            // tournament card. This wrapper StreamBuilder uses the
            // CACHED _tournamentsStream (never a fresh stream in
            // build — see the FIX 6 comment) to tell the bar
            // whether tournaments exist; the bar still shows its
            // empty card on a genuinely empty Home, and the VS bar
            // whenever a match is joined.
            StreamBuilder<List<Map<String, dynamic>>>(
              stream: _tournamentsStream,
              builder: (context, tsnap) {
                final hasTournaments = (tsnap.data ?? []).isNotEmpty;
                return _pinnedNextMatchBar(hideEmpty: hasTournaments);
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// J-detail-fix1 (#7): the pushed Tournaments page title — the
/// mockup header reads TOURNAMENTS (white italic w900 with a gold
/// bar), not the tab's gold 'Events'. The tab's own AppBar lives in
/// HomeShell (main.dart, out of scope for this round).
Widget _tournamentsAppBarTitle() => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
            width: 5,
            height: 28,
            decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(2), color: hGold)),
        const SizedBox(width: 10),
        const Text('TOURNAMENTS',
            style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w900,
                fontStyle: FontStyle.italic,
                fontSize: 22)),
      ],
    );

/// SAMEER FIX 3 (2026-11-21) — branded empty state for Home's
/// TOURNAMENTS section: the ARENA HUB mark + an honest "no
/// tournaments yet" line + a Browse Events action. Shown when the
/// current filter matches no tournament (never a fake tournament).
/// Extracted (public) so the empty state is widget-testable.
class HomeTournamentsEmptyState extends StatelessWidget {
  final VoidCallback onBrowse;
  const HomeTournamentsEmptyState({super.key, required this.onBrowse});

  @override
  Widget build(BuildContext context) {
    return _homeGlassCard(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          children: [
            const ArenaLogo(crownSize: 36, fontSize: 20, showWordmark: false),
            const SizedBox(height: 10),
            Text(tr('No tournaments yet', 'Abhi koi tournament nahi'),
                style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 16)),
            const SizedBox(height: 4),
            Text(
                tr('Check back soon — new tournaments will appear here when registration opens.',
                    'Jald wapas aayein — naye tournaments registration khulne par yahan nazar aayenge.'),
                textAlign: TextAlign.center,
                style: TextStyle(color: hText2, fontSize: 13)),
            const SizedBox(height: 12),
            _goldPillButton(
                label: tr('Browse Events', 'Events dekhein'),
                onPressed: onBrowse),
          ],
        ),
      ),
    );
  }
}

class TournamentsPage extends StatefulWidget {
  final String? gameFilter;
  final String? gameName;
  const TournamentsPage({super.key, this.gameFilter, this.gameName});
  @override
  State<TournamentsPage> createState() => _TournamentsPageState();
}

class _TournamentsPageState extends State<TournamentsPage>
    with AutomaticKeepAliveClientMixin {
  // WAVE 4 FIX 5: keep-alive so the tab State (streams, saved ids,
  // search/filter state) survives tab switches in the IndexedStack.
  @override
  bool get wantKeepAlive => true;

  // Phase 2 filters (mockup #37): all | live | upcoming | mygames
  // | saved. Live = ongoing; My Games = tournaments I joined;
  // Saved = device-saved events (SharedPreferences interim).
  String _filter = 'all';
  Set<String> _savedIds = {};
  // CACHE-FIRST (Batch 3B, user order 2026-11-22 ~01:15 PKT): the
  // last tournament list, rendered instantly while the live stream
  // refreshes in the background. Same rule as Home: the cache is
  // used ONLY while the stream has not delivered yet (snap.data
  // == null) — live data, even [], always wins after that.
  List<Map<String, dynamic>> _cachedTournaments = [];
  bool _ignoreGameFilter = false;

  @override
  void initState() {
    super.initState();
    _loadSaved();
    SupaDb.readCachedTournaments().then((rows) {
      if (mounted && rows.isNotEmpty) {
        setState(() => _cachedTournaments = rows);
      }
    });
  }

  Future<void> _loadSaved() async {
    final ids = await loadSavedTournamentIds();
    if (mounted) setState(() => _savedIds = ids);
  }

  // FULL COMPLETION expansion 2: search + filters + client pagination.
  // Pagination is client-side over the live list (render window, not a
  // query limit) — it keeps long lists light on small phones without
  // changing the live stream behaviour.
  final _searchCtrl = TextEditingController();
  final _searchFocus = FocusNode();
  String _search = '';
  // P2 (2026-11-21, mockup #7): the filter/search icon in the
  // in-page header toggles the search row (real behaviour — it
  // filters the same list the in-list search field filters).
  bool _showSearch = false;
  String _feeFilter = 'any'; // any | free | paid — fee group: EXACTLY
  // ONE is always selected (single-select; Sameer 2026-11-22: ye
  // hissa pehle se theek hai, waisa hi rakho).
  // EVENTS FILTER RULE (Sameer, 2026-11-22 05:33): the SORT group is
  // OPTIONAL — zero or one selected, never forced. null = no sort
  // filter (list keeps its natural/stream order); tapping a selected
  // sort chip DESELECTS it. Before this, _sort defaulted to 'date',
  // so 'Any fee' + 'Sort: Date' both showed gold at once — wrong.
  String? _sort; // null | date | prize | fee
  int _visible = 20;

  /// Wave 4b #7: search field + fee/sort chips, rendered by the list
  /// builder ONLY when the filtered list is non-empty (mockup frame
  /// = chips + empty state only). Same widgets/behaviour as before,
  /// just relocated — search, fee filter and sort still work exactly
  /// as they did when results exist.
  @override
  void dispose() {
    _searchCtrl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  // S3 REDESIGN (Phase 2, guide §6 Screen 3): search bar in the
  // shared input style — contract tokens (kField fill, kRadiusInput,
  // subtle kBorder, gold focus border). Behaviour unchanged: same
  // controller/focus node, same clear action, same onChanged filter.
  Widget _searchField() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(kSpace12, kSpace12, kSpace12, 0),
      // FIX 23 item 29: card look via CardFieldShell.
      child: CardFieldShell(
        child: TextField(
        controller: _searchCtrl,
        focusNode: _searchFocus,
        style: TextStyle(color: kText),
        decoration: InputDecoration(
          hintText: 'Search tournaments, games...',
          hintStyle: TextStyle(color: kTextMuted),
          prefixIcon: Icon(Icons.search, color: kGold),
          suffixIcon: _search.isEmpty
              ? null
              : IconButton(
                  icon: Icon(Icons.clear, color: kMuted),
                  onPressed: () => setState(() {
                        _searchCtrl.clear();
                        _search = '';
                      })),
          border: const OutlineInputBorder(borderSide: BorderSide.none),
          enabledBorder: const OutlineInputBorder(borderSide: BorderSide.none),
          focusedBorder: const OutlineInputBorder(borderSide: BorderSide.none),
        ),
        onChanged: (v) => setState(() => _search = v.trim().toLowerCase()),
      ),
      ),
    );
  }

  // S3 REDESIGN (Phase 2, guide §6 Screen 3): fee/sort chips are
  // the shared ArenaFilterChip — selected yellow fill + dark text,
  // unselected dark surface + grey border. SELECTION LOGIC
  // UNCHANGED: fee stays single-select (exactly one of any/free/
  // paid), sort stays optional-toggle (tap a selected chip to
  // clear). The row stays horizontally scrollable so it never
  // overflows on small screens.
  Widget _feeSortRow() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(kSpace12, kSpace8, kSpace12, 0),
      child: Row(
        children: [
          for (final f in [
            {'k': 'any', 'l': 'Any fee'},
            {'k': 'free', 'l': 'Free entry'},
            {'k': 'paid', 'l': 'Paid entry'},
          ])
            Padding(
              padding: const EdgeInsets.only(right: kSpace8),
              child: ArenaFilterChip(
                  label: f['l']!,
                  selected: _feeFilter == f['k'],
                  onTap: () => setState(() => _feeFilter = f['k']!)),
            ),
          for (final s in [
            {'k': 'date', 'l': 'Sort: Date'},
            {'k': 'prize', 'l': 'Sort: Prize'},
            {'k': 'fee', 'l': 'Sort: Fee'},
          ])
            Padding(
              padding: const EdgeInsets.only(right: kSpace8),
              child: ArenaFilterChip(
                  label: s['l']!,
                  selected: _sort == s['k'],
                  // Sort chips TOGGLE (optional group): tapping the
                  // selected chip clears the sort entirely.
                  onTap: () =>
                      setState(() => _sort = _sort == s['k'] ? null : s['k']!)),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final uid = FirebaseAuth.instance.currentUser!.uid;
    return Column(
      children: [
        // P2 (2026-11-21, mockup #7): the Events tab gets its own
        // in-page TOURNAMENTS header (gold bar + white italic
        // title, the shared _tournamentsAppBarTitle) — the
        // HomeShell AppBar above it only says "Events". The
        // search icon toggles the search row.
        // S3 REDESIGN (Phase 2, guide §6 Screen 3): header in the
        // shared style — contract spacing tokens + kGold (same
        // #FDC903 value as hGold). Title widget, back action,
        // filter menu and search toggle all unchanged.
        Padding(
          padding: const EdgeInsets.fromLTRB(kSpace8, kSpace12, kSpace8, 0),
          child: Row(
            children: [
              // P2 (mockup #7): the in-page header carries the
              // gold-ring circled back arrow (mockup, top-left).
              // On the Events tab there is no route to pop, so it
              // pops only when this page was pushed onto a stack.
              Container(
                decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: kGold, width: 1.5)),
                child: IconButton(
                  icon: Icon(Icons.arrow_back,
                      color: kGold, size: 20),
                  tooltip: 'Back',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                      minWidth: 36, minHeight: 36),
                  onPressed: () => Navigator.maybePop(context),
                ),
              ),
              const SizedBox(width: kSpace8),
              // S3 OVERFLOW FIX (Phase 2, found by the S3 render
              // tests): the bare title Row overflowed by 71px at
              // 360dp (111px at 320dp) — the search button was
              // pushed off-screen. The title now takes the free
              // space in an Expanded + FittedBox(scaleDown), so it
              // renders full-size when it fits and shrinks only
              // when it must (same pattern as the empty-state
              // heading). The Expanded replaces the old Spacer:
              // it still pushes the search action to the right
              // edge. The shared title widget itself is untouched.
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: _tournamentsAppBarTitle(),
                ),
              ),
              // P2 (mockup #7): the gold chevron after TOURNAMENTS
              // is the filter dropdown — same four filters as the
              // pill row below (Saved lives in the pill row too).
              PopupMenuButton<String>(
                icon: Icon(Icons.keyboard_arrow_down,
                    color: kGold, size: 26),
                tooltip: 'Filter tournaments',
                color: kSurfaceElevated,
                onSelected: (v) => setState(() => _filter = v),
                itemBuilder: (_) => [
                  for (final f in [
                    {'k': 'all', 'l': 'All'},
                    {'k': 'live', 'l': 'Live'},
                    {'k': 'upcoming', 'l': 'Upcoming'},
                    {'k': 'mygames', 'l': 'My Games'},
                    {'k': 'saved', 'l': 'Saved'},
                  ])
                    PopupMenuItem(
                        value: f['k']!,
                        child: Text(f['l']!,
                            style: TextStyle(
                                color: _filter == f['k']
                                    ? kGold
                                    : Colors.white))),
                ],
              ),
              IconButton(
                icon: Icon(Icons.search, color: kGold),
                tooltip: 'Search tournaments',
                onPressed: () {
                  setState(() => _showSearch = !_showSearch);
                  // P2 (mockup #7): opening the search row focuses
                  // the field so the keyboard is ready immediately.
                  if (_showSearch) {
                    WidgetsBinding.instance.addPostFrameCallback(
                        (_) => _searchFocus.requestFocus());
                  }
                },
              ),
            ],
          ),
        ),
        if (_showSearch) _searchField(),
        if (widget.gameFilter != null && !_ignoreGameFilter)
          // Overflow fix: the old single-line label ("Showing
          // tournaments for: <game>") wrapped + ellipsised mid-word at
          // the user's large text scale ("Showing tourname..."). Split
          // into a small muted label + the game name on its own line
          // with explicit sizes, so nothing clips mid-word.
          Padding(
            padding: const EdgeInsets.all(kSpace12),
            child: MockupCard(
              padding: const EdgeInsets.all(14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.filter_list, color: kGold),
                  const SizedBox(width: kSpace8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Showing tournaments for:',
                            style: kStyleLabel.copyWith(color: kMuted)),
                        Text(widget.gameName ?? widget.gameFilter ?? '',
                            style: TextStyle(
                                color: kText,
                                fontSize: 14,
                                fontWeight: FontWeight.bold),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        // Wave B #7: mockup filter pills — icon + label, selected =
        // gold fill with black text, unselected = dark card with
        // muted border. Same five filters as before (Saved kept:
        // device-saved events), only the look changed.
        // FIX 23 item 20 (SUPERSEDES P2's fixed row): the old
        // Expanded + FittedBox scaleDown row shrank the labels
        // PROGRESSIVELY (All big → Saved smallest) — each pill
        // got ~61px at 360px and the longer labels scaled down
        // to fit. Now the row matches the fee/sort row below
        // (the REFERENCE — uniform + horizontally scrollable):
        // natural-width pills, one 13px label size, no scaling,
        // and the row slides left-right so every pill is
        // reachable — never cut/clipped.
        // S3 REDESIGN (Phase 2, guide §6 Screen 3): category pills
        // keep their icon + label structure (the shared
        // ArenaFilterChip has no icon slot) — selected = kGold fill
        // + dark text, unselected = dark card + muted border, with
        // contract spacing tokens. Filter logic unchanged.
        // FIX 23 item 23: the pills sit in the purple container
        // (ChatGPT reference) — same treatment as the Home row:
        // purple border + glow, selected pill gold fill.
        Container(
          padding: const EdgeInsets.all(kSpace4),
          decoration: cardDecoration(radius: 20),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding:
                const EdgeInsets.fromLTRB(kSpace12, kSpace4, kSpace12, kSpace4),
            child: Row(
            children: [
              for (final f in [
                {'k': 'all', 'l': 'All', 'i': Icons.grid_view},
                {'k': 'live', 'l': 'Live', 'i': Icons.sensors},
                {'k': 'upcoming', 'l': 'Upcoming', 'i': Icons.calendar_today},
                {'k': 'mygames', 'l': 'My Games', 'i': Icons.sports_esports},
                {'k': 'saved', 'l': 'Saved', 'i': Icons.bookmark},
              ])
                Padding(
                  padding: const EdgeInsets.only(right: kSpace8),
                  child: GestureDetector(
                    onTap: () => setState(() => _filter = f['k'] as String),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                        color: _filter == f['k'] ? kGold : hCard,
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(
                            color: _filter == f['k'] ? kGold : hBorder,
                            width: 1),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(f['i'] as IconData,
                              size: 15,
                              color: _filter == f['k']
                                  ? const Color(0xFF0A0A0F)
                                  : (f['k'] == 'live'
                                      ? Colors.redAccent
                                      : hText2)),
                          const SizedBox(width: kSpace4),
                          Text(f['l'] as String,
                              style: TextStyle(
                                  color: _filter == f['k']
                                      ? const Color(0xFF0A0A0F)
                                      : Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13)),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
          ),
        ),
        // Wave 4b #7: the search + fee/sort rows live INSIDE the list
        // builder now (see below) — the mockup frame has only the
        // chips + empty state, so those rows are hidden when the
        // filtered list is empty and shown when results exist.
        // LIVE list (fix B): the old code already used StreamBuilders,
        // but they only refetch on a Supabase Realtime postgres_changes
        // event — and tables created via SQL Editor are NOT in the
        // supabase_realtime publication (see 003_realtime.sql), so no
        // event ever fired and the card kept showing Join until the
        // screen was re-entered. Wrapping the streams in the refresh
        // notifier (keyed by its value) forces a fresh fetch whenever
        // a Join/Detail page pops, with or without Realtime.
        Expanded(
          child: ValueListenableBuilder<int>(
            valueListenable: SupaDb.refreshNotifier,
            builder: (context, nonce, _) {
              return StreamBuilder<List<Map<String, dynamic>>>(
                key: ValueKey('tournaments-$nonce'),
                stream: SupaDb.streamTournaments(),
                builder: (context, snap) {
                  // CACHE-FIRST: cached list until the stream
                  // delivers (see _cachedTournaments).
                  var list = snap.data ?? _cachedTournaments;
                  return StreamBuilder<List<Map<String, dynamic>>>(
                    key: ValueKey('regs-$nonce'),
                    stream: SupaDb.streamAllRegistrations(),
                    builder: (context, rsnap) {
                      final allRegs = rsnap.data ?? [];
                      final counts = <String, int>{};
                      final myJoined = <String>{};
                      // ROUND 5: count PLAYERS, not teams (1 row = 1 team,
                      // x teamSize — same as join validation + Detail).
                      // Look the tournament up once instead of falling
                      // back to Solo (1 player) for any row whose
                      // tournament is not in the list.
                      final byId = <String, Map<String, dynamic>>{
                        for (final t in list) strVal(t['id']): t
                      };
                      for (final r in allRegs) {
                        final tid = strVal(r['tournament_id']);
                        final rt = byId[tid];
                        if (rt == null) continue;
                        // P0-1: count PLAYERS — a legacy row counts
                        // as its whole team (teammates payload), an
                        // RPC row as 1 player (see
                        // registrationPlayerCount). The old
                        // "+ teamSizeOf(rt)" per row overcounted RPC
                        // squads 4x.
                        counts[tid] = (counts[tid] ?? 0) +
                            SupaDb.registrationPlayerCount([r]);
                        if (strVal(r['firebase_uid']) == uid) {
                          myJoined.add(tid);
                        }
                      }
                      if (widget.gameFilter != null && !_ignoreGameFilter) {
                        list = list
                            .where((t) =>
                                strVal(t['id']) == widget.gameFilter ||
                                tGame(t) == widget.gameFilter ||
                                strVal(t['gameId']) == widget.gameFilter)
                            .toList();
                      }
                      // PUBLIC VISIBILITY (audit fix 2026-11-21):
                      // pending/draft/cancelled are never public
                      // cards, in ANY filter (same rule as Home).
                      list = list.where((t) {
                        final s = tStatus(t);
                        return s != 'pending' &&
                            s != 'draft' &&
                            s != 'cancelled';
                      }).toList();
                      // Phase 2 filters (mockup #37): Live = ongoing,
                      // My Games = tournaments I joined, Saved =
                      // device-saved events (SharedPreferences interim).
                      if (_filter == 'live') {
                        list =
                            list.where((t) => tStatus(t) == 'ongoing').toList();
                      } else if (_filter == 'upcoming') {
                        list = list
                            .where((t) => tStatus(t) == 'upcoming')
                            .toList();
                      } else if (_filter == 'mygames') {
                        list = list
                            .where((t) => myJoined.contains(strVal(t['id'])))
                            .toList();
                      } else if (_filter == 'saved') {
                        list = list
                            .where((t) => _savedIds.contains(strVal(t['id'])))
                            .toList();
                      }
                      if (_search.isNotEmpty) {
                        list = list
                            .where((t) =>
                                ('${strVal(t['name'])} ${tGame(t)} ${strVal(t['gameName'])}')
                                    .toLowerCase()
                                    .contains(_search))
                            .toList();
                      }
                      if (_feeFilter == 'free') {
                        list = list
                            .where((t) => numVal(t['entryFee']) <= 0)
                            .toList();
                      } else if (_feeFilter == 'paid') {
                        list = list
                            .where((t) => numVal(t['entryFee']) > 0)
                            .toList();
                      }
                      if (_sort == 'prize') {
                        list.sort((a, b) => numVal(b['prizePool'])
                            .compareTo(numVal(a['prizePool'])));
                      } else if (_sort == 'fee') {
                        list.sort((a, b) => numVal(a['entryFee'])
                            .compareTo(numVal(b['entryFee'])));
                      } else if (_sort == 'date') {
                        list.sort((a, b) => intVal(a['startTime'])
                            .compareTo(intVal(b['startTime'])));
                      }
                      // _sort == null: NO sort filter — the list keeps
                      // its natural (stream) order. (EVENTS FILTER
                      // RULE 2026-11-22: sort is optional.)
                      // Wave B #7: designed "NO EVENTS FOUND" — gold
                      // trophy + gamepad art, "NO EVENTS" white +
                      // "FOUND" gold in big italic, the mockup's
                      // subtitle, CLEAR FILTERS gold filled +
                      // EXPLORE GAMES gold outlined. Same actions as
                      // before (clear filters / drop the game filter
                      // and show everything).
                      if (list.isEmpty) {
                        return Stack(
                          children: [
                            // J-detail-fix1 (#7): sparse gold dust
                            // behind the empty state (mockup 08).
                            const Positioned.fill(
                                child: IgnorePointer(child: ArenaEmberDots())),
                            Center(
                              child: SingleChildScrollView(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: kSpace32, vertical: kSpace24),
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    _noEventsArt(),
                                    const SizedBox(height: kSpace8),
                                    // 2026-11-20 rebuild: FittedBox
                                    // (scaleDown) keeps the heading on
                                    // ONE line like the mockup — at 34px
                                    // it wrapped to two lines at 360dp.
                                    FittedBox(
                                      fit: BoxFit.scaleDown,
                                      child: RichText(
                                        textAlign: TextAlign.center,
                                        text: TextSpan(
                                          style: const TextStyle(
                                              color: Colors.white,
                                              fontWeight: FontWeight.w900,
                                              fontStyle: FontStyle.italic,
                                              fontSize: 34,
                                              height: 1.1),
                                          children: [
                                            const TextSpan(text: 'NO EVENTS '),
                                            TextSpan(
                                                text: 'FOUND',
                                                style:
                                                    TextStyle(color: kGold)),
                                          ],
                                        ),
                                      ),
                                    ),
                                    const SizedBox(height: kSpace12),
                                    const Text(
                                        'There are no tournaments matching your filters right now.',
                                        style: TextStyle(
                                            color: hText2, fontSize: 15),
                                        textAlign: TextAlign.center),
                                    const SizedBox(height: kSpace32),
                                    // J-detail-fix1 (#7): the mockup
                                    // shows a soft gold glow under the
                                    // CLEAR FILTERS pill.
                                    Container(
                                      decoration: BoxDecoration(
                                          borderRadius:
                                              BorderRadius.circular(28),
                                          boxShadow: _goldGlow()),
                                      child: SizedBox(
                                        width: double.infinity,
                                        child: ElevatedButton(
                                          onPressed: () => setState(() {
                                            _filter = 'all';
                                            _searchCtrl.clear();
                                            _search = '';
                                            _feeFilter = 'any';
                                            _sort = null;
                                          }),
                                          style: ElevatedButton.styleFrom(
                                            backgroundColor: kGold,
                                            foregroundColor:
                                                const Color(0xFF0A0A0F),
                                            padding: const EdgeInsets.symmetric(
                                                vertical: kSpace16),
                                            shape: RoundedRectangleBorder(
                                                borderRadius:
                                                    BorderRadius.circular(28)),
                                            elevation: 0,
                                          ),
                                          child: const Text('CLEAR FILTERS',
                                              style: TextStyle(
                                                  fontWeight: FontWeight.w900,
                                                  fontSize: 16,
                                                  letterSpacing: 0.5)),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(height: kSpace12),
                                    SizedBox(
                                      width: double.infinity,
                                      child: OutlinedButton(
                                        onPressed: () => setState(() {
                                          _ignoreGameFilter = true;
                                          _filter = 'all';
                                          _searchCtrl.clear();
                                          _search = '';
                                          _feeFilter = 'any';
                                          _sort = null;
                                        }),
                                        style: OutlinedButton.styleFrom(
                                          side: BorderSide(
                                              color: kGold, width: 1.5),
                                          padding: const EdgeInsets.symmetric(
                                              vertical: kSpace16),
                                          shape: RoundedRectangleBorder(
                                              borderRadius:
                                                  BorderRadius.circular(28)),
                                        ),
                                        child: Text('EXPLORE GAMES',
                                            style: TextStyle(
                                                color: kGold,
                                                fontWeight: FontWeight.w900,
                                                fontSize: 16,
                                                letterSpacing: 0.5)),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        );
                      }
                      // Recommended (expansion 2): most-joined upcoming
                      // tournaments first in a slim header row — real
                      // counts, never invented.
                      // 2026-11-20: the list renders the shared
                      // horizontal _TournamentCard (mockup #37: cover
                      // left, status pill, players + gold bar, Details
                      // + Join/Watch) — the migration the card's doc
                      // anticipated. The old vertical tournamentCard
                      // stays for Home My Contests only.
                      final recommended = list
                          .where((t) => tStatus(t) == 'upcoming')
                          .toList()
                        ..sort((a, b) => (counts[strVal(b['id'])] ?? 0)
                            .compareTo(counts[strVal(a['id'])] ?? 0));
                      final top3 = recommended.take(3).toList();
                      final shown = list.take(_visible).toList();
                      final items = <Widget>[];
                      if (top3.isNotEmpty &&
                          _search.isEmpty &&
                          _filter == 'all') {
                        items.add(Padding(
                            padding: EdgeInsets.only(bottom: kSpace8),
                            child: Text('Recommended for you (most joined)',
                                style: kStyleMeta.copyWith(
                                    color: kGold,
                                    fontWeight: FontWeight.bold))));
                        for (final t in top3) {
                          final tid = strVal(t['id']);
                          items.add(Padding(
                              padding: const EdgeInsets.only(bottom: kSpace12),
                              child: _TournamentCard(
                                  tournament: t,
                                  joined: myJoined.contains(tid),
                                  joinedCount: counts[tid] ?? 0)));
                        }
                        items.add(Padding(
                            padding: EdgeInsets.only(bottom: kSpace8),
                            child: Text('All tournaments',
                                style: kStyleMeta.copyWith(
                                    color: kGold,
                                    fontWeight: FontWeight.bold))));
                      }
                      for (final t in shown) {
                        final tid = strVal(t['id']);
                        items.add(Padding(
                            padding: const EdgeInsets.only(bottom: kSpace12),
                            child: _TournamentCard(
                                tournament: t,
                                joined: myJoined.contains(tid),
                                joinedCount: counts[tid] ?? 0)));
                      }
                      if (list.length > _visible) {
                        items.add(Padding(
                          padding: const EdgeInsets.only(bottom: kSpace12),
                          child: SizedBox(
                              width: double.infinity,
                              child: ArenaOutlinedButton(
                                  onPressed: () =>
                                      setState(() => _visible += 20),
                                  child: Text(
                                      'Load more (${list.length - _visible} remaining)',
                                      style: TextStyle(color: kGold)))),
                        ));
                      }
                      // Wave 4b #7: results exist, so the search +
                      // fee/sort rows render above the list (hidden
                      // on the empty state, per the mockup frame).
                      return Column(
                        children: [
                          _searchField(),
                          _feeSortRow(),
                          Expanded(
                              child: ListView(
                                  padding: const EdgeInsets.all(kSpace16),
                                  children: items)),
                        ],
                      );
                    },
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

class _PresenceContextUpdater extends StatefulWidget {
  final String tournamentId;
  final String squadId;
  final Widget child;
  const _PresenceContextUpdater(
      {required this.tournamentId, required this.squadId, required this.child});
  @override
  State<_PresenceContextUpdater> createState() =>
      _PresenceContextUpdaterState();
}

class _PresenceContextUpdaterState extends State<_PresenceContextUpdater> {
  @override
  void initState() {
    super.initState();
    PresenceService.updateContext(
        currentTournamentId: widget.tournamentId, squadId: widget.squadId);
  }

  @override
  void didUpdateWidget(_PresenceContextUpdater oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tournamentId != widget.tournamentId ||
        oldWidget.squadId != widget.squadId) {
      PresenceService.updateContext(
          currentTournamentId: widget.tournamentId, squadId: widget.squadId);
    }
  }

  @override
  void dispose() {
    // Leaving the Detail page ends this tournament context: mark
    // offline now instead of lingering green until staleness. A fresh
    // Detail entry (initState above) or app resume re-heartbeats.
    PresenceService.goOffline();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Live match countdown (expansion 2): ticks every 30 seconds from
/// the tournament start time. Shows days/hours/minutes until start,
/// "LIVE" while ongoing, nothing useful invented when no start time.
class _LiveCountdown extends StatefulWidget {
  final int startMs;
  final String status;
  const _LiveCountdown({required this.startMs, required this.status});
  @override
  State<_LiveCountdown> createState() => _LiveCountdownState();
}

class _LiveCountdownState extends State<_LiveCountdown> {
  late final Timer _timer;
  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.status == 'ongoing') {
      return Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
              color: Colors.redAccent, borderRadius: BorderRadius.circular(12)),
          child: const Text('● LIVE',
              style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 12)));
    }
    if (widget.startMs <= 0) return const SizedBox.shrink();
    final diff = widget.startMs - DateTime.now().millisecondsSinceEpoch;
    if (diff <= 0)
      return Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
              color: kCardFillColor, borderRadius: BorderRadius.circular(12)),
          child: Text('Starting soon',
              style: TextStyle(
                  color: kGold, fontWeight: FontWeight.bold, fontSize: 12)));
    final days = diff ~/ 86400000;
    final hours = (diff % 86400000) ~/ 3600000;
    final mins = (diff % 3600000) ~/ 60000;
    final label = days > 0
        ? '$days d $hours h left'
        : hours > 0
            ? '$hours h $mins m left'
            : '$mins m left';
    return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
            color: kCardFillColor, borderRadius: BorderRadius.circular(12)),
        child: Text('⏳ $label',
            style: TextStyle(
                color: kGold, fontWeight: FontWeight.bold, fontSize: 12)));
  }
}

/// Session dedupe for match-start reminders (detail page only).
final Set<String> _remindedTournaments = {};

/// Wave B #26 — one MATCH INFO / SCHEDULE cell: small muted label,
/// bold white value underneath. "—" when the value does not exist
/// (never an invented map / perspective). With an icon (MATCH INFO,
/// mockup #26) the cell is centred with the gold icon on top.
/// S1 redesign (guide §6 Screen 1) — one cell of the Tournament
/// Details metadata card: gold icon + bold white value, wrapping to
/// 2 lines at a word boundary instead of truncating (same standing
/// rule as _detailInfoCell: "Nov 22, 8:00 PM" and "PUBG Mobile" are
/// wider than one cell of a 4-cell row).
Widget _detailMetaCell(IconData icon, String value,
    {TextAlign align = TextAlign.left}) {
  return Expanded(
    child: Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: align == TextAlign.center
          ? MainAxisAlignment.center
          : (align == TextAlign.right
              ? MainAxisAlignment.end
              : MainAxisAlignment.start),
      children: [
        Icon(icon, color: hGold, size: 16),
        const SizedBox(width: 6),
        Flexible(
          child: Text(value,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.bold),
              textAlign: align,
              maxLines: 2,
              overflow: TextOverflow.ellipsis),
        ),
      ],
    ),
  );
}

Widget _detailInfoCell(String label, String value, [IconData? icon]) {
  final centered = icon != null;
  return Expanded(
    child: Column(
      crossAxisAlignment:
          centered ? CrossAxisAlignment.center : CrossAxisAlignment.start,
      children: [
        if (icon != null) ...[
          Icon(icon, color: hGold, size: 18),
          const SizedBox(height: 4),
        ],
        // Detail fix (2026-11-21, standing rule): the label scales
        // down instead of breaking mid-word — "Perspec tive" /
        // "Match Starts" wrapping was the user's screenshot #1/#3.
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: centered ? Alignment.center : Alignment.centerLeft,
          child: Text(label,
              style: const TextStyle(color: hText2, fontSize: 11),
              textAlign: centered ? TextAlign.center : TextAlign.left),
        ),
        const SizedBox(height: 3),
        Text(value,
            style: const TextStyle(
                color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
            // Detail fix (2026-11-21): 2 lines so "4 Players" wraps
            // at the word boundary instead of truncating to "4 Pla...".
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: centered ? TextAlign.center : TextAlign.left),
      ],
    ),
  );
}

/// Detail fix (2026-11-21, standing rule) — one MATCH INFO /
/// SCHEDULE row: gold icon + muted label on the left, bold white
/// value on the right, full card width. The old 3-across MATCH INFO
/// layout gave each cell ~45px and broke "Perspec tive" + truncated
/// "4 Pla..."; one row per fact always fits ("Perspective" + "TPP",
/// "Team Size" + "4 Players"). The value wraps to 2 lines at a
/// word boundary rather than truncating.
Widget _detailInfoRow(String label, String value, [IconData? icon]) {
  return Row(
    children: [
      if (icon != null) ...[
        Icon(icon, color: hGold, size: 18),
        const SizedBox(width: 6),
      ],
      // v2011 fix: the label must shrink instead of overflowing the
      // narrow (~135px) MATCH INFO card — "Perspective" alone is
      // 132px in the test font and ~2px over even on a real device.
      // Flexible + FittedBox scaleDown: short labels keep their
      // natural size, long ones shrink to fit (same pattern as
      // _detailInfoCell). No visual change on device for the
      // current labels ('Map'/'Perspective'/'Team Size').
      Flexible(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(label, style: const TextStyle(color: hText2, fontSize: 12)),
        ),
      ),
      const SizedBox(width: 6),
      Expanded(
        child: Text(value,
            style: const TextStyle(
                color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
            textAlign: TextAlign.right,
            maxLines: 2,
            overflow: TextOverflow.ellipsis),
      ),
    ],
  );
}

/// Wave B #26 — rules as gold bullets in the mockup's TWO-COLUMN
/// layout ("• Level 30+ required" | "• No emulators"). Real `rules`
/// text, one bullet per line; `level_required` is NOT live (draft
/// 020) so no level bullet is invented; a tournament with no rules
/// shows the app's real generic fair-play rules (same text the Join
/// page shows).
Widget _ruleBullets(Map<String, dynamic> t) {
  final raw = strVal(t['rules']);
  final lines = raw.isEmpty
      ? [
          'Fair play: no cheating, no abusive language, no account sharing. Follow the room instructions from the organizer. Violations may lead to disqualification.'
        ]
      : raw
          .split('\n')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
  final level = intVal(t['level_required'], 0);
  final items = <String>[if (level > 0) 'Level $level+ required', ...lines];
  return LayoutBuilder(
    builder: (context, constraints) {
      final w = (constraints.maxWidth - 16) / 2;
      return Wrap(
        spacing: 16,
        runSpacing: 6,
        children: [
          for (final line in items)
            SizedBox(
              width: w,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('•  ',
                      style: TextStyle(
                          color: hGold,
                          fontSize: 14,
                          fontWeight: FontWeight.bold)),
                  Expanded(
                      child: Text(line,
                          style: const TextStyle(
                              color: hText2, fontSize: 14, height: 1.4))),
                ],
              ),
            ),
        ],
      );
    },
  );
}

class TournamentDetailPage extends StatelessWidget {
  final Map<String, dynamic> tournament;
  const TournamentDetailPage({super.key, required this.tournament});

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser!.uid;
    final id = strVal(tournament['id']);
    // LIVE detail stream on the tournament row + registrations stream,
    // so "You have joined" appears immediately after joining. Wrapped
    // in the refresh notifier (same Realtime-publication caveat as the
    // list page): a bump after any Join pop forces a fresh fetch even
    // when no postgres_changes event fires.
    return ValueListenableBuilder<int>(
      valueListenable: SupaDb.refreshNotifier,
      builder: (context, nonce, _) {
        return StreamBuilder<Map<String, dynamic>>(
          key: ValueKey('detail-$nonce'),
          stream: SupaDb.streamTournament(id),
          builder: (context, snap) {
            var t = tournament;
            if (snap.hasData && (snap.data ?? {}).isNotEmpty) t = snap.data!;
            return StreamBuilder<List<Map<String, dynamic>>>(
              stream: SupaDb.streamRegistrations(id),
              builder: (context, rsnap) {
                final regs = rsnap.data ?? [];
                final myReg = regs
                    .where((r) => strVal(r['firebase_uid']) == uid)
                    .toList();
                final joined = myReg.isNotEmpty;
                // P0-1: count PLAYERS, not rows x teamSize (RPC rows
                // are one-per-member).
                final joinedCount = SupaDb.registrationPlayerCount(regs);
                final maxP = intVal(t['maxPlayers'], 0);
                final status = tStatus(t);
                final fee = numVal(t['entryFee']);
                final myTeam = joined ? strVal(myReg.first['team_name']) : '';
                final mySquad = joined ? squadIdFor(id, myTeam) : '';
                // Check-in team id (integration 2026-11-21): the squad id
                // for team modes; solo registrations have no squad, so the
                // registration id (else the uid) identifies the entrant.
                final checkInTeamId = mySquad.isNotEmpty
                    ? mySquad
                    : (joined && strVal(myReg.first['id']).isNotEmpty
                        ? strVal(myReg.first['id'])
                        : uid);
                // Room gating: shared helper (Phase 2) — show only if
                // show_id_pass AND (ongoing OR upcoming + within 10 min
                // before start). Same rule in MatchDetails/MatchRoom.
                final startMs = intVal(t['startTime']);
                final roomVisible = roomVisibleFor(t);
                // FULL COMPLETION expansion 1: match-start reminder —
                // upcoming + joined + starts within 60 min => one in-app
                // notification (deduped per session + per existing rows).
                if (joined &&
                    status == 'upcoming' &&
                    startMs > 0 &&
                    (startMs - DateTime.now().millisecondsSinceEpoch) <=
                        60 * 60 * 1000 &&
                    (startMs - DateTime.now().millisecondsSinceEpoch) > 0 &&
                    !_remindedTournaments.contains(id)) {
                  _remindedTournaments.add(id);
                  Future.microtask(() async {
                    try {
                      final existing = await SupaDb.getNotifications(uid);
                      final already = existing.any((n) =>
                          SupaDb.strOf(n['title']) == 'Match starting soon' &&
                          SupaDb.strOf(n['message']).contains(tName(t)));
                      if (!already)
                        await SupaDb.notifyUser(uid, 'Match starting soon',
                            '${tName(t)} 1 ghante se kam me shuru ho raha hai — room me aa jayen!');
                    } catch (_) {}
                  });
                }
                final isFull = maxP > 0 && joinedCount >= maxP;
                return Scaffold(
                  // Wave B #26: mockup AppBar — "TOURNAMENT DETAILS"
                  // title + share (Save Event moved to the bottom bar).
                  appBar: AppBar(
                    backgroundColor: Colors.transparent, // PHASE E (E4): transparent header — poster shows through
                    // S1 redesign: clean dark header — flat, no
                    // shadow, white back/share icons.
                    elevation: 0,
                    scrolledUnderElevation: 0,
                    iconTheme: const IconThemeData(color: Colors.white),
                    // FIX ROUND I-all-fix1-A (#26): mockup title is
                    // centered, not left-aligned.
                    centerTitle: true,
                    title: const FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.center,
                        child: Text('TOURNAMENT DETAILS',
                            style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w900,
                                fontStyle: FontStyle.italic,
                                fontSize: 26))),
                    actions: [
                      IconButton(
                        icon: const Icon(Icons.share, color: Colors.white),
                        tooltip: 'Share',
                        onPressed: () async {
                          final link = 'protournament://tournament/$id';
                          final text =
                              'Join ${tName(t)} on ARENA HUB! Tournament link: $link (App me Tournaments → search karen ya link paste karen)';
                          final uri = Uri.parse(
                              'https://wa.me/?text=${Uri.encodeComponent(text)}');
                          if (await canLaunchUrl(uri))
                            await launchUrl(uri,
                                mode: LaunchMode.externalApplication);
                        },
                      ),
                    ],
                  ),
                  // Wave B #26: mockup bottom bar — Save Event (real
                  // device-local toggle) + JOIN TOURNAMENT (2026-11-21
                  // FINAL list #5: "JOIN COMMUNITY EVENT" confused
                  // players joining a tournament). The
                  // primary button follows the real join state; the
                  // in-body Join button is gone (no duplicate CTA).
                  bottomNavigationBar: Container(
                    color: hBg,
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
                    child: SafeArea(
                      top: false,
                      child: Row(
                        children: [
                          Expanded(
                              child: _SaveEventBarButton(tournamentId: id)),
                          const SizedBox(width: 10),
                          Expanded(
                            flex: 2,
                            // J-detail-fix1 (#26): the mockup's JOIN
                            // button has a soft gold glow under it.
                            child: Container(
                              decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(28),
                                  boxShadow: _goldGlow()),
                              child: ElevatedButton(
                                onPressed:
                                    (!joined && status == 'upcoming' && !isFull)
                                        ? () async {
                                            await Navigator.push(
                                                context,
                                                MaterialPageRoute(
                                                    builder: (_) =>
                                                        JoinTournamentPage(
                                                            tournament: t)));
                                            SupaDb.bumpRefresh();
                                          }
                                        : null,
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: hGold,
                                  // S1 redesign: JOINED green is the
                                  // app green token (kGreen) with dark
                                  // text — and ONLY in the joined
                                  // state; closed/full stay muted with
                                  // white text. Behaviour unchanged.
                                  disabledBackgroundColor:
                                      joined ? kGreen : hSecondary,
                                  disabledForegroundColor: joined
                                      ? const Color(0xFF0A0A0F)
                                      : Colors.white,
                                  foregroundColor: const Color(0xFF0A0A0F),
                                  padding: const EdgeInsets.symmetric(
                                      vertical: 14, horizontal: 8),
                                  shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(28)),
                                  elevation: 0,
                                ),
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Text(
                                    joined
                                        ? '✓ JOINED'
                                        : (status != 'upcoming'
                                            ? 'REGISTRATION CLOSED'
                                            : (isFull
                                                ? 'FULL'
                                                : 'JOIN TOURNAMENT  ›')),
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w900,
                                        fontSize: 15),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  body: _PresenceContextUpdater(
                    tournamentId: id,
                    squadId: mySquad,
                    child: SingleChildScrollView(
                      // Detail fix (2026-11-21, FINAL list #8 +
                      // standing rule): 32px bottom padding so the
                      // Prize / Entry Fee / Spots / Per Kill card
                      // (and the page tail) scroll fully above the
                      // bottom bar instead of sitting half hidden
                      // behind it.
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Wave B #26 — mockup hero: real banner_url
                          // cover (never mock game art) with the real
                          // status pill top-left and the REAL name in
                          // big prominent white text over a bottom
                          // gradient.
                          // S1 redesign (guide §6 Screen 1): the hero
                          // is inset with ROUNDED corners
                          // (kRadiusHero) — the old full-bleed
                          // square-corner OverflowBox is gone. Same
                          // height (210), same gradient, same pill,
                          // same title position; only the frame and
                          // the title colour (all white now) changed.
                          ClipRRect(
                            borderRadius:
                                BorderRadius.circular(kRadiusHero),
                            child: SizedBox(
                              height: 210,
                              width: double.infinity,
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  _coverImage(tImage(t)),
                                  Container(
                                    decoration: BoxDecoration(
                                      gradient: LinearGradient(
                                        begin: Alignment.topCenter,
                                        end: Alignment.bottomCenter,
                                        colors: [
                                          Colors.transparent,
                                          Colors.black.withValues(alpha: 0.45),
                                          Colors.black.withValues(alpha: 0.85)
                                        ],
                                      ),
                                    ),
                                  ),
                                  // Mockup #26 hero pill: UPCOMING is a
                                  // GOLD OUTLINE pill (transparent bg,
                                  // gold border + gold text), not solid
                                  // gold.
                                  Positioned(
                                    top: 12,
                                    left: 12,
                                    child: status == 'upcoming'
                                        ? _goldPill('UPCOMING',
                                            bg: Colors.transparent,
                                            fg: hGold,
                                            border: hGold)
                                        : _statusPill2(status),
                                  ),
                                  Positioned(
                                    left: 14,
                                    right: 14,
                                    bottom: 14,
                                    // S1 redesign: prominent WHITE
                                    // title (guide §6 Screen 1) — the
                                    // two-tone gold/white title is
                                    // gone on this screen. Same 40px
                                    // w900 italic; maxLines 2 so a
                                    // long name wraps instead of
                                    // overflowing the hero.
                                    child: Text(
                                      tName(t),
                                      style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 40,
                                          fontWeight: FontWeight.w900,
                                          fontStyle: FontStyle.italic,
                                          height: 1.05),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: kSpace12),
                          // S1 redesign (guide §6 Screen 1): date/time,
                          // mode, game AND player count in ONE aligned
                          // metadata card — four equal cells, gold
                          // icons, dividers between. Same values as
                          // the old strip (the player count is the
                          // same joined/max count the registration
                          // card shows); every value still wraps to
                          // 2 lines at a word boundary, never cut.
                          _DarkMockupCard(
                            padding: const EdgeInsets.all(kSpace16),
                            radius: kRadiusCard,
                            child: Row(
                              children: [
                                _detailMetaCell(Icons.calendar_today,
                                    _shortDate(startMs)),
                                Container(
                                    width: 1, height: 18, color: hBorder),
                                _detailMetaCell(Icons.group,
                                    strVal(t['mode'], 'Solo'),
                                    align: TextAlign.center),
                                Container(
                                    width: 1, height: 18, color: hBorder),
                                _detailMetaCell(
                                    Icons.sports_esports,
                                    tGame(t).isEmpty ? 'Arena' : tGame(t),
                                    align: TextAlign.center),
                                Container(
                                    width: 1, height: 18, color: hBorder),
                                _detailMetaCell(
                                    Icons.people,
                                    maxP > 0
                                        ? '$joinedCount / $maxP'
                                        : '$joinedCount',
                                    align: TextAlign.center),
                              ],
                            ),
                          ),
                          const SizedBox(height: kSpace16),
                          // Mockup registration card: real status + real
                          // joined/max players + gold bar.
                          // 2026-11-20 USER CORRECTION (global card rule):
                          // the full gold border + glow are gone — the
                          // card is a _DarkMockupCard (gradient fill +
                          // two orbiting yellow shines, no static border).
                          _DarkMockupCard(
                            padding: const EdgeInsets.all(kSpace16),
                            radius: kRadiusCard,
                            child: Column(
                              children: [
                                Row(
                                  children: [
                                    // S1 redesign (guide §6 Screen 1):
                                    // Match Live is a RED badge now
                                    // (ArenaLiveBadge), not a dot +
                                    // text. Other states keep their
                                    // dot + label, unchanged.
                                    if (status == 'ongoing')
                                      const ArenaLiveBadge()
                                    else ...[
                                      Container(
                                          width: 10,
                                          height: 10,
                                          decoration: BoxDecoration(
                                              shape: BoxShape.circle,
                                              color: status == 'upcoming'
                                                  ? hGreen
                                                  : hText2)),
                                      const SizedBox(width: 8),
                                      Text(
                                          status == 'upcoming'
                                              ? 'Registration Open'
                                              : 'Registration Closed',
                                          style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 15,
                                              fontWeight: FontWeight.bold)),
                                    ],
                                    const Spacer(),
                                    // Standing rule (2026-11-21): the
                                    // count wraps instead of overflowing
                                    // the row on big player counts.
                                    Flexible(
                                      child: Text(
                                          maxP > 0
                                              ? '$joinedCount / $maxP Players'
                                              : '$joinedCount Players',
                                          style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 15,
                                              fontWeight: FontWeight.bold),
                                          textAlign: TextAlign.right,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis),
                                    ),
                                  ],
                                ),
                                if (maxP > 0) ...[
                                  const SizedBox(height: 10),
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(3),
                                    child: LinearProgressIndicator(
                                        value: (joinedCount / maxP)
                                            .clamp(0.0, 1.0),
                                        minHeight: 6,
                                        backgroundColor: hBorder,
                                        valueColor:
                                            const AlwaysStoppedAnimation<Color>(
                                                hGold)),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          // Detail fix (2026-11-21, FINAL list #7):
                          // the OVERVIEW section always renders —
                          // empty / dummy text ("test description"
                          // is live on Pro Tour) shows "No
                          // description added yet" instead of the
                          // dummy, never a hidden section.
                          // S1 redesign (guide §6 Screen 1): Overview
                          // is its own dark card now (header inside
                          // the card, like MATCH INFO / SCHEDULE),
                          // not a bare header + text. Same text, same
                          // placeholder behaviour.
                          const SizedBox(height: kSpace20),
                          _DarkMockupCard(
                            padding: const EdgeInsets.all(kSpace16),
                            radius: kRadiusCard,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _homeSectionHeader('TOURNAMENT OVERVIEW'),
                                const SizedBox(height: kSpace8),
                                Text(
                                    displayTournamentDescription(
                                        strVal(t['description'])),
                                    style: kStyleBody.copyWith(
                                        color: hText2, height: 1.5)),
                              ],
                            ),
                          ),
                          const SizedBox(height: kSpace20),
                          // Mockup MATCH INFO + SCHEDULE side by side.
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: _DarkMockupCard(
                                  padding: const EdgeInsets.all(kSpace12),
                                  radius: kRadiusCard,
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      const Text('MATCH INFO',
                                          style: TextStyle(
                                              color: Colors.white,
                                              fontWeight: FontWeight.w900,
                                              fontSize: 15)),
                                      const SizedBox(height: 10),
                                      // Detail fix (2026-11-21, FINAL
                                      // list #2/#4 + standing rule): one
                                      // row per fact, full card width —
                                      // Map from tags ("Erangle" ->
                                      // "Erangel"), Perspective defaults
                                      // TPP, Team Size full "4 Players".
                                      // The old 3-across cells gave each
                                      // ~45px and broke "Perspec tive"
                                      // + truncated "4 Pla...".
                                      _detailInfoRow('Map',
                                          matchInfoMapName(t), Icons.map),
                                      const SizedBox(height: 10),
                                      _detailInfoRow('Perspective',
                                          matchInfoPerspective(t),
                                          Icons.visibility),
                                      const SizedBox(height: 10),
                                      _detailInfoRow('Team Size',
                                          matchInfoTeamSizeLabel(t),
                                          Icons.group),
                                    ],
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: _DarkMockupCard(
                                  padding: const EdgeInsets.all(kSpace12),
                                  radius: kRadiusCard,
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      const Text('SCHEDULE',
                                          style: TextStyle(
                                              color: Colors.white,
                                              fontWeight: FontWeight.w900,
                                              fontSize: 15)),
                                      const SizedBox(height: 10),
                                      Row(
                                        children: [
                                          _detailInfoCell(
                                              'Lobby Opens',
                                              _timeOnly(
                                                  lobbyOpensMsFor(t))),
                                          // Detail fix (2026-11-21,
                                          // FINAL list #6): the gap
                                          // that stops "Lobby Opens"
                                          // and "Match Starts" running
                                          // together.
                                          const SizedBox(width: 12),
                                          _detailInfoCell('Match Starts',
                                              _timeOnly(startMs)),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: kSpace20),
                          // S1 redesign (guide §6 Screen 1): Rules is
                          // its own dark card now (header inside the
                          // card), not a bare header + bullets. Same
                          // bullets, same generic fair-play fallback.
                          _DarkMockupCard(
                            padding: const EdgeInsets.all(kSpace16),
                            radius: kRadiusCard,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _homeSectionHeader('TOURNAMENT RULES'),
                                const SizedBox(height: kSpace8),
                                _ruleBullets(t),
                              ],
                            ),
                          ),
                          // Detail fix (2026-11-21, FINAL list #1):
                          // the tags chips ("Squad" / "Erangle") are
                          // GONE from below Tournament Rules — their
                          // values now live INSIDE the MATCH INFO box
                          // (matchInfoMapName / matchInfoPerspective /
                          // matchInfoTeamSizeLabel above).
                          if (t['prizeDistribution'] != null) ...[
                            const SizedBox(height: 12),
                            const Text('Prize Distribution',
                                style: TextStyle(
                                    color: hGold, fontWeight: FontWeight.bold)),
                            const SizedBox(height: 4),
                            Text(_prizeDistText(t['prizeDistribution']),
                                style: const TextStyle(color: Colors.white)),
                          ],
                          const SizedBox(height: 16),
                          // Prize / fee / spots strip (below the mockup
                          // fold): the mockup top shows none of these,
                          // but they are real tournament facts the page
                          // must keep visible. 2026-11-20: _DarkMockupCard
                          // (global card rule — no full border).
                          _DarkMockupCard(
                            padding: const EdgeInsets.all(kSpace16),
                            radius: kRadiusCard,
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceAround,
                              children: [
                                _detailStat(
                                    'Prize', fmtRs(numVal(t['prizePool']))),
                                _detailStat('Entry Fee',
                                    fee == 0 ? 'Free' : fmtRs(fee)),
                                _detailStat(
                                    'Spots',
                                    maxP > 0
                                        ? '$joinedCount / $maxP'
                                        : '$joinedCount'),
                                if (numVal(t['perKillPrize']) > 0)
                                  _detailStat('Per Kill',
                                      fmtRs(numVal(t['perKillPrize']))),
                              ],
                            ),
                          ),
                          // Watch Live (2026-11-21; FIX 6 2026-11-22
                          // free spectating): in-app embed + own live
                          // comments for EVERYONE — no joined
                          // requirement, spectating is free — shown
                          // whenever the admin switched the stream on
                          // (show_watch_live + URL). Before this the
                          // button opened YouTube externally.
                          if (watchLiveVisibleFor(t)) ...[
                            const SizedBox(height: 16),
                            SizedBox(
                              width: double.infinity,
                              child: ElevatedButton.icon(
                                onPressed: () {
                                  Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                          builder: (_) => WatchLiveScreen(
                                                tournamentId: id,
                                                tournamentName: tName(t),
                                                watchUrl:
                                                    watchLiveUrlOf(t),
                                              )));
                                },
                                icon: const Icon(Icons.live_tv,
                                    color: Colors.black),
                                label: const Text('Watch Live',
                                    style: TextStyle(
                                        color: Colors.black,
                                        fontWeight: FontWeight.bold)),
                                style: ElevatedButton.styleFrom(
                                    backgroundColor: kGold,
                                    padding: const EdgeInsets.symmetric(
                                        vertical: 13)),
                              ),
                            ),
                          ],
                          // v2013 (FIX 6 2026-11-22: no joined
                          // requirement — spectating is free): ANY
                          // viewer on a LIVE tournament with no
                          // stream URL sees the note plainly instead
                          // of a missing button and no explanation.
                          if (watchLiveUrlNoteVisibleFor(t)) ...[
                            const SizedBox(height: 16),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Icon(Icons.live_tv,
                                    color: kMuted, size: 16),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    'Live stream URL set nahi hai.',
                                    style: TextStyle(
                                        color: kMuted, fontSize: 13),
                                  ),
                                ),
                              ],
                            ),
                          ],
                          const SizedBox(height: 16),
                          // Join lives in the bottom bar now (#26 mockup);
                          // only the closed / full states stay in-body.
                          if (!joined && status != 'upcoming')
                            Text('Registration is closed for this tournament.',
                                style: TextStyle(color: kMuted)),
                          if (!joined && status == 'upcoming' && isFull) ...[
                            const Text('This tournament is full.',
                                style: TextStyle(color: Colors.redAccent)),
                            const SizedBox(height: 8),
                            SizedBox(
                              width: double.infinity,
                              child: OutlinedButton(
                                onPressed: () async {
                                  try {
                                    await SupaDb.client
                                        .from('waitlists')
                                        .insert({
                                      'tournament_id': id,
                                      'firebase_uid': uid
                                    });
                                    if (context.mounted)
                                      toast(context,
                                          'Waitlist me add ho gaye! Slot khali hote hi admin aapko batayega.');
                                  } catch (e) {
                                    if (context.mounted)
                                      toast(context,
                                          'Waitlist pending hai (migration 008 chalani hogi) ya aap pehle se waitlist me hain.');
                                  }
                                },
                                style: OutlinedButton.styleFrom(
                                    side: BorderSide(color: kGold)),
                                child: Text('Join Waitlist',
                                    style: TextStyle(color: kGold)),
                              ),
                            ),
                            const SizedBox(height: 8),
                            SizedBox(
                              width: double.infinity,
                              child: OutlinedButton(
                                // Blueprint waitlist page (integration
                                // 2026-11-21): position + leave. The
                                // server `waitlists` insert above stays
                                // the live admin-visible flow.
                                onPressed: () => Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                        builder: (_) => WaitlistPage(
                                            tournamentId: id, myUid: uid))),
                                style: OutlinedButton.styleFrom(
                                    side: BorderSide(color: kGold)),
                                child: Text(
                                    tr('View Waitlist', 'Waitlist dekhein'),
                                    style: TextStyle(color: kGold)),
                              ),
                            ),
                          ],
                          if (joined) ...[
                            Text('You have joined this tournament.',
                                style: TextStyle(
                                    color: kGold, fontWeight: FontWeight.bold)),
                            const SizedBox(height: 10),
                            // SUBMIT RESULT entry point (2026-11-21):
                            // the ONLY way to reach UploadResultPage
                            // was the Room ID dialog ("Upload Result
                            // Screenshot"). A finished match the player
                            // registered for now shows this gold button
                            // here too. The start-time rule covers
                            // matches whose status was never flipped
                            // to completed — same rule the submit page
                            // itself enforces, so the button never
                            // leads to a dead end.
                            if (canSubmitResultFor(
                                joined: joined,
                                status: status,
                                startMs: startMs)) ...[
                              SizedBox(
                                width: double.infinity,
                                child: ElevatedButton.icon(
                                  onPressed: () => Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                          builder: (_) => UploadResultPage(
                                              tournamentId: id))),
                                  icon: const Icon(Icons.upload, size: 20),
                                  label: const Text('SUBMIT RESULT',
                                      style: TextStyle(
                                          fontWeight: FontWeight.w900,
                                          fontSize: 16)),
                                  style: ElevatedButton.styleFrom(
                                      backgroundColor: kGold,
                                      foregroundColor: Colors.black,
                                      padding: const EdgeInsets.symmetric(
                                          vertical: 14),
                                      shape: RoundedRectangleBorder(
                                          borderRadius:
                                              BorderRadius.circular(14)),
                                      elevation: 0),
                                ),
                              ),
                              const SizedBox(height: 10),
                            ],
                            // Phase 2: Match Details (#14) + Match Room
                            // (#19) entry for joined players.
                            Row(children: [
                              Expanded(
                                child: OutlinedButton(
                                  onPressed: () => Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                          builder: (_) =>
                                              MatchDetailsPage(tournament: t))),
                                  style: OutlinedButton.styleFrom(
                                      side: BorderSide(color: kGold),
                                      backgroundColor:
                                          kGold.withValues(alpha: 0.08)),
                                  child: Text('Match Details',
                                      style: TextStyle(color: kGold)),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: OutlinedButton(
                                  onPressed: () => Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                          builder: (_) =>
                                              MatchRoomPage(tournament: t))),
                                  style: OutlinedButton.styleFrom(
                                      side: BorderSide(color: kGold),
                                      backgroundColor:
                                          kGold.withValues(alpha: 0.08)),
                                  child: Text('Match Room',
                                      style: TextStyle(color: kGold)),
                                ),
                              ),
                            ]),
                            const SizedBox(height: 10),
                            // MATCH CENTER (integration 2026-11-21, ChatGPT
                            // blueprint): check-in, tournament leaderboard,
                            // dispute center for joined players.
                            Row(children: [
                              Expanded(
                                child: OutlinedButton(
                                  onPressed: () => Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                          builder: (_) => CheckInPage(
                                              tournamentId: id,
                                              teamId: checkInTeamId,
                                              captainUid: strVal(myReg
                                                  .first['firebase_uid'])))),
                                  style: OutlinedButton.styleFrom(
                                      side: BorderSide(color: kGold),
                                      backgroundColor:
                                          kGold.withValues(alpha: 0.08)),
                                  child: Text(tr('Check In', 'Check In'),
                                      style: TextStyle(color: kGold)),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: OutlinedButton(
                                  onPressed: () => Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                          builder: (_) => ScopedLeaderboardPage(
                                              tournamentId: id))),
                                  style: OutlinedButton.styleFrom(
                                      side: BorderSide(color: kGold),
                                      backgroundColor:
                                          kGold.withValues(alpha: 0.08)),
                                  child: Text(tr('Leaderboard', 'Leaderboard'),
                                      style: TextStyle(color: kGold)),
                                ),
                              ),
                            ]),
                            const SizedBox(height: 10),
                            SizedBox(
                              width: double.infinity,
                              child: OutlinedButton(
                                onPressed: () => Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                        builder: (_) => DisputeCenterPage(
                                            uid: uid, tournamentId: id))),
                                style: OutlinedButton.styleFrom(
                                    side: BorderSide(color: kGold)),
                                child: Text(
                                    tr('Dispute Center', 'Dispute Center'),
                                    style: TextStyle(color: kGold)),
                              ),
                            ),
                            // v2016 FIX 11(a) (user order 2026-11-22):
                            // the Tournament Room card is GONE from
                            // tournament details — voice rooms moved
                            // into communities / team chat.
                            // v2016 FIX 11(a): the Squad Room card is
                            // GONE too — squad voice now lives in the
                            // team's chat (TeamChatPage voice room).
                            const SizedBox(height: 10),
                            SizedBox(
                              width: double.infinity,
                              child: OutlinedButton(
                                onPressed: () async {
                                  // A-5 (026): admin-closed room never shows
                                  // credentials. B-11: credentials come ONLY
                                  // from getRoomCredentials (026 RPC) — the
                                  // tournament row is never read for them.
                                  // Read failure = ON (getRoomControl {}).
                                  final control =
                                      await SupaDb.getRoomControl(id);
                                  if (!context.mounted) return;
                                  if (SupaDb.isRoomVoiceDisabled(control)) {
                                    final reason = SupaDb.strOf(
                                        control['disabled_reason']);
                                    showInfoDialog(
                                        context,
                                        'Room band hai',
                                        reason.isNotEmpty
                                            ? 'Room band hai — $reason'
                                            : 'Room band hai — voice join abhi band hai.');
                                    return;
                                  }
                                  // B-11: fetch via the RPC before showing
                                  // anything. A failed call fails closed —
                                  // an honest error, never the row.
                                  final creds =
                                      await SupaDb.getRoomCredentials(id);
                                  if (!context.mounted) return;
                                  if (creds['ok'] != true) {
                                    showInfoDialog(
                                        context,
                                        'Room ID & Password',
                                        'Room details abhi load nahi ho sake — dobara try karein.');
                                    return;
                                  }
                                  final roomId =
                                      SupaDb.strOf(creds['roomId']);
                                  final roomPass =
                                      SupaDb.strOf(creds['roomPassword']);
                                  if (roomVisible) {
                                    showDialog<void>(
                                      context: context,
                                      builder: (_) => AlertDialog(
                                        backgroundColor: kCardPurpleMid,
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22), side: const BorderSide(color: kCardPurpleBorder, width: 1.5)),
                                        title: Text('Room ID & Password',
                                            style: TextStyle(color: kText)),
                                        content: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                                'Room ID: ${roomId.isEmpty ? 'Not announced yet' : roomId}',
                                                style: TextStyle(color: kText)),
                                            const SizedBox(height: 6),
                                            Text(
                                                'Password: ${roomPass.isEmpty ? 'Not announced yet' : roomPass}',
                                                style: TextStyle(color: kText)),
                                            const SizedBox(height: 12),
                                            Row(children: [
                                              Expanded(
                                                  child: OutlinedButton(
                                                      onPressed: () {
                                                        Clipboard.setData(
                                                            ClipboardData(
                                                                text: roomId));
                                                        toast(context,
                                                            'Room ID copied.');
                                                      },
                                                      style: OutlinedButton
                                                          .styleFrom(
                                                              side: BorderSide(
                                                                  color:
                                                                      kGold)),
                                                      child: Text('Copy ID',
                                                          style: TextStyle(
                                                              color: kGold)))),
                                              const SizedBox(width: 8),
                                              Expanded(
                                                  child: OutlinedButton(
                                                      onPressed: () {
                                                        Clipboard.setData(
                                                            ClipboardData(
                                                                text: roomPass));
                                                        toast(context,
                                                            'Password copied.');
                                                      },
                                                      style: OutlinedButton
                                                          .styleFrom(
                                                              side: BorderSide(
                                                                  color:
                                                                      kGold)),
                                                      child: Text(
                                                          'Copy Password',
                                                          style: TextStyle(
                                                              color: kGold)))),
                                            ]),
                                          ],
                                        ),
                                        actions: [
                                          TextButton(
                                              onPressed: () =>
                                                  Navigator.pop(context),
                                              child: Text('Close',
                                                  style:
                                                      TextStyle(color: kGold)))
                                        ],
                                      ),
                                    );
                                  } else {
                                    showInfoDialog(
                                        context,
                                        'Room ID & Password',
                                        'Hidden by Admin');
                                  }
                                },
                                style: OutlinedButton.styleFrom(
                                    side: BorderSide(color: kGold)),
                                child: Text(
                                    roomVisible
                                        ? 'Room ID / Password'
                                        : 'Room ID / Password — Hidden by Admin',
                                    style: TextStyle(color: kGold)),
                              ),
                            ),
                            const SizedBox(height: 10),
                            SizedBox(
                              width: double.infinity,
                              child: OutlinedButton(
                                onPressed: () => Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                        builder: (_) => UploadResultPage(
                                            tournamentId: id))),
                                style: OutlinedButton.styleFrom(
                                    side: BorderSide(color: kGold)),
                                child: Text('Upload Result Screenshot',
                                    style: TextStyle(color: kGold)),
                              ),
                            ),
                            const SizedBox(height: 10),
                            Row(children: [
                              Expanded(
                                child: OutlinedButton.icon(
                                  onPressed: () async {
                                    // Calendar reminder via Google Calendar
                                    // template URL (free, no plugin, no SMS).
                                    final start =
                                        DateTime.fromMillisecondsSinceEpoch(
                                            startMs,
                                            isUtc: true);
                                    final end =
                                        start.add(const Duration(hours: 2));
                                    String fmt(DateTime d) =>
                                        d
                                            .toUtc()
                                            .toIso8601String()
                                            .replaceAll(RegExp(r'[-:]'), '')
                                            .split('.')
                                            .first +
                                        'Z';
                                    final uri = Uri.parse(
                                        'https://calendar.google.com/calendar/render?action=TEMPLATE&text=${Uri.encodeComponent(tName(t))}&dates=${fmt(start)}/${fmt(end)}&details=${Uri.encodeComponent('ARENA HUB — ${tName(t)}')}');
                                    if (await canLaunchUrl(uri))
                                      await launchUrl(uri,
                                          mode: LaunchMode.externalApplication);
                                    // Phase 2: reminder write goes through
                                    // the data layer (check-before-insert).
                                    await SupaDb.setMatchReminder(id, uid);
                                    if (context.mounted)
                                      toast(context,
                                          'Calendar reminder khul gaya + in-app reminder set ho gaya.');
                                  },
                                  icon: Icon(Icons.calendar_month,
                                      color: kGold, size: 18),
                                  label: Text('Calendar Reminder',
                                      style: TextStyle(
                                          color: kGold, fontSize: 12)),
                                  style: OutlinedButton.styleFrom(
                                      side: BorderSide(color: kGold)),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: OutlinedButton.icon(
                                  onPressed: () async {
                                    final link =
                                        'protournament://tournament/$id';
                                    final text =
                                        'Join ${tName(t)} on ARENA HUB! Tournament link: $link (App me Tournaments → search karen ya link paste karen)';
                                    final uri = Uri.parse(
                                        'https://wa.me/?text=${Uri.encodeComponent(text)}');
                                    if (await canLaunchUrl(uri))
                                      await launchUrl(uri,
                                          mode: LaunchMode.externalApplication);
                                  },
                                  icon:
                                      Icon(Icons.share, color: kGold, size: 18),
                                  label: Text('WhatsApp Invite',
                                      style: TextStyle(
                                          color: kGold, fontSize: 12)),
                                  style: OutlinedButton.styleFrom(
                                      side: BorderSide(color: kGold)),
                                ),
                              ),
                            ]),
                          ],
                          // v2016 FIX 11(a): the non-joined
                          // else-branch ("Tournament Room — Chat &
                          // Voice" button) is GONE — voice rooms
                          // moved into communities / team chat.
                          // Phase 3 (#22): Results entry point — completed
                          // tournaments only (status completed / result).
                          // Visible to joined and non-joined viewers alike.
                          if (status == 'completed' || status == 'result') ...[
                            const SizedBox(height: 10),
                            SizedBox(
                              width: double.infinity,
                              child: OutlinedButton.icon(
                                onPressed: () => Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                        builder: (_) => TournamentResultsPage(
                                            tournamentId: id, tournament: t))),
                                icon: Icon(Icons.emoji_events, color: kGold),
                                label: Text('View Results',
                                    style: TextStyle(color: kGold)),
                                style: OutlinedButton.styleFrom(
                                    side: BorderSide(color: kGold)),
                              ),
                            ),
                          ],
                          const SizedBox(height: 20),
                          Row(
                            children: [
                              Expanded(
                                  child: Text('Players',
                                      style: TextStyle(
                                          color: kGold,
                                          fontSize: 16,
                                          fontWeight: FontWeight.bold))),
                              // Compact side button (NOT an inline list):
                              // opens the Online Status bottom sheet.
                              TextButton.icon(
                                onPressed: () =>
                                    showOnlineStatusSheet(context, id),
                                icon:
                                    Icon(Icons.people, color: kGold, size: 18),
                                label: Text('Status',
                                    style: TextStyle(
                                        color: kGold,
                                        fontWeight: FontWeight.bold)),
                                style: TextButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8)),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          if (regs.isEmpty)
                            Text('No players joined yet.',
                                style: TextStyle(color: kMuted))
                          else
                            Column(
                              children: [
                                for (final p in regs)
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 8),
                                    child: appCard(
                                      child: Row(
                                        children: [
                                          CachedFramedAvatar(
                                              uid: strVal(p['firebase_uid']),
                                              name: strVal(
                                                  p['username'], 'Player'),
                                              radius: 16),
                                          const SizedBox(width: 8),
                                          PresenceDot(
                                              uid: strVal(p['firebase_uid']),
                                              showLastSeen: true),
                                          const SizedBox(width: 10),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                    strVal(p['username'],
                                                        'Player'),
                                                    style: TextStyle(
                                                        color: kText,
                                                        fontWeight:
                                                            FontWeight.bold)),
                                                if (strVal(p['team_name'])
                                                    .isNotEmpty)
                                                  Text(
                                                      'Squad: ${p['team_name']} • Slot ${SupaDb.slotOf(p) > 0 ? SupaDb.slotOf(p) : '-'}',
                                                      style: TextStyle(
                                                          color: kMuted,
                                                          fontSize: 12)),
                                              ],
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _detailStat(String label, String value) => Expanded(
        child: Column(children: [
          Text(label, style: TextStyle(color: kMuted, fontSize: 12)),
          const SizedBox(height: 2),
          Text(value,
              style: TextStyle(
                  color: kText, fontWeight: FontWeight.bold, fontSize: 13),
              textAlign: TextAlign.center,
              // Detail fix (2026-11-21, standing rule): "Rs 10000.00"
              // is wider than one stat cell at 13px — wrap to 2 lines
              // at a word boundary, never truncate the amount.
              maxLines: 2,
              overflow: TextOverflow.ellipsis),
        ]),
      );

  String _prizeDistText(dynamic v) {
    if (v is List) {
      return v.map((e) {
        final m = SupaDb.asMap(e);
        return '${SupaDb.strOf(m['position'], SupaDb.strOf(m['rank'], '?'))}: ${fmtRs(SupaDb.numOf(m['prize'], SupaDb.numOf(m['amount'])))}';
      }).join('\n');
    }
    if (v is Map) {
      return v.entries.map((e) => '${e.key}: ${e.value}').join('\n');
    }
    return v.toString();
  }
}

/// Squad Registration (#23) — counts FILLED slots: the leader +
/// each mate with BOTH name and UID entered. A half-filled slot
/// (IGN only, UID only) does NOT count — the mockup's (n/4) means
/// complete slots, and _submit requires both fields per slot, so
/// counting partial slots would over-promise. Pure — unit-tested
/// in test/squad_registration_test.dart.
int squadFilledCount(
    {required bool leaderFilled, required List<bool> matesFilled}) {
  var n = leaderFilled ? 1 : 0;
  for (final m in matesFilled) {
    if (m) n++;
  }
  return n;
}

/// Squad Registration (#23) — picks the leader's game-UID prefill.
/// The profile is the first source (Edit Profile's IN-GAME PLAYER
/// ID, stored as profiles.game_uid and read back as
/// profile['gameUid'] by normProfile). When the profile has no UID
/// saved — the live v2005 case: IGN "admin" prefilled but UID
/// empty — fall back to the user's OWN registration rows, where
/// joinTournament always writes the leader's game_uid: first this
/// tournament's row (repair / re-join), then the latest UID from
/// any of the user's registrations. Returns '' when no UID is
/// saved anywhere — the field honestly stays empty, never a fake
/// value. Pure — unit-tested in test/squad_registration_test.dart.
String squadLeaderUidPrefill({
  required Map<String, dynamic> profile,
  required List<Map<String, dynamic>> tournamentRegs,
  required List<Map<String, dynamic>> myRegs,
  required String uid,
}) {
  final fromProfile = strVal(profile['gameUid'], strVal(profile['game_uid']));
  if (fromProfile.isNotEmpty) return fromProfile;
  for (final r in tournamentRegs) {
    if (strVal(r['firebase_uid']) != uid) continue;
    final g = strVal(r['game_uid'], strVal(r['gameUid']));
    if (g.isNotEmpty) return g;
  }
  var last = '';
  for (final r in myRegs) {
    final g = strVal(r['game_uid'], strVal(r['gameUid']));
    if (g.isNotEmpty) last = g;
  }
  return last;
}

class JoinTournamentPage extends StatefulWidget {
  final Map<String, dynamic> tournament;
  const JoinTournamentPage({super.key, required this.tournament});
  @override
  State<JoinTournamentPage> createState() => _JoinTournamentPageState();
}

class _JoinTournamentPageState extends State<JoinTournamentPage> {
  final _username = TextEditingController();
  final _gameUid = TextEditingController();
  final _teamName = TextEditingController();
  final _mates = List.generate(3, (_) => TextEditingController());
  final _mateUids = List.generate(3, (_) => TextEditingController());
  int? _slot;
  // FIX ROUND I-all-fix1-D (#07): the leader's REAL level
  // (profiles.level, default 1) for the gold level badge on the
  // leader avatar. Never a mockup number.
  int _leaderLevel = 1;
  // P0-1 (#06): the leader's REAL photo (profiles.photo_url, loaded
  // in _load next to _leaderLevel) for the leader avatar. Empty =
  // no photo set — the generic person icon stays.
  String _leaderPhotoUrl = '';
  bool _busy = false;
  bool _isRepair = false;
  // FIX ROUND I-all-fix1-A (#29): Preferred Region display value —
  // real profiles.country (migration 017) when set, else Pakistan
  // (the app's market). Display only; Edit Profile owns the value.
  String _region = 'Pakistan';
  List<int> _takenSlots = [];
  // Phase 2: rules acceptance (required) + Solo second
  // confirmation (Game ID / username correct).
  bool _rulesAccepted = false;
  bool _confirmIgn = false;

  int get _teamSize => teamSizeOf(widget.tournament);

  /// REGISTRATION UNIFY (2026-11-21): one title style for all
  /// modes — only the mode word differs.
  String get _registrationTitle => _teamSize >= 4
      ? 'SQUAD REGISTRATION'
      : (_teamSize == 2 ? 'DUO REGISTRATION' : 'SOLO REGISTRATION');

  /// REGISTRATION UNIFY (2026-11-21): one confirm-button style for
  /// all modes — only the label carries the mode.
  String get _confirmLabel => _teamSize >= 4
      ? 'CONFIRM SQUAD'
      : (_teamSize == 2 ? 'CONFIRM DUO' : 'CONFIRM SOLO');

  bool get _canConfirm =>
      _teamSize > 1 ? _rulesAccepted : (_rulesAccepted && _confirmIgn);

  /// REGISTRATION FIELD (2026-11-20 rebuild, mockups #23/#6): the
  /// mockup's compact floating-label field. The label lives INSIDE
  /// the border (never a separate row above it, so it can never wrap
  /// to two lines and the card stays compact), the validation tick
  /// is a tight 18px icon with 24px constraints (the old default
  /// 48px suffix box ate half of every narrow field and clipped
  /// hints to "E..."/"Ent..." at 360dp), and there is NO bottom
  /// spacing — the parent owns gaps. [label] must stay SHORT
  /// ("UID" / "IGN" / "Name") — a long floating label would clip in
  /// a half-width field. [hint] is optional and, when given, must
  /// also be short ("9-digit UID" / "Game UID"); most half-width
  /// fields pass no hint — the floating label doubles as the
  /// placeholder, so nothing can truncate. [goldBorder] gives the
  /// Squad leader's validated IGN field its gold border (#23).
  Widget _regField(TextEditingController controller, String label, bool valid,
      {String? hint,
      TextInputType? keyboardType,
      bool goldBorder = false,
      bool showTick = true,
      bool outline = false,
      // P2 (mockup #6): label-above fields render the label OUTSIDE
      // the box (showLabel: false) and the team-name field is LARGE.
      bool showLabel = true,
      bool large = false}) {
    // FIX 23 item 29: card look via CardFieldShell (radius 10, the
    // compact registration size). The validated-IGN gold border
    // (#23) survives as the shell's goldBorder.
    return CardFieldShell(
      goldBorder: goldBorder && valid,
      radius: 10,
      child: TextField(
      controller: controller,
      keyboardType: keyboardType,
      style: TextStyle(color: kText, fontSize: large ? 15 : 13),
      decoration: InputDecoration(
        labelText: showLabel ? label : null,
        labelStyle: TextStyle(color: kMuted, fontSize: 12),
        floatingLabelStyle: TextStyle(color: kMuted, fontSize: 11),
        hintText: hint,
        hintStyle: TextStyle(color: kMuted, fontSize: 12),
        isDense: true,
        contentPadding: EdgeInsets.symmetric(
            horizontal: large ? 14 : 10, vertical: large ? 16 : 13),
        suffixIcon: showTick
            ? Icon(valid ? Icons.check_circle : Icons.radio_button_unchecked,
                color: valid ? Colors.green : kMuted, size: 18)
            : null,
        suffixIconConstraints:
            const BoxConstraints(minWidth: 26, minHeight: 26),
        focusedBorder: const OutlineInputBorder(borderSide: BorderSide.none),
        enabledBorder: const OutlineInputBorder(borderSide: BorderSide.none),
        border: const OutlineInputBorder(borderSide: BorderSide.none),
      ),
      ),
    );
  }

  /// P2 (mockup #6): a STACKED labelled field — small caps label
  /// ABOVE a full-width box (Duo's GAME UID / IN-GAME NAME). The
  /// shared side-by-side compact fields stay for Squad/Solo.
  Widget _labelledField(TextEditingController controller, String label,
      bool valid,
      {String? hint, TextInputType? keyboardType}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(
                color: hText2,
                fontSize: 11,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5)),
        const SizedBox(height: 4),
        _regField(controller, label, valid,
            hint: hint,
            keyboardType: keyboardType,
            showLabel: false,
            outline: true),
      ],
    );
  }

  @override
  void initState() {
    super.initState();
    // Per-field validation ticks + (n/4) counter: re-render when
    // ANY registration field changes. The leader fields were
    // missing here — typing the leader's IGN/UID never rebuilt the
    // page, so the counter and the VALIDATED pill stayed stale
    // (v2005: leader filled, counter stuck at (0/4)).
    for (final c in [_username, _gameUid, ..._mates, ..._mateUids]) {
      c.addListener(() {
        if (mounted) setState(() {});
      });
    }
    _load();
  }

  Future<void> _load() async {
    try {
      final uid = FirebaseAuth.instance.currentUser!.uid;
      final id = strVal(widget.tournament['id']);
      final profile = await SupaDb.getProfile(uid);
      final regs = await SupaDb.getRegistrations(id);
      // FIX J (2026-11-21, v2005 #23): the leader's UID prefill.
      // The profile alone is often empty (Edit Profile's game UID
      // is only saved when the user typed it there) — fall back to
      // the user's own registration rows, where joinTournament
      // always writes the leader's game_uid. Own try/catch: a
      // failure here must never block the profile prefill above.
      var myRegs = <Map<String, dynamic>>[];
      try {
        myRegs = await SupaDb.getMyRegistrations(uid);
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        // Prefill username/gameUid from profile (+ registration
        // fallback for the UID — see squadLeaderUidPrefill).
        if (_username.text.isEmpty)
          _username.text =
              strVal(profile['username'], strVal(profile['displayName']));
        if (_gameUid.text.isEmpty)
          _gameUid.text = squadLeaderUidPrefill(
              profile: profile, tournamentRegs: regs, myRegs: myRegs, uid: uid);
        final country = strVal(profile['country']);
        if (country.isNotEmpty) _region = country;
        _takenSlots =
            regs.map((r) => SupaDb.slotOf(r)).where((s) => s > 0).toList();
        // REGISTRATION UNIFY (2026-11-21): NO auto-pick any more —
        // Duo gets the same visible slot picker as Squad and the
        // player picks; Solo's slot stays an optional preference.
        _leaderLevel = intVal(profile['level'], 1);
        // P0-1 (#06): real photo for the leader avatar (normed
        // profile carries both keys; empty = no photo set).
        _leaderPhotoUrl =
            strVal(profile['photoURL'], strVal(profile['photo_url']));
        final flagMap = SupaDb.asMap(
            profile['joined_tournaments'] ?? profile['joinedTournaments']);
        _isRepair = flagMap[id] == true &&
            !regs.any((r) => strVal(r['firebase_uid']) == uid);
      });
    } catch (_) {}
  }

  @override
  void dispose() {
    _username.dispose();
    _gameUid.dispose();
    _teamName.dispose();
    for (final c in _mates) {
      c.dispose();
    }
    for (final c in _mateUids) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.tournament;
    final maxP = intVal(t['maxPlayers'], 0);
    final htmlSlots = _teamSize == 2 ? 50 : 25;
    final slotCount = maxP > 0
        ? ((maxP ~/ _teamSize) < htmlSlots ? (maxP ~/ _teamSize) : htmlSlots)
        : htmlSlots;
    final slots = [
      for (var i = 1; i <= slotCount; i++)
        if (!_takenSlots.contains(i)) i
    ];
    final fee = numVal(t['entryFee']) * _teamSize;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent, // PHASE E (E4): transparent header — poster shows through
        // REGISTRATION UNIFY (2026-11-21, user order — one design +
        // one system for Solo/Duo/Squad; the mockups' per-mode
        // differences are OVERRIDDEN): identical header in all
        // three — gold back chevron, upright bold title, ARENA HUB
        // wordmark top-right. Only the mode word in the title
        // differs (SOLO / DUO / SQUAD REGISTRATION).
        leading: IconButton(
            icon: const Icon(Icons.chevron_left, color: hGold, size: 28),
            onPressed: () => Navigator.maybePop(context)),
        title: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(_registrationTitle,
              style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                  fontStyle: FontStyle.normal,
                  fontSize: 20)),
        ),
        actions: [
          Padding(
              padding: const EdgeInsets.only(right: 12),
              child: _arenaWordmark(fontSize: 12, crownSize: 24))
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_isRepair) ...[
              const Text(
                  'Your previous join did not complete. This will complete it now — no fee will be charged again.',
                  style: TextStyle(color: hGold, fontSize: 13)),
              const SizedBox(height: 12),
            ],
            // REGISTRATION UNIFY: one banner for all three modes.
            _registrationBanner(t, fee),
            const SizedBox(height: 20),
            // REGISTRATION UNIFY: one form for all three modes.
            ..._registrationForm(fee, slots),
            const SizedBox(height: 8),
            // J-detail-fix1 (#06/#23/#29): the mockup confirm
            // buttons are full PILLS (radius ~24-28, w900) — the
            // shared GoldButton stays radius 12, so the pill is
            // built locally. REGISTRATION UNIFY: one button style
            // in all three modes (glow everywhere); only the label
            // carries the mode (CONFIRM SOLO / DUO / SQUAD).
            _goldPillButton(
              label:
                  _isRepair ? 'Complete Join (No extra fee)' : _confirmLabel,
              onPressed: _canConfirm ? _submit : null,
              busy: _busy,
              glow: true,
            ),
          ],
        ),
      ),
    );
  }

  /// REGISTRATION UNIFY (2026-11-21, user order — one design for
  /// Solo/Duo/Squad; mockups' per-mode differences OVERRIDDEN):
  /// the SAME banner in all three modes — real banner_url cover,
  /// real status + mode pills, the REAL name in two-tone italic,
  /// the real date + mode, fee pill ALWAYS (Squad included — it
  /// used to hide the pill here). The old per-mode branches (no
  /// pills for Squad, game-name caps line, _heroTitle for Duo,
  /// diagonal slashes for Squad) are gone.
  Widget _registrationBanner(Map<String, dynamic> t, double fee) {
    final status = tStatus(t);
    final banner = ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Container(
        height: 176,
        width: double.infinity,
        color: hCard,
        child: Stack(
          fit: StackFit.expand,
          children: [
            _coverImage(tImage(t)),
            Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  colors: [
                    Colors.black.withValues(alpha: 0.62),
                    Colors.black.withValues(alpha: 0.25),
                    Colors.transparent
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // v2011 fix: pills shrink instead of overflowing
                  // the 300px banner in wide test fonts (23px over
                  // in Ahem). Flexible + FittedBox scaleDown, 2:1
                  // flex so the long REGISTRATION OPEN pill gets
                  // the room it needs; on a real device both pills
                  // keep their natural size (no shrink).
                  Row(
                    children: [
                      if (status == 'upcoming') ...[
                        Flexible(
                          flex: 2,
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerLeft,
                            child: _goldPill('REGISTRATION OPEN',
                                bg: Colors.transparent,
                                fg: Colors.green,
                                border: Colors.green,
                                icon: Icons.circle),
                          ),
                        ),
                        const SizedBox(width: 8),
                      ],
                      Flexible(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: _goldPill(strVal(t['mode'], 'Solo').toUpperCase(),
                              bg: Colors.transparent, fg: hGold, border: hGold),
                        ),
                      ),
                    ],
                  ),
                  const Spacer(),
                  // REGISTRATION UNIFY: the same two-tone name in
                  // all three modes (34). P2: mockups #6/#23 want
                  // WEEKEND white + DUO/SQUAD SHOWDOWN gold, so
                  // this banner uses goldFirst: false — #1's
                  // SQUAD-gold default is untouched elsewhere.
                  _twoToneTitle(tName(t), fontSize: 34, goldFirst: false),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      const Icon(Icons.calendar_today,
                          color: Colors.white, size: 14),
                      const SizedBox(width: 5),
                      // FIX ROUND I-all-fix1-A (#23/#6): mockup date
                      // carries the weekday — "Sat, Nov 22 • 8:00 PM".
                      // FIX J (2026-11-21): Flexible + ellipsis —
                      // the bare Text overflowed the 300dp row by
                      // 104px under wide font metrics (widget test);
                      // the date truncates, the SQUAD tag never does.
                      Flexible(
                          child: Text(_shortDateWeekday(intVal(t['startTime'])),
                              style: const TextStyle(
                                  color: Colors.white, fontSize: 13),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis)),
                      const SizedBox(width: 10),
                      Container(
                          width: 1,
                          height: 14,
                          color: Colors.white.withValues(alpha: 0.5)),
                      const SizedBox(width: 10),
                      const Icon(Icons.group, color: Colors.white, size: 14),
                      const SizedBox(width: 5),
                      Text(strVal(t['mode'], 'Solo').toUpperCase(),
                          style: const TextStyle(
                              color: Colors.white, fontSize: 13)),
                    ],
                  ),
                  // REGISTRATION UNIFY: the fee pill shows in ALL
                  // three modes (Squad used to hide it here).
                  const SizedBox(height: 8),
                  _goldPill(fee == 0 ? 'FREE ENTRY' : fmtRs(fee)),
                ],
              ),
            ),
            // REGISTRATION UNIFY: no Squad-only diagonal slashes —
            // the banner is identical in all three modes.
          ],
        ),
      ),
    );
    // 2026-11-20 (user order, "har jagah"): the banner is a card
    // view too — no static full gold border; the two rotating
    // corner shines + gradient fill come from MockupCard (padding
    // zero so the cover stays edge-to-edge).
    return MockupCard(padding: EdgeInsets.zero, radius: 16, child: banner);
  }



  /// Preferred Region display (#29): read-only. The join RPC takes
  /// no region and nothing is written — the value comes from the
  /// profile (Edit Profile owns it).
  Widget _regionDisplay() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Preferred Region',
            style: TextStyle(color: hText2, fontSize: 13)),
        const SizedBox(height: 4),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
          decoration: BoxDecoration(
              color: kField, borderRadius: BorderRadius.circular(10)),
          child: Row(
            children: [
              Expanded(
                  child: Text(_region,
                      style:
                          const TextStyle(color: Colors.white, fontSize: 15))),
              const Icon(Icons.keyboard_arrow_down, color: hGold, size: 22),
            ],
          ),
        ),
        const SizedBox(height: 4),
        const Text('Change your country in Edit Profile.',
            style: TextStyle(color: hText2, fontSize: 11)),
      ],
    );
  }


  /// REGISTRATION UNIFY (2026-11-21, user order — one design +
  /// one system for Solo/Duo/Squad): the SAME form for all three
  /// modes, parameterised only by [_teamSize] (1/2/4). Team name
  /// only for teams (Solo has none); one player card per slot —
  /// leader + 0/1/3 mates; the SAME slot picker in all three
  /// (Duo's auto-pick is gone — the player picks); Solo keeps its
  /// Preferred Region + confirm checkbox in a compact section
  /// below the picker. Fee = entryFee × teamSize; slots =
  /// maxPlayers ÷ teamSize (both computed in [build]).
  /// Join semantics unchanged: _submit still requires the team name
  /// (teams), every mate's name + UID, a picked slot (teams), the
  /// rules tick (all) + the IGN confirm tick (Solo only).
  List<Widget> _registrationForm(double fee, List<int> slots) {
    final leaderValid =
        _username.text.trim().isNotEmpty && _gameUid.text.trim().isNotEmpty;
    final filled = squadFilledCount(
      leaderFilled: leaderValid,
      matesFilled: [
        for (var i = 0; i < _teamSize - 1; i++)
          _mates[i].text.trim().isNotEmpty &&
              _mateUids[i].text.trim().isNotEmpty
      ],
    );
    final teamMode = _teamSize > 1;
    return [
      if (teamMode) ...[
        Row(
          children: [
            Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                    color: hGold.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: hGold.withValues(alpha: 0.5))),
                child: const Icon(Icons.shield, color: hGold, size: 26)),
            const SizedBox(width: 10),
            // P2 (mockup #6): LABEL-ABOVE large field — "Team Name"
            // sits above the box (taller, 15px text), shield icon
            // kept at the left. The compact floating-label field is
            // gone for the team name (all team modes share it).
            Expanded(
                child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Team Name',
                    style: TextStyle(
                        color: hText2,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.5)),
                const SizedBox(height: 6),
                _regField(_teamName, 'Team Name', true,
                    hint: 'Enter team name',
                    showTick: false,
                    showLabel: false,
                    large: true),
              ],
            )),
          ],
        ),
        const SizedBox(height: 16),
      ],
      Row(
        children: [
          Expanded(
              child: Text(_teamHeading(filled),
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w900,
                      fontSize: 18))),
          _goldPill(fee == 0 ? 'FREE ENTRY' : fmtRs(fee),
              bg: Colors.transparent, fg: hGold, border: hGold),
        ],
      ),
      const SizedBox(height: 12),
      _playerCard(leaderValid),
      const SizedBox(height: 12),
      for (var i = 0; i < _teamSize - 1; i++) ...[
        _mateCard(i),
        const SizedBox(height: 12),
      ],
      // One slot picker for all three modes — Duo included
      // (auto-pick removed); Solo's stays an optional preference.
      _slotDropdown(slots, optional: !teamMode),
      const SizedBox(height: 12),
      if (!teamMode) ...[
        _regionDisplay(),
        const SizedBox(height: 12),
        CheckboxListTile(
          value: _confirmIgn,
          onChanged: (v) => setState(() => _confirmIgn = v ?? false),
          title: const Text('I confirm that my in-game details are correct.',
              style: TextStyle(color: Colors.white)),
          activeColor: hGold,
          checkColor: Colors.black,
          controlAffinity: ListTileControlAffinity.leading,
          contentPadding: EdgeInsets.zero,
        ),
      ],
      // P2: wording is per-mode — Squad's mockup #23 reads "I agree
      // to the Tournament Rules & Regulations" (gold spans); Duo/Solo
      // keep "tournament rules & terms of service". Solo passes
      // highlight: false so "rules"/"terms of service" render plain
      // white like mockup #29.
      if (_teamSize >= 4)
        // v2011 fix: mockup #23's wording has NO trailing period
        // (the '.' made the rendered text differ from the mockup).
        _rulesTile('I agree to the ', 'Tournament Rules', ' & ',
            'Regulations', '')
      else if (_teamSize == 2)
        _rulesTile('I agree to the tournament ', 'rules', ' & ',
            'terms of service', '.')
      else
        _rulesTile('I agree to the tournament ', 'rules', ' & ',
            'terms of service', '.', highlight: false),
      // P2 (mockups #29/#6): the free-event line is a bordered pill
      // with an icon — Solo shows the trophy pill "Community event —
      // free participation", Duo the gift "Community event. Free
      // participation!", Squad keeps its own text in the same pill.
      // Paid tournaments show nothing here (the price already lives
      // in the fee pill above).
      if (fee == 0)
        Center(
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            decoration: BoxDecoration(
                color: hGold.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: hGold.withValues(alpha: 0.6))),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                    _teamSize == 1 ? Icons.emoji_events : Icons.card_giftcard,
                    color: hGold,
                    size: 16),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                      _teamSize == 1
                          ? 'Community event \u2014 free participation'
                          : (_teamSize == 2
                              ? 'Community event. Free participation!'
                              : 'This is a free community event.'),
                      style: const TextStyle(
                          color: hGold,
                          fontSize: 13,
                          fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          ),
        ),
    ];
  }

  /// REGISTRATION UNIFY: the form heading — same style in all three
  /// modes, only the mode word + counter differ.
  String _teamHeading(int filled) => _teamSize >= 4
      ? 'BUILD YOUR SQUAD ($filled/$_teamSize)'
      : (_teamSize == 2
          ? 'BUILD YOUR DUO ($filled/$_teamSize)'
          : 'YOUR PLAYER ($filled/$_teamSize)');

  /// REGISTRATION UNIFY (2026-11-21): the ONE player card — the
  /// leader in all three modes. Title is "TEAM LEADER (YOU)" for
  /// teams, "PLAYER (YOU)" for Solo. Same gold border + crown +
  /// VALIDATED / PENDING pill + side-by-side IGN/UID fields
  /// everywhere. (Was _squadLeaderCard, mockup #23's compact
  /// layout; the title scales down instead of wrapping, and the
  /// compact floating-label fields have no separate label rows and
  /// no long hints. The card is a plain bordered Container, NOT
  /// MockupCard — the mockup's leader card has a FULL gold border
  /// + soft gold glow.)
  Widget _playerCard(bool valid) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: hCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: kGold, width: 1.5),
        boxShadow: [
          BoxShadow(color: kGold.withValues(alpha: 0.18), blurRadius: 12)
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // P2 (mockup #6): the gold TEAM LEADER pill sits UNDER the
          // leader avatar (team modes only — Solo has no team).
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: kGold, width: 2)),
                // P0-1 (#06): the leader's REAL photo (profiles
                // photo_url) instead of the generic person icon; a
                // broken URL falls back to the icon (the error
                // handler clears the URL and rebuilds). No photo
                // set = icon, exactly as before.
                child: CircleAvatar(
                    radius: 26,
                    backgroundColor: hSecondary,
                    // Batch 3B (item 8): disk-cached provider — the
                    // leader photo no longer re-downloads on every
                    // open; same cache as CachedNetworkImage.
                    backgroundImage: _leaderPhotoUrl.isNotEmpty
                        ? CachedNetworkImageProvider(_leaderPhotoUrl)
                        : null,
                    onBackgroundImageError: _leaderPhotoUrl.isNotEmpty
                        ? (_, __) {
                            if (mounted) {
                              setState(() => _leaderPhotoUrl = '');
                            }
                          }
                        : null,
                    child: _leaderPhotoUrl.isEmpty
                        ? Icon(Icons.person, color: kGold, size: 28)
                        : null),
              ),
              Positioned(
                right: -2,
                top: -4,
                child: Container(
                    padding: const EdgeInsets.all(3),
                    decoration:
                        BoxDecoration(color: kGold, shape: BoxShape.circle),
                    child: const _MiniCrown(size: 12, color: Colors.black)),
              ),
              // P0-1 (#06): the gold level badge (mockup "3") —
              // _leaderLevel was loaded from profiles.level but
              // never rendered. Bottom-right corner (the crown
              // owns top-right); pill-shaped so a 2-3 digit level
              // never truncates. Real level only, never a mockup
              // number.
              Positioned(
                right: -2,
                bottom: -4,
                child: Container(
                    constraints: const BoxConstraints(
                        minWidth: 20, minHeight: 20),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 4, vertical: 1),
                    decoration: BoxDecoration(
                        color: kGold,
                        borderRadius: BorderRadius.circular(10),
                        border:
                            Border.all(color: hCard, width: 1.5)),
                    alignment: Alignment.center,
                    child: Text('$_leaderLevel',
                        style: const TextStyle(
                            color: Colors.black,
                            fontWeight: FontWeight.w900,
                            fontSize: 11)),
                  ),
              ),
                ],
              ),
              if (_teamSize > 1) ...[
                const SizedBox(height: 6),
                _goldPill('TEAM LEADER'),
              ],
            ],
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    // FittedBox (scaleDown): the title shrinks a
                    // touch beside the VALIDATED pill instead of
                    // wrapping to two lines (the old card's fault).
                    Expanded(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                            _teamSize > 1 ? 'TEAM LEADER (YOU)' : 'PLAYER (YOU)',
                            style: TextStyle(
                                color: kGold,
                                fontWeight: FontWeight.w900,
                                fontSize: 13)),
                      ),
                    ),
                    const SizedBox(width: 8),
                    // v2011 fix: the VALIDATED pill must shrink
                    // instead of overflowing this narrow (144.5px)
                    // title Row in wide test fonts (6px over in
                    // Ahem). Flexible + FittedBox scaleDown; the
                    // title keeps its 50/50 share, so on a real
                    // device both render as before (title ~0.78x
                    // as now, pill unshrunk).
                    Flexible(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerRight,
                        child: _validPill(valid),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                // P2 (mockup #6): DUO stacks the fields with labels
                // above (GAME UID, then IN-GAME NAME). Squad/Solo
                // keep the side-by-side compact fields (mockup #23
                // shows them side by side; stacked doubled the card
                // height there).
                if (_teamSize == 2) ...[
                  _labelledField(_gameUid, 'GAME UID', valid,
                      hint: 'Enter game UID',
                      keyboardType: TextInputType.number),
                  const SizedBox(height: 8),
                  _labelledField(_username, 'IN-GAME NAME', valid,
                      hint: 'Enter in-game name'),
                ] else
                  // Mockup #23: the two fields sit SIDE BY SIDE in
                  // one row — stacked fields doubled the card height.
                  // Labels only ("IGN"/"UID") — no long hints to clip.
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                          child: _regField(_username, 'IGN', valid,
                              goldBorder: true, outline: true)),
                      const SizedBox(width: 8),
                      Expanded(
                          child: _regField(_gameUid, 'UID', valid,
                              keyboardType: TextInputType.number,
                              outline: true)),
                    ],
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// REGISTRATION UNIFY (2026-11-21): the ONE mate card — Duo gets
  /// 1, Squad gets 3. Title is "SQUAD MATE #n" for Squad,
  /// "TEAMMATE" for Duo. Filled -> solid card with number circle +
  /// VALIDATED pill and UID/Name fields; empty -> soft-gold card
  /// with 9-digit UID + IGN fields and a real INVITE TEAMMATE share.
  /// (Was _squadMateCard, mockup #23.)
  Widget _mateCard(int i) {
    final n = i + 2;
    final filled =
        _mates[i].text.trim().isNotEmpty && _mateUids[i].text.trim().isNotEmpty;
    if (!filled) {
      // P2 (mockup #6): DUO's empty-mate card carries a silhouette
      // avatar + gold TEAMMATE pill and STACKED labelled fields
      // (GAME UID / IN-GAME NAME), with INVITE TEAMMATE full-width
      // below. Squad keeps the mockup #23 layout (title + side-by-
      // side fields + invite in the fields row).
      if (_teamSize == 2) {
        return ArenaDashedBorder(
          backgroundColor:
              Color.alphaBlend(kGold.withValues(alpha: 0.10), hCard),
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 52,
                    height: 52,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: hSecondary,
                        border: Border.all(color: hBorder, width: 2)),
                    child: const Icon(Icons.person,
                        color: hText2, size: 28),
                  ),
                  const SizedBox(width: 10),
                  _goldPill('TEAMMATE'),
                ],
              ),
              const SizedBox(height: 10),
              _labelledField(_mateUids[i], 'GAME UID', false,
                  hint: '9-digit UID',
                  keyboardType: TextInputType.number),
              const SizedBox(height: 8),
              _labelledField(_mates[i], 'IN-GAME NAME', false,
                  hint: 'Enter in-game name'),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _showInviteTeammateDialog,
                  style: ElevatedButton.styleFrom(
                      backgroundColor: kGold,
                      foregroundColor: Colors.black,
                      padding:
                          const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                      elevation: 0),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.share, size: 15),
                      SizedBox(width: 6),
                      Text('INVITE TEAMMATE',
                          style: TextStyle(
                              fontWeight: FontWeight.w900, fontSize: 12)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      }
      // Wave 4b #23: mockup's empty-mate card has a DASHED gold
      // outline — shared ArenaDashedBorder (foreground painter, so
      // the hCard fill never covers the dashes). Fields, INVITE
      // TEAMMATE action and join semantics unchanged.
      // 2026-11-20 rebuild: the old three-column row clipped both
      // hints to "Ent..." at 360dp (user's screenshot) — the fields
      // are now the compact floating-label kind with SHORT hints
      // ("9-digit UID" / "IGN") that fit fully, the button is 92px
      // wide, and the row stretches so the button matches the
      // fields' height.
      // FIX J (2026-11-21 — ROOT CAUSE of the live v2005 report):
      // the stretch Row below sits in a Column inside a
      // SingleChildScrollView, i.e. UNBOUNDED height — stretch
      // hands the button's SizedBox + the Expanded fields tight
      // INFINITE-height constraints (debug: "BoxConstraints forces
      // an infinite height" at this Row; release: the card renders
      // broken — no dashes, no button — and everything below it
      // is pushed out of reach). IntrinsicHeight bounds the Row
      // to the fields' real height FIRST, so stretch is safe and
      // the button still matches the fields' height exactly.
      return ArenaDashedBorder(
        // Mockup #23: the empty card's fill is dark gold-TINTED
        // (warmer than the solid cards) — hCard warmed 10% gold.
        backgroundColor: Color.alphaBlend(kGold.withValues(alpha: 0.10), hCard),
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_teamSize >= 4 ? 'SQUAD MATE #$n' : 'TEAMMATE',
                style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w900,
                    fontSize: 14)),
            const SizedBox(height: 10),
            // FIX ROUND I-all-fix1-A (#23): mockup puts INVITE
            // TEAMMATE in the same row as the two fields (third
            // column), bottom-aligned with the inputs.
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                      child: _regField(_mateUids[i], 'UID', false,
                          hint: '9-digit UID',
                          keyboardType: TextInputType.number,
                          showTick: false,
                          outline: true)),
                  const SizedBox(width: 8),
                  Expanded(
                      child: _regField(_mates[i], 'Name', false,
                          hint: 'IGN', showTick: false, outline: true)),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 92,
                    child: ElevatedButton(
                      onPressed: _showInviteTeammateDialog,
                      style: ElevatedButton.styleFrom(
                          backgroundColor: kGold,
                          foregroundColor: Colors.black,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 8),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10)),
                          elevation: 0),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.share, size: 15),
                          SizedBox(width: 4),
                          Flexible(
                              child: Text('INVITE\nTEAMMATE',
                                  style: TextStyle(
                                      fontWeight: FontWeight.w900,
                                      fontSize: 11,
                                      height: 1.1),
                                  textAlign: TextAlign.center)),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }
    // FIX J (2026-11-21, mockup #23 same-to-same — Sameer's 01:19
    // order overrides the global 2-line rule FOR THESE CARDS):
    // the mockup's filled mate cards have a plain thin GREY
    // border, so this card is a bordered Container, NOT MockupCard
    // (whose rotating shines are not in the mockup). Layout already
    // matches mockup #23 (number circle + side-by-side fields);
    // compact floating-label fields with green ticks (mockup #23
    // shows checks on the filled fields), title scales down
    // instead of wrapping, tighter padding/gaps.
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: hCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: hBorder, width: 1.5),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 52,
            height: 52,
            alignment: Alignment.center,
            decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: hSecondary,
                border: Border.all(color: hBorder, width: 2)),
            child: Text('$n',
                style: const TextStyle(
                    color: hText2, fontSize: 22, fontWeight: FontWeight.bold)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(_teamSize >= 4 ? 'SQUAD MATE #$n' : 'TEAMMATE',
                            style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w900,
                                fontSize: 14)),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _validPill(true),
                  ],
                ),
                const SizedBox(height: 8),
                // P2 (mockup #6): DUO stacks the mate fields with
                // labels above; Squad keeps side-by-side (mockup #23).
                if (_teamSize == 2) ...[
                  _labelledField(_mateUids[i], 'GAME UID', true,
                      hint: 'Enter game UID',
                      keyboardType: TextInputType.number),
                  const SizedBox(height: 8),
                  _labelledField(_mates[i], 'IN-GAME NAME', true,
                      hint: 'Enter in-game name'),
                ] else
                  Row(
                    children: [
                      Expanded(
                          child: _regField(_mateUids[i], 'UID', true,
                              keyboardType: TextInputType.number,
                              outline: true)),
                      const SizedBox(width: 8),
                      Expanded(
                          child: _regField(_mates[i], 'Name', true,
                              outline: true)),
                    ],
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// VALIDATED = this mate's name AND UID are both filled (client
  /// format check only — there is no server UID-lookup API, so the
  /// pill means "details entered", never "verified by the game").
  Widget _validPill(bool valid) {
    if (valid) {
      return _goldPill('VALIDATED',
          bg: Colors.green.withValues(alpha: 0.15),
          fg: Colors.green,
          border: Colors.green,
          icon: Icons.check_circle);
    }
    return _goldPill('PENDING',
        bg: Colors.transparent, fg: hText2, border: hBorder);
  }


  /// Slot picker — REGISTRATION UNIFY (2026-11-21): the SAME
  /// picker in all three modes (Duo included — auto-pick removed).
  /// Required for teams, optional preference for Solo. The join
  /// RPC needs a slot for teams; Solo's slot is record-only.
  Widget _slotDropdown(List<int> slots, {bool optional = false}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(optional ? 'Preferred Slot (optional)' : 'Select Slot',
            style: const TextStyle(color: hText2, fontSize: 13)),
        if (slots.isEmpty)
          const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text('All slots are full for this tournament.',
                  style: TextStyle(color: Colors.redAccent))),
        const SizedBox(height: 4),
        DropdownButtonFormField<int>(
          initialValue: _slot,
          dropdownColor: hCard,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
              filled: true,
              fillColor: hSecondary,
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none)),
          items: [
            for (final s in slots)
              DropdownMenuItem(value: s, child: Text('Slot $s'))
          ],
          onChanged: (v) => setState(() => _slot = v),
        ),
      ],
    );
  }



  /// Rules checkbox with gold spans for the rules / terms words.
  /// `a` + gold `b` + `c` + gold `d` + `e` compose the label.
  /// FIX ROUND I-all-fix1-A (#29): the Solo mockup shows the whole
  /// line in plain white — pass highlight: false there.
  Widget _rulesTile(String a, String b, String c, String d, String e,
      {bool highlight = true}) {
    return CheckboxListTile(
      value: _rulesAccepted,
      onChanged: (v) => setState(() => _rulesAccepted = v ?? false),
      title: RichText(
        text: TextSpan(
          style: const TextStyle(color: Colors.white, fontSize: 14),
          children: [
            TextSpan(text: a),
            TextSpan(
                text: b,
                style: TextStyle(color: highlight ? hGold : Colors.white)),
            TextSpan(text: c),
            if (d.isNotEmpty)
              TextSpan(
                  text: d,
                  style: TextStyle(color: highlight ? hGold : Colors.white)),
            TextSpan(text: e),
          ],
        ),
      ),
      activeColor: hGold,
      checkColor: Colors.black,
      controlAffinity: ListTileControlAffinity.leading,
      contentPadding: EdgeInsets.zero,
    );
  }

  /// Invite Teammate (#23): the INVITE TEAMMATE button opens a
  /// dialog with BOTH paths — a real in-app invite (username lookup
  /// -> [SupaDb.sendTeamInvite], so the invitee gets Accept/Decline
  /// in their Notifications) and the WhatsApp share. The in-app
  /// path needs a real `teams` row: [SupaDb.ensureTeamForJoin]
  /// provisions/returns the team id for the typed team name (the
  /// join itself provisions the same team, so this creates nothing
  /// the join would not create). A fabricated team id would make an
  /// invite Accept can never complete ("Team nahi mili"), so the
  /// dialog refuses to send until the team name is entered.
  Future<void> _showInviteTeammateDialog() async {
    final ctrl = TextEditingController();
    String? errorText;
    bool sending = false;
    final sent = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          Future<void> sendInApp() async {
            final name = ctrl.text.trim().replaceFirst(RegExp(r'^@'), '');
            if (name.isEmpty) {
              setDialogState(
                  () => errorText = 'Username likho (e.g. zehri5).');
              return;
            }
            final teamName = _teamName.text.trim();
            if (teamName.isEmpty) {
              setDialogState(() => errorText =
                  'Pehle team ka naam likho — invite usi team ke liye banti hai.');
              return;
            }
            setDialogState(() {
              sending = true;
              errorText = null;
            });
            try {
              final found = await SupaDb.findUserByUsername(name);
              if (found.isEmpty) {
                setDialogState(() {
                  sending = false;
                  errorText = 'Is username ka koi player nahi mila.';
                });
                return;
              }
              final invitedUid = SupaDb.strOf(found['firebase_uid']);
              final uid = FirebaseAuth.instance.currentUser!.uid;
              if (invitedUid.isEmpty || invitedUid == uid) {
                setDialogState(() {
                  sending = false;
                  errorText = invitedUid == uid
                      ? 'Apne aap ko invite nahi kar sakte.'
                      : 'Is player ka account nahi mila.';
                });
                return;
              }
              final teamId = await SupaDb.ensureTeamForJoin(
                captainUid: uid,
                captainName: _username.text.trim().isEmpty
                    ? 'Player'
                    : _username.text.trim(),
                teamName: teamName,
              );
              final res = await SupaDb.sendTeamInvite(
                teamId: teamId,
                teamName: teamName,
                invitedUid: invitedUid,
                inviterUid: uid,
                inviterName: _username.text.trim(),
              );
              if (!context.mounted) return;
              if (res['ok'] == true) {
                Navigator.pop(context, true);
              } else {
                setDialogState(() {
                  sending = false;
                  errorText = SupaDb.strOf(
                      res['error'], 'Invite nahi bheji ja saki.');
                });
              }
            } catch (e) {
              if (!context.mounted) return;
              setDialogState(() {
                sending = false;
                errorText = e.toString().replaceFirst('Exception: ', '');
              });
            }
          }

          return AlertDialog(
            backgroundColor: kCardPurpleMid,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22), side: const BorderSide(color: kCardPurpleBorder, width: 1.5)),
            title: Text('Invite Teammate',
                style: TextStyle(color: kGold)),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                      'In-app invite: player ko app ke andar notification milegi — Accept karte hi woh aap ki team me aa jayega.',
                      style: TextStyle(color: kText, fontSize: 13)),
                  const SizedBox(height: 12),
                  // FIX 23 item 29: card look via CardFieldShell.
                  CardFieldShell(
                    child: TextField(
                    controller: ctrl,
                    style: TextStyle(color: kText),
                    decoration: InputDecoration(
                      hintText: '@username',
                      hintStyle: TextStyle(color: kMuted),
                      border: const OutlineInputBorder(borderSide: BorderSide.none),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 12),
                    ),
                  ),
                  ),
                  if (errorText != null) ...[
                    const SizedBox(height: 8),
                    Text(errorText!,
                        style: const TextStyle(color: Colors.redAccent)),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: sending
                    ? null
                    : () async {
                        Navigator.pop(context, false);
                        await _inviteTeammate();
                      },
                child: Text('WhatsApp',
                    style: TextStyle(color: kGold)),
              ),
              ElevatedButton(
                onPressed: sending ? null : sendInApp,
                style: ElevatedButton.styleFrom(
                    backgroundColor: kGold,
                    foregroundColor: Colors.black),
                child: Text(sending ? 'Sending…' : 'Send Invite',
                    style: const TextStyle(fontWeight: FontWeight.bold)),
              ),
            ],
          );
        },
      ),
    );
    if (!mounted) return;
    if (sent == true) {
      toast(context, 'Invite bhej di gayi!');
    }
  }

  /// Invite Teammate (#23): shares the real tournament join link
  /// on WhatsApp — the same invite the Detail page sends. Kept as
  /// the secondary path inside the invite dialog above.
  Future<void> _inviteTeammate() async {
    final t = widget.tournament;
    final link = 'protournament://tournament/${strVal(t['id'])}';
    final text =
        'Join ${tName(t)} on ARENA HUB! Tournament link: $link (App me Tournaments → search karen ya link paste karen)';
    final uri = Uri.parse('https://wa.me/?text=${Uri.encodeComponent(text)}');
    if (await canLaunchUrl(uri))
      await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<void> _submit() async {
    final uid = FirebaseAuth.instance.currentUser!.uid;
    final id = strVal(widget.tournament['id']);
    final teamMode = _teamSize > 1;
    // Phase 2: defensive re-check (the button is already gated).
    if (!_rulesAccepted) {
      toast(context, 'Please accept the tournament rules first.');
      return;
    }
    if (!teamMode && !_confirmIgn) {
      toast(context, 'Please confirm your Game ID and username are correct.');
      return;
    }
    if (_username.text.trim().isEmpty || _gameUid.text.trim().isEmpty) {
      toast(context, 'Enter your username and game UID.');
      return;
    }
    // Join validation (HTML-exact): team name + teammates required.
    if (_teamSize > 1 && _teamName.text.trim().isEmpty) {
      toast(context, 'Enter your team / squad name.');
      return;
    }
    for (var i = 0; i < _teamSize - 1; i++) {
      if (_mates[i].text.trim().isEmpty) {
        toast(context, 'Enter Player ${i + 2} name.');
        return;
      }
      if (_mateUids[i].text.trim().isEmpty) {
        toast(context, 'Enter Player ${i + 2} UID.');
        return;
      }
    }
    // REGISTRATION UNIFY (2026-11-21): re-read the taken slots
    // right before joining — a slot taken since page-open must
    // never dead-end the join with a "select a different slot"
    // message the user cannot act on. All team modes pick in the
    // same picker; Solo's slot stays an optional preference.
    if (_teamSize > 1) {
      try {
        final regs = await SupaDb.getRegistrations(id);
        _takenSlots =
            regs.map((r) => SupaDb.slotOf(r)).where((s) => s > 0).toList();
      } catch (_) {}
    }
    if (!mounted) return;
    if (_teamSize > 1 && _slot == null) {
      // REGISTRATION UNIFY: every team mode picks a slot in the
      // same picker — null means the player has not picked one.
      toast(context, 'Please select a slot.');
      return;
    }
    setState(() => _busy = true);
    try {
      // WAVE 4 FIX 1 (P0): defensive profile ensure — a restored
      // session can reach Join with no profiles row, and
      // joinTournament throws 'Profile not found. Please log in
      // again.' without one. SplashGate now ensures on sign-in, but
      // this covers any path that missed it (e.g. ensure failed
      // transiently at login, or the row was deleted). No-op when
      // the profile already exists.
      final currentUser = FirebaseAuth.instance.currentUser;
      if (currentUser != null && (await SupaDb.getProfile(uid)).isEmpty) {
        await SupaDb.ensureUserProfile(currentUser);
      }
      final mates = <Map<String, String>>[];
      for (var i = 0; i < _teamSize - 1; i++) {
        mates.add(
            {'name': _mates[i].text.trim(), 'uid': _mateUids[i].text.trim()});
      }
      final result = await SupaDb.joinTournament(
        uid: uid,
        tournamentId: id,
        username: _username.text.trim(),
        gameUid: _gameUid.text.trim(),
        teamName: _teamName.text.trim(),
        slot:
            _slot, // team: required slot; solo: optional preference (recorded, never blocks others)
        mates: mates,
      );
      final isRepair = result['isRepair'] == true;
      // P0-1: WAITLISTED is not a join — the RPC waitlisted the
      // team (full + waitlist on) and charged nothing. Stay on the
      // page with the honest position; NEVER navigate to the
      // success page for a waitlist.
      if (result['waitlisted'] == true) {
        if (mounted) {
          toast(context,
              'Tournament full hai — aap waitlist position ${result['position'] ?? ''} par hain. Slot khali hote hi admin aap ko promote karega.');
        }
        return;
      }
      if (mounted) {
        // Phase 2 (#24): success page with the REAL registration
        // id — the RPC returns the captain row id directly; fall
        // back to the data-layer fetch (repair path) when it is
        // absent. No invented number. Navigation + id format
        // UNCHANGED (RegistrationSuccessPage still renders
        // '#AH-' + the first 8 chars).
        var regId = strVal(result['registrationId']);
        if (regId.isEmpty) regId = await SupaDb.getMyRegistrationId(id, uid);
        // P0-1: post-RPC bookkeeping flags — the join itself
        // SUCCEEDED (registration + fee ledger are in), only a
        // follow-up write failed. Warn plainly instead of faking
        // a clean success or failing a completed join.
        if (result['balanceSyncFailed'] == true) {
          toast(context,
              'Registered! Wallet balance update nahi hua — balance galat dikhe to support se rabta karen (code: ${strVal(result['registrationCode'])}).');
        } else if (result['slotPatchFailed'] == true) {
          toast(context,
              'Registered! Slot record save nahi hua — admin aap ka slot check karega (code: ${strVal(result['registrationCode'])}).');
        } else if (result['commissionOk'] == false) {
          // F29 (Batch 3B): the join stands, but the platform
          // commission row did not land (recordTransaction logged
          // the failure). Warn plainly; the approve-time catch-up
          // reconciles the missed row.
          toast(context,
              'Registered! Commission record save nahi hua — admin ko inform kar diya gaya hai (code: ${strVal(result['registrationCode'])}).');
        }
        SupaDb.bumpRefresh();
        if (!mounted) return;
        Navigator.pushReplacement(
            context,
            MaterialPageRoute(
                builder: (_) => RegistrationSuccessPage(
                    tournament: widget.tournament,
                    registrationId: regId,
                    isRepair: isRepair,
                    teamName: _teamName.text.trim())));
      }
    } catch (e) {
      if (mounted)
        toast(context,
            'Join failed: ${e.toString().replaceFirst('Exception: ', '')}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

/// Phase 2 — 3-step match timeline (#1, reused by MatchDetailsPage):
/// Registration -> Room opens -> Match starts. Room step uses the
/// REAL gating rule (admin-set lobby_opens_at when present, else
/// 10 min before start — the same computed time `roomVisibleFor`
/// gates on, via [lobbyOpensMsFor]); lobby_opens_at is live (029),
/// so a set lobby time is shown, never a hard-coded start−10min.
/// (F21, Batch 3B: the old comment claiming lobby_opens_at "does
/// not exist live (draft 020)" was stale — the column exists and
/// the Matches picker + admin form both write it.)
/// Wave B #1 — 3-step match timeline in the mockup's style: gold
/// rail, done = gold check, current = flat gold dot, pending =
/// grey. NO NEON rule: no glow shadow on the current dot.
/// same rule the room lock uses), match begins at the real start
/// time. No time is shown when the tournament has no start time.
class _MatchTimeline extends StatelessWidget {
  final Map<String, dynamic> tournament;
  final bool joined;
  final bool roomVisible;
  const _MatchTimeline(
      {required this.tournament,
      required this.joined,
      required this.roomVisible});

  @override
  Widget build(BuildContext context) {
    final status = tStatus(tournament);
    final startMs = intVal(tournament['startTime']);
    final lobbyMs = lobbyOpensMsFor(tournament);
    final steps = [
      {
        'label': 'Registration Confirmed',
        'done': joined,
        'current': !joined && status == 'upcoming'
      },
      {
        'label': lobbyMs > 0
            ? 'Match Room Opens (${_timeOnly(lobbyMs)})'
            : 'Match Room Opens',
        'done': roomVisible,
        'current': joined && !roomVisible
      },
      {
        'label': startMs > 0
            ? 'Match Begins (${_timeOnly(startMs)})'
            : 'Match Begins',
        'done': status == 'ongoing',
        'current': status == 'upcoming' && joined
      },
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      child: Column(
        children: [
          for (var i = 0; i < steps.length; i++)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // J-detail-fix1 (#1, mockup 02_match_countdown.jpg):
                // the rail is 44 wide — the done step's gold ✓ sits
                // SEPARATE, to the LEFT of the rail dot (not inside
                // the circle), and the CURRENT dot carries a glowing
                // halo. The connector stays centred under the dot.
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 44,
                      child: Row(
                        children: [
                          if (steps[i]['done'] as bool)
                            const Icon(Icons.check, color: hGold, size: 18)
                          else
                            const SizedBox(width: 18),
                          const SizedBox(width: 6),
                          Container(
                            width: 26,
                            height: 26,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: (steps[i]['done'] as bool)
                                  ? hGold
                                  : Colors.transparent,
                              border: Border.all(
                                  color: (steps[i]['done'] as bool) ||
                                          (steps[i]['current'] as bool)
                                      ? hGold
                                      : hBorder,
                                  width: 2),
                              // Current-dot halo: soft gold glow
                              // around the ring + the dot itself.
                              boxShadow: (steps[i]['current'] as bool)
                                  ? [
                                      BoxShadow(
                                          color: hGold.withValues(alpha: 0.45),
                                          blurRadius: 10,
                                          spreadRadius: 1),
                                    ]
                                  : null,
                            ),
                            child: (steps[i]['done'] as bool)
                                ? null
                                : Container(
                                    width: 8,
                                    height: 8,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: (steps[i]['current'] as bool)
                                          ? hGold
                                          : hBorder,
                                      boxShadow: (steps[i]['current'] as bool)
                                          ? [
                                              BoxShadow(
                                                  color: hGold.withValues(
                                                      alpha: 0.7),
                                                  blurRadius: 8,
                                                  spreadRadius: 2),
                                            ]
                                          : null,
                                    ),
                                  ),
                          ),
                        ],
                      ),
                    ),
                    if (i < steps.length - 1)
                      Container(
                          margin: const EdgeInsets.only(left: 36),
                          width: 2,
                          height: 34,
                          color: (steps[i]['done'] as bool) ? hGold : hBorder),
                  ],
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(
                      steps[i]['label'] as String,
                      style: TextStyle(
                        // Mockup #1: done step white, CURRENT step
                        // gold, pending step muted grey.
                        color: (steps[i]['done'] as bool)
                            ? Colors.white
                            : (steps[i]['current'] as bool)
                                ? hGold
                                : hText2,
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                  ),
                ),
                if (i == 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(joined ? '1/3' : '0/3',
                        style: const TextStyle(
                            color: hGold,
                            fontWeight: FontWeight.bold,
                            fontSize: 15)),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

/// Phase 2 — Match Countdown page (#1): big countdown + timeline +
/// Remind Me (writes match_reminders via the data layer).
class MatchCountdownPage extends StatefulWidget {
  final Map<String, dynamic> tournament;
  const MatchCountdownPage({super.key, required this.tournament});
  @override
  State<MatchCountdownPage> createState() => _MatchCountdownPageState();
}

class _MatchCountdownPageState extends State<MatchCountdownPage> {
  bool? _hasReminder;

  @override
  void initState() {
    super.initState();
    _loadReminder();
  }

  Future<void> _loadReminder() async {
    final uid = FirebaseAuth.instance.currentUser!.uid;
    final has =
        await SupaDb.hasMatchReminder(strVal(widget.tournament['id']), uid);
    if (mounted) setState(() => _hasReminder = has);
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.tournament;
    final uid = FirebaseAuth.instance.currentUser!.uid;
    final id = strVal(t['id']);
    final startMs = intVal(t['startTime']);
    final status = tStatus(t);
    final ts = teamSizeOf(t);
    final maxP = intVal(t['maxPlayers'], 0);
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent, // PHASE E (E4): transparent header — poster shows through
        title: const FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text('MATCH COUNTDOWN',
                style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w900,
                    fontSize: 24))),
        actions: [
          // Mockup header bell with the REAL unread badge (same
          // pattern as the Home header) + the crown logo.
          StreamBuilder<int>(
            stream: SupaDb.streamUnreadCount(uid),
            builder: (context, usnap) {
              final unread = usnap.data ?? 0;
              return Stack(
                children: [
                  IconButton(
                    icon: const Icon(Icons.notifications_outlined,
                        color: Colors.white, size: 26),
                    onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => NotificationsPage(uid: uid))),
                  ),
                  if (unread > 0)
                    Positioned(
                      right: 6,
                      top: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(
                            color: Colors.redAccent,
                            borderRadius: BorderRadius.circular(10)),
                        child: Text(unread > 9 ? '9+' : '$unread',
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.bold)),
                      ),
                    ),
                ],
              );
            },
          ),
          const Padding(
              padding: EdgeInsets.only(right: 12),
              child:
                  ArenaLogo(crownSize: 30, fontSize: 16, showWordmark: false)),
        ],
      ),
      body: StreamBuilder<List<Map<String, dynamic>>>(
        stream: SupaDb.streamRegistrations(id),
        builder: (context, snap) {
          final regs = snap.data ?? [];
          final myReg =
              regs.where((r) => strVal(r['firebase_uid']) == uid).toList();
          final joined = myReg.isNotEmpty;
          final myTeam = joined ? strVal(myReg.first['team_name']) : '';
          final mySquad = joined ? squadIdFor(id, myTeam) : '';
          final squadCount = ts > 1 && mySquad.isNotEmpty
              ? regs
                  .where(
                      (r) => squadIdFor(id, strVal(r['team_name'])) == mySquad)
                  .length
              : (joined ? 1 : 0);
          // P0-1: count PLAYERS, not rows x teamSize (RPC rows are
          // one-per-member).
          final joinedCount = SupaDb.registrationPlayerCount(regs);
          return SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Wave B #1 — mockup hero: real banner cover, big
                // two-tone title, MATCH STARTS IN + the huge gold
                // HH:MM:SS countdown with HOURS/MINUTES/SECONDS.
                // 2026-11-20 USER CORRECTION (global card rule):
                // the flat gold border is gone — the hero is a
                // _DarkMockupCard (two orbiting yellow shines, no
                // static border), padding zero so the cover stays
                // edge-to-edge.
                _DarkMockupCard(
                  padding: EdgeInsets.zero,
                  radius: 18,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(18),
                    child: Container(
                      width: double.infinity,
                      color: hCard,
                      child: Stack(
                        children: [
                          Positioned.fill(child: _coverImage(tImage(t))),
                          Positioned.fill(
                            child: Container(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [
                                    Colors.black.withValues(alpha: 0.35),
                                    Colors.black.withValues(alpha: 0.55),
                                    Colors.black.withValues(alpha: 0.85)
                                  ],
                                ),
                              ),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 20, 16, 20),
                            child: Column(
                              children: [
                                _twoToneTitle(tName(t),
                                    fontSize: 40, align: TextAlign.center),
                                const SizedBox(height: 16),
                                const Text('MATCH STARTS IN',
                                    style: TextStyle(
                                        color: hGold,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 14,
                                        letterSpacing: 1.5)),
                                const SizedBox(height: 4),
                                _DigitalCountdown(
                                    targetMs: startMs,
                                    status: status,
                                    fontSize: 56,
                                    glow: true,
                                    dimSeconds: true),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                // Mockup info card: Mode & Map chips, YOUR TEAM +
                // players pill, Schedule.
                _homeGlassCard(
                  borderColor: hGold.withValues(alpha: 0.45),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          const Text('Mode & Map',
                              style: TextStyle(color: hText2, fontSize: 14)),
                          const SizedBox(width: 10),
                          _goldPill(strVal(t['mode'], 'Solo').toUpperCase(),
                              bg: hSecondary, fg: hGold, icon: Icons.group),
                          const SizedBox(width: 8),
                          // Mockup #1: the MAP pill is GOLD FILLED
                          // (black text/icon) while the MODE pill is
                          // dark with gold text.
                          _goldPill(
                            strVal(t['map']).isEmpty
                                ? (tGame(t).isEmpty
                                    ? 'ARENA'
                                    : tGame(t).toUpperCase())
                                : strVal(t['map']).toUpperCase(),
                            icon: strVal(t['map']).isEmpty
                                ? Icons.sports_esports
                                : Icons.place,
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 10),
                        decoration: BoxDecoration(
                            color: hSecondary,
                            borderRadius: BorderRadius.circular(12)),
                        child: Row(
                          children: [
                            Expanded(
                              child: RichText(
                                text: TextSpan(
                                  style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 14,
                                      fontWeight: FontWeight.bold),
                                  children: [
                                    const TextSpan(text: 'YOUR TEAM: '),
                                    TextSpan(
                                        text: myTeam.isEmpty
                                            ? (joined
                                                ? '—'
                                                : 'Not registered yet')
                                            : myTeam.toUpperCase(),
                                        style: const TextStyle(color: hGold)),
                                  ],
                                ),
                              ),
                            ),
                            // P2 (mockup #1): the mockup's team
                            // emblem is a detailed helmet-in-shield,
                            // not the generic Icons.shield glyph.
                            const SizedBox(
                                width: 26,
                                height: 26,
                                child: CustomPaint(
                                    painter: _HelmetShieldPainter())),
                            const SizedBox(width: 8),
                            Text(
                              joined
                                  ? '$squadCount/$ts Players'
                                  : (maxP > 0
                                      ? '$joinedCount/$maxP Players'
                                      : '$joinedCount Players'),
                              style: const TextStyle(
                                  color: hGold,
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          const Text('Schedule',
                              style: TextStyle(color: hText2, fontSize: 14)),
                          const SizedBox(width: 10),
                          const Icon(Icons.access_time,
                              color: Colors.white, size: 16),
                          const SizedBox(width: 6),
                          Text(_matchTimeLabel(startMs),
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold)),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                _MatchTimeline(
                    tournament: t,
                    joined: joined,
                    roomVisible: roomVisibleFor(t)),
                const SizedBox(height: 8),
                // Mockup REMIND ME row: bell + label + ON/OFF + the
                // same match_reminders toggle as before.
                _homeGlassCard(
                  borderColor: hGold.withValues(alpha: 0.45),
                  child: Row(
                    children: [
                      Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                              color: hGold.withValues(alpha: 0.15),
                              shape: BoxShape.circle,
                              // P2 (mockup #1): the bell sits in a
                              // GOLD-RINGED circle, not a plain tint.
                              border:
                                  Border.all(color: hGold, width: 1.5)),
                          child: const Icon(Icons.notifications,
                              color: hGold, size: 22)),
                      const SizedBox(width: 12),
                      const Expanded(
                          child: Text('REMIND ME',
                              style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w900,
                                  fontSize: 16,
                                  letterSpacing: 0.5))),
                      Text(_hasReminder == true ? 'ON' : 'OFF',
                          style: const TextStyle(
                              color: hGold,
                              fontWeight: FontWeight.bold,
                              fontSize: 14)),
                      Switch(
                        value: _hasReminder == true,
                        // Mockup #1: gold track + white thumb when ON.
                        activeThumbColor: Colors.white,
                        activeTrackColor: hGold,
                        inactiveThumbColor: hText2,
                        inactiveTrackColor: hBorder,
                        onChanged: _hasReminder == null
                            ? null
                            : (v) async {
                                final wasSet = _hasReminder == true;
                                if (wasSet) {
                                  await SupaDb.removeMatchReminder(id, uid);
                                } else {
                                  await SupaDb.setMatchReminder(id, uid);
                                }
                                if (!context.mounted) return;
                                setState(() => _hasReminder = !wasSet);
                                toast(
                                    context,
                                    wasSet
                                        ? 'Reminder cancelled.'
                                        : 'Reminder set — we will notify you before the match.');
                              },
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) =>
                                    MatchDetailsPage(tournament: t))),
                        style: OutlinedButton.styleFrom(
                            side: const BorderSide(color: hGold, width: 1.5),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12))),
                        child: const Text('MATCH DETAILS',
                            style: TextStyle(
                                color: hGold,
                                fontWeight: FontWeight.w900,
                                fontSize: 14)),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: ElevatedButton(
                        // P2 (mockup #1): TEAM ROSTER opens the
                        // dedicated roster view (live registrations
                        // with presence dots) — NOT the Match Room.
                        onPressed: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) =>
                                    TeamRosterPage(tournament: t))),
                        style: ElevatedButton.styleFrom(
                            backgroundColor: hGold,
                            foregroundColor: Colors.black,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12)),
                            elevation: 0),
                        child: const Text('TEAM ROSTER',
                            style: TextStyle(
                                fontWeight: FontWeight.w900, fontSize: 14)),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// P2 (mockup #1) — drawn helmet-in-shield emblem: a gold shield
/// outline with a helmet dome + visor slit inside. The mockup's team
/// emblem is a detailed helmet-shield, not the generic Icons.shield
/// glyph; this is drawn art (own asset), never a copied game image.
class _HelmetShieldPainter extends CustomPainter {
  const _HelmetShieldPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final gold = Paint()
      ..color = hGold
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeJoin = StrokeJoin.round;
    final goldFill = Paint()..color = hGold;
    final dark = Paint()..color = hBg;
    final w = size.width, h = size.height;
    // Shield outline.
    final shield = Path()
      ..moveTo(w * 0.08, h * 0.10)
      ..lineTo(w * 0.92, h * 0.10)
      ..lineTo(w, h * 0.32)
      ..lineTo(w * 0.78, h * 0.72)
      ..lineTo(w * 0.5, h)
      ..lineTo(w * 0.22, h * 0.72)
      ..lineTo(0, h * 0.32)
      ..close();
    canvas.drawPath(shield, gold);
    // Inner rim.
    final rim = Path()
      ..moveTo(w * 0.16, h * 0.17)
      ..lineTo(w * 0.84, h * 0.17)
      ..lineTo(w * 0.92, h * 0.33)
      ..lineTo(w * 0.74, h * 0.66)
      ..lineTo(w * 0.5, h * 0.90)
      ..lineTo(w * 0.26, h * 0.66)
      ..lineTo(w * 0.08, h * 0.33)
      ..close();
    canvas.drawPath(
        rim,
        Paint()
          ..color = hGold.withValues(alpha: 0.35)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1);
    // Helmet dome (gold arc) + brim.
    final dome = Path()
      ..moveTo(w * 0.28, h * 0.52)
      ..arcTo(
          Rect.fromLTWH(w * 0.24, h * 0.18, w * 0.52, h * 0.42),
          3.14159,
          3.14159,
          false)
      ..lineTo(w * 0.72, h * 0.52)
      ..close();
    canvas.drawPath(dome, goldFill);
    // Visor slit (dark) + centre ridge.
    canvas.drawRRect(
        RRect.fromLTRBR(
            w * 0.30, h * 0.54, w * 0.70, h * 0.60, const Radius.circular(2)),
        dark);
    canvas.drawLine(Offset(w * 0.5, h * 0.22), Offset(w * 0.5, h * 0.50),
        gold..strokeWidth = 1.2);
    // Cheek-guard ticks.
    canvas.drawLine(Offset(w * 0.34, h * 0.62), Offset(w * 0.34, h * 0.72),
        gold..strokeWidth = 1.2);
    canvas.drawLine(Offset(w * 0.66, h * 0.62), Offset(w * 0.66, h * 0.72),
        gold..strokeWidth = 1.2);
  }

  @override
  bool shouldRepaint(covariant _HelmetShieldPainter old) => false;
}

/// P2 (mockup #1) — TEAM ROSTER dedicated view. Live data only, no
/// new backend: streams the existing
/// [SupaDb.streamRegistrations] and renders the shared
/// [_ReadyPlayersList] (real avatar + presence dot + squad/slot +
/// Ready pill per player). Entry: the TEAM ROSTER button on
/// MatchCountdownPage.
class TeamRosterPage extends StatelessWidget {
  final Map<String, dynamic> tournament;
  const TeamRosterPage({super.key, required this.tournament});

  @override
  Widget build(BuildContext context) {
    final id = strVal(tournament['id']);
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent, // PHASE E (E4): transparent header — poster shows through
        leading: IconButton(
          icon: const Icon(Icons.chevron_left, color: hGold, size: 30),
          onPressed: () => Navigator.maybePop(context),
        ),
        title: const Text('TEAM ROSTER',
            style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w900,
                fontSize: 20)),
      ),
      body: StreamBuilder<List<Map<String, dynamic>>>(
        stream: SupaDb.streamRegistrations(id),
        builder: (context, snap) {
          final regs = snap.data ?? [];
          return SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(tName(tournament).toUpperCase(),
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w900,
                        fontSize: 18)),
                const SizedBox(height: 4),
                Text(
                    regs.isEmpty
                        ? 'No players registered yet.'
                        : '${regs.length} registration${regs.length == 1 ? '' : 's'}',
                    style: const TextStyle(color: hText2, fontSize: 13)),
                const SizedBox(height: 16),
                _ReadyPlayersList(
                    tournamentId: id, registrations: regs),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Phase 2 — shared ready-players list (#14): every registration
/// row is a real "ready" player (registered). Presence dot shows
/// online state. (Wave 4b #19: MatchRoomPage no longer uses this
/// list — it renders its own squad card — so the mySquadId filter
/// was removed; #14 passes the full registration list.)
class _ReadyPlayersList extends StatelessWidget {
  final String tournamentId;
  final List<Map<String, dynamic>> registrations;
  const _ReadyPlayersList(
      {required this.tournamentId, required this.registrations});

  @override
  Widget build(BuildContext context) {
    final regs = registrations;
    if (regs.isEmpty)
      return Text('No players joined yet.', style: TextStyle(color: kMuted));
    return Column(
      children: [
        for (final p in regs)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: appCard(
              child: Row(
                children: [
                  CachedFramedAvatar(
                      uid: strVal(p['firebase_uid']),
                      name: strVal(p['username'], 'Player'),
                      radius: 16),
                  const SizedBox(width: 8),
                  PresenceDot(
                      uid: strVal(p['firebase_uid']), showLastSeen: true),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(strVal(p['username'], 'Player'),
                            style: TextStyle(
                                color: kText, fontWeight: FontWeight.bold)),
                        if (strVal(p['team_name']).isNotEmpty)
                          Text(
                              'Squad: ${p['team_name']} • Slot ${SupaDb.slotOf(p) > 0 ? SupaDb.slotOf(p) : '-'}',
                              style: TextStyle(color: kMuted, fontSize: 12)),
                      ],
                    ),
                  ),
                  Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                          color: Colors.green.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(10)),
                      child: const Text('Ready',
                          style: TextStyle(
                              color: Colors.green,
                              fontWeight: FontWeight.bold,
                              fontSize: 11))),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// Phase 2 — Match Details page (#14): hero + info grid +
/// countdown + timeline + locked/released room + ready players +
/// rules + organizer announcement + chat entry. All data is live
/// (tournament row + registrations stream); the announcement is
/// the tournament description — no separate announcement column
/// exists live, so an empty description hides the section rather
/// than inventing text.
/// Wave B #14 — MATCH INFO cell: gold icon, small muted label,
/// bold white value, centred.
Widget _matchInfoCell(IconData icon, String label, String value) {
  return Column(
    children: [
      Icon(icon, color: hGold, size: 22),
      const SizedBox(height: 4),
      Text(label,
          style:
              const TextStyle(color: hText2, fontSize: 10, letterSpacing: 0.5),
          textAlign: TextAlign.center),
      const SizedBox(height: 2),
      Text(value,
          style: const TextStyle(
              color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis),
    ],
  );
}

/// Wave B #14 — compact ROOM DETAILS card for the right column:
/// SECURE + LOCKED pill + the locked note, or the real credentials
/// with a Copy All button when the organizer released them (same
/// gating rule as everywhere else).
/// B-11 (2026-11-21): credentials come ONLY from
/// getRoomCredentials (026 RPC) — never off the tournament row.
Widget _roomDetailsCompact(
    BuildContext context, Map<String, dynamic> t, bool roomVisible) {
  // A-5 (026): OFF -> "Band hai" + reason, credentials hidden, pill
  // BAND HAI. Read failure = ON (getRoomControl returns {} then).
  // B-11: the RPC failure half fails closed too — a failed
  // credentials call shows an honest load error, never the row.
  return FutureBuilder<List<Map<String, dynamic>>>(
    future: Future.wait([
      SupaDb.getRoomControl(strVal(t['id'])),
      SupaDb.getRoomCredentials(strVal(t['id'])),
    ]),
    builder: (context, snap) {
      final control =
          (snap.data?.length ?? 0) > 0 ? snap.data![0] : <String, dynamic>{};
      final creds =
          (snap.data?.length ?? 0) > 1 ? snap.data![1] : <String, dynamic>{};
      final credsOk = creds['ok'] == true;
      final roomId = SupaDb.strOf(creds['roomId']);
      final roomPass = SupaDb.strOf(creds['roomPassword']);
      final voiceOff = SupaDb.isRoomVoiceDisabled(control);
      final reason = SupaDb.strOf(control['disabled_reason']);
      // 2026-11-20: _DarkMockupCard (global card rule — no full
      // border); the SizedBox keeps the card full-width in the
      // right column.
      return SizedBox(
        width: double.infinity,
        child: _DarkMockupCard(
          padding: const EdgeInsets.all(12),
          radius: 16,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('ROOM DETAILS',
                  style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w900,
                      fontSize: 14)),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Icon(Icons.lock, color: hText2, size: 14),
                  const SizedBox(width: 4),
                  const Text('SECURE',
                      style: TextStyle(
                          color: hText2,
                          fontSize: 11,
                          fontWeight: FontWeight.bold)),
                  const Spacer(),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                        color: voiceOff
                            ? Colors.red
                            : (roomVisible ? Colors.green : Colors.orange),
                        borderRadius: BorderRadius.circular(10)),
                    child: Text(
                        voiceOff
                            ? 'BAND HAI'
                            : (roomVisible ? 'OPEN' : 'LOCKED'),
                        style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 10)),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              const Text('Room ID & Password',
                  style: TextStyle(color: hText2, fontSize: 12)),
              const SizedBox(height: 6),
              if (voiceOff)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                      color: Colors.red.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(10)),
                  child: Text(
                      reason.isNotEmpty
                          ? 'Room band hai — $reason'
                          : 'Room band hai — voice join abhi band hai.',
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                      textAlign: TextAlign.center),
                )
              else if (!roomVisible)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                      color: hSecondary,
                      borderRadius: BorderRadius.circular(10)),
                  child: const Text(
                      'Room details will be available when the organizer releases them.',
                      style: TextStyle(color: hText2, fontSize: 12),
                      textAlign: TextAlign.center),
                )
              else if (!credsOk)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                      color: hSecondary,
                      borderRadius: BorderRadius.circular(10)),
                  child: const Text(
                      'Room details abhi load nahi ho sake — dobara try karein.',
                      style: TextStyle(color: hText2, fontSize: 12),
                      textAlign: TextAlign.center),
                )
              else ...[
                Text('ID: ${roomId.isEmpty ? 'Not announced yet' : roomId}',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.bold)),
                Text(
                    'Pass: ${roomPass.isEmpty ? 'Not announced yet' : roomPass}',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(
                          text: 'Room ID: $roomId\nPassword: $roomPass'));
                      if (context.mounted)
                        toast(context, 'Room details copied.');
                    },
                    style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: hGold),
                        padding: const EdgeInsets.symmetric(vertical: 6)),
                    child: const Text('Copy All',
                        style: TextStyle(color: hGold, fontSize: 12)),
                  ),
                ),
              ],
            ],
          ),
        ),
      );
    },
  );
}

/// Wave B #14 — YOUR TEAM card: the real squad (my registration's
/// team), gold ring on EVERY member, READY pill under mates only
/// (mockup #14: "Player • Lv.5" under #1, green READY✓ pills under
/// #2–4). FIX ROUND I-all-fix1-A (#14): the READY pill overlaps
/// the avatar's bottom edge like the mockup, and MY OWN row shows
/// "name • Lv.N" from the real profiles.level (mates have no level
/// in the model, so only my row carries one).
Widget _yourTeamCard(
    List<Map<String, dynamic>> squadRegs, String teamName, String myUid,
    {int myLevel = 1}) {
  // 2026-11-20: _DarkMockupCard (global card rule — no full border).
  return _DarkMockupCard(
    padding: const EdgeInsets.all(14),
    radius: 16,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        RichText(
          text: TextSpan(
            style: const TextStyle(
                color: Colors.white, fontWeight: FontWeight.w900, fontSize: 16),
            children: [
              const TextSpan(text: 'YOUR TEAM: '),
              TextSpan(
                  text: teamName.isEmpty ? '—' : teamName.toUpperCase(),
                  style: const TextStyle(color: hGold)),
            ],
          ),
        ),
        const SizedBox(height: 12),
        if (squadRegs.isEmpty)
          const Text('No players joined yet.', style: TextStyle(color: hText2))
        else
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final p in squadRegs)
                Expanded(
                  child: Column(
                    children: [
                      Stack(
                        clipBehavior: Clip.none,
                        children: [
                          Container(
                            padding: const EdgeInsets.all(2),
                            decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                // P2 (mockup #14): ALL 4 avatars carry
                                // the gold ring — not just mine.
                                border:
                                    Border.all(color: hGold, width: 2)),
                            child: CachedFramedAvatar(
                                uid: strVal(p['firebase_uid']),
                                name: strVal(p['username'], 'Player'),
                                radius: 26),
                          ),
                          // P2 (mockup #14): the READY pill sits
                          // under MATES only — my row carries
                          // "Player • Lv.N" instead.
                          if (strVal(p['firebase_uid']) != myUid)
                            Positioned(
                            bottom: -9,
                            left: 0,
                            right: 0,
                            child: Center(
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                    color: Colors.green.withValues(alpha: 0.15),
                                    borderRadius: BorderRadius.circular(8)),
                                child: const Text('READY ✓',
                                    style: TextStyle(
                                        color: Colors.green,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 9)),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 15),
                      Text(
                        strVal(p['username'], 'Player') +
                            (strVal(p['firebase_uid']) == myUid
                                ? ' • Lv.$myLevel'
                                : ''),
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.bold),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
            ],
          ),
      ],
    ),
  );
}

class MatchDetailsPage extends StatelessWidget {
  final Map<String, dynamic> tournament;
  const MatchDetailsPage({super.key, required this.tournament});

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser!.uid;
    final id = strVal(tournament['id']);
    return ValueListenableBuilder<int>(
      valueListenable: SupaDb.refreshNotifier,
      builder: (context, nonce, _) {
        return StreamBuilder<Map<String, dynamic>>(
          key: ValueKey('mdetail-$nonce'),
          stream: SupaDb.streamTournament(id),
          builder: (context, snap) {
            var t = tournament;
            if (snap.hasData && (snap.data ?? {}).isNotEmpty) t = snap.data!;
            return StreamBuilder<List<Map<String, dynamic>>>(
              stream: SupaDb.streamRegistrations(id),
              builder: (context, rsnap) {
                final regs = rsnap.data ?? [];
                final myReg = regs
                    .where((r) => strVal(r['firebase_uid']) == uid)
                    .toList();
                final joined = myReg.isNotEmpty;
                final ts = teamSizeOf(t);
                final status = tStatus(t);
                final startMs = intVal(t['startTime']);
                final lobbyMs = lobbyOpensMsFor(t);
                final roomVisible = roomVisibleFor(t);
                final nowMs = DateTime.now().millisecondsSinceEpoch;
                final lobbyOpen =
                    lobbyMs > 0 && nowMs >= lobbyMs && status == 'upcoming';
                final myTeam = joined ? strVal(myReg.first['team_name']) : '';
                final mySquad = joined ? squadIdFor(id, myTeam) : '';
                final squadRegs = ts > 1 && mySquad.isNotEmpty
                    ? regs
                        .where((r) =>
                            squadIdFor(id, strVal(r['team_name'])) == mySquad)
                        .toList()
                    : myReg;
                final modeLabel = strVal(t['perspective']).isEmpty
                    ? strVal(t['mode'], 'Solo').toUpperCase()
                    : '${strVal(t['mode'], 'Solo').toUpperCase()} ${strVal(t['perspective']).toUpperCase()}';
                return Scaffold(
                  appBar: AppBar(
                    backgroundColor: Colors.transparent, // PHASE E (E4): transparent header — poster shows through
                    // P2 (mockup #14): plain gold chevron back, not
                    // the default AppBar arrow.
                    leading: IconButton(
                      icon: const Icon(Icons.chevron_left,
                          color: hGold, size: 30),
                      onPressed: () => Navigator.maybePop(context),
                    ),
                    // J-detail-fix1 (#14): mockup title is ITALIC
                    // w900 ~22 (was upright 20).
                    title: const FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text('MATCH DETAILS',
                            style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w900,
                                fontStyle: FontStyle.italic,
                                fontSize: 22))),
                    actions: [
                      IconButton(
                        icon: const Icon(Icons.share, color: Colors.white),
                        tooltip: 'Share',
                        onPressed: () async {
                          final link = 'protournament://tournament/$id';
                          final text =
                              'Join ${tName(t)} on ARENA HUB! Tournament link: $link (App me Tournaments → search karen ya link paste karen)';
                          final uri = Uri.parse(
                              'https://wa.me/?text=${Uri.encodeComponent(text)}');
                          if (await canLaunchUrl(uri))
                            await launchUrl(uri,
                                mode: LaunchMode.externalApplication);
                        },
                      ),
                    ],
                  ),
                  body: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Wave B #14 — mockup hero: real banner cover
                        // with the real status pill, the REAL name in
                        // two-tone italic, and the real mode • game
                        // line. GAP: no match number exists in the
                        // model, so "Match #1" is not shown.
                        ClipRRect(
                          borderRadius: BorderRadius.circular(16),
                          child: SizedBox(
                            height: 200,
                            width: double.infinity,
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                _coverImage(tImage(t)),
                                Container(
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                      begin: Alignment.topCenter,
                                      end: Alignment.bottomCenter,
                                      colors: [
                                        Colors.transparent,
                                        Colors.black.withValues(alpha: 0.4),
                                        Colors.black.withValues(alpha: 0.85)
                                      ],
                                    ),
                                  ),
                                ),
                                // Mockup #14: the status pill sits
                                // top-left over the banner — the
                                // UPCOMING pill carries a clock icon.
                                // ("Tournament Hero" was a mockup
                                // annotation, not UI copy — removed
                                // 2026-11-20 per the inventory.)
                                Positioned(
                                    top: 12,
                                    left: 12,
                                    child: status == 'upcoming'
                                        ? _goldPill('UPCOMING',
                                            icon: Icons.access_time)
                                        : _statusPill2(status)),
                                Positioned(
                                  left: 14,
                                  right: 14,
                                  bottom: 14,
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      // Mockup #14: "WEEKEND |
                                      // COMMUNITY CUP" — last words
                                      // gold (_heroTitle), not first
                                      // word gold.
                                      _heroTitle(tName(t)),
                                      const SizedBox(height: 4),
                                      Text(
                                          '${strVal(t['mode'], 'Solo')} • ${tGame(t).isEmpty ? 'Arena' : tGame(t)}',
                                          style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 14)),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        // Mockup grid: MATCH INFO left, LOBBY OPENS
                        // IN + ROOM DETAILS right.
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              flex: 5,
                              child: _DarkMockupCard(
                                padding: const EdgeInsets.all(12),
                                radius: 16,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text('MATCH INFO',
                                        style: TextStyle(
                                            color: Colors.white,
                                            fontWeight: FontWeight.w900,
                                            fontSize: 15)),
                                    const SizedBox(height: 12),
                                    Row(
                                      children: [
                                        Expanded(
                                            child: _matchInfoCell(
                                                Icons.sports_esports,
                                                'GAME MODE',
                                                modeLabel)),
                                        // J-detail-fix1 (#14): mockup
                                        // MAP icon is a map-pin.
                                        Expanded(
                                            child: _matchInfoCell(
                                                Icons.place,
                                                'MAP',
                                                strVal(t['map']).isEmpty
                                                    ? '—'
                                                    : strVal(t['map']))),
                                      ],
                                    ),
                                    const SizedBox(height: 12),
                                    Row(
                                      children: [
                                        Expanded(
                                            child: _matchInfoCell(
                                                Icons.access_time,
                                                'SCHEDULED START',
                                                _shortDate(startMs))),
                                        Expanded(
                                            child: _matchInfoCell(
                                                Icons.alarm,
                                                'LOBBY OPENS',
                                                _shortDate(lobbyMs))),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              flex: 4,
                              child: Column(
                                children: [
                                  InkWell(
                                    onTap: () => Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                            builder: (_) => MatchCountdownPage(
                                                tournament: t))),
                                    borderRadius: BorderRadius.circular(16),
                                    // 2026-11-20: _DarkMockupCard
                                    // (global card rule — no full gold
                                    // border); the SizedBox keeps the
                                    // card full-width in this column.
                                    child: SizedBox(
                                      width: double.infinity,
                                      child: _DarkMockupCard(
                                        padding: const EdgeInsets.all(12),
                                        radius: 16,
                                        child: Column(
                                          children: [
                                            const Text('LOBBY OPENS IN',
                                                style: TextStyle(
                                                    color: hText2,
                                                    fontSize: 11,
                                                    fontWeight: FontWeight.bold,
                                                    letterSpacing: 0.5)),
                                            const SizedBox(height: 6),
                                            lobbyOpen
                                                ? const Text('LOBBY OPEN',
                                                    style: TextStyle(
                                                        color: hGold,
                                                        fontWeight:
                                                            FontWeight.w900,
                                                        fontSize: 18))
                                                // J-detail-fix1 (#14):
                                                // mockup lobby countdown
                                                // has NO unit labels.
                                                : _DigitalCountdown(
                                                    targetMs: lobbyMs,
                                                    status: status,
                                                    fontSize: 26,
                                                    showLabels: false),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 10),
                                  _roomDetailsCompact(context, t, roomVisible),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        // YOUR TEAM (joined) or all ready players.
                        if (joined) ...[
                          // FIX ROUND I-all-fix1-A (#14): my own
                          // profiles.level for the "• Lv.N" under my
                          // avatar — the same default (1) ProfilePage
                          // uses when the level is unset.
                          StreamBuilder<Map<String, dynamic>>(
                            stream: SupaDb.streamProfile(uid),
                            builder: (context, psnap) {
                              final level =
                                  intVal((psnap.data ?? {})['level'], 1);
                              return _yourTeamCard(squadRegs, myTeam, uid,
                                  myLevel: level);
                            },
                          ),
                        ] else ...[
                          const Text('Players — Ready',
                              style: TextStyle(
                                  color: hGold,
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold)),
                          const SizedBox(height: 8),
                          _ReadyPlayersList(
                              tournamentId: id, registrations: regs),
                        ],
                        const SizedBox(height: 12),
                        // Mockup TOURNAMENT RULES row -> real rules.
                        InkWell(
                          onTap: () => showInfoDialog(
                              context,
                              'Tournament Rules',
                              strVal(t['rules']).isNotEmpty
                                  ? strVal(t['rules'])
                                  : 'Fair play: no cheating, no abusive language, no account sharing. Follow the room instructions from the organizer. Violations may lead to disqualification.'),
                          borderRadius: BorderRadius.circular(12),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 12),
                            decoration: BoxDecoration(
                                color: hGold.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                    color: hGold.withValues(alpha: 0.4))),
                            child: Row(
                              children: [
                                const Icon(Icons.description,
                                    color: hGold, size: 20),
                                const SizedBox(width: 10),
                                const Expanded(
                                    child: Text('TOURNAMENT RULES',
                                        style: TextStyle(
                                            color: Colors.white,
                                            fontWeight: FontWeight.w900,
                                            fontSize: 15))),
                                const Text('See Details →',
                                    style: TextStyle(
                                        color: hGold,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 13)),
                              ],
                            ),
                          ),
                        ),
                        // FIX ROUND I-all-fix1-A (#14): the mockup
                        // always shows ORGANIZER ANNOUNCEMENT — an
                        // empty description shows an honest note
                        // instead of hiding the whole section.
                        const SizedBox(height: 16),
                        const Text('ORGANIZER ANNOUNCEMENT',
                            style: TextStyle(
                                color: kSectionLabel,
                                fontWeight: FontWeight.w900,
                                fontSize: 16)),
                        const SizedBox(height: 8),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Icon(Icons.warning_amber_rounded,
                                color: hGold, size: 20),
                            const SizedBox(width: 8),
                            Expanded(
                                child: Text(
                                    strVal(t['description']).isNotEmpty
                                        ? strVal(t['description'])
                                        : 'No announcement from the organizer yet.',
                                    style: const TextStyle(
                                        color: hText2,
                                        fontSize: 14,
                                        height: 1.5))),
                          ],
                        ),
                        const SizedBox(height: 20),
                        // SUBMIT RESULT entry point (2026-11-21): same
                        // rule as the tournament detail page — a
                        // finished match the player registered for
                        // shows this gold button; it opens
                        // UploadResultPage.
                        if (canSubmitResultFor(
                            joined: joined,
                            status: status,
                            startMs: startMs)) ...[
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton.icon(
                              onPressed: () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                      builder: (_) => UploadResultPage(
                                          tournamentId: id))),
                              icon: const Icon(Icons.upload, size: 20),
                              label: const Text('SUBMIT RESULT',
                                  style: TextStyle(
                                      fontWeight: FontWeight.w900,
                                      fontSize: 16)),
                              style: ElevatedButton.styleFrom(
                                  backgroundColor: hGold,
                                  foregroundColor: Colors.black,
                                  padding: const EdgeInsets.symmetric(
                                      vertical: 15),
                                  // P2 (mockup #14): full pill (~28),
                                  // not radius 14.
                                  shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(28)),
                                  elevation: 0),
                            ),
                          ),
                          const SizedBox(height: 12),
                        ],
                        // v2016 FIX 11(a): the tournament room entry
                        // was removed — voice/chat rooms now live in
                        // the team chat (TeamChatPage Voice button).
                      ],
                    ),
                  ),
                );
              },
            );
          },
        );
      },
    );
  }
}

/// Phase 2 — Match Room page (#19): LIVE/READY banner, countdown,
/// Room ID/password (released or locked), squad ready list,
/// organizer note, match chat entry, fair-play footer.
class MatchRoomPage extends StatelessWidget {
  final Map<String, dynamic> tournament;
  const MatchRoomPage({super.key, required this.tournament});

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser!.uid;
    final id = strVal(tournament['id']);
    return ValueListenableBuilder<int>(
      valueListenable: SupaDb.refreshNotifier,
      builder: (context, nonce, _) {
        return StreamBuilder<Map<String, dynamic>>(
          key: ValueKey('mroom-$nonce'),
          stream: SupaDb.streamTournament(id),
          builder: (context, snap) {
            var t = tournament;
            if (snap.hasData && (snap.data ?? {}).isNotEmpty) t = snap.data!;
            return StreamBuilder<List<Map<String, dynamic>>>(
              stream: SupaDb.streamRegistrations(id),
              builder: (context, rsnap) {
                final regs = rsnap.data ?? [];
                final myReg = regs
                    .where((r) => strVal(r['firebase_uid']) == uid)
                    .toList();
                final joined = myReg.isNotEmpty;
                final status = tStatus(t);
                final myTeam = joined ? strVal(myReg.first['team_name']) : '';
                final isTeam = teamSizeOf(t) > 1;
                // Squad list: team modes show the whole squad; Solo
                // shows only my own row (a Solo "squad" is one player).
                final squadRegs = isTeam
                    ? regs
                    : regs
                        .where((r) => strVal(r['firebase_uid']) == uid)
                        .toList();
                // Wave 4b #19: mockup layout — hero banner (real
                // cover + LIVE/READY + mode pills), gold countdown
                // card, ROOM DETAILS with RELEASED pill + copy
                // icons + COPY ALL, squad card, organizer note,
                // fair-play footer. (v2016 FIX 11: the match-chat
                // button was removed — voice/chat rooms now live
                // in the team chat.) The Room ID/password gating
                // + RPC flow and all behaviour are unchanged —
                // only the layout moved.
                return Scaffold(
                  appBar: AppBar(
                    centerTitle: true,
                    // FIX ROUND I-all-fix1-A (#19): mockup back arrow
                    // sits in a bordered square box (same pattern as
                    // NotificationsPage).
                    automaticallyImplyLeading: false,
                    leading: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Container(
                        decoration: BoxDecoration(
                            border: Border.all(color: hBorder),
                            borderRadius: BorderRadius.circular(10)),
                        child: IconButton(
                            // P2 (mockup #19): the back chevron is
                            // GOLD in its bordered box, not white.
                            icon: const Icon(Icons.chevron_left,
                                color: hGold, size: 24),
                            padding: EdgeInsets.zero,
                            onPressed: () => Navigator.maybePop(context)),
                      ),
                    ),
                    title: const Text('MATCH ROOM',
                        style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w900,
                            fontSize: 26)),
                    actions: [
                      IconButton(
                        icon: Container(
                          padding: const EdgeInsets.all(7),
                          decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: hCard,
                              border: Border.all(color: hBorder)),
                          child: const Text('?',
                              style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14)),
                        ),
                        tooltip: 'About this room',
                        onPressed: () => showDialog<void>(
                          context: context,
                          builder: (_) => AlertDialog(
                            backgroundColor: kCardPurpleMid,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22), side: const BorderSide(color: kCardPurpleBorder, width: 1.5)),
                            title: Text('Match Room',
                                style: TextStyle(color: kGold)),
                            content: Text(
                              'The organizer releases the Room ID and password shortly before the match starts. Enter the in-game lobby with those details — the match starts sharp. No emulators, no cheating, no teaming.',
                              style: TextStyle(color: kText),
                            ),
                            actions: [
                              TextButton(
                                  onPressed: () => Navigator.pop(context),
                                  child: Text('OK',
                                      style: TextStyle(color: kGold)))
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                  body: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Hero (mockup #19): real cover art (never
                        // mock game art); LIVE/READY + mode pills
                        // STACKED top-left; the real name + game
                        // sit on the RIGHT, vertically centred.
                        ClipRRect(
                          borderRadius: BorderRadius.circular(16),
                          child: Container(
                            height: 150,
                            width: double.infinity,
                            color: hCard,
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                _coverImage(tImage(t)),
                                Container(
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                      begin: Alignment.centerLeft,
                                      end: Alignment.centerRight,
                                      colors: [
                                        Colors.black.withValues(alpha: 0.68),
                                        Colors.black.withValues(alpha: 0.3),
                                        Colors.transparent
                                      ],
                                    ),
                                  ),
                                ),
                                Positioned(
                                  top: 12,
                                  left: 12,
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      // FIX ROUND I-all-fix1-A (#19):
                                      // mockup pill reads "● LIVE /
                                      // READY" — both words present,
                                      // the one that applies is bright.
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 10, vertical: 5),
                                        decoration: BoxDecoration(
                                            borderRadius:
                                                BorderRadius.circular(20),
                                            border: Border.all(
                                                color: Colors.green,
                                                width: 1.5)),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(Icons.circle,
                                                color: status == 'ongoing'
                                                    ? Colors.redAccent
                                                    : Colors.green,
                                                size: 8),
                                            const SizedBox(width: 5),
                                            Text('LIVE',
                                                style: TextStyle(
                                                    color: status == 'ongoing'
                                                        ? Colors.redAccent
                                                        : hText2,
                                                    fontWeight: FontWeight.bold,
                                                    fontSize: 11,
                                                    letterSpacing: 0.5)),
                                            const Text(' / ',
                                                style: TextStyle(
                                                    color: hText2,
                                                    fontWeight: FontWeight.bold,
                                                    fontSize: 11)),
                                            Text('READY',
                                                style: TextStyle(
                                                    color: (status ==
                                                                'upcoming' ||
                                                            status == 'ongoing')
                                                        ? Colors.green
                                                        : hText2,
                                                    fontWeight: FontWeight.bold,
                                                    fontSize: 11,
                                                    letterSpacing: 0.5)),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                      // Mockup #19: the mode pill is
                                      // dark with white text.
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 10, vertical: 5),
                                        decoration: BoxDecoration(
                                            color: hSecondary,
                                            borderRadius:
                                                BorderRadius.circular(20)),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            const Icon(Icons.group,
                                                color: Colors.white, size: 12),
                                            const SizedBox(width: 4),
                                            Text(strVal(t['mode'], 'Solo'),
                                                style: const TextStyle(
                                                    color: Colors.white,
                                                    fontWeight: FontWeight.bold,
                                                    fontSize: 11,
                                                    letterSpacing: 0.5)),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Positioned(
                                  right: 14,
                                  left: 150,
                                  top: 0,
                                  bottom: 0,
                                  child: Center(
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(tName(t).toUpperCase(),
                                            style: const TextStyle(
                                                color: Colors.white,
                                                fontWeight: FontWeight.w900,
                                                fontSize: 28),
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis),
                                        const SizedBox(height: 2),
                                        // P2 (mockup #19): the hero
                                        // subtitle is the cup/series
                                        // name (the tournament name),
                                        // not '<game> • <mode>'. NOTE:
                                        // the data model carries only
                                        // one name field, so when the
                                        // tournament name IS the
                                        // showdown name the subtitle
                                        // repeats the title — a
                                        // separate series/cup field
                                        // would be needed to show a
                                        // different subtitle (Lane B).
                                        Text(
                                            tName(t),
                                            style: const TextStyle(
                                                color: Colors.white70,
                                                fontSize: 13),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        // Countdown card: MATCH STARTS IN + big gold
                        // HH:MM:SS + clock icon. 2026-11-20: the
                        // mockup's gold border + glow are gone per
                        // the global card rule — _DarkMockupCard
                        // (two orbiting yellow shines, no border).
                        SizedBox(
                          width: double.infinity,
                          child: _DarkMockupCard(
                            padding: const EdgeInsets.symmetric(
                                vertical: 14, horizontal: 16),
                            radius: 16,
                            child: Column(
                              children: [
                                const Text('MATCH STARTS IN',
                                    style: TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 14,
                                        letterSpacing: 1)),
                                const SizedBox(height: 4),
                                _MatchRoomCountdown(
                                    startMs: intVal(t['startTime']),
                                    status: status),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        _MatchRoomDetailsCard(tournament: t),
                        const SizedBox(height: 12),
                        // FIX ROUND I-all-fix1-A (#19): my own
                        // profiles.level for the "(Lv.N)" on my row.
                        StreamBuilder<Map<String, dynamic>>(
                          stream: SupaDb.streamProfile(uid),
                          builder: (context, psnap) {
                            final level =
                                intVal((psnap.data ?? {})['level'], 1);
                            return _MatchRoomSquadCard(
                                registrations: squadRegs,
                                teamName: myTeam,
                                myUid: uid,
                                isTeam: isTeam,
                                myLevel: level);
                          },
                        ),
                        // FIX ROUND I-all-fix1-A (#19): the mockup
                        // always shows the organizer note — an empty
                        // description shows an honest line instead of
                        // hiding the whole card.
                        const SizedBox(height: 12),
                        // 2026-11-20: _DarkMockupCard (global card
                        // rule — no full border).
                        _DarkMockupCard(
                          padding: const EdgeInsets.all(14),
                          radius: 16,
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                padding: const EdgeInsets.all(6),
                                decoration: const BoxDecoration(
                                    color: hGold, shape: BoxShape.circle),
                                child: const Icon(Icons.priority_high,
                                    color: Colors.black, size: 16),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: RichText(
                                  text: TextSpan(
                                    style:
                                        TextStyle(color: kText, fontSize: 14),
                                    children: [
                                      const TextSpan(
                                          text: 'From Organizer: ',
                                          style: TextStyle(
                                              color: hGold,
                                              fontWeight: FontWeight.bold)),
                                      TextSpan(
                                          text: strVal(t['description'])
                                                  .isNotEmpty
                                              ? '“${strVal(t['description'])}”'
                                              : 'No announcement yet.'),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                        // v2016 FIX 11(a): the match-chat button was
                        // removed — voice/chat rooms now live in the
                        // team chat (TeamChatPage Voice button).
                        Center(
                          child: RichText(
                            textAlign: TextAlign.center,
                            text: TextSpan(
                              style: TextStyle(color: kMuted, fontSize: 12),
                              children: [
                                const TextSpan(
                                    text: 'RULES & FAIR PLAY: ',
                                    style:
                                        TextStyle(fontWeight: FontWeight.bold)),
                                const TextSpan(
                                    text:
                                        'No Cheating, Teaming, or Emulators. Anti-Cheat is ACTIVE. '),
                                TextSpan(
                                  text: 'View Rules',
                                  style: TextStyle(
                                      color: kText,
                                      decoration: TextDecoration.underline),
                                  recognizer: TapGestureRecognizer()
                                    ..onTap = () => Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                            builder: (_) =>
                                                const RulesPoliciesPage())),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            );
          },
        );
      },
    );
  }
}

/// Wave 4b #19 — ticking HH:MM:SS countdown for the Match Room
/// gold card (mockup "00:08:42" + clock icon). Ticks every second;
/// LIVE while ongoing, "Starting soon" once the start passes, honest
/// muted text when no start time exists.
class _MatchRoomCountdown extends StatefulWidget {
  final int startMs;
  final String status;
  const _MatchRoomCountdown({required this.startMs, required this.status});
  @override
  State<_MatchRoomCountdown> createState() => _MatchRoomCountdownState();
}

class _MatchRoomCountdownState extends State<_MatchRoomCountdown> {
  late final Timer _timer;
  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.status == 'ongoing') {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
            color: Colors.redAccent, borderRadius: BorderRadius.circular(12)),
        child: const Text('● LIVE',
            style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 16)),
      );
    }
    if (widget.startMs <= 0)
      return Text('Start time not announced yet.',
          style: TextStyle(color: hText2, fontSize: 13));
    final diff = widget.startMs - DateTime.now().millisecondsSinceEpoch;
    if (diff <= 0)
      return const Text('Starting soon',
          style: TextStyle(
              color: hGold, fontWeight: FontWeight.bold, fontSize: 20));
    final hours = diff ~/ 3600000;
    final mins = (diff % 3600000) ~/ 60000;
    final secs = (diff % 60000) ~/ 1000;
    final hhmmss =
        '${hours.toString().padLeft(2, '0')}:${mins.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          hhmmss,
          style: const TextStyle(
              color: hGold,
              fontWeight: FontWeight.w900,
              fontSize: 40,
              height: 1.0,
              fontFeatures: [FontFeature.tabularFigures()]),
        ),
        const SizedBox(width: 8),
        const Icon(Icons.access_time, color: hGold, size: 28),
      ],
    );
  }
}

/// Wave 4b #19 — ROOM DETAILS card in the mockup's layout: header +
/// RELEASED/LOCKED pill, ROOM ID | PASSWORD columns with a copy icon
/// each, COPY ALL at the right. Same gating rule as everywhere else
/// (`roomVisibleFor`) and the same clipboard behaviour as the old
/// shared room card — layout only, no behaviour change. The locked
/// branch keeps the existing locked note.
class _MatchRoomDetailsCard extends StatelessWidget {
  final Map<String, dynamic> tournament;
  const _MatchRoomDetailsCard({required this.tournament});

  Future<void> _copy(BuildContext context, String text, String label) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (context.mounted) toast(context, '$label copied.');
  }

  Widget _credCol(
      BuildContext context, String label, String value, VoidCallback onCopy) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: TextStyle(
                  color: kMuted,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5)),
          const SizedBox(height: 4),
          Row(
            children: [
              Flexible(
                  child: Text(value,
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w900,
                          fontSize: 20),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis)),
              IconButton(
                icon: Icon(Icons.copy, color: kGold, size: 18),
                tooltip: 'Copy $label',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                onPressed: onCopy,
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final released = roomVisibleFor(tournament);
    // A-5 (026): OFF -> "Band hai" + reason, credentials hidden.
    // Read failure = ON (getRoomControl returns {} then).
    // B-11 (2026-11-21): credentials come ONLY from
    // getRoomCredentials (026 RPC) — never off the tournament row.
    // A failed credentials call fails closed (honest load error).
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: Future.wait([
        SupaDb.getRoomControl(strVal(tournament['id'])),
        SupaDb.getRoomCredentials(strVal(tournament['id'])),
      ]),
      builder: (context, snap) {
        final control =
            (snap.data?.length ?? 0) > 0 ? snap.data![0] : <String, dynamic>{};
        final creds =
            (snap.data?.length ?? 0) > 1 ? snap.data![1] : <String, dynamic>{};
        final credsOk = creds['ok'] == true;
        final roomId = SupaDb.strOf(creds['roomId']);
        final roomPass = SupaDb.strOf(creds['roomPassword']);
        final voiceOff = SupaDb.isRoomVoiceDisabled(control);
        final reason = SupaDb.strOf(control['disabled_reason']);
        final visible = released && !voiceOff;
        // 2026-11-20: _DarkMockupCard (global card rule — no full
        // border); the SizedBox keeps the card full-width.
        return SizedBox(
          width: double.infinity,
          child: _DarkMockupCard(
            padding: const EdgeInsets.all(14),
            radius: 16,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Text('ROOM DETAILS',
                        style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w900,
                            fontSize: 16)),
                    const Spacer(),
                    _goldPill(
                      voiceOff ? 'BAND HAI' : (visible ? 'RELEASED' : 'LOCKED'),
                      bg: voiceOff
                          ? Colors.red.withValues(alpha: 0.15)
                          : (visible
                              ? Colors.green.withValues(alpha: 0.15)
                              : Colors.orange.withValues(alpha: 0.15)),
                      fg: voiceOff
                          ? Colors.red
                          : (visible ? Colors.green : Colors.orange),
                      border: voiceOff
                          ? Colors.red
                          : (visible ? Colors.green : Colors.orange),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (voiceOff)
                  Row(
                    children: [
                      const Icon(Icons.mic_off, color: Colors.red, size: 24),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          reason.isNotEmpty
                              ? 'Room band hai — $reason'
                              : 'Room band hai — voice join abhi band hai.',
                          style: TextStyle(color: kText, fontSize: 13),
                        ),
                      ),
                    ],
                  )
                else if (!visible)
                  Row(
                    children: [
                      Icon(Icons.lock, color: kGold, size: 24),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Room details are locked — the organizer releases the Room ID & password shortly before the match starts.',
                          style: TextStyle(color: kText, fontSize: 13),
                        ),
                      ),
                    ],
                  )
                else if (!credsOk)
                  Row(
                    children: [
                      Icon(Icons.error_outline, color: kGold, size: 24),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Room details abhi load nahi ho sake — dobara try karein.',
                          style: TextStyle(color: kText, fontSize: 13),
                        ),
                      ),
                    ],
                  )
                else
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      _credCol(
                          context,
                          'ROOM ID',
                          roomId.isEmpty ? '—' : roomId,
                          () => _copy(context, roomId, 'Room ID')),
                      Container(
                          width: 1,
                          height: 52,
                          color: hBorder,
                          margin: const EdgeInsets.symmetric(horizontal: 10)),
                      _credCol(
                          context,
                          'PASSWORD',
                          roomPass.isEmpty ? '—' : roomPass,
                          () => _copy(context, roomPass, 'Password')),
                      const SizedBox(width: 6),
                      OutlinedButton(
                        onPressed: () => _copy(
                            context,
                            'Room ID: $roomId\nPassword: $roomPass',
                            'Room details'),
                        style: OutlinedButton.styleFrom(
                            side: const BorderSide(color: hGold),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 8),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(20))),
                        child: const Text('COPY ALL',
                            style: TextStyle(
                                color: hGold,
                                fontWeight: FontWeight.bold,
                                fontSize: 12)),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Wave 4b #19 — YOUR SQUAD card in the mockup's layout: one card,
/// "YOUR SQUAD: TEAM NAME" header (gold team name), one row per
/// registered mate — avatar, real name + (Lv.N) (YOU) on my row
/// (my own real profiles.level; mates have no level in the model),
/// green "Ready ✓" pill.
class _MatchRoomSquadCard extends StatelessWidget {
  final List<Map<String, dynamic>> registrations;
  final String teamName;
  final String myUid;
  final bool isTeam;
  final int myLevel;
  const _MatchRoomSquadCard(
      {required this.registrations,
      required this.teamName,
      required this.myUid,
      required this.isTeam,
      this.myLevel = 1});

  @override
  Widget build(BuildContext context) {
    // 2026-11-20: _DarkMockupCard (global card rule — no full
    // border); the SizedBox keeps the card full-width.
    return SizedBox(
      width: double.infinity,
      child: _DarkMockupCard(
        padding: const EdgeInsets.all(14),
        radius: 16,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (isTeam && teamName.isNotEmpty)
              RichText(
                text: TextSpan(
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w900,
                      fontSize: 16),
                  children: [
                    const TextSpan(text: 'YOUR SQUAD: '),
                    TextSpan(
                        text: teamName.toUpperCase(),
                        style: const TextStyle(color: hGold)),
                  ],
                ),
              )
            else
              const Text('YOU',
                  style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w900,
                      fontSize: 16)),
            const SizedBox(height: 12),
            if (registrations.isEmpty)
              Text('No players joined yet.', style: TextStyle(color: kMuted))
            else
              for (var i = 0; i < registrations.length; i++) ...[
                if (i > 0) const Divider(color: hBorder, height: 16),
                Row(
                  children: [
                    CachedFramedAvatar(
                        uid: strVal(registrations[i]['firebase_uid']),
                        name: strVal(registrations[i]['username'], 'Player'),
                        radius: 18),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        strVal(registrations[i]['username'], 'Player') +
                            (strVal(registrations[i]['firebase_uid']) == myUid
                                ? ' (Lv.$myLevel) (YOU)'
                                : ''),
                        style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 15),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                          color: Colors.green.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: Colors.green)),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('Ready',
                              style: TextStyle(
                                  color: Colors.green,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12)),
                          SizedBox(width: 4),
                          Icon(Icons.check_circle,
                              color: Colors.green, size: 14),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
          ],
        ),
      ),
    );
  }
}

/// Phase 2 — My Matches page (#28): the user's own matches only,
/// in Upcoming / Live / Completed tabs. LIVE card with badge,
/// UPCOMING+CONFIRMED card with countdown, COMPLETED card with
/// real placement/kills from the registration row. Tab page (no
/// own Scaffold) — pushed routes wrap it in one.
class MyMatchesPage extends StatefulWidget {
  const MyMatchesPage({super.key});
  @override
  State<MyMatchesPage> createState() => _MyMatchesPageState();
}

class _MyMatchesPageState extends State<MyMatchesPage>
    with AutomaticKeepAliveClientMixin {
  // WAVE 4 FIX 5: keep-alive so the tab State survives switches.
  @override
  bool get wantKeepAlive => true;

  int _tab = 0;
  // WAVE 4 FIX 5: load-once cache for the per-registration
  // tournament map. The old build ran Future.wait(getTournament(id))
  // on EVERY build (every tab tap inside the page, every parent
  // rebuild) — now the map is fetched once per registration set and
  // re-rendered from cache instantly; it refreshes only when the
  // registration set changes or SupaDb.refreshNotifier bumps (Join /
  // pop-back). The registrations stream itself is created once, not
  // per build.
  late final Stream<List<Map<String, dynamic>>> _myRegsStream;
  final Map<String, Map<String, dynamic>> _tournaments = {};
  String _loadedKey = '';
  String _pendingKey = '';
  Set<String> _pendingIds = {};
  bool _tournamentsLoading = false;

  @override
  void initState() {
    super.initState();
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    _myRegsStream = SupaDb.streamMyRegistrations(uid);
    SupaDb.refreshNotifier.addListener(_onRefresh);
  }

  @override
  void dispose() {
    SupaDb.refreshNotifier.removeListener(_onRefresh);
    super.dispose();
  }

  /// A Join / pop-back bumped the notifier: drop the cache key so the
  /// next build re-fetches the tournament map in the background.
  void _onRefresh() {
    if (!mounted) return;
    setState(() {
      _loadedKey = '';
      _pendingKey = '';
    });
  }

  /// Schedules a background fetch of the tournament map when the
  /// registration set changed. Never called during build directly —
  /// the fetch is posted to the next frame so no setState runs inside
  /// build, and a key already loaded or already pending is skipped.
  void _ensureTournaments(Set<String> ids) {
    final sorted = ids.toList()..sort();
    final key = sorted.join(',');
    if (key == _loadedKey || key == _pendingKey) return;
    _pendingKey = key;
    _pendingIds = Set<String>.from(ids);
    WidgetsBinding.instance.addPostFrameCallback((_) => _fetchTournaments(key));
  }

  Future<void> _fetchTournaments(String key) async {
    // One fetch at a time: if a fetch is already in flight, the
    // in-flight fetch re-triggers the pending key when it finishes
    // (below), so nothing is ever dropped silently.
    if (_tournamentsLoading) return;
    final ids = _pendingIds;
    if (_pendingKey != key || ids.isEmpty) return;
    _tournamentsLoading = true;
    try {
      final results =
          await Future.wait(ids.map((id) => SupaDb.getTournament(id)));
      if (!mounted) return;
      if (_pendingKey != key) {
        // Registrations changed mid-flight: drop this stale result
        // and fetch the new set instead.
        _tournamentsLoading = false;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _pendingKey.isNotEmpty && _pendingKey != _loadedKey)
            _fetchTournaments(_pendingKey);
        });
        return;
      }
      setState(() {
        for (final t in results) {
          if (t.isNotEmpty) _tournaments[strVal(t['id'])] = t;
        }
        _tournaments.removeWhere((id, _) => !ids.contains(id));
        _loadedKey = key;
        _tournamentsLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      // A failed refresh keeps the last-good map (never blanks the
      // list); clearing the pending key lets the next build retry.
      setState(() {
        _pendingKey = '';
        _tournamentsLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    // Wave B #28: mockup header (MY MATCHES + ARENA HUB wordmark)
    // and the single pill tab bar. The Live tab's red dot is REAL —
    // it shows only when one of my tournaments is ongoing.
    // NOTE (shell): the global AppBar is hidden for this tab
    // (main.dart, WAVE 4 FIX 5) because the in-tab mockup title
    // below would duplicate it.
    // REDESIGN S4: shared ArenaBackground (kBackgroundGradient) replaces
    // the flat hBg fill — styling only, the stream + tab logic below
    // are untouched.
    // PHASE E (E9): the title + ARENA HUB logo sat ~12px from y=0
    // (under the status bar on Sameer's v2023 phone) — SafeArea
    // (top) + the Home 28dp floor pattern, so the title always
    // clears the bar. The background stays edge-to-edge (this
    // screen's background is the reference — untouched).
    final topPad = MediaQuery.paddingOf(context).top;
    final topShortfall = topPad < 28 ? 28 - topPad : 0.0;
    return ArenaBackground(
      child: SafeArea(
        top: true,
        bottom: false,
        child: Padding(
          padding: EdgeInsets.only(top: topShortfall),
          child: StreamBuilder<List<Map<String, dynamic>>>(
        stream: _myRegsStream,
        builder: (context, snap) {
          final myRegs = snap.data ?? [];
          final myIds = myRegs.map((r) => strVal(r['tournament_id'])).toSet();
          final myRegByTid = <String, Map<String, dynamic>>{
            for (final r in myRegs) strVal(r['tournament_id']): r
          };
          if (myIds.isEmpty) {
            return Column(
              children: [
                _headerRow(),
                _tabsBar(liveExists: false),
                const Expanded(
                    child: Center(
                        child: EmptyState(
                            icon: Icons.sports_esports,
                            title: 'No matches yet',
                            body:
                                'Join a tournament and it will show up here.'))),
              ],
            );
          }
          // WAVE 4 FIX 5: cached tournament map (see _ensureTournaments)
          // — renders instantly from cache; first load shows a
          // skeleton, never a full-screen spinner and never a flash of
          // the wrong "No upcoming matches" empty state.
          _ensureTournaments(myIds);
          final all = myIds
              .map((id) => _tournaments[id])
              .whereType<Map<String, dynamic>>()
              .toList();
          final liveExists = all.any((t) => tStatus(t) == 'ongoing');
          // 'full' (slots locked) stays in the Upcoming tab —
          // locking slots used to hide a joined tournament from the
          // player entirely (audit fix 2026-11-21).
          final statuses = _tab == 0
              ? ['upcoming', 'full']
              : _tab == 1
                  ? ['ongoing']
                  : ['completed', 'result', 'cancelled'];
          final list = all.where((t) => statuses.contains(tStatus(t))).toList()
            ..sort((a, b) =>
                intVal(a['startTime']).compareTo(intVal(b['startTime'])));
          return Column(
            children: [
              _headerRow(),
              _tabsBar(liveExists: liveExists),
              Expanded(
                child: (_tournamentsLoading && all.isEmpty)
                    ? ListView(
                        padding: const EdgeInsets.all(kSpace16),
                        children: const [
                          LoadingSkeleton(height: 110),
                          SizedBox(height: kSpace12),
                          LoadingSkeleton(height: 110),
                          SizedBox(height: kSpace12),
                          LoadingSkeleton(height: 110),
                        ],
                      )
                    : list.isEmpty
                        ? Center(
                            child: EmptyState(
                              icon: Icons.sports_esports,
                              title: _tab == 0
                                  ? 'No upcoming matches'
                                  : _tab == 1
                                      ? 'No live matches'
                                      : 'No completed matches',
                              body: _tab == 2
                                  ? 'Finished matches will show your placement and kills here.'
                                  : 'Matches in this state will show up here.',
                            ),
                          )
                        : ListView(
                            padding: const EdgeInsets.all(kSpace16),
                            children: [
                              for (final t in list) ...[
                                _myMatchCard(
                                    context, t, myRegByTid[strVal(t['id'])]),
                                const SizedBox(height: kSpace12),
                              ],
                            ],
                          ),
              ),
            ],
          );
        },
          ),
        ),
      ),
    );
  }

  Widget _headerRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          kSpace16, kSpace12, kSpace16, kSpace4),
      child: Row(
        children: [
          Expanded(
            // J-detail-fix1 (#28): mockup title ~30, not 28.
            child: Text('MY MATCHES',
                style: TextStyle(
                    color: kText,
                    fontSize: 30,
                    fontWeight: FontWeight.w900,
                    fontStyle: FontStyle.italic)),
          ),
          _arenaWordmark(fontSize: 15, crownSize: 28),
        ],
      ),
    );
  }

  /// Mockup tab bar: one rounded container, three tabs. The red
  /// dot on Live is real (see build).
  /// PHASE E (E24, CORRECTED 2026-11-24): the strip is the card
  /// now (shared token, not the opaque kSurfaceElevated), and
  /// the selected tab is the kGoldGradient pill again (Sameer:
  /// "click pe yellow hona chahiye") — the REST tabs are
  /// transparent over the strip's card fill, never black.
  /// Tab logic (setState _tab) unchanged.
  Widget _tabsBar({required bool liveExists}) {
    const labels = ['Upcoming', 'Live', 'Completed'];
    return Padding(
      padding: const EdgeInsets.fromLTRB(kSpace16, 10, kSpace16, kSpace12),
      child: Container(
        padding: const EdgeInsets.all(kSpace4),
        decoration: cardDecoration(radius: 28),
        child: Row(
          children: [
            for (var i = 0; i < labels.length; i++)
              Expanded(
                child: GestureDetector(
                  onTap: () => setState(() => _tab = i),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(24),
                        gradient: _tab == i ? kGoldGradient : null),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(labels[i],
                            style: TextStyle(
                                color: _tab == i
                                    ? const Color(0xFF0A0A0F)
                                    : kTextMuted,
                                fontWeight: FontWeight.bold,
                                fontSize: 14)),
                        if (i == 1 && liveExists) ...[
                          const SizedBox(width: 5),
                          Container(
                              width: 8,
                              height: 8,
                              decoration: const BoxDecoration(
                                  shape: BoxShape.circle, color: kLiveRed)),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Wave B #28 — mockup match card: the REAL banner as the card
  /// backdrop (never mock game art), status pills, real team/date,
  /// live "Starts in" countdown, real placement/kills.
  /// GAPS (logged, not faked): there is no bracket / opponent /
  /// score model, so the LIVE card shows my team VS an honest
  /// "TBD" (no Team Bravo, no score bars) — and no round/match
  /// number, so "Round 3 - Match 1" is not shown either.
  Widget _myMatchCard(BuildContext context, Map<String, dynamic> t,
      Map<String, dynamic>? myReg) {
    final status = tStatus(t);
    final isLive = status == 'ongoing';
    final isCompleted =
        status == 'completed' || status == 'result' || status == 'cancelled';
    final myTeam = myReg == null ? '' : strVal(myReg['team_name']);
    final myName = myReg == null ? '' : strVal(myReg['username'], 'Player');
    final rank = myReg == null ? 0 : intVal(myReg['rank']);
    final kills = myReg == null ? 0 : intVal(myReg['kills']);
    void openDetails() => Navigator.push(context,
        MaterialPageRoute(builder: (_) => MatchDetailsPage(tournament: t)));
    return InkWell(
      onTap: openDetails,
      borderRadius: BorderRadius.circular(kRadiusCard),
      // 2026-11-20 USER CORRECTION (global card rule): the mockup's
      // full gold border + glow are gone — the photo card is a
      // _DarkMockupCard (two orbiting yellow shines, no static
      // border), padding zero so the cover stays edge-to-edge.
      child: _DarkMockupCard(
        padding: EdgeInsets.zero,
        radius: kRadiusCard,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(kRadiusCard - 1),
          child: Stack(
            children: [
              Positioned.fill(child: _coverImage(tImage(t))),
              // REDESIGN S4: dark overlay over the banner so the
              // title/meta stay readable — deepened at the right
              // end (0.45 -> 0.55) and middle (0.72 -> 0.78).
              Positioned.fill(
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                      colors: [
                        hBg.withValues(alpha: 0.94),
                        hBg.withValues(alpha: 0.78),
                        hBg.withValues(alpha: 0.55)
                      ],
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (isLive)
                          const ArenaLiveBadge()
                        else if (!isCompleted) ...[
                          _goldPill('UPCOMING'),
                          const SizedBox(width: kSpace8),
                          _goldPill('CONFIRMED',
                              bg: Colors.transparent,
                              fg: Colors.green,
                              border: Colors.green),
                        ] else
                          _goldPill('COMPLETED',
                              bg: Colors.transparent, fg: kGold, border: kGold),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Text(tName(t),
                        style: TextStyle(
                            color: kText,
                            fontSize: 20,
                            fontWeight: FontWeight.bold),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                    const SizedBox(height: kSpace8),
                    if (isLive) ...[
                      // FIX ROUND I-all-fix1-A (#28): mockup VS row —
                      // my team vs the opponent. No opponent model
                      // exists, so the right side is an honest "TBD"
                      // (same pattern as the pinned VS bar) — never a
                      // fake team name, score or bracket.
                      Row(
                        children: [
                          Expanded(child: _teamLine(myTeam, myName)),
                          const Text('VS',
                              style: TextStyle(
                                  color: kGoldDeep,
                                  fontWeight: FontWeight.w900,
                                  fontStyle: FontStyle.italic,
                                  fontSize: 20)),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                Flexible(
                                    child: Text('TBD',
                                        style: TextStyle(
                                            color: kTextMuted,
                                            fontWeight: FontWeight.bold,
                                            fontSize: 14),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis)),
                                const SizedBox(width: 6),
                                Icon(Icons.help_outline,
                                    color: kTextMuted, size: 18),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: kSpace8),
                      Row(
                        children: [
                          const Icon(Icons.circle, color: kLiveRed, size: 8),
                          const SizedBox(width: 6),
                          Text(
                              'Match in progress • ${_shortDate(intVal(t['startTime']))}',
                              style: TextStyle(color: kText, fontSize: 13)),
                        ],
                      ),
                    ] else if (!isCompleted) ...[
                      Row(
                        children: [
                          Expanded(child: _teamLine(myTeam, myName)),
                          Container(width: 1, height: 16, color: kBorder),
                          const SizedBox(width: 10),
                          Icon(Icons.calendar_today,
                              color: kTextMuted, size: 14),
                          const SizedBox(width: 5),
                          Text(_shortDate(intVal(t['startTime'])),
                              style: TextStyle(color: kText, fontSize: 13)),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Icon(Icons.access_time,
                              color: kTextMuted, size: 16),
                          const SizedBox(width: 6),
                          _StartsInText(startMs: intVal(t['startTime'])),
                        ],
                      ),
                    ] else ...[
                      // J-detail-fix1 (#28): mockup placement line
                      // is GREY, not white.
                      Text(
                          'Placement: ${rank > 0 ? '${_ordinal(rank)} Place' : '—'}  •  $kills Kills',
                          style: TextStyle(color: kTextMuted, fontSize: 14)),
                    ],
                    // SUBMIT RESULT entry point (2026-11-21): a
                    // finished match I registered for shows a gold
                    // SUBMIT RESULT button above VIEW RESULT. The
                    // start-time rule covers matches whose status was
                    // never flipped to completed (they sit in the
                    // Upcoming/Live tab, not Completed).
                    // REDESIGN S4: contract ArenaPrimaryButton — the
                    // canSubmitResultFor rule + UploadResultPage
                    // navigation are UNCHANGED.
                    if (canSubmitResultFor(
                        joined: true,
                        status: status,
                        startMs: intVal(t['startTime']))) ...[
                      SizedBox(
                        width: double.infinity,
                        child: ArenaPrimaryButton(
                          onPressed: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) => UploadResultPage(
                                      tournamentId: strVal(t['id'])))),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.upload,
                                  size: 18, color: Color(0xFF0A0A0F)),
                              SizedBox(width: kSpace8),
                              Text('SUBMIT RESULT'),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                    ],
                    const SizedBox(height: kSpace12),
                    Row(
                      children: [
                        const Spacer(),
                        if (isLive)
                          SizedBox(
                            width: 170,
                            child: Container(
                              // J-detail-fix1 (#28): the mockup's
                              // VIEW MATCH button has a slight glow.
                              decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(
                                      kRadiusInput),
                                  boxShadow: _goldGlow(blur: 14, alpha: 0.32)),
                              child: ArenaPrimaryButton(
                                onPressed: openDetails,
                                child: const Text('VIEW MATCH'),
                              ),
                            ),
                          )
                        else if (!isCompleted)
                          SizedBox(
                            width: 170,
                            child: ArenaOutlinedButton(
                              onPressed: openDetails,
                              child: const Text('MATCH DETAILS'),
                            ),
                          )
                        else if (status != 'cancelled')
                          SizedBox(
                            width: 170,
                            child: OutlinedButton(
                              onPressed: () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                      builder: (_) => TournamentResultsPage(
                                          tournamentId: strVal(t['id']),
                                          tournament: t))),
                              // J-detail-fix1 (#28): the mockup's
                              // VIEW RESULT button border + text read
                              // grey, not gold.
                              style: OutlinedButton.styleFrom(
                                  side: BorderSide(
                                      color: kTextMuted, width: 1.5),
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 12),
                                  shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(
                                          kRadiusInput))),
                              child: Text('VIEW RESULT',
                                  style: TextStyle(
                                      color: kTextMuted,
                                      fontWeight: FontWeight.w900,
                                      fontSize: 14)),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Team row: gold shield + real team name (or the player's own
  /// username for a Solo entry — never a fake team name).
  Widget _teamLine(String teamName, String playerName) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.all(5),
          decoration: BoxDecoration(
              color: kGold.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(kSpace8),
              border: Border.all(color: kGold.withValues(alpha: 0.5))),
          child: Icon(teamName.isEmpty ? Icons.person : Icons.shield,
              color: kGold, size: 16),
        ),
        const SizedBox(width: kSpace8),
        Flexible(
            child: Text(teamName.isEmpty ? playerName : teamName,
                style: TextStyle(
                    color: kText, fontSize: 14, fontWeight: FontWeight.bold),
                maxLines: 1,
                overflow: TextOverflow.ellipsis)),
      ],
    );
  }
}

/// Phase 2 — Registration Success page (#24): shown ONLY after
/// joinTournament confirms (never before). Registration ID is the
/// interim "AH-" + id-prefix format until the Phase 4 RPC owns it;
/// when no id comes back, no id is shown (never invented).
class RegistrationSuccessPage extends StatelessWidget {
  final Map<String, dynamic> tournament;
  final String registrationId;
  final bool isRepair;
  final String teamName;
  const RegistrationSuccessPage(
      {super.key,
      required this.tournament,
      required this.registrationId,
      required this.isRepair,
      this.teamName = ''});

  @override
  Widget build(BuildContext context) {
    final t = tournament;
    final displayId = registrationId.isEmpty
        ? ''
        : '#AH-${registrationId.length >= 8 ? registrationId.substring(0, 8).toUpperCase() : registrationId.toUpperCase()}';
    return Scaffold(
      // J-detail-fix1 (#24): confetti across the WHOLE screen
      // (mockup 25_registration_success.jpg), not confined to the
      // shield box — behind content, never blocking taps.
      body: Stack(
        children: [
          const Positioned.fill(
              child: IgnorePointer(child: _FullScreenConfetti())),
          SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Mockup header: X close left, ARENA HUB wordmark
                  // centred.
                  Row(
                    children: [
                      // FIX ROUND I-all-fix1-A (#24): mockup X sits in a
                      // dark circular background.
                      Container(
                        decoration: const BoxDecoration(
                            color: hCard, shape: BoxShape.circle),
                        child: IconButton(
                            icon: const Icon(Icons.close,
                                color: Colors.white, size: 26),
                            tooltip: 'Close',
                            onPressed: () => Navigator.pop(context)),
                      ),
                      const Spacer(),
                      _arenaWordmark(fontSize: 18, crownSize: 32),
                      const Spacer(),
                      const SizedBox(width: 48),
                    ],
                  ),
                  const SizedBox(height: 8),
                  // Mockup gold shield + check with flat gold rings and
                  // a confetti field (decoration only — no data).
                  // J-detail-fix1 (#24, mockup 25): the shield is an
                  // OUTLINE with a bold gold check (not a solid fill),
                  // on a STRONG radial gold glow — restored per the
                  // glow directive (the glow IS in the mockup).
                  // P-D2 (#24): the laurel wreath IS drawn now
                  // (_LaurelWreath painter — no laurel asset exists,
                  // so it is painted); the two flat gold rings stay
                  // behind it. Confetti now covers the whole screen
                  // (see _FullScreenConfetti above), so the 16 pieces
                  // that lived inside this box are gone.
                  Center(
                    child: SizedBox(
                      width: 200,
                      height: 190,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          Container(
                            width: 200,
                            height: 200,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: RadialGradient(
                                colors: [
                                  hGold.withValues(alpha: 0.32),
                                  hGold.withValues(alpha: 0.08),
                                  Colors.transparent
                                ],
                                stops: const [0.0, 0.55, 1.0],
                              ),
                            ),
                          ),
                          Container(
                              width: 180,
                              height: 180,
                              decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                      color: hGold.withValues(alpha: 0.4),
                                      width: 1.5))),
                          Container(
                              width: 158,
                              height: 158,
                              decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                      color: hGold.withValues(alpha: 0.22),
                                      width: 1))),
                          const _SuccessShield(size: 150),
                          // P-D2 (#24): gold laurel wreath wrapping the
                          // shield's lower sides (mockup 25).
                          const Positioned(
                              left: 0,
                              right: 0,
                              bottom: 0,
                              height: 120,
                              child: IgnorePointer(child: _LaurelWreath())),
                        ],
                      ),
                    ),
                  ),
                  RichText(
                    textAlign: TextAlign.center,
                    text: const TextSpan(
                      // J-detail-fix1 (#24): mockup ~44, not 40.
                      style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w900,
                          fontStyle: FontStyle.italic,
                          fontSize: 44,
                          height: 1.1),
                      children: [
                        TextSpan(text: "YOU'RE "),
                        TextSpan(text: 'IN!', style: TextStyle(color: hGold)),
                      ],
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                      isRepair
                          ? 'Your incomplete join is now complete — no fee was charged again.'
                          : 'Registration Successful',
                      style: const TextStyle(color: hText2, fontSize: 15),
                      textAlign: TextAlign.center),
                  const SizedBox(height: 20),
                  // Mockup summary card: real banner thumb, status
                  // pill, real name, real registration ID, real date |
                  // mode, real team name (team joins only), confirmed.
                  // 2026-11-20: _DarkMockupCard (global card rule — no
                  // full gold border).
                  _DarkMockupCard(
                    padding: const EdgeInsets.all(12),
                    radius: 16,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // J-detail-fix1 (#24): the mockup thumb carries
                        // a gold diagonal slash overlay.
                        Stack(
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(12),
                              child: SizedBox(
                                  width: 96,
                                  height: 110,
                                  child: _coverImage(tImage(t), iconSize: 36)),
                            ),
                            const Positioned.fill(
                                child: IgnorePointer(
                                    child: CustomPaint(
                                        painter: _ThumbSlashPainter()))),
                          ],
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _statusPill2(tStatus(t)),
                              const SizedBox(height: 8),
                              Text(tName(t),
                                  style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 19,
                                      fontWeight: FontWeight.bold),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis),
                              if (displayId.isNotEmpty) ...[
                                const SizedBox(height: 4),
                                Text('Registration ID: $displayId',
                                    style: const TextStyle(
                                        color: hGold,
                                        fontSize: 14,
                                        fontWeight: FontWeight.bold)),
                              ],
                              const SizedBox(height: 6),
                              Row(
                                children: [
                                  const Icon(Icons.calendar_today,
                                      color: Colors.white, size: 14),
                                  const SizedBox(width: 5),
                                  Flexible(
                                      child: Text(
                                          _shortDate(intVal(t['startTime'])),
                                          style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 13),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis)),
                                  const SizedBox(width: 8),
                                  Container(
                                      width: 1, height: 14, color: hBorder),
                                  const SizedBox(width: 8),
                                  const Icon(Icons.person,
                                      color: Colors.white, size: 14),
                                  const SizedBox(width: 5),
                                  Text(strVal(t['mode'], 'Solo'),
                                      style: const TextStyle(
                                          color: Colors.white, fontSize: 13)),
                                ],
                              ),
                              if (teamName.isNotEmpty) ...[
                                const SizedBox(height: 6),
                                Row(
                                  children: [
                                    const Icon(Icons.group,
                                        color: Colors.white, size: 14),
                                    const SizedBox(width: 5),
                                    Flexible(
                                        child: Text('Team Name: $teamName',
                                            style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 13),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis)),
                                  ],
                                ),
                              ],
                              const SizedBox(height: 8),
                              Row(
                                children: [
                                  Container(
                                      width: 9,
                                      height: 9,
                                      decoration: const BoxDecoration(
                                          shape: BoxShape.circle,
                                          color: Colors.green)),
                                  const SizedBox(width: 6),
                                  const Text('Registration Confirmed',
                                      style: TextStyle(
                                          color: Colors.green,
                                          fontSize: 13,
                                          fontWeight: FontWeight.bold)),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  // 2026-11-20: _DarkMockupCard (global card rule — no
                  // full border).
                  _DarkMockupCard(
                    padding: const EdgeInsets.all(14),
                    radius: 12,
                    child: Row(
                      children: [
                        Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                                color: hGold.withValues(alpha: 0.15),
                                shape: BoxShape.circle),
                            child: const Icon(Icons.notifications,
                                color: hGold, size: 20)),
                        const SizedBox(width: 12),
                        const Expanded(
                            child: Text(
                                "We'll notify you before your match begins.",
                                style: TextStyle(color: hText2, fontSize: 14))),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  // J-detail-fix1 (#24): the mockup's VIEW MY MATCHES
                  // button has a soft gold glow.
                  _glowGoldButton(
                    child: goldButton(
                      label: 'VIEW MY MATCHES',
                      onPressed: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => Scaffold(
                                  appBar: AppBar(
                                      title: boardAppBarTitle('My Matches')),
                                  body: const MyMatchesPage()))),
                    ),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      onPressed: () =>
                          Navigator.popUntil(context, (r) => r.isFirst),
                      style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: hGold, width: 1.5),
                          padding: const EdgeInsets.symmetric(vertical: 15),
                          // P2 (mockup #24): BACK TO HOME is a full
                          // gold pill — radius 28, not 14.
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(28))),
                      child: const Text('BACK TO HOME',
                          style: TextStyle(
                              color: hGold,
                              fontWeight: FontWeight.w900,
                              fontSize: 16)),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// SUBMIT RESULT entry-point rule (2026-11-21): a registered player
/// may submit once the match has ended. "Ended" = status
/// completed/result, OR the start time has passed — live
/// tournaments stay 'upcoming' until an admin moves them, so a
/// status-only rule would hide the button for every real finished
/// match. Cancelled tournaments never show it. This mirrors the
/// guard inside `_UploadResultPageState._submit` (registration +
/// start-time check), so a visible button never leads to a dead
/// end. Used by the tournament detail page, the match details
/// page and the My Matches cards.
bool canSubmitResultFor({
  required bool joined,
  required String status,
  required int startMs,
}) {
  if (!joined) return false;
  if (status == 'completed' || status == 'result') return true;
  if (status == 'cancelled') return false;
  if (startMs > 0 &&
      startMs <= DateTime.now().millisecondsSinceEpoch) return true;
  return false;
}

/// Shared chat UI: display_name, reply-to quote, admin blue bubble,
/// HH:MM timestamps, send gate (must have joined).
class UploadResultPage extends StatefulWidget {
  final String tournamentId;
  const UploadResultPage({super.key, required this.tournamentId});
  @override
  State<UploadResultPage> createState() => _UploadResultPageState();
}

/// FIX 10 follow-up (coordinator): the evidence-screenshot watermark
/// prefers the player's GAME UID (what Sameer wants shown everywhere)
/// and falls back to the Firebase UID ONLY when no game UID is saved —
/// the watermark's job is anti-fraud traceability, and the Firebase UID
/// is the account key the admin traces by, so a blank watermark would
/// defeat its purpose. The fallback label stays honest ('UID: ...').
String resultWatermarkLabel({String? gameUid, required String firebaseUid}) {
  final game = (gameUid ?? '').trim();
  if (game.isNotEmpty) return 'Game UID: $game';
  return 'UID: $firebaseUid';
}

/// Phase 3 (#8) — Submit Result REBUILD. Full form: Match ID display
/// (real tournament id), placement dropdown, kills / assists / damage /
/// duration / notes, screenshot ≤10MB (OD-15, enforced client-side)
/// with thumbnail preview, ImgBB upload (existing path).
///
/// Submit order: FIRST try `SupaDb.submitMatchResult(...)` — the
/// `record_match_result` RPC (022). The RPC derives the caller from
/// firebase_uid() server-side, and the app talks to Supabase with
/// the publishable anon key only (no Supabase Auth sign-in, no JWT
/// bridge yet) — so the RPC raises 'not authorized' for anon-key
/// callers and this returns ok:false today. That is expected, not a
/// bug; the fallback below is the live path until the JWT bridge
/// lands. On any RPC failure, fall back to `SupaDb.submitResult`
/// direct upsert, which saves the FULL stats (placement/kills/
/// assists/damage/duration/notes + screenshot, status 'submitted')
/// — the admin approval automation reads exactly these columns to
/// compute winnings and points. Nothing is shown as saved that was
/// not saved.
/// Points preview: LIVE — placement + kills under the effective
/// template (decided 10/7/5 + 1/kill), clearly an estimate until
/// admin approval. Kills, damage, assists and duration fields are
/// REQUIRED inputs: an earlier mockup-matching round removed them
/// from the form and every submission sent kills=0, so kill
/// points and per-kill prize were always 0. Never remove them
/// again.
/// ANTI-FRAUD (N-create-tournament): an APPROVED result is final
/// and cannot be re-submitted or edited — checked before the
/// screenshot upload. Submit is also guarded: the player must be
/// registered in the tournament, and the tournament must have
/// started (start time passed — status is NOT checked, live
/// tournaments stay 'upcoming' until an admin moves them).
/// Wave 4 (after the JWT bridge lands): re-test the RPC path and
/// remove the fallback-only note once it returns ok:true.
class _UploadResultPageState extends State<UploadResultPage> {
  File? _file;
  String? _fileName;
  int? _fileBytes;
  bool _busy = false;
  int? _placement;
  final _kills = TextEditingController();
  final _assists = TextEditingController();
  final _damage = TextEditingController();
  final _durationMin = TextEditingController();
  final _notes = TextEditingController();
  String? _error;
  bool _offline = false;
  String _tournamentName = '';
  bool _nameLoading = true;
  // Wave C (#8): the user's REAL team name from their registration
  // row (display-only — record_match_result has no team-name param,
  // same class of gap as the image param; see _submit).
  String _teamName = '';
  // Effective scoring template for the live points preview
  // (admin override when saved, else the decided 10/7/5).
  ScoringTemplate _template = kDefaultScoringTemplate;

  /// Live points preview: placement + kills under [_template].
  /// 0 until a placement is picked. An estimate — points count
  /// only after admin approval.
  int get _previewPoints => _placement == null
      ? 0
      : calculateMatchPoints(
          placement: _placement!, kills: _num(_kills), template: _template);

  /// OD-15: screenshot limit for result submission (mockup value).
  static const int _maxScreenshotBytes = 10 * 1024 * 1024;

  @override
  void initState() {
    super.initState();
    ScoringTemplateStore.loadEffectiveTemplate().then((t) {
      if (mounted) setState(() => _template = t);
    });
    SupaDb.getTournament(widget.tournamentId).then((t) {
      if (mounted) {
        setState(() {
          _tournamentName = tName(t);
          _nameLoading = false;
        });
      }
    }).catchError((_) {
      if (mounted) setState(() => _nameLoading = false);
    });
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid != null) {
      SupaDb.getRegistrations(widget.tournamentId).then((regs) {
        final mine =
            regs.where((r) => strVal(r['firebase_uid']) == uid).toList();
        if (mounted && mine.isNotEmpty) {
          setState(() => _teamName = strVal(mine.first['team_name']));
        }
      });
    }
  }

  @override
  void dispose() {
    _kills.dispose();
    _assists.dispose();
    _damage.dispose();
    _durationMin.dispose();
    _notes.dispose();
    super.dispose();
  }

  int _num(TextEditingController c) {
    final v = int.tryParse(c.text.trim()) ?? 0;
    return v < 0 ? 0 : v;
  }

  Future<void> _pickScreenshot() async {
    final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (picked == null) return;
    final size = await picked.length();
    if (size > _maxScreenshotBytes) {
      setState(() {
        _error =
            'Screenshot ${(size / (1024 * 1024)).toStringAsFixed(1)} MB hai — limit 10 MB hai. Chhoti screenshot choose karen.';
        _file = null;
        _fileName = null;
        _fileBytes = null;
      });
      return;
    }
    setState(() {
      _file = File(picked.path);
      _fileName = picked.name;
      _fileBytes = size;
      _error = null;
    });
  }

  Future<void> _submit() async {
    if (_file == null || _placement == null) {
      setState(() => _error =
          'Placement select karen aur screenshot attach karen — dono zaroori hain.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _offline = false;
    });
    try {
      final uid = FirebaseAuth.instance.currentUser!.uid;
      // ANTI-FRAUD (N-create-tournament): an APPROVED result is final —
      // it can never be edited or re-submitted. Checked BEFORE the
      // screenshot upload, so a blocked re-submit wastes no bandwidth.
      final existing = await SupaDb.getMyResult(widget.tournamentId, uid);
      if (SupaDb.strOf(existing['status']).toLowerCase() == 'approved') {
        if (mounted)
          setState(() => _error =
              'Result already approved — final hai, edit nahi ho sakta.');
        return;
      }
      // GUARD: only a registered player can submit. The Upload
      // button is hidden unless joined, but the screen itself
      // must enforce it (deep links / stale state).
      final regs = await SupaDb.getRegistrations(widget.tournamentId);
      if (!regs.any((r) => SupaDb.strOf(r['firebase_uid']) == uid)) {
        if (mounted)
          setState(() => _error =
              'Aap is tournament mein registered nahi hain — pehle join karen.');
        return;
      }
      // GUARD: a result can only be submitted AFTER the tournament
      // has started (start time passed). Tournament STATUS is
      // deliberately NOT checked: live tournaments stay
      // 'upcoming' until an admin moves them, so a status guard
      // would block every real submission. A missing/zero start
      // time (old test rows) skips the guard.
      final t = await SupaDb.getTournament(widget.tournamentId);
      final startMs = SupaDb.intOf(t['startTime']);
      if (startMs > 0 && startMs > DateTime.now().millisecondsSinceEpoch) {
        if (mounted)
          setState(() => _error =
              'Tournament abhi shuru nahi hua — khelne ke baad result bhejen.');
        return;
      }
      // FIX 10 follow-up: the watermark prefers the game UID; a failed
      // profile read falls back to the Firebase UID (never blocks).
      String? gameUid;
      try {
        final profile = await SupaDb.getProfile(uid);
        gameUid = SupaDb.strOf(profile['game_uid']);
      } catch (_) {
        gameUid = null;
      }
      final watermarked = await _watermarked(
        _file!,
        resultWatermarkLabel(gameUid: gameUid, firebaseUid: uid),
      );
      final url = await ImgbbService.uploadImage(watermarked);
      // FIRST: the result-system RPC via the data layer. The RPC
      // is NOT applied on production yet (022 is a draft in the
      // tree) AND the app has no JWT bridge (anon key only, so
      // the RPC would raise 'not authorized' even if applied) —
      // so today this returns ok:false. That is expected, not a
      // bug; the fallback below is the live path until the
      // backend applies 022 and the bridge lands. Real signature
      // (supabase_db.dart): submitMatchResult({tournamentId,
      // placement, kills, assists, damage, duration, notes,
      // imageUrl}) -> Map with 'ok'. The screenshot itself is
      // saved by the fallback below.
      bool rpcOk = false;
      String rpcMessage = '';
      try {
        final res = await SupaDb.submitMatchResult(
          tournamentId: widget.tournamentId,
          placement: _placement!,
          kills: _num(_kills),
          assists: _num(_assists),
          damage: _num(_damage),
          duration: _num(_durationMin) * 60,
          notes: _notes.text.trim(),
          imageUrl: url,
        );
        rpcOk = res['ok'] == true;
        rpcMessage = SupaDb.strOf(res['message'], SupaDb.strOf(res['error']));
      } catch (e) {
        rpcOk = false;
        rpcMessage = e.toString();
      }
      if (rpcOk) {
        if (mounted) {
          toast(context, 'Result submitted — admin review pending.');
          Navigator.pop(context);
        }
        return;
      }
      // FALLBACK: the RPC needs a JWT bridge that does not exist
      // yet, so the full stats are saved by direct upsert —
      // placement, kills, assists, damage, duration and notes,
      // not just the screenshot. The admin approval automation
      // reads exactly these columns.
      await SupaDb.submitResult(
        widget.tournamentId,
        uid,
        url,
        placement: _placement,
        kills: _num(_kills),
        assists: _num(_assists),
        damage: _num(_damage),
        durationSeconds: _num(_durationMin) * 60,
        notes: _notes.text.trim(),
      );
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          backgroundColor: kCardPurpleMid,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22), side: const BorderSide(color: kCardPurpleBorder, width: 1.5)),
          title: Text('Result submitted', style: TextStyle(color: kGold)),
          content: Text(
            'Placement + stats save ho gaye hain. Admin screenshot verify karega — approve hote hi prize automatic credit hogi.${rpcMessage.isNotEmpty ? '\n\nResult system: $rpcMessage' : ''}',
            style: TextStyle(color: kText),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text('OK', style: TextStyle(color: kGold)))
          ],
        ),
      );
      if (mounted) Navigator.pop(context);
    } on SocketException {
      if (mounted) setState(() => _offline = true);
    } catch (e) {
      if (mounted) setState(() => _error = 'Submit failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// FULL COMPLETION expansion 2: user-ID watermark — the uploaded
  /// screenshot carries the uploader's ID burned into its bottom
  /// strip, so a reused/stolen screenshot is traceable. The label
  /// prefers the game UID (see resultWatermarkLabel) and only falls
  /// back to the Firebase UID when no game UID is saved. If
  /// watermarking fails for any reason, the ORIGINAL file still
  /// uploads (never block proof submission on the watermark).
  Future<File> _watermarked(File src, String label) async {
    try {
      final bytes = await src.readAsBytes();
      final decoded = img.decodeImage(bytes);
      if (decoded == null) return src;
      final stripH = 44;
      img.fillRect(decoded,
          x1: 0,
          y1: decoded.height - stripH,
          x2: decoded.width,
          y2: decoded.height,
          color: img.ColorRgba8(0, 0, 0, 180));
      img.drawString(decoded, label,
          font: img.arial24,
          x: 12,
          y: decoded.height - stripH + 8,
          color: img.ColorRgb8(255, 215, 122));
      final out = File(
          '${src.parent.path}/wm_${DateTime.now().millisecondsSinceEpoch}.jpg');
      await out.writeAsBytes(img.encodeJpg(decoded, quality: 88));
      return out;
    } catch (_) {
      return src;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Wave C (#8): mockup header — SUBMIT RESULT + ARENA HUB logo.
      // J-detail-fix1: the mockup title is WHITE upright ~22, not
      // the gold helper title.
      appBar: AppBar(
        title: const FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text('SUBMIT RESULT',
                style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w900,
                    fontSize: 22))),
        actions: const [
          Padding(
              padding: EdgeInsets.only(right: 12),
              child: ArenaLogo(crownSize: 26, fontSize: 14))
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Match ID display — the REAL tournament id.
            // J-detail-fix1 (#8): the mockup subtitle is a PLAIN
            // text line (no card, no copy button): NAME • MATCH ID:
            // #WCC-8942 — the id shown is the real one (no invented
            // short code).
            if (_nameLoading)
              const LoadingSkeleton(height: 18, width: 180)
            else
              RichText(
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                text: TextSpan(
                  style: TextStyle(
                      color: kText, fontSize: 14, fontWeight: FontWeight.bold),
                  children: [
                    TextSpan(
                        text: (_tournamentName.isEmpty
                                ? 'Tournament'
                                : _tournamentName)
                            .toUpperCase()),
                    TextSpan(text: '  •  ', style: TextStyle(color: kMuted)),
                    TextSpan(
                        text: 'MATCH ID: ', style: TextStyle(color: kMuted)),
                    TextSpan(
                        text: '#${widget.tournamentId}',
                        style: TextStyle(color: kGold)),
                  ],
                ),
              ),
            const SizedBox(height: 12),
            // Wave C (#8): instruction box — the mockup's 3 bullets
            // (generic instructions, not mock values), gold edge.
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                  color: kCardFillColor,
                  borderRadius: BorderRadius.circular(12),
                  border: Border(left: BorderSide(color: kGold, width: 4))),
              // NOTE: not `const` — kText is a theme getter, not a
              // compile-time constant.
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                      '•  Upload a clear screenshot of the post-match scoreboard.',
                      style: TextStyle(color: kText, fontSize: 14)),
                  SizedBox(height: 6),
                  Text(
                      '•  Your team name, placement, and points must be visible.',
                      style: TextStyle(color: kText, fontSize: 14)),
                  SizedBox(height: 6),
                  Text(
                      '•  Fraudulent submissions will result in tournament disqualification.',
                      style: TextStyle(color: kText, fontSize: 14)),
                ],
              ),
            ),
            const SizedBox(height: 12),
            // Wave C (#8): YOUR TEAM NAME — the mockup's filled field,
            // shown from the REAL registration row. Display-only:
            // record_match_result has no team-name param, so this
            // field is never submitted (same gap as the image param).
            // 2026-11-20: shared MockupCard (global card rule — no
            // full border); content is theme-aware (k* tokens).
            SizedBox(
              width: double.infinity,
              child: MockupCard(
                padding: const EdgeInsets.all(14),
                radius: 12,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('YOUR TEAM NAME',
                        style: TextStyle(
                            color: kMuted,
                            fontSize: 12,
                            fontWeight: FontWeight.bold)),
                    const SizedBox(height: 4),
                    Text(
                        _teamName.isEmpty
                            ? 'No team on file — solo entry'
                            : _teamName,
                        style: TextStyle(
                            color: kText,
                            fontSize: 17,
                            fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            // Wave C (#8): FINAL PLACEMENT + TOTAL TEAM POINTS side
            // by side, as in the mockup. Placement uses ordinal
            // labels (3rd, not #3). Points are a LIVE preview
            // (placement + kills under the effective template) —
            // an estimate until admin approval; the mockup's "18"
            // is a sample value, never copied.
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: DropdownButtonFormField<int>(
                    initialValue: _placement,
                    decoration: InputDecoration(
                        labelText: 'FINAL PLACEMENT',
                        labelStyle: TextStyle(color: kMuted),
                        filled: true,
                        fillColor: kField,
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide.none)),
                    dropdownColor: kCard,
                    style: TextStyle(color: kText),
                    hint: Text('Select placement',
                        style: TextStyle(color: kMuted)),
                    items: [
                      for (var i = 1; i <= 100; i++)
                        DropdownMenuItem(value: i, child: Text(_ordinal(i)))
                    ],
                    onChanged: (v) => setState(() => _placement = v),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
                    decoration: BoxDecoration(
                        color: kField, borderRadius: BorderRadius.circular(12)),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('TOTAL TEAM POINTS',
                            style: TextStyle(color: kMuted, fontSize: 12)),
                        const SizedBox(height: 6),
                        Text('$_previewPoints',
                            style: TextStyle(
                                color: kText,
                                fontSize: 20,
                                fontWeight: FontWeight.bold)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            // Live estimate — points count only after admin
            // approval (decided template: 1st=10, 2nd=7, 3rd=5,
            // +1 per kill, or the admin override when saved).
            Text(
                'Estimate — approve hone ke baad points milenge (1st=${_template.placementPoints[1] ?? 0}, 2nd=${_template.placementPoints[2] ?? 0}, 3rd=${_template.placementPoints[3] ?? 0}, +1/kill).',
                style: TextStyle(color: kMuted, fontSize: 12)),
            const SizedBox(height: 16),
            // KILLS + DAMAGE — REQUIRED inputs, never remove: an
            // earlier mockup-matching round dropped these fields
            // and every submission sent kills=0, so kill points
            // and per-kill prize were always 0. Typing here
            // refreshes the points preview + breakdown live.
            Row(
              children: [
                Expanded(
                  // FIX 23 item 29: card look via CardFieldShell.
                  child: CardFieldShell(
                    child: TextField(
                    controller: _kills,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    style: TextStyle(color: kText),
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                        labelText: 'KILLS',
                        labelStyle: TextStyle(color: kMuted),
                        hintText: '0',
                        hintStyle: TextStyle(color: kMuted),
                        border: const OutlineInputBorder(borderSide: BorderSide.none),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 12)),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  // FIX 23 item 29: card look via CardFieldShell.
                  child: CardFieldShell(
                    child: TextField(
                    controller: _damage,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    style: TextStyle(color: kText),
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                        labelText: 'DAMAGE',
                        labelStyle: TextStyle(color: kMuted),
                        hintText: '0',
                        hintStyle: TextStyle(color: kMuted),
                        border: const OutlineInputBorder(borderSide: BorderSide.none),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 12)),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            // ASSISTS + DURATION — same story as kills/damage:
            // the same mockup round dropped these two fields, so
            // every submission sent assists=0 and duration=0.
            // They don't change points, but the admin sees them
            // on the review card and the match record is
            // incomplete without them.
            Row(
              children: [
                Expanded(
                  // FIX 23 item 29: card look via CardFieldShell.
                  child: CardFieldShell(
                    child: TextField(
                    controller: _assists,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    style: TextStyle(color: kText),
                    decoration: InputDecoration(
                        labelText: 'ASSISTS',
                        labelStyle: TextStyle(color: kMuted),
                        hintText: '0',
                        hintStyle: TextStyle(color: kMuted),
                        border: const OutlineInputBorder(borderSide: BorderSide.none),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 12)),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  // FIX 23 item 29: card look via CardFieldShell.
                  child: CardFieldShell(
                    child: TextField(
                    controller: _durationMin,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    style: TextStyle(color: kText),
                    decoration: InputDecoration(
                        labelText: 'DURATION (MIN)',
                        labelStyle: TextStyle(color: kMuted),
                        hintText: '0',
                        hintStyle: TextStyle(color: kMuted),
                        border: const OutlineInputBorder(borderSide: BorderSide.none),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 12)),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            // Points breakdown (blueprint §6 transparency): how
            // the preview total is calculated, live.
            PointsBreakdown(
              placement: _placement ?? 0,
              kills: _num(_kills),
              template: _template,
            ),
            const SizedBox(height: 16),
            // FIX 23 item 29: card look via CardFieldShell.
            CardFieldShell(
              child: TextField(
              controller: _notes,
              style: TextStyle(color: kText),
              maxLines: 3,
              maxLength: 500,
              decoration: InputDecoration(
                labelText: 'MATCH NOTES (OPTIONAL)',
                labelStyle: TextStyle(color: kMuted),
                hintText: 'Enter any additional details or issues here...',
                hintStyle: TextStyle(color: kMuted),
                // J-detail-fix1 (#8): the mockup shows no character
                // counter — the 500 cap stays enforced, the counter
                // text is hidden.
                counterText: '',
                counterStyle: TextStyle(color: kMuted, fontSize: 11),
                border: const OutlineInputBorder(borderSide: BorderSide.none),
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 12),
              ),
              ),
            ),
            const SizedBox(height: 12),
            // Wave C (#8): mockup upload area — dashed box, TAP TO
            // UPLOAD SCREENSHOT / JPG or PNG up to 10MB. Picked file
            // shows its REAL thumbnail + REAL filename (the mockup's
            // "match_result.jpg" is a sample name, never copied).
            Text('UPLOAD SCREENSHOT',
                style: TextStyle(
                    color: kMuted, fontSize: 12, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            // P2 (mockup #8): the dashed upload box + the thumbnail
            // sit SIDE BY SIDE in one row ALWAYS — not only after a
            // file is picked. With nothing picked yet the thumbnail
            // slot is an honest empty placeholder ("No screenshot
            // yet"), never a fake image.
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    flex: 3,
                    child: ArenaDashedBorder(
                      onTap: _busy ? null : _pickScreenshot,
                      padding: const EdgeInsets.symmetric(
                          vertical: 16, horizontal: 12),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.file_upload_outlined,
                              color: kGold, size: 32),
                          SizedBox(height: 8),
                          Text('TAP TO UPLOAD SCREENSHOT',
                              style: TextStyle(
                                  color: kGold,
                                  fontWeight: FontWeight.w900,
                                  fontSize: 13),
                              textAlign: TextAlign.center),
                          SizedBox(height: 4),
                          Text('JPG or PNG up to 10MB',
                              style: TextStyle(color: kMuted, fontSize: 12),
                              textAlign: TextAlign.center),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: _file != null
                        ? GestureDetector(
                            onTap: _busy ? null : _pickScreenshot,
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(12),
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  Image.file(_file!, fit: BoxFit.cover),
                                  Positioned(
                                    left: 0,
                                    right: 0,
                                    bottom: 0,
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 8, vertical: 6),
                                      color: Colors.black
                                          .withValues(alpha: 0.65),
                                      child: Row(
                                        children: [
                                          Expanded(
                                              child: Text(
                                                  _fileName ??
                                                      'screenshot.jpg',
                                                  style: const TextStyle(
                                                      color: Colors.white,
                                                      fontWeight:
                                                          FontWeight.bold,
                                                      fontSize: 12),
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis)),
                                          const Icon(Icons.edit,
                                              color: Colors.white, size: 14),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          )
                        : Container(
                            decoration: BoxDecoration(
                                color: hCard,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: hBorder)),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.image_outlined,
                                    color: kMuted, size: 28),
                                const SizedBox(height: 6),
                                Text('No screenshot yet',
                                    style: TextStyle(
                                        color: kMuted, fontSize: 12),
                                    textAlign: TextAlign.center),
                              ],
                            ),
                          ),
                  ),
                ],
              ),
            ),
            if (_file != null) ...[
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(
                      child: Text(
                          '${_fileBytes != null ? '${(_fileBytes! / (1024 * 1024)).toStringAsFixed(2)} MB' : ''} (limit 10 MB)',
                          style: TextStyle(color: kMuted, fontSize: 12))),
                  TextButton(
                    onPressed: () => setState(() {
                      _file = null;
                      _fileName = null;
                      _fileBytes = null;
                    }),
                    child: Text('Remove',
                        style: TextStyle(color: Colors.redAccent)),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 8),
            Text(
                'Note: upload hone wali screenshot par aapka User ID watermark lag jayega (fair-play proof ke liye).',
                style: TextStyle(color: kMuted, fontSize: 12)),
            const SizedBox(height: 16),
            // Wave C (#8): admin-review note. GAP: the mockup promises
            // "within 30 mins" — no such SLA exists in the system, so
            // the note promises review without inventing a time.
            Center(
                child: Text('Submission will be reviewed by admin.',
                    style: TextStyle(color: kMuted, fontSize: 13),
                    textAlign: TextAlign.center)),
            const SizedBox(height: 12),
            // J-detail-fix1 (#8): the mockup's SUBMIT FOR REVIEW is
            // a full PILL (radius ~28) with a soft gold glow under
            // it — the shared GoldButton stays radius 12, so the
            // pill is built locally.
            _goldPillButton(
              label: 'SUBMIT FOR REVIEW',
              busy: _busy,
              glow: true,
              onPressed: (_file == null || _placement == null || _busy)
                  ? null
                  : _submit,
            ),
            const SizedBox(height: 12),
            if (_offline)
              Center(
                  child: OfflineState(
                      message:
                          'No internet — result submit nahi hua. Connection wapas aate hi dobara try karen.',
                      onRetry: _submit))
            else if (_error != null)
              ErrorState(
                  message: _error!,
                  onRetry:
                      (_file != null && _placement != null) ? _submit : null),
          ],
        ),
      ),
    );
  }
}

/// Phase 3 (#22) — Tournament Results (NEW). Podium 1st/2nd/3rd by
/// rank from `SupaDb.getResultsForTournament(tournamentId)` (Worker S;
/// live `tournament_registrations`: rank, kills, prize);
/// tabs All Results / My Results; search by team/player name from
/// real rows; View Match Summary -> `MatchSummaryPage`
/// (pro_features.dart). A2 (OD-02): points shown as 0 with the label
/// "points not credited yet — points system pending decision (OD-02)".
/// NEVER displays `tournament_payouts` (cash table — out of safe
/// scope); the prize shown here is the registration row's own prize
/// field, the same value MatchSummaryPage already displays.
/// NOTE for Worker S / parent: assumed signature —
/// getResultsForTournament(String tournamentId) ->
/// `Future<List<Map<String, dynamic>>>` of registration rows.
class TournamentResultsPage extends StatefulWidget {
  final String tournamentId;
  final Map<String, dynamic>? tournament;
  const TournamentResultsPage(
      {super.key, required this.tournamentId, this.tournament});
  @override
  State<TournamentResultsPage> createState() => _TournamentResultsPageState();
}

class _TournamentResultsPageState extends State<TournamentResultsPage> {
  final _searchCtrl = TextEditingController();
  // Wave 4b #22: the header search icon focuses THIS field — the
  // real in-body search, never a decorative dead icon.
  final _searchFocus = FocusNode();
  String _search = '';
  int _tab = 0; // 0 = All Results, 1 = My Results
  Future<List<Map<String, dynamic>>>? _future;
  Map<String, dynamic>? _tournament;

  @override
  void initState() {
    super.initState();
    _tournament = widget.tournament;
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _load() {
    setState(() {
      _future = _fetch();
    });
    // Wave C (#22): the header card needs the tournament row even
    // when there are no result rows — load it for the header directly.
    if (_tournament == null) {
      SupaDb.getTournament(widget.tournamentId).then((t) {
        if (mounted && t.isNotEmpty) setState(() => _tournament = t);
      });
    }
  }

  Future<List<Map<String, dynamic>>> _fetch() async {
    _tournament ??= await SupaDb.getTournament(widget.tournamentId);
    final rows = await SupaDb.getResultsForTournament(widget.tournamentId);
    // Ranked rows first (rank 1..n), unranked after, ties by kills.
    rows.sort((a, b) {
      final ra = intVal(a['rank']);
      final rb = intVal(b['rank']);
      if ((ra > 0) != (rb > 0)) return ra > 0 ? -1 : 1;
      if (ra != rb) return ra.compareTo(rb);
      return intVal(b['kills']).compareTo(intVal(a['kills']));
    });
    return rows;
  }

  Map<String, dynamic> get _tournamentOrId {
    final t = _tournament;
    if (t != null && t.isNotEmpty) return t;
    return {'id': widget.tournamentId, 'name': 'Tournament'};
  }

  String _rowName(Map<String, dynamic> r) =>
      strVal(r['username'], strVal(r['team_name'], 'Player'));

  /// Wave C (#22): mockup tournament header card — two-tone name,
  /// GAME • MODE left, status • real date + green check (when
  /// completed) right. All values real; the mockup's "Nov 22" is the
  /// tournament's real start date (short form of fmtDate).
  Widget _tournamentHeader() {
    final t = _tournamentOrId;
    if (_tournament == null) {
      return const Padding(
        padding: EdgeInsets.fromLTRB(12, 12, 12, 4),
        child: LoadingSkeleton(height: 84, radius: 16),
      );
    }
    final status = tStatus(t);
    final completed = status == 'completed';
    final statusLabel = completed
        ? 'Completed'
        : status.isEmpty
            ? 'Upcoming'
            : status[0].toUpperCase() + status.substring(1);
    final dateShort = fmtDate(t['startTime']).split(',').first;
    // 2026-11-20: _DarkMockupCard (global card rule — no full gold
    // border + glow). The header title is two-tone white/gold, so
    // the dark twin (not the shared light-fallback card) is used.
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: _DarkMockupCard(
        padding: const EdgeInsets.all(14),
        radius: 16,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // J-detail-fix1 (#22): mockup header name ~28, not 24.
            _twoToneTitle(tName(t), fontSize: 28),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                    child: Text(
                        '${tGame(t)}  •  ${strVal(t['mode'], 'Solo')}'
                            .toUpperCase(),
                        style: TextStyle(
                            color: kMuted,
                            fontSize: 13,
                            fontWeight: FontWeight.bold),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis)),
                Text('$statusLabel • $dateShort',
                    style: TextStyle(color: kMuted, fontSize: 13)),
                if (completed) ...[
                  const SizedBox(width: 4),
                  const Icon(Icons.check_circle, color: Colors.green, size: 16)
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser!.uid;
    return Scaffold(
      // Wave 4b #22: the mockup's header search icon focuses the
      // real in-body search field below (ArenaSearchBar focusNode) —
      // tapping it opens the keyboard with the cursor in the search
      // that actually filters the rows. No dead icon.
      appBar: AppBar(
        // FIX ROUND I-all-fix1-A (#22): mockup title is white
        // italic w900, not the gold non-italic helper title.
        title: const FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text('TOURNAMENT RESULTS',
                style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w900,
                    fontStyle: FontStyle.italic,
                    fontSize: 20))),
        actions: [
          IconButton(
            // J-detail-fix1 (#22): the mockup search icon is
            // light grey/white, not gold.
            icon: const Icon(Icons.search, color: Colors.white),
            tooltip: 'Search results',
            onPressed: () => _searchFocus.requestFocus(),
          ),
        ],
      ),
      // J-detail-fix1 (#22): gold dust background (mockup 23) —
      // the shared ArenaEmberDots, behind content, taps pass
      // through.
      body: Stack(
        children: [
          const Positioned.fill(child: IgnorePointer(child: ArenaEmberDots())),
          Positioned.fill(
            child: Column(
              children: [
                _tournamentHeader(),
                // FIX ROUND I-all-fix1-A (#22): mockup order is header →
                // tabs → podium → Leaderboard card (search INSIDE it) →
                // rows → button. The search + points disclaimer no longer
                // sit above the podium.
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                  child: FilterTabs(
                      labels: const ['All Results', 'My Results'],
                      selectedIndex: _tab,
                      onSelected: (i) => setState(() => _tab = i)),
                ),
                Expanded(
                  child: FutureBuilder<List<Map<String, dynamic>>>(
                    future: _future,
                    builder: (context, snap) {
                      if (snap.connectionState == ConnectionState.waiting) {
                        return ListView(
                          padding: const EdgeInsets.all(16),
                          children: const [
                            LoadingSkeleton(height: 110, radius: 14),
                            SizedBox(height: 12),
                            LoadingSkeleton(height: 64, radius: 12),
                            SizedBox(height: 8),
                            LoadingSkeleton(height: 64, radius: 12),
                            SizedBox(height: 8),
                            LoadingSkeleton(height: 64, radius: 12),
                          ],
                        );
                      }
                      if (snap.hasError) {
                        final err = snap.error;
                        if (err is SocketException) {
                          return Center(child: OfflineState(onRetry: _load));
                        }
                        return Center(
                            child: ErrorState(
                                message: 'Results load nahi ho sake: $err',
                                onRetry: _load));
                      }
                      var rows = snap.data ?? [];
                      if (_tab == 1) {
                        rows = rows
                            .where((r) => strVal(r['firebase_uid']) == uid)
                            .toList();
                      }
                      if (_search.isNotEmpty) {
                        rows = rows
                            .where((r) =>
                                _rowName(r).toLowerCase().contains(_search))
                            .toList();
                      }
                      if (rows.isEmpty) {
                        return Center(
                          child: EmptyState(
                            icon: Icons.emoji_events,
                            title: _tab == 1
                                ? 'No results for you yet'
                                : 'No results yet',
                            body: _search.isNotEmpty
                                ? 'No team or player matches "$_search".'
                                : _tab == 1
                                    ? 'Your result for this tournament is not published yet.'
                                    : 'Results appear here once the admin publishes them.',
                          ),
                        );
                      }
                      final ranked =
                          rows.where((r) => intVal(r['rank']) > 0).toList();
                      final podium = <Map<String, dynamic>?>[
                        ranked.where((r) => intVal(r['rank']) == 2).firstOrNull,
                        ranked.where((r) => intVal(r['rank']) == 1).firstOrNull,
                        ranked.where((r) => intVal(r['rank']) == 3).firstOrNull,
                      ];
                      return ListView(
                        padding: const EdgeInsets.all(16),
                        children: [
                          if (_tab == 0 && podium.any((p) => p != null)) ...[
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Expanded(child: _podiumSlot(podium[0], 2)),
                                Expanded(child: _podiumSlot(podium[1], 1)),
                                Expanded(child: _podiumSlot(podium[2], 3)),
                              ],
                            ),
                            const SizedBox(height: 16),
                          ],
                          // FIX ROUND I-all-fix1-A (#22): mockup order —
                          // podium, then ONE enclosing Leaderboard card
                          // with the heading, the search INSIDE it, the
                          // column header and the rows. The MATCHES column
                          // has no data (registration rows carry no
                          // matches-played count), so the real kills count
                          // takes that column's place — never invented.
                          // 2026-11-20: _DarkMockupCard (global card rule).
                          _DarkMockupCard(
                            padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
                            radius: 16,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('Leaderboard',
                                    style: TextStyle(
                                        color: kSectionLabel,
                                        fontSize: 18,
                                        fontWeight: FontWeight.bold)),
                                const SizedBox(height: 10),
                                ArenaSearchBar(
                                    controller: _searchCtrl,
                                    focusNode: _searchFocus,
                                    hint: 'Search team or player...',
                                    onChanged: (v) => setState(() =>
                                        _search = v.trim().toLowerCase())),
                                const SizedBox(height: 12),
                                Row(
                                  children: [
                                    SizedBox(
                                        width: 40,
                                        child: Text('RANK',
                                            style: TextStyle(
                                                color: kMuted,
                                                fontSize: 11,
                                                fontWeight: FontWeight.bold))),
                                    const SizedBox(width: 12),
                                    const SizedBox(width: 36),
                                    const SizedBox(width: 10),
                                    Expanded(
                                        child: Text('TEAM / PLAYER',
                                            style: TextStyle(
                                                color: kMuted,
                                                fontSize: 11,
                                                fontWeight: FontWeight.bold))),
                                    SizedBox(
                                        width: 48,
                                        child: Text('KILLS',
                                            style: TextStyle(
                                                color: kMuted,
                                                fontSize: 11,
                                                fontWeight: FontWeight.bold),
                                            textAlign: TextAlign.right)),
                                    const SizedBox(width: 8),
                                    SizedBox(
                                        width: 56,
                                        child: Text('PTS',
                                            style: TextStyle(
                                                color: kMuted,
                                                fontSize: 11,
                                                fontWeight: FontWeight.bold),
                                            textAlign: TextAlign.right)),
                                  ],
                                ),
                                const Divider(color: hBorder, height: 16),
                                for (var i = 0; i < rows.length; i++) ...[
                                  _resultRow(context, rows[i]),
                                  if (i < rows.length - 1)
                                    const SizedBox(height: 8),
                                ],
                              ],
                            ),
                          ),
                          const SizedBox(height: 16),
                          // J-detail-fix1 (#22): the mockup's VIEW MATCH
                          // SUMMARY button has a soft gold glow under it.
                          _glowGoldButton(
                            child: GoldButton(
                              label: 'VIEW MATCH SUMMARY',
                              icon: Icons.north_east,
                              onPressed: () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                      builder: (_) => MatchSummaryPage(
                                          tournament: _tournamentOrId))),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Wave C (#22) — mockup podium: rank medallion on top, then a
  /// flat medal-coloured PEDESTAL (1st tallest, gold; 2nd silver;
  /// 3rd bronze) with the avatar straddling its top edge and the
  /// team name + points + kills in dark text on the pedestal.
  /// J-detail-fix1: the 1st-place medallion carries a gold glow +
  /// sparkle rays (mockup 23) and a real gold crown vector above
  /// the avatar (the app logo asset is not a crown). P-D2: the
  /// pedestals are 3D cylinders now (vertical gradient + top
  /// ellipse highlight) — the mockup IS 3D here.
  Widget _podiumSlot(Map<String, dynamic>? r, int place) {
    final medalColor = place == 1
        ? kGold
        : place == 2
            ? const Color(0xFFC0C0C0)
            : const Color(0xFFCD7F32);
    final isFirst = place == 1;
    final name = r == null ? '—' : _rowName(r);
    final initial =
        r == null || name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase();
    final pedestalH = isFirst ? 168.0 : (place == 2 ? 138.0 : 118.0);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Wave C (#22): mockup rank medallion (1st/2nd/3rd).
          // J-detail-fix1: the 1st-place medallion glows gold with
          // sparkle rays around it (mockup 23).
          SizedBox(
            width: 64,
            height: 64,
            child: Stack(
              alignment: Alignment.center,
              children: [
                if (isFirst) ...[
                  const Positioned(
                      top: 0,
                      left: 4,
                      child: Icon(Icons.star, color: hGold, size: 10)),
                  const Positioned(
                      top: 8,
                      right: 0,
                      child: Icon(Icons.star, color: hGold, size: 8)),
                  const Positioned(
                      bottom: 4,
                      left: 0,
                      child: Icon(Icons.star, color: hGold, size: 8)),
                  const Positioned(
                      bottom: 0,
                      right: 6,
                      child: Icon(Icons.star, color: hGold, size: 10)),
                ],
                Container(
                  width: 52,
                  height: 52,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: hCard,
                    border: Border.all(color: medalColor, width: 2),
                    boxShadow: isFirst
                        ? [
                            BoxShadow(
                                color: hGold.withValues(alpha: 0.55),
                                blurRadius: 14,
                                spreadRadius: 2)
                          ]
                        : null,
                  ),
                  child: Text(_ordinal(place),
                      style: TextStyle(
                          color: medalColor,
                          fontWeight: FontWeight.w900,
                          fontSize: 16)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.topCenter,
            children: [
              // P-D2 (#22): the mockup's pedestals are 3D cylinders
              // (23_tournament_results.jpg) — vertical gradient
              // (light top -> medal -> darker base) + a lighter
              // ellipse highlight at the top edge. Flat fills were
              // the last visual gap on this screen.
              Container(
                height: pedestalH,
                width: double.infinity,
                margin: EdgeInsets.only(top: isFirst ? 46.0 : 22.0),
                padding: const EdgeInsets.fromLTRB(6, 28, 6, 10),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color.lerp(medalColor, Colors.white, 0.38)!,
                      medalColor,
                      Color.lerp(medalColor, Colors.black, 0.28)!,
                    ],
                    stops: const [0.0, 0.45, 1.0],
                  ),
                  borderRadius:
                      const BorderRadius.vertical(top: Radius.circular(16)),
                ),
                child: Column(
                  children: [
                    Text(
                      name,
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 13),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                    ),
                    if (r != null) ...[
                      const SizedBox(height: 2),
                      // Mockup shows real points (142 PTS); P1-10:
                      // getResultsForTournament merges stored
                      // team_points onto the row, so this is real.
                      // White, not gold: the 1st pedestal IS gold, so
                      // gold text would be invisible on it.
                      Text('${intVal(r['team_points'])} PTS',
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.bold)),
                      Text('${intVal(r['kills'])} kills',
                          style: const TextStyle(
                              color: Colors.white70, fontSize: 11)),
                    ],
                  ],
                ),
              ),
              // P-D2 (#22): cylinder-top highlight — a flattened
              // lighter ellipse across the pedestal's top edge.
              Positioned(
                top: (isFirst ? 46.0 : 22.0) + 4,
                left: 12,
                right: 12,
                child: Container(
                    height: 12,
                    decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.30),
                        borderRadius: BorderRadius.circular(6))),
              ),
              // Avatar: initial letter, straddling the pedestal top
              // edge. GAP: registration rows carry no photo_url, so
              // no real photo can be shown — and the mockup's PUBG
              // soldier art must never be copied.
              // J-detail-fix1 (#22): the mockup's small gold crown
              // above the 1st-place avatar is a real crown vector
              // now (was the app logo asset).
              if (isFirst)
                const Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: Center(child: _MiniCrown(size: 26)),
                ),
              Positioned(
                top: isFirst ? 24.0 : 0.0,
                left: 0,
                right: 0,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: medalColor, width: 2),
                        color: hCard),
                    child: CircleAvatar(
                        radius: 20,
                        backgroundColor: hCard,
                        child: Text(initial,
                            style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 18))),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// J-detail-fix1 (#22): mockup rows are SEPARATE rounded cards
  /// (dark fill, grey border, radius ~12) — not divider-separated
  /// rows inside the one card. Rank is a plain number like the
  /// mockup ("4", not "#4" in a circle). The KILLS column carries
  /// the real kills count (the mockup's MATCHES column has no data
  /// source — never invented); PTS stays honest 0 (OD-02) with the
  /// real prize below it when set.
  Widget _resultRow(BuildContext context, Map<String, dynamic> r) {
    final rank = intVal(r['rank']);
    final prize = numVal(r['prize']);
    final name = _rowName(r);
    final initial = name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
          color: hSecondary,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: hBorder)),
      child: Row(
        children: [
          SizedBox(
              width: 40,
              child: Text(rank > 0 ? '$rank' : '—',
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 15))),
          const SizedBox(width: 12),
          // Wave C (#22): mockup avatar circle — initial letter (no
          // photo_url in the rows; never mock art).
          CircleAvatar(
              radius: 18,
              backgroundColor: kField,
              child: Text(initial,
                  style: TextStyle(
                      color: kText,
                      fontWeight: FontWeight.bold,
                      fontSize: 15))),
          const SizedBox(width: 10),
          Expanded(
              child: Text(name,
                  style: TextStyle(color: kText, fontWeight: FontWeight.bold),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis)),
          SizedBox(
              width: 48,
              child: Text('${intVal(r['kills'])}',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.bold),
                  textAlign: TextAlign.right)),
          const SizedBox(width: 8),
          SizedBox(
            width: 56,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                // P1-10: real stored team_points, merged onto the
                // row by getResultsForTournament (was a hard-coded
                // '0 PTS' while points were OFF).
                Text('${intVal(r['team_points'])} PTS',
                    style: TextStyle(
                        color: kGold,
                        fontSize: 12,
                        fontWeight: FontWeight.bold)),
                if (prize > 0)
                  Text('Prize: ${fmtRs(prize)}',
                      style: TextStyle(color: kGold, fontSize: 11)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
