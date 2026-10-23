# Android Web 支持

本轮目标是 Android Web 浏览器中的编辑器与应用入口，不包含原生 APK。桌面鼠标、键盘和触控板沿用原有输入方式。

## 触摸约定

- 双指在画布上缩放并平移，缩放范围 25%–200%，双指中心下的内容保持锚定。
- 空白处单指平移；节点上单指拖动；从输出端口拖至目标节点连线。
- 第二根手指加入时终止当前单指操作，取消连线预览；缩放后剩余的一根手指不会误拖节点，全部抬起后可重新开始。
- 系统取消触摸不算完成连线。已实际移动的节点仍按原有协作保存和撤销语义收尾。
- 开始节点的变量列表普通滑动用于滚动，长按变量行后可排序；鼠标仍可直接拖动排序。
- 长按打开已有 Dify 菜单；空白处双击放大。嵌入文本编辑器、滚动区域与控件优先处理自己的手势。

## 紧凑布局

- 窄屏沿用 Dify 左侧 64px 收起栏，展开为覆盖式导航；不修改桌面侧栏偏好。
- 编辑器顶部保持 Dify 原有 56px 单行和操作分组顺序，空间不足时横向访问完整工具栏。底部操作根据实际可用宽度换行。
- 节点、运行、变量和评论面板以扣除侧栏后的实际可用宽度为上限。多个面板可横向滑动访问，桌面保存宽度不被手机尺寸覆盖。
- 页面考虑安全区域；对话框、抽屉与编辑面板避让软键盘。切换横竖屏后重新布局。

## 验证口径

触摸验证使用正式 Dart Wasm/skwasm 构建、Chromium 的 Android 视口和可信多点触摸事件，结合真实 HTTP、独立 PostgreSQL 与持久化结果；这与真实手机、TalkBack、厂商浏览器或 iOS Safari 验证不同。不能把浏览器仿真写成所有设备均已验收。

回归包含缩放锚点与边界、连续多种手势、取消与手指数变化、拖动的一步撤销、长按菜单、窄屏面板、旋转与键盘，以及桌面选择、焦点、注释编辑与导航。当前用户账号、数据库、上传卷及凭据不用于测试数据重置。

字体按用户指令暂停；本轮不以移动端工作顺带改变字体方案。

## Flutter Web 横向滚动兼容

Flutter 3.47.6 的 Web semantics 同步在横向滚动时也写 `scrollTop`，造成辅助功能 DOM 的纵向坐标偏移。`app/web/semantics_scroll_compat.js` 仅为 Flutter 创建的 semantics 元素安装局部适配：检测引擎横向 overflow 标记后将这次赋值用于 `scrollLeft`，纵向滚动和普通 DOM 沿用浏览器行为，不关闭辅助功能。没有修改共享 SDK。

来源：[Flutter SemanticScrollable.update](https://github.com/flutter/flutter/blob/5fc346839b5d0eef006ed8404392afb4dfae428d/engine/src/flutter/lib/web_ui/lib/src/engine/semantics/scrollable.dart)。上游按轴同步后，应移除此适配并复跑真实横向手势、发布弹层与纵向面板用例；`tool/verify_semantics_scroll_web.py` 使用 Playwright 检查横向点击目标及纵向行为。

## iOS 26.6+ 的 Web Wasm 选择

只更新 Web 加载器，不修改原生 iOS 项目或要求页面替用户升级系统。iOS／iPadOS 26.6+ 在实际通过 Wasm GC、新异常处理、字符串内建功能的流式编译与调用、WebGL 检测后，默认选择 Dart Wasm/skwasm。Safari 26 的系统 UA 可能冻结在 18.x；优先使用 Safari 的浏览器版本，其他隐去版本的浏览器仍必须通过完整能力检测。低版本或缺少能力时保留 Flutter 的 JavaScript/CanvasKit 兼容路径。

启动到首帧之前的 Wasm 下载、编译或引擎错误会重新打开同一路径并添加 `renderer=canvaskit`；该参数同时提供手动兼容入口，兼容启动失败不会再次尝试 Wasm，因此不会循环刷新。首帧之后的业务异常不触发整页重载。

实现复用 [Flutter 自定义初始化接口](https://docs.flutter.dev/platform-integration/web/initialization)，不改共享 SDK。26.6 的流式编译能力见 [WebKit 发布说明](https://webkit.org/blog/18178/webkit-features-for-safari-26-6/)。Flutter 所引用的 [Canvas 复制性能问题](https://bugs.webkit.org/show_bug.cgi?id=267291) 仍需留意；启用 Wasm 不等于已经证明真机不卡。策略单测与真实加载器测试见 [客户端构建说明](client.md)，浏览器身份仿真与实体 iPhone 验收分别记录。
