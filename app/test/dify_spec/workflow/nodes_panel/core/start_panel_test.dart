// dify-spec: web/app/components/workflow/nodes/start/__tests__/panel.spec.tsx
// dify-spec: web/app/components/workflow/nodes/start/components/__tests__/var-item.spec.tsx
// dify-spec: web/app/components/workflow/nodes/start/components/__tests__/var-list.spec.tsx
//
// The panel over a document in an in-memory session, with the real input field dialog (Dify mocks it with a
// confirm button: here its fields are filled and saved) and the real remove confirmation.
import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/workflow_editor/context_menu/context_menu.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/core/start_panel.dart';
import 'package:dify_sf_app/src/workflow_editor/panel_fields/panel_fields.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

/// The Start panel of [nodes]' `start` node (with [toasts]).
Future<CorePanel> openStartPanel(
  WidgetTester t,
  List<Node> nodes, {
  List<Edge> edges = const [],
  bool chatMode = false,
}) => openCorePanel(
  t,
  nodes,
  'start',
  edges: edges,
  options: WorkflowMenuOptions(isChatMode: chatMode),
  scroll: false,
);

Map<String, Object?> inputVar(String variable, [String? label]) => {
  'label': label ?? variable,
  'variable': variable,
  'type': 'text-input',
  'required': false,
};

Future<TestGesture> hover(WidgetTester t, Finder f) async {
  final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: Offset.zero);
  addTearDown(mouse.removePointer);
  await mouse.moveTo(t.getCenter(f));
  await t.pump();
  return mouse;
}

/// The text field of the dialog's field titled [title].
Finder modalInput(String title) => find.descendant(
  of: find.ancestor(of: find.text(title), matching: find.byType(ModalField)),
  matching: find.byType(TextField),
);

const _addTitle = 'app-debug.variableConfig.addModalTitle';
const _addButton = 'common.operation.add workflow.nodes.start.inputField';

/// Fills the dialog's name and label and saves.
Future<void> fillAndSave(WidgetTester t, String variable, String label) async {
  await t.enterText(modalInput('app-debug.variableConfig.varName'), variable);
  await t.enterText(modalInput('app-debug.variableConfig.labelName'), label);
  await t.tap(find.text('common.operation.save'));
  await settle(t);
}

/// Whether the focused node is inside [f].
bool focusIn(Finder f) {
  final el = FocusManager.instance.primaryFocus?.context as Element?;
  if (el == null) return false;
  final targets = f.evaluate().toSet();
  var found = targets.contains(el);
  el.visitAncestorElements((a) => !(found = found || targets.contains(a)));
  return found;
}

/// Dify's test translator, with `common.operation.*` as the bare operation.
class _ShortButtons extends DifyTestTranslator {
  @override
  String t(String ns, String key, [Map<String, Object?> params = const {}]) =>
      ns == 'common' && key.startsWith('operation.') ? key.substring(10) : super.t(ns, key, params);
}

