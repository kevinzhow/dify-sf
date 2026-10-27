// Portions derived from OpenAI Codex (https://github.com/openai/codex,
// rust-v0.163.0, codex-rs/core/src/session/turn.rs (`run_turn`: the turn
// ends at a response without tool calls), codex-rs/core/src/tools/parallel.rs
// (parallel-safe tools overlap, the others run alone) and
// codex-rs/core/src/responses_retry.rs), Copyright 2025 OpenAI, licensed
// under the Apache License 2.0. Modified for dify-sf: one operation is one
// Codex turn over the dify-sf run machinery (events, snapshots, questions,
// declared outputs, the near-budget notice and `max_turns`).

part of '../../loop.dart';

/// The upstream this port follows.
const codexUpstream = 'rust-v0.163.0';

/// The tools of a `codex` run (on the plugin wire today).
List<CodexToolSpec> codexToolsFor(
  OperationRequest r, {
  bool freeform = false,
}) => codexTools(
  shell: r.shell,
  viewImage: r.viewImage,
  updatePlan: r.updatePlan,
  askHuman: r.askHuman,
  reportProgress: r.reportProgress,
  freeform: freeform,
  originalImageDetail: codexModelProfile(r.model.name)
      .supportsImageDetailOriginal,
);

/// The `tool_definitions_digest` of a `codex` snapshot (the tools depend
/// on the model wire: `apply_patch` is freeform on the Responses wire).
String codexToolDefinitionsDigest(OperationRequest r) => sha256Hex(
  canonicalJson({
    'harness_style': HarnessStyle.codex.wire,
    'tools': [
      for (final t in codexToolsFor(
        r,
        freeform: selectWire(r).wire == 'responses',
      ))
        t.toResponsesJson(),
    ],
  }),
);

/// Checks a `codex` continuation's snapshot against [r] (the checks of
/// [verifyContinuation], on `items`); returns its items.
List<Item> verifyCodexContinuation(OperationRequest r) {
  final c = r.continuation;
  if (c == null) return const [];
  final s = c.snapshot;
  if (s['agent_config_snapshot_id'] != r.execution.agentConfigSnapshotId) {
    throw _incompatible(
      'snapshot belongs to a different agent_config_snapshot_id',
    );
  }
  final snapshotWire = (s['codex'] as Map?)?['wire'];
  final wire = selectWire(r).wire;
  if (snapshotWire != wire) {
    throw _incompatible(
      'snapshot was taken on the ${jsonEncode(snapshotWire)} model wire, '
      'this operation uses "$wire"',
    );
  }
  if (s['tool_definitions_digest'] != codexToolDefinitionsDigest(r)) {
    throw _incompatible('snapshot was taken with different tool definitions');
  }
  if (s['revision'] is! int) throw _incompatible('snapshot has no revision');
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
  final raw = s['items'];
  if (raw is! List || raw.any((i) => i is! Map || i['type'] is! String)) {
    throw _incompatible('snapshot items are not Responses items');
  }
  final items = [for (final i in raw) (i as Map).cast<String, Object?>()];
  final pending = s['pending'];
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
      final callId = pending['tool_call_id'];
      final open =
          callId is String &&
          items.any(
            (i) =>
                isToolCall(i) &&
                i['call_id'] == callId &&
                i['name'] == askHumanToolName,
          ) &&
          !items.any((i) => isToolOutput(i) && i['call_id'] == callId);
      if (!open) {
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
  return items;
}

/// The near-budget notice of the `codex` style: as the dify style's, with
/// the final answer (not `final_output`) as the way to finish.
String codexBudgetNoticeText(
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
    final give = files
        ? 'If a file you will name in the final answer does not exist yet, '
              'use at most one step to write it into the workspace; then give'
        : 'Give';
    finish =
        '$give your final answer now, without calling tools: the JSON object '
        'of the final answer format with the best result you have; fill '
        'every required field and say in `text` what is unfinished.';
  }
  return 'Budget notice from the agent service: this run has $left left. '
      'Stop exploring. $finish A last step that calls other tools instead '
      'is not run, and the run fails without a result.';
}

