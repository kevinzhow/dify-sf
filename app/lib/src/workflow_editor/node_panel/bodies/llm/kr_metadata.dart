/// The Knowledge Retrieval panel's Metadata Filtering (nodes/knowledge-retrieval/components/metadata/**): the mode
/// selector, the automatic mode's model, the manual mode's Conditions popover (condition list, items with their
/// operator and value editors, Add Condition) and the metadata icon.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../../../cards/card_kit.dart';
import '../../../../design/dify_icon.dart';
import '../../../../design/dify_tokens.g.dart';
import '../../../../design/widgets/widgets.dart';
import '../../../../i18n/dify_i18n.dart';
import '../../../../workflow/dify_json.dart';
import '../../../panel_fields/panel_fields.dart';
import 'kr_config.dart';
import 'model_parameter_modal.dart';
import 'panel_edit.dart' show jsMap;

String _w(String key) => DifyI18n.tr('workflow', key);
String _c(String key) => DifyI18n.tr('common', key);
String _time(String key) => DifyI18n.tr('time', key);
const _p = 'nodes.knowledgeRetrieval.metadata';

/// What the metadata components share (MetadataShape): the metadata on offer, the conditions and their handlers, the
/// variables value editors pick from.
class MetadataShape {
  const MetadataShape({
    this.metadataList = const [],
    this.selectedDatasetsLoaded = false,
    this.conditions,
    required this.onAddCondition,
    required this.onRemoveCondition,
    required this.onToggleLogicalOperator,
    required this.onUpdateCondition,
    this.stringVars = const VarScope(),
    this.numberVars = const VarScope(),
    this.isCommonVariable = false,
    this.commonStringVars = const [],
    this.commonNumberVars = const [],
  });

  final List<Json> metadataList;
  final bool selectedDatasetsLoaded;

  /// `metadata_filtering_conditions` (`{logical_operator, conditions}`).
  final Json? conditions;
  final ValueChanged<Json> onAddCondition;
  final ValueChanged<String> onRemoveCondition;
  final VoidCallback onToggleLogicalOperator;
  final void Function(String id, Json condition) onUpdateCondition;
  final VarScope stringVars, numberVars;
  final bool isCommonVariable;
  final List<({String name, String type, String value})> commonStringVars, commonNumberVars;

  List<Json> get conditionList => [for (final c in jsList(conditions?['conditions'])) jsMap(c)];
}

/// MetadataIcon: `RiTextSnippet` for string / select, `RiHashtag` for number, `RiTimeLine` for time.
class MetadataIcon extends StatelessWidget {
  const MetadataIcon({super.key, this.type, this.size = 14, this.color = DifyColors.textTertiary});
  final String? type;
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) => switch (type) {
    MetadataVarType.string || MetadataVarType.select => RemixIcon('text-snippet', size: size, color: color),
    MetadataVarType.number => RemixIcon('hashtag', size: size, color: color),
    MetadataVarType.time => RemixIcon('time-line', size: size, color: color),
    _ => SizedBox(width: size, height: size),
  };
}

/// A ghost small trigger: [label] and the chevron.
Widget _chevronButton(String label, VoidCallback onPressed, {bool disabled = false, double opacity = 1}) => Opacity(
  opacity: opacity,
  child: DifyButton(
    variant: DifyButtonVariant.ghost,
    size: DifyButtonSize.small,
    disabled: disabled,
    trailing: const RemixIcon('arrow-down-s-line', size: 14),
    onPressed: onPressed,
    child: Text(label),
  ),
);

/// The popovers' blurred list surface (`rounded-xl border-[0.5px] bg-components-panel-bg-blur p-1 shadow-lg`).
Widget _listSurface({required Widget child, double? width}) => Container(
  width: width,
  padding: const EdgeInsets.all(4),
  decoration: BoxDecoration(
    color: DifyColors.componentsPanelBgBlur,
    borderRadius: BorderRadius.circular(DifyRadius.xl),
    border: Border.all(color: DifyColors.componentsPanelBorder, width: 0.5),
    boxShadow: DifyShadows.lg,
  ),
  child: child,
);

/// A `h-7 px-3 text-[13px] font-medium` option row.
class _OptionRow extends StatelessWidget {
  const _OptionRow({required this.label, required this.onTap, this.selected = false, this.radius = DifyRadius.lg});
  final String label;
  final VoidCallback onTap;
  final bool selected;
  final double radius;

  @override
  Widget build(BuildContext context) => DifyPressable(
    semanticLabel: label,
    onPressed: onTap,
    builder: (context, hovered, focused) => Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      alignment: Alignment.centerLeft,
      decoration: BoxDecoration(
        color: hovered || selected ? DifyColors.stateBaseHover : null,
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Text(
        label,
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: DifyColors.textSecondary),
      ),
    ),
  );
}

/// A DifyFloating owning its controller; [popupBuilder] gets a `close`.
class _Popover extends StatefulWidget {
  const _Popover({required this.builder, required this.popupBuilder, this.placement = DifyPlacement.bottomStart});
  final DifyTriggerBuilder builder;
  final Widget Function(BuildContext context, VoidCallback close) popupBuilder;
  final DifyPlacement placement;

