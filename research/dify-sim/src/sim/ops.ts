// User-level UI operations. Each op reproduces the data transformation of the corresponding Dify UI handler, then calls
// the REAL hooks (use-collaborative-workflow / use-node-data-update) so the rest of the path (collab setNodes -> CRDT -> socket ->
// debounced autosave) is Dify code. Sources of each op model are cited per function; they are NOT byte-faithful (React components).
import type { Tab } from './tab'

export type OpResult = { ok: boolean; blocked?: string; applied?: boolean }

/** The collaboration overlay (workflow-main.tsx:~470 `collaboration-graph-loading`, z-50) covers the canvas+panel while !canApplyLocalGraphMutation(). */
let forceUi = false
/** S4B-style edits: the user already had keyboard focus in a field when the overlay appeared, so the handler runs although the overlay is up. */
export function withForcedUi<T>(fn: () => T): T {
  forceUi = true
  try {
    return fn()
  } finally {
    forceUi = false
  }
}
export function uiInteractive(tab: Tab): boolean {
  if (tab.dead || !tab.loaded || !tab.manager) return false
  if (forceUi) return true
  return tab.world.sim.als.run(tab, () => tab.manager.canApplyLocalGraphMutation() === true)
}

const nodeOf = (tab: Tab, id: string) => tab.rf.nodes.find((n: any) => n.id === id)
const clone = <T>(v: T): T => JSON.parse(JSON.stringify(v))

/** Run `fn` inside the tab's execution context (so Dify code sees the right singletons / virtual timers). */
export function inTab<T>(tab: Tab, fn: () => T): T {
  return tab.world.sim.als.run(tab, fn)
}

/** use-nodes-interactions.ts:443 handleNodeSelect (node click): RF-only update (`setNodes(newNodes, false)`: no broadcast, but the top-level `selected`
 *  flag IS written to the CRDT by later whole-node writes (populateNodeContainer:359) and `data.selected` ends up in the saved draft) */
export function selectNode(tab: Tab, id: string) {
  const n = nodeOf(tab, id)
  if (!n || (n.selected === true && n.data?.selected === true)) return
  inTab(tab, () => {
    const R = tab.world.real
    const { nodes, edges, setNodes, setEdges } = tab.hooks.collab.getState()
    setNodes(
      R.produce(nodes, (draft: any[]) => {
        draft.forEach((node) => {
          const selected = node.id === id
          node.selected = selected
          node.data.selected = selected
        })
      }),
      false,
    )
    const connected = new Set(edges.filter((e: any) => e.source === id || e.target === id).map((e: any) => e.id))
    setEdges(
      R.produce(edges, (draft: any[]) => {
        draft.forEach((edge) => {
          edge.data = { ...edge.data, _connectedNodeIsSelected: connected.has(edge.id) }
        })
      }),
      false,
    )
  })
}

/** workflow-panel/index.tsx:221 handleTitleBlur -> handleNodeDataUpdateWithSyncDraft({id, data:{title}}) */
export function setTitle(tab: Tab, id: string, title: string): OpResult {
  return panelUpdate(tab, id, { title })
}
/** workflow-panel/index.tsx:230 handleDescriptionChange */
export function setDesc(tab: Tab, id: string, desc: string): OpResult {
  return panelUpdate(tab, id, { desc })
}
/** A panel edit whose handler passes only the changed key (title/desc style). */
export function panelUpdate(tab: Tab, id: string, data: Record<string, unknown>): OpResult {
  if (!uiInteractive(tab)) return { ok: false, blocked: 'overlay' }
  if (!nodeOf(tab, id)) return { ok: false, blocked: 'no-node' }
  selectNode(tab, id)
  return inTab(tab, () => {
    tab.editsAttempted++
    tab.hooks.nodeData.handleNodeDataUpdateWithSyncDraft({ id, data })
    return { ok: true, applied: true }
  })
}
/** Node panels (code/llm/if-else...) call setInputs(newInputs) with their WHOLE `inputs` copy (use-node-crud.ts:20,
 *  use-node-data-update.ts:20 merges {...currentNode.data, ...data}). `mutate` receives a deep copy of the panel's current inputs
 *  (= the node's data as rendered, i.e. RF store data at op time) and edits it (immer-style in the real hooks). */
