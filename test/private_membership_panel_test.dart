import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_group_messenger/core/messaging/tcp_message_transport.dart';
import 'package:offline_group_messenger/features/chat/private_membership_panel.dart';

class _LegacyHost extends TcpMessageTransport {
  bool waiting = false;
  @override
  bool get waitingForApproval => waiting;
}

void main() {
  testWidgets('updated hosts never show a second membership decision', (
    tester,
  ) async {
    final transport = _LegacyHost();
    addTearDown(transport.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: PrivateMembershipPanel(transport: transport)),
      ),
    );
    expect(find.byType(ListTile), findsNothing);
    expect(find.text('Approve join'), findsNothing);
    expect(find.text('Decline join'), findsNothing);
    transport.waiting = true;
    transport.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.text('Waiting for a host with an older app'), findsOneWidget);
    expect(find.byType(FilledButton), findsNothing);
    transport.waiting = false;
    transport.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.byType(ListTile), findsNothing);
  });
}
