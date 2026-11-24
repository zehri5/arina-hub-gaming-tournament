// ARENA HUB #10 AUDIO — MUSIC FX RE-ATTACH (Group 2 swap,
// 2026-11-22): tests for lib/audio/music_fx.dart (the _fx music
// effects driven onto the MusicDspPlayer's OWN AudioDsp instance)
// + source pins for the mount wiring in room_screen.dart.
//
// Covered:
//   (a) the bass mapping: positive dB -> bass boost, negative dB ->
//       low-band cut, 0 dB -> flat (same mapping as the voice
//       chain's rjBassEqPreset — NOT the old (dB+12)/24 mapping,
//       which would send +6 dB at 0 dB on this engine; see
//       MusicFx's doc + the BASS DEVIATION note in
//       test/rj_voice_mount_test.dart);
//   (b) knob callback -> DSP setter called with the mapped value
//       (mocked 'com.arenahub.app/audio_dsp' channel, same pattern
//       as test/audio_dsp_wrapper_test.dart);
//   (c) preset application (AudioEffectsPanel.presetValues — the
//       ONE preset definition) mirrors into the engine: Off stays
//       flat, Room/Hall push their values;
//   (d) fail-open: an uninitialized DSP means no channel call and
//       no throw;
//   (e) the mount wiring pins (room_screen.dart source): the _fx
//       handlers drive MusicFx through _musicDsp(), which reads
//       Group 1's `_musicPlayer` (MusicDspPlayer) — and the old
//       PlaybackEffects / session-0 path is gone.
//
// No widget tests boot the room screen (too heavy): the wiring
// logic lives in MusicFx (tested directly) and the mount is pinned
// by source-invariant tests (same style as
// test/rj_voice_mount_test.dart).
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/audio/audio_dsp.dart';
import 'package:protournament_user/audio/music_fx.dart';
import 'package:protournament_user/screens/audio_effects_panel.dart';

const MethodChannel _channel = MethodChannel('com.arenahub.app/audio_dsp');

/// Records every MethodCall and serves a canned 'create' handle.
class _FakeDspChannel {
  final List<MethodCall> calls = <MethodCall>[];
  int? createResult = 42;

