#ifndef ARENA_HUB_DSP_ENGINE_H
#define ARENA_HUB_DSP_ENGINE_H

#include <cstddef>
#include <cstdint>
#include <mutex>
#include <vector>

namespace arena_dsp {

class BiquadFilter {
public:
    enum class Type {
        LowShelf,
        Peaking,
        HighShelf
    };

    void configure(Type type, int sampleRate, float freqHz, float qOrSlope, float gainDb);
    void reset();
    float processSample(int channel, float x);

    bool isBypassed() const { return bypassed_; }

private:
    float b0_ = 1.0f;
    float b1_ = 0.0f;
    float b2_ = 0.0f;
    float a1_ = 0.0f;
    float a2_ = 0.0f;

    float z1_[2] = {0.0f, 0.0f};
    float z2_[2] = {0.0f, 0.0f};

    bool bypassed_ = true;
};

class CombFilter {
public:
    void resize(size_t size);
    void reset();
    void setFeedback(float feedback);
    void setDamping(float damping);
    float process(float input);

    // True before resize() has ever run (configure() not called yet).
    // process() must never index an empty buffer (UB / segfault).
    bool empty() const { return buffer_.empty(); }

private:
    std::vector<float> buffer_;
    size_t index_ = 0;
    float filterStore_ = 0.0f;
    float feedback_ = 0.5f;
    float damp1_ = 0.2f;
    float damp2_ = 0.8f;
};

class AllpassFilter {
public:
    void resize(size_t size);
    void reset();
    void setFeedback(float feedback);
    float process(float input);

private:
    std::vector<float> buffer_;
    size_t index_ = 0;
    float feedback_ = 0.5f;
};

class NoiseGateProcessor {
public:
    void configure(int sampleRate);
    void reset();
    void setParams(bool enabled, float thresholdDb, float attackMs, float releaseMs);
    void process(float* interleaved, size_t frames, int channels);

    bool isEnabled() const { return enabled_; }

private:
    void updateCoefficients();

    int sampleRate_ = 48000;
    bool enabled_ = false;
    float thresholdDb_ = -40.0f;
    float attackMs_ = 5.0f;
    float releaseMs_ = 120.0f;

    float openThreshold_ = 0.01f;
    float closeThreshold_ = 0.007079f;

    float attackCoeff_ = 0.995f;
    float releaseCoeff_ = 0.9998f;
    float detAttackCoeff_ = 0.95f;
    float detReleaseCoeff_ = 0.9993f;

    float detectorEnv_ = 0.0f;
    float gain_ = 0.0f;
    bool gateOpen_ = false;
};

class CompressorProcessor {
public:
    void configure(int sampleRate);
    void reset();
    void setParams(bool enabled, float thresholdDb, float ratio, float attackMs, float releaseMs, float makeupGainDb);
    void process(float* interleaved, size_t frames, int channels);

    bool isEnabled() const { return enabled_; }

private:
    void updateCoefficients();

    int sampleRate_ = 48000;
    bool enabled_ = false;
    float thresholdDb_ = -18.0f;
    float ratio_ = 4.0f;
    float attackMs_ = 10.0f;
    float releaseMs_ = 100.0f;
    float makeupGainDb_ = 0.0f;

    float attackCoeff_ = 0.9979f;
    float releaseCoeff_ = 0.99979f;
    float envelopeDb_ = 0.0f;
};

class FreeverbProcessor {
public:
    static constexpr int kNumCombs = 8;
    static constexpr int kNumAllpasses = 4;

    void configure(int sampleRate);
    void reset();
    void setParams(bool enabled, float wetDryMix, float roomSize, float damping);
    void process(float* interleaved, size_t frames, int channels);

    bool isEnabled() const { return enabled_; }

private:
    void updateInternalParams();

    int sampleRate_ = 48000;
    bool enabled_ = false;
    float wetDryMix_ = 0.3f;
    float roomSize_ = 0.5f;
    float damping_ = 0.5f;
    float wetGain_ = 0.9f;
    float dryGain_ = 0.7f;

