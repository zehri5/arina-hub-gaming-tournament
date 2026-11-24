// ARENA HUB #10 AUDIO — Group 4 DSP adoption track.
// HOST-ONLY smoke-test harness for the external EchoProcessor.
// Runs on the dev VM with g++; NOT part of the shipped Android build.
//
// CMakeLists.txt lists ONLY dsp_engine.cpp + audio_dsp_jni.cpp, so
// nothing in this directory is ever compiled into libaudio_dsp.so.
// The harness compiles dsp_engine.cpp WITHOUT the JNI file (no
// jni.h / Android NDK needed on the host).
//
// Build (from android/app/src/main/cpp):
//   g++ -std=c++17 -O2 -Wall -Wextra host_test/echo_harness.cpp dsp_engine.cpp -o host_test/echo_harness
// Run:
//   ./host_test/echo_harness        (exit 0 = all checks pass)
//
// What it checks (all at 48 kHz unless noted):
//   A  delay accuracy: 250 ms impulse repeat lands at sample 12000,
//      repeats decay 1.0 / 0.35 / 0.1225 / ...
//   B  fractional delay: 250.1 ms -> energy centroid at 12004.8
//   C  dry passthrough when disabled / mix = 0 (bit-exact)
//   D  edge params: delay 1/2000 ms, feedback 0/0.95, mix 0/1
//   E  reset() clears the delay line
//   F  NaN params are sanitised (never become max feedback / max delay)
//   G  no ghost echo after disable -> silence -> re-enable
//   H  no ghost echo after mix 0 -> silence -> mix back up
//   I  sustained input at feedback 0.95 stays finite and bounded
//   J  delay change mid-stream: no click (slew), new delay accurate
//   K  stereo: L/R lines independent, no crossfeed
//   L  PCM16 end-to-end through DspEngine (repeat position/value,
//      disabled passthrough byte-identical, engine-level ghost test)
//   M  +/-inf params clamp to the documented ranges
//   N  process() with 0 frames does not crash

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <limits>
#include <vector>

#include "../dsp_engine.h"

using namespace arena_dsp;

static int g_pass = 0;
static int g_fail = 0;

static void check(bool ok, const char* name, const char* detail) {
    if (ok) {
        ++g_pass;
        std::printf("[PASS] %s -- %s\n", name, detail);
    } else {
        ++g_fail;
        std::printf("[FAIL] %s -- %s\n", name, detail);
    }
}

static bool allFinite(const std::vector<float>& v) {
    for (float x : v) {
        if (!std::isfinite(x)) return false;
    }
    return true;
}

static float maxAbs(const std::vector<float>& v, size_t begin, size_t end) {
    float m = 0.0f;
    for (size_t i = begin; i < end && i < v.size(); ++i) {
        const float a = std::fabs(v[i]);
        if (a > m) m = a;
    }
    return m;
}

// First index >= begin with |v[i]| > thresh, or -1.
static long firstAbove(const std::vector<float>& v, size_t begin, float thresh) {
    for (size_t i = begin; i < v.size(); ++i) {
        if (std::fabs(v[i]) > thresh) return static_cast<long>(i);
    }
    return -1;
}

// Max |x[n] - x[n-1]| over [begin, end).
static float maxStep(const std::vector<float>& v, size_t begin, size_t end) {
    float m = 0.0f;
    for (size_t i = begin + 1; i < end && i < v.size(); ++i) {
        const float d = std::fabs(v[i] - v[i - 1]);
        if (d > m) m = d;
    }
    return m;
}

// Process `frames` frames of silence so the delay slew can settle on
// its target before an impulse is fed. Needed after any setParams()
// that changes the delay: the slew is rate-limited to 0.5
// samples/sample, so a big jump (250 -> 2000 ms = 84000 samples)
// needs ~170k frames to arrive. Silence in -> silence out.
static void settle(EchoProcessor& echo, size_t frames, int channels) {
    std::vector<float> silence(frames * static_cast<size_t>(channels), 0.0f);
    echo.process(silence.data(), frames, channels);
}

