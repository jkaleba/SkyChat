import 'dart:convert';

/// Contains network credentials. Do not log or persist invitations.
class GroupInvitation {
  const GroupInvitation._(
    this.networkName,
    this.passphrase,
    this.privateGroup,
    this.admissionToken,
    this.hostAddress,
  );
  final String networkName;
  final String passphrase;
  final bool privateGroup;
  final String? admissionToken;

  /// Actual Android group-owner address, provided only by the iPhone invitation.
  final String? hostAddress;
  int get version => privateGroup ? (admissionToken == null ? 3 : 2) : 1;

  static bool isLocalHostAddress(String value) {
    final parts = value.split('.');
    if (parts.length != 4) return false;
    final octets = parts.map(int.tryParse).toList();
    if (octets.any((n) => n == null || n < 0 || n > 255)) return false;
    if (List.generate(4, (i) => octets[i].toString()).join('.') != value) {
      return false;
    }
    return octets[0] == 10 ||
        (octets[0] == 172 && octets[1]! >= 16 && octets[1]! <= 31) ||
        (octets[0] == 192 && octets[1] == 168) ||
        (octets[0] == 169 && octets[1] == 254);
  }

  factory GroupInvitation.fromMap(Map<String, dynamic> map) {
    final name = map['networkName'];
    final password = map['passphrase'];
    final version = map['version'];
    final privateGroup = map['privateGroup'] == true;
    final token = map['admissionToken'];
    final host = map['hostAddress'];
    final contactInvitation = privateGroup && version == 3;
    if (map['app'] != 'offline-group-messenger' ||
        (!contactInvitation && version != (privateGroup ? 2 : 1)) ||
        (map['privateGroup'] != null && map['privateGroup'] is! bool) ||
        (privateGroup &&
            !contactInvitation &&
            (version != 2 ||
                token is! String ||
                !RegExp(r'^[0-9a-f]{64}$').hasMatch(token))) ||
        (!privateGroup && token != null) ||
        (contactInvitation && (token != null || host == null)) ||
        (host != null && (host is! String || !isLocalHostAddress(host))) ||
        map['transport'] != 'wifi-direct' ||
        name is! String ||
        !RegExp(r'^DIRECT-[a-zA-Z0-9]{2}').hasMatch(name) ||
        utf8.encode(name).length > 32 ||
        name.contains(RegExp(r'[\x00-\x1f\x7f]')) ||
        password is! String ||
        password.length < 8 ||
        password.length > 63 ||
        password.codeUnits.any((c) => c < 32 || c > 126)) {
      throw const FormatException('This is not a supported group invitation.');
    }
    return GroupInvitation._(
      name,
      password,
      privateGroup,
      token as String?,
      host as String?,
    );
  }

  factory GroupInvitation.parse(String raw) {
    if (raw.length > 2048) {
      throw const FormatException('Invitation is too large.');
    }
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('This is not a group invitation.');
    }
    return GroupInvitation.fromMap(decoded);
  }

  Map<String, dynamic> toMap() => {
    'app': 'offline-group-messenger',
    'version': version,
    'transport': 'wifi-direct',
    'networkName': networkName,
    'passphrase': passphrase,
    if (privateGroup) 'privateGroup': true,
    if (admissionToken != null) 'admissionToken': admissionToken,
    if (hostAddress != null) 'hostAddress': hostAddress,
  };
  String encode() => jsonEncode(toMap());
}
