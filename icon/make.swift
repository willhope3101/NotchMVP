import AppKit

// Draws the app icon: the notch silhouette biting into a dark rounded square,
// with a level meter underneath — the two things the app actually shows.
func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let s = size
    let ctx = NSGraphicsContext.current!.cgContext

    // Rounded-square background, macOS icon proportions.
    let inset = s * 0.06
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let bg = NSBezierPath(roundedRect: rect, xRadius: s * 0.22, yRadius: s * 0.22)
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.16, green: 0.16, blue: 0.18, alpha: 1),
        NSColor(calibratedRed: 0.05, green: 0.05, blue: 0.06, alpha: 1)
    ])!
    bg.addClip()
    gradient.draw(in: rect, angle: -90)
    ctx.resetClip()

    // The notch: a wide pill hanging from the top edge of the inner area.
    let notchW = s * 0.44, notchH = s * 0.135
    let notchX = (s - notchW) / 2
    let notchY = rect.maxY - notchH - s * 0.1
    let notch = NSBezierPath(roundedRect: CGRect(x: notchX, y: notchY, width: notchW, height: notchH),
                             xRadius: notchH / 2, yRadius: notchH / 2)
    NSColor.white.setFill()
    notch.fill()

    // Four bars, the tallest in the middle, echoing the meter.
    let heights: [CGFloat] = [0.10, 0.19, 0.14, 0.08]
    let barW = s * 0.055
    let gap = s * 0.038
    let total = barW * 4 + gap * 3
    var x = (s - total) / 2
    let baseY = notchY - s * 0.16
    for h in heights {
        let bar = NSBezierPath(roundedRect: CGRect(x: x, y: baseY, width: barW, height: s * h),
                               xRadius: barW / 2, yRadius: barW / 2)
        NSColor.white.withAlphaComponent(0.92).setFill()
        bar.fill()
        x += barW + gap
    }

    image.unlockFocus()
    return image
}

let iconset = URL(fileURLWithPath: "icon/AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// The sizes iconutil expects, each at 1x and 2x.
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = CGFloat(base * scale)
        let image = drawIcon(size: px)
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { continue }
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try png.write(to: iconset.appendingPathComponent(name))
    }
}
print("iconset written")
