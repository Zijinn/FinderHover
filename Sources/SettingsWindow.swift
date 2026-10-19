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
}

private final class SidebarItemView: NSView {
    let index: Int
    private let label: NSTextField
    private let iconView: NSImageView
    var onClick: ((Int) -> Void)?

    var isSelected = false {
        didSet {
            needsDisplay = true
            label.textColor = isSelected ? .labelColor : .secondaryLabelColor
            iconView.contentTintColor = isSelected ? .controlAccentColor : .secondaryLabelColor
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
        NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
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

    private let pageTitles = ["权限", "窗口切换", "临时口袋", "外观"]
    private let pageSymbols = ["lock.shield", "macwindow.on.rectangle", "tray.full", "slider.horizontal.3"]

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
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "MacToolbox 设置"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = windowSize

        let root = FlippedContainerView(frame: NSRect(origin: .zero, size: windowSize))
        window.contentView = root

        let sidebar = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: sidebarWidth, height: windowSize.height))
        sidebar.material = .sidebar
        sidebar.blendingMode = .behindWindow
        sidebar.state = .active
        sidebar.autoresizingMask = [.height]
        root.addSubview(sidebar)

        root.addSubview(UIKitBits.separator(frame: NSRect(x: sidebarWidth, y: 0, width: 0.5,
                                                          height: windowSize.height)))

        let appIcon = NSImageView(frame: NSRect(x: 16, y: 18, width: 22, height: 22))
        appIcon.image = NSApp.applicationIconImage
        appIcon.imageScaling = .scaleProportionallyUpOrDown
        root.addSubview(appIcon)
        root.addSubview(UIKitBits.label("MacToolbox", size: 13, weight: .semibold,
                                        frame: NSRect(x: 46, y: 20, width: 120, height: 18)))