static void testDelayAccuracyAndDecay() {
    EchoProcessor echo;
    echo.configure(48000);
    echo.setParams(true, 250.0f, 0.35f, 1.0f);  // mix 1 = wet only
    const size_t n = 96000;  // 2 s mono
    std::vector<float> buf(n, 0.0f);
    buf[0] = 1.0f;
    echo.process(buf.data(), n, 1);

    char d[256];
    const long first = firstAbove(buf, 1, 0.5f);
    std::snprintf(d, sizeof(d), "first repeat at sample %ld (expected 12000), "
                  "amp %.4f (expected 1.0000)", first, buf[12000]);
    check(first == 12000 && std::fabs(buf[12000] - 1.0f) < 1e-4f,
          "A1 delay accuracy 250ms", d);

    const float r2 = buf[24000], r3 = buf[36000], r4 = buf[48000], r5 = buf[60000];
    std::snprintf(d, sizeof(d), "repeats 0.3500/0.1225/0.0429/0.0150 expected, "
                  "got %.4f/%.4f/%.4f/%.4f", r2, r3, r4, r5);
    check(std::fabs(r2 - 0.35f) < 1e-4f && std::fabs(r3 - 0.1225f) < 1e-4f &&
          std::fabs(r4 - 0.042875f) < 1e-4f && std::fabs(r5 - 0.01500625f) < 1e-4f,
          "A2 repeat decay = feedback^n", d);

    // Everything except the impulse positions must be silent (mix=1 kills dry).
    float stray = 0.0f;
    for (size_t i = 0; i < n; ++i) {
        if (i % 12000 == 0) continue;
        if (std::fabs(buf[i]) > stray) stray = std::fabs(buf[i]);
    }
    std::snprintf(d, sizeof(d), "max stray sample %.6f (expected 0), dry at frame 0 = %.4f",
                  stray, buf[0]);
    check(stray < 1e-6f && buf[0] == 0.0f, "A3 silence between repeats, dry muted at mix=1", d);
    check(allFinite(buf), "A4 output finite", "2 s impulse response, no NaN/inf");
}

static void testFractionalDelay() {
    EchoProcessor echo;
    echo.configure(48000);
    echo.setParams(true, 250.1f, 0.35f, 1.0f);  // 12004.8 samples
    settle(echo, 8000, 1);  // let the slew arrive before the impulse
    const size_t n = 48000;
    const size_t impulseAt = 8000;
    std::vector<float> buf(n, 0.0f);
    buf[impulseAt] = 1.0f;
    echo.process(buf.data(), n, 1);

    // Linear interp splits the impulse: 0.2 @ +12004, 0.8 @ +12005.
    // Tolerance is 5e-3, not 1e-4: the read position is float32, whose
    // ulp at ~20000 samples is 0.002, so the split weights wobble by
    // ~+-0.002. The centroid check below (0.001-sample error) is the
    // meaningful accuracy assertion; the split itself is exact to
    // float precision.
    char d[256];
    const size_t s0 = impulseAt + 12004, s1 = impulseAt + 12005;
    std::snprintf(d, sizeof(d), "buf[%zu]=%.4f (exp 0.2000), buf[%zu]=%.4f (exp 0.8000)",
                  s0, buf[s0], s1, buf[s1]);
    check(std::fabs(buf[s0] - 0.2f) < 5e-3f && std::fabs(buf[s1] - 0.8f) < 5e-3f,
          "B1 fractional split 250.1ms", d);

    double num = 0.0, den = 0.0;
    for (size_t i = impulseAt + 12000; i < impulseAt + 12010; ++i) {
        num += static_cast<double>(i) * std::fabs(buf[i]);
        den += std::fabs(buf[i]);
    }
    const double centroid = (den > 0.0) ? num / den : -1.0;
    const double expected = static_cast<double>(impulseAt) + 12004.8;
    std::snprintf(d, sizeof(d), "energy centroid %.3f samples (expected %.3f), "
                  "error %.3f samples", centroid, expected, centroid - expected);
    check(std::fabs(centroid - expected) < 0.01, "B2 fractional delay centroid", d);
}

