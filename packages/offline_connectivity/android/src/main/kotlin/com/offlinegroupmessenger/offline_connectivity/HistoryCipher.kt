package com.offlinegroupmessenger.offline_connectivity

import javax.crypto.Cipher
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Versioned, authenticated envelope; keys are supplied by Android Keystore. */
internal object HistoryCipher {
    const val MAX_PLAINTEXT_BYTES = 8 * 1024 * 1024
    const val OVERHEAD = 4 + 12 + 16
    private val header = byteArrayOf(0x53, 0x43, 0x48, 1)
    private val aad = "skychat-chat-history-v1".toByteArray(Charsets.UTF_8)

    fun seal(plaintext: ByteArray, key: SecretKey): ByteArray {
        require(plaintext.size <= MAX_PLAINTEXT_BYTES) { "History is too large" }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key)
        cipher.updateAAD(header + aad)
        check(cipher.iv.size == 12)
        return header + cipher.iv + cipher.doFinal(plaintext)
    }

    fun open(envelope: ByteArray, key: SecretKey): ByteArray {
        require(envelope.size in OVERHEAD..(MAX_PLAINTEXT_BYTES + OVERHEAD)) { "Invalid history size" }
        require(envelope.copyOfRange(0, 4).contentEquals(header)) { "Unsupported history format" }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, envelope.copyOfRange(4, 16)))
        cipher.updateAAD(header + aad)
        return cipher.doFinal(envelope.copyOfRange(16, envelope.size))
    }
}
