/// The Monaco editor as Dify configures it (code-editor/index.tsx options on Monaco 0.52.2 defaults, `vs` theme,
/// transparent backgrounds from code-editor/style.css), using Re-Editor for native Flutter input and one source/view
/// projection for drawing, caret, selections and input-method geometry. The unchanged source holds the text
/// (input, IME, selection gestures, undo), its [TextSpan]s carry the token and bracket-pair colours, kept per line
/// and rebuilt only for re-tokenized lines; two painters draw what Monaco renders around the text: the margin (glyph
/// margin, line numbers, folding space), the current-line border, indent guides, bracket-match boxes, the selection
/// and the cursor.
///
/// Layout follows Monaco's `EditorLayoutInfoComputer`: no glyph margin (as Dify shows it), line numbers
/// `round(digits * maxDigitWidth)` wide (`lineNumbersMinChars: 1`), 10 + 16 px of line decorations and folding,
/// then the text, wrapped (`wordWrap: 'on'`) at `floor((contentWidth - 14 - 2) / charWidth)` columns, a 14 px
/// vertical scrollbar and room to scroll the last line to the top (`scrollBeyondLastLine`). The font is Monaco's
/// platform default (Linux and web: 'Droid Sans Mono', monospace, which resolves to DejaVu Sans Mono, 14 / 19 px;
/// macOS: Menlo 12 / 18 px; Windows: Consolas 14 / 19 px).
library;

import 'package:dify_sf_app/src/design/widgets/widgets.dart';

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/material.dart' show Colors;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../design/dify_tokens.g.dart' show DifyColors;
import 'document.dart';
import 'paragraph.dart';

