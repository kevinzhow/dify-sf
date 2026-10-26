import 'support/code_editor_input.dart';
import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/workflow_editor/dify_editor.dart';
import 'package:dify_sf_app/src/demo/demo_backend.dart';
import 'package:collab_client/testing.dart';
import 'package:dify_sf_app/src/editor/editor_controller.dart';
import 'package:dify_sf_app/src/editor/editor_page.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/node_panel.dart';
import 'package:dify_sf_app/src/workflow_editor/panel_fields/panel_fields.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/app_fonts.dart';

import 'package:meta/meta.dart' show isTest;

const _me = 'me-abc123';

/// Drives fake time forward in small steps so timers, streams and debounces run.
Future<void> settle(WidgetTester t, [Duration d = const Duration(seconds: 2)]) async {
  final step = d.inSeconds >= 5 ? 500 : 100;
  for (var i = 0; i < d.inMilliseconds ~/ step; i++) {
    await t.pump(Duration(milliseconds: step));
  }
}

DemoBackend? _current;

/// A widget test that closes the editor and lets leftover request timeouts expire before it ends (the test
/// binding fails on pending timers).
@isTest
void editorTest(String name, Future<void> Function(WidgetTester t) body) {
  testWidgets(name, (t) async {
    await body(t);
    await t.pumpWidget(const SizedBox());
    await _current?.dispose();
    await t.pump(const Duration(seconds: 20));
  });
}

Future<DemoBackend> openEditor(
  WidgetTester t, {
  bool journaled = true,
  bool withBo = true,
  Size size = const Size(1600, 900),
  String? clientId = _me,
}) async {
  await useAppFonts();
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final demo = DemoBackend(withBo: withBo);
  await t.pumpWidget(
    MaterialApp(
      theme: ThemeData(fontFamily: 'Noto Sans'),
      home: EditorPage(
        backend: demo,
        docId: 'demo',
        clientId: clientId,
        journaled: journaled,
        extraActions: demo.actions,
      ),
    ),
  );
  await settle(t);
  _current = demo;
  return demo;
}

EditorController _controller(WidgetTester t) =>
    t.widget<DifyWorkflowEditor>(find.byType(DifyWorkflowEditor)).controller;

/// The session details live in the header's session menu (opened when needed).
Future<void> openSession(WidgetTester t) async {
  if (find.byKey(const Key('link-state')).evaluate().isNotEmpty) return;
  await t.tap(find.byKey(const Key('session-menu')));
  await t.pump();
  await t.pump();
  await t.pump(const Duration(milliseconds: 300));
}

Future<String> text(WidgetTester t, String key) async {
  if (const ['link-state', 'pending-count', 'last-seq'].contains(key)) await openSession(t);
  return (t.widget(find.byKey(Key(key))) as DifyTextLine).data!;
}

/// Types a node's title in its panel and commits it (Dify's title input commits on blur; Enter blurs it).
Future<void> enterTitle(WidgetTester t, String nodeId, String title) async {
  await t.enterText(find.byKey(ValueKey('title-$nodeId')), title);
  await t.testTextInput.receiveAction(TextInputAction.done);
}

Future<void> select(WidgetTester t, String nodeId) async {
  await t.tap(find.byKey(ValueKey('node-$nodeId')), warnIfMissed: false);
  await settle(t, const Duration(milliseconds: 300));
}

/// The control whose accessible name is [label].
Finder _buttonNamed(String label) =>
    find.byWidgetPredicate((w) => w is DifyPressable && w.semanticLabel == label, description: 'button "$label"');

/// The text field of the Code panel's output variable named [name].
Finder _outputInput(String name) => find.descendant(
  of: find.descendant(
    of: find.byType(OutputVarList),
    matching: find.byWidgetPredicate((w) => w is DifyInput && w.value == name),
  ),
  matching: find.byType(EditableText),
);


