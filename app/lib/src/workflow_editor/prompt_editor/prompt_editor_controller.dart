import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'prompt_blocks.dart';

/// Builds the widget of the block at [offset] of the editor text.
typedef PromptChipBuilder = Widget Function(BuildContext context, PromptBlock block, int offset);

/// The text of a [DifyPromptEditor]: Dify's prompt string, edited as text in which every block is one character.
///
/// [text] is the display text: each block (a Lexical decorator node in Dify) is a private-use character mapped to
/// its [PromptBlock], so the caret steps over a block in one move, Backspace deletes it whole, and undo, which
/// restores old values, brings blocks back. [prompt] is the Dify string. Typed or pasted tokens turn into blocks as
/// Dify's replacement transforms turn them, for the kinds in [blocks].
class PromptEditorController extends TextEditingController {
  PromptEditorController({String prompt = '', PromptBlockSet blocks = PromptBlockSet.none}) : _blockSet = blocks {
    super.value = TextEditingValue(text: _encode(parsePrompt(prompt, blocks)));
  }

  static const _firstCode = 0xE000, _lastCode = 0xF8FF;

  final _codeOf = <String, int>{};
  final _blockOf = <int, PromptBlock>{};
  int _next = _firstCode;

  /// Builds block widgets ([DifyPromptEditor] sets it); without one, blocks show as their text.
  PromptChipBuilder? chipBuilder;

  /// Called for each block a transform or an insert creates (Dify's `onInsert`) and each block that leaves the text
  /// (`onDelete`).
  void Function(PromptBlock block)? onBlockCreated, onBlockRemoved;

  PromptBlockSet _blockSet;
  PromptBlockSet get blocks => _blockSet;

  /// Changes the kinds tokens turn into. Newly enabled kinds convert the tokens already in the text (Lexical marks
  /// all nodes dirty when a transform registers); blocks already made stay.
  set blocks(PromptBlockSet v) {
    if (v == _blockSet) return;
    _blockSet = v;
    value = _transform(value);
  }

  /// The block a display character stands for.
  PromptBlock? blockAt(int offset) => offset >= 0 && offset < text.length ? _blockOf[text.codeUnitAt(offset)] : null;

  /// The prompt as Dify stores it.
  String get prompt => serialize(0, text.length);

  /// Replaces the content (Dify's ValueSyncPlugin / UpdateBlock: a new editor state from the text). The caret keeps
  /// its offset where it can.
  set prompt(String v) {
    if (v == prompt) return;
    final display = _encode(parsePrompt(v, _blockSet));
    final at = selection.isValid ? selection.extentOffset.clamp(0, display.length) : display.length;
    final before = _codes(text);
    super.value = TextEditingValue(
      text: display,
      selection: TextSelection.collapsed(offset: at),
    );
    _report(before, _codes(display));
  }

  /// The prompt text of display range [start, end).
  String serialize(int start, int end) {
    final b = StringBuffer();
    for (var i = start; i < end; i++) {
      final c = text.codeUnitAt(i);
      final block = _blockOf[c];
      block == null ? b.writeCharCode(c) : b.write(block.text);
    }
    return b.toString();
  }

  /// The prompt text of the selection (what Copy puts on the clipboard: Lexical copies a block as its text).
  String get selectedPrompt =>
      selection.isValid && !selection.isCollapsed ? serialize(selection.start, selection.end) : '';

  /// Replaces the selection with [block] and puts the caret after it (`$insertNodes`).
  void insertBlock(PromptBlock block, {TextRange? replacing}) => _replace(replacing, String.fromCharCode(_code(block)));

  /// Replaces the selection (or [replacing]) with [s], which is transformed like typed text.
  void insertText(String s, {TextRange? replacing}) => _replace(replacing, _encode([s]));

