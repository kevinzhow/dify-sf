# Dify 工作流编辑器丢改动：实测报告（v1.17.1）

结论先说：**丢，而且不难丢。** 默认开启协作模式（CRDT）的 1.17.1 里，"两个人同时改不同节点"合并得很好（0/20）；但碰到「leader 离开 / 断网 / hash 过期 / 导入恢复 / 关页」这些边界，用户屏幕上已生效的编辑会**悄无声息地**没存进服务器，或被后来的保存覆盖，多数场景 100% 复现（20/20）。关闭协作模式（旧行为）则连"两个人各改一处"都 20/20 丢。

> **实测**=在真实 Dify + 真实 Chromium 里跑出来的，附次数；**代码推断**=只从源码读出、没触发实验。数字是 N 次里的出现次数，原始逐次记录在 `logs/*.jsonl`。

## 1. 环境与方法
- Dify `1.17.1`（tag，commit 8387590；main HEAD 0d580fd 更新，见 §6）。官方 compose，`ENABLE_COLLABORATION_MODE=true`（`/console/api/system-features` 返回 `enable_collaboration_mode:true`，浏览器里确实建立 `ws://localhost/socket.io` 连接）。
- 只绑本机：nginx `127.0.0.1:80`，plugin_daemon `127.0.0.1:5003`（override 文件）。账号是一次性的测试账号。
- 浏览器：Playwright 驱动**真实 Web UI**（点节点、改标题/描述、拖拽、加输出变量、Delete），每个 tab 一个独立 Chromium 进程。每次 run 新建 workflow（start→c1..c4 四个 Code 节点串联引用→end），等 autosave 稳定（14s）后比较「编辑者本地所见」「各 tab 最终画布」「服务器 draft」。
- 判定：**丢**=编辑在本端已显示生效，但最终服务器 draft 没有（且不是被同字段后写者覆盖）；**分歧**=各端画布彼此或与服务器不一致。
- 注入：socket.io 延迟/断网用 `route_web_socket` 代理（已验证：单向 400ms 时对端 0.81–0.88s 才看到，0ms 时 0.07–0.09s，`logs/latency_probe.txt`）；"后台标签页"是**模拟**（覆盖 `visibilityState`、派发 `visibilitychange`、暂停 rAF）；"崩溃"是对该 tab 浏览器进程树 `SIGKILL`。
- 局限：图小（4 节点）；没测多 websocket worker、token 过期、真实后台标签计时器节流；机器期间被别的任务占满过 CPU，受影响批次放 `logs/aborted/`，不参与统计。

## 2. 代码机制（file:line，1.17.1，`web/app/components/` 与 `api/` 前缀省略）
**保存模型**
- M1 整图覆盖+乐观锁：`workflow_service.py:439-440` 比较 `unique_hash`；hash 只算 graph（`models/workflow.py:554-563`），不含 features/变量。服务端不理解内容：基线对、内容旧的整图照收。
- M2 冲突后"只换 hash、不换画布"：`workflow-app/hooks/use-nodes-sync-draft.ts:195-203` 收到 `draft_workflow_not_sync`→`handleRefreshWorkflowDraft(true)`（`use-workflow-refresh-draft.ts:46-48` 的 `notUpdateCanvas`）。失败那次不重试；下次保存带新 hash+旧画布，服务器照收。该刷新还会 `cancel()` 待发 debounce（`:35`）。
- M3 autosave 5s debounce（`workflow/store/workflow/workflow-draft-slice.ts:35-37`）。关页补救靠 keepalive POST（`use-nodes-sync-draft.ts:127-139`、`workflow/index.tsx:421-458`、`service/fetch.ts:241-260`）：不看响应；keepalive 请求体限 64KB，超了抛错被 `.catch(() => {})` 吞。
- M13 features/会话变量/环境变量走独立接口，整对象替换、无 hash（`workflow_service.py:571-620`）；非协作模式 graph 保存还顺带覆盖 features 和会话变量（`:477-480`）。
- M14 服务端不做引用完整性：空图放行（`workflow_service.py:1812-1814`）、悬空边与悬空变量引用都存。

