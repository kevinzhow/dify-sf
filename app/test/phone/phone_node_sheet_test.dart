// The phone editor's node settings as a bottom sheet (batch 4a): opened from the Steps view and from the canvas at
// half the window, pulled up to full, its header (icon, editable title, type, Run step, "…", close) and tabs, back
// and close order; the panel's fields at phone density; every picker as a sheet; the keyboard; at 411x914 and
// 360x780 with the system bars' insets.
import 'dart:async';

import 'package:dify_sf_app/src/canvas/canvas_controller.dart';
import 'package:dify_sf_app/src/canvas/workflow_canvas.dart';
import 'package:dify_sf_app/src/demo/demo_backend.dart';
import 'package:dify_sf_app/src/design/dify_icon.dart';
import 'package:dify_sf_app/src/design/dify_theme.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/editor/editor_controller.dart';
import 'package:dify_sf_app/src/editor/editor_page.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/workflow_editor/dify_editor.dart';
import 'package:dify_sf_app/src/workflow_editor/header/publisher/app_publisher.dart' show AppPublisher;
import 'package:collab_client/collab_client.dart' show Document, Edge, Node;
import 'package:dify_sf_app/src/editor/undo_manager.dart' show HistoryEvent;
import 'package:dify_sf_app/src/workflow_editor/context_menu/clipboard.dart' show nodeFromDify;
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/model_selector.dart' show ModelSelectorButton;
import 'package:dify_sf_app/src/workflow_editor/node_panel/title_description_input.dart';
import 'package:dify_sf_app/src/workflow_editor/panel_fields/panel_fields.dart';
import 'package:dify_sf_app/src/workflow_editor/prompt_editor/prompt_editor.dart';
import 'package:dify_sf_app/src/workflow_editor/prompt_editor/prompt_editor_panel.dart';
import 'package:dify_sf_app/src/workflow_editor/phone/phone_editor_controller.dart';
import 'package:dify_sf_app/src/workflow_editor/run/ui/node_run_ui.dart' show NodeLastRun;
import 'package:dify_sf_app/src/workflow_editor/phone/phone_editor_frame.dart';
import 'package:dify_sf_app/src/workflow_editor/steps/workflow_steps_view.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/app_fonts.dart';
import 'phone_harness.dart';

/// The editor on the demo document (Start → "Answer the question" (LLM) → "Post-process" (code) → Answer).
class _Editor {
  _Editor(this.t, this.demo);
  final WidgetTester t;
  final DemoBackend demo;
  final nav = GlobalKey<NavigatorState>();

  EditorController get c => t.widget<DifyWorkflowEditor>(find.byType(DifyWorkflowEditor)).controller;
  Finder get canvasFinder => find.byType(WorkflowCanvas, skipOffstage: false);
  CanvasController get canvas => t.state<WorkflowCanvasState>(canvasFinder).canvas;
  WorkflowStore get store => WorkflowStoreScope.of(t.element(canvasFinder));
  PhoneEditorController get phone => PhoneEditorScope.read(t.element(find.byType(PhoneEditorFrame)))!;

  Offset node(String id) => t.getTopLeft(canvasFinder) + canvas.view.toScreen(canvas.graph![id]!.rect.center);

  Future<void> showCanvas() async {
    await t.tap(find.text('Canvas'));
    await settle(t, 600);
  }

  Future<void> dispose() async {
    await unmount(t);
    await demo.dispose();
    await t.pump(const Duration(seconds: 20));
  }
}

Future<_Editor> _pump(
  WidgetTester t, {
  Size size = const Size(411, 914),
  EdgeInsets insets = gestureInsets,
  bool pushed = false,
}) async {
  phoneWindow(t, size: size, insets: insets);
  final e = _Editor(t, DemoBackend(withBo: false));
  Widget editor() => EditorPage(backend: e.demo, docId: 'demo', clientId: 'phone-node-sheet', journaled: false);
  await t.pumpWidget(
    DifyApplication(
      theme: difyTheme(),
      edgeToEdge: true,
      navigatorKey: e.nav,
      home: pushed ? const DifyPage(edgeToEdge: true, body: SizedBox.expand(key: ValueKey('home'))) : editor(),
    ),
  );
  if (pushed) unawaited(e.nav.currentState!.push(difyPageRoute<void>(edgeToEdge: true, builder: (_) => editor())));
  await settle(t, 2000);
  _difyWorkflow(e.c);
  await settle(t, 800);
  return e;
}

/// A long flow (Start, twelve code steps, End), so a step can sit under the half sheet and the list can scroll it up.
void _longWorkflow(EditorController c) {
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
  add('l-start', 'start', 'Start', {'variables': <Object?>[]});
  for (var i = 1; i <= 12; i++) {
    add('l-$i', 'code', 'Step $i', {
      'code_language': 'python3',
      'code': 'def main() -> dict:\n    return {}\n',
      'variables': <Object?>[],
      'outputs': <String, Object?>{},
    });
  }
  add('l-end', 'end', 'End', {'outputs': <Object?>[]});
  final ids = [for (final n in nodes) n.id];
  c.applyGraphChange(
    event: HistoryEvent.nodeAdd,
    removeNodes: [...c.doc.nodes.keys],
    addNodes: nodes,
    addEdges: [for (var i = 0; i + 1 < ids.length; i++) Edge(id: 'le-$i', source: ids[i], target: ids[i + 1])],
  );
  c.selectNode(null);
}

