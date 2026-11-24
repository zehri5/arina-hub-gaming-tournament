package com.protournament.app

import android.media.audiofx.Equalizer
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * GROUP 8 — music-playback effects bridge (ARENA HUB #10 AUDIO).
 *
 * This is the SESSION-ROUTING layer for the playback DSP effects. It
 * owns NO effect parameters — Groups 3/4/5 own those
 * (`setReverb` / `setEcho` / `setDelay` / `setBass` / `setEq`) — and
 * it creates NO effect instances of its own beyond a short-lived
 * attach probe (see [attachPlayback]). It owns three methods on the
 * shared `arena_audio/effects` channel:
 *
 *   * `attachPlayback`  — probe + record that playback effects are
 *     wanted; returns the session-routing report.
 *   * `detachPlayback`  — clear the attach state.
 *   * `getSessionInfo`  — the session-routing report, no side effects.
 *
 * ## How audio-session routing works (verified, not assumed)
 *
 * Android `AudioEffect` subclasses (EnvironmentalReverb, BassBoost,
 * Equalizer, ...) attach to an audio session ID passed to their
 * constructor. The music player is audioplayers 6.8.1, and that
 * plugin exposes NO session ID anywhere:
 *
 *   * no `audioSessionId` in the Dart package or in
 *     `audioplayers_platform_interface`;
 *   * in `audioplayers_android` 5.3.0 the `MediaPlayer` is a private
 *     field of `MediaPlayerWrapper`, the `players` map is private in
 *     `AudioplayersPlugin`, and no method-channel method returns a
 *     session ID.
 *
 * So per-player attachment is IMPOSSIBLE without forking
 * audioplayers (a fork would add a method-channel method returning
 * `MediaPlayer.getAudioSessionId()` for a playerId). The routing
 * actually used — by Groups 3/4/5 and by this bridge — is therefore
 * **audio session 0, the global output mix**: effects constructed
 * with session 0 colour all audio routed through the device output
 * mix while enabled. Consequences, stated plainly:
 *
 *   * the music player IS coloured (it plays through the mix);
 *   * while an effect is enabled, other audio is coloured too
 *     (UI sounds, other apps' playback, and voice audio routed
 *     through the mix) — so effects must be released/disabled when
 *     the music stops, which Groups 3/4/5 do at amount 0 / dispose;
 *   * attaching to session 0 needs MODIFY_AUDIO_SETTINGS, which is
 *     already in AndroidManifest.xml (a normal permission, granted
 *     at install, no runtime prompt).
 *
 * The effect instances themselves are created lazily by the groups'
 * native files (ReverbEffect.kt / BassEqEffect.kt) on the first
 * parameter call, and each group releases its own. This bridge
 * deliberately does NOT create duplicate effects: two reverbs or two
 * EQs on the same session would double-apply.
 *
 * ## Merge wiring (coordinator)
 *
 * ONE MethodChannel handler serves the whole `arena_audio/effects`
 * channel — a second `setMethodCallHandler` replaces the first. Drop
 * this bridge into the single dispatcher in MainActivity, next to
 * the other groups' handlers:
 *
 *     val playbackBridge = PlaybackEffectsBridge()
 *     MethodChannel(messenger, "arena_audio/effects")
 *         .setMethodCallHandler { call, result ->
 *             if (playbackBridge.onMethodCall(call, result))
 *                 return@setMethodCallHandler
 *             // ... other groups' handlers ...
 *             result.notImplemented()
 *         }
 *     // ... and on engine destroy: playbackBridge.release()
 *
 * [register] exists only for single-group standalone testing.
 */
class PlaybackEffectsBridge {

    companion object {
        private const val TAG = "PlaybackEffectsBridge"
        private const val CHANNEL = "arena_audio/effects"

        /** Audio session 0 = the global output mix. */
        private const val OUTPUT_MIX_SESSION = 0
    }

    @Volatile
    private var attached = false

    /**
     * Last probe outcome, or null if [attachPlayback] never ran.
     * Tracked separately from [attached]: detaching does not mean
     * the device lost its effect engine.
     */
    @Volatile
    private var effectsAvailable: Boolean? = null

    /**
     * Handles one method call on the shared `arena_audio/effects`
     * channel. Returns true if this bridge owns the method
     * (`attachPlayback` / `detachPlayback` / `getSessionInfo`) and
     * answered [result]; false otherwise, so the caller can route the
     * call to another effect group.
     */
    fun onMethodCall(call: MethodCall, result: MethodChannel.Result): Boolean {
        return when (call.method) {
            "attachPlayback" -> {
                attachPlayback(result)
                true
            }
            "detachPlayback" -> {
                detachPlayback(result)
                true
            }
            "getSessionInfo" -> {
                result.success(sessionInfoMap())
                true
            }
            else -> false
        }
    }

    /**
     * Standalone registration: creates the channel handler for
     * `arena_audio/effects` and answers ONLY this bridge's three
     * methods (every other method gets `notImplemented`). See the
     * merge warning above — in the merged app, route through
     * [onMethodCall] from the single shared handler instead.
     */
    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            if (!onMethodCall(call, result)) {
                result.notImplemented()
            }
        }
    }

    /**
     * Probes whether an AudioEffect can be attached to the global
     * output mix on this device, and records the attach state.
     *
     * The probe creates a throwaway [Equalizer] on session 0 and
     * releases it immediately: a freshly created effect is disabled
     * by default, so nothing audible happens. If creation throws
     * (no effect engine on this device/emulator, missing
     * MODIFY_AUDIO_SETTINGS, ...) the report says
     * `effectsAvailable: false` and `attached: false` — the Dart
     * side then knows reverb/bass/EQ will not work on this device.
     * Never throws; always answers [result].
     */
    private fun attachPlayback(result: MethodChannel.Result) {
        val available = probeOutputMix()
        effectsAvailable = available
        attached = available
        if (!available) {
            Log.w(TAG, "No AudioEffect engine available on session 0")
        }
        result.success(sessionInfoMap())
    }

    /** Clears the attach state. Does NOT release other groups'
     * effects — each group releases its own (amount 0 / dispose). */
    private fun detachPlayback(result: MethodChannel.Result) {
        attached = false
        result.success(sessionInfoMap())
    }

    /** The session-routing report. No side effects. */
    private fun sessionInfoMap(): Map<String, Any> {
        return mapOf(
            "sessionId" to OUTPUT_MIX_SESSION,
            "routing" to "global-mix",
            "perPlayerSession" to false,
            "playerSessionAvailable" to false,
            "reason" to
                "audioplayers 6.8.1 does not expose the player's " +
                "audio session ID; effects attach to session 0 " +
                "(global output mix)",
            "attached" to attached,
            // Last probe outcome; null until attachPlayback runs.
            // Detaching clears `attached`, never this.
            "effectsAvailable" to (effectsAvailable ?: false),
            "probed" to (effectsAvailable != null),
        )
    }

    /**
     * Creates and immediately releases an [Equalizer] on session 0.
     * Returns true if the platform effect could be created.
     */
    private fun probeOutputMix(): Boolean {
        return try {
            Equalizer(0, OUTPUT_MIX_SESSION).release()
            true
        } catch (e: Exception) {
            Log.w(TAG, "Session-0 effect probe failed", e)
            false
        }
    }

    /** Clears the attach state. Call when the engine is destroyed;
     * safe to call more than once. */
    fun release() {
        attached = false
    }
}
