| Dify file : line | import | replaced by | why |
|---|---|---|---|
| app/components/workflow/collaboration/core/crdt-provider.ts:6 | `./websocket-manager` | `shims/websocket-manager.ts` | webSocketClient is a module singleton; the REAL WebSocketClient class (websocket-manager.ts, unmodified) is instantiated once per simulated tab and the singleton name resolves to the current tab (AsyncLocalStorage) |
| app/components/workflow/hooks/use-nodes-sync-draft.ts:3 | `@/app/components/workflow/hooks-store` | `shims/hooks-store.ts` | zustand hooks-store -> per-tab plain object holding the real doSyncWorkflowDraft/syncWorkflowDraftWhenPageClose/handleRefreshWorkflowDraft |
| app/components/workflow-app/hooks/use-workflow-refresh-draft.ts:2 | `@/app/components/app/store` | `shims/app-store.ts` | appDetail.mode = workflow |
| app/components/workflow/hooks/use-workflow-update.ts:4 | `@/context/event-emitter` | `shims/event-emitter.ts` | React context event emitter -> per-tab emitter delivering WORKFLOW_DATA_UPDATE to the app-shell handler |
| app/components/workflow/hooks/use-workflow-update.ts:5 | `../constants` | `shims/workflow-constants.ts` | constant WORKFLOW_DATA_UPDATE |
| app/components/workflow/collaboration/core/websocket-manager.ts:4 | `@/config` | `shims/config.ts` | next config: SOCKET_URL=ws://localhost (docker default), API_PREFIX |
| app/components/workflow/hooks/use-nodes-sync-draft.ts:4 | `../store` | `shims/workflow-store.ts` | zustand workflow store -> per-tab object built from the REAL workflow-draft-slice (5 s debounce) plus the fields the data path reads |
| app/components/workflow/hooks/use-collaborative-workflow.ts:4 | `../collaboration/core/collaboration-manager` | `shims/collab-singleton.ts` | collaborationManager singleton -> per-tab instance of the REAL CollaborationManager class |
| app/components/workflow/hooks/use-workflow-update.ts:6 | `../utils` | `shims/workflow-utils.ts` | initialNodes/initialEdges -> simplified port (src/sim/workflow-init.ts) |
| app/components/workflow-app/hooks/use-workflow-refresh-draft.ts:4 | `@/app/components/workflow/store` | `shims/workflow-store.ts` | zustand workflow store -> per-tab object built from the REAL workflow-draft-slice (5 s debounce) plus the fields the data path reads |
| app/components/workflow/hooks/use-nodes-sync-draft.ts:5 | `./use-workflow` | `shims/use-workflow.ts` | useNodesReadOnly(+ByCanEdit): constant false (no run/history/restore state in the workload) |
| app/components/workflow/hooks/use-node-data-update.ts:6 | `./use-workflow` | `shims/use-workflow.ts` | useNodesReadOnly(+ByCanEdit): constant false (no run/history/restore state in the workload) |
| app/components/workflow-app/hooks/use-workflow-refresh-draft.ts:5 | `@/service/workflow` | `shims/service-workflow.ts` | fetch wrappers -> simulated console API over the simulated network (src/sim/world.ts httpFor) |
| app/components/workflow-app/hooks/use-workflow-refresh-draft.ts:6 | `./use-workflow-draft-graph-for-canvas` | `shims/draft-graph-for-canvas.ts` | getWorkflowDraftGraphForCanvas: only the "graph already has a Start node" branch is reachable |
| app/components/workflow-app/hooks/use-nodes-sync-draft.ts:11 | `@/app/components/base/features/hooks` | `shims/features-hooks.ts` | features store (opening/suggested/...): constant disabled features; only used to build the (ignored, graph_only) features payload |
| app/components/workflow-app/hooks/use-nodes-sync-draft.ts:12 | `@/app/components/workflow/collaboration/core/collaboration-manager` | `shims/collab-singleton.ts` | collaborationManager singleton -> per-tab instance of the REAL CollaborationManager class |
| app/components/workflow/collaboration/core/collaboration-manager.ts:24 | `./websocket-manager` | `shims/websocket-manager.ts` | webSocketClient is a module singleton; the REAL WebSocketClient class (websocket-manager.ts, unmodified) is instantiated once per simulated tab and the singleton name resolves to the current tab (AsyncLocalStorage) |
| app/components/workflow-app/hooks/use-nodes-sync-draft.ts:17 | `@/app/components/workflow/hooks/use-workflow` | `shims/use-workflow.ts` | useNodesReadOnly(+ByCanEdit): constant false (no run/history/restore state in the workload) |
| app/components/workflow-app/hooks/use-nodes-sync-draft.ts:21 | `@/app/components/workflow/nodes/agent-v2/types` | `shims/agent-v2-types.ts` | agent-v2 predicates: false (no agent nodes in the workload) |
| app/components/workflow-app/hooks/use-nodes-sync-draft.ts:22 | `@/app/components/workflow/store` | `shims/workflow-store.ts` | zustand workflow store -> per-tab object built from the REAL workflow-draft-slice (5 s debounce) plus the fields the data path reads |
| app/components/workflow-app/hooks/use-nodes-sync-draft.ts:23 | `@/app/components/workflow/types` | `shims/workflow-types.ts` | BlockEnum values used by use-nodes-sync-draft.ts |
| app/components/workflow-app/hooks/use-nodes-sync-draft.ts:24 | `@/config` | `shims/config.ts` | next config: SOCKET_URL=ws://localhost (docker default), API_PREFIX |
| app/components/workflow-app/hooks/use-nodes-sync-draft.ts:25 | `@/features/system-features/client` | `shims/system-features.ts` | enable_collaboration_mode = true |
| app/components/workflow-app/hooks/use-nodes-sync-draft.ts:26 | `@/service/app-deletion` | `shims/app-deletion.ts` | isAppDeletingOrDeleted = false |
| app/components/workflow-app/hooks/use-nodes-sync-draft.ts:27 | `@/service/fetch` | `shims/service-fetch.ts` | postWithKeepalive -> simulated POST honouring the 64 KiB keepalive body cap |
| app/components/workflow-app/hooks/use-nodes-sync-draft.ts:6 | `@/service/workflow` | `shims/service-workflow.ts` | fetch wrappers -> simulated console API over the simulated network (src/sim/world.ts httpFor) |

