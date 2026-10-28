/// One run of the agent loop: a per-run Genkit instance with the gateway
/// model, the `ask_human` tool and the event middleware.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpException, SocketException;
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:genkit/genkit.dart';
import 'package:http/http.dart' as http;
import 'package:schemantic/schemantic.dart';

import 'ask_human.dart';
import 'executor_profiles.dart' show Egress;
import 'file_outputs.dart';
import 'gateway.dart';
import 'harness/codex/apply_patch.dart';
import 'harness/codex/exec_output.dart';
import 'harness/codex/official.dart';
import 'harness/codex/prompts.dart';
import 'harness/codex/retry.dart';
import 'harness/codex/sandbox_patch_fs.dart';
import 'harness/codex/tools.dart';
import 'harness/codex/transport.dart';
import 'harness/codex/unified_exec.dart';
import 'model.dart';
import 'output_tool.dart';
import 'protocol.dart';
import 'report_progress.dart';
import 'run_store.dart';
import 'sandbox/sandbox.dart';
import 'sandbox/shellctl.dart' show JobResult, ShellctlException;
import 'sandbox/shell_tools.dart';
import 'view_image.dart';

part 'harness/codex/codex_run.dart';
part 'harness/codex/official_run.dart';

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

/// The last model call the run may make answered without finishing (no
/// `final_output`, no final answer, no question): its tools are not run,
/// because no model call is left to read their results.
class BudgetExhausted implements Exception {
  BudgetExhausted(this.message);
  final String message;
  @override
  String toString() => 'BudgetExhausted: $message';
}

/// Model calls the run needs to finish once told to: one for the call that
/// gives the result (`final_output`, or the final answer without declared
/// outputs), plus one to write declared file outputs into the workspace
/// first when the schema declares any (they must exist when `final_output`
/// names them). Derived from what finishing needs; not a tuned margin.
int callsToFinish(OperationRequest r) {
  final schema = r.outputSchema;
  return schema != null && r.shell && declaresFileOutputs(schema) ? 2 : 1;
}

/// Why the run told the model to finish now (see `budget_notice`).
enum BudgetReason { maxTurns, timeout }

extension on BudgetReason {
  String get wire => switch (this) {
    BudgetReason.maxTurns => 'max_turns',
    BudgetReason.timeout => 'timeout',
  };
}

