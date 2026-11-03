// The HTTP Request node's header / param KEY and VALUE cells on a phone (emulator recheck 4 of PR #90): tapping a cell
// opens the keyboard (the text input connection) and what is typed lands in the cell; "/" opens the variable picker
// while the keyboard stays with the cell (the typed picker follows what is typed), and the pick lands in the cell.
// At 411x914 in the real editor (the node settings sheet).
import 'package:collab_client/collab_client.dart' show Document, Edge, Node;
import 'package:dify_sf_app/src/demo/demo_backend.dart';
import 'package:dify_sf_app/src/design/dify_theme.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/editor/editor_controller.dart';
import 'package:dify_sf_app/src/editor/editor_page.dart';
import 'package:dify_sf_app/src/editor/undo_manager.dart' show HistoryEvent;
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/workflow_editor/context_menu/clipboard.dart' show nodeFromDify;
import 'package:dify_sf_app/src/workflow_editor/dify_editor.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/http/key_value.dart';
import 'package:dify_sf_app/src/workflow_editor/prompt_editor/prompt_editor.dart';
import 'package:dify_sf_app/src/workflow_editor/steps/workflow_steps_view.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/app_fonts.dart';
import 'phone_harness.dart';

Future<(EditorController, DemoBackend)> _editor(WidgetTester t) async {
  phoneWindow(t);
  final demo = DemoBackend(withBo: false);
  await t.pumpWidget(
    DifyApplication(
      theme: difyTheme(),
      edgeToEdge: true,
      home: EditorPage(backend: demo, docId: 'demo', clientId: 'phone-http', journaled: false),
    ),
  );
  await settle(t, 2000);
  final c = t.widget<DifyWorkflowEditor>(find.byType(DifyWorkflowEditor)).controller;
  final nodes = <Node>[];
  void add(String id, String type, String title, Map<String, Object?> data) => nodes.add(
    nodeFromDify(
      {
        'id': id,
        'position': {'x': nodes.length * 300, 'y': 0},
        'data': {'type': type, 'title': title, ...data},
      },
      Document(nodes: nodes),
      id: id,
    ),
  );
  add('n-start', 'start', 'Start', {
    'variables': [
      {'variable': 'query', 'label': 'Query', 'type': 'text-input', 'required': true},
    ],
  });
  add('n-http', 'http-request', 'HTTP Request', {
    'variables': <Object?>[],
    'method': 'get',
    'url': '',
    'authorization': {'type': 'no-auth', 'config': null},
    'headers': '',
    'params': '',
    'body': {'type': 'none', 'data': <Object?>[]},
    'timeout': {'connect': 5, 'read': 10, 'write': 15},
    'ssl_verify': true,
  });
  c.applyGraphChange(
    event: HistoryEvent.nodeAdd,
    removeNodes: [...c.doc.nodes.keys],
    addNodes: nodes,
    addEdges: [Edge(id: 'e-0', source: 'n-start', target: 'n-http')],
  );
  c.selectNode(null);
  await settle(t, 800);
  return (c, demo);
}

void main() {
  setUpAll(() async {
    await DifyI18n.load('en-US');
    await useAppFonts();
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('HTTP Request KEY and VALUE cells on a phone: a tap opens the keyboard and typing lands; "/" opens the '
      'variable picker with the keyboard still on the cell, and a pick lands in it', (t) async {
    final (c, demo) = await _editor(t);
    await t.tap(find.descendant(of: find.byType(WorkflowStepsView), matching: find.text('HTTP Request')).first);
    await settle(t, 800);
    final headers = find.byType(KeyValueLines).first;
    Finder cell(int i) => find.descendant(of: headers, matching: find.byType(EditableText)).at(i);
    for (final (i, text) in [(0, 'x-token'), (1, 'abc')]) {
      await t.ensureVisible(cell(i));
      await settle(t, 300);
      await t.tap(cell(i));
      await settle(t, 600);
      expect(t.testTextInput.hasAnyClients, isTrue, reason: 'cell $i: the text input connection is open');
      expect(t.testTextInput.isVisible, isTrue, reason: 'cell $i: the keyboard is up');
      expect(t.widget<EditableText>(cell(i)).focusNode.hasFocus, isTrue, reason: 'cell $i has the focus');
      t.testTextInput.enterText(text);
      await settle(t, 300);
      expect(t.widget<EditableText>(cell(i)).controller.text, text, reason: 'cell $i: the typing landed');
    }
    // "/" typed into an empty cell (the params' KEY): the typed picker opens and the keyboard stays with the cell.
    final params = find.byType(KeyValueLines).at(1);
    final key = find.descendant(of: params, matching: find.byType(EditableText)).first;
    await t.ensureVisible(key);
    await settle(t, 300);
    await t.tap(key);
    await settle(t, 600);
    expect(t.testTextInput.isVisible, isTrue);
    t.testTextInput.updateEditingValue(
      const TextEditingValue(text: '/', selection: TextSelection.collapsed(offset: 1)),
    );
    await settle(t, 800);
    final sheet = find.byKey(const Key('prompt-editor-picker-sheet'));
    expect(sheet, findsOneWidget, reason: 'the variable picker');
    expect(t.testTextInput.isVisible, isTrue, reason: 'the keyboard stays up for the query');
    expect(t.widget<EditableText>(key).focusNode.hasFocus, isTrue, reason: 'the cell keeps the focus');
    await t.tap(find.descendant(of: sheet, matching: find.text('query')).first);
    await settle(t, 800);
    expect(sheet, findsNothing);
    final picked = t.state<DifyPromptEditorState>(
      find.ancestor(of: key, matching: find.byType(DifyPromptEditor)).first,
    );
    expect(picked.controller.prompt, '{{#n-start.query#}}', reason: 'the pick landed in the cell');
    expect(t.takeException(), isNull);
    await unmount(t);
    await demo.dispose();
    await t.pump(const Duration(seconds: 20));
    expect(c.doc.nodes.containsKey('n-http'), isTrue);
  });
}
