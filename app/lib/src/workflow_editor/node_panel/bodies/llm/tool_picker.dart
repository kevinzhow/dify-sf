/// A minimal port of the block selector's Tools panel (block-selector/tool-picker.tsx, tools.tsx, tool/**), for the
/// panels that pick a tool: the Parameter Extractor's "Import from tools" and the agent's tool selector. It lists the
/// store's tool providers (`buildInTools`, `customTools`, `workflowTools`, `mcpTools`: Dify's ToolWithProvider
/// JSON) by tab (All, Tool Plugin, Swagger API, Workflow, MCP), filtered by a search; a provider expands to its tools
/// (a workflow tool provider is its single tool). Choosing a tool reports it; in multi-select mode tools toggle and
/// "Add" reports them all.
library;

import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';

import '../../../../cards/card_kit.dart' show DifyText;
import '../../../../design/dify_icon.dart';
import '../../../../design/dify_tokens.g.dart';
import '../../../../design/widgets/widgets.dart';
import '../../../../i18n/dify_i18n.dart';
import '../../../../workflow/dify_json.dart';
import '../../../../workflow/model_catalog.dart' show renderI18nObject;
import '../../../panel_fields/panel_fields.dart';
import '../../../store/store.dart';
import 'llm_vars.dart' show jsMap;

String _w(String key) => DifyI18n.tr('workflow', key);

/// A chosen tool: its provider (ToolWithProvider JSON, `tools` included) and the tool (`{name, label, description,
/// parameters}`).
typedef PickedTool = ({Json provider, Json tool});

/// `CollectionType` values.
abstract final class ToolCollectionType {
  static const builtIn = 'builtin', custom = 'api', workflow = 'workflow', mcp = 'mcp';
}

/// The key a picked tool is selected by: `<provider name>/<tool name>` (`provider_id` / `name` when no name).
String pickedToolKey(PickedTool t) =>
    '${jsStr(t.provider['name']) ?? jsStr(t.provider['id']) ?? ''}/${jsStr(t.tool['name']) ?? ''}';

/// The tool providers in the store, in Dify's order (built-in, custom, workflow, MCP).
List<Json> storeToolProviders(WorkflowStore? store) => [
  for (final list in [
    store?.buildInTools.value,
    store?.customTools.value,
    store?.workflowTools.value,
    store?.mcpTools.value,
  ])
    ...?list,
];

enum _ToolTab {
  all('tabs.allTool', null),
  plugin('tabs.plugin', ToolCollectionType.builtIn),
  custom('tabs.customTool', ToolCollectionType.custom),
  workflow('tabs.workflowTool', ToolCollectionType.workflow),
  mcp(null, ToolCollectionType.mcp);

  const _ToolTab(this.key, this.type);
  final String? key;
  final String? type;

  String get label => key == null ? 'MCP' : _w(key!);
}

/// ToolPicker: [trigger] (given the popup controller) opens the picker ([placement], [sideOffset], [alignOffset]).
/// [onSelect] gets the tool chosen, which closes it; with [onSelectMultiple] tools are toggled ([selected] keys,
/// see [pickedToolKey], are shown chosen and not offered again) and "Add" reports the new ones. [providers]
/// overrides the store's lists.
class ToolPicker extends StatefulWidget {
  const ToolPicker({
    super.key,
    required this.trigger,
    this.onSelect,
    this.onSelectMultiple,
    this.selected = const {},
    this.providers,
    this.placement = DifyPlacement.bottomEnd,
    this.sideOffset = 4,
    this.alignOffset = 0,
    this.disabled = false,
    this.language = 'en_US',
  });

  final DifyTriggerBuilder trigger;
  final ValueChanged<PickedTool>? onSelect;
  final ValueChanged<List<PickedTool>>? onSelectMultiple;
  final Set<String> selected;
  final List<Json>? providers;
  final DifyPlacement placement;
  final double sideOffset, alignOffset;
  final bool disabled;
  final String language;

  @override
  State<ToolPicker> createState() => _ToolPickerState();
}

class _ToolPickerState extends State<ToolPicker> {
  final _popup = DifyFloatingController();

