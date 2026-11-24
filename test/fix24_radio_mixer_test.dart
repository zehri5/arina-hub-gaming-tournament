// FIX 24 — RADIO MUSIC MIXER tests (2026-11-23).
//
// The host's background music mixed DIRECTLY into the live mic
// stream (native MusicMixProcessor on WebRTC's
// capturePostProcessing hook — Shoutcast/radio model). Unit tests
// for what CAN be tested on this VM:
//  - radioMixGains (pure mix-gain rule)
//  - faderGestureNext (the link-gated gesture rule)
//  - RadioMixer channel bridge (mocked MethodChannel, incl.
//    fail-open behaviour)
//  - source pins: publish quality, hold-track mute on both
//    engines, the single-mechanism volume path, GO LIVE / END
//    LIVE mixer hooks, the pump feed, MainActivity registration,
//    and the Kotlin mixer file.
//
// Kotlin/native audio CANNOT be unit-tested here — the phone-only
// proofs are listed in the fix24 report (two-phone test: host
// plays -> listener hears a clean mix; mic-off music keeps
// playing; speaker doubling check; Krisp interaction).
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/screens/room_screen.dart';
import 'package:protournament_user/services/radio_mixer.dart';

String _read(String path) => File(path).readAsStringSync();

String _region(String src, String start, String end) {
  final s = src.indexOf(start);
  if (s < 0) return '';
  final e = src.indexOf(end, s + start.length);
  if (e < 0) return '';
  return src.substring(s, e);
}

