/// [MockWorkflowRunService]: the default [WorkflowRunService] until dify-sf has a runtime. Deterministic: it walks
/// the current graph from its entry node in topological order (only the branch each if-else / classifier / human
/// input takes), runs iterations and loops round by round over their children, and emits Dify's events with
/// plausible inputs / outputs per node type, `stepDelay` apart. A [MockRunScenario] makes nodes fail, raise an
/// exception, retry, pause for human input, take another branch, or the request fail; a script replaces the walk.
/// Runs, their node executions and every node's last run are remembered (run history, Last Run tabs).
library;

import 'dart:async';
import 'dart:convert';

import '../store/workflow_store.dart' show DifyJson;
import '../variable_inspect/inspect_vars.dart' show VariableInspectServices;
import 'run_graph.dart';
import 'run_service.dart';
import 'run_types.dart';

/// How mock runs go. Node ids name the nodes concerned.
class MockRunScenario {
  const MockRunScenario({
    this.stepDelay = const Duration(milliseconds: 300),
    this.failNodeId,
    this.failMessage = 'Mock node failed',
    this.exceptionNodeIds = const {},
    this.retries = const {},
    this.branches = const {},
    this.pauseNodeIds = const {},
    this.iterationLength = 3,
    this.loopLength = 3,
    this.outputs = const {},
    this.llmText = 'This is a mock answer from the language model.',
    this.chunkSize = 8,
    this.requestError,
    this.triggerDelay = Duration.zero,
  });

  /// Between two events.
  final Duration stepDelay;

  /// This node fails (`status: failed`, [failMessage]); the run fails with it unless the node handles errors
  /// (`error_strategy` fail-branch / default-value: `exception`, the run goes on).
  final String? failNodeId;
  final String failMessage;

  /// These nodes end with `exception` (their fail branch is taken when they have one).
  final Set<String> exceptionNodeIds;

  /// Node id → failed attempts (node_retry events) before the node succeeds.
  final Map<String, int> retries;

  /// Node id → the source handle taken (an if-else case id or `false`, a class id, a human input action id).
  final Map<String, String> branches;

  /// Human input nodes that pause the run until their form is submitted ([MockWorkflowRunService.submitHumanInputForm]).
  final Set<String> pauseNodeIds;

  /// Rounds of every iteration (when its input is not a list) and loop.
  final int iterationLength;
  final int loopLength;

  /// Node id → outputs to report instead of the made-up ones.
  final Map<String, DifyJson> outputs;

  /// The text LLM / agent nodes answer (streamed in [chunkSize] character pieces where an End or Answer shows it).
  final String llmText;
  final int chunkSize;

  /// The request itself fails with this message (the stream ends with a [RunServiceException]).
  final String? requestError;

  /// Trigger debug runs wait this long before the trigger "fires".
  final Duration triggerDelay;
}

class _ActiveRun {
  _ActiveRun(this.taskId, this.runId);
  final String taskId;
  final String runId;
  bool stopped = false;
  final stop = Completer<void>();
  final resumed = <String, Completer<DifyJson>>{};
}

/// See the library comment.
class MockWorkflowRunService extends WorkflowRunService {
  MockWorkflowRunService({
    required this.graph,
    this.scenario = const MockRunScenario(),
    this.script,
    this.conversationVariables,
    DateTime Function()? now,
    this.user = const {'id': 'mock-user', 'name': 'Mock User', 'email': 'mock@dify-sf.local'},
  }) : _now = now ?? DateTime.now;

  /// The graph runs walk (read when a run starts).
  final RunGraph Function() graph;

  /// How the next runs go (tests change it between runs).
  MockRunScenario scenario;

  /// Replaces the graph walk: the payloads to emit for a run (each `stepDelay` apart).
  List<DifyJson> Function(Object request)? script;

  /// The conversation variables' declarations (chatflow), returned with their default values.
  final List<DifyJson> Function()? conversationVariables;
  final DateTime Function() _now;

  /// The account runs are created by.
  final DifyJson user;

  var _seq = 0;
  String _id(String kind) => 'mock-$kind-${++_seq}';
  int get _seconds => _now().millisecondsSinceEpoch ~/ 1000;

  final _history = <DifyJson>[];
  final _tracings = <String, List<DifyJson>>{};
  final _lastRuns = <String, DifyJson>{};
  final _active = <String, _ActiveRun>{};
  final _byRunId = <String, _ActiveRun>{};
  final _pausedTokens = <String, (_ActiveRun, String nodeId)>{};
  final _messages = <String, List<DifyJson>>{};

  /// Runs started so far (requests in order), for tests.
  final requests = <Object>[];

  /// Task ids stopped so far, for tests.
  final stoppedTasks = <String>[];

  Future<void> _wait([Duration? d]) {
    final delay = d ?? scenario.stepDelay;
    return delay == Duration.zero ? Future<void>.value() : Future<void>.delayed(delay);
  }

  // ----- the service -----

