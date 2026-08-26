import AppKit

// PR Bar icon generator. Renders a pixel-art "pull request" glyph:
//   base branch (left) = dot top + dot bottom + vertical line;
//   feature branch (right) = dot top + short line + a quarter-circle that
//   sweeps down-left and merges into the base branch's bottom dot.
// Everything is built as integer grid cells so the menu bar mark stays
// pixel-crisp with no anti-aliased blur.

struct Cell: Hashable { let x: Int; let y: Int }

// Glyph laid out on a top-left-origin grid (y grows downward).
func buildGlyph() -> (cells: Set<Cell>, w: Int, h: Int) {
    var cells = Set<Cell>()

    func fillBox(_ x0: Int, _ y0: Int, _ w: Int, _ h: Int) {
        for x in x0..<(x0 + w) { for y in y0..<(y0 + h) { cells.insert(Cell(x: x, y: y)) } }
    }

    // 7x7 pixel dot with the four single corner cells knocked off (rounded).
    func dot(left: Int, top: Int) {
        let s = 7
        for x in left..<(left + s) {
            for y in top..<(top + s) {
                let corner = (x == left || x == left + s - 1) && (y == top || y == top + s - 1)
                if !corner { cells.insert(Cell(x: x, y: y)) }
            }
        }
    }

    // Thick quadratic bezier stamped along its centerline.
    func bezier(_ p0: (Double, Double), _ p1: (Double, Double), _ p2: (Double, Double), thickness: Int) {
        let half = Double(thickness) / 2.0
        let steps = 900
        for i in 0...steps {
            let t = Double(i) / Double(steps)
            let mt = 1 - t
            let px = mt * mt * p0.0 + 2 * mt * t * p1.0 + t * t * p2.0
            let py = mt * mt * p0.1 + 2 * mt * t * p1.1 + t * t * p2.1
            let bx = Int(floor(px - half)), ex = Int(ceil(px + half))
            let by = Int(floor(py - half)), ey = Int(ceil(py + half))
            for x in bx..<ex { for y in by..<ey { cells.insert(Cell(x: x, y: y)) } }
        }
    }

    // Base branch (left): the trunk — a node top, a node bottom, straight line.
    dot(left: 3, top: 1)      // top-left node,    center (6.5, 4)
    dot(left: 3, top: 20)     // bottom-left node, center (6.5, 23)
    fillBox(5, 8, 3, 12)      // continuous vertical trunk between the nodes

    // Feature branch (right): a node top, a short line, then a curve that
    // merges into the trunk with a left-pointing arrowhead.
    dot(left: 13, top: 1)     // top-right node, center (16.5, 4)
    fillBox(15, 8, 3, 5)      // short vertical line below the node

    // Merge curve: from the feature line (16.5,13) sweeping down-left into the
    // trunk at (9,17). Control point pulls it around a clean quarter turn.
    bezier((16.5, 13), (16.5, 17), (9, 17), thickness: 3)

    // Arrowhead where the curve meets the trunk, pointing left into it.
    for (dx, dy) in [(0, 0), (1, -1), (1, 0), (1, 1), (2, -2), (2, -1), (2, 0), (2, 1), (2, 2)] {
        cells.insert(Cell(x: 8 + dx, y: 17 + dy))
    }

    // Normalize to the content bounding box. Extra horizontal padding brings
    // the frame close to 1:1 (the glyph is tall); it centers the mark without
    // shrinking its height — macOS fits a template icon to the menu bar height.
    let hpad = 6, vpad = 2
    let minX = cells.map(\.x).min()!, maxX = cells.map(\.x).max()!
    let minY = cells.map(\.y).min()!, maxY = cells.map(\.y).max()!
    var shifted = Set<Cell>()
    for c in cells { shifted.insert(Cell(x: c.x - minX + hpad, y: c.y - minY + vpad)) }
    let w = (maxX - minX + 1) + hpad * 2
    let h = (maxY - minY + 1) + vpad * 2
    return (shifted, w, h)
}

let glyph = buildGlyph()

