/// The conversation variable modal (chat-variable-panel/components: variable-modal.tsx, variable-modal.sections.tsx).
library;

import 'package:flutter/material.dart';

import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../code_editor/code_editor.dart';
import '../panel_fields/form_controls.dart' show ArrayBoolList, BoolValue;
import '../panel_fields/var_list.dart' show varNameFormatter;
import '../store/store.dart';
import 'app_variables.dart';
import 'chat_variable_state.dart';
import 'chat_variable_values.dart';
import 'panel_kit.dart';

/// ChatVariableModal: "Add Conversation Variable", or "Edit Conversation Variable" for [chatVar] (`w-90`, `w-120`
/// for objects): name, type, value (a form or JSON for objects and arrays) and description.
class ChatVariableModal extends StatefulWidget {
  const ChatVariableModal({super.key, this.chatVar, required this.onClose, required this.onSave});
  final DifyVariable? chatVar;
  final VoidCallback onClose;
  final ValueChanged<DifyVariable> onSave;

  @override
  State<ChatVariableModal> createState() => _ChatVariableModalState();
}

class _ChatVariableModalState extends State<ChatVariableModal> {
  late final ChatVariableModalState _s;

  @override
  void initState() {
    super.initState();
    final store = WorkflowStoreScope.of(context);
    _s = ChatVariableModalState(
      chatVar: widget.chatVar,
      conversationVariables: () => store.conversationVariables.value,
      notify: _notify,
      onClose: () => widget.onClose(),
      onSave: (v) => widget.onSave(v),
    );
  }

  void _notify(String message) {
    if (mounted) toastError(context, message);
  }

  void _update(VoidCallback f) => setState(f);

  void _handleNameChange(String value) {
    if (value.isNotEmpty && !validateVariableName(value, _notify)) return setState(() {});
    _update(() => _s.handleVarNameChange(value));
  }

  @override
  Widget build(BuildContext context) {
    final s = _s;
    final toggle =
        const [
          ChatVarType.object,
          ChatVarType.arrayString,
          ChatVarType.arrayNumber,
          ChatVarType.arrayBoolean,
        ].contains(s.type)
        ? getEditorToggleLabelKey(s.type, s.editInJSON)
        : null;
    return VariableModalSurface(
      title: tw(widget.chatVar == null ? 'chatVariable.modal.title' : 'chatVariable.modal.editTitle'),
      width: s.type == ChatVarType.object ? 480 : 360,
      onClose: widget.onClose,
      onSave: () => _update(s.save),
      body: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 480),
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              NameSection(
                title: tw('chatVariable.modal.name'),
                placeholder: tw('chatVariable.modal.namePlaceholder'),
                name: s.name,
                onBlur: (name) => validateVariableName(name, _notify),
                onChange: _handleNameChange,
              ),
              TypeSection(
                title: tw('chatVariable.modal.type'),
                type: s.type,
                list: chatVarTypeList,
                onSelect: (t) => _update(() => s.handleTypeChange(t)),
              ),
              ValueSection(
                type: s.type,
                value: s.value,
                objectValue: s.objectValue,
                editInJSON: s.editInJSON,
                editorContent: s.editorContent,
                editorMinHeight: s.editorMinHeight,
                placeholder: s.placeholder,
                toggleLabelKey: toggle,
                onArrayBoolChange: (v) => _update(() => s.value = v),
                onArrayChange: (v) => _update(
                  () => s.type == ChatVarType.string || s.type == ChatVarType.number
                      ? s.handleStringOrNumberChange(v)
                      : s.value = v,
                ),
                onEditorChange: (v) => _update(() => s.handleEditorChange(v)),
                onEditorValueChange: (v) => _update(() => s.handleEditorValueChange(v)),
                onObjectChange: (v) => _update(() => s.objectValue = v),
                onValueChange: (v) => _update(() => s.value = v),
              ),
              DescriptionSection(
                title: tw('chatVariable.modal.description'),
                placeholder: tw('chatVariable.modal.descriptionPlaceholder'),
                description: s.description,
                maxLength: maxDescriptionLength,
                onChange: (v) => _update(() => s.description = v),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// NameSection: the name field (`mb-4`; spaces typed become underscores); [onBlur] gets the text when it loses
/// the focus.
class NameSection extends StatefulWidget {
  const NameSection({
    super.key,
    required this.title,
    required this.placeholder,
    required this.name,
    required this.onChange,
    required this.onBlur,
  });
  final String title, placeholder, name;
  final ValueChanged<String> onChange, onBlur;

  @override
  State<NameSection> createState() => _NameSectionState();
}

class _NameSectionState extends State<NameSection> {
  final _focus = FocusNode(debugLabel: 'variable name');
  late String _text = widget.name;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) widget.onBlur(_text);
    });
  }

  @override
  void didUpdateWidget(NameSection old) {
    super.didUpdateWidget(old);
    _text = widget.name;
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ModalSectionTitle(widget.title),
        DifyInput(
          value: widget.name,
          placeholder: widget.placeholder,
          formatters: [varNameFormatter],
          focusNode: _focus,
          onChanged: (v) {
            _text = v;
            widget.onChange(v);
          },
        ),
      ],
    ),
  );
}

