/// The Start tab (all-start-blocks.tsx, start-blocks.tsx, trigger-plugin/**, featured-triggers.tsx): User Input,
/// the schedule and webhook triggers, the installed trigger plugins, the featured triggers and the marketplace's.
library;

import 'package:flutter/widgets.dart';

import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../i18n/dify_i18n.dart';
import '../../workflow/model_catalog.dart' show I18nText;
import 'block_selector.dart' show OnSelectBlock;
import 'block_selector_data.dart';
import 'selector_widgets.dart';
import 'tools_panel.dart';

/// constants.tsx START_BLOCKS (type, English title for the search).
const startBlocks = [
  ('start', 'User Input'),
  ('trigger-schedule', 'Schedule Trigger'),
  ('trigger-webhook', 'Webhook Trigger'),
];

/// ENTRY_NODE_TYPES.
const entryNodeTypes = ['start', 'trigger-schedule', 'trigger-webhook', 'trigger-plugin'];

/// The start blocks StartBlocks lists: those in [availableBlocksTypes] whose name (or English title) contains
/// [searchText]; User Input only when not already on the canvas and not hidden, unless it is shown as added or
/// disabled.
List<String> filterStartBlocks({
  required String searchText,
  required List<String> availableBlocksTypes,
  required bool hasStartNode,
  bool hideUserInput = false,
  bool showUserInputAdded = false,
  bool showUserInputDisabled = false,
}) {
  final needle = searchText.toLowerCase();
  return [
    for (final (type, title) in startBlocks)
      if (!(type == 'start' && (hasStartNode || hideUserInput) && !showUserInputAdded && !showUserInputDisabled) &&
          ((type == 'trigger-webhook' ? wf('customWebhook') : wf('blocks.$type')).toLowerCase().contains(needle) ||
              title.toLowerCase().contains(needle)) &&
          availableBlocksTypes.contains(type))
        type,
  ];
}

/// trigger-plugin/list.tsx's filtering: providers with events; while searching, the providers whose name or label
/// matches, else those with matching events (only those).
List<ToolProvider> filterTriggerPlugins(List<ToolProvider> plugins, String searchText) {
  final needle = searchText.trim().toLowerCase();
  bool match(String name, I18nText label) =>
      [localized(label), name].where((s) => s.isNotEmpty).any((s) => s.toLowerCase().contains(needle));
  if (needle.isEmpty) {
    return [
      for (final p in plugins)
        if (p.tools.isNotEmpty) p,
    ];
  }
  final out = <ToolProvider>[];
  for (final p in plugins) {
    if (p.tools.isEmpty) continue;
    if (match(p.name, p.label)) {
      out.add(p);
      continue;
    }
    final events = [
      for (final e in p.tools)
        if (match(e.name, e.label)) e,
    ];
    if (events.isNotEmpty) out.add(p.withTools(events));
  }
  return out;
}

/// AllStartBlocks: (with User Input on the canvas, its conflict banner over a dimmed, inert list) the start blocks,
/// the installed trigger plugins, Featured and the marketplace's matching triggers; "No triggers found" when a
/// search finds nothing; the marketplace footer. [variant] `panel` is the start placeholder's panel.
class AllStartBlocks extends StatefulWidget {
  const AllStartBlocks({
    super.key,
    required this.searchText,
    required this.onSelect,
    this.availableBlocksTypes = const [],
    this.tags = const [],
    this.allowUserInputSelection = false,
    this.hasUserInputNode = false,
    this.hasTriggerNode = false,
    this.panelVariant = false,
  });

  final String searchText;
  final OnSelectBlock onSelect;
  final List<String> availableBlocksTypes;
  final List<String> tags;
  final bool allowUserInputSelection, hasUserInputNode, hasTriggerNode, panelVariant;

  @override
  State<AllStartBlocks> createState() => _AllStartBlocksState();
}

class _AllStartBlocksState extends State<AllStartBlocks> {
  late final _market = MarketplaceSearch(null)..addListener(() => mounted ? setState(() {}) : null);

