import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:offline_connectivity/offline_connectivity.dart';
import 'package:offline_group_messenger/app/app.dart';
import 'support/configured_profile_store.dart';
import 'package:offline_group_messenger/features/invitations/scan_invitation_screen.dart';
import 'package:offline_group_messenger/features/invitations/nfc_invitation_screen.dart';
import 'nfc_invitation_test.dart' show NfcConnection;
import 'qr_invitation_test.dart' show FakeCamera;

final privateInvitation = GroupInvitation.fromMap({
  'app': 'offline-group-messenger',
  'version': 2,
  'transport': 'wifi-direct',
  'networkName': 'DIRECT-ab-Private',
  'passphrase': 'secret-password',
  'privateGroup': true,
  'admissionToken': 'a' * 64,
});

void main() {
  testWidgets(
    'private host creates advertised private group without NFC or QR',
    (tester) async {
      final connection = NfcConnection();
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
        find.text('Private'),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Private'));
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
      expect(connection.createdPrivate, isTrue);
      expect(connection.createdToken, isNull);
      connection.updates.add(
        const GroupConnectionState(
          status: GroupStatus.connected,
          isHost: true,
          privateGroup: true,
          hostAddress: '192.168.88.7',
          wifiEnabled: true,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Show group QR code'), findsNothing);
      expect(find.text('Share via NFC'), findsNothing);
      expect(find.text('Private group · Known contacts only'), findsOneWidget);
    },
  );

  testWidgets('public creation has no admission secret', (tester) async {
    final connection = NfcConnection();
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
      find.text('Public'),
      150,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Public'));
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
    expect(connection.createdPrivate, isFalse);
    expect(connection.createdToken, isNull);
  });

  testWidgets('scanner refuses private credentials encoded as QR', (
    tester,
  ) async {
    final previous = MobileScannerPlatform.instance;
    MobileScannerPlatform.instance = FakeCamera();
    addTearDown(() => MobileScannerPlatform.instance = previous);
    await tester.pumpWidget(const MaterialApp(home: ScanInvitationScreen()));
    await tester.pumpAndSettle();
    tester.widget<MobileScanner>(find.byType(MobileScanner)).onDetect!(
      BarcodeCapture(
        barcodes: [
          Barcode(
            rawValue: privateInvitation.encode(),
            format: BarcodeFormat.qrCode,
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Private groups require an NFC tap'),
      findsOneWidget,
    );
    expect(find.byType(ScanInvitationScreen), findsOneWidget);
  });

  testWidgets('private NFC screen never suggests a QR fallback', (
    tester,
  ) async {
    final connection = NfcConnection()..disabled = true;
    addTearDown(connection.updates.close);
    await tester.pumpWidget(
      MaterialApp(
        home: NfcInvitationScreen(
          connectivity: connection,
          sharing: true,
          privateGroup: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Private groups use NFC invitations only'),
      findsOneWidget,
    );
    expect(find.textContaining('Public groups also support QR'), findsNothing);
  });
}
