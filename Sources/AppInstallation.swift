import AppKit
import Security

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

    /// `adhoc` means the binary carries no identity, so the Accessibility grant is
    /// keyed to its hash and dies on the next rebuild or reinstall. This is the
    /// difference between "the app is broken" and "this copy is signed wrong", and it
    /// is invisible from the UI without asking the code signing machinery.
    static var signatureKind: String {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code = code else { return "unknown" }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode = staticCode else { return "unknown" }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation),
                                            &information) == errSecSuccess,
              let dictionary = information as? [String: Any] else { return "unknown" }
        let flags = (dictionary[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let isAdHoc = flags & 0x2 != 0
        if isAdHoc { return "adhoc" }
        let certificates = dictionary[kSecCodeInfoCertificates as String] as? [Any]
        return (certificates?.isEmpty ?? true) ? "unknown" : "certificate"
    }

    static var isAdHocSigned: Bool { signatureKind == "adhoc" }

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
