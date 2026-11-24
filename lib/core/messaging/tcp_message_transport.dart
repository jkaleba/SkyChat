import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../contacts/contact_repository.dart';
import '../models/chat_message.dart';
import '../models/message_delivery.dart';
import '../models/participant.dart';
import 'message_transport.dart';
import 'private_channel.dart';

enum ChatStatus { offline, connecting, ready }

class _Identity {
  _Identity(this.participant);
  Participant participant;
  int lastRequest = 0;
  bool revoked = false;
}

class PrivateJoinRequest {
  const PrivateJoinRequest(this.id, this.contactId, this.name);
  final String id;
  final String contactId;
  final String name;
}

class _PendingAdmission {
  _PendingAdmission(this.request, this.frame, this.after);
  final PrivateJoinRequest request;
  final Map<String, dynamic> frame;
  final int after;
  Timer? timeout;
}

/// Foreground, in-memory protocol v3. Resume tokens are NOT authenticated identity.
class TcpMessageTransport extends ChangeNotifier implements MessageTransport {
  TcpMessageTransport({
    this.confirmationTimeout = const Duration(seconds: 6),
    this.callCapable = true,
    ContactRepository contacts = const ContactRepository(),
  }) : _contacts = contacts;
  final ContactRepository _contacts;
  bool requireVerifiedContact = false;
  bool requireContactAuth = false;
  String? _hostContactId;
  String? _selfContactId;
  final _challenges = <Socket, String>{};
  bool _awaitingChallenge = false;
  SecurityContext? _privateContext;
  String? _privateCertificate;
  String? _clientChallenge;
  String? _pinnedHostContactId;
  bool _authenticatedPrivateHost = false;
  bool _waitingForApproval = false;
  final _handshaking = <Socket>{};
  final _authenticating = <Socket>{};
  final _admissions = <Socket, _PendingAdmission>{};
  final _approvedContacts = <String>{};
  bool get waitingForApproval => _waitingForApproval;
  bool get privateChannelAuthenticated =>
      (requireVerifiedContact && _privateContext != null) ||
      (requireContactAuth && _authenticatedPrivateHost);
  List<PrivateJoinRequest> get joinRequests =>
      List.unmodifiable(_admissions.values.map((p) => p.request));
  final bool callCapable;
  bool _callRelay = false;
  String? hostId;
  bool get isHost => _isHost;
  int get connectionRevision => _epoch;
  bool get supportsCalls => callCapable && (_isHost || _callRelay);
  final _callFrames = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get callFrames => _callFrames.stream;
  final _callRates = <String, ({int second, int count})>{};

  static const protocolVersion = 3;
  static const versionMismatchMessage =
      'Incompatible chat version. Update the app on every phone, then rejoin the group.';
  static const defaultPort = 45871;
  static const maxTextLength = 2000;
  static const maxFrameBytes = 32768;
  static const historyLimit = 500;
  static const acceptanceLimit = 1000;
  static const identityLimit = 128;
  final Duration confirmationTimeout;
  final _incoming = StreamController<ChatMessage>.broadcast();
  final _messages = <ChatMessage>[];
  final _history = <ChatMessage>[];
  final _accepted = <String, ChatMessage>{};
  final _delivery = <String, MessageDelivery>{};
  final _participants = <Participant>[];
  final _peers = <Socket, _Identity?>{};
  final _identities = <String, _Identity>{};
  final _pending = <String, Completer<void>>{};
  ServerSocket? _server;
  Socket? _host;
  Timer? _heartbeat;
  _Identity? _hostIdentity;
  int _epoch = 0;
  int _sequence = 0;
  int _nextRequest = 0;
  bool _disposed = false;
  bool _isHost = false;
  bool _welcomed = false;
  bool _hasRoster = false;
  String displayName = 'Guest';

  /// Out-of-band group admission, carried only in NFC invitations for private groups.
  /// These bearer secrets are not encryption or authenticated identities.
  String? hostAdmissionToken;
  String? invitationToken;
  String? selfId;
  String? _groupId;
  String? _resumeToken;
  String? error;
  String? historyWarning;
  bool sessionEnded = false;
  bool membershipRevoked = false;
  ChatStatus status = ChatStatus.offline;
  int? get listeningPort => _server?.port;
  String? get groupId => _groupId;
  List<ChatMessage> get messages => List.unmodifiable(_messages);
  List<Participant> get participants => List.unmodifiable(_participants);
  bool get canManagePrivateMembers =>
      _isHost &&
      (hostAdmissionToken != null || requireVerifiedContact) &&
      status == ChatStatus.ready &&
      !sessionEnded;
  List<Participant> get members => canManagePrivateMembers
      ? [
          if (_hostIdentity != null) _hostIdentity!.participant,
          for (final identity in _identities.values)
            if (!identity.revoked) identity.participant,
        ]
      : participants;
  bool canRemoveMember(String id) =>
      canManagePrivateMembers &&
      _identities.values.any(
        (identity) => !identity.revoked && identity.participant.id == id,
      );
  MessageDelivery? deliveryFor(String messageId) => _delivery[messageId];
  @override
  Stream<ChatMessage> get incoming => _incoming.stream;

