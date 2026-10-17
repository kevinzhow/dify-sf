import { env } from './_env'
export const useStoreApi = () => env().rfStoreApi
export const useReactFlow = () => env().reactFlowInstance
export const getConnectedEdges = (nodes: any[], edges: any[]) => {
  const ids = new Set(nodes.map((n) => n.id))
  return edges.filter((e) => ids.has(e.source) || ids.has(e.target))
}
