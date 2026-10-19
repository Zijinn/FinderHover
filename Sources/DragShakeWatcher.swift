import AppKit
import CoreGraphics

/// Detects a deliberate side-to-side shake while the mouse button is held down,
/// i.e. while the user is dragging something.
///
/// A drag that starts in another process (Finder, Mail, Photos …) never reaches our
/// event monitors: AppKit runs that drag inside the source app's own nested event
/// loop, so `leftMouseDragged` global monitors stay silent. The only dependable
/// signal is polling the hardware button state plus the cursor position, then
/// filtering it through the same `ShakeDetector` the menu bar icon uses.
final class DragShakeWatcher {
    var onShake: ((CGPoint) -> Void)?

    private var detector: ShakeDetector
    private var timer: Timer?
    private var buttonDownSince: TimeInterval?
    private var lastShakeAt: TimeInterval = -Double.greatestFiniteMagnitude

    /// A click that has not become a drag yet must not be read as a shake.
    private let minimumHoldDuration: TimeInterval = 0.12
    /// One summoned pocket per gesture; prevents a jittery drag from re-opening it.
    private let retriggerInterval: TimeInterval = 1.2

    init(minimumSegmentDistance: CGFloat = 18,
         maximumDuration: TimeInterval = 0.9,
         cooldownDuration: TimeInterval = 1.1,
         requiredSegments: Int = 4) {
        detector = ShakeDetector(minimumSegmentDistance: minimumSegmentDistance,
                                 maximumDuration: maximumDuration,
                                 cooldownDuration: cooldownDuration,
                                 requiredSegments: requiredSegments)
    }

    var isRunning: Bool { timer != nil }

    func start(interval: TimeInterval = 1.0 / 60.0) {
        stop()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        buttonDownSince = nil
        lastShakeAt = -Double.greatestFiniteMagnitude
        detector.reset()
    }

    private func poll() {
        let buttonDown = NSEvent.pressedMouseButtons & 0x1 != 0
        process(point: NSEvent.mouseLocation, buttonDown: buttonDown,
                now: ProcessInfo.processInfo.systemUptime)
    }

    /// Pure entry point so the gating rules can be tested without a timer or a real
    /// drag. Returns true when this call is the one that completed a shake.
    @discardableResult
    func process(point: CGPoint, buttonDown: Bool, now: TimeInterval) -> Bool {
        guard buttonDown else {
            buttonDownSince = nil
            detector.reset()
            return false
        }
        if buttonDownSince == nil { buttonDownSince = now }
        guard now - (buttonDownSince ?? now) >= minimumHoldDuration else { return false }
        guard now - lastShakeAt >= retriggerInterval else { return false }
        guard detector.update(point: point, inside: true, now: now) else { return false }
        lastShakeAt = now
        onShake?(point)
        return true
    }
}
