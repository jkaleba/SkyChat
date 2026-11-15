package com.offlinegroupmessenger.offline_connectivity

/** Service records belong in the app's discovery list for public and private groups. */
internal object PublicGroupRecord {
    const val INSTANCE = "OfflineMessenger"
    const val TYPE = "_ogm._tcp"
    fun accepts(domain: String, record: Map<String, String>): Boolean =
        domain.trimEnd('.').equals("$INSTANCE.$TYPE.local", ignoreCase = true) &&
            record["app"] == "offline-group-messenger" &&
            record["v"] == "3" &&
            (record["mode"] == "public" || record["mode"] == "private")

    fun fields(
        privateGroup: Boolean = false,
        hostContactId: String? = null,
        hostName: String? = null
    ): Map<String, String> = buildMap {
        put("app", "offline-group-messenger")
        put("v", "3")
        put("mode", if (privateGroup) "private" else "public")
        if (privateGroup && !hostContactId.isNullOrBlank()) {
            put("cid", hostContactId)
        }
        val cleanName = hostName?.trim()?.take(32)
        if (!cleanName.isNullOrEmpty()) {
            put("name", cleanName)
        }
    }
}
