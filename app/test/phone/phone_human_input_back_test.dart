// The Human Input single run's generated form on a phone (device recheck of 2591a435): its Back link is a 44 dp touch
// target. The editor's server runtime on a FakeWorkflowRunApi; fixture after the reviewer's review13 (a human-input
// node whose paragraph default is start.query, so the before-run form shows).
import 'dart:async';

import 'package:collab_client/collab_client.dart';
import 'package:collab_client/testing.dart';
import 'package:dify_sf_app/src/demo/demo_backend.dart';
import 'package:dify_sf_app/src/design/dify_theme.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/editor/editor_page.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/human_input/single_run.dart'
    show HumanInputRunForm;
import 'package:dify_sf_app/src/workflow_editor/phone/phone_editor_frame.dart';
import 'package:dify_sf_app/src/workflow_editor/run/run_scope.dart';
import 'package:dify_sf_app/src/workflow_editor/run/server_run_service.dart';
import 'package:dify_sf_app/src/workflow_editor/run/ui/before_run_form.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'phone_harness.dart';
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

  WorkflowStore get store => WorkflowStoreScope.of(t.element(find.byType(PhoneEditorFrame)));
  WorkflowRunScope get scope => WorkflowRunScope.of(t.element(find.byType(PhoneEditorFrame)));

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

  final runs = <Map<String, Object?>>[];
  final submitted = Completer<Map<String, Object?>>();
  @override
  Future<Map<String, Object?>> humanInputFormRun(String url, Map<String, Object?> body) {
    runs.add(body);
    return submitted.future;
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
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final size in phoneSizes) {
    testWidgets('${size.width.toInt()}x${size.height.toInt()}: the Human Input form\'s Back is a 44 dp touch target', (
      t,
    ) async {
      final api = _Api();
      final e = await _pump(t, api: api, size: size);
      addTearDown(e.dispose);
      e.store.setPendingSingleRun((nodeId: 'human', action: SingleRunAction.run));
      await settle(t, 800);
      t.widget<BeforeRunForm>(find.byType(BeforeRunForm)).handleShowGeneratedForm!({'#start.query#': 'example'});
      api.response.complete(_generated());
      await settle(t, 800);
      final back = find.descendant(of: find.byType(HumanInputRunForm), matching: find.byType(DifyPressable)).first;
      final box = find.ancestor(of: back, matching: find.byType(DifyTouchArea));
      expect(box, findsWidgets, reason: 'the link is in a touch box');
      final r = t.getRect(box.first);
      expect(r.height, greaterThanOrEqualTo(44), reason: '$r');
      expect(r.width, greaterThanOrEqualTo(44), reason: '$r');
      await t.tap(back);
      await settle(t, 600);
      expect(find.byType(HumanInputRunForm), findsNothing, reason: 'Back returns to the before-run form');
      expect(t.takeException(), isNull);
    });
  }
}