/// The JSON object of a final answer (a code fence around it is accepted).
Object? parseFinalAnswerJson(String text) {
  var t = text.trim();
  final fence = RegExp(r'^```[A-Za-z]*\n([\s\S]*?)\n?```$').firstMatch(t);
  if (fence != null) t = fence.group(1)!.trim();
  try {
    return jsonDecode(t);
  } on FormatException {
    return null;
  }
}

/// Ends the loop with a run result (after the shell is closed).
class _Finish implements Exception {
  _Finish(this.run);
  final Future<void> Function() run;
}

class _CodexLoop {
  _CodexLoop(this.run, this.inner)
    : transport = selectWire(run.request).wire == 'responses'
          ? ResponsesTransport(
              inner: inner,
              request: run.request,
              runId: run.runId,
            )
          : PluginTransport(
              inner: inner,
              request: run.request,
              runId: run.runId,
            );

  final AgentRun run;
  final InnerClient inner;
  final ModelTransport transport;
  final Random _random = Random();
  final List<Item> items = [];
  int _callIndex = 0;
  int _revision = 0;
  UnifiedExec? _exec;
  Future<UnifiedExec>? _execFuture;

  OperationRequest get r => run.request;
  late final CodexModelProfile profile = codexModelProfile(r.model.name);
  late final List<CodexToolSpec> tools = codexToolsFor(
    r,
    freeform: transport.freeformTools,
  );

  // ---- setup -----------------------------------------------------------------

  /// Codex's initial context (`model_visible_layout`): base instructions;
  /// the permissions (and dify-sf's sections); the AGENTS.md block with the
  /// environment context; the task.
  List<Item> initialItems() {
    final networkEnabled =
        run.sandboxes?.profiles[r.executorProfile]?.egress != Egress.none;
    final schema = r.outputSchema;
    final env = environmentContext(now: run._now(), withShell: r.shell);
    return [
      developerMessage([baseInstructions(profile, updatePlan: r.updatePlan)]),
      developerMessage([
        if (r.shell) permissionsInstructions(networkEnabled: networkEnabled),
        if (r.askHuman) askHumanPromptHint(),
        // The Responses wire sends the schema as `text.format`, as Codex.
        if (schema != null && transport.wire == 'plugin')
          outputFormatInstructions(modelFacingSchema(schema)),
      ]),
      userMessage([
        if (r.systemPrompt.trim().isNotEmpty)
          inputText(agentsMdInstructions(r.systemPrompt)),
        inputText(env),
      ]),
      userMessage([
        for (final p in r.task)
          switch (p) {
            TaskText() => inputText(p.text),
            TaskFile() when (p.mimeType ?? '').startsWith('image/') =>
              inputImage(p.fileId, p.mimeType),
            TaskFile() => inputFile(p.fileId, p.mimeType),
          },
      ]),
    ]..removeWhere(
      (i) => i['role'] == 'developer' && (i['content'] as List).isEmpty,
    );
  }

  void _countViewedImages() {
    for (final i in items) {
      final output = i['output'];
      if (!isToolOutput(i) || output is! List) continue;
      for (final c in output) {
        final meta = c is Map ? c['dify_sf_view_image'] : null;
        if (meta is Map && meta['size'] is int) {
          run._viewedBytes += meta['size'] as int;
        }
      }
    }
  }

  /// Puts the answer to the pending question where its call's output
  /// belongs (outputs in call order; nothing after them was sent yet).
  void _insertAnswer(String callId, Map<String, Object?> result) {
    final at = items.indexWhere((i) => isToolCall(i) && i['call_id'] == callId);
    final callOrder = <String>[];
    var k = at;
    while (k > 0 &&
        !isToolOutput(items[k - 1]) &&
        items[k - 1]['role'] != 'user') {
      k--;
    }
    while (k < items.length && !isToolOutput(items[k])) {
      if (isToolCall(items[k])) callOrder.add('${items[k]['call_id']}');
      k++;
    }
    final mine = callOrder.indexOf(callId);
    var insertAt = k;
    while (insertAt < items.length && isToolOutput(items[insertAt])) {
      final pos = callOrder.indexOf('${items[insertAt]['call_id']}');
      if (pos > mine) break;
      insertAt++;
    }
    items.insert(insertAt, functionCallOutput(callId, jsonEncode(result)));
  }

  // ---- the loop ----------------------------------------------------------------

