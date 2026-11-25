import 'package:offline_group_messenger/core/profile/user_profile.dart';

/// Existing connection tests exercise the app after first-run setup is complete.
class ConfiguredProfileStore implements UserProfileStore {
  const ConfiguredProfileStore();

  @override
  Future<LocalUserProfile> load() async =>
      const LocalUserProfile(username: 'Guest', configured: true);

  @override
  Future<void> complete(String username) => Future.error(
    StateError('This fixture already has a configured profile.'),
  );
}
