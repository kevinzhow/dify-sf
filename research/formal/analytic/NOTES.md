# Dify 1.17.1 协同编辑：解析式「丢编辑率」模型（analytic/）

范围：只覆盖 Dify 数据通路 M1–M7（见任务书）；对 dify-sf 不做任何结论。所有数值都可由下面的命令复现。venv：`research/formal/.venv/bin/python`（下文记作 `PY`）。

## 0. 文件与复现命令（在 `analytic/` 下运行）

| 文件 | 作用 | 命令 / 耗时 |
|---|---|---|
| `model.py` | 闭式公式（参数 `Params`、`breakdown`、`per_hour`、`p_pair`…） | `PY model.py`（秒） |
| `sim.py` | 机制级蒙特卡洛（Loro 式 LWW/Fugue 列表/skip-if-equal/整节点 populate/syncList/视图滞后/relay/删除僵尸）+ 持久化 DES | 被其他脚本调用 |
| `validate_vs_loro.py` | toy doc vs **真 Loro 1.16.2**，随机 2–3 用户调度 | `PY validate_vs_loro.py 3000`（~20 s） |
| `validate_pair_windows.py` | 两用户逐 gap 扫描，模拟窗口 vs 公式窗口 | `PY validate_pair_windows.py` |
| `compare_sim_model.py` | 公式 vs 模拟，参数网格（43 格），写 `results/simgrid.{json,txt}`（`--quick` 写 `simgrid_quick.json`，不覆盖） | `PY compare_sim_model.py > results/simgrid.txt`（全量约 25 min，机器繁忙时）；`--quick` ≈ 20 s |
| `validate_persistence.py` | 持久化项公式 vs DES | `PY validate_persistence.py`（~数分钟） |
| `sim_markers.py` | 图 1/2 上的模拟点（N=10/25/50/100 × 3 延迟 × mix ii/iii） | `PY sim_markers.py > results/simmarkers.txt`（~5–30 min） |
| `calibration.py` | 与 repro/logs 对标（Clopper-Pearson、最大似然拟合 L0/r/δ） | `PY calibration.py [--sigma 0.03]`（~40 s） |
| `make_plots.py` | 6 张图 + csv 表格视图 → `plots/` | `PY make_plots.py` |
| `compare_difysim.py` | 读 difysim 结果并与预测对比；无结果则打印 "difysim results not found yet" 退出 0 | `PY compare_difysim.py [--dir D \| --file F]` |

## 1. 记号与假设

N 用户，每人 Poisson 编辑率 λ（默认 0.1/s）；L = 客户端→relay→客户端路径时延 = 2·lat（+L0，relay/处理开销）；r = 远端更新进入 Loro doc 到进入 React 视图的平均滞后（默认 50 ms；扫描 16–250 ms）；D = 5 s 防抖。丢失率 = 「被确认的编辑中，最终收敛状态里不存在、且没有任何「视图里包含它」的后续写入替代它」的比例。

**丢失判据（sim 与公式一致）**：寄存器类编辑 e 丢失 ⇔ e 不在最终值的 provenance 链（每次编辑记录它写入时视图里的旧值作为 parent）上；列表项 ⇔ 最终列表中不存在；节点被删 ⇔ 删除者视图里没见过 e 且 e 原本还活在容器里（否则按其本身机制计）；删除本身丢失 ⇔ 最终节点复活（僵尸）。

**负载模型（透明、可调）**：每次编辑以概率 s 落在「热点集」（H 个节点，均匀选），否则落在用户私有区域（与他人永不相交，故私有编辑只进分母）。热点节点有「类型」，按 40/30/30 分配：同一寄存器（所有人写同一 key，如 title / code 节点 `outputs`）/ 同节点不同字段（每人写自己的 key）/ 列表追加。因此「两次编辑落在同一节点」的条件下，恰好 40% 同寄存器、30% 不同字段、30% 列表不同项。三种 mix：
- (i) disjoint：s=0，碰撞项为 0，只剩持久化项；
- (ii) 40/30/30：s=0.5，H=30（热点 = 500 节点图的 6%，一半编辑落在其上），两次编辑撞同一节点的概率 s²/H=0.83%（均匀的 4.2 倍）；另设 2% 的热点事件是删除节点；
- (iii) uniform：s=1，H=500（均匀随机选节点；撞同一节点 0.2%），节点类型同样 40/30/30，2% 删除。
**这些 s、H、p_del 是假设，不是测得**；图 6c 给出对 s 的敏感性。

