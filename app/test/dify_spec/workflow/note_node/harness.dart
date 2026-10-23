import 'package:collab_client/collab_client.dart';
import 'package:collab_client/testing.dart';
import 'package:dify_sf_app/src/canvas/canvas_controller.dart';
import 'package:dify_sf_app/src/canvas/live_card.dart';
import 'package:dify_sf_app/src/cards/bodies/note_text.dart';
import 'package:dify_sf_app/src/canvas/renderer_choice.dart';
import 'package:dify_sf_app/src/canvas/workflow_canvas.dart';
import 'package:dify_sf_app/src/demo/demo_backend.dart';
import 'package:dify_sf_app/src/design/widgets/toast.dart';
import 'package:dify_sf_app/src/editor/editor_controller.dart';
import 'package:dify_sf_app/src/editor/undo_manager.dart';
import 'package:dify_sf_app/src/session_factory.dart';
import 'package:dify_sf_app/src/workflow_editor/block_selector/candidate_node.dart';
import 'package:dify_sf_app/src/workflow_editor/context_menu/context_menu.dart';
import 'package:dify_sf_app/src/workflow_editor/note_node/note_node.dart';
import 'package:dify_sf_app/src/workflow_editor/operator/control.dart';
import 'package:dify_sf_app/src/workflow_editor/operator/actions.dart' show OperatorOptions;
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

export 'package:dify_sf_app/src/cards/bodies/note_text.dart';
export 'package:dify_sf_app/src/workflow_editor/note_node/note_node.dart';

/// A note as Dify's DSL has it once imported: `type: ''`, the note's data in the config, React Flow's type in
/// `_dify_node`.
Node note(
  String id, {
  int x = 100,
  int y = 100,
  String text = '',
  String theme = 'blue',
  String author = 'Alice',
  bool showAuthor = true,
  int w = 240,
  int h = 88,
}) => Node(
  id: id,
  type: '',
  title: '',
  x: x,
  y: y,
  config: {
    'desc': const VString(''),
    'text': VString(text),
    'theme': VString(theme),
    'author': VString(author),
    'showAuthor': VBool(showAuthor),
    'width': VInt(w),
    'height': VInt(h),
    '_dify_node': const VMap({'type': VString('custom-note')}),
  },
);

/// An [EditorController] that counts the config writes it is asked for.
class CountingController extends EditorController {
  CountingController({required super.session, required super.docId, required super.journaled});

  final writes = <(String, List<String>)>[];

  @override
  void setConfig(String nodeId, List<String> path, Value value, {int? base}) {
    writes.add((nodeId, path));
    super.setConfig(nodeId, path, value, base: base);
  }
}

/// An 800 x 600 editor whose canvas coordinates are its screen coordinates (a React Flow viewport of 0, 0, 1): the
/// canvas (widget renderer) with the note overlay, over a document in an in-memory session.
class NoteHarness {
  NoteHarness._(this.demo, this.opened, this.controller, this.preferences);

  final DemoBackend demo;
  final OpenedSession opened;
  final CountingController controller;
  final WorkflowPreferences preferences;
  final canvas = CanvasController();
  final store = WorkflowStore();
  String? clipboard;

  Document get doc => controller.doc;
  Node? operator [](String id) => doc.nodes[id];

