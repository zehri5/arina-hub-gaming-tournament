import 'dart:convert';
import 'dart:math';

import 'package:firebase_auth/firebase_auth.dart';

import 'admin_db.dart';
import 'supabase_db.dart';

/// W2 data layer — Dashboard + Tournaments + Matches (O-admin-panel).
///
/// All admin reads go through [AdminDb.getList]/[AdminDb.getRow]; all
/// writes are DIRECT-WRITEs (024-enforced) issued here via
/// [SupaDb.client] — never from a widget — and every write is paired
/// with an [AdminDb.logAdminActivity] row in the same action.
/// [SupaDb] itself is NOT forked and no user-facing method is changed.
///
/// Audit values: W1's [AdminDb.logAdminActivity] takes `oldValue` /
/// `newValue` as Strings, so maps are passed JSON-encoded (valid in a
/// jsonb column as a string scalar, and valid in a text column).
///
/// Fetch cap: PostgREST pages at 1000 rows by default, so counts are
/// computed over at most the latest 1000 rows and the dashboard says
/// so honestly ("1000+") when the cap is hit. No count RPC exists.
class AdminDbTournaments {
  static const int _cap = 1000;

  static String? _auditJson(Map<String, dynamic>? m) =>
      m == null ? null : jsonEncode(m);

  /// Recent rows, newest first. `created_at` ordering is retried
  /// without an order when the table has no `created_at` column
  /// (a failed order reads as [] under the guarded getList).
  static Future<List<Map<String, dynamic>>> _recent(
    String table, {
    Map<String, dynamic>? eq,
    int limit = 10,
  }) async {
    var rows = await AdminDb.getList(
      table,
      eq: eq,
      orderBy: 'created_at',
      ascending: false,
      limit: limit,
    );
    if (rows.isEmpty) {
      rows = await AdminDb.getList(table, eq: eq, limit: limit);
    }
    return rows;
  }

  // ---------- dashboard ----------

  /// One aggregated read per KPI set (plan §4.2 #19).
  /// Keys: totalPlayers, playersCapped, pendingCount, upcomingCount,
  /// liveCount, completedCount, totalTournaments, totalRegistrations,
  /// recentRegistrations, recentActivity, signups7 (`List<int>`),
  /// signupLabels (`List<String>`), signupDays (`List<DateTime>`).
  static Future<Map<String, dynamic>> getDashboardStats() async {
    final profiles = await AdminDb.getList(
      'profiles',
      orderBy: 'created_at',
      ascending: false,
      limit: _cap,
    );
    final tournaments = await AdminDb.getList(
      'tournaments',
      orderBy: 'start_time',
      ascending: false,
      limit: _cap,
    );
    final regs = await _recent('tournament_registrations', limit: 10);
    final activity = await _recent('admin_activity_logs', limit: 15);

    var pending = 0, upcoming = 0, live = 0, completed = 0;
    for (final t in tournaments) {
      switch (SupaDb.strOf(t['status']).toLowerCase()) {
        case 'pending':
        case 'draft':
          pending++;
          break;
        case 'upcoming':
          upcoming++;
          break;
        case 'ongoing':
        case 'live':
          live++;
          break;
        case 'completed':
          completed++;
          break;
      }
    }

    // Signups per day, last 7 days (local days, oldest first).
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final counts = List<int>.filled(7, 0);
    final labels = <String>[];
    const weekday = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    for (var i = 6; i >= 0; i--) {
      final d = today.subtract(Duration(days: i));
      labels.add('${weekday[d.weekday - 1]} ${d.day}/${d.month}');
    }
    for (final p in profiles) {
      final ts = SupaDb.parseTs(p['created_at']);
      if (ts <= 0) continue;
      final d = DateTime.fromMillisecondsSinceEpoch(ts);
      final day = DateTime(d.year, d.month, d.day);
      final diff = today.difference(day).inDays;
      if (diff >= 0 && diff < 7) counts[6 - diff]++;
    }

    return {
      'totalPlayers': profiles.length,
      'playersCapped': profiles.length >= _cap,
      'pendingCount': pending,
      'upcomingCount': upcoming,
      'liveCount': live,
      'completedCount': completed,
      'totalTournaments': tournaments.length,
      'totalRegistrations': await _registrationTotal(),
      'recentRegistrations': regs,
      'recentActivity': activity,
      'signups7': counts,
      'signupLabels': labels,
    };
  }

  static Future<int> _registrationTotal() async {
    final rows = await AdminDb.getList('tournament_registrations', limit: _cap);
    return rows.length;
  }

