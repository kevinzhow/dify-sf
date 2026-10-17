# Dify 协作编辑 vs dify-sf：形式化与解析证据

## 0. 结论
| 性质 | Dify 1.17.1 | dify-sf |
|---|---|---|
| P1 已确认的编辑不丢 | **不成立**（最短 6–9 步） | 成立（边界内穷举） |
| P2 不静默用旧覆盖新 | **不成立**（3–4 步） | 成立（修复"等值写入"缺陷后） |
| P3 静默后收敛且等于存储 | **不成立**（6–8 步） | 成立 |
| P4 无悬空引用 | **不成立**（5–6 步） | 成立 |
| P5 无静默丢弃 | **不成立**（6–9 步） | 成立 |

- Dify 反例在真实 Loro 库上逐个重放成功（`replay/replay_ce.py`，9/9 PASS），并与真实浏览器日志逐条对照（§5.1）。
- dify-sf 的穷举边界和未完成的运行见 §5.2，没有把超时的运行当作证明。
- 建模抓出一个协议缺陷（§5.3）：决定 (2)"等值写入接受"叠加"同客户端豁免"，3 步违反 P2。修复很小。
- 解析模型：50 人、400 ms 单向延迟、40/30/30 负载下约 1.5% 的已确认编辑静默丢失（约 270 次/小时）。

## 1. 文件
`tla/` Common/Dify/DifySF 与 cfg（`gen_cfgs.py` 生成）；`tools/`（tla2tools.jar、trace_summary.py、make_tables.py）；`replay/`（真 Loro 缩影，重放反例）；`loro-check/`（Loro 语义 U1–U7）；`crosscheck/`（反例 vs repro 日志）；`analytic/`（公式、模拟、图）；`results/`（TLC 日志、反例的可读版 `results/ces/`、各表）。TLC 跑在一台有 JDK 21 的远程主机上。

## 2. 共同接口与性质
- 接口：客户端；操作 setField/listInsert/listRemove/addNode/removeNode/moveNode/addEdge/setRef；消息延迟/乱序/丢失/重复；断线；客户端崩溃。Dify 特有：leader 选举/关闭、标签页隐藏、relay 重启、重连重建 LoroDoc。dify-sf 特有：服务端崩溃并从持久日志重启、重传。静默后进入 `Settled`（否则 TLC 报死锁 = 不收敛）。
- P1：每个已确认的操作，其效果在最终权威状态可见，或被同一寄存器上已确认的竞争写入、或已确认的 removeNode 合法取代。
- P2：不存在"写改变了寄存器的值，而同一寄存器上别的客户端在其 base 之后写过、作者没看到"。dify-sf 的检查器独立于服务端判断（对日志逐条严格检查，不用同客户端豁免捷径）；Dify 用写入的"谱系"判断。removeNode 同理：不得抛弃别人未见的修改。布局字段 p 豁免（决定 1）。
- P3：Settled 后每个视图等于最终状态。P4：没有指向不存在节点的引用或端点缺失的边；dify-sf 的显式 broken 标记不算悬空。P5：每个操作要么生效要么被告知；凡被丢/被静默覆盖的必须在"已告知"集合里。
- dify-sf 额外检查：已确认 ⇒ 在持久日志里；"没存上"确实不在日志里；无重复提交；崩溃恢复等于在线状态。

## 3. Dify 模型的忠实性（源码行，1.17.1）
- 每个客户端同时有 Loro doc（建模为写入操作集合，按 (lamport, peer) 做 LWW）和 React 视图，二者是两个对象。
- 本地编辑写回整节点：`collaboration-manager.ts:345-406 populateNodeContainer`、`:396`、`:1270-1290 syncNodes`；面板写回完整副本：`use-node-data-update.ts:24`。真 Loro 对"写入相同值"不产生操作（U1）。
- 远端更新立刻进 doc，视图在 rAF 里才刷新：`:1344-1389`。这就是"视图滞后"窗口，对应 repro 的 M11。
- 列表：`variables/prompt_template/parameters` 按下标 diff（`:418-440`）；其余（如 code 节点 `outputs`）整值 LWW（`:396`）。
- 在已被删节点上编辑会重建容器，节点复活：`:265-298`（repro M15）。删除不改写引用：`use-nodes-interactions.ts:678-800`（repro M14）。
- 每次连接新建 LoroDoc（`:564-568`）。只有 leader 保存：5 s 防抖（`workflow-draft-slice.ts:35-37`），follower 通过 `sync_request`（`workflow_collaboration_service.py:228-304`）；hash 校验（`workflow_service.py:439-440`）；失败不重试。
- Loro 语义用真库验证（`loro-check/loro_semantics.py`，U1–U7 全 PASS）：等值写入不产生操作；LWW 按 lamport 再按 peer id 破平；导出是累积的；并发追加都保留；删除节点会静默丢弃并发的内部编辑。
- 近似与未建模：Loro 的 peer id 用客户端号近似；新 doc 视作新 peer。未建模的 repro 机制：M12（导入/恢复绕过 CRDT）、M3（keepalive 64 KB）、M13（features 无 hash）、S4D（leader 静默掉线），M2/S8 只部分覆盖。

