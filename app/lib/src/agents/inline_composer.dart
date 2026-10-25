import 'dart:async';
import 'dart:convert';

import 'package:collab_client/collab_client.dart';

import '../ids.dart';
import '../workflow/dify_json.dart';

typedef AgentDocumentState = ({Document document, int seq, bool ready});

/// Private configuration and shared graph edits use one server transaction. A save never writes a second set of
/// optimistic graph operations, never rebases somebody else's private prompt, and retains its receipt identity.
class InlineAgentComposer {
  InlineAgentComposer({
    required this.api,
    required this.appId,
    required this.state,
    required this.changes,
    this.waitTimeout = const Duration(seconds: 15),
  });

  factory InlineAgentComposer.forSession(
    AgentComposerApi api,
    String appId,
    CollabSession session,
  ) => InlineAgentComposer(
    api: api,
    appId: appId,
    changes: session.changes,
    state: () => (
      document: session.confirmed,
      seq: session.lastSeq,
      ready: session.hasState && session.pending.isEmpty && session.link == LinkState.live,
    ),
  );

  final AgentComposerApi api;
  final String appId;
  final AgentDocumentState Function() state;
  final Stream<void> changes;
  final Duration waitTimeout;
  final Map<String, Map<String, Object?>> _creates = {};

  Future<void> _until(bool Function(AgentDocumentState) predicate) async {
    final complete = Completer<void>();
    void inspect() {
      if (!complete.isCompleted && predicate(state())) complete.complete();
    }

    final subscription = changes.listen(
      (_) => inspect(),
      onError: (Object _) {
        if (!complete.isCompleted) complete.completeError(const AgentComposerConflict('connection'));
      },
      onDone: () {
        if (!complete.isCompleted) complete.completeError(const AgentComposerConflict('connection'));
      },
    );
    try {
      inspect();
      await complete.future.timeout(waitTimeout);
    } finally {
      await subscription.cancel();
    }
  }

  Future<Map<String, Object?>> load(
    String nodeId, {
    String? agentId,
    String? snapshotId,
  }) async {
    final response = await api.readInlineAgent(
      appId,
      nodeId,
      agentId: agentId,
      snapshotId: snapshotId,
    );
    final seq = response['document_seq'];
    if (seq is! int) throw const FormatException('agent_composer_receipt');
    await _until((s) => s.ready && s.seq >= seq);
    _sameBinding(nodeId, response['binding']);
    return response;
  }

  void _sameBinding(String nodeId, Object? expected) {
    final node = state().document.nodes[nodeId];
    if (node == null) throw const AgentComposerConflict('node_deleted');
    final current = difyDataOf(node)['agent_binding'];
    for (final key in ['agent_id', 'current_snapshot_id']) {
      final before = expected is Map ? expected[key] : null;
      final now = current is Map ? current[key] : null;
      if (before != now) throw const AgentComposerConflict('binding_changed');
    }
  }

  /// Called once per user save. If transport outcome is uncertain, retain this exact payload for [save].
  Future<Map<String, Object?>> prepare(
    String nodeId,
    Map<String, Object?> loaded,
    Map<String, Object?> soul, {
    String strategy = 'save_to_current_version',
    String versionNote = '',
  }) async {
    await _until((s) => s.ready);
    _sameBinding(nodeId, loaded['binding']);
    final current = state();
    final data = difyDataOf(current.document.nodes[nodeId]!);
    final job = {
      ...?(loaded['node_job'] as Map?)?.cast<String, Object?>(),
      'workflow_prompt': data['agent_task'] ?? '',
      'declared_outputs': data['agent_declared_outputs'] ?? <Object?>[],
    };
    // Detach editable trees: retries must not silently acquire subsequently typed values.
    return (jsonDecode(
      jsonEncode({
        'variant': 'workflow',
        'expected_seq': current.seq,
        'expected_node': {
          for (final field in ['agent_binding', 'agent_task', 'agent_declared_outputs']) field: data[field],
        },
        'idempotency_key': newUuid(),
        'binding': loaded['binding'] ?? {'binding_type': 'inline_agent'},
        'agent_soul': soul,
        'node_job': job,
        'save_strategy': strategy,
        'version_note': versionNote,
      }),
    ) as Map).cast<String, Object?>();
  }

