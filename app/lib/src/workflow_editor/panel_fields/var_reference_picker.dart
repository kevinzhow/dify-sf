/// VarReferencePicker (nodes/_base/components/variable/var-reference-picker.tsx, var-reference-picker.trigger.tsx,
/// constant-field.tsx): the field that references an upstream variable.
library;

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../i18n/dify_i18n.dart';
import 'field.dart';
import 'selectors.dart';
import 'var_picker_model.dart';
import 'var_reference_vars.dart';

/// `hasErrorHandleNode` (utils/workflow.ts).
bool hasErrorHandleNode(String? type) =>
    const {'llm', 'tool', 'http-request', 'code', 'agent', 'agent-v2'}.contains(type);

/// `isExceptionVariable` (utils/variable.ts): `error_message` / `error_type` of a node with error handling.
bool isExceptionVariable(String variable, String? nodeType) =>
    (variable == 'error_message' || variable == 'error_type') && hasErrorHandleNode(nodeType);

/// Dify's `onChange(value, varKindType, varInfo)` for a variable: the selector chosen (empty when cleared) and the
/// variable it names.
typedef VarReferenceChanged = void Function(List<String> selector, PickerVar? info);

/// VarReferencePicker: shows the selected variable ([value], a value selector) as Dify's trigger does (node icon and
/// title, "…/" for nested paths, the variable icon and name, its type, an error mark when the variable no longer
/// exists, a clear button on hover) and opens the variable list from [scope] below it on a tap.
///
/// [filterVar] / [isFilterFileVar] narrow the list, [isSupportFileVar] false makes file variables unselectable.
/// With [isSupportConstantValue] a Variable / Constant selector leads the field; in constant mode [constantValue] is
/// edited in place ([constantSchema]: a select or a number) and reported with [onConstantChange]. Other trigger forms:
/// [isAddBtnTrigger] (a "+" button), [trigger] (any widget), [isInTable] (no background, a remove button on hover),
/// [isJustShowValue] (24 px, transparent). Ctrl / Cmd + tap on the node title calls [onJump] instead of opening.
class VarReferencePicker extends StatefulWidget {
  const VarReferencePicker({
    super.key,
    required this.value,
    required this.onChange,
    required this.scope,
    this.readonly = false,
    this.isShowNodeName = true,
    this.filterVar,
    this.isFilterFileVar = false,
    this.isSupportFileVar = true,
    this.isSupportConstantValue = false,
    this.defaultVarKindType = VarKindType.constant,
    this.constantValue = '',
    this.onConstantChange,
    this.onVarKindChange,
    this.constantSchema,
    this.isLoading = false,
    this.isAddBtnTrigger = false,
    this.trigger,
    this.isJustShowValue = false,
    this.isInTable = false,
    this.onRemove,
    this.typePlaceHolder,
    this.valueTypePlaceHolder,
    this.placeholder,
    this.minWidth,
    this.popupFor,
    this.preferSchemaType = false,
    this.onOpen,
    this.onJump,
    this.showManageInputField = false,
    this.onManageInputField,
  });

  final List<String> value;
  final VarReferenceChanged onChange;
  final VarScope scope;
  final bool readonly, isShowNodeName;
  final VarFilter? filterVar;
  final bool isFilterFileVar, isSupportFileVar;

  final bool isSupportConstantValue;
  final VarKindType defaultVarKindType;
  final String constantValue;
  final ValueChanged<String>? onConstantChange;
  final ValueChanged<VarKindType>? onVarKindChange;
  final ConstantSchema? constantSchema;

  /// Dynamic options are loading (a spinner by the value).
  final bool isLoading;

  final bool isAddBtnTrigger;
  final Widget? trigger;
  final bool isJustShowValue, isInTable;
  final VoidCallback? onRemove;
  final String? typePlaceHolder, valueTypePlaceHolder, placeholder;
  final double? minWidth;

  /// `assigned` / `toAssigned` (variable assigner empty states).
  final String? popupFor;
  final bool preferSchemaType;

  /// The popup opened or closed.
  final ValueChanged<bool>? onOpen;

