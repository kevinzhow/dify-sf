/// Dify 1.17.1's run event handlers (workflow/hooks/use-workflow-run-event/*.ts, `useWorkflowRunEvent`): each event
/// of a draft run updates the store's `workflowRunningData` and the nodes' and edges' run fields, which in dify-sf
/// are the store's local view state ([WorkflowStore.nodeRunData] / [WorkflowStore.edgeRunData]), never document
/// ops. Ported one handler per Dify hook, quirks included (noted where they show).
library;

import '../../canvas/agent_progress_view.dart';
import '../store/workflow_store.dart';
import '../variable_inspect/value_content_helpers.dart' show getProcessedFilesFromResponse;
import 'run_events.dart';
import 'run_graph.dart';
import 'run_types.dart';

/// The workflow container's size (`document.getElementById('workflow-container')` clientWidth / clientHeight).
typedef RunContainerSize = ({double clientWidth, double clientHeight});

/// `useWorkflowRunEvent`: the handlers, bound to one editor's store, graph and viewport.
class WorkflowRunEvents {
  WorkflowRunEvents({required this.store, required this.graph, this.viewport});

  final WorkflowStore store;
  final RunGraph graph;

  /// Where `node_started` centres the node; null: the view stays.
  final RunViewport? viewport;

  DifyJson get _data => jsonCopy(store.workflowRunningData.value ?? <String, Object?>{});

  void _set(DifyJson data) => store.setWorkflowRunningData(data);

  /// The draft's `tracing` as a list of JSON objects (made one when it is not yet).
  List<DifyJson> _tracing(DifyJson draft) {
    final t = draft['tracing'];
    if (t is List<DifyJson>) return t;
    final list = <DifyJson>[for (final x in (t as List?) ?? const []) (x as Map).cast<String, Object?>()];
    draft['tracing'] = list;
    return list;
  }

  static Map<String, Object?> _map(Object? v) => v is Map ? v.cast<String, Object?>() : <String, Object?>{};

  /// Sets the run fields of several nodes at once (one store write).
  void _patchNodes(Map<String, DifyJson> patches) {
    if (patches.isEmpty) return;
    final next = {...store.nodeRunData.value};
    patches.forEach((id, patch) {
      final m = {...?next[id], ...patch}..removeWhere((_, v) => v == null);
      next[id] = m;
    });
    store.nodeRunData.value = next;
  }

  void _patchEdges(Map<String, DifyJson> patches) {
    if (patches.isEmpty) return;
    final next = {...store.edgeRunData.value};
    patches.forEach((id, patch) {
      final m = {...?next[id], ...patch}..removeWhere((_, v) => v == null);
      next[id] = m;
    });
    store.edgeRunData.value = next;
  }

  DifyJson _nodeData(String id) => store.nodeRunDataOf(id);

  /// use-workflow-started.ts.
  void handleWorkflowStarted(WorkflowStartedEvent params) {
    final running = store.workflowRunningData.value;
    if (resultOf(running)['status'] == WorkflowRunningStatus.paused) {
      final draft = _data;
      draft['result'] = {..._map(draft['result']), 'status': WorkflowRunningStatus.running};
      _set(draft);
      return;
    }
    store.setIterParallelLogMap({});
    final draft = _data;
    draft['task_id'] = params.taskId;
    draft['result'] = {..._map(draft['result']), ...params.data, 'status': WorkflowRunningStatus.running};
    draft['resultText'] = '';
    draft.remove('resultTextSelectorKey');
    _set(draft);
    _patchNodes({
      for (final n in graph.nodes) n.id: {'_waitingRun': true, '_runningBranchId': null},
    });
    _patchEdges({
      for (final e in graph.edges)
        e.id: {'_sourceRunningStatus': null, '_targetRunningStatus': null, '_waitingRun': true},
    });
  }

  /// use-workflow-finished.ts.
  void handleWorkflowFinished(WorkflowFinishedEvent params) {
    final data = params.data;
    final outputs = data['outputs'];
    final isStringOutput = outputs is Map && outputs.length == 1 && outputs.values.first is String;
    final draft = _data;
    draft['result'] = {..._map(draft['result']), ...data, 'files': getFilesInLogs(outputs)};
    if (isStringOutput) {
      draft['resultTabActive'] = true;
      draft['resultText'] = outputs.values.first;
    }
    _set(draft);
  }

