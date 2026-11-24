package com.offlinegroupmessenger.offline_connectivity

/** Service records belong in the app's discovery list for public and private groups. */
internal object PublicGroupRecord {
    const val INSTANCE = "OfflineMessenger"
    const val TYPE = "_ogm._tcp"
    fun accepts(domain: String, record: Map<String, String>): Boolean =
        domain.trimEnd('.').equals("$INSTANCE.$TYPE.local", ignoreCase = true) &&
            record["app"] == "offline-group-messenger" &&
            ((record["mode"] == "public" && record["v"] == "3") ||
                (record["mode"] == "private" && record["v"] == "4" &&
                    record["sid"]?.matches(Regex("[a-f0-9]{32}")) == true &&
                    "cid" !in record && "name" !in record))

    fun fields(
        privateGroup: Boolean = false,
        hostContactId: String? = null,
        hostName: String? = null,
        sessionId: String? = null
    ): Map<String, String> = buildMap {
        put("app", "offline-group-messenger")
        put("v", if (privateGroup) "4" else "3")
        put("mode", if (privateGroup) "private" else "public")
        if (privateGroup) {
            require(sessionId?.matches(Regex("[a-f0-9]{32}")) == true)
            put("sid", requireNotNull(sessionId))
        }
        val cleanName = hostName?.trim()?.take(32)
        if (!privateGroup && !cleanName.isNullOrEmpty()) {
            put("name", cleanName)
        }
    }
}
