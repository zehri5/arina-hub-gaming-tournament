// ARENA HUB #10 AUDIO — RJ STUDIO VOICE MOUNT (2026-11-22): tests
// for the final wiring (lib/screens/room_screen.dart — the RJ voice
// console + mic-processor picker) and the composite kind extension
// in lib/services/dsp_mic_processor.dart.
//
// Covered:
//   (a) the picker maps each kind to the right processor type
//       (DspMicProcessor / RnnoiseMicProcessor / KrispMicProcessor /
//       CompositeMicProcessor / null for Off) — via buildMicProcessor
//       and the rjKindOfSource round-trip;
//   (b) the source cast handles BOTH DspMicProcessor and
//       CompositeMicProcessor (live setters reachable on both;
//       RNNoise / Krisp / Off source -> sliders disabled, no crash);
//   (c) the bass mapping (dB -> EQ preset — see the deviation note
//       below). The RjStudioPanel mount drives setEq directly now,
//       so rjBassEqPreset is a documented mapping pinned here, not
//       a live mount call — group (d) still uses it to pin the
//       exact channel args a preset application sends;
//   (d) the preset values (AudioEffectsPanel.presetValues — the ONE
//       preset definition, still live on the MUSIC mount) and the
//       mic-chain preset arg contract: the exact channel args a
//       preset application sends for Off / Room / Hall;
//   (e) the RjDspMicAdapter: the live DspMicProcessor wrapped as
//       the panel's RjVoiceDsp control plane — all five setters
//       forward to the mic channel, isInitialized mirrors the
//       wrapped processor.
//
// BASS DEVIATION (documented, deliberate): the brief asked for the
// music mount's (dB+12)/24 mapping on the voice side too — but the
// mic chain has NO 0..1 bass setter (its EQ preset takes absolute
// dB: bassBoostDb 0..12, lowGainDb -12..+12), and applying
// (dB+12)/24 here would make the 0 dB slider send +6 dB of bass
// boost (and the Off preset non-flat). The voice mount maps dB to
// the EQ preset instead (positive dB -> bass boost, negative dB ->
// low-band cut, 0 dB -> flat) — see rjBassEqPreset. The test
// 'voice bass at 0 dB is flat' pins the deviation.
//
// No widget tests boot the room screen (too heavy): the wiring
// logic lives in top-level helpers (rjLiveDspSource /
// rjKindOfSource / rjBassEqPreset) tested directly, and the sheet /
// button mounting is pinned by source-invariant tests (same style
// as test/room_rail_order_test.dart).
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:protournament_user/screens/audio_effects_panel.dart';
import 'package:protournament_user/screens/room_screen.dart';
import 'package:protournament_user/services/composite_mic_processor.dart';
import 'package:protournament_user/services/dsp_mic_processor.dart';
import 'package:protournament_user/services/krisp_noise_filter.dart';
import 'package:protournament_user/services/mic_audio_pipeline.dart';
import 'package:protournament_user/services/rnnoise_processor.dart';
import 'package:protournament_user/widgets/rj_studio_panel.dart';

String _read(String path) => File(path).readAsStringSync();

class _FakeNoiseProcessor implements MicNoiseProcessor {
  @override
  Future<bool> initialize() async => true;

  @override
  Future<lk.TrackProcessor<lk.AudioProcessorOptions>?>
  buildProcessor() async => null;

  @override
  Future<void> dispose() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('arena_hub_dsp_mic');
  late List<MethodCall> calls;
  var nativeAvailable = true;

