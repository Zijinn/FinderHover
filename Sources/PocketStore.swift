import AppKit
import Foundation

private let pocketDataType = NSPasteboard.PasteboardType("public.data")

public enum PocketItemKind: String {
    case file
    case image
}

public struct PocketItem: Equatable {
    public let id: UUID
    public let url: URL
    public let displayName: String
    public let kind: PocketItemKind
    public let addedAt: Date

    public var isValid: Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}

final class PocketStore {
    private(set) var items: [PocketItem] = []
    private var ownedTemporaryURLs: Set<URL> = []
    private let temporaryDirectory: URL
    var onChange: (() -> Void)?

    init() {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FinderHover-Pocket-\(UUID().uuidString)", isDirectory: true)
        ensureTemporaryDirectory()
    }

    var count: Int { items.count }

    @discardableResult
    func addURLs(_ urls: [URL]) -> Int {
        var added = 0
        for url in urls {
            let normalized = url.standardizedFileURL
            guard normalized.isFileURL,
                  FileManager.default.fileExists(atPath: normalized.path),
                  !items.contains(where: { $0.url.standardizedFileURL == normalized }) else { continue }
            let kind: PocketItemKind = Self.isImageURL(normalized) ? .image : .file
            items.append(PocketItem(id: UUID(), url: normalized,
                                    displayName: normalized.lastPathComponent,
                                    kind: kind, addedAt: Date()))
            added += 1
        }
        if added > 0 { onChange?() }
        return added
    }

    @discardableResult
    func addImage(_ image: NSImage, preferredName: String? = nil) -> PocketItem? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        return addImageData(png, preferredName: preferredName)
    }

    @discardableResult
    func addImageData(_ data: Data, preferredName: String? = nil) -> PocketItem? {
        guard let png = Self.pngData(from: data) else { return nil }
        ensureTemporaryDirectory()
        let baseName = Self.sanitizedName(preferredName ?? "剪贴板图片")
        let name = baseName.lowercased().hasSuffix(".png") ? baseName : baseName + ".png"
        let url = temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-\(name)")
        do {
            try png.write(to: url, options: .atomic)
        } catch {
            return nil
        }
        let item = PocketItem(id: UUID(), url: url, displayName: name,
                               kind: .image, addedAt: Date())
        items.append(item)
        ownedTemporaryURLs.insert(url)
        onChange?()
        return item
    }

    @discardableResult
    func addImageFromPasteboard(_ pasteboard: NSPasteboard,
                                preferredName: String? = nil) -> PocketItem? {
        let types: [NSPasteboard.PasteboardType] = [.png, .tiff, pocketDataType]
        for type in types {
            if let data = pasteboard.data(forType: type),
               let item = addImageData(data, preferredName: preferredName) { return item }
        }
        if let image = NSImage(pasteboard: pasteboard) {
            return addImage(image, preferredName: preferredName)
        }
        return nil
    }

    func exportURL(for item: PocketItem) -> URL? {
        guard item.isValid else { return nil }
        return item.url
    }

    func remove(_ item: PocketItem) {
        items.removeAll { $0.id == item.id }
        deleteOwnedFileIfNeeded(item.url)
        onChange?()
    }

    func clear() {
        let urls = ownedTemporaryURLs
        items.removeAll()
        ownedTemporaryURLs.removeAll()
        for url in urls { try? FileManager.default.removeItem(at: url) }
        try? FileManager.default.removeItem(at: temporaryDirectory)
        onChange?()
    }

    deinit {
        for url in ownedTemporaryURLs { try? FileManager.default.removeItem(at: url) }
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func hasAcceptablePasteboardContent(_ pasteboard: NSPasteboard) -> Bool {
        let fileTypes: [NSPasteboard.PasteboardType] = [.fileURL, .URL]
        if pasteboard.availableType(from: fileTypes) != nil { return true }
        return pasteboard.availableType(from: [.png, .tiff, pocketDataType]) != nil
    }

    @discardableResult
    func addPasteboard(_ pasteboard: NSPasteboard) -> Int {
        var added = 0
        if let objects = pasteboard.readObjects(forClasses: [NSURL.self],
                                                options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            added += addURLs(objects)
        }
        if added == 0, addImageFromPasteboard(pasteboard) != nil { added = 1 }
        return added
    }

    private func ensureTemporaryDirectory() {
        try? FileManager.default.createDirectory(at: temporaryDirectory,
                                                  withIntermediateDirectories: true)
    }

    private func deleteOwnedFileIfNeeded(_ url: URL) {
        guard ownedTemporaryURLs.remove(url) != nil else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func pngData(from data: Data) -> Data? {
        guard let bitmap = NSBitmapImageRep(data: data) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    private static func isImageURL(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "gif", "tif", "tiff", "heic", "webp", "bmp"].contains(ext)
    }

    private static func sanitizedName(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\")
        let clean = value.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? "剪贴板图片" : clean
    }
}
