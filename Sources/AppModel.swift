import Foundation
import CoreGraphics
import ApplicationServices

/// AX role and subrole names taken from the SDK's own constants, exposed as
/// `String` so the classification rules below stay plain, testable comparisons.
enum AXRoleName {
    static let window: String = kAXWindowRole as String
}

enum AXSubroleName {
    static let applicationDockItem: String = kAXApplicationDockItemSubrole as String
    static let separatorDockItem: String = kAXSeparatorDockItemSubrole as String
    static let trashDockItem: String = kAXTrashDockItemSubrole as String
    static let folderDockItem: String = kAXFolderDockItemSubrole as String
    static let documentDockItem: String = kAXDocumentDockItemSubrole as String
    static let urlDockItem: String = kAXURLDockItemSubrole as String
    static let minimizedWindowDockItem: String = kAXMinimizedWindowDockItemSubrole as String
    static let dockExtraItem: String = kAXDockExtraDockItemSubrole as String
    static let standardWindow: String = kAXStandardWindowSubrole as String
    static let dialog: String = kAXDialogSubrole as String
    static let systemDialog: String = kAXSystemDialogSubrole as String
    static let floatingWindow: String = kAXFloatingWindowSubrole as String
    static let systemFloatingWindow: String = kAXSystemFloatingWindowSubrole as String
    static let decorative: String = kAXDecorativeSubrole as String
    static let unknown: String = kAXUnknownSubrole as String
}

// MARK: - Dock item identification

enum DockItemKind: Equatable {
    case application
    case stack
    case trash
    case fileOrURL
    case separator
    case minimizedWindows
    case other
}

/// Everything about one Dock element that the classification rules need, already
/// decoded from AX so these rules stay testable without a trusted process.
struct DockItemFacts: Equatable {
    var role: String
    var subrole: String
    var urlPath: String?
    var title: String
    var bundleIdentifier: String?

    init(role: String = "", subrole: String = "", urlPath: String? = nil,
         title: String = "", bundleIdentifier: String? = nil) {
        self.role = role
        self.subrole = subrole
        self.urlPath = urlPath
        self.title = title
        self.bundleIdentifier = bundleIdentifier
    }
}

enum DockItemClassifier {
    static func classify(_ facts: DockItemFacts) -> DockItemKind {
        switch facts.subrole {
        case AXSubroleName.separatorDockItem: return .separator
        case AXSubroleName.trashDockItem: return .trash
        case AXSubroleName.folderDockItem: return .stack
        case AXSubroleName.documentDockItem, AXSubroleName.urlDockItem: return .fileOrURL
        case AXSubroleName.minimizedWindowDockItem: return .minimizedWindows
        case AXSubroleName.dockExtraItem: return .other
        default: break
        }
        if let bundleIdentifier = facts.bundleIdentifier, !bundleIdentifier.isEmpty { return .application }
        if facts.urlPath?
            .split(separator: "/").last
            .map({ $0.hasSuffix(".app") }) == true { return .application }
        if facts.subrole == AXSubroleName.applicationDockItem { return .application }
        return .other
    }

    /// An item can drive the window switcher only if it names a real application
    /// that is currently running; a quit-but-pinned icon has no windows to list.
    static func isSwitchable(_ facts: DockItemFacts, isRunning: Bool) -> Bool {
        classify(facts) == .application && isRunning
    }
}

// MARK: - Per-application window configuration

struct AppWindowConfig: Equatable {
    var includeMinimized: Bool = true
    var maxWindows: Int = 12
}

struct ManagedApp: Equatable {
    let bundleIdentifier: String
    let displayName: String
    var isEnabled: Bool
    var config: AppWindowConfig
}

/// Everyday editors, browsers and terminals people keep documents in. Only the
/// installed subset is ever offered in the menu.
enum AppCatalogue {
    struct Entry {
        let bundleIdentifier: String
        let fallbackName: String
        let defaultEnabled: Bool
    }

