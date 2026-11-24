// HOST HARNESS — RJ Studio mic bridge (DspMicBridge + v3 DspEngine).
//
// Compiles the REAL bridge + the UNTOUCHED v3 engine on the host and
// checks the RJ design: full-band full-chain when numBands == 1,
// per-band full-chain (EQ on band 0 only) when split, dual-format
// routing, the float sanity check, bypass bit-exactness, and the live
// gate/compressor params.
//
// Build (from the project cpp dir):
//   g++ -std=c++17 -Wall -Wextra -O2 -I. host_test/dsp_mic_rj_bridge_check.cpp
//       dsp_engine.cpp dsp_mic_bridge.cpp -o /tmp/dsp_mic_rj_check
//   /tmp/dsp_mic_rj_check
//
// (Folded into host_test/ by the DSP fold, 2026-11-22; it previously
// lived at ~/workspace/arena-hub-audio/dsp_mic_rj_bridge_check.cpp.)
//
// Echo timing note: DspEngine::setEcho only moves the TARGET delay —
// the read pointer slews toward it (0.2%/sample). The tests below use
// the 250 ms DEFAULT delay, where target == current from configure()
// (no slew): the echo of a frame-0 impulse lands exactly 25 frames
// later (250 ms = 4000 samples @ 16 kHz = 25 x 160; 12000 @ 48 kHz =
// 25 x 480). A live delay change still slews smoothly on-device —
// that is the engine's designed behaviour, not a bridge defect.
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>

#include "dsp_mic_bridge.h"

using namespace arena_dsp;

static int g_pass = 0;
static int g_fail = 0;

#define CHECK(cond, ...)                                                     \
    do {                                                                     \
        if (cond) {                                                          \
            ++g_pass;                                                        \
        } else {                                                             \
            ++g_fail;                                                        \
            std::printf("FAIL line %d: ", __LINE__);                         \
            std::printf(__VA_ARGS__);                                        \
            std::printf("\n");                                               \
        }                                                                    \
    } while (0)

namespace {

constexpr float kPi = 3.14159265358979323846f;

void tone(float* buf, int n, float freqHz, float rateHz, float amp) {
    for (int i = 0; i < n; ++i) {
        buf[i] = amp * std::sin(2.0f * kPi * freqHz *
                                static_cast<float>(i) / rateHz);
    }
}

float peak(const float* buf, int n) {
    float p = 0.0f;
    for (int i = 0; i < n; ++i) p = std::max(p, std::fabs(buf[i]));
    return p;
}

float maxDiff(const float* a, const float* b, int n) {
    float d = 0.0f;
    for (int i = 0; i < n; ++i) d = std::max(d, std::fabs(a[i] - b[i]));
    return d;
}

bool bitIdentical(const void* a, const void* b, size_t bytes) {
    return std::memcmp(a, b, bytes) == 0;
}

// One 10 ms split-band float frame: 3 bands x 160, tone in every band.
void splitToneFrame(std::vector<float>& f, float amp) {
    f.assign(3 * 160, 0.0f);
    tone(f.data(), 160, 1000.0f, 16000.0f, amp);          // band 0
    tone(f.data() + 160, 160, 3000.0f, 16000.0f, amp);    // band 1
    tone(f.data() + 320, 160, 5000.0f, 16000.0f, amp);    // band 2
}

void splitSilence(std::vector<float>& f) { f.assign(3 * 160, 0.0f); }

// ---- Soundboard clip helpers (route A). ----

// A 48 kHz mono clip of `seconds` of a constant value.
std::vector<float> clip48kConstant(float value, float seconds) {
    const size_t n = static_cast<size_t>(48000.0f * seconds);
    return std::vector<float>(n, value);
}

// A 48 kHz mono clip ramping linearly 0 -> 1 over `seconds`.
std::vector<float> clip48kRamp(float seconds) {
    const size_t n = static_cast<size_t>(48000.0f * seconds);
    std::vector<float> c(n);
    for (size_t i = 0; i < n; ++i) {
        c[i] = static_cast<float>(i) / static_cast<float>(n);
    }
    return c;
}

// A 48 kHz mono clip: a tone at `freqHz`, amplitude `amp`.
std::vector<float> clip48kTone(float freqHz, float amp, float seconds) {
    const size_t n = static_cast<size_t>(48000.0f * seconds);
    std::vector<float> c(n);
    tone(c.data(), static_cast<int>(n), freqHz, 48000.0f, amp);
    return c;
}

// One split-band int16 silence frame: 3 bands x 160 int16 = 960 bytes.
void splitSilencePcm16(std::vector<uint8_t>& b) { b.assign(3 * 160 * 2, 0); }

int16_t readPcm16(const std::vector<uint8_t>& b, size_t sampleIdx) {
    const size_t off = sampleIdx * 2;
    return static_cast<int16_t>(b[off] | (b[off + 1] << 8));
}

}  // namespace

