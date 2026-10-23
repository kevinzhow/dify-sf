// dify-spec: web/app/components/workflow/nodes/agent-v2/components/agent-output-variables/__tests__/index.spec.tsx
// dify-spec: web/app/components/workflow/nodes/agent-v2/components/agent-output-variables/__tests__/utils.spec.ts
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/agent_v2_logic.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/agent_v2_outputs.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../dify_test_i18n.dart';

const _editorLabel = 'workflow.nodes.agent.outputVars.editorLabel';
const _confirmLabel = 'workflow.nodes.agent.outputVars.confirm';

Future<List<List<Map<String, Object?>>>> _render(WidgetTester t, List<Map<String, Object?>> outputs) async {
  final changes = <List<Map<String, Object?>>>[];
  t.view.physicalSize = const Size(800, 1200);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      home: Material(
        child: SizedBox(
          width: 400,
          child: SingleChildScrollView(
            child: AgentOutputVariables(outputs: outputs, onChange: changes.add),
          ),
        ),
      ),
    ),
  );
  await t.pumpAndSettle();
  return changes;
}

Future<void> _expand(WidgetTester t) async {
  await t.tap(find.text('WORKFLOW.NODES.COMMON.OUTPUTVARS'));
  await t.pumpAndSettle();
}

Finder _button(String label) => find.bySemanticsLabel(label);

Future<void> _confirmName(WidgetTester t, String name) async {
  final editor = find.bySemanticsLabel(_editorLabel);
  expect(editor, findsOneWidget);
  await t.enterText(
    find.descendant(of: find.byKey(const ValueKey('output-name')), matching: find.byType(TextField)),
    name,
  );
  await t.pump();
  await t.tap(find.bySemanticsLabel(_confirmLabel));
  await t.pumpAndSettle();
}

OutputDraft _draft({
  String defaultValue = '',
  String description = '',
  String name = 'summary',
  bool required = false,
  String type = 'string',
  List<Map<String, Object?>> children = const [],
}) => (
  defaultValue: defaultValue,
  description: description,
  name: name,
  required: required,
  type: type,
  children: children,
);