        for (index, title) in pageTitles.enumerated() {
            let item = SidebarItemView(index: index, title: title, symbol: pageSymbols[index],
                                       frame: NSRect(x: 12, y: 56 + CGFloat(index) * 36,
                                                     width: sidebarWidth - 24, height: 32))
            item.onClick = { [weak self] index in self?.selectPage(index) }
            item.isSelected = index == 0
            root.addSubview(item)
            sidebarItems.append(item)
        }

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
        view.cornerRadius = 10
        view.fillColor = NSColor.labelColor.withAlphaComponent(0.035)
        view.borderColor = NSColor.separatorColor.withAlphaComponent(0.55)
        page.addSubview(view)
        return view
    }

    private func addHeader(_ title: String, _ subtitle: String, to page: NSView) {
        page.addSubview(UIKitBits.label(title, size: 20, weight: .semibold,
                                        frame: NSRect(x: contentX, y: 24, width: contentWidth, height: 26)))
        page.addSubview(UIKitBits.paragraph(subtitle, size: 13, color: .secondaryLabelColor,
                                            frame: NSRect(x: contentX, y: 56, width: contentWidth, height: 18),
                                            lines: 1))
        page.addSubview(UIKitBits.separator(frame: NSRect(x: contentX, y: 86, width: contentWidth, height: 1)))
    }

    private func sectionLabel(_ title: String, at point: NSPoint, width: CGFloat, to parent: NSView) {
        parent.addSubview(UIKitBits.label(title, size: 12, weight: .medium, color: .secondaryLabelColor,
                                          frame: NSRect(x: point.x, y: point.y, width: width, height: 18)))
    }

    private func addSwitch(_ title: String, isOn: Bool, action: Selector,
                           at point: NSPoint, to parent: NSView) -> NSSwitch {
        let toggle = NSSwitch(frame: NSRect(x: point.x, y: point.y, width: 38, height: 22))
        toggle.state = isOn ? .on : .off
        toggle.target = self
        toggle.action = action
        toggle.setAccessibilityLabel(title)
        parent.addSubview(toggle)
        parent.addSubview(UIKitBits.label(title, size: 13,
                                          frame: NSRect(x: point.x + 48, y: point.y + 2,
                                                        width: max(80, parent.bounds.width - point.x - 64),
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
        let status = card(NSRect(x: contentX, y: 104, width: contentWidth, height: 108), to: page)
        let pill = StatusPillView(frame: NSRect(x: 16, y: 14, width: 80, height: 22))
        pill.text = trusted ? "已授权" : "未授权"
        pill.tint = trusted ? .systemGreen : .systemOrange
        let pillWidth = pill.intrinsicContentSize.width
        pill.frame = NSRect(x: 16, y: 14, width: pillWidth, height: 22)
        status.addSubview(pill)

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

        let steps = card(NSRect(x: contentX, y: 228, width: contentWidth, height: 190), to: page)
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
        open.frame = NSRect(x: contentX, y: 432, width: 150, height: 30)
        page.addSubview(open)

        let reveal = NSButton(title: "在访达中显示", target: self, action: #selector(revealApp))
        reveal.bezelStyle = .rounded
        reveal.frame = NSRect(x: contentX + 158, y: 432, width: 118, height: 30)
        page.addSubview(reveal)

        let reset = NSButton(title: "重置权限", target: self, action: #selector(resetPermission))
        reset.bezelStyle = .inline
        reset.isBordered = false
        reset.font = .systemFont(ofSize: 12)
        reset.contentTintColor = .secondaryLabelColor
        reset.frame = NSRect(x: contentX + 288, y: 436, width: 76, height: 24)
        page.addSubview(reset)

        let copies = AppInstallation.duplicateCopies()
        let note: String
        let noteColor: NSColor
        if !copies.isEmpty {
            let names = copies.map { ($0 as NSString).lastPathComponent }.joined(separator: "、")
            note = "检测到另外 \(copies.count) 份副本：\(names)。辅助功能按路径授权，只有上面「当前程序」这一份的开关有效。"
            noteColor = .systemOrange
        } else {
            note = "重置会从系统设置中移除本应用的授权条目，用于修复开关变灰或授权失效；重置后需要重新添加。"
            noteColor = .tertiaryLabelColor
        }
        page.addSubview(UIKitBits.paragraph(note, size: 11, color: noteColor,
                                            frame: NSRect(x: contentX, y: 476, width: contentWidth, height: 44),
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

        let top = card(NSRect(x: contentX, y: 104, width: contentWidth, height: 96), to: page)
        _ = addSwitch("启用悬停切窗", isOn: settings.isToolEnabled(.windowSwitcher),
                      action: #selector(toggleSwitcher), at: NSPoint(x: 16, y: 14), to: top)
        addShortcutRow(role: .windowSwitcherPanel, title: "面板快捷键", y: 56, to: top)

        let installed = hooks.installedApps()
        let apps = settings.managedApps(installed: installed)
        sectionLabel("启用哪些应用", at: NSPoint(x: contentX, y: 216), width: 130, to: page)

        let selectAll = NSButton(title: "全选", target: self, action: #selector(selectAllApps))
        selectAll.bezelStyle = .inline
        selectAll.isBordered = false
        selectAll.font = .systemFont(ofSize: 11)
        selectAll.contentTintColor = .controlAccentColor
        selectAll.frame = NSRect(x: contentX + 136, y: 212, width: 40, height: 22)
        selectAll.setAccessibilityHelp("启用列表里的全部应用")
        page.addSubview(selectAll)

        let selectNone = NSButton(title: "全不选", target: self, action: #selector(selectNoneApps))
        selectNone.bezelStyle = .inline
        selectNone.isBordered = false
        selectNone.font = .systemFont(ofSize: 11)
        selectNone.contentTintColor = .secondaryLabelColor
        selectNone.frame = NSRect(x: contentX + 182, y: 212, width: 52, height: 22)
        selectNone.setAccessibilityHelp("关闭列表里的全部应用")
        page.addSubview(selectNone)

        let enabledCount = UIKitBits.label("\(apps.filter { $0.isEnabled }.count) / \(apps.count) 已启用",
                                           size: 11, color: .secondaryLabelColor,
                                           frame: NSRect(x: contentX + 360, y: 216, width: 152, height: 18))
        enabledCount.alignment = .right
        page.addSubview(enabledCount)

        _ = card(NSRect(x: contentX, y: 240, width: contentWidth, height: 246), to: page)
        let scroll = NSScrollView(frame: NSRect(x: contentX + 1, y: 241, width: contentWidth - 2, height: 244))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = CGFloat(apps.count) * 42 > 244
        scroll.hasHorizontalScroller = false
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        let document = FlippedContainerView(frame: NSRect(x: 0, y: 0, width: contentWidth - 14,
                                                          height: max(244, CGFloat(apps.count) * 42)))
        for (offset, app) in apps.enumerated() {
            document.addSubview(appRow(app, y: CGFloat(offset) * 42, isLast: offset == apps.count - 1))
        }
        scroll.documentView = document
        page.addSubview(scroll)
        lastAppRowCount = apps.count

        let add = NSButton(title: "添加其他应用…", target: self, action: #selector(addApp))
        add.bezelStyle = .rounded
        add.frame = NSRect(x: contentX, y: 500, width: 130, height: 28)
        page.addSubview(add)
    }

    private func appRow(_ app: ManagedApp, y: CGFloat, isLast: Bool) -> NSView {
        let row = SettingsRowView(frame: NSRect(x: 0, y: y, width: contentWidth - 14, height: 42))
        row.showsSeparator = !isLast

        let icon = NSImageView(frame: NSRect(x: 12, y: 11, width: 20, height: 20))
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleIdentifier) {
            icon.image = NSWorkspace.shared.icon(forFile: url.path)
        }
        row.addSubview(icon)

        row.addSubview(UIKitBits.label(app.displayName, size: 13,
                                       frame: NSRect(x: 40, y: 11, width: 168, height: 20)))

        let enable = AppActionButton(frame: NSRect(x: 208, y: 12, width: 64, height: 18))
        enable.setButtonType(.switch)
        enable.title = "启用"
        enable.font = .systemFont(ofSize: 12)
        enable.state = app.isEnabled ? .on : .off
        enable.target = self
        enable.action = #selector(toggleAppEnabled(_:))
        enable.bundleIdentifier = app.bundleIdentifier
        row.addSubview(enable)

        let minimized = AppActionButton(frame: NSRect(x: 276, y: 12, width: 84, height: 18))
        minimized.setButtonType(.switch)
        minimized.title = "最小化"
        minimized.font = .systemFont(ofSize: 12)
        minimized.state = app.config.includeMinimized ? .on : .off
        minimized.target = self
        minimized.action = #selector(toggleAppMinimized(_:))
        minimized.bundleIdentifier = app.bundleIdentifier
        row.addSubview(minimized)

        let popup = AppPopupButton(frame: NSRect(x: 364, y: 9, width: 84, height: 24), pullsDown: false)
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
            row.addSubview(remove)
        }

        return row
    }

    // MARK: - Page: pocket

    private func buildPocketPage(into page: NSView) {
        addHeader("临时口袋", "把文件或图片先放进来，需要时再拖出去。", to: page)

        let top = card(NSRect(x: contentX, y: 104, width: contentWidth, height: 96), to: page)
        _ = addSwitch("启用临时口袋", isOn: settings.isToolEnabled(.pocket),
                      action: #selector(togglePocket), at: NSPoint(x: 16, y: 14), to: top)
        addShortcutRow(role: .pocket, title: "口袋快捷键", y: 56, to: top)

        let info = card(NSRect(x: contentX, y: 212, width: contentWidth, height: 132), to: page)
        sectionLabel("当前口袋", at: NSPoint(x: 16, y: 14), width: 200, to: info)
        info.addSubview(UIKitBits.label("\(pocketStore.count) 项", size: 22, weight: .medium,
                                        frame: NSRect(x: 16, y: 36, width: 200, height: 28)))

        let open = NSButton(title: "打开口袋", target: self, action: #selector(openPocket))
        open.bezelStyle = .rounded
        open.frame = NSRect(x: 16, y: 86, width: 110, height: 28)
        open.isEnabled = settings.isToolEnabled(.pocket)
        info.addSubview(open)

        let clear = NSButton(title: "清空", target: self, action: #selector(clearPocket))
        clear.bezelStyle = .rounded
        clear.frame = NSRect(x: 134, y: 86, width: 80, height: 28)
        clear.isEnabled = pocketStore.count > 0
        info.addSubview(clear)

        page.addSubview(UIKitBits.paragraph(
            "口袋内容只保存在本次运行中，退出应用即清空。普通文件保留原位置，拖出时默认复制；从剪贴板导入的截图会另存为临时 PNG，清空时一并删除。",
            size: 12, color: .secondaryLabelColor,
            frame: NSRect(x: contentX, y: 364, width: contentWidth, height: 60), lines: 3))
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

        let panel = card(NSRect(x: contentX, y: 104, width: contentWidth, height: 360), to: page)
        for (offset, definition) in metricDefinitions.enumerated() {
            panel.addSubview(metricRow(definition, y: CGFloat(12 + offset * 48)))
            lastSliderCount += 1
        }

        _ = addSwitch("宽度自适应标题", isOn: settings.metrics.autoFitWidth,
                      action: #selector(toggleAutoFit), at: NSPoint(x: contentX, y: 476), to: page)

        let reset = NSButton(title: "恢复默认外观", target: self, action: #selector(resetMetrics))
        reset.bezelStyle = .rounded
        reset.frame = NSRect(x: contentX, y: 504, width: 120, height: 28)
        page.addSubview(reset)

        let preview = NSButton(title: "预览面板", target: self, action: #selector(showPreview))
        preview.bezelStyle = .rounded
        preview.frame = NSRect(x: contentX + 128, y: 504, width: 100, height: 28)
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
    }

    @objc private func togglePocket(_ sender: NSSwitch) {
        settings.setToolEnabled(sender.state == .on, for: .pocket)
        if sender.state == .off { hooks.clearPocket() }
    }

    @objc private func toggleAppEnabled(_ sender: AppActionButton) {
        settings.setEnabled(sender.state == .on, for: sender.bundleIdentifier)
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
        context.cgContext.setFillColor(NSColor.windowBackgroundColor.cgColor)
        context.cgContext.fill(view.bounds)
        cache.draw(in: view.bounds)
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
            pages.append(entry)
        }
        return ["pageCount": pages.count, "pages": pages]
    }

    func renderWindow(to basePath: String) -> [String: Any] {
        _ = ensureWindow()
        selectPage(0)
        guard let window = window, let view = window.contentView else { return ["error": "无窗口"] }
        let path = basePath.replacingOccurrences(of: ".png", with: "-window.png")
        return compose(view, to: URL(fileURLWithPath: path))
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