  /// Ctrl / Cmd + tap on the node title (Dify centres the canvas on that node).
  final ValueChanged<String>? onJump;
  final bool showManageInputField;
  final VoidCallback? onManageInputField;

  @override
  State<VarReferencePicker> createState() => _VarReferencePickerState();
}

class _VarReferencePickerState extends State<VarReferencePicker> {
  final _popup = DifyFloatingController();
  final _search = FocusNode(debugLabel: 'var picker search');
  final _constantFocus = FocusNode(debugLabel: 'var picker constant');
  final _group = Object();
  late VarKindType _kind = widget.defaultVarKindType;
  late List<VarGroup> _vars = _computeVars();
  double _triggerWidth = 227;
  bool _hovered = false;

  @override
  void didUpdateWidget(VarReferencePicker old) {
    super.didUpdateWidget(old);
    if (old.scope != widget.scope ||
        old.filterVar != widget.filterVar ||
        old.isFilterFileVar != widget.isFilterFileVar) {
      _vars = _computeVars();
    }
  }

  @override
  void dispose() {
    _search.dispose();
    _constantFocus.dispose();
    super.dispose();
  }

  List<VarGroup> _computeVars() {
    var s = widget.scope;
    if (widget.filterVar != null) s = s.filtered(widget.filterVar!);
    return widget.isFilterFileVar ? removeFileVars(s.vars) : s.vars;
  }

  void _setHovered(bool v) => setState(() => _hovered = v);

  bool get _isConstant => widget.isSupportConstantValue && _kind == VarKindType.constant;

  void _select(List<String> value, PickerVar info) {
    widget.onChange(normalizeSysSelector(value), info);
    _popup.close();
  }

  void _clear() {
    if (_isConstant) {
      widget.onConstantChange?.call('');
    } else {
      widget.onChange(const [], null);
    }
  }

