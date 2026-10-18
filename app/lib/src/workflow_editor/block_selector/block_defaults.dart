/// What a new node of each block type starts as, and which blocks the app offers where (Dify 1.17.1): each node's
/// `default.ts` (`metaData` and `defaultValue`), workflow-app's use-available-nodes-meta-data.ts, the block
/// selector's node filtering (hooks/use-available-blocks.ts) and the node factory of utils/node.ts.
library;

import '../../i18n/dify_i18n.dart';
import '../store/workflow_store.dart' show DifyJson;

/// block-selector/types.ts BlockClassification, in the order the Nodes tab lists them (BLOCK_CLASSIFICATIONS).
abstract final class BlockClassification {
  static const defaultGroup = '-';
  static const questionUnderstand = 'question-understand';
  static const logic = 'logic';
  static const transform = 'transform';
  static const utilities = 'utilities';
  static const all = [defaultGroup, questionUnderstand, logic, transform, utilities];
}

/// A block as the selector lists it (NodeDefault's `metaData`, titled and described in the current language).
class BlockMeta {
  const BlockMeta({
    required this.type,
    this.classification = BlockClassification.defaultGroup,
    this.sort = 0,
    this.title = '',
    this.description = '',
  });

  final String type;
  final String classification;
  final num sort;
  final String title;
  final String description;
}

typedef _Default = ({String classification, num sort, DifyJson Function() value});

DifyJson _model() => {
  'provider': '',
  'name': '',
  'mode': 'chat',
  'completion_params': {'temperature': 0.7},
};

const _d = BlockClassification.defaultGroup, _l = BlockClassification.logic, _t = BlockClassification.transform;

