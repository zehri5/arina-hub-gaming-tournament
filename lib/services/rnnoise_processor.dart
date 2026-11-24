/// RNNoise mic noise suppression for Arena Hub voice rooms (Group 2, #10 audio).
///
/// Wiring (Group 7): same shape as Group 1's Krisp class —
/// ```dart
/// final rnnoise = RnnoiseMicProcessor();
/// if (await rnnoise.initialize()) {
///   final processor = await rnnoise.buildProcessor();
///   // pass into the mic track:
///   await room.localParticipant?.setMicrophoneEnabled(
///     true,
///     audioCaptureOptions: lk.AudioCaptureOptions(processor: processor),
///   );
/// }
/// ```
/// `buildProcessor()` returns null when [RnnoiseMicProcessor.initialize]
/// has not run (or after [RnnoiseMicProcessor.dispose]); pass null through
/// and the mic just works unprocessed.
///
/// How it works (livekit_client 2.13.2 TrackProcessor seam, verified against
/// the pub-cache source):
/// * [RnnoiseTrackProcessor] implements `TrackProcessor<AudioProcessorOptions>`.
///   LiveKit calls `init(AudioProcessorOptions(track: ...))` from
///   `LocalTrack.setProcessor`, then publishes the track. Like the official
///   Krisp plugin (`livekit_noise_filter`), `processedTrack` is null: the
///   audio is processed IN PLACE on the native side, so the original track
///   is published unchanged from Dart's point of view.
/// * On Android the Dart side talks to `RnnoiseProcessor.kt` over the
///   `arena_hub_rnnoise` MethodChannel. The Kotlin side registers an
///   `AudioProcessingAdapter.ExternalAudioFrameProcessing` on flutter_webrtc's
///   `audioProcessingController.capturePostProcessing` (the same hook the
///   Krisp plugin uses), and each 10 ms mic frame runs through the vendored
///   RNNoise C library (`android/app/src/main/cpp/rnnoise/`, xiph/rnnoise,
///   BSD-licensed) via JNI.
/// * The APM hands the hook SPLIT-BAND float32 audio — 1-3 bands x 160
///   samples, planar, band-major; each band is 10 ms at an effective
///   16 kHz. The native bridge (`cpp/rnnoise_bridge.cpp`) resamples each
///   band 16 kHz -> 48 kHz, runs it through its own RNNoise
///   `DenoiseState` (480-sample frames), and resamples back — in place,
///   zero-copy from the direct ByteBuffer. Added latency ~2.6 ms.
/// * [SpectralGateNoiseSuppressor] is the pure-Dart fallback DSP stage:
///   a real spectral-subtraction gate (FFT, adaptive noise floor, Wiener-ish
///   gains, overlap-add). It is fully unit-tested here and is what the Dart
///   side can verify without a device. It is NOT wired to the live mic —
///   flutter_webrtc exposes no Dart-side audio-frame API, so live mic audio
///   can only be touched natively (see above).
///
/// Honest status (host-verified, on-device pending):
/// * Dart plumbing through the seam: implemented + unit-tested.
/// * Native bridge: Kotlin processor + JNI wrapper + C++ bridge written;
///   the C was compiled and run on the host — 33/33 host checks pass
///   (see `android/app/src/main/cpp/rnnoise/README.md` for the numbers:
///   lowpassed noise -20.1 dB, speech-band resampler round-trip 82.5 dB
///   SNR, speech proxy survives in noise, noise-only band -39 dB).
///   The vendored RNNoise needed a 2-line FFT-scaling fix to work at
///   all (its kiss_fft is Opus's 1/N-scaled variant; without the fix
///   the silence gate ate everything below ~RMS 0.45) — documented in
///   the README.
/// * The on-device path (APK build + real mic) is NOT verified yet — no
///   APK build is allowed in this task — and the split-band buffer
///   layout is taken from the WebRTC `ExternalAudioProcessing` contract
///   plus the Krisp plugin's identical usage, not proven on-device.
///   First phone test: join a voice room with background noise, check
///   [RnnoiseTrackProcessor.framesProcessed] grows, and A/B with
///   [RnnoiseTrackProcessor.setBypass].
/// * iOS: not wired in this prototype (Android only). The RNNoise C is
///   portable; the iOS hook needs the iOS equivalent of the
///   AudioProcessingAdapter registration (Group 6's lane).
/// * Fail-open by design: if the native side is missing/unregistered, every
///   channel call degrades to a no-op and the mic keeps working unprocessed.
///   Nothing here can break a voice call.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show MediaStreamTrack;
import 'package:livekit_client/livekit_client.dart';

