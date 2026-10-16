import 'package:collab_client/collab_client.dart';
import 'package:flutter/material.dart';

import 'editor_controller.dart';

/// Connection state (live / reconnecting / offline), unacknowledged edit count and the last applied seq.
class StatusBar extends StatelessWidget {
  const StatusBar({super.key, required this.controller, required this.clientId, required this.serverLabel});

  final EditorController controller;
  final String clientId;
  final String serverLabel;

  @override
  Widget build(BuildContext context) {
    final s = controller.status;
    final (color, label) = switch (s.link) {
      LinkState.live => (Colors.green.shade600, 'Live'),
      LinkState.connecting => (Colors.amber.shade700, 'Connecting…'),
      LinkState.reconnecting => (Colors.amber.shade700, 'Reconnecting…'),
      LinkState.offline => (Colors.red.shade600, 'Offline'),
    };
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall!;
    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Container(
        height: 30,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(children: [
          Tooltip(
            message: s.lastError ?? 'connected to $serverLabel',
            child: Row(children: [
              Icon(Icons.circle, size: 10, color: color, key: const Key('link-dot')),
              const SizedBox(width: 6),
              Text(label, key: const Key('link-state'), style: small.copyWith(fontWeight: FontWeight.w600)),
            ]),
          ),
          if (s.link != LinkState.live)
            TextButton(
              key: const Key('reconnect-now'),
              style: TextButton.styleFrom(minimumSize: const Size(0, 24), padding: const EdgeInsets.symmetric(horizontal: 8)),
              onPressed: controller.reconnectNow,
              child: const Text('Reconnect now'),
            ),
          const SizedBox(width: 20),
          Text(
            s.pending == 0 ? 'All edits saved' : '${s.pending} unsaved edit${s.pending == 1 ? '' : 's'}',
            key: const Key('pending-count'),
            style: small.copyWith(
              color: s.pending == 0 ? null : Colors.amber.shade900,
              fontWeight: s.pending == 0 ? null : FontWeight.w600,
            ),
          ),
          const SizedBox(width: 20),
          Text('seq ${s.lastSeq}', key: const Key('last-seq'), style: small),
          const Spacer(),
          Text(
            '${controller.journaled ? 'journaled' : 'volatile'} · $clientId · ${controller.docId}',
            style: small.copyWith(color: Colors.black54),
          ),
        ]),
      ),
    );
  }
}
