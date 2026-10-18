/// invite-modal/email-recipients-field.tsx: the invitation form's recipient composer (chips plus a draft input).
library;

import 'dart:math' as math;

import 'package:flutter/material.dart' show InputBorder, InputDecoration, TextField, VisualDensity;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../settings_kit.dart';
import 'email_recipients.dart';

/// The field's own validation (`validateRecipients`): no recipient at all is "required", any invalid one "invalid";
/// null when the form may be sent. [draft] counts as typed recipients.
String? validateRecipients(BuildContext context, List<EmailRecipient> recipients, String draft) {
  final next = mergeEmailRecipients(recipients, draft);
  if (next.isEmpty) return stc(context, 'members.emailRequired');
  if (next.any((r) => !r.isValid)) return stc(context, 'members.emailInvalid');
  return null;
}

/// EmailRecipientsField: `Field name="emails"` with the label (and the recipient count once there are chips), the
/// composer box and either the error or the tip. Enter commits the draft (it stays, marked invalid, when an address
/// in it is invalid); typed separators wait for Enter; a paste holding separators becomes chips at once (merged with
/// the draft around the caret); Backspace in an empty draft removes the last chip; ArrowLeft / ArrowRight walk the
/// chips (which are no tab stops); Delete / Backspace on a chip removes it; Enter / Space on a chip edits an invalid
/// one (back into the draft) or returns to the input. [error] is the form's error for the field (after a submit, or
/// from the server); the field's own "invalid" error comes first.
class EmailRecipientsField extends StatefulWidget {
  const EmailRecipientsField({
    super.key,
    required this.recipients,
    required this.draft,
    required this.onRecipientsChange,
    required this.onDraftChange,
    this.onChange,
    this.disabled = false,
    this.error,
    this.focusNode,
    this.onSubmit,
  });

  final List<EmailRecipient> recipients;
  final String draft;
  final ValueChanged<List<EmailRecipient>> onRecipientsChange;
  final ValueChanged<String> onDraftChange;

  /// Any edit of the recipients or the draft.
  final VoidCallback? onChange;
  final bool disabled;
  final String? error;

  /// The draft input's focus (the form focuses it when the field is invalid).
  final FocusNode? focusNode;

  /// Enter with an empty draft: the form's submit (an input submits its form on Enter).
  final VoidCallback? onSubmit;

  @override
  State<EmailRecipientsField> createState() => _EmailRecipientsFieldState();
}

class _EmailRecipientsFieldState extends State<EmailRecipientsField> {
  late final _controller = TextEditingController(text: widget.draft);
  FocusNode? _ownFocus;
  final _chipNodes = <FocusNode>[];
  bool _draftTouched = false;
  bool _selectOnSync = false;
  bool _hovered = false;
  late String _last = widget.draft;

  FocusNode get _input => widget.focusNode ?? (_ownFocus ??= FocusNode(debugLabel: 'EmailRecipientsField'));

  @override
  void initState() {
    super.initState();
    _input.addListener(_focusChanged);
  }

  @override
  void didUpdateWidget(EmailRecipientsField old) {
    super.didUpdateWidget(old);
    if (old.focusNode != widget.focusNode) {
      (old.focusNode ?? _ownFocus)?.removeListener(_focusChanged);
      _input.addListener(_focusChanged);
    }
    if (_controller.text != widget.draft) {
      final t = widget.draft;
      _controller.value = TextEditingValue(
        text: t,
        selection: _selectOnSync
            ? TextSelection(baseOffset: 0, extentOffset: t.length)
            : TextSelection.collapsed(offset: t.length),
      );
      _last = t;
    }
    _selectOnSync = false;
  }

  @override
  void dispose() {
    _input.removeListener(_focusChanged);
    _controller.dispose();
    _ownFocus?.dispose();
    for (final n in _chipNodes) {
      n.dispose();
    }
    super.dispose();
  }

  bool _hadFocus = false;

  void _focusChanged() {
    final has = _input.hasFocus;
    // onBlur: the draft counts as touched (an invalid one shows its error).
    if (_hadFocus && !has) setState(() => _draftTouched = true);
    if (has != _hadFocus) setState(() {});
    _hadFocus = has;
  }

  FocusNode _chip(int i) {
    while (_chipNodes.length <= i) {
      _chipNodes.add(FocusNode(debugLabel: 'recipient chip ${_chipNodes.length}', skipTraversal: true));
    }
    return _chipNodes[i];
  }