  Future<Map<String, Object?>> save(
    String nodeId,
    Map<String, Object?> payload,
  ) async {
    final response = await api.saveInlineAgent(appId, nodeId, payload);
    final seq = response['document_seq'];
    if (seq is! int) throw const FormatException('agent_composer_receipt');
    await _until((s) => s.ready && s.seq >= seq);
    _sameBinding(nodeId, response['binding']);
    return response;
  }

  Map<String, Object?>? _pendingPaste;
  String? _pendingPasteSource;

  Future<Map<String, Object?>> exportClipboard(List<String> nodes) async {
    if (api is! AgentClipboardApi) throw const AgentComposerConflict('clipboard_unavailable');
    await _until((s) => s.ready);
    return (api as AgentClipboardApi).exportAgentClipboard(appId, {
      'expected_seq': state().seq, 'node_ids': nodes,
      'expected_nodes': {for (final id in nodes) id: state().document.nodes[id]?.toJson()},
    });
  }

  Future<Map<String, Object?>> pasteClipboard(Map<String, Object?> graph) async {
    if (api is! AgentClipboardApi) throw const AgentComposerConflict('clipboard_unavailable');
    await _until((s) => s.ready);
    final source = jsonEncode(graph['clipboard_source'] ?? graph);
    if (_pendingPaste != null && _pendingPasteSource != source) {
      // Resolve the original receipt before accepting a different operation. Never silently paste old contents.
      throw const AgentComposerConflict('clipboard_pending_changed');
    }
    _pendingPasteSource ??= source;
    _pendingPaste ??= (jsonDecode(
      jsonEncode({...graph, 'expected_seq': state().seq, 'idempotency_key': newUuid()}..remove('clipboard_source')),
    ) as Map).cast<String, Object?>();
    try {
      final saved = await (api as AgentClipboardApi).pasteAgentClipboard(appId, _pendingPaste!);
      final seq = saved['document_seq'];
      if (seq is! int || saved['node_ids'] is! List || saved['edge_ids'] is! List) {
        throw const FormatException('agent_clipboard_receipt');
      }
      await _until((s) => s.ready && s.seq >= seq);
      _pendingPaste = null;
      _pendingPasteSource = null;
      return saved;
    } on Object catch (error) {
      if (!agentSaveUncertain(error)) { _pendingPaste = null; _pendingPasteSource = null; }
      rethrow;
    }
  }

  Future<Map<String, Object?>> create(String nodeId) async {
    var payload = _creates[nodeId];
    if (payload == null) {
      final loaded = await load(nodeId);
      if (loaded['binding'] is Map) return loaded;
      payload = await prepare(
        nodeId,
        loaded,
        (loaded['agent_soul'] as Map).cast<String, Object?>(),
        strategy: 'node_job_only',
      );
      _creates[nodeId] = payload;
    }
    try {
      final saved = await save(nodeId, payload);
      _creates.remove(nodeId);
      return saved;
    } on TransportException catch (e) {
      if (!agentSaveUncertain(e)) _creates.remove(nodeId);
      rethrow;
    }
  }
}

bool agentSaveUncertain(Object error) =>
    error is TimeoutException ||
    (error is TransportException && (error.timeout || error.statusCode == null || error.statusCode! >= 500));

class AgentComposerConflict implements Exception {
  const AgentComposerConflict(this.reason);
  final String reason;
  @override
  String toString() => 'AgentComposerConflict($reason)';
}

/// Only locally authored error text is shown. Remote response bodies may contain private configuration.
String agentSaveErrorKey(Object error) {
  if (error is! TransportException) return 'inline.saveFailed';
  if (error.code == 'secrets_key_missing') return 'inline.secretsUnavailable';
  if (error.code == 'agent_idempotency_conflict') return 'inline.receiptConflict';
  return switch (error.statusCode) {
    400 || 422 => 'inline.invalidConfiguration',
    401 => 'inline.loginRequired',
    403 => 'inline.editForbidden',
    404 => 'inline.nodeMissing',
    413 => 'inline.configurationTooLarge',
    429 => 'inline.rateLimited',
    _ => 'inline.saveFailed',
  };
}