static void testDryPassthrough() {
    std::vector<float> in(48000);
    for (size_t i = 0; i < in.size(); ++i) in[i] = std::sin(2.0 * 3.14159265358979 * 440.0 * i / 48000.0f) * 0.5f;

    EchoProcessor echo;
    echo.configure(48000);

    std::vector<float> out = in;
    echo.setParams(false, 250.0f, 0.35f, 0.35f);
    echo.process(out.data(), out.size(), 1);
    check(std::memcmp(out.data(), in.data(), in.size() * sizeof(float)) == 0,
          "C1 disabled = bit-exact passthrough", "output identical to input");

    out = in;
    echo.setParams(true, 250.0f, 0.35f, 0.0f);  // mix 0
    echo.process(out.data(), out.size(), 1);
    check(std::memcmp(out.data(), in.data(), in.size() * sizeof(float)) == 0,
          "C2 mix=0 = bit-exact passthrough", "output identical to input");

    out = in;
    echo.setParams(true, 250.0f, 0.35f, 0.00005f);  // below the 0.0001 bypass threshold
    echo.process(out.data(), out.size(), 1);
    check(std::memcmp(out.data(), in.data(), in.size() * sizeof(float)) == 0,
          "C3 mix=0.00005 = bit-exact passthrough", "below bypass threshold");
}

static void testEdgeParams() {
    char d[256];
    {   // delay 1 ms -> 48 samples
        EchoProcessor echo;
        echo.configure(48000);
        echo.setParams(true, 1.0f, 0.35f, 1.0f);
        settle(echo, 30000, 1);  // 12000 -> 48 needs ~25k frames at 0.5/sample
        std::vector<float> buf(4800, 0.0f);
        buf[0] = 1.0f;
        echo.process(buf.data(), buf.size(), 1);
        const long first = firstAbove(buf, 1, 0.5f);
        std::snprintf(d, sizeof(d), "first repeat at %ld (expected 48)", first);
        check(first == 48 && allFinite(buf), "D1 delay=1ms", d);
    }
    {   // delay 2000 ms -> 96000 samples
        EchoProcessor echo;
        echo.configure(48000);
        echo.setParams(true, 2000.0f, 0.35f, 1.0f);
        settle(echo, 180000, 1);  // 12000 -> 96000 needs ~170k frames at 0.5/sample
        std::vector<float> buf(144000, 0.0f);
        buf[0] = 1.0f;
        echo.process(buf.data(), buf.size(), 1);
        const long first = firstAbove(buf, 1, 0.5f);
        std::snprintf(d, sizeof(d), "first repeat at %ld (expected 96000)", first);
        check(first == 96000 && allFinite(buf), "D2 delay=2000ms", d);
    }
    {   // feedback 0 -> exactly one repeat
        EchoProcessor echo;
        echo.configure(48000);
        echo.setParams(true, 250.0f, 0.0f, 1.0f);
        std::vector<float> buf(48000, 0.0f);
        buf[0] = 1.0f;
        echo.process(buf.data(), buf.size(), 1);
        std::snprintf(d, sizeof(d), "repeat1=%.4f (exp 1.0), repeat2=%.6f (exp 0.0)",
                      buf[12000], buf[24000]);
        check(std::fabs(buf[12000] - 1.0f) < 1e-4f && buf[24000] == 0.0f,
              "D3 feedback=0 single repeat", d);
    }
    {   // feedback 0.95 -> repeats are 0.95^n: 5th (at 60000) = 0.95^4,
        // 6th (at 72000) = 0.95^5
        EchoProcessor echo;
        echo.configure(48000);
        echo.setParams(true, 250.0f, 0.95f, 1.0f);
        std::vector<float> buf(96000, 0.0f);
        buf[0] = 1.0f;
        echo.process(buf.data(), buf.size(), 1);
        std::snprintf(d, sizeof(d), "5th repeat %.4f (expected 0.8145 = 0.95^4), "
                      "6th repeat %.4f (expected 0.7738 = 0.95^5)", buf[60000], buf[72000]);
        check(std::fabs(buf[60000] - 0.81450625f) < 1e-4f &&
              std::fabs(buf[72000] - 0.77378094f) < 1e-4f && allFinite(buf),
              "D4 feedback=0.95 decay", d);
    }
    {   // mix 1 with dry sine: dry must vanish
        EchoProcessor echo;
        echo.configure(48000);
        echo.setParams(true, 250.0f, 0.35f, 1.0f);
        std::vector<float> buf(12000);
        for (size_t i = 0; i < buf.size(); ++i) buf[i] = 0.5f;
        echo.process(buf.data(), buf.size(), 1);
        // First 12000 frames: no repeat has arrived yet, dry muted -> all 0.
        std::snprintf(d, sizeof(d), "max|out| in first 12000 frames = %.6f (expected 0)",
                      maxAbs(buf, 0, buf.size()));
        check(maxAbs(buf, 0, buf.size()) == 0.0f, "D5 mix=1 dry fully muted", d);
    }
}

