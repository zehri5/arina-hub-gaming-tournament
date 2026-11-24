import 'dart:math' as math;

import 'package:supabase_flutter/supabase_flutter.dart';
import '../platform/scoring/scoring_template_store.dart';
import 'supabase_db.dart';

/// Admin data layer for the W3 scope (Results + Disputes + Players +
/// Teams) — O-admin-panel round, ARENA HUB Phase 6.
///
/// NOTE ON AdminDb: worker W1's `lib/services/admin_db.dart` did NOT
/// exist when this file was written, so this layer is built directly on
/// the existing `SupaDb` primitives, using the EXACT contract the task
/// specified for AdminDb:
///   getList(table, {eq, orderBy, ascending, limit}) — via
///     SupaDb.getList (same named parameters; `eq` = eqCol/eqVal pair)
///   getRow(table, idColumn, id) — via SupaDb.getRow
///   logAdminActivity with named parameters action, targetType,
///     targetId, oldValue, newValue and reason — implemented here; ONE
///     has no admin-uid parameter, but `admin_activity_logs.admin_uid`
///     is NOT NULL, so this implementation takes a REQUIRED `adminUid`
///     named parameter. When AdminDb lands, these calls map 1:1 onto it.
/// Admin screens NEVER call Supabase directly and NEVER write a table
/// from a widget — every write below goes through this file.
///
/// WRITE PATHS (flagged per the Phase 6 plan §4.7):
/// - approve_result (023) is NOT used any more: the RPC raises
///   'result already decided' unless the row's status is exactly
///   'pending', but every live result arrives with status
///   'submitted' (SupaDb.submitResult fallback — the 022
///   record_match_result RPC is not applied yet), so Approve via the
///   RPC failed on every real row. Results are now decided through
///   the CLIENT path — SupaDb.approveMatchResult /
///   SupaDb.rejectMatchResult — the same single path the (FIX 32:
///   removed with the panel) result-review queue already used:
///   winnings computed + wallet credited exactly-once + commission
///   catch-up + leaderboard recompute + referral check. The client
///   path writes NO audit row itself, so [approveResult] logs the
///   decision here (one row per decision, plan §4.7).
/// - RPC first: resolve_dispute (071). It writes its own
///   admin_activity_logs row server-side in the same transaction as
///   the decision — no second audit insert is made here (that would
///   double-log the same decision).
/// - DIRECT-WRITE (024-enforced): restrict/restore/edit/notify player,
///   mark-dispute-reviewing, dissolve team, remove-team-member,
///   resolve-player-report. Each pairs the table write with an
///   admin_activity_logs insert in the same user action.
/// - file_dispute (023) is a PLAYER-side RPC (a player files a dispute);
///   the admin side never calls it. It is listed here only so the
///   vocabulary is complete: file_dispute writes status 'disputed' on
///   the result; resolve_dispute (071) closes the dispute as
///   'resolved' — 071 has NO overturn / points reversal (draft 071
///   open item O1, separate RPC).
///   NOTE (verified 2026-11-20): no code in this app actually calls
///   file_dispute — the live player path (DisputePage._raise) inserts
///   directly into `disputes` with status 'open'.
///
/// "Request Correction" vocabulary (plan §4.2 #2): there is no separate
/// correction status in 023. Request Correction = approve_result with
/// decision 'rejected' and reason 'correction_requested' (plus an
/// optional detail suffix after `': '` when the admin types one).
class AdminDbPeople {
  static SupabaseClient get _client => SupaDb.client;

  // ---------- audit (AdminDb contract + required adminUid) ----------

  static Future<bool> logAdminActivity({
    required String adminUid,
    required String action,
    String? targetType,
    String? targetId,
    Map<String, dynamic>? oldValue,
    Map<String, dynamic>? newValue,
    String? reason,
  }) async {
    try {
      await _client.from('admin_activity_logs').insert({
        'admin_uid': adminUid,
        'action': action,
        'target_type': targetType,
        'target_id': targetId,
        'old_value': oldValue,
        'new_value': newValue,
        'reason': reason,
      });
      return true;
    } catch (_) {
      return false;
    }
  }

  // ---------- generic reads (AdminDb contract shape) ----------

  static Future<List<Map<String, dynamic>>> getList(
    String table, {
    String? eqCol,
    dynamic eqVal,
    String? orderBy,
    bool ascending = true,
    int? limit,
  }) =>
      SupaDb.getList(
        table,
        eqCol: eqCol,
        eqVal: eqVal,
        orderBy: orderBy,
        ascending: ascending,
        limit: limit,
      );

