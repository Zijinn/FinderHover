import AppKit
import Carbon.HIToolbox

@main
struct ShortcutTests {
    static var passed = 0

    static func check(_ name: String, _ condition: @autoclosure () -> Bool) {
        guard condition() else {
            fputs("FAIL: \(name)\n", stderr)
            exit(1)
        }
        passed += 1
        print("PASS: \(name)")
    }

    static func main() {
        let standard = GlobalShortcut.defaultValue
        check("default shortcut uses Option-Space", standard.keyCode == UInt32(kVK_Space) && standard.modifiers == UInt32(optionKey))
        check("default shortcut has readable label", standard.displayName == "⌥Space")
        let custom = GlobalShortcut(keyCode: UInt32(kVK_ANSI_K),
                                    modifiers: UInt32(controlKey | optionKey | shiftKey))
        check("custom shortcut modifiers and key format correctly", custom.displayName == "⌃⌥⇧K")
        check("shortcut is value-comparable", custom == GlobalShortcut(keyCode: UInt32(kVK_ANSI_K),
                                                                         modifiers: UInt32(controlKey | optionKey | shiftKey)))
        print("\(passed) shortcut tests passed.")
    }
}
