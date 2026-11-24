// ARENA HUB #10 AUDIO — Group 9, RJ STUDIO evolution:
// AudioEffectsPanel widget tests. Presentational only: no Supabase,
// no Firebase, no network. Proves the RJ STUDIO console renders its
// controls, fires the contract callbacks with values, keeps the
// effect controls host-only (listeners see the count row, not the
// console), keeps the compressor section
// live on the v3 DSP, and stays gold-only (#FDC903 via kGold —
// pinned by reading the panel's own source).
//
// NOTE: the effect controls are host-only (isHost defaults to
// false = controls hidden, count row visible), so every widget test
// that exercises the console pumps it with isHost: true. The
// gating tests below prove the default.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/screens/audio_effects_panel.dart';
import 'package:protournament_user/theme.dart';

Widget wrap(Widget child) => MaterialApp(
  theme: ThemeData.dark().copyWith(scaffoldBackgroundColor: kBg),
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

void main() {
  testWidgets('panel renders header, 7 sliders, 3 presets, NS toggle', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(const AudioEffectsPanel(isHost: true)));
    await tester.pump();

    expect(find.text('RJ STUDIO'), findsOneWidget);
    expect(find.text('Live host console'), findsOneWidget);
    // 4 effect sliders + gate threshold + 2 compressor sliders.
    expect(find.byType(Slider), findsNWidgets(7));
    expect(find.text('Reverb'), findsOneWidget);
    expect(find.text('Echo'), findsOneWidget);
    expect(find.text('Delay'), findsOneWidget);
    expect(find.text('Bass'), findsOneWidget);
    expect(find.text('Off'), findsOneWidget);
    expect(find.text('Room'), findsOneWidget);
    expect(find.text('Hall'), findsOneWidget);
    expect(find.text('Noise cancellation'), findsOneWidget);
    expect(find.byKey(const Key('noise-cancellation-switch')), findsOneWidget);
    expect(find.text('Noise gate'), findsOneWidget);
    expect(find.byKey(const Key('noise-gate-switch')), findsOneWidget);
    expect(find.byKey(const Key('gate-threshold-slider')), findsOneWidget);
    expect(find.text('Compressor'), findsOneWidget);
    expect(find.text('Even out loud and quiet voices'), findsOneWidget);
    expect(
      find.byKey(const Key('compressor-threshold-slider')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('compressor-ratio-slider')), findsOneWidget);
    expect(find.byType(MockupCard), findsOneWidget);
  });

  testWidgets('reverb slider drag calls onReverb with a value in range', (
    tester,
  ) async {
    double? seen;
    await tester.pumpWidget(
      wrap(AudioEffectsPanel(isHost: true, onReverb: (v) => seen = v)),
    );
    await tester.pump();

    await tester.drag(
      find.byKey(const Key('reverb-slider')),
      const Offset(100, 0),
    );
    await tester.pump();

    expect(seen, isNotNull);
    expect(seen!, greaterThan(0.0));
    expect(seen!, lessThanOrEqualTo(1.0));
  });

  testWidgets('echo slider drag calls onEcho with a value in range', (
    tester,
  ) async {
    double? seen;
    await tester.pumpWidget(
      wrap(AudioEffectsPanel(isHost: true, onEcho: (v) => seen = v)),
    );
    await tester.pump();

    await tester.drag(
      find.byKey(const Key('echo-slider')),
      const Offset(100, 0),
    );
    await tester.pump();

    expect(seen, isNotNull);
    expect(seen!, greaterThan(0.0));
    expect(seen!, lessThanOrEqualTo(1.0));
  });

  testWidgets('delay slider drag calls onDelayMs in milliseconds', (
    tester,
  ) async {
    double? seen;
    await tester.pumpWidget(
      wrap(AudioEffectsPanel(isHost: true, onDelayMs: (v) => seen = v)),
    );
    await tester.pump();

    await tester.drag(
      find.byKey(const Key('delay-slider')),
      const Offset(100, 0),
    );
    await tester.pump();

    expect(seen, isNotNull);
    expect(seen!, greaterThan(0.0));
    expect(seen!, lessThanOrEqualTo(500.0));
  });

  testWidgets('bass slider drag calls onBass in dB', (tester) async {
    double? seen;
    await tester.pumpWidget(
      wrap(AudioEffectsPanel(isHost: true, onBass: (v) => seen = v)),
    );
    await tester.pump();

    await tester.drag(
      find.byKey(const Key('bass-slider')),
      const Offset(100, 0),
    );
    await tester.pump();

    expect(seen, isNotNull);
    expect(seen!, greaterThan(0.0));
    expect(seen!, lessThanOrEqualTo(12.0));
  });

  testWidgets('preset tap calls onPreset and moves the sliders', (
    tester,
  ) async {
    String? seen;
    await tester.pumpWidget(
      wrap(AudioEffectsPanel(isHost: true, onPreset: (v) => seen = v)),
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('preset-Hall')));
    await tester.pump();

    expect(seen, 'Hall');
    // Hall preset values are visible on the sliders. (Reconciled to
    // Group 8's PlaybackEffects presets, 2026-11-22: echo 0.25,
    // delay 350 ms, bass +4.5 dB — the label rounds 4.5 to +5 dB.)
    expect(find.text('70%'), findsOneWidget); // reverb
    expect(find.text('25%'), findsOneWidget); // echo
    expect(find.text('350 ms'), findsOneWidget); // delay
    expect(find.text('+5 dB'), findsOneWidget); // bass

    await tester.tap(find.byKey(const Key('preset-Off')));
    await tester.pump();

    expect(seen, 'Off');
    expect(find.text('0%'), findsNWidgets(2)); // reverb + echo
    // Off resets the delay to the 250 ms native default (echo is 0,
    // so it is inaudible).
    expect(find.text('250 ms'), findsOneWidget);
    expect(find.text('0 dB'), findsOneWidget);
  });

  testWidgets('noise-cancellation toggle calls back', (tester) async {
    bool? seen;
    await tester.pumpWidget(
      wrap(
        AudioEffectsPanel(isHost: true, onNoiseCancellation: (v) => seen = v),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('noise-cancellation-switch')));
    await tester.pump();

    expect(seen, isTrue);
  });

  test('presetValues map matches the contract', () {
    final values = AudioEffectsPanel.presetValues;
    expect(values.keys, containsAll(['Off', 'Room', 'Hall']));
    // Reconciled to Group 8's PlaybackEffects presets (2026-11-22):
    // Off resets the delay to the 250 ms native default; 'bass' is
    // the EQ band 0 gain in dB (+3 Room, +4.5 Hall).
    expect(values['Off'], {
      'reverb': 0.0,
      'echo': 0.0,
      'delayMs': 250.0,
      'bass': 0.0,
    });
    expect(values['Room']!['reverb'], 0.35);
    expect(values['Room']!['echo'], 0.15);
    expect(values['Room']!['delayMs'], 180.0);
    expect(values['Room']!['bass'], 3.0);
    expect(values['Hall']!['reverb'], 0.70);
    expect(values['Hall']!['echo'], 0.25);
    expect(values['Hall']!['delayMs'], 350.0);
    expect(values['Hall']!['bass'], 4.5);
    expect(AudioEffectsPanel.presets, ['Off', 'Room', 'Hall']);
  });

  test('GOLD-ONLY source pin: no hardcoded colours, only kGold', () {
    final source = File('lib/screens/audio_effects_panel.dart')
        .readAsStringSync();
    // No hex colour literal anywhere in the file — every colour comes
    // from the shared theme tokens.
    expect(
      source.contains('0x'),
      isFalse,
      reason: 'audio_effects_panel.dart must not contain hex colours',
    );
    // No material yellow/amber/orange that could read as a second gold.
    expect(source.contains('Colors.amber'), isFalse);
    expect(source.contains('Colors.yellow'), isFalse);
    expect(source.contains('Colors.orange'), isFalse);
    // No retired gold shades from before the 2026-11-22 GOLD RULE.
    expect(source.contains('FFE20A'), isFalse);
    expect(source.contains('FFCC00'), isFalse);
    expect(source.contains('FFD700'), isFalse);
    // No full border anywhere — the global card rule lives in the
    // shared MockupCard only.
    expect(source.contains('Border.all'), isFalse);
    // Gold comes from the shared token, and the card is the shared
    // global-card-rule card.
    expect(source.contains('kGold'), isTrue);
    expect(source.contains('MockupCard'), isTrue);
  });

  // ---- RJ STUDIO: host gating (listeners see the count, not the
  // console) ----

  testWidgets('non-host sees the count row, not the controls: default isHost', (
    tester,
  ) async {
    // No isHost passed — the safe default (false) applies: the
    // effect controls stay hidden, but the live listener count row
    // is visible to everyone (tap -> detail sheet).
    await tester.pumpWidget(wrap(const AudioEffectsPanel()));
    await tester.pump();

    expect(find.text('RJ STUDIO'), findsOneWidget);
    expect(find.text('Live host console'), findsNothing);
    expect(find.byKey(const Key('listener-count-row')), findsOneWidget);
    expect(find.text('0 listening'), findsOneWidget);
    expect(find.byType(Slider), findsNothing);
    expect(find.byType(Switch), findsNothing);
    expect(find.text('Preset'), findsNothing);
    expect(find.text('Noise gate'), findsNothing);
    expect(find.text('Compressor'), findsNothing);
    expect(find.byType(MockupCard), findsOneWidget);
  });

  testWidgets('explicit isHost false hides the controls, shows the count', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        const AudioEffectsPanel(
          isHost: false,
          listenerCount: 128,
          peakListeners: 214,
        ),
      ),
    );
    await tester.pump();

    expect(find.text('RJ STUDIO'), findsOneWidget);
    expect(find.text('Live host console'), findsNothing);
    expect(find.byKey(const Key('listener-count-row')), findsOneWidget);
    expect(find.text('128 listening'), findsOneWidget);
    expect(find.byType(Slider), findsNothing);
    expect(find.byType(Switch), findsNothing);
    expect(find.text('Preset'), findsNothing);
    expect(find.byType(MockupCard), findsOneWidget);
  });

  testWidgets('host sees the full console AND the count row', (tester) async {
    await tester.pumpWidget(
      wrap(const AudioEffectsPanel(isHost: true, listenerCount: 128)),
    );
    await tester.pump();

    expect(find.text('RJ STUDIO'), findsOneWidget);
    expect(find.text('Live host console'), findsOneWidget);
    expect(find.byKey(const Key('listener-count-row')), findsOneWidget);
    expect(find.text('128 listening'), findsOneWidget);
    expect(find.byType(Slider), findsNWidgets(7));
    expect(find.text('Noise gate'), findsOneWidget);
    expect(find.text('Even out loud and quiet voices'), findsOneWidget);
  });

  // ---- RJ STUDIO: noise gate ----

  testWidgets('gate threshold slider drag calls onNoiseGateThreshold', (
    tester,
  ) async {
    double? seen;
    await tester.pumpWidget(
      wrap(
        AudioEffectsPanel(isHost: true, onNoiseGateThreshold: (v) => seen = v),
      ),
    );
    await tester.pump();

    // Default threshold is -40 dB; dragging right raises it.
    expect(find.text('-40 dB'), findsOneWidget);
    await tester.drag(
      find.byKey(const Key('gate-threshold-slider')),
      const Offset(100, 0),
    );
    await tester.pump();

    expect(seen, isNotNull);
    expect(seen!, greaterThan(-40.0));
    expect(seen!, lessThanOrEqualTo(0.0));
  });

  testWidgets('gate enable switch calls onNoiseGateEnabled', (tester) async {
    bool? seen;
    await tester.pumpWidget(
      wrap(
        AudioEffectsPanel(isHost: true, onNoiseGateEnabled: (v) => seen = v),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('noise-gate-switch')));
    await tester.pump();

    expect(seen, isTrue);
  });

  // ---- RJ STUDIO: compressor (LIVE on the v3 DSP) ----

  testWidgets('compressor sliders are enabled and live', (tester) async {
    await tester.pumpWidget(wrap(const AudioEffectsPanel(isHost: true)));
    await tester.pump();

    final thresholdSlider = tester.widget<Slider>(
      find.byKey(const Key('compressor-threshold-slider')),
    );
    final ratioSlider = tester.widget<Slider>(
      find.byKey(const Key('compressor-ratio-slider')),
    );
    expect(thresholdSlider.onChanged, isNotNull);
    expect(ratioSlider.onChanged, isNotNull);
    // Engine defaults show: threshold -18 dB, ratio 4.0:1.
    expect(find.text('-18 dB'), findsOneWidget);
    expect(find.text('4.0:1'), findsOneWidget);
    // No "coming soon" anywhere — the compressor is live.
    expect(find.textContaining('coming soon'), findsNothing);
  });

  testWidgets('compressor threshold slider drag calls onCompressorThreshold', (
    tester,
  ) async {
    double? seen;
    await tester.pumpWidget(
      wrap(
        AudioEffectsPanel(isHost: true, onCompressorThreshold: (v) => seen = v),
      ),
    );
    await tester.pump();

    // Default threshold is -18 dB; dragging right raises it.
    // The compressor sits at the bottom of the tall console —
    // scroll it into view first (the test viewport is 600px).
    await tester.ensureVisible(
      find.byKey(const Key('compressor-threshold-slider')),
    );
    await tester.pumpAndSettle();
    await tester.drag(
      find.byKey(const Key('compressor-threshold-slider')),
      const Offset(100, 0),
    );
    await tester.pump();

    // tester.drag starts at the slider's CENTER, not at the thumb
    // (default -18 dB sits at 70% across), so the value jumps to
    // the centre first and then moves right — assert the callback
    // fired with a changed, in-range value rather than a
    // direction.
    expect(seen, isNotNull);
    expect(seen!, greaterThanOrEqualTo(-60.0));
    expect(seen!, lessThanOrEqualTo(0.0));
    expect(seen, isNot(-18.0));
  });

  testWidgets('compressor ratio slider drag calls onCompressorRatio', (
    tester,
  ) async {
    double? seen;
    await tester.pumpWidget(
      wrap(AudioEffectsPanel(isHost: true, onCompressorRatio: (v) => seen = v)),
    );
    await tester.pump();

    // Default ratio is 4.0; dragging right raises it.
    // Scroll into view first — see the threshold test above.
    await tester.ensureVisible(
      find.byKey(const Key('compressor-ratio-slider')),
    );
    await tester.pumpAndSettle();
    await tester.drag(
      find.byKey(const Key('compressor-ratio-slider')),
      const Offset(100, 0),
    );
    await tester.pump();

    // Same centre-start note as the threshold test: assert a
    // changed, in-range value.
    expect(seen, isNotNull);
    expect(seen!, greaterThanOrEqualTo(1.0));
    expect(seen!, lessThanOrEqualTo(20.0));
    expect(seen, isNot(4.0));
  });
}
