// dify-spec: web/app/components/workflow-app/hooks/__tests__/use-workflow-run-callbacks.spec.ts
// Not ported from these cases: text-to-speech playback (dify-sf has no audio player) and Amplitude tracking
// (`trackWorkflowRunFailed`); the rest of each case is.
import 'package:dify_sf_app/src/workflow_editor/run/run_events.dart';
import 'package:dify_sf_app/src/workflow_editor/run/run_graph.dart';
import 'package:dify_sf_app/src/workflow_editor/run/run_stream.dart';
import 'package:dify_sf_app/src/workflow_editor/run/workflow_run.dart';
import 'package:dify_sf_app/src/workflow_editor/run/workflow_run_events.dart';
import 'package:dify_sf_app/src/workflow_editor/store/workflow_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// `createHandlers()`: every handler records its calls.
class _Handlers extends WorkflowRunEvents {
  _Handlers() : super(store: WorkflowStore(), graph: const StaticRunGraph());
  final calls = <String, List<Object?>>{};
  void _rec(String name, [Object? args]) => (calls[name] ??= []).add(args);
  bool called(String name) => calls.containsKey(name);

  @override
  void handleWorkflowStarted(WorkflowStartedEvent params) => _rec('handleWorkflowStarted', params);
  @override
  void handleWorkflowFinished(WorkflowFinishedEvent params) => _rec('handleWorkflowFinished', params);
  @override
  void handleWorkflowFailed([String? error]) => _rec('handleWorkflowFailed', error);
  @override
  void handleWorkflowNodeStarted(NodeStartedEvent params, RunContainerSize container) =>
      _rec('handleWorkflowNodeStarted', (params.nodeId, container));
  @override
  void handleWorkflowNodeFinished(NodeFinishedEvent params) => _rec('handleWorkflowNodeFinished');
  @override
  void handleWorkflowNodeHumanInputRequired(HumanInputRequiredEvent params) =>
      _rec('handleWorkflowNodeHumanInputRequired');
  @override
  void handleWorkflowNodeHumanInputFormFilled(HumanInputFormFilledEvent params) =>
      _rec('handleWorkflowNodeHumanInputFormFilled');
  @override
  void handleWorkflowNodeHumanInputFormTimeout(HumanInputFormTimeoutEvent params) =>
      _rec('handleWorkflowNodeHumanInputFormTimeout');
  @override
  void handleWorkflowNodeIterationStarted(IterationStartedEvent params, RunContainerSize container) =>
      _rec('handleWorkflowNodeIterationStarted', (params.nodeId, container));
  @override
  void handleWorkflowNodeIterationNext(IterationNextEvent params) => _rec('handleWorkflowNodeIterationNext');
  @override
  void handleWorkflowNodeIterationFinished(IterationCompletedEvent params) =>
      _rec('handleWorkflowNodeIterationFinished');
  @override
  void handleWorkflowNodeLoopStarted(LoopStartedEvent params, RunContainerSize container) =>
      _rec('handleWorkflowNodeLoopStarted', (params.nodeId, container));
  @override
  void handleWorkflowNodeLoopNext(LoopNextEvent params) => _rec('handleWorkflowNodeLoopNext');
  @override
  void handleWorkflowNodeLoopFinished(LoopCompletedEvent params) => _rec('handleWorkflowNodeLoopFinished');
  @override
  void handleWorkflowNodeRetry(NodeRetryEvent params) => _rec('handleWorkflowNodeRetry');
  @override
  void handleWorkflowAgentLog(AgentLogEvent params) => _rec('handleWorkflowAgentLog');
  @override
  void handleWorkflowTextChunk(TextChunkEvent params) => _rec('handleWorkflowTextChunk');
  @override
  void handleWorkflowTextReplace(TextReplaceEvent params) => _rec('handleWorkflowTextReplace');
  @override
  void handleWorkflowReasoning(ReasoningChunkEvent params) => _rec('handleWorkflowReasoning');
  @override
  void handleWorkflowPaused() => _rec('handleWorkflowPaused');
}

