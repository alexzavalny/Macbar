import AppKit

let destination = CommandLine.arguments.dropFirst().first ?? "build/IconGeneration"
let iconset = URL(fileURLWithPath: destination).appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let scale = CGFloat(pixels) / 1024
    let context = NSGraphicsContext.current!.cgContext
    context.scaleBy(x: scale, y: scale)
    let base = NSBezierPath(roundedRect: NSRect(x: 32, y: 32, width: 960, height: 960), xRadius: 218, yRadius: 218)
    NSGradient(colors: [NSColor(calibratedRed: 0.12, green: 0.27, blue: 0.53, alpha: 1),
                        NSColor(calibratedRed: 0.035, green: 0.08, blue: 0.18, alpha: 1)])!.draw(in: base, angle: -70)
    let glow = NSBezierPath(ovalIn: NSRect(x: 90, y: 470, width: 700, height: 600))
    NSColor(calibratedRed: 0.18, green: 0.55, blue: 0.95, alpha: 0.15).setFill()
    glow.fill()
    let bar = NSBezierPath(roundedRect: NSRect(x: 114, y: 182, width: 796, height: 152), xRadius: 35, yRadius: 35)
    NSColor.white.withAlphaComponent(0.20).setFill(); bar.fill()
    NSColor.white.withAlphaComponent(0.40).setStroke(); bar.lineWidth = 2; bar.stroke()
    let colors: [NSColor] = [.systemBlue, .white, .systemMint, .systemOrange, .systemPurple]
    for (index, color) in colors.enumerated() {
        let tile = NSBezierPath(roundedRect: NSRect(x: 225 + index * 119, y: 223, width: 72, height: 72), xRadius: 17, yRadius: 17)
        color.withAlphaComponent(0.95).setFill(); tile.fill()
    }
    for row in 0..<2 {
        for column in 0..<2 {
            let tile = NSBezierPath(roundedRect: NSRect(x: 359 + column * 166, y: 454 + row * 166, width: 144, height: 144), xRadius: 13, yRadius: 13)
            NSGradient(starting: NSColor(calibratedRed: 0.29, green: 0.77, blue: 1, alpha: 1),
                       ending: NSColor(calibratedRed: 0.07, green: 0.43, blue: 0.98, alpha: 1))!.draw(in: tile, angle: -60)
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try render(pixels: size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(pixels: size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
print(iconset.path)