  /// Pure-Dart CSV of the dashboard summary (no package).
  static String dashboardCsv(Map<String, dynamic> stats) {
    String esc(dynamic v) {
      final s = v.toString();
      return s.contains(',') || s.contains('"') || s.contains('\n')
          ? '"${s.replaceAll('"', '""')}"'
          : s;
    }

    final b = StringBuffer();
    b.writeln('ARENA HUB Admin Dashboard,${DateTime.now().toIso8601String()}');
    b.writeln('Metric,Value');
    b.writeln('Total players,${esc(stats['totalPlayers'] ?? 0)}');
    b.writeln('Tournaments pending approval,${esc(stats['pendingCount'] ?? 0)}');
    b.writeln('Tournaments upcoming,${esc(stats['upcomingCount'] ?? 0)}');
    b.writeln('Tournaments live,${esc(stats['liveCount'] ?? 0)}');
    b.writeln('Tournaments completed,${esc(stats['completedCount'] ?? 0)}');
    b.writeln('Total tournaments,${esc(stats['totalTournaments'] ?? 0)}');
    b.writeln('Total registrations,${esc(stats['totalRegistrations'] ?? 0)}');
    b.writeln();
    b.writeln('New players last 7 days');
    b.writeln('Day,Signups');
    final labels = (stats['signupLabels'] as List?) ?? const [];
    final counts = (stats['signups7'] as List?) ?? const [];
    for (var i = 0; i < labels.length && i < counts.length; i++) {
      b.writeln('${esc(labels[i])},${esc(counts[i])}');
    }
    b.writeln();
    b.writeln('Recent activity');
    b.writeln('Action,Target type,Target id,Time');
    for (final a in (stats['recentActivity'] as List?) ?? const []) {
      final m = SupaDb.asMap(a);
      b.writeln(
        '${esc(m['action'])},${esc(m['target_type'])},${esc(m['target_id'])},${esc(m['created_at'])}',
      );
    }
    return b.toString();
  }

  // ---------- tournaments ----------

  /// Admin tournament list (plan §4.2 #11). Client-side filters:
  /// [status] ('' = all), [gameId] ('' = all), [query] matches name /
  /// game name, case-insensitive. Newest start first.
  static Future<List<Map<String, dynamic>>> getTournamentsAdmin({
    String status = '',
    String gameId = '',
    String query = '',
  }) async {
    final rows = await AdminDb.getList(
      'tournaments',
      orderBy: 'start_time',
      ascending: false,
      limit: _cap,
    );
    final q = query.trim().toLowerCase();
    return rows
        .map(SupaDb.normTournament)
        .where((t) {
          if (status.isNotEmpty &&
              SupaDb.strOf(t['status']).toLowerCase() != status) {
            return false;
          }
          if (gameId.isNotEmpty && SupaDb.strOf(t['gameId']) != gameId) {
            return false;
          }
          if (q.isNotEmpty) {
            final hay =
                '${SupaDb.strOf(t['name'])} ${SupaDb.strOf(t['gameName'])}'
                    .toLowerCase();
            if (!hay.contains(q)) return false;
          }
          return true;
        })
        .toList();
  }

  /// Games for the create/edit game dropdown — real `games` rows only
  /// (no invented entries; an empty table = an empty dropdown).
  static Future<List<Map<String, dynamic>>> getGamesForAdmin() =>
      SupaDb.getGamesForPicker();

  /// Registration counts per tournament id (one capped read, counted
  /// client-side) — used by the Matches slot display.
  static Future<Map<String, int>> registrationCounts() async {
    final rows = await AdminDb.getList('tournament_registrations', limit: _cap);
    final counts = <String, int>{};
    for (final r in rows) {
      final tid = SupaDb.strOf(r['tournament_id']);
      if (tid.isEmpty) continue;
      counts[tid] = (counts[tid] ?? 0) + 1;
    }
    return counts;
  }

  // ---------- create / edit (DIRECT-WRITE + audit) ----------

  /// Columns guaranteed by migrations 001 + 010 — the pre-029 fallback
  /// (same retry ladder as the N create form in pro_features.dart).
  static Map<String, dynamic> _coreRow(Map<String, dynamic> row) => {
        'name': row['name'],
        'game_name': row['game_name'],
        'game_id': row['game_id'],
        'mode': row['mode'],
        'entry_fee': row['entry_fee'],
        'prize_pool': row['prize_pool'],
        'max_players': row['max_players'],
        'status': row['status'],
        'start_time': row['start_time'],
        'created_by': row['created_by'],
        'tags': row['tags'],
      };

