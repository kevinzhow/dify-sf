## 7. 典型失败轨迹（可复现；`CAL=1 npx tsx src/trace.ts <场景> <指标> <最大seed>` 打印最小失败 seed 的事件时间线，虚拟毫秒）

**T1　S1N，seed=2（校准档）——"改不同字段也丢"。** B 在 0 ms 改描述并广播；A 在 54.9 ms 收到（已进 A 的 CRDT）；58.8 ms A 改标题——此刻 A 的画布还是旧的（描述为空，画布要到 ≥130 ms 的第二个 rAF 才更新）；A 的整节点写入把画布里的旧描述 `""` 写回 CRDT，覆盖了 B 的新描述。最终存档 `title=A-c1, desc=""`。B 的屏幕上描述被悄悄改回去，没有任何提示。

**T2　S2O，seed=1——同对象字段的原子覆盖。** A 加输出变量（0 ms 提交 `var_2`，30 ms 重命名为 `oa`），B 在 88 ms 基于只含 `result` 的 `outputs` 再加 `ob`。`outputs` 是 Loro 里的**一个值**，后写的整个对象胜出，A 的 `oa` 消失；存档 `outputs = [result, ob]`。

**T3　S3C，seed=1——leader 交接后 hash 过期，永久丢。** A(leader)改标题并在 5.0 s 保存（服务端 hash 变了）；9.3 s A 关页，B 成为新 leader，但 B 手里的 hash 还是旧的。12.3 s B 改 c3，17.4 s 保存 → 409 `draft_workflow_not_sync`，`handleRefreshWorkflowDraft(true)` 只刷新 hash 不重试，**这次编辑再没有保存机会**（真实 20/20）。

**T4　S5A，seed=1——leader 关页不 flush。** A 改完 0.5 s 后关页：`visibilitychange→hidden` 先触发，房间里还有 B，`canFlushGraphOnPageClose()` 为假，keepalive 不发；B 屏幕上有这次编辑（CRDT 已到达）但存档没有，之后也没有人会保存（真实 20/20）。

**T5　S8，seed=1——外部写入被覆盖。** 草稿被 API 带 hash 改过；A 的第一次保存 409，只刷新 hash 不刷新画布；9 s 后 A 的第二次保存用新 hash 提交"旧画布"，外部修改被悄悄覆盖（真实 20/20）。

**T6　S6F，seed=1——大图关页。** 100 节点图 + 选中标记 ≈ 73 KB，超过 fetch keepalive 的 64 KiB，`postWithKeepalive` 的异常被 `.catch(() => {})` 吞掉。

时间线原文：`out/traces.txt`。

## 8. 复现命令

```bash
cd research/dify-sim
export PATH=$PWD/.toolchain/node-v22.23.3-linux-x64/bin:$PATH      # Node 22.23.3（本目录内）
node build.mjs                                                      # 打包真实 Dify 代码（务必在改 shims 后重跑）
npx tsx src/cli.ts sseries --runs 60 --out out/sseries.json             # S 系列（理想档）
npx tsx src/cli.ts sseries --runs 120 --calib --out out/sseries-calib.json   # 校准档
npx tsx src/cli.ts catalog-yaml && npx tsx src/cli.ts catalog --runs 30      # A 层目录
npx tsx src/cli.ts storm --users 25 --duration 120 --mix contended --seed 1 [--focus 40] [--rafdist out/rafdist_dom.json --panellag 30]
USERS="10 25 50" SEEDS=1 PAR=3 DUR=120 scripts/ladder.sh          # 风暴梯度（结果在 out/storm/*.json）
SIM_FAST=off npx tsx src/cli.ts digests --runs 6 --out a.txt; npx tsx src/cli.ts digests --runs 6 --out b.txt; cmp a.txt b.txt   # 逐位等价
node scripts/delta-equiv.mjs                                        # delta 线格式 == 整库导入
CAL=1 npx tsx src/trace.ts S1N M1 300                               # 最小失败 seed 的事件时间线
# 校准（需要本机 Dify + repro 的 venv；≤4 个浏览器会话）
calib/record.py s1n|s2o|s2 --runs N --out calib/data/x.jsonl [--fast --gap MS --agap MS --lat MS]
npx tsx src/cli.ts calib-replay --in calib/data/s1n_lat0.jsonl --k 30 [--rafdist out/rafdist_dom.json]
python3 scripts/real_vs_sim.py; python3 scripts/calib_table.py; python3 scripts/storm_table.py
```

## 9. 实测 vs 推断（汇总）

| 实测 | 推断 / 假设 |
|---|---|
| 真实 Dify 代码在模拟器里的全部行为；`unique_hash` 与真实服务器 15/15 一致；ReactFlow `setNodes` 无效路径（读 `@reactflow/core@11.11.4` 源码）；Loro 对相同值去重（微基准）；整库 export/import 的耗时与内存泄漏（微基准）；真实浏览器内 rAF / DOM 延迟分布、A→B 端到端延迟分布；真实浏览器各场景发生率（repro 20 轮 + 本次 133 轮录制） | 100 人的客户端 CPU 饱和与服务端带宽（未建模，只能推断：约 67 次更新/秒 × 约 15–30 ms/次解码导入 ≥ 100% 单核）；"1.2 GB/标签页"来自 Loro 泄漏的说法；校准分布在其他机器 / 负载下的取值；SPA 卸载路径；面板 inputs 精确过期窗口 |
