// Portions derived from OpenAI Codex (https://github.com/openai/codex,
// rust-v0.163.0, codex-rs/protocol/src/models.rs (`ResponseItem`) and the
// request fields of codex-rs/core/src/client.rs), Copyright 2025 OpenAI,
// licensed under the Apache License 2.0. Modified for dify-sf: items are
// kept as Responses JSON; the plugin transport maps them to Dify
// `PromptMessage`s for the inner gateway.

/// The `codex` style's history (Responses API items) and the transports
/// that send it to a model: the native Responses wire (`POST
/// /inner/agent/responses`) and the plugin wire (`POST
/// /inner/agent/llm/invoke`), chosen by [selectWire].
library;

import 'dart:async';
import 'dart:convert';

import 'package:genkit/genkit.dart' show Media;

import '../../gateway.dart';
import '../../model.dart';
import '../../protocol.dart';
import 'retry.dart';
import 'tools.dart';

/// One history item: Responses API JSON. Keys starting with `dify_sf_` are
/// this service's annotations and never sent on the Responses wire.
typedef Item = Map<String, Object?>;

/// Prefix of the annotation keys inside items.
const annotationPrefix = 'dify_sf_';

Item developerMessage(List<String> texts) => {
  'type': 'message',
  'role': 'developer',
  'content': [
    for (final t in texts) {'type': 'input_text', 'text': t},
  ],
};

Item userMessage(List<Map<String, Object?>> content) => {
  'type': 'message',
  'role': 'user',
  'content': content,
};

Item userText(String text) => userMessage([
  {'type': 'input_text', 'text': text},
]);

Map<String, Object?> inputText(String text) => {
  'type': 'input_text',
  'text': text,
};

/// A file of the execution in a user message (task files) or a tool output
/// (viewed images): `dify-sf-file:<id>`.
Map<String, Object?> inputImage(
  String fileId,
  String? mimeType, {
  String? detail,
  Map<String, Object?>? viewImage,
}) => {
  'type': 'input_image',
  'image_url': '$fileUrlScheme$fileId',
  'detail': ?detail,
  'dify_sf_mime_type': ?mimeType,
  'dify_sf_view_image': ?viewImage,
};

Map<String, Object?> inputFile(String fileId, String? mimeType) => {
  'type': 'input_file',
  'file_id': '$fileUrlScheme$fileId',
  'dify_sf_mime_type': ?mimeType,
};

Item functionCallOutput(String callId, Object output) => {
  'type': 'function_call_output',
  'call_id': callId,
  'output': output,
};

Item customToolCallOutput(String callId, Object output) => {
  'type': 'custom_tool_call_output',
  'call_id': callId,
  'output': output,
};

bool isToolCall(Item i) =>
    i['type'] == 'function_call' || i['type'] == 'custom_tool_call';

bool isToolOutput(Item i) =>
    i['type'] == 'function_call_output' ||
    i['type'] == 'custom_tool_call_output';

/// The text of a tool output (its `input_text` parts for a content list).
String outputText(Object? output) {
  if (output is String) return output;
  if (output is List) {
    return [
      for (final c in output)
        if (c is Map && c['type'] == 'input_text') c['text'],
    ].join('\n');
  }
  return '';
}

/// [item] without annotation keys (recursively), for the Responses wire.
Object? stripAnnotations(Object? value) {
  if (value is Map) {
    return {
      for (final e in value.entries)
        if (!(e.key as String).startsWith(annotationPrefix))
          e.key as String: stripAnnotations(e.value),
    };
  }
  if (value is List) return [for (final v in value) stripAnnotations(v)];
  return value;
}

/// One model request of the loop.
class SampleRequest {
  SampleRequest({
    required this.callIndex,
    required this.attempt,
    required this.items,
    required this.tools,
    required this.parallelToolCalls,
    this.reasoningEffort,
    this.reasoningSummary,
    this.outputSchema,
    required this.promptCacheKey,
  });

  final int callIndex;

  /// 0 for the first attempt; retries count up (same [callIndex]).
  final int attempt;
  final List<Item> items;
  final List<CodexToolSpec> tools;
  final bool parallelToolCalls;

  /// What the Responses wire sends as `reasoning.effort` (the plugin wire
  /// forwards `model.parameters` instead).
  final String? reasoningEffort;
  final String? reasoningSummary;