  @override
  Widget build(BuildContext context) => DifyFloating(
    controller: _popup,
    placement: widget.placement,
    sideOffset: widget.sideOffset,
    alignOffset: widget.alignOffset,
    builder: widget.trigger,
    popupBuilder: (context) => ToolPickerPanel(
      providers:
          widget.providers ?? storeToolProviders(context.getInheritedWidgetOfExactType<WorkflowStoreScope>()?.store),
      selected: widget.selected,
      language: widget.language,
      multiple: widget.onSelectMultiple != null,
      onSelect: (t) {
        _popup.close();
        widget.onSelect?.call(t);
      },
      onSelectMultiple: (ts) {
        _popup.close();
        widget.onSelectMultiple?.call(ts);
      },
    ),
  );
}

/// The picker's content: `w-80 rounded-xl border-[0.5px] bg-components-panel-bg-blur shadow-lg`, the tabs, the
/// search and the provider list (`max-h-112 overflow-y-auto`).
class ToolPickerPanel extends StatefulWidget {
  const ToolPickerPanel({
    super.key,
    required this.providers,
    required this.onSelect,
    this.onSelectMultiple,
    this.multiple = false,
    this.selected = const {},
    this.language = 'en_US',
  });

  final List<Json> providers;
  final ValueChanged<PickedTool> onSelect;
  final ValueChanged<List<PickedTool>>? onSelectMultiple;
  final bool multiple;
  final Set<String> selected;
  final String language;

  @override
  State<ToolPickerPanel> createState() => _ToolPickerPanelState();
}

class _ToolPickerPanelState extends State<ToolPickerPanel> {
  _ToolTab _tab = _ToolTab.all;
  String _search = '';
  final _open = <String>{};
  final _picked = <String, PickedTool>{};

  String _label(Object? i18n) => renderI18nObject(
    {for (final e in jsMap(i18n).entries) e.key: e.value?.toString()},
    widget.language,
  );

  List<Json> _tools(Json p) => [for (final t in jsList(p['tools'])) jsMap(t)];

  /// The providers of the tab whose name or tools match the search (case-insensitive), with the matching tools.
  List<(Json, List<Json>)> get _visible {
    final q = _search.trim().toLowerCase();
    return [
      for (final p in widget.providers)
        if (_tab.type == null || p['type'] == _tab.type)
          if (() {
                final providerHit = q.isEmpty || _label(p['label']).toLowerCase().contains(q);
                return (
                  p,
                  [
                    for (final t in _tools(p))
                      if (providerHit ||
                          _label(t['label']).toLowerCase().contains(q) ||
                          '${t['name']}'.toLowerCase().contains(q))
                        t,
                  ],
                );
              }()
              case final hit when hit.$2.isNotEmpty)
            hit,
    ];
  }