  /// use-workflow-failed.ts.
  void handleWorkflowFailed([String? error]) {
    final running = store.workflowRunningData.value;
    if (running == null) return;
    final status = resultOf(running)['status'];
    if (status == WorkflowRunningStatus.succeeded || status == WorkflowRunningStatus.stopped) return;
    if (status == WorkflowRunningStatus.failed) {
      if (error == null || error.isEmpty || _truthy(resultOf(running)['error'])) return;
      final draft = _data;
      draft['result'] = {..._map(draft['result']), 'error': error};
      _set(draft);
      return;
    }
    final draft = _data;
    draft['result'] = {..._map(draft['result']), 'status': WorkflowRunningStatus.failed, 'error': error};
    for (final trace in _tracing(draft)) {
      if (trace['status'] == NodeRunningStatus.running) trace['status'] = NodeRunningStatus.failed;
    }
    _set(draft);
    _patchNodes({
      for (final n in graph.nodes)
        n.id: {
          if (_nodeData(n.id)['_runningStatus'] == NodeRunningStatus.running)
            '_runningStatus': NodeRunningStatus.failed,
          '_waitingRun': false,
        },
    });
    _patchEdges({
      for (final e in graph.edges)
        e.id: {
          if (store.edgeRunDataOf(e.id)['_sourceRunningStatus'] == NodeRunningStatus.running)
            '_sourceRunningStatus': NodeRunningStatus.failed,
          if (store.edgeRunDataOf(e.id)['_targetRunningStatus'] == NodeRunningStatus.running)
            '_targetRunningStatus': NodeRunningStatus.failed,
          '_waitingRun': false,
        },
    });
  }

  /// Centres a top-level node in the canvas left of the 400 px run panel (node-started, iteration/loop started).
  void _centre(RunGraphNode node, RunContainerSize container) {
    final v = viewport;
    if (v == null || node.parentId != null) return;
    final zoom = v.zoom;
    v.setViewport(
      (container.clientWidth - 400 - node.width * zoom) / 2 - node.x * zoom,
      (container.clientHeight - node.height * zoom) / 2 - node.y * zoom,
      zoom,
    );
  }

  RunGraphNode? _node(String? id) {
    for (final n in graph.nodes) {
      if (n.id == id) return n;
    }
    return null;
  }

  /// use-workflow-node-started.ts.
  void handleWorkflowNodeStarted(NodeStartedEvent params, RunContainerSize container) {
    final data = params.data;
    final nodeId = data['node_id'];
    final draft = _data;
    final tracing = _tracing(draft);
    final currentIndex = tracing.indexWhere((t) => t['node_id'] == nodeId);
    // Dify: `if (currentIndex && currentIndex > -1)`: an entry at index 0 is not replaced, a new one is pushed.
    if (currentIndex > 0) {
      tracing[currentIndex] = {...jsonCopy(data), 'status': NodeRunningStatus.running};
    } else {
      tracing.add({...jsonCopy(data), 'status': NodeRunningStatus.running});
    }
    _set(draft);
    final node = _node(nodeId as String?);
    if (node == null) return;
    _centre(node, container);
    _patchNodes({
      node.id: {'_runningStatus': NodeRunningStatus.running, '_waitingRun': false},
    });
    final edges = <String, DifyJson>{};
    for (final e in graph.edges.where((e) => e.target == nodeId)) {
      if (_node(e.source) == null) continue;
      final income = _nodeData(e.source);
      final branch = income['_runningBranchId'];
      if ((!_truthy(branch) && e.sourceHandle == 'source') || (_truthy(branch) && e.sourceHandle == branch)) {
        edges[e.id] = {
          '_sourceRunningStatus': income['_runningStatus'],
          '_targetRunningStatus': NodeRunningStatus.running,
          '_waitingRun': false,
        };
      }
    }
    _patchEdges(edges);
  }

  /// use-workflow-node-finished.ts.
  void handleWorkflowNodeFinished(NodeFinishedEvent params) {
    final data = params.data;
    final draft = _data;
    final tracing = _tracing(draft);
    final currentIndex = tracing.indexWhere((t) => t['id'] == data['id']);
    if (currentIndex > -1) tracing[currentIndex] = {...tracing[currentIndex], ...jsonCopy(data)};
    _set(draft);
    final nodeId = data['node_id'] as String?;
    if (_node(nodeId) == null) return;
    final patch = <String, Object?>{'_runningStatus': data['status']};
    if (data['node_type'] == 'agent') {
      final raw = _nodeData(nodeId!)['_agentProgress'];
      final progress = AgentProgressView.finished(
        raw is Map ? AgentProgressView.parse(raw.cast<String, Object?>()) : null,
        _map(data['execution_metadata']),
      );
      if (progress != null) patch['_agentProgress'] = progress.json;
    }

    if (data['status'] == NodeRunningStatus.exception) {
      if (_map(data['execution_metadata'])['error_strategy'] == errorHandleFailBranch) {
        patch['_runningBranchId'] = errorHandleFailBranch;
      }
    } else {
      final outputs = _map(data['outputs']);
      switch (data['node_type']) {
        case 'if-else':
          patch['_runningBranchId'] = outputs['selected_case_id'];
        case 'question-classifier':
          patch['_runningBranchId'] = outputs['class_id'];
        case 'human-input':
          patch['_runningBranchId'] = outputs['__action_id'];
      }
    }
    _patchNodes({nodeId!: patch});
    _patchEdges({
      for (final e in graph.edges.where((e) => e.target == nodeId)) e.id: {'_targetRunningStatus': data['status']},
    });
  }

