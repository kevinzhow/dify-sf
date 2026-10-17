// Agent-v2 nodes are not part of the workload.
export const isAgentV2NodeData = (_d: unknown) => false
export const needsInlineAgentBindingCreation = (_d: unknown) => false
