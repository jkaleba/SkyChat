import 'dart:async';

import 'package:offline_group_messenger/core/history/chat_history_repository.dart';

class MemoryHistoryStorage implements ChatHistoryStorage {
  String? data;
  bool failRead = false;
  bool failWrite = false;
  Completer<String?>? readGate;
  Completer<void>? writeGate;
  final writeStarted = Completer<void>();
  final writes = <String>[];
  final operations = <String>[];

  @override
  Future<String?> read() async {
    if (failRead) throw StateError('Storage unavailable');
    return readGate == null ? data : readGate!.future;
  }

  @override
  Future<void> write(String value) async {
    if (!writeStarted.isCompleted) writeStarted.complete();
    await writeGate?.future;
    if (failWrite) throw StateError('Disk full');
    data = value;
    writes.add(value);
    operations.add('write');
  }

  @override
  Future<void> clear() async {
    data = null;
    operations.add('clear');
  }
}