  static final _random = Random.secure();
  static String _id() => List.generate(
    16,
    (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Explicit new conversation only. Reconnecting never calls this.
  void resetSession() {
    _stop();
    _messages.clear();
    _history.clear();
    _accepted.clear();
    _delivery.clear();
    _identities.clear();
    _hostIdentity = null;
    selfId = null;
    _groupId = null;
    _resumeToken = null;
    _selfContactId = null;
    _hostContactId = null;
    _pinnedHostContactId = null;
    _approvedContacts.clear();
    _sequence = 0;
    _nextRequest = 0;
    sessionEnded = false;
    membershipRevoked = false;
    historyWarning = null;
    error = null;
    _notify();
  }

  void _prepare() {
    _stop();
    error = null;
    _welcomed = false;
    _hasRoster = false;
    _authenticatedPrivateHost = false;
    _waitingForApproval = false;
    status = ChatStatus.connecting;
    _notify();
  }

  @override
  Future<void> startHost({
    required int port,
    String address = '0.0.0.0',
  }) async {
    resetSession();
    _isHost = true;
    _prepare();
    final epoch = _epoch;
    try {
      _hostContactId ??= await _loadSelfContactId();
      if (requireVerifiedContact) {
        if (_hostContactId == null) {
          throw StateError('Contact identity unavailable');
        }
        final material = await PrivateChannel(_contacts).createHost();
        if (epoch != _epoch) return;
        _privateContext = material.context;
        _privateCertificate = material.fingerprint;
      }
      final server = await ServerSocket.bind(address, port);
      if (epoch != _epoch) {
        await server.close();
        return;
      }
      _server = server;
      selfId = _id();
      _groupId = _id();
      _hostIdentity = _Identity(
        Participant(
          id: selfId!,
          displayName: _name(displayName),
          canCall: callCapable,
          contactId: _hostContactId,
        ),
      );
      _participants.add(_hostIdentity!.participant);
      hostId = selfId;
      status = ChatStatus.ready;
      server.listen(
        (socket) {
          if (epoch != _epoch || _peers.length + _handshaking.length >= 15) {
            socket.destroy();
            return;
          }
          if (requireVerifiedContact) {
            unawaited(_secureIncoming(socket, epoch));
          } else {
            _acceptSocket(socket, epoch);
          }
        },
        onError: (Object _) {
          if (epoch == _epoch) _end('Host chat stopped. Create a new group.');
        },
      );
      _startHeartbeat();
      _notify();
    } catch (_) {
      if (epoch == _epoch) _fail('Could not start chat server. Retry chat.');
    }
  }

  Future<void> _secureIncoming(Socket raw, int epoch) async {
    _handshaking.add(raw);
    try {
      final socket =
          await SecureSocket.secureServer(
                raw,
                _privateContext!,
                supportedProtocols: [PrivateChannel.protocol],
              )
              .then((socket) {
                if (epoch != _epoch || !_handshaking.contains(raw)) {
                  socket.destroy();
                }
                return socket;
              })
              .timeout(const Duration(seconds: 5));
      if (epoch != _epoch) {
        socket.destroy();
        return;
      }
      _acceptSocket(socket, epoch);
    } catch (_) {
      raw.destroy();
    } finally {
      _handshaking.remove(raw);
    }
  }

  void _acceptSocket(Socket socket, int epoch) {
    _peers[socket] = null;
    _listen(socket, epoch);
    Future<void>.delayed(const Duration(seconds: 8), () {
      if (epoch == _epoch &&
          _peers.containsKey(socket) &&
          _peers[socket] == null &&
          !_admissions.containsKey(socket)) {
        _lost(socket);
      }
    });
  }

  @override
  Future<void> connect({required String host, required int port}) async {
    if (sessionEnded) return;
    _isHost = false;
    _prepare();
    final epoch = _epoch;
    for (var attempt = 0; attempt < 5 && epoch == _epoch; attempt++) {
      try {
        final Socket socket = requireContactAuth
            ? await PrivateChannel(_contacts).connect(host, port)
            : await Socket.connect(
                host,
                port,
                timeout: const Duration(seconds: 2),
              );
        if (epoch != _epoch) {
          socket.destroy();
          return;
        }
        _host = socket;
        _awaitingChallenge = requireContactAuth;
        if (requireContactAuth && socket is! SecureSocket) {
          socket.destroy();
          throw StateError('Private TLS protocol unavailable');
        }
        _listen(socket, epoch);
        if (requireContactAuth) {
          _clientChallenge = _id() + _id();
          _write(socket, {'type': 'private_open', 'nonce': _clientChallenge});
        } else {
          await _loadSelfContactId();
          if (epoch != _epoch || !identical(_host, socket)) return;
          _sendHello(socket);
        }
        _startHeartbeat();
        Future<void>.delayed(const Duration(seconds: 12), () {
          if (epoch == _epoch &&
              status == ChatStatus.connecting &&
              !_waitingForApproval) {
            _fail('Host did not finish chat synchronization. Retry chat.');
          }
        });
        return;
      } catch (_) {
        if (attempt < 4) {
          await Future<void>.delayed(const Duration(milliseconds: 500));
        }
      }
    }
    if (epoch == _epoch) {
      _fail('Cannot reach the host. Retry chat or rejoin its Wi-Fi group.');
    }
  }

  void _startHeartbeat() {
    _heartbeat = Timer.periodic(const Duration(seconds: 10), (_) {
      for (final socket in [..._peers.keys, if (_host != null) _host!]) {
        _write(socket, {'type': 'ping'});
      }
    });
  }

  void _listen(Socket socket, int epoch) {
    final buffer = <int>[];
    socket.done.then<void>(
      (_) {},
      onError: (Object _) {
        if (epoch == _epoch) _lost(socket);
      },
    );
    socket
        .timeout(const Duration(seconds: 35))
        .listen(
          (bytes) {
            try {
              for (final byte in bytes) {
                if (epoch != _epoch) return;
                if (byte == 10) {
                  final frame = jsonDecode(utf8.decode(buffer));
                  buffer.clear();
                  if (frame is! Map<String, dynamic> || frame['v'] is! int) {
                    throw const FormatException('Invalid protocol version');
                  }
                  if (frame['v'] != protocolVersion) {
                    if (_isHost) {
                      error = versionMismatchMessage;
                      _lost(socket);
                      _notify();
                    } else {
                      _fail(versionMismatchMessage);
                    }
                    return;
                  }
                  _receive(socket, frame);
                } else {
                  buffer.add(byte);
                  if (buffer.length > maxFrameBytes) {
                    throw const FormatException('Frame too large');
                  }
                }
              }
            } catch (_) {
              if (epoch == _epoch) _lost(socket);
            }
          },
          onError: (Object _) {
            if (epoch == _epoch) _lost(socket);
          },
          onDone: () {
            if (epoch == _epoch) _lost(socket);
          },
          cancelOnError: true,
        );
  }

  static String _string(Object? value, int max) {
    if (value is! String || value.trim().isEmpty || value.length > max) {
      throw const FormatException('Invalid text field');
    }
    return value;
  }

  static int _number(Object? value) {
    if (value is! int || value < 0 || value > 9007199254740991) {
      throw const FormatException('Invalid sequence');
    }
    return value;
  }

  static int _request(String id) {
    final value = int.tryParse(id);
    if (value == null || value <= 0 || value.toString() != id) {
      throw const FormatException('Invalid request ID');
    }
    return _number(value);
  }

  Future<String?> _loadSelfContactId() async {
    if (_selfContactId != null) return _selfContactId;
    try {
      _selfContactId = (await _contacts.load()).identity;
    } catch (_) {
      // Best-effort; unavailable in unit tests without contacts channel.
    }
    return _selfContactId;
  }

  void _sendHello(Socket socket, {String? contactAuth}) {
    _write(socket, {
      'type': 'hello',
      'name': _name(displayName),
      'calls': callCapable ? 1 : 0,
      'after': _sequence,
      if (_selfContactId != null) 'contactId': _selfContactId,
      if (_resumeToken != null) 'token': _resumeToken,
      if (_groupId != null) 'groupId': _groupId,
      if (_resumeToken == null && invitationToken != null)
        'admissionToken': invitationToken,
      if (contactAuth != null) 'contactAuth': contactAuth,
    });
  }

  Future<void> _openPrivateChannel(
    Socket socket,
    Map<String, dynamic> frame,
    int epoch,
  ) async {
    if (socket is! SecureSocket ||
        _challenges.containsKey(socket) ||
        !_authenticating.add(socket)) {
      _lost(socket);
      return;
    }
    try {
      final nonce = _string(frame['nonce'], 64);
      if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(nonce)) {
        throw const FormatException('Invalid challenge');
      }
      final challenge = _id() + _id();
      _challenges[socket] = challenge;
      final group = _groupId!;
      final proof = await _contacts
          .signPrivateChannel({
            'role': 'host',
            'to': '',
            'nonce': nonce,
            'certificate': _privateCertificate!,
            'group': group,
          })
          .timeout(const Duration(seconds: 4));
      if (epoch != _epoch || !_peers.containsKey(socket)) return;
      _write(socket, {
        'type': 'private_host',
        'nonce': challenge,
        'group': group,
        'proof': proof,
      });
    } catch (_) {
      if (epoch == _epoch) _lost(socket);
    } finally {
      _authenticating.remove(socket);
    }
  }

  Future<void> _authenticatePrivateHost(
    Socket socket,
    Map<String, dynamic> frame,
    int epoch,
  ) async {
    try {
      if (socket is! SecureSocket || socket.peerCertificate == null) {
        throw StateError('Private TLS certificate unavailable');
      }
      final group = _string(frame['group'], 32);
      final nonce = _string(frame['nonce'], 64);
      if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(group) ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(nonce)) {
        throw const FormatException('Invalid private handshake');
      }
      final certificate = PrivateChannel.fingerprint(socket.peerCertificate!);
      final host = await _contacts
          .verifyPrivateChannel(_string(frame['proof'], 24000), {
            'role': 'host',
            'nonce': _clientChallenge!,
            'certificate': certificate,
            'group': group,
            if (_pinnedHostContactId != null) 'from': _pinnedHostContactId,
          })
          .timeout(const Duration(seconds: 4));
      if (epoch != _epoch || !identical(socket, _host)) return;
      if (_groupId != null && _groupId != group) {
        _end('The host session changed. Start a new chat explicitly.');
        return;
      }
      final proof = await _contacts
          .signPrivateChannel({
            'role': 'client',
            'to': host,
            'nonce': nonce,
            'certificate': certificate,
            'group': group,
          })
          .timeout(const Duration(seconds: 4));
      await _loadSelfContactId();
      if (epoch != _epoch || !identical(socket, _host)) return;
      _pinnedHostContactId = host;
      _authenticatedPrivateHost = true;
      _sendHello(socket, contactAuth: proof);
    } catch (_) {
      if (epoch == _epoch && identical(socket, _host)) {
        _fail(
          'Could not verify this private group. Verify the host by NFC and retry.',
        );
      }
    }
  }