export function setInputs(tab: Tab, id: string, mutate: (inputs: any) => void): OpResult {
  if (!uiInteractive(tab)) return { ok: false, blocked: 'overlay' }
  const n = nodeOf(tab, id)
  if (!n) return { ok: false, blocked: 'no-node' }
  selectNode(tab, id)
  return inTab(tab, () => {
    tab.editsAttempted++
    const inputs = clone((tab.panelNode(id) ?? nodeOf(tab, id)!).data)
    mutate(inputs)
    tab.hooks.nodeData.handleNodeDataUpdateWithSyncDraft({ id, data: inputs })
    return { ok: true, applied: true }
  })
}
/** nodes/_base/hooks/use-output-var-list.ts:93 handleAddVariable then the VarList rename (handleVarsChange) when the user types the name. */
export function addOutputVar(tab: Tab, id: string, name: string, gapMs = 30): OpResult {
  const n = nodeOf(tab, id)
  if (!n || !uiInteractive(tab)) return { ok: false, blocked: n ? 'overlay' : 'no-node' }
  const r1 = setInputs(tab, id, (inputs) => {
    let keyIndex = Object.keys(inputs.outputs ?? {}).length + 1
    while (inputs.outputs?.[`var_${keyIndex}`]) keyIndex++
    const newKey = `var_${keyIndex}`
    inputs.outputs = { ...inputs.outputs, [newKey]: { type: 'string', children: null } }
    ;(addOutputVar as any)._k = newKey
  })
  const newKey = (addOutputVar as any)._k as string
  // user types the variable name: handleVarsChange(newVars) with the key renamed in place (order preserved)
  const rename = () =>
    setInputs(tab, id, (inputs) => {
      const out: Record<string, unknown> = {}
      for (const [k, v] of Object.entries(inputs.outputs ?? {})) out[k === newKey ? name : k] = v
      inputs.outputs = out
    })
  if (gapMs > 0) {
    tab.world.sim.after(gapMs, () => void rename(), tab)
    return { ok: r1.ok, applied: r1.applied }
  }
  const r2 = rename()
  return { ok: r1.ok && r2.ok, applied: r2.applied }
}

/** use-nodes-interactions.ts:246 handleNodeDrag (position per pointer move through collaborative setNodes: every step is a CRDT commit + a whole-doc
 *  broadcast) + :324 handleNodeDragStop (debounced autosave). A drag is `steps` pointer moves 16.7 ms apart (~330 ms at 60 Hz for the default 20). */
export function moveNode(tab: Tab, id: string, x: number, y: number, steps = 20, dtMs = 1000 / 60): OpResult {
  if (!uiInteractive(tab)) return { ok: false, blocked: 'overlay' }
  const n = nodeOf(tab, id)
  if (!n) return { ok: false, blocked: 'no-node' }
  const x0 = n.position.x
  const y0 = n.position.y
  const step = (i: number) => {
    const R = tab.world.real
    const px = x0 + ((x - x0) * i) / steps
    const py = y0 + ((y - y0) * i) / steps
    if (!tab.rf.nodes.some((d: any) => d.id === id)) return
    const { nodes, setNodes } = tab.hooks.collab.getState()
    const newNodes = R.produce(nodes, (draft: any[]) => {
      const cur = draft.find((d) => d.id === id)!
      cur.position = { x: px, y: py }
      if (cur.positionAbsolute) cur.positionAbsolute = { x: px, y: py }
    })
    setNodes(newNodes)
    if (i === steps) tab.hooks.sync.handleSyncWorkflowDraft()
  }
  return inTab(tab, () => {
    tab.editsAttempted++
    step(1)
    for (let i = 2; i <= steps; i++) tab.world.sim.after((i - 1) * dtMs, () => step(i), tab)
    return { ok: true, applied: true }
  })
}

/** use-nodes-interactions.ts:678 handleNodeDelete (connected edges removed, neighbours' _connected*HandleIds updated) */
export function deleteNode(tab: Tab, id: string): OpResult {
  if (!uiInteractive(tab)) return { ok: false, blocked: 'overlay' }
  if (!nodeOf(tab, id)) return { ok: false, blocked: 'no-node' }
  return inTab(tab, () => {
    tab.editsAttempted++
    const R = tab.world.real
    const { nodes, edges, setNodes, setEdges } = tab.hooks.collab.getState()
    const idx = nodes.findIndex((n: any) => n.id === id)
    const connected = edges.filter((e: any) => e.source === id || e.target === id)
    const newNodes = R.produce(nodes, (draft: any[]) => {
      draft.forEach((node) => {
        const rm = connected.filter((e: any) => e.source === node.id || e.target === node.id)
        if (rm.length) {
          node.data = {
            ...node.data,
            _connectedSourceHandleIds: (node.data._connectedSourceHandleIds ?? []).filter((h: string) => !rm.some((e: any) => e.source === node.id && (e.sourceHandle || 'source') === h)),
            _connectedTargetHandleIds: (node.data._connectedTargetHandleIds ?? []).filter((h: string) => !rm.some((e: any) => e.target === node.id && (e.targetHandle || 'target') === h)),
          }
        }
      })
      draft.splice(idx, 1)
    })
    setNodes(newNodes, true, 'nodes:perform-batch-cascade-delete')
    const newEdges = R.produce(edges, (draft: any[]) => draft.filter((e) => !connected.some((c: any) => c.id === e.id)))
    setEdges(newEdges)
    tab.hooks.sync.handleSyncWorkflowDraft()
    return { ok: true, applied: true }
  })
}

