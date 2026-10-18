import 'package:flutter/widgets.dart';

import '../../../canvas/node_card.dart';
import '../../../design/dify_icon.dart';
import '../../../design/dify_tokens.g.dart';
import '../../../design/widgets/widgets.dart';
import '../../../i18n/dify_i18n.dart';
import '../../block_selector/selector_widgets.dart' show SelectorBlockIcon, SelectorIconSize;
import '../../store/plugin_dependency_store.dart';
import '../../store/workflow_store.dart';
import '../../store/workflow_store_scope.dart';
import '../header_data.dart';
import '../header_widgets.dart';
import 'checklist_item.dart';

String _tr(String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr('workflow', key, params);

/// header/checklist/index.tsx: the checklist button (with the warning count) and its popover: the nodes with
/// problems, each with "Go to fix", and the plugins to install. [items] defaults to the header graph's checklist.
class WorkflowChecklist extends StatefulWidget {
  const WorkflowChecklist({
    super.key,
    required this.disabled,
    this.showGoTo = true,
    this.onItemClick,
    this.items,
    this.pluginDependencies,
  });

  final bool disabled;
  final bool showGoTo;
  final ValueChanged<ChecklistItem>? onItemClick;
  final List<ChecklistItem>? items;

  /// Where "Install" puts the missing plugins (Dify's plugin dependency store).
  final PluginDependencyStore? pluginDependencies;

  @override
  State<WorkflowChecklist> createState() => _WorkflowChecklistState();
}

class _WorkflowChecklistState extends State<WorkflowChecklist> {
  bool _open = false;

  void _click(ChecklistItem item, WorkflowHeaderData data, WorkflowStore store) {
    if (widget.onItemClick != null) {
      widget.onItemClick!(item);
    } else {
      data.handleNodeSelect?.call(item.id);
      if (item.openInlineAgentPanel) store.setOpenInlineAgentPanelNodeId(item.id);
    }
    setState(() => _open = false);
  }

  @override
  Widget build(BuildContext context) {
    final data = WorkflowHeaderScope.of(context);
    final graph = data.graph;
    if (widget.items == null && graph != null) {
      return ValueListenableBuilder(valueListenable: graph, builder: (context, facts, _) => _build(facts.checklist));
    }
    return _build(widget.items ?? const []);
  }

  Widget _build(List<ChecklistItem> items) {
    final data = WorkflowHeaderScope.of(context);
    final store = WorkflowStoreScope.of(context);
    final label = _tr('panel.checklist');
    final plugins = [
      for (final i in items)
        if (i.isPluginMissing) i,
    ];
    final nodes = [
      for (final i in items)
        if (!i.isPluginMissing) i,
    ];
    return DifyPopover(
      open: _open && !widget.disabled,
      onOpenChange: (v) {
        if (!widget.disabled) setState(() => _open = v);
      },
      placement: DifyPlacement.bottomStart,
      sideOffset: 12,
      alignOffset: -30,
      surface: false,
      semanticLabel: label,
      builder: (context, c) => Padding(
        padding: const EdgeInsets.only(left: 2),
        child: HeaderPressable(
          disabled: widget.disabled,
          semanticLabel: label,
          onPressed: c.toggle,
          builder: (context, hovered) {
            final active = hovered || _open;
            return Opacity(
              opacity: widget.disabled ? 0.5 : 1,
              child: SizedBox.square(
                dimension: 28,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Positioned.fill(
                      child: Container(
                        decoration: BoxDecoration(
                          color: active ? DifyColors.stateAccentHover : null,
                          borderRadius: BorderRadius.circular(DifyRadius.md),
                        ),
                        alignment: Alignment.center,
                        child: RemixIcon(
                          'list-check-3',
                          size: 16,
                          color: active
                              ? DifyColors.componentsButtonSecondaryAccentText
                              : DifyColors.componentsButtonGhostText,
                        ),
                      ),
                    ),
                    if (items.isNotEmpty) Positioned(top: -6, right: -6, child: _CountBadge(items.length)),
                  ],
                ),
              ),
            );
          },
        ),
      ),
      content: Container(
        width: 420,
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 2 / 3),
        decoration: headerPopupDecoration(
          color: DifyColors.backgroundDefaultSubtle,
          radius: DifyRadius.xxl,
          shadow: DifyShadows.lg,
        ),
        clipBehavior: Clip.antiAlias,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 14, 12, 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: 2,
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.only(right: 32),
                              child: Text(
                                '$label${items.isNotEmpty ? '(${items.length})' : ''}',
                                style: const TextStyle(
                                  fontSize: 16,
                                  height: 24 / 16,
                                  fontWeight: FontWeight.w600,
                                  color: DifyColors.textPrimary,
                                ),
                              ),
                            ),
                          ),
                          Transform.translate(
                            offset: const Offset(2, -2),
                            child: HeaderCloseButton(
                              size: 28,
                              label: DifyI18n.tr('common', 'operation.close'),
                              onPressed: () => setState(() => _open = false),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (items.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Text(
                          _tr('panel.checklistDescription'),
                          style: const TextStyle(fontSize: 12, height: 16 / 12, color: DifyColors.textTertiary),
                        ),
                      ),
                  ],
                ),
              ),
              if (items.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    spacing: 4,
                    children: [
                      if (plugins.isNotEmpty)
                        ChecklistPluginGroup(
                          items: plugins,
                          dependencies: widget.pluginDependencies ?? data.pluginDependencies,
                          onClose: () => setState(() => _open = false),
                        ),
                      for (final item in nodes)
                        ChecklistNodeGroup(
                          key: ValueKey(item.id),
                          item: item,
                          showGoTo: widget.showGoTo,
                          onItemClick: (i) => _click(i, data, store),
                        ),
                    ],
                  ),
                )
              else
                Container(
                  margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Column(
                    children: [
                      const DifyIcon(
                        'vender/line/general/checklist-square',
                        size: 32,
                        color: DifyColors.textQuaternary,
                      ),
                      const SizedBox(height: 5),
                      Text(
                        _tr('panel.checklistResolved'),
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 12, height: 16 / 12, color: DifyColors.textTertiary),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// `absolute -top-1.5 -right-1.5 h-4.5 min-w-4.5 rounded-full border border-gray-100 bg-text-warning-secondary
/// text-[11px] font-semibold text-white`.
class _CountBadge extends StatelessWidget {
  const _CountBadge(this.count);
  final int count;

  @override
  Widget build(BuildContext context) => Container(
    height: 18,
    constraints: const BoxConstraints(minWidth: 18),
    padding: const EdgeInsets.symmetric(horizontal: 3),
    decoration: BoxDecoration(
      color: DifyColors.textWarningSecondary,
      border: Border.all(color: const Color(0xFFF2F4F7)),
      borderRadius: BorderRadius.circular(9),
    ),
    alignment: Alignment.center,
    child: Text(
      '$count',
      style: const TextStyle(fontSize: 11, height: 1, fontWeight: FontWeight.w600, color: Color(0xFFFFFFFF)),
    ),
  );
}

/// `<BlockIcon type toolIcon>`: a tool, data source or trigger plugin with a provider icon shows it.
Widget _itemIcon(ChecklistItem item, {bool small = false}) => item.toolIcon != null && item.toolIcon != ''
    ? SelectorBlockIcon(
        type: item.type,
        size: small ? SelectorIconSize.xs : SelectorIconSize.sm,
        toolIcon: item.toolIcon,
      )
    : _SmallBlockIcon(item.type, small: small);

/// A node's BlockIcon at `xs` (16 px, radius 5, 12 px glyph) or `sm` (20 px, radius 6, 14 px glyph).
class _SmallBlockIcon extends StatelessWidget {
  const _SmallBlockIcon(this.type, {this.small = false});
  final String type;
  final bool small;

  @override
  Widget build(BuildContext context) => Container(
    width: small ? 16 : 20,
    height: small ? 16 : 20,
    decoration: BoxDecoration(
      color: blockColor(type),
      borderRadius: BorderRadius.circular(small ? 5 : DifyRadius.md),
      border: Border.all(color: const Color(0x05FFFFFF), width: 0.5),
      boxShadow: DifyShadows.xs,
    ),
    alignment: Alignment.center,
    child: DifyIcon(blockGlyph(type), size: small ? 12 : 14, color: const Color(0xFFFFFFFF)),
  );
}

/// checklist/item-indicator.tsx: a 20×24 rail (1 px line in divider-regular) with a #F79009 dot ringed in white.
class ItemIndicator extends StatelessWidget {
  const ItemIndicator({super.key});

  @override
  Widget build(BuildContext context) =>
      const SizedBox(width: 20, height: 24, child: CustomPaint(painter: _Indicator()));
}

class _Indicator extends CustomPainter {
  const _Indicator();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(const Rect.fromLTWH(9.5, 0, 1, 24), Paint()..color = DifyColors.dividerRegular);
    canvas.drawCircle(const Offset(10, 12), 3.25, Paint()..color = const Color(0xFFF79009));
    canvas.drawCircle(
      const Offset(10, 12),
      3.25,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = const Color(0xFFFFFFFF),
    );
  }

  @override
  bool shouldRepaint(_Indicator old) => false;
}

/// checklist/node-group.tsx: a node's card (`rounded-[10px] bg-components-panel-on-panel-item-bg`) with its
/// errors and, when it is not connected, "This step is not connected to anything". Rows go to the node on click
/// (revealing "Go to fix" on hover) unless navigation is off.
class ChecklistNodeGroup extends StatelessWidget {
  const ChecklistNodeGroup({super.key, required this.item, required this.showGoTo, required this.onItemClick});

  final ChecklistItem item;
  final bool showGoTo;
  final ValueChanged<ChecklistItem> onItemClick;

  @override
  Widget build(BuildContext context) {
    final goTo = showGoTo && item.canNavigate && !item.disableGoTo;
    final messages = [...item.errorMessages, if (item.unConnected) _tr('common.needConnectTip')];
    return Container(
      decoration: BoxDecoration(
        color: DifyColors.componentsPanelOnPanelItemBg,
        borderRadius: BorderRadius.circular(DifyRadius.container),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
            child: Row(
              spacing: 8,
              children: [
                _itemIcon(item),
                Expanded(
                  child: Text(
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      height: 20 / 14,
                      fontWeight: FontWeight.w500,
                      color: DifyColors.textPrimary,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final m in messages) _ErrorRow(message: m, goTo: goTo, onTap: () => onItemClick(item)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorRow extends StatelessWidget {
  const _ErrorRow({required this.message, required this.goTo, required this.onTap});
  final String message;
  final bool goTo;
  final VoidCallback onTap;

  Widget _row(bool hovered) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 4),
    decoration: BoxDecoration(
      color: hovered ? DifyColors.stateBaseHover : null,
      borderRadius: BorderRadius.circular(DifyRadius.lg),
    ),
    child: Row(
      spacing: 8,
      children: [
        const ItemIndicator(),
        Expanded(
          child: Text(
            message,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, height: 16 / 12, color: DifyColors.textWarning),
          ),
        ),
        if (goTo)
          AnimatedOpacity(
            opacity: hovered ? 1 : 0,
            duration: const Duration(milliseconds: 150),
            child: Padding(
              padding: const EdgeInsets.only(right: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                spacing: 2,
                children: [
                  Text(
                    _tr('panel.goToFix'),
                    style: const TextStyle(
                      fontSize: 12,
                      height: 16 / 12,
                      fontWeight: FontWeight.w500,
                      color: DifyColors.textAccent,
                    ),
                  ),
                  const RemixIcon('arrow-right-line', size: 14, color: DifyColors.textAccent),
                ],
              ),
            ),
          ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => DifyTooltip(
    content: Text(message),
    child: goTo
        ? HeaderPressable(onPressed: onTap, semanticLabel: message, builder: (context, hovered) => _row(hovered))
        : _row(false),
  );
}

/// The version in a marketplace identifier (`org/name:1.0.0@sha` → `1.0.0`).
String? versionFromMarketplaceIdentifier(String identifier) {
  final parts = identifier.split('@').first.split(':');
  return parts.length > 1 && parts[1].isNotEmpty ? parts[1] : null;
}

/// checklist/plugin-group.tsx: the nodes whose plugin is not installed, with "Install" (it hands the marketplace
/// dependencies to the plugin installer, [dependencies]) .
class ChecklistPluginGroup extends StatelessWidget {
  const ChecklistPluginGroup({super.key, required this.items, this.dependencies, this.onClose});

  final List<ChecklistItem> items;
  final PluginDependencyStore? dependencies;
  final VoidCallback? onClose;

  List<DifyJson> get _dependencies => [
    for (final id in {for (final i in items) ?i.pluginUniqueIdentifier}.where((s) => s.isNotEmpty))
      {
        'type': 'marketplace',
        'value': {
          'marketplace_plugin_unique_identifier': id,
          'plugin_unique_identifier': id,
          'version': versionFromMarketplaceIdentifier(id),
        },
      },
  ];

  @override
  Widget build(BuildContext context) {
    final deps = _dependencies;
    return Container(
      decoration: BoxDecoration(
        color: DifyColors.componentsPanelOnPanelItemBg,
        borderRadius: BorderRadius.circular(DifyRadius.container),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
            child: Row(
              spacing: 8,
              children: [
                Container(
                  width: 20,
                  height: 20,
                  decoration: BoxDecoration(
                    color: DifyColors.componentsIconBgMidnightSolid,
                    border: Border.all(color: DifyColors.dividerRegular, width: 0.5),
                    borderRadius: BorderRadius.circular(DifyRadius.md),
                    boxShadow: DifyShadows.xs,
                  ),
                  alignment: Alignment.center,
                  child: const RemixIcon('download-line', size: 14, color: Color(0xFFFFFFFF)),
                ),
                Expanded(
                  child: Text(
                    _tr('nodes.common.pluginsNotInstalled', {'count': items.length}),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      height: 20 / 14,
                      fontWeight: FontWeight.w500,
                      color: DifyColors.textPrimary,
                    ),
                  ),
                ),
                DifyButton(
                  size: DifyButtonSize.small,
                  disabled: deps.isEmpty,
                  onPressed: () {
                    if (deps.isEmpty) return;
                    dependencies?.setDependencies(deps);
                    onClose?.call();
                  },
                  child: Text(_tr('nodes.agent.pluginInstaller.install')),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final item in items)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Row(
                      spacing: 8,
                      children: [
                        const ItemIndicator(),
                        _itemIcon(item, small: true),
                        Expanded(
                          child: Text(
                            item.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12, height: 16 / 12, color: DifyColors.textWarning),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
