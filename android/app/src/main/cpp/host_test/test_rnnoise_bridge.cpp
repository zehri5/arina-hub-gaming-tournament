// Host test for the RNNoise per-band bridge (rnnoise_bridge.h/.cpp).
//
// Compiles the bridge + the vendored RNNoise C engine on the Linux host
// with g++ and verifies, with numbers:
//   1. resampler filter DC gain ~3.0 (interpolation gain);
//   2. resampler up->down round-trip SNR, full-band and speech-band;
//   3. resampler imaging suppression (tone energy above 8 kHz);
//   4. resampler cascade delay is exactly 42 samples @ 16 kHz;
//   5. RNNoise itself: lowpassed noise crushed, tone preserved,
//      white-noise behaviour reported (model leaves 8-24 kHz alone);
//   6. bridge end-to-end on a synthetic 3-band APM frame;
//   7. bridge end-to-end with a speech proxy in noise;
//   8. bypass is bit-identical passthrough;
//   9. bad shapes fail open (buffer untouched, lastError set);
//  10. determinism (two bridges, same input -> identical output).
//
// This does NOT verify the on-device path (APM buffer layout, JNI,
// Kotlin registration) — that needs a phone. It verifies everything
// below the JNI line: the DSP routing is real, not plumbing.
//
// Run: ./run_host_test.sh (or see the compile line inside it).

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <random>
#include <vector>

#include "rnnoise.h"
#include "rnnoise_bridge.h"

using namespace arena_rnnoise;

