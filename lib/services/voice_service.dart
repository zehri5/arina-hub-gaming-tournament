import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'supabase_db.dart';

/// FREE voice chat: flutter_webrtc peer-to-peer mesh with Supabase
/// signaling. No paid service, no billing, nothing recorded or stored.
///
/// Signaling data model (Supabase tables, ephemeral):
///   voice_signaling_peers {room_id, firebase_uid, display_name, muted, joined_at}
///   voice_signaling_inbox {room_id, to_firebase_uid, from_firebase_uid, kind, sdp,
///     sdp_type, candidate, sdp_mid, sdp_mline_index, created_at}
/// Inbox rows are deleted after handling. Peer + inbox rows are removed
/// on leave. Voice media itself is live-only WebRTC audio.
///
/// ROUND 10 stale-peer fix (user bug report 07:46 PKT: members who
/// had left still showed on the mic): joined_at is now a HEARTBEAT,
/// not a one-time join stamp. While joined, the client re-upserts its
/// own row every 30 s (same name, current mute state), so joined_at
/// stays fresh. Readers DROP any peer row whose joined_at is older
/// than 2 minutes (the same freshness rule as presenceIsOnline) and
/// best-effort DELETE such stale rows (throttled, max once per 30 s),
/// so a force-killed app, a crashed app, or a leave whose delete
/// failed can ghost the mic for at most ~2 minutes, never forever.
/// No migration: the table already has joined_at, and the existing
/// anon_all policy permits delete. Caveat: a peer on an OLD build
/// (no heartbeat) will also be pruned after 2 minutes even if still
/// connected — that build must be updated to stay visible.
///
/// Mesh scaling (honest limit, also shown in-app): every peer connects
/// to every other peer. Large tournament rooms will degrade on a free
/// mesh — rooms join MUTED by default, offer push-to-talk, and show the
/// unmuted member list instead of promising unlimited speakers.
/// STUN: stun:stun.l.google.com:19302 (free, no account).
class VoiceRoom extends ChangeNotifier {
  final String roomId;
  final String roomLabel;
  VoiceRoom({required this.roomId, required this.roomLabel});

  final String _uid = FirebaseAuth.instance.currentUser!.uid;
  String get uid => _uid;

  MediaStream? _localStream;
  final Map<String, RTCPeerConnection> _pcs = {};
  final Map<String, RTCVideoRenderer> _renderers = {};
  final Map<String, Map<String, dynamic>> _peers = {};
  Map<String, Map<String, dynamic>> get peers => Map.unmodifiable(_peers);

  /// ADMIN CONTROLS (2026-10-30): the room page sets this to receive
  /// inbox rows whose kind starts with 'admin_' (admin_mute,
  /// admin_mic_off, admin_reject, admin_kick, ...). Returns true when
  /// the control was accepted (row is then deleted); false leaves
  /// the row for a later poll (e.g. admin identity not loaded yet).
  Future<bool> Function(String kind, String fromUid)? onAdminControl;

  /// MIC REQUEST SIGNALS (2026-10-30): inbox kinds starting with
  /// 'mic_' (mic_request, mic_approved, mic_rejected,
  /// mic_request_cancel) are room-level signals, not WebRTC. Same
  /// delivery contract as onAdminControl: true deletes the row.
  /// The sdp payload carries the admin-chosen slot for mic_approved
  /// ('mic_slot:N'), empty for the other kinds.
  Future<bool> Function(String kind, String fromUid, String sdp)? onMicSignal;

  /// MUSIC REQUEST SIGNALS (2026-10-30): inbox kinds starting with
  /// 'music_' (music_request, music_approved, music_rejected,
  /// music_revoked, music_request_cancel) ride the same inbox path
  /// as mic signals. Same delivery contract: true deletes the row.
  Future<bool> Function(String kind, String fromUid, String sdp)? onMusicSignal;

  /// ADMIN-ASSIGNED MIC SLOT (migration 013): when the room page
  /// joins with an admin-chosen slot, the peer row carries seat_no
  /// so EVERY phone renders this user in exactly that cell. Null =
  /// historic join-order placement.
  int? assignedSeat;

  bool joined = false;
  bool muted = true; // Join muted by default (mesh safeguard).
  // FIX 24 — radio mixer: while the broadcast is live, mute must be
  // MIC-GAIN-ZERO, not track disable — the mixed music still has to
  // flow through the mic track (the mic track carries the mix).
  // The room sets [holdMicTrackWhileMuted] when GO LIVE registers
  // the mixer and clears it on END LIVE. [_micTrackHeld] is true
  // while a mute is holding the track enabled (setMuted(true)
  // flipped the muted flag but did NOT disable the track).
  bool holdMicTrackWhileMuted = false;
  bool _micTrackHeld = false;
  // FIX 24: true while a mute is holding the mic track enabled
  // (the track is live, the mixer just has mic gain 0).
  bool get micTrackHeld => _micTrackHeld;
  // FIX 24 — the local mic track's WebRTC id (for the radio
  // mixer's native track validation). Null when no local audio
  // track exists yet.
  String? get localMicTrackId {
    final tracks = _localStream?.getAudioTracks();
    if (tracks == null || tracks.isEmpty) return null;
    return tracks.first.id;
  }
  // FIX 22 item 7 (2026-11-23, user order): the speaker preference
  // is PERMANENTLY ON — voice + music are ALWAYS on the
  // loudspeaker, no earpiece routing anywhere. There is no setter
  // any more (setSpeaker is deleted), so no code path can flip it
  // off. Headsets still win by default (no force flag): BT/wired
  // connected = audio there, otherwise loudspeaker.
  bool get speakerOn => true;
  // v2016 SPEAKER FIX: whether this mesh session started LiveKit's
  // native audio session (see _applySpeakerRoute). Only the mesh
  // session that started it stops it on leave.
  bool _lkSessionStartedByMesh = false;
  // SPEAKER TOGGLE FIX (2026-11-22): generation counter for
  // _applySpeakerRoute — a newer toggle cancels a pending route
  // change, so rapid taps settle on the LAST value instead of
  // letting a stale application clobber it (same pattern as
  // LiveKitVoiceService._speakerRouteGen).
  int _speakerRouteGen = 0;
  bool pushToTalk = false;
  String? error;

