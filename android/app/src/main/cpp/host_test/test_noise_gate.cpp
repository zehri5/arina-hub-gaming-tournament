// Host smoke test for the NoiseGateProcessor (v2 DSP engine, #10 audio,
// gate group). Compiles dsp_engine.cpp WITHOUT JNI on the Linux host and
// MEASURES the gate end to end — pass/silence, hysteresis, attack,
// release, disabled passthrough, click-free transitions, chatter,
// NaN/edge params, stereo, and the 16 kHz mic-bridge rate.
//
// Exit 0 = all checks pass. No Android SDK, no device, no APK needed.
// This file lives in host_test/ and is NOT listed in CMakeLists.txt, so
// it can never ship in libaudio_dsp.so.
//
// Measurement notes:
//  * Gain is estimated as RMS(out)/RMS(in) over short windows. At 1 kHz
//    a 1 ms window is exactly one cycle, so the estimate is exact.
//  * "Attack time" here is the one-pole time constant: gain reaches 63%
//    in attackMs, 90% in ~2.3x, 99% in ~4.6x. The test reports t63/t90/
//    t99 separately so the numbers speak for themselves.
//  * "Release" has two stages: the detector (30 ms tau) must fall below
//    the close threshold before the gain starts decaying (120 ms tau).
//    The test reports the flip time plus t50/t10/t01 of the gain decay.

#include <cmath>
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <limits>
#include <vector>

#include "dsp_engine.h"

