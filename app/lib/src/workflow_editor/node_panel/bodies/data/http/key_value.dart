/// The HTTP node's key / value tables (components/key-value/**: key-value-edit index, item, input-item) and the
/// string-backed headers / params list (hooks/use-key-value-list.ts).
library;

import 'package:flutter/material.dart';

import '../../../../../cards/card_kit.dart';
import '../../../../../design/dify_icon.dart';
import '../../../../../design/dify_tokens.g.dart';
import '../../../../../design/widgets/widgets.dart';
import '../../../../panel_fields/panel_fields.dart';
import '../../../../prompt_editor/prompt_editor.dart';
import '../data_common.dart';
import 'http_model.dart';

/// What a table's cells reference: the text inputs' variables (string / number / secret; with files for form-data
/// text values), the file pickers' scope and the nodes they come from.
class KeyValueVars {
  const KeyValueVars({
    this.text = const [],
    this.textWithFiles = const [],
    this.files = const VarScope(),
    this.nodes = const {},
  });

  final List<VarGroup> text, textWithFiles;
  final VarScope files;
  final Map<String, WorkflowNodeInfo> nodes;
}

/// A table edit: the new rows, and the version the typed text began on.
typedef KeyValueChange = void Function(List<KeyValueItem> list, int? base);

/// KeyValueEdit: `overflow-hidden rounded-lg border border-divider-regular`, a 28 px header row ("Key" / ["Type"] /
/// "Value") and a row per item. Typing into the last row's empty value (or choosing its file) calls [onAdd]; with
/// more than one row each row can be removed. [isSupportFile] adds form-data's Type column (text / file).
class KeyValueTable extends StatelessWidget {
  const KeyValueTable({
    super.key,
    required this.list,
    required this.onChange,
    required this.onAdd,
    this.readonly = false,
    this.isSupportFile = false,
    this.vars = const KeyValueVars(),
    this.version,
  });

  final List<KeyValueItem> list;
  final KeyValueChange onChange;
  final VoidCallback onAdd;
  final bool readonly, isSupportFile;
  final KeyValueVars vars;
  final int Function()? version;

