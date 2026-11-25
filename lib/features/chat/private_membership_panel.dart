import 'package:flutter/material.dart';

import '../../core/messaging/tcp_message_transport.dart';

/// Compatibility notice for a client connected to an older, approval-based host.
class PrivateMembershipPanel extends StatelessWidget {
  const PrivateMembershipPanel({super.key, required this.transport});
  final TcpMessageTransport transport;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: transport,
    builder: (context, _) {
      if (transport.waitingForApproval) {
        return const ListTile(
          leading: Icon(Icons.hourglass_top),
          title: Text('Waiting for a host with an older app'),
          subtitle: Text(
            'Ask the host to approve on their phone or update SkyChat. Updated hosts admit verified contacts automatically.',
          ),
        );
      }
      return const SizedBox.shrink();
    },
  );
}
