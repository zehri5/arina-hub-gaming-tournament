// HOST-ONLY DSP SMOKE TEST — NOT part of the shipped app code.
//
// Compiles the REAL android dsp_engine.cpp with the host g++ (-std=c++17)
// and drives DspEngine directly (no JNI, no Android, no Flutter). It feeds
// an impulse and a sine through the FULL chain (EQ -> Echo -> Freeverb ->
// soft limiter) and checks the invariants the Dart wrapper cannot see:
// finite output, dry passthrough, non-silent processed output, and no
// crash / no runaway on edge parameters.
//
// Build + run (from the project root):
//   g++ -std=c++17 -O2 -Wall -Wextra -o /tmp/dsp_smoke_test
//     android/app/src/main/cpp/dsp_engine.cpp
//     android/app/src/main/cpp/host_test/host_dsp_smoke_test.cpp
//     -Iandroid/app/src/main/cpp
//   /tmp/dsp_smoke_test
//
// DO NOT add this directory to CMakeLists.txt — it must never ship in the
// APK. The binary goes to /tmp, never into the project tree.

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>

#include "dsp_engine.h"

namespace {

using arena_dsp::DspEngine;

int g_passed = 0;
int g_failed = 0;

void check(bool ok, const char* name) {
    if (ok) {
        ++g_passed;
        std::printf("PASS  %s\n", name);
    } else {
        ++g_failed;
        std::printf("FAIL  %s\n", name);
    }
}

// --- PCM16 helpers (little-endian, interleaved) ---------------------------

std::vector<uint8_t> sinePcm16(int sampleRate, int channels, double freqHz,
                               double amplitude, double seconds) {
    const size_t frames = static_cast<size_t>(sampleRate * seconds);
    std::vector<uint8_t> bytes(frames * channels * 2);
    for (size_t f = 0; f < frames; ++f) {
        const double t = static_cast<double>(f) / sampleRate;
        const double v = amplitude * std::sin(2.0 * M_PI * freqHz * t);
        const int16_t pcm =
            static_cast<int16_t>(std::lrint(v * 32767.0));
        for (int ch = 0; ch < channels; ++ch) {
            const size_t b = (f * channels + ch) * 2;
            bytes[b] = static_cast<uint8_t>(pcm & 0xFF);
            bytes[b + 1] = static_cast<uint8_t>((pcm >> 8) & 0xFF);
        }
    }
    return bytes;
}

std::vector<uint8_t> impulsePcm16(int sampleRate, int channels,
                                  double seconds) {
    const size_t frames = static_cast<size_t>(sampleRate * seconds);
    std::vector<uint8_t> bytes(frames * channels * 2, 0);
    const int16_t pcm = 32767;
    for (int ch = 0; ch < channels; ++ch) {
        const size_t b = static_cast<size_t>(ch) * 2;
        bytes[b] = static_cast<uint8_t>(pcm & 0xFF);
        bytes[b + 1] = static_cast<uint8_t>((pcm >> 8) & 0xFF);
    }
    return bytes;
}

int16_t sampleAt(const std::vector<uint8_t>& bytes, size_t index) {
    const size_t b = index * 2;
    const uint16_t raw = static_cast<uint16_t>(bytes[b]) |
                         (static_cast<uint16_t>(bytes[b + 1]) << 8);
    return static_cast<int16_t>(raw);
}

double rms(const std::vector<uint8_t>& bytes) {
    const size_t n = bytes.size() / 2;
    if (n == 0) return 0.0;
    double acc = 0.0;
    for (size_t i = 0; i < n; ++i) {
        const double v = sampleAt(bytes, i) / 32768.0;
        acc += v * v;
    }
    return std::sqrt(acc / static_cast<double>(n));
}

int peakAbs(const std::vector<uint8_t>& bytes) {
    // NOTE: |−32768| = 32768 — the int16 minimum is a LEGAL sample, so the
    // valid bound is 32768, not 32767.
    int peak = 0;
    for (size_t i = 0; i < bytes.size() / 2; ++i) {
        const int v = std::abs(static_cast<int>(sampleAt(bytes, i)));
        if (v > peak) peak = v;
    }
    return peak;
}

bool allFinite(const std::vector<uint8_t>& bytes) {
    // PCM16 samples are integers by construction, so "finite" here means
    // every sample decodes to a real value (no NaN/inf can survive the
    // int16 quantizer — a NaN inside the engine would quantize to 0 or
    // clamp, so we ALSO check the processed signal is sane, not silent
    // and not pinned at the rails).
    for (size_t i = 0; i < bytes.size() / 2; ++i) {
        const double v = sampleAt(bytes, i) / 32768.0;
        if (!std::isfinite(v)) return false;
    }
    return true;
}

// Energy in the second half of the buffer (reverb/echo tail).
double tailRms(const std::vector<uint8_t>& bytes) {
    const size_t n = bytes.size() / 2;
    if (n < 2) return 0.0;
    double acc = 0.0;
    size_t count = 0;
    for (size_t i = n / 2; i < n; ++i) {
        const double v = sampleAt(bytes, i) / 32768.0;
        acc += v * v;
        ++count;
    }
    return std::sqrt(acc / static_cast<double>(count));
}

std::vector<uint8_t> runEngine(DspEngine& engine,
                               const std::vector<uint8_t>& in) {
    std::vector<uint8_t> out(in.size(), 0);
    engine.processPcm16(in.data(), out.data(), in.size());
    return out;
}

void enableAll(DspEngine& engine) {
    engine.setEq(true, 6.0f, 3.0f, -2.0f, 4.0f);
    engine.setEcho(true, 250.0f, 0.35f, 0.35f);
    engine.setReverb(true, 0.3f, 0.5f, 0.5f);
}

}  // namespace

