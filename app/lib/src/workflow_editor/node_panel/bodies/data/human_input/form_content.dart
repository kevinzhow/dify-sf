/// The Form Content editor (components/form-content.tsx) with the form input fields of
/// base/prompt-editor/plugins/hitl-input-block (the chip of component-ui.tsx, input-field.tsx, pre-populate.tsx,
/// type-switch.tsx, tag-label.tsx).
///
/// dify-sf's prompt editor has no HITL block, so the content is edited as the text between its `{{#$output.x#}}`
/// tokens: one prompt editor per run of text, the input field chips between them (Dify's chip is a full-width block
/// too). Mod + / in a run inserts a field at the caret.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../../cards/card_kit.dart';
import '../../../../../design/css_metrics.dart';
import '../../../../../design/dify_icon.dart';
import '../../../../../design/dify_tokens.g.dart';
import '../../../../../design/widgets/widgets.dart';
import '../../../../../i18n/dify_i18n.dart';
import '../../../../../workflow/dify_json.dart';
import '../../../../../workflow/var_types.dart';
import '../../../../panel_fields/panel_fields.dart';
import '../../../../prompt_editor/prompt_editor.dart';
import '../data_common.dart';
import 'human_input_kit.dart';
import 'human_input_model.dart';

/// The content split at its form inputs: `texts.length == names.length + 1`.
({List<String> texts, List<String> names}) splitFormContent(String content) {
  final texts = <String>[], names = <String>[];
  var last = 0;
  for (final m in hitlInputRegex.allMatches(content)) {
    texts.add(content.substring(last, m.start));
    names.add(m[1]!.substring('#\$output.'.length, m[1]!.length - 1));
    last = m.end;
  }
  texts.add(content.substring(last));
  return (texts: texts, names: names);
}

/// The content of [texts] and the inputs [names] between them.
String joinFormContent(List<String> texts, List<String> names) {
  final b = StringBuffer();
  for (var i = 0; i < texts.length; i++) {
    b.write(texts[i]);
    if (i < names.length) b.write(outputToken(names[i]));
  }
  return b.toString();
}

/// The label of a form input type (`appDebug.variableConfig.*`).
String formInputTypeLabel(Object? input) => DifyI18n.tr('app-debug', switch (inputTypeOf(input)) {
  FormInputType.select => 'variableConfig.select',
  FormInputType.singleFile => 'variableConfig.single-file',
  FormInputType.multiFiles => 'variableConfig.multi-files',
  _ => 'variableConfig.paragraph',
});

/// What changes the editor reports.
@immutable
class FormContentActions {
  const FormContentActions({
    required this.onChange,
    required this.onInsert,
    required this.onInputChange,
    required this.onRename,
    required this.onRemove,
  });

  /// The typed content, with the version its draft began on.
  final TextCommit onChange;

  /// A new input [payload] and the content with its token inserted (one edit: Dify defers the inputs until the
  /// content changed, so neither overwrites the other).
  final void Function(Map<String, Object?> payload, String content) onInsert;

  /// The inputs list with an input edited in place (same name).
  final ValueChanged<List<Object?>> onInputChange;

  /// `handleFormInputItemRename(payload, oldName)`.
  final void Function(Map<String, Object?> payload, String oldName) onRename;

  /// `handleFormInputItemRemove(name)`.
  final ValueChanged<String> onRemove;
}

/// FormContent: the editor box (`rounded-[10px] bg-components-input-bg-normal pt-1`, active border / bg while
/// focused, else `pb-8`), `max-h-75` scrolling (filling the height when [isExpand]); while focused, the hotkey tip
/// footer. [scope] is the variables on offer (string, number, secret, array[string]).
class FormContent extends StatefulWidget {
  const FormContent({
    super.key,
    required this.nodeId,
    required this.value,
    required this.formInputs,
    required this.actions,
    required this.scope,
    this.nodesMap = const {},
    this.isExpand = false,
    this.readonly = false,
    this.version,
  });

  final String nodeId, value;
  final List<Object?> formInputs;
  final FormContentActions actions;
  final VarScope scope;
  final Map<String, WorkflowNodeInfo> nodesMap;
  final bool isExpand, readonly;
  final int Function()? version;

