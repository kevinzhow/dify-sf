import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../../canvas/live_card.dart' show OverflowHitStack;
import '../../cards/bodies/note_body.dart';
import '../../cards/bodies/note_text.dart';
import '../../design/css_metrics.dart';
import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../i18n/dify_i18n.dart';
import 'note_editor_controller.dart';

/// note-editor/context.tsx NoteEditorContext: the editor's controller (and its store) for the editor, the toolbar
/// and the link popup.
class NoteEditorScope extends InheritedWidget {
  const NoteEditorScope({super.key, required this.controller, required this.focusNode, required super.child});

  final NoteEditorController controller;
  final FocusNode focusNode;

  /// `useStore` / `useNoteEditorStore`: throws without a provider above [context].
  static NoteEditorScope of(BuildContext context) {
    final s = context.getInheritedWidgetOfExactType<NoteEditorScope>();
    if (s == null) throw StateError('Missing NoteEditorContext.Provider in the tree');
    return s;
  }

  /// Gives the editor the keyboard back after a toolbar action (popups return focus to their trigger first).
  void refocus() {
    SchedulerBinding.instance
      ..addPostFrameCallback((_) {
        if (focusNode.context != null) focusNode.requestFocus();
      })
      ..scheduleFrame();
  }

  @override
  bool updateShouldNotify(NoteEditorScope old) => old.controller != controller;
}

/// NoteEditorContextProvider: one editor for [value] (Dify's `data.text`), kept in step with it
/// (NoteEditorContentSynchronizer: a new value different from what the editor holds replaces its content).
class NoteEditorProvider extends StatefulWidget {
  const NoteEditorProvider({
    super.key,
    this.value = '',
    this.editable = true,
    this.openUrl,
    this.onInvalidUrl,
    required this.child,
  });

  final String value;
  final bool editable;
  final void Function(String url)? openUrl;
  final VoidCallback? onInvalidUrl;
  final Widget child;

  @override
  State<NoteEditorProvider> createState() => _NoteEditorProviderState();
}

class _NoteEditorProviderState extends State<NoteEditorProvider> {
  late final controller = NoteEditorController(
    value: widget.value,
    editable: widget.editable,
    openUrl: widget.openUrl,
    onInvalidUrl: widget.onInvalidUrl,
  );
  final focusNode = FocusNode(debugLabel: 'note editor');

  @override
  void didUpdateWidget(NoteEditorProvider old) {
    super.didUpdateWidget(old);
    controller
      ..editable = widget.editable
      ..openUrl = widget.openUrl
      ..onInvalidUrl = widget.onInvalidUrl;
    if (widget.value != old.value && widget.value != controller.note.toLexical()) controller.load(widget.value);
  }

  @override
  void dispose() {
    controller.dispose();
    focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      NoteEditorScope(controller: controller, focusNode: focusNode, child: widget.child);
}

/// note-editor/editor.tsx: the rich text surface (`text-text-secondary caret-primary-600`, 12 px paragraphs) with
/// its placeholder, reporting content changes ([onChange]), turning the workflow's history shortcuts off while it
/// has focus ([setHistoryShortcutsEnabled]), with Cmd/Ctrl + B, I and U, and the link popup (LinkEditorPlugin),
/// drawn above the link and taking pointer events outside the editor's box ([OverflowHitStack]).
class NoteEditor extends StatefulWidget {
  const NoteEditor({super.key, this.placeholder, this.onChange, this.setHistoryShortcutsEnabled, this.initialTap});

  final String? placeholder;

  /// Where (globally) the click that selected the note landed: the caret goes there, as the click lands in Dify's
  /// always editable surface.
  final Offset? initialTap;
  final ValueChanged<NoteText>? onChange;
  final ValueChanged<bool>? setHistoryShortcutsEnabled;

  @override
  State<NoteEditor> createState() => _NoteEditorState();
}

class _NoteEditorState extends State<NoteEditor> {
  late NoteEditorScope _scope;
  late int _revision;
  final _field = GlobalKey();
  bool _focused = false;

