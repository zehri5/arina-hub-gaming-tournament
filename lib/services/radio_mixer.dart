// FIX 24 — RADIO MUSIC MIXER (2026-11-23, user voice-call order).
//
// Dart bridge to the native MusicMixProcessor (Kotlin), which mixes
// the host's background music DIRECTLY into the live mic stream on
// WebRTC's capturePostProcessing hook (after mic capture, before
// encoding — the same proven hook DspMicProcessor and Rnnoise use).
// Listeners hear exactly what the host hears: no upload, no wait,
// seek works live (the PCM feed seeks with the player).
//
// PURE RULES (unit-tested, no platform needed):
//  - radioMixGains: the mixer gains from the room's fader state.
//    Mic gain 0 when muted (mute = gain-zero, NOT track disable,
//    while the broadcast is live — so the music keeps flowing);
//    music gain = the MUSIC fader, ducked to the RJ bed while the
//    host mic is live (mic ON) or while a live guest speaks —
//    mic ON = music near-silent, voice loud on top (user order);
//    mic OFF = music at the manual level.
//  - faderGestureNext lives in room_screen.dart next to
//    inverseLinkNudge (the link-gated gesture rule).
//
// CHANNEL: `arena_hub_radio_mixer` — isAvailable / register /
// unregister / pushChunk / flush / setGains / framesMixed /
// bufferedMs / diagnostics. Every call is best-effort and
// fail-open: a mixer failure must never break playback or voice
// (the room falls back to the existing upload-broadcast path with
// an honest toast).

import 'dart:async';

import 'package:flutter/services.dart';

/// The mixer's gains for one moment of the show.
///
/// - `mic`: 0 when the host mic is OFF (gain-zero mute — the track
///   stays live so the music keeps flowing); the MIC fader level
///   when ON and the panel link is ON; 1.0 when ON and the link is
///   OFF (the fader is be-asar then, per the user order).
/// - `music`: the MUSIC fader level, ducked to [guestBed] while
///   the host mic is live ([micOn] — mic ON = music near-silent,
///   voice loud on top, the user order) or while a live call-in
///   guest speaks (their voice must win over the bed, same as
///   the host's voice does). Mic OFF = music at the manual level.
///
/// All inputs are clamped to 0..1; all outputs are 0..1.
({double mic, double music}) radioMixGains({
  required bool micOn,
  required double micFader,
  required double musicBase,
  required bool linkOn,
  required bool guestSpeaking,
  double guestBed = 0.05,
}) {
  final fader = micFader.clamp(0.0, 1.0);
  final base = musicBase.clamp(0.0, 1.0);
  final bed = guestBed.clamp(0.0, 1.0);
  final mic = !micOn ? 0.0 : (linkOn ? fader : 1.0);
  // FIX 24 defect 2 (checker, product decision): the host-mic-live
  // duck is a STATE rule, not a gesture — while the host mic is
  // live the mix music ducks to the bed, so no reachable state has
  // a quiet voice under loud music (music raised while mic OFF,
  // then mic ON, still ducks). Same bed as the guest duck.
  final music = (micOn || guestSpeaking) ? base * bed : base;
  return (mic: mic, music: music);
}

/// FIX 24 — one mic seat for the live call-in picker. [uid] is
/// null for an empty seat (the panel renders it dimmed, "khaali",
/// untappable). Only APPROVED seat occupants appear occupied:
/// the list is built from the same seat-grid assignment the stage
/// renders (assigned seat_no first, then join-order fill).
class RjCallInSeat {
  const RjCallInSeat({
    required this.seatNo,
    this.uid,
    this.name,
    this.muted = false,
  });

  final int seatNo;
  final String? uid;
  final String? name;
  final bool muted;

  bool get occupied => uid != null;
}

/// Dart-side handle for the native radio mixer.
///
/// One instance per room (the room owns it). The native side is a
/// process-wide singleton; register/unregister are idempotent there.
class RadioMixer {
  static const MethodChannel _channel =
      MethodChannel('arena_hub_radio_mixer');

  /// True once flutter_webrtc has built its first
  /// PeerConnectionFactory (i.e. voice has been used in this
  /// process). False before voice, or if the native plugin is
  /// missing — never throws.
  Future<bool> isAvailable() async {
    try {
      return await _channel.invokeMethod<bool>('isAvailable') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Hooks the mixer into the capture stream. [trackId] is the
  /// local mic track id (either engine); when given, the native
  /// side validates it is a live LocalAudioTrack. Returns false
  /// (never throws) when the hook cannot be attached — the caller
  /// falls back to the upload-broadcast path with an honest toast.
  Future<bool> register({String? trackId}) async {
    try {
      return await _channel.invokeMethod<bool>(
            'register',
            trackId == null ? null : {'trackId': trackId},
          ) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// Unhooks the mixer (END LIVE / room exit). Best-effort, never
  /// throws; safe to call when not registered.
  Future<void> unregister() async {
    try {
      await _channel.invokeMethod<void>('unregister');
    } catch (_) {}
  }

  /// Pushes one processed music chunk (48 kHz stereo int16 PCM,
  /// the same bytes the pump just wrote to playback) into the
  /// native ring buffer. Fire-and-forget: the pump must never wait
  /// on this, and a failed push must never break playback.
  void pushChunk(Uint8List chunk) {
    if (chunk.isEmpty) return;
    unawaited(
      _channel.invokeMethod<void>('pushChunk', chunk).then(
            (_) {},
            onError: (_) {},
          ),
    );
  }

  /// Drops all buffered music (seek / stop / new song load).
  /// Best-effort, never throws.
  Future<void> flush() async {
    try {
      await _channel.invokeMethod<void>('flush');
    } catch (_) {}
  }

  /// Pushes both mix gains in ONE channel call (fewer calls during
  /// fader drags). Best-effort, never throws. Values clamp 0..1.
  Future<void> setGains({required double music, required double mic}) async {
    try {
      await _channel.invokeMethod<void>('setGains', {
        'music': music.clamp(0.0, 1.0),
        'mic': mic.clamp(0.0, 1.0),
      });
    } catch (_) {}
  }

  /// Frames mixed since process start (native diagnostics; -1
  /// when the channel is unreachable). Proves on-device that the
  /// mixer is actually running.
  Future<int> framesMixed() async {
    try {
      return await _channel.invokeMethod<int>('framesMixed') ?? -1;
    } catch (_) {
      return -1;
    }
  }

  /// Buffered music in the native ring, in milliseconds.
  Future<int> bufferedMs() async {
    try {
      return await _channel.invokeMethod<int>('bufferedMs') ?? -1;
    } catch (_) {
      return -1;
    }
  }

  /// Full native diagnostics map (framesMixed, underrunFrames,
  /// droppedBytes, bufferedMs, lastBands, lastFrames, layout,
  /// micGain, musicGain). Empty map when unreachable.
  Future<Map<String, dynamic>> diagnostics() async {
    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>(
        'diagnostics',
      );
      return raw ?? <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }
}
