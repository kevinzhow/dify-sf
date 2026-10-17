// Port of repro/lib/graphs.py (start -> c1..cN -> end chain of code nodes), byte-for-byte same node/edge objects.
export function startNode(nid = 'start', x = 80, y = 200) {
  return { id: nid, type: 'custom', position: { x, y }, positionAbsolute: { x, y }, width: 244, height: 90, sourcePosition: 'right', targetPosition: 'left',
    data: { type: 'start', title: 'Start', desc: '', variables: [{ variable: 'q', label: 'q', type: 'text-input', required: false, max_length: 48, options: [] }] } }
}
export function codeNode(nid: string, title: string, x: number, y: number, desc = '', src: [string, string] = ['start', 'q']) {
  return { id: nid, type: 'custom', position: { x, y }, positionAbsolute: { x, y }, width: 244, height: 54, sourcePosition: 'right', targetPosition: 'left',
    data: { type: 'code', title, desc, code_language: 'python3', code: "def main(a: str) -> dict:\n    return {'result': a}\n", variables: [{ variable: 'a', value_selector: [...src] }], outputs: { result: { type: 'string', children: null } } } }
}
export function endNode(nid: string, x: number, y: number, srcId: string, title = 'End') {
  return { id: nid, type: 'custom', position: { x, y }, positionAbsolute: { x, y }, width: 244, height: 90, sourcePosition: 'right', targetPosition: 'left',
    data: { type: 'end', title, desc: '', outputs: [{ variable: 'out', value_selector: [srcId, 'result'] }] } }
}
export function edge(src: string, tgt: string, srcType = 'start', tgtType = 'code') {
  return { id: `${src}-source-${tgt}-target`, type: 'custom', source: src, sourceHandle: 'source', target: tgt, targetHandle: 'target',
    data: { sourceType: srcType, targetType: tgtType, isInIteration: false, isInLoop: false }, zIndex: 0 }
}
export function baseGraph(nCode = 4) {
  const nodes: any[] = [startNode()]
  const edges: any[] = []
  let prev = 'start'
  let ptype = 'start'
  for (let i = 1; i <= nCode; i++) {
    const nid = `c${i}`
    nodes.push(codeNode(nid, `Code ${i}`, 80 + 320 * i, 200 + (i % 2) * 160, '', i === 1 ? ['start', 'q'] : [prev, 'result']))
    edges.push(edge(prev, nid, ptype, 'code'))
    prev = nid
    ptype = 'code'
  }
  nodes.push(endNode('end', 80 + 320 * (nCode + 1), 200, prev))
  edges.push(edge(prev, 'end', 'code', 'end'))
  return { nodes, edges, viewport: { x: 0, y: 0, zoom: 0.6 } }
}

// ---------------------------------------------------------------------------------------------------------------------
// Large mixed graph (storm): start -> ... -> end with code / llm / if-else / template-transform / http-request / variable-aggregator
// nodes. Data shapes follow web/app/components/workflow/nodes/*/default.ts (defaultValue) so per-node JSON size is realistic
// (list fields: variables / prompt_template; object fields: outputs / model; private `_targetBranches` for if-else).
import { Rng } from './rng'

const LOREM = 'Summarise the following input for a customer-support agent, keep the tone neutral, cite the original sentence ids and never invent facts. '
const mk = (id: string, i: number, type: string, data: any, w = 244, h = 90) => {
  const x = 80 + (i % 25) * 320
  const y = 120 + Math.floor(i / 25) * 220 + (i % 2) * 70
  return { id, type: 'custom', position: { x, y }, positionAbsolute: { x, y }, width: w, height: h, sourcePosition: 'right', targetPosition: 'left', data: { type, ...data } }
}
export type NodeKind = 'start' | 'code' | 'llm' | 'if-else' | 'template-transform' | 'http-request' | 'variable-aggregator' | 'end'

