# Dify 工作流编辑器「丢改动」复现脚本

被测对象：Dify 1.17.1（tag `1.17.1` = 8387590，官方 `docker/docker-compose.yaml`，`ENABLE_COLLABORATION_MODE=true` 默认开）。
所有东西只跑在本机（nginx 绑定 `127.0.0.1:80`，plugin_daemon 绑定 `127.0.0.1:5003`），账号是一次性的本地账号。

## 目录

| 路径 | 作用 |
|---|---|
| `REPORT.md` | 结论报告（中文）。注意：写文件被执行环境拦截，报告正文随交付消息一并返回，需要调用方自行存为此文件 |
| `scenarios.py` | 浏览器场景（Playwright + 真实 Chromium，真实 Dify Web UI）。一个 run = 新建一个 workflow app → 2~3 个浏览器进程/上下文 → 真实点击/拖拽/输入 → 等 autosave 稳定 → 对比「各端本地看到的」「服务器 draft」 |
| `api_tests.py` | 不开浏览器，直接打 `POST /console/api/apps/{id}/workflows/draft` 等接口，隔离服务端语义 |
| `lib/harness.py` | Playwright 封装：每个 tab 独立浏览器进程；websocket 代理（可注入延迟 / 断网）；hidden 标签页模拟；SIGKILL |
| `lib/difyapi.py` `lib/graphs.py` | 控制台 API 客户端、测试用的 workflow 图（start → c1..c4 → end，Code 节点串联引用） |
| `summarize.py` | 把 `logs/*.jsonl` 汇总成表 |
| `run_all.sh` | 重放全部浏览器场景 |
| `logs/` | 原始日志：每个 run 一行 JSON（编辑列表、服务器最终状态、各 tab 最终状态、每次 draft 保存请求的 hash/状态码、console 错误） |
| `shots/` | 非 OK 的 run 的截图（场景名-run序号-tab） |
| `logs/aborted/` | 早期因机器被其它任务占满 CPU / harness 缺陷而作废的批次，仅留档，不参与统计 |

## 重放

```bash
# 0. 起 Dify（已经起着的话跳过）
cd ../dify-src/docker && docker compose up -d          # 约 1 分钟；本机入口 http://localhost
# 1. 一次性本地账号：alice@example.test / bob@example.test / bob2@example.test，先在本地 Dify 里建好，密码通过环境变量 REPRO_PW_ALICE / REPRO_PW_BOB 传入
#    首次需要：POST /console/api/setup 建 alice，再用邀请接口加 bob、bob2（见 REPORT.md「环境」）

cd ../../repro
uv venv --python 3.12 .venv && uv pip install --python .venv/bin/python requests "python-socketio[client]" aiohttp websocket-client playwright
.venv/bin/playwright install chromium

.venv/bin/python api_tests.py --runs 20                                   # 服务端语义，几秒
.venv/bin/python scenarios.py S5A --runs 20 --parallel 3                  # 单个场景
.venv/bin/python scenarios.py S1,S2,S3C --runs 20 --parallel 3 --tag mine # 多个场景
./run_all.sh                                                              # 全部（约 1.5~2 小时）
.venv/bin/python summarize.py                                             # 汇总
```

关闭协作模式做对照：在 `docker/.env` 里把 `ENABLE_COLLABORATION_MODE=false`，`docker compose up -d api worker`，再用 `--tag nocollab` 跑。

## 场景速查（名字 → 做什么）

S1 两人改不同节点；S1L 同上 + 400ms ws 延迟；S1N 同节点不同字段（title vs desc）；S1NL 同上+延迟；S1NR 同上+每帧 rAF 延迟 250ms（模拟卡顿主线程）
S2 同节点同字段；S2L 同上+延迟；S2O 两人给同一 Code 节点各加一个不同的 output；S2OS/S2OM/S2OL 错开 3s / 0.8s / 加延迟
S3A 后台(模拟 hidden)标签回来再编辑；S3B leader 在后台；S3C leader 走后新 leader 手里是旧 hash；S3D 回到前台 0.2s 内编辑
S4A 跟随者断网 12s；S4B 断网后在已聚焦输入框里继续输入；S4C 单人编辑后 2s 断网 8s；S4D leader 静默掉线 60s
S5A leader 编辑后 0.5s 正常关页；S5B leader 编辑后 0.5s 被 SIGKILL；S5C 跟随者编辑后关页，之后 leader 被 SIGKILL；S5D 单人编辑后被 SIGKILL
S6A~E 单人：编辑后 0.3s 关页 / 刷新 / SIGKILL / 整页跳转 / 等 autosave；S6F 100 节点大图编辑后关页；S6G 30 节点对照
S7A 一人删节点另一人改它；S7AL 同上+延迟；S7B 单人删节点（看引用是否残留）
S8 草稿被带 hash 的外部写入改过（API/其它设备），tab 再编辑两次
S9 DSL 导入/版本恢复时广播 `workflow_update`，另一人有 <5s 内未保存的编辑
S10 两个 tab 一直开着，A 编辑并保存后 B 再编辑两次（非并发）

注意：
- hidden 标签页是**模拟**的（覆盖 `document.visibilityState`/`hidden`、派发 `visibilitychange`、暂停 rAF），不是真的被操作系统挂起的后台标签。
- 延迟 / 断网是在 Playwright `route_web_socket` 上做的 socket.io 代理，HTTP 请求不受影响（HTTP 断网用 `context.set_offline`）。
- 这台机器在跑批期间曾被另一个任务占满 CPU（load 12~35），受影响的批次已放进 `logs/aborted/` 重跑。
