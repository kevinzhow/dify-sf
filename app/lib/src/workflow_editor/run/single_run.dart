/// Running one node (Dify 1.17.1 nodes/_base/hooks/use-one-step-run.ts, the data side; the Last Run tab's query
/// `useLastRun` / `useInvalidLastRun` of service/use-workflow.ts). The node's `_isSingleRun` /
/// `_singleRunningStatus` are the store's local run fields ([WorkflowStore.nodeRunData]), never document ops.
///
/// The form inputs (`toVarInputs`, `getInputVars`, `varSelectorsToVarInputs`) are built from the upstream nodes'
/// variables ([formatItem]), the environment / conversation variables and the system ones. Not ported here: the
/// per-type `checkValid` (pass [SingleRunController.checkValid]); Start variables' `isSelect` / `isParagraph` (the
/// output vars carry no such flags: their declared `options` are kept). Trigger nodes run once through
/// [WorkflowRunService.singleNodeRun] instead of polling the trigger debug endpoint.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../design/widgets/toast.dart';
import '../../workflow/var_types.dart' show DifyVar, NodeOutputVars, VarType, formatItem, supportOutputVarsNode;
import '../prompt_editor/prompt_blocks.dart' show getInputVars;
import '../store/workflow_store.dart';
import 'run_graph.dart';
import 'run_service.dart';
import 'run_stream.dart';
import 'run_types.dart';
import 'workflow_run.dart';

/// `checkValid(data)`: whether the node may run, and the message to show when not.
typedef SingleRunCheck = ({bool isValid, String errorMessage}) Function(DifyJson data);

/// `useOneStepRun` for one node, plus its last run. Listen to it for [runResult], [iterationRunResult],
/// [loopRunResult] and [lastRun]; [runningStatus] and [isShowSingleRun] live in the store
/// (`store.nodeRunData`), listen to that too.
class SingleRunController extends ChangeNotifier {
  SingleRunController({
    required this.nodeId,
    required this.store,
    required this.service,
    required this.graph,
    required this.run,
    bool Function()? isChatMode,
    this.checkValid,
    this.refreshNodeInspectVars,
    void Function(DifyToastType type, String message)? toast,
  }) : isChatMode = isChatMode ?? _never,
       toast = toast ?? difyToast {
    run.lastRunVersion.addListener(_invalidated);
  }

  static bool _never() => false;

  final String nodeId;
  final WorkflowStore store;
  final WorkflowRunService service;
  final RunGraph graph;
  final WorkflowRunController run;
  final bool Function() isChatMode;

  /// The node type's `checkValid`; null: always valid.
  SingleRunCheck? checkValid;

  /// `fetchNodeInspectVars` + `appendNodeInspectVars` after a run.
  final Future<void> Function(String nodeId)? refreshNodeInspectVars;
  final void Function(DifyToastType type, String message) toast;

  /// use-last-run's `isRunAfterSingleRun`.
  bool isRunAfterSingleRun = false;

  /// The run is paused (the backend can't pause a single run: results are dropped meanwhile).
  bool isPaused = false;

  DifyJson? _runResult;
  var _iterationRunResult = const <DifyJson>[];
  var _loopRunResult = const <DifyJson>[];
  DifyJson? _lastRun;
  var _lastRunLoading = false;
  var _lastRunWanted = false;
  var _lastRunFetch = 0;
  var _disposed = false;

  DifyJson? get runResult => _runResult;
  List<DifyJson> get iterationRunResult => _iterationRunResult;
  List<DifyJson> get loopRunResult => _loopRunResult;

  /// The node's last run (NodeTracing JSON) once [fetchLastRun] loaded it; null: none.
  DifyJson? get lastRun => _lastRun;
  bool get isLastRunLoading => _lastRunLoading;

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  void setRunResult(DifyJson? v) {
    _runResult = v;
    _changed();
  }

  RunGraphNode? get _node => graph.nodes.where((n) => n.id == nodeId).firstOrNull;
  DifyJson get _data => {...?_node?.data, ...store.nodeRunDataOf(nodeId)};
  String get _type => _node?.type ?? '';

  /// `data._singleRunningStatus || NodeRunningStatus.NotStart`.
  String get runningStatus =>
      store.nodeRunDataOf(nodeId)['_singleRunningStatus'] as String? ?? NodeRunningStatus.notStart;

  bool get isCompleted => runningStatus == NodeRunningStatus.succeeded || runningStatus == NodeRunningStatus.failed;