    CombFilter combL_[kNumCombs];
    CombFilter combR_[kNumCombs];
    AllpassFilter allpassL_[kNumAllpasses];
    AllpassFilter allpassR_[kNumAllpasses];
};

class EchoProcessor {
public:
    static constexpr float kMaxDelayMs = 2000.0f;

    void configure(int sampleRate);
    void reset();
    void setParams(bool enabled, float delayMs, float feedback, float mix);
    void process(float* interleaved, size_t frames, int channels);

    bool isEnabled() const { return enabled_; }

private:
    int sampleRate_ = 48000;
    bool enabled_ = false;
    float delayMs_ = 250.0f;
    float feedback_ = 0.35f;
    float mix_ = 0.35f;

    // Slew state is double, not float: at large delays (96000 samples
    // @ 2000 ms) a float32 slew stalls ~2 samples short of the target
    // because the per-sample step 0.002*error falls below half an ulp
    // (0.0039 @ 96000) once error < ~2 samples, so the delay lands
    // ~0.04 ms short. Double accumulation converges exactly; only the
    // read position itself is float.
    double targetDelaySamples_ = 12000.0;
    double currentDelaySamples_ = 12000.0;

    std::vector<float> bufferL_;
    std::vector<float> bufferR_;
    size_t writePos_ = 0;
};

class EqProcessor {
public:
    void configure(int sampleRate);
    void reset();
    void setParams(bool enabled, float bassBoostDb, float lowGainDb, float midGainDb, float highGainDb);
    void process(float* interleaved, size_t frames, int channels);

    // True while the EQ is enabled OR a disable fade-out is still
    // running, so DspEngine's all-disabled fast path never cuts the
    // fade short. (Group 5 fix, 2026-11-22.)
    bool isEnabled() const { return enabled_ || mix_ > 0.0f; }

private:
    void updateCoefficients();

    int sampleRate_ = 48000;
    bool enabled_ = false;
    float bassBoostDb_ = 0.0f;
    float lowGainDb_ = 0.0f;
    float midGainDb_ = 0.0f;
    float highGainDb_ = 0.0f;

    // Wet/dry mix ramp for click-free enable/disable: setParams moves
    // mixTarget_ (1 = enabled, 0 = disabled) and process() slews mix_
    // toward it over kMixRampFrames frames (~5 ms at 48 kHz).
    // Coefficient changes need no ramp: measured jumps (bass 0->+12 dB,
    // mid 0->+12 dB) stay at/below the signal's own max step.
    static constexpr int kMixRampFrames = 256;
    float mix_ = 0.0f;
    float mixTarget_ = 0.0f;

    BiquadFilter bassBoost_;
    BiquadFilter lowShelf_;
    BiquadFilter midPeak_;
    BiquadFilter highShelf_;
};

class DspEngine {
public:
    DspEngine(int sampleRate, int channels);

    void configure(int sampleRate, int channels);
    void setNoiseGate(bool enabled, float thresholdDb, float attackMs, float releaseMs);
    void setCompressor(bool enabled, float thresholdDb, float ratio, float attackMs, float releaseMs, float makeupGainDb);
    void setReverb(bool enabled, float wetDryMix, float roomSize, float damping);
    void setEcho(bool enabled, float delayMs, float feedback, float mix);
    void setEq(bool enabled, float bassBoostDb, float lowGainDb, float midGainDb, float highGainDb);
    void reset();

    void processPcm16(const uint8_t* inBytes, uint8_t* outBytes, size_t byteLength);

private:
    void configureInternal(int sampleRate, int channels);

    std::mutex mutex_;
    int sampleRate_ = 48000;
    int channels_ = 2;

    NoiseGateProcessor noiseGate_;
    CompressorProcessor compressor_;
    EqProcessor eq_;
    EchoProcessor echo_;
    FreeverbProcessor reverb_;
    std::vector<float> scratch_;
};

} // namespace arena_dsp

#endif // ARENA_HUB_DSP_ENGINE_H
