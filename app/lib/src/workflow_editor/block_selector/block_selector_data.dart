/// What the block selector shows and what it needs from the app (block-selector/types.ts, hooks.ts, utils.ts,
/// tool-list-data.ts): its tabs, the tool, trigger, data source, marketplace, snippet and agent lists the host
/// provides (empty by default, as before they load), and the pure list logic Dify runs on them.
library;

import 'package:flutter/widgets.dart';

import '../../i18n/dify_i18n.dart';
import '../../workflow/model_catalog.dart' show I18nText, languageOfLocale, renderI18nObject;
import '../store/workflow_store.dart' show DifyJson;
import 'block_defaults.dart';
import 'pinyin_initials.g.dart';

/// TabType, in the order the tab bar lists them.
enum BlockSelectorTab { blocks, tools, sources, start, snippets }

/// ToolType: the Tools tab's provider filter.
enum ToolType {
  all('all'),
  builtIn('built-in'),
  custom('custom'),
  workflow('workflow'),
  mcp('mcp');

  const ToolType(this.key);
  final String key;
}

/// ViewType: providers A to Z, or grouped by author / category.
enum ViewType { flat, tree }

/// What the flow is (FlowType): an app's workflow or chatflow, a RAG pipeline, or a snippet.
enum BlockSelectorFlow { app, ragPipeline, snippet }

/// CollectionType.
abstract final class CollectionType {
  static const builtIn = 'builtin';
  static const custom = 'api';
  static const workflow = 'workflow';
  static const mcp = 'mcp';
  static const trigger = 'trigger';
}

/// PluginCategoryEnum values the selector searches the marketplace in.
abstract final class PluginCategory {
  static const tool = 'tool';
  static const trigger = 'trigger';
  static const datasource = 'datasource';
}

/// One tab of the bar (useTabs).
class BlockSelectorTabConfig {
  const BlockSelectorTabConfig(this.tab, this.name, {this.disabled = false, this.disabledTip});
  final BlockSelectorTab tab;
  final String name;
  final bool disabled;
  final String? disabledTip;
}

String _wf(String key) => DifyI18n.tr('workflow', key);

/// useTabs: the tabs to show, in order, and the one to open on ([defaultActiveTab] when shown and enabled, else the
/// first enabled one). The Start tab is disabled in a snippet ([disableStartTab]) or, unless [forceEnableStartTab],
/// while an unconfigured start placeholder is on the canvas.
({List<BlockSelectorTabConfig> tabs, BlockSelectorTab initialTab}) blockSelectorTabs({
  bool noBlocks = false,
  bool noSources = false,
  bool noTools = false,
  bool noSnippets = false,
  bool noStart = true,
  BlockSelectorTab? defaultActiveTab,
  bool hasStartPlaceholderNode = false,
  bool disableStartTab = false,
  bool forceEnableStartTab = false,
}) {
  final startDisabled = disableStartTab || (!forceEnableStartTab && hasStartPlaceholderNode);
  final startTip = disableStartTab
      ? _wf('tabs.startNotSupportedTip')
      : hasStartPlaceholderNode
      ? _wf('tabs.unconfiguredStartDisabledTip')
      : _wf('tabs.startDisabledTip');
  final tabs = [
    if (!noBlocks) BlockSelectorTabConfig(BlockSelectorTab.blocks, _wf('tabs.blocks')),
    if (!noTools) BlockSelectorTabConfig(BlockSelectorTab.tools, _wf('tabs.tools')),
    if (!noSources) BlockSelectorTabConfig(BlockSelectorTab.sources, _wf('tabs.sources')),
    if (!noStart)
      BlockSelectorTabConfig(
        BlockSelectorTab.start,
        _wf('tabs.start'),
        disabled: startDisabled,
        disabledTip: startDisabled ? startTip : null,
      ),
    if (!noSnippets) BlockSelectorTabConfig(BlockSelectorTab.snippets, _wf('tabs.snippets')),
  ];
  BlockSelectorTab? valid(BlockSelectorTab? t) {
    final c = tabs.where((c) => c.tab == t).firstOrNull;
    return c == null || c.disabled ? null : c.tab;
  }

  final initial = valid(defaultActiveTab) ?? tabs.where((t) => !t.disabled).firstOrNull?.tab ?? BlockSelectorTab.blocks;
  return (tabs: tabs, initialTab: initial);
}