  @override
  void dispose() {
    _market.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final w = widget, d = BlockSelectorScope.of(context);
    final entry = w.availableBlocksTypes.isNotEmpty ? w.availableBlocksTypes : entryNodeTypes;
    final triggers = entry.contains('trigger-plugin');
    final search = w.searchText.trim();
    final hasFilter = search.isNotEmpty || w.tags.isNotEmpty;
    final marketplace = d.enableMarketplace;
    final searchEnabled = triggers && marketplace && hasFilter;
    _market.update(
      searchEnabled ? (query: search, tags: w.tags, category: PluginCategory.trigger) : null,
      d.searchMarketplace,
    );
    final hideUserInput = !w.allowUserInputSelection && !w.hasTriggerNode;
    final blocks = filterStartBlocks(
      searchText: search,
      availableBlocksTypes: entry,
      hasStartNode: d.nodes.any((n) => n.type == 'start'),
      hideUserInput: hideUserInput,
      showUserInputAdded: w.hasUserInputNode,
      showUserInputDisabled: w.hasTriggerNode && !w.hasUserInputNode,
    );
    final installed = triggers ? filterTriggerPlugins(d.triggerPlugins, search) : const <ToolProvider>[];
    final featured = triggers && marketplace && !hasFilter;
    final marketResults = triggers && marketplace && _market.plugins.isNotEmpty;
    final hasAny = blocks.isNotEmpty || installed.isNotEmpty || featured || marketResults;
    final empty = hasFilter && !(searchEnabled && _market.pending) && !hasAny;
    final providerMap = <String, ToolProvider>{};
    for (final p in d.triggerPlugins) {
      for (final k in [p.pluginId, p.pluginUniqueIdentifier, p.id]) {
        if (k != null && k.isNotEmpty) providerMap.putIfAbsent(k, () => p);
      }
    }
    final sectionDivider =
        triggers && marketplace && (blocks.isNotEmpty || installed.isNotEmpty) && (featured || marketResults);
    final divider = Padding(
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: SizedBox(height: 1, child: ColoredBox(color: DifyColors.dividerSubtle)),
    );
    final disabled = w.hasUserInputNode;
    final list = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        StartBlocksList(
          blocks: blocks,
          onSelect: w.onSelect,
          showMostCommonBadge: true,
          showUserInputAdded: w.hasUserInputNode,
          showUserInputDisabled: w.hasTriggerNode && !w.hasUserInputNode,
          disabled: disabled,
        ),
        if (w.panelVariant && blocks.isNotEmpty && installed.isNotEmpty) divider,
        if (installed.isNotEmpty)
          TriggerPluginList(
            plugins: installed,
            onSelect: w.onSelect,
            hasSearchText: search.isNotEmpty,
            disabled: disabled,
          ),
        if (sectionDivider) divider,
        if (featured)
          FeaturedTriggers(
            plugins: d.featuredTriggers,
            providerMap: providerMap,
            onSelect: w.onSelect,
            isLoading: d.featuredTriggersLoading,
          ),
        if (triggers && marketplace)
          MarketplacePluginList(
            list: _market.plugins,
            searchText: search,
            tags: w.tags,
            category: PluginCategory.trigger,
            hideFindMoreFooter: true,
          ),
      ],
    );
    final footerUrl = d.marketplaceCategoryUrl(PluginCategory.trigger);
    return ConstrainedBox(
      constraints: w.panelVariant
          ? const BoxConstraints()
          : const BoxConstraints(minWidth: 400, maxWidth: 500, maxHeight: 640),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Flexible(
            child: MarketplaceScrollArea(
              children: [
                if (empty)
                  SelectorEmptyState(
                    title: wf('nodes.startPlaceholder.noTriggersFound'),
                    titleStyle: DifyType.systemSmMedium,
                    action: const RequestToCommunityLink(accentText: true),
                  )
                else ...[
                  if (w.hasUserInputNode) const _UserInputConflictBanner(),
                  if (disabled)
                    // `inert`: neither pointer nor keyboard reach it.
                    Opacity(
                      opacity: 0.3,
                      child: IgnorePointer(child: ExcludeFocus(child: list)),
                    )
                  else
                    list,
                ],
              ],
            ),
          ),
          if (marketplace) w.panelVariant ? _PanelFooter(url: footerUrl) : MarketplaceFooter(url: footerUrl),
        ],
      ),
    );
  }
}

/// The start placeholder panel's footer: a short rule and "Browse more on Marketplace" with the marketplace mark.
class _PanelFooter extends StatelessWidget {
  const _PanelFooter({required this.url});
  final String url;

