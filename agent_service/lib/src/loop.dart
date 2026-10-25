/// One run of the agent loop: a per-run Genkit instance with the gateway
/// model, the `ask_human` tool and the event middleware.
library;

import 'dart:async';
import 'dart:convert';

import 'package:genkit/genkit.dart';
import 'package:schemantic/schemantic.dart';

import 'ask_human.dart';
import 'file_outputs.dart';
import 'gateway.dart';
import 'model.dart';
import 'output_tool.dart';
import 'protocol.dart';
import 'run_store.dart';
import 'sandbox/sandbox.dart';
import 'sandbox/shell_tools.dart';

/// More than one `ask_human` call in one model turn (as in Dify).
class AskHumanInvalid implements Exception {
  AskHumanInvalid(this.message);
  final String message;
  @override
  String toString() => 'AskHumanInvalid: $message';
}

/// A model turn called `final_output`: the run ends with its arguments and
/// no tool of that turn is executed (pydantic-ai's `end_strategy='early'`).
class FinalOutputReached implements Exception {
  FinalOutputReached(this.history, this.response);

  /// The messages sent to the model in that turn.
  final List<Message> history;

  /// The model message holding the `final_output` call.
  final Message response;
}

/// Why a run was stopped from outside the loop.
enum StopReason {
  /// `POST /v1/runs/{id}/cancel` or `DELETE /v1/executions/{id}`.
  cancel,

  /// The execution's lease expired.
  cancelLost,

  /// `limits.timeout_seconds` elapsed.
  timeout,

  /// The service is shutting down.
  shutdown,
}

/// Tool definitions as the model sees them, for the snapshot digest.
List<Map<String, Object?>> toolDefinitions(OperationRequest r) => [
  if (r.askHuman)
    {
      'name': askHumanToolName,
      'description': askHumanDescription,
      'parameters': askHumanInputSchema,
    },
  if (r.outputSchema case final schema?)
    {
      'name': finalOutputToolName,
      'description': finalOutputTool(modelFacingSchema(schema)).description,
      'parameters': finalOutputTool(modelFacingSchema(schema)).parameters,
    },
  if (r.shell)
    for (final e in shellToolDefinitions.entries)
      {
        'name': e.key,
        'description': e.value.description,
        'parameters': e.value.parameters,
      },
];

String toolDefinitionsDigest(OperationRequest r) =>
    sha256Hex(canonicalJson({'tools': toolDefinitions(r), 'shell': r.shell}));

ApiError _incompatible(String why) =>
    ApiError(422, 'snapshot_incompatible', why);

/// Checks a continuation's snapshot against [r]; throws `422
/// snapshot_incompatible`. Returns the snapshot's Genkit messages.
List<Message> verifyContinuation(OperationRequest r) {
  final c = r.continuation;
  if (c == null) return const [];
  final s = c.snapshot;
  if (s['envelope'] != envelopeName) {
    throw _incompatible(
      'snapshot envelope ${jsonEncode(s['envelope'])} is not $envelopeName',
    );
  }
  final genkit = s['genkit'];
  if (genkit is! String ||
      genkit.split('.').first != genkitVersion.split('.').first) {
    throw _incompatible(
      'snapshot Genkit version ${jsonEncode(genkit)} is not compatible with '
      '$genkitVersion',
    );
  }
  if (s['agent_config_snapshot_id'] != r.execution.agentConfigSnapshotId) {
    throw _incompatible(
      'snapshot belongs to a different agent_config_snapshot_id',
    );
  }
  if (s['tool_definitions_digest'] != toolDefinitionsDigest(r)) {
    throw _incompatible('snapshot was taken with different tool definitions');
  }
  if (s['revision'] is! int) throw _incompatible('snapshot has no revision');
  final pending = s['pending'];
  final List<Message> messages;
  try {
    messages = [
      for (final m in s['messages'] as List)
        Message.fromJson((m as Map).cast<String, dynamic>()),
    ];
  } catch (_) {
    throw _incompatible('snapshot messages are not Genkit messages');
  }
  // A run ended by `final_output` ends with the tool message answering it.
  final lastRole = messages.isEmpty ? null : messages.last.role;
  if (lastRole != Role.model &&
      !(c is OutputRetryContinuation && lastRole == Role.tool)) {
    throw _incompatible('snapshot does not end with a model message');
  }
  switch (c) {
    case AnswerContinuation():
      if (s['resume_sequence'] != r.resumeSequence - 1 ||
          s['output_attempt'] != r.outputAttempt) {
        throw _incompatible(
          'snapshot is not the one answered by this operation_id',
        );
      }
      if (pending is! Map) {
        throw _incompatible('snapshot has no pending question');
      }
      if (pending['question_id'] != c.questionId) {
        throw _incompatible(
          'question_id ${c.questionId} is not the pending question',
        );
      }
      final toolCallId = pending['tool_call_id'];
      if (toolCallId is! String || _pendingPart(messages, toolCallId) == null) {
        throw _incompatible('the pending tool call is not in the snapshot');
      }
    case OutputRetryContinuation():
      if (s['output_attempt'] != r.outputAttempt - 1 ||
          s['resume_sequence'] != r.resumeSequence) {
        throw _incompatible(
          'snapshot is not the one retried by this operation_id',
        );
      }
      if (pending != null) {
        throw _incompatible('a paused snapshot cannot be retried; answer it');
      }
  }
  return messages;
}