    static let entries: [Entry] = [
        Entry(bundleIdentifier: "com.apple.finder", fallbackName: "访达", defaultEnabled: true),
        Entry(bundleIdentifier: "com.microsoft.Word", fallbackName: "Microsoft Word", defaultEnabled: true),
        Entry(bundleIdentifier: "com.microsoft.Excel", fallbackName: "Microsoft Excel", defaultEnabled: true),
        Entry(bundleIdentifier: "com.microsoft.Powerpoint", fallbackName: "Microsoft PowerPoint", defaultEnabled: true),
        Entry(bundleIdentifier: "com.apple.Preview", fallbackName: "预览", defaultEnabled: true),
        Entry(bundleIdentifier: "com.apple.Safari", fallbackName: "Safari 浏览器", defaultEnabled: true),
        Entry(bundleIdentifier: "com.google.Chrome", fallbackName: "Google Chrome", defaultEnabled: true),
        Entry(bundleIdentifier: "com.microsoft.edgemac", fallbackName: "Microsoft Edge", defaultEnabled: true),
        Entry(bundleIdentifier: "com.apple.Terminal", fallbackName: "终端", defaultEnabled: true),
        Entry(bundleIdentifier: "com.apple.dt.Xcode", fallbackName: "Xcode", defaultEnabled: true),
        Entry(bundleIdentifier: "com.microsoft.VSCode", fallbackName: "Visual Studio Code", defaultEnabled: false),
        Entry(bundleIdentifier: "com.googlecode.iterm2", fallbackName: "iTerm2", defaultEnabled: false),
        Entry(bundleIdentifier: "com.apple.Notes", fallbackName: "备忘录", defaultEnabled: false),
        Entry(bundleIdentifier: "com.apple.mail", fallbackName: "邮件", defaultEnabled: false),
        Entry(bundleIdentifier: "com.tinyspeck.slackmacgap", fallbackName: "Slack", defaultEnabled: false),
        Entry(bundleIdentifier: "com.electron.lark", fallbackName: "Lark", defaultEnabled: false),
        Entry(bundleIdentifier: "com.coteditor.CotEditor", fallbackName: "CotEditor", defaultEnabled: false),
        Entry(bundleIdentifier: "abnerworks.Typora", fallbackName: "Typora", defaultEnabled: false),
        Entry(bundleIdentifier: "com.sublimetext.4", fallbackName: "Sublime Text", defaultEnabled: false)
    ]

    static func entry(for bundleIdentifier: String) -> Entry? {
        entries.first { $0.bundleIdentifier == bundleIdentifier }
    }

    static func fallbackName(for bundleIdentifier: String) -> String? {
        entry(for: bundleIdentifier)?.fallbackName
    }

    static func defaultEnabled(for bundleIdentifier: String) -> Bool {
        entry(for: bundleIdentifier)?.defaultEnabled ?? false
    }
}

// MARK: - Adaptive window presentation

struct WindowFacts: Equatable {
    var index: Int
    var role: String
    var subrole: String
    var title: String
    var minimized: Bool
    var isMain: Bool
    var isFocused: Bool
    var width: CGFloat
    var height: CGFloat
}

struct WindowDisplayRow: Equatable {
    let sourceIndex: Int
    let displayTitle: String
    let minimized: Bool
    let isMain: Bool
}

/// One row the panel can render and, when it carries an element, focus. Preview
/// rows keep `element == nil` so a click can never touch a real window.
struct AppWindow {
    let element: AXUIElement?
    let displayTitle: String
    let minimized: Bool
    let isMain: Bool

    init(element: AXUIElement?, displayTitle: String, minimized: Bool = false, isMain: Bool = false) {
        self.element = element
        self.displayTitle = displayTitle
        self.minimized = minimized
        self.isMain = isMain
    }

    static func preview(title: String) -> AppWindow {
        AppWindow(element: nil, displayTitle: title)
    }
}

struct WindowPresentation: Equatable {
    let rows: [WindowDisplayRow]
    let switchableCount: Int
    let omittedCount: Int

    static let empty = WindowPresentation(rows: [], switchableCount: 0, omittedCount: 0)
}

