// Emits the auditable table of every Dify import that is replaced by a shim (file:line -> shim, why) and the sha256 of every real file used.
import fs from 'node:fs'
import path from 'node:path'
const m = JSON.parse(fs.readFileSync('dist/manifest.json', 'utf8'))
const why = {
  'shims/websocket-manager.ts': 'webSocketClient is a module singleton; the REAL WebSocketClient class (websocket-manager.ts, unmodified) is instantiated once per simulated tab and the singleton name resolves to the current tab (AsyncLocalStorage)',
  'shims/collab-singleton.ts': 'collaborationManager singleton -> per-tab instance of the REAL CollaborationManager class',
  'shims/config.ts': 'next config: SOCKET_URL=ws://localhost (docker default), API_PREFIX',
  'shims/hooks-store.ts': 'zustand hooks-store -> per-tab plain object holding the real doSyncWorkflowDraft/syncWorkflowDraftWhenPageClose/handleRefreshWorkflowDraft',
  'shims/workflow-store.ts': 'zustand workflow store -> per-tab object built from the REAL workflow-draft-slice (5 s debounce) plus the fields the data path reads',
  'shims/use-workflow.ts': 'useNodesReadOnly(+ByCanEdit): constant false (no run/history/restore state in the workload)',
  'shims/event-emitter.ts': 'React context event emitter -> per-tab emitter delivering WORKFLOW_DATA_UPDATE to the app-shell handler',
  'shims/app-store.ts': 'appDetail.mode = workflow',
  'shims/service-workflow.ts': 'fetch wrappers -> simulated console API over the simulated network (src/sim/world.ts httpFor)',
  'shims/service-fetch.ts': 'postWithKeepalive -> simulated POST honouring the 64 KiB keepalive body cap',
  'shims/workflow-constants.ts': 'constant WORKFLOW_DATA_UPDATE',
  'shims/workflow-utils.ts': 'initialNodes/initialEdges -> simplified port (src/sim/workflow-init.ts)',
  'shims/draft-graph-for-canvas.ts': 'getWorkflowDraftGraphForCanvas: only the "graph already has a Start node" branch is reachable',
  'shims/features-hooks.ts': 'features store (opening/suggested/...): constant disabled features; only used to build the (ignored, graph_only) features payload',
  'shims/agent-v2-types.ts': 'agent-v2 predicates: false (no agent nodes in the workload)',
  'shims/workflow-types.ts': 'BlockEnum values used by use-nodes-sync-draft.ts',
  'shims/system-features.ts': 'enable_collaboration_mode = true',
  'shims/app-deletion.ts': 'isAppDeletingOrDeleted = false',
}
const lines = []
lines.push('| Dify file : line | import | replaced by | why |', '|---|---|---|---|')
for (const s of m.shimmed) {
  const f = path.join(m.web, s.importer)
  const src = fs.readFileSync(f, 'utf8').split('\n')
  const ln = src.findIndex((l) => l.includes(`'${s.spec}'`) && /import|from/.test(l)) + 1
  lines.push(`| ${s.importer}:${ln || '?'} | \`${s.spec}\` | \`${s.shim}\` | ${why[s.shim] ?? ''} |`)
}
lines.push('', '### Real Dify files executed unmodified (sha256 of the file in dify-src @ 1.17.1)', '', '| file | lines | sha256 |', '|---|---|---|')
for (const f of m.files) lines.push(`| ${f.file} | ${f.lines} | ${f.sha256.slice(0, 16)}… |`)
fs.writeFileSync('FIDELITY.generated.md', lines.join('\n') + '\n')
console.log(lines.length, 'rows')
