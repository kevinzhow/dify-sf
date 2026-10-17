import { env } from './_env'
export const useEventEmitterContextContext = () => ({ eventEmitter: env().eventEmitter })
