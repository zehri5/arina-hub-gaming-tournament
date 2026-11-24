# RNNoise native engine — Arena Hub #10 audio, Group 2

Vendored **xiph/rnnoise** C library (BSD, see `COPYING`) + the Arena Hub
per-band bridge that routes live mic frames through it. This README is
the honest record of what the native side is, what it does, and what
was verified where.

## Architecture (the full route, Dart → mic)

```
Dart: RnnoiseMicProcessor.buildProcessor()
  → livekit_client TrackProcessor seam (AudioCaptureOptions.processor
    → LocalTrack.setProcessor → init(AudioProcessorOptions))
  → MethodChannel "arena_hub_rnnoise" ("init", trackId)
  → Kotlin RnnoiseProcessor (android/.../RnnoiseProcessor.kt)
  → flutter_webrtc AudioProcessingController.capturePostProcessing
    .addProcessor(RnnoiseAudioProcessor)   // WebRTC APM capture hook,
                                           // same hook the Krisp plugin uses
  → APM calls process(numBands, numFrames, ByteBuffer) every 10 ms
  → JNI nativeProcess (cpp/rnnoise_jni.cpp, zero-copy direct buffer)
  → RnnoiseBridge::process (cpp/rnnoise_bridge.cpp)
  → per band: 3x upsample (16 kHz → 48 kHz) → rnnoise_process_frame
    → 3x downsample (48 kHz → 16 kHz), in place
```

**Why per-band.** The APM hands the hook *split-band* float32 audio:
`numBands` (1–3) × `numFrames` (160) samples, planar, band-major.
Each band is 10 ms at an effective 16 kHz (band 0 = 0–8 kHz,
band 1 = 8–16 kHz, band 2 = 16–24 kHz). RNNoise is a 48 kHz
full-band model (480-sample frames), so each band is resampled to
48 kHz, denoised by its own `DenoiseState`, and resampled back.
Processing bands independently is also what WebRTC's own noise
suppressor does, and it avoids a second pass through WebRTC's
lossy analysis/synthesis filterbank. The resampler is a
Blackman-windowed-sinc FIR (127 taps, coefficients generated at
runtime — no transcribed tables). Added latency is a constant
~2.6 ms (126 samples @ 48 kHz); the hook runs *after* AEC in the
APM pipeline, so the extra delay does not disturb echo cancellation.

**Build wiring.** `cpp/CMakeLists.txt` builds `libarena_rnnoise.so`
(RNNoise C + bridge + JNI); `android/app/build.gradle.kts` points
`externalNativeBuild.cmake` at it; `MainActivity.kt` registers the
`arena_hub_rnnoise` channel. If the `.so` is absent (old APK, build
without CMake), the Kotlin side catches the load failure and the
Dart side fails open to unprocessed mic audio.

## The denoise.c scaling fix (read before touching the vendored code)

The vendored `kiss_fft` is **Opus's** variant, whose `rnn_fft_c()`
scales its input by `1/N` (`kiss_fft.c`: `st->scale = 1.f/nfft` in
the float path). Upstream RNNoise uses un-normalized kissfft, and
every calibration in `denoise.c` — the `E < 0.04` silence gate,
`Ly = log10(1e-2+Ex)`, the feature offsets, the pitch-correlation
normalization — assumes un-normalized spectra.

As vendored, the silence gate ate everything below ~RMS 0.45
(verified on host: a 0.5-amplitude tone came out untouched with
`vad_prob = 0.0000`), and even loud input was miscalibrated
(only −3.5 dB on loud white noise). The fix, in `src/denoise.c`
(marked `ARENA HUB FIX`):

* `forward_transform()`: multiply the FFT output by `WINDOW_SIZE`
  (undo the 1/N) so the analysis spectra match upstream.
* `inverse_transform()`: remove the `WINDOW_SIZE` multiplier (the
  1/N inside `rnn_fft` already provides the IFFT normalization).

The two changes cancel exactly in the synthesis path, so the audio
path is bit-identical to before the fix — only the analysis
calibration is restored. Do NOT "fix" one without the other.

## Host verification (all numbers measured, 2026-11-22)

Run: `cpp/host_test/run_host_test.sh` (g++ on Linux, no Android SDK).
**33 checks, 0 failures.**