  /// `text.format` json_schema on the Responses wire.
  final Map<String, Object?>? outputSchema;
  final String promptCacheKey;
}

/// One model response.
class SampleResult {
  SampleResult({
    required this.invocationId,
    required this.output,
    required this.usage,
    required this.reasoning,
    this.prefix,
    this.finishReason,
  });

  final String invocationId;

  /// Output items: reasoning, assistant messages, tool calls.
  final List<Item> output;
  final Usage usage;

  /// `model_call.reasoning` (docs/agent-v2.md, "Harness styles").
  final Map<String, Object?> reasoning;
  final PromptPrefix? prefix;
  final String? finishReason;
}

/// A way to call the model with the `codex` history.
abstract class ModelTransport {
  /// `plugin` or `responses` (`model.wire`).
  String get wire;

  /// Freeform (grammar) tools: `apply_patch` as Codex sends it.
  bool get freeformTools;

  /// Images inside tool outputs (else they follow as a user message).
  bool get imagesInToolOutputs;

  /// Whether reasoning items with `encrypted_content` round-trip.
  bool get reasoningRoundTrip;

  /// One attempt. Throws [GatewayException] (or a transport error).
  Future<SampleResult> sample(
    SampleRequest request, {
    required void Function(String text) onReasoning,
  });

  void close();
}

/// `<run_id>:<call_index>` for the first attempt (as the dify style), and
/// `<run_id>:<call_index>:<attempt>` for retries (with `caller.attempt`).
String invocationIdFor(String runId, int callIndex, int attempt) =>
    attempt == 0 ? '$runId:$callIndex' : '$runId:$callIndex:$attempt';

/// The `caller` of a gateway model request (`llm/invoke` and `responses`).
Map<String, Object?> callerJson(
  OperationRequest r,
  String runId,
  String invocationId,
  SampleRequest req,
) {
  final x = r.execution;
  return {
    'invocation_id': invocationId,
    'run_id': runId,
    'call_index': req.callIndex,
    if (req.attempt > 0) 'attempt': req.attempt,
    'operation_id': r.operationId,
    'tenant_id': x.tenantId,
    'app_id': x.appId,
    'user_id': x.userId,
    'user_from': x.userFrom,
    'invoke_from': x.invokeFrom,
    'workflow_run_id': x.workflowRunId,
    'node_id': x.nodeId,
    'node_execution_id': x.executionId,
    'agent_config_snapshot_id': x.agentConfigSnapshotId,
  };
}

/// The plugin wire: Dify `PromptMessage`s through `POST
/// /inner/agent/llm/invoke`. The plugin builds the vendor request from
/// `model.parameters`, so the reasoning effort it forwards is not provable
/// and no reasoning item survives beyond its text.
class PluginTransport implements ModelTransport {
  PluginTransport({
    required this.inner,
    required this.request,
    required this.runId,
  });

  final InnerClient inner;
  final OperationRequest request;
  final String runId;
  List<String>? _previousMessages;
  String? _previousTools;

  @override
  String get wire => 'plugin';
  @override
  bool get freeformTools => false;
  @override
  bool get imagesInToolOutputs => false;
  @override
  bool get reasoningRoundTrip => false;

  @override
  void close() => inner.close();

