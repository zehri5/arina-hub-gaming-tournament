import 'package:flutter/material.dart';

import '../services/live_listeners.dart';
import '../theme.dart';
import 'listeners_detail_sheet.dart';

/// ARENA HUB #10 AUDIO — Group 9, RJ STUDIO evolution (user order
/// 2026-11-22): the community live voice chat works like an FM RJ's
/// studio, and this panel is the HOST's live control console — the
/// host runs their own live show from it, WHILE live: no navigation
/// away, no voice restart.
///
/// A presentational panel ONLY. It owns no audio engine and imports
/// no other group's effect classes — it talks to the merge through
/// the callbacks below, which the merge wires to the audio groups:
///
///   * [onReverb] — reverb mix, 0.0 (dry) .. 1.0 (fully wet).
///   * [onEcho] — echo mix, 0.0 .. 1.0.
///   * [onDelayMs] — echo delay time in milliseconds, 0 .. 500.
///   * [onBass] — bass shelf in dB, -12 .. +12.
///   * [onPreset] — preset name: 'Off', 'Room' or 'Hall'. The merge
///     handler should apply [presetValues] for that preset to the
///     engine; the panel already moves its own sliders to match.
///   * [onNoiseCancellation] — true = noise cancellation on.
///   * [onNoiseGateThreshold] — noise-gate threshold in dB,
///     -60 .. 0. Wires to the v3 DSP engine's
///     `AudioDsp.setNoiseGate({enabled, thresholdDb})` (defaults
///     threshold -40 dB, attack 5 ms, release 120 ms — the panel
///     default matches). The engine is in this tree now
///     (lib/audio/audio_dsp.dart); the merge wires the callback
///     (see RJ_STUDIO_INTEGRATION.md).
///   * [onNoiseGateEnabled] — true = noise gate on.
///   * [onCompressorThreshold] — compressor threshold in dB,
///     -60 .. 0 (engine default -18). Wires to
///     `AudioDsp.setCompressor({enabled, thresholdDb, ratio})` —
///     the v3 DSP engine, in this tree now
///     (lib/audio/audio_dsp.dart + android/app/src/main/cpp/
///     dsp_engine.*). LIVE: the sliders are enabled and fire.
///   * [onCompressorRatio] — compressor ratio, 1 .. 20
///     (engine default 4). Same wiring as above.
///     Attack (10 ms), release (100 ms) and makeup gain (0 dB)
///     stay at the engine defaults — they are set-once DSP
///     tuning, not live-show controls, and the panel already
///     carries 7 sliders. The merge passes the defaults in each
///     setCompressor call (see RJ_STUDIO_INTEGRATION.md).
///
/// LISTENERS (mockup v4, user order 2026-11-22): the header also
/// carries the LIVE LISTENER COUNT — a headphone icon + "128
/// listening" in gold, on the right of the "RJ STUDIO" header row.
/// Tapping it opens the listeners detail sheet
/// (lib/screens/listeners_detail_sheet.dart): avatar, display name
/// and listening-since per listener, sorted longest-listening
/// first, plus the show's peak. The three props are
/// [listenerCount] (default 0), [peakListeners] (default 0) and
/// [listeners] (default empty) — all defaulted, so the music-sheet
/// mount (which passes none of them yet) keeps working unchanged
/// and shows "0 listening" until the merge wires the live data
/// there. The count row ALWAYS renders — it is never hidden for a
/// zero count. Listeners = LiveKit room participants NOT on a mic
/// seat (the host + mic guests occupy seats).
///
/// HOST GATING (restructured 2026-11-22): the effect controls
/// belong to the HOST, but the COUNT belongs to everyone. [isHost]
/// defaults to false (safe): when false the panel renders the
/// header + the tappable listener count row and hides the effect
/// controls (sliders, presets, noise gate, compressor) — listeners
/// see the count, never the console. The mount passes
/// `isHost: <room-admin signal>` — see
/// RJ_STUDIO_INTEGRATION.md for the exact getter.
///
/// LIVE-USE CONTRACT: every slider callback maps to a live setter
/// that applies WITHOUT re-publish or voice restart — the v3 DSP
/// setters (AudioDsp.setNoiseGate / setCompressor / setReverb /
/// setEcho / setEq) are mutex-guarded in C++ and apply to the
/// running stream, and the mic pipeline's
/// setNoiseCancellationEnabled re-publishes the mic track ONLY
/// when the NC flag itself flips (param changes never touch the
/// track). So the host drags a slider mid-show and the room hears
/// the change at once; nothing here ever restarts voice.
///
/// DESIGN (strict, user order): gold #FDC903 ONLY — every gold in
/// this file comes from the shared [kGold] token, and the file
/// contains NO hardcoded hex colour literal at all (pinned by
/// test/audio_effects_ui_test.dart). The card is the shared
/// [MockupCard] — global card rule: deep black background, light
/// greyish card, NO full border, only 2 short yellow lines
/// (top-right + bottom-left). The shines park at their rest
/// position (`animate: false`) so no ticker runs inside the
/// console.
///
/// MOUNT: see RJ_STUDIO_INTEGRATION.md at the project root — the
/// console mounts in the community voice UI (room_screen.dart)
/// and the team voice panel (same panel, same pattern). The old
/// Group 9 music-sheet mount (_showMusicPlayer) still works as a
/// secondary mount, but the music sheet is mainAxisSize.min and
/// NOT scrollable, so the console must never be dropped into it
/// un-wrapped (see the note's overflow caution).
class AudioEffectsPanel extends StatefulWidget {
  /// Preset slider values, keyed by preset name. The merge's
  /// [onPreset] handler reads these to apply a preset to the engine —
  /// the numbers live here once, never duplicated in the merge.
  /// Each map holds: 'reverb' (0..1), 'echo' (0..1),
  /// 'delayMs' (0..500), 'bass' (-12..+12 dB).
  ///
  /// RJ STUDIO keeps Off/Room/Hall EXACTLY as-is. Do NOT add
  /// presets here — the one preset definition is a merge-time
  /// decision.
  ///
  /// PRESET RECONCILIATION (Group 9 merge, 2026-11-22): these numbers
  /// ARE Group 8's PlaybackEffects presets — the playback path is the
  /// source of truth for what you hear, so the panel's slider
  /// positions and the engine agree. The old Group 9 values (Room
  /// 120 ms, Hall 320 ms / echo 0.40 / bass +2/+4 dB) were replaced:
  /// Room is now 180 ms, Hall 350 ms with echo 0.25. 'bass' here is
  /// the EQ band 0 gain in dB (+3 Room, +4.5 Hall) — the dB-valued
  /// part of the preset; the BassBoost amount (0.30 Room, 0.40 Hall)
  /// has no slider of its own and is applied alongside by
  /// PlaybackEffects.applyPreset. Off resets the delay to the 250 ms
  /// native default (echo is 0, so it is inaudible).
  static const Map<String, Map<String, double>> presetValues = {
    'Off': {'reverb': 0.0, 'echo': 0.0, 'delayMs': 250.0, 'bass': 0.0},
    'Room': {'reverb': 0.35, 'echo': 0.15, 'delayMs': 180.0, 'bass': 3.0},
    'Hall': {'reverb': 0.70, 'echo': 0.25, 'delayMs': 350.0, 'bass': 4.5},
  };

