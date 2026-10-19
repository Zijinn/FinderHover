# 环境与技术发现

- 指定目录原本为空。
- 实测 macOS 27.0.1 (26A434)，Apple Silicon；Swift 6.4；Xcode macOS 27.0 SDK。
- Finder 与 Dock 正在运行。
- 采用 Swift + AppKit、Accessibility API、非激活 NSPanel、NSVisualEffectView。
- AX 坐标为主屏左上原点；AppKit 为主屏左下原点，须转换并覆盖副屏负坐标测试。
- 以 AX Dock item 的 Finder.app URL / 应用名称识别，不使用固定屏幕坐标。
- 面板展示不激活自身；点击条目才激活并聚焦 Finder。

## macOS 27 原生液态玻璃
- 实际读取 macOS 27 AppKit SDK 的 NSGlassEffectView.h：NSGlassEffectView 自 macOS 26 提供 regular/clear 样式、cornerRadius、contentView；macOS 27 新增 effectIsInteractive。
- 必须通过 contentView 嵌入内容，不能依赖任意 subview 的渲染层级。
- 本次优化使用单层 regular 原生玻璃，启用 27 原生交互反馈；不用自制模糊或多层叠加玻璃。
- 用户本轮优先要求视觉优化，未确认辅助功能授权；真实交互测试仍不能视为通过。

## 最终验证
- 0.2.0 两种外观的元数据均为 nativeLiquidGlass=true、macOS27InteractiveGlass=true。
- app 实际运行、视图缓存渲染和动画中断测试通过；未做桌面截图级视觉一致性判断。
- 最终权限诊断依然 accessibilityTrusted=false；用户仍需授权才能验证真实交互。

## 0.2.1 透明度调整
- regular 改为 clear；系统减少透明度开启时选择 regular，不降低整窗不透明度。
- 本机两种外观运行时均为 glassStyle=clear；布局和动画回归通过。未做桌面截图级透明度测量。

## 0.2.2 Dock 通透感修正
- clear 材质不是透明度参数；Dock 未提供可复制的公开材质参数。当前截图预检 false，未获取 Dock 实际像素。
- 普通 NSView alpha + 原生玻璃缓存无法验证实际透明度；改为两个联动 NSPanel，后景独立窗口 alpha，前景无底色。
- 动态原生玻璃不进入缓存；不要用缓存背景 alpha 来断言屏幕材质。前景空白缓存 alpha=0，图标 alpha=1。
- 本应用 WindowServer 信息确认默认 0.28、调节后 0.12；窗口 alpha 修改异步，需要返回 run loop 后再验证。
- 菜单栏玻璃底色滑块 8%–65%，默认 28%，保存用户选择；百分比不是 Dock 实测值。