  @override
  Widget build(BuildContext context) {
    final header = difyStyle(DifyType.systemXsMediumUppercase, DifyColors.textTertiary);
    Widget cell(
      String text, {
      double? width,
      bool border = true,
      EdgeInsets padding = const EdgeInsets.only(left: 12),
    }) {
      final c = Container(
        height: 28,
        width: width,
        padding: padding,
        alignment: Alignment.centerLeft,
        decoration: border
            ? BoxDecoration(
                border: Border(right: BorderSide(color: DifyColors.dividerRegular)),
              )
            : null,
        child: Text(text.toUpperCase(), style: header, maxLines: 1, overflow: TextOverflow.ellipsis),
      );
      return width == null ? Expanded(child: c) : c;
    }

    return LayoutBuilder(
      builder: (context, c) {
        final keyWidth = isSupportFile ? 140.0 : (c.maxWidth - 2) / 2;
        return Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(DifyRadius.lg),
            border: Border.all(color: DifyColors.dividerRegular),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  cell(wf('nodes.http.key'), width: keyWidth),
                  if (isSupportFile) cell(wf('nodes.http.type'), width: 70),
                  cell(wf('nodes.http.value'), border: false, padding: const EdgeInsets.only(left: 12, right: 4)),
                ],
              ),
              for (final (i, item) in list.indexed)
                KeyValueRow(
                  key: ValueKey(item.id),
                  item: item,
                  keyWidth: keyWidth,
                  isLastItem: i == list.length - 1,
                  canRemove: list.length > 1,
                  readonly: readonly,
                  isSupportFile: isSupportFile,
                  vars: vars,
                  version: version,
                  onAdd: onAdd,
                  onChange: (next, base) => onChange([...list]..[i] = next, base),
                  onRemove: () => onChange([...list]..removeAt(i), null),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// KeyValueItem (item.tsx): a `min-h-7 border-t` row of the key cell, form-data's type select and the value cell (a
/// file picker for file rows).
class KeyValueRow extends StatelessWidget {
  const KeyValueRow({
    super.key,
    required this.item,
    required this.keyWidth,
    required this.isLastItem,
    required this.canRemove,
    required this.readonly,
    required this.isSupportFile,
    required this.vars,
    required this.onAdd,
    required this.onChange,
    required this.onRemove,
    this.version,
  });

  final KeyValueItem item;
  final double keyWidth;
  final bool isLastItem, canRemove, readonly, isSupportFile;
  final KeyValueVars vars;
  final VoidCallback onAdd;
  final void Function(KeyValueItem next, int? base) onChange;
  final VoidCallback onRemove;
  final int Function()? version;

  bool get _hasValue => item.type == 'file' ? (item.file?.isNotEmpty ?? false) : item.value.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final valueCell = isSupportFile && item.type == 'file'
        ? VarReferencePicker(
            value: item.file ?? const [],
            scope: vars.files,
            readonly: readonly,
            isInTable: true,
            onRemove: onRemove,
            onChange: (sel, _) {
              final addNext = isLastItem && (item.file?.isEmpty ?? true) && sel.isNotEmpty;
              onChange(item.copyWith(file: sel), null);
              if (addNext) onAdd();
            },
          )
        : KeyValueInput(
            value: item.value,
            placeholder: wf('nodes.http.value'),
            readOnly: readonly,
            hasRemove: !readonly && canRemove,
            onRemove: onRemove,
            vars: isSupportFile ? vars.textWithFiles : vars.text,
            nodes: vars.nodes,
            isSupportFileVar: isSupportFile,
            version: version,
            onEdit: (v) {
              if (isLastItem && item.value.isEmpty && v.isNotEmpty) onAdd();
            },
            onChange: (v, base) => onChange(item.copyWith(value: v), base),
          );
    final line = BoxDecoration(color: DifyColors.dividerRegular);
    return Container(
      constraints: const BoxConstraints(minHeight: 28),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: DifyColors.dividerRegular)),
      ),
      // The column lines are drawn over the row so each cell keeps its own height (no intrinsic layout).
      child: Stack(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: keyWidth - 1,
                child: KeyValueInput(
                  value: item.key,
                  placeholder: wf('nodes.http.key'),
                  readOnly: readonly,
                  vars: vars.text,
                  nodes: vars.nodes,
                  version: version,
                  onChange: (v, base) => onChange(item.copyWith(key: v), base),
                ),
              ),
              const SizedBox(width: 1),
              if (isSupportFile) ...[
                SizedBox(
                  width: 69,
                  child: _TypeSelect(
                    value: item.type ?? 'text',
                    readonly: readonly,
                    onChanged: (t) => onChange(item.copyWith(type: t), null),
                  ),
                ),
                const SizedBox(width: 1),
              ],
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: () {
                    if (isLastItem && _hasValue) onAdd();
                  },
                  child: valueCell,
                ),
              ),
            ],
          ),
          Positioned(
            left: keyWidth - 1,
            top: 0,
            bottom: 0,
            width: 1,
            child: DecoratedBox(decoration: line),
          ),
          if (isSupportFile)
            Positioned(
              left: keyWidth + 69,
              top: 0,
              bottom: 0,
              width: 1,
              child: DecoratedBox(decoration: line),
            ),
        ],
      ),
    );
  }
}

/// form-data's Type select (`h-7 rounded-none bg-transparent`, popup `w-20`).
class _TypeSelect extends StatelessWidget {
  const _TypeSelect({required this.value, required this.readonly, required this.onChanged});
  final String value;
  final bool readonly;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) => DifyDropdownMenu(
    placement: DifyPlacement.bottomStart,
    sideOffset: 4,
    width: 80,
    builder: (context, c) => Semantics(
      button: true,
      label: wf('nodes.http.type'),
      value: value,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: readonly ? null : c.toggle,
        child: Container(
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          color: c.isOpen ? DifyColors.stateBaseHover : null,
          child: Row(
            children: [
              Expanded(child: DifyText(value, DifyType.systemSmRegular, color: DifyColors.textPrimary)),
              if (!readonly) RemixIcon('arrow-down-s-line', size: 16, color: DifyColors.textQuaternary),
            ],
          ),
        ),
      ),
    ),
    children: [
      DifyMenuRadioGroup<String>(
        value: value,
        onValueChange: onChanged,
        children: [
          for (final t in const ['text', 'file'])
            DifyMenuRadioItem<String>(value: t, closeOnClick: true, child: Text(t)),
        ],
      ),
    ],
  );
}

/// InputItem (input-item.tsx): a cell's variable-capable text (`px-3 py-1`, `bg-components-input-bg-active` while
/// focused, hover `bg-state-base-hover`), placeholder "type '/' to insert variable", with the remove button after it
/// while unfocused ([hasRemove]). Read-only: the placeholder ([placeholder], `text-xs text-text-quaternary`) when empty,
/// else the value in a read-only bordered input. Text is a draft committed on blur.
class KeyValueInput extends StatefulWidget {
  const KeyValueInput({
    super.key,
    required this.value,
    required this.onChange,
    required this.placeholder,
    this.readOnly = false,
    this.hasRemove = false,
    this.onRemove,
    this.vars = const [],
    this.nodes = const {},
    this.isSupportFileVar = false,
    this.version,
    this.onEdit,
  });

