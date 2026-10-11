package com.writingrecogniser

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Encrypts small secrets (the MyScript Cloud keys) with a key that lives in
 * Android's hardware-backed key store and never leaves it. A copy of the
 * app's files (e.g. from a rooted or transferred device) can't be decrypted
 * elsewhere; on a new device the user enters the keys again.
 *
 * Channel "writing_recogniser/secrets":
 *  - seal(text) -> base64 of IV + AES-256-GCM ciphertext
 *  - open(sealed) -> text, or null if it can't be decrypted (key gone)
 */
class SecretBox(messenger: BinaryMessenger) {
    init {
        MethodChannel(messenger, "writing_recogniser/secrets").setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "seal" -> result.success(seal(call.argument<String>("text")!!))
                    "open" -> result.success(open(call.argument<String>("sealed")!!))
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("secrets", e.javaClass.simpleName, null)
            }
        }
    }

    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        gen.init(
            KeyGenParameterSpec.Builder(
                ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build(),
        )
        return gen.generateKey()
    }

    private fun seal(text: String): String {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val out = cipher.iv + cipher.doFinal(text.toByteArray(Charsets.UTF_8))
        return Base64.encodeToString(out, Base64.NO_WRAP)
    }

    private fun open(sealed: String): String? = try {
        val bytes = Base64.decode(sealed, Base64.NO_WRAP)
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, bytes, 0, IV_BYTES))
        String(cipher.doFinal(bytes, IV_BYTES, bytes.size - IV_BYTES), Charsets.UTF_8)
    } catch (e: Exception) {
        null
    }

    private companion object {
        const val ALIAS = "writing_recogniser.secrets"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val IV_BYTES = 12
    }
}
