import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart' as lk;

import 'dsp_mic_processor.dart';
import 'mic_audio_pipeline.dart';
import 'rnnoise_processor.dart';

/// DSP FOLD — AUDIO #10: the COMPOSITE mic processor (2026-11-22).
///
/// The pipeline installs ONE [MicNoiseProcessor], so the DSP-engine mic
/// chain (Gate -> Compressor -> EQ -> Echo -> Reverb, the RJ panel's
/// live voice chain) and RNNoise noise suppression can only run
/// TOGETHER via a composite: one [MicNoiseProcessor] whose built
/// [lk.TrackProcessor] calls BOTH channels' `init(trackId)` — DSP-mic
/// FIRST, then RNNoise.
///
/// ## Why the order matters
///
/// Both native sides register a `capturePostProcessing` hook on
/// flutter_webrtc's audio-processing controller, and the hooks run in
/// ADD order on the SAME in-place buffer (confirmed in flutter_webrtc
/// 1.6.3 source). DSP first means the RJ chain (gate/EQ/...) shapes
/// the voice before RNNoise suppresses the residual noise — the
/// gate's threshold sees the raw mic level, and RNNoise sees the
/// EQ'd voice. Reversing the order would gate an already-suppressed
/// signal.
///
/// ## Fail-open
///
/// Either channel may be absent (no native side on this build, or a
/// channel that throws). The composite never lets one side's failure
/// take down the other:
/// * [initialize] returns true when EITHER child initializes.
/// * [buildProcessor] builds from whichever children initialized; it
///   returns null only when NEITHER is usable.
/// * [CompositeMicTrackProcessor.init] / [restart] / [destroy] /
///   [onPublish] / [onUnpublish] call each child in a try/catch, so a
///   throwing child cannot prevent the other from running.
/// * [dispose] disposes both children, each in a try/catch.
///
/// ## RJ panel setters
///
/// The RJ panel reaches the live setters through the pipeline source
/// (`(micPipeline.source as DspMicProcessor?)?.setEcho(...)`). When
/// the installed source is the composite, that cast fails — so the
/// composite exposes the SAME live setters ([setEqPreset], [setEcho],
/// [setReverb], [setNoiseGate], [setCompressor], [setBypass]) and
/// delegates them to the DSP child. The panel (or its wiring) should
/// cast to [CompositeMicProcessor] when the composite is installed.
/// Wiring the composite into `buildMicProcessor` / the room screen is
/// the coordinator's job — this file only provides the processor.
///
/// ## What this file does NOT do
///
/// It does not change the audio order inside either engine, does not
/// add a Dart-side audio path (there is none — live mic frames are
/// native-only), and does not decide WHEN the composite is installed
/// (the pipeline / voice service own that).
class CompositeMicProcessor implements MicNoiseProcessor {
  CompositeMicProcessor({DspMicProcessor? dsp, RnnoiseMicProcessor? rnnoise})
      : _dsp = dsp ?? DspMicProcessor(),
        _rnnoise = rnnoise ?? RnnoiseMicProcessor();

  final DspMicProcessor _dsp;
  final RnnoiseMicProcessor _rnnoise;

  /// The DSP-engine child (RJ chain). The live setters below delegate
  /// to it.
  DspMicProcessor get dsp => _dsp;

  /// The RNNoise child (noise suppression).
  RnnoiseMicProcessor get rnnoise => _rnnoise;

  bool _initialized = false;
  bool _disposed = false;
  bool _dspUsable = false;
  bool _rnnoiseUsable = false;
  CompositeMicTrackProcessor? _activeProcessor;

  /// True after a successful [initialize], until [dispose].
  bool get isInitialized => _initialized && !_disposed;

  /// True when the DSP child initialized (its native side answered).
  bool get isDspUsable => _dspUsable && !_disposed;

  /// True when the RNNoise child initialized.
  bool get isRnnoiseUsable => _rnnoiseUsable && !_disposed;

  /// True while a processor built by [buildProcessor] is alive.
  bool get hasActiveProcessor => _activeProcessor != null;

  /// Initializes BOTH children. Returns true when EITHER child is
  /// usable — the other side still runs when one channel is absent.
  /// Returns false only when NEITHER child initializes (or after
  /// [dispose]). A child that throws during initialize counts as
  /// unusable; it never prevents the other child from initializing.
  /// Idempotent.
  @override
  Future<bool> initialize() async {
    if (_disposed) return false;
    if (_initialized) return true;
    try {
      _dspUsable = await _dsp.initialize();
    } catch (_) {
      _dspUsable = false;
    }
    try {
      _rnnoiseUsable = await _rnnoise.initialize();
    } catch (_) {
      _rnnoiseUsable = false;
    }
    _initialized = _dspUsable || _rnnoiseUsable;
    _log('initialize: dspUsable=$_dspUsable rnnoiseUsable=$_rnnoiseUsable');
    return _initialized;
  }