import 'package:re_editor/re_editor.dart' as re;

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

  /// The platform's metrics, the text in the current theme's foreground (vs / vs-dark).
  factory CodeEditorMetrics.of(TargetPlatform platform) => _cache[(platform, DifyColors.isDark)] ??= () {
    final (
      String family,
      List<String> fallback,
      double size,
      double ratio,
    ) = switch (platform) {
      TargetPlatform.macOS || TargetPlatform.iOS => (
        'Menlo',
        const ['Monaco', 'Courier New', 'monospace'],
        12.0,
        1.5,
      ),
      TargetPlatform.windows => (
        'Consolas',
        const ['Courier New', 'monospace'],
        14.0,
        1.35,
      ),
      // 'Droid Sans Mono' is rarely installed; Chromium then takes fontconfig's monospace, DejaVu Sans Mono (bundled).
      _ => (
        codeEditorFontFamily,
        const ['Droid Sans Mono', 'monospace'],
        14.0,
        1.35,
      ),
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
      fontFeatures: const [
        FontFeature.disable('liga'),
        FontFeature.disable('calt'),
      ],
    );
    final strut = StrutStyle(
      fontFamily: family,
      fontFamilyFallback: fallback,
      fontSize: size,
      height: lineHeight / size,
      leadingDistribution: TextLeadingDistribution.even,
      forceStrutHeight: true,
    );
    return CodeEditorMetrics._(
      style,
      strut,
      lineHeight,
      platform == TargetPlatform.linux,
    );
  }();

  static final _cache = <(TargetPlatform, bool), CodeEditorMetrics>{};

  final TextStyle style;
  final StrutStyle strut;
  final double lineHeight;

  /// Monaco adds `lh-odd` (1 px down) to line numbers on Linux when the line height is odd.
  final bool isLinux;
  late final double charWidth, spaceWidth, maxDigitWidth;

  static const verticalScrollbarWidth = 14.0;

  /// lineDecorationsWidth (10) + the folding area (16).
  static const decorationsWidth = 26.0;

  /// None: Dify's editor shows its line numbers at the margin's left edge (measured in Chrome: the margin is the
  /// numbers and the 26 px of decorations).
  double get glyphMarginWidth => 0;
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

  TextStyle _style(Color c, TokenStyle t) => _styles.putIfAbsent(
    (c, t.italic, t.bold),
    () => TextStyle(color: c, fontStyle: t.fontStyle, fontWeight: t.fontWeight),
  );

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    doc.setText(text);
    final lines = doc.lines;
    final composing = withComposing && value.isComposingRangeValid ? value.composing : null;
    final children = <InlineSpan>[];
    for (var i = 0; i < lines.length; i++) {
      if (i > 0) children.add(const TextSpan(text: '\n'));
      final start = doc.lineStart(i);
      final end = start + lines[i].length;
      if (composing != null && composing.start <= end && composing.end >= start) {
        children.add(
          _buildLine(i, (composing.start - start, composing.end - start)),
        );
        continue;
      }
      final tokens = doc.tokensOf(i);
      final cached = _lineSpans[tokens];
      final levels = [for (final b in doc.bracketsOf(i)) b.level];
      if (cached != null &&
          cached.text == lines[i] &&
          cached.dark == DifyColors.isDark &&
          listEquals(cached.levels, levels)) {
        children.add(cached.span);
        continue;
      }
      final span = _buildLine(i, null);
      if (tokens.isNotEmpty) {
        _lineSpans[tokens] = _LineSpan(lines[i], levels, span);
      }
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
      if (t == 0 && at > 0) {
        add(0, _style(VsTheme.foreground, TokenStyle(VsTheme.foreground)));
      }
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
    if (tokens.isEmpty) {
      add(0, _style(VsTheme.foreground, TokenStyle(VsTheme.foreground)));
    }
    final cuts = <int>{
      for (final r in runs) r.$1,
      if (underline != null) ...[
        underline.$1.clamp(0, text.length),
        underline.$2.clamp(0, text.length),
      ],
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
  _LineSpan(this.text, this.levels, this.span) : dark = DifyColors.isDark;
  final String text;
  final List<int> levels;
  final TextSpan span;

  /// The theme its colours are from.
  final bool dark;
}

/// Turns typed characters into Monaco's interceptors (see [CodeEditing]).
class _MonacoFormatter extends TextInputFormatter {
  _MonacoFormatter(this.state);
  final CodeEditorViewState state;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (newValue.composing.isValid || oldValue.text == newValue.text) {
      return newValue;
    }
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
      return editing.type(
            oldValue,
            newValue.text.substring(sel.start, sel.start + insLen),
            state._autoClosed,
          ) ??
          newValue;
    }
    if (sel.isCollapsed &&
        sel.baseOffset > 0 &&
        newValue.selection.isCollapsed &&
        newValue.selection.baseOffset == sel.baseOffset - 1 &&
        newValue.text ==
            oldValue.text.replaceRange(
              sel.baseOffset - 1,
              sel.baseOffset,
              '',
            )) {
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
  late _NativeCodeController _native;
  final _autoClosed = AutoClosedPairs();
  final _scroll = ScrollController();
  final _horizontal = ScrollController();
  late final re.CodeScrollController _codeScroll = re.CodeScrollController(
    verticalScroller: _scroll,
    horizontalScroller: _horizontal,
  );
  FocusNode? _ownFocus;
  FocusNode get _focus => widget.focusNode ?? (_ownFocus ??= FocusNode());
  final _caretOn = ValueNotifier(false), _hovering = ValueNotifier(false);
  Timer? _blink;
  bool _syncing = false, _transaction = false;
  String _lastText = '';
  double _viewportHeight = 0;
  final _layout = _LineLayout();
  final _geometry = _CodeGeometry();
  late final _toolbar = _CodeToolbar(this);
  CodeEditorMetrics get _metrics => CodeEditorMetrics.of(defaultTargetPlatform);
  String get text => _controller.text;
  CodeDocument get document => _doc;
  TextEditingController get controller => _controller;
  double get contentHeight => _geometry.size.height + math.max(0, _viewportHeight - _metrics.lineHeight);
  @override
  void initState() {
    super.initState();
    _create(widget.value);
    _focus.addListener(_onFocus);
    PaintingBinding.instance.systemFonts.addListener(_fontsChanged);
  }

  void _fontsChanged() {
    CodeEditorMetrics._cache.clear();
    _geometry.clear();
    if (mounted) setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _native.forceRepaint();
    });
  }

  void _create(String value) {
    final normalized = value.replaceAll(RegExp(r'\r\n?'), '\n');
    _doc = CodeDocument(widget.language, normalized);
    _editing = CodeEditing(_doc);
    _controller = _CodeController(_doc, normalized)..selection = const TextSelection.collapsed(offset: 0);
    _lastText = normalized;
    _native = _NativeCodeController(
      this,
      re.CodeLineEditingController.fromText(
        normalized,
        re.CodeLineOptions(indentSize: _doc.tabSize),
      ),
    );
    _native.addListener(_nativeChanged);
    _controller.addListener(_mirrorChanged);
  }

  @override
  void didUpdateWidget(CodeEditorView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      (oldWidget.focusNode ?? _ownFocus)?.removeListener(_onFocus);
      _focus.addListener(_onFocus);
    }
    if (oldWidget.language != widget.language) {
      final previousNative = _native, previousMirror = _controller;
      previousNative.removeListener(_nativeChanged);
      previousMirror.removeListener(_mirrorChanged);
      _create(widget.value);
      _geometry.clear();
      _autoClosed.clear();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        previousNative.dispose();
        previousMirror.dispose();
      });
    }
    final value = widget.value.replaceAll(RegExp(r'\r\n?'), '\n');
    if (value != _controller.text) {
      _controller.value = TextEditingValue(
        text: value,
        selection: TextSelection.collapsed(
          offset: widget.readOnly ? 0 : value.length,
        ),
      );
    }
  }

  @override
  void dispose() {
    _blink?.cancel();
    PaintingBinding.instance.systemFonts.removeListener(_fontsChanged);
    _focus.removeListener(_onFocus);
    _ownFocus?.dispose();
    _native.removeListener(_nativeChanged);
    _controller.removeListener(_mirrorChanged);
    _native.dispose();
    _controller.dispose();
    _codeScroll.dispose();
    _scroll.dispose();
    _horizontal.dispose();
    _caretOn.dispose();
    _hovering.dispose();
    _geometry.clear();
    _toolbar.dispose();
    super.dispose();
  }

  TextEditingValue _global(re.CodeLineEditingValue value) {
    final lines = value.codeLines;
    int at(int line, int offset) {
      var result = offset;
      for (var i = 0; i < line; i++) {
        result += lines[i].length + 1;
      }
      return result;
    }

    final selection = value.selection;
    final composing = value.composing;
    return TextEditingValue(
      text: lines.asString(re.TextLineBreak.lf, false),
      selection: TextSelection(
        baseOffset: at(selection.baseIndex, selection.baseOffset),
        extentOffset: at(selection.extentIndex, selection.extentOffset),
        affinity: selection.extentAffinity,
      ),
      composing: composing.isValid
          ? TextRange(
              start: at(selection.baseIndex, composing.start),
              end: at(selection.baseIndex, composing.end),
            )
          : TextRange.empty,
    );
  }

  re.CodeLineEditingValue _local(TextEditingValue value) {
    final lines = re.CodeLines.fromText(value.text);
    ({int index, int offset}) at(int position) {
      var offset = position.clamp(0, value.text.length);
      var index = 0;
      while (index + 1 < lines.length && offset > lines[index].length) {
        offset -= lines[index].length + 1;
        index++;
      }
      return (index: index, offset: offset);
    }

    final a = at(value.selection.isValid ? value.selection.baseOffset : 0),
        b = at(value.selection.isValid ? value.selection.extentOffset : 0);
    final c = value.composing;
    var start = 0;
    for (var i = 0; i < a.index; i++) {
      start += lines[i].length + 1;
    }
    return re.CodeLineEditingValue(
      codeLines: lines,
      selection: re.CodeLineSelection(
        baseIndex: a.index,
        baseOffset: a.offset,
        extentIndex: b.index,
        extentOffset: b.offset,
        baseAffinity: value.selection.affinity,
        extentAffinity: value.selection.affinity,
      ),
      composing: c.isValid ? TextRange(start: c.start - start, end: c.end - start) : TextRange.empty,
    );
  }

  void _mirrorChanged() {
    if (!_syncing) {
      _syncing = true;
      _native.value = _local(_controller.value);
      _syncing = false;
    }
    final current = _controller.value;
    _autoClosed.update(
      _lastText,
      current.text,
      current.selection.isValid ? current.selection.extentOffset : -1,
    );
    final digits = _doc.lineCount.toString().length;
    _lastText = current.text;
    _doc.setText(current.text);
    _restartBlink();
    if (mounted && digits != _doc.lineCount.toString().length) setState(() {});
  }

  void _nativeChanged() {
    if (_syncing) return;
    if (_transaction) {
      _doc.setText(_native.text);
      return;
    }
    final before = _controller.text;
    _syncing = true;
    _controller.value = _global(_native.value);
    _syncing = false;
    if (before != _controller.text) widget.onChanged?.call(_controller.text);
  }

  void _onFocus() => _restartBlink();
  void _restartBlink() {
    _blink?.cancel();
    _caretOn.value = _focus.hasFocus;
    if (!_focus.hasFocus || widget.readOnly) return;
    _blink = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => _caretOn.value = !_caretOn.value,
    );
  }

  void _apply(TextEditingValue value) {
    if (value == _controller.value) return;
    _native.value = _local(value);
    _native.makeCursorCenterIfInvisible();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (widget.readOnly || event is KeyUpEvent) {
      return KeyEventResult.ignored;
    }
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
    if (op == null) {
      return KeyEventResult.ignored;
    }
    _apply(op(_controller.value));
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final m = _metrics;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite ? constraints.maxWidth : 400.0;
        _viewportHeight = constraints.maxHeight.isFinite ? constraints.maxHeight : 0;
        final left = m.contentLeft(_doc.lineCount);
        _geometry.prepare(
          this,
          math.max(
            m.charWidth,
            width - left - CodeEditorMetrics.verticalScrollbarWidth - 2,
          ),
        );
        final state = _PaintState(this, left, width);
        final repaint = Listenable.merge([_controller, _focus, _scroll]);
        Widget paint(CustomPainter painter) => Positioned.fill(
          child: IgnorePointer(
            child: RepaintBoundary(
              child: CustomPaint(painter: _ScrollPainter(painter, _scroll)),
            ),
          ),
        );
        final editor = re.CodeEditor(
          controller: _native,
          scrollController: _codeScroll,
          focusNode: _focus,
          readOnly: widget.readOnly,
          autofocus: false,
          wordWrap: true,
          scrollBeyondLastLine: true,
          chunkAnalyzer: const re.NonCodeChunkAnalyzer(),
          autocompleteSymbols: false,
          padding: EdgeInsets.only(
            right: CodeEditorMetrics.verticalScrollbarWidth + 2,
            bottom: 0,
          ),
          margin: EdgeInsets.zero,
          verticalScrollbarWidth: CodeEditorMetrics.verticalScrollbarWidth,
          style: re.CodeEditorStyle(
            fontFamily: m.style.fontFamily,
            fontFamilyFallback: m.style.fontFamilyFallback,
            fontSize: m.style.fontSize,
            fontHeight: m.style.height,
            textColor: VsTheme.foreground,
            backgroundColor: Colors.transparent,
            selectionColor: Colors.transparent,
            cursorColor: Colors.transparent,
            cursorLineColor: Colors.transparent,
          ),
          indicatorBuilder: (context, controller, chunks, notifier) => SizedBox(
            width: left,
            height: _viewportHeight,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (d) => _selectLineAt(
                d.localPosition.dy + (_scroll.hasClients ? _scroll.offset : 0),
              ),
            ),
          ),
          scrollbarBuilder: (context, child, details) => details.direction == AxisDirection.down
              ? ValueListenableBuilder(
                  valueListenable: _hovering,
                  builder: (context, hovered, _) => DifyEditorScrollbar(
                    controller: _scroll,
                    visible: hovered,
                    width: CodeEditorMetrics.verticalScrollbarWidth,
                    color: VsTheme.scrollbarSlider,
                    hoverColor: VsTheme.scrollbarSliderHover,
                    activeColor: VsTheme.scrollbarSliderActive,
                    child: child,
                  ),
                )
              : child,
          shortcutOverrideActions: {
            re.CodeShortcutCommentIntent: CallbackAction<re.CodeShortcutCommentIntent>(
              onInvoke: (_) {
                if (!widget.readOnly) _apply(_editing.toggleLineComment(_controller.value));
                return null;
              },
            ),
          },
          toolbarController: _toolbar,
        );
        final field = Focus(
          onKeyEvent: _onKey,
          canRequestFocus: false,
          child: MouseRegion(
            onEnter: (_) => _hovering.value = true,
            onExit: (_) => _hovering.value = false,
            child: ClipRect(
              child: Stack(
                children: [
                  paint(_BackPainter(state, repaint)),
                  editor,
                  paint(
                    _CaretPainter(state, Listenable.merge([repaint, _caretOn])),
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
                  if (widget.readOnly)
                    Positioned(
                      right: 0,
                      top: 0,
                      bottom: 0,
                      width: CodeEditorMetrics.verticalScrollbarWidth,
                      child: IgnorePointer(
                        child: CustomPaint(
                          painter: _OverviewRulerPainter(state, repaint),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
        return ListenableBuilder(
          listenable: Listenable.merge([_controller, _focus]),
          child: field,
          builder: (context, child) => _CodeEditorSemantics(
            selection: _controller.selection,
            properties: SemanticsProperties(
              identifier: 'dify-code-editor-input',
              textField: true,
              multiline: true,
              focused: _focus.hasFocus,
              readOnly: widget.readOnly,
              value: _controller.text,
              onTap: _focus.requestFocus,
              onFocus: _focus.requestFocus,
              onDidGainAccessibilityFocus: _focus.requestFocus,
              onSetText: widget.readOnly
                  ? null
                  : (text) => _apply(
                      TextEditingValue(
                        text: text,
                        selection: TextSelection.collapsed(offset: text.length),
                      ),
                    ),
              onSetSelection: (selection) {
                if (selection.start < 0 || selection.end > _controller.text.length) return;
                _controller.selection = selection;
              },
              onCopy: _controller.selection.isCollapsed ? null : () => unawaited(_native.copy()),
              onCut: widget.readOnly || _controller.selection.isCollapsed ? null : _native.cut,
              onPaste: widget.readOnly ? null : _native.paste,
            ),
            child: child!,
          ),
        );
      },
    );
  }

  void _selectLineAt(double y) {
    final line = _layout.lineAtY(this, _geometry, y);
    final start = _doc.lineStart(line);
    final end = line + 1 < _doc.lineCount ? _doc.lineStart(line + 1) : _doc.lineEnd(line);
    _focus.requestFocus();
    _controller.selection = TextSelection(baseOffset: start, extentOffset: end);
  }
}

/// Publish selection on the same semantics node as its text-field flags/value,
/// just as RenderEditable does. The public Semantics widget has no selection
/// property, and a child proxy's selection is not absorbed into its parent.
class _CodeEditorSemantics extends SingleChildRenderObjectWidget {
  const _CodeEditorSemantics({required this.selection, required this.properties, required super.child});
  final TextSelection selection;
  final SemanticsProperties properties;
  @override
  _RenderCodeEditorSemantics createRenderObject(BuildContext context) => _RenderCodeEditorSemantics(
    selection,
    properties: properties,
    textDirection: Directionality.of(context),
  );
  @override
  void updateRenderObject(BuildContext context, _RenderCodeEditorSemantics renderObject) {
    renderObject
      ..properties = properties
      ..textDirection = Directionality.of(context)
      ..selection = selection;
  }
}

class _RenderCodeEditorSemantics extends RenderSemanticsAnnotations {
  _RenderCodeEditorSemantics(
    this._selection, {
    required super.properties,
    required super.textDirection,
  }) : super(container: true);
  TextSelection _selection;
  set selection(TextSelection value) {
    if (value == _selection) return;
    _selection = value;
    markNeedsSemanticsUpdate();
  }

  @override
  void describeSemanticsConfiguration(SemanticsConfiguration config) {
    super.describeSemanticsConfiguration(config);
    config.textSelection = _selection;
  }
}

class _NativeCodeController extends re.CodeLineEditingControllerDelegate {
  _NativeCodeController(this.owner, re.CodeLineEditingController source) : super(delegate: source);
  final CodeEditorViewState owner;
  @override
  re.CodeParagraphBuilder? get paragraphBuilder =>
      (span, style, width, maxLength) => owner._geometry.forSpan(span);
  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    required int index,
    required TextSpan textSpan,
    required TextStyle style,
  }) {
    owner._geometry.prepare(owner, owner._geometry.size.width);
    return owner._geometry.spanAt(index);
  }

  @override
  void edit(TextEditingValue next) {
    final old = owner._controller.value;
    owner._transaction = true;
    try {
      super.edit(next);
      final plain = owner._global(value);
      final formatted = _MonacoFormatter(owner).formatEditUpdate(old, plain);
      if (formatted != plain) value = owner._local(formatted);
    } finally {
      owner._transaction = false;
      owner._nativeChanged();
    }
  }

  @override
  void applyNewLine() => owner._apply(owner._editing.enter(owner._controller.value));
  @override
  void applyIndent() => owner._apply(owner._editing.tab(owner._controller.value));
  @override
  void applyOutdent() => owner._apply(
    owner._editing.shift(owner._controller.value, unshift: true),
  );
  @override
  void deleteBackward() {
    final current = owner._controller.value;
    final replacement = owner._editing.backspace(current, owner._autoClosed);
    if (replacement != null) {
      owner._apply(replacement);
    } else {
      super.deleteBackward();
    }
  }
}

class _ScrollPainter extends CustomPainter {
  _ScrollPainter(this.inner, this.scroll) : super(repaint: Listenable.merge([inner, scroll]));
  final CustomPainter inner;
  final ScrollController scroll;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.translate(0, -(scroll.hasClients ? scroll.offset : 0.0));
    inner.paint(canvas, size);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ScrollPainter old) => inner.shouldRepaint(old.inner) || old.scroll != scroll;
}

class _CodeToolbar implements re.SelectionToolbarController {
  _CodeToolbar(this.owner);
  final CodeEditorViewState owner;
  FocusNode get focus => owner._focus;
  bool get readOnly => owner.widget.readOnly;
  void dispose() => _context.remove();
  final _context = ContextMenuController();
  @override
  void show({
    required BuildContext context,
    required re.CodeLineEditingController controller,
    required TextSelectionToolbarAnchors anchors,
    Rect? renderRect,
    required LayerLink layerLink,
    required ValueNotifier<bool> visibility,
  }) {
    _context.show(
      context: context,
      contextMenuBuilder: (_) => DifySelectionMenu(
        anchors: anchors,
        focusParent: focus,
        buttonItems: [
          if (!readOnly && !controller.selection.isCollapsed)
            ContextMenuButtonItem(
              type: ContextMenuButtonType.cut,
              onPressed: controller.cut,
            ),
          if (!controller.selection.isCollapsed)
            ContextMenuButtonItem(
              type: ContextMenuButtonType.copy,
              onPressed: () => unawaited(controller.copy()),
            ),
          if (!readOnly)
            ContextMenuButtonItem(
              type: ContextMenuButtonType.paste,
              onPressed: controller.paste,
            ),
          ContextMenuButtonItem(
            type: ContextMenuButtonType.selectAll,
            onPressed: controller.selectAll,
          ),
        ],
      ),
    );
  }

  @override
  void hide(BuildContext context) => _context.remove();
}

class _CodeGeometry {
  final paragraphs = <WrappedParagraph>[];
  final _spans = <TextSpan>[];
  final _indices = Expando<int>();
  int _version = -1;
  double _width = -1;
  TextStyle? _style;
  TextRange _composing = TextRange.empty;
  Size get size => Size(math.max(0.0, _width), paragraphs.fold(0, (sum, p) => sum + p.height));
  bool get hasSize => paragraphs.isNotEmpty;
  void clear() {
    final retired = paragraphs.toList();
    // Previously laid out render objects may still paint in the current frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final p in retired) {
        p.dispose();
      }
    });
    paragraphs.clear();
    _spans.clear();
    _version = -1;
  }

  void prepare(CodeEditorViewState owner, double width) {
    final style = owner._metrics.style, composing = owner._controller.value.composing;
    if (_version == owner._doc.version && _width == width && _style == style && _composing == composing) {
      return;
    }
    clear();
    owner._layout._version = -1;
    _version = owner._doc.version;
    _width = width;
    _style = style;
    _composing = composing;
    for (var i = 0; i < owner._doc.lineCount; i++) {
      final start = owner._doc.lineStart(i), end = owner._doc.lineEnd(i);
      final underline = composing.isValid && composing.start <= end && composing.end >= start
          ? (composing.start - start, composing.end - start)
          : null;
      final span = TextSpan(
        style: style,
        children: [owner._controller._buildLine(i, underline)],
      );
      _indices[span] = i;
      _spans.add(span);
      paragraphs.add(
        WrappedParagraph(span, style, width, tabSize: owner._doc.tabSize),
      );
    }
    _document = owner._doc;
  }

  late CodeDocument _document;
  TextSpan spanAt(int index) => _spans[index];
  WrappedParagraph forSpan(TextSpan span) => paragraphs[_indices[span]!];
  Rect getLocalRectForCaret(TextPosition position) {
    final index = _document.lineAt(
      position.offset.clamp(0, _document.text.length),
    );
    final p = paragraphs[index];
    final offset = p.getOffset(
      TextPosition(
        offset: position.offset - _document.lineStart(index),
        affinity: position.affinity,
      ),
    );
    final y = paragraphs.take(index).fold(0.0, (sum, p) => sum + p.height);
    return Rect.fromLTWH(offset.dx, offset.dy + y, 1, p.preferredLineHeight);
  }

  List<ui.TextBox> getBoxesForSelection(TextSelection selection) {
    final result = <ui.TextBox>[];
    var top = 0.0;
    for (var i = 0; i < paragraphs.length; i++) {
      final start = _document.lineStart(i), end = _document.lineEnd(i), p = paragraphs[i];
      if (selection.start < end && selection.end > start) {
        for (final rect in p.getRangeRects(
          TextRange(
            start: math.max(start, selection.start) - start,
            end: math.min(end, selection.end) - start,
          ),
        )) {
          result.add(
            ui.TextBox.fromLTRBD(
              rect.left,
              rect.top + top,
              rect.right,
              rect.bottom + top,
              TextDirection.ltr,
            ),
          );
        }
      }
      top += p.height;
    }
    return result;
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

  void ensure(CodeEditorViewState s, _CodeGeometry box) {
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

  static int _row(_CodeGeometry box, TextPosition p, double lh) => (box.getLocalRectForCaret(p).center.dy / lh).floor();

  int lineAtY(CodeEditorViewState s, _CodeGeometry box, double y) {
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

  _CodeGeometry? get box => view._geometry.hasSize ? view._geometry : null;

  /// The visual row of the cursor (selection extent).
  int caretRow(_CodeGeometry box) {
    final sel = view._controller.selection;
    final lh = view._metrics.lineHeight;
    return _LineLayout._row(
      box,
      TextPosition(offset: sel.extentOffset, affinity: sel.affinity),
      lh,
    );
  }
}

/// Monaco's decorations overview ruler (`overviewRulerBorder`, the cursor lane): a 1 device pixel border on its left
/// and the cursor as a 2 px bar at the cursor line's place (the line's top scaled by the ruler's height over the
/// scroll height, which `scrollBeyondLastLine` extends by a viewport less a line). An editor never touched has its
/// cursor at 1:1.
class _OverviewRulerPainter extends CustomPainter {
  _OverviewRulerPainter(this.s, Listenable repaint) : super(repaint: repaint);
  final _PaintState s;

  @override
  void paint(Canvas canvas, Size size) {
    final px = 1 / ui.PlatformDispatcher.instance.implicitView!.devicePixelRatio;
    canvas.drawRect(
      Rect.fromLTWH(0, 0, px, size.height),
      Paint()..color = VsTheme.overviewRulerBorder,
    );
    final box = s.box;
    final sel = s.view._controller.selection;
    final lh = s.view._metrics.lineHeight;
    final row = box == null || !sel.isValid ? 0 : s.caretRow(box);
    final content = box?.size.height ?? lh;
    final scrollHeight = content + math.max(0.0, size.height - lh);
    final y = scrollHeight <= 0 ? 0.0 : (row * lh * size.height / scrollHeight).clamp(0.0, size.height - 2);
    canvas.drawRect(
      Rect.fromLTWH(px, y, size.width - px, 2),
      Paint()..color = VsTheme.overviewRulerCursor,
    );
  }

  @override
  bool shouldRepaint(_OverviewRulerPainter old) => old.s != s;
}

class _BackPainter extends CustomPainter {
  _BackPainter(this.s, Listenable repaint) : super(repaint: repaint);
  final _PaintState s;
  static final _numbers = <(String, bool, TargetPlatform, Color), TextPainter>{};

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
    // Monaco's cursor starts at 1:1, so an editor never touched has its first line current.
    final caretRow = sel.isValid ? s.caretRow(box) : 0;

    // Current line: a 2 px #eeeeee border around the cursor's row (only with an empty selection).
    if (!sel.isValid || sel.isCollapsed) {
      // Read-only viewers (run logs): the view lines end where the vertical scrollbar and its overview ruler begin.
      // Dify's editable editors in node panels lay Monaco out wider than their box, which hides both: there the
      // line runs to the box's edge.
      final end = view.widget.readOnly ? CodeEditorMetrics.verticalScrollbarWidth : 0.0;
      final r = Rect.fromLTWH(
        left,
        caretRow * lh,
        math.max(0.0, s.width - end - left),
        lh,
      ).deflate(1);
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
        canvas.drawRect(
          Rect.fromLTWH(left + x, layout.tops[i], 1, layout.rows[i] * lh),
          guidePaint,
        );
      }
    }

    // Bracket matching (focused, empty selection): the pair at the cursor, else the enclosing one.
    if (focused && sel.isValid && sel.isCollapsed) {
      final pair = doc.matchBracket(sel.baseOffset) ?? doc.enclosingBrackets(sel.baseOffset);
      if (pair != null) {
        for (final o in [pair.open, pair.close]) {
          final a = box.getLocalRectForCaret(TextPosition(offset: o));
          final b = box.getLocalRectForCaret(
            TextPosition(offset: o + 1, affinity: TextAffinity.upstream),
          );
          final row = (a.center.dy / lh).floor();
          final r = Rect.fromLTRB(
            left + a.left,
            row * lh,
            left + b.left,
            row * lh + lh,
          );
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
      final tp = _numbers.putIfAbsent(
        (
          '${i + 1}',
          isActive,
          defaultTargetPlatform,
          isActive ? VsTheme.activeLineNumber : VsTheme.lineNumber,
        ),
        () {
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
        },
      );
      tp.paint(canvas, Offset(numbersRight - tp.width, top + dy));
    }
  }

  /// Monaco's selection: per row, from the selection start to its end on that row, plus half a character where it
  /// takes the line break; 3 px rounded outer corners; `#ADD6FF` focused, `#E5EBF1` otherwise.
  void _paintSelection(Canvas canvas, _CodeGeometry box, bool focused) {
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
        final end = box.getLocalRectForCaret(
          TextPosition(offset: b, affinity: TextAffinity.upstream),
        );
        final endRow = (end.center.dy / lh).floor();
        for (final tb in box.getBoxesForSelection(
          TextSelection(baseOffset: a, extentOffset: b),
        )) {
          var rect = tb.toRect();
          if ((rect.center.dy / lh).floor() == endRow) {
            rect = Rect.fromLTRB(
              rect.left,
              rect.top,
              math.min(rect.right, end.left),
              rect.bottom,
            );
          }
          if (rect.width > 0) addRect(rect);
        }
      }
      if (sel.end > le) {
        // The line break: half a character after the line's end.
        final caret = box.getLocalRectForCaret(
          TextPosition(offset: le, affinity: TextAffinity.upstream),
        );
        addRect(
          Rect.fromLTWH(
            caret.left,
            caret.center.dy - lh / 2,
            m.charWidth / 2,
            lh,
          ),
        );
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
    final caret = box.getLocalRectForCaret(
      TextPosition(offset: sel.extentOffset, affinity: sel.affinity),
    );
    final row = (caret.center.dy / lh).floor();
    var x = caret.left;
    if (x >= 1) x -= 1;
    canvas.drawRect(
      Rect.fromLTWH(s.contentLeft + x, row * lh, 2, lh),
      Paint()..color = VsTheme.cursor,
    );
  }

  @override
  bool shouldRepaint(_CaretPainter old) => old.s.contentLeft != s.contentLeft || old.s.view != s.view;
}