| Check | Measured | Bar |
|---|---|---|
| Resampler filter DC gain | 3.0000 | ~3.0 |
| Resampler round-trip SNR, full-band white noise | 23.0 dB | > 20 dB |
| Resampler round-trip SNR, speech band (< 6 kHz) | **82.5 dB** | > 45 dB |
| Resampler imaging suppression | −118.6 dB | < −50 dB |
| Resampler cascade delay | 42 samples @ 16 kHz (2.6 ms) | 242 ± 1 |
| RNNoise: lowpassed noise (room/fan-like) | **−20.1 dB**, vad 0.015 | ≥ 15 dB |
| RNNoise: 1 kHz tone preserved | 0.3536 → 0.3543 RMS | ≥ 70% |
| RNNoise: full-band white noise | −1.4 dB (see note) | any suppression |
| Bridge: speech proxy in noise (band 0) | clean 0.1342 → out 0.1112, vad high | survives |
| Bridge: noise-only band (band 1) | 0.1459 → 0.0016 (**−39 dB**) | ≥ 6 dB |
| Bridge: bypass | bit-identical passthrough | exact |
| Bridge: bad numFrames / numBands / null / stereo / uninitialized | passthrough + `lastError` set | fail-open |
| Bridge: determinism (two bridges, same input) | identical output | exact |

**Notes on the two weak-looking numbers.**

* *Full-band round-trip SNR 23 dB.* A half-band FIR rolls off
  through its transition band (~7–9 kHz here), so white noise —
  which fills the whole 0–8 kHz band — loses energy at the 7–8 kHz
  edge. Speech lives below 6 kHz, where the round trip is 82.5 dB
  (transparent). A longer filter would sharpen the edge but cost
  latency (255 taps = 5.3 ms); 127 taps / 2.6 ms is the chosen
  trade-off.
* *Full-band white noise −1.4 dB.* The RNNoise model leaves the
  8–24 kHz bands nearly untouched (its training data has little
  energy there), so full-band white noise barely drops overall even
  though the 0–8 kHz bands are suppressed ~5 dB. Realistic noises
  (lowpassed / room tone / fan) are suppressed 20+ dB. In the
  deployment path each band is 0–8 kHz content, so the weak high
  bands never see full-band white noise.
* *Very low SNR.* At ~0 dB SNR with noise dominating the same
  frequencies as the (synthetic, steady) speech proxy, the model
  over-suppresses. Real speech has transients and high-frequency
  content the proxy lacks; real-speech behaviour needs the phone
  test below.

## What is NOT verified (needs a phone)

* The APM buffer layout (split-band float32 planar, band-major) is
  taken from the WebRTC `ExternalAudioProcessing` contract and the
  Krisp plugin's identical usage — it is **not** proven on-device
  here. If the buffer were full-band instead, the bridge would
  misinterpret it (it would still fail open on shape checks only if
  `numFrames != 160`).
* The Kotlin registration path (`MainActivity` → channel →
  `capturePostProcessing.addProcessor`) compiles against
  flutter_webrtc 1.6.3 APIs verified in the pub cache, but the
  Kotlin was **not compiled** in this task (no Gradle build allowed
  here) — the merge build is the first compile check.
* No APK was built; no real mic audio has run through this yet.
  First phone test: join a voice room with background noise, check
  `framesProcessed` grows (Dart `RnnoiseTrackProcessor.framesProcessed()`)
  and the far end hears less noise; toggle `setBypass(true)` to
  A/B the effect.

## Files

| File | What |
|---|---|
| `rnnoise/src/*.c`, `rnnoise/include/rnnoise.h` | Vendored xiph/rnnoise (BSD). `denoise.c` carries the 2-line scaling fix above. |
| `cpp/rnnoise_bridge.h/.cpp` | JNI-free bridge: per-band resample → RNNoise → resample. Host-testable. |
| `cpp/rnnoise_jni.cpp` | Thin JNI wrapper (one global bridge instance). |
| `cpp/CMakeLists.txt` | Builds `libarena_rnnoise.so`. |
| `cpp/host_test/` | Host test harness (`run_host_test.sh` + `test_rnnoise_bridge.cpp`). |
| `../kotlin/com/protournament/app/RnnoiseProcessor.kt` | Frame hook + MethodChannel handler. |
