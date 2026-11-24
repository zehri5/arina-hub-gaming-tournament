#!/bin/bash
# Host smoke test for the v3 CompressorProcessor + setCompressor path
# (Arena Hub #10 audio, compressor adoption).
# Compiles dsp_engine.cpp WITHOUT JNI on the Linux host and runs the
# measurements in test_compressor.cpp. No Android SDK, no device, no
# APK needed. Exit 0 = all checks pass.
#
# Host-only: CMakeLists lists only dsp_engine.cpp + audio_dsp_jni.cpp,
# so this harness can never ship in libaudio_dsp.so.
set -euo pipefail
cd "$(dirname "$0")"

CXX="${CXX:-g++}"
BUILD_DIR="${BUILD_DIR:-/tmp/compressor-host-build}"
mkdir -p "$BUILD_DIR"

"$CXX" -std=c++17 -O2 -Wall -Wextra \
  -I.. \
  test_compressor.cpp ../dsp_engine.cpp \
  -o "$BUILD_DIR/test_compressor" -lm

"$BUILD_DIR/test_compressor"
