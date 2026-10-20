import AppKit

/// First-run permission guide. Replaces the old wall-of-text NSAlert: three short
/// steps, a live status pill, and a button that opens the exact settings pane.
///
/// macOS never lets a process write the TCC database, so this window cannot grant
/// the permission itself. What it can do is make the one manual step obvious and
/// detect the result the moment the switch flips.
final class PermissionWindowController: NSObject, NSWindowDelegate {
    private let service: AccessibilityService

    private var window: NSWindow?
    private var statusPill: StatusPillView?
    private var subtitleLabel: NSTextField?
    private var tipBox: RoundedBackgroundView?
    private var tipIcon: NSImageView?
    private var tipLabel: NSTextField?
    private var primaryButton: NSButton?
    private var pollTimer: Timer?
    private var lastTrusted = false
    private var closeScheduled = false
    private var didReset = false
    private var duplicates: [String] = []

    /// Called once when the permission flips to granted while this window is open.
    var onTrusted: (() -> Void)?

    private let contentSize = NSSize(width: 560, height: 462)

    init(service: AccessibilityService) {
        self.service = service
        super.init()
    }

    var isVisible: Bool { window?.isVisible ?? false }
    var frame: NSRect { window?.frame ?? .zero }

    /// Running straight out of a mounted DMG puts the app under a randomised
    /// `/AppTranslocation/` path. TCC records that path, so the grant silently
    /// dies the next time the app is launched from the disk image.
    var isTranslocated: Bool { AppInstallation.isTranslocated }

    // MARK: - Presentation

    func show() {
        let window = ensureWindow()
        duplicates = AppInstallation.duplicateCopies()
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
        startPolling()
    }

    func close() {
        stopPolling()
        window?.orderOut(nil)
    }

    private func ensureWindow() -> NSWindow {
        if let window = window { return window }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: contentSize),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "辅助功能权限"
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.delegate = self
        window.backgroundColor = .windowBackgroundColor