// Fill glyph cells into a target rect (bottom-left origin, y flipped from grid).
func drawGlyph(in ctx: CGContext, rect: CGRect, color: NSColor, seam: CGFloat) {
    let cw = rect.width / CGFloat(glyph.w)
    let ch = rect.height / CGFloat(glyph.h)
    ctx.setFillColor(color.cgColor)
    ctx.interpolationQuality = .none
    for c in glyph.cells {
        let x = rect.minX + CGFloat(c.x) * cw
        let y = rect.minY + CGFloat(glyph.h - 1 - c.y) * ch
        ctx.fill(CGRect(x: x, y: y, width: cw + seam, height: ch + seam))
    }
}

// --- Menu bar mark: pure black glyph on transparent, template-ready. ---
func menubarMark(cellPx: Int) -> NSImage {
    let w = glyph.w * cellPx, h = glyph.h * cellPx
    let image = NSImage(size: NSSize(width: w, height: h))
    image.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    drawGlyph(in: ctx, rect: CGRect(x: 0, y: 0, width: w, height: h),
              color: .black, seam: 0)
    image.unlockFocus()
    return image
}

// --- App icon: Big Sur rounded rect, indigo->cyan gradient, white glyph. ---
func appIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext

    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    let radius = size * 0.2237
    let bg = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    ctx.saveGState()
    bg.addClip()
    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0x63/255, green: 0x66/255, blue: 0xf1/255, alpha: 1), // indigo
        NSColor(srgbRed: 0x22/255, green: 0xd3/255, blue: 0xee/255, alpha: 1), // cyan
    ])
    gradient?.draw(in: bg, angle: -45)

    // Glyph centered, sized to ~54% of the icon height, aspect preserved.
    let gh = size * 0.54
    let gw = gh * CGFloat(glyph.w) / CGFloat(glyph.h)
    let grect = CGRect(x: (size - gw) / 2, y: (size - gh) / 2, width: gw, height: gh)
    drawGlyph(in: ctx, rect: grect,
              color: NSColor(srgbRed: 0xe2/255, green: 0xe8/255, blue: 0xf0/255, alpha: 1),
              seam: size >= 128 ? 0.75 : 0.4)
    ctx.restoreGState()

    image.unlockFocus()
    return image
}

func savePNG(_ image: NSImage, to path: String) {
    let w = Int(image.size.width), h = Int(image.size.height)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
    NSGraphicsContext.restoreGraphicsState()
    let png = rep.representation(using: .png, properties: [:])!
    try? png.write(to: URL(fileURLWithPath: path))
}

let fm = FileManager.default
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

// 1. Menu bar mark (~30 grid cells tall * 5px ~ 150px, aspect ~1:1).
savePNG(menubarMark(cellPx: 5), to: "\(outDir)/menubar-mark.png")

// 2. App icon -> .iconset -> iconutil -> AppIcon.icns
let iconsetDir = "\(outDir)/AppIcon.iconset"
try? fm.removeItem(atPath: iconsetDir)
try? fm.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)

let variants: [(name: String, px: CGFloat)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for v in variants {
    savePNG(appIcon(size: v.px), to: "\(iconsetDir)/\(v.name)")
}

let iconutil = "/usr/bin/iconutil"
if fm.isExecutableFile(atPath: iconutil) {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: iconutil)
    proc.arguments = ["-c", "icns", iconsetDir, "-o", "\(outDir)/AppIcon.icns"]
    try? proc.run()
    proc.waitUntilExit()
    if proc.terminationStatus == 0 {
        try? fm.removeItem(atPath: iconsetDir)
        print("wrote AppIcon.icns")
    } else {
        savePNG(appIcon(size: 1024), to: "\(outDir)/AppIcon.png")
        print("iconutil failed; wrote AppIcon.png (1024) instead")
    }
} else {
    savePNG(appIcon(size: 1024), to: "\(outDir)/AppIcon.png")
    print("iconutil not found; wrote AppIcon.png (1024) instead")
}

print("done -> \(outDir)")
