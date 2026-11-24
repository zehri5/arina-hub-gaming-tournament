// MUSIC DSP SWAP — MOUNT TESTS (Group 3, 2026-11-22).
//
// Verifies the MusicDspPlayer swap (audioplayers -> decode -> DSP ->
// AudioTrack) end to end, against mocked platform channels — no native
// code runs here. Group 1 owns the transport swap, Group 2 owns the
// _fx effects re-attach; this file pins the CONTRACT both groups must
// satisfy, plus the mount behaviour that must survive the swap.
//
// What is STABLE (mocked-channel tests against the MusicDspPlayer API
// + the AudioDsp wrapper — these identifiers do not change under the
// swap):
//   * pump order: nextChunk -> dsp.process -> writeChunk (PROCESSED
//     bytes), EOS -> finishStream;
//   * the player owns its own MUSIC DSP instance (private engine via
//     'create', NEVER the shared playback engine 'attachPlaybackEngine');
//   * pause keeps the pending chunk; resume continues it without a
//     fresh nextChunk;
//   * seek while paused does not restart the pump; stop mid-pump
//     resets DSP, zeroes position, pump exits;
//   * setVolume delivers the exact ducked value (5% bed);
//   * the mount-side replay recipe: completed -> seek(0) -> play
//     restarts the pump;
//   * the music DSP instance accepts effect setters (setReverb /
//     setEcho / setEq) through the audio_dsp channel.
//
// What is PINNED BY SOURCE (read from the CURRENT main tree — these
// pins are flagged where Group 1 / Group 2 will move them; Haaji
// reconciles at merge, see the FLAGGED PINS list at the end of this
// header):
//   * ducking: _musicDuckedVolume = 0.05, target via the pure
//     musicTargetVolume (shared = base x activity x fader,
//     local/fallback = base x fader — the ACTIVITY bed stays
//     shared-only, the fader factor applies in every mode),
//     fade 350 ms down / 1400 ms up — MUST NOT SHIFT.
//   * RECONCILED AT MERGE (2026-11-22, Group 1 landed):
//     _applyMusicVolume drives the DSP player's setVolume; repeat is
//     mount-side replay (completedStream -> re-play, player seeks 0).
//   * PRE-SWAP (Group 2 will move): the _fx handlers still drive the
//     session-0 effect tear-offs; the audioplayers attachToPlayer call
//     is already GONE (Group 1 removed it — type error vs the DSP
//     player). Group 2 re-attaches them to the music DSP setters.
//   * STABLE: the AudioDsp wrapper HAS setReverb / setEcho / setEq /
//     setNoiseGate / setCompressor + process.
//
// FLAGGED PINS — RECONCILED AT MERGE (2026-11-22):
//   F1. RECONCILED: play() after natural EOS now seeks 0 first
//       (Group 1 §5.1) — the test asserts the NEW behaviour.
//   F2. RECONCILED: _applyMusicVolume now drives the DSP player's
//       setVolume (MusicDspPlayer? _musicPlayer).
//   F3. RECONCILED: repeat is mount-side replay via completedStream
//       (no ReleaseMode anywhere in the mount).
//   F4. RECONCILED: Group 2 re-attached the _fx handlers to the
//       music DSP setters (MusicFx on _musicDsp() — the player's
//       own AudioDsp instance); the session-0 tear-offs are gone.
//
// What this CANNOT prove (phone-only): real MediaCodec decode,
// audible DSP effects on music, latency/underrun behaviour, audio
// focus / routing, and the Kotlin-side queue/generation races.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/audio/audio_dsp.dart';
import 'package:protournament_user/audio/music_dsp_player.dart';

const MethodChannel _musicChannel =
    MethodChannel('com.arenahub.app/music_dsp');
const MethodChannel _dspChannel = MethodChannel('com.arenahub.app/audio_dsp');
const MethodChannel _eventChannel =
    MethodChannel('com.arenahub.app/music_dsp_events');

String _read(String path) => File(path).readAsStringSync();

/// Shared ordered log across both mocked channels, so pump ordering
/// (nextChunk -> dsp.process -> writeChunk) can be asserted.
class _CallLog {
  final List<String> order = <String>[];
  final List<MethodCall> musicCalls = <MethodCall>[];
  final List<MethodCall> dspCalls = <MethodCall>[];