void main() {
  setUp(useDifyTestTranslator);

  group('AgentOutputVariables', () {
    testWidgets('should keep system text immutable while custom outputs remain editable', (t) async {
      await _render(t, [
        agentV2SystemTextOutput,
        {'name': 'summary', 'type': 'string', 'required': false},
      ]);
      await _expand(t);
      expect(_button('workflow.nodes.agent.outputVars.edit:{"name":"text"}'), findsNothing);
      expect(_button('workflow.nodes.agent.outputVars.delete:{"name":"text"}'), findsNothing);
      expect(_button('workflow.nodes.agent.outputVars.edit:{"name":"summary"}'), findsOneWidget);
      expect(_button('workflow.nodes.agent.outputVars.delete:{"name":"summary"}'), findsOneWidget);
    });

    testWidgets('should add an object child without opening the parent editor', (t) async {
      final changes = await _render(t, [
        {'name': 'profile', 'type': 'object', 'required': true, 'description': 'User profile'},
      ]);
      await _expand(t);
      await t.tap(_button('common.operation.add profile'));
      await t.pumpAndSettle();
      expect(find.bySemanticsLabel(_editorLabel), findsOneWidget);
      expect(find.text('profile'), findsOneWidget);
      await _confirmName(t, 'email');
      expect(changes.single, [
        {
          'name': 'profile',
          'type': 'object',
          'required': true,
          'description': 'User profile',
          'children': [
            {'name': 'email', 'type': 'string', 'required': false},
          ],
        },
      ]);
    });

    testWidgets('should append children to array object items', (t) async {
      final changes = await _render(t, [
        {
          'name': 'addresses',
          'type': 'array',
          'required': false,
          'array_item': {'type': 'object'},
        },
      ]);
      await _expand(t);
      await t.tap(_button('common.operation.add addresses'));
      await t.pumpAndSettle();
      await _confirmName(t, 'city');
      expect(changes.single, [
        {
          'name': 'addresses',
          'type': 'array',
          'required': false,
          'array_item': {
            'type': 'object',
            'children': [
              {'name': 'city', 'type': 'string', 'required': false},
            ],
          },
        },
      ]);
    });

    testWidgets('should add nested children under the selected object child', (t) async {
      final changes = await _render(t, [
        {
          'name': 'profile',
          'type': 'object',
          'required': true,
          'children': [
            {'name': 'contact', 'type': 'object', 'required': true},
          ],
        },
      ]);
      await _expand(t);
      await t.tap(_button('common.operation.add contact'));
      await t.pumpAndSettle();
      await _confirmName(t, 'email');
      expect(changes.single, [
        {
          'name': 'profile',
          'type': 'object',
          'required': true,
          'children': [
            {
              'name': 'contact',
              'type': 'object',
              'required': true,
              'children': [
                {'name': 'email', 'type': 'string', 'required': false},
              ],
            },
          ],
        },
      ]);
    });

    testWidgets('should edit only the selected nested child', (t) async {
      final changes = await _render(t, [
        {
          'name': 'profile',
          'type': 'object',
          'required': true,
          'children': [
            {
              'name': 'contact',
              'type': 'object',
              'required': true,
              'children': [
                {'name': 'email', 'type': 'string', 'required': true, 'description': 'Primary email'},
              ],
            },
          ],
        },
      ]);
      await _expand(t);
      await t.tap(_button('workflow.nodes.agent.outputVars.edit:{"name":"email"}'));
      await t.pumpAndSettle();
      expect(find.bySemanticsLabel(_editorLabel), findsOneWidget);
      await _confirmName(t, 'work_email');
      expect(changes.single, [
        {
          'name': 'profile',
          'type': 'object',
          'required': true,
          'children': [
            {
              'name': 'contact',
              'type': 'object',
              'required': true,
              'children': [
                {'name': 'work_email', 'type': 'string', 'required': true, 'description': 'Primary email'},
              ],
            },
          ],
        },
      ]);
    });

    testWidgets('should reject editing an output name with dots', (t) async {
      final changes = await _render(t, [
        {'name': 'summary', 'type': 'string', 'required': true},
      ]);
      await _expand(t);
      await t.tap(_button('workflow.nodes.agent.outputVars.edit:{"name":"summary"}'));
      await t.pumpAndSettle();
      await _confirmName(t, 'report.summary');
      expect(find.text('workflow.nodes.agent.outputVars.nameInvalid'), findsOneWidget);
      expect(changes, isEmpty);
    });

    testWidgets('should reject reserved output name %s', (t) async {
      for (final name in ['text', 'switch', '_session']) {
        final changes = await _render(t, []);
        await _expand(t);
        await t.tap(_button('workflow.nodes.agent.outputVars.newOutput'));
        await t.pumpAndSettle();
        await _confirmName(t, name);
        expect(find.text('workflow.nodes.agent.outputVars.nameInvalid'), findsOneWidget, reason: name);
        expect(changes, isEmpty);
        await t.pumpWidget(const SizedBox());
      }
    });
  });

  group('agent output variables utils', () {
    test('should build a declared output from the editable draft', () {
      expect(
        createOutputFromDraft(
          _draft(defaultValue: '42', description: 'A numeric score', required: true, type: 'number'),
        ),
        {
          'name': 'summary',
          'type': 'number',
          'required': true,
          'description': 'A numeric score',
          'failure_strategy': {'on_failure': 'default_value', 'default_value': 42},
        },
      );
    });

    test('should validate default values against the declared output type', () {
      expect(
        getDefaultValueErrorKey(_draft(defaultValue: 'not-json', type: 'object')),
        'nodes.agent.outputVars.defaultValueObjectInvalid',
      );
      expect(
        getDefaultValueErrorKey(_draft(defaultValue: '{}', type: 'array[string]')),
        'nodes.agent.outputVars.defaultValueArrayInvalid',
      );
      expect(
        getDefaultValueErrorKey(_draft(defaultValue: 'yes', type: 'boolean')),
        'nodes.agent.outputVars.defaultValueBooleanInvalid',
      );
      expect(
        getDefaultValueErrorKey(_draft(defaultValue: '[]', type: 'array[file]')),
        'nodes.agent.outputVars.defaultValueFileUnsupported',
      );
    });

    test('should preserve object children when building an output', () {
      expect(
        createOutputFromDraft(
          _draft(
            name: 'profile',
            type: 'object',
            children: [
              {'name': 'email', 'type': 'string', 'required': true, 'description': 'User email'},
            ],
          ),
        ),
        allOf(
          containsPair('name', 'profile'),
          containsPair('type', 'object'),
          containsPair('children', [
            {'name': 'email', 'type': 'string', 'required': true, 'description': 'User email'},
          ]),
        ),
      );
    });

    test('should preserve array object item children when building an output', () {
      expect(
        createOutputFromDraft(
          _draft(
            name: 'addresses',
            type: 'array[object]',
            children: [
              {'name': 'city', 'type': 'string', 'required': false},
            ],
          ),
        ),
        allOf(
          containsPair('name', 'addresses'),
          containsPair('type', 'array'),
          containsPair('array_item', {
            'type': 'object',
            'children': [
              {'name': 'city', 'type': 'string', 'required': false},
            ],
          }),
        ),
      );
    });
  });
}