int main() {
    // ---- init validation -------------------------------------------------
    {
        DspMicBridge b;
        CHECK(!b.init(48000, 2), "stereo must be rejected");
        CHECK(b.lastError() == kDspMicUnsupportedChannels,
              "stereo error code");
        CHECK(!b.init(44100, 1), "44.1 kHz must be rejected");
        CHECK(!b.init(48000, 0), "0 channels must be rejected");
        CHECK(b.init(48000, 1), "mono 48 kHz accepted");
        CHECK(b.isInitialized(), "isInitialized after init");
        CHECK(b.init(16000, 1), "re-init accepted");
        b.release();
        CHECK(!b.isInitialized(), "not initialized after release");
        b.release();  // double release is safe
    }

    // ---- process before init fails open, buffer untouched ----------------
    {
        DspMicBridge b;
        std::vector<float> f;
        splitToneFrame(f, 0.5f);
        std::vector<float> before = f;
        CHECK(!b.processBuffer(reinterpret_cast<uint8_t*>(f.data()),
                               f.size() * 4, 3, 160),
              "process before init must fail");
        CHECK(b.lastError() == kDspMicNotInitialized, "not-init code");
        CHECK(bitIdentical(f.data(), before.data(), f.size() * 4),
              "buffer untouched before init");
    }

    // ---- full-band float: engine at full rate, EQ changes the signal ----
    {
        DspMicBridge b;
        CHECK(b.init(48000, 1), "init 48k");
        b.setEq(true, 0.0f, 0.0f, 6.0f, 0.0f);  // +6 dB @ 1 kHz
        std::vector<float> f(480);
        tone(f.data(), 480, 1000.0f, 48000.0f, 0.5f);
        const float inPeak = peak(f.data(), 480);
        CHECK(b.processBuffer(reinterpret_cast<uint8_t*>(f.data()),
                              f.size() * 4, 1, 480),
              "full-band float processes");
        CHECK(b.engineSampleRate() == 48000,
              "full-band engine at 48 kHz, got %d", b.engineSampleRate());
        CHECK(b.engineSampleRateForBand(0) == 48000, "band-0 rate 48k");
        CHECK(b.lastFormatBytesPerSample() == 4, "float format recorded");
        CHECK(peak(f.data(), 480) > inPeak * 1.5f,
              "+6 dB mid must boost a 1 kHz tone (in %.3f out %.3f)",
              inPeak, peak(f.data(), 480));
        CHECK(b.framesProcessed() == 1, "one frame counted");
    }

    // ---- full-band: echo lands exactly 25 frames later (250 ms) ---------
    {
        DspMicBridge b;
        CHECK(b.init(48000, 1), "init 48k");
        b.setEq(false, 0, 0, 0, 0);
        b.setEcho(true, 250.0f, 0.5f, 0.5f);  // default delay: no slew
        std::vector<float> f(480, 0.0f);
        f[0] = 0.9f;  // impulse
        CHECK(b.processBuffer(reinterpret_cast<uint8_t*>(f.data()),
                              f.size() * 4, 1, 480),
              "impulse frame processes");
        float maxBefore = 0.0f;
        for (int k = 1; k < 25; ++k) {
            std::vector<float> s(480, 0.0f);
            CHECK(b.processBuffer(reinterpret_cast<uint8_t*>(s.data()),
                                  s.size() * 4, 1, 480),
                  "silent frame %d processes", k);
            maxBefore = std::max(maxBefore, peak(s.data(), 480));
        }
        CHECK(maxBefore < 0.01f,
              "no echo before frame 25 (max %.4f)", maxBefore);
        std::vector<float> echo(480, 0.0f);
        CHECK(b.processBuffer(reinterpret_cast<uint8_t*>(echo.data()),
                              echo.size() * 4, 1, 480),
              "frame 25 processes");
        CHECK(peak(echo.data(), 480) > 0.3f,
              "echo lands at frame 25 (peak %.3f, expect ~0.45)",
              peak(echo.data(), 480));
        CHECK(b.framesProcessed() == 26, "26 frames counted, got %ld",
              b.framesProcessed());
    }

    // ---- full-band: reverb tail after an impulse -------------------------
    {
        DspMicBridge b;
        CHECK(b.init(48000, 1), "init 48k");
        b.setEq(false, 0, 0, 0, 0);
        b.setReverb(true, 0.5f, 0.7f, 0.5f);
        std::vector<float> f(480, 0.0f);
        f[0] = 0.9f;
        CHECK(b.processBuffer(reinterpret_cast<uint8_t*>(f.data()),
                              f.size() * 4, 1, 480),
              "impulse frame processes");
        float tail = 0.0f;
        for (int k = 0; k < 5; ++k) {
            std::vector<float> s(480, 0.0f);
            b.processBuffer(reinterpret_cast<uint8_t*>(s.data()),
                            s.size() * 4, 1, 480);
            tail = std::max(tail, peak(s.data(), 480));
        }
        CHECK(tail > 0.005f, "reverb tail present (max %.4f)", tail);
    }

    // ---- full-band: compressor tames a loud tone, spares a quiet one ----
    {
        DspMicBridge b;
        CHECK(b.init(48000, 1), "init 48k");
        b.setEq(false, 0, 0, 0, 0);
        b.setCompressor(true, -18.0f, 4.0f, 10.0f, 100.0f, 0.0f);
        float loudPeak = 0.0f;
        for (int k = 0; k < 12; ++k) {
            std::vector<float> f(480);
            tone(f.data(), 480, 1000.0f, 48000.0f, 0.9f);
            b.processBuffer(reinterpret_cast<uint8_t*>(f.data()),
                            f.size() * 4, 1, 480);
            loudPeak = peak(f.data(), 480);
        }
        CHECK(loudPeak < 0.7f,
              "compressor must tame a 0.9 tone (last peak %.3f)", loudPeak);
        // Quiet tone (0.05 = -26 dBFS, below the -18 dB threshold):
        // the compressor must (nearly) leave it alone.
        DspMicBridge b2;
        CHECK(b2.init(48000, 1), "init 48k (quiet)");
        b2.setEq(false, 0, 0, 0, 0);
        b2.setCompressor(true, -18.0f, 4.0f, 10.0f, 100.0f, 0.0f);
        float quietPeak = 0.0f;
        for (int k = 0; k < 12; ++k) {
            std::vector<float> f(480);
            tone(f.data(), 480, 1000.0f, 48000.0f, 0.05f);
            b2.processBuffer(reinterpret_cast<uint8_t*>(f.data()),
                             f.size() * 4, 1, 480);
            quietPeak = peak(f.data(), 480);
        }
        CHECK(quietPeak > 0.04f && quietPeak < 0.06f,
              "quiet tone spared by compressor (peak %.4f)", quietPeak);
    }

    // ---- full-band: noise gate opens for speech, silence stays silent ---
    {
        DspMicBridge b;
        CHECK(b.init(48000, 1), "init 48k");
        b.setEq(false, 0, 0, 0, 0);
        b.setNoiseGate(true, -40.0f, 5.0f, 120.0f);
        float p = 0.0f;
        for (int k = 0; k < 6; ++k) {
            std::vector<float> f(480);
            tone(f.data(), 480, 1000.0f, 48000.0f, 0.5f);
            b.processBuffer(reinterpret_cast<uint8_t*>(f.data()),
                            f.size() * 4, 1, 480);
            p = peak(f.data(), 480);
        }
        CHECK(p > 0.4f, "gate opens for a loud tone (peak %.3f)", p);
        std::vector<float> s(480, 0.0f);
        CHECK(b.processBuffer(reinterpret_cast<uint8_t*>(s.data()),
                              s.size() * 4, 1, 480),
              "silent frame processes");
        CHECK(peak(s.data(), 480) == 0.0f, "silence stays bit-exact zero");
    }

    // ---- split-band float: EQ on band 0 ONLY, bands 1-2 bit-identical ---
    {
        DspMicBridge b;
        CHECK(b.init(48000, 1), "init 48k");
        b.setEq(true, 0.0f, 0.0f, 12.0f, 0.0f);  // +12 dB mid, EQ only
        std::vector<float> f;
        splitToneFrame(f, 0.5f);
        std::vector<float> before = f;
        CHECK(b.processBuffer(reinterpret_cast<uint8_t*>(f.data()),
                              f.size() * 4, 3, 160),
              "split float processes");
        CHECK(b.engineSampleRate() == 16000,
              "split band-0 engine at 16 kHz, got %d",
              b.engineSampleRate());
        CHECK(b.engineSampleRateForBand(1) == 16000, "band-1 rate 16k");
        CHECK(b.engineSampleRateForBand(2) == 16000, "band-2 rate 16k");
        CHECK(maxDiff(f.data(), before.data(), 160) > 0.1f,
              "band 0 EQ'd (max diff %.3f)",
              maxDiff(f.data(), before.data(), 160));
        CHECK(bitIdentical(f.data() + 160, before.data() + 160,
                           160 * sizeof(float)),
              "band 1 bit-identical with EQ only");
        CHECK(bitIdentical(f.data() + 320, before.data() + 320,
                           160 * sizeof(float)),
              "band 2 bit-identical with EQ only");
    }

    // ---- split-band: echo reaches band 1 (not just band 0) --------------
    {
        DspMicBridge b;
        CHECK(b.init(48000, 1), "init 48k");
        b.setEq(false, 0, 0, 0, 0);
        b.setEcho(true, 250.0f, 0.5f, 0.5f);
        std::vector<float> f;
        splitSilence(f);
        f[160] = 0.9f;  // impulse in BAND 1 only
        CHECK(b.processBuffer(reinterpret_cast<uint8_t*>(f.data()),
                              f.size() * 4, 3, 160),
              "band-1 impulse processes");
        float band0Echo = 0.0f, band1Echo = 0.0f, band2Echo = 0.0f;
        for (int k = 1; k <= 25; ++k) {
            std::vector<float> s;
            splitSilence(s);
            b.processBuffer(reinterpret_cast<uint8_t*>(s.data()),
                            s.size() * 4, 3, 160);
            if (k == 25) {
                band0Echo = peak(s.data(), 160);
                band1Echo = peak(s.data() + 160, 160);
                band2Echo = peak(s.data() + 320, 160);
            }
        }
        CHECK(band1Echo > 0.3f,
              "band-1 echo lands at frame 25 (peak %.3f)", band1Echo);
        CHECK(band0Echo < 0.01f && band2Echo < 0.01f,
              "echo stays in its own band (b0 %.4f b2 %.4f)",
              band0Echo, band2Echo);
    }

    // ---- split-band: reverb tail reaches band 2 --------------------------
    {
        DspMicBridge b;
        CHECK(b.init(48000, 1), "init 48k");
        b.setEq(false, 0, 0, 0, 0);
        b.setReverb(true, 0.5f, 0.7f, 0.5f);
        std::vector<float> f;
        splitSilence(f);
        f[320] = 0.9f;  // impulse in BAND 2 only
        CHECK(b.processBuffer(reinterpret_cast<uint8_t*>(f.data()),
                              f.size() * 4, 3, 160),
              "band-2 impulse processes");
        float tail = 0.0f;
        for (int k = 0; k < 5; ++k) {
            std::vector<float> s;
            splitSilence(s);
            b.processBuffer(reinterpret_cast<uint8_t*>(s.data()),
                            s.size() * 4, 3, 160);
            tail = std::max(tail, peak(s.data() + 320, 160));
        }
        CHECK(tail > 0.005f, "band-2 reverb tail present (max %.4f)",
              tail);
    }

    // ---- split-band int16: same routing, EQ band-0-only ------------------
    {
        DspMicBridge b;
        CHECK(b.init(48000, 1), "init 48k");
        b.setEq(true, 0.0f, 0.0f, 12.0f, 0.0f);
        std::vector<int16_t> pcm(3 * 160);
        for (int i = 0; i < 3 * 160; ++i) {
            pcm[i] = static_cast<int16_t>(
                16000.0f *
                std::sin(2.0f * kPi * 1000.0f *
                         static_cast<float>(i % 160) / 16000.0f));
        }
        std::vector<int16_t> before = pcm;
        CHECK(b.processBuffer(reinterpret_cast<uint8_t*>(pcm.data()),
                              pcm.size() * 2, 3, 160),
              "split int16 processes");
        CHECK(b.lastFormatBytesPerSample() == 2, "int16 format recorded");
        bool band0Changed = false;
        for (int i = 0; i < 160; ++i) {
            if (std::abs(pcm[i] - before[i]) > 100) band0Changed = true;
        }
        CHECK(band0Changed, "int16 band 0 EQ'd");
        CHECK(bitIdentical(pcm.data() + 160, before.data() + 160,
                           160 * sizeof(int16_t)),
              "int16 band 1 bit-identical with EQ only");
        CHECK(bitIdentical(pcm.data() + 320, before.data() + 320,
                           160 * sizeof(int16_t)),
              "int16 band 2 bit-identical with EQ only");
    }

    // ---- split-band int16: echo reaches band 1 ---------------------------
    {
        DspMicBridge b;
        CHECK(b.init(48000, 1), "init 48k");
        b.setEq(false, 0, 0, 0, 0);
        b.setEcho(true, 250.0f, 0.5f, 0.5f);
        std::vector<int16_t> pcm(3 * 160, 0);
        pcm[160] = 29000;  // impulse in band 1
        CHECK(b.processBuffer(reinterpret_cast<uint8_t*>(pcm.data()),
                              pcm.size() * 2, 3, 160),
              "int16 band-1 impulse processes");
        int16_t echoPeak = 0;
        for (int k = 1; k <= 25; ++k) {
            std::vector<int16_t> s(3 * 160, 0);
            b.processBuffer(reinterpret_cast<uint8_t*>(s.data()),
                            s.size() * 2, 3, 160);
            if (k == 25) {
                for (int i = 160; i < 320; ++i) {
                    echoPeak = static_cast<int16_t>(std::max<int>(
                        echoPeak, std::abs(static_cast<int>(s[i]))));
                }
            }
        }
        CHECK(echoPeak > 8000,
              "int16 band-1 echo lands (peak %d, expect ~14500)",
              static_cast<int>(echoPeak));
    }

    // ---- bypass bit-exact WITH gate+compressor enabled in the chain -----
    {
        DspMicBridge b;
        CHECK(b.init(48000, 1), "init 48k");
        b.setEq(true, 0, 0, 12.0f, 0);
        b.setEcho(true, 250.0f, 0.5f, 0.5f);
        b.setReverb(true, 0.5f, 0.7f, 0.5f);
        b.setNoiseGate(true, -40.0f, 5.0f, 120.0f);
        b.setCompressor(true, -18.0f, 4.0f, 10.0f, 100.0f, 0.0f);
        b.setBypass(true);
        std::vector<float> f;
        splitToneFrame(f, 0.5f);
        std::vector<float> before = f;
        CHECK(b.processBuffer(reinterpret_cast<uint8_t*>(f.data()),
                              f.size() * 4, 3, 160),
              "bypassed frame returns true");
        CHECK(bitIdentical(f.data(), before.data(), f.size() * 4),
              "bypass bit-exact (float, all stages on)");
        CHECK(b.framesProcessed() == 0, "bypassed frames not counted");
        // int16 bypass too.
        std::vector<int16_t> pcm(3 * 160, 12000);
        std::vector<int16_t> pcmBefore = pcm;
        CHECK(b.processBuffer(reinterpret_cast<uint8_t*>(pcm.data()),
                              pcm.size() * 2, 3, 160),
              "bypassed int16 frame returns true");
        CHECK(bitIdentical(pcm.data(), pcmBefore.data(),
                           pcm.size() * 2),
              "bypass bit-exact (int16, all stages on)");
        // Un-bypass resumes processing.
        b.setBypass(false);
        std::vector<float> f2;
        splitToneFrame(f2, 0.5f);
        CHECK(b.processBuffer(reinterpret_cast<uint8_t*>(f2.data()),
                              f2.size() * 4, 3, 160),
              "frame after un-bypass processes");
        CHECK(b.framesProcessed() == 1, "counting resumes after bypass");
    }

    // ---- all stages disabled: engine memcpy, bit-exact -------------------
    {
        DspMicBridge b;
        CHECK(b.init(48000, 1), "init 48k");
        b.setEq(false, 0, 0, 0, 0);  // echo/reverb/gate/comp off by default
        std::vector<float> f;
        splitToneFrame(f, 0.5f);
        std::vector<float> before = f;
        CHECK(b.processBuffer(reinterpret_cast<uint8_t*>(f.data()),
                              f.size() * 4, 3, 160),
              "all-disabled frame processes");
        // All bands skipped outright (bandBypass_) — NO round-trip,
        // so the float path is bit-exact here, not just ~1 LSB close.
        CHECK(bitIdentical(f.data(), before.data(), f.size() * 4),
              "all-disabled float bit-exact (bands skipped)");
        // int16 path: the engine memcpys in place — EXACT.
        std::vector<int16_t> pcm(3 * 160);
        for (int i = 0; i < 3 * 160; ++i) pcm[i] = 12000 - i;
        std::vector<int16_t> pcmBefore = pcm;
        CHECK(b.processBuffer(reinterpret_cast<uint8_t*>(pcm.data()),
                              pcm.size() * 2, 3, 160),
              "all-disabled int16 processes");
        CHECK(bitIdentical(pcm.data(), pcmBefore.data(),
                           pcm.size() * 2),
              "all-disabled int16 bit-exact (engine memcpy)");
    }

    // ---- flat EQ ~= bypass (1 LSB round-trip only) -----------------------
    {
        DspMicBridge b;
        CHECK(b.init(48000, 1), "init 48k");
        b.setEq(true, 0.0f, 0.0f, 0.0f, 0.0f);  // flat: biquads bypass
        std::vector<float> f;
        splitToneFrame(f, 0.5f);
        std::vector<float> before = f;
        CHECK(b.processBuffer(reinterpret_cast<uint8_t*>(f.data()),
                              f.size() * 4, 3, 160),
              "flat-EQ frame processes");
        // Band 0 still round-trips (EQ enabled): the bound is 2 LSB
        // (1 LSB truncation + the x32767 vs /32768 scale asymmetry),
        // i.e. 0.000061 — NOT 1 LSB. Bands 1-2 are skipped (exact).
        CHECK(maxDiff(f.data(), before.data(), 160) <= 0.000062f,
              "flat EQ changes band 0 by at most 2 LSB (max %.6f)",
              maxDiff(f.data(), before.data(), 160));
        CHECK(bitIdentical(f.data() + 160, before.data() + 160,
                           320 * sizeof(float)),
              "flat EQ leaves bands 1-2 bit-identical (skipped)");
    }

    // ---- capacity routing: too small fails open; bad counts rejected ----
    {
        DspMicBridge b;
        CHECK(b.init(48000, 1), "init 48k");
        std::vector<float> f;
        splitToneFrame(f, 0.5f);
        std::vector<float> before = f;
        CHECK(!b.processBuffer(reinterpret_cast<uint8_t*>(f.data()),
                               100, 3, 160),
              "too-small buffer fails");
        CHECK(b.lastError() == kDspMicBadBuffer, "bad-buffer code");
        CHECK(bitIdentical(f.data(), before.data(), f.size() * 4),
              "too-small buffer untouched");
        CHECK(!b.processBuffer(reinterpret_cast<uint8_t*>(f.data()),
                               f.size() * 4, 0, 160),
              "0 bands rejected");
        CHECK(b.lastError() == kDspMicBadBandCount, "bad-band code");
        CHECK(!b.processBuffer(reinterpret_cast<uint8_t*>(f.data()),
                               f.size() * 4, 4, 160),
              "4 bands rejected");
        CHECK(!b.processBuffer(reinterpret_cast<uint8_t*>(f.data()),
                               f.size() * 4, 3, 0),
              "0 frames rejected");
        CHECK(b.lastError() == kDspMicBadFrameSize, "bad-frame code");
        CHECK(!b.processBuffer(nullptr, 1920, 3, 160),
              "null buffer rejected");
    }

    // ---- float sanity check: int16-as-float latches error 6 -------------
    {
        DspMicBridge b;
        CHECK(b.init(48000, 1), "init 48k");
        // int16 value 1 repeated, reinterpreted as float32: every
        // sample is a denormal (~1e-41) — the misrouting signature.
        std::vector<float> f(3 * 160);
        for (size_t i = 0; i < f.size(); ++i) {
            uint32_t bits = 0x00010001u;
            std::memcpy(&f[i], &bits, 4);
        }
        CHECK(!b.processFloat(f.data(), 3, 160),
              "denormal buffer must be rejected");
        CHECK(b.lastError() == kDspMicBadFormat, "bad-format code 6");
        // Latched: genuine float still refused until re-init.
        std::vector<float> good;
        splitToneFrame(good, 0.5f);
        CHECK(!b.processFloat(good.data(), 3, 160),
              "format failure latches until re-init");
        CHECK(b.init(48000, 1), "re-init clears the latch");
        CHECK(b.processFloat(good.data(), 3, 160),
              "genuine float works after re-init");
    }

    // ---- pending params: setEcho BEFORE init applies on first frame -----
    {
        DspMicBridge b;
        b.setEq(false, 0, 0, 0, 0);
        b.setEcho(true, 250.0f, 0.5f, 0.5f);  // before init!
        CHECK(b.init(48000, 1), "init 48k");
        std::vector<float> f(480, 0.0f);
        f[0] = 0.9f;
        CHECK(b.processBuffer(reinterpret_cast<uint8_t*>(f.data()),
                              f.size() * 4, 1, 480),
              "impulse frame processes");
        float echoPeak = 0.0f;
        for (int k = 1; k <= 25; ++k) {
            std::vector<float> s(480, 0.0f);
            b.processBuffer(reinterpret_cast<uint8_t*>(s.data()),
                            s.size() * 4, 1, 480);
            if (k == 25) echoPeak = peak(s.data(), 480);
        }
        CHECK(echoPeak > 0.3f,
              "pre-init echo preset applied (peak %.3f)", echoPeak);
    }

    // ---- layout change split -> full-band reconfigures engine 0 ---------
    {
        DspMicBridge b;
        CHECK(b.init(48000, 1), "init 48k");
        b.setEq(true, 0.0f, 0.0f, 6.0f, 0.0f);
        std::vector<float> split;
        splitToneFrame(split, 0.5f);
        CHECK(b.processBuffer(reinterpret_cast<uint8_t*>(split.data()),
                              split.size() * 4, 3, 160),
              "split frame processes");
        CHECK(b.engineSampleRate() == 16000, "split: engine at 16k");
        std::vector<float> full(480);
        tone(full.data(), 480, 1000.0f, 48000.0f, 0.5f);
        CHECK(b.processBuffer(reinterpret_cast<uint8_t*>(full.data()),
                              full.size() * 4, 1, 480),
              "full-band frame after split processes");
        CHECK(b.engineSampleRate() == 48000,
              "full-band: engine back at 48k, got %d",
              b.engineSampleRate());
        // The EQ preset survived the rate change (re-applied).
        CHECK(peak(full.data(), 480) > 0.75f,
              "EQ still applied after rate change (peak %.3f)",
              peak(full.data(), 480));
    }

    // ---- soundboard clip mixing (route A) ------------------------------
    {
        // Load validation.
        DspMicBridge b;
        CHECK(b.init(48000, 1), "sb: init 48k");
        CHECK(!b.loadClip(nullptr, 100, 48000), "sb: null clip rejected");
        const std::vector<float> empty;
        CHECK(!b.loadClip(empty.data(), 0, 48000),
              "sb: empty clip rejected");
        const std::vector<float> tone48k =
            clip48kTone(1000.0f, 0.8f, 1.0f);
        CHECK(!b.loadClip(tone48k.data(), tone48k.size(), 44100),
              "sb: non-48k rate rejected");
        CHECK(b.loadClip(tone48k.data(), tone48k.size(), 48000),
              "sb: 48k clip loads");
        CHECK(b.clipLength16k() == 16000, "sb: 16k length 16000, got %zu",
              b.clipLength16k());
        CHECK(!b.isClipPlaying(), "sb: idle before play");
    }

    {
        // Play without a loaded clip is a no-op.
        DspMicBridge b;
        CHECK(b.init(48000, 1), "sb: init 48k");
        b.playClip(1.0f);
        std::vector<float> f;
        splitSilence(f);
        CHECK(b.processBuffer(reinterpret_cast<uint8_t*>(f.data()),
                              f.size() * 4, 3, 160),
              "sb: frame processes with no clip");
        CHECK(!b.isClipPlaying(), "sb: still idle, no clip loaded");
        CHECK(peak(f.data(), 480) == 0.0f, "sb: silence untouched");
    }

    {
        // Decimation passband + mix: 1 kHz tone survives to band 0.
        DspMicBridge b;
        CHECK(b.init(48000, 1), "sb: init 48k");
        const std::vector<float> tone48k =
            clip48kTone(1000.0f, 0.8f, 1.0f);
        CHECK(b.loadClip(tone48k.data(), tone48k.size(), 48000),
              "sb: tone clip loads");
        b.playClip(1.0f);
        float steadyPeak = 0.0f;
        for (int k = 0; k < 10; ++k) {
            std::vector<float> f;
            splitSilence(f);
            CHECK(b.processBuffer(reinterpret_cast<uint8_t*>(f.data()),
                                  f.size() * 4, 3, 160),
                  "sb: split frame %d processes", k);
            if (k >= 3) {
                steadyPeak = std::max(steadyPeak, peak(f.data(), 160));
            }
            // Bands 1-2 stay bit-identical silence: the clip only
            // ever touches band 0.
            CHECK(peak(f.data() + 160, 320) == 0.0f,
                  "sb: bands 1-2 untouched on frame %d", k);
        }
        CHECK(b.isClipPlaying(), "sb: playing after 10 frames");
        CHECK(steadyPeak > 0.72f && steadyPeak <= 0.84f,
              "sb: 1 kHz survives decimation+mix (peak %.3f)", steadyPeak);
    }

    {
        // Decimation stopband: a 12 kHz tone is (nearly) gone — the
        // FIR keeps ultrasonic content from aliasing into band 0.
        DspMicBridge b;
        CHECK(b.init(48000, 1), "sb: init 48k");
        const std::vector<float> tone48k =
            clip48kTone(12000.0f, 0.8f, 1.0f);
        CHECK(b.loadClip(tone48k.data(), tone48k.size(), 48000),
              "sb: 12k clip loads");
        b.playClip(1.0f);
        float steadyPeak = 0.0f;
        for (int k = 0; k < 10; ++k) {
            std::vector<float> f;
            splitSilence(f);
            b.processBuffer(reinterpret_cast<uint8_t*>(f.data()),
                            f.size() * 4, 3, 160);
            if (k >= 3) {
                steadyPeak = std::max(steadyPeak, peak(f.data(), 160));
            }
        }
        CHECK(steadyPeak < 0.08f,
              "sb: 12 kHz attenuated by the FIR (peak %.4f)", steadyPeak);
    }

    {
        // Timing alignment: an impulse at 48k sample 3000 lands at
        // 16k sample 1000 (frame 6, offset 40) — the 3:1 decimation
        // keeps the clip time-aligned, no off-by-one.
        DspMicBridge b;
        CHECK(b.init(48000, 1), "sb: init 48k");
        std::vector<float> impulse(48000, 0.0f);
        impulse[3000] = 1.0f;
        CHECK(b.loadClip(impulse.data(), impulse.size(), 48000),
              "sb: impulse clip loads");
        b.playClip(1.0f);
        float prePeak = 0.0f;
        float postPeak = 0.0f;
        float frame6Peak = 0.0f;
        int frame6Argmax = -1;
        for (int k = 0; k < 10; ++k) {
            std::vector<float> f;
            splitSilence(f);
            b.processBuffer(reinterpret_cast<uint8_t*>(f.data()),
                            f.size() * 4, 3, 160);
            const float p = peak(f.data(), 160);
            if (k < 6) {
                prePeak = std::max(prePeak, p);
            } else if (k == 6) {
                frame6Peak = p;
                for (int i = 0; i < 160; ++i) {
                    if (std::fabs(f[i]) == p) frame6Argmax = i;
                }
            } else {
                postPeak = std::max(postPeak, p);
            }
        }
        CHECK(prePeak < 0.05f, "sb: nothing before frame 6 (%.4f)",
              prePeak);
        CHECK(postPeak < 0.05f, "sb: nothing after frame 6 (%.4f)",
              postPeak);
        CHECK(frame6Peak > 0.15f, "sb: impulse lands in frame 6 (%.3f)",
              frame6Peak);
        CHECK(frame6Argmax >= 38 && frame6Argmax <= 42,
              "sb: impulse at offset 40, got %d", frame6Argmax);
    }

    {
        // Content + playhead: a ramp clip advances 160 samples/frame
        // in band 0 (split layout).
        DspMicBridge b;
        CHECK(b.init(48000, 1), "sb: init 48k");
        const std::vector<float> ramp = clip48kRamp(1.0f);
        CHECK(b.loadClip(ramp.data(), ramp.size(), 48000),
              "sb: ramp clip loads");
        b.playClip(1.0f);
        for (int k = 0; k < 6; ++k) {
            std::vector<float> f;
            splitSilence(f);
            b.processBuffer(reinterpret_cast<uint8_t*>(f.data()),
                            f.size() * 4, 3, 160);
            if (k == 0) {
                CHECK(std::fabs(f[0]) < 0.01f,
                      "sb: ramp starts at 0 (%.4f)", f[0]);
            }
            if (k == 5) {
                // Frame 5 starts at 16k sample 800 = 5% through.
                CHECK(std::fabs(f[0] - 0.05f) < 0.005f,
                      "sb: playhead at 5%% on frame 5 (%.4f)", f[0]);
            }
        }
        CHECK(b.isClipPlaying(), "sb: ramp still playing");
    }

    {
        // Clip ends mid-frame: the rest of the frame is untouched mic.
        DspMicBridge b;
        CHECK(b.init(48000, 1), "sb: init 48k");
        // 600 samples @48k = 200 @16k = 1.25 frames of constant 0.5.
        const std::vector<float> shortClip =
            clip48kConstant(0.5f, 600.0f / 48000.0f);
        CHECK(b.loadClip(shortClip.data(), shortClip.size(), 48000),
              "sb: short clip loads");
        CHECK(b.clipLength16k() == 200, "sb: short clip is 200 @16k");
        b.playClip(1.0f);
        std::vector<float> f0;
        splitSilence(f0);
        b.processBuffer(reinterpret_cast<uint8_t*>(f0.data()),
                        f0.size() * 4, 3, 160);
        // The FIR's Gibbs overshoot at the clip-start step (a constant
        // clip is the pathological worst case — real SFX start near
        // silence) puts a one-sample ~7% bump at decimated sample 1
        // (0.536, reproduced exactly by an independent Python
        // replication of the filter); the steady part is 0.5.
        CHECK(peak(f0.data(), 160) < 0.6f,
              "sb: frame 0 edge overshoot bounded (peak %.3f)",
              peak(f0.data(), 160));
        CHECK(std::fabs(peak(f0.data() + 20, 140) - 0.5f) < 0.01f,
              "sb: frame 0 steady part mixed (peak %.3f)",
              peak(f0.data() + 20, 140));
        CHECK(b.isClipPlaying(), "sb: still playing after frame 0");
        std::vector<float> f1;
        splitSilence(f1);
        b.processBuffer(reinterpret_cast<uint8_t*>(f1.data()),
                        f1.size() * 4, 3, 160);
        // First 40 = decimated samples 160-199; the last few carry
        // the clip-end Gibbs bump (0.522 in the Python replication),
        // so the steady check stops at sample 194.
        CHECK(peak(f1.data(), 40) < 0.6f,
              "sb: frame 1 edge overshoot bounded (peak %.3f)",
              peak(f1.data(), 40));
        CHECK(std::fabs(peak(f1.data(), 35) - 0.5f) < 0.01f,
              "sb: frame 1 first 35 steady (peak %.3f)",
              peak(f1.data(), 35));
        CHECK(peak(f1.data() + 40, 120) == 0.0f,
              "sb: frame 1 tail untouched mic (peak %.4f)",
              peak(f1.data() + 40, 120));
        CHECK(!b.isClipPlaying(), "sb: finished after frame 1");
        std::vector<float> f2;
        splitSilence(f2);
        b.processBuffer(reinterpret_cast<uint8_t*>(f2.data()),
                        f2.size() * 4, 3, 160);
        CHECK(peak(f2.data(), 480) == 0.0f,
              "sb: frame 2 has no clip");
    }

    {
        // Gain 0: the mic stays bit-identical, but the clip still
        // finishes on time.
        DspMicBridge b;
        CHECK(b.init(48000, 1), "sb: init 48k");
        const std::vector<float> tone48k =
            clip48kTone(1000.0f, 0.8f, 1.0f);
        CHECK(b.loadClip(tone48k.data(), tone48k.size(), 48000),
              "sb: tone clip loads");
        b.playClip(0.0f);
        DspMicBridge ref;
        CHECK(ref.init(48000, 1), "sb: ref init");
        for (int k = 0; k < 3; ++k) {
            std::vector<float> f, r;
            splitToneFrame(f, 0.5f);
            r = f;
            b.processBuffer(reinterpret_cast<uint8_t*>(f.data()),
                            f.size() * 4, 3, 160);
            ref.processBuffer(reinterpret_cast<uint8_t*>(r.data()),
                              r.size() * 4, 3, 160);
            CHECK(bitIdentical(f.data(), r.data(), f.size() * 4),
                  "sb: gain-0 frame %d bit-identical to no-clip", k);
        }
        // Run the 1 s clip out at gain 0: it must still finish.
        for (int k = 0; k < 100; ++k) {
            std::vector<float> f;
            splitSilence(f);
            b.processBuffer(reinterpret_cast<uint8_t*>(f.data()),
                            f.size() * 4, 3, 160);
        }
        CHECK(!b.isClipPlaying(), "sb: gain-0 clip finished on time");
    }

    {
        // stopClip halts mid-play; playClip restarts from the top.
        DspMicBridge b;
        CHECK(b.init(48000, 1), "sb: init 48k");
        const std::vector<float> ramp = clip48kRamp(1.0f);
        CHECK(b.loadClip(ramp.data(), ramp.size(), 48000),
              "sb: ramp clip loads");
        b.playClip(1.0f);
        for (int k = 0; k < 5; ++k) {
            std::vector<float> f;
            splitSilence(f);
            b.processBuffer(reinterpret_cast<uint8_t*>(f.data()),
                            f.size() * 4, 3, 160);
        }
        b.stopClip();
        std::vector<float> stopped;
        splitSilence(stopped);
        b.processBuffer(reinterpret_cast<uint8_t*>(stopped.data()),
                        stopped.size() * 4, 3, 160);
        CHECK(peak(stopped.data(), 480) == 0.0f,
              "sb: stopped frame has no clip");
        CHECK(!b.isClipPlaying(), "sb: idle after stop");
        b.playClip(1.0f);
        std::vector<float> restarted;
        splitSilence(restarted);
        b.processBuffer(reinterpret_cast<uint8_t*>(restarted.data()),
                        restarted.size() * 4, 3, 160);
        CHECK(std::fabs(restarted[0]) < 0.01f,
              "sb: restart begins at clip start (%.4f)", restarted[0]);
        CHECK(b.isClipPlaying(), "sb: playing after restart");
    }

    {
        // Post-DSP ordering: +6 dB mid EQ boosts the MIC tone ~2x but
        // leaves the clip at its own level — the SFX never passes
        // through the voice chain.
        DspMicBridge b;
        CHECK(b.init(48000, 1), "sb: init 48k");
        b.setEq(true, 0.0f, 0.0f, 6.0f, 0.0f);
        const std::vector<float> tone48k =
            clip48kTone(1000.0f, 0.5f, 1.0f);
        CHECK(b.loadClip(tone48k.data(), tone48k.size(), 48000),
              "sb: tone clip loads");
        b.playClip(1.0f);
        float steadyPeak = 0.0f;
        for (int k = 0; k < 6; ++k) {
            std::vector<float> f;
            splitSilence(f);
            b.processBuffer(reinterpret_cast<uint8_t*>(f.data()),
                            f.size() * 4, 3, 160);
            if (k >= 3) {
                steadyPeak = std::max(steadyPeak, peak(f.data(), 160));
            }
        }
        CHECK(steadyPeak > 0.45f && steadyPeak < 0.55f,
              "sb: clip NOT EQ-boosted (peak %.3f, EQ would give ~1.0)",
              steadyPeak);
    }

    {
        // Full-band 48 kHz (1 x 480): the 48k variant mixes, 480/frame.
        DspMicBridge b;
        CHECK(b.init(48000, 1), "sb: init 48k");
        const std::vector<float> ramp = clip48kRamp(1.0f);
        CHECK(b.loadClip(ramp.data(), ramp.size(), 48000),
              "sb: ramp clip loads");
        b.playClip(1.0f);
        std::vector<float> f0(480, 0.0f);
        CHECK(b.processBuffer(reinterpret_cast<uint8_t*>(f0.data()),
                              f0.size() * 4, 1, 480),
              "sb: full-band frame 0 processes");
        CHECK(std::fabs(f0[0]) < 0.01f, "sb: full-band starts at 0");
        std::vector<float> f1(480, 0.0f);
        b.processBuffer(reinterpret_cast<uint8_t*>(f1.data()),
                        f1.size() * 4, 1, 480);
        // Frame 1 starts at 48k sample 480 = 1% through the ramp.
        CHECK(std::fabs(f1[0] - 0.01f) < 0.005f,
              "sb: full-band playhead 480/frame (%.4f)", f1[0]);
    }

    {
        // Full-band 16 kHz (1 x 160 @16k init): the 16k variant mixes.
        DspMicBridge b;
        CHECK(b.init(16000, 1), "sb: init 16k");
        const std::vector<float> c =
            clip48kConstant(0.5f, 1.0f);
        CHECK(b.loadClip(c.data(), c.size(), 48000),
              "sb: constant clip loads");
        b.playClip(1.0f);
        std::vector<float> f0(160, 0.0f);
        CHECK(b.processBuffer(reinterpret_cast<uint8_t*>(f0.data()),
                              f0.size() * 4, 1, 160),
              "sb: 16k full-band frame processes");
        // Skip the FIR edge (first ~15 samples ramp up); the rest of
        // the frame is the steady 0.5.
        CHECK(std::fabs(peak(f0.data() + 20, 140) - 0.5f) < 0.01f,
              "sb: 16k full-band mixes the 16k variant (peak %.3f)",
              peak(f0.data() + 20, 140));
    }

    {
        // Int16 split-band path: band 0 gets the clip, bands 1-2 stay
        // bit-identical.
        DspMicBridge b;
        CHECK(b.init(48000, 1), "sb: init 48k");
        const std::vector<float> c = clip48kConstant(0.5f, 1.0f);
        CHECK(b.loadClip(c.data(), c.size(), 48000),
              "sb: constant clip loads");
        b.playClip(1.0f);
        std::vector<uint8_t> bytes;
        splitSilencePcm16(bytes);
        const std::vector<uint8_t> before = bytes;
        CHECK(b.processBuffer(bytes.data(), bytes.size(), 3, 160),
              "sb: int16 split frame processes");
        CHECK(b.lastFormatBytesPerSample() == 2, "sb: int16 format");
        // Steady part of band 0 (skip the FIR edge): 0.5 -> 16383.
        const int16_t v = readPcm16(bytes, 100);
        CHECK(v >= 16381 && v <= 16385,
              "sb: int16 band 0 mixed (sample 100 = %d)", v);
        CHECK(bitIdentical(bytes.data() + 320, before.data() + 320,
                           bytes.size() - 320),
              "sb: int16 bands 1-2 bit-identical");
    }

    {
        // Soft-limit: loud mic + loud clip never wraps (float + int16).
        DspMicBridge b;
        CHECK(b.init(48000, 1), "sb: init 48k");
        const std::vector<float> c = clip48kConstant(0.9f, 1.0f);
        CHECK(b.loadClip(c.data(), c.size(), 48000),
              "sb: loud clip loads");
        b.playClip(1.0f);
        std::vector<float> f(3 * 160, 0.9f);
        b.processBuffer(reinterpret_cast<uint8_t*>(f.data()),
                        f.size() * 4, 3, 160);
        const float p = peak(f.data(), 160);
        CHECK(p <= 1.0f && p > 0.99f,
              "sb: float mix soft-limited, no wrap (peak %.4f)", p);
        std::vector<uint8_t> bytes(3 * 160 * 2, 0);
        for (size_t i = 0; i < 3 * 160; ++i) {
            const int16_t s = 29491;  // ~0.9
            bytes[i * 2] = static_cast<uint8_t>(s & 0xFF);
            bytes[i * 2 + 1] = static_cast<uint8_t>((s >> 8) & 0xFF);
        }
        b.processBuffer(bytes.data(), bytes.size(), 3, 160);
        const int16_t v = readPcm16(bytes, 100);
        CHECK(v > 29000 && v <= 32767,
              "sb: int16 mix soft-limited, no wrap (%d)", v);
    }

    {
        // Live gain: setClipGain applies on the next frame.
        DspMicBridge b;
        CHECK(b.init(48000, 1), "sb: init 48k");
        const std::vector<float> c = clip48kConstant(0.5f, 1.0f);
        CHECK(b.loadClip(c.data(), c.size(), 48000),
              "sb: constant clip loads");
        b.playClip(1.0f);
        for (int k = 0; k < 2; ++k) {
            std::vector<float> f;
            splitSilence(f);
            b.processBuffer(reinterpret_cast<uint8_t*>(f.data()),
                            f.size() * 4, 3, 160);
        }
        b.setClipGain(0.25f);
        std::vector<float> f;
        splitSilence(f);
        b.processBuffer(reinterpret_cast<uint8_t*>(f.data()),
                        f.size() * 4, 3, 160);
        CHECK(std::fabs(peak(f.data(), 160) - 0.125f) < 0.01f,
              "sb: gain change applies live (peak %.3f)",
              peak(f.data(), 160));
    }

    {
        // Loading a new clip stops the playing one; the new clip does
        // not auto-play.
        DspMicBridge b;
        CHECK(b.init(48000, 1), "sb: init 48k");
        const std::vector<float> c = clip48kConstant(0.5f, 1.0f);
        CHECK(b.loadClip(c.data(), c.size(), 48000), "sb: clip 1 loads");
        b.playClip(1.0f);
        std::vector<float> f;
        splitSilence(f);
        b.processBuffer(reinterpret_cast<uint8_t*>(f.data()),
                        f.size() * 4, 3, 160);
        CHECK(b.isClipPlaying(), "sb: playing before reload");
        const std::vector<float> c2 = clip48kConstant(0.25f, 1.0f);
        CHECK(b.loadClip(c2.data(), c2.size(), 48000),
              "sb: clip 2 loads");
        std::vector<float> g;
        splitSilence(g);
        b.processBuffer(reinterpret_cast<uint8_t*>(g.data()),
                        g.size() * 4, 3, 160);
        CHECK(!b.isClipPlaying(), "sb: load stopped playback");
        CHECK(peak(g.data(), 480) == 0.0f,
              "sb: new clip does not auto-play");
    }

    {
        // Bypass pauses the clip (playhead frozen) and it resumes
        // where it paused when bypass lifts.
        DspMicBridge b;
        CHECK(b.init(48000, 1), "sb: init 48k");
        const std::vector<float> ramp = clip48kRamp(1.0f);
        CHECK(b.loadClip(ramp.data(), ramp.size(), 48000),
              "sb: ramp clip loads");
        b.playClip(1.0f);
        std::vector<float> f0;
        splitSilence(f0);
        b.processBuffer(reinterpret_cast<uint8_t*>(f0.data()),
                        f0.size() * 4, 3, 160);
        b.setBypass(true);
        for (int k = 0; k < 3; ++k) {
            std::vector<float> f;
            splitSilence(f);
            b.processBuffer(reinterpret_cast<uint8_t*>(f.data()),
                            f.size() * 4, 3, 160);
            CHECK(peak(f.data(), 480) == 0.0f,
                  "sb: bypassed frame %d has no clip", k);
        }
        CHECK(b.isClipPlaying(), "sb: still playing (paused) in bypass");
        b.setBypass(false);
        std::vector<float> resumed;
        splitSilence(resumed);
        b.processBuffer(reinterpret_cast<uint8_t*>(resumed.data()),
                        resumed.size() * 4, 3, 160);
        // Resumes at frame 1's position (16k sample 160 = 1%).
        CHECK(std::fabs(resumed[0] - 0.01f) < 0.005f,
              "sb: resumes where it paused (%.4f)", resumed[0]);
    }

    {
        // Layout change mid-play keeps the TIME position: 5 split
        // frames (50 ms in) then a full-band 48k frame reads the 48k
        // clip at 50 ms, not from the start and not at the wrong rate.
        DspMicBridge b;
        CHECK(b.init(48000, 1), "sb: init 48k");
        const std::vector<float> ramp = clip48kRamp(1.0f);
        CHECK(b.loadClip(ramp.data(), ramp.size(), 48000),
              "sb: ramp clip loads");
        b.playClip(1.0f);
        for (int k = 0; k < 5; ++k) {
            std::vector<float> f;
            splitSilence(f);
            b.processBuffer(reinterpret_cast<uint8_t*>(f.data()),
                            f.size() * 4, 3, 160);
        }
        std::vector<float> full(480, 0.0f);
        CHECK(b.processBuffer(reinterpret_cast<uint8_t*>(full.data()),
                              full.size() * 4, 1, 480),
              "sb: full-band frame after split processes");
        CHECK(std::fabs(full[0] - 0.05f) < 0.005f,
              "sb: time position survives layout change (%.4f)", full[0]);
    }

    {
        // 1-band 32 kHz (synthetic only): no variant — no mix, no
        // playhead advance, still playing.
        DspMicBridge b;
        CHECK(b.init(32000, 1), "sb: init 32k");
        const std::vector<float> c = clip48kConstant(0.5f, 1.0f);
        CHECK(b.loadClip(c.data(), c.size(), 48000),
              "sb: constant clip loads");
        b.playClip(1.0f);
        std::vector<float> f(320, 0.0f);
        CHECK(b.processBuffer(reinterpret_cast<uint8_t*>(f.data()),
                              f.size() * 4, 1, 320),
              "sb: 1-band 32k frame processes");
        CHECK(peak(f.data(), 320) == 0.0f,
              "sb: no mix at 1-band 32k");
        CHECK(b.isClipPlaying(), "sb: still playing (paused) at 32k");
    }

    {
        // release() drops the clip: after re-init nothing plays
        // until a fresh load.
        DspMicBridge b;
        CHECK(b.init(48000, 1), "sb: init 48k");
        const std::vector<float> c = clip48kConstant(0.5f, 1.0f);
        CHECK(b.loadClip(c.data(), c.size(), 48000),
              "sb: constant clip loads");
        b.playClip(1.0f);
        std::vector<float> f;
        splitSilence(f);
        b.processBuffer(reinterpret_cast<uint8_t*>(f.data()),
                        f.size() * 4, 3, 160);
        CHECK(b.isClipPlaying(), "sb: playing before release");
        b.release();
        CHECK(!b.isClipPlaying(), "sb: idle after release");
        CHECK(b.clipLength16k() == 0, "sb: clip dropped by release");
        CHECK(b.init(48000, 1), "sb: re-init after release");
        std::vector<float> g;
        splitSilence(g);
        b.processBuffer(reinterpret_cast<uint8_t*>(g.data()),
                        g.size() * 4, 3, 160);
        CHECK(peak(g.data(), 480) == 0.0f,
              "sb: nothing plays after re-init without reload");
    }

    std::printf("\nRJ bridge checks: %d passed, %d failed\n", g_pass,
                g_fail);
    return g_fail == 0 ? 0 : 1;
}
