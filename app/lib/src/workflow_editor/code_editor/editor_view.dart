/// The Monaco editor as Dify configures it (code-editor/index.tsx options on Monaco 0.52.2 defaults, `vs` theme,
/// transparent backgrounds from code-editor/style.css), drawn the Flutter way: one [EditableText] holds the text
/// (input, IME, selection gestures, undo), its [TextSpan]s carry the token and bracket-pair colours, kept per line
/// and rebuilt only for re-tokenized lines; two painters draw what Monaco renders around the text: the margin (glyph
/// margin, line numbers, folding space), the current-line border, indent guides, bracket-match boxes, the selection
/// and the cursor.
///
/// Layout follows Monaco's `EditorLayoutInfoComputer`: glyph margin of one line height, line numbers
/// `round(digits * maxDigitWidth)` wide (`lineNumbersMinChars: 1`), 10 + 16 px of line decorations and folding,
/// then the text, wrapped (`wordWrap: 'on'`) at `floor((contentWidth - 14 - 2) / charWidth)` columns, a 14 px
/// vertical scrollbar and room to scroll the last line to the top (`scrollBeyondLastLine`). The font is Monaco's
/// platform default (Linux and web: 'Droid Sans Mono', monospace, which resolves to DejaVu Sans Mono, 14 / 19 px;
/// macOS: Menlo 12 / 18 px; Windows: Consolas 14 / 19 px).
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Scrollbar, ScrollbarTheme, ScrollbarThemeData;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'document.dart';
import 'editing.dart';
import 'language.dart';
import 'monarch/vs_theme.dart';

/// The bundled font standing in for the Linux `monospace` Monaco falls back to (fontconfig's DejaVu Sans Mono).
const codeEditorFontFamily = 'DejaVu Sans Mono';

/// Monaco's font metrics for the platform (`EDITOR_FONT_DEFAULTS`, `GOLDEN_LINE_HEIGHT_RATIO`), measured like
/// Monaco's FontMeasurements.
class CodeEditorMetrics {
  CodeEditorMetrics._(this.style, this.strut, this.lineHeight, this.isLinux) {
    double width(String s) {
      final p = TextPainter(
        text: TextSpan(text: s, style: style),
        textDirection: TextDirection.ltr,
      )..layout();
      final w = p.width;
      p.dispose();
      return w;
    }

    charWidth = width('x');
    spaceWidth = width(' ');
    maxDigitWidth = [for (var d = 0; d < 10; d++) width('$d')].reduce(math.max);
  }

  factory CodeEditorMetrics.of(TargetPlatform platform) => _cache[platform] ??= () {
    final (String family, List<String> fallback, double size, double ratio) = switch (platform) {
      TargetPlatform.macOS || TargetPlatform.iOS => ('Menlo', const ['Monaco', 'Courier New', 'monospace'], 12.0, 1.5),
      TargetPlatform.windows => ('Consolas', const ['Courier New', 'monospace'], 14.0, 1.35),
      // 'Droid Sans Mono' is rarely installed; Chromium then takes fontconfig's monospace, DejaVu Sans Mono (bundled).
      _ => (codeEditorFontFamily, const ['Droid Sans Mono', 'monospace'], 14.0, 1.35),
    };
    final lineHeight = (size * ratio).roundToDouble();
    final style = TextStyle(
      fontFamily: family,
      fontFamilyFallback: fallback,
      fontSize: size,
      height: lineHeight / size,
      leadingDistribution: TextLeadingDistribution.even,
      color: VsTheme.foreground,
      fontWeight: FontWeight.normal,
      letterSpacing: 0,
      fontFeatures: const [FontFeature.disable('liga'), FontFeature.disable('calt')],
    );
    final strut = StrutStyle(
      fontFamily: family,
      fontFamilyFallback: fallback,
      fontSize: size,
      height: lineHeight / size,
      leadingDistribution: TextLeadingDistribution.even,
      forceStrutHeight: true,
    );
    return CodeEditorMetrics._(style, strut, lineHeight, platform == TargetPlatform.linux);
  }();

  static final _cache = <TargetPlatform, CodeEditorMetrics>{};

