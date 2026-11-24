import 'dart:async';
import 'dart:convert';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:livekit_client/livekit_client.dart' as lk;

import 'mic_audio_pipeline.dart';

/// LIVEKIT SFU TEST PATH (2026-11-01, user order) — a SEPARATE
/// voice engine beside the existing WebRTC mesh (VoiceRoom in
/// voice_service.dart), which stays untouched as the fallback.
///
/// Why an SFU: in the mesh every speaker connects directly to every
/// listener, so one weak network drops the call and shows Retry.
/// LiveKit forwards each speaker's audio ONCE through a server, so
/// a weak listener no longer breaks the speakers. The room UI,
/// chat, mic-request flow and admin controls are unchanged — only
/// the media transport under the test toggle is different.
///
/// This service mirrors the mesh surface the room page already
/// understands (joined / muted / speakerOn / participants keyed by
/// Firebase UID / isSpeaking / connection state), so the room can
/// observe it the same way. Remote audio tracks are played by the
/// LiveKit SDK on subscribe; this service does not render video
/// and never records anything (voice is live-only, as before).
///
/// NO secrets here: connect() takes a server URL + a token that
/// the token Edge Function minted. Tokens are fetched by
/// fetchToken() from the token-function URL in app_settings config
/// — the API secret never enters the app.
class LiveKitParticipantInfo {
  final String identity;
  final String name;
  final bool muted;
  final bool speaking;
  const LiveKitParticipantInfo({
    required this.identity,
    required this.name,
    required this.muted,
    required this.speaking,
  });
}

class LiveKitVoiceService extends ChangeNotifier {
  final String roomId;
  final String roomLabel;
  LiveKitVoiceService({required this.roomId, required this.roomLabel});

  lk.Room? _room;
  lk.EventsListener<lk.RoomEvent>? _listener;
  final Map<String, LiveKitParticipantInfo> _participants = {};
  Map<String, LiveKitParticipantInfo> get participants => Map.unmodifiable(_participants);

  bool _disposed = false;
  // v2016 SPEAKER FIX — this line was the toggle bug: it read
  // `if (!_disposed) _notify();` (infinite self-recursion — every
  // notify threw StackOverflowError, so NO LiveKit state change
  // ever reached the UI: the speaker Switch never moved, mute /
  // connection / participant updates never rendered). The voice
  // itself worked (audio flows without notifications), which is
  // why the bug hid: the toggle LOOKED dead while the route call
  // underneath did run. Now it notifies properly.
  void _notify() { if (!_disposed) notifyListeners(); }

  bool joined = false;
  bool muted = true; // Join muted by default, same safeguard as mesh.
  // FIX 22 item 7 (2026-11-23, user order): the speaker preference
  // is PERMANENTLY ON — voice + music are ALWAYS on the
  // loudspeaker, no earpiece routing anywhere. There is no setter
  // any more (setSpeaker is deleted), so no code path can flip it
  // off. Headsets still win by default (no force flag): BT/wired
  // connected = audio there, otherwise loudspeaker.
  bool get speakerOn => true;
  // FIX 12 G6b (2026-11-23, 01:56 live issue): the room showed
  // "Connecting…" for nearly an hour after the LiveKit project
  // switch — room.connect() has NO timeout in the SDK, so a
  // stalled handshake never returned and no error was ever set.
  // [connecting] is true while a connect attempt is in flight
  // (the UI shows "Connecting…" ONLY then); [connectTimeout]
  // bounds every attempt (tests shorten it — see
  // fix12_g6_voice_room_test.dart). [roomFactory] is a test seam:
  // tests inject a fake SDK room to drive connect success /
  // failure / timeout without a server. Production never sets it.
  bool connecting = false;
  static Duration connectTimeout = const Duration(seconds: 30);
  @visibleForTesting
  lk.Room Function()? roomFactory;
  // FIX 24 — radio mixer: while the broadcast is live, mute must be
  // MIC-GAIN-ZERO, not track disable — the mixed music still has to
  // flow through the mic track (the mic track carries the mix).
  // The room sets [holdMicTrackWhileMuted] when GO LIVE registers
  // the mixer and clears it on END LIVE. [_micTrackHeld] is true
  // while a mute is holding the track live (setMuted(true) flipped
  // the muted flag but did NOT disable the track).
  bool holdMicTrackWhileMuted = false;
  bool _micTrackHeld = false;
  // FIX 24: true while a mute is holding the mic track live (the
  // track is publishing, the mixer just has mic gain 0).
  bool get micTrackHeld => _micTrackHeld;
  // v2016: generation guard for the delayed speaker re-apply in
  // _applySpeakerRoute — a newer route change cancels a pending one.
  int _speakerRouteGen = 0;
  String? error;
  lk.ConnectionState connectionState = lk.ConnectionState.disconnected;