void main() {
  group('StartPanel', () {
    testWidgets('should show chat-only system variables and open the add-variable modal when writable', (t) async {
      final p = await openStartPanel(
        t,
        difyNodes([
          difyNode('start', 'start', {'variables': <Object?>[]}),
        ]),
        chatMode: true,
      );
      expect(find.text('userinput.query'), findsOneWidget);
      expect(find.text('userinput.files'), findsOneWidget);
      expect(find.text('LEGACY'), findsNothing);

      await t.tap(buttonNamed(_addButton));
      await settle(t);
      expect(find.text(_addTitle), findsOneWidget);
      await t.tap(find.text('common.operation.cancel'));
      await settle(t);
      await p.dispose(t);
    });

    testWidgets('should render the add modal and hide it after a successful confirm', (t) async {
      final nodes = difyNodes([
        difyNode('start', 'start', {
          'variables': [inputVar('query')],
        }),
        difyNode('end', 'end', {
          'outputs': [
            {
              'variable': 'out',
              'value_selector': ['start', 'query'],
            },
          ],
        }),
      ]);
      final p = await openStartPanel(t, nodes, edges: chain(['start', 'end']));
      expect(find.text('userinput.query'), findsNothing);
      expect(find.text('LEGACY'), findsOneWidget);

      await t.tap(buttonNamed(_addButton));
      await settle(t);
      await fillAndSave(t, 'locale', 'Locale');
      expect(find.text(_addTitle), findsNothing);
      expect([for (final v in p.data['variables']! as List) (v as Map)['variable']], ['query', 'locale']);

      // Removing a variable the End node uses asks first.
      final mouse = await hover(t, find.text('query').first);
      // (The confirmation's buttons are named shortly: the test font makes the full keys wider than the dialog.)
      DifyI18n.current = _ShortButtons();
      await t.tap(buttonNamed('common.operation.remove'));
      await settle(t);
      expect(find.text('workflow.common.effectVarConfirm.title'), findsOneWidget);
      await t.tap(find.text('confirm'));
      await settle(t);
      await mouse.removePointer();
      expect([for (final v in p.data['variables']! as List) (v as Map)['variable']], ['locale']);
      expect((p.h['end']!.config['outputs']! as VItems).items.single.value.toString(), contains('value_selector: []'));
      await p.dispose(t);
    });

    testWidgets(
      'should keep the add modal open when validation fails and pass existing variable keys to the modal',
      (t) async {
        final p = await openStartPanel(
          t,
          difyNodes([
            difyNode('start', 'start', {
              'variables': [inputVar('locale', 'Locale')],
            }),
          ]),
        );
        await t.tap(buttonNamed(_addButton));
        await settle(t);
        await fillAndSave(t, 'locale', 'Other');
        expect(find.text(_addTitle), findsOneWidget);
        expect(p.toasts, [
          'app-debug.varKeyError.keyAlreadyExists:{"key":"app-debug.variableConfig.varName"}',
        ]);
        expect((p.data['variables']! as List), hasLength(1));
        await t.tap(find.text('common.operation.cancel'));
        await settle(t);
        await p.dispose(t);
      },
    );
  });

  group('StartVarItem', () {
    testWidgets('shows named edit and remove actions on hover', (t) async {
      useDifyTestTranslator();
      var removed = 0;
      await t.pumpWidget(
        MaterialApp(
          home: Material(
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 380,
                child: StartVarItem(readonly: false, payload: inputVar('query', 'Query'), onRemove: () => removed++),
              ),
            ),
          ),
        ),
      );
      final mouse = await hover(t, find.byType(StartVarItem));
      await t.tap(buttonNamed('common.operation.edit'));
      await settle(t);
      expect(find.text('app-debug.variableConfig.editModalTitle'), findsOneWidget);
      await t.tap(find.text('common.operation.cancel'));
      await settle(t);

      await mouse.moveTo(t.getCenter(find.byType(StartVarItem)) + const Offset(1, 0));
      await t.pump();
      await t.tap(buttonNamed('common.operation.remove'));
      expect(removed, 1);
    });
  });

  testWidgets('tabs to the reorder handle before the hovered variable edit and remove actions', (t) async {
    useDifyTestTranslator();
    await t.pumpWidget(
      MaterialApp(
        home: Material(
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 380,
              child: StartVarList(
                readonly: false,
                list: [
                  for (final v in ['alpha', 'beta']) inputVar(v),
                ],
                onChange: (_, [_]) {},
              ),
            ),
          ),
        ),
      ),
    );
    await hover(t, find.text('alpha').first);
    bool handle(String v) => FocusManager.instance.primaryFocus?.debugLabel == 'start var handle $v';

    await t.sendKeyEvent(LogicalKeyboardKey.tab);
    await t.pump();
    expect(handle('alpha'), isTrue);
    await t.sendKeyEvent(LogicalKeyboardKey.tab);
    await t.pump();
    expect(focusIn(buttonNamed('common.operation.edit')), isTrue);
    await t.sendKeyEvent(LogicalKeyboardKey.tab);
    await t.pump();
    expect(focusIn(buttonNamed('common.operation.remove')), isTrue);
    await t.sendKeyEvent(LogicalKeyboardKey.tab);
    await t.pump();
    expect(handle('beta'), isTrue);
  });
}