## 0.2.3 透明度语义
- 滑块改为透明度 0–100%：`backgroundPanel.alpha = 1 - transparency/100`。默认无历史偏好为 72%，即 alpha 0.28。
- 旧 `glassBackgroundStrength` 仍可读取并换算为透明度；新值保存为 `glassTransparency`。
- 实测透明度 88% 时 WindowServer alpha=0.12；文字和图标保持不透明。
## 临时口袋实现核对（2026-10-11）
- 产品目标明确：口袋与既有 Finder 窗口列表并存，不能替代或改变现有交互。
- 普通文件应以 URL 引用留在会话内；收纳过程仅接受拖放数据，不执行文件移动/改名/复制；拖出声明 `.copy`。
- 剪贴板图片经 NSPasteboard 公共图像类型转换并写入临时目录 PNG；结束时清理由进程拥有的临时文件。
- 口袋暂不持久化普通文件条目：这是明确的会话级生命周期；清空/退出只删除本 Store 创建的临时图片，不触碰用户文件。
- macOS 26 SDK 中无法编译 Swift `NSGlassEffectView.effectIsInteractive` 属性；测试现在核验实际公开材质实现，不再要求不可用属性为真。
- 状态栏图标的手势 hit rect 必须向外扩张；使用负值 `insetBy` 扩展命中面积，不能向内缩小 28×22 pt 状态项区域。
## Mac工具箱更名与快捷键（待实现）
- 决策：用户可见名称和发布产物改为“Mac工具箱”；内部 Bundle ID/可执行文件保留以降低辅助功能授权回归风险。
- 快捷键：默认 `⌥Space`，UserDefaults 持久化，自定义录入窗口捕获组合键，菜单支持恢复默认。
## Mac工具箱更名与快捷键结论
- 用户可见名称使用 `CFBundleDisplayName/CFBundleName = Mac工具箱`；`CFBundleExecutable` 和 Bundle ID 保留 FinderHover 兼容路径。
- Carbon `RegisterEventHotKey` 可在当前 macOS SDK 下 Swift 5 typecheck；默认 Option-Space，自定义快捷键必须含 modifier，冲突时保留原值并提示。
- 状态栏/口袋快捷键入口不新增辅助功能或屏幕录制权限；真实 Finder 交互权限仍独立存在。
- WindowListPanel 的重开时序测试在更名改动后暴露 alpha 回归，已修复为淡出中重开时显式恢复背景 alpha，并重新通过完整测试。
## 通用工具箱改造（2026-10-17）
- 本机当前 `AXIsProcessTrusted()=false`，无法实测 Dock 元素的真实 AX 数据。分类规则因此只使用 SDK 头文件 `AXRoleConstants.h` 中已声明的常量，并采用"排除法"：先排除分隔符/废纸篓/stack/文档/URL/最小化窗口堆/extra，再用 `bundleIdentifier` 或 `.app` URL 后缀判定应用，最后回退 `kAXApplicationDockItemSubrole`。不虚构字符串。
- 历史事实：0.2.x 期间用户曾授权成功，实测 `dockFinderItemFound=true` 并读取 8 个真实访达窗口、悬停与点击切换均通过。ad-hoc 重编译会撤销授权，因此本轮"不授权"意味着通用化后的真实交互完全未回归，只能声称离线规则与渲染通过。
- `NSStatusItem`/`NSMenu` 的自检坑：给父项赋值 `submenu` 后 AppKit 会把父项 `action` 设成私有 `submenuAction:`，`responds(to:)` 返回 false。菜单自检必须跳过带 submenu 的项，否则 17 个假阳性。
- 面板宽度必须 `ceil` 到整点：布局算出 247.29 pt，而窗口框落在 248 pt，导致"重新按标题测宽再断言布局"的 `metricsAppliedToLayout` 永远为 false。断言与布局必须使用同一种取整。
- `PocketStore.onChange` 是单槽回调且已被 `PocketPanel` 占用（`store.onChange = reload`），徽标更新链路是 store → reload → onCountChanged → statusView。因此 `PocketPanel.onItemsAdded/onClear` 是从未被赋值的死代码，已删除。
- Swift 惯用法：`kAXFoo as String` 只在 switch 模式位置报 "'as' test is always true"，在表达式/初始化位置干净。已改为 `AXRoleName/AXSubroleName` 常量，规则里做纯 String 比较。
- 撤回的初审误判（避免再次误报）：`PocketStore.addPasteboard` 确实会在没有 URL 时回退 `addImageFromPasteboard`，图片拖入不是 bug；`tick()` 的 `lastHit` 已有 `time - lastDockQuery < 0.4` 守卫，不是陈旧命中 bug。本轮真正的行为 bug 只有摇晃检测（拖拽运动喂给检测器、混用 `event.timestamp` 与系统时钟、拖放完成复用 `onShake`）。
- 目录里的 bundle id 必须实测校验：本机 `mdfind` 确认 15/19 个条目真实安装（含 Code、备忘录、邮件、飞书、Typora）；`com.apple.mobilenotes` 与 `com.apple.Notes` 重复，已删除；`com.MacPaw.CotEDITOR` 是编造值，正确为 `com.coteditor.CotEditor`。
