import AppKit

/// Everything the settings window cannot do on its own. Keeping these as closures
/// means the window stays testable and never reaches back into AppController.
struct SettingsHooks {
    var installedApps: () -> [String: String]
    var addCustomApp: () -> Void
    var openPocket: () -> Void
    var clearPocket: () -> Void
    var showPanelPreview: () -> Void
    var refreshPanelPreview: () -> Void
    var showPermissionWindow: () -> Void
    var isTrusted: () -> Bool
    var revealApp: () -> Void
    var resetPermission: () -> Void
    var relaySummary: () -> (configured: Int, running: Int)
    var openRelayBridge: () -> Void
    var stopAllRelays: () -> Void
}

private final class SidebarItemView: NSView {
    let index: Int
    private let label: NSTextField
    private let iconView: NSImageView
    var onClick: ((Int) -> Void)?

    var isSelected = false {
        didSet {
            needsDisplay = true
            label.textColor = isSelected ? .alternateSelectedControlTextColor : .labelColor
            iconView.contentTintColor = isSelected ? .alternateSelectedControlTextColor : .secondaryLabelColor
        }
    }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(index: Int, title: String, symbol: String, frame: NSRect) {
        self.index = index
        label = UIKitBits.label(title, size: 13, weight: .medium,
                                frame: NSRect(x: 34, y: 7, width: frame.width - 44, height: 18))
        iconView = NSImageView(frame: NSRect(x: 10, y: 8, width: 16, height: 16))
        iconView.image = UIKitBits.symbol(symbol, pointSize: 12, weight: .medium)
        iconView.contentTintColor = .secondaryLabelColor
        super.init(frame: frame)
        addSubview(iconView)
        addSubview(label)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        guard isSelected else { return }
        NSColor.selectedContentBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
    }

    override func mouseDown(with event: NSEvent) {
        onClick?(index)
    }
}

private final class AppActionButton: NSButton {
    var bundleIdentifier: String = ""
}

private final class AppPopupButton: NSPopUpButton {
    var bundleIdentifier: String = ""
}

/// A list row with a hover tint and a hairline separator. The tint is what makes the
/// table feel interactive instead of looking like printed text.
private final class SettingsRowView: NSView {
    var showsSeparator = true
    private var tracking: NSTrackingArea?
    private var hovered = false

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking = tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        if hovered {
            NSColor.labelColor.withAlphaComponent(0.04).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 1), xRadius: 7, yRadius: 7).fill()
        }
        guard showsSeparator else { return }
        NSColor.separatorColor.withAlphaComponent(0.5).setFill()
        NSRect(x: 40, y: bounds.height - 1, width: bounds.width - 40, height: 1).fill()
    }
}