## 4. dify-sf 模型
对应原型加上三个决定：布局 LWW；等值写入接受；列表为按 id 的项级操作。抽象：
- 服务端到客户端的广播/应答建模为"拉取"（CatchUp，或在 Edit 之前懒加载）。丢失/重复/乱序等价于延迟，所有实际行为都被包含。
- 提交消息（submit）是显式网络消息，有丢失/重复/延迟；hello 与 welcome 合成一步 Sync。
- 不模拟快照压缩；客户端是 journaled（outbox 持久）。
- 对称约简（客户端、取值、初始节点）。每个 cfg 的穷举范围见下表。

## 5. 结果
### 5.1 Dify 反例（TLC BFS 最短；trace 在 `results/ces/*.txt`）
| 性质 | 反例 | 步数 | 对照 repro | 源码行 |
|---|---|---|---|---|
| P1/P5 | 两人改同一节点的不同字段：B 在 A 的更新进了 B 的 doc、但视图未刷新时编辑，整节点写回把 A 的字段还原；A 本地已确认 | 9 | S1N 3/20、S1NR 12/20、S1NL 0/20（延迟窗口移位，与模型一致） | `:345-406`、`:1344-1389` |
| P2 | 同节点同字段并发：LWW 静默丢一个，双方都以为生效 | 3 | S2L 20/20（S2 的 0/20 是 harness 标注问题） | `:396` |
| P1 | 对象值整体原子（code 的 `outputs`）：两人各加一个变量只剩一个 | 9 | S2O 19/19、S2OL 20/20；S2OM/S2OS 0/20 | `:396` |
| P1 | 按下标列表：陈旧视图的追加删掉远端新增项；删除项被陈旧编辑复活 | 9 | **无真实浏览器观察**，仅在真 Loro 重放 | `:418-440` |
| P1/P2 | 删除 vs 编辑：编辑被静默丢弃，或陈旧视图使节点复活 | 3 / 9 | S7A（节点复活、删除被还原）、S7AL 20/20 | `:265-298`、`:1278` |
| P4 | 删除被引用节点：引用悬空；并发加边指向已删节点 | 5 / 9 | S7B 20/20、A5 20/20 | `use-nodes-interactions.ts:678-800` |
| P1 | 标签页在 5 s 防抖内关闭/崩溃，或断线后重连，未存编辑丢 | 4 / 7 | S6C 20/20、S5D、S4C 20/20；S6A/B/D 正常关页 0/20 | M3/M7 |
| P1/P3 | follower 改后关页，leader 内存里有而库里没有；leader 先死则永久丢 | 6 | S5C 20/20 | M8 |
| P1/P3 | 新 leader 沿用旧 hash，首次保存失败且不重试 | 5（覆盖探针） | S3C、S3E 20/20 | M9/M2 |
| P1 | relay 重启，未存编辑丢 | 7 | **无 repro 场景** | M7 |
| P1 | 编辑后立刻隐藏标签页：防抖在隐藏时触发而被跳过，且不会重新触发 | 8 | **无 repro 场景**（S3D 相邻） | `canPersistLocalGraph` |

Dify 在"各人各改各的节点"（2 客户端×2 操作，setField，f1/f2）上穷举成立（4.5M 状态），与 S1 的 0/20 一致。

