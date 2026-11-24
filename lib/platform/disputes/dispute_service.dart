import 'dart:convert';
import 'dart:math';

import 'package:protournament_user/platform/core/exceptions.dart';
import 'package:protournament_user/platform/core/local_store.dart';
import 'package:protournament_user/services/supabase_db.dart';

/// Dispute + exception storage (ChatGPT blueprint §5-7; backend
/// guide §5-7 `disputes` + `exception_reports` tables).
///
/// LOCAL-STORE BACKED for the blueprint's auto-generated
/// exceptions (check-in, scoring, no-shows): those records live in
/// [PlatformLocalStore] under area `disputes` (one list, id `all`).
/// The stored maps use the guide's column names (`kind`,
/// `tournament_id`, `match_id`, `evidence_urls`, `resolution`,
/// `resolved_by`, `reported_by`, `created_at`, `resolved_at`) so a
/// later server sync can read them as-is.
///
/// The backend `disputes` table HAS landed (live, verified
/// 2026-11-21) — [listServerDisputes] reads real player disputes
/// from it, and the Moderation Center merges both sources. The
/// local store is now only the exceptions half of the queue.
///
/// EVIDENCE RULE (guide §4 / §5-7): evidence URLs are screenshot
/// URLs stored exactly as given. A screenshot is evidence for a
/// dispute — it is NEVER payment proof (that rule belongs to the
/// payments workstream; nothing here touches money).
///
/// The live `disputes` table + the 023 `resolve_dispute` RPC (see
/// admin_disputes.dart) are a SEPARATE, older flow. This service
/// is the blueprint's Action Required Center queue; when the
/// backend `disputes` table from the guide is live, this service
/// is replaced by server reads — the [DisputeRecord] shape already
/// matches the guide's columns.

/// One dispute/exception record: the platform [ActionItem] plus
/// the guide's extra `disputes` columns that [ActionItem] does not
/// carry (`match_id`, `reported_by`, `evidence_urls`,
/// `resolution`, `resolved_by`).
class DisputeRecord {
  final ActionItem item;
  final String matchId;
  final String reportedBy;
  final List<String> evidenceUrls;
  final String resolution;
  final String resolvedBy;

  const DisputeRecord({
    required this.item,
    this.matchId = '',
    this.reportedBy = '',
    this.evidenceUrls = const [],
    this.resolution = '',
    this.resolvedBy = '',
  });

  String get id => item.id;
  ExceptionType get type => item.type;
  String get title => item.title;
  String get detail => item.detail;
  String get tournamentId => item.tournamentId;
  String get targetUid => item.targetUid;
  DisputeStatus get status => item.status;
  DateTime? get createdAt => item.createdAt;
  DateTime? get resolvedAt => item.resolvedAt;

  /// True when an admin still has to act on this record.
  bool get needsAction =>
      status == DisputeStatus.open || status == DisputeStatus.underReview;

  factory DisputeRecord.fromMap(Map<String, dynamic> map) {
    final urls = map['evidence_urls'];
    return DisputeRecord(
      item: ActionItem.fromMap(map),
      matchId: (map['match_id'] ?? map['matchId'] ?? '').toString(),
      reportedBy:
          (map['reported_by'] ?? map['reportedBy'] ?? '').toString(),
      evidenceUrls: urls is List
          ? urls.map((e) => e.toString()).toList()
          : const [],
      resolution: (map['resolution'] ?? '').toString(),
      resolvedBy: (map['resolved_by'] ?? map['resolvedBy'] ?? '').toString(),
    );
  }

  Map<String, dynamic> toMap() => {
        ...item.toMap(),
        'match_id': matchId,
        'reported_by': reportedBy,
        'evidence_urls': evidenceUrls,
        'resolution': resolution,
        'resolved_by': resolvedBy,
      };

