# MacToolbox

原生 macOS 菜单栏工具箱，目前包含三个工具：**任意应用的悬停切窗**、**临时文件口袋**和**Anthropic 中转接口（RelayBridge）**。功能入口收在同一个菜单栏图标里，设置集中在一个独立窗口，不额外开主窗口。

为兼容现有辅助功能授权，应用内部 Bundle ID `com.zijin.FinderHoverPrototype` 和可执行文件名 `FinderHover` 保持不变；系统显示名称和发布包名称为“MacToolbox”。

## 设置窗口

菜单栏图标 →“打开设置…”（⌘,）打开，左侧五页：

- **权限**：辅助功能状态、三步引导、“打开辅助功能设置 / 在访达中显示 / 重置权限”。
- **窗口切换**：总开关、面板快捷键，以及每个应用的启用、是否列出最小化窗口、窗口数量上限；底部“添加其他应用…”。
- **临时口袋**：总开关、快捷键、当前数量、打开与清空。
- **中转接口**：配置数量与运行状态，打开 RelayBridge 管理窗口或停止全部代理。
- **外观**：行高、标题字号、宽度上限、最大高度占比、距 Dock 间隙、圆角、玻璃透明度 7 个滑块，加“宽度自适应标题”和“恢复默认外观”。拖动即时作用到面板上。

设置窗口打开期间悬停切窗暂停响应，避免列表面板盖住设置。

窗口本身是一整块 macOS 26 原生玻璃：标题栏、侧栏和内容共用同一块玻璃，页面标题下不再画分隔线；系统开启“降低透明度”时回退为不透明材质。侧栏选中项的文字和图标为白色。菜单栏状态图标使用 template image，选中态和深色菜单栏会自动反色。

## 工具一：悬停切窗（不再限于访达）

把鼠标停在 Dock 的应用图标上，会在图标旁弹出该应用的窗口列表，点击即切换到对应窗口。

- 适用于任意在 Dock 中且正在运行的应用：访达、Word、Excel、PowerPoint、预览、Safari、Chrome、Edge、终端、Xcode 默认开启；Code、备忘录、邮件、飞书、Typora 等已安装但未默认开启，可在设置里勾选。
- 设置 →“窗口切换”可按应用开关；每个应用单独设置是否列出最小化窗口、最多列出多少个窗口，已手动添加的应用可以移除。
- “添加其他应用…”可以选择 `/Applications` 里的任意 `.app`。
- 设置 →“外观”实时调整行高、标题字号、宽度上限、最大高度占比、距 Dock 间隙、圆角和玻璃透明度；“宽度自适应标题”可关闭自适应，“恢复默认外观”一键还原。改动即时生效并写入偏好。
- 自适应无需配置：Dock 在底部/左/右自动识别（读取系统 `com.apple.dock` 方向），面板尺寸受屏幕可视区域约束，多显示器（含负坐标副屏）不会跳到主屏，标题重复时自动加序号，空标题显示“未命名窗口”，对话框、浮动面板、装饰窗口不会出现在列表里。
- 菜单 →“显示当前应用窗口”可不依赖悬停直接列出前台应用的窗口；设置 →“外观”→“预览面板”在未授权时也能查看排版效果。
- 面板快捷键与口袋快捷键相互独立，各自在设置里录入。

## 工具二：临时口袋

- **拖动文件时左右晃动鼠标**，口袋会在光标旁弹出；不松手把文件移进去即可收纳。
- 也可按 `⌥Space` 随时打开，或晃动菜单栏图标两次，或从菜单打开。
- 将文件或图片拖到菜单栏图标或口袋面板中收纳。普通文件保留原位置；剪贴板截图可从口袋中的“收纳剪贴板图片”按钮导入为 PNG。
- 从口袋拖出一个或多个条目时默认复制，条目仍留在口袋中。口袋在应用退出时清空。
- 设置 →“临时口袋”可开关该工具、查看数量、清空，以及录入/恢复默认快捷键。

晃动识别只对文件或图片拖拽生效：拖拽文本、拖选内容、拖动窗口边缘不会误触发。跨应用拖拽走的是源应用自己的嵌套事件循环，全局 `mouseDragged` 监听收不到，因此实现为 60Hz 轮询鼠标按键与光标位置，再用与图标晃动相同的方向检测器判定。