  void clear() {
    order.clear();
    musicCalls.clear();
    dspCalls.clear();
  }

  List<MethodCall> musicNamed(String method) =>
      musicCalls.where((c) => c.method == method).toList();

  List<MethodCall> dspNamed(String method) =>
      dspCalls.where((c) => c.method == method).toList();

  static Map<String, dynamic> argsOf(MethodCall call) =>
      Map<String, dynamic>.from(call.arguments as Map);
}

class _FakeMusicChannel {
  _FakeMusicChannel(this.log);

  final _CallLog log;

  /// Scripted nextChunk replies, consumed in order. When the queue is
  /// empty, nextChunk returns [repeatChunk] (null = end of stream).
  final List<Uint8List?> nextChunkScript = <Uint8List?>[];
  Uint8List? repeatChunk;

  /// Scripted writeChunk replies, consumed in order; when empty,
  /// [writeChunkResult] is used. Lets a test stage a backpressure
  /// rejection (false) followed by acceptance (true).
  final List<bool> writeChunkScript = <bool>[];
  bool writeChunkResult = true;
  int loadDurationMs = 180000;

  Future<dynamic> handler(MethodCall call) async {
    log.musicCalls.add(call);
    log.order.add('music:${call.method}');
    switch (call.method) {
      case 'load':
        return <String, Object>{'durationMs': loadDurationMs};
      case 'seek':
        final args = _CallLog.argsOf(call);
        return args['positionMs'] as int;
      case 'nextChunk':
        // Tiny delay paces the pump so repeat-mode tests log a
        // bounded number of iterations.
        await Future<void>.delayed(const Duration(milliseconds: 1));
        if (nextChunkScript.isNotEmpty) {
          return nextChunkScript.removeAt(0);
        }
        return repeatChunk;
      case 'writeChunk':
        if (writeChunkScript.isNotEmpty) {
          return writeChunkScript.removeAt(0);
        }
        return writeChunkResult;
      default:
        return null;
    }
  }
}

class _FakeDspChannel {
  _FakeDspChannel(this.log);

  final _CallLog log;

  int? createResult = 42;

