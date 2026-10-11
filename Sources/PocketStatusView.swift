import AppKit
import Foundation

private let pocketDataType = NSPasteboard.PasteboardType("public.data")

final class PocketStatusView: NSView {
    var onClick: (() -> Void)?
    var onShake: (() -> Void)?
    var onDrop: ((NSPasteboard) -> Bool)?
    private weak var statusButton: NSStatusBarButton?
    private var icon: NSImage?
    private var count = 0
    private var shakeDetector = ShakeDetector(minimumSegmentDistance: 5,
                                               maximumDuration: 0.75,
                                               cooldownDuration: 0.9,
                                               requiredSegments: 4)
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var lastShakeTime: TimeInterval = -Double.greatestFiniteMagnitude

    init(image: NSImage?, statusButton: NSStatusBarButton) {
        self.icon = image
        self.statusButton = statusButton
        super.init(frame: statusButton.bounds)
        autoresizingMask = [.width, .height]
        registerForDraggedTypes([.fileURL, .URL, .png, .tiff, pocketDataType])
        setAccessibilityElement(false)
        let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeAlways, .inVisibleRect]
        addTrackingArea(NSTrackingArea(rect: .zero, options: options, owner: self))
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.observe(point: NSEvent.mouseLocation, now: event.timestamp)
            return event
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            let point = NSEvent.mouseLocation
            DispatchQueue.main.async { self?.observe(point: point, now: event.timestamp) }
        }
        toolTip = "在图标附近快速左右晃动两次打开口袋；也可拖入文件"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        if let local = localMouseMonitor { NSEvent.removeMonitor(local) }
        if let global = globalMouseMonitor { NSEvent.removeMonitor(global) }
    }

    func setCount(_ value: Int) {
        count = max(0, value)
        needsDisplay = true
    }

    func statusFrameInScreen() -> NSRect {
        guard let window = window else { return .zero }
        return window.convertToScreen(convert(bounds, to: nil))
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let icon = icon else { return }
        let imageRect = NSRect(x: max(0, (bounds.width - 20) / 2), y: 2, width: 20, height: 18)
        icon.draw(in: imageRect)
        guard count > 0 else { return }
        let text = "\(count)" as NSString
        let badgeWidth: CGFloat = count > 99 ? 18 : 15
        let badge = NSRect(x: bounds.width - badgeWidth, y: bounds.height - 11,
                           width: badgeWidth, height: 12)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: badge, xRadius: 6, yRadius: 6).fill()
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        text.draw(in: badge.insetBy(dx: 1, dy: 1), withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .bold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph
        ])
    }

    override func mouseDown(with event: NSEvent) {
        if let button = statusButton { button.performClick(nil) }
        else { onClick?() }
    }

    override func mouseExited(with event: NSEvent) {
        _ = shakeDetector.update(point: NSEvent.mouseLocation, inside: false, now: event.timestamp)
    }

    private func observe(point: CGPoint, now: TimeInterval) {
        let hit = statusFrameInScreen().insetBy(dx: -12, dy: -10).contains(point)
        if shakeDetector.update(point: point, inside: hit, now: now) {
            guard now - lastShakeTime >= 0.9 else { return }
            lastShakeTime = now
            onShake?()
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        observe(point: sender.draggingLocation, now: ProcessInfo.processInfo.systemUptime)
        guard sender.draggingPasteboard.availableType(from: [.fileURL, .URL, .png, .tiff, pocketDataType]) != nil else { return [] }
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        observe(point: sender.draggingLocation, now: ProcessInfo.processInfo.systemUptime)
        return sender.draggingPasteboard.availableType(from: [.fileURL, .URL, .png, .tiff, pocketDataType]) != nil ? .copy : []
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        return sender.draggingPasteboard.availableType(from: [.fileURL, .URL, .png, .tiff, pocketDataType]) != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let accepted = onDrop?(sender.draggingPasteboard) ?? false
        if accepted { onShake?() }
        return accepted
    }
}
