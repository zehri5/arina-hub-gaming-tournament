// ARENA HUB #10 AUDIO — MUSIC PLAYER PANEL (Group 9, 2026-11-22):
// widget tests for MusicPlayerPanel (AI Studio design, reviewed —
// see MUSIC_PLAYER_INTEGRATION.md §1). Every control must call its
// callback — these tests prove the firings (with the right mapped
// values), not just the rendering.
//
// The panel is taller than the default 800x600 test viewport, so
// each test pumps on a tall 390x1600 surface (a real phone width)
// instead of scrolling: every control is tappable as pumped.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/widgets/music_player_panel.dart';

// Minimal 1x1 transparent PNG, so Image.network avatar URLs
// resolve in tests instead of hitting the network.
final _png1x1 = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
);

class _MockHttpClient extends Fake implements HttpClient {
  @override
  Future<HttpClientRequest> getUrl(Uri url) async => _MockHttpRequest();
}

class _MockHttpRequest extends Fake implements HttpClientRequest {
  @override
  Future<HttpClientResponse> close() async => _MockHttpResponse();
}

class _MockHttpResponse extends Fake implements HttpClientResponse {
  @override
  int get statusCode => 200;

  @override
  int get contentLength => _png1x1.length;

  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return Stream<List<int>>.value(_png1x1).listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // NetworkImage uses a static shared HttpClient in this Flutter
  // version, so HttpOverrides cannot mock it — the supported test
  // hook is debugNetworkImageHttpClientProvider (debug-only, and
  // tests run with asserts enabled). It is set only in the avatar
  // test, with addTearDown right after: a file-level tearDown runs
  // AFTER the binding's post-test invariant check and fails it.

