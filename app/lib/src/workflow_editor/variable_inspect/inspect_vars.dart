/// The variable inspect panel's data (hooks/use-inspect-vars-crud.ts, use-inspect-vars-crud-common.ts and
/// use-fetch-workflow-inspect-vars.ts over the store's inspect-vars slice): the cached node variables live in
/// [WorkflowStore.nodesWithInspectVars]; the environment variables are the store's (the document's, read-only here);
/// the conversation variables are draft values over the document's declarations; the system variables and every
/// last-run value come from [VariableInspectServices] (dify-sf has no runtime yet: by default there are none).
library;

import 'package:collab_client/collab_client.dart' show Node;
import 'package:flutter/widgets.dart';

import '../../workflow/var_types.dart' show VarTypes;
import '../context_menu/clipboard.dart' show difyNodeOf;
import '../store/store.dart';

/// `VarInInspectType` (types/workflow.ts).
abstract final class VarInInspectType {
  static const conversation = 'conversation';
  static const environment = 'env';
  static const node = 'node';
  static const system = 'sys';
}

/// `EVENT_WORKFLOW_STOP` (variable-inspect/types.ts).
const eventWorkflowStop = 'WORKFLOW_STOP';

/// Dify's draft variable endpoints (service/workflow.ts, service/use-workflow.ts). Variables are Dify's
/// `VarInInspect` JSON (`id`, `type`, `name`, `description`, `selector`, `value_type`, `value`, `edited`,
/// `visible`, `is_truncated`, `full_content`). The defaults are a workspace without runs: nothing cached.
class VariableInspectServices {
  const VariableInspectServices();

  static const none = VariableInspectServices();

  /// `fetchAllInspectVars`: every cached variable of the draft (each node's last run).
  Future<List<DifyJson>> fetchAllInspectVars() async => const [];

  /// `fetchNodeInspectVars`: the node's cached variables with their values; null without a backend (the variables
  /// listed are all there is).
  Future<List<DifyJson>?> fetchNodeInspectVars(String nodeId) async => null;

  /// `useSysVarValues`: the system variables of the last run.
  Future<List<DifyJson>> fetchSystemVars() async => const [];

  /// `useEditInspectorVar`: a variable's new value.
  Future<void> editInspectVar(String varId, Object? value) async {}

  /// `useResetToLastRunValue`: the variable as the last run left it; null without a backend (the editor then puts
  /// back the value it was given).
  Future<DifyJson?> resetToLastRunValue(String varId) async => null;

  Future<void> deleteNodeInspectVars(String nodeId) async {}

  Future<void> deleteAllInspectVars() async {}

  /// FileUploaderInAttachment's two ways in (`local_file`, `remote_url`): the uploaded file as Dify's FileEntity
  /// JSON, or null (no file service: nothing is added).
  Future<DifyJson?> uploadFile(String transferMethod) async => null;

  /// Opens a link in a new tab (a truncated value's download, the docs).
  void openUrl(String url) {}
}

/// `useInspectVarsCrud`: the variables the panel lists and the actions on them, for one editor.
class InspectVarsCrud {
  InspectVarsCrud({required this.store, this.services = VariableInspectServices.none, this.nodes = _noNodes});

  final WorkflowStore store;
  final VariableInspectServices services;

  /// The document's nodes (titles and types of the nodes that have variables, the trigger being listened to).
  final Iterable<Node> Function() nodes;

  static Iterable<Node> _noNodes() => const [];

  /// The conversation variables' draft values, by declaration id (an entry: edited). Dify keeps them server-side,
  /// apart from the declarations; here they live as long as the editor.
  final conversationEdits = ValueNotifier<Map<String, Object?>>(const {});

  /// `useSysVarValues`' data: every system variable, `query` and `files` included.
  final allSystemVars = ValueNotifier<List<DifyJson>>(const []);

  /// The values variables had when they were cached, for "reset to last run" without a backend.
  final _lastRun = <String, Object?>{};