  /// [items] as Dify prompt messages (deterministic: a longer history
  /// gives the same JSON for its earlier messages).
  Future<List<Map<String, Object?>>> promptMessages(List<Item> items) async {
    final out = <Map<String, Object?>>[];
    final names = <String, String>{};
    for (final i in items) {
      if (isToolCall(i)) names['${i['call_id']}'] = '${i['name']}';
    }
    var k = 0;
    while (k < items.length) {
      final item = items[k];
      final type = item['type'];
      if (type == 'message' && item['role'] != 'assistant') {
        out.add(await _message(item));
        k++;
        continue;
      }
      if (type == 'message' || type == 'reasoning' || isToolCall(item)) {
        final group = <Item>[];
        while (k < items.length) {
          final t = items[k]['type'];
          final assistantMessage =
              t == 'message' && items[k]['role'] == 'assistant';
          if (!(assistantMessage || t == 'reasoning' || isToolCall(items[k]))) {
            break;
          }
          group.add(items[k]);
          k++;
        }
        out.add(_assistant(group));
        continue;
      }
      if (isToolOutput(item)) {
        final images = <Map<String, Object?>>[];
        while (k < items.length && isToolOutput(items[k])) {
          final o = items[k];
          final callId = '${o['call_id']}';
          final output = o['output'];
          var text = outputText(output);
          if (output is List) {
            for (final c in output) {
              if (c is! Map || c['type'] != 'input_image') continue;
              final meta = c['dify_sf_view_image'];
              final path = meta is Map ? meta['path'] : null;
              if (text.isEmpty) {
                text = 'Image attached after this result: $path';
              }
              images.add({
                'type': 'text',
                'data': '${images.isEmpty ? '' : '\n'}view_image $path:',
              });
              images.add(await _media(c, defaultDetail: 'high'));
            }
          }
          out.add({
            'role': 'tool',
            'content': text,
            'name': names[callId] ?? '',
            'tool_call_id': callId,
          });
          k++;
        }
        if (images.isNotEmpty) {
          out.add({'role': 'user', 'content': images, 'name': null});
        }
        continue;
      }
      throw ArgumentError('unsupported history item type $type');
    }
    return out;
  }

  Future<Map<String, Object?>> _media(
    Map<dynamic, dynamic> part, {
    String defaultDetail = 'low',
  }) {
    final url = (part['image_url'] ?? part['file_id']) as String;
    final d = part['detail'];
    return mediaPromptContent(
      Media(url: url, contentType: part['dify_sf_mime_type'] as String?),
      inner,
      // Dify knows `low` and `high`; Codex's `original` is sent as `high`.
      detail: d == null ? defaultDetail : (d == 'low' ? 'low' : 'high'),
    );
  }

  Future<Map<String, Object?>> _message(Item item) async {
    final role = item['role'] == 'developer' || item['role'] == 'system'
        ? 'system'
        : 'user';
    final content = (item['content'] as List?) ?? const [];
    final texts = [
      for (final c in content)
        if (c is Map &&
            (c['type'] == 'input_text' || c['type'] == 'output_text'))
          c['text'] as String,
    ];
    final allText = texts.length == content.length;
    if (role == 'system' || (allText && texts.length == 1)) {
      return {'role': role, 'content': texts.join('\n\n'), 'name': null};
    }
    return {
      'role': role,
      'content': [
        for (final c in content)
          if (c is Map && c['type'] == 'input_text')
            {'type': 'text', 'data': c['text']}
          else if (c is Map)
            await _media(c),
      ],
      'name': null,
    };
  }

  Map<String, Object?> _assistant(List<Item> group) {
    final content = StringBuffer();
    final reasoningField = <String>[];
    final toolCalls = <Map<String, Object?>>[];
    for (final i in group) {
      switch (i['type']) {
        case 'reasoning':
          final text = [
            for (final c in (i['content'] as List?) ?? const [])
              if (c is Map) c['text'],
          ].join();
          if (text.isEmpty) continue;
          if (i['dify_sf_form'] == ReasoningForm.reasoningContent.wire) {
            reasoningField.add(text);
          } else {
            content.write('<think>\n$text\n</think>');
          }
        case 'message':
          for (final c in (i['content'] as List?) ?? const []) {
            if (c is Map && c['text'] is String) content.write(c['text']);
          }
        case 'function_call':
          toolCalls.add({
            'id': i['call_id'],
            'type': 'function',
            'function': {'name': i['name'], 'arguments': i['arguments']},
          });
        case 'custom_tool_call':
          // A freeform call from another wire: as a function call whose
          // only argument is the input.
          toolCalls.add({
            'id': i['call_id'],
            'type': 'function',
            'function': {
              'name': i['name'],
              'arguments': jsonEncode({'input': i['input']}),
            },
          });
      }
    }
    return {
      'role': 'assistant',
      'content': content.toString(),
      'name': null,
      'tool_calls': toolCalls,
      if (reasoningField.isNotEmpty) 'reasoning_content': reasoningField.join(),
    };
  }

  static Map<String, Object?> _tool(CodexToolSpec t) => {
    'name': t.name,
    'description': t.description,
    'parameters': t.parameters ?? {'type': 'object', 'properties': {}},
  };