/// The user message appended (and kept) when the budget runs low.
String budgetNoticeText(
  OperationRequest r, {
  required int remainingCalls,
  int? remainingSeconds,
}) {
  final schema = r.outputSchema;
  final files = schema != null && r.shell && declaresFileOutputs(schema);
  final left = [
    '$remainingCalls model call${remainingCalls == 1 ? '' : 's'} '
        '(this one included)',
    if (remainingSeconds != null) 'about $remainingSeconds seconds',
  ].join(' and ');
  final String finish;
  if (schema == null) {
    finish =
        'Give your final answer as text now, without calling tools, with the '
        'best result you have, and say what is unfinished.';
  } else {
    final call = files
        ? 'If a file you will name in final_output does not exist yet, use at '
              'most one step to write it into the workspace; then call'
        : 'Call';
    finish =
        '$call final_output now with the best result you have: fill every '
        'required field and say in `text` what is unfinished.';
  }
  return 'Budget notice from the agent service: this run has $left left. '
      'Stop exploring. $finish A last step that calls other tools instead '
      'is not run, and the run fails without a result.';
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
  if (r.viewImage)
    {
      'name': viewImageToolName,
      'description': viewImageDescription,
      'parameters': viewImageInputSchema,
    },
  if (r.reportProgress)
    {
      'name': reportProgressToolName,
      'description': reportProgressDescription,
      'parameters': reportProgressInputSchema,
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
  // Snapshots of the dify style carry no `harness_style`.
  final style = s['harness_style'] ?? HarnessStyle.dify.wire;
  if (style != r.harnessStyle.wire) {
    throw _incompatible(
      'snapshot was taken with harness_style ${jsonEncode(style)}, not '
      '"${r.harnessStyle.wire}"',
    );
  }
  if (r.harnessStyle == HarnessStyle.codex) {
    if (r.officialCodex) {
      verifyOfficialCodexContinuation(r);
    } else {
      verifyCodexContinuation(r);
    }
    return const [];
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
  // The sandbox keeps its profile for its lifetime (snapshots taken before
  // profiles existed name none: `default`).
  final ref = s['workspace_ref'];
  final snapshotProfile = s['executor_profile'] ?? 'default';
  if (r.shell &&
      ref is String &&
      ref.isNotEmpty &&
      snapshotProfile != r.executorProfile) {
    throw _incompatible(
      'the sandbox of this snapshot has executor profile '
      '${jsonEncode(snapshotProfile)}, not ${jsonEncode(r.executorProfile)}',
    );
  }
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
    this.codexGatewayUrl,
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

  /// The Codex Responses entry as sandboxes reach it, when the grant has
  /// none (`AGENT_CODEX_GATEWAY_URL`).
  final String? codexGatewayUrl;
  final void Function(String message)? log;

  final StreamController<RunEvent> _events = StreamController.broadcast(
    sync: true,
  );
  final Completer<RunEvent> _done = Completer();
  final CancellationController _cancel = CancellationController();
  StopReason? _stopReason;
  InnerClient? _inner;
  GatewayModelContext? _model;
  final Usage usage = Usage();

  /// Bytes of the viewed images kept in the conversation (the snapshot's
  /// and this run's), and the path of each by SHA-256 of its bytes.
  int _viewedBytes = 0;
  final Map<String, String> _viewedDigests = {};

  /// `report_progress` previews of this run.
  int _progressCount = 0;

  /// When the run started and the longest step so far (from one model
  /// call's start to the next one's: the call and its tools).
  final Stopwatch _clock = Stopwatch();
  Duration _longestStep = Duration.zero;
  Duration? _lastCallStart;

  /// The budget notice, once given: why and with which call.
  ({BudgetReason reason, int callIndex})? _notice;

  /// The shell of this run, opened on the first shell tool call.
  Future<ShellSession>? _sessionFuture;
  ShellSession? _session;

  /// The sandbox this run used (its `workspace_ref`).
  String? _sandboxId;

  /// Aborts what the `codex` loop has in flight besides the model call.
  void Function()? _onStop;

  /// `run_started` held back until the official Codex runtime knows the
  /// run's skills and Codex's thread settings ([_runStarted]); written
  /// before any other event.
  Map<String, Object?>? _heldRunStarted;

  /// The clock of prompt dates (`codex` style's environment context).
  DateTime _now() => DateTime.now();

  String get runId => record.runId;

  /// `codex.skills_dirs` of the run's executor profile.
  List<String> get _codexSkillsDirs =>
      sandboxes?.profiles[request.executorProfile]?.codexSkillsDirs ?? const [];

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
    _onStop?.call();
  }

  void _emit(String event, Map<String, Object?> data) {
    if (record.isEnded) return;
    if (event != 'run_started') _runStarted();
    _events.add(store.append(record, event, data));
  }

  /// Writes a held `run_started`, with [runtime] added to its `runtime`.
  void _runStarted([Map<String, Object?> runtime = const {}]) {
    final started = _heldRunStarted;
    if (started == null) return;
    _heldRunStarted = null;
    _emit('run_started', {
      ...started,
      'runtime': {...?started['runtime'] as Map?, ...runtime},
    });
  }

  void _finish(String event, Map<String, Object?> data) {
    if (record.isEnded) return;
    _runStarted();
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
    final started = <String, Object?>{
      'model': {'provider': r.model.provider, 'name': r.model.name},
      'call_index_base': 0,
      'executor_profile': r.executorProfile,
      'harness_style': r.harnessStyle.wire,
      if (r.officialCodex) ...{
        'model_wire': {
          'wire': 'responses',
          'reason': 'the official Codex CLI in the sandbox calls the '
              'gateway\'s Codex Responses entry',
          'reduced_fidelity': false,
        },
        'runtime': {
          'name': 'codex-cli',
          'version': officialCodexVersion,
          'sha256': officialCodexSha256,
        },
      } else if (r.harnessStyle == HarnessStyle.codex)
        'model_wire': switch (selectWire(r)) {
          final w => {
            'wire': w.wire,
            'reason': w.reason,
            'reduced_fidelity': w.reducedFidelity,
          },
        },
    };
    // The official runtime adds what Codex reports once it runs (the
    // profile's skills, the thread's model and reasoning effort).
    if (r.officialCodex) {
      _heldRunStarted = started;
    } else {
      _emit('run_started', started);
    }
    if (r.shell && !(sandboxes?.enabled ?? false)) {
      return _fail(
        'sandbox_unavailable',
        'the shell tool is not available: this agent service has no sandbox',
      );
    }
    if (r.officialCodex && !(sandboxes?.enabled ?? false)) {
      return _fail(
        'sandbox_unavailable',
        'harness_style codex runs Codex in a sandbox: this agent service has '
            'no sandbox',
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
    _clock.start();
    if (r.officialCodex) {
      try {
        await _OfficialCodexRun(this).execute();
      } finally {
        await _endShell();
        timer.cancel();
        inner.close();
      }
      return;
    }
    if (r.harnessStyle == HarnessStyle.codex) {
      try {
        await _CodexLoop(this, inner).execute();
      } finally {
        await _endShell();
        timer.cancel();
        inner.close();
      }
      return;
    }
    final ai = Genkit(isDevEnv: false, promptDir: null);
    try {
      final model = defineGatewayModel(
        ai,
        _model = GatewayModelContext(
          inner: inner,
          request: r,
          runId: runId,
          onReasoning: (t) => _emit('thought', {'text': t}),
          onModelCall: (id, u, prefix) {
            usage.add(u);
            _emit('model_call', {
              'invocation_id': id,
              'usage': u.toJson(),
              'prompt': prefix.toJson(),
            });
          },
        )..onCallStart = _onCallStart,
      );
      if (r.askHuman) _defineAskHuman(ai);
      if (r.shell) _defineShellTools(ai);
      if (r.viewImage) _defineViewImage(ai);
      if (r.reportProgress) _defineReportProgress(ai);
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
        _countViewedImages(messages);
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
          if (r.viewImage) viewImageToolName,
          if (r.reportProgress) reportProgressToolName,
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
          'partial': _partial,
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
      'partial': _partial,
    });
  }

  /// `partial` of `succeeded`: the result was given after the budget notice.
  Map<String, Object?>? get _partial => switch (_notice) {
    null => null,
    final n => {'reason': n.reason.wire, 'notice_call_index': n.callIndex},
  };

  void _onCallStart(int callIndex) {
    final now = _clock.elapsed;
    final last = _lastCallStart;
    if (last != null && now - last > _longestStep) _longestStep = now - last;
    _lastCallStart = now;
  }

  /// Before model call [callIndex]: when the calls or the time left are no
  /// more than what finishing needs ([callsToFinish] calls; for time, that
  /// many of the longest step so far), appends the budget notice to
  /// [req]'s messages, once per run. Genkit 1.0.1 builds the next turn's
  /// history from this same request object, so the notice stays in the
  /// history at the place it was added (append-only; tested).
  void _maybeNotice(ModelRequest req, int callIndex) {
    if (_notice != null) return;
    final r = request;
    final need = callsToFinish(r);
    final remainingCalls = r.maxTurns - callIndex + 1;
    final remaining = Duration(seconds: r.timeoutSeconds) - _clock.elapsed;
    final BudgetReason reason;
    if (remainingCalls <= need) {
      reason = BudgetReason.maxTurns;
    } else if (_longestStep > Duration.zero &&
        remaining <= _longestStep * need) {
      reason = BudgetReason.timeout;
    } else {
      return;
    }
    final seconds = remaining.isNegative ? 0 : remaining.inSeconds;
    _notice = (reason: reason, callIndex: callIndex);
    req.messages = [
      ...req.messages,
      Message(
        role: Role.user,
        content: [
          TextPart(
            text: budgetNoticeText(
              r,
              remainingCalls: remainingCalls,
              remainingSeconds: reason == BudgetReason.timeout ? seconds : null,
            ),
          ),
        ],
      ),
    ];
    _emit('budget_notice', {
      'reason': reason.wire,
      'call_index': callIndex,
      'remaining_calls': remainingCalls,
      if (reason == BudgetReason.timeout) 'remaining_seconds': seconds,
    });
  }

  /// After model call [callIndex]: the last call the run may make must
  /// finish (`final_output`, a final answer or a question); otherwise its
  /// tools are not run and the run fails `max_turns` now.
  void _checkLastCall(int callIndex, Message? message) {
    if (callIndex < request.maxTurns || message == null) return;
    final calls = [for (final p in message.content) ?p.toolRequestPart];
    if (calls.isEmpty) return;
    if (calls.any(
      (c) =>
          c.toolRequest.name == finalOutputToolName ||
          c.toolRequest.name == askHumanToolName,
    )) {
      return;
    }
    throw BudgetExhausted(
      'the run reached max_turns (${request.maxTurns}) without a final answer'
      '${_notice == null ? '' : '; the model was told to finish at call ${_notice!.callIndex}'}',
    );
  }

  /// Counts the viewed images kept in [messages] (a continuation's history).
  void _countViewedImages(List<Message> messages) {
    for (final m in messages) {
      if (m.role != Role.tool) continue;
      for (final p in m.content) {
        for (final c in p.toolResponse?.content ?? const []) {
          if (c is! Map) continue;
          final meta = (c['metadata'] as Map?)?[viewImageMetadataKey];
          if (meta is! Map || meta['size'] is! int) continue;
          _viewedBytes += meta['size'] as int;
          final digest = meta['sha256'];
          if (digest is String) {
            _viewedDigests.putIfAbsent(digest, () => '${meta['path']}');
          }
        }
      }
    }
  }

  (String, String) _classify(Object? cause, String? fallback) {
    Object? c = cause;
    for (var depth = 0; c != null && depth < 8; depth++) {
      if (c is GatewayException) return (c.errorType, c.message);
      if (c is AskHumanInvalid) return ('ask_human_invalid', c.message);
      if (c is BudgetExhausted) return ('max_turns', c.message);
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
      'executor_profile': r.executorProfile,
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
      cancel: _cancel.token,
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
      profileEnv: sandboxes?.profiles[request.executorProfile]?.env ?? const {},
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

  /// Reads an image of the workspace for `view_image` / `report_progress`:
  /// inside the workspace, a PNG, JPEG or WebP by its header, at most
  /// [maxBytes]. Returns the error text or the file.
  Future<
    ({
      String? error,
      String rel,
      List<int> bytes,
      ({String mimeType, int width, int height})? info,
    })
  >
  _workspaceImage(Object? path, int maxBytes, String budgetText) async {
    if (path is! String || path.trim().isEmpty) {
      return (
        error: 'path is required',
        rel: '',
        bytes: const <int>[],
        info: null,
      );
    }
    final sandbox = (await _shellSession()).sandbox;
    final st = await sandbox.statFile(path.trim());
    if (st.error != null) {
      return (error: st.error, rel: '', bytes: const <int>[], info: null);
    }
    final real = st.realPath!;
    final rel = real.substring(sandbox.layout.workspaceDir.length + 1);
    if (st.size > maxBytes) {
      return (
        error:
            '$rel is ${st.size} bytes; $budgetText. Make a smaller copy '
            '(scaled down, or JPEG) and use that.',
        rel: rel,
        bytes: const <int>[],
        info: null,
      );
    }
    final List<int> bytes;
    try {
      bytes = await sandbox.readFile(real, st.size);
    } on SandboxFailure catch (e) {
      return (error: e.message, rel: rel, bytes: const <int>[], info: null);
    }
    final info = imageInfo(bytes);
    if (info == null) {
      return (
        error: '$rel is not a PNG, JPEG or WebP image (${st.mimeType})',
        rel: rel,
        bytes: bytes,
        info: null,
      );
    }
    return (error: null, rel: rel, bytes: bytes, info: info);
  }

  /// Uploads [bytes] as a file of the execution; returns its `upload_id`.
  Future<String> _upload(
    String filename,
    String mimeType,
    List<int> bytes,
  ) async {
    final up = await _inner!.uploadRequest(
      filename: filename,
      mimeType: mimeType,
      size: bytes.length,
    );
    final url = up['url'];
    final id = up['upload_id'];
    if (url is! String || id is! String) {
      throw GatewayException('file_error', 'upload-request gave no url');
    }
    await _inner!.uploadBytes(url, bytes, mimeType);
    return id;
  }

  /// `view_image`: checks the workspace file (see [_workspaceImage]; the
  /// conversation's viewed images together at most
  /// [viewImageConversationBytes]), uploads it as a file of the execution
  /// and returns the tool text with the image as a multipart `MediaPart`.
  /// The image stays in the conversation: the model bridge sends it after
  /// the tool message in every later call (see `toPromptMessages`). The
  /// same bytes viewed again are not attached twice. Problems are tool
  /// errors the model can act on; a sandbox that cannot be opened ends the
  /// run as for the shell tools.
  void _defineViewImage(Genkit ai) {
    ToolResult<Object?> error(String message) => ToolResult.response(
      shellToolError(message),
      metadata: {'dify_sf_error': message},
    );
    ai.defineTool<Object?, Object?>(
      name: viewImageToolName,
      description: viewImageDescription,
      inputSchema: SchemanticType.from<Object?>(
        jsonSchema: viewImageInputSchema,
        parse: (j) => j,
      ),
      fn: (input, _) async {
        final args = input is Map
            ? input.cast<String, Object?>()
            : const <String, Object?>{};
        final detail = args['detail'] == 'low' ? 'low' : 'high';
        final left = viewImageConversationBytes - _viewedBytes;
        final img = await _workspaceImage(
          args['path'],
          left < 0 ? 0 : left,
          'the viewed images of this conversation may have at most '
          '$viewImageConversationBytes bytes together and $_viewedBytes '
          'are used',
        );
        if (img.error != null) return error(img.error!);
        final info = img.info!;
        final rel = img.rel;
        final digest = sha256.convert(img.bytes).toString();
        final earlier = _viewedDigests[digest];
        if (earlier != null) {
          return ToolResult.response(
            'The image $rel has the same bytes as $earlier, which is already '
            'in the conversation; it is not attached again.',
          );
        }
        // Checked again and reserved synchronously: tools of one turn may run
        // concurrently, and another view may have used the budget meanwhile.
        if (_viewedBytes + img.bytes.length > viewImageConversationBytes) {
          return error(
            '$rel is ${img.bytes.length} bytes; the viewed images of this '
            'conversation may have at most $viewImageConversationBytes bytes '
            'together and $_viewedBytes are used. Make a smaller copy (scaled '
            'down, or JPEG) and use that.',
          );
        }
        _viewedBytes += img.bytes.length;
        _viewedDigests[digest] = rel;
        final String uploadId;
        try {
          uploadId = await _upload(
            rel.substring(rel.lastIndexOf('/') + 1),
            info.mimeType,
            img.bytes,
          );
        } on GatewayException catch (e) {
          _viewedBytes -= img.bytes.length;
          _viewedDigests.remove(digest);
          return error('the image could not be attached: ${e.message}');
        }
        return ToolResult.response(
          'The image $rel (${info.mimeType}, ${info.width}x${info.height}, '
          '${img.bytes.length} bytes) is attached after this result and stays '
          'in the conversation ($_viewedBytes of $viewImageConversationBytes '
          'bytes of viewed images used).',
          parts: [
            MediaPart(
              media: Media(
                url: '$fileUrlScheme$uploadId',
                contentType: info.mimeType,
              ),
              metadata: {
                viewImageMetadataKey: {
                  'path': rel,
                  'detail': detail,
                  'size': img.bytes.length,
                  'sha256': digest,
                },
              },
            ),
          ],
        );
      },
    );
  }

  /// `report_progress`: checks the workspace image (see [_workspaceImage],
  /// at most [progressImageBytes]) and the caption, uploads the image as a
  /// file of the execution and emits a `progress` event. The model gets a
  /// short text only; the image never enters its context. At most
  /// [progressMaxPerRun] per run; problems are tool errors.
  void _defineReportProgress(Genkit ai) {
    ToolResult<Object?> error(String message) => ToolResult.response(
      shellToolError(message),
      metadata: {'dify_sf_error': message},
    );
    ai.defineTool<Object?, Object?>(
      name: reportProgressToolName,
      description: reportProgressDescription,
      inputSchema: SchemanticType.from<Object?>(
        jsonSchema: reportProgressInputSchema,
        parse: (j) => j,
      ),
      fn: (input, _) async {
        final args = input is Map
            ? input.cast<String, Object?>()
            : const <String, Object?>{};
        final r = await _reportProgressCall(args, _model?.callIndex ?? 0);
        final message = r.error;
        return message == null ? ToolResult.response(r.text) : error(message);
      },
    );
  }

  /// The work of `report_progress` (both styles): the preview checked,
  /// uploaded and announced; an error text the model can act on otherwise.
  Future<({String? error, String text})> _reportProgressCall(
    Map<String, Object?> args,
    int callIndex,
  ) async {
    ({String? error, String text}) error(String message) =>
        (error: message, text: '');
    final caption = args['caption'];
    if (caption is! String || caption.trim().isEmpty) {
      return error('caption is required');
    }
    final text = caption.trim();
    if (text.runes.length > progressCaptionMaxChars) {
      return error(
        'caption has ${text.runes.length} characters; at most '
        '$progressCaptionMaxChars',
      );
    }
    if (_progressCount >= progressMaxPerRun) {
      return error(
        'this run already reported $progressMaxPerRun previews, the most '
        'it may; continue without reporting',
      );
    }
    // Reserved before the upload: tools of one turn run concurrently.
    _progressCount++;
    final img = await _workspaceImage(
      args['path'],
      progressImageBytes,
      'a preview may have at most $progressImageBytes bytes',
    );
    if (img.error != null) {
      _progressCount--;
      return error(img.error!);
    }
    final info = img.info!;
    final name = img.rel.substring(img.rel.lastIndexOf('/') + 1);
    final String uploadId;
    try {
      uploadId = await _upload(name, info.mimeType, img.bytes);
    } on GatewayException catch (e) {
      _progressCount--;
      return error('the preview could not be uploaded: ${e.message}');
    }
    _emit('progress', {
      'file': {
        'upload_id': uploadId,
        'filename': name,
        'mime_type': info.mimeType,
        'size': img.bytes.length,
      },
      'caption': text,
      'call_index': callIndex,
    });
    return (
      error: null,
      text:
          'Progress reported: ${img.rel} with your caption '
          '($_progressCount of at most $progressMaxPerRun in this run).',
    );
  }

  /// Uploads the declared file outputs of [candidate]. A path that is not a
  /// usable workspace file is a candidate error for its field; a failed
  /// upload throws [SandboxFailure] (`file_error`).
  Future<(Map<String, Object?>, List<Map<String, Object?>>)>
  _resolveFileOutputs(
    Map<String, Object?> candidate,
    List<Map<String, Object?>> errors,
  ) async {
    final sites = fileSites(request.outputSchema!, candidate);
    if (sites.isEmpty) return (candidate, errors);
    Object? out = Map<String, Object?>.of(candidate);
    final allErrors = List<Map<String, Object?>>.of(errors);
    final failed = {for (final e in errors) e['field']};
    final hasWorkspace = request.shell && _workspaceRef != null;
    ExecutionSandbox? sandbox;
    // Check every site of a field before uploading any of it, so a field is
    // either fully replaced by receipts or left as the model gave it.
    final byField = <String, List<FileSite>>{};
    for (final site in sites) {
      (byField[site.field] ??= []).add(site);
    }
    for (final MapEntry(key: field, value: fieldSites) in byField.entries) {
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
      final resolved =
          <
            ({FileSite site, String real, String name, String mime, int size})
          >[];
      String? error;
      for (final site in fieldSites) {
        final p = site.value;
        if (p is! String) {
          error = '${site.label}: expected a workspace path';
          break;
        }
        sandbox ??= await _openSandbox();
        final st = await sandbox.statFile(p);
        if (st.error != null) {
          error = '${site.label}: ${st.error}';
          break;
        }
        final name = st.realPath!.substring(st.realPath!.lastIndexOf('/') + 1);
        final mime = outputMimeType(name, st.mimeType);
        final v = st.size > maxOutputFileBytes
            ? '$name exceeds $maxOutputFileBytes bytes'
            : site.spec.violation(name, mime);
        if (v != null) {
          error = '${site.label}: $v';
          break;
        }
        resolved.add((
          site: site,
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
      for (final f in resolved) {
        final bytes = await sandbox!.readFile(f.real, f.size);
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
          out = replaceAt(out, f.site.path, {
            'upload_id': uploadId,
            'filename': f.name,
            'mime_type': f.mime,
            'size': bytes.length,
          });
        } on GatewayException catch (e) {
          throw SandboxFailure(
            'file_error',
            'uploading ${f.name} for output ${f.site.label} failed: ${e.message}',
          );
        }
      }
    }
    return ((out as Map).cast<String, Object?>(), allErrors);
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
    final callIndex = (run._model?.callIndex ?? 0) + 1;
    run._maybeNotice(request, callIndex);
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
    run._checkLastCall(callIndex, message);
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