  @override
  Widget build(BuildContext context) {
    final label = wf('nodes.startPlaceholder.browseMoreOnMarketplace');
    return Semantics(
      container: true,
      label: 'contentinfo',
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 8,
          children: [
            SizedBox(width: 32, height: 1, child: ColoredBox(color: DifyColors.dividerSubtle)),
            SelectorLink(
              url: url,
              label: label,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                spacing: 4,
                children: [
                  DifyIcon('vender/workflow/marketplace', size: 12, color: DifyColors.textTertiary),
                  DifyText(label, DifyType.systemXsRegular, color: DifyColors.textTertiary),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "User Input cannot be combined with other triggers": `border-b-[0.5px] px-3 py-2` on a blue-light wash with
/// `i-ri-information-fill`.
class _UserInputConflictBanner extends StatelessWidget {
  const _UserInputConflictBanner();

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    decoration: BoxDecoration(
      color: DifyColors.componentsPanelBgBlur,
      border: Border(bottom: BorderSide(color: DifyColors.dividerSubtle, width: 0.5)),
      gradient: LinearGradient(
        colors: [
          DifyColors.utilColorsBlueLightBlueLight500.withValues(alpha: 0.2 * 0.4),
          const Color(0x00FFFFFF),
        ],
      ),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 2,
      children: [
        Padding(
          padding: EdgeInsets.all(4),
          child: RemixIcon('information-fill', size: 16, color: DifyColors.textAccent),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: DifyText(
              wf('nodes.startPlaceholder.userInputConflictTip'),
              DifyType.systemXsRegular,
              color: DifyColors.textSecondary,
              maxLines: null,
            ),
          ),
        ),
      ],
    ),
  );
}

/// StartBlocks: [StartBlocksList] over [filterStartBlocks].
class StartBlocks extends StatelessWidget {
  const StartBlocks({
    super.key,
    required this.searchText,
    required this.onSelect,
    this.availableBlocksTypes = const [],
    this.hideUserInput = false,
    this.showMostCommonBadge = false,
    this.showUserInputAdded = false,
    this.showUserInputDisabled = false,
    this.disabled = false,
  });

  final String searchText;
  final OnSelectBlock onSelect;
  final List<String> availableBlocksTypes;
  final bool hideUserInput, showMostCommonBadge, showUserInputAdded, showUserInputDisabled, disabled;

  @override
  Widget build(BuildContext context) => StartBlocksList(
    blocks: filterStartBlocks(
      searchText: searchText,
      availableBlocksTypes: availableBlocksTypes,
      hasStartNode: BlockSelectorScope.of(context).nodes.any((n) => n.type == 'start'),
      hideUserInput: hideUserInput,
      showUserInputAdded: showUserInputAdded,
      showUserInputDisabled: showUserInputDisabled,
    ),
    onSelect: onSelect,
    showMostCommonBadge: showMostCommonBadge,
    showUserInputAdded: showUserInputAdded,
    showUserInputDisabled: showUserInputDisabled,
    disabled: disabled,
  );
}

/// The start block rows (`p-1`): BlockIcon sm and the name; User Input marked "Most common", "Added" or "original
/// start node" (then a rule), or disabled with the conflict reason on hover; hovering a row previews its icon,
/// name, description and "Author Dify Team".
class StartBlocksList extends StatelessWidget {
  const StartBlocksList({
    super.key,
    required this.blocks,
    required this.onSelect,
    this.showMostCommonBadge = false,
    this.showUserInputAdded = false,
    this.showUserInputDisabled = false,
    this.disabled = false,
  });

  final List<String> blocks;
  final OnSelectBlock onSelect;
  final bool showMostCommonBadge, showUserInputAdded, showUserInputDisabled, disabled;

  @override
  Widget build(BuildContext context) {
    if (blocks.isEmpty) return const SizedBox.shrink();
    return PreviewCardScope(
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (i, type) in blocks.indexed) ...[
              _row(type),
              if (type == 'start' && !showMostCommonBadge && i < blocks.length - 1)
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  child: SizedBox(height: 1, child: ColoredBox(color: DifyColors.dividerSubtle)),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _row(String type) {
    final userInput = type == 'start';
    final userInputDisabled = userInput && showUserInputDisabled;
    final rowDisabled = disabled || (userInput && showUserInputAdded) || userInputDisabled;
    final label = wf('blocks.$type');
    final description = userInput ? wf('nodes.start.userInputTipDescription') : wf('blocksAbout.$type');
    final reason = wf('nodes.startPlaceholder.userInputConflictTip');
    final row = SelectorRow(
      label: userInputDisabled ? '$label. $reason' : label,
      description: description,
      disabled: rowDisabled,
      onPressed: () => onSelect(type),
      child: Opacity(
        opacity: userInputDisabled ? 0.3 : 1,
        child: Row(
          children: [
            SelectorBlockIcon(type: type),
            const SizedBox(width: 8),
            Expanded(child: DifyText(label, DifyType.systemSmMedium, color: DifyColors.textSecondary)),
            if (userInput && showUserInputAdded)
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: DifyText(
                  DifyI18n.tr('common', 'operation.added'),
                  DifyType.systemXsRegular,
                  color: DifyColors.textTertiary,
                ),
              ),
            if (userInput && showMostCommonBadge && !showUserInputAdded)
              Container(
                margin: const EdgeInsets.only(left: 8),
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(5),
                  border: Border.all(color: DifyColors.dividerDeep),
                ),
                child: DifyText(
                  wf('blocks.mostCommon'),
                  DifyType.system2xsMediumUppercase,
                  color: DifyColors.textTertiary,
                ),
              ),
            if (userInput && !showMostCommonBadge && !showUserInputAdded && !showUserInputDisabled)
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: DifyText(
                  wf('blocks.originalStartNode'),
                  DifyType.systemXsRegular,
                  color: DifyColors.textQuaternary,
                ),
              ),
          ],
        ),
      ),
    );
    if (userInputDisabled) {
      return DifyTooltip(content: Text(reason), child: row);
    }
    return PreviewCardTrigger(
      preview: (_) => BlockPreviewContent(
        type: type,
        title: label,
        description: description,
        descriptionColor: DifyColors.textSecondary,
        footer: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: DifyText(
            '${DifyI18n.tr('tools', 'author')} ${wf('difyTeam')}',
            DifyType.systemXsRegular,
            color: DifyColors.textTertiary,
          ),
        ),
      ),
      child: row,
    );
  }
}

/// TriggerPluginList (`p-1`): the installed trigger providers.
class TriggerPluginList extends StatelessWidget {
  const TriggerPluginList({
    super.key,
    required this.plugins,
    required this.onSelect,
    this.hasSearchText = false,
    this.disabled = false,
  });

  final List<ToolProvider> plugins;
  final OnSelectBlock onSelect;
  final bool hasSearchText, disabled;

  @override
  Widget build(BuildContext context) => PreviewCardScope(
    child: Padding(
      padding: const EdgeInsets.all(4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final p in plugins)
            TriggerPluginItem(
              key: ValueKey(p.id),
              provider: p,
              onSelect: onSelect,
              hasSearchText: hasSearchText,
              disabled: disabled,
            ),
        ],
      ),
    ),
  );
}

