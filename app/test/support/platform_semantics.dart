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

/// A node of the semantics tree as the platform gets it: its data (merged, for a node that merges its descendants)
/// and its bounds in the window, in logical pixels (what TalkBack's focus outlines, in dp).
typedef PlatformNode = ({SemanticsNode node, SemanticsData data, Rect rect});

/// The nodes of the semantics tree as the platform gets it, in [platformLabels]' order: a node that merges its
/// descendants is one node (theirs are not listed), an `OverlayPortal`'s overlay child counts under its place.
List<PlatformNode> platformNodes(WidgetTester t) {
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
  final dpr = t.view.devicePixelRatio;
  Rect global(SemanticsNode n) {
    var rect = n.rect;
    for (SemanticsNode? p = n; p != null; p = p.parent) {
      if (p.transform case final m?) rect = MatrixUtils.transformRect(m, rect);
    }
    return Rect.fromLTRB(rect.left / dpr, rect.top / dpr, rect.right / dpr, rect.bottom / dpr);
  }

  final out = <PlatformNode>[];
  void walk(SemanticsNode n) {
    out.add((node: n, data: n.getSemanticsData(), rect: global(n)));
    if (n.mergeAllDescendantsIntoThisNode) return;
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

/// What a screen reader announces for [n]: its label, value and hint (the parts it reads), joined with " / ".
String spokenText(PlatformNode n) => [n.data.label, n.data.value, n.data.hint].where((s) => s.isNotEmpty).join(' / ');

/// The nodes a screen reader stops at: with something to read or an action (a container without either is passed).
List<PlatformNode> platformStops(WidgetTester t) => [
  for (final n in platformNodes(t))
    if (spokenText(n).isNotEmpty || n.data.actions != 0) n,
];

/// One line per stop (spoken text, flags, size): for a test's failure reason.
String describeStops(List<PlatformNode> stops) => [
  for (final n in stops)
    '"${spokenText(n)}" ${n.data.flagsCollection.toStrings().join(',')} '
        '${n.rect.width.toStringAsFixed(0)}x${n.rect.height.toStringAsFixed(0)}',
].join('\n');
