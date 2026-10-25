/// A Genkit model that calls the Swift inner gateway
/// (`POST /inner/agent/llm/invoke`), mapping Genkit messages to Dify
/// `PromptMessage` JSON and Dify `LLMResultChunk`s back to Genkit.
library;

import 'dart:async';
import 'dart:convert';

import 'package:genkit/genkit.dart';

import 'gateway.dart';
import 'protocol.dart';

/// URL scheme of task files inside the Genkit history. Snapshots store the
/// stable `file_id` only and model requests carry the same reference.
const fileUrlScheme = 'dify-sf-file:';

/// Largest `thought` event: longer reasoning of one model call is split.
const thoughtPieceChars = 16 * 1024;

/// Metadata key on a [ReasoningPart] recording how the reasoning arrived.
const reasoningFormKey = 'dify_sf_reasoning_form';

/// Metadata key on a [ToolRequestPart] keeping the provider's raw arguments.
const rawArgumentsKey = 'dify_sf_arguments';

/// Per-run state of the gateway model.
class GatewayModelContext {
  GatewayModelContext({
    required this.inner,
    required this.request,
    required this.runId,
    required this.onReasoning,
    required this.onModelCall,
  });

  final InnerClient inner;
  final OperationRequest request;
  final String runId;

  /// Called with every streamed reasoning piece (a `thought` event).
  final void Function(String text) onReasoning;

  /// Called once per completed model call with its usage.
  final void Function(String invocationId, Usage usage) onModelCall;

  int callIndex = 0;
}

Model defineGatewayModel(Genkit ai, GatewayModelContext c) {
  return ai.defineModel(
    name: 'dify-sf/gateway',
    info: ModelInfo(
      label: 'dify-sf inner gateway',
      supports: const {
        'multiturn': true,
        'media': true,
        'tools': true,
        'systemRole': true,
        'constrained': 'none',
      },
    ),
    fn: (request, ctx) => _raceCancel(ctx.cancel, () => _call(c, request, ctx)),
  );
}

/// Resolves as soon as [token] is cancelled, so a model call that waits on a
/// silent connection ends promptly.
Future<T> _raceCancel<T>(CancellationToken? token, Future<T> Function() body) {
  if (token == null) return body();
  token.throwIfCancelled();
  final work = body();
  return Future.any<T>([
    work,
    token.whenCancelled.then<T>((_) {
      // The abandoned call fails once its client is closed; nobody awaits it.
      work.ignore();
      throw CancelledException(reason: token.reason, token: token);
    }),
  ]);
}

Future<ModelResponse> _call(
  GatewayModelContext c,
  ModelRequest request,
  ActionFnArg<ModelResponseChunk, ModelRequest, void> ctx,
) async {
  c.callIndex++;
  final callIndex = c.callIndex;
  final invocationId = '${c.runId}:$callIndex';
  final r = c.request;
  final x = r.execution;
  final promptMessages = await toPromptMessages(request.messages, c.inner);
  final tools = [
    for (final t in request.tools ?? const <ToolDefinition>[])
      toPromptMessageTool(t),
  ];
  final body = <String, Object?>{
    'caller': {
      'invocation_id': invocationId,
      'run_id': c.runId,
      'call_index': callIndex,
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
    },
    'target': {
      'provider': r.model.provider,
      'model': r.model.name,
      'prompt_messages': promptMessages,
      'model_parameters': r.model.parameters,
      'tools': tools.isEmpty ? null : tools,
      'stop': null,
      'stream': true,
    },
  };

  final acc = LlmAccumulator();
  // Reasoning streams in many tiny pieces. The run record gets one `thought`
  // per model call (split only above [thoughtPieceChars]), not one per chunk.
  final thought = StringBuffer();
  void flushThought() {
    if (thought.isEmpty) return;
    c.onReasoning(thought.toString());
    thought.clear();
  }

  void forward(List<LlmDelta> deltas) {
    for (final d in deltas) {
      switch (d) {
        case ReasoningDelta():
          thought.write(d.text);
          if (thought.length >= thoughtPieceChars) flushThought();
          ctx.sendChunk(
            ModelResponseChunk(
              index: 0,
              content: [ReasoningPart(reasoning: d.text)],
            ),
          );
        case TextDelta():
          ctx.sendChunk(
            ModelResponseChunk(index: 0, content: [TextPart(text: d.text)]),
          );
      }
    }
  }

  try {
    await for (final chunk in c.inner.invokeLlm(body)) {
      forward(acc.add(chunk));
    }
    forward(acc.flush());
  } finally {
    flushThought();
  }
  acc.assignMissingIds();

  final usage = Usage.fromDify(acc.usage ?? const {});
  c.onModelCall(invocationId, usage);
  return ModelResponse(
    finishReason: mapFinishReason(acc.finishReason),
    message: responseMessage(acc),
    usage: GenerationUsage(
      inputTokens: usage.promptTokens,
      outputTokens: usage.completionTokens,
      totalTokens: usage.totalTokens,
      thoughtsTokens: usage.reasoningTokens,
    ),
    custom: {'invocation_id': invocationId},
  );
}

FinishReason mapFinishReason(String? reason) => switch (reason?.toLowerCase()) {
  null ||
  'stop' ||
  'tool_calls' ||
  'tool_call' ||
  'function_call' => FinishReason.stop,
  'length' => FinishReason.length,
  'content_filter' => FinishReason.blocked,
  _ => FinishReason.unknown,
};