/// TriggerPluginItem: the provider row (BlockIcon sm with its icon, the name, the author, a fold chevron) opening
/// its events (`max-h-60`, region "All triggers"); open while searching. A workflow provider selects its event.
class TriggerPluginItem extends StatefulWidget {
  const TriggerPluginItem({
    super.key,
    required this.provider,
    required this.onSelect,
    this.hasSearchText = false,
    this.disabled = false,
  });

  final ToolProvider provider;
  final OnSelectBlock onSelect;
  final bool hasSearchText, disabled;

  @override
  State<TriggerPluginItem> createState() => _TriggerPluginItemState();
}

class _TriggerPluginItemState extends State<TriggerPluginItem> {
  late bool _fold = !widget.hasSearchText;

  @override
  void didUpdateWidget(TriggerPluginItem old) {
    super.didUpdateWidget(old);
    if (old.hasSearchText != widget.hasSearchText) _fold = !widget.hasSearchText;
  }

  @override
  Widget build(BuildContext context) {
    final w = widget, p = w.provider;
    final workflow = p.type == CollectionType.workflow;
    final groupName = switch (p.type) {
      CollectionType.custom => wf('tabs.customTool'),
      CollectionType.workflow => wf('tabs.workflowTool'),
      _ => p.author,
    };
    final name = workflow ? localized(p.tools.firstOrNull?.label) : localized(p.label);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          MergeSemantics(
            child: Semantics(
              expanded: workflow ? null : !_fold,
              child: SelectorRow(
                label: name,
                disabled: w.disabled,
                focusableWhenDisabled: false,
                onPressed: () {
                  if (!workflow) return setState(() => _fold = !_fold);
                  w.onSelect('trigger-plugin', triggerDefaultValueOf(p, p.tools.first)..remove('meta'));
                },
                child: Row(
                  children: [
                    SelectorBlockIcon(type: 'trigger-plugin', toolIcon: p.themedIcon),
                    const SizedBox(width: 8),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 200),
                      child: DifyText(name, DifyType.systemSmRegular, color: DifyColors.textPrimary),
                    ),
                    const SizedBox(width: 8),
                    Expanded(child: DifyText(groupName, DifyType.systemXsRegular, color: DifyColors.textQuaternary)),
                    if (!workflow)
                      Padding(
                        padding: const EdgeInsets.only(left: 8),
                        child: RemixIcon(
                          _fold ? 'arrow-right-s-line' : 'arrow-down-s-line',
                          size: 16,
                          color: _fold ? DifyColors.textQuaternary : DifyColors.textTertiary,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          if (!workflow && !_fold)
            Semantics(
              container: true,
              label: wf('tabs.allTriggers'),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 240),
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final e in p.tools)
                        TriggerPluginActionItem(provider: p, event: e, onSelect: w.onSelect, disabled: w.disabled),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// TriggerPluginActionItem: an event row indented under its provider (`pl-5.25 pr-1`, `border-l-2` guide); hovering
/// previews it. Selecting it hands up the event's TriggerDefaultValue (its parameters empty).
class TriggerPluginActionItem extends StatelessWidget {
  const TriggerPluginActionItem({
    super.key,
    required this.provider,
    required this.event,
    required this.onSelect,
    this.disabled = false,
    this.isAdded = false,
  });

  final ToolProvider provider;
  final ToolAction event;
  final OnSelectBlock onSelect;
  final bool disabled, isAdded;

  @override
  Widget build(BuildContext context) {
    final label = localized(event.label), description = localized(event.description);
    return PreviewCardTrigger(
      preview: (_) => BlockPreviewContent(
        type: 'trigger-plugin',
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
            onPressed: () => onSelect('trigger-plugin', triggerDefaultValueOf(provider, event)),
            builder: (context, hovered, focused) => Container(
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
                      padding: const EdgeInsets.fromLTRB(16, 8, 0, 8),
                      decoration: BoxDecoration(
                        border: Border(left: BorderSide(color: DifyColors.dividerSubtle, width: 2)),
                      ),
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
                        DifyI18n.tr('tools', 'addToolModal.added'),
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

/// FeaturedTriggers: as FeaturedTools, with installed trigger providers as provider rows.
class FeaturedTriggers extends StatefulWidget {
  const FeaturedTriggers({
    super.key,
    required this.plugins,
    required this.providerMap,
    required this.onSelect,
    this.isLoading = false,
  });

  final List<MarketplacePlugin> plugins;
  final Map<String, ToolProvider> providerMap;
  final OnSelectBlock onSelect;
  final bool isLoading;

  @override
  State<FeaturedTriggers> createState() => _FeaturedTriggersState();
}

class _FeaturedTriggersState extends State<FeaturedTriggers> {
  int _visible = 5;

  @override
  void didUpdateWidget(FeaturedTriggers old) {
    super.didUpdateWidget(old);
    if (old.plugins != widget.plugins) _visible = 5;
  }

  @override
  Widget build(BuildContext context) {
    final d = BlockSelectorScope.of(context), map = widget.providerMap;
    final s = FeaturedSlice<ToolProvider>(
      widget.plugins,
      (p) => map[p.pluginId] ?? map[p.latestPackageIdentifier],
      (t) => t.id,
      _visible,
    );
    return FeaturedSection(
      storageKey: 'workflow_triggers_featured_collapsed',
      padding: const EdgeInsets.only(top: 8, bottom: 12),
      headerInset: 8,
      emptyPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      isLoading: widget.isLoading,
      emptyText: wf('tabs.noFeaturedTriggers'),
      emptyUrl: d.marketplaceCategoryUrl(PluginCategory.trigger),
      totalVisible: s.totalVisible,
      canToggle: s.canToggle,
      showingAll: s.showingAll,
      onToggleMore: () => setState(() => _visible = s.next(_visible)),
      body: PreviewCardScope(
        child: Padding(
          padding: const EdgeInsets.only(top: 4, left: 4, right: 4, bottom: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final p in s.visibleInstalled)
                TriggerPluginItem(key: ValueKey(p.id), provider: p, onSelect: widget.onSelect),
              for (final p in s.visibleUninstalled)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: FeaturedUninstalledItem(plugin: p, blockType: 'trigger-plugin'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
