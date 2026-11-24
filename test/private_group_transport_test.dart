import 'package:flutter_test/flutter_test.dart';
import 'package:offline_group_messenger/core/messaging/tcp_message_transport.dart';
import 'package:offline_group_messenger/core/messaging/chat_session_controller.dart';
import 'session_recovery_test.dart' show until, texts;
import 'support/private_contacts.dart';

void main() {
  test(
    'private admission rejects missing/wrong NFC secrets before exposing chat',
    () async {
      final host = TcpMessageTransport()..hostAdmissionToken = 'a' * 64;
      final stranger = TcpMessageTransport();
      final wrong = TcpMessageTransport()..invitationToken = 'b' * 64;
      final invited = TcpMessageTransport()..invitationToken = 'a' * 64;
      addTearDown(() {
        invited.dispose();
        wrong.dispose();
        stranger.dispose();
        host.dispose();
      });
      await host.startHost(port: 0, address: '127.0.0.1');
      await host.sendText('Before joining');
      for (final client in [stranger, wrong]) {
        await client.connect(host: '127.0.0.1', port: host.listeningPort!);
        await until(() => client.sessionEnded);
        expect(client.error, contains('NFC invitation'));
        expect(client.selfId, isNull);
        expect(client.participants, isEmpty);
        expect(client.messages, isEmpty);
      }
      expect(host.participants.length, 1);
      await invited.connect(host: '127.0.0.1', port: host.listeningPort!);
      await until(() => invited.status == ChatStatus.ready);
      expect(texts(invited), isEmpty);
      await invited.sendText('Invited participant');
      expect(texts(host).last.text, 'Invited participant');
      final identity = invited.selfId;
      await invited.close();
      invited.invitationToken = null;
      await host.sendText('While away');
      await invited.connect(host: '127.0.0.1', port: host.listeningPort!);
      await until(() => invited.status == ChatStatus.ready);
      expect(invited.selfId, identity);
      expect(texts(invited).map((m) => m.text), [
        'Invited participant',
        'While away',
      ]);
    },
  );

  test(
    'deliberate leave and rejoin keeps history and draft in the controller',
    () async {
      final host = TcpMessageTransport();
      final session = ChatSessionController();
      addTearDown(() {
        session.dispose();
        host.dispose();
      });
      await host.startHost(port: 0, address: '127.0.0.1');
      Future<void> join() async {
        session.prepareJoin();
        await session.transport.connect(
          host: '127.0.0.1',
          port: host.listeningPort!,
        );
        await until(() => session.status == ChatStatus.ready);
      }

      await join();
      session.draft = 'Before leaving';
      await session.sendDraft();
      await until(() => session.draft.isEmpty);
      session.draft = 'Keep draft';
      await session.leave();
      await host.sendText('Missed message');
      await join();
      await until(
        () => session.messages.any((e) => e.message.text == 'Missed message'),
      );
      expect(
        session.messages
            .where((e) => e.message.sequence > 0)
            .map((e) => e.message.text),
        ['Before leaving', 'Missed message'],
      );
      expect(session.draft, 'Keep draft');
    },
  );

  test(
    'contact-verified private group admits known contacts and rejects unknown peers',
    () async {
      final host =
          TcpMessageTransport(
              contacts: PrivateContacts('host', {'alice': 'Alice'}),
            )
            ..displayName = 'Host'
            ..requireVerifiedContact = true;
      final knownClient =
          TcpMessageTransport(
              contacts: PrivateContacts('alice', {'host': 'Host'}),
            )
            ..displayName = 'Alice'
            ..requireContactAuth = true;
      final unknownClient =
          TcpMessageTransport(
              contacts: PrivateContacts('mallory', {'host': 'Host'}),
            )
            ..displayName = 'Mallory'
            ..requireContactAuth = true;
      addTearDown(() {
        knownClient.dispose();
        unknownClient.dispose();
        host.dispose();
      });

      await host.startHost(port: 0, address: '127.0.0.1');

      await knownClient.connect(host: '127.0.0.1', port: host.listeningPort!);
      await until(() => host.joinRequests.isNotEmpty);
      await host.approveJoin(host.joinRequests.single.id);
      await until(() => knownClient.status == ChatStatus.ready);
      await knownClient.sendText('Hello from contact');
      await until(
        () => host.messages.any((e) => e.text == 'Hello from contact'),
      );

      await unknownClient.connect(host: '127.0.0.1', port: host.listeningPort!);
      await until(() => unknownClient.sessionEnded);
      expect(
        unknownClient.error,
        'Only known contacts can join this private group.',
      );
    },
  );
}
