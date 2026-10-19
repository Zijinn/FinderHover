# 访达悬停原型测试计划

## 目标
在 macOS 27 上实现原生菜单栏工具：悬停 Dock 访达图标显示竖排窗口名称列表，点击聚焦对应窗口。

## 阶段
1. 环境与目录检查：已完成（空目录；macOS 27.0.1；Swift 6.4；macOS 27 SDK）。
2. 原型实现：已完成。
3. 编译、逻辑测试、界面预览与权限诊断：已完成。23 项逻辑测试、浅深色原生玻璃布局和动画中断测试通过；真实交互因未授权暂缓，未宣称通过。
4. macOS 27 液态玻璃优化：已完成（用户追加要求）；NSGlassEffectView 和 macOS 27 effectIsInteractive 均在两种外观的实际 app 中验证启用。
5. 测试结果与使用说明：已完成；README.md、测试报告.md 与 TestResults/ 已交付。

## 边界
仅访达；窗口级别，不拆分标签页；不采集截图、不使用私有 API、不修改 Dock 配置。
真实窗口读取/切换依赖用户手动授权辅助功能；不可代替用户更改权限。
所有文件写入本目录，临时文件置于会话 scratch。保留任何非本任务文件。

## 错误与阻塞
- 首次打包：Swift 编译通过；codesign --verify --strict 失败，Contents 根目录标记文件被当成未签名子组件。已将标记移至 Contents/Resources，重新签名和 strict 校验通过。
- 实际 app 诊断：accessibilityTrusted=false。真实窗口读取、悬停与切换测试待用户手动授权，不能把 0 个窗口视为真实窗口结果。


## 透明度追加调整（0.2.1）
- 用户要求玻璃更透明；将原生 regular 改为 clear，开启减少透明度时使用 regular。
- 不降低整个面板的不透明度，保留文字和图标；布局与窗口交互不变。
- 已完成：Swift 编译与签名、23 项逻辑测试、浅深色 clear 材质与布局、动画中断测试通过。新版预览已启动，README 与测试报告已更新。真实交互仍未授权，未执行。


## Dock 通透感调整（0.2.2）
- 用户连续反馈 clear 材质仍显厚重，改为背景玻璃和前景内容分离，单独降低背景不透明度。
- 原生 API 未提供 Dock 的透明度参数；截图权限预检为 false，不能读取 Dock 实际像素，不能声称精确匹配。
- 系统减少透明度和增强对比度均为 false。
- 将验证缓存透明像素、前景不透明度、布局和动画，不申请新系统权限。
- 首轮分层测试：NSView 背景 alpha=0.12，但缓存背景 alpha 仍为 1，像素测试失败。不能仅凭配置宣称透明度已改好。
- 调整实现：后景与前景使用联动的独立窗口，通过 NSWindow alphaValue 控制玻璃后景，并验证明确合成的像素结果。
- 环境错误：rg 未安装，已改用 grep；Swift 编译与 23 项逻辑测试已通过。
- 第二轮：联动窗口的前景空白缓存 alpha=0、图标 alpha=1、位置与穿透检查正常；原生动态玻璃未进入视图缓存，后景缓存 alpha=0，非空后景断言失败。
- 不把动态玻璃缓存当成桌面像素；改为检查本应用 WindowServer 后景透明度，保留前景透明像素与图标不透明像素断言。
- 第三轮：WindowServer 已返回默认背景 alpha=0.28；即时修改到 0.12 后同一轮 run loop 读取仍是旧 0.28，异步更新导致实时调整断言失败。测试改为等待下一轮显示更新后读取，不能直接同步读新值。
- 状态：已完成。编译、脚本语法、严格签名、23 项逻辑、浅深色布局、前景像素、联动窗口和背景实时调节测试通过；WindowServer 实测默认 0.28、实时修改 0.12。文档与报告更新，新版预览已启动。精确 Dock 对照与真实窗口切换分别受截图/辅助功能未授权限制。


