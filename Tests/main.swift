import Foundation
import CoreGraphics

var passed = 0
func check(_ name: String, _ test: @autoclosure () -> Bool) {
    guard test() else {
        fputs("FAIL: \(name)\n", stderr)
        exit(1)
    }
    passed += 1
    print("PASS: \(name)")
}

var gate = HoverGate()
check("hover does not open immediately", gate.update(onIcon: true, inPanel: false, visible: false, now: 0) == .none)
check("brief pass over icon is ignored", gate.update(onIcon: false, inPanel: false, visible: false, now: 0.1) == .none)
check("new hover starts independent delay", gate.update(onIcon: true, inPanel: false, visible: false, now: 1) == .none)
check("sustained hover opens", gate.update(onIcon: true, inPanel: false, visible: false, now: 1.3) == .show)
check("movement into panel keeps it open", gate.update(onIcon: false, inPanel: true, visible: true, now: 1.4) == .none)
check("crossing a small gap does not close", gate.update(onIcon: false, inPanel: false, visible: true, now: 1.5) == .none)
check("leaving closes after delay", gate.update(onIcon: false, inPanel: false, visible: true, now: 1.7) == .hide)
gate.suppressUntilExit()
check("selection suppresses immediate reopening", gate.update(onIcon: true, inPanel: false, visible: false, now: 2) == .none)
check("suppression stays while over icon", gate.update(onIcon: true, inPanel: false, visible: false, now: 3) == .none)
_ = gate.update(onIcon: false, inPanel: false, visible: false, now: 4)
_ = gate.update(onIcon: true, inPanel: false, visible: false, now: 5)
check("reentry after selection opens again", gate.update(onIcon: true, inPanel: false, visible: false, now: 5.3) == .show)
gate.reset()
check("reset clears pending hover", gate.update(onIcon: true, inPanel: false, visible: false, now: 6) == .none)

let ax = CGRect(x: 100, y: 900, width: 50, height: 50)
check("AX to AppKit flips y", PanelGeometry.appKitRect(fromAX: ax, mainDisplayTop: 1000) == CGRect(x: 100, y: 50, width: 50, height: 50))
let negativeScreenRect = CGRect(x: -1400, y: -800, width: 60, height: 60)
check("secondary screens retain negative x", PanelGeometry.appKitRect(fromAX: negativeScreenRect, mainDisplayTop: 1000) == CGRect(x: -1400, y: 1740, width: 60, height: 60))
let point = CGPoint(x: -1000, y: 1800)
let quartz = PanelGeometry.quartzPoint(fromAppKit: point, mainDisplayTop: 1000)
check("quartz conversion is reversible", PanelGeometry.quartzPoint(fromAppKit: quartz, mainDisplayTop: 1000) == point)

let screen = CGRect(x: 0, y: 80, width: 1440, height: 780)
let icon = CGRect(x: 500, y: 20, width: 50, height: 50)
let size = CGSize(width: 360, height: 458)
let bottom = PanelGeometry.frame(size: size, icon: icon, visibleScreen: screen, edge: .bottom)
check("bottom panel stays in visible screen", screen.insetBy(dx: 8, dy: 8).contains(bottom))
check("bottom panel centered at icon", bottom.midX == icon.midX)
let left = PanelGeometry.frame(size: size, icon: CGRect(x: 10, y: 400, width: 50, height: 50), visibleScreen: screen, edge: .left)
check("left Dock panel opens to right", left.minX == 70)
let right = PanelGeometry.frame(size: size, icon: CGRect(x: 1380, y: 400, width: 50, height: 50), visibleScreen: screen, edge: .right)
check("right Dock panel opens to left", right.maxX == 1370)
let secondary = CGRect(x: -1920, y: 200, width: 1920, height: 1080)
let secondaryPanel = PanelGeometry.frame(size: size, icon: CGRect(x: -1900, y: 220, width: 40, height: 40), visibleScreen: secondary, edge: .bottom)
check("secondary panel clamps without jumping to main screen", secondary.insetBy(dx: 8, dy: 8).contains(secondaryPanel))
let small = PanelGeometry.frame(size: size, icon: icon, visibleScreen: CGRect(x: 0, y: 0, width: 300, height: 200), edge: .bottom)
check("oversized panel shrinks to fit", CGRect(x: 8, y: 8, width: 284, height: 184).contains(small))
check("bottom Dock edge is detected", PanelGeometry.nearDock(point: CGPoint(x: 500, y: 20), screen: CGRect(x: 0, y: 0, width: 1440, height: 900), edge: .bottom))
check("ordinary desktop is not Dock band", !PanelGeometry.nearDock(point: CGPoint(x: 500, y: 500), screen: CGRect(x: 0, y: 0, width: 1440, height: 900), edge: .bottom))
check("other screen is not this Dock band", !PanelGeometry.nearDock(point: CGPoint(x: -500, y: 20), screen: CGRect(x: 0, y: 0, width: 1440, height: 900), edge: .bottom))
print("\(passed) tests passed.")
