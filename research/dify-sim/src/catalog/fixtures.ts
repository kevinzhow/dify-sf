import { edge } from '../sim/graphgen'

const mkNode = (id: string, x: number, y: number, data: any) => ({ id, type: 'custom', position: { x, y }, positionAbsolute: { x, y }, width: 244, height: 90, sourcePosition: 'right', targetPosition: 'left', data })

/** fixtures referenced as `graph:` in catalog case files */
export const FIXTURES: Record<string, () => any> = {
  'code-node-basic': () => {
    const nodes = [
      mkNode('start', 80, 200, { type: 'start', title: 'Start', desc: '', variables: [{ variable: 'q', label: 'q', type: 'text-input', required: false, max_length: 48, options: [] }] }),
      mkNode('code1', 400, 200, { type: 'code', title: 'Code 1', desc: 'first', code_language: 'python3', code: "def main(a: str) -> dict:\n    return {'result': a}\n",
        variables: [{ variable: 'a', value_selector: ['start', 'q'] }, { variable: 'b', value_selector: ['start', 'q'] }], outputs: { result: { type: 'string', children: null }, extra: { type: 'string', children: null } } }),
      mkNode('llm1', 720, 200, { type: 'llm', title: 'LLM 1', desc: 'ask', model: { provider: 'openai', name: 'gpt-4o', mode: 'chat', completion_params: { temperature: 0.7 } },
        prompt_template: [{ id: 'p0', role: 'system', text: 'You are helpful.' }, { id: 'p1', role: 'user', text: '{{#code1.result#}}' }], context: { enabled: false, variable_selector: [] }, vision: { enabled: false } }),
      mkNode('ifelse1', 1040, 200, { type: 'if-else', title: 'Branch', desc: '', _targetBranches: [{ id: 'true', name: 'IF' }, { id: 'false', name: 'ELSE' }],
        cases: [{ case_id: 'true', logical_operator: 'and', conditions: [{ id: 'c1', variable_selector: ['llm1', 'text'], comparison_operator: 'contains', value: 'yes', varType: 'string' }] }] }),
      mkNode('code2', 1360, 100, { type: 'code', title: 'Code 2', desc: 'second', code_language: 'python3', code: "def main(a: str) -> dict:\n    return {'result': a}\n",
        variables: [{ variable: 'a', value_selector: ['llm1', 'text'] }], outputs: { result: { type: 'string', children: null } } }),
      mkNode('code3', 1360, 320, { type: 'code', title: 'Code 3', desc: 'third', code_language: 'python3', code: "def main(a: str) -> dict:\n    return {'result': a}\n",
        variables: [{ variable: 'a', value_selector: ['llm1', 'text'] }], outputs: { result: { type: 'string', children: null } } }),
      mkNode('end', 1680, 200, { type: 'end', title: 'End', desc: '', outputs: [{ variable: 'out', value_selector: ['code2', 'result'] }] }),
    ]
    const edges = [
      edge('start', 'code1', 'start', 'code'),
      edge('code1', 'llm1', 'code', 'llm'),
      edge('llm1', 'ifelse1', 'llm', 'if-else'),
      { ...edge('ifelse1', 'code2', 'if-else', 'code'), id: 'ifelse1-true-code2-target', sourceHandle: 'true' },
      { ...edge('ifelse1', 'code3', 'if-else', 'code'), id: 'ifelse1-false-code3-target', sourceHandle: 'false' },
      edge('code2', 'end', 'code', 'end'),
    ]
    return { nodes, edges, viewport: { x: 0, y: 0, zoom: 0.6 } }
  },
}
export const newNodeFor = (kind: string, id: string, x: number, y: number) =>
  mkNode(id, x, y, kind === 'code'
    ? { type: 'code', title: 'New Code', desc: '', code_language: 'python3', code: 'def main() -> dict:\n    return {}\n', variables: [], outputs: { result: { type: 'string', children: null } } }
    : { type: 'template-transform', title: 'New Template', desc: '', template: '', variables: [] })
