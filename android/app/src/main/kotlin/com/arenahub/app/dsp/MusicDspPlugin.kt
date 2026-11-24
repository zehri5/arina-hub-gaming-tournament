package com.arenahub.app.dsp

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.LinkedList
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.TimeUnit
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

class MusicDspPlugin : FlutterPlugin, MethodCallHandler, EventChannel.StreamHandler {

    companion object {
        const val METHOD_CHANNEL_NAME = "com.arenahub.app/music_dsp"
        const val EVENT_CHANNEL_NAME = "com.arenahub.app/music_dsp_events"

        private const val TARGET_SAMPLE_RATE = 48000
        private const val TARGET_CHANNELS = 2
        private const val TARGET_CHUNK_BYTES = 7680 // 40 ms @ 48 kHz, stereo, 16-bit PCM
        private const val MAX_QUEUED_CHUNKS = 6     // 240 ms max headroom
        private const val PREBUFFER_CHUNKS = 3      // 120 ms pre-roll for gapless start
        private const val CODEC_TIMEOUT_US = 10_000L
        // K2: cap on decodeNextChunkInternal iterations — a stalled
        // codec must never spin the command executor forever.
        private const val MAX_DECODE_ITERATIONS = 128
        // K6: enqueueChunkForPlayback poll slice — bounds how long a
        // full queue can block a writeChunk when the consumer died.
        private const val ENQUEUE_WAIT_MS = 250L
    }

    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    private var eventSink: EventChannel.EventSink? = null
    private var commandExecutor: ExecutorService? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    private val decoderLock = ReentrantLock()
    private var extractor: MediaExtractor? = null
    private var codec: MediaCodec? = null
    private var decoderInputEos = false
    private var decoderOutputEos = false
    private var srcSampleRate = TARGET_SAMPLE_RATE
    private var srcChannels = TARGET_CHANNELS
    private var isFloatPcm = false
    // K11: written under decoderLock on the command executor, read
    // lock-free by the playback thread (position emit) — @Volatile
    // for cross-thread visibility.
    @Volatile
    private var durationMs = 0L
    private var resampler = PcmResampler(TARGET_SAMPLE_RATE, TARGET_CHANNELS)

    private var stagingBuf = ByteArray(TARGET_CHUNK_BYTES * 4)
    private var stagingLen = 0

    private val queueLock = ReentrantLock()
    private val queueNotEmpty = queueLock.newCondition()
    private val queueNotFull = queueLock.newCondition()
    private val chunkQueue = LinkedList<ByteArray>()

