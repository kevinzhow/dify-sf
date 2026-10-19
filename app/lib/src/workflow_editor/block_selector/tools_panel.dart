/// The Tools and Sources tabs (tool-panel.tsx, tool-browser.tsx, tools.tsx, tool/**, index-bar.tsx,
/// view-type-select.tsx, featured-tools.tsx, data-sources.tsx) and the marketplace rows they end with
/// (marketplace-plugin/**).
library;

import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';

import '../../design/css_metrics.dart';
import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../i18n/dify_i18n.dart';
import '../store/workflow_store.dart' show DifyJson;
import 'block_selector.dart' show OnSelectBlock;
import 'block_selector_data.dart';
import 'selector_widgets.dart';

String _tools(String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr('tools', key, params);
String _plugin(String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr('plugin', key, params);

/// formatNumber: thousands separated by commas.
String formatInstallCount(int n) => n.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');

/// ToolPanel: the Tools tab's browser over the app's installed providers, with the marketplace's featured tools
/// (not in a RAG pipeline).
class ToolPanel extends StatelessWidget {
  const ToolPanel({
    super.key,
    required this.searchText,
    required this.tags,
    required this.onTagsChange,
    required this.onSelect,
    this.inRagPipeline = false,
  });

  final String searchText;
  final List<String> tags;
  final ValueChanged<List<String>> onTagsChange;
  final OnSelectBlock onSelect;
  final bool inRagPipeline;

  @override
  Widget build(BuildContext context) {
    final d = BlockSelectorScope.of(context);
    return ToolBrowser(
      searchText: searchText,
      tags: tags,
      onTagsChange: onTagsChange,
      onSelect: onSelect,
      canNotSelectMultiple: true,
      buildInTools: d.buildInTools,
      customTools: d.customTools,
      workflowTools: d.workflowTools,
      mcpTools: d.mcpTools,
      isInRagPipeline: inRagPipeline,
      featuredPlugins: d.featuredTools,
      featuredLoading: d.featuredToolsLoading,
      showFeatured: d.enableMarketplace && !inRagPipeline,
    );
  }
}

/// ToolBrowser: the provider filter (All / Tool Plugin / Swagger API / Workflow / MCP; `h-6 rounded-md px-2 text-xs
/// font-medium`, the active one on `bg-state-base-hover-alt`), the list / tree switch (All and Tool Plugin), then in
/// `max-h-116`: Featured (All, no filter), the list title, the providers, the category's empty state, the
/// marketplace's matches, "No integrations were found" when a search finds nothing anywhere, and the "Find more in
/// Marketplace" footer while not searching.
class ToolBrowser extends StatefulWidget {
  const ToolBrowser({
    super.key,
    required this.searchText,
    this.tags = const [],
    required this.onSelect,
    this.canNotSelectMultiple = false,
    this.onSelectMultiple,
    this.buildInTools = const [],
    this.customTools = const [],
    this.workflowTools = const [],
    this.mcpTools = const [],
    this.selectedTools,
    this.onTagsChange,
    this.isInRagPipeline = false,
    this.featuredPlugins = const [],
    this.featuredLoading = false,
    this.showFeatured = false,
  });

  final String searchText;
  final List<String> tags;
  final OnSelectBlock onSelect;
  final bool canNotSelectMultiple;
  final void Function(String type, List<DifyJson> tools)? onSelectMultiple;
  final List<ToolProvider> buildInTools, customTools, workflowTools, mcpTools;

  /// The tools already added (ToolValue: `provider_name`, `tool_name`).
  final List<DifyJson>? selectedTools;
  final ValueChanged<List<String>>? onTagsChange;
  final bool isInRagPipeline;
  final List<MarketplacePlugin> featuredPlugins;
  final bool featuredLoading, showFeatured;

  @override
  State<ToolBrowser> createState() => _ToolBrowserState();
}

bool _matches(String text, String keywords) => text.toLowerCase().contains(keywords.toLowerCase());

class _ToolBrowserState extends State<ToolBrowser> {
  ToolType _tab = ToolType.all;
  ViewType _view = ViewType.flat;
  late final _market = MarketplaceSearch(null)..addListener(_changed);

  void _changed() => mounted ? setState(() {}) : null;

  @override
  void dispose() {
    _market.dispose();
    super.dispose();
  }

  List<ToolProvider> get _all => [
    ...widget.buildInTools,
    ...widget.customTools,
    ...widget.workflowTools,
    ...widget.mcpTools,
  ];

  List<ToolProvider> _filtered(String search, bool hasFilter) {
    final w = widget;
    final merged = switch (_tab) {
      ToolType.all => _all,
      ToolType.builtIn => w.buildInTools,
      ToolType.custom => w.customTools,
      ToolType.workflow => w.workflowTools,
      ToolType.mcp => w.mcpTools,
    };
    final needle = search.toLowerCase();
    if (!hasFilter || needle.isEmpty) {
      return [
        for (final p in merged)
          if (p.tools.isNotEmpty) p,
      ];
    }
    final out = <ToolProvider>[];
    for (final p in merged) {
      if ([p.name, localized(p.label)].any((t) => _matches(t, needle))) {
        if (p.tools.isNotEmpty) out.add(p);
        continue;
      }
      final tools = [
        for (final t in p.tools)
          if (_matches(t.name, needle) || _matches(localized(t.label), needle)) t,
      ];
      if (tools.isNotEmpty) out.add(p.withTools(tools));
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final w = widget, d = BlockSelectorScope.of(context);
    final search = w.searchText.trim();
    final hasSearch = search.isNotEmpty, hasFilter = hasSearch || w.tags.isNotEmpty;
    final marketplace = d.enableMarketplace;
    _market.update(
      marketplace && hasFilter ? (query: search, tags: w.tags, category: PluginCategory.tool) : null,
      d.searchMarketplace,
    );
    final tools = _filtered(search, hasFilter);
    final groupView = _tab == ToolType.all || _tab == ToolType.builtIn;
    final view = groupView ? _view : ViewType.flat;
    final hasList = tools.isNotEmpty;
    final hasPlugins = marketplace && _market.plugins.isNotEmpty;
    final pending = marketplace && hasFilter && _market.pending;
    final empty = hasFilter && !pending && !hasList && !hasPlugins;
    final categoryEmpty = !hasFilter && _tab != ToolType.all && !hasList;
    final featured = w.showFeatured && marketplace && !w.isInRagPipeline && _tab == ToolType.all && !hasFilter;
    final providerMap = {for (final p in _all) (p.pluginId ?? p.id): p};
    final title = switch (_tab) {
      ToolType.builtIn => _tools('allToolPlugins'),
      ToolType.custom => _tools('allSwaggerAPIAsTool'),
      ToolType.workflow => _tools('allWorkflowAsTool'),
      ToolType.mcp => _tools('allMCP'),
      ToolType.all => _tools('allTools'),
    };
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 500),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: DifyColors.dividerSubtle)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: UnconstrainedBox(
                    constrainedAxis: Axis.vertical,
                    alignment: Alignment.centerLeft,
                    clipBehavior: Clip.hardEdge,
                    child: SizedBox(
                      height: 32,
                      child: Row(
                        spacing: 4,
                        children: [
                          for (final t in toolTabs())
                            Semantics(
                              toggled: _tab == t.type,
                              child: DifyPressable(
                                semanticLabel: t.name,
                                onPressed: () => setState(() => _tab = t.type),
                                builder: (context, hovered, focused) => Container(
                                  height: 24,
                                  padding: const EdgeInsets.symmetric(horizontal: 8),
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    color: _tab == t.type
                                        ? DifyColors.stateBaseHoverAlt
                                        : hovered
                                        ? DifyColors.stateBaseHover
                                        : null,
                                    borderRadius: BorderRadius.circular(DifyRadius.md),
                                  ),
                                  foregroundDecoration: insetFocusRing(focused, DifyRadius.md),
                                  child: DifyText(t.name, DifyType.systemXsMedium, color: DifyColors.textSecondary),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                if (groupView) ViewTypeSelect(viewType: _view, onChange: (v) => setState(() => _view = v)),
              ],
            ),
          ),
          Flexible(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 464),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Flexible(
                    child: MarketplaceScrollArea(
                      children: [
                        if (empty)
                          SelectorEmptyState(title: wf('tabs.noPluginsFound'), action: const RequestToCommunityLink())
                        else ...[
                          if (featured) ...[
                            FeaturedTools(
                              plugins: w.featuredPlugins,
                              providerMap: providerMap,
                              onSelect: w.onSelect,
                              selectedTools: w.selectedTools,
                              isLoading: w.featuredLoading,
                            ),
                            Padding(
                              padding: EdgeInsets.symmetric(horizontal: 12),
                              child: SizedBox(height: 1, child: ColoredBox(color: DifyColors.dividerRegular)),
                            ),
                          ],
                          if (hasList) ...[
                            Padding(
                              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                              child: DifyText(title, DifyType.systemXsMedium, color: DifyColors.textPrimary),
                            ),
                            ToolsList(
                              tools: tools,
                              onSelect: w.onSelect,
                              canNotSelectMultiple: w.canNotSelectMultiple,
                              onSelectMultiple: w.onSelectMultiple,
                              viewType: view,
                              hasSearchText: hasSearch,
                              selectedTools: w.selectedTools,
                            ),
                          ],
                          if (categoryEmpty) _CategoryEmptyState(type: _tab),
                          if (marketplace)
                            MarketplacePluginList(
                              list: _market.plugins,
                              searchText: search,
                              tags: w.tags,
                              category: PluginCategory.tool,
                              hideFindMoreFooter: true,
                            ),
                        ],
                      ],
                    ),
                  ),
                  if (marketplace && !hasFilter) MarketplaceFooter(url: d.marketplaceCategoryUrl(PluginCategory.tool)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// ToolCategoryEmptyState: `addToolModal.<type>.title`, with a link to create one (Swagger API, Workflow, MCP).
class _CategoryEmptyState extends StatelessWidget {
  const _CategoryEmptyState({required this.type});
  final ToolType type;

  @override
  Widget build(BuildContext context) {
    final tip = _tools('addToolModal.${type.key}.tip');
    final href = switch (type) {
      ToolType.custom => integrationCustomToolPath,
      ToolType.workflow => integrationWorkflowToolPath,
      ToolType.mcp => integrationMcpPath,
      _ => null,
    };
    return SelectorEmptyState(
      title: _tools('addToolModal.${type.key}.title'),
      action: href == null || tip.isEmpty
          ? null
          : SelectorLink(
              url: href,
              label: tip,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                spacing: 2,
                children: [
                  DifyText(tip, DifyType.systemXsRegular, color: DifyColors.textTertiary),
                  RemixIcon('arrow-right-up-line', size: 12, color: DifyColors.textTertiary),
                ],
              ),
            ),
    );
  }
}

/// Tools: the providers (`p-1`), A to Z with the letter index once there are more than 10 (flat), or grouped (tree);
/// tools/provider/empty's "No tools available" when there are none and no search.
class ToolsList extends StatefulWidget {
  const ToolsList({
    super.key,
    required this.tools,
    required this.onSelect,
    this.canNotSelectMultiple = false,
    this.onSelectMultiple,
    this.viewType = ViewType.flat,
    this.hasSearchText = false,
    this.selectedTools,
    this.padding = const EdgeInsets.all(4),
  });

  final List<ToolProvider> tools;
  final OnSelectBlock onSelect;
  final bool canNotSelectMultiple;
  final void Function(String type, List<DifyJson> tools)? onSelectMultiple;
  final ViewType viewType;
  final bool hasSearchText;
  final List<DifyJson>? selectedTools;
  final EdgeInsets padding;

  @override
  State<ToolsList> createState() => _ToolsListState();
}

class _ToolsListState extends State<ToolsList> {
  final _letterKeys = <String, GlobalKey>{};

  @override
  Widget build(BuildContext context) {
    final w = widget;
    if (w.tools.isEmpty) {
      return w.hasSearchText
          ? const SizedBox.shrink()
          : const Padding(padding: EdgeInsets.symmetric(vertical: 40), child: _NoTools());
    }
    final data = createToolListData(w.tools, toolFirstChar);
    Widget row(ToolProvider p, ViewType view) => ToolProviderRow(
      key: ValueKey(p.id),
      provider: p,
      viewType: view,
      hasSearchText: w.hasSearchText,
      onSelect: w.onSelect,
      canNotSelectMultiple: w.canNotSelectMultiple,
      onSelectMultiple: w.onSelectMultiple,
      selectedTools: w.selectedTools,
    );
    final Widget list;
    if (w.viewType == ViewType.flat) {
      final first = <String>{};
      list = Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final t in data.flatTools)
                    first.add(t.letter)
                        ? KeyedSubtree(
                            key: _letterKeys.putIfAbsent(t.letter, GlobalKey.new),
                            child: row(t.tool, ViewType.flat),
                          )
                        : row(t.tool, ViewType.flat),
                ],
              ),
            ),
          ),
          if (w.tools.length > 10) IndexBar(letters: data.letters, itemKeys: _letterKeys),
        ],
      );
    } else {
      list = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final g in data.treeGroups)
            ToolTreeGroup(
              groupName: g.author ?? _categoryName(g.category!),
              children: [for (final p in g.tools) row(p, ViewType.tree)],
            ),
        ],
      );
    }
    return PreviewCardScope(
      child: Padding(padding: w.padding, child: list),
    );
  }
}

