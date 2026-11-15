package com.offlinegroupmessenger.offline_connectivity

import org.junit.Assert.*
import org.junit.Test

class PublicGroupRecordTest {
    @Test fun publicAndPrivateMessengerRecordsAreAccepted() {
        val domain = "OfflineMessenger._ogm._tcp.local."
        assertTrue(PublicGroupRecord.accepts(domain, PublicGroupRecord.fields()))
        assertTrue(PublicGroupRecord.accepts(domain, PublicGroupRecord.fields(privateGroup = true)))
        assertTrue(
            PublicGroupRecord.accepts(
                domain,
                PublicGroupRecord.fields(privateGroup = true, hostContactId = "contact-123"),
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
            setOf("app", "v", "mode", "cid"),
            PublicGroupRecord.fields(privateGroup = true, hostContactId = "contact-123").keys,
        )
        assertEquals(
            "Alice",
            PublicGroupRecord.fields(hostName = "  Alice  ")["name"],
        )
    }
}