ToolRequestPart? _pendingPart(List<Message> messages, String toolCallId) {
  for (final p in messages.last.content) {
    final t = p.toolRequestPart;
    if (t != null &&
        t.toolRequest.ref == toolCallId &&
        t.toolRequest.name == askHumanToolName &&
        (t.metadata?.containsKey('interrupt') ?? false)) {
      return t;
    }
  }
  return null;
}

/// Per-field JSON Schema violations of [candidate].
Future<List<Map<String, Object?>>> candidateErrors(
  Map<String, Object?> schema,
  Object? candidate,
) async {
  final type = SchemanticType.from<Object?>(
    jsonSchema: inlineLocalDefs(schema),
    parse: (j) => j,
  );
  final errors = await type.validate(candidate);
  final missing = RegExp(r'^Required property "(.+)" is missing$');
  return [
    for (final e in errors)
      if (e.path.isNotEmpty)
        {
          'field': e.path.first,
          'error': [
            e.details ?? e.error.name,
            if (e.path.length > 1) 'at ${e.path.skip(1).join('.')}',
          ].join(' '),
        }
      else
        {
          'field': missing.firstMatch(e.details ?? '')?.group(1) ?? '',
          'error': e.details ?? e.error.name,
        },
  ];
}

/// One run of one operation.
class AgentRun {
  AgentRun({
    required this.record,
    required this.request,
    required this.store,
    required this.innerBase,
    required this.serviceKey,
    required this.runToken,
    this.sandboxes,
    this.log,
  });

  final RunRecord record;
  final OperationRequest request;
  final RunStore store;
  final Uri? innerBase;
  final String serviceKey;

  /// `X-Agent-Run-Token` of the operation request; kept in memory only.
  final String? runToken;

  /// The service's sandboxes; null or disabled means no shell.
  final SandboxManager? sandboxes;
  final void Function(String message)? log;

  final StreamController<RunEvent> _events = StreamController.broadcast(
    sync: true,
  );
  final Completer<RunEvent> _done = Completer();
  final CancellationController _cancel = CancellationController();
  StopReason? _stopReason;
  InnerClient? _inner;
  final Usage usage = Usage();

  /// The shell of this run, opened on the first shell tool call.
  Future<ShellSession>? _sessionFuture;
  ShellSession? _session;

  /// The sandbox this run used (its `workspace_ref`).
  String? _sandboxId;

  String get runId => record.runId;
  Stream<RunEvent> get events => _events.stream;
  Future<RunEvent> get done => _done.future;
  bool get isEnded => record.isEnded;

  /// Stops the run: the model call in flight (its HTTP client is closed) and
  /// the tool in flight; the run then ends promptly.
  void stop(StopReason reason) {
    if (record.isEnded || _stopReason != null) return;
    _stopReason = reason;
    _cancel.cancel(reason.name);
    _inner?.close();
    _session?.abort();
  }

  void _emit(String event, Map<String, Object?> data) {
    if (record.isEnded) return;
    _events.add(store.append(record, event, data));
  }

  void _finish(String event, Map<String, Object?> data) {
    if (record.isEnded) return;
    final e = store.finish(record, event, data);
    _events.add(e);
    unawaited(_events.close());
    _done.complete(e);
  }