  final TextStyle style;
  final StrutStyle strut;
  final double lineHeight;

  /// Monaco adds `lh-odd` (1 px down) to line numbers on Linux when the line height is odd.
  final bool isLinux;
  late final double charWidth, spaceWidth, maxDigitWidth;

  static const verticalScrollbarWidth = 14.0;

  /// lineDecorationsWidth (10) + the folding area (16).
  static const decorationsWidth = 26.0;

  double get glyphMarginWidth => lineHeight;
  double lineNumbersWidth(int lineCount) => (math.max(lineCount.toString().length, 1) * maxDigitWidth).roundToDouble();
  double contentLeft(int lineCount) => glyphMarginWidth + lineNumbersWidth(lineCount) + decorationsWidth;
}

/// Highlights the text as the document tokenizes it; spans are kept per line.
class _CodeController extends TextEditingController {
  _CodeController(this.doc, String text) : super(text: text);

  final CodeDocument doc;

  /// A line's span, attached to its token list, which the document keeps while the line is unchanged (also when
  /// lines above it are inserted or removed).
  final _lineSpans = Expando<_LineSpan>();
  final _styles = <(Color, bool, bool), TextStyle>{};

  TextStyle _style(Color c, TokenStyle t) => _styles.putIfAbsent((
    c,
    t.italic,
    t.bold,
  ), () => TextStyle(color: c, fontStyle: t.fontStyle, fontWeight: t.fontWeight));

  @override
  TextSpan buildTextSpan({required BuildContext context, TextStyle? style, required bool withComposing}) {
    doc.setText(text);
    final lines = doc.lines;
    final composing = withComposing && value.isComposingRangeValid ? value.composing : null;
    final children = <InlineSpan>[];
    for (var i = 0; i < lines.length; i++) {
      if (i > 0) children.add(const TextSpan(text: '\n'));
      final start = doc.lineStart(i);
      final end = start + lines[i].length;
      if (composing != null && composing.start <= end && composing.end >= start) {
        children.add(_buildLine(i, (composing.start - start, composing.end - start)));
        continue;
      }
      final tokens = doc.tokensOf(i);
      final cached = _lineSpans[tokens];
      final levels = [for (final b in doc.bracketsOf(i)) b.level];
      if (cached != null && cached.text == lines[i] && listEquals(cached.levels, levels)) {
        children.add(cached.span);
        continue;
      }
      final span = _buildLine(i, null);
      if (tokens.isNotEmpty) _lineSpans[tokens] = _LineSpan(lines[i], levels, span);
      children.add(span);
    }
    return TextSpan(style: style, children: children);
  }

  TextSpan _buildLine(int line, (int, int)? underline) {
    final text = doc.lines[line];
    if (text.isEmpty) return const TextSpan(text: '');
    final tokens = doc.tokensOf(line);
    final brackets = doc.bracketsOf(line);
    // Per character run: the token colour, overridden by bracket-pair colours (inline decorations win over tokens).
    final runs = <(int start, TextStyle style)>[];
    void add(int at, TextStyle s) {
      if (runs.isNotEmpty && runs.last.$1 == at) runs.removeLast();
      if (runs.isEmpty || runs.last.$2 != s) runs.add((at, s));
    }

    var b = 0;
    for (var t = 0; t < tokens.length; t++) {
      final ts = VsTheme.match(tokens[t].type);
      final tokenStyle = _style(ts.foreground, ts);
      final end = t + 1 < tokens.length ? tokens[t + 1].offset : text.length;
      var at = tokens[t].offset;
      if (t == 0 && at > 0) add(0, _style(VsTheme.foreground, const TokenStyle(VsTheme.foreground)));
      add(at, tokenStyle);
      while (b < brackets.length && brackets[b].column < end) {
        final br = brackets[b++];
        if (br.column < at) continue;
        final level = br.level;
        final color = level < 0
            ? VsTheme.unexpectedBracket
            : VsTheme.bracketColors[level % VsTheme.bracketColors.length];
        add(br.column, _style(color, ts));
        if (br.column + 1 < end) add(br.column + 1, tokenStyle);
        at = br.column + 1;
      }
    }
    if (tokens.isEmpty) add(0, _style(VsTheme.foreground, const TokenStyle(VsTheme.foreground)));
    final cuts = <int>{
      for (final r in runs) r.$1,
      if (underline != null) ...[underline.$1.clamp(0, text.length), underline.$2.clamp(0, text.length)],
      text.length,
    }.toList()..sort();
    final spans = <TextSpan>[];
    var r = 0;
    for (var i = 0; i + 1 < cuts.length; i++) {
      final s = cuts[i], e = cuts[i + 1];
      if (s >= e) continue;
      while (r + 1 < runs.length && runs[r + 1].$1 <= s) {
        r++;
      }
      var st = runs[r].$2;
      if (underline != null && s >= underline.$1 && e <= underline.$2) {
        st = st.copyWith(decoration: TextDecoration.underline);
      }
      spans.add(TextSpan(text: text.substring(s, e), style: st));
    }
    return spans.length == 1 ? spans.first : TextSpan(children: spans);
  }
}

