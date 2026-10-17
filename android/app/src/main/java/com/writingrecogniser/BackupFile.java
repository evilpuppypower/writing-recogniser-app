package com.writingrecogniser;

import java.io.BufferedOutputStream;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.zip.Deflater;
import java.util.zip.ZipEntry;
import java.util.zip.ZipInputStream;
import java.util.zip.ZipOutputStream;

/**
 * A whole backup in one file (owner, 2026-10-16: everything, PDFs too,
 * always encrypted): the files, zipped, then encrypted with
 * {@link BackupCrypto}. Plain Java, so it's tested off the tablet.
 *
 * The header (readable, but bound into every chunk so it can't be
 * changed) holds the backup key sealed by the password and by the
 * recovery key ({@link Lock}), and this file's own key sealed by the
 * backup key. Inside the zip, "manifest.txt" comes last and lists every
 * file with its size and SHA-256, so a restore checks every byte.
 */
public final class BackupFile {
    private BackupFile() {}

    public static final String FORMAT = "writing-recogniser-backup";
    public static final String MANIFEST = "manifest.txt";
    private static final byte[] AAD_PASSWORD = BackupCrypto.utf8("password");
    private static final byte[] AAD_RECOVERY = BackupCrypto.utf8("recovery");
    private static final byte[] AAD_FILE = BackupCrypto.utf8("file");

    /** The backup key, sealed by the password and by the recovery key. Made
     * when backups are set up (and again when the password changes); kept
     * on the tablet and copied into every backup's header, so backups need
     * no password. */
    public static final class Lock {
        public final byte[] passwordSalt;
        public final int iterations;
        public final byte[] byPassword;
        public final byte[] recoverySalt;
        public final byte[] byRecovery;

        Lock(byte[] passwordSalt, int iterations, byte[] byPassword, byte[] recoverySalt, byte[] byRecovery) {
            this.passwordSalt = passwordSalt;
            this.iterations = iterations;
            this.byPassword = byPassword;
            this.recoverySalt = recoverySalt;
            this.byRecovery = byRecovery;
        }

        public static Lock make(byte[] backupKey, char[] password, byte[] recovery, int iterations)
                throws GeneralSecurityException {
            byte[] ps = BackupCrypto.random(16), rs = BackupCrypto.random(16);
            byte[] pk = BackupCrypto.passwordKey(password, ps, iterations);
            byte[] rk = BackupCrypto.recoveryKey(recovery, rs);
            return new Lock(ps, iterations, BackupCrypto.seal(pk, backupKey, AAD_PASSWORD),
                    rs, BackupCrypto.seal(rk, backupKey, AAD_RECOVERY));
        }

        /** The backup key from [password], or null if it's wrong. */
        public byte[] withPassword(char[] password) throws GeneralSecurityException {
            byte[] pk = BackupCrypto.passwordKey(password, passwordSalt, iterations);
            try {
                return BackupCrypto.open(pk, byPassword, AAD_PASSWORD);
            } catch (javax.crypto.AEADBadTagException e) {
                return null;
            }
        }

        /** The backup key from the recovery key as typed, or null. */
        public byte[] withRecovery(String typed) throws GeneralSecurityException {
            byte[] r = BackupCrypto.recoveryBytes(typed, 20);
            if (r == null) return null;
            try {
                return BackupCrypto.open(BackupCrypto.recoveryKey(r, recoverySalt), byRecovery, AAD_RECOVERY);
            } catch (javax.crypto.AEADBadTagException e) {
                return null;
            }
        }

        public Map<String, String> toMap() {
            Map<String, String> m = new LinkedHashMap<>();
            m.put("passwordSalt", BackupCrypto.toHex(passwordSalt));
            m.put("iterations", Integer.toString(iterations));
            m.put("byPassword", BackupCrypto.toHex(byPassword));
            m.put("recoverySalt", BackupCrypto.toHex(recoverySalt));
            m.put("byRecovery", BackupCrypto.toHex(byRecovery));
            return m;
        }

        /** Only a sensible number of rounds: a file asking for billions
         * would keep the tablet busy for hours. */
        private static int iterations(String text) {
            int n = Integer.parseInt(text);
            if (n < 100_000 || n > 10_000_000) throw new IllegalArgumentException("rounds");
            return n;
        }

        public static Lock fromMap(Map<String, String> m) throws IOException {
            try {
                return new Lock(
                        BackupCrypto.fromHex(m.get("passwordSalt")),
                        iterations(m.get("iterations")),
                        BackupCrypto.fromHex(m.get("byPassword")),
                        BackupCrypto.fromHex(m.get("recoverySalt")),
                        BackupCrypto.fromHex(m.get("byRecovery")));
            } catch (RuntimeException e) {
                throw new IOException("Not a backup file");
            }
        }
    }

