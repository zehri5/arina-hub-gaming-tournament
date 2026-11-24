#include "dsp_engine.h"

#include <algorithm>
#include <cmath>
#include <cstring>

namespace arena_dsp {

namespace {

constexpr double kPi = 3.14159265358979323846;
constexpr float kDenormalThreshold = 1e-18f;

inline float clampFloat(float v, float lo, float hi) {
    return std::max(lo, std::min(hi, v));
}

inline float flushDenormal(float v) {
    return (std::fabs(v) < kDenormalThreshold) ? 0.0f : v;
}

inline float timeMsToCoeff(float timeMs, int sampleRate) {
    const float samples = std::max(1.0f, (timeMs * 0.001f) * static_cast<float>(sampleRate));
    return std::exp(-1.0f / samples);
}

inline float softLimit(float x) {
    constexpr float kThreshold = 0.9f;
    const float absX = std::fabs(x);
    if (absX <= kThreshold) {
        return x;
    }
    const float excess = absX - kThreshold;
    const float headroom = 1.0f - kThreshold;
    const float compressed = kThreshold + headroom * std::tanh(excess / headroom);
    return (x >= 0.0f) ? compressed : -compressed;
}

} // namespace

// -----------------------------------------------------------------------------
// BiquadFilter
// -----------------------------------------------------------------------------

void BiquadFilter::configure(Type type, int sampleRate, float freqHz, float qOrSlope, float gainDb) {
    if (std::fabs(gainDb) < 0.01f) {
        bypassed_ = true;
        b0_ = 1.0f;
        b1_ = 0.0f;
        b2_ = 0.0f;
        a1_ = 0.0f;
        a2_ = 0.0f;
        return;
    }

    bypassed_ = false;

    const double fs = static_cast<double>(std::max(8000, sampleRate));
    const double f0 = clampFloat(freqHz, 10.0f, static_cast<float>(fs * 0.45));
    const double aAmp = std::pow(10.0, static_cast<double>(gainDb) / 40.0);
    const double w0 = 2.0 * kPi * f0 / fs;
    const double cosW0 = std::cos(w0);
    const double sinW0 = std::sin(w0);

    double b0 = 1.0;
    double b1 = 0.0;
    double b2 = 0.0;
    double a0 = 1.0;
    double a1 = 0.0;
    double a2 = 0.0;

    if (type == Type::LowShelf) {
        const double s = std::max(0.1, static_cast<double>(qOrSlope));
        const double radicand = std::max(0.0, (aAmp + 1.0 / aAmp) * (1.0 / s - 1.0) + 2.0);
        const double alpha = (sinW0 * 0.5) * std::sqrt(radicand);
        const double twoSqrtAAlpha = 2.0 * std::sqrt(aAmp) * alpha;

        b0 = aAmp * ((aAmp + 1.0) - (aAmp - 1.0) * cosW0 + twoSqrtAAlpha);
        b1 = 2.0 * aAmp * ((aAmp - 1.0) - (aAmp + 1.0) * cosW0);
        b2 = aAmp * ((aAmp + 1.0) - (aAmp - 1.0) * cosW0 - twoSqrtAAlpha);
        a0 = (aAmp + 1.0) + (aAmp - 1.0) * cosW0 + twoSqrtAAlpha;
        a1 = -2.0 * ((aAmp - 1.0) + (aAmp + 1.0) * cosW0);
        a2 = (aAmp + 1.0) + (aAmp - 1.0) * cosW0 - twoSqrtAAlpha;
    } else if (type == Type::HighShelf) {
        const double s = std::max(0.1, static_cast<double>(qOrSlope));
        const double radicand = std::max(0.0, (aAmp + 1.0 / aAmp) * (1.0 / s - 1.0) + 2.0);
        const double alpha = (sinW0 * 0.5) * std::sqrt(radicand);
        const double twoSqrtAAlpha = 2.0 * std::sqrt(aAmp) * alpha;

        b0 = aAmp * ((aAmp + 1.0) + (aAmp - 1.0) * cosW0 + twoSqrtAAlpha);
        b1 = -2.0 * aAmp * ((aAmp - 1.0) + (aAmp + 1.0) * cosW0);
        b2 = aAmp * ((aAmp + 1.0) + (aAmp - 1.0) * cosW0 - twoSqrtAAlpha);
        a0 = (aAmp + 1.0) - (aAmp - 1.0) * cosW0 + twoSqrtAAlpha;
        a1 = 2.0 * ((aAmp - 1.0) - (aAmp + 1.0) * cosW0);
        a2 = (aAmp + 1.0) - (aAmp - 1.0) * cosW0 - twoSqrtAAlpha;
    } else {
        const double q = std::max(0.1, static_cast<double>(qOrSlope));
        const double alpha = sinW0 / (2.0 * q);

        b0 = 1.0 + alpha * aAmp;
        b1 = -2.0 * cosW0;
        b2 = 1.0 - alpha * aAmp;
        a0 = 1.0 + alpha / aAmp;
        a1 = -2.0 * cosW0;
        a2 = 1.0 - alpha / aAmp;
    }

    const double invA0 = 1.0 / a0;
    b0_ = static_cast<float>(b0 * invA0);
    b1_ = static_cast<float>(b1 * invA0);
    b2_ = static_cast<float>(b2 * invA0);
    a1_ = static_cast<float>(a1 * invA0);
    a2_ = static_cast<float>(a2 * invA0);
}

void BiquadFilter::reset() {
    z1_[0] = 0.0f;
    z1_[1] = 0.0f;
    z2_[0] = 0.0f;
    z2_[1] = 0.0f;
}

float BiquadFilter::processSample(int channel, float x) {
    if (bypassed_) {
        return x;
    }
    const float y = b0_ * x + z1_[channel];
    z1_[channel] = flushDenormal(b1_ * x - a1_ * y + z2_[channel]);
    z2_[channel] = flushDenormal(b2_ * x - a2_ * y);
    return y;
}

// -----------------------------------------------------------------------------
// CombFilter
// -----------------------------------------------------------------------------

void CombFilter::resize(size_t size) {
    buffer_.assign(std::max<size_t>(1, size), 0.0f);
    index_ = 0;
    filterStore_ = 0.0f;
}

void CombFilter::reset() {
    std::fill(buffer_.begin(), buffer_.end(), 0.0f);
    index_ = 0;
    filterStore_ = 0.0f;
}

void CombFilter::setFeedback(float feedback) {
    feedback_ = feedback;
}

void CombFilter::setDamping(float damping) {
    damp1_ = damping;
    damp2_ = 1.0f - damping;
}

float CombFilter::process(float input) {
    const float output = flushDenormal(buffer_[index_]);
    filterStore_ = flushDenormal((output * damp2_) + (filterStore_ * damp1_));
    buffer_[index_] = input + (filterStore_ * feedback_);
    if (++index_ >= buffer_.size()) {
        index_ = 0;
    }
    return output;
}

// -----------------------------------------------------------------------------
// AllpassFilter
// -----------------------------------------------------------------------------

void AllpassFilter::resize(size_t size) {
    buffer_.assign(std::max<size_t>(1, size), 0.0f);
    index_ = 0;
}

void AllpassFilter::reset() {
    std::fill(buffer_.begin(), buffer_.end(), 0.0f);
    index_ = 0;
}

void AllpassFilter::setFeedback(float feedback) {
    feedback_ = feedback;
}

float AllpassFilter::process(float input) {
    const float bufOut = flushDenormal(buffer_[index_]);
    const float output = bufOut - feedback_ * input;
    buffer_[index_] = flushDenormal(input + feedback_ * output);
    if (++index_ >= buffer_.size()) {
        index_ = 0;
    }
    return output;
}

// -----------------------------------------------------------------------------
// NoiseGateProcessor
// -----------------------------------------------------------------------------

void NoiseGateProcessor::configure(int sampleRate) {
    sampleRate_ = std::max(8000, sampleRate);
    detAttackCoeff_ = timeMsToCoeff(0.5f, sampleRate_);
    detReleaseCoeff_ = timeMsToCoeff(30.0f, sampleRate_);
    updateCoefficients();
    reset();
}

void NoiseGateProcessor::reset() {
    detectorEnv_ = 0.0f;
    gain_ = 0.0f;
    gateOpen_ = false;
}

void NoiseGateProcessor::setParams(bool enabled, float thresholdDb, float attackMs, float releaseMs) {
    enabled_ = enabled;
    // Non-finite inputs must NOT reach clampFloat: std::min/std::max
    // silently map NaN to the upper bound, which would pin the threshold
    // at 0 dB (mic muted) and the times at their maxima. A bad value
    // keeps the previous setting instead (on a fresh processor that is
    // the -40 dB / 5 ms / 120 ms default).
    if (std::isfinite(thresholdDb)) {
        thresholdDb_ = clampFloat(thresholdDb, -90.0f, 0.0f);
    }
    if (std::isfinite(attackMs)) {
        attackMs_ = clampFloat(attackMs, 0.1f, 500.0f);
    }
    if (std::isfinite(releaseMs)) {
        releaseMs_ = clampFloat(releaseMs, 5.0f, 2000.0f);
    }
    updateCoefficients();
}

void NoiseGateProcessor::updateCoefficients() {
    constexpr float kHysteresisFactor = 0.70794578f; // -3 dB hysteresis
    openThreshold_ = std::pow(10.0f, thresholdDb_ / 20.0f);
    closeThreshold_ = openThreshold_ * kHysteresisFactor;
    attackCoeff_ = timeMsToCoeff(attackMs_, sampleRate_);
    releaseCoeff_ = timeMsToCoeff(releaseMs_, sampleRate_);
}

void NoiseGateProcessor::process(float* interleaved, size_t frames, int channels) {
    if (!enabled_) {
        return;
    }

    if (channels == 1) {
        for (size_t i = 0; i < frames; ++i) {
            const float level = std::fabs(interleaved[i]);
            if (level > detectorEnv_) {
                detectorEnv_ = detAttackCoeff_ * detectorEnv_ + (1.0f - detAttackCoeff_) * level;
            } else {
                detectorEnv_ = detReleaseCoeff_ * detectorEnv_ + (1.0f - detReleaseCoeff_) * level;
            }
            detectorEnv_ = flushDenormal(detectorEnv_);

            if (gateOpen_) {
                if (detectorEnv_ < closeThreshold_) {
                    gateOpen_ = false;
                }
            } else {
                if (detectorEnv_ >= openThreshold_) {
                    gateOpen_ = true;
                }
            }

            const float targetGain = gateOpen_ ? 1.0f : 0.0f;
            if (targetGain > gain_) {
                gain_ = attackCoeff_ * gain_ + (1.0f - attackCoeff_) * targetGain;
            } else {
                gain_ = releaseCoeff_ * gain_ + (1.0f - releaseCoeff_) * targetGain;
            }
            gain_ = flushDenormal(gain_);

            interleaved[i] *= gain_;
        }
    } else {
        for (size_t i = 0; i < frames; ++i) {
            const float absL = std::fabs(interleaved[i * 2]);
            const float absR = std::fabs(interleaved[i * 2 + 1]);
            const float level = std::max(absL, absR);

            if (level > detectorEnv_) {
                detectorEnv_ = detAttackCoeff_ * detectorEnv_ + (1.0f - detAttackCoeff_) * level;
            } else {
                detectorEnv_ = detReleaseCoeff_ * detectorEnv_ + (1.0f - detReleaseCoeff_) * level;
            }
            detectorEnv_ = flushDenormal(detectorEnv_);

            if (gateOpen_) {
                if (detectorEnv_ < closeThreshold_) {
                    gateOpen_ = false;
                }
            } else {
                if (detectorEnv_ >= openThreshold_) {
                    gateOpen_ = true;
                }
            }

            const float targetGain = gateOpen_ ? 1.0f : 0.0f;
            if (targetGain > gain_) {
                gain_ = attackCoeff_ * gain_ + (1.0f - attackCoeff_) * targetGain;
            } else {
                gain_ = releaseCoeff_ * gain_ + (1.0f - releaseCoeff_) * targetGain;
            }
            gain_ = flushDenormal(gain_);

            interleaved[i * 2] *= gain_;
            interleaved[i * 2 + 1] *= gain_;
        }
    }
}

// -----------------------------------------------------------------------------
// CompressorProcessor
// -----------------------------------------------------------------------------

void CompressorProcessor::configure(int sampleRate) {
    sampleRate_ = std::max(8000, sampleRate);
    updateCoefficients();
    reset();
}

void CompressorProcessor::reset() {
    envelopeDb_ = 0.0f;
}

void CompressorProcessor::setParams(
    bool enabled,
    float thresholdDb,
    float ratio,
    float attackMs,
    float releaseMs,
    float makeupGainDb) {
    enabled_ = enabled;
    // NaN guard (v3 adoption fix): clampFloat maps NaN to the HIGH end
    // (std::min/max with a NaN operand returns the bound), so a NaN
    // makeup gain would silently become +24 dB and a NaN ratio 20:1.
    // Non-finite params fall back to defaults BEFORE clamping.
    thresholdDb_ = clampFloat(std::isfinite(thresholdDb) ? thresholdDb : -18.0f, -60.0f, 0.0f);
    ratio_ = clampFloat(std::isfinite(ratio) ? ratio : 4.0f, 1.0f, 20.0f);
    attackMs_ = clampFloat(std::isfinite(attackMs) ? attackMs : 10.0f, 0.1f, 200.0f);
    releaseMs_ = clampFloat(std::isfinite(releaseMs) ? releaseMs : 100.0f, 5.0f, 2000.0f);
    makeupGainDb_ = clampFloat(std::isfinite(makeupGainDb) ? makeupGainDb : 0.0f, 0.0f, 24.0f);
    if (!enabled_) {
        // Don't resume with stale gain reduction: a frozen envelope would
        // duck the first ~300 ms after re-enable.
        envelopeDb_ = 0.0f;
    }
    updateCoefficients();
}

void CompressorProcessor::updateCoefficients() {
    attackCoeff_ = timeMsToCoeff(attackMs_, sampleRate_);
    releaseCoeff_ = timeMsToCoeff(releaseMs_, sampleRate_);
}

void CompressorProcessor::process(float* interleaved, size_t frames, int channels) {
    if (!enabled_) {
        return;
    }

    constexpr float kMinLinear = 1e-6f;       // -120 dBFS floor
    constexpr float kDbToLogScale = 0.11512925465f; // ln(10) / 20
    const float invRatio = 1.0f / ratio_;

    if (channels == 1) {
        for (size_t i = 0; i < frames; ++i) {
            const float level = std::max(std::fabs(interleaved[i]), kMinLinear);
            const float levelDb = 20.0f * std::log10(level);

            float desiredGainDb = 0.0f;
            if (levelDb > thresholdDb_) {
                const float overDb = levelDb - thresholdDb_;
                desiredGainDb = (overDb * invRatio) - overDb;
            }

            if (desiredGainDb < envelopeDb_) {
                envelopeDb_ = attackCoeff_ * envelopeDb_ + (1.0f - attackCoeff_) * desiredGainDb;
            } else {
                envelopeDb_ = releaseCoeff_ * envelopeDb_ + (1.0f - releaseCoeff_) * desiredGainDb;
            }
            envelopeDb_ = flushDenormal(envelopeDb_);

            const float totalGain = std::exp((envelopeDb_ + makeupGainDb_) * kDbToLogScale);
            interleaved[i] *= totalGain;
        }
    } else {
        for (size_t i = 0; i < frames; ++i) {
            const float absL = std::fabs(interleaved[i * 2]);
            const float absR = std::fabs(interleaved[i * 2 + 1]);
            const float level = std::max(std::max(absL, absR), kMinLinear);
            const float levelDb = 20.0f * std::log10(level);

            float desiredGainDb = 0.0f;
            if (levelDb > thresholdDb_) {
                const float overDb = levelDb - thresholdDb_;
                desiredGainDb = (overDb * invRatio) - overDb;
            }

            if (desiredGainDb < envelopeDb_) {
                envelopeDb_ = attackCoeff_ * envelopeDb_ + (1.0f - attackCoeff_) * desiredGainDb;
            } else {
                envelopeDb_ = releaseCoeff_ * envelopeDb_ + (1.0f - releaseCoeff_) * desiredGainDb;
            }
            envelopeDb_ = flushDenormal(envelopeDb_);

            const float totalGain = std::exp((envelopeDb_ + makeupGainDb_) * kDbToLogScale);
            interleaved[i * 2] *= totalGain;
            interleaved[i * 2 + 1] *= totalGain;
        }
    }
}

// -----------------------------------------------------------------------------
// FreeverbProcessor
// -----------------------------------------------------------------------------

void FreeverbProcessor::configure(int sampleRate) {
    sampleRate_ = std::max(8000, sampleRate);
    const double ratio = static_cast<double>(sampleRate_) / 44100.0;

    static constexpr int kCombTunings[kNumCombs] = {
        1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617
    };
    static constexpr int kAllpassTunings[kNumAllpasses] = {
        556, 441, 341, 225
    };

    const int stereoSpread = std::max(1, static_cast<int>(std::lround(23.0 * ratio)));

    for (int i = 0; i < kNumCombs; ++i) {
        const size_t sizeL = static_cast<size_t>(std::max(1, static_cast<int>(std::lround(kCombTunings[i] * ratio))));
        const size_t sizeR = sizeL + static_cast<size_t>(stereoSpread);
        combL_[i].resize(sizeL);
        combR_[i].resize(sizeR);
    }

    for (int i = 0; i < kNumAllpasses; ++i) {
        const size_t sizeL = static_cast<size_t>(std::max(1, static_cast<int>(std::lround(kAllpassTunings[i] * ratio))));
        const size_t sizeR = sizeL + static_cast<size_t>(stereoSpread);
        allpassL_[i].resize(sizeL);
        allpassR_[i].resize(sizeR);
        allpassL_[i].setFeedback(0.5f);
        allpassR_[i].setFeedback(0.5f);
    }

    updateInternalParams();
}

void FreeverbProcessor::reset() {
    for (int i = 0; i < kNumCombs; ++i) {
        combL_[i].reset();
        combR_[i].reset();
    }
    for (int i = 0; i < kNumAllpasses; ++i) {
        allpassL_[i].reset();
        allpassR_[i].reset();
    }
}

void FreeverbProcessor::setParams(bool enabled, float wetDryMix, float roomSize, float damping) {
    enabled_ = enabled;
    // NaN degrades to dry (0.0). clampFloat() alone would map NaN to
    // 1.0 — std::min(1.0f, NaN) == 1.0f — silently turning a bad slider
    // value into FULL wet / max room / max damping.
    wetDryMix_ = std::isnan(wetDryMix) ? 0.0f : clampFloat(wetDryMix, 0.0f, 1.0f);
    roomSize_ = std::isnan(roomSize) ? 0.0f : clampFloat(roomSize, 0.0f, 1.0f);
    damping_ = std::isnan(damping) ? 0.0f : clampFloat(damping, 0.0f, 1.0f);
    updateInternalParams();
    // Going inactive freezes the comb/allpass buffers mid-tail: the
    // process() early-return stops the filters advancing, so without
    // this reset re-enabling resurrects the stale tail. Clear the
    // filters so re-enable starts clean (matches the release-at-0
    // behaviour of the platform EnvironmentalReverb path).
    if (!enabled_ || wetDryMix_ <= 0.0001f) {
        reset();
    }
}

void FreeverbProcessor::updateInternalParams() {
    constexpr float kScaleWet = 3.0f;
    constexpr float kScaleDamp = 0.4f;
    constexpr float kScaleRoom = 0.28f;
    constexpr float kOffsetRoom = 0.70f;

    wetGain_ = wetDryMix_ * kScaleWet;
    dryGain_ = 1.0f - wetDryMix_;

    const float feedback = kOffsetRoom + (roomSize_ * kScaleRoom);
    const float damp = damping_ * kScaleDamp;

    for (int i = 0; i < kNumCombs; ++i) {
        combL_[i].setFeedback(feedback);
        combR_[i].setFeedback(feedback);
        combL_[i].setDamping(damp);
        combR_[i].setDamping(damp);
    }
}

void FreeverbProcessor::process(float* interleaved, size_t frames, int channels) {
    if (!enabled_ || wetDryMix_ <= 0.0001f) {
        return;
    }
    // Unconfigured processor (configure() never ran): the comb buffers
    // are empty and indexing them is UB — segfault on host, crash on
    // device. Stay dry instead (mirrors EchoProcessor's empty check).
    if (combL_[0].empty()) {
        return;
    }

    constexpr float kFixedGain = 0.015f;

    if (channels == 1) {
        for (size_t i = 0; i < frames; ++i) {
            const float dry = interleaved[i];
            const float input = dry * (2.0f * kFixedGain);
            float wet = 0.0f;
            for (int c = 0; c < kNumCombs; ++c) {
                wet += combL_[c].process(input);
            }
            for (int a = 0; a < kNumAllpasses; ++a) {
                wet = allpassL_[a].process(wet);
            }
            interleaved[i] = dry * dryGain_ + wet * wetGain_;
        }
    } else {
        for (size_t i = 0; i < frames; ++i) {
            const float dryL = interleaved[i * 2];
            const float dryR = interleaved[i * 2 + 1];
            const float input = (dryL + dryR) * kFixedGain;
            float wetL = 0.0f;
            float wetR = 0.0f;
            for (int c = 0; c < kNumCombs; ++c) {
                wetL += combL_[c].process(input);
                wetR += combR_[c].process(input);
            }
            for (int a = 0; a < kNumAllpasses; ++a) {
                wetL = allpassL_[a].process(wetL);
                wetR = allpassR_[a].process(wetR);
            }
            interleaved[i * 2] = dryL * dryGain_ + wetL * wetGain_;
            interleaved[i * 2 + 1] = dryR * dryGain_ + wetR * wetGain_;
        }
    }
}

// -----------------------------------------------------------------------------
// EchoProcessor
// -----------------------------------------------------------------------------

void EchoProcessor::configure(int sampleRate) {
    sampleRate_ = std::max(8000, sampleRate);
    const size_t maxSamples = static_cast<size_t>((kMaxDelayMs * 0.001f) * static_cast<float>(sampleRate_)) + 4;
    bufferL_.assign(maxSamples, 0.0f);
    bufferR_.assign(maxSamples, 0.0f);
    writePos_ = 0;

    targetDelaySamples_ = clampFloat(
        (delayMs_ * 0.001f) * static_cast<float>(sampleRate_),
        1.0f,
        static_cast<float>(maxSamples - 2)
    );
    currentDelaySamples_ = targetDelaySamples_;
}

void EchoProcessor::reset() {
    std::fill(bufferL_.begin(), bufferL_.end(), 0.0f);
    std::fill(bufferR_.begin(), bufferR_.end(), 0.0f);
    writePos_ = 0;
    currentDelaySamples_ = targetDelaySamples_;
}

void EchoProcessor::setParams(bool enabled, float delayMs, float feedback, float mix) {
    const bool wasEnabled = enabled_;
    enabled_ = enabled;

    // NaN guard: clampFloat() turns NaN into the HIGH end (std::min(hi,
    // NaN) == hi), so an unguarded NaN would silently become max delay /
    // max feedback / full wet. A NaN parameter instead keeps its current
    // value; Dart/Kotlin also sanitise, this is the last line of defence.
    // (+/-inf still clamps to the documented range, as before.)
    if (!std::isnan(delayMs)) {
        delayMs_ = clampFloat(delayMs, 1.0f, kMaxDelayMs);
    }
    if (!std::isnan(feedback)) {
        feedback_ = clampFloat(feedback, 0.0f, 0.95f);
    }
    if (!std::isnan(mix)) {
        mix_ = clampFloat(mix, 0.0f, 1.0f);
    }

    const float maxDelay = bufferL_.size() > 2
        ? static_cast<float>(bufferL_.size() - 2)
        : 1.0f;
    targetDelaySamples_ = clampFloat(
        (delayMs_ * 0.001f) * static_cast<float>(sampleRate_),
        1.0f,
        maxDelay
    );

    // Disabling must not leave stale audio in the line: process() stops
    // touching the buffer while disabled (and DspEngine bypasses the
    // whole chain with memcpy when every effect is off), so without this
    // clear, re-enabling replays a ghost echo of pre-disable audio.
    if (wasEnabled && !enabled_) {
        reset();
    }
}

void EchoProcessor::process(float* interleaved, size_t frames, int channels) {
    if (bufferL_.empty()) {
        return;
    }

    const size_t bufSize = bufferL_.size();
    const float bufSizeF = static_cast<float>(bufSize);
    const float dryGain = 1.0f - mix_;
    const float wetGain = mix_;

    if (!enabled_ || mix_ <= 0.0001f) {
        // Bypassed (disabled, or mix at zero): output untouched, but keep
        // feeding the delay line with dry input so it always holds the
        // most recent audio. Without this the line freezes on disable /
        // mix-0 and re-enabling replays a ghost echo of stale audio.
        // Dry-only writes (no feedback) cannot accumulate or run away.
        if (channels == 1) {
            for (size_t i = 0; i < frames; ++i) {
                bufferL_[writePos_] = flushDenormal(interleaved[i]);
                if (++writePos_ >= bufSize) {
                    writePos_ = 0;
                }
            }
        } else {
            for (size_t i = 0; i < frames; ++i) {
                bufferL_[writePos_] = flushDenormal(interleaved[i * 2]);
                bufferR_[writePos_] = flushDenormal(interleaved[i * 2 + 1]);
                if (++writePos_ >= bufSize) {
                    writePos_ = 0;
                }
            }
        }
        return;
    }

    if (channels == 1) {
        for (size_t i = 0; i < frames; ++i) {
            // Slew the delay toward its target. The per-sample step is
            // rate-limited to 0.5 samples: an unlimited exponential slew
            // sweeps the read pointer at up to ~72x speed on a large jump
            // (250 -> 1000 ms), turning the echo into a ~50 ms ultrasonic
            // chirp (measured max sample-step 21x the dry signal slope).
            // At <= 0.5 samples/sample the read pointer always moves
            // forward at 0.5x-1.5x speed, so a delay change sounds like a
            // short tape-style pitch glide, never a click or a chirp.
            // Small changes (< 250 samples) are unaffected: the 0.002
            // exponential term governs and settles in ~10 ms.
            double step = 0.002 * (targetDelaySamples_ - currentDelaySamples_);
            step = std::max(-0.5, std::min(0.5, step));
            currentDelaySamples_ += step;

            float readPosF = static_cast<float>(
                static_cast<double>(writePos_) - currentDelaySamples_);
            while (readPosF < 0.0f) {
                readPosF += bufSizeF;
            }
            const size_t idx0 = static_cast<size_t>(readPosF) % bufSize;
            const size_t idx1 = (idx0 + 1) % bufSize;
            const float frac = readPosF - std::floor(readPosF);

            const float delayed = bufferL_[idx0] * (1.0f - frac) + bufferL_[idx1] * frac;
            const float dry = interleaved[i];

            bufferL_[writePos_] = flushDenormal(dry + delayed * feedback_);
            interleaved[i] = dry * dryGain + delayed * wetGain;

            if (++writePos_ >= bufSize) {
                writePos_ = 0;
            }
        }
    } else {
        for (size_t i = 0; i < frames; ++i) {
            // Same slew as the mono path (see comment above).
            double step = 0.002 * (targetDelaySamples_ - currentDelaySamples_);
            step = std::max(-0.5, std::min(0.5, step));
            currentDelaySamples_ += step;

            float readPosF = static_cast<float>(
                static_cast<double>(writePos_) - currentDelaySamples_);
            while (readPosF < 0.0f) {
                readPosF += bufSizeF;
            }
            const size_t idx0 = static_cast<size_t>(readPosF) % bufSize;
            const size_t idx1 = (idx0 + 1) % bufSize;
            const float frac = readPosF - std::floor(readPosF);

            const float delayedL = bufferL_[idx0] * (1.0f - frac) + bufferL_[idx1] * frac;
            const float delayedR = bufferR_[idx0] * (1.0f - frac) + bufferR_[idx1] * frac;
            const float dryL = interleaved[i * 2];
            const float dryR = interleaved[i * 2 + 1];

            bufferL_[writePos_] = flushDenormal(dryL + delayedL * feedback_);
            bufferR_[writePos_] = flushDenormal(dryR + delayedR * feedback_);

            interleaved[i * 2] = dryL * dryGain + delayedL * wetGain;
            interleaved[i * 2 + 1] = dryR * dryGain + delayedR * wetGain;

            if (++writePos_ >= bufSize) {
                writePos_ = 0;
            }
        }
    }
}

// -----------------------------------------------------------------------------
// EqProcessor
// -----------------------------------------------------------------------------

void EqProcessor::configure(int sampleRate) {
    sampleRate_ = std::max(8000, sampleRate);
    reset();
    updateCoefficients();
}

void EqProcessor::reset() {
    bassBoost_.reset();
    lowShelf_.reset();
    midPeak_.reset();
    highShelf_.reset();
    // State is zeroed, so the wet path is transient-free: snap the mix.
    mix_ = mixTarget_;
}

void EqProcessor::setParams(bool enabled, float bassBoostDb, float lowGainDb, float midGainDb, float highGainDb) {
    enabled_ = enabled;
    mixTarget_ = enabled ? 1.0f : 0.0f;
    // NaN must map to 0 dB, not to max: clampFloat(NaN) returns the
    // upper bound (std::min/max treat NaN comparisons as false), so an
    // unsanitized NaN would silently become +12 dB on every band.
    const auto clean = [](float v) { return std::isfinite(v) ? v : 0.0f; };
    bassBoostDb_ = clampFloat(clean(bassBoostDb), 0.0f, 12.0f);
    lowGainDb_ = clampFloat(clean(lowGainDb), -12.0f, 12.0f);
    midGainDb_ = clampFloat(clean(midGainDb), -12.0f, 12.0f);
    highGainDb_ = clampFloat(clean(highGainDb), -12.0f, 12.0f);
    updateCoefficients();
}

void EqProcessor::updateCoefficients() {
    bassBoost_.configure(BiquadFilter::Type::LowShelf, sampleRate_, 80.0f, 0.85f, bassBoostDb_);
    lowShelf_.configure(BiquadFilter::Type::LowShelf, sampleRate_, 200.0f, 0.707f, lowGainDb_);
    midPeak_.configure(BiquadFilter::Type::Peaking, sampleRate_, 1000.0f, 0.9f, midGainDb_);
    highShelf_.configure(BiquadFilter::Type::HighShelf, sampleRate_, 4000.0f, 0.707f, highGainDb_);
}

void EqProcessor::process(float* interleaved, size_t frames, int channels) {
    // Fully dry: true bypass, bit-exact (input untouched).
    if (mix_ <= 0.0f && mixTarget_ <= 0.0f) {
        return;
    }
    if (bassBoost_.isBypassed() && lowShelf_.isBypassed() && midPeak_.isBypassed() && highShelf_.isBypassed()) {
        // Wet == dry: nothing audible to fade; snap and bypass.
        mix_ = mixTarget_;
        return;
    }

    // Slew the wet/dry mix toward its target once per frame so
    // enable/disable crossfades over ~5 ms instead of clicking
    // (a hard disable measured a 0.94 single-sample step on a 60 Hz
    // bass-boosted signal — a loud pop).
    const float step = 1.0f / static_cast<float>(kMixRampFrames);
    const auto advanceMix = [&]() {
        if (mix_ < mixTarget_) {
            mix_ = std::min(mixTarget_, mix_ + step);
        } else if (mix_ > mixTarget_) {
            mix_ = std::max(mixTarget_, mix_ - step);
        }
    };

    if (channels == 1) {
        for (size_t i = 0; i < frames; ++i) {
            advanceMix();
            const float dry = interleaved[i];
            float wet = dry;
            wet = bassBoost_.processSample(0, wet);
            wet = lowShelf_.processSample(0, wet);
            wet = midPeak_.processSample(0, wet);
            wet = highShelf_.processSample(0, wet);
            interleaved[i] = dry + (wet - dry) * mix_;
        }
    } else {
        for (size_t i = 0; i < frames; ++i) {
            advanceMix();
            const float dryL = interleaved[i * 2];
            float wetL = dryL;
            wetL = bassBoost_.processSample(0, wetL);
            wetL = lowShelf_.processSample(0, wetL);
            wetL = midPeak_.processSample(0, wetL);
            wetL = highShelf_.processSample(0, wetL);
            interleaved[i * 2] = dryL + (wetL - dryL) * mix_;

            const float dryR = interleaved[i * 2 + 1];
            float wetR = dryR;
            wetR = bassBoost_.processSample(1, wetR);
            wetR = lowShelf_.processSample(1, wetR);
            wetR = midPeak_.processSample(1, wetR);
            wetR = highShelf_.processSample(1, wetR);
            interleaved[i * 2 + 1] = dryR + (wetR - dryR) * mix_;
        }
    }
}

// -----------------------------------------------------------------------------
// DspEngine
// -----------------------------------------------------------------------------

DspEngine::DspEngine(int sampleRate, int channels) {
    configureInternal(sampleRate, channels);
    scratch_.resize(4096, 0.0f);
}

void DspEngine::configure(int sampleRate, int channels) {
    std::lock_guard<std::mutex> lock(mutex_);
    configureInternal(sampleRate, channels);
}

void DspEngine::configureInternal(int sampleRate, int channels) {
    sampleRate_ = std::max(8000, sampleRate);
    channels_ = (channels == 1) ? 1 : 2;
    noiseGate_.configure(sampleRate_);
    compressor_.configure(sampleRate_);
    eq_.configure(sampleRate_);
    echo_.configure(sampleRate_);
    reverb_.configure(sampleRate_);
}

void DspEngine::setNoiseGate(bool enabled, float thresholdDb, float attackMs, float releaseMs) {
    std::lock_guard<std::mutex> lock(mutex_);
    noiseGate_.setParams(enabled, thresholdDb, attackMs, releaseMs);
}

void DspEngine::setCompressor(
    bool enabled,
    float thresholdDb,
    float ratio,
    float attackMs,
    float releaseMs,
    float makeupGainDb) {
    std::lock_guard<std::mutex> lock(mutex_);
    compressor_.setParams(enabled, thresholdDb, ratio, attackMs, releaseMs, makeupGainDb);
}

void DspEngine::setReverb(bool enabled, float wetDryMix, float roomSize, float damping) {
    std::lock_guard<std::mutex> lock(mutex_);
    reverb_.setParams(enabled, wetDryMix, roomSize, damping);
}

void DspEngine::setEcho(bool enabled, float delayMs, float feedback, float mix) {
    std::lock_guard<std::mutex> lock(mutex_);
    echo_.setParams(enabled, delayMs, feedback, mix);
}

void DspEngine::setEq(bool enabled, float bassBoostDb, float lowGainDb, float midGainDb, float highGainDb) {
    std::lock_guard<std::mutex> lock(mutex_);
    eq_.setParams(enabled, bassBoostDb, lowGainDb, midGainDb, highGainDb);
}

void DspEngine::reset() {
    std::lock_guard<std::mutex> lock(mutex_);
    noiseGate_.reset();
    compressor_.reset();
    eq_.reset();
    echo_.reset();
    reverb_.reset();
}

void DspEngine::processPcm16(const uint8_t* inBytes, uint8_t* outBytes, size_t byteLength) {
    if (inBytes == nullptr || outBytes == nullptr || byteLength == 0) {
        return;
    }

    std::lock_guard<std::mutex> lock(mutex_);

    const size_t frameStrideBytes = static_cast<size_t>(channels_) * 2;
    const size_t frames = byteLength / frameStrideBytes;
    if (frames == 0) {
        if (inBytes != outBytes) {
            std::memcpy(outBytes, inBytes, byteLength);
        }
        return;
    }

    if (!noiseGate_.isEnabled() &&
        !compressor_.isEnabled() &&
        !eq_.isEnabled() &&
        !echo_.isEnabled() &&
        !reverb_.isEnabled()) {
        if (inBytes != outBytes) {
            std::memcpy(outBytes, inBytes, byteLength);
        }
        return;
    }

    const size_t totalSamples = frames * static_cast<size_t>(channels_);
    if (scratch_.size() < totalSamples) {
        scratch_.resize(totalSamples);
    }

    constexpr float kInt16ToFloat = 1.0f / 32768.0f;
    for (size_t s = 0; s < totalSamples; ++s) {
        const size_t b = s * 2;
        const uint16_t raw = static_cast<uint16_t>(inBytes[b]) |
                             (static_cast<uint16_t>(inBytes[b + 1]) << 8);
        const int16_t pcm = static_cast<int16_t>(raw);
        scratch_[s] = static_cast<float>(pcm) * kInt16ToFloat;
    }

    noiseGate_.process(scratch_.data(), frames, channels_);
    compressor_.process(scratch_.data(), frames, channels_);
    eq_.process(scratch_.data(), frames, channels_);
    echo_.process(scratch_.data(), frames, channels_);
    reverb_.process(scratch_.data(), frames, channels_);

    for (size_t s = 0; s < totalSamples; ++s) {
        const float limited = clampFloat(softLimit(scratch_[s]), -1.0f, 1.0f);
        const float scaled = (limited >= 0.0f) ? (limited * 32767.0f) : (limited * 32768.0f);
        const long quantized = std::lrintf(scaled);
        const int16_t pcm = static_cast<int16_t>(std::max<long>(-32768L, std::min<long>(32767L, quantized)));
        const uint16_t u = static_cast<uint16_t>(pcm);

        const size_t b = s * 2;
        outBytes[b] = static_cast<uint8_t>(u & 0xFFu);
        outBytes[b + 1] = static_cast<uint8_t>((u >> 8) & 0xFFu);
    }
}

} // namespace arena_dsp
