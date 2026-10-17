package com.writingrecogniser

import android.app.Activity
import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Intent
import android.os.Bundle
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast

/**
 * The app's entry point. Runs in its own small process (":launcher"), which
 * doesn't start Flutter, ML Kit or any other library, so it keeps working
 * even if the main app crashes at start-up.
 *
 * If the main app crashed since last time, it shows what Android recorded
 * (Java crash, native crash, or app not responding) with a Copy button.
 * Otherwise it opens the main app straight away.
 */
class LaunchActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        val report = collectReport()
        // A normal-looking screen for the report; otherwise keep the splash.
        if (report != null) setTheme(android.R.style.Theme_DeviceDefault_DayNight)
        super.onCreate(savedInstanceState)
        when {
            report != null -> showReport(report)
            intent.getBooleanExtra(AFTER_RESTORE, false) -> openAfterRestore(0)
            else -> openApp()
        }
    }

    /** After "Restart the app now" (restoring a backup): opens the app once
     * its old process has gone, so the backup is put in place first. */
    private fun openAfterRestore(tries: Int) {
        val running = try {
            getSystemService(ActivityManager::class.java).runningAppProcesses
                ?.any { it.processName == packageName } ?: false
        } catch (_: Throwable) {
            false
        }
        if (!running || tries >= 20) openApp()
        else android.os.Handler(mainLooper).postDelayed({ openAfterRestore(tries + 1) }, 100)
    }

    private fun openApp() {
        startActivity(Intent(this, MainActivity::class.java))
        finish()
    }

    /** Crash details not yet shown, or null. */
    private fun collectReport(): String? {
        val parts = mutableListOf<String>()
        val prefs = getSharedPreferences("launch_diagnostics", MODE_PRIVATE)
        val lastSeen = prefs.getLong("lastSeenExit", 0L)
        var newest = lastSeen
        try {
            val am = getSystemService(ActivityManager::class.java)
            for (info in am.getHistoricalProcessExitReasons(packageName, 0, 10)) {
                if (info.timestamp <= lastSeen || info.processName != packageName) continue
                if (info.reason !in REPORTED) continue
                newest = maxOf(newest, info.timestamp)
                parts += describe(info)
            }
        } catch (t: Throwable) {
            parts += "Couldn't read Android's exit records: $t"
        }
        prefs.edit().putLong("lastSeenExit", newest).apply()

        val file = App.crashFile(this)
        if (file.exists()) {
            parts += file.readText()
            file.delete()
        }
        // Only a failure note with no actual crash isn't worth showing.
        if (parts.isEmpty() || parts.all { it.startsWith("Couldn't read") }) return null
        return "Writing Recogniser ${packageManager.getPackageInfo(packageName, 0).versionName}, " +
            "Android ${android.os.Build.VERSION.RELEASE}, " +
            "shown ${App.now()}\n\n" + parts.joinToString("\n\n----\n\n")
    }

    private fun describe(info: ApplicationExitInfo): String {
        val reason = when (info.reason) {
            ApplicationExitInfo.REASON_CRASH -> "Java/Kotlin crash"
            ApplicationExitInfo.REASON_CRASH_NATIVE -> "Native crash"
            ApplicationExitInfo.REASON_ANR -> "Not responding (ANR)"
            ApplicationExitInfo.REASON_INITIALIZATION_FAILURE -> "Failed to start"
            ApplicationExitInfo.REASON_SIGNALED -> "Killed by signal ${info.status}"
            ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE -> "Too much memory/CPU"
            else -> "Reason ${info.reason}"
        }
        val time = App.utc(info.timestamp)
        val sb = StringBuilder("$reason at $time\nDescription: ${info.description}\n" +
            "Memory: ${info.pss / 1024} MB, importance ${info.importance}\n")
        try {
            info.traceInputStream?.use { stream ->
                // Native crash records are binary; keep the readable parts
                // (library and function names in the backtrace).
                val bytes = stream.readBytes()
                sb.append("\nTrace:\n").append(readableText(bytes).take(15000))
            }
        } catch (t: Throwable) {
            sb.append("\n(No trace: $t)")
        }
        return sb.toString()
    }

    private fun readableText(bytes: ByteArray): String {
        val out = StringBuilder()
        val run = StringBuilder()
        fun flush() {
            if (run.length >= 4) out.append(run).append('\n')
            run.setLength(0)
        }
        for (b in bytes) {
            val c = b.toInt() and 0xFF
            if (c == 10 || c in 32..126) run.append(c.toChar()) else flush()
        }
        flush()
        return out.toString()
    }

    private fun showReport(report: String) {
        val pad = (16 * resources.displayMetrics.density).toInt()
        val title = TextView(this).apply {
            text = "The app closed unexpectedly last time"
            textSize = 22f
            setPadding(0, 0, 0, pad / 2)
        }
        val hint = TextView(this).apply {
            text = "Please tap Copy details and paste them to Claude in your private chat (not on GitHub) so the problem can be fixed."
            textSize = 16f
            setPadding(0, 0, 0, pad / 2)
        }
        val copy = Button(this).apply {
            text = "Copy details"
            setOnClickListener {
                getSystemService(ClipboardManager::class.java)
                    .setPrimaryClip(ClipData.newPlainText("Crash details", report))
                Toast.makeText(this@LaunchActivity, "Copied", Toast.LENGTH_SHORT).show()
            }
        }
        val open = Button(this).apply {
            text = "Open the app anyway"
            setOnClickListener { openApp() }
        }
        val details = TextView(this).apply {
            text = report
            textSize = 12f
            setTextIsSelectable(true)
            setPadding(0, pad / 2, 0, 0)
        }
        val column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(pad, pad * 2, pad, pad)
            addView(title)
            addView(hint)
            addView(copy)
            addView(open)
            addView(details)
        }
        setContentView(ScrollView(this).apply {
            fitsSystemWindows = true
            addView(column)
        })
    }

    companion object {
        /** Opened by "Restart the app now" after restoring a backup. */
        const val AFTER_RESTORE = "afterRestore"

        private val REPORTED = setOf(
            ApplicationExitInfo.REASON_CRASH,
            ApplicationExitInfo.REASON_CRASH_NATIVE,
            ApplicationExitInfo.REASON_ANR,
            ApplicationExitInfo.REASON_INITIALIZATION_FAILURE,
            ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE,
        )
    }
}
