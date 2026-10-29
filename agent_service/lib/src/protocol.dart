/// Wire models of the `dify-sf-agent/1` protocol (see `docs/agent-v2.md`).
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'harness/codex/official.dart' show officialCodexReasoningEfforts;
import 'output_tool.dart';
import 'sandbox/paths.dart';

/// Top-level fields of `POST /v1/operations`; any other is `400
/// invalid_request`.
const operationFields = {
  'protocol',
  'operation_id',
  'generation',
  'execution',
  'model',
  'system_prompt',
  'task',
  'output_schema',
  'tools',
  'env',
  'files',
  'limits',
  'executor_profile',
  'harness_style',
  'continuation',
  'codex_session',
};

/// `harness_style` of an operation: how the agent loop is built (tool set,
/// prompt assembly, loop policy, reasoning round trip). See docs/agent-v2.md,
/// "Harness styles".
enum HarnessStyle {
  /// Dify's agent (Genkit loop, Dify's shell tools and prompt): the default.
  dify('dify'),

  /// A port of the OpenAI Codex CLI harness (rust-v0.163.0), Direct tools.
  codex('codex');

  const HarnessStyle(this.wire);
  final String wire;
}

/// Reasoning levels the `codex` style accepts in
/// `model.parameters.reasoning_effort`, sent unchanged (Codex 0.163.0's
/// `ReasoningEffort` without `ultra` and `persistent`).
const codexReasoningEfforts = [
  'none',
  'minimal',
  'low',
  'medium',
  'high',
  'xhigh',
  'max',
];

/// Levels Codex knows that the `codex` style refuses, with the reason given
/// in `422 unsupported_reasoning_effort`.
const codexRefusedReasoningEfforts = {
  'ultra':
      'ultra means "max reasoning plus proactive delegation to sub-agents" in '
      'Codex (it sends effort xhigh and enables sub-agents); sub-agents are '
      'not implemented in this harness. Use max',
  'persistent':
      'persistent is an interactive Codex mode (sent as "disabled"); it is '
      'not implemented in this harness',
};

/// Protocol name and version sent in every request and response body.
const protocolName = 'dify-sf-agent/1';

/// Session envelope name and version.
const envelopeName = 'dify-sf-agent-session/1';

/// The Genkit Dart version this service is built against.
const genkitVersion = '1.0.1';

/// The service version reported by `GET /v1/health`.
const serviceVersion = '0.1.0';

/// Terminal event names; exactly one ends every run.
const terminalEvents = {'succeeded', 'paused', 'failed', 'cancelled'};

/// A protocol error answered as `{"protocol", "error", "message", ...extra}`.
class ApiError implements Exception {
  ApiError(this.status, this.code, this.message, {this.extra = const {}});

  final int status;
  final String code;
  final String message;
  final Map<String, Object?> extra;

  Map<String, Object?> toJson() => {
    'protocol': protocolName,
    'error': code,
    'message': message,
    ...extra,
  };

  @override
  String toString() => 'ApiError($status $code: $message)';
}

ApiError invalidRequest(String message) =>
    ApiError(400, 'invalid_request', message);

/// Executor profile names (as the Swift server validates the Soul key).
final profileNamePattern = RegExp(r'^[a-z0-9][a-z0-9-]{0,63}$');

/// Canonical JSON: object keys sorted, no insignificant whitespace.
String canonicalJson(Object? value) {
  final buffer = StringBuffer();
  void write(Object? v) {
    if (v is Map) {
      final keys = v.keys.map((k) => k.toString()).toList()..sort();
      buffer.write('{');
      for (var i = 0; i < keys.length; i++) {
        if (i > 0) buffer.write(',');
        buffer.write(jsonEncode(keys[i]));
        buffer.write(':');
        write(v[keys[i]]);
      }
      buffer.write('}');
    } else if (v is List) {
      buffer.write('[');
      for (var i = 0; i < v.length; i++) {
        if (i > 0) buffer.write(',');
        write(v[i]);
      }
      buffer.write(']');
    } else {
      buffer.write(jsonEncode(v));
    }
  }

  write(value);
  return buffer.toString();
}

