// GROUP 7 DSP — AUDIO #10: mic bridge implementation (RJ Studio evolution).
// See dsp_mic_bridge.h for the design: full-band full-chain when
// numBands == 1, per-band full-chain (EQ on band 0 only) when split.

#include "dsp_mic_bridge.h"

#include <algorithm>
#include <cmath>
#include <cstring>

namespace arena_dsp {

namespace {

// Real float32 audio from the APM lives in [-1, 1]; 4.0 leaves generous
// headroom for any AGC overshoot while still catching int16-as-float
// garbage, which is typically orders of magnitude larger (or NaN).
constexpr float kFloatPlausibleMax = 4.0f;
// A sample is "plausible speech" when it is clearly above the noise
// floor of any real float buffer but within range.
constexpr float kFloatPlausibleMin = 1e-6f;
// Anything non-zero below this is a denormal — real audio never goes
// there (even -90 dBFS room noise is ~3e-5); int16 bytes misread as
// float land here constantly.
constexpr float kFloatDenormalMax = 1e-30f;

int16_t floatToPcm16(float v) {
    if (std::isnan(v)) {
        return 0;
    }
    float clamped = std::max(-1.0f, std::min(1.0f, v));
    return static_cast<int16_t>(clamped * 32767.0f);
}

float pcm16ToFloat(int16_t v) {
    return static_cast<float>(v) / 32768.0f;
}

constexpr double kPiDouble = 3.14159265358979323846;

// Soft limiter for the soundboard mix (same tanh knee as Dart's
// Soundboard.mixInto: identity below +/-0.9, asymptotically +/-1.0
// above). The mix runs AFTER the engine, so the engine's own limiter
// cannot protect the summed mic+clip signal.
float softLimit(float x) {
    constexpr float kThreshold = 0.9f;
    constexpr float kHeadroom = 0.1f;
    if (x > kThreshold) {
        return kThreshold +
               kHeadroom * std::tanh((x - kThreshold) / kHeadroom);
    }
    if (x < -kThreshold) {
        return -kThreshold -
               kHeadroom * std::tanh((-x - kThreshold) / kHeadroom);
    }
    return x;
}

// Anti-alias FIR for the 3:1 clip decimation (48 kHz -> 16 kHz).
// 31-tap Blackman-windowed sinc, cutoff 7.2 kHz (0.15 cycles/sample),
// designed at load time (no magic tables). The decimation runs ONCE
// per clip load, so a sharp filter costs nothing at mix time.
// Output sample i is the filtered value at input sample 3*i
// (zero-padded edges), so the decimated clip stays time-aligned with
// the original: decimated[i] is original[3*i] in time.
std::vector<float> decimate48kTo16k(const float* input, size_t length) {
    constexpr int kTaps = 31;
    constexpr int kHalf = kTaps / 2;  // 15
    constexpr double kCutoff = 0.15;  // 7.2 kHz at a 48 kHz rate
    float taps[kTaps];
    double sum = 0.0;
    for (int n = 0; n < kTaps; ++n) {
        const double m = static_cast<double>(n - kHalf);
        // Ideal low-pass: h[m] = sin(2*pi*fc*m) / (pi*m), 2*fc at 0.
        double sinc;
        if (m == 0.0) {
            sinc = 2.0 * kCutoff;
        } else {
            sinc = std::sin(2.0 * kPiDouble * kCutoff * m) /
                   (kPiDouble * m);
        }
        // Blackman window.
        const double w =
            0.42 -
            0.5 * std::cos(2.0 * kPiDouble * n / (kTaps - 1)) +
            0.08 * std::cos(4.0 * kPiDouble * n / (kTaps - 1));
        taps[n] = static_cast<float>(sinc * w);
        sum += taps[n];
    }
    // Normalize to unity DC gain.
    for (int n = 0; n < kTaps; ++n) {
        taps[n] = static_cast<float>(taps[n] / sum);
    }
    const size_t outLength = (length + 2) / 3;  // ceil(length / 3)
    std::vector<float> out(outLength, 0.0f);
    for (size_t i = 0; i < outLength; ++i) {
        const size_t center = i * 3;
        double acc = 0.0;
        for (int t = 0; t < kTaps; ++t) {
            const long idx =
                static_cast<long>(center) + (t - kHalf);
            const float s = (idx < 0 || idx >= static_cast<long>(length))
                                ? 0.0f
                                : input[idx];
            acc += static_cast<double>(taps[t]) * s;
        }
        out[i] = static_cast<float>(acc);
    }
    return out;
}

}  // namespace

DspMicBridge::~DspMicBridge() {
    release();
}

bool DspMicBridge::init(int sampleRateHz, int numChannels) {
    release();
    if (numChannels != 1) {
        lastError_ = kDspMicUnsupportedChannels;
        return false;
    }
    if (sampleRateHz != 16000 && sampleRateHz != 32000 &&
        sampleRateHz != 48000) {
        lastError_ = kDspMicBadFrameSize;
        return false;
    }
    sampleRateHz_ = sampleRateHz;
    // One engine per band. Engine 0 starts at the full capture rate
    // (right for numBands == 1; reconfigured to 16 kHz on the first
    // split frame by ensureEngineRates). Engines 1-2 only ever run
    // split bands, so they are 16 kHz from birth.
    engines_[0] = new DspEngine(sampleRateHz, 1);
    engines_[1] = new DspEngine(16000, 1);
    engines_[2] = new DspEngine(16000, 1);
    engineRate_ = sampleRateHz;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        paramsDirty_ = true;  // apply the mic preset on the first frame
    }
    formatConfirmed_ = false;
    formatBad_ = false;
    lastFormatBytes_ = 0;
    framesProcessed_ = 0;
    lastError_ = kDspMicOk;
    return true;
}

