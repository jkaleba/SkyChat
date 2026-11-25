import 'dart:convert';

import '../models/chat_message.dart';

class SavedChatMessage {
  const SavedChatMessage({
    required this.message,
    required this.mine,
    required this.confirmed,
    this.checks,
  });

  final ChatMessage message;
  final bool mine;
  final bool confirmed;
  final int? checks;

  SavedChatMessage confirmedWith(int? value) => SavedChatMessage(
    message: message,
    mine: mine,
    confirmed: true,
    checks: value == null || (checks ?? 0) > value ? checks : value,
  );

  Map<String, dynamic> toJson() => {
    'id': message.id,
    'groupId': message.groupId,
    'senderId': message.senderId,
    'senderName': message.senderName,
    'senderContactId': message.senderContactId,
    'text': message.text,
    'sentAt': message.sentAt.toUtc().millisecondsSinceEpoch,
    'sequence': message.sequence,
    'mine': mine,
    'confirmed': confirmed,
    'checks': checks,
  };

  factory SavedChatMessage.fromJson(Map<String, dynamic> json) {
    final contact = json['senderContactId'];
    final checks = json['checks'];
    if (json['mine'] is! bool ||
        json['confirmed'] is! bool ||
        (checks != null && (checks is! int || checks < 1 || checks > 3))) {
      throw const FormatException('Invalid saved message state.');
    }
    return SavedChatMessage(
      message: ChatMessage(
        id: historyString(json['id'], 128),
        groupId: historyString(json['groupId'], 80),
        senderId: historyString(json['senderId'], 64),
        senderName: historyString(json['senderName'], 32),
        senderContactId: contact == null ? null : historyString(contact, 128),
        text: historyString(json['text'], 2000),
        sentAt: historyDate(json['sentAt']),
        sequence: historyInt(json['sequence']),
      ),
      mine: json['mine'] as bool,
      confirmed: json['confirmed'] as bool,
      checks: checks as int?,
    );
  }

  // A conservative bound for JSON escaping, before allocating encoded payloads.
  int get estimatedBytes =>
      256 +
      6 *
          (message.id.length +
              message.groupId.length +
              message.senderId.length +
              message.senderName.length +
              (message.senderContactId?.length ?? 0) +
              message.text.length);
}

class SavedConversation {
  SavedConversation({
    required this.id,
    String? groupId,
    required this.title,
    required this.privateGroup,
    required this.updatedAt,
    this.draft = '',
    Iterable<SavedChatMessage> messages = const [],
  }) : groupId = groupId ?? id,
       messages = List.unmodifiable(messages);

  final String id;
  final String groupId;
  final String title;
  final bool privateGroup;
  final DateTime updatedAt;
  final String draft;
  final List<SavedChatMessage> messages;

  SavedConversation copyWith({
    String? title,
    bool? privateGroup,
    DateTime? updatedAt,
    String? draft,
    Iterable<SavedChatMessage>? messages,
  }) => SavedConversation(
    id: id,
    groupId: groupId,
    title: title ?? this.title,
    privateGroup: privateGroup ?? this.privateGroup,
    updatedAt: updatedAt ?? this.updatedAt,
    draft: draft ?? this.draft,
    messages: messages ?? this.messages,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'groupId': groupId,
    'title': title,
    'privateGroup': privateGroup,
    'updatedAt': updatedAt.toUtc().millisecondsSinceEpoch,
    'draft': draft,
    'messages': messages.map((message) => message.toJson()).toList(),
  };

  factory SavedConversation.fromJson(Map<String, dynamic> json) {
    final id = historyString(json['id'], 80);
    final group = historyString(json['groupId'] ?? id, 80);
    final raw = json['messages'];
    if (id.isEmpty ||
        json['privateGroup'] is! bool ||
        raw is! List ||
        raw.length > 550) {
      throw const FormatException('Invalid saved conversation.');
    }
    final messages = raw
        .map((value) => SavedChatMessage.fromJson(historyMap(value)))
        .toList();
    final ids = <String>{};
    for (final entry in messages) {
      if (entry.message.groupId != group || !ids.add(entry.message.id)) {
        throw const FormatException('Invalid saved message identity.');
      }
    }
    return SavedConversation(
      id: id,
      groupId: group,
      title: historyString(json['title'], 160),
      privateGroup: json['privateGroup'] as bool,
      updatedAt: historyDate(json['updatedAt']),
      draft: historyString(json['draft'], 2000),
      messages: messages,
    );
  }

  late final int estimatedBytes =
      256 +
      6 * (id.length + groupId.length + title.length + draft.length) +
      messages.fold<int>(0, (total, entry) => total + entry.estimatedBytes);
}

Map<String, dynamic> historyMap(Object? value) {
  if (value is! Map<String, dynamic>) {
    throw const FormatException('Invalid saved history.');
  }
  return value;
}

String historyString(Object? value, int maximum) {
  if (value is! String || value.length > maximum) {
    throw const FormatException('Invalid saved text.');
  }
  return value;
}

int historyInt(Object? value) {
  if (value is! int || value < 0 || value > 8640000000000000) {
    throw const FormatException('Invalid saved number.');
  }
  return value;
}

DateTime historyDate(Object? value) =>
    DateTime.fromMillisecondsSinceEpoch(historyInt(value), isUtc: true);

Map<String, SavedConversation> decodeSavedConversations(String raw) {
  if (utf8.encode(raw).length > 8 * 1024 * 1024) {
    throw const FormatException('Saved history is too large.');
  }
  final json = historyMap(jsonDecode(raw));
  final entries = json['conversations'];
  if (json['version'] != 1 || entries is! List || entries.length > 30) {
    throw const FormatException('Unsupported saved history.');
  }
  final result = <String, SavedConversation>{};
  for (final entry in entries) {
    final conversation = SavedConversation.fromJson(historyMap(entry));
    if (result.containsKey(conversation.id)) {
      throw const FormatException('Duplicate saved conversation.');
    }
    result[conversation.id] = conversation;
  }
  return result;
}