  /// DIRECT-WRITE: create a tournament + audit row. Retries like the N
  /// form: full row → core columns (PGRST204) → status 'draft' (CHECK).
  /// Returns {'ok', 'error'?, 'full', 'row'?, 'bannerSaved',
  /// 'extendedSaved'}.
  ///
  /// BANNER RESTORE (2026-11-20): a pre-029 DB rejects the full row
  /// (registration_deadline / map / rules / commission_pct do not
  /// exist yet) and the core retry drops EVERY extended field —
  /// including banner_url, which IS a base column (production rows
  /// carry it). So after a core-only insert, each extended field is
  /// restored one at a time, best-effort, so one unknown column
  /// cannot block the rest — the banner the admin just uploaded
  /// survives even on a pre-029 DB. `bannerSaved` / `extendedSaved`
  /// tell the caller honestly what landed.
  static Future<Map<String, dynamic>> createTournament(
    Map<String, dynamic> row,
  ) async {
    var attempt = Map<String, dynamic>.from(row);
    var triedCore = false;
    var triedDraft = false;
    var full = true;
    for (var i = 0; i < 3; i++) {
      try {
        final inserted = await SupaDb.client
            .from('tournaments')
            .insert(attempt)
            .select()
            .limit(1)
            .maybeSingle();
        final id = inserted == null
            ? ''
            : SupaDb.strOf((inserted as Map)['id']);
        var bannerSaved = full;
        var extendedSaved = 0;
        if (!full && id.isNotEmpty) {
          // Core-only insert: restore the dropped extended fields
          // one by one (best-effort) — banner first, then the rest.
          final extended = <String, dynamic>{
            'banner_url': row['banner_url'],
            'description': row['description'],
            'rules': row['rules'],
            'map': row['map'],
            'level_required': row['level_required'],
            'per_kill_prize': row['per_kill_prize'],
            'registration_deadline': row['registration_deadline'],
            'lobby_opens_at': row['lobby_opens_at'],
            'commission_pct': row['commission_pct'],
            'watch_live_url': row['watch_live_url'],
            // FIX 7 (2026-11-22): show_watch_live IS restored
            // now — the column exists on A1 (live-probed). The
            // v2013 guard that skipped it would drop the flag
            // on a core-only insert. (The loop below skips null
            // / empty-String values only, so a false flag still
            // restores — toggling live OFF persists too.)
            'show_watch_live': row['show_watch_live'],
            // F16 (2026-11-22): perspective / team_mode / game_mode /
            // end_time / duration_minutes (047/069) — without these
            // a core-only insert silently drops the MATCH INFO
            // columns and the detail screen shows '—' again.
            'perspective': row['perspective'],
            'team_mode': row['team_mode'],
            'game_mode': row['game_mode'],
            'end_time': row['end_time'],
            'duration_minutes': row['duration_minutes'],
          };
          for (final e in extended.entries) {
            final v = e.value;
            if (v == null || (v is String && v.isEmpty)) continue;
            try {
              await SupaDb.client
                  .from('tournaments')
                  .update({e.key: v})
                  .eq('id', id);
              extendedSaved++;
              if (e.key == 'banner_url') bannerSaved = true;
            } catch (_) {
              // This column does not exist on this DB — the
              // tournament itself is still created; the caller
              // reports the missing fields honestly.
            }
          }
        }
        await AdminDb.logAdminActivity(
          action: 'tournament_create',
          targetType: 'tournament',
          targetId: id,
          newValue: _auditJson({'name': row['name'], 'status': attempt['status']}),
        );
        return {
          'ok': true,
          'full': full,
          'row': inserted,
          'bannerSaved': bannerSaved,
          'extendedSaved': extendedSaved,
        };
      } catch (e) {
        final s = e.toString();
        final unknownCol = s.contains('PGRST204') ||
            (s.contains('Could not find') && s.contains('column'));
        final statusCheck =
            s.contains('check constraint') || s.contains('violates check');
        if (unknownCol && !triedCore) {
          triedCore = true;
          full = false;
          attempt = _coreRow(row);
          continue;
        }
        if (statusCheck && !triedDraft) {
          triedDraft = true;
          attempt = Map<String, dynamic>.from(attempt)..['status'] = 'draft';
          continue;
        }
        return {'ok': false, 'error': s};
      }
    }
    return {'ok': false, 'error': 'Create failed after retries.'};
  }