/// useToolTabs: All, Tool Plugin, Swagger API, Workflow, then MCP unless [hideMcp].
List<({ToolType type, String name})> toolTabs({bool hideMcp = false}) => [
  (type: ToolType.all, name: _wf('tabs.allTool')),
  (type: ToolType.builtIn, name: _wf('tabs.plugin')),
  (type: ToolType.custom, name: _wf('tabs.customTool')),
  (type: ToolType.workflow, name: _wf('tabs.workflowTool')),
  if (!hideMcp) (type: ToolType.mcp, name: 'MCP'),
];

// ---- data the host provides ---------------------------------------------------------------------------------

/// The language plugin texts are shown in (useGetLanguage: `en_US`, `zh_Hans`, …).
String get pluginLanguage => switch (DifyI18n.current) {
  DifyI18n(:final language) => languageOfLocale(language),
  _ => 'en_US',
};

/// getLocalizedText: the text in [pluginLanguage], else English, else the first one.
String localized(I18nText? text) => renderI18nObject(text, pluginLanguage);

I18nText _i18n(Object? v) => v is Map ? {for (final e in v.entries) '${e.key}': e.value?.toString()} : {};

/// A provider's icon: a URL (string) or an emoji tile (`{content, background}`).
typedef ProviderIcon = Object?;

/// A tool of a provider, or an event of a trigger provider (tools/types.ts Tool / Event).
class ToolAction {
  const ToolAction({
    required this.name,
    this.label = const {},
    this.description = const {},
    this.parameters = const [],
    this.outputSchema,
  });

  factory ToolAction.fromJson(DifyJson j) => ToolAction(
    name: '${j['name'] ?? ''}',
    label: _i18n(j['label']),
    description: _i18n(j['description']),
    parameters: [
      for (final p in (j['parameters'] as List?) ?? const [])
        if (p is Map) p.cast<String, Object?>(),
    ],
    outputSchema: (j['output_schema'] as Map?)?.cast<String, Object?>(),
  );

  final String name;
  final I18nText label, description;
  final List<DifyJson> parameters;
  final DifyJson? outputSchema;

  /// The parameters' default values: each one empty.
  DifyJson get emptyParams => {for (final p in parameters) '${p['name']}': ''};
}

/// A tool, trigger or data source provider (ToolWithProvider / TriggerWithProvider).
class ToolProvider {
  const ToolProvider({
    required this.id,
    required this.name,
    this.author = '',
    this.label = const {},
    this.type = CollectionType.builtIn,
    this.icon,
    this.iconDark,
    this.pluginId,
    this.pluginUniqueIdentifier,
    this.isTeamAuthorization = false,
    this.meta,
    this.tools = const [],
  });

  /// Dify's provider JSON (the console's tool or trigger provider lists, or [transformDataSourceToTool]'s); a
  /// trigger provider's `events` are its [tools].
  factory ToolProvider.fromJson(DifyJson j) => ToolProvider(
    id: '${j['id'] ?? ''}',
    name: '${j['name'] ?? ''}',
    author: '${j['author'] ?? ''}',
    label: _i18n(j['label']),
    type: '${j['type'] ?? CollectionType.builtIn}',
    icon: j['icon'],
    iconDark: j['icon_dark'],
    pluginId: j['plugin_id'] as String?,
    pluginUniqueIdentifier: j['plugin_unique_identifier'] as String?,
    isTeamAuthorization: j['is_team_authorization'] == true,
    meta: (j['meta'] as Map?)?.cast<String, Object?>(),
    tools: [
      for (final t in (j['tools'] as List?) ?? (j['events'] as List?) ?? const [])
        if (t is Map) ToolAction.fromJson(t.cast<String, Object?>()),
    ],
  );

