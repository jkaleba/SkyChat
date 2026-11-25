import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/contacts/contact_repository.dart';
import '../../core/history/chat_history_repository.dart';
import '../../core/history/saved_conversation.dart';

String _date(DateTime value) {
  final local = value.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
}

Future<bool> _confirmDeletion(
  BuildContext context, {
  required bool all,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          all
              ? 'Delete all saved conversations?'
              : 'Delete this saved conversation?',
        ),
        content: const Text(
          'Deletes saved copies of messages and drafts on this phone. Your current chat, contacts and other phones are not affected. '
          'New messages in an active chat will still be saved.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    ) ??
    false;

class SavedHistoryError extends StatelessWidget {
  const SavedHistoryError({super.key, required this.history});
  final ChatHistoryRepository history;

  @override
  Widget build(BuildContext context) => history.error == null
      ? const SizedBox.shrink()
      : Card(
          color: Theme.of(context).colorScheme.errorContainer,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  history.error!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onErrorContainer,
                  ),
                ),
                TextButton(
                  onPressed: history.loading ? null : history.retry,
                  child: Text(
                    history.deletionFailed
                        ? 'Retry deleting'
                        : history.canSave
                        ? 'Retry saving'
                        : 'Retry loading',
                  ),
                ),
              ],
            ),
          ),
        );
}

class SavedChatsScreen extends StatelessWidget {
  const SavedChatsScreen({
    super.key,
    required this.history,
    this.contacts = const ContactRepository(),
  });
  final ChatHistoryRepository history;
  final ContactRepository contacts;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: history,
    builder: (context, _) {
      final conversations = history.conversations;
      return Scaffold(
        appBar: AppBar(
          title: const Text('Saved conversations'),
          actions: [
            IconButton(
              tooltip: 'Delete all saved conversations',
              onPressed:
                  history.loading ||
                      (conversations.isEmpty && history.error == null)
                  ? null
                  : () async {
                      if (await _confirmDeletion(context, all: true)) {
                        await history.clear();
                      }
                    },
              icon: const Icon(Icons.delete_outline),
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
              'Saved on this phone. Rejoin a group to continue chatting. '
              'Your saved draft is restored when you rejoin the same conversation; nothing is sent automatically.',
            ),
            const SizedBox(height: 12),
            SavedHistoryError(history: history),
            if (history.loading)
              const Center(child: CircularProgressIndicator())
            else if (conversations.isEmpty && history.error == null)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'No saved conversations yet. Your messages and drafts will appear here.',
                ),
              ),
            for (final conversation in conversations)
              Card(
                child: ListTile(
                  leading: Icon(
                    conversation.privateGroup
                        ? Icons.lock_outline
                        : Icons.chat_bubble_outline,
                  ),
                  title: Text(conversation.title),
                  subtitle: Text(
                    '${_date(conversation.updatedAt)}\n${conversation.draft.isNotEmpty ? 'Draft: ${conversation.draft}' : conversation.messages.lastOrNull?.message.text ?? 'No messages yet'}',
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                  isThreeLine: true,
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => SavedConversationScreen(
                        history: history,
                        conversationId: conversation.id,
                        contacts: contacts,
                      ),
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 16),
            const Text(
              'History is encrypted on this device and is not backed up. '
              'Up to 30 conversations, 500 confirmed and 50 unconfirmed messages per conversation are kept. '
              'The oldest history is removed when storage limits are reached.',
            ),
          ],
        ),
      );
    },
  );
}

class SavedConversationScreen extends StatefulWidget {
  const SavedConversationScreen({
    super.key,
    required this.history,
    required this.conversationId,
    this.contacts = const ContactRepository(),
  });
  final ChatHistoryRepository history;
  final String conversationId;
  final ContactRepository contacts;

  @override
  State<SavedConversationScreen> createState() =>
      _SavedConversationScreenState();
}

class _SavedConversationScreenState extends State<SavedConversationScreen> {
  Map<String, String> _contactNames = {};
  bool _contactsLoaded = false;

  @override
  void initState() {
    super.initState();
    _loadContacts();
  }

  Future<void> _loadContacts() async {
    try {
      final snapshot = await widget.contacts.load();
      if (!mounted) return;
      setState(() {
        _contactNames = {
          for (final contact in snapshot.contacts)
            if (contact.trust == ContactTrust.verified)
              contact.id: contact.name,
        };
        _contactsLoaded = true;
      });
    } on MissingPluginException {
      // The archive remains readable if the contacts adapter is unavailable.
    } on PlatformException {
      // Saved text never depends on a successful contacts lookup.
    }
  }

  String _sender(SavedChatMessage entry) {
    if (entry.mine) return 'You';
    if (entry.message.senderId.isEmpty) return 'Group';
    return resolveSenderLabel(
      senderName: entry.message.senderName,
      senderContactId: entry.message.senderContactId,
      contactNames: _contactNames,
      contactsLoaded: _contactsLoaded,
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.history,
    builder: (context, _) {
      final conversation = widget.history.find(widget.conversationId);
      return Scaffold(
        appBar: AppBar(
          title: Text(conversation?.title ?? 'Saved conversation'),
          actions: [
            if (conversation != null)
              IconButton(
                tooltip: 'Delete saved conversation',
                icon: const Icon(Icons.delete_outline),
                onPressed: () async {
                  if (!await _confirmDeletion(context, all: false)) return;
                  if (await widget.history.delete(widget.conversationId) &&
                      context.mounted) {
                    Navigator.pop(context);
                  }
                },
              ),
          ],
        ),
        body: conversation == null
            ? ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  SavedHistoryError(history: widget.history),
                  Text(
                    widget.history.error == null
                        ? 'This saved conversation has been deleted.'
                        : 'The deletion has not been saved yet. Retry above.',
                  ),
                ],
              )
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  const Text(
                    'Saved conversation · Viewing history does not connect to the group.',
                  ),
                  const SizedBox(height: 12),
                  SavedHistoryError(history: widget.history),
                  if (conversation.draft.isNotEmpty)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Saved draft',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            const SizedBox(height: 8),
                            SelectableText(conversation.draft),
                            TextButton.icon(
                              icon: const Icon(Icons.copy),
                              label: const Text('Copy draft'),
                              onPressed: () async {
                                await Clipboard.setData(
                                  ClipboardData(text: conversation.draft),
                                );
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text('Draft copied.'),
                                    ),
                                  );
                                }
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
                  for (final entry in conversation.messages)
                    _message(context, entry),
                ],
              ),
      );
    },
  );

  Widget _message(BuildContext context, SavedChatMessage entry) => Align(
    alignment: entry.mine ? Alignment.centerRight : Alignment.centerLeft,
    child: Card(
      color: entry.mine ? Theme.of(context).colorScheme.primaryContainer : null,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${_sender(entry)} · ${_date(entry.message.sentAt)}',
              style: Theme.of(context).textTheme.labelMedium,
            ),
            const SizedBox(height: 4),
            SelectableText(entry.message.text),
            if (entry.mine && !entry.confirmed)
              const Text(
                'Delivery was not confirmed. This message may have reached the group.',
              ),
            if (entry.mine && entry.confirmed)
              Text(
                '✓' * (entry.checks ?? 1),
                semanticsLabel: switch (entry.checks ?? 1) {
                  3 => 'Received by all intended recipients',
                  2 => 'Received by another participant',
                  _ => 'Received by the host',
                },
              ),
          ],
        ),
      ),
    ),
  );
}
