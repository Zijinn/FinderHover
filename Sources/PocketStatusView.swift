import AppKit
import Foundation

private let pocketDataType = NSPasteboard.PasteboardType("public.data")

final class PocketStatusView: NSView {
    var onShake: (() -> Void)?
    var onDrop: ((NSPasteboard) -> Bool)?
    var onDropCompleted: (() -> Void)?
    private weak var statusButton: NSStatusBarButton?
    private var count = 0
    private var shakeDetector = ShakeDetector(minimumSegmentDistance: 5,
                                               maximumDuration: 0.75,
                                               cooldownDuration: 0.9,
                                               requiredSegments: 4)
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var lastShakeTime: TimeInterval = -Double.greatestFiniteMagnitude

    var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    init(statusButton: NSStatusBarButton) {
        self.statusButton = statusButton
        super.init(frame: statusButton.bounds)
        autoresizingMask = [.width, .height]
        registerForDraggedTypes([.fileURL, .URL, .png, .tiff, pocketDataType])
        setAccessibilityElement(false)
        let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeAlways, .inVisibleRect]
        addTrackingArea(NSTrackingArea(rect: .zero, options: options, owner: self))
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.observe(point: NSEvent.mouseLocation)
            return event
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            let point = NSEvent.mouseLocation
            DispatchQueue.main.async { self?.observe(point: point) }
        }
        toolTip = "把文件拖到这里即可收纳；在图标附近快速左右晃动两次也能打开口袋"
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
        statusButton?.performClick(nil)
    }

    override func mouseExited(with event: NSEvent) {
        _ = shakeDetector.update(point: NSEvent.mouseLocation, inside: false, now: now)
    }

    private func observe(point: CGPoint) {
        let hit = statusFrameInScreen().insetBy(dx: -12, dy: -10).contains(point)
        let current = now
        if shakeDetector.update(point: point, inside: hit, now: current) {
            guard current - lastShakeTime >= 0.9 else { return }
            lastShakeTime = current
            onShake?()
        }
    }

    // Dragging updates never feed the shake detector: fast horizontal motion while
    // dragging over the icon would otherwise be read as a shake and pop the panel
    // over the drop target.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.availableType(from: [.fileURL, .URL, .png, .tiff, pocketDataType]) != nil else { return [] }
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        return sender.draggingPasteboard.availableType(from: [.fileURL, .URL, .png, .tiff, pocketDataType]) != nil ? .copy : []
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        return sender.draggingPasteboard.availableType(from: [.fileURL, .URL, .png, .tiff, pocketDataType]) != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let accepted = onDrop?(sender.draggingPasteboard) ?? false
        if accepted { onDropCompleted?() }
        return accepted
    }
}