  /// use-workflow-node-retry.ts.
  void handleWorkflowNodeRetry(NodeRetryEvent params) {
    final data = params.data;
    final draft = _data;
    _tracing(draft).add(jsonCopy(data));
    _set(draft);
    final nodeId = data['node_id'] as String?;
    if (_node(nodeId) == null) return;
    _patchNodes({
      nodeId!: {'_retryIndex': data['retry_index']},
    });
  }

  /// use-workflow-node-iteration-started.ts.
  void handleWorkflowNodeIterationStarted(IterationStartedEvent params, RunContainerSize container) {
    final data = params.data;
    final draft = _data;
    _tracing(draft).add({...jsonCopy(data), 'status': NodeRunningStatus.running});
    _set(draft);
    store.setIterTimes(defaultIterTimes);
    final node = _node(data['node_id'] as String?);
    if (node == null) return;
    _centre(node, container);
    _patchNodes({
      node.id: {
        '_runningStatus': NodeRunningStatus.running,
        '_iterationLength': _map(data['metadata'])['iterator_length'],
        '_waitingRun': false,
      },
    });
    _patchEdges({
      for (final e in graph.edges.where((e) => e.target == node.id))
        e.id: {
          '_sourceRunningStatus': _nodeData(e.source)['_runningStatus'],
          '_targetRunningStatus': NodeRunningStatus.running,
          '_waitingRun': false,
        },
    });
  }

  /// use-workflow-node-iteration-next.ts.
  void handleWorkflowNodeIterationNext(IterationNextEvent params) {
    final iterTimes = store.iterTimes.value;
    final nodeId = params.data['node_id'] as String?;
    if (_node(nodeId) == null) return;
    _patchNodes({
      nodeId!: {'_iterationIndex': iterTimes},
    });
    store.setIterTimes(iterTimes + 1);
  }

  /// use-workflow-node-iteration-finished.ts.
  void handleWorkflowNodeIterationFinished(IterationCompletedEvent params) {
    final data = params.data;
    final draft = _data;
    final tracing = _tracing(draft);
    final currentIndex = tracing.indexWhere((t) => t['id'] == data['id']);
    if (currentIndex > -1) tracing[currentIndex] = {...tracing[currentIndex], ...jsonCopy(data)};
    _set(draft);
    store.setIterTimes(defaultIterTimes);
    _finishContainer(data);
  }

  void _finishContainer(DifyJson data) {
    final nodeId = data['node_id'] as String?;
    if (_node(nodeId) == null) return;
    _patchNodes({
      nodeId!: {'_runningStatus': data['status']},
    });
    _patchEdges({
      for (final e in graph.edges.where((e) => e.target == nodeId)) e.id: {'_targetRunningStatus': data['status']},
    });
  }

  /// use-workflow-node-loop-started.ts.
  void handleWorkflowNodeLoopStarted(LoopStartedEvent params, RunContainerSize container) {
    final data = params.data;
    final draft = _data;
    _tracing(draft).add({...jsonCopy(data), 'status': NodeRunningStatus.running});
    _set(draft);
    final node = _node(data['node_id'] as String?);
    if (node == null) return;
    _centre(node, container);
    _patchNodes({
      node.id: {
        '_runningStatus': NodeRunningStatus.running,
        '_loopLength': _map(data['metadata'])['loop_length'],
        '_waitingRun': false,
      },
    });
    _patchEdges({
      for (final e in graph.edges.where((e) => e.target == node.id))
        e.id: {
          '_sourceRunningStatus': _nodeData(e.source)['_runningStatus'],
          '_targetRunningStatus': NodeRunningStatus.running,
          '_waitingRun': false,
        },
    });
  }