## 首次真实交互测试
- 辅助功能已确认生效：accessibilityTrusted=true。
- 真实 Dock 访达识别通过：dockFinderItemFound=true；读取 8 个 Finder 窗口通过。
- 悬停显示真实窗口列表、移入列表保持显示、点击后激活 Finder 且选中窗口为 main 均通过。
- 首次自动化测试的“离开后收起”断言失败：测试移出点仍靠近面板边缘，先修正测试移出到屏幕中央再重测；这不是对用户行为的最终失败结论。


## 授权复核与签名限制
- 首次复核当前二进制：accessibilityTrusted=true、dockFinderItemFound=true、可读取 8 个真实 Finder 窗口。
- 首轮真实测试：悬停显示、移入保持、选中后 Finder 前台及目标窗口为 main 全部通过；收起断言测试点不可靠，正在修正。
- 为修正测试移出位置而重编译后，macOS 对本地 ad-hoc 签名副本撤销了 AX 授权。新二进制的集成测试明确 blocked=true；真实悬停本身之前已通过，收起步骤尚未成功重测。
- 当前需用户把同一完整路径的当前 FinderHover.app 再次添加到“隐私与安全性 → 辅助功能”；重新授权后不再重编译，再运行测试。正式版本应使用固定 Developer ID 签名，避免此问题。


## Dock 放大命中修复（待编译）
- 当前 AX 授权有效，读取 Dock Finder 和 8 个窗口正常。
- 自动化悬停在固定坐标下不稳定；原因是 Dock 放大时 Finder 图标 AX frame 会随着光标重新布局，单纯 `AXUIElementCopyElementAtPosition` 可能错过。
- 修复方案：悬停轮询优先使用当前点命中，失败时回退遍历 Dock 元素树定位 Finder；集成测试使用 CGWarpMouseCursorPosition。
- 重新编译将生成新的 ad-hoc code hash，macOS 可能要求重新添加辅助功能权限。


## 透明度 0–100% 调整（0.2.3）
- 用户明确要求透明度取值完整 0–100%。改用透明度正向语义：0%=不透明、100%=完全透明；默认72%对应原 alpha 0.28。
- 新偏好 `glassTransparency`；兼容旧 `glassBackgroundStrength`，避免用户升级后视觉骤变。
- 动画测试改测边界 0/100 和 88% 中间值；完成编译与回归前状态为进行中。


## GitHub 构建错误修复
- 用户提供的 Actions 日志显示 `NSGlassEffectView` 在 `macos-14` runner 上不可用。
- 原因：代码依赖 macOS 26 AppKit SDK，但 workflow 使用 macOS 14 runner，同时 target/最低系统版本仍为 13.0。
- 修复：workflow 改为 `macos-26`；Swift target 和 `LSMinimumSystemVersion` 改为 26.0；重新推送 main 和重建 v0.0.1 标签。
- 按用户要求未执行本地构建验证；仅做文本、diff 和 Git 引用核对。


