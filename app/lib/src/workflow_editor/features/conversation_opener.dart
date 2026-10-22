/// Conversation opener (conversation-opener/index.tsx, modal.tsx) and the "add these variables?" prompt it may ask
/// (app/configuration/config-prompt/confirm-add-var).
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../i18n/dify_i18n.dart';
import '../panel_fields/var_picker_model.dart' show checkKeys;
import '../prompt_editor/prompt_editor.dart';
import 'features_services.dart';
import 'features_store.dart';
import 'new_feature_panel.dart';
import 'simple_features.dart' show toggleFeature;

/// ConversationOpener: the switch, the opening statement (or the placeholder) and, while hovered, "Write opener",
/// which opens the modal context's opening modal ([FeaturesServices.showOpeningModal], else
/// [showOpeningSettingModal]).
class ConversationOpener extends StatefulWidget {
  const ConversationOpener({
    super.key,
    this.disabled = false,
    this.onChange,
    this.promptVariables = const [],
    this.workflowVariables = const [],
    this.onAutoAddPromptVariable,
  });

  final bool disabled;
  final OnFeaturesChange? onChange;
  final List<Json> promptVariables, workflowVariables;
  final void Function(List<Json> variables)? onAutoAddPromptVariable;

  @override
  State<ConversationOpener> createState() => _ConversationOpenerState();
}

class _ConversationOpenerState extends State<ConversationOpener> with FeatureHover {
  void _open() {
    if (widget.disabled) return;
    final store = FeaturesScope.of(context);
    final show = FeaturesServicesScope.of(context).showOpeningModal ?? showOpeningSettingModal;
    show(context, (
      payload: featureMap(store.features.value, FeatureEnum.opening),
      promptVariables: widget.promptVariables,
      workflowVariables: widget.workflowVariables,
      onAutoAddPromptVariable: widget.onAutoAddPromptVariable,
      onSaveCallback: (opening) {
        // The features as they are now (not when the modal opened): a change someone else made meanwhile stays.
        store.setFeatures({...store.features.value, FeatureEnum.opening: opening});
        widget.onChange?.call();
      },
      onCancelCallback: () => widget.onChange?.call(),
    ));
  }

  @override
  Widget build(BuildContext context) => FeaturesBuilder(
    builder: (context, features) {
      final opening = featureMap(features, FeatureEnum.opening);
      final enabled = opening['enabled'] == true;
      final statement = opening['opening_statement'];
      return FeatureCard(
        icon: FeatureIcon(
          color: DifyColors.utilColorsBlueLightBlueLight500,
          dify: 'vender/features/love-message',
        ),
        title: ad('feature.conversationOpener.title'),
        value: enabled,
        disabled: widget.disabled,
        onChange: (v) => toggleFeature(context, FeatureEnum.opening, v, widget.onChange),
        onMouseEnter: () => setHovering(true),
        onMouseLeave: () => setHovering(false),
        child: !enabled
            ? FeatureDescription(ad('feature.conversationOpener.description'))
            : isHovering
            ? FeatureCardButton(
                icon: 'edit-line',
                label: ad('openingStatement.writeOpener'),
                disabled: widget.disabled,
                onPressed: _open,
              )
            : FeatureDescription(
                statement is String && statement.isNotEmpty ? statement : ad('openingStatement.placeholderLine1'),
              ),
      );
    },
  );
}

/// The modal context's opening modal: [OpeningSettingModal] in a dialog that a backdrop click does not close; Save
/// calls `onSaveCallback`, any other way out `onCancelCallback`.
void showOpeningSettingModal(BuildContext context, OpeningModalRequest r) {
  var saved = false;
  showDifyDialog<void>(
    context,
    dismissible: false,
    builder: (dialog) => OpeningSettingModal(
      data: r.payload,
      promptVariables: r.promptVariables,
      workflowVariables: r.workflowVariables,
      onAutoAddPromptVariable: r.onAutoAddPromptVariable,
      onSave: (v) {
        saved = true;
        Navigator.of(dialog).pop();
        r.onSaveCallback(v);
      },
      onCancel: () => Navigator.of(dialog).pop(),
    ),
  ).then((_) {
    if (!saved) r.onCancelCallback();
  });
}