        let root = FlippedContainerView(frame: NSRect(origin: .zero, size: contentSize))
        window.contentView = root
        buildContent(in: root)
        self.window = window
        return window
    }

    private func buildContent(in root: NSView) {
        let iconView = NSImageView(frame: NSRect(x: 28, y: 24, width: 48, height: 48))
        iconView.image = NSApp.applicationIconImage
        iconView.imageScaling = .scaleProportionallyUpOrDown
        root.addSubview(iconView)

        root.addSubview(UIKitBits.label("开启辅助功能权限", size: 15, weight: .semibold,
                                        frame: NSRect(x: 90, y: 26, width: 320, height: 20)))

        let pill = StatusPillView(frame: NSRect(x: 0, y: 27, width: 80, height: 22))
        pill.text = "未授权"
        root.addSubview(pill)
        statusPill = pill

        let subtitle = UIKitBits.paragraph(
            "读取和切换窗口需要这项系统权限。临时口袋与快捷键不需要，可以先直接用。",
            size: 13, color: .secondaryLabelColor,
            frame: NSRect(x: 90, y: 50, width: 442, height: 36), lines: 2)
        root.addSubview(subtitle)
        subtitleLabel = subtitle

        let steps = [
            ("打开系统设置的辅助功能面板", "点下方按钮，会直接跳到「隐私与安全性 → 辅助功能」。"),
            ("把 \(AppInstallation.fileName) 拖进列表",
             "点「在访达中显示」定位到这一份应用，拖进设置列表即可；列表里显示的名称是 \(AppInstallation.listName)。"),
            ("回到这里，无需重启", "窗口会实时检测授权状态，成功后自动变成「已授权」并关闭。")
        ]
        for (offset, step) in steps.enumerated() {
            let row = stepRow(index: offset + 1, title: step.0, detail: step.1,
                              y: CGFloat(104 + offset * 58))
            root.addSubview(row)
        }

        // Which copy is asking. Without this the user cannot tell our entry apart
        // from the other installs, and toggling the wrong one changes nothing.
        root.addSubview(UIKitBits.label("当前程序", size: 11, color: .secondaryLabelColor,
                                        frame: NSRect(x: 28, y: 286, width: 56, height: 16)))
        let pathLabel = UIKitBits.label(AppInstallation.path, size: 10, color: .tertiaryLabelColor,
                                        frame: NSRect(x: 88, y: 285, width: 372, height: 16))
        pathLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        pathLabel.lineBreakMode = .byTruncatingMiddle
        root.addSubview(pathLabel)

        let copy = NSButton(title: "复制路径", target: self, action: #selector(copyPath))
        copy.bezelStyle = .inline
        copy.isBordered = false
        copy.font = .systemFont(ofSize: 11)
        copy.contentTintColor = .controlAccentColor
        copy.frame = NSRect(x: 466, y: 281, width: 62, height: 22)
        root.addSubview(copy)

        let tip = RoundedBackgroundView(frame: NSRect(x: 28, y: 316, width: 504, height: 60))
        tip.cornerRadius = 8
        tip.fillColor = .quaternaryLabelColor
        root.addSubview(tip)
        tipBox = tip

        let icon = NSImageView(frame: NSRect(x: 12, y: 11, width: 14, height: 14))
        icon.image = UIKitBits.symbol("info.circle", pointSize: 11)
        icon.contentTintColor = .secondaryLabelColor
        tip.addSubview(icon)
        tipIcon = icon

        let tipText = UIKitBits.paragraph("", size: 12, color: .secondaryLabelColor,
                                          frame: NSRect(x: 32, y: 8, width: 456, height: 44), lines: 3)
        tip.addSubview(tipText)
        tipLabel = tipText

        root.addSubview(UIKitBits.separator(frame: NSRect(x: 28, y: 392, width: 504, height: 1)))

        let primary = NSButton(title: "打开辅助功能设置", target: self, action: #selector(primaryAction))
        primary.bezelStyle = .rounded
        primary.bezelColor = .controlAccentColor
        primary.keyEquivalent = "\r"
        primary.frame = NSRect(x: 28, y: 408, width: 140, height: 30)
        root.addSubview(primary)
        primaryButton = primary

        let reveal = NSButton(title: "在访达中显示", target: self, action: #selector(revealInFinder))
        reveal.bezelStyle = .rounded
        reveal.frame = NSRect(x: 176, y: 408, width: 118, height: 30)
        root.addSubview(reveal)

        let reset = NSButton(title: "重置权限", target: self, action: #selector(resetPermission))
        reset.bezelStyle = .inline
        reset.isBordered = false
        reset.contentTintColor = .secondaryLabelColor
        reset.font = .systemFont(ofSize: 12)
        reset.frame = NSRect(x: 306, y: 412, width: 74, height: 24)
        reset.setAccessibilityHelp("从系统设置中移除本应用的辅助功能授权，用于修复开关变灰或授权失效")
        root.addSubview(reset)

        let later = NSButton(title: "稍后", target: self, action: #selector(dismiss))
        later.bezelStyle = .inline
        later.isBordered = false
        later.contentTintColor = .secondaryLabelColor
        later.font = .systemFont(ofSize: 13)
        later.frame = NSRect(x: 470, y: 412, width: 60, height: 24)
        root.addSubview(later)
    }

    private func stepRow(index: Int, title: String, detail: String, y: CGFloat) -> NSView {
        let container = FlippedContainerView(frame: NSRect(x: 28, y: y, width: 504, height: 56))

        let badge = RoundedBackgroundView(frame: NSRect(x: 0, y: 1, width: 22, height: 22))
        badge.cornerRadius = 11
        badge.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.14)
        let number = UIKitBits.label("\(index)", size: 12, weight: .medium, color: .controlAccentColor,
                                     frame: NSRect(x: 0, y: 4, width: 22, height: 16))
        number.alignment = .center
        badge.addSubview(number)
        container.addSubview(badge)

        container.addSubview(UIKitBits.label(title, size: 13, weight: .medium,
                                             frame: NSRect(x: 34, y: 0, width: 470, height: 18)))
        container.addSubview(UIKitBits.paragraph(detail, size: 12, color: .secondaryLabelColor,
                                                 frame: NSRect(x: 34, y: 21, width: 470, height: 32),
                                                 lines: 2))
        return container
    }

    // MARK: - State

    private func refresh() {
        let trusted = service.trusted
        let flippedToTrusted = trusted && !lastTrusted
        lastTrusted = trusted

        statusPill?.text = trusted ? "已授权" : "未授权"
        statusPill?.tint = trusted ? .systemGreen : .systemOrange
        if let pill = statusPill {
            let width = pill.intrinsicContentSize.width
            pill.frame = NSRect(x: 532 - width, y: 27, width: width, height: 22)
        }

        subtitleLabel?.stringValue = trusted
            ? "权限已生效，把鼠标停在 Dock 图标上就能看到窗口列表。"
            : "读取和切换窗口需要这项系统权限。临时口袋与快捷键不需要，可以先直接用。"

        primaryButton?.title = trusted ? "完成" : "打开辅助功能设置"
        primaryButton?.keyEquivalent = trusted ? "\r" : "\r"

        if let tipBox = tipBox, let tipLabel = tipLabel, let tipIcon = tipIcon {
            let warning = isTranslocated || AppInstallation.isAdHocSigned || !duplicates.isEmpty || didReset
            if isTranslocated {
                tipLabel.stringValue = "当前从磁盘映像运行。授权会绑定到临时路径，退出后失效 —— 请先把 \(AppInstallation.fileName) 拖到「应用程序」文件夹，再从那里打开。"
            } else if AppInstallation.isAdHocSigned {
                tipLabel.stringValue = "当前副本是 ad-hoc 签名，没有固定身份：授权绑定在文件哈希上，重新安装或更新后就会失效。请使用带证书签名的构建版本。"
            } else if !duplicates.isEmpty {
                let names = duplicates.map { ($0 as NSString).lastPathComponent }.joined(separator: "、")
                tipLabel.stringValue = "检测到另外 \(duplicates.count) 份副本：\(names)。辅助功能按路径授权，只有上面「当前程序」这一份的开关有效。"
            } else if didReset {
                tipLabel.stringValue = "已重置。列表里的旧条目已移除，请重新添加 \(AppInstallation.fileName) 并打开开关。"
            } else if trusted {
                tipLabel.stringValue = "已完成。窗口切换现在可用，无需重启应用。"
            } else {
                tipLabel.stringValue = "列表里已有 \(AppInstallation.listName) 但开关是灰的？先点「−」移除，再重新添加一次。"
            }
            tipLabel.textColor = .secondaryLabelColor
            tipBox.fillColor = warning ? NSColor.systemOrange.withAlphaComponent(0.08)
                : trusted ? NSColor.systemGreen.withAlphaComponent(0.10) : .quaternaryLabelColor
            tipIcon.image = UIKitBits.symbol(warning ? "exclamationmark.triangle.fill"
                                             : trusted ? "checkmark.circle.fill" : "info.circle",
                                             pointSize: 11)
            tipIcon.contentTintColor = warning ? .systemOrange : trusted ? .systemGreen : .secondaryLabelColor
        }

        if flippedToTrusted {
            onTrusted?()
            if !closeScheduled {
                closeScheduled = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
                    self?.close()
                }
            }
        }
    }

    // MARK: - Actions

    @objc private func primaryAction() {
        if service.trusted {
            close()
            return
        }
        // Ask the system first: this is what registers the app in the Accessibility
        // list, so the user only has to flip a switch instead of hunting for the app.
        service.requestPermission()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    @objc private func copyPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(AppInstallation.path, forType: .string)
    }

    @objc private func resetPermission() {
        let identifier = Bundle.main.bundleIdentifier ?? "com.zijin.FinderHoverPrototype"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "Accessibility", identifier]
        do {
            try process.run()
            process.waitUntilExit()
            didReset = process.terminationStatus == 0
        } catch {
            didReset = false
        }
        refresh()
    }

    @objc private func dismiss() {
        close()
    }

    // MARK: - Polling

    private func startPolling() {
        stopPolling()
        let timer = Timer(timeInterval: 0.6, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func windowWillClose(_ notification: Notification) {
        stopPolling()
    }

    // MARK: - Render evidence

    func renderPNG(to url: URL) -> [String: Any] {
        guard let window = window, let view = window.contentView else { return ["error": "无窗口"] }
        view.layoutSubtreeIfNeeded()
        guard let cache = view.bitmapImageRepForCachingDisplay(in: view.bounds),
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                                            pixelsWide: cache.pixelsWide, pixelsHigh: cache.pixelsHigh,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                            isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            return ["error": "无法创建渲染上下文"]
        }
        view.cacheDisplay(in: view.bounds, to: cache)
        bitmap.size = view.bounds.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: CGFloat(bitmap.pixelsWide) / view.bounds.width,
                                  y: CGFloat(bitmap.pixelsHigh) / view.bounds.height)
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            NSBezierPath(rect: view.bounds).fill()
            let image = NSImage(size: view.bounds.size)
            image.addRepresentation(cache)
            image.draw(in: view.bounds, from: .zero, operation: .sourceOver, fraction: 1)
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            return ["error": "无法编码 PNG"]
        }
        try? png.write(to: url, options: .atomic)
        return ["pngBytes": png.count,
                "width": Int(view.bounds.width), "height": Int(view.bounds.height),
                "pixelsWide": bitmap.pixelsWide, "pixelsHigh": bitmap.pixelsHigh,
                "trusted": service.trusted, "translocated": isTranslocated,
                "appearance": NSApp.effectiveAppearance.name.rawValue]
    }
}