  @override
  Stream<RunEvent> runWorkflowDraft(WorkflowDraftRunRequest request) {
    requests.add(request);
    return _run(request: request, inputs: request.inputs, mode: request.mode, chat: null);
  }

  @override
  Stream<RunEvent> sendChatMessage(ChatMessageRequest request) {
    requests.add(request);
    return _run(request: request, inputs: (request.body['inputs'] as Map?)?.cast() ?? const {}, chat: request);
  }

  @override
  Stream<RunEvent> workflowEvents(String workflowRunId) async* {
    final run = _byRunId[workflowRunId];
    if (run == null) return;
    for (final c in [...run.resumed.values]) {
      await c.future;
    }
  }

  @override
  Future<void> stopWorkflowRun(String taskId) async {
    stoppedTasks.add(taskId);
    final run = _active[taskId];
    if (run == null || run.stopped) return;
    run.stopped = true;
    if (!run.stop.isCompleted) run.stop.complete();
  }

  @override
  Future<void> stopChatMessageResponding(String taskId) => stopWorkflowRun(taskId);

  @override
  Future<List<String>> fetchSuggestedQuestions(String messageId) async => const [
    'What else can you do?',
    'Can you explain that in more detail?',
    'Give me an example.',
  ];

  @override
  Future<void> submitHumanInputForm(String formToken, DifyJson data) async {
    final paused = _pausedTokens.remove(formToken);
    if (paused == null) throw const RunServiceException('Form not found');
    final c = paused.$1.resumed[paused.$2];
    if (c != null && !c.isCompleted) c.complete(data);
  }

  @override
  Future<DifyJson> singleNodeRun(String nodeId, DifyJson body) async {
    await _wait();
    final node = _nodeById(nodeId);
    final inputs = (body['inputs'] as Map?)?.cast<String, Object?>() ?? const {};
    final now = _seconds;
    final failed = scenario.failNodeId == nodeId;
    final result = <String, Object?>{
      ..._tracing(node, index: 1, inputs: inputs, at: now),
      'status': failed ? NodeRunningStatus.failed : NodeRunningStatus.succeeded,
      'outputs': failed ? null : _outputs(node, inputs, const {}),
      'process_data': _processData(node),
      'error': failed ? scenario.failMessage : null,
      'elapsed_time': 0.42,
      'execution_metadata': _metadata(node),
      'finished_at': now,
      'created_by_account': user,
    };
    _ran(node, result);
    return result;
  }

  @override
  Stream<RunEvent> iterationSingleNodeRun(String nodeId, DifyJson body) => _singleContainer(nodeId, body, loop: false);

  @override
  Stream<RunEvent> loopSingleNodeRun(String nodeId, DifyJson body) => _singleContainer(nodeId, body, loop: true);

  @override
  Future<DifyJson?> fetchNodeLastRun(String nodeId) async => _lastRuns[nodeId];

  @override
  Future<List<DifyJson>> fetchWorkflowRunHistory() async => [for (final h in _history.reversed) _historyItem(h)];

  @override
  Future<DifyJson> fetchRunDetail(String runId) async {
    final h = _history.firstWhere(
      (h) => h['id'] == runId,
      orElse: () => throw RunServiceException('Run $runId not found'),
    );
    return {
      ..._historyItem(h),
      'inputs': jsonEncode(h['inputs']),
      'inputs_truncated': false,
      'outputs': jsonEncode(h['outputs']),
      'outputs_truncated': false,
      'created_by_role': 'account',
    };
  }

  @override
  Future<List<DifyJson>> fetchTracingList(String runId) async => [..._tracings[runId] ?? const []];

  @override
  Future<List<DifyJson>> fetchConversationVariables(String conversationId) async => [
    for (final v in conversationVariables?.call() ?? const <DifyJson>[])
      {...v, 'updated_at': _seconds, 'created_at': _seconds},
  ];

  @override
  Future<List<DifyJson>> fetchChatMessages(String conversationId) async => [..._messages[conversationId] ?? const []];

  // ----- the draft's cached variables (variable inspect) -----

  /// Node id → its cached variables (Dify's VarInInspect JSON), from its last run.
  final _inspect = <String, List<DifyJson>>{};
  final _sysVars = <DifyJson>[];
  final _edited = <String, Object?>{};

  /// The variable inspect panel's services over this mock's runs (each node's last outputs, the last run's system
  /// variables), editable and resettable as Dify's draft variables.
  late final VariableInspectServices inspectServices = _MockInspectServices(this);

  void _ran(RunGraphNode n, DifyJson finished) {
    _lastRuns[n.id] = finished;
    final outputs = finished['outputs'];
    if (outputs is! Map) return;
    DifyJson v(String id, String type, List<String> selector, Object? value) => {
      'id': id,
      'type': type,
      'name': selector.last,
      'description': '',
      'selector': selector,
      'value_type': _valueType(value),
      'value': value,
      'edited': false,
      'visible': true,
      'is_truncated': false,
      'full_content': null,
    };
    final vars = <DifyJson>[];
    for (final e in outputs.entries) {
      final key = '${e.key}';
      if (key.startsWith('sys.')) {
        _sysVars.removeWhere((s) => s['name'] == key.substring(4));
        _sysVars.add(v('sys-${key.substring(4)}', 'sys', ['sys', key.substring(4)], e.value));
      } else {
        vars.add(v('${n.id}-$key', 'node', [n.id, key], e.value));
      }
    }
    for (final x in vars) {
      _edited.remove(x['id']);
    }
    _inspect[n.id] = vars;
  }

