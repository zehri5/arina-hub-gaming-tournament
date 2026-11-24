package com.arenahub.app.dsp

import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

class AudioDspPlugin : FlutterPlugin, MethodCallHandler {

    companion object {
        const val CHANNEL_NAME = "com.arenahub.app/audio_dsp"

        private const val TAG = "AudioDsp"

        /**
         * True when libaudio_dsp.so loaded. False on builds without the
         * native lib (e.g. an APK built before the CMake wiring) — every
         * method then fails soft with NATIVE_UNAVAILABLE instead of
         * crashing (see the §5 note below).
         */
        @JvmStatic
        var nativeAvailable = false
            private set

        init {
            // §5 FAIL-SOFT (DSP fold, 2026-11-22): the old code called
            // System.loadLibrary("audio_dsp") bare here. When the .so is
            // missing, referencing this class throws UnsatisfiedLinkError
            // at class-init — an Error, and every catch in the call path
            // catches Exception only, so the registrant route aborts
            // mid-way and the MainActivity route is a launch crash.
            // Follow the Group 2 RnnoiseProcessor pattern instead:
            // try/catch Throwable -> nativeAvailable flag, and every
            // call site checks the flag before touching a native method.
            try {
                System.loadLibrary("audio_dsp")
                nativeAvailable = true
            } catch (_: Throwable) {
                // A missing native lib must never crash app startup.
                Log.w(TAG, "libaudio_dsp.so not available; AudioDsp disabled")
                nativeAvailable = false
            }
        }

        // ---- GROUP 8 DSP: shared playback-engine registry (2026-11-22) ----
        //
        // ONE native engine must serve two callers: the Dart parameter
        // API (AudioDsp.setReverb/setEcho/setEq over this channel) and
        // the ExoPlayer DspAudioProcessor, which feeds LIVE playback
        // frames through the same engine on the audio thread. A
        // privately-created engine (MethodChannel 'create') can only
        // be reached by AudioDsp.process(), which Dart can never feed
        // with live frames — so the playback path needs a shared
        // handle both sides can find. That handle lives here.
        //
        // Lifecycle: created lazily by getOrCreatePlaybackHandle()
        // (first caller wins — Dart initPlayback() or the processor's
        // configure()), owned by the PLAYER, not by Dart: disposing
        // the Dart AudioDsp does NOT destroy it (see 'destroy' below);
        // it is destroyed by releasePlaybackHandle(), called when the
        // player is released or the engine detaches. It is deliberately
        // NOT in activeHandles, so engine-detach cleanup cannot destroy
        // it out from under the audio thread.
        //
        // Threading: processPlaybackPcm() runs on the ExoPlayer audio
        // thread while the setters run on the plugin executor thread.
        // The C++ engine guards its own state with a mutex (all setters
        // and processPcm16 lock it), so process-vs-setter is safe. The
        // remaining race is destroy-vs-anything: playbackLock serializes
        // create/configure/process/reset/release of the shared handle,
        // and the MethodChannel handlers run their native calls for
        // this handle through guarded() under the same lock.

        @Volatile
        private var pluginInstance: AudioDspPlugin? = null

        @Volatile
        private var playbackHandle: Long? = null
        private val playbackLock = Any()
        private var playbackSampleRate: Int = -1
        private var playbackChannels: Int = -1

        /**
         * Returns the shared playback engine handle, creating the
         * engine on first use. Only reconfigures when the format
         * actually changed: DspEngine.configure() resets ALL DSP state
         * (echo buffers zeroed, EQ reset, reverb combs resized), so a
         * redundant reconfigure would cut reverb/echo tails every time
         * ExoPlayer re-configures the processor. Returns 0 when the
         * plugin is not attached (no engine exists yet) or the native
         * library is absent (§5 fail-soft).
         */
        fun getOrCreatePlaybackHandle(sampleRate: Int, channels: Int): Long {
            if (!nativeAvailable) return 0L
            val plugin = pluginInstance ?: return 0L
            synchronized(playbackLock) {
                val existing = playbackHandle
                if (existing != null) {
                    if (sampleRate != playbackSampleRate ||
                        channels != playbackChannels
                    ) {
                        plugin.nativeConfigure(existing, sampleRate, channels)
                        playbackSampleRate = sampleRate
                        playbackChannels = channels
                    }
                    return existing
                }
                val handle = plugin.nativeCreate(sampleRate, channels)
                if (handle != 0L) {
                    playbackHandle = handle
                    playbackSampleRate = sampleRate
                    playbackChannels = channels
                }
                return handle
            }
        }

        /** Destroys the shared playback engine, if any. No-op otherwise. */
        fun releasePlaybackHandle() {
            synchronized(playbackLock) {
                val handle = playbackHandle
                playbackHandle = null
                playbackSampleRate = -1
                playbackChannels = -1
                if (handle != null && nativeAvailable) {
                    pluginInstance?.nativeDestroy(handle)
                }
            }
        }

        /**
         * Processes one PCM16 buffer through the shared playback engine.
         * Called from the ExoPlayer audio thread by DspAudioProcessor.
         * NEVER throws: when there is no engine (plugin detached,
         * engine released, native library absent) the input is returned
         * unchanged so playback keeps playing instead of crashing the
         * audio thread.
         */
        fun processPlaybackPcm(pcmBytes: ByteArray): ByteArray {
            if (!nativeAvailable) return pcmBytes
            val plugin = pluginInstance ?: return pcmBytes
            if (playbackHandle == null) return pcmBytes
            synchronized(playbackLock) {
                val handle = playbackHandle ?: return pcmBytes
                return plugin.nativeProcess(handle, pcmBytes)
            }
        }

        /** Resets the shared playback engine's DSP state (tails cleared). No-op when there is no engine. */
        fun resetPlaybackEngine() {
            if (!nativeAvailable) return
            val plugin = pluginInstance ?: return
            if (playbackHandle == null) return
            synchronized(playbackLock) {
                val handle = playbackHandle ?: return
                plugin.nativeReset(handle)
            }
        }

        /** Whether the shared playback engine currently exists. */
        fun isPlaybackEngineActive(): Boolean = playbackHandle != null
    }

