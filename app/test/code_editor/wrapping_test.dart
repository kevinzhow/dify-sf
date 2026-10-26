import 'dart:convert';
import 'dart:io';

import 'package:dify_sf_app/src/workflow_editor/code_editor/wrapping.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final reference =
      jsonDecode(File('test/code_editor/monaco_wrapping.json').readAsStringSync()) as Map<String, dynamic>;
  test('uses the pinned Monaco default break characters', () {
    expect(reference['version'], '0.52.2');
    expect(CodeLineWrapping.breakBefore, reference['breakBefore']);
    expect(CodeLineWrapping.breakAfter, reference['breakAfter']);
  });

  final cases = reference['cases'] as List;
  for (var index = 0; index < cases.length; index++) {
    final c = cases[index] as Map<String, dynamic>;
    test('Monaco wrapping, case $index (${c['columns']} columns, indent ${c['indent']})', () {
      final text = c['text'] as String;
      final line = CodeLineWrapping.compute(
        text,
        columns: c['columns'] as int,
        tabSize: c['tabSize'] as int,
        fullWidthColumns: (c['fullWidthColumns'] as num).toDouble(),
        indent: CodeWrappingIndent.values[c['indent'] as int],
        keepAll: c['keepAll'] as bool,
      );
      expect(line.breakOffsets, c['breakOffsets']);
      expect(line.breakVisibleColumns, c['breakVisibleColumns']);
      expect(line.indentColumns, c['indentColumns']);
      expect(line.source, text);
      for (final point in c['positions'] as List) {
        final p = point as Map<String, dynamic>;
        final offset = p['offset'] as int;
        final before = line.toView(offset, upstream: true);
        final after = line.toView(offset);
        expect([before.row, before.column], p['upstream'], reason: 'offset $offset upstream');
        expect([after.row, after.column], p['downstream'], reason: 'offset $offset downstream');
        expect(line.toSource(before.row, before.column), offset);
        expect(line.toSource(after.row, after.column), offset);
      }
      for (var row = 0; row < line.rowCount; row++) {
        for (var column = 0; column <= line.indentOf(row); column++) {
          expect(line.toSource(row, column), line.startOf(row), reason: 'virtual indentation has no source text');
        }
      }
      for (final end in line.breakOffsets) {
        if (end > 0 && end < text.length) {
          expect(
            CodeLineWrapping.isHighSurrogate(text.codeUnitAt(end - 1)),
            isFalse,
            reason: 'a surrogate pair must not be split',
          );
        }
      }
    });
  }
}
