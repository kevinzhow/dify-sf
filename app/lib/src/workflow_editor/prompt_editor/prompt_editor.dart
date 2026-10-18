/// Dify's PromptEditor (web/app/components/base/prompt-editor: index.tsx, prompt-editor-content.tsx and the
/// plugins): a text field for Dify's prompt string in which variable references and the special placeholders are
/// inline blocks, with the `{` / `/` component picker.
///
/// Approach: a [TextField] over a [PromptEditorController], whose text has one private-use character per block and
/// whose `buildTextSpan` puts the block widget there as a [WidgetSpan]. Editing, selection, IME, undo and the caret
/// are Flutter's own; a block is a single character, so it is atomic for the caret and Backspace, and only the
/// changed text runs are re-parsed. The picker is an [OverlayPortal] anchored to the typed trigger's text box.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../../cards/card_kit.dart' show cardFontFamily;
import '../../design/dify_tokens.g.dart';
import '../../i18n/dify_i18n.dart';
import '../panel_fields/var_picker_model.dart';
import '../panel_fields/var_reference_vars.dart' show VarReferenceVars;
import 'component_picker.dart';
import 'prompt_blocks.dart';
import 'prompt_chips.dart';
import 'prompt_editor_controller.dart';
import 'prompt_editor_types.dart';

export 'prompt_blocks.dart';
export 'prompt_editor_controller.dart';
export 'prompt_editor_types.dart';

/// PromptEditor. [value] is controlled like Dify's (a different value replaces the content); [onChange] gets the
/// prompt string after each edit. The `*Block` configs say which placeholders become blocks and what the picker
/// offers. [compact] is `text-[13px] leading-5` (else `text-sm/6`); [lineHeight] a `leading-*` class over it.
/// [minHeight] / [height] stand for the class names
/// and style Dify passes; with [height] the text scrolls inside.
class DifyPromptEditor extends StatefulWidget {
  const DifyPromptEditor({
    super.key,
    this.value,
    this.onChange,
    this.controller,
    this.focusNode,
    this.placeholder,
    this.compact = false,
    this.lineHeight,
    this.editable = true,
    this.onBlur,
    this.onFocus,
    this.contextBlock,
    this.queryBlock,
    this.historyBlock,
    this.requestUrlBlock,
    this.variableBlock,
    this.externalToolBlock,
    this.workflowVariableBlock,
    this.currentBlock,
    this.errorMessageBlock,
    this.lastRunBlock,
    this.isSupportFileVar = false,
    this.disableSlashPicker = false,
    this.disableBracePicker = false,
    this.minHeight = 0,
    this.height,
    this.semanticLabel,
  });

  final String? value;
  final ValueChanged<String>? onChange;
  final PromptEditorController? controller;
  final FocusNode? focusNode;

  /// A string or a widget; `promptEditor.placeholder` when null.
  final Object? placeholder;
  final bool compact;
  final double? lineHeight;
  final bool editable;
  final VoidCallback? onBlur;
  final VoidCallback? onFocus;
  final ContextBlockConfig? contextBlock;
  final PromptBlockConfig? queryBlock;
  final HistoryBlockConfig? historyBlock;
  final PromptBlockConfig? requestUrlBlock;
  final VariableBlockConfig? variableBlock;
  final ExternalToolBlockConfig? externalToolBlock;
  final WorkflowVariableBlockConfig? workflowVariableBlock;
  final CurrentBlockConfig? currentBlock;
  final PromptBlockConfig? errorMessageBlock;
  final PromptBlockConfig? lastRunBlock;
  final bool isSupportFileVar;
  final bool disableSlashPicker;
  final bool disableBracePicker;
  final double minHeight;
  final double? height;

  /// `aria-label`.
  final String? semanticLabel;

  /// Which tokens the editor makes blocks of.
  PromptBlockSet get blockSet => PromptBlockSet({
    if (contextBlock?.show ?? false) PromptBlockKind.context,
    if (queryBlock?.show ?? false) PromptBlockKind.query,
    if (historyBlock?.show ?? false) PromptBlockKind.history,
    if (workflowVariableBlock?.show ?? false) PromptBlockKind.workflowVariable,
    if (currentBlock?.show ?? false) PromptBlockKind.current,
    if (requestUrlBlock?.show ?? false) PromptBlockKind.requestUrl,
    if (errorMessageBlock?.show ?? false) PromptBlockKind.errorMessage,
    if (lastRunBlock?.show ?? false) PromptBlockKind.lastRun,
  }, variableValue: (variableBlock?.show ?? false) || (externalToolBlock?.show ?? false) || isSupportFileVar);

