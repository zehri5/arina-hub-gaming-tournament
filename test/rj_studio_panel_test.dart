// RJ STUDIO PANEL TESTS — Group 9 restyle (2026-11-22), control-plane
// adaptation (AUDIO #10 mount, 2026-11-22).
//
// Widget tests for lib/widgets/rj_studio_panel.dart against a FAKE
// [RjVoiceDsp] that records every setter call — no MethodChannel,
// no native code runs here. The fake is the interface proof: the
// panel drives the control plane, not a concrete engine. (The
// original version mocked the AudioDsp channel; the channel
// assertions became interface-call assertions with the same mapped
// values.) Proves the LOCKED-design console renders (6 knobs, 4
// soundboard pads, 3 faders, noise-gate toggle, listeners count,
// guest strip, Now Playing, GO LIVE + Mute), that knob drags +
// presets drive the voice DSP with the right mapped values, and
// that the host-only lock holds for non-hosts.
//
// NOTE: the panel is a tall console (~1100 px), so every test pumps
// it on a tall test surface (390x2000) instead of inside a scroll
// view — a vertical ScrollView would steal the knobs'/faders'
// vertical drags in the gesture arena. The v2 merge (2026-11-22,
// RJ_PANEL_INTEGRATION.md §8) added 3 tests for the ported
// behaviour: fader tap-to-jump, a narrow 320 px surface, and the
// spectrumStream prop (23 tests total).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/widgets/rj_studio_panel.dart';

/// Fake RjVoiceDsp: records every setter call as a MethodCall with
/// the panel's named args, so the mapped-value assertions read
/// exactly like the old channel assertions.
class _FakeRjDsp implements RjVoiceDsp {
  final List<MethodCall> calls = <MethodCall>[];

  @override
  bool isInitialized = true;

  @override
  Future<void> setEq({
    bool enabled = true,
    double bassBoostDb = 0.0,
    double lowGainDb = 0.0,
    double midGainDb = 0.0,
    double highGainDb = 0.0,
  }) async {
    calls.add(MethodCall('setEq', <String, Object>{
      'enabled': enabled,
      'bassBoostDb': bassBoostDb,
      'lowGainDb': lowGainDb,
      'midGainDb': midGainDb,
      'highGainDb': highGainDb,
    }));
  }

  @override
  Future<void> setEcho({
    bool enabled = true,
    double delayMs = 250.0,
    double feedback = 0.35,
    double mix = 0.35,
  }) async {
    calls.add(MethodCall('setEcho', <String, Object>{
      'enabled': enabled,
      'delayMs': delayMs,
      'feedback': feedback,
      'mix': mix,
    }));
  }

  @override
  Future<void> setReverb({
    bool enabled = true,
    double wetDryMix = 0.3,
    double roomSize = 0.5,
    double damping = 0.5,
  }) async {
    calls.add(MethodCall('setReverb', <String, Object>{
      'enabled': enabled,
      'wetDryMix': wetDryMix,
      'roomSize': roomSize,
      'damping': damping,
    }));
  }

  @override
  Future<void> setNoiseGate({
    bool enabled = true,
    double thresholdDb = -40.0,
    double attackMs = 5.0,
    double releaseMs = 120.0,
  }) async {
    calls.add(MethodCall('setNoiseGate', <String, Object>{
      'enabled': enabled,
      'thresholdDb': thresholdDb,
      'attackMs': attackMs,
      'releaseMs': releaseMs,
    }));
  }

  @override
  Future<void> setCompressor({
    bool enabled = true,
    double thresholdDb = -18.0,
    double ratio = 4.0,
    double attackMs = 10.0,
    double releaseMs = 100.0,
    double makeupGainDb = 0.0,
  }) async {
    calls.add(MethodCall('setCompressor', <String, Object>{
      'enabled': enabled,
      'thresholdDb': thresholdDb,
      'ratio': ratio,
      'attackMs': attackMs,
      'releaseMs': releaseMs,
      'makeupGainDb': makeupGainDb,
    }));
  }

  List<MethodCall> callsNamed(String method) =>
      calls.where((c) => c.method == method).toList();

