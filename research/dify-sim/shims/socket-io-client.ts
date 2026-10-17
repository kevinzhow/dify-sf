import { env } from './_env'
export type Socket = any
export const io = (url: string, opts: any) => env().createSocket(url, opts)