  final String id, name, author;
  final I18nText label;
  final String type;
  final ProviderIcon icon, iconDark;
  final String? pluginId, pluginUniqueIdentifier;
  final bool isTeamAuthorization;
  final DifyJson? meta;
  final List<ToolAction> tools;

  ToolProvider withTools(List<ToolAction> t) => ToolProvider(
    id: id,
    name: name,
    author: author,
    label: label,
    type: type,
    icon: icon,
    iconDark: iconDark,
    pluginId: pluginId,
    pluginUniqueIdentifier: pluginUniqueIdentifier,
    isTeamAuthorization: isTeamAuthorization,
    meta: meta,
    tools: t,
  );
}

/// The ToolDefaultValue a tool row selects (tool/action-item.tsx).
DifyJson toolDefaultValueOf(ToolProvider p, ToolAction t) => {
  'provider_id': p.id,
  'provider_type': p.type,
  'provider_name': p.name,
  'provider_show_name': localized(p.label),
  'plugin_id': ?p.pluginId,
  'plugin_unique_identifier': ?p.pluginUniqueIdentifier,
  'provider_icon': ?p.icon,
  'provider_icon_dark': ?p.iconDark,
  'tool_name': t.name,
  'tool_label': localized(t.label),
  'tool_description': localized(t.description),
  'title': localized(t.label),
  'is_team_authorization': p.isTeamAuthorization,
  'paramSchemas': t.parameters,
  'params': t.emptyParams,
  'meta': ?p.meta,
};

/// The TriggerDefaultValue a trigger event row selects (trigger-plugin/action-item.tsx).
DifyJson triggerDefaultValueOf(ToolProvider p, ToolAction e) => {
  'plugin_id': ?p.pluginId,
  'provider_id': p.name,
  'provider_type': p.type,
  'provider_name': p.name,
  'event_name': e.name,
  'event_label': localized(e.label),
  'event_description': localized(e.description),
  'plugin_unique_identifier': ?p.pluginUniqueIdentifier,
  'title': localized(e.label),
  'is_team_authorization': p.isTeamAuthorization,
  'output_schema': e.outputSchema ?? const <String, Object?>{},
  'paramSchemas': e.parameters,
  'params': e.emptyParams,
  'meta': ?p.meta,
};

/// utils.ts transformDataSourceToTool: a data source plugin (`DataSourceItem`) as a provider JSON.
DifyJson transformDataSourceToTool(DifyJson item) {
  final declaration = (item['declaration'] as Map?)?.cast<String, Object?>() ?? const {};
  final identity = (declaration['identity'] as Map?)?.cast<String, Object?>() ?? const {};
  return {
    'id': item['plugin_id'],
    'provider': item['provider'],
    'name': item['provider'],
    'author': identity['author'],
    'description': identity['description'],
    'icon': identity['icon'],
    'label': identity['label'],
    'type': declaration['provider_type'],
    'team_credentials': <String, Object?>{},
    'allow_delete': true,
    'is_team_authorization': item['is_authorized'],
    'is_authorized': item['is_authorized'],
    'labels': identity['tags'] ?? const <Object?>[],
    'plugin_id': item['plugin_id'],
    'plugin_unique_identifier': item['plugin_unique_identifier'],
    'tools': [
      for (final d in (declaration['datasources'] as List?) ?? const [])
        if (d is Map)
          {
            'name': (d['identity'] as Map?)?['name'],
            'author': (d['identity'] as Map?)?['author'],
            'label': (d['identity'] as Map?)?['label'],
            'description': d['description'],
            'parameters': d['parameters'],
            'labels': const <Object?>[],
            'output_schema': d['output_schema'],
          },
    ],
    'credentialsSchema': declaration['credentials_schema'] ?? const <Object?>[],
    'meta': {'version': ''},
  };
}

/// A marketplace plugin (plugins/types.ts Plugin, the fields the selector shows).
class MarketplacePlugin {
  const MarketplacePlugin({
    required this.pluginId,
    required this.org,
    required this.name,
    this.label = const {},
    this.brief = const {},
    this.icon,
    this.installCount = 0,
    this.latestVersion = '',
    this.latestPackageIdentifier = '',
  });

