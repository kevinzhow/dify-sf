import 'package:collab_client/collab_client.dart';

import '../workflow/dify_json.dart';

bool isInlineAgentData(Map<String, Object?> data) =>
    (data['type'] == 'agent' || data['type'] == 'agent-v2') &&
    data['version'] == '2' &&
    data['agent_node_kind'] == 'dify_agent';

/// The private half of the editor's checklist, fetched by the immutable identities in the same graph snapshot.
/// Only issue labels reach the checklist/MCP response; masked config and credential references stay internal.
class InlineAgentChecks {
  const InlineAgentChecks({this.souls = const {}, this.unavailable = const []});
  final Map<String, Map<String, Object?>> souls;
  final List<String> unavailable;

  static String identities(Document doc) => [
    for (final node in doc.nodes.values)
      if (isInlineAgentData(difyDataOf(node))) '${node.id}:${plainOf(node.config['agent_binding'])}',
  ].join('|');

  static Future<InlineAgentChecks> load(AgentComposerApi api, String app, Document doc) async {
    final souls = <String, Map<String, Object?>>{};
    final unavailable = <String>[];
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
        souls[node.id] = soul.cast<String, Object?>();
        if (hasUnsupported(souls[node.id]!)) unavailable.add('unsupported_agent_configuration:${node.id}');
      } on TransportException catch (error) {
        if (error.statusCode == 404) {
          souls[node.id] = {'_missing': true};
        } else {
          unavailable.add('agent_configuration:${node.id}');
        }
      } on Object {
        unavailable.add('agent_configuration:${node.id}');
      }
    }
    return InlineAgentChecks(souls: souls, unavailable: unavailable);
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
  }) {
    if (soul == null || soul['_missing'] == true) return [(namespace: 'agent-v-2', key: 'inline.configUnavailable')];
    final model = soul['model'];
    return [
      if (model is! Map ||
          [
            'plugin_id',
            'model_provider',
            'model',
          ].any((key) => model[key] is! String || (model[key] as String).isEmpty))
        (namespace: 'workflow', key: 'nodes.agent.modelNotSelected'),
      if (jsList(soul['config_files'])
          .any((file) => jsGet(file, 'is_missing') == true || jsStr(jsGet(file, 'file_id'))?.isNotEmpty != true))
        (namespace: 'agent-v-2', key: 'agentDetail.configure.files.missing'),
      if (jsList(jsGet(soul['env'], 'secret_refs')).any((entry) => jsStr(jsGet(entry, 'ref'))?.isNotEmpty != true))
        (namespace: 'agent-v-2', key: 'inline.secretMissing'),
      if (model is Map &&
          modelFeatures != null &&
          !(modelFeatures['${model['plugin_id']}/${model['model_provider']}/${model['model']}'] ?? const []).any(
            (feature) => const ['tool-call', 'multi-tool-call'].contains(feature),
          ))
        (namespace: 'agent-v-2', key: 'inline.toolCallsRequired'),
      if (hasUnsupported(soul)) (namespace: 'agent-v-2', key: 'inline.unsupported'),
    ];
  }
}