/// block-input `getInputKeys`: the `{{key}}`s of [value], each once.
List<String> getInputKeys(String value) => [
  ...{for (final m in RegExp(r'\{\{([^}]+)\}\}').allMatches(value)) m[1]!},
];

/// utils/var.ts `getNewVar(key, 'string')`: a prompt variable for [key].
Json getNewVar(String key, [String type = 'string']) {
  final max = RegExp(r'[一-龥]').hasMatch(key) ? 8 : 48;
  return {'key': key, 'name': key.length > max ? key.substring(0, max) : key, 'type': type, 'required': true};
}

const _maxQuestionNum = 10;

/// OpeningSettingModal: the opening statement (a prompt editor offering the prompt and workflow variables) and up
/// to ten suggested questions (sortable by drag or by keyboard from the handle). Saving with variables the app does
/// not have asks whether to add them first ([ConfirmAddVar]); Save is off while the statement is blank.
class OpeningSettingModal extends StatefulWidget {
  const OpeningSettingModal({
    super.key,
    required this.data,
    required this.onSave,
    required this.onCancel,
    this.promptVariables = const [],
    this.workflowVariables = const [],
    this.onAutoAddPromptVariable,
  });

  final Json data;
  final ValueChanged<Json> onSave;
  final VoidCallback onCancel;
  final List<Json> promptVariables, workflowVariables;
  final void Function(List<Json> variables)? onAutoAddPromptVariable;

  @override
  State<OpeningSettingModal> createState() => _OpeningSettingModalState();
}

class _OpeningSettingModalState extends State<OpeningSettingModal> {
  late String _value = widget.data['opening_statement'] as String? ?? '';

  /// The questions, each with an id that stays with it (its row's widgets).
  late List<({int id, String text})> _questions = [
    for (final (i, q) in ((widget.data['suggested_questions'] as List?) ?? const []).indexed) (id: i, text: '$q'),
  ];
  late int _nextId = _questions.length;
  List<String>? _notIncludeKeys;
  int? _focusID, _deletingID, _autoFocusID;

  /// The keyboard sort in progress: the order shown and the id being moved.
  ({List<int> order, int moving})? _sorting;
  final _handles = <int, FocusNode>{};

  @override
  void didUpdateWidget(OpeningSettingModal old) {
    super.didUpdateWidget(old);
    final s = widget.data['opening_statement'];
    if (s != old.data['opening_statement']) _value = s as String? ?? '';
  }

  @override
  void dispose() {
    for (final f in _handles.values) {
      f.dispose();
    }
    super.dispose();
  }

  bool get _saveDisabled => _value.trim().isEmpty;
  List<String> get _texts => [for (final q in _questions) q.text];

  void _save({bool ignoreVariablesCheck = false}) {
    if (_saveDisabled) return;
    if (!ignoreVariablesCheck) {
      final keys = getInputKeys(_value).where((k) => checkKeys([k], canBeEmpty: true) == null).toList();
      final promptKeys = [for (final v in widget.promptVariables) v['key']];
      final workflowKeys = [for (final v in widget.workflowVariables) v['variable']];
      final List<String> missing;
      if (promptKeys.isEmpty && workflowKeys.isEmpty) {
        missing = keys;
      } else if (workflowKeys.isNotEmpty) {
        missing = keys.where((k) => !workflowKeys.contains(k)).toList();
      } else {
        missing = keys.where((k) => !promptKeys.contains(k)).toList();
      }
      if (missing.isNotEmpty) {
        setState(() => _notIncludeKeys = missing);
        return;
      }
    }
    widget.onSave({...widget.data, 'opening_statement': _value, 'suggested_questions': _texts});
  }

  void _cancelAutoAddVar() {
    setState(() => _notIncludeKeys = null);
    _save(ignoreVariablesCheck: true);
  }