enum WindowPresentationRules {
    /// Subroles that are dialogs, palettes and overlays. They are never documents
    /// the user wants to jump back to, so they stay out of the switcher.
    static let excludedSubroles: Set<String> = [
        AXSubroleName.dialog,
        AXSubroleName.systemDialog,
        AXSubroleName.floatingWindow,
        AXSubroleName.systemFloatingWindow,
        AXSubroleName.decorative,
        AXSubroleName.unknown
    ]

    /// Primary rule is the documented standard window subrole. Toolkits that never
    /// set a subrole (some Electron and Qt builds) would otherwise show an empty
    /// panel, so an untitled-but-real window falls back to being listed.
    static func isSwitchable(_ window: WindowFacts) -> Bool {
        guard window.role == AXRoleName.window else { return false }
        guard window.width > 1, window.height > 1 else { return false }
        if excludedSubroles.contains(window.subrole) { return false }
        return window.subrole == AXSubroleName.standardWindow
            || !window.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || window.subrole.isEmpty
    }

    static func present(_ windows: [WindowFacts], config: AppWindowConfig) -> WindowPresentation {
        let candidates = windows.filter { window in
            guard isSwitchable(window) else { return false }
            return config.includeMinimized || !window.minimized
        }
        let ordered = candidates.sorted { first, second in
            if first.isFocused != second.isFocused { return first.isFocused }
            if first.isMain != second.isMain { return first.isMain }
            return first.index < second.index
        }
        let limit = max(1, config.maxWindows)
        let visible = Array(ordered.prefix(limit))
        let titles = deduplicate(visible.map { normalized($0.title) })
        let rows = visible.enumerated().map { offset, window in
            WindowDisplayRow(sourceIndex: window.index, displayTitle: titles[offset],
                             minimized: window.minimized, isMain: window.isMain)
        }
        return WindowPresentation(rows: rows, switchableCount: ordered.count,
                                  omittedCount: ordered.count - visible.count)
    }

    static func normalized(_ title: String) -> String {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? "未命名窗口" : clean
    }

    /// Two Chrome tabs or two untitled documents read as one row otherwise, and the
    /// whole point of the panel is telling windows apart.
    static func deduplicate(_ titles: [String]) -> [String] {
        var seen: [String: Int] = [:]
        return titles.map { title in
            let count = (seen[title] ?? 0) + 1
            seen[title] = count
            return count == 1 ? title : "\(title) (\(count))"
        }
    }
}

// MARK: - Panel appearance

struct PanelMetrics: Equatable {
    var rowHeight: CGFloat
    var titleFontSize: CGFloat
    var widthCap: CGFloat
    var autoFitWidth: Bool
    var maxHeightFraction: CGFloat
    var dockGap: CGFloat
    var cornerRadius: CGFloat

    static let minimumWidth: CGFloat = 240

    static var defaultValue: PanelMetrics {
        PanelMetrics(rowHeight: 52, titleFontSize: 14, widthCap: 380, autoFitWidth: true,
                     maxHeightFraction: 0.72, dockGap: 10, cornerRadius: 24)
    }

    func clamped() -> PanelMetrics {
        var m = self
        m.rowHeight = min(72, max(34, m.rowHeight))
        m.titleFontSize = min(22, max(11, m.titleFontSize))
        m.widthCap = min(640, max(Self.minimumWidth, m.widthCap))
        m.maxHeightFraction = min(0.9, max(0.3, m.maxHeightFraction))
        m.dockGap = min(40, max(4, m.dockGap))
        m.cornerRadius = min(36, max(0, m.cornerRadius))
        return m
    }

    var roundedRowHeight: CGFloat { (rowHeight * 2).rounded() / 2 }
    var roundedTitleFontSize: CGFloat { titleFontSize.rounded() }

    /// Long titles only widen the panel while auto-fit is on, and never past the cap.
    func width(forLongestTitleWidth longest: CGFloat, textInset: CGFloat) -> CGFloat {
        if autoFitWidth {
            return min(widthCap, max(Self.minimumWidth, longest + textInset))
        }
        return widthCap
    }
}
