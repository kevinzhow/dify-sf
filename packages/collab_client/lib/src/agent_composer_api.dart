/// Dify's inline Agent v2 workflow composer. Private configuration is fetched separately from the shared graph.
/// `expected_seq` and `idempotency_key` are dify-sf extensions: a stale save is rejected, and an identical retry
/// returns the original masked response rather than creating another snapshot.
library;

abstract class AgentComposerApi {
  Future<Map<String, Object?>> readInlineAgent(
    String appId,
    String nodeId, {
    String? snapshotId,
    String? agentId,
  });

  /// Caller retains the exact payload/key across uncertain network retries. No secret is echoed by the server.
  Future<Map<String, Object?>> saveInlineAgent(
    String appId,
    String nodeId,
    Map<String, Object?> body,
  );
}

/// dify-sf extension. Portable clipboard exports omit workspace resources; same-app duplicate uses private source identities.
abstract class AgentClipboardApi {
  Future<Map<String, Object?>> exportAgentClipboard(String appId, Map<String, Object?> body);
  Future<Map<String, Object?>> pasteAgentClipboard(String appId, Map<String, Object?> body);
}
