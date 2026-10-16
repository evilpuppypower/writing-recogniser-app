package com.writingrecogniser;

import java.io.ByteArrayOutputStream;
import java.io.DataInputStream;
import java.io.EOFException;
import java.io.FilterOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.security.SecureRandom;
import java.util.Arrays;

import javax.crypto.AEADBadTagException;
import javax.crypto.Cipher;
import javax.crypto.SecretKeyFactory;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.PBEKeySpec;
import javax.crypto.spec.SecretKeySpec;

/**
 * The backup file's encryption (owner, 2026-10-16: backups are always
 * encrypted, with a password and a recovery key). Plain Java with only the
 * standard javax.crypto algorithms, so it can be tested off the tablet and
 * read again on Windows later.
 *
 * Keys ("envelope encryption"):
 *  - the backup key (32 random bytes) is made once and kept on the tablet,
 *    sealed by Android's key store, so scheduled backups need no password;
 *  - each backup file has its own file key, sealed with the backup key;
 *  - the backup key is sealed twice in every file's header: with a key from
 *    the password (PBKDF2-HMAC-SHA256) and with the recovery key, so either
 *    opens any backup, on any tablet.
 *
 * File: "WRBK" + version byte + header length (4 bytes) + header (UTF-8
 * JSON, written by the caller) + chunks. Each chunk: length (4 bytes, top
 * bit set on the last chunk) + AES-256-GCM of up to 1 MiB, its nonce the
 * file's nonce prefix + chunk number, and the header, chunk number and
 * last-chunk flag bound in as associated data, so chunks can't be dropped,
 * reordered, cut short or moved to another file.
 */
public final class BackupCrypto {
    private BackupCrypto() {}

    public static final byte[] MAGIC = {'W', 'R', 'B', 'K'};
    public static final int VERSION = 1;
    public static final int CHUNK = 1 << 20;
    public static final int PASSWORD_ITERATIONS = 600_000;
    private static final int TAG_BITS = 128;
    private static final SecureRandom RANDOM = new SecureRandom();

    public static byte[] random(int n) {
        byte[] b = new byte[n];
        RANDOM.nextBytes(b);
        return b;
    }

    /** A key from [password]: PBKDF2-HMAC-SHA256, 32 bytes. */
    public static byte[] passwordKey(char[] password, byte[] salt, int iterations)
            throws GeneralSecurityException {
        PBEKeySpec spec = new PBEKeySpec(password, salt, iterations, 256);
        try {
            return SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256")
                    .generateSecret(spec).getEncoded();
        } finally {
            spec.clearPassword();
        }
    }

    /** A key from the recovery key's 20 random bytes (one PBKDF2 round is
     * enough: they're random, not guessable). */
    public static byte[] recoveryKey(byte[] recovery, byte[] salt) throws GeneralSecurityException {
        char[] hex = toHex(recovery).toCharArray();
        try {
            return passwordKey(hex, salt, 1);
        } finally {
            Arrays.fill(hex, '\0');
        }
    }

    /** [secret] sealed with [key]: nonce (12) + AES-GCM ciphertext and tag. */
    public static byte[] seal(byte[] key, byte[] secret, byte[] aad) throws GeneralSecurityException {
        byte[] nonce = random(12);
        Cipher c = Cipher.getInstance("AES/GCM/NoPadding");
        c.init(Cipher.ENCRYPT_MODE, new SecretKeySpec(key, "AES"), new GCMParameterSpec(TAG_BITS, nonce));
        if (aad != null) c.updateAAD(aad);
        byte[] body = c.doFinal(secret);
        byte[] out = new byte[12 + body.length];
        System.arraycopy(nonce, 0, out, 0, 12);
        System.arraycopy(body, 0, out, 12, body.length);
        return out;
    }

    /** [sealed] opened with [key]; throws AEADBadTagException if the key is
     * wrong or it was changed. */
    public static byte[] open(byte[] key, byte[] sealed, byte[] aad) throws GeneralSecurityException {
        if (sealed.length < 12 + 16) throw new AEADBadTagException("too short");
        Cipher c = Cipher.getInstance("AES/GCM/NoPadding");
        c.init(Cipher.DECRYPT_MODE, new SecretKeySpec(key, "AES"),
                new GCMParameterSpec(TAG_BITS, sealed, 0, 12));
        if (aad != null) c.updateAAD(aad);
        return c.doFinal(sealed, 12, sealed.length - 12);
    }

