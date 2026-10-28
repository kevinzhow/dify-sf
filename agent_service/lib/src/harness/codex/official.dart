/// The official Codex runtime of `harness_style: codex` (docs/agent-v2.md,
/// "Codex runtime"): the released Codex CLI binary runs inside the run's
/// sandbox as `codex app-server`, talks to the Swift gateway's Codex
/// Responses entry with the run's token, and is driven from here over its
/// JSON-RPC protocol (v2: `initialize`, `thread/start`, `turn/start`,
/// notifications, dynamic tools).
///
/// This file holds what does not need the run: the pinned binary, the
/// per-run `config.toml` and model catalog entry, and the JSON-RPC client.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'vendored.g.dart' show codexFallbackPrompt;

/// Which implementation runs `harness_style: codex`.
enum CodexRuntime {
  /// The released Codex binary in the sandbox (the default).
  official,

  /// The Dart port in `codex_run.dart` (kept while the official runtime is
  /// brought up; `AGENT_CODEX_RUNTIME=port`).
  port,
}

/// The pinned release: `rust-v0.163.0`, the static musl Linux x86_64 build.
const officialCodexVersion = '0.163.0';
const officialCodexSha256 =
    '399ff69c431c066e40de318fba45c2b07f45a76b19939d247ee4828fc70c4215';

/// Where the executor profile mounts the binary's directory (read-only;
/// `{"source": "<dir with codex>", "target": "/opt/codex"}`).
const officialCodexBinary = '/opt/codex/codex';

/// The model provider id in `config.toml`.
const codexProviderId = 'difysf';

/// The variable holding the run token (only Codex's own environment; the
/// commands it runs do not get it).
const codexTokenEnv = 'DIFYSF_RUN_TOKEN';

/// Path of the Codex Responses entry under the gateway's base URL.
const codexGatewayPath = '/inner/agent/codex/v1';

/// Reasoning levels accepted for the official runtime: Codex's own
/// (`ultra` is resolved by Codex; `persistent` is an interactive mode).
const officialCodexReasoningEfforts = [
  'none',
  'minimal',
  'low',
  'medium',
  'high',
  'xhigh',
  'max',
  'ultra',
];

/// Notifications the runtime does not read, suppressed at `initialize`
/// (`capabilities.optOutNotificationMethods`, exact method names of the
/// 0.163.0 schema, checked by tool/codex_e2e.sh): the streaming deltas
/// (the runtime reads completed items), the turn's diff and the account's
/// rate limits.
const codexOptOutNotifications = [
  'item/agentMessage/delta',
  'item/plan/delta',
  'item/reasoning/summaryTextDelta',
  'item/reasoning/summaryPartAdded',
  'item/reasoning/textDelta',
  'item/commandExecution/outputDelta',
  'item/fileChange/outputDelta',
  'item/fileChange/patchUpdated',
  'turn/diff/updated',
  'account/rateLimits/updated',
];

/// A TOML basic string (JSON's escapes are a subset of TOML's).
String tomlString(String s) => jsonEncode(s);