  Future<void> start() async {
    try {
      await _execute();
    } catch (e, st) {
      log?.call('run $runId failed internally: $e\n$st');
      await _endShell();
      _finish('failed', {
        'error_type': 'internal',
        'message': 'internal error: $e',
        'usage': usage.toJson(),
      });
    }
  }

  void _finishStopped(StopReason reason) {
    switch (reason) {
      case StopReason.cancel:
        _finish('cancelled', {'usage': usage.toJson()});
      case StopReason.cancelLost:
        _finish('failed', {
          'error_type': 'cancel_lost',
          'message': 'the execution lease expired; the run was cancelled',
          'usage': usage.toJson(),
        });
      case StopReason.timeout:
        _finish('failed', {
          'error_type': 'timeout',
          'message': 'the run exceeded ${request.timeoutSeconds} seconds',
          'usage': usage.toJson(),
        });
      case StopReason.shutdown:
        _finish('failed', {
          'error_type': 'internal',
          'message': 'the agent service shut down during the run',
          'usage': usage.toJson(),
        });
    }
  }

  void _fail(String type, String message) => _finish('failed', {
    'error_type': type,
    'message': message,
    'usage': usage.toJson(),
  });

  Future<void> _execute() async {
    final r = request;
    _emit('run_started', {
      'model': {'provider': r.model.provider, 'name': r.model.name},
      'call_index_base': 0,
    });
    if (r.shell && !(sandboxes?.enabled ?? false)) {
      return _fail(
        'sandbox_unavailable',
        'the shell tool is not available: this agent service has no sandbox',
      );
    }
    final base = innerBase;
    if (base == null) {
      return _fail('internal', 'AGENT_INNER_URL is not configured');
    }
    if (_stopReason != null) return _finishStopped(_stopReason!);
    final inner = _inner = InnerClient(
      baseUrl: base,
      serviceKey: serviceKey,
      runToken: runToken,
    );
    final timer = Timer(
      Duration(seconds: r.timeoutSeconds),
      () => stop(StopReason.timeout),
    );
    final ai = Genkit(isDevEnv: false, promptDir: null);
    try {
      final model = defineGatewayModel(
        ai,
        GatewayModelContext(
          inner: inner,
          request: r,
          runId: runId,
          onReasoning: (t) => _emit('thought', {'text': t}),
          onModelCall: (id, u) {
            usage.add(u);
            _emit('model_call', {'invocation_id': id, 'usage': u.toJson()});
          },
        ),
      );
      if (r.askHuman) _defineAskHuman(ai);
      if (r.shell) _defineShellTools(ai);
      final outputSchema = r.outputSchema;
      if (outputSchema != null) _defineFinalOutput(ai, outputSchema);
      final events = ai.defineGenerateMiddleware<void>(
        name: 'dify_sf_events',
        create: (_, _) => _EventsMiddleware(this),
      );

      var messages = <Message>[];
      List<InterruptResponse>? respond;
      var revision = 0;
      final c = r.continuation;
      if (c == null) {
        final system = [
          if (r.shell) shellPrefixPrompt,
          if (r.systemPrompt.trim().isNotEmpty) r.systemPrompt,
          if (r.askHuman) askHumanPromptHint(),
          if (r.shell) shellSuffixPrompt,
        ].join('\n\n');
        messages = [
          if (system.isNotEmpty)
            Message(
              role: Role.system,
              content: [TextPart(text: system)],
            ),
          Message(
            role: Role.user,
            content: [
              for (final p in r.task)
                switch (p) {
                  TaskText() => TextPart(text: p.text),
                  TaskFile() => MediaPart(
                    media: Media(
                      url: '$fileUrlScheme${p.fileId}',
                      contentType: p.mimeType,
                    ),
                  ),
                },
            ],
          ),
        ];
      } else {
        messages = verifyContinuation(r).toList();
        revision = c.snapshot['revision'] as int;
        switch (c) {
          case AnswerContinuation():
            final pending = c.snapshot['pending'] as Map;
            final part = _pendingPart(
              messages,
              pending['tool_call_id'] as String,
            )!;
            respond = [InterruptResponse(part, c.result)];
            _emit('tool_call', {
              'id': part.toolRequest.ref,
              'name': part.toolRequest.name,
              'phase': 'finished',
              'output': c.result,
            });
          case OutputRetryContinuation():
            messages.add(
              Message(
                role: Role.user,
                content: [TextPart(text: _feedbackText(c.feedback))],
              ),
            );
        }
      }

      final generation = ai.generate<Object?, void>(
        model: model,
        messages: messages,
        toolNames: [
          if (r.askHuman) askHumanToolName,
          if (outputSchema != null) finalOutputToolName,
          if (r.shell) ...shellToolNames,
        ],
        maxTurns: r.maxTurns,
        onChunk: (_) {},
        use: [events()],
        cancel: _cancel.token,
        interruptRespond: respond,
      );
      // Backstop: a stop ends the run even if the loop does not return.
      final result = await Future.any<GenerateResult<Object?>?>([
        generation,
        _cancel.token.whenCancelled.then(
          (_) => Future.delayed(const Duration(milliseconds: 300), () => null),
        ),
      ]);
      // The run's jobs and their descendants end before the result exists.
      await _endShell();
      await _complete(result, revision);
    } finally {
      await _endShell();
      timer.cancel();
      inner.close();
      unawaited(ai.shutdown());
    }
  }

