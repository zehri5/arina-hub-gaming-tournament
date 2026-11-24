#!/bin/bash
# Host test for the RNNoise per-band bridge (Group 2, #10 audio).
# Compiles the bridge + vendored RNNoise C on the Linux host and runs
# the checks in test_rnnoise_bridge.cpp. No Android SDK, no device, no
# APK needed. Exit 0 = all checks pass.
#
# NOTE: the C sources must be compiled with a C compiler (gcc) and the
# C++ sources with g++ — g++ alone would compile the .c files as C++.
# (Android CMake gets this right by file extension.)
set -euo pipefail
cd "$(dirname "$0")"

CC="${CC:-gcc}"
CXX="${CXX:-g++}"
BUILD_DIR="${BUILD_DIR:-/tmp/rnnoise-host-build}"
mkdir -p "$BUILD_DIR"

for f in denoise kiss_fft pitch celt_lpc rnn rnn_data; do
  # gnu11 (not strict c11): denoise.c uses M_PI from math.h.
  "$CC" -std=gnu11 -O2 -Wall \
    -I../rnnoise/include -I../rnnoise/src \
    -c "../rnnoise/src/$f.c" -o "$BUILD_DIR/$f.o"
done
"$CXX" -std=c++17 -O2 -Wall -Wextra \
  -I../rnnoise/include -I.. \
  -c ../rnnoise_bridge.cpp -o "$BUILD_DIR/rnnoise_bridge.o"
"$CXX" -std=c++17 -O2 -Wall -Wextra \
  -I../rnnoise/include -I.. \
  -c test_rnnoise_bridge.cpp -o "$BUILD_DIR/test_rnnoise_bridge.o"
"$CXX" "$BUILD_DIR"/*.o -o /tmp/test_rnnoise_bridge -lm

/tmp/test_rnnoise_bridge