String sha256Hex(String text) => sha256.convert(utf8.encode(text)).toString();

/// SHA-256 of the canonical JSON request without `generation`.
String requestDigest(Map<String, Object?> body) {
  final copy = Map<String, Object?>.of(body)..remove('generation');
  return sha256Hex(canonicalJson(copy));
}

/// Whether [name] may not be set through `env` (case-insensitive).
bool isReservedEnvName(String name) {
  final upper = name.toUpperCase();
  return const {'HOME', 'PATH', 'TMPDIR', 'TMP', 'TEMP'}.contains(upper) ||
      upper.startsWith('SHELLCTL_') ||
      upper.endsWith('_PROXY') ||
      upper == 'NO_PROXY';
}

/// Rejects a body whose `protocol` is not [protocolName].
void requireProtocol(Map<String, Object?> body) {
  final protocol = body['protocol'];
  if (protocol != protocolName) {
    throw ApiError(
      400,
      'unsupported_protocol',
      'unsupported protocol ${jsonEncode(protocol)}; expected $protocolName',
    );
  }
}

Map<String, Object?> _object(Object? v, String name) {
  if (v is Map<String, Object?>) return v;
  if (v is Map) return v.cast<String, Object?>();
  throw invalidRequest('$name must be an object');
}

String _string(Map<String, Object?> o, String key, String where) {
  final v = o[key];
  if (v is String && v.isNotEmpty) return v;
  throw invalidRequest('$where.$key must be a non-empty string');
}

String? _optString(Map<String, Object?> o, String key, String where) {
  final v = o[key];
  if (v == null || v is String) return v as String?;
  throw invalidRequest('$where.$key must be a string');
}

int _int(Map<String, Object?> o, String key, String where, {int min = 0}) {
  final v = o[key];
  if (v is int && v >= min) return v;
  throw invalidRequest('$where.$key must be an integer >= $min');
}

/// `execution` of an operation request.
class ExecutionRef {
  ExecutionRef(this.json)
    : tenantId = _string(json, 'tenant_id', 'execution'),
      appId = _string(json, 'app_id', 'execution'),
      workflowRunId = _string(json, 'workflow_run_id', 'execution'),
      nodeId = _string(json, 'node_id', 'execution'),
      executionId = _string(json, 'execution_id', 'execution'),
      agentConfigSnapshotId = _string(
        json,
        'agent_config_snapshot_id',
        'execution',
      ),
      userId = _optString(json, 'user_id', 'execution'),
      userFrom = _optString(json, 'user_from', 'execution'),
      invokeFrom = _optString(json, 'invoke_from', 'execution');

  final Map<String, Object?> json;
  final String tenantId;
  final String appId;
  final String workflowRunId;
  final String nodeId;
  final String executionId;
  final String agentConfigSnapshotId;
  final String? userId;
  final String? userFrom;
  final String? invokeFrom;
}

/// `model` of an operation request.
class ModelSpec {
  ModelSpec(this.json)
    : provider = _string(json, 'provider', 'model'),
      name = _string(json, 'name', 'model'),
      parameters = json['parameters'] == null
          ? const {}
          : _object(json['parameters'], 'model.parameters'),
      apiType = _optString(json, 'api_type', 'model'),
      wire = _optString(json, 'wire', 'model'),
      contextWindow = _optPositiveInt(json, 'context_window', 'model'),
      maxOutputTokens = _optPositiveInt(json, 'max_output_tokens', 'model'),
      reasoningEfforts = _optStrings(json, 'reasoning_efforts', 'model'),
      inputModalities = _optStrings(json, 'input_modalities', 'model') {
    if (wire != null && wire != 'plugin' && wire != 'responses') {
      throw invalidRequest('model.wire must be "plugin" or "responses"');
    }
  }

  final Map<String, Object?> json;
  final String provider;
  final String name;
  final Map<String, Object?> parameters;

  /// `model.api_type` (optional): the API mode of the provider credential as
  /// the Swift server knows it, for example `responses` for an
  /// `openai_api_compatible` credential in Responses mode. The `codex` style
  /// selects its model wire from it.
  final String? apiType;