namespace {

int g_failures = 0;
int g_checks = 0;

void check(bool ok, const char* name, const char* detail = "") {
  ++g_checks;
  if (ok) {
    std::printf("[PASS] %s %s\n", name, detail);
  } else {
    ++g_failures;
    std::printf("[FAIL] %s %s\n", name, detail);
  }
}

double rms(const float* x, int n) {
  double acc = 0;
  for (int i = 0; i < n; ++i) acc += (double)x[i] * x[i];
  return std::sqrt(acc / n);
}

void testFilterDcGain() {
  Resampler3x r;
  const float gain = r.filterDcGain();
  char detail[64];
  std::snprintf(detail, sizeof(detail), "(dc gain = %.4f, want ~3.0)", gain);
  check(gain > 2.98f && gain < 3.02f, "resampler DC gain", detail);
}

void testRoundTripSnr() {
  // 2 s of white noise + tones at 16 kHz, up -> down, compare with the
  // 42-sample cascade delay compensated.
  //
  // NOTE on the threshold: a half-band FIR rolls off through its
  // transition band, which for this 127-tap filter spans ~7-9 kHz, so
  // white noise (which fills the whole 0-8 kHz band) loses energy at
  // the 7-8 kHz edge: ~23 dB SNR. That is the top edge of each band —
  // speech lives below 6 kHz, where the round trip is far cleaner (see
  // testRoundTripSpeechBand). A longer filter would sharpen the edge
  // but cost latency (255 taps = 5.3 ms); 127 taps / 2.6 ms is the
  // chosen trade-off.
  constexpr int kSeconds = 2;
  constexpr int kLen = 16000 * kSeconds;
  constexpr int kDelay16k = 42;  // 126 samples @ 48 kHz.
  std::vector<float> in(kLen), up(kLen * 3), out(kLen);
  std::mt19937 rng(42);
  std::uniform_real_distribution<float> uni(-0.3f, 0.3f);
  for (int i = 0; i < kLen; ++i) {
    const float t = (float)i / 16000.f;
    in[i] = uni(rng) + 0.2f * std::sin(2.f * 3.14159265f * 1000.f * t) +
            0.1f * std::sin(2.f * 3.14159265f * 5000.f * t);
  }
  Resampler3x r;
  for (int f = 0; f < kLen / kSamplesPerBand; ++f) {
    r.upsample(&in[f * kSamplesPerBand], &up[f * kRnnoiseFrameSize]);
  }
  // Downsample needs the full 48 kHz stream frame by frame.
  Resampler3x r2;  // fresh instance: same coefficients, own history.
  // NOTE: up and down use separate instances here (as in the bridge,
  // where each band has one Resampler3x doing both directions — the
  // histories are independent, so sharing one instance is equivalent).
  for (int f = 0; f < kLen / kSamplesPerBand; ++f) {
    r2.downsample(&up[f * kRnnoiseFrameSize], &out[f * kSamplesPerBand]);
  }
  double sig = 0, err = 0;
  // Skip the first 100 samples: the up + down filter transients (zero
  // history at startup) settle within ~84 samples @ 16 kHz.
  for (int i = 100; i < kLen; ++i) {
    const double s = in[i - kDelay16k];
    const double e = out[i] - s;
    sig += s * s;
    err += e * e;
  }
  const double snr = 10 * std::log10(sig / err);
  char detail[128];
  std::snprintf(detail, sizeof(detail),
                "(full-band round-trip SNR = %.1f dB, want > 20 dB; "
                "edge-rolloff limited, see comment)",
                snr);
  check(snr > 20.0, "resampler round-trip SNR (full-band)", detail);
}

void testRoundTripSpeechBand() {
  // Same round trip, but the input lives where speech lives (< 6 kHz):
  // tones at 1/3/5 kHz + noise through a 4th-order lowpass (4 cascaded
  // 1-pole sections, 24 dB/octave, so the noise tail above 6 kHz is
  // negligible). The 7-8 kHz edge rolloff does not touch this content,
  // so the SNR must be far higher than the full-band figure.
  constexpr int kLen = 16000 * 2;
  constexpr int kDelay16k = 42;
  std::vector<float> in(kLen), up(kLen * 3), out(kLen);
  std::mt19937 rng(43);
  std::uniform_real_distribution<float> uni(-1.f, 1.f);
  float lp1 = 0, lp2 = 0, lp3 = 0, lp4 = 0;
  for (int i = 0; i < kLen; ++i) {
    const float t = (float)i / 16000.f;
    const float w = 0.3f * uni(rng);
    lp1 += 0.2f * (w - lp1);
    lp2 += 0.2f * (lp1 - lp2);
    lp3 += 0.2f * (lp2 - lp3);
    lp4 += 0.2f * (lp3 - lp4);
    in[i] = lp4 * 6.0f +
            0.2f * std::sin(2.f * 3.14159265f * 1000.f * t) +
            0.15f * std::sin(2.f * 3.14159265f * 3000.f * t) +
            0.1f * std::sin(2.f * 3.14159265f * 5000.f * t);
  }
  Resampler3x rUp, rDown;
  for (int f = 0; f < kLen / kSamplesPerBand; ++f) {
    rUp.upsample(&in[f * kSamplesPerBand], &up[f * kRnnoiseFrameSize]);
    rDown.downsample(&up[f * kRnnoiseFrameSize],
                     &out[f * kSamplesPerBand]);
  }
  double sig = 0, err = 0;
  for (int i = 100; i < kLen; ++i) {
    const double s = in[i - kDelay16k];
    const double e = out[i] - s;
    sig += s * s;
    err += e * e;
  }
  const double snr = 10 * std::log10(sig / err);
  char detail[96];
  std::snprintf(detail, sizeof(detail),
                "(speech-band round-trip SNR = %.1f dB, want > 45 dB)",
                snr);
  check(snr > 45.0, "resampler round-trip SNR (speech band)", detail);
}

void testImaging() {
  // Upsample a 1 kHz tone; measure energy above 8 kHz in the 48 kHz
  // output (images of the 0-8 kHz band would land at 8-24 kHz).
  // Measured with a crude DFT at 9, 12, 15, 20 kHz vs the 1 kHz bin.
  constexpr int kFrames = 20;
  Resampler3x r;
  std::vector<float> out(kFrames * kRnnoiseFrameSize);
  for (int f = 0; f < kFrames; ++f) {
    float frame[kSamplesPerBand];
    for (int i = 0; i < kSamplesPerBand; ++i) {
      const float t =
          (float)(f * kSamplesPerBand + i) / 16000.f;
      frame[i] = 0.5f * std::sin(2.f * 3.14159265f * 1000.f * t);
    }
    r.upsample(frame, &out[f * kRnnoiseFrameSize]);
  }
  // DFT magnitudes on the last 4800 samples (steady state).
  auto magAt = [&](float freq) {
    double re = 0, im = 0;
    const int n0 = (int)out.size() - 4800;
    for (int i = 0; i < 4800; ++i) {
      const double ph =
          -2.0 * 3.141592653589793 * freq * i / 48000.0;
      re += out[n0 + i] * std::cos(ph);
      im += out[n0 + i] * std::sin(ph);
    }
    return std::sqrt(re * re + im * im);
  };
  const double tone = magAt(1000.f);
  double worst = 0;
  for (float f : {9000.f, 12000.f, 15000.f, 20000.f}) {
    worst = std::max(worst, magAt(f));
  }
  const double suppression = 20 * std::log10(worst / tone);
  char detail[96];
  std::snprintf(detail, sizeof(detail),
                "(worst image = %.1f dB rel. tone, want < -50 dB)",
                suppression);
  check(suppression < -50.0, "resampler imaging suppression", detail);
}

void testCascadeDelay() {
  // Impulse at 16 kHz sample 200; the up->down peak must land at 242.
  constexpr int kLen = 1600;
  std::vector<float> in(kLen, 0.f), up(kLen * 3), out(kLen, 0.f);
  in[200] = 1.0f;
  Resampler3x rUp, rDown;
  for (int f = 0; f < kLen / kSamplesPerBand; ++f) {
    rUp.upsample(&in[f * kSamplesPerBand], &up[f * kRnnoiseFrameSize]);
    rDown.downsample(&up[f * kRnnoiseFrameSize],
                     &out[f * kSamplesPerBand]);
  }
  int peak = 0;
  float peakVal = 0;
  for (int i = 0; i < kLen; ++i) {
    if (std::fabs(out[i]) > peakVal) {
      peakVal = std::fabs(out[i]);
      peak = i;
    }
  }
  char detail[96];
  std::snprintf(detail, sizeof(detail),
                "(impulse peak at %d, want 242 +/- 1)", peak);
  check(peak >= 241 && peak <= 243, "resampler cascade delay", detail);
}

void testRnnoiseDirect() {
  // RNNoise on its own (48 kHz, 480-sample frames).
  //
  // The headline case is LOWPASSED noise (room tone / fan / traffic —
  // mostly < 2 kHz), where the model is strong. Full-band white noise
  // is deliberately NOT gated hard: the model leaves the 8-24 kHz
  // bands nearly untouched (its training data has little energy
  // there), so white noise only drops ~1 dB overall even though the
  // 0-8 kHz bands are suppressed ~5 dB. The white-noise check below
  // only guards against a dead model (pre-fix behaviour: exactly
  // 0.0 dB, vad 0 — the silence gate ate everything).
  DenoiseState* st = rnnoise_create(nullptr);
  check(st != nullptr, "rnnoise_create");
  if (st == nullptr) return;
  check(rnnoise_get_frame_size() == 480, "rnnoise frame size is 480");

  std::mt19937 rng(7);
  std::uniform_real_distribution<float> uni(-1.f, 1.f);
  float in[kRnnoiseFrameSize], out[kRnnoiseFrameSize];

  // Lowpassed noise (1-pole LP, mostly < 2 kHz): warm up 50 frames,
  // measure 100.
  float lp = 0;
  for (int f = 0; f < 50; ++f) {
    for (int i = 0; i < kRnnoiseFrameSize; ++i) {
      lp += 0.15f * (0.5f * uni(rng) - lp);
      in[i] = lp * 3.0f;
    }
    rnnoise_process_frame(st, out, in);
  }
  double inRms = 0, outRms = 0, vadSum = 0;
  for (int f = 0; f < 100; ++f) {
    for (int i = 0; i < kRnnoiseFrameSize; ++i) {
      lp += 0.15f * (0.5f * uni(rng) - lp);
      in[i] = lp * 3.0f;
    }
    inRms += rms(in, kRnnoiseFrameSize);
    vadSum += rnnoise_process_frame(st, out, in);
    outRms += rms(out, kRnnoiseFrameSize);
  }
  inRms /= 100;
  outRms /= 100;
  vadSum /= 100;
  const double reduction = 20 * std::log10(outRms / inRms);
  char detail[160];
  std::snprintf(detail, sizeof(detail),
                "(lowpassed noise in=%.4f out=%.4f, %.1f dB, vad=%.3f)",
                inRms, outRms, reduction, vadSum);
  check(outRms < inRms * 0.18,
        "rnnoise lowpassed-noise reduction >= 15 dB", detail);
  check(vadSum < 0.1, "rnnoise vad ~0 on noise-only", detail);

  // Full-band white noise: weak gate (any suppression at all).
  rnnoise_destroy(st);
  st = rnnoise_create(nullptr);
  for (int f = 0; f < 30; ++f) {
    for (int i = 0; i < kRnnoiseFrameSize; ++i) in[i] = 0.25f * uni(rng);
    rnnoise_process_frame(st, out, in);
  }
  inRms = 0;
  outRms = 0;
  for (int f = 0; f < 40; ++f) {
    for (int i = 0; i < kRnnoiseFrameSize; ++i) in[i] = 0.25f * uni(rng);
    inRms += rms(in, kRnnoiseFrameSize);
    rnnoise_process_frame(st, out, in);
    outRms += rms(out, kRnnoiseFrameSize);
  }
  inRms /= 40;
  outRms /= 40;
  std::snprintf(detail, sizeof(detail),
                "(white noise in=%.4f out=%.4f, %.1f dB — model leaves "
                "8-24 kHz alone, see comment)",
                inRms, outRms, 20 * std::log10(outRms / inRms));
  check(outRms < inRms * 0.95,
        "rnnoise white noise suppressed at all", detail);

  // Tone preservation on a fresh state.
  rnnoise_destroy(st);
  st = rnnoise_create(nullptr);
  double tIn = 0, tOut = 0;
  for (int f = 0; f < 70; ++f) {
    for (int i = 0; i < kRnnoiseFrameSize; ++i) {
      const float t =
          (float)(f * kRnnoiseFrameSize + i) / 48000.f;
      in[i] = 0.5f * std::sin(2.f * 3.14159265f * 1000.f * t);
    }
    rnnoise_process_frame(st, out, in);
    if (f >= 30) {
      tIn += rms(in, kRnnoiseFrameSize);
      tOut += rms(out, kRnnoiseFrameSize);
    }
  }
  tIn /= 40;
  tOut /= 40;
  std::snprintf(detail, sizeof(detail), "(tone in=%.4f out=%.4f)", tIn,
                tOut);
  check(tOut > tIn * 0.7, "rnnoise tone preserved >= 70%", detail);
  rnnoise_destroy(st);
}

void testBridgeEndToEnd() {
  RnnoiseBridge bridge;
  check(bridge.init(48000, 1), "bridge init 48kHz mono");
  check(bridge.isInitialized(), "bridge isInitialized");
  check(!bridge.init(48000, 2), "bridge init rejects stereo");
  check(bridge.init(48000, 1), "bridge re-init after failed init");

  // Synthetic 3-band APM frame: band 0 = 1 kHz tone + noise (at the
  // band's effective 16 kHz rate), bands 1-2 = noise only.
  std::mt19937 rng(11);
  std::uniform_real_distribution<float> uni(-1.f, 1.f);
  float bands[kMaxBands * kSamplesPerBand];
  float band0In[kSamplesPerBand];
  double toneIn = 0, toneOut = 0, noiseIn = 0, noiseOut = 0;
  for (int f = 0; f < 100; ++f) {
    for (int i = 0; i < kSamplesPerBand; ++i) {
      const float t =
          (float)(f * kSamplesPerBand + i) / 16000.f;
      band0In[i] =
          0.4f * std::sin(2.f * 3.14159265f * 1000.f * t) +
          0.2f * uni(rng);
    }
    std::memcpy(bands, band0In, sizeof(band0In));
    for (int b = 1; b < 3; ++b) {
      for (int i = 0; i < kSamplesPerBand; ++i) {
        bands[b * kSamplesPerBand + i] = 0.25f * uni(rng);
      }
    }
    const double b1In = rms(bands + kSamplesPerBand, kSamplesPerBand);
    bridge.process(bands, 3, kSamplesPerBand);
    if (f >= 50) {
      toneIn += rms(band0In, kSamplesPerBand);
      toneOut += rms(bands, kSamplesPerBand);
      noiseIn += b1In;
      noiseOut += rms(bands + kSamplesPerBand, kSamplesPerBand);
    }
  }
  toneIn /= 50;
  toneOut /= 50;
  noiseIn /= 50;
  noiseOut /= 50;
  char detail[160];
  std::snprintf(detail, sizeof(detail),
                "(band0 tone+noise in=%.4f out=%.4f; band1 noise "
                "in=%.4f out=%.4f)",
                toneIn, toneOut, noiseIn, noiseOut);
  check(toneOut > toneIn * 0.5,
        "bridge: band 0 tone survives", detail);
  check(noiseOut < noiseIn * 0.6,
        "bridge: band 1 noise gated down", detail);
  check(bridge.framesProcessed() == 100, "bridge framesProcessed == 100");
  check(bridge.lastError() == kBridgeOk, "bridge lastError == ok");
  check(bridge.lastVoiceProb() > 0.f && bridge.lastVoiceProb() <= 1.f,
        "bridge lastVoiceProb in (0,1]");
}

// Speech proxy: harmonic stack, f0 120 Hz with vibrato, syllabic AM.
// A steady pure tone is out-of-distribution for a speech denoiser
// (zero spectral variability reads as "stationary noise"); real speech
// is modulated, so the proxy must be too. 16 kHz version (band rate).
float speechProxySample16k(double t, double& phase) {
  const double f0 = 120.0 * (1.0 + 0.03 * std::sin(2 * M_PI * 5.0 * t));
  phase += 2 * M_PI * f0 / 16000.0;
  if (phase > 2 * M_PI) phase -= 2 * M_PI;
  double s = 0;
  const double weights[12] = {1.0, 0.9, 0.8, 0.7, 0.9, 1.0,
                              0.8, 0.5, 0.6, 0.7, 0.4, 0.3};
  for (int h = 1; h <= 12; ++h) {
    s += weights[h - 1] * std::sin(h * phase) / h;
  }
  const double am =
      0.65 + 0.35 * std::sin(2 * M_PI * 4.0 * t) *
                        std::sin(2 * M_PI * 0.7 * t + 1.0);
  return (float)(0.25 * s * am);
}

void testBridgeSpeechProxy() {
  // Most deployment-realistic check: band 0 carries the speech proxy
  // + lowpassed noise at ~+10 dB SNR; bands 1-2 carry noise only.
  // Speech must survive (output RMS close to the clean-speech RMS)
  // while the noise-only bands are gated down.
  RnnoiseBridge bridge;
  check(bridge.init(48000, 1), "bridge(speech) init 48kHz mono");
  std::mt19937 rng(17);
  std::uniform_real_distribution<float> uni(-1.f, 1.f);
  float bands[kMaxBands * kSamplesPerBand];
  double phase = 0;
  float lp = 0, lp1 = 0, lp2 = 0;
  double cleanRms = 0, outRms = 0, b1In = 0, b1Out = 0;
  int measured = 0;
  for (int f = 0; f < 200; ++f) {
    float clean[kSamplesPerBand];
    for (int i = 0; i < kSamplesPerBand; ++i) {
      const double t = (double)(f * kSamplesPerBand + i) / 16000.0;
      clean[i] = speechProxySample16k(t, phase);
      lp += 0.3f * (0.3f * uni(rng) - lp);
      bands[i] = clean[i] + lp * 0.8f;
      lp1 += 0.3f * (0.3f * uni(rng) - lp1);
      bands[kSamplesPerBand + i] = lp1 * 2.0f;
      lp2 += 0.3f * (0.3f * uni(rng) - lp2);
      bands[2 * kSamplesPerBand + i] = lp2 * 2.0f;
    }
    const double b1 = rms(bands + kSamplesPerBand, kSamplesPerBand);
    bridge.process(bands, 3, kSamplesPerBand);
    if (f >= 100) {
      cleanRms += rms(clean, kSamplesPerBand);
      outRms += rms(bands, kSamplesPerBand);
      b1In += b1;
      b1Out += rms(bands + kSamplesPerBand, kSamplesPerBand);
      ++measured;
    }
  }
  cleanRms /= measured;
  outRms /= measured;
  b1In /= measured;
  b1Out /= measured;
  char detail[192];
  std::snprintf(detail, sizeof(detail),
                "(band0 clean speech=%.4f, noisy output=%.4f; band1 "
                "noise in=%.4f out=%.4f)",
                cleanRms, outRms, b1In, b1Out);
  check(outRms > cleanRms * 0.6 && outRms < cleanRms * 1.4,
        "bridge: speech proxy survives in noise", detail);
  check(b1Out < b1In * 0.5, "bridge: noise-only band gated >= 6 dB",
        detail);
  check(bridge.lastVoiceProb() > 0.5,
        "bridge: vad high on speech in noise", detail);
}

void testBypassAndFailOpen() {
  RnnoiseBridge bridge;
  check(bridge.init(32000, 1), "bridge init 32kHz mono");
  float bands[2 * kSamplesPerBand];
  float copy[2 * kSamplesPerBand];
  std::mt19937 rng(3);
  std::uniform_real_distribution<float> uni(-0.5f, 0.5f);
  for (int i = 0; i < 2 * kSamplesPerBand; ++i) bands[i] = uni(rng);
  std::memcpy(copy, bands, sizeof(bands));

  bridge.setBypass(true);
  bridge.process(bands, 2, kSamplesPerBand);
  check(std::memcmp(bands, copy, sizeof(bands)) == 0,
        "bypass is bit-identical passthrough");
  bridge.setBypass(false);

  // Bad frame size: untouched + error recorded.
  bridge.process(bands, 2, 100);
  check(std::memcmp(bands, copy, sizeof(bands)) == 0,
        "bad numFrames passes through untouched");
  check(bridge.lastError() == kBridgeBadFrameSize,
        "bad numFrames sets lastError");
  // Bad band count.
  bridge.process(bands, 5, kSamplesPerBand);
  check(bridge.lastError() == kBridgeBadBandCount,
        "bad numBands sets lastError");
  // Null buffer: no crash.
  bridge.process(nullptr, 2, kSamplesPerBand);
  check(true, "null buffer does not crash");

  // Uninitialized bridge passes through.
  RnnoiseBridge fresh;
  fresh.process(bands, 2, kSamplesPerBand);
  check(std::memcmp(bands, copy, sizeof(bands)) == 0,
        "uninitialized bridge passes through");
  check(fresh.lastError() == kBridgeOk,
        "uninitialized bridge keeps lastError ok");
}

void testDeterminism() {
  RnnoiseBridge a, b;
  a.init(48000, 1);
  b.init(48000, 1);
  std::mt19937 rng(99);
  std::uniform_real_distribution<float> uni(-0.4f, 0.4f);
  float fa[kMaxBands * kSamplesPerBand];
  float fb[kMaxBands * kSamplesPerBand];
  bool identical = true;
  for (int f = 0; f < 30; ++f) {
    for (int i = 0; i < kMaxBands * kSamplesPerBand; ++i) {
      fa[i] = uni(rng);
    }
    std::memcpy(fb, fa, sizeof(fa));
    a.process(fa, 3, kSamplesPerBand);
    b.process(fb, 3, kSamplesPerBand);
    if (std::memcmp(fa, fb, sizeof(fa)) != 0) identical = false;
  }
  check(identical, "determinism: two bridges, identical output");
}

}  // namespace

int main() {
  std::printf("=== RNNoise bridge host test ===\n");
  testFilterDcGain();
  testRoundTripSnr();
  testRoundTripSpeechBand();
  testImaging();
  testCascadeDelay();
  testRnnoiseDirect();
  testBridgeEndToEnd();
  testBridgeSpeechProxy();
  testBypassAndFailOpen();
  testDeterminism();
  std::printf("=== %d checks, %d failures ===\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