void DspMicBridge::release() {
    for (int b = 0; b < kMaxBands; ++b) {
        if (engines_[b] != nullptr) {
            delete engines_[b];
            engines_[b] = nullptr;
        }
    }
    engineRate_ = 0;
    // Soundboard: drop the clip and stop any playback. Safe to touch
    // the audio-thread flags here: Kotlin removes the processor from
    // capturePostProcessing BEFORE calling nativeRelease, so no frame
    // is in flight (the same contract the engine deletion relies on).
    {
        std::lock_guard<std::mutex> lock(mutex_);
        clipData_.reset();
        clipPlayRequested_ = false;
        clipStopRequested_ = false;
        clipGainPending_ = false;
    }
    clipActive_.reset();
    clipPlayhead48k_ = 0;
    clipGain_ = 0.0f;
    clipActiveFlag_ = false;
}

bool DspMicBridge::processBuffer(uint8_t* data, size_t capacityBytes,
                                 int numBands, int numFrames) {
    if (!isInitialized()) {
        lastError_ = kDspMicNotInitialized;
        return false;
    }
    if (numBands < 1 || numBands > kMaxBands) {
        lastError_ = kDspMicBadBandCount;
        return false;
    }
    if (numFrames < 1 || numFrames > kMaxFrames) {
        lastError_ = kDspMicBadFrameSize;
        return false;
    }
    if (data == nullptr) {
        lastError_ = kDspMicBadBuffer;
        return false;
    }
    // Capacity chooses the layout. Float first: it is the primary
    // contract (G2 + Krisp). An exactly-sized int16 buffer is smaller
    // than the float size, so it falls through to the int16 path; a
    // buffer too small for either fails open. The float sanity check
    // inside processFloat() is the backstop for an int16 buffer that
    // happens to be allocated with float-sized capacity.
    const size_t floatBytes =
        static_cast<size_t>(numBands) * static_cast<size_t>(numFrames) * 4;
    const size_t pcm16Bytes =
        static_cast<size_t>(numBands) * static_cast<size_t>(numFrames) * 2;
    if (capacityBytes >= floatBytes) {
        lastFormatBytes_ = 4;
        return processFloat(reinterpret_cast<float*>(data), numBands,
                            numFrames);
    }
    if (capacityBytes >= pcm16Bytes) {
        lastFormatBytes_ = 2;
        return processPcm16(data, numBands, numFrames);
    }
    lastError_ = kDspMicBadBuffer;
    return false;
}

