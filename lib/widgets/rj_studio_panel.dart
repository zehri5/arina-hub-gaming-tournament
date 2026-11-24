// RJ STUDIO PANEL — Group 9 restyle to Sameer's LOCKED design
// ("same yahi design chahiye", 2026-11-22 19:45).
//
// DESIGN SOURCE: ~/workspace/arena-hub-audio-dsp-external/
// rj-studio-design-final.png — matched SAME-TO-SAME, top to bottom:
// gold mic + red neon ON AIR + gold gear top bar; "RJ STUDIO" in big
// gold letters with gold rules; timer pill (clock + mm:ss + REC);
// host card (gold-ringed avatar, name, red LIVE badge, tappable
// listener count); guest strip; gold spectrum bars; 6 black knobs
// with gold rings (2 rows of 3); 4 gold-bordered soundboard pads;
// Now Playing bar; 3 vertical gold faders + NOISE GATE toggle;
// PRESETS with gold rules; big round red GO LIVE + round black/gold
// MUTE buttons; black textured-metal console background.
//
// COLOUR RULE (locked design): gold #FDC903 ONLY; red ONLY for
// live/rec (ON AIR neon, LIVE badge, REC dot, GO LIVE); green ONLY
// for the guest mic/level bars. No other accent colours.
//
// BORDER RULE OVERRIDE: the locked design itself carries gold
// outlines (soundboard pads, preset pills, GO LIVE ring, fader
// section, guest strip, spectrum frame). The design IS the rule
// here — those outlines are intentional and override the usual
// no-full-border rule. Nothing else gets a full border.
//
// ⚠️ VOICE-INSTANCE CORRECTION (SETUP-music-player.md warning b):
// the AI Studio snippet wires this panel to `musicPlayer.dsp` —
// that is WRONG for voice effects. The panel controls the HOST'S
// VOICE (mic chain). The mount MUST pass the live mic chain's DSP
// handle — the `DspMicProcessor` resolved by `_rjLiveDsp()` (the
// DSP child of the composite when the picker is DSP + RNNoise) —
// through the `RjVoiceDsp` control plane below, NEVER
// `musicPlayer.dsp` and NEVER a fresh `AudioDsp()`: a fresh
// `AudioDsp` owns a private engine no live mic frame flows
// through, so the knobs would move numbers no one hears. The
// music player keeps its own separate instance. See
// RJ_PANEL_INTEGRATION.md §7.
//
// KNOB MAPPINGS (knobs REPLACE the old slider rows; same parameters,
// same ranges — the values shown in the design image, e.g. REVERB
// 60%, are EXAMPLE states, not fixed defaults; knobs reflect live
// state):
//
// | Knob       | Parameter            | Range            | Display  | DSP call |
// |------------|----------------------|------------------|----------|----------|
// | REVERB     | reverb mix           | 0..1             | %        | setReverb wetDryMix |
// | ECHO       | echo mix             | 0..1             | %        | setEcho mix |
// | BASS       | bass boost           | 0..+12 dB        | +X dB    | setEq bassBoostDb |
// | COMPRESSOR | compressor amount    | 0..1             | %        | setCompressor (threshold/ratio/makeup derived) |
// | TREBLE     | EQ high-band gain    | 0..+12 dB        | %        | setEq highGainDb |
// | DELAY      | echo delay           | 50..500 ms       | ms       | setEcho delayMs |
//
// TREBLE DECISION (documented — the AI Studio panel had no treble
// control): TREBLE % is a boost-only high-band gain, 0% = 0 dB,
// 100% = +12 dB (highGainDb = pct * 12), mirroring the boost-only
// BASS knob. The design's "55%" example therefore means +6.6 dB.
// Preset high-gain values map the same way (Radio +1.5 dB = 13%).
//
// DELAY RANGE DECISION (documented — the AI Studio panel had NO
// delay slider; delay was preset-only): the knob spans 50..500 ms,
// matching the AudioEffectsPanel delay range (0..500 ms) and
// covering every preset value (140/200/250/280 ms). The native
// setEcho clamp is 1..2000 ms, so the knob range is a UI choice,
// not an engine limit.
//
// KNOB INTERACTION: vertical drag (up = increase, 120 px = full
// range). Drags accumulate from the value at gesture start (v2
// port), so a drag stays smooth even if the parent rebuilds late
// — the value prop is only read once, at drag start. Faders
// likewise use vertical drag (110 px = full range) plus
// tap-to-jump. This is a deliberate choice for a phone console:
// knobs are small and a rotary drag is fiddly on touch. (v2's
// "RotaryKnob" is linear-drag too, despite the name — its pan
// handler adds -dy and dx terms, no angle math.)
//
// PRESET DISTINCTION: this panel keeps the AI Studio VOICE-console
// presets — Radio / Concert / Studio / Off — and each preset sets
// ALL SIX knob values (treble + delay included; the other four keep
// the AI Studio values). The music path's Off / Room / Hall preset
// definition (AudioEffectsPanel.presetValues, Group 8
// PlaybackEffects) is a DIFFERENT surface and is NOT changed by
// this work. Do not merge the two preset sets.
//
// SPECTRUM ANALYZER: the gold bars are a segmented LED strip
// (7 segments per bar, like the design). When spectrumStream is
// supplied, the bars show its REAL per-band values (a real FFT
// source, when one lands); otherwise the strip is a LEVEL-DRIVEN
// DECORATIVE visualization fed by levelStream — bar heights vary
// deterministically with the live level, no frequency analysis
// runs anywhere in this widget. With the default empty
// levelStream the bars sit at idle height; the level is never
// faked.
//
// V2 MERGE (AUDIO #10, 2026-11-22 — see RJ_PANEL_INTEGRATION.md
// §8): the AI Studio v2 knob panel was reviewed line-by-line
// against this restyle and its better pieces were ported in: the
// segmented LED spectrum painter + an optional spectrumStream
// prop (real FFT when a source lands; the level-driven
// synthesized fallback stays decorative), the brushed-metal
// texture + screw-dot chassis, the mic-with-waves top icon, the
// 19-tick lit knob face, fader scale ticks + tap-to-jump, and
// the centred locked view. NOT taken: v2's Soundboard prop (no
// Soundboard class exists in this tree), its AudioDsp control
// plane (wrong for voice — RjVoiceDsp stays), its panel-owned
// noise gate (the mount owns the gate), its bipolar treble
// (-6..+6 dB vs the design's %), its 0 ms delay floor, or its
// always-on REC dot. v2's `isAvailable` bug (the real method is
// `isPadAvailable`) was fixed in the review copy before the copy
// was deleted.
//
// HOST-ONLY LOCK: non-hosts see the locked state (no knobs, no
// console). The listener count lives inside the host card, so it
// stays inside the locked console. The SEPARATE AudioEffectsPanel
// carries the listener-visible count — that split is deliberate:
// listeners never see this console.
//
// NOISE GATE: the toggle fires [onNoiseGateChanged] only — it does
// NOT drive the DSP directly. The mount wires it to the mic
// chain's setNoiseGate (like AudioEffectsPanel's onNoiseGateEnabled
// callback). The preset's internal gate % still pushes to the
// panel's own dsp instance (existing behaviour, preserved).
//
// SOUNDBOARD: the four pads are WIRED CALLBACKS via [onSoundboard]
// ([RjSoundboardPad]) — the integration point for the external
// soundboard code when it lands from AI Studio. Pads always render;
// a tap fires the callback when provided. The four pad glyphs
// (clapping hands, megaphone, laughing face, drum) are emoji text,
// matching the locked design — the ONLY emoji in this widget;
// everything else uses Material icons.
//
// GEAR ICON: opens Room Settings via [onSettingsPressed] (FIX 20
// fix 10) — the mount passes the room's _showRoomSettings. Null
// = decorative (the design shows it; no settings screen exists
// for that mount yet). It is a real button when wired, never a
// dead button.
//
// PURE WIDGET: this file takes dsp + streams + callbacks as props
// and imports no LiveKit service, no Supabase, no room_screen. The
// only service import is the shared [RjListener] model
// (live_listeners.dart) for the [listeners] prop type.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/live_listeners.dart';
import '../services/radio_mixer.dart';

/// Soundboard pad identifiers. The mount maps these to the external
/// soundboard player when it lands from AI Studio.
enum RjSoundboardPad { applause, airHorn, laugh, drum }

enum _RjPreset { radio, concertHall, studio, off }

// --- Locked-design constants (shared by the panel + [RjKnob]). ---

const Color _kBgBlack = Color(0xFF0A0A0C);
const Color _kCardDarkGrey = Color(0xFF16161A);
const Color _kSurfaceGrey = Color(0xFF222228);
const Color _kGold = Color(0xFFFDC903);
const Color _kLiveRed = Color(0xFFE53935);
const Color _kGuestGreen = Color(0xFF3DDC84);
const Color _kTextPrimary = Color(0xFFF5F5F7);
const Color _kTextMuted = Color(0xFF8E8E98);

/// Vertical drag distance (px) for a knob's full 0..1 range.
const double _kKnobDragSpanPx = 120.0;

/// Vertical drag distance (px) for a fader's full 0..1 range.
const double _kFaderDragSpanPx = 110.0;

/// BASS / TREBLE knob full-scale boost (dB).
const double _kMaxBoostDb = 12.0;

