import 'package:collab_client/collab_client.dart';
import 'package:collab_client/testing.dart';
import 'package:dify_sf_app/src/demo/demo_backend.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/editor/editor_controller.dart';
import 'package:dify_sf_app/src/session_factory.dart';
import 'package:dify_sf_app/src/workflow/model_catalog.dart';
import 'package:dify_sf_app/src/workflow_editor/context_menu/clipboard.dart' show nodeFromDify;
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/group_host.dart';
import 'package:dify_sf_app/src/workflow_editor/store/app_registers_sync.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

export '../../dify_test_i18n.dart';

/// An op the panels asked the controller for: `insert` / `update` / `remove` an item, or `set` a config field.
typedef RecordedOp = ({String kind, String node, List<String> path, String? id, Object? value, int? base});

/// The editor controller with every write it is asked for recorded (before it goes to the session).
class RecordingController extends EditorController {
  RecordingController({required super.session, required super.docId}) : super(journaled: false);

  final ops = <RecordedOp>[];

  @override
  String insertItem(String nodeId, List<String> path, Value value, {String? after, String? id}) {
    final itemId = super.insertItem(nodeId, path, value, after: after, id: id);
    ops.add((kind: 'insert', node: nodeId, path: path, id: itemId, value: value.toJson(), base: null));
    return itemId;
  }

  @override
  void updateItem(String nodeId, List<String> path, String itemId, Value value, {int? base}) {
    ops.add((kind: 'update', node: nodeId, path: path, id: itemId, value: value.toJson(), base: base));
    super.updateItem(nodeId, path, itemId, value, base: base);
  }

  @override
  void removeItem(String nodeId, List<String> path, String itemId) {
    ops.add((kind: 'remove', node: nodeId, path: path, id: itemId, value: null, base: null));
    super.removeItem(nodeId, path, itemId);
  }

  @override
  void setConfig(String nodeId, List<String> path, Value value, {int? base}) {
    ops.add((kind: 'set', node: nodeId, path: path, id: null, value: value.toJson(), base: base));
    super.setConfig(nodeId, path, value, base: base);
  }

  /// The recorded ops on the app variables (`$app`).
  List<RecordedOp> get appOps => [
    for (final o in ops)
      if (o.node == r'$app') o,
  ];

  /// The recorded writes to nodes.
  List<RecordedOp> get nodeOps => [
    for (final o in ops)
      if (o.node != r'$app') o,
  ];
}

/// A node from Dify's React Flow [data] (selectors to nodes of [doc] become references).
Node difyNode(String id, String type, Map<String, Object?> data, {Document? doc}) => nodeFromDify(
  {
    'id': id,
    'type': 'custom',
    'position': {'x': 0, 'y': 0},
    'data': {'type': type, 'title': type, 'desc': '', ...data},
  },
  doc ?? Document(nodes: const [], edges: const []),
  id: id,
);

/// A document with [nodes] and the app's [env] and [conversation] variables in an in-memory session, a recording
/// controller on it, and a workflow store following the document's variables.
class VarHarness {
  VarHarness._(this.server, this.demo, this.opened, this.controller);

  final FakeServer server;
  final DemoBackend demo;
  final OpenedSession opened;
  final RecordingController controller;
  final store = WorkflowStore();

  /// The store following the document's variables, as in the editor.
  late final sync = AppRegistersSync(controller: controller, store: store);

  Document get doc => controller.doc;

