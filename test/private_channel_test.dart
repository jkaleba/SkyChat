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

void main() {
  late PrivateContacts hostContacts;
  late PrivateContacts aliceContacts;
  late TcpMessageTransport host;
  late TcpMessageTransport alice;
  final extraPeers = <_PrivatePeer>[];
  setUp(() async {
    hostContacts = PrivateContacts('host', {'alice': 'Alice', 'bob': 'Bob'});
    aliceContacts = PrivateContacts('alice', {'host': 'Host'});
    host = TcpMessageTransport(contacts: hostContacts)
      ..requireVerifiedContact = true;
    alice = TcpMessageTransport(contacts: aliceContacts)
      ..requireContactAuth = true;
    await host.startHost(port: 0, address: '127.0.0.1');
    expect(host.status, ChatStatus.ready);
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
  Future<void> approve() async {
    await until(() => host.joinRequests.isNotEmpty);
    await host.approveJoin(host.joinRequests.single.id);
    await until(() => alice.status == ChatStatus.ready);
  }

  Future<_PrivatePeer> peer(PrivateContacts contacts) async {
    final peer = _PrivatePeer(
      await PrivateChannel(contacts).connect('127.0.0.1', host.listeningPort!),
    );
    extraPeers.add(peer);
    return peer;
  }

  test(
    'verified contact receives no chat or roster until this host approves',
    () async {
      await connect();
      await until(() => alice.waitingForApproval);
      expect(host.joinRequests.single.name, 'Alice');
      expect(alice.selfId, isNull);
      expect(alice.participants, isEmpty);
      await host.sendText('Before approval');
      expect(alice.messages, isEmpty);
      await approve();
      expect(alice.privateChannelAuthenticated, isTrue);
      expect(host.joinRequests, isEmpty);
      expect(texts(alice), isEmpty);
      await alice.sendText('Encrypted message');
      expect(texts(host).last.text, 'Encrypted message');
    },
  );

  test(
    'decline exposes no conversation and a new group requires fresh approval',
    () async {
      await connect();
      await until(() => host.joinRequests.isNotEmpty);
      host.rejectJoin(host.joinRequests.single.id);
      await until(() => alice.sessionEnded);
      expect(alice.messages, isEmpty);
      expect(alice.participants, isEmpty);
      expect(alice.error, contains('declined'));
      alice.resetSession();
      await connect();
      await approve();
      await alice.close();
      await host.startHost(port: 0, address: '127.0.0.1');
      alice.resetSession();
      await connect();
      await until(() => alice.waitingForApproval);
      expect(alice.status, ChatStatus.connecting);
      expect(host.participants.length, 1);
    },
  );

  test(
    'approved resume preserves identity and removal revokes its grant',
    () async {
      await connect();
      await approve();
      final identity = alice.selfId;
      await alice.close();
      await host.sendText('While away');
      await connect();
      await until(() => alice.status == ChatStatus.ready);
      expect(alice.selfId, identity);
      expect(host.joinRequests, isEmpty);
      expect(texts(alice).last.text, 'While away');
      expect(aliceContacts.clientProofs, 2);
      await alice.close();
      host.removePrivateMember(identity!);
      await connect();
      await until(() => alice.sessionEnded);
      expect(alice.membershipRevoked, isTrue);
      expect(host.joinRequests, isEmpty);
    },
  );

  test(
    'a new host group requires an explicit new conversation and approval',
    () async {
      await connect();
      await approve();
      await alice.sendText('Old group message');
      final oldGroup = alice.groupId;
      await alice.close();
      await host.startHost(port: 0, address: '127.0.0.1');
      await connect();
      await until(() => alice.sessionEnded);
      expect(alice.error, contains('host session changed'));
      expect(host.joinRequests, isEmpty);
      expect(host.participants.length, 1);
      alice.resetSession();
      await connect();
      await until(() => alice.waitingForApproval);
      await approve();
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
      await approve();
      await alice.close();
      hostContacts.blocked.add('alice');
      await connect();
      await until(() => alice.sessionEnded);
      expect(host.joinRequests, isEmpty);
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
      expect(host.joinRequests, isEmpty);
    },
  );

  test('host proof for a different TLS certificate is rejected', () async {
    hostContacts.wrongCertificate = true;
    await connect();
    await until(() => alice.status == ChatStatus.offline);
    expect(aliceContacts.clientProofs, 0);
    expect(host.joinRequests, isEmpty);
  });

  test('another approved contact cannot use a stolen resume token', () async {
    final a = await peer(aliceContacts);
    await a.hello(aliceContacts);
    await until(() => host.joinRequests.isNotEmpty);
    expect(host.joinRequests.single.name, 'Alice');
    await host.approveJoin(host.joinRequests.single.id);
    final welcome = await a.next('welcome');
    final bobContacts = PrivateContacts('bob', {'host': 'Host'});
    final b = await peer(bobContacts);
    await b.hello(bobContacts);
    await until(() => host.joinRequests.isNotEmpty);
    await host.approveJoin(host.joinRequests.single.id);
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
    expect(host.joinRequests, isEmpty);
    await connect();
    await approve();
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
    await until(() => host.joinRequests.isNotEmpty);
    await host.approveJoin(host.joinRequests.single.id);
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