  static String _name(String value) => value.trim().isEmpty
      ? 'Guest'
      : value.trim().substring(0, min(value.trim().length, 32));

  void _receive(Socket socket, Map<String, dynamic> frame) {
    final type = frame['type'];
    if (!_isHost &&
        requireContactAuth &&
        !_authenticatedPrivateHost &&
        type != 'private_host') {
      throw const FormatException('Private host is not authenticated');
    }
    if (type == 'ping') {
      _write(socket, {'type': 'pong'});
      return;
    }
    if (type == 'pong') return;
    if (_isHost) {
      if (!_peers.containsKey(socket)) return;
      final identity = _peers[socket];
      if (type == 'private_open' &&
          identity == null &&
          requireVerifiedContact) {
        unawaited(_openPrivateChannel(socket, frame, _epoch));
      } else if (type == 'hello' && identity == null) {
        _hello(socket, frame);
      } else if (type == 'call' &&
          identity != null &&
          identity.participant.canCall &&
          callCapable) {
        _routeCall(
          identity.participant.id,
          _string(frame['to'], 64),
          _string(frame['token'], 24000),
        );
      } else if (type == 'received' && identity != null) {
        final id = _string(frame['id'], 130);
        final sequence = _number(frame['sequence']);
        final delivery = _delivery[id];
        final participantId = identity.participant.id;
        if (delivery != null &&
            delivery.sequence == sequence &&
            delivery.recipients.any((p) => p.id == participantId) &&
            !delivery.received.contains(participantId)) {
          _delivery[id] = delivery.acknowledge(participantId);
          _publishDelivery(id);
        }
      } else if (type == 'send' && identity != null) {
        final request = _string(frame['id'], 16);
        try {
          _accept(
            identity,
            request,
            _string(frame['text'], maxTextLength),
            socket: socket,
          );
        } on StateError catch (e) {
          _write(socket, {
            'type': 'rejected',
            'id': request,
            'reason': e.message,
          });
        }
      } else {
        throw const FormatException('Unexpected frame');
      }
      return;
    }
    switch (type) {
      case 'private_host':
        if (!requireContactAuth || !_awaitingChallenge || _welcomed) {
          throw const FormatException('Unexpected private host proof');
        }
        _awaitingChallenge = false;
        unawaited(_authenticatePrivateHost(socket, frame, _epoch));
      case 'approval_pending':
        if (!requireContactAuth || !_authenticatedPrivateHost || _welcomed) {
          throw const FormatException('Unexpected approval request');
        }
        _waitingForApproval = true;
        _notify();
      case 'call':
        if (supportsCalls && _welcomed && frame['to'] == selfId) {
          final from = _string(frame['from'], 64);
          if (_participants.any((p) => p.id == from && p.canCall) &&
              _allowCall(from)) {
            _callFrames.add({
              'from': from,
              'token': _string(frame['token'], 24000),
            });
          }
        }
        return;
      case 'ended':
        membershipRevoked = frame['code'] == 'revoked';
        _end(_string(frame['reason'], 200));
      case 'welcome':
        if (_welcomed) throw const FormatException('Duplicate welcome');
        final group = _string(frame['groupId'], 64);
        final id = _string(frame['selfId'], 64);
        final token = _string(frame['token'], 64);
        if (_groupId != null &&
            (group != _groupId || id != selfId || token != _resumeToken)) {
          _end('The host session changed. Start a new chat explicitly.');
          return;
        }
        final baseline = _number(frame['baseline']);
        if (_groupId != null && baseline < _sequence) {
          throw const FormatException('Cursor went backwards');
        }
        selfId = id;
        _groupId = group;
        _resumeToken = token;
        _waitingForApproval = false;
        _sequence = baseline;
        if (frame['gap'] == true) {
          historyWarning =
              'Some missed messages are no longer available from the host.';
        }
        _welcomed = true;
        _callRelay = frame['calls'] == 1;
        hostId = frame['hostId'] as String?;
      case 'roster':
        if (!_welcomed) throw const FormatException('Missing welcome');
        final list = frame['participants'];
        if (list is! List || list.isEmpty || list.length > 16) {
          throw const FormatException('Invalid roster');
        }
        final participants = list
            .map(
              (p) => Participant(
                id: _string(p['id'], 64),
                displayName: _string(p['name'], 32),
                canCall: p['calls'] == 1,
                contactId: p['contactId'] is String
                    ? _string(p['contactId'], 128)
                    : null,
              ),
            )
            .toList();
        if (participants.map((p) => p.id).toSet().length !=
                participants.length ||
            !participants.any((p) => p.id == selfId)) {
          throw const FormatException('Invalid identities');
        }
        _participants
          ..clear()
          ..addAll(participants);
        _hasRoster = true;
        _notice(_string(frame['notice'], 100));
      case 'synced':
        if (!_welcomed ||
            !_hasRoster ||
            _number(frame['through']) != _sequence ||
            status != ChatStatus.connecting) {
          throw const FormatException('Incomplete replay');
        }
        status = ChatStatus.ready;
        // Re-send receipts that may have been lost after recording but before
        // disconnecting, even when the replay cursor already includes the text.
        for (final message in _messages) {
          if (message.sequence > 0 && message.senderId != selfId) {
            _write(socket, {
              'type': 'received',
              'id': message.id,
              'sequence': message.sequence,
            });
          }
        }
        _notify();
      case 'message':
      case 'ack':
        if (!_welcomed || !_hasRoster) throw const FormatException('Not ready');
        final senderId = _string(frame['senderId'], 64);
        final contactId = frame['contactId'] is String
            ? _string(frame['contactId'], 128)
            : _participants
                  .where((p) => p.id == senderId)
                  .map((p) => p.contactId)
                  .firstOrNull;
        final message = ChatMessage(
          id: _string(frame['id'], 130),
          groupId: _groupId!,
          senderId: senderId,
          senderName: _string(frame['name'], 32),
          senderContactId: contactId,
          text: _string(frame['text'], maxTextLength),
          sentAt: DateTime.parse(_string(frame['time'], 40)),
          sequence: _number(frame['sequence']),
        );
        if (message.sequence == 0) {
          throw const FormatException('Invalid message cursor');
        }
        if (type == 'message') {
          if (message.sequence != _sequence + 1) {
            throw const FormatException('Message gap');
          }
          _sequence = message.sequence;
        } else if (message.senderId != selfId || message.sequence > _sequence) {
          throw const FormatException('Invalid acknowledgement');
        }
        _record(message);
        _pending.remove(message.id)?.complete();
        if (type == 'message' && message.senderId != selfId) {
          _write(socket, {
            'type': 'received',
            'id': message.id,
            'sequence': message.sequence,
          });
        }
      case 'delivery':
        if (!_welcomed || !_hasRoster) throw const FormatException('Not ready');
        final id = _string(frame['id'], 130);
        final sequence = _number(frame['sequence']);
        final list = frame['recipients'];
        final hostId = frame['hostId'] == null
            ? null
            : _string(frame['hostId'], 64);
        if (!id.startsWith('$selfId:') ||
            sequence == 0 ||
            sequence > _sequence ||
            list is! List ||
            list.length > 15) {
          throw const FormatException('Invalid delivery snapshot');
        }
        _request(id.substring(selfId!.length + 1));
        final recipients = <Participant>[];
        final received = <String>{};
        for (final item in list) {
          if (item is! Map || item['received'] is! bool) {
            throw const FormatException('Invalid recipient');
          }
          final recipientId = _string(item['id'], 64);
          if (recipientId == selfId ||
              recipients.any((p) => p.id == recipientId)) {
            throw const FormatException('Invalid recipient identity');
          }
          recipients.add(
            Participant(
              id: recipientId,
              displayName: _string(item['name'], 32),
            ),
          );
          if (item['received'] == true) received.add(recipientId);
        }
        final previous = _delivery[id];
        if (previous != null &&
            (previous.sequence != sequence ||
                previous.hostId != hostId ||
                !setEquals(
                  previous.recipients.map((p) => p.id).toSet(),
                  recipients.map((p) => p.id).toSet(),
                ) ||
                !received.containsAll(previous.received))) {
          throw const FormatException(
            'Delivery cannot regress or change targets',
          );
        }
        _delivery[id] = MessageDelivery(
          sequence: sequence,
          hostId: hostId,
          recipients: recipients,
          received: received,
        );
        if (_delivery.length > acceptanceLimit) {
          _delivery.remove(_delivery.keys.first);
        }
        _notify();
      case 'rejected':
        if (!_welcomed) throw const FormatException('Missing welcome');
        final id = '$selfId:${_string(frame['id'], 16)}';
        _pending
            .remove(id)
            ?.completeError(StateError(_string(frame['reason'], 200)));
      default:
        throw const FormatException('Unknown frame');
    }
  }

