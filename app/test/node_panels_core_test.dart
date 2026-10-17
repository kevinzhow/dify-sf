import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/editor/config_editor.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/core/core_bodies.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/core/core_kit.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/node_panel.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/panel_edit.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'dify_spec/workflow/nodes_panel/core/harness.dart';

final _nodes = difyNodes([
  difyNode('start', 'start', {
    'variables': [
      {'variable': 'query', 'label': 'Query', 'type': 'text-input', 'required': true},
    ],
  }, 'Start'),
  difyNode('code', 'code', {
    'code_language': 'python3',
    'code': 'def main(arg1):\n    return {"result": arg1}\n',
    'variables': [
      {
        'variable': 'arg1',
        'value_selector': ['start', 'query'],
      },
      {'variable': 'arg2', 'value_selector': <Object?>[]},
    ],
    'outputs': {
      'result': {'type': 'string', 'children': null},
    },
  }, 'Code'),
  difyNode('end', 'end', {
    'outputs': [
      {
        'variable': 'out',
        'value_selector': ['code', 'result'],
      },
      {
        'variable': 'q',
        'value_selector': ['start', 'query'],
      },
    ],
  }, 'End'),
]);

final _edges = chain(['start', 'code', 'end']);

PanelInputs _crud(Harness h, String id) =>
    PanelInputs(NodePanelProps(node: h[id]!, controller: h.controller, actions: panelActions(h)));

List<String> _ids(Harness h, String id, String key) => [for (final i in (h[id]!.config[key]! as VItems).items) i.id];

