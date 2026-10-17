// workflow-app/hooks/use-workflow-draft-graph-for-canvas.ts: for app mode 'workflow' whose graph already has an entry (Start) node,
// getNodesWithLocalStartPlaceholder returns the nodes untouched; the outer function only fills defaults. Ported 1:1 for that branch.
export const useWorkflowDraftGraphForCanvas = (_appMode?: string) => ({
  getWorkflowDraftGraphForCanvas: (graph?: any) => ({
    nodes: graph?.nodes || [],
    edges: graph?.edges || [],
    viewport: graph?.viewport || { x: 0, y: 0, zoom: 1 },
  }),
})