  /// use-workflow-node-loop-next.ts.
  void handleWorkflowNodeLoopNext(LoopNextEvent params) {
    final data = params.data;
    final nodeId = data['node_id'] as String?;
    if (_node(nodeId) == null) return;
    _patchNodes({
      nodeId!: {'_loopIndex': data['index']},
      for (final n in graph.nodes)
        if (n.parentId == nodeId) n.id: {'_waitingRun': true, '_runningStatus': NodeRunningStatus.waiting},
    });
  }

  /// use-workflow-node-loop-finished.ts.
  void handleWorkflowNodeLoopFinished(LoopCompletedEvent params) {
    final data = params.data;
    final draft = _data;
    final tracing = _tracing(draft);
    final currentIndex = tracing.indexWhere((t) => t['id'] == data['id']);
    if (currentIndex > -1) tracing[currentIndex] = {...tracing[currentIndex], ...jsonCopy(data)};
    _set(draft);
    _finishContainer(data);
  }

  /// use-workflow-text-chunk.ts.
  void handleWorkflowTextChunk(TextChunkEvent params) {
    final text = params.text;
    final selector = params.data['from_variable_selector'];
    final nextSelectorKey = selector is List ? selector.join('.') : null;
    final draft = _data;
    draft['resultTabActive'] = true;
    final resultText = draft['resultText'] as String? ?? '';
    final currentKey = draft['resultTextSelectorKey'] as String?;
    final shouldInsertLineBreak =
        _truthy(nextSelectorKey) &&
        resultText.isNotEmpty &&
        _truthy(currentKey) &&
        currentKey != nextSelectorKey &&
        !resultText.endsWith('\n') &&
        !text.startsWith('\n');
    draft['resultText'] = '$resultText${shouldInsertLineBreak ? '\n' : ''}$text';
    if (_truthy(nextSelectorKey)) draft['resultTextSelectorKey'] = nextSelectorKey;
    _set(draft);
  }

  /// use-workflow-text-replace.ts.
  void handleWorkflowTextReplace(TextReplaceEvent params) {
    final draft = _data;
    draft['resultText'] = params.text;
    draft.remove('resultTextSelectorKey');
    _set(draft);
  }

  /// use-workflow-reasoning.ts.
  void handleWorkflowReasoning(ReasoningChunkEvent params) {
    final data = params.data;
    final reasoning = data['reasoning'] as String?;
    final draft = _data;
    final content = (draft['reasoningContent'] ??= <String, Object?>{}) as Map<String, Object?>;
    final key = _truthy(data['node_id']) ? data['node_id'] as String : '_';
    if (_truthy(reasoning)) content[key] = '${content[key] as String? ?? ''}$reasoning';
    if (data['is_final'] == true) draft['reasoningFinished'] = true;
    _set(draft);
  }

  /// use-workflow-agent-log.ts.
  void handleWorkflowAgentLog(AgentLogEvent params) {
    final data = params.data;
    final nodeId = data['node_id'];
    if (nodeId is String && _node(nodeId) != null) {
      final previous = _nodeData(nodeId)['_agentProgress'];
      final next = AgentProgressView.advance(
        previous is Map ? AgentProgressView.parse(previous.cast<String, Object?>()) : null,
        data,
      );
      if (next != null) {
        _patchNodes({
          nodeId: {'_agentProgress': next.json},
        });
      }
    }
    final draft = _data;
    final tracing = _tracing(draft);
    final currentIndex = tracing.indexWhere((t) => t['node_id'] == data['node_id']);
    if (currentIndex > -1) {
      final current = tracing[currentIndex];
      final meta = current['execution_metadata'];
      if (meta is Map) {
        final log = meta['agent_log'];
        if (log is List) {
          final i = log.indexWhere((l) => l is Map && l['message_id'] == data['message_id']);
          if (i > -1) {
            log[i] = {..._map(log[i]), ...jsonCopy(data)};
          } else {
            log.add(jsonCopy(data));
          }
        } else {
          meta['agent_log'] = [jsonCopy(data)];
        }
      } else {
        current['execution_metadata'] = {
          'agent_log': [jsonCopy(data)],
        };
      }
    }
    _set(draft);
  }

  /// use-workflow-paused.ts.
  void handleWorkflowPaused() {
    final draft = _data;
    draft['result'] = {..._map(draft['result']), 'status': WorkflowRunningStatus.paused};
    _set(draft);
  }

