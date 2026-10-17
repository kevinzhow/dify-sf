import { env } from './_env'
export const useStore = (selector: (s: any) => any) => selector(env().workflowStore.getState())
export const useWorkflowStore = () => env().workflowStore
