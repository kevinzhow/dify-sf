/// hooks/use-tool-icon.ts: the provider icon of a tool, trigger plugin or data source node (its collection's icon,
/// else the icon the node was created with), in the light or dark theme.
library;

import '../../workflow/dify_json.dart';
import '../node_panel/bodies/data/tool/tool_model.dart' show CollectionType, canFindTool;
import '../store/store.dart';

/// `ToolIconCollections`: the tool providers by kind (`ToolWithProvider` JSON: `id`, `name`, `plugin_id`, `icon`,
/// `icon_dark`).
typedef ToolIconCollections = ({
  List<DifyJson>? buildInTools,
  List<DifyJson>? customTools,
  List<DifyJson>? workflowTools,
  List<DifyJson>? mcpTools,
});

const ToolIconCollections noToolIconCollections = (
  buildInTools: null,
  customTools: null,
  workflowTools: null,
  mcpTools: null,
);

Object? _byTheme(String? theme, Object? icon, Object? iconDark) =>
    theme == 'dark' && jsTruthy(iconDark) ? iconDark : icon;

Object? _triggerIcon(List<String?> identifiers, List<DifyJson>? triggers, String? theme) {
  for (final id in identifiers) {
    if (id == null || id.isEmpty) continue;
    final matched = (triggers ?? const <DifyJson>[])
        .where((t) => t['id'] == id || canFindTool(jsStr(t['id']), id))
        .firstOrNull;
    if (matched != null) return _byTheme(theme, matched['icon'], matched['icon_dark']);
  }
  return null;
}

List<DifyJson>? _primary(String? providerType, ToolIconCollections c) => switch (providerType) {
  CollectionType.custom => c.customTools,
  CollectionType.mcp => c.mcpTools,
  CollectionType.workflow => c.workflowTools,
  _ => c.buildInTools,
};

Object? _toolIcon(DifyJson data, ToolIconCollections c, String? theme) {
  final seen = <List<DifyJson>>{};
  for (final collection in [
    _primary(jsStr(data['provider_type']), c),
    c.buildInTools,
    c.customTools,
    c.workflowTools,
    c.mcpTools,
  ]) {
    if (collection == null || !seen.add(collection)) continue;
    final matched = collection.where((p) {
      if (canFindTool(jsStr(p['id']), jsStr(data['provider_id']))) return true;
      if (jsTruthy(data['plugin_id']) && p['plugin_id'] == data['plugin_id']) return true;
      return data['provider_name'] == p['name'];
    }).firstOrNull;
    if (matched != null) {
      final icon = _byTheme(theme, matched['icon'], matched['icon_dark']);
      if (jsTruthy(icon)) return icon;
      break;
    }
  }
  return _byTheme(theme, data['provider_icon'], data['provider_icon_dark']);
}

/// `findNodeIcon`: the icon of a node's [data] (null for other node types or no match).
Object? findNodeIcon(
  DifyJson? data, {
  ToolIconCollections collections = noToolIconCollections,
  List<DifyJson>? dataSourceList,
  List<DifyJson>? triggerPlugins,
  String? theme,
}) {
  if (data == null) return null;
  switch (data['type']) {
    case 'trigger-plugin':
      return _triggerIcon(
        [jsStr(data['plugin_id']), jsStr(data['provider_id']), jsStr(data['provider_name'])],
        triggerPlugins,
        theme,
      );
    case 'tool':
      return _toolIcon(data, collections, theme);
    case 'datasource':
      return dataSourceList?.where((d) => d['plugin_id'] == data['plugin_id']).firstOrNull?['icon'];
    default:
      return null;
  }
}

/// `useToolIcon(data)`: [findNodeIcon], `''` when there is none.
Object toolIconOf(
  DifyJson? data, {
  ToolIconCollections collections = noToolIconCollections,
  List<DifyJson>? dataSourceList,
  List<DifyJson>? triggerPlugins,
  String? theme,
}) =>
    findNodeIcon(
      data,
      collections: collections,
      dataSourceList: dataSourceList,
      triggerPlugins: triggerPlugins,
      theme: theme,
    ) ??
    '';

/// `useGetToolIcon()`: [findNodeIcon] with the store's tool collections where it has them, else [collections] (the
/// queried ones).
Object? Function(DifyJson data) getToolIcon(
  WorkflowStore store, {
  ToolIconCollections collections = noToolIconCollections,
  List<DifyJson>? dataSourceList,
  List<DifyJson>? triggerPlugins,
  String? theme,
}) =>
    (data) => findNodeIcon(
      data,
      collections: (
        buildInTools: store.buildInTools.value ?? collections.buildInTools,
        customTools: store.customTools.value ?? collections.customTools,
        workflowTools: store.workflowTools.value ?? collections.workflowTools,
        mcpTools: store.mcpTools.value ?? collections.mcpTools,
      ),
      dataSourceList: dataSourceList,
      triggerPlugins: triggerPlugins,
      theme: theme,
    );
