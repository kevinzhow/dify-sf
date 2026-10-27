import 'dart:convert';

import 'package:collab_client/collab_client.dart';

import '../workflow/dify_json.dart';
import 'model_compatibility.g.dart';

bool isInlineAgentData(Map<String, Object?> data) =>
    (data['type'] == 'agent' || data['type'] == 'agent-v2') &&
    data['version'] == '2' &&
    data['agent_node_kind'] == 'dify_agent';

/// Same pinned upstream name filter as the Swift runtime, in addition to tool-call capability checks.
bool inlineAgentModelCompatible(String englishLabel) =>
    !inlineAgentExcludedModels.any((pattern) => pattern.hasMatch(englishLabel));

/// The private half of the editor's checklist, fetched by the immutable identities in the same graph snapshot.
/// Only issue labels reach the checklist/MCP response; masked config and credential references stay internal.
class InlineAgentChecks {
  const InlineAgentChecks({
    this.souls = const {},
    this.unavailable = const [],
    this.retryable = false,
  });
  final Map<String, Map<String, Object?>> souls;
  final List<String> unavailable;
  final bool retryable;

  static String identities(Document doc) => [
    for (final node in doc.nodes.values)
      if (isInlineAgentData(difyDataOf(node))) '${node.id}:${plainOf(node.config['agent_binding'])}',
  ].join('|');

  static Future<InlineAgentChecks> load(
    AgentComposerApi api,
    String app,
    Document doc,
  ) async {
    final souls = <String, Map<String, Object?>>{};
    final unavailable = <String>[];
    var retryable = false;
    for (final node in doc.nodes.values) {
      final data = difyDataOf(node);
      if (!isInlineAgentData(data)) continue;
      final binding = data['agent_binding'];
      if (binding is! Map ||
          binding['binding_type'] != 'inline_agent' ||
          binding['agent_id'] is! String ||
          binding['current_snapshot_id'] is! String) {
        continue;
      }
      try {
        final response = await api.readInlineAgent(
          app,
          node.id,
          agentId: binding['agent_id'] as String,
          snapshotId: binding['current_snapshot_id'] as String,
        );
        final found = response['binding'];
        final soul = response['agent_soul'];
        if (found is! Map ||
            found['agent_id'] != binding['agent_id'] ||
            found['current_snapshot_id'] != binding['current_snapshot_id'] ||
            soul is! Map) {
          throw const FormatException('agent_snapshot_identity');
        }
        souls[node.id] = {
          ...soul.cast<String, Object?>(),
          '_missing_job_files': jsList(
            jsGet(jsGet(response['node_job'], 'metadata'), 'file_refs'),
          ).any(missingFileReference),
        };
        if (hasUnsupported(souls[node.id]!)) unavailable.add('unsupported_agent_configuration:${node.id}');
      } on TransportException catch (error) {
        if (error.statusCode == 404) {
          souls[node.id] = {'_missing': true};
        } else {
          unavailable.add('agent_configuration:${node.id}');
          retryable |= error.timeout || error.statusCode == null || error.statusCode == 429 || error.statusCode! >= 500;
        }
      } on Object {
        unavailable.add('agent_configuration:${node.id}');
      }
    }
    final checks = InlineAgentChecks(
      souls: souls,
      unavailable: unavailable,
      retryable: retryable,
    );
    return souls.isEmpty ? checks : checks.withExecutors(await AgentExecutorContext.load(api, app));
  }

  InlineAgentChecks withExecutors(AgentExecutorContext context) => InlineAgentChecks(
    souls: {
      for (final entry in souls.entries)
        entry.key: {
          ...({...entry.value}
            ..remove('_executor_profile_status')
            ..remove('_executor_profiles_unknown')
            ..remove('_max_turns_max')),
          if (context.shellEnabled && context.profiles != null)
            '_executor_profile_status': context.named(executorName(entry.value))?.status ?? 'unavailable',
          if (context.shellEnabled && context.profiles != null)
            '_max_turns_max': context.named(executorName(entry.value))?.maxTurnsMax ?? 50,
          if (context.unknown) '_executor_profiles_unknown': true,
        },
    },
    unavailable: [
      ...unavailable.where((key) => key != 'agent_executor_profiles'),
      if (context.unknown && souls.isNotEmpty) 'agent_executor_profiles',
    ],
    retryable: retryable,
  );

  static String executorName(Map<String, Object?>? soul) =>
      soul?['executor_profile'] is String && (soul!['executor_profile'] as String).isNotEmpty
      ? soul['executor_profile'] as String
      : 'default';
  static bool executorUnknown(Map<String, Object?>? soul) => soul?['_executor_profiles_unknown'] == true;
  static Map<String, Object?> profileParams(Map<String, Object?>? soul) => {
    'name': executorName(soul),
  };

  static const omittedFileReference = 'dify-file-ref:eyJyZWNvcmRfaWQiOiJvbWl0dGVkIn0=';