static void testReset() {
    EchoProcessor echo;
    echo.configure(48000);
    echo.setParams(true, 250.0f, 0.35f, 1.0f);
    std::vector<float> buf(24000, 0.0f);
    buf[0] = 1.0f;
    echo.process(buf.data(), buf.size(), 1);
    echo.reset();
    std::vector<float> silence(48000, 0.0f);
    echo.process(silence.data(), silence.size(), 1);
    char d[256];
    std::snprintf(d, sizeof(d), "max|out| after reset = %.6f (expected 0)", maxAbs(silence, 0, silence.size()));
    check(maxAbs(silence, 0, silence.size()) == 0.0f, "E1 reset() clears the line", d);

    // After reset the line behaves like new: fresh impulse repeats at 12000.
    std::vector<float> buf2(24000, 0.0f);
    buf2[0] = 1.0f;
    echo.process(buf2.data(), buf2.size(), 1);
    std::snprintf(d, sizeof(d), "repeat after reset at %ld (expected 12000), amp %.4f",
                  firstAbove(buf2, 1, 0.5f), buf2[12000]);
    check(firstAbove(buf2, 1, 0.5f) == 12000, "E2 line usable after reset", d);
}

static void testNanParams() {
    const float nan = std::numeric_limits<float>::quiet_NaN();
    char d[256];
    {
        EchoProcessor echo;
        echo.configure(48000);
        echo.setParams(true, 250.0f, 0.35f, 1.0f);
        echo.setParams(true, nan, nan, nan);  // must NOT become delay 2000 / fb 0.95
        std::vector<float> buf(48000, 0.0f);
        buf[0] = 1.0f;
        echo.process(buf.data(), buf.size(), 1);
        const long first = firstAbove(buf, 1, 0.5f);
        std::snprintf(d, sizeof(d), "first repeat at %ld (expected 12000 = params kept; "
                      "96000 would mean NaN became max delay)", first);
        check(first == 12000 && allFinite(buf), "F1 NaN params keep previous values", d);
    }
    {
        EchoProcessor echo;
        echo.configure(48000);
        echo.setParams(true, 250.0f, 0.35f, 1.0f);
        echo.setParams(true, 250.0f, nan, 1.0f);  // only feedback is NaN
        std::vector<float> buf(48000, 0.0f);
        buf[0] = 1.0f;
        echo.process(buf.data(), buf.size(), 1);
        std::snprintf(d, sizeof(d), "2nd repeat %.4f (expected 0.3500 = kept; "
                      "0.9500 would mean NaN became max feedback)", buf[24000]);
        check(std::fabs(buf[24000] - 0.35f) < 1e-4f, "F2 NaN feedback keeps previous value", d);
    }
}

