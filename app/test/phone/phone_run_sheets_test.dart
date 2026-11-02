// The phone editor's run and panels as sheets (batch 4b, mockup 7-run): Run opens the inputs as a modal sheet, the
// run shows in a persistent sheet at its peek over the Steps view (which stays usable, its cards with live status and
// time), dragged up it shows Input | Result | Detail | Tracing, Stop, the finished state and close; a single step's
// form as a sheet and its result in the run sheet; the variable panels, variable inspect, the comment list, run
// history and the version list as sheets; Android back closes the newest first. At 411x914 and 360x780 with gesture
// insets and the real Noto Sans.

import 'package:collab_client/collab_client.dart';
import 'package:collab_client/testing.dart';
import 'package:dify_sf_app/src/demo/demo_backend.dart';
import 'package:dify_sf_app/src/design/dify_theme.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/editor/editor_controller.dart';
import 'package:dify_sf_app/src/editor/editor_page.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/canvas/canvas_controller.dart';
import 'package:dify_sf_app/src/canvas/canvas_input.dart' show ControlMode;
import 'package:dify_sf_app/src/canvas/workflow_canvas.dart';
import 'package:dify_sf_app/src/workflow_editor/dify_editor.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/workflow_panels.dart';
import 'package:dify_sf_app/src/workflow_editor/phone/phone_editor_controller.dart';
import 'package:dify_sf_app/src/workflow_editor/phone/phone_editor_frame.dart';
import 'package:dify_sf_app/src/workflow_editor/phone/phone_editor_sheets.dart';
import 'package:dify_sf_app/src/workflow_editor/run/mock_run_service.dart';
import 'package:dify_sf_app/src/workflow_editor/run/run_scope.dart';
import 'package:dify_sf_app/src/workflow_editor/run/run_types.dart';
import 'package:dify_sf_app/src/workflow_editor/run/ui/before_run_form.dart';
import 'package:dify_sf_app/src/workflow_editor/run/ui/debug_and_preview.dart';
import 'package:dify_sf_app/src/workflow_editor/run/ui/run_panel.dart';
import 'package:dify_sf_app/src/workflow_editor/run/ui/tracing_node.dart';
import 'package:dify_sf_app/src/workflow_editor/run/ui/tracing_panel.dart';
import 'package:dify_sf_app/src/workflow_editor/run/ui/workflow_preview.dart';
import 'package:dify_sf_app/src/workflow_editor/steps/workflow_steps_view.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:dify_sf_app/src/workflow_editor/variable_inspect/panel.dart';
import 'package:dify_sf_app/src/workflow_editor/variable_inspect/value_content.dart' show ValueContent;
import 'package:dify_sf_app/src/workflow_editor/variable_panels/variable_panels.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/app_fonts.dart';
import 'phone_harness.dart';

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
  _Editor(this.t, this.backend, this.size);
  final WidgetTester t;
  final _Backend backend;
  final Size size;

  EditorController get c => t.widget<DifyWorkflowEditor>(find.byType(DifyWorkflowEditor)).controller;
  WorkflowStore get store => WorkflowStoreScope.of(t.element(find.byType(PhoneEditorFrame)));
  PhoneEditorController get phone => PhoneEditorScope.read(t.element(find.byType(PhoneEditorFrame)))!;
  WorkflowRunScope get scope => WorkflowRunScope.of(t.element(find.byType(PhoneEditorFrame)));
  CanvasController get canvas => t.state<WorkflowCanvasState>(find.byType(WorkflowCanvas, skipOffstage: false)).canvas;
  MockWorkflowRunService get mock => scope.service as MockWorkflowRunService;

  Finder sheet(String key) => find.byKey(ValueKey(key));
  Finder get runSheet => sheet('phone-run-sheet');
  Finder get runHeader => find.byKey(const ValueKey('phone-run-sheet-header'));

  /// [key]'s grab handle: inside a docked sheet (the key is the DifyPersistentSheet's), or in the sheet around a modal
  /// sheet's content (a DifySheetPortal's: the key is its content's).
  Finder handle(String key) {
    final inside = find.descendant(of: sheet(key), matching: find.byType(DifySheetGrabHandle));
    if (inside.evaluate().isNotEmpty) return inside;
    return find.descendant(
      of: find.ancestor(of: sheet(key), matching: find.byType(DraggableScrollableSheet)).first,
      matching: find.byType(DifySheetGrabHandle),
    );
  }

  /// The top of [key]'s sheet surface on screen (its grab handle's row).
  double top(String key) => t.getTopLeft(handle(key)).dy;

  /// The bottom bar's top (the run, version and comment sheets rest on it).
  double get barTop {
    final bars = find.byType(DifyBottomToolbar).evaluate().isNotEmpty
        ? find.byType(DifyBottomToolbar)
        : find.byType(DifySelectionBar);
    return t.getTopLeft(bars.first).dy;
  }

  /// Drags [key]'s sheet by its grab handle by [dy], in finger-sized steps.
  Future<void> drag(String key, double dy) async {
    final g = await t.startGesture(t.getCenter(handle(key)));
    for (var i = 0; i < 20; i++) {
      await g.moveBy(Offset(0, dy / 20));
      await t.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await settle(t, 600);
  }

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
  final e = _Editor(t, backend, size);
  // The fixture's model is not configured in a workspace: let the mock runtime's preflight pass.
  e.store.computeRunChecklist = () => const [];
  return e;
}

String _tw(String key) => DifyI18n.tr('workflow', key);
String _tp(String key) => DifyI18n.tr('phone-editor', key);
String _tc(String key) => DifyI18n.tr('common', key);
String _tr(String key) => DifyI18n.tr('run-log', key);

const _windows = [Size(411, 914), Size(360, 780)];

/// The close button of the sheet header in [of].
Finder _close(Finder of) => find.descendant(
  of: of,
  matching: find.byWidgetPredicate((w) => w is DifyTouchIconButton && w.label == _tc('operation.close')),
);

/// The run sheet's tab [key] (run-log `input` / `result` / `detail` / `tracing`) in its header.
Finder _tab(_Editor e, String key) => find.descendant(of: e.runHeader, matching: find.text(_tr(key)));

