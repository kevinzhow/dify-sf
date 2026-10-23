/// run/utils/format-log: turns a run's flat node executions (Dify's `NodeTracing` JSON, in execution order) into the
/// tree the tracing panel shows: agent/tool logs as trees, one entry per human-input node, retries under their node,
/// iteration and loop children under their container (one list per run), and parallel branches grouped under their
/// parallel's first node with Dify's "Parallel-1A" / "Branch-1-A" titles.
///
/// The functions work on copies (Dify's `cloneDeep`) and add Dify's view fields to them: `agentLog`, `retryDetail`,
/// `details`, `parallelDetail` (`{isParallelStartNode, parallelTitle, branchTitle, children}`), `hasCircle`.
library;

import '../../../i18n/dify_i18n.dart';
import '../../store/workflow_store.dart' show DifyJson;

/// Dify's `t` for the workflow namespace.
typedef WorkflowTranslate = String Function(String key);

String _defaultTranslate(String key) => DifyI18n.tr('workflow', key);

/// `cloneDeep` of JSON.
Object? deepCopyJson(Object? v) => switch (v) {
  final Map m => <String, Object?>{for (final e in m.entries) '${e.key}': deepCopyJson(e.value)},
  final List l => [for (final x in l) deepCopyJson(x)],
  _ => v,
};

DifyJson _copy(DifyJson v) => deepCopyJson(v)! as DifyJson;

DifyJson? _meta(DifyJson n) => n['execution_metadata'] as DifyJson?;
Object? _metaOf(DifyJson n, String key) => _meta(n)?[key];

/// `a ?? b` over a node field and its execution metadata.
Object? _either(DifyJson n, String key) => n[key] ?? _metaOf(n, key);

// ----- agent/index.ts -----

const _supportedAgentLogNodes = {'agent', 'tool'};

String? _logId(DifyJson item) {
  final id = item['message_id'];
  if (id is String && id.isNotEmpty) return id;
  return item['id'] as String?;
}

List<DifyJson> _children(DifyJson node) => [for (final c in (node['children'] as List? ?? const [])) c as DifyJson];

void _remove(DifyJson node, String removeId) {
  var children = _children(node);
  if (children.isEmpty) return;
  final hasCircle = children.any((c) => _logId(c) == removeId);
  if (hasCircle) {
    node['hasCircle'] = true;
    node['children'] = children = [
      for (final c in children)
        if (_logId(c) != removeId) c,
    ];
  }
  for (final child in children) {
    _remove(child, removeId);
  }
}

List<DifyJson> _removeRepeatedSiblings(List<DifyJson> list) {
  final result = <DifyJson>[];
  final added = <String>{};
  for (final item in list) {
    final id = _logId(item);
    if (id != null && added.add(id)) result.add(item);
  }
  return result;
}

DifyJson _removeCircleLogItem(DifyJson log) {
  final newLog = _copy(log);
  if (_children(newLog).isEmpty) return newLog;
  newLog['children'] = _removeRepeatedSiblings(_children(newLog));
  final id = _logId(newLog);
  var children = _children(newLog);
  if (children.any((c) => _logId(c) == id)) {
    newLog['hasCircle'] = true;
    newLog['children'] = children = [
      for (final c in children)
        if (_logId(c) != id) c,
    ];
  }
  for (var i = 0; i < children.length; i++) {
    if (id != null) _remove(children[i], id);
    children[i] = _removeCircleLogItem(children[i]);
  }
  newLog['children'] = children;
  return newLog;
}

List<DifyJson> _listToTree(List<DifyJson> logs) {
  if (logs.isEmpty) return [];
  final itemsById = <String, DifyJson>{};
  final childrenById = <String, List<DifyJson>>{};
  for (final item in logs) {
    final id = _logId(item);
    if (id != null) {
      itemsById.putIfAbsent(id, () => item);
      childrenById.putIfAbsent(id, () => []);
    }
    final parent = item['parent_id'];
    if (parent is String && parent.isNotEmpty) childrenById.putIfAbsent(parent, () => []).add(item);
  }
  final tree = <DifyJson>[];
  for (final item in itemsById.values) {
    final parent = item['parent_id'];
    if (parent is String && parent.isNotEmpty) continue;
    final children = childrenById[_logId(item)];
    if (children != null && children.isNotEmpty) item['children'] = children;
    tree.add(item);
  }
  for (final item in itemsById.values) {
    final children = childrenById[_logId(item)];
    if (children != null && children.isNotEmpty) item['children'] = children;
  }
  return tree;
}