import 'mic_audio_pipeline.dart';

/// Which suppression engine will actually process the mic.
///
/// * [native] — the vendored RNNoise C engine on the native side.
/// * [spectralGate] — the pure-Dart [SpectralGateNoiseSuppressor]; used only
///   when the native side is unavailable (desktop/web, or the Kotlin side
///   not registered yet). The live mic is NOT gated in this mode — see the
///   file doc comment — the gate is the tested DSP reference.
enum RnnoiseEngine {
  /// Real RNNoise (C) running natively on the mic capture path.
  native,

  /// Pure-Dart spectral gate (reference/fallback; not on the live mic).
  spectralGate,
}

/// Mic noise suppression via RNNoise. Same public shape as Group 1's Krisp
/// class so Group 7 can wire either implementation behind one switch.
class RnnoiseMicProcessor implements MicNoiseProcessor {
  /// MethodChannel shared with `RnnoiseProcessor.kt`.
  static const String channelName = 'arena_hub_rnnoise';

  /// The native RNNoise path is wired for Android only in this prototype.
  static bool isSupported() =>
      <PlatformType>[PlatformType.android].contains(lkPlatform());

  final MethodChannel _channel = const MethodChannel(channelName);

  bool _initialized = false;
  bool _disposed = false;
  bool _nativeAvailable = false;
  RnnoiseTrackProcessor? _activeProcessor;

  /// True after a successful [initialize], until [dispose].
  bool get isInitialized => _initialized && !_disposed;

  /// True when the native side answered the `isAvailable` ping (Android
  /// with the Kotlin side registered). False on desktop/web, in tests
  /// without a mocked channel, or before [initialize].
  bool get isNativeAvailable => _nativeAvailable;

  /// Which engine will process the mic once a processor is built.
  RnnoiseEngine get engine =>
      _nativeAvailable ? RnnoiseEngine.native : RnnoiseEngine.spectralGate;

  /// True while a processor built by [buildProcessor] is alive.
  bool get hasActiveProcessor => _activeProcessor != null;

  /// Prepares the processor. Pings the native side (best-effort, short
  /// timeout); a missing native side does NOT fail init — [engine] just
  /// reports [RnnoiseEngine.spectralGate] and the mic still works.
  /// Idempotent. Returns false only after [dispose].
  Future<bool> initialize() async {
    if (_disposed) return false;
    if (_initialized) return true;
    if (isSupported()) {
      try {
        final result = await _channel
            .invokeMethod<bool>('isAvailable')
            .timeout(const Duration(seconds: 2));
        _nativeAvailable = result ?? false;
      } on MissingPluginException {
        _nativeAvailable = false;
      } on PlatformException {
        _nativeAvailable = false;
      } on TimeoutException {
        _nativeAvailable = false;
      }
    } else {
      _nativeAvailable = false;
    }
    _initialized = true;
    _log('initialize: nativeAvailable=$_nativeAvailable engine=$engine');
    return true;
  }

  /// Builds the [TrackProcessor] to hand to `AudioCaptureOptions(processor:)`.
  /// Returns null when not initialized (or after [dispose]) — pass null
  /// through and the mic works unprocessed. Building twice destroys the
  /// previous processor first (a track must never be double-registered
  /// on the native side).
  Future<TrackProcessor<AudioProcessorOptions>?> buildProcessor() async {
    if (!isInitialized) return null;
    final previous = _activeProcessor;
    if (previous != null) {
      await previous.destroy();
      _activeProcessor = null;
    }
    final processor = RnnoiseTrackProcessor._(
      _channel,
      nativeAvailable: _nativeAvailable,
    );
    _activeProcessor = processor;
    return processor;
  }

  /// Destroys the active processor (if any) and releases this instance.
  /// Idempotent; safe to call without [initialize].
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
    if (kDebugMode) debugPrint('[Rnnoise] $message');
  }
}

