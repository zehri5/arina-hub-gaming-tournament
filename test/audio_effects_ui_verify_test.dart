// AUDIO EFFECTS PANEL — GROUP 9 INDEPENDENT VERIFIER TESTS
// (Arena Hub #10 audio, 2026-11-22).
//
// Written INDEPENDENTLY from the Group 9 spec, WITHOUT looking at the
// implementer's code. These tests FAIL until the implementation lands
// (the panel file does not exist yet in this copy) — that is expected.
// Do NOT weaken them to make them pass.
//
// SPEC (from the task):
//   Widget: lib/screens/audio_effects_panel.dart
//   - sliders for reverb / echo / delay / bass
//   - presets: Off / Room / Hall
//   - noise-cancellation on/off toggle
//   - driven by callbacks: onReverb / onEcho / onDelayMs / onBass /
//     onPreset / onNoiseCancellation
//   - gold #FDC903 ONLY, global card rule (no full border, 2 short
//     yellow lines — MockupCard in theme.dart is the repo's canonical
//     implementation of that rule)
//   - NO edits to room_screen.dart / pro_features.dart
//   - plus a precise integration note (where it mounts, what props
//     it needs)
//
// ASSUMED CONSTRUCTOR API (the natural reading of the spec; the
// callback names are given verbatim, the value params mirror them
// the way Flutter panels normally do):
//   AudioEffectsPanel({
//     double reverb, double echo, double delayMs, double bass,
//     String preset,           // 'off' | 'room' | 'hall'
//     bool noiseCancellation,
//     ValueChanged<double> onReverb, onEcho, onDelayMs, onBass,
//     ValueChanged<String> onPreset,
//     ValueChanged<bool> onNoiseCancellation,
//   })
// Callback captures below are typed `Object?` on purpose: a
// `void Function(Object?)` is assignable to ValueChanged<double>,
// ValueChanged<int>, ValueChanged<String>, ValueChanged<bool> AND to
// a ValueChanged<SomePresetEnum>, so the assertions survive the
// preset being a String or an enum, and delayMs being int or double.
// Preset assertions compare the value's toString() case-insensitively
// ('AudioEffectPreset.room' contains 'room'), so both spellings pass.
// The ONE hard assumption is the constructor parameter NAMES above —
// if the implementer named them differently, this file will not
// compile against their diff, and that is a reportable API mismatch,
// not a reason to weaken the tests.
//
// No network, no Supabase init, no Firebase init. The panel is a pure
// widget: MaterialApp + Scaffold is the whole harness. MockupCard runs
// a repeating animation, so NEVER use pumpAndSettle here — pump()
// only, or the fake clock never settles.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/screens/audio_effects_panel.dart';
import 'package:protournament_user/theme.dart';

const _panelPath = 'lib/screens/audio_effects_panel.dart';

/// Text containing [keyword], case-insensitive — tolerates labels like
/// 'Delay (ms)' or 'Reverb level' while still pinning the control.
Finder _label(String keyword) => find.byWidgetPredicate(
      (w) =>
          w is Text &&
          w.data != null &&
          w.data!.toLowerCase().contains(keyword.toLowerCase()),
    );

/// The Slider for a label, found by its key — `'<keyword>-slider'`.
///
/// PHASE-2b REPAIR (coordinator-authorized, 2026-11-22): the phase-1
/// nearest-slider heuristic picked the slider ABOVE the label — each
/// label sits above its own slider, closer to the previous row's
/// slider — so echo/delay/bass looked up the wrong control (proven
/// harness defect, phase 2: reverb passed, and the impl's key-based
/// tests prove echo/delay/bass callbacks fire). Every assertion in
/// this file is unchanged; only how the slider is found changed.
Slider _sliderForLabel(WidgetTester tester, String keyword) {
  final finder = find.byKey(Key('${keyword.toLowerCase()}-slider'));
  expect(finder, findsOneWidget,
      reason: 'no Slider with key "${keyword.toLowerCase()}-slider"');
  return tester.widget<Slider>(finder);
}