  static Future<Map<String, dynamic>> getRow(
    String table,
    String idColumn,
    dynamic id,
  ) =>
      SupaDb.getRow(table, idColumn, id);

  /// Throwing twin of [getList] (via [SupaDb.getListOrThrow]): a
  /// failed read throws instead of returning []. Use it where
  /// "no data" and "could not load" must not be confused.
  static Future<List<Map<String, dynamic>>> getListOrThrow(
    String table, {
    String? eqCol,
    dynamic eqVal,
    String? orderBy,
    bool ascending = true,
    int? limit,
  }) =>
      SupaDb.getListOrThrow(
        table,
        eqCol: eqCol,
        eqVal: eqVal,
        orderBy: orderBy,
        ascending: ascending,
        limit: limit,
      );

  // ---------- shared lookups ----------

  /// tournament id (text) -> tournament name. Live data only.
  static Future<Map<String, String>> getTournamentNames() async {
    final rows = await getList('tournaments', limit: 500);
    final out = <String, String>{};
    for (final r in rows) {
      out[SupaDb.strOf(r['id'])] = SupaDb.strOf(r['name'], 'Tournament');
    }
    return out;
  }

  /// firebase_uid -> display name. Live data only.
  static Future<Map<String, String>> getProfileNames() async {
    final rows = await getList('profiles', limit: 500);
    final out = <String, String>{};
    for (final r in rows) {
      final uid = SupaDb.strOf(r['firebase_uid']);
      if (uid.isNotEmpty) {
        out[uid] = SupaDb.strOf(r['display_name'], 'Player');
      }
    }
    return out;
  }

  /// team id -> team name. Live data only.
  static Future<Map<String, String>> getTeamNames() async {
    final rows = await getList('teams', limit: 500);
    final out = <String, String>{};
    for (final r in rows) {
      out[SupaDb.strOf(r['id'])] = SupaDb.strOf(r['name'], 'Team');
    }
    return out;
  }

  // ---------- results ----------

  /// All tournament_results rows, oldest first (review queue order).
  /// Statuses in the live data: 'pending' (022 RPC path),
  /// 'submitted' / 're-submitted' (legacy direct-insert fallback in
  /// SupaDb.submitResult), 'approved', 'rejected'. The pending chip
  /// treats pending + submitted + re-submitted as "awaiting review".
  static Future<List<Map<String, dynamic>>> getAllResults() =>
      getList('tournament_results', orderBy: 'created_at', ascending: true, limit: 200);

  /// Throwing twin of [getAllResults]: the admin queue load uses
  /// this so a failed read shows an error instead of the empty
  /// "Koi pending result nahi" state (getList swallows errors).
  static Future<List<Map<String, dynamic>>> getAllResultsOrThrow() =>
      getListOrThrow('tournament_results', orderBy: 'created_at', ascending: true, limit: 200);

  /// Keys 'tournamentId|firebaseUid' for results under an open or
  /// in-review dispute — the "Flagged" chip. A dispute row carries
  /// (tournament_id, raised_by); a result is flagged when both match.
  static Future<Set<String>> getFlaggedResultKeys() async {
    final rows = await getList('disputes', limit: 500);
    final out = <String>{};
    for (final r in rows) {
      final s = SupaDb.strOf(r['status']);
      if (s == 'open' || s == 'under_review') {
        out.add("${SupaDb.strOf(r['tournament_id'])}|${SupaDb.strOf(r['raised_by'])}");
      }
    }
    return out;
  }

  /// The open / in-review dispute row behind each flagged key
  /// ('tournamentId|firebaseUid' -> dispute row), so a flagged
  /// result card can show WHICH dispute flags it (issue + reason +
  /// status) instead of a bare FLAGGED pill. Resolving the dispute
  /// moves it out of open/under_review, so the key — and the flag —
  /// disappears on the next reload.
  static Future<Map<String, Map<String, dynamic>>>
      getFlaggedDisputes() async {
    final rows = await getList('disputes',
        orderBy: 'created_at', ascending: false, limit: 500);
    final out = <String, Map<String, dynamic>>{};
    for (final r in rows) {
      final s = SupaDb.strOf(r['status']);
      if (s != 'open' && s != 'under_review') continue;
      final key =
          "${SupaDb.strOf(r['tournament_id'])}|${SupaDb.strOf(r['raised_by'])}";
      out.putIfAbsent(key, () => r);
    }
    return out;
  }