/// The LiveKit seam implementation. Mirrors the official Krisp plugin's
/// shape (`livekit_noise_filter`): in-place native processing, so
/// [processedTrack] is null and the original mic track is published.
///
/// Every channel call is fail-open: a missing native handler (channel not
/// registered yet, wrong platform) leaves the mic unprocessed instead of
/// throwing into LiveKit's track setup.
class RnnoiseTrackProcessor implements TrackProcessor<AudioProcessorOptions> {
  RnnoiseTrackProcessor._(this._channel, {required bool nativeAvailable})
      : _nativeAvailable = nativeAvailable;

  final MethodChannel _channel;
  final bool _nativeAvailable;

  bool _destroyed = false;

  /// True once [init] has confirmed the native side is processing this
  /// track. False when the native side is absent (fail-open passthrough).
  bool get nativeActive => _nativeAvailable && !_destroyed && _initOk;

  bool _initOk = false;

  @override
  String get name => 'RnnoiseMicProcessor';

  @override
  MediaStreamTrack? get processedTrack => null;

  @override
  Future<void> init(AudioProcessorOptions options) async {
    _initOk = await _invokeBool('init', <String, dynamic>{
      'trackId': options.track.id,
    });
    _log('init track=${options.track.id} nativeActive=$nativeActive');
  }

  @override
  Future<void> restart(AudioProcessorOptions options) async {
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
  Future<void> onPublish(Room room) async {
    // RNNoise needs no auth and no room context (unlike Krisp, which
    // authenticates against the room). Forwarded so the native side can
    // log/latch the publish transition if it wants to.
    await _invoke('onPublish');
  }

  @override
  Future<void> onUnpublish() async {
    await _invoke('onUnpublish');
  }

  /// Temporarily passes audio through unprocessed without unregistering.
  /// Returns false when the native side is absent.
  Future<bool> setBypass(bool bypass) async =>
      _invokeBool('setBypass', <String, dynamic>{'bypass': bypass});

  /// Last native error code (0 = ok). -1 when the native side is absent.
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

  /// Frames the native bridge has actually processed (10 ms APM frames
  /// routed through RNNoise). The on-device proof that frames are
  /// flowing: it must grow while the mic is live. -1 when the native
  /// side is absent.
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
    if (kDebugMode) debugPrint('[Rnnoise] $message');
  }
}

/// Pure-Dart spectral-subtraction noise gate — the tested DSP reference
/// stage and the fallback when the native RNNoise engine is unavailable.
///
/// Frame-based, RNNoise-style framing: 480-sample frames at 48 kHz
/// (10 ms), processed with 50% overlap-add (hop 240) so a steady tone
/// passes through bit-stable while broadband noise is gated down.
///
/// Algorithm (classic, prototype-grade — NOT the RNNoise neural model):
/// 1. one-pole DC blocker (kills rumble/DC offset);
/// 2. sqrt-Hann window -> 512-point FFT (zero-padded);
/// 3. per-bin noise floor tracked with STABILITY GATING: a bin whose
///    magnitude barely changes between consecutive frames is tonal
///    (a speech harmonic or steady tone) and its floor is FROZEN, so
///    the gate never eats the signal it should preserve; a bin whose
///    magnitude jumps frame to frame (Rayleigh-distributed, like
///    noise) is noise-like and its floor tracks the magnitude.
///    (An earlier min-statistics version learned the tone itself as
///    "noise" and gated steady tones to the 15% floor — the stability
///    gate is the fix.)
/// 4. Wiener-ish power-subtraction gains with a spectral floor (max
///    ~16 dB suppression per bin), smoothed in time to avoid pumping;
/// 5. inverse FFT -> sqrt-Hann synthesis -> overlap-add.
///
/// Stateful: one instance per audio stream; call [reset] when the stream
/// restarts. Deterministic for a given input sequence.
class SpectralGateNoiseSuppressor {
  /// Samples per frame (10 ms at 48 kHz, same as RNNoise).
  static const int frameSize = 480;

  /// Sample rate this gate is tuned for.
  static const int sampleRate = 48000;

  static const int _fftSize = 512;
  static const int _hop = 240; // 50% overlap
  static const int _bins = _fftSize ~/ 2 + 1;

  // Over-subtraction factor: how aggressively the estimated noise
  // spectrum is subtracted from the signal spectrum.
  static const double _overSubtraction = 1.5;

  // Spectral floor: no bin is ever gated below 15% of its magnitude
  // (~16 dB max suppression), which keeps the residual natural.
  static const double _spectralFloor = 0.15;

