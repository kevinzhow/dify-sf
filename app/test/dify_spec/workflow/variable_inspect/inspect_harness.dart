import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:dify_sf_app/src/workflow_editor/variable_inspect/inspect_vars.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

export '../../dify_test_i18n.dart';

/// Dify's spec fixture `createVariable` (a node variable).
DifyJson createVariable([DifyJson overrides = const {}]) => {
  'id': 'var-1',
  'type': VarInInspectType.node,
  'name': 'result',
  'description': '',
  'selector': ['node-1', 'result'],
  'value_type': 'string',
  'value': 'value',
  'edited': false,
  'visible': true,
  'is_truncated': false,
  'full_content': {'size_bytes': 0, 'download_url': ''},
  ...overrides,
};

/// A node group of the store (`NodeWithVar`).
DifyJson createNodeWithVar({
  String nodeId = 'node-1',
  String type = 'code',
  String title = 'Code',
  List<DifyJson> vars = const [],
  bool isValueFetched = true,
}) => {
  'nodeId': nodeId,
  'nodePayload': {'type': type, 'title': title, 'desc': ''},
  'nodeType': type,
  'title': title,
  'vars': vars,
  'isValueFetched': isValueFetched,
};

/// The draft variable endpoints with every call recorded; [nodeVars] answers `fetchNodeInspectVars`.
class RecordingServices extends VariableInspectServices {
  RecordingServices({this.nodeVars = const {}, this.systemVars = const [], this.lastRun = const {}});

  final Map<String, List<DifyJson>> nodeVars;
  final List<DifyJson> systemVars;

  /// `resetToLastRunValue`'s answers by variable id.
  final Map<String, Object?> lastRun;
  final calls = <String>[];

  @override
  Future<List<DifyJson>?> fetchNodeInspectVars(String nodeId) async {
    calls.add('fetchNodeInspectVars $nodeId');
    return nodeVars[nodeId];
  }

  @override
  Future<List<DifyJson>> fetchSystemVars() async => systemVars;

  @override
  Future<void> editInspectVar(String varId, Object? value) async => calls.add('edit $varId');

  @override
  Future<DifyJson?> resetToLastRunValue(String varId) async {
    calls.add('reset $varId');
    return lastRun.containsKey(varId) ? {'id': varId, 'value': lastRun[varId]} : null;
  }

  @override
  Future<void> deleteAllInspectVars() async => calls.add('deleteAll');

  @override
  Future<void> deleteNodeInspectVars(String nodeId) async => calls.add('deleteNode $nodeId');

  @override
  void openUrl(String url) => calls.add('open $url');
}

/// The inspect data of a test: [store] and its crud.
class InspectHarness {
  InspectHarness({WorkflowStore? store, VariableInspectServices? services, Iterable<Node> nodes = const []})
    : store = store ?? WorkflowStore() {
    crud = InspectVarsCrud(store: this.store, services: services ?? RecordingServices(), nodes: () => nodes);
  }

  final WorkflowStore store;
  late final InspectVarsCrud crud;
  final viewed = <String>[];
  var stops = 0;

  /// [child] with the store, the preferences and the inspect scope above it.
  Widget wrap(Widget child, {WorkflowPreferences? preferences}) => WorkflowStoreScope(
    store: store,
    preferences: preferences,
    child: VariableInspectScope(crud: crud, onViewNode: viewed.add, onStop: () => stops++, child: child),
  );

  /// Pumps [child] in an [width] x [height] box with the store, the preferences and the inspect scope.
  Future<void> pump(
    WidgetTester t,
    Widget child, {
    double width = 960,
    double height = 400,
    WorkflowPreferences? preferences,
  }) async {
    t.view.physicalSize = const Size(1400, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Material(
          child: wrap(
            Align(
              alignment: Alignment.topLeft,
              child: SizedBox(width: width, height: height, child: child),
            ),
            preferences: preferences,
          ),
        ),
      ),
    );
    await t.pump();
  }
}

/// The control named [label] (`getByRole('button', { name })`).
Finder pressable(String label) => find.byWidgetPredicate(
  (w) => w is DifyPressable && w.semanticLabel == label,
  description: 'button "$label"',
);

/// The text field labelled [label].
Finder fieldLabelled(String label) =>
    find.descendant(of: find.bySemanticsLabel(label), matching: find.byType(EditableText)).first;