  factory MarketplacePlugin.fromJson(DifyJson j) => MarketplacePlugin(
    pluginId: '${j['plugin_id'] ?? ''}',
    org: '${j['org'] ?? ''}',
    name: '${j['name'] ?? ''}',
    label: _i18n(j['label']),
    brief: j['brief'] is String ? {'en_US': j['brief'] as String} : _i18n(j['brief']),
    icon: j['icon'] as String?,
    installCount: (j['install_count'] as num?)?.toInt() ?? 0,
    latestVersion: '${j['latest_version'] ?? ''}',
    latestPackageIdentifier: '${j['latest_package_identifier'] ?? ''}',
  );

  final String pluginId, org, name;
  final I18nText label, brief;
  final String? icon;
  final int installCount;
  final String latestVersion, latestPackageIdentifier;
}

/// A marketplace search: the trimmed search text, the tags and the plugin category.
typedef MarketplaceQuery = ({String query, List<String> tags, String category});

/// An Agent v2 roster agent (AgentInviteOptionResponse, the fields the selector shows).
class AgentOption {
  const AgentOption({
    required this.id,
    required this.name,
    this.role,
    this.description,
    this.icon,
    this.iconBackground,
    this.iconType,
    this.activeConfigSnapshotId,
  });

  factory AgentOption.fromJson(DifyJson j) => AgentOption(
    id: '${j['id']}',
    name: '${j['name'] ?? ''}',
    role: j['role'] as String?,
    description: j['description'] as String?,
    icon: j['icon'] as String?,
    iconBackground: j['icon_background'] as String?,
    iconType: j['icon_type'] as String?,
    activeConfigSnapshotId: j['active_config_snapshot_id'] as String?,
  );

  final String id, name;
  final String? role, description, icon, iconBackground, iconType, activeConfigSnapshotId;
}

/// A published snippet (SnippetListItem) and the block types of its graph (for the preview).
class SnippetItem {
  const SnippetItem({
    required this.id,
    required this.name,
    this.description = '',
    this.authorName,
    this.blockTypes = const [],
  });
  final String id, name, description;
  final String? authorName;
  final List<String> blockTypes;
}

/// A node on the canvas as the selector sees it.
typedef BlockSelectorNode = ({String id, String type});

/// Everything the selector reads from the app, the console API and the marketplace (Dify's stores and queries), and
/// the actions it leaves to the app. All lists are empty and all actions absent by default.
@immutable
class BlockSelectorData {
  const BlockSelectorData({
    this.chatMode = false,
    this.flow = BlockSelectorFlow.app,
    this.agentV2 = false,
    this.nodes = const [],
    this.blocks,
    this.buildInTools = const [],
    this.customTools = const [],
    this.workflowTools = const [],
    this.mcpTools = const [],
    this.triggerPlugins = const [],
    this.dataSources = const [],
    this.enableMarketplace = false,
    this.featuredTools = const [],
    this.featuredToolsLoading = false,
    this.featuredTriggers = const [],
    this.featuredTriggersLoading = false,
    this.searchMarketplace,
    this.canInstallPlugin = false,
    this.onInstallPlugin,
    this.onDownloadPlugin,
    this.searchSnippets,
    this.onInsertSnippet,
    this.searchAgents,
    this.mcpToolAllowed = true,
    this.openUrl,
    this.onError,
    this.iconBuilder,
    this.marketplaceUrlPrefix = 'https://marketplace.dify.ai',
    this.marketplaceSource,
  });

  final bool chatMode;
  final BlockSelectorFlow flow;

  /// NEXT_PUBLIC_ENABLE_AGENT_V2 (with NEXT_PUBLIC_ENABLE_AGENT_V2_IN_CHATFLOW in a chatflow).
  final bool agentV2;

  /// The nodes on the canvas (for the Start tab's conflicts and singleton blocks).
  final List<BlockSelectorNode> nodes;