/// Each block's genNodeMetaData classification and sort, and its `defaultValue` (fresh on every call).
final Map<String, _Default> _defaults = {
  'llm': (
    classification: _d,
    sort: 1,
    value: () => {
      'model': _model(),
      'prompt_template': [
        {'role': 'system', 'text': ''},
      ],
      'context': {'enabled': false, 'variable_selector': <Object?>[]},
      'vision': {'enabled': false},
    },
  ),
  'knowledge-retrieval': (
    classification: _d,
    sort: 2,
    value: () => {
      'query_variable_selector': <Object?>[],
      'query_attachment_selector': <Object?>[],
      'dataset_ids': <Object?>[],
      'retrieval_mode': 'multiple',
      // `score_threshold: undefined` is dropped by JSON.
      'multiple_retrieval_config': {'top_k': 4, 'reranking_enable': false},
    },
  ),
  'agent': (classification: _d, sort: 3, value: () => {'tool_node_version': '2'}),
  'agent-v2': (
    classification: _d,
    sort: 3,
    value: () => {
      'agent_binding': {'binding_type': 'inline_agent'},
      'agent_node_kind': 'dify_agent',
      'version': '2',
    },
  ),
  'question-classifier': (
    classification: BlockClassification.questionUnderstand,
    sort: 1,
    value: () => {
      'query_variable_selector': <Object?>[],
      'model': _model(),
      'classes': [
        {'id': '1', 'name': '', 'label': 'CLASS 1'},
        {'id': '2', 'name': '', 'label': 'CLASS 2'},
      ],
      '_targetBranches': [
        {'id': '1', 'name': ''},
        {'id': '2', 'name': ''},
      ],
      'vision': {'enabled': false},
    },
  ),
  'if-else': (
    classification: _l,
    sort: 1,
    value: () => {
      '_targetBranches': [
        {'id': 'true', 'name': 'IF'},
        {'id': 'false', 'name': 'ELSE'},
      ],
      'cases': [
        {'case_id': 'true', 'logical_operator': 'and', 'conditions': <Object?>[]},
      ],
    },
  ),
  'iteration': (
    classification: _l,
    sort: 2,
    value: () => {
      'start_node_id': '',
      'iterator_selector': <Object?>[],
      'output_selector': <Object?>[],
      '_children': <Object?>[],
      '_isShowTips': false,
      'is_parallel': false,
      'parallel_nums': 10,
      'error_handle_mode': 'terminated',
      'flatten_output': true,
    },
  ),
  'iteration-start': (classification: _d, sort: -1, value: () => {}),
  'loop': (
    classification: _l,
    sort: 3,
    value: () => {
      'start_node_id': '',
      'break_conditions': <Object?>[],
      'loop_count': 10,
      '_children': <Object?>[],
      'logical_operator': 'and',
    },
  ),
  'loop-start': (classification: _d, sort: -1, value: () => {}),
  'loop-end': (classification: _l, sort: 2, value: () => {}),
  'code': (
    classification: _t,
    sort: 1,
    value: () => {'code': '', 'code_language': 'python3', 'variables': <Object?>[], 'outputs': <String, Object?>{}},
  ),
  'template-transform': (classification: _t, sort: 2, value: () => {'template': '', 'variables': <Object?>[]}),
  'variable-aggregator': (classification: _t, sort: 3, value: () => {'output_type': 'any', 'variables': <Object?>[]}),
  'document-extractor': (
    classification: _t,
    sort: 4,
    value: () => {'variable_selector': <Object?>[], 'is_array_file': false},
  ),
  'assigner': (classification: _t, sort: 5, value: () => {'version': '2', 'items': <Object?>[]}),
  'parameter-extractor': (
    classification: _t,
    sort: 6,
    value: () => {
      'query': <Object?>[],
      'model': _model(),
      'reasoning_mode': 'prompt',
      'vision': {'enabled': false},
    },
  ),
  'http-request': (
    classification: BlockClassification.utilities,
    sort: 1,
    value: () => {
      'variables': <Object?>[],
      'method': 'get',
      'url': '',
      'authorization': {'type': 'no-auth', 'config': null},
      'headers': '',
      'params': '',
      'body': {'type': 'none', 'data': <Object?>[]},
      'ssl_verify': true,
      'timeout': {'max_connect_timeout': 0, 'max_read_timeout': 0, 'max_write_timeout': 0},
      'retry_config': {'retry_enabled': true, 'max_retries': 3, 'retry_interval': 100},
    },
  ),
  'list-operator': (
    classification: BlockClassification.utilities,
    sort: 2,
    value: () => {
      'variable': <Object?>[],
      'filter_by': {'enabled': false, 'conditions': <Object?>[]},
      'extract_by': {'enabled': false, 'serial': '1'},
      'order_by': {'enabled': false, 'key': '', 'value': 'asc'},
      'limit': {'enabled': false, 'size': 10},
    },
  ),
  'tool': (
    classification: _d,
    sort: -1,
    value: () => {
      'tool_parameters': <String, Object?>{},
      'tool_configurations': <String, Object?>{},
      'tool_node_version': '2',
    },
  ),
  'human-input': (
    classification: _l,
    sort: 1,
    value: () => {
      'delivery_methods': <Object?>[],
      'user_actions': <Object?>[],
      'form_content': '',
      'inputs': <Object?>[],
      'timeout': 3,
      'timeout_unit': 'day',
    },
  ),
  'start': (classification: _d, sort: 0.1, value: () => {'variables': <Object?>[]}),
  'answer': (classification: _d, sort: 2.1, value: () => {'variables': <Object?>[], 'answer': ''}),
  'start-placeholder': (classification: _d, sort: 0.05, value: () => {'title': 'Workflow start', 'desc': ''}),
  'end': (classification: _d, sort: 2.1, value: () => {'outputs': <Object?>[]}),
  'trigger-webhook': (
    classification: _d,
    sort: 3,
    value: () => {
      'webhook_url': '',
      'method': 'POST',
      'content_type': 'application/json',
      'headers': <Object?>[],
      'params': <Object?>[],
      'body': <Object?>[],
      'async_mode': true,
      'status_code': 200,
      'response_body': '',
      'variables': [
        {
          'variable': '_webhook_raw',
          'label': 'raw',
          'value_type': 'object',
          'value_selector': <Object?>[],
          'required': true,
        },
      ],
    },
  ),
  'trigger-schedule': (
    classification: _d,
    sort: 2,
    value: () => {
      'mode': 'visual',
      'frequency': 'daily',
      'visual_config': {
        'time': '12:00 AM',
        'weekdays': ['sun'],
        'on_minute': 0,
        'monthly_days': [1],
      },
      'cron_expression': '',
    },
  ),
  'trigger-plugin': (
    classification: _d,
    sort: 1,
    value: () => {
      'plugin_id': '',
      'event_name': '',
      'event_parameters': <String, Object?>{},
      'config': <String, Object?>{},
    },
  ),
  // RAG pipeline blocks (rag-pipeline's use-available-nodes-meta-data.ts offers them).
  'datasource': (
    classification: _d,
    sort: -1,
    value: () => {'datasource_parameters': <String, Object?>{}, 'datasource_configurations': <String, Object?>{}},
  ),
  'knowledge-index': (
    classification: _d,
    sort: 3.1,
    value: () => {
      'index_chunk_variable_selector': <Object?>[],
      'keyword_number': 10,
      'retrieval_model': {'top_k': 3, 'score_threshold_enabled': false, 'score_threshold': 0.5},
    },
  ),
};