  bool get _isIteration => _type == 'iteration';
  bool get _isLoop => _type == 'loop';
  bool get _isTrigger => const {'trigger-webhook', 'trigger-plugin', 'trigger-schedule'}.contains(_type);

  void _update(DifyJson patch) => store.setNodeRunData(nodeId, patch);

  /// `isShowSingleRun`: `data._isSingleRun && canShowSingleRun`.
  bool get isShowSingleRun =>
      store.nodeRunDataOf(nodeId)['_isSingleRun'] == true && _checkValidWrap(quiet: true).isValid;

  ({bool isValid, String errorMessage}) _checkValidWrap({bool quiet = false}) {
    final check = checkValid;
    if (check == null) return (isValid: true, errorMessage: '');
    final res = check(_data);
    if (!res.isValid && !quiet) {
      _update({'_isSingleRun': false});
      if (res.errorMessage.isNotEmpty) toast(DifyToastType.error, res.errorMessage);
    }
    return res;
  }

  /// `checkValid` as the hook returns it (hides the form and toasts when invalid).
  ({bool isValid, String errorMessage}) validate() => _checkValidWrap();

  void showSingleRun() {
    _update({'_isSingleRun': true});
    store.setShowSingleRunPanel(isShowSingleRun);
  }

  void hideSingleRun() {
    _update({'_isSingleRun': false});
    store.setShowSingleRunPanel(false);
  }

  /// `setNodeRunning`.
  void setNodeRunning() => _update({'_singleRunningStatus': NodeRunningStatus.running});

  /// `updateNodeInspectRunningState`.
  void _inspectRunning(bool isRunning) {
    final list = store.nodesWithInspectVars.value;
    final i = list.indexWhere((n) => n['nodeId'] == nodeId);
    if (i != -1) {
      final target = list[i];
      if (target['isSingRunRunning'] == isRunning) return;
      store.setNodesWithInspectVars(
        [...list]..[i] = {...target, 'isSingRunRunning': isRunning, if (isRunning) 'isValueFetched': false},
      );
    } else if (isRunning) {
      final node = _node;
      if (node == null) return;
      store.setNodesWithInspectVars([
        {
          'nodeId': nodeId,
          'nodeType': node.type,
          'title': node.title,
          'vars': const <DifyJson>[],
          'nodePayload': node.data,
          'isSingRunRunning': true,
          'isValueFetched': false,
        },
        ...list,
      ]);
    }
  }

  void _startTriggerListening() {
    if (!_isTrigger) return;
    store
      ..setIsListening(true)
      ..setShowVariableInspectPanel(true)
      ..setListeningTriggerType(_type)
      ..setListeningTriggerNodeId(nodeId)
      ..setListeningTriggerNodeIds([nodeId])
      ..setListeningTriggerIsAll(false);
  }

  void _stopTriggerListening() {
    if (!_isTrigger) return;
    clearListeningState(store);
  }

  void _invalidLastRun() => _invalidated();

  /// `setRunResult` (the hook's wrapper): the inspect variables are refreshed after a run that may show.
  Future<void> _setRunResult(DifyJson? data) async {
    if (isPaused) return;
    final canRunLastRun = !isRunAfterSingleRun || runningStatus == NodeRunningStatus.succeeded;
    if (!canRunLastRun) {
      setRunResult(data);
      return;
    }
    await refreshNodeInspectVars?.call(nodeId);
    _inspectRunning(false);
    if (data?['status'] == NodeRunningStatus.succeeded) _invalidLastRun();
  }

  /// `handleRun(submitData)`: false when the run failed.
  Future<bool?> handleRun(DifyJson submitData) async {
    _inspectRunning(true);
    if (_isTrigger) {
      _startTriggerListening();
    } else {
      _stopTriggerListening();
    }
    _update({
      '_isSingleRun': false,
      '_singleRunningStatus': _isTrigger ? NodeRunningStatus.listening : NodeRunningStatus.running,
    });
    DifyJson? res;
    var hasError = false;
    try {
      if (_isIteration || _isLoop) {
        _runContainer(submitData);
      } else {
        final DifyJson postData;
        if (_type == 'start') {
          final inputs = {...submitData}
            ..remove('#sys.query#')
            ..remove('#sys.files#');
          postData = {
            if (isChatMode()) 'conversation_id': '',
            'inputs': inputs,
            'query': submitData['#sys.query#'],
            'files': submitData['#sys.files#'] ?? const <Object?>[],
          };
        } else {
          postData = {'inputs': submitData};
        }
        res = await service.singleNodeRun(nodeId, postData);
        final error = res['error'];
        if (error is String && error.isNotEmpty) throw RunServiceException(error);
      }
    } catch (e) {
      hasError = true;
      _invalidLastRun();
      if (!_isIteration && !_isLoop) {
        if (!isPaused) _update({'_isSingleRun': false, '_singleRunningStatus': NodeRunningStatus.failed});
        _finally(res);
        return false;
      }
    }
    _finally(res);
    if (isPaused) return null;
    if (!_isIteration && !_isLoop && !hasError) {
      _update({'_isSingleRun': false, '_singleRunningStatus': NodeRunningStatus.succeeded});
    }
    return null;
  }