  // GROUP 7 — AUDIO #10: mic noise-cancellation pipeline (Krisp /
  // RNNoise, Groups 1/2). The pipeline holds the active processor
  // and supplies it as AudioCaptureOptions.processor; this service
  // owns the live-track side (re-publish on toggle, fresh build
  // after mute/disconnect). Default OFF — installing a processor
  // must not change what the room hears until the user flips the
  // switch.
  final MicAudioPipeline micPipeline = MicAudioPipeline();

  /// True when a noise processor is installed and usable — the room
  /// screen shows the Noise Cancellation toggle only then.
  bool get noiseCancellationAvailable => micPipeline.hasProcessor;

  /// True when noise cancellation is switched on (flag only — the
  /// mic track picks it up at the next publish / re-publish).
  bool get noiseCancellationEnabled => micPipeline.noiseCancellationEnabled;

  // FIX 15 (v2016) — ORGANIZER MUTE (community voice): the
  // community organizer can mute/unmute any participant's mic via
  // a reliable LiveKit data packet (topic 'organizer_control').
  // This is the LiveKit-native equivalent of the room's admin_mute
  // inbox signal (room_screen _adminMute): app-side, no server API
  // call, so no backend change is needed (backend guide §9.3).
  // The packet is honored ONLY when the sender identity is the
  // room's organizer ([organizerUid]) — anyone else's packet is
  // ignored. While organizer-muted, the target cannot unmute
  // themselves (mirrors admin mute's "khud unmute nahi kar
  // sakega"); an organizer_unmute packet releases the lock.
  static const String organizerControlTopic = 'organizer_control';

  /// Firebase UID of the room's organizer (community
  /// created_by_uid). Empty = no organizer configured: mute
  /// packets are ignored (safe default — the tournament room never
  /// sets this).
  String organizerUid = '';

  /// True while an organizer mute is holding this mic off.
  bool mutedByOrganizer = false;

  /// Pure: should a control packet be honored? The topic must
  /// match, an organizer must be configured, and the sender must
  /// BE the organizer. Anything else is ignored (never trust a
  /// packet from a stranger).
  static bool shouldHonorOrganizerPacket({
    required String? senderIdentity,
    required String organizerUid,
    required String? topic,
  }) {
    if (topic != organizerControlTopic) return false;
    if (organizerUid.isEmpty) return false;
    return senderIdentity == organizerUid;
  }

