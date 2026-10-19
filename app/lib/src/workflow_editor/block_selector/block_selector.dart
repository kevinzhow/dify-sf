/// Dify's block selector (workflow/block-selector/index.tsx, tabs.tsx): the "add a node" popup with its Nodes,
/// Tools, Sources, Start and Snippets tabs, opened from a trigger (the node handle's "+", the toolbar's Add Node,
/// the next-step "Select next step", ...) or at a rectangle ([BlockSelector.show]). Choosing a block closes it and
/// hands the block, Dify's default node data for it ([blockDefaults]) and the tool/trigger/data-source/agent
/// defaults to [BlockSelector.onSelect]; the app inserts the node.
library;

import 'dart:async';

import 'package:flutter/material.dart' show Material, MaterialType;
import 'package:flutter/scheduler.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../design/css_metrics.dart';
import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../i18n/dify_i18n.dart';
import '../store/workflow_store.dart' show DifyJson;
import 'block_defaults.dart';
import 'block_selector_data.dart';
import 'blocks_panel.dart';
import 'selector_widgets.dart';
import 'snippets_panel.dart';
import 'start_panel.dart';
import 'tools_panel.dart';

export 'block_defaults.dart';
export 'block_selector_data.dart';
export 'candidate_node.dart';

/// What a block row hands up (OnSelectBlock): the block type and the tool, trigger, data source or Agent v2
/// defaults it carries.
typedef OnSelectBlock = void Function(String type, [DifyJson? defaultValue]);

/// What the app receives when a block is chosen: its [type] (`agent-v2` for Agent v2, whose node is an `agent`),
/// Dify's default data for a new node of it ([blockDefaults], titled `blocks.<type>`), and [toolDefaultValue], the
/// selector's ToolDefaultValue / TriggerDefaultValue / DataSourceDefaultValue / Agent v2 binding (Dify's
/// `pluginDefaultValue`, merged over the defaults; see [newNodeData]).
typedef BlockSelectCallback = void Function(String type, DifyJson defaults, {DifyJson? toolDefaultValue});

/// Where Dify opens the selector from, and how (placement and offsets of each call site).
abstract final class BlockSelectorPlacements {
  /// A node's source handle "+" (insert after) and an edge's midpoint "+": `right`, 8 px.
  static const sourceHandle = (placement: DifyPlacement.right, sideOffset: 8.0, alignOffset: 0.0);

  /// A node's target handle "+" (insert before): `left`, 8 px.
  static const targetHandle = (placement: DifyPlacement.left, sideOffset: 8.0, alignOffset: 0.0);

  /// The toolbar's Add Node (operator/add-block.tsx): `right-start`, 4 px out, 8 px up; the candidate node flow.
  static const addBlock = (placement: DifyPlacement.rightStart, sideOffset: 4.0, alignOffset: -8.0);

  /// The pane menu's Add Node (AddBlock inside the context menu): `right-start`, -36 px, -4 px.
  static const paneMenu = (placement: DifyPlacement.rightStart, sideOffset: -36.0, alignOffset: -4.0);

  /// The next-step panel's "Select next step" (next-step/add.tsx): `top`, 0 px, `w-[328px]`.
  static const nextStep = (placement: DifyPlacement.top, sideOffset: 0.0, alignOffset: 0.0);

  /// The next-step item menu's Change (next-step/operator.tsx): `top-end`, 6 px, 8 px, `w-[328px]`.
  static const nextStepChange = (placement: DifyPlacement.topEnd, sideOffset: 6.0, alignOffset: 8.0);
}

