import AppKit
import QuartzCore

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class PassivePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class WindowRow: NSButton {
    let windowEntry: FinderWindow
    private let finderIcon: NSImage
    private var tracking: NSTrackingArea?
    private var hovered = false
    var onSelect: ((FinderWindow) -> Void)?

    init(entry: FinderWindow, icon: NSImage, frame: NSRect) {
        windowEntry = entry
        finderIcon = icon
        super.init(frame: frame)
        title = entry.title
        isBordered = false
        setButtonType(.momentaryChange)
        target = self
        action = #selector(selected)
        setAccessibilityLabel(entry.title + (entry.minimized ? "，已最小化" : ""))
        setAccessibilityHelp("点击切换到这个访达窗口")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking = tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        if hovered || isHighlighted {
            let highlight = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 0.16 : 0.07
            let color = isHighlighted ? NSColor.controlAccentColor.withAlphaComponent(0.18) :
                NSColor.labelColor.withAlphaComponent(highlight)
            color.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 0.5), xRadius: 15, yRadius: 15).fill()
        }
        finderIcon.draw(in: NSRect(x: 12, y: (bounds.height - 28) / 2, width: 28, height: 28))
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ]
        let labelY: CGFloat = windowEntry.minimized ? 23 : (bounds.height - 20) / 2
        (windowEntry.title as NSString).draw(in: NSRect(x: 52, y: labelY,
                                                       width: max(0, bounds.width - 82), height: 20),
                                            withAttributes: attributes)
        if windowEntry.minimized {
            ("已最小化" as NSString).draw(at: NSPoint(x: 52, y: 7), withAttributes: [
                .font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor
            ])
        }
        if hovered, let chevron = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
            chevron.withSymbolConfiguration(config)?.draw(in: NSRect(x: bounds.width - 23,
                                                                    y: (bounds.height - 11) / 2,
                                                                    width: 7, height: 11))
        }
    }

    @objc private func selected() { onSelect?(windowEntry) }
}

final class WindowListPanel {
    private(set) var panel: NSPanel
    private let backgroundPanel: NSPanel
    private(set) var entries: [FinderWindow] = []
    private(set) var isPreview = false
    private var rows: [WindowRow] = []
    private var animationEpoch = 0
    private var isDismissing = false
    private var materialImplementation = "uninitialized"
    private var interactiveGlass = false
    private var glassStyle = "uninitialized"
    private weak var backgroundSurface: NSView?
    private weak var foregroundContent: NSView?
    private(set) var configuredGlassStrength: CGFloat = {
        let defaults = UserDefaults.standard
        if let transparency = defaults.object(forKey: "glassTransparency") as? Double {
            return 1 - min(1, max(0, CGFloat(transparency / 100)))
        }
        if let legacyStrength = defaults.object(forKey: "glassBackgroundStrength") as? Double {
            return min(1, max(0, CGFloat(legacyStrength)))
        }
        return 0.28
    }()
    var configuredGlassTransparency: CGFloat { (1 - configuredGlassStrength) * 100 }
    private let rowPitch: CGFloat = 52
    var onSelect: ((FinderWindow) -> Void)?
    var isVisible: Bool { panel.isVisible && !isDismissing }
    var frame: NSRect { panel.frame }

