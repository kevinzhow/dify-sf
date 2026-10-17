// Simplified port of web/app/components/workflow/utils/workflow-init.ts initialNodes()/initialEdges() (lines 190-370).
// Kept: type default, zIndex, _connectedSourceHandleIds/_connectedTargetHandleIds, if-else _targetBranches, edge defaults
// (type 'custom', handles, sourceType/targetType, isInIteration/isInLoop flags). Dropped: iteration/loop start-node synthesis,
// legacy provider correction, tool/http defaults, cycle-edge filtering (generated graphs are DAGs without those node kinds).
const clone = <T>(v: T): T => JSON.parse(JSON.stringify(v))

export function initialNodesImpl(originNodes: any[], originEdges: any[]): any[] {
  const nodes = clone(originNodes)
  const edges = clone(originEdges)
  const bySrc = new Map<string, any[]>()
  const byTgt = new Map<string, any[]>()
  for (const e of edges) {
    if (!bySrc.has(e.source)) bySrc.set(e.source, [])
    bySrc.get(e.source)!.push(e)
    if (!byTgt.has(e.target)) byTgt.set(e.target, [])
    byTgt.get(e.target)!.push(e)
  }
  return nodes.map((node: any) => {
    node.zIndex = 0
    if (!node.type) node.type = 'custom'
    node.data._connectedSourceHandleIds = (bySrc.get(node.id) ?? []).map((e) => e.sourceHandle || 'source')
    node.data._connectedTargetHandleIds = (byTgt.get(node.id) ?? []).map((e) => e.targetHandle || 'target')
    if (node.data.type === 'if-else') {
      node.data._targetBranches = [...(node.data.cases ?? []).map((c: any) => ({ id: c.case_id, name: '' })), { id: 'false', name: '' }]
    }
    return node
  })
}

export function initialEdgesImpl(originEdges: any[], originNodes: any[]): any[] {
  const edges = clone(originEdges)
  const nodesMap = new Map<string, any>(originNodes.map((n: any) => [n.id, n]))
  return edges.map((edge: any) => {
    edge.type = 'custom'
    if (!edge.sourceHandle) edge.sourceHandle = 'source'
    if (!edge.targetHandle) edge.targetHandle = 'target'
    if (!edge.data?.sourceType && nodesMap.get(edge.source)) edge.data = { ...edge.data, sourceType: nodesMap.get(edge.source).data.type }
    if (!edge.data?.targetType && nodesMap.get(edge.target)) edge.data = { ...edge.data, targetType: nodesMap.get(edge.target).data.type }
    edge.data = { ...edge.data, isInIteration: false, iteration_id: undefined, isInLoop: false, loop_id: undefined }
    edge.zIndex = 0
    return edge
  })
}
