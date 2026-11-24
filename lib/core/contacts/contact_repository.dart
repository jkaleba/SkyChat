import 'package:flutter/services.dart';

enum ContactTrust { pending, verified, blocked }

class SavedContact {
  const SavedContact({
    required this.id,
    required this.name,
    required this.trust,
  });
  factory SavedContact.fromMap(Map<dynamic, dynamic> raw) => SavedContact(
    id: raw['id'] as String,
    name: raw['name'] as String,
    trust: ContactTrust.values.byName(raw['state'] as String),
  );
  final String id;
  final String name;
  final ContactTrust trust;
}

class ContactSnapshot {
  const ContactSnapshot(this.identity, this.contacts);
  final String identity;
  final List<SavedContact> contacts;
}

/// Android owns private keys, encrypted persistence and trust transitions.
class ContactRepository {
  const ContactRepository();
  static const channel = MethodChannel('com.offlinegroupmessenger/contacts');
  static const _prefsChannel = MethodChannel('com.skychat/background');

  Future<String> loadUsername() async {
    try {
      final name = await _prefsChannel.invokeMethod<String>('getUsername');
      if (name != null && name.trim().isNotEmpty) return name.trim();
    } on MissingPluginException {
      // Fallback for tests or non-Android platforms.
    } on PlatformException {
      // Fallback below.
    }
    return 'Guest';
  }

  Future<void> saveUsername(String name) async {
    try {
      await _prefsChannel.invokeMethod<void>('setUsername', {
        'name': name.trim(),
      });
    } on MissingPluginException {
      // Ignored in tests.
    } on PlatformException {
      // Best-effort.
    }
  }

  Future<ContactSnapshot> load() async {
    final raw = (await channel.invokeMapMethod<String, dynamic>('snapshot'))!;
    return ContactSnapshot(raw['identity'] as String, [
      for (final item in raw['contacts'] as List)
        SavedContact.fromMap(item as Map),
    ]);
  }

  Future<void> rename(String id, String name) =>
      channel.invokeMethod('rename', {'id': id, 'name': name});
  Future<void> block(String id) => channel.invokeMethod('block', {'id': id});
  Future<void> delete(String id) => channel.invokeMethod('delete', {'id': id});
  Future<void> reset() => channel.invokeMethod('reset');
  Future<Map<String, dynamic>> privateChannelCertificate() async =>
      (await channel.invokeMapMethod<String, dynamic>(
        'privateChannelCertificate',
      ))!;
  Future<String> signPrivateChannel(Map<String, dynamic> body) async =>
      (await channel.invokeMethod<String>('signPrivateChannel', {
        'body': body,
      }))!;
  Future<String> verifyPrivateChannel(
    String token,
    Map<String, dynamic> expected,
  ) async => (await channel.invokeMethod<String>('verifyPrivateChannel', {
    'token': token,
    'expected': expected,
  }))!;
  Future<String> signCall(Map<String, dynamic> body) async =>
      (await channel.invokeMethod<String>('signCall', {'body': body}))!;
  Future<Map<String, dynamic>> verifyCall(String token) async => (await channel
      .invokeMapMethod<String, dynamic>('verifyCall', {'token': token}))!;
  Future<String> signGroupAuth(String to, String nonce) async => (await channel
      .invokeMethod<String>('signGroupAuth', {'to': to, 'nonce': nonce}))!;
  Future<String> verifyGroupAuth(String token, String nonce) async =>
      (await channel.invokeMethod<String>('verifyGroupAuth', {
        'token': token,
        'nonce': nonce,
      }))!;
  Future<void> startPairing(String name, {required bool reader}) =>
      channel.invokeMethod('pairingStart', {'name': name, 'reader': reader});
  Future<Map<String, dynamic>?> pairingStatus() =>
      channel.invokeMapMethod<String, dynamic>('pairingStatus');
  Future<void> approvePairing() => channel.invokeMethod('pairingApprove');
  Future<void> stopPairing() => channel.invokeMethod('pairingStop');
}

/// Resolves a peer's display label from local Contacts, falling back to
/// `<senderName> (unknown)` when contacts are loaded and no match exists.
String resolveSenderLabel({
  required String senderName,
  String? senderContactId,
  required Map<String, String> contactNames,
  required bool contactsLoaded,
}) {
  if (!contactsLoaded) return senderName;
  if (senderContactId != null && contactNames.containsKey(senderContactId)) {
    return contactNames[senderContactId]!;
  }
  return '$senderName (unknown)';
}
