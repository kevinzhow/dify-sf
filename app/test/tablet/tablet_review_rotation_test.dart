// The reviewer's (Winnie's) repro of the stacked build, copied from her review (mobile41_rotation_semantics_review4):
// a single step's run form keeps what was typed when a rotation moves it between the bottom sheet and the side panel
// (and on a plain rebuild), and on a tablet the node settings the Run form docks over leave the platform semantics
// tree. Her fixture: start (query) -> llm -> code -> end, touch input.
import 'package:collab_client/collab_client.dart';
import 'package:collab_client/testing.dart';
import 'package:dify_sf_app/src/demo/demo_backend.dart';
import 'package:dify_sf_app/src/design/dify_theme.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/editor/editor_controller.dart';
import 'package:dify_sf_app/src/editor/editor_page.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/workflow_editor/dify_editor.dart';
import 'package:dify_sf_app/src/workflow_editor/phone/phone_editor_controller.dart';
import 'package:dify_sf_app/src/workflow_editor/phone/phone_editor_frame.dart';
import 'package:dify_sf_app/src/workflow_editor/run/ui/before_run_form.dart';
import 'package:dify_sf_app/src/workflow_editor/run/ui/workflow_preview.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../phone/phone_harness.dart';
import '../support/app_fonts.dart';
import '../support/platform_semantics.dart';

class _Backend extends DemoBackend {
  _Backend(this._meta, {super.server}) : super(withBo: false);
  final DocMeta _meta;
  @override
  Future<DocMeta> docMeta(String docId) async => _meta;
}

/// start (query: text input, required) → llm → code → end: mockup 7's run.
FakeServer _server() {
  Value ref(String n, String o) => VRef(OutputRef(n, o));
  return FakeServer(
    initial: Document(
      nodes: [
        Node(
          id: 'start',
          type: 'start',
          title: 'Start',
          x: 80,
          y: 120,
          config: {
            'variables': VItems([
              Item(
                'v-query',
                Value.of({'variable': 'query', 'label': 'Query', 'type': 'text-input', 'required': true}),
              ),
            ]),
          },
        ),
        Node(
          id: 'llm',
          type: 'llm',
          title: 'Summarize',
          x: 380,
          y: 120,
          config: {
            'model': const VMap({'provider': VString('openai'), 'name': VString('gpt-4o')}),
            'context': ref('start', 'query'),
          },
        ),
        Node(
          id: 'code',
          type: 'code',
          title: 'Count Android',
          x: 680,
          y: 120,
          config: {
            'language': const VString('python3'),
            'code': const VString("def main(text):\n    return {'result': text.strip()}"),
            'inputs': ref('llm', 'text'),
          },
        ),
        Node(
          id: 'end',
          type: 'end',
          title: 'End',
          x: 980,
          y: 120,
          config: {
            'outputs': VItems([
              Item('o1', VMap({'variable': const VString('result'), 'value_selector': ref('code', 'result')})),
            ]),
          },
        ),
      ],
      edges: const [
        Edge(id: 'e1', source: 'start', target: 'llm'),
        Edge(id: 'e2', source: 'llm', target: 'code'),
        Edge(id: 'e3', source: 'code', target: 'end'),
      ],
    ),
  );
}

class _Editor {
  _Editor(this.t, this.backend);
  final WidgetTester t;
  final _Backend backend;

  EditorController get c => t.widget<DifyWorkflowEditor>(find.byType(DifyWorkflowEditor)).controller;
  WorkflowStore get store => WorkflowStoreScope.of(t.element(find.byType(PhoneEditorFrame)));
  PhoneEditorController get phone => PhoneEditorScope.read(t.element(find.byType(PhoneEditorFrame)))!;

  Future<void> dispose() async {
    await unmount(t);
    await backend.dispose();
    await t.pump(const Duration(seconds: 20));
  }
}

Future<_Editor> _pump(WidgetTester t, {Size size = const Size(411, 914), bool chat = false}) async {
  phoneWindow(t, size: size, insets: gestureInsets);
  final backend = _Backend(
    DocMeta(appMode: chat ? 'advanced-chat' : 'workflow', appName: 'Self-host check'),
    server: _server(),
  );
  await t.pumpWidget(
    DifyApplication(
      theme: difyTheme(),
      edgeToEdge: true,
      home: EditorPage(backend: backend, docId: 'demo', clientId: 'phone-run', journaled: false),
    ),
  );
  await settle(t, 2000);
  final e = _Editor(t, backend);
  // The fixture's model is not configured in a workspace: let the mock runtime's preflight pass.
  e.store.computeRunChecklist = () => const [];
  return e;
}

