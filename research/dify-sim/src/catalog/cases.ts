// A-tier catalog (CATALOG.md §3): valid (operation pair x relation) combinations x timings T1/T2, fault F0, 2 users.
// Generated programmatically from an explicit applicability table; written out as YAML in catalog/ (CATALOG.md §5 format).
export type Step = { at: number; user: string; op: string; node?: string; path?: string; value?: any; from?: string; to?: string; open_at?: number; item?: string }
export type Case = {
  id: string
  title: string
  graph: string
  users: string[]
  steps: Step[]
  faults: any[]
  settle: string
  expect: { final?: any[]; notices?: any[] }
  repeat: number
  tags: { op_a: string; op_b: string; rel: string; timing: string; fault: string; users: string }
  jitter_ms: number
}

type Tpl = { rel: string; a: Omit<Step, 'at' | 'user'>; b: Omit<Step, 'at' | 'user'>; title: string; expect?: any[] }
const T = (rel: string, title: string, a: Tpl['a'], b: Tpl['b'], expect?: any[]): Tpl => ({ rel, title, a, b, expect })

// applicability table (documented in FIDELITY/REPORT): every row is one operation pair on one relation
export const TEMPLATES: Tpl[] = [
  // R1 same field
  T('R1', '两人同时改同一节点标题', { op: 'setTitle', node: 'code1', value: 'A-title' }, { op: 'setTitle', node: 'code1', value: 'B-title' }),
  T('R1', '两人同时改同一 LLM 温度', { op: 'setField', node: 'llm1', path: 'temp', value: 0.2 }, { op: 'setField', node: 'llm1', path: 'temp', value: 0.9 }),
  T('R1', '两人同时改同一代码块', { op: 'setField', node: 'code1', path: 'code', value: '# A\n' }, { op: 'setField', node: 'code1', path: 'code', value: '# B\n' }),
  T('R1', '两人同时拖动同一节点', { op: 'moveNode', node: 'code1', value: { x: 500, y: 320 } }, { op: 'moveNode', node: 'code1', value: { x: 560, y: 80 } }),
  T('R1', '两人同时改同一引用', { op: 'setRef', node: 'code2', value: ['code1', 'result'] }, { op: 'setRef', node: 'code2', value: ['start', 'q'] }),
  T('R1', '两人同时删同一输出变量', { op: 'listRemove', node: 'code1', path: 'outputs', value: 'extra' }, { op: 'listRemove', node: 'code1', path: 'outputs', value: 'extra' }),
  T('R1', '两人同时改同一 if-else 条件值', { op: 'setField', node: 'ifelse1', path: 'cond', value: 'A' }, { op: 'setField', node: 'ifelse1', path: 'cond', value: 'B' }),
  // R2 same node, different field
  T('R2', 'A 改标题，B 改代码', { op: 'setTitle', node: 'code1', value: 'A-title' }, { op: 'setField', node: 'code1', path: 'code', value: '# B\n' }),
  T('R2', 'A 改标题，B 改描述', { op: 'setTitle', node: 'code1', value: 'A-title' }, { op: 'setField', node: 'code1', path: 'desc', value: 'B-desc' }),
  T('R2', 'A 改标题，B 拖动', { op: 'setTitle', node: 'llm1', value: 'A-title' }, { op: 'moveNode', node: 'llm1', value: { x: 760, y: 340 } }),
  T('R2', 'A 改温度，B 拖动', { op: 'setField', node: 'llm1', path: 'temp', value: 0.1 }, { op: 'moveNode', node: 'llm1', value: { x: 760, y: 340 } }),
  T('R2', 'A 改提示词，B 改温度', { op: 'setField', node: 'llm1', path: 'prompt0', value: 'A prompt' }, { op: 'setField', node: 'llm1', path: 'temp', value: 0.3 }),
  T('R2', 'A 改标题，B 改引用', { op: 'setTitle', node: 'code2', value: 'A-title' }, { op: 'setRef', node: 'code2', value: ['code1', 'result'] }),
  T('R2', 'A 拖动，B 改描述', { op: 'moveNode', node: 'code1', value: { x: 500, y: 320 } }, { op: 'setField', node: 'code1', path: 'desc', value: 'B-desc' }),
  // R3 path overlap (model vs model.completion_params.temperature)
  T('R3', 'A 换模型，B 改温度（路径重叠）', { op: 'setField', node: 'llm1', path: 'model', value: 'gpt-4.1' }, { op: 'setField', node: 'llm1', path: 'temp', value: 0.2 }),
  T('R3', 'A 改温度，B 换模型（路径重叠，顺序对调）', { op: 'setField', node: 'llm1', path: 'temp', value: 0.2 }, { op: 'setField', node: 'llm1', path: 'model', value: 'gpt-4.1' }),
  // R4 same list, different items
  T('R4', '两人各加一个输出变量', { op: 'listInsert', node: 'code1', path: 'outputs', value: 'a_out' }, { op: 'listInsert', node: 'code1', path: 'outputs', value: 'b_out' }, [{ node: 'code1', path: 'outputs', contains: ['a_out', 'b_out'] }]),
  T('R4', '两人各加一个输入变量', { op: 'listInsert', node: 'code1', path: 'variables', value: 'a_in' }, { op: 'listInsert', node: 'code1', path: 'variables', value: 'b_in' }, [{ node: 'code1', path: 'variables', contains: ['a_in', 'b_in'] }]),
  T('R4', '两人各加一条提示词', { op: 'listInsert', node: 'llm1', path: 'prompt', value: 'msg-A' }, { op: 'listInsert', node: 'llm1', path: 'prompt', value: 'msg-B' }, [{ node: 'llm1', path: 'prompt', contains: ['msg-A', 'msg-B'] }]),
  T('R4', 'A 加输出变量，B 删另一个输出变量', { op: 'listInsert', node: 'code1', path: 'outputs', value: 'a_out' }, { op: 'listRemove', node: 'code1', path: 'outputs', value: 'extra' }),
  T('R4', 'A 加输入变量，B 删另一个输入变量', { op: 'listInsert', node: 'code1', path: 'variables', value: 'a_in' }, { op: 'listRemove', node: 'code1', path: 'variables', value: 'b' }),
  T('R4', '两人各删一个不同的输出变量', { op: 'listRemove', node: 'code1', path: 'outputs', value: 'extra' }, { op: 'listRemove', node: 'code1', path: 'outputs', value: 'result' }),
  T('R4', '两人各删一个不同的输入变量', { op: 'listRemove', node: 'code1', path: 'variables', value: 'a' }, { op: 'listRemove', node: 'code1', path: 'variables', value: 'b' }),
  // R5 different nodes
  T('R5', '两人改不同节点的标题', { op: 'setTitle', node: 'code1', value: 'A-title' }, { op: 'setTitle', node: 'code2', value: 'B-title' }),
  T('R5', '两人拖动不同节点', { op: 'moveNode', node: 'code1', value: { x: 500, y: 320 } }, { op: 'moveNode', node: 'code2', value: { x: 1400, y: 40 } }),
  T('R5', '两人改不同节点的字段', { op: 'setField', node: 'code1', path: 'code', value: '# A\n' }, { op: 'setField', node: 'llm1', path: 'temp', value: 0.4 }),
  T('R5', '两人各加一个节点', { op: 'addNode', node: 'newA', value: { kind: 'code', x: 400, y: 420 }, from: 'start' }, { op: 'addNode', node: 'newB', value: { kind: 'template', x: 720, y: 420 }, from: 'code1' }),
  T('R5', 'A 删节点，B 改另一个节点', { op: 'removeNode', node: 'code3' }, { op: 'setTitle', node: 'code2', value: 'B-title' }),
  T('R5', 'A 加节点，B 拖动另一个节点', { op: 'addNode', node: 'newA', value: { kind: 'code', x: 400, y: 420 }, from: 'start' }, { op: 'moveNode', node: 'llm1', value: { x: 760, y: 340 } }),
  T('R5', 'A 连线，B 改另一个节点标题', { op: 'addEdge', from: 'code1', to: 'code3' }, { op: 'setTitle', node: 'code2', value: 'B-title' }),
  T('R5', 'A 断线，B 拖动无关节点', { op: 'removeEdge', from: 'llm1', to: 'ifelse1' }, { op: 'moveNode', node: 'code2', value: { x: 1400, y: 40 } }),
  T('R5', '两人各改不同节点的引用', { op: 'setRef', node: 'code2', value: ['code1', 'result'] }, { op: 'setRef', node: 'code3', value: ['code1', 'result'] }),
  // R6 reference relations
  T('R6', 'A 删节点 code1，B 让 code2 引用 code1 的输出', { op: 'removeNode', node: 'code1' }, { op: 'setRef', node: 'code2', value: ['code1', 'result'] }),
  T('R6', 'A 删节点 code1，B 给 code1 加输出变量', { op: 'removeNode', node: 'code1' }, { op: 'listInsert', node: 'code1', path: 'outputs', value: 'b_out' }),
  T('R6', 'A 删节点 code2，B 改 code2 标题', { op: 'removeNode', node: 'code2' }, { op: 'setTitle', node: 'code2', value: 'B-title' }),
  T('R6', 'A 删 code1 的输出变量 result，B 让 llm1 提示词引用', { op: 'listRemove', node: 'code1', path: 'outputs', value: 'result' }, { op: 'setRef', node: 'code2', value: ['code1', 'result'] }),
  // R7 structure
  T('R7', '两人连同一条线', { op: 'addEdge', from: 'code1', to: 'code3' }, { op: 'addEdge', from: 'code1', to: 'code3' }),
  T('R7', 'A 连线到 code3，B 删 code3', { op: 'addEdge', from: 'code1', to: 'code3' }, { op: 'removeNode', node: 'code3' }),
  T('R7', 'A 断线，B 在同一条线两端的节点上改标题', { op: 'removeEdge', from: 'code2', to: 'end' }, { op: 'setTitle', node: 'end', value: 'B-end' }),
  T('R7', '两人断开不同的线', { op: 'removeEdge', from: 'llm1', to: 'ifelse1' }, { op: 'removeEdge', from: 'code2', to: 'end' }),
  T('R7', 'A 断线，B 连另一条线到同一节点', { op: 'removeEdge', from: 'code2', to: 'end' }, { op: 'addEdge', from: 'code3', to: 'end' }),
  T('R7', 'A 连线 start→code3，B 连线 code1→code3', { op: 'addEdge', from: 'start', to: 'code3' }, { op: 'addEdge', from: 'code1', to: 'code3' }),
  T('R7', 'A 删节点，B 连线到该节点', { op: 'removeNode', node: 'code3' }, { op: 'addEdge', from: 'code1', to: 'code3' }),
  T('R7', 'A 加节点并连线，B 加另一节点并连到同一上游', { op: 'addNode', node: 'newA', value: { kind: 'code', x: 400, y: 420 }, from: 'code1' }, { op: 'addNode', node: 'newB', value: { kind: 'template', x: 720, y: 420 }, from: 'code1' }),
]

