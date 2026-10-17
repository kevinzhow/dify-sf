## 1. 等价性论证

**命题。** Dify 协作编辑的"数据结果"（最终存档草稿、各客户端画布、被丢失/被覆盖的编辑）只取决于**事件的先后顺序**（外加"某个事件发生时各处状态是什么"），而不取决于事件的绝对时刻。依据：

1. 客户端数据面是确定性代码：`CollaborationManager`（整节点写 `populateNodeContainer`、按下标的 `syncList`、leader / `sync_request` / `graph_resync`、每次重连 `initializeCrdt` 新建 LoroDoc、`seedCrdtGraphFromReactFlowIfNeeded`、可见性 / `graph_view_state`）、`handleNodeDataUpdate` 的 `{...currentNode.data, ...data}`、5 秒 debounce 保存、带 hash 的保存与 `draft_workflow_not_sync` 回刷——给定"每个事件落在哪个客户端、先后如何"，输出确定；
2. CRDT（`loro-crdt@1.15.1`）对同一批操作与 (lamport, peer id) 的合并结果确定（真实浏览器的 peer id 随机，模拟器同样每个 LoroDoc 随机抽取）；
3. 服务端中继 / 选主 / 保存是确定的状态机。

**做法。** 不重写，把 **14 个真实 Dify 源文件原样打包**（构建时直接读 `dify-src`，sha256 清单在 `dist/manifest.json`、`FIDELITY.generated.md`），只替换环境：socket.io → 内存 FakeSocket（按 socket.io-client 4.8.3 语义：断线期间 emit 缓冲、重连退避 1→5 s、ack 丢弃）；ReactFlow store → 内存 store；`setTimeout / Date.now / requestAnimationFrame / document.visibilityState` → 虚拟时钟 + 确定性调度器（每个标签页独立 60 Hz 帧格，后台页 rAF 暂停）；后端 Python 按方法名一对一移植（含**与真实服务器逐位相同的 `unique_hash`**：对 15 份真实浏览器存档复算 15/15 一致）。调度器能产生浏览器能产生的任意事件顺序（逐链路延迟 / 抖动 / 重传 / 断线 / 黑洞、可见性切换、关闭 / 崩溃、重连退避），且**同一 seed 复现同一次运行**。

**这是"条件等价"，不是严格数学等价**。成立的前提与缺口（逐行见 `FIDELITY.md`）：
- (a) 手写移植（非原样运行）的部分：React 组件 effect（`index.tsx` / `workflow-main.tsx` 的 `onGraphImport`、`onSyncRequest`、可见性 / 关页处理）、`initialNodes` 简化版、各 UI 操作的数据变换（改标题 / 加输出变量 / 拖动 / 删除 / 连线 / 选中）；
- (b) 未建模：客户端 CPU（真实标签页每收一个更新要解码+导入 ≈250 KB 整库、再做 3 次 500 节点导出，100 人时单核已超载）、服务端 CPU/带宽上限、ReactFlow DOM 测量、engine.io 心跳细节；
- (c) 三个只省宿主机算力、不改结果的优化层（§3），用"精确模式 vs 优化模式逐位比对"证明；
- (d) 真实浏览器里"主线程延迟"取决于机器负载——模拟器提供两档：理想（60 Hz 帧格）和**校准档**（用真实 Chromium 实测的"消息到达→画布更新"延迟分布，§4）。

## 2. 保真度摘要（详见 FIDELITY.md）

| 类别 | 内容 |
|---|---|
| 原样运行 [R] | `collaboration-manager.ts`(2053 行)、`crdt-provider.ts`、`event-emitter.ts`、`websocket-manager.ts`（真实 `WebSocketClient`）、`use-collaborative-workflow.ts`、`use-node-data-update.ts`、`use-node-crud.ts`、两份 `use-nodes-sync-draft.ts`、`use-serial-async-callback.ts`、`workflow-draft-slice.ts`（debounce 5 s）、`use-workflow-refresh-draft.ts`、`use-workflow-update.ts`；`loro-crdt`/`es-toolkit`/`immer` 为真实 npm 包 |
| 环境替换 [S] | socket.io-client、`react` hooks（每标签页实例化一次当普通函数用）、`reactflow` store、zustand store、HTTP（含 keepalive 64 KiB 上限）、全局时钟 / 定时器 / rAF / document |
| 手写移植 [P] | 应用壳 effect、`initialNodes`、UI 操作变换、选中（`handleNodeSelect`）、关页顺序（先 `visibilitychange→hidden` 再 `beforeunload`，由真实 S5A/S6A 反推） |
| 后端移植 | `workflow_collaboration_service.py` 全部方法 + Redis 语义 + `sync_draft_workflow`（hash 校验、`graph_only`）+ python-socketio 的 room / ack / `call(timeout=15)` / 10 MiB 包上限 |
| 偏差 [A] | 单 worker；Redis TTL 不过期；服务端无 CPU / 带宽上限；心跳按 `45 s − φ` 检测；客户端 CPU 无限（可用 `rafDelayMs` / 校准分布压力测试） |

## 3. 优化层与"逐位等价"检验

真实 `loro-crdt@1.15.1` 在 Dify 的使用方式下又慢又**漏内存**（实测，本机）：provider 每次本地提交 `doc.export({mode:'update'})` 导出**整个历史**，接收方 `doc.import()` 整个历史；含 List 容器（`variables` / `prompt_template`）时每次 8~30 ms，并泄漏 wasm 内存 0.16~0.57 MB/次（500 节点图 100 个标签页预计 >80 GB，跑不动）。因此模拟器有四层**只改宿主机开销、不改结果**的优化（`SIM_FAST=off` 可全部关闭，回到完全精确模式）：

1. 诊断日志桩（manager 里只写日志数组的 4 个方法）；
2. `exportNode` / `getEdges` 缓存（由 Loro 事件路径 + 本地写入失效）；
3. **懒摄入**：纯 `update` 投递及其触发的 rAF 回调推迟到下一个能观察到该标签页的事件，再按虚拟时间顺序重放；仅当后到的更新版本向量覆盖前者、且赶在前者本应处理它的那一帧之前到达时才跳过前者；
4. **delta 线格式**：`export(update)` 返回 16 字节标记，`import(标记)` 等价于 `importJsonUpdates(接收方缺的变更)`。`scripts/delta-equiv.mjs`：随机并发文档（嵌套 map+list、乱序投递）5,719 次导入，状态 / 版本向量 / `by:'import'` 事件**零差异**。线上字节数按真实大小估计。

**逐位等价检验**（`SIM_FAST=off` vs 默认，同 seed）：37 个 S 系列场景 + 88 个目录用例 × 6 个 seed = **732 次运行，指标、归一化存档摘要、每次保存的时间戳/作者/结果、各客户端分歧全部相同（732/732）**。这个检验抓到过 2 个实现缺陷并已修复：①早期剪枝规则没考虑帧约束（1,464 次里 2 次不同）；②重放期间误把帧当作真实事件再调度一次（拖动场景 7/976 次不同）。
