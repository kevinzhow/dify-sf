// The workflow editor on tablets and landscape phones (dify-sf's touch desktop, batch 5): with touch, a medium or
// expanded window gets the phone's touch chrome around the canvas with an end-docked side panel (node settings, the
// run's forms and result, the version list) instead of bottom sheets; a short window (a landscape phone) has a 48 px
// app bar holding the view switch and the toolbar as a rail on the start edge, so the canvas keeps the full height.
// With a mouse the same windows keep today's desktop editor. Turning the device keeps the selection, the open panel and
// the canvas, and moves the panel between the sheet and the side panel; Back closes the panels first, as on a phone.
import 'dart:async';

import 'package:dify_sf_app/src/canvas/canvas_controller.dart';
import 'package:dify_sf_app/src/canvas/workflow_canvas.dart';
import 'package:dify_sf_app/src/demo/demo_backend.dart';
import 'package:dify_sf_app/src/design/dify_theme.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/editor/editor_controller.dart';
import 'package:dify_sf_app/src/editor/editor_page.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/workflow_editor/dify_editor.dart';
import 'package:dify_sf_app/src/workflow_editor/header/workflow_header.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/workflow_node_panel.dart';
import 'package:dify_sf_app/src/workflow_editor/operator/operator.dart';
import 'package:dify_sf_app/src/workflow_editor/phone/phone_editor_controller.dart';
import 'package:dify_sf_app/src/workflow_editor/phone/phone_editor_frame.dart';
import 'package:dify_sf_app/src/workflow_editor/steps/workflow_steps_view.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../phone/phone_harness.dart';
import '../support/app_fonts.dart';

/// A landscape phone with gesture navigation: the status bar on top, the gesture handle at the bottom.
const landscapeGesture = EdgeInsets.only(top: 24, bottom: 16);

/// A landscape phone with three-button navigation: the buttons on the end edge, a cutout on the start edge.
const landscapeThreeButton = EdgeInsets.only(top: 24, left: 32, right: 48);

/// A tablet: the status bar and the gesture handle.
const tabletInsets = EdgeInsets.only(top: 24, bottom: 20);

const touchWindows = [
  (size: Size(914, 411), insets: landscapeGesture, name: '914x411 gesture', short: true),
  (size: Size(914, 411), insets: landscapeThreeButton, name: '914x411 three-button', short: true),
  (size: Size(780, 360), insets: landscapeGesture, name: '780x360 gesture', short: true),
  (size: Size(800, 1280), insets: tabletInsets, name: '800x1280', short: false),
  (size: Size(1280, 800), insets: tabletInsets, name: '1280x800', short: false),
];

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
  Rect get canvasRect => t.getRect(canvasFinder);

  Offset node(String id) {
    final n = canvas.graph![id]!;
    return t.getTopLeft(canvasFinder) + canvas.view.toScreen(n.rect.center);
  }

  /// Brings node [id] into the middle of the canvas and taps it.
  Future<void> tapNode(String id) async {
    canvas.view.center = canvas.graph![id]!.rect.center;
    await t.pump();
    await t.tapAt(node(id));
    await settle(t, 600);
  }

  Future<void> dispose() async {
    await unmount(t);
    await demo.dispose();
    await t.pump(const Duration(seconds: 20));
  }
}

void _window(WidgetTester t, Size size, EdgeInsets insets) {
  FakeViewPadding fake(EdgeInsets e) => FakeViewPadding(left: e.left, top: e.top, right: e.right, bottom: e.bottom);
  t.view.physicalSize = size;
  t.view.padding = fake(insets);
  t.view.viewPadding = fake(insets);
}

Future<_Editor> _pump(
  WidgetTester t, {
  required Size size,
  EdgeInsets insets = EdgeInsets.zero,
  bool touch = true,
  bool pushed = false,
}) async {
  phoneWindow(t, size: size, insets: insets);
  DifyInteraction.debugDefault = touch ? DifyInteractionMode.touch : DifyInteractionMode.pointer;
  final e = _Editor(t, DemoBackend(withBo: false));
  Widget editor() => EditorPage(backend: e.demo, docId: 'demo', clientId: 'tablet-editor', journaled: false);
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
  return e;
}

String _tp(String key) => DifyI18n.tr('phone-editor', key);

Finder _side(String key) => find.byKey(ValueKey(key));

