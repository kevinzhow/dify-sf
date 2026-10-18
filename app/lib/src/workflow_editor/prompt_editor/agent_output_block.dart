/// The agent output block of the prompt editor (base/prompt-editor/plugins/agent-output-block: component.tsx, the
/// insert command of index.tsx and utils.ts): an Agent v2 task's `[§output:name:name§]` token as a violet chip. A
/// committed output asks to be edited ([AgentOutputBlockConfig.onEdit]); a new one is edited in place: its name in a
/// small input (committed on Enter, Tab, blur or a type choice), its type in a select.
library;

import 'dart:async';

import 'package:flutter/material.dart' show Material, MaterialType, TextField, InputDecoration;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../cards/card_kit.dart' show DifyText;
import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../i18n/dify_i18n.dart';
import '../node_panel/bodies/llm/agent_v2_logic.dart'
    show outputTypeOptions, getOutputTypeOption, getOutputTypeOptionValue, createAgentOutputConfig;
import 'prompt_blocks.dart';

String _w(String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr('workflow', key, params);

/// `getUniqueAgentOutputName`: `output`, else the first free `output_<n>`.
String getUniqueAgentOutputName(List<Map<String, Object?>> outputs) {
  final names = {for (final o in outputs) o['name']};
  const base = 'output';
  if (!names.contains(base)) return base;
  var i = 1;
  while (names.contains('${base}_$i')) {
    i++;
  }
  return '${base}_$i';
}

/// The type option value of the output named [name] in [outputs] (`string` when it is not declared).
String agentOutputBlockType(String name, List<Map<String, Object?>> outputs) {
  final output = outputs.where((o) => o['name'] == name).firstOrNull;
  return output == null ? 'string' : getOutputTypeOptionValue(output);
}

/// component.tsx `upsertOutput`: [outputs] with [oldName] (or a new entry) set to [nextName] of [outputType]; null
/// when the name is not a valid output name or is another output's.
List<Map<String, Object?>>? upsertAgentOutput(
  List<Map<String, Object?>> outputs,
  String oldName,
  String nextName,
  String outputType,
) {
  final trimmed = nextName.trim();
  if (!agentOutputNamePattern.hasMatch(trimmed)) return null;
  final existing = outputs.indexWhere((o) => o['name'] == oldName);
  if (outputs.any((o) => o['name'] == trimmed && o['name'] != oldName)) return null;
  final next = createAgentOutputConfig(trimmed, outputType);
  if (existing >= 0) return [for (final (i, o) in outputs.indexed) i == existing ? next : o];
  return [...outputs, next];
}

/// What the block does to the editor around it (Dify's Lexical node and editor, which the block reaches by key).
abstract class AgentOutputBlockHost {
  /// The editor's text (`$getRoot()` children joined by line breaks).
  String get prompt;

  /// `node.setOutput(...)`: false when the block is no longer in the editor (its node was replaced).
  bool setOutput(
    String name,
    String outputType,
    bool isEditing,
    List<Map<String, Object?>> outputs,
    bool selectNameOnEdit,
    bool openTypeSelectOnEdit,
  );

  /// `node.selectNext()`: the caret right after the block.
  void selectNext();

  /// `editor.focus()`.
  void focusEditor();

  /// `node.setOpenTypeSelectOnEdit(value)`.
  void setOpenTypeSelectOnEdit(bool value);
}

/// AgentOutputBlockComponent.
class AgentOutputBlockComponent extends StatefulWidget {
  const AgentOutputBlockComponent({
    super.key,
    required this.host,
    required this.name,
    required this.outputType,
    required this.isEditing,
    bool? selectNameOnEdit,
    this.openTypeSelectOnEdit = false,
    this.outputs = const [],
    this.onChange,
    this.onEdit,
  }) : selectNameOnEdit = selectNameOnEdit ?? isEditing;

  final AgentOutputBlockHost host;
  final String name;
  final String outputType;
  final bool isEditing, selectNameOnEdit, openTypeSelectOnEdit;
  final List<Map<String, Object?>> outputs;
  final void Function(List<Map<String, Object?>> outputs, String? prompt)? onChange;
  final void Function(String name, String outputType)? onEdit;

  @override
  State<AgentOutputBlockComponent> createState() => AgentOutputBlockComponentState();
}

class AgentOutputBlockComponentState extends State<AgentOutputBlockComponent> {
  late final draft = TextEditingController(text: widget.name);
  late final nameFocus = FocusNode(debugLabel: 'agent output name', onKeyEvent: _onKey);
  late bool typeSelectOpen = widget.openTypeSelectOnEdit;
  bool _skipNextBlurCommit = false;
  bool _skipNameFocus = false;
  late String _latestDraftName = widget.name;
  bool _hovered = false;

  @override
  void initState() {
    super.initState();
    nameFocus.addListener(_onFocusChange);
    if (widget.isEditing) WidgetsBinding.instance.addPostFrameCallback((_) => _focusName());
  }

  @override
  void didUpdateWidget(AgentOutputBlockComponent oldWidget) {
    super.didUpdateWidget(oldWidget);
    final old = oldWidget;
    if (widget.name != old.name) {
      _latestDraftName = widget.name;
      draft.text = widget.name;
    }
    if (widget.isEditing && (!old.isEditing || widget.selectNameOnEdit != old.selectNameOnEdit)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _focusName());
    }
  }

  @override
  void dispose() {
    nameFocus.dispose();
    draft.dispose();
    super.dispose();
  }

  /// The edit effect: focus the name, all of it selected for a new output, else the caret at its end.
  void _focusName() {
    if (!mounted || !widget.isEditing) return;
    if (_skipNameFocus) {
      _skipNameFocus = false;
      return;
    }
    nameFocus.requestFocus();
    draft.selection = widget.selectNameOnEdit
        ? TextSelection(baseOffset: 0, extentOffset: draft.text.length)
        : TextSelection.collapsed(offset: draft.text.length);
  }

  void _onFocusChange() {
    if (nameFocus.hasFocus || !widget.isEditing) return;
    if (_skipNextBlurCommit) {
      _skipNextBlurCommit = false;
      return;
    }
    commitOutput(draft.text, widget.outputType);
  }

  /// `commitOutput`.
  bool commitOutput(
    String nextName,
    String nextType, {
    bool keepEditing = false,
    bool openTypeSelectOnEdit = false,
    bool selectAfterCommit = false,
  }) {
    final w = widget;
    final trimmed = nextName.trim();
    final nextOutputs = upsertAgentOutput(w.outputs, w.name, trimmed, nextType);
    if (nextOutputs == null) {
      draft.text = w.name;
      return false;
    }
    final currentPrompt = w.host.prompt;
    if (!w.host.setOutput(trimmed, nextType, keepEditing, nextOutputs, false, openTypeSelectOnEdit)) return false;
    if (selectAfterCommit) w.host.selectNext();
    final nextPrompt = replaceAgentOutputName(currentPrompt, w.name, trimmed);
    w.onChange?.call(nextOutputs, nextPrompt);
    if (draft.text != trimmed) draft.text = trimmed;
    _latestDraftName = trimmed;
    return true;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.numpadEnter || k == LogicalKeyboardKey.tab) {
      _skipNextBlurCommit = true;
      final tab = k == LogicalKeyboardKey.tab;
      final did = commitOutput(
        draft.text,
        widget.outputType,
        keepEditing: tab,
        openTypeSelectOnEdit: tab,
        selectAfterCommit: !tab,
      );
      if (!did) {
        _skipNextBlurCommit = false;
        return KeyEventResult.handled;
      }
      if (tab) {
        _skipNameFocus = true;
        draft.selection = TextSelection.collapsed(offset: draft.text.length);
        nameFocus.unfocus();
        setState(() => typeSelectOpen = true);
        return KeyEventResult.handled;
      }
      scheduleMicrotask(widget.host.focusEditor);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.escape) {
      draft.text = widget.name;
      nameFocus.unfocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _onTypeSelectOpenChange(bool open) {
    setState(() => typeSelectOpen = open);
    if (!open) {
      _skipNextBlurCommit = false;
      widget.host.setOpenTypeSelectOnEdit(false);
    }
  }

  void _onTypeChange(String type) {
    _skipNextBlurCommit = false;
    setState(() => typeSelectOpen = false);
    commitOutput(_latestDraftName, type);
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final selected = getOutputTypeOption(w.outputType);
    const violet700 = DifyColors.utilColorsVioletViolet700;
    if (!w.isEditing) {
      return MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: DifyPressable(
          semanticLabel: _w('nodes.agent.outputVars.edit', {'name': w.name}),
          onPressed: () => w.onEdit?.call(w.name, w.outputType),
          builder: (context, hovered, focused) => Container(
            key: const Key('agent-output-block'),
            constraints: const BoxConstraints(minWidth: 18),
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            decoration: BoxDecoration(
              color: DifyColors.utilColorsVioletViolet50,
              border: Border.all(color: DifyColors.utilColorsVioletViolet100),
              borderRadius: BorderRadius.circular(5),
              boxShadow: DifyShadows.xs,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              spacing: 4,
              children: [
                _hovered
                    ? const RemixIcon('edit-2-line', size: 14, color: violet700)
                    : const DifyIcon('vender/workflow/variable-x', size: 14, color: violet700),
                DifyText(w.name, DifyType.systemXsMedium, color: violet700, maxLines: 1),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: DifyText(
                    selected.label.toUpperCase(),
                    DifyType.system2xsMediumUppercase,
                    color: DifyColors.textTertiary,
                    maxLines: 1,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    final nameStyle = difyTextStyle(DifyType.systemXsRegular, violet700);
    return Container(
      key: const Key('agent-output-block-editing'),
      padding: const EdgeInsets.all(1),
      decoration: BoxDecoration(
        color: DifyColors.utilColorsVioletViolet50,
        border: Border.all(color: violet700),
        borderRadius: BorderRadius.circular(5),
        boxShadow: DifyShadows.xs,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 3,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              spacing: 2,
              children: [
                const DifyIcon('vender/workflow/variable-x', size: 14, color: violet700),
                ListenableBuilder(
                  listenable: Listenable.merge([draft, nameFocus]),
                  builder: (context, _) {
                    // `min-w-5 max-w-28`, `focus:w-24`.
                    final painter = TextPainter(
                      text: TextSpan(text: draft.text, style: nameStyle),
                      textDirection: TextDirection.ltr,
                    )..layout();
                    final width = nameFocus.hasFocus ? 96.0 : painter.width.clamp(20.0, 112.0) + 2;
                    painter.dispose();
                    return SizedBox(
                      width: width,
                      height: 16,
                      child: Semantics(
                        label: _w('nodes.agent.outputVars.nameLabel'),
                        textField: true,
                        child: Material(
                          type: MaterialType.transparency,
                          child: TextField(
                            controller: draft,
                            focusNode: nameFocus,
                            textAlign: TextAlign.center,
                            style: nameStyle,
                            maxLines: 1,
                            cursorColor: violet700,
                            cursorWidth: 1,
                            onChanged: (v) => _latestDraftName = v,
                            decoration: InputDecoration.collapsed(
                              hintText: _w('nodes.agent.outputVars.namePlaceholder'),
                              hintStyle: nameStyle.copyWith(color: violet700.withValues(alpha: 0.5)),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
          Listener(
            onPointerDown: (_) => _skipNextBlurCommit = true,
            child: DifyDropdownMenu(
              open: typeSelectOpen,
              onOpenChange: _onTypeSelectOpenChange,
              placement: DifyPlacement.bottomStart,
              width: 160,
              semanticLabel: _w('nodes.agent.outputVars.typeLabel'),
              builder: (context, c) => DifyPressable(
                semanticLabel: _w('nodes.agent.outputVars.typeLabel'),
                onPressed: () => _onTypeSelectOpenChange(!typeSelectOpen),
                builder: (context, hovered, focused) => Container(
                  key: const Key('agent-output-type-trigger'),
                  height: 16,
                  constraints: const BoxConstraints(minWidth: 16),
                  padding: const EdgeInsets.only(left: 4, right: 2),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: DifyColors.utilColorsVioletViolet200,
                    borderRadius: BorderRadius.circular(DifyRadius.sm),
                  ),
                  child: DifyText(
                    selected.label.toUpperCase(),
                    DifyType.system2xsSemiboldUppercase,
                    color: violet700,
                    maxLines: 1,
                  ),
                ),
              ),
              children: [
                for (final o in outputTypeOptions)
                  DifyMenuItem(
                    semanticLabel: o.label,
                    onSelect: () => _onTypeChange(o.value),
                    trailing: o.value == w.outputType
                        ? const RemixIcon('check-line', size: 16, color: DifyColors.textAccent)
                        : null,
                    child: Text(o.label),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
