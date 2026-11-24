import 'package:flutter/foundation.dart';

import 'livekit_voice_service.dart';

/// RJ STUDIO — live listeners (shared contract, 2026-11-22).
///
/// A *listener* is a LiveKit room participant who is NOT on a mic seat
/// (the host and mic guests occupy seats; everyone else in the voice
/// room is listening). This file holds the shared [RjListener] model
/// used by both the data layer (Group 7) and the panel UI (Group 9),
/// plus the [LiveListeners] service that derives the live list from
/// the LiveKit room.
///
/// LIVE-ROOM ONLY: the count/detail come from the live LiveKit room.
/// Persistence (show history, stored peak counts) is BACKEND work
/// (live_shows + show_listeners tables — see the backend guide);
/// the app must NOT invent server tables. The session peak tracked
/// here is in-memory only until the backend lands.
///
/// DESIGN (async-safe, mount-driven):
/// - The mount calls [LiveListeners.update] whenever the LiveKit
///   participant set OR the mic-seat occupancy changes, then reads
///   [LiveListeners.listeners] / [LiveListeners.listenerCount] /
///   [LiveListeners.peakListeners]. update() is SYNCHRONOUS — it
///   never blocks on network/profile I/O.
/// - Names/avatars resolve in the BACKGROUND: the mount passes
///   optional resolver callbacks (the room's existing profile
///   lookup — see LISTENERS_INTEGRATION.md). update() renders with
///   the last resolved value (or the LiveKit name / identity
///   fallback); when a background resolution lands for a uid still
///   in the room, the list refreshes and listeners are notified.
/// - First-seen clock: a listener keeps their ORIGINAL listeningSince
///   while they stay a listener. Leaving the room OR taking a mic
///   seat drops them from the list; rejoining / leaving the seat
///   later restarts their clock from zero. This is deliberate:
///   "listening since" means "listening continuously since".
/// - [LiveListeners.peakListeners] is the SESSION peak (max live
///   count since the room joined / last reset). It is in-memory
///   only — it does NOT survive leaving the room and is NOT the
///   show's stored peak (backend work, see above).

/// One listener in the live room.
class RjListener {
  /// LiveKit participant identity (= the user's Firebase uid).
  final String uid;

  /// Resolved display name (falls back to the LiveKit name/identity
  /// when no profile name is known).
  final String displayName;

  /// When this listener first appeared in the room this session.
  /// The detail sheet renders this as "12 min" etc.
  final DateTime listeningSince;

  /// Photo URL when the profile lookup has one; null otherwise
  /// (the sheet renders an initial-circle avatar then).
  final String? avatarUrl;

  const RjListener({
    required this.uid,
    required this.displayName,
    required this.listeningSince,
    this.avatarUrl,
  });
}

/// Live listener list for the RJ Studio panel, derived from the
/// LiveKit room's live participants MINUS the mic-seat occupants.
///
/// Inputs only — this class never touches Supabase, Firebase, or
/// the room screen: the mount passes the LiveKit participant map
/// ([LiveKitVoiceService.participants]), the set of uids currently
/// on mic seats, and optional name/avatar resolvers (the room's
/// existing profile lookup). That keeps it unit-testable in
/// isolation with fake participant maps.
///
/// The mount calls [update] whenever participants or seats change
/// (see LISTENERS_INTEGRATION.md for the exact call sites), then
/// reads [listeners], [listenerCount] and [peakListeners]. This is
/// a [ChangeNotifier]: it notifies when the visible list, the
/// count, or the peak changes, and when a background name/avatar
/// resolution lands.
class LiveListeners extends ChangeNotifier {
  /// Resolves a uid to a display name. Return '' (or null-safe
  /// empty) when no profile name is known — the LiveKit
  /// participant name, then the identity, is the fallback.
  /// Optional: without it, names come straight from LiveKit.
  final Future<String> Function(String uid)? nameResolver;

  /// Resolves a uid to a photo URL. Return null when there is no
  /// photo — the panel renders an initial-circle avatar then.
  /// Optional: without it, every avatarUrl is null.
  final Future<String?> Function(String uid)? avatarResolver;

  /// Clock (injectable for tests; defaults to [DateTime.now]).
  final DateTime Function() _now;