/// `config.toml` of one run (docs/agent-v2.md, "Codex runtime").
String codexConfigToml({
  required String model,
  required String baseUrl,
  required String catalogPath,
  required String workspace,
  String? effort,
  required bool shell,
  required bool viewImage,
  required bool updatePlan,
  bool skills = false,
  Map<String, String> commandEnv = const {},
}) {
  final b = StringBuffer()
    ..writeln('model = ${tomlString(model)}')
    ..writeln('model_provider = "$codexProviderId"');
  if (effort != null) {
    b.writeln('model_reasoning_effort = ${tomlString(effort)}');
  }
  b
    ..writeln('approval_policy = "never"')
    ..writeln('sandbox_mode = "danger-full-access"')
    ..writeln('web_search = "disabled"')
    ..writeln('check_for_update_on_startup = false')
    ..writeln('model_catalog_json = ${tomlString(catalogPath)}')
    ..writeln()
    ..writeln('[model_providers.$codexProviderId]')
    ..writeln('name = "dify-sf"')
    ..writeln('base_url = ${tomlString(baseUrl)}')
    ..writeln('wire_api = "responses"')
    ..writeln('env_key = "$codexTokenEnv"')
    ..writeln('supports_websockets = false')
    ..writeln()
    // The commands get the node's environment as the other styles do
    // (Codex's default KEY/SECRET/TOKEN filter off), never the run token or
    // shellctl's own variables.
    ..writeln('[shell_environment_policy]')
    ..writeln('ignore_default_excludes = true')
    ..writeln('exclude = ["$codexTokenEnv", "SHELLCTL_*"]')
    ..writeln();
  if (commandEnv.isNotEmpty) {
    b.writeln('[shell_environment_policy.set]');
    for (final e in commandEnv.entries) {
      b.writeln('${e.key} = ${tomlString(e.value)}');
    }
    b.writeln();
  }
  b
    // ask_human is not offered in this step: no request_user_input.
    ..writeln('[tools.experimental_request_user_input]')
    ..writeln('enabled = false')
    ..writeln()
    ..writeln('[tools.update_plan]')
    ..writeln('enabled = $updatePlan')
    ..writeln()
    // The catalog of the profile's skills (`codex.skills_dirs`); none
    // bundled.
    ..writeln('[skills]')
    ..writeln('include_instructions = $skills')
    ..writeln()
    ..writeln('[skills.bundled]')
    ..writeln('enabled = false')
    ..writeln()
    ..writeln('[features]')
    // Sub-agents only for `ultra`, which is what asks for them in Codex.
    ..writeln('multi_agent = ${effort == 'ultra'}')
    ..writeln('goals = false')
    ..writeln('apps = false')
    ..writeln('plugins = false')
    ..writeln('remote_plugin = false')
    ..writeln('image_generation = false')
    ..writeln('memories = false')
    ..writeln('skill_mcp_dependency_install = false')
    // Input sent during a turn (the near-budget notice) waits for the next
    // model request instead of discarding a response the gateway counted.
    ..writeln('instant_interrupt = false')
    ..writeln('defer_mailbox_preemption = true')
    // Connection failures end after Codex's bounded retries.
    ..writeln('unbounded_connection_retries = false')
    ..writeln('view_image = $viewImage')
    ..writeln('shell_tool = $shell')
    ..writeln('unified_exec = $shell')
    ..writeln()
    ..writeln('[analytics]')
    ..writeln('enabled = false')
    ..writeln()
    ..writeln('[history]')
    ..writeln('persistence = "none"')
    ..writeln()
    // The workspace is an untrusted project: no project config, hooks, exec
    // policies or AGENTS.md from it (a previous operation may have written
    // them); Codex would otherwise trust it at thread/start.
    ..writeln('[projects.${tomlString(workspace)}]')
    ..writeln('trust_level = "untrusted"');
  return b.toString();
}

/// The skills of a run, from Codex's `skills/list` answer for the
/// workspace: [names] are the enabled skills whose `SKILL.md` lies in one of
/// the profile's [dirs] (sorted); [others] are the paths of every other
/// enabled skill Codex found (the workspace's `.agents/skills` and
/// `.codex/skills`, the home's `.agents/skills`), which the run disables;
/// [errors] are the `SKILL.md` files Codex could not load.
({List<String> names, List<String> others, List<String> errors})
codexSkillSelection(Map<String, Object?> listed, List<String> dirs) {
  final names = <String>{};
  final others = <String>[];
  final errors = <String>[];
  for (final entry in (listed['data'] as List?) ?? const []) {
    if (entry is! Map) continue;
    for (final s in (entry['skills'] as List?) ?? const []) {
      if (s is! Map || s['enabled'] != true) continue;
      final path = '${s['path']}';
      if (dirs.any((d) => path.startsWith('$d/'))) {
        names.add('${s['name']}');
      } else if (!others.contains(path)) {
        others.add(path);
      }
    }
    for (final e in (entry['errors'] as List?) ?? const []) {
      if (e is Map) errors.add('${e['path']}: ${e['message']}');
    }
  }
  return (names: names.toList()..sort(), others: others, errors: errors);
}