### 5.2 dify-sf（穷举；`results/table_sf.txt`）
| 配置（客户端×操作，故障数，字母表） | 状态数 | 结果 |
|---|---|---|
| 2×2, f0, setField(f1) | 2.9M | 成立 |
| 2×2, f0, setField(f1,f2) | 4.7M | 成立 |
| 2×2, f0, list insert/remove | 0.21M | 成立 |
| 2×2, f0, move+delete | 9.3M | 成立 |
| 2×2, f0, struct | 27.6M | 成立 |
| 2×2, f1, setField/removeNode/setRef | 37.6M | 成立 |
| 2×2, f1, list insert/remove | 2.9M | 成立 |
| 2×2, f2, setField | 8.5M | 成立 |
| 2×2 f1 move+delete；3×1 f2 全操作；3×2 f0 f1；2×3 f1 | 20–118M | 时间到未发现违例；**未完成，不算证明** |
- 随机模拟：3 客户端×4 操作×2 故障、全操作，约 22M 采样状态，无违例。
- 有界活性（Quiesce 后每个公平执行到达 Settled，各动作弱公平）：2c1o f2 成立（324k 状态）；2c2o f1 超时无结论。
- 故障覆盖：服务端崩溃、客户端崩溃、断线、submit 的丢失/重复/乱序延迟；覆盖探针证实拒绝、等值接受、级联、崩溃、重复在界内可达。

### 5.3 建模发现的缺陷
c1 先后发 f1:=v1、f1:=v2（base 都是 0），c2 并发发 f1:=v1。服务端先收 c2 的写入；c1 的第一个写等值，按决定 (2) 被接受并取得版本戳；第二个写因"最后写者是自己"被豁免，覆盖了它没见过的 c2 的写入。修复：等值写入是空操作，不取版本戳，也不更新 touch。修复后全部通过；撤销修复（`EqualStamp=TRUE`）TLC 立刻重现。原型没有决定 (2)，所以它的 20 万次 fuzz 没覆盖到。

### 5.4 突变测试
`SFmut_*` 的 8 个注入缺陷全部被抓：NoStale（P2）、NoCascade（P4）、NoDedup（日志）、EarlyAck（已确认不在日志）、NoFrom（"没存上"的操作后来被提交）、NoResend（死锁）、NoTouch（P2）、EqualStamp（P2）。

## 6. 解析丢失率模型
`analytic/NOTES.md`；图在 `analytic/plots/*.png`。机制与窗口：
- 同寄存器 LWW：窗口 L+r（L 为路径延迟，r 为视图滞后）。
- 同节点异字段与列表追加：窗口 r，与网络延迟无关。
- 删除 vs 编辑：编辑一侧窗口约 2L+r。
- 持久化项：依赖假设的房间终止率和 leader 退出率。
- 同寄存器项的修正为 x/(1+x)（死时间过程；朴素 1−e^{−x} 在 x≈1 处高估约 25%）。

校验：与真 Loro 对拍 3000 个随机调度 0 不一致；公式 vs 模拟 43 格，中位相对误差 2%，汇总比 0.99；校准 r≈15–80 ms。
50 人、λ=0.1/s、r=50 ms、40/30/30 混合负载的丢失率：

| 单向延迟 | 丢失率 | 每小时 |
|---|---|---|
| 50 ms | 0.38% | 68 |
| 400 ms | 1.5% | 272 |
| 2 s | 5.6% | 1006 |

全不相交场景（i）只剩持久化项，数值完全由假设的 κ、μ 决定。difysim 对接脚本 `compare_difysim.py` 已就绪；现有 difysim 输出只有约 50–800 个编辑，对比没有信息量，且字段映射是猜测。

## 7. 局限
- 小范围穷举：每个配置的边界见 §5.2，部分较大配置未跑完。
- 未建模：volatile 客户端崩溃、快照压缩、多 worker、撤销/重做。
- dify-sf 模型不含 Swift 原型的代码，二者靠同一规则文字对应；建议把 §5.3 的修复同步到原型再 fuzz。
- 持久化项和 mix (ii) 的参数是假设，不是测得。

## 8. 重跑
```
cd research/formal
./run_all.sh                                   # 全部（约 2–3 小时，16 核）
python3 gen_cfgs.py                            # 重新生成 tla/*.cfg
./run_dify_matrix.sh 1500                      # Dify 反例 -> results/dify_summary.txt, results/ces/
./run_matrix.sh 2700 2                         # dify-sf 穷举 -> results/summary.txt
./run_long.sh 7200 5 SF_2c2o_f1_narrow ...     # 超时配置加长时间
./run_tlc.sh DifySF SFsim_3c4o_f2_all.cfg -simulate -depth 200
python3 tools/make_tables.py dify|sf|mut
.venv/bin/python replay/replay_ce.py
.venv/bin/python loro-check/loro_semantics.py
python3 crosscheck/ce_vs_repro.py
cd analytic && ../.venv/bin/python make_plots.py && ../.venv/bin/python compare_difysim.py
```
TLC 在一台有 JDK 21 的远程主机上运行（`run_tlc.sh`，用 `TLC_HOST` 指定；`TLC_LOCAL=1` 可本地跑）。
