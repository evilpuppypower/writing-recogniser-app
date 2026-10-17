package com.writingrecogniser

import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.ComponentName
import android.content.Context
import android.net.Uri
import android.provider.DocumentsContract
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/**
 * Automatic backups (owner, 2026-10-16: every few days, to a folder on the
 * tablet or a cloud provider's folder): Android's own job scheduler runs
 * [AutoBackupJob] every [Settings.everyDays] days, when the battery and
 * storage aren't low. Each run saves a new backup into the chosen folder
 * (the user picks it with Android's folder picker, which also offers
 * cloud providers' folders), checks it, and then removes the oldest of
 * the app's own backups there, keeping [Settings.keep]. The app makes no
 * network calls: a cloud provider's app moves the file.
 */
object AutoBackup {
    private const val JOB_ID = 7310
    /** Automatic backups have their own name, so only they are ever removed
     * (never a backup the user saved there by hand); the time is in UTC,
     * so the names sort by age even if the clock's zone changes. */
    const val PREFIX = "writing-recogniser-auto-"
    const val SUFFIX = ".wrbackup"

    data class Settings(val folder: Uri?, val everyDays: Int, val keep: Int)

    private fun dir(context: Context) = File(context.filesDir, "backup").apply { mkdirs() }
    private fun settingsFile(context: Context) = File(dir(context), "auto.txt")
    private fun statusFile(context: Context) = File(dir(context), "auto-status.txt")
    private fun saverFile(context: Context) = File(dir(context), "battery-saver.txt")

    /** The app's battery saver (owner, 2026-10-17), told by the app when it
     * changes: switched on, and whether it follows Android's. */
    fun saveBatterySaver(context: Context, on: Boolean, withSystem: Boolean) {
        writeAtomically(saverFile(context), BackupFile.lines(linkedMapOf("on" to on.toString(), "withSystem" to withSystem.toString())))
    }

    /** Whether to wait: the app's battery saver is on now. */
    fun savingBattery(context: Context): Boolean {
        val m = if (saverFile(context).isFile) BackupFile.parseLines(saverFile(context).readBytes()) else emptyMap()
        val on = m["on"] == "true"
        val withSystem = m["withSystem"] != "false"
        val system = context.getSystemService(android.os.PowerManager::class.java).isPowerSaveMode
        return on || (withSystem && system)
    }

    fun settings(context: Context): Settings {
        val m = if (settingsFile(context).isFile) BackupFile.parseLines(settingsFile(context).readBytes()) else emptyMap()
        return Settings(
            folder = m["folder"]?.takeIf { it.isNotEmpty() }?.let(Uri::parse),
            everyDays = m["every"]?.toIntOrNull() ?: 0,
            keep = m["keep"]?.toIntOrNull() ?: 5,
        )
    }

    fun save(context: Context, s: Settings) {
        val before = settings(context)
        writeAtomically(settingsFile(context),
            BackupFile.lines(
                linkedMapOf(
                    "folder" to (s.folder?.toString() ?: ""),
                    "every" to s.everyDays.toString(),
                    "keep" to s.keep.toString(),
                ),
            ),
        )
        // Changing only how many are kept doesn't put the next one off.
        if (before.folder != s.folder || before.everyDays != s.everyDays) schedule(context, s)
        else ensureScheduled(context)
    }

    /** Scheduled again if Android dropped it (e.g. after the app was force
     * stopped); called when the app opens. */
    fun ensureScheduled(context: Context) {
        val s = settings(context)
        val scheduler = context.getSystemService(JobScheduler::class.java)
        if (s.folder != null && s.everyDays > 0 && scheduler.getPendingJob(JOB_ID) == null) schedule(context, s)
    }

    /** Whether the app may still write to the chosen folder (it may have
     * been removed, or its permission taken back). */
    fun canWrite(context: Context): Boolean {
        val folder = settings(context).folder ?: return false
        return context.contentResolver.persistedUriPermissions.any { it.uri == folder && it.isWritePermission }
    }

    private fun writeAtomically(file: File, bytes: ByteArray) {
        val tmp = File(file.path + ".tmp")
        tmp.writeBytes(bytes)
        if (!tmp.renameTo(file)) {
            file.writeBytes(bytes)
            tmp.delete()
        }
    }

    /** The last automatic backup: when (UTC), its size, or why it failed. */
    fun status(context: Context): Map<String, String> =
        if (statusFile(context).isFile) BackupFile.parseLines(statusFile(context).readBytes()) else emptyMap()

    @Synchronized
    private fun record(context: Context, status: Map<String, String>) {
        writeAtomically(statusFile(context), BackupFile.lines(status.mapValues { it.value.replace("\n", " ") }))
    }