  Future<void> _complete(GenerateResult<Object?>? result, int revision) async {
    // A stop requested before the loop returned wins: the stream it cut
    // short may look like a normal end.
    final stopped = _stopReason;
    if (stopped != null) return _finishStopped(stopped);
    if (result == null) {
      return _fail('internal', 'the agent loop returned no result');
    }

    switch (result.finishReason.value) {
      case 'interrupted':
        final interrupts = result.interrupts;
        if (interrupts.length != 1) {
          return _fail(
            'ask_human_invalid',
            'ask_human supports exactly one call per turn; got ${interrupts.length}',
          );
        }
        final part = interrupts.single;
        final data = part.metadata?['interrupt'];
        final question = data is Map ? data['question'] : null;
        final questionId =
            '${request.execution.executionId}:q${request.resumeSequence + 1}';
        final toolCallId = part.toolRequest.ref ?? '';
        _finish('paused', {
          'question_id': questionId,
          'tool_call_id': toolCallId,
          'question': question,
          'snapshot': _snapshot(
            revision + 1,
            result.messages,
            pending: {'question_id': questionId, 'tool_call_id': toolCallId},
          ),
          'usage': usage.toJson(),
        });
      case 'aborted':
        _fail(
          'max_turns',
          'the run reached max_turns (${request.maxTurns}) without a final answer',
        );
      case 'failed':
        final finalOutput = _findFinalOutput(result.cause);
        if (finalOutput != null) {
          return _succeedWithFinalOutput(finalOutput, revision);
        }
        final (type, message) = _classify(result.cause, result.error?.message);
        _fail(type, message);
      case 'blocked':
        _fail('model_error', 'the model response was blocked');
      default:
        final message = result.message;
        final text = message?.text ?? '';
        final Object? candidate;
        final List<Map<String, Object?>> errors;
        final schema = request.outputSchema;
        if (schema == null) {
          candidate = {'text': text};
          errors = const [];
        } else {
          // Declared outputs come only through `final_output`.
          candidate = null;
          errors = [
            {
              'field': '',
              'error': 'the model answered without calling final_output',
            },
          ];
        }
        _finish('succeeded', {
          'candidate': candidate,
          'candidate_errors': errors,
          'snapshot': _snapshot(revision + 1, result.messages),
          'usage': usage.toJson(),
        });
    }
  }

  static FinalOutputReached? _findFinalOutput(Object? cause) {
    Object? c = cause;
    for (var depth = 0; c != null && depth < 8; depth++) {
      if (c is FinalOutputReached) return c;
      c = c is GenkitException ? c.cause : null;
    }
    return null;
  }

