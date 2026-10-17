import { env } from './_env'
/** web/service/fetch.ts:244-258 postWithKeepalive: fetch(..., {keepalive:true}). Browsers reject keepalive bodies > 64 KiB (Fetch spec, "keepalive quota"). */
export function postWithKeepalive(url: string, body: Record<string, unknown>): void {
  env().http.postKeepalive(url, JSON.stringify(body))
}
