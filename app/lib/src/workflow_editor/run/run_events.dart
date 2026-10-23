/// The events of Dify 1.17.1's run streams (service/base.ts `handleStream`, the payload types in types/workflow.ts and
/// models/debug.ts): one Dart class per `event` value the web app handles, each wrapping the SSE payload as Dify's
/// JSON ([RunEvent.json]: `event`, `task_id`, `workflow_run_id`, `data`, ...). Node payloads (`data` of node_started,
/// node_finished, iteration_*, loop_*, node_retry, parallel_branch_*) are Dify's `NodeTracing` JSON, kept as is: the
/// run panels read dozens of its fields.
library;

import '../store/workflow_store.dart' show DifyJson;

/// One event of a run stream. [RunEvent.fromJson] picks the class by `event`, as `handleStream` dispatches.
sealed class RunEvent {
  const RunEvent(this.json);

  /// The whole SSE payload (`data: {...}`).
  final DifyJson json;

  String get event => json['event'] as String? ?? '';
  String? get taskId => json['task_id'] as String?;
  String? get workflowRunId => json['workflow_run_id'] as String?;

  /// The payload's `data` (empty when absent).
  DifyJson get data => switch (json['data']) {
    final Map<String, Object?> d => d,
    _ => const {},
  };

  /// The event for [json], as `handleStream` reads it: an `error` event, a payload with a numeric `status` >= 400
  /// or without `event` is an [ErrorEvent]; unknown events are [UnknownRunEvent].
  static RunEvent fromJson(DifyJson json) {
    final status = json['status'];
    final event = json['event'];
    if (event == 'error' || (status is num && status >= 400) || event == null || event == '') return ErrorEvent(json);
    return switch (event) {
      'message' || 'agent_message' => MessageEvent(json),
      'agent_thought' => AgentThoughtEvent(json),
      'message_file' => MessageFileEvent(json),
      'message_end' => MessageEndEvent(json),
      'message_replace' => MessageReplaceEvent(json),
      'workflow_started' => WorkflowStartedEvent(json),
      'workflow_finished' => WorkflowFinishedEvent(json),
      'node_started' => NodeStartedEvent(json),
      'node_finished' => NodeFinishedEvent(json),
      'iteration_started' => IterationStartedEvent(json),
      'iteration_next' => IterationNextEvent(json),
      'iteration_completed' => IterationCompletedEvent(json),
      'loop_started' => LoopStartedEvent(json),
      'loop_next' => LoopNextEvent(json),
      'loop_completed' => LoopCompletedEvent(json),
      'node_retry' => NodeRetryEvent(json),
      'parallel_branch_started' => ParallelBranchStartedEvent(json),
      'parallel_branch_finished' => ParallelBranchFinishedEvent(json),
      'text_chunk' => TextChunkEvent(json),
      'reasoning_chunk' => ReasoningChunkEvent(json),
      'text_replace' => TextReplaceEvent(json),
      'agent_log' => AgentLogEvent(json),
      'tts_message' => TtsMessageEvent(json),
      'tts_message_end' => TtsMessageEndEvent(json),
      'human_input_required' => HumanInputRequiredEvent(json),
      'human_input_form_filled' => HumanInputFormFilledEvent(json),
      'human_input_form_timeout' => HumanInputFormTimeoutEvent(json),
      'workflow_paused' => WorkflowPausedEvent(json),
      'datasource_processing' => DataSourceProcessingEvent(json),
      'datasource_completed' => DataSourceCompletedEvent(json),
      'datasource_error' => DataSourceErrorEvent(json),
      _ => UnknownRunEvent(json),
    };
  }

  @override
  String toString() => '$runtimeType($json)';
}

/// A node payload (`NodeTracing`): node_started, node_finished, node_retry, iteration_*, loop_*, parallel_branch_*.
sealed class NodeTracingEvent extends RunEvent {
  const NodeTracingEvent(super.json);
  String? get nodeId => data['node_id'] as String?;

  /// The node execution's id (`data.id`).
  String? get executionId => data['id'] as String?;
}

// ----- chat (advanced-chat) -----

/// `message` / `agent_message`: a piece of the answer (`answer`), with `conversation_id`, `id` (the message id).
final class MessageEvent extends RunEvent {
  const MessageEvent(super.json);
  String get answer => json['answer'] as String? ?? '';
  String? get conversationId => json['conversation_id'] as String?;
  String? get messageId => json['id'] as String?;
}

/// `agent_thought` (ThoughtItem).
final class AgentThoughtEvent extends RunEvent {
  const AgentThoughtEvent(super.json);
}

/// `message_file` (VisionFile).
final class MessageFileEvent extends RunEvent {
  const MessageFileEvent(super.json);
}

/// `message_end` (MessageEnd: `metadata.retriever_resources`, `files`).
final class MessageEndEvent extends RunEvent {
  const MessageEndEvent(super.json);
}

/// `message_replace` (MessageReplace: `answer`).
final class MessageReplaceEvent extends RunEvent {
  const MessageReplaceEvent(super.json);
  String get answer => json['answer'] as String? ?? '';
}

// ----- workflow -----

