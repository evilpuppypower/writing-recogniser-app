package com.writingrecogniser

import android.app.Activity
import android.graphics.BlendMode
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.PixelFormat
import android.graphics.RectF
import android.os.SystemClock
import android.view.MotionEvent
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.ViewGroup
import androidx.graphics.lowlatency.CanvasFrontBufferedRenderer
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * The line under the pen, drawn straight to the screen (owner, 2026-10-18:
 * lag between the pen and the ink; androidx.graphics approved). Flutter
 * draws a frame or two behind the pen; this draws each pen sample as it
 * arrives, on a see-through layer over the app, using a front buffer
 * (androidx.graphics CanvasFrontBufferedRenderer).
 *
 * The app still decides what the pen is doing: it says "start" when a pen
 * stroke begins (with its colour, width and the page's edges), "cancel"
 * when the stroke turns out not to be ink (straightened, a shape, the
 * eraser, a tap on a label), and "release" once it has drawn the stroke
 * itself, which removes it here. Nothing is saved here. Any failure turns
 * this off and the app's own drawing carries on as before.
 */
class WetInk(private val activity: Activity, messenger: BinaryMessenger) {
    private class Style(
        val color: Int,
        val unitPx: Float, // line width at normal pressure, in pixels
        val spread: Float, // how far pressure changes the width (see PressureResponse)
        val thinnest: Float,
        val clip: RectF, // the page, in this layer's pixels
    ) {
        fun width(pressure: Float): Float {
            val d = 2 * (pressure.coerceIn(0f, 1f) - 0.5f)
            val f = if (d >= 0) 1 + spread * d else 1 + minOf(spread, 1 - thinnest) * d
            return maxOf(unitPx * f, 0.5f)
        }
    }

    /** Points of one stroke, as drawn: x, y (layer pixels), pressure. */
    private class Points(val xs: FloatArray, val ys: FloatArray, val ps: FloatArray, val n: Int)

    /** A drawn stroke waiting for the app to show it. */
    private class Shown(val downTime: Long, val style: Style, val points: Points)

    /** The new part of the stroke being written (with the point before it). */
    private class Part(val style: Style, val points: Points, val eventTime: Long)

    private class Stroke(val downTime: Long, val pointerId: Int) {
        var xs = FloatArray(256)
        var ys = FloatArray(256)
        var ps = FloatArray(256)
        var n = 0
        var drawn = 0 // points already sent to the screen
        var style: Style? = null
        var lastTime = 0L

        fun add(x: Float, y: Float, p: Float, t: Long) {
            if (n == xs.size) {
                xs = xs.copyOf(n * 2)
                ys = ys.copyOf(n * 2)
                ps = ps.copyOf(n * 2)
            }
            xs[n] = x
            ys[n] = y
            ps[n] = p
            n++
            lastTime = t
        }

        fun points(from: Int = 0) = Points(
            xs.copyOfRange(from, n), ys.copyOfRange(from, n), ps.copyOfRange(from, n), n - from,
        )
    }

    private val main = android.os.Handler(android.os.Looper.getMainLooper())
    private var enabled = false
    private var failed = false
    private var surface: SurfaceView? = null
    private var renderer: CanvasFrontBufferedRenderer<Part>? = null
    private var current: Stroke? = null

    /** Strokes drawn here that the app hasn't shown yet (main thread). */
    private val shown = ArrayList<Shown>()

    /** What the lasting layer draws (read on the drawing thread). */
    @Volatile private var scene: List<Shown> = emptyList()

    /** Where this layer is in the window, in pixels (pen events are). */
    @Volatile private var originX = 0f
    @Volatile private var originY = 0f

    /** The layer's surface is ready to draw on (main thread). */
    private var ready = false

    /** When the pen was last near or on the screen (uptime ms). */
    private var lastPen = 0L

    private val latencies = ArrayList<Long>()
    private var started = 0
    private var wakes = 0
    private var missed = 0
    private var cancelled = 0
    private var problem: String? = null

    init {
        MethodChannel(messenger, "writing_recogniser/wet_ink").setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "enable" -> {
                        enable()
                        result.success(enabled && !failed)
                    }
                    "disable" -> {
                        disable()
                        result.success(null)
                    }
                    "start" -> {
                        start(call.argument<Number>("downMicros")!!.toLong(), call.argument<Map<String, Any?>>("style")!!)
                        result.success(null)
                    }
                    "cancel" -> {
                        cancel(call.argument<Number>("downMicros")!!.toLong())
                        result.success(null)
                    }
                    "release" -> {
                        release(call.argument<Number>("downMicros")!!.toLong())
                        result.success(null)
                    }
                    "stats" -> result.success(stats())
                    else -> result.notImplemented()
                }
            } catch (e: Throwable) {
                fail(e)
                result.success(null)
            }
        }
    }

    private fun fail(e: Throwable) {
        problem = (e.message ?: e.javaClass.simpleName).take(120)
        failed = true
        disable()
    }

    private fun enable() {
        if (failed || enabled) return
        enabled = true
        lastPen = SystemClock.uptimeMillis()
        wake()
    }

    /**
     * Puts the layer over the app. It's taken away again when the pen has
     * been away for a while ([sleep]): an idle see-through layer over the
     * whole screen still costs battery, as the screen is put together with
     * it on every frame (owner, 2026-10-22).
     */
    private fun wake() {
        if (failed || !enabled || surface != null) return
        val flutterView = activity.findViewById<View>(FlutterActivity.FLUTTER_VIEW_ID)
        val parent = flutterView?.parent as? ViewGroup ?: return
        val view = SurfaceView(activity).apply {
            setZOrderMediaOverlay(true) // over the app's own drawing
            holder.setFormat(PixelFormat.TRANSLUCENT)
            isClickable = false
            isFocusable = false
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
        }
        // Exactly over the app's view, so the app's positions are ours.
        parent.addView(
            view,
            parent.indexOfChild(flutterView) + 1,
            ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT),
        )
        view.addOnLayoutChangeListener { v, _, _, _, _, _, _, _, _ ->
            val at = IntArray(2)
            v.getLocationInWindow(at)
            originX = at[0].toFloat()
            originY = at[1].toFloat()
        }
        surface = view
        renderer = CanvasFrontBufferedRenderer(view, callback)
        // Added after the renderer's own, so it's set up first. Strokes
        // that start before this are drawn by the app alone.
        view.holder.addCallback(object : SurfaceHolder.Callback {
            override fun surfaceCreated(holder: SurfaceHolder) {}

            override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
                if (surface === view) ready = width > 0 && height > 0
            }

            override fun surfaceDestroyed(holder: SurfaceHolder) {
                if (surface === view) ready = false
            }
        })
        wakes++
        main.removeCallbacks(sleepCheck)
        main.postDelayed(sleepCheck, IDLE_MS)
    }

    /** Takes the layer away once the pen has been away [IDLE_MS] and
     * nothing is left on it; it comes back when the pen comes near. */
    private val sleepCheck = object : Runnable {
        override fun run() {
            if (surface == null) return
            val idle = SystemClock.uptimeMillis() - lastPen
            if (idle >= IDLE_MS && current == null && shown.isEmpty()) {
                removeLayer()
            } else {
                main.postDelayed(this, maxOf(IDLE_MS - idle, 500L))
            }
        }
    }

    /** The activity is going: the layer and its drawing thread go too. */
    fun close() = disable()

    private fun disable() {
        enabled = false
        current = null
        shown.clear()
        scene = emptyList()
        removeLayer()
    }

    private fun removeLayer() {
        main.removeCallbacks(sleepCheck)
        ready = false
        try {
            renderer?.release(true)
        } catch (_: Throwable) {}
        renderer = null
        surface?.let { (it.parent as? ViewGroup)?.removeView(it) }
        surface = null
    }

    private fun draw(canvas: Canvas, style: Style, p: Points) {
        // Its own paint: the two layers may be drawn on different threads.
        val paint = Paint().apply {
            isAntiAlias = true
            this.style = Paint.Style.STROKE
            strokeCap = Paint.Cap.ROUND
            strokeJoin = Paint.Join.ROUND
        }
        canvas.save()
        canvas.clipRect(style.clip)
        paint.color = style.color
        if (p.n == 1) {
            paint.style = Paint.Style.FILL
            canvas.drawCircle(p.xs[0], p.ys[0], style.width(p.ps[0]) / 2, paint)
            paint.style = Paint.Style.STROKE
        }
        for (i in 1 until p.n) {
            paint.strokeWidth = style.width((p.ps[i - 1] + p.ps[i]) / 2)
            canvas.drawLine(p.xs[i - 1], p.ys[i - 1], p.xs[i], p.ys[i], paint)
        }
        canvas.restore()
    }

    private val callback = object : CanvasFrontBufferedRenderer.Callback<Part> {
        override fun onDrawFrontBufferedLayer(canvas: Canvas, bufferWidth: Int, bufferHeight: Int, param: Part) {
            draw(canvas, param.style, param.points)
            val lag = SystemClock.uptimeMillis() - param.eventTime
            synchronized(latencies) {
                if (latencies.size < 20000) latencies.add(lag)
            }
        }

        override fun onDrawMultiBufferedLayer(
            canvas: Canvas,
            bufferWidth: Int,
            bufferHeight: Int,
            params: Collection<Part>,
        ) {
            canvas.drawColor(Color.TRANSPARENT, BlendMode.CLEAR)
            for (s in scene) draw(canvas, s.style, s.points)
        }
    }

    /** Every pen event, before the app sees it (MainActivity). */
    fun onTouch(ev: MotionEvent) {
        if (!enabled || failed) return
        try {
            penNear(ev)
            handle(ev)
        } catch (e: Throwable) {
            fail(e)
        }
    }

    /** Pen hover events (MainActivity): the layer is got ready before the
     * pen touches. */
    fun onHover(ev: MotionEvent) {
        if (!enabled || failed) return
        try {
            penNear(ev)
        } catch (e: Throwable) {
            fail(e)
        }
    }

    private fun penNear(ev: MotionEvent) {
        if ((0 until ev.pointerCount).none { isPen(ev, it) }) return
        lastPen = SystemClock.uptimeMillis()
        wake()
    }

    private fun isPen(ev: MotionEvent, i: Int) = ev.getToolType(i) == MotionEvent.TOOL_TYPE_STYLUS

    /** The eraser end, or a pen button held (the app erases then). */
    private fun erasing(ev: MotionEvent, i: Int) =
        ev.getToolType(i) == MotionEvent.TOOL_TYPE_ERASER ||
            ev.buttonState and (MotionEvent.BUTTON_STYLUS_PRIMARY or MotionEvent.BUTTON_STYLUS_SECONDARY) != 0

    private fun handle(ev: MotionEvent) {
        when (ev.actionMasked) {
            MotionEvent.ACTION_DOWN, MotionEvent.ACTION_POINTER_DOWN -> {
                val i = ev.actionIndex
                if (!isPen(ev, i) || erasing(ev, i)) return
                if (!ready) {
                    // The layer is still being got ready: the app draws
                    // this stroke on its own.
                    missed++
                    return
                }
                // Identified by this event's time: the app uses the same
                // time for the stroke.
                val s = Stroke(ev.eventTime, ev.getPointerId(i))
                current = s
                s.add(ev.getX(i) - originX, ev.getY(i) - originY, ev.getPressure(i), ev.eventTime)
            }
            MotionEvent.ACTION_MOVE -> {
                val s = current ?: return
                val i = ev.findPointerIndex(s.pointerId)
                if (i < 0) return
                if (erasing(ev, i)) {
                    abandon()
                    return
                }
                for (h in 0 until ev.historySize) {
                    s.add(
                        ev.getHistoricalX(i, h) - originX,
                        ev.getHistoricalY(i, h) - originY,
                        ev.getHistoricalPressure(i, h),
                        ev.getHistoricalEventTime(h),
                    )
                }
                s.add(ev.getX(i) - originX, ev.getY(i) - originY, ev.getPressure(i), ev.eventTime)
                show(s)
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_POINTER_UP -> {
                val s = current ?: return
                val i = ev.actionIndex
                if (ev.getPointerId(i) != s.pointerId) return
                s.add(ev.getX(i) - originX, ev.getY(i) - originY, ev.getPressure(i), ev.eventTime)
                show(s)
                finish(s)
            }
            MotionEvent.ACTION_CANCEL -> abandon()
        }
    }

    /** Draws the points not drawn yet, once the app has said it's ink. */
    private fun show(s: Stroke) {
        val style = s.style ?: return
        val r = renderer ?: return
        if (s.n <= s.drawn) return
        val from = maxOf(s.drawn - 1, 0) // joined to the point before
        r.renderFrontBufferedLayer(Part(style, s.points(from), s.lastTime))
        s.drawn = s.n
    }

    /** The pen lifted: the stroke stays until the app has drawn it. */
    private fun finish(s: Stroke) {
        current = null
        val style = s.style ?: return
        shown.add(Shown(s.downTime, style, s.points()))
        scene = shown.toList()
        renderer?.commit()
        // The app releases it within a few frames; if it never does (the
        // page went away meanwhile), it still goes.
        main.postDelayed({ releaseMs(s.downTime) }, 3000)
    }

    private fun abandon() {
        val s = current ?: return
        current = null
        if (s.style != null) {
            renderer?.cancel()
            redraw()
        }
    }

    /**
     * Draws the lasting layer again: the strokes waiting for the app, and
     * the one being written (in case redrawing clears the front layer).
     */
    private fun redraw() {
        val s = current
        val style = s?.style
        scene = if (s != null && style != null) shown + Shown(s.downTime, style, s.points()) else shown.toList()
        renderer?.renderMultiBufferedLayer(emptyList())
    }

    private fun matches(s: Stroke?, downMicros: Long) =
        s != null && kotlin.math.abs(s.downTime - downMicros / 1000) <= 1

    private fun start(downMicros: Long, m: Map<String, Any?>) {
        val s = current
        if (!enabled || !matches(s, downMicros) || s!!.style != null) return
        val dpr = (m["dpr"] as Number).toFloat()
        val clip = (m["clip"] as List<*>).map { (it as Number).toFloat() * dpr }
        s.style = Style(
            color = (m["color"] as Number).toLong().toInt(),
            unitPx = (m["unitPx"] as Number).toFloat(),
            spread = (m["spread"] as Number).toFloat(),
            thinnest = (m["thinnest"] as Number).toFloat(),
            clip = RectF(clip[0], clip[1], clip[2], clip[3]),
        )
        started++
        show(s)
    }

    private fun cancel(downMicros: Long) {
        val s = current
        if (matches(s, downMicros)) {
            if (s!!.style != null) cancelled++
            abandon()
            return
        }
        release(downMicros)
    }

    private fun release(downMicros: Long) = releaseMs(downMicros / 1000)

    private fun releaseMs(downMs: Long) {
        val removed = shown.removeAll { kotlin.math.abs(it.downTime - downMs) <= 1 }
        if (!removed || !enabled) return
        redraw()
    }

    private fun stats(): Map<String, Any?> {
        val lags = synchronized(latencies) {
            val copy = latencies.sorted()
            latencies.clear()
            copy
        }
        val out = mutableMapOf<String, Any?>(
            "wetOn" to (enabled && !failed),
            "wetStrokes" to started,
            "wetCancelled" to cancelled,
            "wetWakes" to wakes,
            "wetMissed" to missed,
        )
        if (lags.isNotEmpty()) {
            out["wetMedianMs"] = lags[lags.size / 2]
            out["wetP90Ms"] = lags[((lags.size - 1) * 9) / 10]
        }
        problem?.let { out["wetProblem"] = it }
        started = 0
        cancelled = 0
        wakes = 0
        missed = 0
        return out
    }

    private companion object {
        /** How long the pen is away before the layer is taken away. */
        const val IDLE_MS = 5000L
    }
}