  static const List<String> presets = ['Off', 'Room', 'Hall'];

  /// True only for the room host (the RJ). The effect controls
  /// (sliders, presets, noise gate, compressor) render only for
  /// the host; listeners see the header + the live listener count
  /// row instead. Defaults to false (safe).
  final bool isHost;

  /// Live listener count, shown in the header count row ("128
  /// listening"). Defaults to 0 — the count row always renders,
  /// even before the mount wires real data.
  final int listenerCount;

  /// Session peak listeners, shown in the detail sheet header
  /// ("Peak: 214"). Defaults to 0. In-memory only until the
  /// backend lands.
  final int peakListeners;

  /// The listeners themselves, for the detail sheet — avatar,
  /// display name, listening-since. Defaults to empty. The sheet
  /// sorts them longest-listening first; the panel passes the list
  /// through untouched.
  final List<RjListener> listeners;

  final double reverb;
  final double echo;
  final double delayMs;
  final double bass;
  final String preset;
  final bool noiseCancellation;

  /// Noise-gate threshold in dB, -60 .. 0. Default -40.
  final double noiseGateThreshold;

  /// Noise gate on/off. Default false.
  final bool noiseGateEnabled;

  /// Compressor threshold in dB, -60 .. 0. Default -18 (the
  /// engine default).
  final double compressorThreshold;