  /// Approve / reject one result through the CLIENT path
  /// (SupaDb.approveMatchResult / SupaDb.rejectMatchResult) — the
  /// ONE working approve path (unified 2026-11-20; the 023
  /// approve_result RPC is retired — it raises 'result already
  /// decided' on every 'submitted' row, which is every live row).
  /// [decision] must be 'approved' or 'rejected'. 'rejected' with a
  /// reason starting 'correction_requested' IS Request Correction:
  /// the player is notified with the detail and can re-submit
  /// (submitResult upserts a rejected row back to 'submitted'; only
  /// an APPROVED result is final).
  ///
  /// Approve runs everything downstream: winnings computed (kills x
  /// per-kill + placement bonus), wallet credited exactly-once,
  /// commission catch-up, result -> 'approved', leaderboard
  /// recomputed from approved results (SupaDb.matchPoints), referral
  /// check. The client path writes NO audit row itself, so the
  /// approve decision is logged here; rejectMatchResult logs its
  /// own row. Returns {'ok', 'error'?, 'total'?, 'already'?}.
  ///
  /// Points honesty (OD-02 decided 2026-11-21: placement 1st = 10
  /// + 1 per kill): points are COMPUTED from placement + kills
  /// with the effective template and PERSISTED at approve time on
  /// the tournament_results row by SupaDb.approveMatchResult step
  /// (4b) (P1-10, 2026-11-22) — getResultsForTournament merges
  /// them onto the registration rows the results page reads, so
  /// approved results show real points. The 022 RPC would credit
  /// the ledger at submit time, but it is NOT applied on
  /// production yet, and even applied it would fail for anon-key
  /// calls without the JWT bridge; the direct-upsert fallback
  /// writes stats only. Leaderboard RANK moves on approve
  /// (recomputeLeaderboard over matchPoints, decided model). Do
  /// not silently change the formula — the server RPC is the
  /// authority for credited points.
  static Future<Map<String, dynamic>> approveResult({
    required String resultId,
    required String decision,
    required String reason,
    required String adminUid,
  }) async {
    try {
      final row = await getRow('tournament_results', 'id', resultId);
      if (row.isEmpty) {
        return {'ok': false, 'error': 'Result nahi mila.'};
      }
      final tournamentId = SupaDb.strOf(row['tournament_id']);
      final playerUid = SupaDb.strOf(row['firebase_uid']);
      final status = SupaDb.strOf(row['status']).toLowerCase();
      if (status == 'approved') {
        return {'ok': true, 'already': true, 'total': 0.0};
      }
      if (decision == 'approved') {
        if (status != 'pending' &&
            status != 'submitted' &&
            status != 're-submitted') {
          return {
            'ok': false,
            'error':
                "Result ki status '$status' hai — sirf pending/submitted result approve ho sakta hai."
          };
        }
        final res = await SupaDb.approveMatchResult(
          tournamentId: tournamentId,
          playerUid: playerUid,
          adminUid: adminUid,
        );
        if (res['ok'] != true) {
          return {
            'ok': false,
            'error': SupaDb.strOf(res['error'], 'Approve fail ho gaya.')
          };
        }
        await logAdminActivity(
          adminUid: adminUid,
          action: 'result_approve',
          targetType: 'tournament_result',
          targetId: resultId,
          oldValue: {'status': status},
          newValue: {
            'status': 'approved',
            'prize_total': res['total'],
            'kill_amount': res['killAmount'],
            'win_bonus': res['winBonus'],
          },
        );
        // Notify the player — otherwise they never learn the
        // result was approved or how many points they earned.
        // Skipped when another approve already credited this
        // result (res['already']) so a race never double-notifies.
        if (res['already'] != true) {
          try {
            final template =
                await ScoringTemplateStore.loadEffectiveTemplate();
            final points = SupaDb.matchPoints(
              kills: SupaDb.intOf(row['kills'], 0),
              placement: SupaDb.intOf(row['placement'], 0),
              template: template,
            );
            await SupaDb.notifyUser(
              playerUid,
              'Result approved',
              'Aapka result approve ho gaya — $points points mil gaye.',
            );
          } catch (_) {
            // Notification failure never undoes the decision.
          }
        }
        return {
          'ok': true,
          'total': res['total'],
          'killAmount': res['killAmount'],
          'winBonus': res['winBonus'],
          'commissionCatchUp': res['commissionCatchUp'],
          'leaderboardOk': res['leaderboardOk'] != false,
          'already': res['already'] == true,
          // P1-10: points persisted at approve time (step 4b).
          'teamPoints': res['teamPoints'],
          'placementPoints': res['placementPoints'],
          'killPoints': res['killPoints'],
          'pointsOk': res['pointsOk'],
        };
      }
      // decision == 'rejected' (plain reject OR request-correction).
      if (status == 'rejected') {
        return {'ok': false, 'error': 'Result pehle se rejected hai.'};
      }
      final res = await SupaDb.rejectMatchResult(
        tournamentId: tournamentId,
        playerUid: playerUid,
        adminUid: adminUid,
        reason: reason,
      );
      if (res['ok'] != true) {
        return {
          'ok': false,
          'error': SupaDb.strOf(res['error'], 'Reject fail ho gaya.')
        };
      }
      // Notify the player — otherwise the reason lives only in the
      // audit log and the player never sees it (no player-side
      // surface reads rejection / correction_requested reasons).
      final isCorrection = reason.startsWith('correction_requested');
      final detail = isCorrection
          ? reason
              .substring('correction_requested'.length)
              .replaceFirst(RegExp(r'^\s*:\s*'), '')
              .trim()
          : reason.trim();
      try {
        await SupaDb.notifyUser(
          playerUid,
          isCorrection ? 'Result correction requested' : 'Result rejected',
          isCorrection
              ? (detail.isEmpty
                  ? 'Admin ne aapke result mein correction maangi hai — sahi details ke saath dobara submit karein.'
                  : 'Admin ne correction maangi hai: $detail — dobara submit karein.')
              : (detail.isEmpty
                  ? 'Aapka result reject ho gaya hai.'
                  : 'Aapka result reject ho gaya hai. Reason: $detail'),
        );
      } catch (_) {
        // Notification failure never undoes the decision.
      }
      return {'ok': true, 'correction': isCorrection};
    } catch (e) {
      return {'ok': false, 'error': e.toString()};
    }
  }

