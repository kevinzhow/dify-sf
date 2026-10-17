/// The checklist's logic, ported from Dify 1.17.1 web/app/components/workflow/hooks/use-checklist.ts (`useChecklist`'s
/// `needWarningNodes`, `useChecklistBeforePublish`'s `handleCheckBeforePublish`, `useWorkflowRunValidation`), with
/// `getValidTreeNodes` (utils/workflow.ts), `getBeforeNodesInSameBranch(IncludeParent)` (hooks/use-workflow.ts),
/// `isNodePluginMissing` (utils/plugin-install-check.ts) and the default node metadata (`useAvailableNodesMetaData`).
///
/// Pure Dart over a Dify-shaped view of the document ([DifyFlowNode], [DifyFlowEdge]). What Dify reads from hooks and
/// services comes in a [ChecklistEnv]. Left out: the inline Agent v2 checks (`agentComposer` queries to Dify's backend:
/// missing model / files / skills / tools), and before publishing the fetches of the latest datasets and knowledge-base
/// models ([ChecklistEnv.datasetsDetail] is used as is).
library;

import 'package:collab_client/collab_client.dart';

import '../../../i18n/dify_i18n.dart';
import '../../../workflow/dify_json.dart';
import '../../../workflow/var_types.dart';
import '../../store/workflow_store.dart';
import 'checklist_item.dart';
import 'node_validators.dart';

export 'node_validators.dart' show ChecklistTranslate, NodeCheckValid, nodeCheckValid;

extension<T> on Iterable<T> {
  T? firstWhereOrNull(bool Function(T) test) => where(test).firstOrNull;
}

/// `CUSTOM_NODE`: React Flow's type of a normal node.
const customNode = 'custom';

/// `MAX_TREE_DEPTH` (web/config, `NEXT_PUBLIC_MAX_TREE_DEPTH` default).
const maxTreeDepth = 50;

const _startNodeTypes = {'start', 'trigger-schedule', 'trigger-webhook', 'trigger-plugin'};

// ---- the Dify-shaped graph ---------------------------------------------------------------------------------------

/// A React Flow node as Dify's checklist sees it: [type] is React Flow's (`custom`, `custom-note`,
/// `custom-iteration-start`, …), [data] the node's Dify `data` (with `type` and `title`). [node] is the document node
/// it was built from (null for nodes made directly, e.g. in tests).
class DifyFlowNode {
  const DifyFlowNode({required this.id, this.type = customNode, this.parentId, required this.data, this.node});

  /// The view of a document node: React Flow fields from config `_dify_node` (dify-sf nodes have none: `custom`).
  factory DifyFlowNode.of(Node node) {
    final rf = plainOf(node.config['_dify_node']);
    final parent = jsStr(jsGet(rf, 'parentId'));
    return DifyFlowNode(
      id: node.id,
      type: jsStr(jsGet(rf, 'type')) ?? customNode,
      parentId: parent == null || parent.isEmpty ? null : parent,
      data: difyDataOf(node)..remove('_dify_node'),
      node: node,
    );
  }

  final String id;
  final String type;
  final String? parentId;
  final Map<String, Object?> data;
  final Node? node;

  /// `data.type` (the `BlockEnum` value).
  String get blockType => jsStr(data['type']) ?? '';
  String get title => jsStr(data['title']) ?? '';
}

class DifyFlowEdge {
  const DifyFlowEdge({required this.source, required this.target, this.id = ''});

  factory DifyFlowEdge.of(Edge e) => DifyFlowEdge(id: e.id, source: e.source, target: e.target);

  final String id;
  final String source;
  final String target;
}

/// The document as Dify's React Flow nodes and edges (in document order).
({List<DifyFlowNode> nodes, List<DifyFlowEdge> edges}) difyGraphOf(Document doc) => (
  nodes: [for (final n in doc.nodes.values) DifyFlowNode.of(n)],
  edges: [for (final e in doc.edges.values) DifyFlowEdge.of(e)],
);

/// React Flow's `getOutgoers` (in node order).
List<DifyFlowNode> _outgoers(DifyFlowNode node, List<DifyFlowNode> nodes, List<DifyFlowEdge> edges) {
  final ids = {
    for (final e in edges)
      if (e.source == node.id) e.target,
  };
  return [
    for (final n in nodes)
      if (ids.contains(n.id)) n,
  ];
}