  Map<String, dynamic> lastArgs(String method) {
    final found = callsNamed(method);
    expect(found, isNotEmpty, reason: 'expected a $method call');
    return Map<String, dynamic>.from(found.last.arguments as Map);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeRjDsp fake;

  _FakeRjDsp initializedDsp() {
    fake = _FakeRjDsp();
    return fake;
  }

  /// Tall surface so the whole console fits without a scroll view
  /// (which would steal vertical knob/fader drags).
  void setTallSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(390, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  /// Narrow phone width (320 px) on the same tall surface — the
  /// overflow check for the chassis-wrapped console.
  void setNarrowSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(320, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

  Future<void> pumpPanel(
    WidgetTester tester, {
    required RjVoiceDsp dsp,
    bool isHost = true,
    String hostName = 'RJ Sameer',
    bool isLive = false,
    bool isMuted = false,
    VoidCallback? onGoLivePressed,
    VoidCallback? onMutePressed,
    int listenerCount = 0,
    VoidCallback? onListenersTap,
    String? guestName,
    double guestLevel = 0.0,
    Duration liveElapsed = Duration.zero,
    String? nowPlayingTitle,
    Duration nowPlayingPosition = Duration.zero,
    Duration nowPlayingDuration = Duration.zero,
    ValueChanged<double>? onMicVolume,
    ValueChanged<double>? onGuestVolume,
    ValueChanged<double>? onMusicVolume,
    bool noiseGateEnabled = false,
    ValueChanged<bool>? onNoiseGateChanged,
    ValueChanged<RjSoundboardPad>? onSoundboard,
    double level = 0.0,
    Stream<List<double>>? spectrumStream,
  }) async {
    await tester.pumpWidget(wrap(RjStudioPanel(
      dsp: dsp,
      isHost: isHost,
      levelStream: Stream<double>.value(level),
      spectrumStream: spectrumStream,
      hostName: hostName,
      isLive: isLive,
      isMuted: isMuted,
      onGoLivePressed: onGoLivePressed ?? () {},
      onMutePressed: onMutePressed ?? () {},
      listenerCount: listenerCount,
      onListenersTap: onListenersTap,
      guestName: guestName,
      guestLevel: guestLevel,
      liveElapsed: liveElapsed,
      nowPlayingTitle: nowPlayingTitle,
      nowPlayingPosition: nowPlayingPosition,
      nowPlayingDuration: nowPlayingDuration,
      onMicVolume: onMicVolume,
      onGuestVolume: onGuestVolume,
      onMusicVolume: onMusicVolume,
      noiseGateEnabled: noiseGateEnabled,
      onNoiseGateChanged: onNoiseGateChanged,
      onSoundboard: onSoundboard,
    )));
    await tester.pump();
  }

  testWidgets('all 6 knobs render with labels + initial values',
      (tester) async {
    setTallSurface(tester);
    final dsp = initializedDsp();
    await pumpPanel(tester, dsp: dsp);

    expect(find.text('RJ STUDIO'), findsOneWidget);
    expect(find.text('RJ Sameer'), findsOneWidget);
    expect(find.byType(RjKnob), findsNWidgets(6));
    expect(find.text('REVERB'), findsOneWidget);
    expect(find.text('ECHO'), findsOneWidget);
    expect(find.text('BASS'), findsOneWidget);
    expect(find.text('COMPRESSOR'), findsOneWidget);
    expect(find.text('TREBLE'), findsOneWidget);
    expect(find.text('DELAY'), findsOneWidget);
    // Initial state is the Off preset: reverb/echo/compressor/
    // treble at 0%, bass +0 dB, delay at the 250 ms default.
    expect(find.text('0%'), findsNWidgets(4));
    expect(find.text('+0 dB'), findsOneWidget);
    expect(find.text('250 ms'), findsOneWidget);
  });

  testWidgets('reverb knob drag calls setReverb with mapped wetDryMix',
      (tester) async {
    setTallSurface(tester);
    final dsp = initializedDsp();
    await pumpPanel(tester, dsp: dsp);

    // 60 px up on a 120 px full range = +0.50 from 0.0. The knob
    // accumulates every drag update from the gesture-start value
    // (v2 port), so the FULL drag counts — including the 20 px
    // slop move tester.drag sends first. (The old prop-based knob
    // only counted the last move segment in tests, because no
    // pump ran between the two moves; in production, where
    // rebuilds keep up, it always counted the full drag too.)
    await tester.drag(
        find.byKey(const Key('knob-reverb')), const Offset(0, -60));
    await tester.pumpAndSettle();

    expect(find.text('0%'), findsNWidgets(3)); // reverb moved off 0%
    final args = fake.lastArgs('setReverb');
    expect(args['wetDryMix'], closeTo(0.5, 0.05));
    expect(args['enabled'], isTrue);
  });

  testWidgets('delay knob drag calls setEcho with mapped delayMs',
      (tester) async {
    setTallSurface(tester);
    final dsp = initializedDsp();
    await pumpPanel(tester, dsp: dsp);

    // 60 px up = +0.5 normalised on top of the 250 ms start
    // (0.444) -> ~475 ms. (60 px, not 80, so the value lands
    // mid-range instead of clamping at the 500 ms ceiling — the
    // accumulator counts the full drag, slop move included.)
    await tester.drag(
        find.byKey(const Key('knob-delay')), const Offset(0, -60));
    await tester.pumpAndSettle();

    expect(find.text('250 ms'), findsNothing);
    expect(find.textContaining('ms'), findsOneWidget);
    final args = fake.lastArgs('setEcho');
    expect(args['delayMs'], closeTo(475.0, 15.0));
  });

  testWidgets('treble knob drag calls setEq with mapped highGainDb',
      (tester) async {
    setTallSurface(tester);
    final dsp = initializedDsp();
    await pumpPanel(tester, dsp: dsp);

    // 60 px up = +0.50 -> highGainDb = 0.5 * 12 = +6 dB (the
    // accumulator counts the full drag, slop move included).
    await tester.drag(
        find.byKey(const Key('knob-treble')), const Offset(0, -60));
    await tester.pumpAndSettle();

    expect(find.text('0%'), findsNWidgets(3)); // treble moved off 0%
    final args = fake.lastArgs('setEq');
    expect(args['highGainDb'], closeTo(6.0, 0.5));
    expect(args['enabled'], isTrue);
  });

  testWidgets('echo, bass + compressor knob drags call the right setters',
      (tester) async {
    setTallSurface(tester);
    final dsp = initializedDsp();
    await pumpPanel(tester, dsp: dsp);

    await tester.drag(find.byKey(const Key('knob-echo')), const Offset(0, -60));
    await tester.pumpAndSettle();
    // 60 px up = +0.50 mix (accumulator counts the full drag).
    expect(fake.lastArgs('setEcho')['mix'], closeTo(0.5, 0.05));

    await tester.drag(find.byKey(const Key('knob-bass')), const Offset(0, -60));
    await tester.pumpAndSettle();
    // 50% of the 0..12 dB bass range = +6 dB.
    expect(fake.lastArgs('setEq')['bassBoostDb'], closeTo(6.0, 0.5));
    expect(find.text('+0 dB'), findsNothing);

    await tester.drag(
        find.byKey(const Key('knob-compressor')), const Offset(0, -60));
    await tester.pumpAndSettle();
    final comp = fake.lastArgs('setCompressor');
    // 50%: threshold -6 - 15 = -21 dB, ratio 1.5 + 3.25 = 4.75.
    expect(comp['thresholdDb'], closeTo(-21.0, 1.0));
    expect(comp['ratio'], closeTo(4.75, 0.2));
  });

  testWidgets('Radio preset sets all six knob values end-to-end',
      (tester) async {
    setTallSurface(tester);
    final dsp = initializedDsp();
    await pumpPanel(tester, dsp: dsp);

    await tester.tap(find.byKey(const Key('preset-radio')));
    await tester.pumpAndSettle();

    // Knob readouts move to the Radio values (treble: +1.5 dB =
    // 1.5/12 = 12.5% -> '13%').
    expect(find.text('8%'), findsOneWidget);
    expect(find.text('+5 dB'), findsOneWidget);
    expect(find.text('65%'), findsOneWidget);
    expect(find.text('13%'), findsOneWidget);
    expect(find.text('200 ms'), findsOneWidget);

    // And every value reaches the DSP.
    expect(fake.lastArgs('setReverb')['wetDryMix'], closeTo(0.08, 0.001));
    final echo = fake.lastArgs('setEcho');
    expect(echo['mix'], closeTo(0.0, 0.001));
    expect(echo['delayMs'], closeTo(200.0, 0.001));
    final eq = fake.lastArgs('setEq');
    expect(eq['bassBoostDb'], closeTo(5.0, 0.001));
    expect(eq['highGainDb'], closeTo(1.5, 0.001));
    final comp = fake.lastArgs('setCompressor');
    expect(comp['thresholdDb'], closeTo(-25.5, 0.01));
    expect(comp['ratio'], closeTo(5.725, 0.01));
    expect(fake.lastArgs('setNoiseGate')['thresholdDb'], closeTo(-44.25, 0.01));
  });

  testWidgets('Off preset resets all six knobs', (tester) async {
    setTallSurface(tester);
    final dsp = initializedDsp();
    await pumpPanel(tester, dsp: dsp);

    await tester.tap(find.byKey(const Key('preset-concert')));
    await tester.pumpAndSettle();
    expect(find.text('55%'), findsOneWidget); // concert reverb

    await tester.tap(find.byKey(const Key('preset-off')));
    await tester.pumpAndSettle();
    expect(find.text('0%'), findsNWidgets(4));
    expect(find.text('+0 dB'), findsOneWidget);
    expect(find.text('250 ms'), findsOneWidget);
    expect(fake.lastArgs('setReverb')['wetDryMix'], closeTo(0.0, 0.001));
    expect(fake.lastArgs('setEcho')['delayMs'], closeTo(250.0, 0.001));
  });

  testWidgets('soundboard pads render + taps fire onSoundboard',
      (tester) async {
    setTallSurface(tester);
    final dsp = initializedDsp();
    final tapped = <RjSoundboardPad>[];
    await pumpPanel(tester, dsp: dsp, onSoundboard: tapped.add);

    expect(find.text('APPLAUSE'), findsOneWidget);
    expect(find.text('AIR HORN'), findsOneWidget);
    expect(find.text('LAUGH'), findsOneWidget);
    expect(find.text('DRUM'), findsOneWidget);

    await tester.tap(find.byKey(const Key('pad-applause')));
    await tester.tap(find.byKey(const Key('pad-air-horn')));
    await tester.tap(find.byKey(const Key('pad-laugh')));
    await tester.tap(find.byKey(const Key('pad-drum')));
    await tester.pump();

    expect(tapped, [
      RjSoundboardPad.applause,
      RjSoundboardPad.airHorn,
      RjSoundboardPad.laugh,
      RjSoundboardPad.drum,
    ]);
  });

  testWidgets('faders render + drag fires the volume callbacks',
      (tester) async {
    setTallSurface(tester);
    final dsp = initializedDsp();
    double? micSeen;
    double? guestSeen;
    double? musicSeen;
    await pumpPanel(
      tester,
      dsp: dsp,
      onMicVolume: (v) => micSeen = v,
      onGuestVolume: (v) => guestSeen = v,
      onMusicVolume: (v) => musicSeen = v,
    );

    expect(find.text('MIC'), findsOneWidget);
    expect(find.text('GUEST'), findsOneWidget);
    expect(find.text('MUSIC'), findsOneWidget);
    expect(find.text('NOISE GATE'), findsOneWidget);

    // Faders start at 0.8; 110 px = full range, minus ~20 px slop
    // per gesture.
    await tester.drag(find.byKey(const Key('fader-mic')), const Offset(0, -55));
    await tester.pump();
    expect(micSeen, closeTo(1.0, 0.01)); // 0.8 + ~0.32, clamped

    await tester.drag(
        find.byKey(const Key('fader-guest')), const Offset(0, 55));
    await tester.pump();
    expect(guestSeen, closeTo(0.48, 0.05)); // 0.8 - ~0.32

    await tester.drag(
        find.byKey(const Key('fader-music')), const Offset(0, -44));
    await tester.pump();
    expect(musicSeen, closeTo(1.0, 0.1)); // 0.8 + ~0.22, ~clamped
  });

  testWidgets('noise-gate toggle fires onNoiseGateChanged', (tester) async {
    setTallSurface(tester);
    final dsp = initializedDsp();
    final seen = <bool>[];
    await pumpPanel(tester, dsp: dsp, onNoiseGateChanged: seen.add);

    // 'OFF' appears twice at rest: the toggle + the OFF preset pill.
    expect(find.text('OFF'), findsNWidgets(2));
    await tester.tap(find.byKey(const Key('noise-gate-toggle')));
    await tester.pump();
    expect(find.text('ON'), findsOneWidget);
    expect(find.text('OFF'), findsOneWidget); // only the preset now

    await tester.tap(find.byKey(const Key('noise-gate-toggle')));
    await tester.pump();
    expect(find.text('OFF'), findsNWidgets(2));

    expect(seen, [true, false]);
  });

  testWidgets('listeners count renders + tap fires onListenersTap',
      (tester) async {
    setTallSurface(tester);
    final dsp = initializedDsp();
    var tapped = false;
    await pumpPanel(
      tester,
      dsp: dsp,
      listenerCount: 128,
      onListenersTap: () => tapped = true,
    );

    expect(find.text('128 listening'), findsOneWidget);
    await tester.tap(find.byKey(const Key('listeners-count')));
    expect(tapped, isTrue);
  });

  testWidgets('listeners count is not tappable when onListenersTap is null',
      (tester) async {
    setTallSurface(tester);
    final dsp = initializedDsp();
    await pumpPanel(tester, dsp: dsp, listenerCount: 128);

    expect(find.text('128 listening'), findsOneWidget);
    expect(find.byKey(const Key('listeners-count')), findsNothing);
  });

  testWidgets('guest strip hides when guestName is null', (tester) async {
    setTallSurface(tester);
    final dsp = initializedDsp();
    await pumpPanel(tester, dsp: dsp);

    expect(find.byKey(const Key('guest-strip')), findsNothing);
    expect(find.textContaining('Guest:'), findsNothing);
  });

  testWidgets('guest strip shows name + bars when guestName is set',
      (tester) async {
    setTallSurface(tester);
    final dsp = initializedDsp();
    await pumpPanel(tester, dsp: dsp, guestName: 'Ali', guestLevel: 0.8);

    expect(find.byKey(const Key('guest-strip')), findsOneWidget);
    expect(find.text('Guest: Ali'), findsOneWidget);
    expect(find.byKey(const Key('guest-level-bars')), findsOneWidget);
  });

  testWidgets('Now Playing hides when title is null', (tester) async {
    setTallSurface(tester);
    final dsp = initializedDsp();
    await pumpPanel(tester, dsp: dsp);

    expect(find.byKey(const Key('now-playing')), findsNothing);
  });

  testWidgets('Now Playing shows title + times when set', (tester) async {
    setTallSurface(tester);
    final dsp = initializedDsp();
    await pumpPanel(
      tester,
      dsp: dsp,
      nowPlayingTitle: 'Night Drive - DJ Arman',
      nowPlayingPosition: const Duration(minutes: 2, seconds: 15),
      nowPlayingDuration: const Duration(minutes: 4, seconds: 30),
    );

    expect(find.byKey(const Key('now-playing')), findsOneWidget);
    expect(find.text('Night Drive - DJ Arman'), findsOneWidget);
    expect(find.text('02:15 / 04:30'), findsOneWidget);
  });

  testWidgets('GO LIVE + Mute fire their callbacks', (tester) async {
    setTallSurface(tester);
    final dsp = initializedDsp();
    var goLive = false;
    var mute = false;
    await pumpPanel(
      tester,
      dsp: dsp,
      onGoLivePressed: () => goLive = true,
      onMutePressed: () => mute = true,
    );

    expect(find.text('GO LIVE'), findsOneWidget);
    expect(find.text('MUTE'), findsOneWidget);
    await tester.tap(find.byKey(const Key('go-live-button')));
    await tester.tap(find.byKey(const Key('mute-button')));
    await tester.pump();

    expect(goLive, isTrue);
    expect(mute, isTrue);
  });

  testWidgets('non-host sees the locked state (no knobs)', (tester) async {
    setTallSurface(tester);
    final dsp = initializedDsp();
    await pumpPanel(tester, dsp: dsp, isHost: false);

    expect(
      find.text('Host only — audio controls are locked for listeners.'),
      findsOneWidget,
    );
    expect(find.byType(RjKnob), findsNothing);
    expect(find.text('REVERB'), findsNothing);
    expect(find.text('GO LIVE'), findsNothing);
  });

  testWidgets('timer pill shows liveElapsed + REC only when live',
      (tester) async {
    setTallSurface(tester);
    final dsp = initializedDsp();
    await pumpPanel(
      tester,
      dsp: dsp,
      isLive: true,
      liveElapsed: const Duration(minutes: 12, seconds: 34),
    );

    expect(find.text('12:34'), findsOneWidget);
    expect(find.text('REC'), findsOneWidget);
    expect(find.text('ON AIR'), findsOneWidget);
    expect(find.text('LIVE'), findsOneWidget);

    await pumpPanel(
      tester,
      dsp: dsp,
      liveElapsed: const Duration(minutes: 12, seconds: 34),
    );
    expect(find.text('12:34'), findsOneWidget);
    expect(find.text('REC'), findsNothing);
    expect(find.text('ON AIR'), findsNothing);
    expect(find.text('OFF AIR'), findsOneWidget);
    expect(find.text('OFFLINE'), findsOneWidget);
  });

  testWidgets('GO LIVE label becomes END LIVE while live', (tester) async {
    setTallSurface(tester);
    final dsp = initializedDsp();
    await pumpPanel(tester, dsp: dsp, isLive: true);

    expect(find.text('END LIVE'), findsOneWidget);
    expect(find.text('GO LIVE'), findsNothing);
  });

  testWidgets('fader tap jumps to the tapped track position', (tester) async {
    setTallSurface(tester);
    final dsp = initializedDsp();
    double? micSeen;
    await pumpPanel(tester, dsp: dsp, onMicVolume: (v) => micSeen = v);

    final Finder fader = find.byKey(const Key('fader-mic'));
    final Offset topLeft = tester.getTopLeft(fader);
    final Offset center = tester.getCenter(fader);

    // Tap near the top of the 110 px track -> ~full volume.
    await tester.tapAt(Offset(center.dx, topLeft.dy + 5));
    await tester.pump();
    expect(micSeen, closeTo(1.0, 0.05));

    // Tap near the bottom -> ~silent.
    await tester.tapAt(Offset(center.dx, topLeft.dy + 105));
    await tester.pump();
    expect(micSeen, closeTo(0.0, 0.05));
  });

  testWidgets('narrow 320 px surface renders without overflow', (tester) async {
    setNarrowSurface(tester);
    final dsp = initializedDsp();
    await pumpPanel(
      tester,
      dsp: dsp,
      hostName: 'RJ Sameer — Long Host Name Here',
      isLive: true,
      listenerCount: 128,
      guestName: 'Ali',
      guestLevel: 0.8,
      nowPlayingTitle: 'Night Drive - DJ Arman',
      nowPlayingPosition: const Duration(minutes: 2, seconds: 15),
      nowPlayingDuration: const Duration(minutes: 4, seconds: 30),
    );
    await tester.pumpAndSettle();

    // Any horizontal overflow throws during pump; reaching here
    // with the console intact is the assertion.
    expect(find.text('RJ STUDIO'), findsOneWidget);
    expect(find.byType(RjKnob), findsNWidgets(6));
    expect(find.text('128 listening'), findsOneWidget);
    expect(find.text('Guest: Ali'), findsOneWidget);
    expect(find.byKey(const Key('now-playing')), findsOneWidget);
  });

  testWidgets('spectrumStream drives the bars; stream swap is clean',
      (tester) async {
    setTallSurface(tester);
    final dsp = initializedDsp();
    await pumpPanel(
      tester,
      dsp: dsp,
      spectrumStream: Stream<List<double>>.value(List<double>.filled(16, 0.9)),
    );
    await tester.pumpAndSettle();
    expect(find.text('RJ STUDIO'), findsOneWidget);
    expect(find.byType(RjKnob), findsNWidgets(6));

    // Swap to a different spectrum stream (didUpdateWidget
    // resubscribe) + an empty list (idle bars) — no crash.
    await pumpPanel(
      tester,
      dsp: dsp,
      spectrumStream: Stream<List<double>>.value(<double>[]),
    );
    await tester.pumpAndSettle();
    expect(find.text('RJ STUDIO'), findsOneWidget);
  });
}
