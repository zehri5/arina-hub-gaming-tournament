package com.protournament.app

import android.util.Log
import com.cloudwebrtc.webrtc.FlutterWebRTCPlugin
import com.cloudwebrtc.webrtc.audio.AudioProcessingAdapter
import com.cloudwebrtc.webrtc.audio.LocalAudioTrack
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer

// RNNoise mic noise suppression (Arena Hub #10 audio, Group 2).
//
// Mirrors the official Krisp plugin's Android shape
// (livekit_noise_filter 0.2.1, LiveKitKrispNoiseFilterPlugin.kt):
// the Dart side (lib/services/rnnoise_processor.dart) talks to this
// object over the `arena_hub_rnnoise` MethodChannel, and the frame hook
// is flutter_webrtc's AudioProcessingAdapter.ExternalAudioFrameProcessing
// registered on
// FlutterWebRTCPlugin.sharedSingleton.audioProcessingController
//   .capturePostProcessing
// — the WebRTC APM capture post-processing hook, which runs AFTER the
// APM's own AEC/NS on every 10 ms mic frame.
//
// Buffer contract (WebRTC ExternalAudioProcessing): process() receives
// the mic frame as SPLIT-BAND float32 audio — `numBands` (1-3) bands x
// `numFrames` (160) samples, planar, band-major, in a direct ByteBuffer
// that is modified IN PLACE. Each band is 10 ms at an effective 16 kHz.
// The buffer is passed straight to the native bridge (libarena_rnnoise,
// android/app/src/main/cpp/), which resamples each band to 48 kHz, runs
// it through the vendored RNNoise C engine, and resamples back. See
// rnnoise_bridge.h for the routing details and the host-test numbers in
// cpp/rnnoise/README.md.
//
// Fail-open throughout: a missing native library, a missing
// flutter_webrtc plugin, or a track that is not a LocalAudioTrack only
// ever degrades to unprocessed mic audio — never a crash, never a
// broken call. Every channel method replies exactly once.

/** The WebRTC APM frame hook. One instance, shared across init/destroy. */
class RnnoiseAudioProcessor : AudioProcessingAdapter.ExternalAudioFrameProcessing {
    companion object {
        private const val TAG = "Rnnoise"
    }

    @Volatile
    private var bypass = false

    // Last format the APM reported; used for the lazy init below.
    @Volatile
    private var lastSampleRateHz = 48000

    @Volatile
    private var lastNumChannels = 1

    @Volatile
    private var nativeInitDone = false

    fun setBypass(bypass: Boolean) {
        this.bypass = bypass
    }

    fun isBypassed(): Boolean = bypass

    override fun initialize(sampleRateHz: Int, numChannels: Int) {
        lastSampleRateHz = sampleRateHz
        lastNumChannels = numChannels
        if (RnnoiseProcessor.nativeLoaded) {
            nativeInitDone =
                RnnoiseProcessor.nativeInit(sampleRateHz, numChannels)
            Log.i(TAG, "initialize rate=$sampleRateHz ch=$numChannels ok=$nativeInitDone")
        }
    }

    override fun reset(newRate: Int) {
        lastSampleRateHz = newRate
        if (RnnoiseProcessor.nativeLoaded) {
            nativeInitDone =
                RnnoiseProcessor.nativeInit(newRate, lastNumChannels)
        }
    }

    override fun process(numBands: Int, numFrames: Int, buffer: ByteBuffer?) {
        if (buffer == null || bypass) return
        if (!RnnoiseProcessor.nativeLoaded) return
        if (!nativeInitDone) {
            // initialize() was never called — this happens when the
            // processor is registered after the APM already initialized
            // (AudioProcessingAdapter.addProcessor does not replay
            // initialize()). Lazy-init with the last known format; the
            // native bridge only uses the rate for validation, because
            // every band is always 160 samples at an effective 16 kHz.
            nativeInitDone = RnnoiseProcessor.nativeInit(
                lastSampleRateHz,
                lastNumChannels,
            )
            if (!nativeInitDone) return
        }
        RnnoiseProcessor.nativeProcess(buffer, numBands, numFrames)
    }
}

