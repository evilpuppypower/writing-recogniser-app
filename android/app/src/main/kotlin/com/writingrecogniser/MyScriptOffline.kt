package com.writingrecogniser

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.myscript.iink.Engine
import com.myscript.iink.MimeType
import com.myscript.iink.Recognizer
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * MyScript iink offline engine (the "Recognizer" API, no MyScript UI).
 * Runs entirely on the tablet: no network, nothing leaves the device.
 *
 * Two things are added to the APK by CI, never committed to the repo:
 *  - the owner's certificate (com.myscript.certificate.MyCertificate, from the
 *    MYSCRIPT_CERTIFICATE_JAVA secret), loaded by reflection so the app still
 *    builds without it;
 *  - the English recognition files, under assets/myscript/{conf,resources}.
 *
 * Channel "writing_recogniser/myscript_offline":
 *  - status -> {state: ready|noCertificate|noAssets|error, message, lang,
 *    mmPerPxX, mmPerPxY}
 *  - recognize {strokes: [[x0,y0,t0,p0, x1,y1,t1,p1, ...], ...]} -> JIIX string
 *    (with each word's bounding box, in mm)
 *  - classify {strokes: same} -> JIIX string from MyScript's "Raw Content"
 *    recognizer, which sorts ink into text and drawings (task 2.2b); an
 *    error "no_classifier" if this build lacks its files.
 */
class MyScriptOffline(private val context: Context, messenger: BinaryMessenger) {
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    // Only touched on [worker].
    private var engine: Engine? = null
    private var recognizer: Recognizer? = null
    private var lang: String? = null
    private var setupError: Map<String, Any?>? = null
    private var rawRecognizer: Recognizer? = null
    private var rawProblem: String? = null
    private var scaleX = 1f
    private var scaleY = 1f

    init {
        MethodChannel(messenger, "writing_recogniser/myscript_offline")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "status" -> worker.execute {
                        val status = ensureReady() ?: mapOf(
                            "state" to "ready", "message" to "", "lang" to lang,
                            // Millimetres per point sent, so the app can
                            // match the words' boxes (mm) to its strokes.
                            "mmPerPxX" to scaleX.toDouble(), "mmPerPxY" to scaleY.toDouble(),
                        )
                        main.post { result.success(status) }
                    }
                    "recognize" -> {
                        val strokes = call.argument<List<List<Number>>>("strokes") ?: emptyList()
                        worker.execute {
                            try {
                                val problem = ensureReady()
                                if (problem != null) {
                                    main.post { result.error("not_ready", problem["message"] as String, null) }
                                } else {
                                    val jiix = recognize(strokes)
                                    main.post { result.success(jiix) }
                                }
                            } catch (e: Exception) {
                                main.post { result.error("failed", e.message ?: e.toString(), null) }
                            }
                        }
                    }
                    "classify" -> {
                        val strokes = call.argument<List<List<Number>>>("strokes") ?: emptyList()
                        worker.execute {
                            try {
                                val problem = ensureReady()
                                val raw = if (problem == null) ensureRaw() else null
                                if (raw == null) {
                                    val why = problem?.get("message") as String?
                                        ?: rawProblem ?: "unavailable"
                                    main.post { result.error("no_classifier", why, null) }
                                } else {
                                    val jiix = feed(raw, strokes)
                                    main.post { result.success(jiix) }
                                }
                            } catch (e: Exception) {
                                main.post { result.error("failed", e.message ?: e.toString(), null) }
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /** Sets up the engine once. Returns a status map if it can't be used. */
    private fun ensureReady(): Map<String, Any?>? {
        if (recognizer != null) return null
        setupError?.let { return it }

        val certificate = try {
            val cls = Class.forName("com.myscript.certificate.MyCertificate")
            cls.getMethod("getBytes").invoke(null) as ByteArray
        } catch (e: Exception) {
            null
        }
        if (certificate == null || certificate.isEmpty()) {
            return fail(
                "noCertificate",
                "This build doesn't include the MyScript certificate. Add the " +
                    "MYSCRIPT_CERTIFICATE_JAVA secret on GitHub, then use a newer build.",
            )
        }

        val confFiles = context.assets.list("myscript/conf")?.filter { it.endsWith(".conf") }
            ?: emptyList()
        // Prefer British spelling, then US.
        val chosen = listOf("en_GB", "en_US").firstOrNull { "$it.conf" in confFiles }
            ?: return fail(
                "noAssets",
                "This build doesn't include MyScript's English recognition files.",
            )

        return try {
            val e = Engine.create(certificate)
            val conf = e.configuration
            val confDir = "zip://" + context.packageCodePath + "!/assets/myscript/conf"
            conf.setStringArray("recognizer.configuration-manager.search-path", arrayOf(confDir))
            conf.setString("recognizer.lang", chosen)
            // Millimetres per Flutter logical pixel (an Android dp), from the
            // screen's real density so writing size is judged correctly.
            val dm = context.resources.displayMetrics
            scaleX = 25.4f * dm.density / dm.xdpi
            scaleY = 25.4f * dm.density / dm.ydpi
            // Each word's box in the answer, so a whole line can be read at
            // once and its words matched back to their strokes.
            conf.setBoolean("export.jiix.bounding-box", true)
            recognizer = e.createRecognizer(scaleX, scaleY, "Text")
            engine = e
            lang = chosen
            null
        } catch (e: Exception) {
            fail(
                "error",
                "MyScript couldn't start: ${e.message ?: e}. The certificate may " +
                    "not match the app ID com.writingrecogniser.",
            )
        }
    }

    private fun fail(state: String, message: String): Map<String, Any?> {
        val status = mapOf("state" to state, "message" to message, "lang" to null)
        setupError = status
        return status
    }

    /**
     * MyScript's writing/drawing sorter, set up on first use. Classifies
     * only (no text recognition) and exports each element's bounding box.
     */
    private fun ensureRaw(): Recognizer? {
        rawRecognizer?.let { return it }
        if (rawProblem != null) return null
        val e = engine ?: return null
        return try {
            val conf = e.configuration
            for (prefix in listOf("", "recognizer.")) {
                conf.setStringArray("${prefix}raw-content.classification.types", arrayOf("text", "drawing"))
                conf.setStringArray("${prefix}raw-content.recognition.types", arrayOf<String>())
            }
            conf.setBoolean("export.jiix.bounding-box", true)
            conf.setBoolean("export.jiix.strokes", false)
            conf.setBoolean("export.jiix.ranges", true)
            e.createRecognizer(scaleX, scaleY, "Raw Content").also { rawRecognizer = it }
        } catch (ex: Exception) {
            rawProblem = "MyScript's writing/drawing sorting isn't available: ${ex.message ?: ex}"
            null
        }
    }

    /** Each stroke is a flat list of x, y, t (ms), pressure, repeated. */
    private fun recognize(strokes: List<List<Number>>): String = feed(recognizer!!, strokes)

    private fun feed(r: Recognizer, strokes: List<List<Number>>): String {
        r.clear()
        r.waitForIdle()
        for (s in strokes) {
            val n = s.size / 4
            if (n == 0) continue
            for (i in 0 until n) {
                val x = s[i * 4].toFloat()
                val y = s[i * 4 + 1].toFloat()
                val t = s[i * 4 + 2].toLong()
                val p = s[i * 4 + 3].toFloat()
                when (i) {
                    0 -> r.pointerDown(x, y, t, p)
                    n - 1 -> r.pointerUp(x, y, t, p)
                    else -> r.pointerMove(x, y, t, p)
                }
            }
            // A one-point stroke (a dot) still needs a pen-up.
            if (n == 1) {
                r.pointerUp(s[0].toFloat(), s[1].toFloat(), s[2].toLong(), s[3].toFloat())
            }
        }
        r.waitForIdle()
        val jiix = r.getResult(MimeType.JIIX) ?: "{}"
        r.clear()
        return jiix
    }
}