  /// DIRECT-WRITE: update a tournament + audit row. Returns
  /// {'ok', 'error'?} — plus 'partial': true when the DB rejected
  /// the full update (unknown 029 column) and only the base columns
  /// + banner_url were saved.
  ///
  /// BANNER FIX (2026-11-20): on a pre-029 DB the edit form's full
  /// update (registration_deadline / map / rules / ...) fails whole
  /// with PGRST204, so even a banner-only edit could never save.
  /// The retry below keeps only the guaranteed base columns
  /// (001 + 010, same set as [_coreRow]) plus banner_url — a base
  /// column in production — so the banner edit lands and the caller
  /// can report the dropped fields honestly instead of failing.
  static Future<Map<String, dynamic>> updateTournament(
    String id,
    Map<String, dynamic> values, {
    Map<String, dynamic>? oldValues,
  }) async {
    var saved = values;
    var partial = false;
    var extendedRestored = 0;
    try {
      await SupaDb.client.from('tournaments').update(values).eq('id', id);
    } catch (e) {
      final s = e.toString();
      final unknownCol = s.contains('PGRST204') ||
          (s.contains('Could not find') && s.contains('column'));
      if (!unknownCol) return {'ok': false, 'error': s};
      const baseKeys = {
        'name',
        'game_name',
        'game_id',
        'mode',
        'entry_fee',
        'prize_pool',
        'max_players',
        'status',
        'start_time',
        'created_by',
        'tags',
        'banner_url',
      };
      final reduced = <String, dynamic>{};
      for (final k in baseKeys) {
        if (values.containsKey(k)) reduced[k] = values[k];
      }
      if (reduced.isEmpty) return {'ok': false, 'error': s};
      try {
        await SupaDb.client.from('tournaments').update(reduced).eq('id', id);
      } catch (e2) {
        return {'ok': false, 'error': e2.toString()};
      }
      saved = reduced;
      partial = true;
      // F16 (2026-11-22): the reduced update drops every extended
      // field — restore each one individually, best-effort, like
      // createTournament does, so a pre-047/069 DB keeps whatever
      // columns it actually has (incl. perspective / team_mode /
      // game_mode / end_time / duration_minutes) instead of losing
      // them all silently. One unknown column cannot block the rest.
      const extendedKeys = {
        'description',
        'rules',
        'map',
        'level_required',
        'per_kill_prize',
        'registration_deadline',
        'lobby_opens_at',
        'commission_pct',
        'watch_live_url',
        // FIX 7 (2026-11-22): show_watch_live IS restored now —
        // the column exists on A1 (live-probed). The v2013 guard
        // that skipped it would drop the flag on a partial save.
        'show_watch_live',
        'perspective',
        'team_mode',
        'game_mode',
        'end_time',
        'duration_minutes',
      };
      for (final k in extendedKeys) {
        if (!values.containsKey(k)) continue;
        final v = values[k];
        if (v == null || (v is String && v.isEmpty)) continue;
        try {
          await SupaDb.client
              .from('tournaments')
              .update({k: v})
              .eq('id', id);
          extendedRestored++;
        } catch (_) {}
      }
    }
    await AdminDb.logAdminActivity(
      action: 'tournament_update',
      targetType: 'tournament',
      targetId: id,
      oldValue: _auditJson(oldValues),
      newValue: _auditJson(saved),
    );
    return {
      'ok': true,
      if (partial) 'partial': true,
      if (partial) 'extendedRestored': extendedRestored,
    };
  }

  /// DIRECT-WRITE: status change (publish / cancel / complete) + audit.
  static Future<Map<String, dynamic>> setTournamentStatus(
    String id,
    String status, {
    String? oldStatus,
  }) async {
    try {
      await SupaDb.client
          .from('tournaments')
          .update({'status': status})
          .eq('id', id);
    } catch (e) {
      return {'ok': false, 'error': e.toString()};
    }
    await AdminDb.logAdminActivity(
      action: 'tournament_status',
      targetType: 'tournament',
      targetId: id,
      oldValue: _auditJson(
        oldStatus == null ? null : {'status': oldStatus},
      ),
      newValue: _auditJson({'status': status}),
    );
    return {'ok': true};
  }

  /// Deletes one tournament's child rows (registrations +
  /// submitted results + waitlist / check-in / reminder / chat /
  /// voice rows — the last five used to survive as orphans, audit
  /// fix 2026-11-21). Returns counts; extra-table failures are
  /// swallowed (a missing table must not block the delete) but the
  /// core registrations/results deletes still throw (see
  /// [deleteTournament]).
  static Future<Map<String, int>> _deleteTournamentChildren(String id) async {
    final regs = await SupaDb.client
        .from('tournament_registrations')
        .delete()
        .eq('tournament_id', id)
        .select('id');
    final results = await SupaDb.client
        .from('tournament_results')
        .delete()
        .eq('tournament_id', id)
        .select('id');
    var extra = 0;
    Future<void> wipe(String table, String col, String val) async {
      try {
        final r = await SupaDb.client
            .from(table)
            .delete()
            .eq(col, val)
            .select('id');
        extra += (r as List).length;
      } catch (_) {}
    }

    await wipe('waitlists', 'tournament_id', id);
    await wipe('match_checkins', 'tournament_id', id);
    await wipe('match_reminders', 'tournament_id', id);
    await wipe('chat_messages', 'tournament_id', id);
    // Voice peers live under the derived room id (squad.dart:
    // tournamentRoomId == 'tournament_<id>').
    await wipe('voice_signaling_peers', 'room_id', 'tournament_$id');
    return {
      'registrations': (regs as List).length,
      'results': (results as List).length,
      'extra': extra,
    };
  }