  void _hello(Socket socket, Map<String, dynamic> frame) {
    final name = _string(frame['name'], 32);
    final after = _number(frame['after']);
    final resume = frame['token'] != null || frame['groupId'] != null;
    if (!resume && after != 0) {
      throw const FormatException('New participant cursor');
    }
    if (!resume &&
        hostAdmissionToken != null &&
        frame['admissionToken'] != hostAdmissionToken) {
      _rejectSession(
        socket,
        'This private group requires an NFC invitation. Tap the host to join.',
      );
      return;
    }
    if (requireVerifiedContact) {
      final challenge = _challenges.remove(socket);
      final contactAuth = frame['contactAuth'];
      final epoch = _epoch;
      if (socket is! SecureSocket ||
          challenge == null ||
          !_authenticating.add(socket) ||
          contactAuth is! String ||
          contactAuth.isEmpty) {
        _rejectSession(
          socket,
          'Only known contacts can join this private group.',
        );
        return;
      }
      unawaited(() async {
        try {
          final verified = await _contacts
              .verifyPrivateChannel(contactAuth, {
                'role': 'client',
                'nonce': challenge,
                'certificate': _privateCertificate!,
                'group': _groupId!,
              })
              .timeout(const Duration(seconds: 4));
          final snapshot = await _contacts.load().timeout(
            const Duration(seconds: 4),
          );
          final contact = snapshot.contacts
              .where(
                (c) => c.id == verified && c.trust == ContactTrust.verified,
              )
              .single;
          if (epoch != _epoch || !_peers.containsKey(socket)) return;
          // Authentication is required on every reconnect, including token resume.
          if (resume || _approvedContacts.contains(verified)) {
            _completeHello(
              socket,
              frame,
              contact.name,
              after,
              resume,
              verifiedContactId: verified,
            );
          } else {
            final pending = _PendingAdmission(
              PrivateJoinRequest(_id(), verified, contact.name),
              frame,
              after,
            );
            _admissions[socket] = pending;
            pending.timeout = Timer(const Duration(seconds: 60), () {
              if (epoch == _epoch && identical(_admissions[socket], pending)) {
                _rejectSession(
                  socket,
                  'The host did not approve your request. Try joining again.',
                );
              }
            });
            _write(socket, {'type': 'approval_pending'});
            _notify();
          }
        } catch (_) {
          if (epoch == _epoch && _peers.containsKey(socket)) {
            _rejectSession(
              socket,
              'Only known contacts can join this private group.',
            );
          }
        } finally {
          _authenticating.remove(socket);
        }
      }());
      return;
    }
    _completeHello(socket, frame, name, after, resume);
  }