  static String _valueType(Object? v) => switch (v) {
    String() => 'string',
    num() => 'number',
    bool() => 'boolean',
    final Map m when m['dify_model_identity'] == '__dify__file__' => 'file',
    Map() => 'object',
    final List l when l.isNotEmpty && l.every((x) => x is String) => 'array[string]',
    final List l when l.isNotEmpty && l.every((x) => x is num) => 'array[number]',
    final List l when l.isNotEmpty && l.every((x) => x is Map && x['dify_model_identity'] == '__dify__file__') =>
      'array[file]',
    final List l when l.isNotEmpty && l.every((x) => x is Map) => 'array[object]',
    List() => 'array[any]',
    _ => 'any',
  };

  DifyJson _withEdit(DifyJson v) =>
      _edited.containsKey(v['id']) ? {...v, 'value': _edited[v['id']], 'edited': true} : v;

  // ----- history -----

  DifyJson _historyItem(DifyJson h) => {
    for (final e in h.entries)
      if (e.key != 'inputs' || e.value is Map) e.key: e.value,
  };

  // ----- the walk -----

  RunGraphNode _nodeById(String id) => graph().nodes.firstWhere(
    (n) => n.id == id,
    orElse: () => RunGraphNode(id: id, type: 'unknown', title: id),
  );

  DifyJson _graphJson(RunGraph g) => {
    'nodes': [
      for (final n in g.nodes)
        {
          'id': n.id,
          'type': n.rfType,
          'data': n.data,
          'position': {'x': n.x, 'y': n.y},
          'width': n.width,
          'height': n.height,
          'parentId': ?n.parentId,
        },
    ],
    'edges': [
      for (final e in g.edges)
        {
          'id': e.id,
          'source': e.source,
          'target': e.target,
          'sourceHandle': e.sourceHandle,
          'targetHandle': e.targetHandle,
          'type': 'custom',
        },
    ],
  };

  Stream<RunEvent> _run({
    required Object request,
    required DifyJson inputs,
    TriggerType mode = TriggerType.userInput,
    ChatMessageRequest? chat,
  }) async* {
    final s = scenario;
    if (s.requestError != null) {
      await _wait();
      throw RunServiceException(s.requestError!);
    }
    final g = graph();
    final taskId = _id('task'), runId = _id('run');
    final run = _ActiveRun(taskId, runId);
    _active[taskId] = run;
    _byRunId[runId] = run;
    final conversationId = chat == null
        ? null
        : (chat.conversationId?.isNotEmpty == true ? chat.conversationId! : _id('conversation'));
    final messageId = chat == null ? null : _id('message');
    final startedAt = _seconds;
    final history = <String, Object?>{
      'id': runId,
      'version': 'draft',
      'conversation_id': ?conversationId,
      'message_id': ?messageId,
      'graph': _graphJson(g),
      'inputs': inputs,
      'status': WorkflowRunningStatus.running,
      'outputs': <String, Object?>{},
      'elapsed_time': 0,
      'total_tokens': 0,
      'total_steps': 0,
      'created_at': startedAt,
      'finished_at': null,
      'created_by_account': user,
      'exceptions_count': 0,
    };
    _history.add(history);
    final tracings = _tracings[runId] = [];
    DifyJson base(String event) => {
      'event': event,
      'task_id': taskId,
      'workflow_run_id': runId,
      'conversation_id': ?conversationId,
      'message_id': ?messageId,
    };

    if (mode != TriggerType.userInput) await _wait(s.triggerDelay);

    if (script != null) {
      for (final p in script!(request)) {
        if (run.stopped) break;
        await _wait();
        yield RunEvent.fromJson({...base(p['event'] as String? ?? ''), ...p});
      }
      _active.remove(taskId);
      return;
    }

    final walk = _Walk(this, g, run, inputs: inputs, chat: chat, base: base, tracings: tracings);
    yield RunEvent.fromJson({
      ...base('workflow_started'),
      'data': {'id': runId, 'workflow_id': 'mock-workflow', 'created_at': startedAt},
    });

    final entries = _entries(g, mode, request);
    await for (final e in walk.top(entries)) {
      yield e;
    }
    final finishedAt = _seconds;
    final status = run.stopped
        ? WorkflowRunningStatus.stopped
        : walk.error != null
        ? WorkflowRunningStatus.failed
        : WorkflowRunningStatus.succeeded;
    final outputs = walk.workflowOutputs();
    final data = {
      'id': runId,
      'workflow_id': 'mock-workflow',
      'status': status,
      'outputs': outputs,
      'error': walk.error ?? (run.stopped ? 'Workflow stopped' : null),
      'elapsed_time': walk.elapsed,
      'total_tokens': walk.tokens,
      'total_steps': walk.steps,
      'created_at': startedAt,
      'created_by': user,
      'finished_at': finishedAt,
      'exceptions_count': walk.exceptions,
      'files': <Object?>[],
    };
    history.addAll({
      'status': status,
      'outputs': outputs,
      'error': data['error'],
      'elapsed_time': walk.elapsed,
      'total_tokens': walk.tokens,
      'total_steps': walk.steps,
      'finished_at': finishedAt,
      'exceptions_count': walk.exceptions,
    });
    await _wait();
    yield RunEvent.fromJson({...base('workflow_finished'), 'data': data});
    if (chat != null) {
      yield RunEvent.fromJson({
        ...base('message_end'),
        'id': messageId,
        'metadata': {
          'retriever_resources': <Object?>[],
          'usage': {'total_tokens': walk.tokens},
        },
        'files': <Object?>[],
      });
      (_messages[conversationId!] ??= []).add({
        'id': messageId,
        'conversation_id': conversationId,
        'query': chat.query,
        'inputs': inputs,
        'answer': walk.answer.toString(),
        'message_files': <Object?>[],
        'feedback': null,
        'workflow_run_id': runId,
        'created_at': startedAt,
        'parent_message_id': chat.body['parent_message_id'],
        'status': status == WorkflowRunningStatus.failed ? 'error' : 'normal',
        'error': walk.error,
      });
    }
    _active.remove(taskId);
  }

