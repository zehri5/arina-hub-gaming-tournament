// GROUP 7 DSP — AUDIO #10: thin JNI wrapper over DspMicBridge.
//
// Structure mirrors Group 2's proven rnnoise_jni.cpp: one global bridge
// instance, one native per operation, no logic here beyond null checks
// and the GetDirectBufferAddress/Capacity calls. All routing, format
// detection, EQ and safety logic lives in the JNI-free bridge
// (dsp_mic_bridge.cpp), which is host-testable.
//
// WHY A SECOND JNI FILE (vs the external audio_dsp_jni.cpp)
// ---------------------------------------------------------
// The external plugin's nativeProcess() takes a jbyteArray and returns a
// fresh jbyteArray — two allocations + two copies per call. WebRTC's
// capture post-processing callback fires every 10 ms on the real-time
// audio thread; allocating there churns the GC and risks audio glitches.
// The callback hands us a DIRECT ByteBuffer, so nativeProcess() operates
// IN PLACE on its address and never allocates. The external plugin stays
// untouched (Groups 3/4/5 own it) and remains the control-plane API for
// the music (stereo) instance.
//
// These natives are bound to com.protournament.app.DspMicProcessor
// (@JvmStatic in the companion object, hence jclass). The Kotlin side
// loads libaudio_dsp with a try/catch (nativeLoaded flag), so a missing
// .so never crashes startup — the Dart side fails open.

#include <jni.h>

#include "dsp_mic_bridge.h"

namespace {

arena_dsp::DspMicBridge g_bridge;

}  // namespace

