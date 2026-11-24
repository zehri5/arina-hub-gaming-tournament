import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide User;
import '../platform/core/scoring.dart';
import '../platform/scoring/scoring_template_store.dart';
import 'squad.dart';

/// Supabase data layer — REPLACES services/rtdb.dart entirely.
///
/// Firebase Auth is used ONLY for login (FirebaseAuth UID). Every data
/// row carries that UID as `firebase_uid` (text). No service_role key is
/// used anywhere; the client uses only the publishable anon key.
///
/// TABLE / COLUMN CONTRACT (shared with the admin port):
///   profiles, match_history, games, promotions, tournaments,
///   tournament_registrations, transactions, withdrawals, deposits,
///   pending_referrals, notifications, user_notifications, chat_messages,
///   tournament_results, support_tickets, ads, app_settings (single row),
///   presence, voice_signaling_peers, voice_signaling_inbox.
/// Tournaments: `name` (NOT tournamentName/title/gameName), status
/// upcoming/ongoing/completed/result/cancelled, mode Solo/Duo/Squad.
/// Registrations: `slot_number` primary (+ legacy `slot` read),
/// `teammates` jsonb + flat player2/3/4 columns.
/// Chat: `display_name` + `sender`, stored per schema as scope +
/// tournament_id (+ squad_id for squad scope); there is NO `scope_id`
/// column. Transactions use HTML type strings exactly
/// (`tournament_join`, NOT `join_fee`). Deposits use `payment_method`.
/// Support tickets use `image_url` + `reply` (NOT `admin_reply`).
///
/// ATOMICITY LIMITATION (honest): Supabase PostgREST has no multi-table
/// transaction from the client. Join/withdraw therefore do
/// validate-first + ordered writes + compensation (refund / delete) if a
/// later write fails. True atomicity needs a Postgres RPC
/// (e.g. `join_tournament`) — recommended follow-up for the builder, NOT
/// silently claimed here. See [joinTournament] and [requestWithdrawal].
class SupaDb {
  static SupabaseClient get client => Supabase.instance.client;

  /// Live-refresh signal for screens whose Supabase Realtime subscription
  /// cannot be trusted on its own (see 003_realtime.sql: tables created
  /// via SQL Editor are NOT in the supabase_realtime publication until
  /// that migration runs, so postgres_changes events never fire and a
  /// plain StreamBuilder never rebuilds after a pop-back). Screens wrap
  /// their streams in a ValueListenableBuilder on this notifier and use
  /// its value as the StreamBuilder key, so any bump forces a fresh
  /// fetch. Bump it after every join / after any pushed page pops.
  static final ValueNotifier<int> refreshNotifier = ValueNotifier<int>(0);
  static void bumpRefresh() {
    refreshNotifier.value++;
  }

  // FIX 23 item 22 (user order 2026-11-23): the admin-set app-wide
  // background image URL. Stored inside the app_settings.theme jsonb
  // map under [appBackgroundUrlKey] — no new column/table (the
  // admin APK writes it via its own theme helper). Read once at
  // boot (main.dart, same fetch as force-update); empty means "no
  // remote background — use the bundled default artwork" (FIX 23
  // item 21). A new URL arrives on next app start, not in an
  // already-open app.
  static const String appBackgroundUrlKey = 'app_background_url';
  static final ValueNotifier<String> appBackgroundUrl =
      ValueNotifier<String>('');

  /// Pure helper: the background URL out of a fetched settings map.
  /// Returns '' when the theme map has no background URL set.
  static String appBackgroundUrlFromSettings(Map<String, dynamic> settings) {
    final theme = asMap(settings['theme']);
    return strOf(theme[appBackgroundUrlKey]);
  }

  // ---------- timestamp helpers ----------
  static int parseTs(dynamic v) {
    if (v == null) return 0;
    if (v is num) {
      final d = v.toDouble();
      if (d == 0) return 0;
      // Seconds (~1.7e9) vs milliseconds (~1.7e12).
      return d.abs() < 100000000000 ? (d * 1000).round() : d.round();
    }
    final s = v.toString().trim();
    if (s.isEmpty) return 0;
    final asNum = double.tryParse(s);
    if (asNum != null) return parseTs(asNum);
    try {
      return DateTime.parse(s).millisecondsSinceEpoch;
    } catch (_) {
      return 0;
    }
  }

  static String isoNow() => DateTime.now().toUtc().toIso8601String();

