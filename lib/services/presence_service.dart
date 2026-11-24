import 'package:flutter/material.dart';
import 'supabase_db.dart';
import '../utils.dart';

/// Online presence on Supabase `presence` (NO onDisconnect exists in
/// Supabase). Heartbeat writes online + last_seen on foreground/resume;
/// offline = staleness (last_seen older than 2 minutes, see
/// SupaDb.presenceIsOnline — the single freshness rule). Privacy unchanged: presence is only
/// rendered in same-tournament / same-squad contexts and on the
/// leaderboard only when the viewer shares a tournament.
class PresenceService {
  static Future<void> goOnline({String? currentTournamentId, String? squadId}) async {
    await SupaDb.presenceHeartbeat(currentTournamentId: currentTournamentId, squadId: squadId);
  }

  static Future<void> updateContext({String? currentTournamentId, String? squadId}) async {
    await SupaDb.presenceHeartbeat(currentTournamentId: currentTournamentId, squadId: squadId);
  }

  static Future<void> goOffline() async {
    await SupaDb.presenceOffline();
  }

  /// v2016 FIX 8 — ONE count rule for the Room "Online" count.
  /// Union of (a) presence rows that are IN THIS ROOM and online
  /// (fresh last_seen, the single freshness rule) and (b) live
  /// voice-peer uids from BOTH engines (mesh + LiveKit). A uid on
  /// voice AND in presence counts ONCE. The old code was
  /// presence-OR-voice: as soon as any presence row was online,
  /// voice peers NOT in the presence map (room admin, spectators,
  /// a voice user whose presence heartbeat went stale) were
  /// invisible and the count under-read. Peer sets are room-scoped
  /// by construction (voice_signaling_peers per room_id, LiveKit
  /// participants per room), so no room check is needed for them.
  /// Pure (no Firebase/Supabase calls) so it is unit-testable.
  static int countOnlineUsers({
    required Map<String, Map<String, dynamic>> presenceMap,
    required bool Function(Map<String, dynamic> row) inRoom,
    required Iterable<String> meshPeerUids,
    required Iterable<String> liveKitUids,
  }) {
    final uids = <String>{};
    for (final e in presenceMap.entries) {
      if (e.key.isEmpty) continue;
      if (inRoom(e.value) && SupaDb.presenceIsOnline(e.value)) uids.add(e.key);
    }
    uids.addAll(meshPeerUids.where((u) => u.isNotEmpty));
    uids.addAll(liveKitUids.where((u) => u.isNotEmpty));
    return uids.length;
  }

  /// RJ DUCKING — ANY-SPEAKER rule (2026-11-22 user order: "koi bhi
  /// ek banda bolne lage to music down ho jaye", FM RJ style). True
  /// when ANY voice participant in the room is unmuted — self on
  /// either engine, any mesh peer, any LiveKit participant, or any
  /// fresh poll row. The old rule only read the music-sharing
  /// PLAYER's mic, so a muted player + a speaking seat 2–6 never
  /// ducked. Full volume returns only when ALL are muted (or
  /// nobody is on voice at all). Self is judged ONLY by the live
  /// joined/muted flags (selfUid is skipped in the peer maps, so a
  /// stale self row can never hold the duck). A peer row with no
  /// 'muted' key counts as UNMUTED (same as the old player rule:
  /// muted != true means unmuted). Pure (no Firebase/Supabase
  /// calls) so it is unit-testable.
  static bool anyMicUnmuted({
    required String selfUid,
    required bool selfMeshJoined,
    required bool selfMeshMuted,
    required bool selfLiveKitJoined,
    required bool selfLiveKitMuted,
    required Map<String, Map<String, dynamic>> meshPeers,
    required Map<String, bool> liveKitPeerMuted,
    required Map<String, bool> pollMuted,
  }) {
    if (selfMeshJoined && !selfMeshMuted) return true;
    if (selfLiveKitJoined && !selfLiveKitMuted) return true;
    for (final e in meshPeers.entries) {
      if (e.key == selfUid || e.key.isEmpty) continue;
      if (e.value['muted'] != true) return true;
    }
    for (final e in liveKitPeerMuted.entries) {
      if (e.key == selfUid || e.key.isEmpty) continue;
      if (!e.value) return true;
    }
    for (final e in pollMuted.entries) {
      if (e.key == selfUid || e.key.isEmpty) continue;
      if (!e.value) return true;
    }
    return false;
  }

  /// Freshness filter for the duck-poll rows (same 2-minute rule as
  /// the voice roster): a row joined more than 2 minutes ago — or
  /// with an unparseable joined_at — is a ghost and is dropped, so
  /// a departed speaker can never keep the music ducked. Returns
  /// uid -> muted for the fresh rows only. Pure, unit-testable.
  static Map<String, bool> freshPeerMuted(
    List<Map<String, dynamic>> rows, {
    required int nowMs,
  }) {
    final next = <String, bool>{};
    for (final r in rows) {
      final joinedMs = SupaDb.parseTs(r['joined_at']);
      if (joinedMs == 0 || nowMs - joinedMs > 2 * 60 * 1000) continue;
      final uid = SupaDb.strOf(r['firebase_uid']);
      if (uid.isEmpty) continue;
      next[uid] = r['muted'] == true;
    }
    return next;
  }
}

/// Green dot when online (fresh heartbeat), grey dot + last-seen when stale.
/// [showLastSeen] adds "last seen X" under an OFFLINE dot (never when
/// online — the dot alone says online). [showLabel] ALSO labels the
/// online state ("Online") — friends/roster rows use it so ONLINE reads
/// as a word, not just a dot. A player with NO presence row (never
/// heartbeated — last_seen 0) reads "Last seen —", never a nonsense
/// date: timeAgo(0) would render the 1970 epoch (bug fixed 2026-11-22).
class PresenceDot extends StatelessWidget {
  final String uid;
  final bool showLastSeen;
  final bool showLabel;
  const PresenceDot({super.key, required this.uid, this.showLastSeen = false, this.showLabel = false});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Map<String, dynamic>>(
      stream: SupaDb.streamPresence(uid),
      builder: (context, snap) {
        final p = snap.data ?? {};
        final online = SupaDb.presenceIsOnline(p);
        final dot = Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(shape: BoxShape.circle, color: online ? Colors.greenAccent : Colors.grey, border: Border.all(color: Colors.white, width: 1)),
        );
        final showText = showLastSeen || showLabel;
        if (!showText) return dot;
        if (online) {
          if (!showLabel) return dot;
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [dot, const SizedBox(width: 4), const Text('Online', style: TextStyle(color: Colors.greenAccent, fontSize: 11, fontWeight: FontWeight.bold))],
          );
        }
        final last = SupaDb.parseTs(p['last_seen']);
        final label = last == 0 ? 'Last seen —' : 'last seen ${timeAgo(last)}';
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [dot, const SizedBox(width: 4), Text(label, style: TextStyle(color: kMuted, fontSize: 11))],
        );
      },
    );
  }
}