## 2. 公式（`model.py`）

令 ν_c = λ·s·(1−p_del)/H（某个其他用户在某个热点节点上的编辑率），其余 N−1 个用户独立。lag_lt(x)=E[e^{−x·lag}]（常数滞后 e^{−xr}；帧栅格滞后 U(0,2r) 为 (1−e^{−2rx})/(2rx)）。

* **(a) 同寄存器 LWW（窗口 W=L+r）**：编辑 e 被「击败」当且仅当存在其他用户的写入 p：p 与 e 在 doc 层并发（|Δ|<L，LWW 胜负 50/50 ⇒ 贡献 L）或 p 晚于 e 且 p 的视图尚未含 e（Δ∈(L,L+lag)，p 必胜 ⇒ 贡献 lag）。暴露量 x = (N−1)·[ν_c·L − ln lag_lt(ν_c)]≈ν·(L+r)，ν=(N−1)ν_c。**一阶**：P=1−e^{−x}。**饱和修正**：最终值只保留「每次都从含前驱的视图写出」的谱系；从最终值回溯，一次编辑的 parent 是比它早 W 以上的最后一次编辑，每代跳过的编辑数 ~Poisson(x)，所以幸存者构成**非瘫痪死时间过程**：幸存率 1/(1+x)，故 **P_a = x/(1+x)**。（第一版用 1−e^{−x}，在 x≈1 处比模拟高 25%，原因：被陈旧写者击败的编辑会在「仍看见它的后续写者击败陈旧写者」时复活。x/(1+x) 在 x∈[0.1,1.5] 对 ~10⁵ 编辑的模拟吻合到 ±1%。）
* **(b) 同节点不同字段（窗口 r，与网络时延无关）**：受害者 e 被还原 ⇔ 另一用户在 e 到达其 doc 之后、其视图刷新之前（Δ∈(L,L+lag)）写同一节点。P_b = 1−lag_lt(ν_c)^{N−1}≈ν·r。doc 并发（|Δ|<L）时被 skip-if-equal 吞掉，安全 ⇒ 时延只把窗口平移到 L 之后。
* **(c) 列表追加/追加**：同 (b)：P_c=P_b（并发追加都保留，U5；陈旧 syncList 逐下标覆盖/裁剪掉窗口内到达的远端项）。删除/编辑列表项的 L+r 变体：公式相同、窗口 L+r，未实现（任务书说明只需文字）；索引移位复活未建模。
* **(d) 删除 vs 编辑**：设 A 在 0 删节点，B 在 Δ 编辑同节点：Δ∈(−(L+lag), L) ⇒ **编辑**丢失（删除者没看见它 / doc 并发，U3），Δ∈[L,L+lag) ⇒ B 视图陈旧，重建僵尸（U4），**删除**丢失。窗口宽 2L+r（编辑受害）与 r（删除受害）；比任务书中单边「L+r」宽（两侧都算）。
* 每编辑总丢失率 = s·[(1−p_del)(w_same·P_a + w_diff·P_b + w_list·P_c) + (1−p_del)·P_edit,del + p_del·P_del,zombie] + 持久化项；每小时 = 3600·N·λ·率。
* **两用户 pair 函数**：`p_pair(kind, G, L, r)`：lww 为 |G|<L ∨ G∈(L,L+r)，即 |G|<L+r；diff/list 为 |G|∈(L,L+r)。均匀 gap 分布下 =窗口/spread（`p_pair_uniform_gap`）。