  Future<dynamic> handler(MethodCall call) async {
    calls.add(call);
    if (call.method == 'create') return createResult;
    return null;
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

  Future<AudioDsp> initializedDsp() async {
    final dsp = AudioDsp();
    await dsp.init(sampleRate: 48000, channels: 2);
    fake.calls.clear();
    return dsp;
  }

  group('bass mapping', () {
    test('positive dB becomes bass boost only', () {
      expect(MusicFx.bassBoostDb(3.0), 3.0);
      expect(MusicFx.bassBoostDb(12.0), 12.0);
      expect(MusicFx.bassBoostDb(0.0), 0.0);
      expect(MusicFx.bassBoostDb(-6.0), 0.0);
      expect(MusicFx.bassLowGainDb(3.0), 0.0);
      expect(MusicFx.bassLowGainDb(12.0), 0.0);
    });

    test('negative dB cuts the low band only', () {
      expect(MusicFx.bassLowGainDb(-3.0), -3.0);
      expect(MusicFx.bassLowGainDb(-12.0), -12.0);
      expect(MusicFx.bassLowGainDb(0.0), 0.0);
      expect(MusicFx.bassLowGainDb(-6.0), -6.0);
      expect(MusicFx.bassBoostDb(-3.0), 0.0);
      expect(MusicFx.bassBoostDb(-12.0), 0.0);
    });

    test('music bass at 0 dB is flat', () {
      // Pins the deviation from the old (dB+12)/24 mapping: 0 dB
      // must NOT send +6 dB of boost (see MusicFx's doc).
      expect(MusicFx.bassBoostDb(0.0), 0.0);
      expect(MusicFx.bassLowGainDb(0.0), 0.0);
    });

    test('out-of-range and NaN inputs are safe', () {
      expect(MusicFx.bassBoostDb(99.0), 12.0);
      expect(MusicFx.bassLowGainDb(-99.0), -12.0);
      expect(MusicFx.bassBoostDb(double.nan), 0.0);
      expect(MusicFx.bassLowGainDb(double.nan), 0.0);
    });
  });

  group('knob callback -> DSP setter', () {
    test('reverb knob drives setReverb with the amount', () async {
      final dsp = await initializedDsp();
      await MusicFx.applyReverb(dsp, 0.6);
      final calls = fake.callsNamed('setReverb');
      expect(calls, hasLength(1));
      final args = fake.argsOf(calls.single);
      expect(args['handle'], 42);
      expect(args['enabled'], isTrue);
      expect(args['wetDryMix'], 0.6);
    });

    test('reverb at 0 disables the effect', () async {
      final dsp = await initializedDsp();
      await MusicFx.applyReverb(dsp, 0.0);
      final args = fake.argsOf(fake.callsNamed('setReverb').single);
      expect(args['enabled'], isFalse);
      expect(args['wetDryMix'], 0.0);
    });

    test('echo knob drives setEcho with amount + delay', () async {
      final dsp = await initializedDsp();
      await MusicFx.applyEcho(dsp, 0.4, 300.0);
      final calls = fake.callsNamed('setEcho');
      expect(calls, hasLength(1));
      final args = fake.argsOf(calls.single);
      expect(args['handle'], 42);
      expect(args['enabled'], isTrue);
      expect(args['mix'], 0.4);
      expect(args['delayMs'], 300.0);
    });

    test('echo at 0 disables but still pushes the delay', () async {
      final dsp = await initializedDsp();
      await MusicFx.applyEcho(dsp, 0.0, 250.0);
      final args = fake.argsOf(fake.callsNamed('setEcho').single);
      expect(args['enabled'], isFalse);
      expect(args['mix'], 0.0);
      expect(args['delayMs'], 250.0);
    });

    test('bass knob +dB drives setEq boost', () async {
      final dsp = await initializedDsp();
      await MusicFx.applyBass(dsp, 3.0);
      final calls = fake.callsNamed('setEq');
      expect(calls, hasLength(1));
      final args = fake.argsOf(calls.single);
      expect(args['handle'], 42);
      expect(args['enabled'], isTrue);
      expect(args['bassBoostDb'], 3.0);
      expect(args['lowGainDb'], 0.0);
    });

    test('bass knob -dB drives setEq low-band cut', () async {
      final dsp = await initializedDsp();
      await MusicFx.applyBass(dsp, -6.0);
      final args = fake.argsOf(fake.callsNamed('setEq').single);
      expect(args['enabled'], isTrue);
      expect(args['bassBoostDb'], 0.0);
      expect(args['lowGainDb'], -6.0);
    });

    test('bass knob at 0 dB disables the EQ (flat)', () async {
      final dsp = await initializedDsp();
      await MusicFx.applyBass(dsp, 0.0);
      final args = fake.argsOf(fake.callsNamed('setEq').single);
      expect(args['enabled'], isFalse);
      expect(args['bassBoostDb'], 0.0);
      expect(args['lowGainDb'], 0.0);
    });
  });

  group('preset application', () {
    test('Room preset pushes reverb + echo + bass gain', () async {
      final dsp = await initializedDsp();
      await MusicFx.applyPreset(
        dsp,
        AudioEffectsPanel.presetValues['Room']!,
      );
      final reverb = fake.argsOf(fake.callsNamed('setReverb').single);
      expect(reverb['enabled'], isTrue);
      expect(reverb['wetDryMix'], 0.35);
      final echo = fake.argsOf(fake.callsNamed('setEcho').single);
      expect(echo['enabled'], isTrue);
      expect(echo['mix'], 0.15);
      expect(echo['delayMs'], 180.0);
      final eq = fake.argsOf(fake.callsNamed('setEq').single);
      expect(eq['enabled'], isTrue);
      expect(eq['bassBoostDb'], 3.0);
      expect(eq['lowGainDb'], 0.0);
    });

    test('Hall preset pushes its values', () async {
      final dsp = await initializedDsp();
      await MusicFx.applyPreset(
        dsp,
        AudioEffectsPanel.presetValues['Hall']!,
      );
      final reverb = fake.argsOf(fake.callsNamed('setReverb').single);
      expect(reverb['wetDryMix'], 0.70);
      final echo = fake.argsOf(fake.callsNamed('setEcho').single);
      expect(echo['mix'], 0.25);
      expect(echo['delayMs'], 350.0);
      final eq = fake.argsOf(fake.callsNamed('setEq').single);
      expect(eq['bassBoostDb'], 4.5);
    });

    test('Off preset is fully flat', () async {
      final dsp = await initializedDsp();
      await MusicFx.applyPreset(
        dsp,
        AudioEffectsPanel.presetValues['Off']!,
      );
      expect(
        fake.argsOf(fake.callsNamed('setReverb').single)['enabled'],
        isFalse,
      );
      expect(
        fake.argsOf(fake.callsNamed('setEcho').single)['enabled'],
        isFalse,
      );
      final eq = fake.argsOf(fake.callsNamed('setEq').single);
      expect(eq['enabled'], isFalse);
      expect(eq['bassBoostDb'], 0.0);
      expect(eq['lowGainDb'], 0.0);
    });
  });

  group('fail-open', () {
    test('uninitialized DSP: no channel call, no throw', () async {
      final dsp = AudioDsp(); // never init()ed
      await MusicFx.applyReverb(dsp, 0.6);
      await MusicFx.applyEcho(dsp, 0.4, 300.0);
      await MusicFx.applyBass(dsp, 3.0);
      await MusicFx.applyPreset(
        dsp,
        AudioEffectsPanel.presetValues['Room']!,
      );
      expect(fake.calls, isEmpty);
    });
  });

  group('mount wiring pins (room_screen.dart source)', () {
    late String room;

    setUpAll(() {
      room = File('lib/screens/room_screen.dart').readAsStringSync();
    });

    test('the _fx handlers drive MusicFx through _musicDsp()', () {
      // Group 1's field: _musicPlayer IS the MusicDspPlayer now
      // (reused name, new type) — _musicDsp() reads its `.dsp`.
      expect(room, contains('MusicDspPlayer? _musicPlayer;'));
      expect(room, contains('AudioDsp? _musicDsp()'));
      expect(room, contains('final player = _musicPlayer;'));
      expect(room, contains('final dsp = _musicDsp();'));
      expect(room, contains('await MusicFx.applyReverb(dsp, v);'));
      expect(room, contains('await MusicFx.applyEcho(dsp, v, _fxDelayMs);'));
      expect(room, contains('await MusicFx.applyEcho(dsp, _fxEcho, v);'));
      expect(room, contains('await MusicFx.applyBass(dsp, v);'));
      expect(room, contains('await MusicFx.applyPreset(dsp, values);'));
      expect(room, contains('AudioEffectsPanel.presetValues[name]'));
    });

    test('the old PlaybackEffects / session-0 path is gone', () {
      expect(room, isNot(contains('_ensureAudioEffects')));
      expect(room, isNot(contains('_fxPlayback')));
      expect(room, isNot(contains('attachToPlayer')));
      expect(room, isNot(contains('playbackEffects.applyPreset')));
      expect(room, isNot(contains('bassEffect.setBass')));
      expect(room, isNot(contains('reverbEffect.setAmount')));
      expect(room, isNot(contains('echoEffect.setEcho')));
    });
  });
}