## 第二次 GitHub 构建错误修复
- 日志显示 macOS 26 SDK 不包含 Swift 属性 `effectIsInteractive`，尽管头文件存在该 API 注释。
- 已删除该不可用属性调用，保留 `NSGlassEffectView`、clear/regular 材质和透明度窗口合成。
- 按用户要求未执行本地构建；仅修改源码/文档、检查 diff 后推送。
## 临时口袋功能（2026-10-11）
- 目标：按 `.pi/goal/为-finderhover-增加临时文件口袋-20261011-1455.md` 增加会话级文件/图片口袋，不改变 Finder 悬停切窗。
- 阶段：1) 核对菜单栏 hit/drop API；2) 新增存储、手势、面板与拖放；3) 集成菜单栏并保留旧菜单；4) 测试、构建、签名和验收。
- 当前状态：所有实现阶段完成；原有 Finder 逻辑保留，菜单栏口袋入口、摇晃触发、拖入/复制拖出、剪贴板图片导入和会话清理已实现。
- 验证：`./build.sh` 通过（Swift 编译、plist lint、ad-hoc strict 签名）；`./test.sh` 全通过：23 原逻辑、22 口袋、浅深色玻璃布局、透明度及动画。
- 真实 Finder 集成因当前辅助功能 `accessibilityTrusted=false` 被诊断脚本明确 BLOCKED；未模拟或声称通过。
## Mac工具箱更名与快捷键（2026-10-11）
- 用户可见名称改为“Mac工具箱”；保留 `com.zijin.FinderHoverPrototype` 和 `FinderHover` 可执行文件，避免现有辅助功能授权与内部兼容性被无谓破坏。
- 构建产物、DMG、README、菜单、权限提示和诊断文件名同步使用“Mac工具箱”。
- 默认全局快捷键为 `⌥Space`；支持菜单打开录入窗口、保存自定义组合键、恢复默认值。快捷键使用公开 `NSEvent` global/local keyDown monitor，不新增系统权限声明。
- 本阶段状态：已完成方案核对，尚未开始源码修改。
## Mac工具箱更名与快捷键完成
- 用户可见名称、Info.plist 显示名、README、退出菜单、诊断文件名、DMG 卷名和 GitHub workflow 名称已改为“Mac工具箱”。内部 `FinderHover` executable/Bundle ID 保留以兼容已有辅助功能授权。
- 默认全局快捷键为 `⌥Space`，使用 Carbon Hot Key API；菜单支持录入自定义组合键和恢复默认，快捷键写入 UserDefaults。
- 修复并保留原有窗口面板动画重开和玻璃背景 alpha 行为。
- `./build.sh`、`./test.sh`、strict codesign、脚本语法和 diff 检查通过：23 原逻辑、22 口袋、4 快捷键专项测试。
- 真实 Finder/Dock 诊断仍因 `accessibilityTrusted=false` 明确 BLOCKED；快捷键逻辑和用户可见录入流程未做真实桌面 GUI 操作验证。
## 0.2.0 发布准备
- 版本号更新为 `0.2.0` / Bundle build `20`；README 与 DMG 名称同步。
- 远端 `origin/main` 已 fetch，当前无远端领先提交；`v0.2.0` 尚不存在。
- 下一步：构建、测试、提交并推送 `main` 与 `v0.2.0`。

## Mac工具箱通用化 0.3.0（2026-10-17）
- 用户要求：修 bug；悬停切窗从"仅访达"扩展为任意应用（例如 Word）；整体重构为"工具箱"而非单点工具；先复述确认再动手。
- 已确认的范围决定：应用范围=默认常用 + 可勾选增减；"自动调整"=外观可调 + 按应用开关/单独配置 + 环境自适应 + 窗口识别规则自适应；外壳=单图标 + 菜单内扩展；验证=本轮不授权，只跑离线逻辑测试与预览。
- 阶段：1) 契约层 AppModel/SettingsStore；2) 三组并行（口袋摇晃修复、快捷键分角色、面板通用化）；3) AccessibilityService 通用化；4) AppController 菜单外壳；5) 脚本/测试/文档/版本。
- 状态：1–5 全部完成。`./build.sh`、`./test.sh`（23+28+23+70 项逻辑与新增菜单自检、浅深色渲染、动画、按应用诊断，退出码 0）、`./package-dmg.sh` 通过；`accessibilityTrusted=false`，真实悬停/聚焦保持 BLOCKED，未声称通过。
- 下一步（需要用户）：重新授权后运行 `./test.sh --integration`，用真实 Dock 数据复核分类与窗口读取；若第三方应用的子角色异常，再按实测收紧排除列表。
- 干净重跑暴露的取样缺陷：前景 alpha 采样点落在行内，物理光标悬在预览上时会取到 0.07 行高亮。采样点移到行外边距后再次干净重跑通过（156 PASS / 0 FAIL / 退出码 0，浅深色 `cachedForegroundBackgroundAlphaSamples=[0,0,0]`，typecheck 0 警告，DMG 重新生成）。
