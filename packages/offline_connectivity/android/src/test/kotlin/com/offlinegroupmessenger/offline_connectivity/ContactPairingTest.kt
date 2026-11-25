package com.offlinegroupmessenger.offline_connectivity

import org.junit.Assert.*
import org.junit.Test

class ContactPairingTest {
    @Test fun transcriptSerializationMatchesTheIosJsonContract() {
        // Names intentionally exercise Unicode and slash escaping across platforms.
        val fields = listOf("ogm-nfc-contact-v1", "key", "A/B Żółw 👋", "nonce", "hostkey", "Host", "nonce")
        assertEquals("""{"fields":["ogm-nfc-contact-v1","key","A/B Żółw 👋","nonce","hostkey","Host","nonce"]}""",
            com.nimbusds.jose.util.JSONObjectUtils.toJSONString(mapOf("fields" to fields)))
    }

    @Test fun iphoneTwoTapExchangeKeepsApprovalAcrossApduReselection() {
        val a = testCrypto(); val b = testCrypto()
        val readerBook = ContactBook(a, null) {}; val hostBook = ContactBook(b, null) {}
        val reader = ContactPairing(readerBook, "iPhone", true)
        val host = ContactPairing(hostBook, "Android", false)
        val apdu = ContactApdu { request ->
            com.nimbusds.jose.util.JSONObjectUtils.toJSONString(host.handle(
                com.nimbusds.jose.util.JSONObjectUtils.parse(request.toString(Charsets.UTF_8))))
                .toByteArray(Charsets.UTF_8)
        }
        fun exchange(value: Map<String, Any?>): Map<String, Any?> = com.nimbusds.jose.util.JSONObjectUtils.parse(
            ContactApdu.request(com.nimbusds.jose.util.JSONObjectUtils.toJSONString(value).toByteArray(Charsets.UTF_8), apdu::respond)
                .toString(Charsets.UTF_8))
        assertArrayEquals(byteArrayOf(0x90.toByte(), 0), apdu.respond(ContactApdu.SELECT + byteArrayOf(0)))
        assertEquals("ready", exchange(reader.receiveHostProof(exchange(reader.hello())))["type"])
        apdu.reset() // iOS closes its system sheet so both users can compare codes.
        assertEquals("pending", hostBook.entry(a.id)!!["state"])
        host.approve(); reader.approve()
        assertArrayEquals(byteArrayOf(0x90.toByte(), 0), apdu.respond(ContactApdu.SELECT + byteArrayOf(0)))
        reader.receiveConfirmation(exchange(reader.poll()))
        assertEquals("verified", readerBook.entry(b.id)!!["state"])
        assertEquals("verified", hostBook.entry(a.id)!!["state"])
    }

    @Test fun mutualProofAndBothApprovalsAreRequired() {
        val a = testCrypto(); val b = testCrypto()
        val ab = ContactBook(a, null) {}; val bb = ContactBook(b, null) {}
        val r = ContactPairing(ab, "Alice", true); val h = ContactPairing(bb, "Bob", false)
        h.receiveReaderProof(r.receiveHostProof(h.receiveHello(r.hello())))
        assertEquals(r.status()["code"], h.status()["code"])
        r.approve(); r.receiveConfirmation(h.receiveConfirmation(r.poll()))
        assertEquals("pending", ab.entry(b.id)!!["state"])
        assertEquals("pending", bb.entry(a.id)!!["state"])
        h.approve(); r.receiveConfirmation(h.receiveConfirmation(r.poll()))
        assertEquals("verified", ab.entry(b.id)!!["state"])
        assertEquals("verified", bb.entry(a.id)!!["state"])
    }
    @Test fun staleProofAndConfirmationCannotCompleteANewAttempt() {
        val a = testCrypto(); val b = testCrypto()
        val ab = ContactBook(a, null) {}; val bb = ContactBook(b, null) {}
        val oldReader = ContactPairing(ab, "Alice", true); val oldHost = ContactPairing(bb, "Bob", false)
        val staleProof = oldHost.receiveHello(oldReader.hello())
        oldHost.receiveReaderProof(oldReader.receiveHostProof(staleProof)); oldReader.approve()
        val staleReceipt = oldReader.poll()
        val r = ContactPairing(ab, "Alice", true); val h = ContactPairing(bb, "Bob", false)
        assertThrows(Exception::class.java) { ContactPairing(ab, "Alice", true).receiveHostProof(staleProof) }
        h.receiveReaderProof(r.receiveHostProof(h.receiveHello(r.hello())))
        assertThrows(Exception::class.java) { h.receiveConfirmation(staleReceipt) }
        h.stop(); assertThrows(Exception::class.java) { h.approve() }
    }
    @Test fun interruptedPairingRestartsWithoutDuplicatesOrImplicitApproval() {
        val a = testCrypto(); val b = testCrypto(); var disk: String? = null
        val book = ContactBook(a, null) { disk = it }; val other = ContactBook(b, null) {}
        val r = ContactPairing(book, "Alice", true); val h = ContactPairing(other, "Bob", false)
        h.receiveReaderProof(r.receiveHostProof(h.receiveHello(r.hello()))); r.approve(); r.stop()
        val recovered = ContactBook(a, disk) { disk = it }
        val retry = ContactPairing(recovered, "Alice", true); val host = ContactPairing(other, "Bob", false)
        host.receiveReaderProof(retry.receiveHostProof(host.receiveHello(retry.hello())))
        assertEquals(false, retry.status()["approved"])
        assertEquals(1, (recovered.snapshot()["contacts"] as List<*>).size)
    }
    @Test fun apduBoundsAndChunkedRoundTrip() {
        val protocol = ContactApdu { it.reversedArray() }
        assertArrayEquals(byteArrayOf(0x90.toByte(), 0), protocol.respond(ContactApdu.SELECT))
        val data = ByteArray(8192) { it.toByte() }
        assertArrayEquals(data.reversedArray(), ContactApdu.request(data, protocol::respond))
        assertThrows(Exception::class.java) { ContactApdu.request(ByteArray(8193), protocol::respond) }
        protocol.reset()
        assertThrows(Exception::class.java) { ContactApdu.request(data, protocol::respond) }
        protocol.respond(ContactApdu.SELECT)
        assertArrayEquals(byteArrayOf(0x69, 0x85.toByte()), protocol.respond(byteArrayOf(0, 0x20, 0, 1, 1, 5)))
    }
}