### (e) 持久化项（第二项，**强假设**）
只有 leader 存盘；任何一次防抖触发（任何人）都会让 leader 视图里已有的全部编辑落盘。故编辑的「未落盘时间」不是作者自己的防抖，而是：T_nd=(1−1/N)(L+r)+(1−e^{−f_o·T_own})/f_o，T_own=(e^{λD}−1)/λ（作者尾部防抖，每次本地编辑重置），f_o=(N−1)λe^{−λD}（他人触发率）。P(永久丢失)=κ·T_nd·(1+μ·extra)：κ=房间整体终止率（所有 tab 同时关闭/relay 重启，**假设 1/4 h**），μ=leader 退出/崩溃率（**假设 1/30 min**；退出后新 leader 首次存盘因 hash 过期失败且不重试，需再多一次存盘，extra≈1/(Nλe^{−λD})）。注意：leader 单独退出但仍有其他 tab 时，编辑仍在其他 tab 的内存里，只有房间终结才永久丢失——所以这项与 κ 成正比，**不是**任务书初稿里的 μ·(D+RTT)（那是「处于风险」的概率，见 `at-risk` 列）。随 N 增大 T_nd 反而变短（他人的防抖触发会顺带存盘）。数值很小（~1e-4）且完全由 κ 假设决定。

## 3. 验证

1. **toy doc ≡ 真 Loro**（`validate_vs_loro.py`）：3000 个随机 2–3 用户调度（含删除、僵尸、并发列表追加、抖动、两种刷新模式、整节点 populate、syncList），toy 与 loro 1.16.2 的收敛终态 **0/3000 不一致**，真 Loro 各副本均收敛；其中 ~60% 的调度出现静默丢失。过程中发现并修正了 toy 的 3 处差异：列表序必须是 Fugue（同 origin 的兄弟按 peer 序，RGA 的 lamport 序不同）、创建子列表容器也消耗一个 op（lamport 对齐）、`import` 无新 op 时不触发视图刷新。
2. **窗口形状**（`validate_pair_windows.py`）：两用户单次编辑，扫 gap：同寄存器丢失区间恰为 |g|<L+r；diff/list 恰为 (L,L+r)；删除 vs 编辑恰为 编辑丢失 (−(L+r),L)、删除丢失 [L,L+r)。边界等号外 0 分歧。
3. **公式 vs 模拟（43 格）**（`compare_sim_model.py`，结果 `results/simgrid.txt`，图 5）：N∈{5,10,25,50}×lat∈{50ms,0.4s,2s}×r∈{50,250ms}、λ 扫描 1/60..1/3、热点数 H=5..100、删除率 2/5/10%、稀疏 mix、常数 rAF 延迟。p_del≤2% 的 39 格：**中位相对误差 2.0%，汇总 sim/公式=0.99**，最大相对误差 17%（该格只有 42 个丢失事件，统计噪声）；全部 43 格最大绝对误差 0.005/事件。p_del=5–10%（不现实）时公式比模拟高 15–27%：节点被频繁替换后「同寄存器」谱系被切断（二阶效应，未建模）。逐机制：a/b/c/d 都吻合。|z|>3 的 4 格全部是 p_del≥5%；rms z=2.1 偏大是因为一次碰撞牵连多个编辑（计数过离散）且各格复用同一随机种子，并非系统偏差——高统计量单格复核（24 万编辑）：N=50,lat=50ms 模拟 0.03556±0.00038 vs 公式 0.03545；N=10 0.00666±0.00017 vs 0.00670。
4. **图 1/2 的实际工作点**（`sim_markers.py`，`results/simmarkers.txt`）：mix (ii)/(iii) × N=10/25/50/100 × 50ms/0.4s/2s 共 24 点，每点 52–498 个丢失事件（uniform N=10、50 ms 仅 52 个，±14%）；模拟/公式 汇总比 0.988，中位绝对偏差 4.7%，范围 −22%（52 事件那格）…+11%。图中圆点 = 模拟的碰撞项 + 公式的持久化项（持久化项无法在真实 κ 下直接模拟）。
5. **持久化 DES vs 公式**（`validate_persistence.py`）：见 `results/persist.txt`（为取得统计量把 κ、μ 放大到 10–30 min / 1–5 min）。N=20/50 偏差 −3%/−6%；N=10 −14%、N=5 +19%、N=3 −17%、N=2 −31%（小房间里 leader 退出后丢失的防抖定时器和 extra 估计较粗），仅作量级使用。
6. **一个由模拟发现的修正（重要）**：`per_import` 模式（每次 import 各自 +r 回调，repro 的 rAF 延迟压力）下，视图对一个 op 的滞后 = 最早未触发回调之前的剩余时间，流量越密越短；真实浏览器 rAF 同一帧合并，等价于「帧栅格」模式（滞后 U(0,2r)，与密度无关）。公式的 r 即「op 到达→视图可见」的平均滞后。

