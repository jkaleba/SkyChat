import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../contacts/contact_repository.dart';

/// TLS encrypts all private frames. NFC identity proofs authenticate its certificate
/// before any name, resume token, admission decision, roster or message is sent.
class PrivateChannel {
  const PrivateChannel(this.contacts);
  final ContactRepository contacts;

  static const protocol = 'ogm-private-channel-v1';
  static String fingerprint(X509Certificate certificate) =>
      sha256.convert(certificate.der).toString();

  Future<({SecurityContext context, String fingerprint})> createHost() async {
    final material = await contacts.privateChannelCertificate();
    final context = SecurityContext()
      ..minimumTlsProtocolVersion = TlsProtocolVersion.tls1_3
      ..useCertificateChainBytes(utf8.encode(material['certificate'] as String))
      ..usePrivateKeyBytes(utf8.encode(material['privateKey'] as String));
    return (context: context, fingerprint: material['fingerprint'] as String);
  }

  Future<SecureSocket> connect(String host, int port) => SecureSocket.connect(
    host,
    port,
    context: SecurityContext()
      ..minimumTlsProtocolVersion = TlsProtocolVersion.tls1_3,
    // Self-signed transport certificate is authenticated by the NFC identity
    // proof, bound to its SHA-256 fingerprint and a fresh client challenge.
    onBadCertificate: (_) => true,
    supportedProtocols: [protocol],
    timeout: const Duration(seconds: 4),
  );
}
