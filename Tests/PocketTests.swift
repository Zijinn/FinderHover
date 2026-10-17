import AppKit
import Foundation
import CoreGraphics

@main
struct PocketTests {
    static var passed = 0

    static func check(_ name: String, _ condition: @autoclosure () -> Bool) {
        guard condition() else {
            fputs("FAIL: \(name)\n", stderr)
            exit(1)
        }
        passed += 1
        print("PASS: \(name)")
    }

    static func shake(_ detector: inout ShakeDetector, points: [(CGFloat, TimeInterval)]) -> Bool {
        var triggered = false
        for (x, time) in points {
            triggered = detector.update(point: CGPoint(x: x, y: 100), inside: true, now: time) || triggered
        }
        return triggered
    }

    static func main() {
        var detector = ShakeDetector(minimumSegmentDistance: 10, maximumDuration: 1, cooldownDuration: 0.5)
        check("one direction does not open pocket", !shake(&detector, points: [(100, 0), (120, 0.1)]))
        detector.reset()
        check("two complete side-to-side round trips trigger", shake(&detector, points: [(100, 0.2), (120, 0.3), (100, 0.4), (120, 0.5), (100, 0.6)]))
        check("cooldown prevents immediate retrigger", !shake(&detector, points: [(120, 0.7), (100, 0.8), (120, 0.9), (100, 1.0)]))
        detector.reset()
        check("single direction does not trigger", !shake(&detector, points: [(100, 0), (120, 0.1), (140, 0.2), (160, 0.3), (180, 0.4)]))
        detector.reset()
        check("small jitter does not trigger", !shake(&detector, points: [(100, 0), (104, 0.1), (98, 0.2), (103, 0.3), (99, 0.4), (102, 0.5)]))
        detector.reset()
        check("slow shake does not trigger", !shake(&detector, points: [(100, 0), (120, 0.3), (95, 0.7), (120, 1.1), (95, 1.5)]))
        detector.reset()
        _ = detector.update(point: CGPoint(x: 100, y: 100), inside: true, now: 0)
        _ = detector.update(point: CGPoint(x: 120, y: 100), inside: true, now: 0.1)
        _ = detector.update(point: CGPoint(x: 120, y: 100), inside: false, now: 0.2)
        check("leaving hit area resets a partial sequence", !shake(&detector, points: [(100, 0.3), (120, 0.4), (100, 0.5), (120, 0.6)]))

        // The status view now feeds detection from a single ProcessInfo.systemUptime clock,
        // so the detector must behave identically at a large uptime-style base than at zero.
        let uptimeBase: TimeInterval = 50_000
        detector.reset()
        check("full round trip at uptime base triggers",
              shake(&detector, points: [(100, uptimeBase), (120, uptimeBase + 0.1), (100, uptimeBase + 0.2), (120, uptimeBase + 0.3), (100, uptimeBase + 0.4)]))
        check("cooldown at uptime base blocks an immediate retrigger",
              !shake(&detector, points: [(120, uptimeBase + 0.5), (100, uptimeBase + 0.6), (120, uptimeBase + 0.7), (100, uptimeBase + 0.8)]))
        check("shake works again once the cooldown expires",
              shake(&detector, points: [(100, uptimeBase + 1.0), (120, uptimeBase + 1.1), (100, uptimeBase + 1.2), (120, uptimeBase + 1.3), (100, uptimeBase + 1.4)]))
        detector.reset()
        _ = detector.update(point: CGPoint(x: 100, y: 100), inside: true, now: uptimeBase)
        _ = detector.update(point: CGPoint(x: 120, y: 100), inside: true, now: uptimeBase + 0.1)
        _ = detector.update(point: CGPoint(x: 120, y: 100), inside: false, now: uptimeBase + 0.2)
        check("leaving hit area at uptime base resets a partial sequence",
              !shake(&detector, points: [(100, uptimeBase + 0.3), (120, uptimeBase + 0.4), (100, uptimeBase + 0.5), (120, uptimeBase + 0.6)]))
        detector.reset()
        check("single direction at uptime base does not trigger",
              !shake(&detector, points: [(100, uptimeBase), (120, uptimeBase + 0.1), (140, uptimeBase + 0.2), (160, uptimeBase + 0.3), (180, uptimeBase + 0.4)]))
        detector.reset()
        check("slow shake at uptime base does not trigger",
              !shake(&detector, points: [(100, uptimeBase), (120, uptimeBase + 0.3), (95, uptimeBase + 0.7), (120, uptimeBase + 1.1), (95, uptimeBase + 1.5)]))

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FinderHover-PocketTest-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.txt")
        try! Data("original".utf8).write(to: source)
        let sourceFromPasteboard = root.appendingPathComponent("from-pasteboard.txt")
        try! Data("pasteboard original".utf8).write(to: sourceFromPasteboard)
        let store = PocketStore()
        check("file is added as a reference", store.addURLs([source]) == 1)
        check("duplicate file is ignored", store.addURLs([source, source]) == 0)
        let filePasteboard = NSPasteboard(name: NSPasteboard.Name("FinderHover-Pocket-File-Test"))
        filePasteboard.clearContents()
        filePasteboard.writeObjects([sourceFromPasteboard as NSURL])
        check("file URL pasteboard is accepted", store.addPasteboard(filePasteboard) == 1)
        check("source file is unchanged", try! Data(contentsOf: source) == Data("original".utf8))
        check("dropped source file is unchanged", try! Data(contentsOf: sourceFromPasteboard) == Data("pasteboard original".utf8))
        let fileItem = store.items[0]
        check("export returns original URL", store.exportURL(for: fileItem) == source.standardizedFileURL)
        check("export keeps all pocket items", store.items.count == 2)

        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        for x in 0..<2 {
            for y in 0..<2 { rep.setColor(NSColor(deviceRed: 0.1, green: 0.3, blue: 0.9, alpha: 1), atX: x, y: y) }
        }
        let tiff = rep.tiffRepresentation!
        let imagePasteboard = NSPasteboard(name: NSPasteboard.Name("FinderHover-Pocket-Image-Test"))
        imagePasteboard.clearContents()
        imagePasteboard.setData(tiff, forType: .tiff)
        let imageItem = store.addImageFromPasteboard(imagePasteboard, preferredName: "微信截图")!
        check("clipboard TIFF becomes a PNG item", imageItem.kind == PocketItemKind.image && imageItem.url.pathExtension.lowercased() == "png" )
        check("temporary PNG exists", FileManager.default.fileExists(atPath: imageItem.url.path))
        check("temporary PNG is readable", NSImage(contentsOf: imageItem.url) != nil)
        let pngData = try! Data(contentsOf: imageItem.url)
        check("temporary image has PNG signature", Array(pngData.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10])
        let temporaryImageURL = imageItem.url
        store.clear()
        check("clear removes all items", store.items.isEmpty)
        check("clear removes temporary PNG", !FileManager.default.fileExists(atPath: temporaryImageURL.path))
        check("clear does not remove original files", FileManager.default.fileExists(atPath: source.path) && FileManager.default.fileExists(atPath: sourceFromPasteboard.path))
        let secondImage = store.addImageData(pngData, preferredName: "再次收纳")
        check("store recreates temporary directory after clear", secondImage != nil && secondImage!.isValid)
        store.clear()
        try? FileManager.default.removeItem(at: root)
        print("\(passed) pocket tests passed.")
    }
}