  Future<void> execute() async {
    run._onStop = () {
      final backend = _exec?.backend;
      if (backend is ShellctlExecBackend) backend.client.close();
    };
    final c = r.continuation;
    if (c == null) {
      items.addAll(initialItems());
    } else {
      items.addAll(verifyCodexContinuation(r));
      _revision = c.snapshot['revision'] as int;
      _countViewedImages();
      switch (c) {
        case AnswerContinuation():
          final callId =
              (c.snapshot['pending'] as Map)['tool_call_id'] as String;
          _insertAnswer(callId, c.result);
          run._emit('tool_call', {
            'id': callId,
            'name': askHumanToolName,
            'phase': 'finished',
            'output': c.result,
          });
        case OutputRetryContinuation():
          items.add(userText(AgentRun._feedbackText(c.feedback)));
      }
    }
    Future<void> Function() finish;
    try {
      await _loop();
      finish = () async => run._fail('internal', 'the codex loop ended');
    } on _Finish catch (f) {
      finish = f.run;
    } on SandboxFailure catch (e) {
      finish = () async => run._fail(e.errorType, e.message);
    }
    final stopped = run._stopReason;
    await run._endShell();
    if (stopped != null || run._stopReason != null) {
      return run._finishStopped(stopped ?? run._stopReason!);
    }
    await finish();
  }

  Never _end(Future<void> Function() f) => throw _Finish(f);

  Never _failWith(String type, String message) =>
      _end(() async => run._fail(type, message));

  void _checkStopped() {
    final s = run._stopReason;
    if (s != null) _end(() async => run._finishStopped(s));
  }

  Future<void> _loop() async {
    while (true) {
      _checkStopped();
      _callIndex++;
      run._onCallStart(_callIndex);
      _maybeNotice(_callIndex);
      final result = await _sample();
      _checkStopped();
      run.usage.add(result.usage);
      final reasoning = {
        ...result.reasoning,
        'reasoning_tokens': result.usage.reasoningTokens,
        'reasoning_tokens_source': result.usage.reasoningTokens == null
            ? null
            : 'provider',
        if (result.usage.reasoningTokens == null)
          'reasoning_tokens_null_reason': transport.wire == 'plugin'
              ? 'the plugin wire reports no reasoning token count (Dify '
                    'LLMUsage has no such field)'
              : 'the provider reported none',
      };
      run._emit('model_call', {
        'invocation_id': result.invocationId,
        'usage': result.usage.toJson(),
        'prompt': result.prefix?.toJson(),
        'harness_style': HarnessStyle.codex.wire,
        'wire': transport.wire,
        'reasoning': reasoning,
      });
      items.addAll(result.output);
      final hasCalls = result.output.any(isToolCall);
      for (final o in result.output) {
        if (o['type'] == 'message' &&
            o['role'] == 'assistant' &&
            (o['phase'] == 'commentary' || (o['phase'] == null && hasCalls))) {
          run._emit('commentary', {
            'text': [
              for (final c in (o['content'] as List?) ?? const [])
                if (c is Map) c['text'],
            ].join(),
            'call_index': _callIndex,
          });
        }
      }
      switch (result.finishReason?.toLowerCase()) {
        case 'length':
          _failWith(
            'model_error',
            'the model response was cut off at its output limit '
                '(finish_reason length)',
          );
        case 'content_filter':
          _failWith('model_error', 'the model response was blocked');
      }
      final calls = [
        for (final o in result.output)
          if (isToolCall(o)) o,
      ];
      if (calls.isEmpty) _finalAnswer(result.output);
      final asks = [
        for (final c in calls)
          if (r.askHuman && c['name'] == askHumanToolName) c,
      ];
      if (asks.length > 1) {
        _failWith(
          'ask_human_invalid',
          'ask_human supports exactly one call per model turn; got ${asks.length}',
        );
      }
      if (_callIndex >= r.maxTurns && asks.isEmpty) {
        final n = run._notice;
        _failWith(
          'max_turns',
          'the run reached max_turns (${r.maxTurns}) without a final answer'
              '${n == null ? '' : '; the model was told to finish at call ${n.callIndex}'}',
        );
      }
      // A valid question pauses the run after the other calls ran; an
      // invalid one is answered like any tool error (see [_tool]).
      Map<String, Object?>? question;
      Item? ask;
      if (asks.length == 1) {
        try {
          question = normalizeAskHumanArgs(_arguments(asks.single));
          ask = asks.single;
        } on FormatException {
          question = null;
        }
      }
      final outputs = await _runCalls(calls, skip: ask);
      _checkStopped();
      items.addAll(outputs);
      if (ask != null && question != null) {
        final callId = '${ask['call_id']}';
        run._emit('tool_call', {
          'id': callId,
          'name': askHumanToolName,
          'phase': 'started',
          'input': _arguments(ask),
        });
        final questionId =
            '${r.execution.executionId}:q${r.resumeSequence + 1}';
        final q = question;
        _end(() async {
          run._finish('paused', {
            'question_id': questionId,
            'tool_call_id': callId,
            'question': q,
            'snapshot': _snapshot(
              _revision + 1,
              pending: {'question_id': questionId, 'tool_call_id': callId},
            ),
            'usage': run.usage.toJson(),
          });
        });
      }
    }
  }

