import 'package:flutter/services.dart';

String? normalizeProfileName(String raw) {
  final name = raw.trim();
  if (name.isEmpty ||
      name.length > 32 ||
      RegExp(r'[\x00-\x1f\x7f-\x9f\u2028\u2029]').hasMatch(name)) {
    return null;
  }
  return name;
}

class LocalUserProfile {
  const LocalUserProfile({required this.username, required this.configured});
  final String username;
  final bool configured;
}

abstract interface class UserProfileStore {
  Future<LocalUserProfile> load();
  Future<void> complete(String username);
}

class AndroidUserProfileStore implements UserProfileStore {
  const AndroidUserProfileStore();
  static const channel = MethodChannel('com.skychat/profile');
  static const _legacyChannel = MethodChannel('com.skychat/background');

  @override
  Future<LocalUserProfile> load() async {
    Object? raw;
    try {
      raw = await channel.invokeMethod<Object?>('load');
    } on MissingPluginException {
      return _legacyProfile();
    }
    if (raw == null) return _legacyProfile();
    if (raw is! Map) throw const FormatException('Invalid local profile.');
    final value = raw['username'];
    final name = value is String ? normalizeProfileName(value) : null;
    return LocalUserProfile(
      username: name ?? '',
      configured: raw['configured'] == true && name != null,
    );
  }

  Future<LocalUserProfile> _legacyProfile() async {
    // Older native adapters/tests do not implement setup. Keep their existing
    // name and behavior; no setup screen can be saved through a missing channel.
    String? name;
    try {
      final value = await _legacyChannel.invokeMethod<Object?>('getUsername');
      if (value is String) name = normalizeProfileName(value);
    } on MissingPluginException {
      // Non-Android adapters need no profile setup.
    } on PlatformException {
      // Existing adapters use Guest when the nickname is unavailable.
    }
    return LocalUserProfile(username: name ?? 'Guest', configured: true);
  }

  @override
  Future<void> complete(String username) async {
    final name = normalizeProfileName(username);
    if (name == null) throw const FormatException('Invalid display name.');
    await channel.invokeMethod<void>('complete', {'name': name});
  }
}