/// `vi.fn()`s.
class _Spy {
  final calls = <String, List<Object?>>{};
  VoidCallback fn(String name) =>
      () => (calls[name] ??= []).add(null);
  int count(String name) => calls[name]?.length ?? 0;
}

typedef VoidCallback = void Function();

/// `createUserCallbacks()`.
RunCallbacks _userCallbacks(Map<String, List<Object?>> calls) {
  void rec(String n, [Object? a]) => (calls[n] ??= []).add(a);
  return RunCallbacks(
    onWorkflowStarted: (_) => rec('onWorkflowStarted'),
    onWorkflowFinished: (_) => rec('onWorkflowFinished'),
    onNodeStarted: (_) => rec('onNodeStarted'),
    onNodeFinished: (_) => rec('onNodeFinished'),
    onIterationStart: (_) => rec('onIterationStart'),
    onIterationNext: (_) => rec('onIterationNext'),
    onIterationFinish: (_) => rec('onIterationFinish'),
    onLoopStart: (_) => rec('onLoopStart'),
    onLoopNext: (_) => rec('onLoopNext'),
    onLoopFinish: (_) => rec('onLoopFinish'),
    onNodeRetry: (_) => rec('onNodeRetry'),
    onAgentLog: (_) => rec('onAgentLog'),
    onError: (m, [code]) => rec('onError', (m, code)),
    onWorkflowPaused: (_) => rec('onWorkflowPaused'),
    onHumanInputRequired: (_) => rec('onHumanInputRequired'),
    onHumanInputFormFilled: (_) => rec('onHumanInputFormFilled'),
    onHumanInputFormTimeout: (_) => rec('onHumanInputFormTimeout'),
    onCompleted: ([hasError = false, message]) => rec('onCompleted', (hasError, message)),
  );
}

const _node = {
  'data': {'node_id': 'node-1'},
};

