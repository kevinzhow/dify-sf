import 'package:flutter/widgets.dart';

import '../editor/editor_controller.dart';
import 'canvas_controller.dart';
import 'canvas_input.dart';
import 'live_card.dart';
import 'node_card.dart';

/// Interactive card content is a widget layer shared by the widget and Scene renderers. A captured button is
/// only pixels; this layer supplies its real hit target, clipped/occluded and transformed with its node.
class CanvasControlLayer extends StatelessWidget {
  const CanvasControlLayer({
    super.key,
    required this.canvas,
    required this.cards,
    required this.input,
    required this.changes,
  });
  final CanvasController canvas;
  final CardSpec cards;
  final CanvasInput input;
  final Listenable changes;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([changes, canvas.view, canvas.visualChanges, canvas.selection]),
    builder: (context, _) {
      final graph = canvas.graph;
      if (graph == null) return const SizedBox.shrink();
      final nodes = graph.nodes.where((n) => canvas.view.visible.overlaps(n.visual)).toList()
        ..sort((a, b) => input.stackKey(a).compareTo(input.stackKey(b)));
      return CanvasControlScope(
        canvas: canvas,
        editor: input.controller,
        child: Transform(
          transform: canvas.view.matrix,
          child: OverflowHitStack(
            children: [
              for (final node in nodes)
                for (final control in cards.controls(context, node, graph))
                  Positioned.fromRect(
                    key: ValueKey('card-control-${node.id}-${control.rect.top}'),
                    rect: control.rect,
                    child: ValueListenableBuilder(
                      valueListenable: node.run,
                      builder: (context, run, child) => CanvasInteractionGate(
                        opacity: run.opacity,
                        accepts: (local) => input.nodeAt(control.rect.topLeft + local) == node,
                        claim: input.claim,
                        child: child!,
                      ),
                      child: control.child,
                    ),
                  ),
            ],
          ),
        ),
      );
    },
  );
}

class CanvasControlScope extends InheritedWidget {
  const CanvasControlScope({super.key, required this.canvas, required this.editor, required super.child});
  final CanvasController canvas;
  final EditorController editor;
  static CanvasControlScope of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<CanvasControlScope>()!;
  @override
  bool updateShouldNotify(CanvasControlScope oldWidget) => oldWidget.canvas != canvas || oldWidget.editor != editor;
}
