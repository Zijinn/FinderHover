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
    private lazy var dragShake = DragShakeWatcher()

    private lazy var permissionWindow = PermissionWindowController(service: service)
    private lazy var settingsWindow: SettingsWindowController = {
        SettingsWindowController(
            settings: settings, shortcuts: shortcutManager, pocketStore: pocketStore,
            windowPanel: windowPanel,
            hooks: SettingsHooks(
                installedApps: { [weak self] in self?.installedApps() ?? [:] },
                addCustomApp: { [weak self] in self?.addApp() },
                openPocket: { [weak self] in self?.showPocket(nil) },
                clearPocket: { [weak self] in self?.pocketStore.clear() },
                showPanelPreview: { [weak self] in self?.showPreview(nil) },
                refreshPanelPreview: { [weak self] in self?.refreshPreviewFromMenu() },
                showPermissionWindow: { [weak self] in self?.showPermissionWindow(nil) },
                isTrusted: { [weak self] in self?.service.trusted ?? false },
                revealApp: {
                    NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                },
                resetPermission: { [weak self] in self?.resetAccessibilityPermission() }))
    }()

    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
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
    private static let onboardingShownKey = "toolbox.permissionOnboardingShown"

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
        if let path = value(after: "--render-settings") {
            settingsWindow.show(page: 0)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                var report = self.settingsWindow.renderPages(basePath: path)
                report["window"] = self.settingsWindow.renderWindow(to: path)
                self.writeReport(report, to: path + ".json")
                NSApp.terminate(nil)
            }
            return
        }
        if let path = value(after: "--render-permission") {
            permissionWindow.show()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                self.writeReport(self.permissionWindow.renderPNG(to: URL(fileURLWithPath: path)),
                                 to: path + ".json")
                NSApp.terminate(nil)
            }
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
        permissionWindow.onTrusted = { [weak self] in
            self?.updatePermission()
            self?.settingsWindow.reload()
        }
        dragShake.onShake = { [weak self] point in self?.handleDragShake(at: point) }
        dragShake.start()
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
        } else if !permissionGranted && !arguments.contains("--no-onboarding")
                    && !UserDefaults.standard.bool(forKey: Self.onboardingShownKey) {
            // A menu bar utility that opens a window on every login is noise. Guide
            // once; afterwards the menu item and the tool tip carry the reminder.
            UserDefaults.standard.set(true, forKey: Self.onboardingShownKey)
            DispatchQueue.main.async { self.explainPermission() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        dragShake.stop()
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
        // The settings window owns the foreground while open. The permission guide is
        // small, so it only blocks hover while the pointer is actually over it —
        // otherwise leaving it open would silently kill Dock detection.
        let mouse = NSEvent.mouseLocation
        let overGuide = permissionWindow.isVisible && permissionWindow.frame.contains(mouse)
        if settingsWindow.isVisible || overGuide {
            if windowPanel.isVisible { windowPanel.hide() }
            lastHit = nil
            gate.reset()
            return
        }
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
            ? "MacToolbox：移到 Dock 应用图标上看看；拖动文件时晃动鼠标可打开临时口袋"
            : "MacToolbox：窗口切换需要辅助功能权限；拖动文件时晃动鼠标可打开临时口袋"
        if !permissionGranted && previouslyTrusted {
            windowPanel.hide()
            gate.reset()
            lastHit = nil
        }
        if previouslyTrusted != permissionGranted {
            settingsWindow.reload()
            // A rebuild invalidates the ad-hoc signature and drops the grant, so the
            // guide must be able to come back after a successful authorisation.
            if !previouslyTrusted {
                UserDefaults.standard.set(false, forKey: Self.onboardingShownKey)
            }
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
        let icon = NSImage(systemSymbolName: "rectangle.stack", accessibilityDescription: "MacToolbox")
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
        button.toolTip = "MacToolbox；拖动文件时晃动鼠标打开临时口袋"

        menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
        rebuildMenu()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    /// The menu is now a launcher, not a control panel: switches and entry points
    /// only. Everything with a slider or a per-app row lives in the settings window.
    private func rebuildMenu() {
        while menu.items.count > 0 { menu.removeItem(at: 0) }
        addHeading("MacToolbox")
        add("打开设置…", #selector(openSettings(_:)), key: ",")
        menu.addItem(.separator())

        let switcher = NSMenuItem(title: "启用悬停切窗", action: #selector(toggleSwitcher(_:)),
                                  keyEquivalent: "")
        switcher.target = self
        switcher.state = settings.isToolEnabled(.windowSwitcher) ? .on : .off
        menu.addItem(switcher)

        let pocket = NSMenuItem(title: "启用临时口袋", action: #selector(togglePocket(_:)),
                                keyEquivalent: "")
        pocket.target = self
        pocket.state = settings.isToolEnabled(.pocket) ? .on : .off
        menu.addItem(pocket)

        menu.addItem(.separator())
        add("显示当前应用窗口", #selector(showCurrentAppWindows(_:)))
        add("打开临时口袋", #selector(showPocket(_:)))
        menu.addItem(.separator())

        let permission = NSMenuItem(title: permissionGranted ? "辅助功能：已授权" : "辅助功能：尚未授权",
                                    action: nil, keyEquivalent: "")
        permission.isEnabled = false
        menu.addItem(permission)
        add("开启辅助功能权限…", #selector(showPermissionWindow(_:)))
        add("生成诊断报告…", #selector(saveDiagnostic(_:)))

        let last = NSMenuItem(title: lastAction, action: nil, keyEquivalent: "")
        last.isEnabled = false
        menu.addItem(last)
        menu.addItem(.separator())
        add("退出 MacToolbox", #selector(quit(_:)))
    }

    private func addHeading(_ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    /// Walks the whole menu graph without clicking anything, then builds every
    /// settings page offscreen. This is the only way the window surface gets
    /// exercised while Accessibility is still ungranted.
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
        let titles = menu.items.map(\.title).filter { !$0.isEmpty }
        var report: [String: Any] = ["menuBuilt": true,
                "statusItemCreated": statusItem != nil,
                "statusItemHasMenu": statusItem?.menu === menu,
                "menuDelegateIsController": menu.delegate === self,
                "topLevelItemCount": menu.items.count,
                "sectionHeadingsPresent": titles.contains("MacToolbox")
                    && titles.contains("启用悬停切窗")
                    && titles.contains("启用临时口袋")
                    && titles.contains("退出 MacToolbox"),
                "settingsEntryPresent": titles.contains("打开设置…"),
                "actionableItemCount": actionable,
                "actionItemsMissingTarget": missingTarget,
                "unresolvedSelectors": unresolvedSelector,
                "unresolvedItemTitles": unresolvedTitles,
                "emptySubmenuCount": emptySubmenus,
                "pocketPanelConstructed": true,
                "pocketPanelVisible": pocketPanel.isVisible,
                "pocketItemCount": pocketStore.count,
                "permissionNoteMatchesState":
                    titles.contains("辅助功能：尚未授权") == !permissionGranted,
                "accessibilityTrusted": permissionGranted]
        for (key, value) in settingsWindow.smokeReport() { report[key] = value }
        return report
    }

    private func add(_ title: String, _ selector: Selector, key: String = "") {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
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
        settingsWindow.reload()
    }

    @objc private func togglePocket(_ sender: NSMenuItem) {
        let enable = sender.state != .on
        settings.setToolEnabled(enable, for: .pocket)
        if !enable { pocketPanel.hide() }
        settingsWindow.reload()
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

    private func refreshPreviewFromMenu() {
        if !windowPanel.isVisible { showPreview(nil) }
        manualDisplayUntil = now + 20
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

    /// Shaking a file while dragging it summons the pocket at the cursor. The drag
    /// pasteboard is the filter: without a file or image payload this is just a
    /// text selection or a window resize, and nothing should appear.
    private func handleDragShake(at point: CGPoint) {
        guard settings.isToolEnabled(.pocket) else { return }
        let pasteboard = NSPasteboard(name: .drag)
        guard pocketStore.hasAcceptablePasteboardContent(pasteboard) else {
            // Surfaces in the menu status row, which is the only place a menu bar
            // utility can explain a gesture that did nothing.
            lastAction = "晃动了，但当前拖拽内容不是文件或图片"
            return
        }
        lastAction = "口袋已打开，把文件移进去即可收纳"
        windowPanel.hide()
        pocketPanel.show(nearPoint: point)
    }

    @objc private func clearPocket(_ sender: Any?) {
        pocketStore.clear()
    }

    // MARK: - Permissions and diagnostics

    /// The old flow dumped a paragraph of instructions into an NSAlert. A dedicated
    /// window can poll the real state and react the moment the switch flips.
    private func explainPermission() {
        showPermissionWindow(nil)
    }

    @objc private func showPermissionWindow(_ sender: Any?) {
        permissionWindow.show()
    }

    @objc private func openSettings(_ sender: Any?) {
        settingsWindow.show(page: 0)
    }

    @objc private func resetAccessibilityPermission() {
        let identifier = Bundle.main.bundleIdentifier ?? "com.zijin.FinderHoverPrototype"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "Accessibility", identifier]
        try? process.run()
        process.waitUntilExit()
        lastHit = nil
        gate.reset()
        updatePermission()
    }

    @objc private func saveDiagnostic(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        let picker = NSSavePanel()
        picker.nameFieldStringValue = "MacToolbox-诊断.json"
        picker.title = "保存 MacToolbox 诊断报告"
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