bool DspMicBridge::processFloat(float* bands, int numBands, int numFrames) {
    if (!isInitialized()) {
        lastError_ = kDspMicNotInitialized;
        return false;
    }
    if (bands == nullptr) {
        lastError_ = kDspMicBadBuffer;
        return false;
    }
    if (numBands < 1 || numBands > kMaxBands) {
        lastError_ = kDspMicBadBandCount;
        return false;
    }
    if (numFrames < 1 || numFrames > kMaxFrames) {
        lastError_ = kDspMicBadFrameSize;
        return false;
    }
    if (bypass_) {
        return true;  // pass through, not counted (G2 convention)
    }
    if (formatBad_) {
        lastError_ = kDspMicBadFormat;
        return false;
    }
    // Band 0 is the first numFrames floats (planar, band-major).
    float* band0 = bands;
    if (!checkFloatSanity(band0, numFrames)) {
        lastError_ = kDspMicBadFormat;
        return false;  // touch nothing
    }
    ensureEngineRates(numBands);
    applyPendingParams();
    if (static_cast<int>(pcm16Scratch_.size()) < numFrames) {
        pcm16Scratch_.resize(static_cast<size_t>(numFrames));
    }
    // Per band: float -> int16 -> that band's engine (full chain) ->
    // int16 -> float. numBands == 1 is the full-band case: engine 0
    // runs the whole chain on the whole frame. The scratch buffer is
    // reused band by band (processing is sequential, never parallel).
    uint8_t* pcmBytes =
        reinterpret_cast<uint8_t*>(pcm16Scratch_.data());
    for (int b = 0; b < numBands; ++b) {
        if (bandBypass_[b]) continue;  // bit-identical, no round-trip
        float* band = bands + static_cast<size_t>(b) * numFrames;
        for (int i = 0; i < numFrames; ++i) {
            pcm16Scratch_[static_cast<size_t>(i)] = floatToPcm16(band[i]);
        }
        engines_[b]->processPcm16(pcmBytes, pcmBytes,
                                  static_cast<size_t>(numFrames) * 2);
        for (int i = 0; i < numFrames; ++i) {
            band[i] = pcm16ToFloat(pcm16Scratch_[static_cast<size_t>(i)]);
        }
    }
    // SOUNDBOARD (route A): mix the active clip into band 0 AFTER the
    // DSP chain (the SFX stays dry). No-op when idle.
    mixClipIntoBand0Float(band0, numFrames, band0RateFor(numBands));
    framesProcessed_++;
    return true;
}

bool DspMicBridge::processPcm16(uint8_t* bytes, int numBands,
                                int numFrames) {
    if (!isInitialized()) {
        lastError_ = kDspMicNotInitialized;
        return false;
    }
    if (bytes == nullptr) {
        lastError_ = kDspMicBadBuffer;
        return false;
    }
    if (numBands < 1 || numBands > kMaxBands) {
        lastError_ = kDspMicBadBandCount;
        return false;
    }
    if (numFrames < 1 || numFrames > kMaxFrames) {
        lastError_ = kDspMicBadFrameSize;
        return false;
    }
    if (bypass_) {
        return true;  // pass through, not counted (G2 convention)
    }
    ensureEngineRates(numBands);
    applyPendingParams();
    // Band b is the slice [b*numFrames*2, (b+1)*numFrames*2). Each band
    // runs through its own engine, in place — processPcm16() is safe
    // in place (it decodes into the engine's scratch float buffer
    // first and only writes the output afterwards).
    for (int b = 0; b < numBands; ++b) {
        if (bandBypass_[b]) continue;  // bit-identical, no engine call
        uint8_t* bandBytes =
            bytes + static_cast<size_t>(b) * numFrames * 2;
        engines_[b]->processPcm16(bandBytes, bandBytes,
                                  static_cast<size_t>(numFrames) * 2);
    }
    // SOUNDBOARD (route A): mix the active clip into band 0 AFTER the
    // DSP chain. Band 0 starts at `bytes`. No-op when idle.
    mixClipIntoBand0Pcm16(bytes, numFrames, band0RateFor(numBands));
    framesProcessed_++;
    return true;
}

void DspMicBridge::setEq(bool enabled, float bassBoostDb, float lowGainDb,
                         float midGainDb, float highGainDb) {
    std::lock_guard<std::mutex> lock(mutex_);
    eqEnabled_ = enabled;
    eqBassDb_ = bassBoostDb;
    eqLowDb_ = lowGainDb;
    eqMidDb_ = midGainDb;
    eqHighDb_ = highGainDb;
    paramsDirty_ = true;
}

void DspMicBridge::setEcho(bool enabled, float delayMs, float feedback,
                           float mix) {
    std::lock_guard<std::mutex> lock(mutex_);
    echoEnabled_ = enabled;
    echoDelayMs_ = delayMs;
    echoFeedback_ = feedback;
    echoMix_ = mix;
    paramsDirty_ = true;
}