  /// Pure: which organizer control kind does this packet carry?
  /// Returns 'organizer_mute' / 'organizer_unmute', or null for
  /// anything else (garbage, wrong shape, other kinds).
  static String? organizerControlKindFromData(List<int> data) {
    try {
      final decoded = jsonDecode(utf8.decode(data));
      if (decoded is! Map) return null;
      final kind = decoded['kind']?.toString();
      if (kind == 'organizer_mute' || kind == 'organizer_unmute') {
        return kind;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  String get connectionStatus {
    switch (connectionState) {
      case lk.ConnectionState.connected:
        return 'Connected';
      case lk.ConnectionState.connecting:
      case lk.ConnectionState.reconnecting:
        return 'Connecting…';
      case lk.ConnectionState.disconnected:
        return joined ? 'Failed' : 'Not connected';
    }
  }

  bool get voiceReady => connectionState == lk.ConnectionState.connected;
  bool get aloneOnVoice => joined && _participants.keys.where((u) => u != _uid).isEmpty;
  String get _uid => FirebaseAuth.instance.currentUser?.uid ?? '';

  /// Fetches a join token from the token Edge Function. The body
  /// carries only room + identity (the same trust level as the
  /// existing anon-key Supabase tables); the function itself gates
  /// publish rights via admin_config / mic grants — see
  /// supabase/functions/livekit-token/index.ts. Never fake a token:
  /// any failure here is returned as an error, never papered over.
  static Future<String> fetchToken(String tokenUrl, String room, String identity) async {
    // O-2 (2026-11-22): send the Firebase ID token as Bearer so the
    // token endpoint can tell users apart. No token (signed out) =
    // no header, same as before. Never fake a token.
    String? idToken;
    try {
      idToken = await FirebaseAuth.instance.currentUser?.getIdToken();
    } catch (_) {
      idToken = null;
    }
    final res = await http
        .post(Uri.parse(tokenUrl), headers: {'Content-Type': 'application/json', if (idToken != null) 'Authorization': 'Bearer $idToken'}, body: jsonEncode({'room': room, 'identity': identity}))
        .timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) {
      throw Exception('Token function failed (${res.statusCode}). LiveKit server/token function abhi set nahi hai ya ghalat hai.');
    }
    final body = jsonDecode(res.body);
    final token = body is Map ? (body['token']?.toString() ?? '') : '';
    if (token.isEmpty) throw Exception('Token function ne token nahi diya.');
    return token;
  }

  Future<void> connect(String url, String token) async {
    // FIX 12 G6b: a second connect while one is in flight is a
    // no-op — never stack two SDK handshakes (the old code
    // disconnected + rebuilt mid-flight, which could orphan a
    // half-connected room).
    if (connecting) return;
    connecting = true;
    connectionState = lk.ConnectionState.connecting;
    error = null;
    _notify();
    try {
      await disconnect();
      // FIX 24 — radio mixer: publish the mic at music quality
      // (96 kbps, DTX off — DTX would gate the music bed silent
      // between words). publishAudioTrack falls back to this when
      // no per-call options are given, so every mic publish in
      // this room gets it. The test seam (roomFactory) is
      // untouched — injected rooms keep their own options.
      final room = roomFactory != null
          ? roomFactory!()
          : lk.Room(
              roomOptions: const lk.RoomOptions(
                defaultAudioPublishOptions: lk.AudioPublishOptions(
                  encoding: lk.AudioEncoding.presetMusicHighQuality,
                  dtx: false,
                ),
              ),
            );
      _room = room;
      _listener = room.createListener();
      _listener!
        ..on<lk.ParticipantConnectedEvent>((_) => _sync())
        ..on<lk.ParticipantDisconnectedEvent>((_) => _sync())
        ..on<lk.ActiveSpeakersChangedEvent>((_) => _sync())
        // RJ DUCKING (any-speaker): a remote mic mute/unmute must
        // land in _participants at once, or ducking only notices
        // when that person next speaks (ActiveSpeakers) — mute is
        // a publish/unpublish in LiveKit, so listen to all four.
        ..on<lk.TrackPublishedEvent>((_) => _sync())
        ..on<lk.TrackUnpublishedEvent>((_) => _sync())
        ..on<lk.TrackMutedEvent>((_) => _sync())
        ..on<lk.TrackUnmutedEvent>((_) => _sync())
        ..on<lk.TrackSubscribedEvent>((_) {
          _sync();
          // A new remote track can reset the SDK audio output, so
          // re-apply the user's current speaker route here too.
          unawaited(_applySpeakerRoute());
        })
        ..on<lk.TrackUnsubscribedEvent>((_) => _sync())
        // FIX 15: organizer mute/unmute data packets (community
        // voice) — honored only from the room's organizer.
        ..on<lk.DataReceivedEvent>(_onDataReceived)
        ..on<lk.RoomDisconnectedEvent>((_) {
          joined = false;
          connectionState = lk.ConnectionState.disconnected;
          _participants.clear();
          // FIX 33: a server-side / network drop ends the session
          // exactly like a leave — the keep-alive has nothing left
          // to keep alive, so the ongoing notification must go
          // now, not whenever the user next leaves the room page.
          // (A later Refresh re-connects and re-starts it.)
          unawaited(_stopForegroundService());
          _notify();
        });
      try {
        await const MethodChannel('pro_tournament/voice_foreground').invokeMethod('start');
      } catch (_) {}
      // FIX 12 G6b: HARD TIMEOUT — the SDK's room.connect() never
      // times out on its own, so a stalled handshake (wrong /
      // unreachable server URL after a project switch, dead
      // network) used to hang forever with the UI stuck on
      // "Connecting…". 30 s is generous for a healthy server
      // (Haaji probed it UP at 01:56) and short enough that a
      // failure is always visible quickly.
      await room.connect(url, token).timeout(connectTimeout, onTimeout: () {
        throw TimeoutException(
            'LiveKit server se connect nahi ho saka (${connectTimeout.inSeconds}s timeout) — server URL ya network check karen, phir Retry dabayen.');
      });
      // SPEAKER FIX (2026-11-01 user repro: speaker on/off did
      // nothing): routing was applied BEFORE room.connect(), and
      // the SDK's own audio setup on connect reset the output to
      // the earpiece, so the toggle appeared dead. Apply AFTER
      // connect, when the live audio session exists. Speaker routing
      // reuses the mesh rule verbatim: headset (BT first, then
      // wired) whenever one is connected, loudspeaker only as the
      // no-headset fallback when speakerOn is true.
      await _applySpeakerRoute();
      joined = true;
      muted = true;
      await room.localParticipant?.setMicrophoneEnabled(false);
      connectionState = room.connectionState;
      error = null;
      _sync();
    } catch (e) {
      // FIX 12 G6b: on ANY failure (including the timeout above)
      // tear down the half-connected room so a zombie handshake
      // can never complete later and flip state behind the UI's
      // back — then surface the honest reason, never silence.
      try {
        await _room?.disconnect();
      } catch (_) {}
      // ORDERING FIX (item-33 regression, same as VoiceRoom.join):
      // surface the error FIRST so the banner appears promptly —
      // awaiting the stop first delayed it past the UI's settle
      // window. The stop below is STILL awaited, so the
      // notification is still cleared before connect() returns.
      error = e is TimeoutException
          ? e.message ?? 'LiveKit connect timeout ho gaya.'
          : 'LiveKit connect failed: $e';
      joined = false;
      connectionState = lk.ConnectionState.disconnected;
      _notify();
      // FIX 33: 'start' above already ran — a failed connect must
      // undo it, or the ongoing notification outlives the session
      // that never started (joined stays false, so no leave path
      // is ever offered to clear it).
      await _stopForegroundService();
    } finally {
      connecting = false;
      _notify();
    }
  }

  void _sync() {
    final room = _room;
    if (room == null) return;
    connectionState = room.connectionState;
    final next = <String, LiveKitParticipantInfo>{};
    final local = room.localParticipant;
    if (local != null) {
      next[local.identity] = LiveKitParticipantInfo(
        identity: local.identity,
        name: local.name.isNotEmpty ? local.name : local.identity,
        muted: local.isMuted,
        speaking: local.isSpeaking,
      );
    }
    for (final p in room.remoteParticipants.values) {
      next[p.identity] = LiveKitParticipantInfo(
        identity: p.identity,
        name: p.name.isNotEmpty ? p.name : p.identity,
        muted: p.isMuted,
        speaking: p.isSpeaking,
      );
    }
    _participants
      ..clear()
      ..addAll(next);
    _notify();
  }

  Future<void> _applySpeakerRoute() async {
    final gen = ++_speakerRouteGen;
    try {
      // SPEAKER BUG FIX (2026-11-01 user repro: toggle did
      // nothing, audio stayed on the earpiece): LiveKit runs its
      // OWN native audio session, so flutter_webrtc's Helper
      // channel never moved LiveKit audio at all — the old code
      // called Helper here and LiveKit silently kept its default
      // (earpiece). AudioManager is LiveKit's own route control;
      // headsets/Bluetooth still win by default (no force flag),
      // so speakerOn=true means loudspeaker unless a headset is
      // connected, exactly like the mesh prefer-Bluetooth rule.
      // v2016: this call was re-verified correct — the dead toggle
      // in v2015 was the MESH engine's (LiveKit's plugin disables
      // flutter_webrtc's native audio management at attach, so the
      // mesh Helper calls are no-ops; see voice_service.dart).
      // SPEAKER TOGGLE FIX (2026-11-22): 2 s timeout — a wedged
      // platform call must never hang this chain. FIX 22 item 7:
      // the preference is permanently ON (true) — no toggle, no
      // earpiece route anywhere.
      await lk.AudioManager.instance
          .setSpeakerOutputPreferred(true)
          .timeout(const Duration(seconds: 2));
    } catch (_) {}
    // A newer toggle already re-applied; it owns the delayed
    // re-assert below, so this stale one stops here.
    if (gen != _speakerRouteGen) return;
    // v2016 insurance for one native race: LKAudioSwitchManager's
    // start() snapshots the speaker preference BEFORE its handler
    // post runs, so a preference set between the snapshot and the
    // post would only apply on the NEXT call. Re-asserting shortly
    // after covers that window. Plain re-apply (no flip-flop): a
    // same-selection re-apply is a no-op in the native switch, so
    // this costs nothing when the first call already landed.
    unawaited(Future.delayed(const Duration(milliseconds: 700), () async {
      if (gen != _speakerRouteGen) return;
      try {
        await lk.AudioManager.instance
            .setSpeakerOutputPreferred(true)
            .timeout(const Duration(seconds: 2));
      } catch (_) {}
    }));
  }

  Future<void> setMuted(bool value) async {
    // FIX 15: an organizer-muted mic stays off until the organizer
    // releases it — self-unmute is ignored while the lock holds.
    if (!value && mutedByOrganizer) return;
    muted = value;
    try {
      if (muted) {
        if (holdMicTrackWhileMuted && _room != null) {
          // FIX 24: hold the track — mute is mic-gain-zero in the
          // mixer (the room pushes gain 0), NOT a track disable,
          // so the mixed music keeps flowing to listeners.
          _micTrackHeld = true;
        } else {
          await _room?.localParticipant?.setMicrophoneEnabled(false);
        }
      } else {
        if (_micTrackHeld) {
          // The track was never disabled — just release the hold
          // (the room pushes the mic gain back up). No re-publish,
          // no processor rebuild: the track never stopped.
          _micTrackHeld = false;
        } else {
          // GROUP 7: unmute goes through _enableMic so a switched-on
          // noise processor is actually attached — the plain
          // setMicrophoneEnabled(true) reuses the existing
          // publication, whose track was stopped at mute (the SDK
          // destroyed its processor with it) and restartTrack does
          // NOT re-attach a processor.
          await _enableMic();
        }
      }
    } catch (_) {}
    _notify();
  }

  /// FIX 24 — the local mic track's WebRTC id (for the radio
  /// mixer's native track validation). Null when no mic
  /// publication exists (not joined, or never unmuted).
  String? get localMicTrackId => _room?.localParticipant
      ?.getTrackPublicationBySource(lk.TrackSource.microphone)
      ?.track
      ?.mediaStreamTrack
      .id;

  /// FIX 24 — makes sure a mic track is PUBLISHING (frames flowing)
  /// before the radio mixer registers: a mic muted before GO LIVE
  /// has a disabled track, and a disabled track carries no frames
  /// — the mixer would mix music into nothing. GO LIVE calls this
  /// first (after turning the hold on), so the mix flows even when
  /// the host starts live muted. No-op when already publishing.
  Future<void> ensureMicTrackEnabled() async {
    final local = _room?.localParticipant;
    if (local == null) return;
    final pub =
        local.getTrackPublicationBySource(lk.TrackSource.microphone);
    if (pub?.track != null && !(pub!.muted)) return;
    try {
      await _enableMic();
    } catch (_) {}
  }

  /// GROUP 7 — enables the mic WITH the pipeline's processor when
  /// noise cancellation is on and a processor is installed. When
  /// NC is off (or nothing is installed) this is exactly the old
  /// one-liner — zero behavior change for the plain mic.
  ///
  /// Why the unpublish: when a mic publication already exists (the
  /// mute -> unmute case), setMicrophoneEnabled(true) just unmutes
  /// the existing track — the AudioCaptureOptions passed to it are
  /// IGNORED (livekit_client 2.13.2 only uses them when creating a
  /// track), and the track's processor was destroyed when the track
  /// stopped at mute. Unpublishing first forces a fresh track
  /// created WITH the processor. The room stays connected.
  Future<void> _enableMic() async {
    final local = _room?.localParticipant;
    if (local == null) return;
    final needsProcessor =
        micPipeline.noiseCancellationEnabled && micPipeline.hasProcessor;
    if (!needsProcessor) {
      try {
        await local.setMicrophoneEnabled(true);
      } catch (_) {}
      return;
    }
    await _unpublishMic();
    await _publishMicWithPipeline();
  }

  /// GROUP 7 — removes the mic publication (if any). The SDK stops
  /// the track on unpublish and destroys its attached processor, so
  /// the pipeline's built copy is dropped too — the next publish
  /// builds a fresh one from the source. No-op when no mic
  /// publication exists. The room connection is untouched.
  Future<void> _unpublishMic() async {
    final local = _room?.localParticipant;
    final pub = local?.getTrackPublicationBySource(lk.TrackSource.microphone);
    if (local == null || pub == null) return;
    try {
      await local.removePublishedTrack(pub.sid);
    } catch (_) {}
    micPipeline.markProcessorDetached();
  }

  /// GROUP 7 — publishes the mic with the pipeline's current
  /// capture options (processor attached iff NC is on). Fail-open:
  /// if the publish fails — the SDK rethrows processor setup
  /// failures from LocalAudioTrack.create — the mic is retried
  /// WITHOUT a processor, so voice keeps working and NC just stays
  /// off for this track. The built processor is dropped either way:
  /// on a processor failure the SDK already destroyed it, and on
  /// any other failure the next publish simply rebuilds it.
  Future<void> _publishMicWithPipeline() async {
    final local = _room?.localParticipant;
    if (local == null || !joined) return;
    try {
      await micPipeline.prepareForPublish();
      await local.setMicrophoneEnabled(true,
          audioCaptureOptions: micPipeline.captureOptions());
    } catch (_) {
      micPipeline.markProcessorDetached();
      try {
        await local.setMicrophoneEnabled(true);
      } catch (_) {}
    }
  }

  /// FIX 15 — organizer mutes [targetIdentity]'s mic: a reliable
  /// data packet addressed to that participant only. No-op when
  /// not joined. The target honors it only when this client IS the
  /// room's organizer (see _onDataReceived).
  Future<void> sendOrganizerMute(String targetIdentity) async {
    await _sendOrganizerControl(targetIdentity, 'organizer_mute');
  }

  /// FIX 15 — organizer releases a mute (also unmutes the target).
  Future<void> sendOrganizerUnmute(String targetIdentity) async {
    await _sendOrganizerControl(targetIdentity, 'organizer_unmute');
  }

  Future<void> _sendOrganizerControl(
      String targetIdentity, String kind) async {
    final room = _room;
    if (room == null || !joined || targetIdentity.isEmpty) return;
    try {
      await room.localParticipant?.publishData(
        utf8.encode(jsonEncode({'kind': kind})),
        reliable: true,
        destinationIdentities: [targetIdentity],
        topic: organizerControlTopic,
      );
    } catch (_) {}
  }

  void _onDataReceived(lk.DataReceivedEvent e) {
    final sender = e.participant?.identity;
    if (!shouldHonorOrganizerPacket(
        senderIdentity: sender,
        organizerUid: organizerUid,
        topic: e.topic)) {
      return;
    }
    final kind = organizerControlKindFromData(e.data);
    if (kind == 'organizer_mute') {
      mutedByOrganizer = true;
      muted = true;
      if (holdMicTrackWhileMuted && _room != null) {
        // FIX 24: same hold as self-mute — the organizer's mute
        // is gain-zero in the mixer, not a track disable, so the
        // mixed music keeps flowing.
        _micTrackHeld = true;
      } else {
        unawaited(_room?.localParticipant?.setMicrophoneEnabled(false));
      }
      _notify();
    } else if (kind == 'organizer_unmute') {
      mutedByOrganizer = false;
      muted = false;
      if (_micTrackHeld) {
        // FIX 24: the track was never disabled — release the hold
        // (the room pushes the mic gain back up). No re-publish.
        _micTrackHeld = false;
      } else {
        // GROUP 7: same _enableMic path as self-unmute, so the
        // released mic comes back WITH the noise processor when NC is
        // on (the plain call would reuse the stopped track).
        unawaited(_enableMic());
      }
      _notify();
    }
  }

  /// FIX 22 item 7 — re-asserts the loudspeaker route (the room
  /// calls this after music ends + on admin-mic release, where
  /// music audio may have masked the voice route). The speaker
  /// preference is permanently ON (see [speakerOn]) — there is
  /// no setter any more, so nothing can flip it off.
  Future<void> reapplySpeakerRoute() async {
    await _applySpeakerRoute();
  }

  /// GROUP 7 — installs [processor] as the mic noise processor (or
  /// removes it when null). MERGE NOTE: Groups 1/2 land the concrete
  /// classes (Krisp / RNNoise); the merge wires one of them here,
  /// e.g. right after the service is created in room_screen
  /// initState. Returns true when the processor is ready to use.
  ///
  /// When the mic is live WITH the old processor attached, the mic
  /// is unpublished first (the SDK destroys the attached
  /// processor), then swapped, then re-published — the room stays
  /// connected. When the mic is muted or NC is off, the swap is
  /// silent and the next unmute picks the new processor up.
  /// Fail-open: a processor that fails to initialize leaves the mic
  /// plain.
  Future<bool> setNoiseProcessor(MicNoiseProcessor? processor) async {
    final wasLive = joined && !muted;
    final hadAttached = wasLive &&
        micPipeline.noiseCancellationEnabled &&
        micPipeline.hasProcessor;
    if (hadAttached) await _unpublishMic();
    final ok = await micPipeline.setProcessor(processor);
    if (hadAttached) await _publishMicWithPipeline();
    _notify();
    return ok;
  }

  /// GROUP 7 — noise-cancellation on/off switch. Flipping the flag
  /// while muted (or not joined) costs nothing — the next unmute
  /// applies it. Flipping it on a LIVE mic re-publishes the mic
  /// track with the new options: livekit_client 2.13.2 applies a
  /// processor only at track creation, and there is no public API
  /// to attach/detach one on a published track. The ROOM stays
  /// connected — only the mic track is replaced, so remote
  /// listeners hear only a brief gap, never a dropped call.
  Future<void> setNoiseCancellationEnabled(bool value) async {
    if (micPipeline.noiseCancellationEnabled == value) return;
    micPipeline.setNoiseCancellationEnabled(value);
    if (joined && !muted && micPipeline.hasProcessor) {
      await _unpublishMic();
      await _publishMicWithPipeline();
    }
    _notify();
  }

  // FIX 33 — STICKY NOTIFICATION (2026-11-24 user report): the
  // voice foreground service's notification is setOngoing(true),
  // so ONLY this stop removes it. Every path that ends a voice
  // session — disconnect, failed connect, server-side drop,
  // dispose — calls it. The stop is UNCONDITIONAL (no "did this
  // engine start it" flag): the two engines share ONE service and
  // are mutually exclusive in the UI, so a flag could only
  // disagree with reality and re-create this bug. stopService on
  // a non-running service is a harmless no-op.
  Future<void> _stopForegroundService() async {
    try {
      await const MethodChannel('pro_tournament/voice_foreground').invokeMethod('stop');
    } catch (_) {}
  }

  @override
  void dispose() {
    _disposed = true;
    // FIX 33: dispose without disconnect must never leak the
    // ongoing notification (stop is idempotent, so a preceding
    // disconnect() makes this a no-op).
    unawaited(_stopForegroundService());
    // GROUP 7: release the noise processor's native resources.
    unawaited(micPipeline.dispose());
    super.dispose();
  }

  Future<void> disconnect() async {
    await _stopForegroundService();
    try {
      await _listener?.dispose();
    } catch (_) {}
    _listener = null;
    try {
      await _room?.disconnect();
    } catch (_) {}
    try {
      await _room?.dispose();
    } catch (_) {}
    _room = null;
    // GROUP 7: room disconnect unpublishes all tracks, and the SDK
    // destroys the attached noise processor with the mic track —
    // drop the pipeline's built copy so the next join builds a
    // fresh one instead of reusing a destroyed object. The source
    // survives, so the NC switch and toggle stay as the user left
    // them.
    micPipeline.markProcessorDetached();
    joined = false;
    muted = true;
    // FIX 24: the room is gone — no track to hold any more.
    holdMicTrackWhileMuted = false;
    _micTrackHeld = false;
    // FIX 15: leaving the room releases any organizer-mute lock —
    // a fresh join starts clean (the organizer can mute again).
    mutedByOrganizer = false;
    connectionState = lk.ConnectionState.disconnected;
    _participants.clear();
    _notify();
  }
}