/// React Flow's `getIncomers` (in node order).
List<DifyFlowNode> _incomers(DifyFlowNode node, List<DifyFlowNode> nodes, List<DifyFlowEdge> edges) {
  final ids = {
    for (final e in edges)
      if (e.target == node.id) e.source,
  };
  return [
    for (final n in nodes)
      if (ids.contains(n.id)) n,
  ];
}

List<DifyFlowNode> _uniqById(Iterable<DifyFlowNode> list) {
  final seen = <String>{};
  return [
    for (final n in list)
      if (seen.add(n.id)) n,
  ];
}

/// `getValidTreeNodes` (utils/workflow.ts): the nodes reachable from the start and trigger nodes, with the children of
/// the iterations and loops reached (Dify's quirk: a container reached as an outgoer adds its children before it is
/// traversed, one reached as a leaf after), and the depth of the deepest path.
({List<DifyFlowNode> validNodes, int maxDepth}) getValidTreeNodes(List<DifyFlowNode> nodes, List<DifyFlowEdge> edges) {
  final startNodes = nodes.where((n) => _startNodeTypes.contains(n.blockType)).toList();
  if (startNodes.isEmpty) return (validNodes: const [], maxDepth: 0);

  final list = <DifyFlowNode>[];
  var maxDepth = 0;
  Iterable<DifyFlowNode> childrenOf(DifyFlowNode n) => nodes.where((c) => c.parentId == n.id);
  bool isContainer(DifyFlowNode n) => n.blockType == 'iteration' || n.blockType == 'loop';

  void traverse(DifyFlowNode root, int depth) {
    list.add(root);
    if (depth > maxDepth) maxDepth = depth;
    final outgoers = _outgoers(root, nodes, edges);
    if (outgoers.isNotEmpty) {
      for (final o in outgoers) {
        if (list.any((n) => n.id == o.id)) continue;
        if (isContainer(o)) list.addAll(childrenOf(o));
        traverse(o, depth + 1);
      }
    } else if (isContainer(root)) {
      list.addAll(childrenOf(root));
    }
  }

  for (final s in startNodes) {
    if (!list.any((n) => n.id == s.id)) traverse(s, 1);
  }
  return (validNodes: _uniqById(list), maxDepth: maxDepth);
}

/// `getBeforeNodesInSameBranch` (hooks/use-workflow.ts): the upstream nodes of [nodeId] (and of its container) that
/// have output variables, nearest last.
List<DifyFlowNode> getBeforeNodesInSameBranch(String nodeId, List<DifyFlowNode> nodes, List<DifyFlowEdge> edges) {
  final current = nodes.firstWhereOrNull((n) => n.id == nodeId);
  final list = <DifyFlowNode>[];
  if (current == null) return list;
  if (current.parentId != null) {
    final parent = nodes.firstWhereOrNull((n) => n.id == current.parentId);
    if (parent != null) list.addAll(getBeforeNodesInSameBranch(parent.id, nodes, edges));
  }
  void traverse(DifyFlowNode root) {
    for (final n in _incomers(root, nodes, edges)) {
      if (!list.any((l) => l.id == n.id)) {
        list.add(n);
        traverse(n);
      }
    }
  }

  traverse(current);
  if (list.isEmpty) return [];
  return _uniqById(list).reversed.where((n) => supportOutputVarsNode.contains(n.blockType)).toList();
}

/// `getBeforeNodesInSameBranchIncludeParent` (hooks/use-workflow.ts): [getBeforeNodesInSameBranch] plus the container.
List<DifyFlowNode> getBeforeNodesInSameBranchIncludeParent(
  String nodeId,
  List<DifyFlowNode> nodes,
  List<DifyFlowEdge> edges,
) {
  final list = getBeforeNodesInSameBranch(nodeId, nodes, edges);
  final parentId = nodes.firstWhereOrNull((n) => n.id == nodeId)?.parentId;
  final parent = nodes.firstWhereOrNull((n) => n.id == parentId);
  if (parent != null) list.add(parent);
  return list;
}