    init() {
        panel = PassivePanel(contentRect: .zero,
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        backgroundPanel = PassivePanel(contentRect: .zero,
                                       styleMask: [.borderless, .nonactivatingPanel],
                                       backing: .buffered, defer: false)
        for window in [panel, backgroundPanel] {
            window.isReleasedWhenClosed = false
            window.backgroundColor = .clear
            window.isOpaque = false
            window.level = .popUpMenu
            window.hidesOnDeactivate = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.animationBehavior = .none
        }
        panel.hasShadow = false
        backgroundPanel.hasShadow = true
        backgroundPanel.ignoresMouseEvents = true
        panel.addChildWindow(backgroundPanel, ordered: .below)
        panel.setAccessibilityLabel("访达窗口列表")
    }

    func setAppearance(_ name: String) {
        switch name {
        case "dark": panel.appearance = NSAppearance(named: .darkAqua)
        case "light": panel.appearance = NSAppearance(named: .aqua)
        default: panel.appearance = nil
        }
        backgroundPanel.appearance = panel.appearance
    }

    private var effectiveGlassStrength: CGFloat {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ||
            NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast { return 1 }
        return configuredGlassStrength
    }

    func setGlassTransparency(_ value: CGFloat, persist: Bool = true) {
        let transparency = min(100, max(0, value))
        configuredGlassStrength = 1 - transparency / 100
        if persist { UserDefaults.standard.set(Double(transparency), forKey: "glassTransparency") }
        backgroundPanel.alphaValue = effectiveGlassStrength
    }

    private func glassSurface(content: NSView) -> NSView {
        let background: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: content.frame)
            glass.style = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? .regular : .clear
            glassStyle = glass.style == .clear ? "clear" : "regular"
            glass.cornerRadius = 24
            glass.tintColor = nil
            if #available(macOS 27.0, *) {
                glass.effectIsInteractive = true
                interactiveGlass = true
            }
            glass.contentView = NSView(frame: content.bounds)
            materialImplementation = "NSGlassEffectView"
            background = glass
        } else {
            let fallback = NSVisualEffectView(frame: content.frame)
            fallback.material = .popover
            fallback.blendingMode = .behindWindow
            fallback.state = .active
            fallback.wantsLayer = true
            fallback.layer?.cornerRadius = 24
            fallback.layer?.masksToBounds = true
            fallback.layer?.borderWidth = 0.5
            fallback.layer?.borderColor = NSColor.separatorColor.cgColor
            if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
                fallback.blendingMode = .withinWindow
                fallback.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            }
            materialImplementation = "NSVisualEffectView-fallback"
            interactiveGlass = false
            glassStyle = "popover-fallback"
            background = fallback
        }
        // WindowServer opacity controls only the glass window. Foreground
        // controls stay in a separate, fully opaque window above it.
        background.autoresizingMask = [.width, .height]
        background.setAccessibilityElement(false)
        content.alphaValue = 1
        content.autoresizingMask = [.width, .height]
        backgroundPanel.contentView = background
        backgroundSurface = background
        foregroundContent = content
        return content
    }

    func show(entries: [FinderWindow], icon: NSRect, screen: NSScreen,
              edge: DockEdge, preview: Bool = false, message: String? = nil) {
        let alreadyVisible = isVisible
        animationEpoch += 1
        isDismissing = false
        self.entries = entries
        self.isPreview = preview
        rows.removeAll()
        let textFont = NSFont.systemFont(ofSize: 14, weight: .medium)
        let longestTitle = entries.map {
            ($0.title as NSString).size(withAttributes: [.font: textFont]).width
        }.max() ?? 180
        let width = min(max(300, min(380, longestTitle + 112)), screen.visibleFrame.width - 16)
        let maxHeight = max(110, min(620, screen.visibleFrame.height * 0.72))
        let listHeight = min(max(rowPitch, CGFloat(entries.count) * rowPitch), maxHeight - 54)
        let size = NSSize(width: width, height: listHeight + 54)
        let content = NSView(frame: NSRect(origin: .zero, size: size))
        let heading = NSTextField(labelWithString: preview ? "访达 · 示例预览" : "访达")
        heading.font = .systemFont(ofSize: 12, weight: .semibold)
        heading.textColor = .secondaryLabelColor
        heading.frame = NSRect(x: 20, y: size.height - 32, width: width - 116, height: 17)
        content.addSubview(heading)
        let count = NSTextField(labelWithString: "\(entries.count) 个窗口")
        count.font = .systemFont(ofSize: 11, weight: .medium)
        count.textColor = .secondaryLabelColor
        count.alignment = .right
        count.frame = NSRect(x: width - 92, y: size.height - 32, width: 72, height: 17)
        content.addSubview(count)

        let scroll = NSScrollView(frame: NSRect(x: 8, y: 8, width: width - 16, height: listHeight))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = CGFloat(entries.count) * rowPitch > listHeight
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        let document = FlippedView(frame: NSRect(x: 0, y: 0, width: width - 16,
                                                 height: max(listHeight, CGFloat(entries.count) * rowPitch)))
        let finderIcon = NSWorkspace.shared.icon(forFile: AccessibilityService.finderPath)
        for (index, entry) in entries.enumerated() {
            let row = WindowRow(entry: entry, icon: finderIcon,
                                frame: NSRect(x: 0, y: CGFloat(index) * rowPitch + 2,
                                              width: width - 16, height: rowPitch - 4))
            row.onSelect = { [weak self] entry in self?.onSelect?(entry) }
            document.addSubview(row)
            rows.append(row)
        }
        if entries.isEmpty {
            let empty = NSTextField(wrappingLabelWithString: message ?? "没有打开的访达窗口")
            empty.font = .systemFont(ofSize: 13)
            empty.textColor = .secondaryLabelColor
            empty.frame = NSRect(x: 12, y: 12, width: width - 40, height: 36)
            document.addSubview(empty)
        }
        scroll.documentView = document
        content.addSubview(scroll)
        panel.contentView = glassSurface(content: content)
        panel.setFrame(PanelGeometry.frame(size: size, icon: icon,
                                           visibleScreen: screen.visibleFrame, edge: edge), display: true)
        backgroundPanel.setFrame(panel.frame, display: true)
        if !alreadyVisible && !panel.isVisible {
            panel.alphaValue = 0
            backgroundPanel.alphaValue = 0
        }
        panel.orderFrontRegardless()
        backgroundPanel.order(.below, relativeTo: panel.windowNumber)
        panel.displayIfNeeded()
        backgroundPanel.displayIfNeeded()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            backgroundPanel.animator().alphaValue = effectiveGlassStrength
        }
    }

    func hide() {
        guard panel.isVisible && !isDismissing else { return }
        animationEpoch += 1
        let epoch = animationEpoch
        isDismissing = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.10
            panel.animator().alphaValue = 0
            backgroundPanel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self = self, self.animationEpoch == epoch else { return }
            self.panel.orderOut(nil)
            self.backgroundPanel.orderOut(nil)
            self.backgroundPanel.alphaValue = self.effectiveGlassStrength
            self.panel.alphaValue = 1
            self.isDismissing = false
        })
    }

    func renderPNG(to url: URL) throws -> [String: Any] {
        guard let view = panel.contentView, let glass = backgroundPanel.contentView else {
            throw NSError(domain: "FinderHover", code: 1)
        }
        view.layoutSubtreeIfNeeded()
        glass.layoutSubtreeIfNeeded()
        guard let foregroundBitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds),
              let backgroundBitmap = glass.bitmapImageRepForCachingDisplay(in: glass.bounds),
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                  pixelsWide: foregroundBitmap.pixelsWide, pixelsHigh: foregroundBitmap.pixelsHigh,
                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw NSError(domain: "FinderHover", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "无法生成界面预览"])
        }
        foregroundBitmap.bitmapData?.initialize(repeating: 0,
            count: foregroundBitmap.bytesPerRow * foregroundBitmap.pixelsHigh)
        view.cacheDisplay(in: view.bounds, to: foregroundBitmap)
        glass.cacheDisplay(in: glass.bounds, to: backgroundBitmap)
        bitmap.size = view.bounds.size
        // Export the two view caches with the same alpha as the live windows;
        // this is a deterministic composition, not a desktop screenshot.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.clear(CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
        context.cgContext.scaleBy(x: CGFloat(bitmap.pixelsWide) / view.bounds.width,
                                  y: CGFloat(bitmap.pixelsHigh) / view.bounds.height)
        context.cgContext.setAlpha(backgroundPanel.alphaValue)
        backgroundBitmap.draw(in: view.bounds)
        context.cgContext.setAlpha(1)
        foregroundBitmap.draw(in: view.bounds)
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "FinderHover", code: 3)
        }
        try png.write(to: url, options: .atomic)
        let scaleX = CGFloat(bitmap.pixelsWide) / view.bounds.width
        let scaleY = CGFloat(bitmap.pixelsHigh) / view.bounds.height
        let backgroundPoints = [CGPoint(x: view.bounds.midX, y: 6),
                                CGPoint(x: view.bounds.width - 16, y: view.bounds.midY),
                                CGPoint(x: view.bounds.midX, y: view.bounds.height - 6)]
        let backgroundAlphaSamples = backgroundPoints.map { point in
            bitmap.colorAt(x: Int(point.x * scaleX), y: Int(point.y * scaleY))?.alphaComponent ?? -1
        }
        let foregroundBackgroundAlphaSamples = backgroundPoints.map { point in
            foregroundBitmap.colorAt(x: Int(point.x * scaleX), y: Int(point.y * scaleY))?.alphaComponent ?? -1
        }
        var iconPeakAlpha: CGFloat = 0
        if let row = rows.first {
            let icon = row.convert(NSRect(x: 12, y: (row.bounds.height - 28) / 2,
                                          width: 28, height: 28), to: view)
            let left = max(0, Int(icon.minX * scaleX))
            let right = min(bitmap.pixelsWide, Int(icon.maxX * scaleX))
            let top = max(0, Int((view.bounds.height - icon.maxY) * scaleY))
            let bottom = min(bitmap.pixelsHigh, Int((view.bounds.height - icon.minY) * scaleY))
            for x in left..<right {
                for y in top..<bottom {
                    iconPeakAlpha = max(iconPeakAlpha, bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0)
                }
            }
        }
        let serverWindows = CGWindowListCopyWindowInfo(.optionIncludingWindow,
            CGWindowID(backgroundPanel.windowNumber)) as? [[String: Any]] ?? []
        let serverBackgroundAlpha = (serverWindows.first?[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? -1
        return ["rowCount": rows.count, "panelWidth": view.bounds.width,
                "panelHeight": view.bounds.height, "rowPitch": rowPitch,
                "allRowsFitDocument": rows.allSatisfy { row in
                    guard let parent = row.superview else { return false }
                    return parent.bounds.contains(row.frame)
                }, "pngBytes": png.count,
                "previewUsesSampleData": isPreview,
                "materialImplementation": materialImplementation,
                "configuredGlassTransparency": configuredGlassTransparency,
                "nativeLiquidGlass": materialImplementation == "NSGlassEffectView",
                "macOS27InteractiveGlass": interactiveGlass,
                "glassStyle": glassStyle,
                "backgroundOpacity": backgroundPanel.alphaValue,
                "windowServerBackgroundAlpha": serverBackgroundAlpha,
                "viewCacheIncludesDynamicBackdrop": false,
                "configuredGlassStrength": configuredGlassStrength,
                "foregroundOpacity": foregroundContent?.alphaValue ?? -1,
                "separateBackgroundAndForeground": backgroundSurface?.window === backgroundPanel &&
                    foregroundContent?.window === panel && backgroundPanel.parent === panel,
                "backgroundFrameMatchesForeground": backgroundPanel.frame == panel.frame,
                "backgroundIgnoresMouseEvents": backgroundPanel.ignoresMouseEvents,
                "backgroundWindowVisible": backgroundPanel.isVisible,
                "cachedForegroundBackgroundAlphaSamples": foregroundBackgroundAlphaSamples,
                "cachedBackgroundAlphaSamples": backgroundAlphaSamples,
                "cachedIconPeakAlpha": iconPeakAlpha,
                "systemIncreasedContrast": NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast,
                "appearance": panel.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])?.rawValue ?? "unknown",
                "systemReducedTransparency": NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
                "systemReducedMotion": NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                "requiresScreenRecording": false,
                "captureKind": "explicit-two-window-composition-not-desktop-compositor"]
    }
}
