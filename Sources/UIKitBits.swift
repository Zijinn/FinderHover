import AppKit

/// Top-down container. Every window and page in this file lays its children out
/// from the top edge, so y coordinates read the same way they do in a design tool.
final class FlippedContainerView: NSView {
    override var isFlipped: Bool { true }
}

/// Flat rounded surface used for cards, pills and status strips. Drawn rather than
/// layered so it renders identically in a view cache (which is how previews and
/// tests capture it).
final class RoundedBackgroundView: NSView {
    var fillColor: NSColor = .quaternaryLabelColor { didSet { needsDisplay = true } }
    var borderColor: NSColor? { didSet { needsDisplay = true } }
    var cornerRadius: CGFloat = 8 { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.25, dy: 0.25),
                                xRadius: cornerRadius, yRadius: cornerRadius)
        fillColor.setFill()
        path.fill()
        if let borderColor = borderColor {
            borderColor.setStroke()
            path.lineWidth = 0.5
            path.stroke()
        }
    }
}

/// Small capsule that carries a coloured dot and a short state word. Width follows
/// the text so callers never have to measure it themselves.
final class StatusPillView: NSView {
    var text: String = "" {
        didSet { needsDisplay = true; invalidateIntrinsicContentSize() }
    }
    var tint: NSColor = .systemOrange {
        didSet { needsDisplay = true }
    }

    private let font = NSFont.systemFont(ofSize: 12, weight: .medium)

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        let width = (text as NSString).size(withAttributes: [.font: font]).width
        return NSSize(width: ceil(width) + 32, height: 22)
    }

    override func draw(_ dirtyRect: NSRect) {
        tint.withAlphaComponent(0.14).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        tint.setFill()
        NSBezierPath(ovalIn: NSRect(x: 10, y: (bounds.height - 6) / 2, width: 6, height: 6)).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: tint]
        let textHeight = font.boundingRectForFont.height
        (text as NSString).draw(at: NSPoint(x: 22, y: (bounds.height - textHeight) / 2),
                                withAttributes: attributes)
    }
}

enum UIKitBits {
    /// Single-line label. Truncates rather than wraps, so it never reflows a row.
    static func label(_ string: String, size: CGFloat, weight: NSFont.Weight = .regular,
                      color: NSColor = .labelColor, frame: NSRect) -> NSTextField {
        let field = NSTextField(labelWithString: string)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.frame = frame
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    /// Wrapping label. `lines` of 0 means as many lines as the frame allows.
    static func paragraph(_ string: String, size: CGFloat, weight: NSFont.Weight = .regular,
                          color: NSColor = .labelColor, frame: NSRect, lines: Int = 0) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: string)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.frame = frame
        field.isSelectable = false
        field.maximumNumberOfLines = lines
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        return field
    }

    static func separator(frame: NSRect) -> NSView {
        let view = NSView(frame: frame)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.separatorColor.cgColor
        return view
    }

    static func symbol(_ name: String, pointSize: CGFloat, weight: NSFont.Weight = .regular) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
    }
}