**协作层**
- M4 服务端只转发+选 leader，不存 CRDT：`graph_event` 纯广播（`controllers/console/socketio/workflow.py:59-64`、`workflow_collaboration_service.py:338-348`）。真正写库的是前端 **leader 标签页**：follower 保存发 `sync_request`，服务端转给 leader（`workflow_collaboration_service.py:228-304`，超时 15s），leader 导入 follower 快照后用自己的 hash 保存（`workflow-main.tsx:347-368`、`collaboration-manager.ts:1787-1810`、`use-nodes-sync-draft.ts:227-257`）。
- M5 初始化：每次加入 `new LoroDoc()`（`collaboration-manager.ts:568`）。画布先用 HTTP draft 渲染；leader 把 ReactFlow 的图灌进 CRDT（`:1879-1883`、`:2009-2027`），follower 向 leader 要快照（`:1983-2007`）。**连着时以 CRDT 为准，不与服务器 draft 比对**。
- M6 CRDT 粒度：节点 `data` 每个 key 一个 LWW 寄存器（`:345-406`）。对象/数组值（`outputs`、`model`、`conditions` 等）整体原子；只有 `variables/prompt_template/parameters` 按下标做列表 diff（`:418-440`）。字符串无文本 CRDT。
- M7 保存被静默跳过：`canPersistLocalGraph()` 为 false（断线/隐藏/未受信任）时 `performLocalSync` 直接 `return null`（`use-nodes-sync-draft.ts:155-158`、`collaboration-manager.ts:806-809`）。重连后重建空 CRDT，leader 用服务器 draft 整图覆盖画布（`:1909-1921,1870-1878`、`workflow-main.tsx:370-405`）→ 断线前 5s 内没存的改动没了。
- M8 leader 关页只有"唯一在线用户"才 flush：`canFlushGraphOnPageClose`（`:841-851`）。别人在线时 leader 最后 5s 的改动只活在对方内存里。
- M9 hash 只在"自己保存/刷新"时更新（`use-nodes-sync-draft.ts:183,246`、`use-workflow-refresh-draft.ts:48`）。从没保存过的 follower 的 hash 永远是加入时的；接任 leader 后首次保存必 409，关页 keepalive 也 409 且无人知晓。
- M10 同步失败不重试：follower→leader 超时则 `requestWorkflowSync` 抛错、仅回调 onError（`:921-985`）。
- M11 本地编辑写回**整节点 ReactFlow 副本**（`hooks/use-collaborative-workflow.ts:38-58`→`collaboration-manager.ts:509-523,1270-1290`），而远端更新要等 rAF 才落到 ReactFlow（`:1344-1389`）。窗口内的本地编辑会拿陈旧副本覆盖刚到的远端字段（推断+剂量关系实测）。
- M12 导入 DSL/版本恢复/按服务器 draft 刷新**只改 ReactFlow、不进 CRDT**（`workflow/index.tsx:352-366`、`hooks/use-workflow-update.ts:12-33`、`update-dsl-modal.tsx:62-79`、`workflow-main.tsx:315-331`）。随后任何 CRDT 更新或标签页重新可见，画布还原成导入前，leader 下次保存覆盖导入。
- M15 在已被他人删除的节点上编辑：`getNodeContainer` 发现容器不存在就重建（`collaboration-manager.ts:265-298`）→ 节点复活。

## 3. 场景结果（协作模式 ON；命令均为 `.venv/bin/python scenarios.py <名> --runs 20 --parallel 3`）

### 3.1 并发编辑
| 场景 | 步骤 | 结果 | 机制 |
|---|---|---|---|
| S1 | A 改 c1 标题+拖 c2；B 改 c3 标题+拖 c4 | **0/20** | CRDT 合并正常 |
| S1L | 同上 + 单向 400ms | **0/20** | — |
| S1N | A 改 c1 标题，B 同时改 c1 描述 | 4/40 丢（忙 3/20、闲 1/20），丢的都是 B 的描述 | M11（推断） |
| S1NL | 同上 + 400ms | 0/20 | 窗口只在"远端已进 CRDT、未进 ReactFlow"那一帧 |
| S1NR | 同 S1N，每帧 rAF 延迟 250ms | **12/20 丢**，各端一致收敛到"丢了的版本" | M11；丢失率随帧延迟升高 |
| S2 | 同节点同字段并发 | 必有一值消失（LWW）；无延迟时输家 0.3s 内看到被覆盖 | M6 |
| S2L | 同上 + 400ms | 20/20 两人都"看到生效"约 0.4s，随后一个被静默替换 | M6，无冲突提示 |
| S2O | 两人给同一 Code 节点各加一个不同输出变量 | **19/19** 只剩一个 | M6：`outputs` 整体原子 |
| S2OL | 同上 + 400ms | **20/20** | — |
| S2OS/S2OM | B 晚 3s / 0.8s | 0/20 / 0/20 | 对照 |