final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let settings: SettingsStore
    private let shortcuts: ShortcutManager
    private let pocketStore: PocketStore
    private let windowPanel: WindowListPanel
    private let hooks: SettingsHooks

    private var window: NSWindow?
    private var contentHost: NSView?
    private var glassMaterial = "uninitialized"
    private var sidebarItems: [SidebarItemView] = []
    private var currentPageView: NSView?
    private var currentPage = 0
    private var metricSliders: [String: NSSlider] = [:]
    private var metricValueLabels: [String: NSTextField] = [:]
    private var metricKeys: [String] = []

    private let windowSize = NSSize(width: 760, height: 560)
    private let sidebarWidth: CGFloat = 184
    private let pageSize = NSSize(width: 576, height: 560)
    private let contentX: CGFloat = 32
    private let contentWidth: CGFloat = 512

    private(set) var lastAppRowCount = 0
    private(set) var lastSliderCount = 0
    private(set) var lastSwitchCount = 0

    private let pageTitles = ["权限", "窗口切换", "临时口袋", "中转接口", "外观"]
    private let pageSymbols = ["lock.shield", "macwindow.on.rectangle", "tray.full",
                               "arrow.triangle.branch", "slider.horizontal.3"]

    private var prefersSolidSurface: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    private var glassCardFill: NSColor {
        NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor.white.withAlphaComponent(dark ? 0.08 : 0.34)
        }
    }

    init(settings: SettingsStore, shortcuts: ShortcutManager, pocketStore: PocketStore,
         windowPanel: WindowListPanel, hooks: SettingsHooks) {
        self.settings = settings
        self.shortcuts = shortcuts
        self.pocketStore = pocketStore
        self.windowPanel = windowPanel
        self.hooks = hooks
        super.init()
    }

    var isVisible: Bool { window?.isVisible ?? false }

    // MARK: - Presentation

    func show(page: Int) {
        let window = ensureWindow()
        selectPage(max(0, min(pageTitles.count - 1, page)))
        NSApp.activate(ignoringOtherApps: true)
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.orderOut(nil)
    }

    /// Rebuilds the visible page so values changed elsewhere (menu, shortcut
    /// recorder, permission grant) show up without reopening the window.
    func reload() {
        guard window != nil else { return }
        selectPage(currentPage)
    }

    private func ensureWindow() -> NSWindow {
        if let window = window { return window }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: windowSize),
                              styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "MacToolbox 设置"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = windowSize

        let root = FlippedContainerView(frame: NSRect(origin: .zero, size: windowSize))
        root.wantsLayer = true
        root.layer?.cornerRadius = 16
        root.layer?.masksToBounds = true
        window.contentView = root

        let solidSurface = prefersSolidSurface
        if !solidSurface, #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: root.bounds)
            glass.style = .regular
            glass.cornerRadius = 16
            glass.autoresizingMask = [.width, .height]
            glass.setAccessibilityElement(false)
            root.addSubview(glass)
            glassMaterial = "NSGlassEffectView"
        } else {
            let fallback = NSVisualEffectView(frame: root.bounds)
            fallback.material = .windowBackground
            fallback.blendingMode = .behindWindow
            fallback.state = .followsWindowActiveState
            fallback.autoresizingMask = [.width, .height]
            root.addSubview(fallback)
            glassMaterial = solidSurface ? "opaque-fallback" : "NSVisualEffectView-fallback"
            if solidSurface {
                window.isOpaque = true
                window.backgroundColor = .windowBackgroundColor
            }
        }

        let sidebar = SidebarSurfaceView(frame: NSRect(x: 0, y: 0,
                                                       width: sidebarWidth, height: windowSize.height))
        sidebar.autoresizingMask = [.height]
        root.addSubview(sidebar)

        let appIcon = NSImageView(frame: NSRect(x: 16, y: 44, width: 22, height: 22))
        appIcon.image = NSApp.applicationIconImage
        appIcon.imageScaling = .scaleProportionallyUpOrDown
        root.addSubview(appIcon)
        root.addSubview(UIKitBits.label("MacToolbox", size: 13, weight: .semibold,
                                        frame: NSRect(x: 46, y: 46, width: 120, height: 18)))

        for (index, title) in pageTitles.enumerated() {
            let item = SidebarItemView(index: index, title: title, symbol: pageSymbols[index],
                                       frame: NSRect(x: 12, y: 84 + CGFloat(index) * 36,
                                                     width: sidebarWidth - 24, height: 32))
            item.onClick = { [weak self] index in self?.selectPage(index) }
            item.isSelected = index == 0
            root.addSubview(item)
            sidebarItems.append(item)
        }

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.4.0"
        root.addSubview(UIKitBits.label("版本 \(version)", size: 10, color: .tertiaryLabelColor,
                                        frame: NSRect(x: 16, y: windowSize.height - 26,
                                                      width: sidebarWidth - 32, height: 16)))

        let host = FlippedContainerView(frame: NSRect(x: sidebarWidth, y: 0,
                                                      width: windowSize.width - sidebarWidth,
                                                      height: windowSize.height))
        root.addSubview(host)
        contentHost = host

        self.window = window
        return window
    }

    private func selectPage(_ index: Int) {
        currentPage = index
        for item in sidebarItems { item.isSelected = item.index == index }
        rebuildPage()
    }

    private func rebuildPage() {
        currentPageView?.removeFromSuperview()
        let page = FlippedContainerView(frame: NSRect(origin: .zero, size: pageSize))
        switch currentPage {
        case 0: buildPermissionPage(into: page)
        case 1: buildSwitcherPage(into: page)
        case 2: buildPocketPage(into: page)
        case 3: buildRelayPage(into: page)
        default: buildAppearancePage(into: page)
        }
        contentHost?.addSubview(page)
        currentPageView = page
    }

    // MARK: - Shared page furniture

    /// Grouping surface. Without it every control floats on the page background and
    /// the page reads as one undifferentiated list.
    private func card(_ rect: NSRect, to page: NSView) -> RoundedBackgroundView {
        let view = RoundedBackgroundView(frame: rect)
        view.cornerRadius = 12
        let solidSurface = prefersSolidSurface
        view.fillColor = solidSurface ? .controlBackgroundColor : glassCardFill
        view.fillAlpha = 1
        view.borderColor = .separatorColor
        view.borderAlpha = solidSurface ? 0.55 : 0.28
        view.topHighlightColor = solidSurface ? nil : NSColor.white.withAlphaComponent(0.36)
        page.addSubview(view)
        return view
    }

    private func addHeader(_ title: String, _ subtitle: String, to page: NSView) {
        page.addSubview(UIKitBits.label(title, size: 20, weight: .semibold,
                                        frame: NSRect(x: contentX, y: 24, width: contentWidth, height: 26)))
        page.addSubview(UIKitBits.paragraph(subtitle, size: 13, color: .secondaryLabelColor,
                                            frame: NSRect(x: contentX, y: 56, width: contentWidth, height: 18),
                                            lines: 1))
    }

    private func sectionLabel(_ title: String, at point: NSPoint, width: CGFloat, to parent: NSView) {
        parent.addSubview(UIKitBits.label(title, size: 12, weight: .medium, color: .secondaryLabelColor,
                                          frame: NSRect(x: point.x, y: point.y, width: width, height: 18)))
    }

    private func addSwitch(_ title: String, isOn: Bool, action: Selector,
                           at point: NSPoint, to parent: NSView,
                           rightEdge: CGFloat? = nil) -> NSSwitch {
        let toggleX = (rightEdge ?? parent.bounds.width - 16) - 38
        let toggle = NSSwitch(frame: NSRect(x: toggleX, y: point.y, width: 38, height: 22))
        toggle.state = isOn ? .on : .off
        toggle.target = self
        toggle.action = action
        toggle.setAccessibilityLabel(title)
        parent.addSubview(toggle)
        parent.addSubview(UIKitBits.label(title, size: 13,
                                          frame: NSRect(x: point.x, y: point.y + 2,
                                                        width: max(80, toggleX - point.x - 12),
                                                        height: 18)))
        lastSwitchCount += 1
        return toggle
    }

    private func addShortcutRow(role: ShortcutRole, title: String, y: CGFloat, to parent: NSView) {
        parent.addSubview(UIKitBits.label(title, size: 12, color: .secondaryLabelColor,
                                          frame: NSRect(x: 16, y: y + 3, width: 92, height: 18)))
        let value = shortcuts.shortcut(for: role)?.displayName ?? "未设置"
        parent.addSubview(UIKitBits.label(value, size: 12, weight: .medium,
                                          frame: NSRect(x: 112, y: y + 3, width: 150, height: 18)))

        let set = AppActionButton(frame: NSRect(x: 344, y: y, width: 64, height: 26))
        set.title = "设置…"
        set.bezelStyle = .rounded
        set.font = .systemFont(ofSize: 12)
        set.target = self
        set.action = #selector(recordShortcut(_:))
        set.bundleIdentifier = role.rawValue
        parent.addSubview(set)

        let reset = AppActionButton(frame: NSRect(x: 416, y: y, width: 80, height: 26))
        reset.title = "恢复默认"
        reset.bezelStyle = .rounded
        reset.font = .systemFont(ofSize: 12)
        reset.isEnabled = shortcuts.shortcut(for: role) != ShortcutManager.defaultShortcut(for: role)
        reset.target = self
        reset.action = #selector(resetShortcut(_:))
        reset.bundleIdentifier = role.rawValue
        parent.addSubview(reset)
    }

    private func role(from button: NSButton) -> ShortcutRole? {
        guard let action = button as? AppActionButton else { return nil }
        return ShortcutRole(rawValue: action.bundleIdentifier)
    }

    // MARK: - Page: permission

    private func buildPermissionPage(into page: NSView) {
        addHeader("权限", "窗口切换需要 macOS 的辅助功能权限，其余功能不受影响。", to: page)

        let trusted = hooks.isTrusted()
        let status = card(NSRect(x: contentX, y: 88, width: contentWidth, height: 108), to: page)
        let pill = StatusPillView(frame: NSRect(x: 16, y: 14, width: 80, height: 22))
        pill.text = trusted ? "已授权" : "未授权"
        pill.tint = trusted ? .systemGreen : .systemOrange
        let pillWidth = pill.intrinsicContentSize.width
        pill.frame = NSRect(x: 16, y: 14, width: pillWidth, height: 22)
        status.addSubview(pill)
        status.addSubview(UIKitBits.label("辅助功能权限", size: 13, weight: .medium,
                                          frame: NSRect(x: 28 + pillWidth, y: 17,
                                                        width: 240, height: 18)))

        status.addSubview(UIKitBits.label(
            trusted ? "可以读取并切换任意应用的窗口。" : "悬停 Dock 不会列出窗口，口袋和快捷键仍可正常使用。",
            size: 12, color: .secondaryLabelColor,
            frame: NSRect(x: 16, y: 46, width: 480, height: 18)))

        // Which copy is asking. Accessibility is per path, so this line is the only
        // way to tell the right entry apart from a stale one.
        status.addSubview(UIKitBits.label("当前程序", size: 11, color: .secondaryLabelColor,
                                          frame: NSRect(x: 16, y: 75, width: 56, height: 16)))
        let pathLabel = UIKitBits.label(AppInstallation.path, size: 10, color: .tertiaryLabelColor,
                                        frame: NSRect(x: 76, y: 76, width: 328, height: 16))
        pathLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        pathLabel.lineBreakMode = .byTruncatingMiddle
        status.addSubview(pathLabel)

        let copy = NSButton(title: "复制路径", target: self, action: #selector(copyAppPath))
        copy.bezelStyle = .inline
        copy.isBordered = false
        copy.font = .systemFont(ofSize: 11)
        copy.contentTintColor = .controlAccentColor
        copy.frame = NSRect(x: 410, y: 72, width: 62, height: 22)
        status.addSubview(copy)

        let steps = card(NSRect(x: contentX, y: 212, width: contentWidth, height: 190), to: page)
        let stepData = [
            ("打开系统设置的辅助功能面板", "点下方按钮直接跳到「隐私与安全性 → 辅助功能」。"),
            ("把 \(AppInstallation.fileName) 拖进列表",
             "「在访达中显示」会定位到这一份应用；列表里显示的名称是 \(AppInstallation.listName)。"),
            ("回到这里，无需重启", "窗口会实时检测状态，授权成功后自动更新。")
        ]
        for (offset, step) in stepData.enumerated() {
            steps.addSubview(permissionStep(index: offset + 1, title: step.0, detail: step.1,
                                            y: CGFloat(12 + offset * 58)))
        }

        let open = NSButton(title: "打开辅助功能设置", target: self, action: #selector(openPermission))
        open.bezelStyle = .rounded
        open.bezelColor = .controlAccentColor
        open.frame = NSRect(x: contentX, y: 416, width: 150, height: 30)
        page.addSubview(open)

        let reveal = NSButton(title: "在访达中显示", target: self, action: #selector(revealApp))
        reveal.bezelStyle = .rounded
        reveal.frame = NSRect(x: contentX + 158, y: 416, width: 118, height: 30)
        page.addSubview(reveal)

        let reset = NSButton(title: "重置权限", target: self, action: #selector(resetPermission))
        reset.bezelStyle = .inline
        reset.isBordered = false
        reset.font = .systemFont(ofSize: 12)
        reset.contentTintColor = .secondaryLabelColor
        reset.frame = NSRect(x: contentX + 288, y: 420, width: 76, height: 24)
        page.addSubview(reset)

        let copies = AppInstallation.duplicateCopies()
        let note: String
        if !copies.isEmpty {
            let names = copies.map { ($0 as NSString).lastPathComponent }.joined(separator: "、")
            note = "检测到另外 \(copies.count) 份副本：\(names)。辅助功能按路径授权，只有上面「当前程序」这一份的开关有效。"
        } else {
            note = "重置会从系统设置中移除本应用的授权条目，用于修复开关变灰或授权失效；重置后需要重新添加。"
        }
        let noteIcon = NSImageView(frame: NSRect(x: contentX, y: 462, width: 14, height: 14))
        noteIcon.image = UIKitBits.symbol(copies.isEmpty ? "info.circle" : "exclamationmark.triangle.fill",
                                          pointSize: 11)
        noteIcon.contentTintColor = copies.isEmpty ? .tertiaryLabelColor : .systemOrange
        page.addSubview(noteIcon)
        page.addSubview(UIKitBits.paragraph(note, size: 11,
                                            color: copies.isEmpty ? .tertiaryLabelColor : .secondaryLabelColor,
                                            frame: NSRect(x: contentX + 20, y: 460,
                                                          width: contentWidth - 20, height: 44),
                                            lines: 3))
    }

    private func permissionStep(index: Int, title: String, detail: String, y: CGFloat) -> NSView {
        let container = FlippedContainerView(frame: NSRect(x: 16, y: y, width: 480, height: 56))
        let badge = RoundedBackgroundView(frame: NSRect(x: 0, y: 1, width: 22, height: 22))
        badge.cornerRadius = 11
        badge.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.14)
        let number = UIKitBits.label("\(index)", size: 12, weight: .medium, color: .controlAccentColor,
                                     frame: NSRect(x: 0, y: 4, width: 22, height: 16))
        number.alignment = .center
        badge.addSubview(number)
        container.addSubview(badge)
        container.addSubview(UIKitBits.label(title, size: 13, weight: .medium,
                                             frame: NSRect(x: 34, y: 0, width: 446, height: 18)))
        container.addSubview(UIKitBits.paragraph(detail, size: 12, color: .secondaryLabelColor,
                                                 frame: NSRect(x: 34, y: 21, width: 446, height: 32),
                                                 lines: 2))
        return container
    }

    // MARK: - Page: window switcher

    private func buildSwitcherPage(into page: NSView) {
        addHeader("窗口切换", "把鼠标停在 Dock 图标上，列出该应用正在运行的窗口。", to: page)

        let top = card(NSRect(x: contentX, y: 88, width: contentWidth, height: 96), to: page)
        _ = addSwitch("启用悬停切窗", isOn: settings.isToolEnabled(.windowSwitcher),
                      action: #selector(toggleSwitcher), at: NSPoint(x: 16, y: 14), to: top)
        addShortcutRow(role: .windowSwitcherPanel, title: "面板快捷键", y: 56, to: top)

        let installed = hooks.installedApps()
        let apps = settings.managedApps(installed: installed)
        let masterEnabled = settings.isToolEnabled(.windowSwitcher)
        sectionLabel("启用哪些应用", at: NSPoint(x: contentX, y: 200), width: 130, to: page)

        let selectAll = NSButton(title: "全选", target: self, action: #selector(selectAllApps))
        selectAll.bezelStyle = .inline
        selectAll.isBordered = false
        selectAll.font = .systemFont(ofSize: 11)
        selectAll.contentTintColor = .controlAccentColor
        selectAll.frame = NSRect(x: contentX + 136, y: 196, width: 40, height: 22)
        selectAll.isEnabled = masterEnabled
        selectAll.setAccessibilityHelp("启用列表里的全部应用")
        page.addSubview(selectAll)

        let selectNone = NSButton(title: "全不选", target: self, action: #selector(selectNoneApps))
        selectNone.bezelStyle = .inline
        selectNone.isBordered = false
        selectNone.font = .systemFont(ofSize: 11)
        selectNone.contentTintColor = .secondaryLabelColor
        selectNone.frame = NSRect(x: contentX + 182, y: 196, width: 52, height: 22)
        selectNone.isEnabled = masterEnabled
        selectNone.setAccessibilityHelp("关闭列表里的全部应用")
        page.addSubview(selectNone)

        let enabled = apps.filter { $0.isEnabled }.count
        let countText = masterEnabled ? "\(enabled) / \(apps.count) 已启用"
            : "已暂停 · \(enabled) / \(apps.count) 已启用"
        let enabledCount = UIKitBits.label(countText, size: 11, color: .secondaryLabelColor,
                                           frame: NSRect(x: contentX + 300, y: 200, width: 212, height: 18))
        enabledCount.alignment = .right
        page.addSubview(enabledCount)

        let listCard = card(NSRect(x: contentX, y: 224, width: contentWidth, height: 270), to: page)
        listCard.addSubview(UIKitBits.label("应用", size: 10, color: .secondaryLabelColor,
                                            frame: NSRect(x: 40, y: 8, width: 100, height: 14)))
        listCard.addSubview(columnLabel("启用", x: 197, y: 8, width: 40))
        listCard.addSubview(columnLabel("最小化", x: 256, y: 8, width: 56))
        listCard.addSubview(columnLabel("窗口数", x: 348, y: 8, width: 96))
        listCard.addSubview(UIKitBits.separator(frame: NSRect(x: 0, y: 29, width: contentWidth - 2, height: 1)))

        let rowHeight: CGFloat = 40
        let scroll = NSScrollView(frame: NSRect(x: contentX + 1, y: 254, width: contentWidth - 2, height: 239))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = CGFloat(apps.count) * rowHeight > 239
        scroll.hasHorizontalScroller = false
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        let document = FlippedContainerView(frame: NSRect(x: 0, y: 0, width: contentWidth - 14,
                                                          height: max(239, CGFloat(apps.count) * rowHeight)))
        for (offset, app) in apps.enumerated() {
            document.addSubview(appRow(app, y: CGFloat(offset) * rowHeight, height: rowHeight,
                                       interactive: masterEnabled, isLast: offset == apps.count - 1))
        }
        scroll.documentView = document
        page.addSubview(scroll)
        lastAppRowCount = apps.count

        let add = NSButton(title: "添加其他应用…", target: self, action: #selector(addApp))
        add.bezelStyle = .rounded
        add.frame = NSRect(x: contentX, y: 504, width: 130, height: 28)
        page.addSubview(add)
    }

    private func columnLabel(_ title: String, x: CGFloat, y: CGFloat, width: CGFloat) -> NSTextField {
        let label = UIKitBits.label(title, size: 10, color: .secondaryLabelColor,
                                    frame: NSRect(x: x, y: y, width: width, height: 14))
        label.alignment = .center
        return label
    }

    private func appRow(_ app: ManagedApp, y: CGFloat, height: CGFloat,
                        interactive: Bool, isLast: Bool) -> NSView {
        let row = SettingsRowView(frame: NSRect(x: 0, y: y, width: contentWidth - 14, height: height))
        row.showsSeparator = !isLast

        let icon = NSImageView(frame: NSRect(x: 12, y: 10, width: 20, height: 20))
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleIdentifier) {
            icon.image = NSWorkspace.shared.icon(forFile: url.path)
        }
        row.addSubview(icon)

        row.addSubview(UIKitBits.label(app.displayName, size: 13,
                                       frame: NSRect(x: 40, y: 10, width: 156, height: 20)))

        let enable = AppActionButton(frame: NSRect(x: 208, y: 11, width: 18, height: 18))
        enable.setButtonType(.switch)
        enable.title = ""
        enable.state = app.isEnabled ? .on : .off
        enable.target = self
        enable.action = #selector(toggleAppEnabled(_:))
        enable.bundleIdentifier = app.bundleIdentifier
        enable.isEnabled = interactive
        enable.setAccessibilityLabel("启用 \(app.displayName)")
        row.addSubview(enable)

        let minimized = AppActionButton(frame: NSRect(x: 276, y: 11, width: 18, height: 18))
        minimized.setButtonType(.switch)
        minimized.title = ""
        minimized.state = app.config.includeMinimized ? .on : .off
        minimized.target = self
        minimized.action = #selector(toggleAppMinimized(_:))
        minimized.bundleIdentifier = app.bundleIdentifier
        minimized.isEnabled = interactive && app.isEnabled
        minimized.setAccessibilityLabel("列出 \(app.displayName) 的最小化窗口")
        row.addSubview(minimized)

        let popup = AppPopupButton(frame: NSRect(x: 348, y: 8, width: 96, height: 24), pullsDown: false)
        popup.font = .systemFont(ofSize: 12)
        for count in [3, 6, 9, 12, 20, 40] {
            let item = NSMenuItem(title: "\(count) 个", action: nil, keyEquivalent: "")
            item.representedObject = count
            popup.menu?.addItem(item)
        }
        popup.selectItem(withTitle: "\(app.config.maxWindows) 个")
        popup.target = self
        popup.action = #selector(changeMaxWindows(_:))
        popup.bundleIdentifier = app.bundleIdentifier
        popup.isEnabled = interactive && app.isEnabled
        popup.setAccessibilityLabel("最多列出窗口数")
        row.addSubview(popup)

        if settings.customBundleIdentifiers().contains(app.bundleIdentifier) {
            let remove = AppActionButton(frame: NSRect(x: 452, y: 9, width: 40, height: 24))
            remove.title = "移除"
            remove.bezelStyle = .inline
            remove.isBordered = false
            remove.font = .systemFont(ofSize: 11)
            remove.contentTintColor = .secondaryLabelColor
            remove.target = self
            remove.action = #selector(removeApp(_:))
            remove.bundleIdentifier = app.bundleIdentifier
            remove.isEnabled = interactive
            row.addSubview(remove)
        }

        return row
    }

    // MARK: - Page: pocket

    private func buildPocketPage(into page: NSView) {
        addHeader("临时口袋", "把文件或图片先放进来，需要时再拖出去。", to: page)

        let top = card(NSRect(x: contentX, y: 88, width: contentWidth, height: 96), to: page)
        _ = addSwitch("启用临时口袋", isOn: settings.isToolEnabled(.pocket),
                      action: #selector(togglePocket), at: NSPoint(x: 16, y: 14), to: top)
        addShortcutRow(role: .pocket, title: "口袋快捷键", y: 56, to: top)

        let info = card(NSRect(x: contentX, y: 196, width: contentWidth, height: 96), to: page)
        let tray = NSImageView(frame: NSRect(x: 16, y: 16, width: 20, height: 20))
        tray.image = UIKitBits.symbol("tray.full", pointSize: 16)
        tray.contentTintColor = .controlAccentColor
        info.addSubview(tray)
        sectionLabel("当前口袋", at: NSPoint(x: 48, y: 14), width: 200, to: info)
        info.addSubview(UIKitBits.label("\(pocketStore.count) 项", size: 22, weight: .medium,
                                        frame: NSRect(x: 48, y: 32, width: 200, height: 28)))

        let open = NSButton(title: "打开口袋", target: self, action: #selector(openPocket))
        open.bezelStyle = .rounded
        open.frame = NSRect(x: 280, y: 34, width: 110, height: 28)
        open.isEnabled = settings.isToolEnabled(.pocket)
        info.addSubview(open)

        let clear = NSButton(title: "清空", target: self, action: #selector(clearPocket))
        clear.bezelStyle = .rounded
        clear.frame = NSRect(x: 398, y: 34, width: 80, height: 28)
        clear.isEnabled = pocketStore.count > 0
        info.addSubview(clear)

        sectionLabel("使用方式", at: NSPoint(x: contentX, y: 308), width: 200, to: page)
        let usage = card(NSRect(x: contentX, y: 332, width: contentWidth, height: 156), to: page)
        let descriptions = [
            ("hand.draw", "拖动文件时左右晃动鼠标", "口袋出现在光标旁，不松手把文件放进去。"),
            ("keyboard", "按 ⌥Space 随时打开", "也可以晃动菜单栏图标两次，或从菜单打开。"),
            ("doc.on.doc", "拖出默认复制", "条目仍留在口袋中；普通文件保留原位置。")
        ]
        for (offset, description) in descriptions.enumerated() {
            usage.addSubview(pocketUsageRow(symbol: description.0, title: description.1,
                                            detail: description.2, y: CGFloat(8 + offset * 48)))
            if offset < descriptions.count - 1 {
                usage.addSubview(UIKitBits.separator(
                    frame: NSRect(x: 16, y: CGFloat(55 + offset * 48), width: contentWidth - 34, height: 1)))
            }
        }

        page.addSubview(UIKitBits.paragraph(
            "口袋内容只保存在本次运行中，退出应用即清空。普通文件保留原位置，拖出时默认复制；从剪贴板导入的截图会另存为临时 PNG，清空时一并删除。",
            size: 11, color: .tertiaryLabelColor,
            frame: NSRect(x: contentX, y: 500, width: contentWidth, height: 32), lines: 2))
    }

    private func pocketUsageRow(symbol: String, title: String, detail: String, y: CGFloat) -> NSView {
        let row = FlippedContainerView(frame: NSRect(x: 0, y: y, width: contentWidth - 2, height: 48))
        let icon = NSImageView(frame: NSRect(x: 16, y: 16, width: 16, height: 16))
        icon.image = UIKitBits.symbol(symbol, pointSize: 12, weight: .medium)
        icon.contentTintColor = .secondaryLabelColor
        row.addSubview(icon)
        row.addSubview(UIKitBits.label(title, size: 13, weight: .medium,
                                       frame: NSRect(x: 44, y: 8, width: 440, height: 18)))
        row.addSubview(UIKitBits.label(detail, size: 11, color: .secondaryLabelColor,
                                       frame: NSRect(x: 44, y: 26, width: 440, height: 16)))
        return row
    }

    // MARK: - Page: relay bridge

    private func buildRelayPage(into page: NSView) {
        addHeader("中转接口", "把 Anthropic 中转接口修复成客户端可读取的流式输出。", to: page)
        let summary = hooks.relaySummary()

        let status = card(NSRect(x: contentX, y: 88, width: contentWidth, height: 136), to: page)
        status.addSubview(UIKitBits.label("本机中转", size: 12, color: .secondaryLabelColor,
                                          frame: NSRect(x: 16, y: 14, width: 200, height: 18)))
        let countText = summary.configured == 0 ? "尚未配置接口"
            : "\(summary.configured) 个接口 · \(summary.running) 个运行中"
        status.addSubview(UIKitBits.label(countText, size: 20, weight: .semibold,
                                          frame: NSRect(x: 16, y: 34, width: 480, height: 28)))
        status.addSubview(UIKitBits.paragraph("每个接口使用独立本机端口；关闭设置窗口后代理仍会继续运行。",
                                              size: 11, color: .secondaryLabelColor,
                                              frame: NSRect(x: 16, y: 66, width: 480, height: 18),
                                              lines: 1))

        let open = NSButton(title: "打开中转接口…", target: self, action: #selector(openRelayBridge))
        open.bezelStyle = .rounded
        open.bezelColor = .controlAccentColor
        open.frame = NSRect(x: 16, y: 94, width: 140, height: 28)
        status.addSubview(open)

        let stop = NSButton(title: "停止全部代理", target: self, action: #selector(stopAllRelays))
        stop.bezelStyle = .rounded
        stop.frame = NSRect(x: 164, y: 94, width: 120, height: 28)
        stop.isEnabled = summary.running > 0
        status.addSubview(stop)

        sectionLabel("工作方式", at: NSPoint(x: contentX, y: 244), width: 200, to: page)
        let info = card(NSRect(x: contentX, y: 268, width: contentWidth, height: 156), to: page)
        let rows = [
            ("arrow.triangle.branch", "修复流式输出",
             "上游强制非流式请求，代理重建 Claude 客户端需要的事件流。"),
            ("network", "独立端口", "每个接口可分别启动、停止和测试，互不影响。"),
            ("key", "密钥与本机",
             "密钥保存在 macOS 钥匙串；配置位于 ~/Library/Application Support/RelayBridge。")
        ]
        for (offset, row) in rows.enumerated() {
            info.addSubview(pocketUsageRow(symbol: row.0, title: row.1, detail: row.2,
                                           y: CGFloat(8 + offset * 48)))
            if offset < rows.count - 1 {
                info.addSubview(UIKitBits.separator(
                    frame: NSRect(x: 16, y: CGFloat(55 + offset * 48),
                                  width: contentWidth - 34, height: 1)))
            }
        }

        page.addSubview(UIKitBits.paragraph(
            "支持通用 SSE 修复与 justwoker 工具兼容；仅提供 Anthropic Messages 协议。使用前先退出独立的 RelayBridge.app，避免同一端口被占用。",
            size: 11, color: .tertiaryLabelColor,
            frame: NSRect(x: contentX, y: 440, width: contentWidth, height: 44), lines: 2))
    }

    // MARK: - Page: appearance

    private struct MetricDefinition {
        let key: String
        let title: String
        let unit: String
        let range: ClosedRange<CGFloat>
        let percent: Bool
    }

    private var metricDefinitions: [MetricDefinition] {
        [
            MetricDefinition(key: "rowHeight", title: "行高", unit: "pt", range: 34...72, percent: false),
            MetricDefinition(key: "titleFontSize", title: "标题字号", unit: "pt", range: 11...22, percent: false),
            MetricDefinition(key: "widthCap", title: "宽度上限", unit: "pt", range: 240...640, percent: false),
            MetricDefinition(key: "maxHeightFraction", title: "最大高度占比", unit: "%", range: 30...90, percent: true),
            MetricDefinition(key: "dockGap", title: "距 Dock 间隙", unit: "pt", range: 4...40, percent: false),
            MetricDefinition(key: "cornerRadius", title: "圆角", unit: "pt", range: 0...36, percent: false),
            MetricDefinition(key: "glassTransparency", title: "玻璃透明度", unit: "%", range: 0...100, percent: true)
        ]
    }

    private func metricValue(_ key: String) -> CGFloat {
        let metrics = settings.metrics
        switch key {
        case "rowHeight": return metrics.rowHeight
        case "titleFontSize": return metrics.titleFontSize
        case "widthCap": return metrics.widthCap
        case "maxHeightFraction": return metrics.maxHeightFraction * 100
        case "dockGap": return metrics.dockGap
        case "cornerRadius": return metrics.cornerRadius
        case "glassTransparency": return windowPanel.configuredGlassTransparency
        default: return 0
        }
    }

    private func buildAppearancePage(into page: NSView) {
        addHeader("外观", "调整窗口列表的尺寸与质感，改动即时生效。", to: page)
        metricSliders.removeAll()
        metricValueLabels.removeAll()
        metricKeys.removeAll()
        lastSliderCount = 0

        let panel = card(NSRect(x: contentX, y: 88, width: contentWidth, height: 360), to: page)
        for (offset, definition) in metricDefinitions.enumerated() {
            panel.addSubview(metricRow(definition, y: CGFloat(12 + offset * 48)))
            if offset < metricDefinitions.count - 1 {
                panel.addSubview(UIKitBits.separator(
                    frame: NSRect(x: 16, y: CGFloat(12 + offset * 48 + 44),
                                  width: contentWidth - 34, height: 1)))
            }
            lastSliderCount += 1
        }

        _ = addSwitch("宽度自适应标题", isOn: settings.metrics.autoFitWidth,
                      action: #selector(toggleAutoFit), at: NSPoint(x: contentX, y: 460),
                      to: page, rightEdge: contentX + contentWidth)

        let reset = NSButton(title: "恢复默认外观", target: self, action: #selector(resetMetrics))
        reset.bezelStyle = .rounded
        reset.frame = NSRect(x: contentX, y: 488, width: 120, height: 28)
        page.addSubview(reset)

        let preview = NSButton(title: "预览面板", target: self, action: #selector(showPreview))
        preview.bezelStyle = .rounded
        preview.frame = NSRect(x: contentX + 128, y: 488, width: 100, height: 28)
        page.addSubview(preview)
    }

    private func metricRow(_ definition: MetricDefinition, y: CGFloat) -> NSView {
        let row = FlippedContainerView(frame: NSRect(x: 16, y: y, width: 480, height: 44))
        let value = metricValue(definition.key)

        row.addSubview(UIKitBits.label(definition.title, size: 12,
                                       frame: NSRect(x: 0, y: 0, width: 200, height: 18)))
        let valueLabel = UIKitBits.label(formatted(definition, value), size: 11, color: .secondaryLabelColor,
                                         frame: NSRect(x: 360, y: 0, width: 120, height: 18))
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        valueLabel.alignment = .right
        row.addSubview(valueLabel)

        let slider = NSSlider(value: Double(value), minValue: Double(definition.range.lowerBound),
                              maxValue: Double(definition.range.upperBound),
                              target: self, action: #selector(metricChanged(_:)))
        slider.isContinuous = true
        slider.frame = NSRect(x: 0, y: 22, width: 480, height: 18)
        slider.tag = metricKeys.count
        slider.setAccessibilityLabel(definition.title)
        row.addSubview(slider)

        metricKeys.append(definition.key)
        metricSliders[definition.key] = slider
        metricValueLabels[definition.key] = valueLabel
        return row
    }

    private func formatted(_ definition: MetricDefinition, _ value: CGFloat) -> String {
        definition.percent ? String(format: "%.0f%%", Double(value))
            : String(format: "%.0f%@", Double(value), definition.unit)
    }

    // MARK: - Actions

    @objc private func toggleSwitcher(_ sender: NSSwitch) {
        settings.setToolEnabled(sender.state == .on, for: .windowSwitcher)
        rebuildPage()
    }

    @objc private func togglePocket(_ sender: NSSwitch) {
        settings.setToolEnabled(sender.state == .on, for: .pocket)
        if sender.state == .off { hooks.clearPocket() }
    }

    @objc private func toggleAppEnabled(_ sender: AppActionButton) {
        settings.setEnabled(sender.state == .on, for: sender.bundleIdentifier)
        guard let row = sender.superview else { return }
        for case let button as AppActionButton in row.subviews
        where button !== sender && button.bundleIdentifier == sender.bundleIdentifier
            && button.title.isEmpty {
            button.isEnabled = sender.state == .on
        }
        for case let popup as AppPopupButton in row.subviews
        where popup.bundleIdentifier == sender.bundleIdentifier {
            popup.isEnabled = sender.state == .on
        }
    }

    /// Bulk toggles only touch apps that are actually installed, so the stored flags
    /// stay meaningful if an app is later reinstalled.
    private func setAllApps(enabled: Bool) {
        for app in settings.managedApps(installed: hooks.installedApps()) {
            settings.setEnabled(enabled, for: app.bundleIdentifier)
        }
        rebuildPage()
    }

    @objc private func selectAllApps() { setAllApps(enabled: true) }

    @objc private func selectNoneApps() { setAllApps(enabled: false) }

    @objc private func toggleAppMinimized(_ sender: AppActionButton) {
        var config = settings.config(for: sender.bundleIdentifier)
        config.includeMinimized = sender.state == .on
        settings.setConfig(config, for: sender.bundleIdentifier)
    }

    @objc private func changeMaxWindows(_ sender: AppPopupButton) {
        guard let count = sender.selectedItem?.representedObject as? Int else { return }
        var config = settings.config(for: sender.bundleIdentifier)
        config.maxWindows = count
        settings.setConfig(config, for: sender.bundleIdentifier)
    }

    @objc private func removeApp(_ sender: AppActionButton) {
        settings.removeCustomApp(bundleIdentifier: sender.bundleIdentifier)
        rebuildPage()
    }

    @objc private func addApp() {
        hooks.addCustomApp()
        rebuildPage()
    }

    @objc private func toggleAutoFit(_ sender: NSSwitch) {
        var metrics = settings.metrics
        metrics.autoFitWidth = sender.state == .on
        settings.setMetrics(metrics)
        hooks.refreshPanelPreview()
    }

    @objc private func resetMetrics(_ sender: Any?) {
        settings.setMetrics(PanelMetrics.defaultValue)
        windowPanel.setGlassTransparency(72)
        rebuildPage()
        hooks.refreshPanelPreview()
    }

    @objc private func metricChanged(_ sender: NSSlider) {
        guard sender.tag >= 0, sender.tag < metricKeys.count else { return }
        let key = metricKeys[sender.tag]
        let value = CGFloat(sender.doubleValue)
        if let definition = metricDefinitions.first(where: { $0.key == key }) {
            metricValueLabels[key]?.stringValue = formatted(definition, value)
        }
        if key == "glassTransparency" {
            windowPanel.setGlassTransparency(value)
        } else {
            var metrics = settings.metrics
            switch key {
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
        hooks.refreshPanelPreview()
    }

    @objc private func recordShortcut(_ sender: AppActionButton) {
        guard let role = role(from: sender) else { return }
        shortcuts.presentRecorder(for: role)
        rebuildPage()
    }

    @objc private func resetShortcut(_ sender: AppActionButton) {
        guard let role = role(from: sender) else { return }
        shortcuts.reset(role)
        rebuildPage()
    }

    @objc private func openPermission() {
        hooks.showPermissionWindow()
    }

    @objc private func copyAppPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(AppInstallation.path, forType: .string)
    }

    @objc private func revealApp() {
        hooks.revealApp()
    }

    @objc private func resetPermission() {
        hooks.resetPermission()
        rebuildPage()
    }

    @objc private func openPocket() {
        hooks.openPocket()
    }

    @objc private func clearPocket() {
        hooks.clearPocket()
        rebuildPage()
    }

    @objc private func openRelayBridge() {
        hooks.openRelayBridge()
    }

    @objc private func stopAllRelays() {
        hooks.stopAllRelays()
        rebuildPage()
    }

    @objc private func showPreview() {
        hooks.showPanelPreview()
    }

    // MARK: - Diagnostics

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }

    // MARK: - Render evidence

    private func compose(_ view: NSView, to url: URL) -> [String: Any] {
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
        // The backing store is 2x while the view is measured in points; without this
        // scale the content lands in the bottom-left quarter of the bitmap.
        context.cgContext.scaleBy(x: CGFloat(bitmap.pixelsWide) / view.bounds.width,
                                  y: CGFloat(bitmap.pixelsHigh) / view.bounds.height)
        // Dynamic colours resolve against the current drawing appearance. Without
        // this, dark mode produced white labels on a light background in the cache.
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            let isDark = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let colors = isDark
                ? [NSColor(calibratedRed: 0.09, green: 0.12, blue: 0.17, alpha: 1),
                   NSColor(calibratedRed: 0.16, green: 0.20, blue: 0.26, alpha: 1)]
                : [NSColor(calibratedRed: 0.87, green: 0.91, blue: 0.96, alpha: 1),
                   NSColor(calibratedRed: 0.96, green: 0.93, blue: 0.88, alpha: 1)]
            NSGradient(colors: colors)?.draw(in: view.bounds, angle: -70)
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
                "pixelsWide": bitmap.pixelsWide, "pixelsHigh": bitmap.pixelsHigh]
    }

    /// Renders each settings page on its own, so layout regressions are visible
    /// without a screenshot of the desktop.
    func renderPages(basePath: String) -> [String: Any] {
        _ = ensureWindow()
        var pages: [[String: Any]] = []
        for index in 0..<pageTitles.count {
            selectPage(index)
            guard let page = currentPageView else { continue }
            let path = basePath.replacingOccurrences(of: ".png", with: "-p\(index).png")
            var entry = compose(page, to: URL(fileURLWithPath: path))
            entry["page"] = index
            entry["title"] = pageTitles[index]
            entry["appearance"] = NSApp.effectiveAppearance.name.rawValue
            pages.append(entry)
        }
        return ["pageCount": pages.count, "pages": pages,
                "appearance": NSApp.effectiveAppearance.name.rawValue]
    }

    func renderWindow(to basePath: String) -> [String: Any] {
        _ = ensureWindow()
        selectPage(0)
        guard let window = window, let view = window.contentView else { return ["error": "无窗口"] }
        let path = basePath.replacingOccurrences(of: ".png", with: "-window.png")
        var report = compose(view, to: URL(fileURLWithPath: path))
        report["appearance"] = NSApp.effectiveAppearance.name.rawValue
        return report
    }

    /// Builds every page offscreen so the menu smoke test can prove the whole
    /// settings surface exists even when nothing is shown on screen.
    func smokeReport() -> [String: Any] {
        _ = ensureWindow()
        let saved = currentPage
        var pageSubviewCounts: [Int] = []
        var sliderCount = 0
        var switchCount = 0
        var bulkSelectPresent = false
        for index in 0..<pageTitles.count {
            selectPage(index)
            let page = currentPageView
            pageSubviewCounts.append(page?.subviews.count ?? 0)
            let all = page.map { descendants(of: $0) } ?? []
            sliderCount = max(sliderCount, all.filter { $0 is NSSlider }.count)
            switchCount += all.filter { $0 is NSSwitch }.count
            if index == 1 {
                let titles = Set(all.compactMap { ($0 as? NSButton)?.title })
                bulkSelectPresent = titles.contains("全选") && titles.contains("全不选")
            }
        }
        selectPage(saved)
        let managed = settings.managedApps(installed: hooks.installedApps()).count
        return ["settingsWindowConstructed": window != nil,
                "settingsGlassMaterial": glassMaterial,
                "settingsPageCount": pageTitles.count,
                "settingsSidebarItemCount": sidebarItems.count,
                "settingsPageSubviewCounts": pageSubviewCounts,
                "settingsAppRowCount": lastAppRowCount,
                "settingsManagedAppCount": managed,
                "settingsAppRowsMatchManagedApps": lastAppRowCount == managed,
                "settingsSliderCount": sliderCount,
                "settingsAppearanceSlidersComplete": sliderCount == 7,
                "settingsSwitchCount": switchCount,
                "settingsBulkSelectPresent": bulkSelectPresent,
                "settingsSidebarComplete": sidebarItems.count == pageTitles.count,
                "settingsWindowSize": "\(Int(windowSize.width))x\(Int(windowSize.height))"]
    }
}
