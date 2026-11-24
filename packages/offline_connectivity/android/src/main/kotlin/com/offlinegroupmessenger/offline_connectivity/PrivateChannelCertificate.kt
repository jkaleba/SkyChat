package com.offlinegroupmessenger.offline_connectivity

import org.bouncycastle.asn1.x500.X500Name
import org.bouncycastle.asn1.x509.BasicConstraints
import org.bouncycastle.asn1.x509.Extension
import org.bouncycastle.asn1.x509.KeyUsage
import org.bouncycastle.cert.jcajce.JcaX509v3CertificateBuilder
import org.bouncycastle.operator.jcajce.JcaContentSignerBuilder
import java.math.BigInteger
import java.security.KeyPairGenerator
import java.security.SecureRandom
import java.security.spec.ECGenParameterSpec
import java.util.Date

/** Ephemeral TLS key, unrelated to the non-exportable NFC identity key. Memory only. */
internal object PrivateChannelCertificate {
    fun create(): Map<String, Any> {
        val pair = KeyPairGenerator.getInstance("EC").apply {
            initialize(ECGenParameterSpec("secp256r1"))
        }.generateKeyPair()
        val now = System.currentTimeMillis()
        val name = X500Name("CN=SkyChat ephemeral group")
        val builder = JcaX509v3CertificateBuilder(
            name, BigInteger(128, SecureRandom()).setBit(127),
            Date(now - 86_400_000L), Date(now + 7 * 86_400_000L), name, pair.public
        )
        builder.addExtension(Extension.basicConstraints, true, BasicConstraints(false))
        builder.addExtension(Extension.keyUsage, true, KeyUsage(KeyUsage.digitalSignature))
        val certificate = builder.build(JcaContentSignerBuilder("SHA256withECDSA").build(pair.private)).encoded
        // Dart SecurityContext accepts PEM. Never log or persist either value.
        fun pem(label: String, bytes: ByteArray): String =
            "-----BEGIN $label-----\n" + com.nimbusds.jose.util.Base64.encode(bytes).toString() +
                "\n-----END $label-----\n"
        return mapOf(
            "certificate" to pem("CERTIFICATE", certificate),
            "privateKey" to pem("PRIVATE KEY", pair.private.encoded),
            "fingerprint" to ContactCrypto.hash(certificate)
        )
    }
}