// ---- node metadata -----------------------------------------------------------------------------------------------

/// What the checklist reads from a node type's metadata (`nodesMap[type]`).
class NodeMeta {
  const NodeMeta({this.isStart = false, this.isRequired = false, this.checkValid});

  final bool isStart;
  final bool isRequired;

  /// Null where the validator is not ported (it needs plugin or server data): the node is then not validated.
  final NodeCheckValid? checkValid;
}

/// `useAvailableNodesMetaData().nodesMap` of the workflow app (workflow-app/hooks): the common nodes, Start, then
/// Answer in chat mode (required there) or the start placeholder, End and the triggers otherwise, and
/// `variable-assigner` as the aggregator.
Map<String, NodeMeta> difyNodesMetaData({bool chatMode = false}) {
  NodeMeta meta(String type, {bool isStart = false, bool isRequired = false}) =>
      NodeMeta(isStart: isStart, isRequired: isRequired, checkValid: nodeCheckValid[type]);
  return {
    for (final type in const [
      'llm', 'knowledge-retrieval', 'agent', 'agent-v2', 'question-classifier', 'if-else', 'iteration', //
      'iteration-start', 'loop', 'loop-start', 'loop-end', 'code', 'template-transform', 'variable-aggregator',
      'document-extractor', 'assigner', 'parameter-extractor', 'http-request', 'list-operator', 'tool', 'human-input',
    ])
      type: meta(type),
    'start': meta('start', isStart: true),
    if (chatMode)
      'answer': meta('answer', isRequired: true)
    else ...{
      'start-placeholder': meta('start-placeholder'),
      'end': meta('end'),
      'trigger-webhook': meta('trigger-webhook', isStart: true),
      'trigger-schedule': meta('trigger-schedule', isStart: true),
      'trigger-plugin': meta('trigger-plugin', isStart: true),
    },
    'variable-assigner': meta('variable-aggregator'),
  };
}

// ---- environment -------------------------------------------------------------------------------------------------

/// What Dify's checklist reads from hooks and services. Catalogs left null are unknown: nothing is reported missing
/// for them, as in Dify before they load.
class ChecklistEnv {
  ChecklistEnv({
    this.appMode = 'workflow',
    Map<String, NodeMeta>? nodesMeta,
    this.flowType,
    this.environmentVariables = const [],
    this.conversationVariables = const [],
    this.language = 'en_US',
    this.builtInTools,
    this.customTools,
    this.workflowTools,
    this.mcpTools,
    this.triggerPlugins,
    this.dataSourceList,
    this.strategyProviders,
    this.modelProviders,
    this.datasetsDetail = const {},
    this.usedVars,
    this.availableVars,
    this.isSpecialVar = isSpecialVarPrefix,
    this.toolIcon,
    ChecklistTranslate? t,
  }) : nodesMeta = nodesMeta ?? difyNodesMetaData(chatMode: appMode == 'advanced-chat'),
       t = t ?? DifyI18n.tr;

  /// The app's mode (`workflow`, `advanced-chat`, …).
  final String? appMode;

  /// `useNodesMetaData().nodesMap` (default: [difyNodesMetaData] for [appMode]).
  final Map<String, NodeMeta> nodesMeta;

  /// `configsMap.flowType` (`appFlow`, `ragPipeline`, `snippet`), passed to the validators.
  final String? flowType;

  /// The workflow's declarations, as Dify's JSON (`{name, value_type, value}`).
  final List<DifyJson> environmentVariables;
  final List<DifyJson> conversationVariables;

  /// The language for plugin texts (`en_US`, …).
  final String language;

  /// Tool providers (`ToolWithProvider` JSON: `id`, `name`, `plugin_id`, …), trigger providers (`name`, `id`,
  /// `plugin_id`) and data sources (`plugin_unique_identifier`, `plugin_id`, `provider`).
  final List<DifyJson>? builtInTools, customTools, workflowTools, mcpTools, triggerPlugins, dataSourceList;

  /// Agent strategy providers (`{declaration: {identity: {name}, strategies: [{identity: {name}, parameters}]}}`).
  /// Null: not loaded, legacy agent nodes are not checked.
  final List<DifyJson>? strategyProviders;