void main() {
  setUpAll(() async {
    await DifyI18n.load('en-US');
    await useAppFonts();
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // Run times count on the test binding's clock (it moves with the pumps).
    PhoneEditorSheets.now = () => TestWidgetsFlutterBinding.instance.clock.now();
  });
  tearDown(() => PhoneEditorSheets.now = DateTime.now);

  for (final size in _windows) {
    final name = '${size.width.toInt()}x${size.height.toInt()}';

    testWidgets('$name: Run → the inputs sheet → Start Run → the run at its peek over a usable Steps view', (t) async {
      final e = await _pump(t, size: size);
      e.mock.scenario = const MockRunScenario(stepDelay: Duration(milliseconds: 400));
      expect(find.byType(WorkflowStepsView), findsOneWidget);

      // Run: the Start node's inputs in a modal sheet; no keyboard pops up by itself.
      await t.tap(find.byKey(const ValueKey('phone-run')));
      await settle(t, 800);
      expect(e.sheet('phone-run-input-sheet'), findsOneWidget);
      expect(find.byType(InputsPanel), findsOneWidget);
      expect(find.byKey(const ValueKey('dify-sheet-scrim')), findsOneWidget);
      expect(t.testTextInput.isVisible, isFalse);
      // Edge to edge: the sheet reaches the bottom edge, Start Run stays above the gesture bar.
      final start = find.text(_tw('singleRun.startRun'));
      expect(t.getBottomLeft(start).dy, lessThanOrEqualTo(size.height - gestureInsets.bottom));
      expect(e.runSheet, findsNothing);

      await t.enterText(
        find.descendant(of: e.sheet('phone-run-input-sheet'), matching: find.byType(EditableText)),
        'hello from phone',
      );
      await t.pump();
      // The keyboard: the sheet rides on it, Start Run stays above it.
      openKeyboard(t, insets: gestureInsets);
      await settle(t, 600);
      expect(t.getBottomLeft(start).dy, lessThanOrEqualTo(size.height - 300));
      closeKeyboard(t, insets: gestureInsets);
      await settle(t, 600);
      await t.tap(start);
      await t.pump();
      expect(e.mock.requests, hasLength(1));
      await settle(t, 600);

      // The run: its sheet at the peek, resting on the toolbar; the app bar's Run became Stop.
      expect(e.sheet('phone-run-input-sheet'), findsNothing);
      expect(e.runSheet, findsOneWidget);
      expect(find.byKey(const ValueKey('phone-stop')), findsOneWidget);
      expect(e.top('phone-run-sheet'), closeTo(e.barTop - 72, 1));
      expect(find.descendant(of: e.runHeader, matching: find.textContaining(_tw('common.running'))), findsOneWidget);
      expect(find.byKey(const ValueKey('phone-run-sheet-stop')), findsOneWidget);
      // The tabs are below the peek.
      expect(_tab(e, 'detail').hitTestable(), findsNothing);

      // The Steps view above stays usable while it runs: a step shows its live status, a tap selects it.
      expect(find.byKey(const ValueKey('step-status-running')), findsWidgets);
      await t.tap(find.text('Count Android'));
      await settle(t, 400);
      expect(e.c.selectedNodeId, 'code');
      if (e.phone.settingsNodeId != null) {
        expect(await systemBack(t), isTrue, reason: 'the settings opened by the tap');
        await settle(t, 400);
      }
      expect(e.runSheet, findsOneWidget);

      // It finishes: the sheet stays at its peek with the outcome; the cards show each step's time.
      await settle(t, 3000);
      expect(runningStatusOf(e.store.workflowRunningData.value), WorkflowRunningStatus.succeeded);
      expect(find.descendant(of: e.runHeader, matching: find.textContaining(_tp('runSucceeded'))), findsOneWidget);
      expect(e.top('phone-run-sheet'), closeTo(e.barTop - 72, 1));
      expect(find.byKey(const ValueKey('phone-run')), findsOneWidget);
      // (The settings sheet opened above revealed Count Android: back to the top of the list, every card built.)
      await t.drag(find.byType(WorkflowStepsView), const Offset(0, 1500));
      await settle(t, 600);
      expect(find.byKey(const ValueKey('step-status-succeeded')), findsNWidgets(4));
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('step-card-start')),
          matching: find.textContaining(RegExp(r' · \d\.\d s$')),
        ),
        findsOneWidget,
      );

      // The Steps view scrolls its last step above the resting sheet.
      await t.drag(find.byType(WorkflowStepsView), const Offset(0, -1500));
      await settle(t, 600);
      expect(
        t.getRect(find.byKey(const ValueKey('step-card-end'))).bottom,
        lessThanOrEqualTo(e.top('phone-run-sheet')),
      );

      // Dragged up: Input | Result | Detail | Tracing, the desktop panel's own content.
      await e.drag('phone-run-sheet', -500);
      expect(_tab(e, 'input').hitTestable(), findsOneWidget);
      // The tabs take the tab component's touch size.
      for (final key in const ['input', 'result', 'detail', 'tracing']) {
        final tab = find.ancestor(of: _tab(e, key), matching: find.byType(DifyTab)).first;
        expect(t.getSize(tab).height, greaterThanOrEqualTo(DifyTab.touchHeight), reason: key);
      }
      expect(_tab(e, 'result').hitTestable(), findsOneWidget);
      await t.tap(_tab(e, 'detail'));
      await settle(t, 300);
      expect(find.text('SUCCESS'), findsWidgets);
      await t.ensureVisible(_tab(e, 'tracing'));
      await t.pump();
      await t.tap(_tab(e, 'tracing'));
      await settle(t, 300);
      expect(find.byType(TracingPanel), findsOneWidget);
      expect(t.widgetList<RunNodePanel>(find.byType(RunNodePanel)).map((r) => r.nodeInfo['node_id']).first, 'start');
      // Its rows are touch rows.
      expect(t.getSize(find.byType(RunNodePanel).first).height, greaterThanOrEqualTo(44));

      // Back collapses it to the peek, then closes it (the run's statuses go with it).
      expect(await systemBack(t), isTrue);
      await settle(t, 600);
      expect(e.top('phone-run-sheet'), closeTo(e.barTop - 72, 1));
      expect(await systemBack(t), isTrue);
      await settle(t, 600);
      expect(e.runSheet, findsNothing);
      expect(e.store.showDebugAndPreviewPanel.value, isFalse);
      // The run's statuses and times went with it, although the steps keep inspect values (Dify's success marks for
      // those are not shown on a phone: they read as the closed run's).
      expect(e.store.nodesWithInspectVars.value, isNotEmpty);
      expect(find.byKey(const ValueKey('step-status-succeeded')), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('step-card-start')),
          matching: find.textContaining(RegExp(r' · \d\.\d s$')),
        ),
        findsNothing,
      );
      expect(t.takeException(), isNull);
      await e.dispose();
    });

    testWidgets('$name: Stop in the run sheet; the stopped run stays at its peek until closed', (t) async {
      final e = await _pump(t, size: size);
      e.mock.scenario = const MockRunScenario(stepDelay: Duration(seconds: 2));
      await t.tap(find.byKey(const ValueKey('phone-run')));
      await settle(t, 800);
      await t.enterText(
        find.descendant(of: e.sheet('phone-run-input-sheet'), matching: find.byType(EditableText)),
        'q',
      );
      await t.pump();
      await t.tap(find.text(_tw('singleRun.startRun')));
      await settle(t, 1000);
      expect(find.byKey(const ValueKey('phone-run-sheet-stop')), findsOneWidget);
      // While it runs the header counts the time; there is no close, only Stop.
      expect(find.descendant(of: e.runHeader, matching: find.textContaining(RegExp(r' · \d\.\d s$'))), findsOneWidget);
      expect(_close(e.runHeader), findsNothing);

      await t.tap(find.byKey(const ValueKey('phone-run-sheet-stop')));
      await settle(t, 600);
      expect(runningStatusOf(e.store.workflowRunningData.value), WorkflowRunningStatus.stopped);
      expect(find.descendant(of: e.runHeader, matching: find.textContaining(_tp('runStopped'))), findsOneWidget);
      expect(find.byKey(const ValueKey('phone-run-sheet-stop')), findsNothing);
      expect(find.byKey(const ValueKey('phone-run')), findsOneWidget, reason: 'the app bar has Run again');
      expect(e.top('phone-run-sheet'), closeTo(e.barTop - 72, 1));
      // The step that was running when it stopped shows no spinner any more.
      await settle(t, 1500);
      expect(find.byKey(const ValueKey('step-status-running')), findsNothing);
      expect(e.canvas.nodeRun.value.values.where((v) => v.isLoading), isEmpty);

      // Close: the sheet goes, and the run with it.
      await t.tap(_close(e.runHeader));
      await settle(t, 600);
      expect(e.runSheet, findsNothing);
      expect(e.store.workflowRunningData.value, isNull);
      expect(t.takeException(), isNull);
      await e.dispose();
    });

    testWidgets('$name: Back hides a running run; its chip in the view row counts and reopens it at its peek', (
      t,
    ) async {
      final e = await _pump(t, size: size);
      e.mock.scenario = const MockRunScenario(stepDelay: Duration(milliseconds: 600));
      final chip = find.byKey(const ValueKey('phone-run-chip'));
      Finder runChip() => find.descendant(of: chip, matching: find.byType(DifyFilterChip)).hitTestable().first;
      await t.tap(find.byKey(const ValueKey('phone-run')));
      await settle(t, 800);
      await t.enterText(
        find.descendant(of: e.sheet('phone-run-input-sheet'), matching: find.byType(EditableText)),
        'q',
      );
      await t.pump();
      await t.tap(find.text(_tw('singleRun.startRun')));
      await settle(t, 600);
      expect(e.runSheet, findsOneWidget);
      expect(chip, findsNothing, reason: 'no chip while the sheet shows');

      // Back at the peek while it runs hides the sheet; the run goes on, and its chip sits beside the issues chip.
      expect(await systemBack(t), isTrue);
      await settle(t, 400);
      expect(e.runSheet, findsNothing);
      expect(runningStatusOf(e.store.workflowRunningData.value), WorkflowRunningStatus.running);
      expect(chip, findsOneWidget);
      final running = find.bySemanticsLabel(RegExp(r'^Running · \d+ s$'));
      expect(running, findsOneWidget);
      final row = t.getRect(find.byKey(const ValueKey('phone-view-switch')));
      final shown = t.getRect(runChip());
      expect(shown.left, greaterThan(row.right), reason: 'after the Steps | Canvas switch');
      expect(t.getRect(chip).right, lessThanOrEqualTo(size.width - 16 + 0.5), reason: 'inside the row');
      expect(t.takeException(), isNull, reason: 'the row does not overflow');
      // It counts while the run goes.
      final before = t.getSemantics(running).label;
      await settle(t, 1100);
      expect(t.getSemantics(find.bySemanticsLabel(RegExp(r'^Running · \d+ s$'))).label, isNot(before));

      // A tap reopens the sheet at its peek; Back hides it again.
      await t.tap(runChip());
      await settle(t, 600);
      expect(e.runSheet, findsOneWidget);
      expect(e.top('phone-run-sheet'), closeTo(e.barTop - 72, 1));
      expect(chip, findsNothing);
      expect(await systemBack(t), isTrue);
      await settle(t, 400);
      expect(e.runSheet, findsNothing);

      // It ends while hidden: the chip says so, and stops counting.
      await settle(t, 3000);
      expect(runningStatusOf(e.store.workflowRunningData.value), WorkflowRunningStatus.succeeded);
      expect(find.bySemanticsLabel(_tp('runSucceeded')), findsOneWidget);
      // At 360 dp its short form is its time beside the outcome's icon, never a bare check like the issues chip's.
      final label = t.widget<DifyFilterChip>(runChip()).label;
      if (size.width < 400) {
        expect(label, matches(RegExp(r'^\d+\.\d s$')));
        expect(
          find.descendant(of: chip, matching: find.byKey(const ValueKey('phone-run-state-succeeded'))),
          findsWidgets,
        );
      }
      expect(t.takeException(), isNull);
      // Reopened, then closed: the run is cleared and the chip goes.
      await t.tap(runChip());
      await settle(t, 600);
      expect(find.descendant(of: e.runHeader, matching: find.textContaining(_tp('runSucceeded'))), findsOneWidget);
      expect(await systemBack(t), isTrue);
      await settle(t, 600);
      expect(e.runSheet, findsNothing);
      expect(e.store.workflowRunningData.value, isNull);
      expect(chip, findsNothing);
      expect(find.byKey(const ValueKey('phone-issues')), findsOneWidget);
      expect(t.takeException(), isNull);
      await e.dispose();
    });

    testWidgets('$name: Run step: its form as a sheet (back closes it), its result in the run sheet', (t) async {
      final e = await _pump(t, size: size);
      e.mock.scenario = const MockRunScenario(stepDelay: Duration(milliseconds: 300));
      Future<void> runStep() async {
        await t.longPress(find.text('Summarize'));
        await settle(t, 800);
        await t.tap(find.text(_tw('panel.runThisStep')));
        await settle(t, 800);
      }

      // The LLM reads start.query, which has no value: its form asks for it, in a sheet; back closes it.
      await runStep();
      expect(e.sheet('phone-step-input-sheet'), findsOneWidget);
      expect(
        find.descendant(
          of: find.ancestor(of: find.text(_tw('singleRun.testRun')), matching: find.byType(DifySheetHeader)),
          matching: find.text('Summarize'),
        ),
        findsOneWidget,
      );
      expect(e.phone.settingsNodeId, isNull, reason: 'the settings stay closed');
      expect(await systemBack(t), isTrue);
      await settle(t, 600);
      expect(e.sheet('phone-step-input-sheet'), findsNothing);
      expect(e.runSheet, findsNothing);

      await runStep();
      await t.enterText(
        find.descendant(of: e.sheet('phone-step-input-sheet'), matching: find.byType(EditableText)).first,
        'hello',
      );
      await t.pump();
      await t.tap(find.text(_tw('singleRun.startRun')));
      await settle(t, 600);
      expect(e.sheet('phone-step-input-sheet'), findsNothing);
      expect(e.runSheet, findsOneWidget);
      expect(e.phone.singleRunNodeId, 'llm');
      expect(find.descendant(of: e.runHeader, matching: find.text('Summarize')), findsOneWidget);
      await settle(t, 2500);
      expect(e.store.nodeRunDataOf('llm')['_singleRunningStatus'], NodeRunningStatus.succeeded);
      expect(find.descendant(of: e.runHeader, matching: find.textContaining(_tp('runSucceeded'))), findsOneWidget);
      // Dragged up: the node's Last Run (its status box).
      await e.drag('phone-run-sheet', -500);
      expect(find.text('SUCCESS'), findsWidgets);
      // Back: down to the peek, then the sheet closes.
      expect(await systemBack(t), isTrue);
      await settle(t, 600);
      expect(await systemBack(t), isTrue);
      await settle(t, 600);
      expect(e.runSheet, findsNothing);
      expect(e.phone.singleRunNodeId, isNull);
      expect(t.takeException(), isNull);
      await e.dispose();
    });

    testWidgets('$name: the variable panels and variable inspect are sheets; back closes them', (t) async {
      final e = await _pump(t, size: size);
      Future<void> overflow(String item) async {
        await t.tap(find.byKey(const ValueKey('phone-editor-more')));
        await settle(t, 800);
        await t.ensureVisible(find.text(item));
        await t.pump();
        await t.tap(find.text(item));
        await settle(t, 800);
      }

      // Environment variables: a modal sheet at half the window, pulled up to full; back slides it away.
      await overflow(_tw('env.envPanelTitle'));
      expect(e.store.showEnvPanel.value, isTrue);
      expect(e.sheet('phone-variables-sheet'), findsOneWidget);
      expect(find.byType(EnvPanel), findsOneWidget);
      expect(find.byKey(const ValueKey('phone-panels')), findsNothing, reason: 'no full-area panel');
      expect(e.top('phone-variables-sheet'), closeTo(size.height / 2 - gestureInsets.bottom, 1));
      expect(find.byType(WorkflowStepsView).hitTestable(), findsNothing, reason: 'the scrim blocks the editor');
      await e.drag('phone-variables-sheet', -600);
      expect(e.top('phone-variables-sheet'), closeTo(gestureInsets.top, 1));
      expect(await systemBack(t), isTrue);
      await settle(t, 600);
      expect(e.store.showEnvPanel.value, isFalse);
      expect(e.sheet('phone-variables-sheet'), findsNothing);

      // System variables: the sheet's own close button.
      await overflow(_tw('globalVar.title'));
      expect(find.byType(GlobalVariablePanel), findsOneWidget);
      await t.tap(
        _close(e.sheet('phone-variables-sheet')),
      );
      await settle(t, 600);
      expect(e.store.showGlobalVariablePanel.value, isFalse);
      expect(e.sheet('phone-variables-sheet'), findsNothing);

      // A drag down below its lowest detent closes it too.
      await overflow(_tw('globalVar.title'));
      await e.drag('phone-variables-sheet', 600);
      expect(e.store.showGlobalVariablePanel.value, isFalse);

      // Variable inspect: a full sheet; back closes it.
      await overflow(_tw('debug.variableInspect.title'));
      expect(e.sheet('phone-inspect-sheet'), findsOneWidget);
      expect(find.byType(InspectPanel), findsOneWidget);
      expect(await systemBack(t), isTrue);
      await settle(t, 600);
      expect(e.store.showVariableInspectPanel.value, isFalse);
      expect(e.sheet('phone-inspect-sheet'), findsNothing);
      expect(t.takeException(), isNull);
      await e.dispose();
    });

    testWidgets('$name: comments, run history and the version list are sheets over a usable editor', (t) async {
      final e = await _pump(t, size: size);
      // Comment mode: the comment list starts at its peek on the canvas page (the canvas is what comment mode is for);
      // back ends comment mode.
      await t.tap(find.byKey(const ValueKey('phone-editor-more')));
      await settle(t, 800);
      await t.ensureVisible(find.text(_tw('common.commentMode')));
      await t.tap(find.text(_tw('common.commentMode')));
      await settle(t, 800);
      expect(e.sheet('phone-comments-sheet'), findsOneWidget);
      expect(find.byKey(const ValueKey('dify-sheet-scrim')), findsNothing, reason: 'the canvas stays usable');
      expect(e.top('phone-comments-sheet'), closeTo(e.barTop - 72, 1));
      expect(await systemBack(t), isTrue);
      await settle(t, 600);
      expect(e.sheet('phone-comments-sheet'), findsNothing);
      expect(e.store.controlMode.value, isNot(ControlModeFinder.comment));

      // Run history: a past run opens in the run sheet with its Result | Detail | Tracing.
      e.mock.scenario = const MockRunScenario(stepDelay: Duration.zero);
      await e.scope.run.handleRun({
        'inputs': {'query': 'q'},
      });
      await settle(t, 1000);
      e.scope.run.handleCancelDebugAndPreviewPanel();
      await settle(t, 300);
      await t.tap(find.byKey(const ValueKey('phone-editor-more')));
      await settle(t, 800);
      await t.ensureVisible(find.text(_tw('common.runHistory')));
      await t.tap(find.text(_tw('common.runHistory')));
      await settle(t, 800);
      await t.tap(find.textContaining('Test Run (', findRichText: true).first);
      await settle(t, 1000);
      expect(e.store.historyWorkflowData.value, isNotNull);
      expect(e.runSheet, findsOneWidget);
      expect(find.byType(RunPanel), findsOneWidget);
      expect(find.byKey(const ValueKey('phone-history-bar')), findsOneWidget);
      expect(e.top('phone-run-sheet'), closeTo(e.barTop - 72, 1), reason: 'the viewed run lands at its peek');
      expect(t.takeException(), isNull);
      await e.drag('phone-run-sheet', -500);
      await t.tap(_tab(e, 'detail'));
      await settle(t, 300);
      expect(find.text('SUCCESS'), findsWidgets);
      expect(await systemBack(t), isTrue);
      await settle(t, 600);
      expect(await systemBack(t), isTrue);
      await settle(t, 600);
      expect(e.store.historyWorkflowData.value, isNull);
      expect(e.runSheet, findsNothing);

      // Versions: the list at half over the browsed graph, Restore in the app bar; picking a version collapses it to
      // its peek; back: closes the list, then leaves the versions.
      await t.tap(find.text(_tp('versions')));
      await settle(t, 800);
      expect(e.store.isRestoring.value, isTrue);
      expect(e.sheet('phone-versions-sheet'), findsOneWidget);
      expect(find.byKey(const ValueKey('phone-restore')), findsOneWidget);
      expect(find.byKey(const ValueKey('phone-restoring-bar')), findsOneWidget);
      final half = e.top('phone-versions-sheet');
      expect(half, lessThan(e.barTop - 200));
      // The browsed graph shows no run statuses (the run before left inspect values).
      expect(e.store.nodesWithInspectVars.value, isNotEmpty);
      expect(e.canvas.nodeRun.value, isEmpty);
      expect(find.byKey(const ValueKey('step-status-succeeded')), findsNothing);
      final header = find.byKey(const ValueKey('version-sheet-header'));
      expect(
        find.descendant(of: header, matching: find.text(DifyI18n.tr('workflow', 'versionHistory.currentDraft'))),
        findsOneWidget,
      );
      e.store.currentVersion.value = {'id': 'v-picked', 'version': '2026-11-02 12:00', 'marked_name': 'v1 slow count'};
      await settle(t, 600);
      expect(e.top('phone-versions-sheet'), closeTo(e.barTop - 72, 1));
      // The peek names the shown version.
      expect(find.descendant(of: header, matching: find.text('v1 slow count')), findsOneWidget);
      expect(await systemBack(t), isTrue, reason: 'closes the version list');
      await settle(t, 600);
      expect(e.sheet('phone-versions-sheet'), findsNothing);
      expect(e.store.isRestoring.value, isTrue);
      expect(await systemBack(t), isTrue, reason: 'leaves the versions');
      await settle(t, 600);
      expect(e.store.isRestoring.value, isFalse);
      expect(t.takeException(), isNull);
      await e.dispose();
    });
  }

  // ----- device-check fixes -----

  Future<void> overflow(WidgetTester t, String item) async {
    await t.tap(find.byKey(const ValueKey('phone-editor-more')));
    await settle(t, 800);
    await t.ensureVisible(find.text(item));
    await t.pump();
    await t.tap(find.text(item));
    await settle(t, 800);
  }

  Future<void> runOnce(_Editor e, WidgetTester t, {String query = 'hello from phone'}) async {
    e.mock.scenario = const MockRunScenario(stepDelay: Duration.zero);
    await e.scope.run.handleRun({
      'inputs': {'query': query},
    });
    await settle(t, 1000);
    e.scope.run.handleCancelDebugAndPreviewPanel();
    await settle(t, 300);
  }

  for (final size in _windows) {
    testWidgets(
      '${size.width.toInt()}: Variable Inspect is a list, a variable a page with Back; one header, touch rows',
      (
        t,
      ) async {
        final e = await _pump(t, size: size);
        final title = _tw('debug.variableInspect.title');
        Finder titles(Finder of) => find.descendant(
          of: of,
          matching: find.byWidgetPredicate((w) => w is Text && (w.data ?? '').toLowerCase() == title.toLowerCase()),
        );
        // Nothing to inspect yet: the empty state, full width.
        await overflow(t, title);
        final sheet = e.sheet('phone-inspect-sheet');
        expect(find.descendant(of: sheet, matching: find.byType(InspectEmpty)), findsOneWidget);
        expect(t.getSize(find.byType(InspectEmpty)).width, greaterThan(size.width - 48));
        expect(systemBack, isNotNull);
        expect(await systemBack(t), isTrue);
        await settle(t, 600);

        await runOnce(e, t);
        await overflow(t, title);
        expect(find.byKey(const ValueKey('inspect-phone-list')), findsOneWidget);
        expect(titles(sheet), findsOneWidget, reason: 'one title: the sheet header\'s');
        expect(_close(sheet), findsOneWidget, reason: 'one close');
        expect(
          find.descendant(of: find.byType(DifySheetHeader), matching: find.byKey(const ValueKey('inspect-reset-all'))),
          findsOneWidget,
        );
        // Touch rows; the list takes the sheet's width.
        final row = find.ancestor(of: find.text('query').first, matching: find.byType(DifyPressable)).first;
        expect(t.getSize(row).height, greaterThanOrEqualTo(48));
        expect(t.getSize(row).width, greaterThan(size.width - 48));
        // A variable opens as a page: its name in the header, its value the sheet's width; Back returns to the list.
        await t.tap(find.text('query').first);
        await settle(t, 600);
        final page = find.byKey(const ValueKey('inspect-phone-value'));
        expect(page, findsOneWidget);
        expect(find.descendant(of: page, matching: find.text('query')), findsOneWidget);
        expect(find.byType(ValueContent), findsOneWidget);
        expect(t.getSize(find.byType(ValueContent)).width, greaterThan(size.width - 48));
        expect(find.textContaining('hello from phone'), findsWidgets);
        expect(titles(sheet), findsNothing);
        expect(await systemBack(t), isTrue);
        await settle(t, 600);
        expect(find.byKey(const ValueKey('inspect-phone-list')), findsOneWidget, reason: 'back to the list');
        expect(e.store.showVariableInspectPanel.value, isTrue);
        expect(await systemBack(t), isTrue);
        await settle(t, 600);
        expect(e.store.showVariableInspectPanel.value, isFalse);
        expect(t.takeException(), isNull);
        await e.dispose();
      },
    );
  }

  testWidgets('run statuses: a new run starts with every status reset, a chatflow\'s preview leaves none', (t) async {
    final e = await _pump(t);
    await runOnce(e, t);
    expect(e.store.nodesWithInspectVars.value, isNotEmpty);
    expect(find.byKey(const ValueKey('step-status-succeeded')), findsNothing, reason: 'the closed run left none');
    // A new run: while its first step runs, nothing shows the last run's success (End least of all).
    e.mock.scenario = const MockRunScenario(stepDelay: Duration(milliseconds: 800));
    await t.tap(find.byKey(const ValueKey('phone-run')));
    await settle(t, 800);
    await t.enterText(find.descendant(of: e.sheet('phone-run-input-sheet'), matching: find.byType(EditableText)), 'q');
    await t.pump();
    await t.tap(find.text(_tw('singleRun.startRun')));
    await settle(t, 300);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('step-card-end')),
        matching: find.byKey(const ValueKey('step-status-succeeded')),
      ),
      findsNothing,
    );
    expect(e.canvas.nodeRun.value['end']?.status ?? 'idle', 'idle');
    for (
      var i = 0;
      i < 40 && runningStatusOf(e.store.workflowRunningData.value) == WorkflowRunningStatus.running;
      i++
    ) {
      await settle(t, 500);
    }
    await settle(t, 500);
    expect(runningStatusOf(e.store.workflowRunningData.value), WorkflowRunningStatus.succeeded);
    expect(find.byKey(const ValueKey('step-status-succeeded')), findsNWidgets(4), reason: 'the run\'s own statuses');
    await e.dispose();
  });

  testWidgets('a chatflow\'s statuses go when its preview closes', (t) async {
    final e = await _pump(t, chat: true);
    await t.tap(find.byKey(const ValueKey('phone-run')));
    await settle(t, 800);
    e.store.setNodeRunData('llm', {'_runningStatus': 'succeeded'});
    e.store.nodesWithInspectVars.value = [
      {'nodeId': 'llm', 'vars': const <Object?>[]},
    ];
    await settle(t, 300);
    expect(e.canvas.nodeRun.value['llm']?.status, 'succeeded');
    expect(await systemBack(t), isTrue);
    await settle(t, 600);
    expect(e.store.showDebugAndPreviewPanel.value, isFalse);
    expect(e.canvas.nodeRun.value['llm'], isNull, reason: 'neither the run\'s status nor the inspect values\' mark');
    await e.dispose();
  });

  testWidgets('the run time counts from the moment the run starts, not from an idle frame', (t) async {
    final e = await _pump(t);
    e.mock.scenario = const MockRunScenario(stepDelay: Duration(seconds: 3));
    await t.tap(find.byKey(const ValueKey('phone-run')));
    await settle(t, 800);
    // The form sits idle for 10 s.
    await t.pump(const Duration(seconds: 10));
    await t.enterText(find.descendant(of: e.sheet('phone-run-input-sheet'), matching: find.byType(EditableText)), 'q');
    await t.pump();
    await t.tap(find.text(_tw('singleRun.startRun')));
    await settle(t, 900);
    final text = t
        .widgetList<Text>(find.descendant(of: e.runHeader, matching: find.byType(Text)))
        .map((w) => w.data ?? '')
        .firstWhere((d) => d.startsWith(_tw('common.running')));
    final seconds = double.parse(RegExp(r'(\d+\.\d) s$').firstMatch(text)!.group(1)!);
    expect(seconds, inInclusiveRange(0.7, 1.1), reason: text);
    // Hidden, the chip counts on the same clock.
    expect(await systemBack(t), isTrue);
    await settle(t, 300);
    final chip = t.widget<DifyFilterChip>(
      find.descendant(of: find.byKey(const ValueKey('phone-run-chip')), matching: find.byType(DifyFilterChip)).first,
    );
    // The same clock: a second or two since the start, not the idle time before it.
    final n = int.parse(RegExp(r'· (\d+) s$').firstMatch(chip.semanticLabel!)!.group(1)!);
    expect(n, inInclusiveRange(1, 2), reason: chip.semanticLabel);
    await e.dispose();
  });

  testWidgets('during a run the phone canvas stays put while the running step is in view, else pans just enough', (
    t,
  ) async {
    final e = await _pump(t);
    await t.tap(find.text(_tp('canvas')));
    await settle(t, 600);
    e.canvas.fitView();
    await settle(t, 300);
    final center = e.canvas.view.center, scale = e.canvas.view.scale;
    await runOnce(e, t);
    expect((e.canvas.view.center - center).distance, lessThan(0.5), reason: 'every step was in view');
    expect(e.canvas.view.scale, scale);

    // Zoomed in on Start: End is off to the right. Each step that starts is brought just into view.
    e.canvas.view
      ..scale = 1
      ..center = e.canvas.graph!['start']!.rect.center;
    await settle(t, 300);
    final size = e.canvas.view.viewport;
    expect(e.canvas.view.rectToScreen(e.canvas.graph!['end']!.rect).left, greaterThan(size.width));
    e.mock.scenario = const MockRunScenario(stepDelay: Duration(milliseconds: 300));
    await t.tap(find.byKey(const ValueKey('phone-run')));
    await settle(t, 800);
    await t.enterText(find.descendant(of: e.sheet('phone-run-input-sheet'), matching: find.byType(EditableText)), 'q');
    await t.pump();
    await t.tap(find.text(_tw('singleRun.startRun')));
    await settle(t, 4000);
    expect(runningStatusOf(e.store.workflowRunningData.value), WorkflowRunningStatus.succeeded);
    final end = e.canvas.view.rectToScreen(e.canvas.graph!['end']!.rect);
    expect(end.right, closeTo(size.width - 16, 1), reason: 'brought in from the right, no further');
    expect(end.bottom, lessThanOrEqualTo(size.height - 72 - 16 + 0.5), reason: 'above the run sheet');
    expect(e.canvas.view.scale, 1, reason: 'the zoom stays');
    await e.dispose();
  });

  testWidgets('touch sizes: Start Run, the environment variable form and its cards\' actions', (t) async {
    final e = await _pump(t);
    // Start Run: 44 px, the design's button height in a phone sheet.
    await t.tap(find.byKey(const ValueKey('phone-run')));
    await settle(t, 800);
    final start = find.ancestor(of: find.text(_tw('singleRun.startRun')), matching: find.byType(DifyButton)).first;
    expect(t.getSize(start).height, 44);
    expect(await systemBack(t), isTrue);
    await settle(t, 600);

    // Add an environment variable: the form is the sheet's content (its header, 44 px Cancel / Save).
    await overflow(t, _tw('env.envPanelTitle'));
    await t.tap(find.text(_tw('env.envPanelButton')));
    await settle(t, 800);
    final form = find.byKey(const ValueKey('variable-modal-save'));
    expect(form, findsOneWidget);
    expect(find.text(_tw('env.modal.title')), findsOneWidget);
    expect(
      find.ancestor(of: find.text(_tw('env.modal.title')), matching: find.byType(DifySheetHeader)),
      findsOneWidget,
    );
    expect(t.getSize(form).height, 44);
    final fields = find.byType(EditableText);
    await t.enterText(fields.first, 'api_base');
    await t.pump();
    await t.enterText(fields.at(1), 'https://example.com');
    await t.pump();
    await t.tap(form);
    await settle(t, 800);
    expect(e.c.doc.nodes, isNotEmpty);
    // The card's edit and delete: 44 px touch buttons whose 48 px targets do not overlap.
    final buttons = find.descendant(of: e.sheet('phone-variables-sheet'), matching: find.byType(DifyTouchIconButton));
    final labels = {_tc('operation.edit'), _tc('operation.delete')};
    final actions = [
      for (final b in t.widgetList<DifyTouchIconButton>(buttons))
        if (labels.contains(b.label)) b,
    ];
    expect(actions.length, 2);
    final a = t.getRect(find.byWidget(actions[0])), b = t.getRect(find.byWidget(actions[1]));
    expect(a.height, 44);
    expect((b.center.dx - a.center.dx).abs(), greaterThanOrEqualTo(48));
    expect(t.takeException(), isNull);
    await e.dispose();
  });

  testWidgets('accessibility: the run form (modal) exposes its controls and hides the editor; the run sheet at its '
      'peek (non-modal) is read with the editor', (t) async {
    final semantics = t.ensureSemantics();
    final e = await _pump(t);
    e.mock.scenario = const MockRunScenario(stepDelay: Duration(seconds: 2));
    List<String> labels() {
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

    bool has(List<String> l, String label) => l.any((x) => x.contains(label));
    // The editor's own labels, matched whole ("Run" is also in the form's "Test Run").
    bool editor(List<String> l) => l.contains(_tp('run')) || l.contains(_tp('steps'));
    final startRun = _tw('singleRun.startRun');
    expect(editor(labels()), isTrue, reason: 'the editor: its app bar and view switch');
    // The run form: a modal sheet, read alone.
    await t.tap(find.byKey(const ValueKey('phone-run')));
    await settle(t, 800);
    var l = labels();
    expect(has(l, startRun), isTrue, reason: 'the form\'s Start Run: $l');
    expect(has(l, 'Query'), isTrue, reason: 'its field: $l');
    expect(editor(l), isFalse, reason: 'the editor behind is hidden: $l');
    await t.enterText(find.descendant(of: e.sheet('phone-run-input-sheet'), matching: find.byType(EditableText)), 'q');
    await t.pump();
    await t.tap(find.text(startRun));
    await settle(t, 800);
    // The run sheet at its peek: not modal, so the editor is read with it.
    l = labels();
    expect(has(l, _tw('common.running')), isTrue, reason: 'the run sheet\'s state: $l');
    expect(has(l, _tp('stop')), isTrue, reason: 'its Stop: $l');
    expect(editor(l), isTrue, reason: 'the editor stays readable: $l');
    expect(has(l, 'Count Android'), isTrue, reason: 'a step: $l');
    semantics.dispose();
    await e.dispose();
  });

  testWidgets('a step\'s form hugs its field under "Test Run" and the step\'s title', (t) async {
    final e = await _pump(t);
    await t.longPress(find.text('Summarize'));
    await settle(t, 800);
    await t.tap(find.text(_tw('panel.runThisStep')));
    await settle(t, 800);
    expect(e.sheet('phone-step-input-sheet'), findsOneWidget);
    final header = find.ancestor(of: find.text(_tw('singleRun.testRun')), matching: find.byType(DifySheetHeader));
    expect(header, findsOneWidget);
    expect(find.descendant(of: header, matching: find.text('Summarize')), findsOneWidget);
    expect(e.top('phone-step-input-sheet'), greaterThan(914 / 2 - 24), reason: 'as tall as its one field');
    await e.dispose();
  });

  testWidgets('Run step from the open settings sheet runs once, in the settings; its result also in the run sheet', (
    t,
  ) async {
    final e = await _pump(t);
    e.mock.scenario = const MockRunScenario(stepDelay: Duration(milliseconds: 300));
    var starts = 0;
    var was = e.store.nodeRunDataOf('llm')['_singleRunningStatus'];
    void count() {
      final now = e.store.nodeRunDataOf('llm')['_singleRunningStatus'];
      if (now == NodeRunningStatus.running && was != NodeRunningStatus.running) starts++;
      was = now;
    }

    final store = e.store;
    store.nodeRunData.addListener(count);
    addTearDown(() => store.nodeRunData.removeListener(count));
    // A tap on the step opens its settings (4a's sheet).
    await t.tap(find.text('Summarize'));
    await settle(t, 800);
    final settings = find.byKey(const Key('node-settings-sheet'));
    expect(settings, findsOneWidget);
    expect(e.phone.settingsNodeId, 'llm');
    // Its Run step: the settings' panel takes the request and shows the step's form inside the settings; the phone's
    // own step sheet stays closed.
    await t.tap(find.byKey(const Key('node-settings-run')));
    await settle(t, 800);
    expect(e.store.pendingSingleRun.value, isNull);
    expect(e.sheet('phone-step-input-sheet'), findsNothing);
    final form = find.descendant(of: settings, matching: find.byType(BeforeRunFormFinder.type));
    expect(form, findsOneWidget);
    await t.enterText(find.descendant(of: form, matching: find.byType(EditableText)).first, 'hello');
    await t.pump();
    await t.tap(find.descendant(of: form, matching: find.text(_tw('singleRun.startRun'))));
    await settle(t, 2000);
    expect(starts, 1, reason: 'one run');
    expect(e.store.nodeRunDataOf('llm')['_singleRunningStatus'], NodeRunningStatus.succeeded);
    expect(e.phone.settingsNodeId, 'llm', reason: 'the settings stay open on their Last Run');
    expect(e.phone.singleRunNodeId, 'llm', reason: 'the run sheet shows it too, under the settings');
    // Closing the settings leaves the run sheet with the result.
    expect(await systemBack(t), isTrue);
    await settle(t, 800);
    expect(e.phone.settingsNodeId, isNull);
    expect(find.descendant(of: e.runHeader, matching: find.textContaining(_tp('runSucceeded'))), findsOneWidget);
    expect(starts, 1);
    expect(t.takeException(), isNull);
    await e.dispose();
  });

  testWidgets('chatflow: Preview opens the chat as a full sheet; back closes it', (t) async {
    final e = await _pump(t, chat: true);
    await t.tap(find.byKey(const ValueKey('phone-run')));
    await settle(t, 800);
    expect(e.store.showDebugAndPreviewPanel.value, isTrue);
    expect(e.sheet('phone-chat-sheet'), findsOneWidget);
    expect(find.byType(DebugAndPreview), findsOneWidget);
    expect(e.top('phone-chat-sheet'), closeTo(gestureInsets.top, 1));
    // Its header: the sheet header's touch-size buttons (44 px, 48 px targets): refresh, the user input fields'
    // toggle (Start has a variable), close.
    final header = find.descendant(of: e.sheet('phone-chat-sheet'), matching: find.byType(DifySheetHeader));
    expect(find.descendant(of: header, matching: find.text(_tw('common.debugAndPreview'))), findsOneWidget);
    final buttons = find.descendant(of: header, matching: find.byType(DifyTouchIconButton));
    expect(buttons, findsNWidgets(3));
    for (final b in t.widgetList<DifyTouchIconButton>(buttons)) {
      expect(b.size, 44);
      expect(t.getSize(find.byWidget(b)), const Size(44, 44));
    }
    final toggle = t.widgetList<DifyTouchIconButton>(buttons).singleWhere((b) => b.selected != null);
    expect(toggle.label, _tw('panel.userInputField'));
    expect(toggle.selected, isTrue);
    await t.tap(find.byWidget(toggle));
    await t.pump();
    expect(t.widgetList<DifyTouchIconButton>(buttons).singleWhere((b) => b.selected != null).selected, isFalse);
    expect(find.descendant(of: e.sheet('phone-chat-sheet'), matching: find.byType(DifyIconButton)), findsNothing);
    expect(e.runSheet, findsNothing);
    expect(await systemBack(t), isTrue);
    await settle(t, 600);
    expect(e.store.showDebugAndPreviewPanel.value, isFalse);
    expect(e.sheet('phone-chat-sheet'), findsNothing);
    expect(t.takeException(), isNull);
    await e.dispose();
  });

  testWidgets('a wide window keeps the desktop run panel', (t) async {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(1440, 900);
    addTearDown(t.view.reset);
    final backend = _Backend(
      const DocMeta(appMode: 'workflow', appName: 'Self-host check'),
      server: _server(),
    );
    await t.pumpWidget(
      DifyApplication(
        theme: difyTheme(),
        home: EditorPage(backend: backend, docId: 'demo', clientId: 'desk-run', journaled: false),
      ),
    );
    await settle(t, 2000);
    expect(find.byType(PhoneEditorFrame), findsNothing);
    final store = WorkflowStoreScope.of(t.element(find.byType(WorkflowPanelsFinder.type)));
    WorkflowRunScope.of(t.element(find.byType(WorkflowPanelsFinder.type))).run.handleStartWorkflowRun();
    await settle(t, 600);
    expect(store.showDebugAndPreviewPanel.value, isTrue);
    expect(find.byType(WorkflowPreview), findsOneWidget);
    expect(find.byKey(const ValueKey('phone-run-sheet')), findsNothing);
    expect(find.byKey(const ValueKey('phone-run-input-sheet')), findsNothing);
    await unmount(t);
    await backend.dispose();
    await t.pump(const Duration(seconds: 20));
  });
}

/// Types for finders.
abstract final class WorkflowPanelsFinder {
  static const type = WorkflowPanels;
}

abstract final class ControlModeFinder {
  static const comment = ControlMode.comment;
}

/// The before-run form's type, for finders.
abstract final class BeforeRunFormFinder {
  static const type = BeforeRunForm;
}
