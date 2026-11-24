// FIX 22 items 9 + 10 + 11 — volume: direct application, the
// inverse mic/music link, and the mic-toggle duck trigger.
// Item 11 SUPERSEDES item 9's instant-only path and item 10's
// 350ms duck ramp: there are NO fades anywhere anymore.

import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/screens/room_screen.dart';

import 'audio_test_helpers.dart';

String _region(String src, String start, String end) {
  final s = src.indexOf(start);
  if (s < 0) return '';
  final e = src.indexOf(end, s + start.length);
  if (e < 0) return '';
  return src.substring(s, e);
}

void main() {
  group('fix22 item 10 — mic-fader duck level', () {
    test('MIC fader 0.8 ducks music to 24%', () {
      expect(
        micFaderDuckFactor(micFader: 0.8, micOn: true),
        closeTo(0.24, 0.001),
      );
    });

    test('mic off = no duck', () {
      expect(
        micFaderDuckFactor(micFader: 0.8, micOn: false),
        closeTo(1.0, 0.001),
      );
    });

    test('fallback mode still ducks (fader applies in every mode)', () {
      // Fallback: no shared session, so activityFactor is 1.0 and
      // only the fader factor applies.
      expect(
        musicTargetVolume(
          base: 1.0,
          sharedSession: false,
          activityFactor: 1.0,
          faderFactor: micFaderDuckFactor(micFader: 0.8, micOn: true),
        ),
        closeTo(0.24, 0.001),
      );
    });

    test('mic off restores full volume', () {
      expect(
        musicTargetVolume(
          base: 1.0,
          sharedSession: false,
          activityFactor: 1.0,
          faderFactor: micFaderDuckFactor(micFader: 0.8, micOn: false),
        ),
        closeTo(1.0, 0.001),
      );
    });

    test('shared + activity ducking drops to 1.2%', () {
      expect(
        musicTargetVolume(
          base: 1.0,
          sharedSession: true,
          activityFactor: 0.05,
          faderFactor: micFaderDuckFactor(micFader: 0.8, micOn: true),
        ),
        closeTo(0.012, 0.001),
      );
    });
  });

  group('fix22 item 11 — inverse mic/music link', () {
    test('music +0.1 -> mic -0.1', () {
      final next = inverseLinkNudge(
        mic: 0.8,
        music: 0.5,
        delta: 0.1,
        musicMoved: true,
      );
      expect(next.music, closeTo(0.6, 0.001));
      expect(next.mic, closeTo(0.7, 0.001));
    });

    test('mic +0.1 -> music -0.1', () {
      final next = inverseLinkNudge(
        mic: 0.8,
        music: 0.5,
        delta: 0.1,
        musicMoved: false,
      );
      expect(next.mic, closeTo(0.9, 0.001));
      expect(next.music, closeTo(0.4, 0.001));
    });

    test('mic down -> music up', () {
      final next = inverseLinkNudge(
        mic: 0.8,
        music: 0.5,
        delta: -0.1,
        musicMoved: false,
      );
      expect(next.mic, closeTo(0.7, 0.001));
      expect(next.music, closeTo(0.6, 0.001));
    });

    test('clamped at 0 and 1', () {
      final top = inverseLinkNudge(
        mic: 0.95,
        music: 0.05,
        delta: 0.1,
        musicMoved: false,
      );
      expect(top.mic, closeTo(1.0, 0.001));
      expect(top.music, closeTo(0.0, 0.001));
      final bottom = inverseLinkNudge(
        mic: 0.05,
        music: 0.95,
        delta: 0.1,
        musicMoved: true,
      );
      expect(bottom.music, closeTo(1.0, 0.001));
      expect(bottom.mic, closeTo(0.0, 0.001));
    });

    test('two sequential gestures settle, no oscillation', () {
      var mic = 0.8;
      var music = 0.5;
      final first = inverseLinkNudge(
        mic: mic,
        music: music,
        delta: 0.1,
        musicMoved: true,
      );
      mic = first.mic;
      music = first.music;
      final second = inverseLinkNudge(
        mic: mic,
        music: music,
        delta: 0.1,
        musicMoved: false,
      );
      // Mic back up by 0.1 restores the original pair exactly.
      expect(second.mic, closeTo(0.8, 0.001));
      expect(second.music, closeTo(0.5, 0.001));
    });
  });

  group('fix22 item 11 — direct application, no fades', () {
    late String room;

    setUpAll(() {
      room = codeOnly(requireProjectFile('lib/screens/room_screen.dart'));
    });

    test('_applyMusicVolume has no instant param, one setVolume', () {
      final vol = _region(
        room,
        'Future<void> _applyMusicVolume()',
        'Future<void> _onUserMusicVolume(',
      );
      expect(vol, isNotEmpty);
      expect(vol, isNot(contains('instant')));
      expect('setVolume('.allMatches(vol).length, 1);
      expect(vol, contains('await _musicPlayer!.setVolume(target);'));
    });

    test('no fade machinery remains anywhere in the room', () {
      expect(room, isNot(contains('_runMusicFade')));
      expect(room, isNot(contains('_musicFadeGen')));
      expect(room, isNot(contains('_musicFadeDownDuration')));
      expect(room, isNot(contains('_musicFadeUpDuration')));
      expect(room, isNot(contains('setVolume(v)')));
    });

    test('link handlers exist and drive the gesture sites', () {
      expect(room, contains('Future<void> _onUserMusicVolume('));
      expect(room, contains('Future<void> _onUserMicLevel('));
      // FIX 24: the handlers route through faderGestureNext (the
      // link-gated rule — link ON = inverseLinkNudge, link OFF =
      // manual). 2 inverseLinkNudge matches = 1 definition + the
      // call inside faderGestureNext; 3 faderGestureNext matches
      // = 1 definition + 2 handler call sites.
      expect('inverseLinkNudge('.allMatches(room).length, 2);
      expect('faderGestureNext('.allMatches(room).length, 3);
    });

    test('mic-toggle re-apply runs from both listeners', () {
      expect('_reapplyMusicVolumeForMicToggle();'.allMatches(room).length,
          2);
    });

    test('host mic buttons re-apply volume right after setMuted', () {
      final toggle = _region(
        room,
        'Future<void> _toggleOwnSeat()',
        'Widget _buildHostStrip(',
      );
      // Both engine paths (LiveKit + mesh) re-apply after setMuted.
      expect('_applyMusicVolume();'.allMatches(toggle).length, 2);
    });

    test('RJ panel carries mic/music volume props + sync', () {
      final panel =
          codeOnly(requireProjectFile('lib/widgets/rj_studio_panel.dart'));
      expect(panel, contains('final double micVolume;'));
      expect(panel, contains('final double musicVolume;'));
      expect(panel, contains('didUpdateWidget'));
    });

    test('player has the mic stepper (0.1 step, % display)', () {
      final player =
          codeOnly(requireProjectFile('lib/widgets/music_player_panel.dart'));
      expect(player, contains('_buildMicStepper()'));
      expect(player, contains('onMicLevelChanged'));
      expect(player, contains("'\${(mic * 100).round()}%'"));
    });
  });
}
