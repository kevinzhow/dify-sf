/// Dify's code editor (nodes/_base/components/editor/code-editor/index.tsx) and the chrome around it
/// (editor/base.tsx with wrap.tsx, use-toggle-expend.ts, toggle-expand-btn.tsx and
/// prompt-editor-height-resize-wrap.tsx): a title bar with the copy and expand buttons over a resizable body, or the
/// bare editor (`noWrapper`) sized from its content like Dify does.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart' show Colors;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../design/css_metrics.dart';
import '../../design/dify_icon.dart';
import '../../design/dify_palette.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/dify_type_tw.dart';
import '../../design/widgets/icon_button.dart';
import '../../design/widgets/text.dart';
import '../../i18n/dify_i18n.dart';
import '../store/workflow_store_scope.dart';
import 'editor_view.dart';
import 'language.dart';
import 'utils.dart';

export 'language.dart' show CodeLanguage;

/// `CODE_EDITOR_LINE_HEIGHT`.
const codeEditorLineHeight = 18.0;

class DifyCodeEditor extends StatefulWidget {
  const DifyCodeEditor({
    super.key,
    this.value,
    required this.language,
    this.onChange,
    this.title,
    this.titleWidget,
    this.headerRight,
    this.placeholder,
    this.placeholderWidget,
    this.readOnly = false,
    this.isJSONStringifyBeauty = false,
    this.height,
    this.isInNode = false,
    this.noWrapper = false,
    this.isExpand = false,
    this.codeGenerator,
    this.tip,
    this.footer,
    this.focusNode,
  });

  /// A string, or a JSON value shown as `JSON.stringify(value, null, 2)`.
  final Object? value;
  final CodeLanguage language;
  final ValueChanged<String>? onChange;

  /// The title bar's label (upper-cased, `system-xs-semibold-uppercase`), or [titleWidget].
  final String? title;
  final Widget? titleWidget;
  final Widget? headerRight;

  /// Shown at the top left while the editor is empty and unfocused (13 / 18 px, placeholder colour).
  final String? placeholder;
  final Widget? placeholderWidget;
  final bool readOnly;
  final bool isJSONStringifyBeauty;

  /// The body's minimum height plus the 28 px title bar (Dify's `minHeight = height || 200`).
  final double? height;
  final bool isInNode;
  final bool noWrapper;

  /// With [noWrapper], fill the parent's height.
  final bool isExpand;

  /// Base's code generator button slot (`showCodeGenerator`), placed before the copy button.
  final Widget? codeGenerator;
  final Widget? tip;
  final Widget? footer;
  final FocusNode? focusNode;

  @override
  State<DifyCodeEditor> createState() => _DifyCodeEditorState();
}

class _DifyCodeEditorState extends State<DifyCodeEditor> {
  final _viewKey = GlobalKey<CodeEditorViewState>();
  FocusNode? _ownFocus;
  FocusNode get _focus => widget.focusNode ?? (_ownFocus ??= FocusNode());
  bool _isFocus = false;
  double _editorContentHeight = 56;
  Timer? _resize;

  String get _value => serializeCodeEditorValue(widget.value, isJSONStringifyBeauty: widget.isJSONStringifyBeauty);

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocus);
    WidgetsBinding.instance.addPostFrameCallback((_) => _resizeEditorToContent());
  }

  @override
  void didUpdateWidget(DifyCodeEditor old) {
    super.didUpdateWidget(old);
    if (old.focusNode != widget.focusNode) {
      (old.focusNode ?? _ownFocus)?.removeListener(_onFocus);
      _focus.addListener(_onFocus);
    }
  }

  @override
  void dispose() {
    _resize?.cancel();
    _focus.removeListener(_onFocus);
    _ownFocus?.dispose();
    super.dispose();
  }

  void _onFocus() {
    if (_isFocus != _focus.hasFocus) setState(() => _isFocus = _focus.hasFocus);
  }

  void _resizeEditorToContent() {
    final view = _viewKey.currentState;
    if (!mounted || view == null) return;
    final h = view.contentHeight;
    if (h != _editorContentHeight) setState(() => _editorContentHeight = h);
  }

  void _handleChange(String value) {
    widget.onChange?.call(value);
    _resize?.cancel();
    _resize = Timer(const Duration(milliseconds: 10), _resizeEditorToContent);
  }

  @override
  Widget build(BuildContext context) {
    final value = _value;
    final view = CodeEditorView(
      key: _viewKey,
      value: value,
      language: widget.language,
      readOnly: widget.readOnly,
      onChanged: _handleChange,
      focusNode: _focus,
    );
    final placeholder =
        widget.placeholderWidget ?? (widget.placeholder == null ? null : DifyTextLine(widget.placeholder!));
    final main = Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(child: view),
        if (value.isEmpty && !_isFocus && placeholder != null)
          Positioned(
            top: 0,
            // `left-9` from the editor's positioned box: the bare editor, or the resize wrap around Base's 8 px inset.
            left: widget.noWrapper ? 36 : 28,
            child: IgnorePointer(
              child: DefaultTextStyle.merge(
                style: difyTextStyle(DifyTw.text13NormalLeading18, DifyColors.componentsInputTextPlaceholder),
                child: placeholder,
              ),
            ),
          ),
      ],
    );
    if (widget.noWrapper) {
      return LayoutBuilder(
        builder: (context, constraints) {
          final h = widget.isExpand && constraints.maxHeight.isFinite
              ? constraints.maxHeight
              : math.max(codeEditorLineHeight, _editorContentHeight / 2 + codeEditorLineHeight);
          return SizedBox(height: h, child: main);
        },
      );
    }
    return CodeEditorBase(
      title: widget.title,
      titleWidget: widget.titleWidget,
      value: value,
      headerRight: widget.headerRight,
      isFocus: _isFocus && !widget.readOnly,
      minHeight: widget.height ?? 200,
      isInNode: widget.isInNode,
      codeGenerator: widget.codeGenerator,
      tip: widget.tip,
      footer: widget.footer,
      child: main,
    );
  }
}