  void _autoAddVar() {
    final keys = _notIncludeKeys ?? const [];
    widget.onAutoAddPromptVariable?.call([for (final k in keys) getNewVar(k)]);
    setState(() => _notIncludeKeys = null);
    _save(ignoreVariablesCheck: true);
  }

  // ---- keyboard sorting (useKeyboardSortable) ----

  List<({int id, String text})> get _shown {
    final s = _sorting;
    if (s == null) return _questions;
    final byId = {for (final q in _questions) q.id: q};
    return [for (final id in s.order) ?byId[id]];
  }

  FocusNode _handle(int id) => _handles.putIfAbsent(id, () => FocusNode(debugLabel: 'question sort handle $id'));

  void _focusHandle(int id) => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (mounted) _handles[id]?.requestFocus();
  });

  KeyEventResult _onHandleKey(int id, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    final s = _sorting;
    if (k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.space) {
      if (s == null) {
        if (_questions.length < 2) return KeyEventResult.handled;
        setState(() => _sorting = (order: [for (final q in _questions) q.id], moving: id));
      } else {
        setState(() {
          _questions = _shown;
          _sorting = null;
        });
        _focusHandle(id);
      }
      return KeyEventResult.handled;
    }
    if (s == null || s.moving != id) return KeyEventResult.ignored;
    if (k == LogicalKeyboardKey.escape) {
      setState(() => _sorting = null);
      _focusHandle(id);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowUp || k == LogicalKeyboardKey.arrowDown) {
      final at = s.order.indexOf(id);
      final to = (at + (k == LogicalKeyboardKey.arrowUp ? -1 : 1)).clamp(0, s.order.length - 1);
      if (to != at) {
        final order = [...s.order];
        order.insert(to, order.removeAt(at));
        setState(() => _sorting = (order: order, moving: id));
        _focusHandle(id);
      }
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.tab) setState(() => _sorting = null);
    return KeyEventResult.ignored;
  }

  void _reorder(int from, int to) {
    if (_sorting != null) return;
    final list = [..._questions];
    list.insert(to, list.removeAt(from));
    setState(() => _questions = list);
  }

  // ---- layout ----

  Widget _questionRow(int index, ({int id, String text}) q) {
    final id = q.id;
    final focused = _focusID == id, deleting = _deletingID == id;
    return Padding(
      key: ValueKey(id),
      padding: EdgeInsets.only(top: index == 0 ? 0 : 4),
      child: _QuestionRow(
        text: q.text,
        focused: focused,
        deleting: deleting,
        autofocus: _autoFocusID == id,
        sortIndex: index,
        handle: _handle(id),
        pressed: _sorting?.moving == id,
        onHandleKey: (e) => _onHandleKey(id, e),
        onChanged: (v) => setState(() => _questions = [for (final x in _questions) x.id == id ? (id: id, text: v) : x]),
        onFocusChange: (f) => setState(() {
          _focusID = f ? id : (_focusID == id ? null : _focusID);
          if (f && _autoFocusID == id) _autoFocusID = null;
        }),
        onDelete: () => setState(() {
          _questions = [..._questions.where((x) => x.id != id)];
          if (_deletingID == id) _deletingID = null;
        }),
        onDeleteHover: (h) => setState(() => _deletingID = h ? id : (_deletingID == id ? null : _deletingID)),
      ),
    );
  }

  Widget _questions_() {
    final shown = _shown;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        ad('openingStatement.openingQuestion'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: DifyType.systemMdMedium.style,
                      ),
                    ),
                    const SizedBox(width: 4),
                    DifyInfotip(
                      label: ad('openingStatement.openingQuestionDescription'),
                      width: 220,
                      content: Text(ad('openingStatement.openingQuestionDescription')),
                    ),
                  ],
                ),
              ),
              Text(
                '${_questions.length}/$_maxQuestionNum',
                style: difyTextStyle(DifyTw.textXsMediumLeading18, DifyColors.textTertiary),
              ),
            ],
          ),
        ),
        const Padding(padding: EdgeInsets.only(bottom: 12), child: DifyDivider(gradient: true)),
        ReorderableList(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: shown.length,
          itemBuilder: (context, i) => _questionRow(i, shown[i]),
          proxyDecorator: (child, _, _) => Opacity(opacity: 0.5, child: child),
          onReorderItem: _reorder,
        ),
        if (_questions.length < _maxQuestionNum)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: _AddQuestion(
              onTap: () => setState(() {
                final id = _nextId++;
                _deletingID = null;
                _autoFocusID = id;
                _questions = [..._questions, (id: id, text: '')];
              }),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final placeholderStyle = difyTextStyle(DifyTw.textSmLeading24, DifyColors.componentsInputTextPlaceholder);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (_sorting == null) widget.onCancel();
        },
      },
      child: DifyDialogSurface(
        width: 640,
        label: ad('feature.conversationOpener.title'),
        child: Stack(
          children: [
            SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(bottom: 24),
                    child: Row(
                      children: [
                        Expanded(
                          child: DifyText(ad('feature.conversationOpener.title'), DifyType.title2xlSemiBold),
                        ),
                        _CloseButton(onPressed: widget.onCancel),
                      ],
                    ),
                  ),
                  KeyedSubtree(
                    key: const ValueKey('opener-input-section'),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: Text(
                              ad('openingStatement.editorTitle'),
                              style: DifyType.systemMdMedium.style,
                            ),
                          ),
                          Container(
                            constraints: const BoxConstraints(minHeight: 80),
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            decoration: BoxDecoration(
                              color: DifyColors.componentsInputBgNormal,
                              borderRadius: BorderRadius.circular(DifyRadius.lg),
                            ),
                            child: DifyPromptEditor(
                              value: _value,
                              onChange: (v) => setState(() => _value = v),
                              minHeight: 64,
                              placeholder: Padding(
                                padding: const EdgeInsets.only(right: 32),
                                child: Text(
                                  '${ad('openingStatement.placeholderLine1')}\n'
                                  '${ad('openingStatement.placeholderLine2')}',
                                  style: placeholderStyle,
                                ),
                              ),
                              variableBlock: VariableBlockConfig(
                                show: true,
                                variables: [
                                  for (final v in widget.promptVariables)
                                    (
                                      name: '${(v['name'] as String?)?.isNotEmpty ?? false ? v['name'] : v['key']}',
                                      value: '${v['key']}',
                                    ),
                                  for (final v in widget.workflowVariables)
                                    (name: '${v['variable']}', value: '${v['variable']}'),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  KeyedSubtree(
                    key: const ValueKey('opener-questions-section'),
                    child: Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: _questions_()),
                  ),
                  const SizedBox(height: 32),
                  FeatureFooter([
                    DifyButton(onPressed: widget.onCancel, child: Text(tc('operation.cancel'))),
                    DifyButton(
                      variant: DifyButtonVariant.primary,
                      disabled: _saveDisabled,
                      onPressed: _save,
                      child: Text(tc('operation.save')),
                    ),
                  ]),
                ],
              ),
            ),
            if (_notIncludeKeys case final keys?)
              Positioned.fill(
                child: ConfirmAddVar(varNameArr: keys, onConfirm: _autoAddVar, onCancel: _cancelAutoAddVar),
              ),
          ],
        ),
      ),
    );
  }
}

