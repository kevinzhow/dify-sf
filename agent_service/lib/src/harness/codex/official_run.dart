// The official Codex runtime of `harness_style: codex` (docs/agent-v2.md,
// "Codex runtime"): one operation is one turn of the released Codex binary
// (rust-v0.163.0) running as `codex app-server` in the execution's sandbox.

part of '../../loop.dart';

/// Binary checks already passed, by sandbox ID (version and sha256).
final Map<String, Future<void>> _codexBinaryChecks = {};

/// Codex's bundled model catalog (`codex debug models --bundled`), read once
/// per process from the pinned binary.
Future<List<Map<String, Object?>>>? _codexBundledCatalog;

/// Checks a continuation of the official runtime: only output retries (no
/// `ask_human` in this step); the snapshot names the same runtime.
void verifyOfficialCodexContinuation(OperationRequest r) {
  final c = r.continuation;
  if (c == null) return;
  final s = c.snapshot;
  final codex = s['codex'];
  if (codex is! Map || codex['runtime'] != 'official') {
    throw _incompatible('snapshot was not taken by the official Codex runtime');
  }
  if (s['agent_config_snapshot_id'] != r.execution.agentConfigSnapshotId) {
    throw _incompatible(
      'snapshot belongs to a different agent_config_snapshot_id',
    );
  }
  if (s['revision'] is! int) throw _incompatible('snapshot has no revision');
  switch (c) {
    case AnswerContinuation():
      throw _incompatible('the Codex runtime does not pause for questions');
    case OutputRetryContinuation():
      if (s['output_attempt'] != r.outputAttempt - 1 ||
          s['resume_sequence'] != r.resumeSequence) {
        throw _incompatible(
          'snapshot is not the one retried by this operation_id',
        );
      }
  }
}

/// [schema] made acceptable to strict structured outputs (Codex always
/// sends `strict: true`): every object closed, every property required,
/// the optional ones nullable. Unchanged when it already is.
Map<String, Object?> strictOutputSchema(Map<String, Object?> schema) {
  if (isStrictSchema(schema)) return schema;
  Object? walk(Object? node) {
    if (node is List) return [for (final n in node) walk(n)];
    if (node is! Map) return node;
    final out = <String, Object?>{
      for (final e in node.entries) '${e.key}': walk(e.value),
    };
    final props = out['properties'];
    if (props is Map) {
      final required = {...?(node['required'] as List?)?.cast<String>()};
      out['properties'] = {
        for (final e in props.entries)
          e.key: required.contains(e.key) ? e.value : _nullable(e.value),
      };
      out['required'] = [for (final k in props.keys) '$k'];
      out['additionalProperties'] = false;
    }
    return out;
  }

  return (walk(schema) as Map).cast<String, Object?>();
}

Object? _nullable(Object? s) {
  if (s is! Map) return s;
  final t = s['type'];
  if (t is String && t != 'null') {
    return {
      ...s,
      'type': [t, 'null'],
    };
  }
  if (t is List && !t.contains('null')) {
    return {
      ...s,
      'type': [...t, 'null'],
    };
  }
  return {
    'anyOf': [
      s,
      {'type': 'null'},
    ],
  };
}

/// Removes the `null`s [strictOutputSchema] made the model write for
/// optional properties of [schema].
Object? dropOptionalNulls(Map<String, Object?> schema, Object? value) {
  if (value is! Map) return value;
  final props = schema['properties'];
  if (props is! Map) return value;
  final required = {...?(schema['required'] as List?)?.cast<String>()};
  return {
    for (final e in value.entries)
      if (!(e.value == null &&
          props.containsKey(e.key) &&
          !required.contains(e.key)))
        e.key: props[e.key] is Map
            ? dropOptionalNulls(
                (props[e.key] as Map).cast<String, Object?>(),
                e.value,
              )
            : e.value,
  };
}

class _OfficialCodexRun {
  _OfficialCodexRun(this.run);

  final AgentRun run;
  OperationRequest get r => run.request;

  CodexAppServer? _server;
  String? _threadId;
  String? _turnId;
  final Completer<Map<String, Object?>> _turnDone = Completer();

  /// Model calls seen as finished (one `thread/tokenUsage/updated` each).
  int _calls = 0;

  /// Failed model calls Codex announced it retries (`error` with
  /// `willRetry`, every thread): each was a POST the gateway counted.
  int _retries = 0;

  /// The last assistant message without a phase (or `partial_answer`), not
  /// yet known to be commentary (a tool call follows) or the final answer.
  Map<String, Object?>? _unphased;
  String? _finalText;

  /// The catalog entry's context window and where it came from
  /// ([codexContextWindowSource]).
  Object? _contextWindow;
  String? _contextWindowSource;

  /// Whether a context compaction of the root thread is under way.
  bool _compacting = false;

  /// The CODEX_HOME of this run in the sandbox.
  String? _home;

  static final Random _random = Random.secure();