  /// Compressor ratio, 1 .. 20. Default 4 (the engine default).
  final double compressorRatio;

  final ValueChanged<double>? onReverb;
  final ValueChanged<double>? onEcho;
  final ValueChanged<double>? onDelayMs;
  final ValueChanged<double>? onBass;
  final ValueChanged<String>? onPreset;
  final ValueChanged<bool>? onNoiseCancellation;
  final ValueChanged<double>? onNoiseGateThreshold;
  final ValueChanged<bool>? onNoiseGateEnabled;

  /// LIVE (v3 DSP): fired by the compressor sliders; the merge
  /// wires them to AudioDsp.setCompressor.
  final ValueChanged<double>? onCompressorThreshold;
  final ValueChanged<double>? onCompressorRatio;

  const AudioEffectsPanel({
    super.key,
    this.isHost = false,
    this.listenerCount = 0,
    this.peakListeners = 0,
    this.listeners = const [],
    this.reverb = 0.0,
    this.echo = 0.0,
    this.delayMs = 0.0,
    this.bass = 0.0,
    this.preset = 'Off',
    this.noiseCancellation = false,
    this.noiseGateThreshold = -40.0,
    this.noiseGateEnabled = false,
    this.compressorThreshold = -18.0,
    this.compressorRatio = 4.0,
    this.onReverb,
    this.onEcho,
    this.onDelayMs,
    this.onBass,
    this.onPreset,
    this.onNoiseCancellation,
    this.onNoiseGateThreshold,
    this.onNoiseGateEnabled,
    this.onCompressorThreshold,
    this.onCompressorRatio,
  });

  @override
  State<AudioEffectsPanel> createState() => _AudioEffectsPanelState();
}

class _AudioEffectsPanelState extends State<AudioEffectsPanel> {
  late double _reverb;
  late double _echo;
  late double _delayMs;
  late double _bass;
  late String? _preset;
  late bool _noiseCancellation;
  late double _noiseGateThreshold;
  late bool _noiseGateEnabled;
  late double _compressorThreshold;
  late double _compressorRatio;

  @override
  void initState() {
    super.initState();
    _reverb = widget.reverb;
    _echo = widget.echo;
    _delayMs = widget.delayMs;
    _bass = widget.bass;
    _preset = widget.preset;
    _noiseCancellation = widget.noiseCancellation;
    _noiseGateThreshold = widget.noiseGateThreshold;
    _noiseGateEnabled = widget.noiseGateEnabled;
    _compressorThreshold = widget.compressorThreshold;
    _compressorRatio = widget.compressorRatio;
  }

