import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// Whole-row sorting waits for a finger long press so a normal swipe can scroll
/// the surrounding panel. Mouse and stylus keep their immediate drag behavior.
class DifyReorderableDragStartListener extends StatelessWidget {
  const DifyReorderableDragStartListener({super.key, required this.index, required this.child, this.enabled = true});
  final int index;
  final Widget child;
  final bool enabled;

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: !enabled
        ? null
        : (event) {
            final list = SliverReorderableList.maybeOf(context);
            if (list == null) return;
            final recognizer = event.kind == PointerDeviceKind.touch
                ? DelayedMultiDragGestureRecognizer(debugOwner: this)
                : ImmediateMultiDragGestureRecognizer(debugOwner: this);
            list.startItemDragReorder(
              index: index,
              event: event,
              recognizer: recognizer..gestureSettings = MediaQuery.maybeGestureSettingsOf(context),
            );
          },
    child: child,
  );
}

/// Dify's embedded drag list: no Material overlay, implicit elevation or screen
/// padding. Callers provide their original list's drag proxy.
class DifyReorderableList extends StatelessWidget {
  const DifyReorderableList({
    super.key,
    required this.children,
    required this.onReorderItem,
    this.proxyDecorator,
    this.shrinkWrap = true,
    this.physics = const NeverScrollableScrollPhysics(),
  });
  final List<Widget> children;
  final ReorderCallback onReorderItem;
  final ReorderItemProxyDecorator? proxyDecorator;
  final bool shrinkWrap;
  final ScrollPhysics physics;
  @override
  Widget build(BuildContext context) => ReorderableList(
    itemCount: children.length,
    itemBuilder: (context, index) => children[index],
    onReorderItem: onReorderItem,
    proxyDecorator: proxyDecorator,
    shrinkWrap: shrinkWrap,
    physics: physics,
    padding: EdgeInsets.zero,
  );
}
