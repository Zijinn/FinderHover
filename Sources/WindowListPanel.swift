import AppKit
import QuartzCore

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class PassivePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Everything the panel needs to know about which application it is currently
/// presenting. It never resolves this itself, so the panel is not tied to Finder.
struct PanelAppContext {
    let appName: String
    let bundleIdentifier: String?
    let icon: NSImage
    let switchableCount: Int
    let omittedCount: Int
}

final class WindowRow: NSButton {
    let windowEntry: AppWindow
    private let displayIcon: NSImage
    let titleFont: NSFont
    private let iconEdge: CGFloat
    private var appliedCornerRadius: CGFloat
    private var tracking: NSTrackingArea?
    private var hovered = false
    var onSelect: ((AppWindow) -> Void)?

    var rowPitch: CGFloat { bounds.height + 4 }
    var titleText: String { windowEntry.displayTitle }
    var iconRect: NSRect {
        NSRect(x: 12, y: (bounds.height - iconEdge) / 2, width: iconEdge, height: iconEdge)
    }

    init(entry: AppWindow, icon: NSImage, titleFontSize: CGFloat,
         cornerRadius: CGFloat, frame: NSRect) {
        windowEntry = entry
        displayIcon = icon
        titleFont = NSFont.systemFont(ofSize: titleFontSize, weight: .medium)
        iconEdge = min(28, max(18, titleFontSize + 14))
        appliedCornerRadius = cornerRadius
        super.init(frame: frame)
        title = entry.displayTitle
        isBordered = false
        setButtonType(.momentaryChange)
        target = self
        action = #selector(selected)
        setAccessibilityLabel(entry.displayTitle + (entry.minimized ? "，已最小化" : ""))
        setAccessibilityHelp("点击切换到这个窗口")
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
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 0.5),
                         xRadius: appliedCornerRadius, yRadius: appliedCornerRadius).fill()
        }
        displayIcon.draw(in: iconRect)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        let attributes: [NSAttributedString.Key: Any] = [
            .font: titleFont,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ]
        let textHeight = ceil(titleFont.boundingRectForFont.height)
        let labelY: CGFloat = windowEntry.minimized ? 23 : (bounds.height - textHeight) / 2
        (titleText as NSString).draw(in: NSRect(x: 52, y: labelY,
                                                width: max(0, bounds.width - 82), height: textHeight),
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
    // Foreground window is always opaque and only carries text/icons/controls;
    // glass lives in a separate background window whose WindowServer alpha we drive.
    private(set) var panel: NSPanel
    private let backgroundPanel: NSPanel
    private(set) var entries: [AppWindow] = []
    private(set) var isPreview = false
    private var context = PanelAppContext(appName: "访达", bundleIdentifier: nil,
                                          icon: NSImage(), switchableCount: 0, omittedCount: 0)
    private var rows: [WindowRow] = []
    private var animationEpoch = 0
    private var isDismissing = false
    private var materialImplementation = "uninitialized"
    private var glassStyle = "uninitialized"
    private var appliedCornerRadius: CGFloat = PanelMetrics.defaultValue.cornerRadius
    private weak var backgroundSurface: NSView?
    private weak var foregroundContent: NSView?
    private(set) var currentMetrics = PanelMetrics.defaultValue
    private let headerHeight: CGFloat = 54
    private let textInset: CGFloat = 112
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
    var onSelect: ((AppWindow) -> Void)?
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
        panel.setAccessibilityLabel("窗口列表")
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
            glass.cornerRadius = appliedCornerRadius
            glass.tintColor = nil
            glass.contentView = NSView(frame: content.bounds)
            materialImplementation = "NSGlassEffectView"
            background = glass
        } else {
            let fallback = NSVisualEffectView(frame: content.frame)
            fallback.material = .popover
            fallback.blendingMode = .behindWindow
            fallback.state = .active
            fallback.wantsLayer = true
            fallback.layer?.cornerRadius = appliedCornerRadius
            fallback.layer?.masksToBounds = true
            fallback.layer?.borderWidth = 0.5
            fallback.layer?.borderColor = NSColor.separatorColor.cgColor
            if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
                fallback.blendingMode = .withinWindow
                fallback.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            }
            materialImplementation = "NSVisualEffectView-fallback"
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

    func show(windows: [AppWindow], context: PanelAppContext, icon: NSRect, screen: NSScreen,
              edge: DockEdge, metrics: PanelMetrics, preview: Bool, message: String?) {
        let wasDismissing = isDismissing
        let alreadyVisible = isVisible
        animationEpoch += 1
        isDismissing = false
        let applied = metrics.clamped()
        currentMetrics = applied
        self.entries = windows
        self.context = context
        self.isPreview = preview
        appliedCornerRadius = applied.cornerRadius
        rows.removeAll()

        let pitch = applied.roundedRowHeight
        let titleFont = NSFont.systemFont(ofSize: applied.roundedTitleFontSize, weight: .medium)
        let longestTitle = windows.map {
            ($0.displayTitle as NSString).size(withAttributes: [.font: titleFont]).width
        }.max() ?? 180
        // Window frames land on whole points, so the layout rounds up too; otherwise
        // the reported width can never equal the width the metrics imply.
        let width = ceil(min(applied.width(forLongestTitleWidth: longestTitle, textInset: textInset),
                             screen.visibleFrame.width - 16))
        let maxHeight = max(110, screen.visibleFrame.height * applied.maxHeightFraction)
        let listHeight = min(max(pitch, CGFloat(windows.count) * pitch), maxHeight - headerHeight)
        let size = NSSize(width: width, height: listHeight + headerHeight)
        let content = NSView(frame: NSRect(origin: .zero, size: size))

        let heading = NSTextField(labelWithString: context.appName)
        heading.font = .systemFont(ofSize: 12, weight: .semibold)
        heading.textColor = .secondaryLabelColor
        heading.frame = NSRect(x: 20, y: size.height - 32, width: max(0, width - 212), height: 17)
        content.addSubview(heading)

        let total = context.switchableCount
        let displayed = windows.count
        let count = NSTextField(labelWithString: context.omittedCount > 0
            ? "共 \(total) 个窗口，显示前 \(displayed) 个" : "\(displayed) 个窗口")
        count.font = .systemFont(ofSize: 11, weight: .medium)
        count.textColor = .secondaryLabelColor
        count.alignment = .right
        count.frame = NSRect(x: width - 192, y: size.height - 32, width: 172, height: 17)
        content.addSubview(count)

        let scroll = NSScrollView(frame: NSRect(x: 8, y: 8, width: width - 16, height: listHeight))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = CGFloat(windows.count) * pitch > listHeight
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        let document = FlippedView(frame: NSRect(x: 0, y: 0, width: width - 16,
                                                 height: max(listHeight, CGFloat(windows.count) * pitch)))
        for (index, entry) in windows.enumerated() {
            let row = WindowRow(entry: entry, icon: context.icon,
                                titleFontSize: applied.roundedTitleFontSize,
                                cornerRadius: applied.cornerRadius,
                                frame: NSRect(x: 0, y: CGFloat(index) * pitch + 2,
                                              width: width - 16, height: pitch - 4))
            row.onSelect = { [weak self] entry in self?.onSelect?(entry) }
            document.addSubview(row)
            rows.append(row)
        }
        if windows.isEmpty {
            let empty = NSTextField(wrappingLabelWithString: message ?? "没有可切换的窗口")
            empty.font = .systemFont(ofSize: 13)
            empty.textColor = .secondaryLabelColor
            empty.frame = NSRect(x: 12, y: 12, width: width - 40, height: 36)
            document.addSubview(empty)
        }
        scroll.documentView = document
        content.addSubview(scroll)
        panel.contentView = glassSurface(content: content)
        panel.setFrame(PanelGeometry.frame(size: size, icon: icon, visibleScreen: screen.visibleFrame,
                                           edge: edge, gap: applied.dockGap), display: true)
        backgroundPanel.setFrame(panel.frame, display: true)
        if !alreadyVisible && !panel.isVisible {
            panel.alphaValue = 0
            backgroundPanel.alphaValue = 0
        }
        panel.orderFrontRegardless()
        backgroundPanel.order(.below, relativeTo: panel.windowNumber)
        panel.displayIfNeeded()
        backgroundPanel.displayIfNeeded()
        backgroundPanel.alphaValue = effectiveGlassStrength
        if wasDismissing {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                panel.animator().alphaValue = 1
                backgroundPanel.animator().alphaValue = effectiveGlassStrength
            }
            return
        }
        let epoch = animationEpoch
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            backgroundPanel.animator().alphaValue = effectiveGlassStrength
        }, completionHandler: { [weak self] in
            guard let self = self, self.animationEpoch == epoch else { return }
            self.panel.alphaValue = 1
            self.backgroundPanel.alphaValue = self.effectiveGlassStrength
        })
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
            throw NSError(domain: "WindowList", code: 1)
        }
        view.layoutSubtreeIfNeeded()
        glass.layoutSubtreeIfNeeded()
        guard let foregroundBitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds),
              let backgroundBitmap = glass.bitmapImageRepForCachingDisplay(in: glass.bounds),
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                  pixelsWide: foregroundBitmap.pixelsWide, pixelsHigh: foregroundBitmap.pixelsHigh,
                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let renderContext = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw NSError(domain: "WindowList", code: 2,
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
        NSGraphicsContext.current = renderContext
        renderContext.cgContext.clear(CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
        renderContext.cgContext.scaleBy(x: CGFloat(bitmap.pixelsWide) / view.bounds.width,
                                  y: CGFloat(bitmap.pixelsHigh) / view.bounds.height)
        renderContext.cgContext.setAlpha(backgroundPanel.alphaValue)
        backgroundBitmap.draw(in: view.bounds)
        renderContext.cgContext.setAlpha(1)
        foregroundBitmap.draw(in: view.bounds)
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "WindowList", code: 3)
        }
        try png.write(to: url, options: .atomic)
        let scaleX = CGFloat(bitmap.pixelsWide) / view.bounds.width
        let scaleY = CGFloat(bitmap.pixelsHigh) / view.bounds.height
        // Sample only the margins outside every row: a point inside a row can pick up
        // the hover highlight if the real cursor happens to sit over the preview.
        let backgroundPoints = [CGPoint(x: view.bounds.midX, y: 3),
                                CGPoint(x: view.bounds.width - 3, y: view.bounds.midY),
                                CGPoint(x: view.bounds.midX, y: view.bounds.height - 3)]
        let backgroundAlphaSamples = backgroundPoints.map { point in
            bitmap.colorAt(x: Int(point.x * scaleX), y: Int(point.y * scaleY))?.alphaComponent ?? -1
        }
        let foregroundBackgroundAlphaSamples = backgroundPoints.map { point in
            foregroundBitmap.colorAt(x: Int(point.x * scaleX), y: Int(point.y * scaleY))?.alphaComponent ?? -1
        }
        var iconPeakAlpha: CGFloat = 0
        if let row = rows.first {
            let icon = row.iconRect
            let iconInPanel = row.convert(icon, to: view)
            let left = max(0, Int(iconInPanel.minX * scaleX))
            let right = min(bitmap.pixelsWide, Int(iconInPanel.maxX * scaleX))
            let top = max(0, Int((view.bounds.height - iconInPanel.maxY) * scaleY))
            let bottom = min(bitmap.pixelsHigh, Int((view.bounds.height - iconInPanel.minY) * scaleY))
            for x in left..<right {
                for y in top..<bottom {
                    iconPeakAlpha = max(iconPeakAlpha, bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0)
                }
            }
        }
        let serverWindows = CGWindowListCopyWindowInfo(.optionIncludingWindow,
            CGWindowID(backgroundPanel.windowNumber)) as? [[String: Any]] ?? []
        let serverBackgroundAlpha = (serverWindows.first?[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? -1

        let appliedPitch = currentMetrics.roundedRowHeight
        let appliedTitleFont = currentMetrics.roundedTitleFontSize
        let rowFont = NSFont.systemFont(ofSize: appliedTitleFont, weight: .medium)
        let longestTitleWidth = rows.map {
            ($0.titleText as NSString).size(withAttributes: [.font: rowFont]).width
        }.max() ?? 180
        let clampWidth: CGFloat
        if let panelScreen = panel.screen ?? NSScreen.main {
            clampWidth = panelScreen.visibleFrame.width - 16
        } else {
            clampWidth = view.bounds.width
        }
        let expectedWidth = ceil(min(currentMetrics.width(forLongestTitleWidth: longestTitleWidth,
                                                          textInset: textInset), clampWidth))
        var glassCornerMatch: Bool
        if #available(macOS 26.0, *) {
            glassCornerMatch = (glass as? NSGlassEffectView)?.cornerRadius == appliedCornerRadius
        } else {
            glassCornerMatch = glass.layer?.cornerRadius == appliedCornerRadius
        }
        let pitchOK = rows.isEmpty || abs(rows.first!.rowPitch - appliedPitch) < 0.001
        let fontOK = rows.isEmpty || rows.first!.titleFont == rowFont
        let widthOK = abs(view.bounds.width - expectedWidth) < 0.5
        let metricsAppliedToLayout = pitchOK && fontOK && widthOK && glassCornerMatch
        return ["rowCount": rows.count, "panelWidth": view.bounds.width,
                "expectedPanelWidth": expectedWidth, "measuredLongestTitleWidth": longestTitleWidth,
                "metricsRowPitchMatches": pitchOK, "metricsTitleFontMatches": fontOK,
                "metricsPanelWidthMatches": widthOK, "metricsGlassCornerMatches": glassCornerMatch,
                "panelHeight": view.bounds.height, "rowPitch": appliedPitch,
                "allRowsFitDocument": rows.allSatisfy { row in
                    guard let parent = row.superview else { return false }
                    return parent.bounds.contains(row.frame)
                }, "pngBytes": png.count,
                "previewUsesSampleData": isPreview,
                "materialImplementation": materialImplementation,
                "configuredGlassTransparency": configuredGlassTransparency,
                "nativeLiquidGlass": materialImplementation == "NSGlassEffectView",
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
                "captureKind": "explicit-two-window-composition-not-desktop-compositor",
                "panelAppName": context.appName,
                "appliedRowHeight": appliedPitch,
                "appliedTitleFontSize": appliedTitleFont,
                "appliedWidthCap": currentMetrics.widthCap,
                "appliedAutoFitWidth": currentMetrics.autoFitWidth,
                "appliedMaxHeightFraction": currentMetrics.maxHeightFraction,
                "appliedDockGap": currentMetrics.dockGap,
                "appliedCornerRadius": appliedCornerRadius,
                "omittedWindowCount": context.omittedCount,
                "switchableWindowCount": context.switchableCount,
                "metricsAppliedToLayout": metricsAppliedToLayout]
    }
}
