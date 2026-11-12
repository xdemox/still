import AppKit

let size: CGFloat = 1024
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
let square = NSRect(x: 90, y: 90, width: 844, height: 844)
let tile = NSBezierPath(roundedRect: square, xRadius: 195, yRadius: 195)
let deepGreen = NSColor(srgbRed: 0.055, green: 0.115, blue: 0.105, alpha: 1)
let green = NSColor(srgbRed: 0.14, green: 0.25, blue: 0.20, alpha: 1)
NSGradient(starting: deepGreen, ending: green)!.draw(in: tile, angle: 47)
NSColor.white.withAlphaComponent(0.15).setStroke()
tile.lineWidth = 4
tile.stroke()
let heights: [CGFloat] = [76, 156, 264, 373, 233, 141, 76]
for (index, height) in heights.enumerated() {
    NSColor(srgbRed: 0.66, green: 0.96, blue: 0.79, alpha: 1 - abs(CGFloat(index) - 3) * 0.10).setFill()
    let bar = NSRect(x: 512 - 3 * 65 - 19 + CGFloat(index) * 65, y: 512 - height / 2, width: 38, height: height)
    NSBezierPath(roundedRect: bar, xRadius: 19, yRadius: 19).fill()
}
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