  /// Builds the [lk.TrackProcessor] to hand to
  /// `AudioCaptureOptions(processor:)`. Builds each usable child's
  /// processor and wraps them in a [CompositeMicTrackProcessor] whose
  /// `init()` calls DSP-mic FIRST, then RNNoise. Returns null when not
  /// initialized, after [dispose], or when no child could build a
  /// processor — pass null through and the mic works unprocessed.
  /// Building twice destroys the previous processor first.
  @override
  Future<lk.TrackProcessor<lk.AudioProcessorOptions>?> buildProcessor() async {
    if (!isInitialized) return null;
    final previous = _activeProcessor;
    if (previous != null) {
      await previous.destroy();
      _activeProcessor = null;
    }
    lk.TrackProcessor<lk.AudioProcessorOptions>? dspBuilt;
    lk.TrackProcessor<lk.AudioProcessorOptions>? rnnoiseBuilt;
    if (_dspUsable) {
      try {
        dspBuilt = await _dsp.buildProcessor();
      } catch (_) {
        dspBuilt = null;
      }
    }
    if (_rnnoiseUsable) {
      try {
        rnnoiseBuilt = await _rnnoise.buildProcessor();
      } catch (_) {
        rnnoiseBuilt = null;
      }
    }
    if (dspBuilt == null && rnnoiseBuilt == null) return null;
    // Safe casts: each child builds only its own TrackProcessor type.
    final processor = CompositeMicTrackProcessor._(
      dsp: dspBuilt as DspMicTrackProcessor?,
      rnnoise: rnnoiseBuilt as RnnoiseTrackProcessor?,
    );
    _activeProcessor = processor;
    return processor;
  }

  /// RJ STUDIO live setters — delegated to the DSP child (see the
  /// class doc comment). Each only sends numbers over the
  /// `arena_hub_dsp_mic` channel; the bridge applies them on the next
  /// mic frame. No re-publish, no voice restart. All return false,
  /// never throw, when the DSP native side is absent.
  Future<bool> setEqPreset(DspMicEqPreset preset) => _dsp.setEqPreset(preset);

  Future<bool> setEcho({
    bool enabled = true,
    double delayMs = 250.0,
    double feedback = 0.35,
    double mix = 0.35,
  }) =>
      _dsp.setEcho(
        enabled: enabled,
        delayMs: delayMs,
        feedback: feedback,
        mix: mix,
      );

  Future<bool> setReverb({
    bool enabled = true,
    double wetDryMix = 0.3,
    double roomSize = 0.5,
    double damping = 0.5,
  }) =>
      _dsp.setReverb(
        enabled: enabled,
        wetDryMix: wetDryMix,
        roomSize: roomSize,
        damping: damping,
      );

  Future<bool> setNoiseGate({
    bool enabled = true,
    double thresholdDb = -40.0,
    double attackMs = 5.0,
    double releaseMs = 120.0,
  }) =>
      _dsp.setNoiseGate(
        enabled: enabled,
        thresholdDb: thresholdDb,
        attackMs: attackMs,
        releaseMs: releaseMs,
      );

  Future<bool> setCompressor({
    bool enabled = true,
    double thresholdDb = -18.0,
    double ratio = 4.0,
    double attackMs = 10.0,
    double releaseMs = 100.0,
    double makeupGainDb = 0.0,
  }) =>
      _dsp.setCompressor(
        enabled: enabled,
        thresholdDb: thresholdDb,
        ratio: ratio,
        attackMs: attackMs,
        releaseMs: releaseMs,
        makeupGainDb: makeupGainDb,
      );

  /// Bypasses the DSP chain in place (frames pass through untouched)
  /// or re-engages it. Delegated to the DSP child.
  Future<bool> setBypass(bool bypass) => _dsp.setBypass(bypass);

  /// Last DSP native error code (0 = ok). -1 when the native side is
  /// absent. Delegated to the DSP child.
  Future<int> lastError() => _dsp.lastError();

  /// Frames the DSP native bridge has actually processed. -1 when the
  /// native side is absent. Delegated to the DSP child.
  Future<int> framesProcessed() => _dsp.framesProcessed();