  void _setKind(VarKindType kind) {
    setState(() => _kind = kind);
    widget.onVarKindChange?.call(kind);
    if (kind == VarKindType.constant) {
      widget.onConstantChange?.call('');
    } else {
      widget.onChange(const [], null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final scope = w.scope;
    final value = w.value;
    final isConstant = _isConstant;
    final hasValue = pickerHasValue(isConstant, value);
    final parent = scope.parent;
    final isIterationVar = isContainerVar(parent?.type == 'iteration', value, parent?.id);
    final isLoopVar = isContainerVar(parent?.type == 'loop', value, parent?.id);
    final node = outputVarNodeOf(
      hasValue: hasValue,
      isConstant: isConstant,
      value: value,
      lookup: scope.lookup,
      isIterationVar: isIterationVar,
      isLoopVar: isLoopVar,
      iterationNode: parent?.type == 'iteration' ? parent : null,
      loopNode: parent?.type == 'loop' ? parent : null,
      startNode: scope.start,
    );
    final varName = pickerVarDisplayName(hasValue, value);
    final type = isConstant ? 'string' : (hasValue ? scope.typeOf?.call(value) : null);
    final meta = pickerVariableMeta(
      node?.type,
      value,
      varName,
      availableVars: _vars,
      canValidateSpecialVars: scope.validateSpecialVars,
      hasOutputVarNode: node != null,
    );
    final isException = isExceptionVariable(varName, node?.type);
    final showNodeName = w.isShowNodeName && !meta.isEnv && !meta.isChatVar && !meta.isGlobal && !meta.isRagVar;
    final category = pickerVariableCategory(
      isChatVar: meta.isChatVar,
      isEnv: meta.isEnv,
      isGlobal: meta.isGlobal,
      isLoopVar: isLoopVar,
      isRagVar: meta.isRagVar,
    );
    final isShowAPart = isShowAPartSelector(value);
    final hover = pickerTooltipContent(hasValue, isShowAPart, meta.isValidVar);

    return DifyFloating(
      controller: _popup,
      placement: w.isAddBtnTrigger ? DifyPlacement.bottomEnd : DifyPlacement.bottomStart,
      sideOffset: 4,
      tapRegionGroup: _group,
      initialFocus: _search,
      onOpenChange: (open) => w.onOpen?.call(open),
      builder: (context, controller) {
        void open() {
          if (!w.readonly) controller.toggle();
        }

        if (w.trigger != null) {
          return GestureDetector(behavior: HitTestBehavior.opaque, onTap: open, child: w.trigger);
        }
        return LayoutBuilder(
          builder: (context, c) {
            if (c.maxWidth.isFinite) _triggerWidth = c.maxWidth;
            final widths = pickerWidthAllocations(
              _triggerWidth,
              showNodeName ? node?.title ?? '' : '',
              varName,
              type ?? '',
            );
            Widget pill = _Pill(
              hasValue: hasValue,
              readonly: w.readonly,
              isLoading: w.isLoading,
              placeholder: w.placeholder ?? DifyI18n.tr('workflow', 'common.setVarValuePlaceholder'),
              nodeType: node?.type,
              nodeTitle: node?.title,
              showNodeName: showNodeName,
              isShowAPart: isShowAPart,
              value: value,
              category: category,
              isException: isException,
              varName: varName,
              type: type,
              showErrorIcon: hasValue && !meta.isValidVar,
              widths: widths,
              onJump: w.onJump == null ? null : () => w.onJump!(pickerOutputVarNodeId(hasValue, value)),
            );
            pill = switch (hover) {
              PickerHover.fullPath => _PreviewCard(
                card: VarFullPathPanel(
                  nodeName: node?.title ?? '',
                  path: value.sublist(1),
                  varType: varTypeToStructType(type),
                  nodeType: node?.type,
                ),
                child: pill,
              ),
              PickerHover.invalidVariable => DifyTooltip(
                content: Text(DifyI18n.tr('workflow', 'errorMsg.invalidVariable')),
                child: pill,
              ),
              null => pill,
            };
            return _Trigger(
              picker: this,
              pill: pill,
              hasValue: hasValue,
              isConstant: isConstant,
              open: controller.isOpen,
              onOpen: open,
            );
          },
        );
      },
      popupBuilder: (context) => isConstant
          ? const SizedBox.shrink()
          : VarReferencePopup(
              vars: _vars,
              onChange: _select,
              popupFor: w.popupFor,
              itemWidth: w.isAddBtnTrigger ? 260 : w.minWidth ?? _triggerWidth,
              isSupportFileVar: w.isSupportFileVar,
              preferSchemaType: w.preferSchemaType,
              searchFocusNode: _search,
              showManageInputField: w.showManageInputField,
              onManageInputField: w.onManageInputField,
              onClose: () => _popup.close(instant: true),
              tapRegionGroup: _group,
            ),
    );
  }
}

/// The trigger box around the pill (VarReferencePickerTrigger).
class _Trigger extends StatelessWidget {
  const _Trigger({
    required this.picker,
    required this.pill,
    required this.hasValue,
    required this.isConstant,
    required this.open,
    required this.onOpen,
  });

  final _VarReferencePickerState picker;
  final Widget pill;
  final bool hasValue, isConstant, open;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final w = picker.widget;
    final readonly = w.readonly;
    if (w.isAddBtnTrigger) {
      return Align(
        alignment: Alignment.centerLeft,
        child: DifyIconButton(
          label: DifyI18n.tr('common', 'operation.add'),
          size: DifyIconButtonSize.md,
          onPressed: readonly ? null : onOpen,
          icon: RemixIcon('add-line', size: 16, color: DifyColors.textTertiary),
        ),
      );
    }
    final placeholderColor = readonly
        ? DifyColors.componentsInputTextDisabled
        : DifyColors.componentsInputTextPlaceholder;
    // The variable area: in constant-capable pickers its own popover trigger on the panel background.
    Widget variablePicker = w.isSupportConstantValue
        ? Container(
            padding: const EdgeInsets.fromLTRB(4, 4, 0, 4),
            decoration: BoxDecoration(
              color: DifyColors.componentsPanelBg,
              borderRadius: BorderRadius.circular(DifyRadius.lg),
            ),
            child: Align(alignment: Alignment.centerLeft, child: pill),
          )
        : Align(alignment: Alignment.centerLeft, child: pill);
    if (w.isSupportConstantValue && !readonly) {
      variablePicker = GestureDetector(behavior: HitTestBehavior.opaque, onTap: onOpen, child: variablePicker);
    }
    final bg = w.isJustShowValue || w.isInTable
        ? null
        : readonly
        ? DifyColors.componentsInputBgDisabled
        : w.isSupportConstantValue
        ? null
        : DifyColors.componentsInputBgNormal;
    final box = Container(
      height: w.isJustShowValue ? 24 : 32,
      padding: w.isSupportConstantValue || w.isJustShowValue ? EdgeInsets.zero : const EdgeInsets.all(4),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(DifyRadius.lg)),
      child: Stack(
        alignment: Alignment.centerRight,
        children: [
          Row(
            children: [
              if (w.isSupportConstantValue)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: TypeSelector<VarKindType>(
                    noLeft: true,
                    readonly: readonly,
                    value: picker._kind,
                    showChecked: true,
                    sideOffset: 0,
                    options: varKindOptions(),
                    onChanged: picker._setKind,
                    onTriggerTap: () {
                      picker._popup.close();
                      picker._constantFocus.requestFocus();
                    },
                    trigger: Container(
                      height: 32,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      decoration: BoxDecoration(
                        color: DifyColors.componentsInputBgNormal,
                        borderRadius: BorderRadius.circular(DifyRadius.lg),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          DifyText(
                            varKindOptions().firstWhere((o) => o.value == picker._kind).label,
                            DifyType.systemSmRegular,
                            color: DifyColors.componentsInputTextFilled,
                          ),
                          const SizedBox(width: 4),
                          RemixIcon('arrow-down-s-line', size: 16, color: DifyColors.textQuaternary),
                        ],
                      ),
                    ),
                  ),
                )
              else if (!hasValue)
                Padding(
                  padding: const EdgeInsets.only(left: 6, right: 4),
                  child: DifyIcon('vender/solid/development/variable-02', size: 16, color: placeholderColor),
                ),
              Expanded(
                child: isConstant
                    ? _ConstantField(
                        value: w.constantValue,
                        schema: w.constantSchema,
                        readonly: readonly,
                        isLoading: w.isLoading,
                        focusNode: picker._constantFocus,
                        onChanged: (v) => w.onConstantChange?.call(v),
                      )
                    : variablePicker,
              ),
            ],
          ),
          if (hasValue && !readonly && !w.isInTable && !w.isJustShowValue)
            Visibility(
              visible: picker._hovered,
              maintainState: true,
              maintainAnimation: true,
              maintainSize: true,
              child: Padding(
                padding: const EdgeInsets.only(right: 0),
                child: DifyIconButton(
                  label: DifyI18n.tr('common', 'operation.clear'),
                  size: DifyIconButtonSize.sm,
                  onPressed: picker._clear,
                  icon: RemixIcon('close-line', size: 14, color: DifyColors.textTertiary),
                ),
              ),
            ),
          if (!hasValue && w.valueTypePlaceHolder != null)
            DifyBadge(w.valueTypePlaceHolder!, uppercase: false, capitalize: true),
        ],
      ),
    );
    Widget trigger = Stack(
      clipBehavior: Clip.none,
      children: [
        box,
        if (!readonly && w.isInTable && picker._hovered)
          Positioned(top: 2, right: 4, child: RemoveButton(onPressed: w.onRemove)),
        if (!hasValue && w.typePlaceHolder != null)
          Positioned(top: 6, right: 8, child: DifyBadge(w.typePlaceHolder!, uppercase: false)),
      ],
    );
    trigger = MouseRegion(
      cursor: readonly ? SystemMouseCursors.basic : SystemMouseCursors.click,
      onEnter: (_) => picker._setHovered(true),
      onExit: (_) => picker._setHovered(false),
      child: trigger,
    );
    return Semantics(
      key: const Key('var-reference-picker-trigger'),
      button: !w.isSupportConstantValue,
      child: FocusableActionDetector(
        // A variable-only picker is one button (Enter / Space open it); constant-capable ones focus their parts.
        enabled: !readonly && !w.isSupportConstantValue,
        actions: {ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => onOpen())},
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            if (readonly) return;
            if (isConstant) {
              picker._constantFocus.requestFocus();
            } else if (!w.isSupportConstantValue) {
              onOpen();
            }
          },
          child: trigger,
        ),
      ),
    );
  }
}

