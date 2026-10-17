import { env } from './_env'
// web/service/workflow.ts syncWorkflowDraft / fetchWorkflowDraft: JSON over HTTP via the console API; non-2xx rejects with the Response.
export const syncWorkflowDraft = ({ url, params }: { url: string; params: any }) => env().http.post(url, params)
export const fetchWorkflowDraft = (url: string) => env().http.get(url)