  /// The workspace's model providers (`provider` names such as `langgenius/openai/openai`, or plugin ids). Null:
  /// unknown, the LLM `configureModel` check is skipped; empty: nothing is installed.
  final Iterable<String>? modelProviders;

  /// Datasets by id (the datasets-detail store), for knowledge-retrieval checks.
  final Map<String, DifyJson> datasetsDetail;

  /// Overrides `getNodeUsedVars` (default: [getNodeUsedVars] of the document node).
  final List<List<String>> Function(DifyFlowNode node)? usedVars;

  /// Overrides the variables available to a node (default: `useNodesAvailableVarList` over the graph).
  final List<NodeOutputVars> Function(DifyFlowNode node)? availableVars;

  final bool Function(String prefix) isSpecialVar;

  /// `useGetToolIcon`: a node's tool icon.
  final Object? Function(DifyFlowNode node)? toolIcon;

  final ChecklistTranslate t;

  bool get chatMode => appMode == 'advanced-chat';
  bool get shouldCheckStartNode => appMode == 'workflow' || appMode == 'advanced-chat';

  Set<String>? get _installedPluginIds => modelProviders == null ? null : {...modelProviders!.map(extractPluginId)};
}

/// `isSpecialVar` (variable/utils.ts).
bool isSpecialVarPrefix(String prefix) => const {'sys', 'env', 'conversation', 'rag'}.contains(prefix);

// ---- shared steps ------------------------------------------------------------------------------------------------

/// `canFindTool` (web/utils).
bool _canFindTool(Object? providerId, Object? oldToolId) =>
    providerId == oldToolId ||
    providerId == 'langgenius/$oldToolId/$oldToolId' ||
    providerId == 'langgenius/${oldToolId}_tool/$oldToolId';

/// `isNodePluginMissing` (utils/plugin-install-check.ts).
bool isNodePluginMissing(Map<String, Object?> data, ChecklistEnv env) {
  final uid = jsTruthy(data['plugin_unique_identifier']);
  switch (data['type']) {
    case 'tool':
      final collection = switch (data['provider_type']) {
        'builtin' => env.builtInTools,
        'api' => env.customTools,
        'workflow' => env.workflowTools,
        'mcp' => env.mcpTools,
        _ => null,
      };
      if (collection == null) return false;
      final found = collection.any(
        (tool) =>
            (jsTruthy(data['plugin_id']) && tool['plugin_id'] == data['plugin_id']) ||
            _canFindTool(tool['id'], data['provider_id']) ||
            tool['name'] == data['provider_name'],
      );
      return !found && uid;
    case 'trigger-plugin':
      final providers = env.triggerPlugins;
      if (providers == null) return false;
      final found = providers.any(
        (p) =>
            p['name'] == data['provider_name'] ||
            p['id'] == data['provider_id'] ||
            (jsTruthy(data['plugin_id']) && p['plugin_id'] == data['plugin_id']),
      );
      return !found && uid;
    case 'datasource':
      final list = env.dataSourceList;
      if (list == null) return false;
      final found = list.any(
        (d) =>
            (uid && d['plugin_unique_identifier'] == data['plugin_unique_identifier']) ||
            (jsTruthy(data['plugin_id']) && d['plugin_id'] == data['plugin_id']) ||
            (jsTruthy(data['provider_name']) && d['provider'] == data['provider_name']),
      );
      return !found && uid;
    default:
      return false;
  }
}

/// `isAgentV2NodeData` (agent-v2/types.ts).
bool _isAgentV2(Map<String, Object?> data) =>
    (data['type'] == 'agent' || data['type'] == 'agent-v2') &&
    data['agent_node_kind'] == 'dify_agent' &&
    data['version'] == '2';

/// `resolveNodeValidator`: the type's validator (Agent v2 data under `agent-v2`), else the legacy agent's.
NodeCheckValid? _validatorOf(Map<String, Object?> data, ChecklistEnv env) {
  final catalogType = _isAgentV2(data) ? 'agent-v2' : data['type'];
  final v = env.nodesMeta[catalogType]?.checkValid;
  if (v != null) return v;
  if (data['type'] == 'agent' && !_isAgentV2(data)) return checkValidAgent;
  return null;
}