void main() {
  setUpAll(() async {
    await DifyI18n.load('en-US');
    await useAppFonts();
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('touch', () {
    for (final w in touchWindows) {
      testWidgets('${w.name}: the touch chrome on the canvas, nothing docked yet, no desktop chrome', (t) async {
        final e = await _pump(t, size: w.size, insets: w.insets);
        expect(t.takeException(), isNull);
        expect(find.byType(PhoneEditorFrame), findsOneWidget);
        expect(find.byType(HeaderInNormal), findsNothing);
        expect(find.byType(WorkflowControl), findsNothing);
        expect(find.byType(WorkflowOperator), findsNothing);
        // A wider window opens on the canvas.
        expect(e.phone.view, PhoneEditorView.canvas);
        final bar = t.getRect(find.byKey(const ValueKey('phone-editor-app-bar')));
        expect(bar.top, 0);
        expect(bar.height, (w.short ? DifyTopAppBar.denseHeight : DifyTopAppBar.height) + w.insets.top);
        final toolbar = t.getRect(find.byKey(const ValueKey('phone-toolbar')));
        final canvas = e.canvasRect;
        if (w.short) {
          // The view switch is in the app bar; the toolbar is a rail on the start edge; the canvas runs from the app
          // bar to the window's bottom edge.
          expect(
            find.descendant(
              of: find.byKey(const ValueKey('phone-editor-app-bar')),
              matching: find.byKey(const ValueKey('phone-view-switch')),
            ),
            findsOneWidget,
          );
          expect(toolbar.left, 0);
          expect(toolbar.width, DifyBottomToolbar.railWidth + w.insets.left);
          expect(toolbar.top, bar.bottom);
          expect(toolbar.bottom, w.size.height);
          expect(canvas.top, bar.bottom);
          expect(canvas.bottom, w.size.height);
          expect(canvas.left, toolbar.right);
          expect(canvas.right, w.size.width);
          // Every rail action and the Add button stay clear of the start inset and the bottom bar.
          for (final f in [find.byKey(const ValueKey('phone-add')), find.text(_tp('versions'))]) {
            await t.ensureVisible(f);
            await t.pump();
            final r = t.getRect(f);
            expect(r.left, greaterThanOrEqualTo(w.insets.left));
            expect(r.bottom, lessThanOrEqualTo(w.size.height - w.insets.bottom));
          }
        } else {
          // A tablet: the view row under the app bar and the toolbar under the canvas, as on a phone.
          expect(toolbar.bottom, w.size.height);
          expect(toolbar.width, w.size.width);
          expect(canvas.bottom, toolbar.top);
          expect(canvas.width, w.size.width);
        }
        expect(_side('phone-side-dock'), findsOneWidget);
        expect(find.byType(DifySidePanel), findsNothing);
        expect(t.takeException(), isNull);
        await e.dispose();
      });

      testWidgets('${w.name}: a node\'s settings dock at the end beside the canvas, Back closes them', (t) async {
        final e = await _pump(t, size: w.size, insets: w.insets, pushed: true);
        await e.tapNode('code');
        expect(e.c.selectedNodeId, 'code');
        final bar = find.byKey(const ValueKey('phone-node-bar'));
        expect(bar, findsOneWidget);
        if (w.short) {
          // The selection's actions are the rail's.
          expect(t.getRect(bar).left, 0);
          expect(t.getRect(bar).width, DifyBottomToolbar.railWidth + w.insets.left);
        }
        await t.ensureVisible(find.byKey(const ValueKey('phone-node-settings')));
        await t.pump();
        await t.tap(find.byKey(const ValueKey('phone-node-settings')));
        await settle(t, 800);
        expect(t.takeException(), isNull);
        expect(e.phone.settingsNodeId, 'code');
        expect(find.byType(WorkflowNodePanel), findsOneWidget);
        expect(find.byKey(const Key('node-settings-sheet')), findsOneWidget, reason: 'the touch panel content');
        // No sheet and no scrim: a side panel at the window's end, as tall as the area under the app bar.
        expect(find.byKey(const ValueKey('dify-sheet-scrim')), findsNothing);
        expect(find.byType(DraggableScrollableSheet), findsNothing);
        final side = t.getRect(_side('phone-node-settings-side'));
        final width = DifySidePanel.widthFor(w.size);
        expect(side.width, width);
        expect(side.right, w.size.width);
        final appBar = t.getRect(find.byKey(const ValueKey('phone-editor-app-bar')));
        expect(side.top, appBar.bottom);
        expect(side.bottom, w.size.height);
        // The canvas is beside it, not under it, and the node is in view.
        final canvas = e.canvasRect;
        expect(canvas.right, side.left);
        expect(canvas.contains(e.node('code')), isTrue, reason: 'the narrower canvas brought the node into view');
        // The panel's content keeps clear of the end and bottom insets; its close is a 44 px touch button.
        final close = find.descendant(
          of: _side('phone-node-settings-side'),
          matching: find.byWidgetPredicate(
            (w) => w is DifyTouchIconButton && w.label == DifyI18n.tr('common', 'operation.close'),
          ),
        );
        expect(close, findsOneWidget);
        expect(t.getRect(close).right, lessThanOrEqualTo(w.size.width - w.insets.right));
        expect(t.getSize(close).height, greaterThanOrEqualTo(44));

        expect(await systemBack(t), isTrue, reason: 'the panel');
        expect(find.byType(WorkflowNodePanel), findsNothing);
        expect(e.c.selectedNodeId, 'code', reason: 'the selection stays');
        expect(e.canvasRect.right, w.size.width, reason: 'the canvas has the width again');
        expect(await systemBack(t), isTrue, reason: 'the selection');
        expect(e.c.selectedNodeId, isNull);
        expect(await systemBack(t), isTrue, reason: 'the editor');
        expect(find.byType(EditorPage), findsNothing);
        expect(t.takeException(), isNull);
        await e.dispose();
      });
    }

    testWidgets('914x411: the version list and the run\'s form are side panels; Back closes the newest first', (
      t,
    ) async {
      final e = await _pump(t, size: const Size(914, 411), insets: landscapeGesture, pushed: true);
      await e.tapNode('code');
      await t.ensureVisible(find.byKey(const ValueKey('phone-node-settings')));
      await t.pump();
      await t.tap(find.byKey(const ValueKey('phone-node-settings')));
      await settle(t, 800);
      // Run: the run's input form docks on top of the settings (a phone shows it as a modal sheet).
      await t.tap(find.byKey(const ValueKey('phone-run')));
      await settle(t, 800);
      expect(t.takeException(), isNull);
      expect(_side('phone-run-input-side'), findsOneWidget);
      expect(find.byKey(const ValueKey('dify-sheet-scrim')), findsNothing);
      final form = t.getRect(_side('phone-run-input-side'));
      expect(form, t.getRect(_side('phone-node-settings-side')), reason: 'the same docked place, the newest on top');
      expect(e.canvasRect.right, form.left);

      expect(await systemBack(t), isTrue, reason: 'the run form');
      expect(_side('phone-run-input-side'), findsNothing);
      expect(_side('phone-node-settings-side'), findsOneWidget);
      expect(await systemBack(t), isTrue, reason: 'the settings');
      expect(_side('phone-node-settings-side'), findsNothing);
      expect(await systemBack(t), isTrue, reason: 'the selection');
      expect(e.c.selectedNodeId, isNull);

      // Versions from the rail: the version list docks; Back closes it, then leaves the versions.
      await t.ensureVisible(find.text(_tp('versions')));
      await t.pump();
      await t.tap(find.text(_tp('versions')));
      await settle(t, 1000);
      expect(e.store.isRestoring.value, isTrue);
      expect(_side('phone-versions-side'), findsOneWidget);
      expect(find.byType(DifyPersistentSheet), findsNothing);
      expect(e.canvasRect.right, t.getRect(_side('phone-versions-side')).left);
      expect(await systemBack(t), isTrue, reason: 'the version list');
      expect(_side('phone-versions-side'), findsNothing);
      expect(e.store.isRestoring.value, isTrue);
      expect(await systemBack(t), isTrue, reason: 'the versions');
      expect(e.store.isRestoring.value, isFalse);
      expect(t.takeException(), isNull);
      await e.dispose();
    });

    testWidgets('914x411: the Steps view stays available beside the rail', (t) async {
      final e = await _pump(t, size: const Size(914, 411), insets: landscapeGesture);
      await t.tap(find.text(_tp('steps')));
      await settle(t, 600);
      expect(e.phone.view, PhoneEditorView.steps);
      expect(find.byType(WorkflowStepsView), findsOneWidget);
      final steps = t.getRect(find.byType(WorkflowStepsView));
      expect(steps.left, DifyBottomToolbar.railWidth);
      expect(steps.right, 914);
      // A step's settings dock beside the list.
      await t.tap(find.text('Post-process').first);
      await settle(t, 800);
      expect(e.phone.settingsNodeId, 'code');
      expect(t.getRect(find.byType(WorkflowStepsView)).right, t.getRect(_side('phone-node-settings-side')).left);
      expect(t.takeException(), isNull);
      await e.dispose();
    });

    testWidgets('rotation: the selection, the open settings and the canvas stay; the panel moves between the sheet and '
        'the side panel', (t) async {
      final e = await _pump(t, size: const Size(411, 914), insets: gestureInsets);
      expect(e.phone.view, PhoneEditorView.steps, reason: 'a phone opens on the Steps view');
      await t.tap(find.text(_tp('canvas')));
      await settle(t, 600);
      final canvasState = t.state<WorkflowCanvasState>(e.canvasFinder);
      await e.tapNode('code');
      await t.tap(find.byKey(const ValueKey('phone-node-settings')));
      await settle(t, 800);
      expect(find.byKey(const ValueKey('phone-node-settings-sheet')), findsOneWidget);
      expect(find.byKey(const ValueKey('dify-sheet-scrim')), findsOneWidget);
      final phone = e.phone;

      // To landscape: the same settings, now docked beside the canvas.
      _window(t, const Size(914, 411), landscapeThreeButton);
      await settle(t, 1000);
      expect(t.takeException(), isNull);
      expect(e.phone, same(phone));
      expect(e.c.selectedNodeId, 'code');
      expect(e.phone.settingsNodeId, 'code');
      expect(e.phone.view, PhoneEditorView.canvas, reason: 'the view stays as it was');
      expect(t.state<WorkflowCanvasState>(e.canvasFinder), same(canvasState), reason: 'the canvas kept its state');
      expect(_side('phone-node-settings-side'), findsOneWidget);
      expect(find.byKey(const ValueKey('dify-sheet-scrim')), findsNothing);
      expect(t.getRect(_side('phone-node-settings-side')).right, 914);

      // A tablet's portrait (another size class) and back to the phone: the sheet again, still for the same node.
      _window(t, const Size(800, 1280), tabletInsets);
      await settle(t, 1000);
      expect(_side('phone-node-settings-side'), findsOneWidget);
      _window(t, const Size(411, 914), gestureInsets);
      await settle(t, 1000);
      expect(t.takeException(), isNull);
      expect(_side('phone-node-settings-side'), findsNothing);
      expect(find.byKey(const Key('node-settings-sheet')), findsOneWidget);
      expect(e.phone.settingsNodeId, 'code');
      expect(e.c.selectedNodeId, 'code');
      expect(t.state<WorkflowCanvasState>(e.canvasFinder), same(canvasState));
      await e.dispose();
    });

    testWidgets('rotation: the open version list moves from its sheet to the side panel and back', (t) async {
      final e = await _pump(t, size: const Size(411, 914), insets: gestureInsets);
      await t.tap(find.text(_tp('versions')));
      await settle(t, 1000);
      expect(find.byKey(const ValueKey('phone-versions-sheet')), findsOneWidget);
      _window(t, const Size(914, 411), landscapeGesture);
      await settle(t, 1000);
      expect(t.takeException(), isNull);
      expect(find.byKey(const ValueKey('phone-versions-sheet')), findsNothing);
      expect(_side('phone-versions-side'), findsOneWidget);
      expect(e.store.isRestoring.value, isTrue);
      _window(t, const Size(411, 914), gestureInsets);
      await settle(t, 1000);
      expect(find.byKey(const ValueKey('phone-versions-sheet')), findsOneWidget);
      expect(_side('phone-versions-side'), findsNothing);
      expect(t.takeException(), isNull);
      await e.dispose();
    });

    testWidgets('1280x800: Add opens the block picker as a sheet (no anchored popover, no keyboard)', (t) async {
      final e = await _pump(t, size: const Size(1280, 800), insets: tabletInsets);
      await t.tap(find.byKey(const ValueKey('phone-add')));
      await settle(t, 800);
      final sheet = find.byType(DraggableScrollableSheet);
      expect(sheet, findsOneWidget);
      expect(t.testTextInput.isVisible, isFalse);
      // Material's large-screen bottom sheet: 640 dp, centred.
      final r = t.getRect(sheet);
      expect(r.width, DifySheetRecipe.maxWidth);
      expect(r.center.dx, 640);
      expect(t.takeException(), isNull);
      await e.dispose();
    });
  });

  group('mouse', () {
    for (final size in const [Size(914, 411), Size(800, 1280), Size(1280, 800)]) {
      testWidgets('${size.width.toInt()}x${size.height.toInt()}: today\'s desktop editor', (t) async {
        final e = await _pump(t, size: size, touch: false);
        expect(find.byType(PhoneEditorFrame), findsNothing);
        expect(find.byType(PhoneEditorScope), findsNothing);
        expect(find.byType(HeaderInNormal), findsOneWidget);
        expect(find.byType(WorkflowControl), findsOneWidget);
        expect(find.byType(WorkflowOperator), findsOneWidget);
        e.c.selectNode('code');
        await settle(t, 600);
        expect(find.byType(WorkflowNodePanel), findsOneWidget);
        expect(find.byType(DifySidePanel), findsNothing);
        expect(t.takeException(), isNull);
        await e.dispose();
      });
    }
  });
}
