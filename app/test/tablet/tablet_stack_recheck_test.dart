// The stacked build's device check (check-stack.md), tablet's part, with touch: the side panels a form docks over leave
// the platform semantics tree and get the focus back when the form closes (finding 3); a focused field of a landscape
// phone's side panel comes into view above the keyboard (finding 4); the touch desktop's drawers, Logs sidebar and
// Studio filters are touch-sized while a mouse keeps Dify's sizes (finding 5); the selection rail reads its title
// first, then the state (finding 6).
import 'dart:async';

import 'package:dify_sf_app/src/app_detail/annotations/annotation_modals.dart';
import 'package:dify_sf_app/src/app_detail/detail_sidebar.dart';
import 'package:dify_sf_app/src/canvas/canvas_controller.dart';
import 'package:dify_sf_app/src/canvas/workflow_canvas.dart';
import 'package:dify_sf_app/src/demo/demo_backend.dart';
import 'package:dify_sf_app/src/design/dify_theme.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/editor/editor_controller.dart';
import 'package:dify_sf_app/src/editor/editor_page.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/workflow_editor/dify_editor.dart';
import 'package:dify_sf_app/src/workflow_editor/phone/phone_editor_controller.dart';
import 'package:dify_sf_app/src/workflow_editor/phone/phone_editor_frame.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../phone/phone_harness.dart';
import '../support/app_fonts.dart';
import '../support/platform_semantics.dart';

const _landscape = EdgeInsets.only(top: 24, bottom: 16);
const _tablet = EdgeInsets.only(top: 24, bottom: 20);

String _c(String key) => DifyI18n.tr('common', key);
String _tw(String key) => DifyI18n.tr('workflow', key);
String _tp(String key) => DifyI18n.tr('phone-editor', key);

Finder _key(String key) => find.byKey(ValueKey(key));

class _Editor {
  _Editor(this.t, this.demo);
  final WidgetTester t;
  final DemoBackend demo;

  EditorController get c => t.widget<DifyWorkflowEditor>(find.byType(DifyWorkflowEditor)).controller;
  Finder get canvasFinder => find.byType(WorkflowCanvas, skipOffstage: false);
  CanvasController get canvas => t.state<WorkflowCanvasState>(canvasFinder).canvas;
  PhoneEditorController get phone => PhoneEditorScope.read(t.element(find.byType(PhoneEditorFrame)))!;

  Future<void> tapNode(String id) async {
    canvas.view.center = canvas.graph![id]!.rect.center;
    await t.pump();
    await t.tapAt(t.getTopLeft(canvasFinder) + canvas.view.toScreen(canvas.graph![id]!.rect.center));
    await settle(t, 600);
  }

  /// Selects [id] and opens its settings from the selection's Settings.
  Future<void> openSettings(String id) async {
    await tapNode(id);
    await t.ensureVisible(_key('phone-node-settings'));
    await t.pump();
    await t.tap(_key('phone-node-settings'));
    await settle(t, 800);
    expect(phone.settingsNodeId, id);
  }

  /// The settings panel's description field (it leads the settings).
  Finder get description =>
      find.descendant(of: _key('phone-node-settings-side'), matching: find.byType(EditableText)).first;

  Future<void> dispose() async {
    await unmount(t);
    await demo.dispose();
    await t.pump(const Duration(seconds: 20));
  }
}

Future<_Editor> _editor(WidgetTester t, Size size, EdgeInsets insets) async {
  phoneWindow(t, size: size, insets: insets);
  final e = _Editor(t, DemoBackend(withBo: false));
  await t.pumpWidget(
    DifyApplication(
      theme: difyTheme(),
      edgeToEdge: true,
      home: EditorPage(backend: e.demo, docId: 'demo', clientId: 'tablet-recheck', journaled: false),
    ),
  );
  await settle(t, 2000);
  return e;
}

/// Whether [context] is inside [f]'s widget.
bool _inside(BuildContext? context, Finder f) {
  if (context is! Element) return false;
  final target = f.evaluate().single;
  if (context == target) return true;
  var found = false;
  context.visitAncestorElements((a) {
    found = a == target;
    return !found;
  });
  return found;
}

/// [f] is at least 44 dp in each direction.
void _touchSized(WidgetTester t, Finder f, String reason) {
  final size = t.getSize(f);
  expect(size.height, greaterThanOrEqualTo(44), reason: '$reason: height $size');
  expect(size.width, greaterThanOrEqualTo(44), reason: '$reason: width $size');
}

