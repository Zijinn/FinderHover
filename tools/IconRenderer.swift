import AppKit
import CoreGraphics

// Renders the app icon at any pixel size. macOS icons live on a 1024 grid where the
// artwork occupies 824x824, so every coordinate below is a fraction of the canvas and
// the body rect keeps that inset.

func rounded(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func fill(_ ctx: CGContext, _ path: CGPath, _ color: NSColor) {
    ctx.addPath(path)
    ctx.setFillColor(color.cgColor)
    ctx.fillPath()
}

func fill(_ ctx: CGContext, _ rect: CGRect, _ color: NSColor) {
    fill(ctx, CGPath(rect: rect, transform: nil), color)
}

func gradient(_ ctx: CGContext, _ rect: CGRect, _ from: NSColor, _ to: NSColor) {
    let space = CGColorSpaceCreateDeviceRGB()
    guard let g = CGGradient(colorsSpace: space,
                             colors: [from.cgColor, to.cgColor] as CFArray,
                             locations: [0, 1]) else { return }
    ctx.drawLinearGradient(g,
                           start: CGPoint(x: rect.minX, y: rect.maxY),
                           end: CGPoint(x: rect.maxX, y: rect.minY),
                           options: [])
}

struct Palette {
    let top: NSColor
    let bottom: NSColor
    let accent: NSColor
}

func palette(_ id: String) -> Palette {
    switch id {
    case "panel":
        return Palette(top: NSColor(srgbRed: 0.42, green: 0.36, blue: 0.95, alpha: 1),
                       bottom: NSColor(srgbRed: 0.24, green: 0.17, blue: 0.68, alpha: 1),
                       accent: NSColor(srgbRed: 0.36, green: 0.50, blue: 1.00, alpha: 1))
    case "dock":
        return Palette(top: NSColor(srgbRed: 0.18, green: 0.72, blue: 0.78, alpha: 1),
                       bottom: NSColor(srgbRed: 0.05, green: 0.38, blue: 0.55, alpha: 1),
                       accent: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    default:
        return Palette(top: NSColor(srgbRed: 0.36, green: 0.50, blue: 1.00, alpha: 1),
                       bottom: NSColor(srgbRed: 0.16, green: 0.22, blue: 0.72, alpha: 1),
                       accent: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    }
}

/// Three window panes stepping up to the right. The front pane is solid, the ones
/// behind fade back so the silhouette still reads at 16 px.
func drawStack(_ ctx: CGContext, body: CGRect, accent: NSColor) {
    let w = body.width * 0.47
    let h = body.height * 0.345
    let step = body.width * 0.078
    let origin = CGPoint(x: body.minX + body.width * 0.175, y: body.minY + body.height * 0.250)
    let radius = body.width * 0.048

    for (index, alpha) in [(2, CGFloat(0.20)), (1, CGFloat(0.44))] {
        let rect = CGRect(x: origin.x + step * CGFloat(index), y: origin.y + step * CGFloat(index),
                          width: w, height: h)
        fill(ctx, rounded(rect, radius), NSColor.white.withAlphaComponent(alpha))
    }

    let front = CGRect(x: origin.x, y: origin.y, width: w, height: h)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -body.height * 0.008),
                  blur: body.width * 0.030,
                  color: NSColor.black.withAlphaComponent(0.18).cgColor)
    fill(ctx, rounded(front, radius), .white)
    ctx.restoreGState()

    // Title strip, clipped to the pane so it keeps the rounded top corners. It has to
    // be darker than the pane, not tinted with the accent, or it disappears entirely.
    ctx.saveGState()
    ctx.addPath(rounded(front, radius))
    ctx.clip()
    fill(ctx, CGRect(x: front.minX, y: front.maxY - h * 0.105, width: w, height: h * 0.105),
         NSColor.black.withAlphaComponent(0.075))
    ctx.restoreGState()
}

/// The window list itself: a rounded card with a header and rows. This is the most
/// literal of the options — it shows what the app actually puts on screen.
func drawPanel(_ ctx: CGContext, body: CGRect, accent: NSColor) {
    let card = CGRect(x: body.minX + body.width * 0.205, y: body.minY + body.height * 0.155,
                      width: body.width * 0.59, height: body.height * 0.69)
    let radius = body.width * 0.075

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -body.height * 0.012),
                  blur: body.width * 0.045,
                  color: NSColor.black.withAlphaComponent(0.20).cgColor)
    fill(ctx, rounded(card, radius), .white)
    ctx.restoreGState()

    let inset = body.width * 0.062
    let innerX = card.minX + inset
    let innerW = card.width - inset * 2

    // Header: two short lines standing in for the app name and window count.
    fill(ctx, rounded(CGRect(x: innerX, y: card.maxY - body.height * 0.105,
                             width: innerW * 0.34, height: body.height * 0.028),
                      body.height * 0.014), accent.withAlphaComponent(0.55))
    fill(ctx, rounded(CGRect(x: innerX + innerW * 0.70, y: card.maxY - body.height * 0.103,
                             width: innerW * 0.30, height: body.height * 0.024),
                      body.height * 0.012), accent.withAlphaComponent(0.22))
    fill(ctx, CGRect(x: innerX, y: card.maxY - body.height * 0.145,
                     width: innerW, height: body.height * 0.006),
         accent.withAlphaComponent(0.14))

    // Rows: icon square plus a title line, the same rhythm as the real panel.
    let rowH = body.height * 0.105
    let gap = body.height * 0.026
    var y = card.maxY - body.height * 0.175 - rowH
    for index in 0..<3 {
        let alpha: CGFloat = index == 0 ? 0.95 : 0.55
        fill(ctx, rounded(CGRect(x: innerX, y: y, width: rowH, height: rowH),
                          rowH * 0.28), accent.withAlphaComponent(alpha))
        let lineW = innerW * (index == 0 ? 0.62 : (index == 1 ? 0.72 : 0.50))
        fill(ctx, rounded(CGRect(x: innerX + rowH + inset * 0.55,
                                 y: y + rowH * 0.30,
                                 width: lineW, height: rowH * 0.34),
                          rowH * 0.17), accent.withAlphaComponent(alpha * 0.55))
        y -= rowH + gap
    }
}