/// agent/index.ts: an agent's or tool's `execution_metadata.agent_log` as a tree (`agentLog`), circles removed.
List<DifyJson> formatAgentNode(List<DifyJson> list) => [
  for (final item in list)
    item
      ..['agentLog'] = () {
        final logs = _metaOf(item, 'agent_log');
        if (!_supportedAgentLogNodes.contains(item['node_type']) || logs is! List || logs.isEmpty) {
          return <DifyJson>[];
        }
        return [
          for (final t in _listToTree([for (final l in logs) l as DifyJson])) _removeCircleLogItem(t),
        ];
      }(),
];

// ----- human-input/index.ts -----

/// human-input/index.ts: only the latest (highest `index`) entry of each human-input node, where its first entry was.
List<DifyJson> formatHumanInputNode(List<DifyJson> list) {
  final latest = <String, DifyJson>{};
  for (final item in list) {
    if (item['node_type'] != 'human-input') continue;
    final id = '${item['node_id']}';
    final existing = latest[id];
    if (existing == null || _num(item['index']) > _num(existing['index'])) latest[id] = item;
  }
  if (latest.isEmpty) return list;
  final added = <String>{};
  return [
    for (final item in list)
      if (item['node_type'] != 'human-input')
        item
      else if (added.add('${item['node_id']}'))
        latest['${item['node_id']}']!,
  ];
}

num _num(Object? v) => v is num ? v : 0;

// ----- retry/index.ts -----

/// retry/index.ts: `retry` entries leave the list and become their node's `retryDetail` (matched by iteration or loop
/// index inside containers).
List<DifyJson> formatRetryNode(List<DifyJson> list) {
  final retryNodes = [
    for (final item in list)
      if (item['status'] == 'retry') item,
  ];
  final retryNodeIds = {for (final n in retryNodes) n['node_id']};
  return [
    for (final item in list)
      if (item['status'] != 'retry')
        if (!retryNodeIds.contains(item['node_id']))
          item
        else
          {
            ...item,
            'retryDetail': [
              for (final node in retryNodes)
                if (_retryBelongs(item, node)) node,
            ],
          },
  ];
}

bool _retryBelongs(DifyJson item, DifyJson node) {
  if (node['node_id'] != item['node_id']) return false;
  final inIteration = _truthy(_metaOf(item, 'iteration_id'));
  final inLoop = _truthy(_metaOf(item, 'loop_id'));
  if (!inIteration && !inLoop) return true;
  if (inIteration) return _metaOf(node, 'iteration_index') == _metaOf(item, 'iteration_index');
  return _metaOf(node, 'loop_index') == _metaOf(item, 'loop_index');
}

bool _truthy(Object? v) => v != null && v != '' && v != false && v != 0;

// ----- iteration/index.ts, loop/index.ts -----

/// iteration/index.ts: the children grouped per run by `iteration_index` (a child without one stays in the current run
/// unless its node already ran there) as `details`.
DifyJson addChildrenToIterationNode(DifyJson iterationNode, List<DifyJson> childrenNodes) {
  final details = <List<DifyJson>>[];
  var lastResolvedIndex = -1;
  for (final item in childrenNodes) {
    if (_meta(item) == null) continue;
    final iterationIndex = _metaOf(item, 'iteration_index');
    final int runIndex;
    if (iterationIndex is num) {
      runIndex = iterationIndex.toInt();
    } else if (lastResolvedIndex >= 0) {
      final current = lastResolvedIndex < details.length ? details[lastResolvedIndex] : const <DifyJson>[];
      runIndex = current.any((n) => n['node_id'] == item['node_id']) ? lastResolvedIndex + 1 : lastResolvedIndex;
    } else {
      runIndex = 0;
    }
    while (details.length <= runIndex) {
      details.add([]);
    }
    details[runIndex].add(item);
    lastResolvedIndex = runIndex;
  }
  return {...iterationNode, 'details': details};
}

/// loop/index.ts: like iterations, grouped by `parallel_mode_run_id` first, then `loop_index`, in first-seen order.
DifyJson addChildrenToLoopNode(DifyJson loopNode, List<DifyJson> childrenNodes) {
  final groups = <String, List<DifyJson>>{};
  var lastResolvedIndex = -1;
  for (final item in childrenNodes) {
    if (_meta(item) == null) continue;
    final parallelRunId = _metaOf(item, 'parallel_mode_run_id');
    final loopIndex = _metaOf(item, 'loop_index');
    final Object runIndex;
    if (parallelRunId != null) {
      runIndex = '$parallelRunId';
    } else if (loopIndex is num) {
      runIndex = loopIndex.toInt();
    } else if (lastResolvedIndex >= 0) {
      final current = groups['$lastResolvedIndex'] ?? const <DifyJson>[];
      runIndex = current.any((n) => n['node_id'] == item['node_id']) ? lastResolvedIndex + 1 : lastResolvedIndex;
    } else {
      runIndex = 0;
    }
    groups.putIfAbsent('$runIndex', () => []).add(item);
    if (runIndex is int) lastResolvedIndex = runIndex;
  }
  return {...loopNode, 'details': groups.values.toList()};
}

