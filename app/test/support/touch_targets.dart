// Touch targets as the platform gets them, for the phone tests: a control's own semantics node, at least 44 dp
// square, all of its reported bounds hittable (a tap at the centre and 2 dp inside each edge reaches a gesture of the
// control), and controls not overlapping.
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// [n]'s rectangle in the window (a semantics node's rect is in its parent's coordinates).
Rect globalSemanticsRect(SemanticsNode n) {
  var r = n.rect;
  for (SemanticsNode? x = n; x != null; x = x.parent) {
    if (x.transform case final m?) r = MatrixUtils.transformRect(m, r);
  }
  return r;
}

/// The semantics node control [el] is for the platform: the first node its render objects form (a node merged into
/// a parent: that parent), else the node it is part of.
SemanticsNode semanticsNodeOf(WidgetTester t, Element el) {
  final queue = <RenderObject>[el.renderObject!];
  while (queue.isNotEmpty) {
    final r = queue.removeAt(0);
    if (r.debugSemantics case final n?) {
      var m = n;
      while (m.isMergedIntoParent && m.parent != null) {
        m = m.parent!;
      }
      return m;
    }
    r.visitChildren(queue.add);
  }
  return t.getSemantics(find.byElementPredicate((x) => x == el));
}

/// [el], scrolled to the middle of its scroll view, is for the platform a node at least 44 dp square (what TalkBack
/// focuses and an accessibility scanner measures); returns that node's rectangle in the scroll view's content (to
/// compare controls measured at different scroll offsets) and its name.
Future<(Rect, String)> expectTouchTarget(WidgetTester t, Element el, String what) async {
  if (Scrollable.maybeOf(el) != null) await Scrollable.ensureVisible(el, alignment: 0.5);
  for (var i = 0; i < 3; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
  final node = semanticsNodeOf(t, el);
  final data = node.getSemanticsData();
  final name = '${el.widget.runtimeType} ${data.label}${data.value.isEmpty ? '' : ' (${data.value})'}'.replaceAll(
    '\n',
    ' ',
  );
  expect(node.rect.width, greaterThanOrEqualTo(44), reason: '$what: "$name" accessible width ${node.rect}');
  expect(node.rect.height, greaterThanOrEqualTo(44), reason: '$what: "$name" accessible height ${node.rect}');
  expectHittable(t, el, node, '$what: "$name"');
  final scroll = Scrollable.maybeOf(el);
  final shift = scroll == null
      ? Offset.zero
      : scroll.position.axis == Axis.vertical
      ? Offset(0, scroll.position.pixels)
      : Offset(scroll.position.pixels, 0);
  return (globalSemanticsRect(node).shift(shift), name);
}

/// The bounds [node] reports are all hittable: a tap at their centre and 2 dp inside each edge reaches a pointer
/// listener (a gesture detector) of the control that forms the node, not padding or a border around it, nor a
/// neighbour (the platform sends a touch there to the control).
void expectHittable(WidgetTester t, Element el, SemanticsNode node, String what) {
  // The render object that forms the node (the control's own, or the box it is merged into).
  RenderObject? owner = el.renderObject;
  final queue = <RenderObject>[owner!];
  while (queue.isNotEmpty && owner?.debugSemantics != node) {
    final r = queue.removeAt(0);
    if (r.debugSemantics == node) {
      owner = r;
      break;
    }
    r.visitChildren(queue.add);
  }
  if (owner?.debugSemantics != node) {
    for (RenderObject? r = el.renderObject; r != null; r = r.parent) {
      if (r.debugSemantics == node) {
        owner = r;
        break;
      }
    }
  }
  expect(owner?.debugSemantics, node, reason: '$what: the node\'s render object');
  final listeners = <RenderObject>{};
  void collect(RenderObject r) {
    if (r is RenderPointerListener) listeners.add(r);
    r.visitChildren(collect);
  }

  collect(owner!);
  final r = globalSemanticsRect(node);
  for (final p in [
    r.center,
    Offset(r.center.dx, r.top + 2),
    Offset(r.center.dx, r.bottom - 2),
    Offset(r.left + 2, r.center.dy),
    Offset(r.right - 2, r.center.dy),
  ]) {
    final path = t.hitTestOnBinding(p).path.map((e) => e.target);
    expect(
      path.any(listeners.contains),
      isTrue,
      reason: '$what: a tap at $p in its bounds $r reaches no gesture of it',
    );
  }
}

/// No two of [targets] overlap.
void expectApart(List<(Rect, String)> targets, String what) {
  for (var i = 0; i < targets.length; i++) {
    for (var j = i + 1; j < targets.length; j++) {
      final (a, an) = targets[i];
      final (b, bn) = targets[j];
      final o = a.intersect(b);
      expect(o.width > 0.5 && o.height > 0.5, isFalse, reason: '$what: "$an" $a and "$bn" $b overlap');
    }
  }
}