/// `getDuplicateEndOutputMessages`: per End node, a message for each output name another End node also uses.
Map<String, List<String>> _duplicateEndOutputMessages(List<DifyFlowNode> nodes, ChecklistEnv env) {
  final occurrences = <String, List<String>>{};
  for (final n in nodes) {
    if (n.type != customNode || n.blockType != 'end') continue;
    for (final o in jsList(n.data['outputs'])) {
      final name = jsStr(jsGet(o, 'variable'))?.trim() ?? '';
      if (name.isNotEmpty) (occurrences[name] ??= []).add(n.id);
    }
  }
  final messages = <String, List<String>>{};
  occurrences.forEach((variable, ids) {
    if (ids.length <= 1) return;
    for (final id in ids.toSet()) {
      (messages[id] ??= []).add(env.t('workflow', 'errorMsg.duplicateOutputVariable', {'variable': variable}));
    }
  });
  return messages;
}

class _Check {
  _Check(this.nodes, this.edges, this.env)
    : filtered = [
        for (final n in nodes)
          if (n.type == customNode) n,
      ],
      byId = {for (final n in nodes) n.id: n};

  final List<DifyFlowNode> nodes;
  final List<DifyFlowEdge> edges;
  final ChecklistEnv env;
  final List<DifyFlowNode> filtered;
  final Map<String, DifyFlowNode> byId;

  late final duplicates = _duplicateEndOutputMessages(filtered, env);
  late final tree = getValidTreeNodes(filtered, edges);
  late final validIds = {for (final n in tree.validNodes) n.id};
  late final installedPluginIds = env._installedPluginIds;

  /// `moreDataForCheckValid` (with `flowType`).
  Map<String, Object?>? moreData(DifyFlowNode n) {
    Map<String, Object?>? more;
    if (n.blockType == 'agent' && !_isAgentV2(n.data)) {
      final providers = env.strategyProviders;
      final provider = providers?.firstWhereOrNull(
        (p) => jsGet(jsGet(jsGet(p, 'declaration'), 'identity'), 'name') == n.data['agent_strategy_provider_name'],
      );
      final strategy = jsList(jsGet(jsGet(provider, 'declaration'), 'strategies')).firstWhereOrNull(
        (s) => jsGet(jsGet(s, 'identity'), 'name') == n.data['agent_strategy_name'],
      );
      more = {
        'provider': provider,
        'strategy': strategy,
        'language': env.language,
        'isReadyForCheckValid': providers != null,
      };
    }
    if (n.blockType == 'llm') more = {...?more, 'environmentVariables': env.environmentVariables};
    if (env.flowType == null) return more;
    return {...?more, 'flowType': env.flowType};
  }

  List<List<String>> usedVars(DifyFlowNode n) {
    if (n.blockType == 'agent' && !_isAgentV2(n.data)) return const [];
    final List<List<String>> all;
    if (env.usedVars != null) {
      all = env.usedVars!(n);
    } else {
      try {
        all = n.node == null ? const [] : getNodeUsedVars(n.node!);
      } on StateError {
        return const [];
      }
    }
    return [
      for (final v in all)
        if (v.isNotEmpty) v,
    ];
  }

  /// `getCheckData`: knowledge retrieval gets its datasets' details as `_datasets`.
  Map<String, Object?> checkData(DifyFlowNode n) {
    if (n.blockType != 'knowledge-retrieval') return n.data;
    return {
      ...n.data,
      '_datasets': [
        for (final id in jsList(n.data['dataset_ids'])) ?env.datasetsDetail[id],
      ],
    };
  }

  /// `useNodesAvailableVarList` for one node.
  List<NodeOutputVars> availableVars(DifyFlowNode n) {
    if (env.availableVars != null) return env.availableVars!(n);
    final before = getBeforeNodesInSameBranchIncludeParent(n.id, nodes, edges);
    if (n.blockType == 'loop') before.add(n);
    try {
      return toNodeAvailableVars(
        beforeNodes: [for (final b in before) ?b.node],
        parent: byId[n.parentId]?.node,
        chatMode: env.chatMode,
        environmentVariables: DeclaredVar.listOf(env.environmentVariables),
        conversationVariables: env.chatMode ? DeclaredVar.listOf(env.conversationVariables) : const [],
      );
    } on StateError {
      return const [];
    }
  }