  /// Approvals belong to this live group and this verified contact only.
  Future<void> approveJoin(String requestId) async {
    if (!_isHost || !requireVerifiedContact || sessionEnded) return;
    final entry = _admissions.entries
        .where((e) => e.value.request.id == requestId)
        .firstOrNull;
    if (entry == null) return;
    final epoch = _epoch;
    final pending = entry.value;
    try {
      final snapshot = await _contacts.load().timeout(
        const Duration(seconds: 4),
      );
      if (epoch != _epoch || !identical(_admissions[entry.key], pending)) {
        return;
      }
      final contact = snapshot.contacts
          .where(
            (c) =>
                c.id == pending.request.contactId &&
                c.trust == ContactTrust.verified,
          )
          .single;
      _admissions.remove(entry.key);
      pending.timeout?.cancel();
      _approvedContacts.add(contact.id);
      _completeHello(
        entry.key,
        pending.frame,
        contact.name,
        pending.after,
        false,
        verifiedContactId: contact.id,
      );
      _notify();
    } catch (_) {
      if (epoch == _epoch && identical(_admissions[entry.key], pending)) {
        _rejectSession(entry.key, 'This contact is no longer verified.');
      }
    }
  }

  void rejectJoin(String requestId) {
    if (!_isHost) return;
    final entry = _admissions.entries
        .where((e) => e.value.request.id == requestId)
        .firstOrNull;
    if (entry != null) {
      _rejectSession(entry.key, 'The host declined your request to join.');
    }
  }

