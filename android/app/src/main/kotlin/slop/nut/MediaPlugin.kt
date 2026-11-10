package slop.nut

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.media.MediaMuxer
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLExt
import android.opengl.EGLSurface
import android.opengl.GLES20
import android.os.Build
import android.view.Surface
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.BufferedOutputStream
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.roundToLong

/**
 * Video and sound through Android's own media stack (MediaExtractor,
 * MediaMetadataRetriever, MediaCodec, MediaMuxer) - no bundled ffmpeg.
 * Channel "mcore/media"; long jobs run on a worker thread and report
 * progress back with "progress" calls.
 */
class MediaPlugin(messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, "mcore/media")
    private val worker = Executors.newFixedThreadPool(2)
    private val main = Handler(Looper.getMainLooper())
    private val cancelled: MutableSet<String> = java.util.Collections.synchronizedSet(HashSet<String>())
    private val encoders = ConcurrentHashMap<String, Encoder>()

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "cancel" -> {
                cancelled.add(call.argument<String>("job")!!)
                result.success(null)
            }
            "encoderAvailable" -> result.success(encoderName(call.argument<String>("mime")!!) != null)
            else -> worker.execute {
                try {
                    val value: Any? = when (call.method) {
                        "probe" -> probe(call.argument<String>("path")!!)
                        "extractFrames" -> extractFrames(call)
                        "decodeAudio" -> decodeAudio(call)
                        "beginEncode" -> beginEncode(call)
                        "encodeFrame" -> {
                            // no picture: the one before again (a still frame).
                            val e = encoders[call.argument<String>("id")!!]!!
                            val rgba = call.argument<ByteArray>("rgba")
                            if (rgba == null) e.repeat() else e.frame(rgba)
                            null
                        }
                        "finishEncode" -> {
                            val id = call.argument<String>("id")!!
                            val e = encoders.remove(id)!!
                            e.finish()
                        }
                        "abortEncode" -> {
                            encoders.remove(call.argument<String>("id")!!)?.abort()
                            null
                        }
                        "encodeImages" -> encodeImages(call)
                        "encodeAudioFile" -> encodeAudioFile(call)
                        else -> throw NotImplementedError(call.method)
                    }
                    main.post { result.success(value) }
                } catch (e: Throwable) {
                    main.post { result.error("media", e.message ?: e.toString(), null) }
                }
            }
        }
    }

    private fun progress(job: String, done: Int, total: Int) {
        main.post { channel.invokeMethod("progress", mapOf("job" to job, "done" to done, "total" to total)) }
    }

    // ===== probing =====

    private fun probe(path: String): Map<String, Any?> {
        val ex = MediaExtractor()
        try {
            ex.setDataSource(path)
            var width = 0
            var height = 0
            var fps = 0.0
            var durationUs = 0L
            var hasVideo = false
            var hasAudio = false
            var videoMime: String? = null
            for (i in 0 until ex.trackCount) {
                val f = ex.getTrackFormat(i)
                val mime = f.getString(MediaFormat.KEY_MIME) ?: continue
                if (f.containsKey(MediaFormat.KEY_DURATION)) durationUs = max(durationUs, f.getLong(MediaFormat.KEY_DURATION))
                if (mime.startsWith("video/") && !hasVideo) {
                    hasVideo = true
                    videoMime = mime
                    width = f.getInteger(MediaFormat.KEY_WIDTH)
                    height = f.getInteger(MediaFormat.KEY_HEIGHT)
                    if (f.containsKey(MediaFormat.KEY_FRAME_RATE)) {
                        fps = try { f.getInteger(MediaFormat.KEY_FRAME_RATE).toDouble() } catch (e: Exception) { f.getFloat(MediaFormat.KEY_FRAME_RATE).toDouble() }
                    }
                }
                if (mime.startsWith("audio/")) hasAudio = true
            }
            var rotation = 0
            var frameCount = 0
            if (hasVideo) {
                val r = MediaMetadataRetriever()
                try {
                    r.setDataSource(path)
                    rotation = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull() ?: 0
                    if (Build.VERSION.SDK_INT >= 28) {
                        frameCount = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_FRAME_COUNT)?.toIntOrNull() ?: 0
                    }
                } finally {
                    r.release()
                }
            }
            if (fps <= 0 && frameCount > 0 && durationUs > 0) fps = frameCount / (durationUs / 1e6)
            if (rotation == 90 || rotation == 270) {
                val t = width; width = height; height = t
            }
            return mapOf(
                "width" to width, "height" to height, "fps" to fps, "durationUs" to durationUs,
                "hasVideo" to hasVideo, "hasAudio" to hasAudio, "videoMime" to videoMime, "frameCount" to frameCount,
            )
        } finally {
            ex.release()
        }
    }

    // ===== frames out of a video =====

    /** Every frame at `fps` (sampled from the source's own), scaled into maxW x maxH, as JPEGs 000001.jpg... */
    private fun extractFrames(call: MethodCall): Map<String, Any> {
        val path = call.argument<String>("path")!!
        val outDir = File(call.argument<String>("outDir")!!)
        val outFps = call.argument<Double>("fps")!!
        val maxW = call.argument<Double>("maxWidth")!!
        val maxH = call.argument<Double>("maxHeight")!!
        val job = call.argument<String>("job")!!
        outDir.mkdirs()
        val info = probe(path)
        val durationUs = info["durationUs"] as Long
        val srcFps = (info["fps"] as Double).takeIf { it > 0 } ?: outFps
        val srcCount = info["frameCount"] as Int
        val total = max(1, (durationUs / 1e6 * outFps).toInt())
        val r = MediaMetadataRetriever()
        var written = 0
        var outW = 0
        var outH = 0
        try {
            r.setDataSource(path)
            fun save(bmp: Bitmap) {
                val k = min(1.0, min(maxW / bmp.width, maxH / bmp.height))
                val w = max(2, (bmp.width * k / 2).roundToInt() * 2)
                val h = max(2, (bmp.height * k / 2).roundToInt() * 2)
                val scaled = if (w == bmp.width && h == bmp.height) bmp else Bitmap.createScaledBitmap(bmp, w, h, true)
                outW = w; outH = h
                written++
                val name = String.format("%06d.jpg", written)
                BufferedOutputStream(FileOutputStream(File(outDir, name))).use { scaled.compress(Bitmap.CompressFormat.JPEG, 90, it) }
                if (scaled !== bmp) scaled.recycle()
                bmp.recycle()
                progress(job, written, total)
            }
            if (Build.VERSION.SDK_INT >= 28 && srcCount > 0) {
                // decoded in order, in batches (fast); the out frames pick
                // their nearest source frame.
                val wanted = (0 until total).map { i -> min(srcCount - 1, (i * srcFps / outFps).roundToInt()) }
                var i = 0
                while (i < wanted.size) {
                    if (cancelled.remove(job)) throw InterruptedException("cancelled")
                    val start = wanted[i]
                    var end = start
                    var j = i
                    while (j < wanted.size && wanted[j] - start < 24) { end = wanted[j]; j++ }
                    val batch = r.getFramesAtIndex(start, end - start + 1)
                    for (k in i until j) {
                        val src = batch[wanted[k] - start]
                        save(src.copy(src.config ?: Bitmap.Config.ARGB_8888, false))
                    }
                    for (b in batch) b.recycle()
                    i = j
                }
            } else {
                for (i in 0 until total) {
                    if (cancelled.remove(job)) throw InterruptedException("cancelled")
                    val t = (i * 1e6 / outFps).roundToLong()
                    val bmp = r.getFrameAtTime(t, MediaMetadataRetriever.OPTION_CLOSEST) ?: break
                    save(bmp)
                }
            }
        } finally {
            r.release()
        }
        if (written == 0) throw IllegalStateException("No frames could be read from this video.")
        return mapOf("count" to written, "width" to outW, "height" to outH,
            "sourceWidth" to info["width"] as Int, "sourceHeight" to info["height"] as Int)
    }

    // ===== sound =====

    /** The file's sound as 16-bit little-endian PCM at `rate` / `channels`. Returns its length in seconds. */
    private fun decodeAudio(call: MethodCall): Double {
        val path = call.argument<String>("path")!!
        val out = File(call.argument<String>("out")!!)
        val rate = call.argument<Int>("rate")!!
        val channels = call.argument<Int>("channels")!!
        val job = call.argument<String>("job")!!
        val ex = MediaExtractor()
        ex.setDataSource(path)
        var track = -1
        for (i in 0 until ex.trackCount) {
            if (ex.getTrackFormat(i).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true) { track = i; break }
        }
        if (track < 0) { ex.release(); throw IllegalStateException("This file has no sound.") }
        ex.selectTrack(track)
        val format = ex.getTrackFormat(track)
        val durationUs = if (format.containsKey(MediaFormat.KEY_DURATION)) format.getLong(MediaFormat.KEY_DURATION) else 0L
        val codec = MediaCodec.createDecoderByType(format.getString(MediaFormat.KEY_MIME)!!)
        codec.configure(format, null, null, 0)
        codec.start()
        out.parentFile?.mkdirs()
        val sink = BufferedOutputStream(FileOutputStream(out))
        val resampler = Resampler(rate, channels)
        val info = MediaCodec.BufferInfo()
        var inputDone = false
        var srcRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
        var srcChannels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
        var floatPcm = false
        var bytes = 0L
        try {
            while (true) {
                if (cancelled.remove(job)) throw InterruptedException("cancelled")
                if (!inputDone) {
                    val inIndex = codec.dequeueInputBuffer(10000)
                    if (inIndex >= 0) {
                        val buf = codec.getInputBuffer(inIndex)!!
                        val n = ex.readSampleData(buf, 0)
                        if (n < 0) {
                            codec.queueInputBuffer(inIndex, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputDone = true
                        } else {
                            codec.queueInputBuffer(inIndex, 0, n, ex.sampleTime, 0)
                            ex.advance()
                            if (durationUs > 0) progress(job, (ex.sampleTime / 1000).toInt().coerceAtLeast(0), (durationUs / 1000).toInt())
                        }
                    }
                }
                val outIndex = codec.dequeueOutputBuffer(info, 10000)
                if (outIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    val f = codec.outputFormat
                    srcRate = f.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                    srcChannels = f.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                    floatPcm = Build.VERSION.SDK_INT >= 24 && f.containsKey(MediaFormat.KEY_PCM_ENCODING) &&
                        f.getInteger(MediaFormat.KEY_PCM_ENCODING) == android.media.AudioFormat.ENCODING_PCM_FLOAT
                } else if (outIndex >= 0) {
                    val buf = codec.getOutputBuffer(outIndex)!!
                    buf.position(info.offset)
                    buf.limit(info.offset + info.size)
                    val pcm = resampler.push(buf.slice().order(ByteOrder.LITTLE_ENDIAN), srcRate, srcChannels, floatPcm)
                    sink.write(pcm)
                    bytes += pcm.size
                    codec.releaseOutputBuffer(outIndex, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) break
                }
            }
        } finally {
            sink.close()
            codec.stop()
            codec.release()
            ex.release()
        }
        if (bytes == 0L) throw IllegalStateException("No sound could be read from this file.")
        return bytes / (2.0 * channels) / rate
    }

    /** Linear resampling and channel mixing to 16-bit PCM, streaming. */
    private class Resampler(val rate: Int, val channels: Int) {
        private var pos = 0.0 // the next output sample's position in source samples
        private var prev: FloatArray? = null

        fun push(buf: ByteBuffer, srcRate: Int, srcChannels: Int, float: Boolean): ByteArray {
            val frames = buf.remaining() / (srcChannels * if (float) 4 else 2)
            val src = Array(frames) { FloatArray(channels) }
            for (f in 0 until frames) {
                var l = 0f
                var r = 0f
                for (c in 0 until srcChannels) {
                    val v = if (float) buf.getFloat() else buf.getShort() / 32768f
                    if (c == 0) l = v
                    if (c == 1) r = v
                }
                if (srcChannels == 1) r = l
                if (channels == 1) src[f][0] = (l + r) / 2 else { src[f][0] = l; src[f][1] = r }
            }
            val step = srcRate.toDouble() / rate
            val out = ByteBuffer.allocate(((frames / step) + 2).toInt() * channels * 2).order(ByteOrder.LITTLE_ENDIAN)
            // positions are relative to this buffer; index -1 is the last
            // frame of the previous one.
            while (pos < frames - 1) {
                val i = kotlin.math.floor(pos).toInt()
                val t = (pos - i).toFloat()
                val a = if (i < 0) prev ?: src[0] else src[i]
                val b = src[i + 1]
                for (c in 0 until channels) {
                    val v = (a[c] + (b[c] - a[c]) * t).coerceIn(-1f, 1f)
                    out.putShort((v * 32767).toInt().toShort())
                }
                pos += step
            }
            if (frames > 0) prev = src[frames - 1]
            pos -= frames
            val bytes = ByteArray(out.position())
            out.flip()
            out.get(bytes)
            return bytes
        }
    }

    // ===== encoding =====

    private fun encoderName(mime: String): String? {
        val list = MediaCodecList(MediaCodecList.REGULAR_CODECS)
        for (info in list.codecInfos) {
            if (!info.isEncoder) continue
            if (info.supportedTypes.any { it.equals(mime, ignoreCase = true) }) return info.name
        }
        return null
    }

    private fun beginEncode(call: MethodCall): String {
        val id = call.argument<String>("id")!!
        encoders[id] = Encoder(
            call.argument<String>("path")!!,
            call.argument<String>("codec")!!,
            call.argument<Int>("width")!!,
            call.argument<Int>("height")!!,
            call.argument<Double>("fps")!!,
            call.argument<Int>("bitrateKbps")!!,
            call.argument<String>("audioPcm"),
            call.argument<Int>("rate") ?: 48000,
            call.argument<Int>("channels") ?: 2,
            call.argument<Int>("audioKbps") ?: 160,
        )
        return id
    }

    /** Re-encodes a folder of 000001.jpg / .png frames (trimming media). */
    private fun encodeImages(call: MethodCall): String {
        val dir = File(call.argument<String>("dir")!!)
        val files = dir.listFiles { f -> f.name.endsWith(".jpg") || f.name.endsWith(".png") }!!.sortedBy { it.name }
        if (files.isEmpty()) throw IllegalStateException("No frames to encode.")
        val first = BitmapFactory.decodeFile(files[0].path)
        val w = first.width / 2 * 2
        val h = first.height / 2 * 2
        first.recycle()
        val codec = call.argument<String>("codec")!!
        val e = Encoder(call.argument<String>("path")!!, codec, w, h, call.argument<Double>("fps")!!,
            max(2000, (w * h * call.argument<Double>("fps")!! * 0.2 / 1000).toInt()), null, 48000, 2)
        try {
            val px = IntArray(w * h)
            val rgba = ByteArray(w * h * 4)
            for (f in files) {
                val bmp = BitmapFactory.decodeFile(f.path)
                val s = if (bmp.width == w && bmp.height == h) bmp else Bitmap.createScaledBitmap(bmp, w, h, true)
                s.getPixels(px, 0, w, 0, 0, w, h)
                for (i in px.indices) {
                    val p = px[i]
                    rgba[i * 4] = (p shr 16).toByte()
                    rgba[i * 4 + 1] = (p shr 8).toByte()
                    rgba[i * 4 + 2] = p.toByte()
                    rgba[i * 4 + 3] = (p ushr 24).toByte()
                }
                if (s !== bmp) s.recycle()
                bmp.recycle()
                e.frame(rgba)
            }
        } catch (t: Throwable) {
            e.abort()
            throw t
        }
        return e.finish()
    }

    /** A PCM file as a sound file: Opus in Ogg (Android 10+), else AAC in MP4. Returns the path written. */
    private fun encodeAudioFile(call: MethodCall): String {
        val pcm = File(call.argument<String>("pcm")!!)
        var path = call.argument<String>("path")!!
        val rate = call.argument<Int>("rate")!!
        val channels = call.argument<Int>("channels")!!
        val opus = Build.VERSION.SDK_INT >= 29 && encoderName(MediaFormat.MIMETYPE_AUDIO_OPUS) != null
        if (!opus) path = path.substringBeforeLast('.') + ".m4a"
        val muxer = if (Build.VERSION.SDK_INT >= 29 && opus) {
            MediaMuxer(path, MediaMuxer.OutputFormat.MUXER_OUTPUT_OGG)
        } else {
            MediaMuxer(path, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        }
        val kbps = call.argument<Int>("kbps") ?: 160
        val audio = AudioEncoder(if (opus) MediaFormat.MIMETYPE_AUDIO_OPUS else MediaFormat.MIMETYPE_AUDIO_AAC, rate, channels, kbps)
        val samples = audio.encodeAll(pcm)
        val track = muxer.addTrack(audio.format!!)
        muxer.start()
        for (s in samples) muxer.writeSampleData(track, ByteBuffer.wrap(s.data), s.info)
        muxer.stop()
        muxer.release()
        return path
    }

    private class Sample(val data: ByteArray, val info: MediaCodec.BufferInfo)

    /** PCM file -> encoded samples (whole file, in memory). */
    private inner class AudioEncoder(val mime: String, val rate: Int, val channels: Int, val kbps: Int = 160) {
        var format: MediaFormat? = null

        fun encodeAll(pcm: File): List<Sample> {
            val f = MediaFormat.createAudioFormat(mime, rate, channels)
            f.setInteger(MediaFormat.KEY_BIT_RATE, kbps * 1000)
            if (mime == MediaFormat.MIMETYPE_AUDIO_AAC) f.setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
            f.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 16384)
            val codec = MediaCodec.createByCodecName(encoderName(mime) ?: throw IllegalStateException("No $mime encoder"))
            codec.configure(f, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            codec.start()
            val out = ArrayList<Sample>()
            val input = pcm.inputStream().buffered()
            val info = MediaCodec.BufferInfo()
            var inputDone = false
            var frames = 0L
            val chunk = ByteArray(4096 * channels)
            try {
                while (true) {
                    if (!inputDone) {
                        val i = codec.dequeueInputBuffer(10000)
                        if (i >= 0) {
                            val buf = codec.getInputBuffer(i)!!
                            val n = input.read(chunk, 0, min(chunk.size, buf.capacity()))
                            val t = frames * 1_000_000L / rate
                            if (n <= 0) {
                                codec.queueInputBuffer(i, 0, 0, t, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                                inputDone = true
                            } else {
                                buf.clear()
                                buf.put(chunk, 0, n)
                                codec.queueInputBuffer(i, 0, n, t, 0)
                                frames += n / (2 * channels)
                            }
                        }
                    }
                    val o = codec.dequeueOutputBuffer(info, 10000)
                    if (o == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                        format = codec.outputFormat
                    } else if (o >= 0) {
                        if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0 && info.size > 0) {
                            val buf = codec.getOutputBuffer(o)!!
                            buf.position(info.offset)
                            buf.limit(info.offset + info.size)
                            val data = ByteArray(info.size)
                            buf.get(data)
                            val copy = MediaCodec.BufferInfo()
                            copy.set(0, info.size, info.presentationTimeUs, info.flags)
                            out.add(Sample(data, copy))
                        }
                        codec.releaseOutputBuffer(o, false)
                        if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) break
                    }
                }
            } finally {
                input.close()
                codec.stop()
                codec.release()
            }
            return out
        }
    }

    /**
     * RGBA frames in, H.264 (MP4) or VP9 (WebM) out, frames timed by their
     * index (fps). An optional PCM file becomes AAC (MP4) / Opus (WebM,
     * Android 10+) in the same file.
     */
    private inner class Encoder(
        val path: String, codecName: String, val width: Int, val height: Int, val fps: Double,
        bitrateKbps: Int, audioPcm: String?, rate: Int, channels: Int, audioKbps: Int = 160,
    ) {
        private val mime = if (codecName == "h264") MediaFormat.MIMETYPE_VIDEO_AVC else MediaFormat.MIMETYPE_VIDEO_VP9
        private val codec: MediaCodec
        private val muxer: MediaMuxer
        private var videoTrack = -1
        private var started = false
        private var index = 0L
        private val info = MediaCodec.BufferInfo()
        private var audioSamples: List<Sample>? = null
        private var audioFormat: MediaFormat? = null
        private val pending = ArrayList<Sample>()

        /** Surface input: the frame is drawn into the encoder by the GPU
         * (it turns RGB into YUV itself) - null: buffers filled on the CPU. */
        private var gl: GlInput? = null
        private var lastRgba: ByteArray? = null

        init {
            val name = encoderName(mime) ?: throw IllegalStateException("This phone has no $mime encoder")
            fun format(surface: Boolean): MediaFormat {
                val f = MediaFormat.createVideoFormat(mime, width, height)
                f.setInteger(
                    MediaFormat.KEY_COLOR_FORMAT,
                    if (surface) MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface
                    else MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible,
                )
                f.setInteger(MediaFormat.KEY_BIT_RATE, bitrateKbps * 1000)
                f.setFloat(MediaFormat.KEY_FRAME_RATE, fps.toFloat())
                f.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
                if (Build.VERSION.SDK_INT >= 29) f.setInteger(MediaFormat.KEY_MAX_B_FRAMES, 0)
                return f
            }
            var c = MediaCodec.createByCodecName(name)
            try {
                c.configure(format(true), null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
                val surface = c.createInputSurface()
                c.start()
                gl = GlInput(surface, width, height)
            } catch (t: Throwable) {
                // no surface input here: the CPU way.
                gl?.release()
                gl = null
                try { c.stop() } catch (e: Throwable) {}
                c.release()
                c = MediaCodec.createByCodecName(name)
                c.configure(format(false), null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
                c.start()
            }
            codec = c
            val webm = mime == MediaFormat.MIMETYPE_VIDEO_VP9
            muxer = MediaMuxer(path, if (webm) MediaMuxer.OutputFormat.MUXER_OUTPUT_WEBM else MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            if (audioPcm != null) {
                val audioMime = if (webm) MediaFormat.MIMETYPE_AUDIO_OPUS else MediaFormat.MIMETYPE_AUDIO_AAC
                if (!webm || (Build.VERSION.SDK_INT >= 29 && encoderName(audioMime) != null)) {
                    val enc = AudioEncoder(audioMime, rate, channels, audioKbps)
                    audioSamples = enc.encodeAll(File(audioPcm))
                    audioFormat = enc.format
                }
            }
        }

        /** An input buffer, draining the output while the encoder is full. */
        private fun nextInput(): Int {
            var i = codec.dequeueInputBuffer(10000)
            while (i < 0) {
                drain(false)
                i = codec.dequeueInputBuffer(10000)
            }
            return i
        }

        private fun pts() = (index * 1_000_000.0 / fps).toLong()

        fun frame(rgba: ByteArray) {
            val g = gl
            if (g != null) {
                g.draw(rgba, pts() * 1000)
            } else {
                val i = nextInput()
                val image = codec.getInputImage(i)!!
                rgbaToYuv(rgba, image)
                codec.queueInputBuffer(i, 0, width * height * 3 / 2, pts(), 0)
                lastRgba = rgba
            }
            index++
            drain(false)
        }

        /** The frame before, once more (nothing changed). */
        fun repeat() {
            val g = gl
            if (g != null) {
                g.draw(null, pts() * 1000)
                index++
                drain(false)
                return
            }
            frame(lastRgba ?: ByteArray(width * height * 4))
        }

        private fun rgbaToYuv(rgba: ByteArray, image: android.media.Image) {
            val planes = image.planes
            val y = planes[0].buffer
            val u = planes[1].buffer
            val v = planes[2].buffer
            val yRow = planes[0].rowStride
            val yPix = planes[0].pixelStride
            val uRow = planes[1].rowStride
            val uPix = planes[1].pixelStride
            val vRow = planes[2].rowStride
            val vPix = planes[2].pixelStride
            for (row in 0 until height) {
                for (col in 0 until width) {
                    val p = (row * width + col) * 4
                    val r = rgba[p].toInt() and 255
                    val g = rgba[p + 1].toInt() and 255
                    val b = rgba[p + 2].toInt() and 255
                    val yy = ((66 * r + 129 * g + 25 * b + 128) shr 8) + 16
                    y.put(row * yRow + col * yPix, yy.coerceIn(0, 255).toByte())
                    if (row % 2 == 0 && col % 2 == 0) {
                        val uu = ((-38 * r - 74 * g + 112 * b + 128) shr 8) + 128
                        val vv = ((112 * r - 94 * g - 18 * b + 128) shr 8) + 128
                        u.put((row / 2) * uRow + (col / 2) * uPix, uu.coerceIn(0, 255).toByte())
                        v.put((row / 2) * vRow + (col / 2) * vPix, vv.coerceIn(0, 255).toByte())
                    }
                }
            }
        }

        private fun drain(end: Boolean) {
            while (true) {
                val o = codec.dequeueOutputBuffer(info, if (end) 10000 else 0)
                if (o == MediaCodec.INFO_TRY_AGAIN_LATER) {
                    if (!end) return
                    continue
                }
                if (o == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    videoTrack = muxer.addTrack(codec.outputFormat)
                    val af = audioFormat
                    val audioTrack = if (af != null) muxer.addTrack(af) else -1
                    muxer.start()
                    started = true
                    audioSamples?.let { s -> for (a in s) muxer.writeSampleData(audioTrack, ByteBuffer.wrap(a.data), a.info) }
                    for (p in pending) muxer.writeSampleData(videoTrack, ByteBuffer.wrap(p.data), p.info)
                    pending.clear()
                    continue
                }
                if (o < 0) continue
                if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0 && info.size > 0) {
                    val buf = codec.getOutputBuffer(o)!!
                    buf.position(info.offset)
                    buf.limit(info.offset + info.size)
                    if (started) {
                        muxer.writeSampleData(videoTrack, buf, info)
                    } else {
                        val data = ByteArray(info.size)
                        buf.get(data)
                        val copy = MediaCodec.BufferInfo()
                        copy.set(0, info.size, info.presentationTimeUs, info.flags)
                        pending.add(Sample(data, copy))
                    }
                }
                codec.releaseOutputBuffer(o, false)
                if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) return
            }
        }

        fun finish(): String {
            if (gl != null) {
                codec.signalEndOfInputStream()
            } else {
                val i = nextInput()
                codec.queueInputBuffer(i, 0, 0, pts(), MediaCodec.BUFFER_FLAG_END_OF_STREAM)
            }
            drain(true)
            gl?.release()
            codec.stop()
            codec.release()
            if (started) muxer.stop()
            muxer.release()
            return path
        }

        fun abort() {
            try { gl?.release() } catch (e: Throwable) {}
            try { codec.stop() } catch (e: Throwable) {}
            codec.release()
            try { if (started) muxer.stop() } catch (e: Throwable) {}
            muxer.release()
            File(path).delete()
        }
    }

    /**
     * The encoder's input surface as an OpenGL ES target: each frame is
     * uploaded as a texture and drawn over the whole surface; the encoder
     * turns it into YUV on the GPU. Calls may come on any worker thread -
     * the context is made current for each and let go after.
     */
    private class GlInput(private val surface: Surface, private val width: Int, private val height: Int) {
        private val display: EGLDisplay = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        private val context: EGLContext
        private val eglSurface: EGLSurface
        private var program = 0
        private var texture = 0
        private val pixels: ByteBuffer = ByteBuffer.allocateDirect(width * height * 4)
        private val quad: java.nio.FloatBuffer

        init {
            val version = IntArray(2)
            check(EGL14.eglInitialize(display, version, 0, version, 1)) { "EGL" }
            val attribs = intArrayOf(
                EGL14.EGL_RED_SIZE, 8, EGL14.EGL_GREEN_SIZE, 8, EGL14.EGL_BLUE_SIZE, 8,
                EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
                0x3142, 1, // EGL_RECORDABLE_ANDROID
                EGL14.EGL_NONE,
            )
            val configs = arrayOfNulls<EGLConfig>(1)
            val n = IntArray(1)
            check(EGL14.eglChooseConfig(display, attribs, 0, configs, 0, 1, n, 0) && n[0] > 0) { "EGL config" }
            context = EGL14.eglCreateContext(
                display, configs[0], EGL14.EGL_NO_CONTEXT,
                intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE), 0,
            )
            check(context != EGL14.EGL_NO_CONTEXT) { "EGL context" }
            eglSurface = EGL14.eglCreateWindowSurface(display, configs[0], surface, intArrayOf(EGL14.EGL_NONE), 0)
            check(eglSurface != EGL14.EGL_NO_SURFACE) { "EGL surface" }
            // x, y, u, v: the picture's first row at the top.
            val v = floatArrayOf(-1f, -1f, 0f, 1f, 1f, -1f, 1f, 1f, -1f, 1f, 0f, 0f, 1f, 1f, 1f, 0f)
            quad = ByteBuffer.allocateDirect(v.size * 4).order(ByteOrder.nativeOrder()).asFloatBuffer()
            quad.put(v).position(0)
            current {
                program = link(
                    "attribute vec2 aPos; attribute vec2 aTex; varying vec2 vTex;" +
                        "void main() { gl_Position = vec4(aPos, 0.0, 1.0); vTex = aTex; }",
                    "precision mediump float; varying vec2 vTex; uniform sampler2D uTex;" +
                        "void main() { gl_FragColor = vec4(texture2D(uTex, vTex).rgb, 1.0); }",
                )
                val t = IntArray(1)
                GLES20.glGenTextures(1, t, 0)
                texture = t[0]
                GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, texture)
                GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_NEAREST)
                GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_NEAREST)
                GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
                GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
                GLES20.glTexImage2D(GLES20.GL_TEXTURE_2D, 0, GLES20.GL_RGBA, width, height, 0, GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, null)
                check(GLES20.glGetError() == GLES20.GL_NO_ERROR) { "GL setup" }
            }
        }

        private fun <T> current(block: () -> T): T = synchronized(this) {
            check(EGL14.eglMakeCurrent(display, eglSurface, eglSurface, context)) { "EGL current" }
            try {
                block()
            } finally {
                EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
            }
        }

        private fun shader(type: Int, src: String): Int {
            val s = GLES20.glCreateShader(type)
            GLES20.glShaderSource(s, src)
            GLES20.glCompileShader(s)
            val ok = IntArray(1)
            GLES20.glGetShaderiv(s, GLES20.GL_COMPILE_STATUS, ok, 0)
            check(ok[0] != 0) { GLES20.glGetShaderInfoLog(s) }
            return s
        }

        private fun link(vs: String, fs: String): Int {
            val p = GLES20.glCreateProgram()
            GLES20.glAttachShader(p, shader(GLES20.GL_VERTEX_SHADER, vs))
            GLES20.glAttachShader(p, shader(GLES20.GL_FRAGMENT_SHADER, fs))
            GLES20.glLinkProgram(p)
            val ok = IntArray(1)
            GLES20.glGetProgramiv(p, GLES20.GL_LINK_STATUS, ok, 0)
            check(ok[0] != 0) { GLES20.glGetProgramInfoLog(p) }
            return p
        }

        /** Draws `rgba` (null: the picture already there) at `ptsNs`. */
        fun draw(rgba: ByteArray?, ptsNs: Long) = current {
            GLES20.glViewport(0, 0, width, height)
            GLES20.glUseProgram(program)
            GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, texture)
            if (rgba != null) {
                pixels.position(0)
                pixels.put(rgba, 0, min(rgba.size, width * height * 4))
                pixels.position(0)
                GLES20.glPixelStorei(GLES20.GL_UNPACK_ALIGNMENT, 1)
                GLES20.glTexSubImage2D(GLES20.GL_TEXTURE_2D, 0, 0, 0, width, height, GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, pixels)
            }
            GLES20.glUniform1i(GLES20.glGetUniformLocation(program, "uTex"), 0)
            val aPos = GLES20.glGetAttribLocation(program, "aPos")
            val aTex = GLES20.glGetAttribLocation(program, "aTex")
            quad.position(0)
            GLES20.glVertexAttribPointer(aPos, 2, GLES20.GL_FLOAT, false, 16, quad)
            GLES20.glEnableVertexAttribArray(aPos)
            quad.position(2)
            GLES20.glVertexAttribPointer(aTex, 2, GLES20.GL_FLOAT, false, 16, quad)
            GLES20.glEnableVertexAttribArray(aTex)
            GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
            EGLExt.eglPresentationTimeANDROID(display, eglSurface, ptsNs)
            check(EGL14.eglSwapBuffers(display, eglSurface)) { "EGL swap" }
        }

        fun release() {
            try {
                EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
                EGL14.eglDestroySurface(display, eglSurface)
                EGL14.eglDestroyContext(display, context)
                // (no eglTerminate: the display is the whole app's.)
            } catch (e: Throwable) {}
            surface.release()
        }
    }
}
