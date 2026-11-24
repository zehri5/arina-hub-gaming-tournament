import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart' as lk;

import 'mic_audio_pipeline.dart';

/// GROUP 7 DSP — AUDIO #10: the DSP-engine mic processor.
///
/// The Dart half of the live-mic DSP route. It implements the
/// [MicNoiseProcessor] contract so [MicAudioPipeline] can select it
/// exactly like the Krisp (Group 1) / RNNoise (Group 2) processors —
/// see [buildMicProcessor].
///
/// ## RJ Studio evolution (2026-11-22) — the host mic chain
///
/// Sameer: the community live voice chat works like an FM RJ's studio —
/// the HOST's mic chain applies the DSP LIVE so LISTENERS hear the
/// processed voice in real time. The chain is the v3 engine's full
/// chain: Gate -> Compressor -> EQ -> Echo -> Reverb, running per band
/// (one engine per band; EQ on band 0 only — see dsp_mic_bridge.h).
/// The RJ panel's sliders call the live setters below ([setEcho],
/// [setReverb], [setNoiseGate], [setCompressor], [setEqPreset]) while
/// the host speaks.
///
/// ## LIVE PARAM CONTRACT — read before wiring the RJ panel
///
/// Param changes NEVER touch the TrackProcessor or the mic track: each
/// setter only sends numbers over the `arena_hub_dsp_mic` channel, the
/// Kotlin side forwards them to the bridge, and the bridge applies the
/// pending preset on the next mic frame (the engine's setters are
/// mutex-guarded and live-safe). No re-publish, no voice restart, no
/// navigation. Only install/remove (`setProcessor`) and NC on/off
/// re-publish the mic track (see [MicAudioPipeline] — livekit_client
/// 2.13.2 applies a processor only at track creation).
///
/// ## Host-only note
///
/// The chain processes the LOCAL mic — when the host hosts, the local
/// mic IS the host's, so listeners hear the processed voice
/// automatically (the processed frames are what gets encoded and
/// published). No extra gating is needed on the chain itself. The
/// PANEL is host-only (a separate agent's job); the chain just
/// processes whoever's mic is attached.