static void testGhostAfterDisable() {
    EchoProcessor echo;
    echo.configure(48000);
    echo.setParams(true, 250.0f, 0.35f, 1.0f);
    std::vector<float> buf(24000, 0.0f);
    buf[0] = 1.0f;
    echo.process(buf.data(), buf.size(), 1);          // impulse + 1 repeat in the line
    echo.setParams(false, 250.0f, 0.35f, 1.0f);       // disable
    std::vector<float> silence(144000, 0.0f);         // 3 s of silence while off
    echo.process(silence.data(), silence.size(), 1);
    echo.setParams(true, 250.0f, 0.35f, 1.0f);        // re-enable
    std::vector<float> after(48000, 0.0f);
    echo.process(after.data(), after.size(), 1);
    char d[256];
    const float m = maxAbs(after, 0, after.size());
    std::snprintf(d, sizeof(d), "max|out| after re-enable = %.4f (expected 0.0000; "
                  "0.3500 would be a ghost of the pre-disable audio)", m);
    check(m == 0.0f, "G ghost echo after disable/re-enable", d);
}

static void testGhostAfterMixZero() {
    EchoProcessor echo;
    echo.configure(48000);
    echo.setParams(true, 250.0f, 0.35f, 1.0f);
    std::vector<float> buf(24000, 0.0f);
    buf[0] = 1.0f;
    echo.process(buf.data(), buf.size(), 1);
    echo.setParams(true, 250.0f, 0.35f, 0.0f);        // mix to 0 (stays "enabled")
    std::vector<float> silence(144000, 0.0f);         // 3 s of silence at mix 0
    echo.process(silence.data(), silence.size(), 1);
    echo.setParams(true, 250.0f, 0.35f, 1.0f);        // mix back up
    std::vector<float> after(48000, 0.0f);
    echo.process(after.data(), after.size(), 1);
    char d[256];
    const float m = maxAbs(after, 0, after.size());
    std::snprintf(d, sizeof(d), "max|out| after mix back up = %.4f (expected 0.0000; "
                  "0.3500 would be a ghost of the pre-zero audio)", m);
    check(m == 0.0f, "H ghost echo after mix 0 -> back up", d);
}

static void testSustainedHighFeedback() {
    char d[256];
    {
        EchoProcessor echo;
        echo.configure(48000);
        echo.setParams(true, 250.0f, 0.95f, 0.5f);
        std::vector<float> buf(240000);  // 5 s sine
        for (size_t i = 0; i < buf.size(); ++i)
            buf[i] = std::sin(2.0 * 3.14159265358979 * 440.0 * i / 48000.0) * 0.8f;
        echo.process(buf.data(), buf.size(), 1);
        const float m = maxAbs(buf, 0, buf.size());
        std::snprintf(d, sizeof(d), "5 s sine @ fb 0.95: finite=%s, max|out|=%.3f (bounded, no runaway; "
                      "comb resonance can reach ~8x input, the engine soft limiter bounds the PCM path)",
                      allFinite(buf) ? "yes" : "NO", m);
        check(allFinite(buf) && m < 10.0f, "I1 sustained sine fb=0.95", d);
    }
    {
        EchoProcessor echo;
        echo.configure(48000);
        echo.setParams(true, 250.0f, 0.95f, 0.5f);
        std::vector<float> buf(96000, 0.5f);  // 2 s DC 0.5 (worst case for a comb)
        echo.process(buf.data(), buf.size(), 1);
        const float m = maxAbs(buf, 0, buf.size());
        // Steady state: delayed -> 0.5/(1-0.95) = 10, out -> 0.25 + 5 = 5.25.
        std::snprintf(d, sizeof(d), "2 s DC 0.5 @ fb 0.95: finite=%s, max|out|=%.3f "
                      "(steady-state theory 5.25, must stay finite)", allFinite(buf) ? "yes" : "NO", m);
        check(allFinite(buf) && m < 25.0f, "I2 sustained DC fb=0.95", d);
    }
}