  @override
  State<DifyPromptEditor> createState() => DifyPromptEditorState();
}

/// The typeahead state (`MenuResolution`): the trigger, where it starts and what follows it.
typedef _Resolution = ({String trigger, int leadOffset, int caret, String query});

class DifyPromptEditorState extends State<DifyPromptEditor> {
  PromptEditorController? _ownController;
  FocusNode? _ownFocus;
  PromptEditorController get controller => widget.controller ?? (_ownController ??= PromptEditorController());
  FocusNode get focusNode => widget.focusNode ?? (_ownFocus ??= FocusNode(debugLabel: 'prompt editor'));

  final _portal = OverlayPortalController();
  final _fieldKey = GlobalKey();
  final _searchFocus = FocusNode(debugLabel: 'prompt editor var search');
  late String _lastPrompt;
  _Resolution? _match;
  TextEditingValue? _dismissedAt;
  bool _blurHidden = false;
  Timer? _blurTimer;
  int _highlight = 0;
  bool _keyUsed = false;

  @override
  void initState() {
    super.initState();
    final c = controller;
    c.blocks = widget.blockSet;
    if (widget.value != null) c.prompt = widget.value!;
    _lastPrompt = c.prompt;
    _attach(c);
    _attachFocus(focusNode);
    _searchFocus.addListener(_onSearchFocusChange);
  }

  FocusOnKeyEventCallback? _hostKeyHandler;

  void _attachFocus(FocusNode f) {
    _hostKeyHandler = f.onKeyEvent;
    f
      ..onKeyEvent = (node, e) {
        final r = _onKey(node, e);
        return r == KeyEventResult.ignored ? (_hostKeyHandler?.call(node, e) ?? r) : r;
      }
      ..addListener(_onFocusChange);
  }

  void _detachFocus(FocusNode f) {
    f
      ..onKeyEvent = _hostKeyHandler
      ..removeListener(_onFocusChange);
  }

  void _attach(PromptEditorController c) {
    c
      ..chipBuilder = _chip
      ..variableValueStyle = const TextStyle(color: DifyColors.textAccent)
      ..onBlockCreated = ((b) {
        _configOf(b.kind)?.onInsert?.call();
      })
      ..onBlockRemoved = ((b) {
        _configOf(b.kind)?.onDelete?.call();
      })
      ..addListener(_onChanged);
  }

  void _detach(PromptEditorController c) {
    c
      ..removeListener(_onChanged)
      ..chipBuilder = null
      ..onBlockCreated = null
      ..onBlockRemoved = null;
  }

  ({void Function()? onInsert, void Function()? onDelete})? _configOf(PromptBlockKind k) {
    final w = widget;
    return switch (k) {
      PromptBlockKind.context => (onInsert: w.contextBlock?.onInsert, onDelete: w.contextBlock?.onDelete),
      PromptBlockKind.query => (onInsert: w.queryBlock?.onInsert, onDelete: w.queryBlock?.onDelete),
      PromptBlockKind.history => (onInsert: w.historyBlock?.onInsert, onDelete: w.historyBlock?.onDelete),
      PromptBlockKind.workflowVariable => (
        onInsert: w.workflowVariableBlock?.onInsert,
        onDelete: w.workflowVariableBlock?.onDelete,
      ),
      PromptBlockKind.current => (onInsert: w.currentBlock?.onInsert, onDelete: w.currentBlock?.onDelete),
      PromptBlockKind.requestUrl => (onInsert: w.requestUrlBlock?.onInsert, onDelete: w.requestUrlBlock?.onDelete),
      PromptBlockKind.errorMessage => (
        onInsert: w.errorMessageBlock?.onInsert,
        onDelete: w.errorMessageBlock?.onDelete,
      ),
      PromptBlockKind.lastRun => (onInsert: w.lastRunBlock?.onInsert, onDelete: w.lastRunBlock?.onDelete),
      PromptBlockKind.literal => null,
    };
  }

  @override
  void didUpdateWidget(DifyPromptEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    final old = oldWidget;
    if (old.controller != widget.controller) {
      _detach(old.controller ?? _ownController!);
      _attach(controller);
    }
    if (old.focusNode != widget.focusNode) {
      final prev = old.focusNode ?? _ownFocus;
      if (prev != null) _detachFocus(prev);
      _attachFocus(focusNode);
    }
    controller.blocks = widget.blockSet;
    // ValueSyncPlugin: a new value replaces the content (an unchanged one leaves the edits alone).
    final v = widget.value;
    if (v != null && v != old.value && v != controller.prompt) {
      _lastPrompt = v;
      controller.prompt = v;
    }
  }