  DisputeRecord copyWith({
    ActionItem? item,
    String? matchId,
    String? reportedBy,
    List<String>? evidenceUrls,
    String? resolution,
    String? resolvedBy,
  }) =>
      DisputeRecord(
        item: item ?? this.item,
        matchId: matchId ?? this.matchId,
        reportedBy: reportedBy ?? this.reportedBy,
        evidenceUrls: evidenceUrls ?? this.evidenceUrls,
        resolution: resolution ?? this.resolution,
        resolvedBy: resolvedBy ?? this.resolvedBy,
      );
}

class DisputeService {
  static const String _area = 'disputes';
  static const String _listId = 'all';

  String _newId() {
    final rnd = Random.secure();
    final suffix = List.generate(6, (_) => rnd.nextInt(16).toRadixString(16))
        .join();
    return 'dsp_${DateTime.now().millisecondsSinceEpoch}_$suffix';
  }

  Future<List<DisputeRecord>> _loadAll() async {
    final maps = await PlatformLocalStore.loadList(_area, _listId);
    final out = maps.map(DisputeRecord.fromMap).toList();
    // Newest first.
    out.sort((a, b) {
      final at = a.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      final bt = b.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      return bt.compareTo(at);
    });
    return out;
  }

  Future<bool> _saveAll(List<DisputeRecord> records) =>
      PlatformLocalStore.saveList(
          _area, _listId, records.map((r) => r.toMap()).toList());

  /// Files a player dispute. Returns the created [ActionItem] with
  /// status [DisputeStatus.open]. `evidenceUrls` are stored as
  /// given (screenshot URLs — never payment proof).
  Future<ActionItem> fileDispute({
    required String tournamentId,
    String matchId = '',
    required ExceptionType kind,
    required String detail,
    List<String> evidenceUrls = const [],
    String reportedBy = '',
  }) async {
    final now = DateTime.now().toUtc();
    final item = ActionItem(
      id: _newId(),
      type: kind,
      title: kind.label,
      detail: detail,
      tournamentId: tournamentId,
      targetUid: reportedBy,
      status: DisputeStatus.open,
      createdAt: now,
    );
    final record = DisputeRecord(
      item: item,
      matchId: matchId,
      reportedBy: reportedBy,
      evidenceUrls: evidenceUrls,
    );
    final all = await _loadAll();
    all.insert(0, record);
    await _saveAll(all);
    return item;
  }

  /// Stores an auto-generated exception (check-in close, scoring
  /// anomaly, no-show — guide §5-7 `exception_reports`). Other
  /// workstreams call this so their exceptions land in the same
  /// Action Required queue as player disputes.
  Future<ActionItem> fileException({
    required ExceptionType kind,
    required String title,
    required String detail,
    String tournamentId = '',
    String targetUid = '',
  }) async {
    final now = DateTime.now().toUtc();
    final item = ActionItem(
      id: _newId(),
      type: kind,
      title: title,
      detail: detail,
      tournamentId: tournamentId,
      targetUid: targetUid,
      status: DisputeStatus.open,
      createdAt: now,
    );
    final all = await _loadAll();
    all.insert(0, DisputeRecord(item: item));
    await _saveAll(all);
    return item;
  }

  /// All records filed by [uid], newest first.
  Future<List<DisputeRecord>> listMyDisputes(String uid) async {
    final all = await _loadAll();
    return all.where((r) => r.reportedBy == uid).toList();
  }

  /// The Action Required queue: every record still needing a
  /// human (status `open` or `under_review`), newest first.
  Future<List<DisputeRecord>> listOpenExceptions() async {
    final all = await _loadAll();
    return all.where((r) => r.needsAction).toList();
  }

  /// Every stored record, newest first.
  Future<List<DisputeRecord>> listAll() => _loadAll();

  /// LIVE SERVER disputes (audit fix 2026-11-21): reads the real
  /// `disputes` table — player-filed disputes the admin must see.
  /// The Moderation Center merges these with the local exceptions
  /// ([listAll]); the user-side dispute screens still use the local
  /// store only. Returns [] when the table is unreachable (the
  /// local queue keeps working). Live columns verified 2026-11-21:
  /// id/kind/status/tournament_id/match_id/evidence_urls/
  /// resolution/resolved_by/created_at/resolved_at/reason. There is
  /// NO reported_by / player column live yet, so reportedBy and
  /// targetUid come back empty (backend gap — see the guide).
  Future<List<DisputeRecord>> listServerDisputes() async {
    try {
      final rows = await SupaDb.getList('disputes',
          orderBy: 'created_at', ascending: false, limit: 200);
      return rows.map(_fromServerRow).toList();
    } catch (_) {
      return [];
    }
  }

