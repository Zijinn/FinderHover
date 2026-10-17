import AppKit
import ApplicationServices

struct FocusResult {
    let success: Bool
    let message: String
}

/// A Dock item that names an application which is currently running, resolved to
/// the process whose windows we can list and focus.
struct DockAppHit {
    let element: AXUIElement
    let axFrame: CGRect
    let bundleIdentifier: String
    let pid: pid_t
    let displayName: String
    let url: URL
}

struct WindowReadout {
    let windows: [AppWindow]
    let switchableCount: Int
    let omittedCount: Int
    let error: String?

    static let unavailable = WindowReadout(windows: [], switchableCount: 0, omittedCount: 0,
                                           error: "尚未授予辅助功能权限")
}

final class AccessibilityService {
    var trusted: Bool { AXIsProcessTrusted() }
    private var cachedDockPID: pid_t = 0
    private var cachedDock: AXUIElement?

    func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private func text(_ element: AXUIElement, _ name: String) -> String {
        attribute(element, name) as? String ?? ""
    }

    private func children(_ element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    private func rect(_ element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute),
              let size = attribute(element, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(),
              CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions),
              dimensions.width > 0, dimensions.height > 0 else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    private func dockApplication() -> AXUIElement? {
        guard let dock = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
        if dock.processIdentifier != cachedDockPID || cachedDock == nil {
            cachedDockPID = dock.processIdentifier
            cachedDock = AXUIElementCreateApplication(dock.processIdentifier)
            if let dock = cachedDock { AXUIElementSetMessagingTimeout(dock, 0.15) }
        }
        return cachedDock
    }

    // MARK: - Dock item identification

    private func facts(_ element: AXUIElement) -> DockItemFacts {
        let url = attribute(element, kAXURLAttribute) as? URL
        let path = url?.standardizedFileURL.path
        return DockItemFacts(role: text(element, kAXRoleAttribute),
                             subrole: text(element, kAXSubroleAttribute),
                             urlPath: path,
                             title: text(element, kAXTitleAttribute),
                             bundleIdentifier: url.flatMap { Bundle(url: $0)?.bundleIdentifier })
    }

    /// A Dock item only becomes usable once it names an installed bundle that is
    /// running; pinned-but-quit icons and stacks resolve to nothing here.
    private func hit(_ element: AXUIElement, facts itemFacts: DockItemFacts? = nil) -> DockAppHit? {
        let facts = itemFacts ?? self.facts(element)
        guard DockItemClassifier.classify(facts) == .application,
              let frame = rect(element) else { return nil }
        let running: NSRunningApplication?
        if let identifier = facts.bundleIdentifier {
            running = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).first
        } else {
            let title = facts.title.trimmingCharacters(in: .whitespacesAndNewlines)
            running = NSWorkspace.shared.runningApplications.first {
                $0.activationPolicy == .regular && $0.localizedName == title
            }
        }
        guard let app = running, let url = app.bundleURL,
              let identifier = app.bundleIdentifier else { return nil }
        return DockAppHit(element: element, axFrame: frame, bundleIdentifier: identifier,
                          pid: app.processIdentifier,
                          displayName: app.localizedName ?? facts.title, url: url)
    }

    private func dockItemElements(_ dock: AXUIElement) -> [AXUIElement] {
        var found: [AXUIElement] = []
        var remaining = 900
        func visit(_ element: AXUIElement, depth: Int) {
            guard remaining > 0, depth <= 5 else { return }
            remaining -= 1
            if text(element, kAXRoleAttribute) == kAXDockItemRole { found.append(element) }
            else { children(element).forEach { visit($0, depth: depth + 1) } }
        }
        visit(dock, depth: 0)
        return found
    }

    func appItem(at point: CGPoint) -> DockAppHit? {
        guard trusted, let dock = dockApplication() else { return nil }
        var direct: AXUIElement?
        if AXUIElementCopyElementAtPosition(dock, Float(point.x), Float(point.y), &direct) == .success,
           var current = direct {
            for _ in 0..<5 {
                if let hit = hit(current) { return hit }
                guard let parent = attribute(current, kAXParentAttribute),
                      CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
                current = parent as! AXUIElement
            }
        }
        // Dock magnification relays out icons while the cursor sits on one, so the
        // position query above can miss; fall back to matching each item's own frame.
        for element in dockItemElements(dock) {
            guard rect(element).map({ $0.contains(point) }) == true else { continue }
            if let hit = hit(element) { return hit }
        }
        return nil
    }

    func appItem(bundleIdentifier: String) -> DockAppHit? {
        guard trusted, let dock = dockApplication() else { return nil }
        for element in dockItemElements(dock) where facts(element).bundleIdentifier == bundleIdentifier {
            if let hit = hit(element) { return hit }
        }
        return nil
    }

    /// Dock items the user can hover over right now, for the enabled-app picker.
    func currentDockAppItems() -> [DockAppHit] {
        guard trusted, let dock = dockApplication() else { return [] }
        var seen = Set<String>()
        return dockItemElements(dock).compactMap { element -> DockAppHit? in
            guard let hit = hit(element), !seen.contains(hit.bundleIdentifier) else { return nil }
            seen.insert(hit.bundleIdentifier)
            return hit
        }
    }

    // MARK: - Windows

