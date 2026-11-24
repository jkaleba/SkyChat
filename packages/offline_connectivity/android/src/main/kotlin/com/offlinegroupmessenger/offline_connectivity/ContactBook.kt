package com.offlinegroupmessenger.offline_connectivity

import com.nimbusds.jose.util.JSONObjectUtils

/** Serialized, transactional state: persist a copy before publishing it in memory. */
internal class ContactBook(
    val crypto: ContactCrypto,
    saved: String?,
    private val persist: (String) -> Unit,
) {
    private var records = linkedMapOf<String, Map<String, Any?>>()
    init {
        if (saved != null) {
            val root = JSONObjectUtils.parse(saved)
            require(root["v"] == 1L && root["identity"] == crypto.key)
            val list = root["contacts"] as List<*>
            require(list.size <= 256)
            for (raw in list) {
                @Suppress("UNCHECKED_CAST") val entry = raw as Map<String, Any?>
                val id = entry["id"] as String
                require(id == ContactCrypto.fingerprint(entry["key"] as String) && id != crypto.id)
                require(!records.containsKey(id))
                require(entry["state"] in listOf("pending", "verified", "blocked"))
                name(entry["name"] as String)
                records[id] = entry.toMap()
            }
        }
    }
    @Synchronized fun snapshot(): Map<String, Any?> = mapOf(
        "identity" to crypto.id, "contacts" to records.values.map { it.toMap() })
    @Synchronized fun entry(id: String): Map<String, Any?>? = records[id]?.toMap()
    @Synchronized private fun update(id: String, entry: Map<String, Any?>?) {
        val next = LinkedHashMap(records)
        if (entry == null) next.remove(id) else next[id] = entry
        require(next.size <= 256) { "Contact limit reached" }
        persist(JSONObjectUtils.toJSONString(mapOf("v" to 1, "identity" to crypto.key, "contacts" to next.values.toList())))
        records = next
    }
    @Synchronized fun pending(key: String, displayName: String, transcript: String) {
        val id = ContactCrypto.fingerprint(key)
        require(id != crypto.id && transcript.matches(Regex("[a-f0-9]{64}")))
        val old = records[id]
        check(old?.get("state") != "blocked") { "Contact is blocked" }
        // An interrupted repeat must not revoke an already verified contact.
        if (old?.get("state") == "verified") return
        update(id, mapOf("id" to id, "key" to key, "name" to name(displayName),
            "state" to "pending", "transcript" to transcript, "approved" to false))
    }
    @Synchronized fun approve(id: String, transcript: String) {
        val old = requireNotNull(records[id])
        check(old["state"] != "blocked")
        if (old["state"] == "verified") return
        require(old["transcript"] == transcript)
        update(id, old + ("approved" to true))
    }
    @Synchronized fun verified(id: String, transcript: String) {
        val old = requireNotNull(records[id])
        check(old["state"] != "blocked")
        if (old["state"] == "verified") return
        require(old["transcript"] == transcript && old["approved"] == true)
        update(id, old.filterKeys { it !in setOf("transcript", "approved") } + ("state" to "verified"))
    }
    @Synchronized fun rename(id: String, value: String) = update(id, requireNotNull(records[id]) + ("name" to name(value)))
    @Synchronized fun block(id: String) = update(id, requireNotNull(records[id]).filterKeys {
        it !in setOf("transcript", "approved") } + ("state" to "blocked"))
    // Unblocking intentionally requires a fresh NFC enrollment, not silent reactivation.
    @Synchronized fun delete(id: String) = update(id, null)
    @Synchronized fun signCall(body: Map<String, Any?>): String {
        val to = body["to"] as String
        require(records[to]?.get("state") == "verified")
        val payload = body + mapOf("scope" to "ogm-call-v1", "from" to crypto.id)
        require(JSONObjectUtils.toJSONString(payload).toByteArray().size <= 18000)
        return crypto.sign(payload)
    }
    @Synchronized fun verifyCall(token: String): Map<String, Any?> {
        require(token.length <= 24000)
        val untrusted = JSONObjectUtils.parse(com.nimbusds.jose.JWSObject.parse(token).payload.toString())
        val from = untrusted["from"] as String
        val contact = requireNotNull(records[from])
        require(contact["state"] == "verified")
        val payload = ContactCrypto.verify(token, contact["key"] as String)
        require(payload["scope"] == "ogm-call-v1" && payload["from"] == from && payload["to"] == crypto.id)
        return payload
    }
    @Synchronized fun signGroupAuth(to: String, nonce: String): String {
        require(records[to]?.get("state") == "verified")
        require(nonce.length in 16..128)
        return crypto.sign(mapOf("scope" to "ogm-group-v1", "from" to crypto.id, "to" to to, "nonce" to nonce))
    }
    @Synchronized fun verifyGroupAuth(token: String, expectedNonce: String): String {
        require(token.length <= 24000)
        val untrusted = JSONObjectUtils.parse(com.nimbusds.jose.JWSObject.parse(token).payload.toString())
        val from = untrusted["from"] as String
        val contact = requireNotNull(records[from])
        require(contact["state"] == "verified")
        val payload = ContactCrypto.verify(token, contact["key"] as String)
        require(payload["scope"] == "ogm-group-v1" && payload["from"] == from && payload["to"] == crypto.id &&
            payload["nonce"] == expectedNonce)
        return from
    }
    /** Bind both NFC identities to this TLS certificate, group, role and fresh challenge. */
    @Synchronized fun signPrivateChannel(body: Map<String, Any?>): String {
        val role = body["role"] as String
        val to = body["to"] as String
        require(role in setOf("host", "client"))
        require((body["nonce"] as String).matches(Regex("[a-f0-9]{64}")))
        require((body["certificate"] as String).matches(Regex("[a-f0-9]{64}")))
        require((body["group"] as String).matches(Regex("[a-f0-9]{32}")))
        if (role == "client") require(records[to]?.get("state") == "verified")
        else require(to.isEmpty())
        return crypto.sign(mapOf(
            "scope" to "ogm-private-channel-v1", "from" to crypto.id, "to" to to,
            "role" to role, "nonce" to body["nonce"], "certificate" to body["certificate"], "group" to body["group"]
        ))
    }
    @Synchronized fun verifyPrivateChannel(token: String, expected: Map<String, Any?>): String {
        require(token.length <= 24000)
        val untrusted = JSONObjectUtils.parse(com.nimbusds.jose.JWSObject.parse(token).payload.toString())
        val from = untrusted["from"] as String
        val contact = requireNotNull(records[from])
        require(contact["state"] == "verified")
        val payload = ContactCrypto.verify(token, contact["key"] as String)
        val role = expected["role"] as String
        require(role in setOf("host", "client"))
        require(payload.keys == setOf("scope", "from", "to", "role", "nonce", "certificate", "group"))
        require(payload["scope"] == "ogm-private-channel-v1" && payload["from"] == from)
        for (field in listOf("role", "nonce", "certificate", "group")) require(payload[field] == expected[field])
        if (role == "client") require(payload["to"] == crypto.id)
        else {
            require(payload["to"] == "")
            val pinned = expected["from"] as? String
            if (pinned != null) require(from == pinned)
        }
        return from
    }
    companion object {
        fun name(value: String): String = value.trim().also {
            require(it.length in 1..32 && it.none { c -> c.code < 32 || c.code == 127 })
        }
    }
}
