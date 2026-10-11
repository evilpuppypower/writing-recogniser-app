package com.writingrecogniser

import android.app.Application
import android.content.Context
import java.io.File
import java.io.PrintWriter
import java.io.StringWriter
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Starts things that could otherwise crash the app before it appears:
 *  - records any crash to a file as early as possible (before other
 *    libraries start), so [LaunchActivity] can show the details next time
 *    (the owner can't read the tablet's system logs);
 *  - starts Google ML Kit inside a try/catch. ML Kit normally starts itself
 *    at launch (its "MlKitInitProvider"); that is switched off in
 *    AndroidManifest.xml so a failure there can't stop the app opening.
 *
 * Runs in both processes: the main one (Flutter) and ":launcher"
 * ([LaunchActivity]); ML Kit is only started in the main one.
 */
class App : Application() {
    override fun attachBaseContext(base: Context) {
        super.attachBaseContext(base)
        installCrashRecorder()
    }

    override fun onCreate() {
        super.onCreate()
        if (Application.getProcessName() != packageName) return
        mlKitStartError = try {
            Class.forName("com.google.mlkit.common.sdkinternal.MlKitContext")
                .getMethod("initializeIfNeeded", Context::class.java)
                .invoke(null, this)
            null
        } catch (t: Throwable) {
            val cause = (t as? java.lang.reflect.InvocationTargetException)?.targetException ?: t
            "$cause"
        }
    }

    private fun installCrashRecorder() {
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, error ->
            try {
                val trace = StringWriter().also { error.printStackTrace(PrintWriter(it)) }
                crashFile(this).writeText(
                    "Crash at ${now()} on thread ${thread.name}\n" +
                        "Android ${android.os.Build.VERSION.RELEASE}\n\n" +
                        trace.toString().take(20000)
                )
            } catch (_: Throwable) {
                // Never let the recorder itself get in the way.
            }
            previous?.uncaughtException(thread, error)
        }
    }

    companion object {
        /** Why ML Kit couldn't start, or null if it started fine. */
        var mlKitStartError: String? = null

        fun crashFile(context: Context) = File(context.filesDir, "last_crash.txt")

        /** A time for crash details, in UTC: the details may be shared, and a
         *  local time would give away the user's time zone. */
        fun utc(millis: Long): String =
            SimpleDateFormat("yyyy-MM-dd HH:mm:ss 'UTC'", Locale.US)
                .apply { timeZone = java.util.TimeZone.getTimeZone("UTC") }
                .format(Date(millis))

        fun now(): String = utc(System.currentTimeMillis())
    }
}
