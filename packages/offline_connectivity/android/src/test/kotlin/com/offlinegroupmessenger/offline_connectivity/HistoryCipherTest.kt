package com.offlinegroupmessenger.offline_connectivity

import org.junit.Assert.*
import org.junit.Test
import java.security.GeneralSecurityException
import javax.crypto.KeyGenerator

class HistoryCipherTest {
    private fun key() = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()

    @Test fun privateHistoryRoundTripAndUniqueNonces() {
        val key = key()
        val text = "Private conversation: zażółć gęślą 📨".toByteArray(Charsets.UTF_8)
        val first = HistoryCipher.seal(text, key)
        val second = HistoryCipher.seal(text, key)
        assertArrayEquals(text, HistoryCipher.open(first, key))
        assertFalse(first.contentEquals(second))
        assertFalse(first.toString(Charsets.UTF_8).contains("Private conversation"))
    }

    @Test(expected = GeneralSecurityException::class) fun rejectsModifiedCiphertext() {
        val key = key()
        val encrypted = HistoryCipher.seal("message".toByteArray(), key)
        encrypted[encrypted.lastIndex] = (encrypted.last().toInt() xor 1).toByte()
        HistoryCipher.open(encrypted, key)
    }

    @Test(expected = GeneralSecurityException::class) fun rejectsWrongKey() {
        HistoryCipher.open(HistoryCipher.seal("message".toByteArray(), key()), key())
    }

    @Test(expected = GeneralSecurityException::class) fun rejectsModifiedNonce() {
        val key = key()
        val encrypted = HistoryCipher.seal("message".toByteArray(), key)
        encrypted[4] = (encrypted[4].toInt() xor 1).toByte()
        HistoryCipher.open(encrypted, key)
    }

    @Test(expected = IllegalArgumentException::class) fun rejectsUnknownVersion() {
        val key = key()
        val encrypted = HistoryCipher.seal("message".toByteArray(), key)
        encrypted[3] = 2
        HistoryCipher.open(encrypted, key)
    }

    @Test(expected = IllegalArgumentException::class) fun rejectsTruncatedFile() {
        HistoryCipher.open(ByteArray(HistoryCipher.OVERHEAD - 1), key())
    }

    @Test(expected = IllegalArgumentException::class) fun rejectsOversizedHistory() {
        HistoryCipher.seal(ByteArray(HistoryCipher.MAX_PLAINTEXT_BYTES + 1), key())
    }
}