  /// Ends the run with the first `final_output` call of the turn. Every call
  /// of that turn is answered in the history with pydantic-ai's texts, so an
  /// output retry continues from a complete conversation.
  Future<void> _succeedWithFinalOutput(
    FinalOutputReached reached,
    int revision,
  ) async {
    final calls = [
      for (final p in reached.response.content) ?p.toolRequestPart,
    ];
    final first = calls.firstWhere(
      (c) => c.toolRequest.name == finalOutputToolName,
    );
    final messages = [
      ...reached.history,
      reached.response,
      Message(
        role: Role.tool,
        content: [
          for (final c in calls)
            ToolResponsePart(
              toolResponse: ToolResponse(
                ref: c.toolRequest.ref,
                name: c.toolRequest.name,
                output: identical(c, first)
                    ? finalResultProcessed
                    : c.toolRequest.name == finalOutputToolName
                    ? outputToolNotUsed
                    : toolNotExecuted,
              ),
            ),
        ],
      ),
    ];
    final input = first.toolRequest.input;
    _emit('tool_call', {
      'id': first.toolRequest.ref,
      'name': finalOutputToolName,
      'phase': 'started',
      'input': input,
    });
    _emit('tool_call', {
      'id': first.toolRequest.ref,
      'name': finalOutputToolName,
      'phase': 'finished',
      'output': finalResultProcessed,
    });
    Object? candidate;
    List<Map<String, Object?>> errors;
    if (input is Map) {
      candidate = input;
      errors = await candidateErrors(request.outputSchema!, input);
      try {
        (candidate, errors) = await _resolveFileOutputs(
          input.cast<String, Object?>(),
          errors,
        );
      } on SandboxFailure catch (e) {
        // The workspace is kept: nothing is released on a failed upload.
        return _fail(e.errorType, e.message);
      }
    } else {
      candidate = null;
      errors = [
        {'field': '', 'error': 'final_output arguments are not a JSON object'},
      ];
    }
    _finish('succeeded', {
      'candidate': candidate,
      'candidate_errors': errors,
      'snapshot': _snapshot(revision + 1, messages),
      'usage': usage.toJson(),
    });
  }

  (String, String) _classify(Object? cause, String? fallback) {
    Object? c = cause;
    for (var depth = 0; c != null && depth < 8; depth++) {
      if (c is GatewayException) return (c.errorType, c.message);
      if (c is AskHumanInvalid) return ('ask_human_invalid', c.message);
      if (c is SandboxFailure) return (c.errorType, c.message);
      if (c is GenkitException) {
        if (c.cause == null) {
          if (c.status == StatusCode.notFound &&
              c.message.startsWith('Tool ')) {
            return (
              'model_error',
              'the model called an unknown tool: ${c.message}',
            );
          }
          return ('internal', c.message);
        }
        c = c.cause;
        continue;
      }
      break;
    }
    return (
      'model_error',
      fallback ?? cause?.toString() ?? 'model call failed',
    );
  }

  Map<String, Object?> _snapshot(
    int revision,
    List<Message> messages, {
    Map<String, Object?>? pending,
  }) {
    final r = request;
    return {
      'envelope': envelopeName,
      'revision': revision,
      'genkit': genkitVersion,
      'agent_config_snapshot_id': r.execution.agentConfigSnapshotId,
      'tool_definitions_digest': toolDefinitionsDigest(r),
      'model': r.model.json,
      'output_attempt': r.outputAttempt,
      'resume_sequence': r.resumeSequence,
      'pending': pending,
      'file_ids': {
        for (final p in r.task)
          if (p is TaskFile) p.fileId,
        ...r.fileIds,
      }.toList(),
      'workspace_ref': _workspaceRef,
      'messages': [for (final m in messages) m.toJson()],
    };
  }

  static String _feedbackText(List<({String field, String error})> feedback) {
    final lines = [
      for (final f in feedback)
        '- ${f.field.isEmpty ? '(output)' : f.field}: ${f.error}',
    ];
    return 'Your previous output failed validation:\n${lines.join('\n')}\n'
        'Reply again with the complete JSON output conforming to the schema.';
  }

  void _defineFinalOutput(Genkit ai, Map<String, Object?> schema) {
    final tool = finalOutputTool(modelFacingSchema(schema));
    ai.defineTool<Object?, Object?>(
      name: finalOutputToolName,
      description: tool.description,
      inputSchema: SchemanticType.from<Object?>(
        jsonSchema: tool.parameters,
        parse: (j) => j,
      ),
      // Never executed: the model middleware ends the run first.
      fn: (_, _) => throw StateError('final_output is not executed'),
    );
  }

  String? get _continuationRef {
    final ref = request.continuation?.snapshot['workspace_ref'];
    return ref is String && ref.isNotEmpty ? ref : null;
  }

  String? get _workspaceRef =>
      _sandboxId ??
      sandboxes?.sandboxIdOf(request.execution.executionId) ??
      _continuationRef;