    private var audioTrack: AudioTrack? = null
    private var playbackThread: Thread? = null
    private var isLoaded = false
    private var isPlaying = false
    private var isPaused = false
    private var playbackStopped = true
    private var eosQueued = false
    private var seekGeneration = 0
    // K11: same cross-thread read as durationMs (playback thread).
    @Volatile
    private var seekBasePositionMs = 0L
    private var currentVolume = 1.0f

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        commandExecutor = Executors.newSingleThreadExecutor()
        methodChannel = MethodChannel(binding.binaryMessenger, METHOD_CHANNEL_NAME).apply {
            setMethodCallHandler(this@MusicDspPlugin)
        }
        eventChannel = EventChannel(binding.binaryMessenger, EVENT_CHANNEL_NAME).apply {
            setStreamHandler(this@MusicDspPlugin)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel?.setMethodCallHandler(null)
        methodChannel = null
        eventChannel?.setStreamHandler(null)
        eventChannel = null
        eventSink = null

        val exec = commandExecutor
        commandExecutor = null
        if (exec != null) {
            exec.execute { releaseAllInternal() }
            exec.shutdown()
        } else {
            releaseAllInternal()
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        try {
            handleCall(call, result)
        } catch (e: RejectedExecutionException) {
            // K8 fix (2026-11-22): detach can race the dispatch — the
            // executor shuts down between the isShutdown check and
            // execute(), so no reply was ever queued. Answer DETACHED
            // here instead of hanging the Dart call forever.
            result.error("DETACHED", "MusicDspPlugin is detached from FlutterEngine.", null)
        }
    }

    private fun handleCall(call: MethodCall, result: Result) {
        val exec = commandExecutor
        if (exec == null || exec.isShutdown) {
            result.error("DETACHED", "MusicDspPlugin is detached from FlutterEngine.", null)
            return
        }

        when (call.method) {
            "load" -> {
                val filePath = call.argument<String>("filePath")
                if (filePath.isNullOrBlank()) {
                    result.error("INVALID_ARGS", "Missing or empty 'filePath'.", null)
                    return
                }
                exec.execute {
                    try {
                        val loadedDurationMs = loadInternal(filePath)
                        replySuccess(result, mapOf("durationMs" to loadedDurationMs))
                    } catch (e: Exception) {
                        releaseAllInternal()
                        replyError(result, "LOAD_FAILED", e.message ?: "Failed to load audio file.")
                    }
                }
            }

            "start" -> {
                exec.execute {
                    try {
                        startPlaybackInternal()
                        replySuccess(result, null)
                    } catch (e: Exception) {
                        replyError(result, "PLAY_FAILED", e.message ?: "Failed to start playback.")
                    }
                }
            }

            "pause" -> {
                exec.execute {
                    pauseInternal()
                    replySuccess(result, null)
                }
            }

            "resume" -> {
                exec.execute {
                    try {
                        resumeInternal()
                        replySuccess(result, null)
                    } catch (e: Exception) {
                        replyError(result, "RESUME_FAILED", e.message ?: "Failed to resume playback.")
                    }
                }
            }

            "stop" -> {
                exec.execute {
                    stopPlaybackOnlyInternal()
                    replySuccess(result, null)
                }
            }

            "seek" -> {
                val positionMs = call.argument<Number>("positionMs")?.toLong()
                if (positionMs == null) {
                    result.error("INVALID_ARGS", "Missing 'positionMs'.", null)
                    return
                }
                exec.execute {
                    try {
                        val actualMs = seekInternal(positionMs)
                        replySuccess(result, actualMs)
                    } catch (e: Exception) {
                        replyError(result, "SEEK_FAILED", e.message ?: "Failed to seek audio.")
                    }
                }
            }

            "setVolume" -> {
                val volume = call.argument<Number>("volume")?.toFloat() ?: 1.0f
                exec.execute {
                    currentVolume = max(0.0f, min(1.0f, volume))
                    try {
                        // K5 fix (2026-11-22): the track can be
                        // released concurrently by
                        // stopPlaybackThreadOnly(); an unguarded
                        // setVolume() throws IllegalStateException,
                        // kills this executor task before the reply,
                        // and hangs the Dart setVolume() call
                        // (play() awaits it). A released track simply
                        // drops the update — the next track is created
                        // with currentVolume anyway.
                        audioTrack?.setVolume(currentVolume)
                    } catch (_: IllegalStateException) {
                    }
                    replySuccess(result, null)
                }
            }

            "nextChunk" -> {
                exec.execute {
                    try {
                        val chunk = decodeNextChunkInternal()
                        replySuccess(result, chunk)
                    } catch (e: Exception) {
                        emitError(e.message ?: "Audio decoding error.")
                        replyError(result, "DECODE_FAILED", e.message ?: "Audio decoding error.")
                    }
                }
            }

            "writeChunk" -> {
                val pcmBytes = call.argument<ByteArray>("pcmBytes")
                if (pcmBytes == null) {
                    result.error("INVALID_ARGS", "Missing 'pcmBytes'.", null)
                    return
                }
                // Run on a separate thread from commandExecutor so pause/stop are never blocked
                Thread {
                    val accepted = enqueueChunkForPlayback(pcmBytes)
                    replySuccess(result, accepted)
                }.start()
            }

            "finishStream" -> {
                exec.execute {
                    queueLock.withLock {
                        eosQueued = true
                        queueNotEmpty.signalAll()
                    }
                    replySuccess(result, null)
                }
            }

            "dispose" -> {
                exec.execute {
                    releaseAllInternal()
                    replySuccess(result, null)
                }
            }

            else -> result.notImplemented()
        }
    }

    private fun loadInternal(filePath: String): Long {
        releaseAllInternal()

        val file = File(filePath)
        if (!file.exists() || !file.isFile || !file.canRead()) {
            throw IllegalArgumentException("Audio file does not exist or is unreadable: $filePath")
        }

        // K1 fix (2026-11-22): the extractor/codec locals are only
        // published to the fields inside the decoderLock block below.
        // If setDataSource / createDecoderByType / configure / start
        // throws first, the caller's releaseAllInternal() cannot see
        // them and they leak (file descriptor + codec instance) —
        // so release the locals here on failure.
        val mediaExtractor = MediaExtractor()
        var createdCodec: MediaCodec? = null
        var resolvedFormat: MediaFormat? = null
        try {
            mediaExtractor.setDataSource(filePath)

            var audioTrackIndex = -1
            for (i in 0 until mediaExtractor.trackCount) {
                val format = mediaExtractor.getTrackFormat(i)
                val mime = format.getString(MediaFormat.KEY_MIME) ?: ""
                if (mime.startsWith("audio/")) {
                    audioTrackIndex = i
                    resolvedFormat = format
                    break
                }
            }

            val format = resolvedFormat
            if (audioTrackIndex < 0 || format == null) {
                throw IllegalStateException("No audio track found in file: $filePath")
            }

            mediaExtractor.selectTrack(audioTrackIndex)
            val mime = format.getString(MediaFormat.KEY_MIME)
                ?: throw IllegalStateException("Audio track missing MIME type.")

            val codec = MediaCodec.createDecoderByType(mime)
            createdCodec = codec
            codec.configure(format, null, null, 0)
            codec.start()
        } catch (e: Exception) {
            try {
                createdCodec?.release()
            } catch (_: Exception) {
            }
            try {
                mediaExtractor.release()
            } catch (_: Exception) {
            }
            throw e
        }

        // Only reachable with a live codec + resolved format.
        val mediaCodec = createdCodec
            ?: throw IllegalStateException("Audio decoder was not created.")
        val audioFormat = resolvedFormat
            ?: throw IllegalStateException("Audio track format was not resolved.")

        decoderLock.withLock {
            extractor = mediaExtractor
            codec = mediaCodec
            decoderInputEos = false
            decoderOutputEos = false
            srcSampleRate = if (audioFormat.containsKey(MediaFormat.KEY_SAMPLE_RATE)) {
                audioFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            } else {
                TARGET_SAMPLE_RATE
            }
            srcChannels = if (audioFormat.containsKey(MediaFormat.KEY_CHANNEL_COUNT)) {
                audioFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            } else {
                TARGET_CHANNELS
            }
            isFloatPcm = if (audioFormat.containsKey(MediaFormat.KEY_PCM_ENCODING)) {
                audioFormat.getInteger(MediaFormat.KEY_PCM_ENCODING) == AudioFormat.ENCODING_PCM_FLOAT
            } else {
                false
            }
            durationMs = if (audioFormat.containsKey(MediaFormat.KEY_DURATION)) {
                max(0L, audioFormat.getLong(MediaFormat.KEY_DURATION) / 1000L)
            } else {
                0L
            }
            resampler = PcmResampler(srcSampleRate, srcChannels)
            stagingLen = 0
            isLoaded = true
            seekBasePositionMs = 0L
        }

        emitState(playing = false)
        emitPosition(0L, durationMs)
        return durationMs
    }

    private fun startPlaybackInternal() {
        if (!isLoaded) {
            throw IllegalStateException("No audio file loaded. Call load() before play().")
        }

        stopPlaybackThreadOnly()

        val track = createAudioTrack()
        queueLock.withLock {
            chunkQueue.clear()
            playbackStopped = false
            isPaused = false
            isPlaying = true
            eosQueued = false
            audioTrack = track
            seekGeneration++
        }

        val gen = queueLock.withLock { seekGeneration }
        val thread = Thread({ playbackLoop(track, gen) }, "ArenaMusicAudioTrack")
        // K7: publish the thread under queueLock like every other
        // reader (resumeInternal / stopPlaybackThreadOnly /
        // enqueueChunkForPlayback) expects.
        queueLock.withLock { playbackThread = thread }
        thread.start()

        emitState(playing = true)
    }

    private fun pauseInternal() {
        queueLock.withLock {
            if (!isPlaying || isPaused) return
            isPaused = true
            isPlaying = false
            try {
                audioTrack?.pause()
            } catch (_: IllegalStateException) {
            }
            queueNotEmpty.signalAll()
            queueNotFull.signalAll()
        }
        emitState(playing = false)
    }

    private fun resumeInternal() {
        if (!isLoaded) {
            throw IllegalStateException("No audio file loaded.")
        }
        // K7 fix (2026-11-22): read the consumer-thread state under
        // queueLock — the playback thread mutates playbackStopped
        // (EOS path) and the old unlocked read could take the wrong
        // branch on a stale value.
        val needsRestart = queueLock.withLock {
            playbackThread == null || playbackStopped
        }
        if (needsRestart) {
            startPlaybackInternal()
            return
        }
        queueLock.withLock {
            if (!isPaused) return
            isPaused = false
            isPlaying = true
            try {
                audioTrack?.play()
            } catch (_: IllegalStateException) {
            }
            queueNotEmpty.signalAll()
            queueNotFull.signalAll()
        }
        emitState(playing = true)
    }

    private fun stopPlaybackOnlyInternal() {
        stopPlaybackThreadOnly()
        decoderLock.withLock {
            if (isLoaded) {
                try {
                    extractor?.seekTo(0L, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
                    codec?.flush()
                } catch (_: Exception) {
                }
                decoderInputEos = false
                decoderOutputEos = false
                stagingLen = 0
                resampler.reset()
                seekBasePositionMs = 0L
            }
        }
        emitState(playing = false)
        emitPosition(0L, durationMs)
    }

    private fun seekInternal(requestedMs: Long): Long {
        if (!isLoaded) {
            throw IllegalStateException("No audio file loaded.")
        }
        val clampedMs = if (durationMs > 0L) {
            max(0L, min(durationMs, requestedMs))
        } else {
            max(0L, requestedMs)
        }
        val targetUs = clampedMs * 1000L

        val wasPlaying = queueLock.withLock {
            val playing = isPlaying && !isPaused
            chunkQueue.clear()
            eosQueued = false
            seekGeneration++
            try {
                audioTrack?.pause()
                audioTrack?.flush()
            } catch (_: IllegalStateException) {
            }
            queueNotEmpty.signalAll()
            queueNotFull.signalAll()
            playing
        }

        decoderLock.withLock {
            val ext = extractor ?: throw IllegalStateException("Extractor not initialized.")
            val dec = codec ?: throw IllegalStateException("Codec not initialized.")
            ext.seekTo(targetUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
            dec.flush()
            decoderInputEos = false
            decoderOutputEos = false
            stagingLen = 0
            resampler.reset()
            seekBasePositionMs = clampedMs

            // Trim frames prior to targetUs so seek lands accurately on targetMs
            trimDecoderToTimestamp(ext, dec, targetUs)
        }

        if (wasPlaying) {
            queueLock.withLock {
                if (!playbackStopped && !isPaused) {
                    try {
                        audioTrack?.play()
                    } catch (_: IllegalStateException) {
                    }
                }
            }
        }

        emitPosition(clampedMs, durationMs)
        return clampedMs
    }

    private fun trimDecoderToTimestamp(ext: MediaExtractor, dec: MediaCodec, targetUs: Long) {
        if (targetUs <= 0L) return
        val info = MediaCodec.BufferInfo()
        var iterations = 0
        while (!decoderOutputEos && iterations < 64) {
            iterations++
            feedCodecInput(ext, dec)
            val outIndex = dec.dequeueOutputBuffer(info, CODEC_TIMEOUT_US)
            when {
                outIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    updateOutputFormat(dec.outputFormat)
                }
                outIndex >= 0 -> {
                    if ((info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                        decoderOutputEos = true
                    }
                    if (info.presentationTimeUs >= targetUs - 20_000L || decoderOutputEos) {
                        if (info.size > 0) {
                            val outBuf = dec.getOutputBuffer(outIndex)
                            if (outBuf != null) {
                                appendDecodedBuffer(outBuf, info)
                            }
                        }
                        dec.releaseOutputBuffer(outIndex, false)
                        break
                    }
                    dec.releaseOutputBuffer(outIndex, false)
                }
                else -> {
                    if (decoderInputEos) break
                }
            }
        }
    }

    private fun decodeNextChunkInternal(): ByteArray? {
        decoderLock.withLock {
            if (!isLoaded) return null
            val ext = extractor ?: return null
            val dec = codec ?: return null
            val info = MediaCodec.BufferInfo()

            // K2 fix (2026-11-22): a stalled codec (no output, no EOS)
            // used to spin this loop forever on the single-thread
            // command executor, blocking pause/stop/seek/dispose.
            // Cap the iterations; the tail below returns whatever was
            // staged (partial chunk) or an EMPTY array on the cap —
            // never null, because Dart reads null as end-of-stream.
            var iterations = 0
            while (stagingLen < TARGET_CHUNK_BYTES && !decoderOutputEos && iterations < MAX_DECODE_ITERATIONS) {
                iterations++
                feedCodecInput(ext, dec)

                val outIndex = dec.dequeueOutputBuffer(info, CODEC_TIMEOUT_US)
                when {
                    outIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        updateOutputFormat(dec.outputFormat)
                    }
                    outIndex >= 0 -> {
                        if (info.size > 0) {
                            val outBuf = dec.getOutputBuffer(outIndex)
                            if (outBuf != null) {
                                appendDecodedBuffer(outBuf, info)
                            }
                        }
                        if ((info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                            decoderOutputEos = true
                        }
                        dec.releaseOutputBuffer(outIndex, false)
                    }
                    outIndex == MediaCodec.INFO_TRY_AGAIN_LATER -> {
                        if (decoderInputEos && stagingLen > 0) {
                            break
                        }
                    }
                }
            }

            if (stagingLen >= TARGET_CHUNK_BYTES) {
                val out = stagingBuf.copyOfRange(0, TARGET_CHUNK_BYTES)
                val remaining = stagingLen - TARGET_CHUNK_BYTES
                if (remaining > 0) {
                    System.arraycopy(stagingBuf, TARGET_CHUNK_BYTES, stagingBuf, 0, remaining)
                }
                stagingLen = remaining
                return out
            }

            if (stagingLen > 0 && (decoderOutputEos || iterations >= MAX_DECODE_ITERATIONS)) {
                val out = stagingBuf.copyOfRange(0, stagingLen)
                stagingLen = 0
                return out
            }

            if (!decoderOutputEos && iterations >= MAX_DECODE_ITERATIONS) {
                // Stalled codec, nothing staged: empty (not null) so
                // the Dart pump retries instead of finishing the stream.
                return ByteArray(0)
            }

            return null
        }
    }

    private fun feedCodecInput(ext: MediaExtractor, dec: MediaCodec) {
        if (decoderInputEos) return
        val inIndex = dec.dequeueInputBuffer(CODEC_TIMEOUT_US)
        if (inIndex < 0) return

        val inBuf = dec.getInputBuffer(inIndex)
        if (inBuf == null) {
            // K9 fix (2026-11-22): returning here would leak the
            // dequeued input buffer (never queued back), eventually
            // starving the codec of input buffers. Queue an empty
            // buffer to hand the index back.
            dec.queueInputBuffer(inIndex, 0, 0, 0L, 0)
            return
        }
        val sampleSize = ext.readSampleData(inBuf, 0)
        if (sampleSize < 0) {
            dec.queueInputBuffer(
                inIndex,
                0,
                0,
                0L,
                MediaCodec.BUFFER_FLAG_END_OF_STREAM
            )
            decoderInputEos = true
        } else {
            val ptsUs = ext.sampleTime
            dec.queueInputBuffer(inIndex, 0, sampleSize, ptsUs, 0)
            ext.advance()
        }
    }

    private fun updateOutputFormat(format: MediaFormat) {
        val newRate = if (format.containsKey(MediaFormat.KEY_SAMPLE_RATE)) {
            format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
        } else {
            srcSampleRate
        }
        val newChannels = if (format.containsKey(MediaFormat.KEY_CHANNEL_COUNT)) {
            format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
        } else {
            srcChannels
        }
        isFloatPcm = if (format.containsKey(MediaFormat.KEY_PCM_ENCODING)) {
            format.getInteger(MediaFormat.KEY_PCM_ENCODING) == AudioFormat.ENCODING_PCM_FLOAT
        } else {
            false
        }
        if (newRate != srcSampleRate || newChannels != srcChannels) {
            srcSampleRate = newRate
            srcChannels = newChannels
            resampler.reconfigure(srcSampleRate, srcChannels)
        }
    }

    private fun appendDecodedBuffer(outBuf: ByteBuffer, info: MediaCodec.BufferInfo) {
        outBuf.position(info.offset)
        outBuf.limit(info.offset + info.size)
        val rawBytes = ByteArray(info.size)
        outBuf.get(rawBytes)

        val pcm48kStereo = resampler.process(rawBytes, isFloatPcm)
        if (pcm48kStereo.isEmpty()) return

        val needed = stagingLen + pcm48kStereo.size
        if (needed > stagingBuf.size) {
            val newSize = max(needed, stagingBuf.size * 2)
            stagingBuf = stagingBuf.copyOf(newSize)
        }
        System.arraycopy(pcm48kStereo, 0, stagingBuf, stagingLen, pcm48kStereo.size)
        stagingLen += pcm48kStereo.size
    }

    private fun enqueueChunkForPlayback(pcmBytes: ByteArray): Boolean {
        if (pcmBytes.isEmpty()) return true
        queueLock.withLock {
            val startGen = seekGeneration
            // K6 fix (2026-11-22): the old unbounded await() wedged
            // the Dart pump forever if the playback thread died (e.g.
            // AudioTrack write error) with a full queue — nothing
            // ever drained or signalled again. Poll with a timeout
            // and bail out when the consumer thread is dead; the Dart
            // pump then stops (it already got the error event)
            // instead of hanging in writeChunk until stop/dispose.
            while (chunkQueue.size >= MAX_QUEUED_CHUNKS &&
                !playbackStopped &&
                !isPaused &&
                seekGeneration == startGen &&
                playbackThreadAlive()
            ) {
                try {
                    queueNotFull.await(ENQUEUE_WAIT_MS, TimeUnit.MILLISECONDS)
                } catch (_: InterruptedException) {
                    return false
                }
            }

            if (playbackStopped || isPaused || seekGeneration != startGen || !playbackThreadAlive()) {
                return false
            }

            chunkQueue.addLast(pcmBytes)
            queueNotEmpty.signalAll()
            return true
        }
    }

    /**
     * True when a consumer thread exists and is alive. A null thread
     * (playback never started) counts as alive here: the queue can
     * still accept chunks and the start path drains them.
     */
    private fun playbackThreadAlive(): Boolean {
        val thread = playbackThread
        return thread == null || thread.isAlive
    }

    private fun playbackLoop(track: AudioTrack, initialGeneration: Int) {
        var startedTrack = false
        var chunksSincePosEmit = 0

        try {
            while (true) {
                var chunk: ByteArray? = null
                var reachedEos = false
                var currentGen = initialGeneration

                queueLock.withLock {
                    while (!playbackStopped &&
                        (isPaused ||
                            (chunkQueue.isEmpty() && !eosQueued) ||
                            (!startedTrack && chunkQueue.size < PREBUFFER_CHUNKS && !eosQueued))
                    ) {
                        queueNotEmpty.await()
                    }

                    if (playbackStopped) {
                        return
                    }

                    currentGen = seekGeneration
                    if (chunkQueue.isNotEmpty()) {
                        chunk = chunkQueue.removeFirst()
                        queueNotFull.signalAll()
                    } else if (eosQueued) {
                        reachedEos = true
                    }
                }

                if (reachedEos) {
                    // K4 fix (2026-11-22): a seek (or stop) can land
                    // between the EOS determination above and this
                    // block. The old code emitted 'completed' and
                    // returned unconditionally — after a seek that
                    // killed playback for good (Dart stops pumping
                    // and the playback thread is gone). Re-check the
                    // generation first: a stale EOS rejoins the wait
                    // loop, a stop exits silently, only a current EOS
                    // completes.
                    val eosDisposition = queueLock.withLock {
                        when {
                            playbackStopped -> EosDisposition.STOPPED
                            seekGeneration != currentGen -> EosDisposition.STALE
                            else -> {
                                isPlaying = false
                                isPaused = false
                                playbackStopped = true
                                EosDisposition.COMPLETE
                            }
                        }
                    }
                    when (eosDisposition) {
                        EosDisposition.STALE -> continue
                        EosDisposition.STOPPED -> return
                        EosDisposition.COMPLETE -> {
                            try {
                                if (startedTrack) {
                                    track.stop()
                                }
                            } catch (_: IllegalStateException) {
                            }
                            emitPosition(durationMs, durationMs)
                            emitState(playing = false)
                            emitCompleted()
                            return
                        }
                    }
                }

                val data = chunk ?: continue
                if (!startedTrack) {
                    track.play()
                    startedTrack = true
                }

                var offset = 0
                while (offset < data.size) {
                    val shouldAbort = queueLock.withLock {
                        playbackStopped || isPaused || seekGeneration != currentGen
                    }
                    if (shouldAbort) break

                    val written = track.write(
                        data,
                        offset,
                        data.size - offset,
                        AudioTrack.WRITE_BLOCKING
                    )
                    if (written < 0) {
                        // K10 fix (2026-11-22): the old code returned
                        // with isPlaying still true and
                        // playbackStopped still false, leaving the
                        // native state claiming a dead thread was
                        // playing. Mark it stopped so resume() takes
                        // the restart path instead of no-oping.
                        queueLock.withLock {
                            isPlaying = false
                            isPaused = false
                            playbackStopped = true
                        }
                        emitError("AudioTrack write error: $written")
                        return
                    }
                    offset += written
                }

                chunksSincePosEmit++
                if (chunksSincePosEmit >= 4) {
                    chunksSincePosEmit = 0
                    val headFrames = track.playbackHeadPosition.toLong() and 0xFFFFFFFFL
                    val playedMs = seekBasePositionMs + (headFrames * 1000L / TARGET_SAMPLE_RATE)
                    val clampedPos = if (durationMs > 0L) min(durationMs, playedMs) else playedMs
                    emitPosition(clampedPos, durationMs)
                }
            }
        } catch (_: InterruptedException) {
            // K3 fix (2026-11-22): stopPlaybackThreadOnly() interrupts
            // this thread to wake it from queueNotEmpty.await(). That
            // is an expected wake-up, not a playback failure — the old
            // code let it fall into the generic catch and emitted a
            // spurious error event on (nearly) every stop. Swallow it;
            // the finally block below still releases the track.
        } catch (e: Exception) {
            emitError(e.message ?: "AudioTrack playback error.")
        } finally {
            try {
                if (track.state == AudioTrack.STATE_INITIALIZED) {
                    track.pause()
                    track.flush()
                    track.release()
                }
            } catch (_: IllegalStateException) {
            }
        }
    }

    private fun createAudioTrack(): AudioTrack {
        val minBufSize = AudioTrack.getMinBufferSize(
            TARGET_SAMPLE_RATE,
            AudioFormat.CHANNEL_OUT_STEREO,
            AudioFormat.ENCODING_PCM_16BIT
        )
        val bufferBytes = max(minBufSize * 2, TARGET_CHUNK_BYTES * 4)

        val attributes = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
            .build()

        val format = AudioFormat.Builder()
            .setSampleRate(TARGET_SAMPLE_RATE)
            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
            .setChannelMask(AudioFormat.CHANNEL_OUT_STEREO)
            .build()

        return AudioTrack.Builder()
            .setAudioAttributes(attributes)
            .setAudioFormat(format)
            .setBufferSizeInBytes(bufferBytes)
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build()
            .apply {
                setVolume(currentVolume)
            }
    }

    private fun stopPlaybackThreadOnly() {
        val threadToJoin: Thread?
        queueLock.withLock {
            playbackStopped = true
            isPlaying = false
            isPaused = false
            eosQueued = false
            chunkQueue.clear()
            try {
                audioTrack?.pause()
                audioTrack?.flush()
            } catch (_: IllegalStateException) {
            }
            queueNotEmpty.signalAll()
            queueNotFull.signalAll()
            threadToJoin = playbackThread
            playbackThread = null
            audioTrack = null
        }

        if (threadToJoin != null && threadToJoin != Thread.currentThread()) {
            threadToJoin.interrupt()
            try {
                threadToJoin.join(500L)
            } catch (_: InterruptedException) {
            }
        }
    }

    private fun releaseAllInternal() {
        stopPlaybackThreadOnly()

        decoderLock.withLock {
            isLoaded = false
            decoderInputEos = false
            decoderOutputEos = false
            stagingLen = 0
            durationMs = 0L
            seekBasePositionMs = 0L

            try {
                codec?.stop()
            } catch (_: Exception) {
            }
            try {
                codec?.release()
            } catch (_: Exception) {
            }
            codec = null

            try {
                extractor?.release()
            } catch (_: Exception) {
            }
            extractor = null
        }
    }

    private fun emitPosition(positionMs: Long, totalMs: Long) {
        sendEvent(
            mapOf(
                "type" to "position",
                "positionMs" to positionMs,
                "durationMs" to totalMs
            )
        )
    }

    private fun emitState(playing: Boolean) {
        sendEvent(
            mapOf(
                "type" to "state",
                "isPlaying" to playing
            )
        )
    }

    private fun emitCompleted() {
        sendEvent(mapOf("type" to "completed"))
    }

    private fun emitError(message: String) {
        sendEvent(
            mapOf(
                "type" to "error",
                "message" to message
            )
        )
    }

    private fun sendEvent(payload: Map<String, Any>) {
        mainHandler.post {
            eventSink?.success(payload)
        }
    }

    private fun replySuccess(result: Result, value: Any?) {
        mainHandler.post { result.success(value) }
    }

    private fun replyError(result: Result, code: String, message: String) {
        mainHandler.post { result.error(code, message, null) }
    }

    /** EOS-branch disposition (K4): distinguishes a genuine
     * end-of-stream from a seek/stop that raced it. */
    private enum class EosDisposition { STALE, STOPPED, COMPLETE }

    // Internal (not private) so the JVM host check in /tmp can
    // exercise the resampler math directly against the compiled
    // classes — the class has no Android dependencies. See
    // MUSIC_PLAYER_INTEGRATION.md §3.
    internal class PcmResampler(
        private var srcRate: Int,
        private var srcChannels: Int
    ) {
        private var prevL = 0.0
        private var prevR = 0.0
        private var hasPrev = false
        private var phase = 0.0

        fun reconfigure(newRate: Int, newChannels: Int) {
            srcRate = max(8000, newRate)
            srcChannels = max(1, newChannels)
            reset()
        }

        fun reset() {
            prevL = 0.0
            prevR = 0.0
            hasPrev = false
            phase = 0.0
        }

        fun process(rawBytes: ByteArray, isFloat: Boolean): ByteArray {
            if (rawBytes.isEmpty()) return ByteArray(0)

            if (!isFloat && srcRate == TARGET_SAMPLE_RATE && srcChannels == TARGET_CHANNELS) {
                return rawBytes
            }

            val bytesPerSample = if (isFloat) 4 else 2
            val frameStride = bytesPerSample * srcChannels
            val frameCount = rawBytes.size / frameStride
            if (frameCount <= 0) return ByteArray(0)

            val srcL = DoubleArray(frameCount)
            val srcR = DoubleArray(frameCount)
            val buf = ByteBuffer.wrap(rawBytes).order(ByteOrder.LITTLE_ENDIAN)

            for (i in 0 until frameCount) {
                val base = i * frameStride
                if (isFloat) {
                    val l = (buf.getFloat(base).toDouble() * 32767.0).coerceIn(-32768.0, 32767.0)
                    val r = if (srcChannels >= 2) {
                        (buf.getFloat(base + 4).toDouble() * 32767.0).coerceIn(-32768.0, 32767.0)
                    } else {
                        l
                    }
                    srcL[i] = l
                    srcR[i] = r
                } else {
                    val l = buf.getShort(base).toDouble()
                    val r = if (srcChannels >= 2) buf.getShort(base + 2).toDouble() else l
                    srcL[i] = l
                    srcR[i] = r
                }
            }

            if (srcRate == TARGET_SAMPLE_RATE) {
                val out = ByteArray(frameCount * 4)
                val outBuf = ByteBuffer.wrap(out).order(ByteOrder.LITTLE_ENDIAN)
                for (i in 0 until frameCount) {
                    outBuf.putShort(srcL[i].roundToInt().coerceIn(-32768, 32767).toShort())
                    outBuf.putShort(srcR[i].roundToInt().coerceIn(-32768, 32767).toShort())
                }
                prevL = srcL[frameCount - 1]
                prevR = srcR[frameCount - 1]
                hasPrev = true
                return out
            }

            if (!hasPrev) {
                prevL = srcL[0]
                prevR = srcR[0]
                hasPrev = true
                phase = 0.0
            }

            val step = srcRate.toDouble() / TARGET_SAMPLE_RATE.toDouble()
            val maxOutFrames = ((frameCount.toDouble() - phase) / step).toInt() + 4
            val outShorts = ShortArray(max(0, maxOutFrames) * 2)
            var outFrames = 0

            while (phase < (frameCount - 1).toDouble()) {
                val l: Double
                val r: Double
                if (phase < 0.0) {
                    val frac = phase + 1.0
                    l = prevL + frac * (srcL[0] - prevL)
                    r = prevR + frac * (srcR[0] - prevR)
                } else {
                    val idx = phase.toInt()
                    val frac = phase - idx.toDouble()
                    l = srcL[idx] + frac * (srcL[idx + 1] - srcL[idx])
                    r = srcR[idx] + frac * (srcR[idx + 1] - srcR[idx])
                }

                val outIdx = outFrames * 2
                if (outIdx + 1 < outShorts.size) {
                    outShorts[outIdx] = l.roundToInt().coerceIn(-32768, 32767).toShort()
                    outShorts[outIdx + 1] = r.roundToInt().coerceIn(-32768, 32767).toShort()
                    outFrames++
                }
                phase += step
            }

            prevL = srcL[frameCount - 1]
            prevR = srcR[frameCount - 1]
            phase -= frameCount.toDouble()

            val outBytes = ByteArray(outFrames * 4)
            val outBuf = ByteBuffer.wrap(outBytes).order(ByteOrder.LITTLE_ENDIAN)
            for (i in 0 until outFrames * 2) {
                outBuf.putShort(outShorts[i])
            }
            return outBytes
        }
    }
}
