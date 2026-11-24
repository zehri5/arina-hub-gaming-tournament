// MUSIC DSP PLAYER TESTS (Group 8 music, 2026-11-22).
//
// Tests the Dart player lib/audio/music_dsp_player.dart (class
// MusicDspPlayer) against mocked platform channels — no native code runs
// here. Two MethodChannels are mocked:
//
//   * 'com.arenahub.app/music_dsp'        — the MusicDspPlugin methods
//     (load/start/pause/resume/stop/seek/setVolume/nextChunk/writeChunk/
//     finishStream/dispose).
//   * 'com.arenahub.app/audio_dsp'        — the folded AudioDsp wrapper's
//     channel (the player owns a REAL AudioDsp instance, so the pump's
//     dsp.process() goes through the real wrapper code with a canned
//     native reply).
//
// The EventChannel 'com.arenahub.app/music_dsp_events' is mocked for
// listen/cancel, and native events are injected with
// handlePlatformMessage + StandardMethodCodec success envelopes.
//
// What this CANNOT prove (phone-only): real MediaCodec decode, audible
// AudioTrack output, latency/underrun behaviour, and the Kotlin-side
// queue/generation races. The Kotlin is proven separately by the
// kotlinc + d8 compile (see MUSIC_PLAYER_INTEGRATION.md) and the JVM
// resampler check (/tmp, host-side).
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/audio/audio_dsp.dart';
import 'package:protournament_user/audio/music_dsp_player.dart';

const MethodChannel _musicChannel =
    MethodChannel('com.arenahub.app/music_dsp');