  /// Destroys the active processor (if any) and releases both
  /// children. Idempotent; safe to call without [initialize]. Each
  /// child dispose runs in a try/catch so one child's failure cannot
  /// leak the other.
  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final processor = _activeProcessor;
    _activeProcessor = null;
    if (processor != null) {
      try {
        await processor.destroy();
      } catch (_) {}
    }
    try {
      await _dsp.dispose();
    } catch (_) {}
    try {
      await _rnnoise.dispose();
    } catch (_) {}
    _initialized = false;
    _dspUsable = false;
    _rnnoiseUsable = false;
  }

  static void _log(String message) {
    if (kDebugMode) debugPrint('[CompositeMic] $message');
  }
}

/// The LiveKit seam implementation: ONE TrackProcessor that stacks the
/// DSP-mic and RNNoise processors on the same mic track. Both children
/// are in-place native processors, so [processedTrack] is null and the
/// original mic track is published.
///
/// Every child call runs in a try/catch: a child that throws (or whose
/// channel is absent) must never prevent the other child from running.
/// The children themselves are already fail-open (a missing native
/// handler degrades to a no-op), so the try/catch here is the second
/// line of defence, not the first.
class CompositeMicTrackProcessor
    implements lk.TrackProcessor<lk.AudioProcessorOptions> {
  CompositeMicTrackProcessor._({
    DspMicTrackProcessor? dsp,
    RnnoiseTrackProcessor? rnnoise,
  })  : _dsp = dsp,
        _rnnoise = rnnoise;

  final DspMicTrackProcessor? _dsp;
  final RnnoiseTrackProcessor? _rnnoise;

  bool _destroyed = false;

  /// True once [init] has confirmed the DSP native side is processing
  /// this track. False when the DSP child is absent or its init failed
  /// (fail-open passthrough). Delegates to the child's own flag — the
  /// composite never claims a child is active when it is not.
  bool get dspActive => !_destroyed && (_dsp?.nativeActive ?? false);

  /// True once [init] has confirmed the RNNoise native side is
  /// processing this track. False when the RNNoise child is absent or
  /// its init failed.
  bool get rnnoiseActive => !_destroyed && (_rnnoise?.nativeActive ?? false);

  /// True when at least one child confirmed init.
  bool get nativeActive => dspActive || rnnoiseActive;

  @override
  String get name => 'CompositeMicProcessor';

  @override
  rtc.MediaStreamTrack? get processedTrack => null;

  /// Attaches BOTH children to the mic track — DSP-mic FIRST, then
  /// RNNoise. The native hooks run in add order on the same in-place
  /// buffer, so DSP shapes the voice before RNNoise suppresses noise.
  /// A failing child never blocks the other.
  @override
  Future<void> init(lk.AudioProcessorOptions options) async {
    if (_dsp != null) {
      try {
        await _dsp.init(options);
      } catch (_) {}
    }
    if (_rnnoise != null) {
      try {
        await _rnnoise.init(options);
      } catch (_) {}
    }
    _log('init track=${options.track.id} '
        'dspActive=$dspActive rnnoiseActive=$rnnoiseActive');
  }

  @override
  Future<void> restart(lk.AudioProcessorOptions options) async {
    if (_dsp != null) {
      try {
        await _dsp.restart(options);
      } catch (_) {}
    }
    if (_rnnoise != null) {
      try {
        await _rnnoise.restart(options);
      } catch (_) {}
    }
  }

  @override
  Future<void> destroy() async {
    if (_destroyed) return;
    _destroyed = true;
    if (_dsp != null) {
      try {
        await _dsp.destroy();
      } catch (_) {}
    }
    if (_rnnoise != null) {
      try {
        await _rnnoise.destroy();
      } catch (_) {}
    }
  }

  @override
  Future<void> onPublish(lk.Room room) async {
    if (_dsp != null) {
      try {
        await _dsp.onPublish(room);
      } catch (_) {}
    }
    if (_rnnoise != null) {
      try {
        await _rnnoise.onPublish(room);
      } catch (_) {}
    }
  }

  @override
  Future<void> onUnpublish() async {
    if (_dsp != null) {
      try {
        await _dsp.onUnpublish();
      } catch (_) {}
    }
    if (_rnnoise != null) {
      try {
        await _rnnoise.onUnpublish();
      } catch (_) {}
    }
  }

  static void _log(String message) {
    if (kDebugMode) debugPrint('[CompositeMic] $message');
  }
}