/// `workflow_started`: `data` {id, workflow_id, created_at}; `conversation_id` / `message_id` in chatflows.
final class WorkflowStartedEvent extends RunEvent {
  const WorkflowStartedEvent(super.json);
  String? get conversationId => json['conversation_id'] as String?;
  String? get messageId => json['message_id'] as String?;
}

/// `workflow_finished`: `data` {id, workflow_id, status, outputs, error, elapsed_time, total_tokens, total_steps,
/// created_at, created_by, finished_at, files}.
final class WorkflowFinishedEvent extends RunEvent {
  const WorkflowFinishedEvent(super.json);
  String? get status => data['status'] as String?;
}

/// `workflow_paused`: `data` {outputs, paused_nodes, reasons, workflow_run_id}.
final class WorkflowPausedEvent extends RunEvent {
  const WorkflowPausedEvent(super.json);
}

final class NodeStartedEvent extends NodeTracingEvent {
  const NodeStartedEvent(super.json);
}

final class NodeFinishedEvent extends NodeTracingEvent {
  const NodeFinishedEvent(super.json);
  String? get status => data['status'] as String?;
}

/// `node_retry`: the failed attempt (`retry_index`).
final class NodeRetryEvent extends NodeTracingEvent {
  const NodeRetryEvent(super.json);
}

final class IterationStartedEvent extends NodeTracingEvent {
  const IterationStartedEvent(super.json);
}

final class IterationNextEvent extends NodeTracingEvent {
  const IterationNextEvent(super.json);
}

/// `iteration_completed` (Dify's handler: onIterationFinish).
final class IterationCompletedEvent extends NodeTracingEvent {
  const IterationCompletedEvent(super.json);
}

final class LoopStartedEvent extends NodeTracingEvent {
  const LoopStartedEvent(super.json);
}

/// `loop_next`: `data.index` is the loop round.
final class LoopNextEvent extends NodeTracingEvent {
  const LoopNextEvent(super.json);
}

final class LoopCompletedEvent extends NodeTracingEvent {
  const LoopCompletedEvent(super.json);
}

final class ParallelBranchStartedEvent extends NodeTracingEvent {
  const ParallelBranchStartedEvent(super.json);
}

final class ParallelBranchFinishedEvent extends NodeTracingEvent {
  const ParallelBranchFinishedEvent(super.json);
}

/// `text_chunk`: `data` {text, from_variable_selector}.
final class TextChunkEvent extends RunEvent {
  const TextChunkEvent(super.json);
  String get text => data['text'] as String? ?? '';
}

/// `reasoning_chunk`: `data` {message_id, reasoning, node_id, is_final}.
final class ReasoningChunkEvent extends RunEvent {
  const ReasoningChunkEvent(super.json);
}

/// `text_replace`: `data.text`.
final class TextReplaceEvent extends RunEvent {
  const TextReplaceEvent(super.json);
  String get text => data['text'] as String? ?? '';
}

/// `agent_log`: `data` is an AgentLogItemWithChildren (node_id, message_id, label, status, data, ...).
final class AgentLogEvent extends RunEvent {
  const AgentLogEvent(super.json);
}

/// `tts_message`: `message_id`, `audio` (base64), `audio_type`.
final class TtsMessageEvent extends RunEvent {
  const TtsMessageEvent(super.json);
}

final class TtsMessageEndEvent extends RunEvent {
  const TtsMessageEndEvent(super.json);
}

/// `human_input_required`: `data` is HumanInputFormData (form_id, node_id, node_title, form_content, inputs,
/// actions, form_token, resolved_default_values, display_in_ui, expiration_time).
final class HumanInputRequiredEvent extends RunEvent {
  const HumanInputRequiredEvent(super.json);
}

/// `human_input_form_filled`: `data` is HumanInputFilledFormData.
final class HumanInputFormFilledEvent extends RunEvent {
  const HumanInputFormFilledEvent(super.json);
}

/// `human_input_form_timeout`: `data` {node_id, node_title, expiration_time}.
final class HumanInputFormTimeoutEvent extends RunEvent {
  const HumanInputFormTimeoutEvent(super.json);
}

/// RAG pipeline data source events (`datasource_processing` / `_completed` / `_error`).
final class DataSourceProcessingEvent extends RunEvent {
  const DataSourceProcessingEvent(super.json);
}

final class DataSourceCompletedEvent extends RunEvent {
  const DataSourceCompletedEvent(super.json);
}

final class DataSourceErrorEvent extends RunEvent {
  const DataSourceErrorEvent(super.json);
}

/// An `error` event (or a payload `handleStream` treats as one): `message`, `code`, `status`.
final class ErrorEvent extends RunEvent {
  const ErrorEvent(super.json);
  String? get message => json['message'] as String?;
  String? get code => json['code'] as String?;
}

/// An event Dify's web app does not handle (`ping`, newer events): ignored ("Unknown event" warning).
final class UnknownRunEvent extends RunEvent {
  const UnknownRunEvent(super.json);
}

/// A run stream that ends with an error before or instead of an `error` event (the request failed, a trigger debug
/// poll answered with an error): the stream's error. [message] is what Dify shows (toast, failed result).
class RunServiceException implements Exception {
  const RunServiceException(this.message, {this.code});
  final String message;
  final String? code;
  @override
  String toString() => message;
}
