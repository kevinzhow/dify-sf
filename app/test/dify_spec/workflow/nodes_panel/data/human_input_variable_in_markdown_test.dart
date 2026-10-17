// dify-spec: web/app/components/workflow/nodes/human-input/components/__tests__/variable-in-markdown.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/human_input/form_preview.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/human_input/human_input_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'human_input_test_kit.dart';

void main() {
  group('variable-in-markdown', () {
    group('rehypeVariable', () {
      test('should replace variable tokens with variable elements and preserve surrounding text', () {
        final tree = MdNode(children: [MdNode.text('Hello {{#node.field#}} world')]);
        rehypeVariable(tree);
        expect(
          [for (final c in tree.children) c.toJson()],
          [
            {'type': 'text', 'value': 'Hello '},
            {
              'type': 'element',
              'tagName': 'variable',
              'properties': {'dataPath': '{{#node.field#}}'},
              'children': <Object?>[],
            },
            {'type': 'text', 'value': ' world'},
          ],
        );
      });

      test('should ignore note tokens while processing variable nodes', () {
        final tree = MdNode(children: [MdNode.text('Hello {{#\$node.field#}} world')]);
        rehypeVariable(tree);
        expect(
          [for (final c in tree.children) c.toJson()],
          [
            {'type': 'text', 'value': 'Hello {{#\$node.field#}} world'},
          ],
        );
      });
    });

    group('rehypeNotes', () {
      test('should replace note tokens with section nodes and update the parent tag name', () {
        final tree = MdNode(tagName: 'p', children: [MdNode.text('See {{#\$node.title#}} please')]);
        rehypeNotes(tree);
        expect(tree.tagName, 'div');
        expect(
          [for (final c in tree.children) c.toJson()],
          [
            {'type': 'text', 'value': 'See '},
            {
              'type': 'element',
              'tagName': 'section',
              'properties': {'dataName': 'title'},
              'children': <Object?>[],
            },
            {'type': 'text', 'value': ' please'},
          ],
        );
      });
    });

    group('rendering', () {
      Future<void> note(WidgetTester t, Map<String, Object?> input, [String Function(String)? nodeName]) =>
          pumpComponent(t, FormInputNote(input: input, nodeName: nodeName ?? (id) => id));

      testWidgets('should format variable paths for display', (t) async {
        await pumpComponent(t, const VariablePath('{{#node.field#}}'));
        expect(find.text('{{node/field}}'), findsOneWidget);
      });

      testWidgets('should render note values and replace node ids with labels for variable defaults', (t) async {
        await note(t, {
          'type': 'paragraph',
          'output_variable_name': 'approval',
          'default': {
            'type': 'variable',
            'selector': ['node-1', 'output'],
            'value': '',
          },
        }, (id) => id == 'node-1' ? 'Start Node' : id);
        expect(find.text('{{Start Node/output}}'), findsOneWidget);

        await note(t, {
          'type': 'paragraph',
          'output_variable_name': 'approval',
          'default': {'type': 'constant', 'value': 'Plain value', 'selector': <Object?>[]},
        });
        expect(find.text('Plain value'), findsOneWidget);
      });

      Map<String, Object?> select(String type, List<String> selector, List<String> value) => {
        'type': 'select',
        'output_variable_name': 'approval',
        'option_source': {'type': type, 'selector': selector, 'value': value},
      };

      testWidgets('should render a select preview control for select inputs', (t) async {
        await note(t, select('constant', const [], const ['Approved', 'Rejected']));
        expect(find.byKey(const ValueKey('human-input-note-select-preview')), findsOneWidget);
        expect(find.text('Approved'), findsOneWidget);
      });

      testWidgets('should render dynamic select inputs as variable information without a select control', (t) async {
        await note(
          t,
          select('variable', const ['node-1', 'options'], const []),
          (id) => id == 'node-1' ? 'Start Node' : id,
        );
        expect(find.byKey(const ValueKey('human-input-note-select-preview')), findsNothing);
        expect(find.byType(DifySelect<String>), findsNothing);
        expect(find.text('{{Start Node/options}}'), findsOneWidget);
      });

      testWidgets('should open the select preview and show option items', (t) async {
        await note(t, select('constant', const [], const ['Approved', 'Rejected']));
        await t.tap(find.byType(DifySelect<String>));
        await t.pump(const Duration(milliseconds: 300));
        expect(find.text('Rejected'), findsOneWidget);
      });

      testWidgets('should render upload placeholders for file inputs', (t) async {
        await note(t, {
          'type': 'file',
          'output_variable_name': 'attachment',
          'allowed_file_extensions': ['.pdf'],
          'allowed_file_types': <Object?>[],
          'allowed_file_upload_methods': ['local_file', 'remote_url'],
        });
        expect(find.byKey(const ValueKey('human-input-note-file-preview')), findsOneWidget);
        expect(find.text('common.fileUploader.uploadFromComputer'), findsOneWidget);
        expect(find.text('common.fileUploader.pasteFileLink'), findsOneWidget);
      });
    });
  });
}
