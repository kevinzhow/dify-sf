import 'dart:async';

import '../client/transport.dart';
import '../workflow_run_api.dart';

/// An in-memory [WorkflowRunApi] (protocol 1.13) for tests and demos: [run] decides each execution (by default a
/// succeeded one echoing the inputs); executions become the node's last run, as on the server. [calls] records every
/// request (`run` or `last-run`, app, node, body).
///
/// Draft runs (1.14): [draftRunEvents] decides a run's events (by default `workflow_started` and a succeeded
/// `workflow_finished` echoing the inputs); each run lands in the history; [stopped] records stop calls. Draft
/// variables live in [variables] (id -> Dify's JSON with `node_id` / `name` / `value`).
class FakeWorkflowRunApi implements WorkflowRunApi {
  FakeWorkflowRunApi({
    Map<String, Object?> Function(String appId, String nodeId, Map<String, Object?> body)? run,
    List<Map<String, Object?>> Function(String appId, String runId, Map<String, Object?> body)? draftRunEvents,
  }) : run = run ?? _echo,
       draftRunEvents = draftRunEvents ?? _echoRun;

  Map<String, Object?> Function(String appId, String nodeId, Map<String, Object?> body) run;

  final calls = <({String op, String appId, String nodeId, Map<String, Object?>? body})>[];
  final _last = <String, Map<String, Object?>>{};
  var _n = 0;

  static Map<String, Object?> _echo(String appId, String nodeId, Map<String, Object?> body) => {
    'node_id': nodeId,
    'status': 'succeeded',
    'inputs': body['inputs'],
    'outputs': {'text': 'fake run of $nodeId'},
    'error': null,
    'elapsed_time': 0.01,
    'execution_metadata': {'total_tokens': 0},
  };

  @override
  Future<Map<String, Object?>> singleNodeRun(String appId, String nodeId, Map<String, Object?> body) async {
    calls.add((op: 'run', appId: appId, nodeId: nodeId, body: body));
    final result = {'id': 'exec-${++_n}', 'index': 1, ...run(appId, nodeId, body)};
    _last['$appId/$nodeId'] = result;
    return result;
  }

  @override
  Future<Map<String, Object?>?> nodeLastRun(String appId, String nodeId) async {
    calls.add((op: 'last-run', appId: appId, nodeId: nodeId, body: null));
    return _last['$appId/$nodeId'];
  }

  List<Map<String, Object?>> Function(String appId, String runId, Map<String, Object?> body) draftRunEvents;
  final stopped = <String>[];
  final _runs = <String, List<Map<String, Object?>>>{};
  final _runDetails = <String, Map<String, Object?>>{};

  /// Draft variables by id: Dify's item JSON (`id`, `type`, `name`, `selector`, `value_type`, `value`, `edited`, ...)
  /// plus `node_id` for grouping.
  final variables = <String, Map<String, Object?>>{};

  static List<Map<String, Object?>> _echoRun(String appId, String runId, Map<String, Object?> body) => [
    {
      'event': 'workflow_started',
      'workflow_run_id': runId,
      'task_id': runId,
      'data': {'id': runId, 'workflow_id': appId, 'inputs': body['inputs'], 'created_at': 0, 'reason': 'initial'},
    },
    {
      'event': 'workflow_finished',
      'workflow_run_id': runId,
      'task_id': runId,
      'data': {
        'id': runId,
        'workflow_id': appId,
        'status': 'succeeded',
        'outputs': body['inputs'],
        'error': null,
        'elapsed_time': 0.01,
        'total_tokens': 0,
        'total_steps': 0,
        'created_at': 0,
        'finished_at': 0,
        'exceptions_count': 0,
        'files': <Object?>[],
      },
    },
  ];

  @override
  Stream<Map<String, Object?>> draftRun(String appId, Map<String, Object?> body) =>
      _streamRun(appId, body, op: 'draft-run');

  @override
  Stream<Map<String, Object?>> iterationSingleRun(String appId, String nodeId, Map<String, Object?> body) =>
      _streamRun(appId, body, op: 'iteration-run', nodeId: nodeId);

  @override
  Stream<Map<String, Object?>> loopSingleRun(String appId, String nodeId, Map<String, Object?> body) =>
      _streamRun(appId, body, op: 'loop-run', nodeId: nodeId);

  Stream<Map<String, Object?>> _streamRun(
    String appId,
    Map<String, Object?> body, {
    required String op,
    String nodeId = '',
  }) async* {
    final runId = 'run-${++_n}';
    calls.add((op: op, appId: appId, nodeId: nodeId, body: body));
    final events = draftRunEvents(appId, runId, body);
    _runs.putIfAbsent(appId, () => []).insert(0, {'id': runId, 'version': 'draft', 'status': 'running'});
    for (final e in events) {
      if (e['event'] == 'workflow_finished' && e['data'] is Map<String, Object?>) {
        final d = e['data']! as Map<String, Object?>;
        _runs[appId]!.first['status'] = d['status'];
        _runDetails[runId] = {'id': runId, ...d};
      }
      yield e;
    }
  }

  @override
  Future<void> stopRun(String appId, String taskId) async => stopped.add(taskId);

  @override
  Future<Map<String, Object?>> runHistory(String appId, {String? lastId, int limit = 20}) async {
    final all = _runs[appId] ?? const [];
    final start = lastId == null ? 0 : all.indexWhere((r) => r['id'] == lastId) + 1;
    final page = all.skip(start).take(limit).toList();
    return {'limit': limit, 'has_more': start + page.length < all.length, 'data': page};
  }

