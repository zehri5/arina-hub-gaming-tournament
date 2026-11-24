import 'package:livekit_client/livekit_client.dart' as lk;

/// GROUP 7 — AUDIO #10: MIC NOISE-PROCESSOR PIPELINE.
///
/// The ONE seam between the mic noise processors (Group 1 Krisp /
/// Group 2 RNNoise, built in parallel) and the LiveKit room voice
/// pipeline. The pipeline holds the active processor, exposes the
/// on/off switch, and supplies the processor to LiveKit through the
/// livekit_client 2.13.2 TrackProcessor seam:
///
///   AudioCaptureOptions.processor — a
///   `TrackProcessor<AudioProcessorOptions>`, applied by
///   LocalAudioTrack.create() BEFORE the track is published, so the
///   processed audio is what the room hears.
///
/// ## The processor contract (Groups 1/2 implement this)
///
/// ```dart
/// Future<bool> initialize();
/// Future<lk.TrackProcessor<lk.AudioProcessorOptions>?> buildProcessor();
/// Future<void> dispose();
/// ```
///
/// NOTE the generic: `buildProcessor()` MUST return a
/// `TrackProcessor<AudioProcessorOptions>` — NOT a bare
/// `TrackProcessor?`. `AudioCaptureOptions.processor` is typed
/// `TrackProcessor<AudioProcessorOptions>?`, and Dart generics are
/// covariant, so a `TrackProcessor<ProcessorOptions>` is NOT
/// assignable to it. A processor class that extends the bare
/// `TrackProcessor` will not compile against this seam.
///
/// The built processor itself follows the livekit_client 2.13.2
/// `TrackProcessor<T extends ProcessorOptions>` contract (the SDK
/// drives it, not this file): `name`, `init(AudioProcessorOptions)`
/// (carries the raw mic MediaStreamTrack), `restart(...)`,
/// `destroy()`, `onPublish(Room)`, `onUnpublish()`, and
/// `processedTrack` (null for in-place processors, which is what a
/// noise filter is expected to be).
///
/// ## Lifecycle — read before touching
///
/// A built TrackProcessor is ONE-SHOT per mic track. The SDK
/// destroys it whenever the mic track stops: mute
/// (stopAudioCaptureOnMute), unpublish, and room disconnect all end
/// in `LocalTrack.stop()` -> `stopProcessor()` -> `destroy()`
/// (verified in livekit_client 2.13.2 source). Re-using a destroyed
/// processor on a new track would call `init()` a second time on a
/// dead native object, so the pipeline NEVER reuses one:
///
/// * `setProcessor()` builds eagerly (validates the processor at
///   install time) and keeps the SOURCE factory.
/// * `markProcessorDetached()` drops the built copy after any track
///   stop. The source survives.
/// * `prepareForPublish()` rebuilds a fresh TrackProcessor from the
///   source right before a mic (re)publish, but ONLY when noise
///   cancellation is enabled — no wasted builds while NC is off.
/// * `setProcessor()` / `dispose()` dispose the SOURCE (the factory
///   + native library); they never call `destroy()` on a built
///   processor — only the SDK calls `destroy()`, and calling it on
///   a never-attached processor is undefined.
///
/// ## On/off switching — why re-publish
///
/// livekit_client 2.13.2 offers NO public way to attach/detach a
/// processor on a live published track: `setProcessor(null)` is a
/// no-op, `stopProcessor()` is `@internal` (app code must not call
/// it), `restartTrack()` re-applies the OLD processor instead of
/// reading `options.processor`, and `setProcessor(new)` on a
/// published track never calls `sender.replaceTrack`, so the
/// transmitted audio would not change. The only supported route is
/// the one `LiveKitVoiceService` uses: unpublish the mic track and
/// re-publish it with new `AudioCaptureOptions`. The ROOM stays
/// connected — no re-join, no renegotiation of the room; remote
/// listeners hear only a brief mic gap. Toggling while muted costs
/// nothing at all: the flag just applies at the next unmute.
///
/// Default is OFF (explicit opt-in): installing a processor must
/// not change what the room hears until the user flips the switch.
abstract class MicNoiseProcessor {
  /// One-time native setup (load the model / library). Returns
  /// false when noise cancellation is unavailable on this device —
  /// the pipeline then treats the processor as not installed and
  /// the mic stays plain. Must be safe to call once per instance.
  Future<bool> initialize();

