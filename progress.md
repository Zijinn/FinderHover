# 工作记录

## 本次执行
- 已读取 planning-with-files 与 apple-design 技能。
- 完成目录、系统版本、编译器和 Finder/Dock 进程检查。
- 开始实现原型与独立测试；尚未宣称真实悬停或窗口切换已通过。

## 首轮测试
- 原生 app 构建与 strict 签名校验通过。
- 23 项悬停状态机/坐标/屏幕边缘逻辑测试全部通过。
- 原生竖排面板自渲染：720×916，8 行；行布局边界检查通过。此图使用示例数据，不是屏幕录制或真实窗口读取。
- 诊断报告证明 app 尚未获得辅助功能权限；等待用户授权再做真实交互。

## macOS 27 视觉优化与最终检查
- 原生 NSGlassEffectView + effectIsInteractive，版本 0.2.0。
- 浅色/深色均通过 8 行布局检查；300×470 pt，600×940 px。PNG 仅用于视图布局，未采集桌面玻璃折射截图。
- 原生面板淡出中立即重开测试通过（alpha=1），23 项逻辑测试再次通过。
- bash -n、plist、Swift 编译、严格签名校验通过。
- 完成 README.md 和测试报告.md。
- 新版 app 仍未获得辅助功能权限；真实窗口交互暂缓。
- 已启动新版示例预览，启动检查进程 PID=90282；供用户观察实际系统玻璃效果。

## 0.2.1 透明度调整完成
- 编译、严格签名校验、脚本语法、23 项逻辑测试、浅深色 clear 材质/布局和动画测试通过。
- 文档与报告已更新；新版示例预览已启动，PID=13401。
- 辅助功能仍未授权，真实悬停和窗口切换未执行；本轮仅调整透明材质。

## 0.2.2 完成
- 背景/前景使用联动独立窗口；后景忽略鼠标事件，前景文字和图标不跟随变淡。
- 添加玻璃底色实时滑块；上下限测试不写入用户偏好。
- 最终 ./build.sh、./test.sh、bash -n、严格签名校验通过。23 项逻辑测试、浅深色布局、两窗口对齐、动画、前景像素与 WindowServer 透明度通过。
- 默认 WindowServer alpha=0.2800000011920929；实时修改后=0.11999999731779099。
- 原型预览已启动，PID=40512；README 与测试报告已更新。
- 截图权限/辅助功能未授权，未获取 Dock 实际像素，未执行真实访达窗口切换；不宣称外观精确匹配。

## 真实交互复测状态
- 上一次授权下已实测 Dock Finder 识别、8 窗口读取、悬停展开、移入保持、切换 Finder 前台和 main window 均通过。
- 修复收起测试移出点后，为集成脚本重编译触发 ad-hoc 签名身份变化，macOS 撤销当前副本 AX 授权。
- 新构建 23 项逻辑/透明度测试通过；真实集成被权限检查安全阻止，未执行鼠标操作。
- 当前安装路径不变；需重新加回辅助功能后，不再重编译并继续验证。

## 0.2.3 完成
- 透明度滑块和偏好语义已改为 0–100%；README/测试报告已同步。
- bash 语法、Swift 编译、签名、23 项逻辑测试、透明度边界/88%中间值和布局测试通过。
- 0.2.3 预览已启动；重新编译的 ad-hoc app 可能需要重新授权辅助功能。

