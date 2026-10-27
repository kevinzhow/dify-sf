/// A Genkit model that calls the Swift inner gateway
/// (`POST /inner/agent/llm/invoke`), mapping Genkit messages to Dify
/// `PromptMessage` JSON and Dify `LLMResultChunk`s back to Genkit.
library;

import 'dart:async';
import 'dart:convert';

import 'package:genkit/genkit.dart';

import 'gateway.dart';
import 'protocol.dart';
import 'view_image.dart';

/// URL scheme of task files inside the Genkit history. Snapshots store the
/// stable `file_id` only and model requests carry the same reference.
const fileUrlScheme = 'dify-sf-file:';

/// Largest `thought` text in UTF-8 bytes: longer reasoning of one model call
/// is split.
const thoughtPieceBytes = 16 * 1024;

/// Collects the reasoning of one model call into `thought` texts of at most
/// [maxBytes] UTF-8 bytes each, cut only between code points.
class ThoughtBuffer {
  ThoughtBuffer(this.emit, {this.maxBytes = thoughtPieceBytes});

  final void Function(String text) emit;
  final int maxBytes;
  final _text = StringBuffer();
  int _bytes = 0;

  void add(String text) {
    for (final rune in text.runes) {
      // A lone surrogate is written as U+FFFD: 3 bytes.
      final n = rune < 0x80
          ? 1
          : rune < 0x800
          ? 2
          : rune < 0x10000
          ? 3
          : 4;
      if (_bytes + n > maxBytes) flush();
      _text.writeCharCode(rune);
      _bytes += n;
    }
  }

  void flush() {
    if (_text.isEmpty) return;
    emit(_text.toString());
    _text.clear();
    _bytes = 0;
  }
}

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

  /// Called once per completed model call with its usage and the
  /// [PromptPrefix] check of its request.
  final void Function(String invocationId, Usage usage, PromptPrefix prefix)
  onModelCall;

  /// Called right before each model call with its index (1-based).
  void Function(int callIndex)? onCallStart;

  int callIndex = 0;

  /// The previous call's prompt messages and tools, each as JSON text.
  List<String>? _previousMessages;
  String? _previousTools;
}

/// Whether a model request repeats the previous request of the run byte for
/// byte before appending to it: the condition for a provider's prefix cache
/// to serve the earlier part. Compared on the request the service sends to
/// the gateway (file references, not bytes).
class PromptPrefix {
  const PromptPrefix({
    required this.messages,
    this.stable,
    this.firstChangedMessage,
  });

  /// Number of prompt messages of this request.
  final int messages;

  /// Null for the first call of a run; true when the previous request's
  /// tools are unchanged and its messages are an unchanged prefix of this
  /// request's.
  final bool? stable;

  /// The index of the first earlier message that changed or disappeared
  /// (`-1`: only the tools changed); null when stable or first.
  final int? firstChangedMessage;

  static PromptPrefix compare(
    List<String>? previous,
    String? previousTools,
    List<String> current,
    String tools,
  ) {
    if (previous == null) return PromptPrefix(messages: current.length);
    for (var i = 0; i < previous.length; i++) {
      if (i >= current.length || previous[i] != current[i]) {
        return PromptPrefix(
          messages: current.length,
          stable: false,
          firstChangedMessage: i,
        );
      }
    }
    if (previousTools != tools) {
      return PromptPrefix(
        messages: current.length,
        stable: false,
        firstChangedMessage: -1,
      );
    }
    return PromptPrefix(messages: current.length, stable: true);
  }

  Map<String, Object?> toJson() => {
    'messages': messages,
    'prefix_stable': stable,
    'first_changed_message': firstChangedMessage,
  };
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
  c.onCallStart?.call(callIndex);
  final invocationId = '${c.runId}:$callIndex';
  final r = c.request;
  final x = r.execution;
  final promptMessages = await toPromptMessages(request.messages, c.inner);
  final tools = [
    for (final t in request.tools ?? const <ToolDefinition>[])
      toPromptMessageTool(t),
  ];
  final messageTexts = [for (final m in promptMessages) jsonEncode(m)];
  final toolsText = jsonEncode(tools);
  final prefix = PromptPrefix.compare(
    c._previousMessages,
    c._previousTools,
    messageTexts,
    toolsText,
  );
  c._previousMessages = messageTexts;
  c._previousTools = toolsText;
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
  // per model call (split only above [thoughtPieceBytes]), not one per chunk.
  final thought = ThoughtBuffer(c.onReasoning);

  void forward(List<LlmDelta> deltas) {
    for (final d in deltas) {
      switch (d) {
        case ReasoningDelta():
          thought.add(d.text);
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
    thought.flush();
  }
  acc.assignMissingIds();

  final usage = Usage.fromDify(acc.usage ?? const {});
  c.onModelCall(invocationId, usage, prefix);
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
///
/// The result depends on [messages] only, and a longer history gives the
/// same JSON for its earlier messages: the request prefix stays byte-stable
/// for the provider's prompt cache.
///
/// Images of `view_image` results (multipart tool response content) follow
/// their tool messages as a user message (tool messages carry text only),
/// in every call from the one right after the tool ran. Parts from
/// snapshots taken before images were kept (no `size` in their metadata)
/// are not sent.
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
        final images = <Map<String, Object?>>[];
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
          for (final c in r.content ?? const []) {
            if (c is! Map) continue;
            final media = c['media'];
            final meta = (c['metadata'] as Map?)?[viewImageMetadataKey];
            if (media is! Map || meta is! Map || meta['size'] is! int) continue;
            images.add({
              'type': 'text',
              'data':
                  '${images.isEmpty ? '' : '\n'}view_image ${meta['path']}:',
            });
            images.add(
              await _mediaContent(
                Media(
                  url: media['url'] as String,
                  contentType: media['contentType'] as String?,
                ),
                inner,
                detail: meta['detail'] == 'low' ? 'low' : 'high',
              ),
            );
          }
        }
        if (images.isNotEmpty) {
          out.add({'role': 'user', 'content': images, 'name': null});
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
  InnerClient inner, {
  String detail = 'low',
}) async {
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
    if (type == 'image') 'detail': detail,
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