///
/// This file's shape is adapted from Group 2's
/// `lib/services/rnnoise_processor.dart`: same `isAvailable` ping at
/// initialize, same fail-open `_invoke`/`_invokeBool` helpers, same
/// in-place [lk.TrackProcessor] seam (`processedTrack` is null), same
/// `framesProcessed`/`lastError` diagnostics. The native side is the
/// same hook too — `DspMicProcessor.kt` is a close copy of G2's
/// `RnnoiseProcessor.kt` (capturePostProcessing + lazy nativeInit +
/// loadLibrary try/catch). What differs is ONLY the engine: the
/// external C++ DspEngine's full v3 chain (Gate -> Compressor -> EQ ->
/// Echo -> Reverb, one mono instance per band) instead of RNNoise,
/// plus the live param setters (`setEq`/`setEcho`/`setReverb`/
/// `setNoiseGate`/`setCompressor`) the RNNoise path has no use for.
///
/// Two deliberate deviations from G2's Dart shape:
/// * G2's initialize() returns true even when the native side is
///   absent (it falls back to a pure-Dart spectral gate). DSP has no
///   Dart fallback — `AudioDsp.process()` cannot reach live mic
///   frames — so initialize() returns false and the pipeline simply
///   does not install the processor.
/// * G2 puts `framesProcessed`/`lastError` on the TrackProcessor.
///   Here they live on the source class, because the counters are
///   engine-global and the source is the handle the pipeline exposes
///   to the room screen (the A/B test needs them without holding the
///   one-shot TrackProcessor).
///
/// ## What Dart can and cannot do here
///
/// Pure Dart CANNOT touch live mic audio: flutter_webrtc /
/// livekit_client expose no audio-frame API to Dart, so
/// `AudioDsp.process()` (a MethodChannel PCM round-trip) can only
/// process buffers Dart already holds — and Dart never sees live mic
/// frames. The audio plane therefore lives entirely in native code:
///
///   mic -> WebRTC APM -> DspMicAudioProcessor (Kotlin, same hook as
///   the Krisp plugin) -> DspMicBridge C++ (in place: full chain on
///   the whole frame when numBands == 1, per-band full chain — EQ on
///   band 0 only — when split) -> encoder.
///
/// What Dart DOES own is the CONTROL plane, over the
/// `arena_hub_dsp_mic` MethodChannel: the `isAvailable` ping, the
/// voice EQ preset, bypass, and the attach/detach pair per mic track.
/// Parameter control works over the channel because it is a handful
/// of numbers, not audio frames.
///
/// ## Mic preset
///
/// Echo, reverb, noise gate and compressor are OFF at init — they are
/// true bypass in the engine (each disabled stage returns before
/// touching the buffer), so they add no coloration and no latency
/// until the host enables them LIVE from the RJ panel. Only the EQ
/// shapes the voice at startup, using [DspMicEqPreset.voice] unless a
/// different preset is passed to the constructor.
///
/// ## Honest status (host-verified, on-device pending)
///
/// * Dart plumbing through the seam: implemented + unit-tested.
/// * Native bridge: Kotlin processor + JNI wrapper + C++ bridge
///   written; the C++ was compiled and run on the host (see
///   MIC_DSP_ROUTING.md for the check list), including the v3 engine
///   (Gate -> Compressor -> EQ -> Echo -> Reverb) and the per-band
///   full-chain routing. The Kotlin was compiled with kotlinc on this
///   VM (see MIC_DSP_ROUTING.md) but NOT dexed or run — the APK
///   pipeline does that.
/// * The on-device path (APK build + real mic) is NOT verified yet.
///   First phone test: join a voice room, check `framesProcessed`
///   grows, check the logcat `DspMic first frame:` line for the
///   buffer capacity (float32 = 1920 bytes at 48 kHz mono, int16 =
///   960), and A/B with `setBypass`.

/// Which mic processor the pipeline should use. Krisp / RNNoise are
/// built by Groups 1/2 and injected; DSP is built here.
enum MicProcessorKind {
  /// The external C++ DSP engine (full v3 chain on the mic path:
  /// Gate -> Compressor -> EQ -> Echo -> Reverb).
  dsp,

  /// Krisp noise filter (Group 1).
  krisp,

  /// RNNoise filter (Group 2).
  rnnoise,

  /// DSP + RNNoise stacked on ONE mic track (DSP fold):
  /// the RJ voice chain shapes the voice first, then RNNoise
  /// suppresses the residual noise. Injected like Krisp/RNNoise
  /// (see [buildMicProcessor]) — constructing it here would need
  /// this file to import composite_mic_processor.dart, which
  /// imports THIS file (an import cycle).
  composite,
}

/// Selects the mic processor for [kind] — the ONE place the choice
/// lives. Pass the Groups 1/2 processors in when they exist; a kind
/// with no processor returns null and the mic publishes plain
/// (fail-open, same as a failed initialize). The composite is
/// injected the same way (the RJ console's picker passes a fresh
/// `CompositeMicProcessor()`); [MicProcessorKind.dsp] is the only
/// kind built here, because this file owns the DSP class.
MicNoiseProcessor? buildMicProcessor(
  MicProcessorKind kind, {
  MicNoiseProcessor? krisp,
  MicNoiseProcessor? rnnoise,
  MicNoiseProcessor? composite,
  DspMicEqPreset dspPreset = DspMicEqPreset.voice,
}) {
  switch (kind) {
    case MicProcessorKind.dsp:
      return DspMicProcessor(eqPreset: dspPreset);
    case MicProcessorKind.krisp:
      return krisp;
    case MicProcessorKind.rnnoise:
      return rnnoise;
    case MicProcessorKind.composite:
      return composite;
  }
}

