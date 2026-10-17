import Foundation

enum ToolboxTool: String, CaseIterable {
    case windowSwitcher
    case pocket
}

/// UserDefaults-backed settings for every tool in the box. App presence is passed
/// in rather than queried here, so the whole layer is testable without AppKit.
final class SettingsStore {
    private static let toolPrefix = "toolbox.tool"
    private static let appPrefix = "toolbox.app"
    private static let customAppsKey = "toolbox.customApps"
    private static let metricsPrefix = "toolbox.metrics"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: Tool switches

    func isToolEnabled(_ tool: ToolboxTool) -> Bool {
        let key = "\(Self.toolPrefix).\(tool.rawValue).enabled"
        return defaults.object(forKey: key) as? Bool ?? true
    }

    func setToolEnabled(_ enabled: Bool, for tool: ToolboxTool) {
        defaults.set(enabled, forKey: "\(Self.toolPrefix).\(tool.rawValue).enabled")
    }

    // MARK: Managed applications

    func displayName(for bundleIdentifier: String) -> String? {
        defaults.string(forKey: "\(Self.appPrefix).\(bundleIdentifier).name")
            ?? AppCatalogue.fallbackName(for: bundleIdentifier)
    }

    func isEnabled(_ bundleIdentifier: String) -> Bool {
        defaults.object(forKey: "\(Self.appPrefix).\(bundleIdentifier).enabled") as? Bool
            ?? AppCatalogue.defaultEnabled(for: bundleIdentifier)
    }

    func setEnabled(_ enabled: Bool, for bundleIdentifier: String) {
        defaults.set(enabled, forKey: "\(Self.appPrefix).\(bundleIdentifier).enabled")
    }

    func config(for bundleIdentifier: String) -> AppWindowConfig {
        var config = AppWindowConfig()
        if let includeMinimized = defaults.object(
            forKey: "\(Self.appPrefix).\(bundleIdentifier).includeMinimized") as? Bool {
            config.includeMinimized = includeMinimized
        }
        if let maxWindows = defaults.object(
            forKey: "\(Self.appPrefix).\(bundleIdentifier).maxWindows") as? Int {
            config.maxWindows = Self.clampedMaxWindows(maxWindows)
        }
        return config
    }

    func setConfig(_ config: AppWindowConfig, for bundleIdentifier: String) {
        defaults.set(config.includeMinimized,
                     forKey: "\(Self.appPrefix).\(bundleIdentifier).includeMinimized")
        defaults.set(Self.clampedMaxWindows(config.maxWindows),
                     forKey: "\(Self.appPrefix).\(bundleIdentifier).maxWindows")
    }

    static func clampedMaxWindows(_ value: Int) -> Int { min(40, max(3, value)) }

    func customBundleIdentifiers() -> [String] {
        (defaults.stringArray(forKey: Self.customAppsKey) ?? []).filter { !$0.isEmpty }
    }

    func addCustomApp(bundleIdentifier: String, displayName: String) {
        guard !bundleIdentifier.isEmpty else { return }
        var apps = customBundleIdentifiers()
        if !apps.contains(bundleIdentifier) { apps.append(bundleIdentifier) }
        defaults.set(apps, forKey: Self.customAppsKey)
        defaults.set(displayName, forKey: "\(Self.appPrefix).\(bundleIdentifier).name")
    }

    /// Removing an app drops its override too, otherwise a hidden stale preference
    /// silently decides the next time the same bundle id is re-added.
    func removeCustomApp(bundleIdentifier: String) {
        defaults.set(customBundleIdentifiers().filter { $0 != bundleIdentifier },
                     forKey: Self.customAppsKey)
        [".enabled", ".name", ".includeMinimized", ".maxWindows"].forEach {
            defaults.removeObject(forKey: "\(Self.appPrefix).\(bundleIdentifier)\($0)")
        }
    }

    /// Catalogue entries first, then user-added applications, and only entries that
    /// are actually installed on this machine.
    func managedApps(installed: [String: String]) -> [ManagedApp] {
        var apps: [ManagedApp] = []
        for entry in AppCatalogue.entries where installed[entry.bundleIdentifier] != nil {
            apps.append(ManagedApp(
                bundleIdentifier: entry.bundleIdentifier,
                displayName: installed[entry.bundleIdentifier] ?? entry.fallbackName,
                isEnabled: isEnabled(entry.bundleIdentifier),
                config: config(for: entry.bundleIdentifier)))
        }
        for bundleIdentifier in customBundleIdentifiers()
        where installed[bundleIdentifier] != nil
            && AppCatalogue.entry(for: bundleIdentifier) == nil {
            apps.append(ManagedApp(
                bundleIdentifier: bundleIdentifier,
                displayName: installed[bundleIdentifier] ?? displayName(for: bundleIdentifier) ?? bundleIdentifier,
                isEnabled: isEnabled(bundleIdentifier),
                config: config(for: bundleIdentifier)))
        }
        return apps
    }

    // MARK: Panel appearance

    var metrics: PanelMetrics {
        let defaults = self.defaults
        func value(_ key: String, _ fallback: CGFloat) -> CGFloat {
            guard let stored = defaults.object(forKey: "\(Self.metricsPrefix).\(key)") as? Double else {
                return fallback
            }
            return CGFloat(stored)
        }
        var metrics = PanelMetrics.defaultValue
        metrics.rowHeight = value("rowHeight", metrics.rowHeight)
        metrics.titleFontSize = value("titleFontSize", metrics.titleFontSize)
        metrics.widthCap = value("widthCap", metrics.widthCap)
        metrics.maxHeightFraction = value("maxHeightFraction", metrics.maxHeightFraction)
        metrics.dockGap = value("dockGap", metrics.dockGap)
        metrics.cornerRadius = value("cornerRadius", metrics.cornerRadius)
        if let autoFit = defaults.object(forKey: "\(Self.metricsPrefix).autoFitWidth") as? Bool {
            metrics.autoFitWidth = autoFit
        }
        return metrics.clamped()
    }

    func setMetrics(_ metrics: PanelMetrics) {
        let clamped = metrics.clamped()
        defaults.set(Double(clamped.rowHeight), forKey: "\(Self.metricsPrefix).rowHeight")
        defaults.set(Double(clamped.titleFontSize), forKey: "\(Self.metricsPrefix).titleFontSize")
        defaults.set(Double(clamped.widthCap), forKey: "\(Self.metricsPrefix).widthCap")
        defaults.set(Double(clamped.maxHeightFraction), forKey: "\(Self.metricsPrefix).maxHeightFraction")
        defaults.set(Double(clamped.dockGap), forKey: "\(Self.metricsPrefix).dockGap")
        defaults.set(Double(clamped.cornerRadius), forKey: "\(Self.metricsPrefix).cornerRadius")
        defaults.set(clamped.autoFitWidth, forKey: "\(Self.metricsPrefix).autoFitWidth")
    }
}
