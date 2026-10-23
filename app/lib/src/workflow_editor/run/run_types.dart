/// Run constants and the run states of Dify 1.17.1 (workflow/types.ts NodeRunningStatus / WorkflowRunningStatus,
/// workflow/constants.ts, workflow-app/hooks/use-workflow-run-utils.ts' state factories).
library;

import '../header/header_data.dart' show WorkflowRunningStatus;
import '../store/workflow_store.dart' show DifyJson;

export '../header/header_data.dart' show WorkflowRunningStatus, runningStatusOf;

/// `NodeRunningStatus` (workflow/types.ts).
abstract final class NodeRunningStatus {
  static const notStart = 'not-start';
  static const waiting = 'waiting';
  static const listening = 'listening';
  static const running = 'running';
  static const succeeded = 'succeeded';
  static const failed = 'failed';
  static const exception = 'exception';
  static const retry = 'retry';
  static const stopped = 'stopped';
  static const paused = 'paused';
}

/// `DEFAULT_ITER_TIMES` / `DEFAULT_LOOP_TIMES` (constants.ts).
const defaultIterTimes = 1;
const defaultLoopTimes = 1;

/// `ErrorHandleTypeEnum.failBranch`.
const errorHandleFailBranch = 'fail-branch';

/// `createRunningWorkflowState`.
DifyJson createRunningWorkflowState() => {
  'result': {
    'status': WorkflowRunningStatus.running,
    'inputs_truncated': false,
    'process_data_truncated': false,
    'outputs_truncated': false,
  },
  'tracing': <DifyJson>[],
  'resultText': '',
  'reasoningContent': <String, Object?>{},
  'reasoningFinished': false,
};

/// `createStoppedWorkflowState`.
DifyJson createStoppedWorkflowState() => {
  'result': {
    'status': WorkflowRunningStatus.stopped,
    'inputs_truncated': false,
    'process_data_truncated': false,
    'outputs_truncated': false,
  },
  'tracing': <DifyJson>[],
  'resultText': '',
};

/// `createFailedWorkflowState`.
DifyJson createFailedWorkflowState(String error) => {
  'result': {
    'status': WorkflowRunningStatus.failed,
    'error': error,
    'inputs_truncated': false,
    'process_data_truncated': false,
    'outputs_truncated': false,
  },
  'tracing': <DifyJson>[],
};

/// A deep, mutable copy of JSON (immer's draft: handlers copy, change the copy, and store it). Lists of JSON objects
/// stay `List<DifyJson>`.
T jsonCopy<T>(T v) => _copy(v) as T;

Object? _copy(Object? v) => switch (v) {
  final Map m => <String, Object?>{for (final e in m.entries) e.key as String: _copy(e.value)},
  final List<Map<String, Object?>> l => <DifyJson>[for (final x in l) _copy(x)! as DifyJson],
  final List l => <Object?>[for (final x in l) _copy(x)],
  _ => v,
};

/// `workflowRunningData.result` (an empty map when absent).
DifyJson resultOf(DifyJson? data) => switch (data?['result']) {
  final Map<String, Object?> r => r,
  _ => const {},
};

/// `workflowRunningData.tracing` (empty when absent).
List<DifyJson> tracingOf(DifyJson? data) => switch (data?['tracing']) {
  final List l => l.cast<DifyJson>(),
  _ => const [],
};