  Future<void> execute() async {
    run._onStop = _interrupt;
    Future<void> Function() finish;
    StopReason? stopped;
    try {
      try {
        finish = await _run();
      } on _Finish catch (f) {
        finish = f.run;
      } on SandboxFailure catch (e) {
        finish = () async => run._fail(e.errorType, e.message);
      } on ShellctlException catch (e) {
        finish = () async => run._fail('sandbox_error', e.toolText);
      } on CodexRpcError catch (e) {
        finish = () async => run._fail('internal', '$e');
      }
    } finally {
      // Also when something else was thrown (the run then fails internal).
      stopped = run._stopReason;
      await _cleanup();
    }
    if (stopped != null || run._stopReason != null) {
      return run._finishStopped(stopped ?? run._stopReason!);
    }
    await finish();
  }

  /// Closes the connection, ends the shell session (terminating the
  /// app-server job; the reap kills Codex and its children) and removes the
  /// run's CODEX_HOME. Never throws.
  Future<void> _cleanup() async {
    try {
      await _server?.close();
    } catch (e) {
      run.log?.call('run ${run.runId}: closing the codex connection: $e');
    }
    final home = _home;
    final session = run._session;
    try {
      await run._endShell();
    } catch (e) {
      run.log?.call('run ${run.runId}: ending the shell session: $e');
    }
    if (home != null && session != null) {
      try {
        await session.sandbox.control('rm -rf -- ${shellQuote(home)}');
      } catch (e) {
        run.log?.call('run ${run.runId}: could not remove $home: $e');
      }
    }
  }

  Never _failWith(String type, String message) =>
      throw _Finish(() async => run._fail(type, message));

  /// Adds [info] to the held `run_started`'s `runtime`.
  void _addRuntime(Map<String, Object?> info) {
    final held = run._heldRunStarted;
    if (held == null) return;
    held['runtime'] = {...?held['runtime'] as Map?, ...info};
  }

  /// A failure found while the turn runs (Codex's settings changed): the
  /// turn is interrupted and the run ends with it.
  ({String type, String message})? _aborted;
  final Completer<void> _abortSignal = Completer();

  void _abort(String type, String message) {
    if (_aborted != null) return;
    _aborted = (type: type, message: message);
    _abortSignal.complete();
    _interrupt();
  }

  void _checkAborted() {
    final a = _aborted;
    if (a == null) return;
    _closeOpenTools('the run ended: ${a.message}');
    _failWith(a.type, a.message);
  }

  /// Why Codex's [model] and [effort] (from `thread/start` or
  /// `thread/settings/updated`) are not the run's, else null. `ultra` is
  /// Codex's to resolve; with no requested effort any is accepted.
  String? _settingsMismatch(String where, Object? model, Object? effort) {
    final want = r.reasoningEffort;
    if (model != r.model.name) {
      return 'Codex $where model ${jsonEncode(model)}, not the requested '
          '${jsonEncode(r.model.name)}';
    }
    if (want != null && want != 'ultra' && effort != want) {
      return 'Codex $where reasoning effort ${jsonEncode(effort)}, not the '
          'requested ${jsonEncode(want)}';
    }
    return null;
  }

  void _checkStopped() {
    final s = run._stopReason;
    if (s != null) throw _Finish(() async => run._finishStopped(s));
  }

  /// `turn/interrupt`, then the connection is closed (the job is terminated
  /// by [execute] through the shell session).
  void _interrupt() {
    final server = _server;
    final thread = _threadId;
    final turn = _turnId;
    if (server == null || thread == null || turn == null) return;
    unawaited(
      server
          .request('turn/interrupt', {
            'threadId': thread,
            'turnId': turn,
          }, timeout: const Duration(seconds: 3))
          .then((_) {}, onError: (_) {}),
    );
  }

  Future<String> _controlOk(ExecutionSandbox sandbox, String script) async {
    final c = await sandbox.control('set -eu\n$script', mergeStderr: false);
    if (c.exitCode != 0) {
      throw SandboxFailure(
        'sandbox_error',
        'Codex setup failed in the sandbox (${c.status} ${c.exitCode}): '
            '${c.output.trim()}',
      );
    }
    return c.output;
  }

  Future<void> _checkBinary(
    ExecutionSandbox sandbox,
  ) => _codexBinaryChecks[sandbox.sandboxId] ??=
      () async {
        final out = await sandbox.control(
          'b=$officialCodexBinary\n'
          '[ -x "\$b" ] || { echo missing; exit 0; }\n'
          'echo "version \$("\$b" --version 2>&1 | head -1)"\n'
          'echo "sha256 \$(sha256sum "\$b" | cut -d" " -f1)"',
        );
        final text = out.output;
        if (text.trim() == 'missing') {
          throw SandboxFailure(
            'sandbox_error',
            'the Codex binary is not in the sandbox at $officialCodexBinary '
                '(the executor profile ${r.executorProfile} must mount the '
                'Codex $officialCodexVersion release directory at /opt/codex)',
          );
        }
        final version = RegExp(
          r'^version (.*)$',
          multiLine: true,
        ).firstMatch(text)?.group(1)?.trim();
        final sum = RegExp(
          r'^sha256 ([0-9a-f]{64})$',
          multiLine: true,
        ).firstMatch(text)?.group(1);
        if (version != 'codex-cli $officialCodexVersion' ||
            sum != officialCodexSha256) {
          throw SandboxFailure(
            'sandbox_error',
            'the Codex binary at $officialCodexBinary is "$version" with '
                'sha256 $sum; expected codex-cli $officialCodexVersion, '
                '$officialCodexSha256',
          );
        }
      }().catchError((Object e) {
        _codexBinaryChecks.remove(sandbox.sandboxId);
        throw e;
      });