static void testDelayChange() {
    char d[256];
    {   // J1: no click when the delay changes mid-stream (slew).
        EchoProcessor echo;
        echo.configure(48000);
        echo.setParams(true, 250.0f, 0.35f, 0.5f);
        std::vector<float> buf(96000);
        for (size_t i = 0; i < buf.size(); ++i)
            buf[i] = std::sin(2.0 * 3.14159265358979 * 440.0 * i / 48000.0) * 0.5f;
        echo.process(buf.data(), 48000, 1);
        const float baseStep = maxStep(buf, 43000, 48000);
        echo.setParams(true, 1000.0f, 0.35f, 0.5f);  // 250 -> 1000 ms mid-stream
        echo.process(buf.data() + 48000, 48000, 1);
        const float changeStep = maxStep(buf, 48000, 53000);
        std::snprintf(d, sizeof(d), "max sample-step before change %.4f, in 5k frames after "
                      "change %.4f (ratio %.2fx; an instant jump would be >>10x)",
                      baseStep, changeStep, changeStep / baseStep);
        check(allFinite(buf) && changeStep < 3.0f * baseStep, "J1 delay change: no click (slew)", d);
    }
    {   // J2: the new delay is accurate once the slew settles. The change
        // is 12000 samples, rate-limited to 0.5/sample, so settle needs
        // ~24k frames; the 2nd impulse goes in at frame 54000.
        EchoProcessor echo;
        echo.configure(48000);
        echo.setParams(true, 250.0f, 0.35f, 1.0f);
        std::vector<float> buf(120000, 0.0f);
        buf[0] = 1.0f;
        echo.process(buf.data(), 24000, 1);
        echo.setParams(true, 500.0f, 0.35f, 1.0f);   // change at frame 24000
        buf[54000] = 1.0f;                            // 2nd impulse, slew settled by now
        echo.process(buf.data() + 24000, 96000, 1);
        const long rep = firstAbove(buf, 54001, 0.5f);
        std::snprintf(d, sizeof(d), "2nd impulse repeat at %ld (expected 78000 = 54000 + 24000)",
                      rep);
        check(rep == 78000 && allFinite(buf), "J2 new delay accurate after change", d);
    }
    {   // J3: slider-drag simulation — 10 delay steps 250 -> 1000 ms,
        // 4800 frames (100 ms) apart, sine input. No click at any step.
        EchoProcessor echo;
        echo.configure(48000);
        echo.setParams(true, 250.0f, 0.35f, 0.5f);
        std::vector<float> buf(96000);
        for (size_t i = 0; i < buf.size(); ++i)
            buf[i] = std::sin(2.0 * 3.14159265358979 * 440.0 * i / 48000.0) * 0.5f;
        echo.process(buf.data(), 48000, 1);
        const float baseStep = maxStep(buf, 43000, 48000);
        float worstStep = 0.0f;
        for (int s = 1; s <= 10; ++s) {
            echo.setParams(true, 250.0f + s * 75.0f, 0.35f, 0.5f);
            const size_t off = 48000 + static_cast<size_t>(s - 1) * 4800;
            echo.process(buf.data() + off, 4800, 1);
            const float st = maxStep(buf, off, off + 4800);
            if (st > worstStep) worstStep = st;
        }
        std::snprintf(d, sizeof(d), "baseline max step %.4f, worst step during 10-step drag %.4f "
                      "(ratio %.2fx)", baseStep, worstStep, worstStep / baseStep);
        check(allFinite(buf) && worstStep < 3.0f * baseStep, "J3 slider drag: no clicks", d);
    }
}

static void testStereo() {
    EchoProcessor echo;
    echo.configure(48000);
    echo.setParams(true, 250.0f, 0.35f, 1.0f);
    const size_t frames = 48000;
    std::vector<float> buf(frames * 2, 0.0f);
    buf[0] = 1.0f;  // impulse on L only
    echo.process(buf.data(), frames, 2);
    float maxR = 0.0f;
    for (size_t i = 1; i < buf.size(); i += 2) {
        if (std::fabs(buf[i]) > maxR) maxR = std::fabs(buf[i]);
    }
    char d[256];
    std::snprintf(d, sizeof(d), "L repeat @ frame 12000 = %.4f (exp 1.0), max|R| = %.6f (exp 0)",
                  buf[24000], maxR);
    check(std::fabs(buf[24000] - 1.0f) < 1e-4f && maxR == 0.0f,
          "K stereo: independent lines, no crossfeed", d);
    check(allFinite(buf), "K2 stereo output finite", "48000 stereo frames");
}

