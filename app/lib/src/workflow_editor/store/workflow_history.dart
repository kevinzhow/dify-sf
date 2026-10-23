import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'workflow_store.dart';
import 'workflow_store_scope.dart';

/// hooks/use-workflow-history.ts `WorkflowHistoryEvent`: what made a history entry.
enum WorkflowHistoryEvent {
  nodeTitleChange,
  nodeDescriptionChange,
  nodeDragStop,
  nodeChange,
  nodeConnect,
  nodePaste,
  nodeDelete,
  edgeDelete,
  edgeDeleteByDeleteBranch,
  edgeSourceHandleChange,
  nodeAdd,
  nodeResize,
  noteAdd,
  noteChange,
  noteDelete,
  layoutOrganize,
}

typedef WorkflowHistoryEventMeta = ({String? nodeId, String? nodeTitle});

/// history-slice.ts `WorkflowHistoryState`: one snapshot of the graph (React Flow nodes and edges as Dify's JSON)
/// and the event that produced it.
@immutable
class WorkflowHistoryState {
  const WorkflowHistoryState({
    required this.nodes,
    required this.edges,
    this.workflowHistoryEvent,
    this.workflowHistoryEventMeta,
  });

  static const empty = WorkflowHistoryState(nodes: [], edges: []);

  final List<DifyJson> nodes;
  final List<DifyJson> edges;
  final WorkflowHistoryEvent? workflowHistoryEvent;
  final WorkflowHistoryEventMeta? workflowHistoryEventMeta;

  /// history-slice.ts `isWorkflowHistoryTemporalStateEqual` (fast-deep-equal).
  bool deepEquals(WorkflowHistoryState other) =>
      identical(this, other) ||
      workflowHistoryEvent == other.workflowHistoryEvent &&
          workflowHistoryEventMeta == other.workflowHistoryEventMeta &&
          _deepEqual(nodes, other.nodes) &&
          _deepEqual(edges, other.edges);
}

bool _deepEqual(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_deepEqual(a[i], b[i])) return false;
    }
    return true;
  }
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final k in a.keys) {
      if (!b.containsKey(k) || !_deepEqual(a[k], b[k])) return false;
    }
    return true;
  }
  return a == b;
}

/// The store's `workflowHistory` field: a [ValueNotifier] whose writes are recorded in [temporal].
class WorkflowHistoryValue extends ValueNotifier<WorkflowHistoryState> {
  WorkflowHistoryValue(super.value);

  late final temporal = WorkflowHistoryTemporal._(this);

  @override
  set value(WorkflowHistoryState next) {
    final past = super.value;
    super.value = next;
    temporal._track(past, next);
  }

  void _apply(WorkflowHistoryState state) => super.value = state;

  @override
  void dispose() {
    temporal.dispose();
    super.dispose();
  }
}

/// zundo's temporal state for the workflow history (no limit, so unbounded; in memory only): every change of
/// `workflowHistory` while tracking pushes the previous snapshot on [pastStates] and clears [futureStates].
class WorkflowHistoryTemporal extends ChangeNotifier {
  WorkflowHistoryTemporal._(this._value);

  final WorkflowHistoryValue _value;

  /// Oldest first; the last one is what [undo] goes back to.
  List<WorkflowHistoryState> get pastStates => List.unmodifiable(_past);

  /// The last one is what [redo] goes forward to.
  List<WorkflowHistoryState> get futureStates => List.unmodifiable(_future);
  final _past = <WorkflowHistoryState>[];
  final _future = <WorkflowHistoryState>[];

  bool get isTracking => _isTracking;
  bool _isTracking = true;

  void Function(WorkflowHistoryState pastState, WorkflowHistoryState currentState)? _onSave;

  void _track(WorkflowHistoryState past, WorkflowHistoryState current) {
    if (!_isTracking || past.deepEquals(current)) return;
    _onSave?.call(past, current);
    _past.add(past);
    _future.clear();
    notifyListeners();
  }

  /// Goes back [steps] entries (at most as many as there are).
  void undo([int steps = 1]) {
    if (_past.isEmpty) return;
    final current = _value.value;
    final toApply = _past.sublist(_past.length - steps.clamp(0, _past.length));
    _past.removeRange(_past.length - toApply.length, _past.length);
    final next = toApply.removeAt(0);
    _value._apply(next);
    _future
      ..add(current)
      ..addAll(toApply.reversed);
    notifyListeners();
  }

  /// Goes forward [steps] entries (at most as many as there are).
  void redo([int steps = 1]) {
    if (_future.isEmpty) return;
    final current = _value.value;
    final toApply = _future.sublist(_future.length - steps.clamp(0, _future.length));
    _future.removeRange(_future.length - toApply.length, _future.length);
    final next = toApply.removeAt(0);
    _value._apply(next);
    _past
      ..add(current)
      ..addAll(toApply.reversed);
    notifyListeners();
  }

  void clear() {
    _past.clear();
    _future.clear();
    notifyListeners();
  }

  void pause() {
    _isTracking = false;
    notifyListeners();
  }

  void resume() {
    _isTracking = true;
    notifyListeners();
  }

  void setOnSave(void Function(WorkflowHistoryState pastState, WorkflowHistoryState currentState)? onSave) =>
      _onSave = onSave;
}

/// workflow-history-store.ts: the history as the undo/redo hook sees it. Snapshots written through [setState] are
/// stored with every node's `data.selected` and every edge's `selected` false.
class WorkflowHistoryStore {
  WorkflowHistoryStore(this._store);

  /// `useWorkflowHistoryStore()`: throws when there is no [WorkflowStoreScope] above [context].
  factory WorkflowHistoryStore.of(BuildContext context) => WorkflowHistoryStore(WorkflowStoreScope.of(context));

  final WorkflowStore _store;

  WorkflowHistoryState getState() => _store.workflowHistory.value;
  void setState(WorkflowHistoryState state) => _store.setWorkflowHistory(sanitizeWorkflowHistory(state));

  /// Notifies when the history snapshot changes.
  ValueListenable<WorkflowHistoryState> get listenable => _store.workflowHistory;
  WorkflowHistoryTemporal get temporal => _store.temporal;
}

WorkflowHistoryState sanitizeWorkflowHistory(WorkflowHistoryState state) => WorkflowHistoryState(
  workflowHistoryEvent: state.workflowHistoryEvent,
  workflowHistoryEventMeta: state.workflowHistoryEventMeta,
  nodes: [
    for (final node in state.nodes)
      {
        ...node,
        'data': {...?(node['data'] as Map<String, Object?>?), 'selected': false},
      },
  ],
  edges: [
    for (final edge in state.edges) {...edge, 'selected': false},
  ],
);
