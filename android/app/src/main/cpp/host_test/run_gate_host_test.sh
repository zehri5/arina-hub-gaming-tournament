#!/bin/bash
# Host test for the NoiseGateProcessor (v2 DSP engine, #10 audio, gate group).
# Compiles dsp_engine.cpp WITHOUT JNI on the Linux host and runs the
# checks in test_noise_gate.cpp. No Android SDK, no device, no APK needed.
# Exit 0 = all checks pass.
set -euo pipefail
cd "$(dirname "$0")"

CXX="${CXX:-g++}"
BUILD_DIR="${BUILD_DIR:-/tmp/gate-host-build}"
mkdir -p "$BUILD_DIR"

"$CXX" -std=c++17 -O2 -Wall -Wextra -I.. \
  -c ../dsp_engine.cpp -o "$BUILD_DIR/dsp_engine.o"
"$CXX" -std=c++17 -O2 -Wall -Wextra -I.. \
  -c test_noise_gate.cpp -o "$BUILD_DIR/test_noise_gate.o"
"$CXX" "$BUILD_DIR/dsp_engine.o" "$BUILD_DIR/test_noise_gate.o" \
  -o /tmp/test_noise_gate -lm

/tmp/test_noise_gate
