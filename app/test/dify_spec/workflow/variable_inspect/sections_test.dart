// dify-spec: web/app/components/workflow/variable-inspect/__tests__/value-content-sections.spec.tsx
// dify-spec: web/app/components/workflow/variable-inspect/__tests__/display-content.spec.tsx
// dify-spec: web/app/components/workflow/variable-inspect/__tests__/large-data-alert.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/code_editor/editor_view.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:dify_sf_app/src/workflow_editor/variable_inspect/inspect_vars.dart';
import 'package:dify_sf_app/src/workflow_editor/variable_inspect/value_content.dart';
import 'package:dify_sf_app/src/workflow_editor/variable_inspect/value_content_helpers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'inspect_harness.dart';

DifyJson createVar(DifyJson overrides) => {
  'id': 'var-1',
  'name': 'query',
  'type': VarInInspectType.node,
  'value_type': 'string',
  'value': '',
  ...overrides,
};

void main() {
  setUp(useDifyTestTranslator);

  group('value-content sections', () {
    testWidgets('should render the text editor section and forward text changes', (t) async {
      final changes = <String>[];
      await InspectHarness().pump(
        t,
        TextEditorSection(
          currentVar: createVar({'value_type': 'string'}),
          value: 'hello',
          textEditorDisabled: false,
          isTruncated: false,
          onTextChange: changes.add,
        ),
      );

      await t.enterText(find.byType(TextField), 'updated');
      expect(changes, ['updated']);
    });

    testWidgets('should render the textarea editor for non-string values', (t) async {
      final changes = <String>[];
      await InspectHarness().pump(
        t,
        TextEditorSection(
          currentVar: createVar({'name': 'count', 'value_type': 'number'}),
          value: '12',
          textEditorDisabled: false,
          isTruncated: false,
          onTextChange: changes.add,
        ),
      );

      await t.enterText(find.byType(TextField), '24');
      expect(changes, ['24']);
    });

    testWidgets('should update a boolean array item by index', (t) async {
      final changes = <List<bool>>[];
      await InspectHarness().pump(t, BoolArraySection(values: const [true, false], onChange: changes.add));

      await t.tap(find.text('True').at(1));
      expect(changes, [
        [true, true],
      ]);
    });

    testWidgets('should render schema editor and error messages', (t) async {
      final changes = <String>[];
      await InspectHarness().pump(
        t,
        Column(
          children: [
            Expanded(
              child: JsonEditorSection(
                hasChunks: false,
                valueType: 'object',
                json: '{}',
                readonly: false,
                isTruncated: false,
                onChange: changes.add,
              ),
            ),
            const ErrorMessages(parseError: FormatException('Broken JSON'), validationError: 'Too deep'),
          ],
        ),
      );

      await t.enterText(find.byType(EditableText), '{"foo":1}');
      expect(changes.last, '{"foo":1}');
      expect(find.text('Broken JSON'), findsOneWidget);
      expect(find.text('Too deep'), findsOneWidget);
    });

    testWidgets('should render chunk preview when the json editor has chunks', (t) async {
      await InspectHarness().pump(
        t,
        JsonEditorSection(
          hasChunks: true,
          schemaType: 'general_structure',
          valueType: 'object',
          json: '{}',
          readonly: false,
          isTruncated: false,
          onChange: (_) {},
        ),
      );

      expect(find.byType(CodeEditorView), findsOneWidget);
      // `system-xs-semibold-uppercase` shows "OBJECT(general_structure)" upper-cased.
      expect(find.text('OBJECT(GENERAL_STRUCTURE)'), findsOneWidget);
    });

    testWidgets('should render the file editor section', (t) async {
      await InspectHarness().pump(
        t,
        FileEditorSection(
          currentVar: createVar({'name': 'files', 'value_type': 'file'}),
          fileValue: const [],
          fileUploadConfig: const {'workflow_file_upload_limit': 5},
          textEditorDisabled: false,
          onChange: (_) {},
        ),
      );

      expect(find.text('common.fileUploader.uploadFromComputer'), findsOneWidget);
      expect(find.text('common.fileUploader.pasteFileLink'), findsOneWidget);
    });
  });

  group('variable inspect display content', () {
    Widget display({ValueChanged<String>? onText}) => DisplayContent(
      previewType: PreviewType.markdown,
      varType: 'string',
      mdString: 'hello markdown',
      readonly: false,
      handleTextChange: onText,
    );

    testWidgets('renders markdown code view and forwards text edits', (t) async {
      final changes = <String>[];
      await InspectHarness().pump(t, display(onText: changes.add));

      expect(find.text('MARKDOWN'), findsOneWidget);

      await t.enterText(find.byType(TextField), 'updated markdown');
      expect(changes, ['updated markdown']);
    });

    testWidgets('keeps the active view selected when clicking the selected segmented control item', (t) async {
      final semantics = t.ensureSemantics();
      await InspectHarness().pump(t, display());
      final code = find.bySemanticsLabel('workflow.nodes.templateTransform.code');

      expect(t.getSemantics(code), isSemantics(isChecked: true, isInMutuallyExclusiveGroup: true));

      await t.tap(code);
      await t.pump();

      expect(t.getSemantics(code), isSemantics(isChecked: true, isInMutuallyExclusiveGroup: true));
      expect(find.byType(TextField), findsOneWidget);
      semantics.dispose();
    });
  });

  group('LargeDataAlert', () {
    testWidgets('should render the default message and export action when a download URL exists', (t) async {
      await InspectHarness().pump(t, const LargeDataAlert(downloadUrl: 'https://example.com/export.json'));

      expect(find.text('workflow.debug.variableInspect.largeData'), findsOneWidget);
      expect(
        t.widget<Tooltip>(find.byType(Tooltip)).message,
        'workflow.debug.variableInspect.largeData',
        reason: 'the message is its own title',
      );
      expect(find.text('WORKFLOW.DEBUG.VARIABLEINSPECT.EXPORT'), findsOneWidget);
    });

    testWidgets('should render the no-export message and omit the export action when the URL is missing', (t) async {
      await InspectHarness().pump(t, const LargeDataAlert(textHasNoExport: true));

      expect(find.text('workflow.debug.variableInspect.largeDataNoExport'), findsOneWidget);
      expect(t.widget<Tooltip>(find.byType(Tooltip)).message, 'workflow.debug.variableInspect.largeDataNoExport');
      expect(find.text('WORKFLOW.DEBUG.VARIABLEINSPECT.EXPORT'), findsNothing);
    });
  });
}
