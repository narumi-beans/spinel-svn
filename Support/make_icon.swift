// Renders the app icon (an original design) into an .iconset directory.
import AppKit

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
for (size, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let px = size * scale
    let img = NSImage(size: NSSize(width: px, height: px))
    img.lockFocus()
    let s = CGFloat(px)
    let rect = NSRect(x: s * 0.06, y: s * 0.06, width: s * 0.88, height: s * 0.88)
    let bg = NSBezierPath(roundedRect: rect, xRadius: s * 0.2, yRadius: s * 0.2)
    NSGradient(starting: NSColor(calibratedRed: 0.10, green: 0.55, blue: 0.45, alpha: 1),
               ending: NSColor(calibratedRed: 0.05, green: 0.25, blue: 0.40, alpha: 1))!.draw(in: bg, angle: -90)
    // Branch glyph: a trunk line with one branch, three nodes.
    NSColor.white.setStroke()
    NSColor.white.setFill()
    let line = NSBezierPath()
    line.lineWidth = s * 0.06
    line.lineCapStyle = .round
    line.move(to: NSPoint(x: s * 0.38, y: s * 0.25))
    line.line(to: NSPoint(x: s * 0.38, y: s * 0.75))
    line.move(to: NSPoint(x: s * 0.38, y: s * 0.42))
    line.curve(to: NSPoint(x: s * 0.64, y: s * 0.66), controlPoint1: NSPoint(x: s * 0.38, y: s * 0.58),
               controlPoint2: NSPoint(x: s * 0.64, y: s * 0.50))
    line.stroke()
    for p in [NSPoint(x: 0.38, y: 0.25), NSPoint(x: 0.38, y: 0.75), NSPoint(x: 0.64, y: 0.66)] {
        let r = s * 0.075
        NSBezierPath(ovalIn: NSRect(x: p.x * s - r, y: p.y * s - r, width: r * 2, height: r * 2)).fill()
    }
    img.unlockFocus()
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/\(name)"))
}