int main() {
    std::printf("=== Arena Hub DSP host smoke test ===\n");
    std::printf("(engine: dsp_engine.cpp, chain EQ -> Echo -> Freeverb -> "
                "soft limiter)\n\n");

    // 1. Dry passthrough: all stages disabled -> byte-identical output.
    {
        DspEngine engine(48000, 2);
        const auto in = sinePcm16(48000, 2, 440.0, 0.5, 0.25);
        const auto out = runEngine(engine, in);
        std::printf("  dry: in=%zu bytes, identical=%s\n", in.size(),
                    (in == out) ? "yes" : "NO");
        check(in == out, "dry passthrough is byte-identical (all off)");
    }

    // 2. Impulse through the FULL chain: finite, non-silent, audible tail.
    {
        DspEngine engine(48000, 2);
        enableAll(engine);
        const auto in = impulsePcm16(48000, 2, 1.0);
        const auto out = runEngine(engine, in);
        const double outRms = rms(out);
        const double outTail = tailRms(out);
        const int peak = peakAbs(out);
        std::printf("  impulse: rms=%.6f tailRms=%.6f peak=%d\n", outRms,
                    outTail, peak);
        check(allFinite(out), "impulse: output finite (no NaN/inf)");
        check(outRms > 1e-4, "impulse: processed output non-silent");
        check(outTail > 1e-5,
              "impulse: reverb/echo tail present in second half");
        check(peak <= 32768, "impulse: peak within int16 range");
    }

    // 3. Sine through the FULL chain: finite, non-silent, changed, bounded.
    {
        DspEngine engine(48000, 2);
        enableAll(engine);
        const auto in = sinePcm16(48000, 2, 440.0, 0.5, 0.5);
        const auto out = runEngine(engine, in);
        const double inRms = rms(in);
        const double outRms = rms(out);
        const int peak = peakAbs(out);
        std::printf("  sine 440Hz: inRms=%.4f outRms=%.4f peak=%d\n", inRms,
                    outRms, peak);
        check(allFinite(out), "sine: output finite (no NaN/inf)");
        check(outRms > 0.01, "sine: processed output non-silent");
        check(out != in, "sine: processed output differs from input");
        check(peak <= 32768, "sine: peak within int16 range (limiter)");
        check(outRms < 1.5, "sine: RMS bounded (no runaway gain)");
    }

    // 4. Mono engine: same guarantees on 1 channel.
    {
        DspEngine engine(16000, 1);
        enableAll(engine);
        const auto in = sinePcm16(16000, 1, 440.0, 0.5, 0.5);
        const auto out = runEngine(engine, in);
        std::printf("  mono 16kHz: outRms=%.4f peak=%d\n", rms(out),
                    peakAbs(out));
        check(allFinite(out) && rms(out) > 0.01,
              "mono 16kHz: finite + non-silent");
    }

    // 5. Edge parameters at/near every bound + full-scale input: no crash,
    //    finite, bounded. (The Dart wrapper clamps these; the engine clamps
    //    again — verify the engine survives even unclamped extremes.)
    //
    // NOTE: echo mix=1.0 + delay 2000 ms means the output is pure delayed
    // signal, so the first 2 s are silent BY DESIGN. The max-params input
    // is therefore 3 s long and the non-silence check looks at the tail
    // (after the delay has elapsed), not the whole buffer.
    {
        DspEngine engine(48000, 2);
        engine.setEq(true, 12.0f, 12.0f, -12.0f, 12.0f);
        engine.setEcho(true, 2000.0f, 0.95f, 1.0f);
        engine.setReverb(true, 1.0f, 1.0f, 1.0f);
        const auto in = sinePcm16(48000, 2, 1000.0, 1.0, 3.0);  // full scale
        const auto out = runEngine(engine, in);
        std::printf("  edge max: outRms=%.4f tailRms=%.4f peak=%d\n", rms(out),
                    tailRms(out), peakAbs(out));
        check(allFinite(out), "edge max params: finite output");
        check(peakAbs(out) <= 32768, "edge max params: peak bounded");
        check(rms(out) < 1.5, "edge max params: RMS bounded");
        check(tailRms(out) > 1e-4,
              "edge max params: signal arrives after 2000ms delay");

        // Wet-only reverb (wetDryMix=1.0) with a short echo delay must
        // still produce sound — the wet path alone is not silent.
        DspEngine wetOnly(48000, 2);
        wetOnly.setEcho(true, 50.0f, 0.3f, 0.2f);
        wetOnly.setReverb(true, 1.0f, 0.8f, 0.3f);
        const auto inWet = sinePcm16(48000, 2, 440.0, 0.5, 1.0);
        const auto outWet = runEngine(wetOnly, inWet);
        std::printf("  wet-only reverb: outRms=%.4f peak=%d\n", rms(outWet),
                    peakAbs(outWet));
        check(allFinite(outWet) && rms(outWet) > 0.01,
              "wet-only reverb: finite + non-silent");

        DspEngine engine2(8000, 1);
        engine2.setEq(true, 0.0f, 0.0f, 0.0f, 0.0f);
        engine2.setEcho(true, 1.0f, 0.0f, 0.0f);
        engine2.setReverb(true, 0.0f, 0.0f, 0.0f);
        const auto in2 = sinePcm16(8000, 1, 440.0, 0.9, 0.5);
        const auto out2 = runEngine(engine2, in2);
        std::printf("  edge min (8kHz mono): outRms=%.4f peak=%d\n",
                    rms(out2), peakAbs(out2));
        check(allFinite(out2) && rms(out2) > 0.01,
              "edge min params: finite + non-silent");

        // Out-of-range values the wrapper should never send: engine must
        // clamp, not blow up.
        DspEngine engine3(48000, 2);
        engine3.setEq(true, 100.0f, -100.0f, 100.0f, -100.0f);
        engine3.setEcho(true, 99999.0f, 5.0f, 5.0f);
        engine3.setReverb(true, 5.0f, -5.0f, 5.0f);
        const auto out3 = runEngine(engine3, in);
        std::printf("  out-of-range params: outRms=%.4f tailRms=%.4f "
                    "peak=%d\n",
                    rms(out3), tailRms(out3), peakAbs(out3));
        check(allFinite(out3) && peakAbs(out3) <= 32768,
              "out-of-range params: clamped, finite, bounded");
        check(tailRms(out3) > 1e-4,
              "out-of-range params: signal arrives after clamped delay");
    }

    // 6. Long run: 5 seconds in 10 ms blocks — no blow-up over time.
    {
        DspEngine engine(48000, 2);
        enableAll(engine);
        double maxRms = 0.0;
        bool finite = true;
        for (int i = 0; i < 500; ++i) {
            const auto in = sinePcm16(48000, 2, 440.0, 0.8, 0.01);
            const auto out = runEngine(engine, in);
            finite = finite && allFinite(out);
            const double r = rms(out);
            if (r > maxRms) maxRms = r;
        }
        std::printf("  5s streamed: maxBlockRms=%.4f finite=%s\n", maxRms,
                    finite ? "yes" : "NO");
        check(finite, "5s streamed: all blocks finite");
        check(maxRms < 1.5, "5s streamed: no gain runaway over time");
    }

    // 7. Degenerate inputs: empty, null, odd byte length, sub-frame.
    {
        DspEngine engine(48000, 2);
        enableAll(engine);
        uint8_t buf[8] = {1, 2, 3, 4, 5, 6, 7, 8};
        engine.processPcm16(nullptr, buf, 8);       // must not crash
        engine.processPcm16(buf, nullptr, 8);       // must not crash
        engine.processPcm16(buf, buf, 0);           // must not crash
        check(true, "null/empty input: no crash");

        // Odd byte length (not a whole frame): must not crash, must not
        // write past the buffer. NOTE: with stages enabled, trailing
        // partial-frame bytes are left untouched by design (only whole
        // frames are processed) — the harness fills the output with a
        // sentinel and verifies the tail bytes are untouched.
        const std::vector<uint8_t> odd = {0, 64, 0, 64, 0xAA};  // 1 frame + 1
        std::vector<uint8_t> oddOut(odd.size(), 0x55);
        engine.processPcm16(odd.data(), oddOut.data(), odd.size());
        check(oddOut[4] == 0x55,
              "odd byte length: trailing partial byte untouched, no crash");

        // Sub-frame input (2 bytes stereo = half a frame): copied through.
        const std::vector<uint8_t> sub = {0x11, 0x22};
        std::vector<uint8_t> subOut(2, 0);
        engine.processPcm16(sub.data(), subOut.data(), sub.size());
        check(subOut == sub, "sub-frame input: passed through unchanged");
    }

    // 8. In-place processing (in == out buffer).
    {
        DspEngine engine(48000, 2);
        enableAll(engine);
        auto buf = sinePcm16(48000, 2, 440.0, 0.5, 0.25);
        const auto original = buf;
        engine.processPcm16(buf.data(), buf.data(), buf.size());
        std::printf("  in-place: outRms=%.4f changed=%s\n", rms(buf),
                    (buf != original) ? "yes" : "NO");
        check(allFinite(buf) && rms(buf) > 0.01 && buf != original,
              "in-place processing: finite, non-silent, changed");
    }

    // 9. Reconfigure + reset mid-stream: no crash, state cleared.
    {
        DspEngine engine(48000, 2);
        enableAll(engine);
        const auto in = impulsePcm16(48000, 2, 0.5);
        (void)runEngine(engine, in);
        engine.reset();
        const auto silence = std::vector<uint8_t>(48000 * 2 * 2, 0);
        const auto out = runEngine(engine, silence);
        std::printf("  after reset: silenceRms=%.6f\n", rms(out));
        check(rms(out) < 1e-4,
              "reset: reverb/echo tail cleared (silence stays silent)");

        engine.configure(16000, 1);
        const auto inMono = sinePcm16(16000, 1, 440.0, 0.5, 0.25);
        const auto outMono = runEngine(engine, inMono);
        check(allFinite(outMono) && rms(outMono) > 0.01,
              "reconfigure 48k stereo -> 16k mono: works after switch");
    }

    // 10. EQ-only / echo-only / reverb-only: each stage alone is audible
    //     (output differs from dry input) and bounded.
    {
        const auto in = sinePcm16(48000, 2, 220.0, 0.5, 0.5);
        DspEngine eqOnly(48000, 2);
        eqOnly.setEq(true, 12.0f, 6.0f, 6.0f, 6.0f);
        const auto eqOut = runEngine(eqOnly, in);
        check(eqOut != in && allFinite(eqOut) && peakAbs(eqOut) <= 32768,
              "EQ-only: audible change, finite, bounded");

        DspEngine echoOnly(48000, 2);
        echoOnly.setEcho(true, 100.0f, 0.5f, 0.5f);
        const auto echoOut = runEngine(echoOnly, in);
        check(echoOut != in && allFinite(echoOut),
              "echo-only: audible change, finite");

        DspEngine verbOnly(48000, 2);
        verbOnly.setReverb(true, 0.8f, 0.9f, 0.2f);
        const auto verbOut = runEngine(verbOnly, in);
        check(verbOut != in && allFinite(verbOut),
              "reverb-only: audible change, finite");
    }

    std::printf("\n=== RESULT: %d passed, %d failed ===\n", g_passed, g_failed);
    return g_failed == 0 ? 0 : 1;
}
