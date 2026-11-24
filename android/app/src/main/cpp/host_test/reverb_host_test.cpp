// HOST-ONLY SMOKE TEST — NOT PART OF THE SHIPPED CODE.
//
// Runs the Freeverb section of dsp_engine.cpp on the host (x86_64 g++)
// with NO Android/JNI dependency. Build from this directory:
//
//   g++ -std=c++17 -O2 -Wall -Wextra -I.. -o /tmp/reverb_host_test
//       reverb_host_test.cpp ../dsp_engine.cpp
//
// Never add this directory to CMakeLists.txt and never ship it in the APK.
// Group 3 DSP adoption track, Arena Hub #10 audio, 2026-11-22.

#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <limits>
#include <vector>

#include "dsp_engine.h"

using arena_dsp::DspEngine;
using arena_dsp::FreeverbProcessor;

namespace {

int g_failures = 0;

void check(bool ok, const char* name) {
    std::printf("  [%s] %s\n", ok ? "PASS" : "FAIL", name);
    if (!ok) ++g_failures;
}

bool allFinite(const float* buf, size_t n) {
    for (size_t i = 0; i < n; ++i) {
        if (!std::isfinite(buf[i])) return false;
    }
    return true;
}

float peakAbs(const float* buf, size_t n) {
    float p = 0.0f;
    for (size_t i = 0; i < n; ++i) p = std::max(p, std::fabs(buf[i]));
    return p;
}

// RMS over [start, end) sample indices (interleaved buffer).
float rmsRange(const float* buf, size_t start, size_t end) {
    double acc = 0.0;
    for (size_t i = start; i < end; ++i) acc += static_cast<double>(buf[i]) * buf[i];
    const size_t n = end - start;
    return n == 0 ? 0.0f : static_cast<float>(std::sqrt(acc / static_cast<double>(n)));
}

constexpr int kSr = 48000;

// ---------------------------------------------------------------- T1: impulse
void testImpulseStereo() {
    std::printf("T1 impulse, stereo, mix=0.5 room=0.7 damp=0.3 (3s)\n");
    FreeverbProcessor rv;
    rv.configure(kSr);
    rv.setParams(true, 0.5f, 0.7f, 0.3f);

    const size_t frames = 144000;  // 3 s: RT60 at room 0.7 is ~1.7 s
    std::vector<float> buf(frames * 2, 0.0f);
    buf[0] = 1.0f;  // L impulse
    buf[1] = 1.0f;  // R impulse
    rv.process(buf.data(), frames, 2);

    check(allFinite(buf.data(), buf.size()), "output finite (no NaN/inf)");
    const float tailRms = rmsRange(buf.data(), 2400 * 2, frames * 2);  // tail after 50 ms
    std::printf("      tail RMS (50ms..3s) = %.6f\n", tailRms);
    check(tailRms > 1e-4f, "non-silent reverb tail");
    const float peak = peakAbs(buf.data(), buf.size());
    std::printf("      peak abs = %.4f\n", peak);
    check(peak < 2.0f, "peak bounded (< 2.0)");

    // Crude RT60: first 10 ms-window RMS to fall 60 dB below the
    // loudest early window (windows start at 50 ms).
    float earlyPeak = 0.0f;
    for (size_t f = 2400; f < 4800; f += 480) {
        earlyPeak = std::max(earlyPeak, rmsRange(buf.data(), f * 2, (f + 480) * 2));
    }
    float rt60 = -1.0f;
    for (size_t f = 4800; f + 480 <= frames; f += 480) {
        if (rmsRange(buf.data(), f * 2, (f + 480) * 2) < earlyPeak * 0.001f) {
            rt60 = static_cast<float>(f) / kSr;
            break;
        }
    }
    std::printf("      early-window RMS = %.6f, RT60 ~ %.2fs\n", earlyPeak, rt60);
    check(rt60 > 0.2f, "tail decays (RT60 measurable, > 0.2s)");

    // Stereo decorrelation: L and R tails must differ.
    double diff = 0.0;
    for (size_t f = 2400; f < frames; ++f) {
        const double d = buf[f * 2] - buf[f * 2 + 1];
        diff += d * d;
    }
    const float diffRms = static_cast<float>(std::sqrt(diff / (frames - 2400)));
    std::printf("      L-R tail difference RMS = %.6f\n", diffRms);
    check(diffRms > 1e-5f, "L/R tails decorrelated (stereo spread works)");
}

// ---------------------------------------------------------------- T2: sine
void testSineStereo() {
    std::printf("T2 full-scale-ish sine 440 Hz, stereo, mix=0.5 room=0.7 damp=0.3 (1s)\n");
    FreeverbProcessor rv;
    rv.configure(kSr);
    rv.setParams(true, 0.5f, 0.7f, 0.3f);

    const size_t frames = 48000;
    std::vector<float> buf(frames * 2);
    for (size_t i = 0; i < frames; ++i) {
        const float s = 0.9f * std::sin(2.0f * 3.14159265f * 440.0f * i / kSr);
        buf[i * 2] = s;
        buf[i * 2 + 1] = s;
    }
    rv.process(buf.data(), frames, 2);

    check(allFinite(buf.data(), buf.size()), "output finite (no NaN/inf)");
    const float peak = peakAbs(buf.data(), buf.size());
    const float outRms = rmsRange(buf.data(), 24000 * 2, frames * 2);
    std::printf("      peak abs = %.4f, steady RMS (last 0.5s) = %.4f\n", peak, outRms);
    check(peak < 5.0f, "peak bounded (< 5.0, soft limiter caps it at engine level)");
    check(outRms > 0.05f && outRms < 2.0f, "steady-state RMS sane");
}

// ------------------------------------------------------- T3: disabled bypass
void testDisabledPassthrough() {
    std::printf("T3 disabled = true bypass (bit-exact)\n");
    FreeverbProcessor rv;
    rv.configure(kSr);
    rv.setParams(false, 0.5f, 0.7f, 0.3f);

    const size_t frames = 4800;
    std::vector<float> buf(frames * 2);
    std::vector<float> ref(frames * 2);
    for (size_t i = 0; i < frames; ++i) {
        const float s = 0.8f * std::sin(2.0f * 3.14159265f * 220.0f * i / kSr);
        buf[i * 2] = s;
        buf[i * 2 + 1] = -s;
        ref[i * 2] = s;
        ref[i * 2 + 1] = -s;
    }
    rv.process(buf.data(), frames, 2);
    check(std::memcmp(buf.data(), ref.data(), buf.size() * sizeof(float)) == 0,
          "disabled output bit-identical to input");

    // Enabled but mix == 0 must also be a dry passthrough.
    rv.setParams(true, 0.0f, 0.7f, 0.3f);
    rv.process(buf.data(), frames, 2);
    check(std::memcmp(buf.data(), ref.data(), buf.size() * sizeof(float)) == 0,
          "enabled, mix=0 output bit-identical to input");
}

// ------------------------------------------------------------- T4: edge params
void testEdgeParams() {
    std::printf("T4 edge params (all 8 corners of mix/room/damp in {0,1})\n");
    const float corners[2] = {0.0f, 1.0f};
    bool allOk = true;
    float worstPeak = 0.0f;
    for (float mix : corners) {
        for (float room : corners) {
            for (float damp : corners) {
                FreeverbProcessor rv;
                rv.configure(kSr);
                rv.setParams(true, mix, room, damp);
                const size_t frames = 48000;
                std::vector<float> buf(frames * 2, 0.0f);
                buf[0] = 1.0f;
                buf[1] = 1.0f;
                for (size_t i = 1; i < frames; ++i) {  // + sine after impulse
                    const float s = 0.5f * std::sin(2.0f * 3.14159265f * 440.0f * i / kSr);
                    buf[i * 2] = s;
                    buf[i * 2 + 1] = s;
                }
                rv.process(buf.data(), frames, 2);
                const bool finite = allFinite(buf.data(), buf.size());
                const float peak = peakAbs(buf.data(), buf.size());
                worstPeak = std::max(worstPeak, peak);
                if (!finite || peak > 50.0f) {
                    allOk = false;
                    std::printf("      corner mix=%.0f room=%.0f damp=%.0f: finite=%d peak=%.2f\n",
                                mix, room, damp, static_cast<int>(finite), peak);
                }
            }
        }
    }
    std::printf("      worst peak across corners = %.4f\n", worstPeak);
    check(allOk, "all 8 corners finite, bounded, no crash");
}

// ------------------------------------------------------------- T5: reset
void testResetClearsTail() {
    std::printf("T5 reset() clears the tail\n");
    FreeverbProcessor rv;
    rv.configure(kSr);
    rv.setParams(true, 0.8f, 0.9f, 0.1f);  // long loud tail

    const size_t frames = 24000;
    std::vector<float> buf(frames * 2, 0.0f);
    buf[0] = 1.0f;
    buf[1] = 1.0f;
    rv.process(buf.data(), frames, 2);
    const float tailBefore = rmsRange(buf.data(), 12000 * 2, frames * 2);
    std::printf("      tail RMS before reset = %.6f\n", tailBefore);
    check(tailBefore > 1e-4f, "tail present before reset (sanity)");

    rv.reset();
    std::vector<float> silence(frames * 2, 0.0f);
    rv.process(silence.data(), frames, 2);
    const float afterPeak = peakAbs(silence.data(), silence.size());
    std::printf("      peak after reset + silence = %.9f\n", afterPeak);
    check(afterPeak == 0.0f, "silence after reset is exactly zero");
}

// ------------------------------------------------------------- T6: NaN params
void testNanParams() {
    std::printf("T6 NaN params (defect probe: clampFloat(NaN) behaviour)\n");
    const float nan = std::numeric_limits<float>::quiet_NaN();
    const float clamped = std::max(0.0f, std::min(1.0f, nan));
    std::printf("      std::max(0, std::min(1, NaN)) = %.1f  (raw clampFloat result)\n", clamped);

    FreeverbProcessor rv;
    rv.configure(kSr);
    rv.setParams(true, nan, nan, nan);
    const size_t frames = 4800;
    std::vector<float> buf(frames * 2, 0.0f);
    buf[0] = 1.0f;
    buf[1] = 1.0f;
    rv.process(buf.data(), frames, 2);
    check(allFinite(buf.data(), buf.size()), "output finite after NaN params");
    // Correct behaviour (NaN -> dry): frame 0 is the dry impulse at full
    // level, and there is no wet tail. Pre-fix, NaN clamped to 1.0 =
    // full wet, so frame 0 would be ~0 (dry gain 0) with a loud tail.
    std::printf("      frame0 L = %.4f, tail RMS = %.6f\n",
                buf[0], rmsRange(buf.data(), 2400 * 2, frames * 2));
    check(std::fabs(buf[0] - 1.0f) < 1e-6f, "NaN mix degrades to dry (frame 0 == 1.0)");
    check(rmsRange(buf.data(), 2400 * 2, frames * 2) == 0.0f, "NaN mix produces no tail");
}

// ------------------------------------------------- T7: disable / re-enable tail
void testDisableReenable() {
    std::printf("T7 disable then re-enable must not resurrect a stale tail\n");
    FreeverbProcessor rv;
    rv.configure(kSr);
    rv.setParams(true, 0.8f, 0.9f, 0.1f);

    const size_t frames = 12000;  // 0.25 s each step
    std::vector<float> buf(frames * 2, 0.0f);
    buf[0] = 1.0f;
    buf[1] = 1.0f;
    rv.process(buf.data(), frames, 2);  // excite the tail

    rv.setParams(false, 0.8f, 0.9f, 0.1f);
    std::vector<float> silence(frames * 2, 0.0f);
    rv.process(silence.data(), frames, 2);  // disabled: frozen buffers

    rv.setParams(true, 0.8f, 0.9f, 0.1f);
    std::vector<float> after(frames * 2, 0.0f);
    rv.process(after.data(), frames, 2);
    const float stalePeak = peakAbs(after.data(), after.size());
    std::printf("      peak after re-enable + silence = %.6f\n", stalePeak);
    check(stalePeak == 0.0f, "no stale tail after disable/re-enable");
}

// ------------------------------------------------------------- T8: engine PCM16
void testEnginePcm16() {
    std::printf("T8 DspEngine end-to-end PCM16 (stereo 48 kHz)\n");
    const size_t frames = 48000;
    std::vector<uint8_t> in(frames * 4, 0);
    std::vector<uint8_t> out(frames * 4, 0);
    // Impulse: L=R=32767 at frame 0 (little-endian).
    in[0] = 0xFF; in[1] = 0x7F; in[2] = 0xFF; in[3] = 0x7F;

    DspEngine eng(kSr, 2);
    eng.setReverb(true, 0.5f, 0.7f, 0.3f);
    eng.processPcm16(in.data(), out.data(), in.size());

    auto sample = [&](const std::vector<uint8_t>& b, size_t s) -> int16_t {
        const uint16_t u = static_cast<uint16_t>(b[s * 2]) |
                           (static_cast<uint16_t>(b[s * 2 + 1]) << 8);
        return static_cast<int16_t>(u);
    };
    double tailEnergy = 0.0;
    int16_t tailPeak = 0;
    for (size_t s = 4800; s < frames * 2; ++s) {
        const int16_t v = sample(out, s);
        tailEnergy += static_cast<double>(v) * v;
        tailPeak = std::max<int16_t>(tailPeak, static_cast<int16_t>(std::abs(v)));
    }
    const float tailRms = static_cast<float>(std::sqrt(tailEnergy / (frames * 2 - 4800)));
    std::printf("      tail RMS (int16 units, 50ms..1s) = %.2f, tail peak = %d\n",
                tailRms, static_cast<int>(tailPeak));
    check(tailRms > 1.0f, "PCM16 tail present and non-silent");
    std::printf("      frame0 L = %d (expect ~16383: dry 32767 x dryGain 0.5, wet is 0 before first comb round trip)\n",
                static_cast<int>(sample(out, 0)));
    check(std::abs(sample(out, 0) - 16383) <= 1, "frame 0 is dry-only at mix 0.5");

    // Disabled engine: bit-exact passthrough.
    DspEngine eng2(kSr, 2);
    std::vector<uint8_t> out2(frames * 4, 0);
    eng2.processPcm16(in.data(), out2.data(), in.size());
    check(std::memcmp(in.data(), out2.data(), in.size()) == 0,
          "disabled engine is bit-exact passthrough");

    // Reset via engine clears the tail.
    eng.reset();
    std::vector<uint8_t> zeros(frames * 4, 0), out3(frames * 4, 0);
    eng.processPcm16(zeros.data(), out3.data(), zeros.size());
    bool allZero = true;
    for (uint8_t b : out3) allZero &= (b == 0);
    check(allZero, "engine reset + silence = all-zero output");
}

// ---------------------------------------------------------------- T9: mono
void testMono() {
    std::printf("T9 mono impulse (mix=0.5 room=0.7 damp=0.3, 1s)\n");
    FreeverbProcessor rv;
    rv.configure(kSr);
    rv.setParams(true, 0.5f, 0.7f, 0.3f);
    const size_t frames = 48000;
    std::vector<float> buf(frames, 0.0f);
    buf[0] = 1.0f;
    rv.process(buf.data(), frames, 1);
    check(allFinite(buf.data(), buf.size()), "mono output finite");
    const float tailRms = rmsRange(buf.data(), 2400, frames);
    std::printf("      mono tail RMS (50ms..1s) = %.6f\n", tailRms);
    check(tailRms > 1e-4f, "mono reverb tail present");
}

// ---------------------------------------------------------------- T10: CPU
void testCpu() {
    std::printf("T10 CPU cost (10 s stereo 48 kHz, mix=0.5 room=0.7 damp=0.3)\n");
    FreeverbProcessor rv;
    rv.configure(kSr);
    rv.setParams(true, 0.5f, 0.7f, 0.3f);
    const size_t frames = 480000;
    std::vector<float> buf(frames * 2);
    for (size_t i = 0; i < frames; ++i) {
        const float s = 0.5f * std::sin(2.0f * 3.14159265f * 440.0f * i / kSr);
        buf[i * 2] = s;
        buf[i * 2 + 1] = s;
    }
    const auto t0 = std::chrono::steady_clock::now();
    rv.process(buf.data(), frames, 2);
    const auto t1 = std::chrono::steady_clock::now();
    const double ms = std::chrono::duration<double, std::milli>(t1 - t0).count();
    std::printf("      10 s audio processed in %.1f ms -> %.2f ms per 1 s audio (%.2f%% of one core)\n",
                ms, ms / 10.0, ms / 100.0);
    check(ms < 10000.0, "faster than realtime on host (x86_64, -O2)");
}

}  // namespace

int main() {
    std::printf("Freeverb host smoke test (dsp_engine.cpp, no JNI)\n\n");
    testImpulseStereo();
    testSineStereo();
    testDisabledPassthrough();
    testEdgeParams();
    testResetClearsTail();
    testNanParams();
    testDisableReenable();
    testEnginePcm16();
    testMono();
    testCpu();
    std::printf("\n%s: %d failure(s)\n", g_failures == 0 ? "ALL PASS" : "FAILURES",
                g_failures);
    return g_failures == 0 ? 0 : 1;
}