  @override
  State<FormContent> createState() => _FormContentState();
}

class _FormContentState extends State<FormContent> {
  late final _draft = TextDraft(widget.version);
  late var _split = splitFormContent(widget.value);
  final _controllers = <PromptEditorController>[];
  final _focuses = <FocusNode>[];
  int _gen = 0;
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _ensure();
  }

  @override
  void didUpdateWidget(FormContent old) {
    super.didUpdateWidget(old);
    if (!_draft.isOpen && widget.value != joinFormContent(_split.texts, _split.names)) {
      final next = splitFormContent(widget.value);
      if (!listEquals(next.names, _split.names)) _gen++;
      _split = next;
      _ensure();
    }
  }

  /// One controller and focus node per text run.
  void _ensure() {
    while (_controllers.length < _split.texts.length) {
      final i = _controllers.length;
      _controllers.add(PromptEditorController());
      _focuses.add(FocusNode(debugLabel: 'form content $i', onKeyEvent: (_, e) => _onKey(i, e)));
    }
    while (_controllers.length > _split.texts.length) {
      _controllers.removeLast().dispose();
      _focuses.removeLast().dispose();
    }
  }

  @override
  void dispose() {
    _commit();
    for (final c in _controllers) {
      c.dispose();
    }
    for (final f in _focuses) {
      f.dispose();
    }
    super.dispose();
  }

  String get _content => joinFormContent(_split.texts, _split.names);

  void _commit() {
    final d = _draft.take();
    if (d != null && _content != widget.value) widget.actions.onChange(_content, d.base);
  }

  KeyEventResult _onKey(int i, KeyEvent e) {
    if (e is! KeyDownEvent || widget.readonly) return KeyEventResult.ignored;
    final kb = HardwareKeyboard.instance;
    if ((kb.isControlPressed || kb.isMetaPressed) && e.logicalKey == LogicalKeyboardKey.slash) {
      _insertAt(i);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// What run [i] shows of its text: Dify's editor puts each input field in a paragraph of its own, so the line
  /// break that ends the paragraph before a field ([trail]) and the one that ends the field's paragraph ([lead], at
  /// the start of the run after it) are no lines of their own.
  ({String lead, String shown, String trail}) _shown(int i) {
    final text = _split.texts[i];
    final lead = i > 0 && text.startsWith('\n') ? '\n' : '';
    final rest = text.substring(lead.length);
    final trail = i < _split.names.length && rest.endsWith('\n') ? '\n' : '';
    return (lead: lead, shown: rest.substring(0, rest.length - trail.length), trail: trail);
  }

  /// The shortcut popup: a new input field inserted at the caret of run [i].
  Future<void> _insertAt(int i) async {
    final c = _controllers[i], s = _shown(i);
    final sel = c.selection.isValid ? c.selection : TextSelection.collapsed(offset: c.text.length);
    final before = s.lead + c.serialize(0, sel.start), after = c.serialize(sel.end, c.text.length) + s.trail;
    final texts = [..._split.texts], names = [..._split.names];
    final unavailable = [for (final x in widget.formInputs) inputNameOf(x)];
    final payload = await showInputFieldDialog(context, scope: widget.scope, unavailable: unavailable);
    if (payload == null || !mounted) return;
    final name = inputNameOf(payload);
    if (widget.formInputs.any((x) => inputNameOf(x) == name)) return;
    texts
      ..[i] = before
      ..insert(i + 1, after);
    names.insert(i, name);
    widget.actions.onInsert(payload, joinFormContent(texts, names));
  }

  void _edited(int i, String text) {
    if (text == _split.texts[i]) return;
    _draft.touch();
    _split.texts[i] = text;
  }

  Map<String, Object?>? _inputNamed(String name) =>
      switch (widget.formInputs.where((x) => inputNameOf(x) == name).firstOrNull) {
        final Map<String, Object?> m => m,
        _ => null,
      };

  void _chipChange(String name, Map<String, Object?> payload) {
    final others = [
      for (final x in widget.formInputs)
        if (inputNameOf(x) != name) inputNameOf(x),
    ];
    final newName = inputNameOf(payload);
    if (newName != name && others.contains(newName)) return;
    if (newName != name) {
      widget.actions.onRename(payload, name);
    } else if (_inputNamed(name) == null) {
      widget.actions.onInputChange([...widget.formInputs, payload]);
    } else {
      widget.actions.onInputChange([for (final x in widget.formInputs) inputNameOf(x) == name ? payload : x]);
    }
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final empty = w.value.isEmpty && _split.texts.length == 1 && _split.texts.first.isEmpty;
    final runs = <Widget>[];
    for (var i = 0; i < _split.texts.length; i++) {
      final s = _shown(i);
      Widget run = DifyPromptEditor(
        key: ValueKey('form-content-$_gen-$i'),
        value: s.shown,
        controller: _controllers[i],
        focusNode: _focuses[i],
        editable: !w.readonly,
        minHeight: i == 0 ? 80 : 24,
        semanticLabel: i == 0 ? hi('formContent.title') : null,
        placeholder: i == 0 && empty ? hi('formContent.placeholder') : '',
        onChange: (v) => _edited(i, '${s.lead}$v${s.trail}'),
        workflowVariableBlock: WorkflowVariableBlockConfig(
          show: true,
          variables: w.scope.vars,
          workflowNodesMap: w.nodesMap,
        ),
      );
      // Nothing after the last field: it ends the content, no empty line under it until the run is edited (a tap
      // below the content goes there).
      if (i > 0 && i == _split.names.length && _split.texts[i].isEmpty && !_focuses[i].hasFocus) {
        run = SizedBox(
          height: 0,
          child: ClipRect(
            child: OverflowBox(alignment: Alignment.topCenter, child: run),
          ),
        );
      }
      runs.add(run);
      if (i < _split.names.length) {
        final name = _split.names[i];
        runs.add(
          Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 4),
            child: InputFieldChip(
              key: ValueKey('chip-$name'),
              varName: name,
              formInput: _inputNamed(name),
              unavailable: [
                for (final x in w.formInputs)
                  if (inputNameOf(x) != name) inputNameOf(x),
              ],
              scope: w.scope,
              nodesMap: w.nodesMap,
              readonly: w.readonly,
              onChange: (p) => _chipChange(name, p),
              onRemove: () => w.actions.onRemove(name),
            ),
          ),
        );
      }
    }
    Widget scroll = SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: runs),
    );
    scroll = w.isExpand
        ? Expanded(child: scroll)
        : ConstrainedBox(constraints: const BoxConstraints(maxHeight: 300), child: scroll);
    final box = Container(
      padding: EdgeInsets.only(top: 4, bottom: _focused ? 0 : 32),
      decoration: BoxDecoration(
        color: _focused ? DifyColors.componentsInputBgActive : DifyColors.componentsInputBgNormal,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: _focused ? DifyColors.componentsInputBorderActive : DifyColors.componentsInputBgNormal,
        ),
      ),
      child: Column(
        mainAxisSize: w.isExpand ? MainAxisSize.max : MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [scroll, if (_focused) const _HotkeyTip()],
      ),
    );
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (f) {
        setState(() => _focused = f);
        if (!f) _commit();
      },
      child: IgnorePointer(
        ignoring: w.readonly,
        // A tap below the content (not on a run) edits its end.
        child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: _focuses.last.requestFocus, child: box),
      ),
    );
  }
}