/// The modal's close icon (`p-1`, `i-ri-close-line size-4 text-text-tertiary`), named `common.operation.close`.
class _CloseButton extends StatelessWidget {
  const _CloseButton({required this.onPressed});
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => DifyPressable(
    onPressed: onPressed,
    semanticLabel: tc('operation.close'),
    builder: (context, hovered, focused) => Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        border: focused ? Border.all(color: DifyColors.componentsInputBorderActive) : null,
        borderRadius: BorderRadius.circular(DifyRadius.sm),
      ),
      child: RemixIcon('close-line', size: 16, color: DifyColors.textTertiary),
    ),
  );
}

/// One suggested question: the drag handle, the input and the delete icon. The row turns destructive while the
/// delete icon is hovered and active while the input has focus.
class _QuestionRow extends StatefulWidget {
  const _QuestionRow({
    required this.text,
    required this.focused,
    required this.deleting,
    required this.autofocus,
    required this.sortIndex,
    required this.handle,
    required this.pressed,
    required this.onHandleKey,
    required this.onChanged,
    required this.onFocusChange,
    required this.onDelete,
    required this.onDeleteHover,
  });

  final String text;
  final bool focused, deleting, autofocus, pressed;
  final int sortIndex;
  final FocusNode handle;
  final KeyEventResult Function(KeyEvent e) onHandleKey;
  final ValueChanged<String> onChanged;
  final ValueChanged<bool> onFocusChange;
  final VoidCallback onDelete;
  final ValueChanged<bool> onDeleteHover;