    private func windowFacts(_ elements: [AXUIElement]) -> [WindowFacts] {
        elements.enumerated().map { index, element in
            let frame = rect(element) ?? .zero
            return WindowFacts(index: index,
                               role: text(element, kAXRoleAttribute),
                               subrole: text(element, kAXSubroleAttribute),
                               title: text(element, kAXTitleAttribute),
                               minimized: attribute(element, kAXMinimizedAttribute) as? Bool ?? false,
                               isMain: attribute(element, kAXMainAttribute) as? Bool ?? false,
                               isFocused: attribute(element, kAXFocusedAttribute) as? Bool ?? false,
                               width: frame.width, height: frame.height)
        }
    }

    func windows(of app: DockAppHit, config: AppWindowConfig) -> WindowReadout {
        guard trusted else { return .unavailable }
        let element = AXUIElementCreateApplication(app.pid)
        AXUIElementSetMessagingTimeout(element, 0.3)
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value)
        guard result == .success, let elements = value as? [AXUIElement] else {
            return WindowReadout(windows: [], switchableCount: 0, omittedCount: 0,
                                 error: "读取 \(app.displayName) 窗口失败（AX \(result.rawValue)）")
        }
        let presentation = WindowPresentationRules.present(windowFacts(elements), config: config)
        let windows = presentation.rows.compactMap { row -> AppWindow? in
            guard elements.indices.contains(row.sourceIndex) else { return nil }
            return AppWindow(element: elements[row.sourceIndex], displayTitle: row.displayTitle,
                             minimized: row.minimized, isMain: row.isMain)
        }
        return WindowReadout(windows: windows, switchableCount: presentation.switchableCount,
                             omittedCount: presentation.omittedCount, error: nil)
    }

    /// Windows of the application currently in front, used by the manual menu entry
    /// when the pointer is nowhere near the Dock. `axFrame` stays empty because no
    /// Dock item backs it, and the caller then falls back to its own anchor.
    func frontmostAppWindows(config: AppWindowConfig) -> (hit: DockAppHit, readout: WindowReadout)? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let identifier = app.bundleIdentifier,
              let url = app.bundleURL else { return nil }
        let hit = DockAppHit(element: AXUIElementCreateApplication(app.processIdentifier),
                             axFrame: .zero, bundleIdentifier: identifier,
                             pid: app.processIdentifier,
                             displayName: app.localizedName ?? identifier, url: url)
        return (hit, windows(of: hit, config: config))
    }

    func focus(_ window: AppWindow, in app: DockAppHit) -> FocusResult {
        guard trusted, let element = window.element,
              let running = NSRunningApplication(processIdentifier: app.pid) else {
            return FocusResult(success: false, message: "缺少辅助功能权限或窗口已失效")
        }
        var probe: CFTypeRef?
        let probeResult = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &probe)
        guard probeResult == .success else {
            return FocusResult(success: false, message: "窗口已关闭，请重新展开列表")
        }
        if attribute(element, kAXMinimizedAttribute) as? Bool == true {
            let restored = AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString,
                                                        kCFBooleanFalse)
            guard restored == .success else {
                return FocusResult(success: false, message: "无法恢复最小化窗口（AX \(restored.rawValue)）")
            }
        }
        let activated = running.activate(options: [])
        let main = AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        let focused = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        let raised = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        let success = activated && (raised == .success || main == .success || focused == .success)
        return FocusResult(success: success,
                           message: success ? "已切换到：\(app.displayName) · \(window.displayTitle)" :
                            "窗口切换失败（激活 \(activated)，AXRaise \(raised.rawValue)）")
    }

    func isMain(_ window: AppWindow) -> Bool {
        guard let element = window.element else { return false }
        return attribute(element, kAXMainAttribute) as? Bool ?? false
    }

    // MARK: - Diagnostics

    func diagnostic(settings: SettingsStore, managedApps: [ManagedApp]) -> [String: Any] {
        let dockItems = currentDockAppItems()
        let enabled = managedApps.filter { $0.isEnabled }
        var perApp: [[String: Any]] = []
        for app in enabled {
            guard let item = dockItems.first(where: { $0.bundleIdentifier == app.bundleIdentifier }) else {
                perApp.append(["bundleIdentifier": app.bundleIdentifier, "name": app.displayName,
                               "inDock": false])
                continue
            }
            let readout = windows(of: item, config: app.config)
            var entry: [String: Any] = ["bundleIdentifier": app.bundleIdentifier,
                                        "name": app.displayName, "inDock": true,
                                        "switchableWindowCount": readout.switchableCount,
                                        "listedWindowCount": readout.windows.count]
            if let error = readout.error { entry["error"] = error }
            if !readout.windows.isEmpty {
                entry["firstTitles"] = readout.windows.prefix(3).map { $0.displayTitle }
            }
            perApp.append(entry)
        }
        let report: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "bundleIdentifier": Bundle.main.bundleIdentifier ?? "unbundled",
            "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "accessibilityTrusted": trusted,
            "dockRunning": NSRunningApplication
                .runningApplications(withBundleIdentifier: "com.apple.dock").first != nil,
            "windowSwitcherEnabled": settings.isToolEnabled(.windowSwitcher),
            "pocketEnabled": settings.isToolEnabled(.pocket),
            "dockAppItemCount": dockItems.count,
            "dockApps": dockItems.map { ["bundleIdentifier": $0.bundleIdentifier, "name": $0.displayName] },
            "managedAppCount": managedApps.count,
            "enabledAppCount": enabled.count,
            "enabledApps": perApp
        ]
        return report
    }
}