  /// DIRECT-WRITE (024-enforced): delete one tournament_results row
  /// + audit row. HONEST LIMIT: deleting an APPROVED result does
  /// NOT reverse wallet credits already paid — no reversal path
  /// exists. The leaderboard rank IS rebuilt, so the deleted
  /// result stops counting. The caller states this in the confirm
  /// dialog; for a still-pending result, Reject is the cleaner
  /// action (it notifies the player, delete does not).
  static Future<Map<String, dynamic>> deleteResult({
    required String resultId,
    required String adminUid,
    String? reason,
  }) async {
    try {
      final before = await getRow('tournament_results', 'id', resultId);
      if (before.isEmpty) return {'ok': true, 'alreadyGone': true};
      await _client.from('tournament_results').delete().eq('id', resultId);
      await logAdminActivity(
        adminUid: adminUid,
        action: 'result_delete',
        targetType: 'tournament_result',
        targetId: resultId,
        oldValue: {
          'status': SupaDb.strOf(before['status']),
          'tournament_id': SupaDb.strOf(before['tournament_id']),
          'firebase_uid': SupaDb.strOf(before['firebase_uid']),
        },
        reason: reason,
      );
      // An approved result fed the stored ranks — rebuild them so
      // the deleted result stops counting. Best-effort: a failed
      // rebuild never fails the delete itself.
      if (SupaDb.strOf(before['status']) == 'approved') {
        try {
          await SupaDb.recomputeLeaderboard();
        } catch (_) {}
      }
      return {'ok': true, 'wasApproved': SupaDb.strOf(before['status']) == 'approved'};
    } catch (e) {
      return {'ok': false, 'error': e.toString()};
    }
  }