  /// DIRECT-WRITE: delete a tournament + audit row. (User order
  /// 2026-11-20: admin panel mein tournament DELETE option lazmi,
  /// confirm ke saath.) Returns {'ok', 'error'?, 'registrations',
  /// 'results', 'alreadyGone'?, 'childError'?}.
  ///
  /// What is deleted, honestly:
  /// * the tournaments row itself;
  /// * ALL tournament_registrations rows for it — NO refund: a PAID
  ///   registration's entry fee is NOT refunded here; the admin must
  ///   handle refunds via the Cash screens first (same rule as
  ///   [removeRegistration]);
  /// * ALL tournament_results rows for it (submitted / approved /
  ///   rejected — this tournament's result history is gone).
  /// What is NOT deleted: match_history rows (player stats history
  /// stays — a played match remains in the player's record) and
  /// user_notifications (plain text rows, no tournament FK). The
  /// 026 room_controls row cascades automatically (ON DELETE
  /// CASCADE).
  ///
  /// Ordering is deliberate: the tournament row goes FIRST, so a
  /// foreign-key block aborts before any child row is touched. If
  /// the row delete fails with an FK violation (a child table
  /// references tournaments without cascade), the children are
  /// deleted first and the row delete retried — if the retry still
  /// fails, the error return carries the child counts so the caller
  /// can say exactly what was already deleted. If the row was
  /// already gone, the call still cleans up orphan children and
  /// returns ok with 'alreadyGone': true (so a retry after a
  /// half-finished delete works). A child-delete failure AFTER the
  /// row is gone cannot undo the delete — it returns ok with
  /// 'childError' naming the orphaned rows.
  static Future<Map<String, dynamic>> deleteTournament(
    String id, {
    String? name,
  }) async {
    Map<String, dynamic>? old;
    try {
      old = await AdminDb.getRow('tournaments', 'id', id);
    } catch (_) {
      old = null;
    }
    final tName = name ??
        (old == null ? '' : SupaDb.strOf(old['name']));
    final oldStatus = old == null ? '' : SupaDb.strOf(old['status']);

    Future<Map<String, dynamic>> auditAndReturn({
      required bool ok,
      String? error,
      int registrations = 0,
      int results = 0,
      bool alreadyGone = false,
      String? childError,
    }) async {
      await AdminDb.logAdminActivity(
        action: ok ? 'tournament_delete' : 'tournament_delete_failed',
        targetType: 'tournament',
        targetId: id,
        oldValue: _auditJson({
          'name': tName,
          'status': oldStatus,
          'registrations_deleted': registrations,
          'results_deleted': results,
          if (error != null) 'error': error,
        }),
      );
      return {
        'ok': ok,
        if (error != null) 'error': error,
        'registrations': registrations,
        'results': results,
        if (alreadyGone) 'alreadyGone': true,
        if (childError != null) 'childError': childError,
      };
    }

    // Step 1: the tournament row itself, first.
    List<dynamic> deletedRows;
    try {
      deletedRows = await SupaDb.client
          .from('tournaments')
          .delete()
          .eq('id', id)
          .select('id') as List<dynamic>;
    } catch (e) {
      final s = e.toString();
      final fkBlock = s.contains('23503') ||
          s.toLowerCase().contains('foreign key');
      if (!fkBlock) return {'ok': false, 'error': s};
      // FK block: children reference the tournament without
      // cascade — delete them first, then retry the row.
      Map<String, int> counts;
      try {
        counts = await _deleteTournamentChildren(id);
      } catch (e2) {
        return {'ok': false, 'error': e2.toString()};
      }
      try {
        deletedRows = await SupaDb.client
            .from('tournaments')
            .delete()
            .eq('id', id)
            .select('id') as List<dynamic>;
      } catch (e2) {
        // Children are gone but the tournament row survived
        // (e.g. a match_history FK without cascade) — say so
        // exactly, with counts, instead of a bare failure.
        return await auditAndReturn(
          ok: false,
          error: e2.toString(),
          registrations: counts['registrations'] ?? 0,
          results: counts['results'] ?? 0,
        );
      }
      if (deletedRows.isEmpty) {
        return await auditAndReturn(
          ok: true,
          registrations: counts['registrations'] ?? 0,
          results: counts['results'] ?? 0,
          alreadyGone: true,
        );
      }
      return await auditAndReturn(
        ok: true,
        registrations: counts['registrations'] ?? 0,
        results: counts['results'] ?? 0,
      );
    }

    // Step 2: the row is gone (or was already gone) — clean up
    // its children. A failure here cannot undo the delete.
    final alreadyGone = deletedRows.isEmpty;
    try {
      final counts = await _deleteTournamentChildren(id);
      return await auditAndReturn(
        ok: true,
        registrations: counts['registrations'] ?? 0,
        results: counts['results'] ?? 0,
        alreadyGone: alreadyGone,
      );
    } catch (e) {
      return await auditAndReturn(
        ok: true,
        alreadyGone: alreadyGone,
        childError: e.toString(),
      );
    }
  }