/// EQ gains for the mic engine, in dB. The engine clamps bass to
/// 0..12 and the rest to -12..12; the same clamps are applied here
/// so a bad preset fails loudly in Dart, not silently in C++.
///
/// Argument keys match `DspMicProcessor.kt` (`bassDb` / `lowDb` /
/// `midDb` / `highDb`) — NOT the AudioDsp plugin's keys.
class DspMicEqPreset {
  const DspMicEqPreset({
    required this.bassBoostDb,
    required this.lowGainDb,
    required this.midGainDb,
    required this.highGainDb,
  });

  /// Starting voice preset: gentle warmth + presence. Tunable from
  /// the room screen later; NOT gospel — verify by ear on a device.
  static const voice = DspMicEqPreset(
    bassBoostDb: 2.0,
    lowGainDb: 1.0,
    midGainDb: 2.0,
    highGainDb: 3.0,
  );

  /// Flat: EQ stage enabled but every band at 0 dB (each biquad
  /// bypasses itself — dsp_engine.cpp:445-448 — so the signal passes
  /// through only the int16 round-trip + soft limiter).
  static const flat = DspMicEqPreset(
    bassBoostDb: 0.0,
    lowGainDb: 0.0,
    midGainDb: 0.0,
    highGainDb: 0.0,
  );

  final double bassBoostDb;
  final double lowGainDb;
  final double midGainDb;
  final double highGainDb;

  Map<String, Object> toArgs({required bool enabled}) => <String, Object>{
    'enabled': enabled,
    'bassDb': bassBoostDb.clamp(0.0, 12.0).toDouble(),
    'lowDb': lowGainDb.clamp(-12.0, 12.0).toDouble(),
    'midDb': midGainDb.clamp(-12.0, 12.0).toDouble(),
    'highDb': highGainDb.clamp(-12.0, 12.0).toDouble(),
  };
}

/// Why a DSP mic init failed (FIX 21 item 2). The old code collapsed
/// every failure into a bare `false`, which made the v2020 phone
/// toast ("Mic processor available nahi hai") undiagnosable — the
/// reason was lost at the exact moment it mattered. [DspMicProcessor]
/// keeps the reason in [DspMicProcessor.lastInitFailure] instead.
///
/// Proven by elimination on the v2020 toast (2026-11-23): DSP is the
/// ONLY kind whose initialize() can return false on Android — Krisp's
/// `LiveKitNoiseFilter.isSupported()` is a pure platform check (true
/// on Android), RNNoise's initialize() always returns true (Dart
/// spectral-gate fallback), and the composite returns true when
/// EITHER child works. So the toast could only have come from a DSP
/// switch, and the failure is one of the four causes below.
enum DspMicInitFailure {
  /// No failure (init succeeded, or init never ran).
  none,

  /// The native side answered the ping with false — libaudio_dsp.so
  /// did not load (DspMicProcessor.kt `nativeLoaded`).
  nativeAbsent,

  /// No MethodChannel handler is registered for `arena_hub_dsp_mic`
  /// (Kotlin side not registered).
  channelMissing,

  /// The ping did not answer within the timeout — twice (see the one
  /// retry in [DspMicProcessor.initialize]).
  timeout,

  /// The ping threw a PlatformException.
  platformError,
}

/// FIX 22 item 8 — the SHORT Urdu reason for a DSP failure, shown
/// in the RJ picker's DSP label + the console's Urdu DSP message.
/// One line, no jargon: the user asked "DSP available nahi — kyun?"
/// and this is the answer. `none` = DSP works (the live-effects
/// label). Pure function — pinned by unit tests.
String dspFailureLabel(DspMicInitFailure failure) {
  switch (failure) {
    case DspMicInitFailure.nativeAbsent:
      return 'DSP — native library load nahi ho saki';
    case DspMicInitFailure.channelMissing:
      return 'DSP — app channel nahi mila';
    case DspMicInitFailure.timeout:
      return 'DSP — jawab time out ho gaya';
    case DspMicInitFailure.platformError:
      return 'DSP — platform error';
    case DspMicInitFailure.none:
      return 'DSP — RJ live effects';
  }
}