class _LineSpan {
  _LineSpan(this.text, this.levels, this.span);
  final String text;
  final List<int> levels;
  final TextSpan span;
}

class _GestureDelegate implements TextSelectionGestureDetectorBuilderDelegate {
  _GestureDelegate(this.editableTextKey);
  @override
  final GlobalKey<EditableTextState> editableTextKey;
  @override
  bool get forcePressEnabled => false;
  @override
  bool get selectionEnabled => true;
}

/// Turns typed characters into Monaco's interceptors (see [CodeEditing]).
class _MonacoFormatter extends TextInputFormatter {
  _MonacoFormatter(this.state);
  final CodeEditorViewState state;

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    if (state._bypassFormatter || newValue.composing.isValid || oldValue.text == newValue.text) return newValue;
    final sel = oldValue.selection;
    if (!sel.isValid) return newValue;
    state._doc.setText(oldValue.text);
    final editing = state._editing;
    final insLen = newValue.text.length - (oldValue.text.length - (sel.end - sel.start));
    if (insLen > 0 &&
        newValue.selection.isCollapsed &&
        newValue.selection.baseOffset == sel.start + insLen &&
        newValue.text.startsWith(oldValue.text.substring(0, sel.start)) &&
        newValue.text.endsWith(oldValue.text.substring(sel.end))) {
      return editing.type(oldValue, newValue.text.substring(sel.start, sel.start + insLen), state._autoClosed) ??
          newValue;
    }
    if (sel.isCollapsed &&
        sel.baseOffset > 0 &&
        newValue.selection.isCollapsed &&
        newValue.selection.baseOffset == sel.baseOffset - 1 &&
        newValue.text == oldValue.text.replaceRange(sel.baseOffset - 1, sel.baseOffset, '')) {
      return editing.backspace(oldValue, state._autoClosed) ?? newValue;
    }
    return newValue;
  }
}

/// The Monaco editor area: margin, text and scrollbar, filling the height it is given.
class CodeEditorView extends StatefulWidget {
  const CodeEditorView({
    super.key,
    required this.value,
    required this.language,
    this.readOnly = false,
    this.onChanged,
    this.focusNode,
  });

  final String value;
  final CodeLanguage language;
  final bool readOnly;
  final ValueChanged<String>? onChanged;
  final FocusNode? focusNode;

  @override
  State<CodeEditorView> createState() => CodeEditorViewState();
}

class CodeEditorViewState extends State<CodeEditorView> {
  late CodeDocument _doc;
  late CodeEditing _editing;
  late _CodeController _controller;
  final _autoClosed = AutoClosedPairs();
  final _editableKey = GlobalKey<EditableTextState>();
  late final _gestures = TextSelectionGestureDetectorBuilder(delegate: _GestureDelegate(_editableKey));
  final _scroll = ScrollController();
  FocusNode? _ownFocus;
  FocusNode get _focus => widget.focusNode ?? (_ownFocus ??= FocusNode());
  final _caretOn = ValueNotifier<bool>(false);
  Timer? _blink;
  final _hovering = ValueNotifier<bool>(false);
  bool _bypassFormatter = false;
  String _lastText = '';
  late CodeEditorMetrics _metrics;
  double _viewportHeight = 0;
  final _layout = _LineLayout();

