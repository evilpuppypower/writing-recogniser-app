package com.writingrecogniser

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Lets the user pick a PDF with Android's system file picker and copies it
 * into the app's own cache, reporting progress so the UI can show a progress
 * bar and time remaining.
 *
 * The original file is only ever read, never modified. Copies are kept in
 * cache/imports so opening the same file again is instant; only the most
 * recent `keep` copies are kept (a user setting, default 3). Copies the user
 * pins live in cache/imports/pinned and are never removed automatically.
 *
 * Channel API (all paths/URIs are strings):
 *  - pick() -> {uri, name, size (-1 if unknown), modified, cacheId, cachedPath
 *    (null if not yet copied)} or null. Read permission for the file is kept
 *    so it can be reopened later from the Recent list.
 *  - inspect({uri}) -> the same details for a file picked earlier; fails with
 *    code "unavailable" if it was moved, deleted or access was lost.
 *  - releaseAccess({uri}) gives back the kept read access (when the file
 *    leaves the Recent list); Android limits how many an app may keep.
 *  - copy({uri, name, size, modified, keep}) -> path of the finished copy; progress events
 *    {copied, total} are sent on the progress EventChannel while it runs.
 *    Fails with code "cancelled" if cancel() was called.
 *  - cancel()
 *  - cacheInfo() -> {count, bytes} of all stored copies (pinned included)
 *  - trimCache({keep}) deletes all but the `keep` most recent unpinned copies
 *  - clearCache() deletes all copies, pinned ones too
 *  - listCopies() -> [{id, path, size, lastUsed, pinned}]; id is the file name
 *  - deleteCopy({id, pinned})
 *  - setPinned({id, pinned, keep}) pins or unpins a copy, then trims the
 *    unpinned ones to `keep`
 */
