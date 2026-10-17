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

enum ShortcutRole: String, CaseIterable {
    case pocket
    case windowSwitcherPanel

    fileprivate var keyCodeKey: String {
        switch self {
        case .pocket: return "shortcutKeyCode"
        case .windowSwitcherPanel: return "toolbox.shortcut.windowSwitcherPanel.keyCode"
        }
    }

    fileprivate var modifiersKey: String {
        switch self {
        case .pocket: return "shortcutModifiers"
        case .windowSwitcherPanel: return "toolbox.shortcut.windowSwitcherPanel.modifiers"
        }
    }

    fileprivate var carbonID: UInt32 {
        switch self {
        case .pocket: return 1
        case .windowSwitcherPanel: return 2
        }
    }

    fileprivate var recorderTitle: String {
        switch self {
        case .pocket: return "临时口袋"
        case .windowSwitcherPanel: return "窗口列表面板"
        }
    }

    fileprivate init?(carbonID: UInt32) {
        guard let role = ShortcutRole.allCases.first(where: { $0.carbonID == carbonID }) else { return nil }
        self = role
    }
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
    private let defaults: UserDefaults
    private var hotKeyRefs: [ShortcutRole: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?
    private var shortcuts: [ShortcutRole: GlobalShortcut?] = [:]
    var onTrigger: ((ShortcutRole) -> Void)?
    var onChange: ((ShortcutRole, GlobalShortcut) -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        installEventHandler()
        for role in ShortcutRole.allCases {
            let value = Self.readShortcut(from: defaults, for: role)
            guard let shortcut = value else {
                shortcuts[role] = nil
                continue
            }
            if register(shortcut, for: role) != noErr {
                let fallback = Self.defaultShortcut(for: role)
                shortcuts[role] = fallback
                if let fallback = fallback, fallback != shortcut {
                    _ = register(fallback, for: role)
                }
            } else {
                shortcuts[role] = shortcut
            }
        }
    }

    deinit {
        for role in Array(hotKeyRefs.keys) {
            unregister(role)
        }
        if let handler = eventHandler { RemoveEventHandler(handler) }
    }

    func shortcut(for role: ShortcutRole) -> GlobalShortcut? {
        shortcuts[role] ?? nil
    }

    static func defaultShortcut(for role: ShortcutRole) -> GlobalShortcut? {
        switch role {
        case .pocket: return .defaultValue
        case .windowSwitcherPanel: return nil
        }
    }

    @discardableResult
    func update(_ value: GlobalShortcut?, for role: ShortcutRole) -> OSStatus {
        let current = shortcut(for: role)
        if value == current {
            guard let value = value else { return noErr }
            return hotKeyRefs[role] == nil ? register(value, for: role) : noErr
        }
        unregister(role)
        var status: OSStatus = noErr
        if let value = value {
            status = register(value, for: role)
        }
        guard status == noErr else {
            if let current = current { _ = register(current, for: role) }
            return status
        }
        shortcuts[role] = value
        persist(value, for: role)
        if let value = value { onChange?(role, value) }
        return noErr
    }

    func reset(_ role: ShortcutRole) {
        _ = update(Self.defaultShortcut(for: role), for: role)
    }

    func presentRecorder(for role: ShortcutRole) {
        let previous = shortcut(for: role)
        unregister(role)
        let alert = NSAlert()
        alert.messageText = "设置「\(role.recorderTitle)」的全局快捷键"
        alert.informativeText = "按下新组合键。必须包含至少一个修饰键；也可点「清空快捷键」移除该工具的快捷键。"
        let capture = ShortcutCaptureView(frame: NSRect(x: 0, y: 0, width: 270, height: 42))
        var captured: GlobalShortcut?
        let saveButton = alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "清空快捷键")
        capture.onCapture = { [weak saveButton] value in
            captured = value
            saveButton?.title = "保存 \(value.displayName)"
        }
        alert.accessoryView = capture
        let response = alert.runModal()
        if response == .alertFirstButtonReturn, let captured = captured {
            let status = update(captured, for: role)
            if status != noErr {
                let warning = NSAlert()
                warning.messageText = "快捷键不可用"
                let kept = previous.map { "原快捷键 \($0.displayName) 已保留。" }
                    ?? "该工具原本未设置快捷键。"
                warning.informativeText = "系统无法注册 \(captured.displayName)，可能已被其他应用占用。\(kept)"
                warning.addButton(withTitle: "好")
                warning.runModal()
            }
        } else if response == .alertThirdButtonReturn {
            _ = update(nil, for: role)
        } else {
            if let previous = previous { _ = register(previous, for: role) }
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
            guard result == noErr, hotKeyID.signature == 0x4D544F4F,
                  let role = ShortcutRole(carbonID: hotKeyID.id) else { return noErr }
            let manager = Unmanaged<ShortcutManager>.fromOpaque(userData).takeUnretainedValue()
            manager.onTrigger?(role)
            return noErr
        }
        InstallEventHandler(GetEventDispatcherTarget(), callback,
                            eventTypes.count, &eventTypes,
                            Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
    }

    private static func readShortcut(from defaults: UserDefaults, for role: ShortcutRole) -> GlobalShortcut? {
        // keyCode -1 是"用户主动清空"的哨兵值，必须与"从未设置过"（回落到角色默认值）区分开
        guard let rawKeyCode = defaults.object(forKey: role.keyCodeKey) as? Int else {
            return defaultShortcut(for: role)
        }
        guard rawKeyCode >= 0 else { return nil }
        let modifiers = defaults.object(forKey: role.modifiersKey) as? Int ?? 0
        return GlobalShortcut(keyCode: UInt32(rawKeyCode), modifiers: UInt32(modifiers))
    }

    private func persist(_ value: GlobalShortcut?, for role: ShortcutRole) {
        if let value = value {
            defaults.set(Int(value.keyCode), forKey: role.keyCodeKey)
            defaults.set(Int(value.modifiers), forKey: role.modifiersKey)
        } else {
            defaults.set(-1, forKey: role.keyCodeKey)
            defaults.set(0, forKey: role.modifiersKey)
        }
    }

    private func register(_ value: GlobalShortcut, for role: ShortcutRole) -> OSStatus {
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: signature, id: role.carbonID)
        let status = RegisterEventHotKey(value.keyCode, value.modifiers, hotKeyID,
                                         GetEventDispatcherTarget(), 0, &ref)
        if status == noErr { hotKeyRefs[role] = ref }
        return status
    }

    private func unregister(_ role: ShortcutRole) {
        if let ref = hotKeyRefs.removeValue(forKey: role) {
            UnregisterEventHotKey(ref)
        }
    }
}