export function bigGraph(n = 500, seed = 1) {
  const rng = new Rng(seed, 'biggraph')
  const nodes: any[] = []
  const edges: any[] = []
  const kinds: NodeKind[] = []
  const pickKind = (): NodeKind => {
    const r = rng.next()
    if (r < 0.34) return 'code'
    if (r < 0.58) return 'llm'
    if (r < 0.7) return 'if-else'
    if (r < 0.82) return 'template-transform'
    if (r < 0.9) return 'http-request'
    return 'variable-aggregator'
  }
  nodes.push(mk('n0', 0, 'start', { title: 'Start', desc: '', variables: [
    { variable: 'q', label: 'q', type: 'text-input', required: true, max_length: 256, options: [] },
    { variable: 'lang', label: 'lang', type: 'select', required: false, max_length: 48, options: ['en', 'zh', 'de'] },
  ] }))
  kinds.push('start')
  for (let i = 1; i < n - 1; i++) {
    const k = pickKind()
    kinds.push(k)
    const id = `n${i}`
    const parent = i === 1 || rng.chance(0.7) ? `n${i - 1}` : `n${Math.max(0, i - 1 - rng.int(8))}`
    const sel = [parent, 'result']
    let data: any
    switch (k) {
      case 'code':
        data = { title: `Code ${i}`, desc: `step ${i} transform`, code_language: 'python3',
          code: `def main(a: str, b: str) -> dict:\n    # step ${i}\n    return {'result': a + b, 'n': len(a)}\n`,
          variables: [{ variable: 'a', value_selector: sel }, { variable: 'b', value_selector: ['n0', 'q'] }],
          outputs: { result: { type: 'string', children: null }, n: { type: 'number', children: null } } }
        break
      case 'llm':
        data = { title: `LLM ${i}`, desc: `llm step ${i}`,
          model: { provider: 'openai', name: 'gpt-4o', mode: 'chat', completion_params: { temperature: 0.7 } },
          prompt_template: [{ id: `p${i}-0`, role: 'system', text: LOREM + `{{#${parent}.result#}}` }, { id: `p${i}-1`, role: 'user', text: `Question: {{#n0.q#}} (step ${i})` }],
          context: { enabled: false, variable_selector: [] }, vision: { enabled: false }, variables: [] }
        break
      case 'if-else':
        data = { title: `Branch ${i}`, desc: '', _targetBranches: [{ id: 'true', name: 'IF' }, { id: 'false', name: 'ELSE' }],
          cases: [{ case_id: 'true', logical_operator: 'and', conditions: [{ id: `c${i}`, variable_selector: sel, comparison_operator: 'contains', value: 'ok', varType: 'string' }] }] }
        break
      case 'template-transform':
        data = { title: `Template ${i}`, desc: '', template: `Result of {{ arg1 }} at step ${i}`, variables: [{ variable: 'arg1', value_selector: sel }] }
        break
      case 'http-request':
        data = { title: `HTTP ${i}`, desc: '', method: 'get', url: `https://api.example.test/v1/items/${i}`, authorization: { type: 'no-auth', config: null },
          headers: 'Accept: application/json', params: '', body: { type: 'none', data: [] }, timeout: { max_connect_timeout: 0, max_read_timeout: 0, max_write_timeout: 0 }, variables: [] }
        break
      default:
        data = { title: `Aggregate ${i}`, desc: '', output_type: 'string', variables: [sel], advanced_settings: { group_enabled: false, groups: [] } }
    }
    nodes.push(mk(id, i, k, data))
    const srcKind = kinds[Number(parent.slice(1))]!
    const handle = srcKind === 'if-else' ? (rng.chance(0.5) ? 'true' : 'false') : 'source'
    edges.push({ id: `${parent}-${handle}-${id}-target`, type: 'custom', source: parent, sourceHandle: handle, target: id, targetHandle: 'target',
      data: { sourceType: srcKind, targetType: k, isInIteration: false, isInLoop: false }, zIndex: 0 })
  }
  const last = `n${n - 2}`
  kinds.push('end')
  nodes.push(mk(`n${n - 1}`, n - 1, 'end', { title: 'End', desc: '', outputs: [{ variable: 'out', value_selector: [last, 'result'] }] }))
  edges.push({ id: `${last}-source-n${n - 1}-target`, type: 'custom', source: last, sourceHandle: 'source', target: `n${n - 1}`, targetHandle: 'target',
    data: { sourceType: kinds[n - 2]!, targetType: 'end', isInIteration: false, isInLoop: false }, zIndex: 0 })
  return { graph: { nodes, edges, viewport: { x: 0, y: 0, zoom: 0.5 } }, kinds }
}