/// DELAY knob range (ms) — see the header note.
const double _kDelayMinMs = 50.0;
const double _kDelayMaxMs = 500.0;

/// mm:ss formatter (hours fold into minutes; negatives clamp to 0).
String _mmss(Duration d) {
  final int totalSeconds = d.inSeconds < 0 ? 0 : d.inSeconds;
  final String minutes = (totalSeconds ~/ 60).toString().padLeft(2, '0');
  final String seconds = (totalSeconds % 60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}

/// "+6 dB" / "+6.5 dB" — whole numbers print without a decimal.
String _formatDb(double db) {
  final double rounded = (db * 10).round() / 10;
  if (rounded == rounded.roundToDouble()) {
    return '+${rounded.toInt()} dB';
  }
  return '+${rounded.toStringAsFixed(1)} dB';
}

/// RJ VOICE DSP — the control plane the panel drives (AUDIO #10
/// mount, 2026-11-22).
///
/// The panel used to take a concrete `AudioDsp`; that was the wrong
/// control plane for voice — no voice-chain `AudioDsp` instance
/// exists, and the live mic flows through `DspMicProcessor` /
/// `CompositeMicProcessor` instead (see RJ_PANEL_INTEGRATION.md
/// §7). The two control planes expose the same five live setters
/// with identical named parameters, so the panel drives them
/// through this small interface. Dart is NOMINALLY typed, so the
/// classes do NOT satisfy it by matching members alone — and the
/// return types differ (`DspMicProcessor` setters return
/// `Future<bool>`, `AudioDsp` setters `Future<void>`), so no
/// single return type could cover both. The voice mount therefore
/// wraps the live `DspMicProcessor` in `RjDspMicAdapter`
/// (room_screen.dart), which forwards the five setters and drops
/// the bool result the panel never reads. An `AudioDsp` would
/// need the same treatment if it ever mounted this panel; today
/// it doesn't (the music sheet keeps `AudioEffectsPanel`).
///
/// Only the five setters + `isInitialized` are on the interface:
/// that is everything the panel's `_push*` methods call. Init /
/// dispose / process stay on the concrete classes — the mount
/// owns the instance's lifecycle, the panel only pushes numbers.
abstract class RjVoiceDsp {
  /// True once the engine behind the setters is ready; the panel
  /// pushes nothing while this is false.
  bool get isInitialized;

  /// Live EQ (four-band, dB). Engine ranges: bass 0..12, the rest
  /// -12..12.
  Future<void> setEq({
    bool enabled = true,
    double bassBoostDb = 0.0,
    double lowGainDb = 0.0,
    double midGainDb = 0.0,
    double highGainDb = 0.0,
  });

  /// Live echo (delay): delayMs 1..2000, feedback 0..0.95, mix 0..1.
  Future<void> setEcho({
    bool enabled = true,
    double delayMs = 250.0,
    double feedback = 0.35,
    double mix = 0.35,
  });

  /// Live reverb: wetDryMix, roomSize, damping all 0..1.
  Future<void> setReverb({
    bool enabled = true,
    double wetDryMix = 0.3,
    double roomSize = 0.5,
    double damping = 0.5,
  });

  /// Live noise gate: thresholdDb -90..0, attackMs 0.1..500,
  /// releaseMs 5..2000.
  Future<void> setNoiseGate({
    bool enabled = true,
    double thresholdDb = -40.0,
    double attackMs = 5.0,
    double releaseMs = 120.0,
  });

  /// Live compressor: thresholdDb -60..0, ratio 1..20, attackMs
  /// 0.1..200, releaseMs 5..2000, makeupGainDb 0..24.
  Future<void> setCompressor({
    bool enabled = true,
    double thresholdDb = -18.0,
    double ratio = 4.0,
    double attackMs = 10.0,
    double releaseMs = 100.0,
    double makeupGainDb = 0.0,
  });
}

class RjStudioPanel extends StatefulWidget {
  const RjStudioPanel({
    super.key,
    this.dsp,
    required this.isHost,
    this.levelStream = const Stream<double>.empty(),
    this.spectrumStream,
    required this.hostName,
    this.hostAvatarUrl,
    this.isLive = false,
    this.isMuted = false,
    required this.onGoLivePressed,
    required this.onMutePressed,
    this.onSettingsPressed,
    this.listenerCount = 0,
    this.onListenersTap,
    this.listeners = const [],
    this.guestName,
    this.guestLevel = 0.0,
    this.liveElapsed = Duration.zero,
    this.nowPlayingTitle,
    this.nowPlayingPosition = Duration.zero,
    this.nowPlayingDuration = Duration.zero,
    this.onMicVolume,
    this.onGuestVolume,
    this.onMusicVolume,
    this.micVolume = 0.8,
    this.musicVolume = 0.8,
    // FIX 24: the MIC ON/OFF button gates the inverse link (ON =
    // link active, OFF = manual faders) + the live call-in picker.
    this.micLinkOn = true,
    this.onMicLinkChanged,
    this.callInSeats = const [],
    this.selectedCallInUid,
    this.onCallInSelected,
    this.noiseGateEnabled = false,
    this.onNoiseGateChanged,
    this.onSoundboard,
  });

  /// The live DSP control plane the knobs + presets drive — the
  /// mic chain's `DspMicProcessor` for the voice console (resolved
  /// via `_rjLiveDsp()`), or an `AudioDsp` for the music path.
  /// NULLABLE (FIX 22 item 6): the panel builds regardless of the
  /// mic processor — with no DSP the knobs + presets + noise gate
  /// render dimmed + untappable ([_dspGated]) and everything else
  /// (GO LIVE, MUTE, faders, soundboard, listeners) keeps working.
  /// NEVER a fresh `AudioDsp()` for voice — its private engine
  /// processes no live mic frames (see the header correction +
  /// RJ_PANEL_INTEGRATION §7).
  final RjVoiceDsp? dsp;

  /// True only for the room host (the RJ). False renders the locked
  /// state — listeners never see the console.
  final bool isHost;

  /// Live mic level stream (0..1) driving the spectrum bars.
  /// Optional: no mic-level stream exists yet (RJ_PANEL_INTEGRATION
  /// §6.2), so the default is an empty stream and the bars sit at
  /// idle height until a real level source lands. The level is
  /// never faked.
  final Stream<double> levelStream;

  /// Optional REAL spectrum values (per-band 0..1, any length —
  /// mapped onto the 28 bars). When supplied, the bars show these
  /// instead of the level-driven synthesis. No FFT source exists
  /// yet (RJ_PANEL_INTEGRATION §8); null = synthesized from
  /// [levelStream].
  final Stream<List<double>>? spectrumStream;

  final String hostName;
  final String? hostAvatarUrl;
  final bool isLive;
  final bool isMuted;
  final VoidCallback onGoLivePressed;
  final VoidCallback onMutePressed;

  /// Fired when the host taps the top-right gear — the mount
  /// opens Room Settings (FIX 20 fix 10). Null = the gear is
  /// decorative (no settings screen for that mount).
  final VoidCallback? onSettingsPressed;

  /// Live listener count, from LiveListeners.listenerCount.
  final int listenerCount;

  /// Fired when the host taps the listener count — the mount opens
  /// the listeners detail sheet. Null = the count is not tappable.
  final VoidCallback? onListenersTap;

  /// Live listener list, from LiveListeners.listeners. Passed
  /// through for the mount (the detail sheet's rows); this panel
  /// does NOT build the sheet — the G9-listeners agent owns it.
  final List<RjListener> listeners;

  /// On-mic guest name. Null = the guest strip hides.
  final String? guestName;

  /// Guest mic level (0..1) driving the green guest bars.
  final double guestLevel;

  /// Time since GO LIVE; drives the timer pill. The REC dot + ON AIR
  /// sign show only when [isLive] is true.
  final Duration liveElapsed;

  /// Now-playing track title. Null = the Now Playing bar hides.
  final String? nowPlayingTitle;

  /// Now-playing position / total (the "02:15 / 04:30" readout).
  final Duration nowPlayingPosition;
  final Duration nowPlayingDuration;

  /// Fader callbacks (0..1). Null = that fader still moves locally
  /// but drives nothing.
  final ValueChanged<double>? onMicVolume;
  final ValueChanged<double>? onGuestVolume;
  final ValueChanged<double>? onMusicVolume;

  /// FIX 22 item 11 — the mount's current MIC + MUSIC levels (the
  /// room's single source of truth: _micFaderLevel +
  /// _musicBaseVolume). The panel initializes its faders from
  /// these and re-syncs in didUpdateWidget, so the inverse link's
  /// nudge (music up -> mic down, mic up -> music down) shows on
  /// the OTHER fader at once. Defaults 0.8 = the old hardcoded
  /// fader positions, for mounts that do not pass them. GUEST has
  /// no mount value (no per-participant volume exists) and stays
  /// panel-owned.
  final double micVolume;
  final double musicVolume;

  /// FIX 24 — the panel MIC ON/OFF button (mount-owned): ON
  /// (default) = the inverse link is active (mic down -> music
  /// up, mic up -> music down); OFF = the mic fader is be-asar
  /// and the music fader is manual. The mount pushes the mixer
  /// gains when this flips — listeners hear the host's mix live.
  final bool micLinkOn;

  /// Fired when the host taps the MIC ON/OFF button.
  final ValueChanged<bool>? onMicLinkChanged;

  /// FIX 24 — the live call-in seats (all mic seats, occupied +
  /// empty) for the picker. Only APPROVED seat occupants appear
  /// occupied — the mount builds this from the seat-grid
  /// assignment. Empty = the picker section hides.
  final List<RjCallInSeat> callInSeats;

  /// The host's selected call-in guest uid (null = none).
  final String? selectedCallInUid;

  /// Fired when the host taps a seat: the uid to go live with, or
  /// null when the host deselects (taps the selected seat again).
  final ValueChanged<String?>? onCallInSelected;

  /// Noise-gate toggle state (mount-owned).
  final bool noiseGateEnabled;

  /// Fired when the host flips the NOISE GATE toggle. The mount
  /// wires it to the mic chain's setNoiseGate — this panel does NOT
  /// drive the DSP from the toggle.
  final ValueChanged<bool>? onNoiseGateChanged;

  /// Soundboard pad taps (integration point for the external
  /// soundboard code). Null = pads render but fire nothing.
  final ValueChanged<RjSoundboardPad>? onSoundboard;

  @override
  State<RjStudioPanel> createState() => _RjStudioPanelState();
}

class _RjStudioPanelState extends State<RjStudioPanel> {
  double _reverbMix = 0.0;
  double _reverbRoomSize = 0.5;
  double _echoMix = 0.0;
  double _echoDelayMs = 250.0;
  double _echoFeedback = 0.35;
  double _bassBoostDb = 0.0;
  double _lowGainDb = 0.0;
  double _midGainDb = 0.0;
  double _highGainDb = 0.0;
  double _noiseGatePct = 0.0;
  double _compressorPct = 0.0;

  /// TREBLE knob position 0..1; highGainDb = _treblePct * 12.
  double _treblePct = 0.0;

  /// Fader positions 0..1 — initialized from the mount's
  /// [RjStudioPanel.micVolume] / [RjStudioPanel.musicVolume] in
  /// initState and re-synced in didUpdateWidget (FIX 22 item 11:
  /// the mount is the single source of truth, so the inverse
  /// link's nudge shows on the other fader). GUEST stays
  /// panel-owned (no mount value exists). 0.8 = the design's
  /// roughly-two-thirds look.
  late double _micVolume;
  double _guestVolume = 0.8;
  late double _musicVolume;

  /// Toggle mirror of widget.noiseGateEnabled (synced in
  /// didUpdateWidget so the mount stays the source of truth).
  late bool _noiseGateOn;

  _RjPreset? _activePreset = _RjPreset.off;

  // Spectrum: 28 segmented LED bars. Real per-band values when
  // spectrumStream is supplied, else a deterministic level-driven
  // synthesis from levelStream (decorative shape, real level).
  static const int _kSpectrumBars = 28;
  final ValueNotifier<List<double>> _spectrumNotifier =
      ValueNotifier<List<double>>(List<double>.filled(_kSpectrumBars, 0.08));
  StreamSubscription<double>? _levelSub;
  StreamSubscription<List<double>>? _spectrumSub;
  double _lastLevel = 0.0;
  int _frameTick = 0;

  // FIX 20 (fix 12): drag-throttle — every knob/fader drag tick
  // used to rebuild the WHOLE panel (setState) AND fire an
  // unawaited native DSP call, so each drag pixel cost a full
  // rebuild + a platform-channel call (the lag Sameer felt).
  // Now: at most one DSP push per 50ms per control + at most one
  // panel rebuild per 50ms, each with a TRAILING call carrying
  // the exact final value (never dropped). Pushes read state at
  // fire time, so the trailing push is always exact. Single taps
  // (presets, toggles) are unaffected — only drags throttle.
  static const Duration _dragThrottle = Duration(milliseconds: 50);
  final Map<String, DateTime> _dspPushLast = {};
  final Map<String, Timer?> _dspPushPending = {};
  DateTime? _panelRefreshLast;
  Timer? _panelRefreshPending;

  void _throttledPush(String key, void Function() push) {
    final now = DateTime.now();
    final last = _dspPushLast[key];
    if (last == null || now.difference(last) >= _dragThrottle) {
      _dspPushLast[key] = now;
      _dspPushPending[key]?.cancel();
      _dspPushPending[key] = null;
      push();
      return;
    }
    _dspPushPending[key]?.cancel();
    _dspPushPending[key] = Timer(_dragThrottle - now.difference(last), () {
      _dspPushPending[key] = null;
      _dspPushLast[key] = DateTime.now();
      if (mounted) push();
    });
  }

  void _throttledPanelRefresh() {
    final now = DateTime.now();
    if (_panelRefreshLast == null ||
        now.difference(_panelRefreshLast!) >= _dragThrottle) {
      _panelRefreshLast = now;
      _panelRefreshPending?.cancel();
      _panelRefreshPending = null;
      if (mounted) setState(() {});
      return;
    }
    _panelRefreshPending?.cancel();
    _panelRefreshPending =
        Timer(_dragThrottle - now.difference(_panelRefreshLast!), () {
      _panelRefreshPending = null;
      _panelRefreshLast = DateTime.now();
      if (mounted) setState(() {});
    });
  }

  @override
  void initState() {
    super.initState();
    _micVolume = widget.micVolume.clamp(0.0, 1.0);
    _musicVolume = widget.musicVolume.clamp(0.0, 1.0);
    _noiseGateOn = widget.noiseGateEnabled;
    _subscribeSpectrumStreams();
  }

  @override
  void didUpdateWidget(covariant RjStudioPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.noiseGateEnabled != widget.noiseGateEnabled) {
      _noiseGateOn = widget.noiseGateEnabled;
    }
    // FIX 22 item 11: the mount's levels win — when the inverse
    // link nudges the other fader (or the player stepper moves
    // the mic), the panel follows the new prop value.
    if (oldWidget.micVolume != widget.micVolume) {
      _micVolume = widget.micVolume.clamp(0.0, 1.0);
    }
    if (oldWidget.musicVolume != widget.musicVolume) {
      _musicVolume = widget.musicVolume.clamp(0.0, 1.0);
    }
    if (oldWidget.levelStream != widget.levelStream ||
        oldWidget.spectrumStream != widget.spectrumStream) {
      _unsubscribeSpectrumStreams();
      _subscribeSpectrumStreams();
    }
  }

  @override
  void dispose() {
    _unsubscribeSpectrumStreams();
    _spectrumNotifier.dispose();
    for (final t in _dspPushPending.values) {
      t?.cancel();
    }
    _panelRefreshPending?.cancel();
    super.dispose();
  }

  void _subscribeSpectrumStreams() {
    _levelSub = widget.levelStream.listen((double level) {
      _lastLevel = level.clamp(0.0, 1.0);
      if (widget.spectrumStream == null) {
        _frameTick++;
        _spectrumNotifier.value = _synthesizeSpectrum(_lastLevel);
      }
    }, onError: (_) {});
    if (widget.spectrumStream != null) {
      _spectrumSub = widget.spectrumStream!.listen((List<double> raw) {
        if (raw.isEmpty) {
          _spectrumNotifier.value = List<double>.filled(_kSpectrumBars, 0.08);
          return;
        }
        final List<double> mapped = List<double>.generate(_kSpectrumBars, (
          int i,
        ) {
          final int idx = ((i / _kSpectrumBars) * raw.length).floor().clamp(
                0,
                raw.length - 1,
              );
          return raw[idx].clamp(0.06, 1.0);
        });
        _spectrumNotifier.value = mapped;
      }, onError: (_) {});
    }
  }

  void _unsubscribeSpectrumStreams() {
    _levelSub?.cancel();
    _levelSub = null;
    _spectrumSub?.cancel();
    _spectrumSub = null;
  }

  /// Deterministic level-driven bar heights (ported from the v2
  /// panel): a sine envelope + a slowly rotating harmonic, scaled
  /// by the REAL level. The shape is decorative; the level is not.
  List<double> _synthesizeSpectrum(double level) {
    final List<double> bars = List<double>.filled(_kSpectrumBars, 0.08);
    final double phase = _frameTick * 0.45;
    for (int i = 0; i < _kSpectrumBars; i++) {
      final double norm = i / (_kSpectrumBars - 1);
      final double envelope =
          0.45 + 0.55 * math.sin(norm * math.pi).clamp(0.0, 1.0);
      final double harmonic =
          0.65 + 0.35 * math.sin(phase + i * 0.72 + level * 4.0);
      final double v = 0.08 + (level * envelope * harmonic * 0.92);
      bars[i] = v.clamp(0.08, 1.0);
    }
    return bars;
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.isHost) {
      return _buildLockedState();
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[Color(0xFF141416), _kBgBlack],
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      child: CustomPaint(
        painter: _MetalTexturePainter(),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildTopBar(),
            const SizedBox(height: 10),
            _buildTitleRow(),
            const SizedBox(height: 10),
            _buildTimerPill(),
            const SizedBox(height: 10),
            _buildHostCard(),
            if (widget.guestName != null) ...[
              const SizedBox(height: 10),
              _buildGuestStrip(),
            ],
            // FIX 24: live call-in picker — the 6 mic seats (only
            // approved occupants tappable). Hidden when the mount
            // passes no seats.
            if (widget.callInSeats.isNotEmpty) ...[
              const SizedBox(height: 10),
              _buildCallInSection(),
            ],
            const SizedBox(height: 10),
            _buildSpectrum(),
            const SizedBox(height: 12),
            _buildKnobGrid(),
            const SizedBox(height: 12),
            _buildSoundboard(),
            if (widget.nowPlayingTitle != null) ...[
              const SizedBox(height: 10),
              _buildNowPlaying(),
            ],
            const SizedBox(height: 10),
            _buildFadersAndGate(),
            const SizedBox(height: 12),
            _buildPresets(),
            const SizedBox(height: 14),
            _buildBottomActions(),
          ],
        ),
      ),
    );
  }

  Widget _buildLockedState() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
      decoration: BoxDecoration(
        color: _kBgBlack,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _kGold.withValues(alpha: 0.55), width: 1.4),
        boxShadow: <BoxShadow>[
          BoxShadow(color: _kGold.withValues(alpha: 0.11), blurRadius: 16),
        ],
      ),
      child: CustomPaint(
        painter: _MetalTexturePainter(),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _kCardDarkGrey,
                border: Border.all(color: _kGold, width: 2),
                boxShadow: <BoxShadow>[
                  BoxShadow(
                    color: _kGold.withValues(alpha: 0.25),
                    blurRadius: 12,
                  ),
                ],
              ),
              child: const Icon(Icons.lock_rounded, color: _kGold, size: 28),
            ),
            const SizedBox(height: 14),
            const Text(
              'RJ STUDIO',
              style: TextStyle(
                color: _kGold,
                fontSize: 20,
                fontWeight: FontWeight.w900,
                letterSpacing: 2.0,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Host only — audio controls are locked for listeners.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: _kTextMuted,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // --- Top bar: gold mic (left) + ON AIR (center) + gold gear (right). ---

  Widget _buildTopBar() {
    return Row(
      children: [
        const SizedBox(
          width: 48,
          height: 36,
          child: CustomPaint(painter: _StudioMicWavesPainter()),
        ),
        Expanded(
          child: Center(
            child: widget.isLive ? _buildOnAirSign() : _buildOffAirSign(),
          ),
        ),
        // FIX 20 (fix 10): a REAL button now — opens Room Settings
        // via onSettingsPressed (null = decorative, same look).
        InkWell(
          onTap: widget.onSettingsPressed,
          borderRadius: BorderRadius.circular(20),
          child: const Padding(
            padding: EdgeInsets.all(4),
            child: Icon(Icons.settings, color: _kGold, size: 28),
          ),
        ),
      ],
    );
  }

  Widget _buildOnAirSign() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        color: _kLiveRed,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFFF8A80), width: 1.5),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: _kLiveRed.withValues(alpha: 0.55),
            blurRadius: 16,
            spreadRadius: 1,
          ),
        ],
      ),
      child: const Text(
        'ON AIR',
        style: TextStyle(
          color: Colors.white,
          fontSize: 20,
          fontWeight: FontWeight.w900,
          letterSpacing: 1.5,
        ),
      ),
    );
  }

  Widget _buildOffAirSign() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        color: _kCardDarkGrey,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _kSurfaceGrey, width: 1.5),
      ),
      child: const Text(
        'OFF AIR',
        style: TextStyle(
          color: _kTextMuted,
          fontSize: 20,
          fontWeight: FontWeight.w900,
          letterSpacing: 1.5,
        ),
      ),
    );
  }

  // --- Title: gold rules + "RJ STUDIO" in big gold letters. ---

  Widget _buildTitleRow() {
    return Row(
      children: [
        Expanded(
          child: Container(
            height: 3,
            decoration: BoxDecoration(
              color: _kGold,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            'RJ STUDIO',
            style: TextStyle(
              color: _kGold,
              fontSize: 26,
              fontWeight: FontWeight.w900,
              letterSpacing: 2.0,
            ),
          ),
        ),
        Expanded(
          child: Container(
            height: 3,
            decoration: BoxDecoration(
              color: _kGold,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
      ],
    );
  }

  // --- Timer pill: clock + mm:ss (+ red REC dot when live). ---

  Widget _buildTimerPill() {
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: _kCardDarkGrey,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: _kSurfaceGrey),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.access_time, size: 16, color: _kTextPrimary),
            const SizedBox(width: 6),
            Text(
              _mmss(widget.liveElapsed),
              style: const TextStyle(
                color: _kTextPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
            if (widget.isLive) ...[
              const SizedBox(width: 10),
              const Text(
                '|',
                style: TextStyle(color: _kTextMuted, fontSize: 14),
              ),
              const SizedBox(width: 10),
              Container(
                width: 9,
                height: 9,
                decoration: const BoxDecoration(
                  color: _kLiveRed,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 5),
              const Text(
                'REC',
                style: TextStyle(
                  color: _kTextPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.8,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // --- Host card: gold-ringed avatar + name + LIVE badge + listeners. ---

  Widget _buildHostCard() {
    return _ConsoleChassis(
      padding: const EdgeInsets.all(12),
      borderColor: _kGold.withValues(alpha: 0.45),
      child: Row(
        children: [
          _buildAvatar(),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.hostName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: _kTextPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    if (widget.isLive)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 9,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: _kLiveRed,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.play_arrow,
                              color: Colors.white,
                              size: 12,
                            ),
                            SizedBox(width: 2),
                            Text(
                              'LIVE',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.8,
                              ),
                            ),
                          ],
                        ),
                      )
                    else
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 9,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: _kSurfaceGrey,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Text(
                          'OFFLINE',
                          style: TextStyle(
                            color: _kTextMuted,
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.8,
                          ),
                        ),
                      ),
                    const SizedBox(width: 8),
                    const Text(
                      '|',
                      style: TextStyle(color: _kTextMuted, fontSize: 13),
                    ),
                    const SizedBox(width: 8),
                    Flexible(child: _buildListenersCount()),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildListenersCount() {
    final Widget content = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.people, size: 16, color: _kTextPrimary),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            '${widget.listenerCount} listening',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: _kTextPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
    final VoidCallback? tap = widget.onListenersTap;
    if (tap == null) {
      return content;
    }
    return GestureDetector(
      key: const Key('listeners-count'),
      behavior: HitTestBehavior.opaque,
      onTap: tap,
      child: content,
    );
  }

  Widget _buildAvatar() {
    final String? url = widget.hostAvatarUrl;
    final String initial = widget.hostName.trim().isNotEmpty
        ? widget.hostName.trim()[0].toUpperCase()
        : 'H';

    final Widget inner;
    if (url != null && url.trim().isNotEmpty) {
      inner = CircleAvatar(
        radius: 26,
        backgroundColor: _kSurfaceGrey,
        backgroundImage: NetworkImage(url),
        onBackgroundImageError: (_, __) {},
      );
    } else {
      inner = CircleAvatar(
        radius: 26,
        backgroundColor: _kGold.withValues(alpha: 0.16),
        child: Text(
          initial,
          style: const TextStyle(
            color: _kGold,
            fontSize: 20,
            fontWeight: FontWeight.w800,
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(2.5),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: _kGold, width: 2.5),
      ),
      child: inner,
    );
  }

  // --- Guest strip: small avatar + "Guest: <name>" + green mic/bars. ---

  Widget _buildGuestStrip() {
    final String name = widget.guestName!;
    final String initial =
        name.trim().isNotEmpty ? name.trim()[0].toUpperCase() : 'G';
    final double level = widget.guestLevel.clamp(0.0, 1.0);
    final int activeBars = (level * 5).round();
    const List<double> barHeights = <double>[8, 14, 20, 14, 10];

    return Container(
      key: const Key('guest-strip'),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: _kCardDarkGrey,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _kGold.withValues(alpha: 0.6)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(1.5),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: _kGold, width: 1.5),
            ),
            child: CircleAvatar(
              radius: 14,
              backgroundColor: _kGold.withValues(alpha: 0.16),
              child: Text(
                initial,
                style: const TextStyle(
                  color: _kGold,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Guest: $name',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: _kTextPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const Icon(Icons.mic, color: _kGuestGreen, size: 20),
          const SizedBox(width: 10),
          Row(
            key: const Key('guest-level-bars'),
            crossAxisAlignment: CrossAxisAlignment.end,
            children: List<Widget>.generate(5, (int i) {
              final bool active = i < activeBars;
              return Container(
                width: 4,
                height: barHeights[i],
                margin: EdgeInsets.only(right: i == 4 ? 0 : 2),
                decoration: BoxDecoration(
                  color: active ? _kGuestGreen : _kSurfaceGrey,
                  borderRadius: BorderRadius.circular(1.5),
                ),
              );
            }),
          ),
        ],
      ),
    );
  }

  // FIX 24 — live call-in picker: the 6 mic seats (radio
  // live-call style). Tapping an occupied seat puts that person
  // LIVE with the host (their voice already reaches all listeners
  // — both engines publish every unmuted seat occupant and
  // subscribe to all tracks — so the pick is a SPOTLIGHT: the
  // guest strip shows them and their speech ducks the mix music).
  // Tapping the selected seat again deselects (call-in ends);
  // tapping another seat switches the guest. Empty seats render
  // dimmed ("khaali") and untappable — only approved occupants
  // are ever listed (the mount builds the seats from the
  // seat-grid assignment).
  Widget _buildCallInSection() {
    return Container(
      key: const Key('call-in-section'),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: _kCardDarkGrey,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _kGold.withValues(alpha: 0.5)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'LIVE CALL-IN',
            style: TextStyle(
              color: _kTextPrimary,
              fontSize: 12,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(height: 6),
          for (final seat in widget.callInSeats)
            _buildCallInRow(seat),
        ],
      ),
    );
  }

  Widget _buildCallInRow(RjCallInSeat seat) {
    final bool selected =
        seat.uid != null && seat.uid == widget.selectedCallInUid;
    final bool occupied = seat.occupied;
    return GestureDetector(
      key: Key('call-in-seat-${seat.seatNo}'),
      behavior: HitTestBehavior.opaque,
      onTap: occupied
          ? () => widget.onCallInSelected
              ?.call(selected ? null : seat.uid)
          : null,
      child: Opacity(
        opacity: occupied ? 1.0 : 0.45,
        child: Container(
          margin: const EdgeInsets.only(bottom: 4),
          padding:
              const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: selected
                ? _kGold.withValues(alpha: 0.18)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: selected
                ? Border.all(color: _kGold, width: 1.2)
                : null,
          ),
          child: Row(
            children: [
              Container(
                width: 24,
                height: 24,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: selected
                      ? _kGold
                      : _kSurfaceGrey,
                ),
                child: Text(
                  '${seat.seatNo}',
                  style: TextStyle(
                    color: selected ? _kBgBlack : _kTextMuted,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  occupied ? (seat.name ?? 'Player') : 'khaali',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: occupied ? _kTextPrimary : _kTextMuted,
                    fontSize: 13,
                    fontWeight:
                        selected ? FontWeight.w800 : FontWeight.w600,
                  ),
                ),
              ),
              if (occupied) ...[
                Icon(
                  seat.muted ? Icons.mic_off : Icons.mic,
                  color: seat.muted ? _kTextMuted : _kGuestGreen,
                  size: 16,
                ),
                const SizedBox(width: 6),
              ],
              if (selected)
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: _kGold,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text(
                    'LIVE',
                    style: TextStyle(
                      color: _kBgBlack,
                      fontSize: 10,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // --- Gold spectrum bars: segmented LED strip (7 segments per
  // bar, like the design). Real per-band values from spectrumStream
  // when supplied; otherwise a level-driven decorative synthesis
  // from levelStream (the LEVEL is real, the frequency shape is
  // decorative — NOT an FFT). Idle height with no level source.

  Widget _buildSpectrum() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: _kCardDarkGrey,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _kGold.withValues(alpha: 0.5)),
      ),
      child: SizedBox(
        height: 40,
        child: ValueListenableBuilder<List<double>>(
          valueListenable: _spectrumNotifier,
          builder: (BuildContext context, List<double> bars, _) {
            return CustomPaint(
              size: const Size(double.infinity, double.infinity),
              painter: _SpectrumPainter(bars: bars),
            );
          },
        ),
      ),
    );
  }

  // --- 6 knobs, 2 rows of 3 (replace the old slider rows). ---

  Widget _buildKnobGrid() {
    return _dspGated(_ConsoleChassis(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
      borderColor: Colors.white.withValues(alpha: 0.14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: RjKnob(
                  key: const Key('knob-reverb'),
                  label: 'REVERB',
                  valueText: '${(_reverbMix * 100).round()}%',
                  value: _reverbMix,
                  onChanged: (double v) {
                    // FIX 20 (fix 12): drag ticks update state at once
                    // but rebuild the panel throttled (<=1 per 50ms +
                    // trailing) — no full rebuild per pixel.
                    _activePreset = null;
                      _reverbMix = v;
                    _throttledPanelRefresh();
                    _pushReverb();
                  },
                ),
              ),
              Expanded(
                child: RjKnob(
                  key: const Key('knob-echo'),
                  label: 'ECHO',
                  valueText: '${(_echoMix * 100).round()}%',
                  value: _echoMix,
                  onChanged: (double v) {
                    // FIX 20 (fix 12): drag ticks update state at once
                    // but rebuild the panel throttled (<=1 per 50ms +
                    // trailing) — no full rebuild per pixel.
                    _activePreset = null;
                      _echoMix = v;
                    _throttledPanelRefresh();
                    _pushEcho();
                  },
                ),
              ),
              Expanded(
                child: RjKnob(
                  key: const Key('knob-bass'),
                  label: 'BASS',
                  valueText: _formatDb(_bassBoostDb),
                  value: _bassBoostDb / _kMaxBoostDb,
                  onChanged: (double v) {
                    // FIX 20 (fix 12): drag ticks update state at once
                    // but rebuild the panel throttled (<=1 per 50ms +
                    // trailing) — no full rebuild per pixel.
                    _activePreset = null;
                      _bassBoostDb = v * _kMaxBoostDb;
                    _throttledPanelRefresh();
                    _pushEq();
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: RjKnob(
                  key: const Key('knob-compressor'),
                  label: 'COMPRESSOR',
                  valueText: '${(_compressorPct * 100).round()}%',
                  value: _compressorPct,
                  onChanged: (double v) {
                    // FIX 20 (fix 12): drag ticks update state at once
                    // but rebuild the panel throttled (<=1 per 50ms +
                    // trailing) — no full rebuild per pixel.
                    _activePreset = null;
                      _compressorPct = v;
                    _throttledPanelRefresh();
                    _pushCompressor();
                  },
                ),
              ),
              Expanded(
                child: RjKnob(
                  key: const Key('knob-treble'),
                  label: 'TREBLE',
                  valueText: '${(_treblePct * 100).round()}%',
                  value: _treblePct,
                  onChanged: (double v) {
                    // FIX 20 (fix 12): drag ticks update state at once
                    // but rebuild the panel throttled (<=1 per 50ms +
                    // trailing) — no full rebuild per pixel.
                    _activePreset = null;
                      _treblePct = v;
                      _highGainDb = v * _kMaxBoostDb;
                    _throttledPanelRefresh();
                    _pushEq();
                  },
                ),
              ),
              Expanded(
                child: RjKnob(
                  key: const Key('knob-delay'),
                  label: 'DELAY',
                  valueText: '${_echoDelayMs.round()} ms',
                  value: (_echoDelayMs - _kDelayMinMs) /
                      (_kDelayMaxMs - _kDelayMinMs),
                  onChanged: (double v) {
                    // FIX 20 (fix 12): drag ticks update state at once
                    // but rebuild the panel throttled (<=1 per 50ms +
                    // trailing) — no full rebuild per pixel.
                    _activePreset = null;
                      _echoDelayMs =
                          _kDelayMinMs + v * (_kDelayMaxMs - _kDelayMinMs);
                    _throttledPanelRefresh();
                    _pushEcho();
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    ));
  }

  // --- Soundboard pads (wired callbacks, emoji glyphs per design). ---

  Widget _buildSoundboard() {
    return Row(
      children: [
        _buildPad('APPLAUSE', '👏', RjSoundboardPad.applause, 'pad-applause'),
        const SizedBox(width: 8),
        _buildPad('AIR HORN', '📣', RjSoundboardPad.airHorn, 'pad-air-horn'),
        const SizedBox(width: 8),
        _buildPad('LAUGH', '😂', RjSoundboardPad.laugh, 'pad-laugh'),
        const SizedBox(width: 8),
        _buildPad('DRUM', '🥁', RjSoundboardPad.drum, 'pad-drum'),
      ],
    );
  }

  Widget _buildPad(
    String label,
    String glyph,
    RjSoundboardPad pad,
    String keyName,
  ) {
    return Expanded(
      child: GestureDetector(
        key: Key(keyName),
        behavior: HitTestBehavior.opaque,
        onTap: () => widget.onSoundboard?.call(pad),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: _kCardDarkGrey,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: _kGold, width: 1.5),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(glyph, style: const TextStyle(fontSize: 26)),
              const SizedBox(height: 4),
              // FIX 20 (fix 13): 'DRUM ROLL' nearly fills a 70px
              // pad at 360px — scale down instead of clipping.
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  label,
                  style: const TextStyle(
                    color: _kGold,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.6,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // --- Now Playing bar (hidden when nowPlayingTitle is null). ---

  Widget _buildNowPlaying() {
    final String title = widget.nowPlayingTitle!;
    final Duration total = widget.nowPlayingDuration;
    final Duration position = widget.nowPlayingPosition;
    final double progress = total.inMilliseconds > 0
        ? (position.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;

    return Container(
      key: const Key('now-playing'),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: _kCardDarkGrey,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _kGold.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          const Icon(Icons.music_note, color: _kGold, size: 26),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: _kTextPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: progress,
                    minHeight: 5,
                    backgroundColor: _kSurfaceGrey,
                    valueColor: const AlwaysStoppedAnimation<Color>(_kGold),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Text(
            '${_mmss(position)} / ${_mmss(total)}',
            style: const TextStyle(
              color: _kTextPrimary,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  // --- Three vertical faders + NOISE GATE toggle. ---

  Widget _buildFadersAndGate() {
    return _ConsoleChassis(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 12),
      borderColor: Colors.white.withValues(alpha: 0.14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            // FIX 24: the MIC fader dims when the link is OFF (the
            // fader is be-asar then — manual music only). The
            // MIC ON/OFF button below it gates the inverse link.
            child: Opacity(
              opacity: widget.micLinkOn ? 1.0 : 0.45,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _RjFader(
                    key: const Key('fader-mic'),
                    label: 'MIC',
                    value: _micVolume,
                    onChanged: (double v) {
                      _micVolume = v;
                      _throttledPanelRefresh();
                      widget.onMicVolume?.call(v);
                    },
                  ),
                  const SizedBox(height: 6),
                  GestureDetector(
                    key: const Key('rj-mic-link-toggle'),
                    behavior: HitTestBehavior.opaque,
                    onTap: () =>
                        widget.onMicLinkChanged?.call(!widget.micLinkOn),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: widget.micLinkOn
                            ? _kGold
                            : _kSurfaceGrey,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: widget.micLinkOn
                              ? _kGold
                              : _kTextMuted.withValues(alpha: 0.5),
                        ),
                      ),
                      child: Text(
                        widget.micLinkOn ? 'MIC ON' : 'MIC OFF',
                        style: TextStyle(
                          color: widget.micLinkOn
                              ? _kBgBlack
                              : _kTextMuted,
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.6,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: _RjFader(
              key: const Key('fader-guest'),
              label: 'GUEST',
              value: _guestVolume,
              onChanged: (double v) {
                _guestVolume = v;
                _throttledPanelRefresh();
                widget.onGuestVolume?.call(v);
              },
            ),
          ),
          Expanded(
            child: _RjFader(
              key: const Key('fader-music'),
              label: 'MUSIC',
              value: _musicVolume,
              onChanged: (double v) {
                _musicVolume = v;
                _throttledPanelRefresh();
                widget.onMusicVolume?.call(v);
              },
            ),
          ),
          Container(width: 1, height: 140, color: _kSurfaceGrey),
          Expanded(child: _buildNoiseGate()),
        ],
      ),
    );
  }

  Widget _buildNoiseGate() {
    final bool on = _noiseGateOn;
    return _dspGated(Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          'NOISE GATE',
          style: TextStyle(
            color: _kTextPrimary,
            fontSize: 12,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.8,
          ),
        ),
        const SizedBox(height: 10),
        GestureDetector(
          key: const Key('noise-gate-toggle'),
          behavior: HitTestBehavior.opaque,
          onTap: () {
            setState(() => _noiseGateOn = !on);
            widget.onNoiseGateChanged?.call(!on);
          },
          child: Container(
            width: 92,
            height: 40,
            decoration: BoxDecoration(
              color: on ? _kGold : _kSurfaceGrey,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: _kGold, width: 1.5),
            ),
            child: Stack(
              children: [
                Align(
                  alignment: on ? Alignment.centerLeft : Alignment.centerRight,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Text(
                      on ? 'ON' : 'OFF',
                      style: TextStyle(
                        color: on ? Colors.black : _kGold,
                        fontSize: 13,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ),
                Align(
                  alignment: on ? Alignment.centerRight : Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Container(
                      width: 32,
                      height: 32,
                      decoration: const BoxDecoration(
                        color: Colors.black,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    ));
  }

  // --- Presets: gold rules + RADIO / CONCERT / STUDIO / OFF. ---

  Widget _buildPresets() {
    return _dspGated(_ConsoleChassis(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 10),
      borderColor: Colors.white.withValues(alpha: 0.14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Container(
                  height: 2,
                  decoration: BoxDecoration(
                    color: _kGold,
                    borderRadius: BorderRadius.circular(1),
                  ),
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 10),
                child: Text(
                  'PRESETS',
                  style: TextStyle(
                    color: _kGold,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.5,
                  ),
                ),
              ),
              Expanded(
                child: Container(
                  height: 2,
                  decoration: BoxDecoration(
                    color: _kGold,
                    borderRadius: BorderRadius.circular(1),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              _buildPresetPill('RADIO', _RjPreset.radio, 'preset-radio'),
              const SizedBox(width: 8),
              _buildPresetPill(
                'CONCERT',
                _RjPreset.concertHall,
                'preset-concert',
              ),
              const SizedBox(width: 8),
              _buildPresetPill('STUDIO', _RjPreset.studio, 'preset-studio'),
              const SizedBox(width: 8),
              _buildPresetPill('OFF', _RjPreset.off, 'preset-off'),
            ],
          ),
        ],
      ),
    ));
  }

  Widget _buildPresetPill(String label, _RjPreset preset, String keyName) {
    final bool selected = _activePreset == preset;
    return Expanded(
      child: GestureDetector(
        key: Key(keyName),
        behavior: HitTestBehavior.opaque,
        onTap: () => _applyPreset(preset),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: selected ? _kGold : Colors.black,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: _kGold, width: 1.5),
            boxShadow: selected
                ? <BoxShadow>[
                    BoxShadow(
                      color: _kGold.withValues(alpha: 0.45),
                      blurRadius: 12,
                    ),
                  ]
                : null,
          ),
          child: Center(
            // FIX 20 (fix 13): 'CONCERT' nearly fills a 70px pill
            // at 360px — scale down instead of clipping.
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                label,
                style: TextStyle(
                  color: selected ? Colors.black : _kGold,
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.5,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // --- Bottom: big round red GO LIVE + round black/gold MUTE. ---

  Widget _buildBottomActions() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _buildRoundButton(
          keyName: 'go-live-button',
          diameter: 108,
          background: _kLiveRed,
          ring: _kGold,
          glow: _kLiveRed,
          icon: Icons.cell_tower,
          iconColor: Colors.white,
          label: widget.isLive ? 'END LIVE' : 'GO LIVE',
          labelColor: Colors.white,
          onTap: widget.onGoLivePressed,
        ),
        const SizedBox(width: 28),
        _buildRoundButton(
          keyName: 'mute-button',
          diameter: 96,
          background: Colors.black,
          ring: widget.isMuted ? _kLiveRed : _kGold,
          glow: null,
          icon: widget.isMuted ? Icons.mic_off : Icons.mic,
          iconColor: widget.isMuted ? _kLiveRed : _kGold,
          label: 'MUTE',
          labelColor: _kGold,
          onTap: widget.onMutePressed,
        ),
      ],
    );
  }

  Widget _buildRoundButton({
    required String keyName,
    required double diameter,
    required Color background,
    required Color ring,
    required Color? glow,
    required IconData icon,
    required Color iconColor,
    required String label,
    required Color labelColor,
    required VoidCallback onTap,
  }) {
    return SizedBox(
      width: diameter,
      height: diameter,
      child: Material(
        key: Key(keyName),
        color: background,
        shape: CircleBorder(side: BorderSide(color: ring, width: 3)),
        elevation: 0,
        shadowColor: Colors.transparent,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: glow == null
                  ? null
                  : <BoxShadow>[
                      BoxShadow(
                        color: glow.withValues(alpha: 0.45),
                        blurRadius: 18,
                        spreadRadius: 1,
                      ),
                    ],
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, color: iconColor, size: 30),
                const SizedBox(height: 4),
                Text(
                  label,
                  style: TextStyle(
                    color: labelColor,
                    fontSize: 14,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.8,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // --- Presets (all six knob values; other four keep AI Studio values). ---

  void _applyPreset(_RjPreset preset) {
    // FIX 22 item 6: presets drive the DSP chain — with no DSP
    // the pills are already untappable (_dspGated); this guard
    // keeps a programmatic call from moving knob state nowhere.
    if (!_dspReady) return;
    setState(() {
      _activePreset = preset;
      switch (preset) {
        case _RjPreset.radio:
          _reverbMix = 0.08;
          _reverbRoomSize = 0.25;
          _echoMix = 0.0;
          _echoDelayMs = 200.0;
          _echoFeedback = 0.25;
          _bassBoostDb = 5.0;
          _lowGainDb = 1.5;
          _midGainDb = 2.0;
          _highGainDb = 1.5;
          _noiseGatePct = 0.55;
          _compressorPct = 0.65;
          break;
        case _RjPreset.concertHall:
          _reverbMix = 0.55;
          _reverbRoomSize = 0.85;
          _echoMix = 0.28;
          _echoDelayMs = 280.0;
          _echoFeedback = 0.35;
          _bassBoostDb = 6.5;
          _lowGainDb = 2.0;
          _midGainDb = -1.0;
          _highGainDb = 2.5;
          _noiseGatePct = 0.25;
          _compressorPct = 0.35;
          break;
        case _RjPreset.studio:
          _reverbMix = 0.18;
          _reverbRoomSize = 0.40;
          _echoMix = 0.10;
          _echoDelayMs = 140.0;
          _echoFeedback = 0.20;
          _bassBoostDb = 2.5;
          _lowGainDb = 0.5;
          _midGainDb = 0.5;
          _highGainDb = 1.5;
          _noiseGatePct = 0.45;
          _compressorPct = 0.45;
          break;
        case _RjPreset.off:
          _reverbMix = 0.0;
          _reverbRoomSize = 0.50;
          _echoMix = 0.0;
          _echoDelayMs = 250.0;
          _echoFeedback = 0.35;
          _bassBoostDb = 0.0;
          _lowGainDb = 0.0;
          _midGainDb = 0.0;
          _highGainDb = 0.0;
          _noiseGatePct = 0.0;
          _compressorPct = 0.0;
          break;
      }
      // TREBLE follows the preset's high-band gain (see header).
      _treblePct = (_highGainDb / _kMaxBoostDb).clamp(0.0, 1.0);
    });

    _pushNoiseGate();
    _pushCompressor();
    _pushEq();
    _pushEcho();
    _pushReverb();
  }

  /// FIX 22 item 6 — true when the live DSP chain is behind the
  /// panel (the knobs + presets + noise gate drive it). False
  /// renders those controls dimmed + untappable; everything else
  /// (GO LIVE, MUTE, faders, soundboard, listeners) keeps working
  /// with any mic processor.
  bool get _dspReady {
    final dsp = widget.dsp;
    return dsp != null && dsp.isInitialized;
  }

  /// Wraps a DSP-bound section: untouched when the DSP chain is
  /// live, dimmed + untappable when it is not.
  Widget _dspGated(Widget child) {
    if (_dspReady) return child;
    return AbsorbPointer(
      child: Opacity(opacity: 0.4, child: child),
    );
  }

  void _pushNoiseGate() {
    final dsp = widget.dsp;
    if (dsp == null || !dsp.isInitialized) return;
    _throttledPush('noisegate', () {
      final bool enabled = _noiseGatePct > 0.005;
      final double thresholdDb = -80.0 + (_noiseGatePct * 65.0);
      unawaited(
        dsp.setNoiseGate(
          enabled: enabled,
          thresholdDb: thresholdDb,
          attackMs: 5.0,
          releaseMs: 120.0,
        ),
      );
    });
  }

  void _pushCompressor() {
    final dsp = widget.dsp;
    if (dsp == null || !dsp.isInitialized) return;
    _throttledPush('compressor', () {
      final bool enabled = _compressorPct > 0.005;
      final double thresholdDb = -6.0 - (_compressorPct * 30.0);
      final double ratio = 1.5 + (_compressorPct * 6.5);
      final double makeupGainDb = _compressorPct * 6.0;
      unawaited(
        dsp.setCompressor(
          enabled: enabled,
          thresholdDb: thresholdDb,
          ratio: ratio,
          attackMs: 10.0,
          releaseMs: 100.0,
          makeupGainDb: makeupGainDb,
        ),
      );
    });
  }

  void _pushEq() {
    final dsp = widget.dsp;
    if (dsp == null || !dsp.isInitialized) return;
    _throttledPush('eq', () {
      final bool enabled = _bassBoostDb > 0.05 ||
          _lowGainDb.abs() > 0.05 ||
          _midGainDb.abs() > 0.05 ||
          _highGainDb.abs() > 0.05;
      unawaited(
        dsp.setEq(
          enabled: enabled,
          bassBoostDb: _bassBoostDb,
          lowGainDb: _lowGainDb,
          midGainDb: _midGainDb,
          highGainDb: _highGainDb,
        ),
      );
    });
  }

  void _pushEcho() {
    final dsp = widget.dsp;
    if (dsp == null || !dsp.isInitialized) return;
    _throttledPush('echo', () {
      final bool enabled = _echoMix > 0.005;
      unawaited(
        dsp.setEcho(
          enabled: enabled,
          delayMs: _echoDelayMs,
          feedback: _echoFeedback,
          mix: _echoMix,
        ),
      );
    });
  }

  void _pushReverb() {
    final dsp = widget.dsp;
    if (dsp == null || !dsp.isInitialized) return;
    _throttledPush('reverb', () {
      final bool enabled = _reverbMix > 0.005;
      unawaited(
        dsp.setReverb(
          enabled: enabled,
          wetDryMix: _reverbMix,
          roomSize: _reverbRoomSize,
          damping: 0.5,
        ),
      );
    });
  }
}

/// Reusable console knob: black face, gold ring + tick marks, gold
/// indicator line. Vertical drag changes the value (up = increase,
/// [_kKnobDragSpanPx] px = full range); see the file header.
///
/// The drag accumulates from the value at gesture start (ported
/// from the v2 panel's RotaryKnob): the value prop is read once,
/// at drag start, and each drag update adds its own delta — so a
/// drag stays smooth even if the parent rebuilds late. (v2's knob
/// uses a pan handler, which reports the full first delta; this
/// port keeps our vertical-drag recogniser — its first update
/// nets out the touch slop, which the drag tests pin — plus our
/// vertical-only semantics and our 120 px span, so the drag
/// tests are unchanged.)
class RjKnob extends StatefulWidget {
  const RjKnob({
    super.key,
    required this.label,
    required this.valueText,
    required this.value,
    required this.onChanged,
  });

  /// Uppercase label under the knob (e.g. 'REVERB').
  final String label;

  /// Formatted live value under the label (e.g. '60%', '+6 dB').
  final String valueText;

  /// Normalised position, 0..1.
  final double value;

  final ValueChanged<double> onChanged;

  @override
  State<RjKnob> createState() => _RjKnobState();
}

class _RjKnobState extends State<RjKnob> {
  double _dragAccum = 0.0;

  void _handleDragStart(DragStartDetails details) {
    _dragAccum = widget.value.clamp(0.0, 1.0);
  }

  void _handleDragUpdate(DragUpdateDetails details) {
    _dragAccum = (_dragAccum - details.delta.dy / _kKnobDragSpanPx).clamp(
      0.0,
      1.0,
    );
    widget.onChanged(_dragAccum);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragStart: _handleDragStart,
      onVerticalDragUpdate: _handleDragUpdate,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CustomPaint(
            size: const Size(72, 72),
            painter: _KnobPainter(value: widget.value.clamp(0.0, 1.0)),
          ),
          const SizedBox(height: 4),
          // FIX 20 (fix 13): 'COMPRESSOR' is the longest knob
          // label — scale down instead of clipping at 360px.
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              widget.label,
              style: const TextStyle(
                color: _kGold,
                fontSize: 11,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.6,
              ),
            ),
          ),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              widget.valueText,
              style: const TextStyle(
                color: _kTextPrimary,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _KnobPainter extends CustomPainter {
  _KnobPainter({required this.value});

  /// Normalised position, 0..1 (maps to -135°..+135°, gap at the
  /// bottom — same sweep as the v2 panel's RotaryKnob).
  final double value;

  @override
  void paint(Canvas canvas, Size size) {
    final Offset center = Offset(size.width / 2, size.height / 2 + 2);
    final double outerRadius = math.min(size.width, size.height) * 0.44;
    final double knobRadius = outerRadius * 0.74;

    // 1. Radial tick marks around the knob: 19 ticks, -135°..+135°;
    // ticks at or below the value light up gold, the rest stay dim.
    const double startAngle = 135.0 * math.pi / 180.0;
    const double sweepAngle = 270.0 * math.pi / 180.0;
    const int tickCount = 19;
    final Paint activeTickPaint = Paint()
      ..color = _kGold
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round;
    final Paint inactiveTickPaint = Paint()
      ..color = _kTextMuted.withValues(alpha: 0.35)
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round;
    for (int i = 0; i < tickCount; i++) {
      final double t = i / (tickCount - 1);
      final double angle = startAngle + (t * sweepAngle);
      final bool isLit = t <= value + 0.001;
      final double r1 = outerRadius * 0.86;
      final double r2 = outerRadius;
      final Offset p1 = Offset(
        center.dx + math.cos(angle) * r1,
        center.dy + math.sin(angle) * r1,
      );
      final Offset p2 = Offset(
        center.dx + math.cos(angle) * r2,
        center.dy + math.sin(angle) * r2,
      );
      canvas.drawLine(p1, p2, isLit ? activeTickPaint : inactiveTickPaint);
    }

    // 2. Outer gold halo ring.
    final Paint ringGlowPaint = Paint()
      ..color = _kGold.withValues(alpha: 0.22)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.0;
    canvas.drawCircle(center, knobRadius + 1.5, ringGlowPaint);

    final Paint ringPaint = Paint()
      ..color = _kGold
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;
    canvas.drawCircle(center, knobRadius + 1.0, ringPaint);

    // 3. Dark brushed-metal dial cap.
    final Rect capRect = Rect.fromCircle(center: center, radius: knobRadius);
    final Paint capPaint = Paint()
      ..shader = const RadialGradient(
        center: Alignment(-0.25, -0.3),
        radius: 1.0,
        colors: [Color(0xFF33333A), Color(0xFF16161A), Color(0xFF0A0A0D)],
      ).createShader(capRect);
    canvas.drawCircle(center, knobRadius, capPaint);

    final Paint innerBevel = Paint()
      ..color = Colors.white.withValues(alpha: 0.13)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;
    canvas.drawCircle(center, knobRadius - 2.0, innerBevel);

    // 4. Gold indicator pointer line.
    final double pointerAngle = startAngle + (value * sweepAngle);
    final Offset innerPt = Offset(
      center.dx + math.cos(pointerAngle) * (knobRadius * 0.25),
      center.dy + math.sin(pointerAngle) * (knobRadius * 0.25),
    );
    final Offset outerPt = Offset(
      center.dx + math.cos(pointerAngle) * (knobRadius * 0.86),
      center.dy + math.sin(pointerAngle) * (knobRadius * 0.86),
    );
    final Paint pointerPaint = Paint()
      ..color = _kGold
      ..strokeWidth = 2.6
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(innerPt, outerPt, pointerPaint);
  }

  @override
  bool shouldRepaint(covariant _KnobPainter oldDelegate) =>
      oldDelegate.value != value;
}

/// Vertical gold fader (MIC / GUEST / MUSIC). Vertical drag changes
/// the value (up = increase, [_kFaderDragSpanPx] px = full range);
/// a tap on the track jumps straight to that position (v2 port).
/// The tap uses onTapUp, not onTapDown, so a drag never also
/// fires a jump: onTapUp only runs once the tap wins the gesture
/// arena (pointer up, no drag).
class _RjFader extends StatefulWidget {
  const _RjFader({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final double value;
  final ValueChanged<double> onChanged;

  @override
  State<_RjFader> createState() => _RjFaderState();
}

class _RjFaderState extends State<_RjFader> {
  static const double _trackHeight = 110.0;
  static const double _handleHeight = 20.0;

  // FIX 20 (fix 12): local drag accumulation (same pattern as
  // RjKnob) — the parent rebuilds throttled now, so computing a
  // drag update from widget.value would re-read a stale prop
  // mid-drag and the fader would barely move.
  double _dragAccum = 0.0;

  void _jumpToLocalY(double dy) {
    final double usable = _trackHeight - _handleHeight;
    final double clampedY = ((dy - _handleHeight / 2) / usable).clamp(0.0, 1.0);
    widget.onChanged((1.0 - clampedY).clamp(0.0, 1.0));
  }

  @override
  Widget build(BuildContext context) {
    final double clamped = widget.value.clamp(0.0, 1.0);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragStart: (_) {
        _dragAccum = widget.value.clamp(0.0, 1.0);
      },
      onVerticalDragUpdate: (DragUpdateDetails details) {
        _dragAccum =
            (_dragAccum - details.delta.dy / _kFaderDragSpanPx).clamp(0.0, 1.0);
        widget.onChanged(_dragAccum);
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (TapUpDetails details) =>
                _jumpToLocalY(details.localPosition.dy),
            child: SizedBox(
              height: _trackHeight,
              width: 46,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  CustomPaint(
                    size: const Size(46, _trackHeight),
                    painter: _FaderScalePainter(value: clamped),
                  ),
                  Positioned(
                    top: (1 - clamped) * (_trackHeight - _handleHeight),
                    child: Container(
                      width: 36,
                      height: _handleHeight,
                      decoration: BoxDecoration(
                        color: _kGold,
                        borderRadius: BorderRadius.circular(5),
                        boxShadow: <BoxShadow>[
                          BoxShadow(
                            color: _kGold.withValues(alpha: 0.4),
                            blurRadius: 8,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            widget.label,
            style: const TextStyle(
              color: _kGold,
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.6,
            ),
          ),
        ],
      ),
    );
  }
}

/// Screw-dot console section (ported from the v2 panel): gradient
/// body + four corner screws, like the design's metal panels. The
/// border colour is per-section: gold for the host card, a faint
/// neutral for the big console sections.
class _ConsoleChassis extends StatelessWidget {
  const _ConsoleChassis({
    required this.child,
    required this.padding,
    required this.borderColor,
  });

  final Widget child;
  final EdgeInsets padding;
  final Color borderColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF19191E), Color(0xFF101014)],
        ),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: borderColor, width: 1.1),
      ),
      child: Stack(
        children: [
          Padding(padding: padding, child: child),
          const Positioned(top: 4, left: 4, child: _ScrewDot()),
          const Positioned(top: 4, right: 4, child: _ScrewDot()),
          const Positioned(bottom: 4, left: 4, child: _ScrewDot()),
          const Positioned(bottom: 4, right: 4, child: _ScrewDot()),
        ],
      ),
    );
  }
}

class _ScrewDot extends StatelessWidget {
  const _ScrewDot();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 6,
      height: 6,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: const Color(0xFF2B2B33),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.16),
          width: 0.6,
        ),
      ),
    );
  }
}

/// Segmented LED spectrum bars (ported from the v2 panel): 7 lit
/// segments per bar, dim segments below the value — the blocky
/// look of the design image.
class _SpectrumPainter extends CustomPainter {
  const _SpectrumPainter({required this.bars});

  final List<double> bars;

  @override
  void paint(Canvas canvas, Size size) {
    if (bars.isEmpty) return;
    final int count = bars.length;
    const double gap = 2.5;
    final double barWidth = (size.width - (gap * (count - 1))) / count;
    const int segments = 7;
    const double segGap = 1.6;
    final double segHeight =
        (size.height - (segGap * (segments - 1))) / segments;

    final Paint activePaint = Paint()..color = _kGold;
    final Paint dimPaint = Paint()..color = _kGold.withValues(alpha: 0.09);

    for (int i = 0; i < count; i++) {
      final double level = bars[i].clamp(0.0, 1.0);
      final int litSegments = (level * segments).ceil().clamp(1, segments);
      final double x = i * (barWidth + gap);

      for (int s = 0; s < segments; s++) {
        final double y = size.height - ((s + 1) * segHeight + s * segGap);
        final RRect rect = RRect.fromRectAndRadius(
          Rect.fromLTWH(x, y, barWidth, segHeight),
          const Radius.circular(1.0),
        );
        canvas.drawRRect(rect, s < litSegments ? activePaint : dimPaint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _SpectrumPainter oldDelegate) {
    return oldDelegate.bars != bars;
  }
}

/// Brushed-metal console texture (ported from the v2 panel): faint
/// horizontal + diagonal lines behind the whole console.
class _MetalTexturePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final Paint linePaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.03)
      ..strokeWidth = 1.0;

    for (double y = 0; y < size.height; y += 5) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), linePaint);
    }

    final Paint diagPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.02)
      ..strokeWidth = 1.0;

    for (double x = -size.height; x < size.width; x += 12) {
      canvas.drawLine(
        Offset(x, 0),
        Offset(x + size.height, size.height),
        diagPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Gold mic with sound waves (ported from the v2 panel) — the
/// design's top-left icon, replacing the plain mic glyph.
class _StudioMicWavesPainter extends CustomPainter {
  const _StudioMicWavesPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final Offset c = Offset(size.width / 2, size.height / 2);
    final Paint goldFill = Paint()..color = _kGold;
    final Paint goldStroke = Paint()
      ..color = _kGold
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round;

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(c.dx, c.dy - 3), width: 10, height: 15),
        const Radius.circular(5),
      ),
      goldFill,
    );
    canvas.drawArc(
      Rect.fromCenter(center: Offset(c.dx, c.dy - 1), width: 16, height: 14),
      0.15,
      math.pi - 0.3,
      false,
      goldStroke,
    );
    canvas.drawLine(
      Offset(c.dx, c.dy + 6),
      Offset(c.dx, c.dy + 12),
      goldStroke,
    );
    canvas.drawLine(
      Offset(c.dx - 5, c.dy + 12),
      Offset(c.dx + 5, c.dy + 12),
      goldStroke,
    );

    canvas.drawArc(
      Rect.fromCenter(center: Offset(c.dx, c.dy - 3), width: 26, height: 22),
      -0.7,
      1.4,
      false,
      goldStroke,
    );
    canvas.drawArc(
      Rect.fromCenter(center: Offset(c.dx, c.dy - 3), width: 26, height: 22),
      math.pi - 0.7,
      1.4,
      false,
      goldStroke,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Fader scale: dB tick marks both sides of the slot + a gold
/// fill up to the current value (ported from the v2 panel).
class _FaderScalePainter extends CustomPainter {
  const _FaderScalePainter({required this.value});

  final double value;

  @override
  void paint(Canvas canvas, Size size) {
    final double cx = size.width / 2;
    const double padV = 6.0;
    final double trackTop = padV;
    final double trackBottom = size.height - padV;
    final double trackHeight = trackBottom - trackTop;

    const int ticks = 9;
    final Paint tickPaint = Paint()
      ..color = _kTextMuted.withValues(alpha: 0.47)
      ..strokeWidth = 1.0;

    for (int i = 0; i < ticks; i++) {
      final double y = trackTop + (i / (ticks - 1)) * trackHeight;
      final double tickLen = (i % 2 == 0) ? 7.0 : 4.5;
      canvas.drawLine(
        Offset(cx - 8 - tickLen, y),
        Offset(cx - 8, y),
        tickPaint,
      );
      canvas.drawLine(
        Offset(cx + 8, y),
        Offset(cx + 8 + tickLen, y),
        tickPaint,
      );
    }

    final RRect slot = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(cx, size.height / 2),
        width: 8,
        height: trackHeight,
      ),
      const Radius.circular(4),
    );
    canvas.drawRRect(slot, Paint()..color = _kBgBlack);
    canvas.drawRRect(
      slot,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.14)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0,
    );

    final double fillHeight = (trackHeight - 4) * value;
    if (fillHeight > 1) {
      final RRect fillRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(cx - 2.2, trackBottom - 2 - fillHeight, 4.4, fillHeight),
        const Radius.circular(2),
      );
      canvas.drawRRect(fillRect, Paint()..color = _kGold);
    }
  }

  @override
  bool shouldRepaint(covariant _FaderScalePainter oldDelegate) {
    return oldDelegate.value != value;
  }
}
