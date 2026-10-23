/// The container (Iteration / Loop) canvas interactions as pure functions over React Flow nodes in Dify's JSON shape
/// (`{id, type, parentId, position: {x, y}, width, height, data}`): iteration/use-interactions(.helpers).ts and
/// loop/use-interactions(.helpers).ts. dify-sf's canvas does not call them yet (it sizes containers from the stored
/// `_dify_node` size); they are the logic its auto-grow, drag clamp and child copy will use.
library;

import '../../../../../workflow/dify_json.dart';

typedef RfNode = Map<String, Object?>;

/// `ITERATION_PADDING` / `LOOP_PADDING` (constants.ts): both `{top: 65, right: 16, bottom: 20, left: 16}`.
const containerPadding = (top: 65.0, right: 16.0, bottom: 20.0, left: 16.0);

/// `NESTED_ELEMENT_Z_INDEX`.
const nestedElementZIndex = 1001;

num _x(RfNode n) => jsGet(n['position'], 'x') as num? ?? 0;
num _y(RfNode n) => jsGet(n['position'], 'y') as num? ?? 0;
num _w(RfNode n) => n['width'] as num? ?? 0;
num _h(RfNode n) => n['height'] as num? ?? 0;

/// The child reaching furthest right and the one reaching furthest down.
typedef ContainerBounds = ({RfNode? rightNode, RfNode? bottomNode});

/// `getIterationContainerBounds` / `getContainerBounds`.
ContainerBounds getContainerBounds(List<RfNode> children) {
  RfNode? right, bottom;
  for (final n in children) {
    if (right == null || _x(n) + _w(n) > _x(right) + _w(right)) right = n;
    if (bottom == null || _y(n) + _h(n) > _y(bottom) + _h(bottom)) bottom = n;
  }
  return (rightNode: right, bottomNode: bottom);
}

/// `getIterationContainerResize` / `getContainerResize`: the width / height the container grows to (null: keeps).
({num? width, num? height}) getContainerResize(RfNode current, ContainerBounds bounds) {
  final r = bounds.rightNode, b = bounds.bottomNode;
  return (
    width: r != null && _w(current) < _x(r) + _w(r) ? _x(r) + _w(r) + containerPadding.right : null,
    height: b != null && _h(current) < _y(b) + _h(b) ? _y(b) + _h(b) + containerPadding.bottom : null,
  );
}

/// `getRestrictedIterationPosition` / `getRestrictedLoopPosition`: where a dragged child of [parent] is held
/// ([flag] is `isInIteration` / `isInLoop`; null coordinates are free).
({num? x, num? y}) getRestrictedPosition(RfNode node, RfNode? parent, {required String flag}) {
  if (!jsTruthy(jsGet(node['data'], flag)) || parent == null) return (x: null, y: null);
  num? x, y;
  const p = containerPadding;
  if (_y(node) < p.top) y = p.top;
  if (_x(node) < p.left) x = p.left;
  if (_x(node) + _w(node) > _w(parent) - p.right) x = _w(parent) - p.right - _w(node);
  if (_y(node) + _h(node) > _h(parent) - p.bottom) y = _h(parent) - p.bottom - _h(node);
  return (x: x, y: y);
}

/// `getIterationChildren` / `getLoopChildren`: the children of [nodeId] except its start node ([startType]).
List<RfNode> getContainerChildren(List<RfNode> nodes, String nodeId, {required String startType}) => [
  for (final n in nodes)
    if (n['parentId'] == nodeId && n['type'] != startType) n,
];

/// `handleNodeIterationRerender` / `handleNodeLoopRerender`: [nodes] with the container [nodeId] grown to fit its
/// children, or null when it already fits.
List<RfNode>? containerRerender(List<RfNode> nodes, String nodeId) {
  final current = nodes.firstWhere((n) => n['id'] == nodeId);
  final resize = getContainerResize(
    current,
    getContainerBounds([
      for (final n in nodes)
        if (n['parentId'] == nodeId) n,
    ]),
  );
  if (resize.width == null && resize.height == null) return null;
  return [
    for (final n in nodes)
      if (n['id'] == nodeId)
        {
          ...n,
          if (resize.width != null) 'width': resize.width,
          if (resize.height != null) 'height': resize.height,
          'data': {
            ...?(n['data'] as Map?)?.cast<String, Object?>(),
            if (resize.width != null) 'width': resize.width,
            if (resize.height != null) 'height': resize.height,
          },
        }
      else
        n,
  ];
}

/// `handleNode…ChildDrag`: the restriction for [node] inside its parent among [nodes].
({num? x, num? y}) containerChildDrag(List<RfNode> nodes, RfNode node, {required String flag}) =>
    getRestrictedPosition(node, nodes.where((n) => n['id'] == node['parentId']).firstOrNull, flag: flag);

/// `handleNode…ChildSizeChange`: the container to re-render after [nodeId] changed size (its parent), or null.
String? containerOfResized(List<RfNode> nodes, String nodeId) {
  final parent = nodes.firstWhere((n) => n['id'] == nodeId)['parentId'];
  return parent is String && parent.isNotEmpty ? parent : null;
}

/// `generateNewNode(params)` (utils/node.ts): the node a copy is made into (Dify adds the id and React Flow fields).
typedef GenerateNewNode = RfNode Function(RfNode params);

/// Copies of a container's children: the new nodes and the id mapping (old id to new id) extended with them.
typedef ChildrenCopy = ({List<RfNode> copyChildren, Map<String, String> newIdMapping});