void DspMicBridge::setReverb(bool enabled, float wetDryMix, float roomSize,
                             float damping) {
    std::lock_guard<std::mutex> lock(mutex_);
    reverbEnabled_ = enabled;
    reverbMix_ = wetDryMix;
    reverbRoom_ = roomSize;
    reverbDamping_ = damping;
    paramsDirty_ = true;
}

void DspMicBridge::setNoiseGate(bool enabled, float thresholdDb,
                                float attackMs, float releaseMs) {
    std::lock_guard<std::mutex> lock(mutex_);
    gateEnabled_ = enabled;
    gateThresholdDb_ = thresholdDb;
    gateAttackMs_ = attackMs;
    gateReleaseMs_ = releaseMs;
    paramsDirty_ = true;
}

void DspMicBridge::setCompressor(bool enabled, float thresholdDb,
                                 float ratio, float attackMs,
                                 float releaseMs, float makeupGainDb) {
    std::lock_guard<std::mutex> lock(mutex_);
    compEnabled_ = enabled;
    compThresholdDb_ = thresholdDb;
    compRatio_ = ratio;
    compAttackMs_ = attackMs;
    compReleaseMs_ = releaseMs;
    compMakeupDb_ = makeupGainDb;
    paramsDirty_ = true;
}

void DspMicBridge::setBypass(bool bypass) {
    std::lock_guard<std::mutex> lock(mutex_);
    bypass_ = bypass;
}

// ---- Soundboard clip (route A) -----------------------------------------

bool DspMicBridge::loadClip(const float* samples48k, size_t numSamples,
                            int sampleRateHz) {
    if (samples48k == nullptr || numSamples == 0) {
        return false;
    }
    if (sampleRateHz != 48000) {
        // The Dart decoder always outputs 48 kHz; anything else is a
        // caller bug (the decimation below assumes 3:1).
        return false;
    }
    auto data = std::make_shared<ClipData>();
    data->samples48k.assign(samples48k, samples48k + numSamples);
    data->samples16k = decimate48kTo16k(samples48k, numSamples);
    if (data->samples16k.empty()) {
        return false;  // cannot happen (ceil division), defensive
    }
    std::lock_guard<std::mutex> lock(mutex_);
    clipData_ = std::move(data);
    // A load implicitly stops any playing clip and cancels a pending
    // play: a load is a setup operation, never a play trigger.
    clipStopRequested_ = true;
    clipPlayRequested_ = false;
    return true;
}

void DspMicBridge::playClip(float gain) {
    std::lock_guard<std::mutex> lock(mutex_);
    clipPendingGain_ = std::max(0.0f, std::min(1.0f, gain));
    clipPlayRequested_ = true;
    clipStopRequested_ = false;  // a play cancels a pending stop
}

void DspMicBridge::stopClip() {
    std::lock_guard<std::mutex> lock(mutex_);
    clipStopRequested_ = true;
    clipPlayRequested_ = false;  // a stop cancels a pending play
}

void DspMicBridge::setClipGain(float gain) {
    std::lock_guard<std::mutex> lock(mutex_);
    clipPendingGain_ = std::max(0.0f, std::min(1.0f, gain));
    clipGainPending_ = true;
}

size_t DspMicBridge::clipLength16k() {
    std::lock_guard<std::mutex> lock(mutex_);
    return clipData_ == nullptr ? 0 : clipData_->samples16k.size();
}

void DspMicBridge::applyPendingClipRequests() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (clipStopRequested_) {
        clipStopRequested_ = false;
        finishClip();
    }
    if (clipPlayRequested_) {
        clipPlayRequested_ = false;
        if (clipData_ != nullptr && !clipData_->samples48k.empty()) {
            clipActive_ = clipData_;  // snapshot under the lock
            clipPlayhead48k_ = 0;
            clipGain_ = clipPendingGain_;
            clipActiveFlag_ = true;
        }
        // No clip loaded: the play request is dropped (Dart only
        // sends play for available pads, so this is a no-op in
        // practice — never start mixing without a clip).
    }
    if (clipGainPending_) {
        clipGainPending_ = false;
        clipGain_ = clipPendingGain_;
    }
}

