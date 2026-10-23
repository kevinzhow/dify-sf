/// Layout probe of a node panel, to compare with Dify's boxes (tool/visual/dom_probe.py --panels): opens the node
/// panel of a panel case of tool/visual/cases.json (its workflow file converted as the server imports it) at the
/// case's size and writes the panel's boxes, relative to the panel's top-left corner, to `<PANEL_PROBE_OUT>/<case>.txt`
/// (default build/panel_probe). Only runs when `PANEL_PROBE` names the cases (comma separated, or `all`):
///
///     PANEL_PROBE=panel-end flutter test test/panel_probe_test.dart
library;

import 'dart:convert';
import 'dart:io';

import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/design/dify_theme.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/workflow_editor/context_menu/clipboard.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/node_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

import 'dify_spec/workflow/node_panel/harness.dart';
import 'support/app_fonts.dart';

Object? _plain(Object? y) => switch (y) {
  YamlMap m => {for (final e in m.entries) '${e.key}': _plain(e.value)},
  YamlList l => [for (final v in l) _plain(v)],
  _ => y,
};

void main() {
  final only = Platform.environment['PANEL_PROBE'];
  if (only == null) return;
  final outDir = Directory(Platform.environment['PANEL_PROBE_OUT'] ?? 'build/panel_probe')..createSync(recursive: true);
  final cases = [
    for (final c
        in (jsonDecode(File('../tool/visual/cases.json').readAsStringSync()) as List).cast<Map<String, Object?>>())
      if (c['select'] != null && (only == 'all' || only.split(',').contains(c['id']))) c,
  ];
  for (final c in cases) {
    testWidgets(
      'panel probe ${c['id']}',
      (t) => _probe(t, c, File('${outDir.path}/${c['id']}.txt')),
      // The desktop platform the app runs on (Material's compact density and such).
      variant: TargetPlatformVariant.only(TargetPlatform.linux),
    );
  }
}

Future<void> _probe(WidgetTester t, Map<String, Object?> c, File file) async {
  await useAppFonts();
  await (FontLoader('DejaVu Sans Mono')..addFont(rootBundle.load('assets/fonts/DejaVuSansMono.ttf'))).load();
  final yaml = _plain(loadYaml(File('../${c['fixture']}').readAsStringSync())) as Map<String, Object?>;
  final graph = ((yaml['workflow'] as Map)['graph'] as Map).cast<String, Object?>();
  var doc = Document();
  final nodes = <Node>[];
  for (final n in (graph['nodes'] as List).cast<Map<String, Object?>>()) {
    nodes.add(nodeFromDify(n, doc, id: n['id']! as String));
    doc = Document(nodes: nodes);
  }
  final edges = [
    for (final e in (graph['edges'] as List).cast<Map<String, Object?>>())
      Edge(
        id: e['id']! as String,
        source: e['source']! as String,
        sourceHandle: e['sourceHandle'] == 'source' ? 'out' : e['sourceHandle'] as String? ?? 'out',
        target: e['target']! as String,
      ),
  ];
  final h = await Harness.start(t, nodes, edges: edges);
  await t.runAsync(() => DifyI18n.load('en-US'));
  final window = (c['oursWindow'] ?? c['window'])! as List;
  // The panels slot: `absolute top-14 right-0 bottom-1`.
  final size = Size((window[0] as num).toDouble(), (window[1] as num).toDouble() - 56 - 4);
  t.view
    ..physicalSize = size * 2
    ..devicePixelRatio = 2;
  h.store.setWorkflowCanvasWidth(size.width);
  final nodeId = c['select']! as String;
  h.controller.selectNode(nodeId);
  await t.pumpWidget(
    panelApp(
      h,
      // The app theme (panelApp's MaterialApp has the default one).
      Theme(
        data: difyTheme(fontFamily: 'Noto Sans'),
        child: DefaultTextStyle.merge(
          style: const TextStyle(fontFamily: 'Noto Sans'),
          child: WorkflowNodePanel(key: ValueKey(nodeId), node: h[nodeId]!, actions: panelActions(h)),
        ),
      ),
    ),
  );
  await settle(t, 1500);

  // The panel's outer box: the one with the panel border.
  final panel = find.byType(WorkflowNodePanel).evaluate().first.renderObject! as RenderBox;
  RenderBox? outer;
  void findOuter(RenderObject o) {
    if (outer != null) return;
    if (o is RenderDecoratedBox && o.decoration is BoxDecoration && (o.decoration as BoxDecoration).boxShadow != null) {
      outer = o;
      return;
    }
    o.visitChildren(findOuter);
  }

  panel.visitChildren(findOuter);
  final origin = outer!.localToGlobal(Offset.zero);
  final out = StringBuffer();
  String f(double v) => v.toStringAsFixed(2);
  void walk(RenderObject o, int depth, Rect? parent) {
    if (o is! RenderBox || !o.hasSize) {
      o.visitChildren((c) => walk(c, depth, parent));
      return;
    }
    final r = MatrixUtils.transformRect(o.getTransformTo(null), Offset.zero & o.size).shift(-origin);
    String? what;
    if (o is RenderParagraph) {
      final s = o.text.style;
      what = 'text ${s?.fontSize}/${s?.height} ${jsonEncode(o.text.toPlainText())}';
    } else if (o is RenderEditable) {
      final len = o.text?.toPlainText().length ?? 0;
      final lines = {
        for (final b in o.getBoxesForSelection(TextSelection(baseOffset: 0, extentOffset: len)))
          '${f(b.top)}-${f(b.bottom)}',
      };
      what = 'editable ${jsonEncode(o.text?.toPlainText())} lines ${lines.join(' ')}';
    } else if (o is RenderDecoratedBox && o.decoration is BoxDecoration) {
      final d = o.decoration as BoxDecoration;
      final b = d.border;
      what =
          'box${d.color == null ? '' : ' bg=${d.color}'}'
          '${b is Border ? ' border=${b.top.width},${b.right.width},${b.bottom.width},${b.left.width}' : ''}';
    } else if ('${o.runtimeType}' == 'RenderCssMiddle') {
      what = 'css-middle';
    } else if (o is RenderPadding) {
      what = 'pad ${o.padding}';
    } else if ((o is RenderCustomPaint && '${o.painter.runtimeType}' == '_PicturePainter') ||
        RegExp('Picture|Svg|Vector').hasMatch(o.runtimeType.toString())) {
      what = 'icon';
    } else if (o.runtimeType.toString().contains('ColoredBox')) {
      what = 'box bg=${(o as dynamic).color}';
    }
    final show =
        what != null &&
        (r != parent || o is RenderParagraph || o is RenderEditable || what.startsWith('box') || what == 'icon');
    if (show) {
      out.writeln(
        '${'  ' * depth}${o.runtimeType} x=${f(r.left)} y=${f(r.top)} w=${f(r.width)} h=${f(r.height)} $what',
      );
    }
    o.visitChildren((c) => walk(c, show ? depth + 1 : depth, r));
  }

  walk(outer!, 0, null);
  file.writeAsStringSync(out.toString());
  await h.dispose(t);
}