    /** Writes the start of a backup file: magic, version and [header]. */
    public static void writeHeader(OutputStream out, byte[] header) throws IOException {
        out.write(MAGIC);
        out.write(VERSION);
        out.write(ByteBuffer.allocate(4).putInt(header.length).array());
        out.write(header);
    }

    /** Reads the header of a backup file (null if it isn't one). */
    public static byte[] readHeader(InputStream in) throws IOException {
        DataInputStream d = new DataInputStream(in);
        byte[] magic = new byte[4];
        try {
            d.readFully(magic);
        } catch (EOFException e) {
            return null;
        }
        if (!Arrays.equals(magic, MAGIC)) return null;
        int version = d.read();
        if (version != VERSION) throw new IOException("Made by a newer version of the app");
        int n = d.readInt();
        if (n < 0 || n > (1 << 20)) throw new IOException("Not a backup file");
        byte[] header = new byte[n];
        d.readFully(header);
        return header;
    }

    private static byte[] chunkAad(byte[] header, long index, boolean last) {
        return ByteBuffer.allocate(header.length + 9)
                .put(header).putLong(index).put((byte) (last ? 1 : 0)).array();
    }

    private static byte[] chunkNonce(byte[] prefix, long index) {
        return ByteBuffer.allocate(12).put(prefix, 0, 4).putLong(index).array();
    }

    /** Encrypts everything written to it in chunks, after the header has
     * been written to [out]; [close] writes the last chunk. */
    public static final class Encrypting extends FilterOutputStream {
        private final SecretKeySpec key;
        private final byte[] prefix;
        private final byte[] header;
        private final byte[] buf = new byte[CHUNK];
        private int used = 0;
        private long index = 0;
        private boolean closed = false;

        /** [noncePrefix]: 4 random bytes, kept in the header. */
        public Encrypting(OutputStream out, byte[] fileKey, byte[] noncePrefix, byte[] header) {
            super(out);
            this.key = new SecretKeySpec(fileKey, "AES");
            this.prefix = noncePrefix.clone();
            this.header = header.clone();
        }

        @Override public void write(int b) throws IOException {
            write(new byte[] {(byte) b}, 0, 1);
        }

        @Override public void write(byte[] b, int off, int len) throws IOException {
            while (len > 0) {
                if (used == CHUNK) flushChunk(false);
                int n = Math.min(len, CHUNK - used);
                System.arraycopy(b, off, buf, used, n);
                used += n;
                off += n;
                len -= n;
            }
        }

        private void flushChunk(boolean last) throws IOException {
            try {
                Cipher c = Cipher.getInstance("AES/GCM/NoPadding");
                c.init(Cipher.ENCRYPT_MODE, key, new GCMParameterSpec(TAG_BITS, chunkNonce(prefix, index)));
                c.updateAAD(chunkAad(header, index, last));
                byte[] body = c.doFinal(buf, 0, used);
                int len = body.length | (last ? 0x80000000 : 0);
                out.write(ByteBuffer.allocate(4).putInt(len).array());
                out.write(body);
            } catch (GeneralSecurityException e) {
                throw new IOException(e);
            }
            index++;
            used = 0;
        }

        @Override public void flush() throws IOException {
            out.flush();
        }

        @Override public void close() throws IOException {
            if (closed) return;
            closed = true;
            flushChunk(true);
            out.close();
        }
    }

    /** Reads and checks the chunks after the header; throws IOException if
     * the key is wrong or anything was changed, cut short or added. */
    public static final class Decrypting extends InputStream {
        private final DataInputStream in;
        private final SecretKeySpec key;
        private final byte[] prefix;
        private final byte[] header;
        private byte[] chunk = new byte[0];
        private int pos = 0;
        private long index = 0;
        private boolean done = false;

