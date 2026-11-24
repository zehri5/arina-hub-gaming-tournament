import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide User;
import '../services/imgbb_service.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import '../services/squad.dart';
import '../services/presence_service.dart';
import '../services/supabase_db.dart';
import '../services/voice_service.dart';
import '../services/livekit_voice_service.dart';
import '../services/rnnoise_processor.dart';
// ARENA HUB #10 AUDIO (RJ STUDIO voice mount, 2026-11-22): the mic
// processors the RJ console's picker switches between, the pipeline
// source type the console's live setters reach through, and the DSP
// chain the voice console drives.
import '../services/composite_mic_processor.dart';
import '../services/dsp_mic_processor.dart';
import '../services/radio_mixer.dart';
import '../services/krisp_noise_filter.dart';
import '../services/live_listeners.dart';
import '../services/mic_audio_pipeline.dart';
// ARENA HUB #10 AUDIO (soundboard): the live-on-air SFX service.
import '../audio/soundboard.dart';
import '../services/livekit_config.dart';
// ARENA HUB #10 AUDIO (MUSIC DSP SWAP, 2026-11-22): music plays
// through the Group 8 DSP player (decode -> DSP -> AudioTrack) —
// NOT audioplayers. (Group 2 owns the effects re-attach: the _fx
// knobs still drive the session-0 Android effects until then.)
import '../audio/music_dsp_player.dart';
// ARENA HUB #10 AUDIO (Group 2 swap): the music sheet's effects
// drive the MusicDspPlayer's OWN AudioDsp instance through MusicFx
// — the old session-0 effect services (audio_effects_reverb /
// audio_effects_echo / audio_effects_bass / playback_effects) are
// no longer mounted here (their attach-to-player path took an
// audioplayers AudioPlayer, which the swap removed).
import '../audio/audio_dsp.dart';
import '../audio/music_fx.dart';
import '../services/sound_service.dart';
import '../services/message_sounds.dart';
import 'frames_screen.dart';
import 'frames_widgets.dart';
import 'audio_effects_panel.dart';
import 'listeners_detail_sheet.dart';
import '../widgets/rj_studio_panel.dart';
// ARENA HUB #10 AUDIO (Group 9 music library, 2026-11-22): the
// Music Library panel mounted in _showMusicPanel.
import '../widgets/music_library_panel.dart';
import '../widgets/music_player_panel.dart';
// FIX 16 (2026-11-23): the header Settings sheet's bridge — the
// embedded panel binds its Music / Settings / RJ / Close actions
// into this controller so the chat header can reach them.
import '../widgets/voice_settings_sheet.dart';
import '../widgets/arena_ui.dart';
import '../components/cached_image.dart';
import '../components/arena_chat.dart' hide ArenaChatMessage;
import 'status_sheet.dart';
import '../utils.dart';
// FIX 31: AI Studio voice-room presentation (screen + models +
// theme) + Lucide icons for the menu extras.
// FIX 31b: the AI Studio cyber-notch clippers + podium painter,
// reused by the embedded panel's re-skin below.
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../models/voice_room_models.dart';
import '../theme/arena_theme.dart';
import '../widgets/arena_custom_graphics.dart';
import 'arena_voice_room_screen.dart';

// ─── RJ STUDIO voice console — wiring helpers ───────────────────────
// ARENA HUB #10 AUDIO (RJ STUDIO voice mount, 2026-11-22). These are
// top-level (not state methods) so the wiring logic is unit-testable
// without booting the room screen (see test/rj_voice_mount_test.dart).
// The voice console itself is `_showRjVoiceConsole` on
// `_UnifiedRoomPageState` below.

/// Resolves the live DSP setter handle from the mic pipeline's
/// installed source — the handle the RJ voice console's sliders
/// drive. Returns null when the installed processor has no live DSP
/// setters (RNNoise / Krisp / Off): the console disables its effect
/// sliders then, never crashing on a bad cast.
///
/// TYPE-SWITCH BY DESIGN (not a shared interface): the two live
/// setter owners are `DspMicProcessor` and `CompositeMicProcessor`,
/// and the composite cannot declare a shared interface without an
/// edit to its own file — so the switch resolves the composite to
/// its DSP child (`source.dsp`). That is exactly equivalent to
/// calling the composite's own setters: they delegate to the same
/// DSP child over the same channel. The composite only resolves
/// when its DSP child actually initialized (`isDspUsable`) — a
/// composite running RNNoise-only (DSP native side absent) has no
/// live setters to drive.
DspMicProcessor? rjLiveDspSource(MicNoiseProcessor? source) {
  if (source is DspMicProcessor) return source;
  if (source is CompositeMicProcessor) {
    return source.isDspUsable ? source.dsp : null;
  }
  return null;
}

/// Maps the pipeline's installed source back to the picker kind —
/// the picker's displayed value is always derived from the ACTUAL
/// installed source, never from remembered picker state, so it can
/// never disagree with the mic. Null = Off (no processor installed).
MicProcessorKind? rjKindOfSource(MicNoiseProcessor? source) {
  if (source == null) return null;
  if (source is CompositeMicProcessor) return MicProcessorKind.composite;
  if (source is DspMicProcessor) return MicProcessorKind.dsp;
  if (source is RnnoiseMicProcessor) return MicProcessorKind.rnnoise;
  if (source is KrispMicProcessor) return MicProcessorKind.krisp;
  return null;
}

/// Display name for a mic processor kind — used by the switch-failure
/// toast (FIX 21 item 1) so the user knows WHICH processor failed,
/// e.g. "Krisp available nahi hai — pehle wala chal raha hai."
/// The old toast said only "Mic processor" and the user could not
/// tell which one he had pressed.
String rjProcessorDisplayName(MicProcessorKind kind) {
  switch (kind) {
    case MicProcessorKind.dsp:
      return 'DSP';
    case MicProcessorKind.krisp:
      return 'Krisp';
    case MicProcessorKind.rnnoise:
      return 'RNNoise';
    case MicProcessorKind.composite:
      return 'DSP + RNNoise';
  }
}

/// Maps the panel bass slider (dB, -12..+12) onto the mic chain's
/// EQ preset, preserving [base]'s mid/high bands.
///
/// NOTE (2026-11-22 RjStudioPanel mount): the voice console no
/// longer calls this — the panel drives `DspMicProcessor.setEq`
/// directly with its own knob values. Kept as the documented
/// dB→preset mapping, pinned by test/rj_voice_mount_test.dart
/// group (c); the mic-chain preset arg contract (group d) still
/// uses it to pin the exact channel args a preset application
/// sends.
///
/// NOTE — this is deliberately NOT the OLD music mount's (dB+12)/24
/// mapping: that mapping fed `BassEqEffect.setBass`, a 0.0-1.0
/// playback amount (the Group 2 swap removed that mount — the music
/// path now uses this same dB mapping through MusicFx). The mic
/// chain has NO
/// 0..1 bass setter — its EQ preset takes absolute dB
/// (`bassBoostDb` 0..12, `lowGainDb` -12..+12) — so applying
/// (dB+12)/24 here would make the 0 dB slider send +6 dB of bass
/// boost (and the Off preset non-flat). Instead: positive dB
/// becomes bass boost (the EQ band 0 gain, same as the preset's
/// bass dB), negative dB cuts the low band, and 0 dB stays flat.
DspMicEqPreset rjBassEqPreset(double bassDb, DspMicEqPreset base) {
  final db = bassDb.clamp(-12.0, 12.0).toDouble();
  return DspMicEqPreset(
    bassBoostDb: db > 0 ? db : 0.0,
    lowGainDb: db < 0 ? db : base.lowGainDb,
    midGainDb: base.midGainDb,
    highGainDb: base.highGainDb,
  );
}

/// Adapts the mic chain's [DspMicProcessor] to the RJ panel's
/// [RjVoiceDsp] control plane (AUDIO #10 mount, 2026-11-22).
///
/// Dart is nominally typed: `DspMicProcessor` cannot satisfy
/// `RjVoiceDsp` by matching members alone, and its setters return
/// `Future<bool>` where the interface declares `Future<void>` —
/// so the mount wraps the live DSP in this thin adapter instead of
/// editing the processor (which stays untouched beyond `setEq`).
/// The adapter holds no state — it only forwards the five setters
/// (dropping the bool result, which the panel never reads) and
/// `isInitialized`. The music path's `AudioDsp` needs no adapter:
/// it never mounts this panel (the music sheet mounts
/// `MusicPlayerPanel`, which drives the playback effects
/// directly through the mount's callbacks).
class RjDspMicAdapter implements RjVoiceDsp {
  RjDspMicAdapter(this._dsp);

  final DspMicProcessor _dsp;

  @override
  bool get isInitialized => _dsp.isInitialized;

  @override
  Future<void> setEq({
    bool enabled = true,
    double bassBoostDb = 0.0,
    double lowGainDb = 0.0,
    double midGainDb = 0.0,
    double highGainDb = 0.0,
  }) async {
    await _dsp.setEq(
      enabled: enabled,
      bassBoostDb: bassBoostDb,
      lowGainDb: lowGainDb,
      midGainDb: midGainDb,
      highGainDb: highGainDb,
    );
  }

  @override
  Future<void> setEcho({
    bool enabled = true,
    double delayMs = 250.0,
    double feedback = 0.35,
    double mix = 0.35,
  }) async {
    await _dsp.setEcho(
      enabled: enabled,
      delayMs: delayMs,
      feedback: feedback,
      mix: mix,
    );
  }

  @override
  Future<void> setReverb({
    bool enabled = true,
    double wetDryMix = 0.3,
    double roomSize = 0.5,
    double damping = 0.5,
  }) async {
    await _dsp.setReverb(
      enabled: enabled,
      wetDryMix: wetDryMix,
      roomSize: roomSize,
      damping: damping,
    );
  }

  @override
  Future<void> setNoiseGate({
    bool enabled = true,
    double thresholdDb = -40.0,
    double attackMs = 5.0,
    double releaseMs = 120.0,
  }) async {
    await _dsp.setNoiseGate(
      enabled: enabled,
      thresholdDb: thresholdDb,
      attackMs: attackMs,
      releaseMs: releaseMs,
    );
  }

  @override
  Future<void> setCompressor({
    bool enabled = true,
    double thresholdDb = -18.0,
    double ratio = 4.0,
    double attackMs = 10.0,
    double releaseMs = 100.0,
    double makeupGainDb = 0.0,
  }) async {
    await _dsp.setCompressor(
      enabled: enabled,
      thresholdDb: thresholdDb,
      ratio: ratio,
      attackMs: attackMs,
      releaseMs: releaseMs,
      makeupGainDb: makeupGainDb,
    );
  }
}

/// UNIFIED PROFESSIONAL ROOM — chat + voice in ONE screen.
/// FIX ROUND 2026-10-28: the room stage STAYS DARK BY DESIGN in both
/// app themes (the board's room is dark; Settings says so too). The
/// hardcoded dark colours in this file are therefore intentional and
/// were deliberately NOT converted to the light palette — every other
/// screen follows the theme toggle.
///
/// Replaces the old split navigation (Tournament Chat page / Squad Chat
/// page / Voice Room page, three separate screens). The user had to leave
/// chat to use voice and vice versa; here both live together.
///
/// Rooms are strictly separated:
///   - TOURNAMENT room: all joined players of the tournament.
///     Voice roomId: `tournament_` + tournamentId; chat scope 'tournament'.
///   - SQUAD / DUO room: only players of the same team in the tournament.
///     Voice roomId: `squad_` + squadId; chat
///     scope 'squad' with squad_id = squadIdFor(tournamentId, teamName).
///     Squad rows NEVER leak into the tournament room and vice versa
///     (chat scope + squad_id filters are separate queries).
///   - TEAM room (v2016 FIX 11): a persistent team's room,
///     opened from its team chat. Voice roomId: `squad_` + teamId;
///     chat scope 'team' with squad_id = 'team_<teamId>'. Mic
///     seats: 6 (teamMicCount — FIX 11: Squad removed, all teams
///     have 6). The player-facing
///     tournament/squad room entries were removed — the voice room
///     lives in the team chat now.
///   - COMMUNITY room (FIX 12 G6, 2026-11-23): the FULL voice
///     room inside a public community's detail page, moved from
///     the old clan room. Voice roomId: `community_` + id;
///     chat scope 'community' with community_id = id. Mic
///     seats: 6, same as the team room. The organizer
///     (community creator) is the host fallback; fix-14 gating
///     (voice_enabled + approval) is enforced by the detail page
///     before this room is ever mounted.
///   - Solo players have NO squad room (empty teamName -> no squadId);
///     they use the tournament room only.
/// Capacity comes from the tournament MODE, never a hardcoded number:
///   Duo room capacity = 2, Squad room capacity = 4 (teamSizeOf), and
///   the tournament room capacity = maxPlayers (or unlimited).
///
/// MIC INDICATOR (user's exact ask: "mic on ho to mic green ho jaye"):
///   a member whose mic is ON (unmuted) shows a GREEN mic icon + a GREEN
///   dot on the avatar; muted shows a grey mic_off icon. This is the
///   UNMUTED STATE, not true speaking detection — free WebRTC audio
///   tracks do not expose voice activity, so no "is speaking" claim is
///   made anywhere in this file.
///
/// Voice is live-only, never recorded or stored. Join is muted by
/// default, push-to-talk is available. If the admin turned voice off
/// (global or per-tournament), the voice strip shows that notice and
/// chat keeps working.
///
/// FIX 17 (2026-11-20): visual polish pass only — host-card hierarchy,
/// refined seat rings/glows, uniform rail buttons, polished chat +
/// composer. No handler, stream, routing or state logic changed.
/// PREMIUM REDESIGN 2026-11-21 (visuals/layout only): gold-on-black
/// stage — host panel first, Live Voice Chat + start-time strip,
/// glass 3x3 seat stage, Live Chat header, premium composer.
/// No handler, stream, routing, state or voice logic changed.
// ─── FIX 12 G8 — COMMUNITY MIC-REQUEST ROUTING (2026-11-23) ────────
// Community mic rules = the FULL 6-mic system WITH the mic-request
// flow, exactly as the old clan had it (user clarification 01:08 —
// supersedes MD §8). Users are NOT listen-only: any member can
// request a mic, the request goes to the ORGANIZER (community
// creator), and the organizer approves/rejects. The clan flow
// already keys every mic decision off _adminUid + _isRoomAdmin +
// _voiceRoomId, so the community wiring is a routing override, not
// a second flow: _loadRoomAdmin resolves _adminUid to the
// organizer in community scope, and _voiceRoomId is
// community_<id>. These helpers are top-level (not state methods)
// so the routing is unit-testable without booting the room screen
// (see test/fix12_g8_mic_request_test.dart) — the same pattern as
// the RJ helpers above.

/// Who receives mic requests in a community room: the ORGANIZER
/// (community creator) when known, else the designated app admin
/// (fail-open to the old target rather than dropping requests).
String communityRoomAdminUid({required String organizerUid, required String appAdminUid}) =>
    organizerUid.isNotEmpty ? organizerUid : appAdminUid;

/// FIX 20 (fix 11): mic-fader-linked music ducking (talkover).
/// Factor 1.0 (mic fader at 0) → 0.05 (mic fader at max), linear
/// in between. Applies only while the host's mic is ON; muted →
/// 1.0 (no fader ducking). Multiplies with the voice-activity
/// ducking factor in [_applyMusicVolume] — the same single volume
/// path, never a second one — and the MUSIC fader's set level
/// (_musicBaseVolume) is never touched: only the effective output
/// volume changes, the handle keeps the user's set level.
/// FIX 20 (fix 16): duplicate-song dedupe. The library used to
/// dedupe ONLY on the raw path string ('file:$path'), but the
/// Android picker can return different path spellings for the
/// same file — so the same song appeared twice ("All: 2"). Two
/// entries are the same song when their keys match exactly, OR
/// when their titles match (trimmed, case-insensitive) AND their
/// file sizes match (both known, > 0). Tones never match by
/// title+size (they carry no size), so built-in tones are safe.
bool libraryEntriesMatch(Map<String, dynamic> a, Map<String, dynamic> b) {
  final keyA = strVal(a['key']);
  if (keyA.isNotEmpty && keyA == strVal(b['key'])) return true;
  final titleA = strVal(a['title']).trim().toLowerCase();
  final titleB = strVal(b['title']).trim().toLowerCase();
  if (titleA.isEmpty || titleA != titleB) return false;
  final sizeA = a['size'];
  final sizeB = b['size'];
  if (sizeA is! int || sizeB is! int || sizeA <= 0 || sizeB <= 0) {
    return false;
  }
  return sizeA == sizeB;
}

/// File size in bytes, or 0 when the file is gone/unreadable.
/// Never throws (the library must survive a deleted file).
int _fileSizeOf(String path) {
  try {
    final f = File(path);
    return f.existsSync() ? f.lengthSync() : 0;
  } catch (_) {
    return 0;
  }
}

/// FIX 20 (fix 11) — the mic-fader duck factor as a pure rule
/// (unit-tested): mic ON + fader f -> 1.0 - 0.95*f (0.8 -> 0.24);
/// mic OFF -> 1.0. FIX 24: NO LONGER APPLIED anywhere in
/// production — the inverse link is the single mic/music
/// mechanism (applying both squared the response). The function
/// stays for the unit pins only; do NOT re-apply it in
/// _applyMusicVolume or the mixer path.
double micFaderDuckFactor({required double micFader, required bool micOn}) {
  if (!micOn) return 1.0;
  final f = micFader.clamp(0.0, 1.0);
  return 1.0 - 0.95 * f;
}

/// FIX 22 item 15 — compact count for the sidebar Followers icon
/// (pure, unit-tested): 1 -> '1', 999 -> '999', 1000 -> '1K',
/// 1500 -> '1.5K', 1000000 -> '1M', 1000000000 -> '1B',
/// 1000000000000 -> '1T'. Same whole-or-one-decimal style as
/// formatViewerCount, extended with B/T tiers. Negative input
/// (never a real count) clamps to 0.
String formatCompactCount(int n) {
  if (n < 0) n = 0;
  if (n < 1000) return '$n';
  const tiers = ['K', 'M', 'B', 'T'];
  var v = n / 1000.0;
  var t = 0;
  while (v >= 1000 && t < tiers.length - 1) {
    v /= 1000;
    t++;
  }
  final whole = v.truncateToDouble() == v;
  return '${whole ? v.toInt() : v.toStringAsFixed(1)}${tiers[t]}';
}

/// FIX 22 item 19 — the blue-tick rule as a pure function
/// (unit-tested): the tick shows when the host is verified —
/// an admin-granted flag on the profile/community row, OR
/// 1000+ followers (the same real count the sidebar Followers
/// icon shows). A null count (unknown) never earns the tick.
bool hostVerifiedTick({required bool flag, int? followersCount}) =>
    flag || (followersCount != null && followersCount >= 1000);

/// FIX 22 item 19 — reads the verified flag from a
/// profile/community row map. Key-presence check only — a
/// missing key is false (no verified column exists today;
/// never assume one). Accepts both `verified` and
/// `is_verified` spellings, so whichever the backend adds
/// later just works.
bool profileVerifiedFlag(Map<String, dynamic> row) =>
    row['verified'] == true || row['is_verified'] == true;

/// FIX 20 defect fix: the effective music target volume as a pure
/// rule (unit-testable — room widget tests cannot drive the music
/// player: _ensureMusicPlayer builds a real MusicDspPlayer with no
/// injection point). FIX 24: the mic-fader factor is 1.0 at the
/// only call site (the inverse link is the single mechanism) —
/// the parameter stays so the pure rule keeps its shape and the
/// fix20 pins hold. The voice-activity factor (the 5% RJ bed)
/// stays shared-only: local playback has no room ducking trigger.
double musicTargetVolume({
  required double base,
  required bool sharedSession,
  required double activityFactor,
  required double faderFactor,
}) =>
    sharedSession
        ? base * activityFactor * faderFactor
        : base * faderFactor;

/// FIX 22 item 11 — the inverse mic/music link as a pure rule
/// (unit-tested): the control the user moved takes its new value
/// ([delta] applied to it); the OTHER control moves by the SAME
/// delta in the OPPOSITE direction. Both values clamp to 0..1.
/// [musicMoved] = true when the user moved the MUSIC volume,
/// false when they moved the MIC level. One nudge per gesture —
/// the handlers (_onUserMusicVolume / _onUserMicLevel) call this
/// once and never re-trigger from the nudged value, so the link
/// cannot oscillate or run away.
({double mic, double music}) inverseLinkNudge({
  required double mic,
  required double music,
  required double delta,
  required bool musicMoved,
}) {
  if (musicMoved) {
    return (
      mic: (mic - delta).clamp(0.0, 1.0),
      music: (music + delta).clamp(0.0, 1.0),
    );
  }
  return (
    mic: (mic + delta).clamp(0.0, 1.0),
    music: (music - delta).clamp(0.0, 1.0),
  );
}

/// FIX 24 — the inverse link GATED by the panel MIC button
/// (unit-tested): link ON = the fix22 inverseLinkNudge (the moved
/// control takes its value, the other moves by the same delta in
/// the opposite direction); link OFF = MANUAL — only the moved
/// control changes, the other stays exactly where it was (the
/// user order: mic OFF → mic fader be-asar, music manual up/down).
/// The handlers (_onUserMusicVolume / _onUserMicLevel) call this
/// once per gesture with [_rjMicLinkOn].
({double mic, double music}) faderGestureNext({
  required double mic,
  required double music,
  required double delta,
  required bool musicMoved,
  required bool linkOn,
}) {
  if (!linkOn) {
    if (musicMoved) {
      return (mic: mic, music: (music + delta).clamp(0.0, 1.0));
    }
    return (mic: (mic + delta).clamp(0.0, 1.0), music: music);
  }
  return inverseLinkNudge(
    mic: mic,
    music: music,
    delta: delta,
    musicMoved: musicMoved,
  );
}

/// FIX 24 — live call-in guest pick (unit-tested): the host's
/// SELECTED guest wins when they are still seated; otherwise the
/// historic auto-pick (first non-host seat occupant). Null when
/// no guest is seated — the panel hides the guest strip then.
/// [hostUid] is the room admin/owner ([_adminUid]).
String? rjCallInGuestUid({
  String? selectedUid,
  required Iterable<String> seatUids,
  required String hostUid,
}) {
  if (selectedUid != null && seatUids.contains(selectedUid)) {
    return selectedUid;
  }
  for (final uid in seatUids) {
    if (uid != hostUid) return uid;
  }
  return null;
}

/// FIX 24 — the 6 call-in seats (unit-tested). Replicates the
/// seat grid's assignment EXACTLY (see _buildSeatGrid): peers
/// carrying seat_no render in that cell; peers without a seat
/// fill the earliest free cells in join order; leftovers past
/// [usable] are listeners and never appear. Names come from the
/// same rule as the stage (display_name ?? name ?? 'Player').
/// The grid itself is untouched — this is the console's read-only
/// copy of its assignment.
List<RjCallInSeat> callInSeatAssignments({
  required Map<String, Map<String, dynamic>> peers,
  required int usable,
}) {
  final assigned = <int, MapEntry<String, Map<String, dynamic>>>{};
  final unassigned = <MapEntry<String, Map<String, dynamic>>>[];
  for (final e in peers.entries) {
    final sn = SupaDb.intOf(e.value['seat_no']);
    if (sn >= 1 && sn <= usable && !assigned.containsKey(sn)) {
      assigned[sn] = e;
    } else {
      unassigned.add(e);
    }
  }
  final freeCells = <int>[
    for (var c = 1; c <= usable; c++)
      if (!assigned.containsKey(c)) c,
  ];
  final placed = unassigned.length < freeCells.length
      ? unassigned.length
      : freeCells.length;
  MapEntry<String, Map<String, dynamic>>? peerForCell(int cellNo) {
    if (assigned.containsKey(cellNo)) return assigned[cellNo];
    final idx = freeCells.indexOf(cellNo);
    if (idx >= 0 && idx < placed) return unassigned[idx];
    return null;
  }

  return [
    for (var c = 1; c <= usable; c++)
      () {
        final peer = peerForCell(c);
        if (peer == null) return RjCallInSeat(seatNo: c);
        final row = peer.value;
        final name = strVal(row['display_name']).isNotEmpty
            ? strVal(row['display_name'])
            : (strVal(row['name']).isNotEmpty
                ? strVal(row['name'])
                : 'Player');
        return RjCallInSeat(
          seatNo: c,
          uid: peer.key,
          name: name,
          muted: row['muted'] == true,
        );
      }(),
  ];
}

/// Approval payload: the organizer-chosen seat travels in the
/// mic_approved inbox row's sdp as 'mic_slot:N'; the requester's
/// join then carries seat_no so every phone renders them in
/// exactly that cell.
String micSlotPayload(int slot) => 'mic_slot:$slot';

/// Parses the approval payload back. Null = no slot (legacy
/// approval or malformed payload) — the join then falls back to
/// join-order placement, never a crash.
int? parseApprovedMicSlot(String sdp) {
  final m = RegExp(r'mic_slot:(\d+)').firstMatch(sdp);
  return m == null ? null : int.tryParse(m.group(1)!);
}

/// First free mic seat in 1..[usable], or null when every seat is
/// taken. Out-of-range taken values are ignored (defensive: a
/// stale seat_no above the count must not block assignment).
int? firstFreeMicSlot(Set<int> taken, int usable) {
  for (var c = 1; c <= usable; c++) {
    if (!taken.contains(c)) return c;
  }
  return null;
}

class UnifiedRoomPage extends StatefulWidget {
  final String tournamentId;
  final String tournamentName;
  final String scope; // 'tournament' | 'squad' | 'team' | 'community'
  final String squadId; // '' for tournament scope
  final String squadName; // team name, '' for tournament scope
  // v2016 FIX 11 (voice room relocation): 'team' scope — the room
  // opened from a team's chat (TeamChatPage). Room identity is the
  // TEAM id (squad_<teamId>), never a tournament id. micCount
  // is the total mic seats: 6 (FIX 11 — Squad removed).
  final String teamId; // '' unless scope == 'team'
  final String teamName; // '' unless scope == 'team'
  final String captainUid; // team captain, '' unless scope == 'team'
  // FIX 12 G6 (2026-11-23): 'community' scope — the FULL voice
  // room inside a public community (CommunityDetailPage mounts
  // this page embedded). Room identity is the COMMUNITY id
  // (community_<communityId>), never a tournament id. micCount
  // is the total mic seats: 6, same as the team room.
  final String communityId; // '' unless scope == 'community'
  final String communityName; // '' unless scope == 'community'
  final String organizerUid; // community creator, '' unless scope == 'community'
  // FIX 22 item 14 — host-card tagline + cover, passed by the
  // parent page (community detail / team chat). [hostCardDescription]
  // is the scope description (community description; teams have
  // no description field, so '' there) — the tagline's fallback
  // when the organizer has no profile bio. [hostCardCoverUrl] is
  // the scope photo (community / team photo_url) shown dimmed
  // behind the card content; '' = the code-built gradient + glow
  // background instead. Tournament scope passes neither — the
  // room reads the description + banner from the tournament row
  // itself (_tournamentFuture). Empty = omit, never fake.
  final String hostCardDescription;
  final String hostCardCoverUrl;
  final int micCount; // 0 = scope default (squad capacity / 9)
  final String mode; // Solo | Duo | Squad
  final int maxPlayers; // 0 = unlimited (tournament room only)
  // FULL COMPLETION expansion 3: spectator = view-only room entry
  // (no Take mic, no sending); shoutcaster = spectator + highlighted
  // SHOUT messages + voice listening (see _send + seat guards).
  final bool spectator;
  final bool shoutcaster;
  // v2017 INLINE VOICE (user order 2026-11-22): when true, the
  // page renders as an embeddable voice panel (host strip + mic
  // seats + controls) instead of the full room screen — no chat,
  // no composer, no side rail. TeamChatPage mounts it inline
  // above the team chat when the Voice toggle is ON; removing it
  // (toggle OFF) disposes the state, which leaves voice.
  final bool embedded;
  // v2017 INLINE VOICE: called by the panel's Close button
  // (embedded only) so the host can hide the panel. Null in
  // full-page mode (the panel only exists in embedded mode).
  final VoidCallback? onCloseVoice;
  // FIX 16 (2026-11-23): the voice settings bridge — the room
  // state binds its Music / Room Settings / RJ / Close actions
  // into this controller (TeamChatPage owns it), so the header
  // Settings sheet can reach the panel's voice functions. Null
  // in full-page mode (the rail already has Music/Settings).
  final VoicePanelController? voiceController;
  // FIX 22 item 5 + item 12 (2026-11-23): the embedded panel's
  // RIGHT SIDEBAR — FINAL five entries (user order 19:03–19:07,
  // SUPERSEDES item 5's rectangular menus + item 12e's list):
  // Followers, Music, RJ Panel, Settings, Leave Room, in this
  // order — ROUND icons only, no rectangular card views. Room
  // Home + Participants + Tournament Info are REMOVED (exit is
  // Leave Room + system back; the members button in the host
  // card, item 16, opens the FULL members list). Each entry has
  // an in-room fallback (see _buildEmbeddedSidebar), so a
  // missing callback never leaves a dead button. RJ Panel is
  // host-only (same gate as the full-page rail); Music +
  // Followers + Settings are open to everyone. The RJ 4-option
  // menu is PENDING (the options are not named yet) — until
  // they arrive, RJ Panel opens the console directly, as
  // item 12e briefed.
  final VoidCallback? onSidebarFollowers;
  // The organizer's/captain's REAL followers count, loaded by
  // the parent (CommunityService.followers length). Null =
  // unknown (still loading / failed) — the icon shows '—',
  // never 0 and never a fake number. FIX 23 item 12: this count
  // now feeds ONLY the item-19 blue-tick 1000 rule — the
  // sidebar shows the COMMUNITY count below instead.
  final int? sidebarFollowersCount;
  // FIX 23 item 12a: the COMMUNITY's real member count (fresh
  // COUNT from community_members — the same source the members
  // list uses), shown under the sidebar Followers icon. Null =
  // fall back to sidebarFollowersCount (team scope).
  final int? sidebarCommunityCount;
  // FIX 23 item 9: the Follow pill under the Followers icon.
  // null = creator (shows gold JOINED, no tap); true = member
  // (shows Following); false = not a member (shows Follow).
  // Null onSidebarFollowToggle = no pill at all (team scope).
  final bool? sidebarFollowing;
  final bool sidebarFollowBusy;
  final VoidCallback? onSidebarFollowToggle;
  final VoidCallback? onSidebarSettings;
  final VoidCallback? onSidebarLeaveRoom;
  final VoidCallback? onSidebarRjPanel;
  final VoidCallback? onSidebarMusic;
  // FIX 23 item 16a: voice LOCKED by the parent (community
  // voice_enabled == false). The host card stays pinned
  // (sticky) but the seats area shows a slim "Voice locked"
  // line instead of seats, and _joinVoiceOpen refuses to
  // join. Default false (team/tournament scopes are never
  // locked this way — their lock is _roomVoiceDisabled).
  final bool voiceLocked;
  // FIX 23 items 14+21: fired after the user picks a background in
  // the Backgrounds panel (_setBackground), so the parent (community
  // detail page) can refresh its own chat-area background to match.
  final VoidCallback? onBackgroundChanged;
  // FIX 23 item 12b: the host-card members button (FIX 22 item
  // 16) is REMOVED — the word "Members" must not appear in the
  // room. Members are reached from the sidebar Followers entry
  // (which opens the full members list) instead.
  // FIX 22 item 19: the community row's verified flag, read by
  // the parent with a key-presence check (absent = false — no
  // verified column exists today). The host PROFILE row's flag
  // is read in the room itself (_hostVerifiedFor).
  final bool hostCardVerified;
  // FIX 72 (2026-11-24): host-page sidebar reserve override —
  // the pixels the capped sidebar leaves for the host page's own
  // chrome + chat minimum (see _buildCappedSidebar). Null = the
  // scope default (team 316.0, community 236.0 — the FIX 31b
  // Defect-A values, untouched). CommunityDetailPage passes
  // 480.0: its voice-lock banner (76–154px) + host card +
  // header strip (~158px) + the chat tab's ~143px minimum do
  // not fit under the 236 default — the chat composer was cut
  // off (72px bottom overflow at 800x600, 71px at 360x800).
  final double? sidebarReserve;

  const UnifiedRoomPage({
    super.key,
    this.tournamentId = '',
    this.tournamentName = '',
    required this.scope,
    this.squadId = '',
    this.squadName = '',
    this.teamId = '',
    this.teamName = '',
    this.captainUid = '',
    this.communityId = '',
    this.communityName = '',
    this.organizerUid = '',
    this.hostCardDescription = '',
    this.hostCardCoverUrl = '',
    this.micCount = 0,
    this.mode = 'Solo',
    this.maxPlayers = 0,
    this.spectator = false,
    this.shoutcaster = false,
    this.embedded = false,
    this.onCloseVoice,
    this.voiceController,
    this.onSidebarFollowers,
    this.sidebarFollowersCount,
    this.sidebarCommunityCount,
    this.sidebarFollowing,
    this.sidebarFollowBusy = false,
    this.onSidebarFollowToggle,
    this.onSidebarSettings,
    this.onSidebarLeaveRoom,
    this.onSidebarRjPanel,
    this.onSidebarMusic,
    this.voiceLocked = false,
    this.onBackgroundChanged,
    this.hostCardVerified = false,
    this.sidebarReserve,
  });

  @override
  State<UnifiedRoomPage> createState() => _UnifiedRoomPageState();
}


/// Animated mic-wave bars shown on an UNMUTED seat. This is a MIC-ON
/// animation (bars dance while the mic is on), NOT speaking detection:
/// free WebRTC audio tracks expose no voice activity, so the bars do
/// NOT react to actual speech volume. Cheap: one short controller per
/// unmuted seat only; muted seats show flat grey bars, no animation.
class _MicWave extends StatefulWidget {
  final bool active;
  const _MicWave({required this.active});
  @override
  State<_MicWave> createState() => _MicWaveState();
}

class _MicWaveState extends State<_MicWave> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.active) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(4, (_) => Container(width: 3, height: 6, margin: const EdgeInsets.symmetric(horizontal: 1), decoration: BoxDecoration(color: kMuted, borderRadius: BorderRadius.circular(2)))),
      );
    }
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(4, (i) {
            final phase = (_ctrl.value + i * 0.25) % 1.0;
            final h = 5 + 9 * (phase < 0.5 ? phase * 2 : (1 - phase) * 2);
            return Container(width: 3, height: h, margin: const EdgeInsets.symmetric(horizontal: 1), decoration: BoxDecoration(color: Colors.greenAccent, borderRadius: BorderRadius.circular(2)));
          }),
        );
      },
    );
  }
}

/// Pulsing glow around a SPEAKING member's avatar (FIX 23 item
/// 13b: the pulse used to run the whole time a mic was unmuted,
/// so idle seats blinked forever — now it runs ONLY while the
/// seat is actually speaking. LiveKit reports speaking via
/// ActiveSpeakersChangedEvent; mesh peers carry no speaking
/// signal, so mesh seats stay static — never a faked pulse).
class _PulseGlow extends StatefulWidget {
  final Widget child;
  final bool active;
  const _PulseGlow({required this.child, required this.active});
  @override
  State<_PulseGlow> createState() => _PulseGlowState();
}

class _PulseGlowState extends State<_PulseGlow> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.active) return widget.child;
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, child) {
        return Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            boxShadow: [BoxShadow(color: _neonSeat.withValues(alpha: 0.22 + 0.22 * _ctrl.value), blurRadius: 8 + 10 * _ctrl.value, spreadRadius: 1 + 2 * _ctrl.value)],
          ),
          child: child,
        );
      },
      child: widget.child,
    );
  }
}


// NEON DESIGN SYSTEM (user master prompt + reference mockup,
// 2026-10-30): fixed neon palette for the room only — the rest of
// the app keeps its own theme. Original code-drawn art only.
// FIX 22 item 18: the room BACKGROUND went gold (painter +
// glows + sparkles all nGold now) — nPurple/nPink/nMagenta/
// nBlue survive only in the two non-background uses (chat
// organizer name, verified tick).
const Color nBg = Color(0xFF070817);
const Color nBg2 = Color(0xFF0D1028);
const Color nCard = Color(0xFF10132E);
const Color nPurple = Color(0xFF8B2CFF);
const Color nPink = Color(0xFFFF16C8);
const Color nMagenta = Color(0xFDC903F9);
const Color nBlue = Color(0xFF426BFF);
const Color nGold = Color(0xFFFDC903);
const Color nGreen = Color(0xFF00F5A0);
const Color nText2 = Color(0xFFAAB0D0);
const Color nBorder = Color(0xFF34265F);

// FIX 23 item 6 (user order 2026-11-23, neon reference
// 1000035598_33_dv28.png): the sidebar buttons + mic seats are
// COLORFUL NEON. This palette is the ONLY exception to the
// gold-only rule, for these elements only — everything else
// stays dark + #FDC903.
const Color _neonPink = Color(0xFFFF2E88);
const Color _neonCyan = Color(0xFF00E5FF);
const Color _neonPurple = Color(0xFFB537F2);
const Color _neonLime = Color(0xFF39FF88);
const Color _neonOrange = Color(0xFFFF5C39);
const Color _neonSeat = Color(0xFFC026D3);
const Color _neonSeatDeep = Color(0xFF7E22CE);

// PREMIUM REDESIGN (2026-11-21, visuals only): gold-on-black stage
// tokens. nGold is the locked #FDC903.
// FIX 31b: the _roomGlass/_roomHairline stage-panel tokens are
// GONE — their only use was the seat-grid card shell, which is
// the AI Studio podium card now (ArenaColors.cardBg + purple
// border). Removing them keeps analyze warning-free.

/// v2016 FIX 6 (user order 2026-11-22, "numbers purane lagte
/// hain"): modern seat-number badge, shared by the occupied and
/// locked mic cells so every seat 1-9 shows its number in the same
/// gold/black style as the redesigned free-seat disc — a bright
/// gold gradient ring around a deep gold-brown-to-black gradient
/// disc, soft gold glow, number in heavy gold. The free-seat disc
/// (52px, mic glyph + number) is the large form; this is the small
/// (18px) corner form for cells whose centre is an avatar or a
/// lock. `dimmed` is the locked-seat form: muted gold, no glow.
/// Public (not _private) so a widget test can pump it directly —
/// the full Room screen is untestable (Firebase + Supabase +
/// LiveKit), but this badge has no such dependency.
class MicSeatNumberBadge extends StatelessWidget {
  const MicSeatNumberBadge({super.key, required this.seatNo, this.dimmed = false});
  final int seatNo;
  final bool dimmed;
  @override
  Widget build(BuildContext context) {
    // FIX 23 item 6 (user order 2026-11-23, neon reference):
    // the seat-number badge is NEON now — a bright magenta
    // gradient ring around a deep purple-black disc, soft neon
    // glow, white number. Same 18px size, same positions.
    final neon = dimmed ? _neonSeat.withValues(alpha: 0.55) : _neonSeat;
    return Container(
      width: 18,
      height: 18,
      padding: const EdgeInsets.all(1.5),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(colors: [neon, _neonSeatDeep], begin: Alignment.topLeft, end: Alignment.bottomRight),
        boxShadow: dimmed ? null : [BoxShadow(color: _neonSeat.withValues(alpha: 0.4), blurRadius: 6, spreadRadius: 0)],
      ),
      child: Container(
        alignment: Alignment.center,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(colors: [Color(0xFF241031), Color(0xFF120A1E)], begin: Alignment.topCenter, end: Alignment.bottomCenter),
        ),
        child: Text('$seatNo', style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w900, height: 1.0)),
      ),
    );
  }
}

class _OrnateRoomPainter extends CustomPainter {
  // ROUND 16: original ornamental pattern only — diamond lattice,
  // arch arcs and sparkle dots painted in code. No copied artwork,
  // photos, dome/mosque art or branding. FIX 22 item 18: all
  // gold now (was purple/pink) to match the black+gold theme.
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = nGold.withValues(alpha: 0.05)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (double y = -40; y < size.height + 40; y += 56) {
      canvas.drawLine(Offset(-20, y), Offset(size.width + 20, y + 56), paint);
      canvas.drawLine(Offset(-20, y + 56), Offset(size.width + 20, y), paint);
    }
    final arcPaint = Paint()
      ..color = nGold.withValues(alpha: 0.09)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawArc(Rect.fromCircle(center: Offset(size.width / 2, 40), radius: 170), 0, 3.14159, false, arcPaint);
    canvas.drawArc(Rect.fromCircle(center: Offset(size.width / 2, 40), radius: 210), 0, 3.14159, false, arcPaint);
    final dot = Paint()..color = nGold.withValues(alpha: 0.18);
    for (final o in [Offset(size.width * 0.18, 420), Offset(size.width * 0.82, 520), Offset(size.width * 0.5, 640), Offset(size.width * 0.3, 760), Offset(size.width * 0.75, 880)]) {
      canvas.drawCircle(o, 2.5, dot);
    }
  }
  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// FIX 23 item 14 — the background gradient colors for a stored
/// room_bg_id, shared by the room panel ([_bgColors]) and the
/// parent chat area (CommunityDetailPage), so both show the same
/// background. Unknown ids (and 'custom', whose image belongs to
/// the room panel only) fall back to the Neon Nights default.
List<Color> roomBackgroundColorsFor(String bgId) {
  for (final b in _UnifiedRoomPageState._bgPresets) {
    if (b['id'] == bgId) {
      return (b['colors'] as List<int>).map((c) => Color(c)).toList();
    }
  }
  return const [Color(0xFF2D1B4E), Color(0xFF1A0B2E), Color(0xFF0B0618)];
}

class _UnifiedRoomPageState extends State<UnifiedRoomPage> {
  final _msg = TextEditingController();
  final _msgFocus = FocusNode();
  final _chatScroll = ScrollController();
  Map<String, dynamic>? _replyTo;
  // FULL COMPLETION expansion 2: low-data mode — room images load
  // only on tap when this is true (read from SharedPreferences).
  bool _lowData = false;
  final Set<String> _loadedImages = {};
  bool _joined = false;
  // ADMIN CHAT GATE EXEMPTION (2026-10-30 user screenshot): the
  // designated admin (admin_config.admin_firebase_uid, same check as
  // _loadRoomAdmin) may send chat/gifts/stickers/images and raise a
  // hand without tournament registration or a join fee. Ordinary
  // users/spectators keep the join gate. The direct _adminUid
  // comparison (not just _isRoomAdmin) covers the window where
  // _checkJoined ran before _loadRoomAdmin finished.
  bool get _canSendChat {
    final myUid = FirebaseAuth.instance.currentUser?.uid ?? '';
    return _joined ||
        _isRoomAdmin ||
        (myUid.isNotEmpty && _adminUid.isNotEmpty && myUid == _adminUid);
  }
  // JOIN BANNER widget: one-shot per room entry — 5 s auto-dismiss
  // plus an X. The timer is started once (guarded) and cancelled
  // on dispose; dismissing only hides the bar, the send-time gate
  // (toast + composer hint) still blocks non-joined sends.
  Widget _buildJoinBanner() {
    _joinBannerTimer ??= Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _joinBannerDismissed = true);
    });
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
      decoration: BoxDecoration(color: const Color(0xFF241D05), borderRadius: BorderRadius.circular(16), border: Border.all(color: nGold.withValues(alpha: 0.5)), boxShadow: [BoxShadow(color: nGold.withValues(alpha: 0.10), blurRadius: 10)]),
      child: Row(
        children: [
          Expanded(child: Text('You must join this tournament to send messages.', style: TextStyle(color: kMuted, fontSize: 12))),
          InkWell(
            onTap: () {
              _joinBannerTimer?.cancel();
              setState(() => _joinBannerDismissed = true);
            },
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(Icons.close, color: kMuted, size: 16),
            ),
          ),
        ],
      ),
    );
  }

  bool _checkedJoin = false;
  bool _showVoiceDiag = false;
  // FIX 22 item 8 — the native DSP load error, fetched lazily
  // while Voice diagnostics is open (the Kotlin side records it
  // when System.loadLibrary throws). Null = no error recorded, or
  // the fetch has not run yet.
  String? _dspNativeError;
  bool _dspNativeErrorLoaded = false;
  // USER ORDER 2026-11-01: Live Chat / Voice Chat tabs REMOVED —
  // chat panel is messages only; voice peers stay reachable via
  // the Participants sheet on the rail. NO Gift tab either.
  // ADMIN-ONLY ROOM CONTROL (2026-10-30 user order): ownership and
  // all participant controls below belong ONLY to the designated
  // admin (admin_config.admin_firebase_uid). A non-admin creator or
  // co-host gets NO admin menu and NO owner powers in this room.
  // Enforcement is sticky by design: an admin mute/mic-off/reject
  // stays in force until the admin explicitly clears it (inbox
  // admin_unmute / admin_mic_on / admin_mic_allow), never by the
  // target tapping their own seat.
  bool _isRoomAdmin = false;
  String _adminUid = '';
  // JOIN BANNER (2026-10-30 user order): the "must join to send
  // messages" bar must NEVER be a permanent sticky bar. It shows
  // only once per room entry, auto-dismisses after 5 s, and has an
  // X. _adminLoaded gates it: the banner waits until the admin
  // check finishes, so the admin never even flashes it while
  // _checkJoined beats _loadRoomAdmin. Send-time blocking (toast
  // + composer hint) is unchanged for non-joined users.
  bool _adminLoaded = false;
  // FIX 12 G6b (2026-11-23): _loadRoomAdmin fills _adminUid /
  // _isRoomAdmin / _adminMicRejected async from initState, and the
  // embedded panel's post-frame auto-join used to RACE it — the mic
  // gate could read the not-yet-loaded state, send a mic request
  // and return without ever joining, for a user who IS the admin
  // (the panel then sat silent: no join, no error, no banner).
  // _joinVoiceOpen awaits this future (bounded) before the gates
  // that read admin state, so the gate always sees loaded state.
  Future<void>? _adminLoadFuture;
  bool _joinBannerDismissed = false;
  Timer? _joinBannerTimer;
  bool _adminMutedHeld = false;
  bool _adminMicOffHeld = false;
  bool _adminMicRejected = false;
  // MIC REQUEST / APPROVAL (2026-10-30 user order): NOBODY goes
  // directly on a mic except the admin. A non-admin tap sends a
  // mic_request inbox row to the admin; only a mic_approved row
  // from the admin unlocks the tap, for 2 minutes or until used.
  // Pending requests live in _micRequests on the ADMIN's phone
  // (rebuilt from the inbox on re-entry, since inbox rows persist
  // until handled); approvals live on the REQUESTER's phone.
  List<Map<String, String>> _micRequests = [];
  bool _micRequestPending = false;
  // MUSIC-STREAM ADMIN CONTROL (2026-10-30 user order): nobody
  // broadcasts shared music except the admin, or a non-admin the
  // admin approved. Transport mirrors mic requests (voice inbox
  // 'music_' kinds); listener-side enforcement comes from hidden
  // MUSIC_APPROVAL:: chat rows (see _handleMusicRows), so a
  // streamer cannot fake approval locally — every listener checks
  // the shared approval row before playing a stranger's session.
  List<Map<String, String>> _musicRequests = [];
  bool _musicRequestPending = false;
  bool _musicApproved = false; // this phone may broadcast this visit
  final Set<String> _musicApprovedStreamers = {}; // listener-side
  static const String _musicApprovalPrefix = 'MUSIC_APPROVAL::';
  // CHAT CLEAR (2026-10-30 user order): marker row written AFTER
  // a clear, so other phones know to drop their local welcome rows
  // too. Filtered from visible chat like MUSIC:: rows.
  static const String _chatClearedPrefix = 'CHAT_CLEARED::';
  // PHASE E (E14): also match the PLAIN-TEXT legacy notice
  // ("— Chat history clear kar di gayi —", written by an old
  // version with no CHAT_CLEARED:: prefix) — the prefix filter
  // alone let it sit STICKY as an organizer bubble.
  static bool _isChatClearedRow(Map<String, dynamic> m) {
    final msg = strVal(m['message']);
    return msg.startsWith(_chatClearedPrefix) ||
        msg.contains('Chat history clear kar di gayi');
  }
  static bool _isMusicApprovalRow(Map<String, dynamic> m) => strVal(m['message']).startsWith(_musicApprovalPrefix);
  bool get _isAdminForBroadcast {
    final myUid = FirebaseAuth.instance.currentUser?.uid ?? '';
    return _isRoomAdmin || (myUid.isNotEmpty && _adminUid.isNotEmpty && myUid == _adminUid);
  }
  // FIX 2 (2026-11-22): in TEAM scope the team captain/creator is a
  // broadcaster too — the tournament-only admin_config check left
  // team rooms with NO broadcaster when admin_config was unreadable,
  // and the tournament join gate blocked everyone (team rooms have
  // no tournament to join). Captain identity follows the line-4242
  // pattern: loaded _creatorUid first, widget.captainUid fallback.
  bool get _isTeamCaptainForBroadcast {
    if (!_isTeam) return false;
    final myUid = FirebaseAuth.instance.currentUser?.uid ?? '';
    if (myUid.isEmpty) return false;
    final captain = _creatorUid.isNotEmpty ? _creatorUid : widget.captainUid;
    return captain.isNotEmpty && myUid == captain;
  }
  // FIX 12 G6 (2026-11-23, verifier 4 F1): in COMMUNITY scope the
  // community organizer/creator is a broadcaster too — the
  // tournament-only admin check + team-captain check left
  // community rooms with NO broadcaster when the organizer was
  // not the app admin. Organizer identity follows the line-4394
  // pattern: loaded _creatorUid first, widget.organizerUid fallback.
  bool get _isCommunityOrganizerForBroadcast {
    if (!_isCommunity) return false;
    final myUid = FirebaseAuth.instance.currentUser?.uid ?? '';
    if (myUid.isEmpty) return false;
    final organizer = _creatorUid.isNotEmpty ? _creatorUid : widget.organizerUid;
    return organizer.isNotEmpty && myUid == organizer;
  }
  // FIX 22 item 6 — the RJ console's host gate, shared by the
  // rail button / music-panel RJ pill / settings-sheet RJ row /
  // _showRjVoiceConsole: admin, team captain, or community
  // organizer (same three flags as the music broadcast gate).
  bool get _rjHostGatePasses =>
      _isAdminForBroadcast ||
      _isTeamCaptainForBroadcast ||
      _isCommunityOrganizerForBroadcast;
  bool get _canBroadcastMusic => _isAdminForBroadcast || _isTeamCaptainForBroadcast || _isCommunityOrganizerForBroadcast || _musicApproved;
  // FIX 2: the "join this tournament first" gate is tournament-only.
  // Team rooms have no tournament to join — being in the team IS the
  // join, so the gate never blocks team scope.
  bool get _broadcastJoinBlocked => !_isTeam && !_isCommunity && !_joined && !_isAdminForBroadcast;
  // ADMIN PROFILE NAME for the always-admin host strip (below):
  // fetched from the admin's profiles row on room entry, so the
  // strip shows the admin's real name even when the admin is not
  // on voice. Empty = profile unreadable (strip falls back to the
  // role label 'Admin', never to a non-admin name).
  String _adminProfileName = '';
  DateTime? _micApprovedUntil;
  // Admin-chosen slot from a mic_approved row ('mic_slot:N' in the
  // inbox sdp payload). Null = approval without a chosen slot
  // (historic path) -> join-order placement.
  int? _micApprovedSlot;
  // ROUND 13 backgrounds (per-device, persisted in SharedPreferences):
  // built-ins are original gradients only; a custom upload goes
  // through the existing ImgBB path and its URL is stored here, so
  // the choice survives room re-entries on THIS phone. A background
  // shared for EVERYONE would need a room-background column/table
  // (migration) — not faked here; see parent report.
  String _bgId = 'neon';
  // FIX 23 items 14+21: true once the user (or the tournament's
  // shared background) has picked a background explicitly. While
  // false, the room shows the app-wide background image
  // (AppBackgroundLayer — item 21's bundled artwork, item 22's
  // remote URL when set) instead of the neon gradient: the image
  // supersedes item 14's code-drawn default. An explicit pick —
  // including 'neon' itself — always wins over the image.
  bool _bgUserPicked = false;
  String _customBgUrl = '';
  static const List<Map<String, dynamic>> _bgPresets = [
    // FIX 23 item 14 (user order 2026-11-23): the DEFAULT
    // background is Neon Nights — a rich dark-purple neon
    // gradient (same palette as the neon reference) so the
    // chat room is beautiful on first open, not plain black.
    // A stored choice (SharedPreferences room_bg_id) still
    // wins over it; the picker lists it first.
    {'id': 'neon', 'name': 'Neon Nights', 'colors': [0xFF2D1B4E, 0xFF1A0B2E, 0xFF0B0618]},
    {'id': 'gold', 'name': 'Royal Gold', 'colors': [0xFF4A3510, 0xFF2A1C08, 0xFF120C06, 0xFF070402]},
    {'id': 'emerald', 'name': 'Emerald', 'colors': [0xFF064E3B, 0xFF022C22, 0xFF01120E]},
    {'id': 'royal', 'name': 'Royal Blue', 'colors': [0xFF1E3A8A, 0xFF172554, 0xFF020617]},
    {'id': 'crimson', 'name': 'Crimson', 'colors': [0xFF7F1D1D, 0xFF450A0A, 0xFF1F0505]},
    {'id': 'violet', 'name': 'Violet Night', 'colors': [0xFF4C1D95, 0xFF2E1065, 0xFF12041F]},
    {'id': 'midnight', 'name': 'Midnight', 'colors': [0xFF0F172A, 0xFF1E293B, 0xFF020617]},
    // FULL COMPLETION expansion 3: extra premium themes (original
    // gradients only, same ornamental layer on top).
    {'id': 'rosegold', 'name': 'Rose Gold', 'colors': [0xFF831843, 0xFF500724, 0xFF1F0410]},
    {'id': 'teal', 'name': 'Ocean Teal', 'colors': [0xFF0F766E, 0xFF134E4A, 0xFF042F2E]},
    {'id': 'ember', 'name': 'Sunset Ember', 'colors': [0xFF9A3412, 0xFF431407, 0xFF1C0A04]},
  ];
  List<Color> _bgColors() {
    if (_bgId == 'custom') return const [Color(0x99000000), Color(0xCC0B0803), Color(0xFF0B0803)];
    return roomBackgroundColorsFor(_bgId);
  }
  Future<void> _loadBackground() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final id = prefs.getString('room_bg_id');
      final url = prefs.getString('room_bg_custom_url') ?? '';
      if (!mounted) return;
      setState(() { if (id != null && id.isNotEmpty) { _bgId = id; _bgUserPicked = true; } _customBgUrl = url; });
      // REMAINING-ITEMS shared background: if the tournament has a
      // shared background (tournaments.shared_bg_id/shared_bg_url,
      // migration 011), it WINS over the per-device choice, so every
      // member sees the same room. Clearing the shared value falls
      // back to each phone's own choice. Team rooms have no
      // tournament row — per-device choice only (v2016 FIX 11).
      // FIX 12 G6: same for community rooms (no tournament row).
      try {
        if (!_isTeam && !_isCommunity) {
          final t = await SupaDb.getTournament(widget.tournamentId);
          final sid = SupaDb.strOf(t['shared_bg_id']);
          final surl = SupaDb.strOf(t['shared_bg_url']);
          if (mounted && sid.isNotEmpty) setState(() { _bgId = sid; _bgUserPicked = true; if (surl.isNotEmpty) _customBgUrl = surl; });
        }
      } catch (_) {}
    } catch (_) {}
  }
  Future<void> _shareBackground() async {
    // v2016 FIX 11: shared backgrounds live on the tournaments
    // row — team rooms have none, so there is nothing to share to.
    // FIX 12 G6: same for community rooms.
    if (_isTeam || _isCommunity) {
      if (mounted) toast(context, 'Shared background ${_isCommunity ? 'community' : 'team'} rooms mein nahi — apni device wali background use hoti hai.');
      return;
    }
    try {
      await SupaDb.client.from('tournaments').update({'shared_bg_id': _bgId, 'shared_bg_url': _bgId == 'custom' ? _customBgUrl : ''}).eq('id', widget.tournamentId);
      if (mounted) toast(context, 'Shared background set — sab members ko yehi background dikhega.');
    } catch (e) {
      if (mounted) toast(context, 'Share failed (migration 011 pending?): $e');
    }
  }
  Future<void> _clearSharedBackground() async {
    // v2016 FIX 11: no shared background exists for team rooms.
    // FIX 12 G6: same for community rooms.
    if (_isTeam || _isCommunity) {
      if (mounted) toast(context, 'Shared background ${_isCommunity ? 'community' : 'team'} rooms mein nahi hai.');
      return;
    }
    try {
      await SupaDb.client.from('tournaments').update({'shared_bg_id': null, 'shared_bg_url': null}).eq('id', widget.tournamentId);
      if (mounted) toast(context, 'Shared background hat gaya — ab har phone apni choice dikhayega.');
    } catch (e) {
      if (mounted) toast(context, 'Clear failed: $e');
    }
  }
  Future<void> _setBackground(String id, {String customUrl = ''}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('room_bg_id', id);
      if (customUrl.isNotEmpty) await prefs.setString('room_bg_custom_url', customUrl);
    } catch (_) {}
    if (mounted) setState(() { _bgId = id; _bgUserPicked = true; if (customUrl.isNotEmpty) _customBgUrl = customUrl; });
    // FIX 23 items 14+21: tell the parent the background changed so
    // the chat area behind the panel matches the new pick.
    widget.onBackgroundChanged?.call();
  }
  Future<void> _uploadBackground() async {
    try {
      final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
      if (picked == null || !mounted) return;
      toast(context, 'Uploading background…');
      try {
        final url = await ImgbbService.uploadImage(File(picked.path));
        await _setBackground('custom', customUrl: url);
        if (mounted) toast(context, 'Background uploaded and applied.');
      } catch (_) {
        // ImgBB failed: keep it working on this phone only, from the
        // picked file itself (may vanish if the gallery file moves).
        await _setBackground('custom', customUrl: 'file:${picked.path}');
        if (mounted) toast(context, 'Upload failed — background applied from your phone only.');
      }
    } catch (e) {
      if (mounted) toast(context, 'Background upload failed: $e');
    }
  }
  bool _voiceRetrying = false;
  // SMALL EMOJI STRIP ONLY (2026-10-30): the big Emoji/Gifts picker
  // panel is REMOVED (see composer below). Tapping the composer
  // smiley toggles one slim horizontal emoji row that inserts a
  // small emoji inline into typed text — that is the only emoji UI.
  bool _showEmojiStrip = false;
  bool _atBottom = true;
  bool _wasKbOpen = false; // ROUND 9 keyboard-open transition tracker
  int _lastMsgCount = -1;
  // Animated welcome: session-only. _seenPeers seeds on the FIRST
  // non-empty peers snapshot (members already in the room get no
  // welcome); only keys appearing AFTER that trigger one banner.
  // A peer who leaves and rejoins is a genuinely new join, so they
  // welcome again — but mute/unmute updates (same keys) never do.
  Set<String>? _seenPeers;
  // ROUND 6 welcome rows (IN the chat list, session-only, persistent):
  // the old banner lived ABOVE the chat and auto-hid after 6s, so a
  // user who looked at chat later saw nothing — and it only fired
  // on voice-peer joins, never on plain room entry. These rows stay
  // in the chat list for the whole session. One join = one row:
  // _welcomedUids dedupes across the voice + presence triggers.
  final List<Map<String, dynamic>> _welcomeRows = [];
  final Set<String> _welcomedUids = {};
  // USER ORDER 2026-11-01: welcome is a FLASH, not a sticky row:
  // on join it slides in once at the top of the chat panel, then
  // auto-hides after ~4s and never stays in chat history.
  String? _flashWelcome;
  Timer? _flashWelcomeTimer;
  // REMAINING-ITEMS: real follow state (follows table) for chat senders.
  final Set<String> _following = {};
  Future<void> _loadFollowing() async {
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
      if (uid.isEmpty) return;
      final rows = await SupaDb.getList('follows', eqCol: 'follower_uid', eqVal: uid);
      if (mounted) setState(() => _following.addAll(rows.map((r) => SupaDb.strOf(r['following_uid']))));
    } catch (_) {}
  }
  bool _presenceSeeded = false;
  Timer? _presenceTimer;
  // A-5 ROOM LOAD CONTROL (026, O-admin-panel W5): the room_controls
  // row for this tournament. _roomVoiceDisabled drives the "Band hai"
  // banner + the voice-join gate; _roomControlNotified ensures the
  // mid-voice disconnect dialog shows exactly once per OFF transition
  // (reset when the room re-opens). Polled every 30 s, aligned with
  // the presence heartbeat cadence.
  bool _roomVoiceDisabled = false;
  String _roomDisabledReason = '';
  Timer? _roomControlTimer;
  // v2017 INLINE VOICE: embedded mode has no chat StreamBuilder,
  // so MUSIC:: / chat-cleared rows are fed to the same handlers
  // via this direct subscription (created in initState when
  // embedded, cancelled in dispose).
  StreamSubscription<List<Map<String, dynamic>>>? _musicRowsSub;
  // FIX 20 (fix 18): the room chat stream, created ONCE in
  // initState — the same fix as Watch Live. streamChat returns a
  // FRESH polling stream per call, so building it inside build()
  // recreated + resubscribed on every rebuild. The full-page chat
  // StreamBuilder and the embedded MUSIC-rows subscription share
  // this one stream (only one subscribes per mount — embedded
  // has no chat UI, full page has no _musicRowsSub).
  late final Stream<List<Map<String, dynamic>>> _chatStream;
  bool _roomControlNotified = false;
  DateTime? _roomControlLastCheck;
  Map<String, String> _roomRegNames = {};
  // PHASE 3 #27 squad tags: team_name per registered uid, from the SAME
  // registration rows _startPresenceWelcomes already loads (no new query).
  // tournament_registrations.team_name (001) — empty = Solo / no team.
  Map<String, String> _roomRegTeams = {};
  // PHASE 3 #27 organizer fallback: tournament created_by (same rule as
  // _hostEntry — the creator fallback runs only when the admin UID is
  // unreadable; FIX 22 item 14: the Host pill above the name is a
  // separate widget — the fallback NAME itself still carries no
  // role label).
  String _creatorUid = '';
  // PRESENCE GATE (2026-10-30 user report: offline user still
  // showed green on seats): the 10s presence poll below refreshes
  // this map; seats/strip gate their green on it (see
  // _peerLooksOnline). No row = fall back to voice freshness alone,
  // so a presence-write failure can never grey out a live speaker.
  Map<String, Map<String, dynamic>> _presenceMap = {};
  // REMAINING-ITEMS: reactions are now SHARED via
  // chat_messages.reactions (migration 011) — see _chatItem.
  late final Future<Map<String, dynamic>> _tournamentFuture;
  MusicDspPlayer? _musicPlayer;
  String? _musicPlaying;
  // ARENA HUB #10 AUDIO (Group 2 swap): panel state for the
  // music-player sheet. The sheet is a StatefulBuilder, so these
  // live on the page state (like _musicBaseVolume) — they survive
  // sheet rebuilds and reopens, and the panel's props always show
  // the values actually applied to the engine. The effects drive
  // the MUSIC player's own AudioDsp instance (_musicPlayer.dsp —
  // the private engine its pump calls process() on) through
  // MusicFx (lib/audio/music_fx.dart), resolved per handler via
  // _musicDsp() below. The old session-0 effect instances
  // (ReverbEffect / EchoDelayEffect / BassEqEffect /
  // PlaybackEffects) are GONE: their attach-to-player path took an
  // audioplayers AudioPlayer, which the swap removed. NEVER the
  // voice-chain instance.
  double _fxReverb = 0.0;
  double _fxEcho = 0.0;
  // Off-preset delay: the native delay line's 250 ms default (see
  // presetValues in audio_effects_panel.dart — echo is 0, so it is
  // inaudible until echo is turned up).
  double _fxDelayMs = 250.0;
  double _fxBass = 0.0;
  String _fxPreset = 'Off';
  bool _fxNoiseCancellation = false;
  // MUSIC-PLAYER SHEET VOICE-CHAIN MIRRORS (Group 9 panel): the
  // mic chain's gate threshold + compressor state. The engine
  // exposes no getters, so the mount mirrors the last-applied
  // values — engine defaults until the host moves a control
  // (gate -40 dB, compressor -18 dB / 4.0:1 — DspMicProcessor
  // setNoiseGate / setCompressor defaults). The gate ENABLED
  // mirror is shared with the voice console
  // (_rjNoiseGateEnabled — one gate, one toggle; both sheets
  // read/write the same field).
  double _musicGateThresholdDb = -40.0;
  bool _musicCompressorEnabled = false;
  double _musicCompressorThresholdDb = -18.0;
  double _musicCompressorRatio = 4.0;
  // RJ STUDIO VOICE CONSOLE (2026-11-22): the host's LIVE mic-chain
  // console — RjStudioPanel, mounted in _showRjVoiceConsole and
  // wired to the MIC chain (DspMicProcessor / CompositeMicProcessor
  // live setters via micPipeline.source) instead of the playback
  // effects. The panel OWNS its knob/preset/fader state, so the
  // console keeps only the two pieces of state the panel's props
  // still need from the mount: the noise-gate toggle mirror
  // (_rjNoiseGateEnabled — the panel syncs its toggle from this
  // prop) and the picker guard (_rjSwitchingProcessor — a switch
  // re-publishes the live mic, double-taps must not stack). The
  // old _rj* mirror fields (reverb/echo/delay/bass/preset/
  // thresholds/EQ preset) went away with the AudioEffectsPanel
  // mount — the panel pushes its own values straight to the DSP
  // now (see RJ_PANEL_INTEGRATION.md §7). Param changes NEVER
  // touch the mic track (setter -> channel -> bridge pending
  // preset -> next mic frame); only the processor picker
  // re-publishes (via LiveKitVoiceService.setNoiseProcessor).
  bool _rjNoiseGateEnabled = false;
  // FIX 20 (fix 9): session-local LIVE state — the host's own
  // GO LIVE / END LIVE toggle. Lives in the ROOM state (not the
  // console sheet's StatefulBuilder) so it survives sheet
  // rebuilds and re-opens. No backend calls, no fake data: the
  // timer is the real elapsed time since GO LIVE, and the
  // listener count stays the real LiveListeners count. Live does
  // NOT auto-end on disconnect (follow-up decision) — the host
  // ends it with END LIVE.
  bool _rjIsLive = false;
  DateTime? _rjLiveStartedAt;
  // Picker guard: one processor switch at a time (a switch
  // re-publishes the live mic — double-taps must not stack).
  bool _rjSwitchingProcessor = false;
  // Soundboard (route A, 2026-11-22): owned by the ROOM SCREEN, not
  // LivekitVoiceService — the voice service sits exactly at its
  // surgical line bound (530 < 531) and the soundboard is a
  // console-mount concern. Lifetime = room screen (initState ->
  // dispose), which is the voice session for practical purposes.
  late final Soundboard _soundboard;
  // ROUND 7 shared music (speaker + mic, user's own file):
  // _musicIsFile = a picked file is playing (shared via speaker/mic);
  // false = one of the built-in tones (local-only, unchanged).
  // _musicPaused tracks Pause/Resume for the file player.
  bool _musicIsFile = false;
  bool _musicPaused = false;
  // ROUND 9 TRUE SHARED MUSIC (supersedes round 7 for shared files):
  // the player's picked file is uploaded to Supabase Storage bucket
  // 'room-music' (public, see dashboard steps in the round-9 report —
  // the app CANNOT create the bucket itself with the anon key), and
  // a session is broadcast as a chat row with the MUSIC:: prefix
  // (no new table, no migration — chat_messages already carries
  // scope + tournament/squad id, and the rows are FILTERED OUT of
  // the visible chat + activity lists below). Every room member's
  // phone then plays the SAME file from the public URL — no mic
  // pickup needed. Play/Pause/Resume/Stop are synced from the player.
  // Speaker+mic survives ONLY as the labelled fallback when the
  // upload fails (e.g. bucket not set up yet): _sharedFallback.
  // Local tones stay local-only, unchanged.
  static const String _musicPrefix = 'MUSIC::';
  static bool _isMusicRow(Map<String, dynamic> m) => strVal(m['message']).startsWith(_musicPrefix);
  static const String _sharedBucket = 'room-music';
  // RJ DUCKING (round 9): while shared music plays, the PLAYER's mic
  // state is the single trigger — unmuted (speaking, like an FM RJ)
  // ducks music on EVERY phone to 5% (RJ bed), muted restores 100%.
  static const double _musicDuckedVolume = 0.05; // RJ BED (2026-10-30 user order: mic ON = music near-silent, voice loud on top — the old level was still masking the voice)
  Map<String, dynamic>? _sharedSession; // sessionId, playerUid, playerName, title, url, startedAtMs, storagePath
  bool _sharedFallback = false; // speaker+mic fallback after upload failure
  bool _sharedDucked = false;
  // ROUND 12 MUSIC UI: Broadcast toggle. FIX 22 item 21:
  // default OFF — hosting is GO LIVE only; before GO LIVE
  // the music plays LOCALLY ONLY (no session row is
  // broadcast, so other phones hear nothing). GO LIVE arms
  // the broadcast (upload+share the current song, or arm
  // the flag so the next song shares); END LIVE disarms it.
  // Library + playlist are SESSION-ONLY (this phone, this
  // room visit): picked files and tones, never synced, never
  // persisted.
  bool _broadcastMusic = false;
  final List<Map<String, dynamic>> _localLibrary = []; // {key,title,artist,kind:'file'|'tone',path,url}
  final Set<String> _playlistKeys = {};
  double _musicBaseVolume = 1.0; // slider value; ducking multiplies it by 0.05 (RJ bed)
  // FIX 20 (fix 11): mic-fader-linked ducking (talkover) — the
  // console's MIC fader level (panel default 0.8). The fader does
  // NOT set mic gain (no such control exists); it scales the
  // music output via _applyMusicVolume. My mic is ON when joined
  // + unmuted on either engine.
  double _micFaderLevel = 0.8;
  bool get _isMyMicOn =>
      (_lkRoom.joined && !_lkRoom.muted) || (_room.joined && !_room.muted);
  // FIX 24 — radio mixer (2026-11-23 user order): the host's music
  // mixed directly into the live mic stream (native
  // MusicMixProcessor on the capturePostProcessing hook).
  // [_radioMixerLive] mirrors the native registration (true only
  // between a successful register and unregister). [_rjMicLinkOn]
  // is the panel MIC ON/OFF button: ON (default — current
  // behaviour) = the inverse link is active; OFF = the mic fader
  // is be-asar and the music fader is manual. [_rjCallInGuestUid]
  // is the host's selected call-in guest (null = none/auto-pick).
  // [_rjPreBroadcastKind] remembers the mic processor GO LIVE
  // switched away from (Krisp force-switch — see
  // _registerRadioMixer), restored on END LIVE.
  final RadioMixer _radioMixer = RadioMixer();
  bool _radioMixerLive = false;
  bool _rjMicLinkOn = true;
  String? _rjCallInGuestUid;
  MicProcessorKind? _rjPreBroadcastKind;
  // FIX 22 item 11 (2026-11-23 user order: "fade in fade out ko
  // chhodo") — NO FADES AT ALL. _applyMusicVolume writes the
  // computed target DIRECTLY (one setVolume call) — user faders,
  // ducking and mic toggles all apply at once. The old FM-style
  // fade (350 ms down / 1400 ms up smoothstep) is deleted:
  // every drag tick restarted the ramp and the volume lagged
  // behind the finger. (The "last written volume" tracker went
  // with it: it only existed to resume mid-fade ramps from the
  // current volume, and direct application has no ramp to resume.)
  bool _musicRepeat = true; // loop on by default (historic behaviour)
  Duration _musicDuration = Duration.zero;
  bool _musicDurAttached = false;
  String _nowPlayingKey = '';
  String _librarySearch = '';
  int _libraryTab = 0; // 0 = Local Music, 1 = My Playlist
  final _librarySearchCtrl = TextEditingController();
  final Set<String> _seenMusicRowIds = {};
  // v2016 FIX 9 (user order 2026-11-22): room-entry timestamp (ms).
  // A MUSIC:: play row older than this entry is HISTORY — it only
  // plays if its player is live right now (see _musicPlayerLiveNow).
  // A row written after entry is a live start and always plays.
  // This is the join-time autoplay rule: a joiner hears music only
  // if the host is already playing, never a stale default.
  late final int _roomEnteredAtMs;
  // STALE-SESSION GUARD (2026-10-30): a MUSIC:: 'play' row lives in
  // chat history forever, so re-entering a room used to replay an
  // old host's track even though nobody was hosting any more (the
  // stop row is missing when the host's app was killed, or it has
  // scrolled out of the last-30 catch-up window). Sessions the user
  // stopped are never restarted by a replayed row either.
  final Set<String> _stoppedMusicSessions = {};
  Timer? _sharedDuckPoll; // non-voice listeners poll the player's peer row
  Map<String, bool> _sharedPeerMuted = {}; // playerUid -> muted, from poll
  late final VoiceRoom _room;
  // LIVEKIT TEST PATH (2026-11-01, user order): a SEPARATE SFU
  // engine beside the mesh. _useLiveKit is session-only (never
  // persisted): Mesh stays the default every room entry, and the
  // test engine only runs when the user explicitly picks it in
  // Settings -> Voice test (LiveKit) for that visit. Switching
  // engines drops the current voice session (a LiveKit room cannot
  // transfer between engines/projects mid-call) and requires a
  // fresh join — the panel says exactly that.
  late final LiveKitVoiceService _lkRoom;
  // ARENA HUB #10 AUDIO — RJ Studio listeners (Group 7): live
  // listener count + detail from the LiveKit room (participants
  // minus mic-seat occupants). Session peak is in-memory only
  // until the backend lands stored peaks.
  late final LiveListeners _liveListeners;
  // Latest seat occupants (uids), recomputed in _buildSeatGrid
  // from the same peerForMicCell source the stage renders.
  Set<String> _lastSeatUids = {};
  // Guards the post-frame listeners refresh scheduled from the
  // seat grid (one per frame at most).
  bool _listenersRefreshScheduled = false;
  // FIX 72 (hide option, user order 2026-11-24): the embedded
  // panel's mic seats + sidebar Row is collapsed. Default false
  // (shown). Session-local only — deliberately NOT persisted
  // (no SharedPreferences, no server write): every entry shows
  // the seats again. The host card + header strip NEVER hide
  // (fix23 item 16: the host card is sticky, always present).
  bool _seatsHidden = false;
  // The open panel sheet's refresh fn (music or voice console),
  // so the listener count stays live while the sheet is open.
  // A stale fn (sheet closed) throws once and is cleared by
  // _onListenersChanged's try/catch.
  void Function()? _listenersSheetRefresh;
  // FIX 31: avatar-URL + verified-flag cache for seats/host/chat
  // senders (profile photoURL / verified flag, fetched once per
  // uid via SupaDb.getProfilesMap; missing = '' / false, never
  // a fake photo or tick). Host-verified futures are cached per
  // uid so the FutureBuilder below never refetches.
  final Map<String, String> _fix31AvatarUrls = {};
  final Map<String, bool> _fix31VerifiedFlags = {};
  final Set<String> _fix31AvatarFetching = {};
  final Map<String, Future<bool>> _fix31HostVerifiedFutures = {};
  bool _useLiveKit = false;
  LiveKitConfig? _lkConfig;
  // LIVEKIT RECONNECT (2026-11-01, user order): a LiveKit room
  // lives on ONE project, so switching the active project — or a
  // network drop — WILL break voice for a few seconds; that
  // break cannot be made zero. What this recovers is the ROOM
  // session: the banner below (never a popup, never a kick-out)
  // offers Refresh / Dobara Connect, which re-reads the CURRENT
  // active project and reconnects voice in-place — same room,
  // same chat, same seats (all Supabase state survives). It does
  // NOT rejoin the tournament and does NOT re-run the mic-request
  // gate (this is a continuation of an already-approved session,
  // not a new mic take) — but it DOES re-check the admin mute
  // hold and admin reject first, so a user muted/rejected while
  // dropped cannot reconnect past the admin.
  bool _lkWasJoined = false; // a LiveKit session was live before
  String _lkJoinedProjectId = ''; // project that session ran on
  bool _lkLastMuted = true; // mic state while joined, restored on reconnect
  bool _lkDropped = false; // show the in-room reconnect banner
  String? _lkDropReason;
  bool _lkReconnecting = false;
  String? _lkReconnectError;
  bool _lkIntentionalDisconnect = false; // leave/engine-switch: no banner
  DateTime? _lkLastProjectCheck; // throttle the project-change poll
  // FIX 12 G6b (2026-11-23, 01:56 live issue): the "Connecting…"
  // pill hung for nearly an hour after the LiveKit project
  // switch — _joinVoiceLiveKit only TOASTED failures, so a failed
  // join looked identical to a join still in flight, with no
  // retry and no reason. [_lkConnecting] = a join is actually in
  // flight right now (the pill shows "Connecting…" ONLY then);
  // [_lkConnectError] = the last join failure's honest reason
  // (null = no failure) — shown in the error banner with a Retry
  // button. Together with the service's 30 s connect timeout
  // they make a silent hang impossible: every path lands on
  // Connected, Connecting (bounded) or Failed + Retry.
  bool _lkConnecting = false;
  String? _lkConnectError;
  bool _voiceErrorDismissed = false; // X on the error banner

  // Sticker marker (no migration): a chat_messages row whose message
  // starts with this prefix is rendered as a LARGE sticker by this
  // app's renderer only. Plain text never starts with it.
  static const String _stickerPrefix = 'STICKER::';
  static bool _isSticker(Map<String, dynamic> m) => strVal(m['message']).startsWith(_stickerPrefix);
  static String _stickerOf(Map<String, dynamic> m) => strVal(m['message']).substring(_stickerPrefix.length);
  // FREE gifts: sent as a chat row with this prefix, rendered LARGE
  // like stickers. No wallet deduction, no prices, no gift store —
  // gifts are a free room reaction, consistent with free-only.
  // Image messages: photo uploaded via the existing ImgBB flow,
  // sent as a chat row with this prefix (like stickers/gifts — no
  // migration, the message text carries the URL). Rendered as a
  // photo card + timestamp below.
  static const String _imgPrefix = 'IMG::';
  static bool _isImage(Map<String, dynamic> m) => strVal(m['message']).startsWith(_imgPrefix);
  static String _imageOf(Map<String, dynamic> m) => strVal(m['message']).substring(_imgPrefix.length);
  static String _replyLabel(Map<String, dynamic> m) {
    if (_isImage(m)) return '📷 Photo';
    if (_isSticker(m)) return _stickerOf(m);
    if (_isGift(m)) return '${_giftOf(m)} (gift)';
    return strVal(m['message']);
  }

  // FULL COMPLETION: shoutcaster messages + free-coin cheers.
  static const String _shoutPrefix = 'SHOUT::';
  static bool _isShout(Map<String, dynamic> m) => strVal(m['message']).startsWith(_shoutPrefix);
  static String _shoutOf(Map<String, dynamic> m) => strVal(m['message']).substring(_shoutPrefix.length);
  static const String _cheerPrefix = 'CHEER::';
  static bool _isCheer(Map<String, dynamic> m) => strVal(m['message']).startsWith(_cheerPrefix);
  static String _cheerOf(Map<String, dynamic> m) => strVal(m['message']).substring(_cheerPrefix.length);

  // BIG GIFTS REMOVED (2026-10-30 user order): the _gifts list and
  // _sendGift path are deleted. _isGift/_giftPrefix are kept ONLY
  // as the filter that hides old GIFT:: rows from the stream (same
  // pattern as the sticker filter) — no big gift ever renders now.
  static const String _giftPrefix = 'GIFT::';
  static bool _isGift(Map<String, dynamic> m) => strVal(m['message']).startsWith(_giftPrefix);
  static String _giftOf(Map<String, dynamic> m) => strVal(m['message']).substring(_giftPrefix.length);

  // BIG STICKERS REMOVED (2026-10-30 user order): the old _stickers
  // list and _sendSticker path are deleted. The small Emoji tab
  // (inline emoji inserted into typed text) is NOT a sticker and
  // stays. _isSticker/_stickerPrefix are kept ONLY as the filter
  // that hides old STICKER:: rows from the stream.
  // P1-7: the emoji set is the ONE shared list ([ArenaEmojis.all]) —
  // the room strip, the TeamChat/DM/community pickers all read the
  // same 48 emojis, so the set cannot drift between chats.
  static const List<String> _emojis = ArenaEmojis.all;

  // Consistent avatar colour per user (hash of uid/name).
  Color _avatarColor(String key) {
    final palette = [kGold, Color(0xFF38BDF8), Color(0xFF4ADE80), Color(0xFFC084FC), Color(0xFFFB923C), Color(0xFFF472B6), Color(0xFF2DD4BF)];
    var h = 0;
    for (final c in key.codeUnits) {
      h = (h * 31 + c) & 0x7fffffff;
    }
    return palette[h % palette.length];
  }

  void _addWelcomeRow(String uid, String name) {
    if (_welcomedUids.contains(uid)) return;
    _welcomedUids.add(uid);
    // Flash only: callers rebuild after this (own-welcome wraps in
    // setState, peer/presence paths setState after the loop), so
    // assigning here is enough; the timer hides it again.
    _flashWelcome = name;
    _flashWelcomeTimer?.cancel();
    _flashWelcomeTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _flashWelcome = null);
    });
  }

  void _onPeersChanged() {
    if (!mounted) return;
    final keys = _room.peers.keys.toSet();
    if (_seenPeers == null) {
      if (keys.isNotEmpty) _seenPeers = keys;
    } else {
      final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
      for (final k in keys) {
        if (!_seenPeers!.contains(k) && k != uid) {
          final peer = _room.peers[k] ?? {};
          _addWelcomeRow(k, strVal(peer['display_name'], strVal(peer['name'], _roomRegNames[k] ?? 'A player')));
        }
      }
      _seenPeers = keys;
    }
    // ROUND 9: peer mute changes are the ducking trigger for
    // voice-joined listeners (and for the player themself) — the
    // VoiceRoom notifies on every setMuted, so this fires within
    // ~2s of ANY seat tapping their mic (poll + realtime). The
    // trigger is any-speaker, not player-only (see
    // _anyMicUnmuted).
    _applySharedDucking();
    // FIX 22 item 10: also re-apply in local/fallback mode
    // (the ducking call above early-returns without a session).
    _reapplyMusicVolumeForMicToggle();
    setState(() {});
  }

  // Own entry: the joiner also sees their own welcome row in the
  // chat list (the video shows the join message in chat itself).
  Future<void> _addOwnWelcome() async {
    try {
      final uid = FirebaseAuth.instance.currentUser!.uid;
      final profile = await SupaDb.getProfile(uid);
      final name = strVal(profile['displayName'], FirebaseAuth.instance.currentUser!.email?.split('@').first ?? 'You');
      if (mounted) setState(() => _addWelcomeRow(uid, name));
    } catch (_) {}
  }

  // Room-entry trigger (no voice needed): Detail entry writes
  // presence.current_tournament_id / squad_id, so a 10s presence
  // check over this tournament's registered players sees a member
  // ENTER the tournament context. First check only SEEDS the set
  // (members already present get no row); later arrivals get one.
  // A member who never opens Detail/room writes no context and
  // cannot be observed — that is a data limit, stated honestly.
  Future<void> _startPresenceWelcomes() async {
    try {
      // v2016 FIX 11: team rooms have no registrations — members
      // come from team_members (rows carry user_name).
      if (_isTeam) {
        final members = await SupaDb.getList('team_members', eqCol: 'team_id', eqVal: widget.teamId);
        if (!mounted) return;
        _roomRegNames = {for (final m in members) if (strVal(m['firebase_uid']).isNotEmpty) strVal(m['firebase_uid']): strVal(m['user_name'], 'A player')};
        _roomRegTeams = {};
        _presenceTimer = Timer.periodic(const Duration(seconds: 10), (_) => _checkPresenceWelcomes());
        _checkPresenceWelcomes();
        return;
      }
      // FIX 12 G6: community rooms have no registrations either —
      // members come from community_members (rows carry no name,
      // so the presence map only seeds uids; names resolve from
      // profiles/peers like everywhere else).
      if (_isCommunity) {
        final members = await SupaDb.getList('community_members', eqCol: 'community_id', eqVal: widget.communityId, orderBy: 'created_at', ascending: true, limit: 1000);
        if (!mounted) return;
        _roomRegNames = {for (final m in members) if (strVal(m['firebase_uid']).isNotEmpty) strVal(m['firebase_uid']): 'A player'};
        _roomRegTeams = {};
        _presenceTimer = Timer.periodic(const Duration(seconds: 10), (_) => _checkPresenceWelcomes());
        _checkPresenceWelcomes();
        return;
      }
      final regs = _isSquad ? await SupaDb.getSquadRegistrations(widget.tournamentId, widget.squadId) : await SupaDb.getRegistrations(widget.tournamentId);
      if (!mounted) return;
      _roomRegNames = {for (final r in regs) strVal(r['firebase_uid']): strVal(r['username'], strVal(r['display_name'], 'A player'))};
      // PHASE 3 #27: same rows already carry team_name — keep it for the
      // squad tag on chat messages (no extra query, no invented tags).
      _roomRegTeams = {for (final r in regs) strVal(r['firebase_uid']): strVal(r['team_name'])};
      _presenceTimer = Timer.periodic(const Duration(seconds: 10), (_) => _checkPresenceWelcomes());
      _checkPresenceWelcomes();
    } catch (_) {}
  }

  Future<void> _checkPresenceWelcomes() async {
    if (!mounted) return;
    // LiveKit project-change poll (throttled inside): never
    // disconnects anything, only raises the reconnect banner.
    _maybeDetectLiveKitProjectChange();
    // ADMIN ENFORCEMENT POLL (10 s, same timer): a muted target
    // must be forced mic-off even if the inbox control was missed,
    // and a target NOT on voice still receives admin controls here
    // (the VoiceRoom inbox poll only runs while voice-joined).
    // Fire-and-forget: it must never block the presence update.
    _pollAdminEnforcement();
    if (_roomRegNames.isEmpty) return;
    try {
      // v2016 FIX 8: the presence query covers REGISTERED uids
      // only — an unregistered local user (room admin, spectator
      // just reading chat) has a presence row with this room's
      // context but was never queried, so the count missed them
      // by one. Always include the local uid.
      final myUid = FirebaseAuth.instance.currentUser?.uid ?? '';
      final queryUids = _roomRegNames.keys.toList();
      if (myUid.isNotEmpty && !queryUids.contains(myUid)) queryUids.add(myUid);
      final pres = await SupaDb.getPresenceMap(queryUids);
      // v2016 FIX 8: the Online count must update live on join AND
      // leave — the old code only rebuilt when a welcome row was
      // added, so a leave (presence going stale) never moved the
      // count. Capture the count before the map swap and rebuild
      // below whenever it changes.
      final countBefore = _roomUserCount();
      // PRESENCE GATE: keep the latest presence rows for seat/strip
      // gating. Seats used voice-peer freshness ONLY while the
      // Status sheet used presence last_seen ONLY — two different
      // heartbeat clocks (voice 30s, presence 60s), so one could
      // flip grey up to ~a minute before the other and the room
      // contradicted itself. A stale presence row now overrides a
      // still-fresh voice row on seats/strip.
      _presenceMap = pres;
      var added = false;
      for (final e in pres.entries) {
        final row = e.value;
        final inRoom = _presenceInRoom(row);
        if (!inRoom || !SupaDb.presenceIsOnline(row)) continue;
        if (!_presenceSeeded) continue;
        if (_welcomedUids.contains(e.key)) continue;
        // v2016 FIX 8: never welcome SELF here — _addOwnWelcome
        // already adds the joiner's own row at entry, and an
        // unregistered local user has no name in _roomRegNames
        // (would render as 'A player').
        if (e.key == myUid) continue;
        _addWelcomeRow(e.key, _roomRegNames[e.key] ?? 'A player');
        added = true;
      }
      if (!_presenceSeeded) {
        for (final e in pres.entries) {
          final row = e.value;
          final inRoom = _presenceInRoom(row);
          if (inRoom && SupaDb.presenceIsOnline(row)) _welcomedUids.add(e.key);
        }
        _presenceSeeded = true;
      }
      if ((added || _roomUserCount() != countBefore) && mounted) setState(() {});
    } catch (_) {}
  }

  // --- A-5 ROOM LOAD CONTROL (026, O-admin-panel W5) ---
  // Polls the room_controls row for this tournament (30 s, aligned
  // with the presence heartbeat). CRITICAL GUARD: if the read fails
  // (table missing — 026 not applied), the room is treated as ON
  // and voice is never blocked on a read error (SupaDb.getRoomControl
  // returns {} on failure, and {} means ON).
  // OFF mid-voice -> graceful disconnect (LiveKit disconnect() /
  // mesh leave()) + the exact notice dialog below. Tournament info,
  // brackets, results and chat stay visible — OFF kills voice load,
  // not the tournament. Re-ON clears the state; players rejoin by
  // tapping voice join again (no auto-rejoin: the admin may close
  // the room again at once, and a silent auto-rejoin would fight it).
  static const String _roomClosedNotice = 'Room admin ne band kar diya hai — load zyada tha. Dobara khulne pe join kar sakenge.';

  Future<void> _pollRoomControl() async {
    // v2016 FIX 11: team rooms have no per-tournament room-control
    // row — nothing to poll; voice is always on for team rooms.
    // FIX 12 G6: same for community rooms (no tournament row either).
    if (_isTeam || _isCommunity) return;
    if (!mounted) return;
    final last = _roomControlLastCheck;
    if (last != null && DateTime.now().difference(last) < const Duration(seconds: 25)) return;
    _roomControlLastCheck = DateTime.now();
    final control = await SupaDb.getRoomControl(widget.tournamentId);
    if (!mounted) return;
    final disabled = SupaDb.isRoomVoiceDisabled(control);
    final reason = SupaDb.strOf(control['disabled_reason']);
    if (!disabled) {
      if (_roomVoiceDisabled || _roomDisabledReason.isNotEmpty || _roomControlNotified) {
        setState(() {
          _roomVoiceDisabled = false;
          _roomDisabledReason = '';
          _roomControlNotified = false;
        });
      }
      return;
    }
    final wasDisabled = _roomVoiceDisabled;
    if (mounted) {
      setState(() {
        _roomVoiceDisabled = true;
        _roomDisabledReason = reason;
      });
    }
    if (wasDisabled && _roomControlNotified) return;
    final onVoice = _room.joined || _lkRoom.joined;
    if (onVoice && !_roomControlNotified) {
      _roomControlNotified = true;
      await _disconnectVoiceForRoomClosed();
    }
  }

  /// Graceful voice teardown for an admin-closed room: intentional
  /// disconnect (so the LiveKit drop banner never fires), mesh leave
  /// + LiveKit disconnect, then the exact notice dialog. Chat,
  /// brackets, results and tournament info are untouched.
  Future<void> _disconnectVoiceForRoomClosed() async {
    try {
      _lkIntentionalDisconnect = true;
      if (_lkRoom.joined) await _lkRoom.disconnect();
      if (_room.joined) await _room.leave();
    } catch (_) {}
    if (!mounted) return;
    setState(() {});
    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (dctx) => AlertDialog(
        backgroundColor: kCardPurpleMid,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22), side: const BorderSide(color: kCardPurpleBorder, width: 1.5)),
        title: const Text('Room band ho gaya', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(_roomClosedNotice, style: TextStyle(color: Colors.white, fontSize: 14)),
            if (_roomDisabledReason.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('Reason: $_roomDisabledReason', style: const TextStyle(color: nText2, fontSize: 12)),
            ],
          ],
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(dctx), child: const Text('Theek hai', style: TextStyle(color: nGold, fontWeight: FontWeight.bold)))],
      ),
    );
  }

  /// "Band hai" banner at the top of the room (voice join disabled
  /// while the room is OFF). Chat and the rest of the room stay usable.
  Widget _buildRoomDisabledBanner() {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(color: const Color(0xFFFF3B30).withValues(alpha: 0.15), borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFFFF3B30)), boxShadow: [BoxShadow(color: const Color(0xFFFF3B30).withValues(alpha: 0.12), blurRadius: 10)]),
      child: Row(
        children: [
          const Icon(Icons.mic_off, color: Color(0xFFFF3B30), size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _roomDisabledReason.isNotEmpty ? 'Room band hai — $_roomDisabledReason' : 'Room band hai — voice join abhi band hai.',
              style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  void _scrollToBottom() {
    if (!_chatScroll.hasClients) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_chatScroll.hasClients) _chatScroll.animateTo(_chatScroll.position.maxScrollExtent, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
    });
  }

  bool get _isSquad => widget.scope == 'squad';
  // v2016 FIX 11(b–d): 'team' scope — voice room inside a team's
  // chat. Identity = squad_<teamId> (squadRoomId — the token
  // endpoint already accepts the squad_ prefix). community_ is
  // for PUBLIC communities only (the community room now lives
  // in 'community' scope with identity community_<id>);
  // team rooms never use it.
  bool get _isTeam => widget.scope == 'team';
  // FIX 12 G6 (2026-11-23): 'community' scope — the full voice
  // room inside a public community's detail page. Identity =
  // community_<id> (communityRoomId — the A1 token endpoint
  // accepts the community_ prefix).
  bool get _isCommunity => widget.scope == 'community';
  String get _voiceRoomId => _isTeam ? squadRoomId(widget.teamId) : _isCommunity ? communityRoomId(widget.communityId) : _isSquad ? squadRoomId(widget.squadId) : tournamentRoomId(widget.tournamentId);
  String get _roomTitle => _isTeam ? 'Team Room — ${widget.teamName}' : _isCommunity ? 'Community Room — ${widget.communityName}' : _isSquad ? 'Squad Room — ${widget.squadName}' : 'Tournament Room — ${widget.tournamentName}';
  // Team chat rows live in squad_id='team_<id>' (streamChat/sendChat
  // 'team' branch, same shape as TeamChatPage) — one getter so all
  // chat call sites agree. Community rows live in
  // community_id (streamChat/sendChat 'community' branch, the
  // sendCommunityChatMessage shape: tournament_id null).
  String get _chatScopeId => _isTeam ? 'team_${widget.teamId}' : _isCommunity ? widget.communityId : _isSquad ? widget.squadId : widget.tournamentId;
  String get _chatScopeCol => (_isSquad || _isTeam) ? 'squad_id' : _isCommunity ? 'community_id' : 'tournament_id';
  // Team mic seats: 6 (FIX 11 — Squad removed, every team room
  // has 6). The caller passes micCount; 0 falls back to 6.
  int get _teamMicCount => widget.micCount > 0 ? widget.micCount : 6;
  // FIX 12 G6: community mic seats — 6, the same full system
  // the old clan room had. The caller passes micCount; 0 falls
  // back to 6.
  int get _communityMicCount => widget.micCount > 0 ? widget.micCount : 6;
  // Presence "in this room" rule, single source: team rooms count
  // any online team member (the presence map only holds members —
  // same rule as TeamChatPage's header count); community rooms
  // count any online community member (same reason — the map only
  // holds community members); squad/tournament rooms require the
  // matching context field.
  bool _presenceInRoom(Map<String, dynamic> row) {
    if (_isTeam || _isCommunity) return true;
    if (_isSquad) return strVal(row['squad_id']) == widget.squadId;
    return strVal(row['current_tournament_id']) == widget.tournamentId;
  }
  // Capacity from mode (teamSizeOf), never hardcoded per room type.
  int get _squadCapacity => SupaDb.teamSizeOf({'mode': widget.mode});

  @override
  void initState() {
    super.initState();
    _roomEnteredAtMs = DateTime.now().millisecondsSinceEpoch;
    SharedPreferences.getInstance().then((prefs) {
      if (mounted) setState(() => _lowData = prefs.getBool('low_data_mode') ?? false);
    });
    _room = VoiceRoom(roomId: _voiceRoomId, roomLabel: _roomTitle);
    _room.onAdminControl = _handleAdminControl;
    _room.onMicSignal = _handleMicSignal;
    _room.onMusicSignal = _handleMusicSignal;
    // LiveKit test engine: created but never joined until the user
    // picks it in Settings and taps Join — Mesh stays the default.
    _lkRoom = LiveKitVoiceService(roomId: _voiceRoomId, roomLabel: _roomTitle);
    _lkRoom.addListener(_onLiveKitChanged);
    // FIX 12 G6 (FIX 15 carry-over): community rooms honor
    // organizer-mute packets only from the community creator —
    // the old detail-page voice service set this from
    // created_by_uid; the room page owns the service now, so it
    // sets it here (refreshed from the communities row below).
    if (_isCommunity) _lkRoom.organizerUid = widget.organizerUid;
    // ARENA HUB #10 AUDIO — RJ Studio listeners: the service
    // derives listeners from LiveKit participants minus seats;
    // resolvers reuse the room's existing profile lookup.
    _liveListeners = LiveListeners(
      nameResolver: _resolveListenerName,
      avatarResolver: _resolveListenerAvatar,
    );
    _liveListeners.addListener(_onListenersChanged);
    _soundboard = Soundboard();
    // AUDIO #10 — install the RNNoise mic processor (Group 2) as the
    // default noise canceller. Fail-open: if the native engine is
    // absent (no .so yet) initialize() returns false and the mic
    // stays plain; the NC toggle stays hidden until a processor
    // installs. Krisp (Group 1) is NOT wired: it is Cloud-gated and
    // expected OFF on our self-hosted server.
    unawaited(_installMicNoiseProcessor());
    // v2016 FIX 11: team rooms load the TEAMS row (no tournament);
    // its captain is the creator fallback (same role as created_by).
    // FIX 12 G6: community rooms load the COMMUNITIES row; its
    // created_by_uid is the organizer fallback.
    _tournamentFuture = _isTeam ? SupaDb.getRow('teams', 'id', widget.teamId) : _isCommunity ? SupaDb.getRow('communities', 'id', widget.communityId) : SupaDb.getTournament(widget.tournamentId);
    // PHASE 3 #27: creator uid for the ORGANIZER-badge fallback (same rule
    // as _hostEntry). Best-effort; a missing row just leaves _creatorUid ''.
    _tournamentFuture.then((t) {
      final c = _isTeam ? SupaDb.strOf(t['captain_uid'], widget.captainUid) : _isCommunity ? SupaDb.strOf(t['created_by_uid'], widget.organizerUid) : SupaDb.strOf(t['created_by']);
      if (mounted && c.isNotEmpty) setState(() => _creatorUid = c);
      // FIX 12 G6: refresh the organizer UID for mute packets
      // from the fresh communities row (same value as _creatorUid).
      if (_isCommunity && c.isNotEmpty) _lkRoom.organizerUid = c;
    }, onError: (_) {});
    _room.addListener(_onPeersChanged);
    _chatScroll.addListener(() {
      if (_chatScroll.hasClients) {
        _atBottom = _chatScroll.position.maxScrollExtent - _chatScroll.position.pixels < 120;
      }
    });
    _msgFocus.addListener(() {
      if (_msgFocus.hasFocus) {
        // Typing: emoji strip must not fight the keyboard.
        if (_showEmojiStrip) setState(() => _showEmojiStrip = false);
        Future.delayed(const Duration(milliseconds: 300), _scrollToBottom);
      }
    });
    _loadBackground();
    _loadPersistedMusic();
    _loadFollowing();
    _checkJoined();
    _addOwnWelcome();
    _startPresenceWelcomes();
    _adminLoadFuture = _loadRoomAdmin();
    // A-5 room-control poll (026): OFF mid-voice -> graceful
    // disconnect + notice (see _pollRoomControl). Throttled to 30 s.
    _pollRoomControl();
    _roomControlTimer = Timer.periodic(const Duration(seconds: 30), (_) => _pollRoomControl());
    // ROUND 11: heartbeat immediately on room entry, so the entrant
    // is green in the Status sheet at once — not only after the
    // shell's 60 s timer fires, and not grey from a stale offline
    // write left by a previous Detail/room dispose.
    PresenceService.goOnline();
    // ROUND 9: late joiners catch an already-running shared session
    // (the chat stream only carries the OLDEST 200 rows, so a busy
    // room's play row may not be in it — this direct newest-first
    // query finds the latest session row regardless).
    _catchUpSharedMusic();
    // FIX 20 (fix 18): one chat stream per mount (see _chatStream).
    _chatStream = SupaDb.streamChat(widget.scope, _chatScopeId);
    // PHASE E (E29, 2026-11-24): NO auto-join on mount. The
    // embedded panel used to connect voice as soon as it opened
    // (v2017 "open = connect"); Sameer ordered it off — voice
    // opens ONLY when the user taps the mic/voice button (or a
    // seat / the Voice menu entry). The room UI (chat, seats,
    // host card) renders normally with voice OFF; no
    // "Connecting..." pill on entry. The panel's dispose still
    // leaves voice, so close = disconnect.
    if (widget.embedded) {
      // MUSIC:: rows: the full page handles them via its chat
      // StreamBuilder; the panel has no chat UI, so it subscribes
      // directly and feeds the SAME handlers (shared playback
      // keeps working while the panel is open). KEPT by E29 —
      // this is not a voice join.
      _musicRowsSub = _chatStream.listen((rows) {
        if (mounted) {
          _handleMusicRows(rows);
          _handleChatEmptied(rows);
        }
      });
    }
    // FIX 16 (2026-11-23): bind the header Settings sheet's
    // actions — the sheet reaches the panel's voice functions
    // through this controller (unbound in dispose).
    _bindVoiceController();
  }

  /// FIX 16: bind the panel's voice functions into the header
  /// Settings sheet's controller. The RJ row's visibility is a
  /// getter (admin state loads async — never a bind-time
  /// snapshot). Null controller (full-page mode) = no-op.
  void _bindVoiceController() {
    widget.voiceController?.bind(
      onMusic: () => unawaited(
          _showRjVoiceConsole(initialSection: 'player')),
      onRoomSettings: _showRoomSettings,
      onRjConsole: _showRjVoiceConsole,
      onCloseVoice: widget.onCloseVoice,
      // FIX 22 item 5: the embedded sidebar's Leave menu
      // reaches the room through the same controller (the
      // parents hold no room reference of their own).
      // (Item 15 removed the Participants menu.)
      onLeaveVoice: _leaveEmbeddedVoice,
      // FIX 20 (fix 7b): RJ is for the ROOM HOST — admin, team
      // captain, or community organizer (same parity as music
      // broadcast). Listeners still see no RJ row.
      rjVisible: () =>
          _isAdminForBroadcast ||
          _isTeamCaptainForBroadcast ||
          _isCommunityOrganizerForBroadcast,
      // FIX 23 item 4: the flattened room-settings rows for
      // the community Settings sheet (same targets as
      // _showRoomSettings' rows, reached directly).
      onBackgrounds: _showBackgroundsPanel,
      onFrames: () => unawaited(_openFrames()),
      onParticipantsStatus: _openStatus,
      onVoiceDiagnostics: () => setState(() => _showVoiceDiag = true),
      onVoiceTest: _showLiveKitPanel,
      onCheer: () => unawaited(_sendCheer()),
    );
  }

  @override
  void didUpdateWidget(covariant UnifiedRoomPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // FIX 16: rebind if the chat page hands over a different
    // settings controller (never happens today — the controller
    // is owned by the chat state — but a stale binding would
    // point the sheet at a dead panel).
    if (oldWidget.voiceController != widget.voiceController) {
      oldWidget.voiceController?.unbind();
      _bindVoiceController();
    }
    // PHASE E (E29): the parent unlocked voice while the panel
    // was mounted (locked line -> seats) — the panel used to
    // auto-join here; it does NOT anymore. Voice opens only on
    // the user's tap, even after an unlock.
  }

  @override
  void dispose() {
    // FIX 24: leaving unhooks the radio mixer (the mix stops with
    // the room; restoreMute false — leave() disposes the mic
    // stream right below, so no held mute needs restoring).
    unawaited(_unregisterRadioMixer(restoreMute: false));
    // FIX 16: drop the header Settings sheet's bindings — the
    // panel is gone, so the sheet's actions become safe no-ops.
    widget.voiceController?.unbind();
    _joinBannerTimer?.cancel();
    _flashWelcomeTimer?.cancel();
    _presenceTimer?.cancel();
    _roomControlTimer?.cancel();
    _musicRowsSub?.cancel();
    _stopSharedDuckPoll();
    // ROUND 9: leaving stops shared playback for THIS phone (player
    // below, local stop). If THIS phone is the player, also end the
    // session for everyone (best-effort, fire-and-forget): otherwise
    // the looped file would keep playing for listeners forever with
    // no player left to stop it. A listener leaving sends nothing —
    // other members keep listening.
    final myUid = FirebaseAuth.instance.currentUser?.uid ?? '';
    if (_sharedSession != null && strVal(_sharedSession!['playerUid']) == myUid) {
      _sendMusicAction('stop', session: _sharedSession!);
    }
    // Leaving the room screen stops music: it must never keep playing
    // in the background after the user has left (no setState here —
    // dispose must not rebuild; stop + dispose the player directly).
    _musicPlayer?.stop();
    _musicPlayer?.dispose();
    // ARENA HUB #10 AUDIO (Group 2 swap): the old playback-effects
    // teardown is gone with PlaybackEffects — the music DSP player
    // (and its owned AudioDsp instance) is disposed with the player
    // just above.
    _room.leave();
    _lkRoom.disconnect();
    _lkRoom.dispose();
    // ARENA HUB #10 AUDIO — listeners: release the service (its
    // ChangeNotifier) and drop the sheet refresh fn.
    _liveListeners.dispose();
    _soundboard.dispose();
    _listenersSheetRefresh = null;
    // Room exit ends this tournament context too: mark offline now
    // (voice peer row removal above only clears the mic badge, not
    // presence). Re-entering a Detail page or resuming the app
    // re-heartbeats.
    // v2017 INLINE VOICE: the embedded panel's dispose must NOT
    // mark the user offline — they are still in the team chat
    // (the chat page + shell heartbeat own presence there).
    if (!widget.embedded) PresenceService.goOffline();
    _room.dispose();
    _librarySearchCtrl.dispose();
    _msg.dispose();
    _msgFocus.dispose();
    _chatScroll.dispose();
    super.dispose();
  }

  void _insertEmoji(String e) {
    // Shared cursor-insert helper (same behaviour as before).
    insertEmojiAtCursor(_msg, e);
  }

  // LIVE CHAT IMAGE UPLOAD — ROUND 7 ITEM 1 (2026-11-20): the photo
  // button looked dead/missing — pickImage threw MissingPluginException
  // on the old registrant and the catch only toasted the raw exception.
  // Now: ImagePicker first (compressed at pick time, same as the other
  // in-tree uploaders), file_picker (images only) as fallback on
  // MissingPluginException — the exact pattern from admin_promotions
  // _pickAndUpload / AdminImageUpload — and plain-language toasts only,
  // never raw exception text. Image upload never dead-ends.
  Future<void> _sendImage() async {
    if (!_canSendChat) {
      toast(context, 'You must join this tournament to send messages.');
      return;
    }
    try {
      File? file;
      try {
        final picked = await ImagePicker().pickImage(
          source: ImageSource.gallery,
          imageQuality: 85,
          maxWidth: 1600,
        );
        if (picked == null) return;
        file = File(picked.path);
      } on MissingPluginException {
        final res = await FilePicker.platform.pickFiles(
          type: FileType.image,
          allowMultiple: false,
        );
        final path = res?.files.single.path;
        if (path == null || path.isEmpty) return;
        file = File(path);
      }
      if (!mounted) return;
      toast(context, 'Uploading image…');
      final url = await ImgbbService.uploadImage(file);
      final user = FirebaseAuth.instance.currentUser!;
      final profile = await SupaDb.getProfile(user.uid);
      await SupaDb.sendChat(
        scope: widget.scope,
        scopeId: _chatScopeId,
        uid: user.uid,
        displayName: strVal(profile['displayName'], user.email ?? 'User'),
        message: '$_imgPrefix$url',
      );
      _scrollToBottom();
    } on MissingPluginException {
      // Both pickers unavailable — plain message, never raw text.
      if (mounted) toast(context, 'Photo nahi bheji ja saki — dobara koshish karein.');
    } catch (_) {
      if (mounted) toast(context, 'Photo nahi bheji ja saki — dobara koshish karein.');
    }
  }

  // --- Music: ORIGINAL synthesized tones, generated in-app as WAV
  // bytes and played through a temp file on the DSP player. No
  // downloads, no copyrighted tracks, no songs. Music plays on THIS
  // phone only — it is NOT sent to other members (the voice channel
  // is mic-only).
  static Uint8List _toneWav(List<List<double>> chords, {double pulseHz = 0}) {
    const rate = 22050;
    final seconds = chords.length;
    final total = rate * seconds;
    final bytes = ByteData(44 + total * 2);
    void str(int off, String v) {
      for (var i = 0; i < v.length; i++) {
        bytes.setUint8(off + i, v.codeUnitAt(i));
      }
    }

    void u32(int off, int v) => bytes.setUint32(off, v, Endian.little);
    void u16(int off, int v) => bytes.setUint16(off, v, Endian.little);
    str(0, 'RIFF');
    u32(4, 36 + total * 2);
    str(8, 'WAVE');
    str(12, 'fmt ');
    u32(16, 16);
    u16(20, 1);
    u16(22, 1);
    u32(24, rate);
    u32(28, rate * 2);
    u16(32, 2);
    u16(34, 16);
    str(36, 'data');
    u32(40, total * 2);
    for (var i = 0; i < total; i++) {
      final chord = chords[i ~/ rate];
      final local = i % rate;
      // 30ms fade at each chord boundary so loops do not click.
      var env = 1.0;
      if (local < 660) env = local / 660;
      if (local > rate - 660) env = (rate - local) / 660;
      if (i < 2200) env *= i / 2200;
      if (i > total - 2200) env *= (total - i) / 2200;
      var amp = 0.0;
      for (final f in chord) {
        amp += math.sin(2 * math.pi * f * i / rate);
      }
      amp = amp / chord.length * 0.55 * env;
      if (pulseHz > 0) amp *= 0.6 + 0.4 * math.sin(2 * math.pi * pulseHz * i / rate);
      bytes.setInt16(44 + i * 2, (amp * 32767).round().clamp(-32767, 32767), Endian.little);
    }
    return bytes.buffer.asUint8List();
  }

  // MUSIC DSP SWAP (2026-11-22): the music player is the Group 8
  // DSP player (decode -> DSP -> AudioTrack). It has NO audio
  // context API — the native AudioTrack is USAGE_MEDIA /
  // CONTENT_TYPE_MUSIC, and there is no focus handling in the
  // plugin (deliberate scope — phone check, see
  // MUSIC_PLAYER_INTEGRATION.md §3.5). It also has NO release
  // mode: loop (repeat) is mount-side, via completedStream.
  Future<MusicDspPlayer> _ensureMusicPlayer() async {
    _musicPlayer ??= MusicDspPlayer();
    // FIX 24 — radio mixer feed: the pump ALSO forwards every
    // processed chunk to the native mixer (same bytes, already
    // decoded + FX'd) while GO LIVE is on, and flushes the mixer
    // on seek/stop/load. The callbacks no-op when the mixer is
    // not live, so they are safe to leave attached. Idempotent —
    // the same closures are re-assigned on every call.
    _musicPlayer!.onProcessedChunk = (chunk) {
      if (_radioMixerLive) _radioMixer.pushChunk(chunk);
    };
    _musicPlayer!.onPumpReset = () {
      if (_radioMixerLive) unawaited(_radioMixer.flush());
    };
    if (!_musicDurAttached) {
      _musicDurAttached = true;
      _musicPlayer!.durationStream.listen((d) {
        _musicDuration = d;
        if (mounted) setState(() {});
      });
      _musicPlayer!.completedStream.listen((_) async {
        if (!mounted || !_musicRepeat || _musicPlaying == null) return;
        // play() rewinds to 0 after a natural end (player §5.1),
        // so a loop is just a re-play — no seek needed here.
        try {
          await _musicPlayer!.play();
        } catch (_) {}
      });
    }
    return _musicPlayer!;
  }

  // MUSIC DSP SWAP (2026-11-22): the single load+play entry for
  // every music source. The DSP player takes a file path OR a
  // public URL (MediaExtractor accepts both), so local files,
  // shared URLs and the speaker fallback all go through one call.
  // Returns the track duration (load's own value — the listener
  // seek in _startListeningSession uses it directly instead of
  // waiting up to 8 s for a duration event).
  Future<Duration> _playMusicSource(String path) async {
    final player = await _ensureMusicPlayer();
    final duration = await player.load(path);
    await player.play();
    return duration;
  }

  // Effective volume: the slider's base value, ducked to 5% of it (RJ bed)
  // while a shared session is ducked (RJ mode).
  // FIX 22 item 11 (2026-11-23 user order: "fade in fade out ko
  // chhodo") — DIRECT, NO FADE: the computed target is written in
  // ONE setVolume call, at once — user faders, ducking and mic
  // toggles all apply immediately. The old FM-style fade (350 ms
  // down / 1400 ms up smoothstep) is deleted: every drag tick
  // restarted the ramp and the volume lagged behind the finger
  // (item 9), and the duck ramp delayed the voice winning
  // (item 10). This replaces item 9's instant path AND item 10's
  // 350 ms ramp — direct is now the only path.
  // FIX 24 (2026-11-23) — SINGLE MECHANISM: the mic-fader factor
  // (micFaderDuckFactor) is REMOVED from this path. It used to
  // multiply with the inverse link's nudge (fix22 item 11), so one
  // mic drag changed the music through TWO multiplying paths — the
  // audible response was squared (a small drag = a 2.7x jump or
  // near-silence). The inverse link is now the ONLY mic/music
  // mechanism: it moves _musicBaseVolume itself, and this function
  // applies base x activity only (faderFactor 1.0). The pure
  // micFaderDuckFactor function stays (unit-tested) for the pins
  // only — it is applied nowhere in production anymore; it is
  // just no longer applied here.
  // The target formula lives in musicTargetVolume (pure,
  // unit-tested): shared = base * activity, local/fallback = base.
  // The MUSIC fader's set level (_musicBaseVolume) is never
  // written here — only read.
  Future<void> _applyMusicVolume() async {
    if (_musicPlayer == null) return;
    // FIX 24: faderFactor is 1.0 — the inverse link is the single
    // mechanism (see above). Do NOT re-add the fader-factor call
    // here: it squares the link's response.
    const faderFactor = 1.0;
    final activityFactor = _sharedDucked ? _musicDuckedVolume : 1.0;
    final target = musicTargetVolume(
      base: _musicBaseVolume,
      sharedSession: _sharedSession != null,
      activityFactor: activityFactor,
      faderFactor: faderFactor,
    );
    try { await _musicPlayer!.setVolume(target); } catch (_) {}
  }

  // FIX 22 item 11 — the inverse mic/music link, applied ONCE per
  // user gesture. The control the user moved takes its new value;
  // the other moves by the SAME delta in the OPPOSITE direction
  // (mic up -> music down, music up -> mic down, mic down ->
  // music up). The link lives ONLY in these two gesture handlers —
  // never inside _applyMusicVolume — so the nudged value can never
  // re-trigger it (no feedback loop, no oscillation). "Mic volume"
  // here is the MIC fader level (_micFaderLevel).
  // FIX 24: the link is GATED by the panel MIC button
  // (_rjMicLinkOn) via faderGestureNext — link OFF = manual, only
  // the moved control changes. The volume pushes are
  // FIRE-AND-FORGET (unawaited) so the console's refresh() runs
  // synchronously with the state update instead of waiting behind
  // async channel calls (the drag lag on slow phones). The mixer
  // gains push the same way — listeners hear the host's mix live.
  Future<void> _onUserMusicVolume(double v) async {
    final next = faderGestureNext(
      mic: _micFaderLevel,
      music: _musicBaseVolume,
      delta: v - _musicBaseVolume,
      musicMoved: true,
      linkOn: _rjMicLinkOn,
    );
    _musicBaseVolume = next.music;
    _micFaderLevel = next.mic;
    unawaited(_applyMusicVolume());
    _pushMixerGains();
  }

  Future<void> _onUserMicLevel(double v) async {
    final next = faderGestureNext(
      mic: _micFaderLevel,
      music: _musicBaseVolume,
      delta: v - _micFaderLevel,
      musicMoved: false,
      linkOn: _rjMicLinkOn,
    );
    _micFaderLevel = next.mic;
    _musicBaseVolume = next.music;
    unawaited(_applyMusicVolume());
    _pushMixerGains();
  }

  // DEMO TRACKS REMOVED (2026-10-30 user order): the Music panel
  // used to ship with built-in demo tones (Calm Chords, Bright
  // Chime, Soft Pulse). They are gone from the library — the panel
  // now lists only the user's own uploaded songs, and shows the
  // clean empty state until one is uploaded. The tone generator
  // code below is retained but unreachable from the panel (prev/
  // next already returns early on an empty def list).
  static List<Map<String, dynamic>> _toneDefs() => [];

  Map<String, dynamic> _toneEntry(Map<String, dynamic> def) => {'key': 'tone:${def['name']}', 'title': def['name'], 'artist': 'Built-in tone', 'kind': 'tone'};

  Future<void> _playToneByName(String name) async {
    final def = _toneDefs().firstWhere((t) => strVal(t['name']) == name, orElse: () => {});
    if (def.isEmpty) return;
    final chords = (def['chords'] as List).map((c) => (c as List).map((v) => (v as num).toDouble()).toList()).toList();
    await _playTone(name, chords, pulseHz: (def['pulse'] as num).toDouble());
  }

  Future<void> _playTone(String name, List<List<double>> chords, {double pulseHz = 0}) async {
    // Tones are unreachable (_toneDefs() is empty) — the DSP player
    // has no bytes API, so the generated WAV goes through a temp
    // file (same bytes, same sound) if this is ever reached again.
    final toneFile = File('${Directory.systemTemp.path}/arena_tone.wav');
    await toneFile.writeAsBytes(_toneWav(chords, pulseHz: pulseHz));
    await _playMusicSource(toneFile.path);
    await _musicPlayer?.setVolume(_musicBaseVolume);
    if (mounted) {
      setState(() {
        _musicPlaying = name;
        _musicIsFile = false;
        _musicPaused = false;
        _sharedSession = null;
        _sharedFallback = false;
        _nowPlayingKey = 'tone:$name';
      });
    }
  }

  // SPEAKER ROUTE RE-APPLY (2026-11-01 user repro: music on =
  // voice on the loudspeaker, music off = voice falls back to
  // the earpiece): while music plays, the music player's own
  // speaker route masks the voice route for the whole phone;
  // when music audio ends, that mask lifts and voice is left on
  // whatever the voice engine last set. So EVERY path where
  // music audio ends must re-assert the voice route — local
  // stop (_stopMusic), remote stop row, revoke, and pause —
  // not just the local stop. Idempotent (same speakerOn
  // value), and a no-op when voice is not joined. The remote
  // paths matter most: when the host stops a stream, listener
  // phones stop via chat rows, never via _stopMusic, so a
  // _stopMusic-only fix left listeners on the earpiece.
  void _reapplyVoiceRoute() {
    if (_lkRoom.joined) {
      unawaited(_lkRoom.reapplySpeakerRoute());
    } else if (_room.joined) {
      unawaited(_room.reapplySpeakerRoute());
    }
  }

  // ROUND 9: Stop. Player Stop ends the session for EVERYONE (stop
  // row broadcast BEFORE clearing local state); listener Stop only
  // stops this phone (no broadcast, and later rows for that session
  // are ignored because local session state is gone). Stopping
  // NEVER touches the mic — the user's mic stays exactly as left.
  Future<void> _stopMusic() async {
    final myUid = FirebaseAuth.instance.currentUser?.uid ?? '';
    final wasPlayer = _sharedSession != null && strVal(_sharedSession!['playerUid']) == myUid;
    final session = _sharedSession;
    // A locally stopped session must never restart from a replayed
    // 'play' row on a later snapshot (see _stoppedMusicSessions).
    if (session != null) _stoppedMusicSessions.add(strVal(session['sessionId']));
    await _musicPlayer?.stop();
    await _musicPlayer?.setVolume(_musicBaseVolume);
    _stopSharedDuckPoll();
    _reapplyVoiceRoute();
    if (mounted) {
      setState(() {
        _musicPlaying = null;
        _musicIsFile = false;
        _musicPaused = false;
        _sharedSession = null;
        _sharedDucked = false;
        _sharedFallback = false;
        _nowPlayingKey = '';
      });
    }
    if (wasPlayer && session != null) {
      try {
        await _sendMusicAction('stop', session: session);
      } catch (_) {}
    }
  }

  // ROUND 9: Pause/Resume. Player Pause/Resume broadcasts to the
  // whole room; listener Pause/Resume is LOCAL ONLY (labelled so in
  // the panel) — only the player can pause for everyone.
  Future<void> _pauseResumeMusic() async {
    if (_musicPlayer == null || _musicPlaying == null) return;
    final myUid = FirebaseAuth.instance.currentUser?.uid ?? '';
    final isPlayer = _sharedSession != null && strVal(_sharedSession!['playerUid']) == myUid;
    final session = _sharedSession;
    if (_musicPaused) {
      await _musicPlayer!.resume();
      if (isPlayer && session != null) {
        try {
          await _sendMusicAction('resume', session: session);
        } catch (_) {}
      }
    } else {
      await _musicPlayer!.pause();
      if (isPlayer && session != null) {
        try {
          await _sendMusicAction('pause', session: session);
        } catch (_) {}
      }
    }
    if (mounted) setState(() => _musicPaused = !_musicPaused);
  }

  // ROUND 7 mic behaviour (CHOSEN: no auto-unmute, explicit consent):
  // music may start while muted or while not on voice at all — it
  // ROUND 8: simply plays on this phone only until the user
  // takes a mic seat and taps their own seat to unmute. The panel
  // and the persistent room banner both say so. Nothing ever
  // unmutes the
  // user behind their back, so Stop has no mute state to restore.
  // PTT caveat: with push-to-talk ON, the mic is only open while the
  // user HOLDS the button — others hear the music only during holds.
  static const _audioExtensions = {'mp3', 'wav', 'm4a', 'aac', 'ogg', 'opus', 'flac'};

  // Shared picker: returns (path, name) or null on cancel/invalid.
  // Used by BOTH the round-9 share flow and the speaker fallback.
  Future<({String path, String name})?> _pickAudioFile() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.audio, allowMultiple: false);
    if (result == null || result.files.isEmpty) return null; // User cancelled: silent, no error.
    final picked = result.files.single;
    final path = picked.path;
    if (path == null || path.isEmpty) {
      if (mounted) toast(context, 'Could not read that file — please pick another audio file from your phone.');
      return null;
    }
    final ext = path.split('.').last.toLowerCase();
    if (!_audioExtensions.contains(ext)) {
      if (mounted) toast(context, 'That is not an audio file. Please pick an MP3, WAV, M4A, AAC, OGG or FLAC file.');
      return null;
    }
    if (!File(path).existsSync()) {
      if (mounted) toast(context, 'That file is no longer available on this phone. Please pick another audio file.');
      return null;
    }
    return (path: path, name: picked.name.isNotEmpty ? picked.name : path.split('/').last);
  }

  // ---------- ROUND 9: true shared music ----------
  // (The round-7 pick-and-play-local path is gone: the panel now
  // calls _pickAndShareFile, and the speaker fallback lives in
  // _playSpeakerFallback below.)
  static String _mimeForExt(String ext) {
    switch (ext) {
      case 'mp3':
        return 'audio/mpeg';
      case 'wav':
        return 'audio/wav';
      case 'm4a':
        return 'audio/mp4';
      case 'aac':
        return 'audio/aac';
      case 'ogg':
        return 'audio/ogg';
      case 'opus':
        return 'audio/opus';
      case 'flac':
        return 'audio/flac';
      default:
        return 'audio/mpeg';
    }
  }

  static String _safeFileName(String name) => name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');

  bool get _isSharedPlayer {
    final myUid = FirebaseAuth.instance.currentUser?.uid ?? '';
    return _sharedSession != null && strVal(_sharedSession!['playerUid']) == myUid;
  }

  // Broadcast one shared-music action row. Payload is JSON after the
  // MUSIC:: prefix; rows are hidden from chat/activity by the filter.
  // Sending needs NO voice join — only tournament join (same gate as
  // chat), so a player can share without taking a mic seat.
  Future<void> _sendMusicAction(String action, {required Map<String, dynamic> session}) async {
    final user = FirebaseAuth.instance.currentUser!;
    final profile = await SupaDb.getProfile(user.uid);
    final name = strVal(profile['displayName'], user.email ?? 'User');
    final payload = {
      'v': 1,
      'action': action,
      'session': strVal(session['sessionId']),
      'player': strVal(session['playerUid']),
      'playerName': strVal(session['playerName'], name),
      'title': strVal(session['title']),
      'url': strVal(session['url']),
      'startedAt': session['startedAtMs'] ?? 0,
    };
    await SupaDb.sendChat(
      scope: widget.scope,
      scopeId: _chatScopeId,
      uid: user.uid,
      displayName: name,
      message: '$_musicPrefix${jsonEncode(payload)}',
    );
  }

  // ROUND 12 MUSIC: library + broadcast helpers.
  // PLAYLIST PERSISTENCE (2026-10-30 user order): the library and
  // the My Playlist bookmarks used to live ONLY in memory, so a
  // saved song vanished on app restart. They now persist on this
  // phone in SharedPreferences (library entries + playlist keys,
  // JSON) and are merged back on room entry. Nothing is synced to
  // the backend. Entries whose local file was deleted (and which
  // have no shared URL) are dropped on load, never shown dead.
  static const String _musicLibPrefsKey = 'room_music_library_v1';
  static const String _musicPlaylistPrefsKey = 'room_music_playlist_v1';

  Future<void> _persistMusicLibrary() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final lib = _localLibrary.map((e) => jsonEncode({
            'key': strVal(e['key']),
            'title': strVal(e['title']),
            'artist': strVal(e['artist']),
            'kind': strVal(e['kind']),
            'path': strVal(e['path']),
            'url': strVal(e['url']),
            // FIX 20 (fix 16): size powers the title+size dedupe.
            'size': e['size'] is int ? e['size'] : 0,
          })).toList();
      await prefs.setStringList(_musicLibPrefsKey, lib);
      await prefs.setStringList(_musicPlaylistPrefsKey, _playlistKeys.toList());
    } catch (_) {}
  }

  Future<void> _loadPersistedMusic() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final libRaw = prefs.getStringList(_musicLibPrefsKey) ?? const [];
      final restored = <Map<String, dynamic>>[];
      for (final raw in libRaw) {
        try {
          final d = jsonDecode(raw);
          if (d is! Map) continue;
          final path = strVal(d['path']);
          final url = strVal(d['url']);
          if (path.isNotEmpty && !File(path).existsSync() && url.isEmpty) continue;
          // FIX 20 (fix 16): legacy entries have no stored size —
          // measure it so the title+size dedupe still works.
          final size = d['size'] is int && (d['size'] as int) > 0
              ? d['size'] as int
              : _fileSizeOf(path);
          restored.add(<String, dynamic>{'key': strVal(d['key']), 'title': strVal(d['title']), 'artist': strVal(d['artist']), 'kind': strVal(d['kind']), 'path': path, 'url': url, 'size': size});
        } catch (_) {}
      }
      final savedKeys = prefs.getStringList(_musicPlaylistPrefsKey) ?? const [];
      if (!mounted) return;
      setState(() {
        // Merge, never wipe: an upload made before this load finished
        // must survive it. FIX 20 (fix 16): merge by the same
        // dedupe as _upsertLibraryFile (key OR title+size), so a
        // persisted entry never duplicates a session entry for
        // the same file under a different path spelling; a URL
        // on the restored copy merges into the kept entry.
        for (final e in restored) {
          Map<String, dynamic>? match;
          for (final x in _localLibrary) {
            if (libraryEntriesMatch(x, e)) {
              match = x;
              break;
            }
          }
          if (match == null) {
            _localLibrary.add(e);
          } else if (strVal(match['url']).isEmpty &&
              strVal(e['url']).isNotEmpty) {
            match['url'] = e['url'];
          }
        }
        final allKeys = _localLibrary.map((e) => strVal(e['key'])).toSet();
        _playlistKeys.addAll(savedKeys.where(allKeys.contains));
      });
    } catch (_) {}
  }

  Map<String, dynamic> _upsertLibraryFile(String path, String name, {String? url}) {
    final key = 'file:$path';
    final size = _fileSizeOf(path);
    final candidate = <String, dynamic>{'key': key, 'title': name, 'size': size};
    for (final e in _localLibrary) {
      // FIX 20 (fix 16): key match OR title+size match — the
      // same file under a different path spelling merges into
      // the single entry (path refreshed to the spelling the
      // picker just proved exists; key kept so now-playing /
      // playlist references survive).
      if (libraryEntriesMatch(e, candidate)) {
        if (url != null) e['url'] = url;
        e['path'] = path;
        if (size > 0) e['size'] = size;
        _persistMusicLibrary();
        return e;
      }
    }
    final entry = <String, dynamic>{'key': key, 'title': name, 'artist': 'Local file', 'kind': 'file', 'path': path, 'url': url ?? '', 'size': size};
    _localLibrary.insert(0, entry);
    _persistMusicLibrary();
    return entry;
  }

  Map<String, dynamic>? _libraryEntryByKey(String key) {
    for (final e in _localLibrary) {
      if (strVal(e['key']) == key) return e;
    }
    if (key.startsWith('tone:')) {
      for (final def in _toneDefs()) {
        if ('tone:${def['name']}' == key) return _toneEntry(def);
      }
    }
    return null;
  }

  String _nowPlayingArtist() {
    final entry = _libraryEntryByKey(_nowPlayingKey);
    if (entry != null) return strVal(entry['artist'], 'Local file');
    if (_sharedSession != null) return strVal(_sharedSession!['playerName'], 'Shared music');
    return 'Local file';
  }

  // Local-only playback: NO session row, so other phones hear
  // nothing. Used when Broadcast is OFF and for streamed URLs.
  Future<void> _playLocalFile(String path, String name, {String? key}) async {
    await _stopMusic();
    await _playMusicSource(path);
    if (!mounted) return;
    setState(() {
      _musicPlaying = name;
      _musicIsFile = true;
      _musicPaused = false;
      _sharedSession = null;
      _sharedFallback = false;
      _nowPlayingKey = key ?? 'file:$path';
    });
    await _applyMusicVolume();
  }

  // FIX 20 (fix 14): background share for an ALREADY-PLAYING
  // file — reuses the fromToggle semantics (no restart, toggle
  // stays ON, speaker fallback on failure). Unawaited by design:
  // the tap already produced sound; sharing must never block it.
  // Success upgrades to a shared session and toasts; failure
  // keeps the music playing locally (the fromToggle path inside
  // _uploadAndShareFile handles the fallback + toast).
  void _sharePlayingFileInBackground(String path, String name, {String? key}) {
    unawaited(
      _uploadAndShareFile(path, name, key: key, fromToggle: true).then((ok) {
        if (ok && mounted) {
          toast(context, 'Shared to the room — every member hears this, no mic needed. Unmute and speak to duck the music like an FM RJ.');
        }
      }),
    );
  }

  // Upload + shared play. fromToggle=true means the file is ALREADY
  // playing locally (user just switched Broadcast ON): upload and
  // attach a session WITHOUT restarting playback; on failure the
  // toggle STAYS ON and the room falls back to speaker mode (the
  // status line says Speaker fallback — never a fake shared
  // session). FIX 2: the old revert-to-OFF is what made broadcast
  // "not turn on" while a track played.
  /// FIX 22 item 6 — drops a library entry whose local file is
  /// gone (same rule as the library load, which skips missing
  /// files): match by key first, else by path (URL entries never
  /// match — a shared URL has no local file to lose). Persists
  /// the trimmed library so the dead entry never comes back.
  void _dropDeadMusicEntry(String path, String? key) {
    final before = _localLibrary.length;
    _localLibrary.removeWhere((e) =>
        (key != null &&
                key.isNotEmpty &&
                SupaDb.strOf(e['key']) == key) ||
        (SupaDb.strOf(e['path']) == path &&
            SupaDb.strOf(e['url']).isEmpty));
    if (_localLibrary.length != before) {
      _persistMusicLibrary();
      if (mounted) setState(() {});
    }
  }

  Future<bool> _uploadAndShareFile(String path, String name, {String? key, bool fromToggle = false}) async {
    // SENDER-SIDE BROADCAST GATE (defense in depth; the entry
    // points above already request approval first): never upload +
    // announce a shared session without admin approval.
    if (!_canBroadcastMusic) {
      await _sendMusicRequest();
      return false;
    }
    // FIX 22 item 6: a library entry can outlive its file (the
    // user deleted the song from the phone) — check BEFORE
    // uploading so the toast names the real cause instead of a
    // generic "upload failed", and drop the dead entry. URLs are
    // not local files — only file paths are checked. The speaker
    // fallback stays untouched: fromToggle keeps playing locally
    // as it already is (status flips to speaker fallback), and a
    // fresh share has nothing to play.
    if (!path.startsWith('http') && !File(path).existsSync()) {
      _dropDeadMusicEntry(path, key);
      if (fromToggle && mounted) {
        setState(() => _sharedFallback = true);
      }
      if (mounted) toast(context, 'Ye file ab phone mein nahi hai');
      return false;
    }
    try {
      final myUid = FirebaseAuth.instance.currentUser!.uid;
      final startedAt = DateTime.now().millisecondsSinceEpoch;
      final ext = path.split('.').last.toLowerCase();
      final storagePath = '$_voiceRoomId/$myUid/${startedAt}_${_safeFileName(name)}';
      if (mounted && !fromToggle) toast(context, 'Uploading $name for the room…');
      String publicUrl;
      try {
        final bytes = await File(path).readAsBytes();
        await SupaDb.client.storage.from(_sharedBucket).uploadBinary(
              storagePath,
              bytes,
              fileOptions: FileOptions(contentType: _mimeForExt(ext), upsert: false),
              // FIX 20 (fix 14): a stalled upload must never hang
              // the share forever — 30s, then the fromToggle /
              // speaker-fallback path takes over.
            ).timeout(const Duration(seconds: 30));
        publicUrl = SupaDb.client.storage.from(_sharedBucket).getPublicUrl(storagePath);
      } on TimeoutException {
        // FIX 22 item 6: the 30 s upload timeout is the SLOW
        // NETWORK — say so (the room-music bucket is proven
        // working on A1, so "upload failed" blamed the wrong
        // thing). The speaker fallback stays exactly as before.
        if (fromToggle) {
          // FIX 2: the toggle STAYS ON — the song is already playing
          // locally, so the room still hears it through the speaker
          // fallback (the mic picks the phone's speaker up). The
          // status line shows Speaker fallback, honestly.
          if (mounted) {
            setState(() => _sharedFallback = true);
            toast(context, 'Broadcast ON via speaker — Upload slow network par time out ho gaya — dobara koshish karein.');
          }
          return false;
        }
        if (mounted) toast(context, 'Upload slow network par time out ho gaya — dobara koshish karein. Playing via speaker fallback instead (others hear through your mic).');
        await _playSpeakerFallback(path, name);
        return false;
      } catch (_) {
        if (fromToggle) {
          // FIX 2: the toggle STAYS ON — the song is already playing
          // locally, so the room still hears it through the speaker
          // fallback (the mic picks the phone's speaker up). The
          // status line shows Speaker fallback, honestly.
          if (mounted) {
            setState(() => _sharedFallback = true);
            toast(context, 'Broadcast ON via speaker — upload nahi ho saki (storage error), so others hear through your mic (unmute to share).');
          }
          return false;
        }
        if (mounted) toast(context, 'Shared upload nahi ho saki (storage error) — playing via speaker fallback instead (others hear through your mic).');
        await _playSpeakerFallback(path, name);
        return false;
      }
      final session = <String, dynamic>{
        'sessionId': '${myUid}_$startedAt',
        'playerUid': myUid,
        'playerName': '',
        'title': name,
        'url': publicUrl,
        'startedAtMs': startedAt,
        'storagePath': storagePath,
      };
      if (!fromToggle) {
        await _stopMusic();
        await _playMusicSource(path);
        if (!mounted) return false;
        setState(() {
          _sharedSession = session;
          _sharedFallback = false;
          _sharedDucked = false;
          _musicPlaying = name;
          _musicIsFile = true;
          _musicPaused = false;
          _nowPlayingKey = key ?? 'file:$path';
        });
        await _applyMusicVolume();
      } else {
        if (!mounted) return false;
        setState(() {
          _sharedSession = session;
          _sharedFallback = false;
          _sharedDucked = false;
          _nowPlayingKey = key ?? _nowPlayingKey;
        });
      }
      try {
        await _sendMusicAction('play', session: session);
      } catch (e) {
        if (mounted) {
          setState(() {
            _sharedSession = null;
            // FIX 2: fromToggle keeps the toggle ON — the already
            // playing song falls back to speaker mode instead of
            // silently switching broadcast off.
            if (fromToggle) _sharedFallback = true;
          });
          toast(context, fromToggle ? 'Broadcast ON via speaker — could not announce the session, others hear through your mic.' : 'Could not announce the session to the room — playing via speaker fallback instead.');
        }
        if (!fromToggle) await _playSpeakerFallback(path, name);
        return false;
      }
      final entry = _upsertLibraryFile(path, name, url: publicUrl);
      if (mounted) {
        setState(() => _nowPlayingKey = key ?? strVal(entry['key']));
        if (!fromToggle) toast(context, 'Shared to the room — every member hears this, no mic needed. Unmute and speak to duck the music like an FM RJ.');
      }
      return true;
    } catch (e) {
      // FIX 2: fromToggle keeps the toggle ON (speaker fallback) —
      // never revert it here; the song keeps playing locally.
      if (fromToggle && mounted) setState(() => _sharedFallback = true);
      if (mounted) toast(context, fromToggle ? 'Broadcast ON via speaker — could not share that file: $e' : 'Could not share that file: $e');
      return false;
    }
  }

  // Re-broadcast a file that already has a public URL (no re-upload).
  Future<void> _broadcastExistingFile(Map<String, dynamic> entry) async {
    if (!_canBroadcastMusic) {
      await _sendMusicRequest();
      return;
    }
    final path = strVal(entry['path']);
    final name = strVal(entry['title'], 'Shared music');
    final url = strVal(entry['url']);
    if (url.isEmpty) {
      await _uploadAndShareFile(path, name, key: strVal(entry['key']));
      return;
    }
    await _stopMusic();
    final myUid = FirebaseAuth.instance.currentUser!.uid;
    final startedAt = DateTime.now().millisecondsSinceEpoch;
    final session = <String, dynamic>{
      'sessionId': '${myUid}_$startedAt',
      'playerUid': myUid,
      'playerName': '',
      'title': name,
      'url': url,
      'startedAtMs': startedAt,
      'storagePath': '',
    };
    if (path.isNotEmpty && File(path).existsSync()) {
      await _playMusicSource(path);
    } else {
      await _playMusicSource(url);
    }
    if (!mounted) return;
    setState(() {
      _sharedSession = session;
      _sharedFallback = false;
      _sharedDucked = false;
      _musicPlaying = name;
      _musicIsFile = true;
      _musicPaused = false;
      _nowPlayingKey = strVal(entry['key']);
    });
    await _applyMusicVolume();
    try {
      await _sendMusicAction('play', session: session);
    } catch (_) {
      if (mounted) {
        setState(() => _sharedSession = null);
        toast(context, 'Could not announce the session — the song keeps playing locally only.');
      }
    }
  }

  Future<void> _playLibraryEntry(Map<String, dynamic> entry) async {
    final key = strVal(entry['key']);
    if (strVal(entry['kind']) == 'tone') {
      if (_nowPlayingKey == key && _musicPlaying != null) {
        await _stopMusic();
      } else {
        await _playToneByName(strVal(entry['title']));
      }
      return;
    }
    final path = strVal(entry['path']);
    final name = strVal(entry['title'], 'Shared music');
    if (_broadcastMusic) {
      // FIX 2: a blocked broadcast NEVER swallows the tap — the song
      // still plays locally (fall-through below) with an honest
      // toast; the toggle stays exactly as the user set it.
      if (_broadcastJoinBlocked) {
        toast(context, 'Join this tournament first to share music with the room — playing locally only for now.');
      } else if (!_canBroadcastMusic) {
        await _sendMusicRequest();
        if (mounted) toast(context, 'Music approval pending — playing locally only for now.');
      } else if (strVal(entry['url']).isNotEmpty) {
        await _broadcastExistingFile(entry);
        return;
      } else if (path.isNotEmpty && File(path).existsSync()) {
        // FIX 20 (fix 14): play LOCAL first, share in the
        // background — the old code waited for the upload (no
        // timeout, minutes on slow data) before any sound.
        await _playLocalFile(path, name, key: key);
        _sharePlayingFileInBackground(path, name, key: key);
        return;
      } else {
        toast(context, 'That file is no longer on this phone.');
        return;
      }
    }
    if (path.isNotEmpty && File(path).existsSync()) {
      await _playLocalFile(path, name, key: key);
    } else if (strVal(entry['url']).isNotEmpty) {
      await _stopMusic();
      await _playMusicSource(strVal(entry['url']));
      if (mounted) {
        setState(() {
          _musicPlaying = name;
          _musicIsFile = false;
          _musicPaused = false;
          _nowPlayingKey = key;
        });
      }
      await _applyMusicVolume();
    } else {
      if (mounted) toast(context, 'That file is no longer on this phone.');
    }
  }

  // ROUND 12 MUSIC: pick a file, add it to the library, then play it
  // per the Broadcast toggle — shared when ON, local-only when OFF.
  // FIX 2 (2026-11-22): pick FIRST, share second. The old code
  // returned BEFORE the file picker whenever Broadcast was ON
  // without tournament join/approval, so Local Upload looked dead
  // with broadcast ON. Now the file is always picked + added +
  // played; sharing is attempted after, and a blocked/failed share
  // only affects sharing (local play + honest toast), never the
  // upload or the playback.
  Future<void> _pickAndShareFile() async {
    try {
      final picked = await _pickAudioFile();
      if (picked == null) return;
      _upsertLibraryFile(picked.path, picked.name);
      if (!_broadcastMusic) {
        await _playLocalFile(picked.path, picked.name);
        return;
      }
      if (_broadcastJoinBlocked) {
        if (mounted) toast(context, 'Join this tournament first to share music with the room — playing locally only for now.');
        await _playLocalFile(picked.path, picked.name);
        return;
      }
      if (!_canBroadcastMusic) {
        await _sendMusicRequest();
        if (mounted) toast(context, 'Music approval pending — playing locally only for now.');
        await _playLocalFile(picked.path, picked.name);
        return;
      }
      // FIX 20 (fix 14): play LOCAL first, share in the
      // background (same as _playLibraryEntry above).
      await _playLocalFile(picked.path, picked.name);
      _sharePlayingFileInBackground(picked.path, picked.name);
    } catch (e) {
      if (mounted) toast(context, 'Could not share that file: $e');
    }
  }

  // FIX 24 — RADIO MUSIC MIXER (2026-11-23 user order): the host's
  // music mixed directly into the live mic stream (native
  // MusicMixProcessor on WebRTC's capturePostProcessing hook).
  // GO LIVE registers the mixer; END LIVE unregisters it. The
  // upload-broadcast path (_setBroadcast) stays as-is — the mixer
  // is the live path when GO LIVE is on, and if the mixer fails
  // to register the show falls back to the upload path with an
  // honest toast (never silent failure, never fake success).
  //
  // Mute is MIC-GAIN-ZERO while live: both engines hold the mic
  // track enabled (holdMicTrackWhileMuted) and the mixer applies
  // mic gain 0 — so the music keeps flowing when the mic is off.
  // On END LIVE a held mute is restored to a REAL disable (the
  // track must not stay live while the UI says muted).
  //
  // Krisp force-switch: Krisp's position vs capturePostProcessing
  // is undocumented — if it runs after the mix it may suppress the
  // music as noise. While the mixer is live the mic processor is
  // forced to RNNoise (one attempt, fail-open: if the switch
  // fails, Krisp stays — there is no Off fallback); the previous
  // kind is restored on END LIVE.
  //
  // FIX 24 defect 1 (2026-11-23 checker): GO LIVE arms ONE
  // broadcast path — the mixer first; the upload path ONLY when
  // the mixer fails to register. The upload is the FALLBACK, not
  // a parallel broadcast: arming both played the song twice,
  // unsynchronised (listeners heard the local download AND the
  // mix in the mic track). Returns true when the mixer is live.
  Future<void> _goLiveBroadcast() async {
    final mixerOk = await _registerRadioMixer();
    if (!mixerOk) await _setBroadcast(true);
  }

  Future<bool> _registerRadioMixer() async {
    if (_radioMixerLive) return true;
    // Hold the mic track on both engines BEFORE enabling it: a
    // mic muted before GO LIVE has a disabled track, and a
    // disabled track carries no frames — the mixer would mix
    // music into nothing.
    _lkRoom.holdMicTrackWhileMuted = true;
    _room.holdMicTrackWhileMuted = true;
    try {
      if (_lkRoom.joined) await _lkRoom.ensureMicTrackEnabled();
    } catch (_) {}
    _room.ensureMicTrackEnabled();
    final trackId =
        _lkRoom.joined ? _lkRoom.localMicTrackId : _room.localMicTrackId;
    final ok = await _radioMixer.register(trackId: trackId);
    if (!ok) {
      // Honest fallback: the caller (_goLiveBroadcast) arms the
      // upload path now — the show goes on through it. The hold
      // is released (a held track with no mixer would leak
      // full-volume mic while the UI says muted).
      _lkRoom.holdMicTrackWhileMuted = false;
      _room.holdMicTrackWhileMuted = false;
      if (mounted) {
        toast(
          context,
          'Radio mix nahi lag saka — upload se broadcast ho raha hai.',
        );
      }
      return false;
    }
    _radioMixerLive = true;
    // Krisp force-switch (see above): remember the current kind,
    // switch to RNNoise while live. A failed switch leaves the
    // current processor in place (fail-open, never blocks live).
    final currentKind = rjKindOfSource(_lkRoom.micPipeline.source);
    if (currentKind == MicProcessorKind.krisp) {
      _rjPreBroadcastKind = currentKind;
      try {
        await _rjSwitchMicProcessor(MicProcessorKind.rnnoise);
      } catch (_) {}
    }
    _pushMixerGains();
    return true;
  }

  Future<void> _unregisterRadioMixer({bool restoreMute = true}) async {
    final wasLive = _radioMixerLive;
    _radioMixerLive = false;
    _lkRoom.holdMicTrackWhileMuted = false;
    _room.holdMicTrackWhileMuted = false;
    try {
      await _radioMixer.unregister();
    } catch (_) {}
    // Krisp restore: back to the processor GO LIVE switched away
    // from (fail-open — a failed restore keeps RNNoise).
    final preKind = _rjPreBroadcastKind;
    _rjPreBroadcastKind = null;
    if (wasLive && preKind != null) {
      try {
        await _rjSwitchMicProcessor(preKind);
      } catch (_) {}
    }
    // Restore a held mute to a REAL disable: while live the mic
    // was muted with the track held enabled (gain 0 in the mixer);
    // with the mixer gone the track would publish full-volume mic
    // while the UI says muted. Re-applying setMuted(true) with the
    // hold off disables the track properly. Skipped on room exit
    // (dispose passes false — leave() disposes the stream anyway).
    if (wasLive && restoreMute) {
      try {
        if (_lkRoom.muted && _lkRoom.micTrackHeld) {
          await _lkRoom.setMuted(true);
        }
        if (_room.muted && _room.micTrackHeld) {
          await _room.setMuted(true);
        }
      } catch (_) {}
    }
  }

  /// FIX 24 — pushes the current mix gains to the native mixer
  /// (one channel call). No-op when the mixer is not live. Called
  /// after every fader move, mic toggle, link toggle, call-in
  /// pick, and GO LIVE — listeners hear the host's mix live.
  void _pushMixerGains() {
    if (!_radioMixerLive) return;
    final gains = radioMixGains(
      micOn: _isMyMicOn,
      micFader: _micFaderLevel,
      musicBase: _musicBaseVolume,
      linkOn: _rjMicLinkOn,
      guestSpeaking: _anyCallInGuestSpeaking(),
    );
    unawaited(_radioMixer.setGains(music: gains.music, mic: gains.mic));
  }

  /// FIX 24 — true while the SELECTED call-in guest is speaking
  /// (their voice ducks the mix music to the RJ bed). LiveKit has
  /// a real speaking signal; the mesh has none, so an unmuted
  /// guest peer is the proxy there (same rule as _anyMicUnmuted).
  /// False when no guest is selected.
  bool _anyCallInGuestSpeaking() {
    final guest = _rjCallInGuestUid;
    if (guest == null) return false;
    final lk = _lkRoom.participants[guest];
    if (lk != null) return lk.speaking;
    final mesh = _room.peers[guest];
    if (mesh != null) return mesh['muted'] != true;
    return false;
  }

  /// FIX 24 — the 6 call-in seats for the RJ panel picker (same
  /// assignment the stage renders; approved occupants only).
  /// On a LiveKit visit the mesh peer map is empty, so the list is
  /// empty too — the same source the seat grid renders from, so
  /// the picker never shows a seat the stage does not.
  List<RjCallInSeat> _rjCallInSeats() => callInSeatAssignments(
        peers: _room.peers,
        usable: _usableMicCount(),
      );

  // ROUND 12 MUSIC: the Broadcast toggle, honestly wired. OFF while
  // sharing as player ends the session for everyone (stop row) but
  // keeps the song playing locally; OFF while listening stops only
  // this phone (a listener never broadcasts). ON while a local file
  // plays uploads + shares it; tones/streamed songs cannot be
  // broadcast, so the toggle reverts with an explanation.
  Future<void> _setBroadcast(bool on) async {
    if (on == _broadcastMusic) return;
    if (!on) {
      // FIX 2 (verifier nit): leaving broadcast clears the speaker-
      // fallback flag too, so the status line stops saying
      // "Speaker fallback" for a now local-only song.
      _sharedFallback = false;
      final wasPlayer = _isSharedPlayer;
      final session = _sharedSession;
      if (wasPlayer && session != null) {
        try {
          await _sendMusicAction('stop', session: session);
        } catch (_) {}
        if (mounted) {
          setState(() {
            _broadcastMusic = false;
            _sharedSession = null;
            _sharedDucked = false;
          });
          toast(context, 'Broadcast off — the song now plays only on your phone.');
        }
        return;
      }
      if (session != null) {
        await _stopMusic();
        if (mounted) setState(() => _broadcastMusic = false);
        return;
      }
      if (mounted) setState(() => _broadcastMusic = false);
      return;
    }
    if (!_canBroadcastMusic) {
      await _sendMusicRequest();
      return;
    }
    if (mounted) setState(() => _broadcastMusic = true);
    if (_musicIsFile && _sharedSession == null && _musicPlaying != null) {
      final entry = _libraryEntryByKey(_nowPlayingKey);
      final path = entry != null ? strVal(entry['path']) : '';
      if (entry != null && path.isNotEmpty && File(path).existsSync()) {
        await _uploadAndShareFile(path, strVal(entry['title'], _musicPlaying!), key: strVal(entry['key']), fromToggle: true);
      } else {
        if (mounted) {
          setState(() => _broadcastMusic = false);
          toast(context, 'Built-in tones and streamed songs cannot be broadcast — pick a file from Local Upload to broadcast it.');
        }
      }
    }
  }

  Future<void> _playPrevNext(int dir) async {
    if (_nowPlayingKey.startsWith('tone:')) {
      final defs = _toneDefs();
      final idx = defs.indexWhere((t) => 'tone:${t['name']}' == _nowPlayingKey);
      if (idx < 0) return;
      final next = defs[(idx + dir) % defs.length];
      await _playToneByName(strVal(next['name']));
      return;
    }
    final idx = _localLibrary.indexWhere((e) => strVal(e['key']) == _nowPlayingKey);
    if (idx < 0) {
      toast(context, 'No playlist context for this song — pick a song from the library.');
      return;
    }
    await _playLibraryEntry(_localLibrary[(idx + dir) % _localLibrary.length]);
  }

  // Speaker fallback player (upload failed): local file, speaker
  // route, honest fallback flag for the banner/panel labels.
  Future<void> _playSpeakerFallback(String path, String name) async {
    await _playMusicSource(path);
    // FIX 20 defect fix: fallback is LOCAL playback — clear the
    // session first so _applyMusicVolume computes the local
    // target, then route the volume through it so mic-fader
    // ducking applies here too (it used to set the raw base
    // volume, bypassing ducking entirely).
    _sharedSession = null;
    _sharedFallback = true;
    await _applyMusicVolume();
    if (mounted) {
      setState(() {
        _musicPlaying = name;
        _musicIsFile = true;
        _musicPaused = false;
        _nowPlayingKey = 'file:$path';
      });
    }
  }

  // Listener flow: play the shared URL, seeking to roughly the same
  // point (elapsed since startedAt, modulo the track length, since
  // playback loops). If the duration never arrives, playback simply
  // starts from the beginning — still the shared file, still synced
  // in content, just not in position; that fallback is stated here,
  // not hidden behind a "synced" claim.
  Future<void> _startListeningSession(Map<String, dynamic> session) async {
    final url = strVal(session['url']);
    final startedAt = session['startedAtMs'] is num ? (session['startedAtMs'] as num).toInt() : 0;
    if (url.isEmpty) return;
    final dur = await _playMusicSource(url);
    await _musicPlayer?.setVolume(_musicBaseVolume);
    if (!mounted) return;
    setState(() {
      _sharedSession = session;
      _sharedFallback = false;
      _sharedDucked = false;
      _musicPlaying = strVal(session['title'], 'Shared music');
      _musicIsFile = false;
      _musicPaused = false;
      _nowPlayingKey = 'shared:${strVal(session['sessionId'])}';
    });
    // The duration comes from load() itself (see _playMusicSource)
    // — no 8 s wait for a duration event any more.
    if (startedAt > 0 && dur.inMilliseconds > 0) {
      try {
        final elapsed = DateTime.now().millisecondsSinceEpoch - startedAt;
        await _musicPlayer!.seek(Duration(milliseconds: elapsed % dur.inMilliseconds));
      } catch (_) {}
    }
    _startSharedDuckPoll();
    await _applySharedDucking();
  }

  // Handle every MUSIC:: row in a chat snapshot (live stream +
  // catch-up). Dedupe by row id: rebuilds re-deliver the same
  // snapshot, and replaying a play row must never restart playback.
  // Own rows are skipped — the player already plays locally.
  // v2016 FIX 9: is this music player live RIGHT NOW? True if the
  // player is on voice (either engine) or online in this room per
  // presence (last_seen within 2 min). Presence matters because a
  // non-voice listener's peer maps are empty — without it, no
  // listener would ever hear shared music. A player who left is
  // stale within 2 minutes on every source, so a dead session
  // stops qualifying quickly.
  bool _musicPlayerLiveNow(String playerUid) {
    if (playerUid.isEmpty) return false;
    if (_room.peers.containsKey(playerUid)) return true;
    if (_lkRoom.participants.containsKey(playerUid)) return true;
    final pres = _presenceMap[playerUid];
    if (pres != null && SupaDb.presenceIsOnline(pres)) return true;
    return false;
  }

  Future<void> _handleMusicRows(List<Map<String, dynamic>> msgs) async {
    final myUid = FirebaseAuth.instance.currentUser?.uid ?? '';
    for (final m in msgs) {
      // MUSIC-STREAM APPROVAL ROWS (hidden, see chat filter below):
      // the admin's approve/revoke for a streamer. Processed in
      // order (catch-up replays oldest-first), so an approval row
      // written before a play row is always seen first. A revoke
      // stops a session this phone is currently listening to.
      if (_isMusicApprovalRow(m)) {
        final id = strVal(m['id']);
        if (id.isEmpty || _seenMusicRowIds.contains(id)) continue;
        try {
          final decoded = jsonDecode(strVal(m['message']).substring(_musicApprovalPrefix.length));
          if (decoded is Map<String, dynamic>) {
            final targetUid = strVal(decoded['uid']);
            final act = strVal(decoded['action']);
            if (targetUid.isNotEmpty) {
              _seenMusicRowIds.add(id);
              if (act == 'approved') {
                _musicApprovedStreamers.add(targetUid);
              } else if (act == 'revoked') {
                _musicApprovedStreamers.remove(targetUid);
                if (_sharedSession != null && strVal(_sharedSession!['playerUid']) == targetUid) {
                  _stoppedMusicSessions.add(strVal(_sharedSession!['sessionId']));
                  await _musicPlayer?.stop();
                  if (mounted) {
                    setState(() {
                      _musicPlaying = null;
                      _musicPaused = false;
                      _sharedSession = null;
                      _sharedDucked = false;
                    });
                  }
                  _reapplyVoiceRoute();
                }
              }
            }
          }
        } catch (_) {}
        continue;
      }
      if (!_isMusicRow(m)) continue;
      final id = strVal(m['id']);
      if (id.isEmpty || _seenMusicRowIds.contains(id)) continue;
      Map<String, dynamic>? data;
      try {
        final decoded = jsonDecode(strVal(m['message']).substring(_musicPrefix.length));
        if (decoded is Map<String, dynamic>) data = decoded;
      } catch (_) {
        continue;
      }
      if (data == null) continue;
      final action = strVal(data['action']);
      final sessionId = strVal(data['session']);
      final playerUid = strVal(data['player']);
      if (playerUid.isEmpty || sessionId.isEmpty) continue;
      if (playerUid == myUid) continue;
      // LISTENER-SIDE BROADCAST ENFORCEMENT (2026-10-30): a play
      // row is honoured ONLY from the designated admin or from a
      // streamer the admin approved (approval row seen in this
      // chat history). Unapproved strangers' sessions never play
      // here, whatever the sender's phone claims. If the admin UID
      // is still loading, do NOT mark the row seen — re-evaluate
      // it on a later snapshot instead of wrongly dropping an
      // admin stream.
      if (action == 'play') {
        final isAdminStream = _adminUid.isNotEmpty && playerUid == _adminUid;
        if (!isAdminStream && !_musicApprovedStreamers.contains(playerUid)) {
          if (_adminUid.isEmpty) continue;
          _seenMusicRowIds.add(id);
          continue;
        }
        // A session this phone stopped never restarts from a replay.
        if (_stoppedMusicSessions.contains(sessionId)) {
          _seenMusicRowIds.add(id);
          continue;
        }
        if (_sharedSession != null && strVal(_sharedSession!['sessionId']) == sessionId && _musicPlaying != null) {
          _seenMusicRowIds.add(id);
          continue;
        }
        // v2016 FIX 9 (user order 2026-11-22, "joiner ko default
        // music NA sunai de"): a 'play' row older than THIS room
        // entry is HISTORY — it is honoured ONLY while its player
        // is live right now (on voice, either engine, or online
        // in this room per presence). A long looped session with a
        // live host still plays; a dead session never auto-plays
        // for a joiner. A history row with no live player is
        // skipped WITHOUT marking it seen, so a later snapshot —
        // after peers/presence have loaded, or if the host returns
        // — re-evaluates it. Rows written after entry (a session
        // that just started) always play, as do rows with no
        // timestamp (treated as fresh, as before). This REPLACES
        // the old 10-minute age guard: age alone could not tell a
        // live host from a dead one, and the old guard was mesh-only
        // (on a LiveKit visit it skipped every old row).
        final rowMs = m['timestamp'] is num ? (m['timestamp'] as num).toInt() : 0;
        final isHistoryRow = rowMs > 0 && rowMs < _roomEnteredAtMs;
        if (isHistoryRow && !_musicPlayerLiveNow(playerUid)) continue;
        _seenMusicRowIds.add(id);
        final session = <String, dynamic>{
          'sessionId': sessionId,
          'playerUid': playerUid,
          'playerName': strVal(data['playerName']),
          'title': strVal(data['title'], 'Shared music'),
          'url': strVal(data['url']),
          'startedAtMs': data['startedAt'] is num ? (data['startedAt'] as num).toInt() : 0,
          'storagePath': '',
        };
        await _startListeningSession(session);
      } else if (action == 'pause') {
        _seenMusicRowIds.add(id);
        if (_sharedSession == null || strVal(_sharedSession!['sessionId']) != sessionId) continue;
        await _musicPlayer?.pause();
        if (mounted) setState(() => _musicPaused = true);
        _reapplyVoiceRoute();
      } else if (action == 'resume') {
        _seenMusicRowIds.add(id);
        if (_sharedSession == null || strVal(_sharedSession!['sessionId']) != sessionId) continue;
        await _musicPlayer?.resume();
        if (mounted) setState(() => _musicPaused = false);
      } else if (action == 'stop') {
        _seenMusicRowIds.add(id);
        if (_sharedSession == null || strVal(_sharedSession!['sessionId']) != sessionId) continue;
        _stoppedMusicSessions.add(sessionId);
        await _musicPlayer?.stop();
        await _musicPlayer?.setVolume(_musicBaseVolume);
        _stopSharedDuckPoll();
        if (mounted) {
          setState(() {
            _musicPlaying = null;
            _musicIsFile = false;
            _musicPaused = false;
            _sharedSession = null;
            _sharedDucked = false;
            _nowPlayingKey = '';
          });
        }
        _reapplyVoiceRoute();
      }
    }
  }

  // Late-joiner catch-up: newest-first direct query (the chat
  // stream's oldest-200 window can miss a session in a busy room).
  // Rows are replayed oldest-first so play -> pause -> stop ends in
  // the correct final state; dedupe keeps the live stream from
  // re-applying them.
  Future<void> _catchUpSharedMusic() async {
    try {
      dynamic q = SupaDb.client.from('chat_messages').select().eq('scope', widget.scope);
      // v2016 FIX 11: team rows live in squad_id='team_<id>' too
      // (same column as squad rows) — the getters cover all scopes.
      q = q.eq(_chatScopeCol, _chatScopeId);
      final rows = await q.order('created_at', ascending: false).limit(30);
      final list = (rows as List).map((r) => SupaDb.normChat(Map<String, dynamic>.from(r as Map))).toList().reversed.toList();
      if (mounted) await _handleMusicRows(list);
    } catch (_) {}
  }

  // RJ DUCKING trigger (ANY-SPEAKER, 2026-11-22 user order): ANY
  // unmuted mic in the room ducks the music — the sharing player,
  // any other mic seat, on either engine. The old trigger read
  // ONLY the player's mic, so a muted player + a speaking seat
  // 2-6 never ducked (the user repro). Sources: self on both
  // engines (live joined/muted flags), mesh peers, LiveKit
  // participants (muted flag per participant), and the 5s poll
  // cache for listeners not on voice. Unknown / nobody on voice
  // counts as muted — no duck — because there is no voice to duck
  // under; the moment anyone unmutes, a peer row exists and
  // ducking engages (mesh/LiveKit notify, or the poll within ~5s).
  bool _anyMicUnmuted() {
    if (_sharedSession == null) return false;
    final myUid = FirebaseAuth.instance.currentUser?.uid ?? '';
    return PresenceService.anyMicUnmuted(
      selfUid: myUid,
      selfMeshJoined: _room.joined,
      selfMeshMuted: _room.muted,
      selfLiveKitJoined: _lkRoom.joined,
      selfLiveKitMuted: _lkRoom.muted,
      meshPeers: _room.peers,
      liveKitPeerMuted: {
        for (final e in _lkRoom.participants.entries) e.key: e.value.muted,
      },
      pollMuted: _sharedPeerMuted,
    );
  }

  // Apply ACTIVITY ducking to the SHARED player only (tones and the
  // speaker fallback are never activity-ducked — the fallback NEEDS
  // full volume for mic pickup). The mic-FADER factor is separate
  // (FIX 24: 1.0 at the call site — the inverse link is the single
  // mechanism). Ducked = 5% volume (RJ bed), full = 100%. No mic-gain change: WebRTC echo-cancellation stays ON and mic gain is untouched — the voice gets loud by removing the loud music echo that AEC/AGC was suppressing, not by boosting the mic.
  /// FIX 22 item 10 — the mic-toggle volume re-apply for LOCAL /
  /// FALLBACK mode: _applySharedDucking early-returns without a
  /// shared session, so a mic toggle never re-applied the volume
  /// there — the mic-fader factor (fix20 item 11) sat computed
  /// but unapplied and the music stayed loud while the host
  /// spoke. With a shared session the ducking call already
  /// re-applies; without one, this does. The re-apply is safe on
  /// every notify: _applyMusicVolume early-returns when the
  /// target has not moved (and no longer cancels an in-flight
  /// fade on a no-change call).
  void _reapplyMusicVolumeForMicToggle() {
    if (_sharedSession == null) unawaited(_applyMusicVolume());
    // FIX 24: a mic toggle also re-pushes the mixer gains (mic
    // gain 0 <-> fader) — listeners hear the host's mix change
    // the moment the mic flips. No-op when the mixer is not live.
    _pushMixerGains();
  }

  Future<void> _applySharedDucking() async {
    if (_sharedSession == null || _musicPlayer == null || _musicPlaying == null) return;
    final duck = _anyMicUnmuted();
    if (duck == _sharedDucked) return;
    _sharedDucked = duck;
    await _applyMusicVolume();
    if (mounted) setState(() {});
  }

  void _startSharedDuckPoll() {
    if (_isSharedPlayer) return; // player ducking comes from _room
    _sharedDuckPoll?.cancel();
    _sharedDuckPoll = Timer.periodic(const Duration(seconds: 5), (_) async {
      if (!mounted || _sharedSession == null) return;
      try {
        final peers = await SupaDb.getVoicePeers(_voiceRoomId);
        // ROUND 10: same 2-minute freshness rule as the voice roster
        // — a ghost speaker row must not keep the music ducked after
        // that speaker has left. Stale rows are dropped by the
        // filter, so _anyMicUnmuted() falls back to "muted" (full
        // volume) for them.
        final nowMs = DateTime.now().millisecondsSinceEpoch;
        _sharedPeerMuted = PresenceService.freshPeerMuted(peers, nowMs: nowMs);
        await _applySharedDucking();
      } catch (_) {}
    });
  }

  void _stopSharedDuckPoll() {
    _sharedDuckPoll?.cancel();
    _sharedDuckPoll = null;
  }

  // Shared-session status line for the banner + panel.
  String _sharedMusicNote() {
    if (_sharedSession == null) return '';
    final playerName = strVal(_sharedSession!['playerName']);
    final who = _isSharedPlayer ? 'You are sharing' : (playerName.isNotEmpty ? '$playerName is sharing' : 'Shared music');
    final duck = _sharedDucked
        ? 'Someone on mic — music ducked to 5% — RJ bed (RJ mode)'
        : 'All mics muted — music at full volume';
    return '$who • $duck';
  }


  // ROUND 12 MUSIC UI (user order 08:24 PKT, "aese bna music wala"):
  // MUSIC LIBRARY panel — tabs Local Music / My Playlist, search
  // field, "All: N" count, per-song Edit (files only; tones are
  // fixed built-ins), vinyl/disc icon per card, bookmark to add to
  // My Playlist, and a prominent Local Upload button at the bottom.
  // Library + playlist are SESSION-ONLY (this phone, this visit).
  void _showMusicPanel() {
    _librarySearch = '';
    _librarySearchCtrl.clear();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: kCardPurpleMid,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22)), side: const BorderSide(color: kCardPurpleBorder, width: 1.5)),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (sheetCtx, sheetSetState) {
            void refresh() {
              if (mounted) setState(() {});
              sheetSetState(() {});
            }

            // ARENA HUB #10 AUDIO (Group 9 music library): the sheet
            // is MusicLibraryPanel now — the old inline tab/button/
            // song-card builders are gone (MUSIC_LIBRARY_INTEGRATION.md
            // §3 maps every prop/callback to the real state below).
            // Status line for the playing song (same text the old
            // sheet showed on its now-playing row).
            String statusLine() => _sharedSession != null
                ? 'Shared • ${_sharedDucked ? 'ducked to 5% — RJ bed' : 'full volume'}'
                : (_sharedFallback ? 'Speaker fallback' : 'Local only');

            LibrarySong toSong(Map<String, dynamic> e) {
              final key = strVal(e['key']);
              final isPlaying = _nowPlayingKey == key && _musicPlaying != null;
              return LibrarySong(
                key: key,
                title: strVal(e['title']),
                artist: strVal(e['artist']),
                // Only the playing track has a known duration
                // (_musicDuration, from the player); the rest hide
                // the badge (no per-song duration is stored).
                duration: isPlaying && _musicDuration != Duration.zero ? _musicDuration : null,
                isTone: strVal(e['kind']) == 'tone',
                isPlaying: isPlaying,
                isPaused: isPlaying && _musicPaused,
                inPlaylist: _playlistKeys.contains(key),
                statusLine: isPlaying ? statusLine() : null,
              );
            }

            final allEntries = <Map<String, dynamic>>[..._localLibrary];
            var shown = _libraryTab == 1 ? allEntries.where((e) => _playlistKeys.contains(strVal(e['key']))).toList() : allEntries;
            final q = _librarySearch.trim().toLowerCase();
            if (q.isNotEmpty) {
              shown = shown.where((e) => strVal(e['title']).toLowerCase().contains(q) || strVal(e['artist']).toLowerCase().contains(q)).toList();
            }
            final LibrarySong? nowPlaying = _musicPlaying == null
                ? null
                : LibrarySong(
                    key: _nowPlayingKey,
                    title: _musicPlaying!,
                    artist: _nowPlayingArtist(),
                    duration: _musicDuration != Duration.zero ? _musicDuration : null,
                    isTone: _nowPlayingKey.startsWith('tone:'),
                    isPlaying: true,
                    isPaused: _musicPaused,
                    inPlaylist: _playlistKeys.contains(_nowPlayingKey),
                    statusLine: statusLine(),
                  );
            return SizedBox(
              height: MediaQuery.of(sheetCtx).size.height * 0.85,
              child: MusicLibraryPanel(
                songs: shown.map(toSong).toList(),
                nowPlaying: nowPlaying,
                nowPlayingPaused: _musicPaused,
                // FIX 24 defect 1: live = upload broadcast OR
                // mixer live — either path means ON AIR.
                broadcastOn: _broadcastMusic || _radioMixerLive,
                selectedTab: _libraryTab,
                searchQuery: _librarySearch,
                // FIX 22 item 21: NO broadcast toggle here anymore
                // — hosting is GO LIVE only; broadcastOn is
                // display-only now (the card shows the live state).
                onTabChanged: (i) {
                  _libraryTab = i;
                  refresh();
                },
                onSearchChanged: (v) {
                  _librarySearch = v;
                  refresh();
                },
                onPlaySong: (key) async {
                  final entry = _libraryEntryByKey(key);
                  if (entry != null) {
                    await _playLibraryEntry(entry);
                    refresh();
                  }
                },
                onPauseResume: () async {
                  await _pauseResumeMusic();
                  refresh();
                },
                onStop: () async {
                  await _stopMusic();
                  refresh();
                },
                onOpenPlayer: () async {
                  // FIX 2: await the library sheet's exit before
                  // pushing the console — pushing synchronously
                  // after pop() raced the exit on device and the
                  // console never appeared.
                  final popped = ModalRoute.of(ctx)?.popped;
                  Navigator.pop(ctx);
                  if (popped != null) await popped;
                  if (!mounted) return;
                  // FIX 22 item 21: the player lives inside the
                  // console now — open it focused on the player.
                  unawaited(_showRjVoiceConsole(initialSection: 'player'));
                },
                onToggleBookmark: (key) {
                  if (_playlistKeys.contains(key)) {
                    _playlistKeys.remove(key);
                  } else {
                    _playlistKeys.add(key);
                  }
                  unawaited(_persistMusicLibrary());
                  refresh();
                },
                onEditSong: (key) {
                  final entry = _libraryEntryByKey(key);
                  if (entry != null) unawaited(_editLibraryEntry(entry, refresh));
                },
                onUpload: () async {
                  await _pickAndShareFile();
                  refresh();
                },
                // FIX 22 item 22: NO onSettings — the player's
                // hosting dialog is removed (GO LIVE owns
                // hosting now); the library settings button
                // opened the same dialog, so it goes too.
                // FIX 20 (fix 15): RJ Panel button in the Music
                // header — same host gate as fix 7b; closes the
                // Music sheet first (awaiting its exit, like
                // onOpenPlayer above) then opens the console.
                rjVisible: _isAdminForBroadcast ||
                    _isTeamCaptainForBroadcast ||
                    _isCommunityOrganizerForBroadcast,
                onRjPanel: () async {
                  final popped = ModalRoute.of(ctx)?.popped;
                  Navigator.pop(ctx);
                  if (popped != null) await popped;
                  if (!mounted) return;
                  _showRjVoiceConsole();
                },
                onClose: () => Navigator.pop(ctx),
              ),
            );
          },
        );
      },
    );
  }

  // Edit Song (library files only): renames the DISPLAY title/artist
  // in the session library (and the now-playing label). It does not
  // rewrite the audio file's own metadata.
  Future<void> _editLibraryEntry(Map<String, dynamic> e, void Function() refresh) async {
    final tCtrl = TextEditingController(text: strVal(e['title']));
    final aCtrl = TextEditingController(text: strVal(e['artist']));
    await showDialog<void>(
      context: context,
      builder: (dctx) => AlertDialog(
        backgroundColor: kCardPurpleMid,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22), side: const BorderSide(color: kCardPurpleBorder, width: 1.5)),
        title: Text('Edit Song', style: TextStyle(color: kGold, fontWeight: FontWeight.bold)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // FIX 23 item 29: card look via CardFieldShell.
            CardFieldShell(child: TextField(controller: tCtrl, style: TextStyle(color: kText), decoration: InputDecoration(labelText: 'Title', labelStyle: TextStyle(color: kMuted), border: const OutlineInputBorder(borderSide: BorderSide.none), contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12)))),
            const SizedBox(height: 10),
            CardFieldShell(child: TextField(controller: aCtrl, style: TextStyle(color: kText), decoration: InputDecoration(labelText: 'Artist', labelStyle: TextStyle(color: kMuted), border: const OutlineInputBorder(borderSide: BorderSide.none), contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12)))),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dctx), child: Text('Cancel', style: TextStyle(color: kMuted))),
          TextButton(
            onPressed: () {
              final t = tCtrl.text.trim();
              final a = aCtrl.text.trim();
              if (t.isNotEmpty) e['title'] = t;
              if (a.isNotEmpty) e['artist'] = a;
              if (_nowPlayingKey == strVal(e['key']) && t.isNotEmpty) _musicPlaying = t;
              _persistMusicLibrary();
              Navigator.pop(dctx);
              refresh();
            },
            child: Text('Save', style: TextStyle(color: kGold, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
    tCtrl.dispose();
    aCtrl.dispose();
  }

  // ROUND 12 MUSIC PLAYER: shown over the room when a song plays
  // (auto-opened for the person who starts a song; listeners open it
  // from the Music panel's Now-playing card). Title at top, progress
  // bar with elapsed / total, repeat / previous / large highlighted
  // pause-play / next / playlist controls, volume slider with
  // speaker icons, settings + power (stop) icons. Seeking moves
  // only this phone — shared listeners keep their own position.
  // ARENA HUB #10 AUDIO (Group 2 swap): the music player's OWN
  // AudioDsp instance — the private engine the MusicDspPlayer pump
  // calls process() on. Null when the player is absent or its DSP
  // is not initialized (fail-open: the _fx handlers mirror state
  // and skip the engine call). Mirrors _rjLiveDsp() on the voice
  // side. NEVER the voice-chain instance.
  AudioDsp? _musicDsp() {
    final player = _musicPlayer;
    if (player == null) return null;
    final dsp = player.dsp;
    return dsp.isInitialized ? dsp : null;
  }

  /// FIX 22 item 21: the music player section, MERGED into the
  /// RJ console — the standalone player sheet (_showMusicPlayer)
  /// is retired. The section renders the full MusicPlayerPanel
  /// (transport, library button, mic stepper, volume, FX) below
  /// the effects panel; the sidebar Music entry scrolls to it
  /// via [_rjPlayerSectionKey]. onPlaylist pops the CONSOLE
  /// sheet, then opens the library (same awaited-exit pattern);
  /// onStop stops the music WITHOUT popping (the console stays
  /// open). No onSettings — item 22 removed the player's
  /// hosting dialog (GO LIVE owns hosting now).
  Widget _buildConsoleMusicSection(
    BuildContext sheetCtx,
    void Function() refresh,
  ) {
    if (_musicPlayer == null) {
      // _showRjVoiceConsole ensures the player before opening,
      // so this is unreachable in practice — a loading row
      // instead of a crash if it ever happens.
      return Container(
        key: _rjPlayerSectionKey,
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Row(
          children: [
            SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: kGold)),
            const SizedBox(width: 8),
            Text('Music player load ho raha hai…', style: TextStyle(color: kMuted, fontSize: 12)),
          ],
        ),
      );
    }
    final title = _musicPlaying ?? 'No song playing';
    final status = _musicPlaying == null
        ? 'Pick a song from the Library to start playing.'
        : _sharedSession != null
            ? _sharedMusicNote()
            : (_sharedFallback
                ? 'Speaker fallback — others hear through your mic only.'
                : 'Local only — only you hear this.');
    return Container(
      key: _rjPlayerSectionKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 16),
          Text('MUSIC PLAYER', style: TextStyle(color: kGold, fontWeight: FontWeight.w900, fontSize: 13)),
          const SizedBox(height: 8),
          StreamBuilder<Duration>(
            stream: _musicPlayer!.positionStream,
            initialData: Duration.zero,
            builder: (c, posSnap) {
              final pos = posSnap.data ?? Duration.zero;
              return StreamBuilder<Duration>(
                stream: _musicPlayer!.durationStream,
                initialData: _musicDuration,
                builder: (c2, durSnap) {
                  final dur = durSnap.data ?? Duration.zero;
                  return MusicPlayerPanel(
                    title: title,
                    artist: _musicPlaying == null ? '' : _nowPlayingArtist(),
                    statusLine: status,
                    // Ducked = the same condition _applyMusicVolume
                    // uses (shared session + player mic unmuted).
                    isDucked: _sharedSession != null && _sharedDucked,
                    position: pos,
                    duration: dur,
                    onSeek: (d) async {
                      await _musicPlayer!.seek(d);
                    },
                    isPlaying: _musicPlaying != null && !_musicPaused,
                    isRepeat: _musicRepeat,
                    onPlayPause: () async {
                      await _pauseResumeMusic();
                      refresh();
                    },
                    onRepeat: () async {
                      // Loop is mount-side (completedStream in
                      // _ensureMusicPlayer) — the toggle takes
                      // effect at the next natural completion.
                      _musicRepeat = !_musicRepeat;
                      refresh();
                    },
                    onPrevious: () async {
                      await _playPrevNext(-1);
                      refresh();
                    },
                    onNext: () async {
                      await _playPrevNext(1);
                      refresh();
                    },
                    onPlaylist: () async {
                      // FIX 2: same awaited-exit transition as
                      // onOpenPlayer (see _showMusicPanel) — the
                      // player sheet must fully exit before the
                      // library sheet is pushed.
                      final popped = ModalRoute.of(sheetCtx)?.popped;
                      Navigator.pop(sheetCtx);
                      if (popped != null) await popped;
                      if (!mounted) return;
                      _showMusicPanel();
                    },
                    // FIX 22 item 21: Stop halts the music but
                    // does NOT pop the console (the standalone
                    // player's pop died with the merge).
                    onStop: () async {
                      await _stopMusic();
                      refresh();
                    },
                    volume: _musicBaseVolume,
                    onVolumeChanged: (v) async {
                      // FIX 22 item 11: the inverse link nudges
                      // the mic level, then the volume applies
                      // directly (no fade).
                      await _onUserMusicVolume(v);
                      refresh();
                    },
                    // FIX 22 item 11: mic +/- stepper (host-only)
                    // drives the SAME _micFaderLevel as the RJ
                    // console MIC fader (single source of truth).
                    micLevel: _micFaderLevel,
                    onMicLevelChanged: (v) async {
                      await _onUserMicLevel(v);
                      refresh();
                    },
                    // Display-only: the panel has NO broadcast
                    // toggle — the library panel owns it.
                    // FIX 24 defect 1: either live path counts.
                    broadcastOn: _broadcastMusic || _radioMixerLive,
                    // FIX 2: the team captain hosts their own team
                    // room's music (effects knobs) even without
                    // app-admin. FIX 12 G6 (verifier 4 F1): the
                    // community organizer hosts likewise.
                    isHost: _isAdminForBroadcast || _isTeamCaptainForBroadcast || _isCommunityOrganizerForBroadcast,
                    // MUSIC effects: the mount's _fx state,
                    // pushed to the MUSIC player's own DSP
                    // instance through MusicFx (Group 2 swap).
                    // Fail-open like the voice chain below: when
                    // the music DSP is inactive (_musicDsp()
                    // null) the handlers mirror the state, skip
                    // the engine call, never crash.
                    reverb: _fxReverb,
                    echo: _fxEcho,
                    delayMs: _fxDelayMs,
                    bassDb: _fxBass,
                    onReverb: (v) async {
                      _fxReverb = v;
                      final dsp = _musicDsp();
                      if (dsp != null) {
                        try {
                          await MusicFx.applyReverb(dsp, v);
                        } catch (_) {}
                      }
                      refresh();
                    },
                    onEcho: (v) async {
                      _fxEcho = v;
                      final dsp = _musicDsp();
                      if (dsp != null) {
                        try {
                          await MusicFx.applyEcho(dsp, v, _fxDelayMs);
                        } catch (_) {}
                      }
                      refresh();
                    },
                    onDelayMs: (v) async {
                      _fxDelayMs = v;
                      final dsp = _musicDsp();
                      if (dsp != null) {
                        try {
                          await MusicFx.applyEcho(dsp, _fxEcho, v);
                        } catch (_) {}
                      }
                      refresh();
                    },
                    onBassDb: (v) async {
                      _fxBass = v;
                      // BASS MAPPING lives in MusicFx (same as
                      // the voice chain's rjBassEqPreset):
                      // positive dB -> bass boost, negative dB
                      // -> low-band cut, 0 dB -> flat. NOT the
                      // old (dB+12)/24 mapping — that fed a
                      // 0..1 amount API; on this engine it would
                      // send +6 dB at 0 dB (see MusicFx's doc).
                      final dsp = _musicDsp();
                      if (dsp != null) {
                        try {
                          await MusicFx.applyBass(dsp, v);
                        } catch (_) {}
                      }
                      refresh();
                    },
                    preset: _fxPreset,
                    onPreset: (name) async {
                      // Mirror presetValues into the sheet state
                      // so the props stay in sync, then push the
                      // preset to the music DSP through MusicFx
                      // (the DSP path is the source of truth for
                      // what you hear).
                      final values =
                          AudioEffectsPanel.presetValues[name];
                      if (values != null) {
                        _fxReverb = values['reverb']!;
                        _fxEcho = values['echo']!;
                        _fxDelayMs = values['delayMs']!;
                        _fxBass = values['bass']!;
                      }
                      _fxPreset = name;
                      final dsp = _musicDsp();
                      if (dsp != null && values != null) {
                        try {
                          await MusicFx.applyPreset(dsp, values);
                        } catch (_) {}
                      }
                      refresh();
                    },
                    // VOICE chain: the MIC chain's live setters
                    // (same calls as the voice console). When the
                    // DSP chain is inactive (_rjLiveDsp() null)
                    // the handlers fail open — mirror the state,
                    // skip the engine call, never crash.
                    noiseCancellation: _fxNoiseCancellation,
                    onNoiseCancellation: (v) async {
                      _fxNoiseCancellation = v;
                      try {
                        await _lkRoom.setNoiseCancellationEnabled(v);
                      } catch (_) {}
                      refresh();
                    },
                    noiseGateEnabled: _rjNoiseGateEnabled,
                    noiseGateThresholdDb: _musicGateThresholdDb,
                    onNoiseGateEnabled: (v) async {
                      _rjNoiseGateEnabled = v;
                      final dsp = _rjLiveDsp();
                      if (dsp != null) {
                        try {
                          await dsp.setNoiseGate(
                            enabled: v,
                            thresholdDb: _musicGateThresholdDb,
                          );
                        } catch (_) {}
                      }
                      refresh();
                    },
                    onNoiseGateThreshold: (v) async {
                      _musicGateThresholdDb = v;
                      final dsp = _rjLiveDsp();
                      if (dsp != null) {
                        try {
                          await dsp.setNoiseGate(
                            enabled: _rjNoiseGateEnabled,
                            thresholdDb: v,
                          );
                        } catch (_) {}
                      }
                      refresh();
                    },
                    compressorEnabled: _musicCompressorEnabled,
                    compressorThresholdDb:
                        _musicCompressorThresholdDb,
                    compressorRatio: _musicCompressorRatio,
                    onCompressorEnabled: (v) async {
                      _musicCompressorEnabled = v;
                      final dsp = _rjLiveDsp();
                      if (dsp != null) {
                        try {
                          await dsp.setCompressor(
                            enabled: v,
                            thresholdDb: _musicCompressorThresholdDb,
                            ratio: _musicCompressorRatio,
                          );
                        } catch (_) {}
                      }
                      refresh();
                    },
                    onCompressorThreshold: (v) async {
                      _musicCompressorThresholdDb = v;
                      final dsp = _rjLiveDsp();
                      if (dsp != null) {
                        try {
                          await dsp.setCompressor(
                            enabled: _musicCompressorEnabled,
                            thresholdDb: v,
                            ratio: _musicCompressorRatio,
                          );
                        } catch (_) {}
                      }
                      refresh();
                    },
                    onCompressorRatio: (v) async {
                      _musicCompressorRatio = v;
                      final dsp = _rjLiveDsp();
                      if (dsp != null) {
                        try {
                          await dsp.setCompressor(
                            enabled: _musicCompressorEnabled,
                            thresholdDb: _musicCompressorThresholdDb,
                            ratio: v,
                          );
                        } catch (_) {}
                      }
                      refresh();
                    },
                    listenerCount: _liveListeners.listenerCount,
                    listenerAvatarUrls: _liveListeners.listeners
                        .map((l) => l.avatarUrl)
                        .whereType<String>()
                        .toList(),
                    onListenersPressed: () {
                      showListenersDetailSheet(
                        sheetCtx,
                        listeners: _liveListeners.listeners,
                        listenerCount: _liveListeners.listenerCount,
                        peakListeners: _liveListeners.peakListeners,
                      );
                    },
                    // levelStream: omitted — no mic-level stream
                    // exists yet (same as the voice console);
                    // the panel animates gentle idle bars.
                  );
                },
              );
            },
          ),
        ],
      ),
    );
  }


  /// The live DSP setter handle for the mic chain, or null when the
  /// installed mic processor has no live DSP setters (RNNoise /
  /// Krisp / Off) — see [rjLiveDspSource]. FIX 22 item 6: the
  /// console builds the panel with a null handle too (the
  /// DSP-bound controls dim instead of hiding the panel) —
  /// never crashing on a bad cast.
  DspMicProcessor? _rjLiveDsp() => rjLiveDspSource(_lkRoom.micPipeline.source);

  /// First mic-seat occupant who is NOT the host — the guest
  /// strip's uid source. Seats come from [_lastSeatUids]
  /// (recomputed by the seat grid from the same `peerForMicCell`
  /// source the stage renders, lowest cell first); the host uid is
  /// [_adminUid] (the room admin/owner). Null when no guest is
  /// seated — the panel hides the guest strip then.
  /// FIX 24: the host's SELECTED call-in guest wins when they are
  /// still seated (rjCallInGuestUid) — otherwise the historic
  /// auto-pick (first non-host seat occupant).
  String? _rjGuestUid() {
    return rjCallInGuestUid(
      selectedUid: _rjCallInGuestUid,
      seatUids: _lastSeatUids,
      hostUid: _adminUid,
    );
  }

  /// Switches the mic processor (the console's picker). Null =
  /// Off: no processor, WebRTC built-in noise suppression only.
  /// Mirrors `_installMicNoiseProcessor`: the new processor is
  /// INITIALIZED FIRST — the pipeline disposes the current
  /// processor before installing, so a failed init must never
  /// reach setNoiseProcessor (otherwise the old processor is gone
  /// and the mic goes plain even though the switch failed). On a
  /// failed init the current processor stays installed and the
  /// user gets a toast — never a crash, never a silent switch.
  Future<void> _rjSwitchMicProcessor(MicProcessorKind? kind) async {
    if (_rjSwitchingProcessor) return;
    _rjSwitchingProcessor = true;
    if (mounted) setState(() {});
    try {
      final processor = kind == null
          ? null
          : buildMicProcessor(
              kind,
              krisp: KrispMicProcessor(),
              rnnoise: RnnoiseMicProcessor(),
              composite: CompositeMicProcessor(),
            );
      if (processor != null && !await processor.initialize()) {
        // Init failed (native side absent, Krisp cloud-gated, ...):
        // the current processor is untouched — report and stay.
        // FIX 21 (item 1): the toast names the processor that
        // failed — kind is non-null here (processor != null
        // implies kind != null); the generic text stays only as
        // the defensive fallback.
        await processor.dispose();
        if (mounted) {
          final failedName = kind == null
              ? 'Mic processor'
              : rjProcessorDisplayName(kind);
          toast(context,
              '$failedName available nahi hai — pehle wala chal raha hai.');
        }
        return;
      }
      if (!mounted) {
        if (processor != null) await processor.dispose();
        return;
      }
      // setNoiseProcessor unpublishes a live mic first, swaps, then
      // re-publishes — the room stays connected. (initialize() is
      // idempotent on all four processors, so the pipeline's own
      // initialize call inside setProcessor is a no-op.)
      final ok = await _lkRoom.setNoiseProcessor(processor);
      if (!ok) {
        // Near-unreachable after a successful pre-init (only a
        // build failure or a dispose race lands here) — but the
        // pipeline has already disposed the old processor by now,
        // so the honest report is "mic plain", not "old one kept".
        if (mounted) {
          toast(context, 'Mic processor switch nahi ho saka — mic ab plain chal raha hai.');
        }
        return;
      }
      if (mounted) setState(() {});
    } finally {
      _rjSwitchingProcessor = false;
      if (mounted) setState(() {});
    }
  }

  /// Soundboard tap flow (route A, SOUNDBOARD_INTEGRATION.md §5):
  /// (1) Dart state + local monitor (the D9 finish timer drives the
  /// pad underline — no mount-side timer); (2) push THIS pad's
  /// decoded clip to the native bridge (load-on-tap, ~10 ms);
  /// (3) play it live on air. Fail-open throughout. FIX 22 item 6:
  /// the panel renders with ANY mic processor now, so a tap can
  /// happen with no live DSP — the local monitor still plays and
  /// the on-air push is skipped (the null check below), never a
  /// crash and never a fake on-air claim.
  Future<void> _playSoundboardPad(SoundPad pad) async {
    try {
      await _soundboard.init();
      _soundboard.play(pad);
      final clip = _soundboard.decodedClip(pad);
      final dsp = _rjLiveDsp();
      if (clip != null && dsp != null) {
        final loaded = await dsp.pushSoundboardClip(clip);
        if (loaded) {
          await dsp.playSoundboardClip(_soundboard.gainFor(pad));
        }
      }
    } catch (_) {}
  }

  /// FIX 22 items 6+8 — the Urdu note shown in the RJ console
  /// when no live DSP chain exists: what is missing + how to
  /// enable it, plus the specific probe failure reason when the
  /// probe recorded one (never a bare "available nahi").
  String _rjDspMissingMessage() {
    const base =
        'Live effects ke liye DSP chahiye — upar se mic processor DSP ya DSP + RNNoise par karein.';
    final failure = DspMicProcessor.lastProbeFailure;
    if (failure == DspMicInitFailure.none) return base;
    return '$base\n${dspFailureLabel(failure)}';
  }

  /// Opens the RJ STUDIO voice console in a scrollable bottom sheet.
  /// Room-host-only (admin / team captain / community organizer —
  /// FIX 20 fix 7b, same parity as music broadcast; guarded here
  /// AND by the panel's isHost prop). The
  /// sheet holds the mic-processor picker at the top and the live
  /// console below it; with no live DSP chain the panel still
  /// builds (FIX 22 item 6) — its knobs + presets + noise gate
  /// show dimmed, and the Urdu note below the picker says why.
  /// All effect calls are
  /// best-effort (a missing native side must never break the
  /// sheet) — same contract as the music mount.
  /// FIX 22 item 21: the music player section's scroll target
  /// inside the RJ console — the sidebar Music entry opens the
  /// console focused on this section (ensureVisible).
  final GlobalKey _rjPlayerSectionKey = GlobalKey();

  Future<void> _showRjVoiceConsole({String initialSection = 'effects'}) async {
    // FIX 22 item 6: never fail silently. The host gate reads
    // _adminUid/_creatorUid, which load async from initState — a
    // fast tap could decide on empty state. Wait for the admin
    // load first (bounded 3 s, same pattern as _joinVoiceOpen's
    // 5 s wait), then re-check; if it still fails, say WHY.
    if (!_rjHostGatePasses) {
      final adminLoad = _adminLoadFuture;
      if (adminLoad != null && !_adminLoaded) {
        try {
          await adminLoad.timeout(const Duration(seconds: 3));
        } catch (_) {}
      }
      if (!_rjHostGatePasses) {
        if (!mounted) return;
        if (!_adminLoaded) {
          toast(context,
              'Pehchan load ho rahi hai — thora ruk kar dobara koshish karein.');
        } else {
          toast(context, 'RJ panel sirf room host ke liye hai.');
        }
        return;
      }
    }
    // FIX 22 item 21: the console now contains the music player
    // section, so the player must exist before the sheet opens
    // (idempotent — same call the standalone player made).
    // PHASE E (E17): never fail SILENTLY here — the sidebar
    // calls this via unawaited(), so a throw in the player
    // setup used to swallow the whole tap ("kuch nahi hota").
    // If setup fails, say so instead of doing nothing.
    try {
      await _ensureMusicPlayer();
    } catch (e) {
      if (mounted) {
        toast(context, 'Music player khul nahi saka — dobara koshish karein.');
      }
      return;
    }
    if (!mounted) return;
    // The NC toggle mirrors the mic pipeline's live state (the
    // settings sheet's Group 7 toggle writes the same flag) —
    // moved here from the retired standalone player.
    _fxNoiseCancellation = _lkRoom.noiseCancellationEnabled;
    // FIX 21 (item 3): DSP availability for the picker — probed
    // once per sheet open (DspMicProcessor.probeAvailable caches
    // per session, so repeat opens answer at once). Null = probe
    // still running: DSP stays enabled until proven unavailable
    // (fail-open — the switch still guards with init + toast).
    bool? dspAvailable;
    bool dspProbeStarted = false;
    // FIX 22 item 21: the Music entry's one-time scroll to the
    // player section (sheet-local, like the probe flag above).
    bool playerScrollDone = false;
    // FIX 20 (fix 9): sheet-local 1s ticker for the ON AIR timer
    // pill. The LIVE STATE itself lives in the room state
    // (_rjIsLive / _rjLiveStartedAt); this ticker only repaints
    // the open sheet once a second. Cancelled when the sheet
    // closes (.then below) and when END LIVE is tapped.
    Timer? liveTicker;
    void startLiveTicker(BuildContext sheetCtx, void Function(void Function()) sheetSetState) {
      liveTicker ??= Timer.periodic(const Duration(seconds: 1), (_) {
        if (!sheetCtx.mounted) {
          liveTicker?.cancel();
          liveTicker = null;
          return;
        }
        sheetSetState(() {});
      });
    }

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: kCardPurpleMid,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22)), side: const BorderSide(color: kCardPurpleBorder, width: 1.5)),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (sheetCtx, sheetSetState) {
            void refresh() {
              if (mounted) setState(() {});
              sheetSetState(() {});
            }

            // ARENA HUB #10 AUDIO — listeners: keep the open sheet's
            // count live (see _onListenersChanged).
            _listenersSheetRefresh = refresh;

            // FIX 21 (item 3): probe DSP availability once per
            // sheet open — the picker greys DSP out when the probe
            // says it cannot run (same `isAvailable` ping the
            // switch uses: one source of truth). The sheet may
            // close before the probe answers; the mounted check
            // keeps the late refresh from touching a dead sheet.
            if (!dspProbeStarted) {
              dspProbeStarted = true;
              DspMicProcessor.probeAvailable().then((available) {
                if (!sheetCtx.mounted) return;
                dspAvailable = available;
                refresh();
              });
            }
            // FIX 22 item 21: the sidebar Music entry opens the
            // console focused on the PLAYER section (below the
            // effects panel) — scroll to it once, after layout.
            if (initialSection == 'player' && !playerScrollDone) {
              playerScrollDone = true;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                final targetCtx = _rjPlayerSectionKey.currentContext;
                if (targetCtx != null) {
                  Scrollable.ensureVisible(
                    targetCtx,
                    duration: const Duration(milliseconds: 300),
                  );
                }
              });
            }
            // FIX 20 (fix 9): re-opening the console while live
            // restarts the timer ticker (the state survived in
            // the room; the ticker is per-sheet).
            if (_rjIsLive) startLiveTicker(sheetCtx, sheetSetState);
            final liveElapsed = _rjIsLive && _rjLiveStartedAt != null
                ? DateTime.now().difference(_rjLiveStartedAt!)
                : Duration.zero;

            // Resolved fresh on every sheet rebuild: the picker
            // switch changes the installed source, and the console
            // must follow it at once.
            final liveDsp = _rjLiveDsp();
            // The panel's control plane: the live DSP wrapped in
            // the RjVoiceDsp adapter (Dart is nominally typed —
            // the wrapper is what makes the mic chain's
            // Future<bool> setters satisfy the panel's
            // Future<void> interface). Null when no live DSP.
            final voiceDsp =
                liveDsp == null ? null : RjDspMicAdapter(liveDsp);
            final currentKind = rjKindOfSource(_lkRoom.micPipeline.source);
            // FIX 22 item 20: the mic processor renders as
            // BEAUTIFUL BUTTONS (dark + gold), not a dropdown
            // list — one button per processor, FIRST section of
            // the console. Selected = gold fill + black text +
            // check; disabled (DSP unavailable) = dimmed with
            // the specific failure reason as its subtitle (FIX
            // 22 item 8); switching disables all five. Tap runs
            // the same _rjSwitchMicProcessor path the dropdown
            // used (same toasts, same guards).
            Widget processorBtn(
              MicProcessorKind? kind,
              String name,
              String sub, {
              bool enabled = true,
            }) {
              final selected = currentKind == kind;
              final disabled = !enabled || _rjSwitchingProcessor;
              return InkWell(
                onTap: disabled
                    ? null
                    : () async {
                        if (kind == currentKind) return;
                        final fut = _rjSwitchMicProcessor(kind);
                        refresh(); // shows the switching state at once
                        await fut;
                        refresh(); // button selection + knob enablement
                      },
                borderRadius: BorderRadius.circular(12),
                child: Opacity(
                  opacity: enabled ? 1.0 : 0.45,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: selected
                          ? kGold
                          : Colors.black.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: selected
                            ? kGold
                            : kGold.withValues(alpha: 0.35),
                      ),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              name,
                              style: TextStyle(
                                color: selected ? Colors.black : kText,
                                fontSize: 13,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            if (selected) ...[
                              const SizedBox(width: 6),
                              const Icon(
                                Icons.check_circle,
                                size: 14,
                                color: Colors.black,
                              ),
                            ],
                          ],
                        ),
                        Text(
                          sub,
                          style: TextStyle(
                            color: selected
                                ? Colors.black.withValues(alpha: 0.7)
                                : kMuted,
                            fontSize: 10,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }
            // FIX 20 (fix 13): the console is a TALL sheet — the old
            // bare SingleChildScrollView let the bottom sections
            // (soundboard pads and below) clip off-screen. The
            // DraggableScrollableSheet owns the scroll gesture
            // (same pattern as _showRoomSettings): dragging the
            // content scrolls it instead of dismissing the sheet,
            // and the 28dp bottom padding + viewInsets keep the
            // last row (listeners strip) clear of the nav bar.
            return DraggableScrollableSheet(
              initialChildSize: 0.92,
              minChildSize: 0.5,
              maxChildSize: 0.95,
              expand: false,
              builder: (_, scrollController) => SafeArea(
                child: SingleChildScrollView(
                  controller: scrollController,
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                        20, 16, 20, 28 + MediaQuery.of(sheetCtx).viewInsets.bottom),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(color: kMuted, borderRadius: BorderRadius.circular(2)))),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        Icon(Icons.graphic_eq, color: kGold, size: 22),
                        const SizedBox(width: 8),
                        Text('RJ STUDIO', style: TextStyle(color: kText, fontWeight: FontWeight.w900, fontSize: 17)),
                        const SizedBox(width: 8),
                        Text('Voice console — live mic', style: TextStyle(color: kMuted, fontSize: 12)),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Text('Mic processor', style: TextStyle(color: kMuted, fontSize: 12, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 6),
                    // FIX 22 item 20: buttons, not a dropdown —
                    // see processorBtn above. Krisp is cloud-gated
                    // and expected ineffective on our self-hosted
                    // server — labelled honestly, not hidden. DSP
                    // is greyed with its specific reason when the
                    // probe says it cannot run (FIX 21 item 3 +
                    // FIX 22 item 8); the currently-active
                    // processor is never disabled (if DSP is
                    // installed, it works).
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        processorBtn(MicProcessorKind.rnnoise, 'RNNoise',
                            'noise suppression'),
                        processorBtn(
                          MicProcessorKind.dsp,
                          'DSP',
                          dspAvailable == false &&
                                  currentKind != MicProcessorKind.dsp
                              ? dspFailureLabel(
                                  DspMicProcessor.lastProbeFailure)
                              : 'RJ live effects',
                          enabled: dspAvailable != false ||
                              currentKind == MicProcessorKind.dsp,
                        ),
                        processorBtn(MicProcessorKind.composite,
                            'DSP + RNNoise', 'effects + suppression'),
                        processorBtn(MicProcessorKind.krisp, 'Krisp',
                            'cloud — may not work on our server'),
                        processorBtn(null, 'Off', 'WebRTC built-in only'),
                      ],
                    ),
                    if (_rjSwitchingProcessor) ...[
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: kGold)),
                          const SizedBox(width: 8),
                          Text('Mic processor switch ho raha hai…', style: TextStyle(color: kMuted, fontSize: 12)),
                        ],
                      ),
                    ],
                    const SizedBox(height: 12),
                    // FIX 22 item 6: the console builds with ANY
                    // mic processor now — when no DSP chain is
                    // live, the knobs + presets + noise gate show
                    // dimmed (the panel's _dspGated) and this
                    // Urdu note says why + how to enable them
                    // (FIX 22 item 8: the specific failure reason
                    // rides along when the probe recorded one).
                    if (liveDsp == null) ...[
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(color: kGold.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(12)),
                        child: Text(
                          _rjDspMissingMessage(),
                          style: TextStyle(color: kText, fontSize: 12),
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                    // The console itself: RjStudioPanel, built
                    // ALWAYS (FIX 22 item 6) — dsp: is nullable
                    // now, so a null handle dims the DSP-bound
                    // controls instead of hiding the whole panel
                    // (the old gate left the sheet with only a
                    // picker + note after every restart on phones
                    // where DSP init fails). The panel owns its
                    // knob/preset/fader state; the mount only wires
                    // props + callbacks (see
                    // RJ_PANEL_INTEGRATION.md §7 for the full
                    // wiring table + the unsourced props).
                    // Now-playing position comes from the player's
                    // position stream (same source as the music
                    // sheet); the panel's State survives the ~5 Hz
                    // rebuilds — only this subtree rebuilds.
                    StreamBuilder<Duration>(
                        stream: _musicPlayer?.positionStream,
                        initialData: Duration.zero,
                        builder: (posCtx, posSnap) {
                          final guestUid = _rjGuestUid();
                          return RjStudioPanel(
                            dsp: voiceDsp,
                            // FIX 20 (fix 7b): the panel's host is
                            // the ROOM HOST (admin / team captain /
                            // community organizer), not admin-only.
                            isHost: _isAdminForBroadcast ||
                                _isTeamCaptainForBroadcast ||
                                _isCommunityOrganizerForBroadcast,
                            hostName: _adminProfileName.isNotEmpty
                                ? _adminProfileName
                                : 'Admin',
                            isMuted: _lkRoom.muted,
                            // FIX 20 (fix 9): session-local live
                            // state — the panel shows ON AIR + the
                            // running timer while live, OFF AIR
                            // otherwise. The GO LIVE button flips
                            // to END LIVE (panel-owned label).
                            isLive: _rjIsLive,
                            liveElapsed: liveElapsed,
                            onGoLivePressed: () {
                              if (_rjIsLive) {
                                // END LIVE: clear the state, stop
                                // the ticker, repaint OFF AIR.
                                // FIX 22 item 21: hosting stops
                                // too — music returns to
                                // local-only (the OFF branch sends
                                // 'stop', clears the session, and
                                // keeps playing locally).
                                // FIX 24: END LIVE unhooks the
                                // radio mixer too (music returns to
                                // local-only; a held mute is
                                // restored to a real disable).
                                unawaited(_unregisterRadioMixer());
                                unawaited(_setBroadcast(false));
                                if (mounted) {
                                  setState(() {
                                    _rjIsLive = false;
                                    _rjLiveStartedAt = null;
                                  });
                                } else {
                                  _rjIsLive = false;
                                  _rjLiveStartedAt = null;
                                }
                                liveTicker?.cancel();
                                liveTicker = null;
                                sheetSetState(() {});
                                return;
                              }
                              // GO LIVE: only while actually on
                              // voice — a live show with no mic
                              // would be a lie.
                              if (!_lkRoom.joined && !_room.joined) {
                                if (mounted) {
                                  toast(
                                    context,
                                    'Pehle voice par connect karein — live tabhi hoga jab aap voice par hon',
                                  );
                                }
                                return;
                              }
                              if (mounted) {
                                setState(() {
                                  _rjIsLive = true;
                                  _rjLiveStartedAt = DateTime.now();
                                });
                              } else {
                                _rjIsLive = true;
                                _rjLiveStartedAt = DateTime.now();
                              }
                              // FIX 22 item 21: GO LIVE starts the
                              // music HOSTING — the ON branch
                              // uploads+shares the current file
                              // song if one is playing, else just
                              // arms the flag so the next song
                              // played shares via the play path.
                              // (Edge: if music approval is
                              // blocked, _setBroadcast requests
                              // approval and returns WITHOUT
                              // arming — the host must END LIVE
                              // then GO LIVE again after approval.)
                              // FIX 24: GO LIVE registers the
                              // radio mixer via _goLiveBroadcast
                              // (music straight into the mic
                              // stream). If it fails to register,
                              // the show falls back to the upload
                              // path with an honest toast (inside
                              // _registerRadioMixer) — the upload
                              // arm lives ONLY in _goLiveBroadcast
                              // (defect 1: arming both played the
                              // song twice, unsynchronised).
                              unawaited(_goLiveBroadcast());
                              startLiveTicker(sheetCtx, sheetSetState);
                              sheetSetState(() {});
                            },
                            // FIX 20 (fix 10): the panel's gear
                            // opens Room Settings — close this
                            // console sheet first, then open it
                            // (a sheet over a sheet stacks badly).
                            onSettingsPressed: () {
                              Navigator.of(context).pop();
                              _showRoomSettings();
                            },
                            onMutePressed: () async {
                              await _lkRoom.setMuted(!_lkRoom.muted);
                              // FIX 22 item 10: re-apply the music
                              // volume at once — the voice must win
                              // immediately (FIX 22 item 11: direct,
                              // no fade); do not wait for the
                              // ~2 s poll listener.
                              await _applyMusicVolume();
                              refresh();
                            },
                            listenerCount: _liveListeners.listenerCount,
                            listeners: _liveListeners.listeners,
                            onListenersTap: () {
                              showListenersDetailSheet(
                                sheetCtx,
                                listeners: _liveListeners.listeners,
                                listenerCount:
                                    _liveListeners.listenerCount,
                                peakListeners:
                                    _liveListeners.peakListeners,
                              );
                            },
                            guestName: guestUid == null
                                ? null
                                : _lkRoom.participants[guestUid]?.name,
                            nowPlayingTitle: _musicPlaying,
                            nowPlayingPosition:
                                posSnap.data ?? Duration.zero,
                            nowPlayingDuration: _musicDuration,
                            // FIX 22 item 11: the panel's faders
                            // mirror the room's single source of
                            // truth (mic + music levels) — the
                            // inverse link nudges the OTHER fader,
                            // and the panel syncs via
                            // didUpdateWidget.
                            micVolume: _micFaderLevel,
                            musicVolume: _musicBaseVolume,
                            onMusicVolume: (v) async {
                              // FIX 22 item 11: inverse link +
                              // direct application; refresh so the
                              // nudged MIC fader shows at once.
                              await _onUserMusicVolume(v);
                              refresh();
                            },
                            noiseGateEnabled: _rjNoiseGateEnabled,
                            onNoiseGateChanged: (v) async {
                              _rjNoiseGateEnabled = v;
                              final dsp = _rjLiveDsp();
                              if (dsp != null) {
                                try {
                                  // Engine-default threshold: the
                                  // panel's knob owns the threshold
                                  // now; the toggle only flips the
                                  // stage on/off.
                                  await dsp.setNoiseGate(
                                    enabled: v,
                                    thresholdDb: -40.0,
                                  );
                                } catch (_) {}
                              }
                              refresh();
                            },
                            // levelStream: omitted — no mic-level
                            // stream exists yet; the panel's default
                            // empty stream keeps the spectrum bars
                            // at idle height (never faked).
                            // guestLevel: omitted (0.0) — no
                            // per-participant level exists (§7).
                            // FIX 20 (fix 11): the MIC fader drives
                            // music ducking (talkover) — mic up =
                            // music down. It does NOT set mic gain
                            // (no such control exists); it only
                            // scales the music output via
                            // _applyMusicVolume.
                            onMicVolume: (v) async {
                              // FIX 22 item 11: inverse link +
                              // direct application; refresh so the
                              // nudged MUSIC fader shows at once.
                              await _onUserMicLevel(v);
                              refresh();
                            },
                            // FIX 24: the panel MIC ON/OFF button
                            // gates the inverse link (ON = link
                            // active, OFF = manual faders) and the
                            // live call-in picker (approved seat
                            // occupants only). Both push the mixer
                            // gains at once — listeners hear the
                            // host's mix change live.
                            micLinkOn: _rjMicLinkOn,
                            onMicLinkChanged: (v) {
                              _rjMicLinkOn = v;
                              _pushMixerGains();
                              refresh();
                            },
                            callInSeats: _rjCallInSeats(),
                            selectedCallInUid: _rjCallInGuestUid,
                            onCallInSelected: (uid) {
                              _rjCallInGuestUid = uid;
                              _pushMixerGains();
                              refresh();
                            },
                            // onGuestVolume: omitted — no
                            // per-participant volume control
                            // exists (§7).
                            onSoundboard: (pad) => _playSoundboardPad(
                              switch (pad) {
                                RjSoundboardPad.applause =>
                                  SoundPad.applause,
                                RjSoundboardPad.airHorn =>
                                  SoundPad.airHorn,
                                RjSoundboardPad.laugh => SoundPad.laugh,
                                RjSoundboardPad.drum => SoundPad.drumRoll,
                              },
                            ),
                            // hostAvatarUrl: omitted (null) — no
                            // admin avatar source in the room; the
                            // panel falls back to the initial.
                          );
                        },
                      ),
                      // FIX 22 item 21: the music player section,
                      // merged into the console (no standalone
                      // player sheet anymore) — below the effects
                      // panel, focused by the sidebar Music entry.
                      _buildConsoleMusicSection(sheetCtx, refresh),
                  ],
                ),
              ),
              ),
              ),
            );
          },
        );
      },
    ).then((_) {
      // FIX 20 (fix 9): the console closed — stop the timer
      // ticker. The LIVE STATE stays in the room (re-opening the
      // console while live restarts the ticker from _rjLiveStartedAt).
      liveTicker?.cancel();
      liveTicker = null;
    });
  }

  // FIX 22 item 22: _showMusicSettings is DELETED — the dialog
  // held ONLY the Broadcast switch + fallback note, and hosting
  // is GO LIVE only now (item 21). The player's Settings button
  // and the library's Settings button are both gone with it.

  // ROUND 12 PREMIUM side button: larger gold-ringed circle with a
  // soft gold glow + gradient fill, bold label below. Compact mode
  // (keyboard open) drops the label and shrinks the circle so the
  // 6-button column never squeezes chat off-screen while typing.
  // MASTER-PROMPT ROOM REDESIGN (2026-10-30): the old side column
  // (Backgrounds/Music/Polls/Info/Exit/Frames/Status) is replaced by
  // the right rail + Settings sheet below. Nothing it did is dropped:
  // Backgrounds/Music/Frames/Status live in Settings, Polls and Info
  // have their own rail items, Exit is Leave Room (confirmed).
  int _roomUserCount() {
    // v2016 FIX 8 (user order 2026-11-22, "Online count bilkul
    // sahi aana chahiye"): ONE union rule — in-room + online
    // presence rows UNION live voice peers from BOTH engines
    // (mesh + LiveKit). The old code was presence-OR-voice: as
    // soon as any presence row was online, voice peers NOT in the
    // presence map (room admin, spectators, a voice user whose
    // presence heartbeat went stale) were invisible and the count
    // under-read. A uid on both counts once. Voice join/leave
    // moves the count AT ONCE (both engines notify + setState);
    // presence-only join/leave moves it on the 10 s poll. The
    // pure rule lives on PresenceService so it is unit-tested.
    return PresenceService.countOnlineUsers(
      presenceMap: _presenceMap,
      inRoom: _presenceInRoom,
      meshPeerUids: _room.peers.keys,
      liveKitUids: _lkRoom.participants.keys,
    );
  }

  Future<void> _confirmLeave() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kCardPurpleMid,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22), side: const BorderSide(color: kCardPurpleBorder, width: 1.5)),
        title: const Text('Leave Room?', style: TextStyle(color: Color(0xFFFDC903), fontWeight: FontWeight.bold)),
        content: const Text('Voice chat band ho jayega aur aap room se nikal jayenge.', style: TextStyle(color: Colors.white)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel', style: TextStyle(color: Color(0xFF7786A5)))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Leave', style: TextStyle(color: Color(0xFFF12D45), fontWeight: FontWeight.bold))),
        ],
      ),
    );
    if (ok == true) await _exitRoom();
  }

  // CONNECTED-BAR REDESIGN (2026-10-30): voice-ONLY leave, distinct
  // from Leave Room. The old connected bar's tap called _confirmLeave
  // (room exit); the new small rail indicator must NOT exit the room
  // — it only drops voice (VoiceRoom.leave: peer row removed, peer
  // connections closed, foreground service stopped, joined=false),
  // so the user stays in the room and can still read/send chat, and
  // the small rail Voice button stays for rejoining.
  Future<void> _confirmLeaveVoice() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kCardPurpleMid,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22), side: const BorderSide(color: kCardPurpleBorder, width: 1.5)),
        title: const Text('Leave Voice Chat?', style: TextStyle(color: Color(0xFFFDC903), fontWeight: FontWeight.bold)),
        content: const Text('Voice band ho jayegi, lekin aap room me rahenge aur chat dekh/sun sakenge.', style: TextStyle(color: Colors.white)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel', style: TextStyle(color: Color(0xFF7786A5)))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Leave Voice', style: TextStyle(color: Color(0xFFF12D45), fontWeight: FontWeight.bold))),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _room.leave();
    } catch (_) {}
    if (mounted) setState(() {});
  }

  /// LiveKit test path, voice-only leave (room stays open, chat
  /// stays readable) — mirrors _confirmLeaveVoice for the mesh.
  Future<void> _confirmLeaveVoiceLiveKit() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kCardPurpleMid,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22), side: const BorderSide(color: kCardPurpleBorder, width: 1.5)),
        title: const Text('Leave Voice Chat? (LiveKit test)', style: TextStyle(color: Color(0xFFFDC903), fontWeight: FontWeight.bold)),
        content: const Text('Voice band ho jayegi, lekin aap room me rahenge aur chat dekh/sun sakenge.', style: TextStyle(color: Colors.white)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel', style: TextStyle(color: Color(0xFF7786A5)))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Leave Voice', style: TextStyle(color: Color(0xFFF12D45), fontWeight: FontWeight.bold))),
        ],
      ),
    );
    if (ok != true) return;
    // Intentional leave: the drop banner must NOT appear.
    _lkIntentionalDisconnect = true;
    try {
      await _lkRoom.disconnect();
    } catch (_) {}
    _lkIntentionalDisconnect = false;
    if (mounted) {
      setState(() {
        _lkWasJoined = false;
        _lkJoinedProjectId = '';
        _lkDropped = false;
      });
    }
  }

  /// LIVEKIT TEST PANEL (2026-11-01): engine switch for this
  /// visit + (admin-only) project failover. Non-admins see the
  /// engine switch and a generic configured/not-configured status
  /// ONLY — server URLs and project names are admin-only, and
  /// non-admins can never change server config (fail closed: the
  /// switch write re-checks the admin guard and returns false on
  /// failure, e.g. migration 015 not applied).
  Future<void> _setLiveKitEngine(bool useLiveKit) async {
    if (useLiveKit == _useLiveKit) return;
    try {
      if (useLiveKit) {
        if (_room.joined) await _room.leave();
      } else {
        _lkIntentionalDisconnect = true;
        try {
          if (_lkRoom.joined) await _lkRoom.disconnect();
        } finally {
          _lkIntentionalDisconnect = false;
        }
      }
    } catch (_) {}
    if (mounted) {
      setState(() {
        _useLiveKit = useLiveKit;
        _lkWasJoined = false;
        _lkJoinedProjectId = '';
        _lkDropped = false;
      });
    }
  }

  void _showLiveKitPanel() {
    final isAdmin = _isAdminForBroadcast;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: kCardPurpleMid,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22)), side: const BorderSide(color: kCardPurpleBorder, width: 1.5)),
      builder: (ctx) {
        return DraggableScrollableSheet(
          initialChildSize: 0.65,
          minChildSize: 0.35,
          maxChildSize: 0.9,
          expand: false,
          builder: (sheetCtx, scrollController) => SafeArea(
            child: Column(
              children: [
                const SizedBox(height: 10),
                Container(width: 40, height: 4, decoration: BoxDecoration(color: const Color(0xFF7786A5), borderRadius: BorderRadius.circular(2))),
                const SizedBox(height: 8),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text('Voice test (LiveKit) — TEST ONLY', style: TextStyle(color: Color(0xFFFDC903), fontWeight: FontWeight.bold, fontSize: 16)),
                  ),
                ),
                Expanded(
                  child: FutureBuilder<LiveKitConfig>(
                    future: LiveKitConfig.load(),
                    builder: (_, snap) {
                      final cfg = snap.data ?? _lkConfig ?? const LiveKitConfig(projects: [], activeProjectId: '');
                      final configured = cfg.isConfigured;
                      return ListView(
                        controller: scrollController,
                        children: [
                          ListTile(
                            leading: const Icon(Icons.cloud, color: Color(0xFFFDC903)),
                            title: const Text('Voice engine: Mesh (default)', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                            subtitle: const Text('Current working voice — always available.', style: TextStyle(color: Color(0xFF7786A5))),
                            trailing: !_useLiveKit ? const Icon(Icons.check_circle, color: Color(0xFF16D879)) : null,
                            onTap: () async { Navigator.pop(ctx); await _setLiveKitEngine(false); if (mounted) toast(context, 'Voice engine: Mesh (default).'); },
                          ),
                          ListTile(
                            leading: const Icon(Icons.science, color: Color(0xFFFDC903)),
                            title: const Text('Voice engine: LiveKit test', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                            subtitle: Text(
                              configured
                                  ? 'SFU trial — join with the Join button. Switching engines drops the current voice session.'
                                  : 'LiveKit server abhi set nahi hai — is engine se join nahi hoga jab tak admin server set na kare.',
                              style: const TextStyle(color: Color(0xFF7786A5)),
                            ),
                            trailing: _useLiveKit ? const Icon(Icons.check_circle, color: Color(0xFF16D879)) : null,
                            onTap: () async { Navigator.pop(ctx); await _setLiveKitEngine(true); if (mounted) toast(context, _useLiveKit ? 'Voice engine: LiveKit test. Join button se dobara join karen.' : 'Voice engine: LiveKit test.'); },
                          ),
                          const Divider(color: Color(0xFF203457)),
                          ListTile(
                            leading: const Icon(Icons.info_outline, color: Color(0xFF7786A5)),
                            title: Text(configured ? 'LiveKit: configured' : 'LiveKit: not configured', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                            subtitle: const Text('Server details admin-only hain. Project switch karne par live voice session toot jayegi aur dobara join karna hoga.', style: TextStyle(color: Color(0xFF7786A5))),
                          ),
                          if (isAdmin) ...[
                            const Padding(
                              padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
                              child: Text('Admin — LiveKit projects (failover)', style: TextStyle(color: Color(0xFFFDC903), fontWeight: FontWeight.bold)),
                            ),
                            if (cfg.projects.isEmpty)
                              const Padding(
                                padding: EdgeInsets.all(16),
                                child: Text('Koi LiveKit project set nahi hai. Admin app_settings.livekit me projects + activeProjectId set kare (migration 015 + token function deploy ke baad).', style: TextStyle(color: Color(0xFF7786A5))),
                              ),
                            for (final p in cfg.projects)
                              ListTile(
                                leading: Icon(Icons.dns, color: p.id == cfg.activeProjectId ? const Color(0xFF16D879) : const Color(0xFF7786A5)),
                                title: Text(p.name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                                subtitle: Text(p.serverUrl, style: const TextStyle(color: Color(0xFF7786A5), fontSize: 12)),
                                trailing: p.id == cfg.activeProjectId ? const Icon(Icons.check_circle, color: Color(0xFF16D879)) : null,
                                onTap: p.id == cfg.activeProjectId
                                    ? null
                                    : () async {
                                        final ok = await showDialog<bool>(
                                          context: ctx,
                                          builder: (dctx) => AlertDialog(
                                            backgroundColor: kCardPurpleMid,
                                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22), side: const BorderSide(color: kCardPurpleBorder, width: 1.5)),
                                            title: const Text('Switch LiveKit project?', style: TextStyle(color: Color(0xFFFDC903), fontWeight: FontWeight.bold)),
                                            content: Text('Active project ${p.name} ho jayega. Live voice session (agar chal rahi hai) toot jayegi — room transfer nahi hota. Switch ke baad har koi room ke andar hi Refresh / Dobara Connect dabakar naye project par dobara connect kare — room chhorne ya tournament dobara join karne ki zaroorat nahi.', style: const TextStyle(color: Colors.white)),
                                            actions: [
                                              TextButton(onPressed: () => Navigator.pop(dctx, false), child: const Text('Cancel', style: TextStyle(color: Color(0xFF7786A5)))),
                                              TextButton(onPressed: () => Navigator.pop(dctx, true), child: const Text('Switch', style: TextStyle(color: Color(0xFFF12D45), fontWeight: FontWeight.bold))),
                                            ],
                                          ),
                                        );
                                        if (ok != true) return;
                                        _lkIntentionalDisconnect = true;
                                        try {
                                          if (_lkRoom.joined) await _lkRoom.disconnect();
                                        } finally {
                                          _lkIntentionalDisconnect = false;
                                        }
                                        final done = await LiveKitConfig.setActiveProject(cfg, p.id);
                                        if (mounted) {
                                          setState(() {
                                            _lkConfig = LiveKitConfig(projects: cfg.projects, activeProjectId: p.id);
                                            _lkWasJoined = false;
                                            _lkJoinedProjectId = '';
                                            _lkDropped = false;
                                          });
                                          toast(context, done ? 'LiveKit project switched: ${p.name}. Room ke andar hi Refresh / Dobara Connect dabakar naye project par dobara connect karen — room chhorne ki zaroorat nahi.' : 'Switch failed — migration 015 apply nahi hui ya write blocked hai.');
                                        }
                                        if (ctx.mounted) Navigator.pop(ctx);
                                      },
                              ),
                          ],
                          // FIX 22 item 7 (2026-11-23, user order):
                          // the 'LiveKit Speaker' toggle Switch is
                          // REMOVED — voice + music are ALWAYS on
                          // the loudspeaker; no earpiece routing
                          // anywhere, no toggle in any UI.
                          // GROUP 7 (AUDIO #10) — mic noise
                          // cancellation toggle. Visible only when
                          // a noise processor is installed (Krisp /
                          // RNNoise, Groups 1/2); hidden otherwise
                          // so the panel stays unchanged on builds
                          // without a processor. Toggling never drops
                          // the call — only the mic track is
                          // re-published (see LiveKitVoiceService).
                          if (_lkRoom.joined)
                            ListenableBuilder(
                              listenable: _lkRoom,
                              builder: (_, __) {
                                if (!_lkRoom.noiseCancellationAvailable) {
                                  return const SizedBox.shrink();
                                }
                                return ListTile(
                                  leading: const Icon(Icons.graphic_eq, color: Color(0xFFFDC903)),
                                  title: const Text('Noise Cancellation', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                                  subtitle: const Text('Mic se background shor hataye', style: TextStyle(color: Color(0xFF7786A5), fontSize: 12)),
                                  trailing: Switch(
                                    value: _lkRoom.noiseCancellationEnabled,
                                    activeThumbColor: const Color(0xFFFDC903),
                                    onChanged: (v) => unawaited(_lkRoom.setNoiseCancellationEnabled(v)),
                                  ),
                                  onTap: () => unawaited(_lkRoom.setNoiseCancellationEnabled(!_lkRoom.noiseCancellationEnabled)),
                                );
                              },
                            ),
                          const SizedBox(height: 12),
                        ],
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showRoomSettings() {
    // Scroll fix: the old sheet was a plain Column inside a
    // non-scroll-controlled bottom sheet, so on a small phone the
    // list ran past the fold with no scrollable widget at all —
    // finger drags had nowhere to go and items below the fold
    // (Cheer, cut off at the bottom) was unreachable.
    // DraggableScrollableSheet owns the scroll gesture: dragging the
    // list scrolls it, and dragging past the top/bottom dismisses
    // or expands the sheet, so every item is reachable on phone.
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: kCardPurpleMid,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22)), side: const BorderSide(color: kCardPurpleBorder, width: 1.5)),
      builder: (ctx) {
        Widget row(IconData icon, String label, VoidCallback onTap, {Widget? trailing}) => ListTile(
              leading: Icon(icon, color: const Color(0xFFFDC903), size: 22),
              title: Text(label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
              trailing: trailing,
              onTap: onTap,
            );
        return DraggableScrollableSheet(
          initialChildSize: 0.65,
          minChildSize: 0.35,
          maxChildSize: 0.9,
          expand: false,
          builder: (sheetCtx, scrollController) => SafeArea(
            child: Column(
              children: [
                const SizedBox(height: 10),
                Container(width: 40, height: 4, decoration: BoxDecoration(color: const Color(0xFF7786A5), borderRadius: BorderRadius.circular(2))),
                const SizedBox(height: 8),
                Expanded(
                  child: ListView(
                    controller: scrollController,
                    children: [
                      row(Icons.wallpaper, 'Backgrounds', () { Navigator.pop(ctx); _showBackgroundsPanel(); }),
                      // MUSIC MOVED (2026-11-01 user order): Music
                      // is no longer in Settings — it lives on the
                      // rail (replacing Tournament Info there).
                      row(Icons.emoji_events, 'Frames', () { Navigator.pop(ctx); _openFrames(); }),
                      row(Icons.people, 'Participants / Status', () { Navigator.pop(ctx); _openStatus(); }),
                      // FIX 22 item 7 (2026-11-23, user order):
                      // the Speaker ON/OFF toggle is REMOVED — voice
                      // + music are ALWAYS on the loudspeaker now
                      // (no earpiece routing anywhere); the row
                      // used to sit here (RoomSpeakerRow, deleted).
                      row(Icons.bug_report, 'Voice diagnostics', () { Navigator.pop(ctx); setState(() => _showVoiceDiag = true); }),
                      // LIVEKIT TEST PATH (2026-11-01): Settings
                      // entry for the SFU trial. Mesh stays the
                      // default; this panel only switches the
                      // engine for this visit and (admin-only)
                      // switches the active LiveKit project.
                      row(Icons.science, 'Voice test (LiveKit)', () { Navigator.pop(ctx); _showLiveKitPanel(); }),
                      row(Icons.celebration, 'Cheer (Free Points)', () { Navigator.pop(ctx); _sendCheer(); }),
                      const SizedBox(height: 12),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // RAIL SLIMMED (2026-10-30): button width 68 -> 54, icon 21 -> 19,
  // labels wrap to 2 lines at 8px so full labels stay readable in
  // the slimmer rail instead of truncating ("Tournament I...").
  Widget _railBtn(IconData icon, String label, VoidCallback onTap, {bool selected = false, String? sub}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        width: 54,
        padding: const EdgeInsets.symmetric(vertical: 6),
        // 2026-11-20 (global gold): selected rail button is solid
        // gold with black icon/label — the neon pink/purple gradient
        // is retired; unselected stays the dark card.
        // REDESIGN S7 (2026-11-23): rail button on the shared
        // tokens — kRadiusCard + kGold (same #FDC903 as nGold).
        decoration: BoxDecoration(
          color: selected ? kGold : nCard.withValues(alpha: 0.85),
          borderRadius: BorderRadius.circular(kRadiusCard),
          border: Border.all(color: selected ? kGold : kGold.withValues(alpha: 0.20)),
          boxShadow: selected ? [BoxShadow(color: kGold.withValues(alpha: 0.28), blurRadius: 10, spreadRadius: 1)] : null,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: selected ? Colors.black : Colors.white, size: 20),
            const SizedBox(height: 2),
            Text(label, style: TextStyle(color: selected ? Colors.black : Colors.white, fontSize: 8, fontWeight: FontWeight.w800, height: 1.2), textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis),
            // FIX 17: reserve the sub-label line even with no sub, so
            // every rail button is exactly the same height.
            if (sub != null) Text(sub, style: TextStyle(color: kMuted, fontSize: 7, fontWeight: FontWeight.bold, height: 1.2), textAlign: TextAlign.center) else const SizedBox(height: 9),
          ],
        ),
      ),
    );
  }

  // Right navigation rail (master prompt §12). Room Home is the room
  // itself (selected); every other item opens its real panel/screen.
  Widget _navRail() {
    // RAIL CLEANUP + SLIM (2026-10-30 user order): Gifts and Polls
    // buttons REMOVED. RAIL REORDER (2026-11-22 user order):
    // Room Home, [Invite — squad only], Settings, Voice Connect,
    // [Refresh — LiveKit test only], [Voice On indicators —
    // connected only], Music, [RJ Studio — host only], Follow,
    // Leave Room LAST.
    // Participants button REMOVED from the rail (2026-11-22) —
    // the Participants/Status sheet itself is unchanged and still
    // reachable from the room menu (see _openStatus).
    // Rail width 72 -> 58, tighter padding, sleeker rounded look,
    // so the grid + chat get visibly more room.
    // 2026-11-20 (user order, "har jagah"): the rail is a
    // MockupCard — gradient fill + the two rotating gold corner
    // shines, no static neon border. Width stays 58.
    return SizedBox(
      width: 58,
      child: MockupCard(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
        radius: kRadiusCard,
        child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _railBtn(Icons.home, 'Room Home', () {}, selected: true),
          const SizedBox(height: 6),
          // BATCH 3B #21 INVITE (squad scope only, not spectator):
          // same shared username dialog as community chat /
          // TeamChatPage -> existing SupaDb.sendTeamInvite.
          if (_isSquad && !widget.spectator) ...[
            _railBtn(Icons.person_add, 'Invite', _inviteFromChat),
            const SizedBox(height: 6),
          ],
          _railBtn(Icons.settings, 'Settings', _showRoomSettings),
          const SizedBox(height: 6),
          // VOICE SIDE BUTTON (2026-11-01 user order): the big
          // bottom Join pill + VIP/Hot buttons are REMOVED, so
          // voice connect lives here as one small rail button.
          // Not joined -> Connect (opens the join sheet, or
          // retries a stalled join). Connected (mesh ready or
          // LiveKit) -> highlighted Voice On, tap leaves voice
          // only (room is NOT exited). ListenableBuilder so the
          // button flips live with either voice engine.
          const SizedBox(height: 6),
          ListenableBuilder(
            listenable: Listenable.merge([_room, _lkRoom]),
            builder: (context, _) {
              final connected = _lkRoom.joined || (_room.joined && _room.voiceReady);
              return _railBtn(
                connected ? Icons.mic : Icons.mic_none,
                connected ? 'Voice On' : 'Voice',
                () async {
                  if (widget.spectator) { toast(context, 'Spectator mode — voice view-only hai.'); return; }
                  if (_lkRoom.joined) { await _confirmLeaveVoiceLiveKit(); return; }
                  if (!_room.joined) { _joinVoiceOpen(); return; }
                  if (_room.joinStalled) { await _retryVoice(); return; }
                  if (!_room.voiceReady) { toast(context, 'Voice connect ho rahi hai…'); return; }
                  await _confirmLeaveVoice();
                },
                sub: connected ? null : 'Connect',
                selected: connected,
              );
            },
          ),
          // REFRESH SIDE BUTTON (2026-11-01 user order): jab
          // admin LiveKit project badal kar doosra active kare,
          // to room ke andar side me ye chhota Refresh button
          // dobara connect kar deta hai — naya active project
          // dobara parh kar, naya token lekar, mic state wapas
          // la kar (mute/reject gate dobara check hote hain).
          // Sirf LiveKit test mode on hone par dikhta hai (Mesh
          // par project ka sawal hi nahi). Project change/drop
          // par ye highlight ho jata hai; banner wala Refresh
          // bhi wahi kaam karta hai, ye uska side shortcut hai.
          if (_useLiveKit) ...[
            const SizedBox(height: 6),
            _railBtn(
              Icons.refresh,
              'Refresh',
              () async {
                if (_lkReconnecting) { toast(context, 'Dobara connect ho raha hai…'); return; }
                await _reconnectLiveKit();
              },
              sub: _lkDropped ? 'New project' : null,
              selected: _lkDropped,
            ),
          ],
          // CONNECTED-BAR REDESIGN (2026-10-30): when voice is
          // connected, the big bottom bar is gone — this SMALL rail
          // indicator (green dot + "Voice On") under the Voice
          // button is the connected-state signal AND the
          // voice-leave path (tap → voice-only leave
          // confirmation; room is NOT exited). It only renders
          // while voiceReady, so it can never be confused with
          // the Voice button above it. The rail rebuilds on
          // _room notifications, so it appears/disappears with
          // the voice state without any extra timer.
          if (_room.joined && _room.voiceReady) ...[
            const SizedBox(height: 6),
            InkWell(
              onTap: _confirmLeaveVoice,
              borderRadius: BorderRadius.circular(16),
              child: Container(
                width: 54,
                padding: const EdgeInsets.symmetric(vertical: 6),
                decoration: BoxDecoration(
                  color: const Color(0xFF081329).withValues(alpha: 0.85),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.greenAccent),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(width: 9, height: 9, decoration: const BoxDecoration(color: Colors.greenAccent, shape: BoxShape.circle)),
                    const SizedBox(height: 2),
                    const Text('Voice On', style: TextStyle(color: Colors.greenAccent, fontSize: 8, fontWeight: FontWeight.w800), textAlign: TextAlign.center),
                    const Text('Tap: leave', style: TextStyle(color: Color(0xFF7786A5), fontSize: 7, fontWeight: FontWeight.bold), textAlign: TextAlign.center),
                  ],
                ),
              ),
            ),
          ],
          // LIVEKIT TEST PATH: connected indicator for the SFU
          // session (mesh indicator above only covers VoiceRoom).
          if (_lkRoom.joined) ...[
            const SizedBox(height: 6),
            InkWell(
              onTap: _confirmLeaveVoiceLiveKit,
              borderRadius: BorderRadius.circular(16),
              child: Container(
                width: 54,
                padding: const EdgeInsets.symmetric(vertical: 6),
                decoration: BoxDecoration(
                  color: const Color(0xFF081329).withValues(alpha: 0.85),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.greenAccent),
                ),
                child: const Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(width: 9, height: 9, child: DecoratedBox(decoration: BoxDecoration(color: Colors.greenAccent, shape: BoxShape.circle))),
                    SizedBox(height: 2),
                    Text('LK Voice On', style: TextStyle(color: Colors.greenAccent, fontSize: 8, fontWeight: FontWeight.w800), textAlign: TextAlign.center),
                    Text('Tap: leave', style: TextStyle(color: Color(0xFF7786A5), fontSize: 7, fontWeight: FontWeight.bold), textAlign: TextAlign.center),
                  ],
                ),
              ),
            ),
          ],
          // MUSIC ON RAIL (2026-11-01 user order): Music moved
          // OUT of Settings onto the rail, REPLACING Tournament
          // Info here. _showRoomInfo stays in code but has no
          // rail entry anymore (user ordered it off the rail).
          // 2026-11-22 rail reorder: Music sits between the voice
          // indicators and Follow.
          const SizedBox(height: 6),
          _railBtn(Icons.music_note, 'Music',
              () => unawaited(_showRjVoiceConsole(initialSection: 'player'))),
          // RJ STUDIO VOICE CONSOLE (2026-11-22): room-host-only —
          // the live mic-chain console (echo/reverb/bass/gate/
          // compressor on the host's mic while live). Host =
          // admin / team captain / community organizer (FIX 20
          // fix 7b, same parity as music broadcast). Hidden for
          // listeners; Leave Room stays last.
          if (_isAdminForBroadcast ||
              _isTeamCaptainForBroadcast ||
              _isCommunityOrganizerForBroadcast) ...[
            const SizedBox(height: 6),
            _railBtn(Icons.graphic_eq, 'RJ Studio', _showRjVoiceConsole),
          ],
          // NEON REDESIGN floating button beside chat (mockup):
          // Follow (gold heart) ONLY — no Gift FAB, gifts stay
          // removed by user order; the Mic On FAB was removed by
          // user order 2026-11-22 (v2015). Follow toggles
          // following the host (same follows table as the chat
          // Follow pill). Mic toggle lives on the seat + the host
          // card's circular button.
          const SizedBox(height: 6),
          _railFab(
            Icons.favorite,
            'Follow',
            LinearGradient(colors: [kGold, kGoldDeep], begin: Alignment.topLeft, end: Alignment.bottomRight),
            kGold,
            () async {
              final myUid = FirebaseAuth.instance.currentUser?.uid ?? '';
              final hostUid = _adminUid.isNotEmpty ? _adminUid : '';
              if (myUid.isEmpty || hostUid.isEmpty || hostUid == myUid) {
                toast(context, hostUid == myUid ? 'Aap khud ko follow nahi kar sakte.' : 'Host follow ke liye room reload karen.');
                return;
              }
              try {
                if (_following.contains(hostUid)) {
                  await SupaDb.client.from('follows').delete().eq('follower_uid', myUid).eq('following_uid', hostUid);
                  setState(() => _following.remove(hostUid));
                  if (mounted) toast(context, 'Unfollowed host');
                } else {
                  await SupaDb.client.from('follows').insert({'follower_uid': myUid, 'following_uid': hostUid});
                  setState(() => _following.add(hostUid));
                  if (mounted) toast(context, 'Followed host');
                }
              } catch (e) {
                if (mounted) toast(context, 'Follow failed: $e');
              }
            },
            iconColor: Colors.black,
          ),
          // v2015 (user order 2026-11-22): the 'Mic On' rail FAB is
          // REMOVED — mic toggle lives on the seat + the host
          // card's circular button. Follow stays the only rail FAB.
          // LEAVE ROOM LAST (2026-11-22 user order): Leave Room
          // sits at the very bottom of the rail, below Follow —
          // it is the last item, never above the voice controls.
          const SizedBox(height: 6),
          _railBtn(Icons.exit_to_app, 'Leave Room', _confirmLeave),
        ],
      ),
        ),
    );
  }

  // Circular floating rail button (Follow only since v2015 — the
  // Mic On FAB was removed by user order 2026-11-22). Follow is
  // gold (2026-11-20 global gold).
  Widget _railFab(IconData icon, String label, Gradient gradient, Color glow, VoidCallback onTap, {Color iconColor = Colors.white}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(27),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: gradient,
              boxShadow: [BoxShadow(color: glow.withValues(alpha: 0.35), blurRadius: 10, spreadRadius: 1)],
            ),
            child: Icon(icon, color: iconColor, size: 22),
          ),
          const SizedBox(height: 3),
          Text(label, style: const TextStyle(color: Colors.white, fontSize: 8, fontWeight: FontWeight.w800, height: 1.2), textAlign: TextAlign.center),
        ],
      ),
    );
  }

  // Host panel data: tournament creator when known, else the first
  // voice peer, else nobody on voice yet. Never invents a host name.

  // PREMIUM REDESIGN (2026-11-21, visuals only): "Live Voice Chat"
  // row, sitting between the host panel and the seat stage.
  // Display only — counts derive from the peer map already in
  // scope. 2026-11-22 (user order): the scheduled-start date pill
  // ("Starts 21 Nov • 11:28 AM") is REMOVED from this strip — the
  // _roomStartLabel helper went with it.
  // v2016 FIX 7 (user order 2026-11-22): the whole 'LIVE VOICE
  // CHAT' stats section above the mics is GONE — the _voiceStrip
  // method (heading + 'N on voice • M mics on' pill + tournament
  // name) was deleted outright, not hidden. Its call site below
  // went with it.

  Map<String, dynamic>? _hostEntry(Map<String, dynamic>? t, List<MapEntry<String, Map<String, dynamic>>> occupied) {
    // FIX 23 item 17 (user order 2026-11-23, STRICT): the host
    // slot shows ONLY the scope organizer — community: the
    // creator (communities row / organizerUid param); team: the
    // captain (teams row / captainUid param); tournament: the
    // creator (tournaments.created_by) — and ONLY while they are
    // present in the room (in `occupied`, i.e. on voice). The
    // old always-admin preference and the first-peer fallback
    // are REMOVED: they put another member's (or the designated
    // admin's) photo in the host slot. No organizer present =
    // null: the strip shows 'No host' + an empty picture slot
    // (see _buildHostStrip) — never a placeholder face, never
    // another member's photo.
    final organizer = _isCommunity
        ? (_creatorUid.isNotEmpty ? _creatorUid : widget.organizerUid)
        : _isTeam
            ? (_creatorUid.isNotEmpty ? _creatorUid : widget.captainUid)
            : (t == null ? '' : strVal(t['created_by']));
    if (organizer.isEmpty) return null;
    for (final e in occupied) {
      if (e.key == organizer) return {'uid': e.key, 'name': (e.value['display_name'] ?? e.value['name'] ?? 'Player').toString(), 'muted': e.value['muted'] == true};
    }
    return null;
  }

  Widget _stageCellFree(int seatNo, int usable, bool joined) {
    return InkWell(
      onTap: () async {
        if (widget.spectator) { toast(context, 'Spectator mode — mics view-only hain.'); return; }
        if (_isRoomAdmin) { await _adminTakeMic(seatNo); return; }
        try {
          final locks = await SupaDb.getList('room_seat_locks', eqCol: 'room_id', eqVal: _voiceRoomId);
          if (locks.any((l) => SupaDb.intOf(l['seat_no']) == seatNo)) { toast(context, 'Mic $seatNo host ne lock kiya hua hai.'); return; }
        } catch (_) {}
        if (!joined) {
          if (_room.peers.length >= usable) { toast(context, 'All $usable mics are full — you can still chat and listen until a mic frees.'); return; }
          _joinVoiceOpen();
        } else {
          toast(context, 'Mic $seatNo is free — you are already on voice. Tap your own mic to mute or unmute.');
        }
      },
      borderRadius: BorderRadius.circular(12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // FIX 31b: the free-seat disc in the AI Studio podium
          // language — electric-blue frame + plus glyph (the
          // screen's empty-seat look) + the podium disc below.
          // Same 46px size, same tap behaviour, same number.
          Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                bottom: -8,
                left: -20,
                right: -20,
                child: CustomPaint(
                  size: const Size(86, 16),
                  painter: PodiumDiscPainter(outerColor: ArenaColors.electricBlue),
                ),
              ),
              Container(
                width: 42, height: 42,
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: ArenaColors.electricBlue, width: 2.2), boxShadow: [BoxShadow(color: ArenaColors.electricBlue.withValues(alpha: 0.35), blurRadius: 12, spreadRadius: 1)]),
                child: Container(
                  alignment: Alignment.center,
                  decoration: const BoxDecoration(shape: BoxShape.circle, color: ArenaColors.secondaryBg),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(LucideIcons.plus, color: ArenaColors.electricBlue, size: 13),
                      const SizedBox(height: 1),
                      // (v2016 FIX 6 pins this number's exact
                      // literal — do not tokenize it.)
                      Text('$seatNo', style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w900, height: 1.0, shadows: [Shadow(color: Color(0x80000000), blurRadius: 2, offset: Offset(0, 1))])),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _stageCellLocked(int seatNo) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // v2016 FIX 6: locked seats show their number too (dimmed
        // badge, top-left) — the slot picker and lock toasts refer
        // to mics by number, so the number must be visible.
        Stack(
          clipBehavior: Clip.none,
          children: [
            // FIX 31b: AI Studio tokens (purple frame, secondary
            // lock glyph). No podium disc: a locked cell is not
            // a live seat, and it never renders in embedded
            // (total == usable there).
            Container(
              width: 44, height: 44,
              decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white.withValues(alpha: 0.04), border: Border.all(color: ArenaColors.purple.withValues(alpha: 0.5), width: 1.5)),
              child: Icon(Icons.lock, color: ArenaColors.secondaryText, size: 16),
            ),
            Positioned(
              left: 0, top: 0,
              child: MicSeatNumberBadge(seatNo: seatNo, dimmed: true),
            ),
          ],
        ),
      ],
    );
  }

  Widget _stageCellListener(String name, String uid) {
    return InkWell(
      onTap: () => toast(context, '$name is listening (no mic).'),
      onLongPress: () { if (_isRoomAdmin) _showAdminMenu(uid, name); },
      borderRadius: BorderRadius.circular(12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // FIX 31b: same redesign in the AI Studio podium
          // language — electric-blue frame + the podium disc
          // below (the heart badge is gone: the screen has no
          // hearts). Name via tap toast + Participants sheet.
          Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                bottom: -8,
                left: -19,
                right: -19,
                child: CustomPaint(
                  size: const Size(86, 16),
                  painter: PodiumDiscPainter(outerColor: ArenaColors.electricBlue),
                ),
              ),
              Container(
                padding: const EdgeInsets.all(1.5),
                decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: ArenaColors.electricBlue.withValues(alpha: 0.7), width: 2.2)),
                child: _avatar(name, false, uid, 20),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _stageCellMore(int extra) {
    return InkWell(
      onTap: _openStatus,
      borderRadius: BorderRadius.circular(12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 44, height: 44,
            decoration: BoxDecoration(shape: BoxShape.circle, color: ArenaColors.secondaryBg, border: Border.all(color: ArenaColors.royalGold.withValues(alpha: 0.6), width: 1.5)),
            alignment: Alignment.center,
            child: Text('+$extra', style: ArenaTypography.body(14, color: ArenaColors.royalGold, weight: FontWeight.w800)),
          ),
        ],
      ),
    );
  }

  Future<void> _openFrames() async {
    final uid = FirebaseAuth.instance.currentUser!.uid;
    await Navigator.push(context, MaterialPageRoute(builder: (_) => const FramesShopPage()));
    FrameCache.invalidate(uid);
    if (mounted) setState(() {});
  }


  // ============ ADMIN-ONLY ROOM CONTROL (2026-10-30) ============
  // Identity: admin_config id=1 (admin app Setup) -> admin_firebase_uid.
  // Fail closed: if the row cannot be read, _isRoomAdmin stays false
  // and no admin menu is ever shown. The admin's own Firebase UID
  // must match; a profiles.is_admin chat badge is NOT enough.
  // Delivery to the target (no new table, no migration):
  //   * voice_signaling_inbox rows kind='admin_*' to the target UID
  //     (existing table, existing anon policy). Voice-joined targets
  //     get them via VoiceRoom.onAdminControl within ~2 s; targets
  //     NOT on voice get them via the 10 s _pollAdminEnforcement.
  //   * room_mutes (migration 011) for MUTE only: blocks chat send
  //     AND voice join at action time, and the poll forces mic-off.
  //   * voice_signaling_peers.muted=true for MIC OFF (chat untouched).
  //   * SharedPreferences flags on the TARGET's phone for mic-off /
  //     reject / kick persistence across restarts. A kick is only
  //     lifted by an admin_unkick row, which the target checks on
  //     its next room-entry attempt — so a kicked user cannot
  //     silently re-enter the same room, and clearing app data is
  //     the only bypass (stated honestly in the report).
  // v2016 FIX 11: keyed by the voice room id (tournament_/squad_/
  // community_) so team rooms each get their own key — the old
  // tournamentId key would have collapsed every team room into
  // one shared key (tournamentId is '' for team scope).
  String _adminPrefKey(String kind) => 'admin_${kind}_$_voiceRoomId';

  Future<void> _loadRoomAdmin() async {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    try {
      final rows = await SupaDb.getList('admin_config', eqCol: 'id', eqVal: 1);
      if (rows.isNotEmpty) _adminUid = SupaDb.strOf(rows.first['admin_firebase_uid']);
    } catch (_) {}
    // FIX 12 G8: in a COMMUNITY room the ORGANIZER (community
    // creator) is the room admin — not the designated app admin.
    // Runs BEFORE the profile fetch + _isRoomAdmin below, so the
    // organizer's name loads into _adminProfileName, _isRoomAdmin
    // is true for the organizer (mic-request approve/reject,
    // admin menu, broadcast gates all become organizer-scoped),
    // and mic requests go to the organizer (_sendMicRequest
    // targets _adminUid). Stated honestly: the designated app
    // admin has NO in-room powers in a community they do not
    // organize — their community powers stay in the admin panel.
    if (_isCommunity) {
      _adminUid = communityRoomAdminUid(organizerUid: widget.organizerUid, appAdminUid: _adminUid);
    }
    bool micOff = false, rejected = false, kicked = false;
    try {
      final prefs = await SharedPreferences.getInstance();
      micOff = prefs.getBool(_adminPrefKey('mic_off')) ?? false;
      rejected = prefs.getBool(_adminPrefKey('mic_rejected')) ?? false;
      kicked = prefs.getBool(_adminPrefKey('kicked')) ?? false;
    } catch (_) {}
    // The admin's profile name, for the admin-only surfaces
    // that address the admin by name (see _adminProfileName).
    // FIX 23 item 17: the HOST STRIP no longer shows the admin
    // — it shows only the scope organizer while present.
    String adminName = '';
    if (_adminUid.isNotEmpty) {
      try {
        final prof = await SupaDb.getProfile(_adminUid);
        adminName = SupaDb.strOf(prof['displayName']);
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _adminLoaded = true;
      _isRoomAdmin = uid.isNotEmpty && _adminUid.isNotEmpty && uid == _adminUid;
      _adminMicOffHeld = micOff;
      _adminMicRejected = rejected;
      _adminProfileName = adminName;
    });
    if (!kicked) return;
    // KICK RE-ENTRY GATE: a kicked user checks once for an
    // admin_unkick row before being blocked; otherwise they are
    // popped out of the room immediately, with a clear message.
    bool allowed = false;
    try {
      final rows = await SupaDb.getVoiceInbox(_voiceRoomId, uid);
      for (final r in rows) {
        if (SupaDb.strOf(r['kind']) == 'admin_unkick') {
          allowed = true;
          await SupaDb.voiceInboxDelete(SupaDb.strOf(r['id']));
        }
      }
    } catch (_) {}
    if (allowed) {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove(_adminPrefKey('kicked'));
      } catch (_) {}
      if (mounted) toast(context, 'Admin ne aapko wapas room me allow kar diya hai.');
      return;
    }
    if (mounted) {
      toast(context, 'Admin ne aapko is room se remove kiya hua hai — wapas entry sirf admin ki ijazat se hogi.');
      Navigator.pop(context);
    }
  }

  Future<void> _setAdminFlag(String kind, bool value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (value) {
        await prefs.setBool(_adminPrefKey(kind), true);
      } else {
        await prefs.remove(_adminPrefKey(kind));
      }
    } catch (_) {}
  }

  /// Applies one admin control on the TARGET's phone. Returns false
  /// when the sender is not the designated admin (row is then kept
  /// for a later poll, never silently dropped as "handled").
  Future<bool> _handleAdminControl(String kind, String fromUid) async {
    if (_adminUid.isEmpty || fromUid != _adminUid) return false;
    if (!mounted) return true;
    try {
      switch (kind) {
        case 'admin_mute':
          _adminMutedHeld = true;
          if (_room.joined && !_room.muted) await _room.setMuted(true);
          // LiveKit test path: same hold, applied to the SFU mic.
          // Delivery here is the 10 s presence poll (_pollAdminEn-
          // forcement), which runs whether or not the mesh is
          // joined — the mesh inbox poll alone would miss a
          // LiveKit-only target.
          if (_lkRoom.joined && !_lkRoom.muted) await _lkRoom.setMuted(true);
          if (mounted) toast(context, 'Admin ne aapka mic mute kar diya hai.');
          break;
        case 'admin_unmute':
          // ADMIN-RELEASE FIX (2026-10-30 user repro: approval +
          // admin unmute changed nothing): the old code only cleared
          // the in-memory flag and told the user to unmute themself
          // — it never unmuted the track, never cleared a mic-off
          // hold, and never updated the shared peer row, so B stayed
          // muted everywhere. A release now ACTUALLY unmutes.
          _adminMutedHeld = false;
          _adminMicOffHeld = false;
          await _setAdminFlag('mic_off', false);
          if (_room.joined) {
            await _room.setMuted(false);
            await _room.reapplySpeakerRoute();
          }
          if (_lkRoom.joined) {
            await _lkRoom.setMuted(false);
            await _lkRoom.reapplySpeakerRoute();
          }
          if (mounted) toast(context, 'Admin ne aapka mic unmute kar diya hai — mic live hai, speaker on hai.');
          break;
        case 'admin_mic_off':
          _adminMicOffHeld = true;
          await _setAdminFlag('mic_off', true);
          if (_room.joined && !_room.muted) await _room.setMuted(true);
          if (_lkRoom.joined && !_lkRoom.muted) await _lkRoom.setMuted(true);
          if (mounted) toast(context, 'Admin ne aapka mic OFF kar diya hai.');
          break;
        case 'admin_mic_on':
          // Same release fix as admin_unmute: the old code only
          // cleared the mic-off flag/pref while the track stayed
          // muted, the shared peer row stayed muted=true, and the
          // 10 s poll re-applied mute from any still-active
          // room_mutes row within seconds. A release now unmutes
          // the track, turns the speaker on, and clears both holds.
          _adminMicOffHeld = false;
          _adminMutedHeld = false;
          await _setAdminFlag('mic_off', false);
          if (_room.joined) {
            await _room.setMuted(false);
            await _room.reapplySpeakerRoute();
          }
          if (_lkRoom.joined) {
            await _lkRoom.setMuted(false);
            await _lkRoom.reapplySpeakerRoute();
          }
          if (mounted) toast(context, 'Admin ne aapka mic wapas ON kar diya hai — mic live hai, speaker on hai.');
          break;
        case 'admin_reject':
          _adminMicRejected = true;
          await _setAdminFlag('mic_rejected', true);
          if (_room.joined) await _room.leave();
          // Admin action, not a drop: no reconnect banner.
          _lkIntentionalDisconnect = true;
          try {
            if (_lkRoom.joined) await _lkRoom.disconnect();
          } finally {
            _lkIntentionalDisconnect = false;
          }
          _lkWasJoined = false;
          _lkDropped = false;
          if (mounted) toast(context, 'Admin ne aapka mic reject kar diya hai — mic nahi le sakte.');
          break;
        case 'admin_mic_allow':
          _adminMicRejected = false;
          await _setAdminFlag('mic_rejected', false);
          if (mounted) toast(context, 'Admin ne aapka mic allow kar diya hai.');
          break;
        case 'admin_mic_kick':
          _micApprovedUntil = null;
          _micApprovedSlot = null;
          if (_room.joined) await _room.leave();
          // Admin action, not a drop: no reconnect banner.
          _lkIntentionalDisconnect = true;
          try {
            if (_lkRoom.joined) await _lkRoom.disconnect();
          } finally {
            _lkIntentionalDisconnect = false;
          }
          _lkWasJoined = false;
          _lkDropped = false;
          if (mounted) toast(context, 'Admin ne aapko mic se hata diya hai — slot khali ho gaya hai.');
          break;
        case 'admin_kick':
          await _setAdminFlag('kicked', true);
          if (mounted) toast(context, 'Admin ne aapko is room se remove kar diya hai.');
          await _exitRoom();
          break;
        case 'admin_unkick':
          await _setAdminFlag('kicked', false);
          if (mounted) toast(context, 'Admin ne aapko wapas room me allow kar diya hai.');
          break;
        default:
          return false;
      }
    } catch (_) {}
    if (mounted) setState(() {});
    return true;
  }

  /// 10 s enforcement poll (called from _checkPresenceWelcomes).
  /// Never throws, never blocks presence.
  Future<void> _pollAdminEnforcement() async {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    if (uid.isEmpty || !mounted) return;
    // v2016 FIX 11: room_mutes is keyed by tournament_id — team
    // rooms have no row there, so the live inbox signal below is
    // the only enforcement (session mute, not persistent).
    // FIX 12 G6: same for community rooms.
    if (!_isTeam && !_isCommunity) {
      try {
        final mutes = await SupaDb.getList('room_mutes', eqCol: 'tournament_id', eqVal: widget.tournamentId, eqCol2: 'firebase_uid', eqVal2: uid);
        if (mutes.any((m) => m['active'] == true)) {
          _adminMutedHeld = true;
          if (_room.joined && !_room.muted) {
            try { await _room.setMuted(true); } catch (_) {}
          }
          if (_lkRoom.joined && !_lkRoom.muted) {
            try { await _lkRoom.setMuted(true); } catch (_) {}
          }
        }
      } catch (_) {}
    }
    try {
      final rows = await SupaDb.getVoiceInbox(_voiceRoomId, uid);
      for (final r in rows) {
        final kind = SupaDb.strOf(r['kind']);
        final from = SupaDb.strOf(r['from_firebase_uid']);
        if (kind.startsWith('admin_')) {
          final handled = await _handleAdminControl(kind, from);
          if (handled) await SupaDb.voiceInboxDelete(SupaDb.strOf(r['id']));
        } else if (kind.startsWith('mic_')) {
          // Stale mic requests (>10 min old) are dropped silently:
          // an admin opening the room hours later must not see
          // yesterday's requests as if they were live.
          if (kind == 'mic_request') {
            final ts = SupaDb.parseTs(r['created_at']);
            if (ts > 0 && DateTime.now().millisecondsSinceEpoch - ts > 10 * 60 * 1000) {
              await SupaDb.voiceInboxDelete(SupaDb.strOf(r['id']));
              continue;
            }
          }
          final handled = await _handleMicSignal(kind, from, SupaDb.strOf(r['sdp']));
          if (handled) await SupaDb.voiceInboxDelete(SupaDb.strOf(r['id']));
        } else if (kind.startsWith('music_')) {
          // Same stale-drop + delivery as mic requests.
          if (kind == 'music_request') {
            final ts = SupaDb.parseTs(r['created_at']);
            if (ts > 0 && DateTime.now().millisecondsSinceEpoch - ts > 10 * 60 * 1000) {
              await SupaDb.voiceInboxDelete(SupaDb.strOf(r['id']));
              continue;
            }
          }
          final handled = await _handleMusicSignal(kind, from, SupaDb.strOf(r['sdp']));
          if (handled) await SupaDb.voiceInboxDelete(SupaDb.strOf(r['id']));
        }
        if (!mounted) return;
      }
    } catch (_) {}
  }

  Future<void> _sendAdminControl(String targetUid, String kind, {String? sdp}) async {
    final myUid = FirebaseAuth.instance.currentUser?.uid ?? '';
    await SupaDb.voiceInboxSend(_voiceRoomId, targetUid, myUid, {'kind': kind, if (sdp != null) 'sdp': sdp});
  }

  bool _adminGuard() {
    if (_isRoomAdmin) return true;
    if (mounted) toast(context, 'Ye control sirf room admin use kar sakta hai.');
    return false;
  }

  Future<void> _adminMute(String targetUid, String name) async {
    if (!_adminGuard()) return;
    try {
      // v2016 FIX 11: room_mutes is tournament-keyed — team rooms
      // skip the persistent record; the live peer update + admin
      // signal below still mute the user for this session.
      // FIX 12 G6: same for community rooms (a '' tournament_id
      // row would block every team/community join — see
      // _joinVoiceOpen's mute check).
      if (!_isTeam && !_isCommunity) {
        await SupaDb.client.from('room_mutes').delete().eq('tournament_id', widget.tournamentId).eq('firebase_uid', targetUid);
        await SupaDb.client.from('room_mutes').insert({'tournament_id': widget.tournamentId, 'firebase_uid': targetUid, 'muted_by': FirebaseAuth.instance.currentUser?.uid ?? '', 'reason': 'admin_mute', 'active': true});
      }
      await SupaDb.client.from('voice_signaling_peers').update({'muted': true}).eq('room_id', _voiceRoomId).eq('firebase_uid', targetUid);
      await _sendAdminControl(targetUid, 'admin_mute');
      if (mounted) toast(context, '$name mute ho gaya (admin mute — khud unmute nahi kar sakega).');
    } catch (e) {
      if (mounted) toast(context, 'Mute failed: $e');
    }
  }

  Future<void> _adminUnmute(String targetUid, String name) async {
    if (!_adminGuard()) return;
    try {
      // v2016 FIX 11: no persistent mute record exists for team
      // rooms (see _adminMute) — the live signal below is enough.
      // FIX 12 G6: same for community rooms.
      if (!_isTeam && !_isCommunity) {
        await SupaDb.client.from('room_mutes').update({'active': false}).eq('tournament_id', widget.tournamentId).eq('firebase_uid', targetUid);
      }
      await SupaDb.client.from('voice_signaling_peers').update({'muted': false}).eq('room_id', _voiceRoomId).eq('firebase_uid', targetUid);
      await _sendAdminControl(targetUid, 'admin_unmute');
      if (mounted) toast(context, '$name unmute ho gaya.');
    } catch (e) {
      if (mounted) toast(context, 'Unmute failed: $e');
    }
  }

  Future<void> _adminMicOff(String targetUid, String name) async {
    if (!_adminGuard()) return;
    try {
      await SupaDb.client.from('voice_signaling_peers').update({'muted': true}).eq('room_id', _voiceRoomId).eq('firebase_uid', targetUid);
      await _sendAdminControl(targetUid, 'admin_mic_off');
      if (mounted) toast(context, '$name ka mic OFF kar diya (chat band nahi hui).');
    } catch (e) {
      if (mounted) toast(context, 'Mic off failed: $e');
    }
  }

  Future<void> _adminMicOn(String targetUid, String name) async {
    if (!_adminGuard()) return;
    try {
      // Mic On is a full release, like Unmute: the old code sent only
      // the inbox row, so a still-active room_mutes row made the 10 s
      // poll re-mute the target within seconds of any manual unmute,
      // and the shared peer row stayed muted=true. Clear both now.
      await SupaDb.client.from('room_mutes').update({'active': false}).eq('tournament_id', widget.tournamentId).eq('firebase_uid', targetUid);
      await SupaDb.client.from('voice_signaling_peers').update({'muted': false}).eq('room_id', _voiceRoomId).eq('firebase_uid', targetUid);
      await _sendAdminControl(targetUid, 'admin_mic_on');
      if (mounted) toast(context, '$name ka mic wapas ON kar diya.');
    } catch (e) {
      if (mounted) toast(context, 'Mic on failed: $e');
    }
  }

  Future<void> _adminReject(String targetUid, String name) async {
    if (!_adminGuard()) return;
    try {
      await SupaDb.client.from('voice_signaling_peers').delete().eq('room_id', _voiceRoomId).eq('firebase_uid', targetUid);
      await _sendAdminControl(targetUid, 'admin_reject');
      if (mounted) toast(context, '$name ka mic reject kar diya — wo mic nahi le sakega (chat chalegi).');
    } catch (e) {
      if (mounted) toast(context, 'Reject failed: $e');
    }
  }

  Future<void> _adminAllowMic(String targetUid, String name) async {
    if (!_adminGuard()) return;
    try {
      await _sendAdminControl(targetUid, 'admin_mic_allow');
      if (mounted) toast(context, '$name ka mic allow kar diya.');
    } catch (e) {
      if (mounted) toast(context, 'Allow failed: $e');
    }
  }

  Future<void> _adminKick(String targetUid, String name) async {
    if (!_adminGuard()) return;
    try {
      await SupaDb.client.from('voice_signaling_peers').delete().eq('room_id', _voiceRoomId).eq('firebase_uid', targetUid);
      await _sendAdminControl(targetUid, 'admin_kick');
      try {
        await SupaDb.client.from('user_warnings').insert({'firebase_uid': targetUid, 'type': 'room_kick', 'reason': 'Removed from room ${widget.tournamentId} by admin', 'by_admin': FirebaseAuth.instance.currentUser?.uid ?? ''});
      } catch (_) {}
      if (mounted) toast(context, '$name ko room se remove kar diya — wapas entry sirf admin ki ijazat se hogi.');
    } catch (e) {
      if (mounted) toast(context, 'Remove failed: $e');
    }
  }

  Future<void> _adminUnkick(String targetUid, String name) async {
    if (!_adminGuard()) return;
    try {
      await _sendAdminControl(targetUid, 'admin_unkick');
      if (mounted) toast(context, '$name ko wapas room me allow kar diya.');
    } catch (e) {
      if (mounted) toast(context, 'Allow back failed: $e');
    }
  }


  // ============ MIC REQUEST / APPROVAL (2026-10-30) ============
  // Transport: voice_signaling_inbox (existing table, existing anon
  // policy) — requester -> admin: 'mic_request'; admin -> requester:
  // 'mic_approved' / 'mic_rejected'; requester -> admin:
  // 'mic_request_cancel'. Voice-joined phones get them within ~2 s
  // via VoiceRoom.onMicSignal; phones not on voice get them via the
  // 10 s _pollAdminEnforcement. Nothing is local-only: the admin on
  // a different phone sees the request, and the requester on a
  // different phone gets the approval. Approval: 2 minutes from
  // receipt, single-use (consumed on a successful voice join).
  // Requests: 10 minutes stale-drop (poll path). While waiting, the
  // requester sees the waiting banner + Cancel; tapping Take Mic
  // again while pending only re-toasts, never joins.
  // FIX 12 G8: the mic-request approver is the ORGANIZER in a
  // community room, the admin everywhere else — toasts say so.
  String get _approverWord => _isCommunity ? 'organizer' : 'admin';
  String get _approverWordCap => _isCommunity ? 'Organizer' : 'Admin';

  Future<void> _sendMicRequest() async {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    if (_adminUid.isEmpty) {
      if (mounted) toast(context, '$_approverWordCap ka pata nahi chal raha — thodi der me dobara try karen.');
      return;
    }
    if (_micRequestPending) {
      if (mounted) toast(context, 'Mic request pehle se pending hai — $_approverWord ke jawab ka intezar karen.');
      return;
    }
    try {
      await SupaDb.voiceInboxSend(_voiceRoomId, _adminUid, uid, {'kind': 'mic_request'});
      _micRequestPending = true;
      if (mounted) {
        toast(context, 'Mic request $_approverWord ko bhej di hai — approval ka intezar karen.');
        setState(() {});
      }
    } catch (e) {
      if (mounted) toast(context, 'Request failed: $e');
    }
  }

  Future<void> _cancelMicRequest() async {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    _micRequestPending = false;
    if (mounted) setState(() {});
    try {
      if (_adminUid.isNotEmpty) await SupaDb.voiceInboxSend(_voiceRoomId, _adminUid, uid, {'kind': 'mic_request_cancel'});
    } catch (_) {}
    if (mounted) toast(context, 'Mic request cancel kar di hai.');
  }

  Future<bool> _handleMicSignal(String kind, String fromUid, String sdp) async {
    switch (kind) {
      case 'mic_request':
        if (!_isRoomAdmin) return false;
        if (_micRequests.any((r) => r['uid'] == fromUid)) return true;
        final peerName = _room.peers[fromUid] == null ? '' : SupaDb.strOf(_room.peers[fromUid]!['display_name']);
        final name = peerName.isNotEmpty ? peerName : (_roomRegNames[fromUid] ?? 'A player');
        if (mounted) {
          setState(() => _micRequests.add({'uid': fromUid, 'name': name}));
          toast(context, '$name ne mic request bheji hai.');
        }
        // REQUEST NOTIFICATION (2026-10-30 user order): a new
        // request must be unmissable — alert sound + vibration on
        // top of the banner, not the quiet banner alone. The banner
        // itself stays until the admin approves/rejects.
        try { await SoundService.message(); } catch (_) {}
        try { HapticFeedback.vibrate(); } catch (_) {}
        return true;
      case 'mic_request_cancel':
        if (!_isRoomAdmin) return false;
        if (mounted) setState(() => _micRequests.removeWhere((r) => r['uid'] == fromUid));
        return true;
      case 'mic_approved':
        if (_adminUid.isEmpty || fromUid != _adminUid) return false;
        // Approval supersedes stale mic holds from an earlier
        // session (persisted mic_off flag / in-memory mute hold):
        // the admin just approved this user, so a leftover hold
        // must not keep blocking their seat toggle after joining.
        _adminMutedHeld = false;
        _adminMicOffHeld = false;
        await _setAdminFlag('mic_off', false);
        // Approval also supersedes a stale reject: a user rejected
        // in an earlier session and then approved must not stay
        // blocked by _joinVoiceOpen's reject gate.
        _adminMicRejected = false;
        await _setAdminFlag('mic_rejected', false);
        _micApprovedSlot = parseApprovedMicSlot(sdp);
        _micApprovedUntil = DateTime.now().add(const Duration(minutes: 2));
        _micRequestPending = false;
        if (mounted) {
          toast(context, _micApprovedSlot == null ? '$_approverWordCap ne aapka mic APPROVE kar diya hai — 2 minute me apna number wala circle dabao.' : '$_approverWordCap ne aapko Mic $_micApprovedSlot diya hai — 2 minute me $_micApprovedSlot number wala circle dabao, tum usi par aaoge.');
          setState(() {});
        }
        return true;
      case 'mic_rejected':
        if (_adminUid.isEmpty || fromUid != _adminUid) return false;
        _micApprovedUntil = null;
        _micApprovedSlot = null;
        _micRequestPending = false;
        if (mounted) {
          toast(context, '$_approverWordCap ne aapka mic reject kar diya hai.');
          setState(() {});
        }
        return true;
      default:
        return false;
    }
  }

  Future<void> _rejectMicRequest(String targetUid, String name) async {
    if (!_adminGuard()) return;
    try {
      await _sendAdminControl(targetUid, 'mic_rejected');
      if (mounted) {
        setState(() => _micRequests.removeWhere((r) => r['uid'] == targetUid));
        toast(context, '$name ka mic reject kar diya.');
      }
    } catch (e) {
      if (mounted) toast(context, 'Reject failed: $e');
    }
  }


  // ============ MUSIC-STREAM REQUEST / APPROVAL (2026-10-30) ============
  // Mirrors mic requests: requester -> admin 'music_request' (inbox),
  // admin -> requester 'music_approved' / 'music_rejected' / 'music_revoked',
  // requester -> admin 'music_request_cancel'. Delivery: voice-joined
  // phones via VoiceRoom.onMusicSignal (~2 s), others via the 10 s
  // _pollAdminEnforcement. Approval ALSO writes a hidden
  // MUSIC_APPROVAL:: chat row so EVERY listener can enforce it (see
  // _handleMusicRows) — the inbox row alone only reaches the
  // requester, not the listeners who must refuse unapproved play.
  Future<void> _sendMusicRequest() async {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    if (_adminUid.isEmpty) {
      if (mounted) toast(context, 'Admin ka pata nahi chal raha — thodi der me dobara try karen.');
      return;
    }
    if (_musicRequestPending) {
      if (mounted) toast(context, 'Music request pehle se pending hai — admin ke jawab ka intezar karen.');
      return;
    }
    try {
      await SupaDb.voiceInboxSend(_voiceRoomId, _adminUid, uid, {'kind': 'music_request'});
      _musicRequestPending = true;
      if (mounted) {
        toast(context, 'Music-stream request admin ko bhej di hai — approval ka intezar karen.');
        setState(() {});
      }
    } catch (e) {
      if (mounted) toast(context, 'Music request failed: $e');
    }
  }

  Future<void> _cancelMusicRequest() async {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    _musicRequestPending = false;
    if (mounted) setState(() {});
    try {
      if (_adminUid.isNotEmpty) await SupaDb.voiceInboxSend(_voiceRoomId, _adminUid, uid, {'kind': 'music_request_cancel'});
    } catch (_) {}
    if (mounted) toast(context, 'Music request cancel kar di hai.');
  }

  Future<void> _sendMusicApprovalRow(String targetUid, String action) async {
    try {
      final user = FirebaseAuth.instance.currentUser!;
      final profile = await SupaDb.getProfile(user.uid);
      await SupaDb.sendChat(
        scope: widget.scope,
        scopeId: _chatScopeId,
        uid: user.uid,
        displayName: strVal(profile['displayName'], user.email ?? 'User'),
        message: '$_musicApprovalPrefix${jsonEncode({'uid': targetUid, 'action': action})}',
      );
    } catch (_) {}
  }

  Future<bool> _handleMusicSignal(String kind, String fromUid, String sdp) async {
    switch (kind) {
      case 'music_request':
        if (!_isRoomAdmin) return false;
        if (_musicRequests.any((r) => r['uid'] == fromUid)) return true;
        final peerName = _room.peers[fromUid] == null ? '' : SupaDb.strOf(_room.peers[fromUid]!['display_name']);
        final name = peerName.isNotEmpty ? peerName : (_roomRegNames[fromUid] ?? 'A player');
        if (mounted) {
          setState(() => _musicRequests.add({'uid': fromUid, 'name': name}));
          toast(context, '$name ne music-stream request bheji hai.');
        }
        try { await SoundService.message(); } catch (_) {}
        try { HapticFeedback.vibrate(); } catch (_) {}
        return true;
      case 'music_request_cancel':
        if (!_isRoomAdmin) return false;
        if (mounted) setState(() => _musicRequests.removeWhere((r) => r['uid'] == fromUid));
        return true;
      case 'music_approved':
        if (_adminUid.isEmpty || fromUid != _adminUid) return false;
        _musicApproved = true;
        _musicRequestPending = false;
        if (mounted) {
          toast(context, 'Admin ne aapka music stream APPROVE kar diya hai — ab broadcast kar sakte ho.');
          setState(() {});
        }
        return true;
      case 'music_rejected':
        if (_adminUid.isEmpty || fromUid != _adminUid) return false;
        _musicApproved = false;
        _musicRequestPending = false;
        if (mounted) {
          toast(context, 'Admin ne aapka music stream reject kar diya hai.');
          setState(() {});
        }
        return true;
      case 'music_revoked':
        if (_adminUid.isEmpty || fromUid != _adminUid) return false;
        final wasStreaming = _musicApproved;
        _musicApproved = false;
        _musicRequestPending = false;
        if (wasStreaming && _sharedSession != null) {
          // Stop my own broadcast for everyone (stop row) + local.
          await _stopMusic();
        }
        if (mounted) {
          toast(context, 'Admin ne aapka music stream rok diya hai.');
          setState(() {});
        }
        return true;
      default:
        return false;
    }
  }

  Future<void> _approveMusicRequest(String targetUid, String name) async {
    if (!_adminGuard()) return;
    try {
      await SupaDb.voiceInboxSend(_voiceRoomId, targetUid, FirebaseAuth.instance.currentUser!.uid, {'kind': 'music_approved'});
      await _sendMusicApprovalRow(targetUid, 'approved');
      if (mounted) {
        setState(() => _musicRequests.removeWhere((r) => r['uid'] == targetUid));
        toast(context, '$name ko music stream de diya hai.');
      }
    } catch (e) {
      if (mounted) toast(context, 'Music approve failed: $e');
    }
  }

  Future<void> _rejectMusicRequest(String targetUid, String name) async {
    if (!_adminGuard()) return;
    try {
      await SupaDb.voiceInboxSend(_voiceRoomId, targetUid, FirebaseAuth.instance.currentUser!.uid, {'kind': 'music_rejected'});
      if (mounted) {
        setState(() => _musicRequests.removeWhere((r) => r['uid'] == targetUid));
        toast(context, '$name ka music stream reject kar diya.');
      }
    } catch (e) {
      if (mounted) toast(context, 'Music reject failed: $e');
    }
  }

  /// Admin stops an approved stream at any time: the streamer is
  /// told directly (inbox) and every listener is told via a hidden
  /// revoke row, so playback stops on all phones, not just the
  /// admin's.
  Future<void> _revokeMusicStream(String targetUid, String name) async {
    if (!_adminGuard()) return;
    try {
      await SupaDb.voiceInboxSend(_voiceRoomId, targetUid, FirebaseAuth.instance.currentUser!.uid, {'kind': 'music_revoked'});
      await _sendMusicApprovalRow(targetUid, 'revoked');
      if (mounted) {
        setState(() => _musicApprovedStreamers.remove(targetUid));
        toast(context, '$name ka music stream rok diya hai.');
      }
    } catch (e) {
      if (mounted) toast(context, 'Music revoke failed: $e');
    }
  }

  void _showMusicRequestsSheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: kCardPurpleMid,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22)), side: const BorderSide(color: kCardPurpleBorder, width: 1.5)),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 10),
            Container(width: 40, height: 4, decoration: BoxDecoration(color: const Color(0xFF7786A5), borderRadius: BorderRadius.circular(2))),
            const Padding(padding: EdgeInsets.fromLTRB(16, 12, 16, 4), child: Align(alignment: Alignment.centerLeft, child: Text('Music-stream requests', style: TextStyle(color: Color(0xFFFDC903), fontWeight: FontWeight.bold, fontSize: 16)))),
            if (_musicRequests.isEmpty) const Padding(padding: EdgeInsets.all(16), child: Text('Koi pending music request nahi hai.', style: TextStyle(color: Color(0xFF7786A5)))),
            for (final r in List<Map<String, String>>.from(_musicRequests))
              ListTile(
                leading: const Icon(Icons.music_note, color: Color(0xFFFDC903)),
                title: Text(r['name'] ?? 'Player', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextButton(onPressed: () async { Navigator.pop(ctx); await _approveMusicRequest(r['uid'] ?? '', r['name'] ?? 'Player'); }, child: const Text('Approve', style: TextStyle(color: Color(0xFF16D879), fontWeight: FontWeight.bold))),
                    TextButton(onPressed: () async { Navigator.pop(ctx); await _rejectMusicRequest(r['uid'] ?? '', r['name'] ?? 'Player'); }, child: const Text('Reject', style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold))),
                  ],
                ),
              ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  // ============ ADMIN SLOT CHOICE + MIC KICK (2026-10-30) ============
  // Slot math mirrors the grid placement below: assigned seat_no
  // cells are taken first, then unassigned peers fill the earliest
  // free mic cells in join order. _takenMicSlots() therefore returns
  // exactly the cells the grid will render as occupied.
  // v2016 FIX 11: team rooms use the parameterized mic count
  // (6 seats — FIX 12 G5: no type distinction) — never the
  // tournament 9.
  int _usableMicCount() => _isTeam ? _teamMicCount : _isCommunity ? _communityMicCount : _isSquad ? _squadCapacity : (widget.maxPlayers > 0 ? (widget.maxPlayers < 9 ? widget.maxPlayers : 9) : 9);

  Set<int> _takenMicSlots() {
    final usable = _usableMicCount();
    final taken = <int>{};
    var unassigned = 0;
    for (final e in _room.peers.entries) {
      final sn = SupaDb.intOf(e.value['seat_no']);
      if (sn >= 1 && sn <= usable && !taken.contains(sn)) {
        taken.add(sn);
      } else {
        unassigned++;
      }
    }
    final free = [for (var c = 1; c <= usable; c++) if (!taken.contains(c)) c];
    for (var k = 0; k < unassigned && k < free.length; k++) taken.add(free[k]);
    return taken;
  }

  /// Slot picker dialog: only free slots are tappable; taken slots
  /// show disabled with 'Taken'. Returns null on Cancel/dismiss.
  Future<int?> _pickMicSlotDialog({required int preselected, required String forName}) async {
    final usable = _usableMicCount();
    final taken = _takenMicSlots();
    var initial = preselected;
    if (initial < 1 || initial > usable || taken.contains(initial)) {
      final freeSlots = [for (var c = 1; c <= usable; c++) if (!taken.contains(c)) c];
      initial = freeSlots.isEmpty ? -1 : freeSlots.first;
    }
    if (initial < 0) {
      if (mounted) toast(context, 'Koi mic slot khali nahi hai.');
      return null;
    }
    return showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kCardPurpleMid,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22), side: const BorderSide(color: kCardPurpleBorder, width: 1.5)),
        title: Text('Mic slot chuno — $forName', style: const TextStyle(color: Color(0xFFFDC903), fontWeight: FontWeight.bold, fontSize: 16)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var c = 1; c <= usable; c++)
                ListTile(
                  enabled: !taken.contains(c),
                  leading: Icon(taken.contains(c) ? Icons.lock : Icons.mic, color: taken.contains(c) ? const Color(0xFF7786A5) : const Color(0xFFFDC903)),
                  title: Text('Mic $c${c == initial ? ' (suggested)' : ''}', style: TextStyle(color: taken.contains(c) ? const Color(0xFF7786A5) : Colors.white, fontWeight: FontWeight.bold)),
                  trailing: taken.contains(c) ? const Text('Taken', style: TextStyle(color: Color(0xFF7786A5))) : null,
                  onTap: taken.contains(c) ? null : () => Navigator.pop(ctx, c),
                ),
            ],
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel', style: TextStyle(color: Color(0xFF7786A5))))],
      ),
    );
  }

  /// Admin approves a pending request WITH a slot of their choice.
  /// The slot travels in the approval inbox row's sdp payload
  /// ('mic_slot:N'); the requester's join then carries seat_no so
  /// every phone renders them in exactly that cell (migration 013;
  /// pre-migration fallback is join-order placement).
  Future<void> _approveWithSlot(String targetUid, String name) async {
    if (!_adminGuard()) return;
    final taken = _takenMicSlots();
    final usable = _usableMicCount();
    // FIX 12 G8: firstFreeMicSlot is the single source for the
    // first free seat (null = full) — the old taken.length guard
    // and the inline list comp said the same thing twice.
    final firstFree = firstFreeMicSlot(taken, usable);
    if (firstFree == null) {
      if (mounted) toast(context, 'Koi mic slot khali nahi hai — pehle kisi ko mic se hatao.');
      return;
    }
    final slot = await _pickMicSlotDialog(preselected: firstFree, forName: name);
    if (slot == null) return;
    await _approveMicRequest(targetUid, name, slot);
  }

  Future<void> _approveMicRequest(String targetUid, String name, int slot) async {
    if (!_adminGuard()) return;
    try {
      // Approval must not be vetoed by a stale mute: _joinVoiceOpen
      // blocks voice join outright while an active room_mutes row
      // exists, so a previously muted user could never use a fresh
      // approval. Clearing the row here is the approval itself.
      // v2016 FIX 11: team rooms have no room_mutes rows to clear.
      // FIX 12 G6: same for community rooms.
      if (!_isTeam && !_isCommunity) {
        await SupaDb.client.from('room_mutes').update({'active': false}).eq('tournament_id', widget.tournamentId).eq('firebase_uid', targetUid);
      }
      await _sendAdminControl(targetUid, 'mic_approved', sdp: micSlotPayload(slot));
      // LIVEKIT TEST PATH: the same approval also writes a
      // server-side grant the token function can verify (and
      // consume on mint). Best-effort: if migration 015 is not
      // applied yet this silently does nothing and the token
      // function fail-closes non-admins to listen-only — the
      // approval itself is never blocked by this write.
      await LiveKitConfig.writeMicGrant(_voiceRoomId, targetUid);
      if (mounted) {
        setState(() => _micRequests.removeWhere((r) => r['uid'] == targetUid));
        toast(context, '$name ko Mic $slot de diya hai (2 minute ke liye).');
      }
    } catch (e) {
      if (mounted) toast(context, 'Approve failed: $e');
    }
  }

  /// KICK OFF MIC (distinct from Remove-from-Room): the target
  /// leaves voice and the slot frees for reassignment, but they
  /// STAY in the room (chat keeps working) and may request again.
  /// No reject flag is set, so this never blocks a fresh request.
  Future<void> _adminMicKick(String targetUid, String name) async {
    if (!_adminGuard()) return;
    try {
      await SupaDb.client.from('voice_signaling_peers').delete().eq('room_id', _voiceRoomId).eq('firebase_uid', targetUid);
      await _sendAdminControl(targetUid, 'admin_mic_kick');
      if (mounted) toast(context, '$name ko mic se hata diya — Mic slot dobara khali hai.');
    } catch (e) {
      if (mounted) toast(context, 'Mic kick failed: $e');
    }
  }

  /// Admin takes a mic themself, choosing any free slot 1..usable.
  /// Bypasses the request gate (admin needs no approval) and any
  /// host seat-lock (admin authority supersedes host locks).
  Future<void> _adminTakeMic(int seatNo) async {
    if (!mounted) return;
    if (_room.joined) {
      if (mounted) toast(context, 'Aap pehle se voice par hain — apni seat se mute/unmute karen.');
      return;
    }
    final slot = await _pickMicSlotDialog(preselected: seatNo, forName: 'Aap (Admin)');
    if (slot == null) return;
    _room.assignedSeat = slot;
    await _joinVoiceOpen();
  }

  void _showMicRequestsSheet() {
    if (!_isRoomAdmin) return;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: kCardPurpleMid,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22)), side: const BorderSide(color: kCardPurpleBorder, width: 1.5)),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 10),
              Container(width: 40, height: 4, decoration: BoxDecoration(color: const Color(0xFF7786A5), borderRadius: BorderRadius.circular(2))),
              const Padding(padding: EdgeInsets.fromLTRB(16, 12, 16, 4), child: Align(alignment: Alignment.centerLeft, child: Text('Mic Requests', style: TextStyle(color: Color(0xFFFDC903), fontWeight: FontWeight.bold, fontSize: 16)))),
              if (_micRequests.isEmpty) const Padding(padding: EdgeInsets.all(16), child: Text('Koi pending mic request nahi hai.', style: TextStyle(color: Color(0xFF7786A5)))),
              for (final r in List<Map<String, String>>.from(_micRequests))
                ListTile(
                  leading: const Icon(Icons.mic, color: Color(0xFFFDC903)),
                  title: Text(r['name'] ?? 'Player', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextButton(onPressed: () async { Navigator.pop(ctx); await _approveWithSlot(r['uid'] ?? '', r['name'] ?? 'Player'); }, child: const Text('Approve', style: TextStyle(color: Color(0xFF16D879), fontWeight: FontWeight.bold))),
                      TextButton(onPressed: () async { Navigator.pop(ctx); await _rejectMicRequest(r['uid'] ?? '', r['name'] ?? 'Player'); }, child: const Text('Reject', style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold))),
                    ],
                  ),
                ),
              const SizedBox(height: 12),
            ],
          ),
        );
      },
    );
  }

  /// ADMIN CLEAR CHAT (2026-10-30 user order): admin-only, with
  /// confirmation. Deletes this room's chat_messages rows for
  /// EVERYONE (not just locally): all rows except MUSIC session
  /// rows and MUSIC_APPROVAL rows (clearing chat must not kill a
  /// live music session or its approvals). FIX 22 item 23: NO
  /// marker row is written anymore (the old hidden
  /// CHAT_CLEARED marker accumulated forever — the delete
  /// filter skipped it — and rendered as a sticky organizer
  /// message in community chat, which has no marker filter).
  /// Old markers ARE deleted by the clear now (no prefix skip).
  /// The toast below IS the one-time notification (~2s, then
  /// gone, never again). Other phones learn about the clear
  /// from the empty stream (_handleChatEmptied). New messages
  /// after a clear insert normally.
  // PHASE 3 #27 MESSAGE LONG-PRESS MENU: Report Message for every member
  // (own messages excluded — you cannot report yourself), plus the
  // whole-room Clear Chat entry for the admin only (same guarded
  // _clearChat + confirmation as before; the old admin-only
  // _showChatLongPressMenu is folded in here so the menu has one home).
  /// BATCH 3B #21 INVITE from the squad room: the squad room has no
  /// team row in scope (squadId is the derived squad key built from
  /// the tournament id plus the team name, not a teams.id), so
  /// resolve the caller's team exactly like the community chat does
  /// (getMyFirstTeam) and open the shared username dialog ->
  /// existing SupaDb.sendTeamInvite. No new RPC/table. Squad scope
  /// only — the rail button is hidden otherwise (see _navRail).
  Future<void> _inviteFromChat() async {
    final myUid = FirebaseAuth.instance.currentUser?.uid ?? '';
    if (myUid.isEmpty) {
      toast(context, 'Invite ke liye sign-in zaroori hai.');
      return;
    }
    final team = await SupaDb.getMyFirstTeam(myUid);
    if (!mounted) return;
    final teamId = SupaDb.strOf(team['id']);
    if (teamId.isEmpty) {
      toast(context, 'Pehle team banayen — invite ke liye team zaroori hai.');
      return;
    }
    final sent = await showChatTeamInviteDialog(
      context: context,
      myUid: myUid,
      teamId: teamId,
      teamName: SupaDb.strOf(team['name'], 'Your team'),
      inviteCode: SupaDb.strOf(team['invite_code']),
    );
    if (sent && mounted) toast(context, 'Invitation bhej di!');
  }

  /// BATCH 3B #27 ADMIN PIN/UNPIN (room): designated admin only
  /// (_isRoomAdmin, fail-closed). Pin writes a pinned_messages row
  /// (tournament_id, message, pinned_by) — the banner above the
  /// chat already reads the latest row, so pinning a new message
  /// supersedes the old one. Unpin deletes the pinned row. Photo-only
  /// messages cannot pin (the row carries text only). setState
  /// rebuilds the banner's FutureBuilder so the change shows at once.
  Future<void> _pinChatMessage(Map<String, dynamic> m, {required bool unpin, required String pinId}) async {
    final myUid = FirebaseAuth.instance.currentUser?.uid ?? '';
    if (!_isRoomAdmin || myUid.isEmpty) return;
    try {
      if (unpin) {
        if (pinId.isNotEmpty) {
          await SupaDb.client.from('pinned_messages').delete().eq('id', pinId);
        }
        if (mounted) {
          setState(() {});
          toast(context, 'Message unpin ho gaya.');
        }
      } else {
        // v2016 FIX 11: pinned_messages is tournament-keyed — team
        // rooms have no pin store yet (honest toast, no '' row).
        // FIX 12 G6: same for community rooms.
        if (_isTeam || _isCommunity) {
          if (mounted) toast(context, 'Pin ${_isCommunity ? 'community' : 'team'} rooms mein abhi available nahi hai.');
          return;
        }
        final text = strVal(m['message']);
        if (text.isEmpty) {
          toast(context, 'Photo message pin nahi ho sakta — sirf text pin hota hai.');
          return;
        }
        await SupaDb.client.from('pinned_messages').insert({
          'tournament_id': widget.tournamentId,
          'message': text,
          'pinned_by': myUid,
        });
        if (mounted) {
          setState(() {});
          toast(context, 'Message pin ho gaya.');
        }
      }
    } catch (e) {
      if (mounted) toast(context, 'Pin failed: $e');
    }
  }

  Future<void> _showMessageLongPressMenu(Map<String, dynamic> m, String myUid) async {
    final senderUid = strVal(m['firebase_uid']);
    final isMine = senderUid.isNotEmpty && senderUid == myUid;
    // BATCH 3B #27: read the current pinned row first so the sheet
    // can offer Pin or Unpin (same text-match rule as TeamChatPage).
    Map<String, dynamic>? pinned;
    final text = strVal(m['message']);
    try {
      final pins = await SupaDb.getList('pinned_messages', eqCol: 'tournament_id', eqVal: widget.tournamentId, orderBy: 'created_at', ascending: false, limit: 1);
      if (pins.isNotEmpty) pinned = pins.first;
    } catch (_) {}
    if (!mounted) return;
    final isPinned = pinned != null && strVal(pinned['message']) == text && text.isNotEmpty;
    final pinId = pinned == null ? '' : strVal(pinned['id']);
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: kCardPurpleMid,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22)), side: const BorderSide(color: kCardPurpleBorder, width: 1.5)),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            if (!isMine)
              ListTile(
                leading: const Icon(Icons.flag, color: Colors.orangeAccent),
                title: const Text('Report Message', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                subtitle: const Text('Ye message admin ko report hoga.', style: TextStyle(color: Color(0xFF7786A5), fontSize: 12)),
                onTap: () async {
                  Navigator.pop(ctx);
                  await _reportChatMessage(m);
                },
              ),
            if (_isRoomAdmin)
              ListTile(
                leading: Icon(Icons.push_pin, color: kGold),
                title: Text(isPinned ? 'Unpin message' : 'Pin message', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                subtitle: Text(isPinned ? 'Ye pinned banner se hat jayega.' : 'Ye message sab ke liye upar pin ho jayega.', style: const TextStyle(color: Color(0xFF7786A5), fontSize: 12)),
                onTap: () async {
                  Navigator.pop(ctx);
                  await _pinChatMessage(m, unpin: isPinned, pinId: pinId);
                },
              ),
            if (_isRoomAdmin)
              ListTile(
                leading: const Icon(Icons.delete_sweep, color: Colors.redAccent),
                title: const Text('Clear Chat (whole room)', style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold)),
                subtitle: const Text('Poori room chat sab ke liye delete hogi.', style: TextStyle(color: Color(0xFF7786A5), fontSize: 12)),
                onTap: () async {
                  Navigator.pop(ctx);
                  await _clearChat();
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  // PHASE 3 #27 REPORT MESSAGE — real backend write into live disputes
  // (008_pro_features.sql:52-62): tournament_id, raised_by (+name),
  // against_uid, reason (NOT NULL), status 'open'. disputes has NO
  // message-id/details column, so the reason carries the message id +
  // excerpt verbatim: 'Chat report [message <id>] <reason>: "<excerpt>"'.
  // Same insert shape as DisputePage (pro_features.dart). Moderation
  // action on a report (delete/restrict) is Phase 6 — this only files
  // the report for the admin. NOTE: player_reports (008:63-71) would
  // also fit (it has a details column); disputes was chosen because
  // the task directs it and it already carries the tournament link.
  Future<void> _reportChatMessage(Map<String, dynamic> m) async {
    final myUid = FirebaseAuth.instance.currentUser?.uid ?? '';
    if (myUid.isEmpty) {
      toast(context, 'Report ke liye sign-in zaroori hai.');
      return;
    }
    final senderUid = strVal(m['firebase_uid']);
    if (senderUid.isEmpty || senderUid == myUid) return;
    const reasons = ['Spam', 'Abusive language', 'Cheating / scam', 'Other'];
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kCardPurpleMid,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22), side: const BorderSide(color: kCardPurpleBorder, width: 1.5)),
        title: const Text('Report message', style: TextStyle(color: Color(0xFFFDC903), fontWeight: FontWeight.bold)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final r in reasons)
              ListTile(
                title: Text(r, style: const TextStyle(color: Colors.white)),
                onTap: () => Navigator.pop(ctx, r),
              ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel', style: TextStyle(color: Color(0xFF7786A5)))),
        ],
      ),
    );
    if (picked == null || !mounted) return;
    final msgId = strVal(m['id']);
    final rawText = _isImage(m) ? 'Photo message' : strVal(m['message']);
    final excerpt = rawText.length > 120 ? '${rawText.substring(0, 120)}…' : rawText;
    try {
      final profile = await SupaDb.getProfile(myUid);
      await SupaDb.reportChatMessage(
        // v2016 FIX 11: team reports carry no tournament id (the
        // disputes row omits the key — same as DM/team reports).
        // FIX 12 G6: same for community reports.
        tournamentId: _isTeam || _isCommunity ? null : widget.tournamentId,
        raisedBy: myUid,
        raisedByName: strVal(profile['displayName'], FirebaseAuth.instance.currentUser?.email ?? 'User'),
        againstUid: senderUid,
        reason: 'Chat report [message $msgId] $picked: "$excerpt"',
      );
      if (mounted) toast(context, 'Report submit ho gaya — admin review karega.');
    } catch (e) {
      if (mounted) toast(context, 'Report failed: $e');
    }
  }

  Future<void> _clearChat() async {
    if (!_adminGuard()) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kCardPurpleMid,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22), side: const BorderSide(color: kCardPurpleBorder, width: 1.5)),
        title: const Text('Clear all chat?', style: TextStyle(color: Color(0xFFFDC903), fontWeight: FontWeight.bold)),
        content: const Text('Is room ki poori chat history sab ke liye delete ho jayegi. Ye wapas nahi aayegi. Music sessions par iska asar nahi hoga.', style: TextStyle(color: Colors.white)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel', style: TextStyle(color: Color(0xFF7786A5)))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Clear Chat', style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      dynamic q = SupaDb.client.from('chat_messages').select('id,message').eq('scope', widget.scope);
      // v2016 FIX 11: team rows live in squad_id='team_<id>' too
      // (same column as squad rows) — the getters cover all scopes.
      q = q.eq(_chatScopeCol, _chatScopeId);
      final rows = await q;
      final ids = <String>[];
      for (final r in (rows as List)) {
        final map = r as Map<String, dynamic>;
        final msg = SupaDb.strOf(map['message']);
        // FIX 22 item 23: NO _chatClearedPrefix skip — legacy
        // markers are deleted by the clear too (the old skip
        // let them accumulate forever).
        if (msg.startsWith(_musicPrefix) || msg.startsWith(_musicApprovalPrefix)) continue;
        final id = SupaDb.strOf(map['id']);
        if (id.isNotEmpty) ids.add(id);
      }
      if (ids.isNotEmpty) {
        await SupaDb.client.from('chat_messages').delete().inFilter('id', ids);
      }
      // FIX 22 item 23: NO marker insert (see the doc comment
      // above) — the toast below is the whole notification.
      if (mounted) {
        setState(() {
          _welcomeRows.clear();
        });
        toast(context, 'Chat clear kar di hai — sab ke liye.');
      }
    } catch (e) {
      if (mounted) toast(context, 'Clear chat failed: $e');
    }
  }

  /// FIX 22 item 23 — REPLACES _handleChatClearedRows (deleted:
  /// no markers are written anymore, so the marker scan is dead
  /// code). Other phones learn about a clear from the stream
  /// itself: when a snapshot comes back EMPTY after the room
  /// had messages, the local welcome rows are stale and drop.
  /// (Verified 2026-11-23: _welcomeRows is never populated by
  /// current code — _addWelcomeRow only flashes a banner — so
  /// this is defensive/future-proof, not load-bearing today.)
  bool _hadChatMessages = false;

  void _handleChatEmptied(List<Map<String, dynamic>> rawMsgs) {
    if (rawMsgs.isNotEmpty) {
      _hadChatMessages = true;
      return;
    }
    if (!_hadChatMessages || _welcomeRows.isEmpty) return;
    _hadChatMessages = false;
    if (mounted) {
      setState(() => _welcomeRows.clear());
    } else {
      _welcomeRows.clear();
    }
  }

  void _showAdminMenu(String targetUid, String name) {
    if (!_isRoomAdmin) return;
    final myUid = FirebaseAuth.instance.currentUser?.uid ?? '';
    if (targetUid.isEmpty) return;
    if (targetUid == myUid) {
      // Self long-press: mic controls do not apply to yourself, but
      // Clear Chat must still be reachable even in an otherwise
      // empty room (no other participant to long-press).
      showModalBottomSheet<void>(
        context: context,
        backgroundColor: kCardPurpleMid,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22)), side: const BorderSide(color: kCardPurpleBorder, width: 1.5)),
        builder: (ctx) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.delete_sweep, color: Color(0xFFFDC903)),
                title: const Text('Clear Chat (whole room)', style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold)),
                onTap: () async { Navigator.pop(ctx); await _clearChat(); },
              ),
            ],
          ),
        ),
      );
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: kCardPurpleMid,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22)), side: const BorderSide(color: kCardPurpleBorder, width: 1.5)),
      builder: (ctx) {
        Widget item(IconData icon, String label, Future<void> Function() run, {Color color = Colors.white}) => ListTile(
              leading: Icon(icon, color: const Color(0xFFFDC903)),
              title: Text(label, style: TextStyle(color: color, fontWeight: FontWeight.bold)),
              onTap: () async { Navigator.pop(ctx); await run(); },
            );
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 10),
              Container(width: 40, height: 4, decoration: BoxDecoration(color: const Color(0xFF7786A5), borderRadius: BorderRadius.circular(2))),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Align(alignment: Alignment.centerLeft, child: Text('Admin controls — $name', style: const TextStyle(color: Color(0xFFFDC903), fontWeight: FontWeight.bold, fontSize: 16))),
              ),
              const Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: Align(alignment: Alignment.centerLeft, child: Text('Sirf admin ko nazar aata hai. Mute/Reject/Kick tab tak rahega jab tak admin khud clear na kare.', style: TextStyle(color: Color(0xFF7786A5), fontSize: 12)))),
              item(Icons.mic_off, 'Mute (mic + chat band)', () => _adminMute(targetUid, name)),
              item(Icons.mic, 'Unmute', () => _adminUnmute(targetUid, name)),
              item(Icons.volume_off, 'Mic Off (sirf mic band, chat chalegi)', () => _adminMicOff(targetUid, name)),
              item(Icons.volume_up, 'Mic On', () => _adminMicOn(targetUid, name)),
              item(Icons.block, 'Reject Mic (mic nahi le sakega)', () => _adminReject(targetUid, name)),
              item(Icons.check_circle, 'Allow Mic (reject khatam)', () => _adminAllowMic(targetUid, name)),
              item(Icons.remove_circle, 'Kick off Mic (seat khali, room me rahenge)', () => _adminMicKick(targetUid, name)),
              if (_musicApprovedStreamers.contains(targetUid) || (_sharedSession != null && strVal(_sharedSession!['playerUid']) == targetUid))
                item(Icons.music_off, 'Stop music stream', () => _revokeMusicStream(targetUid, name)),
              item(Icons.exit_to_app, 'Remove from Room (kick)', () => _adminKick(targetUid, name), color: Colors.redAccent),
              item(Icons.undo, 'Allow Back into Room', () => _adminUnkick(targetUid, name)),
              item(Icons.delete_sweep, 'Clear Chat (whole room)', () => _clearChat(), color: Colors.redAccent),
              const SizedBox(height: 12),
            ],
          ),
        );
      },
    );
  }

  void _openStatus() => showOnlineStatusSheet(context, widget.tournamentId, squadId: _isSquad ? widget.squadId : '', teamId: _isTeam ? widget.teamId : '', communityId: _isCommunity ? widget.communityId : '', isAdmin: _isRoomAdmin, onAdminAction: _isRoomAdmin ? (uid, name) => _showAdminMenu(uid, name) : null);


  // ROUND 9 Exit: exactly the old leave path — stop music (player
  // Stop also ends a shared session for everyone), leave voice,
  // mark presence offline, then pop. dispose() repeats the local
  // stops idempotently, so system-back and Exit behave the same.
  Future<void> _exitRoom() async {
    try {
      await _stopMusic();
    } catch (_) {}
    try {
      await _room.leave();
    } catch (_) {}
    // FIX 33: Leave Room must disconnect the LiveKit engine too —
    // the old code only left the mesh, so a LiveKit visit stayed
    // connected (ghost participant, still audible) until dispose
    // ran. Intentional leave: no drop banner (same guard as the
    // voice-only leave and the room-closed teardown).
    _lkIntentionalDisconnect = true;
    try {
      await _lkRoom.disconnect();
    } catch (_) {} finally {
      _lkIntentionalDisconnect = false;
    }
    // ARENA HUB #10 AUDIO — listeners: a new session starts with
    // a fresh peak and fresh listening clocks.
    _liveListeners.reset();
    try {
      await PresenceService.goOffline();
    } catch (_) {}
    if (mounted) Navigator.pop(context);
  }

  /// FIX 22 item 5 — Leave Room from the EMBEDDED sidebar: the
  /// same teardown as [_exitRoom] (stop music, leave voice on
  /// both engines, reset listeners, go offline) but the panel
  /// closes via [UnifiedRoomPage.onCloseVoice] instead of
  /// Navigator.pop — a pop here would close the parent CHAT page
  /// the panel is embedded in. Disposal repeats the local stops
  /// idempotently (see dispose()).
  Future<void> _leaveEmbeddedVoice() async {
    try {
      await _stopMusic();
    } catch (_) {}
    try {
      await _room.leave();
    } catch (_) {}
    try {
      await _lkRoom.disconnect();
    } catch (_) {}
    _liveListeners.reset();
    try {
      await PresenceService.goOffline();
    } catch (_) {}
    widget.onCloseVoice?.call();
  }

  void _showBackgroundsPanel() {
    // ROUND 13: replaces the Activity button in the side column.
    // Built-in original gradients + an Upload option. Per-device:
    // the choice is stored in SharedPreferences on this phone.
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: kCardPurpleMid,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22)), side: const BorderSide(color: kCardPurpleBorder, width: 1.5)),
      builder: (ctx) {
        return SizedBox(
          height: MediaQuery.of(ctx).size.height * 0.7,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(child: Container(width: 40, height: 4, margin: const EdgeInsets.only(top: 10), decoration: BoxDecoration(color: kMuted, borderRadius: BorderRadius.circular(2)))),
              Padding(
                padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Text('Chat backgrounds', style: TextStyle(color: kGold, fontWeight: FontWeight.bold, fontSize: 16)),
              ),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Text('Applies to this room on this phone and stays when you re-enter.', style: TextStyle(color: kMuted, fontSize: 12)),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: GridView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, mainAxisSpacing: 12, crossAxisSpacing: 12, childAspectRatio: 1.6),
                  itemCount: _bgPresets.length + 1,
                  itemBuilder: (_, i) {
                    if (i == _bgPresets.length) {
                      final isCustom = _bgId == 'custom' && _customBgUrl.isNotEmpty;
                      return InkWell(
                        onTap: () async { Navigator.pop(ctx); await _uploadBackground(); },
                        borderRadius: BorderRadius.circular(12),
                        child: Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: isCustom ? kGold : kMuted, width: isCustom ? 2 : 1),
                            image: isCustom && !_customBgUrl.startsWith('file:') ? DecorationImage(image: CachedNetworkImageProvider(_customBgUrl), fit: BoxFit.cover) : null,
                            color: const Color(0xFF1A1208),
                          ),
                          alignment: Alignment.bottomLeft,
                          padding: const EdgeInsets.all(10),
                          child: Row(children: [
                            Icon(Icons.upload, color: kGold, size: 18),
                            const SizedBox(width: 6),
                            Expanded(child: Text(isCustom ? 'Your upload ✓' : 'Upload background', style: TextStyle(color: kText, fontWeight: FontWeight.bold, fontSize: 12))),
                          ]),
                        ),
                      );
                    }
                    final b = _bgPresets[i];
                    final selected = _bgId == b['id'];
                    final colors = (b['colors'] as List<int>).map((c) => Color(c)).toList();
                    return InkWell(
                      onTap: () { Navigator.pop(ctx); _setBackground(b['id'] as String); },
                      borderRadius: BorderRadius.circular(12),
                      child: Container(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(colors: colors, begin: Alignment.topLeft, end: Alignment.bottomRight),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: selected ? kGold : Colors.transparent, width: 2),
                        ),
                        alignment: Alignment.bottomLeft,
                        padding: const EdgeInsets.all(10),
                        child: Text(selected ? '${b['name']} ✓' : b['name'] as String, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
                      ),
                    );
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                child: Row(children: [
                  Expanded(child: TextButton.icon(onPressed: () async { Navigator.pop(ctx); await _shareBackground(); }, icon: Icon(Icons.share, color: kGold, size: 18), label: Text('Share with room', style: TextStyle(color: kGold, fontWeight: FontWeight.bold)))),
                  Expanded(child: TextButton.icon(onPressed: () async { Navigator.pop(ctx); await _clearSharedBackground(); }, icon: Icon(Icons.clear, color: kMuted, size: 18), label: Text('Clear shared', style: TextStyle(color: kMuted, fontWeight: FontWeight.bold)))),
                ]),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
                child: TextButton.icon(
                  onPressed: () async { Navigator.pop(ctx); await _uploadBackground(); },
                  icon: Icon(Icons.upload, color: kGold, size: 18),
                  label: Text('Upload background', style: TextStyle(color: kGold, fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        );
      },
    );
  }


  /// Free-coin cheer (expansion 3): points ONLY — no real money.
  /// Deducts points via a negative cheer_points transaction, then
  /// posts a CHEER:: message everyone sees in the room chat.
  Future<void> _sendCheer() async {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    var points = 0.0;
    try {
      final txs = await SupaDb.getList('transactions', eqCol: 'firebase_uid', eqVal: uid);
      const pointTypes = {'spin_points', 'quiz_points', 'daily_reward', 'season_reward', 'cheer_points'};
      for (final r in txs) {
        if (pointTypes.contains(SupaDb.strOf(r['type']))) points += SupaDb.numOf(r['amount']);
      }
    } catch (_) {}
    if (!mounted) return;
    final choice = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kCardPurpleMid,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22), side: const BorderSide(color: kCardPurpleBorder, width: 1.5)),
        title: Text('Free-Coin Cheer 🎉', style: TextStyle(color: kGold)),
        content: Text('Your points: ${points.toStringAsFixed(0)}\nPoints sirf in-app hain — koi real money nahi.', style: TextStyle(color: kText)),
        actions: [
          for (final amt in [10, 50, 100])
            TextButton(onPressed: () => Navigator.pop(ctx, amt), child: Text('$amt pts', style: TextStyle(color: kGold))),
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text('Cancel', style: TextStyle(color: kMuted))),
        ],
      ),
    );
    if (choice == null) return;
    if (points < choice) {
      if (mounted) toast(context, 'Points kam hain! Daily Spin ya Quiz se points kamayen.');
      return;
    }
    try {
      final profile = await SupaDb.getProfile(uid);
      await SupaDb.recordTransaction(uid, 'cheer_points', -choice.toDouble(), 'Cheer in room');
      await SupaDb.sendChat(scope: widget.scope, scopeId: _chatScopeId, uid: uid, displayName: strVal(profile['displayName'], 'User'), message: '$_cheerPrefix🎉 $choice points cheer!');
      if (mounted) toast(context, 'Cheer bhej diya! 🎉');
    } catch (e) {
      if (mounted) toast(context, 'Cheer failed: $e');
    }
  }

  Future<void> _checkJoined() async {
    if (_isSquad || _isTeam || _isCommunity) {
      // Squad rooms are only reachable from a joined squad (Detail
      // page gates them behind a registration with a team name).
      // Team rooms are only reachable from the team's own chat
      // (TeamChatPage lists only the user's teams) — same rule.
      // Community rooms are only reachable from the community
      // detail, which gates the Voice toggle behind membership
      // (FIX 12 G6) — same rule.
      setState(() {
        _joined = true;
        _checkedJoin = true;
      });
      return;
    }
    try {
      final uid = FirebaseAuth.instance.currentUser!.uid;
      final regs = await SupaDb.getRegistrations(widget.tournamentId);
      if (mounted) {
        setState(() {
          _joined = regs.any((r) => strVal(r['firebase_uid']) == uid);
          _checkedJoin = true;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _checkedJoin = true);
    }
  }

  Future<void> _send() async {
    final text = _msg.text.trim();
    if (text.isEmpty) return;
    if (widget.spectator && !widget.shoutcaster) {
      toast(context, 'Spectator mode — chat view-only hai.');
      return;
    }
    if (!_canSendChat) {
      toast(context, 'You must join this tournament to send messages.');
      return;
    }
    final user = FirebaseAuth.instance.currentUser!;
    // ADMIN CHAT RESTRICTION (Chat Moderation): a chat_restrictions
    // row blocks chat everywhere until the admin unrestricts.
    try {
      if (await SupaDb.isChatRestricted(user.uid)) {
        if (mounted) toast(context, 'Aapka chat admin ne band kiya hua hai — admin se rabta karein.');
        return;
      }
    } catch (_) {}
    // REMAINING-ITEMS mute enforcement: an active room_mutes row
    // blocks chat (and voice join, see _joinVoiceOpen) until a host
    // unmutes. Clear message, no silent drop.
    try {
      final mutes = await SupaDb.getList('room_mutes', eqCol: 'tournament_id', eqVal: widget.tournamentId, eqCol2: 'firebase_uid', eqVal2: user.uid);
      if (mutes.any((m) => m['active'] == true)) {
        toast(context, 'Aap is room me mute hain — host/admin ne mute kiya hai. Unmute hone tak chat/voice nahi chalegi.');
        return;
      }
    } catch (_) {}
    final profile = await SupaDb.getProfile(user.uid);
    await SupaDb.sendChat(
      scope: widget.scope,
      scopeId: _chatScopeId,
      uid: user.uid,
      displayName: strVal(profile['displayName'], user.email ?? 'User'),
      message: widget.shoutcaster ? '$_shoutPrefix$text' : text,
      replyTo: _replyTo == null ? null : {'display_name': strVal(_replyTo!['display_name']), 'message': strVal(_replyTo!['message'])},
    );
    _msg.clear();
    setState(() => _replyTo = null);
    HapticFeedback.lightImpact();
    // SEND SOUND REMOVED (2026-10-30 user order): sending a chat
    // message is silent — no tune on send. Gift and mic-join sounds
    // are untouched; the send-sound helper itself is left in place
    // with no call site, so nothing else changes.
    _scrollToBottom();
  }


  // ROUND 8: Take mic joins voice OPEN (unmuted) — there is no
  // Unmute button anymore, so joining muted would leave the user
  // with no way to speak except tapping their seat. PTT is off in
  // this build (no PTT row), so setPushToTalk(false) is only a
  // safety net for a stale flag.
  Future<void> _joinVoiceOpen() async {
    // FIX 23 item 16a: the parent says voice is LOCKED for
    // this community — refuse to join, silently (the panel
    // shows the "Voice locked" line; no toast spam on the
    // auto-join attempt).
    if (widget.voiceLocked) return;
    // FIX 12 G6b: a fresh join attempt clears a dismissed error
    // banner, so a new failure shows again (never silently hidden).
    _voiceErrorDismissed = false;
    // GLOBAL VOICE TOGGLE (admin setting): when the admin turns voice
    // off — globally or for this tournament — no entry point may join
    // voice. The seat grid hides itself, but the side-rail Voice
    // button and the Mic FAB call this method directly, so the check
    // lives HERE (audit fix 2026-11-21).
    try {
      if (!await SupaDb.voiceEnabledForTournament(widget.tournamentId)) {
        if (mounted) toast(context, 'Voice chat admin ne band ki hui hai.');
        return;
      }
    } catch (_) {}
    // A-5 ROOM LOAD CONTROL (026): fresh control read at join time
    // (the cached poll state may be up to 30 s stale). OFF -> voice
    // join blocked with the reason. Read failure = ON (never block
    // voice on a read error — see SupaDb.getRoomControl).
    try {
      final control = await SupaDb.getRoomControl(widget.tournamentId);
      if (SupaDb.isRoomVoiceDisabled(control)) {
        final reason = SupaDb.strOf(control['disabled_reason']);
        if (mounted) {
          setState(() {
            _roomVoiceDisabled = true;
            _roomDisabledReason = reason;
          });
          toast(context, reason.isNotEmpty ? 'Room band hai — $reason' : 'Room band hai — voice join abhi band hai.');
        }
        return;
      }
    } catch (_) {}
    // REMAINING-ITEMS: muted users cannot join voice either.
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
      if (uid.isNotEmpty) {
        final mutes = await SupaDb.getList('room_mutes', eqCol: 'tournament_id', eqVal: widget.tournamentId, eqCol2: 'firebase_uid', eqVal2: uid);
        if (mutes.any((m) => m['active'] == true)) {
          toast(context, 'Aap is room me mute hain — voice join nahi kar sakte jab tak host unmute na kare.');
          return;
        }
      }
    } catch (_) {}
    // FIX 12 G6b: the reject + mic gates below read _adminMicRejected
    // / _isRoomAdmin / _adminUid, which _loadRoomAdmin fills in async
    // from initState — the embedded panel's post-frame auto-join used
    // to race it and could send a mic request (and return, never
    // joining) for a user who IS the admin. Await the load first so
    // the gates always see loaded state. Bounded at 5 s: a hung admin
    // read must never stall the join — on timeout the gates run on
    // whatever state is loaded (fail-open to the mic-request path).
    final adminLoad = _adminLoadFuture;
    if (adminLoad != null) {
      try {
        await adminLoad.timeout(const Duration(seconds: 5));
      } catch (_) {}
    }
    // ADMIN REJECT: a rejected user cannot take a mic at all
    // (chat is NOT blocked by a reject — only mic-join is).
    if (_adminMicRejected) {
      if (mounted) toast(context, '$_approverWordCap ne aapka mic reject kiya hua hai — mic lene ke liye $_approverWord ki ijazat chahiye.');
      return;
    }
    // MIC REQUEST GATE: the admin takes a mic directly; everyone
    // else needs a live (<=2 min, unused) admin approval. Without
    // one, this tap SENDS the request instead of joining voice —
    // so no entry point (Take Mic, Join button) can bypass it.
    {
      final myUid = FirebaseAuth.instance.currentUser?.uid ?? '';
      final isAdminNow = _isRoomAdmin || (myUid.isNotEmpty && _adminUid.isNotEmpty && myUid == _adminUid);
      if (!isAdminNow) {
        final approved = _micApprovedUntil != null && DateTime.now().isBefore(_micApprovedUntil!);
        if (!approved) {
          await _sendMicRequest();
          return;
        }
        // Approved take: the peer row carries the admin-chosen slot
        // (migration 013 seat_no) so every phone renders this user
        // in exactly that cell, not in join order.
        _room.assignedSeat = _micApprovedSlot;
      }
    }
    // v2017: the request can throw (MissingPluginException) when
    // the plugin is unavailable — treat that as denied, never
    // crash the join flow.
    PermissionStatus status;
    try {
      status = await Permission.microphone.request();
    } catch (_) {
      if (mounted) toast(context, 'Microphone permission nahi mili — voice chat ke liye mic access chahiye.');
      return;
    }
    if (!status.isGranted) {
      if (mounted) toast(context, 'Microphone permission denied. Voice chat needs mic access - allow it in app settings to join.');
      return;
    }
    // HEADPHONE/BT FIX (2026-10-30): ask for Bluetooth-connect too
    // (Android 12+ needs it for headset SCO routing). Best-effort
    // only: a denial must NOT block voice — wired headsets and the
    // loudspeaker still work without it, only Bluetooth routing
    // needs this permission.
    // v2016 (user order 2026-11-22, "Bluetooth connect nahi ho
    // raha"): the result is now CHECKED — a denial used to be
    // swallowed silently, so a user who once denied it (or hit
    // "don't ask again") had no idea why Bluetooth never worked.
    // Denied = honest toast; permanently denied = a dialog with a
    // direct Open Settings shortcut (a twice-denied permission can
    // only be granted from settings). Voice itself never blocks.
    try {
      final bt = await Permission.bluetoothConnect.request();
      if (!bt.isGranted && mounted) {
        if (bt.isPermanentlyDenied) {
          final open = await showDialog<bool>(
            context: context,
            builder: (dCtx) => AlertDialog(
              backgroundColor: kCardPurpleMid,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22), side: const BorderSide(color: kCardPurpleBorder, width: 1.5)),
              title: const Text('Bluetooth permission band hai', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              content: const Text('Bluetooth headset connect karne ke liye Bluetooth permission chahiye. Ye permission settings se hi on ho sakti hai.', style: TextStyle(color: Colors.white70)),
              actions: [
                TextButton(onPressed: () => Navigator.pop(dCtx, false), child: const Text('Cancel', style: TextStyle(color: Colors.white70))),
                TextButton(onPressed: () => Navigator.pop(dCtx, true), child: const Text('Open Settings', style: TextStyle(color: Color(0xFFFDC903), fontWeight: FontWeight.bold))),
              ],
            ),
          );
          if (open == true) {
            try { await openAppSettings(); } catch (_) {}
          }
        } else {
          toast(context, 'Bluetooth permission nahi mili — Bluetooth headset connect nahi hoga.');
        }
      }
    } catch (_) {}
    // ANDROID 13+ (incl. Android 15): the voice foreground service
    // notification needs POST_NOTIFICATIONS. Best-effort only — a
    // denial must NOT block voice; it only hides the notification.
    try {
      await Permission.notification.request();
    } catch (_) {}
    // LIVEKIT TEST PATH: all gates above (mute hold, reject,
    // mic-request approval) already ran — the test engine inherits
    // them exactly, it does not bypass them.
    if (_useLiveKit) {
      await _joinVoiceLiveKit();
      return;
    }
    if (_room.pushToTalk) await _room.setPushToTalk(false);
    await _room.join();
    if (_room.joined) {
      // Approval is single-use: a fresh request is needed for the
      // next mic take after leaving voice (mute toggles on an
      // already-joined seat are not takes, and are unaffected).
      _micApprovedUntil = null;
      _micApprovedSlot = null;
      HapticFeedback.mediumImpact();
      SoundService.micJoin();
      await _room.setMuted(false);
    }
    if (_room.error != null && mounted) toast(context, _room.error!);
  }

  /// Fires on every LiveKit service notify (participant/speaker/
  /// disconnect events). The ONLY drop detector: an unexpected
  /// transition from joined -> not-joined while this visit was
  /// using LiveKit raises the in-room banner. Intentional leaves
  /// (leave button, engine switch, project switch, reconnect's
  /// internal teardown) set _lkIntentionalDisconnect first and
  /// never raise it. While joined, the mic state is remembered so
  /// a reconnect restores it instead of forcing unmute.
  /// AUDIO #10 — installs the RNNoise mic noise processor on the
  /// LiveKit voice service. Fire-and-forget from initState; safe to
  /// call before joining (the pipeline holds the processor until
  /// the mic publishes). No-op when native RNNoise is unavailable.
  Future<void> _installMicNoiseProcessor() async {
    // FIX 22 item 6: try DSP FIRST — the RJ console's live
    // effects need the DSP chain, and a restart used to leave the
    // mic on RNNoise with the console's panel missing entirely.
    // initialize() retries once on timeout only and records the
    // reason (fix21); on any failure fall back to RNNoise —
    // never a fake DSP. The probe cache makes a dead DSP a
    // one-per-session cost: later room entries skip straight to
    // RNNoise. No stored processor choice exists (the picker
    // switch is session-only), so a fresh room entry always
    // auto-tries DSP when the cache has not ruled it out.
    if (DspMicProcessor.cachedAvailable != false) {
      final dsp = DspMicProcessor();
      var installed = false;
      try {
        installed = await dsp.initialize() &&
            mounted &&
            await _lkRoom.setNoiseProcessor(dsp);
      } catch (_) {
        installed = false;
      }
      if (installed) return;
      try {
        await dsp.dispose();
      } catch (_) {}
    }
    final processor = RnnoiseMicProcessor();
    if (!await processor.initialize()) return;
    if (!mounted) {
      await processor.dispose();
      return;
    }
    await _lkRoom.setNoiseProcessor(processor);
  }

  void _onLiveKitChanged() {
    if (!mounted) return;
    // ARENA HUB #10 AUDIO — listeners call site 1: participants
    // changed, so recompute the listener list (cheap, and a
    // no-op notify when nothing changed).
    _liveListeners.update(_lkRoom.participants, _lastSeatUids);
    // RJ DUCKING (any-speaker): LiveKit participant mute changes
    // re-evaluate ducking too — the mesh listener alone left
    // LiveKit visits never re-evaluating, so a LiveKit speaker
    // never ducked the music. _applySharedDucking early-returns
    // when nothing changed, so this is cheap on every notify.
    _applySharedDucking();
    // FIX 22 item 10: also re-apply in local/fallback mode
    // (the ducking call above early-returns without a session).
    _reapplyMusicVolumeForMicToggle();
    if (_lkRoom.joined) {
      _lkLastMuted = _lkRoom.muted;
      if (_useLiveKit) _lkWasJoined = true;
    } else if (_useLiveKit && _lkWasJoined && !_lkIntentionalDisconnect && !_lkReconnecting) {
      _lkDropped = true;
      _lkDropReason = _lkRoom.error != null && _lkRoom.error!.isNotEmpty ? _lkRoom.error : 'Voice connection toot gaya hai.';
    }
    if (mounted) setState(() {});
  }

  /// RJ Studio listeners changed (join/leave/seat move, or a
  /// profile name/avatar resolved in the background): rebuild the
  /// page AND the open panel sheet so the count stays live.
  void _onListenersChanged() {
    if (!mounted) return;
    setState(() {});
    // The sheet's refresh throws once if the sheet closed since
    // it was assigned — catch it and clear the stale fn.
    try {
      _listenersSheetRefresh?.call();
    } catch (_) {
      _listenersSheetRefresh = null;
    }
  }

  /// Listener name resolver (LISTENERS_INTEGRATION.md §4): the
  /// room's existing profile lookup. Returns '' when there is no
  /// real profile name so the service falls back to the LiveKit
  /// participant name, then the identity — normProfile defaults
  /// a missing displayName to 'User', which must NOT leak here.
  Future<String> _resolveListenerName(String uid) async {
    final profile = await SupaDb.getProfile(uid);
    if (profile.isEmpty) return '';
    final name = strVal(profile['displayName']);
    return name == 'User' ? '' : name;
  }

  /// Listener avatar resolver (LISTENERS_INTEGRATION.md §4):
  /// the profile photo URL, or null for the initial-circle avatar.
  Future<String?> _resolveListenerAvatar(String uid) async {
    final profile = await SupaDb.getProfile(uid);
    final url = strVal(profile['photoURL']);
    return url.isEmpty ? null : url;
  }

  /// Project-change detector (polled, throttled to 30 s, called
  /// from the existing 10 s presence poll): if the admin switched
  /// the active project while this session was live, the old
  /// project's room does NOT auto-move — the banner tells the
  /// user to Refresh onto the new project. It never disconnects
  /// anything itself; only the user's Refresh tap reconnects.
  Future<void> _maybeDetectLiveKitProjectChange() async {
    if (!_useLiveKit || !_lkWasJoined || _lkDropped || _lkReconnecting || _lkJoinedProjectId.isEmpty) return;
    final last = _lkLastProjectCheck;
    if (last != null && DateTime.now().difference(last) < const Duration(seconds: 30)) return;
    _lkLastProjectCheck = DateTime.now();
    try {
      final cfg = await LiveKitConfig.load();
      if (!mounted || !_useLiveKit || !_lkWasJoined || _lkDropped) return;
      final active = cfg.activeProjectId;
      if (active.isNotEmpty && active != _lkJoinedProjectId) {
        setState(() {
          _lkConfig = cfg;
          _lkDropped = true;
          _lkDropReason = 'Active LiveKit project badal gaya hai — is session ki voice purani project par hai. Refresh dabakar naye project par dobara connect karen.';
        });
      }
    } catch (_) {}
  }

  /// In-place LiveKit reconnect (banner's Refresh button). Room,
  /// chat and seats are untouched; only the voice transport is
  /// rebuilt against the CURRENT active project. On failure the
  /// banner stays up with the honest reason — it never claims a
  /// connection that did not happen.
  Future<void> _reconnectLiveKit() async {
    if (_lkReconnecting || !_useLiveKit) return;
    // Re-check the two hard gates (mute hold, admin reject) — a
    // user muted/rejected while dropped must not reconnect past
    // the admin. The mic-request gate is deliberately NOT re-run:
    // this continues an approved session, it is not a new take.
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
      if (uid.isNotEmpty) {
        final mutes = await SupaDb.getList('room_mutes', eqCol: 'tournament_id', eqVal: widget.tournamentId, eqCol2: 'firebase_uid', eqVal2: uid);
        if (mutes.any((m) => m['active'] == true)) {
          if (mounted) setState(() => _lkReconnectError = 'Aap is room me mute hain — voice dobara connect nahi ho sakti jab tak host unmute na kare.');
          return;
        }
      }
    } catch (_) {}
    if (_adminMicRejected) {
      if (mounted) setState(() => _lkReconnectError = 'Admin ne aapka mic reject kiya hua hai — dobara connect ke liye admin ki ijazat chahiye.');
      return;
    }
    if (!mounted) return;
    setState(() {
      _lkReconnecting = true;
      _lkReconnectError = null;
    });
    try {
      // FIX 12 G6b: same 15 s bound as the fresh join — Supabase
      // REST has no timeout of its own, so an unbounded load
      // here could hang the reconnect forever.
      late final LiveKitConfig cfg;
      try {
        cfg = await LiveKitConfig.load()
            .timeout(const Duration(seconds: 15));
      } on TimeoutException {
        if (mounted) setState(() => _lkReconnectError = 'Server settings load nahi ho sakin (15s timeout) — network check karen, phir Refresh dabayen.');
        return;
      }
      if (mounted) setState(() => _lkConfig = cfg);
      final project = cfg.activeProject;
      if (!cfg.isConfigured || project == null) {
        if (mounted) setState(() => _lkReconnectError = 'LiveKit server abhi set nahi hai — admin se server set karwayen, ya Mesh engine use karen.');
        return;
      }
      final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
      if (uid.isEmpty) {
        if (mounted) setState(() => _lkReconnectError = 'Pehle login karen.');
        return;
      }
      final token = await LiveKitVoiceService.fetchToken(project.tokenUrl, _voiceRoomId, uid);
      // Suppress the drop detector during connect()'s internal
      // teardown; this method sets the banner state itself.
      _lkIntentionalDisconnect = true;
      try {
        await _lkRoom.connect(project.serverUrl, token);
      } finally {
        _lkIntentionalDisconnect = false;
      }
      if (!mounted) return;
      if (_lkRoom.joined) {
        // Restore the mic state from before the drop (do NOT
        // force unmute — a user who was muted stays muted).
        await _lkRoom.setMuted(_lkLastMuted);
        setState(() {
          _lkWasJoined = true;
          _lkJoinedProjectId = project.id;
          _lkDropped = false;
          _lkDropReason = null;
          _lkReconnectError = null;
        });
        if (mounted) toast(context, 'LiveKit dobara connect ho gaya hai — aap room me hi hain.');
      } else {
        setState(() => _lkReconnectError = _lkRoom.error != null && _lkRoom.error!.isNotEmpty ? _lkRoom.error : 'Dobara connect nahi ho saka — dobara Refresh dabayen ya Mesh engine use karen.');
      }
    } catch (e) {
      if (mounted) setState(() => _lkReconnectError = 'Dobara connect failed: $e');
    } finally {
      if (mounted) setState(() => _lkReconnecting = false);
    }
  }

  /// FIX 12 G6b — the voice CONNECT error banner: shown after a
  /// failed join (LiveKit: _lkConnectError; mesh: _room.error),
  /// in the embedded panel AND the full room. The old code only
  /// toasted the failure once, so the panel sat on "Connecting…"
  /// forever with no reason and no way back. This banner shows
  /// the honest reason + a Retry button (re-runs _joinVoiceOpen,
  /// which re-reads the fresh active project) and an X to dismiss
  /// (a fresh join attempt un-dismisses). Hidden while joined,
  /// while a join is in flight, and when there is no error.
  String? get _voiceConnectError {
    if (_lkRoom.joined || _room.joined || _voiceErrorDismissed) return null;
    if (_lkConnecting || _lkReconnecting) return null;
    if (_lkConnectError != null && _lkConnectError!.isNotEmpty) return _lkConnectError;
    if (_room.error != null && _room.error!.isNotEmpty) return _room.error;
    return null;
  }

  Widget _buildVoiceConnectErrorBanner() {
    final msg = _voiceConnectError;
    if (msg == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(kSpace12, kSpace8, kSpace12, 0),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: kSpace12, vertical: 10),
        decoration: BoxDecoration(color: const Color(0xFF2A1215), borderRadius: BorderRadius.circular(16), border: Border.all(color: Colors.redAccent.withValues(alpha: 0.7))),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.error_outline, color: Colors.redAccent, size: 20),
                const SizedBox(width: kSpace8),
                const Expanded(child: Text('Voice connect nahi ho saka', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13))),
                InkWell(onTap: () => setState(() => _voiceErrorDismissed = true), child: const Icon(Icons.close, color: Color(0xFF7786A5), size: 18)),
              ],
            ),
            const SizedBox(height: kSpace4),
            Text(msg, style: TextStyle(color: kMuted, fontSize: 12)),
            const SizedBox(height: kSpace8),
            SizedBox(
              width: double.infinity,
              // (FIX 12 G6b pins this ElevatedButton.icon shape —
              // the label text + onPressed literal — do not swap
              // it for a shared button component.)
              child: ElevatedButton.icon(
                onPressed: _lkConnecting ? null : _joinVoiceOpen,
                icon: _lkConnecting ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.refresh, size: 18),
                label: Text(_lkConnecting ? 'Connect ho raha hai…' : 'Retry', style: const TextStyle(fontWeight: FontWeight.bold)),
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFFDC903), foregroundColor: Colors.black, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24))),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// FIX 12 G6b — the host strip's presence line, connection-aware
  /// (requirement d). 'Offline' claims the HOST is offline — but
  /// when this phone is not on voice at all, the host's presence
  /// is simply unknown (no peers ever arrive): the honest label
  /// is the CONNECTION state. 'Offline' stays only before any
  /// join attempt (nobody on voice yet, including me).
  String _hostPresenceLabel() {
    if (_lkRoom.joined || _room.joined) return 'Offline';
    if (_lkConnecting || _lkRoom.connecting || _lkReconnecting) return 'Connecting…';
    if (_lkConnectError != null ||
        (_useLiveKit && _lkRoom.error != null) ||
        _room.error != null) return 'Not connected';
    return 'Offline';
  }

  /// The in-room reconnect banner: rendered inline above the Join
  /// bar (never a popup, never a kick-out). Visible only after an
  /// unexpected LiveKit drop or an active-project change under a
  /// live session. X only hides it (the Join button stays as the
  /// other way back in); Refresh reconnects in place.
  Widget _liveKitDroppedBanner() {
    if (!_useLiveKit || !_lkDropped) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(color: const Color(0xFF2A1A12), borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFFFDC903))),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.wifi_off, color: Color(0xFFFDC903), size: 20),
                const SizedBox(width: 8),
                const Expanded(child: Text('Voice toot gayi hai — aap room me hi hain, chat aur seats mehfooz hain.', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13))),
                InkWell(onTap: () => setState(() => _lkDropped = false), child: const Icon(Icons.close, color: Color(0xFF7786A5), size: 18)),
              ],
            ),
            if (_lkDropReason != null) ...[
              const SizedBox(height: 4),
              Text(_lkDropReason!, style: const TextStyle(color: Color(0xFFAAB0D0), fontSize: 12)),
            ],
            if (_lkReconnectError != null) ...[
              const SizedBox(height: 4),
              Text(_lkReconnectError!, style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
            ],
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _lkReconnecting ? null : _reconnectLiveKit,
                icon: _lkReconnecting ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.refresh, size: 18),
                label: Text(_lkReconnecting ? 'Dobara connect ho raha hai…' : 'Refresh / Dobara Connect', style: const TextStyle(fontWeight: FontWeight.bold)),
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF8B2CFF), foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24))),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// LIVEKIT TEST JOIN (2026-11-01): same tail as the mesh join
  /// (approval single-use, haptic, mic-join sound, unmute) but the
  /// media goes through the SFU. NEVER fakes a connection: with
  /// no configured project the user gets the honest
  /// "server abhi set nahi hai" error and nothing joins. The token
  /// is minted by the Edge Function, which gates publish rights
  /// (admin, or a live mic grant written at approval time) — the
  /// app never holds the API secret.
  ///
  /// FIX 12 G6b (2026-11-23, 01:56 live issue — "Connecting…"
  /// for an hour after the project switch): the old version only
  /// TOASTED failures, so a failed join looked identical to a
  /// join still in flight, with no retry and no reason. Now:
  /// (a) the ACTIVE project is re-read FRESH at join time
  /// (LiveKitConfig.load() — never a cached _lkConfig);
  /// (b) every step is bounded — config load 15 s, token fetch
  /// 20 s (service), SDK connect 30 s (service) — so
  /// "Connecting…" can NEVER hang forever;
  /// (c) token-fetch failures are SURFACED in _lkConnectError,
  /// not swallowed;
  /// (d) every failure lands on the error banner + Retry (see
  /// _buildVoiceConnectErrorBanner), never on a stuck pill.
  Future<void> _joinVoiceLiveKit() async {
    if (_lkConnecting) return;
    if (mounted) {
      setState(() {
        _lkConnecting = true;
        _lkConnectError = null;
        _voiceErrorDismissed = false;
      });
    }
    try {
      // (a) FRESH config at join time — the active project may
      // have switched since this room opened (admin panel /
      // settings switch); a cached project would join the WRONG
      // server and hang. Bounded: Supabase REST has no timeout
      // of its own, so 15 s here.
      late final LiveKitConfig cfg;
      try {
        cfg = await LiveKitConfig.load()
            .timeout(const Duration(seconds: 15));
      } on TimeoutException {
        if (mounted) {
          setState(() => _lkConnectError =
              'Server settings load nahi ho sakin (15s timeout) — network check karen, phir Retry dabayen.');
        }
        return;
      }
      if (mounted) setState(() => _lkConfig = cfg);
      final project = cfg.activeProject;
      if (!cfg.isConfigured || project == null) {
        if (mounted) {
          setState(() => _lkConnectError =
              'LiveKit server abhi set nahi hai — admin se server set karwayen, ya Mesh engine use karen.');
        }
        return;
      }
      final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
      if (uid.isEmpty) {
        if (mounted) {
          setState(() => _lkConnectError = 'Pehle login karen.');
        }
        return;
      }
      // (c) Token failures are SURFACED (the old code let them
      // fall into the generic catch + a vanishing toast).
      late final String token;
      try {
        token = await LiveKitVoiceService.fetchToken(
            project.tokenUrl, _voiceRoomId, uid);
      } catch (e) {
        if (mounted) {
          setState(() => _lkConnectError =
              'Voice token nahi mila: $e');
        }
        return;
      }
      await _lkRoom.connect(project.serverUrl, token);
      if (!mounted) return;
      if (_lkRoom.joined) {
        _micApprovedUntil = null;
        _micApprovedSlot = null;
        HapticFeedback.mediumImpact();
        SoundService.micJoin();
        await _lkRoom.setMuted(false);
        if (mounted) {
          setState(() {
            _lkWasJoined = true;
            _lkJoinedProjectId = project.id;
            _lkLastMuted = false;
            _lkDropped = false;
            _lkDropReason = null;
            _lkReconnectError = null;
            _lkConnectError = null;
          });
        }
      } else {
        if (mounted) {
          setState(() => _lkConnectError =
              _lkRoom.error != null && _lkRoom.error!.isNotEmpty
                  ? _lkRoom.error
                  : 'Voice connect nahi ho saka — Retry dabayen ya Mesh engine use karen.');
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _lkConnectError = 'LiveKit join failed: $e');
      }
    } finally {
      if (mounted) setState(() => _lkConnecting = false);
    }
  }

  // ROUND 8: tapping your OWN seat toggles mute/unmute (the only
  // mute control left in the room UI). Other seats are informational.
  // FIX 20 (fix 8): generation counter for the seat toggle — a
  // stale/timeout setMuted result must never flip state after a
  // newer tap (same pattern as _speakerRouteGen).
  int _seatToggleGen = 0;

  Future<void> _toggleOwnSeat() async {
    HapticFeedback.lightImpact();
    final gen = ++_seatToggleGen;
    // LiveKit test path first: its seat toggle must not fall
    // through to the mesh (which is not joined in test mode).
    if (_lkRoom.joined) {
      if (_adminMutedHeld || _adminMicOffHeld) {
        if (mounted) toast(context, 'Admin ne aapka mic band kiya hua hai — unmute sirf admin kar sakta hai.');
        return;
      }
      // FIX 20 (fix 8): 2s timeout — a stalled setMuted must never
      // hang the button; on timeout the user is told to retry and
      // the button stays responsive for the next tap.
      try {
        await _lkRoom.setMuted(!_lkRoom.muted).timeout(const Duration(seconds: 2));
      } on TimeoutException {
        if (mounted && gen == _seatToggleGen) {
          toast(context, 'Mic respond nahi kar raha, dobara try karein');
        }
        return;
      }
      if (mounted && gen == _seatToggleGen) setState(() {});
      // FIX 22 item 10: re-apply the music volume at once — the
      // voice must win immediately (FIX 22 item 11: direct, no
      // fade); do not wait for the ~2 s poll listener.
      if (gen == _seatToggleGen) await _applyMusicVolume();
      return;
    }
    // FIX 20 (fix 8): not joined anywhere — say so honestly
    // instead of swallowing the tap silently (the "Not connected"
    // dead tap: nothing happened, no message).
    if (!_room.joined) {
      if (mounted) toast(context, 'Voice connected nahi hai — pehle connect karein');
      return;
    }
    // ADMIN-HELD mic: the target cannot unmute themself back while
    // an admin mute / mic-off is active — only the admin clears it.
    if (_adminMutedHeld || _adminMicOffHeld) {
      if (mounted) toast(context, 'Admin ne aapka mic band kiya hua hai — unmute sirf admin kar sakta hai.');
      return;
    }
    if (_room.pushToTalk) await _room.setPushToTalk(false);
    // FIX 20 (fix 8): 2s timeout + generation guard, same as the
    // LiveKit path above.
    try {
      await _room.setMuted(!_room.muted).timeout(const Duration(seconds: 2));
    } on TimeoutException {
      if (mounted && gen == _seatToggleGen) {
        toast(context, 'Mic respond nahi kar raha, dobara try karein');
      }
      return;
    }
    if (mounted && gen == _seatToggleGen) setState(() {});
    // FIX 22 item 10: re-apply the music volume at once — the
    // voice must win immediately (FIX 22 item 11: direct, no
    // fade); do not wait for the ~2 s poll listener.
    if (gen == _seatToggleGen) await _applyMusicVolume();
  }

  // PRESENCE GATE (2026-10-30): one online rule for seats/strip.
  // Own seat is always shown by mic state (you are looking at the
  // screen). For everyone else: if a presence row exists and its
  // last_seen is older than 2 min, the user reads GREY + no wave,
  // even if their voice peer row has not been pruned yet. If no
  // presence row exists, voice freshness alone decides (a missing
  // presence write must never silence a live speaker).
  bool _peerLooksOnline(String uid, String myUid) {
    if (uid.isEmpty || uid == myUid) return true;
    final pres = _presenceMap[uid];
    if (pres == null) return true;
    return SupaDb.presenceIsOnline(pres);
  }

  Widget _avatar(String name, bool unmuted, [String uid = '', double radius = 30]) {
    // GREEN dot = mic ON (unmuted state); grey dot = muted. Avatar is
    // frame-wrapped when the member has an equipped frame. Seats are
    // deliberately LARGE (round 4): a 60px framed avatar + name below,
    // like the reference room's circular seat layout (original art).
    // Admin frames need no special-casing here: the admin's chosen
    // admin_* frame IS their equipped frame (see SupaDb), so it
    // renders through this same path on every phone in the room.
    return CachedFramedAvatar(
      uid: uid,
      name: name,
      radius: radius,
      dotColor: unmuted ? Colors.greenAccent : kMuted,
    );
  }


  // USER ORDER 2026-11-01: chat tab buttons + Voice Chat peers list removed (tabs gone).

  Widget _chatItem(Map<String, dynamic> item, String uid) {
                    if (item.containsKey('welcome')) {
                      // Animated welcome row INSIDE the chat list:
                      // slide/fade-in once, then it STAYS in the
                      // session's chat history (no 6s auto-hide).
                      return TweenAnimationBuilder<double>(
                        tween: Tween(begin: 0.0, end: 1.0),
                        duration: const Duration(milliseconds: 500),
                        // ROUND 7 QA: fade ONLY, same reason as seats:
                        // the old slide-in painted the banner over the
                        // message above it for 500ms per welcome.
                        builder: (context, v, child) => Opacity(
                          opacity: v,
                          child: child,
                        ),
                        child: Center(
                          child: Container(
                            // ROUND 11: welcome rows highlighted like
                            // the reference ("wc ji" style) — richer
                            // gold-tinted pill, larger text, still
                            // name-coloured and centred in chat.
                            margin: const EdgeInsets.only(bottom: 12),
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
                            decoration: BoxDecoration(
                              gradient: LinearGradient(colors: [kGold.withValues(alpha: 0.22), const Color(0xFF120C06)]),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: kGold, width: 1),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.celebration, color: kGold, size: 16),
                                const SizedBox(width: 8),
                                Flexible(child: Text('${strVal(item['welcome'])} entered the room', style: TextStyle(color: kGold, fontWeight: FontWeight.bold, fontSize: 13, height: 1.3), maxLines: 2, textAlign: TextAlign.center)),
                              ],
                            ),
                          ),
                        ),
                      );
                    }
                    if (item.containsKey('sep')) {
                      return Center(
                        child: Container(
                          margin: const EdgeInsets.symmetric(vertical: 8),
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
                          decoration: BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(14)),
                          child: Text(strVal(item['sep']), style: TextStyle(color: kMuted, fontSize: 11, fontWeight: FontWeight.bold)),
                        ),
                      );
                    }
                    final m = item;
                    final reply = SupaDb.asMap(m['reply_to']);
                    final gift = _isGift(m);
                    final image = _isImage(m);
                    final sender = strVal(m['display_name'], 'User');
                    final senderUid = strVal(m['firebase_uid'], sender);
                    // PHASE 3 #27 ORGANIZER badge: chat_messages has NO
                    // is_admin column (001; sendChat drops the flag), so
                    // m['is_admin'] is ~always false on live rows. The
                    // room's real determination is the designated admin
                    // (admin_config.admin_firebase_uid -> _adminUid,
                    // _loadRoomAdmin), with the tournament creator as
                    // fallback ONLY when the admin UID is unreadable —
                    // the same rule as _hostEntry. m['is_admin'] stays
                    // as a fallback for any row that does carry it.
                    final isOrganizer = m['is_admin'] == true ||
                        (senderUid.isNotEmpty && _adminUid.isNotEmpty && senderUid == _adminUid) ||
                        (senderUid.isNotEmpty && _adminUid.isEmpty && _creatorUid.isNotEmpty && senderUid == _creatorUid);
                    final nameColor = isOrganizer ? nBlue : _avatarColor(senderUid);
                    // PHASE 3 #27 squad tag: team_name from the
                    // registration rows the room already loads
                    // (_roomRegTeams). Empty = Solo / no team known —
                    // no tag shown, never invented.
                    final squadTag = _roomRegTeams[senderUid] ?? '';
                    // ROUND 11 CHAT LOOK (reference pattern, original
                    // styling only): messages float over the themed
                    // gradient background — no boxed card — with the
                    // avatar left, a COLOURED name, then the text
                    // inside a subtle semi-transparent dark rounded
                    // container so it reads clearly over the
                    // background. Gifts are LARGE and prominent.
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: InkWell(
                        onTap: () => setState(() => _replyTo = m),
                        // PHASE 3 #27 LONG-PRESS: every member gets the
                        // message menu (Report Message; Clear Chat stays
                        // admin-only inside it). Previously onLongPress
                        // was null for non-admins, so nobody could
                        // report a message.
                        onLongPress: () => _showMessageLongPressMenu(m, uid),
                        borderRadius: BorderRadius.circular(12),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            CachedFramedAvatar(uid: senderUid, name: sender, radius: 18, avatarColor: _avatarColor(senderUid)),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Flexible(child: Text(sender, style: TextStyle(color: nameColor, fontSize: 13, fontWeight: FontWeight.w800), maxLines: 2)),
                                      if (isOrganizer) Padding(padding: const EdgeInsets.only(left: 4), child: Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1), decoration: BoxDecoration(color: nGold, borderRadius: BorderRadius.circular(8)), child: const Text('ORGANIZER', style: TextStyle(color: Color(0xFF1A1208), fontSize: 9, fontWeight: FontWeight.w800)))),
                                      if (squadTag.isNotEmpty) Padding(padding: const EdgeInsets.only(left: 4), child: Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1), decoration: BoxDecoration(color: kGold.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(8), border: Border.all(color: kGold.withValues(alpha: 0.5))), child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 90), child: Text(squadTag, style: TextStyle(color: kGold, fontSize: 9, fontWeight: FontWeight.bold), maxLines: 1, overflow: TextOverflow.ellipsis)))),
                                      const SizedBox(width: 6),
                                      Text(hhmm(m['timestamp'] ?? m['created_at']), style: TextStyle(color: kMuted, fontSize: 10)),
                                      if (senderUid.isNotEmpty && senderUid != uid)
                                        Padding(
                                          padding: const EdgeInsets.only(left: 8),
                                          child: InkWell(
                                            onTap: () async {
                                              try {
                                                if (_following.contains(senderUid)) {
                                                  await SupaDb.client.from('follows').delete().eq('follower_uid', uid).eq('following_uid', senderUid);
                                                  setState(() => _following.remove(senderUid));
                                                  if (mounted) toast(context, 'Unfollowed $sender');
                                                } else {
                                                  await SupaDb.client.from('follows').insert({'follower_uid': uid, 'following_uid': senderUid});
                                                  setState(() => _following.add(senderUid));
                                                  if (mounted) toast(context, 'Followed $sender');
                                                }
                                              } catch (e) {
                                                if (mounted) toast(context, 'Follow failed: $e');
                                              }
                                            },
                                            child: Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                                              decoration: BoxDecoration(color: _following.contains(senderUid) ? kCard : kGold, borderRadius: BorderRadius.circular(12)),
                                              child: Text(_following.contains(senderUid) ? 'Following' : 'Follow', style: TextStyle(color: _following.contains(senderUid) ? kGold : Colors.black, fontSize: 10, fontWeight: FontWeight.bold)),
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                  const SizedBox(height: 3),
                                  if (reply.isNotEmpty)
                                    Container(
                                      margin: const EdgeInsets.only(top: 2, bottom: 2),
                                      padding: const EdgeInsets.only(left: 8),
                                      decoration: BoxDecoration(border: Border(left: BorderSide(color: kGold, width: 2))),
                                      child: Text(_replyLabel(reply), style: const TextStyle(color: Colors.white70, fontSize: 12), maxLines: 2, overflow: TextOverflow.ellipsis),
                                    ),
                                  if (image)
                                    Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Container(
                                          decoration: BoxDecoration(borderRadius: BorderRadius.circular(16), border: Border.all(color: kGold.withValues(alpha: 0.6), width: 1.2), boxShadow: [BoxShadow(color: kGold.withValues(alpha: 0.18), blurRadius: 12, spreadRadius: 1)]),
                                          child: ClipRRect(
                                            borderRadius: BorderRadius.circular(15),
                                            child: (_lowData && !_loadedImages.contains(strVal(m['id'], strVal(m['created_at']))))
                                                ? InkWell(
                                                    onTap: () => setState(() => _loadedImages.add(strVal(m['id'], strVal(m['created_at'])))),
                                                    child: Container(
                                                      width: 280,
                                                      height: 150,
                                                      color: kCard,
                                                      alignment: Alignment.center,
                                                      child: Column(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.image, color: kGold, size: 32), SizedBox(height: 6), Text('Tap to load image (low-data mode)', style: TextStyle(color: kGold, fontSize: 12, fontWeight: FontWeight.bold))]),
                                                    ),
                                                  )
                                                : ArenaCachedImage(
                                              imageUrl: _imageOf(m),
                                              width: 280,
                                              height: 200,
                                              fit: BoxFit.cover,
                                              borderRadius: BorderRadius.circular(15),
                                            ),
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        // REMAINING-ITEMS shared reactions: stored in
                                        // chat_messages.reactions (jsonb emoji -> [uids],
                                        // migration 011) and shown to every member
                                        // with counts. Tap toggles your own reaction.
                                        Builder(builder: (context) {
                                          final raw = SupaDb.asMap(m['reactions']);
                                          final counts = <String, int>{};
                                          final mine = <String>{};
                                          raw.forEach((k, v) {
                                            final list = (v as List?)?.map((e) => e.toString()).toList() ?? <String>[];
                                            counts[k.toString()] = list.length;
                                            if (list.contains(uid)) mine.add(k.toString());
                                          });
                                          return Row(
                                            children: [
                                              for (final e in ['❤️', '👍', '🔥'])
                                                Padding(
                                                  padding: const EdgeInsets.only(right: 6),
                                                  child: InkWell(
                                                    onTap: () async {
                                                      final id = strVal(m['id']);
                                                      if (id.isEmpty) return;
                                                      final next = Map<String, dynamic>.from(raw);
                                                      final list = (next[e] as List?)?.map((x) => x.toString()).toList() ?? <String>[];
                                                      if (list.contains(uid)) {
                                                        list.remove(uid);
                                                      } else {
                                                        list.add(uid);
                                                      }
                                                      if (list.isEmpty) {
                                                        next.remove(e);
                                                      } else {
                                                        next[e] = list;
                                                      }
                                                      try {
                                                        await SupaDb.client.from('chat_messages').update({'reactions': next}).eq('id', id);
                                                      } catch (err) {
                                                        if (mounted) toast(context, 'Reaction failed: $err');
                                                      }
                                                    },
                                                    borderRadius: BorderRadius.circular(12),
                                                    child: Container(
                                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                                      decoration: BoxDecoration(
                                                        color: mine.contains(e) ? kGold.withValues(alpha: 0.25) : kCard,
                                                        borderRadius: BorderRadius.circular(12),
                                                        border: Border.all(color: mine.contains(e) ? kGold : const Color(0xFF334155)),
                                                      ),
                                                      child: Text((counts[e] ?? 0) > 0 ? '$e ${counts[e]}' : e, style: const TextStyle(fontSize: 14)),
                                                    ),
                                                  ),
                                                ),
                                              Text('reactions sab ko dikhte hain', style: TextStyle(color: kMuted, fontSize: 9)),
                                            ],
                                          );
                                        }),
                                      ],
                                    )
                                  else if (gift)
                                    // ROUND 11: gifts are LARGE and
                                    // prominent like the reference —
                                    // big gift glyph + big gold
                                    // "× 1", not a small line. (Stickers
                                    // were removed 2026-10-30: the old
                                    // 44px sticker branch is deleted and
                                    // sticker rows are filtered above,
                                    // so this branch is gifts only.)
                                    Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                                        decoration: BoxDecoration(
                                          color: kGold.withValues(alpha: 0.14),
                                          borderRadius: BorderRadius.circular(18),
                                          border: Border.all(color: kGold.withValues(alpha: 0.55), width: 1.2),
                                          boxShadow: [BoxShadow(color: kGold.withValues(alpha: 0.20), blurRadius: 12, spreadRadius: 1)],
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          crossAxisAlignment: CrossAxisAlignment.center,
                                          children: [
                                          TweenAnimationBuilder<double>(
                                            tween: Tween(begin: 0.6, end: 1.0),
                                            duration: const Duration(milliseconds: 250),
                                            builder: (context, v, child) => Transform.scale(scale: v, alignment: Alignment.centerLeft, child: child),
                                            child: Text(_giftOf(m), style: const TextStyle(fontSize: 72)),
                                          ),
                                          const SizedBox(width: 10),
                                          Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Text('× 1', style: TextStyle(color: kGold, fontSize: 34, fontWeight: FontWeight.w900)),
                                              Text('sent a gift • Free', style: TextStyle(color: kMuted, fontSize: 10)),
                                            ],
                                          ),
                                          ],
                                        ),
                                      )
                                  else
                                    // CHAT READABILITY (2026-10-30, revised
                                    // 2026-10-30: user order — SMALLER
                                    // fonts, 16px was too big): 14px
                                    // message text, 1.4 line height,
                                    // slimmer bubble padding so more
                                    // messages fit on screen at once.
                                    // P1-7: the shared mockup-#27 bubble
                                    // shell ([ArenaChatBubble] — no tail,
                                    // own = gold-tinted + gold border)
                                    // replaces the old WhatsApp-style
                                    // [ChatBubble]. The room keeps its
                                    // avatar-left group layout (avatar +
                                    // coloured name + time + Follow stay
                                    // in the header row above, so the
                                    // bubble carries no name/time); only
                                    // the bubble shell changed. Shout
                                    // keeps its gold highlight colours.
                                    // Reply / gift / image / welcome /
                                    // music rows above are untouched.
                                    ArenaChatBubble(
                                      isMine: senderUid.isNotEmpty && senderUid == uid,
                                      // Room group layout: every bubble
                                      // stays left-aligned under its
                                      // avatar + name row; own messages
                                      // are told apart by the gold tint.
                                      alignEnd: false,
                                      text: _isShout(m) ? '📣 ${_shoutOf(m)}' : _isCheer(m) ? _cheerOf(m) : strVal(m['message']),
                                      highlight: _isShout(m),
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                    }

  Future<void> _retryVoice() async {
    setState(() => _voiceRetrying = true);
    await _room.retry();
    if (mounted) {
      setState(() => _voiceRetrying = false);
      if (_room.error != null) toast(context, _room.error!);
    }
  }

  // ROUND 7 voice diagnostics: the room must never again show a green
  // mic while the audio path is silently dead. One tap opens the real
  // state — mic track, speaker, per-peer ICE, remote audio received,
  // signaling sent/failed — plus Retry, which fully rebuilds voice.
  /// FIX 22 item 8 — the diagnostics DSP line: available, the
  /// specific probe failure reason, or "not checked yet" (no
  /// probe has run this session — never a fake status).
  String _dspDiagLine() {
    final cached = DspMicProcessor.cachedAvailable;
    if (cached == true) return 'available ✓';
    if (cached == false) {
      final failure = DspMicProcessor.lastProbeFailure;
      if (failure == DspMicInitFailure.none) {
        return 'unavailable (reason unknown)';
      }
      return dspFailureLabel(failure);
    }
    return 'not checked yet (open the RJ console to probe)';
  }

  Widget _voiceDiagnostics() {
    final peers = _room.peers;
    // FIX 22 item 8: fetch the native DSP error once while the
    // panel is open (post-frame — a build must not setState).
    // The flag flips synchronously so repeat builds before the
    // frame runs never schedule a second fetch.
    if (!_dspNativeErrorLoaded) {
      _dspNativeErrorLoaded = true;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        final msg = await DspMicProcessor.nativeLoadError();
        if (mounted) setState(() => _dspNativeError = msg);
      });
    }
    String iceLabel(String uid) {
      final s = _room.iceStates[uid];
      if (s == null) return 'no connection yet';
      if (s.contains('connected') || s.contains('completed')) return 'connected ✓';
      if (s.contains('failed')) return 'FAILED ✗';
      return s;
    }

    // 2026-11-20 (user order, "har jagah"): the diagnostics panel
    // is a MockupCard too; its heading uses the section-label gold.
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: MockupCard(
        padding: const EdgeInsets.all(10),
        radius: 10,
        child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Voice diagnostics — what is actually happening', style: TextStyle(color: kSectionLabel, fontWeight: FontWeight.bold, fontSize: 12)),
          const SizedBox(height: 4),
          Text('My mic track: ${_room.localMicEnabled ? 'ON (sending)' : 'OFF'} • Mic tracks: ${_room.localAudioTracks} • Speaker: On • Muted: ${_room.muted ? 'Yes' : 'No'}', style: TextStyle(color: kText, fontSize: 11)),
          Text('DSP mic: ${_dspDiagLine()}', style: TextStyle(color: kText, fontSize: 11)),
          if (_dspNativeError != null && _dspNativeError!.isNotEmpty)
            Text('DSP native error: ${_dspNativeError!}', style: const TextStyle(color: Colors.orangeAccent, fontSize: 11)),
          Text('Headset rule: headset connected ho to voice headset me jayegi; warna hamesha loudspeaker par.', style: TextStyle(color: kMuted, fontSize: 11)),
          Text('Audio path: ${_room.audioEstablished ? 'ESTABLISHED ✓ (at least one peer connected)' : 'NOT established yet — if this stays, tap Retry'}', style: TextStyle(color: _room.audioEstablished ? Colors.greenAccent : Colors.orangeAccent, fontSize: 11, fontWeight: FontWeight.bold)),
          Text('Signals sent: ${_room.signalSent} • failed: ${_room.signalFailed}', style: TextStyle(color: kText, fontSize: 11)),
          Text('Silent ICE recovery attempts: ${_room.iceRecoveryAttempts} (automatic, no reconnect prompt)', style: TextStyle(color: kText, fontSize: 11)),
          if (_room.lastSignalError != null) Text('Last signal error: ${_room.lastSignalError}', style: const TextStyle(color: Colors.redAccent, fontSize: 11)),
          if (peers.isEmpty)
            Text('No other voice peers right now — nobody else is on voice in this room.', style: TextStyle(color: kMuted, fontSize: 11))
          else
            for (final e in peers.entries)
              Text('${(e.value['display_name'] ?? e.value['name'] ?? 'Player').toString()} • ICE: ${iceLabel(e.key)} • remote audio: ${_room.audioPeers.contains(e.key) ? 'received ✓' : 'not received yet'} • mic: ${e.value['muted'] == true ? 'muted' : 'unmuted'}', style: TextStyle(color: kText, fontSize: 11), maxLines: 2, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 4),
          Text('If ICE says FAILED on both phones, both networks are blocking direct voice — the app then falls back to the free relay over TCP (port 443). Retry rebuilds the connection with that fallback.', style: TextStyle(color: kMuted, fontSize: 11)),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _voiceRetrying ? null : _retryVoice,
                  icon: Icon(Icons.refresh, color: kGold, size: 16),
                  label: Text(_voiceRetrying ? 'Retrying…' : 'Retry voice', style: TextStyle(color: kGold, fontSize: 12)),
                ),
              ),
              const SizedBox(width: 8),
              TextButton(onPressed: () => setState(() => _showVoiceDiag = false), child: Text('Hide', style: TextStyle(color: kMuted, fontSize: 12))),
            ],
          ),
        ],
      ),
        ),
    );
  }

  /// v2017 INLINE VOICE (user order 2026-11-22): the host strip,
  /// extracted from build() so the embedded (inline-panel) mode
  /// renders the SAME strip without duplicating it. Behaviour is
  /// unchanged in full-page mode — the call site is identical.
  /// FIX 1 COMPACT VOICE PANEL (user order 2026-11-22): when
  /// [compactControls] is true (embedded panel only), the host
  /// card is tighter (less padding, smaller avatar).
  /// FIX 16 (user order 2026-11-23): the compact card carries
  /// ONLY the Connecting / Voice On pill now, in the same row as
  /// the green mic button (Live column, pill, mic) — Music / RJ /
  /// Settings left the card for the header Settings sheet, and
  /// the card is tighter still (vertical padding 10 -> 8). The
  /// full room page keeps the current card (compactControls
  /// false): its rail already has Music/Settings.
  /// FIX12 G9 (user order 2026-11-23, §9 — top box compact):
  /// the compact card is shorter still — outer top 8 -> 6, card
  /// padding 10 -> 8 (already 8 via FIX 16), the tagline gone
  /// with G7, the controls row gone with FIX 16 (no gap at
  /// all), the Live-column gaps 4 -> 2, and the Mute/Unmute
  /// label under the mic hidden (the Live column beside it
  /// already says Mic on / Muted, and the mic icon itself
  /// shows the state). Whole top box ≈110px vs ≈134px before.
  /// Full page unchanged. G7 owns the labels in this box —
  /// G9 touches layout/height only.
  Widget _buildHostStrip(String uid, Map<String, Map<String, dynamic>> peers, {bool compactControls = false}) {
    // MASTER-PROMPT host panel (§9) — FIRST at the top (user order 2026-10-30).
      // FIX 23 item 17: the host slot shows ONLY the organizer
      // (see _hostEntry) — never a member's photo; host absent
      // -> 'No host' + an empty slot. The wave shows the mic-ON
      // state (the room has no per-peer speaking detection — see
      // report); it is labelled "Mic on", never "Speaking...",
      // so no speech is faked.
      // FIX 31b: the card's contents are re-skinned in the AI
      // Studio host-card language (royal-gold Host pill +
      // crown, gold-blue avatar ring, Rajdhani name). The
      // MockupCard shell, the verified-tick rule (item 19) and
      // the mic button (16b gate) are UNCHANGED.
    return FutureBuilder<Map<String, dynamic>>(
        future: _tournamentFuture,
        builder: (context, tsnap) {
          final occupied = peers.entries.toList();
          final host = _hostEntry(tsnap.hasData ? tsnap.data : null, occupied);
          final hostUid = host == null ? '' : host['uid'] as String;
          final hostName = host == null ? 'No host' : host['name'] as String;
          final hostOnVoice = host != null && !(host['offline'] == true) && occupied.any((e) => e.key == hostUid);
          final hostUnmuted = hostOnVoice && !(host['muted'] == true) && _peerLooksOnline(hostUid, uid);
          final hostIsMe = hostUid == uid;
          final hostIsAdminOwner = hostUid.isNotEmpty && _adminUid.isNotEmpty && hostUid == _adminUid;
          // FIX 22 item 14 — host-card dressing, all real data:
          // tagline = organizer bio (async, _hostBioFor) else the
          // scope description (parent param, else the tournament
          // row); cover = parent param else the tournament banner;
          // scope name from the matching widget field; live
          // members = the Participants-list count, shown only
          // once the room can actually know it (joined, or
          // presence data arrived) — never a pre-join fake 0.
          final description = widget.hostCardDescription.isNotEmpty
              ? widget.hostCardDescription
              : (widget.scope == 'tournament' && tsnap.hasData
                  ? SupaDb.strOf(tsnap.data!['description'])
                  : '');
          final coverUrl = widget.hostCardCoverUrl.isNotEmpty
              ? widget.hostCardCoverUrl
              : (widget.scope == 'tournament' && tsnap.hasData
                  ? _bannerOf(tsnap.data!)
                  : '');
          final scopeName = _isCommunity
              ? widget.communityName
              : _isTeam
                  ? widget.teamName
                  : widget.tournamentName;
          // FIX 22 item 16 SUPERSEDES item 14e's 'N live' in the
          // scope line — the live count moved into the tappable
          // members button below (total + online). The old
          // liveKnown/liveCount locals are gone with it.
          // FIX 23 item 2 (SUPERSEDES v2022 Gate-1's
          // LayoutBuilder): the host-card pieces, hoisted so
          // the compact card lays them out as TWO rows (row 1:
          // avatar + name + mic; row 2: the status strip) and
          // the full page as ONE row. Built once, laid out
          // twice — the widgets themselves are UNCHANGED (same
          // avatar, name, pill, Live column, mic).
          // NEON REDESIGN: gold crown above the avatar,
          // as in the mockup (FIX 31b: the AI Studio Lucide
          // crown glyph, not the emoji — the avatar photo
          // itself stays the real host photo from app data).
          // FIX 23 item 17 — the host slot renders ONLY the
          // organizer's photo (via _hostEntry). Host absent ->
          // an EMPTY bordered circle (same 56/64px size, no
          // icon, no face, no crown) — never a member's photo.
          // FIX 31b: the empty host slot in the AI Studio
          // host-card language (glass surface + purple ring,
          // same as the screen's no-host circle).
          final hostAvatar = host == null
              ? Container(
                  width: compactControls ? 56 : 64,
                  height: compactControls ? 56 : 64,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: ArenaColors.purple.withValues(alpha: 0.5), width: 1.5),
                    color: ArenaColors.glassSurface,
                  ),
                )
              : Stack(
            clipBehavior: Clip.none,
            children: [
              Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  // FIX 31b: the avatar ring is the AI Studio
                  // host gradient (royal gold -> electric blue)
                  // with a soft gold glow while the host mic is
                  // on; the muted ring stays the dark neutral
                  // pair.
                  gradient: LinearGradient(colors: hostUnmuted ? [ArenaColors.royalGold, ArenaColors.electricBlue] : [const Color(0xFF3A3F5C), const Color(0xFF23263E)], begin: Alignment.topLeft, end: Alignment.bottomRight),
                  boxShadow: hostUnmuted ? [BoxShadow(color: ArenaColors.royalGold.withValues(alpha: 0.35), blurRadius: 10)] : null,
                ),
                // FIX 1: smaller avatar in the embedded
                // panel (radius 30 -> 26) + smaller crown.
                child: _avatar(hostName, hostUnmuted, hostUid, compactControls ? 26 : 30),
              ),
              // FIX 31b: the crown is the AI Studio Lucide crown
              // glyph (royal gold), not the emoji.
              Positioned(top: compactControls ? -10 : -12, left: 0, right: 0, child: Center(child: Icon(LucideIcons.crown, color: ArenaColors.royalGold, size: compactControls ? 17 : 19))),
            ],
          );
          final hostGap = SizedBox(width: compactControls ? 8 : 10);
          final hostMiddle = Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // FIX 22 item 14 (user order 2026-11-23,
                // from the reference screenshot): the gold
                // Host pill is BACK above the name —
                // SUPERSEDES FIX 12 G7's "name only, no
                // Host pill" rule (the user's latest direct
                // order). 'Room Owner' / 'Tournament
                // Creator' stay GONE — never re-add them.
                // FIX 23 item 3 — the community/stream name
                // INSIDE the card, next to the Host pill (real
                // name from community data, never a sample).
                // Item 16c — the community IMAGE beside the
                // name (photo_url via the cover; no photo ->
                // the trophy icon fallback, never a fake image).
                Row(
                  children: [
                    // FIX 31b: the Host pill in the AI Studio
                    // host-card language — royal-gold fill,
                    // crown glyph, dark text (same pill as the
                    // full-page screen's host card).
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(color: ArenaColors.royalGold, borderRadius: BorderRadius.circular(20)),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(LucideIcons.crown, size: 11, color: ArenaColors.primaryBg),
                          const SizedBox(width: 4),
                          Text('Host', style: ArenaTypography.body(10, color: ArenaColors.primaryBg, weight: FontWeight.w800)),
                        ],
                      ),
                    ),
                    if (scopeName.isNotEmpty) ...[
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(scopeName, style: ArenaTypography.body(12, color: ArenaColors.royalGold, weight: FontWeight.w700), maxLines: 1, overflow: TextOverflow.ellipsis),
                      ),
                    ],
                    const SizedBox(width: 6),
                    if (coverUrl.isNotEmpty)
                      ArenaCachedImage(imageUrl: coverUrl, width: 20, height: 20, borderRadius: BorderRadius.circular(6))
                    else
                      Icon(Icons.emoji_events, color: ArenaColors.royalGold, size: 16),
                  ],
                ),
                const SizedBox(height: 3),
                Row(
                  children: [
                    Flexible(child: Text(hostName, style: ArenaTypography.heading(17), maxLines: 1, overflow: TextOverflow.ellipsis)),
                    // FIX 22 item 19: the blue tick INLINE
                    // beside the name, on the SAME line
                    // (Facebook-verified style — never
                    // below the name). Shown when earned:
                    // verified flag (profile row via
                    // _hostVerifiedFor, or the community
                    // row via widget.hostCardVerified) OR
                    // 1000+ followers (same real count as
                    // the sidebar Followers icon). The
                    // admin owner keeps the pre-existing
                    // tick. An unavailable count earns
                    // nothing — never a fake tick.
                    FutureBuilder<bool>(
                      future: _hostVerifiedFor(hostUid),
                      builder: (context, vsnap) {
                        // FIX 23 item 17: no host -> no tick
                        // either (the slot is empty, not a user).
                        final show = hostUid.isNotEmpty &&
                            (hostIsAdminOwner ||
                                widget.hostCardVerified ||
                                hostVerifiedTick(
                                    flag: vsnap.data ?? false,
                                    followersCount:
                                        widget.sidebarFollowersCount));
                        if (!show) return const SizedBox.shrink();
                        return const Padding(padding: EdgeInsets.only(left: 4), child: Icon(Icons.verified, color: nBlue, size: 16));
                      },
                    ),
                  ],
                ),
                // FIX 22 item 14b — tagline: the organizer's
                // profile bio when one exists, else the
                // scope description; omitted when neither
                // exists. NEVER the screenshot's sample
                // text. The description shows at once; the
                // bio replaces it when its lookup lands.
                FutureBuilder<String>(
                  future: _hostBioFor(hostUid),
                  builder: (context, snap) {
                    final bio = snap.data ?? '';
                    final tag = bio.isNotEmpty ? bio : description;
                    if (tag.isEmpty) return const SizedBox.shrink();
                    return Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(tag, style: TextStyle(color: ArenaColors.secondaryText, fontSize: 11, fontStyle: FontStyle.italic, height: 1.2), maxLines: 1, overflow: TextOverflow.ellipsis),
                    );
                  },
                ),
                // FIX 23 item 3: the scope name moved UP next to
                // the Host pill (above); the small muted line
                // is gone. Item 12b: the members button is
                // gone too — "Members" must not appear in the
                // room; the count lives in the sidebar
                // Followers entry (item 9/12a).
              ],
            ),
          );
          // FIX 23 item 2: the compact card no longer uses
          // this list — its row 1 holds the mic button
          // directly and row 2 holds the status strip (the
          // G9-pinned compact branch + its two 8px gaps are
          // SUPERSEDED by the two-row layout). Full-page
          // keeps the single-row right controls, unchanged.
          final rightControls = <Widget>[
            _buildHostLiveColumn(hostUnmuted, hostOnVoice),
            const SizedBox(width: 10),
            _buildHostMicButton(hostOnVoice: hostOnVoice, hostIsMe: hostIsMe, hostUnmuted: hostUnmuted, hostName: hostName),
          ];
          // 2026-11-20 (user order, "har jagah"): host strip is
          // a MockupCard — gradient fill + the two rotating gold
          // corner shines, no static neon border. Contents
          // unchanged; only the card shell + Live pill colour.
          return Padding(
            // FIX12 G9 (§9): outer top 8 -> 6 in compact mode.
            // (G9 pins this literal — do not tokenize it.)
            padding: EdgeInsets.fromLTRB(12, compactControls ? 6 : 8, 12, 0),
            // v2015 (user order 2026-11-22): animate: false —
            // the rotating bottom shine travelled along the
            // card's bottom edge and read as a thin yellow
            // divider line under the host card. Parked, the
            // shines sit at the top-right + bottom-left
            // corners (the mockup's rest look) and no line
            // ever crosses the bottom edge. (Sparks go with
            // the ticker on this one card.)
            // REDESIGN S7 (2026-11-23, guide §C/§I): the compact
            // card is 2px narrower per side (horizontal 12, full
            // page keeps 14) — at 360px the fixed right side (Live
            // column + pill + 56px mic) + the avatar left ~0px for
            // the name, and the failed state's longer 'Not
            // connected' line overflowed by 12px. (Fix 1/16/G9 pin
            // the vertical literal; v2015 pins radius 22 — neither
            // may be tokenized, and no comment may sit between the
            // card constructor and animate: false: v2015 reads a
            // 400-char window there.)
            child: MockupCard(
              // FIX 1: tighter card in the embedded panel
              // (vertical 14 -> 10) — the card is a bit shorter.
              // FIX 16: tighter still (10 -> 8).
              padding: EdgeInsets.symmetric(horizontal: compactControls ? 12 : 14, vertical: compactControls ? 8 : 14),
              radius: 22,
              animate: false,
              child: Stack(
                children: [
                  // FIX 22 item 14c — cover image dimmed behind
                  // the content (scope photo / tournament
                  // banner); no cover = the MockupCard gradient
                  // + glow underneath stays the background.
                  if (coverUrl.isNotEmpty)
                    Positioned.fill(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            ArenaCachedImage(
                              imageUrl: coverUrl,
                              fit: BoxFit.cover,
                            ),
                            Container(
                              color: Colors.black.withValues(alpha: 0.62),
                            ),
                          ],
                        ),
                      ),
                    ),
                  // FIX 23 item 2 — the compact card is ALWAYS
                  // two rows now (the v2022 Gate-1 LayoutBuilder
                  // narrow/wide split is SUPERSEDED — the card
                  // is full width above the sidebar, so row 1
                  // [avatar + middle + mic] always fits and
                  // row 2 is a Wrap: zero overflow at 360px by
                  // construction, pinned by tests). Full-page
                  // keeps the single row, unchanged.
                  if (compactControls)
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            hostAvatar,
                            hostGap,
                            hostMiddle,
                            hostGap,
                            _buildHostMicButton(hostOnVoice: hostOnVoice, hostIsMe: hostIsMe, hostUnmuted: hostUnmuted, hostName: hostName, compact: true),
                          ],
                        ),
                        const SizedBox(height: 6),
                        // FIX 31b: the strip keeps the connection
                        // state only — LIVE + listeners live in
                        // the panel header strip now (one home,
                        // no duplication).
                        _buildHostStatusStrip(),
                      ],
                    )
                  else
                    Row(
                      children: [
                        hostAvatar,
                        hostGap,
                        hostMiddle,
                        hostGap,
                        ...rightControls,
                      ],
                    ),
                ],
              ),
              ),
          );
        },
      );
  }

  /// FIX 1: the host card's Live pill + wave + status column,
  /// extracted from [_buildHostStrip] so the embedded compact
  /// layout and the full-page layout share one copy. Rendering
  /// unchanged. FIX12 G9 (§9): [compact] tightens the two gaps
  /// 4 -> 2 in the compact card only.
  /// FIX 23 item 2/12c — the Live pill, extracted from
  /// [_buildHostLiveColumn] so the compact card's status strip
  /// reuses the identical widget (same red tint, same mic icon).
  Widget _buildLivePill() {
    // FIX 31b: the Live pill on the AI Studio tokens — live red
    // tint, mic icon + 'Live' text, Inter type. Same gating
    // (host on voice only) as before.
    return Container(padding: const EdgeInsets.symmetric(horizontal: kSpace8, vertical: kSpace4), decoration: BoxDecoration(color: ArenaColors.liveRed.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(kRadiusChip), border: Border.all(color: ArenaColors.liveRed.withValues(alpha: 0.6))), child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.mic, color: ArenaColors.liveRed, size: 12), SizedBox(width: 4), Text('Live', style: ArenaTypography.body(11, color: ArenaColors.liveRed, weight: FontWeight.w800))]));
  }

  /// FIX 23 item 2/12c — the listeners row (headphone icon +
  /// the REAL LiveListeners count), extracted from
  /// [_buildHostLiveColumn] for the compact status strip.
  Widget _buildListenersRow() {
    // Listeners: the REAL LiveListeners count (the same
    // source the RJ panel's strip uses), rebuilt live via
    // ListenableBuilder — never faked, never a stale copy.
    // FIX 31b: electric-blue headset on the AI Studio tokens.
    return ListenableBuilder(
      listenable: _liveListeners,
      builder: (context, _) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.headset, color: ArenaColors.electricBlue, size: 11),
          const SizedBox(width: 3),
          Text('${_liveListeners.listenerCount}', style: ArenaTypography.body(10, color: ArenaColors.secondaryText, weight: FontWeight.w800)),
        ],
      ),
    );
  }

  /// FIX 23 item 2/12c — the Connected/Disconnected box,
  /// extracted from [_buildHostLiveColumn] for the compact
  /// status strip (same _voiceConnected truth as the pill).
  Widget _buildConnectedBox() {
    // FIX 22 item 14c: connection state in a small box —
    // Connected / Disconnected from the SAME truth as the
    // Connecting pill (_voiceConnected), rebuilt live. 8px
    // text keeps 'Disconnected' no wider than the status
    // line above, so the 360px fit is unchanged.
    return ListenableBuilder(
      listenable: Listenable.merge([_room, _lkRoom]),
      builder: (context, _) {
        final connected = _voiceConnected;
        final color = connected ? ArenaColors.connectedGreen : ArenaColors.secondaryText;
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(kRadiusChip),
            border: Border.all(color: color.withValues(alpha: 0.5)),
          ),
          child: Text(connected ? 'Connected' : 'Disconnected', style: ArenaTypography.body(8, color: color, weight: FontWeight.w800)),
        );
      },
    );
  }

  /// FIX 23 items 2 + 12c — the compact card's slim status
  /// strip: the Connecting pill + the Connected box, in a Wrap
  /// so it can never overflow at 360px (it flows to a second
  /// line instead). No wave, no members line (item 12b removed
  /// it).
  /// FIX 31b: the Live pill + listeners row moved OUT of this
  /// strip into the panel header strip (_fix31bHeaderStrip) —
  /// LIVE + listeners have ONE home now, so they are never
  /// shown twice.
  Widget _buildHostStatusStrip() {
    return Wrap(
      spacing: 8,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _buildConnectingPill(),
        _buildConnectedBox(),
      ],
    );
  }

  Widget _buildHostLiveColumn(bool hostUnmuted, bool hostOnVoice, {bool compact = false}) {
    return Column(children: [
      // FIX 22 item 14b: LIVE shows ONLY when the room is
      // actually live (host connected on voice) — when not
      // live, the Connecting pill beside it carries the state
      // instead (never a LIVE badge on a dead room).
      if (hostOnVoice) ...[
        _buildLivePill(),
        SizedBox(height: compact ? 2 : 4),
        _buildListenersRow(),
        SizedBox(height: compact ? 2 : 4),
      ],
      _MicWave(active: hostUnmuted),
      SizedBox(height: compact ? 2 : 4),
      // FIX 12 G6b: the offline case is connection-aware now —
      // _hostPresenceLabel() shows Connecting… / Not connected
      // when this phone itself is not on voice (the host's
      // presence is unknown then), Offline only pre-join.
      // REDESIGN S7 (§I): the compact status line is 9px (11
      // full) — the failed state's 'Not connected' is the widest
      // word in the Live column, and 2px here buys ~14px of card
      // width at 360px, where the card overflowed by 12px. 9px
      // matches the Connecting pill's text beside it. Text and
      // state mapping unchanged.
      Text(hostUnmuted ? 'Mic on' : (hostOnVoice ? 'Muted' : _hostPresenceLabel()), style: TextStyle(color: kMuted, fontSize: compact ? 9 : 11, fontWeight: FontWeight.w600, height: 1.2)),
      SizedBox(height: compact ? 2 : 4),
      _buildConnectedBox(),
    ]);
  }

  /// FIX 1: the host mute/unmute button, extracted from
  /// [_buildHostStrip] (same reason as [_buildHostLiveColumn]).
  /// The green mic stays BIG — 56px, the only big control in
  /// the compact panel (user order 2026-11-22).
  /// FIX 22 item 14a: the button shows its STATE at a glance
  /// (supersedes FIX12 G9's hidden-label-in-compact rule): ON =
  /// green circle + mic icon + 'ON' label; OFF (muted, or the
  /// host not on voice) = grey circle + mic-off icon + 'OFF'
  /// label. The label shows in BOTH modes now — the old code
  /// showed the ACTION instead (red + mic-off when ON), which
  /// read backwards. Tap behaviour is UNCHANGED (toggle own
  /// seat / honest toasts, fix20 item 8 guards).
  /// FIX 23 item 16b (user order 2026-11-23): the host-card mic
  /// button is GATED on this phone being on voice
  /// (_voiceConnected — the same truth as the Connecting pill).
  /// While gated it is INERT and visibly dimmed: no action, no
  /// toast (this SUPERSEDES fix20 item 8's "Voice connected nahi
  /// hai" toast FOR THIS BUTTON — the toast stays on the seat
  /// taps, which still route through [_toggleOwnSeat]).
  Widget _buildHostMicButton({required bool hostOnVoice, required bool hostIsMe, required bool hostUnmuted, required String hostName, bool compact = false}) {
    // v2015 (user order 2026-11-22): the host mute/unmute button
    // is a CIRCLE now (was a rounded rectangle) — same pattern
    // as the rail FABs: round button + label below it.
    final micOn = hostUnmuted;
    final micColor =
        micOn ? const Color(0xFF16D879) : const Color(0xFF5A6076);
    final gated = !_voiceConnected;
    final button = InkWell(
      onTap: gated
          ? null
          : () async {
              if (!hostOnVoice) { toast(context, 'Host is not on voice right now.'); return; }
              if (hostIsMe) { await _toggleOwnSeat(); return; }
              toast(context, '$hostName ka mic ${hostUnmuted ? 'on' : 'muted'} hai. Apna mic apni seat se toggle karen.');
            },
      borderRadius: BorderRadius.circular(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(color: micColor, shape: BoxShape.circle, boxShadow: [BoxShadow(color: micColor.withValues(alpha: 0.35), blurRadius: 10, offset: const Offset(0, 3))]),
            child: Icon(micOn ? Icons.mic : Icons.mic_off, color: Colors.white, size: 24),
          ),
          const SizedBox(height: 3),
          Text(micOn ? 'ON' : 'OFF', style: TextStyle(color: micOn ? const Color(0xFF16D879) : kMuted, fontSize: 10, fontWeight: FontWeight.w900, height: 1.2)),
        ],
      ),
    );
    if (!gated) return button;
    return Opacity(opacity: 0.5, child: button);
  }

  /// FIX 16 (user order 2026-11-23): the Connecting / Voice On
  /// pill, alone now — it sits in the host card's compact row
  /// NEXT TO the green mic button (see [_buildHostStrip]). Music
  /// / RJ / Settings left the card for the header Settings sheet
  /// (the old Fix 1 controls row + its icon-button helper are
  /// deleted); the pill itself is unchanged (small 9px text,
  /// same connected logic, same callbacks' home — the sheet
  /// reaches _showMusicPanel / _showRjVoiceConsole /
  /// _showRoomSettings through the voice controller instead).
  /// FIX 22 item 14c — the ONE voice-connection truth, shared by
  /// the Connecting pill and the host card's Connected box: this
  /// phone is on voice on either engine (mesh needs voiceReady;
  /// LiveKit's joined is enough). Never a second source.
  bool get _voiceConnected =>
      _lkRoom.joined || (_room.joined && _room.voiceReady);

  /// FIX 22 item 14 — the host's profile bio, cached per uid
  /// (one lookup per host per room lifetime). '' on any failure
  /// or empty bio — the tagline then falls back to the scope
  /// description, else the line is omitted. Never fake text.
  final Map<String, Future<String>> _hostBioFutures = {};

  Future<String> _hostBioFor(String uid) {
    if (uid.isEmpty) return Future.value('');
    return _hostBioFutures.putIfAbsent(uid, () async {
      try {
        final profiles = await SupaDb.getProfilesMap([uid]);
        return SupaDb.strOf(profiles[uid]?['bio']);
      } catch (_) {
        return '';
      }
    });
  }

  // FIX 22 item 19: the host profile row's verified flag,
  // cached per uid like the bio above (getProfilesMap selects
  // ALL columns, so a future `verified` column arrives with
  // no query change; absent today = false, never assumed).
  final Map<String, Future<bool>> _hostVerifiedFutures = {};

  Future<bool> _hostVerifiedFor(String uid) {
    if (uid.isEmpty) return Future.value(false);
    return _hostVerifiedFutures.putIfAbsent(uid, () async {
      try {
        final profiles = await SupaDb.getProfilesMap([uid]);
        return profileVerifiedFlag(profiles[uid] ?? {});
      } catch (_) {
        return false;
      }
    });
  }

  /// FIX 22 item 14 — tournament banner URL (same field order as
  /// the tournament screens: banner / banner_url / image_url /
  /// image). '' = no banner.
  static String _bannerOf(Map<String, dynamic> t) =>
      SupaDb.strOf(t['banner'],
          SupaDb.strOf(t['banner_url'],
              SupaDb.strOf(t['image_url'], SupaDb.strOf(t['image']))));

  Widget _buildConnectingPill() {
    // FIX 23 item 12b: the fix20 item-4 members line under the
    // pill ("3 members") is REMOVED — the word "Members" must not
    // appear in the room. The pill itself is unchanged (4 states).
    final pill = ListenableBuilder(
      listenable: Listenable.merge([_room, _lkRoom]),
      builder: (context, _) {
        final connected = _voiceConnected;
        // FIX 12 G6b: the pill used to have only TWO states
        // (Voice On / Connecting…), so a failed join looked
        // exactly like a join in flight — the hour-long
        // "Connecting…" hang. Now FOUR honest states:
        // Voice On (connected) / Voice Failed (a join failed
        // — see the error banner + Retry below) / Connecting…
        // (a join is actually in flight, bounded by timeouts)
        // / Not connected (idle, nothing attempted yet).
        final failed = !connected &&
            (_lkConnectError != null ||
                (_useLiveKit && _lkRoom.error != null && !_lkRoom.joined) ||
                (_room.error != null && !_room.joined && !_lkRoom.joined));
        final connecting = !connected &&
            !failed &&
            (_lkConnecting || _lkRoom.connecting || _lkReconnecting);
        final label = connected
            ? 'Voice On'
            : failed
                ? 'Voice Failed'
                : connecting
                    ? 'Connecting…'
                    : 'Not connected';
        final color = connected
            ? ArenaColors.connectedGreen
            : failed
                ? ArenaColors.liveRed
                : connecting
                    ? ArenaColors.royalGold
                    : ArenaColors.secondaryText;
        // FIX 31b: the pill treatment on the AI Studio tokens —
        // dark pill, state-coloured border + dot, chip radius
        // from the shared tokens. The four-state mapping above
        // is UNCHANGED; only the connected state carries a soft
        // glow (guide §3: glow on the active state only).
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(kRadiusChip),
            border: Border.all(color: failed ? ArenaColors.liveRed : color.withValues(alpha: 0.6)),
            boxShadow: connected ? [BoxShadow(color: color.withValues(alpha: 0.25), blurRadius: 8)] : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(width: 6, height: 6, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
              const SizedBox(width: 4),
              Text(label, style: ArenaTypography.body(9, color: color, weight: FontWeight.w800)),
            ],
          ),
        );
      },
    );
    return pill;
  }

  /// v2017 INLINE VOICE: the mic/music request banners,
  /// extracted from build() for the same reason as
  /// [_buildHostStrip].
  List<Widget> _buildRequestBanners() {
    return [
      // MIC REQUESTS (2026-10-30): admin sees pending requests here;
      // a requester sees their own waiting state here. Neither banner
      // is full-width chat — both sit above the grid/chat column.
      if (_isRoomAdmin && _micRequests.isNotEmpty)
        Container(
          width: double.infinity,
          margin: const EdgeInsets.fromLTRB(12, 6, 12, 0),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(color: const Color(0xFFFDC903).withValues(alpha: 0.15), borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFFFDC903))),
          child: Row(
            children: [
              const Icon(Icons.mic, color: Color(0xFFFDC903), size: 18),
              const SizedBox(width: 8),
              Expanded(child: Text(_micRequests.length == 1 ? 'Mic request: ${_micRequests.first['name']}' : 'Mic requests: ${_micRequests.length}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12))),
              TextButton(onPressed: () => _approveWithSlot(_micRequests.first['uid'] ?? '', _micRequests.first['name'] ?? 'Player'), child: const Text('Approve', style: TextStyle(color: Color(0xFF16D879), fontWeight: FontWeight.bold))),
              TextButton(onPressed: () => _rejectMicRequest(_micRequests.first['uid'] ?? '', _micRequests.first['name'] ?? 'Player'), child: const Text('Reject', style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold))),
              if (_micRequests.length > 1) TextButton(onPressed: _showMicRequestsSheet, child: const Text('All', style: TextStyle(color: Color(0xFFFDC903), fontWeight: FontWeight.bold))),
            ],
          ),
        ),
      if (!_isRoomAdmin && _micRequestPending)
        Container(
          width: double.infinity,
          margin: const EdgeInsets.fromLTRB(12, 6, 12, 0),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(color: const Color(0xFF00D9FF).withValues(alpha: 0.12), borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFF00D9FF))),
          child: Row(
            children: [
              const Icon(Icons.hourglass_top, color: Color(0xFF00D9FF), size: 18),
              const SizedBox(width: 8),
              const Expanded(child: Text('Mic request admin ko bheji gayi hai — approval ka intezar hai.', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12))),
              TextButton(onPressed: _cancelMicRequest, child: const Text('Cancel', style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold))),
            ],
          ),
        ),
      // MUSIC REQUESTS (2026-10-30): admin banner + requester
      // waiting banner, mirroring the mic banners above. Both
      // persist until the admin approves/rejects (or the
      // requester cancels), so a missed moment is still seen.
      if (_isRoomAdmin && _musicRequests.isNotEmpty)
        Container(
          width: double.infinity,
          margin: const EdgeInsets.fromLTRB(12, 6, 12, 0),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(color: const Color(0xFF8B5CFF).withValues(alpha: 0.15), borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFF8B5CFF))),
          child: Row(
            children: [
              const Icon(Icons.music_note, color: Color(0xFF8B5CFF), size: 18),
              const SizedBox(width: 8),
              Expanded(child: Text(_musicRequests.length == 1 ? 'Music request: ${_musicRequests.first['name']}' : 'Music requests: ${_musicRequests.length}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12))),
              TextButton(onPressed: () => _approveMusicRequest(_musicRequests.first['uid'] ?? '', _musicRequests.first['name'] ?? 'Player'), child: const Text('Approve', style: TextStyle(color: Color(0xFF16D879), fontWeight: FontWeight.bold))),
              TextButton(onPressed: () => _rejectMusicRequest(_musicRequests.first['uid'] ?? '', _musicRequests.first['name'] ?? 'Player'), child: const Text('Reject', style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold))),
              if (_musicRequests.length > 1) TextButton(onPressed: _showMusicRequestsSheet, child: const Text('All', style: TextStyle(color: Color(0xFFFDC903), fontWeight: FontWeight.bold))),
            ],
          ),
        ),
      if (!_isRoomAdmin && _musicRequestPending)
        Container(
          width: double.infinity,
          margin: const EdgeInsets.fromLTRB(12, 6, 12, 0),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(color: const Color(0xFF00D9FF).withValues(alpha: 0.12), borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFF00D9FF))),
          child: Row(
            children: [
              const Icon(Icons.hourglass_top, color: Color(0xFF00D9FF), size: 18),
              const SizedBox(width: 8),
              const Expanded(child: Text('Music-stream request admin ko bheji gayi hai — approval ka intezar hai.', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12))),
              TextButton(onPressed: _cancelMusicRequest, child: const Text('Cancel', style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold))),
            ],
          ),
        ),
    ];
  }

  /// v2017 INLINE VOICE: the mic-seat grid, extracted from
  /// build() for the same reason as [_buildHostStrip]. `kbOpen`
  /// collapses the grid while the keyboard is open (same rule
  /// as full mode).
  Widget _buildSeatGrid(String uid, Map<String, Map<String, dynamic>> peers, bool kbOpen) {
    return Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 0, 0),
        child: Row(
          // FULL COMPLETION creative decision (a): squad/duo rooms
          // use a CENTRED row + icon-only side column (see
          // _sideActionsColumn), so no dead band sits under the
          // short squad/duo grids — leftover space splits evenly
          // instead of pooling below the seats. Tournament rooms
          // keep the top-aligned row (grid and column match).
          crossAxisAlignment: _isSquad ? CrossAxisAlignment.center : CrossAxisAlignment.start,
          children: [
            Expanded(
              child: FutureBuilder<bool>(
                future: voiceEnabledForTournament(widget.tournamentId),
                builder: (context, vsnap) {
                  final voiceOn = vsnap.data ?? true;
                  if (!voiceOn) {
                    return appCard(
                      child: Row(children: [Icon(Icons.mic_off, color: kMuted), SizedBox(width: 8), Expanded(child: Text('Voice chat is turned off by admin. Chat below still works.', style: TextStyle(color: kMuted, fontSize: 12)))]),
                    );
                  }
                  // ROUND 9 keyboard collapse: the full grid is
                  // ~230px tall; hiding it while typing is what
                  // gives the chat room above the keyboard. The
                  // side column stays (it is outside this
                  // Expanded), so Activity/Music/Info/Exit
                  // remain reachable while typing.
                  if (kbOpen) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text('Close the keyboard to see seats', style: ArenaTypography.body(12, color: ArenaColors.royalGold, weight: FontWeight.bold)),
                    );
                  }
                  // MASTER-PROMPT stage (§10): EXACTLY 9 cells, 3x3.
                  // Tournament mic seats: old cap 8 -> 9 (the one
                  // deliberate stage change; registration slot
                  // rules outside the room are unchanged).
                  // Duo/Squad mic seats stay 2/4; extra cells
                  // are listeners/locked, never extra mics.
                  // v2016 FIX 11: team rooms use the
                  // parameterized mic count (6 seats — FIX 12 G5:
                  // no type distinction);
                  // the grid is exactly the mics — no locked
                  // filler cells, no "+N more" cell. FIX 12 G6:
                  // community rooms use the same 6.
                  final usable = _isTeam ? _teamMicCount : _isCommunity ? _communityMicCount : _isSquad ? _squadCapacity : (widget.maxPlayers > 0 ? (widget.maxPlayers < 9 ? widget.maxPlayers : 9) : 9);
                  // ROUND 14 (user order 14:33 PKT: "mics k nechy
                  // itna space khaali hai"): PROVEN CAUSE of that
                  // empty band — the seat Row's height was driven
                  // by the TALLER side column, not by the seats.
                  // Side column = 6 buttons x (46 circle + 3 gap
                  // + ~14 label) + 5 x 10 gaps = ~428px, while the
                  // old 4-col tournament grid was only 2 x 122 +
                  // 6 = 250px. The Row is top-aligned, so ~178px
                  // of dead space sat under the seats before the
                  // chat started. FIX (not a spacer tweak, not a
                  // seat shrink): make the seat grid itself as
                  // tall as the side column, so the Row height is
                  // shared, not wasted. Tournament: 3 cols (like
                  // the approved v2 preview) x 140px cells = 3
                  // rows x 140 + 2 x 8 spacing = 436px, vs side
                  // column ~428px — the two end together, so no
                  // dead band remains under the seats and the
                  // chat starts immediately below. Squad: 2 cols
                  // x 140px (2 rows for a 4-seat squad = 288px;
                  // a 2-seat duo is 1 row, so a smaller dead band
                  // can still appear there — see report).
                  // ROUND 15 (user order 21:50 PKT: round-14 seats
                  // + icons TOO BIG, chat below starved): shrink
                  // slightly, not back to small round-13 size.
                  // Tournament cell 140 -> 115px: 3 rows x 115 +
                  // 2 x 8 spacing = 361px (was 436px, -75px freed
                  // for chat). Avatar radius 28 -> 25 (circle
                  // ~61px incl. ring/padding, still large premium,
                  // cell content ~95px fits 115px with slack).
                  // Squad uses the same 115px extent (radius
                  // 26 -> 23) so its grid shrinks in step with
                  // the side column; its pre-existing dead band
                  // (side column taller than a 2-row/1-row grid)
                  // is NOT newly created here and stays a pending
                  // user decision (icon-only vs floating column).
                  final seatCols = 3; // MASTER-PROMPT: always 3 cols
                  final seatR = 18.0; // avatar ~36dp (PHASE E E16: was 20.0/40dp — 6 seats must fit fully; chat gets the room)
                  final occupied = peers.entries.toList();
                  // ADMIN SLOT PLACEMENT (migration 013): peers
                  // carrying seat_no render in EXACTLY that cell
                  // on every phone. Peers without a seat fill the
                  // earliest free mic cells in join order (the
                  // historic behaviour, also the pre-migration
                  // fallback). Leftovers past the mic capacity
                  // become listeners, as before.
                  final assignedSeatPeers = <int, MapEntry<String, Map<String, dynamic>>>{};
                  final unassignedPeers = <MapEntry<String, Map<String, dynamic>>>[];
                  for (final e in occupied) {
                    final sn = SupaDb.intOf(e.value['seat_no']);
                    if (sn >= 1 && sn <= usable && !assignedSeatPeers.containsKey(sn)) {
                      assignedSeatPeers[sn] = e;
                    } else {
                      unassignedPeers.add(e);
                    }
                  }
                  final freeMicCells = <int>[for (var c = 1; c <= usable; c++) if (!assignedSeatPeers.containsKey(c)) c];
                  final micPlacedUnassigned = unassignedPeers.length < freeMicCells.length ? unassignedPeers.length : freeMicCells.length;
                  final listenerPeers = unassignedPeers.sublist(micPlacedUnassigned);
                  MapEntry<String, Map<String, dynamic>>? peerForMicCell(int cellNo) {
                    if (assignedSeatPeers.containsKey(cellNo)) return assignedSeatPeers[cellNo];
                    final idx = freeMicCells.indexOf(cellNo);
                    if (idx >= 0 && idx < micPlacedUnassigned) return unassignedPeers[idx];
                    return null;
                  }
                  // ARENA HUB #10 AUDIO — listeners call site 2:
                  // seats changed (or first build), so recompute
                  // the listener list from the SAME peerForMicCell
                  // source the stage renders. update() must NOT
                  // run during build (it can notify -> setState),
                  // so it goes through a post-frame callback,
                  // one per frame at most.
                  _lastSeatUids = <String>{
                    for (var c = 1; c <= usable; c++)
                      if (peerForMicCell(c) != null) peerForMicCell(c)!.key,
                  };
                  if (!_listenersRefreshScheduled) {
                    _listenersRefreshScheduled = true;
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      _listenersRefreshScheduled = false;
                      if (!mounted) return;
                      _liveListeners.update(_lkRoom.participants, _lastSeatUids);
                    });
                  }
                  // FIX 31b: the host uid (for the gold podium
                  // frame on the host's seat) + the seated count
                  // (for the podium header). _hostEntry needs no
                  // tournament row for community/team scopes —
                  // the organizer comes from the widget params.
                  final hostUid = _hostEntry(null, occupied)?['uid'] as String? ?? '';
                  final occupiedCount = [for (var c = 1; c <= usable; c++) if (peerForMicCell(c) != null) c].length;
                  // v2016 FIX 11: team rooms show exactly their
                  // mics (6/4) — the 9-cell tournament grid does
                  // not apply. FIX 12 G6: same for community rooms (6).
                  final total = _isTeam ? _teamMicCount : _isCommunity ? _communityMicCount : 9; // MASTER-PROMPT: exactly 9 stage cells
                  // ROUND 18 (2026-10-30 user order: mics ke neeche
                  // zyada space, chat chhoti): cells are circles
                  // ONLY now — no pill/label/name/wave rows — so
                  // the tallest cell is a framed occupied avatar
                  // (40 avatar + frame ring + padding + border
                  // = ~57px). Extent 58px keeps that safe with
                  // slack; grid height = 2 x 58 + 6 = 122px for
                  // 6 seats (was 138px at 66px extent), so the
                  // Expanded chat below gains ~16px outright.
                  // Avatars 40dp (was 46dp, FIX 22 item 12);
                  // 3x3 and 9 slots unchanged.
                  // PHASE E (E16): extent 58 -> 52 — the 6-seat grid
                  // is 108 tall now (was 120); seats + chat both fit.
                  final seatExtent = 52.0;
                  final seatRows = (total + seatCols - 1) ~/ seatCols;
                  // ROUND 14: spacing must match the delegate's
                  // mainAxisSpacing (8), not 6, or the last row
                  // clips by a few px inside this SizedBox.
                  // ROUND 17 (user order 22:35 PKT: space above/below
                  // mics too much, chat hiding): tighten VERTICAL
                  // spacing only — seat circles NOT shrunk (extent
                  // stays 115px, radius stays 25/23), strips NOT
                  // deleted. Grid mainAxisSpacing 8 -> 4 saves
                  // 8px over 3 rows; side-column gap 8 -> 5 and
                  // label gap 3 -> 2 save ~21px on the column, so
                  // the Row height (the taller of grid/column)
                  // drops and the Expanded chat below gains it.
                  // FIX 17: mainAxisSpacing 4 -> 6, crossAxisSpacing 4 -> 8 —
                  // the height math below must match the delegate spacing.
                  // FIX 23 item 13a (user order 2026-11-23, "beech ka
                  // space kam karo"): mainAxisSpacing 6 -> 4 and
                  // crossAxisSpacing 8 -> 6 — tighter, balanced grid.
                  // The height math below must match the delegate.
                  final seatFullH = seatRows * seatExtent + (seatRows - 1) * 4;
                  // ROUND 12: grid is NEVER capped/scrolled — all
                  // seats show at once beside the full side
                  // column (3 tall rows balance the 6-button
                  // column), so no seat hides below a scroll.
                  // ROUND 13: NO outer box, NO seat header, NO hint line
                  // (v2 preview match) — large seat circles sit
                  // DIRECTLY on the gradient background. Voice
                  // diagnostics live ONLY in the Info dialog now.
                  // FIX 31b: the stage panel is the AI Studio
                  // podium card now — card-bg fill, purple
                  // border, cyber-notched header on top (full
                  // bleed, like the screen's podium card). The
                  // grid + its spacing + the full-line below
                  // are UNCHANGED.
                  return ClipRRect(
                    borderRadius: BorderRadius.circular(20),
                    child: Container(
                      decoration: BoxDecoration(
                        // PHASE E (update 11): the podium card
                        // reads the ONE shared card number now
                        // (was a bespoke 0.78) — same hue, same
                        // number as every other card in the app.
                        color: ArenaColors.cardBg.withValues(alpha: kCardFillOpacity),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: ArenaColors.purple.withValues(alpha: 0.7), width: 1.4),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _fix31bPodiumHeader(occupiedCount),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                        SizedBox(
                          height: seatFullH,
                          child: GridView.builder(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: seatCols, mainAxisExtent: seatExtent, mainAxisSpacing: 4, crossAxisSpacing: 6),
                            itemCount: total,
                            itemBuilder: (_, i) {
                              // Mic cells: first `usable` cells.
                              if (i < usable) {
                                final placed = peerForMicCell(i + 1);
                                if (placed != null) {
                                  final e = placed;
                                  final name = (e.value['display_name'] ?? e.value['name'] ?? 'Player').toString();
                                  final unmuted = e.value['muted'] != true && _peerLooksOnline(e.key, uid);
                                  // FIX 23 item 13b: the pulse runs
                                  // ONLY while this seat is actually
                                  // speaking (LiveKit 'speaking' in
                                  // the peer map; mesh peers carry
                                  // no key, so they stay static).
                                  final speaking = e.value['speaking'] == true;
                                  final isMine = e.key == uid;
                                  // FIX 31b: the podium frame color
                                  // (AI Studio seat-tile rule) —
                                  // host gold, speaking pink, else
                                  // electric blue.
                                  final frameColor = e.key == hostUid
                                      ? ArenaColors.royalGold
                                      : (speaking && unmuted)
                                          ? ArenaColors.neonPink
                                          : ArenaColors.electricBlue;
                                  return InkWell(
                                    onTap: () async {
                                      if (widget.spectator) { toast(context, 'Spectator mode — mics view-only hain.'); return; }
                                      if (isMine) { await _toggleOwnSeat(); } else { toast(context, '$name is on voice (${unmuted ? 'mic on' : 'muted'}). Tap your own mic to mute or unmute.'); }
                                    },
                                    onLongPress: () { if (_isRoomAdmin) _showAdminMenu(e.key, name); },
                                    borderRadius: BorderRadius.circular(12),
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        Stack(
                                          clipBehavior: Clip.none,
                                          children: [
                                            // FIX 31b: the podium disc
                                            // under the seat (AI Studio
                                            // podium tile). Painted
                                            // first so it sits behind
                                            // the avatar + badges.
                                            Positioned(
                                              bottom: -8, left: -19, right: -19,
                                              child: CustomPaint(
                                                size: const Size(86, 16),
                                                painter: PodiumDiscPainter(outerColor: frameColor, active: speaking && unmuted),
                                              ),
                                            ),
                                            _PulseGlow(
                                              active: speaking,
                                              child: Container(
                                                padding: const EdgeInsets.all(1.5),
                                                decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: frameColor, width: 2.2), boxShadow: unmuted ? [BoxShadow(color: frameColor.withValues(alpha: 0.35), blurRadius: 10, spreadRadius: 0)] : null),
                                                child: _avatar(name, unmuted, e.key, seatR),
                                              ),
                                            ),
                                            Positioned(
                                              right: 0, bottom: 0,
                                              child: Container(
                                                width: 18, height: 18,
                                                decoration: BoxDecoration(shape: BoxShape.circle, color: unmuted ? ArenaColors.connectedGreen : const Color(0xFFD69E00), border: Border.all(color: ArenaColors.primaryBg, width: 1.5)),
                                                child: Icon(unmuted ? LucideIcons.mic : LucideIcons.micOff, color: ArenaColors.primaryBg, size: 10),
                                              ),
                                            ),
                                            // v2016 FIX 6: the occupied cell used to
                                            // show NO number at all (the photo
                                            // replaced it), so seats 1-9 were
                                            // unidentifiable once taken. The small
                                            // gold number badge sits top-left,
                                            // opposite the mic-state badge.
                                            Positioned(
                                              left: 0, top: 0,
                                              child: MicSeatNumberBadge(seatNo: i + 1),
                                            ),
                                          ],
                                        ),
                                        // MIC CELL REDESIGN (2026-10-30): occupied
                                        // cell is the photo circle ONLY — the name
                                        // + wave rows are dropped on purpose, or
                                        // the saved vertical space comes straight
                                        // back. Name stays reachable via the tap
                                        // toast and the Participants sheet; the
                                        // green/red mic badge keeps the mic state.
                                        // (The photo itself is unchanged: it
                                        // replaces the seat number in this circle.)
                                      ],
                                    ),
                                  );
                                }
                                return _stageCellFree(i + 1, usable, _room.joined);
                              }
                              // Cells beyond the mic seats: leftover peers
                              // (unassigned peers past the mic capacity)
                              // show as listeners, in join order.
                              if (i - usable < listenerPeers.length) {
                                final e = listenerPeers[i - usable];
                                final name = (e.value['display_name'] ?? e.value['name'] ?? 'Player').toString();
                                return _stageCellListener(name, e.key);
                              }
                              if (i == 8) {
                                final extra = _roomUserCount() - 9;
                                if (extra > 0) return _stageCellMore(extra);
                              }
                              return _stageCellLocked(i + 1);
                            },
                          ),
                        ),
                        // ROUND 13 full-seats state (only when the user is
                        // not on voice and every mic slot is taken):
                        // room entry, chat and listening still work.
                        if (!_room.joined && peers.length >= usable)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text('All $usable mics are full — you can still chat and listen until a mic frees.', style: ArenaTypography.body(11, color: ArenaColors.royalGold, weight: FontWeight.bold)),
                          ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
                          ],
        ),
      );
  }

  /// v2017 INLINE VOICE: the voice-connection-failed banner,
  /// extracted from build() for the same reason as
  /// [_buildHostStrip]. The caller keeps the `if` (only
  /// rendered while joined + failed).
  Widget _buildConnectionFailedBanner() {
    return Container(
        width: double.infinity,
        margin: const EdgeInsets.fromLTRB(12, 4, 0, 0),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(color: const Color(0xFF3A1210), borderRadius: BorderRadius.circular(16), border: Border.all(color: Colors.redAccent)),
        child: Row(
          children: [
            const Icon(Icons.warning_amber, color: Colors.redAccent, size: 18),
            const SizedBox(width: 8),
            const Expanded(child: Text('Voice audio could not connect — mic may look green but nobody hears you. Tap Retry.', style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold))),
            const SizedBox(width: 8),
            InkWell(
              onTap: _voiceRetrying ? null : _retryVoice,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(color: Colors.redAccent, borderRadius: BorderRadius.circular(16)),
                child: Text(_voiceRetrying ? '…' : 'Retry', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
              ),
            ),
          ],
        ),
      );
  }

  /// v2017 INLINE VOICE (user order 2026-11-22): the embedded
  /// voice panel — the SAME voice UI as the full room page (host
  /// strip with its compact controls, seat grid, request
  /// banners, connection banner), WITHOUT the room chat,
  /// composer, side rail or diagnostics. Used when
  /// [UnifiedRoomPage.embedded] is true (TeamChatPage's inline
  /// Voice toggle). No chat here: the team chat below the panel
  /// IS the chat. FIX 1 (2026-11-22): the old bottom controls
  /// row is GONE — Music / Settings / Connecting moved up into
  /// the host card. FIX 16 (2026-11-23): Music / Settings / RJ
  /// moved on to the header Settings sheet (the pill stays in
  /// the host card, next to the mic); Close lives in that sheet
  /// too — the header Voice button is the other way to hide the
  /// panel.
  /// FIX 22 item 15 (FINAL — SUPERSEDES item 5's rectangular
  /// menus + item 12e's list): the embedded panel's RIGHT
  /// SIDEBAR — FIVE entries in this order: Followers, Music,
  /// RJ Panel, Settings, Leave Room. ALL entries are ROUND
  /// icons (dark circle + gold icon + small label below) like
  /// the reference screenshot's circles — NO rectangular card
  /// views (the user explicitly rejected the card look). Room
  /// Home + Participants + Tournament Info are REMOVED (exit
  /// is Leave Room + system back; the host card's members
  /// button, item 16, opens the FULL members list). Each entry
  /// calls the parent's callback when wired, else the in-room
  /// equivalent — never a dead button. Followers shows the
  /// organizer's/captain's REAL followers count (compact:
  /// 1K/1M/1B/1T; '—' while unknown, never a fake 0) and
  /// opens the followers list. RJ Panel is host-only (same
  /// gate as the full-page rail's 'RJ Studio' button) and
  /// opens the console directly until the 4-option menu's
  /// options are named (PENDING — resolved by item 20: the
  /// console opens on the processor buttons, no menu). Music
  /// opens the unified console focused on the PLAYER section
  /// (FIX 22 item 21). No Gift / VIP / Hot Room / Mic entries:
  /// no gift economy exists, and the mic lives in the host
  /// card (item 14b).
  /// FIX 23 item 9 — the Follow pill under the Followers icon.
  /// sidebarFollowing null = creator: gold JOINED text, no tap.
  /// true = Following pill (dark, gold border); false = Follow
  /// pill (gold fill, black text). Busy = dimmed, no tap.
  Widget _buildSidebarFollowPill() {
    final following = widget.sidebarFollowing;
    if (following == null) {
      return Text('JOINED',
          style: ArenaTypography.body(9, color: ArenaColors.royalGold, weight: FontWeight.w900));
    }
    final pill = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: following ? ArenaColors.glassSurface : ArenaColors.royalGold,
        borderRadius: BorderRadius.circular(12),
        border: following
            ? Border.all(color: ArenaColors.royalGold.withValues(alpha: 0.6))
            : null,
      ),
      child: Text(following ? 'Following' : 'Follow',
          style: ArenaTypography.body(10,
              color: following ? ArenaColors.royalGold : ArenaColors.primaryBg,
              weight: FontWeight.w900)),
    );
    if (widget.sidebarFollowBusy) {
      return Opacity(opacity: 0.5, child: pill);
    }
    return InkWell(
      onTap: widget.onSidebarFollowToggle,
      borderRadius: BorderRadius.circular(12),
      child: pill,
    );
  }

  /// FIX 23 (items 2+5+11 consequence): the two-row host card +
  /// 6th sidebar entry made the embedded panel taller — on short
  /// screens the page Column overflowed (140px at 800x600). The
  /// sidebar rail is capped to the screen height minus the page
  /// chrome (team header + composer + card; the community room
  /// has no header since item 1, so its reserve is smaller) and
  /// scrolls when taller — tall phones show all 6 entries, short
  /// phones scroll the rail instead of overflowing the page.
  /// FIX 31b (Defect A fix): the AI Studio header strip adds
  /// ~35px to the panel (6px top pad + ~29px notch chip), which
  /// made TeamChatPage overflow 30px on the bottom at heights
  /// <=720 — the seats Row is sidebar-height-bound, so the strip
  /// is the only net growth. The reserves below absorb it: +36
  /// on each scope shrinks the capped sidebar in step, so the
  /// panel keeps its item-31 height on the host pages (the
  /// sidebar scrolls a few px sooner on short screens instead).
  /// FIX 72: a host page may pass its own reserve
  /// ([UnifiedRoomPage.sidebarReserve]) when its chrome needs
  /// more room than the scope default — CommunityDetailPage
  /// passes 480 (voice-lock banner 76–154 + host card + header
  /// strip ~158 + the chat tab's ~143px minimum). Null keeps
  /// the scope defaults EXACTLY (team 316.0, community 236.0).
  /// The override path uses a lower floor (160.0) so the reserve
  /// actually bites on short screens — with the 220.0 floor a
  /// 480 reserve would cap identically at 600h and the chat
  /// would keep only ~145px. The default path keeps the 220.0
  /// floor. Either way the rail scrolls, so all 6 entries stay
  /// reachable.
  Widget _buildCappedSidebar() {
    final screenH = MediaQuery.of(context).size.height;
    final reserve = widget.sidebarReserve ?? (_isTeam ? 316.0 : 236.0);
    final minCap = widget.sidebarReserve == null ? 220.0 : 160.0;
    final maxH = (screenH - reserve).clamp(minCap, 520.0);
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxH),
      child: SingleChildScrollView(
        // PHASE E (E15): 8px breathing room so the rail's last
        // visible entry never sits ON the panel's bottom edge —
        // the sidebar visibly ends above the chat box.
        padding: const EdgeInsets.only(bottom: 8),
        child: _buildEmbeddedSidebar(),
      ),
    );
  }

  Widget _buildEmbeddedSidebar() {
    // FIX 23 item 12a: the sub-line is the COMMUNITY's real
    // member count (sidebarCommunityCount); the organizer's
    // profile-followers count is only a team-scope fallback.
    final followersSub = (widget.sidebarCommunityCount ??
                widget.sidebarFollowersCount) ==
            null
        ? '—'
        : formatCompactCount(widget.sidebarCommunityCount ??
            widget.sidebarFollowersCount!);
    final musicPlaying = _musicPlaying != null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _sidebarRoundBtn(
          Icons.people,
          'Followers',
          widget.onSidebarFollowers ??
              () => toast(context, 'Followers list abhi available nahi hai.'),
          neon: _neonPink,
          sub: followersSub,
        ),
        // FIX 23 item 9: the Follow pill, under the Followers
        // entry — the follow toggle lives HERE (not in More,
        // not in Settings). Team scope passes no callback and
        // gets no pill.
        if (widget.onSidebarFollowToggle != null) ...[
          const SizedBox(height: 4),
          _buildSidebarFollowPill(),
        ],
        // PHASE E (E28): Music is host-only too — the same RJ rule
        // as the RJ Panel below (admin / team captain / community
        // organizer). Non-hosts never see the button at all (not
        // greyed — absent). NOTE: _canBroadcastMusic is NOT used
        // here on purpose — it admits music-approved non-organizers,
        // and E28 is absolute (organizer/admin only); approved
        // users lose the Music button path (see the report).
        if (_isAdminForBroadcast ||
            _isTeamCaptainForBroadcast ||
            _isCommunityOrganizerForBroadcast) ...[
          const SizedBox(height: 10),
          _sidebarRoundBtn(
            Icons.music_note,
            'Music',
            widget.onSidebarMusic ??
                () => unawaited(_showRjVoiceConsole(initialSection: 'player')),
            neon: _neonCyan,
          ),
        ],
        if (_isAdminForBroadcast ||
            _isTeamCaptainForBroadcast ||
            _isCommunityOrganizerForBroadcast) ...[
          const SizedBox(height: 10),
          _sidebarRoundBtn(
            Icons.graphic_eq,
            'RJ Panel',
            widget.onSidebarRjPanel ??
                () => unawaited(_showRjVoiceConsole()),
            neon: _neonPurple,
          ),
        ],
        const SizedBox(height: 10),
        _sidebarRoundBtn(
          Icons.settings,
          'Settings',
          widget.onSidebarSettings ?? _showRoomSettings,
          neon: _neonLime,
        ),
        const SizedBox(height: 10),
        // FIX 23 item 11 — the music POWER entry: the same
        // on/off semantics as the player panel's power button
        // (_stopMusic / open the player). The sub-line is the
        // unmistakable state: On (lime) vs Off (grey).
        _sidebarRoundBtn(
          Icons.power_settings_new_rounded,
          'Power',
          musicPlaying
              ? () => unawaited(_stopMusic())
              : () => unawaited(
                  _showRjVoiceConsole(initialSection: 'player')),
          neon: musicPlaying ? _neonLime : const Color(0xFF5A6076),
          sub: musicPlaying ? 'On' : 'Off',
        ),
        const SizedBox(height: 10),
        _sidebarRoundBtn(
          Icons.exit_to_app,
          'Leave Room',
          widget.onSidebarLeaveRoom ?? () => unawaited(_leaveEmbeddedVoice()),
          neon: _neonOrange,
        ),
      ],
    );
  }

  /// FIX 22 item 15: one round sidebar entry — a 48px dark
  /// circle with the label below it and an optional sub-line
  /// (the Followers count) under the label. The whole column
  /// is tappable (48px circle + labels).
  /// FIX 23 item 6 (user order 2026-11-23, neon reference):
  /// the circle is NEON now — neon border + neon icon + a
  /// soft neon glow, one colour per entry (pink Followers,
  /// cyan Music, purple RJ, lime Settings, orange Leave, lime/
  /// grey Power). This is the user's direct order and
  /// supersedes the gold-only rule FOR THESE BUTTONS ONLY.
  /// FIX 31b: the shell is the AI Studio glass surface with
  /// Inter labels — the per-entry neon accents are UNCHANGED
  /// (they ARE the AI Studio neon language).
  Widget _sidebarRoundBtn(
    IconData icon,
    String label,
    VoidCallback onTap, {
    required Color neon,
    String? sub,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: ArenaColors.glassSurface,
              border: Border.all(color: neon.withValues(alpha: 0.8)),
              boxShadow: [
                BoxShadow(
                    color: neon.withValues(alpha: 0.45), blurRadius: 12)
              ],
            ),
            child: Icon(icon, color: neon, size: 22),
          ),
          const SizedBox(height: 4),
          Text(label,
              style: ArenaTypography.body(9, weight: FontWeight.w700)),
          if (sub != null)
            Text(sub,
                style: ArenaTypography.body(10,
                    color: neon, weight: FontWeight.w800)),
        ],
      ),
    );
  }

  /// FIX 23 item 16a — the slim "Voice locked" line that
  /// replaces the mic seats while the parent says voice is
  /// locked. The host card above stays pinned (sticky).
  Widget _buildVoiceLockedLine() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.lock_outline, size: 14, color: ArenaColors.secondaryText),
          const SizedBox(width: 6),
          Text('Voice locked',
              style: ArenaTypography.body(12,
                  color: ArenaColors.secondaryText, weight: FontWeight.w700)),
        ],
      ),
    );
  }

  Widget _buildEmbeddedVoice(String uid, Map<String, Map<String, dynamic>> peers, bool kbOpen) {
    // FIX 23 item 2/5: the host strip is FULL WIDTH at the top
    // now (no sidebar beside it); the sidebar starts LOWER,
    // beside the seat grid. FIX 23 items 14+21: by DEFAULT (no
    // stored background pick) the panel shows the app-wide
    // background image (AppBackgroundLayer — item 21's bundled
    // artwork, item 22's remote URL when set), which supersedes
    // item 14's code-drawn neon default. An explicit pick
    // (_bgUserPicked) shows its gradient instead — the neon
    // blobs only render for an explicit 'neon' pick.
    // FIX 31b: the panel is re-skinned in the AI Studio design
    // language — host card (above), compact header strip (room
    // title + LIVE + listeners, below the card), podium seat
    // grid, glass sidebar. INLINE still: no Scaffold, no chat
    // (the host page owns chat), no new screen, no routing
    // change. The banners + background are UNCHANGED (they
    // have no AI Studio equivalent and stay functional).
    return Container(
      decoration: _bgUserPicked
          ? BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: _bgColors(),
              ),
            )
          : null,
      child: Stack(
        children: [
          // PHASE E (E12): NO inner AppBackgroundLayer here — the
          // host page already mounts one behind this panel (and
          // main.dart mounts one app-wide), so a second layer
          // doubled the scrim over the panel area (0.35 x 2) and
          // the poster read as black in the middle of the room.
          // The _bgUserPicked gradient path above is unchanged.
          if (_bgId == 'neon' && _bgUserPicked) ...[
            Positioned(
              top: -70,
              right: -50,
              child: Container(
                width: 220,
                height: 220,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(colors: [
                    _neonPurple.withValues(alpha: 0.12),
                    _neonPurple.withValues(alpha: 0.0),
                  ]),
                ),
              ),
            ),
            Positioned(
              bottom: -90,
              left: -60,
              child: Container(
                width: 240,
                height: 240,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(colors: [
                    _neonPink.withValues(alpha: 0.10),
                    _neonPink.withValues(alpha: 0.0),
                  ]),
                ),
              ),
            ),
          ],
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_roomVoiceDisabled) _buildRoomDisabledBanner(),
              _buildHostStrip(uid, peers, compactControls: true),
              // FIX 31b: compact header strip between the host
              // card and the seats (room title + LIVE chip +
              // listeners count).
              _fix31bHeaderStrip(peers),
              // FIX 72 (hide option, user order 2026-11-24): the
              // seats + sidebar Row collapses when the user hides
              // it (chevron in the header strip above) — the host
              // page's chat expands into the freed space. The host
              // card + header strip above NEVER hide (fix23 item
              // 16: the host card is sticky, always present).
              if (!_seatsHidden)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _buildVoiceConnectErrorBanner(),
                        ..._buildRequestBanners(),
                        if (widget.voiceLocked)
                          _buildVoiceLockedLine()
                        else
                          _buildSeatGrid(uid, peers, kbOpen),
                        if (_room.joined && (_room.connectionGenuinelyFailed || _room.signalFailedRecently))
                          _buildConnectionFailedBanner(),
                        _liveKitDroppedBanner(),
                      ],
                    ),
                  ),
                  const SizedBox(width: 6),
                  _buildCappedSidebar(),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }


  // ─── FIX 31b: embedded voice-panel adaptation ────────────────
  // The AI Studio design language, adapted to the INLINE panel
  // (community detail + team chat). Same tokens/widgets as the
  // full-page screen — ArenaColors, ArenaTypography, the cyber-
  // notch clippers, the podium seat styling, the host-card
  // look — but NO Scaffold, NO chat (the host page owns it),
  // NO new screen, NO routing change. The full-page screen's
  // big title belongs to the full-page screen ONLY and never
  // appears here: this panel's header shows the room's own
  // title (_roomTitle) instead.
  //
  // Menu decision (FIX 31b): the six sidebar entries stay as
  // the panel's menu — Followers / Music / RJ Panel (host-
  // gated) / Settings / Power / Leave Room, same order, same
  // callbacks, same neon accents (re-skinned shells only).
  // A single menu button + sheet would hide the entries the
  // room tests pin as always-visible, so the sidebar IS the
  // menu; no second menu button was added.

  /// FIX 31b — the compact header strip: room title (left
  /// cyber-notch chip) + LIVE chip (only while the host is on
  /// voice — the same rule as the old status strip) + the REAL
  /// LiveListeners count. The host card's status strip keeps
  /// the connection state only, so LIVE + listeners have ONE
  /// home and are never shown twice.
  Widget _fix31bHeaderStrip(Map<String, Map<String, dynamic>> peers) {
    return FutureBuilder<Map<String, dynamic>>(
      future: _tournamentFuture,
      builder: (context, tsnap) {
        final occupied = peers.entries.toList();
        final host = _hostEntry(tsnap.hasData ? tsnap.data : null, occupied);
        final hostUid = host == null ? '' : host['uid'] as String;
        final hostOnVoice = host != null && !(host['offline'] == true) && occupied.any((e) => e.key == hostUid);
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
          child: Row(
            children: [
              Flexible(
                child: ClipPath(
                  clipper: LeftCyberNotchClipper(),
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(12, 7, 24, 7),
                    color: const Color(0xFF281456),
                    child: Row(
                      children: [
                        const Icon(LucideIcons.crown, size: 14, color: ArenaColors.royalGold),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(_roomTitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: ArenaTypography.heading(13)),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              if (hostOnVoice) ...[
                _buildLivePill(),
                const SizedBox(width: 8),
              ],
              _buildListenersRow(),
              // FIX 72 (hide option, user order 2026-11-24): the
              // seats chevron — hides the mic seats + sidebar
              // Row below so the chat expands; tap again to show.
              // Default shown; session-local (_seatsHidden, no
              // persistence). The host card + this strip NEVER
              // hide (fix23 item 16). GestureDetector (not
              // InkWell): the panel also mounts standalone in
              // tests with no Material ancestor.
              const SizedBox(width: 8),
              Tooltip(
                message:
                    _seatsHidden ? 'Show mic seats' : 'Hide mic seats',
                child: GestureDetector(
                  key: const ValueKey('fix72_seats_toggle'),
                  behavior: HitTestBehavior.opaque,
                  onTap: () =>
                      setState(() => _seatsHidden = !_seatsHidden),
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Icon(
                      _seatsHidden
                          ? Icons.keyboard_arrow_down
                          : Icons.keyboard_arrow_up,
                      size: 20,
                      color: ArenaColors.royalGold,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// FIX 31b — the podium header, verbatim in shape from the
  /// full-page screen's seats card: left cyber-notch chip with
  /// the seated count, right cyber-notch chip opening
  /// Participants/Status. (The chip background colours are the
  /// as-sent AI Studio values, same as the screen.)
  Widget _fix31bPodiumHeader(int occupiedCount) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Flexible(
          child: ClipPath(
            clipper: LeftCyberNotchClipper(),
            child: Container(
              padding: const EdgeInsets.fromLTRB(12, 5, 24, 5),
              color: const Color(0xFF281456),
              child: Row(
                children: [
                  const Icon(LucideIcons.usersRound,
                      size: 16, color: ArenaColors.neonPink),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text('Voice Seats ($occupiedCount)',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ArenaTypography.heading(16)),
                  ),
                ],
              ),
            ),
          ),
        ),
        ClipPath(
          clipper: RightCyberNotchClipper(),
          child: InkWell(
            onTap: _openStatus,
            child: Container(
              padding: const EdgeInsets.fromLTRB(22, 5, 12, 5),
              color: const Color(0xFF281C08),
              child: Row(
                children: [
                  Text('View All',
                      style: ArenaTypography.heading(13, color: ArenaColors.royalGold)),
                  const SizedBox(width: 3),
                  const Icon(LucideIcons.chevronRight,
                      size: 14, color: ArenaColors.royalGold),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }


  // ─── FIX 31: AI Studio voice-room presentation ─────────────────────
  // Full-page rooms render ArenaVoiceRoomScreen (Sameer's AI Studio
  // layout) with the REAL room state; UnifiedRoomPage keeps ALL its
  // logic/services — the screen is only the presentation layer.
  // Embedded mode (community detail / team chat inline panels)
  // does NOT mount the full screen — a full Scaffold screen
  // cannot live inside those panels. FIX 31b re-skins the
  // embedded panel itself in the same design language (see the
  // FIX 31b section above); the _fix31* adapter + the screen
  // are untouched by 31b. The old full-page Scaffold body is
  // preserved verbatim as _buildLegacyFullRoom (rollback +
  // merger reference).
  // Wiring map (fix23 checklist functions -> home in the new UI):
  //  seats/chat/mic/leave -> screen props + callbacks below;
  //  Followers/Music/RJ/Settings/Power/Voice/Invite/Follow Host/
  //  Leave Voice -> the host-card menu (MoreActionsSheet);
  //  Backgrounds/Frames/Participants/Diagnostics/Voice test/Cheer
  //  -> inside the Settings sheet (unchanged home); voice
  //  diagnostics overlay -> _fix31VoiceDiagOverlay (card over the
  //  room); speaker toggle -> REMOVED (fix22 item 7, always
  //  loudspeaker; the voice chip is display-only).
  //  Known gaps (reported in BUILDER-DONE.md): the persistent
  //  "Room band hai" banner + the connect-error / LiveKit-drop
  //  banners have no slot in the new screen — their reasons are
  //  still toasted on entry/join attempts, and Voice retry lives
  //  in the menu's Voice entry.

  void _fix31EnsureAvatars(List<String> uids) {
    final missing = uids
        .where((u) =>
            u.isNotEmpty &&
            !_fix31AvatarUrls.containsKey(u) &&
            !_fix31AvatarFetching.contains(u))
        .toList();
    if (missing.isEmpty) return;
    _fix31AvatarFetching.addAll(missing);
    SupaDb.getProfilesMap(missing).then((profiles) {
      var changed = false;
      for (final u in missing) {
        final url = SupaDb.strOf(profiles[u]?['photoURL']);
        if (_fix31AvatarUrls[u] != url) {
          _fix31AvatarUrls[u] = url;
          changed = true;
        }
        final flag = profileVerifiedFlag(profiles[u] ?? {});
        if (_fix31VerifiedFlags[u] != flag) {
          _fix31VerifiedFlags[u] = flag;
          changed = true;
        }
      }
      _fix31AvatarFetching.removeAll(missing);
      if (changed && mounted) setState(() {});
    }).catchError((_) {
      _fix31AvatarFetching.removeAll(missing);
    });
  }

  String _fix31PeerName(String uid, Map<String, dynamic> peer) =>
      strVal(peer['display_name'],
          strVal(peer['name'], _roomRegNames[uid] ?? 'A player'));

  String _fix31Initials(String name) {
    final parts = name
        .trim()
        .split(RegExp(r'\s+'))
        .where((p) => p.isNotEmpty)
        .toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first[0].toUpperCase();
    return (parts[0][0] + parts[1][0]).toUpperCase();
  }

  bool get _fix31MicOn =>
      (_lkRoom.joined && !_lkRoom.muted) || (_room.joined && !_room.muted);

  /// FIX 31 (item 19): the host blue tick — the same formula as
  /// the old host strip (admin owner OR community-row flag OR
  /// profile flag OR 1000+ followers). Cached per uid.
  Future<bool> _fix31HostVerifiedFuture(String hostUid) async {
    if (hostUid.isEmpty) return false;
    final flag = await _hostVerifiedFor(hostUid);
    return (hostUid == _adminUid) ||
        widget.hostCardVerified ||
        hostVerifiedTick(
            flag: flag, followersCount: widget.sidebarFollowersCount);
  }

  SeatAccent _fix31SeatAccent(int seatNo) {
    switch (seatNo) {
      case 1:
        return SeatAccent.gold;
      case 2:
        return SeatAccent.cyan;
      case 3:
        return SeatAccent.pink;
      case 4:
        return SeatAccent.purple;
      case 5:
        return SeatAccent.cyan;
      default:
        return SeatAccent.pink;
    }
  }

  List<VoiceSeatMember> _fix31MapSeats(
    Map<String, Map<String, dynamic>> peers,
    String uid,
    String hostUid,
    bool hostVerified,
  ) {
    // Same assignment as the old seat grid: peers carrying
    // seat_no render in exactly that cell; peers without one
    // fill the earliest free cells in join order. The podium
    // shows 6 cells; peers past 6 are reachable via View All
    // (Participants / Status list).
    const total = 6;
    final usable = _usableMicCount() < total ? _usableMicCount() : total;
    final assigned = <int, MapEntry<String, Map<String, dynamic>>>{};
    final unassigned = <MapEntry<String, Map<String, dynamic>>>[];
    for (final e in peers.entries) {
      final sn = SupaDb.intOf(e.value['seat_no']);
      if (sn >= 1 && sn <= usable && !assigned.containsKey(sn)) {
        assigned[sn] = e;
      } else {
        unassigned.add(e);
      }
    }
    final seats = <VoiceSeatMember>[];
    var nextUnassigned = 0;
    for (var seatNo = 1; seatNo <= total; seatNo++) {
      MapEntry<String, Map<String, dynamic>>? entry;
      if (seatNo <= usable) {
        entry = assigned[seatNo];
        entry ??= nextUnassigned < unassigned.length
            ? unassigned[nextUnassigned++]
            : null;
      }
      if (entry == null) {
        seats.add(VoiceSeatMember(seatNumber: seatNo));
        continue;
      }
      final peerUid = entry.key;
      final peer = entry.value;
      final muted = peer['muted'] == true;
      final isHost = peerUid.isNotEmpty && peerUid == hostUid;
      final avatarUrl = _fix31AvatarUrls[peerUid];
      seats.add(VoiceSeatMember(
        seatNumber: seatNo,
        memberId: peerUid,
        name: _fix31PeerName(peerUid, peer),
        avatarAssetOrUrl: (avatarUrl != null && avatarUrl.isNotEmpty)
            ? avatarUrl
            : null,
        isHost: isHost,
        // Host: the full item-19 formula (async, via the
        // FutureBuilder). Others: profile verified flag only —
        // per-seat follower counts are not loaded (no fake tick).
        isVerified:
            isHost ? hostVerified : (_fix31VerifiedFlags[peerUid] ?? false),
        isMuted: muted,
        // No per-peer speaking detection exists (free WebRTC
        // audio tracks expose no voice activity) — the old
        // room's wave animated on MIC-ON, so isSpeaking mirrors
        // mic-on here, never faked speech.
        isSpeaking: !muted,
        requestToSpeak: false,
        accent: _fix31SeatAccent(seatNo),
        level: 1,
      ));
    }
    return seats;
  }

  List<ArenaChatMessage> _fix31MapMessages(
    List<Map<String, dynamic>> rawMsgs,
    String uid,
    String hostUid,
  ) {
    // Same filters as the old chat list, then LIVE-ONLY (fix23
    // item 7): only messages sent after this entry. A row with
    // no timestamp (ms == 0) is shown — it cannot be proven old.
    final msgs = rawMsgs
        .where((m) =>
            !_isMusicRow(m) &&
            !_isMusicApprovalRow(m) &&
            !_isChatClearedRow(m) &&
            !_isSticker(m) &&
            !_isGift(m))
        .where((m) {
          final ms = parseTsMs(m['created_at'] ?? m['timestamp']);
          return ms == 0 || ms >= _roomEnteredAtMs;
        })
        .toList();
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    final out = <ArenaChatMessage>[];
    String? lastDay;
    for (final m in msgs) {
      final ms = parseTsMs(m['created_at'] ?? m['timestamp']);
      final d =
          ms > 0 ? DateTime.fromMillisecondsSinceEpoch(ms) : DateTime.now();
      final dayKey = '${d.year}-${d.month}-${d.day}';
      if (dayKey != lastDay) {
        lastDay = dayKey;
        final now = DateTime.now();
        final label =
            (d.year == now.year && d.month == now.month && d.day == now.day)
                ? 'Today'
                : (d.year == now.year &&
                        d.month == now.month &&
                        d.day == now.day - 1)
                    ? 'Yesterday'
                    : '${d.day} ${months[d.month - 1]} ${d.year}';
        out.add(ArenaChatMessage(
          id: 'sep-$dayKey',
          senderName: '',
          initials: '',
          timestamp: '',
          text: label,
          isAnnouncement: true,
        ));
      }
      final senderUid = strVal(m['firebase_uid']);
      final name = strVal(m['display_name'], 'User');
      final avatarUrl = _fix31AvatarUrls[senderUid];
      out.add(ArenaChatMessage(
        id: strVal(m['id'], '${ms}_$senderUid'),
        senderName: name,
        avatarAssetOrUrl:
            (avatarUrl != null && avatarUrl.isNotEmpty) ? avatarUrl : null,
        initials: _fix31Initials(name),
        timestamp:
            '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}',
        text: strVal(m['message']),
        isHost: senderUid.isNotEmpty && senderUid == hostUid,
        isOwn: senderUid.isNotEmpty && senderUid == uid,
      ));
    }
    return out;
  }

  Future<void> _fix31SetMic(bool isOn) async {
    // The screen already flipped its local icon optimistically;
    // this handler only moves the REAL mic when the desired
    // state differs (a failed toggle reverts via didUpdateWidget).
    if (isOn == _fix31MicOn) return;
    await _toggleOwnSeat();
  }

  /// FIX 31: real send path — the same gates as [_send]
  /// (spectator / join gate / admin chat restriction / room
  /// mute), but the text comes from the new composer's callback
  /// instead of the legacy [_msg] controller.
  Future<void> _fix31SendMessage(String text) async {
    final msg = text.trim();
    if (msg.isEmpty) return;
    if (widget.spectator && !widget.shoutcaster) {
      toast(context, 'Spectator mode — chat view-only hai.');
      return;
    }
    if (!_canSendChat) {
      toast(context, 'You must join this tournament to send messages.');
      return;
    }
    final user = FirebaseAuth.instance.currentUser!;
    try {
      if (await SupaDb.isChatRestricted(user.uid)) {
        if (mounted) {
          toast(context,
              'Aapka chat admin ne band kiya hua hai — admin se rabta karein.');
        }
        return;
      }
    } catch (_) {}
    try {
      final mutes = await SupaDb.getList('room_mutes',
          eqCol: 'tournament_id',
          eqVal: widget.tournamentId,
          eqCol2: 'firebase_uid',
          eqVal2: user.uid);
      if (mutes.any((m) => m['active'] == true)) {
        if (mounted) {
          toast(context,
              'Aap is room me mute hain — host/admin ne mute kiya hai. Unmute hone tak chat/voice nahi chalegi.');
        }
        return;
      }
    } catch (_) {}
    final profile = await SupaDb.getProfile(user.uid);
    await SupaDb.sendChat(
      scope: widget.scope,
      scopeId: _chatScopeId,
      uid: user.uid,
      displayName: strVal(profile['displayName'], user.email ?? 'User'),
      message: widget.shoutcaster ? '$_shoutPrefix$msg' : msg,
    );
    HapticFeedback.lightImpact();
  }

  /// FIX 31: the rail Voice button's logic, extracted verbatim
  /// so the menu's Voice entry behaves identically (join /
  /// retry / voice-only leave).
  Future<void> _fix31OnVoiceTap() async {
    if (widget.spectator) {
      toast(context, 'Spectator mode — voice view-only hai.');
      return;
    }
    if (_lkRoom.joined) {
      await _confirmLeaveVoiceLiveKit();
      return;
    }
    if (!_room.joined) {
      _joinVoiceOpen();
      return;
    }
    if (_room.joinStalled) {
      await _retryVoice();
      return;
    }
    if (!_room.voiceReady) {
      toast(context, 'Voice connect ho rahi hai…');
      return;
    }
    await _confirmLeaveVoice();
  }

  /// FIX 31: the rail Follow FAB's logic, extracted verbatim —
  /// follows/unfollows the same uid the rail followed
  /// ([_adminUid]); the toast copy is unchanged.
  Future<void> _fix31ToggleFollowHost() async {
    final myUid = FirebaseAuth.instance.currentUser?.uid ?? '';
    final hostUid = _adminUid.isNotEmpty ? _adminUid : '';
    if (myUid.isEmpty || hostUid.isEmpty || hostUid == myUid) {
      toast(
          context,
          hostUid == myUid
              ? 'Aap khud ko follow nahi kar sakte.'
              : 'Host follow ke liye room reload karen.');
      return;
    }
    try {
      if (_following.contains(hostUid)) {
        await SupaDb.client
            .from('follows')
            .delete()
            .eq('follower_uid', myUid)
            .eq('following_uid', hostUid);
        setState(() => _following.remove(hostUid));
        if (mounted) toast(context, 'Unfollowed host');
      } else {
        await SupaDb.client.from('follows').insert(
            {'follower_uid': myUid, 'following_uid': hostUid});
        setState(() => _following.add(hostUid));
        if (mounted) toast(context, 'Followed host');
      }
    } catch (e) {
      if (mounted) toast(context, 'Follow failed: $e');
    }
  }

  /// FIX 31: extra menu rows for the MoreActionsSheet — every
  /// remaining rail/sidebar function with its real handler.
  /// Settings' own rows (Backgrounds, Frames, Participants,
  /// Diagnostics, Voice test, Cheer) keep their existing home
  /// inside the Settings sheet and are NOT duplicated here.
  List<ArenaMenuEntry> _fix31MenuExtras() {
    final musicOn = _musicPlaying != null;
    final voiceConnected = _voiceConnected;
    final followingHost =
        _adminUid.isNotEmpty && _following.contains(_adminUid);
    return [
      ArenaMenuEntry(
        icon: LucideIcons.power,
        label: 'Power',
        subtitle: musicOn ? 'On' : 'Off',
        color: musicOn
            ? ArenaColors.connectedGreen
            : ArenaColors.secondaryText,
        onTap: musicOn
            ? () => unawaited(_stopMusic())
            : () => unawaited(
                _showRjVoiceConsole(initialSection: 'player')),
      ),
      ArenaMenuEntry(
        icon: voiceConnected ? LucideIcons.mic : LucideIcons.micOff,
        label: 'Voice',
        subtitle: voiceConnected ? 'Voice On' : 'Voice Off',
        color: voiceConnected
            ? ArenaColors.connectedGreen
            : ArenaColors.liveRed,
        onTap: () => unawaited(_fix31OnVoiceTap()),
      ),
      if (_isSquad && !widget.spectator)
        ArenaMenuEntry(
          icon: LucideIcons.userPlus,
          label: 'Invite',
          color: ArenaColors.royalGold,
          onTap: () => unawaited(_inviteFromChat()),
        ),
      ArenaMenuEntry(
        icon: LucideIcons.heart,
        label: 'Follow Host',
        subtitle: followingHost ? 'Following' : 'Follow',
        color: ArenaColors.neonPink,
        onTap: () => unawaited(_fix31ToggleFollowHost()),
      ),
      if (voiceConnected)
        ArenaMenuEntry(
          icon: LucideIcons.phoneOff,
          label: 'Leave Voice',
          subtitle: 'Voice only — room stays open',
          color: ArenaColors.liveRed,
          onTap: () => unawaited(_lkRoom.joined
              ? _confirmLeaveVoiceLiveKit()
              : _confirmLeaveVoice()),
        ),
      if (_useLiveKit)
        ArenaMenuEntry(
          icon: LucideIcons.refreshCw,
          label: 'Refresh',
          subtitle: _lkDropped ? 'New project' : null,
          color: ArenaColors.electricBlue,
          onTap: () async {
            if (_lkReconnecting) {
              toast(context, 'Dobara connect ho raha hai…');
              return;
            }
            await _reconnectLiveKit();
          },
        ),
    ];
  }

  /// FIX 31: empty-seat tap — the old free-cell logic verbatim
  /// ([_stageCellFree]): spectator toast, admin takes the mic,
  /// locked-seat toast, join when not on voice, else the
  /// "already on voice" hint.
  Future<void> _fix31EmptySeatTap(int seatNo) async {
    if (widget.spectator) {
      toast(context, 'Spectator mode — mics view-only hain.');
      return;
    }
    if (_isRoomAdmin) {
      await _adminTakeMic(seatNo);
      return;
    }
    try {
      final locks = await SupaDb.getList('room_seat_locks',
          eqCol: 'room_id', eqVal: _voiceRoomId);
      if (locks.any((l) => SupaDb.intOf(l['seat_no']) == seatNo)) {
        if (mounted) toast(context, 'Mic $seatNo host ne lock kiya hua hai.');
        return;
      }
    } catch (_) {}
    final usable = _usableMicCount();
    if (!_room.joined && !_lkRoom.joined) {
      if (_room.peers.length >= usable) {
        if (mounted) {
          toast(context,
              'All $usable mics are full — you can still chat and listen until a mic frees.');
        }
        return;
      }
      _joinVoiceOpen();
    } else {
      if (mounted) {
        toast(context,
            'Mic $seatNo is free — you are already on voice. Tap your own mic to mute or unmute.');
      }
    }
  }

  void _fix31SeatTap(VoiceSeatMember seat) {
    final myUid = FirebaseAuth.instance.currentUser?.uid ?? '';
    if (!seat.isOccupied) {
      unawaited(_fix31EmptySeatTap(seat.seatNumber));
      return;
    }
    final targetUid = seat.memberId ?? '';
    if (targetUid == myUid) {
      unawaited(_toggleOwnSeat());
      return;
    }
    // Another member's seat: the host's admin menu (same as the
    // old grid's long-press).
    if (_isRoomAdmin && targetUid.isNotEmpty) {
      _showAdminMenu(targetUid, seat.name ?? 'A player');
    }
  }

  /// FIX 31: voice-diagnostics overlay for the new screen — the
  /// old overlay lived in the legacy build (below chat); here it
  /// renders as a dismissible card over the room when Settings >
  /// Voice diagnostics sets [_showVoiceDiag]. Same content
  /// ([_voiceDiagnostics]), same Hide action.
  Widget _fix31VoiceDiagOverlay() {
    return Positioned.fill(
      child: Container(
        color: Colors.black54,
        alignment: Alignment.center,
        child: Container(
          width: MediaQuery.of(context).size.width * 0.92,
          height: MediaQuery.of(context).size.height * 0.7,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: kCardPurpleMid,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: kCardPurpleBorder, width: 1.5),
          ),
          child: Column(
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text('Voice diagnostics',
                        style: TextStyle(
                            color: Color(0xFFFDC903),
                            fontWeight: FontWeight.bold,
                            fontSize: 16)),
                  ),
                  TextButton(
                    onPressed: () => setState(() => _showVoiceDiag = false),
                    child: const Text('Hide',
                        style: TextStyle(
                            color: Color(0xFF7786A5), fontSize: 12)),
                  ),
                ],
              ),
              Expanded(
                  child: SingleChildScrollView(child: _voiceDiagnostics())),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildArenaVoiceRoom(
    String uid,
    Map<String, Map<String, dynamic>> peers,
  ) {
    return FutureBuilder<Map<String, dynamic>>(
      future: _tournamentFuture,
      builder: (context, tsnap) {
        final occupied = peers.entries.toList();
        final host = _hostEntry(tsnap.hasData ? tsnap.data : null, occupied);
        final hostUid = host == null ? '' : host['uid'] as String;
        final hostName = host == null ? 'No host' : host['name'] as String;
        // FIX 31 (item 17): _hostEntry only returns the organizer
        // while present on voice — host == null IS "No host".
        final hostPresent = host != null;
        final coverUrl = widget.hostCardCoverUrl.isNotEmpty
            ? widget.hostCardCoverUrl
            : (tsnap.hasData ? _bannerOf(tsnap.data!) : '');
        _fix31EnsureAvatars([
          ...peers.keys,
          if (hostUid.isNotEmpty) hostUid,
        ]);
        return StreamBuilder<List<Map<String, dynamic>>>(
          stream: _chatStream,
          builder: (context, snap) {
            final rawMsgs = snap.data ?? [];
            // Same post-frame side effects as the old chat list:
            // music rows + chat-emptied handling.
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _handleMusicRows(rawMsgs);
              if (mounted) _handleChatEmptied(rawMsgs);
            });
            final msgs = rawMsgs
                .where((m) =>
                    !_isMusicRow(m) &&
                    !_isMusicApprovalRow(m) &&
                    !_isChatClearedRow(m) &&
                    !_isSticker(m) &&
                    !_isGift(m))
                .toList();
            if (msgs.length != _lastMsgCount) {
              final wasMine =
                  msgs.isNotEmpty && strVal(msgs.last['firebase_uid']) == uid;
              final playChat = MessageSounds.shouldPlayChatSound(
                  primed: _lastMsgCount >= 0,
                  grew: msgs.length > _lastMsgCount,
                  lastIsMine: wasMine);
              if (playChat) MessageSounds.play(MessageSound.chat);
              _lastMsgCount = msgs.length;
              if (_atBottom || wasMine) _scrollToBottom();
            }
            // Avatars for chat senders too (one lookup per uid).
            _fix31EnsureAvatars(
                msgs.map((m) => strVal(m['firebase_uid'])).toList());
            final messages = _fix31MapMessages(rawMsgs, uid, hostUid);
            final playersCount =
                peers.length + _liveListeners.listenerCount;
            final connected = _room.joined || _lkRoom.joined;
            final status = connected
                ? VoiceConnectionStatus.connected
                : (_lkConnecting || _lkReconnecting || _room.joinStalled)
                    ? VoiceConnectionStatus.reconnecting
                    : VoiceConnectionStatus.disconnected;
            final screen = FutureBuilder<bool>(
              future: _fix31HostVerifiedFutures.putIfAbsent(
                  hostUid, () => _fix31HostVerifiedFuture(hostUid)),
              builder: (context, vsnap) {
                final hostVerified = vsnap.data ?? false;
                final seats =
                    _fix31MapSeats(peers, uid, hostUid, hostVerified);
                final myPeer = peers[uid];
                final ownName = myPeer == null
                    ? strVal(
                        FirebaseAuth.instance.currentUser?.displayName,
                        FirebaseAuth.instance.currentUser?.email
                                ?.split('@')
                                .first ??
                            'You')
                    : _fix31PeerName(uid, myPeer);
                final ownAvatar = _fix31AvatarUrls[uid];
                final followersCount = widget.sidebarCommunityCount ??
                    widget.sidebarFollowersCount;
                return ArenaVoiceRoomScreen(
                  roomTitle: _roomTitle,
                  hostName: hostName,
                  hostAvatar: _fix31AvatarUrls[hostUid] ?? '',
                  hostVerified: hostVerified,
                  hostPresent: hostPresent,
                  hostBannerAssetOrUrl: coverUrl.isEmpty ? null : coverUrl,
                  initialSeats: seats,
                  initialMessages: messages,
                  initialDurationSeconds:
                      ((DateTime.now().millisecondsSinceEpoch -
                                  _roomEnteredAtMs) ~/
                              1000)
                          .clamp(0, 1 << 31),
                  connectionStatus: status,
                  isLive: connected,
                  isMicOn: _fix31MicOn,
                  isVoiceOn: true,
                  lockVoiceOutputOn: true,
                  micToggleEnabled: connected,
                  playersCount: playersCount,
                  ownMemberId: uid,
                  ownDisplayName: ownName,
                  ownAvatar: (ownAvatar != null && ownAvatar.isNotEmpty)
                      ? ownAvatar
                      : null,
                  ownInitials: _fix31Initials(ownName),
                  ownIsHost: hostPresent && uid == hostUid,
                  onMicToggled: (isOn) => unawaited(_fix31SetMic(isOn)),
                  onSendMessage: (text) =>
                      unawaited(_fix31SendMessage(text)),
                  // The screen already showed its own confirm
                  // dialog — onLeaveRoom is the REAL leave
                  // (stop music + leave voice + pop), NOT a
                  // second confirm dialog.
                  onLeaveRoom: _exitRoom,
                  onFollowers: widget.onSidebarFollowers ?? _openStatus,
                  onMusic: widget.onSidebarMusic ??
                      () => unawaited(_showRjVoiceConsole(
                          initialSection: 'player')),
                  onRjPanel: widget.onSidebarRjPanel ??
                      () => unawaited(_showRjVoiceConsole()),
                  onSettings: widget.onSidebarSettings ?? _showRoomSettings,
                  followersCountLabel: followersCount == null
                      ? null
                      : formatCompactCount(followersCount),
                  followState: widget.sidebarFollowing,
                  followBusy: widget.sidebarFollowBusy,
                  onFollowToggle: widget.onSidebarFollowToggle,
                  showRjPanel: _isAdminForBroadcast ||
                      _isTeamCaptainForBroadcast ||
                      _isCommunityOrganizerForBroadcast,
                  // PHASE E (E28): Music row, same host-only rule.
                  showMusic: _isAdminForBroadcast ||
                      _isTeamCaptainForBroadcast ||
                      _isCommunityOrganizerForBroadcast,
                  menuExtras: _fix31MenuExtras(),
                  onUsersTap: _openStatus,
                  onViewAll: _openStatus,
                  onSeatTap: _fix31SeatTap,
                  onImageTap: () => unawaited(_sendImage()),
                );
              },
            );
            if (!_showVoiceDiag) return screen;
            return Stack(
              children: [screen, _fix31VoiceDiagOverlay()],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser!.uid;
    final peers = _room.peers;
    // ROUND 9 KEYBOARD FIX (user order 07:24 PKT): resize alone was
    // NOT enough — on a small phone the fixed seat block (~230px)
    // + input (~100px) + AppBar already fill the keyboard-shrunk
    // viewport, so the Expanded chat collapsed to ~0 and the input
    // rendered behind the keyboard (release-mode overflow clips,
    // it does not scroll). While the keyboard is open the seat
    // grid collapses to one slim row and the member strip hides,
    // so chat + input always fit ABOVE the keyboard; everything
    // returns when the keyboard closes. The side column (Activity
    // / Music / Info / Exit) stays visible in both states.
    // Keyboard-open also auto-scrolls chat to the latest message
    // (on the open transition, not on every rebuild).
    final kbOpen = MediaQuery.of(context).viewInsets.bottom > 0;
    if (kbOpen && !_wasKbOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    }
    _wasKbOpen = kbOpen;
    // v2017 INLINE VOICE: embedded mode renders the voice panel
    // only (no Scaffold, no chat) — TeamChatPage hosts it above
    // the team chat.
    if (widget.embedded) return _buildEmbeddedVoice(uid, peers, kbOpen);
    // FIX 31: full-page presentation is the AI Studio voice
    // room screen (see _buildArenaVoiceRoom above); the old
    // full-page Scaffold body lives on as _buildLegacyFullRoom
    // below (preserved verbatim for rollback + merger).
    return _buildArenaVoiceRoom(uid, peers);
  }

  // FIX 31: the pre-item-31 full-page room UI, preserved
  // VERBATIM (moved, not edited) for rollback and for the
  // merger to reconcile against fix24 broadcast wiring.
  // It is not called while the AI Studio screen is live.
  // ignore: unused_element
  Widget _buildLegacyFullRoom(String uid,
      Map<String, Map<String, dynamic>> peers, bool kbOpen) {
    return Scaffold(
      // Explicit: body resizes above the keyboard (manifest is also
      // adjustResize). The input is the last Column child, so with a
      // compact voice strip it always lands above the keyboard.
      resizeToAvoidBottomInset: true,
      // ROUND 12 (user order 08:19 PKT): NO AppBar, NO top icon row
      // at all — the round-11 top row is DELETED and its two icons
      // moved into the side column. The room starts directly with
      // the seat grid at the very top. Background is a rich
      // dark-gold gradient with ORIGINAL gold glow shapes only
      // (radial glows + a thin gold hairline); no copied artwork,
      // photos, names or branding anywhere.
      body: Stack(
        children: [
          // FIX 23 items 14+21: by DEFAULT (no stored background
          // pick) the room shows the app-wide background image
          // (AppBackgroundLayer) instead of the neon gradient —
          // the image supersedes item 14's code-drawn default.
          // An explicit pick shows its gradient instead.
          if (!_bgUserPicked)
            const AppBackgroundLayer(respectLightMode: false),
          if (_bgId == 'custom' && _customBgUrl.isNotEmpty && !_customBgUrl.startsWith('file:'))
            // Wave 4 item B: disk-cached provider in a DecorationImage —
            // NOT ArenaCachedImage here, deliberately: the old
            // errorBuilder was SizedBox.shrink (invisible on error, the
            // gradient below shows), and a full-screen dark card +
            // 'Image unavailable' text would be a visible regression.
            // A DecorationImage simply paints nothing on failure, so
            // the invisible-on-error behaviour is preserved exactly.
            Positioned.fill(child: Container(decoration: BoxDecoration(image: DecorationImage(image: CachedNetworkImageProvider(_customBgUrl), fit: BoxFit.cover)))),
          if (_bgId == 'custom' && _customBgUrl.startsWith('file:'))
            Positioned.fill(child: Image.file(File(_customBgUrl.substring(5)), fit: BoxFit.cover, errorBuilder: (_, __, ___) => const SizedBox.shrink())),
          if (_bgUserPicked)
            Container(
              decoration: BoxDecoration(gradient: LinearGradient(colors: _bgColors(), begin: Alignment.topCenter, end: Alignment.bottomCenter)),
            ),
          // ROUND 16: rich original ornamental layer over the gradient
          // (painted lattice + arch arcs + sparkle) plus extra radial
          // glows, so the room body is layered, not a flat colour.
          Positioned.fill(child: CustomPaint(painter: _OrnateRoomPainter())),
          // FIX 22 item 18: gold ambient glows (was purple/pink/
          // blue) — the room background suits the black theme
          // now. The heart accent is gone too. The base gradient
          // itself stays the user's chosen room background
          // (_bgColors), so the Backgrounds setting keeps working.
          Positioned(
            top: -60,
            left: 40,
            child: Container(width: 220, height: 220, decoration: BoxDecoration(shape: BoxShape.circle, gradient: RadialGradient(colors: [nGold.withValues(alpha: 0.16), Colors.transparent]))),
          ),
          Positioned(
            top: -90,
            right: -70,
            child: Container(width: 280, height: 280, decoration: BoxDecoration(shape: BoxShape.circle, gradient: RadialGradient(colors: [nGold.withValues(alpha: 0.12), Colors.transparent]))),
          ),
          Positioned(
            top: 220,
            left: -110,
            child: Container(width: 220, height: 220, decoration: BoxDecoration(shape: BoxShape.circle, gradient: RadialGradient(colors: [nGold.withValues(alpha: 0.10), Colors.transparent]))),
          ),
          Positioned(
            bottom: 90,
            right: -90,
            child: Container(width: 200, height: 200, decoration: BoxDecoration(shape: BoxShape.circle, gradient: RadialGradient(colors: [nGold.withValues(alpha: 0.08), Colors.transparent]))),
          ),
          // ROUND 12 v2: subtle static gold sparkle dots over the
          // gradient (original Flutter shapes only, no artwork).
          Positioned(top: 130, left: 36, child: Container(width: 3, height: 3, decoration: BoxDecoration(shape: BoxShape.circle, color: nGold.withValues(alpha: 0.40)))),
          Positioned(top: 210, right: 70, child: Container(width: 3, height: 3, decoration: BoxDecoration(shape: BoxShape.circle, color: nGold.withValues(alpha: 0.32)))),
          Positioned(top: 320, left: 90, child: Container(width: 3, height: 3, decoration: BoxDecoration(shape: BoxShape.circle, color: nGold.withValues(alpha: 0.28)))),
          Positioned(top: 470, right: 44, child: Container(width: 3, height: 3, decoration: BoxDecoration(shape: BoxShape.circle, color: nGold.withValues(alpha: 0.36)))),
          Positioned(top: 580, left: 52, child: Container(width: 3, height: 3, decoration: BoxDecoration(shape: BoxShape.circle, color: nGold.withValues(alpha: 0.26)))),
          Positioned(top: 90, left: 150, child: Container(width: 3, height: 3, decoration: BoxDecoration(shape: BoxShape.circle, color: nGold.withValues(alpha: 0.32)))),
          // SafeArea keeps content below the phone status bar while
          // the gradient itself still fills the very top (no black
          // strip anywhere); bottom is NOT padded, so the input
          // row still sits flush above the keyboard/navigation area.
          SafeArea(
          top: true,
          bottom: false,
          child: Column(
          children: [
          // A-5 (026): the ONLY exception to "nothing above the
          // seats" — the "Band hai" banner, shown only while the
          // room is admin-closed (voice join disabled).
          if (_roomVoiceDisabled) _buildRoomDisabledBanner(),
          // ROUND 12: NOTHING above the seats — no AppBar, no
          // icon row, no title. The seat grid is the first thing
          // on the page, directly under the status bar.
          // ROUND 9 (user order 07:18 PKT): host strip + prize chip
          // DELETED entirely — no replacement header, no trophy
          // chip. Seat grid is first at the top; the member strip
          // below only shows while someone is on voice. Room name,
          // Room ID and Prize Pool live ONLY in the Info dialog
          // (_showRoomInfo, untouched).
          // ROUND 8 seat section (reference: seats directly at the
          // top, no voice header/status/buttons above them). Voice
          // controls are gone from here entirely: Take mic joins
          // voice OPEN, tapping your own seat mutes/unmutes, leaving
          // the room (Exit button / dispose) leaves voice, speaker
          // is the bottom-bar icon only, diagnostics live in the
          // Info dialog and in the bottom panel below the chat.
          // ROUND 9: while the keyboard is open this grid collapses
          // to one slim row (see kbOpen branch in the builder) so
          // chat + input fit above the keyboard.
          // ROUND 16 (latest order SUPERSEDES earlier removals):
          // slim host strip + trophy/prize (integrated in the same
          // row to save height) + online member strip return in
          // original form. Host row ~30px, member row only when
          // someone is on voice, so chat height is barely eaten.
          _buildHostStrip(uid, peers),
          // v2016 FIX 7 (user order 2026-11-22): the 'LIVE VOICE
          // CHAT' stats strip above the mics is GONE — the Builder
          // that computed micsOn and rendered _voiceStrip was
          // deleted with the method itself.
          // USER ORDER 2026-11-01: tournament banner (trophy + name + Live now) REMOVED entirely — mic grid moves up by the banner height.
          ..._buildRequestBanners(),
          // CHAT WIDTH FIX (2026-10-30 user order): the chat panel lives
          // in the SAME left column as the mic grid — its right edge
          // ends where the grid ends, and the 72dp rail column stays
          // clear beside it (rail + chat side by side, not chat
          // stretched underneath the rail). Putting the rail beside
          // the grid+chat column (instead of above the chat) also
          // frees vertical space, so several messages show above
          // the composer instead of one squeezed row. Composer
          // below stays full-width, as ordered.
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
          _buildSeatGrid(uid, peers, kbOpen),
if (_room.joined && (_room.connectionGenuinelyFailed || _room.signalFailedRecently))
            _buildConnectionFailedBanner(),
if (_checkedJoin && _adminLoaded && !_joinBannerDismissed && !_canSendChat && !_isSquad)
            _buildJoinBanner(),
          Expanded(
            // 2026-11-20 (user order, "har jagah"): the chat panel
            // is a MockupCard — gradient fill + the two rotating
            // gold corner shines, no static neon border. The chat
            // list inside is untouched (same stream, same items).
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 0, 0),
              child: MockupCard(
                padding: EdgeInsets.zero,
                radius: kRadiusCard,
                child: ClipRRect(
              borderRadius: BorderRadius.circular(kRadiusCard),
              child: Column(
                children: [
          // USER ORDER 2026-11-01: welcome FLASH — slides in once
          // from the top when someone joins, auto-hides after ~4s
          // (timer in _addWelcomeRow), never stays in the chat.
          if (_flashWelcome != null)
            TweenAnimationBuilder<Offset>(
              key: ValueKey(_flashWelcome),
              tween: Tween(begin: const Offset(0, -1), end: Offset.zero),
              duration: const Duration(milliseconds: 400),
              curve: Curves.easeOut,
              builder: (context, v, child) => FractionalTranslation(translation: v, child: child),
              child: Center(
                child: Container(
                  margin: const EdgeInsets.fromLTRB(12, 10, 12, 4),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(colors: [kGold.withValues(alpha: 0.22), const Color(0xFF120C06)]),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: kGold, width: 1),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.celebration, color: kGold, size: 16),
                      const SizedBox(width: 8),
                      Flexible(child: Text('$_flashWelcome entered the room', style: TextStyle(color: kGold, fontWeight: FontWeight.bold, fontSize: 13, height: 1.3), maxLines: 2, textAlign: TextAlign.center)),
                    ],
                  ),
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
            child: Row(
              children: [
                Container(width: 8, height: 8, decoration: BoxDecoration(color: kGold, shape: BoxShape.circle, boxShadow: [BoxShadow(color: kGold.withValues(alpha: 0.6), blurRadius: 6)])),
                const SizedBox(width: kSpace8),
                const Text('LIVE CHAT', style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w900, letterSpacing: 1.4, height: 1.2)),
                const Spacer(),
                Icon(Icons.people, color: kMuted, size: 14),
                const SizedBox(width: 4),
                // v2016 FIX 8 (user order 2026-11-22): the count is
                // the live presence count (_roomUserCount: in-room
                // + online within 2 min, voice peers as fallback) —
                // NOT peers.length, which counted only mesh voice
                // peers (0 for visitors, 0 on a LiveKit visit).
                Text('${_roomUserCount()} online', style: TextStyle(color: kMuted, fontSize: 11, fontWeight: FontWeight.w700, height: 1.2)),
              ],
            ),
          ),
          Container(height: 1, margin: const EdgeInsets.symmetric(horizontal: 14), color: kGold.withValues(alpha: 0.14)),
          Expanded(
            child: StreamBuilder<List<Map<String, dynamic>>>(
              // FIX 20 (fix 18): the initState-created stream —
              // never a fresh streamChat() call per build.
              stream: _chatStream,
              builder: (context, snap) {
                // ROUND 9: MUSIC:: rows drive shared playback (handled
                // post-frame, deduped) and are NEVER shown as chat.
                // Filtering first also keeps session rows from moving
                // the chat scroll position or the empty-state.
                final rawMsgs = snap.data ?? [];
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) _handleMusicRows(rawMsgs);
                  if (mounted) _handleChatEmptied(rawMsgs);
                });
                // BIG STICKERS REMOVED (2026-10-30 user order):
                // STICKER:: rows are filtered out of the visible
                // stream entirely — no large sticker glyph ever
                // renders in chat again. Text, gifts and images
                // are untouched by this filter.
                final msgs = rawMsgs.where((m) => !_isMusicRow(m) && !_isMusicApprovalRow(m) && !_isChatClearedRow(m) && !_isSticker(m) && !_isGift(m)).toList();
                if (msgs.length != _lastMsgCount) {
                  final wasMine = msgs.isNotEmpty && strVal(msgs.last['firebase_uid']) == uid;
                  // MESSAGE SOUNDS: new message from someone else -> in-chat pop (chat_08); first load (_lastMsgCount -1) / own never beep.
                  final playChat = MessageSounds.shouldPlayChatSound(primed: _lastMsgCount >= 0, grew: msgs.length > _lastMsgCount, lastIsMine: wasMine);
                  if (playChat) MessageSounds.play(MessageSound.chat);
                  _lastMsgCount = msgs.length;
                  if (_atBottom || wasMine) _scrollToBottom();
                }
                if (msgs.isEmpty) {
                  // REDESIGN S7 (2026-11-23, guide §F): the empty
                  // chat state in the mockup's treatment — the
                  // gold-ring chat icon, and the line flanked by
                  // two short gold divider lines fading outward.
                  // The copy is UNCHANGED (exact existing text).
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(width: 56, height: 56, decoration: BoxDecoration(shape: BoxShape.circle, color: kGold.withValues(alpha: 0.12), border: Border.all(color: kGold.withValues(alpha: 0.35))), alignment: Alignment.center, child: Icon(Icons.chat_bubble_outline, color: kGold, size: 26)),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              Expanded(child: Container(height: 1, decoration: BoxDecoration(gradient: LinearGradient(colors: [kGold.withValues(alpha: 0), kGold.withValues(alpha: 0.6)])))),
                              const SizedBox(width: 10),
                              Flexible(child: Text('No messages yet. Say hi!', style: TextStyle(color: kMuted, fontSize: 14, fontWeight: FontWeight.w600), textAlign: TextAlign.center)),
                              const SizedBox(width: 10),
                              Expanded(child: Container(height: 1, decoration: BoxDecoration(gradient: LinearGradient(colors: [kGold.withValues(alpha: 0.6), kGold.withValues(alpha: 0)])))),
                            ],
                          ),
                        ],
                      ),
                    ),
                  );
                }
                const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
                final items = <Map<String, dynamic>>[];
                String? lastDay;
                for (final m in msgs) {
                  final ms = parseTsMs(m['created_at'] ?? m['timestamp']);
                  final d = ms > 0 ? DateTime.fromMillisecondsSinceEpoch(ms) : DateTime.now();
                  final dayKey = '${d.year}-${d.month}-${d.day}';
                  if (dayKey != lastDay) {
                    lastDay = dayKey;
                    final now = DateTime.now();
                    String label;
                    if (d.year == now.year && d.month == now.month && d.day == now.day) {
                      label = 'Today';
                    } else if (d.year == now.year && d.month == now.month && d.day == now.day - 1) {
                      label = 'Yesterday';
                    } else {
                      label = '${d.day} ${months[d.month - 1]} ${d.year}';
                    }
                    items.add({'sep': label});
                  }
                  items.add(m);
                }
                // USER ORDER 2026-11-01: welcome rows are NOT merged into
                // chat history any more — they flash once above the messages.
                final displayItems = items;
                // ROUND 8b: chat floats OVER the themed background,
                // not inside a separate boxed card (Royal reference).
                return ListView.builder(
                  controller: _chatScroll,
                  padding: const EdgeInsets.fromLTRB(14, 6, 14, 14),
                  itemCount: displayItems.length,
                  itemBuilder: (_, idx) => _chatItem(displayItems[idx], uid),
                );
              },
            ),
          ),
                  // MASTER-PROMPT admin strip (§13): pinned message
                  // from real admin data only; hidden when none.
          // FULL COMPLETION expansion 3: pinned message banner —
          // host-set via Host Tools; missing table = hidden, never an
          // error state (HostToolsPage shows the pending card).
          FutureBuilder<List<Map<String, dynamic>>>(
            future: SupaDb.getList('pinned_messages', eqCol: 'tournament_id', eqVal: widget.tournamentId, orderBy: 'created_at', ascending: false, limit: 1),
            builder: (context, psnap) {
              if (!psnap.hasData || psnap.data!.isEmpty) return const SizedBox.shrink();
              final pinText = strVal(psnap.data!.first['message']);
              if (pinText.isEmpty) return const SizedBox.shrink();
              // P1-7: the shared mockup-#27 pinned banner (gold left
              // border + pin icon + "PINNED: {text}" + "View" gold
              // link) instead of the room's own gold box. "View"
              // shows the full pinned text. Pin writes come from
              // Host Tools or the in-chat admin long-press pin
              // action (see _showMessageLongPressMenu /
              // _pinChatMessage, Batch 3B).
              return ArenaPinnedBanner(
                message: pinText,
                onView: () => showDialog<void>(
                  context: context,
                  builder: (context) => AlertDialog(
                    backgroundColor: kCardPurpleMid,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22), side: const BorderSide(color: kCardPurpleBorder, width: 1.5)),
                    title: Text('Pinned Message', style: TextStyle(color: kGold)),
                    content: Text(pinText, style: TextStyle(color: kText)),
                    actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text('Close', style: TextStyle(color: kGold)))],
                  ),
                ),
              );
            },
          ),
                ],
              ),
            ),
            ),
              ),
          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (!kbOpen) _navRail(),
                ],
              ),
            ),
          ),
// ROUND 8 diagnostics panel (below chat, above input):
          // the only place diagnostics now live in the room UI
          // (also reachable from Info). Hide closes it.
          if (_showVoiceDiag)
            Container(
              height: 220,
              margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: SingleChildScrollView(child: _voiceDiagnostics()),
            ),
          // ---- Chat input (same screen as voice) ----
          if (_replyTo != null)
            Container(
              width: double.infinity,
              decoration: BoxDecoration(color: kGold.withValues(alpha: 0.08), border: Border(left: BorderSide(color: kGold, width: 3))),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(children: [
                Expanded(child: Text('Replying to ${strVal(_replyTo!['display_name'])}: ${_replyLabel(_replyTo!)}', style: TextStyle(color: kMuted, fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis)),
                IconButton(icon: Icon(Icons.close, color: kMuted, size: 18), onPressed: () => setState(() => _replyTo = null)),
              ]),
            ),
          // SMALL EMOJI STRIP ONLY (2026-10-30 user order): the
          // big 230px Emoji/Gifts picker panel is REMOVED entirely
          // (both tabs + the gift-send path). Tapping the composer
          // smiley toggles just this one slim horizontal row; an
          // emoji tap inserts it SMALL and inline into typed text.
          // No big emoji, no gifts, no stickers anywhere in chat.
          if (_showEmojiStrip)
            Container(
              height: 48,
              decoration: BoxDecoration(color: kCard, border: Border(top: BorderSide(color: nGold.withValues(alpha: 0.2)))),
              child: Row(
                children: [
                  Expanded(
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      itemCount: _emojis.length,
                      itemBuilder: (_, i) => InkWell(
                        onTap: () => _insertEmoji(_emojis[i]),
                        child: Center(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 6), child: Text(_emojis[i], style: const TextStyle(fontSize: 20)))),
                      ),
                    ),
                  ),
                  IconButton(icon: Icon(Icons.close, color: kMuted, size: 18), onPressed: () => setState(() => _showEmojiStrip = false)),
                ],
              ),
            ),
          // MASTER-PROMPT composer (§14): one line — emoji, field,
          // send. v2016 (user order 2026-11-22): the raise-hand
          // button is GONE, and the photo button moved INSIDE the
          // text field (left corner) as a small WhatsApp-style
          // attach icon — no round image button outside any more.
          // Speaker lives in Settings (rail).
          // The gift button is GONE (big gifts removed 2026-10-30);
          // image sending survives through the in-field attach icon.
          // 2026-11-20 (user order, "har jagah"): the composer is a
          // MockupCard — gradient fill + the two rotating gold
          // corner shines; the send button is solid gold like the
          // mockup's yellow circular send button.
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: MockupCard(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              radius: 28,
              child: Row(
              children: [
                IconButton(
                  padding: const EdgeInsets.all(4), constraints: const BoxConstraints(minWidth: 40, minHeight: 40), iconSize: 22,
                  icon: const Icon(Icons.emoji_emotions, color: Colors.white), tooltip: 'Emoji',
                  onPressed: () { _msgFocus.unfocus(); setState(() => _showEmojiStrip = !_showEmojiStrip); },
                ),
                Expanded(
                  // FIX 23 item 29 — STYLE ONLY: the composer field
                  // wears the card look (CardFieldShell, radius 24).
                  // Layout, attach icon, send behaviour and keyboard
                  // handling unchanged.
                  child: CardFieldShell(
                    radius: 24,
                    child: TextField(
                    controller: _msg,
                    focusNode: _msgFocus,
                    onTap: () { if (_showEmojiStrip) setState(() => _showEmojiStrip = false); },
                    style: const TextStyle(color: Colors.white, fontSize: 15, height: 1.4),
                    // v2016 (user order 2026-11-22): the photo
                    // upload lives INSIDE the field now — a small
                    // WhatsApp-style attach icon at the left
                    // corner (was a round image button outside).
                    // REDESIGN S7 (2026-11-23, guide §G): the
                    // composer field on the shared tokens. FIX 23
                    // item 29: the card look now comes from the
                    // CardFieldShell above (gradient + purple border
                    // + glow) — the field itself is borderless.
                    // Placeholder, attach icon, send behaviour and
                    // keyboard handling unchanged.
                    decoration: InputDecoration(prefixIcon: IconButton(padding: EdgeInsets.zero, constraints: const BoxConstraints(minWidth: 36, minHeight: 36), iconSize: 20, icon: Icon(Icons.attach_file, color: kGold), tooltip: 'Send a photo', onPressed: _sendImage), prefixIconConstraints: const BoxConstraints(minWidth: 40, minHeight: 36), hintText: _canSendChat ? 'Type a message...' : 'Join to send messages', hintStyle: TextStyle(color: kMuted), border: const OutlineInputBorder(borderSide: BorderSide.none), enabledBorder: const OutlineInputBorder(borderSide: BorderSide.none), focusedBorder: const OutlineInputBorder(borderSide: BorderSide.none), contentPadding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16)),
                  ),
                  ),
                ),
                Container(
                  decoration: BoxDecoration(shape: BoxShape.circle, boxShadow: [BoxShadow(color: kGold.withValues(alpha: 0.4), blurRadius: 10, spreadRadius: 1)]),
                  child: IconButton(
                    padding: const EdgeInsets.all(4), constraints: const BoxConstraints(minWidth: 40, minHeight: 40), iconSize: 21,
                    icon: const Icon(Icons.send, color: Colors.black), tooltip: 'Send',
                    style: IconButton.styleFrom(backgroundColor: kGold),
                    onPressed: _send,
                  ),
                ),
                // v2016 (user order 2026-11-22): the round photo
                // button outside the field is GONE — photo upload
                // is the small attach icon INSIDE the field now.
                // The raise-hand button is GONE too.
              ],
            ),
              ),
          ),
          // BOTTOM BAR REMOVED (2026-11-01 user order): the big
          // Join pill + VIP Room + Hot Room buttons are gone —
          // their ~76px now go to chat. Voice connect/leave/retry
          // lives on the small rail Voice button, and LiveKit
          // project-change reconnect on the rail Refresh button.
          // LIVEKIT RECONNECT BANNER (2026-11-01): inline, in the
          // room itself — never a popup, never a kick-out. Hidden
          // unless a LiveKit drop / project change raised it (see
          // _liveKitDroppedBanner). FIX 12 G6b: the connect-error
          // banner sits with it (failed join -> reason + Retry).
          _buildVoiceConnectErrorBanner(),
          _liveKitDroppedBanner(),
        ],
        ),
        ),
      ],
      ),
    );
  }
}