String _categoryName(String category) => switch (category) {
  'custom' => wf('tabs.customTool'),
  'workflow' => wf('tabs.workflowTool'),
  'data-source' => wf('tabs.sources'),
  _ => 'MCP',
};

/// tools/provider/empty without a type: NoToolPlaceholder and "No tools available".
class _NoTools extends StatelessWidget {
  const _NoTools();

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      DifyIcon('vender/other/no-tool-placeholder', size: 64),
      SizedBox(height: 8),
      DifyText('No tools available', DifyType.systemSmMedium, color: DifyColors.textPrimary),
      SizedBox(height: 4),
    ],
  );
}

/// The tree view's group (tool-list-tree-view/item.tsx): its name (`h-5.5 px-3 text-xs font-medium
/// text-text-tertiary`) over its providers.
class ToolTreeGroup extends StatelessWidget {
  const ToolTreeGroup({super.key, required this.groupName, required this.children});
  final String groupName;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Container(
        height: 22,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        alignment: Alignment.centerLeft,
        child: DifyText(groupName, DifyType.systemXsMedium, color: DifyColors.textTertiary),
      ),
      ...children,
    ],
  );
}

/// IndexBar: `w-6` letters (`h-4 w-5 text-xs font-medium text-text-quaternary`, hover secondary) centred along a
/// faded 1 px rule; a letter scrolls its first provider into view.
class IndexBar extends StatelessWidget {
  const IndexBar({super.key, required this.letters, required this.itemKeys});
  final List<String> letters;
  final Map<String, GlobalKey> itemKeys;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 24,
    child: DecoratedBox(
      decoration: const BoxDecoration(
        border: Border(left: BorderSide(color: Color(0x14101828), width: 1)),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (final l in letters)
            DifyPressable(
              semanticLabel: l,
              onPressed: () {
                final c = itemKeys[l]?.currentContext;
                if (c != null) {
                  Scrollable.ensureVisible(c, duration: const Duration(milliseconds: 300), curve: Curves.easeInOut);
                }
              },
              builder: (context, hovered, focused) => Container(
                width: 20,
                height: 16,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(DifyRadius.sm),
                  border: focused ? Border.all(color: DifyColors.stateAccentSolid, width: 2) : null,
                ),
                child: DifyText(
                  l,
                  DifyType.systemXsMedium,
                  color: hovered ? DifyColors.textSecondary : DifyColors.textQuaternary,
                ),
              ),
            ),
        ],
      ),
    ),
  );
}

