// Bridge between the bundled Dify code and the simulator runtime (set up by src/sim before the bundle is loaded).
export const env = (): any => {
  const e = (globalThis as any).__SIMENV?.cur()
  if (!e) throw new Error('Dify code executed outside a client context (no AsyncLocalStorage store)')
  return e
}