    private var channel: MethodChannel? = null
    private var executor: ExecutorService? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private val activeHandles = mutableSetOf<Long>()

    private external fun nativeCreate(sampleRate: Int, channels: Int): Long
    private external fun nativeDestroy(handle: Long)
    private external fun nativeConfigure(handle: Long, sampleRate: Int, channels: Int)
    private external fun nativeSetNoiseGate(
        handle: Long,
        enabled: Boolean,
        thresholdDb: Float,
        attackMs: Float,
        releaseMs: Float
    )
    private external fun nativeSetCompressor(
        handle: Long,
        enabled: Boolean,
        thresholdDb: Float,
        ratio: Float,
        attackMs: Float,
        releaseMs: Float,
        makeupGainDb: Float
    )
    private external fun nativeSetReverb(
        handle: Long,
        enabled: Boolean,
        wetDryMix: Float,
        roomSize: Float,
        damping: Float
    )
    private external fun nativeSetEcho(
        handle: Long,
        enabled: Boolean,
        delayMs: Float,
        feedback: Float,
        mix: Float
    )
    private external fun nativeSetEq(
        handle: Long,
        enabled: Boolean,
        bassBoostDb: Float,
        lowGainDb: Float,
        midGainDb: Float,
        highGainDb: Float
    )
    private external fun nativeReset(handle: Long)
    private external fun nativeProcess(handle: Long, pcmBytes: ByteArray): ByteArray

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        executor = Executors.newSingleThreadExecutor()
        channel = MethodChannel(binding.binaryMessenger, CHANNEL_NAME).apply {
            setMethodCallHandler(this@AudioDspPlugin)
        }
        pluginInstance = this
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null

        // Release the shared playback engine FIRST, while the instance
        // is still registered (the destroy call needs it), then drop
        // the instance so the audio processor falls back to passthrough.
        releasePlaybackHandle()
        pluginInstance = null

