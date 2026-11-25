import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_connectivity/offline_connectivity.dart';
import 'package:offline_group_messenger/app/app.dart';
import 'support/configured_profile_store.dart';
import 'package:offline_group_messenger/core/messaging/chat_session_controller.dart';
import 'package:offline_group_messenger/core/messaging/tcp_message_transport.dart';
import 'package:offline_group_messenger/features/home/home_screen.dart';
import 'chat_session_controller_test.dart' show ControlledTransport, connected;

class FakeConnection extends OfflineConnectivity {
  final updates = StreamController<GroupConnectionState>.broadcast();
  int creates = 0;
  int disconnects = 0;
  String? joined;
  bool denied = false;
  bool? createdPrivate;
  String? createdToken;
  @override
  Future<ConnectionCapabilities> getCapabilities() async =>
      const ConnectionCapabilities(
        platform: 'android',
        wifiDirectSupported: true,
        implementationReady: true,
        description: 'Android ready',
      );
  @override
  Stream<GroupConnectionState> get states => updates.stream;
  @override
  Future<void> createGroup({
    bool privateGroup = false,
    String? admissionToken,
  }) async {
    creates++;
    createdPrivate = privateGroup;
    createdToken = admissionToken;
    if (denied) {
      throw PlatformException(
        code: 'permission_denied',
        message: 'Permission denied.',
      );
    }
    updates.add(
      const GroupConnectionState(
        status: GroupStatus.connecting,
        wifiEnabled: true,
      ),
    );
  }

  @override
  Future<void> joinGroup(String peerId) async {
    joined = peerId;
  }

  @override
  Future<void> disconnect() async {
    disconnects++;
    updates.add(
      const GroupConnectionState(wifiEnabled: true, permissionGranted: true),
    );
  }
}

void main() {
  testWidgets(
    'joining the same nearby group after leaving preserves the conversation',
    (tester) async {
      final connection = FakeConnection();
      final transport = ControlledTransport();
      final chat = ChatSessionController(transport: transport);
      addTearDown(() {
        chat.dispose();
        connection.updates.close();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: HomeScreen(connectivity: connection, chat: chat),
        ),
      );
      await tester.pumpAndSettle();
      Future<void> chooseHost() async {
        connection.updates.add(
          const GroupConnectionState(
            status: GroupStatus.discovering,
            wifiEnabled: true,
            permissionGranted: true,
            peers: [
              NearbyPeer(id: 'same-host', name: 'Host', isGroupOwner: true),
            ],
          ),
        );
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.text('Join'),
          150,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.ensureVisible(find.text('Join'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Join'));
        await tester.pumpAndSettle();
      }

      await chooseHost();
      connection.updates.add(connected);
      await tester.pumpAndSettle();
      chat.draft = 'Keep this draft after rejoining';
      await tester.scrollUntilVisible(
        find.text('Disconnect'),
        -150,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Disconnect'));
      await tester.pumpAndSettle();
      await chooseHost();
      expect(chat.draft, 'Keep this draft after rejoining');
      expect(transport.groupId, 'original');
      connection.updates.add(connected);
      await tester.pumpAndSettle();
      expect(transport.connects, 2);
    },
  );

  testWidgets(
    'accepted creation waits for connection info and shows actual IP',
    (tester) async {
      final connection = FakeConnection();
      addTearDown(connection.updates.close);
      await tester.pumpWidget(
        MessengerApp(
          connectivity: connection,
          profileStore: const ConfiguredProfileStore(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create a group'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.widgetWithText(FilledButton, 'Create a group'),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(
        find.widgetWithText(FilledButton, 'Create a group'),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Create a group'));
      await tester.pumpAndSettle();
      expect(connection.creates, 1);
      expect(find.textContaining('Connecting —'), findsOneWidget);
      expect(find.textContaining('Host IP:'), findsNothing);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      connection.updates.add(
        const GroupConnectionState(
          status: GroupStatus.connected,
          wifiEnabled: true,
          permissionGranted: true,
          isHost: true,
          hostAddress: '192.168.88.7',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Host IP: 192.168.88.7'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Disconnect'),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Disconnect'));
      await tester.tap(find.text('Disconnect'));
      await tester.pumpAndSettle();
      expect(find.text('End this group?'), findsOneWidget);
      await tester.tap(find.text('End group'));
      await tester.pumpAndSettle();
      expect(connection.disconnects, 1);
      expect(find.textContaining('Host IP:'), findsNothing);
    },
  );

  testWidgets('discovered peer passes its ID to join', (tester) async {
    final connection = FakeConnection();
    addTearDown(connection.updates.close);
    await tester.pumpWidget(
      MessengerApp(
        connectivity: connection,
        profileStore: const ConfiguredProfileStore(),
      ),
    );
    await tester.pumpAndSettle();
    connection.updates.add(
      const GroupConnectionState(
        status: GroupStatus.discovering,
        wifiEnabled: true,
        permissionGranted: true,
        peers: [
          NearbyPeer(id: 'peer-42', name: 'Host phone', isGroupOwner: true),
        ],
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Join'),
      150,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Join'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Join'));
    await tester.pumpAndSettle();
    expect(connection.joined, 'peer-42');
  });

  testWidgets('permission denial leaves controls usable', (tester) async {
    final connection = FakeConnection()..denied = true;
    addTearDown(connection.updates.close);
    await tester.pumpWidget(
      MessengerApp(
        connectivity: connection,
        profileStore: const ConfiguredProfileStore(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create a group'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.widgetWithText(FilledButton, 'Create a group'),
      150,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(
      find.widgetWithText(FilledButton, 'Create a group'),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Create a group'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Permission denied.'),
      -150,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Permission denied.'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byType(FilledButton),
      150,
      scrollable: find.byType(Scrollable).first,
    );
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNotNull,
    );
  });

  testWidgets(
    'shows Current connection and discovery notice when connected, and Last connection with preserved privacy after disconnect',
    (tester) async {
      final connection = FakeConnection();
      final transport = _FakeHostTransport();
      final chat = ChatSessionController(transport: transport);
      addTearDown(() {
        chat.dispose();
        connection.updates.close();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: HomeScreen(connectivity: connection, chat: chat),
        ),
      );
      await tester.pumpAndSettle();

      chat.configureGroup(privateGroup: true);
      connection.updates.add(
        const GroupConnectionState(
          status: GroupStatus.connected,
          wifiEnabled: true,
          permissionGranted: true,
          isHost: true,
          privateGroup: true,
          hostAddress: '127.0.0.1',
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Current connection'), findsOneWidget);
      expect(find.text('Current private group'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Cannot discover groups while connected'),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        find.text('Cannot discover groups while connected'),
        findsOneWidget,
      );

      connection.updates.add(
        const GroupConnectionState(
          status: GroupStatus.idle,
          wifiEnabled: true,
          permissionGranted: true,
        ),
      );
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.text('Last connection'),
        -150,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Last connection'), findsOneWidget);
      expect(find.text('Last private group'), findsOneWidget);
      expect(find.text('Current connection'), findsNothing);
      expect(find.text('Cannot discover groups while connected'), findsNothing);
    },
  );
}

class _FakeHostTransport extends TcpMessageTransport {
  String? _group;
  @override
  String? get groupId => _group;

  @override
  Future<void> startHost({
    int port = TcpMessageTransport.defaultPort,
    String? address,
  }) async {
    _group = 'g-private';
    status = ChatStatus.ready;
    selfId = 'host';
    notifyListeners();
  }

  @override
  Future<void> close() async {
    status = ChatStatus.offline;
    notifyListeners();
  }
}