  /// The blocks of the Nodes tab; null for the app's own ([availableBlocks] of [chatMode] and [agentV2]).
  final List<BlockMeta>? blocks;

  /// Installed providers (useAllBuiltInTools / useAllCustomTools / useAllWorkflowTools / useAllMCPTools /
  /// useAllTriggerPlugins) and the RAG pipeline's data sources.
  final List<ToolProvider> buildInTools, customTools, workflowTools, mcpTools, triggerPlugins, dataSources;

  /// systemFeatures.enable_marketplace.
  final bool enableMarketplace;

  /// The marketplace's featured tools and triggers (useFeaturedToolsRecommendations / ...TriggersRecommendations).
  final List<MarketplacePlugin> featuredTools, featuredTriggers;
  final bool featuredToolsLoading, featuredTriggersLoading;

  /// useMarketplacePlugins: the plugins not installed that match a search (asked 500 ms after typing stops).
  final Future<List<MarketplacePlugin>> Function(MarketplaceQuery query)? searchMarketplace;

  /// useWorkspacePluginInstallPermission; [onInstallPlugin] shows InstallFromMarketplace and completes with
  /// whether the plugin got installed (the app then refreshes its provider lists).
  final bool canInstallPlugin;
  final Future<bool> Function(MarketplacePlugin plugin)? onInstallPlugin;

  /// The marketplace item menu's Download (the package `<org>-<name>_<version>.zip`); a second Download waits for it.
  final Future<void> Function(MarketplacePlugin plugin)? onDownloadPlugin;

  /// useInfiniteSnippetList (published snippets matching a keyword); null hides the Snippets tab.
  final Future<List<SnippetItem>> Function(String keyword)? searchSnippets;

  /// useInsertSnippet: inserts the snippet's graph (at [payload]'s handles, else the viewport's centre); completes
  /// with whether it was inserted.
  final Future<bool> Function(SnippetItem snippet, DifyJson? payload)? onInsertSnippet;

  /// The Agent v2 roster (`/agent/invite-options`, 8 per page) matching a keyword.
  final Future<List<AgentOption>> Function(String keyword)? searchAgents;

  /// useMCPToolAvailability.
  final bool mcpToolAllowed;

  /// Opens a link (absolute, or a console path such as `/integrations/tools/api`) in a new tab.
  final void Function(String url)? openUrl;

  /// toast.error.
  final void Function(String message)? onError;

  /// Draws a provider [icon] (a URL or an emoji tile) at [size]; null shows the block's own icon.
  final Widget Function(BuildContext context, ProviderIcon icon, double size)? iconBuilder;

  /// MARKETPLACE_URL_PREFIX and the console's origin (`source`).
  final String marketplaceUrlPrefix;
  final String? marketplaceSource;

  /// getMarketplaceUrl.
  String marketplaceUrl(String path, [Map<String, String?> params = const {}]) {
    final q = {'source': ?marketplaceSource, for (final e in params.entries) e.key: ?e.value};
    return q.isEmpty ? '$marketplaceUrlPrefix$path' : '$marketplaceUrlPrefix$path?${Uri(queryParameters: q).query}';
  }

  /// getMarketplaceCategoryUrl.
  String marketplaceCategoryUrl(String? category, [Map<String, String?> params = const {}]) =>
      marketplaceUrl(category == null ? '/plugins' : '/plugins/$category', params);

  void open(String url) => openUrl?.call(url);
}

/// Provides the [BlockSelectorData] of the editor to the block selectors below it.
class BlockSelectorScope extends InheritedWidget {
  const BlockSelectorScope({super.key, required this.data, required super.child});

  final BlockSelectorData data;

  static BlockSelectorData of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<BlockSelectorScope>()?.data ?? const BlockSelectorData();

  @override
  bool updateShouldNotify(BlockSelectorScope old) => old.data != data;
}

/// The plugin request issue Dify links to when nothing matches.
const pluginRequestUrl = 'https://github.com/langgenius/dify-plugins/issues/new?template=plugin_request.yaml';