  /// Where a run begins: the trigger node(s) of a trigger run, else the Start node (or the first entry node).
  List<RunGraphNode> _entries(RunGraph g, TriggerType mode, Object request) {
    final top = g.nodes.where((n) => n.parentId == null).toList();
    final body = request is WorkflowDraftRunRequest ? request.body : const <String, Object?>{};
    if (mode == TriggerType.all) {
      final ids = (body['node_ids'] as List?)?.cast<String>() ?? const [];
      return top.where((n) => ids.contains(n.id)).toList();
    }
    if (mode != TriggerType.userInput) return top.where((n) => n.id == body['node_id']).toList();
    final start = top.where((n) => n.type == 'start');
    if (start.isNotEmpty) return [start.first];
    final entry = top.where((n) => n.type.startsWith('trigger-') || n.type == 'datasource');
    return entry.isEmpty ? const [] : [entry.first];
  }

  Stream<RunEvent> _singleContainer(String nodeId, DifyJson body, {required bool loop}) async* {
    requests.add(body);
    final g = graph();
    final taskId = _id('task'), runId = _id('run');
    final run = _ActiveRun(taskId, runId);
    _active[taskId] = run;
    final now = _seconds;
    DifyJson base(String event) => {'event': event, 'task_id': taskId, 'workflow_run_id': runId};
    final inputs = (body['inputs'] as Map?)?.cast<String, Object?>() ?? const {};
    final walk = _Walk(this, g, run, inputs: inputs, chat: null, base: base, tracings: []);
    yield RunEvent.fromJson({
      ...base('workflow_started'),
      'data': {'id': runId, 'workflow_id': 'mock-workflow', 'created_at': now},
    });
    final node = _nodeById(nodeId);
    await for (final e in walk.container(node, predecessor: null)) {
      yield e;
    }
    await _wait();
    yield RunEvent.fromJson({
      ...base('workflow_finished'),
      'data': {
        'id': runId,
        'workflow_id': 'mock-workflow',
        'status': walk.error == null ? WorkflowRunningStatus.succeeded : WorkflowRunningStatus.failed,
        'outputs': walk.pool[nodeId] ?? const {},
        'error': walk.error,
        'elapsed_time': walk.elapsed,
        'total_tokens': walk.tokens,
        'total_steps': walk.steps,
        'created_at': now,
        'created_by': user,
        'finished_at': _seconds,
      },
    });
    _active.remove(taskId);
  }

  // ----- per node type -----

  DifyJson _tracing(
    RunGraphNode n, {
    required int index,
    required DifyJson inputs,
    required int at,
    String? predecessor,
  }) => {
    'id': _id('exec'),
    'index': index,
    'predecessor_node_id': predecessor,
    'node_id': n.id,
    'node_type': n.type,
    'title': n.title.isEmpty ? n.data['title'] ?? n.id : n.title,
    'inputs': inputs,
    'inputs_truncated': false,
    'process_data': null,
    'process_data_truncated': false,
    'outputs': null,
    'outputs_truncated': false,
    'status': NodeRunningStatus.running,
    'error': null,
    'elapsed_time': 0,
    'execution_metadata': null,
    'extras': <String, Object?>{},
    'created_at': at,
    'created_by': user,
    'finished_at': null,
  };