  // --- ROUND 7 voice diagnostics (visible in the room UI) ---
  // Round 2 fixed the code paths, but the user's phone STILL hears
  // nothing — and every failure was swallowed (empty catch blocks,
  // getList() returning [] on error), so the UI could only show a
  // green mic while the audio path was dead. These counters are the
  // honest surface: if signaling inserts fail (e.g. RLS) or ICE
  // never connects (e.g. carrier NAT blocks UDP), the room now SAYS
  // so instead of showing green silence.
  int signalSent = 0;
  int signalFailed = 0;
  String? lastSignalError;
  // SILENT ICE RECOVERY (2026-10-30 user order: no mid-session
  // reconnect error). lastSignalFailureAt marks the LATEST signal
  // failure; _iceFailedSince marks when each peer's ICE entered
  // 'failed'; recovery attempts are spaced and capped per episode.
  DateTime? lastSignalFailureAt;
  final Map<String, DateTime> _iceFailedSince = {};
  final Map<String, int> _iceRecoveryAttempts = {};
  final Map<String, DateTime> _iceRecoveryAt = {};
  static const _iceRecoveryMaxAttempts = 4;
  static const _iceRecoveryMinGap = Duration(seconds: 10);
  static const _iceGenuineFailAfter = Duration(seconds: 45);
  int get iceRecoveryAttempts => _iceRecoveryAttempts.values.fold(0, (a, b) => a + b);
  DateTime? lastSignalAt;
  DateTime? joinedAt;
  final Set<String> _audioPeers = {};
  Map<String, String> get iceStates => Map.unmodifiable(_iceStates);
  Set<String> get audioPeers => Set.unmodifiable(_audioPeers);
  bool get localMicEnabled => _localStream?.getAudioTracks().any((t) => t.enabled) ?? false;
  int get localAudioTracks => _localStream?.getAudioTracks().length ?? 0;
  bool get audioEstablished => _iceStates.values.any((s) => s.contains('connected') || s.contains('completed'));

  // --- Audio-path state (fix round 2) ---
  // ICE candidates that arrived BEFORE the remote description was set.
  // Old code called addCandidate immediately and DELETED the inbox row
  // on any failure, so those candidates were lost forever and the ICE
  // connection never completed — the exact "mic green, no sound" symptom
  // (signalling rows existed, peer roster worked, audio path never
  // formed). Candidates are now QUEUED and flushed once the remote
  // description lands, never silently dropped.
  final Map<String, List<RTCIceCandidate>> _pendingCandidates = {};
  final Set<String> _remoteDescSet = {};
  final Map<String, String> _iceStates = {};

  /// Visible connection status for the room UI (never silent again):
  /// 'Not connected' | 'Connecting…' | 'Connected' | 'Failed'.
  String get connectionStatus {
    if (_pcs.isEmpty) return 'Not connected';
    final states = _iceStates.values.toList();
    // A live audio path wins: in a mesh, one peer's transient ICE
    // failure must not report the whole room Failed (and flip the
    // Join button to "Connecting…") while audio flows to others.
    if (states.any((s) => s.contains('connected') || s.contains('completed'))) return 'Connected';
    if (states.any((s) => s.contains('failed'))) return 'Failed';
    return 'Connecting…';
  }

  /// A signal failure counts only while it is the LATEST signal
  /// outcome and younger than 30 s. The 2 s poll retries signalling
  /// continuously, so a single transient blip must never latch an
  /// error banner for the rest of the session — the old
  /// `signalFailed > 0` rule did exactly that (one failed insert,
  /// banner forever, even though voice kept working).
  bool get signalFailedRecently {
    final f = lastSignalFailureAt;
    if (f == null) return false;
    if (DateTime.now().difference(f) > const Duration(seconds: 30)) return false;
    final ok = lastSignalAt;
    return ok == null || f.isAfter(ok);
  }

  /// Genuinely dead, not a blip: joined, at least one LIVE peer row
  /// (fresh heartbeat — departed peers never count), NO live peer
  /// connected, and EVERY live peer continuously 'failed' for longer
  /// than _iceGenuineFailAfter. By then all silent recovery attempts
  /// (immediate + 10 s spaced, max 4) have already run. Being alone
  /// in the room is NOT a failure.
  bool get connectionGenuinelyFailed {
    if (!joined) return false;
    final live = _peers.keys.where((u) => u != _uid).toList();
    if (live.isEmpty) return false;
    for (final u in live) {
      final st = _iceStates[u] ?? '';
      if (st.contains('connected') || st.contains('completed')) return false;
    }
    final now = DateTime.now();
    for (final u in live) {
      final since = _iceFailedSince[u];
      if (since == null || now.difference(since) <= _iceGenuineFailAfter) return false;
    }
    return true;
  }