  void _finally(DifyJson? res) {
    _stopTriggerListening();
    if (!_isIteration && !_isLoop) _inspectRunning(false);
    if (!isPaused && !_isIteration && !_isLoop && res != null) {
      final meta = res['execution_metadata'];
      final account = res['created_by_account'];
      unawaited(
        _setRunResult({
          ...res,
          'total_tokens': (meta is Map ? meta['total_tokens'] : null) ?? 0,
          'created_by': (account is Map ? account['name'] : null) ?? '',
        }),
      );
    }
  }

  /// The iteration / loop single run: the stream's node executions go to [iterationRunResult] /
  /// [loopRunResult], the container's own result to [runResult].
  void _runContainer(DifyJson submitData) {
    final loop = _isLoop;
    if (loop) {
      _loopRunResult = const [];
    } else {
      _iterationRunResult = const [];
    }
    _changed();
    var results = <DifyJson>[];
    DifyJson? runResult;
    void set(List<DifyJson> r) {
      results = r;
      if (loop) {
        _loopRunResult = r;
      } else {
        _iterationRunResult = r;
      }
      _changed();
    }

    void merge(DifyJson data) {
      final i = results.indexWhere((t) => t['id'] == data['id']);
      if (i > -1) set([...results]..[i] = {...results[i], ...data});
    }

    final stream = loop
        ? service.loopSingleNodeRun(nodeId, {'inputs': submitData})
        : service.iterationSingleNodeRun(nodeId, {'inputs': submitData});
    void containerStarted(DifyJson data) => set([
      ...results,
      {...data, 'status': NodeRunningStatus.running},
    ]);
    void containerFinished(DifyJson data) {
      runResult = {...data};
      unawaited(_setRunResult(runResult));
      // Dify merges the node's own `data` here (`...data` shadows the event's); kept.
      final i = results.indexWhere((t) => t['id'] == data['id']);
      if (i > -1) set([...results]..[i] = {...results[i], ..._data});
    }

    listenRunEvents(
      stream,
      RunCallbacks(
        onWorkflowFinished: (e) {
          if (isPaused) return;
          _update({'_isSingleRun': false, '_singleRunningStatus': NodeRunningStatus.succeeded});
          final createdBy = e.data['created_by'];
          if (runResult != null) {
            runResult!['created_by'] = createdBy is Map ? createdBy['name'] : null;
            unawaited(_setRunResult(runResult));
          }
        },
        onIterationStart: loop ? null : (e) => containerStarted(e.data),
        onIterationFinish: loop ? null : (e) => containerFinished(e.data),
        onLoopStart: loop ? (e) => containerStarted(e.data) : null,
        onLoopFinish: loop ? (e) => containerFinished(e.data) : null,
        onNodeStarted: (e) => set([
          ...results,
          {...e.data, 'status': NodeRunningStatus.running},
        ]),
        onNodeFinished: (e) => merge(e.data),
        onNodeRetry: (e) => set([...results, e.data]),
        onError: (_, [_]) {
          if (isPaused) return;
          _update({'_isSingleRun': false, '_singleRunningStatus': NodeRunningStatus.failed});
        },
      ),
    );
  }

  /// `handleStop`.
  void handleStop() {
    if (_isTrigger) {
      if (runningStatus != NodeRunningStatus.listening) return;
    } else if (runningStatus != NodeRunningStatus.running) {
      return;
    }
    _update({'_isSingleRun': false, '_singleRunningStatus': NodeRunningStatus.stopped});
    _stopTriggerListening();
    _inspectRunning(false);
    final running = store.workflowRunningData.value;
    if (running != null) {
      final draft = jsonCopy(running);
      draft['result'] = {...resultOf(draft), 'status': WorkflowRunningStatus.stopped};
      store.setWorkflowRunningData(draft);
    }
    final inspect = store.nodesWithInspectVars.value.where((n) => n['nodeId'] == nodeId).firstOrNull;
    final vars = inspect?['vars'];
    if (inspect != null && inspect['isValueFetched'] != true && (vars is! List || vars.isEmpty)) {
      store.deleteNodeInspectVars(nodeId);
    }
  }

