import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:offline_connectivity/offline_connectivity.dart';

import '../models/chat_message.dart';
import '../models/message_delivery.dart';
import '../models/participant.dart';
import '../history/chat_history_repository.dart';
import '../history/saved_conversation.dart';
import 'tcp_message_transport.dart';

enum DeliveryState { pending, confirmed, failed }

class SessionMessage {
  SessionMessage(this.message, this.delivery, {this.failure});
  final ChatMessage message;
  DeliveryState delivery;
  String? failure;
}

/// Live session state outlives sockets and navigation; optional local archives
/// preserve messages and drafts without restoring network access or membership.
class ChatSessionController extends ChangeNotifier {
  ChatSessionController({TcpMessageTransport? transport, this.history})
    : transport = transport ?? TcpMessageTransport() {
    this.transport.addListener(_changed);
    _incoming = this.transport.incoming.listen(_receive);
    history?.addListener(_historyChanged);
  }

  final TcpMessageTransport transport;
  final ChatHistoryRepository? history;
  late final StreamSubscription<ChatMessage> _incoming;
  final _history = <ChatMessage>[];
  final _outbox = <String, SessionMessage>{};
  GroupConnectionState _connection = const GroupConnectionState();
  String? _connectionKey;
  bool? _sessionRole;
  ChatMessage? _draftRequest;
  bool _left = false;
  bool _roleChanged = false;
  bool _disposed = false;
  int _generation = 0;
  String _draft = '';
  String? _unboundDraftId;
  String? _restoredDraftGroup;
  String? _recoveredDraftMessageId;
  static const recoveredSendWarning =
      'This draft may already have reached the group. Check saved history before sending it again.';
  bool _draftTouched = false;
  bool _historyRefreshQueued = false;
  String? _archiveGroupId;
  String? _lastArchiveId;
  bool? _archivePrivate;

  String? get _archiveId {
    final group = transport.groupId;
    if (group == null) return null;
    String id;
    if (_isPrivateGroup) {
      final host = transport.authenticatedHostContactId;
      if (host == null) {
        return _archiveGroupId == group && _archivePrivate == true
            ? _lastArchiveId
            : null;
      }
      id = ChatHistoryRepository.privateConversationId(group, host);
    } else {
      id = group;
    }
    _archiveGroupId = group;
    _archivePrivate = _isPrivateGroup;
    return _lastArchiveId = id;
  }

  String get draft => _draft;
  set draft(String value) {
    _draftTouched = true;
    if (_draft == value) return;
    _draft = value;
    if (_recoveredDraftMessageId != null) {
      _recoveredDraftMessageId = null;
      if (sendError == recoveredSendWarning) sendError = null;
    }
    final saved = history;
    if (saved == null) return;
    final archive = _archiveId;
    final id = archive ?? (_unboundDraftId ??= 'draft:${_newAdmissionToken()}');
    saved.setDraft(
      id,
      _archiveTitle,
      _isPrivateGroup,
      value,
      groupId: archive == null ? null : transport.groupId,
    );
  }

  String? sendError;
  String? _configurationError;
  GroupInvitation? _joinCandidate;
  GroupInvitation? _rememberedPrivateGroup;
  bool _removingMember = false;
  bool _isPrivateGroup = false;
  String? _nearbyPeerId;

  ChatStatus get status => transport.status;
  String? get selfId => transport.selfId;
  String? get error => _configurationError ?? transport.error;
  String? get historyWarning => transport.historyWarning;
  bool get sessionEnded => _roleChanged || transport.sessionEnded;
  bool get hasConversation => transport.groupId != null || _history.isNotEmpty;
  bool get sending =>
      _outbox.values.any((e) => e.delivery == DeliveryState.pending);
  bool get networkConnected =>
      _connection.status == GroupStatus.connected &&
      _connection.hostAddress != null;
  List<Participant> get participants => transport.participants;
  List<Participant> get members => transport.members;
  bool get canManagePrivateMembers => transport.canManagePrivateMembers;
  bool get removingMember => _removingMember;
  bool get isPrivateGroup => _isPrivateGroup;
  bool get waitingForApproval => transport.waitingForApproval;
  List<PrivateJoinRequest> get joinRequests => transport.joinRequests;
  GroupInvitation? get rememberedPrivateGroup => _rememberedPrivateGroup;
  MessageDelivery? deliveryFor(String messageId) =>
      transport.deliveryFor(messageId);
  List<SessionMessage> get messages => [
    for (final message in _history)
      SessionMessage(message, DeliveryState.confirmed),
    ..._outbox.values,
  ];

