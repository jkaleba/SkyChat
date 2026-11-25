import 'dart:async';
import 'package:flutter/material.dart';
import '../../core/contacts/contact_repository.dart';
import '../../core/calling/call_controller.dart';

class ContactsScreen extends StatefulWidget {
  const ContactsScreen({
    super.key,
    this.repository = const ContactRepository(),
    this.calls,
    this.embedded = false,
    this.onUsernameChanged,
    this.nfcReaderOnly = false,
  });
  final ContactRepository repository;
  final CallController? calls;
  final bool embedded;
  final ValueChanged<String>? onUsernameChanged;
  final bool nfcReaderOnly;
  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> {
  ContactSnapshot? snapshot;
  String _username = 'Guest';
  String? error;
  bool busy = false;
  @override
  void initState() {
    super.initState();
    widget.calls?.addListener(_callsChanged);
    unawaited(load());
  }

  void _callsChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.calls?.removeListener(_callsChanged);
    super.dispose();
  }

  Future<void> load() async {
    try {
      final result = await widget.repository.load();
      final username = await widget.repository.loadUsername();
      await widget.calls?.refreshContacts();
      if (mounted) {
        setState(() {
          snapshot = result;
          _username = username;
          error = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => error =
              'Cannot access contacts on this device. Retry, or reset contacts if their keys were lost.',
        );
      }
    }
  }

  Future<void> _editUsername() async {
    final field = TextEditingController(text: _username);
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Your username'),
        content: TextField(controller: field, maxLength: 32, autofocus: true),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              final trimmed = field.text.trim();
              if (trimmed.isNotEmpty) Navigator.pop(context, trimmed);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    Future<void>.delayed(const Duration(seconds: 1), field.dispose);
    if (value != null && mounted) {
      await widget.repository.saveUsername(value);
      widget.onUsernameChanged?.call(value);
      if (mounted) setState(() => _username = value);
    }
  }

  Future<void> _openPairing({required bool reader}) async {
    final previousIds = {
      for (final c in snapshot?.contacts ?? const <SavedContact>[]) c.id,
    };
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ContactPairingScreen(
          repository: widget.repository,
          username: _username,
          reader: reader,
          twoTapPairing: widget.nfcReaderOnly,
        ),
      ),
    );
    if (!mounted) return;
    await load();
    if (mounted) await _promptRenameIfDuplicate(previousIds);
  }

  Future<void> _promptRenameIfDuplicate(Set<String> previousIds) async {
    final contacts = snapshot?.contacts ?? const <SavedContact>[];
    final counts = <String, int>{};
    for (final c in contacts) {
      final key = c.name.trim().toLowerCase();
      counts[key] = (counts[key] ?? 0) + 1;
    }
    SavedContact? duplicate;
    for (final c in contacts) {
      final key = c.name.trim().toLowerCase();
      if ((counts[key] ?? 0) > 1 && !previousIds.contains(c.id)) {
        duplicate = c;
        break;
      }
    }
    if (duplicate == null) {
      for (final c in contacts.reversed) {
        final key = c.name.trim().toLowerCase();
        if ((counts[key] ?? 0) > 1) {
          duplicate = c;
          break;
        }
      }
    }
    if (duplicate == null || !mounted) return;
    final target = duplicate;
    final field = TextEditingController(text: target.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Duplicate contact name'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'A contact named "${target.name}" already exists. Please rename this contact.',
            ),
            const SizedBox(height: 12),
            TextField(controller: field, maxLength: 32, autofocus: true),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              final trimmed = field.text.trim();
              if (trimmed.isNotEmpty) Navigator.pop(context, trimmed);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    Future<void>.delayed(const Duration(seconds: 1), field.dispose);
    if (newName != null && newName != target.name && mounted) {
      await run(() => widget.repository.rename(target.id, newName));
    }
  }

  Future<void> run(Future<void> Function() action) async {
    setState(() => busy = true);
    try {
      await action();
      await load();
    } catch (_) {
      if (mounted) {
        setState(() => error = 'Could not update contacts. Please retry.');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<bool> confirm(String title, String message) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Confirm'),
            ),
          ],
        ),
      ) ??
      false;
  Future<void> change(SavedContact contact, String action) async {
    if (action == 'rename') {
      final field = TextEditingController(text: contact.name);
      final value = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Contact name'),
          content: TextField(controller: field, maxLength: 32, autofocus: true),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                if (field.text.trim().isNotEmpty) {
                  Navigator.pop(context, field.text.trim());
                }
              },
              child: const Text('Save'),
            ),
          ],
        ),
      );
      // Dialog route may still be animating; let its TextField detach first.
      Future<void>.delayed(const Duration(seconds: 1), field.dispose);
      if (value != null && mounted) {
        await run(() => widget.repository.rename(contact.id, value));
      }
    } else {
      final block = action == 'block';
      if (await confirm(
            block ? 'Block ${contact.name}?' : 'Delete ${contact.name}?',
            block
                ? 'This contact will not be able to request calls or pair again. Chat group membership stays unchanged.'
                : 'Remove saved trust. You will need to pair by NFC again. Deleting a blocked contact also removes its block.',
          ) &&
          mounted) {
        await run(
          () => block
              ? widget.repository.block(contact.id)
              : widget.repository.delete(contact.id),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final actions = [
      IconButton(
        onPressed: busy ? null : load,
        tooltip: 'Refresh contacts',
        icon: const Icon(Icons.refresh),
      ),
      IconButton(
        tooltip: 'Reset contact identity',
        icon: const Icon(Icons.delete_forever),
        onPressed: busy
            ? null
            : () async {
                if (await confirm(
                      'Reset all contacts?',
                      'Deletes your contact identity and all saved contacts. Everyone must pair with you by NFC again.',
                    ) &&
                    mounted) {
                  await run(widget.repository.reset);
                }
              },
      ),
    ];
    final body = ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (widget.embedded)
          Row(
            children: [
              Expanded(
                child: Text(
                  'Contacts',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ),
              ...actions,
            ],
          ),
        if (error != null)
          Text(
            error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        Card(
          margin: const EdgeInsets.only(bottom: 12),
          child: ListTile(
            leading: const Icon(Icons.badge_outlined),
            title: const Text('Your username'),
            subtitle: Text(_username),
            trailing: IconButton(
              tooltip: 'Change username',
              icon: const Icon(Icons.edit),
              onPressed: busy ? null : _editUsername,
            ),
            onTap: busy ? null : _editUsername,
          ),
        ),
        Row(
          children: [
            if (!widget.nfcReaderOnly)
              Expanded(
                child: FilledButton.icon(
                  onPressed: busy || snapshot == null
                      ? null
                      : () => _openPairing(reader: false),
                  icon: const Icon(Icons.nfc),
                  label: const Text('Share contact'),
                ),
              ),
            if (!widget.nfcReaderOnly) const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: busy || snapshot == null
                    ? null
                    : () => _openPairing(reader: true),
                icon: const Icon(Icons.person_add),
                label: const Text('Add contact'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (widget.nfcReaderOnly)
          const Text(
            'On Android choose Share contact. On iPhone choose Add contact, compare the codes on both phones, confirm, then tap again to finish.',
          ),
        if (snapshot?.contacts.isEmpty == true)
          const Text(
            'No contacts yet. Add someone by touching your phones together.',
          ),
        for (final contact in snapshot?.contacts ?? <SavedContact>[])
          ListTile(
            leading: Icon(
              contact.trust == ContactTrust.blocked
                  ? Icons.block
                  : Icons.person,
            ),
            title: Text(contact.name),
            subtitle: Text(switch (contact.trust) {
              ContactTrust.pending =>
                'Pairing incomplete — repeat NFC on both phones',
              ContactTrust.verified =>
                widget.calls?.availability(contact.id) ?? 'Verified by NFC',
              ContactTrust.blocked =>
                'Blocked — delete to allow a new NFC pairing',
            }),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (contact.trust == ContactTrust.verified &&
                    widget.calls != null)
                  IconButton(
                    tooltip: 'Call',
                    icon: const Icon(Icons.call),
                    onPressed:
                        busy ||
                            widget.calls!.hasCall ||
                            widget.calls!.peerFor(contact.id) == null
                        ? null
                        : () => widget.calls!.dial(contact.id),
                  ),
                PopupMenuButton<String>(
                  enabled: !busy,
                  onSelected: (value) => change(contact, value),
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: 'rename', child: Text('Rename')),
                    if (contact.trust != ContactTrust.blocked)
                      const PopupMenuItem(value: 'block', child: Text('Block')),
                    const PopupMenuItem(value: 'delete', child: Text('Delete')),
                  ],
                ),
              ],
            ),
          ),
      ],
    );
    if (widget.embedded) return body;
    return Scaffold(
      appBar: AppBar(title: const Text('Contacts'), actions: actions),
      body: body,
    );
  }
}