/// The LLM step's title: a long node name.
const _llmTitle = 'Summarize the customer request in one sentence';

/// Replaces the demo document's nodes with a Dify-shaped workflow (as an import makes it), so the panels show their
/// real fields: Start (query, and a long variable name) → [_llmTitle] (LLM, a system prompt) → "Count words" (code,
/// its input `text` from the LLM) → End.
void _difyWorkflow(EditorController c) {
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
      {'variable': 'customer_request_text_in_full', 'label': 'Request', 'type': 'paragraph', 'required': false},
      {'variable': 'attachment', 'label': 'Attachment', 'type': 'file', 'required': false},
    ],
  });
  add('n-llm', 'llm', _llmTitle, {
    'model': {'provider': 'openai', 'name': 'gpt-4o', 'mode': 'chat', 'completion_params': <String, Object?>{}},
    'prompt_template': [
      {'role': 'system', 'text': 'Summarize {{#n-start.query#}} in one sentence.'},
    ],
    'context': {'enabled': false, 'variable_selector': <Object?>[]},
    'vision': {'enabled': false},
  });
  add('n-code', 'code', 'Count words', {
    'code_language': 'python3',
    'code': 'def main(text: str) -> dict:\n    return {"words": len(text.split())}\n',
    'variables': [
      {
        'variable': 'text',
        'value_selector': ['n-llm', 'text'],
      },
    ],
    'outputs': {
      'words': {'type': 'number', 'children': null},
    },
  });
  add('n-end', 'end', 'End', {
    'outputs': [
      {
        'variable': 'words',
        'value_selector': ['n-code', 'words'],
      },
    ],
  });
  c.applyGraphChange(
    event: HistoryEvent.nodeAdd,
    removeNodes: [...c.doc.nodes.keys],
    addNodes: nodes,
    addEdges: [
      for (final (i, (a, b)) in const [('n-start', 'n-llm'), ('n-llm', 'n-code'), ('n-code', 'n-end')].indexed)
        Edge(id: 'e-$i', source: a, target: b),
    ],
  );
  c.selectNode(null);
}

final _sheet = find.byKey(const Key('node-settings-sheet'));
final _header = find.byKey(const Key('node-settings-header'));
final _scrims = find.byKey(const ValueKey('dify-sheet-scrim'));
final _membersPage = find.byWidgetPredicate((w) => '${w.key}'.contains('var-members-page-'));

String _tw(String key) => DifyI18n.tr('workflow', key);
String _tp(String key) => DifyI18n.tr('phone-editor', key);
String _tc(String key) => DifyI18n.tr('common', key);
String get _insertVariable => DifyI18n.tr('phone-editor', 'insertVariable');

/// Drags [from] by [dy] in 20 steps, as a finger does (a single huge move skips the sheet's hand-over).
Future<void> _drag(WidgetTester t, Offset from, double dy) async {
  final g = await t.startGesture(from);
  for (var i = 0; i < 20; i++) {
    await g.moveBy(Offset(0, dy / 20));
    await t.pump(const Duration(milliseconds: 16));
  }
  await g.up();
  await settle(t, 600);
}

/// The settings sheet's top edge (its grab handle's).
double _sheetTop(WidgetTester t) => t.getRect(find.byType(DifySheetGrabHandle).first).top;

Finder _inSheet(Finder f) => find.descendant(of: _sheet, matching: f);

Future<void> _openFromSteps(WidgetTester t, String title) async {
  await t.tap(find.descendant(of: find.byType(WorkflowStepsView), matching: find.text(title)).first);
  await settle(t, 800);
}

/// [text] shows whole inside [field]: not cut to an ellipsis, not past the field's edge.
void _whole(WidgetTester t, Finder field, String text) {
  final label = find.descendant(of: field, matching: find.text(text));
  expect(label, findsOneWidget, reason: text);
  final paragraph = t.renderObject<RenderParagraph>(find.descendant(of: label, matching: find.byType(RichText)).first);
  expect(paragraph.didExceedMaxLines, isFalse, reason: text);
  final r = t.getRect(label), box = t.getRect(field);
  expect(r.left >= box.left - 0.5 && r.right <= box.right + 0.5, isTrue, reason: '$text: $r in $box');
}

Future<void> _scrollTo(WidgetTester t, Finder f) async {
  await t.ensureVisible(f);
  await settle(t, 300);
}

/// The labels of the semantics tree as the platform gets it (traversal order), what TalkBack and uiautomator read.
List<String> _platformLabels(WidgetTester t) {
  final out = <String>[];
  void walk(SemanticsNode n) {
    if (n.label.isNotEmpty) out.add(n.label);
    n.debugListChildrenInOrder(DebugSemanticsDumpOrder.traversalOrder).forEach(walk);
  }

  for (final view in t.binding.renderViews) {
    if (view.owner?.semanticsOwner?.rootSemanticsNode case final root?) walk(root);
  }
  return out;
}