  void _changed() {
    _syncSavedHistory();
    if (sessionEnded) {
      _rememberedPrivateGroup = null;
      _joinCandidate = null;
    } else if (transport.status == ChatStatus.ready && _joinCandidate != null) {
      _rememberedPrivateGroup = _joinCandidate!.privateGroup
          ? _joinCandidate
          : null;
      _joinCandidate = null;
    }
    if (!_disposed) notifyListeners();
  }

  String get _archiveTitle {
    final names = transport.participants
        .where((peer) => peer.id != transport.selfId)
        .map((peer) => peer.displayName)
        .where((name) => name.isNotEmpty)
        .take(3)
        .join(', ');
    final kind = _isPrivateGroup ? 'Private group' : 'Public group';
    return names.isEmpty ? kind : '$kind · $names';
  }

  void _historyChanged() {
    if (_disposed ||
        _historyRefreshQueued ||
        !networkConnected ||
        status != ChatStatus.ready ||
        history?.canSave != true ||
        _restoredDraftGroup == _archiveId) {
      return;
    }
    // Repository callbacks can occur while moving a draft. Defer restoration
    // so a load/retry never re-enters the same repository mutation.
    _historyRefreshQueued = true;
    scheduleMicrotask(() {
      _historyRefreshQueued = false;
      if (!_disposed && _restoredDraftGroup != _archiveId) _changed();
    });
  }

  void _syncSavedHistory() {
    final saved = history;
    final group = transport.groupId;
    if (_disposed ||
        saved == null ||
        !saved.canSave ||
        !networkConnected ||
        group == null ||
        status != ChatStatus.ready) {
      return;
    }
    final archive = _archiveId;
    if (archive == null) return;
    if (_unboundDraftId != null) {
      saved.moveDraft(
        _unboundDraftId!,
        archive,
        _archiveTitle,
        _isPrivateGroup,
        groupId: group,
      );
      _unboundDraftId = null;
    }
    if (_restoredDraftGroup != archive) {
      _restoredDraftGroup = archive;
      // Group IDs are learned from the existing handshake. Never copy a draft
      // into a different group, restore a membership, or send it automatically.
      if (!_draftTouched && _draft.isEmpty) {
        final conversation = saved.find(archive);
        _draft = conversation?.draft ?? '';
        final uncertain = conversation?.messages
            .where(
              (entry) =>
                  entry.mine &&
                  !entry.confirmed &&
                  entry.message.text == _draft.trim(),
            )
            .firstOrNull;
        if (uncertain != null) {
          _recoveredDraftMessageId = uncertain.message.id;
          sendError = recoveredSendWarning;
        }
      }
    }
    for (final entry in saved.find(archive)?.messages ?? <SavedChatMessage>[]) {
      final receipt = transport.deliveryFor(entry.message.id);
      if (entry.mine && receipt != null) {
        saved.confirm(archive, entry.message.id, receipt.checks);
      }
    }
  }

  void _receive(ChatMessage message) {
    if (_disposed || message.groupId != transport.groupId) return;
    if (message.id == _recoveredDraftMessageId) {
      _recoveredDraftMessageId = null;
      if (sendError == recoveredSendWarning) sendError = null;
    }
    final archive = history == null ? null : _archiveId;
    if (archive != null) {
      history?.record(
        archive,
        _archiveTitle,
        _isPrivateGroup,
        SavedChatMessage(
          message: message,
          mine: message.senderId == transport.selfId,
          confirmed: true,
          checks: message.senderId == transport.selfId
              ? (transport.deliveryFor(message.id)?.checks ?? 1)
              : null,
        ),
      );
    }
    _outbox.remove(message.id);
    if (!_history.any((m) => m.id == message.id)) {
      final index = message.sequence == 0
          ? -1
          : _history.indexWhere((m) => m.sequence > message.sequence);
      if (index < 0) {
        _history.add(message);
      } else {
        _history.insert(index, message);
      }
      if (_history.length > TcpMessageTransport.historyLimit) {
        _history.removeAt(0);
      }
    }
    final request = _draftRequest;
    if (request != null && '${request.senderId}:${request.id}' == message.id) {
      if (draft.trim() == request.text) draft = '';
      _draftRequest = null;
      sendError = null;
    }
    _changed();
  }