  @override
  Future<Map<String, Object?>> runDetail(String appId, String runId) async =>
      _runDetails[runId] ?? refuse('not_found', 'Workflow run not found', status: 404);

  @override
  Future<List<Map<String, Object?>>> runNodeExecutions(String appId, String runId) async => const [];

  @override
  Future<Map<String, Object?>> draftVariables(String appId, {int page = 1, int limit = 20}) async {
    final all = variables.values.toList();
    return {'items': all.skip((page - 1) * limit).take(limit).toList(), 'total': page == 1 ? all.length : null};
  }

  @override
  Future<List<Map<String, Object?>>> nodeVariables(String appId, String nodeId) async =>
      variables.values.where((v) => v['node_id'] == nodeId).toList();

  @override
  Future<List<Map<String, Object?>>> draftVariablesOfKind(String appId, String kind) async {
    final type = switch (kind) {
      'conversation' => 'conversation',
      'system' => 'sys',
      _ => 'env',
    };
    return variables.values.where((v) => v['type'] == type).toList();
  }

  @override
  Future<Map<String, Object?>> draftVariable(String appId, String variableId) async =>
      variables[variableId] ?? refuse('not_found', 'variable not found, id=$variableId', status: 404);

  @override
  Future<Map<String, Object?>> updateDraftVariable(String appId, String variableId, Map<String, Object?> patch) async {
    final v = variables[variableId] ?? refuse('not_found', 'variable not found, id=$variableId', status: 404);
    return variables[variableId] = {...v, ...patch, 'edited': true};
  }

  @override
  Future<Map<String, Object?>?> resetDraftVariable(String appId, String variableId) async {
    final v = variables[variableId] ?? refuse('not_found', 'variable not found, id=$variableId', status: 404);
    return variables[variableId] = {...v, 'edited': false};
  }

  @override
  Future<void> deleteDraftVariables(String appId, {String? variableId, String? nodeId}) async {
    if (variableId != null) {
      variables.remove(variableId);
    } else if (nodeId != null) {
      variables.removeWhere((_, v) => v['node_id'] == nodeId);
    } else {
      variables.clear();
    }
  }

  /// Makes the next runs fail the way the server refuses a request (`400 invalid_param` and the like).
  static Never refuse(String code, String message, {int status = 400}) =>
      throw TransportException(message, statusCode: status, code: code);

  // ---- human input (1.16) ----

  /// Forms by token, their definitions Dify's `GET /v1/form/human_input/{token}` answers.
  final humanInputForms = <String, Map<String, Object?>>{};

  /// The bodies [submitHumanInputForm] received, by token.
  final humanInputAnswers = <String, Map<String, Object?>>{};

  /// What [workflowEvents] streams for a run (the frames after the pause, as [draftRunEvents] would write them).
  final humanInputEvents = <String, List<Map<String, Object?>>>{};

  /// Every reconnect ([WorkflowRunApi.workflowEvents]) with the flags it asked for.
  final reconnects = <({String runId, bool includeStateSnapshot, bool continueOnPause})>[];

  /// A reconnect that should wait for the answer, as the server's does: [humanInputGates] by run, opened by the
  /// submission of [humanInputFormRuns]' token.
  final humanInputGates = <String, Completer<void>>{};
  final humanInputFormRuns = <String, String>{};

  /// The previews and submissions of a human-input node's own form (`url` → body that was sent).
  final formPreviews = <String, Map<String, Object?>>{};
  final formRuns = <String, Map<String, Object?>>{};

  /// Delivery tests (`nodeId` → the body the panel sent).
  final deliveryTests = <String, Map<String, Object?>>{};

  /// The form a preview answers (`url` → definition), else a bare one.
  final formDefinitions = <String, Map<String, Object?>>{};

  @override
  Future<Map<String, Object?>> humanInputForm(String token) async =>
      humanInputForms[token] ?? refuse('not_found', 'Form not found', status: 404);

  @override
  Future<void> submitHumanInputForm(String token, Map<String, Object?> body) async {
    if (!humanInputForms.containsKey(token)) refuse('not_found', 'Form not found', status: 404);
    humanInputAnswers[token] = body;
    // The answer wakes the run: a gated reconnect goes on.
    if (humanInputFormRuns[token] case final run?) {
      if (humanInputGates[run] case final gate? when !gate.isCompleted) gate.complete();
    }
  }

  @override
  Stream<Map<String, Object?>> workflowEvents(
    String runId, {
    bool includeStateSnapshot = true,
    bool continueOnPause = true,
  }) async* {
    reconnects.add((runId: runId, includeStateSnapshot: includeStateSnapshot, continueOnPause: continueOnPause));
    if (humanInputGates[runId] case final gate?) await gate.future;
    yield* Stream.fromIterable(humanInputEvents[runId] ?? const []);
  }

  @override
  Future<Map<String, Object?>> humanInputFormPreview(String url, Map<String, Object?> body) async {
    formPreviews[url] = body;
    return formDefinitions[url] ?? const {
      'form_id': 'node',
      'form_content': 'Form content',
      'inputs': <Object?>[],
      'actions': <Object?>[],
      'node_id': 'node',
      'node_title': 'Human Input',
      'resolved_default_values': <String, Object?>{},
    };
  }

  @override
  Future<void> humanInputDeliveryTest(String appId, String nodeId, Map<String, Object?> body) async {
    deliveryTests[nodeId] = body;
  }

  @override
  Future<Map<String, Object?>> humanInputFormRun(String url, Map<String, Object?> body) async {
    formRuns[url] = body;
    return {'__action_id': body['action'], '__action_value': body['action'], '__rendered_content': 'Form content'};
  }
}
