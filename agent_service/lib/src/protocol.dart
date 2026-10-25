/// Wire models of the `dify-sf-agent/1` protocol (see `docs/agent-v2.md`).
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'output_tool.dart';

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
          : _object(json['parameters'], 'model.parameters');

  final Map<String, Object?> json;
  final String provider;
  final String name;
  final Map<String, Object?> parameters;
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
    required this.env,
    required this.fileIds,
    required this.maxTurns,
    required this.timeoutSeconds,
    required this.continuation,
    required this.outputAttempt,
    required this.resumeSequence,
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
  final Map<String, String> env;
  final List<String> fileIds;
  final int maxTurns;
  final int timeoutSeconds;
  final Continuation? continuation;
  final int outputAttempt;
  final int resumeSequence;

  String get digest => requestDigest(json);

  /// Validates [json]; throws [ApiError] (400) on a malformed request.
  static OperationRequest parse(Map<String, Object?> json) {
    requireProtocol(json);
    final operationId = _string(json, 'operation_id', 'request');
    final generation = _int(json, 'generation', 'request');
    final execution = ExecutionRef(_object(json['execution'], 'execution'));
    final model = ModelSpec(_object(json['model'], 'model'));

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
    final fileIds = <String>[];
    final rawFiles = json['files'];
    if (rawFiles != null) {
      if (rawFiles is! List) throw invalidRequest('files must be a list');
      for (var i = 0; i < rawFiles.length; i++) {
        fileIds.add(
          _string(_object(rawFiles[i], 'files[$i]'), 'file_id', 'files[$i]'),
        );
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
      shell: tools['shell'] == true,
      env: env,
      fileIds: fileIds,
      maxTurns: maxTurns,
      timeoutSeconds: timeoutSeconds,
      continuation: continuation,
      outputAttempt: outputAttempt,
      resumeSequence: resumeSequence,
    );
  }
}

/// Run usage summed over model calls.
class Usage {
  int promptTokens = 0;
  int completionTokens = 0;
  int totalTokens = 0;
  int? reasoningTokens;

  void add(Usage other) {
    promptTokens += other.promptTokens;
    completionTokens += other.completionTokens;
    totalTokens += other.totalTokens;
    if (other.reasoningTokens != null) {
      reasoningTokens = (reasoningTokens ?? 0) + other.reasoningTokens!;
    }
  }

  /// From a Dify `LLMUsage` JSON object. `reasoning_tokens` is read from
  /// `reasoning_tokens` or `completion_tokens_details.reasoning_tokens` and
  /// stays null when neither is reported.
  static Usage fromDify(Map<String, Object?> json) {
    int asInt(Object? v) => v is num ? v.toInt() : 0;
    final u = Usage()
      ..promptTokens = asInt(json['prompt_tokens'])
      ..completionTokens = asInt(json['completion_tokens'])
      ..totalTokens = asInt(json['total_tokens']);
    final direct = json['reasoning_tokens'];
    final details = json['completion_tokens_details'];
    final nested = details is Map ? details['reasoning_tokens'] : null;
    final r = direct ?? nested;
    u.reasoningTokens = r is num ? r.toInt() : null;
    if (u.totalTokens == 0) u.totalTokens = u.promptTokens + u.completionTokens;
    return u;
  }

  Map<String, Object?> toJson() => {
    'prompt_tokens': promptTokens,
    'completion_tokens': completionTokens,
    'total_tokens': totalTokens,
    'reasoning_tokens': reasoningTokens,
  };
}