  /// Builds a FRESH TrackProcessor for one mic track. Called once
  /// at install and again after every track stop (mute / unpublish
  /// / disconnect), because the SDK destroys the previous build.
  /// Returns null when no processor can be built (same fail-open
  /// outcome as `initialize()` returning false).
  ///
  /// The generic is load-bearing: it MUST be
  /// `TrackProcessor<AudioProcessorOptions>`.
  Future<lk.TrackProcessor<lk.AudioProcessorOptions>?> buildProcessor();

  /// Releases everything this processor owns (native library /
  /// model). Called when the processor is replaced or the pipeline
  /// is disposed. Must be safe to call even if `initialize()` was
  /// never called or returned false.
  Future<void> dispose();
}

/// Holds the active mic noise processor and supplies it to LiveKit
/// as `AudioCaptureOptions.processor`. Plain Dart — no ChangeNotifier:
/// `LiveKitVoiceService` owns notification (it is the object the
/// room screen listens to).
class MicAudioPipeline {
  MicNoiseProcessor? _source;
  lk.TrackProcessor<lk.AudioProcessorOptions>? _built;
  bool _enabled = false;
  bool _disposed = false;
  // Generation guard: a slow initialize()/buildProcessor() that
  // finishes after a newer setProcessor()/dispose() must not
  // clobber the newer state — its processor is disposed instead.
  int _generation = 0;

  /// True when noise cancellation is switched on. Independent of
  /// whether a processor is installed: the flag survives a
  /// processor swap, and applies as soon as one is installed.
  bool get noiseCancellationEnabled => _enabled;

  /// True when a noise processor is installed and usable (its
  /// `initialize()` returned true and `buildProcessor()` produced
  /// one). Stays true across mute/disconnect — the SOURCE survives
  /// track stops; only the built copy is dropped and rebuilt.
  bool get hasProcessor => _source != null;

  /// The installed processor SOURCE (the factory), or null when none
  /// is installed. RJ STUDIO (2026-11-22): the live param setters
  /// (setEcho/setReverb/setNoiseGate/setCompressor/setEqPreset) live
  /// on the source — the RJ panel reaches them as
  /// `(micPipeline.source as DspMicProcessor?)?.setEcho(...)`.
  /// Read-only: installing/removing still goes through setProcessor().
  /// The source survives track stops (only the built copy is dropped),
  /// so the setters keep working across mute/unpublish/re-publish.
  MicNoiseProcessor? get source => _source;

  /// Name of the currently built processor (`TrackProcessor.name`),
  /// or null when no built copy exists right now (none installed,
  /// or detached pending the next publish). Debug info only.
  String? get processorName => _built?.name;

  /// The processor to attach to the mic track right now: the built
  /// one, and only when noise cancellation is switched on.
  lk.TrackProcessor<lk.AudioProcessorOptions>? get activeProcessor =>
      _enabled ? _built : null;

  /// Alias for [activeProcessor] — the getter name the spec (and the
  /// phase-1 verify tests) use. Added at merge 2026-11-22.
  lk.TrackProcessor<lk.AudioProcessorOptions>? get processor =>
      activeProcessor;

