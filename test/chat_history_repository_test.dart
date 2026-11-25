import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_group_messenger/core/history/chat_history_repository.dart';
import 'package:offline_group_messenger/core/history/saved_conversation.dart';
import 'package:offline_group_messenger/core/models/chat_message.dart';

import 'support/memory_history_storage.dart';

void remember(
  ChatHistoryRepository history,
  String group,
  String text, {
  int sequence = 1,
  bool confirmed = true,
  bool mine = false,
}) => history.record(
  group,
  'Private group',
  true,
  SavedChatMessage(
    message: ChatMessage(
      id: 'peer:$sequence',
      groupId: group,
      senderId: 'peer',
      senderName: 'Alice',
      text: text,
      sentAt: DateTime.utc(2026, 11, 25),
      sequence: confirmed ? sequence : 0,
    ),
    mine: mine,
    confirmed: confirmed,
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final repositories = <ChatHistoryRepository>[];
  ChatHistoryRepository repository(MemoryHistoryStorage storage) {
    final result = ChatHistoryRepository(
      storage,
      saveDelay: const Duration(days: 1),
    );
    repositories.add(result);
    return result;
  }

  tearDown(() async {
    for (final history in repositories) {
      await history.flush();
      history.dispose();
    }
    repositories.clear();
  });

  test('continuous updates cannot postpone autosaving indefinitely', () async {
    final storage = MemoryHistoryStorage();
    final history = ChatHistoryRepository(
      storage,
      saveDelay: const Duration(milliseconds: 100),
    );
    repositories.add(history);
    await history.ready;
    for (var index = 0; index < 10; index++) {
      history.setDraft('group', 'Public group', false, 'Typing $index');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(storage.writes, isNotEmpty);
    await history.flush();
    expect(decodeSavedConversations(storage.data!)['group']!.draft, 'Typing 9');
  });

  test(
    'deletion is ordered after a pending write and new arrivals stay saved',
    () async {
      final storage = MemoryHistoryStorage()..writeGate = Completer<void>();
      final history = repository(storage);
      await history.ready;
      remember(history, 'old', 'Delete me');
      final saving = history.flush();
      await storage.writeStarted.future;
      final clearing = history.clear();
      remember(history, 'new', 'Arrived after deletion');
      storage.writeGate!.complete();
      await saving;
      expect(await clearing, isTrue);
      await history.flush();
      expect(storage.operations, ['write', 'clear', 'write']);
      expect(decodeSavedConversations(storage.data!).keys, ['new']);
    },
  );

  test(
    'interaction order survives restart when conversation timestamps are identical',
    () async {
      final sameTime = DateTime.utc(2026);
      final storage = MemoryHistoryStorage()
        ..data = jsonEncode({
          'version': 1,
          'conversations': [
            SavedConversation(
              id: 'newer',
              title: 'Newer',
              privateGroup: false,
              updatedAt: sameTime,
            ).toJson(),
            SavedConversation(
              id: 'older',
              title: 'Older',
              privateGroup: false,
              updatedAt: sameTime,
            ).toJson(),
          ],
        });
      final history = repository(storage);
      await history.ready;
      expect(history.conversations.map((value) => value.id), [
        'newer',
        'older',
      ]);
      history.setDraft('older', 'Older', false, 'Most recent action');
      await history.flush();
      final restored = repository(storage);
      await restored.ready;
      expect(restored.conversations.map((value) => value.id), [
        'older',
        'newer',
      ]);
    },
  );

  test(
    'an accepted outgoing message moves after earlier host sequences',
    () async {
      final history = repository(MemoryHistoryStorage());
      await history.ready;
      history.record(
        'group',
        'Group',
        false,
        SavedChatMessage(
          message: ChatMessage(
            id: 'me:1',
            groupId: 'group',
            senderId: 'me',
            text: 'Mine',
            sentAt: DateTime.utc(2026),
          ),
          mine: true,
          confirmed: false,
        ),
      );
      remember(history, 'group', 'Earlier acceptance', sequence: 1);
      history.record(
        'group',
        'Group',
        false,
        SavedChatMessage(
          message: ChatMessage(
            id: 'me:1',
            groupId: 'group',
            senderId: 'me',
            text: 'Mine',
            sentAt: DateTime.utc(2026),
            sequence: 2,
          ),
          mine: true,
          confirmed: true,
        ),
      );
      expect(
        history.find('group')!.messages.map((entry) => entry.message.sequence),
        [1, 2],
      );
    },
  );

  test(
    'messages, Unicode drafts and receipts survive a repository restart',
    () async {
      final storage = MemoryHistoryStorage();
      final first = repository(storage);
      await first.ready;
      remember(first, 'group', 'Zażółć gęślą 📨', mine: true);
      first.confirm('group', 'peer:1', 3);
      first.setDraft('group', 'Private group', true, 'Niedokończona wiadomość');
      expect(await first.flush(), isTrue);
      final restored = repository(storage);
      await restored.ready;
      final conversation = restored.find('group')!;
      expect(conversation.privateGroup, isTrue);
      expect(conversation.draft, 'Niedokończona wiadomość');
      expect(conversation.messages.single.message.text, 'Zażółć gęślą 📨');
      expect(conversation.messages.single.mine, isTrue);
      expect(conversation.messages.single.checks, 3);
    },
  );

  test(
    'replay deduplicates a message and preserves its previous ownership and receipts',
    () async {
      final history = repository(MemoryHistoryStorage());
      await history.ready;
      remember(history, 'group', 'Hello', mine: true);
      history.confirm('group', 'peer:1', 3);
      remember(history, 'group', 'Hello');
      final messages = history.find('group')!.messages;
      expect(messages, hasLength(1));
      expect(messages.single.mine, isTrue);
      expect(messages.single.checks, 3);
    },
  );

  test(
    'bounded history preserves unconfirmed sends separately from accepted messages',
    () async {
      final history = repository(MemoryHistoryStorage());
      await history.ready;
      for (var index = 1; index <= 55; index++) {
        remember(
          history,
          'group',
          'Unconfirmed $index',
          sequence: index,
          confirmed: false,
          mine: true,
        );
      }
      for (var index = 100; index < 605; index++) {
        remember(history, 'group', 'Accepted $index', sequence: index);
      }
      final messages = history.find('group')!.messages;
      expect(messages.where((value) => value.confirmed), hasLength(500));
      expect(messages.where((value) => !value.confirmed), hasLength(50));
      expect(
        messages.any((value) => value.message.text == 'Unconfirmed 1'),
        isFalse,
      );
      expect(
        messages.any((value) => value.message.text == 'Unconfirmed 55'),
        isTrue,
      );
    },
  );

  test(
    'oldest conversations are evicted and encoded storage stays bounded',
    () async {
      final storage = MemoryHistoryStorage();
      final history = repository(storage);
      await history.ready;
      for (var index = 0; index < 32; index++) {
        remember(history, 'group-$index', 'Message');
      }
      expect(history.conversations, hasLength(30));
      expect(history.find('group-0'), isNull);
      for (var group = 0; group < 4; group++) {
        for (var index = 1; index <= 500; index++) {
          remember(history, 'large-$group', 'ż' * 2000, sequence: index);
        }
      }
      await history.flush();
      expect(
        utf8.encode(storage.data!).length,
        lessThanOrEqualTo(ChatHistoryRepository.maxBytes),
      );
      expect(history.find('large-3')!.messages, hasLength(500));
    },
  );

  test(
    'startup merges live events with disk history instead of overwriting either',
    () async {
      final storage = MemoryHistoryStorage();
      final initial = repository(storage);
      await initial.ready;
      remember(initial, 'group', 'Before restart');
      initial.setDraft('group', 'Private group', true, 'Saved draft');
      await initial.flush();
      final raw = storage.data;
      storage.readGate = Completer<String?>();
      final history = repository(storage);
      remember(history, 'group', 'During loading', sequence: 2);
      storage.readGate!.complete(raw);
      await history.ready;
      expect(
        history.find('group')!.messages.map((entry) => entry.message.text),
        ['Before restart', 'During loading'],
      );
      expect(history.find('group')!.draft, 'Saved draft');
    },
  );

  test(
    'failed reads preserve the file, block writes and retain live changes for retry',
    () async {
      final storage = MemoryHistoryStorage();
      final initial = repository(storage);
      await initial.ready;
      remember(initial, 'old-group', 'Existing history');
      await initial.flush();
      final original = storage.data;
      final writes = storage.writes.length;
      storage.failRead = true;
      final history = repository(storage);
      await history.ready;
      remember(history, 'new-group', 'During read failure');
      expect(await history.flush(), isFalse);
      expect(storage.writes, hasLength(writes));
      expect(storage.data, original);
      expect(history.error, isNotNull);
      storage.failRead = false;
      await history.retry();
      await history.flush();
      expect(history.find('old-group'), isNotNull);
      expect(history.find('new-group'), isNotNull);
      expect(history.error, isNull);
    },
  );

  test(
    'unknown formats are not overwritten until the user explicitly clears history',
    () async {
      final storage = MemoryHistoryStorage()
        ..data = '{"version":2,"conversations":[]}';
      final history = repository(storage);
      await history.ready;
      remember(history, 'group', 'Hello');
      expect(await history.flush(), isFalse);
      expect(storage.writes, isEmpty);
      expect(await history.clear(), isTrue);
      remember(history, 'new-group', 'After explicit reset');
      await history.flush();
      expect(decodeSavedConversations(storage.data!).keys, ['new-group']);
    },
  );

  test(
    'a failed write retries the latest draft without losing messages',
    () async {
      final storage = MemoryHistoryStorage()..failWrite = true;
      final history = repository(storage);
      await history.ready;
      remember(history, 'group', 'Hello');
      expect(await history.flush(), isFalse);
      history.setDraft('group', 'Private group', true, 'Latest draft');
      storage.failWrite = false;
      await history.retry();
      final restored = decodeSavedConversations(storage.data!)['group']!;
      expect(restored.messages.single.message.text, 'Hello');
      expect(restored.draft, 'Latest draft');
    },
  );

  test(
    'deletion follows an in-flight save and never resurrects its old payload',
    () async {
      final storage = MemoryHistoryStorage()..writeGate = Completer<void>();
      final history = repository(storage);
      await history.ready;
      remember(history, 'group', 'Delete me');
      final saving = history.flush();
      await storage.writeStarted.future;
      final deleting = history.delete('group');
      storage.writeGate!.complete();
      await saving;
      expect(await deleting, isTrue);
      expect(decodeSavedConversations(storage.data!), isEmpty);
      expect(storage.operations, ['write', 'write']);
    },
  );

  test(
    'clearing during startup cancels the old read and preserves only subsequent messages',
    () async {
      final storage = MemoryHistoryStorage();
      final initial = repository(storage);
      await initial.ready;
      remember(initial, 'old', 'Delete me');
      await initial.flush();
      final raw = storage.data;
      storage.readGate = Completer<String?>();
      final history = repository(storage);
      final clearing = history.clear();
      remember(history, 'new', 'After deletion');
      storage.readGate!.complete(raw);
      expect(await clearing, isTrue);
      await history.flush();
      expect(history.find('old'), isNull);
      expect(decodeSavedConversations(storage.data!).keys, ['new']);
    },
  );

  test(
    'the Android bridge forwards native storage failures without a plaintext fallback',
    () async {
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(AndroidChatHistoryStorage.channel, (
            call,
          ) async {
            calls.add(call.method);
            throw PlatformException(code: 'history_storage_failed');
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(AndroidChatHistoryStorage.channel, null),
      );
      const storage = AndroidChatHistoryStorage();
      await expectLater(storage.read(), throwsA(isA<PlatformException>()));
      await expectLater(
        storage.write('private'),
        throwsA(isA<PlatformException>()),
      );
      expect(calls, ['read', 'write']);
    },
  );

  test(
    'invalid archive message identities and oversized text are rejected',
    () async {
      final history = repository(MemoryHistoryStorage());
      await history.ready;
      remember(history, 'group', 'Hello');
      final data = history.find('group')!.toJson();
      (data['messages'] as List).first['groupId'] = 'another-group';
      expect(() => SavedConversation.fromJson(data), throwsFormatException);
      (data['messages'] as List).first['groupId'] = 'group';
      (data['messages'] as List).first['text'] = 'x' * 2001;
      expect(() => SavedConversation.fromJson(data), throwsFormatException);
    },
  );
}