  void _choose(PickedTool t) {
    if (!widget.multiple) return widget.onSelect(t);
    final key = pickedToolKey(t);
    setState(() => _picked.containsKey(key) ? _picked.remove(key) : _picked[key] = t);
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visible;
    return Semantics(
      container: true,
      role: SemanticsRole.dialog,
      label: _w('tabs.tools'),
      explicitChildNodes: true,
      child: Container(
        width: 320,
        decoration: BoxDecoration(
          color: DifyColors.componentsPanelBgBlur,
          borderRadius: BorderRadius.circular(DifyRadius.xl),
          border: Border.all(color: DifyColors.componentsPanelBorder, width: 0.5),
          boxShadow: DifyShadows.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
              child: Row(
                spacing: 2,
                children: [
                  for (final tab in _ToolTab.values)
                    DifyPressable(
                      semanticLabel: tab.label,
                      onPressed: () => setState(() => _tab = tab),
                      builder: (context, hovered, focused) => Container(
                        height: 24,
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: tab == _tab
                              ? DifyColors.stateAccentActive
                              : hovered
                              ? DifyColors.stateBaseHover
                              : null,
                          borderRadius: BorderRadius.circular(DifyRadius.md),
                        ),
                        child: DifyText(
                          tab.label,
                          DifyType.systemXsMedium,
                          color: tab == _tab ? DifyColors.textAccent : DifyColors.textTertiary,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(8),
              child: DifyInput(
                value: _search,
                height: 32,
                placeholder: DifyI18n.tr('plugin', 'searchTools'),
                leading: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8),
                  child: RemixIcon('search-line', size: 16, color: DifyColors.textQuaternary),
                ),
                onChanged: (v) => setState(() => _search = v),
              ),
            ),
            Flexible(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 448),
                child: visible.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
                        child: Text(
                          _w('tabs.noResult'),
                          textAlign: TextAlign.center,
                          style: difyTextStyle(DifyType.systemXsRegular, DifyColors.textTertiary),
                        ),
                      )
                    : ListView(
                        shrinkWrap: true,
                        padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
                        children: [for (final (p, tools) in visible) ..._provider(p, tools)],
                      ),
              ),
            ),
            if (widget.multiple)
              Container(
                padding: const EdgeInsets.all(8),
                decoration: const BoxDecoration(
                  border: Border(top: BorderSide(color: DifyColors.dividerSubtle)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    DifyButton(
                      variant: DifyButtonVariant.primary,
                      size: DifyButtonSize.small,
                      disabled: _picked.isEmpty,
                      onPressed: () => widget.onSelectMultiple?.call(_picked.values.toList()),
                      child: Text(DifyI18n.tr('common', 'operation.add')),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Iterable<Widget> _provider(Json p, List<Json> tools) sync* {
    final id = '${p['id'] ?? p['name']}';
    final flat = p['type'] == ToolCollectionType.workflow && tools.length == 1;
    final open = _open.contains(id) || _search.trim().isNotEmpty;
    if (!flat) {
      yield _Row(
        label: _label(p['label']),
        icon: p['icon'],
        trailing: RemixIcon(
          open ? 'arrow-down-s-line' : 'arrow-right-s-line',
          size: 16,
          color: DifyColors.textTertiary,
        ),
        onTap: () => setState(() => _open.contains(id) ? _open.remove(id) : _open.add(id)),
      );
    }
    if (!flat && !open) return;
    for (final t in tools) {
      final picked = (provider: p, tool: t);
      final key = pickedToolKey(picked);
      final already = widget.selected.contains(key);
      yield _Row(
        label: _label(t['label']),
        icon: flat ? p['icon'] : null,
        indent: !flat,
        disabled: already,
        trailing: already || _picked.containsKey(key)
            ? const RemixIcon('check-line', size: 16, color: DifyColors.textAccent)
            : null,
        onTap: () => _choose(picked),
      );
    }
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.label,
    required this.onTap,
    this.icon,
    this.trailing,
    this.indent = false,
    this.disabled = false,
  });

  final String label;
  final Object? icon;
  final Widget? trailing;
  final bool indent, disabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => DifyPressable(
    semanticLabel: label,
    disabled: disabled,
    onPressed: onTap,
    builder: (context, hovered, focused) => Container(
      height: 32,
      padding: EdgeInsets.only(left: indent ? 32 : 8, right: 8),
      decoration: BoxDecoration(
        color: hovered && !disabled ? DifyColors.stateBaseHover : null,
        borderRadius: BorderRadius.circular(DifyRadius.lg),
      ),
      child: Row(
        spacing: 8,
        children: [
          if (!indent)
            Container(
              width: 20,
              height: 20,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: switch (icon) {
                  {'background': final String bg} when bg.startsWith('#') && bg.length == 7 => Color(
                    int.parse('FF${bg.substring(1)}', radix: 16),
                  ),
                  _ => DifyColors.backgroundDefaultDodge,
                },
                borderRadius: BorderRadius.circular(DifyRadius.md),
                border: Border.all(color: DifyColors.componentsPanelBorderSubtle, width: 0.5),
              ),
              child: switch (icon) {
                {'content': final String emoji} => Text(emoji, style: const TextStyle(fontSize: 12)),
                _ => const RemixIcon('tools-line', size: 12, color: DifyColors.textTertiary),
              },
            ),
          Expanded(
            child: DifyText(
              label,
              DifyType.systemSmMedium,
              color: disabled ? DifyColors.textDisabled : DifyColors.textSecondary,
            ),
          ),
          ?trailing,
        ],
      ),
    ),
  );
}
