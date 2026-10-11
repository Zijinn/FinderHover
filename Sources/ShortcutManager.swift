import AppKit
import Carbon.HIToolbox

struct GlobalShortcut: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let defaultValue = GlobalShortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey))

    var displayName: String {
        var prefix = ""
        if modifiers & UInt32(controlKey) != 0 { prefix += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { prefix += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { prefix += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { prefix += "⌘" }
        let key = Self.keyNames[keyCode] ?? "Key \(keyCode)"
        return prefix + key
    }

    private static let keyNames: [UInt32: String] = [
        UInt32(kVK_Space): "Space", UInt32(kVK_Return): "Return",
        UInt32(kVK_Tab): "Tab", UInt32(kVK_Delete): "Delete",
        UInt32(kVK_LeftArrow): "←", UInt32(kVK_RightArrow): "→",
        UInt32(kVK_UpArrow): "↑", UInt32(kVK_DownArrow): "↓",
        UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_B): "B",
        UInt32(kVK_ANSI_C): "C", UInt32(kVK_ANSI_D): "D",
        UInt32(kVK_ANSI_E): "E", UInt32(kVK_ANSI_F): "F",
        UInt32(kVK_ANSI_G): "G", UInt32(kVK_ANSI_H): "H",
        UInt32(kVK_ANSI_I): "I", UInt32(kVK_ANSI_J): "J",
        UInt32(kVK_ANSI_K): "K", UInt32(kVK_ANSI_L): "L",
        UInt32(kVK_ANSI_M): "M", UInt32(kVK_ANSI_N): "N",
        UInt32(kVK_ANSI_O): "O", UInt32(kVK_ANSI_P): "P",
        UInt32(kVK_ANSI_Q): "Q", UInt32(kVK_ANSI_R): "R",
        UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_T): "T",
        UInt32(kVK_ANSI_U): "U", UInt32(kVK_ANSI_V): "V",
        UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_X): "X",
        UInt32(kVK_ANSI_Y): "Y", UInt32(kVK_ANSI_Z): "Z",
        UInt32(kVK_ANSI_0): "0", UInt32(kVK_ANSI_1): "1",
        UInt32(kVK_ANSI_2): "2", UInt32(kVK_ANSI_3): "3",
        UInt32(kVK_ANSI_4): "4", UInt32(kVK_ANSI_5): "5",
        UInt32(kVK_ANSI_6): "6", UInt32(kVK_ANSI_7): "7",
        UInt32(kVK_ANSI_8): "8", UInt32(kVK_ANSI_9): "9"
    ]
}

private final class ShortcutCaptureView: NSView {
    var onCapture: ((GlobalShortcut) -> Void)?
    private let label = NSTextField(labelWithString: "按下新的快捷键…")

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        label.alignment = .center
        label.textColor = .secondaryLabelColor
        label.frame = bounds.insetBy(dx: 8, dy: 7)
        label.autoresizingMask = [.width, .height]
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.control, .option, .shift, .command])
        guard !flags.isEmpty else { NSSound.beep(); return }
        let value = GlobalShortcut(keyCode: UInt32(event.keyCode), modifiers: Self.carbonModifiers(flags))
        label.stringValue = value.displayName
        label.textColor = .labelColor
        onCapture?(value)
    }

    override func flagsChanged(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.control, .option, .shift, .command])
        label.stringValue = Self.modifierDisplay(flags)
    }

    private static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var value: UInt32 = 0
        if flags.contains(.control) { value |= UInt32(controlKey) }
        if flags.contains(.option) { value |= UInt32(optionKey) }
        if flags.contains(.shift) { value |= UInt32(shiftKey) }
        if flags.contains(.command) { value |= UInt32(cmdKey) }
        return value
    }

    private static func modifierDisplay(_ flags: NSEvent.ModifierFlags) -> String {
        var value = ""
        if flags.contains(.control) { value += "⌃" }
        if flags.contains(.option) { value += "⌥" }
        if flags.contains(.shift) { value += "⇧" }
        if flags.contains(.command) { value += "⌘" }
        return value.isEmpty ? "按下新的快捷键…" : value
    }
}