extern "C" {

JNIEXPORT jboolean JNICALL
Java_com_protournament_app_DspMicProcessor_nativeInit(
    JNIEnv* /* env */,
    jclass /* clazz */,
    jint sample_rate,
    jint num_channels) {
    return g_bridge.init(static_cast<int>(sample_rate),
                         static_cast<int>(num_channels))
               ? JNI_TRUE
               : JNI_FALSE;
}

JNIEXPORT jboolean JNICALL
Java_com_protournament_app_DspMicProcessor_nativeProcess(
    JNIEnv* env,
    jclass /* clazz */,
    jobject buffer,
    jint num_bands,
    jint num_frames) {
    if (buffer == nullptr) {
        return JNI_FALSE;
    }
    uint8_t* data =
        static_cast<uint8_t*>(env->GetDirectBufferAddress(buffer));
    if (data == nullptr) {
        return JNI_FALSE;  // not a direct buffer — never guess
    }
    const jlong capacity = env->GetDirectBufferCapacity(buffer);
    if (capacity < 0) {
        return JNI_FALSE;
    }
    return g_bridge.processBuffer(
               data, static_cast<size_t>(capacity),
               static_cast<int>(num_bands), static_cast<int>(num_frames))
               ? JNI_TRUE
               : JNI_FALSE;
}

JNIEXPORT void JNICALL
Java_com_protournament_app_DspMicProcessor_nativeSetEq(
    JNIEnv* /* env */,
    jclass /* clazz */,
    jboolean enabled,
    jfloat bass_boost_db,
    jfloat low_gain_db,
    jfloat mid_gain_db,
    jfloat high_gain_db) {
    g_bridge.setEq(enabled == JNI_TRUE, static_cast<float>(bass_boost_db),
                   static_cast<float>(low_gain_db),
                   static_cast<float>(mid_gain_db),
                   static_cast<float>(high_gain_db));
}

JNIEXPORT void JNICALL
Java_com_protournament_app_DspMicProcessor_nativeSetEcho(
    JNIEnv* /* env */,
    jclass /* clazz */,
    jboolean enabled,
    jfloat delay_ms,
    jfloat feedback,
    jfloat mix) {
    g_bridge.setEcho(enabled == JNI_TRUE, static_cast<float>(delay_ms),
                     static_cast<float>(feedback), static_cast<float>(mix));
}

JNIEXPORT void JNICALL
Java_com_protournament_app_DspMicProcessor_nativeSetReverb(
    JNIEnv* /* env */,
    jclass /* clazz */,
    jboolean enabled,
    jfloat wet_dry_mix,
    jfloat room_size,
    jfloat damping) {
    g_bridge.setReverb(enabled == JNI_TRUE,
                       static_cast<float>(wet_dry_mix),
                       static_cast<float>(room_size),
                       static_cast<float>(damping));
}

// RJ STUDIO (2026-11-22): live noise-gate control for the host mic
// chain — the 10th native. Same thin pattern as setEq/setEcho/setReverb.
JNIEXPORT void JNICALL
Java_com_protournament_app_DspMicProcessor_nativeSetNoiseGate(
    JNIEnv* /* env */,
    jclass /* clazz */,
    jboolean enabled,
    jfloat threshold_db,
    jfloat attack_ms,
    jfloat release_ms) {
    g_bridge.setNoiseGate(enabled == JNI_TRUE,
                          static_cast<float>(threshold_db),
                          static_cast<float>(attack_ms),
                          static_cast<float>(release_ms));
}

// DSP v3 (2026-11-22): live compressor control for the host mic chain
// — the 11th native. Same thin pattern as the other setters.
JNIEXPORT void JNICALL
Java_com_protournament_app_DspMicProcessor_nativeSetCompressor(
    JNIEnv* /* env */,
    jclass /* clazz */,
    jboolean enabled,
    jfloat threshold_db,
    jfloat ratio,
    jfloat attack_ms,
    jfloat release_ms,
    jfloat makeup_gain_db) {
    g_bridge.setCompressor(enabled == JNI_TRUE,
                           static_cast<float>(threshold_db),
                           static_cast<float>(ratio),
                           static_cast<float>(attack_ms),
                           static_cast<float>(release_ms),
                           static_cast<float>(makeup_gain_db));
}

JNIEXPORT void JNICALL
Java_com_protournament_app_DspMicProcessor_nativeSetBypass(
    JNIEnv* /* env */,
    jclass /* clazz */,
    jboolean bypass) {
    g_bridge.setBypass(bypass == JNI_TRUE);
}

// SOUNDBOARD (route A, 2026-11-22): the 12th-15th natives. The clip
// crosses JNI ONCE at load as a 48 kHz mono float array (the Dart
// decoder's output); the bridge keeps the original + a 16 kHz
// decimated copy and mixes the active clip into band 0 after the DSP
// chain. See dsp_mic_bridge.h + SOUNDBOARD_INTEGRATION.md §3.
// The Kotlin declarations (merge-time, DspMicProcessor.kt) must match
// these signatures exactly:
//   nativeLoadSoundboardClip(samples: FloatArray, sampleRate: Int): Boolean
//   nativePlaySoundboardClip(gain: Float)
//   nativeStopSoundboardClip()
//   nativeSetSoundboardClipGain(gain: Float)
JNIEXPORT jboolean JNICALL
Java_com_protournament_app_DspMicProcessor_nativeLoadSoundboardClip(
    JNIEnv* env,
    jclass /* clazz */,
    jfloatArray samples,
    jint sample_rate) {
    if (samples == nullptr) {
        return JNI_FALSE;
    }
    const jsize len = env->GetArrayLength(samples);
    if (len <= 0) {
        return JNI_FALSE;
    }
    jfloat* elems = env->GetFloatArrayElements(samples, nullptr);
    if (elems == nullptr) {
        return JNI_FALSE;
    }
    const bool ok = g_bridge.loadClip(
        static_cast<const float*>(elems), static_cast<size_t>(len),
        static_cast<int>(sample_rate));
    // JNI_ABORT: the bridge copied what it needed; never write back.
    env->ReleaseFloatArrayElements(samples, elems, JNI_ABORT);
    return ok ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT void JNICALL
Java_com_protournament_app_DspMicProcessor_nativePlaySoundboardClip(
    JNIEnv* /* env */,
    jclass /* clazz */,
    jfloat gain) {
    g_bridge.playClip(static_cast<float>(gain));
}

JNIEXPORT void JNICALL
Java_com_protournament_app_DspMicProcessor_nativeStopSoundboardClip(
    JNIEnv* /* env */,
    jclass /* clazz */) {
    g_bridge.stopClip();
}

JNIEXPORT void JNICALL
Java_com_protournament_app_DspMicProcessor_nativeSetSoundboardClipGain(
    JNIEnv* /* env */,
    jclass /* clazz */,
    jfloat gain) {
    g_bridge.setClipGain(static_cast<float>(gain));
}

JNIEXPORT void JNICALL
Java_com_protournament_app_DspMicProcessor_nativeRelease(
    JNIEnv* /* env */,
    jclass /* clazz */) {
    g_bridge.release();
}

JNIEXPORT jlong JNICALL
Java_com_protournament_app_DspMicProcessor_nativeGetFramesProcessed(
    JNIEnv* /* env */,
    jclass /* clazz */) {
    return static_cast<jlong>(g_bridge.framesProcessed());
}

JNIEXPORT jint JNICALL
Java_com_protournament_app_DspMicProcessor_nativeGetLastError(
    JNIEnv* /* env */,
    jclass /* clazz */) {
    return static_cast<jint>(g_bridge.lastError());
}

}  // extern "C"
