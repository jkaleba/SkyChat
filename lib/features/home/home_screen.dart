import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:offline_connectivity/offline_connectivity.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../invitations/scan_invitation_screen.dart';
import '../invitations/nfc_invitation_screen.dart';
import '../../core/messaging/tcp_message_transport.dart';
import '../../core/messaging/chat_session_controller.dart';
import '../chat/chat_screen.dart';
import '../chat/private_membership_panel.dart';
import '../contacts/contacts_screen.dart';
import '../calling/call_screen.dart';
import '../../core/background/background_service.dart';
import '../../core/calling/call_controller.dart';
import '../../core/contacts/contact_repository.dart';
import '../../core/models/chat_message.dart';
import '../../core/history/chat_history_repository.dart';
import '../history/saved_chats_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.connectivity,
    this.chat,
    this.background = const BackgroundService(),
    this.contacts = const ContactRepository(),
    this.historyStorage,
    this.initialUsername,
  });
  final OfflineConnectivity connectivity;
  final ChatSessionController? chat;
  final BackgroundService background;
  final ContactRepository contacts;
  final ChatHistoryStorage? historyStorage;
  final String? initialUsername;
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  late final CallController _calls;
  String? _displayedCall;
  bool _callScreenOpen = false;
  ConnectionCapabilities? _capabilities;
  GroupConnectionState _connection = const GroupConnectionState();
  StreamSubscription<GroupConnectionState>? _subscription;
  bool _loading = true;
  bool _running = false;
  bool _cancelling = false;
  String? _error;
  bool _capabilityError = false;
  GroupInvitation? _invitation;
  int _groupEpoch = 0;
  bool _privateMode = false;
  bool _modeSelected = false;
  bool _disconnectingRevoked = false;
  bool _inForeground = true;
  bool _chatScreenOpen = false;
  bool _backgroundRunning = false;
  bool _notificationPermissionRequested = false;
  Set<String> _verifiedContactIds = {};
  Map<String, String> _contactNames = {};
  bool _contactsLoaded = false;
  StreamSubscription<ChatMessage>? _incomingMessages;
  int _selectedIndex = 0;
  final ValueNotifier<int> _uiRevision = ValueNotifier<int>(0);
  late final ChatSessionController _chat;
  late final ChatHistoryRepository? _history;
  String _username = 'Guest';

  bool get _iosPrototype =>
      _capabilities?.platform == 'ios' &&
      (_capabilities?.implementationReady ?? false);

  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    _uiRevision.value++;
  }

  @override
  void initState() {
    super.initState();
    _history =
        widget.chat?.history ??
        (widget.chat == null && widget.historyStorage != null
            ? ChatHistoryRepository(widget.historyStorage!)
            : null);
    _chat =
        widget.chat ??
        ChatSessionController(
          history: _history,
          transport: TcpMessageTransport(
            contacts: widget.contacts,
            callCapable: defaultTargetPlatform != TargetPlatform.iOS,
          ),
        );
    _calls = CallController(_chat.transport)..addListener(_callChanged);
    WidgetsBinding.instance.addObserver(this);
    _chat.addListener(_membershipChanged);
    _incomingMessages = _chat.transport.incoming.listen(_onIncomingMessage);
    if (widget.initialUsername != null) {
      _applyUsername(widget.initialUsername!);
    } else {
      unawaited(_loadUsername());
    }
    unawaited(_loadVerifiedContacts());
    _load();
  }

  Future<void> _loadUsername() async {
    final username = await widget.contacts.loadUsername();
    if (mounted) _applyUsername(username);
  }

  Future<void> _loadVerifiedContacts() async {
    try {
      final snapshot = await widget.contacts.load();
      if (!mounted) return;
      final verified = snapshot.contacts.where(
        (c) => c.trust == ContactTrust.verified,
      );
      setState(() {
        _verifiedContactIds = verified.map((c) => c.id).toSet();
        _contactNames = {for (final c in verified) c.id: c.name};
        _contactsLoaded = true;
      });
    } on MissingPluginException {
      // Ignored in tests without contacts channel.
    } on PlatformException {
      // Best-effort.
    }
  }

  String _senderLabelForMessage(ChatMessage message) {
    if (message.senderId.isEmpty) return 'Group';
    if (message.senderId == _chat.selfId) return 'You';
    return resolveSenderLabel(
      senderName: message.senderName,
      senderContactId: message.senderContactId,
      contactNames: _contactNames,
      contactsLoaded: _contactsLoaded,
    );
  }

  void _onIncomingMessage(ChatMessage message) {
    if (!mounted || message.groupId != _chat.transport.groupId) return;
    if (message.senderId.isEmpty || message.senderId == _chat.selfId) return;
    if (!_inForeground || !_chatScreenOpen) {
      unawaited(
        widget.background.showMessageNotification(
          sender: _senderLabelForMessage(message),
          text: message.text,
        ),
      );
    }
  }

  void _syncBackgroundService(GroupConnectionState state) {
    if (_iosPrototype) return;
    if (state.status == GroupStatus.connected) {
      if (!_notificationPermissionRequested) {
        _notificationPermissionRequested = true;
        unawaited(widget.background.requestNotificationPermission());
      }
      if (!_backgroundRunning) {
        _backgroundRunning = true;
        unawaited(
          widget.background.start(
            title: 'SkyChat',
            body: state.privateGroup
                ? 'Connected to private group'
                : 'Connected to public group',
          ),
        );
      }
    } else if (state.status == GroupStatus.idle && _backgroundRunning) {
      _backgroundRunning = false;
      unawaited(widget.background.stop());
    }
  }

  void _callChanged() {
    final call = _calls.callId;
    if (!mounted || call == null || call == _displayedCall) return;
    setState(() => _displayedCall = call);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _calls.callId == call) _openCall();
    });
  }

  Future<void> _openCall() async {
    if (_callScreenOpen) return;
    _callScreenOpen = true;
    try {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => CallScreen(calls: _calls)),
      );
    } finally {
      _callScreenOpen = false;
    }
  }

  Future<void> _openContacts() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ContactsScreen(
          repository: widget.contacts,
          calls: _iosPrototype ? null : _calls,
          nfcReaderOnly: _iosPrototype,
          onUsernameChanged: _applyUsername,
        ),
      ),
    );
    if (mounted) {
      _applyUsername(await widget.contacts.loadUsername());
      await _calls.refreshContacts();
      unawaited(_loadVerifiedContacts());
    }
  }

  void _applyUsername(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    _username = trimmed;
    _chat.transport.displayName = trimmed;
  }

  Future<void> _openChat() async {
    if (_chatScreenOpen) return;
    _chatScreenOpen = true;
    try {
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => ChatScreen(
            chat: _chat,
            contacts: widget.contacts,
            openContacts: _capabilities?.platform == 'android' || _iosPrototype
                ? _openContacts
                : null,
            openCall: _iosPrototype ? null : _openCall,
            removePrivateMember: _removePrivateMember,
          ),
        ),
      );
    } finally {
      _chatScreenOpen = false;
      if (mounted) unawaited(_loadVerifiedContacts());
    }
  }

  Future<void> _openCreateGroup() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => ListenableBuilder(
          listenable: Listenable.merge([_uiRevision, _chat]),
          builder: (context, _) => Scaffold(
            appBar: AppBar(
              title: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.asset(
                      'assets/images/logo.png',
                      width: 28,
                      height: 28,
                      fit: BoxFit.cover,
                    ),
                  ),
                  const SizedBox(width: 10),
                  const Flexible(
                    child: Text(
                      'Create a group',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            body: SafeArea(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: _buildCreateGroupContent(context),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && _history != null) {
      unawaited(_history.flush());
    }
    if (state == AppLifecycleState.resumed) {
      _inForeground = true;
      if (!_iosPrototype) _calls.foreground(true);
    }
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      _inForeground = false;
    }
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _calls.foreground(false);
    }
  }

  void _membershipChanged() {
    if (mounted &&
        _chat.transport.membershipRevoked &&
        !_connection.isHost &&
        _connection.status == GroupStatus.connected &&
        !_disconnectingRevoked) {
      _disconnectingRevoked = true;
      unawaited(
        widget.connectivity
            .disconnect()
            .catchError((Object _) {
              if (mounted) {
                setState(
                  () => _error =
                      'Access removed. Disconnect from the Wi-Fi group to continue.',
                );
              }
            })
            .whenComplete(() => _disconnectingRevoked = false),
      );
    }
  }

  Future<void> _findNearby() async {
    await _run(widget.connectivity.discoverPeers);
  }

  Future<void> _removePrivateMember(String id) => _chat.removePrivateMember(
    id,
    rotateInvitation: (previous, next) => widget.connectivity
        .rotatePrivateAdmission(previous: previous, next: next),
  );

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _capabilityError = false;
    });
    try {
      final capabilities = await widget.connectivity.getCapabilities();
      if (!mounted) return;
      await _subscription?.cancel();
      if (!mounted) return;
      _capabilities = capabilities;
      if (_iosPrototype) _calls.foreground(false);
      if (!_modeSelected) _privateMode = false;
      if (capabilities.implementationReady &&
          (capabilities.wifiDirectSupported || _iosPrototype)) {
        _subscription = widget.connectivity.states.listen(
          (state) {
            if (mounted) {
              setState(() {
                _connection = state;
                if (state.status != GroupStatus.connected ||
                    !state.isHost ||
                    state.privateGroup) {
                  _invitation = null;
                  _groupEpoch++;
                }
                _error = state.errorMessage;
              });
              _chat.updateConnection(state, displayName: _username);
              _syncBackgroundService(state);
            }
          },
          onError: (Object error) {
            if (mounted) {
              setState(() {
                _error = 'Connection updates failed. Retry the support check.';
              });
            }
          },
        );
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _capabilityError = true;
          _error = 'Could not check device support.';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  Future<void> _run(
    Future<void> Function() action, {
    bool allowDuringRequest = false,
  }) async {
    if ((_running && !allowDuringRequest) || !mounted) return;
    setState(() {
      _running = true;
      _error = null;
    });
    try {
      await action();
    } on PlatformException catch (error) {
      if (mounted && error.code != 'cancelled') {
        setState(() {
          _error = error.message ?? 'Connection request failed.';
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = 'Connection request failed. Please retry.';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _running = false;
        });
      }
    }
  }

  Future<void> _disconnect() async {
    if (_cancelling) return;
    if (_connection.isHost && _connection.status == GroupStatus.connected) {
      final leave = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('End this group?'),
          content: const Text(
            'Everyone will lose their connection to this host.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Stay'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('End group'),
            ),
          ],
        ),
      );
      if (leave != true || !mounted) return;
    }
    setState(() {
      _cancelling = true;
      _error = null;
    });
    try {
      await _run(() async {
        try {
          await widget.connectivity.disconnect();
        } finally {
          await _chat.leave();
          if (_backgroundRunning) {
            _backgroundRunning = false;
            unawaited(widget.background.stop());
          }
        }
      }, allowDuringRequest: true);
    } finally {
      if (mounted) {
        setState(() {
          _cancelling = false;
        });
      }
    }
  }

  Future<void> _showInvitation() => _run(() async {
    if (_connection.privateGroup) return;
    final epoch = _groupEpoch;
    final invitation = await widget.connectivity.getInvitation();
    if (mounted &&
        epoch == _groupEpoch &&
        _connection.status == GroupStatus.connected &&
        _connection.isHost &&
        !_connection.privateGroup &&
        !invitation.privateGroup) {
      setState(() {
        _invitation = invitation;
      });
    }
  });

  Future<void> _scanInvitation() async {
    final invitation = await Navigator.of(context).push<GroupInvitation>(
      MaterialPageRoute(builder: (_) => const ScanInvitationScreen()),
    );
    await _confirmInvitation(invitation);
  }

  Future<void> _nfcInvitation({required bool sharing}) async {
    final invitation = await Navigator.of(context).push<GroupInvitation>(
      MaterialPageRoute(
        builder: (_) => NfcInvitationScreen(
          connectivity: widget.connectivity,
          sharing: sharing,
          privateGroup: sharing && _connection.privateGroup,
          forIphone: sharing,
        ),
      ),
    );
    if (!sharing) await _confirmInvitation(invitation);
  }

  Future<void> _confirmInvitation(GroupInvitation? invitation) async {
    if (invitation == null || !mounted) return;
    if (_iosPrototype &&
        invitation.privateGroup &&
        _verifiedContactIds.isEmpty) {
      setState(() => _error = 'Add the Android host in Contacts by NFC first.');
      return;
    }
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Join this group?'),
        content: Text(
          'Connect to ${invitation.privateGroup ? 'this private NFC group' : invitation.networkName}? Keep the host nearby with its group open.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Join'),
          ),
        ],
      ),
    );
    if (confirm == true && mounted) {
      _chat.prepareJoin(invitation: invitation);
      await _run(() => widget.connectivity.joinInvitation(invitation));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _incomingMessages?.cancel();
    if (_backgroundRunning) {
      _backgroundRunning = false;
      unawaited(widget.background.stop());
    }
    _calls.removeListener(_callChanged);
    _calls.dispose();
    _subscription?.cancel();
    _chat.removeListener(_membershipChanged);
    if (widget.chat == null) _chat.dispose();
    if (widget.chat == null) _history?.dispose();
    _uiRevision.dispose();
    super.dispose();
  }

  bool get _ready =>
      !_loading &&
      !_capabilityError &&
      (_capabilities?.implementationReady ?? false) &&
      ((_capabilities?.wifiDirectSupported ?? false) ||
          (_iosPrototype && (_capabilities?.canJoinNfc ?? false)));

  bool get _occupied => {
    GroupStatus.connecting,
    GroupStatus.connected,
    GroupStatus.disconnecting,
  }.contains(_connection.status);

  bool get _canStart => _ready && !_running && !_occupied;

  bool get _canCancel =>
      !_cancelling &&
      (!_running ||
          _connection.status == GroupStatus.discovering ||
          _connection.status == GroupStatus.connecting);

  Widget _buildPeerCard(NearbyPeer peer, bool canStart) {
    final isPrivate = peer.privateGroup;
    // Private advertisements carry only an ephemeral group label. The actual
    // host is checked against NFC contacts inside the authenticated TLS channel.
    final isKnownContact = !isPrivate || _verifiedContactIds.isNotEmpty;
    final allowJoin = canStart && isKnownContact;
    Future<void> join() => _run(() async {
      _chat.prepareNearbyJoin(peer);
      await widget.connectivity.joinGroup(peer.id);
    });
    final contactName = !isPrivate && peer.hostContactId != null
        ? _contactNames[peer.hostContactId!]
        : null;
    final peerTitle = (contactName != null && contactName.isNotEmpty)
        ? contactName
        : (peer.name.isEmpty ? 'Nearby device' : peer.name);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: CircleAvatar(
          child: Icon(isPrivate ? Icons.lock_outline : Icons.public),
        ),
        title: Text(peerTitle),
        subtitle: Text(
          isPrivate
              ? (isKnownContact
                    ? 'Private group · Verified contacts only'
                    : 'Verify a contact by NFC before joining')
              : (peer.isGroupOwner ? 'Public group host' : 'Public group'),
        ),
        trailing: TextButton(
          onPressed: allowJoin ? join : null,
          child: const Text('Join'),
        ),
        onTap: allowJoin ? join : null,
      ),
    );
  }

  String get _statusText => switch (_connection.status) {
    GroupStatus.idle => 'Not connected',
    GroupStatus.discovering => 'Searching for nearby groups',
    GroupStatus.connecting => 'Connecting — accept any system invitation',
    GroupStatus.connected =>
      _connection.isHost
          ? 'Connected · You are the host'
          : 'Connected · Participant',
    GroupStatus.disconnecting => 'Disconnecting',
    GroupStatus.unavailable => 'Wi-Fi Direct unavailable',
  };

  Future<void> _openJoinGroup() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => ListenableBuilder(
          listenable: Listenable.merge([_uiRevision, _chat]),
          builder: (context, _) => Scaffold(
            appBar: AppBar(title: const Text('Join a group')),
            body: SafeArea(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: _buildJoinGroupContent(context),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildConnectionDetails() {
    final address = SelectableText(
      key: const PageStorageKey('host-address'),
      'Host IP: ${_connection.hostAddress}',
    );
    if (_capabilities?.platform != 'android') return address;
    return ExpansionTile(
      key: const PageStorageKey('connection-details'),
      tilePadding: EdgeInsets.zero,
      title: const Text('Connection details'),
      children: [
        Align(alignment: Alignment.centerLeft, child: address),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _buildGroupsTab(BuildContext context) {
    if (_capabilities?.platform != 'android') {
      return _buildLegacyGroupsTab(context);
    }
    return ListenableBuilder(
      listenable: _chat,
      builder: (context, _) => ListView(
        key: const PageStorageKey('groups-home'),
        padding: const EdgeInsets.all(16),
        children: [
          _buildCurrentConversation(context),
          if (!_ready ||
              _error != null ||
              _connection.status != GroupStatus.idle)
            _buildConnectionCard(context),
          if (!_occupied) ...[
            Text(
              'Chat with nearby people',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            _buildEntryCard(
              title: 'Create a group',
              subtitle: 'Start a conversation and invite others.',
              icon: Icons.add,
              onTap: _canStart ? _openCreateGroup : null,
            ),
            _buildEntryCard(
              title: 'Join a group',
              subtitle: 'Find a host nearby or use an invitation.',
              icon: Icons.group_add_outlined,
              onTap: _canStart ? _openJoinGroup : null,
            ),
          ] else if (_connection.status == GroupStatus.connected)
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: Text(
                'Disconnect before creating or joining another group.',
              ),
            ),
          if (_history != null) ...[
            const SizedBox(height: 12),
            _buildSavedConversations(context),
          ],
        ],
      ),
    );
  }

  Widget _buildEntryCard({
    required String title,
    required String subtitle,
    required IconData icon,
    required VoidCallback? onTap,
  }) => Card(
    margin: const EdgeInsets.only(bottom: 12),
    child: ListTile(
      enabled: onTap != null,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    ),
  );

  Widget _buildJoinGroupContent(BuildContext context) => ListView(
    key: const PageStorageKey('join-group'),
    padding: const EdgeInsets.all(16),
    children: [
      if (_occupied) _buildCurrentConversation(context),
      if (!_ready || _error != null || _connection.status != GroupStatus.idle)
        _buildConnectionCard(context),
      if (!_occupied) ...[
        const Text(
          'Keep Wi-Fi on. Ask someone nearby to create a group and keep it open.',
        ),
        const SizedBox(height: 12),
        _buildEntryCard(
          title: 'Find nearby groups',
          subtitle: 'Search for groups hosted on another Android phone.',
          icon: Icons.search,
          onTap: _canStart ? _findNearby : null,
        ),
        if (_capabilities?.canJoinQr ?? false)
          _buildEntryCard(
            title: 'Scan group QR code',
            subtitle: 'Ask the host of a public group to show its QR code.',
            icon: Icons.qr_code_scanner,
            onTap: _canStart ? _scanInvitation : null,
          ),
        if (_capabilities?.canJoinNfc ?? false)
          _buildEntryCard(
            title: 'Join group by NFC',
            subtitle: 'Read a group invitation from a nearby phone.',
            icon: Icons.nfc,
            onTap: _canStart ? () => _nfcInvitation(sharing: false) : null,
          ),
        const Text(
          'Private groups require a contact verified by NFC. You can add contacts in the Contacts tab.',
        ),
        const SizedBox(height: 16),
        Text(
          'Available groups',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        _buildNearbyResults(context),
      ],
      if (_running)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: LinearProgressIndicator(),
        ),
    ],
  );

  Widget _buildSavedConversations(BuildContext context) {
    final history = _history!;
    return ListenableBuilder(
      listenable: history,
      builder: (context, _) => Card(
        margin: const EdgeInsets.only(bottom: 12),
        child: ListTile(
          leading: const Icon(Icons.history),
          title: const Text('Saved conversations'),
          subtitle: Text(
            history.loading
                ? 'Loading saved conversations…'
                : history.error != null
                ? 'History needs attention. Tap to retry or manage saved data.'
                : '${history.conversations.length} saved on this phone',
          ),
          trailing: Icon(
            history.error == null ? Icons.chevron_right : Icons.error_outline,
          ),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) =>
                  SavedChatsScreen(history: history, contacts: widget.contacts),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildConnectionCard(BuildContext context) {
    final ready = _ready;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              ready ? _statusText : 'Device support',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            if (_loading)
              const Text('Checking device support...')
            else if (_capabilities != null && !ready)
              Text(_capabilities!.description),
            if (ready && _connection.status == GroupStatus.connected) ...[
              Text(
                _connection.privateGroup
                    ? 'Private group · Known contacts only'
                    : 'Public group',
              ),
              if (_connection.hostAddress != null) _buildConnectionDetails(),
            ],
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              TextButton(
                onPressed: _running ? null : _load,
                child: const Text('Try again'),
              ),
            ],
            if (ready &&
                _connection.status == GroupStatus.connected &&
                _connection.isHost) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (_capabilities?.canShareNfc ?? false)
                    OutlinedButton.icon(
                      onPressed: _running
                          ? null
                          : () => _nfcInvitation(sharing: true),
                      icon: const Icon(Icons.nfc),
                      label: const Text('Invite iPhone by NFC'),
                    ),
                  if (!_connection.privateGroup)
                    OutlinedButton.icon(
                      onPressed: _running ? null : _showInvitation,
                      icon: const Icon(Icons.qr_code),
                      label: const Text('Show group QR code'),
                    ),
                ],
              ),
              if (_invitation != null && !_connection.privateGroup) ...[
                const SizedBox(height: 12),
                Center(
                  child: Semantics(
                    label: 'Group invitation QR code',
                    child: ExcludeSemantics(
                      child: QrImageView(
                        data: _invitation!.encode(),
                        size: 240,
                        padding: const EdgeInsets.all(16),
                        backgroundColor: Colors.white,
                        eyeStyle: const QrEyeStyle(
                          eyeShape: QrEyeShape.square,
                          color: Colors.black,
                        ),
                        dataModuleStyle: const QrDataModuleStyle(
                          dataModuleShape: QrDataModuleShape.square,
                          color: Colors.black,
                        ),
                      ),
                    ),
                  ),
                ),
                const Text(
                  'Only show this code to people joining your group. It contains the Wi-Fi password.',
                ),
                TextButton(
                  onPressed: () => setState(() {
                    _invitation = null;
                  }),
                  child: const Text('Hide QR code'),
                ),
              ],
            ],
            if (ready && _connection.status != GroupStatus.idle)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: _canCancel ? _disconnect : null,
                  child: Text(
                    _connection.status == GroupStatus.connected
                        ? 'Disconnect'
                        : 'Cancel / stop discovery',
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildCurrentConversation(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_connection.status == GroupStatus.connected ||
            _chat.hasConversation) ...[
          Text(
            _connection.status == GroupStatus.connected
                ? 'Current connection'
                : 'Last connection',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          ListenableBuilder(
            listenable: _chat,
            builder: (context, _) {
              final isConnected = _connection.status == GroupStatus.connected;
              final isPrivate = isConnected
                  ? _connection.privateGroup
                  : _chat.isPrivateGroup;
              final messages = _chat.messages;
              final lastText = messages.isNotEmpty
                  ? '${_senderLabelForMessage(messages.last.message)}: ${messages.last.message.text}'
                  : (isPrivate
                        ? 'Private group · Tap to open chat'
                        : 'Public group · Tap to open chat');
              return Card(
                margin: const EdgeInsets.only(bottom: 12),
                child: ListTile(
                  leading: CircleAvatar(
                    child: Icon(isPrivate ? Icons.lock : Icons.groups),
                  ),
                  title: Text(
                    isConnected
                        ? (isPrivate
                              ? 'Current private group'
                              : 'Current public group')
                        : (isPrivate
                              ? 'Last private group'
                              : 'Last public group'),
                  ),
                  subtitle: Text(
                    lastText,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: const Icon(Icons.chat_bubble_outline),
                  onTap: _openChat,
                ),
              );
            },
          ),
          if (_capabilities?.platform == 'android') ...[
            FilledButton.icon(
              onPressed: _openChat,
              icon: const Icon(Icons.chat_bubble_outline),
              label: const Text('Open chat'),
            ),
            const SizedBox(height: 12),
          ],
        ],
      ],
    );
  }

  Widget _buildNearbyResults(BuildContext context) {
    final ready = _ready;
    final occupied = _occupied;
    final canStart = _canStart;
    return ListenableBuilder(
      listenable: _chat,
      builder: (context, _) {
        final remembered = (!occupied && ready)
            ? _chat.rememberedPrivateGroup
            : null;
        final peers = (!occupied && ready)
            ? _connection.peers
            : const <NearbyPeer>[];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (remembered != null)
              Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  leading: const CircleAvatar(child: Icon(Icons.lock_outline)),
                  title: const Text('Your private group'),
                  subtitle: const Text(
                    'Remembered from NFC. Availability is checked when rejoining.',
                  ),
                  trailing: TextButton(
                    onPressed: canStart
                        ? () => _run(() async {
                            _chat.prepareJoin(invitation: remembered);
                            await widget.connectivity.joinInvitation(
                              remembered,
                            );
                          })
                        : null,
                    child: const Text('Rejoin'),
                  ),
                  onTap: canStart
                      ? () => _run(() async {
                          _chat.prepareJoin(invitation: remembered);
                          await widget.connectivity.joinInvitation(remembered);
                        })
                      : null,
                ),
              ),
            for (final peer in peers) _buildPeerCard(peer, canStart),
            if (_connection.status == GroupStatus.connected)
              Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: const ListTile(
                  leading: CircleAvatar(child: Icon(Icons.wifi_off)),
                  title: Text('Cannot discover groups while connected'),
                  subtitle: Text(
                    'While connected to a server, you cannot discover new groups. Disconnect first to search.',
                  ),
                ),
              )
            else if (remembered == null && peers.isEmpty)
              Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  leading: CircleAvatar(child: Icon(Icons.wifi_tethering)),
                  title: Text(
                    _connection.status == GroupStatus.discovering
                        ? 'Looking for groups nearby…'
                        : 'No groups listed yet',
                  ),
                  subtitle: Text(
                    _iosPrototype
                        ? 'Use Join group by NFC with an Android host. Nearby Wi-Fi Direct discovery is available on Android.'
                        : 'Keep the host nearby with its group open. Search for it or ask for an invitation.',
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _buildLegacyGroupsTab(BuildContext context) {
    final ready = _ready;
    final canStart = _canStart;
    return ListView(
      key: const PageStorageKey('groups-legacy'),
      padding: const EdgeInsets.all(16),
      children: [
        if (_history != null) _buildSavedConversations(context),
        if (_iosPrototype)
          const Card(
            margin: EdgeInsets.only(bottom: 12),
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Add the Android host in Contacts by NFC. Then ask the host to create a group and choose Invite iPhone by NFC. Keep SkyChat open while chatting.',
              ),
            ),
          ),
        if (!_iosPrototype)
          Card(
            margin: const EdgeInsets.only(bottom: 12),
            child: ListTile(
              leading: CircleAvatar(
                backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                foregroundColor: Theme.of(
                  context,
                ).colorScheme.onPrimaryContainer,
                child: const Icon(Icons.add),
              ),
              title: const Text('Create a group'),
              subtitle: const Text('Start a private or public group'),
              trailing: const Icon(Icons.chevron_right),
              onTap: _openCreateGroup,
            ),
          ),
        if (!_ready || _error != null || _connection.status != GroupStatus.idle)
          _buildConnectionCard(context),
        _buildCurrentConversation(context),
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          runSpacing: 4,
          children: [
            Text(
              'Available groups',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (!_iosPrototype)
              TextButton.icon(
                onPressed: canStart ? _findNearby : null,
                icon: const Icon(Icons.search),
                label: const Text('Find nearby groups'),
              ),
            if (ready && (_capabilities?.canJoinQr ?? false))
              TextButton.icon(
                onPressed: canStart ? _scanInvitation : null,
                icon: const Icon(Icons.qr_code_scanner),
                label: const Text('Scan group QR code'),
              ),
            if (_iosPrototype && (_capabilities?.canJoinNfc ?? false))
              TextButton.icon(
                onPressed: canStart
                    ? () => _nfcInvitation(sharing: false)
                    : null,
                icon: const Icon(Icons.nfc),
                label: const Text('Join group by NFC'),
              ),
          ],
        ),
        const SizedBox(height: 8),
        if (_running)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: LinearProgressIndicator(),
          ),
        _buildNearbyResults(context),
      ],
    );
  }

  Widget _buildCreateGroupContent(BuildContext context) {
    final ready = _ready;
    final occupied = _occupied;
    final canStart = _canStart;
    return ListView(
      key: const PageStorageKey('create-group'),
      padding: const EdgeInsets.all(24),
      children: [
        if (!occupied) ...[
          Text(
            'Who can join?',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 12),
          const Text(
            'Create a private group for known contacts, or make a public group discoverable nearby.',
          ),
          const SizedBox(height: 16),
        ],
        _buildCurrentConversation(context),
        if (!ready ||
            occupied ||
            _error != null ||
            _connection.status == GroupStatus.discovering)
          _buildConnectionCard(context),
        if (ready && !occupied) ...[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final private in [false, true])
                ChoiceChip(
                  avatar: Icon(private ? Icons.lock_outline : Icons.public),
                  label: Text(private ? 'Private' : 'Public'),
                  selected: _privateMode == private,
                  onSelected: _running
                      ? null
                      : (_) => setState(() {
                          _privateMode = private;
                          _modeSelected = true;
                        }),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            _privateMode
                ? 'Nearby users see an anonymous group label. Verified contacts join automatically after connecting.'
                : 'Listed for nearby app users. Join through discovery, QR or NFC. Chat is not yet encrypted.',
          ),
          const SizedBox(height: 8),
          const Text(
            'Keep Wi-Fi on. Android may ask for Nearby devices or Location access when you create the group.',
          ),
          const SizedBox(height: 12),
        ],
        if (_connection.status != GroupStatus.connected)
          FilledButton(
            onPressed: canStart
                ? () => _run(() async {
                    final token = _chat.configureGroup(
                      privateGroup: _privateMode,
                    );
                    await widget.connectivity.createGroup(
                      privateGroup: _privateMode,
                      admissionToken: token,
                    );
                  })
                : null,
            child: const Text('Create a group'),
          ),
        if (_running)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: LinearProgressIndicator(),
          ),
        const SizedBox(height: 20),
        const Text(
          'Offline text chat is available after connecting. '
          'Public groups are visible to everyone nearby; private groups allow only known contacts.',
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _connection.status != GroupStatus.connected,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _connection.status == GroupStatus.connected) {
          unawaited(widget.background.moveToBackground());
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.asset(
                  'assets/images/logo.png',
                  width: 28,
                  height: 28,
                  fit: BoxFit.cover,
                ),
              ),
              const SizedBox(width: 10),
              const Flexible(
                child: Text('SkyChat', overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
        ),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Column(
                children: [
                  PrivateMembershipPanel(transport: _chat.transport),
                  Expanded(
                    child: switch (_selectedIndex) {
                      0 => _buildGroupsTab(context),
                      1 => ContactsScreen(
                        repository: widget.contacts,
                        calls: _iosPrototype ? null : _calls,
                        nfcReaderOnly: _iosPrototype,
                        embedded: true,
                        onUsernameChanged: _applyUsername,
                      ),
                      _ => CallScreen(calls: _calls, embedded: true),
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _selectedIndex,
          onDestinationSelected: (index) {
            setState(() => _selectedIndex = index);
            if (index == 0) unawaited(_loadVerifiedContacts());
            if (index == 1) unawaited(_calls.refreshContacts());
          },
          destinations: [
            const NavigationDestination(
              icon: Icon(Icons.groups_outlined),
              selectedIcon: Icon(Icons.groups),
              label: 'Groups',
            ),
            const NavigationDestination(
              icon: Icon(Icons.contacts_outlined),
              selectedIcon: Icon(Icons.contacts),
              label: 'Contacts',
            ),
            if (!_iosPrototype)
              const NavigationDestination(
                icon: Icon(Icons.call_outlined),
                selectedIcon: Icon(Icons.call),
                label: 'Calls',
              ),
          ],
        ),
      ),
    );
  }
}
