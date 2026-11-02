// The semantics tree as Android and iOS get it (what TalkBack and uiautomator read), for the phone tests.
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// The labels of the semantics tree as the platform gets it, in tree order: an `OverlayPortal`'s overlay child
/// (a node with a traversal child identifier) counts under the node with the matching traversal parent identifier,
/// also when that node has no children of its own, and is dropped when there is no such node (the framework's
/// `SemanticsNode._addToUpdate` and `_childrenInHitTestOrder`).
List<String> platformLabels(WidgetTester t) {
  final roots = [for (final view in t.binding.renderViews) ?view.owner?.semanticsOwner?.rootSemanticsNode];
  final grafted = <Object, List<SemanticsNode>>{};
  void index(SemanticsNode n) {
    if (n.getSemanticsData().traversalChildIdentifier case final id?) (grafted[id] ??= []).add(n);
    n.visitChildren((c) {
      index(c);
      return true;
    });
  }

  roots.forEach(index);
  final out = <String>[];
  void walk(SemanticsNode n) {
    if (n.label.isNotEmpty) out.add(n.label);
    final children = <SemanticsNode>[];
    n.visitChildren((c) {
      if (c.getSemanticsData().traversalChildIdentifier == null) children.add(c);
      return true;
    });
    if (n.getSemanticsData().traversalParentIdentifier case final id?) children.addAll(grafted[id] ?? const []);
    children.forEach(walk);
  }

  roots.forEach(walk);
  return out;
}
