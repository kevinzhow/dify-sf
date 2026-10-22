import 'package:flutter/widgets.dart';

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