/// The selected variable (or the placeholder): `h-full rounded-[5px] px-1.5`, on `bg-components-badge-white-to-dark`
/// once there is a value.
class _Pill extends StatelessWidget {
  const _Pill({
    required this.hasValue,
    required this.readonly,
    required this.isLoading,
    required this.placeholder,
    required this.nodeType,
    required this.nodeTitle,
    required this.showNodeName,
    required this.isShowAPart,
    required this.value,
    required this.category,
    required this.isException,
    required this.varName,
    required this.type,
    required this.showErrorIcon,
    required this.widths,
    this.onJump,
  });

  final bool hasValue, readonly, isLoading;
  final String placeholder;
  final String? nodeType, nodeTitle;
  final bool showNodeName, isShowAPart;
  final List<String> value;
  final String category;
  final bool isException;
  final String varName;
  final String? type;
  final bool showErrorIcon;
  final ({int maxNodeNameWidth, int maxTypeWidth, int maxVarNameWidth}) widths;
  final VoidCallback? onJump;

  static DifyIcon get _line3 => DifyIcon('public/common/line-3', size: 12, color: DifyColors.dividerDeep);

  Widget _capped(double max, Widget child) => ConstrainedBox(
    constraints: BoxConstraints(maxWidth: max < 0 ? 0 : max),
    child: child,
  );