  /// `model.wire` (optional): the model channel the Swift server chose,
  /// `plugin` (`llm/invoke`) or `responses` (`POST /inner/agent/responses`);
  /// without it the `codex` style chooses from [apiType] and [provider].
  final String? wire;

  /// `model.context_window` and `model.max_output_tokens` (optional, from
  /// the model schema): accepted and checked; used by compaction later.
  final int? contextWindow;
  final int? maxOutputTokens;

  /// `model.reasoning_efforts` and `model.input_modalities` (optional, from
  /// the model schema): the levels and inputs (`text`, `image`) the model
  /// supports; the official Codex runtime writes them into its catalog.
  final List<String>? reasoningEfforts;
  final List<String>? inputModalities;
}

List<String>? _optStrings(Map<String, Object?> o, String key, String where) {
  final v = o[key];
  if (v == null) return null;
  if (v is List && v.every((e) => e is String && e.isNotEmpty)) {
    return v.cast<String>();
  }
  throw invalidRequest('$where.$key must be a list of non-empty strings');
}

int? _optPositiveInt(Map<String, Object?> o, String key, String where) {
  final v = o[key];
  if (v == null) return null;
  if (v is int && v >= 1) return v;
  throw invalidRequest('$where.$key must be an integer >= 1');
}

/// One element of `task`.
sealed class TaskPart {
  static TaskPart parse(Object? raw, int index) {
    final o = _object(raw, 'task[$index]');
    switch (o['type']) {
      case 'text':
        final text = o['text'];
        if (text is! String) {
          throw invalidRequest('task[$index].text must be a string');
        }
        return TaskText(text);
      case 'file':
        return TaskFile(
          _string(o, 'file_id', 'task[$index]'),
          _optString(o, 'mime_type', 'task[$index]'),
        );
      default:
        throw invalidRequest('task[$index].type must be "text" or "file"');
    }
  }
}

class TaskText extends TaskPart {
  TaskText(this.text);
  final String text;
}

class TaskFile extends TaskPart {
  TaskFile(this.fileId, this.mimeType);
  final String fileId;
  final String? mimeType;
}

/// One element of `files`: a file materialized at a workspace-relative path.
class FileRef {
  FileRef(this.fileId, this.path);
  final String fileId;
  final String path;
}

/// `continuation` of an operation request.
sealed class Continuation {
  Continuation(this.snapshot);

  final Map<String, Object?> snapshot;

  static Continuation? parse(Object? raw) {
    if (raw == null) return null;
    final o = _object(raw, 'continuation');
    final snapshot = _object(o['snapshot'], 'continuation.snapshot');
    switch (o['kind']) {
      case 'answer':
        final result = _object(o['result'], 'continuation.result');
        const statuses = {'submitted', 'timeout', 'cancelled', 'unavailable'};
        if (!statuses.contains(result['status'])) {
          throw invalidRequest(
            'continuation.result.status must be one of ${statuses.join(', ')}',
          );
        }
        return AnswerContinuation(
          snapshot,
          _string(o, 'question_id', 'continuation'),
          result,
        );
      case 'output_retry':
        final feedback = o['feedback'];
        if (feedback is! List || feedback.isEmpty) {
          throw invalidRequest(
            'continuation.feedback must be a non-empty list',
          );
        }
        final items = <({String field, String error})>[];
        for (var i = 0; i < feedback.length; i++) {
          final f = _object(feedback[i], 'continuation.feedback[$i]');
          final field = f['field'];
          final error = f['error'];
          if (field is! String || error is! String) {
            throw invalidRequest(
              'continuation.feedback[$i] needs string field and error',
            );
          }
          items.add((field: field, error: error));
        }
        return OutputRetryContinuation(snapshot, items);
      default:
        throw invalidRequest(
          'continuation.kind must be "answer" or "output_retry"',
        );
    }
  }
}

class AnswerContinuation extends Continuation {
  AnswerContinuation(super.snapshot, this.questionId, this.result);
  final String questionId;
  final Map<String, Object?> result;
}

class OutputRetryContinuation extends Continuation {
  OutputRetryContinuation(super.snapshot, this.feedback);
  final List<({String field, String error})> feedback;
}