        val exec = executor
        executor = null
        if (exec != null) {
            exec.execute {
                // §5 fail-soft: no native calls when the .so is absent.
                if (nativeAvailable) {
                    activeHandles.forEach { nativeDestroy(it) }
                }
                activeHandles.clear()
            }
            exec.shutdown()
        }
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        val exec = executor
        if (exec == null || exec.isShutdown) {
            result.error("DETACHED", "AudioDspPlugin is detached from FlutterEngine.", null)
            return
        }
        if (!nativeAvailable) {
            // §5 FAIL-SOFT: the .so is missing — every native call below
            // would throw UnsatisfiedLinkError (an Error, not an
            // Exception) on the executor thread. Answer with a
            // Dart-visible error instead; Dart fails open (init() throws
            // PlatformException, no handle is ever created, dispose()
            // then sends nothing).
            result.error(
                "NATIVE_UNAVAILABLE",
                "libaudio_dsp.so is not available on this build.",
                null
            )
            return
        }

        when (call.method) {
            "create" -> {
                val sampleRate = call.intArg("sampleRate", 48000)
                val channels = call.intArg("channels", 2)
                exec.execute {
                    val handle = nativeCreate(sampleRate, channels)
                    if (handle != 0L) {
                        activeHandles.add(handle)
                        replySuccess(result, handle)
                    } else {
                        replyError(result, "INIT_FAILED", "Failed to allocate native DSP engine.")
                    }
                }
            }

            "destroy" -> {
                val handle = call.longArg("handle")
                if (handle == null) {
                    result.error("INVALID_ARGS", "Missing 'handle'.", null)
                    return
                }
                exec.execute {
                    if (handle == playbackHandle) {
                        // The shared playback engine is owned by the
                        // player (DspAudioProcessor), not by Dart:
                        // disposing the Dart handle must NOT destroy
                        // the engine live frames are flowing through.
                        // It is released by 'releasePlaybackEngine' /
                        // player teardown instead.
                        replySuccess(result, null)
                        return@execute
                    }
                    if (activeHandles.remove(handle)) {
                        nativeDestroy(handle)
                    }
                    replySuccess(result, null)
                }
            }

            // GROUP 8 DSP: adopt the shared playback engine (see the
            // companion-object registry above). Returns its handle so
            // Dart's AudioDsp.initPlayback() can control the same
            // engine the ExoPlayer audio processor feeds.
            "attachPlaybackEngine" -> {
                val sampleRate = call.intArg("sampleRate", 48000)
                val channels = call.intArg("channels", 2)
                exec.execute {
                    val handle = getOrCreatePlaybackHandle(sampleRate, channels)
                    if (handle != 0L) {
                        replySuccess(result, handle)
                    } else {
                        replyError(
                            result,
                            "INIT_FAILED",
                            "Playback DSP engine is not available (plugin detached).",
                        )
                    }
                }
            }

            // GROUP 8 DSP: destroy the shared playback engine. Called
            // on player teardown; the audio processor then passes
            // frames through untouched until an engine exists again.
            "releasePlaybackEngine" -> {
                exec.execute {
                    releasePlaybackHandle()
                    replySuccess(result, null)
                }
            }

            "configure" -> {
                val handle = call.longArg("handle")
                if (handle == null) {
                    result.error("INVALID_ARGS", "Missing 'handle'.", null)
                    return
                }
                val sampleRate = call.intArg("sampleRate", 48000)
                val channels = call.intArg("channels", 2)
                exec.execute {
                    if (!isKnownHandle(handle)) {
                        replyError(result, "INVALID_HANDLE", "DSP handle is not active.")
                        return@execute
                    }
                    if (!guarded(handle) { nativeConfigure(handle, sampleRate, channels) }) {
                        replyError(result, "INVALID_HANDLE", "Playback DSP engine was released.")
                        return@execute
                    }
                    replySuccess(result, null)
                }
            }

            "setNoiseGate" -> {
                val handle = call.longArg("handle")
                if (handle == null) {
                    result.error("INVALID_ARGS", "Missing 'handle'.", null)
                    return
                }
                val enabled = call.boolArg("enabled", true)
                val thresholdDb = call.floatArg("thresholdDb", -40.0f)
                val attackMs = call.floatArg("attackMs", 5.0f)
                val releaseMs = call.floatArg("releaseMs", 120.0f)
                exec.execute {
                    if (!isKnownHandle(handle)) {
                        replyError(result, "INVALID_HANDLE", "DSP handle is not active.")
                        return@execute
                    }
                    if (!guarded(handle) { nativeSetNoiseGate(handle, enabled, thresholdDb, attackMs, releaseMs) }) {
                        replyError(result, "INVALID_HANDLE", "Playback DSP engine was released.")
                        return@execute
                    }
                    replySuccess(result, null)
                }
            }

            "setCompressor" -> {
                val handle = call.longArg("handle")
                if (handle == null) {
                    result.error("INVALID_ARGS", "Missing 'handle'.", null)
                    return
                }
                val enabled = call.boolArg("enabled", true)
                // NaN guard (v3 adoption fix): a NaN reaching C++ would be
                // clamped to the HIGH end (NaN makeup -> +24 dB). Non-finite
                // values fall back to defaults (C++ guards again as well).
                val thresholdDb = call.floatArg("thresholdDb", -18.0f).takeIf { it.isFinite() } ?: -18.0f
                val ratio = call.floatArg("ratio", 4.0f).takeIf { it.isFinite() } ?: 4.0f
                val attackMs = call.floatArg("attackMs", 10.0f).takeIf { it.isFinite() } ?: 10.0f
                val releaseMs = call.floatArg("releaseMs", 100.0f).takeIf { it.isFinite() } ?: 100.0f
                val makeupGainDb = call.floatArg("makeupGainDb", 0.0f).takeIf { it.isFinite() } ?: 0.0f
                exec.execute {
                    if (!isKnownHandle(handle)) {
                        replyError(result, "INVALID_HANDLE", "DSP handle is not active.")
                        return@execute
                    }
                    if (!guarded(handle) {
                        nativeSetCompressor(
                            handle,
                            enabled,
                            thresholdDb,
                            ratio,
                            attackMs,
                            releaseMs,
                            makeupGainDb
                        )
                    }) {
                        replyError(result, "INVALID_HANDLE", "Playback DSP engine was released.")
                        return@execute
                    }
                    replySuccess(result, null)
                }
            }

            "setReverb" -> {
                val handle = call.longArg("handle")
                if (handle == null) {
                    result.error("INVALID_ARGS", "Missing 'handle'.", null)
                    return
                }
                val enabled = call.boolArg("enabled", true)
                val wetDryMix = call.floatArg("wetDryMix", 0.3f)
                val roomSize = call.floatArg("roomSize", 0.5f)
                val damping = call.floatArg("damping", 0.5f)
                exec.execute {
                    if (!isKnownHandle(handle)) {
                        replyError(result, "INVALID_HANDLE", "DSP handle is not active.")
                        return@execute
                    }
                    if (!guarded(handle) { nativeSetReverb(handle, enabled, wetDryMix, roomSize, damping) }) {
                        replyError(result, "INVALID_HANDLE", "Playback DSP engine was released.")
                        return@execute
                    }
                    replySuccess(result, null)
                }
            }

            "setEcho" -> {
                val handle = call.longArg("handle")
                if (handle == null) {
                    result.error("INVALID_ARGS", "Missing 'handle'.", null)
                    return
                }
                val enabled = call.boolArg("enabled", true)
                // NaN guard (setEcho branch only): a NaN reaching the
                // native clamp becomes the MAXIMUM value (2000 ms /
                // 0.95 feedback / full wet), so sanitise here too —
                // delay -> default, feedback/mix -> 0 (silent, safe).
                // coerceIn also bounds +/-inf to the documented range.
                val delayMs = call.floatArg("delayMs", 250.0f).let {
                    if (it.isNaN()) 250.0f else it.coerceIn(1.0f, 2000.0f)
                }
                val feedback = call.floatArg("feedback", 0.35f).let {
                    if (it.isNaN()) 0.0f else it.coerceIn(0.0f, 0.95f)
                }
                val mix = call.floatArg("mix", 0.35f).let {
                    if (it.isNaN()) 0.0f else it.coerceIn(0.0f, 1.0f)
                }
                exec.execute {
                    if (!isKnownHandle(handle)) {
                        replyError(result, "INVALID_HANDLE", "DSP handle is not active.")
                        return@execute
                    }
                    if (!guarded(handle) { nativeSetEcho(handle, enabled, delayMs, feedback, mix) }) {
                        replyError(result, "INVALID_HANDLE", "Playback DSP engine was released.")
                        return@execute
                    }
                    replySuccess(result, null)
                }
            }

            "setEq" -> {
                val handle = call.longArg("handle")
                if (handle == null) {
                    result.error("INVALID_ARGS", "Missing 'handle'.", null)
                    return
                }
                val enabled = call.boolArg("enabled", true)
                val bassBoostDb = call.floatArg("bassBoostDb", 0.0f)
                val lowGainDb = call.floatArg("lowGainDb", 0.0f)
                val midGainDb = call.floatArg("midGainDb", 0.0f)
                val highGainDb = call.floatArg("highGainDb", 0.0f)
                exec.execute {
                    if (!isKnownHandle(handle)) {
                        replyError(result, "INVALID_HANDLE", "DSP handle is not active.")
                        return@execute
                    }
                    if (!guarded(handle) { nativeSetEq(handle, enabled, bassBoostDb, lowGainDb, midGainDb, highGainDb) }) {
                        replyError(result, "INVALID_HANDLE", "Playback DSP engine was released.")
                        return@execute
                    }
                    replySuccess(result, null)
                }
            }

            "reset" -> {
                val handle = call.longArg("handle")
                if (handle == null) {
                    result.error("INVALID_ARGS", "Missing 'handle'.", null)
                    return
                }
                exec.execute {
                    if (!isKnownHandle(handle)) {
                        replyError(result, "INVALID_HANDLE", "DSP handle is not active.")
                        return@execute
                    }
                    if (!guarded(handle) { nativeReset(handle) }) {
                        replyError(result, "INVALID_HANDLE", "Playback DSP engine was released.")
                        return@execute
                    }
                    replySuccess(result, null)
                }
            }

            "process" -> {
                val handle = call.longArg("handle")
                val pcmBytes = call.argument<ByteArray>("pcmBytes")
                if (handle == null || pcmBytes == null) {
                    result.error("INVALID_ARGS", "Missing 'handle' or 'pcmBytes'.", null)
                    return
                }
                exec.execute {
                    if (!isKnownHandle(handle)) {
                        replyError(result, "INVALID_HANDLE", "DSP handle is not active.")
                        return@execute
                    }
                    val processed: ByteArray? = guardedResult<ByteArray?>(handle, null) {
                        nativeProcess(handle, pcmBytes)
                    }
                    if (processed == null) {
                        replyError(result, "INVALID_HANDLE", "Playback DSP engine was released.")
                        return@execute
                    }
                    replySuccess(result, processed)
                }
            }

            else -> result.notImplemented()
        }
    }

    // ---- GROUP 8 DSP helpers for the shared playback handle ----

    /** True when [handle] names a live engine: a private handle owned by [activeHandles], or the shared playback handle. */
    private fun isKnownHandle(handle: Long): Boolean {
        return activeHandles.contains(handle) || handle == playbackHandle
    }

    /**
     * Runs [block] for [handle]. Private handles run directly (their
     * lifecycle is owned by the single-thread executor, so nothing can
     * destroy them concurrently). The shared playback handle runs under
     * [playbackLock] so it can never race [releasePlaybackHandle]
     * deleting the engine mid-call. Returns false when the playback
     * engine was released before the block could run.
     */
    private inline fun guarded(handle: Long, block: () -> Unit): Boolean {
        if (handle != playbackHandle) {
            block()
            return true
        }
        synchronized(playbackLock) {
            if (handle != playbackHandle) return false
            block()
            return true
        }
    }

    /** Like [guarded] for blocks that return a value; returns [default] when the playback engine was released first. */
    private inline fun <T> guardedResult(handle: Long, default: T, block: () -> T): T {
        if (handle != playbackHandle) return block()
        synchronized(playbackLock) {
            if (handle != playbackHandle) return default
            return block()
        }
    }

    private fun replySuccess(result: Result, value: Any?) {
        mainHandler.post { result.success(value) }
    }

    private fun replyError(result: Result, code: String, message: String) {
        mainHandler.post { result.error(code, message, null) }
    }

    private fun MethodCall.intArg(key: String, default: Int): Int {
        return argument<Number>(key)?.toInt() ?: default
    }

    private fun MethodCall.longArg(key: String): Long? {
        return argument<Number>(key)?.toLong()
    }

    private fun MethodCall.floatArg(key: String, default: Float): Float {
        return (argument<Number>(key)?.toDouble() ?: default.toDouble()).toFloat()
    }

    private fun MethodCall.boolArg(key: String, default: Boolean): Boolean {
        return argument<Boolean>(key) ?: default
    }
}
