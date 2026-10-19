import AppKit

/// Facts about where this process is running from.
///
/// Accessibility is granted per bundle path, so an entry the user toggled for a
/// different copy of the app can never affect this process. Every surface that
/// asks for permission must therefore name the exact path it wants authorised.
enum AppInstallation {
    static var bundleURL: URL { Bundle.main.bundleURL }
    /// File name on disk, e.g. `FinderHover.app`.
    static var fileName: String { bundleURL.lastPathComponent }
    /// Name the Accessibility list shows, i.e. without the extension.
    static var listName: String { bundleURL.deletingPathExtension().lastPathComponent }
    static var path: String { bundleURL.resolvingSymlinksInPath().path }

    /// Running straight out of a mounted disk image gives a randomised path under
    /// `/AppTranslocation/`; a grant made there dies with the session.
    static var isTranslocated: Bool { path.contains("/AppTranslocation/") }

    /// Other copies of the same bundle on disk. Returns absolute paths, sorted.
    static func duplicateCopies() -> [String] {
        guard let identifier = Bundle.main.bundleIdentifier else { return [] }
        let roots = ["/Applications", (NSHomeDirectory() as NSString).appendingPathComponent("Applications")]
        let current = bundleURL.resolvingSymlinksInPath().standardizedFileURL.path
        var found: [String] = []
        for root in roots {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root) else { continue }
            for entry in entries where entry.hasSuffix(".app") {
                let url = URL(fileURLWithPath: root).appendingPathComponent(entry)
                let resolved = url.resolvingSymlinksInPath().standardizedFileURL
                guard resolved.path != current,
                      let bundle = Bundle(url: resolved),
                      bundle.bundleIdentifier == identifier else { continue }
                found.append(resolved.path)
            }
        }
        return found.sorted()
    }
}