/// Dock strip with windows lifting out of it — the hover gesture, drawn literally.
func drawDock(_ ctx: CGContext, body: CGRect, accent: NSColor) {
    let dock = CGRect(x: body.minX + body.width * 0.165, y: body.minY + body.height * 0.175,
                      width: body.width * 0.67, height: body.height * 0.125)
    fill(ctx, rounded(dock, dock.height * 0.44), NSColor.white.withAlphaComponent(0.96))

    // Dots must read against the white strip; the accent here is white.
    let dot = dock.height * 0.44
    let ink = NSColor(srgbRed: 0.05, green: 0.38, blue: 0.55, alpha: 0.55)
    for index in 0..<4 {
        let x = dock.minX + dock.width * 0.11 + CGFloat(index) * (dot * 1.85)
        fill(ctx, rounded(CGRect(x: x, y: dock.midY - dot / 2, width: dot, height: dot),
                          dot * 0.32), index == 1 ? ink.withAlphaComponent(0.30) : ink)
    }

    let w = body.width * 0.42
    let h = body.height * 0.30
    let step = body.width * 0.070
    let origin = CGPoint(x: body.minX + body.width * 0.245, y: body.minY + body.height * 0.365)
    let radius = body.width * 0.048

    for (index, alpha) in [(2, CGFloat(0.22)), (1, CGFloat(0.46))] {
        let rect = CGRect(x: origin.x + step * CGFloat(index), y: origin.y + step * CGFloat(index),
                          width: w, height: h)
        fill(ctx, rounded(rect, radius), NSColor.white.withAlphaComponent(alpha))
    }
    let front = CGRect(x: origin.x, y: origin.y, width: w, height: h)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -body.height * 0.008),
                  blur: body.width * 0.030,
                  color: NSColor.black.withAlphaComponent(0.18).cgColor)
    fill(ctx, rounded(front, radius), .white)
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(rounded(front, radius))
    ctx.clip()
    fill(ctx, CGRect(x: front.minX, y: front.maxY - h * 0.105, width: w, height: h * 0.105),
         NSColor.black.withAlphaComponent(0.075))
    ctx.restoreGState()
}

func renderIcon(concept: String, pixels: Int) -> Data? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0),
          let gc = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = gc
    let ctx = gc.cgContext
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)

    let s = CGFloat(pixels)
    let body = CGRect(x: s * 0.098, y: s * 0.098, width: s * 0.804, height: s * 0.804)
    let shape = rounded(body, s * 0.180)
    let colors = palette(concept)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.032,
                  color: NSColor.black.withAlphaComponent(0.30).cgColor)
    fill(ctx, shape, .white)
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    gradient(ctx, body, colors.top, colors.bottom)
    if let gloss = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [NSColor.white.withAlphaComponent(0.18).cgColor,
                                       NSColor.white.withAlphaComponent(0).cgColor] as CFArray,
                              locations: [0, 1]) {
        ctx.drawLinearGradient(gloss,
                               start: CGPoint(x: body.midX, y: body.maxY),
                               end: CGPoint(x: body.midX, y: body.midY),
                               options: [])
    }
    ctx.restoreGState()

    switch concept {
    case "panel": drawPanel(ctx, body: body, accent: colors.accent)
    case "dock": drawDock(ctx, body: body, accent: colors.accent)
    default: drawStack(ctx, body: body, accent: colors.accent)
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let args = CommandLine.arguments
guard args.count >= 4 else {
    fputs("usage: IconRenderer <stack|panel|dock> <pixels> <output.png>\n", stderr)
    exit(2)
}
let concept = args[1]
guard let pixels = Int(args[2]) else { exit(2) }
guard let data = renderIcon(concept: concept, pixels: pixels) else {
    fputs("render failed\n", stderr)
    exit(1)
}
try data.write(to: URL(fileURLWithPath: args[3]))