/// BlockSelector. Uncontrolled unless [open] is given; [disabled] keeps it from opening (an open one can still be
/// closed). [trigger] builds the control that toggles it (default: the 16 px blue round "+"). The popup
/// (`w-100 rounded-xl border-[0.5px] bg-components-panel-bg shadow-lg`, [popupWidth] / [popupMinWidth] for the call
/// sites' `w-[328px]` / `min-w-[256px]`) opens at [placement]; the active tab's search field takes focus, Escape
/// closes it and focus returns to the trigger.
///
/// [availableBlocksTypes] are the blocks it may offer here (see [getAvailableBlocks]); [showStartTab] adds the Start
/// tab (entry blocks and trigger plugins); [standalonePanel] shows one tab's content without the tab bar.
class BlockSelector extends StatefulWidget {
  const BlockSelector({
    super.key,
    required this.onSelect,
    this.open,
    this.onOpenChange,
    this.trigger,
    this.triggerTooltip,
    this.triggerLabel,
    this.placement = DifyPlacement.right,
    this.sideOffset = 8,
    this.alignOffset = 0,
    this.popupWidth = 400,
    this.popupMinWidth = 0,
    this.availableBlocksTypes = const [],
    this.disabled = false,
    this.blocks,
    this.dataSources,
    this.noBlocks = false,
    this.noTools = false,
    this.standalonePanel,
    this.showStartTab = false,
    this.defaultActiveTab,
    this.ignoreNodeIds = const [],
    this.forceEnableStartTab = false,
    this.allowUserInputSelection,
    this.snippetInsertPayload,
    this.isolateKeyboardEvents = false,
  });

  final BlockSelectCallback onSelect;
  final bool? open;
  final ValueChanged<bool>? onOpenChange;
  final DifyTriggerBuilder? trigger;

  /// TipPopup around the trigger.
  final String? triggerTooltip;

  /// The trigger's accessible name (`triggerAriaLabel`); the default trigger's is "Add Node".
  final String? triggerLabel;
  final DifyPlacement placement;
  final double sideOffset, alignOffset;
  final double popupWidth, popupMinWidth;
  final List<String> availableBlocksTypes;
  final bool disabled;
  final List<BlockMeta>? blocks;
  final List<ToolProvider>? dataSources;
  final bool noBlocks, noTools;
  final BlockSelectorTab? standalonePanel;
  final bool showStartTab;
  final BlockSelectorTab? defaultActiveTab;

  /// Nodes not to count for the Start tab's conflicts (the node being changed).
  final List<String> ignoreNodeIds;

  /// Keeps the Start tab enabled whatever is on the canvas (changing a Start node's type).
  final bool forceEnableStartTab;

  /// Overrides whether User Input may be chosen (by default not once a trigger or User Input exists).
  final bool? allowUserInputSelection;

  /// Where a snippet goes (`prevNodeId` / `prevNodeSourceHandle` / `nextNodeId` / `nextNodeTargetHandle`).
  final DifyJson? snippetInsertPayload;

  /// Keeps key presses inside the popup from reaching an enclosing keyboard-managed overlay (a context menu).
  final bool isolateKeyboardEvents;

  /// Opens this selector at [anchor] (global coordinates; default: [context]'s box), for triggers that are not
  /// widgets (the canvas's handles and edges) or that the caller owns (the next-step buttons). Completes when it
  /// closes. [open], [onOpenChange] and [trigger] are not used.
  Future<void> show(BuildContext context, {Rect? anchor}) {
    final box = context.findRenderObject() as RenderBox?;
    final rect = anchor ?? (box == null ? Rect.zero : box.localToGlobal(Offset.zero) & box.size);
    final data = BlockSelectorScope.of(context);
    final done = Completer<void>();
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => BlockSelectorScope(
        data: data,
        child: _AnchoredSelector(
          selector: this,
          anchor: rect,
          onClosed: () {
            entry.remove();
            entry.dispose();
            done.complete();
          },
        ),
      ),
    );
    Overlay.of(context, rootOverlay: true).insert(entry);
    return done.future;
  }

  @override
  State<BlockSelector> createState() => _BlockSelectorState();
}

DifyJson _defaultsOf(String type, BlockSelectorData data) =>
    blockDefaults(type, chatMode: data.chatMode) ?? {'type': type, 'title': DifyI18n.tr('workflow', 'blocks.$type')};

class _BlockSelectorState extends State<BlockSelector> {
  late final _controller = _GuardedController(() => widget.disabled);
  final _search = FocusNode(debugLabel: 'BlockSelector search');

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _openChange(bool open) {
    if (open && widget.disabled) return;
    widget.onOpenChange?.call(open);
  }

  void _close() => widget.open == null ? _controller.close() : _openChange(false);

