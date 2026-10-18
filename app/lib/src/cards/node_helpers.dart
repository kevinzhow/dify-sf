/// nodes/_base/node.helpers.tsx. Run statuses are Dify's NodeRunningStatus values ('running', 'succeeded', …).
library;

/// Which status border a card shows; none while its selected border shows.
typedef NodeStatusBorders = ({
  bool showRunningBorder,
  bool showSuccessBorder,
  bool showFailedBorder,
  bool showExceptionBorder,
});

NodeStatusBorders getNodeStatusBorders(String? runningStatus, bool hasVarValue, bool showSelectedBorder) => (
  showRunningBorder: (runningStatus == 'running' || runningStatus == 'paused') && !showSelectedBorder,
  showSuccessBorder: (runningStatus == 'succeeded' || (hasVarValue && runningStatus == null)) && !showSelectedBorder,
  showFailedBorder: runningStatus == 'failed' && !showSelectedBorder,
  showExceptionBorder: runningStatus == 'exception' && !showSelectedBorder,
);

String? getLoopIndexTextKey(String? runningStatus) => switch (runningStatus) {
  'running' => 'nodes.loop.currentLoopCount',
  'succeeded' || 'failed' => 'nodes.loop.totalLoopCount',
  _ => null,
};

bool isTriggerNode(String type) => type.startsWith('trigger-');

bool isEntryWorkflowNode(String type) => isTriggerNode(type) || type == 'start' || type == 'start-placeholder';

/// utils/workflow-entry.ts `isWorkflowEntryNode`: the Start node or a trigger.
bool isWorkflowEntryNode(String type) => type == 'start' || isTriggerNode(type);

/// utils/workflow-entry.ts `getWorkflowEntryNode`: the first trigger node, else the Start node ([typeOf] reads a
/// node's type).
T? getWorkflowEntryNode<T>(Iterable<T> nodes, String Function(T node) typeOf) =>
    nodes.where((n) => isTriggerNode(typeOf(n))).firstOrNull ?? nodes.where((n) => typeOf(n) == 'start').firstOrNull;

bool isContainerNode(String type) => type == 'iteration' || type == 'loop';
