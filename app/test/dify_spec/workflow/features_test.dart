// dify-spec: web/app/components/workflow/__tests__/features.spec.tsx
//
// Dify's Features saves the panel's features with `updateFeatures` and tells the other clients; here a change is
// written to the document (`$app` config `features`), so the "sync" case checks that write.
import 'package:dify_sf_app/src/workflow/dify_json.dart';
import 'package:dify_sf_app/src/workflow_editor/features/features.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'panel/harness.dart';

import 'package:dify_sf_app/src/design/widgets/widgets.dart';

final startNode = difyNode('start-node', 'start', {
  'variables': [
    {'variable': 'existing_variable', 'label': 'Existing Variable'},
  ],
});

Future<VarHarness> renderFeatures(WidgetTester t, {bool showFeaturesPanel = true}) async {
  final h = await VarHarness.start(t, nodes: [startNode]);
  h.store.setShowFeaturesPanel(showFeaturesPanel);
  t.view.physicalSize = const Size(1600, 1000);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      home: Material(
        child: WorkflowStoreScope(
          store: h.store,
          child: WorkflowFeatures(controller: h.controller, isChatMode: true),
        ),
      ),
    ),
  );
  await t.pump(const Duration(milliseconds: 300));
  return h;
}

NewFeaturePanel panel(WidgetTester t) => t.widget<NewFeaturePanel>(find.byType(NewFeaturePanel));

List<Object?> startVariables(VarHarness h) => difyDataOf(h.doc.nodes['start-node']!)['variables']! as List<Object?>;

void main() {
  setUp(useDifyTestTranslator);

  group('Features', () {
    group('Rendering', () {
      testWidgets('should pass workflow context to the feature panel', (t) async {
        final h = await renderFeatures(t);
        expect(panel(t).isChatMode, isTrue);
        expect(panel(t).disabled, isFalse);
        expect(
          [for (final v in panel(t).workflowVariables) '${v['label']}:${v['variable']}'],
          [
            'Existing Variable:existing_variable',
          ],
        );
        await h.dispose(t);
      });
    });

    group('User Interactions', () {
      testWidgets('should sync the draft and open the workflow feature panel when users change features', (t) async {
        final h = await renderFeatures(t);
        final citation = find.ancestor(
          of: find.textContaining('feature.citation.title'),
          matching: find.byType(FeatureCard),
        );
        await t.tap(find.descendant(of: citation, matching: find.byType(DifySwitch)));
        await t.pump();
        expect(h.controller.appOps, hasLength(1));
        // The document had no `retriever_resource` yet: the feature's map is written (only that feature).
        expect(h.controller.appOps.single.path, ['features', 'retriever_resource']);
        expect(h.controller.appOps.single.value, {'enabled': true});
        expect(h.store.showFeaturesPanel.value, isTrue);
        await h.dispose(t);
      });

      testWidgets('should close the workflow feature panel and transform required prompt variables', (t) async {
        final h = await renderFeatures(t);
        final p = panel(t);
        p.onAutoAddPromptVariable!([
          {
            'key': 'opening_statement',
            'name': 'Opening Statement',
            'type': 'string',
            'max_length': 200,
            'required': true,
          },
        ]);
        p.onClose();
        await t.pump();
        expect(h.store.showFeaturesPanel.value, isFalse);
        expect(startVariables(h).last, {
          'variable': 'opening_statement',
          'label': 'Opening Statement',
          'type': 'text-input',
          'max_length': 200,
          'required': true,
          'options': <Object?>[],
        });
        await h.dispose(t);
      });

      testWidgets('should default prompt variables to optional when required is omitted', (t) async {
        final h = await renderFeatures(t);
        panel(t).onAutoAddPromptVariable!([
          {'key': 'optional_statement', 'name': 'Optional Statement', 'type': 'string', 'max_length': 120},
        ]);
        await t.pump();
        expect(startVariables(h).last, {
          'variable': 'optional_statement',
          'label': 'Optional Statement',
          'type': 'text-input',
          'max_length': 120,
          'required': false,
          'options': <Object?>[],
        });
        await h.dispose(t);
      });
    });
  });
}