/// `codex_session` of an operation request (docs/agent-v2.md, "Codex
/// session retained across rounds"): `{"retain": true}` keeps the workspace
/// and the Codex conversation for the next round of the same node in the
/// same workflow run.
class CodexSessionRequest {
  const CodexSessionRequest({required this.retain});

  final bool retain;

  static CodexSessionRequest? parse(Object? raw) {
    if (raw == null) return null;
    final o = _object(raw, 'codex_session');
    final unknown = o.keys.where((k) => k != 'retain');
    if (unknown.isNotEmpty) {
      throw invalidRequest(
        'unknown codex_session fields: ${unknown.join(', ')}',
      );
    }
    if (o['retain'] != true) {
      throw invalidRequest(
        'codex_session.retain must be true (send codex_session null to not '
        'retain the session)',
      );
    }
    return const CodexSessionRequest(retain: true);
  }
}

/// The key of a node's retained workspace in one workflow run: the canonical
/// JSON array `[tenant_id, app_id, workflow_run_id, node_id]` (no separator
/// a value could contain). The supervisor hashes it.
String retainedWorkspaceKey(ExecutionRef e) =>
    canonicalJson([e.tenantId, e.appId, e.workflowRunId, e.nodeId]);

/// The supervisor's ID of the retained workspace [workspaceKey]: its
/// `hashKey("retained:" + workspace_key)`, the hex SHA-256 of the UTF-8
/// text. agent_service indexes and deletes only this ID.
String retainedWorkspaceId(String workspaceKey) =>
    sha256Hex('retained:$workspaceKey');

/// A validated `POST /v1/operations` body.
class OperationRequest {
  OperationRequest._({
    required this.json,
    required this.operationId,
    required this.generation,
    required this.execution,
    required this.model,
    required this.systemPrompt,
    required this.task,
    required this.outputSchema,
    required this.askHuman,
    required this.shell,
    required this.viewImage,
    required this.reportProgress,
    required this.executorProfile,
    required this.harnessStyle,
    required this.updatePlan,
    required this.env,
    required this.files,
    required this.maxTurns,
    required this.timeoutSeconds,
    required this.continuation,
    required this.outputAttempt,
    required this.resumeSequence,
    this.officialCodex = false,
    this.codexRunToken,
    this.codexSession,
  });

  final Map<String, Object?> json;
  final String operationId;
  final int generation;
  final ExecutionRef execution;
  final ModelSpec model;
  final String systemPrompt;
  final List<TaskPart> task;
  final Map<String, Object?>? outputSchema;
  final bool askHuman;
  final bool shell;

  /// `tools.view_image` (a dify-sf extension; needs `tools.shell`).
  final bool viewImage;

  /// `tools.report_progress` (a dify-sf extension; needs `tools.shell`).
  final bool reportProgress;

  /// The requested executor profile; `default` when absent. Used only with
  /// the shell.
  final String executorProfile;

  /// `harness_style`; absent means [HarnessStyle.dify].
  final HarnessStyle harnessStyle;

  /// `tools.update_plan` (`codex` style only; off by default as in Codex).
  final bool updatePlan;

  /// `model.parameters.reasoning_effort` when it is a string, else null.
  String? get reasoningEffort {
    final v = model.parameters['reasoning_effort'];
    return v is String ? v : null;
  }

  final Map<String, String> env;
  final List<FileRef> files;
  final int maxTurns;
  final int timeoutSeconds;
  final Continuation? continuation;
  final int outputAttempt;
  final int resumeSequence;

  /// `harness_style: codex` runs the official Codex binary (see
  /// `harness/codex/official.dart`), not the Dart port.
  final bool officialCodex;

  /// `model.run_token`: the run token Codex sends to the gateway's Codex
  /// entry. A secret: removed from [json] (so from the request digest, the
  /// snapshots and the run store) and never logged.
  final String? codexRunToken;

  /// `codex_session`: only with `harness_style: codex`, the official runtime
  /// and `tools.shell` (the executor profile's disk workspace is checked
  /// with the profile).
  final CodexSessionRequest? codexSession;

  /// Whether the run keeps its workspace and Codex conversation.
  bool get retainsSession => codexSession?.retain ?? false;

