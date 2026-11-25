import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_group_messenger/core/history/chat_history_repository.dart';
import 'package:offline_group_messenger/core/history/saved_conversation.dart';
import 'package:offline_group_messenger/core/models/chat_message.dart';
import 'package:offline_group_messenger/features/history/saved_chats_screen.dart';
import 'package:offline_group_messenger/features/home/home_screen.dart';

import 'connection_flow_test.dart' show FakeConnection;
import 'support/memory_history_storage.dart';

Future<ChatHistoryRepository> seedHistory(MemoryHistoryStorage storage) async {
  final history = ChatHistoryRepository(storage, saveDelay: Duration.zero);
  await history.ready;
  history.record(
    'group',
    'Private group',
    true,
    SavedChatMessage(
      message: ChatMessage(
        id: 'me:1',
        groupId: 'group',
        senderId: 'me',
        text: 'Uncertain message',
        sentAt: DateTime.utc(2026, 11, 25),
      ),
      mine: true,
      confirmed: false,
    ),
  );
  history.setDraft('group', 'Private group', true, 'My saved draft');
  await history.flush();
  return history;
}

void main() {
  testWidgets(
    'a failed deletion stays visible and can be retried without claiming success',
    (tester) async {
      final storage = MemoryHistoryStorage();
      final history = await seedHistory(storage);
      final original = storage.data;
      storage.failWrite = true;
      await tester.pumpWidget(
        MaterialApp(
          home: SavedConversationScreen(
            history: history,
            conversationId: 'group',
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Delete saved conversation'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(
        find.text('The deletion has not been saved yet. Retry above.'),
        findsOneWidget,
      );
      expect(storage.data, original);
      storage.failWrite = false;
      await tester.tap(find.text('Retry saving'));
      await tester.pumpAndSettle();
      expect(decodeSavedConversations(storage.data!), isEmpty);
      expect(
        find.text('This saved conversation has been deleted.'),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      history.dispose();
    },
  );
  testWidgets(
    'restarted app exposes saved conversations without starting a connection',
    (tester) async {
      final storage = MemoryHistoryStorage();
      final original = await seedHistory(storage);
      original.dispose();
      final connection = FakeConnection();
      await tester.pumpWidget(
        MaterialApp(
          home: HomeScreen(connectivity: connection, historyStorage: storage),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('1 saved on this phone'), findsOneWidget);
      await tester.tap(find.text('Saved conversations'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Private group'));
      await tester.pumpAndSettle();
      expect(find.text('My saved draft'), findsOneWidget);
      expect(find.text('Uncertain message'), findsOneWidget);
      expect(
        find.text(
          'Delivery was not confirmed. This message may have reached the group.',
        ),
        findsOneWidget,
      );
      expect(connection.creates, 0);
      expect(connection.joined, isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'deletion requires confirmation and cancellation preserves saved text',
    (tester) async {
      final storage = MemoryHistoryStorage();
      final history = await seedHistory(storage);
      await tester.pumpWidget(
        MaterialApp(home: SavedChatsScreen(history: history)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Private group'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Delete saved conversation'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(history.find('group'), isNotNull);
      await tester.tap(find.byTooltip('Delete saved conversation'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(history.conversations, isEmpty);
      expect(decodeSavedConversations(storage.data!), isEmpty);
      expect(
        find.text(
          'No saved conversations yet. Your messages and drafts will appear here.',
        ),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      history.dispose();
    },
  );

  testWidgets(
    'unreadable storage offers explicit reset instead of silently replacing history',
    (tester) async {
      final storage = MemoryHistoryStorage()..data = 'unreadable';
      final history = ChatHistoryRepository(storage, saveDelay: Duration.zero);
      await history.ready;
      await tester.pumpWidget(
        MaterialApp(home: SavedChatsScreen(history: history)),
      );
      await tester.pumpAndSettle();
      expect(find.text('Retry loading'), findsOneWidget);
      expect(storage.data, 'unreadable');
      await tester.tap(find.byTooltip('Delete all saved conversations'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(storage.data, isNull);
      expect(history.error, isNull);
      expect(storage.operations, ['clear']);
      await tester.pumpWidget(const SizedBox.shrink());
      history.dispose();
    },
  );
}
