// AUDIO DSP WRAPPER TESTS (Group 10 DSP, 2026-11-22).
//
// Tests the Dart wrapper lib/audio/audio_dsp.dart (class AudioDsp) against a
// mocked MethodChannel 'com.arenahub.app/audio_dsp' — no native code runs
// here. The C++ engine itself is smoke-tested on the host by
// android/app/src/main/cpp/host_test/host_dsp_smoke_test.cpp (host-only,
// NOT part of the shipped code).
//
// Coverage target: every public method + every branch of the wrapper's state
// machine (uninitialized / initialized / disposed), argument validation,
// payload shapes (including the native handle in every call), and clamping
// at/beyond every bound.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/audio/audio_dsp.dart';

const MethodChannel _channel =
    MethodChannel('com.arenahub.app/audio_dsp');

/// Records every MethodCall and serves configurable canned replies.
class _FakeDspChannel {
  final List<MethodCall> calls = <MethodCall>[];
  int? createResult = 42;
  Uint8List? processResult;

  Future<dynamic> handler(MethodCall call) async {
    calls.add(call);
    switch (call.method) {
      case 'create':
        return createResult;
      case 'process':
        return processResult;
      default:
        return null;
    }
  }

  List<MethodCall> callsNamed(String method) =>
      calls.where((c) => c.method == method).toList();

  Map<String, dynamic> argsOf(MethodCall call) =>
      Map<String, dynamic>.from(call.arguments as Map);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeDspChannel fake;

