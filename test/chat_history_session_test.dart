import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:offline_connectivity/offline_connectivity.dart';
import 'package:offline_group_messenger/core/history/chat_history_repository.dart';
import 'package:offline_group_messenger/core/messaging/chat_session_controller.dart';
import 'package:offline_group_messenger/core/messaging/tcp_message_transport.dart';
import 'package:offline_group_messenger/core/models/chat_message.dart';

import 'support/memory_history_storage.dart';

class ArchiveTransport extends TcpMessageTransport {
  final events = StreamController<ChatMessage>.broadcast();
  String? currentGroup;
  String nextGroup = 'group-one';
  int sends = 0;
  int connects = 0;
  String? verifiedHost = 'host-contact';
  @override
  String? get authenticatedHostContactId =>
      requireContactAuth ? verifiedHost : null;
  @override
  String? get groupId => currentGroup;
  @override
  Stream<ChatMessage> get incoming => events.stream;

  @override
  Future<void> connect({required String host, required int port}) async {
    connects++;
    currentGroup = nextGroup;
    selfId = 'me';
    status = ChatStatus.ready;
    notifyListeners();
  }

  @override
  ChatMessage createMessage(String text) => ChatMessage(
    id: '1',
    groupId: currentGroup!,
    senderId: 'me',
    text: text.trim(),
    sentAt: DateTime.utc(2026),
  );

  @override
  Future<void> send(ChatMessage message) async {
    sends++;
    throw TimeoutException('Host acknowledgement lost');
  }

  @override
  void resetSession() {
    currentGroup = null;
    super.resetSession();
  }

  @override
  void dispose() {
    events.close();
    super.dispose();
  }
}

const _connection = GroupConnectionState(
  status: GroupStatus.connected,
  hostAddress: '192.168.49.1',
  privateGroup: true,
);

String privateId(String group) =>
    ChatHistoryRepository.privateConversationId(group, 'host-contact');