/// integrations/routes.ts integrationPathBySection (the console paths the tool empty states link to).
const integrationCustomToolPath = '/integrations/tools/api';
const integrationWorkflowToolPath = '/integrations/tools/workflow';
const integrationMcpPath = '/integrations/tools/mcp';

// ---- tool-list-data.ts ------------------------------------------------------------------------------------------

/// A tree-view group: providers of an [author], or of a category (`custom`, `workflow`, `data-source`, `mcp`).
class ToolGroup {
  ToolGroup.author(String this.author, this.tools) : category = null;
  ToolGroup.category(String this.category, this.tools) : author = null;
  final String? author, category;
  final List<ToolProvider> tools;
}

/// A provider of the flat view under its index [letter].
typedef LetteredTool = ({ToolProvider tool, String letter});

Map<int, String>? _pinyin;

/// The pinyin initial of a hanzi (pinyin-pro `pattern: 'first'`), for the GB2312 level-1 characters.
String? pinyinInitial(String char) {
  final m = _pinyin ??= {
    for (final e in pinyinInitialGroups.entries)
      for (final c in e.value.runes) c: e.key,
  };
  return char.isEmpty ? null : m[char.runes.first];
}

String _normalizeLetter(String firstChar) {
  final cjk = RegExp(r'[一-龥]').hasMatch(firstChar);
  final letter = ((cjk ? pinyinInitial(firstChar) : null) ?? firstChar).toUpperCase();
  return RegExp(r'^[A-Z]$').hasMatch(letter) ? letter : '#';
}

String? _categoryOf(String type) => switch (type) {
  CollectionType.custom => 'custom',
  CollectionType.workflow => 'workflow',
  'local_file' || 'online_document' || 'online_drive' || 'website_crawl' => 'data-source',
  CollectionType.mcp => 'mcp',
  _ => null,
};

/// createToolListData: the providers bucketed by the index letter of [firstChar] (A to Z, then `#`): the [letters],
/// the providers A to Z for the flat view (within a letter, grouped by author / category in first-seen order), and
/// the tree view's groups (merged across letters, in first-seen order).
({List<String> letters, List<LetteredTool> flatTools, List<ToolGroup> treeGroups}) createToolListData(
  List<ToolProvider> tools,
  String Function(ToolProvider tool) firstChar,
) {
  final buckets = <String, List<ToolGroup>>{};
  for (final tool in tools) {
    final c = firstChar(tool);
    if (c.isEmpty) continue;
    final groups = buckets.putIfAbsent(_normalizeLetter(c), () => []);
    final category = _categoryOf(tool.type);
    final group = groups
        .where((g) => category == null ? g.author == tool.author && g.category == null : g.category == category)
        .firstOrNull;
    if (group != null) {
      group.tools.add(tool);
    } else {
      groups.add(category == null ? ToolGroup.author(tool.author, [tool]) : ToolGroup.category(category, [tool]));
    }
  }
  final sorted = buckets.entries.toList()
    ..sort((a, b) {
      if (a.key == '#') return 1;
      if (b.key == '#') return -1;
      return a.key.compareTo(b.key);
    });
  final tree = <ToolGroup>[];
  for (final g in buckets.values.expand((gs) => gs)) {
    final same = tree.where((t) => t.author == g.author && t.category == g.category).firstOrNull;
    if (same != null) {
      same.tools.addAll(g.tools);
    } else {
      tree.add(
        g.author != null ? ToolGroup.author(g.author!, [...g.tools]) : ToolGroup.category(g.category!, [...g.tools]),
      );
    }
  }
  return (
    letters: [for (final e in sorted) e.key],
    flatTools: [
      for (final e in sorted)
        for (final g in e.value)
          for (final t in g.tools) (tool: t, letter: e.key),
    ],
    treeGroups: tree,
  );
}

/// The index letter source of a provider (tools.tsx): its localized label's first character, else its name's.
String toolFirstChar(ToolProvider tool) {
  final label = localized(tool.label);
  final s = label.isNotEmpty ? label : tool.name;
  return s.isEmpty ? '#' : String.fromCharCode(s.runes.first);
}