  setUp(() {
    fake = _FakeDspChannel();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, fake.handler);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  Future<AudioDsp> initializedDsp({
    int sampleRate = 48000,
    int channels = 2,
  }) async {
    final dsp = AudioDsp();
    await dsp.init(sampleRate: sampleRate, channels: channels);
    return dsp;
  }

  group('init', () {
    test('assigns handle, reports initialized, sends create payload', () async {
      final dsp = AudioDsp();
      expect(dsp.isInitialized, isFalse);

      await dsp.init(sampleRate: 44100, channels: 1);

      expect(dsp.isInitialized, isTrue);
      expect(dsp.sampleRate, 44100);
      expect(dsp.channels, 1);
      final creates = fake.callsNamed('create');
      expect(creates, hasLength(1));
      expect(fake.argsOf(creates.single), {
        'sampleRate': 44100,
        'channels': 1,
      });
    });

    test('defaults to 48000 Hz stereo', () async {
      final dsp = AudioDsp();
      await dsp.init();
      expect(dsp.sampleRate, 48000);
      expect(dsp.channels, 2);
      expect(fake.argsOf(fake.callsNamed('create').single), {
        'sampleRate': 48000,
        'channels': 2,
      });
    });

    test('second init routes to configure instead of a second create',
        () async {
      final dsp = await initializedDsp(sampleRate: 48000, channels: 2);
      fake.calls.clear();

      await dsp.init(sampleRate: 44100, channels: 1);

      expect(fake.callsNamed('create'), isEmpty);
      final configures = fake.callsNamed('configure');
      expect(configures, hasLength(1));
      expect(fake.argsOf(configures.single), {
        'handle': 42,
        'sampleRate': 44100,
        'channels': 1,
      });
      expect(dsp.sampleRate, 44100);
      expect(dsp.channels, 1);
      expect(dsp.isInitialized, isTrue);
    });

    test('second init validates format before routing to configure', () async {
      final dsp = await initializedDsp();
      fake.calls.clear();
      await expectLater(
        dsp.init(sampleRate: 100, channels: 2),
        throwsArgumentError,
      );
      expect(fake.calls, isEmpty);
      expect(dsp.sampleRate, 48000);
    });

    test('disposed instance throws StateError on init', () async {
      final dsp = await initializedDsp();
      await dsp.dispose();
      await expectLater(dsp.init(), throwsStateError);
    });

    test('sampleRate below 8000 throws ArgumentError, no channel call',
        () async {
      final dsp = AudioDsp();
      await expectLater(dsp.init(sampleRate: 7999), throwsArgumentError);
      await expectLater(dsp.init(sampleRate: 0), throwsArgumentError);
      await expectLater(dsp.init(sampleRate: -48000), throwsArgumentError);
      expect(fake.calls, isEmpty);
      expect(dsp.isInitialized, isFalse);
    });

    test('sampleRate above 192000 throws ArgumentError', () async {
      final dsp = AudioDsp();
      await expectLater(dsp.init(sampleRate: 192001), throwsArgumentError);
      expect(fake.calls, isEmpty);
    });

    test('sampleRate bounds 8000 and 192000 are accepted', () async {
      final dsp = AudioDsp();
      await dsp.init(sampleRate: 8000);
      expect(dsp.sampleRate, 8000);
      await dsp.init(sampleRate: 192000);
      expect(dsp.sampleRate, 192000);
    });

    test('channels other than 1 or 2 throws ArgumentError', () async {
      final dsp = AudioDsp();
      for (final bad in <int>[0, 3, -1, 6]) {
        await expectLater(
          dsp.init(channels: bad),
          throwsArgumentError,
          reason: 'channels=$bad',
        );
      }
      expect(fake.calls, isEmpty);
    });

    test('null handle throws PlatformException INIT_FAILED', () async {
      fake.createResult = null;
      final dsp = AudioDsp();
      await expectLater(
        dsp.init(),
        throwsA(
          isA<PlatformException>()
              .having((e) => e.code, 'code', 'INIT_FAILED'),
        ),
      );
      expect(dsp.isInitialized, isFalse);
      // Still uninitialized afterwards: next call reports not-initialized.
      await expectLater(dsp.reset(), throwsStateError);
    });

    test('zero handle throws PlatformException INIT_FAILED', () async {
      fake.createResult = 0;
      final dsp = AudioDsp();
      await expectLater(
        dsp.init(),
        throwsA(
          isA<PlatformException>()
              .having((e) => e.code, 'code', 'INIT_FAILED'),
        ),
      );
      expect(dsp.isInitialized, isFalse);
    });
  });

  group('configure', () {
    test('sends exact payload with handle and updates state', () async {
      final dsp = await initializedDsp();
      fake.calls.clear();

      await dsp.configure(sampleRate: 32000, channels: 1);

      final configures = fake.callsNamed('configure');
      expect(configures, hasLength(1));
      expect(fake.argsOf(configures.single), {
        'handle': 42,
        'sampleRate': 32000,
        'channels': 1,
      });
      expect(dsp.sampleRate, 32000);
      expect(dsp.channels, 1);
    });

    test('defaults to 48000 Hz stereo', () async {
      final dsp = await initializedDsp(sampleRate: 44100, channels: 1);
      await dsp.configure();
      expect(fake.argsOf(fake.callsNamed('configure').single), {
        'handle': 42,
        'sampleRate': 48000,
        'channels': 2,
      });
    });

    test('uninitialized throws StateError and sends nothing', () async {
      final dsp = AudioDsp();
      await expectLater(dsp.configure(), throwsStateError);
      expect(fake.calls, isEmpty);
    });

    test('uninitialized takes precedence over bad format', () async {
      final dsp = AudioDsp();
      await expectLater(
        dsp.configure(sampleRate: 1, channels: 9),
        throwsStateError,
      );
      expect(fake.calls, isEmpty);
    });

    test('bad format throws ArgumentError, state unchanged', () async {
      final dsp = await initializedDsp(sampleRate: 48000, channels: 2);
      fake.calls.clear();
      await expectLater(
        dsp.configure(sampleRate: 192001),
        throwsArgumentError,
      );
      await expectLater(
        dsp.configure(channels: 3),
        throwsArgumentError,
      );
      expect(fake.calls, isEmpty);
      expect(dsp.sampleRate, 48000);
      expect(dsp.channels, 2);
    });

    test('disposed throws StateError', () async {
      final dsp = await initializedDsp();
      await dsp.dispose();
      await expectLater(dsp.configure(), throwsStateError);
    });
  });

  group('setReverb', () {
    test('sends exact payload with handle and defaults', () async {
      final dsp = await initializedDsp();
      await dsp.setReverb();
      final calls = fake.callsNamed('setReverb');
      expect(calls, hasLength(1));
      expect(fake.argsOf(calls.single), {
        'handle': 42,
        'enabled': true,
        'wetDryMix': 0.3,
        'roomSize': 0.5,
        'damping': 0.5,
      });
    });

    test('enabled=false passes through', () async {
      final dsp = await initializedDsp();
      await dsp.setReverb(enabled: false);
      expect(
        fake.argsOf(fake.callsNamed('setReverb').single)['enabled'],
        isFalse,
      );
    });

    test('clamps wetDryMix/roomSize/damping to 0..1', () async {
      final dsp = await initializedDsp();
      await dsp.setReverb(wetDryMix: -0.5, roomSize: 1.5, damping: 2.0);
      expect(fake.argsOf(fake.callsNamed('setReverb').single), {
        'handle': 42,
        'enabled': true,
        'wetDryMix': 0.0,
        'roomSize': 1.0,
        'damping': 1.0,
      });
    });

    test('boundary values 0.0 and 1.0 pass through unclamped', () async {
      final dsp = await initializedDsp();
      await dsp.setReverb(wetDryMix: 0.0, roomSize: 1.0, damping: 0.0);
      final args = fake.argsOf(fake.callsNamed('setReverb').single);
      expect(args['wetDryMix'], 0.0);
      expect(args['roomSize'], 1.0);
      expect(args['damping'], 0.0);
    });

    test('uninitialized throws StateError', () async {
      final dsp = AudioDsp();
      await expectLater(dsp.setReverb(), throwsStateError);
      expect(fake.calls, isEmpty);
    });
  });

  group('setEcho', () {
    test('sends exact payload with handle and defaults', () async {
      final dsp = await initializedDsp();
      await dsp.setEcho();
      final calls = fake.callsNamed('setEcho');
      expect(calls, hasLength(1));
      expect(fake.argsOf(calls.single), {
        'handle': 42,
        'enabled': true,
        'delayMs': 250.0,
        'feedback': 0.35,
        'mix': 0.35,
      });
    });

    test('clamps delayMs to 1..2000, feedback to 0..0.95, mix to 0..1',
        () async {
      final dsp = await initializedDsp();
      await dsp.setEcho(delayMs: 0.0, feedback: 1.0, mix: -0.2);
      expect(fake.argsOf(fake.callsNamed('setEcho').single), {
        'handle': 42,
        'enabled': true,
        'delayMs': 1.0,
        'feedback': 0.95,
        'mix': 0.0,
      });

      await dsp.setEcho(delayMs: 2001.0, feedback: -0.1, mix: 1.8);
      expect(fake.argsOf(fake.callsNamed('setEcho').last), {
        'handle': 42,
        'enabled': true,
        'delayMs': 2000.0,
        'feedback': 0.0,
        'mix': 1.0,
      });
    });

    test('boundary values pass through unclamped', () async {
      final dsp = await initializedDsp();
      await dsp.setEcho(delayMs: 1.0, feedback: 0.95, mix: 1.0);
      final args = fake.argsOf(fake.callsNamed('setEcho').single);
      expect(args['delayMs'], 1.0);
      expect(args['feedback'], 0.95);
      expect(args['mix'], 1.0);
    });

    test('uninitialized throws StateError', () async {
      final dsp = AudioDsp();
      await expectLater(dsp.setEcho(), throwsStateError);
      expect(fake.calls, isEmpty);
    });
  });

  group('setEq', () {
    test('sends exact payload with handle and defaults', () async {
      final dsp = await initializedDsp();
      await dsp.setEq();
      final calls = fake.callsNamed('setEq');
      expect(calls, hasLength(1));
      expect(fake.argsOf(calls.single), {
        'handle': 42,
        'enabled': true,
        'bassBoostDb': 0.0,
        'lowGainDb': 0.0,
        'midGainDb': 0.0,
        'highGainDb': 0.0,
      });
    });

    test('clamps bassBoost to 0..12 and band gains to -12..12', () async {
      final dsp = await initializedDsp();
      await dsp.setEq(
        bassBoostDb: -3.0,
        lowGainDb: -13.0,
        midGainDb: 13.0,
        highGainDb: 99.0,
      );
      expect(fake.argsOf(fake.callsNamed('setEq').single), {
        'handle': 42,
        'enabled': true,
        'bassBoostDb': 0.0,
        'lowGainDb': -12.0,
        'midGainDb': 12.0,
        'highGainDb': 12.0,
      });

      await dsp.setEq(bassBoostDb: 12.5);
      expect(
        fake.argsOf(fake.callsNamed('setEq').last)['bassBoostDb'],
        12.0,
      );
    });

    test('boundary values pass through unclamped', () async {
      final dsp = await initializedDsp();
      await dsp.setEq(
        bassBoostDb: 12.0,
        lowGainDb: -12.0,
        midGainDb: 12.0,
        highGainDb: -12.0,
      );
      final args = fake.argsOf(fake.callsNamed('setEq').single);
      expect(args['bassBoostDb'], 12.0);
      expect(args['lowGainDb'], -12.0);
      expect(args['midGainDb'], 12.0);
      expect(args['highGainDb'], -12.0);
    });

    test('uninitialized throws StateError', () async {
      final dsp = AudioDsp();
      await expectLater(dsp.setEq(), throwsStateError);
      expect(fake.calls, isEmpty);
    });
  });

  group('process', () {
    test('passes returned bytes through unchanged', () async {
      final dsp = await initializedDsp();
      final input = Uint8List.fromList(<int>[0, 1, 2, 3, 4, 5, 6, 7]);
      fake.processResult = Uint8List.fromList(<int>[9, 8, 7, 6, 5, 4, 3, 2]);

      final output = await dsp.process(input);

      expect(output, fake.processResult);
      final calls = fake.callsNamed('process');
      expect(calls, hasLength(1));
      final args = fake.argsOf(calls.single);
      expect(args['handle'], 42);
      expect(args['pcmBytes'], input);
    });

    test('empty input returns empty output without a channel call', () async {
      final dsp = await initializedDsp();
      final output = await dsp.process(Uint8List(0));
      expect(output, isEmpty);
      expect(fake.callsNamed('process'), isEmpty);
    });

    test('null native result becomes empty output', () async {
      final dsp = await initializedDsp();
      fake.processResult = null;
      final output =
          await dsp.process(Uint8List.fromList(<int>[1, 2, 3, 4]));
      expect(output, isEmpty);
      expect(fake.callsNamed('process'), hasLength(1));
    });

    test('uninitialized throws StateError', () async {
      final dsp = AudioDsp();
      await expectLater(
        dsp.process(Uint8List.fromList(<int>[1, 2])),
        throwsStateError,
      );
      expect(fake.calls, isEmpty);
    });

    test('empty input on uninitialized instance still throws StateError',
        () async {
      // _requireHandle runs before the empty-input fast path.
      final dsp = AudioDsp();
      await expectLater(dsp.process(Uint8List(0)), throwsStateError);
    });
  });

  group('reset', () {
    test('sends reset with handle', () async {
      final dsp = await initializedDsp();
      await dsp.reset();
      final calls = fake.callsNamed('reset');
      expect(calls, hasLength(1));
      expect(fake.argsOf(calls.single), {'handle': 42});
    });

    test('uninitialized throws StateError', () async {
      final dsp = AudioDsp();
      await expectLater(dsp.reset(), throwsStateError);
      expect(fake.calls, isEmpty);
    });
  });

  group('dispose', () {
    test('invokes destroy once with the handle', () async {
      final dsp = await initializedDsp();
      await dsp.dispose();
      final destroys = fake.callsNamed('destroy');
      expect(destroys, hasLength(1));
      expect(fake.argsOf(destroys.single), {'handle': 42});
      expect(dsp.isInitialized, isFalse);
    });

    test('dispose is idempotent — second call sends no destroy', () async {
      final dsp = await initializedDsp();
      await dsp.dispose();
      await dsp.dispose();
      await dsp.dispose();
      expect(fake.callsNamed('destroy'), hasLength(1));
    });

    test('dispose without init sends no destroy and does not throw', () async {
      final dsp = AudioDsp();
      await dsp.dispose();
      expect(fake.calls, isEmpty);
      expect(dsp.isInitialized, isFalse);
    });

    test('every post-dispose call throws StateError', () async {
      final dsp = await initializedDsp();
      await dsp.dispose();
      fake.calls.clear();

      await expectLater(dsp.init(), throwsStateError);
      await expectLater(dsp.configure(), throwsStateError);
      await expectLater(dsp.setReverb(), throwsStateError);
      await expectLater(dsp.setEcho(), throwsStateError);
      await expectLater(dsp.setEq(), throwsStateError);
      await expectLater(
        dsp.process(Uint8List.fromList(<int>[1, 2])),
        throwsStateError,
      );
      await expectLater(dsp.reset(), throwsStateError);

      // No native call leaked out after disposal.
      expect(fake.calls, isEmpty);
    });

    test('dispose after failed init sends no destroy', () async {
      fake.createResult = null;
      final dsp = AudioDsp();
      await expectLater(dsp.init(), throwsA(isA<PlatformException>()));
      fake.calls.clear();
      await dsp.dispose();
      expect(fake.calls, isEmpty);
    });
  });

  group('independent instances', () {
    test('two instances keep separate handles and state', () async {
      fake.createResult = 42;
      final music = AudioDsp();
      await music.init(sampleRate: 48000, channels: 2);
      fake.createResult = 77;
      final voice = AudioDsp();
      await voice.init(sampleRate: 16000, channels: 1);

      await music.setReverb();
      await voice.setEcho();

      expect(
        fake.argsOf(fake.callsNamed('setReverb').single)['handle'],
        42,
      );
      expect(
        fake.argsOf(fake.callsNamed('setEcho').single)['handle'],
        77,
      );
      expect(music.sampleRate, 48000);
      expect(voice.sampleRate, 16000);
      expect(music.channels, 2);
      expect(voice.channels, 1);
    });
  });
}
