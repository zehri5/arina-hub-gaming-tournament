// RNNoise per-band bridge — implementation. See rnnoise_bridge.h for
// the architecture notes (split-band routing, resampler, fail-open).

#include "rnnoise_bridge.h"

#include <cmath>
#include <cstring>

namespace arena_rnnoise {

namespace {

// pi with enough digits for the windowed-sinc coefficient generation.
constexpr double kPi = 3.14159265358979323846;

float sinc(float x) {
  if (x == 0.f) return 1.f;
  const float px = static_cast<float>(kPi) * x;
  return std::sin(px) / px;
}

}  // namespace

Resampler3x::Resampler3x() {
  // Blackman-windowed sinc, cutoff 8 kHz at 48 kHz (normalized cutoff
  // 1/6 cycles/sample). h[n] = sinc((n-M)/3) * w[n]; the sum over n is
  // ~3.0, which is exactly the gain an interpolator needs to compensate
  // zero-insertion. The downsampler reuses the same table scaled by 1/3.
  constexpr int m = kDelay48k;  // 63, the linear-phase center tap.
  for (int n = 0; n < kFilterTaps; ++n) {
    const float x = static_cast<float>(n - m) / kResampleFactor;
    const double phase =
        2.0 * kPi * static_cast<double>(n) / (kFilterTaps - 1);
    const float window = static_cast<float>(
        0.42 - 0.5 * std::cos(phase) + 0.08 * std::cos(2.0 * phase));
    coeffs_[n] = sinc(x) * window;
  }
  reset();
}

void Resampler3x::reset() {
  std::memset(upHistory_, 0, sizeof(upHistory_));
  std::memset(downHistory_, 0, sizeof(downHistory_));
}

float Resampler3x::filterDcGain() const {
  float sum = 0.f;
  for (int n = 0; n < kFilterTaps; ++n) sum += coeffs_[n];
  return sum;
}

void Resampler3x::upsample(const float* in, float* out) {
  // Working buffer: history + current frame, so stream sample k sits at
  // work[k + kUpHistory]. Output m draws on input samples
  // k = (m - j) / 3 for every tap j congruent to m (mod 3).
  float work[kUpHistory + kSamplesPerBand];
  std::memcpy(work, upHistory_, sizeof(upHistory_));
  std::memcpy(work + kUpHistory, in,
              kSamplesPerBand * sizeof(float));

  for (int m = 0; m < kRnnoiseFrameSize; ++m) {
    float acc = 0.f;
    // Smallest tap index j with j = m (mod 3); step by 3 from there.
    for (int j = m % kResampleFactor; j < kFilterTaps;
         j += kResampleFactor) {
      const int k = (m - j) / kResampleFactor;
      acc += coeffs_[j] * work[k + kUpHistory];
    }
    out[m] = acc;
  }

  // Keep the last kUpHistory input samples for the next frame.
  std::memcpy(upHistory_, in + kSamplesPerBand - kUpHistory,
              sizeof(upHistory_));
}

void Resampler3x::downsample(const float* in, float* out) {
  // Working buffer: history + current frame, so stream sample n sits at
  // work[n + kDownHistory]. Output k is the filtered signal sampled at
  // 48 kHz index 3k (filter group delay 63 => the value represents
  // input time 3k - 63, a constant 1.3125 ms delay), scaled by 1/3
  // because the shared table has DC gain ~3.
  float work[kDownHistory + kRnnoiseFrameSize];
  std::memcpy(work, downHistory_, sizeof(downHistory_));
  std::memcpy(work + kDownHistory, in,
              kRnnoiseFrameSize * sizeof(float));

  for (int k = 0; k < kSamplesPerBand; ++k) {
    float acc = 0.f;
    const int center = kResampleFactor * k + kDownHistory;
    for (int j = 0; j < kFilterTaps; ++j) {
      acc += coeffs_[j] * work[center - j];
    }
    out[k] = acc / kResampleFactor;
  }

  // Keep the last kDownHistory input samples for the next frame.
  std::memcpy(downHistory_, in + kRnnoiseFrameSize - kDownHistory,
              sizeof(downHistory_));
}

RnnoiseBridge::RnnoiseBridge() = default;

RnnoiseBridge::~RnnoiseBridge() { release(); }

bool RnnoiseBridge::init(int sampleRateHz, int numChannels) {
  std::lock_guard<std::mutex> lock(mutex_);
  releaseLocked();
  if (numChannels != 1) {
    lastError_ = kBridgeUnsupportedChannels;
    return false;
  }
  // The APM's native processing rates (see WebRTC
  // audio_processing_impl.cc SuitableProcessRate: always one of
  // 16000, 32000, 48000 Hz). Anything else is unexpected — fail open.
  if (sampleRateHz != 16000 && sampleRateHz != 32000 &&
      sampleRateHz != 48000) {
    lastError_ = kBridgeBadFrameSize;
    return false;
  }
  if (rnnoise_get_frame_size() != kRnnoiseFrameSize) {
    // The vendored RNNoise disagrees with our framing — never run.
    lastError_ = kBridgeBadFrameSize;
    return false;
  }
  for (int b = 0; b < kMaxBands; ++b) {
    states_[b] = rnnoise_create(nullptr);  // default model
    if (states_[b] == nullptr) {
      lastError_ = kBridgeRnnoiseAllocFailed;
      releaseLocked();
      return false;
    }
    resamplers_[b].reset();
  }
  sampleRateHz_ = sampleRateHz;
  initialized_ = true;
  lastError_ = kBridgeOk;
  return true;
}

void RnnoiseBridge::process(float* bands, int numBands, int numFrames) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!initialized_ || bypass_ || bands == nullptr) return;
  if (numBands < 1 || numBands > kMaxBands) {
    lastError_ = kBridgeBadBandCount;
    return;
  }
  if (numFrames != kSamplesPerBand) {
    lastError_ = kBridgeBadFrameSize;
    return;
  }
  for (int b = 0; b < numBands; ++b) {
    float* band = bands + b * numFrames;
    if (states_[b] == nullptr) continue;  // defensive; init creates all
    // 16 kHz band -> 48 kHz -> RNNoise -> 16 kHz band, in place.
    resamplers_[b].upsample(band, tmp48_);
    const float vad =
        rnnoise_process_frame(states_[b], tmp48Out_, tmp48_);
    if (b == 0) lastVoiceProb_ = vad;
    resamplers_[b].downsample(tmp48Out_, band);
  }
  ++framesProcessed_;
  lastError_ = kBridgeOk;
}

void RnnoiseBridge::setBypass(bool bypass) {
  std::lock_guard<std::mutex> lock(mutex_);
  bypass_ = bypass;
}

bool RnnoiseBridge::isBypassed() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return bypass_;
}

void RnnoiseBridge::release() {
  std::lock_guard<std::mutex> lock(mutex_);
  releaseLocked();
}

void RnnoiseBridge::releaseLocked() {
  for (int b = 0; b < kMaxBands; ++b) {
    if (states_[b] != nullptr) {
      rnnoise_destroy(states_[b]);
      states_[b] = nullptr;
    }
    resamplers_[b].reset();
  }
  initialized_ = false;
  sampleRateHz_ = 0;
}

bool RnnoiseBridge::isInitialized() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return initialized_;
}

int64_t RnnoiseBridge::framesProcessed() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return framesProcessed_;
}

int RnnoiseBridge::lastError() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return lastError_;
}

float RnnoiseBridge::lastVoiceProb() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return lastVoiceProb_;
}

}  // namespace arena_rnnoise