### Real Dify files executed unmodified (sha256 of the file in dify-src @ 1.17.1)

| file | lines | sha256 |
|---|---|---|
| app/components/workflow-app/hooks/use-nodes-sync-draft.ts | 284 | 9a257fd524979718… |
| app/components/workflow-app/hooks/use-workflow-refresh-draft.ts | 83 | aca6d6aea440f936… |
| app/components/workflow/collaboration/core/collaboration-manager.ts | 2053 | f03f2639e9968abb… |
| app/components/workflow/collaboration/core/crdt-provider.ts | 72 | 7933338c1c090844… |
| app/components/workflow/collaboration/core/crdt-runtime.ts | 21 | 14a95a259d32b185… |
| app/components/workflow/collaboration/core/event-emitter.ts | 44 | f7c9fb6b91c78ea6… |
| app/components/workflow/collaboration/core/websocket-manager.ts | 149 | 6257fd8c69d762cb… |
| app/components/workflow/hooks/use-collaborative-workflow.ts | 93 | 11b0438952cffe20… |
| app/components/workflow/hooks/use-node-data-update.ts | 52 | 649d26c72aba2fc5… |
| app/components/workflow/hooks/use-nodes-sync-draft.ts | 31 | 9fae8a64b7542554… |
| app/components/workflow/hooks/use-serial-async-callback.ts | 21 | 2772e1156a737a68… |
| app/components/workflow/hooks/use-workflow-update.ts | 38 | 147600a7b13ff05e… |
| app/components/workflow/nodes/_base/hooks/use-node-crud.ts | 29 | 03dffb3a72db43be… |
| app/components/workflow/store/workflow/workflow-draft-slice.ts | 56 | 67fbe210aab4c4ef… |