/// `formatForDisplay('Mod')`.
String get modKeyLabel =>
    defaultTargetPlatform == TargetPlatform.macOS || defaultTargetPlatform == TargetPlatform.iOS ? '⌘' : 'Ctrl';

/// The focus footer: "Press / to insert variable, Mod / to insert input field" with key caps.
class _HotkeyTip extends StatelessWidget {
  const _HotkeyTip();

  @override
  Widget build(BuildContext context) {
    WidgetSpan kbd(String k) => WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: Padding(padding: const EdgeInsets.symmetric(horizontal: 2), child: DifyKbd(k)),
    );
    return SizedBox(
      height: 32,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text.rich(
            TextSpan(
              children: transSpans(hi('formContent.hotkeyTip'), {
                'Key': (_) => kbd('/'),
                'CtrlKey': (_) => kbd(modKeyLabel),
              }),
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: difyStyle(DifyType.systemXsRegular, DifyColors.componentsInputTextPlaceholder),
          ),
        ),
      ),
    );
  }
}

/// HITLInputComponentUI: a 32 px chip (`rounded-lg border-[1.5px] border-components-input-border-active
/// bg-background-default-hover`) with the name tag on its top edge (`VariableX` + name), the variable it pre-fills
/// from or a summary (the default text, the options, the type), the type label, and on hover Edit (the input field
/// dialog) and Remove.
class InputFieldChip extends StatefulWidget {
  const InputFieldChip({
    super.key,
    required this.varName,
    required this.formInput,
    required this.onChange,
    required this.onRemove,
    required this.scope,
    this.unavailable = const [],
    this.nodesMap = const {},
    this.readonly = false,
  });

