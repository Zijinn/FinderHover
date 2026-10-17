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
        let full = GlobalShortcut(keyCode: UInt32(kVK_ANSI_P),
                                  modifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey))
        check("display name keeps control-option-shift-command order", full.displayName == "⌃⌥⇧⌘P")

        runRolePersistenceTests()
        runDefaultRoleTests()
        runRepeatUpdateTests()

        print("\(passed) shortcut tests passed.")
    }

    static func isolatedDefaults() -> (String, UserDefaults) {
        let suite = "FinderHoverShortcutTests.\(UUID().uuidString)"
        return (suite, UserDefaults(suiteName: suite)!)
    }

    static func runRolePersistenceTests() {
        let (suite, defaults) = isolatedDefaults()
        let legacyPocket = GlobalShortcut(keyCode: UInt32(kVK_ANSI_J),
                                          modifiers: UInt32(optionKey | cmdKey))
        let panelShortcut = GlobalShortcut(keyCode: UInt32(kVK_ANSI_W),
                                           modifiers: UInt32(controlKey | optionKey))
        defaults.set(Int(legacyPocket.keyCode), forKey: "shortcutKeyCode")
        defaults.set(Int(legacyPocket.modifiers), forKey: "shortcutModifiers")

        do {
            let manager = ShortcutManager(defaults: defaults)
            check("pocket keeps legacy shortcutKeyCode value", manager.shortcut(for: .pocket) == legacyPocket)
            check("windowSwitcherPanel defaults to nil when never set", manager.shortcut(for: .windowSwitcherPanel) == nil)
            check("windowSwitcherPanel update registers cleanly", manager.update(panelShortcut, for: .windowSwitcherPanel) == noErr)
            check("windowSwitcherPanel reads back new shortcut", manager.shortcut(for: .windowSwitcherPanel) == panelShortcut)
            check("setting windowSwitcherPanel leaves pocket untouched", manager.shortcut(for: .pocket) == legacyPocket)
        }

        do {
            let manager = ShortcutManager(defaults: defaults)
            check("windowSwitcherPanel shortcut survives restart", manager.shortcut(for: .windowSwitcherPanel) == panelShortcut)
            manager.update(nil, for: .windowSwitcherPanel)
            check("sentinel clear makes role nil", manager.shortcut(for: .windowSwitcherPanel) == nil)
        }

        do {
            let manager = ShortcutManager(defaults: defaults)
            check("sentinel clear survives restart", manager.shortcut(for: .windowSwitcherPanel) == nil)
            check("sentinel clear on one role leaves other role intact", manager.shortcut(for: .pocket) == legacyPocket)
        }

        UserDefaults.standard.removePersistentDomain(forName: suite)
    }

    static func runDefaultRoleTests() {
        let (suite, defaults) = isolatedDefaults()
        do {
            let manager = ShortcutManager(defaults: defaults)
            check("pocket falls back to Option-Space when never set", manager.shortcut(for: .pocket) == GlobalShortcut.defaultValue)
            check("windowSwitcherPanel default is nil", ShortcutManager.defaultShortcut(for: .windowSwitcherPanel) == nil)
            check("pocket default shortcut matches role default", ShortcutManager.defaultShortcut(for: .pocket) == GlobalShortcut.defaultValue)
            manager.reset(.windowSwitcherPanel)
            check("reset of nil-default role stays nil", manager.shortcut(for: .windowSwitcherPanel) == nil)
            manager.reset(.pocket)
            check("reset restores pocket role default", manager.shortcut(for: .pocket) == GlobalShortcut.defaultValue)
        }
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }

    static func runRepeatUpdateTests() {
        let (suite, defaults) = isolatedDefaults()
        let value = GlobalShortcut(keyCode: UInt32(kVK_ANSI_R),
                                   modifiers: UInt32(controlKey | optionKey | cmdKey))
        do {
            let manager = ShortcutManager(defaults: defaults)
            var changeCount = 0
            manager.onChange = { _, _ in changeCount += 1 }
            check("first update of new role shortcut succeeds", manager.update(value, for: .windowSwitcherPanel) == noErr)
            check("first update notifies once", changeCount == 1)
            check("repeat update with same value succeeds", manager.update(value, for: .windowSwitcherPanel) == noErr)
            check("repeat update with same value does not re-register", changeCount == 1)
        }
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }
}