  /// Everything the lists depend on.
  late final Listenable changes = Listenable.merge([
    store.nodesWithInspectVars,
    store.environmentVariables,
    store.conversationVariables,
    conversationEdits,
    allSystemVars,
  ]);

  static const _varsAppendStartNodeKeys = ['query', 'files'];

  /// The conversation variables as draft variables (prefilled from the declarations, as Dify's backend does).
  List<DifyJson> get conversationVars {
    final edits = conversationEdits.value;
    return [
      for (final v in store.conversationVariables.value)
        {
          'id': v['id'],
          'type': VarInInspectType.conversation,
          'name': v['name'],
          'description': v['description'] ?? '',
          'selector': [VarInInspectType.conversation, v['name']],
          'value_type': v['value_type'],
          'value': edits.containsKey(v['id']) ? edits[v['id']] : v['value'],
          'edited': edits.containsKey(v['id']),
          'visible': true,
          'is_truncated': false,
        },
    ];
  }

  /// The system variables but `query` and `files` (those join the Start node's group).
  List<DifyJson> get systemVars => [
    for (final v in allSystemVars.value)
      if (!_varsAppendStartNodeKeys.contains(v['name'])) v,
  ];

  /// The store's nodes with variables, the Start node with the `query` and `files` system variables appended.
  List<DifyJson> get nodesWithInspectVars {
    final append = [
      for (final v in allSystemVars.value)
        if (_varsAppendStartNodeKeys.contains(v['name'])) v,
    ];
    return [
      for (final n in store.nodesWithInspectVars.value)
        n['nodeType'] == 'start' && append.isNotEmpty
            ? {
                ...n,
                'vars': [...varsOf(n), ...append],
              }
            : n,
    ];
  }

  /// Whether there is anything to inspect (the trigger's "View cached variables", the panel's non-empty state).
  bool get hasVars =>
      store.environmentVariables.value.isNotEmpty ||
      store.conversationVariables.value.isNotEmpty ||
      systemVars.isNotEmpty ||
      store.nodesWithInspectVars.value.isNotEmpty;

  static List<DifyJson> varsOf(DifyJson node) => [...(node['vars'] as List? ?? const []).cast<DifyJson>()];

  void _remember(Iterable<DifyJson> vars) {
    for (final v in vars) {
      if (v['id'] case final String id) _lastRun[id] = v['value'];
    }
  }

  /// useSetWorkflowVarsWithValue `fetchInspectVars`: the draft's cached variables (or [vars], when given) grouped by
  /// node in the order they first appear (nodes no longer in the document are left out), each with the `schemaType`
  /// of the node's output variable of that name; values to be fetched per node. The nodes' succeeded run status is
  /// cleared (handleCancelAllNodeSuccessStatus), so a cleared output shows as unset.
  Future<void> fetchInspectVars({List<DifyJson>? vars}) async {
    invalidateSysVarValues();
    final data = vars ?? await services.fetchAllInspectVars();
    if (_disposed) return;
    final byId = {for (final n in nodes()) n.id: n};
    final byNode = <String, List<DifyJson>>{};
    for (final v in data) {
      final selector = v['selector'];
      if (selector is List && selector.isNotEmpty && byId.containsKey(selector.first)) {
        (byNode[selector.first as String] ??= []).add(v);
      }
    }
    _remember(data);
    store.setNodesWithInspectVars([
      for (final MapEntry(key: id, value: vars) in byNode.entries)
        {
          ..._nodeWithVar(byId[id]!),
          'vars': [for (final v in vars) _withSchemaType(byId[id]!, v)],
          'isValueFetched': false,
        },
    ]);
    _cancelAllNodeSuccessStatus();
  }

  /// [v] with the `schemaType` of [node]'s output variable named like it (`toNodeOutputVars`), else [fallback].
  DifyJson _withSchemaType(Node node, DifyJson v, [Object? fallback]) {
    String? schemaType;
    try {
      final outputs = VarTypes(lookup: (id) => id == node.id ? node : null).outputVarsOf(node);
      schemaType = outputs?.where((o) => o.variable == v['name']).firstOrNull?.schemaType;
    } on StateError {
      schemaType = null;
    }
    return {...v, 'schemaType': schemaType ?? fallback ?? ''};
  }