/// constants/node.ts WORKFLOW_COMMON_NODES.
const _commonNodes = [
  'llm', 'knowledge-retrieval', 'agent', 'agent-v2', 'question-classifier', 'if-else', 'iteration', //
  'iteration-start', 'loop', 'loop-start', 'loop-end', 'code', 'template-transform', 'variable-aggregator',
  'document-extractor', 'assigner', 'parameter-extractor', 'http-request', 'list-operator', 'tool', 'human-input',
];

/// The block types a workflow (or, with [chatMode], a chatflow) offers, in Dify's order (useAvailableNodesMetaData
/// `nodes`): the common nodes, Start, then Answer in a chatflow or the start placeholder, End and the triggers in a
/// workflow; Agent v2 replaces the classic Agent when [agentV2] (NEXT_PUBLIC_ENABLE_AGENT_V2, and
/// NEXT_PUBLIC_ENABLE_AGENT_V2_IN_CHATFLOW for a chatflow) is on.
List<String> availableNodeTypes({bool chatMode = false, bool agentV2 = false}) => [
  for (final t in [
    ..._commonNodes,
    'start',
    ...chatMode ? ['answer'] : ['start-placeholder', 'end', 'trigger-webhook', 'trigger-schedule', 'trigger-plugin'],
  ])
    if (t != (agentV2 ? 'agent' : 'agent-v2')) t,
];

/// The blocks of [availableNodeTypes] with their titles (`blocks.<type>`) and descriptions (`blocksAbout.<type>`).
List<BlockMeta> availableBlocks({bool chatMode = false, bool agentV2 = false}) => [
  for (final t in availableNodeTypes(chatMode: chatMode, agentV2: agentV2))
    BlockMeta(
      type: t,
      classification: _defaults[t]!.classification,
      sort: _defaults[t]!.sort,
      title: DifyI18n.tr('workflow', 'blocks.$t'),
      description: DifyI18n.tr('workflow', 'blocksAbout.$t'),
    ),
];

/// The `data` a new node of [type] starts with (nodesMetaDataMap[type].defaultValue: the block's `defaultValue`
/// with its `type`, Agent v2 being an `agent` node, and its title `blocks.<type>`); null for a block the workflow
/// (or chatflow) does not offer. `variable-assigner` is the aggregator, as Dify maps it; the RAG pipeline's
/// `datasource` and `knowledge-index` are always available here.
DifyJson? blockDefaults(String type, {bool chatMode = false}) {
  final key = type == 'variable-assigner' ? 'variable-aggregator' : type;
  final d = _defaults[key];
  // nodesMetaDataMap holds both agents whatever the flag.
  final offered =
      const {'datasource', 'knowledge-index', 'agent', 'agent-v2'}.contains(key) ||
      availableNodeTypes(chatMode: chatMode).contains(key);
  if (d == null || !offered) return null;
  return {...d.value(), 'type': key == 'agent-v2' ? 'agent' : key, 'title': DifyI18n.tr('workflow', 'blocks.$key')};
}

// ---- use-available-blocks.ts ----------------------------------------------------------------------------------

bool _availableBlocksFilter(String type, bool inContainer) {
  if (type == 'start-placeholder') return false;
  if (inContainer && const {'iteration', 'loop', 'end', 'datasource', 'knowledge-index'}.contains(type)) return false;
  if (!inContainer && type == 'loop-end') return false;
  return true;
}

/// useAvailableBlocks' `getAvailableBlocks`: the blocks that may come before and after a node of [nodeType] among
/// [availableTypes] (the app's [availableNodeTypes]), without the ones a container ([inContainer]: inside an
/// iteration or loop) or the top level does not allow. No type means neither.
({List<String> prev, List<String> next}) getAvailableBlocks(
  String? nodeType, {
  required List<String> availableTypes,
  bool inContainer = false,
}) {
  final noPrev = nodeType == null || const {'start', 'start-placeholder', 'datasource'}.contains(nodeType);
  final noNext = nodeType == null || const {'start-placeholder', 'loop-end', 'knowledge-index'}.contains(nodeType);
  List<String> keep(bool none) => none
      ? []
      : [
          for (final t in availableTypes)
            if (_availableBlocksFilter(t, inContainer)) t,
        ];
  return (prev: keep(noPrev), next: keep(noNext));
}