const MethodChannel _dspChannel = MethodChannel('com.arenahub.app/audio_dsp');
const MethodChannel _eventChannel =
    MethodChannel('com.arenahub.app/music_dsp_events');

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
  /// empty, nextChunk returns null (end of stream) — unless
  /// [repeatChunk] is set, in which case it returns that chunk forever.
  final List<Uint8List?> nextChunkScript = <Uint8List?>[];
  Uint8List? repeatChunk;
  Object? nextChunkError;
  bool writeChunkResult = true;
  int loadDurationMs = 180000;
  Object? loadError;

  Future<dynamic> handler(MethodCall call) async {
    log.musicCalls.add(call);
    log.order.add('music:${call.method}');
    switch (call.method) {
      case 'load':
        if (loadError != null) throw loadError!;
        return <String, Object>{'durationMs': loadDurationMs};
      case 'seek':
        final args = _CallLog.argsOf(call);
        return args['positionMs'] as int;
      case 'nextChunk':
        // Tiny delay paces the pump so repeat-mode tests log a
        // bounded number of iterations.
        await Future<void>.delayed(const Duration(milliseconds: 1));
        if (nextChunkError != null) {
          final Object error = nextChunkError!;
          nextChunkError = null;
          throw error;
        }
        if (nextChunkScript.isNotEmpty) {
          return nextChunkScript.removeAt(0);
        }
        return repeatChunk;
      case 'writeChunk':
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
  Object? createError;

  /// process() returns each input byte + 1 (mod 256), so tests can
  /// prove writeChunk received the PROCESSED bytes, not the raw ones.
  Future<dynamic> handler(MethodCall call) async {
    log.dspCalls.add(call);
    log.order.add('dsp:${call.method}');
    switch (call.method) {
      case 'create':
        if (createError != null) throw createError!;
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

  Future<MusicDspPlayer> playingPlayer() async {
    final player = await loadedPlayer();
    await player.play();
    return player;
  }

  group('load', () {
    test('sends filePath, returns duration, inits DSP 48k stereo',
        () async {
      final player = newPlayer();
      final durations = <Duration>[];
      final positions = <Duration>[];
      player.durationStream.listen(durations.add);
      player.positionStream.listen(positions.add);

      final duration = await player.load('/music/song.mp3');
      // Broadcast stream events land a microtask after the call.
      await _waitFor(
        () => durations.length == 1 && positions.length == 2,
        description: 'duration + position emissions',
      );

      expect(duration, const Duration(minutes: 3));
      expect(player.isLoaded, isTrue);
      expect(player.duration, const Duration(minutes: 3));
      expect(player.position, Duration.zero);
      expect(durations, [const Duration(minutes: 3)]);
      // Two zero emissions: load() stops any previous playback first
      // (stop() emits zero) and then emits zero for the new file.
      expect(positions, [Duration.zero, Duration.zero]);
      final loads = log.musicNamed('load');
      expect(loads, hasLength(1));
      expect(_CallLog.argsOf(loads.single),
          {'filePath': '/music/song.mp3'});
      // The player owns its AudioDsp instance and inits it 48k stereo.
      final creates = log.dspNamed('create');
      expect(creates, hasLength(1));
      expect(_CallLog.argsOf(creates.single),
          {'sampleRate': 48000, 'channels': 2});
      expect(player.dsp.isInitialized, isTrue);
      expect(player.dsp.sampleRate, 48000);
      expect(player.dsp.channels, 2);
    });

    test('empty path throws INVALID_ARGS and sends nothing', () async {
      final player = newPlayer();

      expect(
        () => player.load('   '),
        throwsA(isA<MusicDspException>().having(
          (e) => e.code,
          'code',
          'INVALID_ARGS',
        )),
      );
      expect(player.isLoaded, isFalse);
      expect(log.musicCalls, isEmpty);
      expect(log.dspCalls, isEmpty);
    });

    test('native load failure throws MusicDspException, not loaded',
        () async {
      music.loadError = PlatformException(
        code: 'LOAD_FAILED',
        message: 'no such file',
      );
      final player = newPlayer();

      expect(
        () => player.load('/music/missing.mp3'),
        throwsA(isA<MusicDspException>()
            .having((e) => e.code, 'code', 'LOAD_FAILED')
            .having((e) => e.message, 'message', 'no such file')),
      );
      expect(player.isLoaded, isFalse);
    });

    test('DSP init failure surfaces as MusicDspException (D5)', () async {
      dspChannel.createError = PlatformException(
        code: 'NATIVE_UNAVAILABLE',
        message: 'libaudio_dsp.so is missing',
      );
      final player = newPlayer();

      expect(
        () => player.load('/music/song.mp3'),
        throwsA(isA<MusicDspException>().having(
          (e) => e.code,
          'code',
          'NATIVE_UNAVAILABLE',
        )),
      );
      expect(player.isLoaded, isFalse);
    });
  });

  group('play / pump', () {
    test('play sends start + setVolume, sets isPlaying', () async {
      final player = await loadedPlayer();
      final playingStates = <bool>[];
      player.isPlayingStream.listen(playingStates.add);
      log.clear();

      await player.play();
      await _waitFor(
        () => playingStates.isNotEmpty,
        description: 'isPlaying emission',
      );

      expect(player.isPlaying, isTrue);
      expect(playingStates, [true]);
      expect(log.musicNamed('start'), hasLength(1));
      final volumes = log.musicNamed('setVolume');
      expect(volumes, hasLength(1));
      expect(_CallLog.argsOf(volumes.single), {'volume': 1.0});
    });

    test('play-before-load throws NOT_LOADED', () async {
      final player = newPlayer();

      expect(
        () => player.play(),
        throwsA(isA<MusicDspException>().having(
          (e) => e.code,
          'code',
          'NOT_LOADED',
        )),
      );
      expect(log.musicNamed('start'), isEmpty);
    });

    test('pump order: nextChunk -> dsp.process -> writeChunk (processed '
        'bytes), then EOS -> finishStream', () async {
      final player = await loadedPlayer();
      music.nextChunkScript.addAll(<Uint8List?>[
        Uint8List.fromList(<int>[1, 2, 3, 4]),
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
        'music:finishStream',
      ]);

      // process() received the raw chunk with the DSP handle...
      final processes = log.dspNamed('process');
      expect(processes, hasLength(1));
      final processArgs = _CallLog.argsOf(processes.single);
      expect(processArgs['handle'], 42);
      expect(processArgs['pcmBytes'], Uint8List.fromList(<int>[1, 2, 3, 4]));
      // ...and writeChunk received the PROCESSED bytes (each byte + 1).
      final writes = log.musicNamed('writeChunk');
      expect(writes, hasLength(1));
      expect(
        _CallLog.argsOf(writes.single)['pcmBytes'],
        Uint8List.fromList(<int>[2, 3, 4, 5]),
      );
    });

    test('pump skips empty chunks and keeps going', () async {
      final player = await loadedPlayer();
      music.nextChunkScript.addAll(<Uint8List?>[
        Uint8List(0),
        Uint8List.fromList(<int>[7, 7]),
        null,
      ]);
      log.clear();

      await player.play();
      await _waitFor(
        () => log.musicNamed('finishStream').isNotEmpty,
        description: 'finishStream',
      );

      expect(log.musicNamed('nextChunk'), hasLength(3));
      expect(log.dspNamed('process'), hasLength(1));
      expect(log.musicNamed('writeChunk'), hasLength(1));
    });

    test('pump nextChunk error emits on errorStream, stops playing',
        () async {
      final player = await loadedPlayer();
      music.nextChunkError = PlatformException(
        code: 'DECODE_FAILED',
        message: 'codec died',
      );
      final errors = <MusicDspException>[];
      player.errorStream.listen(errors.add);
      log.clear();

      await player.play();
      await _waitFor(
        () => errors.isNotEmpty,
        description: 'error event',
      );

      expect(player.isPlaying, isFalse);
      expect(errors.single.message, contains('codec died'));
    });

    test('second play() while playing is a no-op (D2)', () async {
      final player = await loadedPlayer();
      music.repeatChunk = Uint8List.fromList(<int>[1, 2, 3, 4]);

      await player.play();
      await player.play();

      expect(log.musicNamed('start'), hasLength(1));
    });
  });

  group('pause / resume', () {
    test('pause sends pause, clears isPlaying, pump stops', () async {
      final player = await loadedPlayer();
      music.repeatChunk = Uint8List.fromList(<int>[1, 2, 3, 4]);
      await player.play();
      await _waitFor(
        () => log.musicNamed('nextChunk').length >= 3,
        description: 'pump started',
      );

      await player.pause();

      expect(player.isPlaying, isFalse);
      expect(log.musicNamed('pause'), hasLength(1));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final countAfterPause = log.musicNamed('nextChunk').length;
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(log.musicNamed('nextChunk').length, countAfterPause);
    });

    test('resume sends resume and restarts the pump', () async {
      final player = await loadedPlayer();
      music.repeatChunk = Uint8List.fromList(<int>[1, 2, 3, 4]);
      await player.play();
      await player.pause();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final countAtPause = log.musicNamed('nextChunk').length;

      await player.resume();

      expect(player.isPlaying, isTrue);
      expect(log.musicNamed('resume'), hasLength(1));
      await _waitFor(
        () => log.musicNamed('nextChunk').length > countAtPause,
        description: 'pump restarted',
      );
    });
  });

  group('stop / seek / volume', () {
    test('stop sends stop, resets DSP, emits zero position', () async {
      final player = await playingPlayer();
      final positions = <Duration>[];
      player.positionStream.listen(positions.add);
      log.clear();

      await player.stop();
      await _waitFor(
        () => positions.isNotEmpty,
        description: 'zero position emission',
      );

      expect(player.isPlaying, isFalse);
      expect(player.position, Duration.zero);
      expect(positions, [Duration.zero]);
      expect(log.musicNamed('stop'), hasLength(1));
      expect(log.dspNamed('reset'), hasLength(1));
    });

    test('seek sends clamped positionMs, resets DSP, emits position',
        () async {
      final player = await loadedPlayer();
      final positions = <Duration>[];
      player.positionStream.listen(positions.add);
      log.clear();

      await player.seek(const Duration(seconds: 30));
      await _waitFor(
        () => positions.isNotEmpty,
        description: 'seek position emission',
      );

      expect(player.position, const Duration(seconds: 30));
      expect(positions, [const Duration(seconds: 30)]);
      final seeks = log.musicNamed('seek');
      expect(seeks, hasLength(1));
      expect(_CallLog.argsOf(seeks.single), {'positionMs': 30000});
      expect(log.dspNamed('reset'), hasLength(1));
    });

    test('seek clamps above duration and below zero', () async {
      final player = await loadedPlayer();
      log.clear();

      await player.seek(const Duration(minutes: 5));
      await player.seek(const Duration(seconds: -5));

      final seeks = log.musicNamed('seek');
      expect(seeks, hasLength(2));
      expect(_CallLog.argsOf(seeks[0]), {'positionMs': 180000});
      expect(_CallLog.argsOf(seeks[1]), {'positionMs': 0});
    });

    test('seek while playing restarts the pump', () async {
      final player = await loadedPlayer();
      music.repeatChunk = Uint8List.fromList(<int>[1, 2, 3, 4]);
      await player.play();
      await _waitFor(
        () => log.musicNamed('nextChunk').length >= 2,
        description: 'pump started',
      );
      final countBeforeSeek = log.musicNamed('nextChunk').length;

      await player.seek(const Duration(seconds: 10));

      expect(player.isPlaying, isTrue);
      // +3, not +1: the stale pre-seek loop can contribute at most one
      // in-flight nextChunk after the seek; three new calls prove the
      // restarted pump is running.
      await _waitFor(
        () => log.musicNamed('nextChunk').length >= countBeforeSeek + 3,
        description: 'pump restarted after seek',
      );
    });

    test('setVolume clamps to [0, 1] and sends setVolume', () async {
      final player = newPlayer();

      await player.setVolume(2.0);
      await player.setVolume(-0.5);
      await player.setVolume(0.25);

      expect(player.volume, 0.25);
      final volumes = log.musicNamed('setVolume');
      expect(volumes, hasLength(3));
      expect(_CallLog.argsOf(volumes[0]), {'volume': 1.0});
      expect(_CallLog.argsOf(volumes[1]), {'volume': 0.0});
      expect(_CallLog.argsOf(volumes[2]), {'volume': 0.25});
    });
  });

  group('streams', () {
    test('position event updates position stream', () async {
      final player = newPlayer();
      final positions = <Duration>[];
      player.positionStream.listen(positions.add);

      await _emitNativeEvent(<String, Object>{
        'type': 'position',
        'positionMs': 5000,
        'durationMs': 180000,
      });
      await _waitFor(
        () => positions.isNotEmpty,
        description: 'position event',
      );

      expect(positions, [const Duration(seconds: 5)]);
      expect(player.position, const Duration(seconds: 5));
      expect(player.duration, const Duration(minutes: 3));
    });

    test('state event updates isPlaying stream', () async {
      final player = await playingPlayer();
      final states = <bool>[];
      player.isPlayingStream.listen(states.add);

      await _emitNativeEvent(<String, Object>{
        'type': 'state',
        'isPlaying': false,
      });
      await _waitFor(
        () => states.isNotEmpty,
        description: 'state event',
      );

      expect(states, [false]);
      expect(player.isPlaying, isFalse);
    });

    test('completed event clears isPlaying', () async {
      final player = await playingPlayer();
      final states = <bool>[];
      player.isPlayingStream.listen(states.add);

      await _emitNativeEvent(<String, Object>{'type': 'completed'});
      await _waitFor(
        () => states.isNotEmpty,
        description: 'completed event',
      );

      expect(states, [false]);
      expect(player.isPlaying, isFalse);
    });

    test('error event emits MusicDspException and clears isPlaying',
        () async {
      final player = await playingPlayer();
      final errors = <MusicDspException>[];
      player.errorStream.listen(errors.add);

      await _emitNativeEvent(<String, Object>{
        'type': 'error',
        'message': 'native boom',
      });
      await _waitFor(
        () => errors.isNotEmpty,
        description: 'error event',
      );

      expect(errors.single.message, 'native boom');
      expect(player.isPlaying, isFalse);
    });
  });

  group('dispose', () {
    test('dispose sends dispose, destroys owned DSP, double-dispose '
        'is a no-op', () async {
      final player = await loadedPlayer();
      log.clear();

      await player.dispose();
      await player.dispose();

      expect(log.musicNamed('dispose'), hasLength(1));
      expect(log.dspNamed('destroy'), hasLength(1));
      expect(_CallLog.argsOf(log.dspNamed('destroy').single),
          {'handle': 42});
      expect(player.isPlaying, isFalse);
      expect(player.isLoaded, isFalse);
    });

    test('dispose does not destroy an injected (shared) DSP', () async {
      final sharedDsp = AudioDsp();
      await sharedDsp.init(sampleRate: 48000, channels: 2);
      final player = newPlayer(dsp: sharedDsp);
      log.clear();

      await player.dispose();

      expect(log.musicNamed('dispose'), hasLength(1));
      expect(log.dspNamed('destroy'), isEmpty);
      expect(sharedDsp.isInitialized, isTrue);
      await sharedDsp.dispose();
    });

    test('dispose during pump is safe: no throw, pump exits', () async {
      final player = await loadedPlayer();
      music.repeatChunk = Uint8List.fromList(<int>[1, 2, 3, 4]);
      await player.play();
      await _waitFor(
        () => log.musicNamed('nextChunk').length >= 3,
        description: 'pump started',
      );

      await player.dispose();

      await Future<void>.delayed(const Duration(milliseconds: 100));
      final countAfterDispose = log.musicNamed('nextChunk').length;
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(log.musicNamed('nextChunk').length, countAfterDispose);
      expect(log.musicNamed('dispose'), hasLength(1));
    });

    test('calls after dispose throw StateError; stop() is silent',
        () async {
      final player = await loadedPlayer();
      await player.dispose();

      expect(() => player.load('/music/x.mp3'),
          throwsA(isA<StateError>()));
      expect(() => player.play(), throwsA(isA<StateError>()));
      expect(() => player.pause(), throwsA(isA<StateError>()));
      expect(() => player.resume(), throwsA(isA<StateError>()));
      expect(() => player.seek(Duration.zero),
          throwsA(isA<StateError>()));
      expect(() => player.setVolume(0.5), throwsA(isA<StateError>()));
      await player.stop(); // fail-soft: no throw after dispose
    });
  });
}