  bool get audioConnected => connectionStatus == 'Connected';

  /// CONNECTING-STUCK FIX (2026-10-30 user screenshots): the Join
  /// button showed "Connecting to voice…" forever in two cases:
  /// (a) ALONE in the room — no peer ever exists, so no PC ever
  /// forms and audioConnected can never become true, even though
  /// the mic is live and the peer row is published; (b) live peers
  /// exist but ICE never completes (still 'checking', never
  /// 'failed'), so the status sat on 'Connecting…' with no timeout.
  /// Alone counts as ready (live mic, nobody to connect to); with
  /// live others and no audio path 30 s after joining, the join is
  /// stalled — the UI turns that into a visible error + Retry
  /// (full teardown + rejoin) instead of an infinite spinner.
  /// Silent ICE recovery is untouched: recovery still runs first,
  /// and the stall clock only fires when nothing connected at all.
  bool get aloneOnVoice => joined && !_peers.keys.any((u) => u != _uid);
  bool get voiceReady => audioConnected || aloneOnVoice;
  bool get joinStalled {
    if (!joined || joinedAt == null || audioConnected) return false;
    if (!_peers.keys.any((u) => u != _uid)) return false;
    return DateTime.now().difference(joinedAt!) > const Duration(seconds: 30);
  }

  StreamSubscription<List<Map<String, dynamic>>>? _peersSub;
  StreamSubscription<List<Map<String, dynamic>>>? _inboxSub;
  final Set<String> _seenInbox = {};
  Timer? _pollTimer;
  // ROUND 10: peer heartbeat (re-upsert own row) + stale-row pruning.
  Timer? _heartbeatTimer;
  String _displayName = 'Player';
  DateTime? _lastPeerPrune;
  static const _peerFreshMs = 2 * 60 * 1000; // same rule as presence

  /// Upserts our own peer row, keeping the admin-assigned seat.
  /// PRE-MIGRATION FALLBACK: if seat_no does not exist yet (013 not
  /// applied), the seated upsert throws and we retry seat-less, so
  /// voice still works and placement falls back to join order.
  /// (Without the retry, the 30 s heartbeat would fail forever and
  /// the peer row would go stale and be pruned after 2 minutes.)
  Future<void> _upsertOwnPeer() async {
    try {
      await SupaDb.voicePeerUpsert(roomId, _uid, _displayName, muted, seatNo: assignedSeat);
    } catch (_) {
      await SupaDb.voicePeerUpsert(roomId, _uid, _displayName, muted);
    }
  }