  // ----- the form inputs -----

  /// `getBeforeNodesInSameBranch(id)`: the upstream nodes (and the container's) that have output variables, nearest
  /// last.
  List<RunGraphNode> _beforeNodes(String id) {
    final nodes = graph.nodes, edges = graph.edges;
    RunGraphNode? byId(String? i) => nodes.where((n) => n.id == i).firstOrNull;
    final current = byId(id);
    final list = <RunGraphNode>[];
    if (current == null) return list;
    if (current.parentId != null && byId(current.parentId) != null) list.addAll(_beforeNodes(current.parentId!));
    void traverse(RunGraphNode root) {
      for (final e in edges.where((e) => e.target == root.id)) {
        final n = byId(e.source);
        if (n != null && !list.any((l) => l.id == n.id)) {
          list.add(n);
          traverse(n);
        }
      }
    }

    traverse(current);
    final seen = <String>{};
    return [
      for (final n in list.reversed)
        if (seen.add(n.id) && supportOutputVarsNode.contains(n.type)) n,
    ];
  }

  /// `getBeforeNodesInSameBranchIncludeParent(id)`.
  List<RunGraphNode> get _beforeNodesIncludeParent {
    final list = _beforeNodes(nodeId);
    final parentId = _node?.parentId;
    final parent = graph.nodes.where((n) => n.id == parentId).firstOrNull;
    return [...list, ?parent];
  }

  /// `toNodeOutputVars(availableNodes, isChatMode, ..., conversationVariables)`: the upstream nodes' variables (Start
  /// last, the rest by x, descending), then ENVIRONMENT, CONVERSATION (chat) and SYSTEM.
  List<NodeOutputVars> get _allOutputVars {
    final chat = isChatMode();
    final nodes = _beforeNodes(nodeId).indexed.toList()
      ..sort((a, b) {
        final byStart = (a.$2.type == 'start' ? 1 : 0) - (b.$2.type == 'start' ? 1 : 0);
        if (byStart != 0) return byStart;
        final byX = b.$2.x.compareTo(a.$2.x);
        return byX != 0 ? byX : a.$1.compareTo(b.$1);
      });
    List<DifyVar> declared(List<DifyJson> list, String prefix) => [
      for (final v in list)
        if (v['name'] is String && v['value_type'] != 'llm')
          DifyVar('$prefix.${v['name']}', v['value_type'] as String?),
    ];
    final env = declared(store.environmentVariables.value, 'env');
    final conversation = chat ? declared(store.conversationVariables.value, 'conversation') : const <DifyVar>[];
    return [
      for (final (_, n) in nodes)
        if (formatItem(n.id, {'type': n.type, 'title': n.title, ...n.data}, chatMode: chat) case final vars
            when vars.isNotEmpty)
          NodeOutputVars(n.id, n.title, vars, isStartNode: n.type == 'start'),
      if (env.isNotEmpty) NodeOutputVars('env', 'ENVIRONMENT', env),
      if (conversation.isNotEmpty) NodeOutputVars('conversation', 'CONVERSATION', conversation),
      NodeOutputVars('global', 'SYSTEM', [
        if (chat) ...[
          const DifyVar('sys.dialogue_count', VarType.number),
          const DifyVar('sys.conversation_id', VarType.string),
        ],
        const DifyVar('sys.user_id', VarType.string),
        const DifyVar('sys.app_id', VarType.string),
        const DifyVar('sys.workflow_id', VarType.string),
        const DifyVar('sys.workflow_run_id', VarType.string),
        if (!chat) const DifyVar('sys.timestamp', VarType.number),
      ]),
    ];
  }

  /// `getVar(valueSelector)`.
  DifyVar? _getVar(List<String> valueSelector) {
    final all = _allOutputVars;
    if (valueSelector.firstOrNull == 'sys') {
      final key = valueSelector.join('.');
      return all.expand((g) => g.vars).where((v) => v.variable == key).firstOrNull;
    }
    final target = all.where((g) => g.nodeId == valueSelector.firstOrNull).firstOrNull;
    if (target == null) return null;
    Object? curr = target.vars;
    for (var i = 1; i < valueSelector.length; i++) {
      final key = valueSelector[i];
      if (curr is List) {
        curr = curr.whereType<DifyVar>().where((v) => v.variable.replaceFirst('conversation.', '') == key).firstOrNull;
      }
      if (i == valueSelector.length - 1) return curr is DifyVar ? curr : null;
      if (curr is DifyVar && (curr.type == VarType.object || curr.type == VarType.file)) curr = curr.children;
    }
    return null;
  }

