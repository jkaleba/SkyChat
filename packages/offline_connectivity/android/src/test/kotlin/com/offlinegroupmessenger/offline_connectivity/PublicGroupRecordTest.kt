package com.offlinegroupmessenger.offline_connectivity

import org.junit.Assert.*
import org.junit.Test

class PublicGroupRecordTest {
    @Test fun publicAndPrivateMessengerRecordsAreAccepted() {
        val domain = "OfflineMessenger._ogm._tcp.local."
        assertTrue(PublicGroupRecord.accepts(domain, PublicGroupRecord.fields()))
        val sid = "a".repeat(32)
        assertTrue(PublicGroupRecord.accepts(domain, PublicGroupRecord.fields(privateGroup = true, sessionId = sid)))
        assertTrue(
            PublicGroupRecord.accepts(
                domain,
                PublicGroupRecord.fields(privateGroup = true, hostContactId = "contact-123", sessionId = sid),
            ),
        )
        assertFalse(PublicGroupRecord.accepts(domain, PublicGroupRecord.fields() + ("mode" to "secret")))
        assertFalse(PublicGroupRecord.accepts(domain, PublicGroupRecord.fields() + ("v" to "1")))
        assertFalse(PublicGroupRecord.accepts(domain, PublicGroupRecord.fields() + ("v" to "2")))
        assertFalse(PublicGroupRecord.accepts(domain, mapOf("mode" to "public")))
        assertFalse(PublicGroupRecord.accepts("Other._ogm._tcp.local.", PublicGroupRecord.fields()))
    }

    @Test fun advertisementContainsNoCredentialsOrPersonalName() {
        assertEquals(setOf("app", "v", "mode"), PublicGroupRecord.fields().keys)
        assertEquals(
            setOf("app", "v", "mode", "sid"),
            PublicGroupRecord.fields(privateGroup = true, hostContactId = "contact-123", hostName = "Alice", sessionId = "a".repeat(32)).keys,
        )
        assertEquals(
            "Alice",
            PublicGroupRecord.fields(hostName = "  Alice  ")["name"],
        )
        val record = PublicGroupRecord.fields(privateGroup = true, sessionId = "a".repeat(32))
        assertFalse(PublicGroupRecord.accepts("OfflineMessenger._ogm._tcp.local", record + ("cid" to "stable")))
        assertFalse(PublicGroupRecord.accepts("OfflineMessenger._ogm._tcp.local", record + ("name" to "Alice")))
        assertFalse(PublicGroupRecord.accepts("OfflineMessenger._ogm._tcp.local", record + ("v" to "3")))
    }
}