// ----- parallel/index.ts -----

DifyJson? _parallelDetail(DifyJson n) => n['parallelDetail'] as DifyJson?;
List<DifyJson>? _parallelChildren(DifyJson n) => (_parallelDetail(n)?['children'] as List?)?.cast<DifyJson>();

void _addTitle(List<DifyJson> list, int depth, String? belongParallelIndexInfo, WorkflowTranslate t) {
  var branchIndex = 0;
  final starts = [
    for (final n in list)
      if (_parallelDetail(n)?['isParallelStartNode'] == true) n,
  ];
  final hasMoreThanOneParallel = starts.length > 1;
  for (final node in list) {
    final parallelId = _either(node, 'parallel_id');
    final parallelStartNodeId = _either(node, 'parallel_start_node_id');
    if (parallelId == null || node['node_type'] == 'end') continue;
    final isParallelStartNode = _parallelDetail(node)?['isParallelStartNode'] == true;
    var letter = '';
    if (isParallelStartNode && hasMoreThanOneParallel) {
      final index = 1 + starts.indexWhere((item) => item['node_id'] == node['node_id']);
      letter = String.fromCharCode(64 + index);
    }
    final parallelIndexInfo = '$depth$letter';
    if (isParallelStartNode) {
      _parallelDetail(node)!
        ..['isParallelStartNode'] = true
        ..['parallelTitle'] = '${t('common.parallel')}-$parallelIndexInfo';
    }
    if (parallelStartNodeId == node['node_id']) {
      branchIndex++;
      final branchLetter = String.fromCharCode(64 + branchIndex);
      final detail = (node['parallelDetail'] ??= <String, Object?>{'branchTitle': ''}) as DifyJson;
      detail['branchTitle'] = '${t('common.branch')}-$belongParallelIndexInfo-$branchLetter';
    }
    final children = _parallelChildren(node);
    if (children != null && children.isNotEmpty) _addTitle(children, depth + 1, parallelIndexInfo, t);
  }
}

int _findLastIndex(List<DifyJson> list, bool Function(DifyJson) test) {
  for (var i = list.length - 1; i >= 0; i--) {
    if (test(list[i])) return i;
  }
  return -1;
}

/// parallel/index.ts: the nodes of a parallel nested under its first node (`parallelDetail.children`, branch after
/// branch, nested parallels under their parent's), titled.
List<DifyJson> formatParallelNode(List<DifyJson> list, [WorkflowTranslate? translate]) {
  final t = translate ?? _defaultTranslate;
  final result = [...list];
  for (final node in result) {
    final parallelId = _either(node, 'parallel_id');
    final parallelStartNodeId = _either(node, 'parallel_start_node_id');
    final parentParallelId = _either(node, 'parent_parallel_id');
    final branchStartNodeId = parallelStartNodeId;
    final parentBranchStartNodeId = _either(node, 'parent_parallel_start_node_id');
    if (parallelId == null || node['node_type'] == 'end') continue;

    if (parallelStartNodeId == node['node_id']) {
      final self = {...node, 'parallelDetail': null}..remove('parallelDetail');
      node['parallelDetail'] = <String, Object?>{
        'isParallelStartNode': true,
        'children': <DifyJson>[self],
      };
      if (parentParallelId == null) continue;
      DifyJson? parent;
      for (final item in result) {
        if (item['node_id'] == parentBranchStartNodeId) {
          parent = item;
          break;
        }
      }
      if (parent != null) {
        parent['parallelDetail'] ??= <String, Object?>{'children': <DifyJson>[]};
        final children = _parallelChildren(parent);
        if (children != null) {
          final i = _findLastIndex(children, (n) => _either(n, 'parallel_start_node_id') == parentBranchStartNodeId);
          final list = [...children];
          if (i != -1) {
            list.insert(i + 1, node);
          } else {
            list.add(node);
          }
          _parallelDetail(parent)!['children'] = list;
        }
      }
      continue;
    }

    DifyJson? start;
    for (final item in result) {
      if (parallelStartNodeId == item['node_id']) {
        start = item;
        break;
      }
    }
    final children = start == null ? null : _parallelChildren(start);
    if (start != null && children != null) {
      final i = _findLastIndex(children, (n) => _either(n, 'parallel_start_node_id') == branchStartNodeId);
      final list = [...children];
      if (i != -1) {
        list.insert(i + 1, node);
      } else {
        list.add(node);
      }
      _parallelDetail(start)!['children'] = list;
    }
  }
  final filtered = [
    for (final node in result)
      if (_either(node, 'parallel_id') == null || node['node_type'] == 'end')
        node
      else if (_either(node, 'parent_parallel_id') == null && _parallelDetail(node)?['isParallelStartNode'] == true)
        node,
  ];
  _addTitle(filtered, 1, null, t);
  return filtered;
}

