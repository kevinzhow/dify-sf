// hooks/use-workflow.ts is a 2k-line hook file; only useNodesReadOnly* are reached by the data path.
// Real implementation: nodesReadOnly = workflowRunningData running || historyWorkflowData || isRestoring. None of those are active in the workload.
export const useNodesReadOnly = () => ({ nodesReadOnly: false, getNodesReadOnly: () => false })
export const useNodesReadOnlyByCanEdit = (_canEdit: boolean) => ({ nodesReadOnly: false, getNodesReadOnly: () => false })
