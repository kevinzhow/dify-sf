import 'package:flutter/widgets.dart';

import 'card_kit.dart';

/// The part of a card below the header, per node type (each type's node.tsx). Heights and handle positions are
/// computed from the node's data so the canvas knows them without laying the widget out; they must match [build].
abstract class NodeBody {
  const NodeBody();

  /// The body's height; 0 for none.
  double height(BodyContext ctx);

  /// Source handles by id, as the y of the handle's middle measured from the body's top; null for the default single
  /// `source` handle next to the header.
  Map<String, double>? sources(BodyContext ctx) => null;

  /// Whether the node has a target (input) handle.
  bool get target => true;

  Widget build(BuildContext context, BodyContext ctx);
}

/// No body (the header only).
class NoBody extends NodeBody {
  const NoBody();

  @override
  double height(BodyContext ctx) => 0;

  @override
  Widget build(BuildContext context, BodyContext ctx) => const SizedBox.shrink();
}