  /// The retained workspace's key, with [retainsSession].
  String? get workspaceKey =>
      retainsSession ? retainedWorkspaceKey(execution) : null;

  String get digest => requestDigest(json);

  List<String> get fileIds => [for (final f in files) f.fileId];

  /// Validates [json]; throws [ApiError] (400) on a malformed request.
  /// [officialCodex]: `harness_style: codex` runs the official Codex binary.
  static OperationRequest parse(
    Map<String, Object?> json, {
    bool officialCodex = false,
  }) {
    requireProtocol(json);
    final unknown = json.keys.where((k) => !operationFields.contains(k));
    if (unknown.isNotEmpty) {
      throw invalidRequest('unknown request fields: ${unknown.join(', ')}');
    }
    final operationId = _string(json, 'operation_id', 'request');
    final generation = _int(json, 'generation', 'request');
    final execution = ExecutionRef(_object(json['execution'], 'execution'));
    // The run token is kept apart: never in the digest, snapshot or store.
    final rawModel = Map.of(_object(json['model'], 'model'));
    final runToken = rawModel.remove('run_token');
    if (runToken != null && (runToken is! String || runToken.isEmpty)) {
      throw invalidRequest('model.run_token must be a non-empty string');
    }
    if (runToken != null) json = {...json, 'model': rawModel};
    final model = ModelSpec(rawModel);

    // operation_id = <execution_id>:<output_attempt>:<resume_sequence>
    final prefix = '${execution.executionId}:';
    final rest = operationId.startsWith(prefix)
        ? operationId.substring(prefix.length).split(':')
        : const <String>[];
    final outputAttempt = rest.length == 2 ? int.tryParse(rest[0]) : null;
    final resumeSequence = rest.length == 2 ? int.tryParse(rest[1]) : null;
    if (outputAttempt == null ||
        resumeSequence == null ||
        outputAttempt < 0 ||
        resumeSequence < 0) {
      throw invalidRequest(
        'operation_id must be <execution_id>:<output_attempt>:<resume_sequence>',
      );
    }

    final systemPrompt = json['system_prompt'] ?? '';
    if (systemPrompt is! String) {
      throw invalidRequest('system_prompt must be a string');
    }
    final rawTask = json['task'];
    if (rawTask is! List || rawTask.isEmpty) {
      throw invalidRequest('task must be a non-empty list');
    }
    final task = [
      for (var i = 0; i < rawTask.length; i++) TaskPart.parse(rawTask[i], i),
    ];
    final outputSchema = json['output_schema'] == null
        ? null
        : _object(json['output_schema'], 'output_schema');
    if (outputSchema != null) {
      try {
        checkOutputSchema(outputSchema);
      } on FormatException catch (e) {
        throw invalidRequest(e.message);
      }
    }
    final tools = json['tools'] == null
        ? const <String, Object?>{}
        : _object(json['tools'], 'tools');
    final shell = tools['shell'] == true;
    final viewImage = tools['view_image'] == true;
    if (viewImage && !shell) {
      throw invalidRequest('tools.view_image needs tools.shell');
    }
    final reportProgress = tools['report_progress'] == true;
    if (reportProgress && !shell) {
      throw invalidRequest('tools.report_progress needs tools.shell');
    }
    final profile = json['executor_profile'] ?? 'default';
    if (profile is! String || !profileNamePattern.hasMatch(profile)) {
      throw invalidRequest(
        'executor_profile must be a profile name (${profileNamePattern.pattern}); '
        'omit it for "default"',
      );
    }
    final rawStyle = json['harness_style'];
    final HarnessStyle harnessStyle;
    if (rawStyle == null) {
      harnessStyle = HarnessStyle.dify;
    } else if (rawStyle is! String) {
      throw invalidRequest('harness_style must be a string');
    } else {
      harnessStyle =
          HarnessStyle.values.where((h) => h.wire == rawStyle).firstOrNull ??
          (throw ApiError(
            422,
            'unsupported_harness_style',
            'harness_style ${jsonEncode(rawStyle)} is not supported; use '
                '${HarnessStyle.values.map((h) => '"${h.wire}"').join(' or ')}',
          ));
    }
    final updatePlan = tools['update_plan'] == true;
    if (model.wire == 'responses' && harnessStyle != HarnessStyle.codex) {
      throw invalidRequest(
        'model.wire "responses" needs harness_style "codex"',
      );
    }
    if (updatePlan && harnessStyle != HarnessStyle.codex) {
      throw invalidRequest('tools.update_plan needs harness_style "codex"');
    }
    final official = officialCodex && harnessStyle == HarnessStyle.codex;
    if (official && runToken == null) {
      throw invalidRequest(
        'model.run_token is required for harness_style "codex"',
      );
    }
    if (harnessStyle == HarnessStyle.codex &&
        model.parameters.containsKey('reasoning_effort')) {
      final effort = model.parameters['reasoning_effort'];
      final accepted = official
          ? officialCodexReasoningEfforts
          : codexReasoningEfforts;
      if (effort is! String || !accepted.contains(effort)) {
        final refused = effort is String && !official
            ? codexRefusedReasoningEfforts[effort]
            : null;
        throw ApiError(
          422,
          'unsupported_reasoning_effort',
          refused ??
              'model.parameters.reasoning_effort ${jsonEncode(effort)} is not '
                  'one of ${accepted.join(', ')}',
          extra: {'reasoning_effort': effort},
        );
      }
    }
    final env = <String, String>{};
    if (json['env'] != null) {
      final rawEnv = _object(json['env'], 'env');
      final reserved = rawEnv.keys.where(isReservedEnvName).toList();
      if (reserved.isNotEmpty) {
        throw ApiError(
          400,
          'reserved_env',
          'reserved environment variable names: ${reserved.join(', ')}',
        );
      }
      rawEnv.forEach((k, v) {
        if (v is! String) throw invalidRequest('env.$k must be a string');
        env[k] = v;
      });
    }
    final files = <FileRef>[];
    final rawFiles = json['files'];
    if (rawFiles != null) {
      if (rawFiles is! List) throw invalidRequest('files must be a list');
      final paths = <String>{};
      for (var i = 0; i < rawFiles.length; i++) {
        final f = _object(rawFiles[i], 'files[$i]');
        final path = _string(f, 'path', 'files[$i]');
        final String normalized;
        try {
          normalized = normalizeWorkspacePath(path);
        } on FormatException catch (e) {
          throw invalidRequest('files[$i].path: ${e.message}');
        }
        if (!paths.add(normalized)) {
          throw invalidRequest('files[$i].path repeats $normalized');
        }
        files.add(FileRef(_string(f, 'file_id', 'files[$i]'), normalized));
      }
    }
    final limits = json['limits'] == null
        ? const <String, Object?>{}
        : _object(json['limits'], 'limits');
    final maxTurns = limits['max_turns'] == null
        ? 50
        : _int(limits, 'max_turns', 'limits', min: 1);
    final timeoutSeconds = limits['timeout_seconds'] == null
        ? 1800
        : _int(limits, 'timeout_seconds', 'limits', min: 1);

    final continuation = Continuation.parse(json['continuation']);
    switch (continuation) {
      case null when outputAttempt != 0 || resumeSequence != 0:
        throw invalidRequest(
          'continuation is required unless operation_id ends with :0:0',
        );
      case AnswerContinuation() when resumeSequence < 1:
        throw invalidRequest('an answer needs resume_sequence >= 1');
      case OutputRetryContinuation() when outputAttempt < 1:
        throw invalidRequest('an output retry needs output_attempt >= 1');
      default:
        break;
    }
    final codexSession = CodexSessionRequest.parse(json['codex_session']);
    if (codexSession != null) {
      if (harnessStyle != HarnessStyle.codex) {
        throw invalidRequest('codex_session needs harness_style "codex"');
      }
      if (!official) {
        throw invalidRequest(
          'codex_session needs the official Codex runtime '
          '(AGENT_CODEX_RUNTIME=official)',
        );
      }
      if (!shell) throw invalidRequest('codex_session needs tools.shell');
    }

    return OperationRequest._(
      json: json,
      operationId: operationId,
      generation: generation,
      execution: execution,
      model: model,
      systemPrompt: systemPrompt,
      task: task,
      outputSchema: outputSchema,
      askHuman: tools['ask_human'] == true,
      shell: shell,
      viewImage: viewImage,
      reportProgress: reportProgress,
      executorProfile: profile,
      harnessStyle: harnessStyle,
      updatePlan: updatePlan,
      env: env,
      files: files,
      maxTurns: maxTurns,
      timeoutSeconds: timeoutSeconds,
      continuation: continuation,
      outputAttempt: outputAttempt,
      resumeSequence: resumeSequence,
      officialCodex: official,
      codexRunToken: runToken as String?,
      codexSession: codexSession,
    );
  }
}