  void _select(String type, [DifyJson? value]) {
    if (widget.disabled) return;
    _close();
    widget.onSelect(type, _defaultsOf(type, BlockSelectorScope.of(context)), toolDefaultValue: value);
  }

  Widget _defaultTrigger(BuildContext context, DifyFloatingController c) => DifyIconButton(
    label: widget.triggerLabel ?? wf('common.addBlock'),
    variant: DifyButtonVariant.primary,
    size: DifyIconButtonSize.xs,
    disabled: widget.disabled,
    onPressed: c.toggle,
    icon: const DifyIcon('vender/line/general/plus-02', size: 10),
  );

  @override
  Widget build(BuildContext context) {
    final trigger = widget.trigger ?? _defaultTrigger;
    final label = wf('common.addBlock');
    return DifyFloating(
      controller: _controller,
      open: widget.open,
      onOpenChange: _openChange,
      placement: widget.placement,
      sideOffset: widget.sideOffset,
      alignOffset: widget.alignOffset,
      initialFocus: _search,
      builder: (context, c) {
        final t = trigger(context, c);
        return widget.triggerTooltip == null ? t : DifyTipPopup(title: widget.triggerTooltip!, child: t);
      },
      popupBuilder: (context) => Semantics(
        container: true,
        role: SemanticsRole.dialog,
        label: label,
        explicitChildNodes: true,
        child: BlockSelectorCard(
          selector: widget,
          searchFocus: _search,
          onSelect: _select,
          onRequestClose: _close,
        ),
      ),
    );
  }
}

/// The trigger's controller: a disabled selector doesn't open.
class _GuardedController extends DifyFloatingController {
  _GuardedController(this._disabled);
  final bool Function() _disabled;

  @override
  void open({Offset? at, bool instant = false}) {
    if (!_disabled()) super.open(at: at, instant: instant);
  }
}

/// [BlockSelector.show]'s popup: the card positioned at [anchor] like a popover (collision avoidance, scale and
/// fade), closed by an outside tap, Escape or a selection.
class _AnchoredSelector extends StatefulWidget {
  const _AnchoredSelector({required this.selector, required this.anchor, required this.onClosed});
  final BlockSelector selector;
  final Rect anchor;
  final VoidCallback onClosed;

  @override
  State<_AnchoredSelector> createState() => _AnchoredSelectorState();
}

class _AnchoredSelectorState extends State<_AnchoredSelector> with SingleTickerProviderStateMixin {
  late final _anim = AnimationController(vsync: this, duration: difyTransitionDuration)..forward();
  late final _curved = CurvedAnimation(parent: _anim, curve: difyTransitionCurve);
  final _search = FocusNode(debugLabel: 'BlockSelector search');
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    SchedulerBinding.instance.addPostFrameCallback((_) => mounted ? _search.requestFocus() : null);
  }

  @override
  void dispose() {
    _curved.dispose();
    _anim.dispose();
    _search.dispose();
    super.dispose();
  }

  void _close({bool instant = false}) {
    if (_closing) return;
    _closing = true;
    widget.selector.onOpenChange?.call(false);
    if (instant || (MediaQuery.maybeDisableAnimationsOf(context) ?? false)) return widget.onClosed();
    _anim.reverse().whenComplete(widget.onClosed);
  }

  void _select(String type, [DifyJson? value]) {
    final s = widget.selector;
    if (s.disabled) return;
    final data = BlockSelectorScope.of(context);
    _close();
    s.onSelect(type, _defaultsOf(type, data), toolDefaultValue: value);
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.selector;
    final overlay = Overlay.of(context, rootOverlay: true).context.findRenderObject() as RenderBox?;
    final anchor = overlay == null ? widget.anchor : overlay.globalToLocal(widget.anchor.topLeft) & widget.anchor.size;
    return DifyFloatingLayout(
      anchor: anchor,
      placement: s.placement,
      sideOffset: s.sideOffset,
      alignOffset: s.alignOffset,
      animation: _curved,
      child: TapRegion(
        onTapOutside: (_) => _close(),
        child: FocusScope(
          onKeyEvent: (node, e) {
            if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.escape) {
              _close(instant: true);
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: Semantics(
            container: true,
            role: SemanticsRole.dialog,
            label: wf('common.addBlock'),
            explicitChildNodes: true,
            child: BlockSelectorCard(selector: s, searchFocus: _search, onSelect: _select, onRequestClose: _close),
          ),
        ),
      ),
    );
  }
}