  /// Native loss suspends clients; the next connected snapshot resumes them.
  void updateConnection(
    GroupConnectionState connection, {
    required String displayName,
  }) {
    _connection = connection;
    if (connection.status == GroupStatus.connected) {
      _isPrivateGroup = connection.privateGroup;
    }
    transport.displayName = displayName;
    final key = networkConnected
        ? '${connection.isHost}:${connection.hostAddress}'
        : null;
    if (key == _connectionKey) return;
    final previousKey = _connectionKey;
    _connectionKey = key;
    if (key != null && previousKey != null) {
      // Cancel a handshake/socket for an obsolete address before starting another.
      unawaited(transport.close());
    }
    if (key == null) {
      unawaited(transport.close());
    } else if (!sessionEnded && !_left) {
      if (transport.groupId != null && _sessionRole != connection.isHost) {
        // A native role change does not migrate a conversation to a new host.
        _left = true;
        _roleChanged = true;
        unawaited(transport.close());
      } else {
        _sessionRole = connection.isHost;
        retry();
      }
    }
    _changed();
  }

  void retry() {
    if (!networkConnected ||
        _left ||
        sessionEnded ||
        status == ChatStatus.connecting) {
      return;
    }
    if (_connection.isHost) {
      if (_connection.privateGroup &&
          !transport.requireVerifiedContact &&
          transport.hostAdmissionToken == null) {
        _configurationError =
            'Private group credentials are unavailable. End this group and create it again.';
        _changed();
        return;
      }
      // A host whose listener existed must start a new session explicitly.
      if (transport.groupId != null) return;
      unawaited(
        transport.startHost(
          port: TcpMessageTransport.defaultPort,
          address: _connection.hostAddress!,
        ),
      );
    } else {
      transport.requireContactAuth = _connection.privateGroup;
      unawaited(
        transport.connect(
          host: _connection.hostAddress!,
          port: TcpMessageTransport.defaultPort,
        ),
      );
    }
  }

  /// Explicit user action; never invoked as a side effect of reconnecting.
  void beginNewSession() {
    _generation++;
    _history.clear();
    _outbox.clear();
    // A new live session leaves previous conversations and drafts in the archive.
    _draft = '';
    _unboundDraftId = null;
    _restoredDraftGroup = null;
    _recoveredDraftMessageId = null;
    _archiveGroupId = null;
    _lastArchiveId = null;
    _archivePrivate = null;
    _draftTouched = false;
    _draftRequest = null;
    sendError = null;
    _configurationError = null;
    _joinCandidate = null;
    _rememberedPrivateGroup = null;
    _left = false;
    _roleChanged = false;
    _connectionKey = null;
    _sessionRole = null;
    _isPrivateGroup = false;
    _nearbyPeerId = null;
    transport.resetSession();
    _changed();
  }

  /// Called before creating the native group. Private groups require contact verification.
  String? configureGroup({required bool privateGroup}) {
    beginNewSession();
    _isPrivateGroup = privateGroup;
    transport.requireVerifiedContact = privateGroup;
    transport.hostAdmissionToken = null;
    transport.invitationToken = null;
    return null;
  }

  void prepareJoin({GroupInvitation? invitation}) {
    if (sessionEnded) {
      beginNewSession();
    } else {
      resumeJoining();
    }
    if (invitation != null) {
      _nearbyPeerId = null;
      _isPrivateGroup = invitation.privateGroup;
    }
    transport.invitationToken = invitation?.admissionToken;
    _joinCandidate = invitation;
    transport.hostAdmissionToken = null;
    transport.requireVerifiedContact = false;
  }

  /// Nearby addresses are only a UI hint. The host still verifies the group,
  /// resume token and (for private groups) the pinned contact on every reconnect.
  void prepareNearbyJoin(NearbyPeer peer) {
    if (_nearbyPeerId != peer.id ||
        _isPrivateGroup != peer.privateGroup ||
        sessionEnded) {
      beginNewSession();
    }
    prepareJoin();
    _nearbyPeerId = peer.id;
    _isPrivateGroup = peer.privateGroup;
  }

