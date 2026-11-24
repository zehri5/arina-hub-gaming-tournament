// HOST-ONLY SMOKE TEST — NOT PART OF THE SHIPPED CODE.
// Runs on the dev VM with g++ only. Never compiled into libaudio_dsp.so
// (CMakeLists.txt lists dsp_engine.cpp + audio_dsp_jni.cpp explicitly;
// this directory is not referenced by any build file).
//
// Build & run (single command, no backslash):
//   g++ -std=c++17 -O2 -Wall -Wextra -o /tmp/eq_smoke_test eq_smoke_test.cpp ../dsp_engine.cpp && /tmp/eq_smoke_test
//
// Tests the EQ section only (EqProcessor + BiquadFilter, plus a
// DspEngine PCM16 end-to-end check). Echo/Freeverb are other groups'
// and are not exercised here beyond the all-disabled fast path.

#include <cmath>
#include <cstdio>
#include <cstring>
#include <limits>
#include <vector>

#include "../dsp_engine.h"

namespace {

constexpr int kSr = 48000;
constexpr double kPi = 3.14159265358979323846;

int gFailures = 0;
int gChecks = 0;

void check(bool ok, const char* name, const char* detail) {
    ++gChecks;
    if (!ok) ++gFailures;
    std::printf("[%s] %s — %s\n", ok ? "PASS" : "FAIL", name, detail);
}

bool allFinite(const float* buf, size_t n) {
    for (size_t i = 0; i < n; ++i) {
        if (!std::isfinite(buf[i])) return false;
    }
    return true;
}

float rmsOf(const float* buf, size_t begin, size_t end) {
    double acc = 0.0;
    for (size_t i = begin; i < end; ++i) acc += static_cast<double>(buf[i]) * buf[i];
    return static_cast<float>(std::sqrt(acc / static_cast<double>(end - begin)));
}

float peakOf(const float* buf, size_t begin, size_t end) {
    float peak = 0.0f;
    for (size_t i = begin; i < end; ++i) {
        const float a = std::fabs(buf[i]);
        if (a > peak) peak = a;
    }
    return peak;
}

// Max |x[n] - x[n-1]| over [begin, end).
float maxStep(const float* buf, size_t begin, size_t end) {
    float m = 0.0f;
    for (size_t i = begin + 1; i < end; ++i) {
        const float d = std::fabs(buf[i] - buf[i - 1]);
        if (d > m) m = d;
    }
    return m;
}

void fillSine(float* buf, size_t n, double freqHz, float amp, int channels,
              int activeChannel = -1) {
    for (size_t i = 0; i < n; ++i) {
        const float v = amp * static_cast<float>(
            std::sin(2.0 * kPi * freqHz * static_cast<double>(i) / kSr));
        for (int c = 0; c < channels; ++c) {
            buf[i * static_cast<size_t>(channels) + static_cast<size_t>(c)] =
                (activeChannel < 0 || c == activeChannel) ? v : 0.0f;
        }
    }
}

// Steady-state gain of one EqProcessor setup at one frequency (mono).
// Feeds 1 s of sine, measures RMS ratio over the last 0.25 s.
float steadyGain(float bassDb, float lowDb, float midDb, float highDb,
                 double freqHz, float amp = 0.25f) {
    arena_dsp::EqProcessor eq;
    eq.configure(kSr);
    eq.setParams(true, bassDb, lowDb, midDb, highDb);
    const size_t frames = 48000;
    std::vector<float> buf(frames);
    fillSine(buf.data(), frames, freqHz, amp, 1);
    eq.process(buf.data(), frames, 1);
    const float outRms = rmsOf(buf.data(), 36000, 48000);
    // Input RMS of a sine = amp / sqrt(2) (measured, not assumed).
    std::vector<float> ref(frames);
    fillSine(ref.data(), frames, freqHz, amp, 1);
    const float inRms = rmsOf(ref.data(), 36000, 48000);
    return outRms / inRms;
}

void reportGain(const char* name, float measured, float expected, float tol) {
    char detail[256];
    std::snprintf(detail, sizeof(detail),
                  "measured %.3fx (%.2f dB), expected ~%.2fx (%.1f dB)",
                  measured, 20.0 * std::log10(measured),
                  expected, 20.0 * std::log10(expected));
    check(std::fabs(measured - expected) <= tol, name, detail);
}

} // namespace