  @override
  State<_Popover> createState() => _PopoverState();
}

class _PopoverState extends State<_Popover> {
  final _c = DifyFloatingController();

  @override
  Widget build(BuildContext context) => DifyFloating(
    controller: _c,
    placement: widget.placement,
    sideOffset: 4,
    builder: widget.builder,
    popupBuilder: (context) => widget.popupBuilder(context, _c.close),
  );
}

// ---- metadata-filter ---------------------------------------------------------------------------------------------

/// MetadataFilterSelector: a secondary small button with the mode's title, opening Disabled / Automatic / Manual with
/// their descriptions (`w-70`), the current one checked.
class MetadataFilterSelector extends StatelessWidget {
  const MetadataFilterSelector({super.key, this.value = MetadataFilteringMode.disabled, required this.onSelect});
  final String value;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final options = [
      for (final k in const [
        MetadataFilteringMode.disabled,
        MetadataFilteringMode.automatic,
        MetadataFilteringMode.manual,
      ])
        (key: k, title: _w('$_p.options.$k.title'), desc: _w('$_p.options.$k.subTitle')),
    ];
    final selected = options.where((o) => o.key == value).firstOrNull ?? options.first;
    return _Popover(
      placement: DifyPlacement.bottomEnd,
      builder: (context, c) => DifyButton(
        size: DifyButtonSize.small,
        trailing: const RemixIcon('arrow-down-s-line', size: 14),
        onPressed: c.toggle,
        child: Text(selected.title),
      ),
      popupBuilder: (context, close) => _listSurface(
        width: 280,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final o in options)
              DifyPressable(
                semanticLabel: o.title,
                onPressed: () {
                  onSelect(o.key);
                  close();
                },
                builder: (context, hovered, focused) => Semantics(
                  checked: o.key == value,
                  inMutuallyExclusiveGroup: true,
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(8, 8, 12, 8),
                    decoration: BoxDecoration(
                      color: hovered ? DifyColors.stateBaseHover : null,
                      borderRadius: BorderRadius.circular(DifyRadius.lg),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 16,
                          child: o.key == value
                              ? const RemixIcon('check-line', size: 16, color: DifyColors.textAccent)
                              : null,
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              DifyText(o.title, DifyType.systemSmSemibold, color: DifyColors.textSecondary),
                              DifyText(
                                o.desc,
                                DifyType.systemXsRegular,
                                color: DifyColors.textTertiary,
                                maxLines: null,
                              ),
                            ],
                          ),
                        ),
                      ],
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

/// MetadataFilter: the "Metadata Filtering" collapse (only automatic mode expands it; choosing automatic opens it)
/// with its infotip, the mode selector and, in manual mode, the Conditions trigger; automatic mode shows its
/// description and the model (`metadata_model_config`, temperature 0.7 by default).
class MetadataFilter extends StatefulWidget {
  const MetadataFilter({
    super.key,
    required this.shape,
    this.mode = MetadataFilteringMode.disabled,
    required this.onModeChange,
    this.modelConfig,
    this.onModelChange,
    this.onCompletionParamsChange,
  });

  final MetadataShape shape;
  final String mode;
  final ValueChanged<String> onModeChange;
  final Json? modelConfig;
  final ValueChanged<ModelChoice>? onModelChange;
  final ValueChanged<Json>? onCompletionParamsChange;

  @override
  State<MetadataFilter> createState() => _MetadataFilterState();
}

class _MetadataFilterState extends State<MetadataFilter> {
  bool _collapsed = true;

  @override
  Widget build(BuildContext context) {
    final w = widget, mode = w.mode;
    final tip = _w('$_p.tip');
    final model = w.modelConfig;
    return PanelCollapse(
      title: _w('$_p.title'),
      disabled: mode == MetadataFilteringMode.disabled || mode == MetadataFilteringMode.manual,
      indicator: mode == MetadataFilteringMode.automatic,
      collapsed: _collapsed,
      onCollapse: (v) => setState(() => _collapsed = v),
      afterTrigger: Infotip(label: tip, width: 200, content: Text(tip)),
      actions: Padding(
        padding: const EdgeInsets.only(right: 16),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: MetadataFilterSelector(
                value: mode,
                onSelect: (m) {
                  if (m == MetadataFilteringMode.automatic) setState(() => _collapsed = false);
                  w.onModeChange(m);
                },
              ),
            ),
            if (mode == MetadataFilteringMode.manual)
              Flexible(
                child: Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: MetadataTrigger(shape: w.shape),
                ),
              ),
          ],
        ),
      ),
      child: mode != MetadataFilteringMode.automatic
          ? const SizedBox.shrink()
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: DifyText(
                    _w('$_p.options.automatic.desc'),
                    DifyType.bodyXsRegular,
                    color: DifyColors.textTertiary,
                    maxLines: null,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                  child: ModelParameterModal(
                    provider: jsStr(model?['provider']) ?? '',
                    modelId: jsStr(model?['name']) ?? '',
                    completionParams: model?['completion_params'] is Map
                        ? jsMap(model!['completion_params'])
                        : const {'temperature': 0.7},
                    onModelChange: w.onModelChange ?? (_) {},
                    onCompletionParamsChange: w.onCompletionParamsChange ?? (_) {},
                  ),
                ),
              ],
            ),
    );
  }
}

