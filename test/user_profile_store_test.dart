import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_group_messenger/core/profile/user_profile.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const legacy = MethodChannel('com.skychat/background');
  const store = AndroidUserProfileStore();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(AndroidUserProfileStore.channel, null);
    messenger.setMockMethodCallHandler(legacy, null);
  });

  test(
    'a fresh native profile requires setup and an existing nickname skips it',
    () async {
      var configured = false;
      messenger.setMockMethodCallHandler(
        AndroidUserProfileStore.channel,
        (call) async => {
          'username': configured ? '  Alice  ' : '',
          'configured': configured,
        },
      );
      expect((await store.load()).configured, isFalse);
      configured = true;
      final profile = await store.load();
      expect(profile.configured, isTrue);
      expect(profile.username, 'Alice');
    },
  );

  test(
    'setup persists the trimmed name and waits for the native acknowledgement',
    () async {
      String? saved;
      final acknowledgement = Completer<void>();
      messenger.setMockMethodCallHandler(AndroidUserProfileStore.channel, (
        call,
      ) async {
        if (call.method == 'complete') {
          saved = (call.arguments as Map)['name'] as String;
        }
        await acknowledgement.future;
        return null;
      });
      var completed = false;
      final saving = store.complete('  Żaneta  ').then((_) => completed = true);
      await Future<void>.delayed(Duration.zero);
      expect(completed, isFalse);
      acknowledgement.complete();
      await saving;
      expect(saved, 'Żaneta');
    },
  );

  test(
    'storage failures remain visible instead of reporting successful setup',
    () async {
      messenger.setMockMethodCallHandler(AndroidUserProfileStore.channel, (
        _,
      ) async {
        throw PlatformException(code: 'profile_storage_failed');
      });
      await expectLater(store.load(), throwsA(isA<PlatformException>()));
      await expectLater(
        store.complete('Alice'),
        throwsA(isA<PlatformException>()),
      );
    },
  );

  test(
    'older native adapters keep their saved name when setup is unsupported',
    () async {
      messenger.setMockMethodCallHandler(
        legacy,
        (call) async => call.method == 'getUsername' ? 'Janek' : null,
      );
      final profile = await store.load();
      expect(profile.configured, isTrue);
      expect(profile.username, 'Janek');
    },
  );

  test(
    'unsupported platforms remain usable without a profile channel',
    () async {
      final profile = await store.load();
      expect(profile.configured, isTrue);
      expect(profile.username, 'Guest');
    },
  );

  test('malformed saved names cannot bypass setup', () async {
    messenger.setMockMethodCallHandler(
      AndroidUserProfileStore.channel,
      (_) async => {'username': 'Alice\nBob', 'configured': true},
    );
    expect((await store.load()).configured, isFalse);
  });

  test('invalid input is rejected before any platform write', () async {
    var writes = 0;
    messenger.setMockMethodCallHandler(AndroidUserProfileStore.channel, (
      _,
    ) async {
      writes++;
      return null;
    });
    for (final value in [
      '',
      '   ',
      'a' * 33,
      '📨' * 17,
      'Alice\nBob',
      'A\u0000B',
      'A\u0085B',
      'A\u2028B',
    ]) {
      await expectLater(store.complete(value), throwsFormatException);
    }
    expect(writes, 0);
    expect(normalizeProfileName('Żaneta 📨'), 'Żaneta 📨');
    expect(normalizeProfileName('a' * 32), 'a' * 32);
  });
}