  /// The near-budget notice (as the dify style's `_maybeNotice`).
  void _maybeNotice(int callIndex) {
    if (run._notice != null) return;
    final need = callsToFinish(r);
    final remainingCalls = r.maxTurns - callIndex + 1;
    final remaining = Duration(seconds: r.timeoutSeconds) - run._clock.elapsed;
    final BudgetReason reason;
    if (remainingCalls <= need) {
      reason = BudgetReason.maxTurns;
    } else if (run._longestStep > Duration.zero &&
        remaining <= run._longestStep * need) {
      reason = BudgetReason.timeout;
    } else {
      return;
    }
    final seconds = remaining.isNegative ? 0 : remaining.inSeconds;
    run._notice = (reason: reason, callIndex: callIndex);
    items.add(
      userText(
        codexBudgetNoticeText(
          r,
          remainingCalls: remainingCalls,
          remainingSeconds: reason == BudgetReason.timeout ? seconds : null,
        ),
      ),
    );
    run._emit('budget_notice', {
      'reason': reason.wire,
      'call_index': callIndex,
      'remaining_calls': remainingCalls,
      if (reason == BudgetReason.timeout) 'remaining_seconds': seconds,
    });
  }

  // ---- model calls and retries ---------------------------------------------

  Future<void> _sleep(Duration d) => Future.any([
    Future<void>.delayed(d),
    run._cancel.token.whenCancelled.then((_) {}),
  ]);

  ModelCallFailure _failure(Object e) {
    if (e is ModelCallFailure) return e;
    if (e is GatewayHttpException) {
      return ModelCallFailure(
        classifyHttpStatus(e.status, errorCode: e.errorCode),
        e.message,
        errorType: e.errorType,
        retryAfter: parseRetryAfter(e.retryAfter),
        status: e.status,
        beforeStream: true,
      );
    }
    if (e is GatewayEnvelopeException) {
      return ModelCallFailure(
        classifyEnvelope(e.code, e.difyErrorType),
        e.message,
        errorType: e.errorType,
      );
    }
    if (e is GatewayException) {
      return ModelCallFailure(
        e.errorType == 'file_error'
            ? ModelFailureKind.invalidRequest
            : ModelFailureKind.stream,
        e.message,
        errorType: e.errorType,
      );
    }
    if (e is StreamIncomplete) {
      return ModelCallFailure(ModelFailureKind.stream, e.message);
    }
    if (e is http.ClientException ||
        e is SocketException ||
        e is HttpException ||
        e is TimeoutException) {
      return ModelCallFailure(
        ModelFailureKind.connection,
        'model gateway connection failed: $e',
        beforeStream: true,
      );
    }
    throw e;
  }

  Future<SampleResult> _attempt(int attempt) async {
    final req = SampleRequest(
      callIndex: _callIndex,
      attempt: attempt,
      items: List.unmodifiable(items),
      tools: tools,
      parallelToolCalls: true,
      reasoningEffort: r.reasoningEffort,
      // Codex's defaults: no summary for the gpt-6 catalog entries, `auto`
      // for fallback metadata. Only the Responses wire sends it.
      reasoningSummary: transport.wire == 'responses' && profile.usedFallback
          ? 'auto'
          : null,
      outputSchema: r.outputSchema == null || transport.wire != 'responses'
          ? null
          : modelFacingSchema(r.outputSchema!),
      promptCacheKey: r.execution.executionId,
    );
    final work = transport.sample(
      req,
      onReasoning: (t) => run._emit('thought', {'text': t}),
    );
    // A stop ends the wait at once; the abandoned call fails on its own.
    return Future.any<SampleResult>([
      work,
      run._cancel.token.whenCancelled.then<SampleResult>((_) {
        work.ignore();
        throw _Finish(() async => run._finishStopped(run._stopReason!));
      }),
    ]);
  }