  Future<List<Map<String, Object?>>> _bundled(ExecutionSandbox sandbox) =>
      _codexBundledCatalog ??=
          () async {
            final out = await _controlOk(
              sandbox,
              'd=\$(mktemp -d "\$HOME/.codex-catalog.XXXXXX")\n'
              'trap \'rm -rf -- "\$d"\' EXIT\n'
              'CODEX_HOME="\$d" $officialCodexBinary debug models --bundled',
            );
            final models = (jsonDecode(out) as Map)['models'] as List;
            return [for (final m in models) (m as Map).cast<String, Object?>()];
          }().catchError((Object e) {
            _codexBundledCatalog = null;
            throw e;
          });

  Future<void> _writeHome(
    ExecutionSandbox sandbox,
    String path,
    String text,
  ) async {
    final b64 = base64.encode(utf8.encode(text));
    final lines = [
      for (var j = 0; j < b64.length; j += 76)
        b64.substring(j, (j + 76).clamp(0, b64.length)),
    ];
    await _controlOk(
      sandbox,
      "base64 -d > ${shellQuote(path)} <<'DIFYSF_EOF'\n${lines.join('\n')}\nDIFYSF_EOF",
    );
  }

  /// The profile's `codex.skills_dirs` as the sandbox resolves them (Codex
  /// reports skills by their resolved paths); a missing one ends the run.
  Future<List<String>> _skillsDirs(ExecutionSandbox sandbox) async {
    final dirs = run._codexSkillsDirs;
    if (dirs.isEmpty) return const [];
    final out = await _controlOk(
      sandbox,
      [
        for (final d in dirs)
          'if [ -d ${shellQuote(d)} ]; then readlink -f -- ${shellQuote(d)}; '
              'else echo; fi',
      ].join('\n'),
    );
    final resolved = const LineSplitter().convert(out);
    final mounts = [
      for (final m
          in run.sandboxes?.profiles[r.executorProfile]?.mounts ?? const [])
        m.target,
    ];
    for (var i = 0; i < dirs.length; i++) {
      final d = i < resolved.length ? resolved[i] : '';
      if (!d.startsWith('/')) {
        throw SandboxFailure(
          'sandbox_error',
          'the Codex skills directory ${dirs[i]} of executor profile '
              '${r.executorProfile} is not a directory in the sandbox',
        );
      }
      // Symlinks must not lead out of the read-only mounts.
      if (!mounts.any((t) => d == t || d.startsWith('$t/'))) {
        throw SandboxFailure(
          'sandbox_error',
          'the Codex skills directory ${dirs[i]} of executor profile '
              '${r.executorProfile} resolves to $d, outside its mounts',
        );
      }
    }
    return resolved.take(dirs.length).toList();
  }

  /// Points Codex at the profile's skills (`skills/extraRoots/set`), lists
  /// what it found for the workspace and writes the names into the held
  /// `run_started`. Returns the paths of the other skills Codex found, which
  /// the thread disables: a run offers exactly the profile's skills.
  Future<List<String>> _loadSkills(
    CodexAppServer server,
    ExecutionSandbox sandbox,
    List<String> dirs,
  ) async {
    if (dirs.isEmpty) return const [];
    await server.request('skills/extraRoots/set', {'extraRoots': dirs});
    final listed = await server.request('skills/list', {
      'cwds': [sandbox.layout.workspaceDir],
      'forceReload': true,
    });
    final s = codexSkillSelection(listed, dirs);
    for (final e in s.errors) {
      run.log?.call('run ${run.runId}: codex skill not loaded: $e');
    }
    if (s.others.isNotEmpty) {
      run.log?.call(
        'run ${run.runId}: codex skills outside the profile disabled: '
        '${s.others.join(', ')}',
      );
    }
    _addRuntime({'skills': s.names});
    return s.others;
  }

  /// Task files go into the workspace; images are given to Codex as local
  /// images (Codex inlines them as data URLs), other files by path.
  Future<List<Map<String, Object?>>> _input(ExecutionSandbox sandbox) async {
    final input = <Map<String, Object?>>[];
    void text(String t) =>
        input.add({'type': 'text', 'text': t, 'text_elements': <Object?>[]});
    for (final p in r.task) {
      switch (p) {
        case TaskText():
          text(p.text);
        case TaskFile():
          final inner = run._inner!;
          final info = await inner.downloadRequest(p.fileId);
          final url = info['url'];
          if (url is! String || url.isEmpty) {
            throw SandboxFailure(
              'file_error',
              'no download URL for ${p.fileId}',
            );
          }
          final mime = p.mimeType ?? '${info['mime_type'] ?? ''}';
          final bytes = await inner.downloadBytes(
            url,
            run.sandboxes!.maxInputFileBytes,
          );
          final ext = switch (mime) {
            'image/png' => '.png',
            'image/jpeg' => '.jpg',
            'image/webp' => '.webp',
            'image/gif' => '.gif',
            'application/pdf' => '.pdf',
            'text/plain' => '.txt',
            _ => '',
          };
          final rel = '.dify-sf/task-files/${p.fileId}$ext';
          await sandbox.writeFile(rel, bytes);
          final path = '${sandbox.layout.workspaceDir}/$rel';
          if (mime.startsWith('image/')) {
            input.add({'type': 'localImage', 'path': path});
          } else {
            text('Attached file ($mime): $path');
          }
      }
    }
    final c = r.continuation;
    if (c is OutputRetryContinuation) {
      final previous = (c.snapshot['codex'] as Map?)?['final_answer'];
      text(
        [
          if (previous is String && previous.isNotEmpty)
            'Your previous final answer was:\n$previous',
          AgentRun._feedbackText(c.feedback),
          'The workspace still holds the files of that attempt.',
        ].join('\n\n'),
      );
    }
    return input;
  }