/// Run usage summed over model calls.
class Usage {
  int promptTokens = 0;
  int completionTokens = 0;
  int totalTokens = 0;
  int? reasoningTokens;

  /// Prompt tokens the provider read from its prompt cache; null when the
  /// provider (or a component on the way) does not report it.
  int? promptCacheHitTokens;

  /// Prompt tokens the provider did not find in its cache; null when not
  /// reported and not derivable (see [fromDify]).
  int? promptCacheMissTokens;

  /// Like `reasoning_tokens`: the sum of the values that were reported.
  void add(Usage other) {
    promptTokens += other.promptTokens;
    completionTokens += other.completionTokens;
    totalTokens += other.totalTokens;
    int? sum(int? a, int? b) => b == null ? a : (a ?? 0) + b;
    reasoningTokens = sum(reasoningTokens, other.reasoningTokens);
    promptCacheHitTokens = sum(
      promptCacheHitTokens,
      other.promptCacheHitTokens,
    );
    promptCacheMissTokens = sum(
      promptCacheMissTokens,
      other.promptCacheMissTokens,
    );
  }

  /// From a Dify `LLMUsage` JSON object. `reasoning_tokens` is read from
  /// `reasoning_tokens` or `completion_tokens_details.reasoning_tokens` and
  /// stays null when neither is reported.
  ///
  /// Cache hits are read from DeepSeek's `prompt_cache_hit_tokens`, the Swift
  /// server's `cached_tokens` or OpenAI's `prompt_tokens_details.
  /// cached_tokens`; misses from DeepSeek's `prompt_cache_miss_tokens`, else
  /// `prompt_tokens - hits` when hits are reported. Both stay null when no
  /// hit count is reported (Dify's `LLMUsage` has no such field, so today's
  /// plugins and plugin daemon drop it; see docs/agent-v2.md).
  static Usage fromDify(Map<String, Object?> json) {
    int asInt(Object? v) => v is num ? v.toInt() : 0;
    int? orNull(Object? v) => v is num ? v.toInt() : null;
    final u = Usage()
      ..promptTokens = asInt(json['prompt_tokens'])
      ..completionTokens = asInt(json['completion_tokens'])
      ..totalTokens = asInt(json['total_tokens']);
    final direct = json['reasoning_tokens'];
    final details = json['completion_tokens_details'];
    final nested = details is Map ? details['reasoning_tokens'] : null;
    final r = direct ?? nested;
    u.reasoningTokens = r is num ? r.toInt() : null;
    final promptDetails = json['prompt_tokens_details'];
    final hit =
        orNull(json['prompt_cache_hit_tokens']) ??
        orNull(json['cached_tokens']) ??
        (promptDetails is Map ? orNull(promptDetails['cached_tokens']) : null);
    u.promptCacheHitTokens = hit;
    u.promptCacheMissTokens =
        orNull(json['prompt_cache_miss_tokens']) ??
        (hit == null ? null : (u.promptTokens - hit).clamp(0, u.promptTokens));
    if (u.totalTokens == 0) u.totalTokens = u.promptTokens + u.completionTokens;
    return u;
  }

  Map<String, Object?> toJson() => {
    'prompt_tokens': promptTokens,
    'completion_tokens': completionTokens,
    'total_tokens': totalTokens,
    'reasoning_tokens': reasoningTokens,
    'prompt_cache_hit_tokens': promptCacheHitTokens,
    'prompt_cache_miss_tokens': promptCacheMissTokens,
  };
}