export function generateCases(): Case[] {
  const out: Case[] = []
  let i = 0
  for (const t of TEMPLATES) {
    i++
    for (const timing of ['T1', 'T2'] as const) {
      const id = `A-${t.a.op}-${t.b.op}-${t.rel}-${timing}-F0-2p-${String(i).padStart(2, '0')}`
      // T1: both commit within 200 ms of each other (nominal offset 50 ms, +-jitter). T2: B opened its panel at t=0, A commits at 600, B commits at 1500 (B's base is stale).
      const steps: Step[] =
        timing === 'T1'
          ? [{ at: 0, user: 'A', ...t.a }, { at: 50, user: 'B', ...t.b }]
          : [{ at: 600, user: 'A', ...t.a }, { at: 1500, user: 'B', ...t.b, open_at: 0 }]
      out.push({
        id, title: `${t.title}（${timing === 'T1' ? '并发' : '基于旧版本'}）`, graph: 'fixtures/code-node-basic.yml', users: ['A', 'B'], steps,
        faults: [], settle: '14s', expect: { final: t.expect ?? [], notices: [] }, repeat: 20,
        tags: { op_a: t.a.op, op_b: t.b.op, rel: t.rel, timing, fault: 'F0', users: '2p' }, jitter_ms: timing === 'T1' ? 40 : 40,
      })
    }
  }
  return out
}