  DifyJson? _processData(RunGraphNode n) => switch (n.type) {
    'llm' || 'question-classifier' || 'parameter-extractor' => {
      'model_mode': 'chat',
      'model_provider': (n.data['model'] as Map?)?['provider'] ?? 'mock',
      'model_name': (n.data['model'] as Map?)?['name'] ?? 'mock-model',
      'prompts': [
        {'role': 'user', 'text': 'Mock prompt', 'files': <Object?>[]},
      ],
    },
    _ => null,
  };

  bool _usesModel(RunGraphNode n) =>
      const {'llm', 'agent', 'agent-v2', 'question-classifier', 'parameter-extractor'}.contains(n.type);

  DifyJson _metadata(RunGraphNode n) => {
    if (_usesModel(n)) ...{'total_tokens': 128, 'total_price': '0.000256', 'currency': 'USD'},
  };

  Object? _sample(Object? type) => switch (type) {
    'number' || 'integer' => 0,
    'boolean' => false,
    'object' => <String, Object?>{},
    final String t when t.startsWith('array') => <Object?>[],
    _ => 'mock',
  };

  /// The made-up outputs of [n] (the scenario's when it names the node); [pool] holds the outputs so far.
  DifyJson _outputs(RunGraphNode n, DifyJson inputs, Map<String, DifyJson> pool, {String? branch}) {
    final given = scenario.outputs[n.id];
    if (given != null) return given;
    final d = n.data;
    List<Map> list(String key) => (d[key] as List?)?.whereType<Map>().toList() ?? const [];
    return switch (n.type) {
      'start' => {
        ...inputs,
        'sys.files': <Object?>[],
        'sys.user_id': user['id'],
        'sys.app_id': 'mock-app',
        'sys.workflow_id': 'mock-workflow',
        'sys.workflow_run_id': 'mock-run',
      },
      'llm' || 'agent' || 'agent-v2' => {
        'text': scenario.llmText,
        'reasoning_content': '',
        'usage': {'prompt_tokens': 64, 'completion_tokens': 64, 'total_tokens': 128},
        'finish_reason': 'stop',
      },
      'code' => switch (d['outputs']) {
        final Map o => {for (final e in o.entries) e.key as String: _sample((e.value as Map?)?['type'])},
        final List o => {
          for (final v in o.whereType<Map>()) (v['variable'] ?? v['name']) as String? ?? 'result': _sample(v['type']),
        },
        _ => {'result': 'mock'},
      },
      'template-transform' => {'output': 'Mock template output'},
      'http-request' => {
        'status_code': 200,
        'body': '{"ok": true}',
        'headers': {'content-type': 'application/json'},
        'files': <Object?>[],
      },
      'knowledge-retrieval' => {'result': <Object?>[]},
      'question-classifier' => {
        'class_name': list('classes').where((c) => c['id'] == branch).firstOrNull?['name'] ?? '',
        'class_id': branch,
        'class_label': list('classes').where((c) => c['id'] == branch).firstOrNull?['name'] ?? '',
        'usage': {'total_tokens': 128},
      },
      'if-else' => {'result': branch != 'false', 'selected_case_id': branch},
      'parameter-extractor' => {
        for (final p in list('parameters')) p['name'] as String? ?? 'param': _sample(p['type']),
        '__is_success': 1,
        '__reason': null,
      },
      'tool' => {'text': 'Mock tool result', 'files': <Object?>[], 'json': <Object?>[]},
      'variable-aggregator' || 'variable-assigner' => {'output': 'mock'},
      'document-extractor' => {'text': 'Mock document text'},
      'list-operator' => {'result': <Object?>[], 'first_record': null, 'last_record': null},
      'human-input' => {'__action_id': branch, '__rendered_content': 'Mock form'},
      'end' => {
        for (final o in list('outputs')) o['variable'] as String? ?? 'output': _resolve(o['value_selector'], pool),
      },
      'answer' => {
        'answer': switch (d['answer']) {
          final String t => _render(t, pool),
          final List selector => '${_resolve(selector, pool) ?? ''}',
          _ => '',
        },
      },
      _ => <String, Object?>{},
    };
  }

  Object? _resolve(Object? selector, Map<String, DifyJson> pool) {
    if (selector is! List || selector.length < 2) return null;
    final out = pool[selector[0]];
    if (out == null) return null;
    final key = selector.sublist(1).join('.');
    return out.containsKey(key) ? out[key] : out[selector[1]];
  }

  static final _ref = RegExp(r'\{\{#([^#]+)#\}\}');

  String _render(String template, Map<String, DifyJson> pool) =>
      template.replaceAllMapped(_ref, (m) => '${_resolve(m[1]!.split('.'), pool) ?? ''}');

  /// The source handle [n] takes (null: `source`).
  String? _branch(RunGraphNode n) {
    final chosen = scenario.branches[n.id];
    if (chosen != null) return chosen;
    final d = n.data;
    return switch (n.type) {
      'if-else' => ((d['cases'] as List?)?.whereType<Map>().firstOrNull?['case_id'] as String?) ?? 'true',
      'question-classifier' => (d['classes'] as List?)?.whereType<Map>().firstOrNull?['id'] as String?,
      'human-input' => (d['user_actions'] as List?)?.whereType<Map>().firstOrNull?['id'] as String?,
      _ => null,
    };
  }
}