  /// use-workflow-node-human-input-required.ts (human input required is not the workflow being paused).
  void handleWorkflowNodeHumanInputRequired(HumanInputRequiredEvent params) {
    final data = params.data;
    final draft = _data;
    final forms = draft['humanInputFormDataList'];
    if (forms is! List) {
      draft['humanInputFormDataList'] = [jsonCopy(data)];
    } else {
      final i = forms.indexWhere((f) => f is Map && f['node_id'] == data['node_id']);
      if (i > -1) {
        forms[i] = jsonCopy(data);
      } else {
        forms.add(jsonCopy(data));
      }
    }
    final tracing = _tracing(draft);
    final currentIndex = tracing.indexWhere((t) => t['node_id'] == data['node_id']);
    if (currentIndex > -1) tracing[currentIndex] = {...tracing[currentIndex], 'status': NodeRunningStatus.paused};
    _set(draft);
    final nodeId = data['node_id'] as String?;
    if (_node(nodeId) == null) return;
    _patchNodes({
      nodeId!: {'_runningStatus': NodeRunningStatus.paused},
    });
  }

  /// use-workflow-node-human-input-form-filled.ts.
  void handleWorkflowNodeHumanInputFormFilled(HumanInputFormFilledEvent params) {
    final data = params.data;
    final draft = _data;
    final forms = draft['humanInputFormDataList'];
    if (forms is List && forms.isNotEmpty) {
      final i = forms.indexWhere((f) => f is Map && f['node_id'] == data['node_id']);
      // Dify: `splice(-1, 1)` removes the last form when none matches.
      forms.removeAt(i == -1 ? forms.length - 1 : i);
    }
    final filled = draft['humanInputFilledFormDataList'];
    if (filled is List) {
      filled.add(jsonCopy(data));
    } else {
      draft['humanInputFilledFormDataList'] = [jsonCopy(data)];
    }
    _set(draft);
  }

  /// use-workflow-node-human-input-form-timeout.ts.
  void handleWorkflowNodeHumanInputFormTimeout(HumanInputFormTimeoutEvent params) {
    final data = params.data;
    final draft = _data;
    final forms = draft['humanInputFormDataList'];
    if (forms is List && forms.isNotEmpty) {
      final i = forms.indexWhere((f) => f is Map && f['node_id'] == data['node_id']);
      if (i > -1) (forms[i] as Map)['expiration_time'] = data['expiration_time'];
    }
    _set(draft);
  }

  // ----- use-nodes-interactions-without-sync.ts, use-edges-interactions-without-sync.ts -----

  /// handleNodeCancelRunningStatus.
  void handleNodeCancelRunningStatus() => _patchNodes({
    for (final n in graph.nodes) n.id: {'_runningStatus': null, '_waitingRun': false},
  });

  /// handleCancelAllNodeSuccessStatus.
  void handleCancelAllNodeSuccessStatus() => _patchNodes({
    for (final n in graph.nodes)
      if (_nodeData(n.id)['_runningStatus'] == NodeRunningStatus.succeeded) n.id: {'_runningStatus': null},
  });

  /// handleCancelNodeSuccessStatus.
  void handleCancelNodeSuccessStatus(String nodeId) {
    if (_nodeData(nodeId)['_runningStatus'] != NodeRunningStatus.succeeded) return;
    _patchNodes({
      nodeId: {'_runningStatus': null, '_waitingRun': false},
    });
  }

  /// handleEdgeCancelRunningStatus.
  void handleEdgeCancelRunningStatus() => _patchEdges({
    for (final e in graph.edges)
      e.id: {'_sourceRunningStatus': null, '_targetRunningStatus': null, '_waitingRun': false},
  });

  /// handleRun's first step: every node's `_runningStatus` cleared.
  void clearNodesRunningStatus() => _patchNodes({
    for (final n in graph.nodes) n.id: {'_runningStatus': null, '_agentProgress': null},
  });
}

bool _truthy(Object? v) => switch (v) {
  null || false || '' => false,
  num n => n != 0 && !n.isNaN,
  _ => true,
};

/// `getFilesInLogs` (base/file-uploader/utils.ts): the file values of a run's outputs, `[{varName, list}]`.
List<DifyJson> getFilesInLogs(Object? rawData) {
  if (rawData is! Map) return const [];
  bool isFile(Object? f) => f is Map && f['dify_model_identity'] == '__dify__file__';
  return [
    for (final e in rawData.entries)
      if (isFile(e.value))
        {
          'varName': e.key,
          'list': getProcessedFilesFromResponse([e.value]),
        }
      else if (e.value is List && (e.value as List).any(isFile))
        {'varName': e.key, 'list': getProcessedFilesFromResponse(e.value as List)},
  ];
}
