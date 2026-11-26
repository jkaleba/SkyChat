import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:offline_group_messenger/core/messaging/private_channel.dart';
import 'package:offline_group_messenger/core/messaging/tcp_message_transport.dart';

import 'session_recovery_test.dart' show until, texts;
import 'support/private_contacts.dart';

class _PrivatePeer {
  _PrivatePeer(this.socket)
    : frames = StreamIterator(
        socket
            .cast<List<int>>()
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .map((line) => jsonDecode(line) as Map<String, dynamic>),
      );
  final SecureSocket socket;
  final StreamIterator<Map<String, dynamic>> frames;
  void send(Map<String, dynamic> frame) =>
      socket.write('${jsonEncode({'v': 3, ...frame})}\n');
  Future<Map<String, dynamic>> next(String type) async {
    while (await frames.moveNext().timeout(const Duration(seconds: 5))) {
      if (frames.current['type'] == type) return frames.current;
    }
    throw StateError('Connection ended before $type');
  }

  Future<void> hello(
    PrivateContacts contacts, {
    Map<String, dynamic> resume = const {},
  }) async {
    send({'type': 'private_open', 'nonce': 'a' * 64});
    final challenge = await next('private_host');
    final certificate = PrivateChannel.fingerprint(socket.peerCertificate!);
    final host = await contacts
        .verifyPrivateChannel(challenge['proof'] as String, {
          'role': 'host',
          'nonce': 'a' * 64,
          'certificate': certificate,
          'group': challenge['group'],
        });
    final proof = await contacts.signPrivateChannel({
      'role': 'client',
      'to': host,
      'nonce': challenge['nonce'],
      'certificate': certificate,
      'group': challenge['group'],
    });
    send({
      'type': 'hello',
      'name': 'Untrusted remote name',
      'after': 0,
      'contactId': contacts.identity,
      'contactAuth': proof,
      ...resume,
    });
  }

  void close() {
    socket.destroy();
    unawaited(frames.cancel());
  }
}

class GatedPrivateContacts extends PrivateContacts {
  GatedPrivateContacts(super.identity, super.trusted);
  Completer<void>? verificationGate;
  bool verifying = false;
  @override
  Future<String> verifyPrivateChannel(
    String token,
    Map<String, dynamic> expected,
  ) async {
    verifying = true;
    await verificationGate?.future;
    return super.verifyPrivateChannel(token, expected);
  }
}

