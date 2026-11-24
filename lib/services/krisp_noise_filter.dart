import 'package:livekit_client/livekit_client.dart';
import 'package:livekit_noise_filter/livekit_noise_filter.dart';

import 'mic_audio_pipeline.dart';

/// AUDIO #10 Group 1 — Krisp mic noise cancellation.
///
/// Thin, fail-soft wrapper around `livekit_noise_filter` 0.2.1
/// (`LiveKitNoiseFilter`, the NC model only on Flutter). The caller wires
/// the processor into the mic BEFORE connecting, per the plugin README:
///
/// ```dart
/// final krisp = KrispMicProcessor();
/// await krisp.initialize();
/// final processor = await krisp.buildProcessor();
/// final room = Room(
///   roomOptions: RoomOptions(
///     defaultAudioCaptureOptions: AudioCaptureOptions(
///       processor: processor,
///     ),
///   ),
/// );
/// ```
///
/// [buildProcessor] returns the typed `TrackProcessor<AudioProcessorOptions>?`
/// directly (fixed 2026-11-22: was the raw [TrackProcessor] type, which did
/// not assign to `AudioCaptureOptions.processor` without a cast).
///
/// ## SELF-HOSTED VERDICT — Krisp is Cloud-gated, expect it OFF on our server
///
/// Every source checked 2026-11-22 says the same thing: the Krisp filter
/// only activates when the LiveKit server says the project is entitled to
/// enhanced noise cancellation, and that entitlement is a LiveKit Cloud
/// feature — our server is self-hosted.
///
/// Evidence (all read, not assumed):
/// * Plugin source, web path (`livekit_noise_filter` 0.2.1,
///   `lib/src/web/krisp_wrapper.dart`): on publish it does
///   `GET {roomServerUrl}/settings` with the room JWT and enables the
///   filter ONLY when the response has `enhancedNoiseCancellation == true`;
///   otherwise it logs "this LiveKit project is not supported" and stays
///   disabled.
/// * Plugin source, native path (`lib/src/livekit_noise_filter_native.dart`
///   + `android/.../LiveKitKrispNoiseFilterPlugin.kt`): `onPublish` passes
///   the room's url + token to native `authenticate(url, token)` in the
///   CLOSED-SOURCE core AAR (`io.livekit:krisp-noise-filter-core:0.0.15`),
///   whose `ErrorCode` includes `kAuthorizationRequired`,
///   `kAuthorizationFailed` and `kNotSupported` ("Feature not supported by
///   server"). The exact native HTTP call cannot be audited (binary only),
///   but the contract mirrors the web gate.
/// * LiveKit docs (docs.livekit.io/home/cloud/noise-cancellation):
///   "LiveKit Cloud includes access to advanced noise cancellation models
///   (ai-coustics and Krisp)"; "Enhanced noise cancellation is available
///   when you use LiveKit Cloud for realtime transport." The only
///   documented self-hosted escape hatch is ai-coustics with your own
///   license key — there is none for Krisp.
/// * livekit-plugins-krisp (PyPI): the Krisp-license alternative "is for
///   running the public Krisp SDK directly with your own Krisp license —
///   for example, when using Livekit OSS server", i.e. the default path
///   does NOT work against the OSS server.
/// * LiveKit community: "the enhanced Krisp and ai-coustics models are tied
///   to LiveKit Cloud transport, and even the frontend Krisp filter pulls
///   its models at runtime" (models come from
///   `https://livekit.io/integrations/enc/v1`).
///
/// What this means for wiring: attaching the processor is SAFE — the gate
/// fails closed (filter stays bypassed, mic keeps working with plain
/// WebRTC `noiseSuppression`) — but it is EXPECTED INEFFECTIVE on our
/// self-hosted server until/unless we move to LiveKit Cloud or buy a
/// Krisp license. A live on-device proof (the exact `lastError()` code
/// against our server) still needs a real phone + our server; it cannot be
/// produced from this VM (no mic, no server access, no Android device).
///
/// Platform support: Android, iOS, macOS only (`LiveKitNoiseFilter`
/// itself). On any other platform [initialize] returns false and
/// [buildProcessor] returns null — the mic then simply runs unfiltered.
///
/// Every method is best-effort and never throws into the caller.
class KrispMicProcessor implements MicNoiseProcessor {
  LiveKitNoiseFilter? _filter;
  bool _initialized = false;
  bool _disposed = false;

  /// True after a successful [initialize] until [dispose]: the Krisp
  /// processor exists and can be attached to the mic. False on
  /// unsupported platforms and before [initialize].
  bool get isAvailable => _initialized && !_disposed && _filter != null;

  /// Creates the Krisp processor when the platform supports it.
  ///
  /// Returns true only on Android/iOS/macOS. Returns false (never throws)
  /// on unsupported platforms or if anything goes wrong — the caller must
  /// then publish the mic without a processor.
  Future<bool> initialize() async {
    if (_disposed) return false;
    if (_initialized) return _filter != null;
    _initialized = true;
    try {
      final supported = await LiveKitNoiseFilter.isSupported();
      if (!supported) return false;
      _filter = LiveKitNoiseFilter();
      return true;
    } catch (_) {
      _filter = null;
      return false;
    }
  }

  /// Returns the processor to attach via
  /// `AudioCaptureOptions(processor: ...)`, or null when Krisp is
  /// unavailable (unsupported platform, failed init, or after [dispose]).
  ///
  /// Safe to call without [initialize]: it initializes lazily first.
  /// Repeated calls return the same instance.
  Future<TrackProcessor<AudioProcessorOptions>?> buildProcessor() async {
    if (_disposed) return null;
    if (!_initialized) {
      await initialize();
    }
    return _filter;
  }

  /// Releases the processor. Safe to call before [initialize], after
  /// [initialize], and more than once. The instance is unusable afterwards.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final filter = _filter;
    _filter = null;
    _initialized = false;
    if (filter == null) return;
    try {
      await filter.destroy();
    } catch (_) {}
  }
}
