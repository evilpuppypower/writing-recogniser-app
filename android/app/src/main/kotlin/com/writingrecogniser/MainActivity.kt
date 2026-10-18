package com.writingrecogniser

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.PowerManager
import android.view.InputDevice
import android.view.MotionEvent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private lateinit var pdfImporter: PdfImporter
    private lateinit var fileTransfer: FileTransfer
    private lateinit var backup: BackupChannel
    private var powerReceiver: BroadcastReceiver? = null

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        // Every pen sample, as the pen reports it (owner, 2026-10-18: record
        // the strokes in full). Android otherwise gathers pen movement into
        // one event per screen refresh, and only its last point reaches the
        // app; this sends each sample on its own. Fingers are unchanged.
        // Asked once the window is there, so the request reaches it.
        window.decorView.requestUnbufferedDispatch(InputDevice.SOURCE_STYLUS)
    }

    /**
     * Every pen sample reaches the app, even when Android has gathered
     * several into one event (owner, 2026-10-18: parts of an "o" turned
     * into straight lines). Flutter reads only the newest point of a
     * gathered event, so a busy moment lost the curve in between; each
     * gathered sample is handed on as its own event, with its own time,
     * place and pressure, before the newest one.
     */
    override fun dispatchTouchEvent(ev: MotionEvent): Boolean {
        if (ev.actionMasked != MotionEvent.ACTION_MOVE ||
            ev.historySize == 0 ||
            !ev.isFromSource(InputDevice.SOURCE_STYLUS)
        ) {
            return super.dispatchTouchEvent(ev)
        }
        val n = ev.pointerCount
        val props = Array(n) { i -> MotionEvent.PointerProperties().also { ev.getPointerProperties(i, it) } }
        var handled = false
        for (h in 0..ev.historySize) {
            val newest = h == ev.historySize
            val coords = Array(n) { i ->
                MotionEvent.PointerCoords().also {
                    if (newest) ev.getPointerCoords(i, it) else ev.getHistoricalPointerCoords(i, h, it)
                }
            }
            val one = MotionEvent.obtain(
                ev.downTime,
                if (newest) ev.eventTime else ev.getHistoricalEventTime(h),
                MotionEvent.ACTION_MOVE,
                n,
                props,
                coords,
                ev.metaState,
                ev.buttonState,
                ev.xPrecision,
                ev.yPrecision,
                ev.deviceId,
                ev.edgeFlags,
                ev.source,
                ev.flags,
            )
            try {
                handled = super.dispatchTouchEvent(one) || handled
            } finally {
                one.recycle()
            }
        }
        return handled
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        pdfImporter = PdfImporter(this, messenger)
        MyScriptOffline(applicationContext, messenger)
        fileTransfer = FileTransfer(this, messenger)
        SecretBox(messenger)
        backup = BackupChannel(this, messenger)
        OcrEngine(applicationContext, messenger)
        // Android's battery saver, for the app's own (owner, 2026-10-17).
        val power = MethodChannel(messenger, "writing_recogniser/power")
        val pm = getSystemService(PowerManager::class.java)
        power.setMethodCallHandler { call, result ->
            if (call.method == "powerSave") result.success(pm.isPowerSaveMode) else result.notImplemented()
        }
        powerReceiver?.let { unregisterReceiver(it) }
        powerReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                power.invokeMethod("powerSaveChanged", pm.isPowerSaveMode)
            }
        }.also {
            registerReceiver(it, IntentFilter(PowerManager.ACTION_POWER_SAVE_MODE_CHANGED), Context.RECEIVER_NOT_EXPORTED)
        }
        // The system "Material You" accent colour (from the wallpaper/theme),
        // so the app can match the tablet's colours.
        MethodChannel(messenger, "writing_recogniser/system").setMethodCallHandler { call, result ->
            when (call.method) {
                "accentColor" -> result.success(
                    getColor(android.R.color.system_accent1_500).toLong() and 0xFFFFFFFFL
                )
                // Details of the last crash, if the app crashed last time.
                "lastCrash" -> {
                    val f = App.crashFile(application)
                    result.success(if (f.exists()) f.readText() else null)
                }
                "clearLastCrash" -> {
                    App.crashFile(application).delete()
                    result.success(null)
                }
                "mlKitStartError" -> result.success(App.mlKitStartError)
                // The screen's refresh rate now and the rates it can run at,
                // and Android's battery saver (diagnostics: measured before
                // choosing a refresh rate, owner 2026-10-18).
                "display" -> {
                    val d = display
                    result.success(
                        mapOf(
                            "hz" to d?.refreshRate?.toDouble(),
                            "modes" to d?.supportedModes?.map { it.refreshRate.toDouble() }?.distinct()?.sorted(),
                            "powerSave" to pm.isPowerSaveMode,
                        ),
                    )
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        powerReceiver?.let {
            try {
                unregisterReceiver(it)
            } catch (_: Exception) {}
        }
        powerReceiver = null
        super.onDestroy()
    }

    @Deprecated("Uses the Activity result API that FlutterActivity supports.")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        val handled = (::pdfImporter.isInitialized &&
            pdfImporter.onActivityResult(requestCode, resultCode, data)) ||
            (::fileTransfer.isInitialized &&
                fileTransfer.onActivityResult(requestCode, resultCode, data)) ||
            (::backup.isInitialized &&
                backup.onActivityResult(requestCode, resultCode, data))
        if (!handled) {
            @Suppress("DEPRECATION")
            super.onActivityResult(requestCode, resultCode, data)
        }
    }
}
