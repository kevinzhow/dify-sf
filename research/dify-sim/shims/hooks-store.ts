import { env } from './_env'
export const useHooksStore = (selector: (s: any) => any) => selector(env().hooksState)