  @override
  void dispose() {
    _blurTimer?.cancel();
    _detach(controller);
    _detachFocus(focusNode);
    _searchFocus.dispose();
    _ownController?.dispose();
    _ownFocus?.dispose();
    super.dispose();
  }

  // -- change, focus

  void _onChanged() {
    final p = controller.prompt;
    if (p != _lastPrompt) {
      _lastPrompt = p;
      widget.onChange?.call(p);
    }
    _updateMenu();
  }

  void _onFocusChange() {
    if (focusNode.hasFocus) {
      _blurTimer?.cancel();
      _blurHidden = false;
      widget.onFocus?.call();
    } else if (!_searchFocus.hasFocus) {
      widget.onBlur?.call();
      _blurTimer?.cancel();
      _blurTimer = Timer(const Duration(milliseconds: 200), () {
        _blurHidden = true;
        _updateMenu();
      });
    }
    _updateMenu();
  }

  /// The search box lost focus (`onBlur={handleClose}`); Dify then leaves the editor looking focused, this tells it.
  void _onSearchFocusChange() {
    if (_searchFocus.hasFocus) _blurTimer?.cancel();
    if (_searchFocus.hasFocus || focusNode.hasFocus) return;
    _dismiss();
    widget.onBlur?.call();
  }

  // -- typeahead (LexicalTypeaheadMenuPlugin)

  _Resolution? _resolve() {
    if (!widget.editable) return null;
    final v = controller.value;
    final sel = v.selection;
    if (!sel.isValid || !sel.isCollapsed) return null;
    final caret = sel.baseOffset;
    var start = caret;
    while (start > 0) {
      final c = v.text.codeUnitAt(start - 1);
      if (c == 0x0A || controller.blockAt(start - 1) != null) break;
      start--;
    }
    final before = v.text.substring(start, caret);
    _Resolution? best;
    for (final t in [if (!widget.disableBracePicker) '{', if (!widget.disableSlashPicker) '/']) {
      final m = pickerTriggerMatch(t, before);
      if (m == null) continue;
      final r = (trigger: t, leadOffset: start + m.leadOffset, caret: caret, query: m.matchingString);
      if (best == null || r.leadOffset > best.leadOffset) best = r;
    }
    return best;
  }

  bool get _menuVisible {
    final m = _match;
    if (m == null || _blurHidden || controller.value == _dismissedAt) return false;
    return (widget.workflowVariableBlock?.show ?? false) || _options(m).isNotEmpty;
  }