  NoteEditorController get controller => _scope.controller;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _scope = NoteEditorScope.of(context);
    _revision = controller.revision;
    controller.addListener(_changed);
    _scope.focusNode.addListener(_focusChanged);
  }

  @override
  void initState() {
    super.initState();
    final tap = widget.initialTap;
    if (tap == null) return;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      final editable = _editable;
      if (!mounted || editable == null || !controller.editable) return;
      final local = editable.globalToLocal(tap);
      if (!(Offset.zero & editable.size).contains(local)) return;
      _scope.focusNode.requestFocus();
      editable.selectPositionAt(from: tap, cause: SelectionChangedCause.tap);
    });
  }

  RenderEditable? get _editable {
    RenderEditable? find(RenderObject o) {
      if (o is RenderEditable) return o;
      RenderEditable? hit;
      o.visitChildren((c) => hit ??= find(c));
      return hit;
    }

    final box = _field.currentContext?.findRenderObject();
    return box == null ? null : find(box);
  }

  @override
  void dispose() {
    controller.removeListener(_changed);
    _scope.focusNode.removeListener(_focusChanged);
    super.dispose();
  }

  void _changed() {
    if (controller.revision == _revision) return;
    _revision = controller.revision;
    widget.onChange?.call(controller.note);
  }

  void _focusChanged() {
    final f = _scope.focusNode.hasFocus;
    if (f == _focused) return;
    _focused = f;
    widget.setHistoryShortcutsEnabled?.call(!f);
  }

  /// The link's box in the field's coordinates (Dify's floating anchor element).
  Rect? _anchorRect(TextRange r) {
    final box = _field.currentContext?.findRenderObject() as RenderBox?;
    final editable = _editable;
    if (box == null || editable == null || !editable.hasSize) return null;
    final boxes = editable.getBoxesForSelection(TextSelection(baseOffset: r.start, extentOffset: r.end));
    final rect = boxes.isEmpty
        ? editable.getLocalRectForCaret(TextPosition(offset: r.start))
        : boxes.map((b) => b.toRect()).reduce((a, b) => a.expandToInclude(b));
    return MatrixUtils.transformRect(editable.getTransformTo(box), rect);
  }

  @override
  Widget build(BuildContext context) {
    final c = controller;
    // Nothing from the Material text theme TextField merges in (its letter spacing).
    final style = noteParagraphStyle.copyWith(fontFamily: cardFontFamily, letterSpacing: 0, wordSpacing: 0);
    Widget field = CallbackShortcuts(
      bindings: {
        for (final meta in [false, true]) ...{
          SingleActivator(LogicalKeyboardKey.keyB, control: !meta, meta: meta): () => c.formatText(NoteFormat.bold),
          SingleActivator(LogicalKeyboardKey.keyI, control: !meta, meta: meta): () => c.formatText(NoteFormat.italic),
          // Lexical's underline: the format bit is kept (Dify's note theme draws no underline).
          SingleActivator(LogicalKeyboardKey.keyU, control: !meta, meta: meta): () =>
              c.formatText(NoteFormat.underline),
        },
      },
      child: Listener(
        onPointerUp: (_) {
          final k = HardwareKeyboard.instance;
          c.handleClick(meta: k.isMetaPressed || k.isControlPressed);
        },
        // TextField needs a Material; this one draws nothing.
        child: Material(
          type: MaterialType.transparency,
          child: TextField(
            key: _field,
            controller: c,
            focusNode: _scope.focusNode,
            readOnly: !c.editable,
            maxLines: null,
            expands: true,
            keyboardType: TextInputType.multiline,
            style: style,
            cursorColor: const Color(0xFF155EEF), // caret-primary-600
            cursorWidth: 1,
            decoration: const InputDecoration.collapsed(hintText: null),
          ),
        ),
      ),
    );
    return ListenableBuilder(
      listenable: Listenable.merge([c, c.store]),
      builder: (context, child) {
        final empty = c.text.isEmpty && !c.value.composing.isValid;
        final anchor = c.store.linkAnchor;
        final at = anchor == null ? null : _anchorRect(anchor);
        return OverflowHitStack(
          children: [
            child!,
            if (empty)
              Positioned(
                left: 0,
                top: 0,
                right: 0,
                child: IgnorePointer(
                  child: Text(
                    widget.placeholder ?? DifyI18n.tr('workflow', 'nodes.note.editor.placeholder'),
                    style: notePlaceholderStyle,
                  ),
                ),
              ),
            // The link popup, portalled into the note as Dify's (FloatingPortal root: the note's element): floating-ui
            // `top`, offset 4, centred above the link.
            if (at != null)
              Positioned(
                left: at.center.dx,
                top: at.top - 4,
                child: const FractionalTranslation(
                  translation: Offset(-0.5, -1),
                  child: NoteTextScope(child: LinkEditor()),
                ),
              ),
          ],
        );
      },
      child: field,
    );
  }
}

