import Foundation
import CoreGraphics
import ApplicationServices

@main
struct ModelTests {
    static var passed = 0

    static func check(_ name: String, _ condition: @autoclosure () -> Bool) {
        guard condition() else {
            fputs("FAIL: \(name)\n", stderr)
            exit(1)
        }
        passed += 1
        print("PASS: \(name)")
    }

    static func window(index: Int, title: String = "文档", subrole: String = AXSubroleName.standardWindow,
                       role: String = AXRoleName.window, minimized: Bool = false,
                       isMain: Bool = false, isFocused: Bool = false,
                       width: CGFloat = 800, height: CGFloat = 600) -> WindowFacts {
        WindowFacts(index: index, role: role, subrole: subrole, title: title,
                    minimized: minimized, isMain: isMain, isFocused: isFocused,
                    width: width, height: height)
    }

    static func dock(subrole: String = "", urlPath: String? = nil, title: String = "",
                     bundleIdentifier: String? = nil) -> DockItemFacts {
        DockItemFacts(role: "AXDockItem", subrole: subrole, urlPath: urlPath,
                      title: title, bundleIdentifier: bundleIdentifier)
    }

    static func main() {
        check("separator dock item is not an app",
              DockItemClassifier.classify(dock(subrole: AXSubroleName.separatorDockItem)) == .separator)
        check("trash is classified apart from apps",
              DockItemClassifier.classify(dock(subrole: AXSubroleName.trashDockItem)) == .trash)
        check("folder dock item is a stack",
              DockItemClassifier.classify(dock(subrole: AXSubroleName.folderDockItem,
                                               urlPath: "/Users/me/Desktop")) == .stack)
        check("recent document tile is a file, not an app",
              DockItemClassifier.classify(dock(subrole: AXSubroleName.documentDockItem,
                                               urlPath: "/Users/me/report.docx")) == .fileOrURL)
        check("url tile is a file, not an app",
              DockItemClassifier.classify(dock(subrole: AXSubroleName.urlDockItem,
                                               urlPath: "https://example.com")) == .fileOrURL)
        check("minimized window pile is not an app",
              DockItemClassifier.classify(dock(subrole: AXSubroleName.minimizedWindowDockItem)) == .minimizedWindows)
        check("dock extra falls back to other",
              DockItemClassifier.classify(dock(subrole: AXSubroleName.dockExtraItem)) == .other)
        check("running app resolved by bundle id",
              DockItemClassifier.classify(dock(subrole: AXSubroleName.applicationDockItem,
                                               bundleIdentifier: "com.microsoft.Word")) == .application)
        check("app resolved from .app url without subrole",
              DockItemClassifier.classify(dock(urlPath: "/Applications/Microsoft Word.app")) == .application)
        check("application subrole alone is enough",
              DockItemClassifier.classify(dock(subrole: AXSubroleName.applicationDockItem)) == .application)
        check("non-app url tile is not mistaken for an app",
              DockItemClassifier.classify(dock(urlPath: "/Users/me/report.docx")) == .other)
        check("running app item can drive the switcher",
              DockItemClassifier.isSwitchable(dock(bundleIdentifier: "com.microsoft.Word"), isRunning: true))
        check("pinned but quit app is not switchable",
              !DockItemClassifier.isSwitchable(dock(bundleIdentifier: "com.microsoft.Word"), isRunning: false))
        check("stack is never switchable even when its process runs",
              !DockItemClassifier.isSwitchable(dock(subrole: AXSubroleName.folderDockItem,
                                                    bundleIdentifier: "com.apple.finder"),
                                               isRunning: true))

        check("standard window is switchable",
              WindowPresentationRules.isSwitchable(window(index: 0)))
        check("dialog is excluded",
              !WindowPresentationRules.isSwitchable(window(index: 0, title: "打印",
                                                            subrole: AXSubroleName.dialog)))
        check("floating panel is excluded",
              !WindowPresentationRules.isSwitchable(window(index: 0, subrole: AXSubroleName.floatingWindow)))
        check("decorative window is excluded",
              !WindowPresentationRules.isSwitchable(window(index: 0, subrole: AXSubroleName.decorative)))
        check("unknown subrole is excluded",
              !WindowPresentationRules.isSwitchable(window(index: 0, subrole: AXSubroleName.unknown)))
        check("zero-size window is excluded",
              !WindowPresentationRules.isSwitchable(window(index: 0, width: 0, height: 0)))
        check("non-window role is excluded",
              !WindowPresentationRules.isSwitchable(window(index: 0, role: "AXSheet")))
        check("toolkit window without a subrole still lists",
              WindowPresentationRules.isSwitchable(window(index: 0, subrole: "")))
        check("titled non-standard window still lists",
              WindowPresentationRules.isSwitchable(window(index: 0, subrole: "AXZoomWindow")))

        let mixed = [window(index: 0, title: "第三"), window(index: 1, title: "已保存",
                                                              subrole: AXSubroleName.dialog),
                     window(index: 2, title: "当前", isFocused: true),
                     window(index: 3, title: "最小化", minimized: true),
                     window(index: 4, title: "主窗口", isMain: true)]
        let all = WindowPresentationRules.present(mixed, config: AppWindowConfig())
        check("dialog never reaches the panel", all.rows.count == 4 && all.switchableCount == 4)
        check("focused window sorts first", all.rows.first?.displayTitle == "当前")
        check("main window sorts before plain windows", all.rows[1].displayTitle == "主窗口")
        check("remaining windows keep accessibility order",
              all.rows.map(\.sourceIndex) == [2, 4, 0, 3])
        let noMinimized = WindowPresentationRules.present(mixed, config: AppWindowConfig(includeMinimized: false))
        check("minimized windows can be hidden per app",
              noMinimized.rows.count == 3 && !noMinimized.rows.contains { $0.minimized })
        let truncated = WindowPresentationRules.present(mixed, config: AppWindowConfig(maxWindows: 2))
        check("truncation reports hidden count",
              truncated.rows.count == 2 && truncated.switchableCount == 4 && truncated.omittedCount == 2)
        check("truncation keeps the highest priority rows",
              truncated.rows.map(\.displayTitle) == ["当前", "主窗口"])
        check("blank titles become a readable placeholder",
              WindowPresentationRules.normalized("   ") == "未命名窗口")
        check("titles are trimmed", WindowPresentationRules.normalized("  报告  ") == "报告")
        check("duplicate titles get numbered",
              WindowPresentationRules.deduplicate(["A", "A", "B", "A"]) == ["A", "A (2)", "B", "A (3)"])
        let dupes = WindowPresentationRules.present(
            [window(index: 0, title: "索引.html"), window(index: 1, title: "索引.html")],
            config: AppWindowConfig())
        check("panel rows disambiguate same-title windows",
              dupes.rows.map(\.displayTitle) == ["索引.html", "索引.html (2)"])
        let onlyPanels = WindowPresentationRules.present(
            [window(index: 0, subrole: AXSubroleName.systemFloatingWindow)], config: AppWindowConfig())
        check("an app with only panels reports an empty presentation", onlyPanels == WindowPresentation.empty)
        check("a preview row carries no accessibility element", AppWindow.preview(title: "示例").element == nil)

        var tooBig = PanelMetrics.defaultValue
        tooBig.rowHeight = 400
        tooBig.titleFontSize = 99
        tooBig.widthCap = 4000
        tooBig.maxHeightFraction = 3
        tooBig.dockGap = 900
        tooBig.cornerRadius = 200
        let big = tooBig.clamped()
        check("oversized metrics clamp to the upper bounds",
              big.rowHeight == 72 && big.titleFontSize == 22 && big.widthCap == 640
              && big.maxHeightFraction == 0.9 && big.dockGap == 40 && big.cornerRadius == 36)
        var tooSmall = PanelMetrics.defaultValue
        tooSmall.rowHeight = 8
        tooSmall.titleFontSize = 4
        tooSmall.widthCap = 10
        tooSmall.maxHeightFraction = 0.05
        tooSmall.dockGap = 0
        tooSmall.cornerRadius = -6
        let small = tooSmall.clamped()
        check("undersized metrics clamp to the lower bounds",
              small.rowHeight == 34 && small.titleFontSize == 11
              && small.widthCap == PanelMetrics.minimumWidth
              && small.maxHeightFraction == 0.3 && small.dockGap == 4 && small.cornerRadius == 0)
        check("row height snaps to half points",
              PanelMetrics.defaultValue.roundedRowHeight == 52
              && PanelMetrics(rowHeight: 53.3, titleFontSize: 14, widthCap: 380, autoFitWidth: true,
                              maxHeightFraction: 0.72, dockGap: 10, cornerRadius: 24).roundedRowHeight == 53.5)
        check("font size snaps to whole points", PanelMetrics.defaultValue.roundedTitleFontSize == 14)
        let autoFit = PanelMetrics.defaultValue
        check("auto-fit widens only up to the cap",
              autoFit.width(forLongestTitleWidth: 100, textInset: 112) == 240
              && autoFit.width(forLongestTitleWidth: 900, textInset: 112) == 380)
        var fixed = PanelMetrics.defaultValue
        fixed.autoFitWidth = false
        check("manual width ignores title length",
              fixed.width(forLongestTitleWidth: 20, textInset: 112) == 380
              && fixed.width(forLongestTitleWidth: 5000, textInset: 112) == 380)

        check("catalogue bundle ids are unique",
              Set(AppCatalogue.entries.map(\.bundleIdentifier)).count == AppCatalogue.entries.count)
        check("catalogue entries all name themselves",
              AppCatalogue.entries.allSatisfy { !$0.fallbackName.isEmpty && !$0.bundleIdentifier.isEmpty })
        check("finder and office editors default on",
              AppCatalogue.defaultEnabled(for: "com.apple.finder")
              && AppCatalogue.defaultEnabled(for: "com.microsoft.Word"))
        check("unknown app is off until the user adds it",
              !AppCatalogue.defaultEnabled(for: "com.example.nobody"))

        runSettingsStoreTests()
        print("\(passed) model tests passed.")
    }

