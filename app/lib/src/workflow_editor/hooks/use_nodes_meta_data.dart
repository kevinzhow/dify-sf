/// hooks/use-nodes-meta-data.ts `useNodeMetaData`: a node's author and description as its "About" shows them: a tool
/// or data source names its provider's (from the tool collections / data source list), other blocks Dify's.
library;

import '../../workflow/dify_json.dart';
import '../block_selector/block_selector_data.dart' show pluginLanguage;
import '../context_menu/node_meta.dart';
import '../node_panel/bodies/data/tool/tool_model.dart' show CollectionType, canFindTool;
import '../store/store.dart';

/// `{author, description}` of a node's [data]. [buildInTools] / [customTools] / [workflowTools] are the tool
/// providers (`ToolWithProvider` JSON: `id`, `author`, `description` by language), [dataSourceList] the data
/// sources (`plugin_id`, `author`, `description`); [language] picks the description (default: the UI's).
({String? author, String? description}) nodeMetaDataOf(
  DifyJson data, {
  List<DifyJson>? buildInTools,
  List<DifyJson>? customTools,
  List<DifyJson>? workflowTools,
  List<DifyJson>? dataSourceList,
  String? language,
}) {
  final lang = language ?? pluginLanguage;
  DifyJson? provider;
  switch (data['type']) {
    case 'datasource':
      provider = dataSourceList?.where((d) => d['plugin_id'] == data['plugin_id']).firstOrNull;
    case 'tool':
      final id = data['provider_id'];
      provider = switch (data['provider_type']) {
        CollectionType.builtIn => buildInTools?.where((p) => canFindTool(jsStr(p['id']), jsStr(id))).firstOrNull,
        CollectionType.workflow => workflowTools?.where((p) => p['id'] == id).firstOrNull,
        _ => customTools?.where((p) => p['id'] == id).firstOrNull,
      };
    default:
      final type = jsStr(data['type']) ?? '';
      return (author: NodeMeta.author, description: NodeMeta.descriptionOf(type));
  }
  return (author: jsStr(provider?['author']), description: jsStr(jsGet(provider?['description'], lang)));
}

/// [nodeMetaDataOf] with the store's tool collections.
({String? author, String? description}) nodeMetaDataIn(WorkflowStore store, DifyJson data) => nodeMetaDataOf(
  data,
  buildInTools: store.buildInTools.value,
  customTools: store.customTools.value,
  workflowTools: store.workflowTools.value,
);