/// One run's walk over the graph.
class _Walk {
  _Walk(
    this.svc,
    this.graph,
    this.run, {
    required this.inputs,
    required this.chat,
    required this.base,
    required this.tracings,
  });

  final MockWorkflowRunService svc;
  final RunGraph graph;
  final _ActiveRun run;
  final DifyJson inputs;
  final ChatMessageRequest? chat;
  final DifyJson Function(String event) base;
  final List<DifyJson> tracings;

  final pool = <String, DifyJson>{};
  String? error;
  var steps = 0, tokens = 0, exceptions = 0;
  double elapsed = 0;
  final answer = StringBuffer();
  final _ends = <String>[];

  MockRunScenario get s => svc.scenario;

  DifyJson workflowOutputs() => {for (final id in _ends) ...?pool[id]};

  RunEvent _ev(String event, DifyJson data) => RunEvent.fromJson({...base(event), 'data': data});

  /// The top-level graph from [entries].
  Stream<RunEvent> top(List<RunGraphNode> entries) => _graphFrom(entries, parentId: null);

  /// Runs the nodes of one level (top level or a container's children) from [entries], in topological order of
  /// the edges the run takes; nodes that become ready together start together (parallel branches).
  Stream<RunEvent> _graphFrom(
    List<RunGraphNode> entries, {
    required String? parentId,
    DifyJson extra = const {},
  }) async* {
    final nodes = {for (final n in graph.nodes.where((n) => n.parentId == parentId)) n.id: n};
    final edges = graph.edges.where((e) => nodes.containsKey(e.source) && nodes.containsKey(e.target)).toList();
    // Branch choices are known up front, so the edges the run takes and the nodes it reaches are too (a node
    // ending in an exception with a fail branch takes that branch).
    String handleOf(RunGraphNode n) {
      final failBranch = n.data['error_strategy'] == errorHandleFailBranch;
      if (failBranch && (s.exceptionNodeIds.contains(n.id) || s.failNodeId == n.id)) return errorHandleFailBranch;
      return svc._branch(n) ?? 'source';
    }

    final active = <RunGraphEdge>[];
    final reached = <String>{for (final e in entries) e.id};
    final queue = [...entries.map((e) => e.id)];
    while (queue.isNotEmpty) {
      final id = queue.removeAt(0);
      final handle = handleOf(nodes[id]!);
      for (final e in edges.where((e) => e.source == id)) {
        if (e.sourceHandle != handle && !(handle == 'source' && e.sourceHandle.isEmpty)) continue;
        active.add(e);
        if (reached.add(e.target)) queue.add(e.target);
      }
    }
    final waiting = {for (final id in reached) id: active.where((e) => e.target == id).map((e) => e.source).toSet()};
    final done = <String>{};
    var ready = [
      for (final id in reached)
        if (waiting[id]!.isEmpty) id,
    ];
    while (ready.isNotEmpty && error == null && !run.stopped) {
      final level = [for (final id in ready) nodes[id]!];
      final parallel = level.length > 1;
      final parallelId = parallel ? svc._id('parallel') : null;
      // Start the level's nodes together, then finish them in order.
      final started = <RunGraphNode, DifyJson>{};
      for (final n in level) {
        if (run.stopped) break;
        final predecessor = active.where((e) => e.target == n.id).map((e) => e.source).firstOrNull;
        final t = svc._tracing(
          n,
          index: ++steps,
          inputs: _inputsOf(n),
          at: svc._seconds,
          predecessor: predecessor,
        )..addAll(extra);
        if (parallelId != null) {
          t['parallel_id'] = parallelId;
          t['parallel_start_node_id'] = n.id;
          t['execution_metadata'] = {'parallel_id': parallelId, 'parallel_start_node_id': n.id};
        }
        started[n] = t;
        if (n.type == 'iteration' || n.type == 'loop') continue;
        await svc._wait();
        if (run.stopped) break;
        yield _ev('node_started', {...t});
      }
      for (final n in level) {
        final t = started[n];
        if (t == null || run.stopped) break;
        if (n.type == 'iteration' || n.type == 'loop') {
          yield* container(n, predecessor: t['predecessor_node_id'] as String?, tracing: t);
        } else {
          yield* _finish(n, t);
        }
        done.add(n.id);
        if (error != null) break;
      }
      ready = [
        for (final id in reached)
          if (!done.contains(id) && !ready.contains(id) && waiting[id]!.every(done.contains)) id,
      ];
    }
  }

  DifyJson _inputsOf(RunGraphNode n) => switch (n.type) {
    'start' => {...inputs, if (chat != null) 'sys.query': chat!.query},
    'end' || 'answer' || 'iteration-start' || 'loop-start' => const {},
    _ => {
      for (final e in n.data.entries)
        if (e.value is List && (e.value as List).length >= 2 && (e.value as List).every((x) => x is String))
          if (e.key.endsWith('selector')) e.key: svc._resolve(e.value, pool),
    },
  };

