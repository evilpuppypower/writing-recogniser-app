package com.writingrecogniser

import android.app.Activity
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.database.sqlite.SQLiteDatabase
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.KeyStore
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Backups of everything (owner, 2026-10-16): the database, the settings
 * and the stored PDFs, always encrypted (see BackupFile.java and
 * BackupCrypto.java). Files go only where the user picks with Android's
 * own file picker; the app itself never sends them anywhere.
 *
 * The backup key is kept on the tablet sealed by Android's key store
 * (like [SecretBox]), with its [BackupFile.Lock] (the key sealed by the
 * password and the recovery key) next to it.
 *
 * Channel "writing_recogniser/backup":
 *  - isSetUp -> bool
 *  - setUp {password} -> the recovery key to write down (a new one each time)
 *  - backUp {name, appBuild, created} -> bytes written, or null if cancelled;
 *    "progress" {phase: "backup"|"check", done, total} calls while it runs
 *  - chooseBackup -> {uri, created, appBuild, bytes} of a picked backup, or null
 *  - restore {uri, password?, recovery?} -> "ready" (restart to finish),
 *    "wrong" (password or recovery key); "progress" calls while it runs
 *  - cancel: stops a backup or restore that's running
 *  - restart: puts an unpacked restore in place: closes the app, which
 *    opens again with it
 *  - discardRestore: forgets an unpacked restore (nothing changes)
 *  - restoreProblem -> why the last restore couldn't be put in place, once,
 *    or null
 *  - chooseFolder -> the name of a folder picked for automatic backups
 *    (kept, with permission to write there), or null if cancelled
 *  - setAuto {every, keep}: every how many days (0 = off), and how many of
 *    the app's backups to keep in the folder
 *  - autoStatus -> {folder, every, keep, at, bytes, failedAt, error}
 *  - backUpToFolder: an automatic backup now ("progress" calls) -> true
 *    when saved and checked
 */
