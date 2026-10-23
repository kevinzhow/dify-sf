import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../dify_test_i18n.dart';
import '../header/harness.dart' as header;

export '../../dify_test_i18n.dart';

/// Dify's test i18n with the run specs' mocked partial-success tip (its `<tracingLink>` marks the link).
class RunTestTranslator extends DifyTestTranslator {
  @override
  String t(String ns, String key, [Map<String, Object?> params = const {}]) {
    if (ns == 'workflow' && key == 'nodes.common.errorHandle.partialSucceeded.tip') {
      return 'There are ${params['num']} nodes in the process running abnormally, please go to '
          '<tracingLink>TRACING</tracingLink> to check the logs.';
    }
    return super.t(ns, key, params);
  }
}

/// [w] in a workflow store, [size] (bounded) so panels with flexible parts lay out.
Future<WorkflowStore> renderRun(
  WidgetTester t,
  Widget w, {
  void Function(WorkflowStore store)? initialStoreState,
  Size size = const Size(420, 900),
}) async {
  DifyI18n.current = RunTestTranslator();
  return header.renderWorkflowComponent(
    t,
    SizedBox(width: size.width, height: size.height, child: w),
    initialStoreState: initialStoreState,
    testTranslator: false,
  );
}

/// A NodeTracing as Dify's specs build them.
Map<String, Object?> createNodeTracing([Map<String, Object?> overrides = const {}]) => {
  'id': 'trace-1',
  'index': 0,
  'predecessor_node_id': '',
  'node_id': 'node-1',
  'node_type': 'code',
  'title': 'Node 1',
  'inputs': <String, Object?>{},
  'inputs_truncated': false,
  'process_data': <String, Object?>{},
  'process_data_truncated': false,
  'outputs_truncated': false,
  'status': 'succeeded',
  'elapsed_time': 0,
  'execution_metadata': {'total_tokens': 0, 'total_price': 0, 'currency': 'USD'},
  'metadata': {'iterator_length': 0, 'iterator_index': 0, 'loop_length': 0, 'loop_index': 0},
  'created_at': 0,
  'created_by': {'id': 'user-1', 'name': 'Alice', 'email': 'alice@example.com'},
  'finished_at': 0,
  ...overrides,
};

Map<String, Object?> executionMetadata([Map<String, Object?> overrides = const {}]) => {
  'total_tokens': 0,
  'total_price': 0,
  'currency': 'USD',
  ...overrides,
};

/// Moves a mouse over [finder] (Dify's hover-only controls).
Future<void> hover(WidgetTester t, Finder finder) async {
  final g = await t.createGesture(kind: PointerDeviceKind.mouse);
  addTearDown(g.removePointer);
  await g.addPointer(location: Offset.zero);
  await g.moveTo(t.getCenter(finder));
  await t.pump();
}

/// The text of [finder]'s widget and its descendants' texts, joined (DOM `textContent`).
String textContent(WidgetTester t, Finder finder) => [
  for (final w in t.widgetList<RichText>(find.descendant(of: finder, matching: find.byType(RichText))))
    w.text.toPlainText(),
].join(' ');

void useRunTranslator() => DifyI18n.current = RunTestTranslator();

/// Taps the [span] inside a rich text (Dify's inline links).
Future<void> tapSpan(WidgetTester t, String span) async {
  final box = t.renderObject<RenderParagraph>(
    find.byWidgetPredicate((w) => w is RichText && w.text.toPlainText().contains(span)).first,
  );
  final text = box.text.toPlainText();
  final i = text.indexOf(span);
  final rect = box.getBoxesForSelection(TextSelection(baseOffset: i, extentOffset: i + span.length)).first.toRect();
  await t.tapAt(box.localToGlobal(rect.center));
}
