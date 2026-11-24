import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'admin_db.dart';
import 'supabase_db.dart';

/// Admin "Care" data layer — Promotions / Notifications / Chat Mod /
/// Support / Live Support (O-admin-panel round, worker W6).
///
/// All admin backend access for these screens goes through here.
/// Screens never call Supabase directly and never write a table from
/// a widget.
///
/// Reads go through [AdminDb.getList] / [AdminDb.getRow] (W1); RPCs
/// and multi-row writes go through [SupaDb.client] (AdminDb exposes
/// no insert/update/delete helpers, and the task specifies
/// "SupaDb.client for RPCs and AdminDb.getList/getRow/logAdminActivity
/// for the rest"). Audit rows go through [AdminDb.logAdminActivity];
/// this file's [logAdminActivity] is a thin adapter that JSON-encodes
/// the map values, because AdminDb's contract takes String values.
///
/// WRITES: every write here is a DIRECT-WRITE (no RPC exists for it)
/// under the 024 RLS admin-only policy, always paired with an
/// `admin_activity_logs` row in the same user action — flagged
/// DIRECT-WRITE in the W6 report. The two moderation actions that
/// need a server RPC (remove message / restrict chat) go through
/// [moderateChat] → `admin_moderate_chat` (migration 032, DRAFT ONLY,
/// never applied); the UI ships those buttons DISABLED until 032 is
/// applied. No method here ever throws for a routine failure — reads
/// return [] / {} and writes return false or {'ok', 'error'}
/// (promotions/ads/sliders family), so screens show the
/// designed empty/error state instead of crashing.
class AdminDbCare {
  static String get _adminUid =>
      FirebaseAuth.instance.currentUser?.uid ?? '';

  // ------------------------------------------------------------------
  // Audit (AdminDb contract shape — Map values, JSON-encoded below).
  // ------------------------------------------------------------------