class BackupChannel(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "writing_recogniser/backup")
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val stop = AtomicBoolean(false)
    private var pendingSave: Pair<Map<String, String>, MethodChannel.Result>? = null
    private var pendingOpen: MethodChannel.Result? = null
    private var pendingFolder: MethodChannel.Result? = null

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "isSetUp" -> {
                    stop.set(false)
                    work(result) { isSetUp(activity) }
                }
                "discardRestore" -> {
                    stagingDir(activity).deleteRecursively()
                    result.success(null)
                }
                "chooseFolder" -> {
                    if (pendingFolder != null) {
                        result.error("busy", "Already choosing a folder", null)
                        return@setMethodCallHandler
                    }
                    pendingFolder = result
                    try {
                        activity.startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE), REQUEST_FOLDER)
                    } catch (e: Exception) {
                        pendingFolder = null
                        result.error("backup", "Android's folder picker couldn't open", null)
                    }
                }
                "setAuto" -> {
                    val every = call.argument<Int>("every") ?: 0
                    val keep = call.argument<Int>("keep") ?: 5
                    work(result) {
                        AutoBackup.save(activity, AutoBackup.settings(activity).copy(everyDays = every, keep = keep))
                        null
                    }
                }
                "autoStatus" -> work(result) { autoStatus() }
                "setBatterySaver" -> {
                    val on = call.argument<Boolean>("on") ?: false
                    val withSystem = call.argument<Boolean>("withSystem") ?: true
                    work(result) {
                        AutoBackup.saveBatterySaver(activity, on, withSystem)
                        null
                    }
                }
                "backUpToFolder" -> {
                    stop.set(false)
                    work(result) {
                        val ok = AutoBackup.run(activity, progress("backup")) { stop.get() }
                        if (!ok && stop.get()) throw Exception("stopped")
                        if (!ok) throw Exception(AutoBackup.status(activity)["error"] ?: "It didn't work")
                        true
                    }
                }
                "restoreProblem" -> {
                    val f = problemFile(activity)
                    result.success(if (f.isFile) f.readText().also { f.delete() } else null)
                }
                "setUp" -> {
                    val password = call.argument<String>("password") ?: ""
                    stop.set(false)
                    work(result) { setUp(password.toCharArray()) }
                }
                "backUp" -> {
                    if (pendingSave != null) {
                        result.error("busy", "A backup is already being saved", null)
                        return@setMethodCallHandler
                    }
                    val args = mapOf(
                        "appBuild" to (call.argument<String>("appBuild") ?: ""),
                        "created" to (call.argument<String>("created") ?: ""),
                    )
                    stop.set(false)
                    pendingSave = args to result
                    try {
                        activity.startActivityForResult(
                            Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                                addCategory(Intent.CATEGORY_OPENABLE)
                                type = "application/octet-stream"
                                putExtra(Intent.EXTRA_TITLE, call.argument<String>("name") ?: "backup.wrbackup")
                            },
                            REQUEST_SAVE,
                        )
                    } catch (e: Exception) {
                        pendingSave = null
                        result.error("backup", "Android's file picker couldn't open", null)
                    }
                }
                "chooseBackup" -> {
                    if (pendingOpen != null) {
                        result.error("busy", "Already choosing a file", null)
                        return@setMethodCallHandler
                    }
                    pendingOpen = result
                    try {
                        activity.startActivityForResult(
                            Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                                addCategory(Intent.CATEGORY_OPENABLE)
                                type = "*/*"
                            },
                            REQUEST_OPEN,
                        )
                    } catch (e: Exception) {
                        pendingOpen = null
                        result.error("backup", "Android's file picker couldn't open", null)
                    }
                }
                "restore" -> {
                    val uri = Uri.parse(call.argument<String>("uri")!!)
                    val password = call.argument<String>("password")
                    val recovery = call.argument<String>("recovery")
                    stop.set(false)
                    work(result) { restore(uri, password, recovery) }
                }
                "cancel" -> {
                    stop.set(true)
                    result.success(null)
                }
                "restart" -> {
                    // Only now is it put in place, the next time the app
                    // opens: a restore left waiting never replaces later
                    // work.
                    val staging = stagingDir(activity)
                    if (!File(staging, "files").isDirectory) {
                        result.error("backup", "No restore is waiting", null)
                        return@setMethodCallHandler
                    }
                    File(staging, READY).writeText("ready")
                    result.success(null)
                    main.postDelayed({
                        activity.startActivity(
                            Intent.makeRestartActivityTask(ComponentName(activity, LaunchActivity::class.java))
                                .putExtra(LaunchActivity.AFTER_RESTORE, true),
                        )
                        // This process goes at once, so the app opens in a
                        // new one, where the restore is put in place first.
                        android.os.Process.killProcess(android.os.Process.myPid())
                    }, 200)
                }
                else -> result.notImplemented()
            }
        }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        val uri = if (resultCode == Activity.RESULT_OK) data?.data else null
        when (requestCode) {
            REQUEST_SAVE -> {
                val (args, result) = pendingSave ?: return true
                pendingSave = null
                if (uri == null) result.success(null)
                else work(result) { backUp(uri, args["created"]!!, args["appBuild"]!!) }
                return true
            }
            REQUEST_FOLDER -> {
                val result = pendingFolder ?: return true
                pendingFolder = null
                if (uri == null) {
                    result.success(null)
                } else {
                    work(result) {
                        val flags = Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                        activity.contentResolver.takePersistableUriPermission(uri, flags)
                        // Only one folder is kept: let go of the one before.
                        val before = AutoBackup.settings(activity)
                        before.folder?.takeIf { it != uri }?.let {
                            try {
                                activity.contentResolver.releasePersistableUriPermission(it, flags)
                            } catch (_: Exception) {}
                        }
                        AutoBackup.save(activity, before.copy(folder = uri))
                        folderName(uri)
                    }
                }
                return true
            }
            REQUEST_OPEN -> {
                val result = pendingOpen ?: return true
                pendingOpen = null
                if (uri == null) result.success(null)
                else work(result) { describe(uri) }
                return true
            }
        }
        return false
    }

    /** Runs [job] off the main thread and answers with what it returns. */
    private fun work(result: MethodChannel.Result, job: () -> Any?) {
        worker.execute {
            try {
                val value = job()
                main.post { result.success(value) }
            } catch (e: Exception) {
                val stopped = e.message == "stopped"
                main.post {
                    if (stopped) result.success(null)
                    else result.error("backup", e.message ?: e.javaClass.simpleName, null)
                }
            }
        }
    }

    private fun progress(phase: String): BackupFile.Progress {
        var last = 0L
        return BackupFile.Progress { done, total ->
            val now = System.currentTimeMillis()
            if (now - last > 200 || done == total) {
                last = now
                main.post { channel.invokeMethod("progress", mapOf("phase" to phase, "done" to done, "total" to total)) }
            }
            !stop.get()
        }
    }

    private fun setUp(password: CharArray): String {
        val key = backupKey(activity) ?: BackupCrypto.random(32).also { saveBackupKey(activity, it) }
        val recovery = BackupCrypto.random(20)
        val lock = BackupFile.Lock.make(key, password, recovery, BackupCrypto.PASSWORD_ITERATIONS)
        java.util.Arrays.fill(password, '\u0000')
        lockFile(activity).writeBytes(BackupFile.lines(lock.toMap()))
        return BackupCrypto.recoveryText(recovery)
    }

    private fun backUp(uri: Uri, created: String, appBuild: String): Long {
        try {
            val written = writeBackup(activity, created, appBuild, progress("backup")) { write ->
                val out = try {
                    activity.contentResolver.openOutputStream(uri, "wt")
                } catch (e: Exception) {
                    // Some cloud folders don't take "wt".
                    activity.contentResolver.openOutputStream(uri, "w")
                }
                out!!.use { write(it) }
            }
            // Read back and checked, so a backup that can't be restored is
            // found now rather than when it's needed.
            val key = backupKey(activity)!!
            activity.contentResolver.openInputStream(uri)!!.use { input ->
                val opened = BackupFile.readHeader(input)
                BackupFile.extract(input, opened, key, null, written, progress("check"))
            }
            return sizeOf(uri)
        } catch (e: Exception) {
            // Stopped or failed: no half-made file that looks like a backup.
            try {
                DocumentsContract.deleteDocument(activity.contentResolver, uri)
            } catch (_: Exception) {}
            throw e
        }
    }

    private fun folderName(tree: Uri): String? = try {
        val doc = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
        activity.contentResolver.query(
            doc,
            arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME),
            null,
            null,
            null,
        )?.use { if (it.moveToFirst()) it.getString(0) else null }
    } catch (e: Exception) {
        null
    }

    private fun autoStatus(): Map<String, Any?> {
        val s = AutoBackup.settings(activity)
        val status = AutoBackup.status(activity)
        // The folder may have been removed, or its permission taken back.
        val allowed = s.folder != null && activity.contentResolver.persistedUriPermissions.any {
            it.uri == s.folder && it.isWritePermission
        }
        return mapOf(
            "folder" to if (allowed) folderName(s.folder!!) ?: "the chosen folder" else null,
            "every" to s.everyDays,
            "keep" to s.keep,
            "at" to status["at"],
            "bytes" to status["bytes"]?.toLongOrNull(),
            "failedAt" to status["failedAt"],
            "error" to status["error"],
        )
    }

    private fun sizeOf(uri: Uri): Long =
        activity.contentResolver.query(uri, arrayOf(OpenableColumns.SIZE), null, null, null)?.use {
            if (it.moveToFirst() && !it.isNull(0)) it.getLong(0) else -1L
        } ?: -1L

    private fun describe(uri: Uri): Map<String, Any?> {
        val opened = activity.contentResolver.openInputStream(uri)!!.use { BackupFile.readHeader(it) }
        return mapOf(
            "uri" to uri.toString(),
            "created" to opened.header["created"],
            "appBuild" to opened.header["appBuild"],
            "bytes" to sizeOf(uri),
        )
    }

    private fun restore(uri: Uri, password: String?, recovery: String?): String {
        val staging = stagingDir(activity)
        staging.deleteRecursively()
        activity.contentResolver.openInputStream(uri)!!.use { input ->
            val opened = BackupFile.readHeader(input)
            val key = when {
                password != null -> opened.lock.withPassword(password.toCharArray())
                recovery != null -> opened.lock.withRecovery(recovery)
                else -> null
            } ?: return "wrong"
            val files = File(staging, "files").apply { mkdirs() }
            val total = opened.header["bytes"]?.toLongOrNull() ?: sizeOf(uri)
            BackupFile.extract(input, opened, key, files, total, progress("restore"))
            // The backup's key and lock come along, so this tablet makes
            // backups the same password opens. The key is sealed by the key
            // store while it waits, as it always is.
            File(staging, "key.sealed").writeBytes(seal(key))
            File(staging, "lock").writeBytes(BackupFile.lines(opened.lock.toMap()))
        }
        return "ready"
    }

    companion object {
        private const val REQUEST_SAVE = 7301
        private const val REQUEST_OPEN = 7302
        private const val REQUEST_FOLDER = 7303
        private const val ALIAS = "writing_recogniser.backup"
        private const val READY = "ready"
        private const val DB_NAME = "writing_recogniser.db"
        private const val PREFS = "FlutterSharedPreferences"
        private val writing = Any()

        private fun dir(context: Context) = File(context.filesDir, "backup").apply { mkdirs() }
        private fun lockFile(context: Context) = File(dir(context), "lock.txt")
        private fun keyFile(context: Context) = File(dir(context), "key.sealed")
        private fun stagingDir(context: Context) = File(context.filesDir, "restore-staging")
        private fun previousDir(context: Context) = File(context.filesDir, "restore-previous")
        private fun problemFile(context: Context) = File(dir(context), "restore-problem.txt")

        fun isSetUp(context: Context) = lockFile(context).isFile && backupKey(context) != null

        private fun keystoreKey(): SecretKey {
            val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
            (store.getKey(ALIAS, null) as? SecretKey)?.let { return it }
            val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
            gen.init(
                KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setKeySize(256)
                    .build(),
            )
            return gen.generateKey()
        }

        private fun seal(key: ByteArray): ByteArray {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, keystoreKey())
            return cipher.iv + cipher.doFinal(key)
        }

        private fun saveBackupKey(context: Context, key: ByteArray) {
            keyFile(context).writeBytes(seal(key))
        }

        /** The backup key, or null if backups aren't set up (or the key
         * store lost its key). */
        fun backupKey(context: Context): ByteArray? = try {
            val sealed = keyFile(context).readBytes()
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, keystoreKey(), GCMParameterSpec(128, sealed, 0, 12))
            cipher.doFinal(sealed, 12, sealed.size - 12)
        } catch (e: Exception) {
            null
        }

        fun lock(context: Context): BackupFile.Lock =
            BackupFile.Lock.fromMap(BackupFile.parseLines(lockFile(context).readBytes()))

        /** What's backed up: a copy of the database (made by SQLite itself, so
         * it's whole even while the app writes), the settings, and every
         * stored PDF and notebook. */
        private fun items(context: Context, tmp: File): List<BackupFile.Item> {
            val items = mutableListOf<BackupFile.Item>()
            val db = context.getDatabasePath(DB_NAME)
            if (db.isFile) {
                val copy = File(tmp, DB_NAME)
                copy.delete()
                // Read-only, so nothing is written to the database the app
                // has open; tried again if the app is busy writing.
                var tries = 0
                while (true) {
                    try {
                        SQLiteDatabase.openDatabase(
                            db.path,
                            null,
                            SQLiteDatabase.OPEN_READONLY or SQLiteDatabase.NO_LOCALIZED_COLLATORS,
                        ).use {
                            it.execSQL("VACUUM INTO ?", arrayOf<Any>(copy.path))
                        }
                        break
                    } catch (e: android.database.sqlite.SQLiteException) {
                        copy.delete()
                        if (++tries >= 5) throw e
                        Thread.sleep(500L * tries)
                    }
                }
                items.add(BackupFile.Item("db/$DB_NAME", copy, false))
            }
            File(context.filesDir, "datastore/$PREFS.preferences_pb").takeIf { it.isFile }?.let {
                items.add(BackupFile.Item("prefs/datastore/${it.name}", it, false))
            }
            File(context.dataDir, "shared_prefs/$PREFS.xml").takeIf { it.isFile }?.let {
                items.add(BackupFile.Item("prefs/shared_prefs/${it.name}", it, false))
            }
            val imports = File(context.cacheDir, "imports")
            items.addAll(BackupFile.folder(imports, "pdfs", true).filter { !it.path.endsWith(".part") })
            return items
        }

        /** Writes a backup with [open] (given the files, and how to write them
         * to a stream); the total bytes backed up. */
        fun writeBackup(
            context: Context,
            created: String,
            appBuild: String,
            progress: BackupFile.Progress,
            open: ((java.io.OutputStream) -> Unit) -> Unit,
        ): Long {
            val key = backupKey(context) ?: throw IllegalStateException("Backups aren't set up")
            val lock = lock(context)
            // One backup at a time (one by hand and a scheduled one could
            // otherwise meet), each with its own temporary folder.
            synchronized(writing) {
                val tmp = File(context.cacheDir, "backup-tmp").apply { deleteRecursively(); mkdirs() }
                try {
                    val items = items(context, tmp)
                    open { out -> BackupFile.write(out, items, key, lock, created, appBuild, progress) }
                    return items.sumOf { it.file.length() }
                } finally {
                    tmp.deleteRecursively()
                }
            }
        }

        /**
         * Puts a restored backup in place (from [App.onCreate], before
         * anything opens the database or settings), once the user chose
         * "Restart the app now". What's there is moved aside first; if any
         * step fails, everything is moved back (nothing changes) and the
         * app says why when it opens. Safe to run again if the app stops
         * part way.
         */
        fun finishRestore(context: Context) {
            val staging = stagingDir(context)
            if (!File(staging, READY).isFile) {
                // Unpacked but never confirmed (or never finished): nothing
                // changes.
                if (staging.exists()) staging.deleteRecursively()
                previousDir(context).deleteRecursively()
                return
            }
            val files = File(staging, "files")
            val previous = previousDir(context)
            val db = context.getDatabasePath(DB_NAME)
            // What's restored -> where it goes. Everything the backup
            // replaces is replaced, even if the backup doesn't have it.
            val parts = listOf(
                File(files, "db/$DB_NAME") to db,
                // The database's own side files go with it (moved aside,
                // never deleted, so moving back loses nothing).
                File(files, "db/$DB_NAME-wal") to File(db.path + "-wal"),
                File(files, "db/$DB_NAME-shm") to File(db.path + "-shm"),
                File(files, "db/$DB_NAME-journal") to File(db.path + "-journal"),
                File(files, "prefs/datastore/$PREFS.preferences_pb") to
                    File(context.filesDir, "datastore/$PREFS.preferences_pb"),
                File(files, "prefs/shared_prefs/$PREFS.xml") to File(context.dataDir, "shared_prefs/$PREFS.xml"),
                File(files, "pdfs") to File(context.cacheDir, "imports"),
                File(staging, "key.sealed") to keyFile(context),
                File(staging, "lock") to lockFile(context),
            )
            val done = mutableListOf<Pair<File, File>>()
            try {
                for ((index, part) in parts.withIndex()) {
                    val (from, to) = part
                    val aside = File(previous, index.toString())
                    if (!aside.exists()) {
                        aside.parentFile?.mkdirs()
                        if (to.exists() && !to.renameTo(aside)) throw java.io.IOException("Couldn't move ${to.name} aside")
                        // Marks it moved aside, even when there was nothing.
                        if (!aside.exists()) aside.mkdirs()
                    }
                    done.add(aside to to)
                    if (from.exists()) {
                        to.parentFile?.mkdirs()
                        if (!from.renameTo(to)) throw java.io.IOException("Couldn't put ${to.name} in place")
                    }
                }
            } catch (e: Exception) {
                // Back as it was.
                for ((aside, to) in done.reversed()) {
                    to.deleteRecursively()
                    if (aside.isDirectory && aside.list().isNullOrEmpty()) continue
                    aside.renameTo(to)
                }
                staging.deleteRecursively()
                previous.deleteRecursively()
                problemFile(context).writeText(
                    "The backup couldn't be put in place, so nothing was changed: ${e.message}"
                )
                return
            }
            staging.deleteRecursively()
            previous.deleteRecursively()
        }

    }
}