  /// The editor's text.
  String get text => _controller.text;

  /// The document behind the editor (tokens, brackets, indentation).
  CodeDocument get document => _doc;

  TextEditingController get controller => _controller;

  /// Monaco's `getContentHeight()`: all (wrapped) lines plus the room to scroll the last line to the top.
  double get contentHeight {
    final lh = _metrics.lineHeight;
    final box = _editableKey.currentState?.renderEditable;
    final lines = box != null && box.hasSize ? (box.size.height / lh).round() : _doc.lineCount;
    return lines * lh + math.max(0, _viewportHeight - lh);
  }

  @override
  void initState() {
    super.initState();
    _metrics = CodeEditorMetrics.of(defaultTargetPlatform);
    _reset(widget.value);
    _focus.addListener(_onFocus);
    _focus.onKeyEvent = _onKey;
  }

  void _reset(String value) {
    final text = value.replaceAll(RegExp(r'\r\n?'), '\n');
    _doc = CodeDocument(widget.language, text);
    _editing = CodeEditing(_doc);
    _controller = _CodeController(_doc, text)..addListener(_onValue);
    _lastText = text;
  }

  @override
  void didUpdateWidget(CodeEditorView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final old = oldWidget;
    if (old.focusNode != widget.focusNode) {
      (old.focusNode ?? _ownFocus)?.removeListener(_onFocus);
      _focus.addListener(_onFocus);
      _focus.onKeyEvent = _onKey;
    }
    if (old.language != widget.language) {
      final previous = _controller;
      _reset(previous.text);
      _controller.selection = previous.selection;
      // EditableText lets go of the old controller in this frame's rebuild.
      WidgetsBinding.instance.addPostFrameCallback((_) => previous.dispose());
    }
    final value = widget.value.replaceAll(RegExp(r'\r\n?'), '\n');
    if (value != _controller.text) {
      // @monaco-editor/react: setValue when read-only (cursor to the start), else a full-range edit (cursor to its end).
      _controller.value = TextEditingValue(
        text: value,
        selection: TextSelection.collapsed(offset: widget.readOnly ? 0 : value.length),
      );
    }
  }

  @override
  void dispose() {
    _blink?.cancel();
    _focus.removeListener(_onFocus);
    _focus.onKeyEvent = null;
    _ownFocus?.dispose();
    _controller.dispose();
    _scroll.dispose();
    _caretOn.dispose();
    _hovering.dispose();
    super.dispose();
  }

  void _onValue() {
    final text = _controller.text;
    final sel = _controller.selection;
    _autoClosed.update(_lastText, text, sel.isValid ? sel.extentOffset : -1);
    final digits = _doc.lineCount.toString().length;
    _lastText = text;
    _doc.setText(text);
    _restartBlink();
    // The painters and EditableText follow the controller; only the margin width needs a new layout.
    if (_doc.lineCount.toString().length != digits) setState(() {});
  }

  void _onFocus() => _restartBlink();