## 第二次 CI 修复已推送
- GitHub 日志确认 `effectIsInteractive` 在 macOS 26 Swift SDK 中不可用；已移除该属性调用，保留 NSGlassEffectView。
- README 同步改为 NSGlassEffectView 原生玻璃说明。
- main 已推送至 0feebe5，v0.0.1 已强制更新至 5402a27。
- 按用户要求未做本地构建或测试。
## 临时口袋功能实现
- 已载入 planning-with-files 技能并核对主机 goal artifact；当前 `main` 工作树无已跟踪改动，现有未跟踪记录保留。
- 已批准目标：会话生命周期、普通文件只引用、剪贴板图片写入临时 PNG；默认复制拖出；不读微信私有缓存。
- 独立实现代理未落盘文件；按其边界停止后由主会话完成核心模块与集成。未保留并发代理写入。
- 新增 `PocketStore`（文件 URL 引用、standardized URL 去重、剪贴板图像转 PNG、仅清理自身临时图）、`ShakeDetector`、`PocketPanel`、`PocketStatusView`。
- 菜单栏原 NSStatusItem/menu 保留；新增数量徽标、菜单打开/清空、状态栏拖放和图标附近晃动两次打开。
- `./build.sh` 成功：Swift 编译、Info.plist lint、ad-hoc codesign 和 `codesign --verify --deep --strict`。
- `./test.sh` 成功：原逻辑 23 项、口袋 22 项、浅深色布局、动画中断、透明度调节全通过。
- 诊断 `accessibilityTrusted=false`；因此真实 Finder/Dock 集成显示 BLOCKED，没有执行真实窗口操作。
- 回归脚本修正：macOS 26 SDK 不含 `effectIsInteractive` Swift 属性，按当前已采用公开 API 检查 `NSGlassEffectView`，不再强制错误断言交互属性为真。
- 摇晃测试复核发现正例曾依赖上一个样例的状态；改为显式 reset 并验证独立的四段往返。修正后口袋 22 项与完整 `./test.sh` 全通过。
- 已更新 README 使用说明。
## Mac工具箱更名与快捷键完成
- 用户可见名称统一为“Mac工具箱”；内部 FinderHover executable/Bundle ID 保留兼容权限。
- 新增 `Sources/ShortcutManager.swift` 和 `Tests/ShortcutTests.swift`：默认 `⌥Space`、Carbon 全局热键、快捷键录入、自定义持久化、恢复默认。
- 菜单已加入当前快捷键、设置快捷键、恢复默认快捷键；快捷键触发打开临时口袋。
- 构建脚本链接 Carbon；Info.plist、DMG、README、诊断文件、退出菜单和 CI 名称已同步。
- 修复 WindowListPanel 重开淡出中断和原生玻璃背景 alpha；完整 `./test.sh` 通过：23 + 22 + 4 项测试及浅深色/动画/透明度回归。
- strict codesign、脚本语法、diff 检查通过。测试 stderr 仍有环境提示 `sandbox_extension_consume failed: 1`，但脚本退出码为 0。
- 真实 Finder/Dock 集成诊断仍为 `accessibilityTrusted=false`，明确 BLOCKED；未宣称真实交互通过。
## Mac工具箱通用化 0.3.0（2026-10-17）
- 新增 `Sources/AppModel.swift`（Dock 分类、窗口呈现规则、外观指标与夹取、按应用配置、应用目录）和 `Sources/SettingsStore.swift`（工具开关、按应用偏好、自定义应用、外观偏好），作为所有面板与服务共用的纯逻辑契约层。
- `AccessibilityService` 去掉全部访达硬编码：`appItem(at:)`/`appItem(bundleIdentifier:)` 返回 `DockAppHit`，`windows(of:config:)` 走 `WindowPresentationRules` 过滤+排序+截断，`focus(_:in:)` 先激活应用再取消最小化并 raise，诊断改为按应用输出。
- `WindowListPanel` 改为应用无关：`show(windows:context:icon:screen:edge:metrics:preview:message:)`，头部显示应用名与"共 N 个窗口，显示前 M 个"，渲染报告新增 `panelAppName`/`applied*`/`omittedWindowCount`/`switchableWindowCount`/`metricsAppliedToLayout` 及四个子断言位。
- 面板宽度统一 `ceil`，修好 `metricsAppliedToLayout` 的 0.71 pt 恒假问题（浅色预览实测从 False 变 True）。
- 外观 7 个滑块（行高/字号/宽度上限/最大高度占比/距 Dock 间隙/圆角/玻璃底色）+ 宽度自适应开关 + 恢复默认，全部经 `PanelMetrics.clamped()` 落盘，悬停与预览即时生效。
- 每应用子菜单提供启用、列出最小化窗口、窗口数量上限（3/6/9/12/20/40）与移除；自定义应用通过 `NSOpenPanel` 选 `.app` 加入。
- 快捷键拆成每工具独立：口袋保留 `⌥Space` 旧偏好，切窗面板使用新键位，`-1` keyCode 区分"显式清除"与"从未设置"。
- 摇晃检测三处行为 bug 修复：拖拽进入/更新不再喂检测器、统一 `ProcessInfo.systemUptime` 时钟、拖放完成改用独立 `onDropCompleted` 回调。
- 清理死代码：`PocketPanel.onItemsAdded/onClear`、`PocketStatusView.onClick`、`interactiveGlass/macOS27InteractiveGlass`。
- 新增 `Tests/ModelTests.swift` 70 项离线断言；`test.sh` 增加模型测试、`--menu-test` 菜单图自检，并把失效的 `macOS27InteractiveGlass`/`windowCount`/`dockFinderItemFound` 断言换成新的按应用诊断键；构建步骤改为每次强制重建，避免测到旧产物。
- 版本 0.3.0 / build 21；`./build.sh`、`./test.sh`（144 项逻辑断言 + 浅深色渲染 + 菜单自检 + 诊断，156 行 PASS，退出码 0）、`./package-dmg.sh` 生成 `build/Mac工具箱-0.3.0.dmg` 全部通过。
- 真实悬停/聚焦仍为 BLOCKED：`accessibilityTrusted=false`，本轮按用户要求不申请授权。
- 干净重跑（`rm -rf build TestResults`）发现前景 alpha 采样点落在行内、被物理光标触发的 0.07 行高亮污染；三个采样点改到行外边距后再次干净重跑：156 行 PASS、0 FAIL、退出码 0，浅/深色 `cachedForegroundBackgroundAlphaSamples=[0,0,0]`、`metricsAppliedToLayout=true`，全量 typecheck 0 警告，DMG 重新生成。