class PdfImporter(
    private val activity: Activity,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private val cancelled = AtomicBoolean(false)
    private var pendingPick: MethodChannel.Result? = null
    private var progressSink: EventChannel.EventSink? = null

    init {
        MethodChannel(messenger, "writing_recogniser/pdf_import").setMethodCallHandler(this)
        EventChannel(messenger, "writing_recogniser/pdf_import/progress").setStreamHandler(this)
    }

    private val importsDir: File
        get() = File(activity.cacheDir, "imports").apply { mkdirs() }

    private val pinnedDir: File
        get() = File(importsDir, "pinned").apply { mkdirs() }

    /** The stored copy [id] in the pinned or the normal folder. */
    private fun copyFile(id: String, pinned: Boolean): File {
        val dir = if (pinned) pinnedDir else importsDir
        val file = File(dir, id)
        // Only plain file names are accepted, never paths.
        require(file.parentFile?.canonicalPath == dir.canonicalPath) { "Bad copy id" }
        return file
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pick" -> pick(result)
            "releaseAccess" -> {
                runCatching {
                    activity.contentResolver.releasePersistableUriPermission(
                        Uri.parse(call.argument<String>("uri")!!),
                        Intent.FLAG_GRANT_READ_URI_PERMISSION,
                    )
                }
                result.success(null)
            }
            "inspect" -> {
                val uri = Uri.parse(call.argument<String>("uri")!!)
                worker.execute {
                    try {
                        val details = describeSource(uri)
                        main.post { result.success(details) }
                    } catch (e: Exception) {
                        main.post { result.error("unavailable", e.message, null) }
                    }
                }
            }
            "copy" -> copy(
                Uri.parse(call.argument<String>("uri")!!),
                call.argument<String>("name")!!,
                (call.argument<Number>("size") ?: -1).toLong(),
                (call.argument<Number>("modified") ?: 0).toLong(),
                (call.argument<Number>("keep") ?: DEFAULT_KEEP).toInt(),
                result,
            )
            "cacheInfo" -> worker.execute {
                val files = storedCopies() + pinnedCopies()
                val info = mapOf("count" to files.size, "bytes" to files.sumOf { it.length() })
                main.post { result.success(info) }
            }
            "listCopies" -> worker.execute {
                val list = storedCopies().map { describe(it, pinned = false) } +
                    pinnedCopies().map { describe(it, pinned = true) }
                main.post { result.success(list) }
            }
            "deleteCopy" -> {
                val id = call.argument<String>("id")!!
                val pinned = call.argument<Boolean>("pinned") ?: false
                worker.execute {
                    runCatching { copyFile(id, pinned).delete() }
                    main.post { result.success(null) }
                }
            }
            "setPinned" -> {
                val id = call.argument<String>("id")!!
                val pin = call.argument<Boolean>("pinned")!!
                val keep = (call.argument<Number>("keep") ?: DEFAULT_KEEP).toInt()
                worker.execute {
                    try {
                        val from = copyFile(id, pinned = !pin)
                        val to = copyFile(id, pinned = pin)
                        if (from.isFile && !from.renameTo(to)) {
                            throw IllegalStateException("Could not move the copy")
                        }
                        trimTo(keep)
                        main.post { result.success(null) }
                    } catch (e: Exception) {
                        main.post { result.error("pin_failed", e.message, null) }
                    }
                }
            }
            "trimCache" -> {
                val keep = (call.argument<Number>("keep") ?: DEFAULT_KEEP).toInt()
                worker.execute {
                    trimTo(keep)
                    main.post { result.success(null) }
                }
            }
            "clearCache" -> worker.execute {
                importsDir.deleteRecursively()
                main.post { result.success(null) }
            }
            "cancel" -> {
                cancelled.set(true)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun pick(result: MethodChannel.Result) {
        if (pendingPick != null) {
            result.error("busy", "A file picker is already open", null)
            return
        }
        pendingPick = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "application/pdf"
        }
        @Suppress("DEPRECATION")
        activity.startActivityForResult(intent, REQUEST_PICK)
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_PICK) return false
        val result = pendingPick ?: return true
        pendingPick = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result.success(null)
            return true
        }
        try {
            // Keep read access so the file can be reopened from Recent later.
            runCatching {
                activity.contentResolver.takePersistableUriPermission(
                    uri, Intent.FLAG_GRANT_READ_URI_PERMISSION,
                )
            }
            result.success(describeSource(uri))
        } catch (e: Exception) {
            result.error("pick_failed", e.message, null)
        }
        return true
    }

    /** Name, size, date and stored-copy status of a picked file. */
    private fun describeSource(uri: Uri): Map<String, Any?> {
        var name = "document.pdf"
        var size = -1L
        var modified = 0L
        val cursor = activity.contentResolver.query(uri, null, null, null, null)
            ?: throw IllegalStateException("File not found")
        cursor.use { c ->
            if (!c.moveToFirst()) throw IllegalStateException("File not found")
            c.getColumnIndex(OpenableColumns.DISPLAY_NAME).takeIf { it >= 0 }
                ?.let { if (!c.isNull(it)) name = c.getString(it) }
            c.getColumnIndex(OpenableColumns.SIZE).takeIf { it >= 0 }
                ?.let { if (!c.isNull(it)) size = c.getLong(it) }
            c.getColumnIndex(DocumentsContract.Document.COLUMN_LAST_MODIFIED)
                .takeIf { it >= 0 }
                ?.let { if (!c.isNull(it)) modified = c.getLong(it) }
        }
        val id = cacheFile(name, size, modified).name
        val cached = listOf(copyFile(id, pinned = true), copyFile(id, pinned = false))
            .firstOrNull { size >= 0 && it.isFile && it.length() == size }
        // Opening a copy counts as using it, so it's kept longest.
        cached?.setLastModified(System.currentTimeMillis())
        return mapOf(
            "uri" to uri.toString(),
            "name" to name,
            "size" to size,
            "modified" to modified,
            "cacheId" to id,
            "cachedPath" to cached?.absolutePath,
        )
    }

    private fun copy(
        uri: Uri,
        name: String,
        size: Long,
        modified: Long,
        keep: Int,
        result: MethodChannel.Result,
    ) {
        cancelled.set(false)
        worker.execute {
            val target = cacheFile(name, size, modified)
            val partial = File(target.path + ".part")
            try {
                // Make room first: keep at most keep - 1 older copies.
                importsDir.listFiles()?.filter { it.name.endsWith(".part") }?.forEach { it.delete() }
                trimTo(keep - 1, except = target)
                var copied = 0L
                var lastReport = 0L
                activity.contentResolver.openInputStream(uri).use { input ->
                    requireNotNull(input) { "Could not open the file" }
                    partial.outputStream().use { output ->
                        val buffer = ByteArray(1 shl 20)
                        while (true) {
                            if (cancelled.get()) throw CancelledException()
                            val n = input.read(buffer)
                            if (n < 0) break
                            output.write(buffer, 0, n)
                            copied += n
                            val now = System.nanoTime()
                            if (now - lastReport > 100_000_000L) {
                                lastReport = now
                                sendProgress(copied, size)
                            }
                        }
                    }
                }
                sendProgress(copied, if (size >= 0) size else copied)
                if (!partial.renameTo(target)) throw IllegalStateException("Could not save the copy")
                main.post { result.success(target.absolutePath) }
            } catch (e: CancelledException) {
                partial.delete()
                main.post { result.error("cancelled", "Import cancelled", null) }
            } catch (e: Exception) {
                partial.delete()
                main.post { result.error("copy_failed", e.message ?: e.toString(), null) }
            }
        }
    }

    private fun sendProgress(copied: Long, total: Long) {
        main.post { progressSink?.success(mapOf("copied" to copied, "total" to total)) }
    }

    /** One cache file per (name, size, last-modified) so a changed file is copied again. */
    private fun cacheFile(name: String, size: Long, modified: Long): File {
        val safeName = name.replace(Regex("[^A-Za-z0-9._ -]"), "_").take(80)
        return File(importsDir, "${size}_${modified}_$safeName")
    }

    /** Unpinned copies (the ones the "keep the last N" limit applies to). */
    private fun storedCopies(): List<File> =
        importsDir.listFiles()?.filter { it.isFile && !it.name.endsWith(".part") } ?: emptyList()

    private fun pinnedCopies(): List<File> =
        pinnedDir.listFiles()?.filter { it.isFile } ?: emptyList()

    private fun describe(file: File, pinned: Boolean): Map<String, Any> = mapOf(
        "id" to file.name,
        "path" to file.absolutePath,
        "size" to file.length(),
        "lastUsed" to file.lastModified(),
        "pinned" to pinned,
    )

    /** Deletes all but the [keep] most recently used copies (never [except]). */
    private fun trimTo(keep: Int, except: File? = null) {
        storedCopies()
            .filter { it != except }
            .sortedByDescending { it.lastModified() }
            .drop(keep.coerceAtLeast(0))
            .forEach { it.delete() }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        progressSink = events
    }

    override fun onCancel(arguments: Any?) {
        progressSink = null
    }

    private class CancelledException : Exception()

    companion object {
        private const val REQUEST_PICK = 4201
        private const val DEFAULT_KEEP = 3
    }
}
