import 'package:flutter/widgets.dart';

import 'card_kit.dart';

/// How the card around a body is drawn.
enum CardChrome {
  /// nodes/_base/node.tsx: header, body, description; 240 wide, shadow-xs (shadow-lg on hover).
  base,

  /// Iteration and Loop: the base chrome at the node's size ([NodeBody.cardSize]), translucent, no description.
  container,

  /// SimpleNode (loop-end): the base chrome without a description.
  simple,

  /// Iteration Start (`custom-iteration-start`): a 44 px tile 4 px below the node's top, shadow-xs, no header.
  marker,

  /// Loop Start (`custom-loop-start`): [marker] without the shadow.
  flatMarker,

  /// datasource-empty (`custom-data-source-empty`): only the body, in a 240 wide card with shadow-xs.
  bodyOnly;

  bool get header => this == base || this == container || this == simple;
  bool get isMarker => this == marker || this == flatMarker;
}

/// The part of a card below the header, per node type (each type's node.tsx). Heights and handle positions are
/// computed from the node's data so the canvas knows them without laying the widget out; they must match [build].
abstract class NodeBody {
  const NodeBody();

  /// The body's height; 0 for none.
  double height(BodyContext ctx);

  /// The card around the body.
  CardChrome get chrome => CardChrome.base;

  /// Source handles by id, as the y of the handle's middle measured from the body's top; null for the default single
  /// `source` handle next to the header.
  Map<String, double>? sources(BodyContext ctx) => null;

  /// Whether the node has a target (input) handle.
  bool get target => true;

  /// The card's size when the node sets it (containers keep their width and height); null: 240 wide, as tall as
  /// header + body + description.
  Size? cardSize(BodyContext ctx) => null;

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