  static double numOf(dynamic v, [double fallback = 0]) {
    if (v == null) return fallback;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString()) ?? fallback;
  }

  static int intOf(dynamic v, [int fallback = 0]) => numOf(v, fallback.toDouble()).round();

  static String strOf(dynamic v, [String fallback = '']) {
    if (v == null) return fallback;
    final s = v.toString();
    return s.isEmpty ? fallback : s;
  }

  static Map<String, dynamic> asMap(dynamic v) {
    if (v is Map) return Map<String, dynamic>.from(v);
    return {};
  }

  static List<dynamic> asList(dynamic v) {
    if (v is List) return v;
    return [];
  }

  // ---------- test seam (FIX 6, 2026-11-21) ----------
  /// Test-only fixture rows, keyed by table name. When non-null,
  /// [getList]/[getRow]/[streamList] serve these rows (with the
  /// same eq/order/limit filtering as the live query) instead of
  /// touching the network, so widget tests can pump REAL screens
  /// (HomePage) with fixture data. Production code NEVER sets this:
  /// null (the default) means live Supabase, and the seam adds no
  /// behaviour change whatsoever when null. Tests must reset it to
  /// null in tearDown.
  @visibleForTesting
  static Map<String, List<Map<String, dynamic>>>? testFixtures;

  /// Public read of the fixture seam for production code that must
  /// behave differently under tests (e.g. CommunityService's
  /// membership read, whose direct client has no connection under
  /// flutter test). The @visibleForTesting field itself cannot be
  /// read from lib code (analyzer warning); this getter is the
  /// sanctioned path. False in production (fixtures are null).
  static bool get hasTestFixtures => testFixtures != null;

  /// Live in-memory row list for one fixture table (tests only),
  /// created when absent — the WRITE side of the fixture seam.
  /// Service-layer fixture seams (e.g. CommunityGroups voice
  /// approval, FIX 14) mutate the returned list exactly like the
  /// live path mutates Supabase, so tests exercise real state
  /// transitions without a connection. Null when no fixtures are
  /// installed (production). Same sanctioned-path rule as
  /// [hasTestFixtures]: lib code uses this, never the field.
  static List<Map<String, dynamic>>? fixtureTable(String table) {
    final fixtures = testFixtures;
    if (fixtures == null) return null;
    return fixtures.putIfAbsent(table, () => <Map<String, dynamic>>[]);
  }

  static List<Map<String, dynamic>> _fixtureRows(
    String table, {
    String? eqCol,
    dynamic eqVal,
    String? eqCol2,
    dynamic eqVal2,
    String? orderBy,
    bool ascending = true,
    int? limit,
    // Communities pagination/search seam (2026-11-22): offset skips
    // rows after sort (same as PostgREST range), ilike* is a
    // case-insensitive substring match (PostgREST ilike '%v%'),
    // lt* is a strict less-than (PostgREST lt, for chat cursors).
    int offset = 0,
    String? ilikeCol,
    String? ilikeVal,
    String? ltCol,
    dynamic ltVal,
  }) {
    var rows = (testFixtures?[table] ?? []).map((r) => Map<String, dynamic>.from(r)).toList();
    bool matches(Map<String, dynamic> r, String? col, dynamic val) {
      if (col == null) return true;
      // PostgREST eq semantics for the values tests use: exact
      // equality (num/bool/string compared by value).
      return r[col] == val;
    }

    bool ilikeMatches(Map<String, dynamic> r) {
      if (ilikeCol == null || ilikeVal == null) return true;
      final hay = (r[ilikeCol] ?? '').toString().toLowerCase();
      return hay.contains(ilikeVal.toLowerCase());
    }

    bool ltMatches(Map<String, dynamic> r) {
      if (ltCol == null || ltVal == null) return true;
      final v = r[ltCol];
      if (v is num && ltVal is num) return v < ltVal;
      return v.toString().compareTo(ltVal.toString()) < 0;
    }

    rows = rows.where((r) => matches(r, eqCol, eqVal) && matches(r, eqCol2, eqVal2) && ilikeMatches(r) && ltMatches(r)).toList();
    if (orderBy != null) {
      int cmp(Map<String, dynamic> a, Map<String, dynamic> b) {
        final av = a[orderBy];
        final bv = b[orderBy];
        if (av is num && bv is num) return av.compareTo(bv);
        return av.toString().compareTo(bv.toString());
      }

      rows.sort((a, b) => ascending ? cmp(a, b) : cmp(b, a));
    }
    if (offset > 0) rows = offset >= rows.length ? <Map<String, dynamic>>[] : rows.sublist(offset);
    if (limit != null && rows.length > limit) rows = rows.sublist(0, limit);
    return rows;
  }

  // ---------- generic reads ----------
  static Future<Map<String, dynamic>> getRow(String table, String col, dynamic val) async {
    final fixtures = testFixtures;
    if (fixtures != null) {
      final rows = _fixtureRows(table, eqCol: col, eqVal: val, limit: 1);
      return rows.isEmpty ? <String, dynamic>{} : rows.first;
    }
    try {
      final row = await client.from(table).select().eq(col, val).limit(1).maybeSingle();
      if (row == null) return {};
      return Map<String, dynamic>.from(row as Map);
    } catch (_) {
      return {};
    }
  }

  static Future<List<Map<String, dynamic>>> getList(
    String table, {
    String? eqCol,
    dynamic eqVal,
    String? eqCol2,
    dynamic eqVal2,
    String? orderBy,
    bool ascending = true,
    int? limit,
    // Pagination/search (2026-11-22, communities scale): offset is
    // a row offset (PostgREST range); ilikeCol/ilikeVal is a
    // case-insensitive substring search; ltCol/ltVal is a strict
    // less-than (chat cursors). All optional — existing callers
    // behave exactly as before.
    int offset = 0,
    String? ilikeCol,
    String? ilikeVal,
    String? ltCol,
    dynamic ltVal,
  }) async {
    if (testFixtures != null) {
      return _fixtureRows(table, eqCol: eqCol, eqVal: eqVal, eqCol2: eqCol2, eqVal2: eqVal2, orderBy: orderBy, ascending: ascending, limit: limit, offset: offset, ilikeCol: ilikeCol, ilikeVal: ilikeVal, ltCol: ltCol, ltVal: ltVal);
    }
    try {
      dynamic q = client.from(table).select();
      if (eqCol != null) q = q.eq(eqCol, eqVal);
      if (eqCol2 != null) q = q.eq(eqCol2, eqVal2);
      if (ilikeCol != null && ilikeVal != null && ilikeVal.isNotEmpty) {
        final esc = ilikeVal.replaceAll('\\', '\\\\').replaceAll('%', '\\%').replaceAll('_', '\\_');
        q = q.ilike(ilikeCol, '%$esc%');
      }
      if (ltCol != null && ltVal != null) q = q.lt(ltCol, ltVal);
      if (orderBy != null) q = q.order(orderBy, ascending: ascending);
      if (offset > 0) {
        final n = limit ?? 50;
        q = q.range(offset, offset + n - 1);
      } else if (limit != null) {
        q = q.limit(limit);
      }
      final rows = await q;
      return (rows as List).map((r) => Map<String, dynamic>.from(r as Map)).toList();
    } catch (_) {
      return [];
    }
  }

  /// Exact row count for a filtered table — WITHOUT loading the
  /// rows (PostgREST `count=exact` + `limit(1)`, so at most one row
  /// crosses the wire). 0 on any error / missing table — never
  /// throws. Communities member counts + comment counts use this;
  /// counting must never mean fetching thousands of rows.
  static Future<int> countRows(
    String table, {
    String? eqCol,
    dynamic eqVal,
    String? eqCol2,
    dynamic eqVal2,
  }) async {
    if (testFixtures != null) {
      return _fixtureRows(table, eqCol: eqCol, eqVal: eqVal, eqCol2: eqCol2, eqVal2: eqVal2).length;
    }
    try {
      dynamic q = client.from(table).select('id');
      if (eqCol != null) q = q.eq(eqCol, eqVal);
      if (eqCol2 != null) q = q.eq(eqCol2, eqVal2);
      final res = await q.limit(1).count(CountOption.exact);
      return res.count ?? 0;
    } catch (_) {
      return 0;
    }
  }

  // ---------- watch live: likes + YouTube key (2026-11-22) ----------
  //
  // LIKES table (BACKEND LANE — does NOT exist yet on production):
  //   create table watch_live_likes (
  //     id uuid primary key default gen_random_uuid(),
  //     tournament_id text not null,
  //     firebase_uid text not null,
  //     created_at timestamptz not null default now(),
  //     unique (tournament_id, firebase_uid)
  //   );
  //   + RLS: anon can select all rows, insert/delete ONLY their own
  //   firebase_uid rows. Until the table lands, every method below
  //   THROWS (count/hasLiked) or returns false (toggle) and the UI
  //   shows "—" + an honest "likes abhi available nahi hain" toast —
  //   NEVER a fake 0 or a fake count. The moment the table exists,
  //   likes work with no app change.
  //
  // YOUTUBE KEY: the YouTube Data API v3 key lives in app_settings
  // (key `youtube_api_key`, pasted by the admin in Admin > Settings;
  // free key from Google Cloud Console with YouTube Data API v3
  // enabled). Empty = the YouTube viewer count is hidden, never
  // faked. The key is NEVER hardcoded anywhere in the app.

  /// Like count for a tournament's live stream. THROWS when the
  /// `watch_live_likes` table is missing so the UI can tell "no
  /// likes yet" (0) apart from "likes not available" (show "—").
  static Future<int> getWatchLiveLikeCount(String tournamentId) async {
    if (testFixtures != null) {
      return _fixtureRows('watch_live_likes',
              eqCol: 'tournament_id', eqVal: tournamentId)
          .length;
    }
    // Exact count, same pattern as countRows — but NO error
    // swallowing: a missing table must throw, not read as 0.
    final res = await client
        .from('watch_live_likes')
        .select('id')
        .eq('tournament_id', tournamentId)
        .limit(1)
        .count(CountOption.exact);
    return res.count;
  }

  /// Has this user liked this tournament's live stream? THROWS when
  /// the table is missing (same reason as [getWatchLiveLikeCount]).
  static Future<bool> hasWatchLiveLiked(
      String tournamentId, String uid) async {
    if (uid.isEmpty) return false;
    final rows = await getListOrThrow('watch_live_likes',
        eqCol: 'tournament_id',
        eqVal: tournamentId,
        eqCol2: 'firebase_uid',
        eqVal2: uid,
        limit: 1);
    return rows.isNotEmpty;
  }

  /// Like/unlike a tournament's live stream. [liked] is the CURRENT
  /// state (true = unlike, false = like). Returns true when the
  /// write landed (verified by a read-back select), false on ANY
  /// failure — including the table not existing yet. Never throws.
  static Future<bool> toggleWatchLiveLike({
    required String tournamentId,
    required String uid,
    required bool liked,
  }) async {
    if (uid.isEmpty || tournamentId.isEmpty) return false;
    if (testFixtures != null) {
      // Fixture seam (tests only): mutate the in-memory fixture
      // list exactly like the live write would (one row per
      // user+tournament, unique pair).
      final list = testFixtures!.putIfAbsent(
          'watch_live_likes', () => <Map<String, dynamic>>[]);
      if (liked) {
        list.removeWhere((r) =>
            r['tournament_id'] == tournamentId &&
            r['firebase_uid'] == uid);
      } else {
        final exists = list.any((r) =>
            r['tournament_id'] == tournamentId &&
            r['firebase_uid'] == uid);
        if (!exists) {
          list.add({
            'id': 'like-${list.length + 1}',
            'tournament_id': tournamentId,
            'firebase_uid': uid,
          });
        }
      }
      return true;
    }
    try {
      if (liked) {
        // Unlike: delete the row. An empty result just means the
        // row was already gone (idempotent) — still a success.
        await client
            .from('watch_live_likes')
            .delete()
            .eq('tournament_id', tournamentId)
            .eq('firebase_uid', uid);
        return true;
      }
      final inserted = await client.from('watch_live_likes').insert({
        'tournament_id': tournamentId,
        'firebase_uid': uid,
      }).select('id');
      return (inserted as List).isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Liker rows for a tournament's live stream (FIX 22 item 4 —
  /// the Facebook-style "X and others reacted" row). Newest first,
  /// capped at [limit] (default 50). THROWS when the
  /// `watch_live_likes` table is missing (same contract as
  /// [getWatchLiveLikeCount]) — callers treat a throw as "likers
  /// unknown" and hide the row, never fake it.
  static Future<List<Map<String, dynamic>>> getWatchLiveLikers(
      String tournamentId,
      {int limit = 50}) async {
    return getListOrThrow('watch_live_likes',
        eqCol: 'tournament_id',
        eqVal: tournamentId,
        orderBy: 'created_at',
        ascending: false,
        limit: limit);
  }

  /// The YouTube Data API v3 key from app_settings (admin-pasted in
  /// Admin > Settings). '' when unset or unreadable — callers hide
  /// the YouTube viewer count instead of faking one.
  static Future<String> getYouTubeApiKey() async {
    try {
      final s = await getAppSettings();
      final k = strOf(s['youtube_api_key'], strOf(s['youtubeApiKey']));
      return k.trim();
    } catch (_) {
      return '';
    }
  }

  // ---------- watch live: viewer-count polling (FIX 8, 2026-11-22) ----------
  //
  // Realtime does NOT exist on A1 (404 — backend lane's §3.4
  // finding), so the in-app viewer count cannot come from Realtime
  // presence. It comes from a heartbeat table instead (BACKEND
  // LANE — does NOT exist yet on production):
  //   create table watch_live_viewers (
  //     tournament_id text not null,
  //     viewer_key text not null,
  //     last_seen timestamptz not null default now(),
  //     primary key (tournament_id, viewer_key)
  //   );
  //   + RLS: anon select/insert/update/delete (v2018 REST is anon;
  //   rows carry no personal data — random keys only).
  // One row per open Watch Live screen. The screen upserts its row
  // on open and every 30 s while open, and deletes it on dispose
  // (best-effort). The count is the rows for the tournament with
  // last_seen inside the last 90 s (3x the heartbeat) — stale rows
  // age out of the count on their own. Until the table lands, the
  // heartbeat returns false and the count THROWS, so the UI shows
  // "—" — NEVER a fake 0 or a stale count. The moment the table
  // exists, the count works with no app change.

  /// FIX 8: heartbeat cadence — the screen re-upserts its viewer
  /// row this often while open.
  static const watchLiveViewerHeartbeatSeconds = 30;

  /// FIX 8: staleness window — a heartbeat row counts only while
  /// its last_seen is within the last 90 s (3x the heartbeat, so
  /// one missed beat never drops a live viewer from the count).
  static const watchLiveViewerStaleSeconds = 90;

  /// Pure: is a heartbeat row fresh? [lastSeen] is the row's
  /// last_seen (ISO-8601 string or DateTime). Fresh = seen within
  /// the staleness window (a slightly-future timestamp from clock
  /// skew still counts). Unparseable / null = stale (never
  /// counted). [now] is injectable for tests.
  static bool watchLiveViewerRowIsFresh(dynamic lastSeen,
      {DateTime? now}) {
    DateTime? seen;
    if (lastSeen is DateTime) {
      seen = lastSeen;
    } else if (lastSeen is String) {
      seen = DateTime.tryParse(lastSeen);
    }
    if (seen == null) return false;
    final at = (now ?? DateTime.now()).toUtc();
    return at.difference(seen.toUtc()) <=
        const Duration(seconds: watchLiveViewerStaleSeconds);
  }

  /// Heartbeat: upsert this screen's row in `watch_live_viewers`
  /// (tournament_id + viewer_key, last_seen = now). Returns true
  /// when the write landed (verified by the upsert's returned
  /// row), false on ANY failure — including the table not existing
  /// yet. Never throws.
  static Future<bool> heartbeatWatchLiveViewer({
    required String tournamentId,
    required String viewerKey,
  }) async {
    if (tournamentId.isEmpty || viewerKey.isEmpty) return false;
    if (testFixtures != null) {
      // Fixture seam (tests only): mutate the in-memory fixture
      // list exactly like the live upsert would (one row per
      // tournament+key, last_seen refreshed to now).
      final list = fixtureTable('watch_live_viewers')!;
      final nowIso = DateTime.now().toUtc().toIso8601String();
      final i = list.indexWhere((r) =>
          r['tournament_id'] == tournamentId &&
          r['viewer_key'] == viewerKey);
      if (i >= 0) {
        list[i] = {...list[i], 'last_seen': nowIso};
      } else {
        list.add({
          'tournament_id': tournamentId,
          'viewer_key': viewerKey,
          'last_seen': nowIso,
        });
      }
      return true;
    }
    try {
      final rows = await client.from('watch_live_viewers').upsert({
        'tournament_id': tournamentId,
        'viewer_key': viewerKey,
        'last_seen': DateTime.now().toUtc().toIso8601String(),
      }, onConflict: 'tournament_id,viewer_key').select('viewer_key');
      return (rows as List).isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Fresh-viewer count for a tournament: rows in
  /// `watch_live_viewers` for [tournamentId] with last_seen inside
  /// the staleness window. THROWS when the table is missing so the
  /// UI can tell "0 viewers" apart from "count not available"
  /// (show "—") — same contract as [getWatchLiveLikeCount].
  static Future<int> getWatchLiveViewerCount(String tournamentId) async {
    if (testFixtures != null) {
      return _fixtureRows('watch_live_viewers',
              eqCol: 'tournament_id', eqVal: tournamentId)
          .where((r) => watchLiveViewerRowIsFresh(r['last_seen']))
          .length;
    }
    // Exact count, same pattern as getWatchLiveLikeCount — but NO
    // error swallowing: a missing table must throw, not read as 0.
    // The cutoff is computed client-side (the backend MD's SQL
    // uses now() - interval '90 seconds' server-side; the app
    // sends the equivalent ISO timestamp — same 90 s window).
    final cutoff = DateTime.now()
        .toUtc()
        .subtract(const Duration(seconds: watchLiveViewerStaleSeconds))
        .toIso8601String();
    final res = await client
        .from('watch_live_viewers')
        .select('viewer_key')
        .eq('tournament_id', tournamentId)
        .gt('last_seen', cutoff)
        .limit(1)
        .count(CountOption.exact);
    return res.count;
  }

  /// FIX 20 (fix 20): record of test-mode RPC calls (tests only)
  /// — the increment is fire-and-forget, so tests assert it
  /// through this list instead of the network. Clear in setUp.
  static final List<Map<String, dynamic>> testRpcCalls = [];

  /// FIX 20 (fix 20): +1 total view for a Watch Live open. Calls
  /// the `increment_watch_views` RPC (SECURITY DEFINER on A1 —
  /// anon may call it). Best-effort: returns false on any failure
  /// and never throws; a failed call just doesn't count that view.
  /// Fixture mode: the call is RECORDED in [testRpcCalls], and the
  /// fixture tournaments row is bumped like the live RPC would —
  /// but ONLY when the row already has a `watch_views` key (a row
  /// without the key models the pre-migration server, where the
  /// RPC does not exist yet and the increment 404s).
  static Future<bool> incrementWatchViews(String tournamentId) async {
    if (tournamentId.isEmpty) return false;
    if (testFixtures != null) {
      testRpcCalls.add(
          {'rpc': 'increment_watch_views', 'p_tournament_id': tournamentId});
      final list = fixtureTable('tournaments');
      if (list != null) {
        final i = list.indexWhere((r) => r['id'] == tournamentId);
        if (i >= 0 && list[i].containsKey('watch_views')) {
          final cur = list[i]['watch_views'];
          list[i] = {
            ...list[i],
            'watch_views': (cur is num ? cur.toInt() : 0) + 1
          };
        }
      }
      return true;
    }
    try {
      await client.rpc('increment_watch_views',
          params: {'p_tournament_id': tournamentId});
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Best-effort delete of one screen's viewer row (dispose).
  /// Never throws — a failed delete is harmless: the row ages out
  /// of the count after the 90 s staleness window anyway.
  static Future<void> leaveWatchLiveViewer({
    required String tournamentId,
    required String viewerKey,
  }) async {
    if (tournamentId.isEmpty || viewerKey.isEmpty) return;
    if (testFixtures != null) {
      fixtureTable('watch_live_viewers')?.removeWhere((r) =>
          r['tournament_id'] == tournamentId &&
          r['viewer_key'] == viewerKey);
      return;
    }
    try {
      await client
          .from('watch_live_viewers')
          .delete()
          .eq('tournament_id', tournamentId)
          .eq('viewer_key', viewerKey);
    } catch (_) {
      // Best-effort only (see doc comment).
    }
  }

  /// Same query as [getList], but a failed read THROWS instead of
  /// returning []. Use it where "no data" and "could not load"
  /// must not be confused — the admin results queue (an empty
  /// queue must mean "nothing pending", never "the read failed"),
  /// and exactly-once checks. Display-only reads keep using
  /// [getList].
  static Future<List<Map<String, dynamic>>> getListOrThrow(
    String table, {
    String? eqCol,
    dynamic eqVal,
    String? eqCol2,
    dynamic eqVal2,
    String? orderBy,
    bool ascending = true,
    int? limit,
  }) async {
    if (testFixtures != null) {
      return _fixtureRows(table, eqCol: eqCol, eqVal: eqVal, eqCol2: eqCol2, eqVal2: eqVal2, orderBy: orderBy, ascending: ascending, limit: limit);
    }
    dynamic q = client.from(table).select();
    if (eqCol != null) q = q.eq(eqCol, eqVal);
    if (eqCol2 != null) q = q.eq(eqCol2, eqVal2);
    if (orderBy != null) q = q.order(orderBy, ascending: ascending);
    if (limit != null) q = q.limit(limit);
    final rows = await q;
    return (rows as List).map((r) => Map<String, dynamic>.from(r as Map)).toList();
  }

  /// Live list stream: initial fetch, then refetch on every
  /// postgres_changes event for the table/filter. This is a real
  /// realtime stream (not a timer poll). One-shot FutureBuilders in
  /// screens refetch on navigation/resume, which is the poll-on-resume
  /// fallback for screens that do not hold a stream.
  static Stream<List<Map<String, dynamic>>> streamList(
    String table, {
    String? eqCol,
    dynamic eqVal,
    String? eqCol2,
    dynamic eqVal2,
    String? orderBy,
    bool ascending = true,
    int? limit,
    Duration? pollInterval, // O-2: re-fetch on a timer (the self-hosted server has no Realtime relay).
  }) {
    if (testFixtures != null) {
      // Broadcast, like the live controller stream: Home shares one
      // stream instance across several StreamBuilders (tournaments
      // feed the hero AND the list; my-registrations feed the
      // pinned bar, the list AND My Contests) — a single-subscription
      // Stream.value would throw "already been listened to" on the
      // second listener.
      return Stream<List<Map<String, dynamic>>>.value(
        _fixtureRows(table, eqCol: eqCol, eqVal: eqVal, eqCol2: eqCol2, eqVal2: eqVal2, orderBy: orderBy, ascending: ascending, limit: limit),
      ).asBroadcastStream();
    }
    final controller = StreamController<List<Map<String, dynamic>>>.broadcast();
    RealtimeChannel? channel;
    var closed = false;
    Future<void> fetch() async {
      if (closed) return;
      final rows = await getList(table, eqCol: eqCol, eqVal: eqVal, eqCol2: eqCol2, eqVal2: eqVal2, orderBy: orderBy, ascending: ascending, limit: limit);
      if (!closed && !controller.isClosed) controller.add(rows);
    }

    fetch();
    // O-2 poll: same fetch() on a timer (getList swallows read
    // errors, returning [], so a failed poll can never kill the
    // stream). Only created when a caller passes pollInterval.
    Timer? pollTimer;
    if (pollInterval != null) {
      pollTimer = Timer.periodic(pollInterval, (_) => fetch());
    }
    final chanName = 's_${table}_${eqCol ?? 'all'}_${eqVal ?? ''}_${eqCol2 ?? ''}_${eqVal2 ?? ''}_${DateTime.now().microsecondsSinceEpoch}';
    try {
      channel = client.channel(chanName).onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: table,
        filter: eqCol != null ? PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: eqCol, value: eqVal) : null,
        callback: (_) => fetch(),
      );
      channel.subscribe();
    } catch (_) {
      // Realtime unavailable: stream still emits the initial fetch;
      // screens refetch on navigation/resume (poll-on-resume fallback).
    }
    controller.onCancel = () async {
      closed = true;
      pollTimer?.cancel();
      try {
        await channel?.unsubscribe();
      } catch (_) {}
      await controller.close();
    };
    return controller.stream;
  }

  static Stream<Map<String, dynamic>> streamRow(String table, String col, dynamic val) {
    return streamList(table, eqCol: col, eqVal: val, limit: 1).map((rows) => rows.isEmpty ? <String, dynamic>{} : rows.first);
  }

  // ---------- normalisers (snake_case row -> map with BOTH keys) ----------
  static Map<String, dynamic> normProfile(Map<String, dynamic> r) {
    if (r.isEmpty) return {};
    final m = Map<String, dynamic>.from(r);
    final uid = strOf(r['firebase_uid'], strOf(r['uid']));
    m['firebase_uid'] = uid;
    m['uid'] = uid;
    m['displayName'] = strOf(r['display_name'], strOf(r['displayName'], 'User'));
    m['display_name'] = m['displayName'];
    m['email'] = strOf(r['email']);
    m['photoURL'] = strOf(r['photo_url'], strOf(r['photoURL']));
    m['photo_url'] = m['photoURL'];
    m['depositBalance'] = numOf(r['deposit_balance'], numOf(r['depositBalance']));
    m['deposit_balance'] = m['depositBalance'];
    m['winningCash'] = numOf(r['winning_cash'], numOf(r['winningCash']));
    m['winning_cash'] = m['winningCash'];
    m['bonusCash'] = numOf(r['bonus_cash'], numOf(r['bonusCash']));
    m['bonus_cash'] = m['bonusCash'];
    m['totalMatches'] = intOf(r['total_matches'], intOf(r['totalMatches']));
    m['total_matches'] = m['totalMatches'];
    m['wonMatches'] = intOf(r['won_matches'], intOf(r['wonMatches']));
    m['won_matches'] = m['wonMatches'];
    m['totalEarnings'] = numOf(r['total_earnings'], numOf(r['totalEarnings']));
    m['total_earnings'] = m['totalEarnings'];
    m['referralEarnings'] = numOf(r['referral_earnings'], numOf(r['referralEarnings']));
    m['referral_earnings'] = m['referralEarnings'];
    m['referralCode'] = strOf(r['referral_code'], strOf(r['referralCode']));
    m['referral_code'] = m['referralCode'];
    m['referredBy'] = strOf(r['referred_by'], strOf(r['referredBy']));
    m['referred_by'] = m['referredBy'];
    m['onesignalId'] = strOf(r['onesignal_id'], strOf(r['onesignalId']));
    m['onesignal_id'] = m['onesignalId'];
    m['username'] = strOf(r['username']);
    m['gameUid'] = strOf(r['game_uid'], strOf(r['gameUid']));
    m['game_uid'] = m['gameUid'];
    m['lastCheckedNotifications'] = parseTs(r['last_checked_notifications'] ?? r['lastCheckedNotifications']);
    m['last_checked_notifications'] = m['lastCheckedNotifications'];
    m['lastLogin'] = parseTs(r['last_login'] ?? r['lastLogin']);
    m['createdAt'] = parseTs(r['created_at'] ?? r['createdAt']);
    m['isAdmin'] = r['is_admin'] == true || r['isAdmin'] == true;
    return m;
  }

  static Map<String, dynamic> normTournament(Map<String, dynamic> r) {
    if (r.isEmpty) return {};
    final m = Map<String, dynamic>.from(r);
    m['id'] = strOf(r['id']);
    final name = strOf(r['name'], strOf(r['tournamentName'], strOf(r['title'], strOf(r['gameName'], 'Tournament'))));
    m['name'] = name;
    m['tournamentName'] = name;
    m['title'] = name;
    m['gameName'] = strOf(r['game_name'], strOf(r['gameName'], strOf(r['game'], '')));
    m['game'] = m['gameName'];
    m['gameId'] = strOf(r['game_id'], strOf(r['gameId']));
    m['created_by'] = strOf(r['created_by'], strOf(r['createdBy'], ''));
    m['mode'] = strOf(r['mode'], 'Solo');
    m['type'] = strOf(r['type']);
    m['status'] = strOf(r['status'], 'upcoming').toLowerCase();
    // Status vocabulary: the user app only understands 'ongoing' for a
    // live tournament; older admin writes used 'live'. Normalise here
    // so a 'live' row behaves as live everywhere (audit fix 2026-11-21).
    if (m['status'] == 'live') m['status'] = 'ongoing';
    m['startTime'] = parseTs(r['start_time'] ?? r['startTime']);
    m['start_time'] = m['startTime'];
    m['prizePool'] = numOf(r['prize_pool'], numOf(r['prizePool']));
    m['prize_pool'] = m['prizePool'];
    m['entryFee'] = numOf(r['entry_fee'], numOf(r['entryFee']));
    m['entry_fee'] = m['entryFee'];
    m['maxPlayers'] = intOf(r['max_players'], intOf(r['maxPlayers']));
    m['max_players'] = m['maxPlayers'];
    m['description'] = strOf(r['description']);
    m['rules'] = strOf(r['rules']);
    m['banner'] = strOf(r['banner_url'], strOf(r['banner'], strOf(r['image_url'], strOf(r['image'], ''))));
    m['bannerUrl'] = m['banner'];
    m['imageUrl'] = m['banner'];
    m['image'] = m['banner'];
    m['map'] = strOf(r['map']);
    m['tags'] = asList(r['tags']);
    m['prizeDistribution'] = r['prize_distribution'] ?? r['prizeDistribution'];
    m['perKillPrize'] = numOf(r['per_kill_prize'], numOf(r['perKillPrize']));
    // N-create-tournament (2026-11-20): professional Create Tournament
    // fields. commission_pct defaults to the platform rate (10%) when
    // the column / row has no value yet (pre-029 DBs). lobby_opens_at
    // and registration_deadline are ms timestamps (0 = not set), same
    // shape as startTime above.
    m['commissionPct'] = numOf(r['commission_pct'], numOf(r['commissionPct'], 10));
    m['commission_pct'] = m['commissionPct'];
    m['lobbyOpensAt'] = parseTs(r['lobby_opens_at'] ?? r['lobbyOpensAt']);
    m['lobby_opens_at'] = m['lobbyOpensAt'];
    m['registrationDeadline'] = parseTs(r['registration_deadline'] ?? r['registrationDeadline']);
    m['registration_deadline'] = m['registrationDeadline'];
    // N-create-tournament: level gate (020 column). 0 = no gate.
    m['levelRequired'] = intOf(r['level_required'], intOf(r['levelRequired']));
    m['level_required'] = m['levelRequired'];
    m['roomId'] = strOf(r['room_id'], strOf(r['roomId']));
    m['roomPassword'] = strOf(r['room_password'], strOf(r['roomPassword']));
    m['showIdPass'] = r['show_id_pass'] ?? r['showIdPass'];
    m['show_id_pass'] = m['showIdPass'];
    m['voiceEnabled'] = r['voice_enabled'] ?? r['voiceEnabled'];
    m['watchLiveUrl'] = strOf(r['watch_live_url'], strOf(r['live_url'], strOf(r['watchLiveUrl'])));
    m['live_url'] = m['watchLiveUrl'];
    // Watch Live toggle (2026-11-21): `show_watch_live` is NOT a
    // column on the server yet — only set the keys when the raw row
    // actually carries them, so watchLiveVisibleFor() can tell
    // "column missing" (fallback: URL present = visible) from
    // "column present and false" (strictly hidden). See
    // watch_live_screen.dart for the backend step still needed.
    if (r.containsKey('show_watch_live') || r.containsKey('showWatchLive')) {
      m['showWatchLive'] = r['show_watch_live'] ?? r['showWatchLive'];
      m['show_watch_live'] = m['showWatchLive'];
    }
    return m;
  }

  static Map<String, dynamic> normChat(Map<String, dynamic> r) {
    if (r.isEmpty) return {};
    final m = Map<String, dynamic>.from(r);
    m['id'] = strOf(r['id']);
    m['firebase_uid'] = strOf(r['firebase_uid'], strOf(r['uid']));
    m['uid'] = m['firebase_uid'];
    m['display_name'] = strOf(r['display_name'], strOf(r['sender'], strOf(r['displayName'], 'User')));
    m['sender'] = m['display_name'];
    m['displayName'] = m['display_name'];
    m['message'] = strOf(r['message']);
    m['reply_to'] = r['reply_to'] ?? r['replyTo'];
    m['replyTo'] = m['reply_to'];
    m['is_admin'] = r['is_admin'] == true || r['admin'] == true;
    // Photo (migration 068, P1-7): chat_messages.image_url — the
    // same column the DM photo path writes; normChat used to pass it
    // through only as an unmapped raw key, now it is in the model.
    m['image_url'] = strOf(r['image_url'], strOf(r['image']));
    m['image'] = m['image_url'];
    m['timestamp'] = parseTs(r['played_at'] ?? r['created_at'] ?? r['timestamp']);
    m['created_at'] = m['timestamp'];
    // Moderation (032, live): a deleted message carries deleted_at.
    m['deleted_at'] = r['deleted_at'];
    m['deletedAt'] = r['deleted_at'];
    return m;
  }

  static Map<String, dynamic> normTx(Map<String, dynamic> r) {
    if (r.isEmpty) return {};
    final m = Map<String, dynamic>.from(r);
    m['id'] = strOf(r['id']);
    m['type'] = strOf(r['type']);
    m['amount'] = numOf(r['amount']);
    m['description'] = strOf(r['description']);
    m['timestamp'] = parseTs(r['played_at'] ?? r['created_at'] ?? r['timestamp']);
    return m;
  }

  static Map<String, dynamic> normNotification(Map<String, dynamic> r) {
    if (r.isEmpty) return {};
    final m = Map<String, dynamic>.from(r);
    m['id'] = strOf(r['id']);
    m['title'] = strOf(r['title'], 'Notification');
    m['message'] = strOf(r['message'], strOf(r['body']));
    m['body'] = m['message'];
    m['image'] = strOf(r['image_url'], strOf(r['image']));
    m['image_url'] = m['image'];
    m['timestamp'] = parseTs(r['played_at'] ?? r['created_at'] ?? r['timestamp']);
    return m;
  }

  static Map<String, dynamic> normTicket(Map<String, dynamic> r) {
    if (r.isEmpty) return {};
    final m = Map<String, dynamic>.from(r);
    m['id'] = strOf(r['id']);
    m['subject'] = strOf(r['subject']);
    m['message'] = strOf(r['message']);
    m['imageUrl'] = strOf(r['image_url'], strOf(r['imageUrl']));
    m['image_url'] = m['imageUrl'];
    m['status'] = strOf(r['status'], 'open');
    m['adminReply'] = strOf(r['reply'], strOf(r['admin_reply'], strOf(r['adminReply'])));
    m['reply'] = m['adminReply'];
    m['admin_reply'] = m['adminReply'];
    m['replies'] = asList(r['replies']);
    m['userEmail'] = strOf(r['user_email'], strOf(r['userEmail']));
    m['timestamp'] = parseTs(r['played_at'] ?? r['created_at'] ?? r['timestamp']);
    return m;
  }

  static Map<String, dynamic> normMatchHistory(Map<String, dynamic> r) {
    if (r.isEmpty) return {};
    final m = Map<String, dynamic>.from(r);
    m['id'] = strOf(r['id']);
    m['tournamentName'] = strOf(r['tournament_name'], strOf(r['tournamentName'], 'Match'));
    m['name'] = m['tournamentName'];
    m['rank'] = r['rank'];
    m['kills'] = intOf(r['kills']);
    m['damage'] = intOf(r['damage']);
    m['headshot'] = intOf(r['headshot']);
    m['winnings'] = numOf(r['earnings'], numOf(r['winnings']));
    m['earnings'] = m['winnings'];
    m['result'] = strOf(r['result']);
    m['timestamp'] = parseTs(r['played_at'] ?? r['created_at'] ?? r['timestamp']);
    return m;
  }

  // ---------- app_settings (single row) ----------
  static Future<Map<String, dynamic>> getAppSettings() async {
    try {
      final row = await client.from('app_settings').select().eq('id', 1).maybeSingle();
      if (row == null) return {};
      var m = Map<String, dynamic>.from(row as Map);
      // Nested jsonb config column, if the admin port stores settings there.
      final cfg = asMap(m['config']);
      for (final e in cfg.entries) {
        m.putIfAbsent(e.key.toString(), () => e.value);
      }
      // Camel aliases for the keys screens read.
      final aliases = <String, String>{
        'maintenance_mode': 'maintenanceMode',
        'maintenance_message': 'maintenanceMessage',
        'signup_bonus': 'signupBonus',
        'min_withdraw': 'minWithdraw',
        'referral_bonus': 'referralBonus',
        'imgbb_api_key': 'imgbbApiKey',
        'voice_enabled': 'voiceEnabled',
        'free_tournament_quota_enabled': 'freeTournamentQuotaEnabled',
        'support_contact': 'supportContact',
        'policy_terms': 'policyTerms',
        'policy_privacy': 'policyPrivacy',
        'policy_refund': 'policyRefund',
        'policy_fair_play': 'policyFairPlay',
        // P2 #34 (2026-11-21): camel aliases for the 3 admin-editable
        // policy docs (069 longer names, live on production). The
        // RulesPoliciesPage switch (more_screens.dart, BLOCKED on the
        // leaderboard lane) will read these via _policy(); the admin
        // editor reads the snake_case keys directly.
        'policy_community_guidelines': 'policyCommunityGuidelines',
        'policy_tournament_rules': 'policyTournamentRules',
        'policy_chat_rules': 'policyChatRules',
        'update_config': 'updateConfig',
        'popup_banner': 'popupBanner',
        'upi_details': 'upiDetails',
        'qr_code_url': 'qrCodeUrl',
      };
      for (final e in aliases.entries) {
        if (m.containsKey(e.key) && !m.containsKey(e.value)) m[e.value] = m[e.key];
        if (m.containsKey(e.value) && !m.containsKey(e.key)) m[e.key] = m[e.value];
      }
      return m;
    } catch (_) {
      return {};
    }
  }

  static Future<bool> isMaintenanceOn() async {
    final s = await getAppSettings();
    return s['maintenanceMode'] == true || s['maintenance_mode'] == true;
  }

  /// Free-tournament quota admin toggle (user decision, voice call
  /// 2026-11-20 ~18:45 PKT): the admin can turn the 1/week free
  /// quota ON/OFF from the admin panel — the column is
  /// app_settings.free_tournament_quota_enabled (draft migration 033,
  /// default true). NULL-TOLERANT / fail-safe: a missing column, a
  /// missing key, or a failed read all mean quota ON — the quota stays
  /// enforced until the admin EXPLICITLY turns it OFF. Callers must
  /// never treat "unknown" as OFF.
  static Future<bool> isFreeTournamentQuotaEnabled() async {
    try {
      final s = await getAppSettings();
      final v = s['freeTournamentQuotaEnabled'] ?? s['free_tournament_quota_enabled'];
      return v != false;
    } catch (_) {
      return true;
    }
  }

  // ---------- profiles ----------
  static Future<Map<String, dynamic>> getProfile(String uid) async {
    final row = await getRow('profiles', 'firebase_uid', uid);
    return normProfile(row);
  }

  static Stream<Map<String, dynamic>> streamProfile(String uid) =>
      streamRow('profiles', 'firebase_uid', uid).map(normProfile);

  static Future<void> updateProfile(String uid, Map<String, dynamic> patch) async {
    await client.from('profiles').update(patch).eq('firebase_uid', uid);
  }

  static String generateReferralCode([int length = 8]) {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final rnd = Random.secure();
    return List.generate(length, (_) => chars[rnd.nextInt(chars.length)]).join();
  }

  /// F29 (2026-11-22, Batch 3B): returns whether the row actually
  /// landed. It used to return void and swallow its own errors, so
  /// a failed commission row vanished silently and no caller could
  /// tell. Callers that only log (prize/referral/deposit rows) keep
  /// ignoring the return; callers that must surface a failure
  /// (join commission — see [joinTournament]) check it. A failure
  /// still never throws: accounting must never break the main flow.
  static Future<bool> recordTransaction(String uid, String type, double amount, String description, [Map<String, dynamic> details = const {}]) async {
    try {
      await client.from('transactions').insert({
        'firebase_uid': uid,
        'type': type,
        'amount': amount,
        'description': description,
        ...details,
      });
      return true;
    } catch (e) {
      // Transaction logging must never break the main flow (same as HTML) —
      // but the failure is now VISIBLE (log + bool) instead of swallowed.
      debugPrint('recordTransaction FAILED ($type, Rs $amount, $uid): $e');
      return false;
    }
  }

  /// N-create-tournament (2026-11-20): platform commission for ONE paid
  /// entry. Called from [joinTournament] after the entry fee is taken:
  /// commission = entry fee x tournament commission_pct (default 10%).
  /// One row per paid entry, type 'platform_commission', status
  /// 'completed', tournament_id set so Prize Escrow & Proof can SUM it
  /// per tournament. Free entries (fee 0) never reach here — free
  /// tournaments are BILKUL FREE, no commission row at all. F29
  /// (2026-11-22): returns whether the row landed (false = the join
  /// caller surfaces it instead of losing the row silently).
  /// Amount is rounded to 2dp (paise).
  static Future<bool> recordPlatformCommission({
    required String tournamentId,
    required String uid,
    required double entryFee,
    required double commissionPct,
    required String tournamentName,
  }) async {
    final commission = (entryFee * commissionPct / 100 * 100).round() / 100;
    if (commission <= 0) return true;
    return recordTransaction(
      uid,
      'platform_commission',
      commission,
      'Platform commission ($commissionPct%) — $tournamentName',
      {
        'tournament_id': tournamentId,
        'status': 'completed',
        'details': {
          'entry_fee': entryFee,
          'commission_pct': commissionPct,
          'tournament_name': tournamentName,
        },
      },
    );
  }

  /// SCORING — DECIDED MODEL (OD-02, decided 2026-11-21, ChatGPT
  /// blueprint §5-5 / backend guide §1.4; table refined by Sameer
  /// 2026-11-21 02:20): placement points 1st = 10, 2nd = 7,
  /// 3rd = 5, 4th and below = 0, + 1 point per kill.
  /// 1st + 12 kills = 22. The old client formula (kills x 10 + 50
  /// for a 1st-place finish) is SUPERSEDED. Delegates to the
  /// platform contract [calculateMatchPoints]
  /// (platform/core/scoring.dart); the server RPC
  /// calculate_match_score is the authority and this mirror is for
  /// display/preview only (developer requirement #5: never trust
  /// client-calculated points). Pure function (unit-tested).
  /// [template] defaults to the decided template; async callers
  /// pass the admin override via [ScoringTemplateStore].
  static int matchPoints({required int kills, required int placement, ScoringTemplate template = kDefaultScoringTemplate}) =>
      calculateMatchPoints(placement: placement, kills: kills, template: template);

  /// P1-10 — split [matchPoints] into its stored parts so the
  /// approve path can persist them on the tournament_results row
  /// (placement_points / kill_points / team_points). Pure function
  /// (unit-tested). The split is derived from the SAME total, so
  /// placement_points + kill_points == team_points == matchPoints
  /// always; placement <= 0 scores 0 on every part (mirrors
  /// [calculateMatchPoints]). The server RPCs (042/054) are the
  /// authority for credited points and overwrite these columns
  /// with the same decided table when they run.
  static Map<String, int> splitMatchPoints({required int kills, required int placement, ScoringTemplate template = kDefaultScoringTemplate}) {
    final total = matchPoints(kills: kills, placement: placement, template: template);
    if (placement <= 0 || total <= 0) {
      return {'placement_points': 0, 'kill_points': 0, 'team_points': 0};
    }
    final killPoints = (kills < 0 ? 0 : kills) * template.killPoints;
    return {
      'placement_points': total - killPoints,
      'kill_points': killPoints,
      'team_points': total,
    };
  }

  /// P1-10 — merge stored result points onto registration rows.
  /// Pure function (unit-tested): [registrations] are the
  /// tournament_registrations rows (which carry NO points column —
  /// verified on staging), [results] the tournament_results rows
  /// for the same tournament. Each registration gains
  /// 'team_points' / 'placement_points' / 'kill_points' /
  /// 'result_status' from its matching result row (by
  /// firebase_uid); rows with no result keep 0. Returns the same
  /// list (mutated in place) for the [getResultsForTournament]
  /// call site.
  static List<Map<String, dynamic>> mergeResultPoints(
    List<Map<String, dynamic>> registrations,
    List<Map<String, dynamic>> results,
  ) {
    final byUid = <String, Map<String, dynamic>>{};
    for (final r in results) {
      byUid[strOf(r['firebase_uid'])] = r;
    }
    for (final reg in registrations) {
      final res = byUid[strOf(reg['firebase_uid'])];
      if (res != null) {
        reg['team_points'] = intOf(res['team_points'], 0);
        reg['placement_points'] = intOf(res['placement_points'], 0);
        reg['kill_points'] = intOf(res['kill_points'], 0);
        reg['result_status'] = strOf(res['status']);
      } else {
        reg['team_points'] = 0;
        reg['placement_points'] = 0;
        reg['kill_points'] = 0;
        reg['result_status'] = '';
      }
    }
    return registrations;
  }

  /// N-create-tournament AUTOMATION (2026-11-20): automatic prize
  /// calculation for ONE verified result. killAmount = kills x
  /// per-kill prize. winBonus = the placement's share of the prize
  /// pool from the tournament's 1st/2nd/3rd split (0 for 4th+).
  /// Returns {'killAmount', 'winBonus', 'total'} in Rs, rounded to
  /// paise. Pure function (unit-tested).
  static Map<String, double> matchWinnings({
    required int kills,
    required double perKillPrize,
    required int placement,
    required double prizePool,
    required int splitFirst,
    required int splitSecond,
    required int splitThird,
  }) {
    double round2(double v) => (v * 100).round() / 100;
    final killAmount = round2(kills * perKillPrize);
    final pct = placement == 1
        ? splitFirst
        : placement == 2
            ? splitSecond
            : placement == 3
                ? splitThird
                : 0;
    final winBonus = round2(prizePool * pct / 100);
    return {'killAmount': killAmount, 'winBonus': winBonus, 'total': round2(killAmount + winBonus)};
  }

  /// N-create-tournament ANTI-FRAUD (2026-11-20): device signals.
  /// Install id — a random id generated ONCE per app install and kept
  /// in SharedPreferences. It survives account switches on the same
  /// phone, so several accounts farming from one device share one
  /// install id. It is NOT a hardware id and is never shown to users.
  /// Stored on profiles.install_id (030 draft) best-effort — a pre-030
  /// DB simply has no value yet.
  static Future<String> getInstallId() async {
    const key = 'arena_install_id';
    try {
      final prefs = await SharedPreferences.getInstance();
      final existing = prefs.getString(key);
      if (existing != null && existing.isNotEmpty) return existing;
      final rnd = Random.secure();
      final id = List.generate(32, (_) => rnd.nextInt(16).toRadixString(16)).join();
      await prefs.setString(key, id);
      return id;
    } catch (_) {
      return '';
    }
  }

  /// Human-readable device label for the admin fraud view
  /// (e.g. "android 12"). Best-effort, never throws.
  static String deviceLabel() {
    try {
      return '${Platform.operatingSystem} ${Platform.operatingSystemVersion}'.trim();
    } catch (_) {
      return '';
    }
  }

  /// N-create-tournament (2026-11-20): admin approval queue for
  /// user-created tournaments. Approve flips a pending/draft tournament
  /// to 'upcoming' (live); reject flips it to 'cancelled'. Both write
  /// an admin_activity_logs row (best-effort — a failed log never
  /// blocks the status change). Caller must be the designated admin;
  /// the queue page re-verifies that on entry.
  static Future<void> approveTournament(String id, String adminUid) async {
    await client.from('tournaments').update({'status': 'upcoming'}).eq('id', id);
    // Notify the creator of the outcome (audit fix 2026-11-21).
    try {
      final t = await getRow('tournaments', 'id', id);
      final creator = strOf(t['created_by']);
      if (creator.isNotEmpty) {
        await notifyUser(creator, 'Tournament Approved', '"${strOf(t['name'], 'Your tournament')}" approve ho gaya hai — ab live hai aur players join kar sakte hain.');
      }
    } catch (_) {}
    try {
      await client.from('admin_activity_logs').insert({
        'admin_uid': adminUid,
        'action': 'tournament_approve',
        'target_type': 'tournament',
        'target_id': id,
        'new_value': {'status': 'upcoming'},
      });
    } catch (_) {}
  }

  static Future<void> rejectTournament(String id, String adminUid, {String? reason}) async {
    await client.from('tournaments').update({'status': 'cancelled'}).eq('id', id);
    // Notify the creator of the outcome, with the reason when given.
    try {
      final t = await getRow('tournaments', 'id', id);
      final creator = strOf(t['created_by']);
      if (creator.isNotEmpty) {
        final r = (reason ?? '').trim();
        await notifyUser(creator, 'Tournament Rejected', '"${strOf(t['name'], 'Your tournament')}" approve nahi hua.${r.isEmpty ? '' : ' Wajah: $r'}');
      }
    } catch (_) {}
    try {
      await client.from('admin_activity_logs').insert({
        'admin_uid': adminUid,
        'action': 'tournament_reject',
        'target_type': 'tournament',
        'target_id': id,
        'new_value': {'status': 'cancelled'},
        if (reason != null && reason.trim().isNotEmpty) 'reason': reason.trim(),
      });
    } catch (_) {}
  }

  /// Mirrors the HTML new-user branch: same defaults, signup bonus from
  /// app_settings. Existing profile: only last_login is refreshed.
  static Future<Map<String, dynamic>> ensureUserProfile(User user, {String? referralCodeFromSignup, String? displayNameOverride}) async {
    final existing = await getProfile(user.uid);
    if (existing.isNotEmpty) {
      try {
        await updateProfile(user.uid, {'last_login': isoNow()});
      } catch (_) {}
      return existing;
    }
    final settings = await getAppSettings();
    final signupBonus = numOf(settings['signupBonus'], 10);
    final displayName = displayNameOverride ?? user.displayName ?? (user.email?.split('@').first ?? 'User');
    final profile = <String, dynamic>{
      'firebase_uid': user.uid,
      'display_name': displayName,
      'email': user.email,
      'photo_url': user.photoURL,
      'deposit_balance': 0,
      'winning_cash': 0,
      'bonus_cash': signupBonus,
      'total_matches': 0,
      'won_matches': 0,
      'total_earnings': 0,
      'referral_earnings': 0,
      'referral_code': generateReferralCode(),
      'is_admin': false,
      'last_checked_notifications': isoNow(),
      'last_login': isoNow(),
    };
    String? referrerId;
    // ANTI-FRAUD (N-create-tournament, 2026-11-20): self-referral +
    // same-device farming. A user typing their OWN code, or signing up
    // on the same device that already owns the referrer account, gets
    // NO pending referral row at all.
    final installId = await getInstallId();
    if (referralCodeFromSignup != null && referralCodeFromSignup.trim().isNotEmpty) {
      final code = referralCodeFromSignup.trim();
      final refRow = await getRow('profiles', 'referral_code', code);
      if (refRow.isNotEmpty) {
        final candidate = strOf(refRow['firebase_uid']);
        final sameDevice = installId.isNotEmpty && strOf(refRow['install_id']).isNotEmpty && strOf(refRow['install_id']) == installId;
        if (candidate.isNotEmpty && candidate != user.uid && !sameDevice) {
          referrerId = candidate;
          profile['referred_by'] = referrerId;
        }
      }
    }
    await client.from('profiles').insert(profile);
    // Device signal, best-effort (030 draft columns install_id /
    // device_model; a pre-030 DB throws PGRST204 here and the update
    // is skipped silently — signup itself never breaks on it).
    if (installId.isNotEmpty) {
      try {
        await updateProfile(user.uid, {'install_id': installId, 'device_model': deviceLabel()});
      } catch (_) {}
    }
    if (referrerId != null && referrerId.isNotEmpty) {
      try {
        await client.from('pending_referrals').insert({
          'referrer_uid': referrerId,
          'referrer_email': strOf((await getProfile(referrerId))['email']),
          'referred_uid': user.uid,
          'referred_email': user.email,
          'status': 'pending',
        });
      } catch (_) {}
    }
    if (signupBonus > 0) {
      await recordTransaction(user.uid, 'signup_bonus', signupBonus, 'Welcome Bonus');
    }
    return normProfile(profile);
  }

  /// FIX 7: returns true ONLY when the profiles write actually
  /// landed. The old version swallowed every error (catch (_) {})
  /// and returned void, so the UI toasted "marked as read" even
  /// when the write never happened — the unread dots (timestamp >
  /// last_checked) all stayed. Callers must check the result.
  static Future<bool> markNotificationsRead(String uid) async {
    try {
      await updateProfile(uid, {'last_checked_notifications': isoNow()});
      // BADGE FIX (2026-11-22): the bell badge recomputes on realtime
      // events, which are unreliable — nudge it directly so the count
      // drops the moment the read lands, not on the next restart.
      notifyUnreadChanged();
      return true;
    } catch (e) {
      debugPrint('[SupaDb] markNotificationsRead failed: $e');
      return false;
    }
  }

  // ---------- tournaments & registrations ----------
  static int teamSizeOf(Map<String, dynamic> t) {
    final mode = strOf(t['mode'], 'Solo').toLowerCase();
    if (mode.contains('squad') || mode.contains('team')) return 4;
    if (mode.contains('duo')) return 2;
    return 1;
  }

  static Future<List<Map<String, dynamic>>> getTournaments() async {
    final rows = await getList('tournaments', orderBy: 'start_time', ascending: true);
    final list = rows.map(normTournament).toList();
    // CACHE-FIRST (Batch 3B, user order 2026-11-22 ~01:15 PKT): every
    // successful list fetch refreshes the on-phone cache, so the next
    // app open can render instantly from disk while the network
    // refreshes in the background. An empty/error fetch NEVER
    // overwrites a good cache (getList swallows errors into []).
    if (list.isNotEmpty) unawaited(writeTournamentsCache(rows));
    return list;
  }

  /// CACHE-FIRST (Batch 3B, user order 2026-11-22 ~01:15 PKT):
  /// home/tournament lists are cached on the phone as JSON in
  /// SharedPreferences. Home reads the cache FIRST and renders it
  /// instantly on app open; the live stream then refreshes in the
  /// background. Navigation is never blocked on the network and no
  /// screen stands waiting on a sync/load. Raw rows are cached (not
  /// normed maps) so [normTournament] stays the single normaliser.
  /// Best-effort throughout: a cache failure degrades to the old
  /// network-only behaviour, never to a crash or a stuck screen.
  static const String _tournamentsCacheKey = 'cached_tournaments_v1';

  static Future<void> writeTournamentsCache(
      List<Map<String, dynamic>> rawRows) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final capped = rawRows.length > 200 ? rawRows.sublist(0, 200) : rawRows;
      await prefs.setString(_tournamentsCacheKey, jsonEncode(capped));
    } catch (_) {}
  }

  static Future<List<Map<String, dynamic>>> readCachedTournaments() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_tournamentsCacheKey);
      if (raw == null || raw.isEmpty) return [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return decoded
          .whereType<Map>()
          .map((m) => normTournament(Map<String, dynamic>.from(m)))
          .where((t) => strOf(t['id']).isNotEmpty)
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// N-create-tournament ANTI-FRAUD: how many tournaments [uid] created
  /// today (local day).
  /// RETIRED as the live rule (user decision, voice call 2026-11-20
  /// ~18:05 PKT): the 3/day cap it enforced is SUPERSEDED — PAID
  /// creations are now unlimited and FREE creations are capped at 1 per
  /// ISO calendar week (see [countFreeTournamentsCreatedThisWeek]).
  /// Kept only so old callers/admin tooling still compile; do NOT use
  /// it as a creation gate any more.
  /// Client-side count — a second device could bypass it; server
  /// enforcement is a TODO (see N checkpoint).
  static Future<int> countTournamentsCreatedToday(String uid) async {
    final rows = await getList('tournaments', eqCol: 'created_by', eqVal: uid);
    final now = DateTime.now();
    final todayStart = DateTime(now.year, now.month, now.day).millisecondsSinceEpoch;
    var n = 0;
    for (final r in rows) {
      if (parseTs(r['created_at']) >= todayStart) n++;
    }
    return n;
  }

  /// CREATION QUOTA (user decisions, voice calls 2026-11-20):
  ///   ~18:04 PKT — PAID tournaments (entry fee > 0) have NO limit.
  ///   ~18:05 PKT — FREE tournaments (entry fee == 0): max 1 per WEEK
  ///   per user. This counts the user's FREE creations in the current
  ///   ISO calendar week (Mon-Sun).
  /// WINDOW: calendar week, NOT a rolling 7 days — the codebase already
  /// has the calendar-week helper [periodKeyFor] (ISO-8601 'YYYY-Www',
  /// used by the 018 weekly challenge/reward claims), so the quota uses
  /// the same week definition the rest of the app shows. A row counts
  /// when periodKeyFor(created_at, 'weekly') == this week's key.
  /// Uses only existing columns: tournaments.created_at (timestamptz,
  /// indexed by 029) and tournaments.entry_fee. Rows with no entry_fee
  /// value count as FREE (conservative — they were created free).
  /// Client-side count, same caveat as [countTournamentsCreatedToday]:
  /// a second device could bypass it; server enforcement is a TODO.
  static Future<int> countFreeTournamentsCreatedThisWeek(String uid, {DateTime? now}) async {
    final rows = await getList('tournaments', eqCol: 'created_by', eqVal: uid);
    final weekKey = periodKeyFor(now ?? DateTime.now(), 'weekly');
    var n = 0;
    for (final r in rows) {
      // PAID creations never consume the free quota.
      if (numOf(r['entry_fee'], numOf(r['entryFee'])) > 0) continue;
      final createdMs = parseTs(r['created_at']);
      if (createdMs <= 0) continue;
      if (periodKeyFor(DateTime.fromMillisecondsSinceEpoch(createdMs), 'weekly') == weekKey) n++;
    }
    return n;
  }

  static Stream<List<Map<String, dynamic>>> streamTournaments() =>
      streamList('tournaments', orderBy: 'start_time', ascending: true).map((rows) => rows.map(normTournament).toList());

  static Future<Map<String, dynamic>> getTournament(String id) async {
    final row = await getRow('tournaments', 'id', id);
    return normTournament(row);
  }

  static Stream<Map<String, dynamic>> streamTournament(String id) =>
      streamRow('tournaments', 'id', id).map(normTournament);

  static Future<List<Map<String, dynamic>>> getRegistrations(String tournamentId) async {
    return getList('tournament_registrations', eqCol: 'tournament_id', eqVal: tournamentId);
  }

  static Stream<List<Map<String, dynamic>>> streamRegistrations(String tournamentId) =>
      streamList('tournament_registrations', eqCol: 'tournament_id', eqVal: tournamentId);

  /// Registrations of one squad (same tournament + same teamName).
  /// squad_id is stored on the registration row at join time.
  static Future<List<Map<String, dynamic>>> getSquadRegistrations(String tournamentId, String squadId) =>
      getList('tournament_registrations', eqCol: 'tournament_id', eqVal: tournamentId, eqCol2: 'squad_id', eqVal2: squadId);

  static Stream<List<Map<String, dynamic>>> streamSquadRegistrations(String tournamentId, String squadId) =>
      streamList('tournament_registrations', eqCol: 'tournament_id', eqVal: tournamentId, eqCol2: 'squad_id', eqVal2: squadId);

  static Future<List<Map<String, dynamic>>> getAllRegistrations() async {
    return getList('tournament_registrations');
  }

  static Stream<List<Map<String, dynamic>>> streamAllRegistrations() =>
      streamList('tournament_registrations');

  static Future<List<Map<String, dynamic>>> getMyRegistrations(String uid) async {
    return getList('tournament_registrations', eqCol: 'firebase_uid', eqVal: uid);
  }

  static Stream<List<Map<String, dynamic>>> streamMyRegistrations(String uid) =>
      streamList('tournament_registrations', eqCol: 'firebase_uid', eqVal: uid);

  static int slotOf(Map<String, dynamic> reg) {
    final n = intOf(reg['slot_number'], -1);
    if (n > 0) return n;
    return intOf(reg['slot'], -1);
  }

  /// P0-1 (2026-11-21, atomic join): registration rows come in TWO
  /// shapes and every player/team count MUST handle both, or spots
  /// and prize pools count wrong:
  ///   - LEGACY rows (client insert, pre-RPC): ONE row per TEAM. The
  ///     captain row carries the whole squad in `teammates`
  ///     (list of {name, uid}, length teamSize-1); it counts as
  ///     teamSize players, 1 team.
  ///   - RPC rows (register_team, 050): ONE row per MEMBER. No
  ///     `teammates` payload; each row counts as 1 player, and rows
  ///     sharing a `squad_id` are 1 team.
  /// A mixed tournament (old + new joins side by side) counts
  /// correctly under both helpers. Never use `regs.length * teamSize`
  /// for a player count or `regs.length` for a team count any more.
  static int registrationPlayerCount(List<Map<String, dynamic>> regs) {
    var n = 0;
    for (final r in regs) {
      final mates = r['teammates'];
      if (mates is List && mates.isNotEmpty) {
        n += 1 + mates.length;
      } else {
        n += 1;
      }
    }
    return n;
  }

  static int registrationTeamCount(List<Map<String, dynamic>> regs) {
    final squads = <String>{};
    var solo = 0;
    for (final r in regs) {
      final sid = strOf(r['squad_id']);
      if (sid.isNotEmpty) {
        squads.add(sid);
      } else if (strOf(r['team_name']).isNotEmpty) {
        // No stored squad_id (older row): group by tournament +
        // normalised team name — the same identity squadIdFor uses.
        squads.add(
            '${strOf(r['tournament_id'])}_${strOf(r['team_name']).toLowerCase()}');
      } else {
        solo++;
      }
    }
    return squads.length + solo;
  }

  /// Phase 2 — match-start reminders (match_reminders table, live
  /// columns: id, tournament_id, firebase_uid, remind_at,
  /// created_at). Check-before-insert: one reminder per
  /// tournament+user. The Detail page's Calendar Reminder button
  /// already inserts the same row directly; these data-layer
  /// methods are the single home for reminder reads/writes so new
  /// screens (MatchCountdownPage) go through the layer, not the
  /// client. No reminder fires by itself — the Detail page's
  /// 60-minute in-app notification is the only trigger today.
  static Future<bool> hasMatchReminder(String tournamentId, String uid) async {
    final rows = await getList('match_reminders', eqCol: 'tournament_id', eqVal: tournamentId, eqCol2: 'firebase_uid', eqVal2: uid, limit: 1);
    return rows.isNotEmpty;
  }

  static Future<void> setMatchReminder(String tournamentId, String uid) async {
    if (await hasMatchReminder(tournamentId, uid)) return;
    try {
      await client.from('match_reminders').insert({'tournament_id': tournamentId, 'firebase_uid': uid});
    } catch (_) {}
  }

  static Future<void> removeMatchReminder(String tournamentId, String uid) async {
    try {
      await client.from('match_reminders').delete().eq('tournament_id', tournamentId).eq('firebase_uid', uid);
    } catch (_) {}
  }

  /// F11 — MATCH CHECK-IN, SERVER-BACKED (Batch 3B, 2026-11-22).
  /// The platform CheckInPage used to be LOCAL STORE ONLY
  /// (CheckInService / PlatformLocalStore); it now writes the real
  /// `match_checkins` table and drives the live 050 RPCs
  /// `open_check_in` / `close_check_in`. The 050 RPCs are
  /// SECURITY DEFINER with EXECUTE granted to anon, but their admin
  /// check compares the caller-supplied p_admin_uid against
  /// admin_config — the app passes the real signed-in Firebase UID,
  /// never a hardcoded admin UID. (Until the JWT bridge lands that
  /// param is caller-supplied by design of the draft; the check
  /// still refuses non-admin UIDs.)
  /// DEDUPE: tournament-level check-in is ONE row per
  /// (tournament_id, firebase_uid) — [checkInToMatch] pre-reads
  /// before inserting and treats a unique violation as
  /// already-checked-in (re-read to confirm) instead of an error.
  /// The 050 partial unique index
  /// uq_match_checkins_tournament_captain enforces the same rule
  /// server-side when the extended columns exist.
  static Future<List<Map<String, dynamic>>> getMatchCheckins(
      String tournamentId) async {
    return getList('match_checkins',
        eqCol: 'tournament_id', eqVal: tournamentId);
  }

  static Future<bool> hasCheckedIn(String tournamentId, String uid) async {
    final rows = await getList('match_checkins',
        eqCol: 'tournament_id',
        eqVal: tournamentId,
        eqCol2: 'firebase_uid',
        eqVal2: uid,
        limit: 1);
    return rows.isNotEmpty;
  }

  /// Captain check-in for one tournament (tournament-level: no
  /// match model yet, so match_id stays NULL). Returns
  /// {'ok': bool, 'already': bool, 'error': String?}. Never throws
  /// for a duplicate — a second tap / retry after the first insert
  /// landed returns already:true. The 050-shape insert
  /// (captain_firebase_uid + status + checked_in_at) is tried
  /// first; when the live table still has the 008 shape only
  /// (missing extended columns), it retries with the minimal
  /// {tournament_id, firebase_uid, user_name} row — the shape the
  /// pro-hub CheckInPage already writes live today.
  static Future<Map<String, dynamic>> checkInToMatch({
    required String tournamentId,
    required String uid,
    String? userName,
  }) async {
    try {
      if (await hasCheckedIn(tournamentId, uid)) {
        return {'ok': true, 'already': true};
      }
      var name = (userName ?? '').trim();
      if (name.isEmpty) {
        try {
          final profile = await getProfile(uid);
          name = strOf(profile['displayName'],
              strOf(profile['display_name'], 'User'));
        } catch (_) {
          name = 'User';
        }
      }
      final nowIso = DateTime.now().toUtc().toIso8601String();
      try {
        await client.from('match_checkins').insert({
          'tournament_id': tournamentId,
          'firebase_uid': uid,
          'captain_firebase_uid': uid,
          'user_name': name,
          'status': 'checked_in',
          'checked_in_at': nowIso,
        });
      } on PostgrestException catch (e) {
        // PGRST204 (unknown column) / 42703: live table is still
        // the 008 shape — retry minimal, then re-check.
        if (e.code == 'PGRST204' || e.code == '42703') {
          await client.from('match_checkins').insert({
            'tournament_id': tournamentId,
            'firebase_uid': uid,
            'user_name': name,
          });
        } else if (e.code == '23505') {
          // Unique violation = the row landed between the pre-read
          // and the insert (double-tap / retry race).
          if (await hasCheckedIn(tournamentId, uid)) {
            return {'ok': true, 'already': true};
          }
          return {
            'ok': false,
            'error': 'Check-in save nahi hua — dobara try karen.'
          };
        } else {
          rethrow;
        }
      }
      return {'ok': true, 'already': false};
    } catch (e) {
      return {'ok': false, 'error': e.toString()};
    }
  }

  /// Unwrap an RPC RAISE's message from a PostgrestException
  /// ("PostgrestException(message: `text`, code: ...)") so the
  /// caller can show the server's own reason honestly.
  static String _unwrapRpcError(Object e) {
    final s = e.toString();
    final match = RegExp(r'message:\s*(.*?), code:').firstMatch(s);
    final msg = match?.group(1)?.trim();
    if (msg != null && msg.isNotEmpty) return msg;
    return s;
  }

  /// Open the check-in window via the live 050 `open_check_in`
  /// RPC (sets tournaments.check_in_open_at / check_in_deadline /
  /// check_in_locked + notifies confirmed captains). Admin-only
  /// server-side: [adminUid] must be the designated admin UID (or
  /// an organizer of the tournament's org); anyone else gets
  /// {'ok': false, 'error': 'not authorized to open check-in'}.
  /// [matchId] is null for tournament-level check-in (no match
  /// model yet). Returns {'ok': bool, 'error': String?,
  /// 'result': the RPC jsonb map}.
  static Future<Map<String, dynamic>> openCheckInWindow({
    required String tournamentId,
    required String adminUid,
    String? matchId,
  }) async {
    try {
      final res = await client.rpc('open_check_in', params: {
        'p_tournament_id': tournamentId,
        'p_match_id': matchId,
        'p_admin_uid': adminUid,
        'p_idempotency_key': _newUuidV4(),
      });
      return {'ok': true, 'result': asMap(res)};
    } catch (e) {
      return {'ok': false, 'error': _unwrapRpcError(e)};
    }
  }

  /// Close check-in via the live 050 `close_check_in` RPC: every
  /// confirmed registrant without a check-in row is marked absent,
  /// waitlist entries are promoted into the freed slots, and a
  /// no-show exception row (entry fee forfeit, no refund) is
  /// written per absent captain. Admin-only, same as
  /// [openCheckInWindow]. Returns {'ok': bool, 'error': String?,
  /// 'result': the RPC jsonb map}.
  static Future<Map<String, dynamic>> closeCheckInWindow({
    required String tournamentId,
    required String adminUid,
    String? matchId,
  }) async {
    try {
      final res = await client.rpc('close_check_in', params: {
        'p_tournament_id': tournamentId,
        'p_match_id': matchId,
        'p_admin_uid': adminUid,
        'p_idempotency_key': _newUuidV4(),
      });
      return {'ok': true, 'result': asMap(res)};
    } catch (e) {
      return {'ok': false, 'error': _unwrapRpcError(e)};
    }
  }

  /// Phase 2 — the registration row id for a join, used by the
  /// RegistrationSuccessPage (#24) to show the interim
  /// "AH-" + id-prefix registration number. The Phase 4 RPC will
  /// own the final format; until then the row id is the only real
  /// identifier. Returns '' when no registration exists (caller
  /// must not invent an id).
  static Future<String> getMyRegistrationId(String tournamentId, String uid) async {
    final regs = await getRegistrations(tournamentId);
    final mine = regs.where((r) => strOf(r['firebase_uid']) == uid).toList();
    if (mine.isEmpty) return '';
    return strOf(mine.first['id']);
  }

  /// P0-1 (2026-11-21, atomic join): `register_team` (050,
  /// §3.2.2) — the ONE registration RPC. Exact signature from
  /// `migrations/041-blueprint/050_registration_checkin_waitlist.DRAFT.sql`
  /// §8 — DO NOT invent args:
  ///   register_team(p_tournament_id uuid, p_captain_uid text,
  ///     p_team_id uuid, p_member_uids text[],
  ///     p_idempotency_key uuid DEFAULT NULL) → jsonb
  /// Returns {ok, registration_id (captain row uuid),
  /// registration_code ('AH-xxxxx'), waitlisted, tournament_id,
  /// member_registration_ids, fee_charged}. A server RAISE (duplicate,
  /// full, insufficient balance, roster error, ...) arrives as a
  /// PostgrestException — the message is unwrapped to the RPC's own
  /// text so the caller can show it honestly instead of raw
  /// Postgrest jargon. Throws when the RPC itself cannot be reached.
  static Future<Map<String, dynamic>> registerTeam({
    required String tournamentId,
    required String captainUid,
    String? teamId,
    required List<String> memberUids,
    required String idempotencyKey,
  }) async {
    try {
      final res = await client.rpc('register_team', params: {
        'p_tournament_id': tournamentId,
        'p_captain_uid': captainUid,
        'p_team_id': teamId,
        'p_member_uids': memberUids,
        'p_idempotency_key': idempotencyKey,
      });
      final m = asMap(res);
      if (m.isEmpty) {
        throw Exception(
            'Registration failed — server ne koi jawab nahi diya.');
      }
      return m;
    } catch (e) {
      // Unwrap the RPC's RAISE text from the PostgrestException
      // ("PostgrestException(message: <text>, code: ...)") — the
      // raise text IS the user-facing reason (e.g. 'tournament
      // full', 'duplicate registration', 'insufficient balance
      // (need Rs X)'). Anything unparseable is rethrown as-is.
      final s = e.toString();
      final match =
          RegExp(r'message:\s*(.*?), code:').firstMatch(s);
      final msg = match?.group(1)?.trim();
      if (msg != null && msg.isNotEmpty) throw Exception(msg);
      rethrow;
    }
  }

  /// P0-1: resolve a teammate's typed GAME UID to their ARENA
  /// profile (firebase_uid). The `register_team` RPC takes member
  /// FIREBASE UIDs, not game UIDs, and every roster member must have
  /// a profiles row — so a teammate with no ARENA account cannot
  /// join a team (honest error, never a guessed UID). Returns the
  /// normed profile, {} when no profile carries that game UID.
  /// Throws when MORE than one profile carries it (ambiguous — the
  /// captain must fix the UID instead of us guessing which player).
  static Future<Map<String, dynamic>> findUserByGameUid(
      String gameUid) async {
    final uid = gameUid.trim();
    if (uid.isEmpty) return {};
    final rows = await getList('profiles', eqCol: 'game_uid', eqVal: uid);
    if (rows.isEmpty) return {};
    if (rows.length > 1) {
      throw Exception(
          'Game UID $uid ek se zyada accounts par hai — teammate se sahi UID confirm karke dobara try karen.');
    }
    return normProfile(rows.first);
  }

  /// P0-1: find-or-create the `teams` row a Duo/Squad join needs.
  /// `register_team` REQUIRES p_team_id for team modes, the caller
  /// must be its captain, and every member must be a team_member —
  /// the join form has no team picker, so the join itself provisions
  /// the team from the typed team name (same columns as
  /// CommunityGroups.createSquad — FIX 12 G13 replaced the old
  /// TeamsPage _createTeam dialog with it). Returns the team id
  /// (uuid string). Throws when a
  /// DIFFERENT captain already owns a team of that exact name
  /// (squad_id is derived from the name, so two teams sharing a name
  /// would collide in every squad grouping).
  static Future<String> ensureTeamForJoin({
    required String captainUid,
    required String captainName,
    required String teamName,
  }) async {
    final name = teamName.trim();
    final mine = await getList('teams',
        eqCol: 'captain_uid', eqVal: captainUid);
    for (final row in mine) {
      if (strOf(row['name']).trim().toLowerCase() ==
          name.toLowerCase()) {
        return strOf(row['id']);
      }
    }
    final sameName =
        await getList('teams', eqCol: 'name', eqVal: name);
    if (sameName.isNotEmpty) {
      throw Exception(
          'Is naam ki team pehle se kisi aur ki hai — apni team ke liye doosra naam choose karen.');
    }
    final team = await client.from('teams').insert({
      'name': name,
      'tag': '',
      'game': '',
      'is_clan': false,
      'captain_uid': captainUid,
      'captain_name': captainName,
      'invite_code': generateReferralCode(6),
    }).select('id').single();
    return strOf((team as Map)['id']);
  }

  /// P0-1 — FREE-QUOTA COUNT (user decision 2026-11-20, migration
  /// 033 toggle): how many DISTINCT free tournaments [uid] joined in
  /// the CURRENT ISO CALENDAR WEEK (Mon-Sun) — the same week the
  /// free-CREATION quota uses ([countFreeTournamentsCreatedThisWeek]
  /// + [periodKeyFor], 'YYYY-Www'). Batch 3B (2026-11-22) aligned
  /// this join-side count from a rolling 7 days to the ISO week the
  /// brief specifies, so creation and join quotas reset on the same
  /// Monday. A join counts when the registration row's created_at
  /// falls in this ISO week AND the tournament's CURRENT entry_fee
  /// is 0 (tournament_registrations carries no fee column, so the
  /// fee is read off the tournament; entry fees do not change after
  /// creation). RPC per-member rows and legacy per-team rows both
  /// contribute exactly one count per tournament (distinct ids).
  /// A deleted tournament is skipped, never counted. Client-side
  /// count — the server RPC does not enforce the quota yet, so a
  /// second device could bypass it; the RPC-side guard is a backend
  /// follow-up, not something this client change can add. A
  /// server-side guard still needs the JWT bridge.
  static Future<int> countFreeTournamentJoinsThisWeek(String uid,
      {DateTime? now}) async {
    final weekKey = periodKeyFor(now ?? DateTime.now(), 'weekly');
    final myRegs = await getMyRegistrations(uid);
    final tournamentIds = <String>{};
    for (final r in myRegs) {
      final createdMs = parseTs(r['created_at']);
      if (createdMs <= 0) {
        continue;
      }
      if (periodKeyFor(DateTime.fromMillisecondsSinceEpoch(createdMs),
              'weekly') !=
          weekKey) continue;
      final tid = strOf(r['tournament_id']);
      if (tid.isNotEmpty) tournamentIds.add(tid);
    }
    var n = 0;
    for (final tid in tournamentIds) {
      try {
        final t = await getTournament(tid);
        if (t.isNotEmpty && numOf(t['entryFee']) <= 0) n++;
      } catch (_) {}
    }
    return n;
  }

  /// Validate-first join, routed through the atomic `register_team`
  /// RPC (050, P0-1 2026-11-21). Fee = entry_fee x teamSize.
  /// Spendable = deposit + winning only, deposit-first. Distinct
  /// errors; a legacy flag WITHOUT a registration completes with NO
  /// second fee (repair branch — legacy direct insert, the RPC has
  /// no no-fee mode). Inside the RPC, capacity check + fee debit
  /// (ONE 'entry_fee' ledger row) + registration inserts are ONE
  /// server transaction, so a failed join can no longer leave a
  /// charged-but-unregistered player. What is NOT inside that
  /// transaction (draft 050 gaps, done client-side right after):
  /// the profiles balance sync (the RPC debits the ledger only, and
  /// wallet_view reads the profile columns), the slot_number patch
  /// (the RPC takes no slot — protected by the unique slot index,
  /// with compensation on conflict), and the 10% commission row.
  /// Returns {'isRepair', 'fee', 'registrationId', 'registrationCode',
  /// 'waitlisted', 'position', 'balanceSyncFailed', 'slotPatchFailed',
  /// 'commissionOk'}.
  /// 'waitlisted' = true means the player is on the waitlist, NOT
  /// registered — the caller must not show the success page.
  static Future<Map<String, dynamic>> joinTournament({
    required String uid,
    required String tournamentId,
    required String username,
    required String gameUid,
    required String teamName,
    int? slot,
    required List<Map<String, String>> mates,
  }) async {
    final t = await getTournament(tournamentId);
    if (t.isEmpty) throw Exception('Tournament not found.');
    final profile = await getProfile(uid);
    if (profile.isEmpty) throw Exception('Profile not found. Please log in again.');
    final regs = await getRegistrations(tournamentId);
    if (regs.any((r) => strOf(r['firebase_uid']) == uid)) {
      throw Exception('You have already joined this tournament.');
    }
    final teamSize = teamSizeOf(t);
    // N-create-tournament (2026-11-20): anti-abuse — the creator can
    // NEVER join their own tournament (no free slot, no prize farming).
    if (strOf(t['created_by']).isNotEmpty && strOf(t['created_by']) == uid) {
      throw Exception('Aap ne ye tournament banaya hai — creator apne tournament mein join nahi kar sakta.');
    }
    if (strOf(t['status'], 'upcoming').toLowerCase() != 'upcoming') {
      throw Exception('Tournament registration is closed.');
    }
    // N-create-tournament: level gate + registration deadline are
    // ENFORCED here. Storing them at creation is not enough — a stored
    // limit nobody checks is a placeholder, not a feature.
    final reqLevel = intOf(t['levelRequired'], 0);
    if (reqLevel > 0 && intOf(profile['level'], 0) < reqLevel) {
      throw Exception('Is tournament ke liye level $reqLevel chahiye (aapka level ${intOf(profile['level'], 0)} hai).');
    }
    final deadlineMs = intOf(t['registrationDeadline'], 0);
    if (deadlineMs > 0 && DateTime.now().millisecondsSinceEpoch > deadlineMs) {
      throw Exception('Registration deadline guzar chuki hai.');
    }
    final maxP = intOf(t['maxPlayers'], 0);
    // Capacity counts PLAYERS (registrationPlayerCount handles the
    // legacy one-row-per-team shape and the RPC one-row-per-member
    // shape). When full AND the waitlist is on, the RPC — not this
    // client check — decides: it waitlists the team instead of
    // raising. When the waitlist is off, this is the 'full' error.
    // NOTE: the pre-check can still race (two joins in flight); the
    // RPC re-checks under the tournament row lock, so the race is
    // closed server-side — this check only fails fast.
    final waitlistOn =
        t['waitlist_enabled'] == true || t['waitlistEnabled'] == true;
    if (maxP > 0 &&
        (registrationPlayerCount(regs) + teamSize) > maxP &&
        !waitlistOn) {
      throw Exception('Tournament is full.');
    }
    if (teamSize > 1 && slot != null) {
      final taken = regs.any((r) => slotOf(r) == slot);
      if (taken) throw Exception('Slot $slot has just been taken by another team. Please select a different slot.');
    }
    // Legacy incomplete join: a joined flag carried on the profile
    // (migration column `joined_tournaments` jsonb) WITHOUT a
    // registration row. Registrations are the source of truth, so this
    // only fires when that flag exists AND no registration exists.
    var isRepair = false;
    final flagMap = asMap(profile['joined_tournaments'] ?? profile['joinedTournaments']);
    if (flagMap[tournamentId] == true) isRepair = true;

    final fee = numOf(t['entryFee']) * teamSize;
    // P0-1 — FREE-QUOTA GUARD (033 toggle, default ON): when the
    // toggle is ON and this tournament is FREE, a 2nd free join
    // in the current ISO week (Mon-Sun) is blocked. Paid joins
    // never consume the quota, and a REPAIR (completing an
    // already-started join) never counts as a new free join.
    // Toggle OFF = no quota at all. The guard runs BEFORE the RPC
    // call, so a blocked join is never charged and never
    // registered. Client-side only — a server-side guard still
    // needs the JWT bridge.
    if (!isRepair && fee <= 0 && await isFreeTournamentQuotaEnabled()) {
      final freeJoins = await countFreeTournamentJoinsThisWeek(uid);
      if (freeJoins >= 1) {
        throw Exception(
            'Free tournament quota: aap is hafte ka 1 free tournament pehle hi join kar chuke hain — agla free tournament agle hafte join kar sakte hain. Paid tournaments par koi limit nahi hai.');
      }
    }
    // Pre-flight balance check (the RPC re-checks inside its own
    // transaction and raises 'insufficient balance' — this early
    // check gives the same answer without a wasted RPC round-trip).
    if (!isRepair && fee > 0) {
      final spendable =
          numOf(profile['depositBalance']) + numOf(profile['winningCash']);
      if (spendable < fee) {
        throw Exception('Insufficient balance. Please recharge first.');
      }
    }
    final teammates = mates.map((m) => {'name': m['name'] ?? '', 'uid': m['uid'] ?? ''}).toList();
    String pName(int i) => i < teammates.length ? (teammates[i]['name'] ?? '').toString() : '';
    String pUid(int i) => i < teammates.length ? (teammates[i]['uid'] ?? '').toString() : '';
    // Slot-confirmation notification (expansion 1): in-app, always
    // works; OneSignal delivery additionally needs the App ID + REST
    // key configured in admin settings (see PushService).
    Future<void> notifySlot() async {
      try {
        await client.from('user_notifications').insert({
          'firebase_uid': uid,
          'title': 'Slot confirmed',
          'message': 'Aapka slot confirm ho gaya hai: ${strOf(t['name'], 'Tournament')}${slot != null ? ' (Slot $slot)' : ''}. Room ID/password joined players ko Tournament Detail me milega.',
        });
      } catch (_) {}
    }

    if (isRepair) {
      // REPAIR ONLY — a legacy incomplete join (flag set, no row).
      // Completes with the legacy direct insert and NO second fee:
      // the RPC has no no-fee mode, so a repair can never go
      // through register_team without charging again. New RPC joins
      // are atomic and can never produce a new repair case.
      // NOTE (FIX 10, 2026-11-21): profiles DOES have game_uid /
      // username columns (verified live 2026-11-21 — the old "NO
      // columns" claim was stale). joinTournament still deliberately
      // does NOT write them to profiles: the per-tournament game UID
      // lives on the registration row below, and Edit Profile owns
      // the profile game_uid write.
      final registration = <String, dynamic>{
        'tournament_id': tournamentId,
        'firebase_uid': uid,
        'username': username,
        'game_uid': gameUid,
        'team_name': teamName,
        'squad_id': squadIdFor(tournamentId, teamName),
        if (slot != null) 'slot_number': slot,
        if (slot != null) 'slot': slot,
        'teammates': teammates,
        'player2_username': pName(0),
        'player2_game_uid': pUid(0),
        'player3_username': pName(1),
        'player3_game_uid': pUid(1),
        'player4_username': pName(2),
        'player4_game_uid': pUid(2),
      };
      await client.from('tournament_registrations').insert(registration);
      await notifySlot();
      return {'isRepair': true, 'fee': fee};
    }

    // P0-1 — RPC ROUTE (all non-repair joins). register_team runs
    // the capacity check, the fee debit (ONE 'entry_fee' ledger row)
    // and the registration inserts in ONE server transaction under
    // the tournament row lock: a failed join leaves NO charge and
    // NO registration, and two simultaneous joins cannot both pass
    // the capacity check. The old client read-then-insert + manual
    // refund is gone.
    // (a) Roster: the RPC takes member FIREBASE UIDs, not game
    // UIDs, and every member must have a profiles row — so each
    // typed game UID is resolved to exactly one ARENA profile
    // first. A teammate with no ARENA account (or an ambiguous UID)
    // fails here with an honest message, never a guessed identity.
    final memberUids = <String>[uid];
    final memberProfiles = <Map<String, dynamic>>[profile];
    for (var i = 0; i < mates.length; i++) {
      final mateGameUid = (mates[i]['uid'] ?? '').trim();
      if (mateGameUid.isEmpty) {
        throw Exception('Enter Player ${i + 2} UID.');
      }
      final mateProfile = await findUserByGameUid(mateGameUid);
      if (mateProfile.isEmpty) {
        throw Exception(
            'Player ${i + 2} ka game UID $mateGameUid kisi ARENA profile se match nahi hua — teammate ko pehle ARENA par account banana hoga, phir dobara try karen.');
      }
      final mateUid = strOf(mateProfile['firebase_uid']);
      if (mateUid.isEmpty || memberUids.contains(mateUid)) {
        throw Exception(
            'Ek hi player UID team mein do dafa hai. Har player ek tournament mein sirf ek dafa register ho sakta hai.');
      }
      memberUids.add(mateUid);
      memberProfiles.add(mateProfile);
    }
    // (b) Team: the RPC REQUIRES p_team_id for Duo/Squad, the
    // caller must be its captain, and every member must be a
    // team_member — the join form has no team picker, so the join
    // itself provisions the team from the typed team name.
    String? teamId;
    if (teamSize > 1) {
      final captainName = strOf(profile['username'],
          strOf(profile['displayName'], strOf(profile['display_name'], 'User')));
      teamId = await ensureTeamForJoin(
          captainUid: uid, captainName: captainName, teamName: teamName);
      for (var j = 0; j < memberUids.length; j++) {
        final mUid = memberUids[j];
        final existing = await getList('team_members',
            eqCol: 'team_id',
            eqVal: teamId,
            eqCol2: 'firebase_uid',
            eqVal2: mUid,
            limit: 1);
        if (existing.isEmpty) {
          final mp = memberProfiles[j];
          await client.from('team_members').insert({
            'team_id': teamId,
            'firebase_uid': mUid,
            'user_name': strOf(mp['username'],
                strOf(mp['displayName'], strOf(mp['display_name'], 'User'))),
            'role': mUid == uid ? 'captain' : 'member',
          });
        }
      }
    }
    // (c) The atomic call. The idempotency key means a retried
    // request replays the stored result instead of charging twice.
    final rpc = await registerTeam(
      tournamentId: tournamentId,
      captainUid: uid,
      teamId: teamId,
      memberUids: memberUids,
      idempotencyKey: _newUuidV4(),
    );
    if (rpc['waitlisted'] == true) {
      // Full + waitlist on: the RPC inserted a waitlists row and
      // charged NOTHING (the fee path runs only on registration).
      // The player is NOT registered — the caller must NOT navigate
      // to the success page.
      return {
        'isRepair': false,
        'fee': 0,
        'waitlisted': true,
        'position': intOf(rpc['position']),
        'registrationId': '',
        'registrationCode': '',
      };
    }
    final captainRegId = strOf(rpc['registration_id']);
    final captainCode = strOf(rpc['registration_code']);
    final feeCharged = numOf(rpc['fee_charged'], fee);
    final memberRegIds = asList(rpc['member_registration_ids'])
        .map((e) => strOf(e))
        .where((e) => e.isNotEmpty)
        .toList();
    if (captainRegId.isEmpty) {
      throw Exception(
          'Registration ka jawab samajh nahi aaya — Tournaments se check karen ke aap registered hain ya nahi.');
    }
    // (d) FEE SYNC — the RPC debited ONLY a transactions ledger row
    // (050 J6). It never touches profiles.deposit_balance /
    // winning_cash, and wallet_view reads exactly those columns
    // (021: a plain view over profiles, NOT a ledger sum) — without
    // this sync the displayed balance would never drop and the same
    // money could be spent twice. The ledger row is the record;
    // this update syncs the app-read columns to it (deposit-first).
    // Retried once; a persistent failure is FLAGGED, never silently
    // swallowed — the join already succeeded, so failing the whole
    // call here would lie about the registration.
    var balanceSyncFailed = false;
    if (feeCharged > 0) {
      var syncDeposit = numOf(profile['depositBalance']);
      var syncWinnings = numOf(profile['winningCash']);
      if (syncDeposit >= feeCharged) {
        syncDeposit -= feeCharged;
      } else {
        syncWinnings -= (feeCharged - syncDeposit);
        syncDeposit = 0;
      }
      var synced = false;
      for (var attempt = 0; attempt < 2 && !synced; attempt++) {
        try {
          await updateProfile(uid, {
            'deposit_balance': syncDeposit,
            'winning_cash': syncWinnings,
          });
          synced = true;
        } catch (_) {
          if (attempt == 1) balanceSyncFailed = true;
        }
      }
    }
    // (e) SLOT — the RPC takes NO slot parameter and writes NO
    // slot_number, so the picked slot is recorded on the captain's
    // registration row right after the RPC (the unique partial
    // index uq_registrations_tournament_slot (020) makes this update
    // itself atomic: a second team claiming the same slot in the
    // race window gets a unique violation instead of a silent
    // double-booking). squad_id is normalised to the client's
    // squadIdFor on every member row so squad grouping reads one
    // identity (the RPC's own normalisation differs on
    // punctuation). The teammates payload keeps the captain row in
    // the legacy shape for existing readers.
    var slotPatchFailed = false;
    if (slot != null) {
      try {
        if (teamSize > 1 && memberRegIds.isNotEmpty) {
          await client
              .from('tournament_registrations')
              .update({'squad_id': squadIdFor(tournamentId, teamName)})
              .inFilter('id', memberRegIds);
        }
        await client.from('tournament_registrations').update({
          'slot_number': slot,
          'slot': slot,
          'teammates': teammates,
          'player2_username': pName(0),
          'player2_game_uid': pUid(0),
          'player3_username': pName(1),
          'player3_game_uid': pUid(1),
          'player4_username': pName(2),
          'player4_game_uid': pUid(2),
        }).eq('id', captainRegId);
      } catch (_) {
        // Slot lost in the race window (or the patch failed): undo
        // the RPC join so no team is ever registered without its
        // recorded slot and no fee is kept for it — delete the fresh
        // registration rows, refund the ledger fee and restore the
        // synced balances. If the undo itself fails, the error is
        // flagged (never a fake success) and names the registration
        // code so support can fix it instead of the user retrying
        // into a duplicate-registration dead end.
        var compensated = false;
        try {
          // Delete by the member row ids; if the RPC returned none,
          // fall back to the captain row id so the undo never
          // silently skips the delete and reports success.
          final idsToDelete = memberRegIds.isNotEmpty
              ? memberRegIds
              : [captainRegId];
          await client
              .from('tournament_registrations')
              .delete()
              .inFilter('id', idsToDelete);
          if (feeCharged > 0) {
            await recordTransaction(uid, 'entry_fee_refund', feeCharged,
                'Refund — slot $slot taken: ${strOf(t['name'], 'Tournament')}');
            await updateProfile(uid, {
              'deposit_balance': numOf(profile['depositBalance']),
              'winning_cash': numOf(profile['winningCash']),
            });
          }
          compensated = true;
        } catch (_) {}
        if (compensated) {
          throw Exception(
              'Slot $slot abhi kisi aur team ne le liya — fee wapas kar di gayi hai. Dobara slot choose kar ke try karen.');
        }
        slotPatchFailed = true;
      }
    }
    // (f) COMMISSION — the RPC writes NO platform_commission row
    // (050 has no commission step), so it is recorded here, after
    // the join stands: 10% default of the charged fee, one
    // 'platform_commission' row per paid entry, exactly as the
    // legacy path did. F29 (2026-11-22): a failed commission row
    // no longer vanishes silently — [recordPlatformCommission]
    // returns false, the failure is logged there, and the flag
    // below tells the caller to warn plainly (same pattern as
    // balanceSyncFailed/slotPatchFailed). The join itself still
    // stands — accounting must never break a completed join; the
    // approve-time catch-up reconciles a missed row.
    var commissionOk = true;
    if (feeCharged > 0) {
      commissionOk = await recordPlatformCommission(
        tournamentId: tournamentId,
        uid: uid,
        entryFee: feeCharged,
        commissionPct: numOf(t['commissionPct'], 10),
        tournamentName: strOf(t['name'], 'Tournament'),
      );
    }
    await notifySlot();
    return {
      'isRepair': false,
      'fee': feeCharged,
      'registrationId': captainRegId,
      'registrationCode': captainCode,
      'balanceSyncFailed': balanceSyncFailed,
      'slotPatchFailed': slotPatchFailed,
      'commissionOk': commissionOk,
    };
  }

  /// Best-effort per-user in-app notification (never throws).
  static Future<void> notifyUser(String uid, String title, String message) async {
    try {
      await client.from('user_notifications').insert({'firebase_uid': uid, 'title': title, 'message': message});
    } catch (_) {}
  }

  // ---------- wallet ----------
  static Future<List<Map<String, dynamic>>> getTransactions(String uid) async {
    final rows = await getList('transactions', eqCol: 'firebase_uid', eqVal: uid, orderBy: 'created_at', ascending: false, limit: 50);
    return rows.map(normTx).toList();
  }

  static Stream<List<Map<String, dynamic>>> streamTransactions(String uid) =>
      streamList('transactions', eqCol: 'firebase_uid', eqVal: uid, orderBy: 'created_at', ascending: false, limit: 50).map((rows) => rows.map(normTx).toList());

  /// Withdraw: winning_cash is deducted in the same write sequence as
  /// the request (NOT after admin approval — audit requirement). If the
  /// withdrawal insert fails, the balance is restored. Min 50 default.
  static Future<void> requestWithdrawal({required String uid, required Map<String, dynamic> profile, required double amount, required String method}) async {
    final settings = await getAppSettings();
    final minW = numOf(settings['minWithdraw'], 50);
    if (amount < minW) throw Exception('Minimum withdrawal is Rs ${minW.toStringAsFixed(2)}.');
    final winning = numOf(profile['winningCash']);
    if (amount > winning) throw Exception('Insufficient winning balance.');
    if (method.isEmpty) throw Exception('Enter your account / method.');
    await updateProfile(uid, {'winning_cash': winning - amount});
    try {
      await client.from('withdrawals').insert({
        'firebase_uid': uid,
        'user_email': strOf(profile['email']),
        'amount': amount,
        'method_name': method,
        'status': 'pending',
      });
    } catch (e) {
      try {
        await updateProfile(uid, {'winning_cash': winning});
      } catch (_) {}
      rethrow;
    }
    await recordTransaction(uid, 'withdraw_request', -amount, 'Withdrawal request ($method)');
  }

  // ---------- games / promotions / ads ----------
  static Future<List<Map<String, dynamic>>> getGames() async {
    final rows = await getList('games', orderBy: 'sort_order', ascending: true);
    rows.sort((a, b) {
      final sa = a['sort_order'];
      final sb = b['sort_order'];
      if (sa == null && sb == null) return strOf(a['name']).compareTo(strOf(b['name']));
      if (sa == null) return 1;
      if (sb == null) return -1;
      return numOf(sa).compareTo(numOf(sb));
    });
    return rows.where((g) {
      final name = strOf(g['name'], strOf(g['gameName']));
      final img = strOf(g['image_url'], strOf(g['imageUrl'], strOf(g['image'])));
      // F3 (2026-11-21 audit): honor the admin's Active toggle —
      // an inactive game must not appear anywhere user-facing. Null
      // (pre-031 rows) counts as active.
      return name.isNotEmpty && img.isNotEmpty && g['is_active'] != false;
    }).map((g) {
      final m = Map<String, dynamic>.from(g);
      m['id'] = strOf(g['id']);
      m['name'] = strOf(g['name'], strOf(g['gameName'], 'Game'));
      m['imageUrl'] = strOf(g['image_url'], strOf(g['imageUrl'], strOf(g['image'])));
      return m;
    }).toList();
  }

  /// N-create-tournament (2026-11-20): games for the Create Tournament
  /// picker. Unlike [getGames] this does NOT require an image_url — a
  /// game with no cover is still a real, selectable game. Returns every
  /// game with a non-empty name, sorted by sort_order. The `maps` key
  /// is the admin-configured map list for that game (029 draft adds
  /// games.maps); absent on pre-029 DBs, where it is simply [].
  /// NEVER invents game names: empty list = no games configured.
  /// PUBG FOCUS (user order 2026-11-20 ~11:39): PUBG Mobile is THE
  /// game — when the admin has configured a game whose name contains
  /// "pubg", it sorts FIRST (before sort_order). This only reorders
  /// real configured games; if PUBG Mobile was never configured, no
  /// fake entry is added.
  static Future<List<Map<String, dynamic>>> getGamesForPicker() async {
    final rows = await getList('games', orderBy: 'sort_order', ascending: true);
    rows.sort((a, b) {
      final sa = a['sort_order'];
      final sb = b['sort_order'];
      if (sa == null && sb == null) return strOf(a['name']).compareTo(strOf(b['name']));
      if (sa == null) return 1;
      if (sb == null) return -1;
      return numOf(sa).compareTo(numOf(sb));
    });
    // F3 (2026-11-21 audit): inactive games are excluded from the
    // picker (null = active for pre-031 rows).
    final picked = rows.where((g) => strOf(g['name'], strOf(g['gameName'])).isNotEmpty && g['is_active'] != false).map((g) {
      final m = Map<String, dynamic>.from(g);
      m['id'] = strOf(g['id']);
      m['name'] = strOf(g['name'], strOf(g['gameName'], 'Game'));
      m['imageUrl'] = strOf(g['image_url'], strOf(g['imageUrl'], strOf(g['image'])));
      m['maps'] = asList(g['maps']);
      return m;
    }).toList();
    // PUBG Mobile first (only when really configured — see above).
    picked.sort((a, b) {
      final aPubg = strOf(a['name']).toLowerCase().contains('pubg') ? 0 : 1;
      final bPubg = strOf(b['name']).toLowerCase().contains('pubg') ? 0 : 1;
      return aPubg.compareTo(bPubg);
    });
    return picked;
  }

  static Stream<List<Map<String, dynamic>>> streamGames() =>
      streamList('games', orderBy: 'sort_order', ascending: true).map((rows) {
        // Re-apply the getGames filter/sort on streamed rows.
        rows.sort((a, b) {
          final sa = a['sort_order'];
          final sb = b['sort_order'];
          if (sa == null && sb == null) return strOf(a['name']).compareTo(strOf(b['name']));
          if (sa == null) return 1;
          if (sb == null) return -1;
          return numOf(sa).compareTo(numOf(sb));
        });
        return rows.where((g) {
          final name = strOf(g['name'], strOf(g['gameName']));
          final img = strOf(g['image_url'], strOf(g['imageUrl'], strOf(g['image'])));
          // F3 (2026-11-21 audit): honor the admin's Active toggle
          // (null = active for pre-031 rows).
          return name.isNotEmpty && img.isNotEmpty && g['is_active'] != false;
        }).map((g) {
          final m = Map<String, dynamic>.from(g);
          m['id'] = strOf(g['id']);
          m['name'] = strOf(g['name'], strOf(g['gameName'], 'Game'));
          m['imageUrl'] = strOf(g['image_url'], strOf(g['imageUrl'], strOf(g['image'])));
          return m;
        }).toList();
      });

  static Future<List<Map<String, dynamic>>> getPromotions() async {
    final rows = await getList('promotions');
    // F2 (2026-11-21 audit): honor promotions.active once the backend
    // adds the column — null/missing counts as active, so today's rows
    // keep showing until the column exists.
    return rows.where((p) => p['active'] != false && strOf(p['image_url'], strOf(p['imageUrl'], strOf(p['banner'], strOf(p['image'])))).isNotEmpty).map((p) {
      final m = Map<String, dynamic>.from(p);
      m['id'] = strOf(p['id']);
      m['title'] = strOf(p['title'], 'Promotion');
      m['imageUrl'] = strOf(p['image_url'], strOf(p['imageUrl'], strOf(p['banner'], strOf(p['image']))));
      m['link'] = strOf(p['link'], strOf(p['link_url']));
      return m;
    }).toList();
  }

  static Stream<List<Map<String, dynamic>>> streamPromotions() =>
      streamList('promotions').map((rows) => rows.where((p) => p['active'] != false && strOf(p['image_url'], strOf(p['imageUrl'], strOf(p['banner'], strOf(p['image'])))).isNotEmpty).map((p) {
            final m = Map<String, dynamic>.from(p);
            m['id'] = strOf(p['id']);
            m['title'] = strOf(p['title'], 'Promotion');
            m['imageUrl'] = strOf(p['image_url'], strOf(p['imageUrl'], strOf(p['banner'], strOf(p['image']))));
            m['link'] = strOf(p['link'], strOf(p['link_url']));
            return m;
          }).toList());

  static Future<List<Map<String, dynamic>>> getAds() async {
    final rows = await getList('ads');
    return rows.where((a) => a['active'] == true).map((a) {
      final m = Map<String, dynamic>.from(a);
      m['id'] = strOf(a['id']);
      m['title'] = strOf(a['title'], 'Sponsored');
      m['imageUrl'] = strOf(a['image_url'], strOf(a['imageUrl']));
      m['targetType'] = strOf(a['target_type'], strOf(a['targetType']));
      m['targetId'] = strOf(a['target_id'], strOf(a['targetId']));
      m['targetName'] = strOf(a['target_name'], strOf(a['targetName']));
      return m;
    }).toList();
  }

  static Stream<List<Map<String, dynamic>>> streamAds() =>
      streamList('ads').map((rows) => rows.where((a) => a['active'] == true).map((a) {
            final m = Map<String, dynamic>.from(a);
            m['id'] = strOf(a['id']);
            m['title'] = strOf(a['title'], 'Sponsored');
            m['imageUrl'] = strOf(a['image_url'], strOf(a['imageUrl']));
            m['targetType'] = strOf(a['target_type'], strOf(a['targetType']));
            m['targetId'] = strOf(a['target_id'], strOf(a['targetId']));
            m['targetName'] = strOf(a['target_name'], strOf(a['targetName']));
            m['rotationInterval'] = a['rotation_interval_seconds'];
            return m;
          }).toList());

  // ---------- notifications ----------
  /// Notification-pref key for a broadcast category
  /// ('Announcement' -> 'announcements', 'Tournament' ->
  /// 'match_alerts'), or null when the category has no pref (System
  /// — always delivered). Shared by the inbox filter below and the
  /// OneSignal push filter (AdminDbCare) so both agree.
  static String? prefKeyForCategory(String category) {
    switch (category.toLowerCase()) {
      case 'announcement':
        return 'announcements';
      case 'tournament':
        return 'match_alerts';
      default:
        return null;
    }
  }

  static Future<List<Map<String, dynamic>>> getNotifications(String uid) async {
    final global = await getList('notifications', orderBy: 'created_at', ascending: false);
    final mine = await getList('user_notifications', eqCol: 'firebase_uid', eqVal: uid, orderBy: 'created_at', ascending: false);
    final all = [...global.map(normNotification), ...mine.map(normNotification)];
    all.sort((a, b) => intOf(b['timestamp']).compareTo(intOf(a['timestamp'])));
    return _applyNotificationPrefs(uid, all);
  }

  /// Notification prefs (profiles.notification_prefs): drop rows
  /// whose category/type the user turned off (audit fix 2026-11-21 —
  /// prefs were stored but never honoured). Fail-open: any prefs-read
  /// failure, or a row with no mappable category/type, keeps the row.
  /// Team invites map to 'team_invites'; ticket replies and System
  /// broadcasts have no pref key and always show.
  static Future<List<Map<String, dynamic>>> _applyNotificationPrefs(
      String uid, List<Map<String, dynamic>> rows) async {
    try {
      final prefs = await getNotificationPrefs(uid);
      if (prefs.isEmpty) return rows;
      bool off(String key) => prefs.containsKey(key) && prefs[key] == false;
      return rows.where((n) {
        final key = prefKeyForCategory(strOf(n['category']));
        if (key != null && off(key)) return false;
        if (strOf(n['type']).toLowerCase() == 'team_invite' &&
            off('team_invites')) {
          return false;
        }
        return true;
      }).toList();
    } catch (_) {
      return rows;
    }
  }

  /// BADGE FIX (2026-11-22): local "refresh the bell" signal. The badge
  /// stream recomputes on Supabase Realtime events, but DELETE events
  /// on `user_notifications` often never arrive (RLS + realtime), and
  /// hiding a global broadcast touches no table at all — so after a
  /// delete-all the badge froze until the next app restart. Any code
  /// that changes what the badge counts (delete, hide, mark-read)
  /// calls [notifyUnreadChanged] and every live badge stream
  /// recomputes at once. No backend change.
  static final StreamController<void> _unreadRefreshController = StreamController<void>.broadcast();
  static void notifyUnreadChanged() {
    if (!_unreadRefreshController.isClosed) _unreadRefreshController.add(null);
  }

  static Future<int> unreadCount(String uid) async {
    final profile = await getProfile(uid);
    final lastChecked = intOf(profile['lastCheckedNotifications'], 0);
    final all = await getNotifications(uid);
    // BADGE FIX (2026-11-22): global broadcasts are NOT deleted —
    // the Notifications page only HIDES them on this device
    // (SharedPreferences 'dismissed_global_notifs_<uid>'). The old
    // count kept counting hidden rows, so the badge showed 2/1/3
    // after a delete-all even when the list was empty. Hidden rows
    // are excluded here; a prefs-read failure falls back to counting
    // everything (old behaviour — never a crash, never a wrong 0).
    Set<String> dismissed = {};
    try {
      final prefs = await SharedPreferences.getInstance();
      dismissed = prefs.getStringList('dismissed_global_notifs_$uid')?.toSet() ?? {};
    } catch (_) {}
    return all.where((n) {
      if (intOf(n['timestamp']) <= lastChecked) return false;
      if (dismissed.isNotEmpty && strOf(n['firebase_uid']).isEmpty && dismissed.contains(strOf(n['id']))) return false;
      return true;
    }).length;
  }

  static Stream<int> streamUnreadCount(String uid) {
    // postgres_changes on both tables would need two channels; poll the
    // profile stream + notifications streams and combine. Simpler and
    // honest: stream the profile (last_checked changes on read) and
    // refetch notifications on each profile event + on a notifications
    // change event via a merged controller.
    final controller = StreamController<int>.broadcast();
    var closed = false;
    StreamSubscription? sub1;
    StreamSubscription? sub2;
    StreamSubscription? sub3;
    StreamSubscription? sub4;
    Future<void> recompute() async {
      if (closed) return;
      final c = await unreadCount(uid);
      if (!closed && !controller.isClosed) controller.add(c);
    }

    recompute();
    sub1 = streamProfile(uid).listen((_) => recompute());
    sub2 = streamList('notifications').listen((_) => recompute());
    // user_notifications-only events (team invite, single notify,
    // ticket reply) must refresh the badge too (audit fix 2026-11-21).
    sub3 = streamList('user_notifications', eqCol: 'firebase_uid', eqVal: uid).listen((_) => recompute());
    // BADGE FIX (2026-11-22): direct local refresh (delete / hide /
    // mark-read) — realtime DELETE events are unreliable, so the
    // badge also recomputes on an explicit in-app signal.
    sub4 = _unreadRefreshController.stream.listen((_) => recompute());
    controller.onCancel = () async {
      closed = true;
      await sub1?.cancel();
      await sub2?.cancel();
      await sub3?.cancel();
      await sub4?.cancel();
      await controller.close();
    };
    return controller.stream;
  }

  // ---------- team invitations (027) ----------
  // Real Accept/Decline state for Notifications (mockup #22). The
  // table + RPCs are live on production (027, 2026-11-20); staging
  // has the same schema. All identity is the caller's Firebase UID
  // (firebase_uid() inside the RPCs) — no uid parameter is ever sent,
  // and no invite is ever inserted as anyone but the signed-in user.

  /// Respond to a team invitation — DIRECT-WRITE path (2026-11-21,
  /// team-invite fix). The 027 RPC `respond_team_invite` CANNOT be
  /// called from this app: it is `GRANT EXECUTE TO authenticated`
  /// only AND derives the caller from `firebase_uid()` (auth.jwt),
  /// but the app never signs into Supabase Auth (Firebase login
  /// only, anon key only), so every app call is role `anon` with
  /// `firebase_uid()` NULL and the RPC always raises 'not
  /// authenticated' (verified in MIGRATIONS-STATUS.md: "both RPCs
  /// callable, returning 'not authenticated' without a JWT"). The
  /// old code called that RPC, so Accept could never join and
  /// Decline could never clear — even when the invitee saw the
  /// buttons. This method does the same state change with direct
  /// writes the live policies DO allow (same anon model as
  /// join-by-code, which works live):
  ///   accepted → insert the caller into `team_members`
  ///     (same row shape as TeamsPage._joinByCode) unless already
  ///     a member, then UPDATE `team_invitations` status.
  ///   declined → UPDATE `team_invitations` status only.
  /// The status UPDATE is VERIFIED by re-reading the row (RLS can
  /// silently drop an update; a silent success is never reported).
  /// The invitee's `user_notifications` row(s) for the invite are
  /// deleted best-effort; a failure there is NOT fatal — the inbox
  /// merge ([mergeInviteNotifications]) drops team_invite rows
  /// whose invite is no longer pending, so the card disappears on
  /// the next load either way. If the member insert lands but the
  /// status update fails, the invite stays pending and a retry
  /// finds `already_member` and only retries the update — the
  /// flow self-heals instead of double-joining.
  /// Returns {'ok': true, 'invite_id', 'team_id', 'status',
  /// 'already_member'} on success; {'ok': false, 'error'} on
  /// failure ('not your invite', 'already responded', 'team roster
  /// is locked'). When the JWT bridge lands, switch this back to
  /// the RPC (it is atomic; this path is validate-first + ordered
  /// writes, same as joinTournament).
  static Future<Map<String, dynamic>> respondTeamInvite(
    String inviteId,
    String response, {
    required String uid,
    String userName = 'User',
  }) async {
    if (response != 'accepted' && response != 'declined') {
      return {'ok': false, 'error': 'Invalid response.'};
    }
    if (inviteId.isEmpty || uid.isEmpty) {
      return {'ok': false, 'error': 'Invite nahi mili.'};
    }
    // TEST SEAM (FIX 6 pattern): with fixtures, run the same steps
    // against the fixture lists so widget tests can tap the REAL
    // Accept/Decline buttons end-to-end. Null fixtures = live path.
    if (testFixtures != null) {
      return _respondTeamInviteFixture(inviteId, response, uid, userName);
    }
    try {
      final invite = await getRow('team_invitations', 'id', inviteId);
      if (invite.isEmpty) {
        return {'ok': false, 'error': 'Invite nahi mili — ho sakta hai ye pehle hi respond ho chuki ho.'};
      }
      if (strOf(invite['invited_firebase_uid']) != uid) {
        return {'ok': false, 'error': 'Ye invitation aap ki nahi hai.'};
      }
      if (strOf(invite['status'], 'pending') != 'pending') {
        return {'ok': false, 'error': 'Ye invitation pehle hi respond ho chuki hai.'};
      }
      final teamId = strOf(invite['team_id']);
      var alreadyMember = false;
      if (response == 'accepted') {
        final team = await getRow('teams', 'id', teamId);
        if (team.isEmpty) {
          return {'ok': false, 'error': 'Team nahi mili.'};
        }
        if (team['roster_locked'] == true) {
          return {'ok': false, 'error': 'Is team ka roster lock hai.'};
        }
        final members = await getList('team_members', eqCol: 'team_id', eqVal: teamId, eqCol2: 'firebase_uid', eqVal2: uid, limit: 1);
        if (members.isNotEmpty) {
          alreadyMember = true;
        } else {
          await client.from('team_members').insert({
            'team_id': teamId,
            'firebase_uid': uid,
            'user_name': userName.isEmpty ? 'User' : userName,
            'role': 'member',
          });
        }
      }
      await client.from('team_invitations').update({
        'status': response,
        'responded_at': isoNow(),
      }).eq('id', inviteId);
      final after = await getRow('team_invitations', 'id', inviteId);
      if (strOf(after['status']) != response) {
        return {'ok': false, 'error': 'Invite update nahi ho saki — dobara try karein.'};
      }
      try {
        await client.from('user_notifications').delete().eq('invite_id', inviteId);
      } catch (_) {}
      return {'ok': true, 'invite_id': inviteId, 'team_id': teamId, 'status': response, 'already_member': alreadyMember};
    } catch (e) {
      return {'ok': false, 'error': inviteRespondErrorMessage(e.toString())};
    }
  }

  /// Friendly text for a [respondTeamInvite] failure (2026-11-22,
  /// user report 00:37 PKT: Accept showed the raw
  /// "PostgrestException(message: not authenticated, code: P0001...)"
  /// toast). That exact error can ONLY come from the 027 RPC
  /// `respond_team_invite` (GRANT EXECUTE TO authenticated only; it
  /// raises 'not authenticated' when firebase_uid() is NULL) — the
  /// direct-write path above never calls any RPC, so if this text
  /// ever surfaces live it means the INSTALLED build predates the
  /// direct-write fix and still calls the RPC. Say so plainly
  /// instead of dumping the raw exception.
  static String inviteRespondErrorMessage(String raw) {
    if (raw.contains('not authenticated') || raw.contains('P0001')) {
      return 'Invite accept nahi ho saki — server ne permission nahi di (not authenticated). Aap ki installed app purani build hai; R copy ki nayi build install karke dobara try karein.';
    }
    if (raw.contains('row-level security')) {
      return 'Invite respond nahi ho saki (permission).';
    }
    return raw;
  }

  /// Fixture simulation of [respondTeamInvite] (test-only, same
  /// steps and same return shape as the live path above).
  static Map<String, dynamic> _respondTeamInviteFixture(String inviteId, String response, String uid, String userName) {
    final invites = testFixtures!['team_invitations'] ?? [];
    final idx = invites.indexWhere((r) => strOf(r['id']) == inviteId);
    if (idx < 0) {
      return {'ok': false, 'error': 'Invite nahi mili — ho sakta hai ye pehle hi respond ho chuki ho.'};
    }
    final invite = invites[idx];
    if (strOf(invite['invited_firebase_uid']) != uid) {
      return {'ok': false, 'error': 'Ye invitation aap ki nahi hai.'};
    }
    if (strOf(invite['status'], 'pending') != 'pending') {
      return {'ok': false, 'error': 'Ye invitation pehle hi respond ho chuki hai.'};
    }
    final teamId = strOf(invite['team_id']);
    var alreadyMember = false;
    if (response == 'accepted') {
      final teams = testFixtures!['teams'] ?? [];
      final team = teams.where((t) => strOf(t['id']) == teamId).toList();
      if (team.isEmpty) {
        return {'ok': false, 'error': 'Team nahi mili.'};
      }
      if (team.first['roster_locked'] == true) {
        return {'ok': false, 'error': 'Is team ka roster lock hai.'};
      }
      final members = testFixtures!['team_members'] ?? [];
      alreadyMember = members.any((m) => strOf(m['team_id']) == teamId && strOf(m['firebase_uid']) == uid);
      if (!alreadyMember) {
        (testFixtures!['team_members'] ??= []).add({
          'team_id': teamId,
          'firebase_uid': uid,
          'user_name': userName.isEmpty ? 'User' : userName,
          'role': 'member',
        });
      }
    }
    invites[idx] = {...invite, 'status': response, 'responded_at': isoNow()};
    testFixtures!['user_notifications'] =
        (testFixtures!['user_notifications'] ?? []).where((n) => strOf(n['invite_id']) != inviteId).toList();
    return {'ok': true, 'invite_id': inviteId, 'team_id': teamId, 'status': response, 'already_member': alreadyMember};
  }

  /// Pending team invitations for one user, read DIRECTLY from
  /// `team_invitations` (040's permissive anon SELECT). This is the
  /// invitee's SECOND discovery path: the inbox used to be the only
  /// one (a `user_notifications` row), so a missing / swiped-away
  /// notification row left a pending invite undiscoverable forever
  /// — nothing in the app ever read this table for the invitee.
  /// THROWS on read failure (via [getListOrThrow]) so callers can
  /// tell "no invites" apart from "could not load": a failed read
  /// must never be mistaken for an empty inbox (see
  /// [mergeInviteNotifications]).
  static Future<List<Map<String, dynamic>>> getPendingTeamInvites(String uid) async {
    if (uid.isEmpty) return [];
    return getListOrThrow('team_invitations',
        eqCol: 'invited_firebase_uid', eqVal: uid, eqCol2: 'status', eqVal2: 'pending', orderBy: 'created_at', ascending: false);
  }

  /// Enrich pending invite rows with the team name + inviter name
  /// for display. Built ONLY from server rows (`teams` by id,
  /// `profiles` by firebase_uid); a missing row leaves that field
  /// empty — the UI then uses generic wording, never an invented
  /// name. Returns one map per invite: invite_id, team_id,
  /// team_name, inviter_uid, inviter_name, invited_firebase_uid,
  /// created_at (ms), status.
  static Future<List<Map<String, dynamic>>> enrichTeamInvites(List<Map<String, dynamic>> pending) async {
    final out = <Map<String, dynamic>>[];
    for (final inv in pending) {
      final teamId = strOf(inv['team_id']);
      final team = teamId.isEmpty ? <String, dynamic>{} : await getRow('teams', 'id', teamId);
      final inviterUid = strOf(inv['inviter_firebase_uid']);
      final inviter = inviterUid.isEmpty ? <String, dynamic>{} : await getRow('profiles', 'firebase_uid', inviterUid);
      out.add({
        'invite_id': strOf(inv['id']),
        'team_id': teamId,
        'team_name': strOf(team['name']),
        'inviter_uid': inviterUid,
        'inviter_name': strOf(inviter['display_name'], strOf(inviter['username'])),
        'invited_firebase_uid': strOf(inv['invited_firebase_uid']),
        'created_at': parseTs(inv['created_at']),
        'status': strOf(inv['status'], 'pending'),
      });
    }
    return out;
  }

  /// Merge the inbox list with the directly-read pending invites.
  /// Pure function (unit-tested) — no I/O.
  ///
  /// [pendingEnriched] is null when the `team_invitations` read
  /// FAILED: the list is then returned unchanged (a failed read
  /// must not hide or invent anything). When it loaded:
  ///   1. a `team_invite` notification row whose invite is NO
  ///      LONGER pending (responded elsewhere, or orphaned) is
  ///      dropped — it is a stale card with dead buttons;
  ///   2. a pending invite with NO notification row gets ONE
  ///      synthesized display card (type='team_invite', the real
  ///      invite_id/team_id, team name from the server row,
  ///      `_synthetic_invite: true`) so the invitee can still
  ///      Accept/Decline it — this is the row the sender's
  ///      notification insert was supposed to create, shown from
  ///      the invite row itself instead of being lost;
  ///   3. a pending invite that DOES have a notification row is
  ///      shown exactly once (the real row wins — never two cards
  ///      for one invite).
  /// Every other row passes through untouched, in timestamp order.
  static List<Map<String, dynamic>> mergeInviteNotifications(
    List<Map<String, dynamic>> notifications,
    List<Map<String, dynamic>>? pendingEnriched,
  ) {
    if (pendingEnriched == null) return List<Map<String, dynamic>>.from(notifications);
    final pendingIds = pendingEnriched.map((e) => strOf(e['invite_id'])).where((s) => s.isNotEmpty).toSet();
    final kept = <Map<String, dynamic>>[];
    for (final n in notifications) {
      final isInviteRow = strOf(n['type']) == 'team_invite' && strOf(n['invite_id']).isNotEmpty;
      if (isInviteRow && !pendingIds.contains(strOf(n['invite_id']))) continue; // stale — invite no longer pending.
      kept.add(Map<String, dynamic>.from(n));
    }
    final covered = kept.where((n) => strOf(n['type']) == 'team_invite').map((n) => strOf(n['invite_id'])).toSet();
    for (final e in pendingEnriched) {
      final inviteId = strOf(e['invite_id']);
      if (inviteId.isEmpty || covered.contains(inviteId)) continue;
      final teamName = strOf(e['team_name']);
      final inviterName = strOf(e['inviter_name']);
      final message = teamName.isEmpty
          ? 'A team has invited you to join their squad — Accept to join.'
          : (inviterName.isEmpty
              ? '$teamName has invited you to join their squad for the next event.'
              : '$inviterName invited you to join $teamName.');
      kept.add({
        'id': 'invite:$inviteId',
        'firebase_uid': strOf(e['invited_firebase_uid']),
        'type': 'team_invite',
        'invite_id': inviteId,
        'team_id': strOf(e['team_id']),
        'title': 'Team Invitation',
        'message': message,
        'timestamp': intOf(e['created_at']),
        '_synthetic_invite': true,
      });
    }
    kept.sort((a, b) => intOf(b['timestamp']).compareTo(intOf(a['timestamp'])));
    return kept;
  }

  /// Dismiss one notification row via RPC dismiss_notification (027).
  /// NOTE (2026-11-21, team-invite fix): this RPC is `GRANT EXECUTE
  /// TO authenticated` only and raises 'not authenticated' for the
  /// anon app (same JWT-identity reason as respond_team_invite
  /// above) — it is NOT a working path from the app. It is kept
  /// only as the last-resort fallback inside
  /// CommunityService.deleteNotification; the invite flow uses
  /// direct deletes instead. Returns {dismissed: true, id} plus
  /// 'ok': true on success; `{'ok': false, 'error': message}` on
  /// failure ('notification not found' when the row does not exist,
  /// belongs to someone else, or is a global `notifications` row).
  static Future<Map<String, dynamic>> dismissNotification(String notificationId) async {
    try {
      final res = await client.rpc('dismiss_notification', params: {'p_notification_id': notificationId});
      return {...asMap(res), 'ok': true};
    } catch (e) {
      return {'ok': false, 'error': e.toString()};
    }
  }

  /// Look up a profile by its UNIQUE username (017). Returns the
  /// profile map (firebase_uid, display_name, username, photo_url)
  /// or {} when no such username exists. Exact match, same as the
  /// Edit Profile availability check (a leading '@' is stripped).
  static Future<Map<String, dynamic>> findUserByUsername(String username) async {
    final name = username.trim().replaceFirst(RegExp(r'^@'), '');
    if (name.isEmpty) return {};
    return getRow('profiles', 'username', name);
  }

  /// Random UUID v4 (no uuid package in this project) — used for
  /// client-generated row ids so an insert never needs RETURNING.
  static String _newUuidV4() {
    final rnd = Random.secure();
    final bytes = List<int>.generate(16, (_) => rnd.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  /// Send a team invitation (027): inserts the team_invitations row
  /// (as the signed-in inviter — RLS rejects anyone else) + the
  /// invitee's user_notifications row (type='team_invite') + a
  /// best-effort OneSignal push with the real invite (see
  /// [sendTeamInvitePush] — a push failure never fails the invite).
  /// Returns {'ok': true, 'invite_id': id, 'push': {...}} on success;
  /// {'ok': false, 'error': message} on failure. A duplicate pending
  /// invite is rejected by the DB unique index (friendly message,
  /// never a crash); an RLS rejection means the inviter is not a
  /// captain or member. If the notification insert fails after the
  /// invite row is created, the invite row is removed again so no
  /// notification-less invite is left behind.
  static Future<Map<String, dynamic>> sendTeamInvite({
    required String teamId,
    required String teamName,
    required String invitedUid,
    required String inviterUid,
    String? inviteCode,
    String inviterName = '',
  }) async {
    try {
      // TEST SEAM (FIX 6 pattern): with fixtures, write the same two
      // rows into the fixture lists so tests can run the full
      // send → inbox → Accept chain with no network.
      if (testFixtures != null) {
        final invites = testFixtures!['team_invitations'] ?? [];
        final dup = invites.any((r) =>
            strOf(r['team_id']) == teamId &&
            strOf(r['invited_firebase_uid']) == invitedUid &&
            strOf(r['status'], 'pending') == 'pending');
        if (dup) {
          return {'ok': false, 'error': 'Is player ko is team ki invite pehle se pending hai.'};
        }
        final fixtureInviteId = _newUuidV4();
        (testFixtures!['team_invitations'] ??= []).add({
          'id': fixtureInviteId,
          'team_id': teamId,
          'invited_firebase_uid': invitedUid,
          'inviter_firebase_uid': inviterUid,
          if (inviteCode != null && inviteCode.isNotEmpty) 'invite_code': inviteCode,
          'status': 'pending',
          'created_at': isoNow(),
        });
        (testFixtures!['user_notifications'] ??= []).add({
          'id': _newUuidV4(),
          'firebase_uid': invitedUid,
          'type': 'team_invite',
          'invite_id': fixtureInviteId,
          'team_id': teamId,
          'title': 'Team Invitation',
          'message': '$teamName has invited you to join their squad for the next event.',
          'created_at': isoNow(),
        });
        final push = await sendTeamInvitePush(invitedUid: invitedUid, teamName: teamName, inviterName: inviterName);
        return {'ok': true, 'invite_id': fixtureInviteId, 'push': push};
      }
      // Client-generated id: the insert carries its own UUID and does
      // NOT ask for RETURNING, so it no longer depends on the
      // team_invitations SELECT policy (040) — the invite works even
      // when that policy is missing (audit fix 2026-11-21).
      final inviteId = _newUuidV4();
      await client.from('team_invitations').insert({
        'id': inviteId,
        'team_id': teamId,
        'invited_firebase_uid': invitedUid,
        'inviter_firebase_uid': inviterUid,
        if (inviteCode != null && inviteCode.isNotEmpty) 'invite_code': inviteCode,
      });
      try {
        await client.from('user_notifications').insert({
          'firebase_uid': invitedUid,
          'type': 'team_invite',
          'invite_id': inviteId,
          'team_id': teamId,
          'title': 'Team Invitation',
          'message': '$teamName has invited you to join their squad for the next event.',
        });
      } catch (e) {
        // Compensation: no notification-less invite.
        try {
          await client.from('team_invitations').delete().eq('id', inviteId);
        } catch (_) {}
        return {'ok': false, 'error': e.toString()};
      }
      // 2026-11-21 NOTIFICATIONS REDESIGN: the invitee ALSO gets a
      // OneSignal push with the real invite. Best-effort only — a
      // push failure (unconfigured OneSignal, no player id yet,
      // network error) never fails the invite itself; the in-app
      // row + the inbox merge already cover the Notifications page.
      Map<String, dynamic> push = const {};
      try {
        push = await sendTeamInvitePush(invitedUid: invitedUid, teamName: teamName, inviterName: inviterName);
      } catch (_) {}
      return {'ok': true, 'invite_id': inviteId, 'push': push};
    } catch (e) {
      final msg = e.toString();
      if (msg.contains('uq_team_invitations_pending') || msg.contains('duplicate key')) {
        return {'ok': false, 'error': 'Is player ko is team ki invite pehle se pending hai.'};
      }
      if (msg.contains('row-level security')) {
        return {'ok': false, 'error': 'Sirf team captain ya member invite kar sakta hai.'};
      }
      return {'ok': false, 'error': msg};
    }
  }

  /// Last team-invite push attempt (payload only — NO keys): set on
  /// every [sendTeamInvitePush] call, live and fixture alike, so
  /// tests can assert the REAL team name + invitee targeting
  /// without any network. Null until the first attempt.
  static Map<String, dynamic>? lastInvitePushAttempt;

  /// OneSignal push for a team invitation (2026-11-21, Notifications
  /// redesign — the invitee must ALSO get a push, not just the
  /// in-app row). Same REST pattern as AdminDbCare._sendOneSignalPush
  /// (broadcasts): App ID + REST key ONLY from app_settings.onesignal
  /// at send time, NEVER hardcoded; target = the invitee's
  /// profiles.onesignal_id (PushService syncs it when they open the
  /// app); a user who muted 'team_invites' gets no push (same mapping
  /// as the inbox filter). Best-effort by design: returns
  /// {'ok', 'configured', 'devices', 'error'} and NEVER throws —
  /// [sendTeamInvite] calls it after both rows land and never fails
  /// the invite over a push problem (unconfigured OneSignal, no
  /// player id yet, network error). The push carries the REAL team
  /// name (+ inviter name when known) — never mock copy.
  static Future<Map<String, dynamic>> sendTeamInvitePush({
    required String invitedUid,
    required String teamName,
    String inviterName = '',
  }) async {
    final title = 'Team Invitation';
    final message = inviterName.isEmpty
        ? '$teamName has invited you to join their squad for the next event.'
        : '$inviterName invited you to join $teamName.';
    lastInvitePushAttempt = {
      'invited_uid': invitedUid,
      'title': title,
      'message': message,
    };
    if (testFixtures != null) {
      // No network in tests — the attempt above is the assertion
      // surface; the invite rows themselves are already written.
      return {'ok': false, 'configured': false, 'devices': 0, 'error': 'test mode — no push sent'};
    }
    try {
      // Muted team_invites => no push (the inbox card still shows —
      // the merge re-surfaces pending invites by design).
      final prefs = await getNotificationPrefs(invitedUid);
      if (prefs.containsKey('team_invites') && prefs['team_invites'] == false) {
        return {'ok': false, 'configured': true, 'devices': 0, 'error': 'Invitee muted team invites.'};
      }
      final settings = await getAppSettings();
      final one = asMap(settings['onesignal']);
      final appId = strOf(one['appId'], strOf(one['app_id'], strOf(settings['onesignal_app_id'])));
      final restKey = strOf(one['restApiKey'], strOf(one['rest_api_key'], strOf(settings['onesignal_rest_api_key'])));
      if (appId.isEmpty || restKey.isEmpty) {
        return {'ok': false, 'configured': false, 'devices': 0, 'error': 'OneSignal is not configured (App ID / REST key missing in app_settings → onesignal).'};
      }
      final profiles = await getProfilesMap([invitedUid]);
      final pid = strOf(profiles[invitedUid]?['onesignal_id'], strOf(profiles[invitedUid]?['onesignalId']));
      if (pid.isEmpty) {
        return {'ok': false, 'configured': true, 'devices': 0, 'error': 'Invitee has no OneSignal player ID yet (app not opened since push setup).'};
      }
      final resp = await http
          .post(
            Uri.parse('https://api.onesignal.com/notifications'),
            headers: {'Content-Type': 'application/json; charset=utf-8', 'Authorization': 'Basic $restKey'},
            body: jsonEncode({
              'app_id': appId,
              'headings': {'en': title},
              'contents': {'en': message},
              'include_player_ids': [pid],
            }),
          )
          .timeout(const Duration(seconds: 20));
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        return {'ok': false, 'configured': true, 'devices': 0, 'error': 'OneSignal rejected the send (HTTP ${resp.statusCode}).'};
      }
      return {'ok': true, 'configured': true, 'devices': 1, 'error': ''};
    } catch (e) {
      return {'ok': false, 'configured': false, 'devices': 0, 'error': e.toString()};
    }
  }

  /// Send a COMMUNITY invitation (PHASE E E30, 2026-11-24).
  ///
  /// NOT a team invite: there is no `community_invitations` table
  /// and no backend invite flow — the invite IS the notification
  /// row itself (type='community_invite' + community_id +
  /// inviter), rendered by the Notifications page with Join /
  /// Decline. Join runs [CommunityGroups.respondCommunityInvite]
  /// (followCommunity + delete the row); Decline just deletes it.
  /// No new table, no RPC, no backend work — everything app-side.
  ///
  /// Guards (all client-side, same as the team flow's spirit):
  /// no self-invite, no invite to someone already a member, no
  /// duplicate pending invite for the same community + invitee.
  /// Returns {'ok': true, 'notification_id': id, 'push': {...}}
  /// on success; {'ok': false, 'error': message} on failure.
  /// A best-effort OneSignal push follows (see
  /// [sendCommunityInvitePush] — a push failure never fails the
  /// invite).
  static Future<Map<String, dynamic>> sendCommunityInvite({
    required String communityId,
    required String communityName,
    required String invitedUid,
    required String inviterUid,
    String inviterName = '',
  }) async {
    if (communityId.isEmpty || invitedUid.isEmpty || inviterUid.isEmpty) {
      return {'ok': false, 'error': 'Invite ke liye zaroori maloomat missing hai.'};
    }
    if (invitedUid == inviterUid) {
      return {'ok': false, 'error': 'Khud ko invite nahi kar sakte.'};
    }
    final message = inviterName.isEmpty
        ? '$communityName has invited you to join their community.'
        : '$inviterName invited you to join $communityName.';
    try {
      // TEST SEAM (FIX 6 pattern): with fixtures, run the same
      // guards + write the notification row into the fixture
      // list so tests can run the full send -> inbox -> Join
      // chain with no network.
      if (testFixtures != null) {
        final members = testFixtures!['community_members'] ?? [];
        final alreadyMember = members.any((r) =>
            strOf(r['community_id']) == communityId &&
            strOf(r['firebase_uid']) == invitedUid);
        if (alreadyMember) {
          return {'ok': false, 'error': 'Ye player pehle se is community ka member hai.'};
        }
        final notifs = testFixtures!['user_notifications'] ?? [];
        final dup = notifs.any((r) =>
            strOf(r['type']) == 'community_invite' &&
            strOf(r['community_id']) == communityId &&
            strOf(r['firebase_uid']) == invitedUid);
        if (dup) {
          return {'ok': false, 'error': 'Is player ko is community ki invite pehle se pending hai.'};
        }
        final fixtureNotifId = _newUuidV4();
        (testFixtures!['user_notifications'] ??= []).add({
          'id': fixtureNotifId,
          'firebase_uid': invitedUid,
          'type': 'community_invite',
          'community_id': communityId,
          'community_name': communityName,
          'inviter_uid': inviterUid,
          'inviter_name': inviterName,
          'title': 'Community Invitation',
          'message': message,
          'created_at': isoNow(),
        });
        final push = await sendCommunityInvitePush(
            invitedUid: invitedUid,
            communityName: communityName,
            inviterName: inviterName);
        return {'ok': true, 'notification_id': fixtureNotifId, 'push': push};
      }
      // Already a member? (The picker hides members, but the
      // service enforces it too — never trust the UI alone.)
      final members = await getList('community_members',
          eqCol: 'community_id',
          eqVal: communityId,
          eqCol2: 'firebase_uid',
          eqVal2: invitedUid);
      if (members.isNotEmpty) {
        return {'ok': false, 'error': 'Ye player pehle se is community ka member hai.'};
      }
      // Duplicate pending invite?
      final existing = await getList('user_notifications',
          eqCol: 'type',
          eqVal: 'community_invite',
          eqCol2: 'firebase_uid',
          eqVal2: invitedUid);
      if (existing.any((r) => strOf(r['community_id']) == communityId)) {
        return {'ok': false, 'error': 'Is player ko is community ki invite pehle se pending hai.'};
      }
      // Client-generated id: the insert carries its own UUID and
      // does NOT ask for RETURNING (same audit fix as the team
      // invite — no dependency on a SELECT policy).
      final notificationId = _newUuidV4();
      await client.from('user_notifications').insert({
        'id': notificationId,
        'firebase_uid': invitedUid,
        'type': 'community_invite',
        'community_id': communityId,
        'community_name': communityName,
        'inviter_uid': inviterUid,
        'inviter_name': inviterName,
        'title': 'Community Invitation',
        'message': message,
      });
      // Best-effort push — never fails the invite.
      Map<String, dynamic> push = const {};
      try {
        push = await sendCommunityInvitePush(
            invitedUid: invitedUid,
            communityName: communityName,
            inviterName: inviterName);
      } catch (_) {}
      return {'ok': true, 'notification_id': notificationId, 'push': push};
    } catch (e) {
      final msg = e.toString();
      if (msg.contains('row-level security')) {
        return {'ok': false, 'error': 'Invite bhejna mumkin nahi — permission issue.'};
      }
      return {'ok': false, 'error': msg};
    }
  }

  /// Last community-invite push attempt (payload only — NO keys):
  /// same test surface as [lastInvitePushAttempt].
  static Map<String, dynamic>? lastCommunityInvitePushAttempt;

  /// OneSignal push for a community invitation (PHASE E E30).
  /// Same REST pattern as [sendTeamInvitePush] (App ID + REST key
  /// ONLY from app_settings.onesignal at send time, NEVER
  /// hardcoded; target = the invitee's profiles.onesignal_id; a
  /// user who muted 'community' gets no push). Best-effort by
  /// design: returns {'ok', 'configured', 'devices', 'error'} and
  /// NEVER throws.
  static Future<Map<String, dynamic>> sendCommunityInvitePush({
    required String invitedUid,
    required String communityName,
    String inviterName = '',
  }) async {
    final title = 'Community Invitation';
    final message = inviterName.isEmpty
        ? '$communityName has invited you to join their community.'
        : '$inviterName invited you to join $communityName.';
    lastCommunityInvitePushAttempt = {
      'invited_uid': invitedUid,
      'title': title,
      'message': message,
    };
    if (testFixtures != null) {
      // No network in tests — the attempt above is the assertion
      // surface; the notification row is already written.
      return {'ok': false, 'configured': false, 'devices': 0, 'error': 'test mode — no push sent'};
    }
    try {
      // Muted community alerts => no push (the inbox card still
      // shows — the invite lives in user_notifications).
      final prefs = await getNotificationPrefs(invitedUid);
      if (prefs.containsKey('community') && prefs['community'] == false) {
        return {'ok': false, 'configured': true, 'devices': 0, 'error': 'Invitee muted community alerts.'};
      }
      final settings = await getAppSettings();
      final one = asMap(settings['onesignal']);
      final appId = strOf(one['appId'], strOf(one['app_id'], strOf(settings['onesignal_app_id'])));
      final restKey = strOf(one['restApiKey'], strOf(one['rest_api_key'], strOf(settings['onesignal_rest_api_key'])));
      if (appId.isEmpty || restKey.isEmpty) {
        return {'ok': false, 'configured': false, 'devices': 0, 'error': 'OneSignal is not configured (App ID / REST key missing in app_settings → onesignal).'};
      }
      final profiles = await getProfilesMap([invitedUid]);
      final pid = strOf(profiles[invitedUid]?['onesignal_id'], strOf(profiles[invitedUid]?['onesignalId']));
      if (pid.isEmpty) {
        return {'ok': false, 'configured': true, 'devices': 0, 'error': 'Invitee has no OneSignal player ID yet (app not opened since push setup).'};
      }
      final resp = await http
          .post(
            Uri.parse('https://api.onesignal.com/notifications'),
            headers: {'Content-Type': 'application/json; charset=utf-8', 'Authorization': 'Basic $restKey'},
            body: jsonEncode({
              'app_id': appId,
              'headings': {'en': title},
              'contents': {'en': message},
              'include_player_ids': [pid],
            }),
          )
          .timeout(const Duration(seconds: 20));
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        return {'ok': false, 'configured': true, 'devices': 0, 'error': 'OneSignal rejected the send (HTTP ${resp.statusCode}).'};
      }
      return {'ok': true, 'configured': true, 'devices': 1, 'error': ''};
    } catch (e) {
      return {'ok': false, 'configured': false, 'devices': 0, 'error': e.toString()};
    }
  }

  // ---------- chat ----------
  // Schema contract (001_init): chat_messages has NO `scope_id` column.
  // Tournament scope: tournament_id = scopeId, squad_id = null.
  // Squad scope: squad_id = scopeId; tournament_id is derived from the
  // squadId prefix (squadId = "<tournamentId>_<teamNorm>", and uuids
  // contain no underscore, so the first '_' is the split point). The
  // derived tournament_id keeps admin chats/{tournamentId} reads working
  // and lets squad rows stay queryable by tournament.
  static String _chatTournamentId(String scope, String scopeId) {
    if (scope == 'squad') {
      final i = scopeId.indexOf('_');
      return i > 0 ? scopeId.substring(0, i) : scopeId;
    }
    return scopeId;
  }

  static Future<List<Map<String, dynamic>>> getChat(String scope, String scopeId) async {
    if (scope == 'squad') {
      final rows = await getList('chat_messages', eqCol: 'scope', eqVal: 'squad', eqCol2: 'squad_id', eqVal2: scopeId, orderBy: 'created_at', ascending: true, limit: 200);
      return rows.map(normChat).where((m) => m['deleted_at'] == null).toList();
    }
    // Watch Live comments (2026-11-21): their own scope on the same
    // chat_messages table — scope 'watch_live', tournament_id =
    // scopeId — so stream comments never mix into the room /
    // tournament chat. Same columns, same RLS shape as 'tournament'.
    if (scope == 'watch_live') {
      final rows = await getList('chat_messages', eqCol: 'scope', eqVal: 'watch_live', eqCol2: 'tournament_id', eqVal2: scopeId, orderBy: 'created_at', ascending: true, limit: 200);
      return rows.map(normChat).where((m) => m['deleted_at'] == null).toList();
    }
    // Community (FIX 12 G6 — the community voice room's music rows
    // live on the same scope as community chat: scope 'community',
    // community_id = scopeId, tournament_id null — the
    // sendCommunityChatMessage shape, so the room's MUSIC:: rows
    // and the chat tab's messages share one filter).
    if (scope == 'community') {
      final rows = await getList('chat_messages', eqCol: 'scope', eqVal: 'community', eqCol2: 'community_id', eqVal2: scopeId, orderBy: 'created_at', ascending: true, limit: 200);
      return rows.map(normChat).where((m) => m['deleted_at'] == null).toList();
    }
    final rows = await getList('chat_messages', eqCol: 'scope', eqVal: 'tournament', eqCol2: 'tournament_id', eqVal2: scopeId, orderBy: 'created_at', ascending: true, limit: 200);
    return rows.map(normChat).where((m) => m['deleted_at'] == null).toList();
  }

  static Stream<List<Map<String, dynamic>>> streamChat(String scope, String scopeId) {
    if (scope == 'squad') {
      return streamList('chat_messages', eqCol: 'scope', eqVal: 'squad', eqCol2: 'squad_id', eqVal2: scopeId, orderBy: 'created_at', ascending: true, limit: 200, pollInterval: const Duration(seconds: 3))
          .map((rows) => rows.map(normChat).where((m) => m['deleted_at'] == null).toList());
    }
    // Team (squad) chat — scope 'team', squad_id 'team_<id>' (the
    // TeamChatPage team-mode write shape). streamChat previously had
    // no 'team' branch, so team mode fell through to the tournament
    // filter and could never go realtime (P1-7).
    if (scope == 'team') {
      return streamList('chat_messages', eqCol: 'scope', eqVal: 'team', eqCol2: 'squad_id', eqVal2: scopeId, orderBy: 'created_at', ascending: true, limit: 200, pollInterval: const Duration(seconds: 3))
          .map((rows) => rows.map(normChat).where((m) => m['deleted_at'] == null).toList());
    }
    if (scope == 'watch_live') {
      return streamList('chat_messages', eqCol: 'scope', eqVal: 'watch_live', eqCol2: 'tournament_id', eqVal2: scopeId, orderBy: 'created_at', ascending: true, limit: 200, pollInterval: const Duration(seconds: 3))
          .map((rows) => rows.map(normChat).where((m) => m['deleted_at'] == null).toList());
    }
    // Community (FIX 12 G6 — the community voice room's MUSIC::
    // rows: same filter as community chat, 3s poll like every
    // other branch — without it the room's music stream never
    // refreshes on A1, which has no Realtime).
    if (scope == 'community') {
      return streamList('chat_messages', eqCol: 'scope', eqVal: 'community', eqCol2: 'community_id', eqVal2: scopeId, orderBy: 'created_at', ascending: true, limit: 200, pollInterval: const Duration(seconds: 3))
          .map((rows) => rows.map(normChat).where((m) => m['deleted_at'] == null).toList());
    }
    return streamList('chat_messages', eqCol: 'scope', eqVal: 'tournament', eqCol2: 'tournament_id', eqVal2: scopeId, orderBy: 'created_at', ascending: true, limit: 200, pollInterval: const Duration(seconds: 3))
        .map((rows) => rows.map(normChat).where((m) => m['deleted_at'] == null).toList());
  }

  /// Is [uid] chat-restricted by an admin (a chat_restrictions row
  /// exists for them)? Fail-open: any read error (e.g. pre-032 DB)
  /// means "not restricted". Send sites check this and refuse with a
  /// clear message; the restriction itself is set from Chat
  /// Moderation (AdminDbCare.restrictChatUser).
  static Future<bool> isChatRestricted(String uid) async {
    if (uid.isEmpty) return false;
    try {
      final rows = await getList('chat_restrictions', eqCol: 'firebase_uid', eqVal: uid, limit: 1);
      return rows.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// FIX 15 (v2016, backend guide §9.1) — is [uid] chat-restricted
  /// inside community [communityId]? A user is restricted in a
  /// community when EITHER a GLOBAL row exists (community_id NULL —
  /// an app-admin action, applies everywhere) OR a SCOPED row
  /// exists for that community (an organizer action). A scoped row
  /// for community A never restricts the user in community B.
  /// Fail-open like [isChatRestricted]: any read error (e.g. the
  /// community_id column not live yet) means "not restricted".
  /// Pre-§9.1 rows have no community_id key at all — strOf(null)
  /// is '' so they read as global, exactly as before.
  static Future<bool> isChatRestrictedInCommunity(
      String uid, String communityId) async {
    if (uid.isEmpty || communityId.isEmpty) return false;
    try {
      final rows = await getList('chat_restrictions',
          eqCol: 'firebase_uid', eqVal: uid, limit: 50);
      return isRestrictedInCommunityRows(rows, communityId);
    } catch (_) {
      return false;
    }
  }

  /// Pure core of [isChatRestrictedInCommunity] (unit-testable):
  /// true when any restriction row is global (null/empty
  /// community_id) or scoped to [communityId].
  static bool isRestrictedInCommunityRows(
      List<Map<String, dynamic>> rows, String communityId) {
    for (final r in rows) {
      final cid = strOf(r['community_id']);
      if (cid.isEmpty || cid == communityId) return true;
    }
    return false;
  }

  /// FIX 15 — insert a chat_restrictions row. Live: direct insert
  /// (same shape as AdminDbCare.restrictChatUser, plus the §9.1
  /// community_id when set). Tests: mutates the in-memory fixture
  /// list (same pattern as toggleWatchLiveLike). Throws on live
  /// failure — callers catch (e.g. the missing-column case, which
  /// means the §9.1 backend change is still pending).
  static Future<void> insertChatRestriction({
    required String uid,
    required String reason,
    String? communityId,
  }) async {
    if (uid.isEmpty) return;
    if (testFixtures != null) {
      final list = testFixtures!.putIfAbsent(
          'chat_restrictions', () => <Map<String, dynamic>>[]);
      list.add({
        'firebase_uid': uid,
        'reason': reason,
        if (communityId != null) 'community_id': communityId,
      });
      return;
    }
    await client.from('chat_restrictions').insert({
      'firebase_uid': uid,
      'reason': reason,
      if (communityId != null) 'community_id': communityId,
    });
  }

  /// FIX 15 — delete the community-scoped chat_restrictions row
  /// for [uid] in [communityId]. Only the scoped row is touched —
  /// a global admin row for the same user is never deleted here
  /// (the organizer cannot lift an admin's block). Throws on live
  /// failure — callers catch; fixture mode mutates the list.
  static Future<void> deleteScopedChatRestriction({
    required String uid,
    required String communityId,
  }) async {
    if (uid.isEmpty || communityId.isEmpty) return;
    if (testFixtures != null) {
      final list = testFixtures!['chat_restrictions'];
      list?.removeWhere((r) =>
          strOf(r['firebase_uid']) == uid &&
          strOf(r['community_id']) == communityId);
      return;
    }
    await client
        .from('chat_restrictions')
        .delete()
        .eq('firebase_uid', uid)
        .eq('community_id', communityId);
  }

  /// FIX 15 — delete chat_messages rows by id (the room _clearChat
  /// path, shared for the community clear). Throws on live failure
  /// — callers catch; fixture mode mutates the list.
  static Future<void> deleteChatMessagesByIds(List<String> ids) async {
    if (ids.isEmpty) return;
    if (testFixtures != null) {
      final list = testFixtures!['chat_messages'];
      list?.removeWhere((r) => ids.contains(strOf(r['id'])));
      return;
    }
    await client.from('chat_messages').delete().inFilter('id', ids);
  }

  static Future<void> sendChat({required String scope, required String scopeId, required String uid, required String displayName, required String message, dynamic replyTo, bool isAdmin = false, String imageUrl = ''}) async {
    // chat_messages has no is_admin column; the flag is accepted for
    // call-site compatibility but not persisted.
    // [imageUrl] (P1-7 photo share): chat_messages.image_url
    // (migration 068) — same column the DM photo path writes.
    // Team scope (P1-7): same row shape as the TeamChatPage team-mode
    // direct insert — tournament_id '' + squad_id 'team_<id>' — so
    // sendChat is now usable for team chat too (before this, a 'team'
    // scope would have stored the squad id as tournament_id).
    // Community scope (FIX 12 G6): the sendCommunityChatMessage
    // shape — tournament_id null + community_id — so the room's
    // MUSIC:: rows land on the same filter as community chat
    // (proven 201 shape; never write the community id into
    // tournament_id — _chatTournamentId would do exactly that).
    await client.from('chat_messages').insert({
      'tournament_id': scope == 'team' ? '' : scope == 'community' ? null : _chatTournamentId(scope, scopeId),
      'scope': scope,
      if (scope == 'squad' || scope == 'team') 'squad_id': scopeId,
      if (scope == 'community') 'community_id': scopeId,
      'firebase_uid': uid,
      'display_name': displayName,
      'sender': displayName,
      'message': message,
      if (imageUrl.isNotEmpty) 'image_url': imageUrl,
      if (replyTo != null) 'reply_to': replyTo,
    });
  }

  /// The caller's first team (by membership row) — for chat invite
  /// entry points that have no team in scope (community chat, P1-8).
  /// Returns the `teams` row or {} when the user has no team.
  static Future<Map<String, dynamic>> getMyFirstTeam(String uid) async {
    if (uid.isEmpty) return {};
    try {
      final members = await getList('team_members', eqCol: 'firebase_uid', eqVal: uid, orderBy: 'created_at', ascending: true, limit: 1);
      if (members.isEmpty) return {};
      final teamId = strOf(members.first['team_id']);
      if (teamId.isEmpty) return {};
      return await getRow('teams', 'id', teamId);
    } catch (_) {
      return {};
    }
  }

  /// Report a chat message (Phase 4 cleanup — was an inline insert in
  /// room_screen._reportChatMessage; the write shape is identical).
  /// The reason carries the message id + excerpt; status 'open'.
  static Future<void> reportChatMessage({
    String? tournamentId,
    required String raisedBy,
    required String raisedByName,
    required String againstUid,
    required String reason,
  }) async {
    await client.from('disputes').insert({
      // DM / team-chat reports have no tournament — omit the key
      // instead of sending '' (audit fix 2026-11-21). The admin
      // Chat Reports queue matches on the reason prefix, not the id.
      if (tournamentId != null && tournamentId.isNotEmpty)
        'tournament_id': tournamentId,
      'raised_by': raisedBy,
      'raised_by_name': raisedByName,
      'against_uid': againstUid,
      'reason': reason,
      'status': 'open',
    });
  }

  // ---------- match history / results / support / deposits ----------
  static Future<List<Map<String, dynamic>>> getMatchHistory(String uid) async {
    final rows = await getList('match_history', eqCol: 'firebase_uid', eqVal: uid, orderBy: 'played_at', ascending: false);
    return rows.map(normMatchHistory).toList();
  }

  static Stream<List<Map<String, dynamic>>> streamMatchHistory(String uid) =>
      streamList('match_history', eqCol: 'firebase_uid', eqVal: uid, orderBy: 'played_at', ascending: false).map((rows) => rows.map(normMatchHistory).toList());

  static Future<List<Map<String, dynamic>>> getLeaderboard() async {
    // Order by leaderboard_rank asc, rank not null, limit 100 — NOT
    // totalEarnings sort (audit fix).
    try {
      final rows = await client.from('profiles').select().not('leaderboard_rank', 'is', null).order('leaderboard_rank', ascending: true).limit(100);
      return (rows as List).map((r) => normProfile(Map<String, dynamic>.from(r as Map))).toList();
    } catch (_) {
      return [];
    }
  }

  /// N-create-tournament AUTOMATION (2026-11-20): the live result
  /// path. The `record_match_result` RPC is tried FIRST by the submit
  /// screen; when it is unavailable, THIS upsert is the fallback — and
  /// it now saves the FULL stats (placement/kills/assists/damage/
  /// duration/notes), not just the screenshot, so the admin approval
  /// automation below can compute winnings from real data. One row per
  /// (tournament, player) — the UNIQUE constraint blocks duplicates.
  static Future<void> submitResult(String tournamentId, String uid, String imageUrl,
      {int? placement, int? kills, int? assists, int? damage, int? durationSeconds, String? notes}) async {
    // A re-submit after a rejection is marked 're-submitted' so
    // the admin queue can tell it apart from a first submission
    // (the status existed in the pending predicate but no code
    // ever wrote it). The read failing is not fatal — the row
    // just goes in as a plain 'submitted'.
    String status = 'submitted';
    try {
      final existing = await getMyResult(tournamentId, uid);
      if (strOf(existing['status']).toLowerCase() == 'rejected') {
        status = 're-submitted';
      }
    } catch (_) {}
    await client.from('tournament_results').upsert({
      'tournament_id': tournamentId,
      'firebase_uid': uid,
      'image_url': imageUrl,
      'status': status,
      if (placement != null) 'placement': placement,
      if (kills != null) 'kills': kills,
      if (assists != null) 'assists': assists,
      if (damage != null) 'damage': damage,
      if (durationSeconds != null) 'duration_seconds': durationSeconds,
      if (notes != null && notes.isNotEmpty) 'notes': notes,
    }, onConflict: 'tournament_id,firebase_uid');
  }

  /// One result row for (tournament, player), or {} when none.
  static Future<Map<String, dynamic>> getMyResult(String tournamentId, String uid) async {
    final rows = await getList('tournament_results', eqCol: 'tournament_id', eqVal: tournamentId, eqCol2: 'firebase_uid', eqVal2: uid);
    return rows.isNotEmpty ? rows.first : {};
  }

  static Future<List<Map<String, dynamic>>> getTournamentResults(String tournamentId) async {
    return getList('tournament_results', eqCol: 'tournament_id', eqVal: tournamentId, orderBy: 'created_at', ascending: true);
  }

  /// All results waiting for admin verification, oldest first.
  /// Same pending set as the main admin queue (AdminResultsPage):
  /// 'pending', 'submitted' and 're-submitted'. The legacy queue
  /// used to read only 'submitted' here and silently missed the
  /// other two statuses.
  static Future<List<Map<String, dynamic>>> getSubmittedResults() async {
    const pending = {'pending', 'submitted', 're-submitted'};
    final rows = await getList('tournament_results', orderBy: 'created_at', ascending: true, limit: 200);
    return rows.where((r) => pending.contains(strOf(r['status']).toLowerCase())).toList();
  }

  /// N-create-tournament AUTOMATION (2026-11-20): approve ONE submitted
  /// result and run EVERYTHING downstream automatically, zero manual
  /// steps: (1) winnings = kills x per-kill prize + placement win
  /// bonus (prize split) computed from the tournament; (2) winner's
  /// wallet credited EXACTLY ONCE — the tournament_payouts row is the
  /// claim lock (UNIQUE(tournament_id, firebase_uid)) and a 'prize_won'
  /// transaction check recovers a crash between payout-insert and
  /// wallet credit instead of double-paying or under-paying; a legacy
  /// 'tournament_winnings' tx check ALSO blocks approve when the manual
  /// path already paid this player (legacy-then-approve would otherwise
  /// double-pay — the claim lock cannot see it);
  /// (3) platform commission catch-up: if the SUM of
  /// 'platform_commission' rows for the tournament is short of the
  /// commission on the fees actually collected, ONE catch-up row is
  /// written for the difference (re-running writes nothing — the sum
  /// is then whole); (4) result -> 'approved' (final, no more edits);
  /// (5) tournaments.winnings_credited flips true once every
  /// registration has a payout row (incl. Rs 0 rows — a zero-winnings
  /// player still gets a payout row, so the flag can complete);
  /// (6) leaderboard ranks recomputed from approved results;
  /// (7) the player's pending referral bonus is credited if they have
  /// now played a real tournament; (8) stats side-effects — the
  /// match_history row (Player Stats / Weekly / Seasonal read it),
  /// profile total_matches/won_matches counters, and the
  /// tournament_registrations row (TournamentResultsPage /
  /// MatchSummary read rank/kills/damage/prize from it). Before this
  /// step existed, only the legacy manual credit path wrote those —
  /// so approve-path players showed 0 matches / 0 wins everywhere.
  /// Approving an already-approved
  /// result is a no-op success (idempotent). Returns a summary map.
  static Future<Map<String, dynamic>> approveMatchResult({
    required String tournamentId,
    required String playerUid,
    required String adminUid,
  }) async {
    final result = await getMyResult(tournamentId, playerUid);
    if (result.isEmpty) return {'ok': false, 'error': 'Result not found.'};
    if (strOf(result['status']).toLowerCase() == 'approved') {
      return {'ok': true, 'already': true, 'total': 0.0};
    }
    final t = await getTournament(tournamentId);
    if (t.isEmpty) return {'ok': false, 'error': 'Tournament not found.'};
    // EXACTLY-ONCE, reverse direction (user decision 2026-11-20
    // ~18:36 PKT): if the legacy manual path already paid this player
    // (a 'tournament_winnings' tx for this tournament+player),
    // auto-payout must NOT pay again. The claim lock below only sees
    // tournament_payouts rows and the (2b) check only sees 'prize_won'
    // txs — neither sees the legacy path's writes, so without this
    // check a legacy-credit-then-approve sequence would double-pay.
    // (Same fail-open-on-read-error property as the (2b) check: getList
    // returns [] on error. The fail-closed cross-path enforcement is
    // the admin APK's hasAutoPayouts on the legacy side.)
    try {
      final legacyTxs = await getList('transactions', eqCol: 'type', eqVal: 'tournament_winnings', eqCol2: 'firebase_uid', eqVal2: playerUid, limit: 200);
      if (legacyTxs.any((tx) => strOf(tx['tournament_id']) == tournamentId)) {
        return {'ok': false, 'error': 'Is player ko is tournament ki prize manual credit se mil chuki hai — auto-payout double-pay rokne ke liye blocked hai.'};
      }
    } catch (_) {}
    final kills = intOf(result['kills'], 0);
    final placement = intOf(result['placement'], 0);
    final split = asMap(t['prizeDistribution']);
    final w = matchWinnings(
      kills: kills,
      perKillPrize: numOf(t['perKillPrize']),
      placement: placement,
      prizePool: numOf(t['prizePool']),
      splitFirst: intOf(split['first'], 50),
      splitSecond: intOf(split['second'], 30),
      splitThird: intOf(split['third'], 20),
    );
    final total = w['total']!;
    final name = strOf(t['name'], 'Tournament');
    // (2a) Claim lock: one payout row per (tournament, player) — always
    // created, even for Rs 0, so the winnings_credited flag can complete.
    try {
      final existing = await getList('tournament_payouts', eqCol: 'tournament_id', eqVal: tournamentId, eqCol2: 'firebase_uid', eqVal2: playerUid);
      if (existing.isEmpty) {
        await client.from('tournament_payouts').insert({
          'tournament_id': tournamentId,
          'firebase_uid': playerUid,
          'kills': kills,
          'rank': placement,
          'extra_amount': w['winBonus'],
          'total_amount': total,
          'idempotency_key': 'payout:$tournamentId:$playerUid',
        });
      }
    } catch (_) {
      // Unique violation = another approve already claimed it.
    }
    // (2a2) Re-check: a concurrent approve may have finished while this
    // call was claiming — if the result is now 'approved', the other
    // call already credited the wallet; return early (idempotent)
    // instead of running the (2b) credit check against a stale read.
    // (Sequential double-approve was already safe via the status check
    // at the top; this closes the two-in-flight window as far as a
    // client-side read can. True simultaneity still needs a server-side
    // atomic credit — see Q-DOUBLEPAY-W2-REPORT.md.)
    final fresh = await getMyResult(tournamentId, playerUid);
    if (strOf(fresh['status']).toLowerCase() == 'approved') {
      return {'ok': true, 'already': true, 'total': total};
    }
    // (2b) Wallet credit — only if no 'prize_won' transaction for this
    // tournament+player exists yet (crash recovery).
    if (total > 0) {
      var credited = false;
      try {
        final txs = await getList('transactions', eqCol: 'type', eqVal: 'prize_won', eqCol2: 'firebase_uid', eqVal2: playerUid, limit: 200);
        credited = txs.any((tx) => strOf(tx['tournament_id']) == tournamentId);
      } catch (_) {}
      if (!credited) {
        final profile = await getProfile(playerUid);
        if (profile.isNotEmpty) {
          await updateProfile(playerUid, {'winning_cash': numOf(profile['winningCash']) + total});
          await recordTransaction(playerUid, 'prize_won', total, 'Prize — $name (#$placement)', {
            'tournament_id': tournamentId,
            'status': 'completed',
            'details': {'kills': kills, 'placement': placement, 'kill_amount': w['killAmount'], 'win_bonus': w['winBonus']},
          });
        }
      }
    }
    // (3) Commission catch-up (see doc comment).
    var commissionCatchUp = 0.0;
    try {
      final pct = numOf(t['commissionPct'], 10);
      final fee = numOf(t['entryFee']);
      double collected = 0;
      if (fee > 0) {
        final regs = await getRegistrations(tournamentId);
        // P0-1: entry fee x PLAYERS (not rows x teamSize — RPC rows
        // are one-per-member, legacy rows one-per-team).
        collected = fee * registrationPlayerCount(regs);
      }
      final expected = (collected * pct / 100 * 100).round() / 100;
      var existing = 0.0;
      final commRows = await getList('transactions', eqCol: 'type', eqVal: 'platform_commission', limit: 1000);
      for (final row in commRows) {
        if (strOf(row['tournament_id']) == tournamentId) existing += numOf(row['amount']);
      }
      final diff = ((expected - existing) * 100).round() / 100;
      if (diff > 0.009) {
        commissionCatchUp = diff;
        await recordTransaction(adminUid, 'platform_commission', diff, 'Platform commission catch-up — $name', {
          'tournament_id': tournamentId,
          'status': 'completed',
          'details': {'catch_up': true, 'expected': expected, 'previously_recorded': existing},
        });
      }
    } catch (_) {}
    // (4) Result -> approved (final).
    await client.from('tournament_results').update({'status': 'approved'}).eq('tournament_id', tournamentId).eq('firebase_uid', playerUid);
    // (4b) P1-10 — persist the real points on the result row.
    // tournament_registrations has NO points column (verified on
    // staging), so the points live here and getResultsForTournament
    // merges them onto the registration rows the results page
    // reads. Same effective template as recomputeLeaderboard and
    // the approve notification, so every client surface agrees.
    // Best-effort: a points-write failure must never fail the
    // approval itself (the page then honestly shows 0 PTS).
    // 042/054 overwrite these columns with the same decided table
    // when they run — no double credit: this writes NO ledger row.
    var pointsOk = false;
    var placementPoints = 0;
    var killPoints = 0;
    var teamPoints = 0;
    try {
      ScoringTemplate template;
      try {
        template = await ScoringTemplateStore.loadEffectiveTemplate();
      } catch (_) {
        template = kDefaultScoringTemplate;
      }
      final split = splitMatchPoints(kills: kills, placement: placement, template: template);
      placementPoints = split['placement_points']!;
      killPoints = split['kill_points']!;
      teamPoints = split['team_points']!;
      await client.from('tournament_results').update({
        'placement_points': placementPoints,
        'kill_points': killPoints,
        'team_points': teamPoints,
      }).eq('tournament_id', tournamentId).eq('firebase_uid', playerUid);
      pointsOk = true;
    } catch (_) {}
    // (5) winnings_credited when every registration has a payout row.
    try {
      final regs = await getRegistrations(tournamentId);
      final payouts = await getList('tournament_payouts', eqCol: 'tournament_id', eqVal: tournamentId);
      final paidUids = payouts.map((p) => strOf(p['firebase_uid'])).toSet();
      if (regs.isNotEmpty && regs.every((r) => paidUids.contains(strOf(r['firebase_uid'])))) {
        await client.from('tournaments').update({'winnings_credited': true}).eq('id', tournamentId);
      }
    } catch (_) {}
    // (6) Leaderboard — best-effort, never fail approval. The
    // caller is told whether it ran (leaderboardOk) so the admin
    // UI can say so honestly instead of always claiming success.
    var leaderboardOk = true;
    try {
      await recomputeLeaderboard();
    } catch (e) {
      leaderboardOk = false;
      debugPrint('approveMatchResult: recomputeLeaderboard failed: $e');
    }
    try {
      await maybeCreditReferralBonus(playerUid);
    } catch (_) {}
    // (8) Stats side-effects — best-effort, never fail approval;
    // idempotent (the match_history row is the marker).
    try {
      await ensureApprovalSideEffects(
        tournamentId: tournamentId,
        playerUid: playerUid,
        tournamentName: name,
        placement: placement,
        kills: kills,
        damage: intOf(result['damage'], 0),
        prize: total,
        winBonus: w['winBonus'] ?? 0.0,
      );
    } catch (_) {}
    return {'ok': true, 'total': total, 'killAmount': w['killAmount'], 'winBonus': w['winBonus'], 'commissionCatchUp': commissionCatchUp, 'leaderboardOk': leaderboardOk, 'placementPoints': placementPoints, 'killPoints': killPoints, 'teamPoints': teamPoints, 'pointsOk': pointsOk};
  }

  /// Stats side-effects of an approval (step (8) of
  /// [approveMatchResult]): the match_history row Player Stats /
  /// Weekly / Seasonal read, the profile match counters, and the
  /// registration row TournamentResultsPage / MatchSummary read.
  /// Idempotent: the match_history row is the marker — when it
  /// already exists for (tournament, player) nothing is written
  /// again, so a re-run can never double-count matches or wins.
  /// The registration row is only touched when its rank is still
  /// unset (a legacy-processed row is never overwritten).
  /// Best-effort: any failure is swallowed by the caller.
  static Future<void> ensureApprovalSideEffects({
    required String tournamentId,
    required String playerUid,
    required String tournamentName,
    required int placement,
    required int kills,
    required int damage,
    required double prize,
    required double winBonus,
  }) async {
    final existing = await getList('match_history', eqCol: 'tournament_id', eqVal: tournamentId, eqCol2: 'firebase_uid', eqVal2: playerUid, limit: 1);
    if (existing.isEmpty) {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final nowIso = DateTime.now().toUtc().toIso8601String();
      await client.from('match_history').insert({
        'firebase_uid': playerUid,
        'tournament_id': tournamentId,
        'tournament_name': tournamentName,
        'rank': placement > 0 ? placement : null,
        'kills': kills,
        'damage': damage,
        'headshot': 0,
        'earnings': prize,
        'played_at': nowIso,
        'date_ms': nowMs,
      });
      final profile = await getProfile(playerUid);
      if (profile.isNotEmpty) {
        final updates = <String, dynamic>{
          'total_matches': intOf(profile['totalMatches']) + 1,
        };
        if (placement == 1) {
          updates['won_matches'] = intOf(profile['wonMatches']) + 1;
        }
        await updateProfile(playerUid, updates);
      }
    }
    // Registration row (TournamentResultsPage + MatchSummary read
    // rank/kills/damage/prize from here). Only when unset — a
    // legacy-processed row is never overwritten.
    try {
      final regs = await getList('tournament_registrations', eqCol: 'tournament_id', eqVal: tournamentId, eqCol2: 'firebase_uid', eqVal2: playerUid, limit: 1);
      if (regs.isNotEmpty && intOf(regs.first['rank'], 0) <= 0) {
        await client.from('tournament_registrations').update({
          'kills': kills,
          'damage': damage,
          'rank': placement > 0 ? placement : null,
          'extra_amount': winBonus,
          'prize': prize,
        }).eq('tournament_id', tournamentId).eq('firebase_uid', playerUid);
      }
    } catch (_) {}
  }

  /// Reject a submitted result. An APPROVED result is final and can
  /// never be rejected (or edited) afterwards. The rejection is logged
  /// to admin_activity_logs with the reason.
  static Future<Map<String, dynamic>> rejectMatchResult({
    required String tournamentId,
    required String playerUid,
    required String adminUid,
    String? reason,
  }) async {
    final result = await getMyResult(tournamentId, playerUid);
    if (result.isEmpty) return {'ok': false, 'error': 'Result not found.'};
    if (strOf(result['status']).toLowerCase() == 'approved') {
      return {'ok': false, 'error': 'Result already approved — final hai, reject nahi ho sakta.'};
    }
    await client.from('tournament_results').update({'status': 'rejected'}).eq('tournament_id', tournamentId).eq('firebase_uid', playerUid);
    try {
      await client.from('admin_activity_logs').insert({
        'admin_uid': adminUid,
        'action': 'result_reject',
        'target_type': 'tournament_result',
        'target_id': '$tournamentId:$playerUid',
        'new_value': {'status': 'rejected'},
        if (reason != null && reason.trim().isNotEmpty) 'reason': reason.trim(),
      });
    } catch (_) {}
    return {'ok': true};
  }

  /// N-create-tournament AUTOMATION: recompute `profiles.leaderboard_rank`
  /// from APPROVED match results only (points = placement 1st = 10 + 1 per kill — decided OD-02 model, 2026-11-21).
  /// The Rankings tab reads this stored rank — without this call the
  /// board goes stale. Runs automatically after every result approval.
  /// Dense ranking (ties share a rank), top 100 only. EVERY player
  /// with an approved result gets a rank, including 0-point players
  /// (4th+ with 0 kills) — they played and were approved, so hiding
  /// them made the stored boards disagree with the scoped
  /// leaderboards (which list 0-point players). Players with NO
  /// approved result at all get rank null (they drop off the board).
  /// Capped at 1000 approved result rows per run (fetch cap).
  static Future<void> recomputeLeaderboard() async {
    final results = await getList('tournament_results', eqCol: 'status', eqVal: 'approved', limit: 1000);
    // Admin override (Sameer 2026-11-21 02:20): the effective
    // template (override when saved, else the decided 10/7/5).
    final template = await ScoringTemplateStore.loadEffectiveTemplate();
    final points = <String, int>{};
    for (final r in results) {
      final uid = strOf(r['firebase_uid']);
      if (uid.isEmpty) continue;
      points[uid] = (points[uid] ?? 0) + matchPoints(kills: intOf(r['kills'], 0), placement: intOf(r['placement'], 0), template: template);
    }
    final ranked = points.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    var rank = 0;
    var lastPoints = -1;
    var seen = 0;
    for (final e in ranked.take(100)) {
      seen++;
      if (e.value != lastPoints) {
        rank = seen;
        lastPoints = e.value;
      }
      try {
        await updateProfile(e.key, {'leaderboard_rank': rank});
      } catch (_) {}
    }
    // Clear stale ranks (users who were ranked but have no points now).
    try {
      final current = await getLeaderboard();
      final rankedUids = ranked.take(100).map((e) => e.key).toSet();
      for (final u in current) {
        final uid = strOf(u['firebase_uid']);
        if (uid.isNotEmpty && !rankedUids.contains(uid)) {
          try {
            await updateProfile(uid, {'leaderboard_rank': null});
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  /// N-create-tournament ANTI-FRAUD: has [uid] actually PLAYED a real
  /// tournament? True when they hold a registration in a tournament
  /// whose status shows it ran (ongoing / completed / result_pending /
  /// result). A bare signup, or a join in an upcoming tournament, does
  /// NOT count. Gates the referral bonus (see maybeCreditReferralBonus).
  static Future<bool> hasPlayedTournament(String uid) async {
    final regs = await getList('tournament_registrations', eqCol: 'firebase_uid', eqVal: uid);
    if (regs.isEmpty) return false;
    const ran = {'ongoing', 'completed', 'result_pending', 'result'};
    final tournaments = await getTournaments();
    final statusById = {for (final t in tournaments) strOf(t['id']): strOf(t['status']).toLowerCase()};
    return regs.any((r) => ran.contains(statusById[strOf(r['tournament_id'])] ?? ''));
  }

  /// REWARDS (user rule, voice call 2026-11-20): has [uid] RECHARGED
  /// their account? True when they hold a deposits row with status
  /// 'completed' and amount > 0 — the only status both credit paths
  /// (creditApiDeposit / creditGatewayDeposit) write when money
  /// actually lands. A pending / failed / gateway_pending deposit
  /// does NOT count. Gates the referral bonus together with
  /// [hasPlayedTournament] (see maybeCreditReferralBonus): the reward
  /// is earned ONLY when the invited friend BOTH recharges AND plays
  /// a tournament. Fail-closed: an unreadable deposits table reads
  /// as "not recharged" (getList returns [] on error).
  static Future<bool> hasRecharged(String uid) async {
    final deps = await getList('deposits', eqCol: 'firebase_uid', eqVal: uid, eqCol2: 'status', eqVal2: 'completed', limit: 200);
    return deps.any((d) => numOf(d['amount']) > 0);
  }

  /// N-create-tournament ANTI-FRAUD: credit a pending referral bonus —
  /// ONLY when every rule passes, otherwise {ok:false, reason}.
  /// Rules: (1) a 'pending' row for this referred user exists (else
  /// nothing to do); (2) NO 'credited' row already exists for them
  /// (one bonus per real person, exactly-once); (3) the referred user
  /// has PLAYED a real tournament (never on signup alone) AND (4) has
  /// RECHARGED their account (a completed deposit, amount > 0) — the
  /// user's rule (voice call 2026-11-20): the reward is earned ONLY
  /// when the invited friend BOTH recharges AND plays a tournament;
  /// (5) referrer != referred (self-referral); (6) referrer and
  /// referred do NOT share an install id (same-device farm -> status
  /// 'flagged', admin sees it in the referral list, no bonus).
  /// Called automatically after a result approval (the moment "played"
  /// becomes true) AND after a recharge completes (creditApiDeposit /
  /// creditGatewayDeposit — the moment "recharged" becomes true), so
  /// whichever condition completes second triggers the grant. Bonus
  /// amount comes from app_settings referral_bonus.
  static Future<Map<String, dynamic>> maybeCreditReferralBonus(String referredUid) async {
    final rows = await getList('pending_referrals', eqCol: 'referred_uid', eqVal: referredUid);
    final pending = rows.where((r) => strOf(r['status']).toLowerCase() == 'pending').toList();
    if (pending.isEmpty) return {'ok': false, 'reason': 'none_pending'};
    if (rows.any((r) => strOf(r['status']).toLowerCase() == 'credited')) {
      return {'ok': false, 'reason': 'already_credited'};
    }
    if (!await hasPlayedTournament(referredUid)) {
      return {'ok': false, 'reason': 'not_played_yet'};
    }
    if (!await hasRecharged(referredUid)) {
      return {'ok': false, 'reason': 'not_recharged_yet'};
    }
    final row = pending.first;
    final referrerUid = strOf(row['referrer_uid']);
    if (referrerUid.isEmpty || referrerUid == referredUid) {
      return {'ok': false, 'reason': 'self_referral'};
    }
    // Same-device farm check (install_id, 030 draft columns).
    try {
      final referrerProfile = await getProfile(referrerUid);
      final referredProfile = await getProfile(referredUid);
      final a = strOf(referrerProfile['install_id']);
      final b = strOf(referredProfile['install_id']);
      if (a.isNotEmpty && b.isNotEmpty && a == b) {
        await client.from('pending_referrals').update({'status': 'flagged'}).eq('id', strOf(row['id']));
        return {'ok': false, 'reason': 'same_device_suspected'};
      }
    } catch (_) {}
    final settings = await getAppSettings();
    final bonus = numOf(settings['referralBonus'], numOf(settings['referral_bonus'], 0));
    if (bonus <= 0) return {'ok': false, 'reason': 'no_bonus_configured'};
    final referrerProfile = await getProfile(referrerUid);
    if (referrerProfile.isEmpty) return {'ok': false, 'reason': 'referrer_not_found'};
    // Same destination as the manual credit path (the admin APK's
    // creditReferral): wallet bonus_cash AND the earnings display —
    // previously the auto path only moved the display number, so the
    // referrer's spendable balance never changed (audit fix 2026-11-21).
    await updateProfile(referrerUid, {
      'referral_earnings': numOf(referrerProfile['referralEarnings']) + bonus,
      'bonus_cash': numOf(referrerProfile['bonusCash']) + bonus,
    });
    await recordTransaction(referrerUid, 'referral_bonus', bonus, 'Referral bonus — friend ne recharge kiya aur tournament khela', {
      'status': 'completed',
      'details': {'referred_uid': referredUid},
    });
    await client.from('pending_referrals').update({'status': 'credited', 'bonus_amount': bonus, 'credited_at': isoNow()}).eq('id', strOf(row['id']));
    return {'ok': true, 'bonus': bonus};
  }

  static Future<List<Map<String, dynamic>>> getMyTickets(String uid) async {
    final rows = await getList('support_tickets', eqCol: 'firebase_uid', eqVal: uid, orderBy: 'created_at', ascending: false);
    return rows.map(normTicket).toList();
  }

  static Stream<List<Map<String, dynamic>>> streamMyTickets(String uid) =>
      streamList('support_tickets', eqCol: 'firebase_uid', eqVal: uid, orderBy: 'created_at', ascending: false).map((rows) => rows.map(normTicket).toList());

  static Future<void> createTicket({required String uid, required String subject, required String message, required String imageUrl, required String userEmail}) async {
    await client.from('support_tickets').insert({
      'firebase_uid': uid,
      'subject': subject,
      'message': message,
      'image_url': imageUrl,
      'status': 'open',
      'user_email': userEmail,
      // Schema column is `reply` (NOT admin_reply); there is no
      // `replies` column. Reply initialised at creation so admin
      // replies have a defined field from day one (audit requirement).
      'reply': '',
    });
  }

  static Future<Map<String, dynamic>> getDeposit(String id) async {
    return getRow('deposits', 'id', id);
  }

  // ---------- API payments (manual UTR flow REMOVED 2026-10-27) ----------
  // Creates an api_pending deposit and returns its id. If migration
  // 007 (order_id / provider_txn_id columns) has not been run yet,
  // the insert falls back to the original columns so the flow still
  // works; the provider tx id is then stored in the legacy `utr`
  // column by updateDepositProviderTx below.
  static Future<String> createApiDepositRow({
    required String uid,
    required String email,
    required String userName,
    required double amount,
    required String paymentMethodValue,
    required String orderId,
  }) async {
    try {
      final row = await client
          .from('deposits')
          .insert({
            'firebase_uid': uid,
            'user_email': email,
            'user_name': userName,
            'amount': amount,
            'payment_method': paymentMethodValue,
            'status': 'api_pending',
            'order_id': orderId,
          })
          .select('id')
          .single();
      return (row['id'] ?? '').toString();
    } catch (_) {
      final row = await client
          .from('deposits')
          .insert({
            'firebase_uid': uid,
            'user_email': email,
            'user_name': userName,
            'amount': amount,
            'payment_method': paymentMethodValue,
            'status': 'api_pending',
          })
          .select('id')
          .single();
      return (row['id'] ?? '').toString();
    }
  }

  static Future<void> updateDepositProviderTx(String depositId, String txId) async {
    try {
      await client.from('deposits').update({'provider_txn_id': txId}).eq('id', depositId);
    } catch (_) {
      await client.from('deposits').update({'utr': txId}).eq('id', depositId);
    }
  }

  static Future<void> updateDepositStatus(String depositId, String status) async {
    await client.from('deposits').update({'status': status}).eq('id', depositId);
  }

  /// Credits an API-verified deposit exactly once: status must still
  /// be api_pending/pending, otherwise this is a no-op (double-verify
  /// guard — the API equivalent of the old winningsCredited guard).
  static Future<void> creditApiDeposit(String depositId) async {
    final dep = await getDeposit(depositId);
    if (dep.isEmpty) return;
    final status = strOf(dep['status']);
    // Strict guard (matches creditGatewayDeposit): only a still-pending
    // deposit may be credited — a failed/rejected row must never credit.
    if (status != 'api_pending' && status != 'pending') return;
    final uid = strOf(dep['firebase_uid']);
    final amount = numOf(dep['amount']);
    final profile = await getProfile(uid);
    final newBalance = numOf(profile['depositBalance']) + amount;
    await updateProfile(uid, {'deposit_balance': newBalance});
    await client.from('deposits').update({'status': 'completed', 'processed_at': isoNow()}).eq('id', depositId);
    await recordTransaction(uid, 'api_deposit', amount, 'Recharge via ${strOf(dep['payment_method'])} (API verified)');
    // Referral milestones (user rule 2026-11-20): the recharge half of
    // "recharge AND play" just became true — re-check the pending
    // referral grant now (the play half may already be true).
    // Best-effort: never fail the deposit credit.
    try {
      await maybeCreditReferralBonus(uid);
    } catch (_) {}
  }

  /// Credits a MANUAL EasyPaisa/JazzCash deposit exactly once — the
  /// admin-confirmed path (P0-4 / audit X1, 2026-11-21): the player
  /// sent money OUTSIDE the app, the admin confirmed it on the
  /// EasyPaisa/JazzCash side and credits it from the player profile
  /// (the admin APK's manualCreditDeposit creates the 'pending'
  /// deposits row first, then calls this). Same strict guard as
  /// creditApiDeposit (only a still-'pending' deposit may credit),
  /// same wallet credit (profiles.deposit_balance += amount), same
  /// referral re-check — but the transaction row is type
  /// 'manual_deposit' with the channel + reference, never
  /// "(API verified)".
  ///
  /// WHY NOT approve_deposit (067): that RPC writes the deposits
  /// status + transactions + audit rows but NEVER touches
  /// profiles.deposit_balance (verified in the 067 draft) — and this
  /// app's wallet display reads the profile columns directly, so an
  /// approve_deposit-only credit would leave the wallet showing
  /// nothing. The two also cannot run on the same row:
  /// approve_deposit flips status to 'approved', which this guard
  /// then refuses (and vice versa). This function IS the credit —
  /// it moves the profile column the wallet shows.
  /// Unlike its siblings this THROWS (instead of silently no-op)
  /// on a missing / already-processed deposit: the caller just
  /// created the row, so a silent skip would report a false
  /// success to the admin.
  static Future<void> creditManualDeposit(
    String depositId, {
    required String adminUid,
    required String reference,
  }) async {
    final dep = await getDeposit(depositId);
    if (dep.isEmpty) throw Exception('Deposit not found.');
    final status = strOf(dep['status']);
    // Strict guard (matches creditApiDeposit/creditGatewayDeposit):
    // only a still-pending deposit may be credited — a
    // completed/rejected row must never credit twice.
    if (status != 'pending') {
      throw Exception('Deposit already processed (status: $status).');
    }
    final uid = strOf(dep['firebase_uid']);
    final amount = numOf(dep['amount']);
    final method = strOf(dep['payment_method'], 'manual');
    final profile = await getProfile(uid);
    final newBalance = numOf(profile['depositBalance']) + amount;
    await updateProfile(uid, {'deposit_balance': newBalance});
    await client.from('deposits').update({
      'status': 'completed',
      'processed_at': isoNow(),
      'processed_by': adminUid,
    }).eq('id', depositId);
    await recordTransaction(
      uid,
      'manual_deposit',
      amount,
      'Manual deposit — $method confirmed by admin'
          '${reference.isEmpty ? '' : ' (ref: $reference)'}',
      {'status': 'completed', 'admin_uid': adminUid},
    );
    // Referral milestones (user rule 2026-11-20): the recharge half of
    // "recharge AND play" just became true — re-check the pending
    // referral grant now (the play half may already be true).
    // Best-effort: never fail the deposit credit.
    try {
      await maybeCreditReferralBonus(uid);
    } catch (_) {}
  }

  // ---------- PayFast gateway deposits (automatic bank transfer) ----------
  // Status 'gateway_pending' is a NEW status value on the existing
  // deposits table (no new column needed — migration 012 only adds
  // the gateway_callbacks table the verified callback lands in).
  static Future<String> createGatewayDepositRow({
    required String uid,
    required String email,
    required String userName,
    required double amount,
    required String paymentMethodValue,
    required String orderId,
  }) async {
    final row = await client
        .from('deposits')
        .insert({
          'firebase_uid': uid,
          'user_email': email,
          'user_name': userName,
          'amount': amount,
          'payment_method': paymentMethodValue,
          'status': 'gateway_pending',
          'order_id': orderId,
        })
        .select('id')
        .single();
    return (row['id'] ?? '').toString();
  }

  /// Credits a gateway deposit EXACTLY ONCE: the fresh re-read must
  /// still be 'gateway_pending', otherwise this is a no-op. Called
  /// ONLY from PayFastService.checkGatewayStatus after a verified
  /// success callback row is found — never from any manual approve
  /// path (none exists for gateway deposits).
  static Future<void> creditGatewayDeposit(String depositId, String providerTxnId) async {
    final dep = await getDeposit(depositId);
    if (dep.isEmpty) return;
    if (strOf(dep['status']) != 'gateway_pending') return;
    final uid = strOf(dep['firebase_uid']);
    final amount = numOf(dep['amount']);
    final profile = await getProfile(uid);
    final newBalance = numOf(profile['depositBalance']) + amount;
    await updateProfile(uid, {'deposit_balance': newBalance});
    final updates = <String, dynamic>{
      'status': 'completed',
      'processed_at': isoNow(),
    };
    if (providerTxnId.isNotEmpty) updates['provider_txn_id'] = providerTxnId;
    await client.from('deposits').update(updates).eq('id', depositId);
    await recordTransaction(uid, 'payfast_deposit', amount, 'Recharge via PayFast (verified callback)');
    // Referral milestones (user rule 2026-11-20): the recharge half of
    // "recharge AND play" just became true — re-check the pending
    // referral grant now (the play half may already be true).
    // Best-effort: never fail the deposit credit.
    try {
      await maybeCreditReferralBonus(uid);
    } catch (_) {}
  }

  static Future<bool> voiceEnabledForTournament(String tournamentId) async {
    try {
      final settings = await getAppSettings();
      if (settings['voiceEnabled'] == false || settings['voice_enabled'] == false) return false;
      final t = await getTournament(tournamentId);
      if (t.isNotEmpty && (t['voiceEnabled'] == false || t['voice_enabled'] == false)) return false;
    } catch (_) {
      return true;
    }
    return true;
  }

  // ---------- presence (heartbeat; offline = staleness) ----------
  static Future<void> presenceHeartbeat({String? currentTournamentId, String? squadId}) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    try {
      await client.from('presence').upsert({
        'firebase_uid': user.uid,
        'online': true,
        'last_seen': isoNow(),
        if (currentTournamentId != null) 'current_tournament_id': currentTournamentId,
        if (squadId != null) 'squad_id': squadId,
      }, onConflict: 'firebase_uid');
    } catch (_) {}
  }

  static Future<void> presenceOffline() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    try {
      // ROUND 11: do NOT touch last_seen here. The old code stamped
      // last_seen = NOW on every offline write (Detail dispose, room
      // dispose, pause/detached, logout), so the Status sheet then
      // showed "Last seen Just now" for a player it counted as
      // offline — the sheet contradicted itself. Last seen must mean
      // last real activity (last heartbeat), never the offline write.
      await client.from('presence').update({'online': false}).eq('firebase_uid', user.uid);
    } catch (_) {}
  }

  static Stream<Map<String, dynamic>> streamPresence(String uid) =>
      streamRow('presence', 'firebase_uid', uid);

  /// Profiles for a set of uids (Status sheet badges). Same pattern as
  /// getPresenceMap; empty map on failure.
  static Future<Map<String, Map<String, dynamic>>> getProfilesMap(List<String> uids) async {
    if (uids.isEmpty) return {};
    // FIX 3 (2026-11-22): fixture seam, same pattern as getRow /
    // getList — the Members online-list tests inject profiles
    // through testFixtures. Null in production: zero behaviour
    // change on the live path.
    final fixtures = testFixtures;
    if (fixtures != null) {
      final out = <String, Map<String, dynamic>>{};
      for (final r in _fixtureRows('profiles')) {
        final uid = strOf(r['firebase_uid']);
        if (uid.isNotEmpty && uids.contains(uid)) out[uid] = Map<String, dynamic>.from(r);
      }
      return out;
    }
    try {
      final rows = await client.from('profiles').select().inFilter('firebase_uid', uids);
      final out = <String, Map<String, dynamic>>{};
      for (final r in (rows as List)) {
        final m = Map<String, dynamic>.from(r as Map);
        out[strOf(m['firebase_uid'])] = m;
      }
      return out;
    } catch (_) {
      return {};
    }
  }

  /// Presence rows for a set of uids (Online Status sheet). Empty map
  /// on any failure — the sheet then shows "Last seen …" grey, never
  /// crashes, and never exposes a global online list: callers pass only
  /// the uids of registrations in one tournament/squad.
  static Future<Map<String, Map<String, dynamic>>> getPresenceMap(List<String> uids) async {
    if (uids.isEmpty) return {};
    // FIX 3 (2026-11-22): fixture seam, same pattern as getRow /
    // getList — the Members online-list tests inject presence
    // rows through testFixtures. Null in production: zero
    // behaviour change on the live path.
    final fixtures = testFixtures;
    if (fixtures != null) {
      final out = <String, Map<String, dynamic>>{};
      for (final r in _fixtureRows('presence')) {
        final uid = strOf(r['firebase_uid']);
        if (uid.isNotEmpty && uids.contains(uid)) out[uid] = Map<String, dynamic>.from(r);
      }
      return out;
    }
    try {
      final rows = await client.from('presence').select().inFilter('firebase_uid', uids);
      final out = <String, Map<String, dynamic>>{};
      for (final r in (rows as List)) {
        final m = Map<String, dynamic>.from(r as Map);
        out[strOf(m['firebase_uid'])] = m;
      }
      return out;
    } catch (_) {
      return {};
    }
  }

  /// ROUND 11 — ONE consistent rule, used by the Status sheet count,
  /// its dots, its Last-seen text, PresenceDot, and room welcomes
  /// alike: online = last_seen within the last 2 minutes. NOTHING
  /// else. The old rule also required `online == true`, but offline
  /// writes fire on Detail dispose, room dispose, pause/detached and
  /// logout — so a player who had just been heartbeating (fresh
  /// last_seen, "Last seen Just now") read as grey with count 0 the
  /// moment any offline write flipped the boolean, even while they
  /// were visibly in the room. With freshness as the sole rule the
  /// sheet can never say 0 while it lists a Just-now player, and
  /// "Last seen" and the dot can never disagree: both derive from
  /// the same last_seen. No onDisconnect exists in Supabase —
  /// staleness IS the offline signal, and 2 minutes is the backstop
  /// for a killed app (no lifecycle event fires on force-kill).
  /// Consequence, stated honestly: a player who explicitly leaves
  /// still reads green for up to 2 minutes after their last
  /// heartbeat — that is the price of the single freshness rule, and
  /// it matches the voice-peer ghost window from round 10.
  static bool presenceIsOnline(Map<String, dynamic> p) {
    if (p.isEmpty) return false;
    final last = parseTs(p['last_seen'] ?? p['lastSeen']);
    if (last == 0) return false;
    return DateTime.now().millisecondsSinceEpoch - last < 2 * 60 * 1000;
  }

  // ---------- room controls (026, O-admin-panel W5) ----------
  /// One room_controls row for a tournament, or {} when there is no
  /// row (room ON) or the read fails. CRITICAL GUARD: if the read
  /// fails — e.g. the table does not exist because migration 026
  /// was never applied — the room is treated as ON and voice is
  /// NEVER blocked on a read error. A missing control row is not a
  /// closed room.
  static Future<Map<String, dynamic>> getRoomControl(String tournamentId) async {
    if (tournamentId.isEmpty) return {};
    try {
      final row = await getRow('room_controls', 'tournament_id', tournamentId);
      return row;
    } catch (_) {
      return {};
    }
  }

  /// True only when a room_controls row explicitly disables voice.
  /// No row, a true flag, or any read failure all mean ON.
  static bool isRoomVoiceDisabled(Map<String, dynamic> control) => control['voice_enabled'] == false;

  /// get_room_credentials caller — 026 4-column return:
  /// TABLE (room_id, room_password, voice_disabled, disabled_reason).
  /// Returns {'ok', 'roomId', 'roomPassword', 'voiceDisabled',
  /// 'disabledReason', 'hasCredentials', 'error'}. Zero rows = the
  /// caller is not eligible (not registered / not released) — never
  /// an error that leaks which half failed. A disabled row returns
  /// voiceDisabled=true with NO credentials. Backward-compatible
  /// with the pre-026 2-column shape (voiceDisabled defaults false).
  /// B-11 (2026-11-21): the LIVE 026 signature takes TWO args —
  /// (p_caller_uid text, p_tournament_id uuid). The old 1-arg call
  /// could never match it, so every call fell into the catch and
  /// the app read room_id/room_password straight off the tournament
  /// row instead (the live leak). This method now passes the
  /// signed-in Firebase UID (the app has no Supabase Auth session,
  /// so the RPC cannot derive the caller itself) and is the ONLY
  /// read path for credentials — no caller reads the row columns.
  static Future<Map<String, dynamic>> getRoomCredentials(String tournamentId) async {
    // Fail closed without a signed-in caller: the live function
    // returns zero rows for a blank UID anyway; never call it
    // without an identity.
    final callerUid = FirebaseAuth.instance.currentUser?.uid ?? '';
    if (callerUid.isEmpty || tournamentId.isEmpty) {
      return {'ok': false, 'roomId': '', 'roomPassword': '', 'voiceDisabled': false, 'disabledReason': '', 'hasCredentials': false, 'error': callerUid.isEmpty ? 'Not signed in' : 'Missing tournament'};
    }
    try {
      final res = await client.rpc('get_room_credentials', params: {'p_caller_uid': callerUid, 'p_tournament_id': tournamentId});
      final rows = res is List ? res : [];
      if (rows.isEmpty) {
        return {'ok': true, 'roomId': '', 'roomPassword': '', 'voiceDisabled': false, 'disabledReason': '', 'hasCredentials': false};
      }
      final row = Map<String, dynamic>.from(rows.first as Map);
      final disabled = row['voice_disabled'] == true;
      return {
        'ok': true,
        'roomId': disabled ? '' : strOf(row['room_id']),
        'roomPassword': disabled ? '' : strOf(row['room_password']),
        'voiceDisabled': disabled,
        'disabledReason': strOf(row['disabled_reason']),
        'hasCredentials': !disabled && strOf(row['room_id']).isNotEmpty,
      };
    } catch (e) {
      return {'ok': false, 'roomId': '', 'roomPassword': '', 'voiceDisabled': false, 'disabledReason': '', 'hasCredentials': false, 'error': e.toString()};
    }
  }

  // ---------- avatar frames (004_frames.sql; cosmetic only) ----------
  // Every read/write here is wrapped so a database WITHOUT the 004
  // tables degrades gracefully: empty lists / no equipped frame, never
  // a crash. Frames never affect join, eligibility, or any balance
  // except the purchase price itself (deposit-first, same spendable
  // rule as join fees: deposit + winning only).
  static const List<String> framePresets = ['gold_royal', 'diamond', 'fire', 'neon', 'crown'];

  static Future<List<Map<String, dynamic>>> getFrames() async {
    try {
      return await getList('frames', orderBy: 'sort_order', ascending: true);
    } catch (_) {
      return [];
    }
  }

  static Future<Map<String, dynamic>> getFrameById(String id) async {
    if (id.isEmpty) return {};
    try {
      return await getRow('frames', 'id', id);
    } catch (_) {
      return {};
    }
  }

  static Future<List<Map<String, dynamic>>> getUserFrames(String uid) async {
    try {
      return await getList('user_frames', eqCol: 'firebase_uid', eqVal: uid, orderBy: 'purchased_at', ascending: false);
    } catch (_) {
      return [];
    }
  }

  // ADMIN PREMIUM FRAMES (2026-10-30): admin_* frame ids have NO
  // frames-table row by design (so the shop can never list or sell
  // them). They live only as user_frames rows with source
  // 'admin_free', written by equipAdminFrame below. This lookup
  // therefore returns an admin preset DIRECTLY (no frames-table
  // lookup) — but ONLY when the row's owner IS the designated
  // admin; an admin preset on any other UID is refused (returns {}),
  // so a crafted row can never make a non-admin render one.
  static Future<String> designatedAdminUid() async {
    try {
      final rows = await getList('admin_config', eqCol: 'id', eqVal: 1);
      if (rows.isNotEmpty) return strOf(rows.first['admin_firebase_uid']);
    } catch (_) {}
    return '';
  }

  // FIX 5 (2026-11-22, Watch Live moderator): the signed-in user's
  // admin role ('moderator' / 'super_admin' / ...), for the Watch
  // Live mod menu. Same `admin_role` RPC (023) as
  // AdminDb.getAdminRole — it lives HERE (not in admin_db.dart)
  /// because watch_live_screen.dart cannot import admin_db.dart
  /// (import cycle via the old admin login screen — FIX 32: the
  /// cycle is gone with the panel, but the method stays here,
  /// where the moderator callers already are).
  /// Falls back to the caller's own `admin_users` row when the RPC
  /// is unavailable (missing/blocked). Returns null on ANY failure
  /// — unknown role = no capabilities (fail closed). Never throws.
  static Future<String?> myAdminRole() async {
    // 1. Server-side resolution (identity from the JWT — no UID is
    // ever sent from the client for authorization).
    try {
      final role = parseAdminRoleResult(await client.rpc('admin_role'));
      if (role != null) return role;
    } catch (_) {
      // RPC missing/blocked — fall through to the direct row read.
    }
    // 2. Own admin_users row (getRow honors test fixtures).
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
      if (uid.isEmpty) return null;
      final row = await getRow('admin_users', 'firebase_uid', uid);
      final role = strOf(row['role']);
      return role.isEmpty ? null : role;
    } catch (_) {
      return null;
    }
  }

  /// Parse the `admin_role` RPC payload: a bare String, or a Map
  /// with a `role` / `admin_role` key. Null when the payload
  /// carries no role. Pure — unit-testable.
  static String? parseAdminRoleResult(dynamic res) {
    if (res == null) return null;
    if (res is String) return res.isEmpty ? null : res;
    if (res is Map) {
      final role = strOf(res['role'], strOf(res['admin_role']));
      return role.isEmpty ? null : role;
    }
    final s = res.toString();
    return s.isEmpty ? null : s;
  }

  static bool isAdminFrameId(String id) => id.startsWith('admin_');

  // ADMIN FRAME UUID MAP (2026-10-30 FIX for the 22P02 select failure):
  // user_frames.frame_id is uuid NOT NULL REFERENCES frames(id) — a
  // string preset such as 'admin_solar_eclipse' can NEVER be stored
  // there (Postgres 22P02), and user_frames.source only allows
  // 'purchased'/'granted', so the old 'admin_free' source would have
  // failed next. Each admin preset therefore has a FIXED uuid. The
  // app self-seeds the matching frames row on first select
  // (active=false, so the shop — which filters active != false —
  // never lists it; style_preset 'crown' is only a CHECK-valid
  // placeholder, rendering keys off this map, never off that column).
  // No migration is required: the rows are created by the app itself
  // under the existing anon_all RLS policy (see also migration 014,
  // which seeds the same rows for completeness and is optional).
  static const Map<String, String> adminFrameUuids = {
    'admin_royal_gold': 'a0d00000-0000-4000-8000-000000000001',
    'admin_diamond_crown': 'a0d00000-0000-4000-8000-000000000002',
    'admin_emerald_royal': 'a0d00000-0000-4000-8000-000000000003',
    'admin_ruby_regal': 'a0d00000-0000-4000-8000-000000000004',
    'admin_sapphire_elite': 'a0d00000-0000-4000-8000-000000000005',
    'admin_obsidian_gold': 'a0d00000-0000-4000-8000-000000000006',
    'admin_crimson_flame': 'a0d00000-0000-4000-8000-000000000007',
    'admin_violet_majesty': 'a0d00000-0000-4000-8000-000000000008',
    'admin_arctic_aurora': 'a0d00000-0000-4000-8000-000000000009',
    'admin_solar_eclipse': 'a0d00000-0000-4000-8000-000000000010',
  };
  static const Map<String, String> adminFrameLabels = {
    'admin_royal_gold': 'Crown Royale Blue-Gold',
    'admin_diamond_crown': 'Diamond Crown Ice',
    'admin_emerald_royal': 'Emerald Crown Royal',
    'admin_ruby_regal': 'Ruby Fire Crown',
    'admin_sapphire_elite': 'Sapphire Ocean Crown',
    'admin_obsidian_gold': 'Obsidian Gold Crown',
    'admin_crimson_flame': 'Crimson Flame Crown',
    'admin_violet_majesty': 'Violet Majesty Crown',
    'admin_arctic_aurora': 'Arctic Aurora Crown',
    'admin_solar_eclipse': 'Solar Fire Crown',
  };
  static String? adminPresetForUuid(String uuid) {
    for (final e in adminFrameUuids.entries) {
      if (e.value == uuid) return e.key;
    }
    return null;
  }

  static bool isAdminFrameUuid(String id) => adminPresetForUuid(id) != null;

  static Future<Map<String, dynamic>> getEquippedFrame(String uid) async {
    if (uid.isEmpty) return {};
    try {
      final rows = await client.from('user_frames').select().eq('firebase_uid', uid).eq('is_equipped', true).limit(1);
      final list = rows as List;
      if (list.isEmpty) return {};
      final frameId = strOf((list.first as Map)['frame_id']);
      final adminPreset = adminPresetForUuid(frameId);
      if (adminPreset != null) {
        final adminUid = await designatedAdminUid();
        if (adminUid.isEmpty || uid != adminUid) return {};
        return {'id': adminPreset, 'style_preset': adminPreset, 'name': 'Admin Premium Frame'};
      }
      if (isAdminFrameId(frameId)) {
        final adminUid = await designatedAdminUid();
        if (adminUid.isEmpty || uid != adminUid) return {};
        return {'id': frameId, 'style_preset': frameId, 'name': 'Admin Premium Frame'};
      }
      return await getFrameById(frameId);
    } catch (_) {
      return {};
    }
  }

  // ADMIN FRAME SELECT (2026-10-30, FIXED 2026-10-30): the ONLY way
  // an admin_* frame gets equipped. Throws unless (a) the preset is
  // one of the 10 admin presets and (b) the caller UID exactly
  // matches the designated admin (fail closed on an unreadable
  // admin row). FREE: no balance is touched. Persists in
  // user_frames as the preset's FIXED uuid with source 'granted'
  // (both satisfy the live schema: frame_id uuid FK + source CHECK),
  // so the choice survives logout/login and renders on every phone
  // via getEquippedFrame. Replaces any previously equipped frame
  // (shop or admin) — one equipped frame at a time, as before.
  // The frames row is self-seeded here (inactive, never in the shop)
  // because the FK requires it to exist; a duplicate-name insert
  // just means it was already seeded, and is verified, not assumed.
  static Future<void> equipAdminFrame(String uid, String preset) async {
    final frameUuid = adminFrameUuids[preset];
    if (frameUuid == null) throw Exception('Ye admin frame maujood nahi hai.');
    final adminUid = await designatedAdminUid();
    if (uid.isEmpty || adminUid.isEmpty || uid != adminUid) {
      throw Exception('Sirf admin ye frame laga sakta hai.');
    }
    try {
      await client.from('frames').insert({
        'id': frameUuid,
        'name': 'Admin Only: ${adminFrameLabels[preset] ?? preset}',
        'style_preset': 'crown',
        'category': 'room',
        'price': 0,
        'active': false,
        'sort_order': 100,
      });
    } catch (_) {
      // Already seeded (unique name/id) — verified below, not assumed.
    }
    final seed = await getFrameById(frameUuid);
    if (seed.isEmpty) throw Exception('Admin frame row ban nahi saka, dobara try karen.');
    final owned = await getUserFrames(uid);
    await client.from('user_frames').update({'is_equipped': false}).eq('firebase_uid', uid);
    if (owned.any((r) => strOf(r['frame_id']) == frameUuid)) {
      await client.from('user_frames').update({'is_equipped': true}).eq('firebase_uid', uid).eq('frame_id', frameUuid);
    } else {
      await client.from('user_frames').insert({
        'firebase_uid': uid,
        'frame_id': frameUuid,
        'source': 'granted',
        'is_equipped': true,
      });
    }
  }

  static Future<void> buyFrame(String uid, Map<String, dynamic> frame) async {
    final frameId = strOf(frame['id']);
    // ADMIN FRAMES ARE NEVER FOR SALE: the shop lists active
    // frames-table rows only (admin rows are inactive), so this is
    // defence-in-depth against a crafted call — preset ids AND uuids.
    if (isAdminFrameId(frameId) || isAdminFrameUuid(frameId)) throw Exception('Admin frames kabhi sale par nahi hote.');
    if (frameId.isEmpty) throw Exception('Frame not found.');
    final owned = await getUserFrames(uid);
    if (owned.any((r) => strOf(r['frame_id']) == frameId)) throw Exception('You already own this frame.');
    final price = numOf(frame['price']);
    if (price <= 0) {
      await client.from('user_frames').insert({
        'firebase_uid': uid,
        'frame_id': frameId,
        'source': 'purchased',
        'is_equipped': false,
      });
      return;
    }
    final profile = await getProfile(uid);
    var dep = numOf(profile['depositBalance']);
    var win = numOf(profile['winningCash']);
    if (dep + win < price) throw Exception('Insufficient balance. Spendable: Rs ${(dep + win).toStringAsFixed(2)}.');
    double fromDep;
    double fromWin;
    if (dep >= price) {
      fromDep = price;
      fromWin = 0;
    } else {
      fromDep = dep;
      fromWin = price - dep;
    }
    await updateProfile(uid, {'deposit_balance': dep - fromDep, 'winning_cash': win - fromWin});
    try {
      await client.from('user_frames').insert({
        'firebase_uid': uid,
        'frame_id': frameId,
        'source': 'purchased',
        'is_equipped': false,
      });
    } catch (e) {
      // Compensation: refund so a failed purchase never strands money.
      try {
        await updateProfile(uid, {'deposit_balance': dep, 'winning_cash': win});
      } catch (_) {}
      rethrow;
    }
    await recordTransaction(uid, 'frame_purchase', -price, 'Frame: ${strOf(frame['name'], 'Frame')}', {
      'details': {'frame_id': frameId},
    });
  }

  static Future<void> equipFrame(String uid, String frameId) async {
    // ADMIN FRAMES CANNOT BE EQUIPPED FROM THE SHOP — not even by
    // the admin (the admin uses equipAdminFrame from the admin-only
    // picker). A non-admin attempting this, including via a crafted
    // request, is blocked here before any ownership check — preset
    // ids AND uuids (the admin's own shop "Obtained" tab may show an
    // inactive admin row they own; equipping it from there is still
    // blocked, so the admin-only picker stays the only path).
    if (isAdminFrameId(frameId) || isAdminFrameUuid(frameId)) throw Exception('Admin frames sirf Admin Profile se lagte hain.');
    final owned = await getUserFrames(uid);
    if (!owned.any((r) => strOf(r['frame_id']) == frameId)) throw Exception('You do not own this frame.');
    await client.from('user_frames').update({'is_equipped': false}).eq('firebase_uid', uid);
    await client.from('user_frames').update({'is_equipped': true}).eq('firebase_uid', uid).eq('frame_id', frameId);
  }

  static Future<void> unequipFrame(String uid) async {
    await client.from('user_frames').update({'is_equipped': false}).eq('firebase_uid', uid);
  }

  // ---------- voice signaling (ephemeral; deleted after handling/leave) ----------
  static Future<List<Map<String, dynamic>>> getVoicePeers(String roomId) async {
    return getList('voice_signaling_peers', eqCol: 'room_id', eqVal: roomId);
  }

  static Stream<List<Map<String, dynamic>>> streamVoicePeers(String roomId) =>
      streamList('voice_signaling_peers', eqCol: 'room_id', eqVal: roomId);

  // seatNo (migration 013, voice_signaling_peers.seat_no): the
  // admin-assigned mic slot (1..9). Null = no assignment (join-order
  // placement, historic behaviour). Callers that pass a seat must
  // tolerate the column not existing yet (see VoiceRoom fallback).
  static Future<void> voicePeerUpsert(String roomId, String uid, String name, bool muted, {int? seatNo}) async {
    final row = <String, dynamic>{
      'room_id': roomId,
      'firebase_uid': uid,
      'display_name': name,
      'muted': muted,
      'joined_at': isoNow(),
    };
    if (seatNo != null) row['seat_no'] = seatNo;
    await client.from('voice_signaling_peers').upsert(row, onConflict: 'room_id,firebase_uid');
  }

  static Future<void> voicePeerRemove(String roomId, String uid) async {
    try {
      await client.from('voice_signaling_peers').delete().eq('room_id', roomId).eq('firebase_uid', uid);
    } catch (_) {}
  }

  static Future<void> voicePeerUpdateMuted(String roomId, String uid, bool muted) async {
    try {
      await client.from('voice_signaling_peers').update({'muted': muted}).eq('room_id', roomId).eq('firebase_uid', uid);
    } catch (_) {}
  }

  static Future<List<Map<String, dynamic>>> getVoiceInbox(String roomId, String toUid) async {
    return getList('voice_signaling_inbox', eqCol: 'room_id', eqVal: roomId, eqCol2: 'to_firebase_uid', eqVal2: toUid);
  }

  static Stream<List<Map<String, dynamic>>> streamVoiceInbox(String roomId, String toUid) =>
      streamList('voice_signaling_inbox', eqCol: 'room_id', eqVal: roomId, eqCol2: 'to_firebase_uid', eqVal2: toUid);

  static Future<void> voiceInboxSend(String roomId, String toUid, String fromUid, Map<String, dynamic> msg) async {
    await client.from('voice_signaling_inbox').insert({
      'room_id': roomId,
      'to_firebase_uid': toUid,
      'from_firebase_uid': fromUid,
      'kind': strOf(msg['kind']),
      'sdp': msg['sdp'],
      'sdp_type': msg['sdpType'],
      'candidate': msg['candidate'],
      'sdp_mid': msg['sdpMid'],
      'sdp_mline_index': msg['sdpMLineIndex'],
    });
  }

  static Future<void> voiceInboxDelete(String id) async {
    try {
      await client.from('voice_signaling_inbox').delete().eq('id', id);
    } catch (_) {}
  }

  static Future<void> voiceInboxClearFor(String roomId, String uid) async {
    try {
      await client.from('voice_signaling_inbox').delete().eq('room_id', roomId).eq('to_firebase_uid', uid);
    } catch (_) {}
  }

  // ---------- Phase 3 — ARENA HUB engagement / support / results ----------
  // Drafts 017–019 + 022 are NOT applied yet (Phase 4 applies them),
  // so every read below degrades gracefully: [] / 0 / all-true
  // defaults / {'ok': false, ...} — never a throw, never invented
  // data. Live tables (profiles, pending_referrals, blocked_users,
  // tournament_registrations) work now. No cash logic anywhere here.
  // RPC identity: claim_reward / record_match_result (022) derive
  // the caller from firebase_uid() server-side — no client-sent UID
  // is used for authorization.
  //
  // Schema sources (verified, not guessed):
  //   017: profiles.notification_prefs jsonb, default all six keys true.
  //   018: community_points_ledger (firebase_uid, delta, created_at),
  //     challenges (key, points, goal, period, active), challenge_progress
  //     (firebase_uid, challenge_id, period_key, progress, claimed),
  //     achievements (key, points, requirement jsonb), user_achievements
  //     (firebase_uid, achievement_id, unlocked_at).
  //   019: support_messages (ticket_id uuid, sender_id TEXT = Firebase
  //     UID, sender_role 'user'/'admin', message), referral_milestones
  //     (milestone_friends, points, title).
  //   022: claim_reward(p_reward_key, p_period_key) -> {reward_key,
  //     period_key, points, total_points}; record_match_result(
  //     p_tournament_id uuid, p_placement, p_kills, p_assists, p_damage,
  //     p_duration, p_notes) -> {tournament_id, firebase_uid, status,
  //     placement, placement_points, kill_points, team_points, kills,
  //     assists, damage, duration_seconds}.
  //   pro_features.dart MatchSummaryPage reads tournament_registrations
  //     rows with rank, kills, damage, headshot, prize, firebase_uid.

  static const Map<String, bool> defaultNotificationPrefs = {
    'reminders': true,
    'match_alerts': true,
    'team_invites': true,
    'results': true,
    'announcements': true,
    'community': true,
  };

  /// Notification prefs from profiles.notification_prefs (017). On ANY
  /// error — column missing (017 not applied), no profile row, bad
  /// json — returns all-true defaults. Stored keys override defaults;
  /// unknown stored keys are kept; non-bool values are ignored.
  static Future<Map<String, bool>> getNotificationPrefs(String uid) async {
    try {
      final row = await getRow('profiles', 'firebase_uid', uid);
      final stored = asMap(row['notification_prefs']);
      final prefs = Map<String, bool>.from(defaultNotificationPrefs);
      for (final e in stored.entries) {
        if (e.value is bool) prefs[e.key.toString()] = e.value as bool;
      }
      return prefs;
    } catch (_) {
      return Map<String, bool>.from(defaultNotificationPrefs);
    }
  }

  /// Server update of profiles.notification_prefs. Returns false (not
  /// throw) on failure — e.g. column missing (017 not applied).
  static Future<bool> updateNotificationPrefs(String uid, Map<String, bool> prefs) async {
    try {
      await client.from('profiles').update({'notification_prefs': prefs}).eq('firebase_uid', uid);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Community Points ledger rows (018), newest first. [] on error
  /// (table not applied yet / RLS without 024 policies).
  static Future<List<Map<String, dynamic>>> getPointsLedger(String uid) async {
    return getList('community_points_ledger', eqCol: 'firebase_uid', eqVal: uid, orderBy: 'created_at', ascending: false);
  }

  /// SUM(delta) over the caller's ledger rows. 0 on error.
  static Future<int> getPointsTotal(String uid) async {
    try {
      final rows = await client.from('community_points_ledger').select('delta').eq('firebase_uid', uid);
      var total = 0;
      for (final r in (rows as List)) {
        total += intOf((r as Map)['delta']);
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  /// Challenge definitions (018). [] on error.
  static Future<List<Map<String, dynamic>>> getChallenges() async {
    return getList('challenges', orderBy: 'created_at', ascending: true);
  }

  /// Achievement definitions (018). [] on error.
  static Future<List<Map<String, dynamic>>> getAchievements() async {
    return getList('achievements', orderBy: 'created_at', ascending: true);
  }

  /// The caller's unlocked achievements (018), newest first. [] on error.
  static Future<List<Map<String, dynamic>>> getMyAchievements(String uid) async {
    return getList('user_achievements', eqCol: 'firebase_uid', eqVal: uid, orderBy: 'unlocked_at', ascending: false);
  }

  /// The caller's challenge_progress rows for one period (018).
  /// [] on error.
  static Future<List<Map<String, dynamic>>> getChallengeProgress(String uid, String periodKey) async {
    return getList('challenge_progress', eqCol: 'firebase_uid', eqVal: uid, eqCol2: 'period_key', eqVal2: periodKey, orderBy: 'created_at', ascending: false);
  }

  /// Claim a Community Points reward via RPC claim_reward (022).
  /// Returns the RPC jsonb ({reward_key, period_key, points,
  /// total_points}) plus 'ok': true on success. On failure returns
  /// `{'ok': false, 'error': message}` — NEVER an invented success.
  static Future<Map<String, dynamic>> claimReward(String rewardKey, String periodKey) async {
    try {
      final res = await client.rpc('claim_reward', params: {'p_reward_key': rewardKey, 'p_period_key': periodKey});
      return {...asMap(res), 'ok': true};
    } catch (e) {
      return {'ok': false, 'error': e.toString()};
    }
  }

  /// Referral milestones (019). [] on error (table not applied yet).
  static Future<List<Map<String, dynamic>>> getReferralMilestones() async {
    return getList('referral_milestones', orderBy: 'milestone_friends', ascending: true);
  }

  /// The caller's sent invites: LIVE pending_referrals rows (001)
  /// where referrer_uid = uid, newest first.
  static Future<List<Map<String, dynamic>>> getMyInvites(String uid) async {
    return getList('pending_referrals', eqCol: 'referrer_uid', eqVal: uid, orderBy: 'created_at', ascending: false);
  }

  /// Support thread for one ticket (019), oldest first. [] on error
  /// (table not applied yet).
  static Future<List<Map<String, dynamic>>> getTicketThread(String ticketId) async {
    return getList('support_messages', eqCol: 'ticket_id', eqVal: ticketId, orderBy: 'created_at', ascending: true);
  }

  /// Reply to a support ticket: insert into support_messages (019)
  /// as sender_id = current Firebase UID, sender_role 'user'.
  /// Returns false on failure (table not applied / not signed in /
  /// empty message) — never throws.
  static Future<bool> sendTicketReply(String ticketId, String message) async {
    if (message.trim().isEmpty) return false;
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return false;
      await client.from('support_messages').insert({
        'ticket_id': ticketId,
        'sender_id': user.uid,
        'sender_role': 'user',
        'message': message.trim(),
      });
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Mark a support ticket resolved (user action). Returns false on
  /// failure — never throws.
  static Future<bool> markTicketResolved(String ticketId) async {
    try {
      await client.from('support_tickets').update({'status': 'resolved'}).eq('id', ticketId);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Users this uid blocked: LIVE blocked_users rows (008) where
  /// blocker_uid = uid. [] on error.
  static Future<List<Map<String, dynamic>>> getBlockedUsers(String uid) async {
    return getList('blocked_users', eqCol: 'blocker_uid', eqVal: uid);
  }

  /// Remove one block. Returns true ONLY if a row was actually
  /// deleted; false on failure or when no such row existed.
  static Future<bool> unblockUser(String uid, String blockedUid) async {
    try {
      final res = await client.from('blocked_users').delete().eq('blocker_uid', uid).eq('blocked_uid', blockedUid);
      return res is List && res.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Tournament results from tournament_registrations (live table),
  /// ordered by rank ascending, nulls last (unranked rows last).
  /// Columns verified against MatchSummaryPage (pro_features.dart):
  /// rank, kills, damage, headshot, prize, firebase_uid, username,
  /// team_name. [] on error.
  /// P1-10 — rows for TournamentResultsPage: the registration rows
  /// (rank, kills, prize) PLUS the real points persisted at approve
  /// time on the matching tournament_results row, merged by
  /// firebase_uid via [mergeResultPoints]. tournament_registrations
  /// has no points column (verified on staging), so the points can
  /// only come from here; unapproved results (or a failed merge)
  /// honestly read 0. The page renders `r['team_points']` — see
  /// home_screens.dart TournamentResultsPage.
  static Future<List<Map<String, dynamic>>> getResultsForTournament(String tournamentId) async {
    try {
      final rows = await client.from('tournament_registrations').select().eq('tournament_id', tournamentId).order('rank', ascending: true, nullsFirst: false);
      final regs = (rows as List).map((r) => Map<String, dynamic>.from(r as Map)).toList();
      try {
        final results = await getList('tournament_results', eqCol: 'tournament_id', eqVal: tournamentId, limit: 1000);
        mergeResultPoints(regs, results);
      } catch (_) {
        for (final reg in regs) {
          reg.putIfAbsent('team_points', () => 0);
          reg.putIfAbsent('placement_points', () => 0);
          reg.putIfAbsent('kill_points', () => 0);
        }
      }
      return regs;
    } catch (_) {
      return [];
    }
  }

  /// Submit a match result via RPC record_match_result (022).
  /// Returns the RPC jsonb ({tournament_id, firebase_uid, status,
  /// placement, placement_points, kill_points, team_points, kills,
  /// assists, damage, duration_seconds}) plus 'ok': true on success;
  /// `{'ok': false, 'error': message}` on failure. No fallback to
  /// any direct write inside this method.
  /// NOTE: imageUrl is accepted for call-site compatibility but NOT
  /// sent — record_match_result (022) has no image parameter.
  /// Screenshot evidence stays on the existing
  /// tournament_results.image_url flow (submitResult).
  static Future<Map<String, dynamic>> submitMatchResult({
    required String tournamentId,
    required int placement,
    required int kills,
    required int assists,
    required int damage,
    required int duration,
    required String notes,
    String? imageUrl,
  }) async {
    try {
      final res = await client.rpc('record_match_result', params: {
        'p_tournament_id': tournamentId,
        'p_placement': placement,
        'p_kills': kills,
        'p_assists': assists,
        'p_damage': damage,
        'p_duration': duration,
        'p_notes': notes,
        // Phase 4: the RPC stores the screenshot URL in
        // tournament_results.image_url (022). NULL = no screenshot.
        'p_image_url': imageUrl,
      });
      return {...asMap(res), 'ok': true};
    } catch (e) {
      return {'ok': false, 'error': e.toString()};
    }
  }

  /// Period key for challenge_progress / reward claims (018):
  /// daily -> 'YYYY-MM-DD'; weekly -> 'YYYY-Www' with the ISO-8601
  /// week number (week 1 = the week containing Jan 4; e.g.
  /// 2026-11-19 -> '2026-W47', matching the 018 draft example).
  /// Any period other than 'weekly' falls back to the daily key.
  static String periodKeyFor(DateTime date, String period) {
    if (period == 'weekly') {
      final d = DateTime(date.year, date.month, date.day);
      // Thursday of this week fixes the ISO week-numbering year.
      final thursday = d.add(Duration(days: 4 - d.weekday));
      final weekYear = thursday.year;
      final jan4 = DateTime(weekYear, 1, 4);
      final week1Monday = jan4.subtract(Duration(days: jan4.weekday - 1));
      final week = (thursday.difference(week1Monday).inDays ~/ 7) + 1;
      return '$weekYear-W${week.toString().padLeft(2, '0')}';
    }
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }
}