/// The DSP-engine mic processor: a [MicNoiseProcessor] the pipeline
/// installs like any other. The native side owns ONE mono engine
/// instance (created lazily on the first mic frame — see
/// DspMicProcessor.kt); Dart sends the voice preset at [initialize]
/// and the bridge stores it until the engine exists.
class DspMicProcessor implements MicNoiseProcessor {
  DspMicProcessor({this.eqPreset = DspMicEqPreset.voice});

  /// MethodChannel shared with `DspMicProcessor.kt`.
  static const String channelName = 'arena_hub_dsp_mic';

  /// The native DSP path is wired for Android only in this prototype.
  /// UI hint only (e.g. hide the DSP option on desktop): [initialize]
  /// does NOT consult it — the `isAvailable` ping is the real check.
  /// Pinging unconditionally is what makes the success path testable
  /// with a mocked channel on the Linux test host, where this is
  /// false; on a real desktop build the ping fails fast with
  /// [MissingPluginException] because no handler is registered.
  static bool isSupported() =>
      <lk.PlatformType>[lk.PlatformType.android].contains(lk.lkPlatform());

  final MethodChannel _channel = const MethodChannel(channelName);

  final DspMicEqPreset eqPreset;

  bool _initialized = false;
  bool _disposed = false;
  bool _nativeAvailable = false;
  DspMicTrackProcessor? _activeProcessor;

  /// The reason the last [initialize] failed ([DspMicInitFailure.none]
  /// after a success, or before init ever ran). Never throws.
  /// FIX 21 (item 2): the old code returned a bare `false` for four
  /// different causes and the reason was lost.
  DspMicInitFailure get lastInitFailure => _lastInitFailure;
  DspMicInitFailure _lastInitFailure = DspMicInitFailure.none;

  /// Cached result of the `isAvailable` probe (FIX 21 item 3): native
  /// availability cannot change during a session (the .so is either
  /// loaded or not; the channel is either registered or not), so the
  /// picker probes once and reuses the answer. Null = never probed.
  /// Written by [probeAvailable] and by [initialize].
  static bool? _cachedAvailable;

  /// FIX 22 item 6 — read the probe cache without pinging: the
  /// join-time DSP auto-try skips DSP entirely when a probe
  /// already failed this session (a dead .so costs one probe per
  /// session, not one per room entry). Null = never probed.
  static bool? get cachedAvailable => _cachedAvailable;

  /// FIX 22 item 8 — the reason the last probe (or init) failed,
  /// shared static so the picker label + diagnostics read it
  /// without owning a processor instance. [DspMicInitFailure.none]
  /// when the last probe/init succeeded or never ran. Written by
  /// [probeAvailable] and by [initialize] (same value, one source
  /// of truth — the probe path used to drop the reason entirely).
  static DspMicInitFailure get lastProbeFailure => _lastProbeFailure;
  static DspMicInitFailure _lastProbeFailure = DspMicInitFailure.none;

  /// FIX 22 item 8 — the NATIVE load error, when the Kotlin side
  /// recorded one (System.loadLibrary threw in
  /// DspMicProcessor.kt). Null when the .so loaded, when the
  /// channel is missing, or when the native side has no message
  /// (older builds). Best-effort, never throws; shown in Voice
  /// diagnostics only, so the user never needs logcat.
  static Future<String?> nativeLoadError() async {
    try {
      final msg = await const MethodChannel(channelName)
          .invokeMethod<String>('nativeLoadError')
          .timeout(const Duration(seconds: 2));
      return (msg == null || msg.isEmpty) ? null : msg;
    } catch (_) {
      return null;
    }
  }

