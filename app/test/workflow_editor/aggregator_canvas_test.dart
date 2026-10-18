// dify-spec: web/app/components/workflow/hooks/__tests__/use-nodes-interactions.spec.ts
import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/workflow_editor/panel_fields/panel_fields.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../dify_spec/workflow/hooks/editor_harness.dart';
import '../support/app_fonts.dart';

import 'package:dify_sf_app/src/i18n/dify_i18n.dart';

List<Node> nodes({bool grouped = false}) => [
  node(
    'source',
    x: 50,
    y: 100,
    config: {
      'outputs': const VMap({
        'result': VMap({'type': VString('string'), 'children': VNull()}),
      }),
    },
  ),
  node(
    'agg',
    type: 'variable-aggregator',
    x: 500,
    y: 100,
    config: {
      'output_type': const VString('any'),
      'variables': const VList([]),
      if (grouped)
        'advanced_settings': const VMap({
          'group_enabled': VBool(true),
          'groups': VList([
            VMap({
              'groupId': VString('g1'),
              'group_name': VString('First'),
              'output_type': VString('any'),
              'variables': VList([]),
            }),
            VMap({
              'groupId': VString('g2'),
              'group_name': VString('Second'),
              'output_type': VString('any'),
              'variables': VList([]),
            }),
          ]),
        }),
    },
  ),
];

void main() {
  setUp(() async {
    await useAppFonts();
    await DifyI18n.load('en-US');
  });
  group('useNodesInteractions', () {
    testWidgets('updates entering states on node enter and clears them on leave using collaborative workflow state', (
      t,
    ) async {
      final h = await EditorHarness.start(t, nodes());
      final g = await t.startGesture(h.outPort('source'), kind: PointerDeviceKind.mouse);
      await g.moveTo(h.nodeCenter('agg'));
      await t.pump();
      expect(h.store.enteringNodePayload.value?.nodeId, 'agg');
      expect(find.byKey(const ValueKey('aggregator-entering-agg-target')), findsOneWidget);
      await g.moveTo(const Offset(1000, 600));
      await t.pump();
      expect(h.store.enteringNodePayload.value, isNull);
      expect(find.byKey(const ValueKey('aggregator-entering-agg-target')), findsNothing);
      await g.up();
      expect(h.store.connectingNodePayload.value, isNull);
      await h.dispose(t);
    });
  });

  testWidgets('dropping a connection offers the source variables, selects one and closes the popup', (t) async {
    final h = await EditorHarness.start(t, nodes());
    await h.drag(t, h.outPort('source'), h.nodeCenter('agg'));
    await EditorHarness.settle(t);
    expect(h.doc.edges.values.where((e) => e.source == 'source' && e.target == 'agg'), hasLength(1));
    expect(find.byType(VarReferencePopup), findsOneWidget);
    await t.tap(find.text('result').last);
    await EditorHarness.settle(t);
    expect(h.store.showAssignVariablePopup.value, isNull);
    expect(find.byType(VarReferencePopup), findsNothing);
    expect(h.doc.nodes['agg']!.config['output_type'], const VString('string'));
    final vars = h.doc.nodes['agg']!.config['variables'];
    expect(vars, isNot(const VList([])));
    expect(h.doc.nodes['agg']!.config.keys.where((k) => k.startsWith('_') && k != '_dify_node'), isEmpty);
    await h.dispose(t);
  });

  testWidgets('group drag selects the hovered group; the plus picker reuses the upstream scope', (t) async {
    final h = await EditorHarness.start(t, nodes(grouped: true));
    final target = h.canvas.graph!['agg']!;
    final second = h.screen(Offset(target.rect.center.dx, target.rect.top + 45 + 60));
    await h.drag(t, h.outPort('source'), second);
    await EditorHarness.settle(t);
    expect(h.store.showAssignVariablePopup.value?.variableAssignerNodeHandleId, 'g2');
    await t.tap(find.text('result').last);
    await EditorHarness.settle(t);
    final adv = h.doc.nodes['agg']!.config['advanced_settings'];
    expect(adv, isNotNull);
    await t.tap(find.byKey(const ValueKey('aggregator-add-agg-g1')));
    await EditorHarness.settle(t);
    expect(find.byType(VarReferencePopup), findsOneWidget);
    await t.tap(find.text('result').last);
    await EditorHarness.settle(t);
    expect(find.byType(VarReferencePopup), findsNothing);
    await h.dispose(t);
  });
}
