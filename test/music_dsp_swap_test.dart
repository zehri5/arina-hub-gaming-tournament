// MUSIC DSP PLAYER SWAP TESTS — GROUP 1 TRANSPORT ONLY (2026-11-22,
// Sameer's order: the swap lands IN the v2018 build).
//
// The music path swaps from audioplayers to the Group 8
// MusicDspPlayer (decode -> DSP -> AudioTrack). THIS FILE IS
// TRANSPORT ONLY: play/pause/resume/stop/seek, position/duration
// streams, repeat (mount-side loop), prev/next wiring, replay
// after completion, volume + ducking. Group 2 owns the effects
// re-attach (_fx knobs -> the DSP chain) and tests it separately.
//
// Two halves:
//   (a) mount wiring pins — room_screen.dart source: the player is a
//       MusicDspPlayer, no audioplayers transport API remains, loop
//       is mount-side via completedStream, ducking still drives
//       setVolume with the 5% bed.
//   (b) player behaviour — MusicDspPlayer against mocked channels
//       (same pattern as test/music_dsp_player_test.dart): pump
//       order, completedStream, play-after-completion rewind,
//       seek/pause/resume/stop, setVolume.
//
// What this CANNOT prove (phone-only): real MediaCodec decode,
// audible output, loop timing on a real device, latency / underrun
// behaviour, speaker routing + audio focus (the plugin has no focus
// handling — deliberate scope).
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/audio/music_dsp_player.dart';

import 'audio_test_helpers.dart';

const MethodChannel _musicChannel =
    MethodChannel('com.arenahub.app/music_dsp');
const MethodChannel _dspChannel = MethodChannel('com.arenahub.app/audio_dsp');
const MethodChannel _eventChannel =
    MethodChannel('com.arenahub.app/music_dsp_events');

/// Ordered log across both mocked channels, so pump ordering
/// (nextChunk -> dsp.process -> writeChunk) can be asserted.
class _SwapCallLog {
  final List<String> order = <String>[];
  final List<MethodCall> musicCalls = <MethodCall>[];
  final List<MethodCall> dspCalls = <MethodCall>[];

  List<MethodCall> musicNamed(String method) =>
      musicCalls.where((c) => c.method == method).toList();

  List<MethodCall> dspNamed(String method) =>
      dspCalls.where((c) => c.method == method).toList();

  static Map<String, dynamic> argsOf(MethodCall call) =>
      Map<String, dynamic>.from(call.arguments as Map);
}

class _SwapFakeMusic {
  _SwapFakeMusic(this.log);

  final _SwapCallLog log;

  final List<Uint8List?> nextChunkScript = <Uint8List?>[];
  bool writeChunkResult = true;
  int loadDurationMs = 180000;

  Future<dynamic> handler(MethodCall call) async {
    log.musicCalls.add(call);
    log.order.add('music:${call.method}');
    switch (call.method) {
      case 'load':
        return <String, Object>{'durationMs': loadDurationMs};
      case 'seek':
        final args = _SwapCallLog.argsOf(call);
        return args['positionMs'] as int;
      case 'nextChunk':
        await Future<void>.delayed(const Duration(milliseconds: 1));
        if (nextChunkScript.isNotEmpty) {
          return nextChunkScript.removeAt(0);
        }
        return null;
      case 'writeChunk':
        return writeChunkResult;
      default:
        return null;
    }
  }
}

class _SwapFakeDsp {
  _SwapFakeDsp(this.log);

  final _SwapCallLog log;

  /// process() returns each input byte + 1 (mod 256), so tests can
  /// prove writeChunk received the PROCESSED bytes, not the raw ones.
  Future<dynamic> handler(MethodCall call) async {
    log.dspCalls.add(call);
    log.order.add('dsp:${call.method}');
    switch (call.method) {
      case 'create':
        return 42;
      case 'process':
        final args = _SwapCallLog.argsOf(call);
        final Uint8List input = args['pcmBytes'] as Uint8List;
        return Uint8List.fromList(
          input.map((b) => (b + 1) & 0xFF).toList(),
        );
      default:
        return null;
    }
  }
}