  /// Monaco's cursor: visible, then toggling every 500 ms; solid when read-only; hidden without focus.
  void _restartBlink() {
    _blink?.cancel();
    _caretOn.value = _focus.hasFocus;
    if (!_focus.hasFocus || widget.readOnly) return;
    _blink = Timer.periodic(const Duration(milliseconds: 500), (_) => _caretOn.value = !_caretOn.value);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (widget.readOnly || event is KeyUpEvent) return KeyEventResult.ignored;
    final keys = HardwareKeyboard.instance;
    final mod = defaultTargetPlatform == TargetPlatform.macOS ? keys.isMetaPressed : keys.isControlPressed;
    TextEditingValue Function(TextEditingValue)? op;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.tab && !mod && !keys.isAltPressed) {
      op = keys.isShiftPressed ? (v) => _editing.shift(v, unshift: true) : _editing.tab;
    } else if (mod && key == LogicalKeyboardKey.slash) {
      op = _editing.toggleLineComment;
    } else if (mod && key == LogicalKeyboardKey.bracketRight) {
      op = (v) => _editing.shift(v, unshift: false);
    } else if (mod && key == LogicalKeyboardKey.bracketLeft) {
      op = (v) => _editing.shift(v, unshift: true);
    }
    if (op == null) return KeyEventResult.ignored;
    _apply(op(_controller.value));
    return KeyEventResult.handled;
  }

  /// Applies a keyboard command's edit as user input (EditableText reports it to onChanged and its undo history).
  void _apply(TextEditingValue value) {
    if (value == _controller.value) return;
    _bypassFormatter = true;
    _editableKey.currentState?.userUpdateTextEditingValue(value, SelectionChangedCause.keyboard);
    _bypassFormatter = false;
  }

  @override
  Widget build(BuildContext context) {
    final m = _metrics;
    final lh = m.lineHeight;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite ? constraints.maxWidth : 400.0;
        _viewportHeight = constraints.maxHeight.isFinite ? constraints.maxHeight : 0;
        final contentLeft = m.contentLeft(_doc.lineCount);
        final contentWidth = math.max(0.0, width - contentLeft);
        final columns = math.max(
          1,
          ((contentWidth - CodeEditorMetrics.verticalScrollbarWidth - 2) / m.charWidth).floor(),
        );
        // RenderEditable keeps 3 px (caret gap + width) beside the text; the rest wraps at Monaco's column.
        final editableWidth = columns * m.charWidth + 3 + 0.5;
        final extra = math.max(0.0, _viewportHeight - lh);
        final editable = EditableText(
          key: _editableKey,
          controller: _controller,
          focusNode: _focus,
          readOnly: widget.readOnly,
          style: m.style,
          strutStyle: m.strut,
          textScaler: TextScaler.noScaling,
          cursorColor: const Color(0x00000000),
          backgroundCursorColor: const Color(0x00000000),
          showCursor: false,
          maxLines: null,
          keyboardType: TextInputType.multiline,
          textInputAction: TextInputAction.newline,
          autocorrect: false,
          enableSuggestions: false,
          smartDashesType: SmartDashesType.disabled,
          smartQuotesType: SmartQuotesType.disabled,
          rendererIgnoresPointer: true,
          scrollPadding: EdgeInsets.zero,
          selectionHeightStyle: ui.BoxHeightStyle.strut,
          inputFormatters: widget.readOnly ? null : [_MonacoFormatter(this)],
          onChanged: widget.onChanged,
          mouseCursor: SystemMouseCursors.text,
        );
        final paintState = _PaintState(this, contentLeft, width);
        final content = SizedBox(
          width: width,
          child: Stack(
            children: [
              Positioned.fill(
                child: RepaintBoundary(
                  child: CustomPaint(painter: _BackPainter(paintState, Listenable.merge([_controller, _focus]))),
                ),
              ),
              Padding(
                padding: EdgeInsets.only(left: contentLeft),
                child: MouseRegion(
                  cursor: SystemMouseCursors.text,
                  child: _gestures.buildGestureDetector(
                    behavior: HitTestBehavior.translucent,
                    child: Padding(
                      padding: EdgeInsets.only(bottom: extra),
                      child: Align(
                        alignment: Alignment.topLeft,
                        child: SizedBox(width: editableWidth, child: editable),
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: contentLeft,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (d) => _selectLineAt(d.localPosition.dy),
                ),
              ),
              Positioned.fill(
                child: IgnorePointer(
                  child: RepaintBoundary(
                    child: CustomPaint(painter: _CaretPainter(paintState, Listenable.merge([_controller, _caretOn]))),
                  ),
                ),
              ),
            ],
          ),
        );
        return MouseRegion(
          onEnter: (_) => _hovering.value = true,
          onExit: (_) => _hovering.value = false,
          child: ClipRect(
            child: Stack(
              children: [
                ScrollbarTheme(
                  data: ScrollbarThemeData(
                    thickness: const WidgetStatePropertyAll(CodeEditorMetrics.verticalScrollbarWidth),
                    radius: Radius.zero,
                    crossAxisMargin: 0,
                    mainAxisMargin: 0,
                    minThumbLength: 20,
                    thumbColor: WidgetStateProperty.resolveWith(
                      (s) => s.contains(WidgetState.dragged)
                          ? VsTheme.scrollbarSliderActive
                          : s.contains(WidgetState.hovered)
                          ? VsTheme.scrollbarSliderHover
                          : VsTheme.scrollbarSlider,
                    ),
                  ),
                  // Monaco shows the slider while the pointer is over the editor (and while scrolling).
                  child: ValueListenableBuilder(
                    valueListenable: _hovering,
                    builder: (context, hovering, child) =>
                        Scrollbar(controller: _scroll, thumbVisibility: hovering, child: child!),
                    child: ScrollConfiguration(
                      behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false, overscroll: false),
                      child: SingleChildScrollView(
                        controller: _scroll,
                        physics: const ClampingScrollPhysics(),
                        child: content,
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  top: 0,
                  height: 6,
                  child: IgnorePointer(
                    child: ListenableBuilder(
                      listenable: _scroll,
                      builder: (context, _) => _scroll.hasClients && _scroll.offset > 0
                          ? const DecoratedBox(decoration: BoxDecoration(gradient: _scrollShadow))
                          : const SizedBox.shrink(),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// A click in the margin selects the line (Monaco's line-number click).
  void _selectLineAt(double y) {
    final box = _editableKey.currentState?.renderEditable;
    if (box == null) return;
    final line = _layout.lineAtY(this, box, y);
    final start = _doc.lineStart(line);
    final end = line + 1 < _doc.lineCount ? _doc.lineStart(line + 1) : _doc.lineEnd(line);
    _focus.requestFocus();
    _controller.selection = TextSelection(baseOffset: start, extentOffset: end);
  }
}

/// `box-shadow: #DDDDDD 0 6px 6px -6px inset` (scroll decoration), as a gradient.
const _scrollShadow = LinearGradient(
  begin: Alignment.topCenter,
  end: Alignment.bottomCenter,
  colors: [Color(0x80DDDDDD), Color(0x4FDDDDDD), Color(0x29DDDDDD), Color(0x11DDDDDD), Color(0x00DDDDDD)],
);

/// The top and visual line count of each line in the EditableText, recomputed when the text or width changes.
class _LineLayout {
  int _version = -1;
  double _width = -1;
  List<double> tops = const [];
  List<int> rows = const [];

  void ensure(CodeEditorViewState s, RenderEditable box) {
    if (_version == s._doc.version && _width == box.size.width) return;
    final lh = s._metrics.lineHeight;
    final doc = s._doc;
    final n = doc.lineCount;
    tops = List<double>.filled(n, 0);
    rows = List<int>.filled(n, 1);
    final textLen = s._controller.text.length;
    for (var i = 0; i < n; i++) {
      final offset = math.min(doc.lineStart(i), textLen);
      tops[i] = _row(box, TextPosition(offset: offset), lh) * lh;
    }
    final totalRows = math.max(1, (box.size.height / lh).round());
    for (var i = 0; i < n; i++) {
      final next = i + 1 < n ? tops[i + 1] : totalRows * lh;
      rows[i] = math.max(1, ((next - tops[i]) / lh).round());
    }
    _version = doc.version;
    _width = box.size.width;
  }

  static int _row(RenderEditable box, TextPosition p, double lh) =>
      (box.getLocalRectForCaret(p).center.dy / lh).floor();

  int lineAtY(CodeEditorViewState s, RenderEditable box, double y) {
    ensure(s, box);
    var line = 0;
    while (line + 1 < tops.length && tops[line + 1] <= y) {
      line++;
    }
    return line;
  }
}

class _PaintState {
  _PaintState(this.view, this.contentLeft, this.width);
  final CodeEditorViewState view;
  final double contentLeft, width;

  RenderEditable? get box {
    final b = view._editableKey.currentState?.renderEditable;
    return b != null && b.hasSize ? b : null;
  }

  /// The visual row of the cursor (selection extent).
  int caretRow(RenderEditable box) {
    final sel = view._controller.selection;
    final lh = view._metrics.lineHeight;
    return _LineLayout._row(box, TextPosition(offset: sel.extentOffset, affinity: sel.affinity), lh);
  }
}

class _BackPainter extends CustomPainter {
  _BackPainter(this.s, Listenable repaint) : super(repaint: repaint);
  final _PaintState s;
  static final _numbers = <(String, bool, TargetPlatform), TextPainter>{};

  @override
  void paint(Canvas canvas, Size size) {
    final box = s.box;
    if (box == null) return;
    final view = s.view;
    final doc = view._doc;
    final m = view._metrics;
    final lh = m.lineHeight;
    final layout = view._layout..ensure(view, box);
    final sel = view._controller.selection;
    final focused = view._focus.hasFocus;
    final left = s.contentLeft;
    final caretRow = sel.isValid ? s.caretRow(box) : -1;

    // Current line: a 2 px #eeeeee border around the cursor's row (only with an empty selection).
    if (sel.isValid && sel.isCollapsed) {
      final r = Rect.fromLTWH(left, caretRow * lh, math.max(0.0, s.width - left), lh).deflate(1);
      canvas.drawRect(
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = VsTheme.lineHighlightBorder,
      );
    }

    // Indent guides.
    final guides = doc.indentGuides;
    final active = sel.isValid ? doc.activeIndentGuide(doc.lineAt(sel.extentOffset)) : null;
    final guidePaint = Paint();
    final step = doc.tabSize * m.spaceWidth;
    final maxIndentLeft = box.size.width - 3.5;
    for (var i = 0; i < doc.lineCount; i++) {
      for (var lvl = 1; lvl <= guides[i]; lvl++) {
        final x = (lvl - 1) * step;
        if (x > maxIndentLeft) break;
        final isActive = active != null && active.startLine <= i && i <= active.endLine && lvl == active.indent;
        guidePaint.color = isActive ? VsTheme.activeIndentGuide : VsTheme.indentGuide;
        canvas.drawRect(Rect.fromLTWH(left + x, layout.tops[i], 1, layout.rows[i] * lh), guidePaint);
      }
    }

    // Bracket matching (focused, empty selection): the pair at the cursor, else the enclosing one.
    if (focused && sel.isValid && sel.isCollapsed) {
      final pair = doc.matchBracket(sel.baseOffset) ?? doc.enclosingBrackets(sel.baseOffset);
      if (pair != null) {
        for (final o in [pair.open, pair.close]) {
          final a = box.getLocalRectForCaret(TextPosition(offset: o));
          final b = box.getLocalRectForCaret(TextPosition(offset: o + 1, affinity: TextAffinity.upstream));
          final row = (a.center.dy / lh).floor();
          final r = Rect.fromLTRB(left + a.left, row * lh, left + b.left, row * lh + lh);
          canvas.drawRect(r, Paint()..color = VsTheme.bracketMatchBackground);
          canvas.drawRect(
            r.deflate(0.5),
            Paint()
              ..style = PaintingStyle.stroke
              ..color = VsTheme.bracketMatchBorder,
          );
        }
      }
    }

    // Selection.
    if (sel.isValid && !sel.isCollapsed) _paintSelection(canvas, box, focused);

    // Line numbers, right-aligned, in the active colour on the cursor's row.
    final numbersRight = m.glyphMarginWidth + m.lineNumbersWidth(doc.lineCount);
    final dy = m.isLinux && lh % 2 == 1 ? 1.0 : 0.0;
    for (var i = 0; i < doc.lineCount; i++) {
      final top = layout.tops[i];
      final isActive = (top / lh).round() == caretRow;
      final tp = _numbers.putIfAbsent(('${i + 1}', isActive, defaultTargetPlatform), () {
        return TextPainter(
          text: TextSpan(
            text: '${i + 1}',
            style: m.style.copyWith(
              color: isActive ? VsTheme.activeLineNumber : VsTheme.lineNumber,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          strutStyle: m.strut,
          textDirection: TextDirection.ltr,
          textScaler: TextScaler.noScaling,
        )..layout();
      });
      tp.paint(canvas, Offset(numbersRight - tp.width, top + dy));
    }
  }

  /// Monaco's selection: per row, from the selection start to its end on that row, plus half a character where it
  /// takes the line break; 3 px rounded outer corners; `#ADD6FF` focused, `#E5EBF1` otherwise.
  void _paintSelection(Canvas canvas, RenderEditable box, bool focused) {
    final view = s.view;
    final doc = view._doc;
    final m = view._metrics;
    final lh = m.lineHeight;
    final sel = view._controller.selection;
    final rows = <int, Rect>{};
    void addRect(Rect r) {
      final row = (r.center.dy / lh).floor();
      final rr = Rect.fromLTRB(r.left, row * lh, r.right, row * lh + lh);
      rows[row] = rows[row]?.expandToInclude(rr) ?? rr;
    }

    final first = doc.lineAt(sel.start), last = doc.lineAt(sel.end);
    for (var l = first; l <= last; l++) {
      final ls = doc.lineStart(l), le = doc.lineEnd(l);
      final a = math.max(sel.start, ls), b = math.min(sel.end, le);
      if (a < b) {
        // Flutter adds a box from the end of a line to the paragraph's edge; the row ends at the segment's end.
        final end = box.getLocalRectForCaret(TextPosition(offset: b, affinity: TextAffinity.upstream));
        final endRow = (end.center.dy / lh).floor();
        for (final tb in box.getBoxesForSelection(TextSelection(baseOffset: a, extentOffset: b))) {
          var rect = tb.toRect();
          if ((rect.center.dy / lh).floor() == endRow) {
            rect = Rect.fromLTRB(rect.left, rect.top, math.min(rect.right, end.left), rect.bottom);
          }
          if (rect.width > 0) addRect(rect);
        }
      }
      if (sel.end > le) {
        // The line break: half a character after the line's end.
        final caret = box.getLocalRectForCaret(TextPosition(offset: le, affinity: TextAffinity.upstream));
        addRect(Rect.fromLTWH(caret.left, caret.center.dy - lh / 2, m.charWidth / 2, lh));
      }
    }
    final paint = Paint()..color = focused ? VsTheme.selection : VsTheme.inactiveSelection;
    final sorted = rows.keys.toList()..sort();
    const r = Radius.circular(3);
    for (final row in sorted) {
      final rect = rows[row]!.shift(Offset(s.contentLeft, 0));
      final above = rows[row - 1]?.shift(Offset(s.contentLeft, 0));
      final below = rows[row + 1]?.shift(Offset(s.contentLeft, 0));
      bool covers(Rect? o, double x) => o != null && o.left <= x + 0.01 && o.right >= x - 0.01;
      canvas.drawRRect(
        RRect.fromRectAndCorners(
          rect,
          topLeft: covers(above, rect.left) ? Radius.zero : r,
          topRight: covers(above, rect.right) ? Radius.zero : r,
          bottomLeft: covers(below, rect.left) ? Radius.zero : r,
          bottomRight: covers(below, rect.right) ? Radius.zero : r,
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_BackPainter old) =>
      old.s.contentLeft != s.contentLeft || old.s.width != s.width || old.s.view != s.view;
}

/// Monaco's line cursor: 2 px wide, one line tall, 1 px left of the character boundary.
class _CaretPainter extends CustomPainter {
  _CaretPainter(this.s, Listenable repaint) : super(repaint: repaint);
  final _PaintState s;

  @override
  void paint(Canvas canvas, Size size) {
    final view = s.view;
    if (!view._caretOn.value || !view._focus.hasFocus) return;
    final box = s.box;
    final sel = view._controller.selection;
    if (box == null || !sel.isValid) return;
    final lh = view._metrics.lineHeight;
    final caret = box.getLocalRectForCaret(TextPosition(offset: sel.extentOffset, affinity: sel.affinity));
    final row = (caret.center.dy / lh).floor();
    var x = caret.left;
    if (x >= 1) x -= 1;
    canvas.drawRect(Rect.fromLTWH(s.contentLeft + x, row * lh, 2, lh), Paint()..color = VsTheme.cursor);
  }

  @override
  bool shouldRepaint(_CaretPainter old) => old.s.contentLeft != s.contentLeft || old.s.view != s.view;
}