  /// One model call with Codex's two retry layers.
  Future<SampleResult> _sample() async {
    var attempt = 0;
    var streamRetries = 0;
    ModelCallFailure? firstFailure;
    while (true) {
      var requestRetries = 0;
      while (true) {
        _checkStopped();
        final ModelCallFailure f;
        try {
          return await _attempt(attempt);
        } on _Finish {
          rethrow;
        } catch (e) {
          _checkStopped();
          f = _failure(e);
        }
        if (attempt > 0 &&
            firstFailure != null &&
            (f.status == 400 || f.status == 409)) {
          _failWith(
            firstFailure.errorType,
            '${firstFailure.message} (retry attempt $attempt of model call '
            '$_callIndex was refused by the gateway: ${f.message})',
          );
        }
        firstFailure ??= f;
        attempt++;
        if (f.requestRetryable && requestRetries < requestMaxRetries) {
          requestRetries++;
          final delay = f.retryAfter ?? requestBackoff(requestRetries, _random);
          _retryEvent(attempt, 'request', f, delay);
          await _sleep(delay);
          continue;
        }
        final delay = f.streamRetryDelay(streamRetries + 1, _random);
        if (delay == null || streamRetries >= streamMaxRetries) {
          _failWith(f.errorType, f.message);
        }
        streamRetries++;
        _retryEvent(attempt, 'stream', f, delay);
        await _sleep(delay);
        break;
      }
    }
  }

  void _retryEvent(int attempt, String layer, ModelCallFailure f, Duration d) =>
      run._emit('model_retry', {
        'call_index': _callIndex,
        'attempt': attempt,
        'layer': layer,
        'kind': f.kind.name,
        'message': f.message,
        'delay_ms': d.inMilliseconds,
      });

  // ---- tools -----------------------------------------------------------------

  Map<String, Object?> _arguments(Item call) {
    if (call['type'] == 'custom_tool_call') return {'input': call['input']};
    final raw = call['arguments'];
    if (raw is! String || raw.trim().isEmpty) return {};
    final decoded = jsonDecode(raw);
    if (decoded is! Map) throw const FormatException('not a JSON object');
    return decoded.cast<String, Object?>();
  }

  /// Runs every call but [skip], parallel-safe ones of a row together and
  /// the others alone, in order; the outputs in call order.
  Future<List<Item>> _runCalls(List<Item> calls, {Item? skip}) async {
    final todo = [
      for (final c in calls)
        if (!identical(c, skip)) c,
    ];
    final outputs = List<Item?>.filled(todo.length, null);
    var i = 0;
    while (i < todo.length) {
      if (parallelSafeTools.contains(todo[i]['name'])) {
        var j = i;
        while (j < todo.length && parallelSafeTools.contains(todo[j]['name'])) {
          j++;
        }
        final group = [for (var k = i; k < j; k++) k];
        final results = await Future.wait([
          for (final k in group) _runCall(todo[k]).then((o) => (k, o)),
        ], eagerError: false);
        for (final (k, o) in results) {
          outputs[k] = o;
        }
        i = j;
      } else {
        outputs[i] = await _runCall(todo[i]);
        i++;
      }
      _checkStopped();
    }
    return [for (final o in outputs) o!];
  }

  Future<Item> _runCall(Item call) async {
    final callId = '${call['call_id']}';
    final name = '${call['name']}';
    Map<String, Object?>? args;
    String? parseError;
    try {
      args = _arguments(call);
    } on FormatException catch (e) {
      parseError = 'failed to parse function arguments: ${e.message}';
    }
    run._emit('tool_call', {
      'id': callId,
      'name': name,
      'phase': 'started',
      'input': args ?? call['arguments'],
    });
    ({Object output, String? error, Object? event}) result;
    if (parseError != null) {
      result = (output: parseError, error: parseError, event: null);
    } else {
      try {
        result = await _tool(name, args!);
      } on SandboxFailure catch (e) {
        run._emit('tool_call', {
          'id': callId,
          'name': name,
          'phase': 'finished',
          'error': e.message,
        });
        rethrow;
      }
    }
    run._emit('tool_call', {
      'id': callId,
      'name': name,
      'phase': 'finished',
      if (result.error != null)
        'error': result.error
      else
        'output': result.event ?? result.output,
    });
    return call['type'] == 'custom_tool_call'
        ? customToolCallOutput(callId, result.output)
        : functionCallOutput(callId, result.output);
  }

