import 'package:protournament_user/platform/core/local_store.dart';

/// Room management / credential release (ChatGPT blueprint §5-4;
/// backend guide §5-4 `room_releases` table + `release_room` RPC).
///
/// INTERIM — LOCAL STORE ONLY: until the backend `room_releases`
/// table + `release_room` RPC land, credentials live in
/// [PlatformLocalStore] under area `rooms`
/// (`platform.rooms.<matchId>`), and THIS SERVICE IS THE ONLY
/// READER. No other file reads the stored credentials.
///
/// SECURITY — room credentials must NEVER be exposed in a public
/// SELECT. The backend guide specifies an RPC-gated read
/// (`release_room` / `get_room_credentials` pattern): only
/// checked-in teams, at/after `release_at`, through the RPC. When
/// the backend lands, this service's local store becomes a cache
/// behind that RPC — the release rules below (checked-in only,
/// never early) are the same rules the RPC enforces.
///
/// REALITY CHECK (guide §5-4): the actual PUBG custom room is
/// created INSIDE THE GAME by an authorized person — the app only
/// distributes the room ID and password. This code never claims
/// automatic room creation, and the UI copy says so.

/// One room release (guide §5-4 `room_releases` row). `releasedTo`
/// holds the team IDs the credentials were released to (checked-in
/// teams only); `log` is the audit trail of release actions.
class RoomRelease {
  final String matchId;
  final String roomId;
  final String roomPassword;
  final DateTime releaseAt;
  final String createdByUid;
  final List<String> releasedTo;
  final DateTime? releasedAt;
  final List<Map<String, dynamic>> log;

  const RoomRelease({
    required this.matchId,
    required this.roomId,
    required this.roomPassword,
    required this.releaseAt,
    this.createdByUid = '',
    this.releasedTo = const [],
    this.releasedAt,
    this.log = const [],
  });

  bool get isReleased => releasedAt != null && releasedTo.isNotEmpty;

  bool releasedToTeam(String teamId) => releasedTo.contains(teamId);

  factory RoomRelease.fromMap(Map<String, dynamic> map) {
    final toList = (map['released_to_team_ids'] ?? map['releasedTo'] ?? []);
    final logRaw = (map['log'] ?? []);
    return RoomRelease(
      matchId: (map['match_id'] ?? map['matchId'] ?? '').toString(),
      roomId: (map['room_id_text'] ?? map['roomId'] ?? '').toString(),
      roomPassword:
          (map['room_password'] ?? map['roomPassword'] ?? '').toString(),
      releaseAt: map['release_at'] == null
          ? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true)
          : DateTime.tryParse(map['release_at'].toString()) ??
              DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      createdByUid:
          (map['created_by'] ?? map['createdByUid'] ?? '').toString(),
      releasedTo: toList is List
          ? toList.map((e) => e.toString()).toList()
          : const [],
      releasedAt: map['released_at'] == null
          ? null
          : DateTime.tryParse(map['released_at'].toString()),
      log: logRaw is List
          ? logRaw
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList()
          : const [],
    );
  }

  Map<String, dynamic> toMap() => {
        'match_id': matchId,
        'room_id_text': roomId,
        'room_password': roomPassword,
        'release_at': releaseAt.toUtc().toIso8601String(),
        'created_by': createdByUid,
        'released_to_team_ids': releasedTo,
        'released_at': releasedAt?.toUtc().toIso8601String(),
        'log': log,
      };
}

class RoomReleaseService {
  static const String _area = 'rooms';

  const RoomReleaseService();

  /// Stores the room credentials + release time for a match
  /// (admin-entered; the room itself is created in-game by an
  /// authorized person). Re-setting credentials keeps the audit
  /// log but resets any previous release — the new credentials
  /// must be released again.
  Future<bool> setCredentials(
    String matchId,
    String roomId,
    String roomPassword,
    DateTime releaseAt,
    String createdByUid,
  ) async {
    final previous = await getRelease(matchId);
    final log = [...?previous?.log];
    log.add({
      'action': 'credentials_set',
      'at': DateTime.now().toUtc().toIso8601String(),
      'by': createdByUid,
    });
    final release = RoomRelease(
      matchId: matchId,
      roomId: roomId,
      roomPassword: roomPassword,
      releaseAt: releaseAt.toUtc(),
      createdByUid: createdByUid,
      log: log,
    );
    return PlatformLocalStore.saveDraft(_area, matchId, release.toMap());
  }

  /// The stored release for a match, or null when none was set.
  /// THIS IS THE ONLY READER of stored room credentials.
  Future<RoomRelease?> getRelease(String matchId) async {
    final data = await PlatformLocalStore.loadDraft(_area, matchId);
    if (data == null) return null;
    return RoomRelease.fromMap(data);
  }

  /// Releases the room credentials — ONLY to the checked-in teams
  /// in [checkedInTeamIds], and ONLY at/after `releaseAt`. Returns
  /// the team IDs it released to, or an empty list when it is too
  /// early (never release early) or no credentials were set.
  /// Records `releasedTo` + `releasedAt` and appends a log row.
  Future<List<String>> releaseRoom(
    String matchId,
    List<String> checkedInTeamIds,
    DateTime now,
  ) async {
    final release = await getRelease(matchId);
    if (release == null) return [];
    if (now.isBefore(release.releaseAt)) return [];
    final teams = <String>[];
    for (final id in checkedInTeamIds) {
      if (!teams.contains(id)) teams.add(id);
    }
    final log = [...release.log];
    log.add({
      'action': 'released',
      'at': now.toUtc().toIso8601String(),
      'team_ids': teams,
    });
    final updated = RoomRelease(
      matchId: release.matchId,
      roomId: release.roomId,
      roomPassword: release.roomPassword,
      releaseAt: release.releaseAt,
      createdByUid: release.createdByUid,
      releasedTo: teams,
      releasedAt: now.toUtc(),
      log: log,
    );
    await PlatformLocalStore.saveDraft(_area, matchId, updated.toMap());
    return teams;
  }

  /// The audit log for a match's room release (credentials-set and
  /// release actions, with timestamps).
  Future<List<Map<String, dynamic>>> getReleaseLog(String matchId) async {
    final release = await getRelease(matchId);
    return release?.log ?? [];
  }

  /// True when [teamId] is among the teams the room was released to.
  Future<bool> isReleasedTo(String matchId, String teamId) async {
    final release = await getRelease(matchId);
    return release?.releasedToTeam(teamId) ?? false;
  }
}
