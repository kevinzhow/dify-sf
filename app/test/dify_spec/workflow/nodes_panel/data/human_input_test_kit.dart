import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/data_common.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/human_input/human_input_model.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/workflow_editor/context_menu/context_menu.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/human_input/human_input_panel.dart';

import 'harness.dart';

export 'package:dify_sf_app/src/design/widgets/widgets.dart';
export 'package:dify_sf_app/src/workflow_editor/panel_fields/panel_fields.dart';

export 'harness.dart';

/// Dify's test i18n text of `workflow.nodes.humanInput.<key>`.
String hiKey(String key) => 'workflow.nodes.humanInput.$key';

/// A Human Input node `hi` with Dify's defaults and [data].
Node hiNode(Map<String, Object?> data, {List<Node> others = const [], String id = 'hi', int x = 400}) => difyNode(
  id,
  {'type': 'human-input', ...humanInputDefaultValue, 'title': 'Human Input', ...data},
  others: others,
  x: x,
);

/// The members fixture of the recipient specs.
const members = [
  HiMember(id: 'member-1', email: 'member-1@example.com', name: 'Member One'),
  HiMember(id: 'member-2', email: 'member-2@example.com', name: 'Member Two'),
];

/// The host of the tests: the workspace "Dify's Lab", the owner and [members].
HumanInputHost host(
  Widget child, {
  List<HiMember> list = members,
  bool? emailDeliveryEnabled = true,
  SendTestEmail? sendTestEmail,
  VoidCallback? onUpgrade,
}) => HumanInputHost(
  members: list,
  userEmail: 'owner@example.com',
  userName: 'Owner',
  workspaceName: "Dify's Lab",
  emailDeliveryEnabled: emailDeliveryEnabled,
  sendTestEmail: sendTestEmail,
  onUpgrade: onUpgrade,
  child: child,
);

/// Renders the Human Input panel of node `hi`.
Future<void> renderPanel(
  WidgetTester t,
  Harness h, {
  Toasts? toasts,
  bool? emailDeliveryEnabled = true,
  SendTestEmail? sendTestEmail,
  double width = 600,
  WorkflowMenuOptionsX options = const WorkflowMenuOptionsX(),
}) => renderBody(
  t,
  h,
  'hi',
  humanInputPanelBody,
  width: width,
  options: options.options,
  toast: toasts?.call,
  host: (c) => host(c, emailDeliveryEnabled: emailDeliveryEnabled, sendTestEmail: sendTestEmail),
);

/// The panel's menu options (read-only via `canEdit: false`).
class WorkflowMenuOptionsX {
  const WorkflowMenuOptionsX({this.canEdit = true});
  final bool canEdit;
  WorkflowMenuOptions get options => WorkflowMenuOptions(canEdit: canEdit);
}

/// Pumps [child] (a component) in a 1000 px wide app with the test translator, the [DataPanelHost] toasts and the
/// [host] data.
Future<void> pumpComponent(
  WidgetTester t,
  Widget child, {
  Toasts? toasts,
  bool isCloud = false,
  Widget Function(Widget child)? wrap,
  double width = 600,
}) async {
  useDifyTestTranslator();
  t.view.physicalSize = const Size(1400, 1000);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final body = Align(
    alignment: Alignment.topLeft,
    child: Padding(
      padding: const EdgeInsets.all(40),
      child: SizedBox(width: width, child: child),
    ),
  );
  await t.pumpWidget(
    MaterialApp(
      home: Material(
        child: DataPanelHost(toast: toasts?.call, isCloud: isCloud, child: (wrap ?? host)(body)),
      ),
    ),
  );
  await t.pump();
}

TestGesture? _mouse;

/// Moves the test's mouse over [finder] (CSS `:hover`).
Future<TestGesture> hover(WidgetTester t, Finder finder) async {
  final at = t.getCenter(finder);
  var g = _mouse;
  if (g == null) {
    g = _mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
    await g.addPointer(location: at);
    addTearDown(() async {
      await _mouse?.removePointer();
      _mouse = null;
    });
  } else {
    await g.moveTo(at);
  }
  await t.pump();
  return g;
}

/// The control named [label] (`getByRole(…, { name })`).
Finder named(String label) => find.bySemanticsLabel(label);

/// Taps the control named [label].
Future<void> tapNamed(WidgetTester t, String label) async {
  await t.tap(named(label).first);
  await t.pump(const Duration(milliseconds: 300));
}

/// The callback calls (vi.fn()).
class Calls<T> {
  final calls = <T>[];
  void call(T v) => calls.add(v);
  int get length => calls.length;
  T get last => calls.last;
}

/// A [DataToastType] list helper.
List<String> errorsOf(Toasts t) => [
  for (final (type, m) in t.list)
    if (type == DataToastType.error) m,
];

/// The text field of the [DifyInput] named [label].
Finder inputNamed(String label) => find.descendant(
  of: find.byWidgetPredicate((w) => w is DifyInput && w.semanticLabel == label),
  matching: find.byType(EditableText),
);

/// The icon button named [label].
Finder iconButton(String label) =>
    find.byWidgetPredicate((w) => w is DifyIconButton && w.label == label, description: 'icon button "$label"');

/// Taps [finder] and lets popups and dialogs animate.
Future<void> tapAndSettle(WidgetTester t, Finder finder) async {
  await t.tap(finder);
  for (var i = 0; i < 4; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

/// A button that opens a dialog with [open] and keeps what it returned in [results].
class Opener<T> extends StatelessWidget {
  const Opener({super.key, required this.open, required this.results});
  final Future<T> Function(BuildContext context) open;
  final List<T> results;

  @override
  Widget build(BuildContext context) =>
      DifyButton(onPressed: () async => results.add(await open(context)), child: const Text('open'));
}

/// Dify's test translator, except [texts] (key: English text) render as written (with their Trans tags).
class EnglishFor extends DifyTestTranslator {
  EnglishFor(this.texts);
  final Map<String, String> texts;

  @override
  String t(String ns, String key, [Map<String, Object?> params = const {}]) => texts[key] ?? super.t(ns, key, params);
}

/// Whether the primary focus is inside [finder]'s widget.
bool focusIn(WidgetTester t, Finder finder) {
  final target = t.element(finder);
  final ctx = FocusManager.instance.primaryFocus?.context;
  if (ctx == null) return false;
  if (ctx == target) return true;
  var found = false;
  ctx.visitAncestorElements((e) {
    if (e == target) found = true;
    return !found;
  });
  return found;
}