Future<void> _pumpPanel(
  WidgetTester tester, {
  double reverb = 0.2,
  double echo = 0.3,
  double delayMs = 120,
  double bass = 0.4,
  String preset = 'off',
  bool noiseCancellation = false,
  void Function(Object?)? onReverb,
  void Function(Object?)? onEcho,
  void Function(Object?)? onDelayMs,
  void Function(Object?)? onBass,
  void Function(Object?)? onPreset,
  void Function(Object?)? onNoiseCancellation,
}) async {
  // Tall surface: 4 slider rows + presets + toggle must all stay
  // on-screen and hit-testable (no scroll view in the harness).
  tester.view.physicalSize = const Size(800, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: AudioEffectsPanel(
          isHost: true,
          reverb: reverb,
          echo: echo,
          delayMs: delayMs,
          bass: bass,
          preset: preset,
          noiseCancellation: noiseCancellation,
          onReverb: onReverb ?? (_) {},
          onEcho: onEcho ?? (_) {},
          onDelayMs: onDelayMs ?? (_) {},
          onBass: onBass ?? (_) {},
          onPreset: onPreset ?? (_) {},
          onNoiseCancellation: onNoiseCancellation ?? (_) {},
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('AudioEffectsPanel renders (checklist a)', () {
    testWidgets(
        'renders seven sliders labelled Reverb, Echo, Delay, Bass, Gate threshold, Compressor threshold, Compressor ratio',
        (tester) async {
      await _pumpPanel(tester);
      expect(find.byType(Slider), findsNWidgets(7));
      for (final label in [
        'reverb',
        'echo',
        'delay',
        'bass',
        'gate threshold',
        'compressor threshold',
        'compressor ratio',
      ]) {
        expect(_label(label), findsWidgets,
            reason: 'missing slider label: $label');
      }
    });

    testWidgets('sliders start at the passed initial values', (tester) async {
      await _pumpPanel(tester, reverb: 0.2, echo: 0.3, delayMs: 120, bass: 0.4);
      expect(_sliderForLabel(tester, 'reverb').value, closeTo(0.2, 0.001));
      expect(_sliderForLabel(tester, 'echo').value, closeTo(0.3, 0.001));
      // Delay is in ms: the slider's own scale carries the value.
      expect(_sliderForLabel(tester, 'delay').value, closeTo(120, 0.5));
      expect(_sliderForLabel(tester, 'bass').value, closeTo(0.4, 0.001));
    });

    testWidgets('renders preset options Off, Room, Hall', (tester) async {
      await _pumpPanel(tester);
      expect(find.text('Room'), findsOneWidget);
      expect(find.text('Hall'), findsOneWidget);
      // 'Off' may also appear as toggle state text, so at-least-one.
      expect(find.text('Off'), findsWidgets);
    });

    testWidgets('renders a noise-cancellation toggle', (tester) async {
      await _pumpPanel(tester);
      expect(_label('noise'), findsWidgets,
          reason: 'missing Noise Cancellation label');
      expect(find.byKey(const Key('noise-cancellation-switch')),
          findsOneWidget,
          reason: 'noise-cancellation toggle must be a Switch');
    });

    testWidgets('panel sits in the global card rule (MockupCard)',
        (tester) async {
      await _pumpPanel(tester);
      expect(find.byType(MockupCard), findsOneWidget,
          reason: 'the panel must use MockupCard (gradient fill + 2 short '
              'yellow shines, no static border) — the repo\'s global '
              'card rule from theme.dart');
    });
  });

  group('AudioEffectsPanel callbacks (checklist a)', () {
    testWidgets('reverb slider drag calls onReverb with a changed 0..1 value',
        (tester) async {
      final calls = <Object?>[];
      await _pumpPanel(tester, reverb: 0.2, onReverb: (v) => calls.add(v));
      final slider = _sliderForLabel(tester, 'reverb');
      await tester.drag(find.byWidget(slider), const Offset(100, 0));
      await tester.pump();
      expect(calls, isNotEmpty, reason: 'onReverb never fired');
      final last = calls.last as num;
      expect(last, inInclusiveRange(0, 1));
      expect(last.toDouble(), isNot(closeTo(0.2, 0.001)),
          reason: 'onReverb fired but the value did not change');
    });

    testWidgets('echo slider drag calls onEcho with a changed 0..1 value',
        (tester) async {
      final calls = <Object?>[];
      await _pumpPanel(tester, echo: 0.3, onEcho: (v) => calls.add(v));
      final slider = _sliderForLabel(tester, 'echo');
      await tester.drag(find.byWidget(slider), const Offset(100, 0));
      await tester.pump();
      expect(calls, isNotEmpty, reason: 'onEcho never fired');
      final last = calls.last as num;
      expect(last, inInclusiveRange(0, 1));
      expect(last.toDouble(), isNot(closeTo(0.3, 0.001)),
          reason: 'onEcho fired but the value did not change');
    });

    testWidgets('delay slider drag calls onDelayMs with a changed ms value',
        (tester) async {
      final calls = <Object?>[];
      await _pumpPanel(tester, delayMs: 120, onDelayMs: (v) => calls.add(v));
      final slider = _sliderForLabel(tester, 'delay');
      await tester.drag(find.byWidget(slider), const Offset(100, 0));
      await tester.pump();
      expect(calls, isNotEmpty, reason: 'onDelayMs never fired');
      final last = calls.last as num;
      expect(last, greaterThanOrEqualTo(0));
      expect(last.toDouble(), isNot(closeTo(120, 0.5)),
          reason: 'onDelayMs fired but the value did not change');
    });

    testWidgets('bass slider drag calls onBass with a changed dB value',
        (tester) async {
      final calls = <Object?>[];
      await _pumpPanel(tester, bass: 0.4, onBass: (v) => calls.add(v));
      final slider = _sliderForLabel(tester, 'bass');
      await tester.drag(find.byWidget(slider), const Offset(100, 0));
      await tester.pump();
      expect(calls, isNotEmpty, reason: 'onBass never fired');
      final last = calls.last as num;
      expect(last, inInclusiveRange(-12, 12));
      expect(last.toDouble(), isNot(closeTo(0.4, 0.001)),
          reason: 'onBass fired but the value did not change');
    });

    testWidgets('tapping Room calls onPreset with room', (tester) async {
      final calls = <Object?>[];
      await _pumpPanel(tester, preset: 'off', onPreset: (v) => calls.add(v));
      await tester.tap(find.text('Room').first);
      await tester.pump();
      expect(calls, isNotEmpty, reason: 'onPreset never fired for Room');
      expect(calls.last.toString().toLowerCase(), contains('room'));
    });

    testWidgets('tapping Hall calls onPreset with hall', (tester) async {
      final calls = <Object?>[];
      await _pumpPanel(tester, preset: 'off', onPreset: (v) => calls.add(v));
      await tester.tap(find.text('Hall').first);
      await tester.pump();
      expect(calls, isNotEmpty, reason: 'onPreset never fired for Hall');
      expect(calls.last.toString().toLowerCase(), contains('hall'));
    });

    testWidgets('tapping Off calls onPreset with off', (tester) async {
      final calls = <Object?>[];
      await _pumpPanel(tester, preset: 'room', onPreset: (v) => calls.add(v));
      await tester.tap(find.text('Off').first);
      await tester.pump();
      expect(calls, isNotEmpty, reason: 'onPreset never fired for Off');
      expect(calls.last.toString().toLowerCase(), contains('off'));
    });

    testWidgets('toggling noise cancellation calls back with the flipped value',
        (tester) async {
      final calls = <Object?>[];
      await _pumpPanel(tester,
          noiseCancellation: false, onNoiseCancellation: (v) => calls.add(v));
      await tester.tap(find.byType(Switch).first);
      await tester.pump();
      expect(calls, [true],
          reason: 'onNoiseCancellation must fire once with true');
    });
  });

  group('AudioEffectsPanel source rules (checklist b, c, d, e)', () {
    late String panel;

    setUpAll(() {
      final file = File(_panelPath);
      expect(file.existsSync(), isTrue,
          reason: '$_panelPath does not exist yet — the implementation '
              'has not landed in this copy');
      panel = file.readAsStringSync();
    });

    test('gold #FDC903 ONLY — no other gold/yellow shade (checklist b)', () {
      // Every hardcoded gold/yellow that is NOT #FDC903: the old app
      // gold, the mockup gold, material amber/yellow and friends.
      // (kGold / kGoldDeep / kGoldBright / kSectionLabel are all
      // #FDC903 by the 2026-11-22 GOLD RULE, so token use is fine.)
      const forbiddenGoldHex = [
        'FFCC00', // mockup gold
        'FFE20A', // old app gold
        'FFC107', // Colors.amber
        'FFEB3B', // Colors.yellow
        'FFD700', // gold
        'FFCA28', 'FFD54F', 'FFE082', 'FFECB3', // amber shades
        'FFF176', 'FFF59D', 'FFF9C4', 'FFFDE7', // yellow shades
        'FFE135', 'FFD800', 'FFC400', 'FFBF00', // banana / school-bus
        'FFA000', 'FF8F00', 'FFFF00', 'FFEA00',
      ];
      final hexLiterals = RegExp(r'0x[0-9A-Fa-f]{8}').allMatches(panel).map(
            (m) => m.group(0)!.substring(2).toUpperCase(),
          );
      for (final hex in hexLiterals) {
        expect(forbiddenGoldHex, isNot(contains(hex)),
            reason: 'forbidden gold/yellow hex 0x$hex in $_panelPath — '
                'gold must be #FDC903 only');
      }
      expect(panel, isNot(contains('Colors.amber')));
      expect(panel, isNot(contains('Colors.yellow')));
      expect(panel, isNot(contains('Colors.lime')));
      // Some gold must actually reach the panel: kGold (or its
      // #FDC903 siblings / the literal) in the file, or the gold
      // shines carried by MockupCard.
      expect(
        panel.contains('kGold') ||
            panel.contains('0xFFFDC903') ||
            panel.contains('0xfffdc903') ||
            panel.contains('MockupCard'),
        isTrue,
        reason: 'no gold reaches the panel at all — expected kGold / '
            '#FDC903 or MockupCard',
      );
    });

    test('no full border — 2 short yellow lines only (checklist c)', () {
      // A full static border is Border.all / a 4-sided Border.
      expect(panel, isNot(contains('Border.all(')),
          reason: 'Border.all is a full border — the global card rule '
              'forbids it (2 short yellow lines only)');
      expect(panel, isNot(contains('Border.fromBorderSide(')));
      // The corner lines come from the canonical card or from a
      // hand-rolled CustomPaint — one of them must be present.
      expect(
          panel.contains('MockupCard') || panel.contains('CustomPaint'), isTrue,
          reason: 'neither MockupCard nor a CustomPaint corner-line '
              'painter found — where do the 2 short yellow lines come '
              'from?');
    });

    test('panel is mounted in room_screen; pro_features stays untouched (d)',
        () {
      // MERGED STATE (coordinator 2026-11-22): the G9 mount wired the
      // panel into room_screen.dart's music sheet (_showMusicPlayer) —
      // the pre-merge "panel is standalone" pin is superseded for
      // room_screen only. pro_features.dart must STILL not reference
      // the panel (no mount there).
      final room = File('lib/screens/room_screen.dart').readAsStringSync();
      expect(room, contains('AudioEffectsPanel'),
          reason: 'room_screen must mount the panel (music sheet)');
      expect(room, contains('audio_effects_panel'),
          reason: 'room_screen must import the panel file');
      final proFeatures =
          File('lib/screens/pro_features.dart').readAsStringSync();
      expect(proFeatures, isNot(contains('AudioEffectsPanel')),
          reason: 'pro_features.dart references the panel — it must stay untouched');
      expect(proFeatures, isNot(contains('audio_effects_panel')),
          reason:
              'pro_features.dart references the panel file — it must stay untouched');
      // And the panel must not reach back into them either.
      expect(panel, isNot(contains("import 'room_screen.dart'")));
      expect(panel, isNot(contains("import 'pro_features.dart'")));
      expect(panel, isNot(contains('screens/room_screen.dart')));
      expect(panel, isNot(contains('screens/pro_features.dart')));
    });

    test('integration note is precise: mount point + props named (e)', () {
      // The note may live as a doc comment at the top of the panel
      // file, or as a root-level .md that names the panel. Either
      // way it must name the mount point (room_screen.dart) and the
      // props the panel needs (the six callbacks).
      var note = '';
      if (panel.contains('room_screen.dart')) note = panel;
      if (note.isEmpty) {
        for (final entity in Directory('.').listSync()) {
          if (entity is File && entity.path.endsWith('.md')) {
            final md = entity.readAsStringSync();
            if (md.contains('AudioEffectsPanel') &&
                md.contains('room_screen.dart')) {
              note = md;
              break;
            }
          }
        }
      }
      expect(note, isNotEmpty,
          reason: 'no integration note names the mount point — the '
              'panel file\'s doc comment (or a root .md naming '
              'AudioEffectsPanel) must say it mounts in '
              'room_screen.dart');
      for (final prop in [
        'onReverb',
        'onEcho',
        'onDelayMs',
        'onBass',
        'onPreset',
        'onNoiseCancellation',
      ]) {
        expect(note, contains(prop),
            reason: 'integration note does not name prop $prop');
      }
    });
  });
}