  /// Whether one of [usedVars] is neither special nor an output of an available node.
  bool hasInvalidVar(DifyFlowNode n, List<List<String>> usedVars) {
    if (usedVars.every((v) => env.isSpecialVar(v[0]))) return false;
    final available = availableVars(n);
    for (final v in usedVars) {
      if (env.isSpecialVar(v[0])) continue;
      final usedNode = available.firstWhereOrNull((a) => a.nodeId == v[0]);
      if (usedNode == null || !usedNode.vars.any((x) => x.variable == (v.length > 1 ? v[1] : null))) return true;
    }
    return false;
  }

  /// The LLM node's model provider plugin is not installed (`LLMModelIssueCode.providerPluginUnavailable`).
  bool llmProviderUnavailable(DifyFlowNode n) {
    final installed = installedPluginIds;
    if (n.blockType != 'llm' || installed == null) return false;
    final provider = jsStr(
      jsGet(resolveLLMNodeModel(n.data['model'], n.data['model_selector'], env.environmentVariables), 'provider'),
    );
    return provider != null && provider.isNotEmpty && !installed.contains(extractPluginId(provider));
  }

  bool isStartMeta(DifyFlowNode n) => env.nodesMeta[n.blockType]?.isStart ?? false;

  Iterable<String> get requiredTypes => env.nodesMeta.entries.where((e) => e.value.isRequired).map((e) => e.key);

  String blockTitle(String type) => env.t('workflow', 'blocks.$type');
}

// ---- useChecklist ------------------------------------------------------------------------------------------------

/// `useChecklist`'s `needWarningNodes` for [doc].
List<ChecklistItem> computeChecklist(Document doc, ChecklistEnv env) {
  final g = difyGraphOf(doc);
  return computeChecklistOf(g.nodes, g.edges, env);
}

/// `useChecklist`'s `needWarningNodes` for React Flow [nodes] and [edges].
List<ChecklistItem> computeChecklistOf(List<DifyFlowNode> nodes, List<DifyFlowEdge> edges, ChecklistEnv env) {
  final c = _Check(nodes, edges, env);
  final t = env.t;
  final list = <ChecklistItem>[];

  for (final n in c.filtered) {
    final usedVars = c.usedVars(n);
    final validator = _validatorOf(n.data, env);
    final isPluginMissing = isNodePluginMissing(n.data, env);
    final errors = <String>[];
    if (isPluginMissing) {
      errors.add(t('workflow', 'nodes.common.pluginNotInstalled'));
    } else {
      if (c.llmProviderUnavailable(n)) errors.add(t('workflow', 'errorMsg.configureModel'));
      if (validator != null) {
        final e = validator(c.checkData(n), t, c.moreData(n));
        if (e.isNotEmpty) errors.add(e);
      }
      if (c.hasInvalidVar(n, usedVars)) errors.add(t('workflow', 'errorMsg.invalidVariable'));
      errors.addAll(c.duplicates[n.id] ?? const []);
    }

    final canSkipConnectionCheck = !env.shouldCheckStartNode || c.isStartMeta(n) || n.blockType == 'start-placeholder';
    final unConnected = !c.validIds.contains(n.id) && !canSkipConnectionCheck;
    if (errors.isNotEmpty || unConnected) {
      list.add(
        ChecklistItem(
          id: n.id,
          type: n.blockType,
          title: n.title,
          toolIcon: env.toolIcon?.call(n),
          unConnected: unConnected,
          errorMessages: errors,
          canNavigate: !isPluginMissing,
          disableGoTo: isPluginMissing,
          isPluginMissing: isPluginMissing,
          pluginUniqueIdentifier: isPluginMissing ? jsStr(n.data['plugin_unique_identifier']) : null,
        ),
      );
    }
  }

  if (env.shouldCheckStartNode &&
      !nodes.any((n) => _startNodeTypes.contains(n.blockType) || n.blockType == 'start-placeholder')) {
    list.add(
      ChecklistItem(
        id: 'start-node-required',
        type: 'start',
        title: t('workflow', 'panel.startNode'),
        errorMessages: [t('workflow', 'common.needStartNode')],
        canNavigate: false,
      ),
    );
  }

  for (final type in c.requiredTypes) {
    if (c.filtered.any((n) => n.blockType == type)) continue;
    list.add(
      ChecklistItem(
        id: '$type-need-added',
        type: type,
        title: c.blockTitle(type),
        errorMessages: [
          t('workflow', 'common.needAdd', {'node': c.blockTitle(type)}),
        ],
        canNavigate: false,
      ),
    );
  }
  return list;
}

