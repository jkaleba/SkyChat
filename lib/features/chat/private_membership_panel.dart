import 'package:flutter/material.dart';

import '../../core/messaging/tcp_message_transport.dart';

/// Membership decisions remain available on both the home and chat screens.
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
          title: Text('Waiting for host approval'),
          subtitle: Text(
            'Your contact is verified. The host must approve this group.',
          ),
        );
      }
      final requests = transport.joinRequests;
      if (requests.isEmpty) return const SizedBox.shrink();
      return ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 240),
        child: SingleChildScrollView(
          child: Column(
            children: [
              for (final request in requests)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${request.name} wants to join',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const Text(
                          'Verified contact · Access to this group only',
                        ),
                        Wrap(
                          spacing: 12,
                          children: [
                            TextButton(
                              onPressed: () => transport.rejectJoin(request.id),
                              child: const Text('Decline join'),
                            ),
                            FilledButton(
                              onPressed: () =>
                                  transport.approveJoin(request.id),
                              child: const Text('Approve join'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    },
  );
}
