// Ported from Monaco 0.52.2 (Microsoft, MIT):
// esm/vs/editor/common/viewModel/monospaceLineBreaksComputer.js (cold, uninjected lines),
// esm/vs/editor/common/modelLineProjectionData.js (source/view positions),
// esm/vs/editor/common/config/editorOptions.js (Dify's defaults), and base/common/strings.js.
// Wrapping is a view operation: this model never changes the source string.
library;

import 'dart:math' as math;

/// Monaco's wrappingIndent options. Dify leaves this at [same].
enum CodeWrappingIndent { none, same, indent, deepIndent }

/// A position in a visual row, including its virtual continuation indentation.
typedef CodeWrappedPosition = ({int row, int column});

class CodeLineWrapping {
  CodeLineWrapping._(this.source, this.breakOffsets, this.breakVisibleColumns, this.indentColumns);

  final String source;

  /// UTF-16 source offsets, including the source length as the final row end.
  final List<int> breakOffsets;
  final List<double> breakVisibleColumns;
  final int indentColumns;

  int get rowCount => breakOffsets.length;
  int startOf(int row) => row == 0 ? 0 : breakOffsets[row - 1];
  int indentOf(int row) => row == 0 ? 0 : indentColumns;

  /// Source offsets at a wrap boundary have two valid visual positions. An upstream affinity picks the previous
  /// row's end; downstream picks the next row's first source character, after its virtual indent.
  CodeWrappedPosition toView(int sourceOffset, {bool upstream = false}) {
    final offset = sourceOffset.clamp(0, source.length);
    var low = 0, high = rowCount - 1;
    while (low < high) {
      final mid = (low + high) >> 1;
      if (offset > breakOffsets[mid] || (!upstream && offset == breakOffsets[mid])) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return (row: low, column: offset - startOf(low) + indentOf(low));
  }

  /// Clicking inside the virtual indent selects the corresponding source boundary, not inserted whitespace.
  int toSource(int row, int column) {
    final r = row.clamp(0, rowCount - 1);
    return (startOf(r) + math.max(0, column - indentOf(r))).clamp(startOf(r), breakOffsets[r]).toInt();
  }

  static const breakBefore = '([{‘“〈《「『【〔（［｛｢£¥＄￡￥+＋';
  static const breakAfter =
      ' \t})]?|/&.,;¢°′″‰℃、。｡､￠，．：；？！％・･ゝゞヽヾーァィゥェォッャュョヮヵヶぁぃぅぇぉっゃゅょゎゕゖㇰㇱㇲㇳㇴㇵㇶㇷㇸㇹㇺㇻㇼㇽㇾㇿ々〻ｧｨｩｪｫｬｭｮｯｰ”〉》」』】〕）］｝｣';
  static final _before = breakBefore.codeUnits.toSet();
  static final _after = breakAfter.codeUnits.toSet();

  static bool isHighSurrogate(int code) => code >= 0xD800 && code <= 0xDBFF;
  static bool isFullWidth(int code) =>
      (code >= 0x2E80 && code <= 0xD7AF) || (code >= 0xF900 && code <= 0xFAFF) || (code >= 0xFF01 && code <= 0xFF5E);

  static double characterColumns(int code, double visibleColumn, int tabSize, double fullWidthColumns) {
    if (code == 9) return tabSize - (visibleColumn % tabSize);
    if (isFullWidth(code) || code < 32) return fullWidthColumns;
    return 1;
  }

  // NONE / BREAK_BEFORE / BREAK_AFTER / BREAK_IDEOGRAPHIC from Monaco's WrappingCharacterClassifier.
  static int _classOf(int code) {
    if (code > 255 &&
        ((code >= 0x3040 && code <= 0x30FF) ||
            (code >= 0x3400 && code <= 0x4DBF) ||
            (code >= 0x4E00 && code <= 0x9FFF))) {
      return 3;
    }
    if (_after.contains(code)) return 2;
    return _before.contains(code) ? 1 : 0;
  }

  static bool _canBreak(int previousClass, int code, int currentClass, bool keepAll) =>
      code != 32 &&
      ((previousClass == 2 && currentClass != 2) ||
          (previousClass != 1 && currentClass == 1) ||
          (!keepAll && previousClass == 3 && currentClass != 2) ||
          (!keepAll && currentClass == 3 && previousClass != 1));

  factory CodeLineWrapping.compute(
    String source, {
    required int columns,
    int tabSize = 4,
    double fullWidthColumns = 2,
    CodeWrappingIndent indent = CodeWrappingIndent.same,
    bool keepAll = false,
  }) {
    assert(columns == -1 || columns >= 1);
    assert(tabSize >= 1 && fullWidthColumns > 0);
    if (columns == -1 || source.length <= 1) {
      return CodeLineWrapping._(source, [source.length], const [], 0);
    }
    var continuationIndent = 0;
    if (indent != CodeWrappingIndent.none) {
      var firstContent = 0;
      while (firstContent < source.length &&
          (source.codeUnitAt(firstContent) == 32 || source.codeUnitAt(firstContent) == 9)) {
        firstContent++;
      }
      if (firstContent < source.length) {
        for (var i = 0; i < firstContent; i++) {
          continuationIndent += source.codeUnitAt(i) == 9 ? tabSize - continuationIndent % tabSize : 1;
        }
        final additionalTabs = switch (indent) {
          CodeWrappingIndent.deepIndent => 2,
          CodeWrappingIndent.indent => 1,
          _ => 0,
        };
        for (var i = 0; i < additionalTabs; i++) {
          continuationIndent += tabSize - continuationIndent % tabSize;
        }
        if (continuationIndent + fullWidthColumns > columns) continuationIndent = 0;
      }
    }
    final wrappedColumns = columns - continuationIndent;
    final offsets = <int>[];
    final visibleOffsets = <double>[];
    var breakOffset = 0;
    var breakVisible = 0.0;
    var limit = columns.toDouble();
    var previous = source.codeUnitAt(0);
    var previousClass = _classOf(previous);
    var visible = characterColumns(previous, 0, tabSize, fullWidthColumns);
    var first = 1;
    if (isHighSurrogate(previous)) {
      visible += 1;
      previousClass = _classOf(source.codeUnitAt(1));
      first++;
    }
    for (var i = first; i < source.length; i++) {
      final start = i;
      final code = source.codeUnitAt(i);
      final int currentClass;
      final double width;
      if (isHighSurrogate(code)) {
        i++;
        currentClass = 0;
        width = 2;
      } else {
        currentClass = _classOf(code);
        width = characterColumns(code, visible, tabSize, fullWidthColumns);
      }
      if (_canBreak(previousClass, code, currentClass, keepAll)) {
        breakOffset = start;
        breakVisible = visible;
      }
      visible += width;
      if (visible > limit) {
        if (breakOffset == 0 || visible - breakVisible > wrappedColumns) {
          breakOffset = start;
          breakVisible = visible - width;
        }
        offsets.add(breakOffset);
        visibleOffsets.add(breakVisible);
        limit = breakVisible + wrappedColumns;
        breakOffset = 0;
      }
      previousClass = currentClass;
    }
    if (offsets.isEmpty) return CodeLineWrapping._(source, [source.length], const [], 0);
    offsets.add(source.length);
    visibleOffsets.add(visible);
    return CodeLineWrapping._(
      source,
      List.unmodifiable(offsets),
      List.unmodifiable(visibleOffsets),
      continuationIndent,
    );
  }
}