## 4. 与真实浏览器 repro 对标（`calibration.py`，输出 `results/calibration.txt`）

repro 的「同时」是 asyncio.gather，记录的 t 是 UI 动作结束时刻而非 commit 时刻，故 commit 间隔 G=(tA−tB)−δ+ε，δ（title 动作 vs desc 动作的系统偏移）与 ε（σ=0.03 s 假设）是未知量。对 10 个双用户场景做最大似然拟合 (L0, r, δ)：
* 最优：**L0=45 ms，r=25 ms，δ=300 ms**；r 的 95% 轮廓区间 15–35 ms（σ=0.03）。**对 σ 敏感**：σ=0.01 → r=65 ms (45–80)，σ=0.06 → r=35 ms (10–70)，L0 在 45–135 ms 之间摆动。结论：r≈15–80 ms，L0+r（同寄存器窗口）≈70–170 ms；n=20/场景，区间很宽，且 r 与 δ 只能联合约束。默认 r=50 ms 与之相容；500 节点图上的真实 r 可能更大（S1NR 即 250 ms 压力）。
* 逐场景（观测 k/n，Clopper-Pearson 95%）：S1N 3/20 [3,38]%、S1N-quiet 1/20 [0,25]%（任务书写 1/15，jsonl 实为 1/20）、S1NR 12/20 [36,81]%（模型 10.9 期望）、S1NL 0/20 [0,17]%（模型预测 0：窗口移到 (0.8 s, 0.8 s+r)，观测 gap 仅 0.15–0.4 s——与 M2 一致；但它对「窗口在 [0,r]」这一备择假设只是弱证据：p=0.9²⁰=0.12）。S2O 19/19、S2OL 20/20、S2OM 0/20、S2OS 0/20、S2L 20/20 均与模型一致（S2OM/S2OS 说明窗口 <0.56 s）。
* **不一致/需说明的地方**：(1) **S2（同 title、无延迟）的 0/20 是 harness 标注问题，不是没丢**：每次运行最终只有一个 title 存活；败者的 ack=False（其 tab 在读 ack 时已显示胜者），所以没被计为 LWW_ONE_EDIT_DROPPED。判别统计：「先发的编辑反而胜出」7/20 [15,59]%（若后发者总能看到先发者则应为 0%）⇒ P(|G|<L0)≈70%，与拟合的 L0≈45 ms 吻合；S2O 同样 7/19，S2L 9/20（模型 50%）。即 S2 实际存在 LWW 静默丢弃，只是 harness 无法区分「合法覆盖」与「并发丢弃」。(2) 对 diff 场景，模型只给出一个很窄的窗口，S1NR 的 12/20 是靠 δ=300 ms 的拟合得到的（δ 是自由参数）——**这是校准，不是独立验证**。(3) 没有任何 repro 数据与 M1–M7 矛盾；S1NL 的 0/20 与 S2 的「0/20」都不构成矛盾（后者见 (1)）。

## 5. 主要数值（模型，λ=0.1/s、r=50 ms；括号为整个房间每小时丢失编辑数）

