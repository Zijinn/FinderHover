import AppKit
import ApplicationServices

struct FinderWindow {
    let element: AXUIElement?
    let title: String
    let minimized: Bool
}

struct DockItem {
    let element: AXUIElement
    let axFrame: CGRect
    let title: String
}

struct FocusResult {
    let success: Bool
    let message: String
}

final class AccessibilityService {
    static let finderPath = "/System/Library/CoreServices/Finder.app"
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

    private func application(_ identifier: String) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: identifier).first
    }

    private func dockApplication() -> AXUIElement? {
        guard let app = application("com.apple.dock") else { return nil }
        if app.processIdentifier != cachedDockPID || cachedDock == nil {
            cachedDockPID = app.processIdentifier
            cachedDock = AXUIElementCreateApplication(app.processIdentifier)
            if let dock = cachedDock { AXUIElementSetMessagingTimeout(dock, 0.15) }
        }
        return cachedDock
    }

    func windows() -> (windows: [FinderWindow], error: String?) {
        guard trusted else { return ([], "尚未授予辅助功能权限") }
        guard let finder = application("com.apple.finder") else {
            return ([], "访达未运行")
        }
        let app = AXUIElementCreateApplication(finder.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.3)
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        guard result == .success, let elements = value as? [AXUIElement] else {
            return ([], "读取访达窗口失败（AX \(result.rawValue)）")
        }
        let windows = elements.compactMap { element -> FinderWindow? in
            let role = text(element, kAXRoleAttribute)
            let subrole = text(element, kAXSubroleAttribute)
            guard role == kAXWindowRole,
                  subrole.isEmpty || subrole == kAXStandardWindowSubrole else { return nil }
            let title = text(element, kAXTitleAttribute).trimmingCharacters(in: .whitespacesAndNewlines)
            let minimized = attribute(element, kAXMinimizedAttribute) as? Bool ?? false
            return FinderWindow(element: element, title: title.isEmpty ? "未命名访达窗口" : title,
                                minimized: minimized)
        }
        return (windows, nil)
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

    private func finderItem(_ element: AXUIElement) -> DockItem? {
        let role = text(element, kAXRoleAttribute)
        let subrole = text(element, kAXSubroleAttribute)
        guard role == "AXDockItem" || subrole == "AXApplicationDockItem" else { return nil }
        let title = text(element, kAXTitleAttribute)
        let url = attribute(element, kAXURLAttribute) as? URL
        let localizedName = application("com.apple.finder")?.localizedName ?? "Finder"
        let knownName = ["Finder", "访达", "訪達", localizedName].contains(title)
        let correctURL = url?.standardizedFileURL.path == Self.finderPath
        guard correctURL || (url == nil && knownName), let frame = rect(element) else { return nil }
        return DockItem(element: element, axFrame: frame, title: title)
    }

    func finderItem(at point: CGPoint) -> DockItem? {
        guard trusted, let dock = dockApplication() else { return nil }
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(dock, Float(point.x), Float(point.y), &hit) == .success,
              var current = hit else { return nil }
        for _ in 0..<5 {
            if let item = finderItem(current) { return item }
            guard let parent = attribute(current, kAXParentAttribute),
                  CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            current = parent as! AXUIElement
        }
        return nil
    }

    func locateFinderItem() -> DockItem? {
        guard trusted, let dock = dockApplication() else { return nil }
        var remaining = 180
        func visit(_ element: AXUIElement, depth: Int) -> DockItem? {
            guard remaining > 0, depth <= 5 else { return nil }
            remaining -= 1
            if let match = finderItem(element) { return match }
            let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
            for child in children {
                if let match = visit(child, depth: depth + 1) { return match }
            }
            return nil
        }
        return visit(dock, depth: 0)
    }

    func focus(_ window: FinderWindow) -> FocusResult {
        guard trusted, let element = window.element,
              let finder = application("com.apple.finder") else {
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
        let activated = finder.activate(options: [])
        let main = AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        let focused = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        let raised = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        let success = activated && (raised == .success || main == .success || focused == .success)
        return FocusResult(success: success,
                           message: success ? "已切换到：\(window.title)" :
                            "窗口切换失败（激活 \(activated)，AXRaise \(raised.rawValue)）")
    }

    func isMain(_ window: FinderWindow) -> Bool {
        guard let element = window.element else { return false }
        return attribute(element, kAXMainAttribute) as? Bool ?? false
    }

    func diagnostic() -> [String: Any] {
        let result = windows()
        let item = locateFinderItem()
        var report: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "bundleIdentifier": Bundle.main.bundleIdentifier ?? "unbundled",
            "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "accessibilityTrusted": trusted,
            "finderRunning": application("com.apple.finder") != nil,
            "dockRunning": application("com.apple.dock") != nil,
            "windowCount": result.windows.count,
            "windows": result.windows.map { ["title": $0.title, "minimized": $0.minimized] as [String: Any] },
            "dockFinderItemFound": item != nil
        ]
        if let error = result.error { report["windowReadError"] = error }
        if let item = item {
            report["dockFinderTitle"] = item.title
            report["dockFinderAXFrame"] = ["x": item.axFrame.minX, "y": item.axFrame.minY,
                                           "width": item.axFrame.width, "height": item.axFrame.height]
        }
        return report
    }
}