String _tw(String key) => DifyI18n.tr('workflow', key);

void main() {
  setUpAll(() async {
    await DifyI18n.load('en-US');
    await useAppFonts();
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    DifyInteraction.debugDefault = DifyInteractionMode.touch;
  });
  tearDown(() => DifyInteraction.debugDefault = null);

  // Her two cases (a plain rebuild, portrait to landscape), and the way back (the side panel to the sheet).
  for (final (from, to) in const [
    (Size(411, 914), null),
    (Size(411, 914), Size(914, 411)),
    (Size(914, 411), Size(411, 914)),
  ]) {
    final what = to == null
        ? 'ordinary rebuild'
        : '${from.width < from.height ? 'portrait' : 'landscape'} to ${to.width < to.height ? 'portrait' : 'landscape'}';
    testWidgets('single-step draft survives $what', (t) async {
      final e = await _pump(t, size: from);
      addTearDown(e.dispose);
      e.store.setPendingSingleRun((nodeId: 'llm', action: SingleRunAction.run));
      await settle(t, 800);
      expect(find.byType(BeforeRunForm), findsOneWidget);
      Finder field() => find.descendant(of: find.byType(BeforeRunForm), matching: find.byType(EditableText)).first;
      await t.enterText(field(), 'draft that must survive');
      await t.pump();
      expect(t.widget<EditableText>(field()).controller.text, 'draft that must survive');
      if (to != null) {
        t.view.physicalSize = to;
      } else {
        e.store.setDraftUpdatedAt(e.store.draftUpdatedAt.value + 1);
      }
      await settle(t, 1000);
      expect(find.byType(BeforeRunForm), findsOneWidget);
      expect(t.widget<EditableText>(field()).controller.text, 'draft that must survive');
      expect(t.takeException(), isNull);
    });
  }

  // The reviewer's follow-up: the same form opened from the node's Settings (Run this step), whose form is the node
  // panel's own; portrait <-> landscape and phone <-> touch tablet.
  for (final (from, to) in const [
    (Size(411, 914), Size(914, 411)),
    (Size(914, 411), Size(411, 914)),
    (Size(411, 914), Size(800, 1280)),
    (Size(800, 1280), Size(411, 914)),
  ]) {
    String at(Size s) => '${s.width.toInt()}x${s.height.toInt()}';
    testWidgets('single-step draft from Settings survives ${at(from)} -> ${at(to)}', (t) async {
      final e = await _pump(t, size: from);
      addTearDown(e.dispose);
      e.c.selectNode('llm');
      e.phone.openSettings('llm');
      await settle(t, 800);
      final run = find.byKey(const Key('node-settings-run'));
      await t.ensureVisible(run);
      await t.pump();
      await t.tap(run);
      await settle(t, 800);
      final form = find.descendant(
        of: find.byKey(const Key('node-settings-sheet')),
        matching: find.byType(BeforeRunForm),
      );
      expect(form, findsOneWidget, reason: "the node panel's own single-run form");
      Finder field() => find.descendant(of: form, matching: find.byType(EditableText)).first;
      await t.enterText(field(), 'typed in Settings');
      await t.pump();
      t.view.physicalSize = to;
      await settle(t, 1000);
      expect(e.phone.settingsNodeId, 'llm', reason: 'the settings stay open');
      expect(form, findsOneWidget);
      expect(t.widget<EditableText>(field()).controller.text, 'typed in Settings');
      expect(t.takeException(), isNull);
    });
  }

  testWidgets('covered node settings leave the platform semantics tree when Run inputs cover them on tablet', (
    t,
  ) async {
    final e = await _pump(t, size: const Size(800, 1280));
    addTearDown(e.dispose);
    final semantics = t.ensureSemantics();
    e.c.selectNode('code');
    e.phone.openSettings('code');
    await settle(t, 800);
    expect(find.byKey(const ValueKey('phone-node-settings-side')), findsOneWidget);
    final panelName = _tw('panel.nodePanel');
    expect(platformLabels(t), contains(panelName));
    await t.tap(find.byKey(const ValueKey('phone-run')));
    await settle(t, 800);
    expect(find.byKey(const ValueKey('phone-run-input-side')), findsOneWidget);
    expect(find.byType(InputsPanel), findsOneWidget);
    expect(platformLabels(t), isNot(contains(panelName)), reason: 'the node panel is fully covered by the Run form');
    semantics.dispose();
    expect(t.takeException(), isNull);
  });
}
