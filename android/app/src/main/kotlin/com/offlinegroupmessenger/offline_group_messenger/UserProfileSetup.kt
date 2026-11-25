package com.offlinegroupmessenger.offline_group_messenger

/** Display names share the chat protocol's 32 UTF-16 code-unit limit. */
internal object UserProfileSetup {
    fun normalize(raw: String?): String? {
        val name = raw?.trim() ?: return null
        if (name.length !in 1..32) return null
        if (name.any { it.isISOControl() || it == '\u2028' || it == '\u2029' }) return null
        return name
    }
}
