// The prompt editor's typed variable picker on a phone (fixes after PR #90, item 2): "/" opens "Insert variable",
// and what is typed after it ("/te") filters the variables as Dify's `/` menu does (VarReferenceVars' searchText,
// the text after the trigger up to the caret), with the keyboard's composing word too. A pick replaces the trigger
// and the query at the caret (PR #89); Escape closes the picker and leaves the text; a space does not close it (Dify's
// trigger match runs to the end of the line); "{" leaves the variables to their own search box, as Dify's does. In the LLM prompt and the HTTP Request KEY cell, at 411x914 and
// 360x780.
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
import 'package:dify_sf_app/src/workflow_editor/panel_fields/var_reference_vars.dart';
import 'package:dify_sf_app/src/workflow_editor/prompt_editor/prompt_editor.dart';
import 'package:dify_sf_app/src/workflow_editor/steps/workflow_steps_view.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/app_fonts.dart';
import 'phone_harness.dart';

Future<(EditorController, DemoBackend)> _editor(WidgetTester t, Size size) async {
  phoneWindow(t, size: size);
  final demo = DemoBackend(withBo: false);
  await t.pumpWidget(
    DifyApplication(
      theme: difyTheme(),
      edgeToEdge: true,
      home: EditorPage(backend: demo, docId: 'demo', clientId: 'phone-filter', journaled: false),
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
      {'variable': 'temperature', 'label': 'Temperature', 'type': 'text-input', 'required': false},
      {'variable': 'text', 'label': 'Text', 'type': 'paragraph', 'required': false},
    ],
  });
  add('n-llm', 'llm', 'Answer', {
    'model': {'provider': 'openai', 'name': 'gpt-4o', 'mode': 'chat', 'completion_params': <String, Object?>{}},
    'prompt_template': [
      {'role': 'system', 'text': 'Hello'},
    ],
    'context': {'enabled': false, 'variable_selector': <Object?>[]},
    'vision': {'enabled': false},
  });
  add('n-http', 'http-request', 'Fetch', {
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
    addEdges: [
      Edge(id: 'e-0', source: 'n-start', target: 'n-llm'),
      Edge(id: 'e-1', source: 'n-llm', target: 'n-http'),
    ],
  );
  c.selectNode(null);
  await settle(t, 800);
  return (c, demo);
}

final _sheet = find.byKey(const Key('prompt-editor-picker-sheet'));

/// The variable names the picker lists.
List<String> _listed(WidgetTester t) => [
  for (final e in find.descendant(of: _sheet, matching: find.byType(VarReferenceItem)).evaluate())
    (e.widget as VarReferenceItem).item.variable,
];

void _type(WidgetTester t, String text) => t.testTextInput.updateEditingValue(
  TextEditingValue(
    text: text,
    selection: TextSelection.collapsed(offset: text.length),
  ),
);

void main() {
  setUpAll(() async {
    await DifyI18n.load('en-US');
    await useAppFonts();
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final size in phoneSizes) {
    final at = '${size.width.toInt()}x${size.height.toInt()}';
    for (final where in ['LLM prompt', 'HTTP KEY cell']) {
      testWidgets('$at $where: "/" opens the picker and "/te" filters it; a pick replaces "/te"; Escape closes and '
          'keeps the text', (t) async {
        final (c, demo) = await _editor(t, size);
        final llm = where == 'LLM prompt';
        await t.tap(
          find.descendant(of: find.byType(WorkflowStepsView), matching: find.text(llm ? 'Answer' : 'Fetch')).first,
        );
        await settle(t, 800);
        final editor = llm
            ? find.byType(DifyPromptEditor).first
            : find.descendant(of: find.byType(KeyValueLines).first, matching: find.byType(DifyPromptEditor)).first;
        final field = find.descendant(of: editor, matching: find.byType(EditableText));
        await t.ensureVisible(field);
        await settle(t, 300);
        await t.tap(field);
        await settle(t, 600);
        final start = llm ? 'Hello ' : '';
        _type(t, '$start/');
        await settle(t, 600);
        expect(_sheet, findsOneWidget, reason: '"/" opens the picker');
        final all = _listed(t);
        expect(all, containsAll(['query', 'temperature', 'text']));
        _type(t, '$start/t');
        await settle(t, 300);
        _type(t, '$start/te');
        await settle(t, 600);
        expect(_sheet, findsOneWidget);
        final filtered = _listed(t);
        expect(filtered, containsAll(['temperature', 'text']), reason: '"/te"');
        expect(filtered, isNot(contains('query')), reason: '"/te" filters the variables: $filtered');
        // "te" is also in the SYSTEM group's title: Dify's filterReferenceVars then keeps the whole group, so all of
        // sys.* stay listed (what looks like no filtering).
        expect(filtered, contains('sys.user_id'), reason: '"/te" matches the title "SYSTEM"');
        _type(t, '$start/temp');
        await settle(t, 600);
        expect(_listed(t), ['temperature'], reason: '"/temp"');
        // A pick replaces the trigger and its query.
        await t.tap(find.descendant(of: _sheet, matching: find.text('temperature')).first);
        await settle(t, 800);
        expect(_sheet, findsNothing);
        final state = t.state<DifyPromptEditorState>(editor);
        expect(state.controller.prompt, '$start{{#n-start.temperature#}}');
        // A space does not end Dify's `/` query (the trigger's characters run to the end of the line, up to 75): the
        // picker stays, with nothing matching "q x". Escape closes it and the typed text stays.
        final after = state.controller.text;
        _type(t, '$after /q');
        await settle(t, 600);
        expect(_listed(t), ['query']);
        _type(t, '$after /q x');
        await settle(t, 600);
        expect(_sheet, findsOneWidget, reason: 'a space keeps the picker, as in Dify');
        expect(_listed(t), isEmpty);
        await t.sendKeyEvent(LogicalKeyboardKey.escape);
        await settle(t, 600);
        expect(_sheet, findsNothing, reason: 'Escape closes the picker');
        expect(state.controller.text, '$after /q x');
        expect(find.byKey(const Key('node-settings-sheet')), findsOneWidget, reason: 'and only the picker');
        expect(t.testTextInput.hasAnyClients, isTrue, reason: 'the editor keeps the keyboard');
        // "{": Dify filters only the prompt blocks by the typed text; the variables keep their own search box.
        if (llm) {
          _type(t, '$after /q x {te');
          await settle(t, 600);
          expect(_sheet, findsOneWidget);
          expect(_listed(t), containsAll(['query', 'temperature', 'text']), reason: '"{te" leaves the variables');
          await t.sendKeyEvent(LogicalKeyboardKey.escape);
          await settle(t, 600);
          expect(_sheet, findsNothing);
        }
        expect(t.takeException(), isNull);
        await unmount(t);
        await demo.dispose();
        await t.pump(const Duration(seconds: 20));
        expect(c.doc.nodes, isNotEmpty);
      });
    }
  }
}