  void _replace(TextRange? range, String s) {
    final r = range ?? (selection.isValid ? selection : TextSelection.collapsed(offset: text.length));
    value = TextEditingValue(
      text: text.replaceRange(r.start, r.end, s),
      selection: TextSelection.collapsed(offset: r.start + s.length),
    );
  }

  @override
  set value(TextEditingValue v) {
    if (v.text == text) {
      super.value = v;
      return;
    }
    final before = _codes(text);
    v = _transform(_adopt(v));
    super.value = v;
    _report(before, _codes(v.text));
  }

  // -- display text

  int _code(PromptBlock block) => _codeOf[block.text] ??= () {
    if (_next > _lastCode) throw StateError('too many distinct prompt blocks');
    _blockOf[_next] = block;
    return _next++;
  }();

  bool _isPrivate(int c) => c >= _firstCode && c <= _lastCode;

  /// Display text for parsed pieces; private-use characters of the prompt itself become literal blocks.
  String _encode(Iterable<Object> pieces) {
    final b = StringBuffer();
    for (final p in pieces) {
      if (p is PromptBlock) {
        b.writeCharCode(_code(p));
      } else {
        for (final c in (p as String).codeUnits) {
          b.writeCharCode(_isPrivate(c) ? _code(PromptBlock.literal(String.fromCharCode(c))) : c);
        }
      }
    }
    return b.toString();
  }

  /// Private-use characters that came from outside (not one of ours) are kept as literal text.
  TextEditingValue _adopt(TextEditingValue v) {
    final t = v.text;
    for (var i = 0; i < t.length; i++) {
      final c = t.codeUnitAt(i);
      if (_isPrivate(c) && !_blockOf.containsKey(c)) {
        return v.copyWith(text: _encode([t]));
      }
    }
    return v;
  }

  /// Runs the replacement transforms over every text run (between blocks and line breaks), mapping the selection.
  /// Not while an input method is composing.
  TextEditingValue _transform(TextEditingValue v) {
    if (_blockSet.kinds.isEmpty || v.composing.isValid && !v.composing.isCollapsed) return v;
    final t = v.text;
    final out = StringBuffer();
    final cuts = <(int, int)>[]; // (start, end) of each token in the old text, now one character
    var runStart = 0;
    void flush(int end) {
      if (end <= runStart) return;
      final run = t.substring(runStart, end);
      var at = runStart;
      for (final p in transformText(run, _blockSet)) {
        if (p is PromptBlock) {
          final n = p.text.length;
          cuts.add((at, at + n));
          out.writeCharCode(_code(p));
          at += n;
        } else {
          out.write(p);
          at += (p as String).length;
        }
      }
    }

    for (var i = 0; i < t.length; i++) {
      final c = t.codeUnitAt(i);
      if (c == 0x0A || _blockOf.containsKey(c)) {
        flush(i);
        out.writeCharCode(c);
        runStart = i + 1;
      }
    }
    flush(t.length);
    if (cuts.isEmpty) return v;
    int map(int o) {
      var shift = 0;
      for (final (s, e) in cuts) {
        if (o <= s) break;
        if (o < e) return s + 1 - shift;
        shift += e - s - 1;
      }
      return o - shift;
    }

    final sel = v.selection;
    return TextEditingValue(
      text: out.toString(),
      selection: sel.isValid ? sel.copyWith(baseOffset: map(sel.baseOffset), extentOffset: map(sel.extentOffset)) : sel,
    );
  }

  Map<int, int> _codes(String t) {
    final m = <int, int>{};
    for (final c in t.codeUnits) {
      if (_blockOf.containsKey(c)) m[c] = (m[c] ?? 0) + 1;
    }
    return m;
  }

  void _report(Map<int, int> before, Map<int, int> after) {
    if (onBlockCreated == null && onBlockRemoved == null) return;
    for (final code in {...before.keys, ...after.keys}) {
      final d = (after[code] ?? 0) - (before[code] ?? 0);
      final block = _blockOf[code]!;
      if (block.kind == PromptBlockKind.literal) continue;
      for (var i = 0; i < d.abs(); i++) {
        (d > 0 ? onBlockCreated : onBlockRemoved)?.call(block);
      }
    }
  }