  /// `toVarInputs(variables)`: the before-run form's inputs (InputVar JSON) for Dify `Variable`s (`variable`,
  /// `value_selector`, `label`, `value_type`, `options`, `required`, `isParagraph`).
  List<DifyJson> toVarInputs(List<DifyJson> variables) => [
    for (final item in variables)
      if ((item['value_selector'] as List?)?.firstOrNull != 'env')
        () {
          final selector = [for (final s in (item['value_selector'] as List?) ?? const []) '$s'];
          final original = _getVar(selector);
          final label = item['label'];
          if (original == null) {
            final options = item['options'];
            return <String, Object?>{
              'label': label ?? item['variable'],
              'variable': item['variable'],
              'type': item['value_type'] != null
                  ? varTypeToInputVarType(
                      item['value_type'] as String,
                      isSelect: options is List && options.isNotEmpty,
                      isParagraph: item['isParagraph'] == true,
                    )
                  : 'text-input',
              'required': true,
              'value_selector': item['value_selector'],
              'options': options,
            };
          }
          final labelText = label is Map ? label['variable'] : label;
          return <String, Object?>{
            'label': (labelText is String && labelText.isNotEmpty) ? labelText : item['variable'],
            'variable': item['variable'],
            'type': varTypeToInputVarType(original.type),
            'required': item['required'] != false,
            'options': item['options'],
          };
        }(),
  ];

  /// `getInputVars(textList)`: the inputs for the `{{#node.var#}}` references in [textList].
  List<DifyJson> getFormInputVars(List<String> textList) {
    final seen = <String>{};
    final selectors = [
      for (final t in textList)
        for (final s in getInputVars(t))
          if (seen.add(s.join('.'))) s,
    ];
    final available = _beforeNodesIncludeParent;
    return toVarInputs([
      for (final item in selectors)
        () {
          final info = available.where((n) => n.id == item.first).firstOrNull;
          return <String, Object?>{
            'label': {
              'nodeType': info?.type,
              'nodeName': info?.title ?? available.firstOrNull?.title,
              'variable': item.first == 'sys' ? item.join('.') : item.last,
              'isChatVar': item.first == 'conversation',
            },
            'variable': '#${item.join('.')}#',
            'value_selector': item,
          };
        }(),
    ]);
  }

  /// `varSelectorsToVarInputs(valueSelectors)`.
  List<DifyJson> varSelectorsToVarInputs(List<List<String>> valueSelectors) => [
    for (final s in valueSelectors)
      if (s.isNotEmpty) ...getFormInputVars(['{{#${s.join('.')}#}}']).take(1),
  ];

  // ----- the last run (useLastRun / useInvalidLastRun) -----

  /// Loads the node's last run (and again whenever runs invalidate it).
  Future<void> fetchLastRun() async {
    _lastRunWanted = true;
    final n = ++_lastRunFetch;
    _lastRunLoading = true;
    _changed();
    DifyJson? data;
    try {
      data = await service.fetchNodeLastRun(nodeId);
    } catch (_) {
      data = null;
    }
    if (_disposed || n != _lastRunFetch) return;
    _lastRun = data;
    _lastRunLoading = false;
    _changed();
  }

  void _invalidated() {
    if (_lastRunWanted && !_disposed) unawaited(fetchLastRun());
  }

  @override
  void dispose() {
    _disposed = true;
    run.lastRunVersion.removeListener(_invalidated);
    super.dispose();
  }
}

/// `varTypeToInputVarType` (use-one-step-run.ts).
String varTypeToInputVarType(String? type, {bool isSelect = false, bool isParagraph = false}) {
  if (isSelect) return 'select';
  if (isParagraph) return 'paragraph';
  return switch (type) {
    VarType.number => 'number',
    VarType.boolean => 'checkbox',
    VarType.object || VarType.array || VarType.arrayNumber || VarType.arrayString || VarType.arrayObject => 'json',
    VarType.file => 'file',
    VarType.arrayFile => 'file-list',
    _ => 'text-input',
  };
}