### 3.2 后台 / 过期标签页 / leader 交接
| 场景 | 步骤 | 结果 | 机制 |
|---|---|---|---|
| S3A | B（模拟后台）期间 A 编辑+保存，B 回前台再改 | 0/20 | — |
| S3B | leader A 进后台，B 编辑 | 0/20 | 服务端把 leader 让给可见者 |
| S3D | 回前台 0.2s 内编辑 | 1/20（非协作 2/20） | M2 |
| **S3C** | A(leader)、B、C；A 改+保存后离开；B（从没保存过）改一处 | **20/20 永久丢** | M9+M2+M8 |
| **S3E** | A、B：A 改+保存后离开；B 改一处，1s 后关页 | **20/20 丢** | M9 |
| S10 | A 改并保存，B（一直开着、可见）随后改两次 | 0/20 | 对照 |

### 3.3 断网 / 重连
| 场景 | 步骤 | 结果 | 机制 |
|---|---|---|---|
| S4A | follower 断 12s，期间 A 编辑，恢复后 B 再改 | 0/20 | — |
| S4B | B 断线后在已聚焦输入框继续打字 | 20/20 被拒（"Syncing data" 遮罩） | 非静默，但正在输入的内容消失 |
| **S4C** | 单人：改一处，2s 后断 websocket，8s 后恢复 | **20/20 丢**：重连后画布回退，无提示 | M7 |
| **S4D** | leader 静默掉线 60s，期间 B 编辑 | **10/10**：70s 内 B 没有保存请求 | M10 |

### 3.4 关页 / 崩溃 / 单人基线
| 场景 | 步骤 | 结果 | 机制 |
|---|---|---|---|
| S6A/B/D | 单人 4 处编辑后 0.3s 正常关页/刷新/跳转 | 0/20 ×3 | keepalive 兜住 |
| S6E | 等 autosave | 0/20 | — |
| S6C | 同上但浏览器 SIGKILL | **20/20 丢** | 5s debounce 窗口 |
| **S6F** | 单人 100 节点图（体约 72KB）改一处后 0.5s 关页 | **19/20 丢**（非协作 20/20） | M3：keepalive>64KB |
| S6G | 30 节点（23KB）对照 | 2/20 丢 | 无法区分产品还是关页时序 |
| **S5A** | A(leader) 改一处，0.5s 后正常关页，B 开着 | **20/20** 服务器没有、B 屏幕上有；B 之后正常关页才补上（18/20） | M8 |
| **S5B** | 同上但 A 被 SIGKILL | 20/20 服务器没有；B 正常关页后补上 | M8 |
| **S5C** | follower B 改一处后关页，A(leader) 空闲，之后 A 被 SIGKILL | **20/20 永久丢** | follower 关页不 flush |
| S5D | 单人改一处 0.5s 后 SIGKILL | 19/20 丢 | 同 S6C |

### 3.5 删除、外部写入、导入
| 场景 | 步骤 | 结果 | 机制 |
|---|---|---|---|
| S7A | A 删 c2，B 同时改 c2 标题（c3 引用 c2.result） | 35 个有效 run：29 次删除生效、B 编辑丢；6 次**节点复活**；29 次 c3 留下悬空引用 | M15+M14 |
| S7AL | 同上 + 400ms | 20/20 删除生效、B 编辑丢、引用悬空 | — |
| S7B | 单人删 c4（End 引用 c4.result） | 20/20 留悬空引用 | 非协作问题（M14） |
| **S8** | 草稿被带 hash 的外部写入改过，开着的 tab 随后改两处 | **20/20** 第二次保存覆盖外部修改 | M2 |
| **S9** | 草稿被整体替换并广播 `workflow_update` 时 B 刚改 | 20/20 B 改动丢，A、B 画布不一致 | M12 |
| **S9Y** | 同上无并发编辑；6s 后 B 连改两处 | **20/20** 导入被覆盖 | M12+M2 |
| **S9ZC** | 单人：草稿被替换后标签页切走再切回 | **20/20** 画布回退 | M12 |
| S9X | S9 之后 A 再做无关编辑 | 20/20 导入被覆盖 | — |

