package com.offlinegroupmessenger.offline_group_messenger

import org.junit.Assert.*
import org.junit.Test

class UserProfileSetupTest {
    @Test fun acceptsAndNormalizesDisplayNames() {
        assertEquals("Janek", UserProfileSetup.normalize("  Janek  "))
        assertEquals("Żaneta 📨", UserProfileSetup.normalize("Żaneta 📨"))
        assertEquals("Guest", UserProfileSetup.normalize("Guest"))
    }

    @Test fun emptyOrMissingNamesRequireSetup() {
        assertNull(UserProfileSetup.normalize(null))
        assertNull(UserProfileSetup.normalize(""))
        assertNull(UserProfileSetup.normalize(" \t\n "))
    }

    @Test fun rejectsNamesThatCannotFitTheChatProtocol() {
        assertEquals("a".repeat(32), UserProfileSetup.normalize("a".repeat(32)))
        assertNull(UserProfileSetup.normalize("a".repeat(33)))
        assertNull(UserProfileSetup.normalize("📨".repeat(17)))
    }

    @Test fun rejectsControlCharactersAndMultilineNames() {
        for (value in listOf("A\nB", "A\u0000B", "A\u007fB", "A\u0085B", "A\u2028B", "A\u2029B")) {
            assertNull(value, UserProfileSetup.normalize(value))
        }
    }
}