  /// One ping of the native `isAvailable` check, with its failure
  /// reason. The ONE source of truth for DSP availability — both
  /// [initialize] and [probeAvailable] consult this, never a second
  /// opinion. Never throws.
  ///
  /// [useTimeout] is true on the switch path ([initialize] needs a
  /// bounded wait) and false for the background probe
  /// ([probeAvailable]): the probe is best-effort information, and
  /// a timeout Timer created on every console open breaks widget
  /// tests (fake_async fails on pending timers) for no benefit —
  /// the native answer is synchronous when present, and a probe
  /// that never answers just leaves the picker fail-open.
  static Future<DspMicInitFailure> _pingAvailable(
    MethodChannel channel, {
    bool useTimeout = true,
  }) async {
    try {
      final Future<bool?> call = channel.invokeMethod<bool>('isAvailable');
      final result = useTimeout
          ? await call.timeout(const Duration(seconds: 2))
          : await call;
      return (result ?? false)
          ? DspMicInitFailure.none
          : DspMicInitFailure.nativeAbsent;
    } on MissingPluginException {
      return DspMicInitFailure.channelMissing;
    } on PlatformException {
      return DspMicInitFailure.platformError;
    } on TimeoutException {
      return DspMicInitFailure.timeout;
    }
  }

  /// Probes DSP availability WITHOUT creating a processor (FIX 21
  /// item 3 — the RJ console's picker). Same `isAvailable` ping
  /// [initialize] uses, but WITHOUT a timeout or retry: the probe
  /// is best-effort background information (see [_pingAvailable]).
  /// Result is cached for the session (native availability cannot
  /// change while the app runs). Never throws.
  static Future<bool> probeAvailable() async {
    final cached = _cachedAvailable;
    if (cached != null) return cached;
    final failure = await _pingAvailable(
      const MethodChannel(channelName),
      useTimeout: false,
    );
    final available = failure == DspMicInitFailure.none;
    _cachedAvailable = available;
    // FIX 22 item 8: the probe used to drop the reason — the
    // picker label reads it from here (shared static).
    _lastProbeFailure = failure;
    return available;
  }

  /// Test-only: clears the [probeAvailable] cache so a test can
  /// re-probe with a different mocked channel.
  @visibleForTesting
  static void resetProbeCacheForTest() {
    _cachedAvailable = null;
    _lastProbeFailure = DspMicInitFailure.none;
  }

  /// True after a successful [initialize], until [dispose].
  bool get isInitialized => _initialized && !_disposed;

  /// True when the native side answered the `isAvailable` ping
  /// (Android with the Kotlin side registered). False on desktop/web,
  /// in tests without a mocked channel, or before [initialize].
  bool get isNativeAvailable => _nativeAvailable;

  /// True while a processor built by [buildProcessor] is alive.
  bool get hasActiveProcessor => _activeProcessor != null;

  /// Prepares the processor. Pings the native side (best-effort, short
  /// timeout); a missing native side FAILS init — unlike G2 there is
  /// no Dart fallback for the DSP engine, so the pipeline must not
  /// install a dead processor. On success the voice EQ preset is sent
  /// (the native bridge stores it until the engine is created on the
  /// first frame). Idempotent. Returns false only when the native side
  /// is absent or after [dispose].
  ///
  /// The ping runs unconditionally (not gated on [isSupported]): on a
  /// platform without the native side it fails fast with
  /// [MissingPluginException], and in tests a mocked channel can
  /// answer `true` so the success path is exercisable on any host.
  @override
  Future<bool> initialize() async {
    if (_disposed) return false;
    if (_initialized) return true;
    // FIX 21 (item 2): ONE retry on timeout only. The ping is a
    // synchronous native answer, so a timeout means the platform
    // thread was stalled — on a budget phone under voice load that
    // is a transient stall, not a dead native side. A retry costs
    // at most 2s extra and only on the timeout path; the other
    // failures (native absent / channel missing / platform error)
    // are definitive and are NOT retried. The failure reason is
    // kept in [lastInitFailure] instead of collapsing to `false`.
    var failure = await _pingAvailable(_channel);
    if (failure == DspMicInitFailure.timeout) {
      failure = await _pingAvailable(_channel);
    }
    _lastInitFailure = failure;
    // FIX 22 item 8: the shared static mirrors the instance
    // reason, so the picker label + diagnostics read the same
    // value whether the failure came from a probe or a switch.
    _lastProbeFailure = failure;
    _nativeAvailable = failure == DspMicInitFailure.none;
    _cachedAvailable = _nativeAvailable;
    if (!_nativeAvailable) {
      _log('initialize: DSP mic unavailable ($failure)');
      return false;
    }
    // Best-effort: the preset is stored natively even before the
    // engine exists; a failure here must not fail init (the engine
    // starts flat, which is still true bypass for echo/reverb).
    await setEqPreset(eqPreset);
    _initialized = true;
    _log('initialize: nativeAvailable=true, voice preset sent');
    return true;
  }

