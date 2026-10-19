import '../client/transport.dart';
import '../workflow_run_api.dart';

/// An in-memory [WorkflowRunApi] (protocol 1.13) for tests and demos: [run] decides each execution (by default a
/// succeeded one echoing the inputs); executions become the node's last run, as on the server. [calls] records every
/// request (`run` or `last-run`, app, node, body).
class FakeWorkflowRunApi implements WorkflowRunApi {
  FakeWorkflowRunApi({Map<String, Object?> Function(String appId, String nodeId, Map<String, Object?> body)? run})
    : run = run ?? _echo;

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

  /// Makes the next runs fail the way the server refuses a request (`400 invalid_param` and the like).
  static Never refuse(String code, String message, {int status = 400}) =>
      throw TransportException(message, statusCode: status, code: code);
}