  /// process() returns each input byte + 1 (mod 256), so tests can
  /// prove writeChunk received the PROCESSED bytes, not the raw ones.
  Future<dynamic> handler(MethodCall call) async {
    log.dspCalls.add(call);
    log.order.add('dsp:${call.method}');
    switch (call.method) {
      case 'create':
        return createResult;
      case 'process':
        final args = _CallLog.argsOf(call);
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _CallLog log;
  late _FakeMusicChannel music;
  late _FakeDspChannel dspChannel;
  final List<MusicDspPlayer> players = <MusicDspPlayer>[];

  setUp(() {
    log = _CallLog();
    music = _FakeMusicChannel(log);
    dspChannel = _FakeDspChannel(log);
    final messenger = TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_musicChannel, music.handler);
    messenger.setMockMethodCallHandler(_dspChannel, dspChannel.handler);
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

  MusicDspPlayer newPlayer({AudioDsp? dsp}) {
    final player = MusicDspPlayer(dsp: dsp);
    players.add(player);
    return player;
  }

  Future<MusicDspPlayer> loadedPlayer() async {
    final player = newPlayer();
    await player.load('/music/song.mp3');
    return player;
  }

  group('pump order (mount contract)', () {
    test('multi-chunk pump: every chunk goes nextChunk -> dsp.process '
        '-> writeChunk with PROCESSED bytes, EOS -> finishStream',
        () async {
      final player = await loadedPlayer();
      music.nextChunkScript.addAll(<Uint8List?>[
        Uint8List.fromList(<int>[1, 2, 3, 4]),
        Uint8List.fromList(<int>[5, 6]),
        Uint8List.fromList(<int>[7]),
        null, // EOS
      ]);
      log.clear();

      await player.play();
      await _waitFor(
        () => log.musicNamed('finishStream').isNotEmpty,
        description: 'finishStream',
      );

      final pumpSteps = log.order
          .where((e) =>
              e == 'music:nextChunk' ||
              e == 'dsp:process' ||
              e == 'music:writeChunk' ||
              e == 'music:finishStream')
          .toList();
      expect(pumpSteps, <String>[
        'music:nextChunk',
        'dsp:process',
        'music:writeChunk',
        'music:nextChunk',
        'dsp:process',
        'music:writeChunk',
        'music:nextChunk',
        'dsp:process',
        'music:writeChunk',
        'music:nextChunk',
        'music:finishStream',
      ]);

      // process() received each RAW chunk with the music handle...
      final processes = log.dspNamed('process');
      expect(processes, hasLength(3));
      expect(_CallLog.argsOf(processes[0]),
          {'handle': 42, 'pcmBytes': Uint8List.fromList(<int>[1, 2, 3, 4])});
      expect(_CallLog.argsOf(processes[1]),
          {'handle': 42, 'pcmBytes': Uint8List.fromList(<int>[5, 6])});
      expect(_CallLog.argsOf(processes[2]),
          {'handle': 42, 'pcmBytes': Uint8List.fromList(<int>[7])});
      // ...and writeChunk received the PROCESSED bytes (each byte + 1).
      final writes = log.musicNamed('writeChunk');
      expect(writes, hasLength(3));
      expect(_CallLog.argsOf(writes[0])['pcmBytes'],
          Uint8List.fromList(<int>[2, 3, 4, 5]));
      expect(_CallLog.argsOf(writes[1])['pcmBytes'],
          Uint8List.fromList(<int>[6, 7]));
      expect(_CallLog.argsOf(writes[2])['pcmBytes'],
          Uint8List.fromList(<int>[8]));
    });

    test('player owns its own MUSIC DSP instance: private engine via '
        'create, never the shared playback engine', () async {
      final player = newPlayer();
      await player.load('/music/song.mp3');

      final creates = log.dspNamed('create');
      expect(creates, hasLength(1));
      expect(_CallLog.argsOf(creates.single),
          {'sampleRate': 48000, 'channels': 2});
      // The shared ExoPlayer playback engine is NOT used here — the
      // mount must never share the VOICE-chain instance with the
      // player, and the player must never adopt the shared engine.
      expect(log.dspNamed('attachPlaybackEngine'), isEmpty);
      expect(player.dsp.isInitialized, isTrue);

      // A second player creates a second engine (distinct instances).
      final second = newPlayer();
      await second.load('/music/other.mp3');
      expect(log.dspNamed('create'), hasLength(2));
      // (The mock returns the same handle 42 for both — a mock
      // artifact. The two 'create' calls prove two engines.)
    });
  });

  group('transport through the new player', () {
    test('pause keeps the pending chunk; resume continues it without '
        'a fresh nextChunk or re-process', () async {
      final player = await loadedPlayer();
      music.nextChunkScript.add(Uint8List.fromList(<int>[9, 9]));
      // First writeChunk is rejected (backpressure): the pump exits
      // with the processed chunk pending.
      music.writeChunkScript.add(false);
      log.clear();

      await player.play();
      await _waitFor(
        () => log.musicNamed('writeChunk').length == 1,
        description: 'first (rejected) writeChunk',
      );
      expect(log.musicNamed('nextChunk'), hasLength(1));
      expect(log.dspNamed('process'), hasLength(1));

      await player.pause();
      expect(player.isPlaying, isFalse);
      expect(log.musicNamed('pause'), hasLength(1));

      await player.resume();
      await _waitFor(
        () => log.musicNamed('finishStream').isNotEmpty,
        description: 'finishStream after resume',
      );

      // The resumed pump wrote the SAME pending chunk (processed
      // bytes [10, 10]) without re-decoding or re-processing it:
      // still 1 process call, 2 writeChunk calls, identical bytes.
      expect(log.dspNamed('process'), hasLength(1));
      final writes = log.musicNamed('writeChunk');
      expect(writes, hasLength(2));
      expect(_CallLog.argsOf(writes[0])['pcmBytes'],
          Uint8List.fromList(<int>[10, 10]));
      expect(_CallLog.argsOf(writes[1])['pcmBytes'],
          Uint8List.fromList(<int>[10, 10]));
      // The second nextChunk is only the EOS check (script empty,
      // repeatChunk null) — no chunk was re-decoded.
      expect(log.musicNamed('nextChunk'), hasLength(2));
    });

    test('seek while paused does not restart the pump', () async {
      final player = await loadedPlayer();
      music.repeatChunk = Uint8List.fromList(<int>[1, 2, 3, 4]);
      await player.play();
      await _waitFor(
        () => log.musicNamed('nextChunk').length >= 2,
        description: 'pump started',
      );
      await player.pause();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final countAtPause = log.musicNamed('nextChunk').length;
      log.clear();

      await player.seek(const Duration(seconds: 30));

      expect(player.isPlaying, isFalse);
      expect(player.position, const Duration(seconds: 30));
      expect(log.musicNamed('seek'), hasLength(1));
      expect(_CallLog.argsOf(log.musicNamed('seek').single),
          {'positionMs': 30000});
      expect(log.dspNamed('reset'), hasLength(1));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(log.musicNamed('nextChunk'), isEmpty);
      // (countAtPause is the pre-seek baseline; the cleared log
      // proves no pump call happened after the seek.)
      expect(countAtPause, greaterThanOrEqualTo(2));
    });

    test('stop mid-pump resets DSP, zeroes position, pump exits',
        () async {
      final player = await loadedPlayer();
      music.repeatChunk = Uint8List.fromList(<int>[1, 2, 3, 4]);
      await player.play();
      await _waitFor(
        () => log.musicNamed('nextChunk').length >= 2,
        description: 'pump started',
      );
      log.clear();

      await player.stop();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final countAfterStop = log.musicNamed('nextChunk').length;

      expect(player.isPlaying, isFalse);
      expect(player.position, Duration.zero);
      expect(log.musicNamed('stop'), hasLength(1));
      expect(log.dspNamed('reset'), hasLength(1));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(log.musicNamed('nextChunk').length, countAfterStop);
    });
  });

  group('ducking', () {
    test('new player setVolume delivers the exact ducked value (5% bed)',
        () async {
      final player = newPlayer();

      // The mount computes ducked = base x 0.05 and hands the value
      // to the player; the player must deliver it verbatim.
      await player.setVolume(0.05);
      await player.setVolume(0.8);

      final volumes = log.musicNamed('setVolume');
      expect(volumes, hasLength(2));
      expect(_CallLog.argsOf(volumes[0]), {'volume': 0.05});
      expect(_CallLog.argsOf(volumes[1]), {'volume': 0.8});
      expect(player.volume, 0.8);
    });

    test('play() applies the last-set (ducked) volume to the new track',
        () async {
      final player = newPlayer();
      await player.setVolume(0.05);
      await player.load('/music/song.mp3');
      log.clear();

      await player.play();

      final volumes = log.musicNamed('setVolume');
      expect(volumes, hasLength(1));
      expect(_CallLog.argsOf(volumes.single), {'volume': 0.05});
    });

    test('ducking contract (source pin, MUST NOT SHIFT): 5% bed, '
        'DIRECT application (no fade — FIX 22 item 11)', () {
      final room = _read('lib/screens/room_screen.dart');

      // The RJ bed level and the ducked-target formula.
      expect(room, contains('static const double _musicDuckedVolume = 0.05'));
      // FIX 20 (fix 11 + defect fix): the target formula lives in
      // the pure musicTargetVolume (unit-tested in
      // fix20_community_voice_test.dart). The activity factor is
      // STILL the 5% bed when any mic is unmuted and speaking,
      // and the fader factor now applies in EVERY mode (shared,
      // local, fallback) — the old "shared-session-only" scope
      // is gone for the fader; only the ACTIVITY bed stays
      // shared-only.
      expect(room,
          contains('final activityFactor = _sharedDucked ? _musicDuckedVolume : 1.0;'));
      expect(room, contains('musicTargetVolume('));
      expect(room, contains('sharedSession: _sharedSession != null,'));
      // The pure rule: shared = base x activity x fader,
      // local/fallback = base x fader (fader ducking everywhere).
      expect(room, contains('base * activityFactor * faderFactor'));
      expect(room, contains(': base * faderFactor;'));
      // FIX 22 item 11 SUPERSEDES the FM fade (Sameer 18:51:
      // "fade in fade out ko chhodo"): _applyMusicVolume is
      // DIRECT always — the 350/1400 durations and the fade
      // loop are DELETED, ducking applies instantly.
      expect(room, isNot(contains('_runMusicFade')));
      expect(room, isNot(contains('_musicFadeGen')));
      expect(room, isNot(contains('_musicFadeDownDuration')));
      expect(room, isNot(contains('_musicFadeUpDuration')));
      expect(room, isNot(contains('setVolume(v)')));
    });

    test('RECONCILED pin (F2 — Group 1 landed): _applyMusicVolume '
        'drives the DSP player _musicPlayer', () {
      final room = _read('lib/screens/room_screen.dart');

      // Post-swap receiver: the DSP player. The setVolume call
      // is unchanged (same receiver name, new player type).
      // FIX 22 item 11: the fade loop's setVolume(v) is gone —
      // only the direct setVolume(target) remains.
      expect(room, contains('MusicDspPlayer? _musicPlayer;'));
      expect(room, contains('await _musicPlayer!.setVolume(target);'));
      expect(room, isNot(contains('setVolume(v)')));
    });
  });

  group('repeat + replay after completion', () {
    test('mount-side replay recipe: completed -> seek(0) -> play '
        'restarts the pump', () async {
      final player = await loadedPlayer();
      music.repeatChunk = Uint8List.fromList(<int>[1, 2, 3, 4]);
      await player.play();
      await _waitFor(
        () => log.musicNamed('nextChunk').length >= 2,
        description: 'pump started',
      );

      // Native end-of-track: the playback thread emits 'completed'.
      await _emitNativeEvent(<String, Object>{'type': 'completed'});
      await _waitFor(
        () => !player.isPlaying,
        description: 'completed clears isPlaying',
      );
      final countAtCompleted = log.musicNamed('nextChunk').length;
      log.clear();

      // The repeat recipe Group 1 wires to the _musicRepeat flag:
      // seek back to 0, then play again.
      await player.seek(Duration.zero);
      expect(log.musicNamed('seek'), hasLength(1));
      expect(_CallLog.argsOf(log.musicNamed('seek').single),
          {'positionMs': 0});
      expect(log.dspNamed('reset'), hasLength(1));

      await player.play();
      expect(player.isPlaying, isTrue);
      await _waitFor(
        () => log.musicNamed('nextChunk').length >= 2,
        description: 'pump restarted after replay',
      );
      expect(countAtCompleted, greaterThanOrEqualTo(2));
    });

    test('RECONCILED behaviour (F1 — Group 1 landed): play() after '
        'natural EOS seeks 0 first, then restarts the pump', () async {
      final player = await loadedPlayer();
      music.nextChunkScript.addAll(<Uint8List?>[
        Uint8List.fromList(<int>[1, 2]),
        null, // EOS
      ]);
      await player.play();
      await _waitFor(
        () => log.musicNamed('finishStream').isNotEmpty,
        description: 'finishStream',
      );
      // Native end-of-track clears isPlaying (otherwise the D2
      // play-while-playing guard would swallow the second play()).
      await _emitNativeEvent(<String, Object>{'type': 'completed'});
      await _waitFor(
        () => !player.isPlaying,
        description: 'completed clears isPlaying',
      );
      log.clear();

      // Chunks for the restarted pump after the rewind.
      music.repeatChunk = Uint8List.fromList(<int>[3, 4]);
      await player.play();

      // NEW behaviour (Group 1 §5.1): play() at EOS rewinds to 0
      // FIRST — a 'seek' {0} is issued, then 'start', and chunks
      // flow again through the pump.
      expect(log.musicNamed('seek'), hasLength(1));
      expect(_CallLog.argsOf(log.musicNamed('seek').single),
          {'positionMs': 0});
      expect(log.musicNamed('start'), hasLength(1));
      await _waitFor(
        () => log.musicNamed('writeChunk').isNotEmpty,
        description: 'chunks flow after rewind',
      );
    });

    test('RECONCILED pin (F3 — Group 1 landed): repeat is mount-side '
        'replay via completedStream, no ReleaseMode', () {
      final room = _read('lib/screens/room_screen.dart');

      expect(room, contains('bool _musicRepeat = true;'));
      // No ReleaseMode anywhere in the mount any more.
      expect(room, isNot(contains('ReleaseMode')));
      // The mount re-plays on natural completion when repeat is on.
      expect(room, contains('completedStream.listen'));
      expect(room,
          contains('if (!mounted || !_musicRepeat || _musicPlaying == null) return;'));
    });
  });

  group('effects wiring pins', () {
    test('RECONCILED pin (F4 — Group 2 landed): the _fx handlers '
        'drive MusicFx on the music DSP instance; the session-0 '
        'tear-offs and the audioplayers attach call are gone', () {
      final room = _read('lib/screens/room_screen.dart');

      // The audioplayers attach call is GONE (Group 1 removed it — it
      // takes an audioplayers AudioPlayer, a type error vs the DSP
      // player). Group 2 re-attached the effects to the music DSP
      // setters: the panel callbacks drive MusicFx through
      // _musicDsp() (the player's own AudioDsp instance).
      expect(room, isNot(contains('_fxPlayback!.attachToPlayer(player)')));
      expect(room, contains('AudioDsp? _musicDsp()'));
      expect(room, contains('final dsp = _musicDsp();'));
      expect(room, contains('await MusicFx.applyReverb(dsp, v);'));
      expect(room, contains('await MusicFx.applyEcho(dsp, v, _fxDelayMs);'));
      expect(room, contains('await MusicFx.applyEcho(dsp, _fxEcho, v);'));
      expect(room, contains('await MusicFx.applyBass(dsp, v);'));
      expect(room, contains('await MusicFx.applyPreset(dsp, values);'));
      // ...and the session-0 tear-offs are gone.
      expect(room, isNot(contains('await reverbEffect.setAmount(v);')));
      expect(room, isNot(contains('await echoEffect.setEcho(v);')));
      expect(room, isNot(contains('await echoEffect.setDelayMs(v);')));
      expect(room, isNot(contains('await bassEffect.setBass((v + 12) / 24);')));
      expect(room, isNot(contains('await playbackEffects.applyPreset(name);')));
      // The _fx mirror state the panel props read.
      expect(room, contains('double _fxReverb = 0.0;'));
      expect(room, contains('double _fxEcho = 0.0;'));
      expect(room, contains('double _fxDelayMs = 250.0;'));
      expect(room, contains('double _fxBass = 0.0;'));
      expect(room, contains("String _fxPreset = 'Off';"));
    });

    test('music DSP instance accepts effect setters through the '
        'audio_dsp channel', () async {
      final player = await loadedPlayer();
      log.clear();

      await player.dsp.setReverb(wetDryMix: 0.6);
      await player.dsp.setEcho(delayMs: 250.0, mix: 0.5);
      await player.dsp.setEq(bassBoostDb: 6.0);

      // The setters Group 2 will call are reachable on the MUSIC
      // instance, addressed to its private-engine handle.
      final reverbs = log.dspNamed('setReverb');
      expect(reverbs, hasLength(1));
      expect(_CallLog.argsOf(reverbs.single), <String, Object>{
        'handle': 42,
        'enabled': true,
        'wetDryMix': 0.6,
        'roomSize': 0.5,
        'damping': 0.5,
      });
      final echoes = log.dspNamed('setEcho');
      expect(echoes, hasLength(1));
      expect(_CallLog.argsOf(echoes.single), <String, Object>{
        'handle': 42,
        'enabled': true,
        'delayMs': 250.0,
        'feedback': 0.35,
        'mix': 0.5,
      });
      final eqs = log.dspNamed('setEq');
      expect(eqs, hasLength(1));
      expect(_CallLog.argsOf(eqs.single), <String, Object>{
        'handle': 42,
        'enabled': true,
        'bassBoostDb': 6.0,
        'lowGainDb': 0.0,
        'midGainDb': 0.0,
        'highGainDb': 0.0,
      });
    });

    test('DSP wrapper HAS the music setters Group 2 needs (source pin, '
        'STABLE)', () {
      final wrapper = _read('lib/audio/audio_dsp.dart');

      expect(wrapper, contains('Future<void> setReverb({'));
      expect(wrapper, contains('Future<void> setEcho({'));
      expect(wrapper, contains('Future<void> setEq({'));
      expect(wrapper, contains('Future<void> setNoiseGate({'));
      expect(wrapper, contains('Future<void> setCompressor({'));
      expect(wrapper, contains('Future<Uint8List> process('));
      expect(wrapper, contains('Future<void> reset()'));
    });
  });
}