  static Future<VarHarness> start(
    WidgetTester t, {
    List<Node> nodes = const [],
    List<Map<String, Object?>> env = const [],
    List<Map<String, Object?>> conversation = const [],
    Map<String, String> envSecrets = const {},
  }) async {
    VItems items(List<Map<String, Object?>> vars) =>
        VItems([for (final v in vars) Item(v['id']! as String, Value.of(v))]);
    final initial = Document(
      nodes: nodes,
      app: {
        if (env.isNotEmpty) AppRegisters.environmentVariables: items(env),
        if (conversation.isNotEmpty) AppRegisters.conversationVariables: items(conversation),
      },
    );
    final server = FakeServer(initial: initial);
    final demo = DemoBackend(server: server, withBo: false);
    final opened = await demo.openSession('demo', clientId: 'me-abc123', journaled: false);
    await opened.session.start();
    final h = VarHarness._(server, demo, opened, RecordingController(session: opened.session, docId: 'demo'));
    for (var i = 0; i < 50 && !h.controller.ready; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    h.sync.sync();
    h.store.setEnvSecrets(envSecrets);
    return h;
  }

  /// Closes the session (call at the end of each test: its timers must be gone when the test ends).
  Future<void> dispose(WidgetTester t) async {
    await t.pumpWidget(const SizedBox());
    sync.dispose();
    controller.dispose();
    store.dispose();
    await opened.close();
    await demo.dispose();
    await t.pump(const Duration(seconds: 20));
  }
}

/// The toasts shown (`toast.error(message)` and the like).
final toasts = <String>[];

/// The host's services for the panels: [models] as the workspace's text generation models, toasts into [toasts],
/// [parameterRules] as the rules loader.
LlmGroupServices panelServices({
  List<ProviderWithModels> models = const [],
  Future<List<Map<String, Object?>>> Function(String provider, String model)? parameterRules,
}) => LlmGroupServices(
  models: ModelCatalog(
    providers: [for (final m in models) ModelProvider(provider: m.provider, label: m.label)],
    modelLists: {ModelTypeEnum.textGeneration: models},
  ),
  parameterRules: parameterRules,
  toast: (type, message) => toasts.add(message),
);

/// Pumps [child] at the right edge of a 1600 x 1000 page (room for the modal on its left), with [store] and
/// [services] in scope.
Future<void> pumpPanel(
  WidgetTester t,
  Widget child, {
  required WorkflowStore store,
  LlmGroupServices? services,
}) async {
  t.view.physicalSize = const Size(1600, 1000);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  toasts.clear();
  await t.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Material(
        child: LlmGroupScope(
          services: services ?? panelServices(),
          child: WorkflowStoreScope(
            store: store,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [const Spacer(), child],
            ),
          ),
        ),
      ),
    ),
  );
  await t.pump();
}

/// Lets popups finish their transitions.
Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 4; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

/// The control whose accessible name is [label] (`getByRole('button', { name })`): its label, or its text.
Finder buttonNamed(String label) {
  final named = find.byWidgetPredicate(
    (w) => w is DifyPressable && w.semanticLabel == label,
    description: 'button "$label"',
  );
  if (named.evaluate().isNotEmpty) return named;
  return find.ancestor(of: find.text(label), matching: find.byType(DifyPressable)).first;
}

/// The text field showing [placeholder] (`getByPlaceholderText`).
Finder byPlaceholder(String placeholder) => find.byWidgetPredicate(
  (w) => w is TextField && w.decoration?.hintText == placeholder,
  description: 'field "$placeholder"',
);

/// The text field showing [text] (`getByDisplayValue`).
Finder byDisplayValue(String text) => find.byWidgetPredicate(
  (w) => w is TextField && w.controller?.text == text,
  description: 'field showing "$text"',
);

/// Taps [f] and lets transitions finish.
Future<void> tap(WidgetTester t, Finder f) async {
  await t.tap(f.first);
  await settle(t);
}

/// Types [text] into the field [f] (replacing its content) and lets the UI settle.
Future<void> type(WidgetTester t, Finder f, String text) async {
  await t.enterText(f.first, text);
  await t.pump();
}

/// Dify's spec fixture `createEnv`.
Map<String, Object?> createEnv([Map<String, Object?> overrides = const {}]) => {
  'id': 'env-1',
  'name': 'api_key',
  'value': '[__HIDDEN__]',
  'value_type': 'secret',
  'description': 'secret description',
  ...overrides,
};