  // Floor-tracking rate for noise-like bins (both directions).
  static const double _floorAlpha = 0.1;

  // A bin is tonal when its magnitude changes by less than this
  // fraction between consecutive frames. Noise magnitudes jump
  // (Rayleigh: typical frame-to-frame change ~70% of the mean);
  // a steady tone's magnitude is near-constant.
  static const double _tonalStability = 0.15;

  final Float64List _noiseFloor = Float64List(_bins);
  final Float64List _prevMag = Float64List(_bins);
  final Float64List _smoothedGain = Float64List(_bins)..fillRange(0, _bins, 1);
  final Float64List _window = Float64List(frameSize);

  // Overlap-add state: 240-sample tails carried between frames.
  final Float64List _inputTail = Float64List(_hop);
  final Float64List _outputTail = Float64List(_hop);

  final Float64List _fftRe = Float64List(_fftSize);
  final Float64List _fftIm = Float64List(_fftSize);
  final Float64List _mag = Float64List(_bins);

  double _dcPrevIn = 0;
  double _dcPrevOut = 0;
  int _framesSeen = 0;

  SpectralGateNoiseSuppressor() {
    // sqrt-Hann: analysis x synthesis = Hann, which sums to 1.0 at
    // 50% overlap, so gains of 1.0 reconstruct the input exactly.
    for (var i = 0; i < frameSize; i++) {
      _window[i] =
          math.sqrt(0.5 * (1 - math.cos(2 * math.pi * i / (frameSize - 1))));
    }
    // The noise floor starts at zero (fail-open: gains of 1.0 until
    // the tracker has seen real audio). A high initial floor would
    // gate the first frames, not pass them — the gain subtracts the
    // floor, so high floor means MORE suppression, not less.
  }

  /// Frames processed since construction or the last [reset].
  int get framesProcessed => _framesSeen;

  /// Processes one 480-sample frame, returns a new 480-sample frame.
  /// Throws [ArgumentError] for any other length.
  Float32List processFrame(Float32List frame) {
    if (frame.length != frameSize) {
      throw ArgumentError.value(
        frame.length,
        'frame.length',
        'must be $frameSize samples (10 ms at 48 kHz)',
      );
    }
    // Assemble 720 samples: 240 carried + 480 new; two 480-windows at
    // offsets 0 and 240 (50% overlap).
    final input = Float64List(frameSize + _hop);
    input.setRange(0, _hop, _inputTail);
    for (var i = 0; i < frameSize; i++) {
      // DC blocker: y[n] = x[n] - x[n-1] + 0.995 * y[n-1].
      final x = frame[i].toDouble();
      final y = x - _dcPrevIn + 0.995 * _dcPrevOut;
      _dcPrevIn = x;
      _dcPrevOut = y;
      input[_hop + i] = y;
    }
    _inputTail.setRange(0, _hop, input, frameSize);

    final output = Float64List(frameSize + _hop);
    output.setRange(0, _hop, _outputTail);
    _processWindow(input, 0, output, 0);
    _processWindow(input, _hop, output, _hop);
    _outputTail.setRange(0, _hop, output, frameSize);

    _framesSeen++;
    final result = Float32List(frameSize);
    for (var i = 0; i < frameSize; i++) {
      // Hard clamp: the gate must never emit out-of-range samples.
      result[i] = output[i].clamp(-1.0, 1.0);
    }
    return result;
  }

  /// Clears all filter state (noise floor, overlap tails, DC blocker).
  void reset() {
    _noiseFloor.fillRange(0, _bins, 0);
    _prevMag.fillRange(0, _bins, 0);
    _smoothedGain.fillRange(0, _bins, 1);
    _inputTail.fillRange(0, _hop, 0);
    _outputTail.fillRange(0, _hop, 0);
    _dcPrevIn = 0;
    _dcPrevOut = 0;
    _framesSeen = 0;
  }

