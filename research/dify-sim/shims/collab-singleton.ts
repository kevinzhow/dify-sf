// Same treatment for the `collaborationManager` singleton exported by collaboration-manager.ts: hooks import it by name.
import { env } from './_env'
export { CollaborationManager } from '@real/collaboration-manager'
export const collaborationManager: any = new Proxy({}, {
  get: (_t, k) => {
    const m: any = env().manager
    const v = m[k]
    return typeof v === 'function' ? v.bind(m) : v
  },
})
