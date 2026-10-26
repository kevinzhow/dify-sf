import '../../../support/code_editor_input.dart';
// dify-spec: web/app/components/workflow/variable-inspect/__tests__/value-content.spec.tsx
import 'dart:convert';

import 'package:dify_sf_app/src/workflow_editor/code_editor/editor_view.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:dify_sf_app/src/workflow_editor/variable_inspect/inspect_vars.dart';
import 'package:dify_sf_app/src/workflow_editor/variable_inspect/value_content.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'inspect_harness.dart';

DifyJson createVar(DifyJson overrides) => {
  'id': 'var-default',
  'name': 'query',
  'type': VarInInspectType.node,
  'value_type': 'string',
  'value': '',
  ...overrides,
};

void main() {
  setUp(useDifyTestTranslator);

  group('ValueContent', () {
    late List<(String, Object?)> changes;

    setUp(() => changes = []);

    Future<void> render(WidgetTester t, DifyJson v, {bool isTruncated = false}) {
      final h = InspectHarness()..store.setFileUploadConfig({'workflow_file_upload_limit': 5});
      return h.pump(
        t,
        ValueContent(
          currentVar: v,
          handleValueChange: (id, value) => changes.add((id, value)),
          isTruncated: isTruncated,
        ),
      );
    }

    /// The debounce's wait.
    Future<void> waitDebounce(WidgetTester t) => t.pump(const Duration(milliseconds: 600));

    void files(WidgetTester t, List<DifyJson> files) =>
        t.widget<FileEditorSection>(find.byType(FileEditorSection)).onChange(files);

    testWidgets('should debounce text changes for string variables', (t) async {
      await render(t, createVar({'id': 'var-1', 'value_type': 'string', 'value': 'hello'}));

      await t.enterText(find.byType(TextField), 'updated');
      expect(changes, isEmpty);
      await waitDebounce(t);

      expect(changes, [('var-1', 'updated')]);
    });

    testWidgets('should surface parse errors from invalid json input', (t) async {
      await render(
        t,
        createVar({
          'id': 'var-2',
          'name': 'payload',
          'value_type': 'object',
          'value': {'foo': 1},
        }),
      );

      await enterCodeEditorText(t, '{');
      await t.pump();

      expect(find.textContaining(RegExp('json', caseSensitive: false)), findsOneWidget);
    });

    testWidgets('should debounce numeric changes', (t) async {
      await render(t, createVar({'id': 'var-3', 'name': 'count', 'value_type': 'number', 'value': 1}));

      await t.enterText(find.byType(TextField), '24.5');
      await waitDebounce(t);

      expect(changes, [('var-3', 24.5)]);
    });

    testWidgets('should update boolean values', (t) async {
      await render(t, createVar({'id': 'var-4', 'name': 'enabled', 'value_type': 'boolean', 'value': false}));

      await t.tap(find.text('True'));
      await waitDebounce(t);

      expect(changes, [('var-4', true)]);
    });

    testWidgets('should not emit changes when the content is truncated', (t) async {
      await render(t, createVar({'id': 'var-5', 'value_type': 'string', 'value': 'hello'}), isTruncated: true);

      await t.enterText(find.byType(TextField), 'updated');
      await waitDebounce(t);

      expect(changes, isEmpty);
    });

    testWidgets('should update boolean array values', (t) async {
      await render(
        t,
        createVar({
          'id': 'var-6',
          'name': 'flags',
          'value_type': 'array[boolean]',
          'value': [true, false],
        }),
      );

      await t.tap(find.text('True').at(1));
      await waitDebounce(t);

      expect(changes.single.$1, 'var-6');
      expect(changes.single.$2, [true, true]);
    });

    testWidgets('should parse valid json values', (t) async {
      await render(
        t,
        createVar({
          'id': 'var-7',
          'name': 'payload',
          'value_type': 'object',
          'value': {'foo': 1},
        }),
      );

      await enterCodeEditorText(t, '{"foo":2}');
      await waitDebounce(t);

      expect(changes.single.$1, 'var-7');
      expect(changes.single.$2, {'foo': 2});
    });

    testWidgets('should render LLM environment variables as read-only JSON', (t) async {
      const value = {'provider': 'openai', 'name': 'gpt-4o', 'mode': 'chat'};
      await render(
        t,
        createVar({
          'id': 'var-llm',
          'name': 'for_summarize',
          'type': VarInInspectType.environment,
          'value_type': 'llm',
          'value': value,
        }),
      );

      final editor = t.widget<CodeEditorView>(find.byType(CodeEditorView));
      expect(editor.value, const JsonEncoder.withIndent('  ').convert(value));
      expect(editor.readOnly, isTrue);
    });

    testWidgets('should update uploaded single file values and ignore pending uploads', (t) async {
      await render(t, createVar({'id': 'var-8', 'name': 'files', 'value_type': 'file', 'value': null}));

      files(t, [
        {'uploadedId': '', 'progress': 40},
      ]);
      await waitDebounce(t);
      expect(changes, isEmpty);

      files(t, [
        {'uploadedId': 'file-1', 'name': 'report.pdf', 'progress': 100},
      ]);
      await waitDebounce(t);

      expect(changes.single.$1, 'var-8');
      expect(changes.single.$2, containsPair('upload_file_id', 'file-1'));
    });

    // The ResizeObserver half (the editor's height less the error messages') is the Column's layout here.
    testWidgets('should update uploaded file arrays and react to resize observer changes', (t) async {
      await render(
        t,
        createVar({
          'id': 'var-9',
          'name': 'files',
          'type': VarInInspectType.system,
          'value_type': 'array[file]',
          'value': [],
        }),
      );

      files(t, [
        {'uploadedId': 'file-1', 'name': 'a.pdf', 'progress': 100},
        {'uploadedId': 'file-2', 'name': 'b.pdf', 'progress': 100},
      ]);
      await waitDebounce(t);

      expect(changes.single.$1, 'var-9');
      expect(changes.single.$2, [
        containsPair('upload_file_id', 'file-1'),
        containsPair('upload_file_id', 'file-2'),
      ]);
      expect(find.text('a.pdf'), findsOneWidget);
      expect(find.text('b.pdf'), findsOneWidget);
    });
  });
}
