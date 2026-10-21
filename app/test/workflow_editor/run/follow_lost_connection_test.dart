// The run follow's two ways of losing a connection, deterministically (no server): a stream that **ends cleanly**
// without a terminal event, and a stream that **throws** a connection error. Both must reopen the stream instead of
// ending the run; and once the page is disposed, no queued retry may make another request or touch a disposed notifier.
import 'dart:async';

import 'package:dify_sf_app/src/workflow_editor/run/mock_run_service.dart';
import 'package:dify_sf_app/src/workflow_editor/run/run_events.dart';
import 'package:dify_sf_app/src/workflow_editor/run/run_graph.dart';
import 'package:dify_sf_app/src/workflow_editor/run/run_stream.dart';
import 'package:dify_sf_app/src/workflow_editor/run/workflow_run.dart';
import 'package:dify_sf_app/src/workflow_editor/store/workflow_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// start → human → end: enough for a run to pause and be answered.
const _graph = StaticRunGraph(
  nodes: [
    RunGraphNode(id: 'start', type: 'start', title: 'Start', data: {'type': 'start', 'title': 'Start'}),
    RunGraphNode(id: 'human', type: 'human-input', title: 'Approve', data: {'type': 'human-input', 'title': 'Approve'}),
    RunGraphNode(id: 'end', type: 'end', title: 'End', data: {'type': 'end', 'title': 'End'}),
  ],
  edges: [RunGraphEdge(id: 'e1', source: 'start', target: 'human'), RunGraphEdge(id: 'e2', source: 'human', target: 'end')],
);

/// A service whose event stream is scripted: [events] answers the n-th attempt (`attempts` counts them).
class ScriptedRunService extends MockWorkflowRunService {
  ScriptedRunService(this.events) : super(graph: () => _graph);

  final Stream<RunEvent> Function(int attempt) events;
  int attempts = 0;

  @override
  Stream<RunEvent> workflowEvents(String workflowRunId, {bool includeStateSnapshot = true, bool continueOnPause = true}) {
    attempts++;
    return events(attempts);
  }
}

void main() {
  test('a stream that ends cleanly without a terminal event is reopened', () async {
    final service = ScriptedRunService((n) async* {
      if (n == 1) {
        yield const WorkflowStartedEvent({'event': 'workflow_started', 'data': <String, Object?>{}});
        return; // EOF: the connection died without ending the run
      }
      yield const WorkflowFinishedEvent({'event': 'workflow_finished', 'data': {'status': 'succeeded'}});
    });
    final run = WorkflowRunController(store: WorkflowStore(), service: service, graph: _graph);
    run.retriesLostConnections = true;
    var failures = 0;
    final finished = Completer<String>();
    final handle = run.debugFollow(
      'run-1',
      RunCallbacks(
        onWorkflowFinished: (e) => finished.complete('${e.data['status']}'),
        onError: (m, [c]) => failures++,
      ),
    );
    expect(await finished.future.timeout(const Duration(seconds: 5)), 'succeeded');
    expect(service.attempts, greaterThanOrEqualTo(2), reason: 'the clean end was a lost connection, not the run');
    expect(failures, 0, reason: 'a lost connection is not the run failing');
    handle.abort();
  });

  test('a stream that throws a connection error is reopened', () async {
    final service = ScriptedRunService((n) {
      if (n == 1) return Stream<RunEvent>.error(Exception('GET /v1/workflow/run-1/events ended: ClientException: Connection closed'));
      return Stream<RunEvent>.value(const WorkflowFinishedEvent({'event': 'workflow_finished', 'data': {'status': 'succeeded'}}));
    });
    final run = WorkflowRunController(store: WorkflowStore(), service: service, graph: _graph);
    run.retriesLostConnections = true;
    final finished = Completer<String>();
    var failures = 0;
    final handle = run.debugFollow(
      'run-1',
      RunCallbacks(
        onWorkflowFinished: (e) => finished.complete('${e.data['status']}'),
        onError: (m, [c]) => failures++,
      ),
    );
    expect(await finished.future.timeout(const Duration(seconds: 5)), 'succeeded');
    expect(service.attempts, greaterThanOrEqualTo(2));
    expect(failures, 0);
    handle.abort();
  });

  test('a run that reports failed ends the follow as failed (no retry)', () async {
    final service = ScriptedRunService((n) => Stream<RunEvent>.value(
        const WorkflowFinishedEvent({'event': 'workflow_finished', 'data': {'status': 'failed'}})));
    final run = WorkflowRunController(store: WorkflowStore(), service: service, graph: _graph);
    final finished = Completer<String>();
    final handle = run.debugFollow('run-1', RunCallbacks(onWorkflowFinished: (e) => finished.complete('${e.data['status']}')));
    expect(await finished.future.timeout(const Duration(seconds: 5)), 'failed');
    await Future<void>.delayed(const Duration(milliseconds: 800));
    expect(service.attempts, 1, reason: 'a finished run is not a lost connection');
    handle.abort();
  });

  test('after dispose a queued retry makes no request and touches no disposed notifier', () async {
    final service = ScriptedRunService((n) => Stream<RunEvent>.empty());
    final run = WorkflowRunController(store: WorkflowStore(), service: service, graph: _graph);
    run.debugFollow('run-1', const RunCallbacks());
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final before = service.attempts;
    expect(before, greaterThanOrEqualTo(1));
    run.dispose();
    // Past the first backoff (500 ms) and well beyond: nothing more may be opened.
    await Future<void>.delayed(const Duration(seconds: 2));
    expect(service.attempts, before, reason: 'a disposed page makes no further request');
  });
}