        public Decrypting(InputStream in, byte[] fileKey, byte[] noncePrefix, byte[] header) {
            this.in = new DataInputStream(in);
            this.key = new SecretKeySpec(fileKey, "AES");
            this.prefix = noncePrefix.clone();
            this.header = header.clone();
        }

        private boolean next() throws IOException {
            if (done) return false;
            int raw;
            try {
                raw = in.readInt();
            } catch (EOFException e) {
                throw new IOException("The backup file is cut short");
            }
            boolean last = (raw & 0x80000000) != 0;
            int len = raw & 0x7fffffff;
            if (len < 16 || len > CHUNK + 16) throw new IOException("Not a backup file");
            byte[] body = new byte[len];
            try {
                in.readFully(body);
            } catch (EOFException e) {
                throw new IOException("The backup file is cut short");
            }
            try {
                Cipher c = Cipher.getInstance("AES/GCM/NoPadding");
                c.init(Cipher.DECRYPT_MODE, key, new GCMParameterSpec(TAG_BITS, chunkNonce(prefix, index)));
                c.updateAAD(chunkAad(header, index, last));
                chunk = c.doFinal(body);
            } catch (GeneralSecurityException e) {
                throw new IOException("The backup file is damaged or the key is wrong", e);
            }
            pos = 0;
            index++;
            if (last) {
                done = true;
                if (in.read() != -1) throw new IOException("Unexpected data after the backup");
            }
            return true;
        }

        @Override public int read() throws IOException {
            byte[] one = new byte[1];
            int n = read(one, 0, 1);
            return n <= 0 ? -1 : one[0] & 0xff;
        }

        @Override public int read(byte[] b, int off, int len) throws IOException {
            if (len == 0) return 0;
            while (pos >= chunk.length) {
                if (!next()) return -1;
            }
            int n = Math.min(len, chunk.length - pos);
            System.arraycopy(chunk, pos, b, off, n);
            pos += n;
            return n;
        }

        @Override public void close() throws IOException {
            in.close();
        }
    }

    public static String toHex(byte[] b) {
        StringBuilder s = new StringBuilder();
        for (byte x : b) s.append(String.format("%02x", x));
        return s.toString();
    }

    public static byte[] fromHex(String s) {
        byte[] out = new byte[s.length() / 2];
        for (int i = 0; i < out.length; i++) {
            out[i] = (byte) Integer.parseInt(s.substring(2 * i, 2 * i + 2), 16);
        }
        return out;
    }

    /** The recovery key as the user writes it down: 32 letters and digits (20 random bytes)
     * in groups of 4, without look-alikes (Crockford base 32). */
    public static String recoveryText(byte[] recovery) {
        final String alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
        StringBuilder s = new StringBuilder();
        int bits = 0, value = 0;
        for (byte x : recovery) {
            value = (value << 8) | (x & 0xff);
            bits += 8;
            while (bits >= 5) {
                s.append(alphabet.charAt((value >> (bits - 5)) & 31));
                bits -= 5;
            }
        }
        if (bits > 0) s.append(alphabet.charAt((value << (5 - bits)) & 31));
        StringBuilder grouped = new StringBuilder();
        for (int i = 0; i < s.length(); i++) {
            if (i > 0 && i % 4 == 0) grouped.append('-');
            grouped.append(s.charAt(i));
        }
        return grouped.toString();
    }

    /** [text] typed back (any case, spaces or dashes; O read as 0, I and L
     * as 1); null if it can't be a recovery key of [bytes] bytes. */
    public static byte[] recoveryBytes(String text, int bytes) {
        final String alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
        String t = text.toUpperCase().replaceAll("[\\s-]", "")
                .replace('O', '0').replace('I', '1').replace('L', '1');
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        int bits = 0, value = 0;
        for (int i = 0; i < t.length(); i++) {
            int v = alphabet.indexOf(t.charAt(i));
            if (v < 0) return null;
            value = (value << 5) | v;
            bits += 5;
            if (bits >= 8) {
                out.write((value >> (bits - 8)) & 0xff);
                bits -= 8;
            }
        }
        byte[] b = out.toByteArray();
        return b.length == bytes ? b : null;
    }

    public static byte[] utf8(String s) {
        return s.getBytes(StandardCharsets.UTF_8);
    }
}