  static Future<NoteHarness> start(WidgetTester t, List<Node> nodes, {List<Edge> edges = const []}) async {
    t.view.physicalSize = const Size(800, 600);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    SharedPreferences.setMockInitialValues({});
    CanvasDefaults.viewport = (0, 0, 1);
    addTearDown(() => CanvasDefaults.viewport = null);
    final demo = DemoBackend(
      server: FakeServer(
        initial: Document(nodes: nodes, edges: edges),
      ),
      withBo: false,
    );
    final opened = await demo.openSession('demo', clientId: 'me-abc123', journaled: false);
    await opened.session.start();
    final h = NoteHarness._(
      demo,
      opened,
      CountingController(session: opened.session, docId: 'demo', journaled: false),
      WorkflowPreferences(),
    );
    for (var i = 0; i < 50 && !h.controller.ready; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') h.clipboard = (call.arguments as Map)['text'] as String?;
      if (call.method == 'Clipboard.getData') return h.clipboard == null ? null : {'text': h.clipboard};
      return null;
    });
    await t.pumpWidget(h.app());
    await settle(t);
    return h;
  }

  Widget app() => MaterialApp(
    home: WorkflowStoreScope(
      store: store,
      preferences: preferences,
      child: WorkflowShortcuts(
        controller: controller,
        canvas: canvas,
        child: Stack(
          fit: StackFit.expand,
          children: [
            WorkflowCanvas(controller: controller, canvas: canvas, renderer: CanvasRendererKind.widgets),
            LiveNoteBinding(controller: controller, canvas: canvas),
            // dify_editor.dart's wiring of Add Note: the control bar's button, the candidate placed on click.
            CandidateNode(canvas: canvas, onPlace: _place),
            Positioned(
              left: 8,
              top: 200,
              child: Builder(
                builder: (context) => WorkflowControl(
                  canvas: canvas,
                  options: OperatorOptions(onAddNote: () => addNoteCandidate(context, controller)),
                ),
              ),
            ),
            // The app's toast host (home_page.dart).
            const DifyToastHost(),
          ],
        ),
      ),
    ),
  );

  void _place(CandidatePlacement p) => controller.addNodes([
    nodeFromDify(p.node, doc, id: p.node['id']! as String),
  ], event: p.historyEvent == 'NoteAdd' ? HistoryEvent.noteAdd : HistoryEvent.nodeAdd);

  /// Clicks a note's card at [offset] from its top-left (by default in its text area).
  Future<void> clickNote(WidgetTester t, String id, {Offset offset = const Offset(40, 30)}) async {
    final n = doc.nodes[id]!;
    await t.tapAt(Offset(n.x.toDouble(), n.y.toDouble()) + offset);
    await settle(t);
  }

  bool get overlayShown => find.byType(NoteNode).evaluate().isNotEmpty;

  NoteEditorController get editor =>
      (find.byType(TextField).evaluate().single.widget as TextField).controller! as NoteEditorController;

  static Future<void> settle(WidgetTester t) async {
    for (var i = 0; i < 4; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> dispose(WidgetTester t) async {
    await t.pumpWidget(const SizedBox());
    controller.dispose();
    canvas.dispose();
    store.dispose();
    preferences.dispose();
    await opened.close();
    await demo.dispose();
    await t.pump(const Duration(seconds: 20));
  }
}

/// Dify's note editor state for [runs] (text and style), as `data.text` holds it.
String lexical(List<(String, NoteStyle)> runs) {
  final text = StringBuffer();
  final styles = <NoteStyle>[];
  for (final (s, style) in runs) {
    text.write(s);
    styles.addAll(List.filled(s.length, style));
  }
  return NoteText(text.toString(), styles).toLexical();
}

/// Plain text with [text] as one paragraph.
String plain(String text) => lexical([(text, NoteStyle.plain)]);

/// Hosts [child] under a note editor for [value] (NoteEditorContextProvider) in an app; the editor's controller.
Future<NoteEditorController> pumpInEditor(
  WidgetTester t,
  Widget child, {
  String value = '',
  bool editable = true,
  void Function(String url)? openUrl,
  VoidCallback? onInvalidUrl,
}) async {
  late NoteEditorController c;
  await t.pumpWidget(
    MaterialApp(
      home: Material(
        child: Align(
          alignment: Alignment.center,
          child: NoteEditorProvider(
            value: value,
            editable: editable,
            openUrl: openUrl,
            onInvalidUrl: onInvalidUrl,
            child: Builder(
              builder: (context) {
                c = NoteEditorScope.of(context).controller;
                return child;
              },
            ),
          ),
        ),
      ),
    ),
  );
  await t.pump(Duration.zero);
  return c;
}

/// The editor surface in a note's editor area (214 x 60); like in a note, its link popup (above it, outside the box)
/// takes pointer events.
const editorBox = OverflowHitStack(
  children: [
    SizedBox(width: 214, height: 60),
    Positioned.fill(child: NoteEditor()),
  ],
);
