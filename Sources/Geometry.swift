import Foundation
import CoreGraphics

enum DockEdge: String { case bottom, left, right }
enum HoverAction: Equatable { case none, show, hide }

struct HoverGate {
    let showDelay: TimeInterval
    let hideDelay: TimeInterval
    private var enteredAt: TimeInterval?
    private var lastInsideAt: TimeInterval?
    private var suppressed = false

    init(showDelay: TimeInterval = 0.28, hideDelay: TimeInterval = 0.25) {
        self.showDelay = showDelay
        self.hideDelay = hideDelay
    }

    mutating func suppressUntilExit() {
        suppressed = true
        enteredAt = nil
        lastInsideAt = nil
    }

    mutating func reset() {
        suppressed = false
        enteredAt = nil
        lastInsideAt = nil
    }

    mutating func update(onIcon: Bool, inPanel: Bool, visible: Bool,
                         now: TimeInterval) -> HoverAction {
        if suppressed {
            if !onIcon && !inPanel { suppressed = false }
            return .none
        }
        if visible {
            enteredAt = nil
            if onIcon || inPanel {
                lastInsideAt = now
                return .none
            }
            if lastInsideAt == nil { lastInsideAt = now }
            if now - (lastInsideAt ?? now) >= hideDelay {
                lastInsideAt = nil
                return .hide
            }
            return .none
        }
        lastInsideAt = nil
        guard onIcon else {
            enteredAt = nil
            return .none
        }
        if enteredAt == nil { enteredAt = now }
        if now - (enteredAt ?? now) >= showDelay {
            enteredAt = nil
            lastInsideAt = now
            return .show
        }
        return .none
    }
}

struct PanelGeometry {
    // Both coordinate systems share the main display's x origin. Only y flips.
    static func appKitRect(fromAX rect: CGRect, mainDisplayTop: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: mainDisplayTop - rect.maxY,
               width: rect.width, height: rect.height)
    }

    static func quartzPoint(fromAppKit point: CGPoint, mainDisplayTop: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: mainDisplayTop - point.y)
    }

    static func frame(size: CGSize, icon: CGRect, visibleScreen: CGRect,
                      edge: DockEdge, gap: CGFloat = 10) -> CGRect {
        let safe = visibleScreen.insetBy(dx: 8, dy: 8)
        let width = min(size.width, safe.width)
        let height = min(size.height, safe.height)
        var origin: CGPoint
        switch edge {
        case .bottom:
            origin = CGPoint(x: icon.midX - width / 2, y: icon.maxY + gap)
        case .left:
            origin = CGPoint(x: icon.maxX + gap, y: icon.midY - height / 2)
        case .right:
            origin = CGPoint(x: icon.minX - width - gap, y: icon.midY - height / 2)
        }
        origin.x = min(max(origin.x, safe.minX), safe.maxX - width)
        origin.y = min(max(origin.y, safe.minY), safe.maxY - height)
        return CGRect(origin: origin, size: CGSize(width: width, height: height))
    }

    static func nearDock(point: CGPoint, screen: CGRect, edge: DockEdge) -> Bool {
        // Includes hidden Dock reveal and magnification; never treats this band as
        // the Finder icon itself. The actual match is always an AX Dock item.
        guard screen.insetBy(dx: -2, dy: -2).contains(point) else { return false }
        switch edge {
        case .bottom: return point.y - screen.minY < 190
        case .left: return point.x - screen.minX < 190
        case .right: return screen.maxX - point.x < 190
        }
    }
}
