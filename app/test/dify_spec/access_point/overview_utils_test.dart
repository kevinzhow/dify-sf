// dify-spec: web/app/components/app/overview/__tests__/app-card-utils.spec.ts
// dify-spec: web/app/components/app/overview/__tests__/workflow-hidden-input-fields.spec.tsx
// dify-spec: web/app/components/app/overview/__tests__/workflow-launch-dialog.spec.tsx
import 'dart:convert';
import 'dart:io' show gzip;

import 'package:dify_sf_app/src/app_detail/access/access_point_utils.dart';
import 'package:dify_sf_app/src/app_detail/access/workflow_launch_dialog.dart';
import 'package:dify_sf_app/src/workflow_editor/panel_fields/selectors.dart' show DifySelect;
import 'package:flutter/material.dart';

import 'dart:ui' show CheckedState;

import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

Json _var(String variable, String label, String type, {Object? defaultValue}) => {
  'variable': variable,
  'label': label,
  'type': type,
  'hide': true,
  'required': false,
  'default': ?defaultValue,
};

/// The text field keyed [key] (Dify's `getByLabelText` / `getByPlaceholderText`).
Finder _field(String key) => find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(EditableText));

String _text(WidgetTester t, String key) => t.widget<EditableText>(_field(key)).controller.text;

