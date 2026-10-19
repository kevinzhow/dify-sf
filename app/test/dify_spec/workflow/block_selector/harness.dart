import 'package:dify_sf_app/src/workflow_editor/block_selector/block_selector.dart';
import 'package:dify_sf_app/src/workflow_editor/block_selector/selector_widgets.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../support/app_fonts.dart';
import '../../dify_test_i18n.dart';

import 'package:dify_sf_app/src/design/widgets/widgets.dart';

/// Per-test setup: Dify's key-echo translations, empty localStorage, fresh stored flags.
void setUpBlockSelectorTests() {
  setUp(() {
    useDifyTestTranslator();
    SharedPreferences.setMockInitialValues({});
    StoredFlag.reset();
  });
}

/// Renders [w] at the top-left of a 1600 × 1200 page with real text metrics, inside [data] (and [store]).
Future<void> pumpSelector(
  WidgetTester t,
  Widget w, {
  BlockSelectorData data = const BlockSelectorData(),
  WorkflowStore? store,
  double textScale = 1,
}) async {
  await useAppFonts();
  t.view.physicalSize = const Size(1600, 1200);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  Widget child = BlockSelectorScope(
    data: data,
    child: Align(
      alignment: Alignment.topLeft,
      child: Padding(padding: const EdgeInsets.all(20), child: w),
    ),
  );
  if (store != null) child = WorkflowStoreScope(store: store, child: child);
  await t.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(fontFamily: 'Noto Sans'),
      home: Material(
        child: textScale == 1
            ? child
            : MediaQuery.withClampedTextScaling(maxScaleFactor: textScale, minScaleFactor: textScale, child: child),
      ),
    ),
  );
  await t.pump();
  await t.pump(const Duration(milliseconds: 200));
}

/// Lets transitions and preview delays run.
Future<void> settle(WidgetTester t, [int ms = 400]) async {
  for (var i = 0; i < ms ~/ 100; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

/// A tap that also lets the popup transitions finish.
Future<void> tapText(WidgetTester t, String text) async {
  await t.tap(find.text(text).first);
  await settle(t, 500);
}

/// Hovers the mouse over [finder] (and waits past the 150 ms preview delay).
Future<TestGesture> hover(WidgetTester t, Finder finder) async {
  final g = await t.createGesture(kind: PointerDeviceKind.mouse);
  await g.addPointer(location: Offset.zero);
  addTearDown(g.removePointer);
  await g.moveTo(t.getCenter(finder));
  await settle(t, 500);
  return g;
}

/// The semantics node labelled [label] (getByRole's accessible name).
SemanticsNode semanticsOf(WidgetTester t, String label) => t.getSemantics(find.bySemanticsLabel(label).first);

/// The recorded calls of an [OnSelectBlock].
class SelectRecorder {
  final calls = <(String, Map<String, Object?>?)>[];
  void call(String type, [Map<String, Object?>? value]) => calls.add((type, value));
}

/// factories.ts createTool.
Map<String, Object?> toolJson(String name, String label, [String? description]) => {
  'name': name,
  'author': 'author',
  'label': {'en_US': label, 'zh_Hans': label},
  'description': {'en_US': description ?? '$label description', 'zh_Hans': description ?? '$label description'},
  'parameters': <Object?>[],
  'labels': <Object?>[],
  'output_schema': <String, Object?>{},
};

/// factories.ts createToolProvider.
ToolProvider toolProvider({
  String id = 'provider-1',
  String name = 'provider-one',
  String author = 'Provider Author',
  String label = 'Provider One',
  String type = 'builtin',
  String? pluginId = 'plugin-1',
  String? pluginUniqueIdentifier = 'plugin-1@1.0.0',
  List<Map<String, Object?>>? tools,
  String? zhLabel,
}) => ToolProvider.fromJson({
  'id': id,
  'name': name,
  'author': author,
  'description': {'en_US': 'Provider description'},
  'icon': 'icon',
  'icon_dark': 'icon-dark',
  'label': {'en_US': label, 'zh_Hans': zhLabel ?? label},
  'type': type,
  'is_team_authorization': false,
  'plugin_id': pluginId,
  'plugin_unique_identifier': pluginUniqueIdentifier,
  'meta': {'version': '1.0.0'},
  'tools': tools ?? [toolJson('tool-a', 'Tool A')],
});

/// factories.ts createPlugin.
MarketplacePlugin plugin({
  String pluginId = 'plugin-1',
  String org = 'org',
  String name = 'Plugin One',
  String label = 'Plugin One',
  String brief = 'Plugin description',
  String latestPackageIdentifier = 'plugin-1@1.0.0',
  int installCount = 0,
}) => MarketplacePlugin(
  pluginId: pluginId,
  org: org,
  name: name,
  label: {'en_US': label, 'zh_Hans': label},
  brief: {'en_US': brief},
  icon: 'icon',
  installCount: installCount,
  latestVersion: '1.0.0',
  latestPackageIdentifier: latestPackageIdentifier,
);

/// A block of the Nodes tab (index.spec createBlock).
BlockMeta block(String type, String title, {String classification = '-', num sort = 0}) =>
    BlockMeta(type: type, title: title, classification: classification, sort: sort, description: '$title description');

/// Whether keyboard focus is on [f] (the element, or something inside it, or the focus node it is inside).
bool hasFocusOn(WidgetTester t, Finder f) {
  final ctx = FocusManager.instance.primaryFocus?.context as Element?;
  if (ctx == null) return false;
  final target = t.element(f);
  if (ctx == target) return true;
  var found = false;
  target.visitAncestorElements((e) => !(found = e == ctx));
  if (found) return true;
  ctx.visitAncestorElements((e) => !(found = e == target));
  return found;
}

/// The search field whose placeholder (accessible name) is [label].
Finder searchField(String label) =>
    find.byWidgetPredicate((w) => w is DifyInput && w.placeholder == label, description: 'searchbox "$label"');

/// The text typed in the search field [label].
String searchValue(WidgetTester t, String label) => t
    .widget<EditableText>(find.descendant(of: searchField(label), matching: find.byType(EditableText)))
    .controller
    .text;

/// The block selector's dialog.
Finder dialogNamed(String label) => find.byWidgetPredicate(
  (w) => w is Semantics && w.properties.role == SemanticsRole.dialog && w.properties.label == label,
  description: 'dialog "$label"',
);

/// The tab [name] (role tab).
Finder tabNamed(String name) => find.ancestor(
  of: find.text(name),
  matching: find.byWidgetPredicate((w) => w is Semantics && w.properties.role == SemanticsRole.tab),
);

bool tabSelected(WidgetTester t, String name) => t.widget<Semantics>(tabNamed(name).first).properties.selected ?? false;
bool tabDisabled(WidgetTester t, String name) =>
    !(t.widget<Semantics>(tabNamed(name).first).properties.enabled ?? true);

/// [text] shown as a list row (not typed in a field).
Finder rowText(String text) => find.byWidgetPredicate((w) => w is Text && w.data == text, description: 'row "$text"');

/// The link (Semantics `link`) around [text].
Uri? linkUrlOf(WidgetTester t, String text) => t
    .widget<Semantics>(
      find
          .ancestor(
            of: find.text(text),
            matching: find.byWidgetPredicate((w) => w is Semantics && w.properties.link == true),
          )
          .first,
    )
    .properties
    .linkUrl;
