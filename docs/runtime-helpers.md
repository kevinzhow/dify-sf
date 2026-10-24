# 辅助服务：实现边界与配置

固定参照 Dify 1.17.1，提交 `8387590ace4a094de812b7847fc6a4c3a27cd52b`。
本阶段只补生成器、DSL 导入、TTS 试听和 annotation-only 语义回复；不扩展知识库、插件市场或计费。

## 生成与导入

`/v1/rule-generate`、`rule-code-generate`、`rule-structured-output-generate`、
`instruction-generate`、`workflow-generate` 使用工作区实际安装并配置的模型。
默认取默认 LLM，生成器可选择模型。原版提示词固定到上述来源；prompt 默认三次调用，
`no_variable=true` 只生成提示词。代码、结构化输出、修改和流程分别核验返回格式。
流程生成采用 planner + 逐节点 builder，核验图、端点、容器、节点参数和变量来源；最多 50 节点。
工具目录来自安装插件及已发布工作流，拒绝虚构工具。结果只是建议，用户 Apply 后才走现有协作写入，
期间原文档或节点发生变化会拒绝覆盖。错误保留输入，可重试；共享对话框取消会中断请求。
共享生成器对话框取消会中断请求；原结构化输出弹窗关闭只忽略返回结果。
请求最多 120 秒，文本最多 1 MiB。JSON Schema 校验限当前界面支持的对象／数组子集。
原版复杂工具路由／自动修复、流式进度、富图预览、Cmd-K 建议尚未移植。

DSL 文件沿用选择器、拖放、版本确认和原文档替换规则。`yaml-url` 由服务端经
`COLLAB_SSRF_PROXY_URL` 下载，无代理配置则拒绝；重定向也经过代理，保留私网拒绝和 TLS 校验。
限制 10 MiB、UTF-8、文本／YAML 类型；下载和解析失败不会新建或覆盖文档。

## TTS

默认 TTS 模型提供实际 voice 列表和音频：`GET /v1/apps/{app}/text-to-audio/voices?language=...`
返回原版的列表；`POST .../text-to-audio` 返回真实音频字节与 MIME。
控制台历史消息只能读取当前账号、本应用的消息；不可把其他会话的 message_id 用于合成。
插件分块音频在服务端有界聚合（16 MiB），浏览器使用原生 Audio、Blob URL 播放；停止、关闭面板／编辑器
会中断请求、停止音频并撤销 URL。未实现公开聊天逐块自动播报，不改原生 iOS。

## 标注语义回复

配置 `COLLAB_ANNOTATION_WEAVIATE_URL`，鉴权服务另设 `COLLAB_ANNOTATION_WEAVIATE_KEY`。
可在 runtime 组合上加入 `docker-compose.annotations.yml`，显式设置私有 key；服务不发布主机端口，
关闭匿名访问，以固定镜像和独立持久卷运行。该 key 与向量卷应随备份保留，原 PostgreSQL 卷不换版本。
复用现有插件进程的真实 text-embedding 模型，不采用本地字符串相似度。
固定 Weaviate 1.39.2，使用 self-provided named vector `default`、cosine distance、top1、
`score=1-distance` 和严格 `score > threshold`。特性层原版 `threshold or 1` 也保留，0 等价于 1。
每个应用和索引代次单独集合；返回结果再次校验应用、代次及精确问题，再读取 SQL 最新答案。
命中不执行图节点，不产生虚构 LLM 用量；本地仍保存正常的聊天／运行记录与命中历史。
索引或查询失败按真实状态报错或走普通模型路径，不伪造匹配成功。

启用作业持久化为 waiting/processing/completed/error，每批 16 条、租约 120 秒，服务每 5 秒扫描。
只有全部向量写入成功才 ready。问题新增／修改／删除与 SQL 事务同时使旧代失效；答案修改直接读最新 SQL。
切换模型产生新代，旧工作无法覆盖新结果。删除标注同时清除命中历史。
禁用立即在 SQL 关闭匹配，用户禁用作业随 SQL 完成；向量清理单独持久化，失败 30 秒后重试。
这区别于原版把清理也放在同一个禁用作业中，不把清理失败伪装为已清理。

升级前只有标记、没有真实索引的旧配置保留原始数据，迁移为 needs_rebuild；不会自动调用现有付费模型。
只有用户主动重新启用才排队建索引。当前为单工作区，每应用与 API 访客权限沿已有边界隔离。