  /// handleCancelAllNodeSuccessStatus.
  void _cancelAllNodeSuccessStatus() {
    for (final MapEntry(key: id, value: data) in store.nodeRunData.value.entries) {
      if (data['_runningStatus'] == 'succeeded') store.setNodeRunData(id, const {'_runningStatus': null});
    }
  }

  DifyJson _nodeWithVar(Node n) {
    final payload = difyNodeOf(n)['data'] as DifyJson? ?? const {};
    return {
      'nodeId': n.id,
      'nodePayload': payload,
      'nodeType': n.type,
      'title': payload['title'] ?? n.title,
      'isSingRunRunning': false,
    };
  }

  /// `appendNodeInspectVars`: a node's variables after it ran, its group moved to the top.
  void appendNodeInspectVars(String nodeId, List<DifyJson> payload) {
    final node = nodes().where((n) => n.id == nodeId).firstOrNull;
    if (node == null) return;
    _remember(payload);
    final list = store.nodesWithInspectVars.value;
    final existing = list.where((n) => n['nodeId'] == nodeId).firstOrNull;
    store.setNodesWithInspectVars([
      existing == null ? {..._nodeWithVar(node), 'vars': payload} : {...existing, 'vars': payload},
      for (final n in list)
        if (n['nodeId'] != nodeId) n,
    ]);
    // handleCancelNodeSuccessStatus.
    if (store.nodeRunDataOf(nodeId)['_runningStatus'] == 'succeeded') {
      store.setNodeRunData(nodeId, const {'_runningStatus': null, '_waitingRun': false});
    }
  }

  /// `fetchInspectVarValue([nodeId])`.
  Future<void> fetchInspectVarValue(String nodeId) async {
    if (nodeId == VarInInspectType.system) return invalidateSysVarValues();
    if (nodeId == VarInInspectType.conversation) return;
    final listed = varsOf(store.nodesWithInspectVars.value.where((n) => n['nodeId'] == nodeId).firstOrNull ?? {});
    final vars = await services.fetchNodeInspectVars(nodeId);
    if (_disposed) return;
    if (vars == null) return store.setNodeInspectVars(nodeId, listed);
    final old = {for (final v in listed) v['id']: v};
    _remember(vars);
    final node = nodes().where((n) => n.id == nodeId).firstOrNull;
    store.setNodeInspectVars(nodeId, [
      for (final v in vars)
        node == null
            ? {...v, 'schemaType': v['schemaType'] ?? old[v['id']]?['schemaType'] ?? ''}
            : _withSchemaType(node, v, v['schemaType'] ?? old[v['id']]?['schemaType']),
    ]);
  }

  /// `invalidateSysVarValues`: fetches the system variables again.
  Future<void> invalidateSysVarValues() async {
    final vars = await services.fetchSystemVars();
    if (_disposed) return;
    _remember(vars);
    allSystemVars.value = vars;
  }

  /// `editInspectVarValue`.
  Future<void> editInspectVarValue(String nodeId, String varId, Object? value) async {
    if (nodeId == VarInInspectType.conversation) {
      conversationEdits.value = {...conversationEdits.value, varId: value};
      return;
    }
    // The value before the first edit is the last run's (whoever cached the variable).
    final current = InspectVarsCrud.varsOf(
      store.nodesWithInspectVars.value.where((n) => n['nodeId'] == nodeId).firstOrNull ?? const {},
    ).where((v) => v['id'] == varId).firstOrNull;
    if (current != null && current['edited'] != true) _lastRun.putIfAbsent(varId, () => current['value']);
    await services.editInspectVar(varId, value);
    if (_disposed) return;
    store.setInspectVarValue(nodeId, varId, value);
    if (nodeId == VarInInspectType.system) await invalidateSysVarValues();
  }