  /// Writes one `admin_activity_logs` row via [AdminDb]. Returns false
  /// (never throws) when the audit insert fails — the caller still
  /// reports the primary action's own result honestly.
  static Future<bool> logAdminActivity({
    required String action,
    String? targetType,
    String? targetId,
    Map<String, dynamic>? oldValue,
    Map<String, dynamic>? newValue,
    String? reason,
  }) async {
    try {
      await AdminDb.logAdminActivity(
        action: action,
        targetType: targetType ?? '',
        targetId: targetId ?? '',
        oldValue: oldValue == null ? null : jsonEncode(oldValue),
        newValue: newValue == null ? null : jsonEncode(newValue),
        reason: reason,
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Best-effort audit wrapper — logging must NEVER flip a
  /// successful save/update/delete to false (2026-11-20 audit-trap
  /// fix). The adapter already swallows its own errors (it is
  /// never-throw by design — audit 2026-11-20 §3a confirmed all
  /// logAdminActivity variants return false instead of throwing),
  /// so this wrapper is structural defense-in-depth. The REAL
  /// defect is the inverse — a failed audit insert is invisible —
  /// so a failure is logged to the console here (never surfaced
  /// to the admin UI, never fatal).
  static Future<void> _audit({
    required String action,
    String? targetType,
    String? targetId,
    Map<String, dynamic>? oldValue,
    Map<String, dynamic>? newValue,
    String? reason,
  }) async {
    try {
      final ok = await logAdminActivity(
        action: action,
        targetType: targetType,
        targetId: targetId,
        oldValue: oldValue,
        newValue: newValue,
        reason: reason,
      );
      if (!ok) {
        debugPrint('audit: FAILED to record $action'
            '${targetType == null ? '' : ' $targetType'}'
            '${targetId == null ? '' : ' $targetId'}');
      }
    } catch (_) {}
  }

  /// Profiles for a set of uids (display names for reports / presence
  /// / live chat). Delegates to SupaDb; empty map on failure.
  static Future<Map<String, Map<String, dynamic>>> getProfilesMap(
          List<String> uids) =>
      SupaDb.getProfilesMap(uids);

  // ------------------------------------------------------------------
  // Promotions / Ads / Sliders (DIRECT-WRITE + audit).
  // Tables (001 + 009 + 028):
  //   promotions: id, image_url, link, created_at, updated_at
  //   ads: id, title, image_url, target_type, target_id, target_name,
  //        active, rotation_interval_seconds (009), created_at
  //   sliders: id, title, subtitle, image_url, target_type, target_id,
  //        target_url, sort_order, active, created_at, updated_at (028)
  //
  // RETURN SHAPE (2026-11-20): every save/update/delete here returns
  // {'ok': bool, 'error': String?} — NEVER a bare bool. A bare
  // `false` hid WHY a save failed: an RLS-blocked write returns []
  // with NO exception, so 'Save failed — try again' told the admin
  // nothing. An empty `.select('id')` result now reports a
  // plain-words reason (write refused — usually an RLS permission
  // issue; draft migration 034 covers the policy fix) and a real
  // exception surfaces its own message. Audit logging is
  // best-effort ([_audit]) and can never flip a successful write
  // to false. Deletes re-check the row by id: the row being GONE
  // is success even if the delete's select came back empty.
  // ------------------------------------------------------------------

  static Future<List<Map<String, dynamic>>> getPromotions() =>
      AdminDb.getList('promotions', orderBy: 'created_at', ascending: false);

  static Future<List<Map<String, dynamic>>> getAds() =>
      AdminDb.getList('ads', orderBy: 'created_at', ascending: false);

  static Future<List<Map<String, dynamic>>> getSliders() =>
      AdminDb.getList('sliders', orderBy: 'sort_order', ascending: true);

  static Future<Map<String, dynamic>> savePromotion({
    String? id,
    required String imageUrl,
    required String link,
  }) async {
    try {
      if (id == null || id.isEmpty) {
        final res = await SupaDb.client.from('promotions').insert({
          'image_url': imageUrl.trim(),
          'link': link.trim(),
        }).select('id');
        if (res.isEmpty) {
          return {
            'ok': false,
            'error':
                'Database ne banner save karne se mana kar diya (koi row nahi bani — shayad permission/RLS issue hai).'
          };
        }
        await _audit(
          action: 'promotion_created',
          targetType: 'promotion',
          targetId: SupaDb.strOf((res.first as Map)['id']),
          newValue: {'image_url': imageUrl.trim(), 'link': link.trim()},
        );
        return {'ok': true};
      }
      final old = await AdminDb.getRow('promotions', 'id', id);
      final res = await SupaDb.client
          .from('promotions')
          .update({'image_url': imageUrl.trim(), 'link': link.trim()})
          .eq('id', id)
          .select('id');
      if (res.isEmpty) {
        return {
          'ok': false,
          'error':
              'Banner update nahi hua — row nahi mili ya permission nahi hai.'
        };
      }
      await _audit(
        action: 'promotion_updated',
        targetType: 'promotion',
        targetId: id,
        oldValue: old == null ? null : {'image_url': SupaDb.strOf(old['image_url']), 'link': SupaDb.strOf(old['link'])},
        newValue: {'image_url': imageUrl.trim(), 'link': link.trim()},
      );
      return {'ok': true};
    } catch (e) {
      return {'ok': false, 'error': e.toString()};
    }
  }

  static Future<Map<String, dynamic>> deletePromotion(String id) async {
    try {
      final old = await AdminDb.getRow('promotions', 'id', id);
      if (old == null) return {'ok': true, 'alreadyGone': true};
      final res = await SupaDb.client
          .from('promotions')
          .delete()
          .eq('id', id)
          .select('id');
      // Re-check by id: the row being GONE is success even if the
      // delete's select came back empty (RLS can hide the row from
      // the returning clause without blocking the delete).
      final gone = await AdminDb.getRow('promotions', 'id', id) == null;
      if (res.isEmpty && !gone) {
        return {
          'ok': false,
          'error':
              'Delete refuse ho gaya — banner abhi bhi maujood hai (shayad permission/RLS issue hai).'
        };
      }
      await _audit(
        action: 'promotion_deleted',
        targetType: 'promotion',
        targetId: id,
        oldValue: {'image_url': SupaDb.strOf(old['image_url']), 'link': SupaDb.strOf(old['link'])},
      );
      return {'ok': true};
    } catch (e) {
      return {'ok': false, 'error': e.toString()};
    }
  }

  static Future<Map<String, dynamic>> saveAd({
    String? id,
    required String title,
    required String imageUrl,
    required String targetType,
    required String targetId,
    required String targetName,
    required bool active,
    int? rotationSeconds,
  }) async {
    try {
      final data = <String, dynamic>{
        'title': title.trim(),
        'image_url': imageUrl.trim(),
        'target_type': targetType,
        'target_id': targetId,
        'target_name': targetName,
        'active': active,
        'rotation_interval_seconds': rotationSeconds,
      };
      if (id == null || id.isEmpty) {
        final res =
            await SupaDb.client.from('ads').insert(data).select('id');
        if (res.isEmpty) {
          return {
            'ok': false,
            'error':
                'Database ne ad save karne se mana kar diya (koi row nahi bani — shayad permission/RLS issue hai).'
          };
        }
        await _audit(
          action: 'ad_created',
          targetType: 'ad',
          targetId: SupaDb.strOf((res.first as Map)['id']),
          newValue: {'title': title.trim(), 'target_type': targetType, 'target_id': targetId},
        );
        return {'ok': true};
      }
      final old = await AdminDb.getRow('ads', 'id', id);
      final res = await SupaDb.client
          .from('ads')
          .update(data)
          .eq('id', id)
          .select('id');
      if (res.isEmpty) {
        return {
          'ok': false,
          'error': 'Ad update nahi hua — row nahi mili ya permission nahi hai.'
        };
      }
      await _audit(
        action: 'ad_updated',
        targetType: 'ad',
        targetId: id,
        oldValue: old == null ? null : {'title': SupaDb.strOf(old['title']), 'active': old['active']},
        newValue: {'title': title.trim(), 'active': active},
      );
      return {'ok': true};
    } catch (e) {
      return {'ok': false, 'error': e.toString()};
    }
  }

  static Future<Map<String, dynamic>> deleteAd(String id) async {
    try {
      final old = await AdminDb.getRow('ads', 'id', id);
      if (old == null) return {'ok': true, 'alreadyGone': true};
      final res =
          await SupaDb.client.from('ads').delete().eq('id', id).select('id');
      final gone = await AdminDb.getRow('ads', 'id', id) == null;
      if (res.isEmpty && !gone) {
        return {
          'ok': false,
          'error':
              'Delete refuse ho gaya — ad abhi bhi maujood hai (shayad permission/RLS issue hai).'
        };
      }
      await _audit(
        action: 'ad_deleted',
        targetType: 'ad',
        targetId: id,
        oldValue: {'title': SupaDb.strOf(old['title'])},
      );
      return {'ok': true};
    } catch (e) {
      return {'ok': false, 'error': e.toString()};
    }
  }

  static Future<Map<String, dynamic>> setAdActive(String id, bool active) async {
    try {
      final res = await SupaDb.client
          .from('ads')
          .update({'active': active})
          .eq('id', id)
          .select('id');
      if (res.isEmpty) {
        return {
          'ok': false,
          'error': 'Update nahi hua — row nahi mili ya permission nahi hai.'
        };
      }
      await _audit(
        action: active ? 'ad_activated' : 'ad_deactivated',
        targetType: 'ad',
        targetId: id,
        newValue: {'active': active},
      );
      return {'ok': true};
    } catch (e) {
      return {'ok': false, 'error': e.toString()};
    }
  }

  static Future<Map<String, dynamic>> saveSlider({
    String? id,
    required String title,
    required String subtitle,
    required String imageUrl,
    String? characterImageUrl,
    required String targetType,
    String? targetId,
    String? targetUrl,
    required int sortOrder,
    required bool active,
  }) async {
    // FIX 20 (2026-11-21): the character cutout lives in
    // sliders.character_image_url (migration 038). DEFENSIVE: if
    // 038 is not applied yet, sending the column fails the WHOLE
    // save with PGRST204 — so on that exact error the save retries
    // WITHOUT the character column and reports
    // characterSkipped: true (the form toasts it plainly). The
    // banner + target still save; only the character waits for 038.
    try {
      final data = <String, dynamic>{
        'title': title.trim(),
        'subtitle': subtitle.trim(),
        'image_url': imageUrl.trim(),
        if (characterImageUrl != null && characterImageUrl.isNotEmpty)
          'character_image_url': characterImageUrl.trim(),
        'target_type': targetType,
        'target_id': (targetId == null || targetId.isEmpty) ? null : targetId,
        'target_url': (targetUrl == null || targetUrl.isEmpty) ? null : targetUrl.trim(),
        'sort_order': sortOrder,
        'active': active,
      };
      // Runs the insert/update once; on a missing-column error for
      // character_image_url, drops the column and runs it again.
      Future<Map<String, dynamic>> runOnce(Map<String, dynamic> payload) async {
        if (id == null || id.isEmpty) {
          final res = await SupaDb.client.from('sliders').insert(payload).select('id');
          if (res.isEmpty) {
            return {
              'ok': false,
              'error': 'Database ne slide save karne se mana kar diya (koi row nahi bani — shayad permission/RLS issue hai).'
            };
          }
          await _audit(
            action: 'slider_created',
            targetType: 'slider',
            targetId: SupaDb.strOf((res.first as Map)['id']),
            newValue: {'title': title.trim(), 'target_type': targetType},
          );
          return {'ok': true};
        }
        final old = await AdminDb.getRow('sliders', 'id', id);
        final res = await SupaDb.client.from('sliders').update(payload).eq('id', id).select('id');
        if (res.isEmpty) {
          return {'ok': false, 'error': 'Slide update nahi hui — row nahi mili ya permission nahi hai.'};
        }
        await _audit(
          action: 'slider_updated',
          targetType: 'slider',
          targetId: id,
          oldValue: old == null ? null : {'title': SupaDb.strOf(old['title']), 'active': old['active']},
          newValue: {'title': title.trim(), 'active': active},
        );
        return {'ok': true};
      }

      try {
        final res = await runOnce(data);
        if (res['ok'] == true) return {'ok': true};
        return res;
      } catch (e) {
        final msg = e.toString();
        final missingColumn = msg.contains('PGRST204') && msg.contains('character_image_url');
        if (!missingColumn || !data.containsKey('character_image_url')) rethrow;
        // 038 not applied yet: retry without the character column.
        data.remove('character_image_url');
        final res = await runOnce(data);
        if (res['ok'] == true) return {'ok': true, 'characterSkipped': true};
        return res;
      }
    } catch (e) {
      return {'ok': false, 'error': e.toString()};
    }
  }

  static Future<Map<String, dynamic>> deleteSlider(String id) async {
    try {
      final old = await AdminDb.getRow('sliders', 'id', id);
      if (old == null) return {'ok': true, 'alreadyGone': true};
      final res = await SupaDb.client
          .from('sliders')
          .delete()
          .eq('id', id)
          .select('id');
      final gone = await AdminDb.getRow('sliders', 'id', id) == null;
      if (res.isEmpty && !gone) {
        return {
          'ok': false,
          'error':
              'Delete refuse ho gaya — slide abhi bhi maujood hai (shayad permission/RLS issue hai).'
        };
      }
      await _audit(
        action: 'slider_deleted',
        targetType: 'slider',
        targetId: id,
        oldValue: {'title': SupaDb.strOf(old['title'])},
      );
      return {'ok': true};
    } catch (e) {
      return {'ok': false, 'error': e.toString()};
    }
  }

  static Future<Map<String, dynamic>> setSliderActive(String id, bool active) async {
    try {
      final res = await SupaDb.client
          .from('sliders')
          .update({'active': active})
          .eq('id', id)
          .select('id');
      if (res.isEmpty) {
        return {
          'ok': false,
          'error': 'Update nahi hua — row nahi mili ya permission nahi hai.'
        };
      }
      await _audit(
        action: active ? 'slider_activated' : 'slider_deactivated',
        targetType: 'slider',
        targetId: id,
        newValue: {'active': active},
      );
      return {'ok': true};
    } catch (e) {
      return {'ok': false, 'error': e.toString()};
    }
  }

  /// Live pick lists for ad / slider tap targets. Never invents a
  /// target — the admin picks from real rows only.
  static Future<List<Map<String, dynamic>>> getTargetOptions(
      String type) async {
    switch (type) {
      case 'game':
        return AdminDb.getList('games', orderBy: 'sort_order', ascending: true);
      case 'promotion':
        return AdminDb.getList('promotions',
            orderBy: 'created_at', ascending: false);
      case 'tournament':
      default:
        return AdminDb.getList('tournaments',
            orderBy: 'created_at', ascending: false, limit: 100);
    }
  }

  // ------------------------------------------------------------------
  // Notifications inbox (AGGREGATION — there is no inbox table).
  //   Reports    = disputes whose reason is a chat report
  //                ('Chat report [message <id>] ...', room_screen)
  //   Tournament = other disputes (file_dispute — tournament-linked)
  //   Support    = support_tickets
  //   System     = global notifications (broadcast history)
  // Unread = open disputes + open/reviewing tickets. Broadcast rows
  // have no read state and never count as unread.
  // ------------------------------------------------------------------

  static Map<String, String> parseChatReportReason(String reason) {
    final m = RegExp(
      r'Chat report \[message ([^\]]+)\] ([^:]+): "(.*)"',
      dotAll: true,
    ).firstMatch(reason);
    if (m == null) return {'messageId': '', 'reportReason': '', 'excerpt': reason};
    return {
      'messageId': m.group(1) ?? '',
      'reportReason': m.group(2) ?? '',
      'excerpt': m.group(3) ?? '',
    };
  }

  static Future<List<Map<String, dynamic>>> getInboxItems() async {
    final disputes = await AdminDb.getList('disputes',
        orderBy: 'created_at', ascending: false, limit: 100);
    final tickets = await AdminDb.getList('support_tickets',
        orderBy: 'created_at', ascending: false, limit: 100);
    final notes = await AdminDb.getList('notifications',
        orderBy: 'created_at', ascending: false, limit: 50);

    // Resolve tournament names + reporter names in bulk (one query
    // each, never one per row).
    final tIds = <String>{
      for (final d in disputes)
        if (SupaDb.strOf(d['tournament_id']).isNotEmpty)
          SupaDb.strOf(d['tournament_id']),
    };
    final tNames = <String, String>{};
    if (tIds.isNotEmpty) {
      try {
        final rows = await SupaDb.client
            .from('tournaments')
            .select('id,name')
            .inFilter('id', tIds.toList());
        for (final r in (rows as List)) {
          final m = Map<String, dynamic>.from(r as Map);
          tNames[SupaDb.strOf(m['id'])] = SupaDb.strOf(m['name']);
        }
      } catch (_) {}
    }
    final uids = <String>{
      for (final d in disputes) ...[
        SupaDb.strOf(d['raised_by']),
        SupaDb.strOf(d['against_uid']),
      ],
      for (final t in tickets) SupaDb.strOf(t['firebase_uid']),
    }..removeWhere((e) => e.isEmpty);
    final profiles = await getProfilesMap(uids.toList());

    String displayName(String uid) {
      final p = profiles[uid];
      if (p == null) return uid;
      return SupaDb.strOf(p['display_name'], SupaDb.strOf(p['displayName'], uid));
    }

    final items = <Map<String, dynamic>>[];
    for (final d in disputes) {
      final reason = SupaDb.strOf(d['reason']);
      final isChat = reason.startsWith('Chat report');
      final parsed = isChat ? parseChatReportReason(reason) : const <String, String>{};
      final tName = tNames[SupaDb.strOf(d['tournament_id'])] ?? '';
      items.add({
        '_kind': 'report',
        '_category': isChat ? 'Reports' : 'Tournament',
        '_id': SupaDb.strOf(d['id']),
        '_title': isChat
            ? 'Chat report — ${displayName(SupaDb.strOf(d['against_uid']))}'
            : 'Dispute — ${tName.isEmpty ? 'Tournament' : tName}',
        '_subtitle': isChat
            ? '${parsed['reportReason'] ?? ''}${(parsed['excerpt'] ?? '').isEmpty ? '' : ': "${parsed['excerpt']}"'}'
            : reason,
        '_time': d['created_at'],
        '_unread': SupaDb.strOf(d['status'], 'open') == 'open',
        '_status': SupaDb.strOf(d['status'], 'open'),
        '_ref': Map<String, dynamic>.from(d),
        '_tournamentName': tName,
        '_againstName': displayName(SupaDb.strOf(d['against_uid'])),
        '_raisedByName': displayName(SupaDb.strOf(d['raised_by'])),
        '_messageId': parsed['messageId'] ?? '',
      });
    }
    for (final t in tickets) {
      final status = SupaDb.strOf(t['status'], 'open');
      items.add({
        '_kind': 'ticket',
        '_category': 'Support',
        '_id': SupaDb.strOf(t['id']),
        '_title': SupaDb.strOf(t['subject'], 'Support ticket'),
        '_subtitle': SupaDb.strOf(t['message']),
        '_time': t['created_at'],
        '_unread': status == 'open' || status == 'reviewing',
        '_status': status,
        '_ref': Map<String, dynamic>.from(t),
        '_raisedByName': SupaDb.strOf(t['user_email'],
            displayName(SupaDb.strOf(t['firebase_uid']))),
      });
    }
    for (final n in notes) {
      items.add({
        '_kind': 'broadcast',
        '_category': 'System',
        '_id': SupaDb.strOf(n['id']),
        '_title': SupaDb.strOf(n['title'], 'Broadcast'),
        '_subtitle': SupaDb.strOf(n['message']),
        '_time': n['created_at'],
        '_unread': false,
        '_status': 'sent',
        '_ref': Map<String, dynamic>.from(n),
      });
    }
    items.sort((a, b) => SupaDb.parseTs(b['_time'])
        .compareTo(SupaDb.parseTs(a['_time'])));
    return items;
  }

  // ------------------------------------------------------------------
  // Broadcasts (AdminDb.sendBroadcast shape).
  // Writes ONE `notifications` row (global history) + ONE
  // `user_notifications` row per audience member, then triggers
  // OneSignal via the existing REST path (app_settings.onesignal —
  // keys are read at send time, never hardcoded, never stored in the
  // app). In-app rows are the guaranteed delivery; push is
  // best-effort and its result is reported honestly.
  // SCHEDULE GAP (honest): there is no server scheduler and no
  // scheduled_broadcasts table, so a future "send at" time cannot
  // delay delivery — the broadcast sends immediately and the
  // requested time is recorded on the audit row for reference.
  // ------------------------------------------------------------------

  static Future<Map<String, dynamic>> sendBroadcast({
    required String title,
    required String message,
    String? imageUrl,
    required String audience, // 'all' | 'admins' | 'single'
    required String category,
    String? singleUid,
    DateTime? scheduledFor,
  }) async {
    final result = <String, dynamic>{
      'ok': false,
      'inAppCount': 0,
      'pushDevices': 0,
      'pushConfigured': false,
      'pushError': '',
      'error': '',
    };
    try {
      // Audience UIDs (never invent one).
      var targetUids = <String>[];
      if (audience == 'single') {
        if (singleUid == null || singleUid.isEmpty) {
          result['error'] = 'Pick a player first.';
          return result;
        }
        targetUids = [singleUid];
      } else if (audience == 'admins') {
        final admins = await AdminDb.getList('admin_users');
        targetUids = [
          for (final a in admins)
            if (SupaDb.strOf(a['firebase_uid']).isNotEmpty)
              SupaDb.strOf(a['firebase_uid']),
        ];
        // admin_users does not exist live — fall back to the designated
        // admin (admin_config id=1) so 'admins' still reaches someone.
        if (targetUids.isEmpty) {
          final adminUid = await SupaDb.designatedAdminUid();
          if (adminUid.isNotEmpty) targetUids = [adminUid];
        }
      } else {
        final profiles = await AdminDb.getList('profiles',
            orderBy: 'created_at', ascending: false, limit: 1000);
        targetUids = [
          for (final p in profiles)
            if (SupaDb.strOf(p['firebase_uid']).isNotEmpty)
              SupaDb.strOf(p['firebase_uid']),
        ];
      }
      if (targetUids.isEmpty) {
        result['error'] = 'No users found for this audience. Nothing was sent.';
        return result;
      }

      // In-app rows — scoped to the audience (audit fix 2026-11-21):
      // 'all' writes ONLY the global row (every user reads it, so
      // per-user copies would render the same broadcast TWICE);
      // 'single'/'admins' write ONLY per-user rows (a global row would
      // leak a private message to everyone). Category is stored on the
      // row (live column) so the user app can honour notification
      // prefs; a missing column falls back to a category-less insert.
      var written = 0;
      if (audience == 'all') {
        try {
          await SupaDb.client.from('notifications').insert({
            'title': title.trim(),
            'message': message.trim(),
            'category': category,
            if (imageUrl != null && imageUrl.trim().isNotEmpty)
              'image_url': imageUrl.trim(),
          });
        } catch (_) {
          await SupaDb.client.from('notifications').insert({
            'title': title.trim(),
            'message': message.trim(),
            if (imageUrl != null && imageUrl.trim().isNotEmpty)
              'image_url': imageUrl.trim(),
          });
        }
        written = targetUids.length;
      } else {
        for (var i = 0; i < targetUids.length; i += 100) {
          final chunk = targetUids.sublist(
            i,
            (i + 100).clamp(0, targetUids.length),
          );
          final rows = [
            for (final uid in chunk)
              {
                'firebase_uid': uid,
                'title': title.trim(),
                'message': message.trim(),
                'category': category,
                if (imageUrl != null && imageUrl.trim().isNotEmpty)
                  'image_url': imageUrl.trim(),
              },
          ];
          try {
            final res = await SupaDb.client
                .from('user_notifications')
                .insert(rows)
                .select('id');
            written += res.length;
          } catch (_) {
            // Missing category column on this DB — retry without it.
            try {
              final plain = [
                for (final r in rows)
                  {
                    for (final e in r.entries)
                      if (e.key != 'category') e.key: e.value
                  },
              ];
              final res = await SupaDb.client
                  .from('user_notifications')
                  .insert(plain)
                  .select('id');
              written += res.length;
            } catch (_) {
              // One failed batch must not silently drop the rest.
            }
          }
        }
      }
      result['inAppCount'] = written;

      // 3) OneSignal push (existing path, keys from app_settings).
      final push = await _sendOneSignalPush(
        title: title.trim(),
        message: message.trim(),
        audience: audience,
        targetUids: targetUids,
        imageUrl: imageUrl,
        category: category,
      );
      result['pushConfigured'] = push['configured'] as bool;
      result['pushDevices'] = push['devices'] as int;
      result['pushError'] = push['error'] as String;

      result['ok'] = written > 0;
      if (written == 0) {
        result['error'] = 'In-app rows could not be written. Push was '
            '${(push['devices'] as int) > 0 ? 'sent to ${push['devices']} device(s)' : 'not sent'} — check the history and retry.';
      }
      await _audit(
        action: 'broadcast_sent',
        targetType: 'broadcast',
        newValue: {
          'title': title.trim(),
          'audience': audience,
          'category': category,
          'in_app_rows': written,
          'push_devices': push['devices'],
          'push_configured': push['configured'],
          if (scheduledFor != null)
            'requested_send_at': scheduledFor.toUtc().toIso8601String(),
          if (scheduledFor != null)
            'schedule_note':
                'No server scheduler exists — sent immediately; requested time recorded only.',
        },
      );
      return result;
    } catch (e) {
      result['error'] = e.toString();
      return result;
    }
  }

  /// OneSignal REST send, ported from the admin app's PushComposeScreen:
  /// keys ONLY from app_settings.onesignal at send time. Returns
  /// {configured, devices, error}. Never throws.
  ///
  /// IMAGE (2026-11-20 fix — push arrived text-only before): the
  /// broadcast imageUrl is passed in and added to the payload as
  /// `big_picture` (Android) and `ios_attachments: {'id': url}`
  /// (iOS), per the OneSignal REST API Create Notification docs.
  /// Image keys are included ONLY when imageUrl is non-empty.
  static Future<Map<String, dynamic>> _sendOneSignalPush({
    required String title,
    required String message,
    required String audience,
    required List<String> targetUids,
    String? imageUrl,
    String category = 'System',
  }) async {
    try {
      final settings = await SupaDb.getAppSettings();
      final one = SupaDb.asMap(settings['onesignal']);
      final appId = SupaDb.strOf(one['appId'],
          SupaDb.strOf(one['app_id'], SupaDb.strOf(settings['onesignal_app_id'])));
      final restKey = SupaDb.strOf(one['restApiKey'],
          SupaDb.strOf(one['rest_api_key'], SupaDb.strOf(settings['onesignal_rest_api_key'])));
      if (appId.isEmpty || restKey.isEmpty) {
        return {
          'configured': false,
          'devices': 0,
          'error':
              'OneSignal is not configured (App ID / REST key missing in app_settings → onesignal). In-app rows were still written.',
        };
      }
      // Player IDs live on profiles.onesignal_id (PushService syncs it
      // when a user opens the app). Users without one still get the
      // in-app row — push simply cannot reach them yet.
      final profiles = await getProfilesMap(targetUids);
      final ids = <String>[];
      for (final uid in targetUids) {
        final p = profiles[uid];
        if (p == null) continue;
        // Notification prefs: a user who muted this category gets no
        // push for it (audit fix 2026-11-21 — same mapping as the
        // inbox filter, SupaDb.prefKeyForCategory).
        final prefKey = SupaDb.prefKeyForCategory(category);
        if (prefKey != null) {
          final userPrefs = SupaDb.asMap(p['notification_prefs']);
          if (userPrefs[prefKey] == false) continue;
        }
        final pid = SupaDb.strOf(p['onesignal_id'], SupaDb.strOf(p['onesignalId']));
        if (pid.isNotEmpty) ids.add(pid);
      }
      if (ids.isEmpty) {
        return {
          'configured': true,
          'devices': 0,
          'error':
              'No OneSignal player IDs for this audience — users must open the app once (it stores onesignal_id) before push can reach them. In-app rows were still written.',
        };
      }
      final resp = await http
          .post(
            Uri.parse('https://api.onesignal.com/notifications'),
            headers: {
              'Content-Type': 'application/json; charset=utf-8',
              'Authorization': 'Basic $restKey',
            },
            body: jsonEncode({
              'app_id': appId,
              'headings': {'en': title},
              'contents': {'en': message},
              'include_player_ids': ids,
              if (imageUrl != null && imageUrl.trim().isNotEmpty)
                'big_picture': imageUrl.trim(),
              if (imageUrl != null && imageUrl.trim().isNotEmpty)
                'ios_attachments': {'id': imageUrl.trim()},
            }),
          )
          .timeout(const Duration(seconds: 20));
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        return {
          'configured': true,
          'devices': 0,
          'error': 'OneSignal rejected the send (HTTP ${resp.statusCode}). In-app rows were still written.',
        };
      }
      return {'configured': true, 'devices': ids.length, 'error': ''};
    } catch (e) {
      return {'configured': false, 'devices': 0, 'error': e.toString()};
    }
  }

  static Future<List<Map<String, dynamic>>> getBroadcastHistory() =>
      AdminDb.getList('notifications',
          orderBy: 'created_at', ascending: false, limit: 50);

  /// Delete one broadcast history row (`notifications`) + audit
  /// row. HONEST LIMIT: this deletes the HISTORY entry only — the
  /// per-user `user_notifications` rows already delivered stay in
  /// players' inboxes, and a push already sent cannot be recalled.
  /// Returns {'ok', 'error'?}.
  static Future<Map<String, dynamic>> deleteBroadcast(String id) async {
    try {
      final old = await AdminDb.getRow('notifications', 'id', id);
      if (old == null) return {'ok': true, 'alreadyGone': true};
      await SupaDb.client.from('notifications').delete().eq('id', id);
      final gone = await AdminDb.getRow('notifications', 'id', id) == null;
      if (!gone) {
        return {
          'ok': false,
          'error':
              'Delete refuse ho gaya — broadcast abhi bhi maujood hai (shayad permission/RLS issue hai).'
        };
      }
      await _audit(
        action: 'broadcast_deleted',
        targetType: 'broadcast',
        targetId: id,
        oldValue: {'title': SupaDb.strOf(old['title'])},
      );
      return {'ok': true};
    } catch (e) {
      return {'ok': false, 'error': e.toString()};
    }
  }

  /// Players for the single-player audience picker: only real
  /// profiles, push-ready first (those with a OneSignal player ID).
  static Future<List<Map<String, dynamic>>> getBroadcastTargets() async {
    final rows = await AdminDb.getList('profiles',
        orderBy: 'created_at', ascending: false, limit: 500);
    rows.sort((a, b) {
      final ap = SupaDb.strOf(a['onesignal_id'], SupaDb.strOf(a['onesignalId'])).isEmpty ? 1 : 0;
      final bp = SupaDb.strOf(b['onesignal_id'], SupaDb.strOf(b['onesignalId'])).isEmpty ? 1 : 0;
      if (ap != bp) return ap.compareTo(bp);
      return SupaDb.strOf(a['display_name'], SupaDb.strOf(a['displayName']))
          .toLowerCase()
          .compareTo(SupaDb.strOf(b['display_name'], SupaDb.strOf(b['displayName'])).toLowerCase());
    });
    return rows;
  }

  // ------------------------------------------------------------------
  // Chat moderation.
  // Reports live in `disputes` (008) — reportChatMessage writes them
  // with reason 'Chat report [message <id>] <reason>: "<excerpt>"'.
  // 032 tables are LIVE (verified 2026-11-21): chat_messages has
  // deleted_by/deleted_at and chat_restrictions exists (firebase_uid /
  // reason / created_at) — so Remove / Restrict work via the direct
  // writes below. No reliance on the admin_moderate_chat RPC, whose
  // draft shape does not match the live chat_restrictions columns.
  // Warn works via user_warnings (008), ported addUserWarning legacy
  // path. NOTE: warn itself is record-only — nothing in the user app
  // reads user_warnings, so a warn does not change what the user can
  // do; Restrict is the enforcing action.
  // Dismiss = dispute status → resolved + admin note (DIRECT-WRITE +
  // audit). The 023 resolve_dispute RPC is result-dispute vocabulary
  // (p_resolution / p_overturn) and is NOT used for chat-report
  // dismissals — that RPC belongs to the Disputes screen.
  // ------------------------------------------------------------------

  static Future<List<Map<String, dynamic>>> getChatReports() async {
    final rows = await AdminDb.getList('disputes',
        orderBy: 'created_at', ascending: false, limit: 200);
    return rows
        .where((d) => SupaDb.strOf(d['reason']).startsWith('Chat report'))
        .toList();
  }

  static Future<List<Map<String, dynamic>>> getChatMessages(
      String tournamentId) {
    if (tournamentId.isEmpty) return Future.value([]);
    return AdminDb.getList('chat_messages',
        eq: {'tournament_id': tournamentId},
        orderBy: 'created_at',
        ascending: false,
        limit: 100);
  }

  static Future<List<Map<String, dynamic>>> getWarnings({String? uid}) {
    if (uid != null && uid.isNotEmpty) {
      return AdminDb.getList('user_warnings',
          eq: {'firebase_uid': uid},
          orderBy: 'created_at',
          ascending: false,
          limit: 200);
    }
    return AdminDb.getList('user_warnings',
        orderBy: 'created_at', ascending: false, limit: 200);
  }

  static Future<bool> dismissReport(String disputeId, String note) async {
    try {
      final old = await AdminDb.getRow('disputes', 'id', disputeId);
      final res = await SupaDb.client
          .from('disputes')
          .update({
            'status': 'resolved',
            'admin_note': note.trim().isEmpty ? 'Dismissed by admin.' : note.trim(),
          })
          .eq('id', disputeId)
          .select('id');
      final ok = res.isNotEmpty;
      if (ok) {
        await _audit(
          action: 'chat_report_dismissed',
          targetType: 'dispute',
          targetId: disputeId,
          oldValue: old == null ? null : {'status': SupaDb.strOf(old['status'])},
          newValue: {'status': 'resolved'},
          reason: note.trim().isEmpty ? null : note.trim(),
        );
      }
      return ok;
    } catch (_) {
      return false;
    }
  }

  /// Warn a user — ported admin legacy addUserWarning: one
  /// `user_warnings` row (type 'warn') + audit row. DIRECT-WRITE.
  static Future<bool> warnUser({
    required String targetUid,
    required String reason,
  }) async {
    if (targetUid.isEmpty || reason.trim().isEmpty) return false;
    try {
      final res = await SupaDb.client.from('user_warnings').insert({
        'firebase_uid': targetUid,
        'type': 'warn',
        'reason': reason.trim(),
        'by_admin': _adminUid,
      }).select('id');
      final ok = res.isNotEmpty;
      if (ok) {
        await _audit(
          action: 'user_warned',
          targetType: 'user',
          targetId: targetUid,
          newValue: {'type': 'warn'},
          reason: reason.trim(),
        );
      }
      return ok;
    } catch (_) {
      return false;
    }
  }

  /// Moderation via the `admin_moderate_chat` RPC (migration 032 —
  /// apply it in the Supabase SQL Editor before this can succeed).
  /// Passes the signed-in admin's Firebase UID as p_admin_uid: the
  /// app has no Supabase Auth session, so the RPC checks the
  /// designated admin server-side against admin_config id=1 (see
  /// 032 header). The UI keeps Remove / Restrict disabled until
  /// 032 is applied; this method exists so the switch is a one-line
  /// enable. Returns {ok, error}. Never throws.
  /// p_action: delete_message | restrict_chat | unrestrict_chat.
  static Future<Map<String, dynamic>> moderateChat({
    String? messageId,
    String? targetUid,
    required String action,
    required String reason,
  }) async {
    try {
      final res = await SupaDb.client.rpc('admin_moderate_chat', params: {
        'p_admin_uid': FirebaseAuth.instance.currentUser?.uid ?? '',
        'p_message_id': messageId,
        'p_target_uid': targetUid,
        'p_action': action,
        'p_reason': reason.trim(),
      });
      if (res is Map) return Map<String, dynamic>.from(res);
      return {'ok': true};
    } catch (e) {
      return {'ok': false, 'error': e.toString()};
    }
  }

  // Direct-write moderation (032 tables live — see header above).
  // Delete is a soft delete (deleted_at/deleted_by); the user app
  // filters such rows out of every chat read. Restrict inserts one
  // chat_restrictions row; the user app refuses to send while a row
  // exists (SupaDb.isChatRestricted). Unrestrict deletes the row.
  // All three write an audit row; all return {'ok', 'error'?}.

  static Future<Map<String, dynamic>> deleteChatMessage({
    required String messageId,
    required String reason,
  }) async {
    try {
      final res = await SupaDb.client
          .from('chat_messages')
          .update({
            'deleted_at': SupaDb.isoNow(),
            'deleted_by': _adminUid,
          })
          .eq('id', messageId)
          .select('id');
      if (res.isEmpty) {
        return {
          'ok': false,
          'error': 'Message nahi mila — shayad pehle se delete ho chuka hai.'
        };
      }
      await _audit(
        action: 'chat_message_deleted',
        targetType: 'chat_message',
        targetId: messageId,
        newValue: {'reason': reason.trim()},
      );
      return {'ok': true};
    } catch (e) {
      return {'ok': false, 'error': e.toString()};
    }
  }

  static Future<Map<String, dynamic>> restrictChatUser({
    required String targetUid,
    required String reason,
  }) async {
    try {
      await SupaDb.client.from('chat_restrictions').insert({
        'firebase_uid': targetUid,
        'reason': reason.trim(),
      });
      await _audit(
        action: 'chat_user_restricted',
        targetType: 'player',
        targetId: targetUid,
        newValue: {'reason': reason.trim()},
      );
      return {'ok': true};
    } catch (e) {
      return {'ok': false, 'error': e.toString()};
    }
  }

  static Future<Map<String, dynamic>> unrestrictChatUser({
    required String targetUid,
  }) async {
    try {
      await SupaDb.client
          .from('chat_restrictions')
          .delete()
          .eq('firebase_uid', targetUid);
      // F23 (2026-11-22): a DELETE denied/dropped by RLS returns no
      // error — re-read to prove the restriction is really gone,
      // otherwise the user stays muted while the admin sees success.
      final remaining = await AdminDb.getList('chat_restrictions',
          eq: {'firebase_uid': targetUid}, limit: 1);
      if (remaining.isNotEmpty) {
        return {
          'ok': false,
          'error':
              'Unrestrict nahi hua — restriction abhi bhi maujood hai (shayad permission/RLS issue hai).'
        };
      }
      await _audit(
        action: 'chat_user_unrestricted',
        targetType: 'player',
        targetId: targetUid,
      );
      return {'ok': true};
    } catch (e) {
      return {'ok': false, 'error': e.toString()};
    }
  }

  static Future<List<Map<String, dynamic>>> getChatRestrictions() =>
      AdminDb.getList('chat_restrictions',
          orderBy: 'created_at', ascending: false, limit: 200);

  /// Ban a user by device + account (v2013, Watch Live
  /// moderation). Inserts one `device_bans` row (firebase_uid +
  /// the device id from the target's profile when it can be read).
  /// `DeviceBanGate` enforces it at the NEXT login (uid OR device
  /// match) — a ban does NOT eject a live session; that is kick's
  /// job (restrict + the target's screen exiting on its poll).
  /// The insert is verified (`.select('id')` must come back
  /// non-empty) so an RLS denial reports honestly instead of
  /// looking like success. Returns {'ok', 'error'?}. Never throws.
  static Future<Map<String, dynamic>> banDeviceUser({
    required String targetUid,
    required String reason,
  }) async {
    if (targetUid.isEmpty) {
      return {'ok': false, 'error': 'User nahi mila.'};
    }
    // Best-effort device lookup: the ban enforces by uid alone,
    // but a device row also blocks a fresh account on the same
    // phone. A failed lookup must never block the ban itself.
    var deviceId = '';
    try {
      final profile =
          await SupaDb.getRow('profiles', 'firebase_uid', targetUid);
      deviceId = SupaDb.strOf(profile['device_id']);
    } catch (_) {}
    // device_id is NOT NULL: when the device is unknown, store a
    // per-user placeholder instead of '' — '' would collide on a
    // second ban if the column ever gains a unique index, and
    // 'uid:<uid>' can never match a real 32-hex-char device id, so
    // the gate's device check stays correct.
    final deviceValue = deviceId.isEmpty ? 'uid:$targetUid' : deviceId;
    try {
      final res = await SupaDb.client.from('device_bans').insert({
        'device_id': deviceValue,
        'firebase_uid': targetUid,
        'reason': reason.trim(),
        'banned_by': _adminUid,
      }).select('id');
      if (res.isEmpty) {
        return {
          'ok': false,
          'error': 'Ban save nahi ho saka — shayad permission issue hai.'
        };
      }
      await _audit(
        action: 'user_device_banned',
        targetType: 'player',
        targetId: targetUid,
        newValue: {'reason': reason.trim()},
      );
      return {'ok': true};
    } catch (e) {
      return {'ok': false, 'error': e.toString()};
    }
  }

  // Team chats (scope 'team', tournament_id '') are invisible to the
  // tournament-filtered read above — this is the moderation view for
  // them (audit fix 2026-11-21).
  static Future<List<Map<String, dynamic>>> getTeamChatMessages() =>
      AdminDb.getList('chat_messages',
          eq: {'scope': 'team'},
          orderBy: 'created_at',
          ascending: false,
          limit: 100);

  // ------------------------------------------------------------------
  // Support tickets.
  // support_tickets (001 + 019): status open / reviewing / responded /
  // resolved. Threaded replies live in support_messages (019) with
  // sender_role 'user' | 'admin'. Replying sets status 'responded'
  // (NOT resolved — resolving is a separate, explicit action).
  // ------------------------------------------------------------------

  static Future<List<Map<String, dynamic>>> getSupportTickets(
      {String? status}) {
    if (status != null && status.isNotEmpty && status != 'all') {
      return AdminDb.getList('support_tickets',
          eq: {'status': status},
          orderBy: 'created_at',
          ascending: false,
          limit: 200);
    }
    return AdminDb.getList('support_tickets',
        orderBy: 'created_at', ascending: false, limit: 200);
  }

  static Future<List<Map<String, dynamic>>> getTicketThread(
          String ticketId) =>
      SupaDb.getTicketThread(ticketId);

  /// Admin reply: support_messages row (sender_role 'admin') +
  /// support_tickets.reply / status 'responded' / replied_at /
  /// replied_by + audit row. DIRECT-WRITE (no RPC exists). The two
  /// writes are ordered (message first); if the ticket update fails
  /// the message row stays and the method reports false honestly.
  static Future<bool> replyTicketAdmin(
      String ticketId, String message) async {
    if (ticketId.isEmpty || message.trim().isEmpty) return false;
    final uid = _adminUid;
    if (uid.isEmpty) return false;
    try {
      final msgRes = await SupaDb.client.from('support_messages').insert({
        'ticket_id': ticketId,
        'sender_id': uid,
        'sender_role': 'admin',
        'message': message.trim(),
      }).select('id');
      if (msgRes.isEmpty) return false;
      final old = await AdminDb.getRow('support_tickets', 'id', ticketId);
      final upd = await SupaDb.client
          .from('support_tickets')
          .update({
            'reply': message.trim(),
            'status': 'responded',
            'replied_at': SupaDb.isoNow(),
            'replied_by': uid,
          })
          .eq('id', ticketId)
          .select('id');
      final ok = upd.isNotEmpty;
      if (ok) {
        await _audit(
          action: 'ticket_replied',
          targetType: 'support_ticket',
          targetId: ticketId,
          oldValue: old == null ? null : {'status': SupaDb.strOf(old['status'])},
          newValue: {'status': 'responded'},
        );
        // The ticket page promises the user will be notified — send the
        // in-app notification (audit fix 2026-11-21).
        try {
          final owner = SupaDb.strOf(old?['firebase_uid']);
          if (owner.isNotEmpty) {
            await SupaDb.notifyUser(owner, 'Support Reply',
                'Aapke support ticket par admin ne jawab diya hai. My Tickets mein dekh sakte hain.');
          }
        } catch (_) {}
      }
      return ok;
    } catch (_) {
      return false;
    }
  }

  /// Explicit resolve (separate from replying). DIRECT-WRITE + audit.
  static Future<bool> resolveTicketAdmin(String ticketId) async {
    if (ticketId.isEmpty) return false;
    try {
      final old = await AdminDb.getRow('support_tickets', 'id', ticketId);
      final res = await SupaDb.client
          .from('support_tickets')
          .update({'status': 'resolved'})
          .eq('id', ticketId)
          .select('id');
      final ok = res.isNotEmpty;
      if (ok) {
        await _audit(
          action: 'ticket_resolved',
          targetType: 'support_ticket',
          targetId: ticketId,
          oldValue: old == null ? null : {'status': SupaDb.strOf(old['status'])},
          newValue: {'status': 'resolved'},
        );
      }
      return ok;
    } catch (_) {
      return false;
    }
  }

  /// Delete one support ticket + its thread (support_messages) +
  /// audit row. Returns {'ok', 'threadOk', 'error'?}. The ticket is gone for
  /// the player too — delete is for spam / test tickets; resolving
  /// is the normal path.
  /// F23 (2026-11-22): the thread delete is verified too — a
  /// silently dropped thread delete leaves orphaned support_messages
  /// rows. 'ok' reports the TICKET (the primary object); 'threadOk'
  /// reports the thread cleanup separately so a caller can surface
  /// it honestly instead of claiming a clean delete. The support
  /// screen should toast the thread failure when threadOk is false.
  static Future<Map<String, dynamic>> deleteTicket(String ticketId) async {
    try {
      final old = await AdminDb.getRow('support_tickets', 'id', ticketId);
      if (old == null) return {'ok': true, 'alreadyGone': true, 'threadOk': true};
      await SupaDb.client
          .from('support_messages')
          .delete()
          .eq('ticket_id', ticketId);
      await SupaDb.client
          .from('support_tickets')
          .delete()
          .eq('id', ticketId);
      final gone =
          await AdminDb.getRow('support_tickets', 'id', ticketId) == null;
      if (!gone) {
        return {
          'ok': false,
          'threadOk': false,
          'error':
              'Delete refuse ho gaya — ticket abhi bhi maujood hai (shayad permission/RLS issue hai).'
        };
      }
      final threadLeft = await AdminDb.getList('support_messages',
          eq: {'ticket_id': ticketId}, limit: 1);
      final threadOk = threadLeft.isEmpty;
      await _audit(
        action: 'ticket_deleted',
        targetType: 'support_ticket',
        targetId: ticketId,
        oldValue: {'subject': SupaDb.strOf(old['subject'])},
      );
      return {
        'ok': true,
        'threadOk': threadOk,
        if (!threadOk)
          'error':
              'Ticket delete ho gaya, lekin us ki thread (support_messages) delete nahi ho saki — permission issue ho sakta hai.'
      };
    } catch (e) {
      return {'ok': false, 'error': e.toString()};
    }
  }

  // ------------------------------------------------------------------
  // Live support.
  // TRANSPORT (correction to the task wording, with evidence): the
  // live-support chat that actually exists in this codebase is
  // `live_support_messages` (011) — the user side reads/writes it
  // (pro_features.dart:9049, is_admin=false rows) and the admin-app
  // reference LiveSupportAdminScreen streams it (is_admin=true
  // replies). `support_messages` is the ticket thread (used by the
  // Support screen above) and `voice_signaling_inbox` is WebRTC
  // signaling — neither is the live chat. No new realtime infra:
  // the existing Supabase realtime stream on live_support_messages.
  // ------------------------------------------------------------------

  static Stream<List<Map<String, dynamic>>> streamLiveSupport() =>
      SupaDb.client
          .from('live_support_messages')
          .stream(primaryKey: ['id'])
          .order('created_at')
          .map((rows) => (rows as List)
              .map((r) => Map<String, dynamic>.from(r as Map))
              .toList());

  static Future<bool> sendLiveSupportReply({
    required String targetUid,
    required String message,
  }) async {
    if (targetUid.isEmpty || message.trim().isEmpty) return false;
    try {
      final res = await SupaDb.client.from('live_support_messages').insert({
        'firebase_uid': targetUid,
        'display_name': 'Admin',
        'message': message.trim(),
        'is_admin': true,
      }).select('id');
      final ok = res.isNotEmpty;
      if (ok) {
        await _audit(
          action: 'live_support_reply',
          targetType: 'user',
          targetId: targetUid,
        );
      }
      return ok;
    } catch (_) {
      return false;
    }
  }

  // ------------------------------------------------------------------
  // Presence (read-only — the user app writes it).
  // Online = last_seen within 2 min (SupaDb.presenceIsOnline, the
  // single ROUND 11 rule). This screen never edits presence.
  // ------------------------------------------------------------------

  static Future<List<Map<String, dynamic>>> getPresenceList() =>
      AdminDb.getList('presence',
          orderBy: 'last_seen', ascending: false, limit: 200);

  static Future<List<Map<String, dynamic>>> getTournamentsForPicker() =>
      AdminDb.getList('tournaments',
          orderBy: 'created_at', ascending: false, limit: 100);
}