/// link-editor-plugin/component.tsx: above the link, the URL input with OK (a link without a URL, or after Edit),
/// else Open (the URL), Edit and Unlink. Escape and a tap outside cancel: a link just created without a URL goes,
/// otherwise the popup is dismissed until reopened.
class LinkEditor extends StatefulWidget {
  const LinkEditor({super.key});

  @override
  State<LinkEditor> createState() => _LinkEditorState();
}

class _LinkEditorState extends State<LinkEditor> {
  late final _url = TextEditingController(text: _store.selectedLinkUrl);
  final _input = FocusNode(debugLabel: 'note link url');
  late NoteEditorScope _scope;
  NoteEditorStore get _store => _scope.controller.store;
  String _lastUrl = '';
  bool _wasEditing = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _scope = NoteEditorScope.of(context);
    _lastUrl = _store.selectedLinkUrl;
  }

  @override
  void dispose() {
    _url.dispose();
    _input.dispose();
    super.dispose();
  }

  void _cancel() {
    if (!_store.linkOperatorShow && _store.selectedLinkUrl.isEmpty) {
      _scope.controller.unlink();
      return;
    }
    _store.dismissLinkEditor();
  }

  void _save() {
    if (_url.text.isNotEmpty) _scope.controller.saveLink(_url.text);
  }

  static TextStyle get _small => difyStyle(DifyType.systemXsMedium, DifyColors.textTertiary);

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _store,
    builder: (context, _) {
      final s = _store;
      // useEffect(() => setUrl(selectedLinkUrl), [selectedLinkUrl])
      if (s.selectedLinkUrl != _lastUrl) {
        _lastUrl = s.selectedLinkUrl;
        _url.text = _lastUrl;
      }
      final editing = !s.linkOperatorShow;
      // `autoFocus` on the URL input, also when Edit switches to it (the note editor still has the focus).
      if (editing && !_wasEditing) {
        SchedulerBinding.instance.addPostFrameCallback((_) {
          if (mounted && !_store.linkOperatorShow) _input.requestFocus();
        });
      }
      _wasEditing = editing;
      final content = editing
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.only(right: 2),
                  child: SizedBox(
                    width: 196,
                    height: 24,
                    child: ListenableBuilder(
                      listenable: _url,
                      builder: (context, _) => Stack(
                        alignment: Alignment.centerLeft,
                        children: [
                          if (_url.text.isEmpty)
                            Padding(
                              padding: const EdgeInsets.all(4),
                              child: Text(
                                DifyI18n.tr('workflow', 'nodes.note.editor.enterUrl'),
                                style: _inputStyle.copyWith(color: DifyColors.componentsInputTextPlaceholder),
                              ),
                            ),
                          Padding(
                            padding: const EdgeInsets.all(4),
                            child: EditableText(
                              controller: _url,
                              focusNode: _input,
                              autofocus: true,
                              style: _inputStyle,
                              cursorColor: DifyColors.textSecondary,
                              backgroundCursorColor: DifyColors.textQuaternary,
                              onSubmitted: (_) {
                                _save();
                                _input.requestFocus();
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                ListenableBuilder(
                  listenable: _url,
                  builder: (context, _) => DifyButton(
                    variant: DifyButtonVariant.primary,
                    size: DifyButtonSize.small,
                    disabled: _url.text.isEmpty,
                    onPressed: () => _scope.controller.saveLink(_url.text),
                    child: Text(DifyI18n.tr('common', 'operation.ok')),
                  ),
                ),
              ],
            )
          : DefaultTextStyle.merge(
              style: _small,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DifyPressable(
                    semanticLabel: '${DifyI18n.tr('workflow', 'nodes.note.editor.openLink')} ${s.selectedLinkUrl}',
                    onPressed: () => _scope.controller.openUrl?.call(s.selectedLinkUrl),
                    builder: (context, hovered, focused) => Container(
                      height: 24,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      decoration: BoxDecoration(
                        color: hovered ? DifyColors.stateBaseHover : null,
                        borderRadius: BorderRadius.circular(DifyRadius.md),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          RemixIcon('external-link-line', size: 12, color: DifyColors.textTertiary),
                          const SizedBox(width: 4),
                          Text(DifyI18n.tr('workflow', 'nodes.note.editor.openLink'), style: _small),
                          const SizedBox(width: 4),
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 140),
                            child: Text(
                              escapeHtml(s.selectedLinkUrl),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: _small.copyWith(color: DifyColors.textAccent),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Container(
                    width: 1,
                    height: 14,
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    color: DifyColors.dividerRegular,
                  ),
                  Padding(
                    padding: const EdgeInsets.only(right: 2),
                    child: _ghost(
                      'edit-line',
                      DifyI18n.tr('common', 'operation.edit'),
                      () => s.setLinkOperatorShow(false),
                    ),
                  ),
                  _ghost(
                    'link-unlink-m',
                    DifyI18n.tr('workflow', 'nodes.note.editor.unlink'),
                    () {
                      _scope.controller.unlink();
                      _scope.focusNode.requestFocus();
                    },
                  ),
                ],
              ),
            );
      return TapRegion(
        onTapOutside: (_) {
          // The focus stays with what was clicked (it does not go back to the note).
          if (_input.hasFocus) _input.unfocus();
          _cancel();
        },
        child: Focus(
          onKeyEvent: (node, e) {
            if (e is! KeyDownEvent || e.logicalKey != LogicalKeyboardKey.escape) return KeyEventResult.ignored;
            _cancel();
            _scope.focusNode.requestFocus();
            return KeyEventResult.handled;
          },
          child: Container(
            padding: EdgeInsets.all(editing ? 4 : 2),
            decoration: BoxDecoration(
              color: DifyColors.componentsActionbarBg,
              border: Border.all(color: DifyColors.componentsActionbarBorder, width: Css.hairline),
              borderRadius: BorderRadius.circular(DifyRadius.md),
              boxShadow: editing ? DifyShadows.md : DifyShadows.sm,
            ),
            child: content,
          ),
        ),
      );
    },
  );

  TextStyle get _inputStyle => TextStyle(
    fontFamily: cardFontFamily,
    fontSize: 13,
    height: 16 / 13,
    color: DifyColors.componentsInputTextFilled,
  );

  /// `Button variant="ghost" size="small" className="px-2 text-text-tertiary"` with a 12 px icon.
  Widget _ghost(String icon, String label, VoidCallback onPressed) => DifyPressable(
    semanticLabel: label,
    onPressed: onPressed,
    builder: (context, hovered, focused) => Container(
      height: 24,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: hovered ? DifyColors.componentsButtonGhostBgHover : null,
        borderRadius: BorderRadius.circular(DifyRadius.md),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 4,
        children: [
          RemixIcon(icon, size: 12, color: DifyColors.textTertiary),
          Text(label, style: _small.copyWith(color: DifyColors.textTertiary)),
        ],
      ),
    ),
  );
}