  static bool missingFileReference(Object? value) {
    if (value is! Map || value['is_missing'] == true) return true;
    Object? id = value['file_id'] ?? value['upload_file_id'] ?? value['related_id'] ?? value['id'];
    final reference = value['reference'];
    if (id == null && reference is String && reference.startsWith('dify-file-ref:')) {
      try {
        id = (jsonDecode(
          utf8.decode(
            base64Decode(reference.substring('dify-file-ref:'.length)),
          ),
        ) as Map)['record_id'];
      } on Object {
        return true;
      }
    }
    return id is! String || !RegExp(r'^[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$').hasMatch(id);
  }

  static bool _missingDefault(Object? value, Object? shape) {
    if (shape is! Map) return false;
    if (shape['type'] == 'file') return value is Map && value['reference'] == omittedFileReference;
    if (shape['type'] == 'array' && value is List) {
      return value.any((item) => _missingDefault(item, shape['array_item']));
    }
    if (shape['type'] == 'object' && value is Map) {
      return jsList(shape['children']).any(
        (child) => child is Map && _missingDefault(value[child['name']], child),
      );
    }
    return false;
  }

  static bool hasUnsupported(Map<String, Object?> soul) => [
    jsGet(soul['tools'], 'dify_tools'),
    jsGet(soul['tools'], 'cli_tools'),
    jsGet(soul['knowledge'], 'sets'),
    soul['config_skills'],
    jsGet(soul['human'], 'tools'),
  ].any((value) => value is List && value.isNotEmpty);

  static List<({String namespace, String key})> issues(
    Map<String, Object?>? soul, {
    Map<String, List<String>>? modelFeatures,
    Map<String, String>? modelLabels,
    List<Object?> declarations = const [],
  }) {
    if (soul == null || soul['_missing'] == true) return [(namespace: 'agent-v-2', key: 'inline.configUnavailable')];
    final model = soul['model'];
    return [
      if (soul['_executor_profile_status'] != null && soul['_executor_profile_status'] != 'ok')
        (namespace: 'agent-v-2', key: 'inline.executorUnavailable'),
      if (!validTurnLimit(soul)) (namespace: 'agent-v-2', key: 'inline.invalidMaxTurns'),
      if (model is! Map ||
          ['plugin_id', 'model_provider', 'model'].any(
            (key) => model[key] is! String || (model[key] as String).isEmpty,
          ))
        (namespace: 'workflow', key: 'nodes.agent.modelNotSelected'),
      if (jsList(soul['config_files']).any(
        (file) => jsGet(file, 'is_missing') == true || jsStr(jsGet(file, 'file_id'))?.isNotEmpty != true,
      ))
        (namespace: 'agent-v-2', key: 'agentDetail.configure.files.missing'),
      if (jsList(jsGet(soul['env'], 'secret_refs')).any(
        (entry) => jsStr(jsGet(entry, 'ref'))?.isNotEmpty != true || jsGet(entry, 'is_missing') == true,
      ))
        (namespace: 'agent-v-2', key: 'inline.secretMissing'),
      if (model is Map &&
          !inlineAgentModelCompatible(
            modelLabels?['${model['plugin_id']}/${model['model_provider']}/${model['model']}'] ??
                '${model['model'] ?? ''}',
          ))
        (namespace: 'agent-v-2', key: 'inline.modelUnsupported'),
      if (modelFeatures?.containsKey('__loading__') == true) (namespace: 'agent-v-2', key: 'inline.catalogUnavailable'),
      if (model is Map &&
          modelFeatures != null &&
          !modelFeatures.containsKey('__loading__') &&
          !(modelFeatures['${model['plugin_id']}/${model['model_provider']}/${model['model']}'] ?? const []).any(
            (feature) => const ['tool-call', 'multi-tool-call'].contains(feature),
          ))
        (namespace: 'agent-v-2', key: 'inline.toolCallsRequired'),
      if (soul['_missing_job_files'] == true) (namespace: 'agent-v-2', key: 'inline.taskFileMissing'),
      if (declarations.any(
        (field) =>
            field is Map &&
            _missingDefault(
              jsGet(field['failure_strategy'], 'default_value'),
              field,
            ),
      ))
        (namespace: 'agent-v-2', key: 'inline.defaultFileMissing'),
      if (hasUnsupported(soul)) (namespace: 'agent-v-2', key: 'inline.unsupported'),
    ];
  }

  static bool validTurnLimit(Map<String, Object?> soul) {
    final limits = soul['limits'];
    if (limits == null) return 50 <= (soul['_max_turns_max'] as int? ?? 1000);
    if (limits is! Map || limits.keys.any((k) => k != 'max_turns')) return false;
    final count = limits['max_turns'];
    final maximum = soul['_max_turns_max'] as int? ?? 1000;
    return count is int && count >= 1 && count <= 1000 && count <= maximum;
  }
}