  @override
  void didUpdateWidget(covariant AudioEffectsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Engine-driven updates (e.g. the merge pushing a preset applied
    // from another device) flow back into the sliders.
    if (widget.reverb != oldWidget.reverb) _reverb = widget.reverb;
    if (widget.echo != oldWidget.echo) _echo = widget.echo;
    if (widget.delayMs != oldWidget.delayMs) _delayMs = widget.delayMs;
    if (widget.bass != oldWidget.bass) _bass = widget.bass;
    if (widget.preset != oldWidget.preset) _preset = widget.preset;
    if (widget.noiseCancellation != oldWidget.noiseCancellation) {
      _noiseCancellation = widget.noiseCancellation;
    }
    if (widget.noiseGateThreshold != oldWidget.noiseGateThreshold) {
      _noiseGateThreshold = widget.noiseGateThreshold;
    }
    if (widget.noiseGateEnabled != oldWidget.noiseGateEnabled) {
      _noiseGateEnabled = widget.noiseGateEnabled;
    }
    if (widget.compressorThreshold != oldWidget.compressorThreshold) {
      _compressorThreshold = widget.compressorThreshold;
    }
    if (widget.compressorRatio != oldWidget.compressorRatio) {
      _compressorRatio = widget.compressorRatio;
    }
  }

  void _applyPreset(String name) {
    final values = AudioEffectsPanel.presetValues[name];
    if (values == null) return;
    setState(() {
      _preset = name;
      _reverb = values['reverb']!;
      _echo = values['echo']!;
      _delayMs = values['delayMs']!;
      _bass = values['bass']!;
    });
    widget.onPreset?.call(name);
  }

  void _showListenersSheet() {
    showListenersDetailSheet(
      context,
      listeners: widget.listeners,
      listenerCount: widget.listenerCount,
      peakListeners: widget.peakListeners,
    );
  }

  @override
  Widget build(BuildContext context) {
    // LISTENER-VISIBLE COUNT: everyone sees the header + the live
    // listener count row (tappable -> detail sheet). Only the host
    // sees the effect controls below it.
    return MockupCard(
      animate: false,
      sparks: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(Icons.graphic_eq, color: kGold, size: 20),
              const SizedBox(width: 8),
              Text(
                'RJ STUDIO',
                style: TextStyle(
                  color: kText,
                  fontWeight: FontWeight.w900,
                  fontSize: 16,
                ),
              ),
              if (widget.isHost) ...[
                const SizedBox(width: 8),
                Text(
                  'Live host console',
                  style: TextStyle(color: kMuted, fontSize: 12),
                ),
              ],
              const Spacer(),
              // LIVE LISTENER COUNT (mockup v4): headphone icon +
              // "$count listening" in gold, tappable — opens the
              // listeners detail sheet. Visible to everyone, host
              // and listeners alike; the row always renders (even
              // "0 listening" before the mount wires real data).
              InkWell(
                key: const Key('listener-count-row'),
                onTap: _showListenersSheet,
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 4,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.headphones, color: kGold, size: 18),
                      const SizedBox(width: 6),
                      Text(
                        '${widget.listenerCount} listening',
                        style: TextStyle(
                          color: kGold,
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          if (widget.isHost) ...[
            const SizedBox(height: 12),
            _EffectSlider(
              sliderKey: const Key('reverb-slider'),
              label: 'Reverb',
              value: _reverb,
              min: 0,
              max: 1,
              divisions: 20,
              valueLabel: '${(_reverb * 100).round()}%',
              onChanged: (v) {
                setState(() {
                  _reverb = v;
                  _preset = null;
                });
                widget.onReverb?.call(v);
              },
            ),
            _EffectSlider(
              sliderKey: const Key('echo-slider'),
              label: 'Echo',
              value: _echo,
              min: 0,
              max: 1,
              divisions: 20,
              valueLabel: '${(_echo * 100).round()}%',
              onChanged: (v) {
                setState(() {
                  _echo = v;
                  _preset = null;
                });
                widget.onEcho?.call(v);
              },
            ),
            _EffectSlider(
              sliderKey: const Key('delay-slider'),
              label: 'Delay',
              value: _delayMs,
              min: 0,
              max: 500,
              divisions: 25,
              valueLabel: '${_delayMs.round()} ms',
              onChanged: (v) {
                setState(() {
                  _delayMs = v;
                  _preset = null;
                });
                widget.onDelayMs?.call(v);
              },
            ),
            _EffectSlider(
              sliderKey: const Key('bass-slider'),
              label: 'Bass',
              value: _bass,
              min: -12,
              max: 12,
              divisions: 24,
              valueLabel: '${_bass > 0 ? '+' : ''}${_bass.round()} dB',
              onChanged: (v) {
                setState(() {
                  _bass = v;
                  _preset = null;
                });
                widget.onBass?.call(v);
              },
            ),
            const SizedBox(height: 8),
            Text(
              'Preset',
              style: TextStyle(
                color: kMuted,
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: AudioEffectsPanel.presets.map((name) {
                final selected = _preset?.toLowerCase() == name.toLowerCase();
                return Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(
                      right: name == AudioEffectsPanel.presets.last ? 0 : 8,
                    ),
                    child: InkWell(
                      key: Key('preset-$name'),
                      onTap: () => _applyPreset(name),
                      borderRadius: BorderRadius.circular(10),
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        decoration: BoxDecoration(
                          color: selected
                              ? kGold
                              : kGold.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Center(
                          child: Text(
                            name,
                            style: TextStyle(
                              color: selected ? Colors.black : kGold,
                              fontWeight: FontWeight.w900,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(Icons.hearing, color: kGold, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Noise cancellation',
                        style: TextStyle(
                          color: kText,
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                      Text(
                        'Cut background noise from your mic',
                        style: TextStyle(color: kMuted, fontSize: 11),
                      ),
                    ],
                  ),
                ),
                Switch(
                  key: const Key('noise-cancellation-switch'),
                  value: _noiseCancellation,
                  activeThumbColor: kGold,
                  activeTrackColor: kGold.withValues(alpha: 0.4),
                  inactiveThumbColor: kMuted,
                  onChanged: (v) {
                    setState(() => _noiseCancellation = v);
                    widget.onNoiseCancellation?.call(v);
                  },
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(Icons.volume_off, color: kGold, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Noise gate',
                        style: TextStyle(
                          color: kText,
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                      Text(
                        'Silence everything below the threshold',
                        style: TextStyle(color: kMuted, fontSize: 11),
                      ),
                    ],
                  ),
                ),
                Switch(
                  key: const Key('noise-gate-switch'),
                  value: _noiseGateEnabled,
                  activeThumbColor: kGold,
                  activeTrackColor: kGold.withValues(alpha: 0.4),
                  inactiveThumbColor: kMuted,
                  onChanged: (v) {
                    setState(() => _noiseGateEnabled = v);
                    widget.onNoiseGateEnabled?.call(v);
                  },
                ),
              ],
            ),
            _EffectSlider(
              sliderKey: const Key('gate-threshold-slider'),
              label: 'Gate threshold',
              value: _noiseGateThreshold,
              min: -60,
              max: 0,
              divisions: 30,
              valueLabel: '${_noiseGateThreshold.round()} dB',
              onChanged: (v) {
                // Gate settings are NOT part of any preset — moving
                // them never clears the selected preset.
                setState(() => _noiseGateThreshold = v);
                widget.onNoiseGateThreshold?.call(v);
              },
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(Icons.compress, color: kGold, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Compressor',
                        style: TextStyle(
                          color: kText,
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                      Text(
                        'Even out loud and quiet voices',
                        style: TextStyle(color: kMuted, fontSize: 11),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            // LIVE (v3 DSP): threshold + ratio sliders fire
            // onCompressorThreshold / onCompressorRatio. Attack
            // (10 ms), release (100 ms) and makeup gain (0 dB) stay
            // at the engine defaults — see the file header.
            _EffectSlider(
              sliderKey: const Key('compressor-threshold-slider'),
              label: 'Compressor threshold',
              value: _compressorThreshold,
              min: -60,
              max: 0,
              divisions: 30,
              valueLabel: '${_compressorThreshold.round()} dB',
              onChanged: (v) {
                // Compressor settings are NOT part of any preset —
                // moving them never clears the selected preset.
                setState(() => _compressorThreshold = v);
                widget.onCompressorThreshold?.call(v);
              },
            ),
            _EffectSlider(
              sliderKey: const Key('compressor-ratio-slider'),
              label: 'Compressor ratio',
              value: _compressorRatio,
              min: 1,
              max: 20,
              divisions: 19,
              valueLabel: '${_compressorRatio.toStringAsFixed(1)}:1',
              onChanged: (v) {
                setState(() => _compressorRatio = v);
                widget.onCompressorRatio?.call(v);
              },
            ),
          ],
        ],
      ),
    );
  }
}

/// One labelled gold slider row. [sliderKey] lands on the [Slider]
/// itself (and nowhere else) so widget tests can find and drag it
/// directly.
class _EffectSlider extends StatelessWidget {
  final Key sliderKey;
  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String valueLabel;
  final ValueChanged<double> onChanged;

  const _EffectSlider({
    required this.sliderKey,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.valueLabel,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              label,
              style: TextStyle(
                color: kText,
                fontWeight: FontWeight.bold,
                fontSize: 13,
              ),
            ),
            Text(
              valueLabel,
              style: TextStyle(
                color: kGold,
                fontWeight: FontWeight.bold,
                fontSize: 12,
              ),
            ),
          ],
        ),
        Slider(
          key: sliderKey,
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: divisions,
          activeColor: kGold,
          inactiveColor: kMuted.withValues(alpha: 0.35),
          label: valueLabel,
          onChanged: onChanged,
        ),
      ],
    );
  }
}