  @override
  Widget build(BuildContext context) {
    final spinner = DifySpinnerIcon(child: RemixIcon('loader-4-line', size: 14, color: DifyColors.textSecondary));
    if (!hasValue) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        alignment: Alignment.centerLeft,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isLoading) ...[spinner, const SizedBox(width: 4)],
            Flexible(
              child: DifyText(
                placeholder,
                DifyType.systemSmRegular,
                color: readonly ? DifyColors.componentsInputTextDisabled : DifyColors.componentsInputTextPlaceholder,
              ),
            ),
          ],
        ),
      );
    }
    Widget nodeLabel = ShrinkRow(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 1),
          child: nodeType == null
              ? const SizedBox(width: 12, height: 12)
              : DifyIcon(varBlockGlyph(nodeType!), size: 12, color: DifyColors.textPrimary),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: _capped(
            widths.maxNodeNameWidth.toDouble(),
            DifyText(nodeTitle ?? '', DifyType.systemXsMedium, color: DifyColors.textSecondary),
          ),
        ),
        Padding(padding: EdgeInsets.only(right: 2), child: _line3),
      ],
    );
    if (onJump != null) {
      nodeLabel = Listener(
        onPointerDown: (e) {
          final kb = HardwareKeyboard.instance;
          if (e.buttons == kPrimaryButton && (kb.isControlPressed || kb.isMetaPressed)) onJump!();
        },
        child: nodeLabel,
      );
    }
    return Container(
      height: double.infinity, // h-full
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: DifyColors.componentsBadgeWhiteToDark,
        borderRadius: BorderRadius.circular(5),
      ),
      child: ShrinkRow(
        children: [
          if (showNodeName) nodeLabel,
          if (isShowAPart) ...[
            RemixIcon('more-line', size: 12, color: DifyColors.textSecondary),
            Padding(padding: EdgeInsets.only(right: 2), child: _line3),
          ],
          if (isLoading) spinner,
          CategoryVarIcon(variables: value, category: category, isException: isException),
          Padding(
            padding: const EdgeInsets.only(left: 2),
            child: _capped(
              widths.maxVarNameWidth.toDouble(),
              DifyText(
                varName,
                DifyType.systemXsMedium,
                color: isException ? DifyColors.textWarning : DifyColors.textAccent,
              ),
            ),
          ),
          if (type != null && type!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 2),
              child: _capped(
                widths.maxTypeWidth.toDouble(),
                DifyText(cssCapitalize(type!), DifyType.systemXsRegular, color: DifyColors.textTertiary),
              ),
            ),
          if (showErrorIcon)
            Padding(
              key: Key('var-reference-picker-error-icon'),
              padding: EdgeInsets.only(left: 2),
              child: RemixIcon('error-warning-fill', size: 12, color: DifyColors.textDestructive),
            ),
        ],
      ),
    );
  }
}