  /// node_retry events, then node_finished (and the streamed text / answer on the way).
  Stream<RunEvent> _finish(RunGraphNode n, DifyJson t) async* {
    final retries = s.retries[n.id] ?? 0;
    for (var i = 0; i < retries; i++) {
      await svc._wait();
      if (run.stopped) return;
      yield _ev('node_retry', {
        ...t,
        'id': svc._id('exec'),
        'status': NodeRunningStatus.retry,
        'error': 'Mock retry error',
        'retry_index': i + 1,
        'elapsed_time': 0.1,
        'finished_at': svc._seconds,
      });
    }
    if (n.type == 'human-input' && s.pauseNodeIds.contains(n.id)) {
      final token = svc._id('form-token');
      final resumed = run.resumed[n.id] = Completer<DifyJson>();
      svc._pausedTokens[token] = (run, n.id);
      final actions = (n.data['user_actions'] as List?)?.whereType<Map>().toList() ?? const [];
      await svc._wait();
      yield _ev('human_input_required', {
        'form_id': svc._id('form'),
        'node_id': n.id,
        'node_title': t['title'],
        'form_content': n.data['form_content'] ?? '',
        'inputs': n.data['inputs'] ?? const <Object?>[],
        'actions': actions,
        'form_token': token,
        'resolved_default_values': const <String, Object?>{},
        'display_in_ui': true,
        'expiration_time': svc._seconds + 3600,
      });
      yield _ev('workflow_paused', {
        'outputs': const <String, Object?>{},
        'paused_nodes': [n.id],
        'reasons': const <Object?>[],
        'workflow_run_id': run.runId,
      });
      final submitted = await Future.any([resumed.future, run.stop.future.then((_) => const <String, Object?>{})]);
      if (run.stopped) return;
      yield _ev('workflow_started', {'id': run.runId, 'workflow_id': 'mock-workflow', 'created_at': svc._seconds});
      final actionId = submitted['action'] as String? ?? svc._branch(n);
      yield _ev('human_input_form_filled', {
        'node_id': n.id,
        'node_title': t['title'],
        'rendered_content': n.data['form_content'] ?? '',
        'action_id': actionId,
        'action_text': actions.where((a) => a['id'] == actionId).firstOrNull?['title'] ?? actionId,
        'submitted_data': submitted['inputs'] ?? const <String, Object?>{},
      });
    }
    // Stream the model's text where an End / Answer shows it.
    if (svc._usesModel(n) && n.type != 'question-classifier' && n.type != 'parameter-extractor') {
      final shown = _shownBy(n.id);
      if (shown != null) {
        final text = s.llmText;
        for (var i = 0; i < text.length; i += s.chunkSize) {
          await svc._wait();
          if (run.stopped) return;
          final piece = text.substring(i, (i + s.chunkSize).clamp(0, text.length));
          if (chat != null) {
            answer.write(piece);
            yield RunEvent.fromJson({...base('message'), 'id': base('message')['message_id'], 'answer': piece});
          } else {
            yield _ev('text_chunk', {
              'text': piece,
              'from_variable_selector': [n.id, 'text'],
            });
          }
        }
      }
    }
    await svc._wait();
    if (run.stopped) return;
    final failed = s.failNodeId == n.id;
    final handlesErrors = const {'fail-branch', 'default-value'}.contains(n.data['error_strategy']);
    final exception = s.exceptionNodeIds.contains(n.id) || (failed && handlesErrors);
    final status = exception
        ? NodeRunningStatus.exception
        : failed
        ? NodeRunningStatus.failed
        : NodeRunningStatus.succeeded;
    final outputs = failed && !exception
        ? null
        : svc._outputs(n, t['inputs'] as DifyJson, pool, branch: svc._branch(n));
    if (outputs != null) pool[n.id] = outputs;
    if (n.type == 'end') _ends.add(n.id);
    if (n.type == 'answer' && chat != null && outputs != null) {
      // The Answer's own text beyond what was streamed.
      final a = outputs['answer'] as String? ?? '';
      final streamed = answer.toString();
      final rest = a.startsWith(streamed) ? a.substring(streamed.length) : (streamed.isEmpty ? a : '');
      if (rest.isNotEmpty) {
        answer.write(rest);
        yield RunEvent.fromJson({...base('message'), 'id': base('message')['message_id'], 'answer': rest});
      }
    }
    final meta = {...?(t['execution_metadata'] as Map?)?.cast<String, Object?>(), ...svc._metadata(n)};
    if (exception) meta['error_strategy'] = n.data['error_strategy'];
    tokens += (meta['total_tokens'] as int?) ?? 0;
    elapsed += 0.42;
    if (exception) exceptions++;
    final finished = {
      ...t,
      'status': status,
      'outputs': outputs,
      'process_data': svc._processData(n),
      'error': failed || exception ? s.failMessage : null,
      'elapsed_time': 0.42,
      'execution_metadata': meta,
      'finished_at': svc._seconds,
    };
    tracings.add(finished);
    svc._ran(n, finished);
    yield _ev('node_finished', finished);
    if (failed && !exception) error = s.failMessage;
  }