/// Codex's `model_info_from_slug` (fallback metadata), as catalog JSON.
Map<String, Object?> codexFallbackEntry(String slug) => {
  'slug': slug,
  'display_name': slug,
  'description': null,
  'default_reasoning_level': null,
  'supported_reasoning_levels': <Object?>[],
  'shell_type': 'unified_exec',
  'visibility': 'none',
  'supported_in_api': true,
  'priority': 99,
  'availability_nux': null,
  'upgrade': null,
  'model_messages': {'instructions_template': codexFallbackPrompt},
  'supports_reasoning_summary_parameter': true,
  'default_reasoning_summary': 'auto',
  'support_verbosity': false,
  'default_verbosity': null,
  'apply_patch_tool_type': null,
  'web_search_tool_type': 'text',
  'truncation_policy': {'mode': 'bytes', 'limit': 10000},
  'supports_image_detail_original': false,
  'context_window': 272000,
  'max_context_window': 272000,
  'effective_context_window_percent': 95,
  'experimental_supported_tools': <Object?>[],
  'input_modalities': ['text', 'image'],
};

/// The bundled entry Codex would use for [model] (`find_model_by_longest_
/// prefix`, then after one simple `namespace/` segment), else dify-sf's
/// routing (`gpt-6*` to `gpt-6-astra`, as the Dart port), else null.
Map<String, Object?>? bundledEntryFor(
  String model,
  List<Map<String, Object?>> bundled,
) {
  Map<String, Object?>? longest(String name) {
    Map<String, Object?>? best;
    for (final m in bundled) {
      final slug = m['slug'];
      if (slug is String &&
          name.startsWith(slug) &&
          (best == null || slug.length > (best['slug'] as String).length)) {
        best = m;
      }
    }
    return best;
  }

  final i = model.indexOf('/');
  final suffix = i > 0 && !model.substring(i + 1).contains('/')
      ? model.substring(i + 1)
      : null;
  final found = longest(model) ?? (suffix == null ? null : longest(suffix));
  if (found != null) return found;
  final name = suffix ?? model;
  if (name.startsWith('gpt-6')) {
    return bundled.where((m) => m['slug'] == 'gpt-6-astra').firstOrNull;
  }
  return null;
}

/// Where the context window of [model]'s catalog entry comes from:
/// `operation` (`model.context_window`), `bundled` (Codex's bundled entry
/// for the model, see [bundledEntryFor]) or `fallback` (Codex's fallback
/// metadata: 272000 tokens, whatever the model really has).
String codexContextWindowSource(
  String model,
  List<Map<String, Object?>> bundled,
  int? contextWindow,
) => contextWindow != null
    ? 'operation'
    : bundledEntryFor(model, bundled) != null
    ? 'bundled'
    : 'fallback';

/// The one catalog entry of a run (`model_catalog_json`): the bundled entry
/// for [model] (see [bundledEntryFor]) or Codex's fallback metadata, named
/// [model], with the operation's model facts and dify-sf's settings:
///
/// - context window, reasoning levels and input modalities from the
///   operation when given;
/// - Direct tools (no code mode: the code-mode host is not installed), no
///   Responses-lite request shape and no WebSocket preference (both
///   ChatGPT-backend features), no service tiers;
/// - `apply_patch` as Codex's freeform tool (the only custom tool DeepSeek
///   accepts), none without the shell.
Map<String, Object?> codexCatalogEntry({
  required String model,
  required List<Map<String, Object?>> bundled,
  int? contextWindow,
  List<String>? reasoningEfforts,
  List<String>? inputModalities,
  required bool shell,
}) {
  final base = bundledEntryFor(model, bundled);
  final e = <String, Object?>{...base ?? codexFallbackEntry(model)};
  e
    ..['slug'] = model
    ..['display_name'] = model
    ..['visibility'] = 'list'
    ..['supported_in_api'] = true
    ..['priority'] = 1
    ..['upgrade'] = null
    ..['availability_nux'] = null
    ..['tool_mode'] = null
    ..['use_responses_lite'] = false
    ..['prefer_websockets'] = false
    ..['service_tiers'] = <Object?>[]
    ..['additional_speed_tiers'] = <Object?>[]
    ..['default_service_tier'] = null
    ..['apply_patch_tool_type'] = shell ? 'freeform' : null;
  if (contextWindow != null) {
    e['context_window'] = contextWindow;
    e['max_context_window'] = contextWindow;
  }
  if (reasoningEfforts != null) {
    final known = {
      for (final l in (e['supported_reasoning_levels'] as List?) ?? const [])
        if (l is Map) l['effort']: l,
    };
    e['supported_reasoning_levels'] = [
      for (final r in reasoningEfforts)
        known[r] ?? {'effort': r, 'description': r},
    ];
    final d = e['default_reasoning_level'];
    if (d != null && !reasoningEfforts.contains(d)) {
      e['default_reasoning_level'] = null;
    }
  }
  if (inputModalities != null) e['input_modalities'] = inputModalities;
  return e;
}