  void _completeHello(
    Socket socket,
    Map<String, dynamic> frame,
    String name,
    int after,
    bool resume, {
    String? verifiedContactId,
  }) {
    final claimedContactId = frame['contactId'] is String
        ? _string(frame['contactId'], 128)
        : null;
    final contactId = verifiedContactId ?? claimedContactId;
    String token;
    _Identity identity;
    if (resume) {
      token = _string(frame['token'], 64);
      final existing = _identities[token];
      if (requireVerifiedContact &&
          (existing == null ||
              existing.participant.contactId != verifiedContactId ||
              !_approvedContacts.contains(verifiedContactId))) {
        _rejectSession(
          socket,
          'Your membership in this private group is no longer valid.',
          code: 'revoked',
        );
        return;
      }
      if (frame['groupId'] == _groupId && existing?.revoked == true) {
        _rejectSession(
          socket,
          'The host removed you from this private group. A new NFC invitation is required.',
          code: 'revoked',
        );
        return;
      }
      if (frame['groupId'] != _groupId ||
          existing == null ||
          after > _sequence) {
        _rejectSession(
          socket,
          'The previous host session is no longer available. Start a new chat explicitly.',
        );
        return;
      }
      identity = existing;
      for (final entry in _peers.entries.toList()) {
        if (identical(entry.value, identity)) {
          _peers.remove(entry.key);
          entry.key.destroy();
        }
      }
      _participants.removeWhere((p) => p.id == identity.participant.id);
    } else {
      if (after != 0) throw const FormatException('New participant cursor');
      MapEntry<String, _Identity>? matched;
      if (contactId != null && contactId.isNotEmpty) {
        for (final entry in _identities.entries) {
          if (!entry.value.revoked &&
              entry.value.participant.contactId == contactId) {
            matched = entry;
            break;
          }
        }
      }
      if (matched != null) {
        token = matched.key;
        identity = matched.value;
        for (final entry in _peers.entries.toList()) {
          if (identical(entry.value, identity)) {
            _peers.remove(entry.key);
            entry.key.destroy();
          }
        }
        _participants.removeWhere((p) => p.id == identity.participant.id);
      } else {
        if (_identities.length >= identityLimit) {
          _rejectSession(
            socket,
            'This session has reached its participant limit. Ask the host to start a new group.',
          );
          return;
        }
        token = _id();
        identity = _Identity(Participant(id: _id(), displayName: name));
        _identities[token] = identity;
      }
    }
    identity.participant = Participant(
      id: identity.participant.id,
      displayName: name,
      canCall: frame['calls'] == 1,
      contactId: contactId ?? identity.participant.contactId,
    );
    _peers[socket] = identity;
    if (error == versionMismatchMessage) error = null;
    _participants.add(identity.participant);
    final oldest = _history.isEmpty ? _sequence + 1 : _history.first.sequence;
    final baseline = resume ? max(after, oldest - 1) : _sequence;
    _write(socket, {
      'type': 'welcome',
      'calls': callCapable ? 1 : 0,
      'hostId': selfId,
      'selfId': identity.participant.id,
      'groupId': _groupId,
      'token': token,
      'baseline': baseline,
      'gap': resume && after < oldest - 1,
    });
    _roster(
      '${identity.participant.displayName} ${resume ? 'rejoined' : 'joined'}',
    );
    if (resume) {
      for (final message in _history) {
        if (message.sequence > baseline) _write(socket, _frame(message));
      }
      for (final message in _accepted.values) {
        if (message.senderId == identity.participant.id) {
          _write(socket, _deliveryFrame(message.id));
        }
      }
    }
    _write(socket, {'type': 'synced', 'through': _sequence});
  }