void main() {
  group('fix24 — radioMixGains (pure mix-gain rule)', () {
    test('mic off = mic gain 0, music untouched', () {
      final g = radioMixGains(
        micOn: false,
        micFader: 0.8,
        musicBase: 0.7,
        linkOn: true,
        guestSpeaking: false,
      );
      expect(g.mic, 0.0);
      expect(g.music, closeTo(0.7, 0.001));
    });

    test('mic on + link on = mic gain is the fader, music ducked', () {
      final g = radioMixGains(
        micOn: true,
        micFader: 0.8,
        musicBase: 0.7,
        linkOn: true,
        guestSpeaking: false,
      );
      expect(g.mic, closeTo(0.8, 0.001));
      // FIX 24 defect 2: host mic live = mix music ducked to the
      // RJ bed (0.7 * 0.05), not untouched.
      expect(g.music, closeTo(0.035, 0.001));
    });

    test('mic on + link off = mic gain 1.0 (fader be-asar), music ducked', () {
      final g = radioMixGains(
        micOn: true,
        micFader: 0.3,
        musicBase: 0.7,
        linkOn: false,
        guestSpeaking: false,
      );
      expect(g.mic, 1.0);
      // FIX 24 defect 2: the host-mic duck does not depend on the
      // link — mic ON ducks the music whatever the link says.
      expect(g.music, closeTo(0.035, 0.001));
    });

    test('mic on ducks the mix music to the RJ bed (state rule)', () {
      final g = radioMixGains(
        micOn: true,
        micFader: 0.8,
        musicBase: 1.0,
        linkOn: true,
        guestSpeaking: false,
      );
      expect(g.music, closeTo(0.05, 0.001));
      expect(g.mic, closeTo(0.8, 0.001));
    });

    test('checker bad state: music raised while mic off, then mic on ducks it', () {
      // Music raised to 0.9 while the mic is OFF: full manual
      // level, as the user set it.
      final off = radioMixGains(
        micOn: false,
        micFader: 0.8,
        musicBase: 0.9,
        linkOn: true,
        guestSpeaking: false,
      );
      expect(off.music, closeTo(0.9, 0.001));
      // Same base, mic flipped ON: the music must duck to the bed
      // — no reachable state has a quiet voice under loud music.
      final on = radioMixGains(
        micOn: true,
        micFader: 0.8,
        musicBase: 0.9,
        linkOn: true,
        guestSpeaking: false,
      );
      expect(on.music, closeTo(0.045, 0.001));
      expect(on.mic, closeTo(0.8, 0.001));
    });

    test('guest speaking ducks the music to the RJ bed', () {
      final g = radioMixGains(
        micOn: true,
        micFader: 0.8,
        musicBase: 1.0,
        linkOn: true,
        guestSpeaking: true,
      );
      expect(g.music, closeTo(0.05, 0.001));
      expect(g.mic, closeTo(0.8, 0.001));
    });

    test('guest bed multiplies the music base, not replaces it', () {
      final g = radioMixGains(
        micOn: true,
        micFader: 0.8,
        musicBase: 0.5,
        linkOn: true,
        guestSpeaking: true,
      );
      expect(g.music, closeTo(0.025, 0.001));
    });

    test('mic off + guest speaking: mic 0, music ducked', () {
      final g = radioMixGains(
        micOn: false,
        micFader: 0.8,
        musicBase: 1.0,
        linkOn: true,
        guestSpeaking: true,
      );
      expect(g.mic, 0.0);
      expect(g.music, closeTo(0.05, 0.001));
    });

    test('inputs clamp to 0..1', () {
      final g = radioMixGains(
        micOn: true,
        micFader: 1.5,
        musicBase: -0.5,
        linkOn: true,
        guestSpeaking: false,
      );
      expect(g.mic, 1.0);
      expect(g.music, 0.0);
    });
  });

  group('fix24 — faderGestureNext (link-gated gesture rule)', () {
    test('link on = the inverse link (music +0.1 -> mic -0.1)', () {
      final next = faderGestureNext(
        mic: 0.8,
        music: 0.5,
        delta: 0.1,
        musicMoved: true,
        linkOn: true,
      );
      expect(next.music, closeTo(0.6, 0.001));
      expect(next.mic, closeTo(0.7, 0.001));
    });

    test('link on = the inverse link (mic +0.1 -> music -0.1)', () {
      final next = faderGestureNext(
        mic: 0.8,
        music: 0.5,
        delta: 0.1,
        musicMoved: false,
        linkOn: true,
      );
      expect(next.mic, closeTo(0.9, 0.001));
      expect(next.music, closeTo(0.4, 0.001));
    });

    test('link off + music moved = only music changes', () {
      final next = faderGestureNext(
        mic: 0.8,
        music: 0.5,
        delta: 0.1,
        musicMoved: true,
        linkOn: false,
      );
      expect(next.music, closeTo(0.6, 0.001));
      expect(next.mic, closeTo(0.8, 0.001));
    });

    test('link off + mic moved = only mic changes', () {
      final next = faderGestureNext(
        mic: 0.8,
        music: 0.5,
        delta: 0.1,
        musicMoved: false,
        linkOn: false,
      );
      expect(next.mic, closeTo(0.9, 0.001));
      expect(next.music, closeTo(0.5, 0.001));
    });

    test('link off clamps the moved control', () {
      final next = faderGestureNext(
        mic: 0.8,
        music: 0.95,
        delta: 0.2,
        musicMoved: true,
        linkOn: false,
      );
      expect(next.music, 1.0);
      expect(next.mic, closeTo(0.8, 0.001));
    });
  });

  group('fix24 — RadioMixer channel bridge (mocked)', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    const channel = MethodChannel('arena_hub_radio_mixer');
    late List<MethodCall> calls;
    bool registerAnswer = true;
    bool throwOnAll = false;

    Future<dynamic> handler(MethodCall call) async {
      calls.add(call);
      if (throwOnAll) throw PlatformException(code: 'MOCK_FAIL');
      switch (call.method) {
        case 'isAvailable':
          return true;
        case 'register':
          return registerAnswer;
        case 'unregister':
        case 'pushChunk':
        case 'flush':
        case 'setGains':
          return null;
        case 'framesMixed':
          return 1234;
        case 'bufferedMs':
          return 240;
        case 'diagnostics':
          return <String, Object>{
            'framesMixed': 1234,
            'layout': 'float32',
            'lastBands': 1,
          };
        default:
          return null;
      }
    }

    setUp(() {
      calls = <MethodCall>[];
      registerAnswer = true;
      throwOnAll = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, handler);
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('register passes the track id and returns the answer', () async {
      final mixer = RadioMixer();
      expect(await mixer.register(trackId: 'track-1'), isTrue);
      expect(calls.length, 1);
      expect(calls.single.method, 'register');
      expect(calls.single.arguments, {'trackId': 'track-1'});
    });

    test('register without a track id sends no arguments', () async {
      final mixer = RadioMixer();
      expect(await mixer.register(), isTrue);
      expect(calls.single.method, 'register');
      expect(calls.single.arguments, isNull);
    });

    test('register false propagates (the room falls back)', () async {
      registerAnswer = false;
      final mixer = RadioMixer();
      expect(await mixer.register(trackId: 't'), isFalse);
    });

    test('setGains sends music + mic in ONE call', () async {
      final mixer = RadioMixer();
      await mixer.setGains(music: 0.5, mic: 0.8);
      expect(calls.length, 1);
      expect(calls.single.method, 'setGains');
      expect(calls.single.arguments, {'music': 0.5, 'mic': 0.8});
    });

    test('setGains clamps to 0..1', () async {
      final mixer = RadioMixer();
      await mixer.setGains(music: 1.5, mic: -0.5);
      expect(calls.single.arguments, {'music': 1.0, 'mic': 0.0});
    });

    test('pushChunk sends the raw bytes', () async {
      final mixer = RadioMixer();
      final bytes = Uint8List.fromList([1, 2, 3, 4]);
      mixer.pushChunk(bytes);
      // Fire-and-forget: let the mock handler run.
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(calls.any((c) => c.method == 'pushChunk'), isTrue);
      final call = calls.firstWhere((c) => c.method == 'pushChunk');
      expect(call.arguments, bytes);
    });

    test('pushChunk ignores empty chunks', () async {
      final mixer = RadioMixer();
      mixer.pushChunk(Uint8List(0));
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(calls, isEmpty);
    });

    test('unregister + flush + diagnostics round-trip', () async {
      final mixer = RadioMixer();
      await mixer.unregister();
      await mixer.flush();
      expect(await mixer.framesMixed(), 1234);
      expect(await mixer.bufferedMs(), 240);
      final diag = await mixer.diagnostics();
      expect(diag['framesMixed'], 1234);
      expect(diag['layout'], 'float32');
      expect(diag['lastBands'], 1);
      expect(await mixer.isAvailable(), isTrue);
    });

    test('fail-open: every call survives a channel failure', () async {
      throwOnAll = true;
      final mixer = RadioMixer();
      expect(await mixer.isAvailable(), isFalse);
      expect(await mixer.register(trackId: 't'), isFalse);
      // These must not throw.
      await mixer.unregister();
      await mixer.flush();
      await mixer.setGains(music: 0.5, mic: 0.5);
      mixer.pushChunk(Uint8List.fromList([1]));
      expect(await mixer.framesMixed(), -1);
      expect(await mixer.bufferedMs(), -1);
      expect(await mixer.diagnostics(), isEmpty);
    });
  });

  group('fix24 — source pins (wiring)', () {
    late String room;
    late String lk;
    late String mesh;
    late String player;
    late String mainActivity;
    late String mixerKt;
    late String panel;

    setUpAll(() {
      room = _read('lib/screens/room_screen.dart');
      lk = _read('lib/services/livekit_voice_service.dart');
      mesh = _read('lib/services/voice_service.dart');
      player = _read('lib/audio/music_dsp_player.dart');
      mainActivity = _read(
          'android/app/src/main/kotlin/com/protournament/app/MainActivity.kt');
      mixerKt = _read(
          'android/app/src/main/kotlin/com/protournament/app/MusicMixProcessor.kt');
      panel = _read('lib/widgets/rj_studio_panel.dart');
    });

    test('LiveKit publishes the mic at music quality (96k, no DTX)', () {
      expect(lk, contains('presetMusicHighQuality'));
      expect(lk, contains('dtx: false'));
      expect(lk, contains('defaultAudioPublishOptions'));
      // The test seam is untouched — injected rooms keep their own
      // options (the RoomOptions line is only in the production
      // branch, not the roomFactory branch).
      final connect = _region(lk, 'Future<void> connect(', '_listener!');
      expect(connect, contains('roomFactory != null'));
      expect(connect, contains('lk.Room('));
    });

    test('both engines hold the mic track while muted (gain-zero)', () {
      for (final src in [lk, mesh]) {
        expect(src, contains('holdMicTrackWhileMuted'));
        expect(src, contains('_micTrackHeld'));
        expect(src, contains('micTrackHeld'));
        expect(src, contains('ensureMicTrackEnabled'));
        expect(src, contains('localMicTrackId'));
      }
      // LiveKit: the hold skips setMicrophoneEnabled(false).
      expect(lk, contains('holdMicTrackWhileMuted && _room != null'));
      // Mesh: the hold skips t.enabled = false.
      expect(mesh, contains('muted && holdMicTrackWhileMuted'));
    });

    test('single mechanism: _applyMusicVolume has faderFactor 1.0', () {
      final apply = _region(room, 'Future<void> _applyMusicVolume()',
          'Future<void> _onUserMusicVolume(');
      expect(apply, isNotEmpty);
      expect(apply, contains('const faderFactor = 1.0;'));
      expect(apply, isNot(contains('micFaderDuckFactor(')));
      expect(apply, contains('musicTargetVolume('));
      expect(apply, contains('setVolume(target)'));
    });

    test('gesture handlers gate on the link + fire-and-forget', () {
      final music = _region(room, 'Future<void> _onUserMusicVolume(',
          'Future<void> _onUserMicLevel(');
      final mic = _region(
          room, 'Future<void> _onUserMicLevel(', '// DEMO TRACKS REMOVED');
      for (final h in [music, mic]) {
        expect(h, isNotEmpty);
        expect(h, contains('faderGestureNext('));
        expect(h, contains('linkOn: _rjMicLinkOn'));
        expect(h, contains('unawaited(_applyMusicVolume());'));
        expect(h, contains('_pushMixerGains();'));
        expect(h, isNot(contains('await _applyMusicVolume();')));
      }
    });

    test('GO LIVE registers the mixer, END LIVE unregisters it', () {
      expect(room, contains('_registerRadioMixer()'));
      expect(room, contains('_unregisterRadioMixer()'));
      // FIX 24 defect 1: the GO LIVE handler arms ONE path via
      // _goLiveBroadcast — it must NOT call the mixer register or
      // the upload arm directly (arming both played the song
      // twice, unsynchronised).
      final goLive = _region(room, '// FIX 24: GO LIVE registers the',
          'startLiveTicker(sheetCtx, sheetSetState);');
      expect(goLive, contains('unawaited(_goLiveBroadcast());'));
      expect(goLive, isNot(contains('_registerRadioMixer()')));
      expect(goLive, isNot(contains('_setBroadcast(true)')));
      final endLive = _region(room, '// FIX 24: END LIVE unhooks the',
          'liveTicker?.cancel();');
      expect(endLive, contains('_unregisterRadioMixer()'));
      expect(endLive, contains('unawaited(_setBroadcast(false));'));
      // Dispose unhooks too (restoreMute false — leave() disposes
      // the stream).
      final dispose = _region(room,
          '// FIX 24: leaving unhooks the radio mixer',
          'widget.voiceController?.unbind();');
      expect(dispose, contains('_unregisterRadioMixer(restoreMute: false)'));
    });

    test('GO LIVE fallback: upload broadcast ONLY when the mixer fails', () {
      // _goLiveBroadcast awaits the mixer registration and arms
      // the upload path only on failure — mixer live means NO
      // upload broadcast (no double music).
      final goLive = _region(room, 'Future<void> _goLiveBroadcast() async {',
          'Future<bool> _registerRadioMixer() async {');
      expect(goLive, isNotEmpty);
      expect(goLive, contains('await _registerRadioMixer()'));
      expect(goLive, contains('if (!mixerOk)'));
      expect(goLive, contains('await _setBroadcast(true);'));
      // The upload arm appears exactly once in the helper (the
      // only conditional arm in the file — the handler has none).
      expect(' _setBroadcast(true);'.allMatches(goLive).length, 1);
    });

    test('mixer registration holds the track + forces Krisp off', () {
      final reg = _region(room, 'Future<bool> _registerRadioMixer()',
          'Future<void> _unregisterRadioMixer(');
      expect(reg, isNotEmpty);
      expect(reg, contains('holdMicTrackWhileMuted = true'));
      expect(reg, contains('ensureMicTrackEnabled'));
      expect(reg, contains('_radioMixer.register(trackId: trackId)'));
      expect(reg, contains('MicProcessorKind.krisp'));
      expect(reg, contains('MicProcessorKind.rnnoise'));
      expect(reg, contains('_pushMixerGains();'));
      // Failure falls back with an honest toast (never silent).
      expect(reg, contains('Radio mix nahi lag saka'));
    });

    test('END LIVE restores a held mute to a real disable', () {
      final unreg = _region(room,
          'Future<void> _unregisterRadioMixer(', 'void _pushMixerGains()');
      expect(unreg, isNotEmpty);
      expect(unreg, contains('holdMicTrackWhileMuted = false'));
      expect(unreg, contains('_radioMixer.unregister()'));
      expect(unreg, contains('micTrackHeld'));
      expect(unreg, contains('await _lkRoom.setMuted(true);'));
      expect(unreg, contains('await _room.setMuted(true);'));
      // Krisp restore.
      expect(unreg, contains('_rjPreBroadcastKind'));
    });

    test('mic-toggle re-apply pushes the mixer gains', () {
      final reapply = _region(room,
          'void _reapplyMusicVolumeForMicToggle() {', 'Future<void> _applySharedDucking()');
      expect(reapply, isNotEmpty);
      expect(reapply, contains('_pushMixerGains();'));
    });

    test('console wires the mic button + call-in picker', () {
      expect(room, contains('micLinkOn: _rjMicLinkOn'));
      expect(room, contains('onMicLinkChanged:'));
      expect(room, contains('callInSeats: _rjCallInSeats()'));
      expect(room, contains('selectedCallInUid: _rjCallInGuestUid'));
      expect(room, contains('onCallInSelected:'));
    });

    test('pump feeds the mixer + flushes on reset', () {
      expect(player, contains('void Function(Uint8List chunk)? onProcessedChunk;'));
      expect(player, contains('void Function()? onPumpReset;'));
      expect(player, contains('feed(chunkToWrite);'));
      expect(player, contains('_notifyPumpReset();'));
      // The room attaches the feed in _ensureMusicPlayer.
      final ensure = _region(room, 'Future<MusicDspPlayer> _ensureMusicPlayer()',
          'Future<Duration> _playMusicSource(String path)');
      expect(ensure, contains('onProcessedChunk = (chunk) {'));
      expect(ensure, contains('_radioMixer.pushChunk(chunk);'));
      expect(ensure, contains('onPumpReset = () {'));
      expect(ensure, contains('_radioMixer.flush()'));
    });

    test('MainActivity registers the mixer channel', () {
      expect(mainActivity, contains('MusicMixProcessor.register('));
    });

    test('Kotlin mixer: APM hook + ring + gains + layout handling', () {
      expect(mixerKt, contains('capturePostProcessing.addProcessor'));
      expect(mixerKt, contains('capturePostProcessing'));
      expect(mixerKt, contains('ExternalAudioFrameProcessing'));
      expect(mixerKt, contains('"pushChunk"'));
      expect(mixerKt, contains('"setGains"'));
      expect(mixerKt, contains('"register"'));
      expect(mixerKt, contains('"unregister"'));
      expect(mixerKt, contains('"flush"'));
      expect(mixerKt, contains('"diagnostics"'));
      // Band-0 mix + both layouts + re-bind lesson.
      expect(mixerKt, contains('b == 0'));
      expect(mixerKt, contains('getFloat'));
      expect(mixerKt, contains('getShort'));
      expect(mixerKt, contains('boundMessenger'));
      expect(mixerKt, contains('onEngineRebound'));
      // No second track, no fork: no factory construction, no
      // peer-connection creation, no custom audio device module
      // here (the word PeerConnectionFactory appears only in the
      // isAvailable comment, explaining when the controller
      // exists — that is documentation, not a fork).
      expect(mixerKt, isNot(contains('createPeerConnection')));
      expect(mixerKt, isNot(contains('AudioDeviceModule(')));
      expect(mixerKt, isNot(contains('createAudioTrack')));
    });

    test('panel has the mic button + call-in section', () {
      expect(panel, contains('micLinkOn'));
      expect(panel, contains('onMicLinkChanged'));
      expect(panel, contains('callInSeats'));
      expect(panel, contains('onCallInSelected'));
      expect(panel, contains("Key('rj-mic-link-toggle')"));
      expect(panel, contains("Key('call-in-section')"));
      expect(panel, contains('_buildCallInSection()'));
    });
  });
}