/// The value of `x-codex-promo-message` on the gateway's own call-limit 429
/// (`usage_limit_reached`, code `agent_call_limit`). Codex drops the body's
/// code and message of a `usage_limit_reached` 429 but puts this header into
/// the turn error's message ("You’ve hit your usage limit. PROMO, or try
/// again later."). The gateway forwards no provider header but
/// `Retry-After`, so a provider cannot send it.
const codexCallLimitMarker = 'dify-sf-agent-call-limit';

/// Codex's message for a 429 with `error.type: usage_limit_reached`
/// (`UsageLimitReachedError`); its quota and billing errors (also
/// `usageLimitExceeded`) read "Quota exceeded…" or name the plan.
final _usageLimitReachedText = RegExp('^You[’\']ve hit your usage limit');

/// The `error_type` of a turn that failed `usageLimitExceeded`:
/// `max_turns` when it is the gateway's own call limit, either marked
/// ([codexCallLimitMarker]) or a `usage_limit_reached` refusal after at
/// least [maxTurns] model calls seen here ([attempts]: finished calls and
/// retried ones; Codex's silent request retries are not seen); otherwise
/// `model_quota` (the provider's quota, billing or usage limit, or a
/// `usage_limit_reached` the gateway passed through).
String codexUsageLimitErrorType({
  required String message,
  required int attempts,
  required int maxTurns,
}) {
  if (message.contains(codexCallLimitMarker)) return 'max_turns';
  if (_usageLimitReachedText.hasMatch(message) && attempts >= maxTurns) {
    return 'max_turns';
  }
  return 'model_quota';
}

/// The reasoning effort Codex 0.163.0 sends for the thread's [effort] with
/// catalog [entry] (`ModelInfo::resolve_reasoning_effort`): `ultra` becomes
/// the entry's `multi_agent_reasoning_effort` when supported, else `max`,
/// else the last supported level, else `medium`; other levels are sent as
/// they are.
String? codexRequestEffort(String? effort, Map<String, Object?> entry) {
  if (effort != 'ultra') return effort;
  final levels = [
    for (final l in (entry['supported_reasoning_levels'] as List?) ?? const [])
      if (l is Map && l['effort'] is String) l['effort'] as String,
  ];
  final multi = entry['multi_agent_reasoning_effort'];
  if (multi is String && multi != 'ultra' && levels.contains(multi)) {
    return multi;
  }
  if (levels.contains('max')) return 'max';
  return levels.reversed.where((l) => l != 'ultra').firstOrNull ?? 'medium';
}

/// A JSON-RPC error answered by the app-server.
class CodexRpcError implements Exception {
  CodexRpcError(this.method, this.error);
  final String method;
  final Object? error;
  @override
  String toString() => 'codex $method failed: ${jsonEncode(error)}';
}

/// A notification of the app-server.
typedef CodexNotification = ({String method, Map<String, Object?> params});

/// Answers a request of the app-server (`item/tool/call`, approvals): the
/// result, or a thrown [CodexRpcError] for a JSON-RPC error.
typedef CodexServerRequestHandler = Future<Object?> Function(
  String method,
  Map<String, Object?> params,
);

/// Client of one `codex app-server` over its WebSocket transport: one
/// JSON-RPC message per text frame (Codex's "JSON-RPC lite": no `jsonrpc`
/// member).
class CodexAppServer {
  CodexAppServer._(this._ws, this.onServerRequest) {
    _ws.listen(
      _onFrame,
      onDone: _onClosed,
      onError: (Object e) => _onClosed(),
      cancelOnError: true,
    );
  }

