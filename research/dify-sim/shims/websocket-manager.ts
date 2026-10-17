// collaboration-manager.ts / crdt-provider.ts import webSocketClient (a module singleton). One simulated process hosts many
// tabs, so we expose the REAL WebSocketClient class (websocket-manager.ts, unmodified) and hand each tab its own instance.
import { WebSocketClient, emitWithAuthGuard, isDefaultSocketUrl } from '@real/websocket-manager'
import { env } from './_env'
export { WebSocketClient, emitWithAuthGuard, isDefaultSocketUrl }
export const webSocketClient: WebSocketClient = new Proxy({} as WebSocketClient, {
  get: (_t, k) => {
    const c: any = env().wsClient
    const v = c[k]
    return typeof v === 'function' ? v.bind(c) : v
  },
})