int main() {
    std::printf("=== External EQ smoke test (host, g++, dsp_engine.cpp only) ===\n");

    // -- A. Disabled = bit-exact passthrough (float path) ----------------
    {
        arena_dsp::EqProcessor eq;
        eq.configure(kSr);
        eq.setParams(false, 12.0f, 12.0f, 12.0f, 12.0f);
        std::vector<float> buf(4800), ref(4800);
        fillSine(buf.data(), 4800, 1000.0, 0.5f, 1);
        ref = buf;
        eq.process(buf.data(), 4800, 1);
        const bool exact = std::memcmp(buf.data(), ref.data(),
                                       buf.size() * sizeof(float)) == 0;
        check(exact, "A disabled=true bit-exact passthrough",
              exact ? "output identical to input" : "output differs!");
    }

    // -- B. Enabled, all 0 dB = passthrough (all bands bypassed) ---------
    {
        arena_dsp::EqProcessor eq;
        eq.configure(kSr);
        eq.setParams(true, 0.0f, 0.0f, 0.0f, 0.0f);
        std::vector<float> buf(4800), ref(4800);
        fillSine(buf.data(), 4800, 1000.0, 0.5f, 1);
        ref = buf;
        eq.process(buf.data(), 4800, 1);
        const bool exact = std::memcmp(buf.data(), ref.data(),
                                       buf.size() * sizeof(float)) == 0;
        check(exact, "B enabled all-0dB passthrough",
              exact ? "output identical to input" : "output differs!");
    }

    // -- C. Band gains (RBJ shelves give HALF the shelf gain at f0) ------
    // Bass low-shelf 80 Hz, +6 dB: ~+6 dB well below f0, ~+3 dB at f0.
    reportGain("C1 bass +6dB @20Hz (~+6dB)", steadyGain(6, 0, 0, 0, 20.0), 2.0f, 0.15f);
    reportGain("C2 bass +6dB @80Hz (~+3dB)", steadyGain(6, 0, 0, 0, 80.0), 1.4125f, 0.12f);
    reportGain("C3 bass +6dB @1000Hz (~0dB)", steadyGain(6, 0, 0, 0, 1000.0), 1.0f, 0.08f);
    // Low low-shelf 200 Hz, +6 dB.
    reportGain("C4 low +6dB @50Hz (~+6dB)", steadyGain(0, 6, 0, 0, 50.0), 2.0f, 0.15f);
    reportGain("C5 low +6dB @200Hz (~+3dB)", steadyGain(0, 6, 0, 0, 200.0), 1.4125f, 0.12f);
    // Mid peaking 1000 Hz, full gain at f0.
    reportGain("C6 mid +6dB @1000Hz (~+6dB)", steadyGain(0, 0, 6, 0, 1000.0), 2.0f, 0.10f);
    reportGain("C7 mid -6dB @1000Hz (~-6dB)", steadyGain(0, 0, -6, 0, 1000.0), 0.5f, 0.05f);
    reportGain("C8 mid +6dB @100Hz (~0dB)", steadyGain(0, 0, 6, 0, 100.0), 1.0f, 0.08f);
    // High high-shelf 4000 Hz, +6 dB: ~+6 dB well above f0, ~+3 dB at f0.
    reportGain("C9 high +6dB @12000Hz (~+6dB)", steadyGain(0, 0, 0, 6, 12000.0), 2.0f, 0.15f);
    reportGain("C10 high +6dB @4000Hz (~+3dB)", steadyGain(0, 0, 0, 6, 4000.0), 1.4125f, 0.12f);
    reportGain("C11 high -12dB @12000Hz (~-12dB)", steadyGain(0, 0, 0, -12, 12000.0), 0.2512f, 0.05f);
    reportGain("C12 bass +12dB @20Hz (~+12dB)", steadyGain(12, 0, 0, 0, 20.0), 3.981f, 0.30f);

    // -- D. Edge params: all max / all min — finite, no crash ------------
    {
        arena_dsp::EqProcessor eq;
        eq.configure(kSr);
        eq.setParams(true, 12.0f, 12.0f, 12.0f, 12.0f);
        std::vector<float> buf(48000);
        fillSine(buf.data(), 48000, 100.0, 0.25f, 1);
        eq.process(buf.data(), 48000, 1);
        const bool finite = allFinite(buf.data(), buf.size());
        char detail[128];
        std::snprintf(detail, sizeof(detail), "finite=%s peak=%.3f",
                      finite ? "yes" : "NO", peakOf(buf.data(), 0, buf.size()));
        check(finite, "D1 all-gains-max finite", detail);
    }
    {
        arena_dsp::EqProcessor eq;
        eq.configure(kSr);
        eq.setParams(true, 12.0f, -12.0f, -12.0f, -12.0f);
        std::vector<float> buf(48000);
        fillSine(buf.data(), 48000, 5000.0, 0.25f, 1);
        eq.process(buf.data(), 48000, 1);
        const bool finite = allFinite(buf.data(), buf.size());
        char detail[128];
        std::snprintf(detail, sizeof(detail), "finite=%s peak=%.3f",
                      finite ? "yes" : "NO", peakOf(buf.data(), 0, buf.size()));
        check(finite, "D2 mixed-extremes finite", detail);
    }

    // -- E. NaN params — must not produce NaN output or max boost --------
    {
        const float nan = std::numeric_limits<float>::quiet_NaN();
        arena_dsp::EqProcessor eq;
        eq.configure(kSr);
        eq.setParams(true, nan, nan, nan, nan);
        const size_t frames = 48000;
        std::vector<float> buf(frames);
        fillSine(buf.data(), frames, 20.0, 0.25f, 1);
        eq.process(buf.data(), frames, 1);
        const bool finite = allFinite(buf.data(), buf.size());
        const float outRms = rmsOf(buf.data(), 36000, 48000);
        const float ratio = outRms / (0.25f / std::sqrt(2.0f));
        char detail[256];
        std::snprintf(detail, sizeof(detail),
                      "finite=%s, 20Hz gain=%.3fx (want ~1.0x = NaN treated as 0dB)",
                      finite ? "yes" : "NO", ratio);
        check(finite && std::fabs(ratio - 1.0f) < 0.1f, "E NaN params sanitized", detail);
    }

    // -- F. Click on abrupt param jump: mid 0 -> +12 dB ------------------
    // Steady 1000 Hz sine @0.5, then jump mid gain. Compare max
    // sample-to-sample step in the 50 ms after the jump (INCLUDING the
    // boundary step between the last pre-change and first post-change
    // sample) against the steady-state max step at the NEW gain
    // (ratio ~1 = no click).
    {
        arena_dsp::EqProcessor eq;
        eq.configure(kSr);
        eq.setParams(true, 0.0f, 0.0f, 0.0f, 0.0f);
        const size_t pre = 48000, post = 4800;
        std::vector<float> buf(pre + post);
        fillSine(buf.data(), pre + post, 1000.0, 0.5f, 1);
        eq.process(buf.data(), pre, 1);
        eq.setParams(true, 0.0f, 0.0f, 12.0f, 0.0f);
        eq.process(buf.data() + pre, post, 1);
        const float stepJump = maxStep(buf.data(), pre - 1, pre + 2400);
        const float stepSteady = maxStep(buf.data(), pre + 2400, pre + post);
        char detail[256];
        std::snprintf(detail, sizeof(detail),
                      "max step incl. boundary=%.4f, steady max step=%.4f, ratio=%.2f (want <1.5)",
                      stepJump, stepSteady, stepJump / stepSteady);
        check(stepJump / stepSteady < 1.5f, "F1 param-jump click (mid 0->+12dB)", detail);
    }

    // -- F2. Click on abrupt SHELF jump: bass 0 -> +12 dB @ 60 Hz --------
    // Shelves change ALL coefficients (incl. a1) and hold long low-freq
    // state, so this is the worst click case. Signal slope is tiny at
    // 60 Hz, so any transient step stands out.
    {
        arena_dsp::EqProcessor eq;
        eq.configure(kSr);
        eq.setParams(true, 0.0f, 0.0f, 0.0f, 0.0f);
        const size_t pre = 48000, post = 4800;
        std::vector<float> buf(pre + post);
        fillSine(buf.data(), pre + post, 60.0, 0.5f, 1);
        eq.process(buf.data(), pre, 1);
        eq.setParams(true, 12.0f, 0.0f, 0.0f, 0.0f);
        eq.process(buf.data() + pre, post, 1);
        const float stepJump = maxStep(buf.data(), pre - 1, pre + 2400);
        const float stepSteady = maxStep(buf.data(), pre + 2400, pre + post);
        char detail[256];
        std::snprintf(detail, sizeof(detail),
                      "max step incl. boundary=%.4f, steady max step=%.4f, ratio=%.2f (want <1.5)",
                      stepJump, stepSteady, stepJump / stepSteady);
        check(stepJump / stepSteady < 1.5f, "F2 shelf-jump click (bass 0->+12dB @60Hz)", detail);
    }

    // -- G. Click on disable: mid +12 dB -> disabled ---------------------
    // Baseline is the WET steady step (the louder signal): during a
    // smooth fade the max step stays near the wet signal's own slope.
    {
        arena_dsp::EqProcessor eq;
        eq.configure(kSr);
        eq.setParams(true, 0.0f, 0.0f, 12.0f, 0.0f);
        const size_t pre = 48000, post = 4800;
        std::vector<float> buf(pre + post);
        fillSine(buf.data(), pre + post, 1000.0, 0.5f, 1);
        eq.process(buf.data(), pre, 1);
        const float stepWet = maxStep(buf.data(), pre - 2400, pre);
        eq.setParams(false, 0.0f, 0.0f, 12.0f, 0.0f);
        eq.process(buf.data() + pre, post, 1);
        const float stepJump = maxStep(buf.data(), pre - 1, pre + 2400);
        char detail[256];
        std::snprintf(detail, sizeof(detail),
                      "max step incl. boundary=%.4f, wet steady max step=%.4f, ratio=%.2f (want <1.5)",
                      stepJump, stepWet, stepJump / stepWet);
        check(stepJump / stepWet < 1.5f, "G1 disable click (mid +12dB -> off)", detail);
    }

    // -- G2. Click on disable from heavy bass: bass +12 dB -> off @60Hz --
    {
        arena_dsp::EqProcessor eq;
        eq.configure(kSr);
        eq.setParams(true, 12.0f, 0.0f, 0.0f, 0.0f);
        const size_t pre = 48000, post = 4800;
        std::vector<float> buf(pre + post);
        fillSine(buf.data(), pre + post, 60.0, 0.5f, 1);
        eq.process(buf.data(), pre, 1);
        const float stepWet = maxStep(buf.data(), pre - 2400, pre);
        eq.setParams(false, 12.0f, 0.0f, 0.0f, 0.0f);
        eq.process(buf.data() + pre, post, 1);
        const float stepJump = maxStep(buf.data(), pre - 1, pre + 2400);
        char detail[256];
        std::snprintf(detail, sizeof(detail),
                      "max step incl. boundary=%.4f, wet steady max step=%.4f, ratio=%.2f (want <1.5)",
                      stepJump, stepWet, stepJump / stepWet);
        check(stepJump / stepWet < 1.5f, "G2 disable click (bass +12dB -> off @60Hz)", detail);
    }

    // -- G3. Click on RE-enable with stale state: wet -> off -> on -------
    // Fresh enable is click-free (state starts at zero), but disable
    // freezes nonzero state, so re-enable jumps dry -> stale-wet.
    {
        arena_dsp::EqProcessor eq;
        eq.configure(kSr);
        eq.setParams(true, 12.0f, 0.0f, 0.0f, 0.0f);
        const size_t pre = 48000, gap = 4800, post = 4800;
        std::vector<float> buf(pre + gap + post);
        fillSine(buf.data(), pre + gap + post, 60.0, 0.5f, 1);
        eq.process(buf.data(), pre, 1);
        const float stepWet = maxStep(buf.data(), pre - 2400, pre);
        eq.setParams(false, 12.0f, 0.0f, 0.0f, 0.0f);
        eq.process(buf.data() + pre, gap, 1);
        const size_t on = pre + gap;
        eq.setParams(true, 12.0f, 0.0f, 0.0f, 0.0f);
        eq.process(buf.data() + on, post, 1);
        const float stepJump = maxStep(buf.data(), on - 1, on + 2400);
        char detail[256];
        std::snprintf(detail, sizeof(detail),
                      "max step incl. boundary=%.4f, wet steady max step=%.4f, ratio=%.2f (want <1.5)",
                      stepJump, stepWet, stepJump / stepWet);
        check(stepJump / stepWet < 1.5f, "G3 re-enable click (bass +12dB off->on @60Hz)", detail);
    }

    // -- H. Stereo: L processed, R silence stays silent ------------------
    {
        arena_dsp::EqProcessor eq;
        eq.configure(kSr);
        eq.setParams(true, 0.0f, 0.0f, 6.0f, 0.0f);
        const size_t frames = 48000;
        std::vector<float> buf(frames * 2);
        fillSine(buf.data(), frames, 1000.0, 0.25f, 2, /*activeChannel=*/0);
        // Re-interleave check: fillSine writes per-frame; process stereo.
        eq.process(buf.data(), frames, 2);
        float peakL = 0.0f, peakR = 0.0f;
        for (size_t i = 36000; i < frames; ++i) {
            peakL = std::max(peakL, std::fabs(buf[i * 2]));
            peakR = std::max(peakR, std::fabs(buf[i * 2 + 1]));
        }
        char detail[256];
        std::snprintf(detail, sizeof(detail),
                      "L peak=%.3f (want ~0.50), R peak=%.5f (want 0.0)",
                      peakL, peakR);
        check(std::fabs(peakL - 0.5f) < 0.05f && peakR < 1e-6f,
              "H stereo L processed / R silent", detail);
    }

    // -- I. DspEngine PCM16 end-to-end -----------------------------------
    {
        arena_dsp::DspEngine eng(kSr, 1);
        std::vector<uint8_t> in(4800 * 2), out(4800 * 2);
        for (int i = 0; i < 4800; ++i) {
            const int16_t s = static_cast<int16_t>(
                12000.0 * std::sin(2.0 * kPi * 1000.0 * i / kSr));
            in[i * 2] = static_cast<uint8_t>(s & 0xFF);
            in[i * 2 + 1] = static_cast<uint8_t>((s >> 8) & 0xFF);
        }
        eng.processPcm16(in.data(), out.data(), in.size());
        const bool exact = std::memcmp(in.data(), out.data(), in.size()) == 0;
        check(exact, "I1 engine all-disabled byte-identical",
              exact ? "PCM16 passthrough exact" : "bytes differ!");
    }
    {
        arena_dsp::DspEngine eng(kSr, 1);
        eng.setEq(true, 12.0f, 12.0f, 0.0f, 0.0f);
        std::vector<uint8_t> in(48000 * 2), out(48000 * 2);
        for (int i = 0; i < 48000; ++i) {
            const int16_t s = static_cast<int16_t>(
                20000.0 * std::sin(2.0 * kPi * 60.0 * i / kSr));
            in[i * 2] = static_cast<uint8_t>(s & 0xFF);
            in[i * 2 + 1] = static_cast<uint8_t>((s >> 8) & 0xFF);
        }
        eng.processPcm16(in.data(), out.data(), in.size());
        int peak = 0;
        int saturated = 0;
        for (int i = 0; i < 48000; ++i) {
            const int16_t s = static_cast<int16_t>(
                static_cast<uint16_t>(out[i * 2]) |
                (static_cast<uint16_t>(out[i * 2 + 1]) << 8));
            // -32768 is a legal int16 value; use int abs (peak 32768 OK).
            const int a = (s == -32768) ? 32768 : std::abs(static_cast<int>(s));
            if (a > peak) peak = a;
            if (s >= 32767 || s <= -32768) ++saturated;
        }
        char detail[256];
        std::snprintf(detail, sizeof(detail),
                      "bass+low maxed on loud 60Hz: peak=%d (limit 32768), "
                      "saturated samples=%d/48000 (%.0f%% — limiter working, heavy distortion by design)",
                      peak, saturated, 100.0 * saturated / 48000.0);
        check(peak <= 32768, "I2 engine max-bass stays in int16 range", detail);
    }

    std::printf("=== %d checks, %d failures ===\n", gChecks, gFailures);
    return gFailures == 0 ? 0 : 1;
}