void main() {
  group('app-card-utils', () {
    test('should create initial values from workflow launch defaults', () {
      expect(
        workflowLaunchInitialValues([
          _var('secret', 'Secret', 'text-input', defaultValue: 'prefilled'),
          _var('enabled', 'Enabled', 'checkbox', defaultValue: true),
        ]),
        {'secret': 'prefilled', 'enabled': true},
      );
    });

    test('should build a workflow launch URL with serialized parameters', () {
      final url = buildWorkflowLaunchUrl(
        accessibleUrl: 'https://example.com/app/workflow/token-1',
        variables: [_var('name', 'Name', 'text-input'), _var('enabled', 'Enabled', 'checkbox')],
        values: {'name': 'Alice', 'enabled': true},
      );
      final parsed = Uri.parse(url);
      expect(parsed.queryParameters['name'], 'Alice');
      expect(parsed.queryParameters['enabled'], 'true');
    });

    test('should serialize checkbox false and empty string values in launch URL', () {
      final url = buildWorkflowLaunchUrl(
        accessibleUrl: 'https://example.com/app/workflow/token-1',
        variables: [_var('flag', 'Flag', 'checkbox'), _var('empty', 'Empty', 'text-input')],
        values: {'flag': false, 'empty': ''},
      );
      final parsed = Uri.parse(url);
      expect(parsed.queryParameters['flag'], 'false');
      expect(parsed.queryParameters['empty'], '');
    });

    test('should generate an iframe snippet with the provided URL', () {
      final snippet = embeddedIframeSnippet('https://example.com/chatbot/token-1');
      expect(snippet, contains('src="https://example.com/chatbot/token-1"'));
      expect(snippet, contains('frameborder="0"'));
      expect(snippet, contains('allow="microphone;clipboard-write"'));
    });

    test('should generate an embedded script snippet with inputs', () {
      final snippet = embeddedScriptSnippet(
        url: 'https://example.com',
        token: 'abc123',
        primaryColor: '#FF0000',
        isTestEnv: true,
        inputValues: {'name': 'Alice', 'count': '5'},
      );
      expect(snippet, contains("token: 'abc123'"));
      expect(snippet, contains('isDev: true'));
      expect(snippet, contains('name: "Alice"'));
      expect(snippet, contains('count: "5"'));
      expect(snippet, contains('background-color: #FF0000'));
      expect(snippet, contains("baseUrl: 'https://example.com'"));
    });

    test('should generate an embedded script snippet with empty inputs comment', () {
      final snippet = embeddedScriptSnippet(
        url: 'https://example.com',
        token: 'abc123',
        primaryColor: '#1C64F2',
        inputValues: {},
      );
      expect(snippet, contains('// You can define the inputs from the Start node here'));
      expect(snippet, isNot(contains('isDev: true')));
    });

    test('should generate an agent embedded script route when requested', () {
      final snippet = embeddedScriptSnippet(
        url: 'https://example.com',
        token: 'agent-token',
        webAppRoute: 'agent',
        primaryColor: '#1C64F2',
        inputValues: {},
      );
      expect(snippet, contains("routeSegment: 'agent'"));
    });

    test('should compress and encode base64 using CompressionStream when available', () {
      final result = compressAndEncodeBase64('hello');
      expect(result, isNotEmpty);
      // A gzip stream of the input, as the browser's CompressionStream('gzip') writes it.
      expect(utf8.decode(gzip.decode(base64Decode(result))), 'hello');
    });

    test('should identify supported workflow launch input types', () {
      for (final type in ['text-input', 'paragraph', 'select', 'number', 'checkbox', 'json', 'json_object', 'url']) {
        expect(isWorkflowLaunchInputSupported(_var('v', 'V', type)), isTrue, reason: type);
      }
      expect(isWorkflowLaunchInputSupported(_var('v', 'V', 'files')), isFalse);
      expect(isWorkflowLaunchInputSupported(_var('v', 'V', 'file')), isFalse);
    });

    test('should coerce numeric defaults to string in createWorkflowLaunchInitialValues', () {
      expect(
        workflowLaunchInitialValues([
          _var('count', 'Count', 'number', defaultValue: 42),
          _var('empty', 'Empty', 'text-input'),
        ]),
        {'count': '42', 'empty': ''},
      );
    });
  });

  group('WorkflowHiddenInputFields', () {
    late List<(String, Object)> changes;

    Future<void> render(WidgetTester t, List<Json> vars, Map<String, Object> values, {String? prefix}) {
      changes = [];
      return renderMembers(
        t,
        Padding(
          padding: const EdgeInsets.all(16),
          child: prefix == null
              ? WorkflowHiddenInputFields(
                  hiddenVariables: vars,
                  values: values,
                  onValueChange: (k, v) => changes.add((k, v)),
                )
              : WorkflowHiddenInputFields(
                  hiddenVariables: vars,
                  values: values,
                  fieldIdPrefix: prefix,
                  onValueChange: (k, v) => changes.add((k, v)),
                ),
        ),
      );
    }

    testWidgets('should render a text input with label and placeholder', (t) async {
      await render(t, [_var('name', 'Full Name', 'text-input')], {'name': 'Alice'});
      expect(find.bySemanticsLabel('Full Name'), findsWidgets);
      expect(_text(t, 'workflow-launch-hidden-input-name'), 'Alice');
      await t.enterText(_field('workflow-launch-hidden-input-name'), 'Bob');
      expect(changes.last, ('name', 'Bob'));
    });

    testWidgets('should render a number input for number-typed variables', (t) async {
      await render(t, [_var('count', 'Count', 'number')], {'count': '5'});
      expect(t.widget<EditableText>(_field('workflow-launch-hidden-input-count')).keyboardType, TextInputType.number);
      await t.enterText(_field('workflow-launch-hidden-input-count'), '10');
      expect(changes.last, ('count', '10'));
    });

    testWidgets('should render a checkbox input without a separate label element above', (t) async {
      await render(t, [_var('enabled', 'Enable Feature', 'checkbox')], {'enabled': true});
      final box = find.semantics.byPredicate(
        (n) => n.getSemanticsData().flagsCollection.isChecked != CheckedState.none,
      );
      expect(box.evaluate().single.getSemanticsData().flagsCollection.isChecked, CheckedState.isTrue);
      expect(find.text('Enable Feature'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('workflow-launch-hidden-input-enabled')));
      expect(changes.last, ('enabled', false));
    });

    testWidgets('should render a select dropdown for select-typed variables', (t) async {
      await render(
        t,
        [
          {
            ..._var('color', 'Color', 'select'),
            'options': ['red', 'green', 'blue'],
          },
        ],
        {'color': 'red'},
      );
      final select = t.widget<DifySelect<String>>(find.byType(DifySelect<String>));
      expect(select.semanticLabel, 'Color');
      expect(select.value, 'red');
    });

    testWidgets('should render a textarea for paragraph-typed variables', (t) async {
      await render(
        t,
        [
          {..._var('description', 'Description', 'paragraph'), 'max_length': 500},
        ],
        {'description': 'Hello world'},
      );
      expect(_text(t, 'workflow-launch-hidden-input-description'), 'Hello world');
      await t.enterText(_field('workflow-launch-hidden-input-description'), 'Updated');
      expect(changes.last, ('description', 'Updated'));
    });

    testWidgets('should render a textarea for json-typed variables', (t) async {
      await render(t, [_var('config', 'Config JSON', 'json')], {'config': '{"key": "value"}'});
      expect(_text(t, 'workflow-launch-hidden-input-config'), '{"key": "value"}');
    });

    testWidgets('should render a textarea for jsonObject-typed variables', (t) async {
      await render(t, [_var('schema', 'Schema', 'json_object')], {'schema': '{}'});
      expect(_text(t, 'workflow-launch-hidden-input-schema'), '{}');
    });

    testWidgets('should use the variable key as label when label is not a string', (t) async {
      await render(
        t,
        [
          {
            ..._var('my_var', '', 'text-input'),
            'label': {'nodeType': 'start', 'nodeName': 'Start', 'variable': 'my_var'},
          },
        ],
        {'my_var': ''},
      );
      // The label (the input's placeholder shows it too).
      expect(find.descendant(of: find.byType(ExcludeSemantics), matching: find.text('my_var')), findsOneWidget);
    });

    testWidgets('should use the custom fieldIdPrefix for element ids', (t) async {
      await render(t, [_var('token', 'Token', 'text-input')], {'token': 'abc'}, prefix: 'custom-prefix');
      expect(find.byKey(const ValueKey('custom-prefix-token')), findsOneWidget);
    });

    testWidgets('should render empty string for non-string fieldValue in text inputs', (t) async {
      await render(t, [_var('flag', 'Flag', 'text-input')], {'flag': true});
      expect(_text(t, 'workflow-launch-hidden-input-flag'), '');
    });
  });

  group('WorkflowLaunchDialog', () {
    final hiddenVariables = [_var('secret', 'Secret', 'text-input', defaultValue: 'initial')];

    Future<List<String>> render(WidgetTester t) async {
      final opened = <String>[];
      await renderMembers(
        t,
        Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => showWorkflowLaunchDialog(
                context,
                hiddenVariables: hiddenVariables,
                targetUrl: 'https://example.test/workflow',
                openUrl: opened.add,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await t.tap(find.text('open'));
      await settle(t);
      return opened;
    }

    testWidgets('opens the workflow with entered hidden values and closes the dialog', (t) async {
      final opened = await render(t);
      await t.enterText(_field('workflow-launch-hidden-input-secret'), 'entered value');
      await t.pump();
      await tapButton(t, RegExp(r'overview\.appInfo\.launch'));
      expect(opened, ['https://example.test/workflow?secret=entered+value']);
      expect(find.byType(WorkflowLaunchDialog), findsNothing);
    });

    testWidgets('resets hidden values when the controlled dialog is reopened', (t) async {
      await render(t);
      await t.enterText(_field('workflow-launch-hidden-input-secret'), 'changed');
      await t.pump();
      expect(_text(t, 'workflow-launch-hidden-input-secret'), 'changed');
      await tapButton(t, 'common.operation.cancel');
      expect(find.byType(WorkflowLaunchDialog), findsNothing);
      await t.tap(find.text('open'));
      await settle(t);
      expect(_text(t, 'workflow-launch-hidden-input-secret'), 'initial');
    });

    testWidgets('renders nothing when there are no hidden variables', (t) async {
      await renderMembers(
        t,
        Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => showWorkflowLaunchDialog(
                context,
                hiddenVariables: const [],
                targetUrl: 'https://example.test/workflow',
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await t.tap(find.text('open'));
      await settle(t);
      expect(find.byType(WorkflowLaunchDialog), findsNothing);
    });
  });
}