/// TypeSection: the type select (`mb-4`, its popup 327 px wide).
class TypeSection extends StatelessWidget {
  const TypeSection({super.key, required this.title, required this.type, required this.list, required this.onSelect});
  final String title, type;
  final List<String> list;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ModalSectionTitle(title),
        VariableTypeSelector(value: type, list: list, onSelect: onSelect, popupWidth: 327),
      ],
    ),
  );
}

/// ValueSection: the "Default Value" title (with the form / JSON toggle named by [toggleLabelKey]) over the
/// type's editor: a textarea, a number field, True / False, the object form, the array lists, or the JSON editor
/// ([editorMinHeight] tall, [placeholder] while empty).
class ValueSection extends StatelessWidget {
  const ValueSection({
    super.key,
    required this.type,
    required this.value,
    required this.objectValue,
    required this.editInJSON,
    required this.editorMinHeight,
    required this.placeholder,
    required this.onArrayBoolChange,
    required this.onArrayChange,
    required this.onEditorChange,
    required this.onEditorValueChange,
    required this.onObjectChange,
    required this.onValueChange,
    this.editorContent,
    this.toggleLabelKey,
  });

  final String type;
  final Object? value;
  final List<ObjectValueItem> objectValue;
  final bool editInJSON;
  final String? editorContent;
  final double editorMinHeight;
  final String placeholder;
  final String? toggleLabelKey;
  final ValueChanged<List<bool>> onArrayBoolChange;
  final ValueChanged<List<Object?>> onArrayChange;
  final ValueChanged<bool> onEditorChange;
  final ValueChanged<String> onEditorValueChange;
  final ValueChanged<List<ObjectValueItem>> onObjectChange;
  final ValueChanged<bool> onValueChange;

  @override
  Widget build(BuildContext context) {
    final v = value;
    final list = v is List ? v.cast<Object?>() : null;
    final Widget editor = switch (type) {
      _ when editInJSON => Container(
        height: editorMinHeight,
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
        decoration: BoxDecoration(
          color: DifyColors.componentsInputBgNormal,
          borderRadius: BorderRadius.circular(10),
        ),
        child: DifyCodeEditor(
          isExpand: true,
          noWrapper: true,
          language: CodeLanguage.json,
          value: editorContent ?? '',
          placeholder: placeholder,
          onChange: onEditorValueChange,
        ),
      ),
      ChatVarType.string => PlainTextarea(
        value: v is String ? v : '',
        placeholder: tw('chatVariable.modal.valuePlaceholder'),
        onChanged: (t) => onArrayChange([t]),
      ),
      ChatVarType.number => OptionalNumberField(
        semanticLabel: tw('chatVariable.modal.value'),
        placeholder: tw('chatVariable.modal.valuePlaceholder'),
        value: v is num ? v : null,
        onChanged: (n) => onArrayChange([n]),
      ),
      ChatVarType.boolean => BoolValue(value: v == true, onChange: onValueChange),
      ChatVarType.object => ObjectValueList(list: objectValue, onChange: onObjectChange),
      ChatVarType.arrayString => ArrayValueList(isString: true, list: list ?? const [null], onChange: onArrayChange),
      ChatVarType.arrayNumber => ArrayValueList(isString: false, list: list ?? const [null], onChange: onArrayChange),
      ChatVarType.arrayBoolean => ArrayBoolList(
        list: list == null ? const [true] : [for (final b in list) b == true],
        onChange: onArrayBoolChange,
      ),
      _ => const SizedBox.shrink(),
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ModalSectionTitle(
            tw('chatVariable.modal.value'),
            trailing: toggleLabelKey == null
                ? null
                : DifyButton(
                    variant: DifyButtonVariant.ghost,
                    size: DifyButtonSize.small,
                    onPressed: () => onEditorChange(!editInJSON),
                    leading: RemixIcon(
                      editInJSON ? 'input-field' : 'draft-line',
                      size: 14,
                      color: DifyColors.textTertiary,
                    ),
                    child: DifyTextLine(tw(toggleLabelKey!), style: TextStyle(color: DifyColors.textTertiary)),
                  ),
          ),
          editor,
        ],
      ),
    );
  }
}

/// DescriptionSection: the description textarea and its length against [maxLength] (`mt-1 text-right
/// system-xs-regular`, destructive past the limit).
class DescriptionSection extends StatelessWidget {
  const DescriptionSection({
    super.key,
    required this.title,
    required this.placeholder,
    required this.description,
    required this.maxLength,
    required this.onChange,
  });
  final String title, placeholder, description;
  final int maxLength;
  final ValueChanged<String> onChange;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      ModalSectionTitle(title),
      PlainTextarea(value: description, placeholder: placeholder, onChanged: onChange),
      Padding(
        padding: const EdgeInsets.only(top: 4),
        child: DifyText(
          '${description.length}/$maxLength',
          DifyType.systemXsRegular,
          color: description.length > maxLength ? DifyColors.textDestructive : DifyColors.textQuaternary,
          align: TextAlign.right,
        ),
      ),
    ],
  );
}
