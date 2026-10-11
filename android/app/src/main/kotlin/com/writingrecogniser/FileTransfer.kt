package com.writingrecogniser

import android.app.Activity
import android.content.Intent
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * Lets the user save a file anywhere (Downloads, Drive, a USB stick, ...) or
 * pick one to open, through Android's own file picker. Used for sample
 * backups. Nothing is sent anywhere unless the user picks a cloud folder.
 *
 * Channel "writing_recogniser/files":
 *  - saveAs {name, mime, bytes} -> true when saved, false when cancelled
 *  - open {mimes} -> bytes, or null when cancelled
 */
class FileTransfer(private val activity: Activity, messenger: BinaryMessenger) {
    private val io = Executors.newSingleThreadExecutor()
    private var pendingSave: Pair<ByteArray, MethodChannel.Result>? = null
    private var pendingOpen: MethodChannel.Result? = null

    init {
        MethodChannel(messenger, "writing_recogniser/files").setMethodCallHandler { call, result ->
            when (call.method) {
                "saveAs" -> {
                    val bytes = call.argument<ByteArray>("bytes")
                    if (bytes == null || pendingSave != null) {
                        result.error("busy", "A save is already in progress", null)
                        return@setMethodCallHandler
                    }
                    pendingSave = bytes to result
                    val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = call.argument<String>("mime") ?: "application/octet-stream"
                        putExtra(Intent.EXTRA_TITLE, call.argument<String>("name") ?: "backup")
                    }
                    activity.startActivityForResult(intent, REQUEST_SAVE)
                }
                "open" -> {
                    if (pendingOpen != null) {
                        result.error("busy", "Already choosing a file", null)
                        return@setMethodCallHandler
                    }
                    pendingOpen = result
                    val mimes = call.argument<List<String>>("mimes") ?: listOf("*/*")
                    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = "*/*"
                        putExtra(Intent.EXTRA_MIME_TYPES, mimes.toTypedArray())
                    }
                    activity.startActivityForResult(intent, REQUEST_OPEN)
                }
                else -> result.notImplemented()
            }
        }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        val uri = if (resultCode == Activity.RESULT_OK) data?.data else null
        when (requestCode) {
            REQUEST_SAVE -> {
                val (bytes, result) = pendingSave ?: return true
                pendingSave = null
                if (uri == null) {
                    result.success(false)
                    return true
                }
                io.execute {
                    try {
                        activity.contentResolver.openOutputStream(uri, "wt")!!.use { it.write(bytes) }
                        activity.runOnUiThread { result.success(true) }
                    } catch (e: Exception) {
                        activity.runOnUiThread { result.error("write", e.message ?: "$e", null) }
                    }
                }
                return true
            }
            REQUEST_OPEN -> {
                val result = pendingOpen ?: return true
                pendingOpen = null
                if (uri == null) {
                    result.success(null)
                    return true
                }
                io.execute {
                    try {
                        val bytes = activity.contentResolver.openInputStream(uri)!!.use { readCapped(it) }
                        if (bytes == null) {
                            activity.runOnUiThread {
                                result.error("too_big", "Files over ${MAX_OPEN_BYTES / (1024 * 1024)} MB can't be opened.", null)
                            }
                        } else {
                            activity.runOnUiThread { result.success(bytes) }
                        }
                    } catch (e: Exception) {
                        activity.runOnUiThread { result.error("read", e.message ?: "$e", null) }
                    }
                }
                return true
            }
        }
        return false
    }

    /** The stream's bytes, or null if it's longer than [MAX_OPEN_BYTES]
     *  (so a huge or malicious file can't use up the app's memory). */
    private fun readCapped(input: java.io.InputStream): ByteArray? {
        val out = java.io.ByteArrayOutputStream()
        val buffer = ByteArray(64 * 1024)
        var total = 0L
        while (true) {
            val n = input.read(buffer)
            if (n < 0) break
            total += n
            if (total > MAX_OPEN_BYTES) return null
            out.write(buffer, 0, n)
        }
        return out.toByteArray()
    }

    companion object {
        /** Largest file the app opens this way (sample backups). */
        const val MAX_OPEN_BYTES = 200L * 1024 * 1024

        private const val REQUEST_SAVE = 4301
        private const val REQUEST_OPEN = 4302
    }
}
