package com.writingrecogniser

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.nio.FloatBuffer
import java.security.MessageDigest
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Reading scanned PDFs (owner, 2026-10-17: PaddleOCR, models downloaded
 * when the user taps, checked by fingerprint). The models run here, on the
 * tablet, with ONNX Runtime; nothing about a page is sent anywhere. The
 * only network use is downloading a model the user chose (approved by the
 * owner), from the address the app lists for it.
 *
 * ONNX Runtime is started only when a page is first read, so the app
 * opens as before (and on the emulator CI checks it with).
 *
 * Channel "writing_recogniser/ocr":
 *  - installed -> list of model ids downloaded
 *  - download {id, files: [{name, url, sha256?}]} -> {name: sha256};
 *    "progress" {done, total} calls while it runs. A file whose
 *    fingerprint doesn't match is deleted and the download fails.
 *  - cancel: stops a download
 *  - remove {id}
 *  - read {id, width, height, pixels (RGBA bytes)} -> list of
 *    {left, top, right, bottom, text, confidence}, in the image's pixels
 */
class OcrEngine(private val context: Context, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "writing_recogniser/ocr")
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val stop = AtomicBoolean(false)

    // Kept while the app runs once loaded (loading a model takes a moment).
    private var loaded: String? = null
    private var det: OrtSession? = null
    private var rec: OrtSession? = null
    private var alphabet: List<String> = emptyList()

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "installed" -> work(result) { installed() }
                "download" -> {
                    val id = call.argument<String>("id")!!
                    val files = call.argument<List<Map<String, String?>>>("files")!!
                    stop.set(false)
                    work(result) { download(id, files) }
                }
                "cancel" -> {
                    stop.set(true)
                    result.success(null)
                }
                "remove" -> {
                    val id = call.argument<String>("id")!!
                    work(result) {
                        if (loaded == id) unload()
                        modelDir(id).deleteRecursively()
                        null
                    }
                }
                "read" -> {
                    val id = call.argument<String>("id")!!
                    val w = call.argument<Int>("width")!!
                    val h = call.argument<Int>("height")!!
                    val rgba = call.argument<ByteArray>("pixels")!!
                    work(result) { read(id, w, h, rgba) }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun work(result: MethodChannel.Result, job: () -> Any?) {
        worker.execute {
            try {
                val value = job()
                main.post { result.success(value) }
            } catch (e: Throwable) {
                main.post { result.error("ocr", e.message ?: e.javaClass.simpleName, null) }
            }
        }
    }

    private fun root() = File(context.filesDir, "ocr").apply { mkdirs() }

    /** Only simple names: a model's files stay in its own folder. */
    private fun safe(name: String): String {
        require(name.matches(Regex("[A-Za-z0-9._-]{1,64}")) && name != "." && name != "..") { "Bad name" }
        return name
    }

    private fun modelDir(id: String) = File(root(), safe(id))

    private fun installed(): List<String> =
        root().listFiles()?.filter { File(it, READY).isFile }?.map { it.name }?.sorted() ?: emptyList()

    private fun download(id: String, files: List<Map<String, String?>>): Map<String, String> {
        val dir = modelDir(id)
        val partial = File(root(), "$id.partial").apply { deleteRecursively(); mkdirs() }
        val sums = mutableMapOf<String, String>()
        try {
            // Total size first, for the progress bar (when servers say).
            val sizes = files.map { f -> head(f["url"]!!) }
            val total = if (sizes.all { it > 0 }) sizes.sum() else -1L
            var done = 0L
            var lastSent = 0L
            for (f in files) {
                val name = safe(f["name"]!!)
                val url = URL(f["url"]!!)
                require(url.protocol == "https") { "Downloads only over https" }
                val target = File(partial, name)
                val sha = MessageDigest.getInstance("SHA-256")
                val conn = (url.openConnection() as HttpURLConnection).apply {
                    connectTimeout = 20_000
                    readTimeout = 60_000
                    instanceFollowRedirects = true
                }
                try {
                    if (conn.responseCode !in 200..299) throw java.io.IOException("The server said ${conn.responseCode}")
                    conn.inputStream.use { input ->
                        target.outputStream().use { out ->
                            val buf = ByteArray(1 shl 16)
                            while (true) {
                                if (stop.get()) throw java.io.IOException("stopped")
                                val n = input.read(buf)
                                if (n < 0) break
                                out.write(buf, 0, n)
                                sha.update(buf, 0, n)
                                done += n
                                val now = System.currentTimeMillis()
                                if (now - lastSent > 200) {
                                    lastSent = now
                                    val d = done
                                    main.post { channel.invokeMethod("progress", mapOf("done" to d, "total" to total)) }
                                }
                            }
                        }
                    }
                } finally {
                    conn.disconnect()
                }
                val got = BackupCrypto.toHex(sha.digest())
                val want = f["sha256"]
                if (!want.isNullOrBlank() && !want.equals(got, ignoreCase = true)) {
                    throw java.io.IOException("$name isn't the file expected (its fingerprint is different), so it wasn't kept")
                }
                sums[name] = got
            }
            File(partial, READY).writeText(sums.entries.joinToString("\n") { "${it.key}=${it.value}" })
            if (loaded == id) unload()
            dir.deleteRecursively()
            if (!partial.renameTo(dir)) throw java.io.IOException("Couldn't keep the model")
            return sums
        } finally {
            partial.deleteRecursively()
        }
    }

    /** The size the server gives for [url], or -1. */
    private fun head(url: String): Long = try {
        val conn = (URL(url).openConnection() as HttpURLConnection).apply {
            requestMethod = "HEAD"
            connectTimeout = 15_000
            instanceFollowRedirects = true
        }
        try {
            conn.contentLengthLong
        } finally {
            conn.disconnect()
        }
    } catch (e: Exception) {
        -1L
    }

    private fun unload() {
        det?.close()
        rec?.close()
        det = null
        rec = null
        loaded = null
    }

    private fun load(id: String) {
        if (loaded == id) return
        unload()
        val dir = modelDir(id)
        require(File(dir, READY).isFile) { "That model isn't downloaded" }
        val env = OrtEnvironment.getEnvironment()
        val options = OrtSession.SessionOptions().apply {
            // Half the cores at most, so the screen stays smooth.
            setIntraOpNumThreads(maxOf(1, Runtime.getRuntime().availableProcessors() / 2))
        }
        det = env.createSession(File(dir, "det.onnx").path, options)
        rec = env.createSession(File(dir, "rec.onnx").path, options)
        alphabet = OcrMath.alphabet(File(dir, "dict.txt").readText())
        loaded = id
    }

    private fun read(id: String, w: Int, h: Int, rgba: ByteArray): List<Map<String, Any>> {
        load(id)
        val env = OrtEnvironment.getEnvironment()
        val argb = IntArray(w * h)
        for (i in 0 until w * h) {
            val r = rgba[i * 4].toInt() and 0xff
            val g = rgba[i * 4 + 1].toInt() and 0xff
            val b = rgba[i * 4 + 2].toInt() and 0xff
            argb[i] = (0xff shl 24) or (r shl 16) or (g shl 8) or b
        }
        // Finding the text.
        val input = OcrMath.detectionInput(argb, w, h, DET_MAX_SIDE)
        val shape = longArrayOf(1, 3, input.height.toLong(), input.width.toLong())
        val prob = OnnxTensor.createTensor(env, FloatBuffer.wrap(input.data), shape).use { t ->
            det!!.run(mapOf(det!!.inputNames.first() to t)).use { out ->
                val v = out[0] as OnnxTensor
                val fb = v.floatBuffer
                FloatArray(fb.remaining()).also { fb.get(it) }
            }
        }
        val lines = OcrMath.detectionBoxes(prob, input.width, input.height, w, h, 0.3f, 0.6f)
        // Reading each line.
        for (line in lines) {
            val ri = OcrMath.recognitionInput(argb, w, h, line, REC_HEIGHT, REC_MAX_WIDTH)
            val rs = longArrayOf(1, 3, ri.height.toLong(), ri.width.toLong())
            OnnxTensor.createTensor(env, FloatBuffer.wrap(ri.data), rs).use { t ->
                rec!!.run(mapOf(rec!!.inputNames.first() to t)).use { out ->
                    val v = out[0] as OnnxTensor
                    val dims = v.info.shape // [1, steps, classes]
                    val fb = v.floatBuffer
                    val probs = FloatArray(fb.remaining()).also { fb.get(it) }
                    OcrMath.decode(probs, dims[1].toInt(), dims[2].toInt(), alphabet, line)
                }
            }
        }
        return lines.filter { it.text.isNotBlank() }.map {
            mapOf(
                "left" to it.left,
                "top" to it.top,
                "right" to it.right,
                "bottom" to it.bottom,
                "text" to it.text,
                "confidence" to it.confidence.toDouble(),
            )
        }
    }

    private companion object {
        const val READY = "ready"
        const val DET_MAX_SIDE = 960
        const val REC_HEIGHT = 48
        const val REC_MAX_WIDTH = 960
    }
}