// ----- index.ts -----

/// The stages of [formatToTracingNodeList] (Dify's modules; tests replace them as Dify's tests mock the modules).
class FormatLogPipeline {
  const FormatLogPipeline({
    this.agent = formatAgentNode,
    this.humanInput = formatHumanInputNode,
    this.retry = formatRetryNode,
    this.loop = addChildrenToLoopNode,
    this.iteration = addChildrenToIterationNode,
    this.parallel = formatParallelNode,
  });

  final List<DifyJson> Function(List<DifyJson>) agent, humanInput, retry;
  final DifyJson Function(DifyJson node, List<DifyJson> children) loop, iteration;
  final List<DifyJson> Function(List<DifyJson>, [WorkflowTranslate? t]) parallel;
}

List<DifyJson> _formatIterationAndLoopNode(List<DifyJson> list, WorkflowTranslate t, FormatLogPipeline p) {
  final cloned = [for (final n in list) _copy(n)];
  final loopNodeIds = {
    for (final item in cloned)
      if (item['node_type'] == 'loop') item['node_id'],
  };
  final iterationNodeIds = {
    for (final item in cloned)
      if (item['node_type'] == 'iteration') item['node_id'],
  };
  final loopChildren = {
    for (final item in cloned)
      if (_truthy(_metaOf(item, 'loop_id')) && loopNodeIds.contains(_metaOf(item, 'loop_id'))) item['node_id'],
  };
  final iterationChildren = {
    for (final item in cloned)
      if (_truthy(_metaOf(item, 'iteration_id')) && iterationNodeIds.contains(_metaOf(item, 'iteration_id')))
        item['node_id'],
  };
  DifyJson container(DifyJson item, String idKey, DifyJson Function(DifyJson, List<DifyJson>) add) {
    final children = [
      for (final child in cloned)
        if (_metaOf(child, idKey) == item['node_id']) child,
    ];
    for (final child in children) {
      if (child['status'] == 'failed') {
        item
          ..['status'] = 'failed'
          ..['error'] = child['error'];
        break;
      }
    }
    final added = add(item, children);
    final details = added['details'];
    if (details is List && details.isNotEmpty) {
      added['details'] = [for (final row in details) p.parallel((row as List).cast<DifyJson>(), t)];
    }
    return added;
  }

  return [
    for (final item in cloned)
      if (!loopChildren.contains(item['node_id']) && !iterationChildren.contains(item['node_id']))
        switch (item['node_type']) {
          'loop' => container(item, 'loop_id', p.loop),
          'iteration' => container(item, 'iteration_id', p.iteration),
          _ => item,
        },
  ];
}

/// index.ts formatToTracingNodeList: sorted by `index`, then agent logs, human inputs, retries, iterations and loops,
/// and parallels.
List<DifyJson> formatToTracingNodeList(
  List<DifyJson> list, [
  WorkflowTranslate? translate,
  FormatLogPipeline pipeline = const FormatLogPipeline(),
]) {
  final t = translate ?? _defaultTranslate;
  // JavaScript's sort is stable: equal indexes keep their order.
  final indexed = [for (final (i, n) in list.indexed) (i, _copy(n))]
    ..sort((a, b) {
      final c = _num(a.$2['index']).compareTo(_num(b.$2['index']));
      return c != 0 ? c : a.$1.compareTo(b.$1);
    });
  final all = [for (final (_, n) in indexed) n];
  final agent = pipeline.agent(all);
  final human = pipeline.humanInput(agent);
  final retry = pipeline.retry(human);
  final containers = _formatIterationAndLoopNode(retry, t, pipeline);
  return pipeline.parallel(containers, t);
}