/// PreviewCard: [card] shown below [child] while the mouse rests on it (300 ms in, 200 ms out) or after a long
/// press.
class _PreviewCard extends StatefulWidget {
  const _PreviewCard({required this.card, required this.child});
  final Widget card, child;

  @override
  State<_PreviewCard> createState() => _PreviewCardState();
}

class _PreviewCardState extends State<_PreviewCard> {
  final _c = DifyFloatingController();
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _schedule(bool open) {
    _timer?.cancel();
    _timer = Timer(Duration(milliseconds: open ? 300 : 200), () => open ? _c.open() : _c.close());
  }

  @override
  Widget build(BuildContext context) => DifyFloating(
    controller: _c,
    focusPopup: false,
    sideOffset: 8,
    builder: (context, _) => MouseRegion(
      onEnter: (e) => e.kind == PointerDeviceKind.mouse ? _schedule(true) : null,
      onExit: (e) => e.kind == PointerDeviceKind.mouse ? _schedule(false) : null,
      child: GestureDetector(onLongPress: _c.open, child: widget.child),
    ),
    popupBuilder: (context) => MouseRegion(
      onEnter: (_) => _timer?.cancel(),
      onExit: (_) => _schedule(false),
      child: widget.card,
    ),
  );
}

/// ConstantField: a select for `select` / `dynamic-select` schemas, a number input (`h-8 rounded-lg
/// bg-workflow-block-parma-bg p-2 text-[13px]`) for `number-input`; nothing otherwise.
class _ConstantField extends StatefulWidget {
  const _ConstantField({
    required this.value,
    required this.schema,
    required this.readonly,
    required this.isLoading,
    required this.focusNode,
    required this.onChanged,
  });

  final String value;
  final ConstantSchema? schema;
  final bool readonly, isLoading;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;

  @override
  State<_ConstantField> createState() => _ConstantFieldState();
}

class _ConstantFieldState extends State<_ConstantField> {
  late final _text = TextEditingController(text: widget.value);

  @override
  void didUpdateWidget(_ConstantField old) {
    super.didUpdateWidget(old);
    if (_text.text != widget.value) _text.text = widget.value;
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final _ConstantField(:value, :schema, :readonly, :isLoading, :focusNode, :onChanged) = widget;
    switch (schema?.type) {
      case 'select' || 'dynamic-select':
        return Focus(
          focusNode: focusNode,
          child: DifySelect<String>(
            value: schema!.options.any((o) => o.value == value) ? value : null,
            options: schema.options,
            onChanged: onChanged,
            disabled: readonly || isLoading,
          ),
        );
      case 'number-input':
        return Container(
          height: 32,
          decoration: BoxDecoration(
            color: DifyColors.workflowBlockParmaBg,
            borderRadius: BorderRadius.circular(DifyRadius.lg),
          ),
          alignment: Alignment.centerLeft,
          child: TextField(
            controller: _text,
            focusNode: focusNode,
            readOnly: readonly,
            keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
            onChanged: onChanged,
            style: TextStyle(fontSize: 13, color: DifyColors.textSecondary),
            decoration: const InputDecoration(
              isCollapsed: true,
              border: InputBorder.none,
              contentPadding: EdgeInsets.all(8),
            ),
          ),
        );
      default:
        return Focus(focusNode: focusNode, child: const SizedBox.shrink());
    }
  }
}