  /// The End / Answer node that shows [nodeId]'s `text`, if any.
  String? _shownBy(String nodeId) {
    for (final n in graph.nodes) {
      if (n.type == 'end') {
        final outs = (n.data['outputs'] as List?)?.whereType<Map>() ?? const [];
        if (outs.any((o) => (o['value_selector'] as List?)?.firstOrNull == nodeId)) return n.id;
      } else if (n.type == 'answer') {
        final a = n.data['answer'];
        if ((a is String && a.contains('{{#$nodeId.')) || (a is List && a.firstOrNull == nodeId)) return n.id;
      }
    }
    return null;
  }

  /// An iteration or loop: started, its rounds over its children, completed.
  Stream<RunEvent> container(RunGraphNode n, {required String? predecessor, DifyJson? tracing}) async* {
    final loop = n.type == 'loop';
    final t =
        tracing ?? svc._tracing(n, index: ++steps, inputs: _inputsOf(n), at: svc._seconds, predecessor: predecessor);
    final input = svc._resolve(n.data['iterator_selector'], pool);
    final rounds = loop ? s.loopLength : (input is List && input.isNotEmpty ? input.length : s.iterationLength);
    t['metadata'] = loop ? {'loop_length': rounds} : {'iterator_length': rounds};
    await svc._wait();
    if (run.stopped) return;
    yield _ev(loop ? 'loop_started' : 'iteration_started', {...t});
    final startType = loop ? 'loop-start' : 'iteration-start';
    final children = graph.nodes.where((c) => c.parentId == n.id).toList();
    final entry = children.where((c) => c.type == startType).toList();
    final durations = <String, double>{};
    final roundOutputs = <Object?>[];
    for (var i = 0; i < rounds; i++) {
      await svc._wait();
      if (run.stopped || error != null) return;
      yield _ev(loop ? 'loop_next' : 'iteration_next', {
        ...t,
        'index': i,
        if (!loop) 'pre_iteration_output': roundOutputs.isEmpty ? null : roundOutputs.last,
      });
      final extra = loop
          ? {
              'loop_id': n.id,
              'execution_metadata': {'loop_id': n.id, 'loop_index': i},
            }
          : {
              'iteration_id': n.id,
              'execution_metadata': {'iteration_id': n.id, 'iteration_index': i},
            };
      yield* _graphFrom(entry.isEmpty ? children.take(1).toList() : entry, parentId: n.id, extra: extra);
      durations['$i'] = 0.42 * children.length;
      roundOutputs.add(children.isEmpty ? null : pool[children.last.id]?.values.firstOrNull);
    }
    if (run.stopped) return;
    final outputs = loop ? <String, Object?>{} : {'output': roundOutputs};
    pool[n.id] = outputs;
    await svc._wait();
    final finished = {
      ...t,
      'status': error == null ? NodeRunningStatus.succeeded : NodeRunningStatus.failed,
      'outputs': outputs,
      'error': error,
      'elapsed_time': 0.42 * rounds,
      'execution_metadata': {
        'total_tokens': 0,
        if (loop) 'loop_duration_map': durations else 'iteration_duration_map': durations,
      },
      'finished_at': svc._seconds,
    };
    tracings.add(finished);
    svc._ran(n, finished);
    yield _ev(loop ? 'loop_completed' : 'iteration_completed', finished);
  }
}

class _MockInspectServices extends VariableInspectServices {
  const _MockInspectServices(this.svc);
  final MockWorkflowRunService svc;

  @override
  Future<List<DifyJson>> fetchAllInspectVars() async => [
    for (final vars in svc._inspect.values)
      for (final v in vars) svc._withEdit(v),
  ];

  @override
  Future<List<DifyJson>?> fetchNodeInspectVars(String nodeId) async => [
    for (final v in svc._inspect[nodeId] ?? const <DifyJson>[]) svc._withEdit(v),
  ];

  @override
  Future<List<DifyJson>> fetchSystemVars() async => [for (final v in svc._sysVars) svc._withEdit(v)];

  @override
  Future<void> editInspectVar(String varId, Object? value) async => svc._edited[varId] = value;

  @override
  Future<DifyJson?> resetToLastRunValue(String varId) async {
    svc._edited.remove(varId);
    for (final v in [...svc._inspect.values.expand((l) => l), ...svc._sysVars]) {
      if (v['id'] == varId) return v;
    }
    return null;
  }

  @override
  Future<void> deleteNodeInspectVars(String nodeId) async => svc._inspect.remove(nodeId);

  @override
  Future<void> deleteAllInspectVars() async {
    svc._inspect.clear();
    svc._edited.clear();
  }
}