  ({Object output, String? error, Object? event}) _text(ToolText t) =>
      (output: t.text, error: t.error ? t.text : null, event: null);

  Future<({Object output, String? error, Object? event})> _tool(
    String name,
    Map<String, Object?> args,
  ) async {
    switch (name) {
      case execCommandToolName when r.shell:
        return _text(await (await _unifiedExec()).execCommand(args));
      case writeStdinToolName when r.shell:
        return _text(await (await _unifiedExec()).writeStdin(args));
      case applyPatchToolName when r.shell:
        return _text(await _applyPatch(args));
      case codexViewImageToolName when r.viewImage:
        return _viewImage(args);
      case updatePlanToolName when r.updatePlan:
        final plan = args['plan'];
        if (plan is! List) {
          const m = 'failed to parse function arguments: missing field `plan`';
          return (output: m, error: m, event: null);
        }
        run._emit('plan', {
          'explanation': args['explanation'],
          'plan': plan,
          'call_index': _callIndex,
        });
        return (output: 'Plan updated', error: null, event: null);
      case askHumanToolName when r.askHuman:
        // Only invalid arguments get here (a valid question pauses).
        try {
          normalizeAskHumanArgs(args);
          const m = 'ask_human supports exactly one call per model turn';
          return (output: m, error: m, event: null);
        } on FormatException catch (e) {
          // Like Dify's ModelRetry: the model reads the error, tries again.
          final m =
              'Invalid ask_human arguments: ${e.message}. Fix the errors and '
              'try again.';
          return (output: m, error: e.message, event: null);
        }
      case reportProgressToolName when r.reportProgress:
        final p = await run._reportProgressCall(args, _callIndex);
        return (output: p.error ?? p.text, error: p.error, event: null);
      default:
        final m = 'unsupported call: $name';
        return (output: m, error: m, event: null);
    }
  }

  Future<UnifiedExec> _unifiedExec() => _execFuture ??= () async {
    final session = await run._shellSession();
    final exec = UnifiedExec(
      ShellctlExecBackend(session.sandbox.client(outputLimit: 256 * 1024)),
      env: session.env,
      truncationPolicy: profile.truncationPolicy,
      track: (id, offset, done) => session.trackJob(id, offset, done: done),
      workspace: session.sandbox.layout.workspaceDir,
    );
    return _exec = exec;
  }();

  Future<ToolText> _applyPatch(Map<String, Object?> args) async {
    final input = args['input'];
    if (input is! String) {
      return (
        text: 'failed to parse function arguments: missing field `input`',
        error: true,
      );
    }
    final sandbox = (await run._shellSession()).sandbox;
    final fs = SandboxPatchFileSystem((script) async {
      final c = await sandbox.control(script);
      return (exitCode: c.exitCode, output: c.output);
    });
    try {
      final t = await runApplyPatchTool(
        input,
        sandbox.layout.workspaceDir,
        fs,
        format: (run, wall) => formatExecOutputForModel(
          exitCode: run.exitCode,
          duration: wall,
          output: '${run.stdout}${run.stderr}',
          policy: profile.truncationPolicy,
        ),
      );
      return (text: t.text, error: t.error);
    } on ShellctlException catch (e) {
      return (text: 'apply_patch failed: ${e.toolText}', error: true);
    }
  }