  final String varName;
  final Map<String, Object?>? formInput;
  final ValueChanged<Map<String, Object?>> onChange;
  final VoidCallback onRemove;
  final VarScope scope;
  final List<String> unavailable;
  final Map<String, WorkflowNodeInfo> nodesMap;
  final bool readonly;

  @override
  State<InputFieldChip> createState() => _InputFieldChipState();
}

class _InputFieldChipState extends State<InputFieldChip> {
  bool _hovered = false;

  Future<void> _edit() async {
    final w = widget;
    final r = await showInputFieldDialog(
      context,
      scope: w.scope,
      payload: w.formInput,
      unavailable: w.unavailable,
      isEdit: true,
    );
    if (r != null) w.onChange(r);
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final input = w.formInput ?? createDefaultParagraphFormInput(w.varName);
    final typeLabel = formInputTypeLabel(input);
    final def = jsGet(input, 'default'), source = jsGet(input, 'option_source');
    List<String> strings(Object? x) => [for (final e in jsList(x)) jsKey(e)];
    final selector = isParagraphFormInput(input) && jsGet(def, 'type') == 'variable'
        ? strings(jsGet(def, 'selector'))
        : isSelectFormInput(input) && jsGet(source, 'type') == 'variable'
        ? strings(jsGet(source, 'selector'))
        : null;
    final summary = isParagraphFormInput(input)
        ? (jsTruthy(jsGet(def, 'value')) ? '${jsGet(def, 'value')}' : typeLabel)
        : isSelectFormInput(input)
        ? (jsGet(source, 'type') == 'variable'
              ? hi('insertInputField.variable')
              : (strings(jsGet(source, 'value')).join(', ').isEmpty
                    ? typeLabel
                    : strings(jsGet(source, 'value')).join(', ')))
        : typeLabel;
    Widget? label;
    if (selector != null) {
      final node = w.nodesMap[isSystemVar(selector) ? 'sys' : selector.firstOrNull ?? ''];
      label = VariableLabel(
        variables: selector,
        nodeType: node?.type,
        nodeTitle: node?.title,
        variant: VarLabelStyle.inEditor,
        notShowFullPath: selector.length > 2,
        errorMsg: node == null && !isEnvVar(selector) && !isConversationVar(selector) && !isGlobalVar(selector)
            ? wf('errorMsg.invalidVariable')
            : null,
      );
    }
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            height: 32,
            padding: const EdgeInsets.only(left: 6, right: 2),
            decoration: BoxDecoration(
              color: DifyColors.backgroundDefaultHover,
              borderRadius: BorderRadius.circular(DifyRadius.lg),
              border: Border.all(color: DifyColors.componentsInputBorderActive, width: 1.5),
            ),
            child: Row(
              spacing: 8,
              children: [
                Expanded(
                  child:
                      label ?? DifyText(summary, DifyType.systemXsMedium, color: DifyColors.componentsInputTextFilled),
                ),
                DifyText(typeLabel.toUpperCase(), DifyType.system2xsMedium, color: DifyColors.textTertiary),
                if (!w.readonly && _hovered) ...[
                  DifyIconButton(
                    label: cm('operation.edit'),
                    size: DifyIconButtonSize.sm,
                    onPressed: _edit,
                    icon: const RemixIcon('edit-line', size: 16, color: DifyColors.textTertiary),
                  ),
                  DifyIconButton(
                    label: cm('operation.remove'),
                    size: DifyIconButtonSize.sm,
                    onPressed: w.onRemove,
                    icon: const RemixIcon('delete-bin-line', size: 16, color: DifyColors.textTertiary),
                  ),
                ] else
                  const SizedBox(width: 20),
              ],
            ),
          ),
          // `absolute -top-3 left-2.5` from inside the 1.5 px border; only a `bottom-1 h-[1.5px]` strip behind the
          // name hides the border line.
          Positioned(
            top: -12 + 1.5,
            left: 10 + 1.5,
            child: Stack(
              children: [
                const Positioned(
                  left: 0,
                  right: 0,
                  bottom: 4,
                  height: 1.5,
                  child: ColoredBox(color: DifyColors.backgroundDefaultSubtle),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    spacing: 2,
                    children: [
                      const DifyIcon(
                        'vender/workflow/variable-x',
                        size: 12,
                        color: DifyColors.textAccentLightModeOnly,
                      ),
                      DifyText(w.varName, DifyType.systemXsMedium, color: DifyColors.textAccentLightModeOnly),
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

/// Shows the Insert / Edit Input Field popup; the input saved, or null when cancelled.
Future<Map<String, Object?>?> showInputFieldDialog(
  BuildContext context, {
  required VarScope scope,
  Map<String, Object?>? payload,
  List<String> unavailable = const [],
  bool isEdit = false,
}) => showDifyDialog<Map<String, Object?>>(
  context,
  builder: (context) => Center(
    child: Material(
      type: MaterialType.transparency,
      child: InputFieldEditor(
        scope: scope,
        payload: payload,
        unavailable: unavailable,
        isEdit: isEdit,
        onChange: (p) => Navigator.of(context).pop(p),
        onCancel: () => Navigator.of(context).pop(),
      ),
    ),
  ),
);

/// InputField (`w-93`): "Insert Input Field", the Field Type (Paragraph, Select, Single File, File List; a new type
/// resets the field but keeps its name), "Save Response As" (the name: `^[a-z_]\w{0,29}$`, unique), then by type the
/// pre-populated value, the options, or the file settings; Cancel and Insert (Mod + Enter) / Save, disabled while the
/// name is invalid.
class InputFieldEditor extends StatefulWidget {
  const InputFieldEditor({
    super.key,
    required this.scope,
    required this.onChange,
    required this.onCancel,
    this.payload,
    this.unavailable = const [],
    this.isEdit = false,
  });

  final VarScope scope;
  final Map<String, Object?>? payload;
  final List<String> unavailable;
  final bool isEdit;
  final ValueChanged<Map<String, Object?>> onChange;
  final VoidCallback onCancel;

  @override
  State<InputFieldEditor> createState() => _InputFieldEditorState();
}

class _InputFieldEditorState extends State<InputFieldEditor> {
  late Map<String, Object?> _p = widget.payload ?? createDefaultParagraphFormInput();

  String get _name => inputNameOf(_p);
  String? get _error => formInputNameError(_name, widget.unavailable);
  bool get _valid => _name.trim().isNotEmpty && _error == null;

  String _t(String key) => hi('insertInputField.$key');

  void _save() {
    if (!_valid) return;
    if (isFileListFormInput(_p)) {
      final v = _p['number_limits'] ?? 5;
      if (v is! num || !v.isFinite) {
        widget.onChange({..._p, 'number_limits': 1});
        return;
      }
    }
    widget.onChange(_p);
  }

  Map<String, Object?> get _paragraphDefault => switch (_p['default']) {
    final Map<String, Object?> d => d,
    _ => createDefaultParagraphFormInput()['default']! as Map<String, Object?>,
  };

  Widget _label(String text, {bool required = false}) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text.rich(
      TextSpan(
        text: text,
        children: [
          if (required)
            TextSpan(
              text: '*',
              style: difyStyle(DifyType.systemXsRegular, DifyColors.textDestructiveSecondary),
            ),
        ],
      ),
      style: difyStyle(DifyType.systemXsMedium, DifyColors.textSecondary),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final source = jsGet(_p, 'option_source');
    final strings = [for (final e in jsList(jsGet(source, 'value'))) jsKey(e)];
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter, control: true): _save,
        const SingleActivator(LogicalKeyboardKey.enter, meta: true): _save,
      },
      child: Container(
        width: 372,
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.8),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: DifyColors.componentsPanelBgBlur,
          borderRadius: BorderRadius.circular(DifyRadius.xl),
          border: Border.all(color: DifyColors.componentsPanelBorder, width: Css.hairline),
          boxShadow: DifyShadows.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
              child: DifyText(_t('title'), DifyType.systemMdSemibold, color: DifyColors.textPrimary),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 12),
                    _label(_t('fieldType')),
                    InputTypeSelect(
                      value: inputTypeOf(_p),
                      items: [
                        for (final t in const [
                          FormInputType.paragraph,
                          FormInputType.select,
                          FormInputType.singleFile,
                          FormInputType.multiFiles,
                        ])
                          (value: t, name: formInputTypeLabel({'type': t})),
                      ],
                      onSelect: (t) => setState(() => _p = createDefaultFormInputByType(t, _name)),
                    ),
                    const SizedBox(height: 12),
                    _label(_t('saveResponseAs'), required: true),
                    DifyInput(
                      value: _name,
                      placeholder: _t('saveResponseAsPlaceholder'),
                      semanticLabel: _t('saveResponseAs'),
                      onChanged: (v) => setState(() => _p = {..._p, 'output_variable_name': v}),
                      onSubmitted: (_) => _save(),
                    ),
                    if (_name.isNotEmpty && _error != null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
                        child: DifyText(
                          _t(_error!),
                          DifyType.systemXsRegular,
                          color: DifyColors.textDestructiveSecondary,
                          maxLines: null,
                        ),
                      ),
                    if (isParagraphFormInput(_p)) ...[
                      const SizedBox(height: 16),
                      _label(_t('prePopulateField')),
                      PrePopulate(
                        isVariable: _paragraphDefault['type'] == 'variable',
                        selector: [for (final e in jsList(_paragraphDefault['selector'])) jsKey(e)],
                        value: jsStr(_paragraphDefault['value']) ?? '',
                        scope: w.scope.filtered(typeIn(const {VarType.string, VarType.number, VarType.secret})),
                        onIsVariableChange: (v) => setState(
                          () => _p = {
                            ..._p,
                            'default': {..._paragraphDefault, 'type': v ? 'variable' : 'constant'},
                          },
                        ),
                        onSelectorChange: (s) => setState(
                          () => _p = {
                            ..._p,
                            'default': {..._paragraphDefault, 'type': 'variable', 'selector': s},
                          },
                        ),
                        onValueChange: (v) => setState(
                          () => _p = {
                            ..._p,
                            'default': {..._paragraphDefault, 'type': 'constant', 'value': v},
                          },
                        ),
                      ),
                    ],
                    if (isSelectFormInput(_p)) ...[
                      const SizedBox(height: 16),
                      _label(_t('options')),
                      if (jsGet(source, 'type') == 'variable')
                        Container(
                          constraints: const BoxConstraints(minHeight: 80),
                          padding: const EdgeInsets.fromLTRB(12, 8, 12, 32),
                          decoration: BoxDecoration(
                            color: DifyColors.componentsInputBgNormal,
                            borderRadius: BorderRadius.circular(DifyRadius.lg),
                          ),
                          child: Stack(
                            clipBehavior: Clip.none,
                            children: [
                              VarReferencePicker(
                                value: [for (final e in jsList(jsGet(source, 'selector'))) jsKey(e)],
                                scope: w.scope,
                                isJustShowValue: true,
                                filterVar: (v, _) => v.type == VarType.arrayString,
                                onChange: (s, _) => setState(
                                  () => _p = {
                                    ..._p,
                                    'option_source': {...(source as Map), 'type': 'variable', 'selector': s},
                                  },
                                ),
                              ),
                              Positioned(
                                left: -6,
                                bottom: -28,
                                child: TypeSwitch(
                                  isVariable: true,
                                  onIsVariableChange: (v) => setState(
                                    () => _p = {
                                      ..._p,
                                      'option_source': {...(source as Map), 'type': v ? 'variable' : 'constant'},
                                    },
                                  ),
                                ),
                              ),
                            ],
                          ),
                        )
                      else
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: DifyColors.componentsInputBgNormal,
                            borderRadius: BorderRadius.circular(DifyRadius.lg),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              ConfigSelect(
                                options: strings,
                                onChange: (o) => setState(
                                  () => _p = {
                                    ..._p,
                                    'option_source': {...(source as Map), 'type': 'constant', 'value': o},
                                  },
                                ),
                              ),
                              const SizedBox(height: 8),
                              TypeSwitch(
                                isVariable: false,
                                onIsVariableChange: (v) => setState(
                                  () => _p = {
                                    ..._p,
                                    'option_source': {...(source as Map), 'type': v ? 'variable' : 'constant'},
                                  },
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                    if (isFileFormInput(_p) || isFileListFormInput(_p)) ...[
                      const SizedBox(height: 16),
                      FileUploadSetting(
                        payload: {
                          ..._p,
                          'max_length': isFileListFormInput(_p)
                              ? (jsTruthy(_p['number_limits']) ? _p['number_limits'] : 5)
                              : 1,
                        },
                        isMultiple: isFileListFormInput(_p),
                        onChange: (f) => setState(
                          () => _p = {
                            ..._p,
                            'allowed_file_extensions': f['allowed_file_extensions'] ?? <Object?>[],
                            'allowed_file_types': f['allowed_file_types'],
                            'allowed_file_upload_methods': f['allowed_file_upload_methods'],
                            if (isFileListFormInput(_p)) 'number_limits': f['max_length'],
                          },
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                  ],
                ),
              ),
            ),
            Container(
              color: DifyColors.componentsPanelBg,
              padding: const EdgeInsets.all(12),
              child: Align(
                alignment: Alignment.centerRight,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    spacing: 8,
                    children: [
                      DifyButton(onPressed: w.onCancel, child: Text(cm('operation.cancel'))),
                      DifyButton(
                        variant: DifyButtonVariant.primary,
                        disabled: !_valid,
                        onPressed: _save,
                        trailing: w.isEdit
                            ? null
                            : Row(
                                mainAxisSize: MainAxisSize.min,
                                spacing: 2,
                                children: [
                                  DifyKbd(modKeyLabel, color: DifyKbdColor.white),
                                  const DifyKbd('↵', color: DifyKbdColor.white),
                                ],
                              ),
                        child: Text(w.isEdit ? cm('operation.save') : _t('insert')),
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

/// TypeSwitch: `h-6 rounded-md pr-2 pl-1.5 text-text-tertiary` with `Variable02` and "Use Variable Instead" /
/// "Use Constant Instead".
class TypeSwitch extends StatelessWidget {
  const TypeSwitch({super.key, required this.isVariable, required this.onIsVariableChange});
  final bool isVariable;
  final ValueChanged<bool> onIsVariableChange;

  @override
  Widget build(BuildContext context) {
    final text = hi('insertInputField.${isVariable ? 'useConstantInstead' : 'useVarInstead'}');
    return DifyPressable(
      semanticLabel: text,
      onPressed: () => onIsVariableChange(!isVariable),
      builder: (context, hovered, _) => Container(
        height: 24,
        padding: const EdgeInsets.only(left: 6, right: 8),
        decoration: BoxDecoration(
          color: hovered ? DifyColors.componentsButtonGhostBgHover : null,
          borderRadius: BorderRadius.circular(DifyRadius.md),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 4,
          children: [
            const DifyIcon('vender/solid/development/variable-02', size: 14, color: DifyColors.textTertiary),
            DifyText(text, DifyType.systemXsMedium, color: DifyColors.textTertiary),
          ],
        ),
      ),
    );
  }
}

/// TagLabel: `h-5 rounded-md bg-components-button-secondary-bg px-1 text-text-accent` with the edit or variable icon.
class TagLabel extends StatelessWidget {
  const TagLabel({super.key, required this.text, required this.isVariable, this.onTap});
  final String text;
  final bool isVariable;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => DifyPressable(
    semanticLabel: text,
    onPressed: onTap,
    builder: (context, _, _) => Container(
      height: 20,
      margin: const EdgeInsets.symmetric(horizontal: 4),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        color: DifyColors.componentsButtonSecondaryBg,
        borderRadius: BorderRadius.circular(DifyRadius.md),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 4,
        children: [
          isVariable
              ? const DifyIcon('vender/solid/development/variable-02', size: 14, color: DifyColors.textAccent)
              : const RemixIcon('edit-line', size: 14, color: DifyColors.textAccent),
          DifyText(text, DifyType.systemXsMedium, color: DifyColors.textAccent),
        ],
      ),
    ),
  );
}

/// PrePopulate: until a choice is made (and while empty), "Add [Static Content] or [variable] …" (Tab leaves it);
/// then a textarea or a variable picker (string / number / secret), each with the TypeSwitch.
class PrePopulate extends StatefulWidget {
  const PrePopulate({
    super.key,
    required this.isVariable,
    required this.selector,
    required this.value,
    required this.scope,
    required this.onIsVariableChange,
    required this.onSelectorChange,
    required this.onValueChange,
  });

  final bool isVariable;
  final List<String> selector;
  final String value;
  final VarScope scope;
  final ValueChanged<bool> onIsVariableChange;
  final ValueChanged<List<String>> onSelectorChange;
  final ValueChanged<String> onValueChange;

  @override
  State<PrePopulate> createState() => _PrePopulateState();
}

class _PrePopulateState extends State<PrePopulate> {
  bool _clicked = false;

  void _type(bool isVariable) {
    setState(() => _clicked = true);
    widget.onIsVariableChange(isVariable);
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final placeholder = !_clicked && (w.isVariable ? w.selector.isEmpty : w.value.isEmpty);
    if (placeholder) {
      return Focus(
        onKeyEvent: (_, e) {
          if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.tab) {
            setState(() => _clicked = true);
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Container(
          height: 80,
          margin: const EdgeInsets.only(top: 4),
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          decoration: BoxDecoration(
            color: DifyColors.componentsInputBgNormal,
            borderRadius: BorderRadius.circular(DifyRadius.lg),
          ),
          child: Text.rich(
            TextSpan(
              children: transSpans(hi('insertInputField.prePopulateFieldPlaceholder'), {
                'staticContent': (_) => WidgetSpan(
                  alignment: PlaceholderAlignment.middle,
                  child: TagLabel(
                    text: hi('insertInputField.staticContent'),
                    isVariable: false,
                    onTap: () => _type(false),
                  ),
                ),
                'variable': (_) => WidgetSpan(
                  alignment: PlaceholderAlignment.middle,
                  child: VarReferencePicker(
                    value: w.selector,
                    scope: w.scope,
                    onChange: (s, _) {
                      setState(() => _clicked = true);
                      w.onSelectorChange(s);
                    },
                    trigger: TagLabel(text: hi('insertInputField.variable'), isVariable: true),
                  ),
                ),
              }),
            ),
            style: difyStyle(DifyType.systemSmRegular, DifyColors.textTertiary).copyWith(height: 20 / 14),
          ),
        ),
      );
    }
    final body = w.isVariable
        ? Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: VarReferencePicker(
              value: w.selector,
              scope: w.scope,
              isJustShowValue: true,
              onChange: (s, _) => w.onSelectorChange(s),
            ),
          )
        : DifyTextarea(
            value: w.value,
            semanticLabel: hi('insertInputField.staticContent'),
            onChanged: w.onValueChange,
          );
    return Container(
      constraints: const BoxConstraints(minHeight: 80),
      decoration: BoxDecoration(
        color: DifyColors.componentsInputBgNormal,
        borderRadius: BorderRadius.circular(DifyRadius.lg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          body,
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 4, 0, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: TypeSwitch(isVariable: w.isVariable, onIsVariableChange: _type),
            ),
          ),
        ],
      ),
    );
  }
}