  /// Pumps the panel on a tall phone surface. All callbacks default
  /// to recording into the [calls] map so a test can pass only the
  /// recorders it asserts on.
  Future<void> pumpPanel(
    WidgetTester tester, {
    String title = 'Test Song',
    String artist = 'Test Artist',
    String statusLine = 'Shared \u2022 test status',
    bool isDucked = true,
    Duration position = const Duration(seconds: 65),
    Duration duration = const Duration(seconds: 200),
    ValueChanged<Duration>? onSeek,
    bool isPlaying = true,
    bool isRepeat = false,
    VoidCallback? onPlayPause,
    VoidCallback? onRepeat,
    VoidCallback? onPrevious,
    VoidCallback? onNext,
    VoidCallback? onPlaylist,
    VoidCallback? onStop,
    double volume = 0.5,
    ValueChanged<double>? onVolumeChanged,
    bool broadcastOn = true,
    bool isHost = true,
    double reverb = 0.6,
    double echo = 0.45,
    double delayMs = 250.0,
    double bassDb = 6.0,
    ValueChanged<double>? onReverb,
    ValueChanged<double>? onEcho,
    ValueChanged<double>? onDelayMs,
    ValueChanged<double>? onBassDb,
    String preset = 'Room',
    ValueChanged<String>? onPreset,
    bool noiseCancellation = true,
    ValueChanged<bool>? onNoiseCancellation,
    bool noiseGateEnabled = false,
    double noiseGateThresholdDb = -45.0,
    ValueChanged<bool>? onNoiseGateEnabled,
    ValueChanged<double>? onNoiseGateThreshold,
    bool compressorEnabled = true,
    double compressorThresholdDb = -18.0,
    double compressorRatio = 2.5,
    ValueChanged<bool>? onCompressorEnabled,
    ValueChanged<double>? onCompressorThreshold,
    ValueChanged<double>? onCompressorRatio,
    int listenerCount = 128,
    List<String> listenerAvatarUrls = const [],
    VoidCallback? onListenersPressed,
    Stream<double>? levelStream,
  }) async {
    tester.view.physicalSize = const Size(390, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          backgroundColor: const Color(0xFF1E1408),
          body: MusicPlayerPanel(
            title: title,
            artist: artist,
            statusLine: statusLine,
            isDucked: isDucked,
            position: position,
            duration: duration,
            onSeek: onSeek ?? (_) {},
            isPlaying: isPlaying,
            isRepeat: isRepeat,
            onPlayPause: onPlayPause ?? () {},
            onRepeat: onRepeat ?? () {},
            onPrevious: onPrevious ?? () {},
            onNext: onNext ?? () {},
            onPlaylist: onPlaylist ?? () {},
            onStop: onStop ?? () {},
            volume: volume,
            onVolumeChanged: onVolumeChanged ?? (_) {},
            broadcastOn: broadcastOn,
            isHost: isHost,
            reverb: reverb,
            echo: echo,
            delayMs: delayMs,
            bassDb: bassDb,
            onReverb: onReverb ?? (_) {},
            onEcho: onEcho ?? (_) {},
            onDelayMs: onDelayMs ?? (_) {},
            onBassDb: onBassDb ?? (_) {},
            preset: preset,
            onPreset: onPreset ?? (_) {},
            noiseCancellation: noiseCancellation,
            onNoiseCancellation: onNoiseCancellation ?? (_) {},
            noiseGateEnabled: noiseGateEnabled,
            noiseGateThresholdDb: noiseGateThresholdDb,
            onNoiseGateEnabled: onNoiseGateEnabled ?? (_) {},
            onNoiseGateThreshold: onNoiseGateThreshold ?? (_) {},
            compressorEnabled: compressorEnabled,
            compressorThresholdDb: compressorThresholdDb,
            compressorRatio: compressorRatio,
            onCompressorEnabled: onCompressorEnabled ?? (_) {},
            onCompressorThreshold: onCompressorThreshold ?? (_) {},
            onCompressorRatio: onCompressorRatio ?? (_) {},
            listenerCount: listenerCount,
            listenerAvatarUrls: listenerAvatarUrls,
            onListenersPressed: onListenersPressed ?? () {},
            levelStream: levelStream,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  /// Centre of the rotary knob above [label] ('REVERB' / 'ECHO' /
  /// 'DELAY' / 'BASS'): the label sits 4 px below the 60 px knob.
  Offset knobCenter(WidgetTester tester, String label) {
    final labelTopLeft = tester.getTopLeft(find.text(label));
    final labelCenter = tester.getCenter(find.text(label));
    return Offset(labelCenter.dx, labelTopLeft.dy - 4 - 30);
  }

  group('transport rendering', () {
    testWidgets('title, artist, status, times render from props',
        (tester) async {
      await pumpPanel(tester);
      expect(find.text('Test Song'), findsOneWidget);
      expect(find.text('Test Artist'), findsOneWidget);
      expect(find.text('Shared \u2022 test status'), findsOneWidget);
      expect(find.text('01:05'), findsOneWidget);
      expect(find.text('03:20'), findsOneWidget);
      expect(find.text('RJ bed'), findsOneWidget);
      expect(find.text('Broadcast ON'), findsOneWidget);
      expect(
        find.text(
          'Seeking moves only your phone \u2014 shared listeners keep their own position.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('no RJ bed badge when not ducked', (tester) async {
      await pumpPanel(tester, isDucked: false);
      expect(find.text('RJ bed'), findsNothing);
    });

    testWidgets('Broadcast OFF renders grey when broadcastOn is false',
        (tester) async {
      await pumpPanel(tester, broadcastOn: false);
      expect(find.text('Broadcast OFF'), findsOneWidget);
      expect(find.text('Broadcast ON'), findsNothing);
    });

    testWidgets('paused shows the play icon, playing shows pause',
        (tester) async {
      await pumpPanel(tester, isPlaying: false);
      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
      expect(find.byIcon(Icons.pause_rounded), findsNothing);
      await pumpPanel(tester, isPlaying: true);
      expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
      expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);
    });
  });

  group('transport callbacks', () {
    testWidgets('play/pause + stop fire', (tester) async {
      var playPause = 0;
      var stop = 0;
      await pumpPanel(
        tester,
        onPlayPause: () => playPause++,
        onStop: () => stop++,
      );
      await tester.tap(find.byIcon(Icons.pause_rounded));
      await tester.pump();
      expect(playPause, 1);
      await tester.tap(find.byIcon(Icons.power_settings_new_rounded));
      await tester.pump();
      expect(stop, 1);
    });

    testWidgets('repeat / previous / next / playlist fire', (tester) async {
      var repeat = 0;
      var prev = 0;
      var next = 0;
      var playlist = 0;
      await pumpPanel(
        tester,
        onRepeat: () => repeat++,
        onPrevious: () => prev++,
        onNext: () => next++,
        onPlaylist: () => playlist++,
      );
      await tester.tap(find.byIcon(Icons.repeat_rounded));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.skip_previous_rounded));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.skip_next_rounded));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.queue_music_rounded));
      await tester.pump();
      expect(repeat, 1);
      expect(prev, 1);
      expect(next, 1);
      expect(playlist, 1);
    });

    testWidgets('no settings gear in the player (FIX 22 item 22)',
        (tester) async {
      // The player Settings button + its Host / Stream Music /
      // Host Music options are REMOVED — hosting is GO LIVE
      // only. Nothing in the player opens settings any more.
      await pumpPanel(tester);
      expect(find.byIcon(Icons.settings_rounded), findsNothing);
      expect(find.text('Host Music'), findsNothing);
      expect(find.text('Stream Music'), findsNothing);
    });