/** MethodChannel handler for `arena_hub_rnnoise`. Registered once from MainActivity. */
class RnnoiseProcessor private constructor() : MethodChannel.MethodCallHandler {
    companion object {
        private const val TAG = "Rnnoise"
        const val CHANNEL_NAME = "arena_hub_rnnoise"

        /**
         * True when libarena_rnnoise.so loaded. False on builds without
         * the native lib (e.g. an APK built before the CMake wiring) —
         * the Dart side then reports the spectral-gate engine and the
         * mic works unprocessed.
         */
        @JvmStatic
        var nativeLoaded = false
            private set

        init {
            try {
                System.loadLibrary("arena_rnnoise")
                nativeLoaded = true
            } catch (_: Throwable) {
                // A missing native lib must never crash app startup.
                Log.w(TAG, "libarena_rnnoise.so not available; RNNoise disabled")
                nativeLoaded = false
            }
        }

        @Volatile
        private var instance: RnnoiseProcessor? = null

        /**
         * The messenger the channel is currently bound to — see
         * DspMicProcessor.kt (FIX 22 item 6): the singleton
         * survives a normal relaunch in the same process, but
         * the engine + messenger are recreated, so identity
         * comparison tells a same-engine re-attach (no-op) from
         * a new engine (must re-bind).
         */
        @Volatile
        private var boundMessenger: BinaryMessenger? = null

        /**
         * Registers the channel. Idempotent for the same engine;
         * RE-BINDS when the engine is recreated (FIX 22 item 6 —
         * same one-shot-singleton bug as DspMicProcessor: without
         * the re-bind, a normal relaunch leaves the channel bound
         * to the dead engine's messenger and the new isolate's
         * calls go nowhere).
         */
        @JvmStatic
        fun register(messenger: BinaryMessenger) {
            val existing = instance
            if (existing == null) {
                synchronized(this) {
                    if (instance == null) {
                        val created = RnnoiseProcessor()
                        MethodChannel(messenger, CHANNEL_NAME)
                            .setMethodCallHandler(created)
                        instance = created
                        boundMessenger = messenger
                        Log.i(TAG, "registered (nativeLoaded=$nativeLoaded)")
                    }
                }
            } else if (boundMessenger !== messenger) {
                // New engine in the same process: re-bind the
                // channel to the new messenger and drop the stale
                // hook state (the old WebRTC controller is gone).
                MethodChannel(messenger, CHANNEL_NAME)
                    .setMethodCallHandler(existing)
                boundMessenger = messenger
                existing.onEngineRebound()
                Log.i(TAG, "re-bound channel to new engine messenger")
            }
            // Same engine re-attaching: nothing to do.
        }

        // ---- JNI (rnnoise_jni.cpp). Guarded by nativeLoaded at every call site. ----
        @JvmStatic
        external fun nativeInit(sampleRateHz: Int, numChannels: Int): Boolean

        @JvmStatic
        external fun nativeProcess(buffer: ByteBuffer, numBands: Int, numFrames: Int)

        @JvmStatic
        external fun nativeSetBypass(bypass: Boolean)

        @JvmStatic
        external fun nativeRelease()

        @JvmStatic
        external fun nativeGetFramesProcessed(): Long

        @JvmStatic
        external fun nativeGetLastError(): Int

        @JvmStatic
        external fun nativeGetLastVoiceProb(): Float
    }

    private val audioProcessor = RnnoiseAudioProcessor()

    @Volatile
    private var registered = false

    /**
     * Called when the channel is re-bound to a new engine's
     * messenger (FIX 22 item 6 — same as DspMicProcessor): the
     * old WebRTC controller died with the old engine, so the
     * hook flag must reset, otherwise the next init()
     * early-returns success without hooking the processor to
     * the new controller.
     */
    private fun onEngineRebound() {
        registered = false
        Log.i(TAG, "engine rebound: hook state reset")
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isAvailable" -> result.success(nativeLoaded)
            "init" -> {
                val trackId = call.argument<String>("trackId")
                if (trackId == null) {
                    result.error("INVALID_ARGUMENT", "trackId is required", null)
                } else {
                    init(trackId, result)
                }
            }
            "restart" -> {
                val trackId = call.argument<String>("trackId")
                if (trackId == null) {
                    result.error("INVALID_ARGUMENT", "trackId is required", null)
                } else {
                    destroy()
                    init(trackId, result)
                }
            }
            "destroy" -> {
                destroy()
                result.success(null)
            }
            "onPublish" -> result.success(null) // RNNoise needs no auth / room context.
            "onUnpublish" -> result.success(null)
            "setBypass" -> {
                val bypass = call.argument<Boolean>("bypass")
                if (bypass == null) {
                    result.error("INVALID_ARGUMENT", "bypass is required", null)
                } else {
                    audioProcessor.setBypass(bypass)
                    if (nativeLoaded) nativeSetBypass(bypass)
                    result.success(true)
                }
            }
            "lastError" -> {
                result.success(if (nativeLoaded) nativeGetLastError() else -1)
            }
            "framesProcessed" -> {
                result.success(if (nativeLoaded) nativeGetFramesProcessed() else -1L)
            }
            else -> result.notImplemented()
        }
    }

    private fun init(trackId: String, result: MethodChannel.Result) {
        if (registered) {
            // Already hooked; re-adding the same instance would process
            // every frame twice.
            result.success(true)
            return
        }
        val plugin = FlutterWebRTCPlugin.sharedSingleton
        if (plugin == null) {
            result.error("WEBRTC_NOT_READY", "FlutterWebRTCPlugin not initialized", null)
            return
        }
        val track = try {
            plugin.getLocalTrack(trackId)
        } catch (_: Exception) {
            null
        }
        if (track == null || track !is LocalAudioTrack) {
            result.error("INVALID_ARGUMENT", "track is not a LocalAudioTrack", null)
            return
        }
        // The controller is created when the first PeerConnectionFactory
        // is built; it can still be null if init races factory setup.
        val controller = try {
            plugin.audioProcessingController
        } catch (_: Exception) {
            null
        }
        if (controller == null) {
            result.error(
                "WEBRTC_NOT_READY",
                "AudioProcessingController not created yet",
                null,
            )
            return
        }
        controller.capturePostProcessing.addProcessor(audioProcessor)
        registered = true
        Log.i(TAG, "init: hooked track=$trackId")
        result.success(true)
    }

    private fun destroy() {
        if (!registered) return
        registered = false
        try {
            FlutterWebRTCPlugin.sharedSingleton
                ?.audioProcessingController
                ?.capturePostProcessing
                ?.removeProcessor(audioProcessor)
        } catch (_: Exception) {
            // Plugin gone; nothing to remove.
        }
        if (nativeLoaded) nativeRelease()
        Log.i(TAG, "destroy: unhooked")
    }
}