  setUp(() {
    calls = <MethodCall>[];
    nativeAvailable = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          calls.add(call);
          switch (call.method) {
            case 'isAvailable':
              return nativeAvailable;
            case 'init':
            case 'restart':
            case 'setBypass':
              return true;
            case 'framesProcessed':
            case 'lastError':
              return 0;
            default:
              // setEq / setEcho / setReverb / setNoiseGate /
              // setCompressor / destroy / onPublish / onUnpublish:
              // void-style calls, null reply = success.
              return null;
          }
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  List<MethodCall> callsTo(String method) =>
      calls.where((c) => c.method == method).toList();

  group('picker mapping (a)', () {
    test('dsp kind builds a DspMicProcessor', () {
      final processor = buildMicProcessor(MicProcessorKind.dsp);
      expect(processor, isA<DspMicProcessor>());
      expect(
        (processor as DspMicProcessor).eqPreset,
        same(DspMicEqPreset.voice),
      );
    });

    test('rnnoise kind returns the injected RnnoiseMicProcessor', () {
      final rnnoise = RnnoiseMicProcessor();
      expect(
        buildMicProcessor(MicProcessorKind.rnnoise, rnnoise: rnnoise),
        same(rnnoise),
      );
    });

    test('krisp kind returns the injected KrispMicProcessor', () {
      final krisp = KrispMicProcessor();
      expect(
        buildMicProcessor(MicProcessorKind.krisp, krisp: krisp),
        same(krisp),
      );
    });

    test('composite kind returns the injected CompositeMicProcessor',
        () {
      final composite = CompositeMicProcessor();
      expect(
        buildMicProcessor(
          MicProcessorKind.composite,
          composite: composite,
        ),
        same(composite),
      );
    });

    test('composite kind without injection returns null (fail-open)',
        () {
      expect(buildMicProcessor(MicProcessorKind.composite), isNull);
    });

    test('rjKindOfSource round-trips each processor type to its kind',
        () {
      expect(
        rjKindOfSource(DspMicProcessor()),
        MicProcessorKind.dsp,
      );
      expect(
        rjKindOfSource(RnnoiseMicProcessor()),
        MicProcessorKind.rnnoise,
      );
      expect(
        rjKindOfSource(KrispMicProcessor()),
        MicProcessorKind.krisp,
      );
      expect(
        rjKindOfSource(CompositeMicProcessor()),
        MicProcessorKind.composite,
      );
    });

    test('rjKindOfSource(null) is null (Off) and unknown is null', () {
      expect(rjKindOfSource(null), isNull);
      expect(rjKindOfSource(_FakeNoiseProcessor()), isNull);
    });
  });

  group('source cast (b)', () {
    test('DspMicProcessor source resolves to itself, setters live',
        () async {
      final dsp = DspMicProcessor();
      expect(await dsp.initialize(), isTrue);
      calls.clear();
      final resolved = rjLiveDspSource(dsp);
      expect(resolved, same(dsp));
      expect(
        await resolved!.setEcho(delayMs: 250.0, feedback: 0.35, mix: 0.35),
        isTrue,
      );
      final echoCalls = callsTo('setEcho');
      expect(echoCalls, hasLength(1));
      expect(echoCalls.single.arguments, <String, Object>{
        'enabled': true,
        'delayMs': 250.0,
        'feedback': 0.35,
        'mix': 0.35,
      });
      await dsp.dispose();
    });

    test(
        'CompositeMicProcessor source resolves to its DSP child, setters live',
        () async {
      final composite = CompositeMicProcessor();
      expect(await composite.initialize(), isTrue);
      expect(composite.isDspUsable, isTrue);
      calls.clear();
      final resolved = rjLiveDspSource(composite);
      expect(resolved, same(composite.dsp));
      expect(await resolved!.setReverb(wetDryMix: 0.35), isTrue);
      final reverbCalls = callsTo('setReverb');
      expect(reverbCalls, hasLength(1));
      expect(reverbCalls.single.arguments, <String, Object>{
        'enabled': true,
        'wetDryMix': 0.35,
        'roomSize': 0.5,
        'damping': 0.5,
      });
      await composite.dispose();
    });

    test('composite with DSP unusable (native absent) resolves to null',
        () async {
      nativeAvailable = false;
      final composite = CompositeMicProcessor();
      // Initializes (RNNoise side is usable) but the DSP child is not.
      expect(await composite.initialize(), isTrue);
      expect(composite.isDspUsable, isFalse);
      expect(composite.isRnnoiseUsable, isTrue);
      expect(rjLiveDspSource(composite), isNull);
      await composite.dispose();
    });

    test('RnnoiseMicProcessor source resolves to null (no crash)', () {
      expect(rjLiveDspSource(RnnoiseMicProcessor()), isNull);
    });

    test('KrispMicProcessor source resolves to null (no crash)', () {
      expect(rjLiveDspSource(KrispMicProcessor()), isNull);
    });

    test('null source (Off) resolves to null (no crash)', () {
      expect(rjLiveDspSource(null), isNull);
    });

    test('unknown processor source resolves to null (no crash)', () {
      expect(rjLiveDspSource(_FakeNoiseProcessor()), isNull);
    });
  });

  group('voice bass mapping (c)', () {
    test('-12 dB cuts the low band, no bass boost', () {
      final preset = rjBassEqPreset(-12.0, DspMicEqPreset.voice);
      expect(preset.bassBoostDb, 0.0);
      expect(preset.lowGainDb, -12.0);
    });

    test('-6 dB cuts the low band by 6', () {
      final preset = rjBassEqPreset(-6.0, DspMicEqPreset.voice);
      expect(preset.bassBoostDb, 0.0);
      expect(preset.lowGainDb, -6.0);
    });

    test('voice bass at 0 dB is flat (NOT the music (dB+12)/24)', () {
      // Deviation pin: the music mount maps (dB+12)/24 onto a
      // 0..1 playback amount whose 0.5 centre is flat — applied to
      // the mic chain's absolute-dB EQ preset it would send +6 dB
      // of bass boost at the 0 dB slider position. The voice mount
      // must never do that: 0 dB is flat.
      final preset = rjBassEqPreset(0.0, DspMicEqPreset.voice);
      expect(preset.bassBoostDb, 0.0);
      expect(preset.lowGainDb, DspMicEqPreset.voice.lowGainDb);
    });

    test('+3 dB (Room preset bass) becomes bass boost 3', () {
      final preset = rjBassEqPreset(3.0, DspMicEqPreset.voice);
      expect(preset.bassBoostDb, 3.0);
      expect(preset.lowGainDb, DspMicEqPreset.voice.lowGainDb);
    });

    test('+4.5 dB (Hall preset bass) becomes bass boost 4.5', () {
      final preset = rjBassEqPreset(4.5, DspMicEqPreset.voice);
      expect(preset.bassBoostDb, 4.5);
      expect(preset.lowGainDb, DspMicEqPreset.voice.lowGainDb);
    });

    test('+12 dB becomes bass boost 12', () {
      final preset = rjBassEqPreset(12.0, DspMicEqPreset.voice);
      expect(preset.bassBoostDb, 12.0);
    });

    test('out-of-range input clamps to -12..+12', () {
      expect(
        rjBassEqPreset(-20.0, DspMicEqPreset.voice).lowGainDb,
        -12.0,
      );
      expect(
        rjBassEqPreset(20.0, DspMicEqPreset.voice).bassBoostDb,
        12.0,
      );
    });

    test('mid/high bands are preserved from the base preset', () {
      const base = DspMicEqPreset(
        bassBoostDb: 1.0,
        lowGainDb: 1.0,
        midGainDb: 5.0,
        highGainDb: -3.0,
      );
      final preset = rjBassEqPreset(4.0, base);
      expect(preset.midGainDb, 5.0);
      expect(preset.highGainDb, -3.0);
    });
  });

  group('preset values (music mount) + mic-chain preset arg contract (d)', () {
    test('presetValues is the ONE preset definition', () {
      expect(AudioEffectsPanel.presetValues['Off'], <String, double>{
        'reverb': 0.0,
        'echo': 0.0,
        'delayMs': 250.0,
        'bass': 0.0,
      });
      expect(AudioEffectsPanel.presetValues['Room'], <String, double>{
        'reverb': 0.35,
        'echo': 0.15,
        'delayMs': 180.0,
        'bass': 3.0,
      });
      expect(AudioEffectsPanel.presetValues['Hall'], <String, double>{
        'reverb': 0.70,
        'echo': 0.25,
        'delayMs': 350.0,
        'bass': 4.5,
      });
    });

    Future<DspMicProcessor> liveDsp() async {
      final dsp = DspMicProcessor();
      expect(await dsp.initialize(), isTrue);
      calls.clear();
      return dsp;
    }

    /// Applies one preset's values through the resolved DSP handle
    /// exactly the way the old _rjApplyPreset did (same setter
    /// calls, same argument order) — the channel args are the
    /// assertion. _rjApplyPreset is gone (RjStudioPanel owns its
    /// presets now — Radio / Concert / Studio / Off — and pushes
    /// them through the same setters); these tests pin the
    /// mic-chain arg contract a preset application must send.
    Future<void> applyPresetValues(String name, DspMicProcessor dsp) async {
      final values = AudioEffectsPanel.presetValues[name]!;
      final reverb = values['reverb']!;
      final echo = values['echo']!;
      final delayMs = values['delayMs']!;
      final bass = values['bass']!;
      await dsp.setReverb(enabled: reverb > 0, wetDryMix: reverb);
      await dsp.setEcho(enabled: echo > 0, delayMs: delayMs, mix: echo);
      await dsp.setEqPreset(rjBassEqPreset(bass, DspMicEqPreset.voice));
    }

    test('Room preset sends the exact mic-chain args', () async {
      final dsp = await liveDsp();
      await applyPresetValues('Room', dsp);
      expect(callsTo('setReverb').single.arguments, <String, Object>{
        'enabled': true,
        'wetDryMix': 0.35,
        'roomSize': 0.5,
        'damping': 0.5,
      });
      expect(callsTo('setEcho').single.arguments, <String, Object>{
        'enabled': true,
        'delayMs': 180.0,
        'feedback': 0.35,
        'mix': 0.15,
      });
      expect(callsTo('setEq').single.arguments, <String, Object>{
        'enabled': true,
        'bassDb': 3.0,
        'lowDb': 1.0,
        'midDb': 2.0,
        'highDb': 3.0,
      });
      await dsp.dispose();
    });

    test('Hall preset sends the exact mic-chain args', () async {
      final dsp = await liveDsp();
      await applyPresetValues('Hall', dsp);
      expect(callsTo('setReverb').single.arguments, <String, Object>{
        'enabled': true,
        'wetDryMix': 0.70,
        'roomSize': 0.5,
        'damping': 0.5,
      });
      expect(callsTo('setEcho').single.arguments, <String, Object>{
        'enabled': true,
        'delayMs': 350.0,
        'feedback': 0.35,
        'mix': 0.25,
      });
      expect(callsTo('setEq').single.arguments, <String, Object>{
        'enabled': true,
        'bassDb': 4.5,
        'lowDb': 1.0,
        'midDb': 2.0,
        'highDb': 3.0,
      });
      await dsp.dispose();
    });

    test('Off preset sends flat args and bypasses echo/reverb',
        () async {
      final dsp = await liveDsp();
      await applyPresetValues('Off', dsp);
      expect(callsTo('setReverb').single.arguments, <String, Object>{
        'enabled': false,
        'wetDryMix': 0.0,
        'roomSize': 0.5,
        'damping': 0.5,
      });
      expect(callsTo('setEcho').single.arguments, <String, Object>{
        'enabled': false,
        'delayMs': 250.0,
        'feedback': 0.35,
        'mix': 0.0,
      });
      expect(callsTo('setEq').single.arguments, <String, Object>{
        'enabled': true,
        'bassDb': 0.0,
        'lowDb': 1.0,
        'midDb': 2.0,
        'highDb': 3.0,
      });
      await dsp.dispose();
    });
  });

  group('RjDspMicAdapter (e)', () {
    test('adapter satisfies RjVoiceDsp and forwards all five setters',
        () async {
      final dsp = DspMicProcessor();
      expect(await dsp.initialize(), isTrue);
      calls.clear();
      // Typed as the interface — this assignment is the proof the
      // adapter (not the processor itself) is what the panel takes.
      final RjVoiceDsp voice = RjDspMicAdapter(dsp);
      expect(voice.isInitialized, isTrue);
      await voice.setEq(
        bassBoostDb: 2.0,
        lowGainDb: -1.0,
        midGainDb: 3.0,
        highGainDb: 4.0,
      );
      await voice.setEcho(delayMs: 400.0, feedback: 0.5, mix: 0.6);
      await voice.setReverb(wetDryMix: 0.7, roomSize: 0.8, damping: 0.2);
      await voice.setNoiseGate(
        thresholdDb: -30.0,
        attackMs: 10.0,
        releaseMs: 200.0,
      );
      await voice.setCompressor(
        thresholdDb: -20.0,
        ratio: 3.0,
        attackMs: 5.0,
        releaseMs: 200.0,
        makeupGainDb: 6.0,
      );
      // EQ goes out on the MIC channel with the KOTLIN keys
      // (bassDb/lowDb/midDb/highDb) — NOT the AudioDsp plugin's
      // bassBoostDb/lowGainDb keys: the adapter forwards to the
      // mic chain, never to the playback engine.
      expect(callsTo('setEq').single.arguments, <String, Object>{
        'enabled': true,
        'bassDb': 2.0,
        'lowDb': -1.0,
        'midDb': 3.0,
        'highDb': 4.0,
      });
      expect(callsTo('setEcho').single.arguments, <String, Object>{
        'enabled': true,
        'delayMs': 400.0,
        'feedback': 0.5,
        'mix': 0.6,
      });
      expect(callsTo('setReverb').single.arguments, <String, Object>{
        'enabled': true,
        'wetDryMix': 0.7,
        'roomSize': 0.8,
        'damping': 0.2,
      });
      expect(callsTo('setNoiseGate').single.arguments, <String, Object>{
        'enabled': true,
        'thresholdDb': -30.0,
        'attackMs': 10.0,
        'releaseMs': 200.0,
      });
      expect(callsTo('setCompressor').single.arguments, <String, Object>{
        'enabled': true,
        'thresholdDb': -20.0,
        'ratio': 3.0,
        'attackMs': 5.0,
        'releaseMs': 200.0,
        'makeupGainDb': 6.0,
      });
      await dsp.dispose();
    });

    test('adapter isInitialized mirrors the wrapped processor', () async {
      final dsp = DspMicProcessor();
      final RjVoiceDsp voice = RjDspMicAdapter(dsp);
      expect(voice.isInitialized, isFalse);
      expect(await dsp.initialize(), isTrue);
      expect(voice.isInitialized, isTrue);
      await dsp.dispose();
      expect(voice.isInitialized, isFalse);
    });
  });

  group('mount source pins', () {
    late String room;

    setUpAll(() {
      room = _read('lib/screens/room_screen.dart');
    });

    String region(String startMarker, String endMarker) {
      final start = room.indexOf(startMarker);
      expect(start, isNot(-1), reason: 'missing $startMarker');
      final end = room.indexOf(endMarker, start);
      expect(end, isNot(-1), reason: 'missing $endMarker');
      return room.substring(start, end);
    }

    test('voice console mounts RjStudioPanel via the adapter; old mount gone',
        () {
      // FIX 22 item 21: the console signature carries
      // initialSection now, and the old end marker (the
      // _showMusicSettings comment) is gone with the dialog —
      // the region ends at the deletion note instead.
      final sheet = region(
        'Future<void> _showRjVoiceConsole(',
        '// FIX 22 item 22: _showMusicSettings is DELETED',
      );
      // The new mount: the panel, driven by the adapter-wrapped
      // live DSP — never a bare DspMicProcessor (Dart is nominally
      // typed; the adapter is the RjVoiceDsp).
      expect(sheet, contains('RjStudioPanel('));
      expect(sheet, contains('dsp: voiceDsp'));
      expect(sheet, contains('RjDspMicAdapter(liveDsp)'));
      // AudioEffectsPanel is NOT in the voice console any more...
      expect(sheet, isNot(contains('AudioEffectsPanel(')));
      // ...and it is NOT in the music sheet any more either — the
      // Group 9 panel replaced it there (MusicPlayerPanel,
      // exactly one construction in the whole file; the widget
      // file stays in the tree and its own tests still run).
      // The voice console is still the only RjStudioPanel
      // construction.
      expect('AudioEffectsPanel('.allMatches(room).length, 0);
      expect('MusicPlayerPanel('.allMatches(room).length, 1);
      expect('RjStudioPanel('.allMatches(room).length, 1);
      // The adapter class itself exists and implements the panel's
      // control plane.
      expect(
        room,
        contains('class RjDspMicAdapter implements RjVoiceDsp'),
      );
      // The old mount is gone: no _rjApplyPreset, no _rj* mirror
      // fields — the panel owns its knob/preset/fader state now.
      expect(room, isNot(contains('_rjApplyPreset')));
      expect(room, isNot(contains('_rjReverb')));
      expect(room, isNot(contains('_rjEcho')));
      expect(room, isNot(contains('_rjDelayMs')));
      expect(room, isNot(contains('_rjBass')));
      expect(room, isNot(contains('_rjPreset')));
      expect(room, isNot(contains('_rjEqPreset')));
      expect(room, isNot(contains('_rjNoiseGateThreshold')));
      expect(room, isNot(contains('_rjCompressorThreshold')));
      expect(room, isNot(contains('_rjCompressorRatio')));
      expect(room, isNot(contains('_rjNoiseCancellation')));
      // ...but the two survivors stay: the noise-gate toggle
      // mirror (a panel prop) and the picker guard.
      expect(room, contains('_rjNoiseGateEnabled'));
      expect(room, contains('_rjSwitchingProcessor'));
    });

    test('console music section mounts MusicPlayerPanel with DSP + voice wiring',
        () {
      // FIX 22 item 21: the standalone player sheet
      // (_showMusicPlayer) is RETIRED — the player lives
      // inside the RJ console now (_buildConsoleMusicSection,
      // below the effects panel). The mount pins below are
      // unchanged; the sheet pins are replaced by section pins
      // (no sheet of its own, no Settings dialog any more).
      final section = region(
        'Widget _buildConsoleMusicSection(',
        'DspMicProcessor? _rjLiveDsp()',
      );
      // The mount: one MusicPlayerPanel, driven by the player's
      // position/duration streams (same nesting as the old sheet).
      expect(section, contains('MusicPlayerPanel('));
      expect(section, contains('StreamBuilder<Duration>('));
      expect(section, contains('stream: _musicPlayer!.positionStream'));
      expect(section, contains('stream: _musicPlayer!.durationStream'));
      // Transport: the real helpers, not local stubs.
      expect(section, contains('await _pauseResumeMusic();'));
      expect(section, contains('await _playPrevNext(-1);'));
      expect(section, contains('await _playPrevNext(1);'));
      expect(section, contains('isRepeat: _musicRepeat'));
      expect(section, contains('await _stopMusic();'));
      expect(section, contains('onPlaylist:'));
      expect(section, contains('_showMusicPanel();'));
      // FIX 22 item 21: onStop stops the music WITHOUT popping
      // (the console stays open); onPlaylist pops the CONSOLE
      // sheet (sheetCtx), then opens the library.
      expect(section, contains('Navigator.pop(sheetCtx)'));
      expect(section, isNot(contains('Navigator.pop(ctx)')));
      // FIX 22 item 22: no Settings dialog anywhere in the
      // section (GO LIVE owns hosting now).
      expect(section, isNot(contains('onSettings')));
      expect(section, isNot(contains('_showMusicSettings')));
      // Music effects: the _fx state + MusicFx on the music
      // player's own DSP instance (Group 2 swap) — the old
      // PlaybackEffects / session-0 path is gone. MUSIC DSP SWAP
      // GROUP 1 (2026-11-22): loop is mount-side, so there is no
      // setReleaseMode in the sheet any more.
      expect(section, contains('reverb: _fxReverb'));
      expect(section, contains('preset: _fxPreset'));
      expect(section, contains('AudioEffectsPanel.presetValues[name]'));
      expect(section, contains('final dsp = _musicDsp();'));
      expect(section, contains('await MusicFx.applyReverb(dsp, v);'));
      expect(section, contains('await MusicFx.applyEcho(dsp, v, _fxDelayMs);'));
      expect(section, contains('await MusicFx.applyEcho(dsp, _fxEcho, v);'));
      expect(section, contains('await MusicFx.applyBass(dsp, v);'));
      expect(section, contains('await MusicFx.applyPreset(dsp, values);'));
      expect(section, isNot(contains('attachToPlayer')));
      expect(section, isNot(contains('playbackEffects.')));
      expect(section, isNot(contains('bassEffect.setBass')));
      expect(section, isNot(contains('setReleaseMode')));
      // Voice chain: NC through the voice service, gate/compressor
      // through the live DSP setters, fail-open on null DSP.
      expect(
        section,
        contains('await _lkRoom.setNoiseCancellationEnabled(v);'),
      );
      expect(section, contains('final dsp = _rjLiveDsp();'));
      expect(section, contains('await dsp.setNoiseGate('));
      expect(section, contains('await dsp.setCompressor('));
      expect(section, contains('if (dsp != null)'));
      // Listeners: live count + avatar URLs + the detail sheet.
      expect(section, contains('listenerCount: _liveListeners.listenerCount'));
      expect(
        section,
        contains('listenerAvatarUrls: _liveListeners.listeners'),
      );
      expect(section, contains('showListenersDetailSheet('));
      // The section is NOT a sheet: no showModalBottomSheet of
      // its own — the console owns the sheet, the section is a
      // plain widget inside it (mounted below the panel).
      expect(section, isNot(contains('showModalBottomSheet')));
      expect(room, contains('_buildConsoleMusicSection(sheetCtx, refresh)'));
      // The old mount is gone from the section.
      expect(section, isNot(contains('AudioEffectsPanel(')));
      // The standalone player is gone from the whole file.
      expect(room, isNot(contains('Future<void> _showMusicPlayer()')));
    });

    test('voice console sheet is scrollable + host-gated', () {
      final sheet = region(
        'Future<void> _showRjVoiceConsole(',
        '// FIX 22 item 22: _showMusicSettings is DELETED',
      );
      expect(sheet, contains('isScrollControlled: true'));
      expect(sheet, contains('SingleChildScrollView('));
      // FIX 20 (fix 7b): RJ is for the ROOM HOST (admin / team
      // captain / community organizer) — not admin-only.
      expect(
          sheet,
          contains(
              'isHost: _isAdminForBroadcast ||\n                                _isTeamCaptainForBroadcast ||\n                                _isCommunityOrganizerForBroadcast,'));
      // FIX 22 item 6: the gate never fails silently — a pending
      // identity load gets the wait toast, a loaded non-host
      // gets the host-only toast (the old silent early-return
      // block is gone).
      expect(sheet, contains('_rjHostGatePasses'));
      expect(
          sheet,
          contains(
              'Pehchan load ho rahi hai — thora ruk kar dobara koshish karein.'));
      expect(sheet, contains('RJ panel sirf room host ke liye hai.'));
      expect(
          sheet,
          isNot(contains(
              'if (!_isAdminForBroadcast &&\n        !_isTeamCaptainForBroadcast &&\n        !_isCommunityOrganizerForBroadcast) {\n      return;\n    }')));
    });

    test('voice console carries processor buttons + Urdu DSP note + always-built panel',
        () {
      // FIX 22 items 6 + 20: the dropdown is replaced by five
      // processor buttons (first section), the English note by
      // the Urdu DSP message, and the panel builds ALWAYS
      // (dsp nullable) instead of only with a live DSP.
      final sheet = region(
        'Future<void> _showRjVoiceConsole(',
        '// FIX 22 item 22: _showMusicSettings is DELETED',
      );
      expect(sheet, isNot(contains('DropdownButton<MicProcessorKind?>')));
      expect(sheet, contains('processorBtn(MicProcessorKind.rnnoise'));
      // The DSP call spans lines (long disabled-reason ternary),
      // so pin its parts separately.
      expect(sheet, contains('MicProcessorKind.dsp,'));
      expect('processorBtn('.allMatches(sheet).length, 6);
      expect(sheet, contains('MicProcessorKind.krisp'));
      expect(sheet, contains('may not work on our server'));
      expect(sheet, contains('_rjSwitchMicProcessor(kind)'));
      expect(sheet, contains('_rjDspMissingMessage()'));
      expect(sheet, contains('dsp: voiceDsp'));
      expect(sheet, isNot(contains('if (voiceDsp != null)')));
      expect(sheet, isNot(contains('switch the mic processor above to DSP')));
      expect(sheet, isNot(contains('IgnorePointer(')));
    });

    test('rail RJ Studio button exists, host-only, before Leave Room',
        () {
      final rail = region(
        'Widget _navRail()',
        '// Circular floating rail button',
      );
      final rjAt = rail.indexOf(
        "_railBtn(Icons.graphic_eq, 'RJ Studio', _showRjVoiceConsole)",
      );
      expect(rjAt, isNot(-1), reason: 'missing RJ Studio rail button');
      // FIX 20 (fix 7b): the rail gate is the ROOM HOST check
      // (admin / team captain / community organizer).
      final gateAt = rail.lastIndexOf(
        'if (_isAdminForBroadcast ||\n              _isTeamCaptainForBroadcast ||\n              _isCommunityOrganizerForBroadcast)',
        rjAt,
      );
      expect(gateAt, isNot(-1), reason: 'RJ button is not host-gated');
      expect(rjAt - gateAt, lessThan(300));
      final musicAt = rail.indexOf("_railBtn(Icons.music_note, 'Music'");
      final leaveAt =
          rail.indexOf("_railBtn(Icons.exit_to_app, 'Leave Room'");
      expect(musicAt, lessThan(rjAt), reason: 'RJ must sit after Music');
      expect(rjAt, lessThan(leaveAt), reason: 'Leave Room stays last');
    });

    test('embedded RJ button exists and is host-only', () {
      // FIX 16 (2026-11-23): the embedded RJ button moved from the
      // host card's compact controls row into the header Settings
      // sheet — the room binds _showRjVoiceConsole into the voice
      // controller with the same host gate (rjVisible).
      final bind = region(
        'void _bindVoiceController()',
        'void didUpdateWidget(',
      );
      final rjAt = bind.indexOf(
        "onRjConsole: _showRjVoiceConsole",
      );
      expect(rjAt, isNot(-1), reason: 'missing embedded RJ binding');
      // FIX 20 (fix 7b): the binding gate is the ROOM HOST check
      // (admin / team captain / community organizer).
      final gateAt = bind.indexOf(
        'rjVisible: () =>\n          _isAdminForBroadcast ||\n          _isTeamCaptainForBroadcast ||\n          _isCommunityOrganizerForBroadcast,',
      );
      expect(gateAt, isNot(-1), reason: 'RJ binding is not host-gated');
      // FIX 22: the bind method grew (the Music entry's console
      // closure + the Leave-menu comment), so the proximity
      // bound is 600, not 300 — the gate is still in the same
      // bind call, which is the real pin.
      expect((gateAt - rjAt).abs(), lessThan(600));
    });
  });

  group('soundboard mount source pins', () {
    late String room;
    late String micProcessor;
    late String kotlin;
    late String soundboard;

    setUpAll(() {
      room = _read('lib/screens/room_screen.dart');
      micProcessor = _read('lib/services/dsp_mic_processor.dart');
      kotlin = _read(
        'android/app/src/main/kotlin/com/protournament/app/DspMicProcessor.kt',
      );
      soundboard = _read('lib/audio/soundboard.dart');
    });

    test('room screen owns the Soundboard (field + init + dispose)', () {
      expect(room, contains("import '../audio/soundboard.dart';"));
      expect(room, contains('late final Soundboard _soundboard;'));
      expect(room, contains('_soundboard = Soundboard();'));
      expect(room, contains('_soundboard.dispose();'));
      // NOT the voice service: it sits exactly at its surgical
      // line bound (530 < 531) — the soundboard is a
      // console-mount concern (SOUNDBOARD_INTEGRATION.md §5
      // deviation, documented in the field comment).
      final service =
          _read('lib/services/livekit_voice_service.dart');
      expect(service, isNot(contains('Soundboard')));
    });

    test('tap flow awaits init, plays, pushes, plays live', () {
      final flow = room.substring(
        room.indexOf('Future<void> _playSoundboardPad(SoundPad pad)'),
      );
      expect(flow, contains('await _soundboard.init();'));
      expect(flow, contains('_soundboard.play(pad);'));
      expect(flow, contains('_soundboard.decodedClip(pad)'));
      expect(flow, contains('final dsp = _rjLiveDsp();'));
      expect(flow, contains('dsp.pushSoundboardClip(clip)'));
      expect(flow, contains('dsp.playSoundboardClip('));
      expect(flow, contains('_soundboard.gainFor(pad)'));
    });

    test('panel prop wires onSoundboard with drum -> drumRoll', () {
      expect(room, contains('onSoundboard: (pad) => _playSoundboardPad('));
      expect(room, contains('RjSoundboardPad.applause =>'));
      expect(room, contains('RjSoundboardPad.airHorn =>'));
      expect(room, contains('RjSoundboardPad.laugh => SoundPad.laugh'));
      expect(room, contains('RjSoundboardPad.drum => SoundPad.drumRoll'));
      // The "onSoundboard: omitted (null)" TODO is gone.
      expect(room, isNot(contains('no Soundboard service exists yet')));
    });

    test('Dart control plane has the four soundboard methods', () {
      expect(
        micProcessor,
        contains('Future<bool> pushSoundboardClip('),
      );
      expect(micProcessor, contains("'loadSoundboardClip'"));
      expect(
        micProcessor,
        contains('Future<bool> playSoundboardClip('),
      );
      expect(micProcessor, contains("'playSoundboardClip'"));
      expect(
        micProcessor,
        contains('Future<bool> stopSoundboardClip('),
      );
      expect(micProcessor, contains("'stopSoundboardClip'"));
      expect(
        micProcessor,
        contains('Future<bool> setSoundboardClipGain('),
      );
      expect(micProcessor, contains("'setSoundboardClipGain'"));
    });

    test('Kotlin control plane has the four natives + four cases', () {
      expect(kotlin, contains('nativeLoadSoundboardClip('));
      expect(kotlin, contains('nativePlaySoundboardClip('));
      expect(kotlin, contains('nativeStopSoundboardClip('));
      expect(kotlin, contains('nativeSetSoundboardClipGain('));
      expect(kotlin, contains('"loadSoundboardClip"'));
      expect(kotlin, contains('"playSoundboardClip"'));
      expect(kotlin, contains('"stopSoundboardClip"'));
      expect(kotlin, contains('"setSoundboardClipGain"'));
    });

    test('gainFor exposes pad x master gain', () {
      expect(
        soundboard,
        contains('double gainFor(SoundPad pad) => _computeGain(pad);'),
      );
    });
  });
}