/// editor/base.tsx: the rounded box with the title bar (title, header slot, code generator, copy, expand), the tip,
/// the resizable body and the footer; expanding lifts it over the panel (use-toggle-expend.ts).
class CodeEditorBase extends StatefulWidget {
  const CodeEditorBase({
    super.key,
    this.title,
    this.titleWidget,
    this.headerRight,
    required this.child,
    this.minHeight = 120,
    required this.value,
    required this.isFocus,
    this.isInNode = false,
    this.codeGenerator,
    this.tip,
    this.footer,
  });

  final String? title;
  final Widget? titleWidget;
  final Widget? headerRight;
  final Widget child;
  final double minHeight;

  /// What the copy button copies.
  final String value;
  final bool isFocus;
  final bool isInNode;
  final Widget? codeGenerator;
  final Widget? tip;
  final Widget? footer;

  @override
  State<CodeEditorBase> createState() => _CodeEditorBaseState();
}

/// use-toggle-expend.ts `editorExpandHeight`: the expanded editor body, the wrapper's height less its chrome (the
/// title bar: 29 px; with a footer: 56 px), never negative.
double toggleExpendEditorHeight(double wrapHeight, {bool hasFooter = true}) =>
    math.max(0, wrapHeight - (hasFooter ? 56 : 29));

class _CodeEditorBaseState extends State<CodeEditorBase> {
  final _portal = OverlayPortalController();
  final _childKey = GlobalKey();
  bool _isExpand = false;
  bool _isCopied = false;
  Timer? _copiedTimer;
  late double _editorContentHeight = widget.minHeight - 28;

  double get _editorContentMinHeight => widget.minHeight - 28;

  @override
  void dispose() {
    _copiedTimer?.cancel();
    super.dispose();
  }