/// The popup's card and its mounted content (BlockSelectorContent): the blocks, data sources and canvas facts the
/// tabs need, resolved from [BlockSelectorScope] when it opens.
class BlockSelectorCard extends StatelessWidget {
  const BlockSelectorCard({
    super.key,
    required this.selector,
    required this.searchFocus,
    required this.onSelect,
    required this.onRequestClose,
  });

  final BlockSelector selector;
  final FocusNode searchFocus;
  final OnSelectBlock onSelect;
  final VoidCallback onRequestClose;

  static const _hiddenBlocks = {
    'start', 'start-placeholder', 'datasource', 'tool', 'iteration-start', 'loop-start', 'datasource-empty', //
  };

  @override
  Widget build(BuildContext context) {
    final s = selector, data = BlockSelectorScope.of(context);
    final blocks =
        s.blocks ??
        [
          for (final b in data.blocks ?? availableBlocks(chatMode: data.chatMode, agentV2: data.agentV2))
            if (!_hiddenBlocks.contains(b.type)) b,
        ];
    final dataSources = s.dataSources ?? data.dataSources;
    final ignored = s.ignoreNodeIds.toSet();
    final nodes = [
      for (final n in data.nodes)
        if (!ignored.contains(n.id)) n,
    ];
    final hasTrigger = nodes.any((n) => n.type.startsWith('trigger-'));
    final hasUserInput = nodes.any((n) => n.type == 'start');
    final hasPlaceholder = nodes.any((n) => n.type == 'start-placeholder');
    final snippetFlow = data.flow == BlockSelectorFlow.snippet;
    final (:tabs, :initialTab) = blockSelectorTabs(
      noBlocks: s.noBlocks,
      noSources: dataSources.isEmpty,
      noTools: s.noTools,
      noSnippets: snippetFlow || data.searchSnippets == null,
      noStart: !s.showStartTab,
      defaultActiveTab: s.defaultActiveTab,
      hasStartPlaceholderNode: hasPlaceholder,
      disableStartTab: snippetFlow,
      forceEnableStartTab: s.forceEnableStartTab,
    );
    Widget card = Container(
      width: s.popupWidth,
      constraints: BoxConstraints(minWidth: s.popupMinWidth),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: DifyColors.componentsPanelBg,
        borderRadius: BorderRadius.circular(DifyRadius.xl),
        border: Border.all(color: DifyColors.componentsPanelBorder, width: Css.hairline),
        boxShadow: DifyShadows.lg,
      ),
      child: Material(
        type: MaterialType.transparency,
        child: BlockSelectorPanels(
          tabs: tabs,
          defaultTab: initialTab,
          standalonePanel: s.standalonePanel,
          searchFocus: searchFocus,
          onSelect: onSelect,
          onRequestClose: onRequestClose,
          availableBlocksTypes: s.availableBlocksTypes,
          blocks: blocks,
          dataSources: dataSources,
          allowStartNodeSelection: s.allowUserInputSelection ?? (!hasUserInput && !hasTrigger),
          hasUserInputNode: hasUserInput,
          hasTriggerNode: hasTrigger,
          snippetInsertPayload: s.snippetInsertPayload,
        ),
      ),
    );
    // PopoverClose (`sr-only`, out of the Tab order): a close action for touch screen readers.
    card = Stack(
      children: [
        card,
        Positioned(
          left: 0,
          top: 0,
          width: 1,
          height: 1,
          child: Semantics(
            button: true,
            label: DifyI18n.tr('common', 'operation.close'),
            onTap: onRequestClose,
            child: const SizedBox.expand(),
          ),
        ),
      ],
    );
    if (s.isolateKeyboardEvents) card = _IsolatedKeys(child: card);
    return card;
  }
}