    private fun schedule(context: Context, s: Settings) {
        val scheduler = context.getSystemService(JobScheduler::class.java)
        if (s.folder == null || s.everyDays <= 0) {
            scheduler.cancel(JOB_ID)
            return
        }
        val period = s.everyDays * 24L * 60 * 60 * 1000
        scheduler.schedule(
            JobInfo.Builder(JOB_ID, ComponentName(context, AutoBackupJob::class.java))
                .setPeriodic(period, period / 4)
                .setPersisted(true) // kept after the tablet restarts
                .setRequiresBatteryNotLow(true)
                .setRequiresStorageNotLow(true)
                // Tried again within the hour or so if it had to wait
                // (battery saver), or failed.
                .setBackoffCriteria(30L * 60 * 1000, JobInfo.BACKOFF_POLICY_EXPONENTIAL)
                .build(),
        )
    }

    /** A UTC time for the status (it may be shown or shared). */
    private fun utcNow(): String =
        SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US)
            .apply { timeZone = TimeZone.getTimeZone("UTC") }
            .format(Date())

    /** The backup's file name, by the time in UTC. */
    private fun fileName(): String =
        PREFIX + SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US)
            .apply { timeZone = TimeZone.getTimeZone("UTC") }
            .format(Date()) + SUFFIX

    /**
     * Makes one backup into the chosen folder now. True if it was saved and
     * checked; false if it failed or [stop] said stop (then it's recorded
     * and nothing half-made is left behind).
     */
    fun run(context: Context, progress: BackupFile.Progress?, stop: () -> Boolean): Boolean {
        val s = settings(context)
        val tree = s.folder
        if (tree == null || !BackupChannel.isSetUp(context)) {
            record(context, mapOf("failedAt" to utcNow(), "error" to "Backups aren't set up"))
            return false
        }
        if (!canWrite(context)) {
            record(
                context,
                status(context).filterKeys { it == "at" || it == "bytes" } +
                    mapOf("failedAt" to utcNow(), "error" to "The folder can't be written to any more: choose it again"),
            )
            return false
        }
        val resolver = context.contentResolver
        var file: Uri? = null
        try {
            val parent = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
            val target = DocumentsContract.createDocument(resolver, parent, "application/octet-stream", fileName())
                ?: throw java.io.IOException("The folder can't be written to")
            file = target
            val wrapped = BackupFile.Progress { done, total ->
                (progress?.at(done, total) ?: true) && !stop()
            }
            val created = utcNow()
            val written = BackupChannel.writeBackup(context, created, "", wrapped) { write ->
                resolver.openOutputStream(target, "w")!!.use { write(it) }
            }
            val key = BackupChannel.backupKey(context)!!
            resolver.openInputStream(target)!!.use { input ->
                val opened = BackupFile.readHeader(input)
                BackupFile.extract(input, opened, key, null, written, wrapped)
            }
            removeOld(context, tree, s.keep)
            record(context, mapOf("at" to created, "bytes" to written.toString()))
            return true
        } catch (e: Exception) {
            file?.let {
                try {
                    DocumentsContract.deleteDocument(resolver, it)
                } catch (_: Exception) {}
            }
            val why = if (e.message == "stopped" || stop()) {
                "Stopped before it finished (it's tried again later)"
            } else {
                e.message ?: e.javaClass.simpleName
            }
            record(context, status(context).filterKeys { it == "at" || it == "bytes" } +
                mapOf("failedAt" to utcNow(), "error" to why))
            return false
        }
    }

    /** Keeps the newest [keep] of the app's own backups in the folder (the
     * names sort by date); nothing else there is touched. */
    private fun removeOld(context: Context, tree: Uri, keep: Int) {
        if (keep <= 0) return
        val resolver = context.contentResolver
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
        val ours = mutableListOf<Pair<String, String>>()
        resolver.query(
            children,
            arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID, DocumentsContract.Document.COLUMN_DISPLAY_NAME),
            null,
            null,
            null,
        )?.use { c ->
            while (c.moveToNext()) {
                val name = c.getString(1) ?: continue
                if (name.startsWith(PREFIX) && name.endsWith(SUFFIX)) ours.add(name to c.getString(0))
            }
        }
        for ((_, id) in ours.sortedByDescending { it.first }.drop(keep)) {
            try {
                DocumentsContract.deleteDocument(resolver, DocumentsContract.buildDocumentUriUsingTree(tree, id))
            } catch (_: Exception) {}
        }
    }
}

/** Runs an automatic backup when Android's job scheduler says. */
class AutoBackupJob : JobService() {
    @Volatile private var stopped = false

    override fun onStartJob(params: JobParameters): Boolean {
        stopped = false
        Thread {
            var retry = false
            try {
                if (AutoBackup.savingBattery(applicationContext)) {
                    // Waits while battery saver is on; tried again later.
                    retry = true
                    return@Thread
                }
                val ok = AutoBackup.run(applicationContext, null) { stopped }
                // Failed for a reason other than being stopped, and the
                // folder is still there: tried again with Android's
                // back-off, as well as at the next period.
                retry = !ok && !stopped && AutoBackup.canWrite(applicationContext)
            } catch (t: Throwable) {
                // Never crash the app from here.
            } finally {
                jobFinished(params, retry)
            }
        }.start()
        return true
    }

    override fun onStopJob(params: JobParameters): Boolean {
        stopped = true
        return true // tried again later
    }
}
