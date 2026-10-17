// Minimal React hook shim: Dify's hooks are instantiated ONCE per simulated tab and their callbacks are used as plain functions.
// (A real React render keeps identities stable via deps; here nothing re-renders, so identity is trivially stable.)
export const useCallback = <T>(fn: T): T => fn
export const useMemo = <T>(fn: () => T): T => fn()
export const useRef = <T>(init: T): { current: T } => ({ current: init })
export const useEffect = (fn: () => void | (() => void)): void => {
  fn()
}
export const useState = <T>(init: T): [T, (v: T) => void] => {
  let v = init
  return [v, (n: T) => (v = n)]
}
export const useEffectEvent = <T>(fn: T): T => fn
export default { useCallback, useMemo, useRef, useEffect, useState }