  Future<Future<void> Function()> _run() async {
    if (r.continuation != null) verifyOfficialCodexContinuation(r);
    final session = await run._shellSession();
    _checkStopped();
    final sandbox = session.sandbox;
    final baseUrl =
        sandbox.grant.codexGatewayUrl?.toString() ?? run.codexGatewayUrl;
    if (baseUrl == null) {
      _failWith(
        'sandbox_unavailable',
        'Codex cannot reach the model gateway from the sandbox of executor '
            'profile ${r.executorProfile}: the supervisor gave no '
            'codex_gateway_url (the Codex gateway route needs a profile with '
            'network egress "allowlist")',
      );
    }
    final token = r.codexRunToken;
    if (token == null) _failWith('internal', 'model.run_token is missing');
    await _checkBinary(sandbox);
    final bundled = await _bundled(sandbox);
    // Codex reaches the gateway directly (NO_PROXY=*); the commands it runs
    // keep the sandbox's own NO_PROXY.
    final noProxy = const LineSplitter().convert(
      await _controlOk(
        sandbox,
        r'printf "%s\n%s\n" "${NO_PROXY-}" "${no_proxy-}"',
      ),
    );
    _checkStopped();

    final skillsDirs = await _skillsDirs(sandbox);
    final home = _home = '${sandbox.layout.homeDir}/.codex-runs/${run.runId}';
    await _controlOk(sandbox, 'mkdir -p -- ${shellQuote(home)}');
    final schema = r.outputSchema;
    await _writeHome(
      sandbox,
      '$home/config.toml',
      codexConfigToml(
        model: r.model.name,
        baseUrl: baseUrl,
        catalogPath: '$home/models.json',
        workspace: sandbox.layout.workspaceDir,
        effort: r.reasoningEffort,
        shell: r.shell,
        viewImage: r.viewImage,
        updatePlan: r.updatePlan,
        skills: skillsDirs.isNotEmpty,
        commandEnv: {
          'NO_PROXY': noProxy.isEmpty ? '' : noProxy[0],
          'no_proxy': noProxy.length < 2 ? '' : noProxy[1],
        },
      ),
    );
    final entry = codexCatalogEntry(
      model: r.model.name,
      bundled: bundled,
      contextWindow: r.model.contextWindow,
      reasoningEfforts: r.model.reasoningEfforts,
      inputModalities: r.model.inputModalities,
      shell: r.shell,
    );
    final windowSource = codexContextWindowSource(
      r.model.name,
      bundled,
      r.model.contextWindow,
    );
    _contextWindow = entry['context_window'];
    _contextWindowSource = windowSource;
    if (windowSource == 'fallback') {
      run.log?.call(
        'run ${run.runId}: no model.context_window and ${r.model.name} is '
        'not in Codex\'s bundled catalog: Codex\'s fallback context window '
        '(${entry['context_window']} tokens) applies to compaction and the '
        'context limit',
      );
    }
    _addRuntime({
      'context_window': entry['context_window'],
      'context_window_source': windowSource,
    });
    await _writeHome(
      sandbox,
      '$home/models.json',
      jsonEncode({
        'models': [entry],
      }),
    );
    // The node's instructions are Codex's global AGENTS.md.
    if (r.systemPrompt.trim().isNotEmpty) {
      await _writeHome(sandbox, '$home/AGENTS.md', r.systemPrompt);
    }
    final input = await _input(sandbox);
    _checkStopped();

    // The app-server: a stdio job of the run's shell session, listening on
    // the sandbox network with a capability token known only here.
    final wsToken = [for (var i = 0; i < 32; i++) _random.nextInt(256)]
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    final port =
        codexAppServerPortForTests?.call() ?? 20000 + _random.nextInt(20000);
    final client = sandbox.client();
    final JobResult job;
    try {
      job = await client.run(
        'exec $officialCodexBinary app-server --listen ws://0.0.0.0:$port '
        '--ws-auth capability-token --ws-token-sha256 ${sha256Hex(wsToken)} '
        '2>&1',
        cwd: sandbox.layout.workspaceDir,
        env: {
          ...session.env,
          'CODEX_HOME': home,
          codexTokenEnv: token,
          'NO_PROXY': '*',
          'no_proxy': '*',
        },
        timeout: 1,
        mode: 'stdio',
      );
    } finally {
      client.close();
    }
    session.trackJob(job.jobId, 0, done: job.done);
    Future<String?> whyNot() async {
      final c = sandbox.client();
      try {
        final s = await c.status(job.jobId);
        if (!s.done) return null;
        // Its stderr is merged into the output (`2>&1`). Mask capabilities
        // before truncation, so a boundary cannot expose half a token.
        final shown = codexDiagnosticTail((await c.tail(job.jobId)).output, [
          token,
          wsToken,
          run.runToken,
          run.serviceKey,
        ]);
        return 'codex app-server exited (${s.status} ${s.exitCode})'
            '${shown.isEmpty ? ' without output' : ': $shown'}';
      } catch (_) {
        return null;
      } finally {
        c.close();
      }
    }

    final server = _server =
        await CodexAppServer.connect(
          Uri(scheme: 'ws', host: sandbox.grant.url.host, port: port),
          wsToken,
          onServerRequest: _serverRequest,
          whyNot: whyNot,
        ).catchError((Object e) {
          throw SandboxFailure('sandbox_error', 'Codex did not start: $e');
        });
    server.notifications.listen(_onNotification);
    _checkStopped();

    await server.request('initialize', {
      'clientInfo': {
        'name': 'dify_sf',
        'title': 'dify-sf agent service',
        'version': serviceVersion,
      },
      'capabilities': {
        'experimentalApi': true,
        'optOutNotificationMethods': codexOptOutNotifications,
      },
    });
    server.notify('initialized');
    final disabledSkills = await _loadSkills(server, sandbox, skillsDirs);
    final thread = await server.request('thread/start', {
      'cwd': sandbox.layout.workspaceDir,
      'approvalPolicy': 'never',
      'sandbox': 'danger-full-access',
      'ephemeral': true,
      if (disabledSkills.isNotEmpty)
        'config': {
          'skills.config': [
            for (final p in disabledSkills) {'path': p, 'enabled': false},
          ],
        },
      'dynamicTools': [
        if (r.reportProgress)
          {
            'type': 'function',
            'name': reportProgressToolName,
            'description': reportProgressDescription,
            'inputSchema': reportProgressInputSchema,
          },
      ],
    });
    _threadId = (thread['thread'] as Map)['id'] as String;
    // Codex's settings for the thread, as it will send them.
    final model = thread['model'];
    final effort = thread['reasoningEffort'];
    final sent = codexRequestEffort(effort is String ? effort : null, entry);
    run.log?.call(
      'run ${run.runId}: codex thread $_threadId: model ${jsonEncode(model)}, '
      'reasoning effort ${jsonEncode(effort)}'
      '${sent == effort ? '' : ' (requests carry ${jsonEncode(sent)})'}; '
      'requested ${jsonEncode(r.model.name)}, ${jsonEncode(r.reasoningEffort)}',
    );
    _addRuntime({
      'model': model,
      'reasoning_effort': effort,
      if (sent != effort) 'request_reasoning_effort': sent,
    });
    final mismatch = _settingsMismatch(
      'started the thread with',
      model,
      effort,
    );
    if (mismatch != null) _failWith('internal', mismatch);
    run._runStarted();
    _checkAborted();
    final turn = await server.request('turn/start', {
      'threadId': _threadId,
      'input': input,
      if (schema != null)
        'outputSchema': strictOutputSchema(modelFacingSchema(schema)),
    });
    _turnId = (turn['turn'] as Map)['id'] as String;
    run._onCallStart(1);
    _checkStopped();

    final done = await Future.any<Map<String, Object?>?>([
      _turnDone.future,
      server.closed.then((_) => null),
      run._cancel.token.whenCancelled.then((_) => null),
      _abortSignal.future.then((_) => null),
    ]);
    if (done == null && !server.isClosed) {
      // Stopped (interrupt sent): give the turn a moment to end, so its last
      // items are mapped.
      await _turnDone.future
          .timeout(const Duration(seconds: 3))
          .then((_) {}, onError: (_) {});
    }
    _checkStopped();
    _checkAborted();
    if (!_turnDone.isCompleted) {
      // Codex went away mid-turn: the process's exit status and output once
      // the job is seen ended (a moment after the connection).
      String? exited;
      for (var i = 0; i < 12 && exited == null; i++) {
        if (i > 0) {
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
        exited = await whyNot();
      }
      _checkStopped();
      final why =
          exited ??
          'the connection to the Codex app-server closed and the process '
              'still runs';
      _closeOpenTools('the Codex app-server ended before the tool finished');
      _failWith(
        exited == null ? 'internal' : 'sandbox_error',
        'Codex ended mid-turn: $why',
      );
    }
    return _complete(await _turnDone.future);
  }

  Future<void> Function() _complete(Map<String, Object?> turn) {
    switch (turn['status']) {
      case 'completed':
        break;
      case 'interrupted':
        _checkStopped();
        _failWith('internal', 'Codex interrupted the turn');
      default:
        final error = (turn['error'] as Map?) ?? const {};
        final info = error['codexErrorInfo'];
        final message = [
          error['message'] ?? 'the Codex turn failed',
          ?error['additionalDetails'],
        ].join(': ');
        if (info == 'usageLimitExceeded') {
          final attempts = _calls + _retries;
          final type = codexUsageLimitErrorType(
            message: message,
            attempts: attempts,
            maxTurns: r.maxTurns,
          );
          final seen =
              '$_calls model calls finished here'
              '${_retries == 0 ? '' : ', $_retries retried'}';
          if (type == 'max_turns') {
            final n = run._notice;
            _failWith(
              'max_turns',
              'the run reached max_turns (${r.maxTurns}): the gateway refused '
                  'the next model call (usage_limit_reached, its call limit) '
                  'without a final answer ($seen)'
                  '${n == null ? '' : '; the model was told to finish at call ${n.callIndex}'}',
            );
          }
          _failWith(
            'model_quota',
            'the model call was refused for a usage, quota or billing limit '
                'that is not the gateway\'s call limit (max_turns '
                '${r.maxTurns}, $seen): Codex: $message',
          );
        }
        if (info == 'contextWindowExceeded') {
          _failWith(
            'model_error',
            'the conversation no longer fits the model\'s context window '
                '($_contextWindow tokens, $_contextWindowSource) and Codex '
                'could not compact it enough: Codex: $message',
          );
        }
        _failWith('model_error', 'Codex: $message (${jsonEncode(info)})');
    }
    // The final answer: the turn's last agent message when Codex lists the
    // items, else the last `final_answer` message, else the last message
    // without a phase or with `partial_answer` that no tool call followed
    // (providers do not always send a phase).
    final items = (turn['items'] as List?) ?? const [];
    String? itemFinal;
    String? itemCandidate;
    var hasMessageOrTool = false;
    for (final item in items.whereType<Map>()) {
      if (_toolItems.contains(item['type'])) {
        hasMessageOrTool = true;
        itemCandidate = null;
      } else if (item['type'] == 'agentMessage') {
        hasMessageOrTool = true;
        if (item['phase'] == 'final_answer') {
          itemFinal = item['text'] as String?;
        } else if (item['phase'] == null || item['phase'] == 'partial_answer') {
          itemCandidate = item['text'] as String?;
        } else {
          itemCandidate = null;
        }
      }
    }
    final text =
        itemFinal ??
        _finalText ??
        itemCandidate ??
        (hasMessageOrTool ? null : _unphased?['text'] as String?) ??
        '';
    final schema = r.outputSchema;
    return () async {
      Object? candidate;
      var errors = <Map<String, Object?>>[];
      if (schema == null) {
        candidate = {'text': text};
      } else {
        final parsed = parseFinalAnswerJson(text);
        if (parsed is Map) {
          final map = (dropOptionalNulls(
            modelFacingSchema(schema),
            parsed,
          ) as Map).cast<String, Object?>();
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
        'snapshot': _snapshot(text),
        'usage': run.usage.toJson(),
        'partial': run._partial,
      });
    };
  }

  Map<String, Object?> _snapshot(String finalAnswer) => {
    'envelope': envelopeName,
    'revision': ((r.continuation?.snapshot['revision'] as int?) ?? 0) + 1,
    'harness_style': HarnessStyle.codex.wire,
    'codex': {
      'runtime': 'official',
      'version': officialCodexVersion,
      'final_answer': finalAnswer,
    },
    'agent_config_snapshot_id': r.execution.agentConfigSnapshotId,
    'model': r.model.json,
    'output_attempt': r.outputAttempt,
    'resume_sequence': r.resumeSequence,
    'pending': null,
    'file_ids': {
      for (final p in r.task)
        if (p is TaskFile) p.fileId,
      ...r.fileIds,
    }.toList(),
    'workspace_ref': run._workspaceRef,
    'executor_profile': r.executorProfile,
  };

  // ---- Codex events -> dify-sf events -------------------------------------

  int get _callIndex => _calls + 1;

  static String _toolName(Map item) => switch (item['type']) {
    'commandExecution' => 'exec_command',
    'fileChange' => 'apply_patch',
    'imageView' => 'view_image',
    'dynamicToolCall' => '${item['tool']}',
    'mcpToolCall' => '${item['server']}.${item['tool']}',
    final t => '$t',
  };

  static const _toolItems = {
    'commandExecution',
    'fileChange',
    'imageView',
    'dynamicToolCall',
    'mcpToolCall',
    'webSearch',
  };

  String _rel(Object? path) {
    final ws = run._session?.sandbox.layout.workspaceDir ?? '/workspace';
    final p = '$path';
    return p.startsWith('$ws/') ? p.substring(ws.length + 1) : p;
  }

  Object? _itemInput(Map item) => switch (item['type']) {
    'commandExecution' => {'command': item['command'], 'cwd': item['cwd']},
    'fileChange' => {
      'changes': [
        for (final c in (item['changes'] as List?) ?? const [])
          if (c is Map)
            {'path': _rel(c['path']), 'kind': (c['kind'] as Map?)?['type']},
      ],
    },
    'imageView' => {'path': _rel(item['path'])},
    'dynamicToolCall' || 'mcpToolCall' => item['arguments'],
    _ => item,
  };

  /// Commands and patches as Codex reports them; failed or declined ones
  /// carry `error`.
  Map<String, Object?> _result(Map item) {
    final status = item['status'];
    switch (item['type']) {
      case 'commandExecution':
        final out = '${item['aggregatedOutput'] ?? ''}';
        final shown = out.length > 64 * 1024
            ? '${out.substring(0, 32 * 1024)}\n…\n${out.substring(out.length - 32 * 1024)}'
            : out;
        if (status == 'declined' ||
            (status == 'failed' && item['exitCode'] == null)) {
          return {'error': 'command $status: $shown'};
        }
        return {
          'output': {
            'exit_code': item['exitCode'],
            'duration_ms': item['durationMs'],
            'output': shown,
          },
        };
      case 'fileChange':
        final changes = [
          for (final c in (item['changes'] as List?) ?? const [])
            if (c is Map)
              {
                'path': _rel(c['path']),
                'kind': (c['kind'] as Map?)?['type'],
                'diff': c['diff'],
              },
        ];
        return status == 'completed'
            ? {
                'output': {'changes': changes},
              }
            : {
                'error': 'patch $status',
                'output': {'changes': changes},
              };
      case 'imageView':
        return {'output': 'image ${_rel(item['path'])} attached'};
      case 'dynamicToolCall':
        final text = [
          for (final c in (item['contentItems'] as List?) ?? const [])
            if (c is Map && c['type'] == 'inputText') c['text'],
        ].join('\n');
        return item['success'] == false ? {'error': text} : {'output': text};
      default:
        return {
          if (status == 'failed') 'error': '${item['error'] ?? status}',
          'output': item['result'] ?? status,
        };
    }
  }

  /// Tool calls of the root thread started and not finished, by item ID.
  final Map<Object?, String> _openTools = {};

  /// Finishes the open tool calls with [error] (Codex will not).
  void _closeOpenTools(String error) {
    for (final e in _openTools.entries) {
      run._emit('tool_call', {
        'id': e.key,
        'name': e.value,
        'phase': 'finished',
        'error': error,
      });
    }
    _openTools.clear();
  }

  void _compactionDone() {
    _compacting = false;
    run._emit('compaction', {'phase': 'finished', 'call_index': _callIndex});
  }

  void _flushUnphased() {
    final m = _unphased;
    if (m == null) return;
    _unphased = null;
    run._emit('commentary', {'text': m['text'], 'call_index': _callIndex});
  }

  void _onNotification(CodexNotification n) {
    final p = n.params;
    // Sub-agents (`ultra`) run in their own threads; only their model calls
    // count here.
    final mine = p['threadId'] == null || p['threadId'] == _threadId;
    switch (n.method) {
      case 'item/started' when mine:
        final item = p['item'];
        if (item is! Map) return;
        if (item['type'] == 'contextCompaction') {
          _compacting = true;
          run._emit('compaction', {
            'phase': 'started',
            'call_index': _callIndex,
          });
        } else if (_toolItems.contains(item['type'])) {
          _flushUnphased();
          _openTools[item['id']] = _toolName(item);
          run._emit('tool_call', {
            'id': item['id'],
            'name': _toolName(item),
            'phase': 'started',
            'input': _itemInput(item),
          });
        }
      case 'item/completed' when mine:
        final item = p['item'];
        if (item is! Map) return;
        final type = item['type'];
        if (type == 'contextCompaction') {
          _compactionDone();
        } else if (_toolItems.contains(type)) {
          _openTools.remove(item['id']);
          run._emit('tool_call', {
            'id': item['id'],
            'name': _toolName(item),
            'phase': 'finished',
            ..._result(item),
          });
        } else if (type == 'agentMessage') {
          _flushUnphased();
          final text = '${item['text'] ?? ''}';
          switch (item['phase']) {
            case 'final_answer':
              _finalText = text;
            case 'commentary':
              run._emit('commentary', {'text': text, 'call_index': _callIndex});
            default:
              _unphased = item.cast<String, Object?>();
          }
        } else if (type == 'reasoning') {
          final buffer = ThoughtBuffer(
            (t) => run._emit('thought', {'text': t}),
          );
          final parts = [
            ...((item['summary'] as List?) ?? const []),
            ...((item['content'] as List?) ?? const []),
          ].whereType<String>().where((t) => t.trim().isNotEmpty);
          buffer
            ..add(parts.join('\n\n'))
            ..flush();
        }
      case 'turn/plan/updated' when mine:
        run._emit('plan', {
          'explanation': p['explanation'],
          'plan': [
            for (final s in (p['plan'] as List?) ?? const [])
              if (s is Map)
                {
                  'step': s['step'],
                  'status': s['status'] == 'inProgress'
                      ? 'in_progress'
                      : s['status'],
                },
          ],
          'call_index': _callIndex,
        });
      case 'thread/tokenUsage/updated':
        _onUsage(p);
      case 'error':
        final error = (p['error'] as Map?) ?? const {};
        if (p['willRetry'] != true) return;
        // Every thread's retried call counts at the gateway; only the root
        // thread's are the run's model_retry (a sub-agent's are logged).
        _retries++;
        if (!mine) {
          run.log?.call(
            'run ${run.runId}: codex sub-agent ${p['threadId']} retries a '
            'model call: ${jsonEncode(error)}',
          );
        } else {
          run._emit('model_retry', {
            'call_index': _callIndex,
            'attempt': null,
            'layer': 'codex',
            'kind': error['codexErrorInfo'],
            'message': error['message'],
            'delay_ms': null,
          });
        }
      case 'turn/completed' when mine:
        final turn = p['turn'];
        if (turn is Map &&
            (turn['id'] == _turnId || _turnId == null) &&
            !_turnDone.isCompleted) {
          _turnDone.complete(turn.cast<String, Object?>());
        }
      case 'thread/settings/updated' when p['threadId'] == _threadId:
        final s = (p['threadSettings'] as Map?) ?? const {};
        run.log?.call(
          'run ${run.runId}: codex thread settings updated: model '
          '${jsonEncode(s['model'])}, reasoning effort ${jsonEncode(s['effort'])}',
        );
        final mismatch = _settingsMismatch(
          'changed the thread to',
          s['model'],
          s['effort'],
        );
        if (mismatch != null) _abort('internal', mismatch);
      // Deprecated (Codex 0.163.0 sends the item instead): ends a
      // compaction the item did not.
      case 'thread/compacted' when mine:
        if (_compacting) _compactionDone();
      case 'model/rerouted':
        run.log?.call(
          'run ${run.runId}: codex rerouted thread ${p['threadId']} from '
          '${jsonEncode(p['fromModel'])} to ${jsonEncode(p['toModel'])} '
          '(${p['reason']})',
        );
      case 'warning' || 'configWarning' || 'deprecationNotice':
        run.log?.call('run ${run.runId}: codex ${n.method}: ${jsonEncode(p)}');
    }
  }

  /// One finished model call: usage and the near-budget notice (counted
  /// here; the gateway counts every attempt). No `model_call` event: the
  /// Swift server records model calls from its gateway.
  void _onUsage(Map<String, Object?> p) {
    final last = ((p['tokenUsage'] as Map?)?['last'] as Map?) ?? const {};
    int n(Object? v) => v is num ? v.toInt() : 0;
    final cached = n(last['cachedInputTokens']);
    final u = Usage()
      ..promptTokens = n(last['inputTokens'])
      ..completionTokens = n(last['outputTokens'])
      ..totalTokens = n(last['totalTokens'])
      ..reasoningTokens = n(last['reasoningOutputTokens'])
      ..promptCacheHitTokens = cached
      ..promptCacheMissTokens = (n(last['inputTokens']) - cached).clamp(
        0,
        1 << 62,
      );
    if (u.totalTokens == 0) u.totalTokens = u.promptTokens + u.completionTokens;
    run.usage.add(u);
    _calls++;
    run.log?.call(
      'run ${run.runId}: codex model call $_calls '
      '(${p['threadId'] == _threadId ? 'main' : 'sub-agent'}): '
      '${jsonEncode(u.toJson())}',
    );
    run._onCallStart(_calls + 1);
    _maybeNotice();
  }

  void _maybeNotice() {
    if (run._notice != null || _threadId == null || _turnId == null) return;
    final need = callsToFinish(r);
    final callIndex = _calls + 1;
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
    unawaited(
      _server
          ?.request('turn/steer', {
            'threadId': _threadId,
            'expectedTurnId': _turnId,
            'input': [
              {
                'type': 'text',
                'text': codexBudgetNoticeText(
                  r,
                  remainingCalls: remainingCalls,
                  remainingSeconds: reason == BudgetReason.timeout
                      ? seconds
                      : null,
                ),
                'text_elements': <Object?>[],
              },
            ],
          })
          .then(
            (_) {},
            onError: (Object e) {
              run.log?.call('run ${run.runId}: budget notice not sent: $e');
            },
          ),
    );
    run._emit('budget_notice', {
      'reason': reason.wire,
      'call_index': callIndex,
      'remaining_calls': remainingCalls,
      if (reason == BudgetReason.timeout) 'remaining_seconds': seconds,
    });
  }

  /// Requests of the app-server: the dynamic tools and the clock
  /// (`currentTime/read`: whole Unix seconds); everything else (no
  /// approvals with `approval_policy = never`) is refused.
  Future<Object?> _serverRequest(
    String method,
    Map<String, Object?> params,
  ) async {
    if (method == 'currentTime/read') {
      return {'currentTimeAt': DateTime.now().millisecondsSinceEpoch ~/ 1000};
    }
    if (method != 'item/tool/call') throw CodexRpcError(method, 'unsupported');
    final tool = params['tool'];
    final args = params['arguments'];
    ({String? error, String text}) result;
    if (tool == reportProgressToolName && r.reportProgress) {
      result = await run._reportProgressCall(
        args is Map ? args.cast<String, Object?>() : const {},
        _callIndex,
      );
    } else {
      result = (error: 'unsupported tool: $tool', text: '');
    }
    return {
      'contentItems': [
        {'type': 'inputText', 'text': result.error ?? result.text},
      ],
      'success': result.error == null,
    };
  }
}