/** use-nodes-interactions.ts handleNodeAdd (+ connect): new node + new edge, then debounced autosave. Simplified default data. */
export function addNode(tab: Tab, node: any, fromId?: string): OpResult {
  if (!uiInteractive(tab)) return { ok: false, blocked: 'overlay' }
  return inTab(tab, () => {
    tab.editsAttempted++
    const R = tab.world.real
    const { nodes, edges, setNodes, setEdges } = tab.hooks.collab.getState()
    const newNode = clone(node)
    newNode.data._connectedTargetHandleIds = fromId ? ['target'] : []
    newNode.data._connectedSourceHandleIds = []
    let newNodes = [...nodes, newNode]
    let newEdges = edges
    if (fromId) {
      const e = { id: `${fromId}-source-${newNode.id}-target`, type: 'custom', source: fromId, sourceHandle: 'source', target: newNode.id, targetHandle: 'target',
        data: { sourceType: nodes.find((n: any) => n.id === fromId)?.data.type, targetType: newNode.data.type, isInIteration: false, isInLoop: false }, zIndex: 0 }
      newEdges = [...edges, e]
      newNodes = R.produce(newNodes, (d: any[]) => {
        const s = d.find((x) => x.id === fromId)
        if (s) s.data._connectedSourceHandleIds = [...(s.data._connectedSourceHandleIds ?? []), 'source']
      })
    }
    setNodes(newNodes)
    if (fromId) setEdges(newEdges)
    tab.hooks.sync.handleSyncWorkflowDraft()
    return { ok: true, applied: true }
  })
}

/** use-nodes-interactions.ts:493 handleNodeConnect: new edge + both endpoints' _connected*HandleIds, then debounced autosave */
export function addEdge(tab: Tab, from: string, to: string): OpResult {
  if (!uiInteractive(tab)) return { ok: false, blocked: 'overlay' }
  const src = nodeOf(tab, from)
  const tgt = nodeOf(tab, to)
  if (!src || !tgt) return { ok: false, blocked: 'no-node' }
  return inTab(tab, () => {
    tab.editsAttempted++
    const R = tab.world.real
    const { nodes, edges, setNodes, setEdges } = tab.hooks.collab.getState()
    const id = `${from}-source-${to}-target`
    if (edges.some((e: any) => e.id === id)) return { ok: true, applied: false }
    const newEdge = { id, type: 'custom', source: from, sourceHandle: 'source', target: to, targetHandle: 'target',
      data: { sourceType: src.data.type, targetType: tgt.data.type, isInIteration: false, isInLoop: false }, zIndex: 0 }
    const newNodes = R.produce(nodes, (draft: any[]) => {
      const s = draft.find((d) => d.id === from)!
      const t = draft.find((d) => d.id === to)!
      s.data = { ...s.data, _connectedSourceHandleIds: [...(s.data._connectedSourceHandleIds ?? []), 'source'] }
      t.data = { ...t.data, _connectedTargetHandleIds: [...(t.data._connectedTargetHandleIds ?? []), 'target'] }
    })
    setNodes(newNodes)
    setEdges([...edges, newEdge])
    tab.hooks.sync.handleSyncWorkflowDraft()
    return { ok: true, applied: true }
  })
}
/** use-edges-interactions handleEdgeDelete: edge removed + endpoints' _connected*HandleIds */
export function removeEdge(tab: Tab, id: string): OpResult {
  if (!uiInteractive(tab)) return { ok: false, blocked: 'overlay' }
  const e0 = tab.rf.edges.find((e: any) => e.id === id)
  if (!e0) return { ok: false, blocked: 'no-edge' }
  return inTab(tab, () => {
    tab.editsAttempted++
    const R = tab.world.real
    const { nodes, edges, setNodes, setEdges } = tab.hooks.collab.getState()
    const newNodes = R.produce(nodes, (draft: any[]) => {
      const s = draft.find((d) => d.id === e0.source)
      const t = draft.find((d) => d.id === e0.target)
      if (s) s.data = { ...s.data, _connectedSourceHandleIds: (s.data._connectedSourceHandleIds ?? []).filter((h: string) => h !== (e0.sourceHandle || 'source')) }
      if (t) t.data = { ...t.data, _connectedTargetHandleIds: (t.data._connectedTargetHandleIds ?? []).filter((h: string) => h !== (e0.targetHandle || 'target')) }
    })
    setNodes(newNodes)
    setEdges(edges.filter((e: any) => e.id !== id))
    tab.hooks.sync.handleSyncWorkflowDraft()
    return { ok: true, applied: true }
  })
}