  final String value;
  final TextCommit onChange;
  final String placeholder;
  final bool readOnly, hasRemove, isSupportFileVar;
  final VoidCallback? onRemove;
  final List<VarGroup> vars;
  final Map<String, WorkflowNodeInfo> nodes;
  final int Function()? version;
  final ValueChanged<String>? onEdit;

  @override
  State<KeyValueInput> createState() => _KeyValueInputState();
}

class _KeyValueInputState extends State<KeyValueInput> {
  late final _focus = FocusNode(debugLabel: 'KeyValueInput')..addListener(_focusChanged);
  late final _draft = TextDraft(widget.version);
  late String _text = widget.value;
  bool _focused = false, _hovered = false;

  @override
  void didUpdateWidget(KeyValueInput old) {
    super.didUpdateWidget(old);
    if (!_draft.isOpen) _text = widget.value;
  }

  void _focusChanged() {
    if (_focus.hasFocus == _focused) return;
    setState(() => _focused = _focus.hasFocus);
    if (!_focused) _commit();
  }

  void _commit() {
    final d = _draft.take();
    if (d != null && _text != widget.value) widget.onChange(_text, d.base);
  }

  @override
  void dispose() {
    _commit();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    if (w.readOnly) {
      if (w.value.isEmpty) {
        return Padding(
          padding: const EdgeInsets.only(left: 2, top: 1),
          child: Text(
            w.placeholder,
            style: TextStyle(fontSize: 12, height: 18 / 12, color: DifyColors.textQuaternary),
          ),
        );
      }
      return VarInput(value: w.value, onChange: w.onChange, vars: w.vars, nodesMap: w.nodes, readOnly: true);
    }
    final editor = DifyPromptEditor(
      value: _text,
      focusNode: _focus,
      placeholder: wf('nodes.http.insertVarPlaceholder'),
      isSupportFileVar: w.isSupportFileVar,
      // InputSupportSelectVar: `min-h-[20px]`, `leading-4.5`.
      minHeight: 20,
      lineHeight: 18,
      onChange: (v) {
        if (v == _text) return;
        _draft.touch();
        _text = v;
        w.onEdit?.call(v);
      },
      workflowVariableBlock: WorkflowVariableBlockConfig(show: true, variables: w.vars, workflowNodesMap: w.nodes),
    );
    return MouseRegion(
      cursor: SystemMouseCursors.text,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Container(
        color: _hovered ? DifyColors.stateBaseHover : null,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              // `px-3 py-1 min-h-8`.
              child: Container(
                constraints: const BoxConstraints(minHeight: 32),
                color: _focused ? DifyColors.componentsInputBgActive : null,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: editor,
              ),
            ),
            // Dify's RemoveButton drops the call site's `absolute hidden group-hover:block`: it sits inline, always shown.
            if (w.hasRemove && !_focused) RemoveButton(onPressed: w.onRemove),
          ],
        ),
      ),
    );
  }
}

/// use-key-value-list.ts over a `key:value` lines value: the rows (one blank row when there are none), edited
/// locally and written back serialized ([onChange], rows without key or value dropped) when that differs; the rows
/// follow [value] when it changes from outside.
class KeyValueLines extends StatefulWidget {
  const KeyValueLines({
    super.key,
    required this.value,
    required this.onChange,
    this.readonly = false,
    this.vars = const KeyValueVars(),
    this.version,
  });

  final String value;
  final TextCommit onChange;
  final bool readonly;
  final KeyValueVars vars;
  final int Function()? version;

  @override
  State<KeyValueLines> createState() => _KeyValueLinesState();
}

class _KeyValueLinesState extends State<KeyValueLines> {
  late List<KeyValueItem> _list = widget.value.isEmpty ? [] : strToKeyValueList(widget.value);
  late final _blank = KeyValueItem();

  @override
  void didUpdateWidget(KeyValueLines old) {
    super.didUpdateWidget(old);
    final target = widget.value.isEmpty ? <KeyValueItem>[] : strToKeyValueList(widget.value);
    if (stringifyKeyValueList(_list) != stringifyKeyValueList(target)) _list = target;
  }

  void _set(List<KeyValueItem> next, int? base) {
    setState(() => _list = next);
    final value = stringifyKeyValueList(next);
    if (value != widget.value) widget.onChange(value, base);
  }

  @override
  Widget build(BuildContext context) => KeyValueTable(
    list: _list.isEmpty ? [_blank] : _list,
    readonly: widget.readonly,
    vars: widget.vars,
    version: widget.version,
    onChange: _set,
    onAdd: () => _set([
      ...(_list.isEmpty ? [_blank] : _list),
      KeyValueItem(),
    ], null),
  );
}
