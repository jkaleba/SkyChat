import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'saved_conversation.dart';

abstract interface class ChatHistoryStorage {
  Future<String?> read();
  Future<void> write(String data);
  Future<void> clear();
}

class AndroidChatHistoryStorage implements ChatHistoryStorage {
  const AndroidChatHistoryStorage();
  static const channel = MethodChannel('com.offlinegroupmessenger/history');

  @override
  Future<String?> read() => channel.invokeMethod<String>('read');
  @override
  Future<void> write(String data) =>
      channel.invokeMethod('write', {'data': data});
  @override
  Future<void> clear() => channel.invokeMethod('clear');
}

/// Local archives contain no Wi-Fi credentials, admission or resume tokens.
/// Disk operations are serialized, including deletion and in-flight saves.
class ChatHistoryRepository extends ChangeNotifier {
  ChatHistoryRepository(
    this.storage, {
    this.saveDelay = const Duration(milliseconds: 300),
  }) {
    ready = _load();
  }

  static const maxConversations = 30;
  static const maxBytes = 8 * 1024 * 1024;
  static String privateConversationId(String groupId, String hostContactId) =>
      'private:${sha256.convert(utf8.encode('$hostContactId:$groupId'))}';
  final ChatHistoryStorage storage;
  final Duration saveDelay;
  late final Future<void> ready;
  final _records = <String, SavedConversation>{};
  final _beforeLoad = <void Function(Map<String, SavedConversation>)>[];
  Future<void> _io = Future.value();
  Timer? _saveTimer;
  bool _loaded = false;
  bool _dirty = false;
  bool _disposed = false;
  bool _resetFailed = false;
  int _revision = 0;
  int _loadGeneration = 0;
  bool loading = true;
  bool saving = false;
  String? error;

  bool get canSave => _loaded;
  bool get deletionFailed => _resetFailed;
  SavedConversation? find(String id) => _records[id];
  // Keep interaction order even when timestamps tie or the phone clock changes.
  List<SavedConversation> get conversations =>
      List.unmodifiable(_records.values);