  static DisputeRecord _fromServerRow(Map<String, dynamic> m) {
    final createdMs = SupaDb.parseTs(m['created_at']);
    final resolvedMs = SupaDb.parseTs(m['resolved_at']);
    final evidence = <String>[];
    final ev = m['evidence_urls'];
    if (ev is List) {
      evidence.addAll(ev.map((e) => e.toString()));
    } else if (ev is String && ev.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(ev);
        if (decoded is List) {
          evidence.addAll(decoded.map((e) => e.toString()));
        } else {
          evidence.add(ev);
        }
      } catch (_) {
        evidence.add(ev);
      }
    }
    return DisputeRecord(
      item: ActionItem(
        id: SupaDb.strOf(m['id']),
        type: ExceptionType.fromString(SupaDb.strOf(m['kind'])),
        // No title column live — the row renderer falls back to the
        // kind label when title is empty.
        title: '',
        detail: SupaDb.strOf(m['reason']),
        tournamentId: SupaDb.strOf(m['tournament_id']),
        targetUid: '',
        status: DisputeStatus.fromString(SupaDb.strOf(m['status'])),
        createdAt: createdMs > 0
            ? DateTime.fromMillisecondsSinceEpoch(createdMs)
            : null,
        resolvedAt: resolvedMs > 0
            ? DateTime.fromMillisecondsSinceEpoch(resolvedMs)
            : null,
      ),
      matchId: SupaDb.strOf(m['match_id']),
      reportedBy: '',
      evidenceUrls: evidence,
      resolution: SupaDb.strOf(m['resolution']),
      resolvedBy: SupaDb.strOf(m['resolved_by']),
    );
  }

  Future<DisputeRecord?> getDispute(String id) async {
    final all = await _loadAll();
    for (final r in all) {
      if (r.id == id) return r;
    }
    return null;
  }

  Future<bool> _update(String id, DisputeRecord Function(DisputeRecord) fn) async {
    final all = await _loadAll();
    final idx = all.indexWhere((r) => r.id == id);
    if (idx < 0) return false;
    all[idx] = fn(all[idx]);
    return _saveAll(all);
  }

  DisputeRecord _withStatus(
    DisputeRecord r,
    DisputeStatus status, {
    String? resolution,
    String? resolvedBy,
  }) {
    final now = DateTime.now().toUtc();
    final done =
        status == DisputeStatus.resolved || status == DisputeStatus.rejected;
    return r.copyWith(
      item: ActionItem(
        id: r.item.id,
        type: r.item.type,
        title: r.item.title,
        detail: r.item.detail,
        tournamentId: r.item.tournamentId,
        targetUid: r.item.targetUid,
        status: status,
        createdAt: r.item.createdAt,
        resolvedAt: done ? now : r.item.resolvedAt,
      ),
      resolution: resolution ?? r.resolution,
      resolvedBy: resolvedBy ?? r.resolvedBy,
    );
  }

  /// Moves a record to `under_review`. Returns false when the id
  /// does not exist.
  Future<bool> markUnderReview(String id) =>
      _update(id, (r) => _withStatus(r, DisputeStatus.underReview));

  /// Resolves a record with the admin's resolution text.
  Future<bool> resolveDispute(
          String id, String resolution, String resolvedBy) =>
      _update(
          id,
          (r) => _withStatus(r, DisputeStatus.resolved,
              resolution: resolution, resolvedBy: resolvedBy));

  /// Rejects a record; [reason] is stored as the resolution text
  /// so the player can see why.
  Future<bool> rejectDispute(String id, String reason, String resolvedBy) =>
      _update(
          id,
          (r) => _withStatus(r, DisputeStatus.rejected,
              resolution: reason, resolvedBy: resolvedBy));
}