void main() {
  final histories = <ChatHistoryRepository>[];
  final sessions = <ChatSessionController>[];
  ChatHistoryRepository history(MemoryHistoryStorage storage) {
    final result = ChatHistoryRepository(
      storage,
      saveDelay: const Duration(days: 1),
    );
    histories.add(result);
    return result;
  }

  ChatSessionController session(
    ChatHistoryRepository history,
    ArchiveTransport transport,
  ) {
    final result = ChatSessionController(
      history: history,
      transport: transport,
    );
    sessions.add(result);
    return result;
  }

  tearDown(() async {
    for (final controller in sessions) {
      controller.dispose();
    }
    for (final repository in histories) {
      await repository.flush();
      repository.dispose();
    }
    sessions.clear();
    histories.clear();
  });

  test(
    'private drafts are bound to the authenticated host and never restore in a public group',
    () async {
      final storage = MemoryHistoryStorage();
      final original = history(storage);
      await original.ready;
      final first = session(original, ArchiveTransport());
      first.updateConnection(_connection, displayName: 'Alice');
      first.draft = 'Private draft for the original host';
      await original.flush();
      final restored = history(storage);
      await restored.ready;
      final otherHost = session(
        restored,
        ArchiveTransport()..verifiedHost = 'another-contact',
      );
      otherHost.updateConnection(_connection, displayName: 'Alice');
      expect(otherHost.draft, isEmpty);
      final public = session(restored, ArchiveTransport());
      public.updateConnection(
        const GroupConnectionState(
          status: GroupStatus.connected,
          hostAddress: '192.168.49.1',
        ),
        displayName: 'Alice',
      );
      expect(public.draft, isEmpty);
      expect(
        restored.find(privateId('group-one'))!.draft,
        'Private draft for the original host',
      );
    },
  );

  test(
    'private history never supplies a draft without an authenticated host identity',
    () async {
      final saved = history(MemoryHistoryStorage());
      await saved.ready;
      saved.setDraft(
        privateId('group-one'),
        'Private group',
        true,
        'Protected draft',
        groupId: 'group-one',
      );
      final controller = session(
        saved,
        ArchiveTransport()..verifiedHost = null,
      );
      controller.updateConnection(_connection, displayName: 'Alice');
      expect(controller.draft, isEmpty);
    },
  );

  test(
    'retrying a failed history load restores the draft in an already verified quiet session',
    () async {
      final storage = MemoryHistoryStorage();
      final original = history(storage);
      await original.ready;
      original.setDraft(
        privateId('group-one'),
        'Private group',
        true,
        'Recovered after retry',
        groupId: 'group-one',
      );
      await original.flush();
      storage.failRead = true;
      final next = history(storage);
      final controller = session(next, ArchiveTransport());
      await next.ready;
      controller.updateConnection(_connection, displayName: 'Alice');
      expect(controller.draft, isEmpty);
      storage.failRead = false;
      await next.retry();
      await Future<void>.delayed(Duration.zero);
      expect(controller.draft, 'Recovered after retry');
    },
  );

  test(
    'restart keeps private text and restores its draft only after joining the same group',
    () async {
      final storage = MemoryHistoryStorage();
      final first = history(storage);
      await first.ready;
      final transport = ArchiveTransport();
      final original = session(first, transport);
      original.updateConnection(_connection, displayName: 'Alice');
      original.draft = 'Continue this later';
      transport.events.add(
        ChatMessage(
          id: 'peer:1',
          groupId: 'group-one',
          senderId: 'peer',
          senderName: 'Bob',
          text: 'Private history',
          sentAt: DateTime.utc(2026),
          sequence: 1,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      await first.flush();

      final restoredHistory = history(storage);
      final restoredTransport = ArchiveTransport();
      final restored = session(restoredHistory, restoredTransport);
      await restoredHistory.ready;
      await Future<void>.delayed(Duration.zero);
      expect(
        restoredHistory
            .find(privateId('group-one'))!
            .messages
            .single
            .message
            .text,
        'Private history',
      );
      expect(restoredTransport.connects, 0);
      expect(restoredTransport.sends, 0);
      expect(restored.networkConnected, isFalse);
      expect(restored.isPrivateGroup, isFalse);
      expect(restored.draft, isEmpty);

      restored.updateConnection(_connection, displayName: 'Alice');
      expect(restored.draft, 'Continue this later');
      expect(restoredTransport.sends, 0);
      expect(restoredTransport.requireContactAuth, isTrue);
    },
  );

  test('a saved draft never leaks into a different group', () async {
    final storage = MemoryHistoryStorage();
    final saved = history(storage);
    await saved.ready;
    saved.setDraft(
      privateId('group-one'),
      'Private group',
      true,
      'Only for group one',
      groupId: 'group-one',
    );
    await saved.flush();
    final second = history(storage);
    await second.ready;
    final transport = ArchiveTransport()..nextGroup = 'group-two';
    final controller = session(second, transport);
    controller.updateConnection(_connection, displayName: 'Alice');
    expect(controller.draft, isEmpty);
    expect(second.find(privateId('group-one'))!.draft, 'Only for group one');
    expect(transport.sends, 0);
  });

  test(
    'a draft deliberately typed before joining takes precedence over the saved draft',
    () async {
      final saved = history(MemoryHistoryStorage());
      await saved.ready;
      saved.setDraft(
        privateId('group-one'),
        'Private group',
        true,
        'Earlier draft',
        groupId: 'group-one',
      );
      final controller = session(saved, ArchiveTransport());
      controller.draft = 'New draft';
      controller.updateConnection(_connection, displayName: 'Alice');
      expect(controller.draft, 'New draft');
      expect(saved.find(privateId('group-one'))!.draft, 'New draft');
      expect(
        saved.conversations.any((entry) => entry.id.startsWith('draft:')),
        isFalse,
      );
    },
  );

  test(
    'unconfirmed outgoing messages remain visible after restart but are never resent',
    () async {
      final storage = MemoryHistoryStorage();
      final first = history(storage);
      await first.ready;
      final original = session(first, ArchiveTransport());
      original.updateConnection(_connection, displayName: 'Alice');
      original.draft = 'May have reached Bob';
      await original.sendDraft();
      await first.flush();
      final next = history(storage);
      final transport = ArchiveTransport();
      final controller = session(next, transport);
      await next.ready;
      expect(
        next.find(privateId('group-one'))!.messages.single.confirmed,
        isFalse,
      );
      controller.updateConnection(_connection, displayName: 'Alice');
      expect(controller.draft, 'May have reached Bob');
      expect(transport.sends, 0);
      expect(controller.messages, isEmpty);
      expect(controller.sendError, ChatSessionController.recoveredSendWarning);
    },
  );

  test(
    'starting a new live session preserves the previous archived draft',
    () async {
      final saved = history(MemoryHistoryStorage());
      await saved.ready;
      final controller = session(saved, ArchiveTransport());
      controller.updateConnection(_connection, displayName: 'Alice');
      controller.draft = 'Previous conversation';
      controller.beginNewSession();
      expect(controller.draft, isEmpty);
      expect(
        saved.find(privateId('group-one'))!.draft,
        'Previous conversation',
      );
      expect(controller.hasConversation, isFalse);
    },
  );

  test(
    'NFC invitations and network credentials are excluded from saved history',
    () async {
      final storage = MemoryHistoryStorage();
      final saved = history(storage);
      await saved.ready;
      final controller = session(saved, ArchiveTransport());
      final token = 'a' * 64;
      final invitation = GroupInvitation.fromMap({
        'app': 'offline-group-messenger',
        'version': 2,
        'transport': 'wifi-direct',
        'privateGroup': true,
        'networkName': 'DIRECT-AB-secret',
        'passphrase': 'secret-password',
        'admissionToken': token,
      });
      controller.prepareJoin(invitation: invitation);
      controller.updateConnection(_connection, displayName: 'Alice');
      controller.draft = 'Draft';
      await saved.flush();
      final raw = storage.data!;
      expect(raw, isNot(contains('secret-password')));
      expect(raw, isNot(contains('DIRECT-AB-secret')));
      expect(raw, isNot(contains(token)));
      expect(jsonDecode(raw)['version'], 1);
    },
  );
}
