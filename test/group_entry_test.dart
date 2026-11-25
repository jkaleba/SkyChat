import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_connectivity/offline_connectivity.dart';
import 'package:offline_group_messenger/core/messaging/chat_session_controller.dart';
import 'package:offline_group_messenger/features/chat/chat_screen.dart';
import 'package:offline_group_messenger/features/home/home_screen.dart';

import 'chat_session_controller_test.dart' show ControlledTransport;
import 'nfc_invitation_test.dart' show NfcConnection;
import 'qr_invitation_test.dart' show invitation;

class EntryConnection extends NfcConnection {
  bool qrSupported = true;
  bool nfcSupported = true;
  bool ready = true;
  int searches = 0;
  int reads = 0;
  int joins = 0;
  Completer<void>? pendingJoin;

  @override
  Future<ConnectionCapabilities> getCapabilities() async =>
      ConnectionCapabilities(
        platform: 'android',
        wifiDirectSupported: true,
        implementationReady: ready,
        canJoinQr: qrSupported,
        canJoinNfc: nfcSupported,
        description: 'Android connection support',
      );

  @override
  Future<void> discoverPeers() async {
    searches++;
    updates.add(const GroupConnectionState(status: GroupStatus.discovering));
  }

  @override
  Future<void> joinGroup(String peerId) async {
    joined = peerId;
    joins++;
    await pendingJoin?.future;
  }

  @override
  Future<GroupInvitation> readNfcInvitation() {
    reads++;
    return super.readNfcInvitation();
  }
}

Future<void> reveal(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    120,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
}

Future<void> openJoin(WidgetTester tester) async {
  await reveal(tester, find.text('Join a group'));
  await tester.tap(find.text('Join a group'));
  await tester.pumpAndSettle();
}