void main() {
  group('useWorkflowRun callbacks helpers', () {
    late _Spy spy;
    late List<(String, RunCallbacks)> resumed;

    setUp(() {
      spy = _Spy();
      resumed = [];
    });

    WorkflowRunCallbackContext ctx(
      _Handlers handlers, {
      double w = 320,
      double h = 240,
      bool debug = true,
      RunCallbacks callbacks = const RunCallbacks(),
      RunCallbacks restCallback = const RunCallbacks(),
    }) => WorkflowRunCallbackContext(
      container: () => (clientWidth: w, clientHeight: h),
      isInWorkflowDebug: debug,
      fetchInspectVars: spy.fn('fetchInspectVars'),
      invalidAllLastRun: spy.fn('invalidAllLastRun'),
      invalidateRunHistory: spy.fn('invalidateRunHistory'),
      clearAbortController: spy.fn('clearAbortController'),
      clearListeningState: spy.fn('clearListeningState'),
      handlers: handlers,
      resume: (runId, cb) => resumed.add((runId, cb)),
      callbacks: callbacks,
      restCallback: restCallback,
    );

    test(
      'should create base callbacks that wrap workflow events, errors, pause continuation, and lazy tts playback',
      () {
        final handlers = _Handlers();
        final user = <String, List<Object?>>{};
        final callbacks = createBaseWorkflowRunCallbacks(
          ctx(
            handlers,
            callbacks: RunCallbacks(
              onWorkflowFinished: (_) => (user['onWorkflowFinished'] ??= []).add(null),
              onError: (m, [_]) => (user['onError'] ??= []).add(m),
              onWorkflowPaused: (_) => (user['onWorkflowPaused'] ??= []).add(null),
            ),
          ),
        );

        callbacks.onWorkflowFinished!(const WorkflowFinishedEvent({'workflow_run_id': 'run-1'}));
        expect(spy.count('clearListeningState'), 1);
        expect(handlers.called('handleWorkflowFinished'), isTrue);
        expect(spy.count('invalidateRunHistory'), 1);
        expect(user['onWorkflowFinished'], hasLength(1));
        expect(spy.count('fetchInspectVars'), 1);
        expect(spy.count('invalidAllLastRun'), 1);

        callbacks.onError!('LLM provider and model are required.');
        expect(spy.count('clearAbortController'), 1);
        expect(handlers.calls['handleWorkflowFailed'], ['LLM provider and model are required.']);
        expect(user['onError'], ['LLM provider and model are required.']);

        callbacks.onWorkflowPaused!(const WorkflowPausedEvent({'workflow_run_id': 'run-2'}));
        callbacks.onWorkflowPaused!(const WorkflowPausedEvent({'workflow_run_id': 'run-2'}));
        expect(handlers.called('handleWorkflowPaused'), isTrue);
        expect(user['onWorkflowPaused'], hasLength(2));
        expect(resumed, hasLength(1));
        expect(resumed.single.$1, 'run-2');
        expect(identical(resumed.single.$2, callbacks), isTrue);
      },
    );

    test(
      'should create final callbacks that preserve rest callback override order and eager abort-controller wiring',
      () {
        final handlers = _Handlers();
        var restOnNodeStarted = 0;
        RunStreamHandle? set;
        final base = createBaseWorkflowRunCallbacks(ctx(handlers, debug: false));
        final finalCallbacks = createFinalWorkflowRunCallbacks(
          ctx(handlers, debug: false, restCallback: RunCallbacks(onNodeStarted: (_) => restOnNodeStarted++)),
          baseSseOptions: base,
          setAbortController: (h) => set = h,
        );
        final controller = RunStreamHandle();
        finalCallbacks.getAbortController!(controller);
        expect(set, same(controller));
        finalCallbacks.onNodeStarted!(const NodeStartedEvent(_node));
        expect(restOnNodeStarted, 1);
        expect(handlers.called('handleWorkflowNodeStarted'), isFalse);
      },
    );

    test('should route base workflow events through handlers, user callbacks, and pause continuation with the same callback object', () {
      final handlers = _Handlers();
      final user = <String, List<Object?>>{};
      final callbacks = createBaseWorkflowRunCallbacks(ctx(handlers, w: 640, h: 360, callbacks: _userCallbacks(user)));

      callbacks.onWorkflowStarted!(const WorkflowStartedEvent({'workflow_run_id': 'run-1'}));
      callbacks.onNodeStarted!(const NodeStartedEvent(_node));
      callbacks.onNodeFinished!(const NodeFinishedEvent(_node));
      callbacks.onIterationStart!(const IterationStartedEvent(_node));
      callbacks.onIterationNext!(const IterationNextEvent(_node));
      callbacks.onIterationFinish!(const IterationCompletedEvent(_node));
      callbacks.onLoopStart!(const LoopStartedEvent(_node));
      callbacks.onLoopNext!(const LoopNextEvent(_node));
      callbacks.onLoopFinish!(const LoopCompletedEvent(_node));
      callbacks.onNodeRetry!(const NodeRetryEvent(_node));
      callbacks.onAgentLog!(const AgentLogEvent(_node));
      callbacks.onTextChunk!(const TextChunkEvent({'data': 'chunk'}));
      callbacks.onTextReplace!(const TextReplaceEvent({'text': 'replacement'}));
      callbacks.onReasoning!(
        const ReasoningChunkEvent({
          'data': {'reasoning': 'thinking', 'node_id': 'node-1'},
        }),
      );
      callbacks.onHumanInputRequired!(const HumanInputRequiredEvent(_node));
      callbacks.onHumanInputFormFilled!(const HumanInputFormFilledEvent(_node));
      callbacks.onHumanInputFormTimeout!(const HumanInputFormTimeoutEvent(_node));
      callbacks.onWorkflowFinished!(const WorkflowFinishedEvent({'workflow_run_id': 'run-1'}));
      callbacks.onCompleted!(false, '');
      callbacks.onWorkflowPaused!(const WorkflowPausedEvent({'workflow_run_id': 'run-2'}));
      callbacks.onWorkflowPaused!(const WorkflowPausedEvent({'workflow_run_id': 'run-2'}));
      callbacks.onError!('failed', '500');

      const container = (clientWidth: 640.0, clientHeight: 360.0);
      expect(handlers.called('handleWorkflowStarted'), isTrue);
      expect(user['onWorkflowStarted'], isNotNull);
      expect(handlers.calls['handleWorkflowNodeStarted'], [('node-1', container)]);
      expect(handlers.calls['handleWorkflowNodeIterationStarted'], [('node-1', container)]);
      expect(handlers.calls['handleWorkflowNodeLoopStarted'], [('node-1', container)]);
      for (final name in [
        'handleWorkflowNodeFinished',
        'handleWorkflowNodeIterationNext',
        'handleWorkflowNodeIterationFinished',
        'handleWorkflowNodeLoopNext',
        'handleWorkflowNodeLoopFinished',
        'handleWorkflowNodeRetry',
        'handleWorkflowAgentLog',
        'handleWorkflowTextChunk',
        'handleWorkflowTextReplace',
        'handleWorkflowReasoning',
        'handleWorkflowNodeHumanInputRequired',
        'handleWorkflowNodeHumanInputFormFilled',
        'handleWorkflowNodeHumanInputFormTimeout',
        'handleWorkflowFinished',
        'handleWorkflowPaused',
        'handleWorkflowFailed',
      ]) {
        expect(handlers.called(name), isTrue, reason: name);
      }
      for (final name in [
        'onNodeStarted',
        'onNodeFinished',
        'onIterationStart',
        'onIterationNext',
        'onIterationFinish',
        'onLoopStart',
        'onLoopNext',
        'onLoopFinish',
        'onNodeRetry',
        'onAgentLog',
        'onHumanInputRequired',
        'onHumanInputFormFilled',
        'onHumanInputFormTimeout',
        'onWorkflowFinished',
        'onWorkflowPaused',
      ]) {
        expect(user[name], isNotNull, reason: name);
      }
      expect(spy.count('clearListeningState'), greaterThan(0));
      expect(spy.count('fetchInspectVars'), 1);
      expect(spy.count('invalidAllLastRun'), 1);
      expect(user['onCompleted'], [(false, '')]);
      expect(resumed, hasLength(1));
      expect(resumed.single.$1, 'run-2');
      expect(identical(resumed.single.$2, callbacks), isTrue);
      expect(spy.count('clearAbortController'), greaterThan(0));
      expect(user['onError'], [('failed', '500')]);
      expect(spy.count('invalidateRunHistory'), greaterThan(0));
    });

    test('should skip base debug-only side effects and audio playback when debug mode is off or audio is empty', () {
      final handlers = _Handlers();
      final callbacks = createBaseWorkflowRunCallbacks(ctx(handlers, debug: false));
      callbacks.onWorkflowFinished!(const WorkflowFinishedEvent({'workflow_run_id': 'run-1'}));
      expect(spy.count('fetchInspectVars'), 0);
      expect(spy.count('invalidAllLastRun'), 0);
    });

    test('should route final workflow events through handlers and continue paused runs with final callbacks', () {
      final handlers = _Handlers();
      final user = <String, List<Object?>>{};
      final baseSpy = _Spy();
      final base = createBaseWorkflowRunCallbacks(
        WorkflowRunCallbackContext(
          container: () => (clientWidth: 480, clientHeight: 320),
          isInWorkflowDebug: false,
          fetchInspectVars: baseSpy.fn('fetchInspectVars'),
          invalidAllLastRun: baseSpy.fn('invalidAllLastRun'),
          invalidateRunHistory: baseSpy.fn('invalidateRunHistory'),
          clearAbortController: baseSpy.fn('clearAbortController'),
          clearListeningState: baseSpy.fn('clearListeningState'),
          handlers: handlers,
          resume: (_, _) => fail('the base callbacks do not continue the run'),
        ),
      );
      var setAbort = 0;
      final finalCallbacks = createFinalWorkflowRunCallbacks(
        ctx(handlers, w: 480, h: 320, callbacks: _userCallbacks(user)),
        baseSseOptions: base,
        setAbortController: (_) => setAbort++,
      );

      finalCallbacks.getAbortController!(RunStreamHandle());
      finalCallbacks.onWorkflowFinished!(const WorkflowFinishedEvent({'workflow_run_id': 'run-1'}));
      finalCallbacks.onNodeStarted!(const NodeStartedEvent(_node));
      finalCallbacks.onNodeFinished!(const NodeFinishedEvent(_node));
      finalCallbacks.onIterationStart!(const IterationStartedEvent(_node));
      finalCallbacks.onIterationNext!(const IterationNextEvent(_node));
      finalCallbacks.onIterationFinish!(const IterationCompletedEvent(_node));
      finalCallbacks.onLoopStart!(const LoopStartedEvent(_node));
      finalCallbacks.onLoopNext!(const LoopNextEvent(_node));
      finalCallbacks.onLoopFinish!(const LoopCompletedEvent(_node));
      finalCallbacks.onNodeRetry!(const NodeRetryEvent(_node));
      finalCallbacks.onAgentLog!(const AgentLogEvent(_node));
      finalCallbacks.onTextChunk!(const TextChunkEvent({'data': 'chunk'}));
      finalCallbacks.onTextReplace!(const TextReplaceEvent({'text': 'replacement'}));
      finalCallbacks.onReasoning!(
        const ReasoningChunkEvent({
          'data': {'reasoning': 'thinking', 'node_id': 'node-1'},
        }),
      );
      finalCallbacks.onHumanInputRequired!(const HumanInputRequiredEvent(_node));
      finalCallbacks.onHumanInputFormFilled!(const HumanInputFormFilledEvent(_node));
      finalCallbacks.onHumanInputFormTimeout!(const HumanInputFormTimeoutEvent(_node));
      finalCallbacks.onWorkflowPaused!(const WorkflowPausedEvent({'workflow_run_id': 'run-2'}));
      finalCallbacks.onWorkflowPaused!(const WorkflowPausedEvent({'workflow_run_id': 'run-2'}));
      finalCallbacks.onCompleted!(true, 'done');
      finalCallbacks.onError!('failed', '500');

      const container = (clientWidth: 480.0, clientHeight: 320.0);
      expect(setAbort, 1);
      expect(handlers.called('handleWorkflowFinished'), isTrue);
      expect(user['onWorkflowFinished'], isNotNull);
      expect(spy.count('fetchInspectVars'), 1);
      expect(spy.count('invalidAllLastRun'), 1);
      expect(handlers.calls['handleWorkflowNodeStarted'], [('node-1', container)]);
      expect(handlers.calls['handleWorkflowNodeIterationStarted'], [('node-1', container)]);
      expect(handlers.calls['handleWorkflowNodeLoopStarted'], [('node-1', container)]);
      for (final name in [
        'onNodeStarted',
        'onNodeFinished',
        'onIterationStart',
        'onIterationNext',
        'onIterationFinish',
        'onLoopStart',
        'onLoopNext',
        'onLoopFinish',
        'onNodeRetry',
        'onAgentLog',
        'onHumanInputRequired',
        'onHumanInputFormFilled',
        'onHumanInputFormTimeout',
        'onWorkflowPaused',
      ]) {
        expect(user[name], isNotNull, reason: name);
      }
      for (final name in [
        'handleWorkflowTextChunk',
        'handleWorkflowTextReplace',
        'handleWorkflowReasoning',
        'handleWorkflowNodeHumanInputRequired',
        'handleWorkflowNodeHumanInputFormFilled',
        'handleWorkflowNodeHumanInputFormTimeout',
        'handleWorkflowPaused',
        'handleWorkflowFailed',
      ]) {
        expect(handlers.called(name), isTrue, reason: name);
      }
      expect(resumed, hasLength(1));
      expect(resumed.single.$1, 'run-2');
      expect(identical(resumed.single.$2, finalCallbacks), isTrue);
      expect(spy.count('clearAbortController'), 1);
      expect(spy.count('clearListeningState'), 1);
      expect(user['onError'], [('failed', '500')]);
      expect(spy.count('invalidateRunHistory'), greaterThan(0));
    });
  });
}