  LiveListeners({
    this.nameResolver,
    this.avatarResolver,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// When each current listener first appeared as a listener.
  /// A uid leaves this map when they leave the room OR take a mic
  /// seat, so rejoining / leaving the seat restarts their clock.
  final Map<String, DateTime> _firstSeen = {};

  /// Last resolved display names (uid -> name, non-empty only).
  final Map<String, String> _resolvedNames = {};

  /// Last resolved avatar URLs (uid -> url; absent = no photo).
  final Map<String, String> _resolvedAvatars = {};

  /// Uids with a resolution currently in flight (one per uid).
  final Set<String> _resolving = {};

  /// Last participant snapshot, kept so a background resolution
  /// can rebuild the list with the current LiveKit fallback names.
  Map<String, LiveKitParticipantInfo> _lastParticipants = const {};

  List<RjListener> _listeners = const [];
  int _peak = 0;
  bool _disposed = false;

  /// Current listeners, LONGEST-LISTENING FIRST (earliest
  /// listeningSince first). Unmodifiable.
  List<RjListener> get listeners => List.unmodifiable(_listeners);

  /// Live listener count.
  int get listenerCount => _listeners.length;

  /// SESSION peak: the highest [listenerCount] seen since the
  /// room joined (or the last [reset]). In-memory only — it does
  /// NOT survive leaving the room and is NOT the show's stored
  /// peak (that is backend work). Survives count drops by design.
  int get peakListeners => _peak;

  /// Recomputes the listener list from the live room.
  ///
  /// [participants] is the LiveKit room map
  /// ([LiveKitVoiceService.participants], keyed by uid);
  /// [seatUids] is the set of uids currently occupying mic seats
  /// (the host is on a seat, so they are excluded automatically).
  /// Listeners = participants MINUS seat occupants.
  ///
  /// SYNCHRONOUS: renders with the last resolved names/avatars
  /// (or the LiveKit fallbacks). Newly-seen uids kick off a
  /// background resolution; when it lands, the list refreshes
  /// and listeners are notified. Never blocks on I/O.
  void update(
    Map<String, LiveKitParticipantInfo> participants,
    Set<String> seatUids,
  ) {
    if (_disposed) return;
    _lastParticipants = Map<String, LiveKitParticipantInfo>.from(participants);
    final now = _now();
    final listenerUids = <String>{
      for (final uid in participants.keys)
        if (!seatUids.contains(uid)) uid,
    };
    // Drop leavers + seat-takers (their clock restarts if they
    // come back as listeners later).
    _firstSeen.removeWhere((uid, _) => !listenerUids.contains(uid));
    _resolvedNames.removeWhere((uid, _) => !listenerUids.contains(uid));
    _resolvedAvatars.removeWhere((uid, _) => !listenerUids.contains(uid));
    // First-seen: newcomers get now; stayers keep their original.
    var added = false;
    for (final uid in listenerUids) {
      if (!_firstSeen.containsKey(uid)) {
        _firstSeen[uid] = now;
        added = true;
        _resolveInBackground(uid);
      }
    }
    final previousUids = _listeners.map((l) => l.uid).toList();
    final previousPeak = _peak;
    _rebuild();
    if (listenerCount > _peak) _peak = listenerCount;
    final uidsChanged = added ||
        previousUids.length != _listeners.length ||
        !_sameOrder(previousUids, _listeners.map((l) => l.uid).toList());
    if (uidsChanged || _peak != previousPeak) notifyListeners();
  }

  /// Clears all first-seen state, resolved names/avatars, the
  /// listener list and the session peak. Called when leaving the
  /// room. In-flight resolutions landing afterwards are ignored
  /// (their uid is no longer in [_firstSeen]).
  void reset() {
    if (_disposed) return;
    final hadState =
        _firstSeen.isNotEmpty || _listeners.isNotEmpty || _peak != 0;
    _firstSeen.clear();
    _resolvedNames.clear();
    _resolvedAvatars.clear();
    _lastParticipants = const {};
    _listeners = const [];
    _peak = 0;
    if (hadState) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _firstSeen.clear();
    _resolvedNames.clear();
    _resolvedAvatars.clear();
    _listeners = const [];
    super.dispose();
  }

  /// Rebuilds [_listeners] from [_firstSeen] + the last
  /// participant snapshot, longest-listening first. Name chain
  /// per uid: resolved profile name -> LiveKit participant name
  /// -> identity. Avatar: resolved photo URL, else null.
  void _rebuild() {
    final built = <RjListener>[];
    for (final entry in _firstSeen.entries) {
      final uid = entry.key;
      final info = _lastParticipants[uid];
      final resolved = _resolvedNames[uid];
      final liveKitName = info?.name.trim() ?? '';
      final displayName = resolved != null && resolved.isNotEmpty
          ? resolved
          : liveKitName.isNotEmpty
              ? liveKitName
              : info?.identity ?? uid;
      built.add(RjListener(
        uid: uid,
        displayName: displayName,
        listeningSince: entry.value,
        avatarUrl: _resolvedAvatars[uid],
      ));
    }
    built.sort((a, b) => a.listeningSince.compareTo(b.listeningSince));
    _listeners = built;
  }

  /// Kicks off one background resolution per uid (name and/or
  /// avatar, whichever resolvers were provided). Fire-and-forget:
  /// errors are swallowed (fallbacks stay in place) and a result
  /// for a uid no longer listening is dropped.
  void _resolveInBackground(String uid) {
    if ((nameResolver == null && avatarResolver == null) ||
        _resolving.contains(uid)) {
      return;
    }
    _resolving.add(uid);
    _resolve(uid);
  }

  Future<void> _resolve(String uid) async {
    String? name;
    String? avatar;
    try {
      final results = await Future.wait([
        if (nameResolver != null) nameResolver!(uid),
        if (avatarResolver != null) avatarResolver!(uid),
      ]);
      var i = 0;
      if (nameResolver != null) name = results[i++];
      if (avatarResolver != null) avatar = results[i];
    } catch (_) {
      // Resolution failure is not fatal: fallbacks stay.
    }
    _resolving.remove(uid);
    if (_disposed || !_firstSeen.containsKey(uid)) return;
    var changed = false;
    final trimmedName = (name ?? '').trim();
    if (trimmedName.isNotEmpty && _resolvedNames[uid] != trimmedName) {
      _resolvedNames[uid] = trimmedName;
      changed = true;
    }
    final trimmedAvatar = (avatar ?? '').trim();
    if (trimmedAvatar.isNotEmpty && _resolvedAvatars[uid] != trimmedAvatar) {
      _resolvedAvatars[uid] = trimmedAvatar;
      changed = true;
    }
    if (changed) {
      _rebuild();
      notifyListeners();
    }
  }

  static bool _sameOrder(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