  /// Installs [processor] as the mic noise processor (or removes
  /// the current one when null). The previous processor is disposed
  /// first. Returns true when the new processor is ready to use.
  ///
  /// CALLER RULE: the previous processor must NOT be attached to a
  /// live mic track when this runs — disposing its source while
  /// its TrackProcessor is still attached would pull the native
  /// library out from under a live track. `LiveKitVoiceService`
  /// unpublishes the mic first; do not call this from anywhere else
  /// while the mic is live.
  Future<bool> setProcessor(MicNoiseProcessor? processor) async {
    final gen = ++_generation;
    final old = _source;
    _source = null;
    _built = null;
    if (old != null) await _disposeQuietly(old);
    if (gen != _generation || _disposed) {
      if (processor != null) await _disposeQuietly(processor);
      return false;
    }
    if (processor == null) return true;

    bool ok = false;
    try {
      ok = await processor.initialize();
    } catch (_) {
      ok = false;
    }
    if (gen != _generation || _disposed || !ok) {
      await _disposeQuietly(processor);
      return false;
    }

    lk.TrackProcessor<lk.AudioProcessorOptions>? built;
    try {
      built = await processor.buildProcessor();
    } catch (_) {
      built = null;
    }
    if (gen != _generation || _disposed || built == null) {
      await _disposeQuietly(processor);
      return false;
    }
    _source = processor;
    _built = built;
    return true;
  }

  /// Flips the noise-cancellation switch. This only flips the flag
  /// — applying it to a LIVE mic track is the voice service's job
  /// (re-publish, see the header). No-op after dispose.
  void setNoiseCancellationEnabled(bool value) {
    if (_disposed) return;
    _enabled = value;
  }

  /// Drops the built TrackProcessor after the mic track it was
  /// attached to stopped (mute / unpublish / disconnect). The SDK
  /// already called `destroy()` on it; the source survives and
  /// `prepareForPublish()` builds a fresh one for the next track.
  /// Safe to call when nothing is built.
  void markProcessorDetached() {
    _built = null;
  }

  /// Ensures a fresh TrackProcessor is built for the next mic
  /// publish. No-op when NC is off, no processor is installed, one
  /// is already built, or the pipeline is disposed. A failed build
  /// leaves `_built` null (fail-open: the mic publishes plain and
  /// the next publish retries).
  Future<void> prepareForPublish() async {
    if (_disposed || !_enabled || _source == null || _built != null) {
      return;
    }
    final gen = _generation;
    lk.TrackProcessor<lk.AudioProcessorOptions>? built;
    try {
      built = await _source!.buildProcessor();
    } catch (_) {
      built = null;
    }
    if (gen != _generation || _disposed) return;
    _built = built;
  }

  /// Capture options for the next mic (re)publish: [base] (or the
  /// SDK defaults) with the processor overridden to the active one
  /// — null when NC is off or nothing is installed.
  ///
  /// Built FRESH on purpose: `AudioCaptureOptions.copyWith` cannot
  /// turn a processor OFF — it keeps the old one when passed null
  /// (`processor ?? this.processor` in livekit_client 2.13.2).
  lk.AudioCaptureOptions captureOptions({lk.AudioCaptureOptions? base}) {
    final b = base ?? const lk.AudioCaptureOptions();
    return lk.AudioCaptureOptions(
      deviceId: b.deviceId,
      noiseSuppression: b.noiseSuppression,
      echoCancellation: b.echoCancellation,
      autoGainControl: b.autoGainControl,
      highPassFilter: b.highPassFilter,
      echoCancellationMode: b.echoCancellationMode,
      noiseSuppressionMode: b.noiseSuppressionMode,
      autoGainControlMode: b.autoGainControlMode,
      highPassFilterMode: b.highPassFilterMode,
      voiceIsolation: b.voiceIsolation,
      typingNoiseDetection: b.typingNoiseDetection,
      stopAudioCaptureOnMute: b.stopAudioCaptureOnMute,
      processor: activeProcessor,
    );
  }

  /// Releases the installed processor. Idempotent; safe to call
  /// while a setProcessor() is still in flight (the late arrival
  /// is disposed instead of installed).
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _enabled = false;
    final old = _source;
    _source = null;
    _built = null;
    if (old != null) await _disposeQuietly(old);
  }

  Future<void> _disposeQuietly(MicNoiseProcessor processor) async {
    try {
      await processor.dispose();
    } catch (_) {}
  }
}