/// Injects one native event into the player's EventChannel stream.
Future<void> _emitNativeEvent(Map<String, Object> event) async {
  final ByteData data =
      const StandardMethodCodec().encodeSuccessEnvelope(event);
  await TestDefaultBinaryMessengerBinding
      .instance.defaultBinaryMessenger
      .handlePlatformMessage(
    'com.arenahub.app/music_dsp_events',
    data,
    (ByteData? reply) {},
  );
}

/// Polls until [condition] holds (pump-loop work is unawaited async).
Future<void> _waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
  String description = 'condition',
}) async {
  final stopwatch = Stopwatch()..start();
  while (!condition()) {
    if (stopwatch.elapsed > timeout) {
      throw StateError('Timed out waiting for $description');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// Region of [src] from [startMarker] (inclusive) to [endMarker]
/// (exclusive); empty string when either marker is missing.
String _region(String src, String startMarker, String endMarker) {
  final start = src.indexOf(startMarker);
  if (start < 0) return '';
  final end = src.indexOf(endMarker, start + startMarker.length);
  if (end < 0) return '';
  return src.substring(start, end);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('swap — mount wiring (room_screen source pins)', () {
    late String room;

    setUpAll(() {
      room = codeOnly(requireProjectFile('lib/screens/room_screen.dart'));
    });

    test('the music player is a MusicDspPlayer, not an AudioPlayer',
        () {
      expect(room, contains('MusicDspPlayer? _musicPlayer;'));
      expect(room, contains("import '../audio/music_dsp_player.dart';"));
      expect(room, isNot(contains('AudioPlayer? _musicPlayer;')));
    });

    test('no audioplayers TRANSPORT API remains in the mount', () {
      // NOTE: attachToPlayer / _ensureAudioEffects are NOT banned
      // here — Group 2 owns the effects re-attach and the effects
      // instances still live on the mount (session-0, as before).
      for (final banned in [
        'AudioPlayer(',
        'ReleaseMode.',
        'DeviceFileSource(',
        'UrlSource(',
        'BytesSource(',
        'onPositionChanged',
        'onDurationChanged',
        'setAudioContext',
        'AudioContextConfig',
      ]) {
        expect(room, isNot(contains(banned)),
            reason: 'audioplayers remnant in room_screen: $banned');
      }
    });

    test('one load+play entry: load(path) then play(), returns duration',
        () {
      final helper = _region(
        room,
        'Future<Duration> _playMusicSource(String path)',
        'Future<void> _applyMusicVolume()',
      );
      expect(helper, isNotEmpty);
      expect(helper, contains('await player.load(path);'));
      expect(helper, contains('await player.play();'));
      expect(helper, contains('return duration;'));
      // Every play site goes through the helper (tone, local file,
      // upload/share, broadcast path + URL, library URL, speaker
      // fallback, listener = 8 call sites + the definition).
      expect('_playMusicSource('.allMatches(room).length,
          greaterThanOrEqualTo(8));
    });

    test('sheet transport uses the new player streams, no release mode',
        () {
      // FIX 22 item 21: the standalone player sheet
      // (_showMusicPlayer) is RETIRED — the player section now
      // lives inside the RJ console (_buildConsoleMusicSection).
      // The transport pins are unchanged, just re-homed.
      final sheet = _region(
        room,
        'Widget _buildConsoleMusicSection(',
        'String? _rjGuestUid() {',
      );
      expect(sheet, isNotEmpty);
      expect(sheet, contains('stream: _musicPlayer!.positionStream'));
      expect(sheet, contains('stream: _musicPlayer!.durationStream'));
      expect(sheet, contains('await _musicPlayer!.seek(d);'));
      // Loop is mount-side: no release mode in the sheet.
      expect(sheet, isNot(contains('setReleaseMode')));
      // Transport helpers, not local stubs.
      expect(sheet, contains('await _pauseResumeMusic();'));
      expect(sheet, contains('await _playPrevNext(-1);'));
      expect(sheet, contains('await _playPrevNext(1);'));
      expect(sheet, contains('await _stopMusic();'));
    });

    test('loop is mount-side via completedStream', () {
      final ensure = _region(
        room,
        'Future<MusicDspPlayer> _ensureMusicPlayer()',
        'Future<Duration> _playMusicSource(String path)',
      );
      expect(ensure, isNotEmpty);
      expect(ensure, contains('_musicPlayer!.completedStream.listen'));
      expect(ensure, contains('if (!mounted || !_musicRepeat'));
      expect(ensure, contains('await _musicPlayer!.play();'));
      expect(ensure, contains('_musicPlayer!.durationStream.listen'));
    });

    test('ducking still drives setVolume with the 5% bed', () {
      final vol = _region(
        room,
        'Future<void> _applyMusicVolume()',
        'Future<void> _onUserMusicVolume(',
      );
      expect(vol, isNotEmpty);
      // FIX 20 (fix 11 + defect fix): the target formula lives in
      // the pure musicTargetVolume (unit-tested in
      // fix20_community_voice_test.dart) — the activity factor is
      // STILL the 5% bed when any mic is unmuted and speaking,
      // and the fader factor now applies in EVERY mode (shared,
      // local, fallback), not just shared.
      expect(vol, contains('final activityFactor = _sharedDucked ? _musicDuckedVolume : 1.0;'));
      expect(vol, contains('musicTargetVolume('));
      expect(vol, contains('sharedSession: _sharedSession != null,'));
      expect(room, contains('base * activityFactor * faderFactor'));
      expect(room, contains(': base * faderFactor;'));
      expect(vol, contains('await _musicPlayer!.setVolume(target);'));
      expect(room, contains('static const double _musicDuckedVolume = 0.05;'));
      // FIX 22 item 11 SUPERSEDES the FM fade: _applyMusicVolume
      // is DIRECT always — one setVolume(target), no ramp. The
      // fade path (_runMusicFade, _musicFadeGen, the 350/1400
      // durations) is DELETED, so ducking applies instantly.
      expect(room, isNot(contains('_runMusicFade')));
      expect(room, isNot(contains('_musicFadeGen')));
      expect(room, isNot(contains('_musicFadeDownDuration')));
      expect(room, isNot(contains('_musicFadeUpDuration')));
      expect(room, isNot(contains('setVolume(v)')));
    });

    test('tones go through a temp file (no bytes API on the player)',
        () {
      final tone = _region(
        room,
        'Future<void> _playTone(String name',
        'void _reapplyVoiceRoute()',
      );
      expect(tone, isNotEmpty);
      expect(tone, contains('arena_tone.wav'));
      expect(tone, contains('writeAsBytes(_toneWav('));
      expect(tone, contains('await _playMusicSource(toneFile.path);'));
    });

    test('listener seek uses the load duration (no 8 s wait)', () {
      final listen = _region(
        room,
        'Future<void> _startListeningSession(',
        'Future<void> _handleMusicRows(',
      );
      expect(listen, isNotEmpty);
      expect(listen, contains('final dur = await _playMusicSource(url);'));
      expect(listen, contains('elapsed % dur.inMilliseconds'));
      expect(listen, isNot(contains('onDurationChanged.first')));
      expect(listen, isNot(contains('Duration(seconds: 8)')));
    });

    test('voice chain untouched: RJ console + gate/compressor stay',
        () {
      expect(room, contains('final dsp = _rjLiveDsp();'));
      expect(room, contains('await dsp.setNoiseGate('));
      expect(room, contains('await dsp.setCompressor('));
      expect(room, contains('RjStudioPanel('));
    });
  });

  group('swap — player behaviour (mocked channels)', () {
    late _SwapCallLog log;
    late _SwapFakeMusic music;
    late _SwapFakeDsp fakeDsp;
    final List<MusicDspPlayer> players = <MusicDspPlayer>[];

    setUp(() {
      log = _SwapCallLog();
      music = _SwapFakeMusic(log);
      fakeDsp = _SwapFakeDsp(log);
      final messenger = TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(_musicChannel, music.handler);
      messenger.setMockMethodCallHandler(_dspChannel, fakeDsp.handler);
      messenger.setMockMethodCallHandler(_eventChannel, (call) async => null);
    });

    tearDown(() async {
      for (final player in players) {
        try {
          await player.dispose();
        } catch (_) {
          // Best-effort cleanup; the test already asserted behaviour.
        }
      }
      players.clear();
      final messenger = TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(_musicChannel, null);
      messenger.setMockMethodCallHandler(_dspChannel, null);
      messenger.setMockMethodCallHandler(_eventChannel, null);
    });

    MusicDspPlayer newPlayer() {
      final player = MusicDspPlayer();
      players.add(player);
      return player;
    }

    Future<MusicDspPlayer> loadedPlayer() async {
      final player = newPlayer();
      await player.load('/music/song.mp3');
      return player;
    }

    test('completedStream emits on the native completed event', () async {
      final player = await loadedPlayer();
      await player.play();
      var completedCount = 0;
      player.completedStream.listen((_) => completedCount++);

      await _emitNativeEvent(<String, Object>{'type': 'completed'});
      await _waitFor(() => completedCount == 1,
          description: 'completed emission');
      expect(player.isPlaying, isFalse);
    });

    test('play() after completion seeks to 0 first, then starts',
        () async {
      final player = await loadedPlayer();
      await player.play();
      await _emitNativeEvent(<String, Object>{'type': 'completed'});
      await _waitFor(() => player.isPlaying == false,
          description: 'player stops on completion');
      log.musicCalls.clear();
      log.order.clear();

      await player.play();

      final seeks = log.musicNamed('seek');
      expect(seeks, hasLength(1));
      expect(_SwapCallLog.argsOf(seeks.single), {'positionMs': 0});
      final starts = log.musicNamed('start');
      expect(starts, hasLength(1));
      // Seek precedes start in the ordered log.
      expect(
        log.order.indexOf('music:seek'),
        lessThan(log.order.indexOf('music:start')),
      );
      expect(player.isPlaying, isTrue);
    });

    test('pump order: nextChunk -> dsp.process -> writeChunk (processed)',
        () async {
      music.nextChunkScript.addAll([
        Uint8List.fromList([10, 20, 30, 40]),
        null, // EOS
      ]);
      final player = await loadedPlayer();
      await player.play();

      await _waitFor(
        () => log.musicNamed('finishStream').isNotEmpty,
        description: 'pump reaching EOS',
      );

      final order = log.order;
      expect(order.indexOf('music:nextChunk'),
          lessThan(order.indexOf('dsp:process')));
      expect(order.indexOf('dsp:process'),
          lessThan(order.indexOf('music:writeChunk')));
      // writeChunk got the PROCESSED bytes (each byte + 1).
      final writes = log.musicNamed('writeChunk');
      expect(writes, hasLength(1));
      final written =
          _SwapCallLog.argsOf(writes.single)['pcmBytes'] as Uint8List;
      expect(written, Uint8List.fromList([11, 21, 31, 41]));
      expect(log.musicNamed('finishStream'), hasLength(1));
    });

    test('seek/pause/resume/stop go through the new player', () async {
      final player = await loadedPlayer();
      await player.play();
      expect(player.isPlaying, isTrue);

      await player.pause();
      expect(player.isPlaying, isFalse);
      expect(log.musicNamed('pause'), hasLength(1));

      await player.resume();
      expect(player.isPlaying, isTrue);
      expect(log.musicNamed('resume'), hasLength(1));

      await player.seek(const Duration(seconds: 30));
      final seeks = log.musicNamed('seek');
      expect(seeks, hasLength(1));
      expect(_SwapCallLog.argsOf(seeks.single), {'positionMs': 30000});
      expect(player.position, const Duration(seconds: 30));

      await player.stop();
      expect(player.isPlaying, isFalse);
      expect(player.position, Duration.zero);
      expect(log.musicNamed('stop'), hasLength(2)); // load + explicit
    });

    test('setVolume sends the ducked 5% value to the native track',
        () async {
      final player = await loadedPlayer();
      await player.setVolume(0.05);
      expect(player.volume, 0.05);
      final vols = log.musicNamed('setVolume');
      expect(vols, hasLength(1));
      expect(_SwapCallLog.argsOf(vols.single), {'volume': 0.05});
    });
  });
}
