import 'package:protournament_user/platform/core/lifecycle.dart';
import 'package:protournament_user/platform/core/local_store.dart';

/// Waitlist (ChatGPT blueprint §5-1; backend guide §5-1
/// `waitlist_entries` table).
///
/// INTERIM — LOCAL STORE ONLY: until the backend `waitlist_entries`
/// table + `register_team` RPC land, entries live in
/// [PlatformLocalStore] under area `waitlist`
/// (`platform.waitlist.<tournamentId>`). Positions are 1-based and
/// re-numbered after every promotion/cancel/expire so the waiting
/// queue is always 1..n with no gaps. Promoted/expired entries keep
/// the position they held (audit trail) and are NOT returned by
/// [getWaitlist] — only waiting entries form the visible queue.

/// One waitlist entry. `teamId` is empty for individual (solo)
/// registrations; `uid` is the Firebase UID of the player (solo)
/// or the team captain.
class WaitlistEntry {
  final String uid;
  final String teamId;
  final int position;
  final WaitlistStatus status;
  final DateTime? createdAt;

  const WaitlistEntry({
    required this.uid,
    this.teamId = '',
    required this.position,
    this.status = WaitlistStatus.waiting,
    this.createdAt,
  });

  WaitlistEntry copyWith({
    String? uid,
    String? teamId,
    int? position,
    WaitlistStatus? status,
    DateTime? createdAt,
  }) =>
      WaitlistEntry(
        uid: uid ?? this.uid,
        teamId: teamId ?? this.teamId,
        position: position ?? this.position,
        status: status ?? this.status,
        createdAt: createdAt ?? this.createdAt,
      );

  factory WaitlistEntry.fromMap(Map<String, dynamic> map) => WaitlistEntry(
        uid: (map['uid'] ?? map['firebase_uid'] ?? '').toString(),
        teamId: (map['team_id'] ?? map['teamId'] ?? '').toString(),
        position: (map['position'] as num?)?.toInt() ?? 0,
        status: WaitlistStatus.fromString((map['status'] ?? '').toString()),
        createdAt: map['created_at'] == null
            ? null
            : DateTime.tryParse(map['created_at'].toString()),
      );

  Map<String, dynamic> toMap() => {
        'uid': uid,
        'team_id': teamId,
        'position': position,
        'status': status.wireValue,
        'created_at': createdAt?.toUtc().toIso8601String(),
      };
}

class WaitlistService {
  static const String _area = 'waitlist';

  const WaitlistService();

  Future<List<WaitlistEntry>> _loadAll(String tournamentId) async {
    final rows = await PlatformLocalStore.loadList(_area, tournamentId);
    return rows.map(WaitlistEntry.fromMap).toList();
  }

  Future<bool> _saveAll(
      String tournamentId, List<WaitlistEntry> entries) async {
    return PlatformLocalStore.saveList(
        _area, tournamentId, entries.map((e) => e.toMap()).toList());
  }

  /// Re-numbers the WAITING entries 1..n in queue order (oldest
  /// first). Promoted/expired entries keep their frozen position.
  List<WaitlistEntry> _renumber(List<WaitlistEntry> entries) {
    var next = 1;
    return entries.map((e) {
      if (e.status == WaitlistStatus.waiting) {
        return e.copyWith(position: next++);
      }
      return e;
    }).toList();
  }

  /// Joins the waitlist. Returns the 1-based position. Joining
  /// twice with the same UID returns the existing position (no
  /// duplicate row). `teamId` identifies the team for team
  /// registrations; solo joins pass it empty.
  Future<int> joinWaitlist(String tournamentId, String uid,
      {String? teamId}) async {
    final entries = await _loadAll(tournamentId);
    for (final e in entries) {
      if (e.uid == uid && e.status == WaitlistStatus.waiting) {
        return e.position;
      }
    }
    final waitingCount =
        entries.where((e) => e.status == WaitlistStatus.waiting).length;
    final entry = WaitlistEntry(
      uid: uid,
      teamId: teamId ?? '',
      position: waitingCount + 1,
      createdAt: DateTime.now().toUtc(),
    );
    entries.add(entry);
    await _saveAll(tournamentId, _renumber(entries));
    return entry.position;
  }

  /// The waiting queue, ordered by position (1 = next in line).
  /// Promoted/expired entries are NOT included.
  Future<List<WaitlistEntry>> getWaitlist(String tournamentId) async {
    final entries = await _loadAll(tournamentId);
    final waiting = entries
        .where((e) => e.status == WaitlistStatus.waiting)
        .toList()
      ..sort((a, b) => a.position.compareTo(b.position));
    return waiting;
  }

  /// All entries (waiting + promoted + expired), for admin history.
  Future<List<WaitlistEntry>> getAllEntries(String tournamentId) =>
      _loadAll(tournamentId);

  /// The waiting entry for [uid], or null when not waiting.
  Future<WaitlistEntry?> getEntryFor(String tournamentId, String uid) async {
    final entries = await _loadAll(tournamentId);
    for (final e in entries) {
      if (e.uid == uid && e.status == WaitlistStatus.waiting) return e;
    }
    return null;
  }

  /// Promotes the first waiting entry (position 1) to `promoted`
  /// and re-numbers the rest. Returns the promoted entry, or null
  /// when the queue is empty.
  Future<WaitlistEntry?> promoteNext(String tournamentId) async {
    final entries = await _loadAll(tournamentId);
    final waiting = entries
        .where((e) => e.status == WaitlistStatus.waiting)
        .toList()
      ..sort((a, b) => a.position.compareTo(b.position));
    if (waiting.isEmpty) return null;
    final first = waiting.first;
    final promoted = first.copyWith(status: WaitlistStatus.promoted);
    final updated = entries
        .map((e) => e.uid == first.uid ? promoted : e)
        .toList();
    await _saveAll(tournamentId, _renumber(updated));
    return promoted;
  }

  /// Marks a waiting entry `expired` (e.g. promotion window
  /// lapsed) and re-numbers the rest. Returns false when the UID
  /// was not waiting.
  Future<bool> expireEntry(String tournamentId, String uid) async {
    final entries = await _loadAll(tournamentId);
    var found = false;
    final updated = entries.map((e) {
      if (e.uid == uid && e.status == WaitlistStatus.waiting) {
        found = true;
        return e.copyWith(status: WaitlistStatus.expired);
      }
      return e;
    }).toList();
    if (!found) return false;
    await _saveAll(tournamentId, _renumber(updated));
    return true;
  }

  /// Removes a waiting entry entirely (player leaves the queue)
  /// and re-numbers the rest. Returns false when the UID was not
  /// waiting.
  Future<bool> cancelEntry(String tournamentId, String uid) async {
    final entries = await _loadAll(tournamentId);
    final before = entries.length;
    entries.removeWhere(
        (e) => e.uid == uid && e.status == WaitlistStatus.waiting);
    if (entries.length == before) return false;
    await _saveAll(tournamentId, _renumber(entries));
    return true;
  }
}