/// useAvailableBlocks(nodeType, inContainer): as [getAvailableBlocks], but trigger nodes take nothing before them.
({List<String> prev, List<String> next}) useAvailableBlocks(
  String? nodeType, {
  required List<String> availableTypes,
  bool inContainer = false,
}) {
  final r = getAvailableBlocks(nodeType, availableTypes: availableTypes, inContainer: inContainer);
  final trigger = nodeType != null && nodeType.startsWith('trigger-');
  return (prev: trigger ? <String>[] : r.prev, next: r.next);
}

// ---- utils/node.ts ----------------------------------------------------------------------------------------------

/// getNodesWithSameDefaultDataType: the nodes (their `data`) a new [type] node's title counts against. Agent v2
/// nodes are `agent` nodes told apart by `agent_node_kind` and `version`.
Iterable<DifyJson> nodesWithSameDefaultDataType(Iterable<DifyJson> nodesData, String type, DifyJson defaults) {
  final dataType = (defaults['type'] as String?) ?? type;
  final discriminators = [
    for (final k in const ['agent_node_kind', 'version'])
      if (defaults[k] != null) (k, defaults[k]),
  ];
  if (dataType != type && discriminators.isNotEmpty) {
    return nodesData.where((d) => d['type'] == dataType && discriminators.every((e) => d[e.$1] == e.$2));
  }
  return nodesData.where((d) => d['type'] == type);
}

/// The `data` of a new [type] node as handleNodeAdd and the Add Node button build it: [defaults] (from
/// [blockDefaults]), its title numbered after the nodes of the same type already in [existing] ("LLM 2"), then the
/// selector's [toolDefaultValue] (a tool's, trigger's or data source's provider fields, or an Agent v2 binding).
DifyJson newNodeData(
  String type,
  DifyJson defaults, {
  DifyJson? toolDefaultValue,
  Iterable<DifyJson> existing = const [],
}) {
  final same = nodesWithSameDefaultDataType(existing, type, defaults).length;
  final title = defaults['title'] as String? ?? '';
  return {...defaults, 'title': same > 0 ? '$title ${same + 1}' : title, ...?toolDefaultValue};
}

/// React Flow's node type of a document node of block [type] (getNodeCustomTypeByNodeDataType; `custom` otherwise).
String nodeCustomTypeOf(String type) => switch (type) {
  'loop-end' => 'custom-simple',
  'iteration-start' => 'custom-iteration-start',
  'loop-start' => 'custom-loop-start',
  _ => 'custom',
};

/// generateNewNode: a Dify node (`{id, type, data, position, targetPosition, sourcePosition, ...}`); an iteration or
/// loop gets its start node, which is returned as [start] and recorded in its `start_node_id` and `_children`. The id
/// defaults to `Date.now()`.
({DifyJson node, DifyJson? start}) generateNewNode({
  required DifyJson data,
  required ({double x, double y}) position,
  String? id,
  String? type,
}) {
  final nodeId = id ?? '${DateTime.now().millisecondsSinceEpoch}';
  final kind = data['type'];
  final node = <String, Object?>{
    'id': nodeId,
    'type': type ?? 'custom',
    'data': {...data},
    'position': {'x': position.x, 'y': position.y},
    'targetPosition': 'left',
    'sourcePosition': 'right',
    if (kind == 'iteration' || kind == 'loop') 'zIndex': 0,
  };
  if (kind != 'iteration' && kind != 'loop') return (node: node, start: null);
  final start = kind == 'iteration' ? iterationStartNode(nodeId) : loopStartNode(nodeId);
  (node['data']! as DifyJson)
    ..['start_node_id'] = start['id']
    ..['_children'] = [
      {'nodeId': start['id'], 'nodeType': kind == 'iteration' ? 'iteration-start' : 'loop-start'},
    ];
  return (node: node, start: start);
}

/// NESTED_ELEMENT_Z_INDEX (constants.ts).
const nestedElementZIndex = 1001;

DifyJson _startNode(String parentId, bool iteration) => {
  'id': '${parentId}start',
  'type': iteration ? 'custom-iteration-start' : 'custom-loop-start',
  'data': {
    'title': '',
    'desc': '',
    'type': iteration ? 'iteration-start' : 'loop-start',
    iteration ? 'isInIteration' : 'isInLoop': true,
  },
  'position': {'x': 24, 'y': 68},
  'targetPosition': 'left',
  'sourcePosition': 'right',
  'zIndex': nestedElementZIndex,
  'parentId': parentId,
  'selectable': false,
  'draggable': false,
};

/// getIterationStartNode.
DifyJson iterationStartNode(String iterationId) => _startNode(iterationId, true);

/// getLoopStartNode.
DifyJson loopStartNode(String loopId) => _startNode(loopId, false);