  /// Opens the execution's sandbox (probes first; a new one gets `files[]`).
  Future<ExecutionSandbox> _openSandbox() async {
    final inner = _inner;
    final manager = sandboxes;
    if (inner == null || manager == null) {
      throw SandboxFailure('sandbox_unavailable', 'no sandbox for this run');
    }
    final sandbox = await manager.open(
      request,
      inner,
      expectedRef: _continuationRef,
    );
    _sandboxId = sandbox.sandboxId;
    return sandbox;
  }

  Future<ShellSession> _shellSession() => _sessionFuture ??= () async {
    final sandbox = await _openSandbox();
    if (_stopReason != null) {
      throw SandboxFailure('sandbox_error', 'the run was stopped');
    }
    final session = ShellSession(
      sandbox,
      request.env,
      log: (m) => log?.call('run $runId: $m'),
    );
    return _session = session;
  }();

  /// Ends the shell session: terminates the run's jobs and kills what they
  /// left; a sandbox whose processes cannot be stopped is removed.
  Future<void> _endShell() async {
    final pending = _sessionFuture;
    if (pending == null) return;
    final ShellSession session;
    try {
      session = await pending;
    } catch (_) {
      return;
    }
    if (_session == null) return;
    _session = null;
    final stopped = await session.close().timeout(
      const Duration(seconds: 30),
      onTimeout: () => false,
    );
    if (!stopped) {
      log?.call(
        'run $runId: processes of sandbox ${session.sandbox.sandboxId} could '
        'not be stopped; removing the sandbox',
      );
      await sandboxes?.discard(
        request.execution.executionId,
        session.sandbox.sandboxId,
      );
    }
  }

  void _defineShellTools(Genkit ai) {
    for (final entry in shellToolDefinitions.entries) {
      final name = entry.key;
      ai.defineTool<Object?, Object?>(
        name: name,
        description: entry.value.description,
        inputSchema: SchemanticType.from<Object?>(
          jsonSchema: entry.value.parameters,
          parse: (j) => j,
        ),
        fn: (input, _) async {
          // A sandbox that cannot be opened ends the run (SandboxFailure).
          final session = await _shellSession();
          final args = input is Map
              ? input.cast<String, Object?>()
              : <String, Object?>{};
          final output = await session.call(name, args);
          return ToolResult.response(
            output,
            metadata: output is Map ? {'dify_sf_error': output['error']} : null,
          );
        },
      );
    }
  }

  /// Uploads the declared file outputs of [candidate]. A path that is not a
  /// usable workspace file is a candidate error for its field; a failed
  /// upload throws [SandboxFailure] (`file_error`).
  Future<(Map<String, Object?>, List<Map<String, Object?>>)>
  _resolveFileOutputs(
    Map<String, Object?> candidate,
    List<Map<String, Object?>> errors,
  ) async {
    final specs = fileOutputFields(request.outputSchema!);
    final present = {
      for (final e in specs.entries)
        if (candidate[e.key] != null) e.key: e.value,
    };
    if (present.isEmpty) return (candidate, errors);
    final out = Map<String, Object?>.of(candidate);
    final allErrors = List<Map<String, Object?>>.of(errors);
    final failed = {for (final e in errors) e['field']};
    final hasWorkspace = request.shell && _workspaceRef != null;
    ExecutionSandbox? sandbox;
    for (final MapEntry(key: field, value: spec) in present.entries) {
      if (failed.contains(field)) continue;
      if (!hasWorkspace) {
        allErrors.add({
          'field': field,
          'error': request.shell
              ? 'there is no workspace file: the shell was not used'
              : 'file outputs come from the shell workspace; tools.shell is false',
        });
        continue;
      }
      final raw = candidate[field];
      final paths = spec.isArray ? raw : [raw];
      if (paths is! List || paths.any((p) => p is! String)) {
        allErrors.add({
          'field': field,
          'error':
              'expected ${spec.isArray ? 'a list of workspace paths' : 'a workspace path'}',
        });
        continue;
      }
      sandbox ??= await _openSandbox();
      final resolved = <({String real, String name, String mime, int size})>[];
      String? error;
      for (final p in paths.cast<String>()) {
        final st = await sandbox.statFile(p);
        if (st.error != null) {
          error = st.error;
          break;
        }
        final name = st.realPath!.substring(st.realPath!.lastIndexOf('/') + 1);
        final mime = outputMimeType(name, st.mimeType);
        error = st.size > maxOutputFileBytes
            ? '$name exceeds $maxOutputFileBytes bytes'
            : spec.violation(name, mime);
        if (error != null) break;
        resolved.add((
          real: st.realPath!,
          name: name,
          mime: mime,
          size: st.size,
        ));
      }
      if (error != null) {
        allErrors.add({'field': field, 'error': error});
        continue;
      }
      final uploaded = <Map<String, Object?>>[];
      for (final f in resolved) {
        final bytes = await sandbox.readFile(f.real, f.size);
        try {
          final up = await _inner!.uploadRequest(
            filename: f.name,
            mimeType: f.mime,
            size: bytes.length,
          );
          final url = up['url'];
          final uploadId = up['upload_id'];
          if (url is! String || uploadId is! String) {
            throw GatewayException('file_error', 'upload-request gave no url');
          }
          await _inner!.uploadBytes(url, bytes, f.mime);
          uploaded.add({
            'upload_id': uploadId,
            'filename': f.name,
            'mime_type': f.mime,
            'size': bytes.length,
          });
        } on GatewayException catch (e) {
          throw SandboxFailure(
            'file_error',
            'uploading ${f.name} for output $field failed: ${e.message}',
          );
        }
      }
      out[field] = spec.isArray ? uploaded : uploaded.single;
    }
    return (out, allErrors);
  }

