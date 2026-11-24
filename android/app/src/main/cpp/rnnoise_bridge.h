// RNNoise per-band bridge — JNI-free core (host-testable).
//
// Arena Hub #10 audio, Group 2. Wires the vendored xiph/rnnoise C engine
// (rnnoise/, BSD) to the WebRTC APM capture post-processing hook
// (flutter_webrtc AudioProcessingAdapter.ExternalAudioFrameProcessing,
// same hook the official Krisp plugin uses — see RnnoiseProcessor.kt).
//
// WHY PER-BAND: the APM hands the hook SPLIT-BAND float32 audio —
// `numBands` (1-3) bands x `numFrames` (160) samples, planar, band-major.
// Each band is 10 ms at an effective 16 kHz (band 0 = 0-8 kHz,
// band 1 = 8-16 kHz, band 2 = 16-24 kHz). RNNoise is a 48 kHz full-band
// model (480-sample frames), so each band is resampled 16 kHz -> 48 kHz,
// run through its own DenoiseState, and resampled back. Processing each
// band independently is also what WebRTC's own noise suppressor does
// (it operates on the split bands), and it avoids a second pass through
// WebRTC's lossy analysis/synthesis filterbank. The resampler is a
// windowed-sinc FIR whose coefficients are generated at runtime (no
// transcribed tables to get wrong); see Resampler3x.
//
// Added latency: ~2.6 ms constant (63 samples @ 48 kHz per resampler
// stage). The post-processing hook runs AFTER AEC in the APM pipeline,
// so the extra delay does not disturb echo cancellation.
//
// Fail-open: any unexpected shape (wrong frame size, bad band count,
// stereo input, RNNoise alloc failure) leaves the buffer untouched and
// records an error code retrievable via lastError(). Nothing here can
// silence or break a voice call.

#pragma once

#include <cstddef>
#include <cstdint>
#include <mutex>

#include "rnnoise.h"

namespace arena_rnnoise {

// Fixed by the WebRTC APM split-band contract: each band is 160 float32
// samples = 10 ms at an effective 16 kHz.
inline constexpr int kSamplesPerBand = 160;
inline constexpr int kMaxBands = 3;
// RNNoise frame: 480 samples at 48 kHz (rnnoise_get_frame_size()).
inline constexpr int kRnnoiseFrameSize = 480;
inline constexpr int kResampleFactor = 3;

// Error codes reported via lastError() (0 = ok). Mirrored in
// RnnoiseProcessor.kt / the Dart side's lastError() documentation.
enum BridgeError : int {
  kBridgeOk = 0,
  kBridgeNotInitialized = 1,
  kBridgeBadFrameSize = 2,
  kBridgeBadBandCount = 3,
  kBridgeUnsupportedChannels = 4,
  kBridgeRnnoiseAllocFailed = 5,
  kBridgeBadBuffer = 6,
};

// 3x sample-rate converter between 16 kHz band signals and the 48 kHz
// RNNoise frame rate. One low-pass FIR (127 taps, Blackman-windowed
// sinc, cutoff 8 kHz) serves both directions: upsampling uses it at
// gain 3 (compensating zero-insertion), downsampling at gain 1/3.
// Group delay is 63 samples @ 48 kHz (1.3125 ms) per direction, so the
// up -> RNNoise -> down cascade adds a constant ~2.6 ms and never
// drifts: every 160-sample input frame yields exactly one 160-sample
// output frame.
//
// Stateful (filter history); one instance per band, never shared
// across bands. Not thread-safe on its own — RnnoiseBridge serializes
// access with a mutex.
class Resampler3x {
 public:
  static constexpr int kFilterTaps = 127;
  // Half-length (group delay in 48 kHz samples).
  static constexpr int kDelay48k = (kFilterTaps - 1) / 2;

  Resampler3x();

  // 160 samples @ 16 kHz -> 480 samples @ 48 kHz. `in` and `out` must
  // not alias.
  void upsample(const float* in, float* out);
  // 480 samples @ 48 kHz -> 160 samples @ 16 kHz. `in` and `out` must
  // not alias.
  void downsample(const float* in, float* out);

  void reset();

  // Exposed for the host test: the filter's DC gain must be ~3.0.
  float filterDcGain() const;

 private:
  // Upsampling needs the 42 input samples before the current frame
  // ((127-1)/3 rounded up); keep 48 for headroom.
  static constexpr int kUpHistory = 48;
  // Downsampling needs the 126 @ 48 kHz samples before the current
  // frame; keep 128.
  static constexpr int kDownHistory = 128;

  float coeffs_[kFilterTaps];
  float upHistory_[kUpHistory];
  float downHistory_[kDownHistory];
};

// Owns one DenoiseState + one Resampler3x per band and routes APM
// split-band frames through RNNoise, in place.
//
// Threading: process() runs on the WebRTC audio thread while init()
// / release() run on the platform thread; every method takes the
// internal mutex. The lock is uncontended in steady state.
class RnnoiseBridge {
 public:
  RnnoiseBridge();
  ~RnnoiseBridge();
  RnnoiseBridge(const RnnoiseBridge&) = delete;
  RnnoiseBridge& operator=(const RnnoiseBridge&) = delete;

  // (Re-)initializes for the APM rate. Only the APM's native rates
  // (16/32/48 kHz) and mono input are supported; anything else returns
  // false and process() passes audio through untouched. Safe to call
  // repeatedly (e.g. from the hook's reset() on a rate change).
  bool init(int sampleRateHz, int numChannels);

  // Processes one APM frame in place. `bands` holds
  // numBands * numFrames float32 samples, band-major (band 0 first).
  // Fails open on any unexpected shape.
  void process(float* bands, int numBands, int numFrames);

  // When bypassed, process() leaves the buffer untouched (the native
  // side stays registered; the mic just runs unprocessed).
  void setBypass(bool bypass);
  bool isBypassed() const;

  // Frees the RNNoise states. The object stays usable via init().
  void release();

  bool isInitialized() const;
  int64_t framesProcessed() const;
  int lastError() const;
  // RNNoise voice-activity probability of the last processed frame
  // (band 0), 0.0-1.0. Diagnostics only.
  float lastVoiceProb() const;

 private:
  void releaseLocked();

  mutable std::mutex mutex_;
  bool initialized_ = false;
  bool bypass_ = false;
  int sampleRateHz_ = 0;
  DenoiseState* states_[kMaxBands] = {nullptr, nullptr, nullptr};
  Resampler3x resamplers_[kMaxBands];
  int64_t framesProcessed_ = 0;
  int lastError_ = kBridgeOk;
  float lastVoiceProb_ = 0.f;
  // Scratch buffers (only touched under the mutex, on the audio thread).
  float tmp48_[kRnnoiseFrameSize];
  float tmp48Out_[kRnnoiseFrameSize];
};

}  // namespace arena_rnnoise
