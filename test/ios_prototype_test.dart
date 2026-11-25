import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_connectivity/offline_connectivity.dart';
import 'package:offline_group_messenger/core/contacts/contact_repository.dart';
import 'package:offline_group_messenger/core/messaging/chat_session_controller.dart';
import 'package:offline_group_messenger/features/contacts/contacts_screen.dart';
import 'package:offline_group_messenger/features/home/home_screen.dart';
import 'chat_session_controller_test.dart' show ControlledTransport;
import 'connection_flow_test.dart' show FakeConnection;
import 'contacts_test.dart' show ContactsFake;

class IPhoneConnection extends FakeConnection {
  final reading = Completer<GroupInvitation>();
  final invitations = <GroupInvitation>[];
  int nfcStops = 0;
  @override
  Future<ConnectionCapabilities> getCapabilities() async =>
      const ConnectionCapabilities(
        platform: 'ios',
        wifiDirectSupported: false,
        implementationReady: true,
        canJoinNfc: true,
        description: 'Join Android by NFC.',
      );
  @override
  Future<GroupInvitation> readNfcInvitation() => reading.future;
  @override
  Future<void> stopNfc() async {
    nfcStops++;
  }

  @override
  Future<void> joinInvitation(GroupInvitation invitation) async {
    invitations.add(invitation);
  }
}

class IPhoneSharingHost extends FakeConnection {
  int iphoneShares = 0;
  int originalShares = 0;
  @override
  Future<ConnectionCapabilities> getCapabilities() async =>
      const ConnectionCapabilities(
        platform: 'android',
        wifiDirectSupported: true,
        implementationReady: true,
        canShareNfc: true,
        description: 'Android host',
      );
  @override
  Future<void> startIosNfcSharing() async {
    iphoneShares++;
  }

  @override
  Future<void> startNfcSharing() async {
    originalShares++;
  }

  @override
  Future<void> stopNfc() async {}
}

GroupInvitation iphoneInvitation() => GroupInvitation.fromMap({
  'app': 'offline-group-messenger',
  'version': 3,
  'transport': 'wifi-direct',
  'networkName': 'DIRECT-ab-Test',
  'passphrase': 'test-password-123',
  'privateGroup': true,
  'hostAddress': '192.168.49.1',
});

void main() {
  testWidgets('Android host uses the separate iPhone NFC invitation action', (
    tester,
  ) async {
    final connection = IPhoneSharingHost();
    final chat = ChatSessionController(transport: ControlledTransport());
    addTearDown(() {
      chat.dispose();
      connection.updates.close();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(
          connectivity: connection,
          chat: chat,
          contacts: ContactsFake(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    connection.updates.add(
      const GroupConnectionState(
        status: GroupStatus.connected,
        wifiEnabled: true,
        permissionGranted: true,
        isHost: true,
        privateGroup: true,
        hostAddress: '192.168.49.1',
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Invite iPhone by NFC'));
    await tester.pumpAndSettle();
    expect(connection.iphoneShares, 1);
    expect(connection.originalShares, 0);
    expect(find.text('Sharing enabled for up to 60 seconds.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'iPhone offers NFC join and reader contacts without Android-only actions',
    (tester) async {
      final connection = IPhoneConnection();
      addTearDown(connection.updates.close);
      await tester.pumpWidget(
        MaterialApp(
          home: HomeScreen(connectivity: connection, contacts: ContactsFake()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Join group by NFC'), findsOneWidget);
      expect(find.text('Create a group'), findsNothing);
      expect(find.text('Find nearby groups'), findsNothing);
      expect(find.text('Calls'), findsNothing);
      expect(
        tester
            .widget<TextButton>(
              find.ancestor(
                of: find.text('Join group by NFC'),
                matching: find.byWidgetPredicate(
                  (widget) => widget is TextButton,
                ),
              ),
            )
            .onPressed,
        isNotNull,
      );
      await tester.tap(find.text('Contacts'));
      await tester.pumpAndSettle();
      expect(find.text('Add contact'), findsOneWidget);
      expect(find.text('Share contact'), findsNothing);
    },
  );

  testWidgets(
    'iPhone NFC sheet may make Flutter inactive; user still confirms before joining',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final connection = IPhoneConnection();
      final contacts = ContactsFake()
        ..list = [
          const SavedContact(
            id: 'host',
            name: 'Host',
            trust: ContactTrust.verified,
          ),
        ];
      final chat = ChatSessionController(transport: ControlledTransport());
      addTearDown(() {
        chat.dispose();
        connection.updates.close();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: HomeScreen(
            connectivity: connection,
            contacts: contacts,
            chat: chat,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Join group by NFC'));
      await tester.pumpAndSettle();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(connection.nfcStops, 0);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      connection.reading.complete(iphoneInvitation());
      await tester.pumpAndSettle();
      expect(find.text('Join this group?'), findsOneWidget);
      expect(connection.invitations, isEmpty);
      await tester.tap(find.text('Join'));
      await tester.pumpAndSettle();
      expect(connection.invitations.single.hostAddress, '192.168.49.1');
      expect(chat.isPrivateGroup, isTrue);
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets(
    'private iPhone invite requires a verified contact before network join',
    (tester) async {
      final connection = IPhoneConnection();
      addTearDown(connection.updates.close);
      await tester.pumpWidget(
        MaterialApp(
          home: HomeScreen(connectivity: connection, contacts: ContactsFake()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Join group by NFC'));
      await tester.pumpAndSettle();
      connection.reading.complete(iphoneInvitation());
      await tester.pumpAndSettle();
      expect(connection.invitations, isEmpty);
      expect(
        find.text('Add the Android host in Contacts by NFC first.'),
        findsOneWidget,
      );
    },
  );

  testWidgets('iPhone contact confirmation explains the second NFC tap', (
    tester,
  ) async {
    final contacts = ContactsFake();
    await tester.pumpWidget(
      MaterialApp(
        home: ContactPairingScreen(
          repository: contacts,
          username: 'Alice',
          reader: true,
          twoTapPairing: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Separate the phones'), findsOneWidget);
    await tester.tap(find.textContaining('Codes match'));
    await tester.pumpAndSettle();
    expect(contacts.approvals, 1);
    expect(find.text('Tap the same Android phone again'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
