/// The HTTP node's Body field (components/edit-body/index.tsx).
library;

import 'package:flutter/material.dart';

import '../../../../../design/dify_tokens.g.dart';
import '../../../../../workflow/dify_json.dart';
import '../../../../panel_fields/panel_fields.dart';
import '../../../../prompt_editor/prompt_editor.dart';
import '../../../../prompt_editor/prompt_editor_panel.dart';
import '../data_common.dart';
import 'http_model.dart';
import 'key_value.dart';

/// A body edit and the version its typed text began on.
typedef BodyChange = void Function(Map<String, Object?> body, int? base);

/// EditBody: the body type radios (none, form-data, x-www-form-urlencoded, JSON, raw, binary), then the type's
/// editor: key / value tables (form-data with a Type column and file rows), a prompt editor titled "Raw text" /
/// "JSON" over [bodyVars], or a file picker ([vars]' file scope) for binary.
class EditBody extends StatelessWidget {
  const EditBody({
    super.key,
    required this.payload,
    required this.onChange,
    this.readonly = false,
    this.vars = const KeyValueVars(),
    this.bodyVars = const [],
    this.version,
  });

  final Map<String, Object?> payload;
  final BodyChange onChange;
  final bool readonly;
  final KeyValueVars vars;
  final List<VarGroup> bodyVars;
  final int Function()? version;

  @override
  Widget build(BuildContext context) {
    final type = jsStr(payload['type']) ?? 'none';
    final rows = bodyPayloadOf(payload);
    final stringValue = isKeyValueBody(type) ? '' : (jsStr(rows.firstOrNull?['value']) ?? '');
    final file = [for (final s in jsList(rows.firstOrNull?['file'])) '$s'];
    final editor = switch (type) {
      'form-data' || 'x-www-form-urlencoded' => KeyValueTable(
        list: [for (final r in rows) KeyValueItem.fromJson(r)],
        readonly: readonly,
        isSupportFile: type == 'form-data',
        vars: vars,
        version: version,
        onChange: (list, base) => onChange({
          ...payload,
          'data': [for (final i in list) i.toJson()],
        }, base),
        onAdd: () => onChange({
          ...payload,
          'data': [
            ...rows,
            {'id': keyValueId(), 'type': 'text', 'key': '', 'value': ''},
          ],
        }, null),
      ),
      'raw-text' || 'json' => _BodyText(
        key: ValueKey(type),
        title: type == 'json' ? 'JSON' : 'Raw text',
        value: stringValue,
        readonly: readonly,
        vars: bodyVars,
        nodes: vars.nodes,
        version: version,
        onChange: (v, base) => onChange(bodyWithValue(payload, v), base),
      ),
      'binary' => VarReferencePicker(
        value: file,
        scope: vars.files,
        readonly: readonly,
        onChange: (sel, _) => onChange(bodyWithFile(payload, sel), null),
      ),
      _ => null,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          children: [
            for (final (t, label) in httpBodyTypes)
              BodyTypeRadio(
                label: label,
                checked: type == t,
                disabled: readonly,
                onSelect: () => onChange(bodyOfType(t), null),
              ),
          ],
        ),
        if (editor != null) Padding(padding: const EdgeInsets.only(top: 4), child: editor),
      ],
    );
  }
}

/// A native `<input type="radio">` (Chrome's: 13 px, white in a 1 px #767676 ring; the accent's ring and dot when
/// checked) and its label (`mr-4 h-7 space-x-2`, `text-[13px] leading-4.5 text-text-secondary`).
class BodyTypeRadio extends StatelessWidget {
  const BodyTypeRadio({
    super.key,
    required this.label,
    required this.checked,
    required this.onSelect,
    this.disabled = false,
  });

  final String label;
  final bool checked, disabled;
  final VoidCallback onSelect;

  /// Chrome's default `accent-color` for form controls.
  static const _accent = Color(0xFF0075FF);

  @override
  Widget build(BuildContext context) {
    final accent = disabled ? _accent.withValues(alpha: 0.5) : _accent;
    return Semantics(
      checked: checked,
      inMutuallyExclusiveGroup: true,
      enabled: !disabled,
      label: label,
      onTap: disabled ? null : onSelect,
      child: MouseRegion(
        cursor: disabled ? SystemMouseCursors.basic : SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          excludeFromSemantics: true,
          onTap: disabled || checked ? null : onSelect,
          child: Container(
            height: 28,
            margin: const EdgeInsets.only(right: 16),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              spacing: 8,
              children: [
                Container(
                  width: 13,
                  height: 13,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(0xFFFFFFFF),
                    border: Border.all(color: checked ? accent : const Color(0xFF767676)),
                  ),
                  // Chrome's dot: 0.3 of the control's width as its radius.
                  child: checked
                      ? Container(
                          width: 13 * 0.6,
                          height: 13 * 0.6,
                          decoration: BoxDecoration(shape: BoxShape.circle, color: accent),
                        )
                      : null,
                ),
                ExcludeSemantics(
                  child: Text(
                    label,
                    style: TextStyle(fontSize: 13, height: 18 / 13, color: DifyColors.textSecondary),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The raw-text / JSON editor (prompt/editor.tsx with `justVar`): typed text is a draft committed on blur.
class _BodyText extends StatefulWidget {
  const _BodyText({
    super.key,
    required this.title,
    required this.value,
    required this.onChange,
    required this.readonly,
    required this.vars,
    required this.nodes,
    this.version,
  });

  final String title, value;
  final TextCommit onChange;
  final bool readonly;
  final List<VarGroup> vars;
  final Map<String, WorkflowNodeInfo> nodes;
  final int Function()? version;

  @override
  State<_BodyText> createState() => _BodyTextState();
}

class _BodyTextState extends State<_BodyText> {
  late final _focus = FocusNode(debugLabel: 'http body')..addListener(_focusChanged);
  late final _draft = TextDraft(widget.version);
  late String _text = widget.value;

  @override
  void didUpdateWidget(_BodyText old) {
    super.didUpdateWidget(old);
    if (!_draft.isOpen) _text = widget.value;
  }

  void _focusChanged() {
    if (!_focus.hasFocus) _commit();
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
  Widget build(BuildContext context) => DifyPromptEditorPanel(
    title: widget.title,
    value: _text,
    focusNode: _focus,
    readOnly: widget.readonly,
    justVar: true,
    nodesOutputVars: widget.vars,
    availableNodes: widget.nodes,
    onChange: (v) {
      if (v == _text) return;
      _draft.touch();
      setState(() => _text = v);
    },
  );
}