  /// DIRECT-WRITE (024-enforced): delete one disputes row + audit
  /// row. The matching result's FLAGGED pill clears on the next
  /// reload (flags come only from open/under_review disputes).
  /// Resolving is the normal path — delete is for spam / test rows
  /// only, and the caller says so in the confirm dialog.
  static Future<Map<String, dynamic>> deleteDispute({
    required String disputeId,
    required String adminUid,
    String? reason,
  }) async {
    try {
      final before = await getRow('disputes', 'id', disputeId);
      if (before.isEmpty) return {'ok': true, 'alreadyGone': true};
      await _client.from('disputes').delete().eq('id', disputeId);
      await logAdminActivity(
        adminUid: adminUid,
        action: 'dispute_delete',
        targetType: 'dispute',
        targetId: disputeId,
        oldValue: {
          'status': SupaDb.strOf(before['status']),
          'tournament_id': SupaDb.strOf(before['tournament_id']),
          'raised_by': SupaDb.strOf(before['raised_by']),
        },
        reason: reason,
      );
      return {'ok': true};
    } catch (e) {
      return {'ok': false, 'error': e.toString()};
    }
  }

  // ---------- disputes ----------

  static Future<List<Map<String, dynamic>>> getDisputes() =>
      getList('disputes', orderBy: 'created_at', ascending: false, limit: 200);

  /// DIRECT-WRITE (024-enforced): open -> 'under_review' + audit row.
  /// No RPC exists for the triage step; resolve_dispute only accepts
  /// open/under_review rows and moves them to a terminal state.
  /// NOTE: the value is 'under_review', NOT 'reviewing' — that is the
  /// live 053 status CHECK vocabulary ('open' / 'under_review' /
  /// 'resolved' / 'rejected') and the 071 guard's accepted set. The
  /// old 'reviewing' value would fail the CHECK on write and 071
  /// would reject the row at resolve time.
  static Future<Map<String, dynamic>> markDisputeReviewing({
    required String disputeId,
    required String adminUid,
    String? oldStatus,
  }) async {
    try {
      await _client
          .from('disputes')
          .update({'status': 'under_review'}).eq('id', disputeId);
      await logAdminActivity(
        adminUid: adminUid,
        action: 'dispute_mark_reviewing',
        targetType: 'dispute',
        targetId: disputeId,
        oldValue: {'status': oldStatus ?? 'open'},
        newValue: {'status': 'under_review'},
      );
      return {'ok': true};
    } catch (e) {
      return {'ok': false, 'error': e.toString()};
    }
  }

  /// Resolve one dispute via the 071 resolve_dispute RPC.
  ///
  /// 071 signature: resolve_dispute(p_dispute_id uuid, p_admin_uid
  /// text, p_resolution text, p_refund boolean, p_idempotency_key
  /// uuid) -> {dispute_id, status, refund, amount, transaction_id}.
  /// The RPC always closes the dispute as status 'resolved' — 071
  /// has NO 'rejected' outcome. A 'rejected' [resolution] is sent as
  /// resolution text `Rejected: <reason>` so the wording survives in
  /// disputes.resolution + the audit row; the row itself lands as
  /// 'resolved' (it appears under the Resolved filter, not Rejected).
  /// For 'resolved', [reason] is stored as the resolution text (or
  /// 'Resolved' when empty) — 071 requires non-blank resolution text.
  /// [refund] is the per-case refund choice, passed through from the
  /// admin's decision — resolve in the reporter's favour returns the
  /// entry fee, reject does not. It is never hardcoded here; the
  /// caller passes it. NOTE: with refund=true the RPC raises (and
  /// resolves nothing) when the reporter has no registration or the
  /// tournament has no entry fee (free tournament / chat report) —
  /// 071 derives the amount from a real payment only.
  /// [overturn] is accepted for API compatibility but 071 performs NO
  /// overturn / points reversal (draft 071 open item O1, separate
  /// RPC); it is not sent to the RPC. The RPC writes its own
  /// admin_activity_logs row.
  static Future<Map<String, dynamic>> resolveDispute({
    required String disputeId,
    required String resolution,
    required String reason,
    required bool overturn,
    required String adminUid,
    required bool refund,
  }) async {
    try {
      final resolutionText = resolution == 'rejected'
          ? 'Rejected: $reason'
          : (reason.isEmpty ? 'Resolved' : reason);
      final res = await _client.rpc('resolve_dispute', params: {
        'p_dispute_id': disputeId,
        'p_admin_uid': adminUid,
        'p_resolution': resolutionText,
        'p_refund': refund,
        'p_idempotency_key': _newUuidV4(),
      });
      return {'ok': true, 'data': res};
    } catch (e) {
      return {'ok': false, 'error': e.toString()};
    }
  }

