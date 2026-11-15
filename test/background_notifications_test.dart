import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_connectivity/offline_connectivity.dart';
import 'package:offline_group_messenger/core/background/background_service.dart';
import 'package:offline_group_messenger/core/messaging/chat_session_controller.dart';
import 'package:offline_group_messenger/core/messaging/tcp_message_transport.dart';
import 'package:offline_group_messenger/core/models/chat_message.dart';
import 'package:offline_group_messenger/features/home/home_screen.dart';

class FakeBackgroundService extends BackgroundService {
  int permissionRequests = 0;
  int starts = 0;
  int stops = 0;
  final List<({String sender, String text})> notifications = [];

  @override
  Future<bool> requestNotificationPermission() async {
    permissionRequests++;
    return true;
  }

  @override
  Future<void> start({
    String title = 'SkyChat',
    String body = 'Connected to offline group',
  }) async {
    starts++;
  }

  @override
  Future<void> stop() async {
    stops++;
  }

  @override
  Future<void> showMessageNotification({
    required String sender,
    required String text,
  }) async {
    notifications.add((sender: sender, text: text));
  }
}

class FakeTransport extends TcpMessageTransport {
  final fakeIncoming = StreamController<ChatMessage>.broadcast();

  @override
  Stream<ChatMessage> get incoming => fakeIncoming.stream;

  @override
  String? get groupId => 'group-1';

  @override
  String? get selfId => 'self-1';

  @override
  Future<void> startHost({
    int port = TcpMessageTransport.defaultPort,
    String? address,
  }) async {}

  @override
  Future<void> connect({required String host, required int port}) async {}

  @override
  Future<void> close() async {}

  @override
  void dispose() {
    fakeIncoming.close();
    super.dispose();
  }
}

class FakeConnectivity extends OfflineConnectivity {
  final updates = StreamController<GroupConnectionState>.broadcast();

  @override
  Future<ConnectionCapabilities> getCapabilities() async =>
      const ConnectionCapabilities(
        platform: 'android',
        wifiDirectSupported: true,
        implementationReady: true,
        description: 'Ready',
      );

  @override
  Stream<GroupConnectionState> get states => updates.stream;
}

void main() {
  testWidgets(
    'starts foreground service on connect, stops on disconnect, and notifies on received peer messages',
    (tester) async {
      final connectivity = FakeConnectivity();
      final transport = FakeTransport();
      final chat = ChatSessionController(transport: transport);
      final background = FakeBackgroundService();
      addTearDown(connectivity.updates.close);
      addTearDown(chat.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: HomeScreen(
            connectivity: connectivity,
            chat: chat,
            background: background,
          ),
        ),
      );
      await tester.pumpAndSettle();

      connectivity.updates.add(
        const GroupConnectionState(
          status: GroupStatus.connected,
          isHost: true,
          hostAddress: '192.168.49.1',
          wifiEnabled: true,
          permissionGranted: true,
        ),
      );
      await tester.pumpAndSettle();

      expect(background.permissionRequests, 1);
      expect(background.starts, 1);
      expect(background.stops, 0);

      // System notice and own message should not notify.
      transport.fakeIncoming.add(
        ChatMessage(
          id: 'sys-1',
          groupId: 'group-1',
          senderId: '',
          senderName: 'Group',
          text: 'Joined',
          sentAt: DateTime.now().toUtc(),
        ),
      );
      transport.fakeIncoming.add(
        ChatMessage(
          id: 'self-1:1',
          groupId: 'group-1',
          senderId: 'self-1',
          senderName: 'Guest',
          text: 'My own message',
          sentAt: DateTime.now().toUtc(),
        ),
      );
      await tester.pump();
      expect(background.notifications, isEmpty);

      // Peer message while not on ChatScreen notifies.
      transport.fakeIncoming.add(
        ChatMessage(
          id: 'peer-1:1',
          groupId: 'group-1',
          senderId: 'peer-1',
          senderName: 'Alice',
          text: 'Hello there',
          sentAt: DateTime.now().toUtc(),
        ),
      );
      await tester.pump();
      expect(background.notifications.length, 1);
      expect(background.notifications.single.sender, 'Alice');
      expect(background.notifications.single.text, 'Hello there');

      // Peer message while viewing ChatScreen in foreground does not notify.
      await tester.tap(find.text('Open chat / connection status'));
      await tester.pumpAndSettle();
      transport.fakeIncoming.add(
        ChatMessage(
          id: 'peer-1:2',
          groupId: 'group-1',
          senderId: 'peer-1',
          senderName: 'Alice',
          text: 'In chat now',
          sentAt: DateTime.now().toUtc(),
        ),
      );
      await tester.pump();
      expect(background.notifications.length, 1);

      // Peer message while ChatScreen is open but app is backgrounded notifies.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      transport.fakeIncoming.add(
        ChatMessage(
          id: 'peer-1:3',
          groupId: 'group-1',
          senderId: 'peer-1',
          senderName: 'Alice',
          text: 'While backgrounded',
          sentAt: DateTime.now().toUtc(),
        ),
      );
      await tester.pump();
      expect(background.notifications.length, 2);
      expect(background.notifications.last.text, 'While backgrounded');

      connectivity.updates.add(const GroupConnectionState());
      await tester.pumpAndSettle();
      expect(background.stops, 1);
    },
  );
}
