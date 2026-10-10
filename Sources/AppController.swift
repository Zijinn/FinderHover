import AppKit
import ApplicationServices

final class AppController: NSObject, NSApplicationDelegate {
    private let service = AccessibilityService()
    private let windowPanel = WindowListPanel()
    private var statusItem: NSStatusItem!
    private var permissionItem: NSMenuItem!
    private var lastActionItem: NSMenuItem!
    private var timer: Timer?
    private var clickMonitor: Any?
    private var gate = HoverGate()
    private var dockEdge: DockEdge = .bottom
    private var lastDockQuery: TimeInterval = 0
    private var lastPermissionQuery: TimeInterval = 0
    private var lastHit: DockItem?
    private var permissionGranted = false
    private var manualDisplayUntil: TimeInterval = 0
    private var lastAction = "尚未切换窗口"
    private var glassStrengthValueLabel: NSTextField?
    private let arguments = CommandLine.arguments

    private var mainDisplayTop: CGFloat { CGDisplayBounds(CGMainDisplayID()).height }
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    static var sampleWindows: [FinderWindow] {
        ["paper", "paper14 基建与出口", "output", "_测试_1003 测度诊断", "1.正文",
         "Tobepolished", "FlowBridge", "选调生材料"].map {
            FinderWindow(element: nil, title: $0, minimized: false)
        }
    }

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
            if entry.element == nil {
                self.lastAction = "预览已关闭；预览条目不会操作真实窗口"
            } else {
                let result = self.service.focus(entry)
                self.lastAction = result.message
                if !result.success { NSSound.beep() }
            }
            self.lastActionItem?.title = self.lastAction
        }
        if let path = value(after: "--diagnose") {
            writeReport(service.diagnostic(), to: path)
            NSApp.terminate(nil)
            return
        }
        if let path = value(after: "--render-preview") {
            showPreview(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
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
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        let adjusted = try? self.windowPanel.renderPNG(to: URL(fileURLWithPath: path + ".png"))
                        self.windowPanel.setGlassTransparency(originalTransparency, persist: false)
                        self.writeReport(["reopenSurvivesOlderDismissal": survives,
                                          "panelAlpha": self.windowPanel.panel.alphaValue,
                                          "glassTransparencyMinimumClamped": minimumClamped,
                                          "glassTransparencyMaximumClamped": maximumClamped,
                                          "liveAdjustment": adjusted ?? [:],
                                          "requiresAccessibility": false], to: path)
                        NSApp.terminate(nil)
                    }
                    }
                }
            return
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
    }

    private func configureMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let icon = NSImage(systemSymbolName: "rectangle.stack", accessibilityDescription: "访达悬停")
        icon?.isTemplate = true
        statusItem.button?.image = icon
        statusItem.button?.toolTip = "访达悬停"
        let menu = NSMenu()
        menu.autoenablesItems = false
        let heading = NSMenuItem(title: "访达悬停", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        permissionItem = NSMenuItem(title: "检查权限中…", action: nil, keyEquivalent: "")
        permissionItem.isEnabled = false
        menu.addItem(permissionItem)
        menu.addItem(.separator())
        addMenuItem("显示当前访达窗口", selector: #selector(showCurrentWindows), to: menu)
        addMenuItem("界面预览", selector: #selector(showPreview), to: menu)
        let glassControl = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let controlView = NSView(frame: NSRect(x: 0, y: 0, width: 250, height: 60))
        let caption = NSTextField(labelWithString: "玻璃透明度")
        caption.font = .systemFont(ofSize: 12)
        caption.frame = NSRect(x: 18, y: 35, width: 130, height: 17)
        let valueLabel = NSTextField(labelWithString: String(format: "%.0f%%", Double(windowPanel.configuredGlassTransparency)))
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        valueLabel.alignment = .right
        valueLabel.frame = NSRect(x: 172, y: 35, width: 60, height: 17)
        glassStrengthValueLabel = valueLabel
        let transparencySlider = NSSlider(value: Double(windowPanel.configuredGlassTransparency),
                                          minValue: 0, maxValue: 100, target: self,
                                          action: #selector(updateGlassTransparency))
        transparencySlider.isContinuous = true
        transparencySlider.frame = NSRect(x: 18, y: 8, width: 214, height: 22)
        transparencySlider.toolTip = "0% 不透明，100% 完全透明；文字与图标不变"
        transparencySlider.setAccessibilityLabel("玻璃透明度，100% 最透明")
        controlView.addSubview(caption)
        controlView.addSubview(valueLabel)
        controlView.addSubview(transparencySlider)
        glassControl.view = controlView
        menu.addItem(glassControl)
        menu.addItem(.separator())
        addMenuItem("开启辅助功能权限…", selector: #selector(openPermissionSettings), to: menu)
        addMenuItem("重新检测权限", selector: #selector(recheckPermission), to: menu)
        addMenuItem("生成诊断报告…", selector: #selector(saveDiagnostic), to: menu)
        lastActionItem = NSMenuItem(title: lastAction, action: nil, keyEquivalent: "")
        lastActionItem.isEnabled = false
        menu.addItem(lastActionItem)
        menu.addItem(.separator())
        addMenuItem("退出访达悬停", selector: #selector(quit), to: menu)
        statusItem.menu = menu
    }

    private func addMenuItem(_ title: String, selector: Selector, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    @objc private func updateGlassTransparency(_ sender: NSSlider) {
        windowPanel.setGlassTransparency(CGFloat(sender.doubleValue))
        glassStrengthValueLabel?.stringValue = String(format: "%.0f%%", sender.doubleValue)
        if !windowPanel.isVisible { showPreview(nil) }
        manualDisplayUntil = now + 20
    }

    private func updatePermission() {
        let previouslyTrusted = permissionGranted
        permissionGranted = service.trusted
        permissionItem?.title = permissionGranted ? "辅助功能：已授权" : "辅助功能：尚未授权"
        statusItem?.button?.toolTip = permissionGranted ? "访达悬停：移到 Dock 访达图标上试试" :
            "访达悬停：需要辅助功能权限"
        if !permissionGranted && previouslyTrusted {
            windowPanel.hide()
            gate.reset()
            lastHit = nil
        }
        dockEdge = DockEdge(rawValue:
            CFPreferencesCopyAppValue("orientation" as CFString, "com.apple.dock" as CFString) as? String
                ?? "bottom") ?? .bottom
    }

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
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }
        let nearDock = screen.map {
            PanelGeometry.nearDock(point: mouse, screen: $0.frame, edge: dockEdge)
        } ?? false
        if permissionGranted && nearDock && !inPanel && time - lastDockQuery >= 0.1 {
            let quartz = PanelGeometry.quartzPoint(fromAppKit: mouse, mainDisplayTop: mainDisplayTop)
            lastHit = service.finderItem(at: quartz) ?? service.locateFinderItem()
            lastDockQuery = time
        } else if !nearDock && !inPanel {
            lastHit = nil
        }
        let itemFrame = lastHit.map {
            PanelGeometry.appKitRect(fromAX: $0.axFrame, mainDisplayTop: mainDisplayTop)
        }
        let onIcon = permissionGranted && nearDock &&
            (itemFrame?.contains(mouse) ?? false) && time - lastDockQuery < 0.4
        switch gate.update(onIcon: onIcon, inPanel: inPanel,
                           visible: windowPanel.isVisible, now: time) {
        case .none: break
        case .hide: windowPanel.hide()
        case .show:
            guard let icon = itemFrame, let screen = screen else { return }
            let result = service.windows()
            windowPanel.show(entries: result.windows, icon: icon, screen: screen,
                             edge: dockEdge, message: result.error)
        }
    }

    private func anchor() -> (NSRect, NSScreen) {
        if let item = service.locateFinderItem() {
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

    @objc private func showCurrentWindows(_ sender: Any?) {
        guard service.trusted else { explainPermission(); return }
        gate.reset()
        let (icon, screen) = anchor()
        let result = service.windows()
        windowPanel.show(entries: result.windows, icon: icon, screen: screen,
                         edge: dockEdge, message: result.error)
        manualDisplayUntil = now + 2
    }

    @objc private func showPreview(_ sender: Any?) {
        gate.reset()
        let (icon, screen) = anchor()
        windowPanel.show(entries: Self.sampleWindows, icon: icon, screen: screen,
                         edge: dockEdge, preview: true)
        manualDisplayUntil = now + 2
    }

    private func explainPermission() {
        NSApp.activate(ignoringOtherApps: true)
        let appPath = Bundle.main.bundleURL.path
        let bundleID = Bundle.main.bundleIdentifier ?? "unknown"
        let alert = NSAlert()
        alert.messageText = "需要开启辅助功能权限"
        alert.informativeText = "请在“系统设置 → 隐私与安全性 → 辅助功能”中添加并开启当前这个应用：\n\n访达悬停\n\(appPath)\n\nBundle ID：\(bundleID)\n\n授权后点击菜单栏中的“重新检测权限”，或重新打开应用。列表中可能显示为“FinderHover”而不是“访达悬停”。"
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
        picker.nameFieldStringValue = "FinderHover-诊断.json"
        picker.title = "保存访达悬停诊断报告"
        if picker.runModal() == .OK, let url = picker.url {
            writeReport(service.diagnostic(), to: url.path)
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

    // Explicit opt-in only. Moves the pointer, tests hover and selection, then
    // restores the pointer and previously active application. No window created.
    private func integrationTest(reportPath: String) {
        var report = service.diagnostic()
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
        guard let item = service.locateFinderItem() else {
            finish(false, reason: "未识别到 Dock 中的访达图标")
            return
        }
        guard let firstWindow = service.windows().windows.first else {
            finish(false, reason: "请先打开至少一个访达窗口")
            return
        }
        let icon = PanelGeometry.appKitRect(fromAX: item.axFrame, mainDisplayTop: mainDisplayTop)
        func moveToCurrentFinder() {
            guard let current = self.service.locateFinderItem() else { return }
            let currentAppKit = PanelGeometry.appKitRect(fromAX: current.axFrame,
                                                         mainDisplayTop: self.mainDisplayTop)
            let quartz = PanelGeometry.quartzPoint(fromAppKit: CGPoint(x: currentAppKit.midX,
                                                                        y: currentAppKit.midY),
                                                    mainDisplayTop: self.mainDisplayTop)
            CGWarpMouseCursorPosition(quartz)
            CGAssociateMouseAndMouseCursorPosition(1)
        }
        moveToCurrentFinder()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            moveToCurrentFinder()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                let hoverShown = self.windowPanel.isVisible && !self.windowPanel.isPreview &&
                    !self.windowPanel.entries.isEmpty
                report["hoverShowsRealWindowList"] = hoverShown
            guard hoverShown else {
                finish(false, reason: "悬停后未显示真实窗口列表")
                return
            }
            let panelFrame = self.windowPanel.frame
            moveMouse(CGPoint(x: panelFrame.midX, y: panelFrame.midY))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                report["movingIntoPanelKeepsItOpen"] = self.windowPanel.isVisible
                let testScreen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: icon.midX, y: icon.midY)) } ?? NSScreen.main
                let outside = testScreen?.visibleFrame ?? NSRect(x: 500, y: 500, width: 100, height: 100)
                moveMouse(CGPoint(x: outside.midX, y: outside.midY))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                    let hides = !self.windowPanel.isVisible
                    report["leavingDismissesPanel"] = hides
                    // Same callback as a row's click; validates the focus action,
                    // not an injected physical mouse click.
                    self.windowPanel.onSelect?(firstWindow)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                        let frontIsFinder = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder"
                        let selectedIsMain = self.service.isMain(firstWindow)
                        report["selectionActivatesFinder"] = frontIsFinder
                        report["selectedWindowIsMain"] = selectedIsMain
                        report["selectionMessage"] = self.lastAction
                        let passed = hoverShown && (report["movingIntoPanelKeepsItOpen"] as? Bool == true) &&
                            hides && frontIsFinder && selectedIsMain
                        finish(passed)
                    }
                }
            }
        }
    }
}
}
