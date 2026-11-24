# Arena Hub native audio libraries (#10 audio).
#
# TWO targets, one file (merged 2026-11-22, RJ Studio):
#
# 1. arena_rnnoise — Group 2: the vendored xiph/rnnoise C engine
#    (rnnoise/, BSD-licensed) plus the per-band bridge
#    (rnnoise_bridge.cpp) and its thin JNI wrapper (rnnoise_jni.cpp),
#    loaded by com.protournament.app.RnnoiseProcessor.
# 2. audio_dsp — external DSP engine (Google AI Studio, v3) plus the
#    Group 7 mic bridge: dsp_engine.cpp + audio_dsp_jni.cpp
#    (UNTOUCHED external code — see the fold notes) + dsp_mic_bridge.cpp
#    + dsp_mic_jni.cpp, loaded by com.protournament.app.DspMicProcessor
#    and com.arenahub.app.dsp.AudioDspPlugin.
#
# Wired into the app by android/app/build.gradle.kts
# (externalNativeBuild.cmake.path).
#
# NOTE: the host test harnesses live in host_test/ and are deliberately
# NOT part of this build (sources are listed explicitly, never globbed).

cmake_minimum_required(VERSION 3.22.1)

project("arena_audio")

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
# Keep the RNNoise numerics as upstream wrote them: no fast-math.
set(CMAKE_C_STANDARD 11)

find_library(log-lib log)

# --- Target 1: RNNoise (Group 2) ---
add_library(
    arena_rnnoise
    SHARED
    # Vendored xiph/rnnoise (see rnnoise/COPYING).
    rnnoise/src/denoise.c
    rnnoise/src/kiss_fft.c
    rnnoise/src/pitch.c
    rnnoise/src/celt_lpc.c
    rnnoise/src/rnn.c
    rnnoise/src/rnn_data.c
    # Per-band bridge + JNI wrapper (Arena Hub).
    rnnoise_bridge.cpp
    rnnoise_jni.cpp
)

target_include_directories(arena_rnnoise PRIVATE rnnoise/include)
target_link_libraries(arena_rnnoise ${log-lib})

# --- Target 2: DSP engine + mic bridge (external v3 + Group 7) ---
add_library(
    audio_dsp
    SHARED
    dsp_engine.cpp
    audio_dsp_jni.cpp
    # Mic path (Group 7, #10 audio): JNI-free bridge + thin JNI wrapper.
    # The engine files above are UNTOUCHED external code.
    dsp_mic_bridge.cpp
    dsp_mic_jni.cpp
)

target_compile_options(
    audio_dsp
    PRIVATE
    -O3
    -fno-math-errno
    -Wall
    -Wextra
)

target_link_libraries(
    audio_dsp
    ${log-lib}
)