void main() {
  setUp(useDifyTestTranslator);

  group('PanelInputs.setInputs', () {
    testWidgets('edits keyed lists item by item and keeps references', (t) async {
      final h = await Harness.start(t, _nodes, edges: _edges);
      final crud = _crud(h, 'code');
      final before = _ids(h, 'code', 'variables');
      final vars = [...crud.inputs['variables']! as List];

      // Update one item: the other keeps its id and its reference.
      crud.setInputs({
        ...crud.inputs,
        'variables': [
          vars[0],
          {...vars[1]! as Map, 'variable': 'b'},
        ],
      });
      expect(_ids(h, 'code', 'variables'), before);
      expect((h['code']!.config['variables']! as VItems).items.first.value.toString(), contains('{{start.query}}'));

      // Insert in the middle, then remove it.
      crud.setInputs({
        ...crud.inputs,
        'variables': [
          vars[0],
          {
            'variable': 'mid',
            'value_selector': ['start', 'query'],
          },
          {...vars[1]! as Map, 'variable': 'b'},
        ],
      });
      final three = _ids(h, 'code', 'variables');
      expect([three.first, three.last], before);
      expect((h['code']!.config['variables']! as VItems).items[1].value.toString(), contains('{{start.query}}'));
      crud.setInputs({
        ...crud.inputs,
        'variables': [
          vars[0],
          {...vars[1]! as Map, 'variable': 'b'},
        ],
      });
      expect(_ids(h, 'code', 'variables'), before);

      // A reorder keeps the longest run in order and moves the other item (taken out, put back as a new item: the
      // protocol has no move), so concurrent edits of the items that stay merge.
      final now = [...crud.inputs['variables']! as List];
      crud.setInputs({
        ...crud.inputs,
        'variables': [now[1], now[0]],
      });
      final moved = _ids(h, 'code', 'variables');
      expect(moved.first, before.last);
      expect(moved.last, isNot(before.first));
      expect(crud.inputs['variables'], [now[1], now[0]]);
      await h.dispose(t);
    });

    testWidgets('writes a changed member of a map at its own path', (t) async {
      final h = await Harness.start(
        t,
        difyNodes([
          difyNode('agg', 'variable-aggregator', {
            'output_type': 'string',
            'variables': <Object?>[],
            'advanced_settings': {'group_enabled': false, 'groups': <Object?>[]},
          }),
        ]),
      );
      List<Op> sent() => [for (final p in h.controller.session.pending) ?p.op];
      final before = sent().length;
      final crud = _crud(h, 'agg');
      final settings = crud.inputs['advanced_settings']! as Map;
      crud.setInputs({
        ...crud.inputs,
        'advanced_settings': {...settings, 'group_enabled': true},
      });
      final ops = sent().sublist(before);
      expect(ops, hasLength(1));
      expect((ops.single as SetField).field, const ConfigKey(['advanced_settings', 'group_enabled']));
      expect(difyDataOf(h['agg']!)['advanced_settings'], {'group_enabled': true, 'groups': <Object?>[]});
      // A map losing a member is written whole.
      crud.setInputs({
        ...crud.inputs,
        'advanced_settings': {'group_enabled': true},
      });
      expect((sent().last as SetField).field, const ConfigKey(['advanced_settings']));
      expect(difyDataOf(h['agg']!)['advanced_settings'], {'group_enabled': true});
      await h.dispose(t);
    });

    testWidgets('creates keyed lists, writes nothing while read-only', (t) async {
      final h = await Harness.start(
        t,
        difyNodes([
          difyNode('answer', 'answer', {'answer': ''}),
        ]),
      );
      final crud = _crud(h, 'answer');
      crud.setInputs({
        ...crud.inputs,
        'variables': [
          {'variable': 'a', 'value_selector': <Object?>[]},
        ],
      });
      expect(h['answer']!.config['variables'], isA<VItems>());
      h.store.canvasReadOnly.value = true;
      _crud(h, 'answer').setInputs({...crud.inputs, 'answer': 'x'});
      expect(difyDataOf(h['answer']!)['answer'], '');
      await h.dispose(t);
    });
  });

  group('variable usage', () {
    testWidgets('finds, renames and clears the downstream uses of a variable', (t) async {
      final h = await Harness.start(t, _nodes, edges: _edges);
      final c = h.controller;
      expect(isVarUsedInNodes(c, ['start', 'query']), true);
      expect(isVarUsedInNodes(c, ['end', 'out']), false);
      handleOutVarRenameChange(c, ['start', 'query'], ['start', 'question']);
      expect(
        (difyDataOf(h['code']!)['variables']! as List).first,
        containsPair('value_selector', ['start', 'question']),
      );
      expect((difyDataOf(h['end']!)['outputs']! as List).last, containsPair('value_selector', ['start', 'question']));
      removeUsedVarInNodes(c, ['start', 'question']);
      expect((difyDataOf(h['end']!)['outputs']! as List).last, containsPair('value_selector', <Object?>[]));
      await h.dispose(t);
    });
  });

  group('core bodies in the node panel', () {
    final all = difyNodes([
      ..._raw,
      difyNode('answer', 'answer', {'variables': <Object?>[], 'answer': 'Hi {{#start.query#}}'}, 'Answer'),
      difyNode('if', 'if-else', {
        'cases': [
          {'case_id': 'true', 'logical_operator': 'and', 'conditions': <Object?>[]},
        ],
      }, 'IF/ELSE'),
      difyNode('tpl', 'template-transform', {
        'template': '{{ arg1 }}',
        'variables': [
          {
            'variable': 'arg1',
            'value_selector': ['start', 'query'],
          },
        ],
      }, 'Template'),
      difyNode('agg', 'variable-aggregator', {'output_type': 'any', 'variables': <Object?>[]}, 'Aggregator'),
      difyNode('legacy', 'variable-assigner', {'output_type': 'any', 'variables': <Object?>[]}, 'Legacy'),
      difyNode('assign', 'assigner', {'version': '2', 'items': <Object?>[]}, 'Assigner'),
    ]);
    for (final n in all) {
      testWidgets('${n.type} renders its body in the shell', (t) async {
        final h = await Harness.start(t, all, edges: chain([for (final n in all) n.id]));
        t.view.physicalSize = const Size(1200, 1200);
        await t.pumpWidget(
          panelApp(
            h,
            WorkflowNodePanel(
              node: h[n.id]!,
              actions: panelActions(h),
              bodies: const NodePanelBodies(corePanelBodies),
            ),
          ),
        );
        await settle(t);
        expect(t.takeException(), isNull);
        expect(find.byType(ConfigEditor), findsNothing);
        await h.dispose(t);
      });
    }
  });
}

final _raw = [
  difyNode('start', 'start', {
    'variables': [
      {'variable': 'query', 'label': 'Query', 'type': 'text-input', 'required': true},
    ],
  }, 'Start'),
  difyNode('code', 'code', {
    'code_language': 'python3',
    'code': 'def main(arg1):\n    return {"result": arg1}\n',
    'variables': [
      {
        'variable': 'arg1',
        'value_selector': ['start', 'query'],
      },
    ],
    'outputs': {
      'result': {'type': 'string', 'children': null},
    },
  }, 'Code'),
  difyNode('end', 'end', {
    'outputs': [
      {
        'variable': 'out',
        'value_selector': ['code', 'result'],
      },
    ],
  }, 'End'),
];
