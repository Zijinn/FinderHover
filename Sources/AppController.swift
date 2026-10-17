import AppKit
import ApplicationServices

final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let service = AccessibilityService()
    private let windowPanel = WindowListPanel()
    private let pocketStore = PocketStore()
    private lazy var pocketPanel = PocketPanel(store: pocketStore)
    private var pocketStatusView: PocketStatusView?
    private lazy var shortcutManager = ShortcutManager()
    private let settings = SettingsStore()

    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private var metricLabels: [String: NSTextField] = [:]
    private var metricSliderKeys: [MetricSliderKey] = []
    private var timer: Timer?
    private var clickMonitor: Any?
    private var gate = HoverGate()
    private var dockEdge: DockEdge = .bottom
    private var lastDockQuery: TimeInterval = 0
    private var lastPermissionQuery: TimeInterval = 0
    private var lastHit: DockAppHit?
    private var permissionGranted = false
    private var manualDisplayUntil: TimeInterval = 0
    private var lastAction = "尚未切换窗口"
    private let arguments = CommandLine.arguments

    private var mainDisplayTop: CGFloat { CGDisplayBounds(CGMainDisplayID()).height }
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private static let sampleTitles = ["paper", "paper14 基建与出口", "output", "_测试_1003 测度诊断",
                                       "1.正文", "Tobepolished", "FlowBridge", "选调生材料"]

    private func value(after option: String) -> String? {
        guard let i = arguments.firstIndex(of: option), i + 1 < arguments.count else { return nil }
        return arguments[i + 1]
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if let appearance = value(after: "--appearance") {
            windowPanel.setAppearance(appearance)
        }
        windowPanel.onSelect = { [weak self] entry in
            guard let self = self else { return }
            self.windowPanel.hide()
            self.gate.suppressUntilExit()
            guard let hit = self.lastHit else {
                self.lastAction = "预览已关闭；预览条目不会操作真实窗口"
                return
            }
            let result = self.service.focus(entry, in: hit)
            if entry.element == nil { self.lastAction = "预览已关闭；预览条目不会操作真实窗口" }
            else {
                self.lastAction = result.message
                if !result.success { NSSound.beep() }
            }
        }
        if let path = value(after: "--diagnose") {
            writeReport(service.diagnostic(settings: settings,
                                           managedApps: settings.managedApps(installed: installedApps())),
                        to: path)
            NSApp.terminate(nil)
            return
        }
        if let path = value(after: "--menu-test") {
            configureMenu()
            updatePermission()
            writeReport(menuSmokeReport(), to: path)
            NSApp.terminate(nil)
            return
        }
        if let path = value(after: "--render-preview") {
            showPreview(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) {
                do {
                    let report = try self.windowPanel.renderPNG(to: URL(fileURLWithPath: path))
                    self.writeReport(report, to: path + ".json")
                } catch {
                    self.writeReport(["error": error.localizedDescription], to: path + ".json")
                }
                NSApp.terminate(nil)
            }
            return
        }
        if let path = value(after: "--animation-test") {
            showPreview(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.windowPanel.hide()
                self.showPreview(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    let survives = self.windowPanel.isVisible && self.windowPanel.panel.alphaValue > 0.99
                    let originalTransparency = self.windowPanel.configuredGlassTransparency
                    self.windowPanel.setGlassTransparency(-1, persist: false)
                    let minimumClamped = self.windowPanel.configuredGlassTransparency == 0
                    self.windowPanel.setGlassTransparency(101, persist: false)
                    let maximumClamped = self.windowPanel.configuredGlassTransparency == 100
                    self.windowPanel.setGlassTransparency(88, persist: false)
                    let originalMetrics = self.windowPanel.currentMetrics
                    self.presentPreview(metrics: self.changingMetrics(rowHeight: 64, titleFontSize: 18))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        let adjusted = try? self.windowPanel.renderPNG(to: URL(fileURLWithPath: path + ".png"))
                        self.windowPanel.setGlassTransparency(originalTransparency, persist: false)
                        self.presentPreview(metrics: originalMetrics)
                        self.writeReport(["reopenSurvivesOlderDismissal": survives,
                                          "panelAlpha": self.windowPanel.panel.alphaValue,
                                          "glassTransparencyMinimumClamped": minimumClamped,
                                          "glassTransparencyMaximumClamped": maximumClamped,
                                          "liveAdjustment": adjusted ?? [:],
                                          "requiresAccessibility": false], to: path)
                        NSApp.terminate(nil)
                    }
                }
                return
            }
            return
        }
        shortcutManager.onTrigger = { [weak self] role in
            DispatchQueue.main.async {
                switch role {
                case .pocket: self?.showPocket(nil)
                case .windowSwitcherPanel: self?.showCurrentAppWindows(nil)
                }
            }
        }
        configureMenu()
        updatePermission()
        timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] _ in
            guard let self = self, self.windowPanel.isVisible,
                  !self.windowPanel.frame.contains(NSEvent.mouseLocation) else { return }
            self.windowPanel.hide()
            self.gate.suppressUntilExit()
        }
        if let path = value(after: "--integration-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                self.integrationTest(reportPath: path)
            }
        } else if arguments.contains("--preview") {
            showPreview(nil)
            manualDisplayUntil = now + 60
        } else if !permissionGranted && !arguments.contains("--no-onboarding") {
            DispatchQueue.main.async { self.explainPermission() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        if let monitor = clickMonitor { NSEvent.removeMonitor(monitor) }
        windowPanel.hide()
        pocketPanel.hide()
        pocketStore.clear()
    }

    // MARK: - Hover polling

    private func tick() {
        let time = now
        if time - lastPermissionQuery >= 1.5 {
            updatePermission()
            lastPermissionQuery = time
        }
        let mouse = NSEvent.mouseLocation
        let inPanel = windowPanel.isVisible &&
            windowPanel.frame.insetBy(dx: -12, dy: -12).contains(mouse)
        if time < manualDisplayUntil { return }
        let switcherActive = permissionGranted && settings.isToolEnabled(.windowSwitcher)
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }
        let nearDock = switcherActive &&
            (screen.map { PanelGeometry.nearDock(point: mouse, screen: $0.frame, edge: dockEdge) } ?? false)
        if nearDock && !inPanel && time - lastDockQuery >= 0.1 {
            let quartz = PanelGeometry.quartzPoint(fromAppKit: mouse, mainDisplayTop: mainDisplayTop)
            if let hit = service.appItem(at: quartz), settings.isEnabled(hit.bundleIdentifier) {
                lastHit = hit
            } else {
                lastHit = nil
            }
            lastDockQuery = time
        } else if !nearDock && !inPanel {
            lastHit = nil
        }
        let itemFrame = lastHit.map {
            PanelGeometry.appKitRect(fromAX: $0.axFrame, mainDisplayTop: mainDisplayTop)
        }
        let onIcon = switcherActive && nearDock &&
            (itemFrame?.contains(mouse) ?? false) && time - lastDockQuery < 0.4
        switch gate.update(onIcon: onIcon, inPanel: inPanel,
                           visible: windowPanel.isVisible, now: time) {
        case .none: break
        case .hide: windowPanel.hide()
        case .show:
            guard let hit = lastHit, let icon = itemFrame, let screen = screen else { return }
            let readout = service.windows(of: hit, config: settings.config(for: hit.bundleIdentifier))
            guard !readout.windows.isEmpty else {
                // An app without switchable windows gets no empty panel, and no
                // repeated AX query until the pointer leaves the icon.
                gate.suppressUntilExit()
                return
            }
            present(hit: hit, readout: readout, icon: icon, screen: screen,
                    message: readout.error, preview: false)
        }
    }

    private func present(hit: DockAppHit, readout: WindowReadout, icon: NSRect, screen: NSScreen,
                         message: String?, preview: Bool) {
        let context = PanelAppContext(appName: hit.displayName,
                                      bundleIdentifier: hit.bundleIdentifier,
                                      icon: NSWorkspace.shared.icon(forFile: hit.url.path),
                                      switchableCount: readout.switchableCount,
                                      omittedCount: readout.omittedCount)
        windowPanel.show(windows: readout.windows, context: context, icon: icon, screen: screen,
                         edge: dockEdge, metrics: settings.metrics, preview: preview,
                         message: message)
    }

    private func updatePermission() {
        let previouslyTrusted = permissionGranted
        permissionGranted = service.trusted
        statusItem?.button?.toolTip = permissionGranted
            ? "Mac工具箱：移到 Dock 应用图标上看看；晃动图标打开临时口袋"
            : "Mac工具箱：窗口切换需要辅助功能权限；快捷键可随时打开口袋"
        if !permissionGranted && previouslyTrusted {
            windowPanel.hide()
            gate.reset()
            lastHit = nil
        }
        dockEdge = DockEdge(rawValue:
            CFPreferencesCopyAppValue("orientation" as CFString, "com.apple.dock" as CFString) as? String
                ?? "bottom") ?? .bottom
    }

    private func anchor() -> (NSRect, NSScreen) {
        if let hit = lastHit {
            let rect = PanelGeometry.appKitRect(fromAX: hit.axFrame, mainDisplayTop: mainDisplayTop)
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: rect.midX, y: rect.midY)) }) {
                return (rect, screen)
            }
        }
        if let item = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            .flatMap({ service.appItem(bundleIdentifier: $0) }) {
            let rect = PanelGeometry.appKitRect(fromAX: item.axFrame, mainDisplayTop: mainDisplayTop)
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: rect.midX, y: rect.midY)) }) {
                return (rect, screen)
            }
        }
        let screen = NSScreen.main ?? NSScreen.screens[0]
        // This is only a placement fallback for a manually opened preview. Hover
        // recognition NEVER uses this guessed icon position.
        let rect: NSRect
        switch dockEdge {
        case .bottom: rect = NSRect(x: screen.frame.midX - 24, y: screen.visibleFrame.minY - 50,
                                    width: 48, height: 48)
        case .left: rect = NSRect(x: screen.visibleFrame.minX - 50, y: screen.frame.midY - 24,
                                  width: 48, height: 48)
        case .right: rect = NSRect(x: screen.visibleFrame.maxX + 2, y: screen.frame.midY - 24,
                                   width: 48, height: 48)
        }
        return (rect, screen)
    }

    // MARK: - Installed applications

    private func installedApps() -> [String: String] {
        var result: [String: String] = [:]
        let identifiers = AppCatalogue.entries.map(\.bundleIdentifier) + settings.customBundleIdentifiers()
        for identifier in identifiers where result[identifier] == nil {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else {
                continue
            }
            let fallback = AppCatalogue.fallbackName(for: identifier) ?? identifier
            result[identifier] = Self.displayName(for: url, fallback: fallback)
        }
        return result
    }

    private static func displayName(for url: URL, fallback: String) -> String {
        guard let bundle = Bundle(url: url) else {
            return url.deletingPathExtension().lastPathComponent
        }
        return bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String
            ?? bundle.infoDictionary?["CFBundleDisplayName"] as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? fallback
    }

    // MARK: - Menu shell

    private func configureMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }
        let icon = NSImage(systemSymbolName: "rectangle.stack", accessibilityDescription: "Mac工具箱")
        icon?.isTemplate = true
        button.image = nil
        let statusView = PocketStatusView(image: icon, statusButton: button)
        statusView.frame = button.bounds
        button.addSubview(statusView)
        pocketStatusView = statusView
        statusView.onShake = { [weak self] in self?.showPocket(nil) }
        statusView.onDrop = { [weak self] pasteboard in
            guard let self = self, self.settings.isToolEnabled(.pocket) else { return false }
            return self.pocketStore.addPasteboard(pasteboard) > 0
        }
        statusView.onDropCompleted = { [weak self] in self?.showPocket(nil) }
        pocketPanel.onCountChanged = { [weak self] count in
            self?.pocketStatusView?.setCount(count)
        }
        statusView.setCount(pocketStore.count)
        button.toolTip = "Mac工具箱；晃动图标打开临时口袋"

        menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
        rebuildMenu()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    private func rebuildMenu() {
        metricLabels.removeAll()
        metricSliderKeys.removeAll()
        while menu.items.count > 0 { menu.removeItem(at: 0) }
        addHeading("Mac工具箱")
        addSwitcherSection()
        menu.addItem(.separator())
        addPocketSection()
        menu.addItem(.separator())
        addSystemSection()
    }

    private func addHeading(_ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private func addSection(_ title: String, isEnabled: Bool) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: isEnabled ? NSColor.controlAccentColor : NSColor.secondaryLabelColor
        ])
        menu.addItem(item)
    }

    /// Walks the whole menu graph without clicking anything. This is the only way
    /// the per-app submenus, slider rows and lazy pocket panel get exercised while
    /// Accessibility is still ungranted.
    private func menuSmokeReport() -> [String: Any] {
        guard let menu = menu else {
            return ["menuBuilt": false, "statusItemCreated": statusItem != nil]
        }
        rebuildMenu()
        var actionable = 0
        var missingTarget = 0
        var unresolvedSelector = 0
        var unresolvedTitles: [String] = []
        var emptySubmenus = 0
        func walk(_ node: NSMenu) {
            for item in node.items {
                if let submenu = item.submenu {
                    if submenu.items.isEmpty { emptySubmenus += 1 }
                    walk(submenu)
                    // AppKit owns the action of a submenu parent (`submenuAction:`),
                    // so only the rows inside it are ours to validate.
                    continue
                }
                guard let action = item.action else { continue }
                actionable += 1
                guard let target = item.target as? NSObject else {
                    missingTarget += 1
                    continue
                }
                if !target.responds(to: action) {
                    unresolvedSelector += 1
                    let entry = "\(item.title) -> \(NSStringFromSelector(action))"
                    if !unresolvedTitles.contains(entry) { unresolvedTitles.append(entry) }
                }
            }
        }
        walk(menu)
        let managed = settings.managedApps(installed: installedApps())
        func submenu(named title: String) -> NSMenu? {
            menu.items.first { $0.title == title }?.submenu
        }
        let picker = submenu(named: "启用哪些应用…")
        let appearance = submenu(named: "面板外观…")
        let appRows = picker?.items.filter { $0.submenu != nil }.count ?? -1
        let sliderRows = appearance?.items.filter { $0.view != nil }.count ?? -1
        let perAppRows = picker?.items.first?.submenu?.items.count ?? -1
        let titles = menu.items.map(\.title).filter { !$0.isEmpty }
        return ["menuBuilt": true,
                "statusItemCreated": statusItem != nil,
                "statusItemHasMenu": statusItem?.menu === menu,
                "menuDelegateIsController": menu.delegate === self,
                "topLevelItemCount": menu.items.count,
                "sectionHeadingsPresent": titles.contains("Mac工具箱")
                    && titles.contains("启用悬停切窗")
                    && titles.contains("启用临时口袋")
                    && titles.contains("退出 Mac工具箱"),
                "managedAppCount": managed.count,
                "appPickerRows": appRows,
                "appPickerRowsMatchManagedApps": appRows == managed.count,
                "perAppSubmenuRows": perAppRows,
                "perAppSubmenuBuilt": perAppRows >= 4,
                "appearanceSliderRows": sliderRows,
                "appearanceRowsComplete": sliderRows == 7,
                "actionableItemCount": actionable,
                "actionItemsMissingTarget": missingTarget,
                "unresolvedSelectors": unresolvedSelector,
                "unresolvedItemTitles": unresolvedTitles,
                "emptySubmenuCount": emptySubmenus,
                "pocketPanelConstructed": true,
                "pocketPanelVisible": pocketPanel.isVisible,
                "pocketItemCount": pocketStore.count,
                "permissionNoteMatchesState":
                    titles.contains("需要辅助功能权限") == !permissionGranted,
                "switcherShortcutRowPresent": titles.contains { $0.hasPrefix("快捷键：") },
                "accessibilityTrusted": permissionGranted]
    }

    private func addSwitcherSection() {
        let enabled = settings.isToolEnabled(.windowSwitcher)
        addSection("窗口切换（悬停 Dock 图标）", isEnabled: enabled)
        let toggle = NSMenuItem(title: "启用悬停切窗", action: #selector(toggleSwitcher), keyEquivalent: "")
        toggle.target = self
        toggle.state = enabled ? .on : .off
        menu.addItem(toggle)
        menu.addItem(appPickerItem())
        menu.addItem(appAppearanceItem())
        let showCurrent = NSMenuItem(title: "显示当前应用窗口", action: #selector(showCurrentAppWindows),
                                     keyEquivalent: "")
        showCurrent.target = self
        showCurrent.isEnabled = enabled && permissionGranted
        menu.addItem(showCurrent)
        let preview = NSMenuItem(title: "界面预览（示例数据）", action: #selector(showPreview), keyEquivalent: "")
        preview.target = self
        menu.addItem(preview)
        let shortcut = NSMenuItem(title: "快捷键：\(shortcutTitle(.windowSwitcherPanel))",
                                  action: #selector(configureSwitcherShortcut), keyEquivalent: "")
        shortcut.target = self
        menu.addItem(shortcut)
        let reset = NSMenuItem(title: "清除面板快捷键", action: #selector(resetSwitcherShortcut), keyEquivalent: "")
        reset.target = self
        reset.isEnabled = shortcutManager.shortcut(for: .windowSwitcherPanel) != nil
        menu.addItem(reset)
        if !permissionGranted {
            let note = NSMenuItem(title: "需要辅助功能权限", action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
        }
    }

    private func appPickerItem() -> NSMenuItem {
        let item = NSMenuItem(title: "启用哪些应用…", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let installed = installedApps()
        let apps = settings.managedApps(installed: installed)
        for app in apps {
            let entry = NSMenuItem(title: app.displayName, action: nil, keyEquivalent: "")
            entry.state = app.isEnabled ? .on : .off
            entry.submenu = appConfigSubmenu(for: app)
            submenu.addItem(entry)
        }
        if apps.isEmpty {
            let none = NSMenuItem(title: "没有找到可管理的应用", action: nil, keyEquivalent: "")
            none.isEnabled = false
            submenu.addItem(none)
        }
        submenu.addItem(.separator())
        let add = NSMenuItem(title: "添加其他应用…", action: #selector(addApp), keyEquivalent: "")
        add.target = self
        submenu.addItem(add)
        item.submenu = submenu
        return item
    }

    private func appConfigSubmenu(for app: ManagedApp) -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let enable = NSMenuItem(title: "悬停切换此应用", action: #selector(toggleAppEnabled), keyEquivalent: "")
        enable.target = self
        enable.state = app.isEnabled ? .on : .off
        enable.representedObject = app.bundleIdentifier
        submenu.addItem(enable)
        submenu.addItem(.separator())
        let minimized = NSMenuItem(title: "列出最小化窗口", action: #selector(toggleAppMinimized), keyEquivalent: "")
        minimized.target = self
        minimized.state = app.config.includeMinimized ? .on : .off
        minimized.representedObject = app.bundleIdentifier
        submenu.addItem(minimized)
        let limit = NSMenuItem(title: "最多列出窗口：\(app.config.maxWindows)", action: nil, keyEquivalent: "")
        limit.isEnabled = false
        submenu.addItem(limit)
        for count in [3, 6, 9, 12, 20, 40] {
            let choice = NSMenuItem(title: "\(count) 个", action: #selector(setAppMaxWindows), keyEquivalent: "")
            choice.target = self
            choice.state = app.config.maxWindows == count ? .on : .off
            choice.representedObject = "\(app.bundleIdentifier)|\(count)"
            submenu.addItem(choice)
        }
        if settings.customBundleIdentifiers().contains(app.bundleIdentifier) {
            submenu.addItem(.separator())
            let remove = NSMenuItem(title: "从列表移除", action: #selector(removeApp), keyEquivalent: "")
            remove.target = self
            remove.representedObject = app.bundleIdentifier
            submenu.addItem(remove)
        }
        return submenu
    }

    private func appAppearanceItem() -> NSMenuItem {
        let item = NSMenuItem(title: "面板外观…", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let metrics = settings.metrics
        submenu.addItem(metricSlider(title: "行高", key: "rowHeight", value: metrics.rowHeight,
                                     range: 34...72, unit: "pt"))
        submenu.addItem(metricSlider(title: "标题字号", key: "titleFontSize", value: metrics.titleFontSize,
                                     range: 11...22, unit: "pt"))
        submenu.addItem(metricSlider(title: "宽度上限", key: "widthCap", value: metrics.widthCap,
                                     range: 240...640, unit: "pt"))
        submenu.addItem(metricSlider(title: "最大高度占比", key: "maxHeightFraction",
                                     value: metrics.maxHeightFraction * 100, range: 30...90, unit: "%"))
        submenu.addItem(metricSlider(title: "距 Dock 间隙", key: "dockGap", value: metrics.dockGap,
                                     range: 4...40, unit: "pt"))
        submenu.addItem(metricSlider(title: "圆角", key: "cornerRadius", value: metrics.cornerRadius,
                                     range: 0...36, unit: "pt"))
        submenu.addItem(metricSlider(title: "玻璃透明度", key: "glassTransparency",
                                     value: windowPanel.configuredGlassTransparency, range: 0...100, unit: "%"))
        let autoFit = NSMenuItem(title: "宽度自适应标题", action: #selector(toggleAutoFitWidth), keyEquivalent: "")
        autoFit.target = self
        autoFit.state = metrics.autoFitWidth ? .on : .off
        submenu.addItem(autoFit)
        let reset = NSMenuItem(title: "恢复默认外观", action: #selector(resetMetrics), keyEquivalent: "")
        reset.target = self
        submenu.addItem(reset)
        item.submenu = submenu
        return item
    }

    private func metricSlider(title: String, key: String, value: CGFloat,
                              range: ClosedRange<CGFloat>, unit: String) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 54))
        let caption = NSTextField(labelWithString: title)
        caption.font = .systemFont(ofSize: 12)
        caption.frame = NSRect(x: 18, y: 30, width: 130, height: 17)
        let label = NSTextField(labelWithString: formatMetric(key, value, unit: unit))
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        label.alignment = .right
        label.frame = NSRect(x: 182, y: 30, width: 60, height: 17)
        metricLabels[key] = label
        let slider = NSSlider(value: Double(value), minValue: Double(range.lowerBound),
                              maxValue: Double(range.upperBound), target: self,
                              action: #selector(metricChanged))
        slider.isContinuous = true
        slider.frame = NSRect(x: 18, y: 6, width: 224, height: 22)
        metricSliderKeys.append(MetricSliderKey(key: key, unit: unit))
        slider.tag = metricSliderKeys.count - 1
        slider.setAccessibilityLabel(title)
        view.addSubview(caption)
        view.addSubview(label)
        view.addSubview(slider)
        item.view = view
        return item
    }

    private struct MetricSliderKey {
        let key: String
        let unit: String
    }

    private func formatMetric(_ key: String, _ value: CGFloat, unit: String) -> String {
        if key == "titleFontSize" || key == "rowHeight" || key == "widthCap" || key == "dockGap" {
            return String(format: "%.0f%@", Double(value), unit)
        }
        return String(format: "%.0f%%", Double(value))
    }

    private func shortcutTitle(_ role: ShortcutRole) -> String {
        shortcutManager.shortcut(for: role)?.displayName ?? "未设置"
    }

    private func addPocketSection() {
        let enabled = settings.isToolEnabled(.pocket)
        addSection("临时口袋", isEnabled: enabled)
        let toggle = NSMenuItem(title: "启用临时口袋", action: #selector(togglePocket), keyEquivalent: "")
        toggle.target = self
        toggle.state = enabled ? .on : .off
        menu.addItem(toggle)
        let status = NSMenuItem(title: "口袋：\(pocketStore.count) 项", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        let open = NSMenuItem(title: "打开临时口袋", action: #selector(showPocket), keyEquivalent: "")
        open.target = self
        open.isEnabled = enabled
        menu.addItem(open)
        let clear = NSMenuItem(title: "清空临时口袋", action: #selector(clearPocket), keyEquivalent: "")
        clear.target = self
        clear.isEnabled = enabled && pocketStore.count > 0
        menu.addItem(clear)
        let shortcut = NSMenuItem(title: "快捷键：\(shortcutTitle(.pocket))",
                                  action: #selector(configurePocketShortcut), keyEquivalent: "")
        shortcut.target = self
        menu.addItem(shortcut)
        let reset = NSMenuItem(title: "恢复默认快捷键（⌥Space）", action: #selector(resetPocketShortcut),
                               keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)
    }

    private func addSystemSection() {
        addSection("系统", isEnabled: true)
        let permission = NSMenuItem(title: permissionGranted ? "辅助功能：已授权" : "辅助功能：尚未授权",
                                    action: nil, keyEquivalent: "")
        permission.isEnabled = false
        menu.addItem(permission)
        add("开启辅助功能权限…", #selector(openPermissionSettings))
        add("重新检测权限", #selector(recheckPermission))
        add("生成诊断报告…", #selector(saveDiagnostic))
        let last = NSMenuItem(title: lastAction, action: nil, keyEquivalent: "")
        last.isEnabled = false
        menu.addItem(last)
        menu.addItem(.separator())
        add("退出 Mac工具箱", #selector(quit))
    }

    private func add(_ title: String, _ selector: Selector) {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    // MARK: - Menu actions

    @objc private func toggleSwitcher(_ sender: NSMenuItem) {
        settings.setToolEnabled(sender.state != .on, for: .windowSwitcher)
        if !settings.isToolEnabled(.windowSwitcher) {
            windowPanel.hide()
            gate.suppressUntilExit()
        }
    }

    @objc private func togglePocket(_ sender: NSMenuItem) {
        let enable = sender.state != .on
        settings.setToolEnabled(enable, for: .pocket)
        if !enable { pocketPanel.hide() }
    }

    @objc private func toggleAppEnabled(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String else { return }
        settings.setEnabled(sender.state != .on, for: identifier)
        lastHit = nil
        gate.reset()
    }

    @objc private func toggleAppMinimized(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String else { return }
        var config = settings.config(for: identifier)
        config.includeMinimized = !config.includeMinimized
        settings.setConfig(config, for: identifier)
    }

    @objc private func setAppMaxWindows(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? String else { return }
        let parts = payload.split(separator: "|")
        guard parts.count == 2, let identifier = parts.first, let count = Int(parts[1]) else { return }
        var config = settings.config(for: String(identifier))
        config.maxWindows = count
        settings.setConfig(config, for: String(identifier))
    }

    @objc private func addApp() {
        NSApp.activate(ignoringOtherApps: true)
        let picker = NSOpenPanel()
        picker.allowsMultipleSelection = false
        picker.canChooseDirectories = false
        picker.allowedContentTypes = [.application]
        picker.directoryURL = URL(fileURLWithPath: "/Applications")
        picker.message = "选择要加入悬停切窗的应用"
        guard picker.runModal() == .OK, let url = picker.url,
              let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier else { return }
        settings.addCustomApp(bundleIdentifier: identifier,
                              displayName: Self.displayName(for: url, fallback: identifier))
        settings.setEnabled(true, for: identifier)
    }

    @objc private func removeApp(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String else { return }
        settings.removeCustomApp(bundleIdentifier: identifier)
        lastHit = nil
        gate.reset()
    }

    @objc private func toggleAutoFitWidth(_ sender: NSMenuItem) {
        var metrics = settings.metrics
        metrics.autoFitWidth = sender.state != .on
        settings.setMetrics(metrics)
        refreshPreviewFromMenu()
    }

    @objc private func resetMetrics(_ sender: Any?) {
        settings.setMetrics(PanelMetrics.defaultValue)
        refreshPreviewFromMenu()
    }

    @objc private func metricChanged(_ sender: NSSlider) {
        guard sender.tag >= 0, sender.tag < metricSliderKeys.count else { return }
        let payload = metricSliderKeys[sender.tag]
        let value = CGFloat(sender.doubleValue)
        metricLabels[payload.key]?.stringValue = formatMetric(payload.key, value, unit: payload.unit)
        if payload.key == "glassTransparency" {
            windowPanel.setGlassTransparency(value)
        } else {
            var metrics = settings.metrics
            switch payload.key {
            case "rowHeight": metrics.rowHeight = value
            case "titleFontSize": metrics.titleFontSize = value
            case "widthCap": metrics.widthCap = value
            case "maxHeightFraction": metrics.maxHeightFraction = value / 100
            case "dockGap": metrics.dockGap = value
            case "cornerRadius": metrics.cornerRadius = value
            default: return
            }
            settings.setMetrics(metrics)
        }
        refreshPreviewFromMenu()
    }

    private func refreshPreviewFromMenu() {
        if !windowPanel.isVisible { showPreview(nil) }
        manualDisplayUntil = now + 20
    }

    @objc private func configurePocketShortcut(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        shortcutManager.presentRecorder(for: .pocket)
    }

    @objc private func resetPocketShortcut(_ sender: Any?) {
        shortcutManager.reset(.pocket)
    }

    @objc private func configureSwitcherShortcut(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        shortcutManager.presentRecorder(for: .windowSwitcherPanel)
    }

    @objc private func resetSwitcherShortcut(_ sender: Any?) {
        shortcutManager.reset(.windowSwitcherPanel)
    }

    // MARK: - Panel entries

    @objc private func showCurrentAppWindows(_ sender: Any?) {
        guard service.trusted else { explainPermission(); return }
        gate.reset()
        guard let result = service.frontmostAppWindows(config: AppWindowConfig()) else { return }
        let (icon, screen) = anchor()
        present(hit: result.hit, readout: result.readout, icon: icon, screen: screen,
                message: result.readout.error, preview: false)
        manualDisplayUntil = now + 2
    }

    @objc private func showPreview(_ sender: Any?) {
        presentPreview(metrics: settings.metrics)
    }

    private func presentPreview(metrics: PanelMetrics) {
        gate.reset()
        let (icon, screen) = anchor()
        let installed = installedApps()
        let managed = settings.managedApps(installed: installed)
        let spotlight = managed.first { $0.isEnabled }
        let appName = spotlight?.displayName ?? "访达"
        let iconImage: NSImage
        if let identifier = spotlight?.bundleIdentifier,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
            iconImage = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            iconImage = NSWorkspace.shared.icon(forFile: "/System/Library/CoreServices/Finder.app")
        }
        let context = PanelAppContext(appName: appName, bundleIdentifier: spotlight?.bundleIdentifier,
                                      icon: iconImage, switchableCount: Self.sampleTitles.count + 2,
                                      omittedCount: 2)
        let windows = Self.sampleTitles.map { AppWindow.preview(title: $0) }
        windowPanel.show(windows: windows, context: context, icon: icon, screen: screen,
                         edge: dockEdge, metrics: metrics, preview: true, message: nil)
        manualDisplayUntil = now + 2
    }

    // MARK: - Pocket

    @objc private func showPocket(_ sender: Any?) {
        guard settings.isToolEnabled(.pocket) else { return }
        windowPanel.hide()
        pocketPanel.show(near: pocketStatusView?.statusFrameInScreen())
    }

    @objc private func clearPocket(_ sender: Any?) {
        pocketStore.clear()
    }

    // MARK: - Permissions and diagnostics

    private func explainPermission() {
        NSApp.activate(ignoringOtherApps: true)
        let appPath = Bundle.main.bundleURL.path
        let bundleID = Bundle.main.bundleIdentifier ?? "unknown"
        let alert = NSAlert()
        alert.messageText = "需要开启辅助功能权限"
        alert.informativeText = "请在“系统设置 → 隐私与安全性 → 辅助功能”中添加并开启当前这个应用：\n\nMac工具箱\n\(appPath)\n\nBundle ID：\(bundleID)\n\n授权后点击菜单栏中的“重新检测权限”，或重新打开应用。内部程序名可能显示为 FinderHover。未授权时窗口切换不可用，临时口袋和快捷键仍可正常使用。"
        alert.addButton(withTitle: "打开辅助功能设置")
        alert.addButton(withTitle: "复制当前路径")
        alert.addButton(withTitle: "稍后")
        switch alert.runModal() {
        case .alertFirstButtonReturn: openPermissionSettings(nil)
        case .alertSecondButtonReturn:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(appPath, forType: .string)
        default: break
        }
    }

    @objc private func openPermissionSettings(_ sender: Any?) {
        service.requestPermission()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func recheckPermission(_ sender: Any?) { updatePermission() }

    @objc private func saveDiagnostic(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        let picker = NSSavePanel()
        picker.nameFieldStringValue = "Mac工具箱-诊断.json"
        picker.title = "保存 Mac工具箱诊断报告"
        if picker.runModal() == .OK, let url = picker.url {
            writeReport(service.diagnostic(settings: settings,
                                           managedApps: settings.managedApps(installed: installedApps())),
                        to: url.path)
        }
    }

    @objc private func quit(_ sender: Any?) { NSApp.terminate(nil) }

    private func writeReport(_ report: [String: Any], to path: String) {
        do {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            fputs("报告写入失败：\(error.localizedDescription)\n", stderr)
        }
    }

    // MARK: - Integration test (explicit opt-in, moves the pointer)

    private func integrationTest(reportPath: String) {
        var report = service.diagnostic(settings: settings,
                                        managedApps: settings.managedApps(installed: installedApps()))
        let originalMouse = NSEvent.mouseLocation
        let originalApp = NSWorkspace.shared.frontmostApplication
        func moveMouse(_ point: CGPoint) {
            let quartz = PanelGeometry.quartzPoint(fromAppKit: point, mainDisplayTop: mainDisplayTop)
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                    mouseCursorPosition: quartz, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
        func finish(_ passed: Bool, reason: String? = nil) {
            self.windowPanel.hide()
            self.gate.suppressUntilExit()
            moveMouse(originalMouse)
            _ = originalApp?.activate(options: [])
            report["passed"] = passed
            if let reason = reason { report["reason"] = reason }
            self.writeReport(report, to: reportPath)
            NSApp.terminate(nil)
        }
        guard service.trusted else {
            report["blocked"] = true
            finish(false, reason: "真实交互测试需要用户授予辅助功能权限")
            return
        }
        guard let candidate = enabledRunningCandidate() else {
            finish(false, reason: "没有已启用且有可切换窗口的应用")
            return
        }
        let hit = candidate.hit
        let firstWindow = candidate.readout.windows[0]
        let icon = PanelGeometry.appKitRect(fromAX: hit.axFrame, mainDisplayTop: mainDisplayTop)
        func moveToCurrentIcon() {
            guard let current = self.service.appItem(bundleIdentifier: hit.bundleIdentifier) else { return }
            let currentAppKit = PanelGeometry.appKitRect(fromAX: current.axFrame,
                                                         mainDisplayTop: self.mainDisplayTop)
            CGWarpMouseCursorPosition(PanelGeometry.quartzPoint(
                fromAppKit: CGPoint(x: currentAppKit.midX, y: currentAppKit.midY),
                mainDisplayTop: self.mainDisplayTop))
            CGAssociateMouseAndMouseCursorPosition(1)
        }
        moveToCurrentIcon()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            moveToCurrentIcon()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                let hoverShown = self.windowPanel.isVisible && !self.windowPanel.isPreview &&
                    !self.windowPanel.entries.isEmpty
                report["hoverBundleIdentifier"] = hit.bundleIdentifier
                report["hoverShowsRealWindowList"] = hoverShown
                guard hoverShown else {
                    finish(false, reason: "悬停后未显示真实窗口列表")
                    return
                }
                let panelFrame = self.windowPanel.frame
                moveMouse(CGPoint(x: panelFrame.midX, y: panelFrame.midY))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    report["movingIntoPanelKeepsItOpen"] = self.windowPanel.isVisible
                    let testScreen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: icon.midX, y: icon.midY)) }
                    let outside = testScreen?.visibleFrame ?? NSRect(x: 500, y: 500, width: 100, height: 100)
                    moveMouse(CGPoint(x: outside.midX, y: outside.midY))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                        let hides = !self.windowPanel.isVisible
                        report["leavingDismissesPanel"] = hides
                        // Same callback as a row's click; validates the focus action,
                        // not an injected physical mouse click.
                        self.lastHit = hit
                        self.windowPanel.onSelect?(firstWindow)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                            let frontIsTarget = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ==
                                hit.bundleIdentifier
                            let selectedIsMain = self.service.isMain(firstWindow)
                            report["selectionActivatesApp"] = frontIsTarget
                            report["selectedWindowIsMain"] = selectedIsMain
                            report["selectionMessage"] = self.lastAction
                            let passed = hoverShown &&
                                (report["movingIntoPanelKeepsItOpen"] as? Bool == true) &&
                                hides && frontIsTarget && selectedIsMain
                            finish(passed)
                        }
                    }
                }
            }
        }
    }

    private func enabledRunningCandidate() -> (hit: DockAppHit, readout: WindowReadout)? {
        for app in settings.managedApps(installed: installedApps()) where app.isEnabled {
            guard let hit = service.appItem(bundleIdentifier: app.bundleIdentifier) else { continue }
            let readout = service.windows(of: hit, config: app.config)
            if !readout.windows.isEmpty { return (hit, readout) }
        }
        return nil
    }

    // MARK: - Metrics preview helper

    private func changingMetrics(rowHeight: CGFloat, titleFontSize: CGFloat) -> PanelMetrics {
        var metrics = settings.metrics
        metrics.rowHeight = rowHeight
        metrics.titleFontSize = titleFontSize
        return metrics.clamped()
    }
}