  Future<void> join() async {
    try {
      _localStream = await navigator.mediaDevices.getUserMedia({'audio': true, 'video': false});
      if (_localStream!.getAudioTracks().isEmpty) {
        error = 'No microphone track found. Check mic permission and try again.';
        notifyListeners();
        return;
      }
      for (final t in _localStream!.getAudioTracks()) {
        t.enabled = !muted;
      }
      final profile = await SupaDb.getProfile(_uid);
      var name = SupaDb.strOf(profile['displayName']);
      if (name.isEmpty || name == 'User') name = FirebaseAuth.instance.currentUser!.email?.split('@').first ?? 'Player';
      _displayName = name;
      await _upsertOwnPeer();
      // HEADPHONE/BT FIX (2026-10-30 user report: no voice on
      // headphones, Bluetooth also not connecting): NEVER force the
      // loudspeaker at join. The old code called
      // Helper.setSpeakerphoneOn(true) here because speakerOn defaults
      // to true — and flutter_webrtc's Android AudioSwitch answers
      // that by EXPLICITLY selecting the Speakerphone device, which
      // steals routing away from a connected wired/Bluetooth headset.
      // Correct routing: headset (BT first, then wired) whenever one
      // is connected, loudspeaker only as the no-headset fallback.
      // setSpeakerphoneOnButPreferBluetooth() does exactly that
      // (FIX 22 item 7: the speaker is permanently ON — there is
      // no OFF/earpiece state any more).
      await _applySpeakerRoute();
      // BACKGROUND VOICE FIX: foreground service keeps this process
      // (mic + peer connections + timers) alive when the app goes
      // to background. Best-effort: a failure here must never block
      // voice itself.
      try {
        await const MethodChannel('pro_tournament/voice_foreground').invokeMethod('start');
      } catch (_) {}
      joined = true;
      joinedAt = DateTime.now();
      error = null;
      lastSignalFailureAt = null;
      _iceFailedSince.clear();
      _iceRecoveryAttempts.clear();
      _iceRecoveryAt.clear();
      notifyListeners();
      _listenPeers();
      _listenInbox();
      // ROUND 10 heartbeat: refresh joined_at every 30 s while joined
      // (upsert with the CURRENT mute state, so a heartbeat never
      // clobbers a mute/unmute). If this phone dies, the heartbeat
      // stops and every other phone prunes the row within 2 minutes.
      _heartbeatTimer?.cancel();
      _heartbeatTimer = Timer.periodic(const Duration(seconds: 30), (_) async {
        if (!joined) return;
        try {
          await _upsertOwnPeer();
        } catch (_) {}
      });
      // POLL FALLBACK (root-cause fix): Supabase Realtime postgres_changes
      // only fires for tables in the supabase_realtime publication, and
      // the 001 migration never added any table to it — so the realtime
      // listeners above silently never fire on a fresh database, and
      // offers/answers/ICE are never delivered (voice "does not work"
      // even though mic permission + peer-row writes succeed). Polling
      // every 2 s while joined guarantees signalling delivery with or
      // without the publication; 003_realtime.sql removes the need for
      // the poll once it has been run, but the poll stays as a safety
      // net. _seenInbox + _pcs guards make poll + realtime duplicates
      // harmless.
      _pollTimer?.cancel();
      _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
        if (!joined) return;
        try {
          _handlePeerRows(await SupaDb.getVoicePeers(roomId));
        } catch (_) {}
        try {
          await _handleInboxRows(await SupaDb.getVoiceInbox(roomId, _uid));
        } catch (_) {}
      });
    } catch (e) {
      // ORDERING FIX (item-33 regression): surface the error FIRST
      // so the banner appears promptly — awaiting the stop first
      // delayed it past the UI's settle window (fix12 G6
      // mesh-join-failure test). The stop below is STILL awaited,
      // so the notification is still cleared before join() returns.
      error = 'Could not start voice: $e';
      notifyListeners();
      // FIX 33: 'start' above may already have run — a failed join
      // must undo it, or the ongoing notification outlives the
      // session that never started (joined stays false, so no
      // leave path is ever offered to clear it). Harmless when the
      // service never started (stopService on a stopped service
      // is a no-op).
      await _stopForegroundService();
    }
  }

  void _handlePeerRows(List<Map<String, dynamic>> rows) {
    // ROUND 10 staleness filter: a peer row proves liveness ONLY via
    // a fresh joined_at heartbeat (see join() above). Rows older
    // than 2 minutes are ghosts — a left / killed / disconnected
    // member — and must never render as a seat, a strip member, or
    // an on-voice count. A future timestamp (peer clock ahead of
    // ours) counts as fresh, never as stale. Rows with no parseable
    // joined_at are dropped too: they cannot prove liveness.
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final next = <String, Map<String, dynamic>>{};
    final staleUids = <String>[];
    for (final r in rows) {
      final peerUid = SupaDb.strOf(r['firebase_uid']);
      if (peerUid.isEmpty) continue;
      final joinedMs = SupaDb.parseTs(r['joined_at']);
      if (joinedMs == 0 || nowMs - joinedMs > _peerFreshMs) {
        if (peerUid != _uid) staleUids.add(peerUid);
        continue;
      }
      next[peerUid] = r;
    }
    // ROUND 10 active prune (throttled): delete ghost rows so they
    // stop haunting OTHER phones too, not just this one. Best-effort
    // and fire-and-forget — a failed delete is harmless because the
    // filter above already hides the row here, and the next prune
    // pass retries. Never delete our own row: our heartbeat owns it.
    if (staleUids.isNotEmpty &&
        (_lastPeerPrune == null || DateTime.now().difference(_lastPeerPrune!).inSeconds >= 30)) {
      _lastPeerPrune = DateTime.now();
      for (final staleUid in staleUids) {
        SupaDb.voicePeerRemove(roomId, staleUid);
      }
    }
    _peers
      ..clear()
      ..addAll(next);
    // SILENT RECOVERY DRIVER: the 2 s poll re-checks failed peers
    // and retries recovery (spaced, capped) with no UI disturbance.
    for (final peerUid in next.keys) {
      if (peerUid == _uid) continue;
      if ((_iceStates[peerUid] ?? '').contains('failed')) {
        _attemptIceRecovery(peerUid);
      }
    }
    for (final entry in next.entries) {
      final peerUid = entry.key;
      if (peerUid == _uid || _pcs.containsKey(peerUid)) continue;
      // Deterministic offer tie-break by UID ONLY (not by join time):
      // the old time-based rule broke under clock skew between the
      // phone and the DB server (server now() vs phone ms), so both
      // sides could wait for the other and no offer was ever sent.
      // Exactly one side (larger UID) always offers.
      if (_uid.compareTo(peerUid) > 0) _createOffer(peerUid);
    }
    notifyListeners();
  }

  void _listenPeers() {
    _peersSub = SupaDb.streamVoicePeers(roomId).listen(_handlePeerRows);
  }

  Future<void> _flushPending(String peerUid) async {
    final pc = _pcs[peerUid];
    if (pc == null || !_remoteDescSet.contains(peerUid)) return;
    final queued = List<RTCIceCandidate>.from(_pendingCandidates[peerUid] ?? []);
    _pendingCandidates[peerUid] = [];
    for (final c in queued) {
      try {
        await pc.addCandidate(c);
      } catch (_) {
        // Keep it queued for the next flush instead of dropping it.
        _pendingCandidates[peerUid]!.add(c);
      }
    }
    notifyListeners();
  }

  Future<void> _handleInboxRows(List<Map<String, dynamic>> rows) async {
    // ORDER MATTERS: getList() has no ORDER BY, so a poll batch could
    // return ICE rows before the offer/answer they belong to. Sort by
    // created_at ascending so offer/answer are always applied first.
    final sorted = List<Map<String, dynamic>>.from(rows)
      ..sort((a, b) => SupaDb.parseTs(a['created_at']).compareTo(SupaDb.parseTs(b['created_at'])));
    for (final msg in sorted) {
      final id = SupaDb.strOf(msg['id']);
      if (id.isEmpty || _seenInbox.contains(id)) continue;
      _seenInbox.add(id);
      final from = SupaDb.strOf(msg['from_firebase_uid'], SupaDb.strOf(msg['from_uid'], SupaDb.strOf(msg['from'])));
      final kind = SupaDb.strOf(msg['kind']);
      // ADMIN CONTROLS (2026-10-30): kinds starting with 'admin_'
      // are room-admin actions, not WebRTC signals. Deliver them
      // to the room page (which owns mic state + navigation); only
      // delete the row when the page accepted it, so a control is
      // never lost while the admin identity is still loading.
      if (kind.startsWith('mic_')) {
        bool handled = false;
        try { handled = await onMicSignal?.call(kind, from, SupaDb.strOf(msg['sdp'])) ?? false; } catch (_) {}
        if (handled) await SupaDb.voiceInboxDelete(id);
        continue;
      }
      if (kind.startsWith('music_')) {
        bool handled = false;
        try { handled = await onMusicSignal?.call(kind, from, SupaDb.strOf(msg['sdp'])) ?? false; } catch (_) {}
        if (handled) await SupaDb.voiceInboxDelete(id);
        continue;
      }
      if (kind.startsWith('admin_')) {
        bool handled = false;
        try { handled = await onAdminControl?.call(kind, from) ?? false; } catch (_) {}
        if (handled) await SupaDb.voiceInboxDelete(id);
        continue;
      }
      try {
        if (kind == 'offer') {
          final pc = await _ensurePc(from);
          await pc.setRemoteDescription(RTCSessionDescription(SupaDb.strOf(msg['sdp']), SupaDb.strOf(msg['sdp_type'], 'offer')));
          _remoteDescSet.add(from);
          await _flushPending(from);
          final answer = await pc.createAnswer();
          await pc.setLocalDescription(answer);
          await _send(from, {'kind': 'answer', 'sdpType': answer.type, 'sdp': answer.sdp});
        } else if (kind == 'answer') {
          final pc = _pcs[from];
          if (pc != null) {
            await pc.setRemoteDescription(RTCSessionDescription(SupaDb.strOf(msg['sdp']), SupaDb.strOf(msg['sdp_type'], 'answer')));
            _remoteDescSet.add(from);
            await _flushPending(from);
          }
        } else if (kind == 'ice') {
          final cand = SupaDb.strOf(msg['candidate']);
          if (cand.isEmpty) continue;
          final candidate = RTCIceCandidate(cand, SupaDb.strOf(msg['sdp_mid']), SupaDb.intOf(msg['sdp_mline_index']));
          final pc = _pcs[from];
          if (pc == null || !_remoteDescSet.contains(from)) {
            // Remote description not set yet: QUEUE, do not drop.
            // Old code deleted the row here and the candidate was gone.
            (_pendingCandidates[from] ??= []).add(candidate);
          } else {
            try {
              await pc.addCandidate(candidate);
            } catch (_) {
              (_pendingCandidates[from] ??= []).add(candidate);
            }
          }
        }
      } catch (_) {
        // A single bad signal must not kill the room.
      }
      await SupaDb.voiceInboxDelete(id);
    }
  }

  void _listenInbox() {
    _inboxSub = SupaDb.streamVoiceInbox(roomId, _uid).listen((rows) async => _handleInboxRows(rows));
  }

  Future<RTCPeerConnection> _ensurePc(String peerUid) async {
    final existing = _pcs[peerUid];
    if (existing != null) return existing;
    // STUN first; OpenRelay is a PUBLIC free demo TURN (no account, no
    // card, username/credential are the published demo pair) added as a
    // FALLBACK only — mobile-carrier NATs often cannot do direct P2P,
    // and with STUN-only that meant "connected" never happened and no
    // audio flowed in either direction. If the relay is down, STUN
    // direct is still attempted; nothing here is paid or private.
    // ROUND 7 ICE: STUN x2 + UDP TURN + TURNS-over-TCP. The TCP/TLS
    // relay is the key addition for the user's symptom: on mobile
    // carrier NATs (both test phones on 4G) UDP is often blocked or
    // mangled, so STUN-only / UDP-TURN ICE simply never completes
    // while the mic still shows green. turns:443/tcp traverses those
    // networks like ordinary HTTPS traffic. Still free (public demo
    // relay, fallback only — direct STUN is always tried first).
    final pc = await createPeerConnection({
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
        {'urls': 'stun:stun1.l.google.com:19302'},
        {
          'urls': 'turn:openrelay.metered.ca:80',
          'username': 'openrelayproject',
          'credential': 'openrelayproject',
        },
        {
          'urls': 'turn:openrelay.metered.ca:443',
          'username': 'openrelayproject',
          'credential': 'openrelayproject',
        },
        {
          'urls': 'turns:openrelay.metered.ca:443?transport=tcp',
          'username': 'openrelayproject',
          'credential': 'openrelayproject',
        },
      ],
    }, {});
    if (_localStream == null) {
      try {
        _localStream = await navigator.mediaDevices.getUserMedia({'audio': true, 'video': false});
        for (final t in _localStream!.getAudioTracks()) {
          t.enabled = !muted;
        }
      } catch (_) {}
    }
    if (_localStream != null) {
      for (final track in _localStream!.getAudioTracks()) {
        await pc.addTrack(track, _localStream!);
      }
    }
    pc.onIceCandidate = (candidate) {
      if (candidate.candidate != null) {
        _send(peerUid, {
          'kind': 'ice',
          'candidate': candidate.candidate,
          'sdpMid': candidate.sdpMid,
          'sdpMLineIndex': candidate.sdpMLineIndex,
        });
      }
    };
    pc.onIceConnectionState = (state) {
      final st = state.toString().toLowerCase();
      _iceStates[peerUid] = st;
      if (st.contains('connected') || st.contains('completed')) {
        _iceFailedSince.remove(peerUid);
        _iceRecoveryAttempts.remove(peerUid);
        _iceRecoveryAt.remove(peerUid);
        // SPEAKER FIX (2026-11-01): re-apply the speaker route once
        // the audio path actually exists — a route applied before
        // ICE completes can be reset by the audio session setup.
        unawaited(_applySpeakerRoute());
      } else if (st.contains('failed')) {
        _iceFailedSince.putIfAbsent(peerUid, () => DateTime.now());
        // First silent recovery attempt immediately; further attempts
        // are driven by the 2 s poll in _handlePeerRows.
        _attemptIceRecovery(peerUid);
      }
      notifyListeners();
    };
    pc.onTrack = (event) async {
      // Remote audio: explicitly enable every remote audio track.
      // Old code only attached the stream to a renderer; a disabled or
      // unattached remote track is silent even when ICE connects.
      _audioPeers.add(peerUid);
      // Remote audio just arrived: make sure the output device
      // follows the current speaker setting, not a stale default.
      await _applySpeakerRoute();
      // SPEAKER HARDENING (2026-11-01): the native audio session
      // can still reset the route when the stream actually starts
      // playing a moment after the track arrives, so re-apply once
      // more after 1 s. Idempotent, respects speakerOn, and a
      // no-op if voice was left meanwhile (joined=false).
      Future.delayed(const Duration(seconds: 1), () {
        if (joined) unawaited(_applySpeakerRoute());
      });
      try {
        event.track.enabled = true;
      } catch (_) {}
      for (final stream in event.streams) {
        for (final t in stream.getAudioTracks()) {
          t.enabled = true;
        }
      }
      if (event.streams.isNotEmpty) {
        final renderer = RTCVideoRenderer();
        await renderer.initialize();
        renderer.srcObject = event.streams[0];
        _renderers[peerUid] = renderer;
        notifyListeners();
      }
    };
    _pcs[peerUid] = pc;
    return pc;
  }

  /// Silent ICE recovery on the SAME peer connection (no teardown,
  /// no leave/rejoin, no user-visible error): ICE restart + fresh
  /// offer, sent to the peer. Only the deterministic offerer side
  /// (larger UID) re-offers, to avoid offer glare; the other side
  /// recovers when that offer arrives (existing offer handling
  /// answers on the same PC). Max 4 attempts per failure episode,
  /// at least 10 s apart. A failed attempt stays silent too — the
  /// next poll pass retries, and only continuous failure past
  /// _iceGenuineFailAfter ever shows the banner.
  Future<void> _attemptIceRecovery(String peerUid) async {
    if (_uid.compareTo(peerUid) <= 0) return; // answerer side waits
    final attempts = _iceRecoveryAttempts[peerUid] ?? 0;
    if (attempts >= _iceRecoveryMaxAttempts) return;
    final last = _iceRecoveryAt[peerUid];
    if (last != null && DateTime.now().difference(last) < _iceRecoveryMinGap) return;
    final pc = _pcs[peerUid];
    if (pc == null) return;
    _iceRecoveryAttempts[peerUid] = attempts + 1;
    _iceRecoveryAt[peerUid] = DateTime.now();
    try {
      try { await pc.restartIce(); } catch (_) {}
      final offer = await pc.createOffer();
      await pc.setLocalDescription(offer);
      await _send(peerUid, {'kind': 'offer', 'sdpType': offer.type, 'sdp': offer.sdp});
    } catch (e) {
      // _send() already recorded its own failure above if it was the
      // failing step; record the recovery failure itself here.
      lastSignalError = 'ICE recovery to $peerUid failed: $e';
      lastSignalFailureAt = DateTime.now();
      notifyListeners();
    }
  }

  Future<void> _createOffer(String peerUid) async {
    try {
      final pc = await _ensurePc(peerUid);
      final offer = await pc.createOffer();
      await pc.setLocalDescription(offer);
      await _send(peerUid, {'kind': 'offer', 'sdpType': offer.type, 'sdp': offer.sdp});
    } catch (e) {
      // Was silently swallowed: an offer that never leaves this phone
      // looks exactly like "green mic, no audio" on the other side.
      signalFailed++;
      lastSignalError = 'Offer to $peerUid failed: $e';
      lastSignalFailureAt = DateTime.now();
      notifyListeners();
    }
  }

  Future<void> _send(String toUid, Map<String, dynamic> msg) async {
    try {
      await SupaDb.voiceInboxSend(roomId, toUid, _uid, msg);
      signalSent++;
      lastSignalAt = DateTime.now();
    } catch (e) {
      // Was silently swallowed (and onIceCandidate callers never
      // awaited _send, so the failure vanished entirely). A blocked
      // inbox insert — e.g. a Supabase policy — now surfaces in the
      // room's diagnostics instead of masquerading as dead audio.
      signalFailed++;
      lastSignalError = 'Signal to $toUid failed: $e';
      lastSignalFailureAt = DateTime.now();
      notifyListeners();
    }
  }

  /// Full voice retry: tear down every peer connection and rejoin
  /// (fresh getUserMedia + fresh offers). Mute state is preserved:
  /// leave() does not reset `muted`, and join() re-applies it to the
  /// new track and peer row — so a retry never silently unmutes.
  Future<void> retry() async {
    error = null;
    await leave();
    await join();
  }

  Future<void> setMuted(bool value) async {
    muted = value;
    if (_localStream != null) {
      if (muted && holdMicTrackWhileMuted) {
        // FIX 24: hold the track — mute is mic-gain-zero in the
        // mixer (the room pushes gain 0), NOT a track disable,
        // so the mixed music keeps flowing to listeners.
        _micTrackHeld = true;
      } else {
        if (!muted) _micTrackHeld = false;
        for (final t in _localStream!.getAudioTracks()) {
          t.enabled = !muted;
        }
      }
    }
    if (joined) await SupaDb.voicePeerUpdateMuted(roomId, _uid, muted);
    notifyListeners();
  }

  /// FIX 24 — makes sure the local mic track is ENABLED (frames
  /// flowing) before the radio mixer registers: a mic muted before
  /// GO LIVE has a disabled track, and a disabled track carries no
  /// frames — the mixer would mix music into nothing. GO LIVE calls
  /// this first (after turning the hold on), so the mix flows even
  /// when the host starts live muted. No-op when already enabled.
  void ensureMicTrackEnabled() {
    if (_localStream == null) return;
    for (final t in _localStream!.getAudioTracks()) {
      t.enabled = true;
    }
    _micTrackHeld = muted;
  }

  /// Headset-aware speaker routing. FIX 22 item 7 (2026-11-23,
  /// user order): the speaker is PERMANENTLY ON — "headset if
  /// connected, otherwise loudspeaker". There is no OFF state any
  /// more (the toggle is deleted, setSpeaker is deleted): a
  /// connected headset wins; otherwise the loudspeaker. No
  /// earpiece routing exists anywhere in the app.
  ///
  /// v2016 SPEAKER FIX (user report: the toggle did nothing, audio
  /// stayed on the earpiece): the flutter_webrtc Helper calls below
  /// are DEAD since LiveKit arrived — LiveKit's plugin disables
  /// flutter_webrtc's native audio management at attach
  /// (LiveKitPlugin.onAttachedToEngine calls
  /// AudioSwitchManager.setAudioSessionManagementEnabled(false)),
  /// so enableSpeakerphone* early-returns and nothing routes. The
  /// ONLY live routing control in the app is LiveKit's own
  /// AudioManager, so the mesh routes through it too: routing is an
  /// AudioManager-level setting, not per-engine. On a mesh visit no
  /// LiveKit room ever connects, so LiveKit's native session is
  /// never started by the SDK — the mesh starts it itself (once)
  /// through LiveKit's own MethodChannel, with an empty config map
  /// (the native defaults ARE the VoIP preset: in-communication
  /// mode, focus gain, voice-call stream). The Helper calls stay as
  /// a harmless no-op fallback.
  Future<void> _applySpeakerRoute() async {
    final gen = ++_speakerRouteGen;
    // Start LiveKit's native audio session once per mesh join, so
    // the speaker preference below lands on a live switch instead
    // of being silently dropped (native setSpeakerphoneOn returns
    // early when no session exists). Direct channel call: the Dart
    // API for this (setAudioSessionOptions) is experimental and
    // forces manual session mode; the channel method is what the
    // SDK itself invokes (configureAndroidAudioSession -> configure
    // + start). Android only; best-effort everywhere else.
    // SPEAKER TOGGLE FIX (2026-11-22): every native await below has
    // a 2 s timeout. A wedged platform call used to hang this whole
    // chain forever — and setSpeaker only notified AFTER it, so the
    // toggle looked dead and the route never applied. Timeouts keep
    // each step bounded; a timed-out session start is marked
    // attempted so later toggles never re-block on it (leave()
    // resets the flag, so the next join retries).
    if (!_lkSessionStartedByMesh && defaultTargetPlatform == TargetPlatform.android) {
      try {
        await const MethodChannel('livekit_client')
            .invokeMethod('configureAndroidAudioSession', <String, dynamic>{})
            .timeout(const Duration(seconds: 2));
        _lkSessionStartedByMesh = true;
      } on TimeoutException {
        _lkSessionStartedByMesh = true;
      } catch (_) {}
    }
    if (gen != _speakerRouteGen) return;
    // FIX 22 item 7: the speaker is permanently ON — always the
    // prefer-Bluetooth branch (headset wins when connected,
    // loudspeaker otherwise). The old OFF branch
    // (setSpeakerphoneOn(false) = earpiece) is deleted: no
    // earpiece routing anywhere.
    try {
      await Helper.setSpeakerphoneOnButPreferBluetooth()
          .timeout(const Duration(seconds: 2));
    } catch (_) {}
    if (gen != _speakerRouteGen) return;
    // THE live control (see the doc above): LiveKit owns the
    // platform audio session, so its preference is what routes —
    // on the mesh engine too. Headsets still win by default (no
    // force flag), exactly like the mesh prefer-Bluetooth rule.
    try {
      await lk.AudioManager.instance
          .setSpeakerOutputPreferred(true)
          .timeout(const Duration(seconds: 2));
    } catch (_) {}
  }

  /// FIX 22 item 7 — re-asserts the loudspeaker route (the room
  /// calls this after music ends + on admin-mic release, where
  /// music audio may have masked the voice route). The speaker
  /// preference is permanently ON (see [speakerOn]) — there is
  /// no setter any more, so nothing can flip it off.
  Future<void> reapplySpeakerRoute() async {
    await _applySpeakerRoute();
  }

  /// Push-to-talk is a MODE, mute is the single state. Turning PTT on
  /// forces muted (hold-to-talk unmutes while held); turning it off
  /// leaves the mute state untouched — the user then uses Unmute.
  /// The UI must never show green while the track is disabled: both the
  /// icon/dot and track.enabled are driven by this one `muted` field
  /// via setMuted(), and PTT hold/release call setMuted() too.
  Future<void> setPushToTalk(bool value) async {
    pushToTalk = value;
    if (value) await setMuted(true);
    notifyListeners();
  }

  // FIX 33 — STICKY NOTIFICATION (2026-11-24 user report): the
  // voice foreground service's notification is setOngoing(true),
  // so ONLY this stop removes it. Every path that ends a voice
  // session — leave, failed join, dispose — calls it. The stop is
  // UNCONDITIONAL (no "did this engine start it" flag): the two
  // engines share ONE service and are mutually exclusive in the
  // UI, so a flag could only disagree with reality and re-create
  // this bug. stopService on a non-running service is a harmless
  // no-op. (This unconditional stop is also what clears a
  // LiveKit-started notification on the Leave Room path.)
  Future<void> _stopForegroundService() async {
    try {
      await const MethodChannel('pro_tournament/voice_foreground').invokeMethod('stop');
    } catch (_) {}
  }

  Future<void> leave() async {
    // Cancel the timers FIRST, synchronously, before any await:
    // dispose() calls leave() unawaited, so anything cancelled
    // after an await can still be pending when the caller moves
    // on (a widget test's post-test invariant check fails on a
    // pending timer; a fast re-join could double-start them).
    // Stopping the poll/heartbeat the moment leaving starts is
    // correct regardless — no later step in leave() needs them.
    _pollTimer?.cancel();
    _pollTimer = null;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    // Stop the foreground service first: leaving voice ends the
    // background keep-alive (the notification must not linger).
    await _stopForegroundService();
    // v2016 SPEAKER FIX: if this mesh session started LiveKit's
    // native audio session (see _applySpeakerRoute), stop it on
    // leave so the phone does not stay in communication mode
    // holding audio focus after voice ends. Best-effort; a LiveKit
    // room connecting later re-starts it via its own policy.
    if (_lkSessionStartedByMesh) {
      _lkSessionStartedByMesh = false;
      try {
        await const MethodChannel('livekit_client').invokeMethod('stopAndroidAudioSession');
      } catch (_) {}
    }
    await _peersSub?.cancel();
    await _inboxSub?.cancel();
    try {
      await SupaDb.voicePeerRemove(roomId, _uid);
      await SupaDb.voiceInboxClearFor(roomId, _uid);
    } catch (_) {}
    for (final pc in _pcs.values) {
      try {
        await pc.close();
      } catch (_) {}
    }
    _pcs.clear();
    assignedSeat = null;
    lastSignalFailureAt = null;
    _iceFailedSince.clear();
    _iceRecoveryAttempts.clear();
    _iceRecoveryAt.clear();
    _pendingCandidates.clear();
    _remoteDescSet.clear();
    _iceStates.clear();
    _audioPeers.clear();
    // ROUND 10: clear the local roster on leave too, so a stale
    // snapshot can never keep rendering occupied seats / a strip /
    // a count on this phone after leaving voice.
    _peers.clear();
    joinedAt = null;
    for (final r in _renderers.values) {
      try {
        await r.dispose();
      } catch (_) {}
    }
    _renderers.clear();
    try {
      await _localStream?.dispose();
    } catch (_) {}
    _localStream = null;
    joined = false;
    // FIX 24: the room is gone — no track to hold any more.
    holdMicTrackWhileMuted = false;
    _micTrackHeld = false;
    notifyListeners();
  }

  @override
  void dispose() {
    // FIX 33: dispose without leave must never leak the ongoing
    // notification (stop is idempotent, so a preceding leave()
    // makes this a no-op).
    unawaited(_stopForegroundService());
    super.dispose();
  }
}

/// Admin voice gate: app_settings voice_enabled (global, default true)
/// and tournaments/{id} voice_enabled (per-tournament, default true).
/// If either is false, voice is off. Absent = enabled.
Future<bool> voiceEnabledForTournament(String tournamentId) => SupaDb.voiceEnabledForTournament(tournamentId);
