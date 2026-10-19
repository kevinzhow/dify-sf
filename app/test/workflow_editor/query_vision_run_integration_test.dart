import 'dart:async';

import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/workflow/model_catalog.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/group_host.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/node_panel.dart';
import 'package:dify_sf_app/src/workflow_editor/run/mock_run_service.dart';
import 'package:dify_sf_app/src/workflow_editor/run/run_graph.dart';
import 'package:dify_sf_app/src/workflow_editor/run/run_scope.dart';
import 'package:dify_sf_app/src/workflow_editor/run/ui/before_run_form.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../dify_spec/workflow/node_panel/harness.dart';

class CaptureRun extends MockWorkflowRunService {
  CaptureRun(RunGraph graph) : super(graph: () => graph);
  Map<String, Object?>? submitted;
  Completer<Map<String, Object?>>? pending;
  @override
  Future<Map<String, Object?>> singleNodeRun(String nodeId, Map<String, Object?> body) async {
    submitted = body;
    return pending?.future ?? {'id': 'run', 'status': 'succeeded', 'outputs': <String, Object?>{}};
  }
}

void main() {
  setUp(useDifyTestTranslator);
  Future<({Harness h, CaptureRun service})> open(WidgetTester t, String type, {bool vision = true}) async {
    final start = node(
      'start',
      type: 'start',
      config: {
        'variables': Value.of([
          {'variable': 'query', 'label': 'Query', 'type': 'text-input'},
          {'variable': 'score', 'label': 'Score', 'type': 'number'},
          {'variable': 'photos', 'label': 'Photos', 'type': 'file-list'},
        ]),
      },
    );
    final target = node(
      'target',
      type: type,
      config: {
        type == 'parameter-extractor' ? 'query' : 'query_variable_selector': const VRef(OutputRef('start', 'query')),
        'model': Value.of({'provider': 'openai', 'name': 'vision-model', 'mode': 'chat'}),
        'instruction': const VString('Route {{#start.score#}}'),
        'vision': Value.of({
          'enabled': true,
          'configs': {
            'variable_selector': ['start', 'photos'],
          },
        }),
      },
    );
    final h = await Harness.start(
      t,
      [start, target],
      edges: [const Edge(id: 'edge', source: 'start', target: 'target')],
    );
    h.store.setWorkflowCanvasWidth(1200);
    final service = CaptureRun(EditorRunGraph(h.controller, h.canvas));
    await t.pumpWidget(
      panelApp(
        h,
        LlmGroupScope(
          services: LlmGroupServices(
            models: ModelCatalog(
              modelLists: {
                ModelTypeEnum.textGeneration: [
                  ProviderWithModels(
                    provider: 'openai',
                    models: [
                      ModelItem(model: 'vision-model', features: [if (vision) ModelFeatureEnum.vision]),
                    ],
                  ),
                ],
              },
            ),
          ),
          child: WorkflowRunHost(
            controller: h.controller,
            canvas: h.canvas,
            service: service,
            child: WorkflowNodePanel(
              node: target,
              actions: panelActions(h),
              bodies: NodePanelBodies({type: (_, _) => const Text('settings')}),
            ),
          ),
        ),
      ),
    );
    await settle(t);
    return (h: h, service: service);
  }

  for (final type in ['parameter-extractor', 'question-classifier']) {
    testWidgets('$type uses query/typed prompt/vision forms and submits their values through the run service', (
      t,
    ) async {
      final (:h, :service) = await open(t, type);
      await t.tap(buttonNamed('workflow.panel.runThisStep'));
      await settle(t);
      var form = t.widget<BeforeRunForm>(find.byType(BeforeRunForm));
      expect(form.forms, hasLength(2));
      expect(form.forms.first.inputs.map((v) => v['variable']), ['query', '#start.score#']);
      expect(form.forms.first.inputs.last['type'], InputVarType.number);
      expect(form.forms.last.inputs.single['variable'], '#files#');
      expect(form.forms.last.inputs.single['type'], InputVarType.multiFiles);
      // Both callbacks are created in one build; changing files must keep the query just entered.
      form.forms.first.onChange({'query': 'new query', '#start.score#': 42});
      form.forms.last.onChange({'#files#': <Object?>[]});
      await t.pump();
      form = t.widget<BeforeRunForm>(find.byType(BeforeRunForm));
      expect(form.forms.first.values['query'], 'new query');
      form.onRun({'query': 'new query', '#start.score#': 42, '#files#': <Object?>[]});
      await settle(t);
      expect(service.submitted, {
        'inputs': {'query': 'new query', '#start.score#': 42, '#files#': <Object?>[]},
      });
      expect(h.store.nodeRunDataOf('target')['_singleRunningStatus'], 'succeeded');
      await h.dispose(t);
    });
  }

  testWidgets('non-vision model omits the file form and existing query values are filtered by their selector', (
    t,
  ) async {
    final (:h, :service) = await open(t, 'question-classifier', vision: false);
    h.store.setNodesWithInspectVars([
      {
        'nodeId': 'start',
        'vars': [
          {'name': 'query'},
        ],
      },
    ]);
    await t.tap(buttonNamed('workflow.panel.runThisStep'));
    await settle(t);
    final form = t.widget<BeforeRunForm>(find.byType(BeforeRunForm));
    expect(form.forms, hasLength(1));
    expect(form.filteredExistVarForms.single.inputs.map((v) => v['variable']), ['#start.score#']);
    expect(service.submitted, isNull);
    await h.dispose(t);
  });

  testWidgets('opening the form after status removal pauses a pending run and drops its late response', (t) async {
    final (:h, :service) = await open(t, 'parameter-extractor');
    final c = WorkflowRunScope.of(t.element(find.byType(WorkflowNodePanel))).singleRunOf('target');
    service.pending = Completer<Map<String, Object?>>();
    final future = c.handleRun({'query': 'old'});
    await t.pump();
    h.store.setNodeRunData('target', {'_singleRunningStatus': null, '_isSingleRun': true});
    await t.pump();
    expect(find.byType(BeforeRunForm), findsOneWidget);
    expect(c.isPaused, isTrue);
    service.pending!.complete({
      'id': 'late',
      'status': 'succeeded',
      'outputs': {'answer': 'old'},
    });
    await future;
    await t.pump();
    expect(c.runResult, isNull);
    expect(h.store.nodeRunDataOf('target')['_singleRunningStatus'], isNull);
    c.setNodeRunning();
    expect(c.isPaused, isFalse);
    await h.dispose(t);
  });
}
