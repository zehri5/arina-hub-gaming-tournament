// RJ DUCKING — ANY-SPEAKER (2026-11-22 user order, 20:38 PKT):
// "jab mic ON ho to ... koi bhi ek banda bolne lage to music ka
// volume auto down ho jaye, jaise FM RJ mein hota hai." The user
// says this existed before and is gone now.
//
// Root cause (proven from code, room_screen.dart ~2534): the duck
// trigger _playerMicUnmuted() read ONLY the music-sharing PLAYER's
// mic — self: _room.muted; others: the player's peer row / poll
// cache. A muted player + a speaking seat 2-6 never ducked. On a
// LiveKit visit it was worse: the trigger read only mesh state AND
// _onLiveKitChanged never called _applySharedDucking at all, so
// LiveKit mute changes never re-evaluated ducking.
//
// The fix: the trigger is now ANY-speaker — the pure rule lives on
// PresenceService (anyMicUnmuted, same pattern as Fix 8's
// countOnlineUsers) and reads self on BOTH engines, mesh peers,
// LiveKit participants, and the fresh 5s-poll cache. Full volume
// returns only when ALL are muted. 5% RJ bed, FM fade,
// shared-session-only scope, tones/fallback never ducked, and the
// 2-minute freshness rule are unchanged.
//
// FM FADE SPLIT (Sameer steer 2026-11-22 20:54, "jaise FM RJ karta
// hai"): the old single 600 ms fade is now TWO durations —
// duck-DOWN fast (~350 ms, voice wins at once) and fade-UP slow
// (~1.4 s, music creeps back gently), both smoothstep, with the
// generation-counter mid-fade reversal kept (a mic toggle mid-fade
// reverses smoothly from the CURRENT volume, never jumps).
// Endpoints unchanged (ducked = base x 0.05, full = base).
//
// FIX 22 item 11 SUPERSEDES the fade split (Sameer 2026-11-23
// 18:51: "fade in fade out ko chhodo"): _applyMusicVolume is
// DIRECT now — one setVolume(target), no ramp at all, for user
// drags AND ducking. The fade machinery (_runMusicFade,
// _musicFadeGen, both durations, _musicCurrentVolume) is
// DELETED; the tests below pin direct application instead.
//
// These are REAL unit tests on the pure rule, plus source pins
// proving the Room screen + LiveKit service actually use it (room
// widget tests are impractical: Firebase + Supabase + LiveKit).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/services/presence_service.dart';

String _read(String path) => File(path).readAsStringSync();

int _nowMs() => DateTime.now().millisecondsSinceEpoch;

// Mesh peer row (uid -> row); muted flag only — the rule reads
// row['muted'] != true as unmuted, same as the old player rule.
Map<String, Map<String, dynamic>> _meshPeers(Map<String, bool> mutedByUid) =>
    {for (final e in mutedByUid.entries) e.key: {'muted': e.value}};

bool _any({
  String selfUid = 'me',
  bool selfMeshJoined = false,
  bool selfMeshMuted = true,
  bool selfLiveKitJoined = false,
  bool selfLiveKitMuted = true,
  Map<String, Map<String, dynamic>> meshPeers = const {},
  Map<String, bool> liveKitPeerMuted = const {},
  Map<String, bool> pollMuted = const {},
}) =>
    PresenceService.anyMicUnmuted(
      selfUid: selfUid,
      selfMeshJoined: selfMeshJoined,
      selfMeshMuted: selfMeshMuted,
      selfLiveKitJoined: selfLiveKitJoined,
      selfLiveKitMuted: selfLiveKitMuted,
      meshPeers: meshPeers,
      liveKitPeerMuted: liveKitPeerMuted,
      pollMuted: pollMuted,
    );

// A voice-peer poll row: fresh (30 s ago) or stale (5 min ago).
Map<String, dynamic> _pollRow(String uid, {required bool muted, required bool fresh}) => {
      'firebase_uid': uid,
      'muted': muted,
      'joined_at': fresh ? _nowMs() - 30 * 1000 : _nowMs() - 5 * 60 * 1000,
    };