/// [control]'s touch box (its [DifyTouchArea]) or the control itself.
Finder _box(Finder control) {
  final box = find.ancestor(of: control, matching: find.byType(DifyTouchArea));
  return box.evaluate().isEmpty ? control : box.first;
}

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

  for (final (size, insets) in const [(Size(914, 411), _landscape), (Size(1280, 800), _tablet)]) {
    final at = '${size.width.toInt()}x${size.height.toInt()}';

    testWidgets('$at: the Run form docked over the settings hides them from assistive technology; the focus moves into '
        'the form and back to the settings field when it closes', (t) async {
      final semantics = t.ensureSemantics();
      final e = await _editor(t, size, insets);
      await e.openSettings('code');
      final panelName = _tw('panel.nodePanel');
      expect(platformLabels(t), contains(panelName));
      await t.tap(e.description);
      await settle(t, 300);
      final field = t.widget<EditableText>(e.description).focusNode;
      expect(field.hasFocus, isTrue);

      await t.tap(_key('phone-run'));
      await settle(t, 800);
      expect(_key('phone-run-input-side'), findsOneWidget);
      final labels = platformLabels(t);
      expect(labels, isNot(contains(panelName)), reason: 'the covered settings are hidden: $labels');
      expect(labels, contains(_c('operation.close')), reason: "the form's header is read: $labels");
      expect(field.hasFocus, isFalse, reason: 'the form took the focus (the keyboard goes down)');
      expect(_inside(FocusManager.instance.primaryFocus?.context, _key('phone-run-input-side')), isTrue);

      expect(await systemBack(t), isTrue, reason: 'Back closes the form');
      expect(_key('phone-run-input-side'), findsNothing);
      expect(platformLabels(t), contains(panelName), reason: 'the settings are read again');
      expect(field.hasFocus, isTrue, reason: 'the settings field has the focus back');
      semantics.dispose();
      expect(t.takeException(), isNull);
      await e.dispose();
    });
  }

  testWidgets('914x411: a focused field of the side panel comes into view above the keyboard (the header gives way)', (
    t,
  ) async {
    final e = await _editor(t, const Size(914, 411), _landscape);
    await e.openSettings('code');
    await t.tap(e.description);
    await settle(t, 300);
    expect(t.widget<EditableText>(e.description).focusNode.hasFocus, isTrue);
    const keyboard = 260.0;
    openKeyboard(t, height: keyboard, insets: _landscape);
    await settle(t, 1000);
    final r = t.getRect(e.description);
    final panel = t.getRect(_key('phone-node-settings-side'));
    expect(r.bottom, lessThanOrEqualTo(411 - keyboard + 0.5), reason: 'above the keyboard: $r');
    expect(r.top, greaterThanOrEqualTo(panel.top - 0.5), reason: 'inside the panel: $r, panel $panel');
    expect(t.widget<EditableText>(e.description).focusNode.hasFocus, isTrue, reason: 'the field keeps the focus');
    closeKeyboard(t, insets: _landscape);
    await settle(t, 600);
    expect(t.takeException(), isNull);
    await e.dispose();
  });

  testWidgets('914x411: the selection rail reads the title first, then the state ("<title>, selected")', (t) async {
    final semantics = t.ensureSemantics();
    final e = await _editor(t, const Size(914, 411), _landscape);
    await e.tapNode('code');
    final title = t.widget<DifySelectionBar>(find.byType(DifySelectionBar)).title;
    final labels = platformLabels(t);
    expect(labels, contains('$title, ${_tp('selected')}'), reason: '$labels');
    expect(labels.where((l) => l.startsWith(_tp('selected'))), isEmpty, reason: 'not "selected / $title": $labels');
    semantics.dispose();
    expect(t.takeException(), isNull);
    await e.dispose();
  });

  for (final touch in [true, false]) {
    final input = touch ? 'touch' : 'mouse';

    testWidgets('1280x800 $input: the Add Annotation drawer is read, its close ${touch ? 'touch-sized' : "Dify's"}', (
      t,
    ) async {
      DifyInteraction.debugDefault = touch ? DifyInteractionMode.touch : DifyInteractionMode.pointer;
      final semantics = t.ensureSemantics();
      phoneWindow(t, size: const Size(1280, 800), insets: _tablet);
      await t.pumpWidget(
        DifyApplication(
          theme: difyTheme(),
          home: DifyPage(
            body: Stack(
              children: [
                Semantics(label: 'Page behind', button: true, child: const SizedBox(width: 200, height: 48)),
                AddAnnotationModal(isShow: true, onHide: () {}, onAdd: (_) async {}),
              ],
            ),
          ),
        ),
      );
      await settle(t, 600);
      final labels = platformLabels(t);
      expect(labels, contains(DifyI18n.tr('app-annotation', 'addModal.title')), reason: '$labels');
      expect(labels, isNot(contains('Page behind')), reason: '$labels');
      final close = find.descendant(
        of: _key('annotation-drawer'),
        matching: find.byWidgetPredicate((w) => w is DifyIconButton && w.label == _c('operation.close')),
      );
      if (touch) {
        _touchSized(t, _box(close), 'drawer close');
      } else {
        expect(t.getSize(_box(close)).height, lessThan(44), reason: "a mouse keeps Dify's size");
      }
      semantics.dispose();
      expect(t.takeException(), isNull);
      await unmount(t);
    });

    testWidgets('800x1280 $input: the Studio filters and Create are ${touch ? 'touch-high' : "Dify's 32 px"}', (
      t,
    ) async {
      DifyInteraction.debugDefault = touch ? DifyInteractionMode.touch : DifyInteractionMode.pointer;
      phoneWindow(t, size: const Size(800, 1280), insets: _tablet);
      final ws = await workspace();
      ws.api.seed(name: 'Support triage');
      await pumpApp(t, ws);
      final controls = {
        'Types': find
            .ancestor(of: find.text(DifyI18n.tr('app', 'studio.filters.types')), matching: find.byType(DifyPressable))
            .first,
        'Sort': find.byKey(const ValueKey('studio-sort-filter')),
        'Create': find.descendant(of: _key('studio-create'), matching: find.byType(DifyButton)),
      };
      for (final MapEntry(:key, :value) in controls.entries) {
        expect(value, findsWidgets, reason: key);
        final h = t.getSize(value.first).height;
        if (touch) {
          expect(h, greaterThanOrEqualTo(44), reason: key);
        } else {
          expect(h, 32, reason: key);
        }
      }
      expect(t.takeException(), isNull);
      await unmount(t);
    });

    testWidgets('1280x800 $input: the Logs sidebar\'s links, collapse and the app\'s "…" are '
        '${touch ? 'touch-sized' : "Dify's sizes"}', (t) async {
      DifyInteraction.debugDefault = touch ? DifyInteractionMode.touch : DifyInteractionMode.pointer;
      phoneWindow(t, size: const Size(1280, 800), insets: _tablet);
      final ws = await workspace();
      ws.api.seed(name: 'Support triage');
      await pumpApp(t, ws);
      await t.tap(find.text('Support triage').first);
      await settle(t, 2500);
      if (find.byType(DetailSidebarFrame).evaluate().isEmpty) {
        // A touch tablet opens the editor without the sidebar: Logs from its "…".
        await t.tap(_key('phone-editor-more'));
        await settle(t, 800);
        final logs = find.text(_c('appMenus.logs'));
        await t.ensureVisible(logs);
        await t.pump();
        await t.tap(logs);
        await settle(t, 1500);
      }
      expect(find.byType(DetailSidebarFrame), findsOneWidget);
      final link = find.ancestor(of: find.text(_c('appMenus.logs')).first, matching: find.byType(DifyPressable)).first;
      final toggle = _key('detail-sidebar-toggle');
      final more = _key('app-info-more');
      if (touch) {
        expect(t.getSize(link).height, greaterThanOrEqualTo(44), reason: 'a link');
        _touchSized(t, _box(toggle), 'collapse');
        _touchSized(t, _box(more), "the app's …");
      } else {
        expect(t.getSize(link).height, 32, reason: 'a link');
        expect(t.getSize(_box(toggle)).height, 32, reason: 'collapse');
        expect(t.getSize(_box(more)).height, 20, reason: "the app's …");
      }
      expect(t.takeException(), isNull);
      await unmount(t);
    });
  }

  testWidgets('1280x800 touch: a drawer\'s (the run detail\'s) close is touch-sized', (t) async {
    phoneWindow(t, size: const Size(1280, 800), insets: _tablet);
    final nav = GlobalKey<NavigatorState>();
    await t.pumpWidget(
      DifyApplication(
        theme: difyTheme(),
        navigatorKey: nav,
        home: const DifyPage(body: SizedBox.expand()),
      ),
    );
    unawaited(
      showDifyDrawer<void>(
        nav.currentContext!,
        builder: (context, close) => DifyDrawerPopup(
          child: Align(
            alignment: Alignment.topRight,
            child: DifyIconButton(
              label: _c('operation.close'),
              icon: const SizedBox.square(dimension: 16),
              onPressed: close,
            ),
          ),
        ),
      ),
    );
    await settle(t, 600);
    final close = find.byWidgetPredicate((w) => w is DifyIconButton && w.label == _c('operation.close'));
    _touchSized(t, _box(close), 'drawer close');
    expect(t.takeException(), isNull);
    await unmount(t);
  });
}