  static String _newAdmissionToken() {
    final random = Random.secure();
    return List.generate(
      32,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  Future<void> removePrivateMember(
    String participantId, {
    required Future<void> Function(String previous, String next)
    rotateInvitation,
  }) async {
    if (_removingMember || !transport.canRemoveMember(participantId)) {
      throw StateError('This private member cannot be removed now.');
    }
    final generation = _generation;
    final group = transport.groupId;
    final previous = transport.hostAdmissionToken;
    if (previous == null) {
      transport.removePrivateMember(participantId);
      _changed();
      return;
    }
    final next = _newAdmissionToken();
    _removingMember = true;
    _changed();
    try {
      await rotateInvitation(previous, next);
      if (_disposed ||
          generation != _generation ||
          group != transport.groupId ||
          transport.hostAdmissionToken != previous ||
          !transport.canRemoveMember(participantId)) {
        throw StateError('The group changed while removing this member.');
      }
      transport.removePrivateMember(participantId, newAdmissionToken: next);
    } finally {
      _removingMember = false;
      _changed();
    }
  }

  void startNewChat() {
    final nearbyPeerId = _nearbyPeerId;
    beginNewSession();
    // Starting a new chat changes the conversation, not the selected Wi-Fi peer.
    _nearbyPeerId = nearbyPeerId;
    _isPrivateGroup = _connection.privateGroup;
    _sessionRole = _connection.isHost;
    _connectionKey = networkConnected
        ? '${_connection.isHost}:${_connection.hostAddress}'
        : null;
    retry();
  }

  Future<void> leave() async {
    _left = true;
    await transport.close();
    _changed();
  }

  /// User chose to rejoin. Preserve the session; the host validates its identity.
  void resumeJoining() {
    _left = false;
    _connectionKey = null;
    _changed();
  }

  Future<void> sendDraft() async {
    if (draft.trim().isEmpty ||
        sending ||
        status != ChatStatus.ready ||
        sessionEnded) {
      return;
    }
    var request = _draftRequest;
    if (request == null || request.text != draft.trim()) {
      if (_outbox.length >= 50) {
        sendError =
            'Too many unconfirmed messages. Retry existing messages first.';
        _changed();
        return;
      }
      request = transport.createMessage(draft);
      _draftRequest = request;
    }
    final id = '${request.senderId}:${request.id}';
    final entry = _outbox.putIfAbsent(
      id,
      () => SessionMessage(request!, DeliveryState.pending),
    );
    await _attempt(id, entry);
  }

  Future<void> retryMessage(String id) async {
    final entry = _outbox[id];
    if (entry == null ||
        sending ||
        status != ChatStatus.ready ||
        sessionEnded) {
      return;
    }
    await _attempt(id, entry);
  }

  Future<void> _attempt(String id, SessionMessage entry) async {
    final generation = _generation;
    entry.delivery = DeliveryState.pending;
    entry.failure = null;
    sendError = null;
    _recoveredDraftMessageId = null;
    final archive = history == null ? null : _archiveId;
    if (archive != null) {
      history?.record(
        archive,
        _archiveTitle,
        _isPrivateGroup,
        SavedChatMessage(
          message: ChatMessage(
            id: id,
            groupId: entry.message.groupId,
            senderId: entry.message.senderId,
            senderName: entry.message.senderName,
            senderContactId: entry.message.senderContactId,
            text: entry.message.text,
            sentAt: entry.message.sentAt,
          ),
          mine: true,
          confirmed: false,
        ),
      );
    }
    _changed();
    try {
      await transport.send(entry.message);
      if (_disposed || generation != _generation) return;
      entry.delivery = DeliveryState.confirmed;
      if (archive != null) history?.confirm(archive, id, 1);
    } catch (e) {
      if (_disposed || generation != _generation || !_outbox.containsKey(id)) {
        return;
      }
      entry.delivery = DeliveryState.failed;
      entry.failure = e is StateError
          ? e.message.toString()
          : 'Host confirmation not received. Retry this message after reconnecting.';
      sendError = entry.failure;
    }
    _changed();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _incoming.cancel();
    history?.removeListener(_historyChanged);
    transport.removeListener(_changed);
    transport.dispose();
    super.dispose();
  }
}