口袋不读取微信私有缓存，不需要屏幕录制权限。

## 工具三：中转接口（RelayBridge）

菜单栏 →「中转接口」子菜单，或设置 →「中转接口」→「打开中转接口…」。

- 管理多个 Anthropic Messages 中转接口：每个接口使用独立本机端口，可分别启动、停止和测试。
- 上游请求强制非流式，代理重建 Claude Code / Claude Desktop 需要的 SSE 事件；支持通用模式和 justwoker 工具兼容模式。
- 支持从 CC Switch 导入 Claude Desktop 供应商；导入后默认为通用模式，需要时手动切换 justwoker 工具兼容。配置在 `~/Library/Application Support/RelayBridge/profiles.json`。
- **默认不读取钥匙串**，只使用客户端发送的密钥；需要备用密钥时在管理窗口打开「读取钥匙串备用密钥」。不开启时不会触发钥匙串权限询问。
- 关闭管理窗口后代理继续运行；可从菜单停止全部代理，退出 MacToolbox 会停止它启动的代理。
- 运行时需要 Python 3（优先 Anaconda、Homebrew，最后系统 Python）；`bridge.py` 与 `justwoker_compat.py` 已随应用打包。
- 默认模板不预置上游地址，第一次新建/编辑接口时必须自行填写。仅提供 Anthropic Messages 协议，不转换 OpenAI / Gemini。使用前请退出独立的 `RelayBridge.app`，避免同一端口被占用。
- `justwoker_compat.py` 来自 Fanorisky/unstream-proxy 的 `88cced9e46c0fa8ad4a8714dd80cc3a8bcaa3fe4`；仅删除默认 `target_url`，保留原实现，并只在 justwoker 模式加载。

## 辅助功能权限

真实悬停、读取和切换窗口需要在**系统设置 → 隐私与安全性 → 辅助功能**中授权“MacToolbox”。未授权时设置窗口、外观、预览和口袋都可用，只有真实窗口切换不可用。

首次启动且未授权时会自动弹出引导窗口（只弹一次，之后从菜单“开启辅助功能权限…”打开）。它做四件事：

1. 先调 `AXIsProcessTrustedWithOptions` 让应用出现在系统列表里，再一键跳到辅助功能面板；
2. “在访达中显示”定位到应用本体，可直接拖进列表；
3. 每 0.6 秒检测一次真实状态，开关打开后自动变成“已授权”并关闭窗口，无需重启；
4. 检测是否运行在 `/AppTranslocation/` 下（直接从 DMG 打开的情况），并提示先把应用拖到“应用程序”文件夹——否则授权会绑定到临时路径，退出后失效。

“重置权限”调用 `tccutil reset Accessibility <bundleID>`，用于修复列表里条目卡住、开关变灰。

辅助功能授权**按应用路径记录**。如果机器上存在多份副本（例如同时有 `build/FinderHover.app` 和 `/Applications/MacToolbox.app`），只有当前正在运行那一份的开关有效——拨另一份的开关不会有任何效果。引导窗口会显示「当前程序」的完整路径，并列出检测到的其他副本。

系统不允许任何进程写入 TCC 授权库，所以不存在“拖进去就自动授权”的接口；能自动化的是引导、状态检测和失效恢复，不是授权本身。

## 代码签名

辅助功能授权按**签名身份**记录。ad-hoc 签名没有身份，系统只能记住二进制哈希，所以每次重编译都会让已授权条目失效。换成一个真实证书后，身份固定，重编译不再影响授权。

`build.sh` 依次查找以下签名身份，找到就用，找不到才回退 ad-hoc 并打印警告：

1. 环境变量 `MACTOOLBOX_SIGN_IDENTITY` 指定的名称
2. `MacToolbox Local Signing`
3. `Apple Development`

### 方案 A：自签证书（不需要 Apple 账号）

如果「证书助理」菜单找不到，它其实是独立程序，可以直接打开：

```bash
open "/System/Library/CoreServices/Certificate Assistant.app"
```

也可以完全用命令行建（本机已按此方式配置好）：