    /** "key=value" lines (values are hex, digits or plain words). */
    public static byte[] lines(Map<String, String> m) {
        StringBuilder s = new StringBuilder();
        for (Map.Entry<String, String> e : m.entrySet()) {
            if (e.getKey().contains("=") || e.getKey().contains("\n") || e.getValue().contains("\n")) {
                throw new IllegalArgumentException("bad header field");
            }
            s.append(e.getKey()).append('=').append(e.getValue()).append('\n');
        }
        return BackupCrypto.utf8(s.toString());
    }

    public static Map<String, String> parseLines(byte[] b) {
        Map<String, String> m = new LinkedHashMap<>();
        for (String line : new String(b, StandardCharsets.UTF_8).split("\n")) {
            int i = line.indexOf('=');
            if (i > 0) m.put(line.substring(0, i), line.substring(i + 1));
        }
        return m;
    }

    /** A file to back up: where it goes in the backup, and where it is. */
    public static final class Item {
        public final String path;
        public final File file;
        /** Already compressed (PDFs): stored as they are, which is quicker. */
        public final boolean packed;

        public Item(String path, File file, boolean packed) {
            this.path = path;
            this.file = file;
            this.packed = packed;
        }
    }

    public interface Progress {
        /** False to stop. */
        boolean at(long done, long total);
    }

    /** Writes a backup of [items] to [out] (closed at the end). [created]:
     * when, as UTC text. Throws IOException("stopped") if [progress] says
     * stop. */
    public static void write(OutputStream out, List<Item> items, byte[] backupKey, Lock lock,
            String created, String appBuild, Progress progress) throws IOException, GeneralSecurityException {
        byte[] fileKey = BackupCrypto.random(32);
        byte[] prefix = BackupCrypto.random(4);
        long total = 0, done = 0;
        for (Item i : items) total += i.file.length();
        Map<String, String> h = new LinkedHashMap<>();
        h.put("format", FORMAT);
        h.put("created", created.replace("\n", " "));
        h.put("appBuild", appBuild.replace("\n", " "));
        // The size of what's inside, for the progress bar when restoring.
        h.put("bytes", Long.toString(total));
        h.putAll(lock.toMap());
        h.put("fileKey", BackupCrypto.toHex(BackupCrypto.seal(backupKey, fileKey, AAD_FILE)));
        h.put("noncePrefix", BackupCrypto.toHex(prefix));
        byte[] header = lines(h);
        OutputStream buffered = new BufferedOutputStream(out, 1 << 16);
        BackupCrypto.writeHeader(buffered, header);
        BackupCrypto.Encrypting enc = new BackupCrypto.Encrypting(buffered, fileKey, prefix, header);
        ZipOutputStream zip = new ZipOutputStream(enc);
        StringBuilder manifest = new StringBuilder();
        byte[] buf = new byte[1 << 16];
        try {
            for (Item i : items) {
                checkPath(i.path);
                MessageDigest sha = sha256();
                zip.setLevel(i.packed ? Deflater.NO_COMPRESSION : Deflater.DEFAULT_COMPRESSION);
                ZipEntry entry = new ZipEntry(i.path);
                // No times inside (they'd be in local time).
                entry.setTime(0);
                zip.putNextEntry(entry);
                long size = 0;
                try (InputStream in = new FileInputStream(i.file)) {
                    int n;
                    while ((n = in.read(buf)) > 0) {
                        zip.write(buf, 0, n);
                        sha.update(buf, 0, n);
                        size += n;
                        done += n;
                        if (progress != null && !progress.at(done, total)) throw new IOException("stopped");
                    }
                }
                zip.closeEntry();
                manifest.append(i.path).append('\t').append(size).append('\t')
                        .append(BackupCrypto.toHex(sha.digest())).append('\n');
            }
            zip.setLevel(Deflater.DEFAULT_COMPRESSION);
            ZipEntry list = new ZipEntry(MANIFEST);
            list.setTime(0);
            zip.putNextEntry(list);
            zip.write(BackupCrypto.utf8(manifest.toString()));
            zip.closeEntry();
            zip.close(); // closes the encryption (last chunk) and [out]
        } catch (IOException | RuntimeException e) {
            try { out.close(); } catch (IOException ignored) {}
            throw e;
        }
    }

    /** What a backup's header says, before it's opened. */
    public static final class Opened {
        public final Map<String, String> header;
        public final Lock lock;
        final byte[] headerBytes;

        Opened(Map<String, String> header, Lock lock, byte[] headerBytes) {
            this.header = header;
            this.lock = lock;
            this.headerBytes = headerBytes;
        }
    }

    /** Reads [in]'s header; throws IOException if it isn't a backup. */
    public static Opened readHeader(InputStream in) throws IOException {
        byte[] hb = BackupCrypto.readHeader(in);
        if (hb == null) throw new IOException("Not a backup file");
        Map<String, String> h = parseLines(hb);
        if (!FORMAT.equals(h.get("format"))) throw new IOException("Not a backup file");
        return new Opened(h, Lock.fromMap(h), hb);
    }

