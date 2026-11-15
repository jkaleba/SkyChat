import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_connectivity/offline_connectivity.dart';
import 'package:offline_group_messenger/core/contacts/contact_repository.dart';
import 'package:offline_group_messenger/core/messaging/chat_session_controller.dart';
import 'package:offline_group_messenger/features/contacts/contacts_screen.dart';
import 'package:offline_group_messenger/features/home/home_screen.dart';

class ContactsFake extends ContactRepository {
  int approvals = 0;
  int stops = 0;
  String username = 'SM-A217F';
  String? lastStartedName;
  bool? lastStartedReader;
  Map<String, dynamic>? state;
  List<SavedContact> list = [
    const SavedContact(id: 'peer', name: 'Bob', trust: ContactTrust.pending),
  ];
  final List<({String id, String name})> renames = [];

  @override
  Future<String> loadUsername() async => username;

  @override
  Future<void> saveUsername(String name) async {
    username = name;
  }

  @override
  Future<ContactSnapshot> load() async => ContactSnapshot('self', list);

  @override
  Future<void> rename(String id, String name) async {
    renames.add((id: id, name: name));
    list = [
      for (final c in list)
        c.id == id ? SavedContact(id: c.id, name: name, trust: c.trust) : c,
    ];
  }

  @override
  Future<void> startPairing(String name, {required bool reader}) async {
    lastStartedName = name;
    lastStartedReader = reader;
    state = {
      'state': 'confirm',
      'name': 'Bob',
      'code': '1234 abcd',
      'approved': false,
    };
  }

  @override
  Future<Map<String, dynamic>?> pairingStatus() async => state;

  @override
  Future<void> approvePairing() async {
    approvals++;
    state!['approved'] = true;
  }

  @override
  Future<void> stopPairing() async {
    stops++;
  }
}

void main() {
  testWidgets('pending contact cannot appear verified or callable', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: ContactsScreen(repository: ContactsFake())),
    );
    await tester.pumpAndSettle();
    expect(find.text('Your username'), findsOneWidget);
    expect(find.text('SM-A217F'), findsOneWidget);
    expect(find.text('Share contact'), findsOneWidget);
    expect(find.text('Add contact'), findsOneWidget);
    expect(find.text('Bob'), findsOneWidget);
    expect(find.textContaining('Pairing incomplete'), findsOneWidget);
    expect(find.text('Verified by NFC'), findsNothing);
    expect(find.text('Call'), findsNothing);
  });

  testWidgets('username can be edited on Contacts screen', (tester) async {
    final repository = ContactsFake();
    await tester.pumpWidget(
      MaterialApp(home: ContactsScreen(repository: repository)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Change username'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Alice');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));
    expect(repository.username, 'Alice');
    expect(find.text('Alice'), findsOneWidget);
  });

  testWidgets('NFC comparison uses username, has no name field, and cleans up', (
    tester,
  ) async {
    final repository = ContactsFake();
    await tester.pumpWidget(
      MaterialApp(
        home: ContactPairingScreen(
          repository: repository,
          username: 'Alice',
          reader: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    expect(repository.lastStartedName, 'Alice');
    expect(repository.lastStartedReader, isTrue);
    expect(repository.approvals, 0);
    expect(find.text('1234 abcd'), findsOneWidget);
    await tester.ensureVisible(find.text('Codes match — confirm contact'));
    await tester.tap(find.text('Codes match — confirm contact'));
    await tester.pumpAndSettle();
    expect(repository.approvals, 1);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(repository.stops, 1);
  });

  testWidgets('Share contact starts NFC sharing and prompts rename on duplicate name', (
    tester,
  ) async {
    final repository = ContactsFake()
      ..list = const [
        SavedContact(id: 'peer-1', name: 'Bob', trust: ContactTrust.verified),
      ];
    await tester.pumpWidget(
      MaterialApp(home: ContactsScreen(repository: repository)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Share contact'));
    await tester.pumpAndSettle();
    expect(repository.lastStartedReader, isFalse);
    expect(repository.lastStartedName, 'SM-A217F');

    // Simulate a second contact with the same name being saved during pairing.
    repository.list = const [
      SavedContact(id: 'peer-1', name: 'Bob', trust: ContactTrust.verified),
      SavedContact(id: 'peer-2', name: 'Bob', trust: ContactTrust.verified),
    ];

    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(find.text('Duplicate contact name'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Bob 2');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));

    expect(repository.renames, [(id: 'peer-2', name: 'Bob 2')]);
    expect(find.text('Bob 2'), findsOneWidget);
  });

  testWidgets('username from Contacts is used as group chat displayName', (
    tester,
  ) async {
    final repository = ContactsFake()..username = 'Galaxy A21s';
    final chat = ChatSessionController();
    addTearDown(chat.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(
          connectivity: const OfflineConnectivity(),
          chat: chat,
          contacts: repository,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(chat.transport.displayName, 'Galaxy A21s');

    await tester.tap(find.text('Contacts'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Change username'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Jan');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));

    expect(chat.transport.displayName, 'Jan');
  });

  testWidgets('ContactPairingScreen shows touching guidance across pairing states', (
    tester,
  ) async {
    final repository = ContactsFake();
    await tester.pumpWidget(
      MaterialApp(
        home: ContactPairingScreen(
          repository: repository,
          username: 'Alice',
          reader: false,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Confirm state
    expect(find.text('Step 2 of 3 · Compare verification code'), findsOneWidget);
    expect(find.text('Keep phones touching'), findsOneWidget);

    // Approve on this phone -> waiting for peer confirmation
    await tester.tap(find.text('Codes match — confirm contact'));
    await tester.pumpAndSettle();
    expect(find.text('Step 3 of 3 · Waiting for the other phone'), findsOneWidget);
    expect(find.text('Keep phones touching'), findsOneWidget);

    // Verified state -> safe to stop touching
    repository.state = {
      'state': 'verified',
      'name': 'Bob',
      'code': '1234 abcd',
      'approved': true,
    };
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(find.text('Contact verified and saved'), findsOneWidget);
    expect(find.text('You can stop touching the phones'), findsOneWidget);
  });
}
