#include <jni.h>
#include <cstdint>
#include <vector>

#include "dsp_engine.h"

extern "C" {

JNIEXPORT jlong JNICALL
Java_com_arenahub_app_dsp_AudioDspPlugin_nativeCreate(
    JNIEnv* /* env */,
    jobject /* thiz */,
    jint sample_rate,
    jint channels) {
    auto* engine = new arena_dsp::DspEngine(
        static_cast<int>(sample_rate),
        static_cast<int>(channels)
    );
    return reinterpret_cast<jlong>(engine);
}

JNIEXPORT void JNICALL
Java_com_arenahub_app_dsp_AudioDspPlugin_nativeDestroy(
    JNIEnv* /* env */,
    jobject /* thiz */,
    jlong handle) {
    if (handle != 0) {
        auto* engine = reinterpret_cast<arena_dsp::DspEngine*>(handle);
        delete engine;
    }
}

JNIEXPORT void JNICALL
Java_com_arenahub_app_dsp_AudioDspPlugin_nativeConfigure(
    JNIEnv* /* env */,
    jobject /* thiz */,
    jlong handle,
    jint sample_rate,
    jint channels) {
    if (handle != 0) {
        auto* engine = reinterpret_cast<arena_dsp::DspEngine*>(handle);
        engine->configure(static_cast<int>(sample_rate), static_cast<int>(channels));
    }
}

JNIEXPORT void JNICALL
Java_com_arenahub_app_dsp_AudioDspPlugin_nativeSetNoiseGate(
    JNIEnv* /* env */,
    jobject /* thiz */,
    jlong handle,
    jboolean enabled,
    jfloat threshold_db,
    jfloat attack_ms,
    jfloat release_ms) {
    if (handle != 0) {
        auto* engine = reinterpret_cast<arena_dsp::DspEngine*>(handle);
        engine->setNoiseGate(
            enabled == JNI_TRUE,
            static_cast<float>(threshold_db),
            static_cast<float>(attack_ms),
            static_cast<float>(release_ms)
        );
    }
}

JNIEXPORT void JNICALL
Java_com_arenahub_app_dsp_AudioDspPlugin_nativeSetCompressor(
    JNIEnv* /* env */,
    jobject /* thiz */,
    jlong handle,
    jboolean enabled,
    jfloat threshold_db,
    jfloat ratio,
    jfloat attack_ms,
    jfloat release_ms,
    jfloat makeup_gain_db) {
    if (handle != 0) {
        auto* engine = reinterpret_cast<arena_dsp::DspEngine*>(handle);
        engine->setCompressor(
            enabled == JNI_TRUE,
            static_cast<float>(threshold_db),
            static_cast<float>(ratio),
            static_cast<float>(attack_ms),
            static_cast<float>(release_ms),
            static_cast<float>(makeup_gain_db)
        );
    }
}

JNIEXPORT void JNICALL
Java_com_arenahub_app_dsp_AudioDspPlugin_nativeSetReverb(
    JNIEnv* /* env */,
    jobject /* thiz */,
    jlong handle,
    jboolean enabled,
    jfloat wet_dry_mix,
    jfloat room_size,
    jfloat damping) {
    if (handle != 0) {
        auto* engine = reinterpret_cast<arena_dsp::DspEngine*>(handle);
        engine->setReverb(
            enabled == JNI_TRUE,
            static_cast<float>(wet_dry_mix),
            static_cast<float>(room_size),
            static_cast<float>(damping)
        );
    }
}

JNIEXPORT void JNICALL
Java_com_arenahub_app_dsp_AudioDspPlugin_nativeSetEcho(
    JNIEnv* /* env */,
    jobject /* thiz */,
    jlong handle,
    jboolean enabled,
    jfloat delay_ms,
    jfloat feedback,
    jfloat mix) {
    if (handle != 0) {
        auto* engine = reinterpret_cast<arena_dsp::DspEngine*>(handle);
        engine->setEcho(
            enabled == JNI_TRUE,
            static_cast<float>(delay_ms),
            static_cast<float>(feedback),
            static_cast<float>(mix)
        );
    }
}

JNIEXPORT void JNICALL
Java_com_arenahub_app_dsp_AudioDspPlugin_nativeSetEq(
    JNIEnv* /* env */,
    jobject /* thiz */,
    jlong handle,
    jboolean enabled,
    jfloat bass_boost_db,
    jfloat low_gain_db,
    jfloat mid_gain_db,
    jfloat high_gain_db) {
    if (handle != 0) {
        auto* engine = reinterpret_cast<arena_dsp::DspEngine*>(handle);
        engine->setEq(
            enabled == JNI_TRUE,
            static_cast<float>(bass_boost_db),
            static_cast<float>(low_gain_db),
            static_cast<float>(mid_gain_db),
            static_cast<float>(high_gain_db)
        );
    }
}

JNIEXPORT void JNICALL
Java_com_arenahub_app_dsp_AudioDspPlugin_nativeReset(
    JNIEnv* /* env */,
    jobject /* thiz */,
    jlong handle) {
    if (handle != 0) {
        auto* engine = reinterpret_cast<arena_dsp::DspEngine*>(handle);
        engine->reset();
    }
}

JNIEXPORT jbyteArray JNICALL
Java_com_arenahub_app_dsp_AudioDspPlugin_nativeProcess(
    JNIEnv* env,
    jobject /* thiz */,
    jlong handle,
    jbyteArray pcm_bytes) {
    if (pcm_bytes == nullptr) {
        return env->NewByteArray(0);
    }

    const jsize byteLen = env->GetArrayLength(pcm_bytes);
    if (byteLen <= 0) {
        return env->NewByteArray(0);
    }

    std::vector<uint8_t> workBuf(static_cast<size_t>(byteLen));
    env->GetByteArrayRegion(
        pcm_bytes,
        0,
        byteLen,
        reinterpret_cast<jbyte*>(workBuf.data())
    );

    if (handle != 0) {
        auto* engine = reinterpret_cast<arena_dsp::DspEngine*>(handle);
        engine->processPcm16(workBuf.data(), workBuf.data(), static_cast<size_t>(byteLen));
    }

    jbyteArray outArray = env->NewByteArray(byteLen);
    if (outArray != nullptr) {
        env->SetByteArrayRegion(
            outArray,
            0,
            byteLen,
            reinterpret_cast<const jbyte*>(workBuf.data())
        );
    }
    return outArray;
}

} // extern "C"