  /// Delete a game — GUARDED: refused when any tournament still
  /// references it (game_id), because deleting would orphan those
  /// tournaments' game link. Delete (or move) the tournaments
  /// first, or deactivate the game instead (the normal path —
  /// deactivation is what the Games screen offered before this
  /// delete existed). Returns {'ok', 'error'?, 'alreadyGone'?}.
  /// NOTE: game create/update/toggle live in the admin APK's growth
  /// service (removed from the user app in FIX 32); this delete
  /// lives here because it needs the tournaments table for the
  /// reference guard.
  static Future<Map<String, dynamic>> deleteGame(
    String id, {
    String? name,
  }) async {
    try {
      final old = await AdminDb.getRow('games', 'id', id);
      if (old == null) return {'ok': true, 'alreadyGone': true};
      final refs = await AdminDb.getList(
        'tournaments',
        eq: {'game_id': id},
        limit: 1,
      );
      if (refs.isNotEmpty) {
        return {
          'ok': false,
          'error':
              'Game delete nahi ho sakta — is se jura hua tournament abhi maujood hai. Pehle wo tournament delete karein, ya game ko deactivate karein.',
        };
      }
      await SupaDb.client.from('games').delete().eq('id', id);
      final gone = await AdminDb.getRow('games', 'id', id) == null;
      if (!gone) {
        return {
          'ok': false,
          'error':
              'Delete refuse ho gaya — game abhi bhi maujood hai (shayad permission/RLS issue hai).'
        };
      }
      await AdminDb.logAdminActivity(
        action: 'game_delete',
        targetType: 'game',
        targetId: id,
        oldValue: _auditJson({'name': SupaDb.strOf(old['name'], name ?? '')}),
      );
      return {'ok': true};
    } catch (e) {
      return {'ok': false, 'error': e.toString()};
    }
  }

  // ---------- tournament detail ----------

  /// Detail bundle: normalized tournament + registrations + results
  /// (tournament_results) + ranked registrations + match_history rows.
  /// Read-only; `match_history` may be [] when the table has no
  /// `tournament_id` column (guarded read).
  static Future<Map<String, dynamic>> getTournamentDetail(String id) async {
    final t = await SupaDb.getTournament(id);
    final regs = await SupaDb.getRegistrations(id);
    final results = await SupaDb.getTournamentResults(id);
    final ranked = await SupaDb.getResultsForTournament(id);
    final history = await AdminDb.getList(
      'match_history',
      eq: {'tournament_id': id},
      orderBy: 'played_at',
      ascending: false,
      limit: 50,
    );
    return {
      'tournament': t,
      'registrations': regs,
      'results': results,
      'ranked': ranked,
      'matchHistory': history.map(SupaDb.normMatchHistory).toList(),
    };
  }