static void testPcm16EndToEnd() {
    char d[256];
    {   // L1: impulse through DspEngine PCM16, chunked like a real stream.
        DspEngine engine(48000, 1);
        engine.setEcho(true, 250.0f, 0.35f, 1.0f);
        const size_t totalFrames = 96000;
        std::vector<uint8_t> pcm(totalFrames * 2, 0);
        const int16_t impulse = 16384;  // 0.5 full-scale: below the soft-limiter knee
        pcm[0] = static_cast<uint8_t>(impulse & 0xFF);
        pcm[1] = static_cast<uint8_t>((impulse >> 8) & 0xFF);
        std::vector<uint8_t> out(pcm.size(), 0);
        const size_t chunk = 4800;  // 100 ms chunks
        for (size_t f = 0; f < totalFrames; f += chunk) {
            engine.processPcm16(pcm.data() + f * 2, out.data() + f * 2, chunk * 2);
        }
        auto sampleAt = [&](size_t frame) -> int16_t {
            const uint16_t u = static_cast<uint16_t>(out[frame * 2]) |
                               (static_cast<uint16_t>(out[frame * 2 + 1]) << 8);
            return static_cast<int16_t>(u);
        };
        long first = -1;
        for (size_t f = 1; f < totalFrames; ++f) {
            if (sampleAt(f) != 0) { first = static_cast<long>(f); break; }
        }
        std::snprintf(d, sizeof(d), "first repeat frame %ld (exp 12000), value %d (exp 16384+-1), "
                      "2nd repeat %d (exp 5734+-2)", first, sampleAt(12000), sampleAt(24000));
        check(first == 12000 && std::abs(sampleAt(12000) - 16384) <= 1 &&
              std::abs(sampleAt(24000) - 5734) <= 2, "L1 PCM16 repeat position/value", d);
    }
    {   // L2: disabled engine = byte-identical passthrough.
        DspEngine engine(48000, 2);
        std::vector<uint8_t> pcm(4800 * 2 * 2);
        for (size_t i = 0; i < pcm.size(); ++i) pcm[i] = static_cast<uint8_t>((i * 37 + 11) & 0xFF);
        std::vector<uint8_t> out(pcm.size(), 0);
        engine.processPcm16(pcm.data(), out.data(), pcm.size());
        check(std::memcmp(pcm.data(), out.data(), pcm.size()) == 0,
              "L2 PCM16 disabled = byte-identical", "memcpy bypass path");
    }
    {   // L3: full-scale impulse still bounded (soft limiter above 0.9).
        DspEngine engine(48000, 1);
        engine.setEcho(true, 250.0f, 0.35f, 1.0f);
        std::vector<uint8_t> pcm(48000 * 2, 0);
        pcm[0] = 0xFF; pcm[1] = 0x7F;  // 32767
        std::vector<uint8_t> out(pcm.size(), 0);
        engine.processPcm16(pcm.data(), out.data(), pcm.size());
        const uint16_t u = static_cast<uint16_t>(out[24000]) |
                           (static_cast<uint16_t>(out[24001]) << 8);
        const int16_t v = static_cast<int16_t>(u);
        std::snprintf(d, sizeof(d), "full-scale repeat = %d (soft-limited from 32767, "
                      "theory ~31985; must stay <= 32767)", v);
        check(v > 30000, "L3 PCM16 soft limiter bounds output", d);
    }
    {   // L4: engine-level ghost test — disable goes through the memcpy
        // bypass, so process() never runs while off; only a clear inside
        // setParams() itself can prevent the ghost here.
        DspEngine engine(48000, 1);
        engine.setEcho(true, 250.0f, 0.35f, 1.0f);
        std::vector<uint8_t> pcm(24000 * 2, 0);
        pcm[0] = 0x00; pcm[1] = 0x40;  // 16384
        std::vector<uint8_t> out(pcm.size(), 0);
        engine.processPcm16(pcm.data(), out.data(), pcm.size());
        engine.setEcho(false, 250.0f, 0.35f, 1.0f);
        std::vector<uint8_t> silence(144000 * 2, 0);
        std::vector<uint8_t> outSil(silence.size(), 0);
        engine.processPcm16(silence.data(), outSil.data(), silence.size());
        engine.setEcho(true, 250.0f, 0.35f, 1.0f);
        std::vector<uint8_t> after(48000 * 2, 0);
        std::vector<uint8_t> outAfter(after.size(), 0);
        engine.processPcm16(after.data(), outAfter.data(), after.size());
        int16_t maxV = 0;
        for (size_t f = 0; f < 48000; ++f) {
            const uint16_t u = static_cast<uint16_t>(outAfter[f * 2]) |
                               (static_cast<uint16_t>(outAfter[f * 2 + 1]) << 8);
            const int16_t s = static_cast<int16_t>(u);
            if (std::abs(s) > std::abs(maxV)) maxV = s;
        }
        std::snprintf(d, sizeof(d), "max|sample| after engine-level re-enable = %d "
                      "(expected 0; 5734 would be the ghost)", maxV);
        check(maxV == 0, "L4 PCM16 ghost after disable/re-enable", d);
    }
    {   // L5: NaN through the real DspEngine::setEcho path.
        const float nan = std::numeric_limits<float>::quiet_NaN();
        DspEngine engine(48000, 1);
        engine.setEcho(true, 250.0f, 0.35f, 1.0f);
        engine.setEcho(true, nan, nan, nan);
        std::vector<uint8_t> pcm(48000 * 2, 0);
        pcm[0] = 0x00; pcm[1] = 0x40;  // 16384
        std::vector<uint8_t> out(pcm.size(), 0);
        engine.processPcm16(pcm.data(), out.data(), pcm.size());
        long first = -1;
        for (size_t f = 1; f < 48000; ++f) {
            const uint16_t u = static_cast<uint16_t>(out[f * 2]) |
                               (static_cast<uint16_t>(out[f * 2 + 1]) << 8);
            if (static_cast<int16_t>(u) != 0) { first = static_cast<long>(f); break; }
        }
        std::snprintf(d, sizeof(d), "first repeat frame %ld (expected 12000 = params kept)", first);
        check(first == 12000, "L5 PCM16 NaN params keep previous values", d);
    }
}