  void _updateMenu() {
    final m = _resolve();
    if (m?.query != _match?.query || m?.trigger != _match?.trigger) _highlight = 0;
    _match = m;
    if (!mounted) return;
    // The overlay can't be shown or hidden while building (a new value from the parent).
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) => mounted ? _syncPortal() : null);
    } else {
      _syncPortal();
    }
  }

  /// What this widget's build reads from the editor state besides the controller's own rebuilds: whether the menu
  /// shows, a block alone is selected (no selection highlight), and the text is empty (placeholder).
  Object? _view;

  void _syncPortal() {
    final show = _menuVisible;
    if (show != _portal.isShowing) show ? _portal.show() : _portal.hide();
    final view = (show, _chipSelected, controller.text.isEmpty);
    // Typing rebuilds only the text field unless the menu is open or one of those changes.
    if (show || view != _view) setState(() => _view = view);
  }

  bool get _chipSelected {
    final sel = controller.selection;
    return sel.isValid && sel.end == sel.start + 1 && controller.blockAt(sel.start) != null;
  }

  void _dismiss() {
    _dismissedAt = controller.value;
    _updateMenu();
  }

  /// The list used a key through its own keyboard handler; the editor must not act on it too.
  void _markKeyUsed() {
    _keyUsed = true;
    scheduleMicrotask(() => _keyUsed = false);
  }

  /// `$splitNodeContainingQuery(match).remove()`: the trigger and query before the caret; nothing without a caret.
  void _removeTrigger() {
    final m = _match;
    final sel = controller.selection;
    if (m == null || !sel.isValid || !sel.isCollapsed || sel.baseOffset < m.leadOffset) return;
    controller.value = TextEditingValue(
      text: controller.text.replaceRange(m.leadOffset, sel.baseOffset, ''),
      selection: TextSelection.collapsed(offset: m.leadOffset),
    );
  }

  /// handleSelectWorkflowVariable.
  void _selectVariable(List<String> variables) {
    _markKeyUsed();
    _removeTrigger();
    final PromptBlock? block;
    if (variables.length == 1) {
      block = switch (variables[0]) {
        'current' => const PromptBlock(PromptBlockKind.current),
        'error_message' => const PromptBlock(PromptBlockKind.errorMessage),
        'last_run' => const PromptBlock(PromptBlockKind.lastRun),
        _ => null,
      };
    } else if (variables[1] == 'sys.query' || variables[1] == 'sys.files') {
      block = PromptBlock.variable([variables[1]]);
    } else {
      block = PromptBlock.variable(variables);
    }
    if (block != null) controller.insertBlock(block);
    focusNode.requestFocus();
  }

  void _selectOption(PickerOption o) {
    _markKeyUsed();
    if (o.key.isNotEmpty) _removeTrigger();
    o.onSelect?.call();
    _dismiss();
    focusNode.requestFocus();
  }

  late final _actions = PickerActions(
    insertBlock: (kind) => controller.insertBlock(PromptBlock(kind)),
    insertText: (text) => controller.insertText(text),
    insertBraces: () {
      final c = controller;
      c.insertText('{{}}');
      c.selection = TextSelection.collapsed(offset: c.selection.baseOffset - 2);
    },
  );

  List<PickerOption> _options(_Resolution m) => pickerOptions(
    actions: _actions,
    queryString: m.query,
    contextBlock: widget.contextBlock,
    queryBlock: widget.queryBlock,
    historyBlock: widget.historyBlock,
    requestUrlBlock: widget.requestUrlBlock,
    variableBlock: widget.variableBlock,
    externalToolBlock: widget.externalToolBlock,
  );

  List<VarGroup> get _workflowVariableOptions => workflowVariableOptions(
    workflowVariableBlock: widget.workflowVariableBlock,
    errorMessageBlock: widget.errorMessageBlock,
    lastRunBlock: widget.lastRunBlock,
    currentBlock: widget.currentBlock,
  );

  bool get _slashList => _match?.trigger == '/' && (widget.workflowVariableBlock?.show ?? false);

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    if (_keyUsed) return KeyEventResult.handled;
    final m = _match;
    if (m == null || !_menuVisible) return KeyEventResult.ignored;
    final k = e.logicalKey;
    final kb = HardwareKeyboard.instance;
    // With `/` the variable list listens to the keyboard itself (Dify: on the document, before the editor).
    if (_slashList && !(kb.isAltPressed || kb.isControlPressed || kb.isMetaPressed)) {
      final arrowsOrEnter = {
        LogicalKeyboardKey.arrowDown,
        LogicalKeyboardKey.arrowUp,
        LogicalKeyboardKey.enter,
        LogicalKeyboardKey.numpadEnter,
      }.contains(k);
      if (arrowsOrEnter && filterReferenceVars(_workflowVariableOptions, m.query).any((g) => g.vars.isNotEmpty)) {
        return KeyEventResult.handled;
      }
    }
    final options = _options(m);
    if (k == LogicalKeyboardKey.escape) {
      _dismiss();
      return KeyEventResult.handled;
    }
    if (options.isEmpty) return KeyEventResult.ignored;
    if (k == LogicalKeyboardKey.arrowDown) {
      setState(() => _highlight = _highlight >= options.length - 1 ? 0 : _highlight + 1);
    } else if (k == LogicalKeyboardKey.arrowUp) {
      setState(() => _highlight = _highlight <= 0 ? options.length - 1 : _highlight - 1);
    } else if (k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.numpadEnter || k == LogicalKeyboardKey.tab) {
      _selectOption(options[_highlight.clamp(0, options.length - 1)]);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  // -- blocks

  Widget _chip(BuildContext context, PromptBlock b, int offset) {
    final sel = controller.selection;
    final selected = sel.isValid && sel.start == offset && sel.end == offset + 1;
    // useSelectOrDelete: a click selects the block, unless Cmd / Ctrl is held.
    void select() {
      final kb = HardwareKeyboard.instance;
      if (!widget.editable || kb.isMetaPressed || kb.isControlPressed) return;
      focusNode.requestFocus();
      controller.selection = TextSelection(baseOffset: offset, extentOffset: offset + 1);
    }

    final w = widget;
    return switch (b.kind) {
      PromptBlockKind.workflowVariable => WorkflowVariableChip(
        variables: b.variables,
        config: w.workflowVariableBlock ?? const WorkflowVariableBlockConfig(),
        selected: selected,
        onTap: select,
      ),
      PromptBlockKind.context => ContextChip(
        config: w.contextBlock ?? const ContextBlockConfig(),
        selected: selected,
        onTap: select,
      ),
      PromptBlockKind.history => HistoryChip(
        config: w.historyBlock ?? const HistoryBlockConfig(),
        selected: selected,
        onTap: select,
      ),
      PromptBlockKind.query => QueryChip(selected: selected, onTap: select),
      PromptBlockKind.current => CurrentChip(
        generatorType: w.currentBlock?.generatorType ?? PromptGeneratorType.prompt,
        selected: selected,
        onTap: select,
      ),
      PromptBlockKind.errorMessage => ErrorMessageChip(selected: selected, onTap: select),
      PromptBlockKind.lastRun => LastRunChip(selected: selected, onTap: select),
      PromptBlockKind.requestUrl => RequestUrlChip(selected: selected, onTap: select),
      PromptBlockKind.literal => Text(b.text),
    };
  }

  // -- clipboard: blocks copy as their text

  void _copy({required bool cut}) {
    final text = controller.selectedPrompt;
    if (text.isEmpty) return;
    Clipboard.setData(ClipboardData(text: text));
    if (cut && widget.editable) {
      final sel = controller.selection;
      controller.value = TextEditingValue(
        text: controller.text.replaceRange(sel.start, sel.end, ''),
        selection: TextSelection.collapsed(offset: sel.start),
      );
    }
  }

  Widget _contextMenu(BuildContext context, EditableTextState s) => AdaptiveTextSelectionToolbar.buttonItems(
    anchors: s.contextMenuAnchors,
    buttonItems: [
      for (final i in s.contextMenuButtonItems)
        switch (i.type) {
          ContextMenuButtonType.copy || ContextMenuButtonType.cut => i.copyWith(
            onPressed: () {
              _copy(cut: i.type == ContextMenuButtonType.cut);
              s.hideToolbar();
            },
          ),
          _ => i,
        },
    ],
  );

  // -- the menu overlay

  RenderEditable? _editable(RenderObject? root) {
    RenderEditable? found;
    void visit(RenderObject o) {
      if (found != null) return;
      if (o is RenderEditable) {
        found = o;
        return;
      }
      o.visitChildren(visit);
    }

    if (root != null) visit(root);
    return found;
  }

  Rect? _anchor(OverlayChildLayoutInfo info) {
    final m = _match;
    final box = _fieldKey.currentContext?.findRenderObject() as RenderBox?;
    final editable = _editable(box);
    if (m == null || box == null || editable == null || !editable.hasSize) return null;
    final end = m.caret.clamp(m.leadOffset, controller.text.length);
    final boxes = editable.getBoxesForSelection(TextSelection(baseOffset: m.leadOffset, extentOffset: end));
    if (boxes.isEmpty) return null;
    final local = boxes.map((b) => b.toRect()).reduce((a, b) => a.expandToInclude(b));
    return MatrixUtils.transformRect(info.childPaintTransform.multiplied(editable.getTransformTo(box)), local);
  }

  Widget _menu(BuildContext context, OverlayChildLayoutInfo info) {
    final m = _match;
    final anchor = _anchor(info);
    if (m == null || anchor == null || !_menuVisible) return const SizedBox.shrink();
    final w = widget;
    final wvb = w.workflowVariableBlock;
    final slash = m.trigger == '/';
    final options = _options(m);
    final showVars = wvb?.show ?? false;
    return CustomSingleChildLayout(
      delegate: _MenuLayout(anchor),
      child: TextFieldTapRegion(
        child: ComponentPickerMenu(
          queryString: m.query,
          options: options,
          selectedIndex: showVars ? null : _highlight,
          onSelect: _selectOption,
          onHighlight: (i) => setState(() => _highlight = i),
          variables: showVars
              ? VarReferenceVars(
                  key: ValueKey(m.trigger),
                  hideSearch: slash,
                  searchText: slash ? m.query : null,
                  vars: _workflowVariableOptions,
                  onChange: (sel, _) => _selectVariable(sel),
                  maxHeight: info.overlaySize.height * 0.34,
                  isSupportFileVar: w.isSupportFileVar,
                  onClose: () {
                    _markKeyUsed();
                    _dismiss();
                  },
                  showManageInputField: wvb!.showManageInputField,
                  onManageInputField: wvb.onManageInputField,
                  isInCodeGeneratorInstructionEditor: w.currentBlock?.generatorType == PromptGeneratorType.code,
                  searchFocusNode: _searchFocus,
                  tapRegionGroup: EditableText,
                )
              : null,
        ),
      ),
    );
  }

  // -- build

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final fontSize = w.compact ? 13.0 : 14.0;
    final lineHeight = w.lineHeight ?? (w.compact ? 20.0 : 24.0);
    // The strut in the text's own font: another font's ascent and descent would make lines taller than CSS's.
    final family = DefaultTextStyle.of(context).style.fontFamily ?? cardFontFamily;
    final style = TextStyle(
      fontFamily: family,
      fontSize: fontSize,
      height: lineHeight / fontSize,
      leadingDistribution: TextLeadingDistribution.even,
      color: DifyColors.textSecondary,
    );
    final chipSelected = _chipSelected;
    final empty = controller.text.isEmpty && !controller.value.composing.isValid;
    final placeholder = w.placeholder ?? DifyI18n.tr('common', 'promptEditor.placeholder');
    Widget field = Actions(
      actions: {
        CopySelectionTextIntent: CallbackAction<CopySelectionTextIntent>(
          onInvoke: (i) => _copy(cut: i.collapseSelection),
        ),
      },
      child: DefaultSelectionStyle(
        selectionColor: chipSelected ? const Color(0x00000000) : const Color(0xFFB4D5FE),
        child: TextField(
          controller: controller,
          focusNode: focusNode,
          readOnly: !w.editable,
          maxLines: null,
          expands: w.height != null,
          keyboardType: TextInputType.multiline,
          style: style,
          // An inline chip (18 px, `vertical-align: middle`) fits in a 20 or 24 px CSS line: those lines keep the
          // line height (a strut; without it Flutter would make a chip's line taller). In an 18 px line the chip
          // reaches out of it and makes it taller, which Flutter's own line metrics (no strut) come closest to.
          strutStyle: lineHeight >= chipFitsLineHeight
              ? StrutStyle(
                  fontFamily: family,
                  fontSize: fontSize,
                  height: lineHeight / fontSize,
                  leadingDistribution: TextLeadingDistribution.even,
                  forceStrutHeight: true,
                )
              : StrutStyle.disabled,
          cursorColor: DifyColors.textSecondary,
          cursorWidth: 1,
          decoration: const InputDecoration.collapsed(hintText: null),
          contextMenuBuilder: _contextMenu,
        ),
      ),
    );
    field = Semantics(label: w.semanticLabel, child: field);
    // The Stack stays when the placeholder goes, so the field keeps its state.
    field = Stack(
      children: [
        field,
        if (empty)
          Positioned.fill(
            child: IgnorePointer(
              child: placeholder is Widget
                  ? placeholder
                  : Text(
                      '$placeholder',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: style.copyWith(color: DifyColors.componentsInputTextPlaceholder),
                    ),
            ),
          ),
      ],
    );
    field = ConstrainedBox(
      constraints: BoxConstraints(minHeight: w.minHeight),
      child: w.height == null ? field : SizedBox(height: w.height, child: field),
    );
    return Material(
      type: MaterialType.transparency,
      child: OverlayPortal.overlayChildLayoutBuilder(
        controller: _portal,
        overlayLocation: OverlayChildLocation.rootOverlay,
        overlayChildBuilder: _menu,
        child: KeyedSubtree(key: _fieldKey, child: field),
      ),
    );
  }
}

/// floating-ui `bottom-start` with `shift({padding: 8})` and `flip()`: below the trigger, above it when it doesn't
/// fit below but does above (else the side with less overflow), kept 8 px inside the window horizontally.
class _MenuLayout extends SingleChildLayoutDelegate {
  _MenuLayout(this.anchor);
  final Rect anchor;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) => BoxConstraints.loose(constraints.biggest);

  @override
  Offset getPositionForChild(Size size, Size child) {
    final below = anchor.bottom + child.height - size.height;
    final above = child.height - anchor.top;
    final y = below > 0 && above < below ? anchor.top - child.height : anchor.bottom;
    final x = anchor.left < size.width - child.width - 8 ? anchor.left : size.width - child.width - 8;
    return Offset(x < 8 ? 8 : x, y);
  }

  @override
  bool shouldRelayout(_MenuLayout old) => old.anchor != anchor;
}
