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
  Future<Map<String, Object?>> exportAgentClipboard(
    String appId,
    Map<String, Object?> body,
  );
  Future<Map<String, Object?>> pasteAgentClipboard(
    String appId,
    Map<String, Object?> body,
  );
}

/// Server-owned execution environments. The authenticated endpoint has the same workspace read access as the composer.
abstract class AgentExecutorProfilesApi {
  Future<Map<String, Object?>> agentExecutorProfiles(String appId);
}

class AgentExecutorProfile {
  const AgentExecutorProfile(
    this.name,
    this.description,
    this.status,
    this.timeoutSecondsMax,
  );
  final String name, description, status;
  final int timeoutSecondsMax;
}

/// A failed read remains unknown. An empty list must never stand in for an unreachable service.
class AgentExecutorContext {
  const AgentExecutorContext({required this.shellEnabled, this.profiles});
  final bool shellEnabled;
  final List<AgentExecutorProfile>? profiles;
  bool get unknown => shellEnabled && profiles == null;

  static final namePattern = RegExp(r'^[a-z0-9][a-z0-9-]{0,63}$');
  static AgentExecutorContext parse(Map<String, Object?> value) {
    if (value['shell_enabled'] is! bool) {
      throw const FormatException('executor_shell_policy');
    }
    final enabled = value['shell_enabled'] == true;
    final raw = value['profiles'];
    if (raw == null) return AgentExecutorContext(shellEnabled: enabled);
    if (raw is! List || raw.isEmpty || raw.length > 256) {
      throw const FormatException('executor_profiles');
    }
    final names = <String>{};
    final profiles = <AgentExecutorProfile>[];
    for (final entry in raw) {
      if (entry is! Map ||
          entry['name'] is! String ||
          !namePattern.hasMatch(entry['name'] as String) ||
          !names.add(entry['name'] as String) ||
          entry['description'] is! String ||
          (entry['description'] as String).runes.length > 200 ||
          !const [
            'ok',
            'image_missing',
            'device_missing',
            'unavailable',
          ].contains(entry['status']) ||
          entry['timeout_seconds_max'] is! int ||
          (entry['timeout_seconds_max'] as int) < 1 ||
          (entry['timeout_seconds_max'] as int) > 86400) {
        throw const FormatException('executor_profile');
      }
      profiles.add(
        AgentExecutorProfile(
          entry['name'] as String,
          entry['description'] as String,
          entry['status'] as String,
          entry['timeout_seconds_max'] as int,
        ),
      );
    }
    if (!names.contains('default')) {
      throw const FormatException('executor_default');
    }
    return AgentExecutorContext(
      shellEnabled: enabled,
      profiles: List.unmodifiable(profiles),
    );
  }

  static Future<AgentExecutorContext> load(
    AgentComposerApi api,
    String appId,
  ) async {
    try {
      if (api is! AgentExecutorProfilesApi) {
        throw const FormatException('executor_catalog_unsupported');
      }
      return parse(
        await (api as AgentExecutorProfilesApi).agentExecutorProfiles(appId),
      );
    } on Object {
      return const AgentExecutorContext(shellEnabled: true);
    }
  }

  AgentExecutorProfile? named(String name) {
    for (final profile in profiles ?? const <AgentExecutorProfile>[]) {
      if (profile.name == name) return profile;
    }
    return null;
  }
}