namespace {

using arena_dsp::DspEngine;
using arena_dsp::NoiseGateProcessor;

constexpr double kPi = 3.14159265358979323846;

int g_failures = 0;
int g_checks = 0;

void check(bool cond, const char* what) {
    ++g_checks;
    if (!cond) {
        ++g_failures;
        std::printf("  FAIL: %s\n", what);
    }
}

double dbToLin(double db) { return std::pow(10.0, db / 20.0); }
double linToDb(double lin) { return 20.0 * std::log10(lin); }

float rmsDbfs(const float* buf, size_t n) {
    double sum = 0.0;
    for (size_t i = 0; i < n; ++i) {
        sum += static_cast<double>(buf[i]) * static_cast<double>(buf[i]);
    }
    if (sum <= 0.0) return -999.0f;
    return static_cast<float>(linToDb(std::sqrt(sum / static_cast<double>(n))));
}

// RMS ratio (gain estimate) over [start, start+len) of two buffers.
double windowGain(const float* out, const float* in, size_t start, size_t len) {
    double sumOut = 0.0, sumIn = 0.0;
    for (size_t i = 0; i < len; ++i) {
        const double o = out[start + i];
        const double v = in[start + i];
        sumOut += o * o;
        sumIn += v * v;
    }
    if (sumIn <= 0.0) return 0.0;
    return std::sqrt(sumOut / sumIn);
}

// Fill `buf` with a sine of `freqHz` at `ampLin`, starting at phase 0.
void fillSine(float* buf, size_t frames, int sampleRate, double freqHz,
              double ampLin) {
    for (size_t i = 0; i < frames; ++i) {
        const double t = static_cast<double>(i) / sampleRate;
        buf[i] = static_cast<float>(ampLin * std::sin(2.0 * kPi * freqHz * t));
    }
}

// Run the gate in 10 ms chunks, as the mic path would (one APM frame).
void processChunked(NoiseGateProcessor* gate, float* buf, size_t frames,
                    int channels, int sampleRate) {
    const size_t chunk = static_cast<size_t>(sampleRate / 100);  // 10 ms
    size_t done = 0;
    while (done < frames) {
        const size_t n = (frames - done < chunk) ? (frames - done) : chunk;
        gate->process(buf + done * static_cast<size_t>(channels), n, channels);
        done += n;
    }
}

// ---------------------------------------------------------------- T1
void testPassAndSilence() {
    std::printf("[T1] loud passes / quiet silenced (threshold -40 dB)\n");
    const int sr = 48000;
    const size_t frames = static_cast<size_t>(sr);  // 1 s
    std::vector<float> in(frames), out(frames);

    NoiseGateProcessor gate;
    gate.configure(sr);
    gate.setParams(true, -40.0f, 5.0f, 120.0f);

    // Loud: -20 dB sine, 1 kHz.
    fillSine(in.data(), frames, sr, 1000.0, dbToLin(-20.0));
    out = in;
    processChunked(&gate, out.data(), frames, 1, sr);
    const double loudGain = windowGain(out.data(), in.data(), frames / 2, frames / 2);
    std::printf("  -20 dB in  -> gain %.4f (%.2f dB)\n", loudGain, linToDb(loudGain));
    check(loudGain > 0.99 && loudGain < 1.01, "loud signal must pass at unity gain");

    // Quiet: -50 dB sine, 1 kHz. Fresh gate (closed state).
    gate.reset();
    fillSine(in.data(), frames, sr, 1000.0, dbToLin(-50.0));
    out = in;
    processChunked(&gate, out.data(), frames, 1, sr);
    const float quietDb = rmsDbfs(out.data(), frames);
    std::printf("  -50 dB in  -> out RMS %.1f dBFS\n", quietDb);
    check(quietDb < -90.0f, "quiet signal must be silenced below -90 dBFS");
}

// ---------------------------------------------------------------- T2
void testHysteresis() {
    std::printf("[T2] hysteresis (slow sweep -60 -> -20 -> -60 dB, 8 s each way)\n");
    const int sr = 48000;
    const size_t halfFrames = static_cast<size_t>(sr) * 8;  // 8 s per leg
    const size_t frames = halfFrames * 2;
    std::vector<float> in(frames), out(frames);

    for (size_t i = 0; i < frames; ++i) {
        double db;
        if (i < halfFrames) {
            db = -60.0 + 40.0 * static_cast<double>(i) / halfFrames;
        } else {
            db = -20.0 - 40.0 * static_cast<double>(i - halfFrames) / halfFrames;
        }
        const double t = static_cast<double>(i) / sr;
        in[i] = static_cast<float>(dbToLin(db) * std::sin(2.0 * kPi * 1000.0 * t));
    }
    out = in;

    NoiseGateProcessor gate;
    gate.configure(sr);
    gate.setParams(true, -40.0f, 5.0f, 120.0f);
    processChunked(&gate, out.data(), frames, 1, sr);

    // 10 ms windows. Open = first window gain >= 0.5 going up; close =
    // first window gain < 0.5 going down. Also the flip points (gain
    // starts rising / starts falling) which track the thresholds most
    // closely.
    const size_t win = static_cast<size_t>(sr / 100);  // 10 ms
    double openDb = 0.0, closeDb = 0.0, openFlipDb = 0.0, closeFlipDb = 0.0;
    bool foundOpen = false, foundClose = false, foundOpenFlip = false,
         foundCloseFlip = false;
    for (size_t w = 0; w + win <= frames; w += win) {
        const double g = windowGain(out.data(), in.data(), w, win);
        const double center = static_cast<double>(w + win / 2);
        double db;
        if (center < static_cast<double>(halfFrames)) {
            db = -60.0 + 40.0 * center / halfFrames;
        } else {
            db = -20.0 - 40.0 * (center - halfFrames) / halfFrames;
        }
        if (center < static_cast<double>(halfFrames)) {
            if (!foundOpenFlip && g > 0.01) { openFlipDb = db; foundOpenFlip = true; }
            if (!foundOpen && g >= 0.5) { openDb = db; foundOpen = true; }
        } else {
            if (foundOpen && !foundCloseFlip && g < 0.99) { closeFlipDb = db; foundCloseFlip = true; }
            if (foundOpen && !foundClose && g < 0.5) { closeDb = db; foundClose = true; }
        }
    }
    std::printf("  open flip  at %6.2f dB (expect ~-40.0)\n", openFlipDb);
    std::printf("  open  50%%  at %6.2f dB\n", openDb);
    std::printf("  close flip at %6.2f dB (expect ~-43.0)\n", closeFlipDb);
    std::printf("  close 50%%  at %6.2f dB\n", closeDb);
    std::printf("  hysteresis band (flip-to-flip): %.2f dB (expect ~3.0)\n",
                openFlipDb - closeFlipDb);
    check(foundOpen && openDb > -42.0 && openDb < -38.0, "open point near -40 dB");
    check(foundClose && closeDb > -46.0 && closeDb < -41.0, "close point near -43 dB");
    check(foundOpenFlip && foundCloseFlip &&
              (openFlipDb - closeFlipDb) > 2.5 && (openFlipDb - closeFlipDb) < 3.5,
          "hysteresis band ~3 dB");
}

// ---------------------------------------------------------------- T3
// Returns the measured attack times; also used by T6 (click check).
void measureAttack(int sampleRate, double* t63, double* t90, double* t99,
                   double* maxOutStep, double* maxInStep) {
    const int sr = sampleRate;
    const size_t preFrames = static_cast<size_t>(sr / 2);   // 0.5 s silence
    const size_t postFrames = static_cast<size_t>(sr);      // 1 s tone
    const size_t frames = preFrames + postFrames;
    std::vector<float> in(frames, 0.0f), out(frames, 0.0f);
    fillSine(in.data() + preFrames, postFrames, sr, 1000.0, dbToLin(-10.0));
    out = in;

    NoiseGateProcessor gate;
    gate.configure(sr);
    gate.setParams(true, -40.0f, 5.0f, 120.0f);
    processChunked(&gate, out.data(), frames, 1, sr);

    // 1 ms windows (one 1 kHz cycle each).
    const size_t win = static_cast<size_t>(sr / 1000);
    *t63 = *t90 = *t99 = -1.0;
    for (size_t w = preFrames; w + win <= frames; w += win) {
        const double g = windowGain(out.data(), in.data(), w, win);
        const double tMs = 1000.0 * (static_cast<double>(w - preFrames) + win / 2.0) / sr;
        if (*t63 < 0.0 && g >= 0.632) *t63 = tMs;
        if (*t90 < 0.0 && g >= 0.90) *t90 = tMs;
        if (*t99 < 0.0 && g >= 0.99) *t99 = tMs;
        if (*t99 >= 0.0) break;
    }
    // Max sample-to-sample steps in the first 50 ms after onset.
    *maxOutStep = 0.0;
    *maxInStep = 0.0;
    const size_t span = static_cast<size_t>(sr * 50 / 1000);
    for (size_t i = preFrames + 1; i < preFrames + span; ++i) {
        const double dOut = std::fabs(static_cast<double>(out[i]) - out[i - 1]);
        const double dIn = std::fabs(static_cast<double>(in[i]) - in[i - 1]);
        if (dOut > *maxOutStep) *maxOutStep = dOut;
        if (dIn > *maxInStep) *maxInStep = dIn;
    }
}

void testAttack() {
    std::printf("[T3] attack time (loud onset at -10 dB, attack 5 ms)\n");
    double t63, t90, t99, maxOutStep, maxInStep;
    measureAttack(48000, &t63, &t90, &t99, &maxOutStep, &maxInStep);
    std::printf("  t63 = %.1f ms (expect ~5.0 = one tau)\n", t63);
    std::printf("  t90 = %.1f ms (expect ~11.5)\n", t90);
    std::printf("  t99 = %.1f ms (expect ~23.0)\n", t99);
    check(t63 > 3.0 && t63 < 8.0, "t63 within 3-8 ms");
    check(t90 > 8.0 && t90 < 16.0, "t90 within 8-16 ms");
    check(t99 > 18.0 && t99 < 30.0, "t99 within 18-30 ms");
}

// ---------------------------------------------------------------- T4
void testRelease() {
    std::printf("[T4] release time (loud -10 dB -> quiet -50 dB probe, release 120 ms)\n");
    const int sr = 48000;
    const size_t loudFrames = static_cast<size_t>(sr);       // 1 s loud
    const size_t probeFrames = static_cast<size_t>(sr) * 2;  // 2 s probe
    const size_t frames = loudFrames + probeFrames;
    std::vector<float> in(frames), out(frames);
    fillSine(in.data(), loudFrames, sr, 1000.0, dbToLin(-10.0));
    fillSine(in.data() + loudFrames, probeFrames, sr, 1000.0, dbToLin(-50.0));
    out = in;

    NoiseGateProcessor gate;
    gate.configure(sr);
    gate.setParams(true, -40.0f, 5.0f, 120.0f);
    processChunked(&gate, out.data(), frames, 1, sr);

    // 5 ms windows after the drop; gain = RMS ratio vs the probe.
    const size_t win = static_cast<size_t>(sr * 5 / 1000);
    double tFlip = -1.0, t50 = -1.0, t10 = -1.0, t01 = -1.0;
    for (size_t w = loudFrames; w + win <= frames; w += win) {
        const double g = windowGain(out.data(), in.data(), w, win);
        const double tMs = 1000.0 * (static_cast<double>(w - loudFrames) + win / 2.0) / sr;
        if (tFlip < 0.0 && g < 0.99) tFlip = tMs;
        if (t50 < 0.0 && g < 0.50) t50 = tMs;
        if (t10 < 0.0 && g < 0.10) t10 = tMs;
        if (t01 < 0.0 && g < 0.01) t01 = tMs;
        if (t01 >= 0.0) break;
    }
    std::printf("  gate starts closing (gain < 0.99) at %.1f ms after drop\n", tFlip);
    std::printf("  gain < 0.50 at %.1f ms (flip + ~83 ms = one release tau x ln2)\n", t50);
    std::printf("  gain < 0.10 at %.1f ms (flip + ~276 ms)\n", t10);
    std::printf("  gain < 0.01 at %.1f ms (flip + ~553 ms)\n", t01);
    check(tFlip > 80.0 && tFlip < 200.0, "flip within 80-200 ms (detector decay)");
    check(t50 > 150.0 && t50 < 300.0, "t50 within 150-300 ms");
    check(t10 > 300.0 && t10 < 550.0, "t10 within 300-550 ms");
    check(t01 > 500.0 && t01 < 900.0, "t01 within 500-900 ms");
}

// ---------------------------------------------------------------- T5
void testDisabledPassthrough() {
    std::printf("[T5] disabled = true bypass + engine PCM path\n");
    const int sr = 48000;
    const size_t frames = static_cast<size_t>(sr);

    // (a) Gate processor disabled: float buffer bit-exact.
    {
        std::vector<float> buf(frames);
        for (size_t i = 0; i < frames; ++i) {
            buf[i] = static_cast<float>(0.5 * std::sin(2.0 * kPi * 440.0 * i / sr) +
                                        0.25 * std::sin(2.0 * kPi * 1234.0 * i / sr));
        }
        const std::vector<float> before = buf;
        NoiseGateProcessor gate;
        gate.configure(sr);
        gate.setParams(false, -40.0f, 5.0f, 120.0f);
        processChunked(&gate, buf.data(), frames, 1, sr);
        const bool identical = std::memcmp(buf.data(), before.data(),
                                           frames * sizeof(float)) == 0;
        std::printf("  (a) gate disabled, float buffer bit-exact: %s\n",
                    identical ? "YES" : "NO");
        check(identical, "disabled gate must not touch the buffer");
    }

    // (b) Engine, all processors disabled: PCM16 byte-identical.
    {
        std::vector<uint8_t> pcm(frames * 2);
        for (size_t i = 0; i < frames; ++i) {
            const int16_t v = static_cast<int16_t>(
                (i % 7 == 0) ? 32767 : ((i % 11 == 0) ? -32768 : (i % 5 == 0) ? 0
                    : static_cast<int>(12000.0 * std::sin(2.0 * kPi * 440.0 * i / sr))));
            pcm[i * 2] = static_cast<uint8_t>(v & 0xFF);
            pcm[i * 2 + 1] = static_cast<uint8_t>((v >> 8) & 0xFF);
        }
        std::vector<uint8_t> out = pcm;
        DspEngine engine(sr, 1);  // nothing enabled: fast-path memcpy
        engine.processPcm16(pcm.data(), out.data(), pcm.size());
        const bool identical = std::memcmp(out.data(), pcm.data(), pcm.size()) == 0;
        std::printf("  (b) engine all-disabled, PCM16 byte-identical: %s\n",
                    identical ? "YES" : "NO");
        check(identical, "all-disabled engine must memcpy passthrough");
    }

    // (c) Gate enabled + open: PCM16 round-trip error vs input (float
    // path runs; expect <= 1 LSB from the 32767/32768 quantizer).
    {
        std::vector<uint8_t> pcm(frames * 2);
        for (size_t i = 0; i < frames; ++i) {
            const double t = static_cast<double>(i) / sr;
            const int16_t v = static_cast<int16_t>(
                std::lrint(dbToLin(-3.0) * 32768.0 * std::sin(2.0 * kPi * 1000.0 * t)));
            pcm[i * 2] = static_cast<uint8_t>(v & 0xFF);
            pcm[i * 2 + 1] = static_cast<uint8_t>((v >> 8) & 0xFF);
        }
        std::vector<uint8_t> out = pcm;
        DspEngine engine(sr, 1);
        engine.setNoiseGate(true, -40.0f, 5.0f, 120.0f);
        // 10 ms chunks like the mic path.
        const size_t chunkBytes = static_cast<size_t>(sr / 100) * 2;
        for (size_t off = 0; off < pcm.size(); off += chunkBytes) {
            engine.processPcm16(out.data() + off, out.data() + off, chunkBytes);
        }
        int maxDiff = 0;
        for (size_t i = frames / 2; i < frames; ++i) {
            const int16_t a = static_cast<int16_t>(pcm[i * 2] | (pcm[i * 2 + 1] << 8));
            const int16_t b = static_cast<int16_t>(out[i * 2] | (out[i * 2 + 1] << 8));
            const int d = std::abs(static_cast<int>(a) - static_cast<int>(b));
            if (d > maxDiff) maxDiff = d;
        }
        std::printf("  (c) gate open, PCM16 round-trip max error: %d LSB\n", maxDiff);
        check(maxDiff <= 1, "open-gate PCM round-trip within 1 LSB");
    }
}

// ---------------------------------------------------------------- T6
void testClickFree() {
    std::printf("[T6] click-free transitions (attack onset)\n");
    double t63, t90, t99, maxOutStep, maxInStep;
    measureAttack(48000, &t63, &t90, &t99, &maxOutStep, &maxInStep);
    std::printf("  max |sample step| out = %.5f, in = %.5f (ratio %.2f)\n",
                maxOutStep, maxInStep, maxOutStep / maxInStep);
    check(maxOutStep < 1.5 * maxInStep,
          "gate must not create steps bigger than the signal's own");
}

// ---------------------------------------------------------------- T7
int countTransitions(const float* out, const float* in, size_t frames,
                     int sr, size_t skipFrames) {
    const size_t win = static_cast<size_t>(sr * 5 / 1000);  // 5 ms
    int transitions = 0;
    bool prevOpen = false;
    bool havePrev = false;
    for (size_t w = skipFrames; w + win <= frames; w += win) {
        const double g = windowGain(out, in, w, win);
        const bool open = g >= 0.5;
        if (havePrev && open != prevOpen) ++transitions;
        prevOpen = open;
        havePrev = true;
    }
    return transitions;
}

void testChatter() {
    std::printf("[T7] no chatter on a signal hovering at the threshold\n");
    const int sr = 48000;

    // (a) 1 kHz tone wandering +/-0.83 dB around -40 dB (inside the
    // 3 dB hysteresis band): gate opens once and must stay open.
    // (b) Same, wandering +/-4 dB (crosses both edges): gate MUST
    // follow -> proves the test can see transitions at all.
    for (int variant = 0; variant < 2; ++variant) {
        const double wanderDb = (variant == 0) ? 0.83 : 4.0;
        const size_t frames = static_cast<size_t>(sr) * 5;  // 5 s
        std::vector<float> in(frames), out(frames);
        for (size_t i = 0; i < frames; ++i) {
            const double t = static_cast<double>(i) / sr;
            const double db = -40.0 + wanderDb * std::sin(2.0 * kPi * 0.7 * t);
            in[i] = static_cast<float>(dbToLin(db) * std::sin(2.0 * kPi * 1000.0 * t));
        }
        out = in;
        NoiseGateProcessor gate;
        gate.configure(sr);
        gate.setParams(true, -40.0f, 5.0f, 120.0f);
        processChunked(&gate, out.data(), frames, 1, sr);
        const int n = countTransitions(out.data(), in.data(), frames, sr,
                                       static_cast<size_t>(sr));  // skip 1 s
        std::printf("  wander +/-%4.2f dB around -40 dB: %d transitions after 1 s\n",
                    wanderDb, n);
        if (variant == 0) {
            check(n == 0, "inside the hysteresis band: no chatter");
        } else {
            check(n >= 4, "crossing both edges: gate must follow (sanity)");
        }
    }

    // (c) Steady low-frequency tones just above threshold: the
    // detector ripple between |sin| peaks must not chatter. 100 Hz
    // and 50 Hz are in voice range; 20 Hz is informational only
    // (below voice fundamentals).
    for (double freq : {100.0, 50.0, 20.0}) {
        const size_t frames = static_cast<size_t>(sr) * 2;  // 2 s
        std::vector<float> in(frames), out(frames);
        fillSine(in.data(), frames, sr, freq, dbToLin(-39.0));
        out = in;
        NoiseGateProcessor gate;
        gate.configure(sr);
        gate.setParams(true, -40.0f, 5.0f, 120.0f);
        processChunked(&gate, out.data(), frames, 1, sr);
        const int n = countTransitions(out.data(), in.data(), frames, sr,
                                       static_cast<size_t>(sr / 5));  // skip 200 ms
        std::printf("  steady %3.0f Hz at -39 dB: %d transitions after 200 ms%s\n",
                    freq, n, freq < 30.0 ? " (informational)" : "");
        if (freq >= 30.0) {
            check(n == 0, "steady tone above threshold must not chatter");
        }
    }
}

// ---------------------------------------------------------------- T8
void testEdgeParams() {
    std::printf("[T8] edge params: NaN, 0 ms, threshold extremes\n");
    const int sr = 48000;
    const size_t frames = static_cast<size_t>(sr);
    std::vector<float> in(frames), out(frames);
    const float kNaN = std::numeric_limits<float>::quiet_NaN();

    // (a) NaN as the FIRST call: must keep the defaults (-40/5/120),
    // so a loud signal still passes and a quiet one is silenced.
    {
        NoiseGateProcessor gate;
        gate.configure(sr);
        gate.setParams(true, kNaN, kNaN, kNaN);
        fillSine(in.data(), frames, sr, 1000.0, dbToLin(-20.0));
        out = in;
        processChunked(&gate, out.data(), frames, 1, sr);
        const double g = windowGain(out.data(), in.data(), frames / 2, frames / 2);
        std::printf("  NaN params (fresh): loud gain %.4f (expect ~1.0)\n", g);
        check(g > 0.99, "NaN params must not mute the mic (keep defaults)");
    }

    // (b) NaN after valid params: must keep the PREVIOUS values.
    {
        NoiseGateProcessor gate;
        gate.configure(sr);
        gate.setParams(true, -40.0f, 5.0f, 120.0f);
        gate.setParams(true, kNaN, kNaN, kNaN);
        fillSine(in.data(), frames, sr, 1000.0, dbToLin(-20.0));
        out = in;
        processChunked(&gate, out.data(), frames, 1, sr);
        const double g = windowGain(out.data(), in.data(), frames / 2, frames / 2);
        std::printf("  NaN params (after valid): loud gain %.4f (expect ~1.0)\n", g);
        check(g > 0.99, "NaN params must keep previous values");
        gate.reset();
        fillSine(in.data(), frames, sr, 1000.0, dbToLin(-50.0));
        out = in;
        processChunked(&gate, out.data(), frames, 1, sr);
        const float q = rmsDbfs(out.data(), frames);
        std::printf("  NaN params (after valid): quiet out %.1f dBFS (expect < -90)\n", q);
        check(q < -90.0f, "NaN params must keep previous threshold");
    }

    // (c) 0 ms attack/release clamp to 0.1/5.0 ms: no div-by-zero,
    // attack becomes very fast.
    {
        NoiseGateProcessor gate;
        gate.configure(sr);
        gate.setParams(true, -40.0f, 0.0f, 0.0f);
        const size_t pre = static_cast<size_t>(sr / 2);
        const size_t total = pre + static_cast<size_t>(sr);
        std::vector<float> in2(total, 0.0f), out2(total, 0.0f);
        fillSine(in2.data() + pre, total - pre, sr, 1000.0, dbToLin(-10.0));
        out2 = in2;
        processChunked(&gate, out2.data(), total, 1, sr);
        const size_t win = static_cast<size_t>(sr / 1000);
        double t63 = -1.0;
        for (size_t w = pre; w + win <= total; w += win) {
            if (windowGain(out2.data(), in2.data(), w, win) >= 0.632) {
                t63 = 1000.0 * (static_cast<double>(w - pre) + win / 2.0) / sr;
                break;
            }
        }
        std::printf("  attack=0ms -> t63 = %.2f ms (expect <= 1 ms, clamped to 0.1 ms)\n", t63);
        check(t63 >= 0.0 && t63 <= 1.0, "0 ms attack clamps sanely");
    }

    // (d) Threshold extremes.
    {
        NoiseGateProcessor gate;
        gate.configure(sr);
        gate.setParams(true, -90.0f, 5.0f, 120.0f);
        fillSine(in.data(), frames, sr, 1000.0, dbToLin(-50.0));
        out = in;
        processChunked(&gate, out.data(), frames, 1, sr);
        const double g = windowGain(out.data(), in.data(), frames / 2, frames / 2);
        std::printf("  threshold -90 dB: -50 dB signal gain %.4f (expect ~1.0)\n", g);
        check(g > 0.99, "-90 dB threshold passes a -50 dB signal");

        gate.reset();
        gate.setParams(true, 0.0f, 5.0f, 120.0f);
        fillSine(in.data(), frames, sr, 1000.0, dbToLin(-20.0));
        out = in;
        processChunked(&gate, out.data(), frames, 1, sr);
        const float q = rmsDbfs(out.data(), frames);
        std::printf("  threshold 0 dB: -20 dB signal out %.1f dBFS (expect < -90)\n", q);
        check(q < -90.0f, "0 dB threshold silences a -20 dB signal");
    }
}

// ---------------------------------------------------------------- T9
void testStereo() {
    std::printf("[T9] stereo: shared detector, equal gain, no crosstalk\n");
    const int sr = 48000;
    const size_t frames = static_cast<size_t>(sr);
    std::vector<float> in(frames * 2), out(frames * 2);

    // L loud (-20 dB), R quiet (-50 dB): detector sees the max, so
    // BOTH channels pass at the same gain.
    for (size_t i = 0; i < frames; ++i) {
        const double t = static_cast<double>(i) / sr;
        in[i * 2] = static_cast<float>(dbToLin(-20.0) * std::sin(2.0 * kPi * 1000.0 * t));
        in[i * 2 + 1] = static_cast<float>(dbToLin(-50.0) * std::sin(2.0 * kPi * 1000.0 * t + 1.0));
    }
    out = in;
    NoiseGateProcessor gate;
    gate.configure(sr);
    gate.setParams(true, -40.0f, 5.0f, 120.0f);
    processChunked(&gate, out.data(), frames, 2, sr);
    // Per-channel RMS ratio over the second half.
    double sumL = 0.0, sumR = 0.0, sumLi = 0.0, sumRi = 0.0;
    for (size_t i = frames / 2; i < frames; ++i) {
        sumL += static_cast<double>(out[i * 2]) * out[i * 2];
        sumR += static_cast<double>(out[i * 2 + 1]) * out[i * 2 + 1];
        sumLi += static_cast<double>(in[i * 2]) * in[i * 2];
        sumRi += static_cast<double>(in[i * 2 + 1]) * in[i * 2 + 1];
    }
    const double gainL = std::sqrt(sumL / sumLi);
    const double gainR = std::sqrt(sumR / sumRi);
    std::printf("  L -20 dB / R -50 dB: gainL %.4f, gainR %.4f\n", gainL, gainR);
    check(gainL > 0.99 && gainR > 0.99, "stereo: both channels pass when max is loud");
    check(std::fabs(gainL - gainR) < 0.02, "stereo: equal gain on both channels");

    // L silent, R loud: L must stay exactly silent (no crosstalk).
    gate.reset();
    for (size_t i = 0; i < frames; ++i) {
        const double t = static_cast<double>(i) / sr;
        in[i * 2] = 0.0f;
        in[i * 2 + 1] = static_cast<float>(dbToLin(-20.0) * std::sin(2.0 * kPi * 1000.0 * t));
    }
    out = in;
    processChunked(&gate, out.data(), frames, 2, sr);
    float maxL = 0.0f;
    for (size_t i = 0; i < frames; ++i) {
        maxL = std::max(maxL, std::fabs(out[i * 2]));
    }
    std::printf("  L silent / R loud: max |out L| = %.2e (expect 0)\n", maxL);
    check(maxL == 0.0f, "stereo: no crosstalk into the silent channel");
}

// --------------------------------------------------------------- T10
void test16kHz() {
    std::printf("[T10] 16 kHz (mic-bridge rate): time constants hold\n");
    double t63, t90, t99, maxOutStep, maxInStep;
    measureAttack(16000, &t63, &t90, &t99, &maxOutStep, &maxInStep);
    std::printf("  16 kHz attack: t63 = %.1f ms, t90 = %.1f ms, t99 = %.1f ms\n",
                t63, t90, t99);
    check(t63 > 3.0 && t63 < 8.0, "16 kHz t63 within 3-8 ms");
    check(t90 > 8.0 && t90 < 16.0, "16 kHz t90 within 8-16 ms");
}

// --------------------------------------------------------------- T11
void testEnginePcmPath() {
    std::printf("[T11] DspEngine PCM16 path (the shipped path): gate silences/passes\n");
    const int sr = 48000;
    const size_t frames = static_cast<size_t>(sr);
    const size_t chunkBytes = static_cast<size_t>(sr / 100) * 2;  // 10 ms

    auto runLevel = [&](double db) {
        std::vector<uint8_t> pcm(frames * 2);
        for (size_t i = 0; i < frames; ++i) {
            const double t = static_cast<double>(i) / sr;
            const int16_t v = static_cast<int16_t>(
                std::lrint(dbToLin(db) * 32768.0 * std::sin(2.0 * kPi * 1000.0 * t)));
            pcm[i * 2] = static_cast<uint8_t>(v & 0xFF);
            pcm[i * 2 + 1] = static_cast<uint8_t>((v >> 8) & 0xFF);
        }
        std::vector<uint8_t> out = pcm;
        DspEngine engine(sr, 1);
        engine.setNoiseGate(true, -40.0f, 5.0f, 120.0f);
        for (size_t off = 0; off < pcm.size(); off += chunkBytes) {
            engine.processPcm16(out.data() + off, out.data() + off, chunkBytes);
        }
        double sumOut = 0.0, sumIn = 0.0;
        for (size_t i = frames / 2; i < frames; ++i) {
            const int16_t a = static_cast<int16_t>(pcm[i * 2] | (pcm[i * 2 + 1] << 8));
            const int16_t b = static_cast<int16_t>(out[i * 2] | (out[i * 2 + 1] << 8));
            sumIn += static_cast<double>(a) * a;
            sumOut += static_cast<double>(b) * b;
        }
        return std::sqrt(sumOut / sumIn);
    };

    const double loud = runLevel(-20.0);
    const double quiet = runLevel(-50.0);
    std::printf("  engine -20 dB in -> gain %.4f (expect ~1.0)\n", loud);
    std::printf("  engine -50 dB in -> gain %.4f (expect ~0.0)\n", quiet);
    check(loud > 0.99 && loud < 1.01, "engine: loud passes");
    check(quiet < 0.001, "engine: quiet silenced");
}

}  // namespace

int main() {
    std::printf("NoiseGate host smoke test (v2 DSP engine)\n");
    std::printf("=========================================\n");
    testPassAndSilence();
    testHysteresis();
    testAttack();
    testRelease();
    testDisabledPassthrough();
    testClickFree();
    testChatter();
    testEdgeParams();
    testStereo();
    test16kHz();
    testEnginePcmPath();
    std::printf("=========================================\n");
    std::printf("%d checks, %d failures\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
