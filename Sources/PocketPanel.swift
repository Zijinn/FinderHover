import AppKit
import Foundation

private let pocketDataType = NSPasteboard.PasteboardType("public.data")
private final class PocketPassivePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class PocketFlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class PocketPanel: NSObject {
    let store: PocketStore
    private let window: PocketPassivePanel
    private let root: PocketFlippedView
    private let listView = PocketListView()
    private let countLabel = NSTextField(labelWithString: "0 项")
    private let messageLabel = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView()
    private var selectedIDs = Set<UUID>()
    private let panelSize = NSSize(width: 360, height: 430)

    var onItemsAdded: (() -> Void)?
    var onClear: (() -> Void)?
    var onCountChanged: ((Int) -> Void)?
    var isVisible: Bool { window.isVisible }
    var frame: NSRect { window.frame }

    init(store: PocketStore) {
        self.store = store
        let initial = NSRect(origin: .zero, size: panelSize)
        window = PocketPassivePanel(contentRect: initial,
                                    styleMask: [.borderless, .nonactivatingPanel],
                                    backing: .buffered, defer: false)
        root = PocketFlippedView(frame: NSRect(origin: .zero, size: panelSize))
        super.init()
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.isOpaque = false
        window.level = .popUpMenu
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.animationBehavior = .none
        window.hasShadow = true
        root.wantsLayer = true
        root.layer?.cornerRadius = 18
        root.layer?.masksToBounds = true

        let effect = NSVisualEffectView(frame: root.bounds)
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.autoresizingMask = [.width, .height]
        root.addSubview(effect, positioned: .below, relativeTo: nil)

        let title = NSTextField(labelWithString: "临时口袋")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.frame = NSRect(x: 16, y: 13, width: 105, height: 22)
        root.addSubview(title)
        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor
        countLabel.frame = NSRect(x: 122, y: 16, width: 95, height: 18)
        root.addSubview(countLabel)

        let close = NSButton(title: "×", target: self, action: #selector(closePanel))
        close.bezelStyle = .circular
        close.frame = NSRect(x: 322, y: 9, width: 26, height: 26)
        close.setAccessibilityLabel("关闭口袋")
        root.addSubview(close)

        let clear = NSButton(title: "清空", target: self, action: #selector(clearItems))
        clear.bezelStyle = .rounded
        clear.frame = NSRect(x: 257, y: 10, width: 58, height: 25)
        root.addSubview(clear)

        let clipboard = NSButton(title: "收纳剪贴板图片", target: self, action: #selector(importClipboardImage))
        clipboard.bezelStyle = .rounded
        clipboard.frame = NSRect(x: 14, y: 45, width: 150, height: 27)
        clipboard.setAccessibilityHelp("将系统剪贴板中的截图或其他栅格图片保存为 PNG")
        root.addSubview(clipboard)
        messageLabel.font = .systemFont(ofSize: 10)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.frame = NSRect(x: 171, y: 50, width: 174, height: 17)
        root.addSubview(messageLabel)

        scrollView.frame = NSRect(x: 8, y: 79, width: 344, height: 342)
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        listView.store = store
        listView.panel = self
        listView.selectedIDs = selectedIDs
        scrollView.documentView = listView
        root.addSubview(scrollView)
        root.registerForDraggedTypes([.fileURL, .URL, .png, .tiff, pocketDataType])
        window.contentView = root
        store.onChange = { [weak self] in self?.reload() }
        reload()
    }

    func show(near anchor: NSRect? = nil) {
        let screen = anchor.flatMap { rect in
            NSScreen.screens.first(where: { $0.frame.intersects(rect) })
        } ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen = screen else { window.orderFrontRegardless(); return }
        let visible = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        var origin = CGPoint(x: visible.maxX - panelSize.width,
                             y: visible.maxY - panelSize.height - 8)
        if let anchor = anchor {
            origin.x = anchor.midX - panelSize.width / 2
            origin.y = anchor.minY - panelSize.height - 8
        }
        origin.x = min(max(origin.x, visible.minX), max(visible.minX, visible.maxX - panelSize.width))
        origin.y = min(max(origin.y, visible.minY), max(visible.minY, visible.maxY - panelSize.height))
        window.setFrame(NSRect(origin: origin, size: panelSize), display: true)
        window.orderFrontRegardless()
    }

    func hide() { window.orderOut(nil) }

    func toggle(near anchor: NSRect? = nil) {
        if isVisible { hide() } else { show(near: anchor) }
    }

    func reload() {
        selectedIDs = selectedIDs.intersection(Set(store.items.map(\.id)))
        listView.selectedIDs = selectedIDs
        let viewportHeight = scrollView.contentSize.height > 0 ? scrollView.contentSize.height : 342
        listView.frame = NSRect(x: 0, y: 0,
                                width: scrollView.contentSize.width > 0 ? scrollView.contentSize.width : 328,
                                height: max(viewportHeight, CGFloat(store.count) * PocketListView.rowHeight))
        listView.needsDisplay = true
        countLabel.stringValue = "\(store.count) 项"
        onCountChanged?(store.count)
    }

    fileprivate func selectItem(at index: Int, modifiers: NSEvent.ModifierFlags) {
        guard store.items.indices.contains(index) else { return }
        let id = store.items[index].id
        if modifiers.contains(.command) || modifiers.contains(.shift) {
            if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
        } else if !selectedIDs.contains(id) {
            selectedIDs = [id]
        }
        listView.selectedIDs = selectedIDs
        listView.needsDisplay = true
    }

    fileprivate func selectedItems() -> [PocketItem] {
        let selected = store.items.filter { selectedIDs.contains($0.id) }
        return selected.isEmpty ? store.items : selected
    }

    fileprivate func didAcceptDrop(_ pasteboard: NSPasteboard) -> Bool {
        let added = store.addPasteboard(pasteboard)
        if added > 0 {
            messageLabel.stringValue = "已收纳 \(added) 项"
            onItemsAdded?()
            return true
        }
        messageLabel.stringValue = "没有可收纳的文件或图片"
        return false
    }

    @objc private func closePanel() { hide() }

    @objc private func clearItems() {
        store.clear()
        selectedIDs.removeAll()
        messageLabel.stringValue = "口袋已清空"
        onClear?()
    }

    @objc private func importClipboardImage() {
        if store.addImageFromPasteboard(.general) != nil {
            messageLabel.stringValue = "已收纳剪贴板图片"
            onItemsAdded?()
        } else {
            messageLabel.stringValue = "剪贴板中没有可用图片"
        }
    }
}

private final class PocketListView: NSView, NSDraggingSource {
    static let rowHeight: CGFloat = 58
    weak var store: PocketStore?
    weak var panel: PocketPanel?
    var selectedIDs = Set<UUID>()
    private var dragStart: NSPoint?
    private var dragStarted = false

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL, .URL, .png, .tiff, pocketDataType])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        guard let store = store else { return }
        if store.items.isEmpty {
            let empty = "口袋还是空的\n拖入文件，或从剪贴板收纳图片" as NSString
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            style.lineSpacing = 5
            empty.draw(in: NSRect(x: 12, y: 118, width: max(0, bounds.width - 24), height: 55),
                       withAttributes: [.font: NSFont.systemFont(ofSize: 13),
                                        .foregroundColor: NSColor.secondaryLabelColor,
                                        .paragraphStyle: style])
            return
        }
        for (index, item) in store.items.enumerated() {
            let rect = NSRect(x: 5, y: CGFloat(index) * Self.rowHeight + 2,
                              width: max(0, bounds.width - 10), height: Self.rowHeight - 4)
            if selectedIDs.contains(item.id) {
                NSColor.selectedContentBackgroundColor.withAlphaComponent(0.28).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
            }
            let image: NSImage
            if item.kind == .image, item.isValid, let thumbnail = NSImage(contentsOf: item.url) {
                image = thumbnail
            } else {
                image = NSWorkspace.shared.icon(forFile: item.url.path)
            }
            image.draw(in: NSRect(x: rect.minX + 8, y: rect.minY + 7, width: 36, height: 36))
            let title = item.displayName as NSString
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingMiddle
            title.draw(in: NSRect(x: rect.minX + 53, y: rect.minY + 8,
                                  width: max(0, rect.width - 64), height: 19),
                       withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium),
                                        .foregroundColor: NSColor.labelColor,
                                        .paragraphStyle: paragraph])
            let detail: String
            if !item.isValid { detail = "源文件已不可用" }
            else if item.kind == .image { detail = "图片 · \(item.url.pathExtension.uppercased())" }
            else { detail = "文件 · 拖出时复制" }
            (detail as NSString).draw(at: NSPoint(x: rect.minX + 53, y: rect.minY + 29),
                                      withAttributes: [.font: NSFont.systemFont(ofSize: 10),
                                                       .foregroundColor: NSColor.secondaryLabelColor])
        }
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil)
        dragStarted = false
        let index = Int((dragStart?.y ?? 0) / Self.rowHeight)
        panel?.selectItem(at: index, modifiers: event.modifierFlags)
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragStarted, let start = dragStart else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) >= 4,
              let store = store, let panel = panel else { return }
        let items = panel.selectedItems().filter { $0.isValid }
        guard !items.isEmpty else { return }
        let dragItems: [NSDraggingItem] = items.enumerated().compactMap { offset, item in
            guard let url = store.exportURL(for: item) else { return nil }
            let writer = NSPasteboardItem()
            writer.setString(url.absoluteString, forType: .fileURL)
            let dragging = NSDraggingItem(pasteboardWriter: writer)
            let image = item.kind == .image ? (NSImage(contentsOf: url) ?? NSWorkspace.shared.icon(forFile: url.path)) :
                NSWorkspace.shared.icon(forFile: url.path)
            dragging.setDraggingFrame(NSRect(x: start.x + CGFloat(offset) * 6,
                                             y: start.y + CGFloat(offset) * 6,
                                             width: 44, height: 44), contents: image)
            return dragging
        }
        guard !dragItems.isEmpty else { return }
        dragStarted = true
        _ = beginDraggingSession(with: dragItems, event: event, source: self)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let store = store, store.hasAcceptablePasteboardContent(sender.draggingPasteboard) else { return [] }
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let store = store else { return false }
        return store.hasAcceptablePasteboardContent(sender.draggingPasteboard)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        panel?.didAcceptDrop(sender.draggingPasteboard) ?? false
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
}