  /// Builds the [lk.TrackProcessor] to hand to
  /// `AudioCaptureOptions(processor:)`. Returns null when not
  /// initialized (or after [dispose]) — pass null through and the mic
  /// works unprocessed. Building twice destroys the previous processor
  /// first (a track must never be double-registered on the native
  /// side).
  @override
  Future<lk.TrackProcessor<lk.AudioProcessorOptions>?> buildProcessor() async {
    if (!isInitialized) return null;
    final previous = _activeProcessor;
    if (previous != null) {
      await previous.destroy();
      _activeProcessor = null;
    }
    final processor = DspMicTrackProcessor._(_channel);
    _activeProcessor = processor;
    return processor;
  }

  /// Changes the voice EQ live (no re-publish needed — the native
  /// bridge applies the new gains on the next frame). Returns false
  /// when the native side is absent.
  Future<bool> setEqPreset(DspMicEqPreset preset) async {
    return _sendParams('setEq', preset.toArgs(enabled: true));
  }

  /// Live EQ (four-band): `bassBoostDb` 0..12, `lowGainDb` /
  /// `midGainDb` / `highGainDb` -12..12. Same channel method and arg
  /// keys as [setEqPreset] (`setEq`; `bassDb` / `lowDb` / `midDb` /
  /// `highDb` — see DspMicProcessor.kt) — this is the per-knob form
  /// the RJ panel's BASS / TREBLE knobs drive (via the
  /// `RjVoiceDsp` control plane); [setEqPreset] stays the preset
  /// form. Returns false, never throws, when the native side is
  /// absent.
  Future<bool> setEq({
    bool enabled = true,
    double bassBoostDb = 0.0,
    double lowGainDb = 0.0,
    double midGainDb = 0.0,
    double highGainDb = 0.0,
  }) {
    return _sendParams('setEq', <String, Object>{
      'enabled': enabled,
      'bassDb': bassBoostDb.clamp(0.0, 12.0).toDouble(),
      'lowDb': lowGainDb.clamp(-12.0, 12.0).toDouble(),
      'midDb': midGainDb.clamp(-12.0, 12.0).toDouble(),
      'highDb': highGainDb.clamp(-12.0, 12.0).toDouble(),
    });
  }

  /// RJ STUDIO live setters — the panel's sliders call these while the
  /// host speaks. Each one only sends numbers over the channel; the
  /// bridge applies them on the next mic frame. No re-publish, no
  /// voice restart, no re-init (they work after [initialize] and even
  /// before it — the bridge stores the preset until the engine
  /// exists). All return false, never throw, when the native side is
  /// absent. Defaults and clamps mirror `AudioDsp` (v3 engine).

  /// Live echo (delay): `delayMs` 1..2000, `feedback` 0..0.95,
  /// `mix` 0..1.
  Future<bool> setEcho({
    bool enabled = true,
    double delayMs = 250.0,
    double feedback = 0.35,
    double mix = 0.35,
  }) {
    return _sendParams('setEcho', <String, Object>{
      'enabled': enabled,
      'delayMs': delayMs.clamp(1.0, 2000.0).toDouble(),
      'feedback': feedback.clamp(0.0, 0.95).toDouble(),
      'mix': mix.clamp(0.0, 1.0).toDouble(),
    });
  }

