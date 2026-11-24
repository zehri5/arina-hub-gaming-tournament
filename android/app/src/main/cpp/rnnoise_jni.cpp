// Thin JNI wrapper over RnnoiseBridge (rnnoise_bridge.h).
//
// One global bridge instance: the APM capture post-processing hook is
// global to the PeerConnectionFactory, and there is only ever one live
// mic track, so a single bridge is correct. All calls are fail-open —
// a bad buffer or an uninitialized bridge is a silent no-op, never a
// crash on the audio thread.
//
// Method names must match the @JvmStatic external funs in
// com.protournament.app.RnnoiseProcessor (RnnoiseProcessor.kt).

#include <jni.h>

#include "rnnoise_bridge.h"

namespace {
arena_rnnoise::RnnoiseBridge g_bridge;
}  // namespace

extern "C" {

JNIEXPORT jboolean JNICALL
Java_com_protournament_app_RnnoiseProcessor_nativeInit(JNIEnv* env,
                                                       jclass /* clazz */,
                                                       jint sampleRateHz,
                                                       jint numChannels) {
  (void)env;
  return g_bridge.init(static_cast<int>(sampleRateHz),
                       static_cast<int>(numChannels))
             ? JNI_TRUE
             : JNI_FALSE;
}

JNIEXPORT void JNICALL
Java_com_protournament_app_RnnoiseProcessor_nativeProcess(JNIEnv* env,
                                                          jclass /* clazz */,
                                                          jobject buffer,
                                                          jint numBands,
                                                          jint numFrames) {
  if (buffer == nullptr) return;
  float* data = static_cast<float*>(env->GetDirectBufferAddress(buffer));
  if (data == nullptr) return;  // not a direct buffer — fail open
  const jlong capacity = env->GetDirectBufferCapacity(buffer);
  const jlong needed = static_cast<jlong>(numBands) *
                       static_cast<jlong>(numFrames) *
                       static_cast<jlong>(sizeof(float));
  if (capacity < needed) return;  // truncated buffer — fail open
  g_bridge.process(data, static_cast<int>(numBands),
                   static_cast<int>(numFrames));
}

JNIEXPORT void JNICALL
Java_com_protournament_app_RnnoiseProcessor_nativeSetBypass(JNIEnv* env,
                                                            jclass /* clazz */,
                                                            jboolean bypass) {
  (void)env;
  g_bridge.setBypass(bypass == JNI_TRUE);
}

JNIEXPORT void JNICALL
Java_com_protournament_app_RnnoiseProcessor_nativeRelease(JNIEnv* env,
                                                          jclass /* clazz */) {
  (void)env;
  g_bridge.release();
}

JNIEXPORT jlong JNICALL
Java_com_protournament_app_RnnoiseProcessor_nativeGetFramesProcessed(
    JNIEnv* env, jclass /* clazz */) {
  (void)env;
  return static_cast<jlong>(g_bridge.framesProcessed());
}

JNIEXPORT jint JNICALL
Java_com_protournament_app_RnnoiseProcessor_nativeGetLastError(JNIEnv* env,
                                                               jclass /* clazz */) {
  (void)env;
  return static_cast<jint>(g_bridge.lastError());
}

JNIEXPORT jfloat JNICALL
Java_com_protournament_app_RnnoiseProcessor_nativeGetLastVoiceProb(
    JNIEnv* env, jclass /* clazz */) {
  (void)env;
  return static_cast<jfloat>(g_bridge.lastVoiceProb());
}

}  // extern "C"