bool DspMicBridge::clipMixWindow(int band0RateHz, int numFrames,
                                 const std::vector<float>** clipOut,
                                 size_t* posOut, size_t* mixCountOut,
                                 int* rateRatioOut) {
    applyPendingClipRequests();
    if (!clipActiveFlag_ || clipActive_ == nullptr) {
        return false;
    }
    const std::vector<float>* clip = nullptr;
    int rateRatio = 0;
    if (band0RateHz == 16000) {
        clip = &clipActive_->samples16k;
        rateRatio = 3;
    } else if (band0RateHz == 48000) {
        clip = &clipActive_->samples48k;
        rateRatio = 1;
    } else {
        // 1-band 32 kHz (synthetic only): no variant — mix nothing
        // and do NOT advance the playhead this frame.
        return false;
    }
    const size_t clipLen = clip->size();
    // The playhead is kept in 48k-sample units so a layout change
    // mid-play keeps the TIME position (16000-variant position =
    // playhead / 3).
    const size_t pos =
        clipPlayhead48k_ / static_cast<size_t>(rateRatio);
    if (pos >= clipLen) {
        finishClip();
        return false;
    }
    const size_t remaining = clipLen - pos;
    const size_t mixCount =
        remaining < static_cast<size_t>(numFrames)
            ? remaining
            : static_cast<size_t>(numFrames);
    *clipOut = clip;
    *posOut = pos;
    *mixCountOut = mixCount;
    *rateRatioOut = rateRatio;
    return true;
}

void DspMicBridge::advanceClipPlayhead(size_t pos, size_t mixCount,
                                       size_t clipLen, int rateRatio) {
    clipPlayhead48k_ += mixCount * static_cast<size_t>(rateRatio);
    if (pos + mixCount >= clipLen) {
        finishClip();
    }
}

void DspMicBridge::mixClipIntoBand0Float(float* band0, int numFrames,
                                         int band0RateHz) {
    const std::vector<float>* clip = nullptr;
    size_t pos = 0;
    size_t mixCount = 0;
    int rateRatio = 0;
    if (!clipMixWindow(band0RateHz, numFrames, &clip, &pos, &mixCount,
                       &rateRatio)) {
        return;
    }
    const float gain = clipGain_;
    if (gain > 0.0f) {
        for (size_t i = 0; i < mixCount; ++i) {
            band0[i] = softLimit(band0[i] + (*clip)[pos + i] * gain);
        }
    }
    // Gain 0 still advances (the clip finishes on time while the mic
    // stays bit-identical — same contract as Dart's mixInto).
    advanceClipPlayhead(pos, mixCount, clip->size(), rateRatio);
}

void DspMicBridge::mixClipIntoBand0Pcm16(uint8_t* band0Bytes, int numFrames,
                                         int band0RateHz) {
    const std::vector<float>* clip = nullptr;
    size_t pos = 0;
    size_t mixCount = 0;
    int rateRatio = 0;
    if (!clipMixWindow(band0RateHz, numFrames, &clip, &pos, &mixCount,
                       &rateRatio)) {
        return;
    }
    const float gain = clipGain_;
    if (gain > 0.0f) {
        for (size_t i = 0; i < mixCount; ++i) {
            const size_t off = i * 2;
            const int16_t mic = static_cast<int16_t>(
                band0Bytes[off] | (band0Bytes[off + 1] << 8));
            const float mixed = softLimit(pcm16ToFloat(mic) +
                                          (*clip)[pos + i] * gain);
            const int16_t out = floatToPcm16(mixed);
            band0Bytes[off] = static_cast<uint8_t>(out & 0xFF);
            band0Bytes[off + 1] = static_cast<uint8_t>((out >> 8) & 0xFF);
        }
    }
    advanceClipPlayhead(pos, mixCount, clip->size(), rateRatio);
}

void DspMicBridge::ensureEngineRates(int numBands) {
    // Split-band: band 0 is 0-8 kHz at an effective 16 kHz. Not split:
    // band 0 spans the full capture rate.
    const int bandRate = (numBands > 1) ? 16000 : sampleRateHz_;
    if (bandRate != engineRate_) {
        engines_[0]->configure(bandRate, 1);
        engineRate_ = bandRate;
        // Reconfiguring resets the EQ state; re-apply the preset so
        // the gains survive the rate change.
        std::lock_guard<std::mutex> lock(mutex_);
        paramsDirty_ = true;
    }
    // Engines 1-2 are always 16 kHz (created that way in init) and
    // only run when split — nothing to reconfigure.
}