// ---- iteration -----------------------------------------------------------------------------------------------------

/// `getNextChildNodeTypeCount`: the running per-type count of copied children (counting [nodesWithSameTypeCount]
/// existing nodes first).
int getNextChildNodeTypeCount(Map<String, int> counts, String type, int nodesWithSameTypeCount) =>
    counts[type] = counts[type] == null || counts[type] == 0 ? nodesWithSameTypeCount + 1 : counts[type]! + 1;

/// `buildIterationChildCopy`.
RfNode buildIterationChildCopy({
  required RfNode child,
  required String childNodeType,
  required Map<String, Object?> defaultValue,
  required String title,
  required String newNodeId,
}) => {
  'type': child['type'],
  'data': {
    ...defaultValue,
    ...?(child['data'] as Map?)?.cast<String, Object?>(),
    'selected': false,
    '_isBundled': false,
    '_connectedSourceHandleIds': const <String>[],
    '_connectedTargetHandleIds': const <String>[],
    'title': title,
    'iteration_id': newNodeId,
    'type': childNodeType,
  },
  'position': child['position'],
  'positionAbsolute': child['positionAbsolute'],
  'parentId': newNodeId,
  'extent': child['extent'],
  'zIndex': nestedElementZIndex,
};

/// `handleNodeIterationChildrenCopy`: [blockTitle] is `t('blocks.<type>')`, [defaultValueOf] the type's default
/// data, [customTypeOf] `getNodeCustomTypeByNodeDataType`.
ChildrenCopy iterationChildrenCopy(
  List<RfNode> nodes,
  String nodeId,
  String newNodeId,
  Map<String, String> idMapping, {
  required GenerateNewNode generateNewNode,
  required String Function(String type) blockTitle,
  required Map<String, Object?> Function(String type) defaultValueOf,
  String Function(String type) customTypeOf = _custom,
}) {
  final children = getContainerChildren(nodes, nodeId, startType: 'custom-iteration-start');
  final mapping = {...idMapping};
  final counts = <String, int>{};
  final copies = <RfNode>[];
  for (final (index, child) in children.indexed) {
    final type = jsStr(jsGet(child['data'], 'type')) ?? '';
    final sameType = nodes.where((n) => jsGet(n['data'], 'type') == type).length;
    final next = getNextChildNodeTypeCount(counts, type, sameType);
    final title = sameType > 0 ? '${blockTitle(type)} $next' : blockTitle(type);
    final copy = buildIterationChildCopy(
      child: child,
      childNodeType: type,
      defaultValue: defaultValueOf(type),
      title: title,
      newNodeId: newNodeId,
    );
    final node = {
      ...generateNewNode({...copy, 'type': customTypeOf(type)}),
    };
    node['id'] = '$newNodeId${'${node['id']}$index'}';
    mapping['${child['id']}'] = node['id']! as String;
    copies.add(node);
  }
  return (copyChildren: copies, newIdMapping: mapping);
}

String _custom(String _) => 'custom';

// ---- loop ----------------------------------------------------------------------------------------------------------

/// `buildLoopChildCopy`: the copy's params and its id suffix (`<newNodeId><index>`).
({RfNode params, String newId}) buildLoopChildCopy({
  required RfNode child,
  required String childNodeType,
  required Map<String, Object?> defaultValue,
  required int nodesWithSameTypeCount,
  required String newNodeId,
  required int index,
}) => (
  params: {
    'type': child['type'],
    'data': {
      ...defaultValue,
      ...?(child['data'] as Map?)?.cast<String, Object?>(),
      'selected': false,
      '_isBundled': false,
      '_connectedSourceHandleIds': const <String>[],
      '_connectedTargetHandleIds': const <String>[],
      '_dimmed': false,
      'title': nodesWithSameTypeCount > 0
          ? '${defaultValue['title']} ${nodesWithSameTypeCount + 1}'
          : defaultValue['title'],
      'isInLoop': true,
      'loop_id': newNodeId,
      'type': childNodeType,
    },
    'position': child['position'],
    'positionAbsolute': child['positionAbsolute'],
    'parentId': newNodeId,
    'extent': child['extent'],
    'zIndex': nestedElementZIndex,
  },
  newId: '$newNodeId$index',
);

/// `handleNodeLoopChildrenCopy`.
ChildrenCopy loopChildrenCopy(
  List<RfNode> nodes,
  String nodeId,
  String newNodeId,
  Map<String, String> idMapping, {
  required GenerateNewNode generateNewNode,
  required Map<String, Object?> Function(String type) defaultValueOf,
  String Function(String type) customTypeOf = _custom,
}) {
  final children = getContainerChildren(nodes, nodeId, startType: 'custom-loop-start');
  final mapping = {...idMapping};
  final copies = <RfNode>[];
  for (final (index, child) in children.indexed) {
    final type = jsStr(jsGet(child['data'], 'type')) ?? '';
    final sameType = nodes.where((n) => jsGet(n['data'], 'type') == type).length;
    final copy = buildLoopChildCopy(
      child: child,
      childNodeType: type,
      defaultValue: defaultValueOf(type),
      nodesWithSameTypeCount: sameType,
      newNodeId: newNodeId,
      index: index,
    );
    final node = {
      ...generateNewNode({...copy.params, 'type': customTypeOf(type)}),
    };
    node['id'] = '$newNodeId${node['id']}${copy.newId}';
    mapping['${child['id']}'] = node['id']! as String;
    copies.add(node);
  }
  return (copyChildren: copies, newIdMapping: mapping);
}
