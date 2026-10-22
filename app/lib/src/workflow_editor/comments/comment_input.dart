/// The comment text box with @mentions (comment/mention-input.tsx) and the box of a new comment on the canvas
/// (comment/comment-input.tsx).
library;

import 'package:flutter/gestures.dart';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../design/css_metrics.dart';
import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../i18n/dify_i18n.dart';
import '../store/workflow_store.dart' show MousePosition;
import 'comment_icon.dart' show CommentAvatar;
import 'workflow_comment.dart';

String _tc(String key) => DifyI18n.tr('common', key);

/// The mention dropdowns open now (Dify's `[data-mention-dropdown]` in the document): the thread leaves Escape to
/// them.
final openMentionDropdowns = ValueNotifier(0);

/// A key handler over the whole app while mounted (Dify's `document.addEventListener('keydown', …, true)`): Escape
/// calls [onEscape] and is consumed when [when] says so.
class EscapeListener extends StatefulWidget {
  const EscapeListener({super.key, required this.onEscape, this.when, required this.child});
  final VoidCallback onEscape;
  final bool Function()? when;
  final Widget child;

  @override
  State<EscapeListener> createState() => _EscapeListenerState();
}

class _EscapeListenerState extends State<EscapeListener> {
  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_key);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_key);
    super.dispose();
  }

  bool _key(KeyEvent e) {
    if (e is! KeyDownEvent || e.logicalKey != LogicalKeyboardKey.escape) return false;
    if (!(widget.when?.call() ?? true)) return false;
    widget.onEscape();
    return true;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Colours the `@name` mentions of the text in `text-primary-600` (the highlight layer under Dify's textarea).
class MentionTextController extends TextEditingController {
  MentionTextController({super.text});

  Iterable<String> names = const [];

  @override
  TextSpan buildTextSpan({required BuildContext context, TextStyle? style, required bool withComposing}) {
    final ranges = mentionRanges(text, names);
    if (ranges.isEmpty) return super.buildTextSpan(context: context, style: style, withComposing: withComposing);
    final spans = <TextSpan>[];
    var at = 0;
    for (final (s, e) in ranges) {
      if (s > at) spans.add(TextSpan(text: text.substring(at, s)));
      spans.add(
        TextSpan(
          text: text.substring(s, e),
          style: TextStyle(color: DifyColors.primary600),
        ),
      );
      at = e;
    }
    if (at < text.length) spans.add(TextSpan(text: text.substring(at)));
    return TextSpan(style: style, children: spans);
  }
}

final _mentionTrigger = RegExp(r'@(\w*)$');

/// mention-input.tsx: a 1–4 line text box (`body-lg-regular leading-6`, 4 to 4 lines while [isEditing]) whose
/// `@` opens a list of the people to mention, filtered by what follows it (arrow keys move, Enter picks, Escape
/// closes). Enter sends (Shift+Enter is a new line); the actions are an `@` button and the round send button at the
/// right, under the text once it wraps, or `@`, Cancel and Save below it while editing. [onSubmit] gets the trimmed
/// text and the mentioned ids.
class MentionInput extends StatefulWidget {
  const MentionInput({
    super.key,
    required this.value,
    required this.onChange,
    required this.onSubmit,
    required this.users,
    this.onCancel,
    this.placeholder,
    this.disabled = false,
    this.loading = false,
    this.isEditing = false,
    this.autoFocus = false,
    this.focusNode,
  });

  final String value;
  final ValueChanged<String> onChange;
  final Future<void> Function(String content, List<String> mentionedUserIds) onSubmit;
  final VoidCallback? onCancel;
  final List<CommentUser> users;
  final String? placeholder;
  final bool disabled, loading, isEditing, autoFocus;
  final FocusNode? focusNode;

  @override
  State<MentionInput> createState() => _MentionInputState();
}

class _MentionInputState extends State<MentionInput> {
  late final _text = MentionTextController(text: widget.value);
  FocusNode? _ownFocus;
  FocusNode get _focus => widget.focusNode ?? (_ownFocus ??= FocusNode(debugLabel: 'mention input'));
  final _dropdown = OverlayPortalController();
  final _list = ScrollController();

  bool _showDropdown = false;
  String _query = '';
  int _mentionPosition = 0, _selected = 0;
  List<String> _mentioned = [];

  // TextField takes the Material text theme, not the editor's DefaultTextStyle: the font is set here.
  // `body-lg-regular leading-6` (mention-input.tsx).
  static TextStyle get _style => DifyType.bodyLgRegular.style.copyWith(
    fontFamily: cardFontFamily,
    height: 24 / 15,
    color: DifyColors.textPrimary,
  );

  @override
  void initState() {
    super.initState();
    _text.addListener(_textChanged);
    if (widget.autoFocus) {
      // `setTimeout(0)`: focus with the caret at the end.
      Future(() {
        if (!mounted) return;
        _focus.requestFocus();
        _text.selection = TextSelection.collapsed(offset: _text.text.length);
      });
    }
  }

  @override
  void didUpdateWidget(MentionInput old) {
    super.didUpdateWidget(old);
    if (widget.value != _text.text) {
      _text.value = TextEditingValue(
        text: widget.value,
        selection: TextSelection.collapsed(offset: widget.value.length),
      );
    }
    if (widget.value.isEmpty) _reset();
  }

  @override
  void dispose() {
    _setDropdown(false);
    _text.dispose();
    _ownFocus?.dispose();
    _list.dispose();
    super.dispose();
  }

  List<CommentUser> get _filtered {
    if (_query.isEmpty) return widget.users;
    final q = _query.toLowerCase();
    return [
      for (final u in widget.users)
        if (u.name.toLowerCase().contains(q) || u.id.toLowerCase().contains(q)) u,
    ];
  }

  void _setDropdown(bool show) {
    if (show == _showDropdown) return;
    _showDropdown = show;
    openMentionDropdowns.value += show ? 1 : -1;
  }

  void _reset() {
    _mentioned = [];
    _setDropdown(false);
    _query = '';
    _mentionPosition = 0;
    _selected = 0;
  }

  int get _cursor => _text.selection.baseOffset < 0 ? _text.text.length : _text.selection.baseOffset;

  /// handleContentChange: an `@word` just before the caret opens the list for that word.
  void _textChanged() {
    final value = _text.text;
    if (value != widget.value) widget.onChange(value);
    final before = value.substring(0, _cursor.clamp(0, value.length));
    final m = _mentionTrigger.firstMatch(before);
    setState(() {
      if (m != null) {
        _query = m.group(1)!;
        _mentionPosition = before.length - m.group(0)!.length;
        _setDropdown(true);
        _selected = 0;
      } else {
        _setDropdown(false);
      }
    });
    _syncPortal();
  }

  void _syncPortal() {
    final show = _showDropdown && _filtered.isNotEmpty;
    if (show == _dropdown.isShowing) return;
    show ? _dropdown.show() : _dropdown.hide();
  }

  bool get _mentionButtonDisabled {
    if (_showDropdown) return true;
    final value = _text.text;
    return _mentionTrigger.hasMatch(value.substring(0, _cursor.clamp(0, value.length)));
  }

  /// handleMentionButtonClick: an `@` at the caret, and the list.
  void _mentionButton() {
    if (_mentionButtonDisabled) return;
    final value = _text.text, at = _cursor.clamp(0, value.length);
    _text.value = TextEditingValue(
      text: '${value.substring(0, at)}@${value.substring(at)}',
      selection: TextSelection.collapsed(offset: at + 1),
    );
    _focus.requestFocus();
  }

  /// insertMention: `@name ` in place of the typed `@word` (with a space before it when needed).
  void _insert(CommentUser user) {
    final value = _text.text;
    final before = value.substring(0, _mentionPosition);
    final after = value.substring(_cursor.clamp(_mentionPosition, value.length));
    final space = _mentionPosition > 0 && !RegExp(r'\s').hasMatch(value[_mentionPosition - 1]);
    final inserted = '${space ? ' ' : ''}@${user.name} ';
    _mentioned = [..._mentioned, user.id];
    _setDropdown(false);
    _text.value = TextEditingValue(
      text: '$before$inserted$after',
      selection: TextSelection.collapsed(offset: before.length + inserted.length),
    );
    _focus.requestFocus();
  }

  Future<void> _submit() async {
    final value = _text.text.trim();
    if (value.isEmpty) return;
    try {
      await widget.onSubmit(value, _mentioned);
      _mentioned = [];
      setState(() => _setDropdown(false));
      _syncPortal();
    } catch (e) {
      debugPrint('Failed to submit: $e');
    }
  }

  KeyEventResult _key(FocusNode node, KeyEvent e) {
    if (e is KeyUpEvent || _text.value.composing.isValid) return KeyEventResult.ignored;
    final users = _filtered;
    if (_showDropdown) {
      switch (e.logicalKey) {
        case LogicalKeyboardKey.arrowDown when users.isNotEmpty:
          setState(() => _selected = _selected < users.length - 1 ? _selected + 1 : 0);
          return KeyEventResult.handled;
        case LogicalKeyboardKey.arrowUp when users.isNotEmpty:
          setState(() => _selected = _selected > 0 ? _selected - 1 : users.length - 1);
          return KeyEventResult.handled;
        case LogicalKeyboardKey.enter || LogicalKeyboardKey.numpadEnter:
          if (_selected < users.length) _insert(users[_selected]);
          return KeyEventResult.handled;
        case LogicalKeyboardKey.escape:
          setState(() => _setDropdown(false));
          _syncPortal();
          return KeyEventResult.handled;
      }
    }
    if ((e.logicalKey == LogicalKeyboardKey.enter || e.logicalKey == LogicalKeyboardKey.numpadEnter) &&
        !HardwareKeyboard.instance.isShiftPressed &&
        !_showDropdown) {
      _submit();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Whether the text wraps at the single-line width (Dify's `hasMultiline`): the actions then go under it.
  bool _multiline(double width) {
    if (_text.text.contains('\n')) return true;
    final p = TextPainter(
      text: TextSpan(text: _text.text, style: _style),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
    )..layout(maxWidth: (width - 8 - 76).clamp(0, double.infinity));
    final lines = p.computeLineMetrics().length;
    p.dispose();
    return lines > 1;
  }

  @override
  Widget build(BuildContext context) {
    _text.names = [for (final u in widget.users) u.name];
    return LayoutBuilder(
      builder: (context, constraints) {
        final editing = widget.isEditing;
        final multiline = !editing && _multiline(constraints.maxWidth);
        // The text keeps clear of the actions: at its right on one line (76 px: `@`, gap-1, ml-2 and send), under it
        // once it wraps or while editing (the 32 px buttons).
        final padRight = 4.0 + (!editing && !multiline ? 76 : 0);
        final padBottom = 4.0 + (editing || multiline ? 32 : 0);
        final off = widget.disabled || widget.loading;
        final field = Focus(
          onKeyEvent: _key,
          canRequestFocus: false,
          skipTraversal: true,
          child: DifyTextField(
            controller: _text,
            focusNode: _focus,
            enabled: !off,
            style: _style,
            cursorColor: DifyColors.primary500,
            cursorWidth: 1,
            minLines: editing ? 4 : 1,
            maxLines: 4,
            keyboardType: TextInputType.multiline,
            onTap: () => _textChanged(),
            decoration: DifyFieldDecoration(
              contentPadding: EdgeInsets.fromLTRB(4, 4, padRight, padBottom),
              hintText: widget.placeholder ?? tw('comments.placeholder.add'),
              hintStyle: _style.copyWith(color: DifyColors.textTertiary),
            ),
          ),
        );
        final at = DifyIconButton(
          label: tw('nodes.agent.task.mention'),
          size: DifyIconButtonSize.lg,
          disabled: _mentionButtonDisabled,
          onPressed: _mentionButton,
          icon: Opacity(
            opacity: _mentionButtonDisabled ? 0.4 : 1,
            child: RemixIcon('at-line', size: 16, color: DifyColors.textTertiary),
          ),
        );
        final actions = editing
            ? Positioned(
                left: 4,
                right: 4,
                bottom: 0,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    at,
                    const Spacer(),
                    Flexible(
                      child: DifyButton(
                        size: DifyButtonSize.small,
                        disabled: widget.loading,
                        onPressed: widget.onCancel,
                        child: Text(_tc('operation.cancel')),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: DifyButton(
                        variant: DifyButtonVariant.primary,
                        size: DifyButtonSize.small,
                        disabled: widget.loading || _text.text.trim().isEmpty,
                        loading: widget.loading,
                        onPressed: _submit,
                        trailing: widget.loading ? null : const DifyIcon('public/common/enter-key', size: 16),
                        child: Text(_tc('operation.save')),
                      ),
                    ),
                  ],
                ),
              )
            : Positioned(
                right: 4,
                bottom: 0,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  spacing: 12,
                  children: [
                    at,
                    DifyIconButton(
                      label: _tc('operation.send'),
                      size: DifyIconButtonSize.lg,
                      variant: DifyButtonVariant.primary,
                      disabled: _text.text.trim().isEmpty || off,
                      onPressed: _submit,
                      icon: widget.loading
                          ? const DifySpinnerIcon(child: RemixIcon('loader-2-line', size: 16))
                          : const RemixIcon('arrow-up-line', size: 16),
                    ),
                  ],
                ),
              );
        return OverlayPortal.overlayChildLayoutBuilder(
          controller: _dropdown,
          overlayLocation: OverlayChildLocation.rootOverlay,
          overlayChildBuilder: (context, info) {
            final rect = MatrixUtils.transformRect(info.childPaintTransform, Offset.zero & info.childSize);
            final below = info.overlaySize.height - rect.bottom, above = rect.top;
            final up = below < 160 && above > below;
            return Positioned(
              left: rect.left,
              top: up ? null : rect.bottom + 4,
              bottom: up ? info.overlaySize.height - rect.top + 4 : null,
              child: _MentionList(
                users: _filtered,
                selected: _selected,
                controller: _list,
                onPick: _insert,
              ),
            );
          },
          child: Stack(
            children: [
              field,
              actions,
            ],
          ),
        );
      },
    );
  }
}

/// The mention list (`fixed z-50 max-h-62 w-70 overflow-y-auto rounded-xl border-[0.5px] bg-components-panel-bg/95
/// shadow-lg backdrop-blur-[10px]`): a row per person (`gap-2 rounded-md py-1 pr-3 pl-2`, the highlighted one and
/// the hovered one in `state-base-hover`) with the avatar and the name.
class _MentionList extends StatelessWidget {
  const _MentionList({required this.users, required this.selected, required this.controller, required this.onPick});
  final List<CommentUser> users;
  final int selected;
  final ScrollController controller;
  final ValueChanged<CommentUser> onPick;

  @override
  Widget build(BuildContext context) => TapRegion(
    groupId: EditableText,
    child: DifyBlurredBox(
      blur: 10,
      borderRadius: BorderRadius.circular(DifyRadius.xl),
      decoration: BoxDecoration(
        color: DifyColors.componentsPanelBg.withValues(alpha: DifyColors.componentsPanelBg.a * 0.95),
        border: Border.all(color: DifyColors.componentsPanelBorder, width: Css.hairline),
        borderRadius: BorderRadius.circular(DifyRadius.xl),
        boxShadow: DifyShadows.lg,
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints.tightFor(width: 280 - 1).copyWith(maxHeight: 248 - 1),
        child: ListView.builder(
          controller: controller,
          shrinkWrap: true,
          padding: EdgeInsets.zero,
          itemCount: users.length,
          itemBuilder: (context, i) => _MentionRow(user: users[i], selected: i == selected, onPick: onPick),
        ),
      ),
    ),
  );
}

class _MentionRow extends StatefulWidget {
  const _MentionRow({required this.user, required this.selected, required this.onPick});
  final CommentUser user;
  final bool selected;
  final ValueChanged<CommentUser> onPick;

  @override
  State<_MentionRow> createState() => _MentionRowState();
}

class _MentionRowState extends State<_MentionRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: SystemMouseCursors.click,
    onEnter: (_) => setState(() => _hovered = true),
    onExit: (_) => setState(() => _hovered = false),
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => widget.onPick(widget.user),
      child: Container(
        padding: const EdgeInsets.fromLTRB(8, 4, 12, 4),
        decoration: BoxDecoration(
          color: _hovered || widget.selected ? DifyColors.stateBaseHover : null,
          borderRadius: BorderRadius.circular(DifyRadius.md),
        ),
        child: Row(
          spacing: 8,
          children: [
            CommentAvatar(name: widget.user.name),
            Expanded(
              child: Text(
                widget.user.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: difyTextStyle(DifyType.systemMdMedium, DifyColors.textPrimary),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// comment-input.tsx: a new comment's box at [position] (its top-left, in the canvas), 384 px wide: the drag handle
/// with the current user's avatar (in a primary teardrop) and the [MentionInput]. Escape cancels; the handle drags the
/// box, or with the keyboard Enter / Space starts and ends moving it with the arrow keys (5 px, 20 with Shift).
/// [disabled] (the preview that follows the pointer while placing): faded, inert.
class CommentInput extends StatefulWidget {
  const CommentInput({
    super.key,
    required this.position,
    required this.onSubmit,
    required this.onCancel,
    required this.users,
    required this.currentUser,
    this.autoFocus = true,
    this.disabled = false,
    this.onPositionChange,
  });

  final Offset position;
  final Future<void> Function(String content, List<String> mentionedUserIds) onSubmit;
  final VoidCallback onCancel;
  final List<CommentUser> users;
  final CommentUser currentUser;
  final bool autoFocus, disabled;
  final ValueChanged<MousePosition>? onPositionChange;

  @override
  State<CommentInput> createState() => _CommentInputState();
}

class _CommentInputState extends State<CommentInput> {
  String _content = '';
  bool _keyboardMoving = false;
  final _handleFocus = FocusNode(debugLabel: 'move draft comment');
  ({int pointer, Offset start, Offset from})? _drag;

  @override
  void initState() {
    super.initState();
    _handleFocus.addListener(() {
      if (!_handleFocus.hasFocus && _keyboardMoving) setState(() => _keyboardMoving = false);
    });
  }

  @override
  void dispose() {
    _stopDragging();
    _handleFocus.dispose();
    super.dispose();
  }

  bool get _canMove => !widget.disabled && widget.onPositionChange != null;

  // Dify follows the pointer on the window once the handle is pressed.
  void _dragDown(PointerDownEvent e) {
    if (e.buttons != kPrimaryButton || !_canMove) return;
    _drag = (pointer: e.pointer, start: e.position, from: widget.position);
    GestureBinding.instance.pointerRouter.addGlobalRoute(_dragRoute);
  }

  void _dragRoute(PointerEvent e) {
    final d = _drag;
    if (d == null || e.pointer != d.pointer) return;
    if (e is PointerMoveEvent) {
      final delta = e.position - d.start;
      widget.onPositionChange?.call((
        pageX: e.position.dx,
        pageY: e.position.dy,
        elementX: d.from.dx + delta.dx,
        elementY: d.from.dy + delta.dy,
      ));
    } else if (e is PointerUpEvent || e is PointerCancelEvent) {
      _stopDragging();
    }
  }

  void _stopDragging() {
    if (_drag == null) return;
    _drag = null;
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_dragRoute);
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent e) {
    if (e is KeyDownEvent && (e.logicalKey == LogicalKeyboardKey.enter || e.logicalKey == LogicalKeyboardKey.space)) {
      if (_canMove) setState(() => _keyboardMoving = !_keyboardMoving);
      return KeyEventResult.handled;
    }
    final delta = keyboardMovement(e);
    if (delta == null) return KeyEventResult.ignored;
    // Arrow keys never move focus off a button (as in a browser).
    if (e is KeyUpEvent || !_keyboardMoving || !_canMove) return KeyEventResult.handled;
    final box = context.findRenderObject() as RenderBox?;
    final page = (box?.localToGlobal(Offset.zero) ?? widget.position) + delta;
    final to = widget.position + delta;
    widget.onPositionChange?.call((pageX: page.dx, pageY: page.dy, elementX: to.dx, elementY: to.dy));
    return KeyEventResult.handled;
  }

  Future<void> _submit(String content, List<String> ids) async {
    final done = widget.onSubmit(content, ids);
    setState(() => _content = '');
    await done;
  }

  static const _teardrop = BorderRadius.only(
    topLeft: Radius.circular(16),
    topRight: Radius.circular(16),
    bottomRight: Radius.circular(16),
  );
  static const _innerTeardrop = BorderRadius.only(
    topLeft: Radius.circular(14),
    topRight: Radius.circular(14),
    bottomRight: Radius.circular(14),
  );

  @override
  Widget build(BuildContext context) {
    final handle = Semantics(
      button: true,
      toggled: _keyboardMoving,
      enabled: _canMove,
      label: tw('keyboard.moveDraftComment'),
      hint:
          '${tw('keyboard.moveDraftHelp')} '
          '${tw('keyboard.position', {'x': widget.position.dx, 'y': widget.position.dy})}',
      child: Focus(
        focusNode: _handleFocus,
        canRequestFocus: _canMove,
        skipTraversal: !_canMove,
        onKeyEvent: _handleKey,
        child: Listener(
          onPointerDown: _dragDown,
          child: MouseRegion(
            cursor: SystemMouseCursors.move,
            child: ExcludeSemantics(
              child: Container(
                width: 32,
                height: 32,
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(color: DifyColors.primary500, borderRadius: _teardrop),
                child: Container(
                  padding: const EdgeInsets.all(2),
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    color: DifyColors.componentsPanelBgBlur,
                    borderRadius: _innerTeardrop,
                  ),
                  child: CommentAvatar(name: widget.currentUser.name),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final box = Container(
      padding: const EdgeInsets.only(bottom: 4),
      decoration: BoxDecoration(
        color: DifyColors.componentsPanelBgBlur,
        border: Border.all(color: DifyColors.componentsChatInputBorder),
        borderRadius: BorderRadius.circular(DifyRadius.xl),
        boxShadow: DifyShadows.md,
      ),
      child: Padding(
        padding: const EdgeInsets.only(top: 4, left: 9),
        child: MentionInput(
          value: _content,
          onChange: (v) => setState(() => _content = v),
          onSubmit: _submit,
          users: widget.users,
          placeholder: tw('comments.placeholder.add'),
          autoFocus: widget.autoFocus,
          disabled: widget.disabled,
        ),
      ),
    );
    Widget input = SizedBox(
      width: 384,
      child: Row(
        spacing: 12,
        children: [
          handle,
          Expanded(child: box),
        ],
      ),
    );
    if (widget.disabled) input = IgnorePointer(child: Opacity(opacity: 0.8, child: input));
    // Tab moves in the document's order: the handle, the text, `@`, send.
    return EscapeListener(
      onEscape: widget.onCancel,
      child: FocusTraversalGroup(policy: WidgetOrderTraversalPolicy(), child: input),
    );
  }
}