/// MetadataTrigger: "Conditions" (secondary-accent small, `RiFilter3Line`, the count chip) opening the MetadataPanel
/// to the left; once the datasets are loaded, conditions whose metadata is gone are removed.
class MetadataTrigger extends StatefulWidget {
  const MetadataTrigger({super.key, required this.shape});
  final MetadataShape shape;

  @override
  State<MetadataTrigger> createState() => _MetadataTriggerState();
}

class _MetadataTriggerState extends State<MetadataTrigger> {
  final _popup = DifyFloatingController();

  @override
  void initState() {
    super.initState();
    _prune();
  }

  @override
  void didUpdateWidget(MetadataTrigger old) {
    super.didUpdateWidget(old);
    _prune();
  }

  void _prune() {
    final s = widget.shape;
    if (!s.selectedDatasetsLoaded) return;
    final stale = staleConditionIds(s.conditionList, s.metadataList);
    if (stale.isEmpty) return;
    scheduleMicrotask(() => stale.forEach(s.onRemoveCondition));
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.shape;
    return DifyFloating(
      controller: _popup,
      placement: DifyPlacement.left,
      sideOffset: 4,
      builder: (context, c) => DifyButton(
        variant: DifyButtonVariant.secondaryAccent,
        size: DifyButtonSize.small,
        leading: const RemixIcon('filter-3-line', size: 14),
        trailing: Container(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(5),
            border: Border.all(color: DifyColors.dividerDeep),
          ),
          child: DifyText(
            '${s.conditionList.length}',
            DifyType.system2xsMediumUppercase,
            color: DifyColors.textTertiary,
          ),
        ),
        onPressed: c.toggle,
        child: Text(_w('$_p.panel.conditions')),
      ),
      popupBuilder: (context) => MetadataPanel(shape: s, onCancel: _popup.close),
    );
  }
}