void main() {
  group('RJ ducking — any-speaker rule', () {
    test('(a) player muted + another peer unmuted -> duck engages', () {
      // Self is the sharing player, joined on mesh, MUTED.
      // Seat 2 (u2) is unmuted. Old rule: no duck. New rule: duck.
      expect(
        _any(
          selfMeshJoined: true,
          selfMeshMuted: true,
          meshPeers: _meshPeers({'u2': false}),
        ),
        isTrue,
      );
      // Same when the player is ANOTHER uid (muted) and a third
      // seat speaks.
      expect(
        _any(
          meshPeers: _meshPeers({'player': true, 'u3': false}),
        ),
        isTrue,
      );
      // A fresh poll row for an unmuted non-voice listener ducks too.
      expect(_any(pollMuted: {'u4': false}), isTrue);
    });

    test('(b) all muted -> full volume (no duck)', () {
      // Everyone on voice, everyone muted.
      expect(
        _any(
          selfMeshJoined: true,
          selfMeshMuted: true,
          meshPeers: _meshPeers({'u2': true, 'u3': true}),
          liveKitPeerMuted: {'u4': true},
          pollMuted: {'u5': true},
        ),
        isFalse,
      );
      // Nobody on voice at all.
      expect(_any(), isFalse);
      // Self joined but muted, no peers.
      expect(
        _any(selfMeshJoined: true, selfMeshMuted: true),
        isFalse,
      );
      // Self NOT joined: a stale self flag must not duck.
      expect(
        _any(selfMeshJoined: false, selfMeshMuted: false),
        isFalse,
      );
    });

    test('(c) LiveKit participant unmuted -> duck engages', () {
      // Remote LiveKit participant unmuted (mesh empty — LK visit).
      expect(
        _any(liveKitPeerMuted: {'u2': false}),
        isTrue,
      );
      // Self unmuted on LiveKit (mesh not joined at all).
      expect(
        _any(selfLiveKitJoined: true, selfLiveKitMuted: false),
        isTrue,
      );
      // All LiveKit participants muted -> no duck.
      expect(
        _any(
          selfLiveKitJoined: true,
          selfLiveKitMuted: true,
          liveKitPeerMuted: {'u2': true, 'u3': true},
        ),
        isFalse,
      );
    });

    test('(d) stale poll row does not keep music ducked', () {
      // Fresh unmuted row is kept; stale unmuted row is dropped.
      final fresh = PresenceService.freshPeerMuted(
        [_pollRow('u2', muted: false, fresh: true)],
        nowMs: _nowMs(),
      );
      expect(fresh, {'u2': false});
      final stale = PresenceService.freshPeerMuted(
        [_pollRow('u2', muted: false, fresh: false)],
        nowMs: _nowMs(),
      );
      expect(stale, isEmpty);
      // And the dropped row cannot duck: an empty cache + everyone
      // muted = full volume.
      expect(_any(pollMuted: stale), isFalse);
      // Unparseable joined_at (0) is also dropped.
      final noTs = PresenceService.freshPeerMuted(
        [
          {'firebase_uid': 'u9', 'muted': false, 'joined_at': null},
        ],
        nowMs: _nowMs(),
      );
      expect(noTs, isEmpty);
    });

    test('self is judged by live flags, not a stale self row', () {
      // Self muted on mesh, but a stale self row in the mesh peers
      // map still says unmuted: must NOT duck.
      expect(
        _any(
          selfMeshJoined: true,
          selfMeshMuted: true,
          meshPeers: _meshPeers({'me': false}),
        ),
        isFalse,
      );
      // Same for a stale self row in the poll cache.
      expect(
        _any(
          selfMeshJoined: true,
          selfMeshMuted: true,
          pollMuted: {'me': false},
        ),
        isFalse,
      );
    });

    test('peer row with no muted key counts as unmuted (old semantics)', () {
      expect(
        _any(meshPeers: {
          'u2': {'display_name': 'Seat 2'},
        }),
        isTrue,
      );
    });
  });

  group('RJ ducking — wiring pins', () {
    test('room screen uses the any-speaker trigger, player-only is gone', () {
      final src = _read('lib/screens/room_screen.dart');
      expect(src, contains('PresenceService.anyMicUnmuted'));
      expect(src, contains('final duck = _anyMicUnmuted();'));
      expect(src, isNot(contains('_playerMicUnmuted')));
      // LiveKit participants feed the trigger.
      expect(src, contains('_lkRoom.participants.entries'));
      // Poll cache feeds the trigger through the freshness filter.
      expect(src, contains('PresenceService.freshPeerMuted'));
    });

    test('LiveKit changes re-evaluate ducking', () {
      final src = _read('lib/screens/room_screen.dart');
      final idx = src.indexOf('void _onLiveKitChanged()');
      expect(idx, isNot(-1));
      final end = src.indexOf('\n  }', idx);
      final body = src.substring(idx, end);
      expect(body, contains('_applySharedDucking();'));
    });

    test('LiveKit service syncs participants on mute/publish events', () {
      final src = _read('lib/services/livekit_voice_service.dart');
      expect(src, contains('lk.TrackMutedEvent'));
      expect(src, contains('lk.TrackUnmutedEvent'));
      expect(src, contains('lk.TrackPublishedEvent'));
      expect(src, contains('lk.TrackUnpublishedEvent'));
    });

    test('status line wording matches any-speaker (accurate)', () {
      final src = _read('lib/screens/room_screen.dart');
      expect(src, contains('Someone on mic — music ducked to 5% — RJ bed'));
      expect(src, contains('All mics muted — music at full volume'));
      expect(src, isNot(contains('Mic ON — music ducked')));
    });

    test('5% RJ bed + shared-session-only scope unchanged', () {
      final src = _read('lib/screens/room_screen.dart');
      expect(src, contains('_musicDuckedVolume = 0.05'));
      // _applySharedDucking still guards on a shared session.
      final idx = src.indexOf('Future<void> _applySharedDucking()');
      expect(idx, isNot(-1));
      final end = src.indexOf('\n  }', idx);
      final body = src.substring(idx, end);
      expect(body, contains('if (_sharedSession == null'));
    });
  });

  group('DIRECT application — no fades at all (FIX 22 item 11)', () {
    test('no fade machinery remains anywhere in the room', () {
      final src = _read('lib/screens/room_screen.dart');
      expect(src, isNot(contains('_runMusicFade')));
      expect(src, isNot(contains('_musicFadeGen')));
      expect(src, isNot(contains('_musicFadeDownDuration')));
      expect(src, isNot(contains('_musicFadeUpDuration')));
      expect(src, isNot(contains('_musicCurrentVolume')));
      expect(src, isNot(contains('_musicFadeDuration = Duration')));
      // The smoothstep formula itself is gone (the word
      // 'smoothstep' survives only in the deletion comments).
      expect(src, isNot(contains('f * f * (3 - 2 * f)')));
    });

    test('_applyMusicVolume sets the target in ONE setVolume call', () {
      final src = _read('lib/screens/room_screen.dart');
      final idx = src.indexOf('Future<void> _applyMusicVolume()');
      expect(idx, isNot(-1));
      final end = src.indexOf('\n  }', idx);
      final body = src.substring(idx, end);
      // Direct: compute the target, set it once, return. No ramp,
      // no loop, no generation, no duration selection.
      expect(body, contains('setVolume(target)'));
      expect('setVolume('.allMatches(body).length, 1);
      expect(body, isNot(contains('Duration')));
      // FIX 24 — SINGLE MECHANISM: the ducking math here is
      // activity ONLY (the 5% RJ bed). The fader factor
      // (micFaderDuckFactor) is gone from _applyMusicVolume — it
      // squared the inverse link's response. The link is the only
      // mic/music mechanism now.
      expect(body, isNot(contains('micFaderDuckFactor')));
      expect(body, contains('musicTargetVolume'));
    });

    test('ducking is instant too: mic toggle re-applies volume at once', () {
      // Item 10's trigger survives item 11 (now direct): the
      // mute-change listeners call _reapplyMusicVolumeForMicToggle
      // instead of waiting for a poll or a fade.
      final src = _read('lib/screens/room_screen.dart');
      expect(src, contains('void _reapplyMusicVolumeForMicToggle()'));
      expect('_reapplyMusicVolumeForMicToggle();'.allMatches(src).length,
          greaterThanOrEqualTo(2));
    });

    test('no fade-duration constants remain', () {
      final src = _read('lib/screens/room_screen.dart');
      expect(
        RegExp(r'_musicFade\w*Duration').hasMatch(src),
        isFalse,
      );
    });
  });
}