class ContactPairingScreen extends StatefulWidget {
  const ContactPairingScreen({
    super.key,
    required this.repository,
    required this.username,
    required this.reader,
    this.twoTapPairing = false,
  });
  final ContactRepository repository;
  final String username;
  final bool reader;
  final bool twoTapPairing;
  @override
  State<ContactPairingScreen> createState() => _ContactPairingScreenState();
}

class _ContactPairingScreenState extends State<ContactPairingScreen>
    with WidgetsBindingObserver {
  Timer? timer;
  Map<String, dynamic>? pairing;
  bool busy = false;
  bool polling = false;
  bool started = false;
  String? error;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    timer = Timer.periodic(const Duration(milliseconds: 500), (_) => poll());
    unawaited(_start());
  }

  Future<void> _start() => run(
    () =>
        widget.repository.startPairing(widget.username, reader: widget.reader),
  );

  Future<void> poll() async {
    if (polling || busy || !started) return;
    polling = true;
    try {
      final status = await widget.repository.pairingStatus();
      if (mounted) setState(() => pairing = status);
    } catch (_) {
      /* Actions show failures; polling must not create error loops. */
    } finally {
      polling = false;
    }
  }

  Future<void> run(Future<void> Function() action) async {
    setState(() {
      busy = true;
      error = null;
      started = true;
    });
    try {
      await action();
    } catch (_) {
      if (mounted) {
        setState(
          () => error =
              widget.twoTapPairing
                  ? 'Pairing failed. Keep both phones unlocked, open Share contact on Android, and start again.'
                  : 'Pairing failed. Enable NFC, keep both phones unlocked, and start again.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
    await poll();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(widget.repository.stopPairing().catchError((Object _) {}));
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    unawaited(widget.repository.stopPairing().catchError((Object _) {}));
    super.dispose();
  }

  ({
    IconData icon,
    String title,
    String description,
    String touchStatus,
    bool isError,
    bool isComplete,
  })
  _statusSummary(String? state, bool approved, String? pairingError) {
    final hasError = error != null || pairingError != null;
    if (state == 'verified') {
      return (
        icon: Icons.check_circle_outline,
        title: 'Contact verified and saved',
        description:
            'Both phones finished exchanging confirmations. You can stop touching and separate the phones now.',
        touchStatus: 'You can stop touching the phones',
        isError: false,
        isComplete: true,
      );
    }
    if (hasError || state == 'stopped') {
      return (
        icon: Icons.error_outline,
        title: hasError ? 'Pairing failed' : 'Pairing stopped',
        description:
            error ??
            pairingError ??
            'NFC pairing was cancelled or timed out. Separate the phones and tap retry to start again.',
        touchStatus: 'You can stop touching the phones',
        isError: hasError,
        isComplete: false,
      );
    }
    if (state == 'confirm' && approved) {
      return (
        icon: Icons.hourglass_top,
        title: 'Step 3 of 3 · Waiting for the other phone',
        description: widget.twoTapPairing
            ? 'Confirm the same code on Android, then hold the top of this iPhone near it again to exchange confirmations.'
            : 'You confirmed on this phone. Keep both phones touching until the other person confirms so the receipt can be exchanged over NFC.',
        touchStatus: widget.twoTapPairing
            ? 'Tap the same Android phone again'
            : 'Keep phones touching',
        isError: false,
        isComplete: false,
      );
    }
    if (state == 'confirm') {
      final peerName = pairing?['name'] ?? 'the other phone';
      return (
        icon: Icons.verified_user_outlined,
        title: 'Step 2 of 3 · Compare verification code',
        description: widget.twoTapPairing
            ? 'Connected with $peerName. Separate the phones, compare the full code on both screens, and confirm on both. Then tap again to save the contact.'
            : 'Connected with $peerName. Keep both phones touching while you compare the code below and tap confirm.',
        touchStatus: widget.twoTapPairing
            ? 'Compare codes before the second tap'
            : 'Keep phones touching',
        isError: false,
        isComplete: false,
      );
    }
    if (state == 'waiting') {
      return (
        icon: Icons.nfc,
        title: 'Step 1 of 3 · Waiting for NFC tap',
        description: widget.twoTapPairing
            ? 'On Android open Share contact. Hold the top of this iPhone near the Android NFC antenna. Finish both taps within 60 seconds.'
            : widget.reader
            ? 'Hold the backs of both phones together to receive their contact. Pairing expires after 60 seconds.'
            : 'Hold the backs of both phones together to share your contact (${widget.username}). Pairing expires after 60 seconds.',
        touchStatus: 'Hold phones together',
        isError: false,
        isComplete: false,
      );
    }
    return (
      icon: Icons.nfc,
      title: 'Starting NFC pairing…',
      description: 'Preparing NFC session. Keep both phones unlocked.',
      touchStatus: 'Get ready to hold phones together',
      isError: false,
      isComplete: false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = pairing?['state'] as String?;
    final approved = pairing?['approved'] == true;
    final pairingError = pairing?['error'] as String?;
    final active = state == 'waiting' || state == 'confirm';
    final summary = _statusSummary(state, approved, pairingError);
    final scheme = Theme.of(context).colorScheme;
    final cardColor = summary.isComplete
        ? scheme.primaryContainer
        : summary.isError
        ? scheme.errorContainer
        : scheme.surfaceContainerHighest;
    final onCardColor = summary.isComplete
        ? scheme.onPrimaryContainer
        : summary.isError
        ? scheme.onErrorContainer
        : scheme.onSurface;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.reader ? 'Add contact' : 'Share contact'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Card(
            color: cardColor,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(summary.icon, color: onCardColor),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          summary.title,
                          style: Theme.of(
                            context,
                          ).textTheme.titleMedium?.copyWith(color: onCardColor),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    summary.description,
                    style: Theme.of(
                      context,
                    ).textTheme.bodyMedium?.copyWith(color: onCardColor),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Icon(
                        summary.isComplete || !active
                            ? Icons.pan_tool_alt_outlined
                            : Icons.touch_app_outlined,
                        size: 18,
                        color: onCardColor,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          summary.touchStatus,
                          style: Theme.of(
                            context,
                          ).textTheme.labelLarge?.copyWith(color: onCardColor),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (!active && state != 'verified')
            FilledButton.icon(
              onPressed: busy ? null : _start,
              icon: const Icon(Icons.nfc),
              label: Text(
                widget.reader ? 'Retry add contact' : 'Retry share contact',
              ),
            ),
          if (state == 'confirm') ...[
            Text(
              'Contact: ${pairing!['name']}',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            const Text(
              'Compare this code on both phones. Confirm only if the full code matches.',
            ),
            const SizedBox(height: 8),
            SelectableText(
              pairing!['code'] as String,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: busy || approved
                  ? null
                  : () => run(widget.repository.approvePairing),
              child: Text(
                approved
                    ? 'Waiting for the other confirmation'
                    : 'Codes match — confirm contact',
              ),
            ),
          ],
          if (active)
            TextButton(
              onPressed: busy ? null : () => run(widget.repository.stopPairing),
              child: const Text('Cancel pairing'),
            ),
        ],
      ),
    );
  }
}