/// MetadataPanel: `w-105 rounded-2xl` with "Metadata Filter Conditions" and close, the condition list and Add
/// Condition.
class MetadataPanel extends StatelessWidget {
  const MetadataPanel({super.key, required this.shape, required this.onCancel});
  final MetadataShape shape;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) => Container(
    width: 420,
    decoration: BoxDecoration(
      color: DifyColors.componentsPanelBg,
      borderRadius: BorderRadius.circular(DifyRadius.xxl),
      border: Border.all(color: DifyColors.componentsPanelBorder, width: 0.5),
      boxShadow: DifyShadows.n2xl,
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 14, 10, 0),
          child: Row(
            children: [
              Expanded(child: DifyText(_w('$_p.panel.title'), DifyType.systemXlSemibold)),
              DifyIconButton(
                label: _c('operation.close'),
                size: DifyIconButtonSize.lg,
                icon: const RemixIcon('close-line', size: 16, color: DifyColors.textTertiary),
                onPressed: onCancel,
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: ConditionList(shape: shape),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: AddCondition(metadataList: shape.metadataList, onAdd: shape.onAddCondition),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

/// AddCondition: "Add Condition" (secondary small) opening a `w-[320px]` popover with "Search metadata" and the
/// metadata rows (icon, name, type); a row adds its condition and closes.
class AddCondition extends StatefulWidget {
  const AddCondition({super.key, required this.metadataList, required this.onAdd});
  final List<Json> metadataList;
  final ValueChanged<Json> onAdd;

  @override
  State<AddCondition> createState() => _AddConditionState();
}

class _AddConditionState extends State<AddCondition> {
  final _popup = DifyFloatingController();
  String _search = '';

  @override
  Widget build(BuildContext context) {
    final label = _w('$_p.panel.search');
    return DifyFloating(
      controller: _popup,
      placement: DifyPlacement.bottomStart,
      sideOffset: 12,
      builder: (context, c) => DifyButton(
        size: DifyButtonSize.small,
        leading: const RemixIcon('add-line', size: 14),
        onPressed: c.toggle,
        child: Text(_w('$_p.panel.add')),
      ),
      popupBuilder: (context) => StatefulBuilder(
        builder: (context, setLocal) {
          final list = widget.metadataList.where((m) => '${m['name'] ?? ''}'.contains(_search));
          return _listSurface(
            width: 320,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
                  child: DifyInput(
                    value: _search,
                    placeholder: label,
                    semanticLabel: label,
                    leading: const RemixIcon('search-line', size: 16, color: DifyColors.componentsInputTextPlaceholder),
                    onChanged: (v) => setLocal(() => _search = v),
                  ),
                ),
                const SizedBox(height: 4),
                for (final m in list)
                  DifyPressable(
                    semanticLabel: '${m['name']}',
                    onPressed: () {
                      widget.onAdd(m);
                      _popup.close();
                    },
                    builder: (context, hovered, focused) => Container(
                      height: 24,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        color: hovered ? DifyColors.stateBaseHover : null,
                        borderRadius: BorderRadius.circular(DifyRadius.md),
                      ),
                      child: Row(
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(right: 4),
                            child: MetadataIcon(type: jsStr(m['type'])),
                          ),
                          Expanded(
                            child: DifyText('${m['name']}', DifyType.systemSmMedium, color: DifyColors.textSecondary),
                          ),
                          DifyText('${m['type'] ?? ''}', DifyType.systemXsRegular, color: DifyColors.textTertiary),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

// ---- condition-list ----------------------------------------------------------------------------------------------

/// ConditionList: with more than one condition, the AND / OR bracket (a toggle chip); the condition items.
class ConditionList extends StatelessWidget {
  const ConditionList({super.key, required this.shape, this.disabled = false});
  final MetadataShape shape;
  final bool disabled;

  @override
  Widget build(BuildContext context) {
    final conditions = shape.conditionList;
    final op = jsStr(shape.conditions?['logical_operator']) ?? 'and';
    final many = conditions.length > 1;
    final items = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, c) in conditions.indexed)
          Padding(
            key: ValueKey('condition-${c['id']}'),
            padding: EdgeInsets.only(bottom: i == conditions.length - 1 ? 0 : 4),
            child: ConditionItem(condition: c, shape: shape, disabled: disabled),
          ),
      ],
    );
    if (!many) return items;
    return Stack(
      children: [
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          width: 44,
          child: Stack(
            alignment: Alignment.centerRight,
            children: [
              Positioned(
                top: 16,
                bottom: 16,
                right: 4,
                width: 10,
                child: Container(
                  decoration: const BoxDecoration(
                    border: Border(
                      left: BorderSide(color: DifyColors.dividerDeep),
                      top: BorderSide(color: DifyColors.dividerDeep),
                      bottom: BorderSide(color: DifyColors.dividerDeep),
                    ),
                    borderRadius: BorderRadius.horizontal(left: Radius.circular(8)),
                  ),
                ),
              ),
              Container(width: 16, height: 29, color: DifyColors.componentsPanelBg),
              Positioned(
                right: 4,
                child: DifyPressable(
                  semanticLabel: op.toUpperCase(),
                  onPressed: shape.onToggleLogicalOperator,
                  builder: (context, hovered, focused) => Container(
                    height: 21,
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    decoration: BoxDecoration(
                      color: DifyColors.componentsButtonSecondaryBg,
                      borderRadius: BorderRadius.circular(DifyRadius.md),
                      border: Border.all(color: DifyColors.componentsButtonSecondaryBorder, width: 0.5),
                      boxShadow: DifyShadows.xs,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          op.toUpperCase(),
                          style: const TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: DifyColors.textAccentSecondary,
                          ),
                        ),
                        const SizedBox(width: 2),
                        const RemixIcon('loop-left-line', size: 12, color: DifyColors.textAccentSecondary),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        Padding(padding: const EdgeInsets.only(left: 44), child: items),
      ],
    );
  }
}

/// ConditionItem: the metadata chip (icon, name, type), the operator, and (unless the operator needs no value) the
/// value editor by type; the delete box turns the item destructive while hovered.
class ConditionItem extends StatefulWidget {
  const ConditionItem({super.key, required this.condition, required this.shape, this.disabled = false});
  final Json condition;
  final MetadataShape shape;
  final bool disabled;

  @override
  State<ConditionItem> createState() => _ConditionItemState();
}

class _ConditionItemState extends State<ConditionItem> {
  bool _hovered = false;
  late String _method = _valueAndMethod.valueMethod;

  Json? get _metadata => conditionMetadata(widget.condition, widget.shape.metadataList);

  ({Object? value, String valueMethod}) get _valueAndMethod => conditionValueAndMethod(
    widget.condition['value'],
    jsStr(_metadata?['type']),
    isCommon: widget.shape.isCommonVariable,
  );

  void _update(Json c) => widget.shape.onUpdateCondition('${widget.condition['id']}', c);

  @override
  Widget build(BuildContext context) {
    final c = widget.condition, s = widget.shape;
    final meta = _metadata;
    final type = jsStr(meta?['type']);
    final op = jsStr(c['comparison_operator']);
    final needsValue = !comparisonOperatorNotRequireValue(op);
    final vm = _valueAndMethod;
    Widget? editor;
    if (needsValue && (type == MetadataVarType.string || type == MetadataVarType.select)) {
      editor = ConditionString(
        valueMethod: _method,
        onValueMethodChange: (m) {
          setState(() => _method = m);
          _update({...c, 'value': null});
        },
        vars: s.stringVars,
        value: vm.value is String ? vm.value! as String : null,
        onChange: (v) => _update({...c, 'value': v}),
        isCommonVariable: s.isCommonVariable,
        commonVariables: s.commonStringVars,
      );
    } else if (needsValue && type == MetadataVarType.number) {
      editor = ConditionNumber(
        valueMethod: _method,
        onValueMethodChange: (m) {
          setState(() => _method = m);
          _update({...c, 'value': null});
        },
        vars: s.numberVars,
        value: vm.value,
        onChange: (v) => _update({...c, 'value': v}),
        isCommonVariable: s.isCommonVariable,
        commonVariables: s.commonNumberVars,
      );
    } else if (needsValue && type == MetadataVarType.time) {
      editor = ConditionDate(
        value: c['value'] is num ? c['value']! as num : null,
        onChange: (v) => _update({...c, 'value': v}),
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: _hovered ? DifyColors.stateDestructiveHover : DifyColors.componentsInputBgNormal,
              borderRadius: BorderRadius.circular(DifyRadius.lg),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.all(4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Container(
                          height: 24,
                          padding: const EdgeInsets.only(left: 4, right: 6),
                          decoration: BoxDecoration(
                            color: DifyColors.componentsBadgeWhiteToDark,
                            borderRadius: BorderRadius.circular(DifyRadius.md),
                            border: Border.all(color: DifyColors.componentsPanelBorderSubtle, width: 0.5),
                            boxShadow: DifyShadows.xs,
                          ),
                          child: Row(
                            children: [
                              Padding(
                                padding: const EdgeInsets.all(1),
                                child: MetadataIcon(type: type, size: 12),
                              ),
                              const SizedBox(width: 2),
                              Expanded(
                                child: DifyText(
                                  jsStr(meta?['name']) ?? '',
                                  DifyType.systemXsMedium,
                                  color: DifyColors.textSecondary,
                                ),
                              ),
                              DifyText(type ?? '', DifyType.systemXsRegular, color: DifyColors.textTertiary),
                            ],
                          ),
                        ),
                      ),
                      Container(
                        width: 1,
                        height: 12,
                        margin: const EdgeInsets.symmetric(horizontal: 4),
                        color: DifyColors.dividerRegular,
                      ),
                      Flexible(
                        child: ConditionOperator(
                          disabled: widget.disabled,
                          variableType: type ?? MetadataVarType.string,
                          value: op,
                          onSelect: (o) => _update({
                            ...c,
                            'value': comparisonOperatorNotRequireValue(op) ? null : c['value'],
                            'comparison_operator': o,
                          }),
                        ),
                      ),
                    ],
                  ),
                ),
                if (editor != null)
                  Container(
                    decoration: const BoxDecoration(
                      border: Border(top: BorderSide(color: DifyColors.dividerSubtle)),
                    ),
                    child: editor,
                  ),
              ],
            ),
          ),
        ),
        MouseRegion(
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: Padding(
            padding: const EdgeInsets.only(top: 4, left: 4),
            child: DifyIconButton(
              label: _c('operation.delete'),
              tone: DifyButtonTone.destructive,
              icon: const RemixIcon('delete-bin-line', size: 16),
              onPressed: () => s.onRemoveCondition('${c['id']}'),
            ),
          ),
        ),
      ],
    );
  }
}

/// ConditionOperator: a ghost small button with the operator's label (or "Select", dimmed), opening the operators
/// of [variableType] (math symbols untranslated).
class ConditionOperator extends StatelessWidget {
  const ConditionOperator({
    super.key,
    required this.variableType,
    required this.value,
    required this.onSelect,
    this.disabled = false,
  });
  final String variableType;
  final String? value;
  final ValueChanged<String> onSelect;
  final bool disabled;

  static String label(String o) => isComparisonOperatorNeedTranslate(o) ? _w('nodes.ifElse.comparisonOperator.$o') : o;

  @override
  Widget build(BuildContext context) {
    final options = getMetadataOperators(variableType);
    final selected = options.contains(value) ? value : null;
    return _Popover(
      placement: DifyPlacement.bottomEnd,
      builder: (context, c) => _chevronButton(
        selected == null ? _w('nodes.ifElse.select') : label(selected),
        c.toggle,
        disabled: disabled,
        opacity: selected == null ? 0.5 : 1,
      ),
      popupBuilder: (context, close) => _listSurface(
        child: IntrinsicWidth(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final o in options)
                _OptionRow(
                  label: label(o),
                  onTap: () {
                    onSelect(o);
                    close();
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// ConditionValueMethod: "Variable" / "Constant" (capitalised) in a ghost small button and a `w-28` list; choosing
/// the current one does nothing.
class ConditionValueMethod extends StatelessWidget {
  const ConditionValueMethod({super.key, this.valueMethod = 'variable', required this.onValueMethodChange});
  final String valueMethod;
  final ValueChanged<String> onValueMethodChange;

  static String _cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

  @override
  Widget build(BuildContext context) {
    return _Popover(
      placement: DifyPlacement.bottomStart,
      builder: (context, c) => _chevronButton(_cap(valueMethod), c.toggle),
      popupBuilder: (context, close) => _listSurface(
        width: 112,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final o in const ['variable', 'constant'])
              _OptionRow(
                label: _cap(o),
                selected: o == valueMethod,
                radius: DifyRadius.md,
                onTap: () {
                  if (o == valueMethod) return;
                  onValueMethodChange(o);
                  close();
                },
              ),
          ],
        ),
      ),
    );
  }
}

Widget _divider() =>
    Container(width: 1, height: 16, margin: const EdgeInsets.only(left: 4, right: 6), color: DifyColors.dividerRegular);

/// ConditionString: the value method, then the variable selector (the value as `{{#node.var#}}`) or an "Enter value"
/// input.
class ConditionString extends StatelessWidget {
  const ConditionString({
    super.key,
    required this.value,
    required this.onChange,
    required this.onValueMethodChange,
    required this.vars,
    this.valueMethod = 'constant',
    this.isCommonVariable = false,
    this.commonVariables = const [],
  });
  final String? value;
  final ValueChanged<String> onChange;
  final String valueMethod;
  final ValueChanged<String> onValueMethodChange;
  final VarScope vars;
  final bool isCommonVariable;
  final List<({String name, String type, String value})> commonVariables;

  @override
  Widget build(BuildContext context) {
    final placeholder = _w('$_p.panel.placeholder');
    return SizedBox(
      height: 32,
      child: Padding(
        padding: const EdgeInsets.only(left: 4, right: 8),
        child: Row(
          children: [
            ConditionValueMethod(valueMethod: valueMethod, onValueMethodChange: onValueMethodChange),
            _divider(),
            Expanded(
              child: switch ((valueMethod, isCommonVariable)) {
                ('variable', false) => ConditionVariableSelector(
                  valueSelector: value != null && value!.isNotEmpty ? value!.split('.') : const [],
                  vars: vars,
                  varType: 'string',
                  onChange: (sel) => onChange('{{#${sel.join('.')}#}}'),
                ),
                ('variable', true) => ConditionCommonVariableSelector(
                  variables: commonVariables,
                  value: value,
                  varType: 'string',
                  onChange: (v) => onChange('{{$v}}'),
                ),
                _ => _BareInput(value: value ?? '', placeholder: placeholder, onChanged: onChange),
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// ConditionNumber: like [ConditionString], the constant typed as a number (null when blank).
class ConditionNumber extends StatelessWidget {
  const ConditionNumber({
    super.key,
    required this.value,
    required this.onChange,
    required this.onValueMethodChange,
    required this.vars,
    this.valueMethod = 'constant',
    this.isCommonVariable = false,
    this.commonVariables = const [],
  });
  final Object? value;
  final ValueChanged<Object?> onChange;
  final String valueMethod;
  final ValueChanged<String> onValueMethodChange;
  final VarScope vars;
  final bool isCommonVariable;
  final List<({String name, String type, String value})> commonVariables;

  @override
  Widget build(BuildContext context) {
    final text = value == null ? '' : jsKey(value);
    return SizedBox(
      height: 32,
      child: Padding(
        padding: const EdgeInsets.only(left: 4, right: 8),
        child: Row(
          children: [
            ConditionValueMethod(valueMethod: valueMethod, onValueMethodChange: onValueMethodChange),
            _divider(),
            Expanded(
              child: switch ((valueMethod, isCommonVariable)) {
                ('variable', false) => ConditionVariableSelector(
                  valueSelector: text.isNotEmpty ? text.split('.') : const [],
                  vars: vars,
                  varType: 'number',
                  onChange: (sel) => onChange('{{#${sel.join('.')}#}}'),
                ),
                ('variable', true) => ConditionCommonVariableSelector(
                  variables: commonVariables,
                  value: text,
                  varType: 'number',
                  onChange: (v) => onChange('{{$v}}'),
                ),
                _ => _BareInput(
                  value: text,
                  number: true,
                  placeholder: _w('$_p.panel.placeholder'),
                  onChanged: (v) => onChange(v.isEmpty ? null : (num.tryParse(v) ?? double.nan)),
                ),
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// The value input of the condition editors: borderless and transparent.
class _BareInput extends StatelessWidget {
  const _BareInput({required this.value, required this.placeholder, required this.onChanged, this.number = false});
  final String value, placeholder;
  final ValueChanged<String> onChanged;
  final bool number;

  @override
  Widget build(BuildContext context) => DifyInput(
    value: value,
    placeholder: placeholder,
    semanticLabel: placeholder,
    keyboardType: number ? const TextInputType.numberWithOptions(decimal: true, signed: true) : null,
    onChanged: onChanged,
  );
}

/// ConditionVariableSelector: the chosen variable as a short tag, or "Select variable..." with the type chip; opens
/// the `w-74` variable list.
class ConditionVariableSelector extends StatelessWidget {
  const ConditionVariableSelector({
    super.key,
    required this.valueSelector,
    required this.vars,
    required this.onChange,
    this.varType = 'string',
  });
  final List<String> valueSelector;
  final VarScope vars;
  final String varType;
  final ValueChanged<List<String>> onChange;

  @override
  Widget build(BuildContext context) {
    final sel = valueSelector;
    final node = sel.isEmpty ? null : (sel.first == 'sys' ? vars.start : vars.lookup(sel.first));
    return _Popover(
      placement: DifyPlacement.bottomStart,
      builder: (context, c) => DifyPressable(
        semanticLabel: sel.isEmpty ? _w('$_p.panel.select') : sel.join('.'),
        onPressed: c.toggle,
        builder: (context, hovered, focused) => SizedBox(
          height: 24,
          child: sel.isNotEmpty
              ? Align(
                  alignment: Alignment.centerLeft,
                  child: VariableLabel(
                    variables: sel,
                    nodeType: node?.type,
                    nodeTitle: node?.title,
                    variableType: varType,
                    notShowFullPath: true,
                  ),
                )
              : Row(
                  children: [
                    const DifyIcon(
                      'vender/solid/development/variable-02',
                      size: 16,
                      color: DifyColors.componentsInputTextPlaceholder,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: DifyText(
                        _w('$_p.panel.select'),
                        DifyType.systemSmRegular,
                        color: DifyColors.componentsInputTextPlaceholder,
                      ),
                    ),
                    DifyBadge(varType, uppercase: false),
                  ],
                ),
        ),
      ),
      popupBuilder: (context, close) => Container(
        width: 296,
        decoration: BoxDecoration(
          color: DifyColors.componentsPanelBgBlur,
          borderRadius: BorderRadius.circular(DifyRadius.lg),
          border: Border.all(color: DifyColors.componentsPanelBorder, width: 0.5),
          boxShadow: DifyShadows.lg,
        ),
        child: VarReferenceVars(
          vars: vars.vars,
          isSupportFileVar: true,
          onChange: (s, _) {
            onChange(s);
            close();
          },
        ),
      ),
    );
  }
}

/// ConditionCommonVariableSelector (common variables `{{name}}`): the chosen variable's value or "Select variable...",
/// opening the variables of [varType].
class ConditionCommonVariableSelector extends StatelessWidget {
  const ConditionCommonVariableSelector({
    super.key,
    required this.variables,
    required this.onChange,
    this.value,
    this.varType = 'string',
  });
  final List<({String name, String type, String value})> variables;
  final String? value;
  final String varType;
  final ValueChanged<String> onChange;

  @override
  Widget build(BuildContext context) {
    final selected = variables.where((v) => v.value == value).firstOrNull;
    return _Popover(
      placement: DifyPlacement.bottomStart,
      builder: (context, c) => DifyPressable(
        semanticLabel: selected?.value ?? _w('$_p.panel.select'),
        onPressed: c.toggle,
        builder: (context, hovered, focused) => SizedBox(
          height: 24,
          child: Row(
            children: [
              const DifyIcon('vender/solid/development/variable-02', size: 16, color: DifyColors.textAccent),
              const SizedBox(width: 4),
              Expanded(
                child: DifyText(
                  selected?.value ?? _w('$_p.panel.select'),
                  DifyType.systemSmRegular,
                  color: selected == null ? DifyColors.componentsInputTextPlaceholder : DifyColors.textSecondary,
                ),
              ),
              if (selected == null) DifyBadge(varType, uppercase: false),
            ],
          ),
        ),
      ),
      popupBuilder: (context, close) => _listSurface(
        width: 296,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final v in variables.where((v) => v.type == varType))
              DifyPressable(
                semanticLabel: v.value,
                onPressed: () {
                  onChange(v.value);
                  close();
                },
                builder: (context, hovered, focused) => Container(
                  height: 24,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  decoration: BoxDecoration(
                    color: hovered ? DifyColors.stateBaseHover : null,
                    borderRadius: BorderRadius.circular(DifyRadius.md),
                  ),
                  child: Row(
                    children: [
                      const DifyIcon('vender/solid/development/variable-02', size: 14, color: DifyColors.textAccent),
                      const SizedBox(width: 4),
                      Expanded(child: DifyText(v.value, DifyType.systemSmMedium, color: DifyColors.textSecondary)),
                      DifyText(v.type, DifyType.systemXsRegular, color: DifyColors.textTertiary),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

const _monthKeys = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];
const _dayKeys = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];

String _pad(int n) => '$n'.padLeft(2, '0');

/// dayjs `format('MMMM DD YYYY HH:mm A')` of [d] (local time).
String formatConditionDate(DateTime d) =>
    '${_time('months.${_monthKeys[d.month - 1]}')} ${_pad(d.day)} ${d.year} ${_pad(d.hour)}:${_pad(d.minute)} '
    '${d.hour < 12 ? 'AM' : 'PM'}';

/// ConditionDate: "Choose a time..." or the date (`MMMM DD YYYY HH:mm A`, device local time) with the calendar icon
/// and a clear button; the picker (a month grid and the time) stores unix seconds.
class ConditionDate extends StatelessWidget {
  const ConditionDate({super.key, required this.value, required this.onChange});
  final num? value;

  /// The new value in unix seconds; null when cleared.
  final ValueChanged<int?> onChange;

  @override
  Widget build(BuildContext context) {
    final v = value;
    final has = v != null && v != 0;
    final date = has ? DateTime.fromMillisecondsSinceEpoch((v * 1000).round()) : null;
    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: _Popover(
        placement: DifyPlacement.bottomStart,
        builder: (context, c) => Row(
          children: [
            Expanded(
              child: DifyPressable(
                semanticLabel: has ? formatConditionDate(date!) : _w('$_p.panel.datePlaceholder'),
                onPressed: c.toggle,
                builder: (context, hovered, focused) => Row(
                  children: [
                    Expanded(
                      child: DifyText(
                        has ? formatConditionDate(date!) : _w('$_p.panel.datePlaceholder'),
                        DifyType.systemSmRegular,
                        color: has ? DifyColors.textSecondary : DifyColors.textTertiary,
                      ),
                    ),
                    RemixIcon(
                      'calendar-line',
                      size: 16,
                      color: has ? DifyColors.textQuaternary : DifyColors.textTertiary,
                    ),
                  ],
                ),
              ),
            ),
            if (has)
              DifyIconButton(
                label: _c('operation.clear'),
                size: DifyIconButtonSize.xs,
                icon: const RemixIcon('close-circle-fill', size: 16, color: DifyColors.textQuaternary),
                onPressed: () => onChange(null),
              ),
          ],
        ),
        popupBuilder: (context, close) => _DateTimePopup(
          initial: date,
          onDone: (d) {
            close();
            onChange(d.millisecondsSinceEpoch ~/ 1000);
          },
        ),
      ),
    );
  }
}

/// The date-time picker popup: month navigation, the days of the month, hour and minute, Now and OK.
class _DateTimePopup extends StatefulWidget {
  const _DateTimePopup({required this.initial, required this.onDone});
  final DateTime? initial;
  final ValueChanged<DateTime> onDone;

  @override
  State<_DateTimePopup> createState() => _DateTimePopupState();
}

class _DateTimePopupState extends State<_DateTimePopup> {
  late DateTime _selected = widget.initial ?? DateTime.now();
  late DateTime _month = DateTime(_selected.year, _selected.month);

  @override
  Widget build(BuildContext context) {
    final first = DateTime(_month.year, _month.month);
    final lead = first.weekday % 7;
    final days = DateTime(_month.year, _month.month + 1, 0).day;
    final cells = <DateTime?>[
      for (var i = 0; i < lead; i++) null,
      for (var d = 1; d <= days; d++) DateTime(_month.year, _month.month, d),
    ];
    return Container(
      width: 252,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: DifyColors.componentsPanelBg,
        borderRadius: BorderRadius.circular(DifyRadius.xl),
        border: Border.all(color: DifyColors.componentsPanelBorder, width: 0.5),
        boxShadow: DifyShadows.lg,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: DifyText(
                  '${_time('months.${_monthKeys[_month.month - 1]}')} ${_month.year}',
                  DifyType.systemMdSemibold,
                  color: DifyColors.textPrimary,
                ),
              ),
              DifyIconButton(
                label: 'previous',
                icon: const RemixIcon('arrow-up-s-line', size: 16),
                onPressed: () => setState(() => _month = DateTime(_month.year, _month.month - 1)),
              ),
              DifyIconButton(
                label: 'next',
                icon: const RemixIcon('arrow-down-s-line', size: 16),
                onPressed: () => setState(() => _month = DateTime(_month.year, _month.month + 1)),
              ),
            ],
          ),
          const SizedBox(height: 4),
          GridView.count(
            crossAxisCount: 7,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            childAspectRatio: 1,
            children: [
              for (final d in _dayKeys)
                Center(
                  child: DifyText(_time('daysInWeek.$d'), DifyType.systemXsMedium, color: DifyColors.textTertiary),
                ),
              for (final d in cells)
                if (d == null)
                  const SizedBox()
                else
                  DifyPressable(
                    semanticLabel: '${d.day}',
                    onPressed: () => setState(
                      () => _selected = DateTime(d.year, d.month, d.day, _selected.hour, _selected.minute),
                    ),
                    builder: (context, hovered, focused) {
                      final on = d.year == _selected.year && d.month == _selected.month && d.day == _selected.day;
                      return Container(
                        margin: const EdgeInsets.all(2),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: on
                              ? DifyColors.componentsButtonPrimaryBg
                              : hovered
                              ? DifyColors.stateBaseHover
                              : null,
                          borderRadius: BorderRadius.circular(DifyRadius.lg),
                        ),
                        child: DifyText(
                          '${d.day}',
                          DifyType.systemSmMedium,
                          color: on ? DifyColors.componentsButtonPrimaryText : DifyColors.textSecondary,
                        ),
                      );
                    },
                  ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              DifyText(_time('title.pickTime'), DifyType.systemXsMedium, color: DifyColors.textTertiary),
              const Spacer(),
              SizedBox(
                width: 64,
                child: DifyNumberField(
                  value: _selected.hour,
                  min: 0,
                  max: 23,
                  semanticLabel: 'hour',
                  onChanged: (h) => setState(
                    () => _selected = DateTime(
                      _selected.year,
                      _selected.month,
                      _selected.day,
                      (h ?? 0).toInt(),
                      _selected.minute,
                    ),
                  ),
                ),
              ),
              const Padding(padding: EdgeInsets.symmetric(horizontal: 4), child: Text(':')),
              SizedBox(
                width: 64,
                child: DifyNumberField(
                  value: _selected.minute,
                  min: 0,
                  max: 59,
                  semanticLabel: 'minute',
                  onChanged: (m) => setState(
                    () => _selected = DateTime(
                      _selected.year,
                      _selected.month,
                      _selected.day,
                      _selected.hour,
                      (m ?? 0).toInt(),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              DifyButton(
                size: DifyButtonSize.small,
                variant: DifyButtonVariant.ghostAccent,
                onPressed: () => widget.onDone(DateTime.now()),
                child: Text(_time('operation.now')),
              ),
              const Spacer(),
              DifyButton(
                size: DifyButtonSize.small,
                variant: DifyButtonVariant.primary,
                onPressed: () => widget.onDone(_selected),
                child: Text(_time('operation.ok')),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