    testWidgets('progress slider drag seeks forward', (tester) async {
      Duration? sought;
      await pumpPanel(tester, onSeek: (d) => sought = d);
      // Slider 0 = progress. Dragging right from the track centre
      // (50% = 100 s) must land past the 65 s start position.
      await tester.drag(
        find.byType(Slider).at(0),
        const Offset(60, 0),
      );
      await tester.pump();
      expect(sought, isNotNull);
      expect(sought!.inSeconds, greaterThan(65));
      expect(sought!.inSeconds, lessThanOrEqualTo(200));
    });

    testWidgets('volume slider drag fires onVolumeChanged', (tester) async {
      double? changed;
      await pumpPanel(tester, onVolumeChanged: (v) => changed = v);
      // Slider 1 = volume. Dragging right from the 0.5 centre.
      await tester.drag(
        find.byType(Slider).at(1),
        const Offset(100, 0),
      );
      await tester.pump();
      expect(changed, isNotNull);
      expect(changed!, greaterThan(0.5));
      expect(changed!, lessThanOrEqualTo(1.0));
    });
  });

  group('host gating', () {
    testWidgets('listeners see no host-only sections', (tester) async {
      await pumpPanel(tester, isHost: false);
      expect(find.text('HOST-ONLY MUSIC EFFECTS'), findsNothing);
      expect(find.text('REVERB'), findsNothing);
      expect(find.text('PRESETS:'), findsNothing);
      expect(find.text('Noise Cancellation'), findsNothing);
      expect(find.text('Noise Gate'), findsNothing);
      expect(find.text('Compressor'), findsNothing);
      // Transport + listeners still render for listeners.
      expect(find.text('Test Song'), findsOneWidget);
      expect(find.text('128 listening'), findsOneWidget);
    });

    testWidgets('host sees the effects sections', (tester) async {
      await pumpPanel(tester, isHost: true);
      expect(find.text('HOST-ONLY MUSIC EFFECTS'), findsOneWidget);
      expect(find.text('REVERB'), findsOneWidget);
      expect(find.text('PRESETS:'), findsOneWidget);
      expect(find.text('Noise Cancellation'), findsOneWidget);
      expect(find.text('Noise Gate'), findsOneWidget);
      expect(find.text('Compressor'), findsOneWidget);
    });
  });

  group('knobs', () {
    testWidgets('knobs render labels + formatted values', (tester) async {
      await pumpPanel(tester);
      expect(find.text('REVERB'), findsOneWidget);
      expect(find.text('60%'), findsOneWidget);
      expect(find.text('ECHO'), findsOneWidget);
      expect(find.text('45%'), findsOneWidget);
      expect(find.text('DELAY'), findsOneWidget);
      expect(find.text('250 ms'), findsOneWidget);
      expect(find.text('BASS'), findsOneWidget);
      expect(find.text('+6 dB'), findsOneWidget);
    });

    testWidgets('reverb knob tap maps angle to 0..1', (tester) async {
      double? value;
      await pumpPanel(tester, onReverb: (v) => value = v);
      final center = knobCenter(tester, 'REVERB');
      // Top of the dial = mid-sweep = 0.5.
      await tester.tapAt(center + const Offset(0, -20));
      await tester.pump();
      expect(value, closeTo(0.5, 0.02));
      // Right of the dial = 225/270 of the sweep = 0.833.
      await tester.tapAt(center + const Offset(20, 0));
      await tester.pump();
      expect(value, closeTo(0.833, 0.02));
    });

    testWidgets('echo knob tap maps angle to 0..1', (tester) async {
      double? value;
      await pumpPanel(tester, onEcho: (v) => value = v);
      final center = knobCenter(tester, 'ECHO');
      await tester.tapAt(center + const Offset(0, -20));
      await tester.pump();
      expect(value, closeTo(0.5, 0.02));
    });

    testWidgets('delay knob tap maps angle to 0..500 ms', (tester) async {
      double? value;
      await pumpPanel(tester, onDelayMs: (v) => value = v);
      final center = knobCenter(tester, 'DELAY');
      await tester.tapAt(center + const Offset(0, -20));
      await tester.pump();
      expect(value, closeTo(250.0, 5.0));
      await tester.tapAt(center + const Offset(20, 0));
      await tester.pump();
      expect(value, closeTo(416.67, 5.0));
    });

    testWidgets('bass knob tap maps angle to -12..+12 dB', (tester) async {
      double? value;
      await pumpPanel(tester, onBassDb: (v) => value = v);
      final center = knobCenter(tester, 'BASS');
      await tester.tapAt(center + const Offset(0, -20));
      await tester.pump();
      expect(value, closeTo(0.0, 0.5));
      // Left of the dial = 45/270 of the sweep = -8 dB.
      await tester.tapAt(center + const Offset(-20, 0));
      await tester.pump();
      expect(value, closeTo(-8.0, 0.5));
      // Right of the dial = +8 dB.
      await tester.tapAt(center + const Offset(20, 0));
      await tester.pump();
      expect(value, closeTo(8.0, 0.5));
    });
  });

  group('presets', () {
    testWidgets('preset pills fire onPreset with the canonical string',
        (tester) async {
      String? preset;
      await pumpPanel(tester, onPreset: (p) => preset = p);
      await tester.tap(find.text('ROOM'));
      await tester.pump();
      expect(preset, 'Room');
      await tester.tap(find.text('HALL'));
      await tester.pump();
      expect(preset, 'Hall');
      // 'OFF' also matches the gate toggle's label — the preset
      // pill is first in tree order.
      await tester.tap(find.text('OFF').first);
      await tester.pump();
      expect(preset, 'Off');
    });
  });

  group('voice chain', () {
    testWidgets('noise cancellation toggle fires', (tester) async {
      bool? value;
      await pumpPanel(tester, onNoiseCancellation: (v) => value = v);
      // NC is the FIRST 'ON' pill in the tree (presets row, above
      // the gate/compressor row). It starts on, so the tap turns
      // it off.
      await tester.tap(find.text('ON').first);
      await tester.pump();
      expect(value, isFalse);
    });

    testWidgets('noise gate toggle fires', (tester) async {
      bool? value;
      await pumpPanel(tester, onNoiseGateEnabled: (v) => value = v);
      // The gate is the LAST 'OFF' in the tree (the OFF preset
      // pill is first; NC + compressor start on).
      await tester.tap(find.text('OFF').last);
      await tester.pump();
      expect(value, isTrue);
    });

    testWidgets('gate threshold pill drag fires the mapped value',
        (tester) async {
      double? value;
      await pumpPanel(tester, onNoiseGateThreshold: (v) => value = v);
      // Drag right 25 px: -45 dB + 25 * 0.4 = -35 dB. The drag
      // anchors at drag start, so the total is exact.
      await tester.drag(find.text('-45 dB'), const Offset(25, 0));
      await tester.pump();
      expect(value, isNotNull);
      expect(value!, closeTo(-35.0, 0.5));
    });

    testWidgets('compressor toggle fires', (tester) async {
      bool? value;
      await pumpPanel(tester, onCompressorEnabled: (v) => value = v);
      // The compressor is the LAST 'ON' pill in the tree.
      await tester.tap(find.text('ON').last);
      await tester.pump();
      expect(value, isFalse);
    });

    testWidgets('compressor threshold slider drag fires', (tester) async {
      double? value;
      await pumpPanel(tester, onCompressorThreshold: (v) => value = v);
      // Slider 2 = compressor threshold (-60..0, starts at -18).
      await tester.drag(
        find.byType(Slider).at(2),
        const Offset(15, 0),
      );
      await tester.pump();
      expect(value, isNotNull);
      expect(value!, greaterThan(-60.0));
      expect(value!, lessThanOrEqualTo(0.0));
      expect(value!, isNot(-18.0));
    });

    testWidgets('ratio pill tap cycles to the next ratio', (tester) async {
      double? value;
      await pumpPanel(tester, onCompressorRatio: (v) => value = v);
      expect(find.text('Ratio: 2.5:1'), findsOneWidget);
      await tester.tap(find.text('Ratio: 2.5:1'));
      await tester.pump();
      expect(value, 3.0);
    });
  });

  group('listeners', () {
    testWidgets('row renders count + person icons when no avatars',
        (tester) async {
      var pressed = 0;
      await pumpPanel(tester, onListenersPressed: () => pressed++);
      expect(find.text('128 listening'), findsOneWidget);
      expect(find.byIcon(Icons.person_rounded), findsNWidgets(3));
      await tester.tap(find.text('128 listening'));
      await tester.pump();
      expect(pressed, 1);
    });

    testWidgets('avatar URLs render as images (mocked HTTP)',
        (tester) async {
      debugNetworkImageHttpClientProvider = () => _MockHttpClient();
      addTearDown(() => debugNetworkImageHttpClientProvider = null);
      await pumpPanel(
        tester,
        listenerAvatarUrls: const [
          'https://example.invalid/a.jpg',
          'https://example.invalid/b.jpg',
        ],
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byType(Image), findsNWidgets(2));
      expect(find.byIcon(Icons.person_rounded), findsNothing);
    });
  });

  group('level stream', () {
    testWidgets('provided levelStream drives the spectrum without crashing',
        (tester) async {
      final controller = StreamController<double>();
      addTearDown(controller.close);
      await pumpPanel(tester, levelStream: controller.stream);
      controller.add(0.7);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Test Song'), findsOneWidget);
    });
  });
}