  void _processWindow(
    Float64List input,
    int inOffset,
    Float64List output,
    int outOffset,
  ) {
    // Window + zero-pad to 512.
    _fftRe.fillRange(0, _fftSize, 0);
    _fftIm.fillRange(0, _fftSize, 0);
    for (var i = 0; i < frameSize; i++) {
      _fftRe[i] = input[inOffset + i] * _window[i];
    }
    _fft(_fftRe, _fftIm, inverse: false);

    for (var b = 0; b < _bins; b++) {
      final re = _fftRe[b];
      final im = _fftIm[b];
      _mag[b] = math.sqrt(re * re + im * im);
    }

    // Noise-floor tracking, gated by tonality. A bin whose magnitude
    // is stable across frames is tonal (a speech harmonic or steady
    // tone): freeze its floor, so a steady tone is never learned as
    // "noise" and gated away. A bin whose magnitude jumps is
    // noise-like (Rayleigh): track it symmetrically so the floor sits
    // at the noise's mean level, where the Wiener gain below can
    // suppress it.
    for (var b = 0; b < _bins; b++) {
      final mag = _mag[b];
      final prevMag = _prevMag[b];
      _prevMag[b] = mag;
      final tonal =
          mag > 1e-9 && (mag - prevMag).abs() < _tonalStability * mag;
      if (!tonal) {
        _noiseFloor[b] += (mag - _noiseFloor[b]) * _floorAlpha;
      }
    }

    // Wiener-ish power-subtraction gains, smoothed in time.
    final gains = Float64List(_bins);
    for (var b = 0; b < _bins; b++) {
      final magSq = _mag[b] * _mag[b] + 1e-12;
      final noiseSq = _noiseFloor[b] * _noiseFloor[b];
      var gain = math.sqrt(
        math.max(magSq - _overSubtraction * noiseSq, 0) / magSq,
      );
      gain = math.max(gain, _spectralFloor);
      // Attack fast (noise appears -> gate closes), release slow
      // (speech returns -> gate opens gently, no pumping).
      final alpha = gain < _smoothedGain[b] ? 0.4 : 0.08;
      _smoothedGain[b] += (gain - _smoothedGain[b]) * alpha;
      gains[b] = _smoothedGain[b];
    }
    // No frequency smoothing of the gains: it would smear the
    // near-zero gains of empty neighbour bins onto a tone's bins and
    // gate the tone down with them.
    for (var b = 0; b < _bins; b++) {
      _fftRe[b] *= gains[b];
      _fftIm[b] *= gains[b];
      // Mirror the conjugate half for a real inverse FFT.
      if (b > 0 && b < _fftSize ~/ 2) {
        _fftRe[_fftSize - b] = _fftRe[b];
        _fftIm[_fftSize - b] = -_fftIm[b];
      }
    }
    _fft(_fftRe, _fftIm, inverse: true);

    for (var i = 0; i < frameSize; i++) {
      output[outOffset + i] += _fftRe[i] * _window[i];
    }
  }

  /// Iterative radix-2 FFT (in place). [_fftSize] is a power of two.
  static void _fft(Float64List re, Float64List im, {required bool inverse}) {
    final n = re.length;
    // Bit-reversal permutation.
    var j = 0;
    for (var i = 1; i < n; i++) {
      var bit = n >> 1;
      while ((j & bit) != 0) {
        j ^= bit;
        bit >>= 1;
      }
      j ^= bit;
      if (i < j) {
        final tr = re[i];
        re[i] = re[j];
        re[j] = tr;
        final ti = im[i];
        im[i] = im[j];
        im[j] = ti;
      }
    }
    // Cooley-Tukey butterflies.
    var len = 2;
    while (len <= n) {
      final angle = (inverse ? 2 : -2) * math.pi / len;
      final wRe = math.cos(angle);
      final wIm = math.sin(angle);
      for (var i = 0; i < n; i += len) {
        var curRe = 1.0;
        var curIm = 0.0;
        for (var k = 0; k < len ~/ 2; k++) {
          final uRe = re[i + k];
          final uIm = im[i + k];
          final vRe = re[i + k + len ~/ 2] * curRe -
              im[i + k + len ~/ 2] * curIm;
          final vIm = re[i + k + len ~/ 2] * curIm +
              im[i + k + len ~/ 2] * curRe;
          re[i + k] = uRe + vRe;
          im[i + k] = uIm + vIm;
          re[i + k + len ~/ 2] = uRe - vRe;
          im[i + k + len ~/ 2] = uIm - vIm;
          final nextRe = curRe * wRe - curIm * wIm;
          curIm = curRe * wIm + curIm * wRe;
          curRe = nextRe;
        }
      }
      len <<= 1;
    }
    if (inverse) {
      for (var i = 0; i < n; i++) {
        re[i] /= n;
        im[i] /= n;
      }
    }
  }
}