    /** Unpacks the backup (the rest of [in], after [readHeader]) into the
     * empty folder [into], with the backup key; checks every file against
     * the manifest. Returns the files, by path. With [into] null, only
     * checks (to make sure a backup just written can be restored). */
    public static Map<String, File> extract(InputStream in, Opened opened, byte[] backupKey, File into,
            long totalBytes, Progress progress) throws IOException, GeneralSecurityException {
        byte[] fileKey;
        try {
            fileKey = BackupCrypto.open(backupKey,
                    BackupCrypto.fromHex(opened.header.get("fileKey")), AAD_FILE);
        } catch (RuntimeException e) {
            throw new IOException("Not a backup file");
        }
        byte[] prefix = BackupCrypto.fromHex(opened.header.get("noncePrefix"));
        BackupCrypto.Decrypting dec = new BackupCrypto.Decrypting(in, fileKey, prefix, opened.headerBytes);
        Map<String, File> files = new LinkedHashMap<>();
        Map<String, String[]> listed = null;
        byte[] buf = new byte[1 << 16];
        long done = 0;
        try (ZipInputStream zip = new ZipInputStream(dec)) {
            ZipEntry e;
            Map<String, String> sums = new LinkedHashMap<>();
            Map<String, Long> sizes = new LinkedHashMap<>();
            while ((e = zip.getNextEntry()) != null) {
                String path = e.getName();
                if (listed != null) throw new IOException("Unexpected data after the list of files");
                if (MANIFEST.equals(path)) {
                    listed = parseManifest(readAll(zip));
                    continue;
                }
                checkPath(path);
                if (sums.containsKey(path)) throw new IOException("A file is in the backup twice");
                File f = into == null ? null : new File(into, path);
                File parent = f == null ? null : f.getParentFile();
                if (parent != null && !parent.isDirectory() && !parent.mkdirs()) {
                    throw new IOException("Can't make a folder");
                }
                MessageDigest sha = sha256();
                long size = 0;
                try (OutputStream o = f == null ? OutputStream.nullOutputStream() : new FileOutputStream(f)) {
                    int n;
                    while ((n = zip.read(buf)) > 0) {
                        o.write(buf, 0, n);
                        sha.update(buf, 0, n);
                        size += n;
                        done += n;
                        if (progress != null && !progress.at(done, totalBytes)) throw new IOException("stopped");
                    }
                }
                if (f != null) files.put(path, f);
                sums.put(path, BackupCrypto.toHex(sha.digest()));
                sizes.put(path, size);
            }
            // Reads to the end, so the last chunk is checked too.
            while (dec.read(buf) > 0) { /* zip's own end */ }
            if (listed == null) throw new IOException("The backup file is cut short");
            if (!listed.keySet().equals(sums.keySet())) throw new IOException("The backup's files don't match its list");
            for (Map.Entry<String, String[]> l : listed.entrySet()) {
                if (!l.getValue()[1].equals(sums.get(l.getKey()))
                        || Long.parseLong(l.getValue()[0]) != sizes.get(l.getKey())) {
                    throw new IOException("A file in the backup is damaged");
                }
            }
        }
        return files;
    }

    static Map<String, String[]> parseManifest(byte[] b) throws IOException {
        Map<String, String[]> m = new LinkedHashMap<>();
        for (String line : new String(b, StandardCharsets.UTF_8).split("\n")) {
            if (line.isEmpty()) continue;
            String[] p = line.split("\t");
            if (p.length != 3) throw new IOException("Not a backup file");
            checkPath(p[0]);
            m.put(p[0], new String[] {p[1], p[2]});
        }
        return m;
    }

    /** Only simple relative paths: nothing can be written outside the
     * restore folder. */
    static void checkPath(String path) throws IOException {
        if (path.isEmpty() || path.startsWith("/") || path.contains("\\") || path.contains("\0")) {
            throw new IOException("Not a backup file");
        }
        for (String part : path.split("/")) {
            if (part.isEmpty() || part.equals(".") || part.equals("..")) throw new IOException("Not a backup file");
        }
    }

    private static byte[] readAll(InputStream in) throws IOException {
        ByteArrayOutputStream o = new ByteArrayOutputStream();
        byte[] buf = new byte[8192];
        int n;
        while ((n = in.read(buf)) > 0) {
            o.write(buf, 0, n);
            if (o.size() > (16 << 20)) throw new IOException("Not a backup file");
        }
        return o.toByteArray();
    }

    private static MessageDigest sha256() {
        try {
            return MessageDigest.getInstance("SHA-256");
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException(e);
        }
    }

    /** Every file under [dir], with its path under [prefix]. */
    public static List<Item> folder(File dir, String prefix, boolean packed) {
        List<Item> out = new ArrayList<>();
        File[] list = dir.listFiles();
        if (list == null) return out;
        java.util.Arrays.sort(list);
        for (File f : list) {
            String path = prefix + "/" + f.getName();
            if (f.isDirectory()) out.addAll(folder(f, path, packed));
            else if (f.isFile()) out.add(new Item(path, f, packed));
        }
        return out;
    }
}
