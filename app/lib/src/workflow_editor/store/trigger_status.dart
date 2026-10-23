import 'package:flutter/foundation.dart';

/// store/trigger-status.ts `EntryNodeStatus`.
enum EntryNodeStatus { enabled, disabled }

/// store/trigger-status.ts: whether each entry (trigger) node is enabled, by node id. Every update replaces the map,
/// so listeners of [triggerStatuses] are notified on each call.
class TriggerStatusStore {
  final triggerStatuses = ValueNotifier<Map<String, EntryNodeStatus>>(const {});

  void setTriggerStatus(String nodeId, EntryNodeStatus status) =>
      triggerStatuses.value = {...triggerStatuses.value, nodeId: status};

  void setTriggerStatuses(Map<String, EntryNodeStatus> statuses) => triggerStatuses.value = statuses;

  /// Disabled unless set.
  EntryNodeStatus getTriggerStatus(String nodeId) => triggerStatuses.value[nodeId] ?? EntryNodeStatus.disabled;

  void clearTriggerStatuses() => triggerStatuses.value = const {};

  void dispose() => triggerStatuses.dispose();
}