  // -- rendering

  /// Styles the `{{name}}` entities of each text run (Dify's VariableValueBlockNode: `text-text-accent
  /// px-0.5`), when [PromptBlockSet.variableValue].
  TextStyle? variableValueStyle;

  @override
  TextSpan buildTextSpan({required BuildContext context, TextStyle? style, required bool withComposing}) {
    final t = text;
    final composing = withComposing && value.isComposingRangeValid ? value.composing : TextRange.empty;
    final children = <InlineSpan>[];
    void span(int s, int e, TextStyle? st) {
      if (e > s) children.add(TextSpan(text: t.substring(s, e), style: st));
    }

    // A piece of text, with the composing range underlined.
    void piece(int s, int e, TextStyle? st) {
      if (!composing.isValid || composing.start >= e || composing.end <= s) return span(s, e, st);
      final cs = composing.start.clamp(s, e), ce = composing.end.clamp(s, e);
      span(s, cs, st);
      span(cs, ce, (st ?? const TextStyle()).merge(const TextStyle(decoration: TextDecoration.underline)));
      span(ce, e, st);
    }

    void addText(int start, int end) {
      final entity = variableValueStyle;
      if (!_blockSet.variableValue || entity == null) return piece(start, end, null);
      var at = start;
      for (final r in variableValueRanges(t.substring(start, end))) {
        final s = start + r.start, e = start + r.end;
        // px-0.5: 2 px before the entity (after the character before it) and after its last character.
        if (s > at) {
          piece(at, s - 1, null);
          piece(s - 1, s, const TextStyle(letterSpacing: 2));
        }
        piece(s, e - 1, entity);
        piece(e - 1, e, entity.merge(const TextStyle(letterSpacing: 2)));
        at = e;
      }
      piece(at, end, null);
    }

    var runStart = 0;
    for (var i = 0; i < t.length; i++) {
      final c = t.codeUnitAt(i);
      final block = _blockOf[c];
      if (c != 0x0A && block == null) continue;
      addText(runStart, i);
      runStart = i + 1;
      if (block == null) {
        children.add(const TextSpan(text: '\n'));
      } else if (block.kind == PromptBlockKind.literal || chipBuilder == null) {
        children.add(TextSpan(text: block.kind == PromptBlockKind.literal ? block.text : '￼'));
      } else {
        children.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic,
            child: CssMiddle(fontSize: style?.fontSize ?? 14, child: chipBuilder!(context, block, i)),
          ),
        );
      }
    }
    addText(runStart, t.length);
    return TextSpan(style: style, children: children);
  }
}

/// CSS `vertical-align: middle` for an inline box: its middle on the baseline raised by half the x-height (Noto
/// Sans: 536 / 1000 em). Reports that baseline for [PlaceholderAlignment.baseline].
class CssMiddle extends SingleChildRenderObjectWidget {
  const CssMiddle({super.key, required this.fontSize, required Widget super.child});
  final double fontSize;

  static const xHeight = 0.536;

  @override
  RenderObject createRenderObject(BuildContext context) => RenderCssMiddle(fontSize);

  @override
  void updateRenderObject(BuildContext context, RenderCssMiddle renderObject) => renderObject.fontSize = fontSize;
}

class RenderCssMiddle extends RenderProxyBox {
  RenderCssMiddle(this._fontSize);
  double _fontSize;
  set fontSize(double v) {
    if (v == _fontSize) return;
    _fontSize = v;
    markNeedsLayout();
  }

  double _baselineFor(double height) => height / 2 + _fontSize * CssMiddle.xHeight / 2;

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) => _baselineFor(size.height);

  @override
  double? computeDryBaseline(BoxConstraints constraints, TextBaseline baseline) =>
      _baselineFor(getDryLayout(constraints).height);
}
