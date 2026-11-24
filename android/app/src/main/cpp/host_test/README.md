# host_test/ — HOST-ONLY, never shipped

Small g++ harnesses for the DSP engine (`../dsp_engine.cpp`) and the
mic bridge (`../dsp_mic_bridge.cpp`). They compile the REAL engine
sources WITHOUT the JNI files and need no Android SDK/NDK. Build
outputs go to `/tmp`, never into the project tree.

**Do NOT add this directory to `CMakeLists.txt`** (it lists sources
explicitly: `dsp_engine.cpp` + `audio_dsp_jni.cpp` + the mic/rnnoise
bridges) and do NOT package it in the APK.

## Harnesses (all folded here by the DSP fold, 2026-11-22)

| File | Source | What it checks |
|---|---|---|
| `reverb_host_test.cpp` | G3 DSP | Freeverb: NaN→dry, stale-tail reset, tail behaviour |
| `unconfigured_test.cpp` | G3 DSP | Unconfigured Freeverb process() must not crash (SEGFAULT guard) |
| `echo_harness.cpp` | G4 DSP | Echo: delay accuracy, NaN keep-current, ghost echo, slew/chirp, stereo, PCM16 end-to-end |
| `eq_smoke_test.cpp` | G5 DSP | EQ: click-free enable/disable crossfade, NaN→0 dB, PCM16 end-to-end |
| `test_noise_gate.cpp` | Gate DSP | Noise gate: pass/silence, hysteresis, attack/release, NaN params, stereo, 16 kHz |
| `test_compressor.cpp` | Comp DSP | Compressor: steady-state ratio, attack/release, makeup, NaN guards, envelope clear on disable |
| `host_dsp_smoke_test.cpp` | G10 DSP | Full-chain DspEngine smoke: impulse/sine, edge params, streaming, null/odd input |
| `dsp_mic_rj_bridge_check.cpp` | RJ mic bridge | REAL bridge + engine: full-band/per-band routing, dual format, bypass, live gate/comp params |
| `test_rnnoise_bridge.cpp` | G2 | RNNoise bridge (pre-existing in this tree; not a DSP-fold file) |

## Build & run (from `android/app/src/main/cpp`)

```sh
# G3 Freeverb (two binaries; the unconfigured probe is separate so a
# pre-fix crash cannot kill the main harness report)
g++ -std=c++17 -O2 -Wall -Wextra -I. -o /tmp/reverb_host_test \
    host_test/reverb_host_test.cpp dsp_engine.cpp && /tmp/reverb_host_test
g++ -std=c++17 -O2 -Wall -Wextra -I. -o /tmp/unconfigured_test \
    host_test/unconfigured_test.cpp dsp_engine.cpp && /tmp/unconfigured_test

# G4 Echo
g++ -std=c++17 -O2 -Wall -Wextra -I. -o /tmp/echo_harness \
    host_test/echo_harness.cpp dsp_engine.cpp && /tmp/echo_harness

# G5 EQ
g++ -std=c++17 -O2 -Wall -Wextra -I. -o /tmp/eq_smoke_test \
    host_test/eq_smoke_test.cpp dsp_engine.cpp && /tmp/eq_smoke_test

# Gate (or run host_test/run_gate_host_test.sh)
g++ -std=c++17 -O2 -Wall -Wextra -I. -o /tmp/test_noise_gate \
    host_test/test_noise_gate.cpp dsp_engine.cpp && /tmp/test_noise_gate

# Compressor (or run host_test/run_compressor_test.sh)
g++ -std=c++17 -O2 -Wall -Wextra -I. -o /tmp/test_compressor \
    host_test/test_compressor.cpp dsp_engine.cpp && /tmp/test_compressor

# G10 full-chain smoke
g++ -std=c++17 -O2 -Wall -Wextra -I. -o /tmp/dsp_smoke_test \
    host_test/host_dsp_smoke_test.cpp dsp_engine.cpp && /tmp/dsp_smoke_test

# RJ mic bridge (compiles the REAL bridge + engine)
g++ -std=c++17 -O2 -Wall -Wextra -I. -o /tmp/dsp_mic_rj_check \
    host_test/dsp_mic_rj_bridge_check.cpp dsp_engine.cpp dsp_mic_bridge.cpp \
    && /tmp/dsp_mic_rj_check
```

Exit 0 = all checks pass. Zero compiler warnings expected on every
build.
