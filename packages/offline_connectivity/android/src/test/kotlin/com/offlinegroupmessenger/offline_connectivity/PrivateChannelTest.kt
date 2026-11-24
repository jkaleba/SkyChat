package com.offlinegroupmessenger.offline_connectivity

import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayInputStream
import java.security.KeyFactory
import java.security.Signature
import java.security.cert.CertificateFactory
import java.security.spec.PKCS8EncodedKeySpec

class PrivateChannelTest {
    private fun trust(book: ContactBook, crypto: ContactCrypto) {
        val transcript = "a".repeat(64)
        book.pending(crypto.key, "Contact", transcript)
        book.approve(crypto.id, transcript)
        book.verified(crypto.id, transcript)
    }
    @Test fun proofsPinTheCertificateGroupRoleNonceAndIdentity() {
        val host = testCrypto(); val client = testCrypto(); val stranger = testCrypto()
        val hb = ContactBook(host, null) {}; val cb = ContactBook(client, null) {}
        trust(hb, client); trust(cb, host)
        val context = mapOf("role" to "client", "to" to host.id,
            "nonce" to "a".repeat(64), "certificate" to "b".repeat(64), "group" to "c".repeat(32))
        val proof = cb.signPrivateChannel(context)
        assertEquals(client.id, hb.verifyPrivateChannel(proof, context))
        for (field in listOf("nonce", "certificate", "group", "role")) {
            assertThrows(Exception::class.java) { hb.verifyPrivateChannel(proof, context + (field to "different")) }
        }
        assertThrows(Exception::class.java) {
            hb.verifyPrivateChannel(stranger.sign(context + mapOf("scope" to "ogm-private-channel-v1", "from" to client.id)), context)
        }
        val hostContext = context + mapOf("role" to "host", "to" to "")
        val hostProof = hb.signPrivateChannel(hostContext)
        assertEquals(host.id, cb.verifyPrivateChannel(hostProof, hostContext + ("from" to host.id)))
        assertThrows(Exception::class.java) { cb.verifyPrivateChannel(hostProof, hostContext + ("from" to stranger.id)) }
        cb.block(host.id)
        assertThrows(Exception::class.java) { cb.verifyPrivateChannel(hostProof, hostContext) }
        assertThrows(Exception::class.java) { cb.signPrivateChannel(context) }
    }
    @Test fun certificateIsEphemeralAndItsPrivateKeyMatches() {
        val material = PrivateChannelCertificate.create()
        val certificate = CertificateFactory.getInstance("X.509").generateCertificate(
            ByteArrayInputStream((material["certificate"] as String).toByteArray()))
        assertEquals(ContactCrypto.hash(certificate.encoded), material["fingerprint"])
        assertNotEquals(material["fingerprint"], PrivateChannelCertificate.create()["fingerprint"])
        val encoded = (material["privateKey"] as String).lineSequence()
            .filter { !it.startsWith("-----") }.joinToString("")
        val key = KeyFactory.getInstance("EC").generatePrivate(PKCS8EncodedKeySpec(
            com.nimbusds.jose.util.Base64(encoded).decode()))
        val message = "test".toByteArray()
        val signature = Signature.getInstance("SHA256withECDSA").apply { initSign(key); update(message) }.sign()
        assertTrue(Signature.getInstance("SHA256withECDSA").apply { initVerify(certificate); update(message) }.verify(signature))
    }
}