void main() {
  setUpAll(() async {
    await DifyI18n.load('en-US');
    await useAppFonts();
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final size in phoneSizes) {
    final name = '${size.width.toInt()}x${size.height.toInt()}';

    testWidgets('$name: from the Steps view the settings open as a half sheet, pull up to full; back closes the '
        'sheet, then the selection', (t) async {
      final e = await _pump(t, size: size);
      await _openFromSteps(t, 'Count words');
      expect(e.phone.settingsNodeId, 'n-code');
      expect(_sheet, findsOneWidget);
      expect(t.takeException(), isNull);
      // Half the window: the step list above stays visible (its first card is above the sheet).
      final half = _sheetTop(t);
      expect(half, closeTo(size.height - size.height / 2 - gestureInsets.bottom, 2));
      // The tapped step is above the sheet (revealed if it was under it).
      final card = t.getRect(
        find.descendant(of: find.byType(WorkflowStepsView), matching: find.text('Count words')).first,
      );
      expect(card.bottom, lessThanOrEqualTo(half));
      // Edge to edge: the sheet reaches the window's bottom and sides; its content keeps clear of the gesture bar.
      expect(t.getRect(_sheet).width, size.width);
      expect(t.getRect(_sheet).bottom, closeTo(size.height - gestureInsets.bottom, 1));
      // The header: the block's icon, the editable title over the type, Run step, "…", close; the tabs under it.
      expect(find.descendant(of: _header, matching: find.byType(TitleInput)), findsOneWidget);
      expect(find.descendant(of: _header, matching: find.text(_tw('blocks.code'))), findsOneWidget);
      expect(find.byKey(const Key('node-settings-run')), findsOneWidget);
      expect(find.byKey(const Key('node-settings-more')), findsOneWidget);
      expect(find.byKey(const Key('node-settings-tab-settings')), findsOneWidget);
      expect(find.byKey(const Key('node-settings-tab-lastRun')), findsOneWidget);
      for (final key in ['node-settings-run', 'node-settings-more']) {
        expect(t.getSize(find.byKey(Key(key))).height, greaterThanOrEqualTo(44));
      }
      // Pulled up by its handle: full, up to the status bar.
      await _drag(t, t.getCenter(find.byType(DifySheetGrabHandle).first), -(size.height / 2));
      expect(_sheetTop(t), closeTo(gestureInsets.top, 2));
      // Back: the sheet, then the selection.
      expect(await systemBack(t), isTrue);
      expect(_sheet, findsNothing);
      expect(e.phone.settingsNodeId, isNull);
      expect(e.c.selectedNodeId, 'n-code', reason: 'back closed the sheet, the selection stays');
      expect(await systemBack(t), isTrue);
      expect(e.c.selectedNodeId, isNull);
      expect(t.takeException(), isNull);
      await e.dispose();
    });

    testWidgets('$name: from the canvas (selection bar, long press) the settings open as a half sheet; the close '
        'button and the scrim close it', (t) async {
      final e = await _pump(t, size: size);
      await e.showCanvas();
      await t.tapAt(e.node('n-llm'));
      await settle(t, 600);
      await t.tap(find.byKey(const ValueKey('phone-node-settings')));
      await settle(t, 800);
      expect(e.phone.settingsNodeId, 'n-llm');
      expect(_sheetTop(t), closeTo(size.height / 2 - gestureInsets.bottom, 2));
      // The header's close: the sheet goes, the node stays selected (its selection bar shows again).
      await t.tap(find.descendant(of: _header, matching: find.bySemanticsLabel(_tc('operation.close'))));
      await settle(t, 600);
      expect(_sheet, findsNothing);
      expect(find.byKey(const ValueKey('phone-node-bar')), findsOneWidget);
      // A long press: its action sheet's Settings.
      await t.longPressAt(e.node('n-code'));
      await settle(t, 800);
      await t.tap(find.text(_tc('operation.settings')).last);
      await settle(t, 800);
      expect(e.phone.settingsNodeId, 'n-code');
      expect(_sheet, findsOneWidget);
      // The scrim above the sheet closes it.
      await t.tapAt(Offset(size.width / 2, gestureInsets.top + 60));
      await settle(t, 600);
      expect(_sheet, findsNothing);
      expect(t.takeException(), isNull);
      await e.dispose();
    });
  }

  testWidgets('the tabs, the title edit, Run step and the "…" action sheet in the sheet header', (t) async {
    final e = await _pump(t);
    await _openFromSteps(t, 'Count words');
    // Tabs.
    await t.tap(find.byKey(const Key('node-settings-tab-lastRun')));
    await settle(t, 400);
    expect(find.byType(NodeLastRun), findsOneWidget);
    // Buttons in a sheet are touch-high on a phone: the empty tab's "Run this node".
    final runNode = find.ancestor(of: find.text(_tw('debug.noData.runThisNode')), matching: find.byType(DifyButton));
    expect(t.getSize(runNode).height, greaterThanOrEqualTo(44));
    await t.tap(find.byKey(const Key('node-settings-tab-settings')));
    await settle(t, 400);
    expect(find.byType(NodeLastRun), findsNothing);
    // The title is edited in place and committed with Done.
    await t.tap(find.descendant(of: _header, matching: find.byType(EditableText)));
    await settle(t, 300);
    await t.enterText(find.descendant(of: _header, matching: find.byType(EditableText)), 'Clean up');
    await t.testTextInput.receiveAction(TextInputAction.done);
    await settle(t, 600);
    expect(e.c.doc.nodes['n-code']!.title, 'Clean up');
    // Run step: the sheet's panel takes the single-run request.
    await t.tap(find.byKey(const Key('node-settings-run')));
    await settle(t, 800);
    expect(e.store.pendingSingleRun.value, isNull);
    expect(_sheet, findsOneWidget);
    expect(e.phone.settingsNodeId, 'n-code');
    // "…": the panel header's menu as an action sheet over the settings; Duplicate copies the node.
    final n = e.c.doc.nodes.length;
    await t.tap(find.byKey(const Key('node-settings-more')));
    await settle(t, 800);
    expect(find.text(_tw('panel.changeBlock')), findsOneWidget);
    await t.tap(find.text(_tw('common.duplicate')));
    await settle(t, 800);
    expect(e.c.doc.nodes.length, n + 1);
    expect(t.takeException(), isNull);
    await e.dispose();
  });

  testWidgets('fields at phone density: full-width rows under their labels, the whole "Node / {x} name" chip; the '
      'variable picker is a full-height sheet grouped by node that inserts into the field', (t) async {
    final e = await _pump(t, size: const Size(360, 780));
    // A long node name upstream of the code step (its input `text` is the LLM's), and a long variable name (Start's).
    e.c.setTitle('n-start', 'Customer request intake form', base: e.c.seenVersion);
    await settle(t, 400);
    await _openFromSteps(t, 'Count words');
    await _drag(t, t.getCenter(find.byType(DifySheetGrabHandle).first), -400);
    final trigger = _inSheet(find.byKey(const Key('var-reference-picker-trigger'))).first;
    await _scrollTo(t, trigger);
    // The variable takes the full width under the name (stacked), at touch height.
    // The LLM's long title shows whole in the chip.
    _whole(t, trigger, _llmTitle);
    _whole(t, trigger, 'text');
    final sheet = t.getRect(_sheet);
    final box = t.getRect(trigger);
    expect(box.width, greaterThan(sheet.width - 2 * 24));
    expect(box.height, greaterThanOrEqualTo(DifyTouch.controlHeight));
    final name = _inSheet(find.byType(DifyInput)).first;
    expect(t.getRect(name).bottom, lessThanOrEqualTo(box.top + 0.5), reason: 'the name above the value');
    // Every text field is 44 px on a phone (DifyInput).
    for (final input in _inSheet(find.byType(DifyInput)).evaluate()) {
      expect((input.renderObject! as RenderBox).size.height, greaterThanOrEqualTo(44));
    }

    // The picker: "Insert variable", a full-height sheet over the settings, no keyboard.
    await t.tap(trigger);
    await settle(t, 800);
    expect(find.text(_insertVariable), findsOneWidget);
    expect(_scrims, findsNWidgets(2));
    expect(t.testTextInput.isVisible, isFalse);
    expect(t.getRect(find.byType(DifySheetGrabHandle).last).top, closeTo(gestureInsets.top, 2));
    // Groups by upstream node, nearest first, each under its block icon; 48 px rows "{x} name … Type".
    final llm = find.byKey(const ValueKey('var-group-n-llm'));
    final start = find.byKey(const ValueKey('var-group-n-start'));
    expect(llm, findsOneWidget);
    expect(start, findsOneWidget);
    expect(t.getRect(llm).top, lessThan(t.getRect(start).top));
    expect(t.getSize(llm).height, greaterThanOrEqualTo(48));
    final row = find.ancestor(of: find.text('customer_request_text_in_full'), matching: find.byType(VarReferenceItem));
    expect(t.getSize(row).height, 48);
    expect(find.descendant(of: row, matching: find.text('String')), findsOneWidget);
    await t.tap(find.text('customer_request_text_in_full'));
    await settle(t, 800);
    expect(find.text(_insertVariable), findsNothing);
    expect(_sheet, findsOneWidget, reason: 'the settings stay open');
    // Inserted into the field, and shown whole: node name and variable name, nothing cut.
    _whole(t, trigger, 'Customer request intake form');
    _whole(t, trigger, 'customer_request_text_in_full');
    expect(find.descendant(of: trigger, matching: find.text(_llmTitle)), findsNothing);
    expect(t.takeException(), isNull);
    await e.dispose();
  });

  testWidgets('every picker in the panel opens as a sheet of touch rows without the keyboard, and back closes it '
      'before the settings', (t) async {
    final e = await _pump(t);
    await _openFromSteps(t, 'Count words');
    await _drag(t, t.getCenter(find.byType(DifySheetGrabHandle).first), -400);

    Future<void> opens(Finder trigger, String what, {Finder? row}) async {
      await _scrollTo(t, trigger);
      await t.tap(trigger);
      await settle(t, 800);
      expect(_scrims, findsNWidgets(2), reason: '$what opens as a sheet over the settings');
      expect(t.testTextInput.isVisible, isFalse, reason: '$what: no keyboard');
      if (row != null) expect(t.getSize(row).height, greaterThanOrEqualTo(48), reason: '$what: touch rows');
      expect(await systemBack(t), isTrue);
      expect(_scrims, findsOneWidget, reason: '$what: back closed the picker, the settings stay');
    }

    // A select (the output variable's type): 48 px rows; picking one changes the type.
    final type = _inSheet(find.byType(VarTypePicker)).first;
    await opens(
      type,
      'the type select',
      row: find.ancestor(of: find.text('String').last, matching: find.byType(Container)).first,
    );
    await t.tap(type);
    await settle(t, 800);
    await t.tap(find.text('String').last);
    await settle(t, 800);
    expect(_scrims, findsOneWidget);
    expect(find.descendant(of: type, matching: find.text('String')), findsOneWidget);
    // The error-handling strategies.
    await opens(_inSheet(find.byType(ErrorHandleTypeSelector)), 'error handling');
    await t.tap(_inSheet(find.byType(ErrorHandleTypeSelector)));
    await settle(t, 800);
    expect(find.text(_tw('nodes.common.errorHandle.title')), findsWidgets);
    await t.tap(find.text(_tw('nodes.common.errorHandle.defaultValue.title')).last);
    await settle(t, 800);
    expect(_scrims, findsOneWidget);
    // A type selector (the code's language).
    await opens(_inSheet(find.byWidgetPredicate((w) => w is TypeSelector)).first, 'the language selector');
    // The variable reference picker.
    await opens(_inSheet(find.byKey(const Key('var-reference-picker-trigger'))).first, 'the variable picker');
    expect(await systemBack(t), isTrue);
    expect(_sheet, findsNothing);

    // The LLM step: the model selector.
    await _openFromSteps(t, _llmTitle);
    await _drag(t, t.getCenter(find.byType(DifySheetGrabHandle).first), -400);
    await opens(_inSheet(find.byType(ModelSelectorButton)).first, 'the model selector');
    expect(t.takeException(), isNull);
    await e.dispose();
  });

  testWidgets('the prompt editor: "{" and the insert-variable button open "Insert variable" as a sheet; a row '
      'inserts the variable at the trigger', (t) async {
    final e = await _pump(t);
    await _openFromSteps(t, _llmTitle);
    await _drag(t, t.getCenter(find.byType(DifySheetGrabHandle).first), -400);
    final editor = _inSheet(find.byType(DifyPromptEditor)).first;
    await _scrollTo(t, editor);
    final state = t.state<DifyPromptEditorState>(editor);
    final before = state.controller.prompt;
    final count = '{{#n-start.query#}}'.allMatches(before).length;
    expect(count, 1, reason: before);
    // Typing "{" at the end.
    state.controller
      ..selection = TextSelection.collapsed(offset: state.controller.text.length)
      ..insertText('{');
    await settle(t, 800);
    final sheet = find.byKey(const Key('prompt-editor-picker-sheet'));
    expect(sheet, findsOneWidget);
    expect(find.descendant(of: sheet, matching: find.text(_insertVariable)), findsOneWidget);
    expect(_scrims, findsNWidgets(2));
    final query = find.descendant(of: sheet, matching: find.text('query'));
    expect(t.getSize(find.ancestor(of: query, matching: find.byType(VarReferenceItem))).height, 48);
    await t.tap(query);
    await settle(t, 800);
    expect(sheet, findsNothing);
    final after = state.controller.prompt;
    expect('{{#n-start.query#}}'.allMatches(after).length, count + 1, reason: after);
    expect(after.endsWith('{'), isFalse, reason: 'the trigger is replaced');
    // The header's insert-variable button: the same sheet, and no keyboard.
    FocusManager.instance.primaryFocus?.unfocus();
    await settle(t, 400);
    final button = find.descendant(
      of: _inSheet(find.byType(DifyPromptEditorPanel)).first,
      matching: find.bySemanticsLabel(_tw('common.insertVarTip')),
    );
    await t.tap(button.first);
    await settle(t, 800);
    expect(sheet, findsOneWidget);
    expect(t.testTextInput.isVisible, isFalse);
    expect(await systemBack(t), isTrue);
    expect(sheet, findsNothing);
    expect(_sheet, findsOneWidget);
    expect(t.takeException(), isNull);
    await e.dispose();
  });

  for (final size in phoneSizes) {
    testWidgets('${size.width.toInt()}x${size.height.toInt()}: the keyboard keeps the focused field above it (the '
        'sheet rises); the code editor expands into a full-screen page', (t) async {
      final e = await _pump(t, size: size);
      await _openFromSteps(t, 'Count words');
      final field = _inSheet(find.byWidgetPredicate((w) => w is EditableText && w.controller.text == 'words'));
      await _scrollTo(t, field);
      await t.tap(field);
      await settle(t, 300);
      openKeyboard(t);
      await settle(t, 800);
      expect(t.takeException(), isNull);
      final r = t.getRect(field);
      expect(r.bottom, lessThanOrEqualTo(size.height - 300));
      expect(r.top, greaterThanOrEqualTo(_sheetTop(t)));
      expect(_sheetTop(t), lessThan(size.height - 300 - size.height / 4), reason: 'the sheet rose with the keyboard');
      closeKeyboard(t);
      FocusManager.instance.primaryFocus?.unfocus();
      await settle(t, 800);

      // The code editor's expand: a full-screen page with a back button; back returns to the settings.
      final expand = _inSheet(find.bySemanticsLabel(DifyI18n.tr('share', 'chat.expand'))).first;
      await _scrollTo(t, expand);
      await t.tap(expand);
      await settle(t, 800);
      final page = find.byKey(const ValueKey('dify-portal-page'));
      expect(page, findsOneWidget);
      expect(t.getRect(page), Offset.zero & size);
      expect(find.descendant(of: page, matching: find.byType(DifyTopAppBar)), findsOneWidget);
      expect(await systemBack(t), isTrue);
      expect(page, findsNothing);
      expect(_sheet, findsOneWidget);
      expect(t.takeException(), isNull);
      await e.dispose();
    });
  }

  testWidgets('a step opened in the lower half of the Steps view is revealed above the half sheet', (t) async {
    final e = await _pump(t);
    _longWorkflow(e.c);
    await settle(t, 800);
    final view = find.byType(WorkflowStepsView);
    final half = 914 / 2 - gestureInsets.bottom;
    // The lowest step card in view that the half sheet would cover.
    String? low;
    for (var i = 12; i >= 1; i--) {
      final f = find.descendant(of: view, matching: find.text('Step $i'));
      if (f.evaluate().isEmpty) continue;
      final r = t.getRect(f.first);
      if (r.top > half && r.bottom < t.getRect(find.byKey(const ValueKey('phone-toolbar'))).top) {
        low = 'Step $i';
        break;
      }
    }
    expect(low, isNotNull, reason: 'a step under the half sheet\'s top');
    await t.tap(find.descendant(of: view, matching: find.text(low!)).first);
    await settle(t, 1200);
    expect(_sheet, findsOneWidget);
    final card = t.getRect(find.descendant(of: view, matching: find.text(low)).first);
    expect(card.bottom, lessThanOrEqualTo(_sheetTop(t)), reason: '$low revealed above the sheet');
    expect(card.top, greaterThanOrEqualTo(t.getRect(find.byKey(const ValueKey('phone-view-switch'))).bottom));
    expect(t.takeException(), isNull);
    await e.dispose();
  });

  testWidgets('object variables: the members open as a page of the variable sheet; back returns; a member is '
      'picked', (t) async {
    final e = await _pump(t);
    await _openFromSteps(t, 'End');
    await _drag(t, t.getCenter(find.byType(DifySheetGrabHandle).first), -400);
    final trigger = _inSheet(find.byKey(const Key('var-reference-picker-trigger'))).first;
    await _scrollTo(t, trigger);
    await t.tap(trigger);
    await settle(t, 800);
    expect(find.text(_insertVariable), findsOneWidget);
    // No hover panel on a phone: a chevron opens the members as a page of the sheet.
    final members = find.byKey(const ValueKey('var-members-attachment'));
    await t.ensureVisible(members);
    await settle(t, 300);
    expect(t.getSize(find.ancestor(of: members, matching: find.byType(DifyTouchArea))).height, 48);
    await t.tap(members);
    await settle(t, 600);
    expect(find.byKey(const ValueKey('var-members-page-attachment')), findsOneWidget);
    expect(find.byType(PickerStructurePanel), findsNothing);
    // Android back returns to the list, the sheet stays.
    expect(await systemBack(t), isTrue);
    expect(find.byKey(const ValueKey('var-members-page-attachment')), findsNothing);
    expect(find.text(_insertVariable), findsOneWidget);
    // The page's back button too; then a member is picked.
    await t.tap(members);
    await settle(t, 600);
    await t.tap(find.descendant(of: _membersPage, matching: find.byType(DifyAppBarBackButton)));
    await settle(t, 600);
    expect(_membersPage, findsNothing);
    await t.tap(members);
    await settle(t, 600);
    final name = find.byKey(const ValueKey('var-member-name'));
    expect(t.getSize(name).height, 48);
    await t.tap(name);
    await settle(t, 800);
    expect(find.text(_insertVariable), findsNothing);
    expect(find.descendant(of: trigger, matching: find.textContaining('name')), findsWidgets);
    expect(t.takeException(), isNull);
    await e.dispose();
  });

  testWidgets('the prompt editor\'s insert-variable button opens "Insert variable" directly (no trigger typed), '
      'after "sentence." too; a pick goes in at the caret; a dismissal changes nothing', (t) async {
    final e = await _pump(t);
    await _openFromSteps(t, _llmTitle);
    await _drag(t, t.getCenter(find.byType(DifySheetGrabHandle).first), -400);
    final editor = _inSheet(find.byType(DifyPromptEditor)).first;
    await _scrollTo(t, editor);
    final state = t.state<DifyPromptEditorState>(editor);
    final before = state.controller.prompt;
    expect(before, endsWith('sentence.'));
    final sheet = find.byKey(const Key('prompt-editor-picker-sheet'));
    final button = find.descendant(
      of: _inSheet(find.byType(DifyPromptEditorPanel)).first,
      matching: find.bySemanticsLabel(_tw('common.insertVarTip')),
    );
    Future<void> open() async {
      // The caret after "sentence.", where a typed "/" would not open anything.
      state.controller.selection = TextSelection.collapsed(offset: state.controller.text.length);
      await t.tap(button.first);
      await settle(t, 800);
      expect(sheet, findsOneWidget);
      expect(find.descendant(of: sheet, matching: find.text(_insertVariable)), findsOneWidget);
      expect(state.controller.prompt, before, reason: 'no trigger typed');
      expect(t.testTextInput.isVisible, isFalse);
    }

    for (final close in ['back', 'close']) {
      await open();
      if (close == 'back') {
        expect(await systemBack(t), isTrue);
      } else {
        await t.tap(find.descendant(of: sheet, matching: find.byType(DifyTouchIconButton)));
        await settle(t, 800);
      }
      expect(sheet, findsNothing, reason: close);
      expect(state.controller.prompt, before, reason: close);
      expect(_sheet, findsOneWidget, reason: close);
    }
    // A pick goes in at the caret (the end).
    await open();
    await t.tap(find.descendant(of: sheet, matching: find.text('query')));
    await settle(t, 800);
    expect(sheet, findsNothing);
    expect(state.controller.prompt, '$before{{#n-start.query#}}');
    expect(t.takeException(), isNull);
    await e.dispose();
  });

  testWidgets('accessibility: with the settings sheet open the platform gets the sheet, not the editor behind; a '
      'picker sheet over it is in the tree too; closing brings the editor back', (t) async {
    final semantics = t.ensureSemantics();
    final e = await _pump(t);
    final run = _tp('run');
    expect(_platformLabels(t), contains(run), reason: 'the app bar\'s Run');
    await _openFromSteps(t, 'Count words');
    var labels = _platformLabels(t);
    expect(labels, contains(_tw('debug.lastRunTab')), reason: 'the sheet\'s tabs: $labels');
    expect(labels, isNot(contains(run)), reason: 'the editor behind is blocked: $labels');
    // A picker sheet over the settings: its rows, not the settings behind it.
    await _drag(t, t.getCenter(find.byType(DifySheetGrabHandle).first), -400);
    final trigger = _inSheet(find.byKey(const Key('var-reference-picker-trigger'))).first;
    await _scrollTo(t, trigger);
    await t.tap(trigger);
    await settle(t, 800);
    labels = _platformLabels(t);
    expect(labels, contains(_insertVariable), reason: labels.toString());
    expect(labels, isNot(contains(run)), reason: 'the editor stays blocked: $labels');
    expect(await systemBack(t), isTrue);
    expect(await systemBack(t), isTrue);
    labels = _platformLabels(t);
    expect(labels, contains(run), reason: 'the editor is back: $labels');
    semantics.dispose();
    await e.dispose();
  });

  testWidgets('"…" → Publish opens the publisher in a sheet without an error (it failed since batch 3a: a clip without '
      'a decoration)', (t) async {
    final e = await _pump(t);
    await t.tap(find.byKey(const ValueKey('phone-editor-more')));
    await settle(t, 800);
    await t.tap(find.text(_tw('common.publish')).last);
    await settle(t, 1200);
    expect(t.takeException(), isNull);
    expect(find.byType(AppPublisher), findsOneWidget);
    expect(find.byType(ErrorWidget), findsNothing);
    expect(await systemBack(t), isTrue);
    expect(find.byType(AppPublisher), findsNothing);
    await e.dispose();
  });

  testWidgets('a short flow: the last step opened is brought above the half sheet (the list gets the room); the room '
      'goes when the sheet closes', (t) async {
    final e = await _pump(t);
    final view = find.byType(WorkflowStepsView);
    final end = find.descendant(of: view, matching: find.text('End'));
    expect(
      t.getRect(end.first).bottom,
      greaterThan(914 / 2 - gestureInsets.bottom),
      reason: 'End is in the lower half',
    );
    await t.tap(end.first);
    await settle(t, 1200);
    expect(_sheet, findsOneWidget);
    expect(t.getRect(end.first).bottom, lessThanOrEqualTo(_sheetTop(t)), reason: 'End above the sheet');
    expect(await systemBack(t), isTrue);
    await settle(t, 600);
    final scroll = t.state<ScrollableState>(find.descendant(of: view, matching: find.byType(Scrollable)).first);
    expect(scroll.position.maxScrollExtent, 0, reason: 'the room went with the sheet');
    expect(t.takeException(), isNull);
    await e.dispose();
  });

  testWidgets('the canvas: Settings from the selection bar pans the selected node above the half sheet when it is '
      'covered', (t) async {
    final e = await _pump(t);
    await e.showCanvas();
    await t.tapAt(e.node('n-end'));
    await settle(t, 600);
    Rect nodeRect() => e.canvas.view.rectToScreen(e.canvas.graph!['n-end']!.rect).shift(t.getTopLeft(e.canvasFinder));
    final half = 914 / 2 - gestureInsets.bottom;
    expect(nodeRect().bottom, greaterThan(half), reason: 'covered by a half sheet before');
    await t.tap(find.byKey(const ValueKey('phone-node-settings')));
    await settle(t, 1200);
    expect(nodeRect().bottom, lessThanOrEqualTo(_sheetTop(t)), reason: 'above the sheet');
    expect(nodeRect().top, greaterThanOrEqualTo(t.getTopLeft(e.canvasFinder).dy), reason: 'still in the canvas');
    expect(t.takeException(), isNull);
    await e.dispose();
  });

  testWidgets('the prompt editor\'s header: separate 48 px boxes (insert, "…" with Expand and Copy); its expanded page '
      'and the code editor\'s are named after the step', (t) async {
    final e = await _pump(t);
    await _openFromSteps(t, _llmTitle);
    await _drag(t, t.getCenter(find.byType(DifySheetGrabHandle).first), -400);
    final panel = _inSheet(find.byType(DifyPromptEditorPanel)).first;
    await _scrollTo(t, panel);
    final boxes = find.descendant(of: panel, matching: find.byType(DifyTouchArea));
    expect(boxes, findsNWidgets(2));
    final rects = [for (final b in boxes.evaluate()) t.getRect(find.byWidget(b.widget))];
    for (final r in rects) {
      expect(r.width, greaterThanOrEqualTo(44));
      expect(r.height, greaterThanOrEqualTo(44));
    }
    for (var i = 0; i + 1 < rects.length; i++) {
      expect(rects[i].right, lessThanOrEqualTo(rects[i + 1].left + 0.5), reason: 'no overlap');
    }
    await t.tap(find.byKey(const Key('prompt-editor-more')));
    await settle(t, 800);
    expect(find.text(DifyI18n.tr('common', 'operation.copy')), findsOneWidget);
    // Expanded from "…": a page titled with the step.
    await t.tap(find.text(DifyI18n.tr('share', 'chat.expand')).last);
    await settle(t, 800);
    final page = find.byKey(const ValueKey('dify-portal-page'));
    expect(find.descendant(of: page, matching: find.text(_llmTitle)), findsOneWidget);
    expect(await systemBack(t), isTrue);
    expect(await systemBack(t), isTrue);
    // The code editor's page: "Count words" over "Code".
    await _openFromSteps(t, 'Count words');
    final expand = _inSheet(find.bySemanticsLabel(DifyI18n.tr('share', 'chat.expand'))).first;
    await _scrollTo(t, expand);
    await t.tap(expand);
    await settle(t, 800);
    final bar = find.descendant(of: page, matching: find.byType(DifyTopAppBar));
    expect(find.descendant(of: bar, matching: find.text('Count words')), findsOneWidget);
    expect(find.descendant(of: bar, matching: find.text(_tw('blocks.code'))), findsOneWidget);
    expect(t.takeException(), isNull);
    await e.dispose();
  });

  testWidgets('select sheets: titled from the field, the current value marked, one row inset', (t) async {
    final e = await _pump(t);
    await _openFromSteps(t, 'Count words');
    await _drag(t, t.getCenter(find.byType(DifySheetGrabHandle).first), -400);
    // The output type select: the field's title, "Number" marked.
    final type = _inSheet(find.byType(VarTypePicker)).first;
    await _scrollTo(t, type);
    await t.tap(type);
    await settle(t, 800);
    expect(
      find.descendant(of: find.byType(DifySheetHeader).last, matching: find.text(_tw('nodes.code.outputVars'))),
      findsOneWidget,
    );
    final number = find.text('Number').last;
    final typeInset = t.getRect(number).left;
    expect(await systemBack(t), isTrue);
    // The language selector: "Language", the current one checked, the same inset.
    final language = _inSheet(find.byWidgetPredicate((w) => w is TypeSelector)).first;
    await _scrollTo(t, language);
    await t.tap(language);
    await settle(t, 800);
    expect(
      find.descendant(
        of: find.byType(DifySheetHeader).last,
        matching: find.text(DifyI18n.tr('phone-editor', 'language')),
      ),
      findsOneWidget,
    );
    expect(find.byWidgetPredicate((w) => w is DifyIcon && w.name == 'vender/line/general/check'), findsOneWidget);
    final python = find.text('Python3').last;
    expect(t.getRect(python).left, closeTo(typeInset, 0.5), reason: 'one row inset');
    expect(typeInset, closeTo(16, 0.5));
    expect(t.takeException(), isNull);
    await e.dispose();
  });
}
