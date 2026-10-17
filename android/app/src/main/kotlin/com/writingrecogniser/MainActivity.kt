package com.writingrecogniser

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.PowerManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private lateinit var pdfImporter: PdfImporter
    private lateinit var fileTransfer: FileTransfer
    private lateinit var backup: BackupChannel
    private var powerReceiver: BroadcastReceiver? = null

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
