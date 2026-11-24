import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_group_messenger/core/messaging/tcp_message_transport.dart';
import 'package:offline_group_messenger/features/chat/private_membership_panel.dart';

class _Requests extends TcpMessageTransport {
  final requests = <PrivateJoinRequest>[
    const PrivateJoinRequest('request', 'alice', 'Alice'),
  ];
  String? approved;
  String? declined;
  @override
  List<PrivateJoinRequest> get joinRequests => requests;
  @override
  Future<void> approveJoin(String id) async {
    approved = id;
    requests.clear();
    notifyListeners();
  }

  @override
  void rejectJoin(String id) {
    declined = id;
    requests.clear();
    notifyListeners();
  }
}

void main() {
  for (final approve in [true, false]) {
    testWidgets(
      'host can ${approve ? 'approve' : 'decline'} a named join request',
      (tester) async {
        final transport = _Requests();
        addTearDown(transport.dispose);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: PrivateMembershipPanel(transport: transport)),
          ),
        );
        expect(find.text('Alice wants to join'), findsOneWidget);
        await tester.tap(find.text(approve ? 'Approve join' : 'Decline join'));
        await tester.pumpAndSettle();
        expect(approve ? transport.approved : transport.declined, 'request');
        expect(find.text('Alice wants to join'), findsNothing);
      },
    );
  }
}