S9* 用 API+无头 socket.io 客户端模拟"别人导入/恢复"，没走导入对话框 UI。

### 3.6 关闭协作模式（旧行为）
S1 两人改不同节点 **20/20 丢**+分歧；S1N 20/20；S2 20/20 分歧；S10 过期可见标签页 **20/20** 覆盖；S3A 20/20 分歧；S8、S6F、S6C 20/20；S6A/B/D 0/20；S3D 2/20。协作模式堵住了旧版"过期标签页覆盖/并发整图覆盖"，但把风险换成了"leader 单点+内存里的 CRDT 不持久化"。

### 3.7 直接打 API（`api_tests.py`，各 20 次）
| 测试 | 结果 |
|---|---|
| A1 两客户端持同一旧 hash 先后保存 | 后者 409（20/20）：乐观锁本身是对的 |
| A2 复刻前端冲突后"只换 hash" | 20/20 前者修改被覆盖 |
| A3 features 并发 | 20/20 都 200，一方设置消失 |
| A4 非协作 graph 保存带旧 features | 20/20 回退别人刚存的 features |
| A5 删节点后保存/空图保存 | 20/20 悬空边、悬空引用、空草稿全部落库 |

## 4. 没复现出丢失的
S1、S1L、S1NL、S2OS、S2OM、S3A、S3B、S4A、S10、S6A/B/D/E、S9ZA/B。协作模式下"两人同时改不同节点"实测可靠。

## 5. 观察 vs 推断
- 推断/未验证：M11 的"一帧窗口"只有剂量关系证据；真实后台标签的计时器节流；websocket URL 默认值导致非 80 端口时静默退化为本地草稿模式（未在浏览器验证）；多 worker 下 leader 判活；Undo/Redo 期间本地编辑被丢一帧。
- 部分"丢失"是延迟丢失（S5A/B：持有者之后关页才补上）。

## 6. 与上游 HEAD 的关系（只读 diff，没跑）
- main 新增 `replaceGraphFromCommittedDraft`，修了 DSL 导入这一支（M12）；新增"空画布保存要二次确认+服务端 force"。
- 协作服务端、leader 关页 flush（M8）、hash 过期（M9）、重连整图覆盖（M7）、`sync_request` 无重试（M10）、keepalive 64KB（M3）没有变化。
- 前端已有丢节点诊断（`captureSetNodesAnomaly`、`GraphImportLog`）。

## 7. 给竞品的启示
1. 编辑先持久化再确认：服务端存 op 日志，客户端拿到 ack 才显示"已保存"；浏览器内存不能是唯一副本（S3C/S5/S4D）。
2. 别让某个客户端当 saver；服务端合并，任何人离开都不影响持久化。
3. 导入/恢复/回滚走和普通编辑同一条 op 路径（M12）。
4. 冲突后不能"只采用新 hash 继续保存旧画布"（M2）；要重放本地 op 或明确提示。
5. 对象/数组配置要细粒度合并（S2O）；同字段冲突要有可见提示（S2L）。
6. 关页/断线/大图不能依赖 keepalive（64KB）和 5s debounce（S4C、S6F）。
7. 服务端要有引用完整性和"异常缩小"保护（A5、S7）。

## 8. 复现
```bash
cd research/real-browser
.venv/bin/python api_tests.py --runs 20
.venv/bin/python scenarios.py S3E --runs 20 --parallel 3   # stale hash
.venv/bin/python scenarios.py S5A --runs 20 --parallel 3   # leader 关页
.venv/bin/python scenarios.py S4C --runs 20 --parallel 3   # 单人断网 8s
.venv/bin/python scenarios.py S6F --runs 20 --parallel 3   # 大图关页
.venv/bin/python summarize.py
```