  @override
  Future<SampleResult> sample(
    SampleRequest req, {
    required void Function(String text) onReasoning,
  }) async {
    final r = request;
    final messages = await promptMessages(req.items);
    final tools = [for (final t in req.tools) _tool(t)];
    final messageTexts = [for (final m in messages) jsonEncode(m)];
    final toolsText = jsonEncode(tools);
    final prefix = PromptPrefix.compare(
      _previousMessages,
      _previousTools,
      messageTexts,
      toolsText,
    );
    _previousMessages = messageTexts;
    _previousTools = toolsText;
    final invocationId = invocationIdFor(runId, req.callIndex, req.attempt);
    final body = <String, Object?>{
      'caller': callerJson(r, runId, invocationId, req),
      'target': {
        'provider': r.model.provider,
        'model': r.model.name,
        'prompt_messages': messages,
        'model_parameters': r.model.parameters,
        'tools': tools.isEmpty ? null : tools,
        'stop': null,
        'stream': true,
      },
    };
    final acc = LlmAccumulator();
    final thought = ThoughtBuffer(onReasoning);
    try {
      await for (final chunk in inner.invokeLlm(body)) {
        for (final d in acc.add(chunk)) {
          if (d is ReasoningDelta) thought.add(d.text);
        }
      }
      for (final d in acc.flush()) {
        if (d is ReasoningDelta) thought.add(d.text);
      }
    } finally {
      thought.flush();
    }
    if (acc.usage == null && acc.finishReason == null) {
      throw StreamIncomplete(
        'the model stream ended before its final chunk (no usage, no '
        'finish reason)',
      );
    }
    acc.assignMissingIds();
    final output = <Item>[];
    final think = acc.thinkReasoning.toString().replaceAll(
      RegExp(r'^\n+|\n+$'),
      '',
    );
    if (think.isNotEmpty) {
      output.add(_reasoning(think, ReasoningForm.thinkTag));
    }
    final field = acc.fieldReasoning.toString();
    if (field.isNotEmpty) {
      output.add(_reasoning(field, ReasoningForm.reasoningContent));
    }
    final text = acc.answer.toString();
    if (text.isNotEmpty) {
      output.add({
        'type': 'message',
        'role': 'assistant',
        'content': [
          {'type': 'output_text', 'text': text},
        ],
        'phase': acc.toolCalls.isEmpty ? 'final_answer' : 'commentary',
      });
    }
    for (final c in acc.toolCalls) {
      output.add({
        'type': 'function_call',
        'call_id': c.id,
        'name': c.name.toString(),
        'arguments': c.arguments.toString(),
      });
    }
    final usage = Usage.fromDify(acc.usage ?? const {});
    final effort = r.reasoningEffort;
    return SampleResult(
      invocationId: invocationId,
      output: output,
      usage: usage,
      prefix: prefix,
      finishReason: acc.finishReason,
      reasoning: {
        'effort_requested': effort,
        'effort_sent': effort,
        'effort_sent_by': 'plugin',
        'effort_echoed': null,
        'effort_echoed_null_reason':
            'the plugin wire returns no provider response object',
        'summary_sent': null,
        'encrypted_items_in': 0,
        'encrypted_items_out': 0,
      },
    );
  }

  static Item _reasoning(String text, ReasoningForm form) => {
    'type': 'reasoning',
    'summary': const <Object?>[],
    'content': [
      {'type': 'reasoning_text', 'text': text},
    ],
    'dify_sf_form': form.wire,
  };
}

/// The response stream ended without its final chunk (Codex: a `Stream`
/// error, retried).
class StreamIncomplete implements Exception {
  StreamIncomplete(this.message);
  final String message;
  @override
  String toString() => 'StreamIncomplete: $message';
}

/// Which model wire a run uses, and why.
typedef WireChoice = ({String wire, String reason, bool reducedFidelity});