void main() {
  editorTest('shows the document, the live status and the last seq', (t) async {
    final demo = await openEditor(t, withBo: false);
    for (final id in ['start', 'llm', 'code', 'answer']) {
      expect(find.byKey(ValueKey('node-$id')), findsOneWidget);
    }
    expect(await text(t, 'link-state'), 'Live');
    expect(await text(t, 'pending-count'), 'All edits saved');
    expect(await text(t, 'last-seq'), 'seq 0');
    expect(demo.server.head, 0);
  });

  editorTest('dragging a node sends position ops that converge on the server', (t) async {
    final demo = await openEditor(t, withBo: false);
    final before = demo.server.doc.nodes['llm']!;
    await t.drag(find.byKey(const ValueKey('node-llm')), const Offset(100, 60));
    await settle(t);
    final after = demo.server.doc.nodes['llm']!;
    expect(after.x, greaterThan(before.x + 50));
    expect(after.y, greaterThan(before.y + 30));
    final ops = demo.server.log.map((e) => e.op);
    expect(ops, isNotEmpty);
    expect(ops, everyElement(isA<MoveNode>()), reason: 'a drag is only small position ops');
    expect(await text(t, 'pending-count'), 'All edits saved');
  });

  editorTest('zoomed out, a drag still moves the node by the distance the pointer travelled', (t) async {
    final demo = await openEditor(t, withBo: false, size: const Size(1000, 700));
    final label = t.widget<Text>(find.textContaining('%'));
    final scale = int.parse(label.data!.replaceAll('%', '')) / 100;
    expect(scale, lessThan(1), reason: 'the graph is wider than the viewport, so it was fitted');
    // The first pixels of a drag are swallowed by the gesture slop, so compare two drags of different length.
    Future<int> dragBy(double dx) async {
      final before = demo.server.doc.nodes['llm']!.x;
      await t.drag(find.byKey(const ValueKey('node-llm')), Offset(dx, 0));
      await settle(t);
      return demo.server.doc.nodes['llm']!.x - before;
    }

    final short = await dragBy(100);
    final long = await dragBy(200);
    expect(long - short, closeTo(100 / scale, 10));
  });

  editorTest('dragging from an output handle to another node creates a connection; it can be deleted', (t) async {
    final demo = await openEditor(t, withBo: false);
    expect(demo.server.doc.edges.length, 3);
    final from = t.getCenter(find.byKey(const Key('out-start')));
    final to = t.getCenter(find.byKey(const ValueKey('node-answer')));
    final g = await t.startGesture(from);
    await g.moveTo(Offset.lerp(from, to, 0.5)!);
    await g.moveTo(to);
    await g.up();
    await settle(t);
    final added = demo.server.doc.edges.values.where((e) => e.source == 'start' && e.target == 'answer');
    expect(added, hasLength(1));
    expect(demo.server.log.last.op, isA<AddEdge>());

    // Select it by tapping the curve, then delete.
    final edge = added.single;
    expect(demo.server.doc.edges.containsKey(edge.id), isTrue);
    final c = Offset.lerp(
      t.getCenter(find.byKey(const Key('out-start'))),
      t.getCenter(find.byKey(const Key('in-answer'))),
      0.5,
    )!;
    await t.tapAt(Offset(c.dx, c.dy));
    await settle(t, const Duration(milliseconds: 300));
    // Dify has no edge panel: the edge shows as selected and the Delete key removes it.
    expect(_controller(t).selectedEdgeId, edge.id);
    expect(find.byType(WorkflowNodePanel), findsNothing);
    await t.sendKeyEvent(LogicalKeyboardKey.delete);
    await settle(t);
    expect(demo.server.doc.edges.length, 3);
    expect(demo.server.log.last.op, isA<RemoveEdge>());
  });

  editorTest('editing the title and a config field becomes small field ops', (t) async {
    final demo = await openEditor(t, withBo: false);
    await select(t, 'llm');
    await enterTitle(t, 'llm', 'Summarize');
    await settle(t, const Duration(seconds: 2));
    expect(demo.server.doc.nodes['llm']!.title, 'Summarize');

    // The Code panel's code editor: typed text is one field.
    await select(t, 'code');
    await enterCodeEditorText(t, 'Say hi');
    await settle(t, const Duration(seconds: 2));
    expect(demo.server.doc.nodes['code']!.config['code'], const VString('Say hi'));

    final ops = demo.server.log.map((e) => e.op).toList();
    expect(ops, hasLength(2));
    expect(ops, everyElement(isA<SetField>()));
    expect((ops.last as SetField).field, const ConfigKey(['code']), reason: 'one field, not the whole config');
  });

  editorTest('the keyed outputs list: add, edit and remove items by id', (t) async {
    final demo = await openEditor(t, withBo: false);
    await select(t, 'code');
    // The Code panel's output variables (OutputVarList): one row per item of the document's keyed list.
    expect(_outputInput('result'), findsOneWidget);
    final add = _buttonNamed(
      '${DifyI18n.tr('common', 'operation.add')} ${DifyI18n.tr('workflow', 'nodes.code.outputVars')}',
    );
    await t.ensureVisible(add);
    await t.tap(add);
    await settle(t);
    var outputs = demo.server.doc.nodes['code']!.config['outputs']! as VItems;
    expect(outputs.items, hasLength(2));
    expect(outputs.items.first.id, 'o-result', reason: 'the existing item keeps its id');
    final newId = outputs.items.last.id;
    expect(demo.server.log.last.op, isA<InsertItem>());

    await t.enterText(_outputInput('var_2'), 'summary');
    await settle(t, const Duration(seconds: 2));
    outputs = demo.server.doc.nodes['code']!.config['outputs']! as VItems;
    expect(outputs.items.map((i) => i.id), ['o-result', newId]);
    expect((outputs.items.last.value as VMap).entries['name'], const VString('summary'));
    expect(demo.server.log.last.op, isA<UpdateItem>());
    expect((demo.server.log.last.op as UpdateItem).itemId, newId);

    final remove = find.descendant(of: find.byType(OutputVarList), matching: find.byType(RemoveButton)).at(1);
    await t.ensureVisible(remove);
    await t.tap(remove);
    await settle(t);
    outputs = demo.server.doc.nodes['code']!.config['outputs']! as VItems;
    expect(outputs.items.map((i) => i.id), ['o-result']);
    expect(demo.server.log.last.op, isA<RemoveItem>());
    expect((demo.server.log.last.op as RemoveItem).itemId, newId);
  });

  editorTest('a new output shows up in the variable picker of other nodes', (t) async {
    final demo = await openEditor(t, withBo: false);
    // Someone adds an output to the code node.
    _controller(t).insertItem(
      'code',
      const ['outputs'],
      const VMap({'name': VString('summary'), 'type': VString('string')}),
      after: 'o-result',
    );
    await settle(t);
    await select(t, 'answer');
    // The Answer panel's prompt editor: "Insert variable" opens its variable picker.
    await t.tap(
      find.byWidgetPredicate(
        (w) => w is DifyIconButton && w.label == DifyI18n.tr('workflow', 'common.insertVarTip'),
      ),
    );
    await settle(t, const Duration(milliseconds: 400));
    // (The seed's start variable is `{name, type}`, not Dify's `{variable, type}`, so Dify's picker has no name for it.)
    for (final v in ['summary', 'result', 'text']) {
      expect(find.text(v), findsWidgets, reason: '$v is offered');
    }
    await t.tap(find.text('text').last);
    await settle(t);
    // Dify's answer is a template: the picked variable is written into it, as one field op.
    expect(demo.server.doc.nodes['answer']!.config['answer'], const VString('{{#llm.text#}}'));
    expect((demo.server.log.last.op as SetField).field, const ConfigKey(['answer']));
  });

  editorTest('deleting a node warns about references, then shows broken references explicitly', (t) async {
    final demo = await openEditor(t, withBo: false);
    await select(t, 'llm');
    // The node panel's "…" menu: Delete asks first, as the node's output is referenced.
    await t.tap(find.byKey(const Key('node-panel-more')));
    await settle(t, const Duration(milliseconds: 400));
    await t.tap(find.text(DifyI18n.tr('common', 'operation.delete')));
    await settle(t, const Duration(milliseconds: 400));
    expect(find.byKey(const Key('delete-dialog')), findsOneWidget);
    expect(find.textContaining('1 reference'), findsOneWidget);
    expect(find.textContaining('inputs'), findsWidgets);
    await t.tap(find.byKey(const Key('confirm-delete')));
    await settle(t);
    expect(demo.server.doc.nodes.containsKey('llm'), isFalse);
    expect(demo.server.doc.edges.length, 1, reason: 'edges of the deleted node are gone');

    // The code node now holds an explicit broken marker, visible on the card and in its panel.
    expect(find.byKey(const Key('broken-badge-code')), findsOneWidget);
    await select(t, 'code');
    expect(find.byKey(const Key('broken-summary')), findsOneWidget);
    expect(find.textContaining('1 broken reference'), findsOneWidget);
    expect(demo.server.doc.nodes['code']!.config['inputs'], const VBroken(OutputRef('llm', 'text')));
  });

  editorTest('offline edits are counted, then rejected with a clear conflict notice; re-apply works', (t) async {
    final demo = await openEditor(t);
    await select(t, 'llm');
    demo.setOffline(true);
    await settle(t, const Duration(seconds: 1));

    await select(t, 'code');
    await enterCodeEditorText(t, 'my code');
    await settle(t, const Duration(seconds: 2));
    expect(await text(t, 'pending-count'), '1 unsaved edit');

    demo.boSets('code', ['code'], 'bo code');
    await settle(t, const Duration(seconds: 1));
    expect(demo.server.doc.nodes['code']!.config['code'], const VString('bo code'));
    // 30 s without a byte: the watchdog notices the dead connection.
    await settle(t, const Duration(seconds: 35));
    expect(await text(t, 'link-state'), isNot('Live'));

    demo.setOffline(false);
    await t.tap(find.byKey(const Key('reconnect-now')));
    await settle(t, const Duration(seconds: 5));
    expect(await text(t, 'link-state'), 'Live');
    expect(await text(t, 'pending-count'), 'All edits saved');
    expect(find.byKey(const Key('notice-message')), findsOneWidget);
    expect(await text(t, 'notice-message'), startsWith('Bo changed code'));
    expect(await text(t, 'notice-message'), endsWith('your change wasn\'t applied'));
    // The winning value is what's on screen, not the lost draft.
    expect(codeEditorText(t), 'bo code');

    await t.tap(find.byKey(const Key('reapply')));
    await settle(t);
    expect(demo.server.doc.nodes['code']!.config['code'], const VString('my code'));
    expect(find.byKey(const Key('notice-message')), findsNothing);
  });

  editorTest('discarding a conflict notice keeps the other writer\'s value', (t) async {
    final demo = await openEditor(t);
    await select(t, 'llm');
    demo.setOffline(true);
    await settle(t, const Duration(seconds: 1));
    await enterTitle(t, 'llm', 'Mine');
    await settle(t, const Duration(seconds: 2));
    demo.bo!.edit(const SetField('llm', TitleKey(), VString('Bo title')));
    await settle(t, const Duration(seconds: 1));
    demo.setOffline(false);
    demo.net.cutStreams();
    await settle(t, const Duration(seconds: 60)); // no hint at all: the client finds its way back by itself
    expect(find.byKey(const Key('discard')), findsOneWidget);
    expect(await text(t, 'notice-message'), contains('title'));
    await t.tap(find.byKey(const Key('discard')));
    await settle(t);
    expect(find.byKey(const Key('notice-message')), findsNothing);
    expect(demo.server.doc.nodes['llm']!.title, 'Bo title');
  });

  editorTest('volatile mode: a crash with unsent edits says explicitly that they were lost', (t) async {
    final demo = await openEditor(t, journaled: false);
    await select(t, 'llm');
    demo.setOffline(true);
    await settle(t, const Duration(seconds: 1));
    await select(t, 'code');
    await enterCodeEditorText(t, 'unsaved work');
    await settle(t, const Duration(seconds: 2));
    expect(await text(t, 'pending-count'), '1 unsaved edit');

    await openSession(t);
    await t.tap(find.byKey(const Key('demo-menu')));
    await settle(t, const Duration(milliseconds: 400));
    await t.tap(find.text('Crash the app and restart'));
    await settle(t, const Duration(seconds: 1));
    demo.setOffline(false);
    await t.tap(find.byKey(const Key('reconnect-now')));
    await settle(t, const Duration(seconds: 5));
    expect(find.byKey(const Key('notice-message')), findsOneWidget);
    expect(await text(t, 'notice-message'), contains('1 edit was lost'));
    expect(
      demo.server.doc.nodes['code']!.config['code'],
      const VString("def main(text):\n    return {'result': text.strip()}"),
    );
    expect(await text(t, 'pending-count'), 'All edits saved');
  });

  editorTest('a second window with the same client id: this one switches ids and re-sends, and says so', (t) async {
    final demo = await openEditor(t, withBo: false, clientId: null);
    final c = _controller(t);
    final sharedId = c.session.clientId;
    expect(sharedId, startsWith('s-'));
    await select(t, 'llm');
    demo.setOffline(true);
    await settle(t, const Duration(seconds: 1));
    await enterTitle(t, 'llm', 'Mine');
    await settle(t, const Duration(seconds: 2));
    expect(await text(t, 'pending-count'), '1 unsaved edit');

    // The "other window": same id, different edit, committed first (cseq 1).
    final twin = CollabSession(clientId: sharedId, transport: FakeTransport(demo.server), store: MemoryStore());
    await twin.start();
    await settle(t, const Duration(seconds: 1));
    twin.edit(const SetField('code', TitleKey(), VString('Twin')));
    await settle(t, const Duration(seconds: 1));
    expect(demo.server.log.single.client, sharedId);

    demo.setOffline(false);
    await t.tap(find.byKey(const Key('reconnect-now')));
    await settle(t, const Duration(seconds: 6));
    expect(c.session.clientId, isNot(sharedId));
    expect(demo.server.doc.nodes['llm']!.title, 'Mine', reason: 'the edit was re-sent under the new id');
    expect(demo.server.doc.nodes['code']!.title, 'Twin');
    expect(await text(t, 'notice-message'), contains('Another window was using this session'));
    expect(await text(t, 'notice-message'), contains('1 unsaved edit'));
    expect(await text(t, 'pending-count'), 'All edits saved');
    await twin.stop();
  });

  editorTest('journaled mode: the same crash loses nothing and the edit is sent after restart', (t) async {
    final demo = await openEditor(t);
    await select(t, 'llm');
    demo.setOffline(true);
    await settle(t, const Duration(seconds: 1));
    await select(t, 'code');
    await enterCodeEditorText(t, 'kept work');
    await settle(t, const Duration(seconds: 2));
    expect(await text(t, 'pending-count'), '1 unsaved edit');

    await openSession(t);
    await t.tap(find.byKey(const Key('demo-menu')));
    await settle(t, const Duration(milliseconds: 400));
    await t.tap(find.text('Crash the app and restart'));
    await settle(t, const Duration(seconds: 1));
    expect(find.textContaining('Recovered 1 unsent edit'), findsOneWidget);
    demo.setOffline(false);
    await t.tap(find.byKey(const Key('reconnect-now')));
    await settle(t, const Duration(seconds: 5));
    expect(demo.server.doc.nodes['code']!.config['code'], const VString('kept work'));
    expect(await text(t, 'pending-count'), 'All edits saved');
  });
}