  /// `view_image`: the workspace image uploaded as a file of the execution
  /// and put into the tool output (on the plugin wire it follows as a user
  /// message); 16 MiB of viewed images per conversation.
  Future<({Object output, String? error, Object? event})> _viewImage(
    Map<String, Object?> args,
  ) async {
    ({Object output, String? error, Object? event}) error(String m) =>
        (output: m, error: m, event: null);
    final path = args['path'];
    if (path is! String) {
      return error('failed to parse function arguments: missing field `path`');
    }
    final requested = args['detail'];
    if (requested != null && requested != 'high' && requested != 'original') {
      return error(
        'view_image.detail only supports `high` or `original`; omit `detail` '
        'for default high resized behavior, got `$requested`',
      );
    }
    final detail =
        requested == 'original' && profile.supportsImageDetailOriginal
        ? 'original'
        : 'high';
    final left = viewImageConversationBytes - run._viewedBytes;
    final img = await run._workspaceImage(
      path,
      left < 0 ? 0 : left,
      'the viewed images of this conversation may have at most '
      '$viewImageConversationBytes bytes together and ${run._viewedBytes} '
      'are used',
    );
    if (img.error != null) {
      return error(
        img.info == null && img.bytes.isNotEmpty
            ? 'unable to process image: invalid or unsupported image data'
            : img.error!,
      );
    }
    final info = img.info!;
    if (run._viewedBytes + img.bytes.length > viewImageConversationBytes) {
      return error(
        '${img.rel} is ${img.bytes.length} bytes; the viewed images of this '
        'conversation may have at most $viewImageConversationBytes bytes '
        'together and ${run._viewedBytes} are used. Make a smaller copy.',
      );
    }
    run._viewedBytes += img.bytes.length;
    final String uploadId;
    try {
      uploadId = await run._upload(
        img.rel.substring(img.rel.lastIndexOf('/') + 1),
        info.mimeType,
        img.bytes,
      );
    } on GatewayException catch (e) {
      run._viewedBytes -= img.bytes.length;
      return error('the image could not be attached: ${e.message}');
    }
    return (
      output: [
        inputImage(
          uploadId,
          info.mimeType,
          detail: detail,
          viewImage: {
            'path': img.rel,
            'size': img.bytes.length,
            'sha256': sha256.convert(img.bytes).toString(),
          },
        ),
      ],
      error: null,
      event:
          'image ${img.rel} (${info.mimeType}, ${info.width}x${info.height}, '
          '${img.bytes.length} bytes) attached',
    );
  }

  // ---- results -----------------------------------------------------------------

  Never _finalAnswer(List<Item> output) {
    final text = [
      for (final o in output)
        if (o['type'] == 'message' && o['role'] == 'assistant')
          for (final c in (o['content'] as List?) ?? const [])
            if (c is Map && c['text'] is String) c['text'] as String,
    ].join();
    final schema = r.outputSchema;
    _end(() async {
      Object? candidate;
      var errors = <Map<String, Object?>>[];
      if (schema == null) {
        candidate = {'text': text};
      } else {
        final parsed = parseFinalAnswerJson(text);
        if (parsed is Map) {
          final map = parsed.cast<String, Object?>();
          errors = await candidateErrors(schema, map);
          try {
            (candidate, errors) = await run._resolveFileOutputs(map, errors);
          } on SandboxFailure catch (e) {
            return run._fail(e.errorType, e.message);
          }
        } else {
          candidate = null;
          errors = [
            {
              'field': '',
              'error':
                  'the final answer is not a JSON object conforming to the '
                  'output schema',
            },
          ];
        }
      }
      run._finish('succeeded', {
        'candidate': candidate,
        'candidate_errors': errors,
        'snapshot': _snapshot(_revision + 1),
        'usage': run.usage.toJson(),
        'partial': run._partial,
      });
    });
  }

  Map<String, Object?> _snapshot(
    int revision, {
    Map<String, Object?>? pending,
  }) => {
    'envelope': envelopeName,
    'revision': revision,
    'harness_style': HarnessStyle.codex.wire,
    'codex': {
      'upstream': codexUpstream,
      'model_family': profile.family,
      'wire': transport.wire,
    },
    'agent_config_snapshot_id': r.execution.agentConfigSnapshotId,
    'tool_definitions_digest': codexToolDefinitionsDigest(r),
    'model': r.model.json,
    'output_attempt': r.outputAttempt,
    'resume_sequence': r.resumeSequence,
    'pending': pending,
    'file_ids': {
      for (final p in r.task)
        if (p is TaskFile) p.fileId,
      ...r.fileIds,
    }.toList(),
    'workspace_ref': run._workspaceRef,
    'executor_profile': r.executorProfile,
    'items': items,
  };
}
