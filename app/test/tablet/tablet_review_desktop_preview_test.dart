// The reviewer's (Winnie's) desktop repro (mobile41_desktop_preview_close_review20): on the desktop editor (a mouse;
// no shared single-run draft) a Human Input preview request still pending when the node panel closes or the editor
// is left must not notify the panel's disposed local draft when it answers; with the panel kept open it lands.
import 'dart:async';

import 'package:collab_client/collab_client.dart';
import 'package:collab_client/testing.dart';
import 'package:dify_sf_app/src/canvas/workflow_canvas.dart';
import 'package:dify_sf_app/src/demo/demo_backend.dart';
import 'package:dify_sf_app/src/design/dify_theme.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/editor/editor_controller.dart';
import 'package:dify_sf_app/src/editor/editor_page.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/workflow_editor/dify_editor.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/human_input/single_run.dart'
    show HumanInputRunForm;
import 'package:dify_sf_app/src/workflow_editor/phone/phone_editor_frame.dart';
import 'package:dify_sf_app/src/workflow_editor/run/run_scope.dart';
import 'package:dify_sf_app/src/workflow_editor/run/server_run_service.dart';
import 'package:dify_sf_app/src/workflow_editor/run/ui/before_run_form.dart';
import 'package:dify_sf_app/src/workflow_editor/run/ui/node_run_ui.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../phone/phone_harness.dart';
import '../support/app_fonts.dart';

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
          id: 'human',
          type: 'human-input',
          title: 'Review',
          x: 380,
          y: 360,
          config: {
            'form_content': Value.of('Question {{#start.query#}} {{#\$output.review#}}'),
            'inputs': VList([
              VMap({
                'type': VString('paragraph'),
                'output_variable_name': VString('review'),
                'default': VMap({
                  'type': VString('variable'),
                  'selector': ref('start', 'query'),
                  'value': VString('initial review'),
                }),
              }),
            ]),
            'user_actions': Value.of([
              {'id': 'approve', 'title': 'Approve', 'button_style': 'primary'},
            ]),
            'delivery_methods': Value.of([
              {'type': 'webapp', 'enabled': true},
            ]),
            'timeout': Value.of(1),
            'timeout_unit': Value.of('day'),
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
  _Editor(this.t, this.backend, this.size);
  final WidgetTester t;
  final _Backend backend;
  final Size size;

  EditorController get c => t.widget<DifyWorkflowEditor>(find.byType(DifyWorkflowEditor)).controller;
  WorkflowStore get store => WorkflowStoreScope.of(t.element(find.byType(WorkflowCanvas)));
  WorkflowRunScope get scope => WorkflowRunScope.of(t.element(find.byType(WorkflowCanvas)));

  Future<void> dispose() async {
    await unmount(t);
    await backend.dispose();
    await t.pump(const Duration(seconds: 20));
  }
}

Future<_Editor> _pump(WidgetTester t, {Size size = const Size(411, 914), bool chat = false, required _Api api}) async {
  phoneWindow(t, size: size, insets: gestureInsets);
  final backend = _Backend(
    DocMeta(appMode: chat ? 'advanced-chat' : 'workflow', appName: 'Self-host check'),
    server: _server(),
  );
  await t.pumpWidget(
    DifyApplication(
      theme: difyTheme(),
      edgeToEdge: true,
      home: EditorPage(
        backend: backend,
        docId: 'demo',
        clientId: 'phone-run',
        journaled: false,
        serverRuntime: ServerWorkflowRuntime(api: api, singleNodeRun: {'human-input'}, humanInput: true),
      ),
    ),
  );
  await settle(t, 2000);
  final e = _Editor(t, backend, size);
  // The fixture's model is not configured in a workspace: let the mock runtime's preflight pass.
  e.store.computeRunChecklist = () => const [];
  return e;
}

class _Api extends FakeWorkflowRunApi {
  final response = Completer<Map<String, Object?>>();
  var previews = 0;
  @override
  Future<Map<String, Object?>> humanInputFormPreview(String url, Map<String, Object?> body) {
    previews++;
    return response.future;
  }
}

Map<String, Object?> _generated() => {
  'form_id': 'form-1',
  'node_id': 'human',
  'node_title': 'Review',
  'form_content': r'Please review {{#$output.review#}}',
  'inputs': [
    {
      'type': 'paragraph',
      'output_variable_name': 'review',
      'default': {'type': 'constant', 'selector': [], 'value': 'initial review'},
    },
  ],
  'actions': [
    {'id': 'approve', 'title': 'Approve', 'button_style': 'primary'},
  ],
  'resolved_default_values': <String, Object?>{},
};
void main() {
  setUpAll(() async {
    await DifyI18n.load('en-US');
    await useAppFonts();
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    DifyInteraction.debugDefault = DifyInteractionMode.pointer;
  });
  tearDown(() => DifyInteraction.debugDefault = null);
  for (final mode in ['keep', 'close', 'leave']) {
    final close = mode != 'keep';
    testWidgets(
      'desktop preview reply after ${mode == 'leave'
          ? "leaving editor"
          : close
          ? "closing panel"
          : "keeping panel open"}',
      (t) async {
        final api = _Api();
        final e = await _pump(t, size: const Size(1280, 800), api: api);
        addTearDown(e.dispose);
        expect(find.byType(PhoneEditorFrame), findsNothing);
        expect(find.byType(SingleRunFormDraftScope), findsNothing);
        e.c.selectNode('human');
        await settle(t, 600);
        expect(e.scope.singleRunOf('human').validate().isValid, isTrue);
        e.scope.singleRunOf('human').showSingleRun();
        await settle(t, 600);
        expect(find.byType(BeforeRunForm), findsOneWidget);
        t.widget<BeforeRunForm>(find.byType(BeforeRunForm)).handleShowGeneratedForm!({'#start.query#': 'example'});
        await t.pump();
        expect(api.previews, 1);
        if (mode == 'leave') {
          await t.pumpWidget(const SizedBox.shrink());
          await settle(t, 600);
        } else if (close) {
          e.c.selectNode(null);
          await settle(t, 600);
        }
        if (close) expect(find.byType(NodeSingleRunOverlay), findsNothing);
        api.response.complete(_generated());
        await settle(t, 800);
        expect(find.byType(HumanInputRunForm), close ? findsNothing : findsOneWidget);
        expect(
          t.takeException(),
          isNull,
          reason: 'reply to a removed desktop panel must not notify its disposed local draft',
        );
      },
    );
  }
}
