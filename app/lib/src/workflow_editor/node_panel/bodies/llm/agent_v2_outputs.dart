/// Agent v2's output variables (nodes/agent-v2/components/agent-output-variables/: index.tsx, edit-card.tsx,
/// type-select.tsx): the fixed `text` row and the declared outputs with their nested children, each editable in
/// place with the OutputEditCard.
library;

import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../../../design/dify_icon.dart';
import '../../../../design/dify_tokens.g.dart';
import '../../../../design/widgets/widgets.dart';
import '../../../../i18n/dify_i18n.dart';
import '../../../../workflow/dify_json.dart';
import '../../../panel_fields/panel_fields.dart';
import 'agent_v2_logic.dart';

String _w(String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr('workflow', key, params);
String _c(String key) => DifyI18n.tr('common', key);

bool _pathsEqual(List<int>? a, List<int>? b) {
  if (a == null || b == null || a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// AgentOutputVariables: "Output Variables" (a FieldCollapse, [collapsed] by the panel) over [outputs] (the system
/// `text` first); edits report the whole list with [onChange].
class AgentOutputVariables extends StatefulWidget {
  const AgentOutputVariables({
    super.key,
    required this.outputs,
    required this.onChange,
    this.collapsed,
    this.onCollapse,
    this.readOnly = false,
  });

  final List<Json> outputs;
  final ValueChanged<List<Json>> onChange;
  final bool? collapsed;
  final ValueChanged<bool>? onCollapse;
  final bool readOnly;

  @override
  State<AgentOutputVariables> createState() => AgentOutputVariablesState();
}

class AgentOutputVariablesState extends State<AgentOutputVariables> {
  OutputEditingState? _editing;
  bool _internalCollapsed = true;

  List<Json> get _outputs => widget.outputs;

  void _set(OutputEditingState? s) => setState(() => _editing = s);

  void _confirm(Json output, OutputEditingState state) {
    final i = state.outputIndex;
    final outs = _outputs;
    if (i != null && state.parentPath != null) {
      if (i >= outs.length) return;
      final child = toDeclaredOutputChild(output);
      widget.onChange([
        for (final (k, o) in outs.indexed) k == i ? insertOutputChildAtPath(o, state.parentPath!, child) : o,
      ]);
    } else if (i != null && state.childPath != null) {
      final child = toDeclaredOutputChild(output);
      widget.onChange([
        for (final (k, o) in outs.indexed) k == i ? updateOutputChildAtPath(o, state.childPath!, child) : o,
      ]);
    } else if (i != null) {
      widget.onChange([for (final (k, o) in outs.indexed) k == i ? output : o]);
    } else {
      widget.onChange([...outs, output]);
    }
    _set(null);
  }

  Widget _editCard({
    required List<Json> existing,
    required OutputEditingState state,
    int? editingIndex,
    bool allowDefaultValue = true,
    Set<String>? reservedNames,
  }) => OutputEditCard(
    key: ValueKey('edit-${state.outputIndex}-${state.childPath}-${state.parentPath}'),
    existingOutputs: existing,
    editingIndex: editingIndex,
    allowDefaultValue: allowDefaultValue,
    reservedNames: reservedNames,
    state: state,
    onCancel: () => _set(null),
    onConfirm: _confirm,
  );

  List<Widget> _children(
    Json output,
    int outputIndex,
    int depth,
    List<Json> children,
    bool editable,
    List<int> parentPath,
  ) {
    final e = _editing;
    final out = <Widget>[];
    for (final (ci, child) in children.indexed) {
      final childPath = [...parentPath, ci];
      final nested = getOutputChildren(child);
      final isEditingChild = e?.outputIndex == outputIndex && _pathsEqual(e?.childPath, childPath);
      out.add(
        ChildOutputFrame(
          depth: depth,
          child: isEditingChild
              ? _editCard(
                  existing: getOutputChildrenAtPath(output, parentPath),
                  state: e!,
                  editingIndex: ci,
                  allowDefaultValue: false,
                )
              : OutputRow(
                  output: child,
                  editable: editable && !widget.readOnly,
                  onAddChild: editable && canOutputHaveChildren(child)
                      ? () => _set((
                          draft: createDraft(),
                          outputIndex: outputIndex,
                          childPath: null,
                          parentPath: childPath,
                        ))
                      : null,
                  onDelete: () => widget.onChange([
                    for (final (k, o) in _outputs.indexed) k == outputIndex ? deleteOutputChildAtPath(o, childPath) : o,
                  ]),
                  onEdit: () => _set((
                    draft: createDraft(child),
                    outputIndex: outputIndex,
                    childPath: childPath,
                    parentPath: null,
                  )),
                ),
        ),
      );
      out.addAll(_children(output, outputIndex, depth + 1, nested, editable, childPath));
      if (e != null && e.outputIndex == outputIndex && _pathsEqual(e.parentPath, childPath)) {
        out.add(
          ChildOutputFrame(
            depth: depth + 1,
            child: _editCard(existing: nested, state: e, allowDefaultValue: false),
          ),
        );
      }
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final e = _editing;
    final outs = _outputs;
    final rows = <Widget>[];
    for (final (i, output) in outs.indexed) {
      final editable = !isDefaultOutput(output);
      final children = getOutputChildren(output);
      final isEditing = e?.outputIndex == i && e?.childPath == null && e?.parentPath == null;
      rows.add(
        isEditing
            ? _editCard(existing: outs, state: e!, editingIndex: i, reservedNames: agentV2ReservedOutputNames)
            : OutputRow(
                output: output,
                editable: editable && !widget.readOnly,
                onAddChild: editable && canOutputHaveChildren(output)
                    ? () => _set((draft: createDraft(), outputIndex: i, childPath: null, parentPath: const []))
                    : null,
                onDelete: () => widget.onChange([
                  for (final (k, o) in outs.indexed)
                    if (k != i) o,
                ]),
                onEdit: () => _set((draft: createDraft(output), outputIndex: i, childPath: null, parentPath: null)),
              ),
      );
      rows.addAll(_children(output, i, 1, children, editable, const []));
      if (e != null && e.outputIndex == i && e.parentPath != null && e.parentPath!.isEmpty) {
        rows.add(
          ChildOutputFrame(
            depth: 1,
            child: _editCard(existing: children, state: e, allowDefaultValue: false),
          ),
        );
      }
    }
    final collapsed = widget.collapsed ?? _internalCollapsed;
    return OutputVars(
      collapsed: collapsed,
      onCollapse: widget.onCollapse ?? (v) => setState(() => _internalCollapsed = v),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ...rows,
            Padding(
              padding: EdgeInsets.symmetric(vertical: 4),
              child: SizedBox(height: 1, child: ColoredBox(color: DifyColors.dividerSubtle)),
            ),
            if (e != null && e.outputIndex == null)
              _editCard(existing: outs, state: e, reservedNames: agentV2ReservedOutputNames)
            else if (!widget.readOnly)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: _NewOutputButton(
                  onPressed: () => _set((draft: createDraft(), outputIndex: null, childPath: null, parentPath: null)),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Opens the editor on an existing output (or a new one, from a task token) as Dify's FloatingOutputEditor does.
  void editOutput(OutputEditingState state) => _set(state);
}

/// The `New output` button: `h-6 w-full rounded-md bg-components-input-bg-normal`, `i-ri-add-line`.
class _NewOutputButton extends StatelessWidget {
  const _NewOutputButton({required this.onPressed});
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => DifyPressable(
    semanticLabel: _w('nodes.agent.outputVars.newOutput'),
    onPressed: onPressed,
    builder: (context, hovered, focused) => Container(
      height: 24,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: hovered ? DifyColors.stateBaseHover : DifyColors.componentsInputBgNormal,
        borderRadius: BorderRadius.circular(DifyRadius.md),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 4,
        children: [
          RemixIcon('add-line', size: 14, color: DifyColors.textSecondary),
          Flexible(
            child: DifyText(
              _w('nodes.agent.outputVars.newOutput'),
              DifyType.systemXsMedium,
              color: DifyColors.textSecondary,
            ),
          ),
        ],
      ),
    ),
  );
}

/// ChildOutputFrame: [depth] `w-5` columns with a `w-px bg-divider-subtle` line each, then [child].
class ChildOutputFrame extends StatelessWidget {
  const ChildOutputFrame({super.key, required this.depth, required this.child});
  final int depth;
  final Widget child;

  @override
  Widget build(BuildContext context) => IntrinsicHeight(
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < depth; i++)
          SizedBox(
            width: 20,
            child: Center(
              child: SizedBox(width: 1, child: ColoredBox(color: DifyColors.dividerSubtle)),
            ),
          ),
        Expanded(child: child),
      ],
    ),
  );
}

/// OutputRow: name, type, "Required", the description; hover (or focus) shows add-child / edit / delete.
class OutputRow extends StatefulWidget {
  const OutputRow({
    super.key,
    required this.output,
    required this.editable,
    required this.onDelete,
    required this.onEdit,
    this.onAddChild,
  });

  final Json output;
  final bool editable;
  final VoidCallback onDelete, onEdit;
  final VoidCallback? onAddChild;

  @override
  State<OutputRow> createState() => _OutputRowState();
}

class _OutputRowState extends State<OutputRow> {
  bool _hovered = false, _focused = false;

  @override
  Widget build(BuildContext context) {
    final o = widget.output;
    final name = jsKey(o['name']);
    final description = name == 'text' ? _w('nodes.agent.outputVars.text') : (jsStr(o['description']) ?? '');
    final show = _hovered || _focused;
    Widget action(String label, String icon, VoidCallback onPressed, {bool destructive = false}) => DifyIconButton(
      label: label,
      tone: destructive ? DifyButtonTone.destructive : DifyButtonTone.normal,
      icon: RemixIcon(icon, size: 16),
      onPressed: onPressed,
    );
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onFocusChange: (f) => setState(() => _focused = f),
        child: Container(
          constraints: const BoxConstraints(minHeight: 48),
          padding: const EdgeInsets.symmetric(vertical: 2),
          decoration: BoxDecoration(
            color: show ? DifyColors.stateBaseHover : null,
            borderRadius: BorderRadius.circular(DifyRadius.lg),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                height: 24,
                child: Padding(
                  padding: const EdgeInsets.only(left: 4, right: 2),
                  child: Row(
                    children: [
                      Flexible(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: DifyText(name, DifyType.codeSmSemibold),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: DifyText(
                          getOutputDisplayType(o),
                          DifyType.systemXsMedium,
                          color: DifyColors.textTertiary,
                        ),
                      ),
                      if (o['required'] == true)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: DifyText(
                            _w('nodes.agent.outputVars.requiredLabel'),
                            DifyType.system2xsMediumUppercase,
                            color: DifyColors.textWarning,
                          ),
                        ),
                      const Spacer(),
                      if (widget.editable)
                        Opacity(
                          opacity: show ? 1 : 0,
                          alwaysIncludeSemantics: true,
                          child: Row(
                            spacing: 2,
                            children: [
                              if (widget.onAddChild != null)
                                action('${_c('operation.add')} $name', 'add-circle-line', widget.onAddChild!),
                              action(_w('nodes.agent.outputVars.edit', {'name': name}), 'pencil-line', widget.onEdit),
                              action(
                                _w('nodes.agent.outputVars.delete', {'name': name}),
                                'delete-bin-line',
                                widget.onDelete,
                                destructive: true,
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              if (description.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
                  child: DifyText(description, DifyType.systemXsRegular, color: DifyColors.textTertiary),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A borderless one-line input (the edit card's name and description), labelled for assistive tech.
class _LineInput extends StatefulWidget {
  const _LineInput({
    super.key,
    required this.value,
    required this.onChanged,
    required this.label,
    required this.placeholder,
    required this.style,
    this.focusNode,
    this.box = false,
  });
  final String value, label, placeholder;
  final ValueChanged<String> onChanged;
  final TextStyle style;
  final FocusNode? focusNode;

  /// The name input's `rounded-md` input box.
  final bool box;

  @override
  State<_LineInput> createState() => _LineInputState();
}

class _LineInputState extends State<_LineInput> {
  late final _text = TextEditingController(text: widget.value);

  @override
  void didUpdateWidget(_LineInput old) {
    super.didUpdateWidget(old);
    if (widget.value != _text.text) _text.text = widget.value;
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: widget.label,
    textField: true,
    child: Container(
      padding: EdgeInsets.symmetric(horizontal: widget.box ? 6 : 4),
      alignment: Alignment.centerLeft,
      decoration: widget.box
          ? BoxDecoration(
              color: DifyColors.componentsInputBgNormal,
              borderRadius: BorderRadius.circular(DifyRadius.md),
            )
          : null,
      child: DifySurface(
        child: DifyTextField(
          controller: _text,
          focusNode: widget.focusNode,
          onChanged: widget.onChanged,
          style: widget.style,
          cursorWidth: 1,
          maxLines: 1,
          decoration: DifyFieldDecoration(
            hintText: widget.placeholder,
            hintStyle: widget.style.copyWith(color: DifyColors.componentsInputTextPlaceholder),
          ),
        ),
      ),
    ),
  );
}

/// OutputEditCard: name (`w-24`), type, Required; the name error; the description; "Show advanced options" with the
/// default value (top-level outputs only); Cancel / Confirm. Mod+Enter confirms and Escape cancels while the focus is
/// inside the card.
class OutputEditCard extends StatefulWidget {
  const OutputEditCard({
    super.key,
    required this.existingOutputs,
    required this.state,
    required this.onCancel,
    required this.onConfirm,
    this.editingIndex,
    this.allowDefaultValue = true,
    this.reservedNames,
  });

  final List<Json> existingOutputs;
  final OutputEditingState state;
  final VoidCallback onCancel;
  final void Function(Json output, OutputEditingState state) onConfirm;
  final int? editingIndex;
  final bool allowDefaultValue;
  final Set<String>? reservedNames;

  @override
  State<OutputEditCard> createState() => _OutputEditCardState();
}

class _OutputEditCardState extends State<OutputEditCard> {
  late OutputDraft _draft = widget.state.draft;
  final _nameFocus = FocusNode(debugLabel: 'output name');
  bool _advancedOpen = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _nameFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _nameFocus.dispose();
    super.dispose();
  }

  String get _trimmed => _draft.name.trim();
  bool get _duplicate =>
      widget.existingOutputs.indexed.any((e) => e.$2['name'] == _trimmed && e.$1 != widget.editingIndex);
  bool get _invalid => _trimmed.isNotEmpty && !outputNamePattern.hasMatch(_trimmed);
  bool get _reserved => widget.reservedNames?.contains(_trimmed) ?? false;
  String? get _defaultError => getDefaultValueErrorKey(_draft);
  bool get _confirmDisabled => _trimmed.isEmpty || _invalid || _duplicate || _reserved || _defaultError != null;

  void _confirm() {
    if (_confirmDisabled) return;
    widget.onConfirm(createOutputFromDraft(_draft, includeDefaultValue: widget.allowDefaultValue), widget.state);
  }

  void _update(OutputDraft d) => setState(() => _draft = d);

  @override
  Widget build(BuildContext context) {
    final hasNameError = _duplicate || _invalid || _reserved;
    final defaultError = _defaultError;
    final card = Semantics(
      container: true,
      role: SemanticsRole.form,
      label: _w('nodes.agent.outputVars.editorLabel'),
      explicitChildNodes: true,
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: DifyColors.componentsPanelBg,
          borderRadius: BorderRadius.circular(DifyRadius.xl),
          border: Border.all(color: DifyColors.componentsPanelBorder),
          boxShadow: DifyShadows.md,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    height: 24,
                    child: Row(
                      spacing: 8,
                      children: [
                        SizedBox(
                          width: 96,
                          height: 24,
                          child: _LineInput(
                            key: const ValueKey('output-name'),
                            box: true,
                            focusNode: _nameFocus,
                            value: _draft.name,
                            label: _w('nodes.agent.outputVars.nameLabel'),
                            placeholder: _w('nodes.agent.outputVars.namePlaceholder'),
                            style: difyStyle(DifyType.codeSmSemibold, DifyColors.textPrimary),
                            onChanged: (v) => _update(draftWith(_draft, name: v)),
                          ),
                        ),
                        OutputTypeSelect(
                          value: _draft.type,
                          onChange: (v) => _update(draftWith(_draft, type: v)),
                        ),
                        Flexible(
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            spacing: 4,
                            children: [
                              DifySwitch(
                                size: DifySwitchSize.xs,
                                checked: _draft.required,
                                semanticLabel: _w('nodes.agent.outputVars.requiredLabel'),
                                onCheckedChange: (v) => _update(draftWith(_draft, required: v)),
                              ),
                              Flexible(
                                child: DifyText(
                                  _w('nodes.agent.outputVars.requiredLabel'),
                                  DifyType.systemXsRegular,
                                  color: DifyColors.textTertiary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (hasNameError)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
                      child: DifyText(
                        _duplicate
                            ? _w('nodes.agent.outputVars.nameDuplicate')
                            : _w('nodes.agent.outputVars.nameInvalid'),
                        DifyType.systemXsRegular,
                        color: DifyColors.textDestructive,
                        maxLines: null,
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: SizedBox(
                      height: 20,
                      child: _LineInput(
                        key: const ValueKey('output-description'),
                        value: _draft.description,
                        label: _w('nodes.agent.outputVars.descriptionLabel'),
                        placeholder: _w('nodes.agent.outputVars.descriptionPlaceholder'),
                        style: difyStyle(DifyType.systemXsRegular, DifyColors.textSecondary),
                        onChanged: (v) => _update(draftWith(_draft, description: v)),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (widget.allowDefaultValue) ...[
              const SizedBox(height: 8),
              Semantics(
                button: true,
                expanded: _advancedOpen,
                label: _w('nodes.agent.outputVars.showAdvancedOptions'),
                excludeSemantics: true,
                onTap: () => setState(() => _advancedOpen = !_advancedOpen),
                child: DifyPressable(
                  onPressed: () => setState(() => _advancedOpen = !_advancedOpen),
                  builder: (context, hovered, focused) => Container(
                    height: 32,
                    padding: const EdgeInsets.only(left: 10, right: 8),
                    decoration: BoxDecoration(
                      color: hovered || focused ? DifyColors.stateBaseHover : null,
                      border: Border.symmetric(horizontal: BorderSide(color: DifyColors.dividerSubtle)),
                    ),
                    child: Row(
                      spacing: 2,
                      children: [
                        AnimatedRotation(
                          turns: _advancedOpen ? 0.5 : 0,
                          duration: const Duration(milliseconds: 100),
                          child: RemixIcon('arrow-down-double-line', size: 12, color: DifyColors.textTertiary),
                        ),
                        Flexible(
                          child: DifyText(
                            _w('nodes.agent.outputVars.showAdvancedOptions'),
                            DifyType.systemXsRegular,
                            color: DifyColors.textTertiary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (_advancedOpen)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    spacing: 4,
                    children: [
                      DifyText(
                        _w('nodes.agent.outputVars.defaultValueLabel'),
                        DifyType.systemXsMedium,
                        color: DifyColors.textSecondary,
                      ),
                      DifyInput(
                        key: const ValueKey('output-default'),
                        value: _draft.defaultValue,
                        semanticLabel: _w('nodes.agent.outputVars.defaultValueLabel'),
                        placeholder: _w('nodes.agent.outputVars.defaultValuePlaceholder'),
                        onChanged: (v) => _update(draftWith(_draft, defaultValue: v)),
                      ),
                      if (defaultError != null)
                        DifyText(_w(defaultError), DifyType.systemXsRegular, color: DifyColors.textDestructive),
                    ],
                  ),
                ),
            ],
            SizedBox(
              height: 48,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  spacing: 8,
                  children: [
                    Flexible(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: DifyButton(
                          size: DifyButtonSize.small,
                          onPressed: widget.onCancel,
                          child: DifyTextLine(_c('operation.cancel')),
                        ),
                      ),
                    ),
                    Flexible(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: DifyButton(
                          size: DifyButtonSize.small,
                          variant: DifyButtonVariant.primary,
                          disabled: _confirmDisabled,
                          semanticLabel: _w('nodes.agent.outputVars.confirm'),
                          onPressed: _confirm,
                          trailing: const DifyShortcutKbd(hotkey: 'Mod+Enter', color: DifyKbdColor.white),
                          child: DifyTextLine(_w('nodes.agent.outputVars.confirm')),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter, control: true): _confirm,
        const SingleActivator(LogicalKeyboardKey.enter, meta: true): _confirm,
        const SingleActivator(LogicalKeyboardKey.escape): widget.onCancel,
      },
      child: card,
    );
  }
}

/// OutputTypeSelect: the type's label (`h-6 px-1 system-xs-medium text-text-tertiary`), a `w-40` list.
class OutputTypeSelect extends StatelessWidget {
  const OutputTypeSelect({super.key, required this.value, required this.onChange});
  final String value;
  final ValueChanged<String> onChange;

  @override
  Widget build(BuildContext context) {
    final selected = getOutputTypeOption(value);
    final label = _w('nodes.agent.outputVars.typeLabel');
    return DifyDropdownMenu(
      placement: DifyPlacement.bottomStart,
      sideOffset: 4,
      width: 160,
      semanticLabel: label,
      builder: (context, c) => DifyPressable(
        semanticLabel: label,
        onPressed: c.toggle,
        builder: (context, hovered, focused) => Container(
          height: 24,
          padding: const EdgeInsets.symmetric(horizontal: 4),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: hovered || c.isOpen ? DifyColors.stateBaseHover : null,
            borderRadius: BorderRadius.circular(DifyRadius.md),
          ),
          child: DifyText(selected.label, DifyType.systemXsMedium, color: DifyColors.textTertiary),
        ),
      ),
      children: [
        for (final o in outputTypeOptions)
          DifyMenuItem(
            semanticLabel: o.label,
            onSelect: () => onChange(o.value),
            trailing: o.value == value ? RemixIcon('check-line', size: 16, color: DifyColors.textAccent) : null,
            child: DifyTextLine(o.label),
          ),
      ],
    );
  }
}