  /// Live reverb: `wetDryMix`, `roomSize`, `damping` all 0..1.
  Future<bool> setReverb({
    bool enabled = true,
    double wetDryMix = 0.3,
    double roomSize = 0.5,
    double damping = 0.5,
  }) {
    return _sendParams('setReverb', <String, Object>{
      'enabled': enabled,
      'wetDryMix': wetDryMix.clamp(0.0, 1.0).toDouble(),
      'roomSize': roomSize.clamp(0.0, 1.0).toDouble(),
      'damping': damping.clamp(0.0, 1.0).toDouble(),
    });
  }

  /// Live noise gate: `thresholdDb` -90..0, `attackMs` 0.1..500,
  /// `releaseMs` 5..2000.
  Future<bool> setNoiseGate({
    bool enabled = true,
    double thresholdDb = -40.0,
    double attackMs = 5.0,
    double releaseMs = 120.0,
  }) {
    return _sendParams('setNoiseGate', <String, Object>{
      'enabled': enabled,
      'thresholdDb': thresholdDb.clamp(-90.0, 0.0).toDouble(),
      'attackMs': attackMs.clamp(0.1, 500.0).toDouble(),
      'releaseMs': releaseMs.clamp(5.0, 2000.0).toDouble(),
    });
  }

  /// Live compressor (v3 engine): `thresholdDb` -60..0, `ratio`
  /// 1..20, `attackMs` 0.1..200, `releaseMs` 5..2000,
  /// `makeupGainDb` 0..24.
  Future<bool> setCompressor({
    bool enabled = true,
    double thresholdDb = -18.0,
    double ratio = 4.0,
    double attackMs = 10.0,
    double releaseMs = 100.0,
    double makeupGainDb = 0.0,
  }) {
    return _sendParams('setCompressor', <String, Object>{
      'enabled': enabled,
      'thresholdDb': thresholdDb.clamp(-60.0, 0.0).toDouble(),
      'ratio': ratio.clamp(1.0, 20.0).toDouble(),
      'attackMs': attackMs.clamp(0.1, 200.0).toDouble(),
      'releaseMs': releaseMs.clamp(5.0, 2000.0).toDouble(),
      'makeupGainDb': makeupGainDb.clamp(0.0, 24.0).toDouble(),
    });
  }