  List<EmailRecipient> get _recipients => widget.recipients;
  List<EmailRecipient> get _draftRecipients => mergeEmailRecipients(const [], widget.draft);

  void _updateRecipients(List<EmailRecipient> next) {
    widget.onRecipientsChange(next);
    widget.onChange?.call();
  }

  void _updateDraft(String next) {
    widget.onDraftChange(next);
    widget.onChange?.call();
  }

  void _focusInput({bool select = false}) {
    _input.requestFocus();
    if (select) {
      _selectOnSync = true;
      _controller.selection = TextSelection(baseOffset: 0, extentOffset: _controller.text.length);
    }
  }

  void _removeRecipient(int index, {required bool focusNeighbor}) {
    final rs = _recipients;
    final next = [...rs]..removeAt(index);
    final nextFocusIndex = index < next.length ? index : index - 1;
    _updateRecipients(next);
    if (focusNeighbor && nextFocusIndex >= 0) {
      // The neighbour that follows (or precedes) the removed chip takes its place at nextFocusIndex.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && nextFocusIndex < _chipNodes.length) _chipNodes[nextFocusIndex].requestFocus();
      });
      return;
    }
    _focusInput();
  }

  void _editRecipient(int index) {
    final rs = _recipients;
    if (index >= rs.length) return;
    final r = rs[index];
    _updateRecipients([...rs]..removeAt(index));
    _selectOnSync = true;
    _updateDraft(r.value);
    setState(() => _draftTouched = false);
    _input.requestFocus();
  }

  void _commitDraft() {
    if (widget.draft.trim().isEmpty) return;
    if (_draftRecipients.any((r) => !r.isValid)) {
      setState(() => _draftTouched = true);
      return;
    }
    _updateRecipients(mergeEmailRecipients(_recipients, widget.draft));
    _updateDraft('');
    setState(() => _draftTouched = false);
  }

  bool _composing() {
    final c = _controller.value.composing;
    return c.isValid && !c.isCollapsed;
  }

  bool get _rtl => Directionality.maybeOf(context) == TextDirection.rtl;

  KeyEventResult _inputKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    if (widget.disabled) return KeyEventResult.ignored;
    final k = e.logicalKey;
    final enter = k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.numpadEnter;
    // An IME composition owns Enter (and Enter never submits meanwhile).
    if (_composing()) return enter ? KeyEventResult.handled : KeyEventResult.ignored;
    if (enter && widget.draft.trim().isNotEmpty) {
      _commitDraft();
      return KeyEventResult.handled;
    }
    if (enter && widget.onSubmit != null) {
      widget.onSubmit!();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.backspace && widget.draft.isEmpty && _recipients.isNotEmpty) {
      _updateRecipients(_recipients.sublist(0, _recipients.length - 1));
      return KeyEventResult.handled;
    }
    final chipKey = _rtl ? LogicalKeyboardKey.arrowRight : LogicalKeyboardKey.arrowLeft;
    if (k == chipKey && widget.draft.isEmpty && _recipients.isNotEmpty) {
      _chip(_recipients.length - 1).requestFocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  KeyEventResult _chipKey(int index, bool isValid, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    if (widget.disabled) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.backspace || k == LogicalKeyboardKey.delete) {
      _removeRecipient(index, focusNeighbor: true);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.numpadEnter || k == LogicalKeyboardKey.space) {
      isValid ? _focusInput() : _editRecipient(index);
      return KeyEventResult.handled;
    }
    final previous = _rtl ? LogicalKeyboardKey.arrowRight : LogicalKeyboardKey.arrowLeft;
    final next = _rtl ? LogicalKeyboardKey.arrowLeft : LogicalKeyboardKey.arrowRight;
    if (k == previous && index > 0) {
      _chip(index - 1).requestFocus();
      return KeyEventResult.handled;
    }
    if (k == next) {
      index < _recipients.length - 1 ? _chip(index + 1).requestFocus() : _focusInput();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// `onPaste`: a paste holding separators becomes chips at once, together with the draft around the caret (a
  /// selection is replaced); any other text is pasted into the draft.
  Future<void> _paste() async {
    if (widget.disabled) return;
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    if (text == null || text.isEmpty || !mounted) return;
    final v = _controller.value;
    final sel = v.selection.isValid ? v.selection : TextSelection.collapsed(offset: v.text.length);
    if (hasEmailDelimiter(text)) {
      _last = '';
      _updateRecipients(mergeEmailRecipients(_recipients, v.text.replaceRange(sel.start, sel.end, text)));
      _updateDraft('');
      setState(() => _draftTouched = false);
      return;
    }
    final next = v.text.replaceRange(sel.start, sel.end, text);
    _controller.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: sel.start + text.length),
    );
    _changed(next);
  }

  /// A text change: a paste holding separators (an insertion of more than one character containing one) becomes
  /// chips with the rest of the draft; anything else is the draft.
  void _changed(String text) {
    final before = _last;
    _last = text;
    var p = 0;
    while (p < before.length && p < text.length && before[p] == text[p]) {
      p++;
    }
    var s = 0;
    while (s < before.length - p && s < text.length - p && before[before.length - 1 - s] == text[text.length - 1 - s]) {
      s++;
    }
    final inserted = text.substring(p, text.length - s);
    if (inserted.length > 1 && hasEmailDelimiter(inserted)) {
      _updateRecipients(mergeEmailRecipients(_recipients, text));
      _updateDraft('');
      setState(() => _draftTouched = false);
      return;
    }
    _updateDraft(text);
    setState(() => _draftTouched = false);
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final rs = _recipients;
    final hasInvalidRecipient = rs.any((r) => !r.isValid);
    final hasInvalidDraft = _draftTouched && w.draft.trim().isNotEmpty && _draftRecipients.any((r) => !r.isValid);
    final ownError = hasInvalidRecipient || hasInvalidDraft ? stc(context, 'members.emailInvalid') : null;
    final error = ownError ?? w.error;
    final invalid = error != null;
    final focused = _input.hasFocus || _chipNodes.any((n) => n.hasFocus);
    final label = stc(context, 'members.emailRecipients');
    final tip = stc(context, 'members.emailRecipientsTip');

    Color bg = DifyColors.componentsInputBgNormal, border = const Color(0x00000000);
    if (w.disabled) {
      bg = DifyColors.componentsInputBgDisabled;
    } else if (invalid) {
      bg = DifyColors.componentsInputBgDestructive;
      border = DifyColors.componentsInputBorderDestructive;
    } else if (focused) {
      bg = DifyColors.componentsInputBgActive;
      border = DifyColors.componentsInputBorderActive;
    } else if (_hovered) {
      bg = DifyColors.componentsInputBgHover;
      border = DifyColors.componentsInputBorderHover;
    }

    final textStyle = difyTextStyle(
      DifyType.systemSmRegular,
      w.disabled ? DifyColors.componentsInputTextFilledDisabled : DifyColors.componentsInputTextFilled,
    );
    final input = Semantics(
      label: label,
      hint: invalid ? error : tip,
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: _inputKey,
        // The keyboard's paste gets the clipboard's text as it is (a single-line field drops its line breaks).
        child: Shortcuts(
          shortcuts: const {
            SingleActivator(LogicalKeyboardKey.keyV, control: true): _PasteIntent(),
            SingleActivator(LogicalKeyboardKey.keyV, meta: true): _PasteIntent(),
          },
          child: Actions(
            actions: {_PasteIntent: CallbackAction<_PasteIntent>(onInvoke: (_) => _paste())},
            child: SizedBox(
              height: 24,
              child: Center(
                child: TextField(
                  key: const ValueKey('email-recipients-input'),
                  controller: _controller,
                  focusNode: _input,
                  enabled: !w.disabled,
                  autocorrect: false,
                  enableSuggestions: false,
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.done,
                  onChanged: _changed,
                  // Enter with an empty draft submits the form (the form's Enter handler); never leave the field.
                  onEditingComplete: () {},
                  style: textStyle,
                  cursorColor: const Color(0xFF155EEF),
                  cursorWidth: 1,
                  maxLines: 1,
                  decoration: InputDecoration(
                    isCollapsed: true,
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.zero,
                    visualDensity: VisualDensity.standard,
                    hintText: rs.isEmpty ? stc(context, 'members.emailPlaceholder') : null,
                    hintStyle: textStyle.copyWith(color: DifyColors.componentsInputTextPlaceholder),
                    counterText: '',
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    final chips = [
      for (final (i, r) in rs.indexed)
        _RecipientChip(
          key: ValueKey('recipient-${r.value}'),
          recipient: r,
          focusNode: _chip(i),
          disabled: w.disabled,
          editLabel: '${stc(context, 'operation.edit')} ${r.value}',
          removeLabel: '${stc(context, 'operation.remove')} ${r.value}',
          onKey: (e) => _chipKey(i, r.isValid, e),
          onActivate: () => r.isValid ? _focusInput() : _editRecipient(i),
          onRemove: () => _removeRecipient(i, focusNeighbor: false),
          onFocusChange: () => setState(() {}),
        ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 4,
      children: [
        Row(
          spacing: 12,
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: difyTextStyle(DifyType.systemSmMedium, DifyColors.textSecondary),
                ),
              ),
            ),
            if (rs.isNotEmpty)
              Flexible(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Semantics(
                    liveRegion: true,
                    child: Text(
                      stc(context, 'members.recipientCount', {'count': rs.length}),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: difyTextStyle(
                        DifyType.bodyXsRegular,
                        DifyColors.textTertiary,
                      ).copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
                    ),
                  ),
                ),
              ),
          ],
        ),
        MouseRegion(
          cursor: w.disabled ? SystemMouseCursors.forbidden : SystemMouseCursors.text,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: w.disabled ? null : _input.requestFocus,
            child: AnimatedContainer(
              duration: difyTransitionDuration,
              curve: difyTransitionCurve,
              constraints: const BoxConstraints(minHeight: 40, maxHeight: 96),
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.circular(DifyRadius.lg),
                border: Border.all(color: border),
                boxShadow: focused && !w.disabled && !invalid ? DifyShadows.xs : null,
              ),
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Semantics(
                  container: true,
                  explicitChildNodes: true,
                  child: _RecipientsFlow(
                    spacing: 4,
                    minLastWidth: rs.isNotEmpty ? 48 : 160,
                    children: [...chips, input],
                  ),
                ),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Text(
            error ?? tip,
            key: ValueKey(error != null ? 'emails-error' : 'emails-description'),
            style: difyTextStyle(
              DifyType.bodyXsRegular,
              error != null ? DifyColors.textDestructive : DifyColors.textTertiary,
            ),
          ),
        ),
      ],
    );
  }
}

/// One recipient chip (`li`): `flex h-6 max-w-full items-center gap-1 rounded-md bg-components-badge-bg-gray-soft
/// px-2 system-xs-medium text-text-secondary`; an invalid address is `bg-components-badge-bg-red-soft
/// text-text-destructive` with `i-ri-error-warning-fill`. Its button (no tab stop) is named by the address, or "Edit
/// <address>" when invalid; the remove button is "Remove <address>".
class _RecipientChip extends StatefulWidget {
  const _RecipientChip({
    super.key,
    required this.recipient,
    required this.focusNode,
    required this.disabled,
    required this.editLabel,
    required this.removeLabel,
    required this.onKey,
    required this.onActivate,
    required this.onRemove,
    required this.onFocusChange,
  });

  final EmailRecipient recipient;
  final FocusNode focusNode;
  final bool disabled;
  final String editLabel, removeLabel;
  final KeyEventResult Function(KeyEvent e) onKey;
  final VoidCallback onActivate, onRemove, onFocusChange;

  @override
  State<_RecipientChip> createState() => _RecipientChipState();
}

class _RecipientChipState extends State<_RecipientChip> {
  bool _removeHovered = false;

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final r = w.recipient;
    final fg = r.isValid ? DifyColors.textSecondary : DifyColors.textDestructive;
    final focused = w.focusNode.hasFocus;
    return Container(
      height: 24,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: r.isValid ? DifyColors.componentsBadgeBgGraySoft : DifyColors.componentsBadgeBgRedSoft,
        borderRadius: BorderRadius.circular(DifyRadius.md),
      ),
      foregroundDecoration: focused
          ? BoxDecoration(
              borderRadius: BorderRadius.circular(DifyRadius.md),
              border: Border.all(color: DifyColors.componentsInputBorderActive),
            )
          : null,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 4,
        children: [
          Flexible(
            child: Semantics(
              button: true,
              enabled: !w.disabled,
              label: r.isValid ? r.value : w.editLabel,
              hint: r.isValid ? null : stc(context, 'members.emailInvalid'),
              onTap: w.disabled ? null : w.onActivate,
              excludeSemantics: true,
              child: Focus(
                focusNode: w.focusNode,
                canRequestFocus: !w.disabled,
                onFocusChange: (_) {
                  setState(() {});
                  w.onFocusChange();
                },
                onKeyEvent: (_, e) => w.onKey(e),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: w.disabled ? null : w.onActivate,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    spacing: 4,
                    children: [
                      if (!r.isValid) RemixIcon('error-warning-fill', size: 14, color: fg),
                      Flexible(
                        child: Text(
                          r.value,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: difyTextStyle(DifyType.systemXsMedium, fg),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          Semantics(
            button: true,
            enabled: !w.disabled,
            label: w.removeLabel,
            onTap: w.disabled ? null : w.onRemove,
            excludeSemantics: true,
            child: MouseRegion(
              cursor: w.disabled ? SystemMouseCursors.forbidden : SystemMouseCursors.click,
              onEnter: (_) => setState(() => _removeHovered = true),
              onExit: (_) => setState(() => _removeHovered = false),
              child: GestureDetector(
                key: ValueKey('remove-${r.value}'),
                behavior: HitTestBehavior.opaque,
                onTap: w.disabled ? null : w.onRemove,
                child: Opacity(
                  opacity: w.disabled ? 0.5 : 1,
                  child: Container(
                    width: 16,
                    height: 16,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: _removeHovered && !w.disabled ? DifyColors.stateBaseHover : null,
                      borderRadius: BorderRadius.circular(DifyRadius.sm),
                    ),
                    child: RemixIcon(
                      'close-line',
                      size: 14,
                      color: _removeHovered && !w.disabled ? DifyColors.textSecondary : DifyColors.textTertiary,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// `flex flex-wrap content-start items-center gap-[spacing]` where the last child (the input, `w-0 flex-1
/// min-w-[minLastWidth]`) takes the rest of its line, or a new line when less than [minLastWidth] is left.
class _RecipientsFlow extends MultiChildRenderObjectWidget {
  const _RecipientsFlow({required this.spacing, required this.minLastWidth, required super.children});

  final double spacing, minLastWidth;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderRecipientsFlow(spacing: spacing, minLastWidth: minLastWidth);

  @override
  void updateRenderObject(BuildContext context, _RenderRecipientsFlow renderObject) => renderObject
    ..spacing = spacing
    ..minLastWidth = minLastWidth;
}

class _FlowData extends ContainerBoxParentData<RenderBox> {}

class _RenderRecipientsFlow extends RenderBox
    with ContainerRenderObjectMixin<RenderBox, _FlowData>, RenderBoxContainerDefaultsMixin<RenderBox, _FlowData> {
  _RenderRecipientsFlow({required this._spacing, required this._minLastWidth});

  double _spacing, _minLastWidth;
  set spacing(double v) {
    if (v == _spacing) return;
    _spacing = v;
    markNeedsLayout();
  }

  set minLastWidth(double v) {
    if (v == _minLastWidth) return;
    _minLastWidth = v;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _FlowData) child.parentData = _FlowData();
  }

  @override
  void performLayout() {
    final maxW = constraints.maxWidth;
    final lines = <List<RenderBox>>[[]];
    var x = 0.0;
    var child = firstChild;
    while (child != null) {
      final last = child == lastChild;
      if (last) {
        final left = lines.last.isEmpty ? maxW : maxW - x;
        final fits = left >= math.min(_minLastWidth, maxW);
        if (!fits) {
          lines.add([]);
          x = 0;
        }
        final width = math.max(0.0, lines.last.isEmpty ? maxW : maxW - x);
        child.layout(BoxConstraints.tightFor(width: width), parentUsesSize: true);
      } else {
        child.layout(BoxConstraints(maxWidth: maxW), parentUsesSize: true);
        final w = child.size.width;
        if (lines.last.isNotEmpty && x + w > maxW) {
          lines.add([]);
          x = 0;
        }
      }
      lines.last.add(child);
      x += child.size.width + _spacing;
      child = (child.parentData! as _FlowData).nextSibling;
    }
    var y = 0.0;
    for (final (i, line) in lines.indexed) {
      if (line.isEmpty) continue;
      final h = line.fold(0.0, (m, c) => math.max(m, c.size.height));
      var lx = 0.0;
      for (final c in line) {
        (c.parentData! as _FlowData).offset = Offset(lx, y + (h - c.size.height) / 2);
        lx += c.size.width + _spacing;
      }
      y += h + (i < lines.length - 1 ? _spacing : 0);
    }
    size = constraints.constrain(Size(maxW, y));
  }

  @override
  double computeMinIntrinsicHeight(double width) => 24;

  @override
  double computeMaxIntrinsicHeight(double width) => 24;

  @override
  void paint(PaintingContext context, Offset offset) => defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}

class _PasteIntent extends Intent {
  const _PasteIntent();
}
