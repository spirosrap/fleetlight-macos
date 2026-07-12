import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("usage: make_icon.swift OUTPUT_PNG\n", stderr)
    exit(2)
}

let output = CommandLine.arguments[1]
let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)

image.lockFocus()

let outer = NSBezierPath(roundedRect: NSRect(x: 56, y: 56, width: 912, height: 912), xRadius: 220, yRadius: 220)
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.09, green: 0.16, blue: 0.28, alpha: 1),
    NSColor(calibratedRed: 0.05, green: 0.48, blue: 0.58, alpha: 1),
])!
gradient.draw(in: outer, angle: -48)

let glow = NSBezierPath(ovalIn: NSRect(x: 180, y: 470, width: 664, height: 420))
NSColor(calibratedWhite: 1, alpha: 0.08).setFill()
glow.fill()

let points = [
    NSPoint(x: 345, y: 650), NSPoint(x: 679, y: 650),
    NSPoint(x: 345, y: 360), NSPoint(x: 679, y: 360),
]

NSColor(calibratedWhite: 1, alpha: 0.28).setStroke()
let links = NSBezierPath()
links.lineWidth = 28
links.lineCapStyle = .round
links.move(to: points[0]); links.line(to: points[1])
links.move(to: points[0]); links.line(to: points[2])
links.move(to: points[1]); links.line(to: points[3])
links.move(to: points[2]); links.line(to: points[3])
links.stroke()

for (index, point) in points.enumerated() {
    let node = NSBezierPath(ovalIn: NSRect(x: point.x - 82, y: point.y - 82, width: 164, height: 164))
    NSColor.white.setFill()
    node.fill()

    let core = NSBezierPath(ovalIn: NSRect(x: point.x - 38, y: point.y - 38, width: 76, height: 76))
    (index == 0 ? NSColor.systemGreen : NSColor(calibratedRed: 0.06, green: 0.48, blue: 0.58, alpha: 1)).setFill()
    core.fill()
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fputs("could not render icon\n", stderr)
    exit(1)
}

try png.write(to: URL(fileURLWithPath: output))