  @override
  State<_QuestionRow> createState() => _QuestionRowState();
}

class _QuestionRowState extends State<_QuestionRow> {
  late final _controller = TextEditingController(text: widget.text);
  final _focus = FocusNode(debugLabel: 'opening question');
  bool _hovered = false, _deleteHovered = false, _handleFocused = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() => widget.onFocusChange(_focus.hasFocus));
  }

  @override
  void didUpdateWidget(_QuestionRow old) {
    super.didUpdateWidget(old);
    if (_controller.text != widget.text) _controller.text = widget.text;
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final (border, bg) = w.deleting
        ? (DifyColors.componentsInputBorderDestructive, DifyColors.stateDestructiveHover)
        : w.focused
        ? (DifyColors.componentsInputBorderActive, DifyColors.componentsInputBgActive)
        : (
            DifyColors.componentsPanelBorderSubtle,
            _hovered ? DifyColors.componentsPanelOnPanelItemBgHover : DifyColors.componentsPanelOnPanelItemBg,
          );
    final label = DifyI18n.tr('common', 'sort.handle', {'item': w.text});
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Container(
        height: 38,
        padding: const EdgeInsets.only(left: 10),
        decoration: BoxDecoration(
          color: bg,
          border: Border.all(color: border),
          borderRadius: BorderRadius.circular(DifyRadius.lg),
        ),
        child: Stack(
          alignment: Alignment.centerLeft,
          children: [
            Row(
              children: [
                Semantics(
                  button: true,
                  toggled: w.pressed,
                  label: label,
                  child: Focus(
                    focusNode: w.handle,
                    onKeyEvent: (_, e) => w.onHandleKey(e),
                    onFocusChange: (f) => setState(() => _handleFocused = f),
                    // A press focuses the handle (as a click focuses a button), for the keyboard sort.
                    child: Listener(
                      onPointerDown: (_) => w.handle.requestFocus(),
                      child: ReorderableDragStartListener(
                        index: w.sortIndex,
                        child: MouseRegion(
                          cursor: SystemMouseCursors.grab,
                          child: Container(
                            width: 24,
                            height: 24,
                            decoration: DifyFocusDecoration(
                              color: w.pressed ? DifyColors.stateAccentHover : null,
                              borderRadius: BorderRadius.circular(DifyRadius.md),
                              boxShadow: difyFocusRing(_handleFocused),
                            ),
                            child: Center(
                              child: RemixIcon('draggable', size: 16, color: DifyColors.textQuaternary),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: DifySurface(
                    child: DifyTextField(
                      controller: _controller,
                      focusNode: _focus,
                      autofocus: w.autofocus,
                      onChanged: w.onChanged,
                      style: difyTextStyle(DifyTw.textSmLeading36, DifyColors.textSecondary),
                      cursorColor: DifyColors.textSecondary,
                      cursorWidth: 1,
                      decoration: DifyFieldDecoration(
                        contentPadding: const EdgeInsets.only(left: 6, right: 32),
                        hintText: ad('openingStatement.openingQuestionPlaceholder'),
                        hintStyle: difyTextStyle(DifyTw.textSmLeading36, DifyColors.componentsInputTextPlaceholder),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            Positioned(
              right: 6,
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                onEnter: (_) {
                  setState(() => _deleteHovered = true);
                  w.onDeleteHover(true);
                },
                onExit: (_) {
                  setState(() => _deleteHovered = false);
                  w.onDeleteHover(false);
                },
                child: GestureDetector(
                  key: ValueKey('delete-question-${w.text}'),
                  onTap: w.onDelete,
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: _deleteHovered ? DifyColors.stateDestructiveHover : null,
                      borderRadius: BorderRadius.circular(DifyRadius.md),
                    ),
                    child: RemixIcon(
                      'delete-bin-line',
                      size: 14,
                      color: _deleteHovered ? DifyColors.textDestructive : DifyColors.textTertiary,
                    ),
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

/// "Add option": `mt-1 flex h-9 items-center gap-2 rounded-lg bg-components-button-tertiary-bg px-3
/// text-components-button-tertiary-text`, hover `bg-components-button-tertiary-bg-hover`.
class _AddQuestion extends StatefulWidget {
  const _AddQuestion({required this.onTap});
  final VoidCallback onTap;

  @override
  State<_AddQuestion> createState() => _AddQuestionState();
}

class _AddQuestionState extends State<_AddQuestion> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    child: MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: _hovered ? DifyColors.componentsButtonTertiaryBgHover : DifyColors.componentsButtonTertiaryBg,
            borderRadius: BorderRadius.circular(DifyRadius.lg),
          ),
          child: Row(
            spacing: 8,
            children: [
              RemixIcon('add-line', size: 16, color: DifyColors.componentsButtonTertiaryText),
              Text(
                ad('variableConfig.addOption'),
                style: difyTextStyle(
                  DifyType.systemSmMedium,
                  DifyColors.componentsButtonTertiaryText,
                ).copyWith(fontSize: 13),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// ConfirmAddVar: over the dialog (`rgba(35, 56, 118, 0.2)`), "add these variables?" with the names as `{{name}}`
/// highlights, Cancel (save without adding) and Add.
class ConfirmAddVar extends StatelessWidget {
  const ConfirmAddVar({super.key, required this.varNameArr, required this.onConfirm, required this.onCancel});
  final List<String> varNameArr;
  final VoidCallback onConfirm, onCancel;

  @override
  Widget build(BuildContext context) => Container(
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: DifyConfirmAddVarColors.backdrop,
      borderRadius: BorderRadius.circular(DifyRadius.xl),
    ),
    child: Container(
      width: 420,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: DifyColors.componentsPanelBg,
        borderRadius: BorderRadius.circular(DifyRadius.xl),
        boxShadow: [
          BoxShadow(
            offset: const Offset(0, 12),
            blurRadius: 16,
            spreadRadius: -4,
            color: DifyConfirmAddVarColors.shadow,
          ),
          BoxShadow(
            offset: const Offset(0, 4),
            blurRadius: 6,
            spreadRadius: -2,
            color: DifyConfirmAddVarColors.shadowNear,
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 12,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: DifyColors.componentsCardBgAlt,
                  border: Border.all(color: DifyColors.componentsCardBorder),
                  borderRadius: BorderRadius.circular(DifyRadius.xl),
                  boxShadow: DifyShadows.lg,
                ),
                child: Center(child: SvgPicture.string(_varIcon, width: 16, height: 14)),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      ad('autoAddVar'),
                      style: difyTextStyle(DifyType.systemMdMedium, DifyColors.textPrimary),
                    ),
                    const SizedBox(height: 15),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 66),
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Wrap(spacing: 4, children: [for (final n in varNameArr) _VarHighlight(n)]),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 28),
          FeatureFooter([
            DifyButton(onPressed: onCancel, child: Text(tc('operation.cancel'))),
            DifyButton(variant: DifyButtonVariant.primary, onPressed: onConfirm, child: Text(tc('operation.add'))),
          ]),
        ],
      ),
    ),
  );
}

/// ConfirmAddVar's VarIcon.
const _varIcon =
    '<svg width="16" height="14" viewBox="0 0 16 14" fill="none" xmlns="http://www.w3.org/2000/svg">'
    '<path d="M13.8683 0.704745C13.7051 0.374685 13.3053 0.239393 12.9752 0.402563C12.6452 0.565732 12.5099 0.965573 '
    '12.673 1.29563C13.5221 3.01316 13.9999 4.94957 13.9999 7.00019C13.9999 9.05081 13.5221 10.9872 12.673 '
    '12.7047C12.5099 13.0348 12.6452 13.4346 12.9752 13.5978C13.3053 13.761 13.7051 13.6257 13.8683 13.2956C14.8063 '
    '11.3983 15.3333 9.26009 15.3333 7.00019C15.3333 4.74029 14.8063 2.60209 13.8683 0.704745Z" fill="#FD853A"/>'
    '<path d="M3.32687 1.29563C3.49004 0.965573 3.35475 0.565732 3.02469 0.402563C2.69463 0.239393 2.29479 0.374685 '
    '2.13162 0.704745C1.19364 2.60209 0.666626 4.74029 0.666626 7.00019C0.666626 9.26009 1.19364 11.3983 2.13162 '
    '13.2956C2.29479 13.6257 2.69463 13.761 3.02469 13.5978C3.35475 13.4346 3.49004 13.0348 3.32687 12.7047C2.47779 '
    '10.9872 1.99996 9.05081 1.99996 7.00019C1.99996 4.94957 2.47779 3.01316 3.32687 1.29563Z" fill="#FD853A"/>'
    '<path d="M9.33238 4.8413C9.74208 4.36081 10.3411 4.08337 10.9726 4.08337H11.0324C11.4006 4.08337 11.6991 4.38185 '
    '11.6991 4.75004C11.6991 5.11823 11.4006 5.41671 11.0324 5.41671H10.9726C10.7329 5.41671 10.5042 5.52196 '
    '10.347 5.7064L8.78693 7.536L9.28085 9.27382C9.29145 9.31112 9.32388 9.33337 9.35696 9.33337H10.2864C10.6545 '
    '9.33337 10.953 9.63185 10.953 10C10.953 10.3682 10.6545 10.6667 10.2864 10.6667H9.35696C8.72382 10.6667 '
    '8.17074 10.245 7.99832 9.63834L7.74732 8.75524L6.76373 9.90878C6.35403 10.3893 5.75501 10.6667 5.1235 '
    '10.6667H5.06372C4.69553 10.6667 4.39705 10.3682 4.39705 10C4.39705 9.63185 4.69553 9.33337 5.06372 '
    '9.33337H5.1235C5.3632 9.33337 5.59189 9.22812 5.74915 9.04368L7.30926 7.21399L6.81536 5.47626C6.80476 5.43897 '
    '6.77233 5.41671 6.73925 5.41671H5.80986C5.44167 5.41671 5.14319 5.11823 5.14319 4.75004C5.14319 4.38185 '
    '5.44167 4.08337 5.80986 4.08337H6.73925C7.37239 4.08337 7.92547 4.50508 8.0979 5.11174L8.34887 5.99475L9.33238 '
    '4.8413Z" fill="#FD853A"/></svg>';

/// VarHighlight: `{{name}}` in `text-primary-600` on `rgba(21, 94, 239, 0.05)`, the braces at 60 %.
class _VarHighlight extends StatelessWidget {
  const _VarHighlight(this.name);
  final String name;

  @override
  Widget build(BuildContext context) {
    final style = difyTextStyle(DifyType.systemXsMedium, DifyColors.primary600);
    final dim = style.copyWith(color: style.color!.withValues(alpha: 0.6));
    return Container(
      height: 20,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        color: DifyConfirmAddVarColors.varHighlightBg,
        borderRadius: BorderRadius.circular(DifyRadius.md),
      ),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(text: '{{', style: dim),
            TextSpan(text: name, style: style),
            TextSpan(text: '}}', style: dim),
          ],
        ),
        style: DifyTw.textXsLeading20.style,
      ),
    );
  }
}