/// ViewTypeSelect: a two-item segmented control (`rounded-lg p-px`, `size-5.5` items) named "View", list
/// (`i-ri-sort-alphabet-asc`) or tree (`i-ri-node-tree`); arrow keys move the choice.
class ViewTypeSelect extends StatefulWidget {
  const ViewTypeSelect({super.key, required this.viewType, required this.onChange});
  final ViewType viewType;
  final ValueChanged<ViewType> onChange;

  @override
  State<ViewTypeSelect> createState() => _ViewTypeSelectState();
}

class _ViewTypeSelectState extends State<ViewTypeSelect> {
  final _focus = {for (final v in ViewType.values) v: FocusNode(debugLabel: 'view ${v.name}')};

  @override
  void dispose() {
    for (final f in _focus.values) {
      f.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final items = [
      (ViewType.flat, wf('tabs.listView'), 'sort-alphabet-asc'),
      (ViewType.tree, wf('tabs.treeView'), 'node-tree'),
    ];
    return Semantics(
      container: true,
      role: SemanticsRole.radioGroup,
      label: DifyI18n.tr('common', 'operation.view'),
      explicitChildNodes: true,
      child: Container(
        padding: const EdgeInsets.all(1),
        decoration: BoxDecoration(
          color: DifyColors.componentsSegmentedControlBgNormal,
          borderRadius: BorderRadius.circular(DifyRadius.lg),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (i, (v, label, icon)) in items.indexed)
              Focus(
                canRequestFocus: false,
                skipTraversal: true,
                onKeyEvent: (node, e) {
                  final fwd = isArrowKey(e, forward: true), back = isArrowKey(e, forward: false);
                  if (!fwd && !back) return KeyEventResult.ignored;
                  // Arrow keys move the focus and the choice with it.
                  final next = items[(i + (fwd ? 1 : -1)) % items.length].$1;
                  _focus[next]!.requestFocus();
                  widget.onChange(next);
                  return KeyEventResult.handled;
                },
                // Roving focus: only the chosen item is in the Tab order.
                child: FocusTraversalGroup(
                  descendantsAreTraversable: v == widget.viewType,
                  child: MergeSemantics(
                    child: Semantics(
                      checked: v == widget.viewType,
                      inMutuallyExclusiveGroup: true,
                      child: DifyPressable(
                        focusNode: _focus[v],
                        semanticLabel: label,
                        onPressed: () => widget.onChange(v),
                        builder: (context, hovered, focused) {
                          final checked = v == widget.viewType;
                          return Container(
                            width: 22,
                            height: 22,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: checked
                                  ? DifyColors.componentsSegmentedControlItemActiveBg
                                  : hovered
                                  ? DifyColors.stateBaseHover
                                  : null,
                              borderRadius: BorderRadius.circular(DifyRadius.lg),
                              boxShadow: checked ? DifyShadows.xs : null,
                            ),
                            foregroundDecoration: insetFocusRing(focused, DifyRadius.lg),
                            child: RemixIcon(
                              icon,
                              size: 16,
                              color: checked ? DifyColors.textAccentLightModeOnly : DifyColors.textTertiary,
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Tool (tool/tool.tsx): a provider row (`h-8 rounded-lg pr-2 pl-3`, BlockIcon with its icon, the name, the author or
/// category in the flat view, the MCP mark, a chevron turning down when open) that opens its tools; open while
/// searching. A workflow tool is selected directly. With [onSelectMultiple] it shows how many are added and an "Add
/// all" button on hover.
class ToolProviderRow extends StatefulWidget {
  const ToolProviderRow({
    super.key,
    required this.provider,
    required this.viewType,
    required this.hasSearchText,
    required this.onSelect,
    this.canNotSelectMultiple = false,
    this.onSelectMultiple,
    this.selectedTools,
  });

  final ToolProvider provider;
  final ViewType viewType;
  final bool hasSearchText;
  final OnSelectBlock onSelect;
  final bool canNotSelectMultiple;
  final void Function(String type, List<DifyJson> tools)? onSelectMultiple;
  final List<DifyJson>? selectedTools;

  @override
  State<ToolProviderRow> createState() => _ToolProviderRowState();
}

class _ToolProviderRowState extends State<ToolProviderRow> {
  late bool _open = widget.hasSearchText;
  bool _hovered = false;

  @override
  void didUpdateWidget(ToolProviderRow old) {
    super.didUpdateWidget(old);
    if (old.hasSearchText != widget.hasSearchText) _open = widget.hasSearchText;
  }

  bool _added(ToolAction t) {
    final s = widget.selectedTools;
    if (s == null || s.isEmpty) return false;
    final p = widget.provider;
    return s.any((x) => (x['provider_name'] == p.name || x['provider_name'] == p.id) && x['tool_name'] == t.name);
  }

  @override
  Widget build(BuildContext context) {
    final w = widget, p = w.provider, d = BlockSelectorScope.of(context);
    final actions = p.tools;
    final workflow = p.type == CollectionType.workflow;
    final mcp = p.type == CollectionType.mcp;
    final mcpBlocked = !d.mcpToolAllowed && mcp;
    final added = actions.where(_added).length;
    final allAdded = added == actions.length;
    final groupName = switch (p.type) {
      CollectionType.builtIn => p.author,
      CollectionType.custom => wf('tabs.customTool'),
      CollectionType.workflow => wf('tabs.workflowTool'),
      _ => '',
    };
    final name = workflow ? localized(actions.firstOrNull?.label) : localized(p.label);
    final details = Opacity(
      opacity: mcpBlocked ? 0.3 : 1,
      child: Row(
        children: [
          SelectorBlockIcon(type: 'tool', toolIcon: p.themedIcon),
          const SizedBox(width: 8),
          Flexible(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 250),
              child: DifyText(name, DifyType.systemSmRegular, color: DifyColors.textPrimary),
            ),
          ),
          if (w.viewType == ViewType.flat && groupName.isNotEmpty) ...[
            const SizedBox(width: 8),
            DifyText(groupName, DifyType.systemXsRegular, color: DifyColors.textQuaternary),
          ],
          if (mcp) ...[
            const SizedBox(width: 8),
            DifyIcon('vender/other/mcp', size: 14, color: DifyColors.textQuaternary),
          ],
        ],
      ),
    );
    final status = added == 0 ? null : (allAdded ? wf('tabs.allAdded') : '$added / ${actions.length}');
    if (workflow) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: SelectorRow(
          label: name,
          onPressed: () => w.onSelect('tool', toolDefaultValueOf(p, actions.first)..remove('meta')),
          child: Row(
            children: [
              Expanded(child: details),
              if (!w.canNotSelectMultiple && status != null) ...[
                const SizedBox(width: 8),
                DifyText(_tools('addToolModal.added'), DifyType.systemXsRegular, color: DifyColors.textTertiary),
              ],
            ],
          ),
        ),
      );
    }
    final canAddAll = !mcpBlocked && !w.canNotSelectMultiple && !allAdded && w.onSelectMultiple != null;
    final reveal = _hovered;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          MouseRegion(
            onEnter: (_) => setState(() => _hovered = true),
            onExit: (_) => setState(() => _hovered = false),
            child: Stack(
              alignment: Alignment.centerRight,
              children: [
                MergeSemantics(
                  child: Semantics(
                    expanded: _open,
                    child: SelectorRow(
                      label: name,
                      highlighted: _hovered,
                      onPressed: () => setState(() => _open = !_open),
                      child: Row(
                        children: [
                          Expanded(child: details),
                          if (!mcpBlocked && !w.canNotSelectMultiple && status != null && (allAdded || !reveal)) ...[
                            const SizedBox(width: 8),
                            DifyText(status, DifyType.systemXsRegular, color: DifyColors.textTertiary),
                          ],
                          const SizedBox(width: 8),
                          Opacity(
                            opacity: canAddAll && reveal ? 0 : 1,
                            child: Padding(
                              padding: EdgeInsets.only(right: mcpBlocked ? 28 : 0),
                              child: AnimatedRotation(
                                turns: _open ? 0.25 : 0,
                                duration: difyTransitionDuration,
                                child: RemixIcon(
                                  'arrow-right-s-line',
                                  size: 16,
                                  color: DifyColors.textQuaternary,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                if (canAddAll)
                  Positioned(
                    right: 4,
                    child: Opacity(
                      opacity: reveal ? 1 : 0,
                      child: IgnorePointer(
                        ignoring: !reveal,
                        child: DifyButton(
                          variant: DifyButtonVariant.ghostAccent,
                          size: DifyButtonSize.small,
                          onPressed: () => w.onSelectMultiple!('tool', [
                            for (final t in actions)
                              if (!_added(t)) toolDefaultValueOf(p, t)..remove('meta'),
                          ]),
                          child: Text(wf('tabs.addAll')),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (_open)
            for (final t in actions)
              ToolActionItem(
                provider: p,
                action: t,
                onSelect: w.onSelect,
                disabled: _added(t) || mcpBlocked,
                isAdded: _added(t),
              ),
        ],
      ),
    );
  }
}

/// ToolItem (tool/action-item.tsx): a ghost button indented under its provider (`pl-5.25 pr-1`) with the tool's
/// name after a `border-l-2 border-divider-subtle` guide, "added" when it is; hovering previews the provider icon,
/// the tool's name and description. Selecting it hands up the tool's ToolDefaultValue (its parameters empty).
class ToolActionItem extends StatelessWidget {
  const ToolActionItem({
    super.key,
    required this.provider,
    required this.action,
    required this.onSelect,
    this.disabled = false,
    this.isAdded = false,
  });

  final ToolProvider provider;
  final ToolAction action;
  final OnSelectBlock onSelect;
  final bool disabled, isAdded;

  @override
  Widget build(BuildContext context) {
    final label = localized(action.label), description = localized(action.description);
    return PreviewCardTrigger(
      preview: (_) => BlockPreviewContent(
        type: 'tool',
        toolIcon: provider.themedIcon,
        title: label,
        description: description,
        titleStyle: DifyType.systemSmRegular,
        descriptionColor: DifyColors.textSecondary,
      ),
      child: MergeSemantics(
        child: Semantics(
          hint: description.isEmpty ? null : description,
          child: DifyPressable(
            semanticLabel: label,
            disabled: disabled,
            onPressed: () => onSelect('tool', toolDefaultValueOf(provider, action)),
            builder: (context, hovered, focused) => Container(
              height: 32,
              padding: const EdgeInsets.only(left: 21, right: 4),
              decoration: BoxDecoration(
                color: hovered && !disabled ? DifyColors.stateBaseHover : null,
                borderRadius: BorderRadius.circular(DifyRadius.lg),
              ),
              foregroundDecoration: insetFocusRing(focused, DifyRadius.lg),
              child: Row(
                children: [
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.only(left: 16),
                      alignment: Alignment.centerLeft,
                      decoration: BoxDecoration(
                        border: Border(left: BorderSide(color: DifyColors.dividerSubtle, width: 2)),
                      ),
                      height: 36,
                      child: Opacity(
                        opacity: disabled ? 0.3 : 1,
                        child: DifyText(label, DifyType.systemSmMedium, color: DifyColors.textSecondary),
                      ),
                    ),
                  ),
                  if (isAdded)
                    Padding(
                      padding: const EdgeInsets.only(right: 16),
                      child: DifyText(
                        _tools('addToolModal.added'),
                        DifyType.systemXsRegular,
                        color: DifyColors.textTertiary,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

const _maxRecommended = 15, _initialVisible = 5;

/// The featured lists' shared show more / less logic (featured-tools.tsx, featured-triggers.tsx): of the first 15
/// plugins, the installed providers first, then the rest, 5 at a time.
class FeaturedSlice<T> {
  FeaturedSlice(
    List<MarketplacePlugin> plugins,
    T? Function(MarketplacePlugin) provider,
    String Function(T) idOf,
    int visible,
  ) {
    final seen = <String>{};
    for (final p in plugins.take(_maxRecommended)) {
      final prov = provider(p);
      if (prov == null) {
        uninstalled.add(p);
      } else if (seen.add(idOf(prov))) {
        installed.add(prov);
      }
    }
    final quota = visible < _maxRecommended ? visible : _maxRecommended;
    visibleInstalled = installed.take(quota).toList();
    final slots = quota - visibleInstalled.length;
    visibleUninstalled = slots > 0 ? uninstalled.take(slots).toList() : [];
    maxAvailable = (installed.length + uninstalled.length).clamp(0, _maxRecommended);
  }

  final installed = <T>[];
  final uninstalled = <MarketplacePlugin>[];
  late final List<T> visibleInstalled;
  late final List<MarketplacePlugin> visibleUninstalled;
  late final int maxAvailable;

  int get totalVisible => visibleInstalled.length + visibleUninstalled.length;
  bool get canToggle => maxAvailable > _initialVisible;
  bool get showingAll => canToggle && totalVisible >= maxAvailable;

  /// The next visible count after "Show more" / "Show less".
  int next(int visible) =>
      visible >= maxAvailable ? _initialVisible : (visible + _initialVisible).clamp(0, maxAvailable);
}

/// The featured lists' collapsible frame: the "Featured" header (collapse state in localStorage [storageKey]), the
/// loading spinner, the empty state link, [body] and the show more / less button.
class FeaturedSection extends StatelessWidget {
  const FeaturedSection({
    super.key,
    required this.storageKey,
    required this.isLoading,
    required this.emptyText,
    required this.emptyUrl,
    required this.totalVisible,
    required this.canToggle,
    required this.showingAll,
    required this.onToggleMore,
    required this.body,
    this.padding = const EdgeInsets.fromLTRB(12, 8, 12, 12),
    this.headerInset = -8,
    this.emptyPadding = const EdgeInsets.symmetric(vertical: 8),
  });

  final String storageKey;
  final bool isLoading;
  final String emptyText, emptyUrl;
  final int totalVisible;
  final bool canToggle, showingAll;
  final VoidCallback onToggleMore;
  final Widget body;
  final EdgeInsets padding, emptyPadding;
  final double headerInset;

  @override
  Widget build(BuildContext context) {
    final collapsed = StoredFlag.of(storageKey);
    return ValueListenableBuilder(
      valueListenable: collapsed,
      builder: (context, isCollapsed, _) => Padding(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Transform.translate(
                offset: Offset(headerInset, 0),
                child: CollapsibleHeader(
                  title: wf('tabs.featuredTools'),
                  expanded: !isCollapsed,
                  onToggle: () => collapsed.value = !isCollapsed,
                ),
              ),
            ),
            if (!isCollapsed) ...[
              if (isLoading)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Center(child: _Spinner()),
                ),
              if (!isLoading && totalVisible == 0)
                Padding(
                  padding: emptyPadding,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: SelectorLink(
                      url: emptyUrl,
                      label: emptyText,
                      child: DifyText(emptyText, DifyType.systemXsRegular, color: DifyColors.textAccent),
                    ),
                  ),
                ),
              if (!isLoading && totalVisible > 0) body,
              if (!isLoading && totalVisible > 0 && canToggle)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: _ShowMoreButton(showingAll: showingAll, onPressed: onToggleMore),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Spinner extends StatelessWidget {
  const _Spinner();
  @override
  Widget build(BuildContext context) =>
      SizedBox.square(dimension: 16, child: RemixIcon('loader-2-line', size: 16, color: DifyColors.textTertiary));
}

class _ShowMoreButton extends StatelessWidget {
  const _ShowMoreButton({required this.showingAll, required this.onPressed});
  final bool showingAll;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final label = wf(showingAll ? 'tabs.showLessFeatured' : 'tabs.showMoreFeatured');
    return DifyPressable(
      semanticLabel: label,
      onPressed: onPressed,
      builder: (context, hovered, focused) {
        final active = hovered || focused;
        final color = active ? DifyColors.textSecondary : DifyColors.textTertiary;
        return Container(
          height: 32,
          padding: const EdgeInsets.only(left: 12, right: 8),
          decoration: BoxDecoration(
            color: hovered ? DifyColors.stateBaseHover : null,
            borderRadius: BorderRadius.circular(DifyRadius.lg),
          ),
          foregroundDecoration: insetFocusRing(focused, DifyRadius.lg),
          child: Row(
            spacing: 4,
            children: [
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: active
                    ? DifyIcon(
                        showingAll
                            ? 'vender/solid/arrows/arrow-up-double-line'
                            : 'vender/solid/arrows/arrow-down-double-line',
                        size: 16,
                        color: color,
                      )
                    : RemixIcon('more-line', size: 16, color: color),
              ),
              DifyText(label, DifyType.systemXsRegular, color: color),
            ],
          ),
        );
      },
    );
  }
}

/// FeaturedTools: the marketplace's featured tools, installed providers as tool rows, the others as marketplace rows
/// (opening the plugin's page, with Install and the more menu on hover).
class FeaturedTools extends StatefulWidget {
  const FeaturedTools({
    super.key,
    required this.plugins,
    required this.providerMap,
    required this.onSelect,
    this.selectedTools,
    this.isLoading = false,
  });

  final List<MarketplacePlugin> plugins;
  final Map<String, ToolProvider> providerMap;
  final OnSelectBlock onSelect;
  final List<DifyJson>? selectedTools;
  final bool isLoading;

  @override
  State<FeaturedTools> createState() => _FeaturedToolsState();
}

class _FeaturedToolsState extends State<FeaturedTools> {
  int _visible = _initialVisible;

  @override
  void didUpdateWidget(FeaturedTools old) {
    super.didUpdateWidget(old);
    if (old.plugins != widget.plugins) _visible = _initialVisible;
  }

  @override
  Widget build(BuildContext context) {
    final d = BlockSelectorScope.of(context);
    final s = FeaturedSlice<ToolProvider>(widget.plugins, (p) => widget.providerMap[p.pluginId], (t) => t.id, _visible);
    return FeaturedSection(
      storageKey: 'workflow_tools_featured_collapsed',
      isLoading: widget.isLoading,
      emptyText: wf('tabs.noFeaturedPlugins'),
      emptyUrl: d.marketplaceCategoryUrl(PluginCategory.tool),
      totalVisible: s.totalVisible,
      canToggle: s.canToggle,
      showingAll: s.showingAll,
      onToggleMore: () => setState(() => _visible = s.next(_visible)),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (s.visibleInstalled.isNotEmpty)
            ToolsList(
              tools: s.visibleInstalled,
              onSelect: widget.onSelect,
              canNotSelectMultiple: true,
              selectedTools: widget.selectedTools,
              padding: EdgeInsets.zero,
            ),
          if (s.visibleUninstalled.isNotEmpty)
            PreviewCardScope(
              child: Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: 4,
                  children: [
                    for (final p in s.visibleUninstalled) FeaturedUninstalledItem(plugin: p, blockType: 'tool'),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A featured plugin that isn't installed: a link to its marketplace page (icon, name, install count) with Install
/// and the more menu taking the count's place on hover.
class FeaturedUninstalledItem extends StatefulWidget {
  const FeaturedUninstalledItem({super.key, required this.plugin, required this.blockType});
  final MarketplacePlugin plugin;
  final String blockType;

  @override
  State<FeaturedUninstalledItem> createState() => _FeaturedUninstalledItemState();
}

class _FeaturedUninstalledItemState extends State<FeaturedUninstalledItem> {
  bool _hovered = false, _menu = false;

  @override
  Widget build(BuildContext context) {
    final p = widget.plugin, d = BlockSelectorScope.of(context);
    final label = localized(p.label).isEmpty ? p.name : localized(p.label);
    final description = localized(p.brief);
    final reveal = _hovered || _menu;
    Widget link = SelectorLink(
      url: d.marketplaceUrl('/plugins/${p.org}/${p.name}'),
      label: label,
      child: Container(
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: _hovered ? DifyColors.stateBaseHover : null,
          borderRadius: BorderRadius.circular(DifyRadius.lg),
        ),
        child: Row(
          children: [
            SelectorBlockIcon(type: widget.blockType, toolIcon: p.icon),
            const SizedBox(width: 8),
            Expanded(child: DifyText(label, DifyType.systemSmMedium, color: DifyColors.textSecondary)),
            Opacity(
              opacity: reveal ? 0 : 1,
              child: Padding(
                padding: const EdgeInsets.only(left: 8),
                child: DifyText(
                  _plugin('install', {'num': formatInstallCount(p.installCount)}),
                  DifyType.systemXsRegular,
                  color: DifyColors.textTertiary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
    if (description.isNotEmpty) {
      link = PreviewCardTrigger(
        preview: (_) => BlockPreviewContent(
          type: widget.blockType,
          toolIcon: p.icon,
          title: label,
          description: description,
          titleStyle: DifyType.systemSmRegular,
          descriptionColor: DifyColors.textSecondary,
        ),
        child: link,
      );
    }
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Stack(
        alignment: Alignment.centerRight,
        children: [
          link,
          Positioned(
            right: 4,
            child: Opacity(
              opacity: reveal ? 1 : 0,
              child: PluginRowActions(plugin: p, onMenuChange: (o) => setState(() => _menu = o)),
            ),
          ),
        ],
      ),
    );
  }
}

/// A marketplace row's actions: Install (when allowed; the app's install dialog) and the more menu.
class PluginRowActions extends StatelessWidget {
  const PluginRowActions({super.key, required this.plugin, this.onMenuChange});
  final MarketplacePlugin plugin;
  final ValueChanged<bool>? onMenuChange;

  @override
  Widget build(BuildContext context) {
    final d = BlockSelectorScope.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 4,
      children: [
        if (d.canInstallPlugin)
          DifyButton(
            variant: DifyButtonVariant.ghostAccent,
            size: DifyButtonSize.small,
            onPressed: () => d.onInstallPlugin?.call(plugin),
            child: Text(_plugin('installAction')),
          ),
        MarketplacePluginAction(plugin: plugin, onOpenChange: onMenuChange),
      ],
    );
  }
}

/// marketplace-plugin/action.tsx: the more button (`i-ri-more-fill`, accent) opening Download and View details
/// (bottom-end, 4 px, `min-w-44`).
class MarketplacePluginAction extends StatefulWidget {
  const MarketplacePluginAction({super.key, required this.plugin, this.open, this.onOpenChange});
  final MarketplacePlugin plugin;
  final bool? open;
  final ValueChanged<bool>? onOpenChange;

  @override
  State<MarketplacePluginAction> createState() => _MarketplacePluginActionState();
}

class _MarketplacePluginActionState extends State<MarketplacePluginAction> {
  bool _open = false;
  bool _downloading = false;

  void _set(bool o) {
    setState(() => _open = o);
    widget.onOpenChange?.call(o);
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.plugin, d = BlockSelectorScope.of(context);
    final common = DifyI18n.tr;
    return DifyDropdownMenu(
      open: widget.open ?? _open,
      onOpenChange: _set,
      placement: DifyPlacement.bottomEnd,
      sideOffset: 4,
      width: 176,
      builder: (context, c) => DifyIconButton(
        label: common('common', 'operation.more'),
        variant: DifyButtonVariant.ghost,
        onPressed: c.toggle,
        icon: RemixIcon('more-fill', size: 16, color: DifyColors.componentsButtonSecondaryAccentText),
      ),
      children: [
        DifyMenuItem(
          onSelect: () async {
            if (_downloading) return;
            _set(false);
            final download = d.onDownloadPlugin;
            if (download == null) return;
            _downloading = true;
            try {
              await download(p);
            } finally {
              _downloading = false;
            }
          },
          child: Text(common('common', 'operation.download')),
        ),
        Semantics(
          link: true,
          linkUrl: Uri.tryParse(d.marketplaceUrl('/plugins/${p.org}/${p.name}')),
          child: DifyMenuItem(
            onSelect: () => d.open(d.marketplaceUrl('/plugins/${p.org}/${p.name}')),
            child: Text(common('common', 'operation.viewDetails')),
          ),
        ),
      ],
    );
  }
}

/// marketplace-plugin/list.tsx: with no search, the "Find more in Marketplace" footer (unless
/// [hideFindMoreFooter]); with matches, the "From Marketplace" bar (with "Search in Marketplace ↗") over them —
/// kept at the bottom of the scroll area while the matches are below it, where it scrolls to them — and the rows.
class MarketplacePluginList extends StatefulWidget {
  const MarketplacePluginList({
    super.key,
    required this.list,
    required this.searchText,
    required this.tags,
    this.category,
    this.hideFindMoreFooter = false,
  });

  final List<MarketplacePlugin> list;
  final String searchText;
  final List<String> tags;
  final String? category;
  final bool hideFindMoreFooter;

  @override
  State<MarketplacePluginList> createState() => _MarketplacePluginListState();
}

class _MarketplacePluginListState extends State<MarketplacePluginList> {
  final _results = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final w = widget, d = BlockSelectorScope.of(context);
    final noFilter = w.searchText.isEmpty && w.tags.isEmpty;
    if (noFilter) {
      return w.hideFindMoreFooter
          ? const SizedBox.shrink()
          : MarketplaceFooter(url: d.marketplaceCategoryUrl(w.category));
    }
    if (w.list.isEmpty) return const SizedBox.shrink();
    final url = d.marketplaceCategoryUrl(w.category, {'q': w.searchText, 'tags': w.tags.join(',')});
    MarketplaceScrollArea.register(context, _results, url);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MarketplaceStickyBar(url: url, position: StickyScrollPosition.showing),
        Padding(
          key: _results,
          padding: const EdgeInsets.all(4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [for (final p in w.list) MarketplacePluginItem(plugin: p)],
          ),
        ),
      ],
    );
  }
}

/// use-sticky-scroll.ts StickyScrollPosition.
enum StickyScrollPosition { belowTheWrap, showing, aboveTheWrap }

/// useStickyScroll's rule: where the element after the sticky bar is relative to the scroll area.
StickyScrollPosition stickyScrollPosition({
  required double wrapTop,
  required double wrapHeight,
  required double nextTop,
}) {
  if (nextTop - wrapTop >= wrapHeight) return StickyScrollPosition.belowTheWrap;
  if (nextTop <= wrapTop) return StickyScrollPosition.aboveTheWrap;
  return StickyScrollPosition.showing;
}

/// The "From Marketplace" bar: `h-8 px-4 py-1 system-sm-medium`; a button scrolling to the matches while they are
/// below ([StickyScrollPosition.belowTheWrap], `border-t bg-components-panel-bg-blur`), a link to the marketplace search
/// otherwise; "Search in Marketplace ↗" on the right.
class MarketplaceStickyBar extends StatelessWidget {
  const MarketplaceStickyBar({super.key, required this.url, required this.position, this.onScrollToResults});
  final String url;
  final StickyScrollPosition position;
  final VoidCallback? onScrollToResults;

  @override
  Widget build(BuildContext context) {
    final from = _plugin('fromMarketplace');
    final title = DifyText(from, DifyType.systemSmMedium, color: DifyColors.textPrimary);
    return Container(
      height: position == StickyScrollPosition.aboveTheWrap ? 36 : 32,
      padding: EdgeInsets.fromLTRB(16, position == StickyScrollPosition.belowTheWrap ? 4 : 12, 16, 4),
      decoration: switch (position) {
        StickyScrollPosition.belowTheWrap => BoxDecoration(
          color: DifyColors.componentsPanelBgBlur,
          border: Border(top: BorderSide(color: DifyColors.dividerSubtle)),
        ),
        StickyScrollPosition.aboveTheWrap => BoxDecoration(
          color: DifyColors.componentsPanelBgBlur,
          boxShadow: DifyShadows.xs,
        ),
        StickyScrollPosition.showing => null,
      },
      child: Row(
        children: [
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: position == StickyScrollPosition.belowTheWrap
                  ? DifyPressable(semanticLabel: from, onPressed: onScrollToResults, builder: (_, _, _) => title)
                  : SelectorLink(url: url, label: from, child: title),
            ),
          ),
          const SizedBox(width: 8),
          SelectorLink(
            url: url,
            label: _plugin('searchInMarketplace'),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              spacing: 2,
              children: [
                DifyText(
                  _plugin('searchInMarketplace'),
                  DifyType.systemSmMedium,
                  color: DifyColors.textAccentLightModeOnly,
                ),
                RemixIcon('arrow-right-up-line', size: 12, color: DifyColors.textAccentLightModeOnly),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The scrolling body of a tab that ends with marketplace matches: keeps the "From Marketplace" bar at the bottom
/// while the matches are below the visible area, and at the top once they have scrolled past it.
class MarketplaceScrollArea extends StatefulWidget {
  const MarketplaceScrollArea({super.key, required this.children});
  final List<Widget> children;

  /// Called by a [MarketplacePluginList] with matches.
  static void register(BuildContext context, GlobalKey results, String url) =>
      context.findAncestorStateOfType<_MarketplaceScrollAreaState>()?._register(results, url);

  @override
  State<MarketplaceScrollArea> createState() => _MarketplaceScrollAreaState();
}

class _MarketplaceScrollAreaState extends State<MarketplaceScrollArea> {
  final _scroll = ScrollController();
  final _viewport = GlobalKey();
  GlobalKey? _results;
  String? _url;
  StickyScrollPosition _position = StickyScrollPosition.showing;

  void _register(GlobalKey results, String url) {
    _results = results;
    _url = url;
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
  }

  void _measure() {
    if (!mounted) return;
    final wrap = _viewport.currentContext?.findRenderObject() as RenderBox?;
    final next = _results?.currentContext?.findRenderObject() as RenderBox?;
    var p = StickyScrollPosition.showing;
    if (wrap != null && next != null && next.attached && wrap.hasSize) {
      p = stickyScrollPosition(
        wrapTop: wrap.localToGlobal(Offset.zero).dy,
        wrapHeight: wrap.size.height,
        nextTop: next.localToGlobal(Offset.zero).dy,
      );
    }
    if (p != _position) setState(() => _position = p);
  }

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_measure);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _results = null;
    final body = SingleChildScrollView(
      key: _viewport,
      controller: _scroll,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: widget.children),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_results == null && _position != StickyScrollPosition.showing && mounted) {
        setState(() => _position = StickyScrollPosition.showing);
      }
    });
    if (_position == StickyScrollPosition.showing || _url == null) return body;
    return Stack(
      children: [
        body,
        Positioned(
          left: 0,
          right: 0,
          top: _position == StickyScrollPosition.aboveTheWrap ? 0 : null,
          bottom: _position == StickyScrollPosition.belowTheWrap ? 0 : null,
          child: MarketplaceStickyBar(
            url: _url!,
            position: _position,
            onScrollToResults: () {
              final c = _results?.currentContext;
              if (c != null) {
                Scrollable.ensureVisible(c, duration: const Duration(milliseconds: 300), curve: Curves.easeInOut);
              }
            },
          ),
        ),
      ],
    );
  }
}

/// marketplace-plugin/item.tsx: `rounded-lg py-1 pr-1 pl-3` with the 24 px icon, the name, the brief and "org ·
/// N installs"; Install and the more menu show on hover.
class MarketplacePluginItem extends StatefulWidget {
  const MarketplacePluginItem({super.key, required this.plugin});
  final MarketplacePlugin plugin;

  @override
  State<MarketplacePluginItem> createState() => _MarketplacePluginItemState();
}

class _MarketplacePluginItemState extends State<MarketplacePluginItem> {
  bool _hovered = false, _menu = false;

  @override
  Widget build(BuildContext context) {
    final p = widget.plugin, d = BlockSelectorScope.of(context);
    final reveal = _hovered || _menu;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
        decoration: BoxDecoration(
          color: _hovered ? DifyColors.stateBaseHover : null,
          borderRadius: BorderRadius.circular(DifyRadius.lg),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 24,
              height: 24,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(DifyRadius.md),
                border: Border.all(color: DifyColors.componentsPanelBorderSubtle, width: Css.hairline),
              ),
              child: p.icon == null ? null : d.iconBuilder?.call(context, p.icon, 24),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    height: 16,
                    child: DifyText(localized(p.label), DifyType.systemSmMedium, color: DifyColors.textPrimary),
                  ),
                  SizedBox(
                    height: 20,
                    child: DifyText(localized(p.brief), DifyType.systemXsRegular, color: DifyColors.textTertiary),
                  ),
                  Row(
                    spacing: 4,
                    children: [
                      DifyText(p.org, DifyType.systemXsRegular, color: DifyColors.textTertiary),
                      DifyText('·', DifyType.systemXsRegular, color: DifyColors.textTertiary),
                      Flexible(
                        child: DifyText(
                          _plugin('install', {'num': formatInstallCount(p.installCount)}),
                          DifyType.systemXsRegular,
                          color: DifyColors.textTertiary,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Opacity(
              opacity: reveal ? 1 : 0,
              child: PluginRowActions(plugin: p, onMenuChange: (o) => setState(() => _menu = o)),
            ),
          ],
        ),
      ),
    );
  }
}

/// DataSources (data-sources.tsx): the RAG pipeline's data source providers matching [searchText] (`max-h-116`, flat
/// view) and the marketplace's matching data source plugins. Selecting one hands up a DataSourceDefaultValue; the
/// built-in local file source carries Dify's default file extensions.
class DataSourcesPanel extends StatefulWidget {
  const DataSourcesPanel({super.key, required this.searchText, required this.onSelect, required this.dataSources});
  final String searchText;
  final OnSelectBlock onSelect;
  final List<ToolProvider> dataSources;

  @override
  State<DataSourcesPanel> createState() => _DataSourcesPanelState();
}

/// DEFAULT_FILE_EXTENSIONS_IN_LOCAL_FILE_DATA_SOURCE.
const defaultLocalFileExtensions = [
  'txt', 'markdown', 'mdx', 'pdf', 'html', 'xlsx', 'xls', 'vtt', 'properties', 'doc', 'docx', 'csv', 'eml', 'msg', //
  'pptx', 'xml', 'epub', 'ppt', 'md',
];

class _DataSourcesPanelState extends State<DataSourcesPanel> {
  late final _market = MarketplaceSearch(null)..addListener(() => mounted ? setState(() {}) : null);

  @override
  void dispose() {
    _market.dispose();
    super.dispose();
  }

  void _select(String _, [DifyJson? tool]) {
    if (tool == null) return widget.onSelect('datasource');
    final value = <String, Object?>{
      'plugin_id': tool['provider_id'],
      'provider_type': tool['provider_type'],
      'provider_name': tool['provider_name'],
      'datasource_name': tool['tool_name'],
      'datasource_label': tool['tool_label'],
      'title': tool['title'],
      'plugin_unique_identifier': tool['plugin_unique_identifier'],
      if (tool['provider_id'] == 'langgenius/file' && tool['provider_name'] == 'file')
        'fileExtensions': defaultLocalFileExtensions,
    };
    widget.onSelect('datasource', value);
  }

  @override
  Widget build(BuildContext context) {
    final w = widget, d = BlockSelectorScope.of(context);
    final s = w.searchText;
    final filtered = s.isEmpty
        ? [
            for (final p in w.dataSources)
              if (p.tools.isNotEmpty) p,
          ]
        : [
            for (final p in w.dataSources)
              if (_matches(p.name, s) || p.tools.any((t) => _matches(localized(t.label), s) || _matches(t.name, s))) p,
          ];
    final trimmed = s.trim();
    _market.update(
      d.enableMarketplace && trimmed.isNotEmpty
          ? (query: trimmed, tags: const [], category: PluginCategory.datasource)
          : null,
      d.searchMarketplace,
    );
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 464),
      child: MarketplaceScrollArea(
        children: [
          ToolsList(tools: filtered, onSelect: _select, hasSearchText: s.isNotEmpty, canNotSelectMultiple: true),
          if (d.enableMarketplace)
            MarketplacePluginList(
              list: _market.pending ? const [] : _market.plugins,
              searchText: trimmed,
              tags: const [],
              category: PluginCategory.datasource,
            ),
        ],
      ),
    );
  }
}