  /// Pushes one decoded soundboard clip to the native bridge (route A).
  /// [samples48k] must be the decoder's 48 kHz mono output.
  /// (SOUNDBOARD_INTEGRATION.md §3.)
  Future<bool> pushSoundboardClip(Float32List samples48k) async {
    try {
      final result = await _channel.invokeMethod<bool>(
        'loadSoundboardClip',
        <String, dynamic>{
          'samples': samples48k,
          'sampleRate': 48000,
        },
      );
      return result ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// Starts the pushed clip live on air (band 0, after DSP).
  Future<bool> playSoundboardClip(double gain) async {
    return _sendParams('playSoundboardClip', <String, Object>{
      'gain': gain.clamp(0.0, 1.0).toDouble(),
    });
  }

  /// Stops the live clip immediately.
  Future<bool> stopSoundboardClip() async {
    try {
      await _channel.invokeMethod<void>('stopSoundboardClip');
      return true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// Live gain for the playing clip (0..1).
  Future<bool> setSoundboardClipGain(double gain) async {
    return _sendParams('setSoundboardClipGain', <String, Object>{
      'gain': gain.clamp(0.0, 1.0).toDouble(),
    });
  }

  /// Best-effort param send: true when the native side answered,
  /// false when it is absent (fail-open — the mic keeps working).
  Future<bool> _sendParams(String method, Map<String, Object> args) async {
    try {
      await _channel.invokeMethod<void>(method, args);
      return true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// Bypasses the DSP in place (frames pass through untouched) or
  /// re-engages it — no re-publish needed. Returns false when the
  /// native side is absent.
  Future<bool> setBypass(bool bypass) async {
    try {
      final result = await _channel.invokeMethod<bool>(
        'setBypass',
        <String, dynamic>{'bypass': bypass},
      );
      return result ?? true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// Last native error code (0 = ok). -1 when the native side is
  /// absent. See dsp_mic_bridge.h for the code list (6 = the float
  /// sanity check failed, i.e. the buffer layout is not float32).
  Future<int> lastError() async {
    try {
      final result = await _channel.invokeMethod<int>('lastError');
      return result ?? -1;
    } on MissingPluginException {
      return -1;
    } on PlatformException {
      return -1;
    }
  }

  /// Frames the native bridge has actually EQ'd (10 ms APM frames).
  /// The on-device proof that frames are flowing: it must grow while
  /// the mic is live. -1 when the native side is absent.
  Future<int> framesProcessed() async {
    try {
      final result = await _channel.invokeMethod<int>('framesProcessed');
      return result ?? -1;
    } on MissingPluginException {
      return -1;
    } on PlatformException {
      return -1;
    }
  }

  /// Destroys the active processor (if any) and releases this
  /// instance. Idempotent; safe to call without [initialize].
  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final processor = _activeProcessor;
    _activeProcessor = null;
    if (processor != null) {
      await processor.destroy();
    }
    _initialized = false;
  }

  static void _log(String message) {
    if (kDebugMode) debugPrint('[DspMic] $message');
  }
}

/// The LiveKit seam implementation. Mirrors Group 2's
/// `RnnoiseTrackProcessor` (which mirrors the official Krisp plugin):
/// in-place native processing, so [processedTrack] is null and the
/// original mic track is published.
///
/// Every channel call is fail-open: a missing native handler (channel
/// not registered yet, wrong platform) leaves the mic unprocessed
/// instead of throwing into LiveKit's track setup.
class DspMicTrackProcessor implements lk.TrackProcessor<lk.AudioProcessorOptions> {
  DspMicTrackProcessor._(this._channel);

  final MethodChannel _channel;

  bool _destroyed = false;

  /// True once [init] has confirmed the native side is processing this
  /// track. False when the native side is absent (fail-open
  /// passthrough).
  bool get nativeActive => !_destroyed && _initOk;

  bool _initOk = false;

  @override
  String get name => 'DspMicProcessor';

  @override
  rtc.MediaStreamTrack? get processedTrack => null;

  @override
  Future<void> init(lk.AudioProcessorOptions options) async {
    _initOk = await _invokeBool('init', <String, dynamic>{
      'trackId': options.track.id,
    });
    _log('init track=${options.track.id} nativeActive=$nativeActive');
  }

  @override
  Future<void> restart(lk.AudioProcessorOptions options) async {
    _initOk = await _invokeBool('restart', <String, dynamic>{
      'trackId': options.track.id,
    });
  }

  @override
  Future<void> destroy() async {
    if (_destroyed) return;
    _destroyed = true;
    _initOk = false;
    await _invoke('destroy');
  }

  @override
  Future<void> onPublish(lk.Room room) async {
    // DSP needs no auth and no room context (unlike Krisp, which
    // authenticates against the room). Forwarded so the native side
    // can log/latch the publish transition if it wants to.
    await _invoke('onPublish');
  }

  @override
  Future<void> onUnpublish() async {
    await _invoke('onUnpublish');
  }

  /// Best-effort call; returns true when native code answered without
  /// error. A null reply counts as success (the native side answers
  /// `success(null)` for void-style calls); only an explicit `false`
  /// or an exception means "not active".
  Future<bool> _invokeBool(String method, [Map<String, dynamic>? args]) async {
    try {
      final result = await _channel.invokeMethod<bool>(method, args);
      return result ?? true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  Future<void> _invoke(String method, [Map<String, dynamic>? args]) async {
    try {
      await _channel.invokeMethod<void>(method, args);
    } on MissingPluginException {
      // Native side not registered: fail open, mic keeps working.
    } on PlatformException {
      // Same: never let a processor call break the call.
    }
  }

  static void _log(String message) {
    if (kDebugMode) debugPrint('[DspMic] $message');
  }
}