/// The `codex` style's channel: the native Responses wire when the provider
/// speaks the Responses API (an `openai_api_compatible` credential with
/// `model.api_type: "responses"`, or the OpenAI provider); otherwise the
/// plugin wire, with reduced fidelity (no encrypted reasoning round trip,
/// `apply_patch` as a function, images after the tool message, no provider
/// echo of the effort, no reasoning or cache token counts).
WireChoice selectWire(OperationRequest r) {
  if (r.harnessStyle != HarnessStyle.codex) {
    return (
      wire: 'plugin',
      reason: 'harness_style dify',
      reducedFidelity: false,
    );
  }
  final parts = r.model.provider.split('/');
  final plugin = parts.length == 3 ? parts[1] : r.model.provider;
  final provider = parts.length == 3 ? parts[2] : r.model.provider;
  if (plugin == 'openai_api_compatible' && r.model.apiType == 'responses') {
    return (
      wire: 'responses',
      reason: 'openai_api_compatible in Responses mode',
      reducedFidelity: false,
    );
  }
  if (plugin == 'openai' && provider == 'openai') {
    return (
      wire: 'responses',
      reason: 'the OpenAI provider',
      reducedFidelity: false,
    );
  }
  return (
    wire: 'plugin',
    reason: r.model.apiType == null
        ? 'the provider is not known to speak the Responses API'
        : 'model.api_type ${jsonEncode(r.model.apiType)} is not "responses"',
    reducedFidelity: true,
  );
}

/// Whether [schema] can be sent with `strict: true` as it is (OpenAI's
/// strict mode: every object closed, every property required). The schema
/// is not rewritten; otherwise `text.format` goes with `strict: false`.
bool isStrictSchema(Object? schema) {
  if (schema is Map) {
    if (schema['type'] == 'object' || schema.containsKey('properties')) {
      final props = schema['properties'];
      if (schema['additionalProperties'] != false) return false;
      final required = (schema['required'] as List?)?.toSet() ?? const {};
      if (props is Map && !props.keys.every(required.contains)) return false;
    }
    return schema.values.every(isStrictSchema);
  }
  if (schema is List) return schema.every(isStrictSchema);
  return true;
}

/// The Responses request body Codex builds (`core/src/client.rs`), from
/// the history kept verbatim: reasoning items with `encrypted_content` are
/// sent back on every request.
Map<String, Object?> responsesRequestBody(
  SampleRequest req, {
  required String model,
}) {
  final items = [for (final i in req.items) stripAnnotations(i)];
  return {
    'model': model,
    'input': items,
    'tools': [for (final t in req.tools) t.toResponsesJson()],
    'tool_choice': 'auto',
    'parallel_tool_calls': req.parallelToolCalls,
    'reasoning': {
      'effort': ?req.reasoningEffort,
      'summary': ?req.reasoningSummary,
    },
    'store': false,
    'stream': true,
    'include': ['reasoning.encrypted_content'],
    'prompt_cache_key': req.promptCacheKey,
    if (req.outputSchema case final schema?)
      'text': {
        'format': {
          'type': 'json_schema',
          'name': 'codex_output_schema',
          'strict': isStrictSchema(schema),
          'schema': schema,
        },
      },
  };
}

/// The classification of a Responses `error` (`response.failed`, an
/// `error` event), after `api_bridge.rs`.
ModelCallFailure responsesFailure(Map<dynamic, dynamic>? error) {
  final code = '${error?['code'] ?? error?['type'] ?? ''}';
  final message = '${error?['message'] ?? 'the response failed'}';
  final text = code.isEmpty ? message : '$code: $message';
  return switch (code) {
    'rate_limit_exceeded' ||
    'slow_down' => ModelCallFailure(ModelFailureKind.rateLimited, text),
    'server_is_overloaded' => ModelCallFailure(
      ModelFailureKind.overloaded,
      text,
    ),
    'insufficient_quota' || 'usage_limit_reached' || 'usage_not_included' =>
      ModelCallFailure(ModelFailureKind.quota, text, errorType: 'model_quota'),
    'context_length_exceeded' ||
    'invalid_prompt' ||
    'invalid_request_error' ||
    'cyber_policy' ||
    'bio_policy' => ModelCallFailure(ModelFailureKind.invalidRequest, text),
    _ => ModelCallFailure(ModelFailureKind.stream, text),
  };
}

/// The native Responses wire: agent_service builds the Codex request body
/// ([responsesRequestBody]) and `POST /inner/agent/responses` forwards it
/// to the provider of the workspace credential and streams the provider's
/// events back unchanged (docs/agent-v2.md, "Model wire").
class ResponsesTransport implements ModelTransport {
  ResponsesTransport({
    required this.inner,
    required this.request,
    required this.runId,
  });

  final InnerClient inner;
  final OperationRequest request;
  final String runId;
  List<String>? _previousItems;
  String? _previousTools;