| mix | 单向时延 | N=10 | N=25 | N=50 | N=100 |
|---|---|---|---|---|---|
| (i) disjoint | 50 ms | 0.013% (0/h) | 0.006% (1/h) | 0.003% (1/h) | 0.002% (1/h) |
| (i) disjoint | 400 ms | 0.018% (1/h) | 0.010% (1/h) | 0.008% (1/h) | 0.007% (3/h) |
| (i) disjoint | 2 s | 0.038% (1/h) | 0.032% (3/h) | 0.030% (5/h) | 0.029% (10/h) |
| (ii) 40/30/30 | 50 ms | 0.082% (3/h) | 0.190% (17/h) | 0.377% (68/h) | 0.752% (271/h) |
| (ii) 40/30/30 | 400 ms | 0.306% (11/h) | 0.767% (69/h) | 1.510% (272/h) | 2.886% (1039/h) |
| (ii) 40/30/30 | 2 s | 1.280% (46/h) | 3.091% (278/h) | 5.589% (1006/h) | 9.315% (3353/h) |
| (iii) uniform/500 | 50 ms | 0.030% (1/h) | 0.050% (5/h) | 0.094% (17/h) | 0.185% (66/h) |
| (iii) uniform/500 | 400 ms | 0.088% (3/h) | 0.196% (18/h) | 0.386% (70/h) | 0.766% (276/h) |
| (iii) uniform/500 | 2 s | 0.350% (13/h) | 0.855% (77/h) | 1.681% (303/h) | 3.256% (1172/h) |

(i) 行完全是持久化项（κ、μ 假设）。N=50、400 ms、mix (ii) 的机制分解：同寄存器 1.25%、同节点异字段 0.059%、列表 0.059%、删除 0.136%、持久化 0.008%（合计 1.51%，272/h）——**同寄存器 LWW 占 83%，且与时延成正比（窗口 L+r）；不同字段/列表只与 r 有关**。S1/S2 类场景的 repro 因此在 400 ms 下会「丢 100%」而 r 窗口类只丢 ≲1%。

## 6. difysim 对接（`compare_difysim.py`）

目录 `research/dify-sim`（递归，跳过 node_modules/dist/src/scripts）里的 `*.json/*.jsonl/*.csv` 与 `REPORT.md` 里的 markdown 表，列名宽松匹配（N/users/clients；latency(_ms)；mix/workload；edits/acked/total；lost；loss_rate 可为 `3.2%`）。明确 schema：
```json
{"runs":[{"N":50,"lambda":0.1,"latency_ms":400,"mix":"mixed","edits":120000,"lost":560}]}
```
`latency_ms`=单向 client↔relay 时延（路径 L=2×；若给总路径用 `path_ms`）；`mix`∈disjoint|mixed(40/30/30)|uniform；可选 `r_ms,s,H,p_del`。输出：观测率+CP 95% CI vs 预测（仅碰撞项 / 含持久化项）、z 值、是否被覆盖。已用 /tmp 下伪造文件测试（json + markdown 表），仓库里不放样例。difysim 目录目前已有 `out/equiv/*.json`（`{"out":{"cfg":{users,mix,durationS},"edits":{performed},"lostDisjointEdits","sameValue","diffValue"…}}`），解析器带一个**按字段名猜测含义**的 storm 适配器（lost = lostDisjointEdits.lost+silentOverwritten + sameValue.lost + diffValue.silentOverwrites+lostOther；λ=performed/(durationS·users)；缺时延则用 `--lat-ms`，默认单向 25 ms）。这些运行只有 ~50 个编辑、mix 名 `contended` 与本文 mix 不同，现在的对比没有信息量；等 difysim 给出带 N/时延/丢失的表或上述 schema 的 json 后再看。难点：difysim 若自己实现了 leader 存盘/relay 重启，应对照「含持久化」列；若 mix 定义与本文不同，请带上 s/H。

## 7. 局限（诚实声明）

* 公式描述的是**稳态泊松到达**；实际协作有突发（同一用户连续改同一节点、多人同时讨论同一处）会使碰撞项偏高，本模型未建模。
* mix (ii) 的 s=0.5、H=30、p_del=2%，持久化的 κ=1/4 h、μ=1/30 min 都是**假设**；(i) 行 100% 由 κ、μ 决定。
* 同寄存器项采用「死时间」闭式（x/(1+x)），已对 x≤1.5 的模拟验证；删除率≥5% 时偏高 15–27%（二阶，未建模）。
* 未建模：丢包只会等效增大 L（M7）；列表的 L+r 删除/编辑变体、索引移位使被删项复活；Dify 的 collab 侧还有边（edges）与 `data` 子容器等，未纳入；同一用户的多标签；undo/redo。
* 校准：n=20/场景，区间宽；δ 与 r 联合约束；S2 的 harness 标注无法区分合法覆盖与并发丢弃。