void main() {
  late GatedPrivateContacts hostContacts;
  late PrivateContacts aliceContacts;
  late TcpMessageTransport host;
  late TcpMessageTransport alice;
  final extraPeers = <_PrivatePeer>[];
  setUp(() async {
    hostContacts = GatedPrivateContacts('host', {
      'alice': 'Alice',
      'bob': 'Bob',
    });
    aliceContacts = PrivateContacts('alice', {'host': 'Host'});
    host = TcpMessageTransport(contacts: hostContacts)
      ..requireVerifiedContact = true;
    alice = TcpMessageTransport(contacts: aliceContacts)
      ..requireContactAuth = true;
    await host.startHost(port: 0, address: '127.0.0.1');
    expect(host.status, ChatStatus.ready);
    expect(
      host.authenticatedHostContactId,
      (await hostContacts.load()).identity,
    );
    expect(alice.authenticatedHostContactId, isNull);
  });
  tearDown(() {
    for (final peer in extraPeers) {
      peer.close();
    }
    extraPeers.clear();
    alice.dispose();
    host.dispose();
  });
  Future<void> connect() =>
      alice.connect(host: '127.0.0.1', port: host.listeningPort!);
  Future<void> ready() async {
    await until(() => alice.status == ChatStatus.ready);
    expect(alice.authenticatedHostContactId, host.authenticatedHostContactId);
    expect(alice.waitingForApproval, isFalse);
  }

  Future<_PrivatePeer> peer(PrivateContacts contacts) async {
    final peer = _PrivatePeer(
      await PrivateChannel(contacts).connect('127.0.0.1', host.listeningPort!),
    );
    extraPeers.add(peer);
    return peer;
  }

  test(
    'verified contact joins automatically after proof, with no pre-authentication data',
    () async {
      hostContacts.verificationGate = Completer<void>();
      await connect();
      await until(() => hostContacts.verifying);
      expect(alice.selfId, isNull);
      expect(alice.participants, isEmpty);
      expect(alice.waitingForApproval, isFalse);
      await host.sendText('Before verification');
      expect(alice.messages, isEmpty);
      hostContacts.verificationGate!.complete();
      await ready();
      expect(alice.privateChannelAuthenticated, isTrue);
      expect(texts(alice), isEmpty);
      expect(
        host.participants
            .singleWhere((p) => p.contactId == 'alice')
            .displayName,
        'Alice',
      );
      await alice.sendText('Encrypted message');
      expect(texts(host).last.text, 'Encrypted message');
    },
  );

  test(
    'an unknown client receives no conversation, while verified contacts join a new group automatically',
    () async {
      hostContacts.trusted.remove('alice');
      await connect();
      await until(() => alice.sessionEnded);
      expect(alice.messages, isEmpty);
      expect(alice.participants, isEmpty);
      expect(host.participants.length, 1);
      hostContacts.trusted['alice'] = 'Alice';
      alice.resetSession();
      await connect();
      await ready();
      await alice.close();
      await host.startHost(port: 0, address: '127.0.0.1');
      alice.resetSession();
      await connect();
      await ready();
      expect(host.participants.length, 2);
    },
  );

  test(
    'removing a contact denies fresh sessions until this hosted group ends',
    () async {
      await connect();
      await ready();
      host.removePrivateMember(alice.selfId!);
      await until(() => alice.sessionEnded);
      alice.resetSession();
      await connect();
      await until(() => alice.sessionEnded);
      expect(alice.membershipRevoked, isTrue);
      expect(alice.participants, isEmpty);
      expect(host.participants.length, 1);
      await host.startHost(port: 0, address: '127.0.0.1');
      alice.resetSession();
      await connect();
      await ready();
      expect(host.participants.length, 2);
    },
  );

  test(
    'authenticated resume preserves identity and removal revokes access',
    () async {
      await connect();
      await ready();
      final identity = alice.selfId;
      await alice.close();
      await host.sendText('While away');
      await connect();
      await until(() => alice.status == ChatStatus.ready);
      expect(alice.selfId, identity);
      expect(texts(alice).last.text, 'While away');
      expect(aliceContacts.clientProofs, 2);
      await alice.close();
      host.removePrivateMember(identity!);
      await connect();
      await until(() => alice.sessionEnded);
      expect(alice.membershipRevoked, isTrue);
    },
  );

  for (final expireAcceptedMessages in [false, true]) {
    test(
      'fresh contact session sends immediately after rejoin (expired=$expireAcceptedMessages)',
      () async {
        await connect();
        await ready();
        await alice.sendText('Before leaving one');
        await alice.sendText('Before leaving two');
        final identity = alice.selfId;
        await alice.close();
        await until(() => host.participants.length == 1);
        if (expireAcceptedMessages) {
          for (var i = 0; i < TcpMessageTransport.acceptanceLimit; i++) {
            await host.sendText('Host message $i');
          }
        }
        // A fresh client/process retains the NFC identity but has no request counter.
        alice.resetSession();
        await connect();
        await until(() => alice.status == ChatStatus.ready);
        expect(alice.selfId, identity);
        await alice.sendText('First new message');
        await alice.sendText('Second new message');
        expect(
          texts(host).where((m) => m.senderId == identity).map((m) => m.text),
          expireAcceptedMessages
              ? ['First new message', 'Second new message']
              : [
                  'Before leaving one',
                  'Before leaving two',
                  'First new message',
                  'Second new message',
                ],
        );
        expect(
          texts(host)
              .where((m) => m.senderId == identity)
              .map((m) => m.id)
              .toSet()
              .length,
          expireAcceptedMessages ? 2 : 4,
        );
      },
    );
  }

  test(
    'a new host group requires an explicit new conversation before automatic admission',
    () async {
      await connect();
      await ready();
      await alice.sendText('Old group message');
      final oldGroup = alice.groupId;
      await alice.close();
      await host.startHost(port: 0, address: '127.0.0.1');
      await connect();
      await until(() => alice.sessionEnded);
      expect(alice.error, contains('host session changed'));
      expect(host.participants.length, 1);
      alice.resetSession();
      await connect();
      await ready();
      expect(alice.groupId, isNot(oldGroup));
      expect(texts(alice), isEmpty);
      await alice.sendText('First message in the new group');
      expect(texts(host).single.text, 'First message in the new group');
    },
  );

  test(
    'blocked contact cannot resume using its previously valid token',
    () async {
      await connect();
      await ready();
      await alice.close();
      hostContacts.blocked.add('alice');
      await connect();
      await until(() => alice.sessionEnded);
      expect(alice.status, ChatStatus.offline);
    },
  );

  test(
    'unknown host is rejected before sending identity or resume credentials',
    () async {
      aliceContacts.trusted.clear();
      await connect();
      await until(() => alice.status == ChatStatus.offline);
      expect(aliceContacts.clientProofs, 0);
      expect(alice.error, contains('verify this private group'));
    },
  );

  test('host proof for a different TLS certificate is rejected', () async {
    hostContacts.wrongCertificate = true;
    await connect();
    await until(() => alice.status == ChatStatus.offline);
    expect(aliceContacts.clientProofs, 0);
  });

  test('another verified contact cannot use a stolen resume token', () async {
    final a = await peer(aliceContacts);
    await a.hello(aliceContacts);
    final welcome = await a.next('welcome');
    final bobContacts = PrivateContacts('bob', {'host': 'Host'});
    final b = await peer(bobContacts);
    await b.hello(bobContacts);
    await b.next('welcome');
    b.close();
    final impostor = await peer(bobContacts);
    await impostor.hello(
      bobContacts,
      resume: {'token': welcome['token'], 'groupId': welcome['groupId']},
    );
    final rejection = await impostor.next('ended');
    expect(rejection['code'], 'revoked');
    expect(host.participants.any((p) => p.contactId == 'alice'), isTrue);
    await host.sendText('Only the real Alice');
    expect((await a.next('message'))['text'], 'Only the real Alice');
  });

  test('plaintext clients cannot downgrade the private listener', () async {
    final raw = await Socket.connect('127.0.0.1', host.listeningPort!);
    raw.write(
      '${jsonEncode({'v': 3, 'type': 'hello', 'name': 'Outsider', 'after': 0})}\n',
    );
    await raw.flush();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    raw.destroy();
    expect(host.status, ChatStatus.ready);
    expect(host.participants.length, 1);
    await connect();
    await ready();
  });

  test('a wire observer cannot read messages or resume credentials', () async {
    final proxy = await ServerSocket.bind('127.0.0.1', 0);
    final captured = <int>[];
    final sockets = <Socket>[];
    proxy.listen((client) async {
      final upstream = await Socket.connect('127.0.0.1', host.listeningPort!);
      sockets.addAll([client, upstream]);
      client.listen(
        (bytes) {
          captured.addAll(bytes);
          upstream.add(bytes);
        },
        onDone: upstream.destroy,
        onError: (Object _) => upstream.destroy(),
      );
      upstream.listen(
        (bytes) {
          captured.addAll(bytes);
          client.add(bytes);
        },
        onDone: client.destroy,
        onError: (Object _) => client.destroy(),
      );
    });
    addTearDown(() async {
      for (final socket in sockets) {
        socket.destroy();
      }
      await proxy.close();
    });
    final endpoint = _PrivatePeer(
      await PrivateChannel(aliceContacts).connect('127.0.0.1', proxy.port),
    );
    extraPeers.add(endpoint);
    await endpoint.hello(aliceContacts);
    final welcome = await endpoint.next('welcome');
    const message = 'This message must never be visible on the wire';
    endpoint.send({'type': 'send', 'id': '1', 'text': message});
    await until(() => texts(host).any((m) => m.text == message));
    final wire = latin1.decode(captured);
    expect(wire, isNot(contains(message)));
    expect(wire, isNot(contains(welcome['token'] as String)));
    expect(wire, isNot(contains('"contactAuth"')));
    expect(wire, isNot(contains('"type":"welcome"')));
  });
}