Future<void> showHome(
  WidgetTester tester,
  EntryConnection connection, {
  double textScale = 1,
}) async {
  final chat = ChatSessionController(transport: ControlledTransport());
  addTearDown(connection.updates.close);
  addTearDown(chat.dispose);
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: HomeScreen(
        connectivity: connection,
        chat: chat,
        initialUsername: 'Alice',
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('idle home offers create and join without starting discovery', (
    tester,
  ) async {
    final connection = EntryConnection();
    await showHome(tester, connection);
    expect(find.text('Create a group'), findsOneWidget);
    expect(find.text('Join a group'), findsOneWidget);
    expect(find.text('Find nearby groups'), findsNothing);
    expect(find.text('Scan group QR code'), findsNothing);
    expect(find.text('No groups listed yet'), findsNothing);
    expect(connection.searches, 0);
    expect(connection.reads, 0);
    expect(connection.creates, 0);

    await openJoin(tester);
    expect(find.text('Find nearby groups'), findsOneWidget);
    expect(find.text('Scan group QR code'), findsOneWidget);
    expect(find.text('Join group by NFC'), findsOneWidget);
    expect(connection.searches, 0);
    expect(connection.reads, 0);
  });

  testWidgets('join only offers methods supported by this phone', (
    tester,
  ) async {
    final connection = EntryConnection()
      ..qrSupported = false
      ..nfcSupported = false;
    await showHome(tester, connection);
    await openJoin(tester);
    expect(find.text('Find nearby groups'), findsOneWidget);
    expect(find.text('Scan group QR code'), findsNothing);
    expect(find.text('Join group by NFC'), findsNothing);
    await tester.tap(find.text('Find nearby groups'));
    await tester.pumpAndSettle();
    expect(connection.searches, 1);
    expect(find.text('Looking for groups nearby…'), findsOneWidget);
    await tester.tap(find.text('Cancel / stop discovery'));
    await tester.pumpAndSettle();
    expect(connection.disconnects, 1);
    expect(find.text('No groups listed yet'), findsOneWidget);
  });

  testWidgets('unsupported Android cannot open a connection action', (
    tester,
  ) async {
    final connection = EntryConnection()..ready = false;
    await showHome(tester, connection);
    for (final title in ['Create a group', 'Join a group']) {
      final tile = tester.widget<ListTile>(
        find.widgetWithText(ListTile, title),
      );
      expect(tile.enabled, isFalse);
      expect(tile.onTap, isNull);
    }
    expect(connection.creates, 0);
    expect(connection.searches, 0);
  });

  testWidgets('connecting hides new actions on both the join page and home', (
    tester,
  ) async {
    final connection = EntryConnection();
    await showHome(tester, connection);
    await openJoin(tester);
    connection.updates.add(
      const GroupConnectionState(status: GroupStatus.connecting),
    );
    await tester.pumpAndSettle();
    expect(find.text('Find nearby groups'), findsNothing);
    expect(find.text('Scan group QR code'), findsNothing);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Join a group'), findsNothing);
    expect(find.text('Create a group'), findsNothing);
    await tester.tap(find.text('Cancel / stop discovery'));
    await tester.pumpAndSettle();
    expect(find.text('Create a group'), findsOneWidget);
    expect(find.text('Join a group'), findsOneWidget);
  });

  testWidgets('two quick join taps send one request for the selected peer', (
    tester,
  ) async {
    final connection = EntryConnection()..pendingJoin = Completer<void>();
    await showHome(tester, connection);
    await openJoin(tester);
    connection.updates.add(
      const GroupConnectionState(
        status: GroupStatus.discovering,
        peers: [
          NearbyPeer(id: 'host-42', name: 'Nearby host', isGroupOwner: true),
        ],
      ),
    );
    await tester.pumpAndSettle();
    await reveal(tester, find.text('Join'));
    await tester.tap(find.text('Join'));
    await tester.tap(find.text('Join'));
    await tester.pump();
    expect(connection.joins, 1);
    expect(connection.joined, 'host-42');
    connection.pendingJoin!.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('a pending native join can still be cancelled', (tester) async {
    final connection = EntryConnection()..pendingJoin = Completer<void>();
    await showHome(tester, connection);
    await openJoin(tester);
    connection.updates.add(
      const GroupConnectionState(
        status: GroupStatus.discovering,
        peers: [
          NearbyPeer(id: 'host-42', name: 'Nearby host', isGroupOwner: true),
        ],
      ),
    );
    await tester.pumpAndSettle();
    await reveal(tester, find.text('Join'));
    await tester.tap(find.text('Join'));
    connection.updates.add(
      const GroupConnectionState(status: GroupStatus.connecting),
    );
    await tester.pump();
    await tester.tap(find.text('Cancel / stop discovery'));
    // The join future deliberately remains pending while cancellation completes.
    await tester.pump();
    expect(connection.disconnects, 1);
    connection.pendingJoin!.complete();
    await tester.pumpAndSettle();
    expect(find.text('Find nearby groups'), findsOneWidget);
  });

  testWidgets('Android NFC entry waits for confirmation before joining', (
    tester,
  ) async {
    final connection = EntryConnection();
    await showHome(tester, connection);
    await openJoin(tester);
    await reveal(tester, find.text('Join group by NFC'));
    await tester.tap(find.text('Join group by NFC'));
    await tester.pumpAndSettle();
    expect(connection.reads, 1);
    connection.read.complete(invitation);
    await tester.pumpAndSettle();
    expect(find.text('Join this group?'), findsOneWidget);
    expect(connection.qrJoins, 0);
    await tester.tap(find.text('Join'));
    await tester.pumpAndSettle();
    expect(connection.qrJoins, 1);
  });

  testWidgets('connected home prioritizes chat and expands technical details', (
    tester,
  ) async {
    final connection = EntryConnection();
    await showHome(tester, connection);
    connection.updates.add(
      const GroupConnectionState(
        status: GroupStatus.connected,
        hostAddress: '127.0.0.1',
        wifiEnabled: true,
        permissionGranted: true,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Open chat'), findsOneWidget);
    expect(find.text('Create a group'), findsNothing);
    expect(find.text('Join a group'), findsNothing);
    expect(find.text('Host IP: 127.0.0.1'), findsNothing);
    await tester.tap(find.text('Connection details'));
    await tester.pumpAndSettle();
    expect(find.text('Host IP: 127.0.0.1'), findsOneWidget);
    await tester.tap(find.text('Open chat'));
    await tester.pumpAndSettle();
    expect(find.byType(ChatScreen), findsOneWidget);
  });

  testWidgets(
    'small screens and large text can reach create and join controls',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final connection = EntryConnection();
      await showHome(tester, connection, textScale: 2);
      await reveal(tester, find.text('Create a group'));
      await tester.tap(find.text('Create a group'));
      await tester.pumpAndSettle();
      await reveal(tester, find.text('Private'));
      await tester.tap(find.text('Private'));
      await tester.pumpAndSettle();
      final create = find.widgetWithText(FilledButton, 'Create a group');
      await reveal(tester, create);
      expect(tester.widget<FilledButton>(create).onPressed, isNotNull);
      expect(tester.takeException(), isNull);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await openJoin(tester);
      for (final title in [
        'Find nearby groups',
        'Scan group QR code',
        'Join group by NFC',
        'No groups listed yet',
      ]) {
        await reveal(tester, find.text(title));
        expect(tester.takeException(), isNull);
      }
      tester.view.physicalSize = const Size(640, 320);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