```bash
openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 3650 -nodes \
  -subj "/CN=MacToolbox Local Signing" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  -addext "basicConstraints=critical,CA:false"
openssl pkcs12 -export -out identity.p12 -inkey key.pem -in cert.pem -passout pass:macbox \
  -name "MacToolbox Local Signing" -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1
security import identity.p12 -k ~/Library/Keychains/login.keychain-db -P macbox \
  -T /usr/bin/codesign -T /usr/bin/security
security add-trusted-cert -r trustRoot -p codeSign \
  -k ~/Library/Keychains/login.keychain-db cert.pem
```

导出 p12 时必须指定 `PBE-SHA1-3DES` 和 `macalg sha1`，否则 OpenSSL 3 的默认算法会让 `security import` 报 “MAC verification failed”。

GUI 方式：钥匙串访问 → 菜单「证书助理」→「创建证书…」，名称填 `MacToolbox Local Signing`，身份类型选「自签名根证书」，证书类型选「代码签名」；创建后双击证书 →「信任」→「代码签名」设为「始终信任」。

### 方案 B：Apple Development（需要 Apple ID）

Xcode → Settings（⌘,）→ Accounts → 左下角「+」→ Apple ID 登录 → 选中账号 → 右下角「Manage Certificates…」→ 左下角「+」→ Apple Development。这个按钮只在登录账号后出现。

两种方案都只解决本机授权稳定性：发给别人时仍会触发 Gatekeeper 的“未识别开发者”提示，也不能上架 App Store 或做公证。

建好证书后运行 `./build.sh --install`，再在系统设置里授权一次即可；此后重编译不用再动开关。

**注意**：GitHub Actions 上没有这张证书，Release 里的 DMG 是 ad-hoc 签名的。如果你把 Release 包下载回来覆盖本地安装，等于把证书签名版本换成了 ad-hoc 版本，之前授予的辅助功能权限会立刻失效。自己日常使用请用 `./build.sh --install`；`--diagnose` 的 `signature` 字段会直接显示当前副本是 `adhoc` 还是 `certificate`。

## 图标

图标由 `tools/IconRenderer.swift` 用 Core Graphics 直接绘制，不依赖外部素材，任意尺寸都是矢量渲染而不是缩放位图：

```bash
xcrun swiftc -O tools/IconRenderer.swift -framework AppKit -o /tmp/render
for spec in "16:icon_16x16" "32:icon_16x16@2x" "32:icon_32x32" "64:icon_32x32@2x" \
            "128:icon_128x128" "256:icon_128x128@2x" "256:icon_256x256" \
            "512:icon_256x256@2x" "512:icon_512x512" "1024:icon_512x512@2x"; do
    /tmp/render stack "${spec%%:*}" "Assets/AppIcon.iconset/${spec##*:}.png"
done
iconutil -c icns Assets/AppIcon.iconset -o Assets/AppIcon.icns
```

渲染器支持三种方案：`stack`（叠放窗口，当前采用）、`panel`（列表面板）、`dock`（Dock 与窗口）。三者的预览图在 `Assets/icon-concepts/`。

## 发布

当前版本 `0.5.0`。打包脚本生成 `MacToolbox-0.5.0.dmg`，内部应用显示名称为“MacToolbox”。

## 构建

需要 macOS 与 Xcode 命令行工具：

```bash
./build.sh              # 只构建到 build/FinderHover.app
./build.sh --install    # 构建并安装到 /Applications/MacToolbox.app
./test.sh
```

建议只保留一个安装位置（`/Applications/MacToolbox.app`），并用 `--install` 更新它。辅助功能按路径和签名身份授权：用证书签名时重装不受影响；回退到 ad-hoc 时每次重装都要重新打开一次开关。

`./test.sh` 会重新构建应用并跑离线验证：几何与状态机 23 项、口袋 34 项、快捷键 23 项、通用模型与偏好 70 项、RelayBridge Python 协议 10 项，再加浅色/深色面板渲染、设置窗口五页浅/深色渲染、权限引导浅/深色渲染、设置窗口玻璃材质自检、菜单栏模板图标自检、中转接口菜单与窗口自检、菜单与设置结构自检、诊断报告。真机悬停/切换只在已授权时有效，否则诊断输出 `accessibilityTrusted=false` 并标记 BLOCKED。

`./test.sh --integration` 会额外尝试真实 Dock 悬停与窗口切换（需要辅助功能授权）。

本地生成 DMG：

```bash
./package-dmg.sh
```

GitHub Actions 对匹配 `v*.*.*` 的 tag 自动构建发布包。
