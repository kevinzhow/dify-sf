// Edit specs: semantic intent of one user action = (target, value) + how to apply it through the UI-level ops and how to read it back.
import * as ops from './ops'
import type { Tab } from './tab'

export type EditKind = 'set' | 'insert' | 'remove' | 'move' | 'exists' | 'edge'
export type EditSpec = {
  kind: EditKind
  node: string
  key: string // semantic field, e.g. title, desc, code, prompt0, temp, outputs+, pos
  item?: string // for insert/remove: item identity
  value: any
  cls?: 'disjoint' | 'same-value' | 'diff-value' | 'list' | 'struct'
  /** read the semantic value from a (RF / draft) node object; for list targets returns membership boolean */
  read: (node: any | undefined) => any
  apply: (tab: Tab) => ops.OpResult
}
export const targetId = (e: Pick<EditSpec, 'node' | 'key' | 'item'>) => `${e.node}|${e.key}${e.item !== undefined ? '#' + e.item : ''}`

const dget = (n: any, path: (string | number)[]) => path.reduce((a: any, k) => (a == null ? undefined : a[k]), n?.data)
const eqJ = (a: any, b: any) => JSON.stringify(a) === JSON.stringify(b)
export { eqJ }

const setIn = (obj: any, path: (string | number)[], v: any) => {
  let o = obj
  for (let i = 0; i < path.length - 1; i++) o = o[path[i]!]
  o[path[path.length - 1]!] = v
}

// keys applicable to a node kind: which semantic fields exist
export const SET_KEYS: Record<string, string[]> = {
  code: ['title', 'desc', 'code'],
  llm: ['title', 'desc', 'prompt0', 'prompt1', 'temp', 'model'],
  'if-else': ['title', 'desc', 'cond'],
  'template-transform': ['title', 'desc', 'template'],
  'http-request': ['title', 'desc', 'url'],
  'variable-aggregator': ['title', 'desc'],
  start: ['title', 'desc'],
  end: ['title', 'desc'],
}

const PATHS: Record<string, (string | number)[]> = {
  title: ['title'],
  desc: ['desc'],
  code: ['code'],
  prompt0: ['prompt_template', 0, 'text'],
  prompt1: ['prompt_template', 1, 'text'],
  temp: ['model', 'completion_params', 'temperature'],
  model: ['model', 'name'],
  cond: ['cases', 0, 'conditions', 0, 'value'],
  template: ['template'],
  url: ['url'],
  ref: ['variables', 0, 'value_selector'],
}

export function set(node: string, key: string, value: any, cls?: EditSpec['cls']): EditSpec {
  // `uf_*`: a per-user config field (formula workload, mechanism (b) "same node, different fields"). It goes through
  // the panel's whole-inputs write like every other config field; only its name is synthetic.
  const path = PATHS[key] ?? (key.startsWith('uf_') ? [key] : undefined)
  if (!path) throw new Error('unknown set key ' + key)
  const partial = key === 'title' || key === 'desc'
  return {
    kind: 'set', node, key, value, cls,
    read: (n) => dget(n, path),
    apply: (tab) => (partial ? ops.panelUpdate(tab, node, { [key]: value }) : ops.setInputs(tab, node, (inputs) => setIn(inputs, path, value))),
  }
}
/** whole `outputs` list-like object edit (code node): add a named output variable (S2O) */
export function addOutput(node: string, name: string, gapMs = 30): EditSpec {
  return { kind: 'insert', node, key: 'outputs+', item: name, value: name, cls: 'list',
    read: (n) => Object.prototype.hasOwnProperty.call(n?.data?.outputs ?? {}, name),
    apply: (tab) => ops.addOutputVar(tab, node, name, gapMs) }
}
export function removeOutput(node: string, name: string): EditSpec {
  return { kind: 'remove', node, key: 'outputs+', item: name, value: name, cls: 'list',
    read: (n) => !Object.prototype.hasOwnProperty.call(n?.data?.outputs ?? {}, name),
    apply: (tab) => ops.setInputs(tab, node, (inputs) => { const o = { ...inputs.outputs }; delete o[name]; inputs.outputs = o }) }
}
/** code/template node input variable list (`variables`, synced by index through syncList) */
export function addVariable(node: string, name: string, sel: string[] = ['start', 'q']): EditSpec {
  return { kind: 'insert', node, key: 'variables+', item: name, value: name, cls: 'list',
    read: (n) => (n?.data?.variables ?? []).some((v: any) => v?.variable === name),
    apply: (tab) => ops.setInputs(tab, node, (inputs) => { inputs.variables = [...(inputs.variables ?? []), { variable: name, value_selector: sel }] }) }
}
export function removeVariable(node: string, name: string): EditSpec {
  return { kind: 'remove', node, key: 'variables+', item: name, value: name, cls: 'list',
    read: (n) => !(n?.data?.variables ?? []).some((v: any) => v?.variable === name),
    apply: (tab) => ops.setInputs(tab, node, (inputs) => { inputs.variables = (inputs.variables ?? []).filter((v: any) => v.variable !== name) }) }
}
/** llm prompt_template: append a message */
export function addPrompt(node: string, text: string): EditSpec {
  return { kind: 'insert', node, key: 'prompt+', item: text, value: text, cls: 'list',
    read: (n) => (n?.data?.prompt_template ?? []).some((v: any) => v?.text === text),
    apply: (tab) => ops.setInputs(tab, node, (inputs) => { inputs.prompt_template = [...(inputs.prompt_template ?? []), { id: 'pm-' + text, role: 'user', text }] }) }
}
export function move(node: string, x: number, y: number, cls?: EditSpec['cls'], steps = 20): EditSpec {
  return { kind: 'move', node, key: 'pos', value: { x, y }, cls,
    read: (n) => (n ? { x: n.position?.x, y: n.position?.y } : undefined),
    apply: (tab) => ops.moveNode(tab, node, x, y, steps) }
}
export function removeNode(node: string): EditSpec {
  return { kind: 'exists', node, key: 'exists', value: false, cls: 'struct', read: (n) => n !== undefined, apply: (tab) => ops.deleteNode(tab, node) }
}
export function addNode(node: any, fromId?: string): EditSpec {
  return { kind: 'exists', node: node.id, key: 'exists', value: true, cls: 'struct', read: (n) => n !== undefined, apply: (tab) => ops.addNode(tab, node, fromId) }
}
/** edge semantic: target id = edge id; value = exists? */
export function addEdgeSpec(from: string, to: string): EditSpec {
  const id = `${from}-source-${to}-target`
  return { kind: 'edge', node: id, key: 'edge', value: true, cls: 'struct', read: () => undefined,
    apply: (tab) => ops.addEdge(tab, from, to) }
}
export function removeEdgeSpec(from: string, to: string): EditSpec {
  const id = `${from}-source-${to}-target`
  return { kind: 'edge', node: id, key: 'edge', value: false, cls: 'struct', read: () => undefined,
    apply: (tab) => ops.removeEdge(tab, id) }
}
export function setRef(node: string, selector: string[]): EditSpec {
  return set(node, 'ref', selector)
}