  /// `resetToLastRunVar`.
  Future<void> resetToLastRunVar(String nodeId, String varId) async {
    final data = await services.resetToLastRunValue(varId);
    if (_disposed) return;
    if (nodeId == VarInInspectType.system) return invalidateSysVarValues();
    store.resetToLastRunVar(nodeId, varId, data != null ? data['value'] : _lastRun[varId]);
  }

  /// `resetConversationVar`: back to the declaration's value.
  void resetConversationVar(String varId) => conversationEdits.value = {...conversationEdits.value}..remove(varId);

  /// `deleteNodeInspectorVars`.
  Future<void> deleteNodeInspectorVars(String nodeId) async {
    if (!store.nodesWithInspectVars.value.any((n) => n['nodeId'] == nodeId)) return;
    await services.deleteNodeInspectVars(nodeId);
    if (_disposed) return;
    store.deleteNodeInspectVars(nodeId);
  }

  /// `deleteAllInspectorVars`: every cached value goes, the conversation variables' drafts included, and the edges'
  /// run state is cleared (handleEdgeCancelRunningStatus).
  Future<void> deleteAllInspectorVars() async {
    await services.deleteAllInspectVars();
    if (_disposed) return;
    conversationEdits.value = const {};
    await invalidateSysVarValues();
    store.deleteAllInspectVars();
    for (final id in store.edgeRunData.value.keys.toList()) {
      store.setEdgeRunData(id, const {
        '_sourceRunningStatus': null,
        '_targetRunningStatus': null,
        '_waitingRun': false,
      });
    }
  }

  /// Answers arriving after [dispose] (the editor closed) are dropped.
  bool _disposed = false;

  void dispose() {
    _disposed = true;
    conversationEdits.dispose();
    allSystemVars.dispose();
  }
}

/// The editor's variable inspect data and what the panel does outside itself: [onViewNode] opens a node's panel on
/// its Last Run tab (`handleNodeSelect(nodeId, false, true)`), [onStop] is the `EVENT_WORKFLOW_STOP` event.
class VariableInspectScope extends InheritedWidget {
  const VariableInspectScope({super.key, required this.crud, this.onViewNode, this.onStop, required super.child});

  final InspectVarsCrud crud;
  final ValueChanged<String>? onViewNode;
  final VoidCallback? onStop;

  static VariableInspectScope? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<VariableInspectScope>();

  /// Throws when there is no scope above [context].
  static VariableInspectScope of(BuildContext context) =>
      maybeOf(context) ?? (throw StateError('Missing VariableInspectScope in the tree'));

  @override
  bool updateShouldNotify(VariableInspectScope old) =>
      crud != old.crud || onViewNode != old.onViewNode || onStop != old.onStop;
}

/// Makes the editor's [InspectVarsCrud] (from the store in scope) for its lifetime, loads the cached variables and
/// puts it in a [VariableInspectScope] over [child].
class VariableInspectHost extends StatefulWidget {
  const VariableInspectHost({
    super.key,
    this.services = VariableInspectServices.none,
    this.nodes,
    this.onViewNode,
    this.onStop,
    required this.child,
  });

  final VariableInspectServices services;
  final Iterable<Node> Function()? nodes;
  final ValueChanged<String>? onViewNode;
  final VoidCallback? onStop;
  final Widget child;

  @override
  State<VariableInspectHost> createState() => _VariableInspectHostState();
}

class _VariableInspectHostState extends State<VariableInspectHost> {
  late final crud = InspectVarsCrud(
    store: WorkflowStoreScope.of(context),
    services: widget.services,
    nodes: () => widget.nodes?.call() ?? const [],
  );

  @override
  void initState() {
    super.initState();
    crud.fetchInspectVars();
  }

  @override
  void dispose() {
    crud.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      VariableInspectScope(crud: crud, onViewNode: widget.onViewNode, onStop: widget.onStop, child: widget.child);
}