  /// Probe: does `tournament_registrations` have a `status` column?
  /// The join flow never writes one and no migration in this copy
  /// defines it — the Players tab shows approve/pending controls only
  /// when this is true, and says so honestly otherwise.
  static Future<bool> registrationsHaveStatus() async {
    try {
      await SupaDb.client
          .from('tournament_registrations')
          .select('id,status')
          .limit(1);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// DIRECT-WRITE: per-registration approve/pending + audit.
  /// Only called when [registrationsHaveStatus] is true.
  static Future<Map<String, dynamic>> setRegistrationStatus(
    String registrationId,
    String tournamentId,
    String playerUid,
    String status,
  ) async {
    try {
      await SupaDb.client
          .from('tournament_registrations')
          .update({'status': status})
          .eq('id', registrationId);
    } catch (e) {
      return {'ok': false, 'error': e.toString()};
    }
    await AdminDb.logAdminActivity(
      action: 'registration_status',
      targetType: 'tournament_registration',
      targetId: '$tournamentId:$playerUid',
      newValue: _auditJson({'status': status}),
    );
    return {'ok': true};
  }

  /// DIRECT-WRITE: remove a registration + audit row. No refund logic
  /// lives here — removing a PAID registration does NOT refund the
  /// entry fee; the admin must handle refunds via the Cash screens.
  static Future<Map<String, dynamic>> removeRegistration(
    String registrationId,
    String tournamentId,
    String playerUid,
  ) async {
    Map<String, dynamic> old = {};
    try {
      final row = await AdminDb.getRow(
        'tournament_registrations',
        'id',
        registrationId,
      );
      if (row != null) {
        old = {
          'tournament_id': SupaDb.strOf(row['tournament_id']),
          'firebase_uid': SupaDb.strOf(row['firebase_uid']),
          'username': SupaDb.strOf(row['username']),
        };
      }
      await SupaDb.client
          .from('tournament_registrations')
          .delete()
          .eq('id', registrationId);
    } catch (e) {
      return {'ok': false, 'error': e.toString()};
    }
    await AdminDb.logAdminActivity(
      action: 'registration_remove',
      targetType: 'tournament_registration',
      targetId: '$tournamentId:$playerUid',
      oldValue: _auditJson(old),
    );
    return {'ok': true};
  }

  /// DIRECT-WRITE: rules + description edit + audit row.
  static Future<Map<String, dynamic>> updateTournamentRules(
    String id,
    String rules,
    String description,
  ) async {
    return updateTournament(id, {'rules': rules, 'description': description});
  }

  // ---------- announcements ----------

  /// DIRECT-WRITE (announcement): one `user_notifications` row per
  /// registered player via the existing [SupaDb.notifyUser] path, plus
  /// one audit row whose new_value carries the text — that audit row
  /// IS the announcement history (no announcements table exists).
  /// Returns {'ok', 'sent', 'total'}.
  static Future<Map<String, dynamic>> sendTournamentAnnouncement(
    String tournamentId,
    String tournamentName,
    String title,
    String message,
  ) async {
    final regs = await SupaDb.getRegistrations(tournamentId);
    final uids = <String>{};
    for (final r in regs) {
      final u = SupaDb.strOf(r['firebase_uid']);
      if (u.isNotEmpty) uids.add(u);
    }
    var sent = 0;
    for (final u in uids) {
      try {
        await SupaDb.notifyUser(u, title, message);
        sent++;
      } catch (_) {}
    }
    await AdminDb.logAdminActivity(
      action: 'tournament_announce',
      targetType: 'tournament',
      targetId: tournamentId,
      newValue: _auditJson({
        'tournament': tournamentName,
        'title': title,
        'message': message,
        'recipients': sent,
        'registered': uids.length,
      }),
    );
    return {'ok': true, 'sent': sent, 'total': uids.length};
  }

  /// Announcement history for one tournament, from the audit rows.
  static Future<List<Map<String, dynamic>>> getTournamentAnnouncements(
    String tournamentId,
  ) async {
    return AdminDb.getList(
      'admin_activity_logs',
      eq: {'action': 'tournament_announce', 'target_id': tournamentId},
      orderBy: 'created_at',
      ascending: false,
      limit: 20,
    );
  }

  // ---------- matches (plan §4.3) ----------

  /// DIRECT-WRITE: SCHEDULED room release — flips `show_id_pass`, the
  /// flag that shows the Room ID & password to players. This is NOT
  /// the A-5 Rooms load switch (voice rooms ON/OFF server-wide); the
  /// Matches screen labels the two controls apart.
  static Future<Map<String, dynamic>> setRoomRelease(
    String tournamentId,
    bool show, {
    bool? oldShow,
  }) async {
    try {
      await SupaDb.client
          .from('tournaments')
          .update({'show_id_pass': show})
          .eq('id', tournamentId);
    } catch (e) {
      return {'ok': false, 'error': e.toString()};
    }
    await AdminDb.logAdminActivity(
      action: 'match_room_release',
      targetType: 'tournament',
      targetId: tournamentId,
      oldValue: _auditJson(
        oldShow == null ? null : {'show_id_pass': oldShow},
      ),
      newValue: _auditJson({'show_id_pass': show}),
    );
    return {'ok': true};
  }

  /// DIRECT-WRITE: lobby open time (`lobby_opens_at`, ISO or null to
  /// clear) + audit row.
  static Future<Map<String, dynamic>> setLobbyOpen(
    String tournamentId,
    DateTime? lobby, {
    int oldLobbyMs = 0,
  }) async {
    try {
      await SupaDb.client
          .from('tournaments')
          .update({
            'lobby_opens_at': lobby?.toUtc().toIso8601String(),
          })
          .eq('id', tournamentId);
    } catch (e) {
      return {'ok': false, 'error': e.toString()};
    }
    await AdminDb.logAdminActivity(
      action: 'match_lobby_open',
      targetType: 'tournament',
      targetId: tournamentId,
      oldValue: _auditJson(
        oldLobbyMs == 0 ? null : {'lobby_opens_at': oldLobbyMs},
      ),
      newValue: _auditJson({
        'lobby_opens_at': lobby?.millisecondsSinceEpoch,
      }),
    );
    return {'ok': true};
  }

  /// DIRECT-WRITE: slot lock. No dedicated lock column exists, so the
  /// lock is the existing status vocabulary: locked = status 'full'
  /// (no more joins), unlocked = status 'upcoming'. Only offered from
  /// those two states; a live/completed tournament cannot be locked
  /// this way. + audit row.
  static Future<Map<String, dynamic>> setSlotsLocked(
    String tournamentId,
    bool locked, {
    String? oldStatus,
  }) async {
    return setTournamentStatus(
      tournamentId,
      locked ? 'full' : 'upcoming',
      oldStatus: oldStatus,
    );
  }

  /// Random UUID v4 (no uuid package in this project) — idempotency
  /// keys for the 050/052 RPCs. Same construction as SupaDb._newUuidV4.
  static String _newUuidV4() {
    final rnd = Random.secure();
    final bytes = List<int>.generate(16, (_) => rnd.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  /// True when [e] looks like "function does not exist" (RPC not
  /// applied yet) rather than a real authorization / data failure.
  /// (Same detection the removed admin rooms service used.)
  static bool _isMissingFunction(Object e) {
    final s = e.toString();
    return s.contains('PGRST202') ||
        s.contains('42883') ||
        s.contains('Could not find the function');
  }

  /// F11: open check-in via the live 050 `open_check_in` RPC
  /// (SECURITY DEFINER, anon EXECUTE granted; admin check inside is
  /// p_admin_uid == admin_config.admin_firebase_uid). Sets
  /// tournaments.check_in_open_at / check_in_deadline /
  /// check_in_locked=false and notifies every confirmed captain.
  /// p_match_id is NULL: there is no matches model yet (075 draft),
  /// so check-in is tournament-wide — the RPC matches rows with
  /// `match_id IS NOT DISTINCT FROM NULL`, i.e. the whole tournament.
  /// Returns {'ok', 'notified'?} or {'ok': false, 'error',
  /// 'notDeployed': true} when the RPC is not applied yet. The RPC
  /// writes its own audit/notification rows; no client audit row.
  static Future<Map<String, dynamic>> openCheckIn(
    String tournamentId,
  ) async {
    try {
      final res = await SupaDb.client.rpc('open_check_in', params: {
        'p_tournament_id': tournamentId,
        'p_match_id': null,
        'p_admin_uid': FirebaseAuth.instance.currentUser?.uid ?? '',
        'p_idempotency_key': _newUuidV4(),
      });
      final m = SupaDb.asMap(res);
      return {
        'ok': true,
        'notified': m['notified_captains'],
        'openAt': SupaDb.strOf(m['check_in_open_at']),
      };
    } catch (e) {
      return {
        'ok': false,
        'error': e.toString(),
        'notDeployed': _isMissingFunction(e),
      };
    }
  }

  /// F11: close check-in via the live 050 `close_check_in` RPC.
  /// Sets tournaments.check_in_locked=true, marks captains who never
  /// checked in as 'absent' (no-show fee forfeit + exception report),
  /// promotes waitlist entries into the freed slots. Same null
  /// p_match_id convention as [openCheckIn]. Returns `{'ok', 'data'}`
  /// (data is the raw RPC jsonb) or `{'ok': false, 'error',
  /// 'notDeployed'}`.
  static Future<Map<String, dynamic>> closeCheckIn(
    String tournamentId,
  ) async {
    try {
      final res = await SupaDb.client.rpc('close_check_in', params: {
        'p_tournament_id': tournamentId,
        'p_match_id': null,
        'p_admin_uid': FirebaseAuth.instance.currentUser?.uid ?? '',
        'p_idempotency_key': _newUuidV4(),
      });
      return {'ok': true, 'data': SupaDb.asMap(res)};
    } catch (e) {
      return {
        'ok': false,
        'error': e.toString(),
        'notDeployed': _isMissingFunction(e),
      };
    }
  }

  /// F26: schedule a timed room release via the live 052
  /// `schedule_room_release` RPC (SECURITY DEFINER, anon EXECUTE
  /// granted; admin check inside). One release per match_id (upsert
  /// by match_id — re-scheduling overwrites the pending one and
  /// clears any previous release). There is no matches model yet
  /// (075 draft) and a match IS a tournament row on this screen, so
  /// the tournament id doubles as the match id until 075 lands.
  /// The release row itself is NOT readable by the app (room_releases
  /// has no SELECT policies by design, 052 §2) — the UI reports the
  /// RPC's returned jsonb and never pretends to list schedules.
  /// Returns {'ok', 'releaseAt'?} or {'ok': false, 'error',
  /// 'notDeployed'}.
  static Future<Map<String, dynamic>> scheduleRoomRelease({
    required String tournamentId,
    required String roomId,
    required String roomPassword,
    required DateTime releaseAt,
  }) async {
    try {
      final res =
          await SupaDb.client.rpc('schedule_room_release', params: {
        'p_match_id': tournamentId,
        'p_tournament_id': tournamentId,
        'p_room_id_text': roomId,
        'p_room_password': roomPassword,
        'p_release_at': releaseAt.toUtc().toIso8601String(),
        'p_admin_uid': FirebaseAuth.instance.currentUser?.uid ?? '',
        'p_idempotency_key': _newUuidV4(),
      });
      final m = SupaDb.asMap(res);
      return {'ok': true, 'releaseAt': SupaDb.strOf(m['release_at'])};
    } catch (e) {
      return {
        'ok': false,
        'error': e.toString(),
        'notDeployed': _isMissingFunction(e),
      };
    }
  }

  /// F26: release the scheduled room NOW via the live 052
  /// `release_room` RPC. The RPC refuses when the release time has
  /// not been reached yet ('too early') or the room was already
  /// released — both surface as honest errors, never a fake success.
  /// Same tournament-id-as-match-id convention as
  /// [scheduleRoomRelease].
  static Future<Map<String, dynamic>> releaseRoomNow(
    String tournamentId,
  ) async {
    try {
      final res = await SupaDb.client.rpc('release_room', params: {
        'p_match_id': tournamentId,
        'p_admin_uid': FirebaseAuth.instance.currentUser?.uid ?? '',
        'p_idempotency_key': _newUuidV4(),
      });
      return {'ok': true, 'data': SupaDb.asMap(res)};
    } catch (e) {
      return {
        'ok': false,
        'error': e.toString(),
        'notDeployed': _isMissingFunction(e),
      };
    }
  }
}