/// The Genkit message of one finished model call: reasoning first (one part
/// per form, the form in metadata), then the answer, then tool requests with
/// the provider's tool call IDs unchanged.
Message responseMessage(LlmAccumulator acc) {
  final parts = <Part>[];
  final think = _trimNewlines(acc.thinkReasoning.toString());
  if (think.isNotEmpty) {
    parts.add(
      ReasoningPart(
        reasoning: think,
        metadata: {reasoningFormKey: ReasoningForm.thinkTag.wire},
      ),
    );
  }
  final field = acc.fieldReasoning.toString();
  if (field.isNotEmpty) {
    parts.add(
      ReasoningPart(
        reasoning: field,
        metadata: {reasoningFormKey: ReasoningForm.reasoningContent.wire},
      ),
    );
  }
  final text = acc.answer.toString();
  if (text.isNotEmpty) parts.add(TextPart(text: text));
  for (final call in acc.toolCalls) {
    final raw = call.arguments.toString();
    Object? input;
    if (raw.trim().isEmpty) {
      input = <String, Object?>{};
    } else {
      try {
        input = jsonDecode(raw);
      } on FormatException {
        input = null;
      }
    }
    parts.add(
      ToolRequestPart(
        toolRequest: ToolRequest(
          ref: call.id,
          name: call.name.toString(),
          input: input,
        ),
        metadata: {rawArgumentsKey: raw},
      ),
    );
  }
  return Message(role: Role.model, content: parts);
}

String _trimNewlines(String s) {
  var start = 0;
  var end = s.length;
  while (start < end && s[start] == '\n') {
    start++;
  }
  while (end > start && s[end - 1] == '\n') {
    end--;
  }
  return s.substring(start, end);
}

/// Dify `PromptMessageTool`. Genkit's `$schema` marker is dropped: Dify's
/// tool parameters carry none.
Map<String, Object?> toPromptMessageTool(ToolDefinition t) => {
  'name': t.name,
  'description': t.description,
  'parameters': t.inputSchema == null
      ? {'type': 'object', 'properties': {}}
      : (Map<String, Object?>.of(t.inputSchema!)..remove(r'$schema')),
};

/// Genkit messages → Dify `PromptMessage` JSON. System content is merged
/// into one leading system message (as dify-agent does); task files are
/// sent as `dify-sf-file:<file_id>` references.
Future<List<Map<String, Object?>>> toPromptMessages(
  List<Message> messages,
  InnerClient inner,
) async {
  final system = <String>[];
  final out = <Map<String, Object?>>[];
  for (final m in messages) {
    switch (m.role) {
      case Role.system:
        final text = m.text;
        if (text.trim().isNotEmpty) system.add(text);
      case Role.user:
        out.add({
          'role': 'user',
          'content': await _userContent(m.content, inner),
          'name': null,
        });
      case Role.model:
        out.add(_assistant(m));
      case Role.tool:
        for (final p in m.content) {
          final r = p.toolResponse;
          if (r == null) continue;
          final output = r.output;
          out.add({
            'role': 'tool',
            'content': output is String ? output : jsonEncode(output),
            'name': r.name,
            'tool_call_id': r.ref ?? '',
          });
        }
      default:
        throw ArgumentError('unsupported role ${m.role}');
    }
  }
  return [
    if (system.isNotEmpty)
      {'role': 'system', 'content': system.join('\n\n'), 'name': null},
    ...out,
  ];
}

Future<Object?> _userContent(List<Part> parts, InnerClient inner) async {
  final items = <Map<String, Object?>>[];
  for (final p in parts) {
    if (p.isText) {
      items.add({'type': 'text', 'data': p.text});
    } else if (p.isMedia) {
      items.add(await _mediaContent(p.media!, inner));
    }
  }
  if (items.every((i) => i['type'] == 'text')) {
    return items.map((i) => i['data']).join();
  }
  return items;
}

Future<Map<String, Object?>> _mediaContent(
  Media media,
  InnerClient inner,
) async {
  // Task files stay `dify-sf-file:<file_id>` references: the Swift gateway
  // checks the file against the run token's execution and reads it from
  // storage. No URL is sent and the gateway never fetches one.
  final url = media.url;
  final mime = media.contentType ?? 'application/octet-stream';
  if (!url.startsWith(fileUrlScheme)) {
    throw GatewayException(
      'file_error',
      'media must reference an execution file ($fileUrlScheme<file_id>)',
    );
  }
  final fileId = url.substring(fileUrlScheme.length);
  final base = mime.split(';').first.trim().toLowerCase();
  final format = base.contains('/') ? base.split('/').last : 'bin';
  final type = switch (base.split('/').first) {
    'image' => 'image',
    'audio' => 'audio',
    'video' => 'video',
    _ => 'document',
  };
  return {
    'type': type,
    'url': url,
    'base64_data': '',
    'format': format,
    'mime_type': base,
    'filename': '$fileId.$format',
    if (type == 'image') 'detail': 'low',
  };
}

Map<String, Object?> _assistant(Message m) {
  final content = StringBuffer();
  final reasoningField = <String>[];
  final toolCalls = <Map<String, Object?>>[];
  for (final p in m.content) {
    if (p.isReasoning) {
      final text = p.reasoning ?? '';
      if (text.isEmpty) continue;
      final form = ReasoningForm.parse(p.metadata?[reasoningFormKey]);
      if (form == ReasoningForm.reasoningContent) {
        reasoningField.add(text);
      } else {
        content.write('<think>\n$text\n</think>');
      }
    } else if (p.isText) {
      content.write(p.text);
    } else if (p.isToolRequest) {
      final t = p.toolRequest!;
      final raw = p.metadata?[rawArgumentsKey];
      toolCalls.add({
        'id': t.ref ?? '',
        'type': 'function',
        'function': {
          'name': t.name,
          'arguments': raw is String ? raw : jsonEncode(t.input ?? {}),
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
