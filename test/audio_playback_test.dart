import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/services/playback_effects.dart';

/// GROUP 8 (ARENA HUB #10 AUDIO) — tests for [PlaybackEffects], the
/// music-playback DSP aggregator.
///
/// Groups 3/4/5 run in parallel, so their effect objects are faked
/// here with recording tear-offs that match the contracted signatures
/// exactly (ReverbEffect.setAmount, EchoDelayEffect.setEcho /
/// setDelayMs, BassEqEffect.setBass / setEqBand). The native bridge
/// is mocked on the shared `arena_audio/effects` channel.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel bridgeChannel = MethodChannel('arena_audio/effects');

  /// audioplayers calls `init` (global channel) + `create` (players
  /// channel) from the AudioPlayer constructor; without mocks the
  /// constructor's internal future fails with MissingPluginException
  /// and the test zone reports it as an unhandled error.
  void mockAudioplayersChannels() {
    final TestDefaultBinaryMessengerBinding binding =
        TestDefaultBinaryMessengerBinding.instance;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('xyz.luan/audioplayers.global'),
      (MethodCall call) async => null,
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('xyz.luan/audioplayers'),
      (MethodCall call) async => null,
    );
  }

  void unmockAudioplayersChannels() {
    final TestDefaultBinaryMessengerBinding binding =
        TestDefaultBinaryMessengerBinding.instance;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('xyz.luan/audioplayers.global'),
      null,
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('xyz.luan/audioplayers'),
      null,
    );
  }

  /// Routing report the native bridge returns on attachPlayback.
  Map<String, Object> routingReport({bool attached = true}) =>
      <String, Object>{
        'sessionId': 0,
        'routing': 'global-mix',
        'perPlayerSession': false,
        'playerSessionAvailable': false,
        'reason': 'audioplayers does not expose the player session',
        'attached': attached,
        'effectsAvailable': true,
        'probed': true,
      };

  group('PlaybackEffects presets', () {
    late _FakeEffects effects;
    late PlaybackEffects playback;

    setUp(() {
      effects = _FakeEffects();
      playback = PlaybackEffects(
        setReverbAmount: effects.setReverbAmount,
        setEchoAmount: effects.setEchoAmount,
        setEchoDelayMs: effects.setEchoDelayMs,
        setBassAmount: effects.setBassAmount,
        setEqBand: effects.setEqBand,
        disposeEffects: effects.disposeEffects,
      );
    });

    tearDown(() async {
      await playback.dispose();
    });

    test('Off preset sends all-zero values', () async {
      await playback.applyPreset('Room');
      effects.clear();
      await playback.applyPreset('Off');

      expect(playback.currentPreset, 'Off');
      expect(effects.reverbCalls, <double>[0.0]);
      expect(effects.echoCalls, <double>[0.0]);
      expect(effects.delayCalls, <double>[250.0]);
      expect(effects.bassCalls, <double>[0.0]);
      expect(effects.eqCalls, <_EqCall>[const _EqCall(0, 0.0)]);
    });

    test('Room preset sends Room values', () async {
      await playback.applyPreset('Room');

      expect(playback.currentPreset, 'Room');
      expect(effects.reverbCalls, <double>[0.35]);
      expect(effects.echoCalls, <double>[0.15]);
      expect(effects.delayCalls, <double>[180.0]);
      expect(effects.bassCalls, <double>[0.30]);
      expect(effects.eqCalls, <_EqCall>[const _EqCall(0, 3.0)]);
    });

    test('Hall preset sends Hall values', () async {
      await playback.applyPreset('Hall');

      expect(playback.currentPreset, 'Hall');
      expect(effects.reverbCalls, <double>[0.70]);
      expect(effects.echoCalls, <double>[0.25]);
      expect(effects.delayCalls, <double>[350.0]);
      expect(effects.bassCalls, <double>[0.40]);
      expect(effects.eqCalls, <_EqCall>[const _EqCall(0, 4.5)]);
    });

    test('unknown preset throws ArgumentError, preset unchanged', () async {
      await playback.applyPreset('Room');
      effects.clear();

      expect(
        () => playback.applyPreset('Cathedral'),
        throwsArgumentError,
      );
      expect(playback.currentPreset, 'Room');
      expect(effects.allCalls, isEmpty);
    });

    test('preset names are case-insensitive', () async {
      await playback.applyPreset('room');
      expect(playback.currentPreset, 'Room');
      await playback.applyPreset('  HALL ');
      expect(playback.currentPreset, 'Hall');
    });

    test('setEnabled(false) pushes Off, (true) re-applies preset',
        () async {
      await playback.applyPreset('Hall');
      effects.clear();

      await playback.setEnabled(false);
      expect(playback.isEnabled, isFalse);
      expect(effects.reverbCalls, <double>[0.0]);
      expect(effects.bassCalls, <double>[0.0]);
      expect(effects.eqCalls, <_EqCall>[const _EqCall(0, 0.0)]);

      effects.clear();
      await playback.setEnabled(true);
      expect(playback.isEnabled, isTrue);
      expect(effects.reverbCalls, <double>[0.70]);
      expect(effects.delayCalls, <double>[350.0]);
    });

    test('setEnabled is a no-op when unchanged', () async {
      await playback.applyPreset('Room');
      effects.clear();
      await playback.setEnabled(true); // already enabled
      expect(effects.allCalls, isEmpty);
    });

    test('applyPreset while disabled records preset, sends nothing',
        () async {
      await playback.setEnabled(false);
      effects.clear();

      await playback.applyPreset('Hall');
      expect(playback.currentPreset, 'Hall');
      expect(effects.allCalls, isEmpty);

      await playback.setEnabled(true);
      expect(effects.reverbCalls, <double>[0.70]);
    });

    test('a failing setter does not block the others; error rethrown',
        () async {
      effects.failReverb = true;
      Object? caught;
      try {
        await playback.applyPreset('Room');
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<PlatformException>());
      // Every other setter still ran.
      expect(effects.echoCalls, <double>[0.15]);
      expect(effects.delayCalls, <double>[180.0]);
      expect(effects.bassCalls, <double>[0.30]);
      expect(effects.eqCalls, <_EqCall>[const _EqCall(0, 3.0)]);
    });
  });

  group('PlaybackEffects attach + bridge', () {
    late _FakeEffects effects;
    late PlaybackEffects playback;
    final List<MethodCall> bridgeCalls = <MethodCall>[];

    setUp(() {
      effects = _FakeEffects();
      bridgeCalls.clear();
      mockAudioplayersChannels();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(bridgeChannel,
              (MethodCall call) async {
        bridgeCalls.add(call);
        switch (call.method) {
          case 'attachPlayback':
            return routingReport();
          case 'detachPlayback':
            return routingReport(attached: false);
          case 'getSessionInfo':
            return routingReport();
          default:
            return null;
        }
      });
      playback = PlaybackEffects(
        setReverbAmount: effects.setReverbAmount,
        setEchoAmount: effects.setEchoAmount,
        setEchoDelayMs: effects.setEchoDelayMs,
        setBassAmount: effects.setBassAmount,
        setEqBand: effects.setEqBand,
        disposeEffects: effects.disposeEffects,
      );
    });

    tearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(bridgeChannel, null);
      unmockAudioplayersChannels();
      await playback.dispose();
    });

    test('attachToPlayer calls bridge and records session info',
        () async {
      final AudioPlayer player = AudioPlayer(playerId: 'music-player-1');
      await playback.attachToPlayer(player);

      expect(playback.isAttached, isTrue);
      expect(playback.attachedPlayerId, 'music-player-1');
      expect(playback.bridgeAvailable, isTrue);
      expect(
        bridgeCalls.map((MethodCall c) => c.method),
        contains('attachPlayback'),
      );
      final Map<String, Object?>? info = playback.sessionInfo;
      expect(info, isNotNull);
      expect(info!['sessionId'], 0);
      expect(info['routing'], 'global-mix');
      expect(info['perPlayerSession'], isFalse);
      expect(info['effectsAvailable'], isTrue);
    });

    test('attachToPlayer applies the current preset', () async {
      await playback.applyPreset('Room');
      effects.clear();
      final AudioPlayer player = AudioPlayer(playerId: 'music-player-2');
      await playback.attachToPlayer(player);

      expect(effects.reverbCalls, <double>[0.35]);
      expect(effects.delayCalls, <double>[180.0]);
    });

    test('dispose zeroes effects, detaches, disposes effects', () async {
      final AudioPlayer player = AudioPlayer(playerId: 'music-player-3');
      await playback.attachToPlayer(player);
      await playback.applyPreset('Hall');
      effects.clear();
      bridgeCalls.clear();

      await playback.dispose();

      expect(effects.reverbCalls, <double>[0.0]);
      expect(effects.echoCalls, <double>[0.0]);
      expect(effects.bassCalls, <double>[0.0]);
      expect(effects.eqCalls, <_EqCall>[const _EqCall(0, 0.0)]);
      expect(effects.disposeCount, 1);
      expect(
        bridgeCalls.map((MethodCall c) => c.method),
        contains('detachPlayback'),
      );
      expect(playback.isAttached, isFalse);
    });

    test('dispose is idempotent; calls after dispose throw', () async {
      await playback.dispose();
      await playback.dispose(); // second call: no-op, no throw
      expect(effects.disposeCount, 1);

      expect(
        () => playback.applyPreset('Room'),
        throwsStateError,
      );
      expect(
        () => playback.setEnabled(false),
        throwsStateError,
      );
      expect(
        () => playback.attachToPlayer(AudioPlayer()),
        throwsStateError,
      );
    });
  });

  group('PlaybackEffects without a native bridge', () {
    test('attachToPlayer does not throw when the bridge is missing',
        () async {
      // No mock handler for arena_audio/effects: the platform side
      // is absent. (audioplayers itself IS mocked so the player
      // constructor does not fail — that is a different channel.)
      mockAudioplayersChannels();
      addTearDown(unmockAudioplayersChannels);
      final _FakeEffects effects = _FakeEffects();
      final PlaybackEffects playback = PlaybackEffects(
        setReverbAmount: effects.setReverbAmount,
        setEchoAmount: effects.setEchoAmount,
        setEchoDelayMs: effects.setEchoDelayMs,
        setBassAmount: effects.setBassAmount,
        setEqBand: effects.setEqBand,
      );
      addTearDown(() async => playback.dispose());

      final AudioPlayer player = AudioPlayer(playerId: 'music-player-9');
      await playback.attachToPlayer(player); // must not throw

      expect(playback.isAttached, isTrue);
      expect(playback.bridgeAvailable, isFalse);
      expect(playback.sessionInfo, isNull);
    });
  });
}