  void _rejectSession(Socket socket, String reason, {String? code}) {
    _clearPendingPeer(socket);
    _write(socket, {
      'type': 'ended',
      'reason': reason,
      if (code != null) 'code': code,
    });
    _peers.remove(socket);
    _drain(socket);
    _notify();
  }

  /// Removes a member from a private group, rotating [hostAdmissionToken] if used.
  void removePrivateMember(String participantId, {String? newAdmissionToken}) {
    if (!canRemoveMember(participantId)) {
      throw StateError(
        'Private membership changed. Refresh the participant list.',
      );
    }
    if (hostAdmissionToken != null) {
      if (newAdmissionToken == null ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(newAdmissionToken) ||
          newAdmissionToken == hostAdmissionToken) {
        throw StateError(
          'Private membership changed. Refresh the participant list.',
        );
      }
      hostAdmissionToken = newAdmissionToken;
    }
    final identity = _identities.values.singleWhere(
      (i) => i.participant.id == participantId,
    );
    identity.revoked = true;
    _approvedContacts.remove(identity.participant.contactId);
    for (final entry in _admissions.entries.toList()) {
      if (entry.value.request.contactId == identity.participant.contactId) {
        _rejectSession(
          entry.key,
          'The host removed you from this private group.',
          code: 'revoked',
        );
      }
    }
    for (final entry in _peers.entries.toList()) {
      if (identical(entry.value, identity)) {
        _rejectSession(
          entry.key,
          hostAdmissionToken != null
              ? 'The host removed you from this private group. A new NFC invitation is required.'
              : 'The host removed you from this private group.',
          code: 'revoked',
        );
      }
    }
    _participants.removeWhere((p) => p.id == participantId);
    _roster('${identity.participant.displayName} was removed');
  }

  Map<String, Object?> _frame(
    ChatMessage message, {
    String type = 'message',
  }) => {
    'type': type,
    'id': message.id,
    'senderId': message.senderId,
    'name': message.senderName,
    if (message.senderContactId != null) 'contactId': message.senderContactId,
    'text': message.text,
    'time': message.sentAt.toIso8601String(),
    'sequence': message.sequence,
  };

  void _accept(
    _Identity identity,
    String requestId,
    String text, {
    Socket? socket,
  }) {
    final request = _request(requestId);
    final sender = identity.participant;
    final id = '${sender.id}:$requestId';
    final previous = _accepted[id];
    if (previous != null) {
      if (previous.text != text) {
        throw StateError('A retry must keep the original message text.');
      }
      if (socket != null) {
        _write(socket, _frame(previous, type: 'ack'));
        _write(socket, _deliveryFrame(id));
      }
      return;
    }
    if (request <= identity.lastRequest) {
      throw StateError(
        'This old request cannot be confirmed safely. It will not be sent again.',
      );
    }
    identity.lastRequest = request;
    final message = ChatMessage(
      id: id,
      groupId: _groupId!,
      senderId: sender.id,
      senderName: sender.displayName,
      senderContactId: sender.contactId,
      text: text,
      sentAt: DateTime.now().toUtc(),
      sequence: ++_sequence,
    );
    _accepted[id] = message;
    _delivery[id] = MessageDelivery(
      sequence: message.sequence,
      hostId: selfId,
      recipients: _participants.where((p) => p.id != sender.id).toList(),
      received: sender.id == selfId ? {} : {selfId!},
    );
    if (_accepted.length > acceptanceLimit) {
      final expired = _accepted.keys.first;
      _accepted.remove(expired);
      _delivery.remove(expired);
    }
    _history.add(message);
    if (_history.length > historyLimit) _history.removeAt(0);
    _record(message);
    _broadcast(_frame(message));
    _publishDelivery(id);
  }

  Map<String, Object?> _deliveryFrame(String id) {
    final delivery = _delivery[id]!;
    return {
      'type': 'delivery',
      'id': id,
      'sequence': delivery.sequence,
      'hostId': delivery.hostId,
      'recipients': [
        for (final p in delivery.recipients)
          {
            'id': p.id,
            'name': p.displayName,
            'received': delivery.received.contains(p.id),
          },
      ],
    };
  }

  void _publishDelivery(String id) {
    final sender = _accepted[id]!.senderId;
    if (sender == selfId) {
      _notify();
      return;
    }
    for (final entry in _peers.entries.toList()) {
      if (entry.value?.participant.id == sender) {
        _write(entry.key, _deliveryFrame(id));
      }
    }
  }

  void _record(ChatMessage message) {
    if (_messages.any((m) => m.id == message.id)) return;
    final index = message.sequence == 0
        ? -1
        : _messages.indexWhere((m) => m.sequence > message.sequence);
    if (index < 0) {
      _messages.add(message);
    } else {
      _messages.insert(index, message);
    }
    if (_messages.length > historyLimit) _messages.removeAt(0);
    _incoming.add(message);
    _notify();
  }

  void _notice(String text) => _record(
    ChatMessage(
      id: _id(),
      groupId: _groupId ?? '',
      senderId: '',
      senderName: 'Group',
      text: text,
      sentAt: DateTime.now().toUtc(),
    ),
  );

  void _roster(String notice) {
    _broadcast({
      'type': 'roster',
      'participants': [
        for (final p in _participants)
          {
            'id': p.id,
            'name': p.displayName,
            'calls': p.canCall ? 1 : 0,
            if (p.contactId != null) 'contactId': p.contactId,
          },
      ],
      'notice': notice,
    });
    _notice(notice);
  }