  @override
  String get wire => 'responses';
  @override
  bool get freeformTools => true;
  @override
  bool get imagesInToolOutputs => true;
  @override
  bool get reasoningRoundTrip => true;

  @override
  void close() => inner.close();

  static int _encrypted(Iterable<Item> items) => items
      .where(
        (i) => i['type'] == 'reasoning' && i['encrypted_content'] is String,
      )
      .length;

  @override
  Future<SampleResult> sample(
    SampleRequest req, {
    required void Function(String text) onReasoning,
  }) async {
    final r = request;
    final invocationId = invocationIdFor(runId, req.callIndex, req.attempt);
    final body = responsesRequestBody(req, model: r.model.name);
    final itemTexts = [for (final i in body['input'] as List) jsonEncode(i)];
    final toolsText = jsonEncode(body['tools']);
    final prefix = PromptPrefix.compare(
      _previousItems,
      _previousTools,
      itemTexts,
      toolsText,
    );
    _previousItems = itemTexts;
    _previousTools = toolsText;
    final opened = await inner.openResponses({
      'caller': callerJson(r, runId, invocationId, req),
      'target': {
        'provider': r.model.provider,
        'model': r.model.name,
        'model_parameters': r.model.parameters,
      },
      'request': body,
    });
    final output = <Item>[];
    final thought = ThoughtBuffer(onReasoning);
    Map<dynamic, dynamic>? response;
    String? finish;
    try {
      await for (final data in opened.events) {
        final Object? e;
        try {
          e = jsonDecode(data);
        } on FormatException {
          throw StreamIncomplete('malformed Responses event');
        }
        if (e is! Map) continue;
        switch (e['type']) {
          case 'response.output_item.done':
            final item = e['item'];
            if (item is Map) output.add(item.cast<String, Object?>());
          case 'response.reasoning_summary_text.delta' ||
              'response.reasoning_text.delta':
            final d = e['delta'];
            if (d is String) thought.add(d);
          case 'response.completed':
            response = e['response'] as Map?;
            finish = 'stop';
          case 'response.incomplete':
            response = e['response'] as Map?;
            final reason = (response?['incomplete_details'] as Map?)?['reason'];
            finish = reason == 'max_output_tokens' ? 'length' : '$reason';
          case 'response.failed':
            throw responsesFailure((e['response'] as Map?)?['error'] as Map?);
          case 'error':
            throw responsesFailure(e['error'] is Map ? e['error'] as Map : e);
        }
      }
    } finally {
      thought.flush();
    }
    if (response == null) {
      throw StreamIncomplete(
        'the Responses stream ended before response.completed',
      );
    }
    final u = (response['usage'] as Map?) ?? const {};
    int? n(Object? v) => v is num ? v.toInt() : null;
    final cached = n((u['input_tokens_details'] as Map?)?['cached_tokens']);
    final reasoningTokens = n(
      (u['output_tokens_details'] as Map?)?['reasoning_tokens'],
    );
    final usage = Usage()
      ..promptTokens = n(u['input_tokens']) ?? 0
      ..completionTokens = n(u['output_tokens']) ?? 0
      ..reasoningTokens = reasoningTokens
      ..promptCacheHitTokens = cached;
    usage.totalTokens =
        n(u['total_tokens']) ?? usage.promptTokens + usage.completionTokens;
    if (cached != null) {
      usage.promptCacheMissTokens = (usage.promptTokens - cached).clamp(
        0,
        usage.promptTokens,
      );
    }
    final echoed = (response['reasoning'] as Map?)?['effort'];
    return SampleResult(
      invocationId: invocationId,
      output: output,
      usage: usage,
      prefix: prefix,
      finishReason: finish,
      reasoning: {
        'effort_requested': r.reasoningEffort,
        'effort_sent': req.reasoningEffort,
        'effort_sent_by': 'agent_service',
        'effort_forwarded': opened.headers['x-dify-sf-forwarded-reasoning'],
        'effort_echoed': echoed is String ? echoed : null,
        if (echoed is! String)
          'effort_echoed_null_reason':
              'the provider echoed no reasoning.effort',
        'summary_sent': req.reasoningSummary,
        'encrypted_items_in': _encrypted(req.items),
        'encrypted_items_out': _encrypted(output),
      },
    );
  }
}