  void _defineAskHuman(Genkit ai) {
    ai.defineTool<Object?, Object?>(
      name: askHumanToolName,
      description: askHumanDescription,
      inputSchema: SchemanticType.from<Object?>(
        jsonSchema: askHumanInputSchema,
        parse: (j) => j,
      ),
      fn: (input, _) {
        try {
          final question = normalizeAskHumanArgs(input);
          return ToolResult.interrupt({'question': question});
        } on FormatException catch (e) {
          // Like Dify's ModelRetry: the model reads the error and tries again.
          final message = e.message;
          return ToolResult.response(
            'Invalid ask_human arguments: $message. Fix the errors and try again.',
            metadata: {'dify_sf_error': message},
          );
        }
      },
    );
  }
}

/// Emits `tool_call` events and enforces one `ask_human` per model turn.
class _EventsMiddleware extends GenerateMiddleware {
  _EventsMiddleware(this.run);

  final AgentRun run;

  @override
  Future<ModelResponse> model(
    ModelRequest request,
    ActionFnArg<ModelResponseChunk, ModelRequest, void> ctx,
    Future<ModelResponse> Function(
      ModelRequest,
      ActionFnArg<ModelResponseChunk, ModelRequest, void>,
    )
    next,
  ) async {
    final response = await next(request, ctx);
    final message = response.message;
    if (message != null &&
        message.content.any(
          (p) => p.toolRequest?.name == finalOutputToolName,
        )) {
      throw FinalOutputReached(request.messages, message);
    }
    final asks =
        response.message?.content
            .where((p) => p.toolRequest?.name == askHumanToolName)
            .length ??
        0;
    if (asks > 1) {
      throw AskHumanInvalid(
        'ask_human supports exactly one call per model turn; got $asks',
      );
    }
    return response;
  }

  @override
  Future<ToolResult> tool(
    ToolRequestPart request,
    ActionFnArg<void, dynamic, void> ctx,
    Future<ToolResult> Function(
      ToolRequestPart,
      ActionFnArg<void, dynamic, void>,
    )
    next,
  ) async {
    final t = request.toolRequest;
    run._emit('tool_call', {
      'id': t.ref,
      'name': t.name,
      'phase': 'started',
      'input': t.input,
    });
    try {
      final result = await next(request, ctx);
      switch (result) {
        case ToolResponseResult(:final output, :final metadata):
          final error = metadata?['dify_sf_error'];
          run._emit('tool_call', {
            'id': t.ref,
            'name': t.name,
            'phase': 'finished',
            if (error != null) 'error': error else 'output': output,
          });
        case ToolInterruptResult():
          // Finished by the answer in the next operation.
          break;
      }
      return result;
    } catch (e) {
      run._emit('tool_call', {
        'id': t.ref,
        'name': t.name,
        'phase': 'finished',
        'error': e.toString(),
      });
      rethrow;
    }
  }
}