  void _broadcast(Map<String, Object?> frame) {
    for (final entry in _peers.entries.toList()) {
      if (entry.value != null) _write(entry.key, frame);
    }
  }

  bool _allowCall(String sender) {
    final second = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final previous = _callRates[sender];
    final count = previous?.second == second ? previous!.count + 1 : 1;
    _callRates[sender] = (second: second, count: count);
    return count <= 100;
  }

  void _routeCall(String from, String to, String token) {
    if (!_allowCall(from) ||
        !_participants.any((p) => p.id == to && p.canCall)) {
      return;
    }
    if (to == selfId) {
      _callFrames.add({'from': from, 'token': token});
    } else {
      for (final entry in _peers.entries) {
        if (entry.value?.participant.id == to) {
          _write(entry.key, {
            'type': 'call',
            'from': from,
            'to': to,
            'token': token,
          });
          return;
        }
      }
    }
  }

  void sendCall(String peer, String token) {
    if (status != ChatStatus.ready ||
        !supportsCalls ||
        !_participants.any((p) => p.id == peer && p.canCall) ||
        token.length > 24000) {
      throw StateError('Call signaling unavailable');
    }
    if (_isHost) {
      _routeCall(selfId!, peer, token);
    } else {
      _write(_host!, {'type': 'call', 'to': peer, 'token': token});
    }
  }

  void _write(Socket socket, Map<String, Object?> frame) {
    try {
      socket.add(
        utf8.encode('${jsonEncode({'v': protocolVersion, ...frame})}\n'),
      );
    } catch (_) {
      _lost(socket);
    }
  }

  ChatMessage createMessage(String text) {
    if (status != ChatStatus.ready) throw StateError('Chat is disconnected');
    return ChatMessage(
      id: '${++_nextRequest}',
      groupId: _groupId!,
      senderId: selfId!,
      senderName: displayName,
      text: _string(text.trim(), maxTextLength),
      sentAt: DateTime.now().toUtc(),
    );
  }

  Future<void> sendText(String text) async => send(createMessage(text));

  @override
  Future<void> send(ChatMessage message) async {
    if (status != ChatStatus.ready || sessionEnded) {
      throw StateError('Chat is disconnected');
    }
    if (message.groupId != _groupId || message.senderId != selfId) {
      throw StateError('Message belongs to another session');
    }
    final text = _string(message.text, maxTextLength);
    final requestId = _string(message.id, 16);
    _request(requestId);
    if (_isHost) {
      _accept(_hostIdentity!, requestId, text);
    } else {
      final id = '$selfId:$requestId';
      if (_pending.containsKey(id)) {
        throw StateError('Message is already pending');
      }
      final pending = Completer<void>();
      _pending[id] = pending;
      final acknowledged = pending.future.timeout(confirmationTimeout);
      _write(_host!, {'type': 'send', 'id': requestId, 'text': text});
      try {
        await acknowledged;
      } finally {
        if (identical(_pending[id], pending)) _pending.remove(id);
      }
    }
  }

  void _lost(Socket socket) {
    _clearPendingPeer(socket);
    socket.destroy();
    if (_isHost) {
      final identity = _peers.remove(socket);
      if (identity != null) {
        _participants.removeWhere((p) => p.id == identity.participant.id);
        _roster('${identity.participant.displayName} left');
      } else {
        _notify();
      }
    } else if (identical(socket, _host)) {
      _fail(
        'Host disconnected or stopped responding. Retry chat or rejoin the group.',
      );
    }
  }

  void _clearPendingPeer(Socket socket) {
    _admissions.remove(socket)?.timeout?.cancel();
    _challenges.remove(socket);
    _authenticating.remove(socket);
  }

  void _fail(String message) {
    _stop();
    error = message;
    _notify();
  }

  void _end(String message) {
    sessionEnded = true;
    _fail(message);
  }

  static void _drain(Socket socket) {
    unawaited(
      socket
          .close()
          .timeout(const Duration(seconds: 1))
          .then<void>(
            (_) => socket.destroy(),
            onError: (Object _) => socket.destroy(),
          ),
    );
  }

  void _stop({bool graceful = false}) {
    _epoch++;
    _heartbeat?.cancel();
    _heartbeat = null;
    _server?.close();
    _server = null;
    _host?.destroy();
    _host = null;
    _waitingForApproval = false;
    _authenticatedPrivateHost = false;
    _clientChallenge = null;
    _privateContext = null;
    _privateCertificate = null;
    for (final socket in _handshaking) {
      socket.destroy();
    }
    _handshaking.clear();
    for (final pending in _admissions.values) {
      pending.timeout?.cancel();
    }
    _admissions.clear();
    _challenges.clear();
    _authenticating.clear();
    for (final socket in _peers.keys) {
      if (graceful) {
        _drain(socket);
      } else {
        socket.destroy();
      }
    }
    _peers.clear();
    _callRates.clear();
    _callRelay = false;
    hostId = null;
    _participants.clear();
    for (final pending in _pending.values) {
      pending.completeError(
        StateError('Chat disconnected before host confirmation'),
      );
    }
    _pending.clear();
    status = ChatStatus.offline;
  }

  /// A client close suspends its session; a host close ends the group session.
  @override
  Future<void> close() async {
    if (_isHost && _groupId != null) {
      _broadcast({
        'type': 'ended',
        'reason': 'The host ended this chat session.',
      });
      sessionEnded = true;
      error = 'The host ended this chat session.';
    }
    _stop(graceful: _isHost);
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    _stop();
    _incoming.close();
    _callFrames.close();
    super.dispose();
  }
}