  void _handleCopy() {
    Clipboard.setData(ClipboardData(text: widget.value));
    setState(() => _isCopied = true);
    _copiedTimer?.cancel();
    _copiedTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _isCopied = false);
    });
  }

  void _setExpand(bool value) {
    setState(() => _isExpand = value);
    value ? _portal.show() : _portal.hide();
  }

  Widget _box({required double? bodyHeight, required bool expanded}) {
    final focus = widget.isFocus;
    final title =
        widget.titleWidget ?? DifyTextLine(difyTransform(DifyType.systemXsSemiboldUppercase, widget.title ?? ''));
    // `<div className="ml-1">` around an inline button (the generator's, the expand toggle's): the div's text line
    // ends below the button, and the right-hand group, as tall as such a div, is centred in the h-7 bar (overflowing
    // it): those buttons sit 1.25 px above the copy button.
    Widget inlineButton(Widget button) => Padding(
      padding: EdgeInsets.only(left: 4, bottom: Css.inlineButtonLineGap),
      child: button,
    );
    final header = SizedBox(
      height: 28,
      child: Padding(
        padding: const EdgeInsets.only(top: 4, right: 8, left: 12),
        child: OverflowBox(
          minHeight: 0,
          maxHeight: double.infinity,
          child: Row(
            children: [
              Expanded(
                child: DefaultTextStyle.merge(
                  style: difyTextStyle(DifyType.systemXsSemiboldUppercase, DifyColors.textSecondary),
                  child: Align(alignment: Alignment.centerLeft, child: title),
                ),
              ),
              ?widget.headerRight,
              if (widget.codeGenerator case final generator?) inlineButton(generator),
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: DifyIconButton(
                  label: DifyI18n.tr('common', 'operation.copy'),
                  onPressed: _handleCopy,
                  icon: DifyIcon(_isCopied ? 'vender/line/files/copy-check' : 'vender/line/files/copy', size: 16),
                ),
              ),
              inlineButton(
                DifyIconButton(
                  label: DifyI18n.tr('share', _isExpand ? 'chat.collapse' : 'chat.expand'),
                  onPressed: () => _setExpand(!_isExpand),
                  icon: RemixIcon(_isExpand ? 'collapse-diagonal-line' : 'expand-diagonal-line', size: 16),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    final body = KeyedSubtree(
      key: _childKey,
      child: Padding(padding: const EdgeInsets.only(left: 8, bottom: 8), child: widget.child),
    );
    final resizable = _ResizeWrap(
      height: bodyHeight ?? _editorContentHeight,
      minHeight: _editorContentMinHeight,
      hideResize: expanded,
      onHeightChange: (h) => setState(() => _editorContentHeight = h),
      child: body,
    );
    // A Container: its 1 px border (transparent at rest) takes room, as in CSS.
    return Container(
      decoration: BoxDecoration(
        color: focus ? DifyColors.componentsInputBgHover : DifyColors.componentsInputBgNormal,
        border: expanded ? null : Border.all(color: focus ? DifyColors.componentsInputBorderHover : Colors.transparent),
        borderRadius: expanded ? null : BorderRadius.circular(DifyRadius.lg),
      ),
      child: ClipRRect(
        borderRadius: expanded || !focus ? BorderRadius.zero : BorderRadius.circular(DifyRadius.lg - 1),
        clipBehavior: focus ? Clip.hardEdge : Clip.none,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            header,
            if (widget.tip != null)
              Padding(padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2), child: widget.tip),
            resizable,
            ?widget.footer,
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final inNode = widget.isInNode;
    final shadow = [
      BoxShadow(color: DifyToggleExpendColors.shadow, blurRadius: 12, spreadRadius: -4),
      BoxShadow(color: DifyToggleExpendColors.shadowTop, offset: const Offset(0, -3), blurRadius: 6, spreadRadius: -2),
    ];
    final panelWidth = inNode ? context.getInheritedWidgetOfExactType<WorkflowStoreScope>()?.store.panelWidth : null;
    return OverlayPortal(
      controller: _portal,
      overlayLocation: inNode ? OverlayChildLocation.rootOverlay : OverlayChildLocation.nearestOverlay,
      overlayChildBuilder: (context) {
        Widget expanded(double? width) => LayoutBuilder(
          builder: (context, c) => _box(
            // editor/base.tsx: `useToggleExpend({ hasFooter: false })`.
            bodyHeight: toggleExpendEditorHeight(c.maxHeight, hasFooter: false),
            expanded: true,
          ),
        );
        if (inNode) {
          return Positioned(
            right: 9,
            top: 166,
            bottom: 8,
            child: ListenableBuilder(
              listenable: panelWidth ?? const _NoListenable(),
              builder: (context, _) => Container(
                width: panelWidth == null ? null : panelWidth.value - 1,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: DifyColors.componentsPanelBg,
                  borderRadius: BorderRadius.circular(DifyRadius.xl),
                  boxShadow: shadow,
                ),
                child: expanded(null),
              ),
            ),
          );
        }
        return Positioned.fill(
          child: Container(
            padding: const EdgeInsets.only(bottom: 16),
            decoration: BoxDecoration(color: DifyColors.componentsPanelBg, boxShadow: shadow),
            child: expanded(null),
          ),
        );
      },
      child: _isExpand ? const SizedBox.shrink() : _box(bodyHeight: null, expanded: false),
    );
  }
}

class _NoListenable implements Listenable {
  const _NoListenable();
  @override
  void addListener(VoidCallback listener) {}
  @override
  void removeListener(VoidCallback listener) {}
}

/// prompt-editor-height-resize-wrap.tsx: a fixed-height body with an 8 px handle along its bottom edge; dragging
/// changes the height (not below [minHeight]), a click without a drag resets it to [minHeight].
class _ResizeWrap extends StatefulWidget {
  const _ResizeWrap({
    required this.height,
    required this.minHeight,
    required this.onHeightChange,
    required this.hideResize,
    required this.child,
  });

  final double height, minHeight;
  final ValueChanged<double> onHeightChange;
  final bool hideResize;
  final Widget child;

  @override
  State<_ResizeWrap> createState() => _ResizeWrapState();
}

class _ResizeWrapState extends State<_ResizeWrap> {
  double _startHeight = 0;
  double _startY = 0;
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        SizedBox(height: widget.height, child: widget.child),
        if (!widget.hideResize)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: 8,
            child: Semantics(
              button: true,
              label: DifyI18n.tr('common', 'resize.editor'),
              child: MouseRegion(
                cursor: SystemMouseCursors.resizeRow,
                onEnter: (_) => setState(() => _hovered = true),
                onExit: (_) => setState(() => _hovered = false),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  dragStartBehavior: DragStartBehavior.down,
                  onVerticalDragStart: (d) {
                    _startHeight = widget.height;
                    _startY = d.globalPosition.dy;
                  },
                  onVerticalDragUpdate: (d) {
                    widget.onHeightChange(math.max(widget.minHeight, _startHeight + d.globalPosition.dy - _startY));
                  },
                  // A click without a drag resets the height (a drag never ends in a tap here).
                  onTap: () => widget.onHeightChange(widget.minHeight),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: _hovered ? DifyColors.stateBaseHover : null,
                      borderRadius: BorderRadius.circular(DifyRadius.md),
                    ),
                    child: Center(
                      child: Container(
                        width: 20,
                        height: 3,
                        decoration: BoxDecoration(
                          color: DifyColors.stateBaseHandle,
                          borderRadius: BorderRadius.circular(DifyRadius.xs),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