  /// Local v4 UUID (no uuid package in pubspec) for RPC idempotency
  /// keys — 071's p_idempotency_key is uuid, not text.
  static String _newUuidV4() {
    final r = math.Random.secure();
    final bytes = List<int>.generate(16, (_) => r.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant 10xx
    final h =
        bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-'
        '${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
  }

  // ---------- players ----------

  static Future<List<Map<String, dynamic>>> getPlayers() =>
      getList('profiles', orderBy: 'created_at', ascending: false, limit: 200);

  /// DIRECT-WRITE (024-enforced): profiles.status = 'blocked' +
  /// blocked_users row (blocker = the acting admin) + audit row.
  /// Enforcement is the Phase 5 §2.6 login gate, which refuses
  /// profiles with status 'blocked'.
  static Future<Map<String, dynamic>> restrictPlayer({
    required String targetUid,
    required String adminUid,
    String? reason,
  }) async {
    try {
      final before = await getRow('profiles', 'firebase_uid', targetUid);
      await _client
          .from('profiles')
          .update({'status': 'blocked'}).eq('firebase_uid', targetUid);
      try {
        await _client.from('blocked_users').upsert(
          {'blocker_uid': adminUid, 'blocked_uid': targetUid},
          onConflict: 'blocker_uid,blocked_uid',
        );
      } catch (_) {
        // The status flag is the enforcement; a duplicate/failed
        // blocked_users row must not mask the restriction.
      }
      await logAdminActivity(
        adminUid: adminUid,
        action: 'restrict_player',
        targetType: 'profile',
        targetId: targetUid,
        oldValue: {'status': SupaDb.strOf(before['status'], 'active')},
        newValue: {'status': 'blocked'},
        reason: reason,
      );
      return {'ok': true};
    } catch (e) {
      return {'ok': false, 'error': e.toString()};
    }
  }

  /// DIRECT-WRITE (024-enforced): profiles.status back to 'active' +
  /// remove the admin's blocked_users row + audit row. A block row
  /// left by ANOTHER blocker (user-level block) is untouched.
  static Future<Map<String, dynamic>> restorePlayer({
    required String targetUid,
    required String adminUid,
    String? reason,
  }) async {
    try {
      final before = await getRow('profiles', 'firebase_uid', targetUid);
      await _client
          .from('profiles')
          .update({'status': 'active'}).eq('firebase_uid', targetUid);
      try {
        await _client
            .from('blocked_users')
            .delete()
            .eq('blocker_uid', adminUid)
            .eq('blocked_uid', targetUid);
      } catch (_) {}
      await logAdminActivity(
        adminUid: adminUid,
        action: 'restore_player',
        targetType: 'profile',
        targetId: targetUid,
        oldValue: {'status': SupaDb.strOf(before['status'], 'blocked')},
        newValue: {'status': 'active'},
        reason: reason,
      );
      return {'ok': true};
    } catch (e) {
      return {'ok': false, 'error': e.toString()};
    }
  }

  /// DIRECT-WRITE (024-enforced): display_name edit + audit row.
  static Future<Map<String, dynamic>> updatePlayerName({
    required String targetUid,
    required String adminUid,
    required String newName,
    String? oldName,
  }) async {
    try {
      await _client
          .from('profiles')
          .update({'display_name': newName}).eq('firebase_uid', targetUid);
      await logAdminActivity(
        adminUid: adminUid,
        action: 'edit_player_name',
        targetType: 'profile',
        targetId: targetUid,
        oldValue: {'display_name': oldName ?? ''},
        newValue: {'display_name': newName},
      );
      return {'ok': true};
    } catch (e) {
      return {'ok': false, 'error': e.toString()};
    }
  }

  /// Notify one player (writes a user_notifications row via the
  /// existing SupaDb.notifyUser path) + audit row.
  static Future<Map<String, dynamic>> notifyPlayer({
    required String targetUid,
    required String adminUid,
    required String title,
    required String message,
  }) async {
    try {
      await SupaDb.notifyUser(targetUid, title, message);
      await logAdminActivity(
        adminUid: adminUid,
        action: 'notify_player',
        targetType: 'profile',
        targetId: targetUid,
        newValue: {'title': title},
        reason: message,
      );
      return {'ok': true};
    } catch (e) {
      return {'ok': false, 'error': e.toString()};
    }
  }

  /// Everything the player detail page needs, from live queries.
  /// Returns a map with keys: profile, matches, teamMemberships,
  /// teamNames, teams (full team rows — for the captain check on
  /// remove), pointsLedger, pointsTotal, reports, disputesRaised,
  /// tickets. Any failed read yields its empty shape, never a crash.
  static Future<Map<String, dynamic>> getPlayerDetail(String uid) async {
    final results = await Future.wait([
      getRow('profiles', 'firebase_uid', uid),
      getList('match_history',
          eqCol: 'firebase_uid', eqVal: uid, orderBy: 'played_at', ascending: false, limit: 50),
      getList('team_members', eqCol: 'firebase_uid', eqVal: uid, limit: 50),
      SupaDb.getPointsLedger(uid),
      SupaDb.getPointsTotal(uid),
      getList('player_reports',
          eqCol: 'reported_uid', eqVal: uid, orderBy: 'created_at', ascending: false, limit: 50),
      getList('disputes',
          eqCol: 'raised_by', eqVal: uid, orderBy: 'created_at', ascending: false, limit: 50),
      getList('support_tickets',
          eqCol: 'firebase_uid', eqVal: uid, orderBy: 'created_at', ascending: false, limit: 50),
      getTeams(),
    ]);
    final teamNames = await getTeamNames();
    return {
      'profile': results[0] as Map<String, dynamic>,
      'matches': results[1] as List<Map<String, dynamic>>,
      'teamMemberships': results[2] as List<Map<String, dynamic>>,
      'pointsLedger': results[3] as List<Map<String, dynamic>>,
      'pointsTotal': results[4] as int,
      'reports': results[5] as List<Map<String, dynamic>>,
      'disputesRaised': results[6] as List<Map<String, dynamic>>,
      'tickets': results[7] as List<Map<String, dynamic>>,
      'teams': results[8] as List<Map<String, dynamic>>,
      'teamNames': teamNames,
    };
  }

  /// DIRECT-WRITE (024-enforced): resolve one player report
  /// (player_reports status 'open' -> 'resolved') + audit row. The
  /// report row is KEPT (history), only its status changes. Reports
  /// are filed by players (pro_features report flow); disputes the
  /// player RAISED are resolved from the Disputes screen, not here.
  static Future<Map<String, dynamic>> resolvePlayerReport({
    required String reportId,
    required String adminUid,
    String? reason,
  }) async {
    try {
      final before = await getRow('player_reports', 'id', reportId);
      if (before.isEmpty) {
        return {'ok': false, 'error': 'Report nahi mili.'};
      }
      await _client
          .from('player_reports')
          .update({'status': 'resolved'})
          .eq('id', reportId);
      await logAdminActivity(
        adminUid: adminUid,
        action: 'player_report_resolved',
        targetType: 'player_report',
        targetId: reportId,
        oldValue: {'status': SupaDb.strOf(before['status'], 'open')},
        newValue: {'status': 'resolved'},
        reason: reason,
      );
      return {'ok': true};
    } catch (e) {
      return {'ok': false, 'error': e.toString()};
    }
  }

  /// DIRECT-WRITE (024-enforced): delete a player's APP data —
  /// profiles row + team memberships + registrations + results +
  /// match history + user notifications + warnings + player
  /// reports (both directions) + live-support messages + chat
  /// messages authored by them. Deleting registrations frees the
  /// slots; deleting results does NOT reverse wallet credits
  /// already paid (same limit as [deleteResult]).
  ///
  /// KEPT on purpose: disputes (evidence), support tickets +
  /// messages (support history), deposits / transactions
  /// (financial audit), admin_activity_logs.
  ///
  /// HONEST LIMIT: the Firebase Auth account itself CANNOT be
  /// deleted from the client — there is no Admin SDK in this app.
  /// The player keeps their login and can open the app again (a
  /// fresh profile is created on next sign-in). Full account
  /// removal needs backend work (Firebase console / Admin SDK).
  /// The admin's own profile can never be deleted this way.
  /// Returns {'ok', 'deleted': {table: count}, 'error'?}.
  static Future<Map<String, dynamic>> deletePlayer({
    required String targetUid,
    required String adminUid,
    String? reason,
  }) async {
    if (targetUid.isEmpty) return {'ok': false, 'error': 'Player nahi mila.'};
    if (targetUid == adminUid) {
      return {
        'ok': false,
        'error': 'Admin apna khud ka profile delete nahi kar sakta.'
      };
    }
    try {
      final deleted = <String, int>{};
      Future<void> wipe(String table, String col) async {
        try {
          final res = await _client
              .from(table)
              .delete()
              .eq(col, targetUid)
              .select('id');
          deleted[table] = (deleted[table] ?? 0) + (res as List).length;
        } catch (_) {
          // One table failing (e.g. RLS) must not hide the rest —
          // the count stays 0 and the caller sees it.
          deleted[table] = deleted[table] ?? 0;
        }
      }

      await wipe('team_members', 'firebase_uid');
      await wipe('tournament_registrations', 'firebase_uid');
      await wipe('tournament_results', 'firebase_uid');
      await wipe('match_history', 'firebase_uid');
      await wipe('user_notifications', 'firebase_uid');
      await wipe('user_warnings', 'firebase_uid');
      await wipe('user_frames', 'firebase_uid');
      await wipe('player_reports', 'reported_uid');
      await wipe('player_reports', 'reporter_uid');
      await wipe('live_support_messages', 'firebase_uid');
      await wipe('chat_messages', 'firebase_uid');
      // Profile LAST — children first so a mid-way failure leaves
      // the profile (and the player) visible instead of orphaned.
      await wipe('profiles', 'firebase_uid');
      await logAdminActivity(
        adminUid: adminUid,
        action: 'player_delete',
        targetType: 'player',
        targetId: targetUid,
        oldValue: {'deleted': deleted},
        reason: reason,
      );
      return {'ok': true, 'deleted': deleted};
    } catch (e) {
      return {'ok': false, 'error': e.toString()};
    }
  }

  // ---------- teams ----------

  static Future<List<Map<String, dynamic>>> getTeams() =>
      getList('teams', orderBy: 'created_at', ascending: false, limit: 200);

  static Future<List<Map<String, dynamic>>> getAllTeamMembers() =>
      getList('team_members', limit: 500);

  /// DIRECT-WRITE (024-enforced): delete all team_members rows, then
  /// the teams row, then an audit row. There is no dissolve RPC.
  /// Also clears the orphans a dissolve used to leave behind (audit
  /// fix 2026-11-21): pending team_invitations for this team, and
  /// the invitees' team_invite notifications — otherwise an invited
  /// player kept a live invite to a team that no longer exists.
  static Future<Map<String, dynamic>> dissolveTeam({
    required String teamId,
    required String adminUid,
    required String teamName,
    String? reason,
  }) async {
    try {
      await _client.from('team_members').delete().eq('team_id', teamId);
      try {
        await _client.from('team_invitations').delete().eq('team_id', teamId);
      } catch (_) {}
      try {
        await _client
            .from('user_notifications')
            .delete()
            .eq('team_id', teamId)
            .eq('type', 'team_invite');
      } catch (_) {}
      await _client.from('teams').delete().eq('id', teamId);
      await logAdminActivity(
        adminUid: adminUid,
        action: 'dissolve_team',
        targetType: 'team',
        targetId: teamId,
        oldValue: {'name': teamName},
        newValue: {'status': 'dissolved'},
        reason: reason,
      );
      return {'ok': true};
    } catch (e) {
      return {'ok': false, 'error': e.toString()};
    }
  }

  /// DIRECT-WRITE (024-enforced): remove ONE player from a team
  /// (delete their team_members row) + audit row. The team itself
  /// survives. Removing the CAPTAIN is allowed but leaves the team
  /// captain-less (no auto-promotion exists) — the caller warns the
  /// admin first; [wasCaptain] is returned so the toast can say so.
  static Future<Map<String, dynamic>> removeTeamMember({
    required String teamId,
    required String targetUid,
    required String adminUid,
    required String teamName,
    String? reason,
  }) async {
    try {
      final team = await getRow('teams', 'id', teamId);
      final wasCaptain =
          SupaDb.strOf(team['captain_uid']) == targetUid;
      await _client
          .from('team_members')
          .delete()
          .eq('team_id', teamId)
          .eq('firebase_uid', targetUid);
      await logAdminActivity(
        adminUid: adminUid,
        action: 'remove_team_member',
        targetType: 'team_member',
        targetId: '$teamId:$targetUid',
        oldValue: {'team': teamName, 'captain': wasCaptain},
        newValue: {'status': 'removed'},
        reason: reason,
      );
      return {'ok': true, 'wasCaptain': wasCaptain};
    } catch (e) {
      return {'ok': false, 'error': e.toString()};
    }
  }
}