final class ShortcutManager {
    private let signature: OSType = 0x4D544F4F
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private(set) var shortcut: GlobalShortcut
    var onTrigger: (() -> Void)?
    var onChange: ((GlobalShortcut) -> Void)?

    init() {
        let defaults = UserDefaults.standard
        let keyCode = defaults.object(forKey: "shortcutKeyCode") as? Int ?? Int(GlobalShortcut.defaultValue.keyCode)
        let modifiers = defaults.object(forKey: "shortcutModifiers") as? Int ?? Int(GlobalShortcut.defaultValue.modifiers)
        shortcut = GlobalShortcut(keyCode: UInt32(keyCode), modifiers: UInt32(modifiers))
        installEventHandler()
        if register(shortcut) != noErr {
            shortcut = .defaultValue
            _ = register(shortcut)
        }
    }

    deinit {
        unregisterHotKey()
        if let handler = eventHandler { RemoveEventHandler(handler) }
    }

    @discardableResult
    func update(_ value: GlobalShortcut) -> OSStatus {
        if value == shortcut {
            return hotKeyRef == nil ? register(value) : noErr
        }
        unregisterHotKey()
        let status = register(value)
        guard status == noErr else {
            _ = register(shortcut)
            return status
        }
        shortcut = value
        UserDefaults.standard.set(Int(value.keyCode), forKey: "shortcutKeyCode")
        UserDefaults.standard.set(Int(value.modifiers), forKey: "shortcutModifiers")
        onChange?(value)
        return noErr
    }

    func reset() { _ = update(.defaultValue) }

    func presentRecorder() {
        unregisterHotKey()
        let alert = NSAlert()
        alert.messageText = "设置全局快捷键"
        alert.informativeText = "按下新组合键以打开 Mac工具箱。必须包含至少一个修饰键。"
        let capture = ShortcutCaptureView(frame: NSRect(x: 0, y: 0, width: 270, height: 42))
        var captured: GlobalShortcut?
        let saveButton = alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        capture.onCapture = { [weak saveButton] value in
            captured = value
            saveButton?.title = "保存 \(value.displayName)"
        }
        alert.accessoryView = capture
        if alert.runModal() == .alertFirstButtonReturn, let captured = captured {
            let status = update(captured)
            if status != noErr {
                let warning = NSAlert()
                warning.messageText = "快捷键不可用"
                warning.informativeText = "系统无法注册 \(captured.displayName)，可能已被其他应用占用。原快捷键 \(shortcut.displayName) 已保留。"
                warning.addButton(withTitle: "好")
                warning.runModal()
            }
        } else {
            _ = register(shortcut)
        }
    }

    private func installEventHandler() {
        var eventTypes = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                        eventKind: UInt32(kEventHotKeyPressed))]
        let callback: EventHandlerUPP = { _, event, userData in
            guard let userData = userData else { return noErr }
            var hotKeyID = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard result == noErr, hotKeyID.signature == 0x4D544F4F, hotKeyID.id == 1 else { return noErr }
            let manager = Unmanaged<ShortcutManager>.fromOpaque(userData).takeUnretainedValue()
            manager.onTrigger?()
            return noErr
        }
        InstallEventHandler(GetEventDispatcherTarget(), callback,
                            eventTypes.count, &eventTypes,
                            Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
    }

    private func register(_ value: GlobalShortcut) -> OSStatus {
        let hotKeyID = EventHotKeyID(signature: signature, id: 1)
        return RegisterEventHotKey(value.keyCode, value.modifiers, hotKeyID,
                                   GetEventDispatcherTarget(), 0, &hotKeyRef)
    }

    private func unregisterHotKey() {
        if let hotKeyRef = hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }
}