/// `useChecklist`'s effect: stores [items] as the store's `checklistItems` unless they are (deeply) the same.
void syncChecklistItems(WorkflowStore store, List<ChecklistItem> items) {
  final json = [for (final i in items) i.toJson()];
  if (jsonEquals(store.checklistItems.value, json)) return;
  store.checklistItems.value = json;
}

// ---- useChecklistBeforePublish -----------------------------------------------------------------------------------

/// `handleCheckBeforePublish` for [doc]: the error Dify toasts (and refuses to publish with), null when the workflow
/// can be published.
String? checkBeforePublish(Document doc, ChecklistEnv env) {
  final g = difyGraphOf(doc);
  return checkBeforePublishOf(g.nodes, g.edges, env);
}

/// [checkBeforePublish] for React Flow [nodes] and [edges].
String? checkBeforePublishOf(List<DifyFlowNode> nodes, List<DifyFlowEdge> edges, ChecklistEnv env) {
  final c = _Check(nodes, edges, env);
  final t = env.t;
  if (c.tree.maxDepth > maxTreeDepth) return t('workflow', 'common.maxTreeDepth', {'depth': maxTreeDepth});

  for (final n in c.filtered) {
    final usedVars = c.usedVars(n);
    if (c.llmProviderUnavailable(n)) return '[${n.title}] ${t('workflow', 'errorMsg.configureModel')}';
    final validator = _validatorOf(n.data, env);
    if (validator != null) {
      final e = validator(c.checkData(n), t, c.moreData(n));
      if (e.isNotEmpty) return '[${n.title}] $e';
    }
    final duplicates = c.duplicates[n.id] ?? const [];
    if (duplicates.isNotEmpty) return '[${n.title}] ${duplicates.first}';
    if (c.hasInvalidVar(n, usedVars)) return '[${n.title}] ${t('workflow', 'errorMsg.invalidVariable')}';
    final canSkipConnectionCheck = !env.shouldCheckStartNode || c.isStartMeta(n);
    if (!c.validIds.contains(n.id) && !canSkipConnectionCheck) {
      return '[${n.title}] ${t('workflow', 'common.needConnectTip')}';
    }
  }

  if (env.shouldCheckStartNode && !nodes.any((n) => _startNodeTypes.contains(n.blockType))) {
    return t('workflow', 'common.needStartNode');
  }
  for (final type in c.requiredTypes) {
    if (!c.filtered.any((n) => n.blockType == type)) {
      return t('workflow', 'common.needAdd', {'node': c.blockTitle(type)});
    }
  }
  return null;
}

// ---- useWorkflowRunValidation ------------------------------------------------------------------------------------

/// `useWorkflowRunValidation`: the checklist and the check before running.
class WorkflowRunValidation {
  WorkflowRunValidation(this.warningNodes, this._t);

  /// For [doc] (Dify passes the hooks store's `flowType` into [env]).
  factory WorkflowRunValidation.of(Document doc, ChecklistEnv env) =>
      WorkflowRunValidation(computeChecklist(doc, env), env.t);

  final List<ChecklistItem> warningNodes;
  final ChecklistTranslate _t;

  bool get hasValidationErrors => warningNodes.isNotEmpty;

  /// False (after [toastError] with `panel.checklistTip`) when the checklist has items.
  bool validateBeforeRun(void Function(String message) toastError) {
    if (warningNodes.isEmpty) return true;
    toastError(_t('workflow', 'panel.checklistTip'));
    return false;
  }
}