static void testInfParams() {
    const float inf = std::numeric_limits<float>::infinity();
    EchoProcessor echo;
    echo.configure(48000);
    echo.setParams(true, inf, -inf, inf);  // -> delay 2000, fb 0, mix 1
    settle(echo, 180000, 1);  // 12000 -> 96000 needs ~170k frames at 0.5/sample
    std::vector<float> buf(120000, 0.0f);
    buf[0] = 1.0f;
    echo.process(buf.data(), buf.size(), 1);
    const long first = firstAbove(buf, 1, 0.5f);
    char d[256];
    // 2nd repeat would be at 192000, beyond the buffer; fb=0 means nothing after 96000.
    float afterFirst = 0.0f;
    for (size_t i = 96001; i < buf.size(); ++i) {
        if (std::fabs(buf[i]) > afterFirst) afterFirst = std::fabs(buf[i]);
    }
    std::snprintf(d, sizeof(d), "first repeat at %ld (expected 96000), max after it %.6f (expected 0)",
                  first, afterFirst);
    check(first == 96000 && afterFirst == 0.0f && allFinite(buf), "M +/-inf params clamp safely", d);
}

static void testZeroFrames() {
    EchoProcessor echo;
    echo.configure(48000);
    echo.setParams(true, 250.0f, 0.35f, 1.0f);
    float x = 1.0f;
    echo.process(&x, 0, 1);  // must not crash
    check(x == 1.0f, "N process(0 frames) is a no-op", "no crash, input untouched");
}

int main() {
    std::printf("=== External EchoProcessor host smoke test (48 kHz) ===\n");
    testDelayAccuracyAndDecay();
    testFractionalDelay();
    testDryPassthrough();
    testEdgeParams();
    testReset();
    testNanParams();
    testGhostAfterDisable();
    testGhostAfterMixZero();
    testSustainedHighFeedback();
    testDelayChange();
    testStereo();
    testPcm16EndToEnd();
    testInfParams();
    testZeroFrames();
    std::printf("=== %d passed, %d failed ===\n", g_pass, g_fail);
    return g_fail == 0 ? 0 : 1;
}