  void _putFirst(
    Map<String, SavedConversation> records,
    SavedConversation value,
  ) {
    final previous = Map<String, SavedConversation>.of(records)
      ..remove(value.id);
    records.clear();
    records[value.id] = value;
    records.addAll(previous);
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<T> _serialize<T>(Future<T> Function() action) {
    final next = _io.then((_) => action());
    _io = next.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return next;
  }

  Future<void> _load() {
    final generation = _loadGeneration;
    return _serialize(() async {
      try {
        final raw = await storage.read();
        if (generation != _loadGeneration) return;
        final loaded = raw == null
            ? <String, SavedConversation>{}
            : decodeSavedConversations(raw);
        for (final change in _beforeLoad) {
          change(loaded);
        }
        _records
          ..clear()
          ..addAll(loaded);
        _dirty = _beforeLoad.isNotEmpty;
        _beforeLoad.clear();
        _loaded = true;
        error = null;
        _prune();
        if (_dirty) {
          if (_disposed) {
            unawaited(flush());
          } else {
            _schedule();
          }
        }
      } catch (_) {
        // Keep the original file and queued live changes until retry or explicit reset.
        if (generation == _loadGeneration) {
          error =
              'Saved conversations could not be opened. Retry, or delete saved history to reset it.';
        }
      } finally {
        if (generation == _loadGeneration) {
          loading = false;
          _notify();
        }
      }
    });
  }

  void _change(void Function(Map<String, SavedConversation>) change) {
    if (_disposed) return;
    change(_records);
    if (!_loaded) {
      _beforeLoad.add(change);
      // Bound unsaved recovery work when the user keeps chatting after a read
      // failure. Recent changes take precedence over the oldest buffered work.
      if (_beforeLoad.length > 4096) _beforeLoad.removeAt(0);
    }
    _revision++;
    _dirty = true;
    _prune();
    if (_loaded) _schedule();
    _notify();
  }

  void _schedule() {
    if (_disposed || (_saveTimer?.isActive ?? false)) return;
    _saveTimer = Timer(saveDelay, () {
      unawaited(flush());
    });
  }

  SavedConversation _new(
    String id,
    String title,
    bool privateGroup,
    DateTime now, {
    String? groupId,
  }) => SavedConversation(
    id: id,
    groupId: groupId,
    title: title,
    privateGroup: privateGroup,
    updatedAt: now,
  );

  void setDraft(
    String id,
    String title,
    bool privateGroup,
    String draft, {
    String? groupId,
  }) {
    if (draft.length > 2000) return;
    final now = DateTime.now();
    _change((records) {
      if (draft.isEmpty && !records.containsKey(id)) return;
      final previous =
          records[id] ?? _new(id, title, privateGroup, now, groupId: groupId);
      if (draft.isEmpty && previous.messages.isEmpty) {
        records.remove(id);
        return;
      }
      _putFirst(
        records,
        previous.copyWith(
          title: title,
          privateGroup: privateGroup,
          draft: draft,
          updatedAt: now,
        ),
      );
    });
  }

  void moveDraft(
    String source,
    String destination,
    String title,
    bool privateGroup, {
    String? groupId,
  }) {
    if (source == destination) return;
    final now = DateTime.now();
    _change((records) {
      final previous = records.remove(source);
      if (previous == null || previous.draft.isEmpty) return;
      final next =
          records[destination] ??
          _new(destination, title, privateGroup, now, groupId: groupId);
      _putFirst(records, next.copyWith(draft: previous.draft, updatedAt: now));
    });
  }

  void record(
    String id,
    String title,
    bool privateGroup,
    SavedChatMessage entry,
  ) {
    final now = DateTime.now();
    _change((records) {
      final previous =
          records[id] ??
          _new(id, title, privateGroup, now, groupId: entry.message.groupId);
      final messages = previous.messages.toList();
      final index = messages.indexWhere(
        (value) => value.message.id == entry.message.id,
      );
      if (index < 0) {
        messages.add(entry);
      } else {
        final old = messages[index];
        messages[index] = SavedChatMessage(
          message: old.message.sequence > entry.message.sequence
              ? old.message
              : entry.message,
          mine: old.mine || entry.mine,
          confirmed: old.confirmed || entry.confirmed,
          checks: (old.checks ?? 0) > (entry.checks ?? 0)
              ? old.checks
              : entry.checks,
        );
      }
      // Place accepted outgoing messages in host order, even if another
      // participant's message arrived while the local send was still pending.
      if (entry.confirmed && entry.message.sequence > 0) {
        final accepted = messages.removeAt(
          messages.indexWhere((value) => value.message.id == entry.message.id),
        );
        final next = messages.indexWhere(
          (value) =>
              !value.confirmed ||
              value.message.sequence > accepted.message.sequence,
        );
        if (next < 0) {
          messages.add(accepted);
        } else {
          messages.insert(next, accepted);
        }
      }
      var confirmed = 0;
      var unconfirmed = 0;
      final retained = messages.reversed
          .where(
            (message) =>
                message.confirmed ? ++confirmed <= 500 : ++unconfirmed <= 50,
          )
          .toList()
          .reversed;
      _putFirst(
        records,
        previous.copyWith(
          title: title,
          privateGroup: privateGroup,
          messages: retained,
          updatedAt: now,
        ),
      );
    });
  }

  void confirm(String groupId, String messageId, int checks) {
    final previous = _records[groupId];
    final message = previous?.messages
        .where((entry) => entry.message.id == messageId)
        .firstOrNull;
    if (message == null ||
        (message.confirmed && (message.checks ?? 0) >= checks)) {
      return;
    }
    _change((records) {
      final conversation = records[groupId];
      if (conversation == null) return;
      records[groupId] = conversation.copyWith(
        messages: [
          for (final entry in conversation.messages)
            if (entry.message.id == messageId)
              entry.confirmedWith(checks)
            else
              entry,
        ],
      );
    });
  }

  void _prune() {
    final ordered = conversations;
    var remaining = 64;
    for (var index = 0; index < ordered.length; index++) {
      final conversation = ordered[index];
      if (index >= maxConversations ||
          remaining + conversation.estimatedBytes > maxBytes) {
        _records.remove(conversation.id);
      } else {
        remaining += conversation.estimatedBytes;
      }
    }
  }

  Future<bool> flush() {
    _saveTimer?.cancel();
    _saveTimer = null;
    if (!_loaded) return Future.value(false);
    return _serialize(() async {
      if (!_dirty) return error == null;
      saving = true;
      _notify();
      final revision = _revision;
      try {
        final encoded = jsonEncode({
          'version': 1,
          'conversations': conversations
              .map((value) => value.toJson())
              .toList(),
        });
        if (utf8.encode(encoded).length > maxBytes) {
          throw const FormatException('Saved history is too large.');
        }
        await storage.write(encoded);
        if (_revision == revision) _dirty = false;
        _resetFailed = false;
        error = null;
        return true;
      } catch (_) {
        error =
            'Conversations could not be saved on this phone. Free some storage and retry.';
        return false;
      } finally {
        saving = false;
        _notify();
        if (_dirty && error == null) _schedule();
      }
    });
  }

  Future<bool> delete(String id) {
    _change((records) => records.remove(id));
    return flush();
  }

  Future<bool> clear() {
    _saveTimer?.cancel();
    _loadGeneration++;
    loading = false;
    _records.clear();
    _beforeLoad.clear();
    _revision++;
    _dirty = false;
    _loaded = true;
    _notify();
    return _serialize(() async {
      try {
        await storage.clear();
        _resetFailed = false;
        error = null;
        return true;
      } catch (_) {
        _resetFailed = true;
        error = 'Saved conversations could not be deleted. Retry.';
        return false;
      } finally {
        _notify();
        if (_dirty && error == null) _schedule();
      }
    });
  }

  Future<void> retry() async {
    if (_resetFailed) {
      await clear();
    } else if (!_loaded) {
      loading = true;
      _notify();
      await _load();
    } else {
      await flush();
    }
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    if (_loaded && _dirty) unawaited(flush());
    _disposed = true;
    super.dispose();
  }
}