/// Recording stand-in for the effect groups' Dart APIs, matching the
/// contracted signatures exactly.
class _FakeEffects {
  final List<double> reverbCalls = <double>[];
  final List<double> echoCalls = <double>[];
  final List<double> delayCalls = <double>[];
  final List<double> bassCalls = <double>[];
  final List<_EqCall> eqCalls = <_EqCall>[];
  int disposeCount = 0;

  /// When true, [setReverbAmount] throws like a failed native call.
  bool failReverb = false;

  List<Object> get allCalls => <Object>[
        ...reverbCalls,
        ...echoCalls,
        ...delayCalls,
        ...bassCalls,
        ...eqCalls,
      ];

  void clear() {
    reverbCalls.clear();
    echoCalls.clear();
    delayCalls.clear();
    bassCalls.clear();
    eqCalls.clear();
  }

  Future<void> setReverbAmount(double amount) async {
    if (failReverb) {
      throw PlatformException(
        code: 'reverb_unavailable',
        message: 'fake reverb failure',
      );
    }
    reverbCalls.add(amount);
  }

  Future<void> setEchoAmount(double amount) async {
    echoCalls.add(amount);
  }

  Future<void> setEchoDelayMs(double ms) async {
    delayCalls.add(ms);
  }

  Future<void> setBassAmount(double amount) async {
    bassCalls.add(amount);
  }

  Future<void> setEqBand(int band, double gainDb) async {
    eqCalls.add(_EqCall(band, gainDb));
  }

  Future<void> disposeEffects() async {
    disposeCount++;
  }
}

class _EqCall {
  const _EqCall(this.band, this.gainDb);

  final int band;
  final double gainDb;

  @override
  bool operator ==(Object other) =>
      other is _EqCall && other.band == band && other.gainDb == gainDb;

  @override
  int get hashCode => Object.hash(band, gainDb);

  @override
  String toString() => '_EqCall($band, $gainDb)';
}