void DspMicBridge::applyPendingParams() {
    bool eqEnabled;
    float bass, low, mid, high;
    bool echoEnabled;
    float echoDelay, echoFeedback, echoMix;
    bool reverbEnabled;
    float reverbMix, reverbRoom, reverbDamping;
    bool gateEnabled;
    float gateThreshold, gateAttack, gateRelease;
    bool compEnabled;
    float compThreshold, compRatio, compAttack, compRelease, compMakeup;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!paramsDirty_) {
            return;
        }
        eqEnabled = eqEnabled_;
        bass = eqBassDb_;
        low = eqLowDb_;
        mid = eqMidDb_;
        high = eqHighDb_;
        echoEnabled = echoEnabled_;
        echoDelay = echoDelayMs_;
        echoFeedback = echoFeedback_;
        echoMix = echoMix_;
        reverbEnabled = reverbEnabled_;
        reverbMix = reverbMix_;
        reverbRoom = reverbRoom_;
        reverbDamping = reverbDamping_;
        gateEnabled = gateEnabled_;
        gateThreshold = gateThresholdDb_;
        gateAttack = gateAttackMs_;
        gateRelease = gateReleaseMs_;
        compEnabled = compEnabled_;
        compThreshold = compThresholdDb_;
        compRatio = compRatio_;
        compAttack = compAttackMs_;
        compRelease = compReleaseMs_;
        compMakeup = compMakeupDb_;
        paramsDirty_ = false;
    }
    // Per-band skip flags: a band whose every stage is disabled needs
    // no processing at all (see bandBypass_ in the header). Band 0's
    // EQ counts; bands 1-2 never have EQ.
    bandBypass_[0] = !gateEnabled && !compEnabled && !eqEnabled &&
                     !echoEnabled && !reverbEnabled;
    for (int b = 1; b < kMaxBands; ++b) {
        bandBypass_[b] =
            !gateEnabled && !compEnabled && !echoEnabled && !reverbEnabled;
    }
    // Gate/compressor/echo/reverb go to EVERY engine (same time
    // parameters in every band — that is what makes the per-band tails
    // sum to the full-band effect). EQ goes to engine 0 ONLY: its
    // coefficients are frequency-selective and would land at the wrong
    // frequencies in a decimated band (see the header design note).
    for (int b = 0; b < kMaxBands; ++b) {
        if (engines_[b] == nullptr) continue;
        engines_[b]->setNoiseGate(gateEnabled, gateThreshold, gateAttack,
                                  gateRelease);
        engines_[b]->setCompressor(compEnabled, compThreshold, compRatio,
                                   compAttack, compRelease, compMakeup);
        if (b == 0) {
            engines_[b]->setEq(eqEnabled, bass, low, mid, high);
        } else {
            engines_[b]->setEq(false, 0.0f, 0.0f, 0.0f, 0.0f);
        }
        engines_[b]->setEcho(echoEnabled, echoDelay, echoFeedback,
                             echoMix);
        engines_[b]->setReverb(reverbEnabled, reverbMix, reverbRoom,
                               reverbDamping);
    }
}

bool DspMicBridge::checkFloatSanity(const float* band0, int numFrames) {
    if (formatConfirmed_) {
        return true;
    }
    int plausible = 0;
    int denormals = 0;
    for (int i = 0; i < numFrames; ++i) {
        const float v = band0[i];
        uint32_t bits;
        std::memcpy(&bits, &v, sizeof(bits));
        if (std::isnan(v) || std::fabs(v) > kFloatPlausibleMax) {
            // int16 bytes misread as float: huge exponents / NaN.
            formatBad_ = true;
            return false;
        }
        const float av = std::fabs(v);
        if (av >= kFloatPlausibleMin) {
            ++plausible;
        } else if (bits != 0 && av < kFloatDenormalMax) {
            // Non-zero bits but ~1e-41: a denormal — int16 bytes
            // misread as float. Real audio never goes here.
            ++denormals;
        }
        // Exact 0.0 (silence) and tiny-but-plausible values are
        // inconclusive: keep waiting.
    }
    // Denormals dominating the frame means int16 bytes misread as
    // float (a genuine float frame has ~zero denormals — even -90 dBFS
    // room noise is ~3e-5). A lone denormal among real speech does
    // NOT fail the check (it could be a decaying filter tail).
    if (denormals > 0 && denormals > plausible) {
        formatBad_ = true;
        return false;
    }
    if (plausible > 0) {
        formatConfirmed_ = true;  // locked in for the session
    }
    return true;
}

}  // namespace arena_dsp