    static func runSettingsStoreTests() {
        let suite = "ModelTests-\(UUID().uuidString)"
        let blankSuite = "\(suite)-blank"
        guard let defaults = UserDefaults(suiteName: suite),
              let blank = UserDefaults(suiteName: blankSuite) else {
            fputs("FAIL: settings suite unavailable\n", stderr)
            exit(1)
        }
        defer {
            defaults.removePersistentDomain(forName: suite)
            blank.removePersistentDomain(forName: blankSuite)
        }
        let finder = "com.apple.finder"
        let word = "com.microsoft.Word"
        let vscode = "com.microsoft.VSCode"
        let custom = "com.example.custom"
        let installed: [String: String] = [
            finder: "访达", word: "Microsoft Word", vscode: "Visual Studio Code",
            custom: "我的编辑器"
        ]

        check("appearance defaults load without any stored keys",
              SettingsStore(defaults: blank).metrics == PanelMetrics.defaultValue)
        check("catalogue name is the fallback for a fresh store",
              SettingsStore(defaults: blank).displayName(for: word) == "Microsoft Word")

        let fresh = SettingsStore(defaults: defaults)
        check("both tools are on before any choice is made",
              fresh.isToolEnabled(.windowSwitcher) && fresh.isToolEnabled(.pocket))
        fresh.setToolEnabled(false, for: .pocket)
        check("tool switch persists", !SettingsStore(defaults: defaults).isToolEnabled(.pocket))
        check("catalogue default is used when the user never touched an app",
              fresh.isEnabled(finder) && !fresh.isEnabled(vscode))
        fresh.setEnabled(false, for: finder)
        check("an installed default-on app can be turned off",
              !SettingsStore(defaults: defaults).isEnabled(finder))
        fresh.setEnabled(true, for: vscode)
        check("a default-off app can be turned on", SettingsStore(defaults: defaults).isEnabled(vscode))
        check("display name comes from the launcher name", fresh.displayName(for: word) == "Microsoft Word")

        check("per-app config starts permissive",
              fresh.config(for: word).includeMinimized && fresh.config(for: word).maxWindows == 12)
        fresh.setConfig(AppWindowConfig(includeMinimized: false, maxWindows: 999), for: word)
        let wordConfig = SettingsStore(defaults: defaults).config(for: word)
        check("per-app config persists", !wordConfig.includeMinimized)
        check("absurd window limits are clamped on write", wordConfig.maxWindows == 40)
        fresh.setConfig(AppWindowConfig(maxWindows: 1), for: vscode)
        check("window limit floor is clamped on write",
              SettingsStore(defaults: defaults).config(for: vscode).maxWindows == 3)

        let managed = SettingsStore(defaults: defaults).managedApps(installed: installed)
        check("only installed apps are offered",
              managed.count == 3 && !managed.contains { $0.bundleIdentifier == custom })
        check("managed list follows catalogue order",
              managed.map(\.bundleIdentifier) == [finder, word, vscode])
        check("managed rows carry the stored enable state",
              managed.first { $0.bundleIdentifier == finder }?.isEnabled == false
              && managed.first { $0.bundleIdentifier == vscode }?.isEnabled == true)
        fresh.addCustomApp(bundleIdentifier: custom, displayName: "我的编辑器")
        let withCustom = SettingsStore(defaults: defaults).managedApps(installed: installed)
        check("a manually added app appears last",
              withCustom.count == 4 && withCustom.last?.bundleIdentifier == custom)
        check("manually added app keeps its given name", withCustom.last?.displayName == "我的编辑器")
        check("manually added app defaults to off", withCustom.last?.isEnabled == false)
        fresh.setConfig(AppWindowConfig(includeMinimized: false, maxWindows: 3), for: custom)
        fresh.setEnabled(true, for: custom)
        fresh.removeCustomApp(bundleIdentifier: custom)
        check("removing an app drops it from the list",
              !SettingsStore(defaults: defaults).managedApps(installed: installed)
                  .contains { $0.bundleIdentifier == custom })
        fresh.addCustomApp(bundleIdentifier: custom, displayName: "我的编辑器")
        let readded = SettingsStore(defaults: defaults).managedApps(installed: installed)
            .first { $0.bundleIdentifier == custom }
        check("removing an app also clears its preferences",
              readded?.isEnabled == false && readded?.config.includeMinimized == true
              && readded?.config.maxWindows == 12)
        check("removing one app leaves the other choices alone",
              SettingsStore(defaults: defaults).isEnabled(finder) == false)

        var metrics = PanelMetrics.defaultValue
        metrics.rowHeight = 60
        metrics.titleFontSize = 18
        metrics.widthCap = 520
        metrics.autoFitWidth = false
        metrics.maxHeightFraction = 0.5
        metrics.dockGap = 18
        metrics.cornerRadius = 0
        fresh.setMetrics(metrics)
        let stored = SettingsStore(defaults: defaults).metrics
        check("appearance round-trips through preferences",
              stored.rowHeight == 60 && stored.titleFontSize == 18 && stored.widthCap == 520
              && stored.autoFitWidth == false && stored.maxHeightFraction == 0.5 && stored.dockGap == 18)
        check("a legitimate zero corner radius is not lost", stored.cornerRadius == 0)
        fresh.setMetrics(PanelMetrics.defaultValue)
        check("restoring defaults is stored, not treated as absent",
              SettingsStore(defaults: defaults).metrics == PanelMetrics.defaultValue)
    }
}