/// isolateKeyboardEvents: the popup handles its own editing and traversal keys and nothing it leaves unhandled goes
/// on to the overlay it was opened from (Escape still closes it).
class _IsolatedKeys extends StatelessWidget {
  const _IsolatedKeys({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Focus(
    canRequestFocus: false,
    skipTraversal: true,
    onKeyEvent: (node, e) =>
        e.logicalKey == LogicalKeyboardKey.escape ? KeyEventResult.ignored : KeyEventResult.skipRemainingHandlers,
    child: Shortcuts(
      shortcuts: WidgetsApp.defaultShortcuts,
      child: DefaultTextEditingShortcuts(child: child),
    ),
  );
}

/// BlockSelectorPanels (tabs.tsx): the tab bar (`bg-background-section-burn pt-1 pl-1`, a white indicator sliding
/// under the active tab over 150 ms) and the active tab's panel, each tab with its own search text and tags for the
/// popup's session. Arrow keys move focus between tabs; Enter or Space (or a click) opens one; disabled tabs show
/// why on hover.
class BlockSelectorPanels extends StatefulWidget {
  const BlockSelectorPanels({
    super.key,
    required this.tabs,
    required this.defaultTab,
    this.standalonePanel,
    this.searchFocus,
    required this.onSelect,
    this.onRequestClose,
    this.availableBlocksTypes = const [],
    this.blocks = const [],
    this.dataSources = const [],
    this.allowStartNodeSelection = false,
    this.hasUserInputNode = false,
    this.hasTriggerNode = false,
    this.snippetInsertPayload,
  });

  final List<BlockSelectorTabConfig> tabs;
  final BlockSelectorTab defaultTab;
  final BlockSelectorTab? standalonePanel;

  /// The default tab's search field (the popup's initial focus).
  final FocusNode? searchFocus;
  final OnSelectBlock onSelect;
  final VoidCallback? onRequestClose;
  final List<String> availableBlocksTypes;
  final List<BlockMeta> blocks;
  final List<ToolProvider> dataSources;
  final bool allowStartNodeSelection, hasUserInputNode, hasTriggerNode;
  final DifyJson? snippetInsertPayload;

  @override
  State<BlockSelectorPanels> createState() => _BlockSelectorPanelsState();
}

class _BlockSelectorPanelsState extends State<BlockSelectorPanels> {
  late BlockSelectorTab _active = widget.defaultTab;
  final _search = {for (final t in BlockSelectorTab.values) t: ''};
  final _tags = {for (final t in BlockSelectorTab.values) t: <String>[]};
  final _tabFocus = {for (final t in BlockSelectorTab.values) t: FocusNode(debugLabel: 'tab ${t.name}')};

  @override
  void dispose() {
    for (final f in _tabFocus.values) {
      f.dispose();
    }
    super.dispose();
  }

  BlockSelectorTab get _current {
    final tabs = widget.tabs;
    if (tabs.any((t) => t.tab == _active)) return _active;
    // The active tab went away: the first enabled one (Base UI's fallback).
    return tabs.where((t) => !t.disabled).firstOrNull?.tab ?? widget.defaultTab;
  }

  void _activate(BlockSelectorTabConfig t) {
    if (t.disabled || t.tab == _current) return;
    setState(() => _active = t.tab);
  }

  KeyEventResult _onTabKey(BlockSelectorTabConfig t, KeyEvent e) {
    final tabs = widget.tabs;
    final i = tabs.indexOf(t);
    if (isArrowKey(e, forward: true) || isArrowKey(e, forward: false)) {
      final next = tabs[(i + (isArrowKey(e, forward: true) ? 1 : -1)) % tabs.length];
      _tabFocus[next.tab]!.requestFocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Widget _searchFilter(BlockSelectorTab tab, FocusNode? focus) {
    void setSearch(String v) => setState(() => _search[tab] = v);
    final value = _search[tab]!;
    final filter = switch (tab) {
      BlockSelectorTab.start || BlockSelectorTab.tools => SelectorSearchBox(
        value: value,
        onChanged: setSearch,
        tags: _tags[tab]!,
        onTagsChanged: (v) => setState(() => _tags[tab] = v),
        placeholder: tab == BlockSelectorTab.start ? wf('tabs.searchTrigger') : DifyI18n.tr('plugin', 'searchTools'),
        focusNode: focus,
      ),
      _ => SelectorSearchInput(
        value: value,
        onChanged: setSearch,
        placeholder: tab == BlockSelectorTab.blocks ? wf('tabs.searchBlock') : wf('tabs.searchDataSource'),
        focusNode: focus,
      ),
    };
    return Padding(padding: const EdgeInsets.all(8), child: filter);
  }

  Widget _panel(BlockSelectorTab tab, FocusNode? focus) {
    final w = widget;
    Widget bordered(Widget child) => Flexible(
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: DifyColors.dividerSubtle)),
        ),
        child: child,
      ),
    );
    final search = _search[tab]!;
    return switch (tab) {
      BlockSelectorTab.snippets => SnippetsPanel(
        searchText: search,
        onSearchTextChange: (v) => setState(() => _search[tab] = v),
        insertPayload: w.snippetInsertPayload,
        onInserted: w.onRequestClose,
      ),
      BlockSelectorTab.blocks => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _searchFilter(tab, focus),
          bordered(
            BlocksPanel(
              searchText: search,
              onSelect: w.onSelect,
              availableBlocksTypes: w.availableBlocksTypes,
              blocks: w.blocks,
            ),
          ),
        ],
      ),
      BlockSelectorTab.sources => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _searchFilter(tab, focus),
          bordered(DataSourcesPanel(searchText: search, onSelect: w.onSelect, dataSources: w.dataSources)),
        ],
      ),
      BlockSelectorTab.start => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _searchFilter(tab, focus),
          bordered(
            AllStartBlocks(
              searchText: search,
              tags: _tags[tab]!,
              onSelect: w.onSelect,
              availableBlocksTypes: w.availableBlocksTypes,
              allowUserInputSelection: w.allowStartNodeSelection,
              hasUserInputNode: w.hasUserInputNode,
              hasTriggerNode: w.hasTriggerNode,
            ),
          ),
        ],
      ),
      BlockSelectorTab.tools => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _searchFilter(tab, focus),
          Flexible(
            child: ToolPanel(
              searchText: search,
              tags: _tags[tab]!,
              onTagsChange: (v) => setState(() => _tags[tab] = v),
              onSelect: w.onSelect,
              inRagPipeline: w.dataSources.isNotEmpty,
            ),
          ),
        ],
      ),
    };
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final standalone = w.standalonePanel;
    if (standalone != null) {
      return _panel(standalone, standalone == BlockSelectorTab.snippets ? null : w.searchFocus);
    }
    final current = _current;
    final active = w.tabs.where((t) => t.tab == current).firstOrNull;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _TabBar(
          tabs: w.tabs,
          active: current,
          focusNodes: _tabFocus,
          onActivate: (t) {
            _tabFocus[t.tab]!.requestFocus();
            _activate(t);
          },
          onKey: _onTabKey,
        ),
        Flexible(
          child: Semantics(
            container: true,
            role: SemanticsRole.tabPanel,
            label: active?.name,
            explicitChildNodes: true,
            child: KeyedSubtree(
              key: ValueKey(current),
              child: _panel(
                current,
                current == w.defaultTab && current != BlockSelectorTab.snippets ? w.searchFocus : null,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _TabBar extends StatefulWidget {
  const _TabBar({
    required this.tabs,
    required this.active,
    required this.focusNodes,
    required this.onActivate,
    required this.onKey,
  });

  final List<BlockSelectorTabConfig> tabs;
  final BlockSelectorTab active;
  final Map<BlockSelectorTab, FocusNode> focusNodes;
  final ValueChanged<BlockSelectorTabConfig> onActivate;
  final KeyEventResult Function(BlockSelectorTabConfig tab, KeyEvent e) onKey;

  @override
  State<_TabBar> createState() => _TabBarState();
}

class _TabBarState extends State<_TabBar> {
  final _stack = GlobalKey();
  final _keys = <BlockSelectorTab, GlobalKey>{};
  Rect? _indicator;
  bool _placed = false;

  void _measure() {
    if (!mounted) return;
    final stack = _stack.currentContext?.findRenderObject() as RenderBox?;
    final tab = _keys[widget.active]?.currentContext?.findRenderObject() as RenderBox?;
    if (stack == null || tab == null || !tab.hasSize) return;
    final r = (tab.localToGlobal(Offset.zero, ancestor: stack)) & tab.size;
    if (r != _indicator) {
      setState(() {
        _placed = _indicator != null;
        _indicator = r;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    SchedulerBinding.instance.addPostFrameCallback((_) => _measure());
    final ind = _indicator;
    return Semantics(
      container: true,
      // The tablist: not SemanticsRole.tabBar, whose children must all be tabs (a disabled tab's tooltip isn't).
      label: wf('common.addBlock'),
      explicitChildNodes: true,
      child: Container(
        color: DifyColors.backgroundSectionBurn,
        padding: const EdgeInsets.only(top: 4, left: 4),
        child: Stack(
          key: _stack,
          children: [
            if (ind != null)
              AnimatedPositioned(
                duration: _placed && !(MediaQuery.maybeDisableAnimationsOf(context) ?? false)
                    ? difyTransitionDuration
                    : Duration.zero,
                curve: Curves.easeInOut,
                left: ind.left,
                top: ind.top,
                width: ind.width,
                height: ind.height,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: DifyColors.componentsPanelBg,
                    borderRadius: BorderRadius.vertical(top: Radius.circular(DifyRadius.lg)),
                  ),
                ),
              ),
            // Tabs past the card's edge are clipped, as `overflow-hidden` does.
            UnconstrainedBox(
              constrainedAxis: Axis.vertical,
              alignment: Alignment.centerLeft,
              clipBehavior: Clip.hardEdge,
              child: Row(
                children: [
                  for (final t in widget.tabs)
                    KeyedSubtree(
                      key: _keys.putIfAbsent(t.tab, GlobalKey.new),
                      child: Padding(
                        padding: const EdgeInsets.only(right: 2),
                        child: _tab(t),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tab(BlockSelectorTabConfig t) {
    final selected = t.tab == widget.active;
    Widget tab = DifyTab(
      active: selected,
      disabled: t.disabled,
      focusableWhenDisabled: true,
      focusNode: widget.focusNodes[t.tab],
      semanticLabel: t.name,
      onKeyEvent: (e) => widget.onKey(t, e),
      onPressed: () => widget.onActivate(t),
      // block-selector/tabs.tsx restyles TabsTab: `h-8 rounded-t-lg px-3 system-sm-medium`, active
      // `text-text-accent` over the sliding TabsIndicator, disabled `opacity-60 text-text-disabled`.
      builder: (context, hovered, focused) => Opacity(
        opacity: t.disabled ? 0.6 : 1,
        child: Container(
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          alignment: Alignment.center,
          foregroundDecoration: focused
              ? BoxDecoration(
                  border: Border.all(color: DifyColors.stateAccentSolid, width: 2),
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(DifyRadius.lg)),
                )
              : null,
          child: DifyText(
            t.name,
            DifyType.systemSmMedium,
            color: t.disabled
                ? DifyColors.textDisabled
                : selected
                ? DifyColors.textAccent
                : DifyColors.textTertiary,
          ),
        ),
      ),
    );
    // Roving focus: only the active tab is in the Tab order.
    tab = FocusTraversalGroup(
      descendantsAreTraversable: selected,
      child: tab,
    );
    if (!t.disabled) return tab;
    // TooltipContent `max-w-57.5 rounded-xl px-4 py-3.5`.
    return DifyTooltip(
      surface: false,
      content: Container(
        constraints: const BoxConstraints(maxWidth: 230),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: DifyColors.componentsPanelBg,
          borderRadius: BorderRadius.circular(DifyRadius.xl),
          boxShadow: DifyShadows.lg,
        ),
        child: DifyText(
          t.disabledTip ?? wf('tabs.startDisabledTip'),
          DifyType.systemXsRegular,
          color: DifyColors.textTertiary,
          maxLines: null,
        ),
      ),
      child: tab,
    );
  }
}
