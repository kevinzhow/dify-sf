import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/workflow_editor/panel_fields/panel_fields.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../dify_test_i18n.dart';

export '../../dify_test_i18n.dart';

/// Renders [child] [width] wide at the top left of a 1024 x 768 screen, with Dify's test translator.
Future<void> render(WidgetTester t, Widget child, {double width = 360}) {
  useDifyTestTranslator();
  return t.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(40),
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(width: width, child: child),
          ),
        ),
      ),
    ),
  );
}

/// The `[...args]` of each call of a callback (vi.fn()).
class Calls<T> {
  final calls = <T>[];
  void call(T v) => calls.add(v);
  int get length => calls.length;
  T get last => calls.last;
}

/// A [VarScope] over [groups] whose nodes are [nodes] (by id), with Start [start].
VarScope scopeOf(List<VarGroup> groups, {List<Node> nodes = const [], Node? start, Node? parent, String? type}) {
  final byId = {for (final n in nodes) n.id: n};
  return VarScope(
    vars: groups,
    lookup: (id) => byId[id],
    start: start,
    parent: parent,
    typeOf: type == null ? null : (_) => type,
  );
}

/// The [VarReferenceItem] showing [text].
VarReferenceItem itemOf(WidgetTester t, String text) =>
    t.widget<VarReferenceItem>(find.ancestor(of: find.text(text), matching: find.byType(VarReferenceItem)).first);
