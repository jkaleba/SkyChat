package com.offlinegroupmessenger.offline_connectivity

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.KeyStore
import java.util.concurrent.Executors
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey

/** One serialized worker owns the file; no plaintext or backup is exported. */
internal class ChatHistoryBridge(context: Context, messenger: BinaryMessenger) {
    private companion object {
        // Preserve operation order across engine/activity recreation as well.
        val worker = Executors.newSingleThreadExecutor()
    }
    private val channel = MethodChannel(messenger, "com.offlinegroupmessenger/history")
    private val main = Handler(Looper.getMainLooper())
    private val file = AtomicFile(File(context.noBackupFilesDir, "chat-history-v1.enc"))
    private val alias = "ogm.chat.history.v1"
    @Volatile private var closed = false

    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method !in setOf("read", "write", "clear")) {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val raw = call.argument<String>("data")
            worker.execute {
                try {
                    val value: String? = when (call.method) {
                        "read" -> read()
                        "write" -> {
                            requireNotNull(raw) { "Missing history" }
                            write(raw)
                            null
                        }
                        else -> {
                            // This affects saved chats only, not NFC contacts or identity.
                            file.delete()
                            check(!hasFile()) { "Could not delete history" }
                            KeyStore.getInstance("AndroidKeyStore").apply {
                                load(null)
                                deleteEntry(alias)
                            }
                            null
                        }
                    }
                    main.post { if (!closed) result.success(value) }
                } catch (_: Exception) {
                    main.post {
                        if (!closed) result.error("history_storage_failed",
                            "Saved conversations could not be opened or saved. Retry, or delete saved history to reset it.", null)
                    }
                }
            }
        }
    }

    private fun hasFile() = file.baseFile.exists() || File(file.baseFile.path + ".bak").exists()

    private fun key(): SecretKey {
        val keys = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        if (!keys.containsAlias(alias)) {
            // An existing encrypted archive must never be replaced with a fresh key.
            check(!hasFile()) { "History key is unavailable" }
            KeyGenerator.getInstance("AES", "AndroidKeyStore").apply {
                init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                    .setKeySize(256).setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
            }.generateKey()
        }
        return keys.getKey(alias, null) as SecretKey
    }

    private fun read(): String? {
        if (!hasFile()) return null
        val secret = key()
        val encrypted = file.openRead().use { input ->
            require(input.channel.size() in HistoryCipher.OVERHEAD.toLong()..
                (HistoryCipher.MAX_PLAINTEXT_BYTES + HistoryCipher.OVERHEAD).toLong())
            input.readBytes()
        }
        return HistoryCipher.open(encrypted, secret).toString(Charsets.UTF_8)
    }

    private fun write(raw: String) {
        val encrypted = HistoryCipher.seal(raw.toByteArray(Charsets.UTF_8), key())
        val stream = file.startWrite()
        try {
            stream.write(encrypted)
            file.finishWrite(stream)
        } catch (error: Exception) {
            file.failWrite(stream)
            throw error
        }
    }

    fun close() {
        channel.setMethodCallHandler(null)
        closed = true
        // The process-wide worker finishes accepted writes before a new
        // engine's read/delete can run. Its lifetime belongs to the process.
    }
}