  /// Connects with the capability token; retried until [timeout] (the
  /// server is still starting).
  static Future<CodexAppServer> connect(
    Uri url,
    String token, {
    required CodexServerRequestHandler onServerRequest,
    Duration timeout = const Duration(seconds: 30),
    Future<String?> Function()? whyNot,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      try {
        final ws = await WebSocket.connect(
          '$url',
          headers: {'Authorization': 'Bearer $token'},
        ).timeout(const Duration(seconds: 5));
        return CodexAppServer._(ws, onServerRequest);
      } catch (e) {
        final reason = await whyNot?.call();
        if (reason != null) throw StateError(reason);
        if (DateTime.now().isAfter(deadline)) {
          throw StateError('codex app-server at $url did not answer: $e');
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }
  }

  final WebSocket _ws;
  final CodexServerRequestHandler onServerRequest;
  final Map<int, (String, Completer<Map<String, Object?>>)> _pending = {};
  final StreamController<CodexNotification> _notifications =
      StreamController.broadcast(sync: true);
  final Completer<void> _closed = Completer();
  int _nextId = 0;

  Stream<CodexNotification> get notifications => _notifications.stream;

  /// Completes when the connection is gone.
  Future<void> get closed => _closed.future;
  bool get isClosed => _closed.isCompleted;

  void _send(Map<String, Object?> message) {
    if (isClosed) return;
    _ws.add(jsonEncode(message));
  }

  Future<Map<String, Object?>> request(
    String method,
    Map<String, Object?> params, {
    Duration timeout = const Duration(seconds: 60),
  }) {
    if (isClosed) {
      return Future.error(CodexRpcError(method, 'connection closed'));
    }
    final id = ++_nextId;
    final c = Completer<Map<String, Object?>>();
    _pending[id] = (method, c);
    _send({'id': id, 'method': method, 'params': params});
    return c.future.timeout(
      timeout,
      onTimeout: () {
        _pending.remove(id);
        throw CodexRpcError(method, 'no answer within $timeout');
      },
    );
  }

  void notify(String method, [Map<String, Object?>? params]) =>
      _send({'method': method, 'params': ?params});

  void _onFrame(Object? frame) {
    if (frame is! String) return;
    final Object? decoded;
    try {
      decoded = jsonDecode(frame);
    } on FormatException {
      return;
    }
    if (decoded is! Map) return;
    final m = decoded.cast<String, Object?>();
    final method = m['method'];
    final params = (m['params'] as Map?)?.cast<String, Object?>() ?? {};
    if (method is String && m.containsKey('id')) {
      unawaited(_answer(m['id'], method, params));
    } else if (method is String) {
      _notifications.add((method: method, params: params));
    } else if (m['id'] is int) {
      final p = _pending.remove(m['id']);
      if (p == null) return;
      final (name, c) = p;
      if (m['error'] != null) {
        c.completeError(CodexRpcError(name, m['error']));
      } else {
        c.complete((m['result'] as Map?)?.cast<String, Object?>() ?? {});
      }
    }
  }

  Future<void> _answer(
    Object? id,
    String method,
    Map<String, Object?> params,
  ) async {
    try {
      final result = await onServerRequest(method, params);
      _send({'id': id, 'result': result});
    } on CodexRpcError catch (e) {
      _send({
        'id': id,
        'error': {'code': -32601, 'message': '${e.error}'},
      });
    } catch (e) {
      _send({
        'id': id,
        'error': {'code': -32603, 'message': '$e'},
      });
    }
  }

  void _onClosed() {
    if (_closed.isCompleted) return;
    _closed.complete();
    for (final (name, c) in _pending.values) {
      c.completeError(CodexRpcError(name, 'connection closed'));
    }
    _pending.clear();
    unawaited(_notifications.close());
  }

  Future<void> close() async {
    try {
      await _ws.close().timeout(const Duration(seconds: 2));
    } catch (_) {}
    _onClosed();
  }
}
