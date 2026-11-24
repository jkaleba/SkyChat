import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:offline_group_messenger/core/contacts/contact_repository.dart';

/// In-memory identity service for socket tests. Actual ES256 verification is
/// tested separately in the Android PrivateChannelTest.
class PrivateContacts extends ContactRepository {
  PrivateContacts(this.identity, this.trusted);
  final String identity;
  final Map<String, String> trusted;
  final blocked = <String>{};
  int clientProofs = 0;
  bool wrongCertificate = false;

  @override
  Future<ContactSnapshot> load() async => ContactSnapshot(identity, [
    for (final contact in trusted.entries)
      SavedContact(
        id: contact.key,
        name: contact.value,
        trust: blocked.contains(contact.key)
            ? ContactTrust.blocked
            : ContactTrust.verified,
      ),
  ]);

  @override
  Future<Map<String, dynamic>> privateChannelCertificate() async {
    final certificate = File(
      'test/fixtures/private_channel/certificate.pem',
    ).readAsStringSync();
    final der = base64Decode(
      certificate
          .split('\n')
          .where((line) => line.isNotEmpty && !line.startsWith('-----'))
          .join(),
    );
    return {
      'certificate': certificate,
      'privateKey': File(
        'test/fixtures/private_channel/private-key.pem',
      ).readAsStringSync(),
      'fingerprint': sha256.convert(der).toString(),
    };
  }

  @override
  Future<String> signPrivateChannel(Map<String, dynamic> body) async {
    if (body['role'] == 'client') {
      clientProofs++;
      if (!trusted.containsKey(body['to']) || blocked.contains(body['to'])) {
        throw StateError('Unknown host');
      }
    }
    final data = base64Url.encode(
      utf8.encode(
        jsonEncode({
          ...body,
          'from': identity,
          if (wrongCertificate) 'certificate': '0' * 64,
        }),
      ),
    );
    return '$data.${Hmac(sha256, utf8.encode('test-key:$identity')).convert(utf8.encode(data))}';
  }

  @override
  Future<String> verifyPrivateChannel(
    String token,
    Map<String, dynamic> expected,
  ) async {
    final parts = token.split('.');
    final payload =
        jsonDecode(utf8.decode(base64Url.decode(parts[0])))
            as Map<String, dynamic>;
    final from = payload['from'] as String;
    if (!trusted.containsKey(from) ||
        blocked.contains(from) ||
        parts[1] !=
            Hmac(
              sha256,
              utf8.encode('test-key:$from'),
            ).convert(utf8.encode(parts[0])).toString()) {
      throw StateError('Untrusted signature');
    }
    for (final field in ['role', 'nonce', 'certificate', 'group']) {
      if (payload[field] != expected[field]) throw StateError('Wrong $field');
    }
    if (expected['role'] == 'client' && payload['to'] != identity ||
        expected['role'] == 'host' && payload['to'] != '' ||
        expected['from'] != null && expected['from'] != from) {
      throw StateError('Wrong identity');
    }
    return from;
  }
}
